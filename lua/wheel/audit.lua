-- lua/wheel/audit.lua
-- Wheel: local append-only execution audit stream (CTX-0030).
--
-- The sink writes one JSON object per line under
-- `$XDG_STATE_HOME/wheel/audit/` (fallback `$HOME/.local/state/wheel/audit/`).
-- An explicit `dir` override exists for tests and embedders; it is never a
-- command or project input. The directory is repaired to 0700, every record
-- file is an owned, singly linked 0600 regular file, and a write opens the
-- file in append mode. No call site can ask the sink to truncate or replace an
-- existing record.
--
-- Bounds (fixed for production callers):
--   * one record is at most 16 KiB;
--   * the active file rotates at 1 MiB;
--   * four files are retained (active + `audit.1.jsonl` .. `audit.3.jsonl`),
--     so the stream is bounded at 4 MiB.
--
-- Integrity: every record carries a monotonic `seq`, the previous record's
-- `hash`, and its own SHA-256 `hash` over the canonical record without the
-- `hash` field. The chain detects silent edits within the retained files. It
-- is not a boundary against the same OS user: that user can read, rewrite, or
-- delete the stream. Tearing a line (a crash, an external writer) is refused
-- on the next write instead of being silently repaired, so a high-risk spawn
-- fails closed after an unexplained tail.
--
-- Redaction: only the allowlisted fields below are recorded. Command strings,
-- argv elements, metadata, and reasons pass through the secret-name, header,
-- query, flag, token-shape, and URL-userinfo passes. A credential-bearing
-- header is removed as a whole value (name, scheme, and every parameter),
-- through its enclosing quote or the end of the preview, so a Digest/AWS4
-- parameter list cannot leave a value after the first token. A removed value
-- becomes `[redacted:<16 hex of SHA-256(value)>]`; the same value yields the
-- same marker, so an operator can correlate events without recovering the
-- secret.
-- Prompts, file contents, provider responses, output, environment values, and
-- authorization header values are never accepted as record fields. Pattern
-- redaction remains heuristic for values Wheel did not load itself.
--
-- Failure contract: `record` returns `true` or `nil, typed_error, reason_code`.
-- The typed error is the static `runtime` / `E_AUDIT_UNAVAILABLE` table; reason
-- codes are a fixed vocabulary (`no_state_dir`, `audit_directory`,
-- `audit_file`, `audit_corrupt`, `rotation_failed`, `write_failed`,
-- `record_too_large`, `hash_unavailable`, `invalid_event`). No path, value,
-- or filesystem diagnostic is copied into either one.
--
-- Concurrency: one process reuses one sink per directory, so sequences stay
-- monotonic inside that process. Two processes appending at the same instant
-- can interleave records and duplicate a sequence number; cross-process
-- serialization is a documented residual, not a claimed guarantee. Appends are
-- flushed to the OS but not fsynced; a crash can lose the last line, which the
-- next writer treats as a torn tail rather than silently repairing it.

local WheelAudit = {}

local WheelErrors = require("wheel.errors")

local FORMAT = "wheel-audit/1"
local ZERO_HASH = string.rep("0", 64)
local MAX_PATH_BYTES = 4096

-- Modes are decimal forms of the octal permission bits (0700 and 0600).
local DIR_MODE = 448
local FILE_MODE = 384

local LIMITS = {
  MAX_RECORD_BYTES = 16 * 1024,
  MAX_FILE_BYTES = 1024 * 1024,
  MAX_FILES = 4,
  MAX_METADATA_BYTES = 256,
  MAX_INTENT_BYTES = 160,
  MAX_CWD_BYTES = 512,
  MAX_REASON_BYTES = 256,
  MAX_COMMAND_BYTES = 2048,
  MAX_TOKEN_BYTES = 64,
}

WheelAudit.FORMAT = FORMAT
WheelAudit.DIR_MODE = DIR_MODE
WheelAudit.FILE_MODE = FILE_MODE
WheelAudit.LIMITS = LIMITS

-- ---------------------------------------------------------------------------
-- Lazy dependencies
-- ---------------------------------------------------------------------------
--
-- host.lua requires this module at its top, so this module cannot require the
-- host seam (or config, which requires the host seam) while it is loading.
-- Both are resolved on the first record instead, after the host module is
-- complete. Kernel is also lazy to keep activation cheap; it owns the canonical
-- JSON encoder used by the rest of Wheel.

local cached_host = nil
local cached_json = nil
local cached_hash = nil

local function host()
  if cached_host then
    return cached_host
  end
  local ok, mod = pcall(require, "wheel.host")
  if not ok then
    package.loaded["wheel.host"] = nil
    ok, mod = pcall(require, "lua.wheel.host")
  end
  if ok and type(mod) == "table" then
    cached_host = mod
    return mod
  end
  return nil
end

local function json()
  if cached_json then
    return cached_json
  end
  local ok, kernel = pcall(require, "wheel.kernel")
  if not ok then
    package.loaded["wheel.kernel"] = nil
    ok, kernel = pcall(require, "lua.wheel.kernel")
  end
  if ok and type(kernel) == "table" and type(kernel.JSON) == "table"
    and type(kernel.JSON.encode) == "function"
    and type(kernel.JSON.decode) == "function" then
    cached_json = kernel.JSON
    return cached_json
  end
  return nil
end

local function hash_function()
  if cached_hash then
    return cached_hash
  end
  local ok, config = pcall(require, "wheel.config")
  if ok and type(config) == "table" and type(config.compute_hash) == "function" then
    cached_hash = config.compute_hash
    return cached_hash
  end
  return nil
end

--- Compute a deterministic 64-hex SHA-256 digest.
-- @param text string
-- @return string? digest
local function digest(text)
  local compute = hash_function()
  if not compute then
    return nil
  end
  local ok, value = pcall(compute, text)
  if not ok or type(value) ~= "string" or #value ~= 64 then
    return nil
  end
  return value
end

local function encode(value)
  local codec = json()
  if not codec then
    return nil
  end
  local ok, text = pcall(codec.encode, value)
  if ok and type(text) == "string" then
    return text
  end
  return nil
end

local function decode(text)
  local codec = json()
  if not codec then
    return nil
  end
  local ok, value = pcall(codec.decode, text)
  if ok then
    return value
  end
  return nil
end

local function audit_failure(reason)
  return nil, WheelErrors.audit_unavailable(), reason
end

-- ---------------------------------------------------------------------------
-- Redaction
-- ---------------------------------------------------------------------------

local SECRET_SUFFIXES = {
  "key",
  "token",
  "secret",
  "password",
  "passwd",
  "credential",
  "credentials",
}

--- Test whether a name looks like a credential-bearing field or flag.
-- This deliberately over-matches (for example `monkey` ends in `key`): losing
-- a harmless command value is preferable to recording a secret.
-- @param name string?
-- @return boolean
local function is_secret_name(name)
  if type(name) ~= "string" or name == "" then
    return false
  end
  local compact = name:lower():gsub("[^%w]", "")
  if compact == "authorization" or compact == "proxyauthorization" then
    return true
  end
  if compact:find("secret", 1, true) ~= nil then
    return true
  end
  for _, suffix in ipairs(SECRET_SUFFIXES) do
    if #compact >= #suffix and compact:sub(-#suffix) == suffix then
      return true
    end
  end
  return false
end

--- Build the stable placeholder for a redacted value.
-- @param value string
-- @return string? placeholder
local function redaction_marker(value)
  local value_hash = digest(value)
  if not value_hash then
    return nil
  end
  return "[redacted:" .. value_hash:sub(1, 16) .. "]"
end

--- Remove control characters and fold CR/LF so one field stays one line.
-- @param value string
-- @return string
local function clean_text(value)
  value = value:gsub("%z", "")
  value = value:gsub("[\r\n]", " ")
  return value
end

--- Return the shell quote state at a position, scanning from the start.
-- The audit preview is bounded, so the quadratic worst case over a handful of
-- header names is acceptable. Backslash escapes are honored inside double
-- quotes only, matching the shell forms the harness sees.
-- @param text string
-- @param limit number
-- @return string? '"', "'", or nil
local function quote_state_at(text, limit)
  local state = nil
  local index = 1
  while index < limit do
    local char = text:sub(index, index)
    if state == '"' then
      if char == "\\" then
        index = index + 2
      else
        if char == '"' then
          state = nil
        end
        index = index + 1
      end
    elseif state == "'" then
      if char == "'" then
        state = nil
      end
      index = index + 1
    else
      if char == '"' or char == "'" then
        state = char
      end
      index = index + 1
    end
  end
  return state
end

--- Find the closing quote for a quoted value, or the end of the preview.
-- @param text string
-- @param start number index of the opening quote
-- @param quote string '"' or "'"
-- @return number end index
local function quoted_end(text, start, quote)
  local index = start + 1
  local length = #text
  while index <= length do
    local char = text:sub(index, index)
    if quote == '"' and char == "\\" then
      index = index + 2
    elseif char == quote then
      return index
    else
      index = index + 1
    end
  end
  return length
end

--- Replace every secret-shaped header's complete value with one marker.
-- Authorization and Proxy-Authorization are redacted regardless of scheme
-- (Bearer, Basic, Token, ApiKey, SSWS, Digest, AWS4-HMAC-SHA256, ...). The
-- scanner consumes the whole value through the enclosing quote or the end of
-- the preview, so a Digest/AWS4 parameter list cannot leave a credential after
-- the first token. Header names are dropped as well; only the stable value
-- marker remains. Quoted shell headers and JSON forms are handled by the same
-- quote-state pass.
-- @param text string
-- @param counter table { n = number }
-- @return string
local function redact_secret_headers(text, counter)
  local out = {}
  local cursor = 1
  local index = 1
  local length = #text

  while index <= length do
    local char = text:sub(index, index)
    local previous = index > 1 and text:sub(index - 1, index - 1) or ""
    local at_boundary = previous == "" or previous:match("[%w%-_]") == nil

    if char:match("[%a]") and at_boundary then
      local name = text:sub(index):match("^([%a][%w%-_]*)")
      local after_name = index + #name
      local colon = after_name
      -- A JSON key closes its quote before the colon: `"Authorization":"..."`.
      local closing = text:sub(colon, colon)
      if closing == '"' or closing == "'" then
        colon = colon + 1
      end
      while text:sub(colon, colon) == " " or text:sub(colon, colon) == "\t" do
        colon = colon + 1
      end

      if text:sub(colon, colon) == ":" and is_secret_name(name) then
        local value_start = colon + 1
        while text:sub(value_start, value_start) == " "
          or text:sub(value_start, value_start) == "\t" do
          value_start = value_start + 1
        end

        local value_end = nil
        local first = text:sub(value_start, value_start)
        if first == '"' then
          value_end = quoted_end(text, value_start, '"')
        elseif first == "'" then
          value_end = quoted_end(text, value_start, "'")
        else
          local state = quote_state_at(text, index)
          if state == '"' then
            value_end = quoted_end(text, value_start, '"')
          elseif state == "'" then
            value_end = quoted_end(text, value_start, "'")
          else
            value_end = length
          end
        end

        if value_end ~= nil and value_end >= value_start then
          local credential
          local first_char = text:sub(value_start, value_start)
          if first_char == '"' or first_char == "'" then
            credential = text:sub(value_start + 1, value_end - 1)
          elseif text:sub(value_end, value_end) == '"'
            or text:sub(value_end, value_end) == "'" then
            credential = text:sub(value_start, value_end - 1)
          else
            credential = text:sub(value_start, value_end)
          end
          local marker = redaction_marker(credential)
          if marker then
            counter.n = counter.n + 1
            out[#out + 1] = text:sub(cursor, index - 1)
            out[#out + 1] = marker
            cursor = value_end + 1
            index = cursor
          else
            index = index + 1
          end
        else
          index = index + 1
        end
      else
        index = index + 1
      end
    else
      index = index + 1
    end
  end

  out[#out + 1] = text:sub(cursor)
  return table.concat(out)
end

--- Apply the redaction passes to one free-form string.
-- @param text string
-- @param counter table { n = number }
-- @return string? redacted, boolean? changed
local function redact_text(text, counter)
  if type(text) ~= "string" then
    return nil
  end
  text = clean_text(text)
  text = redact_secret_headers(text, counter)

  local function span(prefix, value)
    local marker = redaction_marker(value)
    if not marker then
      return nil
    end
    counter.n = counter.n + 1
    return prefix .. marker
  end

  local function whole(value)
    local marker = redaction_marker(value)
    if not marker then
      return nil
    end
    counter.n = counter.n + 1
    return marker
  end

  -- Bare bearer tokens outside a header still need the shape pass.
  text = text:gsub("([Bb][Ee][Aa][Rr][Ee][Rr]%s+)([%w%-%._~%+/=]+)", function(_, value)
    return whole(value)
  end)

  text = text:gsub("([%a_][%w_]*)(=)([^%s]+)", function(name, separator, value)
    if is_secret_name(name) then
      return span(name .. separator, value)
    end
    return nil
  end)

  text = text:gsub("(%-%-?[%w%-_]+)(=)([^%s]+)", function(flag, separator, value)
    if is_secret_name(flag) then
      return span(flag .. separator, value)
    end
    return nil
  end)

  text = text:gsub("(%-%-?[%w%-_]+)(%s+)([^%s%-][^%s]*)", function(flag, space, value)
    if is_secret_name(flag) then
      return span(flag .. space, value)
    end
    return nil
  end)

  text = text:gsub("([?&][%w%-_]+)(=)([^&%s]+)", function(name, separator, value)
    if is_secret_name(name) then
      return span(name .. separator, value)
    end
    return nil
  end)

  -- Common credential shapes that appear without a field name.
  text = text:gsub("(sk%-[%w%-_]+)", function(value)
    return whole(value)
  end)
  text = text:gsub("(gh[pousr]_[%w]+)", function(value)
    return whole(value)
  end)
  text = text:gsub("(xox[baprs]%-[%w%-]+)", function(value)
    return whole(value)
  end)
  text = text:gsub("(AKIA[%w]+)", function(value)
    return whole(value)
  end)
  text = text:gsub("(eyJ[%w%-_]+%.[%w%-_]+%.[%w%-_]+)", function(value)
    return whole(value)
  end)

  text = text:gsub("(://[^/%s:]+:)([^@%s]+)(@)", function(prefix, value, suffix)
    local marker = redaction_marker(value)
    if not marker then
      return nil
    end
    counter.n = counter.n + 1
    return prefix .. marker .. suffix
  end)

  return text
end

--- Redact a bounded prefix of one value.
-- Redaction patterns are only applied to the retained preview window. A
-- 100 KiB argv element must not drive quadratic pattern scanning, and the sink
-- never records more than the preview anyway. A credential that starts inside
-- the window is still matched by the shape passes; a value beyond it is not
-- recorded at all.
-- @param text string
-- @param counter table
-- @param window number
-- @return string? redacted, boolean truncated
local function redact_preview(text, counter, window)
  if type(text) ~= "string" then
    return nil
  end
  local truncated = #text > window
  if truncated then
    text = text:sub(1, window)
  end
  local redacted = redact_text(text, counter)
  if not redacted then
    return nil, truncated
  end
  return redacted, truncated
end

--- Redact and bound one metadata value.
-- @param value any
-- @param limit number
-- @param counter table
-- @return string? value
local function sanitize_meta(value, limit, counter)
  if type(value) ~= "string" then
    return nil
  end
  local redacted = redact_preview(value, counter, limit + 128)
  if not redacted then
    return nil
  end
  if #redacted > limit then
    redacted = redacted:sub(1, limit - 3) .. "..."
  end
  return redacted
end

--- Redact an argv vector with flag/value context and a total byte budget.
-- @param program string
-- @param args table?
-- @param counter table
-- @return table? argv, boolean? truncated
local function sanitize_argv(program, args, counter)
  local out = {}
  local budget = LIMITS.MAX_COMMAND_BYTES
  local truncated = false
  local force_next = false

  local function push(value)
    if type(value) ~= "string" then
      value = tostring(value or "")
    end
    local rendered
    local window = math.min(LIMITS.MAX_COMMAND_BYTES, math.max(budget, 1) + 256)
    local truncated_value = #value > window
    if force_next then
      rendered = redaction_marker(value:sub(1, window))
      if rendered then
        counter.n = counter.n + 1
      end
    else
      rendered = redact_preview(value, counter, window)
    end
    force_next = false
    if not rendered then
      return false
    end
    if truncated_value or budget <= 0 then
      truncated = true
    end
    if budget <= 0 then
      return true
    end
    if #rendered > budget then
      rendered = rendered:sub(1, budget)
      truncated = true
    end
    budget = budget - #rendered
    out[#out + 1] = rendered
    return true
  end

  if not push(program) then
    return nil
  end
  for _, arg in ipairs(args or {}) do
    local flag_name = type(arg) == "string" and arg:match("^%-%-?([%w%-_]+)$") or nil
    local secret_flag = flag_name ~= nil and is_secret_name(flag_name)
    if not push(arg) then
      return nil
    end
    if secret_flag then
      force_next = true
    end
  end
  return out, truncated
end

--- Redact a shell string and bound its retained preview.
-- @param shell_string string
-- @param counter table
-- @return string? command, boolean? truncated
local function sanitize_shell(shell_string, counter)
  if type(shell_string) ~= "string" then
    return nil
  end
  local rendered, truncated = redact_preview(
    shell_string, counter, LIMITS.MAX_COMMAND_BYTES)
  if not rendered then
    return nil
  end
  if #rendered > LIMITS.MAX_COMMAND_BYTES then
    rendered = rendered:sub(1, LIMITS.MAX_COMMAND_BYTES)
    truncated = true
  end
  return rendered, truncated
end

-- ---------------------------------------------------------------------------
-- Record construction
-- ---------------------------------------------------------------------------

local EVENT_PATTERN = "^[a-z][a-z0-9_.%-]*$"
local CLEANUP_VALUES = {
  swept = true,
  unverified = true,
  not_run = true,
}
local OUTCOME_VALUES = {
  exited = true,
  timeout = true,
  unavailable = true,
  failure = true,
}

--- Build the allowlisted, redacted part of one record.
-- @param event table
-- @param counter table
-- @return table? record, string? reason
local function build_record(event, counter)
  if type(event) ~= "table" then
    return nil, "invalid_event"
  end

  local name = event.event
  if type(name) ~= "string" or #name > LIMITS.MAX_TOKEN_BYTES
    or name:match(EVENT_PATTERN) == nil then
    return nil, "invalid_event"
  end

  local record = {
    format = FORMAT,
    v = 1,
    event = name,
  }

  local kind = event.kind
  if kind == "argv" then
    local argv, truncated = sanitize_argv(event.program, event.args, counter)
    if not argv then
      return nil, "hash_unavailable"
    end
    record.kind = "argv"
    record.argv = argv
    record.command_truncated = truncated == true

    -- The hash covers the unredacted command so two events can be correlated
    -- without storing the value. It is not reversible by the audit reader.
    local identity = "argv\0" .. tostring(event.program or "") .. "\0"
    for _, arg in ipairs(event.args or {}) do
      identity = identity .. tostring(arg) .. "\0"
    end
    record.command_hash = digest(identity)
    if not record.command_hash then
      return nil, "hash_unavailable"
    end
  elseif kind == "shell" then
    local shell, truncated = sanitize_shell(event.shell, counter)
    if not shell then
      return nil, "hash_unavailable"
    end
    record.kind = "shell"
    record.shell = shell
    record.command_truncated = truncated == true
    record.command_hash = digest("shell\0" .. tostring(event.shell or ""))
    if not record.command_hash then
      return nil, "hash_unavailable"
    end
  elseif kind ~= nil then
    return nil, "invalid_event"
  end

  for _, field in ipairs({ "role", "agent", "task", "tool" }) do
    local value = sanitize_meta(event[field], LIMITS.MAX_METADATA_BYTES, counter)
    if value then
      record[field] = value
    end
  end
  local intent = sanitize_meta(event.intent, LIMITS.MAX_INTENT_BYTES, counter)
  if intent then
    record.intent = intent
  end
  local cwd = sanitize_meta(event.cwd, LIMITS.MAX_CWD_BYTES, counter)
  if cwd then
    record.cwd = cwd
  end
  local reason = sanitize_meta(event.reason, LIMITS.MAX_REASON_BYTES, counter)
  if reason then
    record.reason = reason
  end

  if event.decision == "allow" or event.decision == "deny" then
    record.decision = event.decision
  elseif event.decision ~= nil then
    return nil, "invalid_event"
  end
  if type(event.high_risk) == "boolean" then
    record.high_risk = event.high_risk
  end
  if type(event.spawned) == "boolean" then
    record.spawned = event.spawned
  end
  if event.cleanup ~= nil then
    if not CLEANUP_VALUES[event.cleanup] then
      return nil, "invalid_event"
    end
    record.cleanup = event.cleanup
  end
  if event.outcome ~= nil then
    if not OUTCOME_VALUES[event.outcome] then
      return nil, "invalid_event"
    end
    record.outcome = event.outcome
  end
  if type(event.exit_code) == "number" and event.exit_code >= 0
    and event.exit_code <= 255 and event.exit_code % 1 == 0 then
    record.exit_code = event.exit_code
  end
  if type(event.duration_ms) == "number" and event.duration_ms >= 0
    and event.duration_ms <= 86400000 and event.duration_ms % 1 == 0 then
    record.duration_ms = event.duration_ms
  end
  if event.timed_out == true then
    record.timed_out = true
  end
  if event.truncated == true then
    record.truncated = true
  end
  if counter.n > 0 then
    record.redactions = counter.n
  end

  return record
end

--- Drop low-value fields until a record fits the 16 KiB bound.
-- @param record table
-- @return boolean changed
local function shrink_record(record)
  if type(record.shell) == "string" and #record.shell > 64 then
    record.shell = record.shell:sub(1, math.floor(#record.shell / 2))
    record.command_truncated = true
    return true
  end
  if type(record.argv) == "table" and #record.argv > 1 then
    table.remove(record.argv)
    record.command_truncated = true
    return true
  end
  for _, field in ipairs({ "intent", "reason", "cwd", "tool", "agent", "role", "task" }) do
    if record[field] ~= nil then
      record[field] = nil
      return true
    end
  end
  return false
end

--- Encode a record without its `hash` field.
-- @param record table
-- @return string? payload
local function payload_without_hash(record)
  local copy = {}
  for key, value in pairs(record) do
    if key ~= "hash" then
      copy[key] = value
    end
  end
  return encode(copy)
end

--- Verify one decoded record's self-hash.
-- @param record table
-- @return boolean
local function verify_record_hash(record)
  if type(record) ~= "table" or type(record.hash) ~= "string" then
    return false
  end
  local claimed = record.hash
  local payload = payload_without_hash(record)
  if not payload then
    return false
  end
  local computed = digest(payload)
  return computed ~= nil and computed == claimed
end

-- ---------------------------------------------------------------------------
-- Filesystem helpers
-- ---------------------------------------------------------------------------

local function normalize_absolute(path)
  if type(path) ~= "string" or path == "" or #path > MAX_PATH_BYTES then
    return nil
  end
  if path:find("[%z\n\r]") or path:sub(1, 1) ~= "/" then
    return nil
  end
  path = path:gsub("/+", "/")
  if path ~= "/" then
    path = path:gsub("/$", "")
  end
  if path == "/" then
    return nil
  end
  for segment in path:gmatch("[^/]+") do
    if segment == "." or segment == ".." then
      return nil
    end
  end
  return path
end

--- Verify (and repair) the audit directory as owned 0700.
-- @param fs table WheelHost.fs
-- @param dir string
-- @return boolean ok
local function ensure_directory(fs, dir)
  local info = fs.stat(dir)
  if info.exists and (info.symlink or not info.directory) then
    return false
  end
  local created = fs.mkdir_p(dir)
  if not created then
    return false
  end
  local chmod_ok = fs.chmod(dir, "700")
  if not chmod_ok then
    return false
  end
  info = fs.stat(dir)
  if not info.exists or info.symlink or not info.directory or info.mode ~= DIR_MODE then
    return false
  end
  local euid = fs.euid()
  if euid == nil or info.uid ~= euid then
    return false
  end
  return true
end

--- Verify one path is an owned, singly linked, mode-0600 regular file.
-- @param fs table WheelHost.fs
-- @param path string
-- @return boolean ok
local function verify_private_file(fs, path)
  local info = fs.stat(path)
  if not info.exists or info.symlink or not info.regular then
    return false
  end
  if info.mode ~= FILE_MODE or info.links ~= 1 then
    return false
  end
  local euid = fs.euid()
  if euid == nil or info.uid ~= euid then
    return false
  end
  return true
end

--- Report whether a path exists and whether it is a safe audit file.
-- @param fs table WheelHost.fs
-- @param path string
-- @return boolean exists, boolean unsafe
local function private_exists(fs, path)
  local info = fs.stat(path)
  if not info.exists then
    return false, false
  end
  if info.symlink or not info.regular or info.mode ~= FILE_MODE or info.links ~= 1 then
    return true, true
  end
  return true, false
end

-- ---------------------------------------------------------------------------
-- Sink
-- ---------------------------------------------------------------------------

local Sink = {}
Sink.__index = Sink

function Sink:_active_path()
  return self.dir .. "/audit.jsonl"
end

function Sink:_rotated_path(index)
  return self.dir .. "/audit." .. tostring(index) .. ".jsonl"
end

--- Parse and verify the last complete record in a file body.
-- @param content string
-- @return table? record, string? reason
local function parse_tail(content)
  if type(content) ~= "string" or content == "" then
    return nil
  end
  if content:sub(-1) ~= "\n" then
    return nil, "audit_corrupt"
  end
  local last_line
  for line in content:gmatch("([^\n]*)\n") do
    if line ~= "" then
      last_line = line
    end
  end
  if not last_line then
    return nil
  end
  local record = decode(last_line)
  if type(record) ~= "table"
    or type(record.seq) ~= "number"
    or record.seq < 0
    or record.seq % 1 ~= 0
    or type(record.hash) ~= "string"
    or #record.hash ~= 64 then
    return nil, "audit_corrupt"
  end
  if not verify_record_hash(record) then
    return nil, "audit_corrupt"
  end
  return record
end

--- Read the newest retained rotated file and return its tail record.
-- @param fs table
-- @return table? record, string? reason
function Sink:_tail_from_rotated(fs)
  local max_rotated = self.limits.max_files - 1
  for index = 1, max_rotated do
    local path = self:_rotated_path(index)
    local exists, unsafe = private_exists(fs, path)
    if unsafe then
      return nil, "audit_file"
    end
    if exists then
      if not verify_private_file(fs, path) then
        return nil, "audit_file"
      end
      local content = fs.read_file_bounded(
        path, self.limits.max_file_bytes + LIMITS.MAX_RECORD_BYTES + 1)
      if content == nil then
        return nil, "audit_file"
      end
      if content ~= "" then
        return parse_tail(content)
      end
    end
  end
  return nil
end

--- Create/repair the directory and recover sequence state from the tail.
-- @return boolean ok, string? reason
function Sink:_prepare()
  if self._ready then
    return true
  end
  local fs = host()
  if not fs or type(fs.fs) ~= "table" then
    return false, "audit_directory"
  end
  fs = fs.fs

  if not ensure_directory(fs, self.dir) then
    return false, "audit_directory"
  end

  local active = self:_active_path()
  local info = fs.stat(active)
  local active_exists = info.exists
  if not active_exists then
    if not fs.create_private_file(active, "") then
      return false, "audit_file"
    end
    info = fs.stat(active)
    active_exists = info.exists
  end
  if active_exists then
    if info.symlink or not info.regular then
      return false, "audit_file"
    end
    if not verify_private_file(fs, active) then
      return false, "audit_file"
    end
    local content = fs.read_file_bounded(
      active, self.limits.max_file_bytes + LIMITS.MAX_RECORD_BYTES + 1)
    if content == nil then
      return false, "audit_file"
    end
    if #content > self.limits.max_file_bytes + LIMITS.MAX_RECORD_BYTES then
      return false, "audit_file"
    end
    self._size = #content
    if content ~= "" then
      local tail, reason = parse_tail(content)
      if not tail then
        return false, reason or "audit_corrupt"
      end
      self._seq = tail.seq
      self._prev = tail.hash
    end
  end

  if not active_exists or self._size == 0 then
    local tail, reason = self:_tail_from_rotated(fs)
    if reason then
      return false, reason
    end
    if tail then
      self._seq = tail.seq
      self._prev = tail.hash
    end
  end

  self._ready = true
  return true
end

--- Rotate active -> .1 -> ... and drop the oldest retained file.
-- @return boolean ok, string? reason
function Sink:_rotate()
  local fs = host().fs
  local max_rotated = self.limits.max_files - 1
  local active = self:_active_path()

  local oldest = self:_rotated_path(max_rotated)
  local oldest_exists, oldest_unsafe = private_exists(fs, oldest)
  if oldest_unsafe then
    return false, "rotation_failed"
  end
  if oldest_exists then
    if not verify_private_file(fs, oldest) or not fs.remove_file(oldest) then
      return false, "rotation_failed"
    end
  end

  for index = max_rotated - 1, 1, -1 do
    local source = self:_rotated_path(index)
    local target = self:_rotated_path(index + 1)
    local source_exists, source_unsafe = private_exists(fs, source)
    local target_exists, target_unsafe = private_exists(fs, target)
    if source_unsafe or target_unsafe or (source_exists and target_exists) then
      return false, "rotation_failed"
    end
    if source_exists then
      if not verify_private_file(fs, source) or not fs.rename(source, target) then
        return false, "rotation_failed"
      end
    end
  end

  local active_exists, active_unsafe = private_exists(fs, active)
  if active_unsafe or not active_exists then
    return false, "rotation_failed"
  end
  if not verify_private_file(fs, active) or not fs.rename(active, self:_rotated_path(1)) then
    return false, "rotation_failed"
  end
  if not fs.create_private_file(active, "") then
    return false, "rotation_failed"
  end
  if not verify_private_file(fs, active) then
    return false, "rotation_failed"
  end
  self._size = 0
  return true
end

--- Append one event to the stream.
-- @param event table
-- @return boolean ok, table? err, string? reason
function Sink:record(event)
  local prepared, prepare_reason = self:_prepare()
  if not prepared then
    return audit_failure(prepare_reason)
  end

  local host_module = host()
  local ok_now, now = pcall(host_module.time.now)
  if not ok_now or type(now) ~= "number" or now < 0 then
    return audit_failure("audit_directory")
  end

  local counter = { n = 0 }
  local record, build_reason = build_record(event, counter)
  if not record then
    return audit_failure(build_reason or "invalid_event")
  end
  record.ts_ms = math.floor(now * 1000)
  record.seq = self._seq + 1
  record.prev = self._prev

  local payload = payload_without_hash(record)
  if not payload then
    return audit_failure("hash_unavailable")
  end

  -- Reserve room for the `,"hash":"<64 hex>"` member when deciding whether a
  -- payload fits; the final check is against the complete encoded line so a
  -- record (not counting the separating newline) never exceeds 16 KiB.
  local hash_reserve = 96
  local record_hash
  local line
  while true do
    if #payload + hash_reserve > LIMITS.MAX_RECORD_BYTES then
      if not shrink_record(record) then
        return audit_failure("record_too_large")
      end
      payload = payload_without_hash(record)
      if not payload then
        return audit_failure("hash_unavailable")
      end
    else
      record_hash = digest(payload)
      if not record_hash then
        return audit_failure("hash_unavailable")
      end
      record.hash = record_hash
      line = encode(record)
      record.hash = nil
      if not line then
        return audit_failure("hash_unavailable")
      end
      if #line <= LIMITS.MAX_RECORD_BYTES then
        break
      end
      if not shrink_record(record) then
        return audit_failure("record_too_large")
      end
      payload = payload_without_hash(record)
      if not payload then
        return audit_failure("hash_unavailable")
      end
    end
  end
  record.hash = record_hash
  line = line .. "\n"

  if self._size > 0 and self._size + #line > self.limits.max_file_bytes then
    local rotated, rotation_reason = self:_rotate()
    if not rotated then
      return audit_failure(rotation_reason)
    end
  end

  local wrote = host_module.fs.append_file(self:_active_path(), line)
  if not wrote then
    -- Force a re-read on the next attempt: a partial append must be seen as a
    -- torn tail instead of silently extending an unverified line.
    self._ready = false
    return audit_failure("write_failed")
  end

  self._seq = record.seq
  self._prev = record_hash
  self._size = self._size + #line
  return true
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

local function env_value(opts, name)
  if type(opts) == "table" and type(opts.env) == "table" then
    return opts.env[name]
  end
  return os.getenv(name)
end

--- Resolve the audit directory without creating it.
-- Precedence: explicit `opts.dir`, `$XDG_STATE_HOME/wheel/audit`,
-- `$HOME/.local/state/wheel/audit`. A relative or malformed XDG/HOME base is a
-- failure rather than a silent write to the current directory.
-- @param opts table? { dir = string?, env = table? }
-- @return string? dir, table? err, string? reason
function WheelAudit.resolve_dir(opts)
  if type(opts) == "table" and opts.dir ~= nil then
    local explicit = normalize_absolute(opts.dir)
    if not explicit then
      return audit_failure("no_state_dir")
    end
    return explicit
  end

  local state = env_value(opts, "XDG_STATE_HOME")
  if state ~= nil and state ~= "" then
    local base = normalize_absolute(state)
    if not base then
      return audit_failure("no_state_dir")
    end
    return base .. "/wheel/audit"
  end

  local home = env_value(opts, "HOME")
  if home ~= nil and home ~= "" then
    local base = normalize_absolute(home)
    if not base then
      return audit_failure("no_state_dir")
    end
    return base .. "/.local/state/wheel/audit"
  end

  return audit_failure("no_state_dir")
end

local function merge_limits(overrides)
  local limits = {
    max_record_bytes = LIMITS.MAX_RECORD_BYTES,
    max_file_bytes = LIMITS.MAX_FILE_BYTES,
    max_files = LIMITS.MAX_FILES,
  }
  if type(overrides) == "table" then
    -- Only the rotation knobs are overridable, and only through an explicit
    -- embedding/test constructor. The record bound is fixed.
    local file_bytes = overrides.max_file_bytes
    if type(file_bytes) == "number" and file_bytes % 1 == 0
      and file_bytes >= 256 and file_bytes <= LIMITS.MAX_FILE_BYTES then
      limits.max_file_bytes = file_bytes
    end
    local files = overrides.max_files
    if type(files) == "number" and files % 1 == 0 and files >= 2 and files <= 16 then
      limits.max_files = files
    end
  end
  return limits
end

--- Create a sink for an explicit directory.
-- The constructor does not touch the filesystem; the first `record` creates or
-- repairs the directory and recovers the sequence tail.
-- @param opts table { dir = string, limits = table? }
-- @return table? sink, table? err, string? reason
function WheelAudit.new(opts)
  if type(opts) ~= "table" then
    return audit_failure("no_state_dir")
  end
  local dir = normalize_absolute(opts.dir)
  if not dir then
    return audit_failure("no_state_dir")
  end
  local sink = setmetatable({
    dir = dir,
    limits = merge_limits(opts.limits),
    _ready = false,
    _seq = 0,
    _prev = ZERO_HASH,
    _size = 0,
  }, Sink)
  return sink
end

local sinks = {}

--- Record one event through the process-wide sink for its directory.
-- @param event table
-- @param opts table? { dir, env, limits }
-- @return boolean ok, table? err, string? reason
function WheelAudit.record(event, opts)
  local dir, resolve_err, resolve_reason = WheelAudit.resolve_dir(opts)
  if not dir then
    return nil, resolve_err, resolve_reason
  end
  local sink = sinks[dir]
  if not sink then
    local created, create_err, create_reason =
      WheelAudit.new({ dir = dir, limits = type(opts) == "table" and opts.limits or nil })
    if not created then
      return nil, create_err, create_reason
    end
    sink = created
    sinks[dir] = sink
  end
  return sink:record(event)
end

--- Forget cached sinks (tests and long-lived embedders after a directory swap).
function WheelAudit.reset()
  sinks = {}
end

--- Verify the retained chain without writing.
-- Files are read oldest to newest; a first retained record may reference a
-- pruned predecessor. Every later record must continue the sequence and name
-- the previous record's hash.
-- @param opts table? { dir, env, limits }
-- @return table? result { records = n, files = n }, table? err, string? reason, string? detail
function WheelAudit.verify(opts)
  local dir, resolve_err, resolve_reason = WheelAudit.resolve_dir(opts)
  if not dir then
    return nil, resolve_err, resolve_reason, nil
  end
  local sink = WheelAudit.new({
    dir = dir,
    limits = type(opts) == "table" and opts.limits or nil,
  })
  if not sink then
    return audit_failure("no_state_dir")
  end
  local fs = host()
  if not fs or type(fs.fs) ~= "table" then
    return audit_failure("audit_directory")
  end
  fs = fs.fs

  local paths = {}
  for index = sink.limits.max_files - 1, 1, -1 do
    paths[#paths + 1] = sink:_rotated_path(index)
  end
  paths[#paths + 1] = sink:_active_path()

  local last_seq = nil
  local last_hash = nil
  local records = 0
  local files = 0
  for _, path in ipairs(paths) do
    local exists, unsafe = private_exists(fs, path)
    if unsafe then
      return audit_failure("audit_file")
    end
    if exists then
      if not verify_private_file(fs, path) then
        return audit_failure("audit_file")
      end
      local content = fs.read_file_bounded(
        path, sink.limits.max_file_bytes + LIMITS.MAX_RECORD_BYTES + 1)
      if content == nil then
        return audit_failure("audit_file")
      end
      if #content > sink.limits.max_file_bytes + LIMITS.MAX_RECORD_BYTES then
        return audit_failure("record_too_large")
      end
      if content ~= "" and content:sub(-1) ~= "\n" then
        return audit_failure("audit_corrupt")
      end
      files = files + 1
      local line_number = 0
      for line in content:gmatch("([^\n]*)\n") do
        line_number = line_number + 1
        if line ~= "" then
          local record = decode(line)
          if type(record) ~= "table"
            or type(record.seq) ~= "number"
            or record.seq % 1 ~= 0
            or type(record.hash) ~= "string"
            or #record.hash ~= 64
            or not verify_record_hash(record) then
            return nil, WheelErrors.audit_unavailable(), "audit_corrupt",
              "line " .. tostring(line_number)
          end
          if last_seq ~= nil and record.seq ~= last_seq + 1 then
            return nil, WheelErrors.audit_unavailable(), "audit_corrupt",
              "line " .. tostring(line_number)
          end
          if last_hash ~= nil and record.prev ~= last_hash then
            return nil, WheelErrors.audit_unavailable(), "audit_corrupt",
              "line " .. tostring(line_number)
          end
          last_seq = record.seq
          last_hash = record.hash
          records = records + 1
        end
      end
    end
  end

  return {
    records = records,
    files = files,
    last_seq = last_seq,
    last_hash = last_hash,
  }
end

return WheelAudit
