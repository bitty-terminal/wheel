-- lua/wheel/session.lua
-- Wheel: local session control plane (client side and shared protocol).
--
-- A Wheel session daemon is a detached per-user process that owns a
-- WheelContext and exposes a small request/response control plane over two
-- POSIX FIFOs in a private per-session runtime directory. This module owns the
-- wire protocol, bounded JSON codec, session-name and path validation,
-- metadata, client-side serialization lock, and the client RPC used by
-- `scripts/wheel-session`.
--
-- Wire format (protocol marker `wheel-session/1`):
--
--   request   one JSON object followed by `\n`, at most 64 KiB
--   response  one JSON object followed by `\n`, at most 1 MiB
--
-- Every request carries `protocol`, `id`, `method`, and optional `params`.
-- Every response echoes `protocol`, `id`, and `method` and carries either
-- `result` or a static three-field `error` (`class`, `code`, `message`).
-- A frame is never parsed before its newline-terminated size is bounded.
--
-- Serialization: one client lock file per session is created exclusively
-- before the FIFOs are opened. A second client fails with `E_SESSION_BUSY`
-- instead of interleaving frames. Stale-lock reclamation is serialized by a
-- short-lived per-lock mutex: the dead owner's path is renamed and verified
-- before removal, and the replacement is created before the mutex is released.
-- The daemon never signals a client and the client never signals the daemon:
-- shutdown is an explicit method.
--
-- Same-user residual: POSIX FIFOs carry no peer credentials in pure Lua. File
-- mode 0700/0600 prevents *other* users from reaching the control plane, but
-- any process running as the session owner can write requests. The control
-- plane therefore grants no authority beyond what the owner already has, and
-- it must not be described as multi-user authentication. See SECURITY-MODEL.md.

local WheelHost = require("wheel.host")

local Session = {}

-- ---------------------------------------------------------------------------
-- Constants
-- ---------------------------------------------------------------------------

Session.PROTOCOL = "wheel-session/1"
Session.APP_DIR = "wheel"
Session.SESSIONS_DIR = "sessions"

Session.MAX_SESSION_NAME_BYTES = 32
Session.SESSION_NAME_PATTERN = "^[a-z0-9][a-z0-9_-]*$"
Session.MAX_REQUEST_BYTES = 64 * 1024
Session.MAX_RESPONSE_BYTES = 1024 * 1024
Session.MAX_DRAIN_BYTES = 1024 * 1024
Session.MAX_METADATA_BYTES = 8 * 1024
Session.MAX_LOCK_BYTES = 128
Session.MAX_PATH_BYTES = 4096
Session.MAX_CONTEXT_NAME_BYTES = 256
Session.MAX_CONTEXT_CONTENT_BYTES = 48 * 1024
Session.MAX_CONTEXT_SLOTS = 1024
Session.MAX_CONTEXT_TOTAL_BYTES = 16 * 1024 * 1024
Session.MAX_LIST_SLOTS = 1024
Session.MAX_SNAPSHOT_SLOTS = 1024
Session.MAX_STALE_RESPONSES = 8
Session.MAX_LOCK_ATTEMPTS = 4
Session.MAX_JSON_DEPTH = 32
Session.MAX_ID_BYTES = 64

Session.FILE_META = "meta.json"
Session.FILE_REQUEST = "request.fifo"
Session.FILE_RESPONSE = "response.fifo"
Session.FILE_CLIENT_LOCK = "client.lock"
Session.FILE_START_LOCK = "start.lock"

Session.ERROR_CODES = {
  E_SESSION_INVALID_NAME = true,
  E_SESSION_INVALID_ROOT = true,
  E_SESSION_UNSAFE_PATH = true,
  E_SESSION_LOCK_UNSAFE = true,
  E_SESSION_NOT_FOUND = true,
  E_SESSION_NOT_RUNNING = true,
  E_SESSION_ALREADY_RUNNING = true,
  E_SESSION_UNRESPONSIVE = true,
  E_SESSION_BUSY = true,
  E_SESSION_METADATA_INVALID = true,
  E_SESSION_PROTOCOL = true,
  E_SESSION_FRAME_TOO_LARGE = true,
  E_SESSION_RESPONSE_TOO_LARGE = true,
  E_SESSION_METHOD_UNKNOWN = true,
  E_SESSION_ARGS_INVALID = true,
  E_SESSION_IO = true,
  E_SESSION_START_FAILED = true,
  E_SESSION_CAS_CONFLICT = true,
  E_SESSION_CONTEXT_ERROR = true,
  E_SESSION_CONTEXT_LIMIT = true,
}

local METHODS = {
  ping = true,
  ["session.status"] = true,
  ["session.snapshot"] = true,
  ["context.put"] = true,
  ["context.get"] = true,
  ["context.list"] = true,
  shutdown = true,
}

Session.METHODS = METHODS

-- ---------------------------------------------------------------------------
-- Typed session errors (the accepted three-field bridge shape)
-- ---------------------------------------------------------------------------

local MESSAGE_MAX_LENGTH = 160

--- Build a static, bounded, single-line session error.
-- Messages are constants or numeric/bounded values; request content is never
-- interpolated, so a crafted slot name cannot forge a log line or leak data.
-- @param code string `E_SESSION_*`
-- @param message string
-- @param class string? "runtime" or "validation"
-- @return table
local function session_error(code, message, class)
  local text = tostring(message or "session error"):gsub("[\r\n]", " ")
  if #text > MESSAGE_MAX_LENGTH then
    text = text:sub(1, MESSAGE_MAX_LENGTH - 3) .. "..."
  end
  return {
    class = class or "runtime",
    code = code,
    message = text,
  }
end

Session.error = session_error

local function err_invalid_name()
  return session_error(
    "E_SESSION_INVALID_NAME",
    "session name must match [a-z0-9][a-z0-9_-]{0,31}",
    "validation"
  )
end

local function err_invalid_root()
  return session_error("E_SESSION_INVALID_ROOT", "session root is not a safe absolute path", "validation")
end

local function err_unsafe_path()
  return session_error("E_SESSION_UNSAFE_PATH", "session path failed the private-path check")
end

local function err_lock_unsafe()
  return session_error("E_SESSION_LOCK_UNSAFE", "session lock path failed the private-path check")
end

local function err_not_running()
  return session_error("E_SESSION_NOT_RUNNING", "session is not running")
end

local function err_already_running()
  return session_error("E_SESSION_ALREADY_RUNNING", "session is already running")
end

local function err_unresponsive()
  return session_error(
    "E_SESSION_UNRESPONSIVE",
    "session metadata reports a live pid but the control plane did not answer"
  )
end

local function err_busy()
  return session_error("E_SESSION_BUSY", "session control plane is busy")
end

local function err_metadata_invalid()
  return session_error("E_SESSION_METADATA_INVALID", "session metadata is invalid")
end

local function err_protocol()
  return session_error("E_SESSION_PROTOCOL", "request does not match the wheel-session/1 protocol")
end

local function err_frame_too_large()
  return session_error(
    "E_SESSION_FRAME_TOO_LARGE",
    string.format("request frame exceeds the %d byte bound", Session.MAX_REQUEST_BYTES),
    "validation"
  )
end

local function err_response_too_large()
  return session_error(
    "E_SESSION_RESPONSE_TOO_LARGE",
    string.format("response frame exceeds the %d byte bound", Session.MAX_RESPONSE_BYTES)
  )
end

local function err_method_unknown()
  return session_error("E_SESSION_METHOD_UNKNOWN", "unknown session method", "validation")
end

local function err_args_invalid()
  return session_error("E_SESSION_ARGS_INVALID", "invalid session method arguments", "validation")
end

local function err_io()
  return session_error("E_SESSION_IO", "session control-plane I/O failed")
end

local function err_start_failed()
  return session_error("E_SESSION_START_FAILED", "session daemon did not become ready")
end

local function err_cas_conflict(expected, current)
  return session_error(
    "E_SESSION_CAS_CONFLICT",
    string.format("context version conflict: expected %d, current is %d", expected, current)
  )
end

local function err_context_error()
  return session_error("E_SESSION_CONTEXT_ERROR", "context operation failed")
end

Session.err_not_running = err_not_running
Session.err_already_running = err_already_running
Session.err_unsafe_path = err_unsafe_path
Session.err_metadata_invalid = err_metadata_invalid
Session.err_protocol = err_protocol
Session.err_frame_too_large = err_frame_too_large
Session.err_response_too_large = err_response_too_large
Session.err_method_unknown = err_method_unknown
Session.err_args_invalid = err_args_invalid
Session.err_io = err_io
Session.err_start_failed = err_start_failed

-- ---------------------------------------------------------------------------
-- Bounded strict JSON codec
-- ---------------------------------------------------------------------------

local JSON = {}

local ARRAY_MT = {}

--- Mark a table as a JSON array even when it is empty.
-- @param value table
-- @return table
function Session.array(value)
  return setmetatable(value or {}, ARRAY_MT)
end

local ESCAPES = {
  ['"'] = '\\"',
  ["\\"] = "\\\\",
  ["\b"] = "\\b",
  ["\f"] = "\\f",
  ["\n"] = "\\n",
  ["\r"] = "\\r",
  ["\t"] = "\\t",
}

local function encode_string(value)
  local out = value:gsub('[%z\1-\31\\"]', function(char)
    local mapped = ESCAPES[char]
    if mapped then
      return mapped
    end
    return string.format("\\u%04x", string.byte(char))
  end)
  return '"' .. out .. '"'
end

local function encode_value(value, depth)
  if depth > Session.MAX_JSON_DEPTH then
    error("json encode depth exceeded", 0)
  end
  local kind = type(value)
  if kind == "nil" then
    return "null"
  elseif kind == "boolean" then
    return value and "true" or "false"
  elseif kind == "number" then
    if value ~= value or value == math.huge or value == -math.huge then
      error("json encode rejected a non-finite number", 0)
    end
    if value % 1 == 0 and math.abs(value) < 1e15 then
      return string.format("%d", value)
    end
    return string.format("%.17g", value)
  elseif kind == "string" then
    return encode_string(value)
  elseif kind ~= "table" then
    error("json encode rejected an unsupported value", 0)
  end

  local count, max_index = 0, 0
  local array = true
  local keys = {}
  for key in pairs(value) do
    count = count + 1
    if type(key) == "number" and key % 1 == 0 and key >= 1 then
      if key > max_index then
        max_index = key
      end
    else
      array = false
    end
    keys[#keys + 1] = key
  end
  if count == 0 and getmetatable(value) ~= ARRAY_MT then
    -- An empty unmarked table is an object; an explicit array stays `[]`.
    array = false
  end
  if array and max_index == count then
    local parts = {}
    for index = 1, count do
      parts[index] = encode_value(value[index], depth + 1)
    end
    return "[" .. table.concat(parts, ",") .. "]"
  end

  table.sort(keys, function(left, right)
    return tostring(left) < tostring(right)
  end)
  local parts = {}
  for _, key in ipairs(keys) do
    if type(key) ~= "string" then
      error("json encode requires string object keys", 0)
    end
    parts[#parts + 1] = encode_string(key) .. ":" .. encode_value(value[key], depth + 1)
  end
  return "{" .. table.concat(parts, ",") .. "}"
end

--- Encode a Lua value as bounded JSON. Raises on unsupported values.
-- @param value any
-- @return string
function JSON.encode(value)
  return encode_value(value, 0)
end

Session.json_encode = JSON.encode

local function decode_error()
  error("invalid json", 0)
end

local function skip_whitespace(text, position)
  local _, stop = text:find("^[ \t\r\n]+", position)
  if stop then
    return stop + 1
  end
  return position
end

local function utf8_char(code)
  if code < 0x80 then
    return string.char(code)
  elseif code < 0x800 then
    return string.char(0xC0 + math.floor(code / 0x40), 0x80 + code % 0x40)
  elseif code < 0x10000 then
    return string.char(
      0xE0 + math.floor(code / 0x1000),
      0x80 + math.floor(code / 0x40) % 0x40,
      0x80 + code % 0x40
    )
  end
  return string.char(
    0xF0 + math.floor(code / 0x40000),
    0x80 + math.floor(code / 0x1000) % 0x40,
    0x80 + math.floor(code / 0x40) % 0x40,
    0x80 + code % 0x40
  )
end

local function decode_string(text, position)
  local index = position + 1
  local length = #text
  local parts = {}
  while index <= length do
    local char = text:sub(index, index)
    local byte = text:byte(index)
    if char == '"' then
      return table.concat(parts), index + 1
    elseif char == "\\" then
      index = index + 1
      local escaped = text:sub(index, index)
      local mapped = {
        ['"'] = '"',
        ["\\"] = "\\",
        ["/"] = "/",
        b = "\b",
        f = "\f",
        n = "\n",
        r = "\r",
        t = "\t",
      }
      if mapped[escaped] then
        parts[#parts + 1] = mapped[escaped]
      elseif escaped == "u" then
        local hex = text:sub(index + 1, index + 4)
        if #hex ~= 4 or not hex:match("^%x%x%x%x$") then
          decode_error()
        end
        local code = tonumber(hex, 16)
        index = index + 4
        if code >= 0xD800 and code <= 0xDBFF then
          if text:sub(index + 1, index + 2) ~= "\\u" then
            decode_error()
          end
          local low_hex = text:sub(index + 3, index + 6)
          if #low_hex ~= 4 or not low_hex:match("^%x%x%x%x$") then
            decode_error()
          end
          local low = tonumber(low_hex, 16)
          if low < 0xDC00 or low > 0xDFFF then
            decode_error()
          end
          code = 0x10000 + (code - 0xD800) * 0x400 + (low - 0xDC00)
          index = index + 6
        elseif code >= 0xDC00 and code <= 0xDFFF then
          decode_error()
        end
        parts[#parts + 1] = utf8_char(code)
      else
        decode_error()
      end
    elseif byte < 0x20 then
      decode_error()
    else
      parts[#parts + 1] = char
    end
    index = index + 1
  end
  decode_error()
end

local function decode_number(text, position)
  local number_text = text:match("^-?%d+", position)
  if not number_text then
    decode_error()
  end
  local stop = position + #number_text - 1
  local dot = text:match("^%.%d+", stop + 1)
  if dot then
    number_text = number_text .. dot
    stop = stop + #dot
  end
  local exponent = text:match("^[eE][+-]?%d+", stop + 1)
  if exponent then
    number_text = number_text .. exponent
    stop = stop + #exponent
  end
  local number = tonumber(number_text)
  if number == nil or number ~= number or number == math.huge or number == -math.huge then
    decode_error()
  end
  return number, stop + 1
end

local decode_value

local function decode_array(text, position, depth)
  local items = {}
  position = skip_whitespace(text, position + 1)
  if text:sub(position, position) == "]" then
    return items, position + 1
  end
  while true do
    local value
    value, position = decode_value(text, position, depth + 1)
    items[#items + 1] = value
    position = skip_whitespace(text, position)
    local char = text:sub(position, position)
    if char == "]" then
      return items, position + 1
    elseif char ~= "," then
      decode_error()
    end
    position = skip_whitespace(text, position + 1)
  end
end

local function decode_object(text, position, depth)
  local object = {}
  position = skip_whitespace(text, position + 1)
  if text:sub(position, position) == "}" then
    return object, position + 1
  end
  while true do
    if text:sub(position, position) ~= '"' then
      decode_error()
    end
    local key
    key, position = decode_string(text, position)
    position = skip_whitespace(text, position)
    if text:sub(position, position) ~= ":" then
      decode_error()
    end
    position = skip_whitespace(text, position + 1)
    local value
    value, position = decode_value(text, position, depth + 1)
    object[key] = value
    position = skip_whitespace(text, position)
    local char = text:sub(position, position)
    if char == "}" then
      return object, position + 1
    elseif char ~= "," then
      decode_error()
    end
    position = skip_whitespace(text, position + 1)
  end
end

decode_value = function(text, position, depth)
  if depth > Session.MAX_JSON_DEPTH then
    decode_error()
  end
  position = skip_whitespace(text, position)
  local char = text:sub(position, position)
  if char == '"' then
    return decode_string(text, position)
  elseif char == "{" then
    return decode_object(text, position, depth)
  elseif char == "[" then
    return decode_array(text, position, depth)
  elseif text:sub(position, position + 3) == "true" then
    return true, position + 4
  elseif text:sub(position, position + 4) == "false" then
    return false, position + 5
  elseif text:sub(position, position + 3) == "null" then
    return nil, position + 4
  end
  return decode_number(text, position)
end

--- Decode one strict JSON document. Trailing non-whitespace is rejected.
-- @param text string
-- @return any
function JSON.decode(text)
  if type(text) ~= "string" then
    decode_error()
  end
  local value, position = decode_value(text, 1, 0)
  position = skip_whitespace(text, position)
  if position <= #text then
    decode_error()
  end
  return value
end

Session.json_decode = JSON.decode

-- ---------------------------------------------------------------------------
-- Path, name, and identity validation
-- ---------------------------------------------------------------------------

local function has_control_char(value)
  return value:find("[%z\1-\31\127]") ~= nil
end

--- Validate a session name (`[a-z0-9][a-z0-9_-]{0,31}`).
-- @param name any
-- @return boolean ok, table? err
function Session.validate_name(name)
  if type(name) ~= "string"
    or #name == 0
    or #name > Session.MAX_SESSION_NAME_BYTES
    or not name:match(Session.SESSION_NAME_PATTERN) then
    return false, err_invalid_name()
  end
  return true, nil
end

--- Validate an absolute runtime path with no traversal segments.
-- @param path any
-- @return boolean ok, table? err
function Session.validate_absolute_path(path)
  if type(path) ~= "string"
    or #path == 0
    or #path > Session.MAX_PATH_BYTES
    or path:sub(1, 1) ~= "/"
    or path == "/"
    or has_control_char(path) then
    return false, err_invalid_root()
  end
  if path:sub(-1) == "/" then
    return false, err_invalid_root()
  end
  for segment in path:gmatch("[^/]+") do
    if segment:match("^%.+$") then
      return false, err_invalid_root()
    end
  end
  return true, nil
end

-- Environment lookup follows the existing WheelConfig/provider precedent: the
-- host seam currently owns filesystem, process, temporary-file, and time
-- primitives, not environment lookup. A missing os.getenv surface is treated as
-- an absent variable, never as a silent empty root (validation rejects nil).
local function getenv(name)
  if type(os) ~= "table" or type(os.getenv) ~= "function" then
    return nil
  end
  return os.getenv(name)
end

--- Resolve the private session root.
-- `WHEEL_SESSION_ROOT` (or `opts.root`) overrides; otherwise the XDG runtime
-- directory is preferred, then XDG state, then the home state directory.
-- @param opts table? { root = string? }
-- @return string? root, table? err
function Session.resolve_root(opts)
  opts = type(opts) == "table" and opts or {}
  local root = opts.root
  if type(root) ~= "string" or root == "" then
    root = getenv("WHEEL_SESSION_ROOT")
  end
  if type(root) ~= "string" or root == "" then
    local runtime = getenv("XDG_RUNTIME_DIR")
    if type(runtime) == "string" and runtime ~= "" then
      root = runtime .. "/" .. Session.APP_DIR .. "/" .. Session.SESSIONS_DIR
    else
      local state = getenv("XDG_STATE_HOME")
      if type(state) == "string" and state ~= "" then
        root = state .. "/" .. Session.APP_DIR .. "/" .. Session.SESSIONS_DIR
      else
        local home = getenv("HOME")
        if type(home) == "string" and home ~= "" then
          root = home .. "/.local/state/" .. Session.APP_DIR .. "/" .. Session.SESSIONS_DIR
        end
      end
    end
  end
  local ok, err = Session.validate_absolute_path(root)
  if not ok then
    return nil, err
  end
  return root
end

local function make_session_dir(root, name)
  return root .. "/" .. name
end

local function stat_path(path)
  local ok, info = pcall(WheelHost.fs.stat, path)
  if not ok then
    return nil, err_io()
  end
  return info
end

local function verify_private_directory(path)
  local info, stat_err = stat_path(path)
  if not info then
    return nil, stat_err
  end
  if not info.exists then
    return nil, err_not_running()
  end
  if info.symlink or not info.directory then
    return nil, err_unsafe_path()
  end
  local euid = WheelHost.fs.euid()
  if euid == nil or info.uid ~= euid then
    return nil, err_unsafe_path()
  end
  if info.mode ~= 448 then
    return nil, err_unsafe_path()
  end
  return info
end

local function ensure_directory(path)
  local info, stat_err = stat_path(path)
  if not info then
    return nil, stat_err
  end
  if not info.exists then
    local created = WheelHost.fs.mkdir_p(path)
    if not created then
      return nil, err_io()
    end
    local chmod_ok = WheelHost.fs.chmod(path, "700")
    if not chmod_ok then
      return nil, err_unsafe_path()
    end
  end
  return verify_private_directory(path)
end

--- Ensure the session root exists and is private (mode 0700, owner only).
-- The immediate parent is also required to be a real directory owned by the
-- current user; a symlinked or foreign-owned parent is refused before the
-- session root is created. An existing root with a weaker mode is refused; a
-- newly created root is chmodded to 0700 and re-verified.
-- @param root string
-- @return boolean ok, table? err
function Session.ensure_root(root)
  local ok, err = Session.validate_absolute_path(root)
  if not ok then
    return false, err
  end
  local parent = root:match("^(.*)/[^/]+$")
  if parent and parent ~= "" and parent ~= "/" then
    local parent_info, parent_err = stat_path(parent)
    if not parent_info then
      return false, parent_err
    end
    if parent_info.exists then
      local euid = WheelHost.fs.euid()
      if parent_info.symlink or not parent_info.directory
        or euid == nil or parent_info.uid ~= euid then
        return false, err_unsafe_path()
      end
    end
  end
  local info, dir_err = ensure_directory(root)
  if not info then
    return false, dir_err
  end
  return true, nil
end

--- Ensure one session directory exists and is private.
-- A missing directory is created and chmodded to 0700. An existing directory
-- is never mode-repaired: a weaker mode is refused, because a permissive
-- session directory may have been tampered with.
-- @param session_dir string
-- @param create boolean?
-- @return table? info, table? err
function Session.ensure_session_dir(session_dir, create)
  local ok = Session.validate_absolute_path(session_dir)
  if not ok then
    return nil, err_unsafe_path()
  end
  local info, stat_err = stat_path(session_dir)
  if not info then
    return nil, stat_err
  end
  if not info.exists then
    if not create then
      return nil, err_not_running()
    end
    local created = WheelHost.fs.mkdir_p(session_dir)
    if not created then
      return nil, err_io()
    end
    local chmod_ok = WheelHost.fs.chmod(session_dir, "700")
    if not chmod_ok then
      return nil, err_unsafe_path()
    end
  end
  return verify_private_directory(session_dir)
end

-- ---------------------------------------------------------------------------
-- Metadata
-- ---------------------------------------------------------------------------

local function valid_pid(value)
  return type(value) == "number" and value % 1 == 0 and value > 1
end

local function validate_metadata(meta, expected_name)
  if type(meta) ~= "table" then
    return false
  end
  if meta.protocol ~= Session.PROTOCOL then
    return false
  end
  if type(meta.name) ~= "string" or meta.name ~= expected_name then
    return false
  end
  if not valid_pid(meta.pid) then
    return false
  end
  if type(meta.started_at) ~= "number" or meta.started_at ~= meta.started_at then
    return false
  end
  if type(meta.wheel_version) ~= "string" or not meta.wheel_version:match("^%d+%.%d+%.%d+$") then
    return false
  end
  return true
end

--- Read and validate one session's metadata.
-- @param session_dir string
-- @param expected_name string
-- @return table? meta, table? err
function Session.read_metadata(session_dir, expected_name)
  local info, stat_err = stat_path(session_dir)
  if not info then
    return nil, stat_err
  end
  if not info.exists then
    return nil, err_not_running()
  end
  if info.symlink or not info.directory then
    return nil, err_unsafe_path()
  end
  local euid = WheelHost.fs.euid()
  if euid == nil or info.uid ~= euid or info.mode ~= 448 then
    return nil, err_unsafe_path()
  end

  local path = session_dir .. "/" .. Session.FILE_META
  local meta_info, meta_stat_err = stat_path(path)
  if not meta_info then
    return nil, meta_stat_err
  end
  if not meta_info.exists then
    return nil, err_not_running()
  end
  if meta_info.symlink or not meta_info.regular or meta_info.uid ~= euid
    or meta_info.mode ~= 384 or meta_info.links ~= 1 then
    return nil, err_unsafe_path()
  end
  local raw = WheelHost.fs.read_file_bounded(path, Session.MAX_METADATA_BYTES + 1)
  if type(raw) ~= "string" or #raw > Session.MAX_METADATA_BYTES then
    return nil, err_metadata_invalid()
  end
  local decoded_ok, meta = pcall(JSON.decode, raw)
  if not decoded_ok or not validate_metadata(meta, expected_name) then
    return nil, err_metadata_invalid()
  end
  return meta, nil
end

local meta_sequence = 0

--- Write session metadata atomically (exclusive 0600 temp + rename).
-- @param session_dir string
-- @param meta table
-- @return boolean ok, table? err
function Session.write_metadata(session_dir, meta)
  local encoded_ok, encoded = pcall(JSON.encode, meta)
  if not encoded_ok or #encoded > Session.MAX_METADATA_BYTES then
    return false, err_metadata_invalid()
  end
  local temp_path
  local created = false
  for _ = 1, Session.MAX_LOCK_ATTEMPTS do
    meta_sequence = meta_sequence + 1
    temp_path = string.format("%s/%s.%d.%d.tmp", session_dir, Session.FILE_META, meta.pid, meta_sequence)
    local ok = WheelHost.fs.create_private_file(temp_path, encoded)
    if ok then
      created = true
      break
    end
  end
  if not created then
    return false, err_io()
  end
  local final_path = session_dir .. "/" .. Session.FILE_META
  local renamed = WheelHost.fs.rename(temp_path, final_path)
  if not renamed then
    WheelHost.fs.remove_file(temp_path)
    return false, err_io()
  end
  local info = stat_path(final_path)
  local euid = WheelHost.fs.euid()
  if not info or not info.exists or info.symlink or not info.regular
    or euid == nil or info.uid ~= euid or info.mode ~= 384 or info.links ~= 1 then
    return false, err_unsafe_path()
  end
  return true, nil
end

--- Probe whether a metadata pid is alive.
-- @param meta table
-- @return boolean? alive, table? err
function Session.pid_alive(meta)
  local alive, probe_err = WheelHost.proc.is_alive(meta.pid)
  if probe_err ~= nil then
    return nil, err_unresponsive()
  end
  return alive, nil
end

-- ---------------------------------------------------------------------------
-- Client serialization lock
-- ---------------------------------------------------------------------------

local lock_sequence = 0

local function lock_path(session_dir, name)
  return session_dir .. "/" .. name
end

local function read_lock_owner(session_dir, name)
  local path = lock_path(session_dir, name)
  local info, stat_err = stat_path(path)
  if not info then
    return nil, stat_err
  end
  if not info.exists then
    return false, nil
  end
  if info.symlink or not info.regular then
    return nil, err_lock_unsafe()
  end
  local euid = WheelHost.fs.euid()
  if euid == nil or info.uid ~= euid or info.mode ~= 384 then
    return nil, err_lock_unsafe()
  end
  local raw = WheelHost.fs.read_file_bounded(path, Session.MAX_LOCK_BYTES + 1)
  if type(raw) ~= "string" or #raw > Session.MAX_LOCK_BYTES then
    return nil, err_lock_unsafe()
  end
  local pid = tonumber(raw:match("^%s*(%d+)%s*$"))
  if not valid_pid(pid) then
    return nil, err_lock_unsafe()
  end
  return pid, nil
end

--- Release one named lock file only when it is still owned by `owner_pid`.
-- @param session_dir string
-- @param lock_name string
-- @param owner_pid number
-- @return boolean released
local function release_named_lock(session_dir, lock_name, owner_pid)
  local owner = read_lock_owner(session_dir, lock_name)
  if owner == owner_pid then
    return WheelHost.fs.remove_file(lock_path(session_dir, lock_name))
  end
  return false
end

--- Claim one stale lock path with an atomic rename and verify the moved owner.
-- The caller must serialize reclamation (for main locks, the per-lock mutex is
-- held). A path that changed after inspection is restored instead of deleted;
-- an unverified live lock is never removed.
-- @param session_dir string
-- @param lock_name string
-- @param expected_owner number
-- @return boolean reclaimed
local function claim_stale_lock(session_dir, lock_name, expected_owner)
  lock_sequence = lock_sequence + 1
  local stale_name = string.format("%s.stale.%d.%d", lock_name, expected_owner, lock_sequence)
  local stale_path = lock_path(session_dir, stale_name)
  if not WheelHost.fs.rename(lock_path(session_dir, lock_name), stale_path) then
    return false
  end
  local claimed = read_lock_owner(session_dir, stale_name)
  if claimed == expected_owner then
    if WheelHost.fs.remove_file(stale_path) then
      return true
    end
    return false
  end
  -- The path changed after the caller inspected it. Restore the moved lock
  -- rather than deleting a potentially live owner's lock.
  if not WheelHost.fs.rename(stale_path, lock_path(session_dir, lock_name)) then
    -- Leave the moved lock under its stale name. The caller fails closed; an
    -- unverified owner is never deleted.
  end
  return false
end

--- Acquire the short-lived reclamation mutex for one lock name.
-- Every main-lock acquisition takes this mutex first, so a stale main lock is
-- inspected, removed, and replaced while no other client can create or reclaim
-- it. A mutex whose owner pid is dead is reclaimed with a verified rename; a
-- mutex whose owner is live makes the caller busy.
-- @param session_dir string
-- @param lock_name string main lock name
-- @param owner_pid number
-- @return boolean ok, table? err
local function acquire_mutex(session_dir, lock_name, owner_pid)
  local mutex_name = lock_name .. ".mutex"
  local path = lock_path(session_dir, mutex_name)
  for _ = 1, Session.MAX_LOCK_ATTEMPTS do
    local created = WheelHost.fs.create_private_file(path, tostring(owner_pid) .. "\n")
    if created then
      local owner = read_lock_owner(session_dir, mutex_name)
      if owner == owner_pid then
        return true, nil
      end
      return false, err_busy()
    end
    local owner, read_err = read_lock_owner(session_dir, mutex_name)
    if owner == nil then
      return false, read_err or err_lock_unsafe()
    end
    if owner ~= false then
      local alive, probe_err = WheelHost.proc.is_alive(owner)
      if probe_err ~= nil or alive then
        return false, err_busy()
      end
      if not claim_stale_lock(session_dir, mutex_name, owner) then
        return false, err_busy()
      end
    end
  end
  return false, err_busy()
end

--- Acquire one exclusive session lock file for `owner_pid`.
-- Reclamation of a dead owner is serialized by a per-lock mutex: the stale main
-- lock is renamed and its moved owner verified before removal, and the new main
-- lock is created before the mutex is released. A concurrent caller therefore
-- sees either a live main lock or a busy mutex, never a freshly created live
-- lock that another cleaner can delete.
-- @param session_dir string
-- @param lock_name string
-- @param owner_pid number
-- @return boolean ok, table? err
function Session.acquire_lock(session_dir, lock_name, owner_pid)
  if not valid_pid(owner_pid) then
    return false, err_io()
  end
  local path = lock_path(session_dir, lock_name)
  for _ = 1, Session.MAX_LOCK_ATTEMPTS do
    local mutex_ok, mutex_err = acquire_mutex(session_dir, lock_name, owner_pid)
    if not mutex_ok then
      return false, mutex_err or err_busy()
    end

    local created = WheelHost.fs.create_private_file(path, tostring(owner_pid) .. "\n")
    if created then
      local owner = read_lock_owner(session_dir, lock_name)
      release_named_lock(session_dir, lock_name .. ".mutex", owner_pid)
      if owner == owner_pid then
        return true, nil
      end
      return false, err_busy()
    end

    local owner, read_err = read_lock_owner(session_dir, lock_name)
    if owner == nil then
      release_named_lock(session_dir, lock_name .. ".mutex", owner_pid)
      return false, read_err or err_lock_unsafe()
    end
    if owner == false then
      release_named_lock(session_dir, lock_name .. ".mutex", owner_pid)
      -- The main lock disappeared; retry under a fresh mutex.
    else
      local alive, probe_err = WheelHost.proc.is_alive(owner)
      if probe_err ~= nil or alive then
        release_named_lock(session_dir, lock_name .. ".mutex", owner_pid)
        return false, err_busy()
      end
      if not claim_stale_lock(session_dir, lock_name, owner) then
        release_named_lock(session_dir, lock_name .. ".mutex", owner_pid)
        return false, err_busy()
      end
      local created_after = WheelHost.fs.create_private_file(path, tostring(owner_pid) .. "\n")
      local owner_after = created_after and read_lock_owner(session_dir, lock_name) or nil
      release_named_lock(session_dir, lock_name .. ".mutex", owner_pid)
      if created_after and owner_after == owner_pid then
        return true, nil
      end
      return false, err_busy()
    end
  end
  return false, err_busy()
end

--- Release one session lock file only when it is still owned by `owner_pid`.
-- @param session_dir string
-- @param lock_name string
-- @param owner_pid number
-- @return boolean released
function Session.release_lock(session_dir, lock_name, owner_pid)
  return release_named_lock(session_dir, lock_name, owner_pid)
end

-- ---------------------------------------------------------------------------
-- Bounded line framing
-- ---------------------------------------------------------------------------

--- Read one newline-terminated frame with a hard bound.
-- Oversized input is drained up to `max_drain` bytes so the caller can answer
-- and continue; a frame that exceeds the drain bound is reported as "oversized"
-- and the caller must fail closed instead of resynchronising.
-- @param handle file
-- @param max_bytes number
-- @param max_drain number?
-- @return string? line, string? status ("closed"|"too_large"|"oversized"|"io")
function Session.read_frame(handle, max_bytes, max_drain)
  local parts, total = {}, 0
  max_drain = max_drain or Session.MAX_DRAIN_BYTES
  while true do
    local ok, char = pcall(handle.read, handle, 1)
    if not ok then
      return nil, "io"
    end
    if char == nil then
      return nil, "closed"
    end
    if char == "\n" then
      return table.concat(parts), nil
    end
    total = total + 1
    if total > max_bytes then
      local drained = 0
      while drained < max_drain do
        local read_ok, discarding = pcall(handle.read, handle, 1)
        if not read_ok then
          return nil, "io"
        end
        if discarding == nil then
          return nil, "closed"
        end
        if discarding == "\n" then
          return nil, "too_large"
        end
        drained = drained + 1
      end
      return nil, "oversized"
    end
    parts[#parts + 1] = char
  end
end

--- Write one newline-framed JSON document.
-- A Lua file handle reports I/O failure by returning nil plus an error
-- (without raising), so pcall success alone is not enough; both the write and
-- the flush result are inspected.
-- @param handle file
-- @param encoded string
-- @return boolean ok
function Session.write_frame(handle, encoded)
  local ok_write, write_result, write_err = pcall(handle.write, handle, encoded .. "\n")
  if not ok_write or write_result == nil then
    return false
  end
  local ok_flush, flush_result = pcall(handle.flush, handle)
  if not ok_flush or flush_result == nil then
    return false
  end
  return true
end

-- ---------------------------------------------------------------------------
-- Protocol envelope validation
-- ---------------------------------------------------------------------------

local function valid_request_id(value)
  return type(value) == "string"
    and #value > 0
    and #value <= Session.MAX_ID_BYTES
    and value:match("^[%w][%w.:_-]*$") ~= nil
end

Session.valid_request_id = valid_request_id

local function valid_method(value)
  return type(value) == "string" and METHODS[value] == true
end

--- Validate a decoded request envelope.
-- @param request any
-- @return boolean ok, table? err
function Session.validate_request(request)
  if type(request) ~= "table" then
    return false, err_protocol()
  end
  if request.protocol ~= Session.PROTOCOL then
    return false, err_protocol()
  end
  if not valid_request_id(request.id) then
    return false, err_protocol()
  end
  if not valid_method(request.method) then
    return false, err_method_unknown()
  end
  if request.params ~= nil and type(request.params) ~= "table" then
    return false, err_args_invalid()
  end
  return true, nil
end

--- Normalize an error table received from the daemon.
-- @param value any
-- @return table? err
function Session.normalize_error(value)
  if type(value) ~= "table" then
    return err_protocol()
  end
  local code = value.code
  local message = value.message
  if type(code) ~= "string" or not code:match("^E_SESSION_[A-Z0-9_]+$") then
    return err_protocol()
  end
  if type(message) ~= "string" or message == "" or #message > MESSAGE_MAX_LENGTH then
    return err_protocol()
  end
  if message:find("[\r\n]") then
    return err_protocol()
  end
  return {
    class = value.class == "validation" and "validation" or "runtime",
    code = code,
    message = message,
  }
end

-- ---------------------------------------------------------------------------
-- Client RPC
-- ---------------------------------------------------------------------------

local request_sequence = 0

local function open_control_plane(session_dir)
  local request, request_err = WheelHost.fs.open_fifo(session_dir .. "/" .. Session.FILE_REQUEST)
  if not request then
    return nil, nil, request_err and err_io() or err_io()
  end
  local response, response_err = WheelHost.fs.open_fifo(session_dir .. "/" .. Session.FILE_RESPONSE)
  if not response then
    pcall(request.close, request)
    return nil, nil, response_err and err_io() or err_io()
  end
  return request, response, nil
end

local function close_control_plane(request, response)
  if response then
    pcall(response.close, response)
  end
  if request then
    pcall(request.close, request)
  end
end

local function read_response(handle, expected_id, expected_method)
  for _ = 1, Session.MAX_STALE_RESPONSES do
    local line, status = Session.read_frame(handle, Session.MAX_RESPONSE_BYTES)
    if not line then
      if status == "too_large" or status == "oversized" then
        return nil, err_response_too_large()
      end
      return nil, err_io()
    end
    local ok, decoded = pcall(JSON.decode, line)
    if not ok or type(decoded) ~= "table" then
      return nil, err_protocol()
    end
    if decoded.protocol ~= Session.PROTOCOL then
      return nil, err_protocol()
    end
    if decoded.id == expected_id and decoded.method == expected_method then
      if decoded.ok == true and type(decoded.result) == "table" then
        return decoded.result, nil
      end
      return nil, Session.normalize_error(decoded.error)
    end
    -- A response from an abandoned request is discarded; a bounded number of
    -- stale frames is tolerated before the control plane is treated as unsafe.
  end
  return nil, err_protocol()
end

local function do_request(session_dir, method, params, request_id)
  local request, response, open_err = open_control_plane(session_dir)
  if not request then
    return nil, open_err
  end
  local ok, result, rpc_err = pcall(function()
    local envelope = {
      protocol = Session.PROTOCOL,
      id = request_id,
      method = method,
      params = params or {},
    }
    local encoded_ok, encoded = pcall(JSON.encode, envelope)
    if not encoded_ok then
      return nil, err_args_invalid()
    end
    if #encoded + 1 > Session.MAX_REQUEST_BYTES then
      return nil, err_frame_too_large()
    end
    if not Session.write_frame(request, encoded) then
      return nil, err_io()
    end
    return read_response(response, request_id, method)
  end)
  close_control_plane(request, response)
  if not ok then
    return nil, err_io()
  end
  return result, rpc_err
end

--- Send one method request to a running session daemon.
-- @param name string session name
-- @param method string one of `Session.METHODS`
-- @param params table?
-- @param opts table? { root = string?, owner_pid = number? }
-- @return table? result, table? err
function Session.request(name, method, params, opts)
  opts = type(opts) == "table" and opts or {}
  local name_ok, name_err = Session.validate_name(name)
  if not name_ok then
    return nil, name_err
  end
  if not valid_method(method) then
    return nil, err_method_unknown()
  end

  local root, root_err = Session.resolve_root(opts)
  if not root then
    return nil, root_err
  end
  local session_dir = make_session_dir(root, name)
  local dir_ok, dir_err = Session.ensure_session_dir(session_dir, false)
  if not dir_ok then
    if dir_err and dir_err.code == "E_SESSION_NOT_RUNNING" then
      return nil, err_not_running()
    end
    return nil, dir_err
  end
  local meta, meta_err = Session.read_metadata(session_dir, name)
  if not meta then
    return nil, meta_err
  end
  local alive, alive_err = Session.pid_alive(meta)
  if alive_err then
    return nil, alive_err
  end
  if not alive then
    return nil, err_not_running()
  end
  local files_ok, files_err = Session.verify_control_files(session_dir)
  if not files_ok then
    return nil, files_err
  end

  local owner_pid = opts.owner_pid
  if owner_pid == nil then
    owner_pid = WheelHost.proc.pid()
  end
  if not valid_pid(owner_pid) then
    return nil, err_io()
  end
  local acquire_ok, locked, lock_err = pcall(
    Session.acquire_lock, session_dir, Session.FILE_CLIENT_LOCK, owner_pid)
  if not acquire_ok then
    pcall(Session.release_lock, session_dir, Session.FILE_CLIENT_LOCK, owner_pid)
    return nil, err_io()
  end
  if not locked then
    return nil, lock_err
  end

  request_sequence = request_sequence + 1
  local request_id = string.format("%d-%d", owner_pid, request_sequence)
  local call_ok, result, rpc_err = pcall(
    do_request, session_dir, method, params, request_id)
  pcall(Session.release_lock, session_dir, Session.FILE_CLIENT_LOCK, owner_pid)
  if not call_ok then
    return nil, err_io()
  end
  if method == "shutdown" and result then
    -- The daemon removes its own control files; the client that received the
    -- shutdown acknowledgement makes one best-effort directory removal after
    -- releasing its lock, so the final empty directory does not depend on a
    -- cleanup race between the two processes.
    pcall(WheelHost.fs.remove_dir, session_dir)
  end
  return result, rpc_err
end

--- Ping a running session.
-- @return table? result, table? err
function Session.ping(name, opts)
  return Session.request(name, "ping", nil, opts)
end

--- Read session metadata and pid liveness without taking the client lock.
-- @param name string
-- @param opts table?
-- @return table? meta, boolean? alive, table? err
function Session.inspect(name, opts)
  opts = type(opts) == "table" and opts or {}
  local name_ok, name_err = Session.validate_name(name)
  if not name_ok then
    return nil, nil, name_err
  end
  local root, root_err = Session.resolve_root(opts)
  if not root then
    return nil, nil, root_err
  end
  local session_dir = make_session_dir(root, name)
  local meta, meta_err = Session.read_metadata(session_dir, name)
  if not meta then
    return nil, nil, meta_err
  end
  local alive, alive_err = Session.pid_alive(meta)
  if alive_err then
    return nil, nil, alive_err
  end
  return meta, alive, nil
end

local function remove_private_entry(path, expected)
  local info, stat_err = stat_path(path)
  if not info then
    return false, stat_err
  end
  if not info.exists then
    return true, nil
  end
  if info.symlink or info.uid ~= WheelHost.fs.euid() then
    return false, err_unsafe_path()
  end
  if expected == "fifo" and (not info.fifo or info.links ~= 1) then
    return false, err_unsafe_path()
  end
  if expected == "file" and (not info.regular or info.links ~= 1) then
    return false, err_unsafe_path()
  end
  local removed = WheelHost.fs.remove_file(path)
  if not removed then
    return false, err_io()
  end
  return true, nil
end

--- Verify both control FIFOs are owned, singly linked, mode-0600 FIFOs.
-- @param session_dir string
-- @return boolean ok, table? err
function Session.verify_control_files(session_dir)
  local euid = WheelHost.fs.euid()
  if euid == nil then
    return false, err_unsafe_path()
  end
  for _, fifo in ipairs({ Session.FILE_REQUEST, Session.FILE_RESPONSE }) do
    local info, stat_err = stat_path(session_dir .. "/" .. fifo)
    if not info then
      return false, stat_err
    end
    if not info.exists then
      return false, err_not_running()
    end
    if info.symlink or not info.fifo or info.uid ~= euid or info.mode ~= 384
      or info.links ~= 1 then
      return false, err_unsafe_path()
    end
  end
  return true, nil
end

--- Remove the known control-plane files of a stopped session.
-- Only the metadata and FIFO files are removed; a live client lock is left for
-- its owner (or for stale-lock recovery by the next client).
-- @param session_dir string
-- @return boolean ok, table? err
function Session.remove_control_files(session_dir)
  local entries = {
    { path = session_dir .. "/" .. Session.FILE_META, kind = "file" },
    { path = session_dir .. "/" .. Session.FILE_REQUEST, kind = "fifo" },
    { path = session_dir .. "/" .. Session.FILE_RESPONSE, kind = "fifo" },
  }
  for _, entry in ipairs(entries) do
    local ok, remove_err = remove_private_entry(entry.path, entry.kind)
    if not ok then
      return false, remove_err
    end
  end
  return true, nil
end

--- Prepare a session runtime directory and FIFOs for a daemon start.
-- The caller must hold the start lock for the whole spawn+readiness window.
-- A live metadata pid is rejected; a dead one is cleaned. Invalid metadata is
-- refused instead of guessed around.
-- @param name string
-- @param opts table? { root = string?, owner_pid = number? }
-- @return string? session_dir, table? err
function Session.prepare_start(name, opts)
  opts = type(opts) == "table" and opts or {}
  local name_ok, name_err = Session.validate_name(name)
  if not name_ok then
    return nil, name_err
  end
  local root, root_err = Session.resolve_root(opts)
  if not root then
    return nil, root_err
  end
  local root_ok, ensure_err = Session.ensure_root(root)
  if not root_ok then
    return nil, ensure_err
  end

  local session_dir = make_session_dir(root, name)
  local dir_info, dir_err = Session.ensure_session_dir(session_dir, true)
  if not dir_info then
    return nil, dir_err
  end

  local owner_pid = opts.owner_pid
  if owner_pid == nil then
    owner_pid = tonumber(getenv("WHEEL_SESSION_CALLER_PID") or "")
  end
  if not valid_pid(owner_pid) then
    owner_pid = WheelHost.proc.pid()
  end
  if not valid_pid(owner_pid) then
    return nil, err_start_failed()
  end

  local locked, lock_err = Session.acquire_lock(session_dir, Session.FILE_START_LOCK, owner_pid)
  if not locked then
    return nil, lock_err
  end

  local function abort(err)
    Session.release_lock(session_dir, Session.FILE_START_LOCK, owner_pid)
    return nil, err
  end

  local meta, meta_err = Session.read_metadata(session_dir, name)
  if meta then
    local alive, alive_err = Session.pid_alive(meta)
    if alive_err then
      return abort(alive_err)
    end
    if alive then
      return abort(err_already_running())
    end
  elseif meta_err and meta_err.code ~= "E_SESSION_NOT_RUNNING" then
    return abort(meta_err)
  end

  local cleaned, clean_err = Session.remove_control_files(session_dir)
  if not cleaned then
    return abort(clean_err)
  end
  for _, fifo in ipairs({ Session.FILE_REQUEST, Session.FILE_RESPONSE }) do
    local path = session_dir .. "/" .. fifo
    local info = stat_path(path)
    if info and info.exists then
      return abort(err_unsafe_path())
    end
    local created = WheelHost.fs.mkfifo(path)
    if not created then
      return abort(err_io())
    end
  end
  return session_dir, nil
end

--- Remove the start lock after readiness (called by the daemon).
-- When `expected_owner` is given, the lock is removed only if its recorded pid
-- still matches, so a late cleanup cannot delete a newer starter's lock.
-- @param session_dir string
-- @param expected_owner number?
-- @return boolean removed
function Session.release_start_lock(session_dir, expected_owner)
  local owner = read_lock_owner(session_dir, Session.FILE_START_LOCK)
  if owner == false then
    return true
  end
  if owner == nil then
    return false
  end
  if expected_owner ~= nil and owner ~= expected_owner then
    return false
  end
  return WheelHost.fs.remove_file(lock_path(session_dir, Session.FILE_START_LOCK))
end

--- Send `shutdown` and return the daemon's acknowledgement.
-- @param name string
-- @param opts table?
-- @return table? result, table? err
function Session.shutdown(name, opts)
  return Session.request(name, "shutdown", nil, opts)
end

-- ---------------------------------------------------------------------------
-- CLI
-- ---------------------------------------------------------------------------

local function parse_cli_args(argv)
  local args, root = {}, nil
  local index = 1
  while index <= #(argv or {}) do
    local value = argv[index]
    if value == "--root" then
      root = argv[index + 1]
      index = index + 2
    else
      args[#args + 1] = value
      index = index + 1
    end
  end
  return args, root
end

local function cli_fail(err)
  local encoded_ok, encoded = pcall(JSON.encode, {
    ok = false,
    error = { code = err.code, message = err.message },
  })
  if not encoded_ok then
    encoded = '{"ok":false,"error":{"code":"E_SESSION_IO","message":"session I/O failed"}}'
  end
  io.stderr:write(encoded .. "\n")
  return 1
end

local function cli_print(value)
  io.write(JSON.encode(value) .. "\n")
end

local function cli_put(opts, args)
  local name, slot, expected = args[2], args[3], args[4]
  if name == nil or slot == nil or args[5] ~= nil then
    return cli_fail(err_args_invalid())
  end
  if expected ~= nil then
    expected = tonumber(expected)
    if expected == nil or expected % 1 ~= 0 or expected < 0 then
      return cli_fail(err_args_invalid())
    end
  end
  local content = io.read(Session.MAX_CONTEXT_CONTENT_BYTES + 1) or ""
  if #content > Session.MAX_CONTEXT_CONTENT_BYTES then
    return cli_fail(err_frame_too_large())
  end
  local result, rpc_err = Session.request(name, "context.put", {
    name = slot,
    content = content,
    expected_version = expected,
  }, opts)
  if not result then
    return cli_fail(rpc_err)
  end
  cli_print(result)
  return 0
end

local function cli_get(opts, args)
  local name, slot = args[2], args[3]
  if name == nil or slot == nil or args[4] ~= nil then
    return cli_fail(err_args_invalid())
  end
  local result, rpc_err = Session.request(name, "context.get", { name = slot }, opts)
  if not result then
    return cli_fail(rpc_err)
  end
  if result.found ~= true then
    cli_print(result)
    return 0
  end
  io.write(result.content or "")
  return 0
end

local function cli_list(opts, args)
  local name, prefix = args[2], args[3]
  if name == nil or args[4] ~= nil then
    return cli_fail(err_args_invalid())
  end
  local result, rpc_err = Session.request(name, "context.list", { prefix = prefix }, opts)
  if not result then
    return cli_fail(rpc_err)
  end
  cli_print(result)
  return 0
end

local function cli_simple(opts, args, method)
  local name = args[2]
  if name == nil or args[3] ~= nil then
    return cli_fail(err_args_invalid())
  end
  local result, rpc_err = Session.request(name, method, nil, opts)
  if not result then
    return cli_fail(rpc_err)
  end
  cli_print(result)
  return 0
end

--- CLI entry point used by `scripts/wheel-session`.
-- Prints one JSON document for structured commands, or raw slot content for
-- `get`. Errors go to stderr as a static JSON error and return exit code 1.
-- @param argv table
-- @return number exit code
function Session.main(argv)
  local args, root = parse_cli_args(argv)
  local command = args[1]
  local opts = { root = root }

  if command == "root" then
    if args[2] ~= nil then
      return cli_fail(err_args_invalid())
    end
    local resolved, resolve_err = Session.resolve_root(opts)
    if not resolved then
      return cli_fail(resolve_err)
    end
    io.write(resolved .. "\n")
    return 0
  elseif command == "prepare" then
    local name = args[2]
    if name == nil or args[3] ~= nil then
      return cli_fail(err_args_invalid())
    end
    local session_dir, prepare_err = Session.prepare_start(name, opts)
    if not session_dir then
      return cli_fail(prepare_err)
    end
    io.write(session_dir .. "\n")
    return 0
  elseif command == "probe" then
    local name = args[2]
    if name == nil or args[3] ~= nil then
      return cli_fail(err_args_invalid())
    end
    local meta, alive, inspect_err = Session.inspect(name, opts)
    if not meta then
      if inspect_err and inspect_err.code ~= "E_SESSION_NOT_RUNNING" then
        return cli_fail(inspect_err)
      end
      return 1
    end
    if not alive then
      return 1
    end
    cli_print(meta)
    return 0
  elseif command == "ping" then
    return cli_simple(opts, args, "ping")
  elseif command == "status" then
    return cli_simple(opts, args, "session.status")
  elseif command == "snapshot" then
    return cli_simple(opts, args, "session.snapshot")
  elseif command == "stop" then
    return cli_simple(opts, args, "shutdown")
  elseif command == "put" then
    return cli_put(opts, args)
  elseif command == "get" then
    return cli_get(opts, args)
  elseif command == "list" then
    return cli_list(opts, args)
  end
  return cli_fail(err_method_unknown())
end

return Session
