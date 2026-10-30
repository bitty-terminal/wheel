-- Deterministic, bounded action records and build diagnostics.
--
-- Raw process output is accepted only at the persistence boundary.  Recent
-- action records retain bounded previews and metadata; complete evidence is
-- stored separately as a content-addressed blob when it exceeds the
-- spillover threshold.

local Action = {}

local ok_audit, WheelAudit = pcall(require, "wheel.audit")
if not ok_audit then WheelAudit = nil end

Action.SPILLOVER_THRESHOLD_BYTES = 4096
Action.MAX_INLINE_PREVIEW_BYTES = 256
Action.MAX_DIAGNOSTICS_ITEMS = 32
Action.MAX_DIAGNOSTIC_TEXT_BYTES = 256

local function text(value)
  return type(value) == "string" and value or ""
end

local function valid_hash(value)
  return type(value) == "string" and value:match("^%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x$") ~= nil
end

local function is_valid_hash(value)
  return type(value) == "string" and #value == 64 and value:match("^%x+$") ~= nil
end

local function content_hash(value)
  local ok, config = pcall(require, "wheel.config")
  if not ok or type(config) ~= "table" or type(config.compute_hash) ~= "function" then
    return nil
  end
  local ok_hash, hash = pcall(config.compute_hash, value)
  if ok_hash and is_valid_hash(hash) then return hash end
  return nil
end

local function bounded(value, limit)
  value = text(value)
  if #value <= limit then return value end
  local marker = " ...[truncated]"
  if limit <= #marker then return value:sub(1, limit) end
  return value:sub(1, limit - #marker) .. marker
end

local function redact_bounded(value, limit)
  if WheelAudit and type(WheelAudit.redact_bounded) == "function" then
    return WheelAudit.redact_bounded(value, limit)
  end
  if text(value) == "" then return "" end
  return "[redacted]"
end

local function lines(value)
  local result = {}
  value = text(value)
  if value == "" then return result end
  for line in (value .. "\n"):gmatch("(.-)\r?\n") do
    table.insert(result, line)
  end
  return result
end

local function append_unique(list, value)
  if #list >= Action.MAX_DIAGNOSTICS_ITEMS or value == "" then return end
  for _, existing in ipairs(list) do
    if existing == value then return end
  end
  table.insert(list, value)
end

local function classify_line(line)
  local lower = line:lower()
  if lower:find("panic", 1, true) then return "panic" end
  if lower:find("assertion", 1, true) or lower:find("assert(", 1, true) then
    return "assertion"
  end
  if lower:find("failed test", 1, true)
    or (lower:find("test result", 1, true) and lower:find("fail", 1, true))
    or lower:match("^%s*test[%w_%.:/%-]*.*%sfailed")
    or lower:match("^%s*failures?:")
    or lower:match("^%s*failed[%s:]" )
    or lower:match("^%s*%-?%s*%d+[%s]+failed") then
    return "test"
  end
  if lower:find("error", 1, true) or lower:find("fatal", 1, true) then
    return "compiler"
  end
  if lower:find("warning", 1, true) then return "warning" end
  return nil
end

local function location_from_line(line)
  local file, line_number, column = line:match("([%w%._/%-]+):(%d+):(%d+)")
  if not file then
    file, line_number = line:match("([%w%._/%-]+):(%d+)")
  end
  local has_path_separator = file and file:find("/", 1, true) ~= nil
  local bare_source_file = file and file:match("%.[%w_]+$")
    and file:match("%.[cC][cC]?$") ~= nil
  local bare_lua_or_rust = file and file:match("%.[lL][uU][aA]$") ~= nil
    or file and file:match("%.[rR][sS]$") ~= nil
  local looks_like_hostname = file and file:match("^[%w%-]+%.[%w%-]+$") ~= nil
  if not file or (not has_path_separator and not bare_source_file and not bare_lua_or_rust)
    or (not has_path_separator and looks_like_hostname)
    or line:find("://", 1, true) ~= nil
    or file:match("^https?$") or file:match("^localhost$")
    or file:match("^%d+$") then
    return nil
  end
  return {
    file = redact_bounded(file, Action.MAX_DIAGNOSTIC_TEXT_BYTES),
    line = tonumber(line_number),
    column = column and tonumber(column) or nil,
    text = redact_bounded(line, Action.MAX_DIAGNOSTIC_TEXT_BYTES),
  }, file .. ":" .. line_number
end

local function looks_like_file(file)
  return type(file) == "string"
    and (file:find("/", 1, true) ~= nil or file:find("%.") ~= nil)
    and not file:match("^https?$")
    and not file:match("^localhost$")
    and not file:match("^%d+$")
end

local function sanitize_diagnostics(raw)
  if type(raw) ~= "table" then return nil end
  local result = {}
  for _, field in ipairs({ "errors", "warnings", "failed_tests", "panic_assertions", "file_lines" }) do
    if type(raw[field]) == "table" then
      result[field] = {}
      for _, value in ipairs(raw[field]) do
        if #result[field] >= Action.MAX_DIAGNOSTICS_ITEMS then break end
        if type(value) == "string" then
          append_unique(result[field], redact_bounded(value, Action.MAX_DIAGNOSTIC_TEXT_BYTES))
        end
      end
    end
  end
  if type(raw.locations) == "table" then
    result.locations = {}
    for _, location in ipairs(raw.locations) do
      if #result.locations >= Action.MAX_DIAGNOSTICS_ITEMS then break end
      if type(location) == "table" and type(location.file) == "string"
        and tonumber(location.line) ~= nil and looks_like_file(location.file) then
        local safe = {
          file = redact_bounded(location.file, Action.MAX_DIAGNOSTIC_TEXT_BYTES),
          line = tonumber(location.line),
        }
        if tonumber(location.column) ~= nil then safe.column = tonumber(location.column) end
        if type(location.text) == "string" then
          safe.text = redact_bounded(location.text, Action.MAX_DIAGNOSTIC_TEXT_BYTES)
        end
        table.insert(result.locations, safe)
      end
    end
  end
  result.exit_status = tonumber(raw.exit_status) or 0
  local stages = {
    success = true, timeout = true, process = true, compiler = true,
    test = true, panic = true, assertion = true,
  }
  result.final_failure_stage = stages[raw.final_failure_stage]
    and raw.final_failure_stage or "process"
  return result
end

--- Extract diagnostics by scanning every line of both streams.
-- @param stdout string
-- @param stderr string
-- @param exit_code number
-- @param timed_out boolean
-- @return table
function Action.extract_diagnostics(stdout, stderr, exit_code, timed_out)
  local result = {
    errors = {},
    warnings = {},
    failed_tests = {},
    panic_assertions = {},
    locations = {},
    file_lines = {},
    exit_status = tonumber(exit_code) or 0,
    final_failure_stage = "success",
  }
  local last_stage = nil
  local streams = { { name = "stdout", value = stdout }, { name = "stderr", value = stderr } }
  for _, stream in ipairs(streams) do
    for _, raw_line in ipairs(lines(stream.value)) do
      local line = raw_line:gsub("%s+$", "")
      local lower = line:lower()
      local stage = classify_line(line)
      if stage == "warning" then
        append_unique(result.warnings, redact_bounded(line, Action.MAX_DIAGNOSTIC_TEXT_BYTES))
      elseif stage == "compiler" then
        append_unique(result.errors, redact_bounded(line, Action.MAX_DIAGNOSTIC_TEXT_BYTES))
      elseif stage == "test" then
        append_unique(result.failed_tests, redact_bounded(line, Action.MAX_DIAGNOSTIC_TEXT_BYTES))
      elseif stage == "panic" or stage == "assertion" then
        append_unique(result.panic_assertions, redact_bounded(line, Action.MAX_DIAGNOSTIC_TEXT_BYTES))
      end
      if lower:find("error", 1, true) and stage ~= "compiler" then
        append_unique(result.errors, redact_bounded(line, Action.MAX_DIAGNOSTIC_TEXT_BYTES))
      end
      local location, file_line = location_from_line(line)
      if location and (stage ~= nil or lower:find("note", 1, true)
        or lower:find(" --> ", 1, true)) then
        append_unique(result.file_lines,
          redact_bounded(file_line, Action.MAX_DIAGNOSTIC_TEXT_BYTES))
        if #result.locations < Action.MAX_DIAGNOSTICS_ITEMS then
          local duplicate = false
          for _, existing in ipairs(result.locations) do
            if existing.file == location.file and existing.line == location.line
              and existing.column == location.column then duplicate = true; break end
          end
          if not duplicate then table.insert(result.locations, location) end
        end
      end
      if stage and stage ~= "warning" then last_stage = stage end
    end
  end
  if timed_out then
    result.final_failure_stage = "timeout"
  elseif (tonumber(exit_code) or 0) ~= 0 then
    result.final_failure_stage = last_stage or "process"
  end
  return result
end

local function make_preview(stdout, stderr)
  local output = ""
  if stdout ~= "" then output = stdout end
  if stderr ~= "" then
    output = output .. (#output > 0 and "\n" or "") .. "STDERR: " .. stderr
  end
  return redact_bounded(output, Action.MAX_INLINE_PREVIEW_BYTES)
end

local function head_tail_preview(stdout, stderr, hash, total_bytes)
  local stream = stdout
  if stderr ~= "" then stream = stream .. (#stream > 0 and "\n" or "") .. "STDERR: " .. stderr end
  if #stream <= Action.MAX_INLINE_PREVIEW_BYTES then
    return redact_bounded(stream, Action.MAX_INLINE_PREVIEW_BYTES)
  end
  local marker = string.format("\n[... %d bytes spilled to blob: %s ...]\n", total_bytes, tostring(hash))
  local available = math.max(0, Action.MAX_INLINE_PREVIEW_BYTES - #marker)
  local head = math.floor(available / 2)
  local tail = available - head
  local head_text = redact_bounded(stream:sub(1, head), head)
  local tail_text = tail > 0 and redact_bounded(stream:sub(-tail), tail) or ""
  return head_text .. marker .. tail_text
end

--- Build a bounded action record. `put_blob` is called only for spilled data.
-- @param raw table
-- @param put_blob fun(hash:string, content:string)?
-- @return table
function Action.normalize(raw, put_blob)
  raw = raw or {}
  local normalized_input = raw.preview ~= nil and raw.stdout == nil and raw.raw_stdout == nil
  local stdout = text(raw.stdout or raw.raw_stdout)
  local stderr = text(raw.stderr or raw.raw_stderr)
  local total_bytes = #stdout + #stderr
  local exit_code = tonumber(raw.exit_code) or 0
  local timed_out = raw.timed_out == true or raw.outcome == "timeout"
  local requested_spill = (normalized_input and raw.spilled == true)
    or total_bytes > Action.SPILLOVER_THRESHOLD_BYTES
  local full_payload = stdout
  if stderr ~= "" then full_payload = full_payload .. "\n--- STDERR ---\n" .. stderr end
  local supplied_blob_hash = raw.blob_hash or raw.spillover_hash
  local supplied_hash_is_valid = is_valid_hash(supplied_blob_hash)
  local blob_hash = supplied_blob_hash
  if not supplied_hash_is_valid then blob_hash = nil end
  if supplied_hash_is_valid and full_payload ~= "" and content_hash(full_payload) ~= blob_hash then
    -- A supplied identity is authoritative only when it matches the content;
    -- never replace an existing blob under that identity with different data.
    blob_hash = nil
    requested_spill = false
  end
  if requested_spill and not blob_hash and not supplied_hash_is_valid and full_payload ~= "" then
    blob_hash = content_hash(full_payload)
  end
  local spilled = requested_spill and blob_hash ~= nil
  if spilled and put_blob and full_payload ~= "" then
    put_blob(blob_hash, full_payload)
  end
  local diagnostics = sanitize_diagnostics(raw.diagnostics)
    or Action.extract_diagnostics(stdout, stderr, exit_code, timed_out)
  local supplied_preview = raw.preview or raw.summary
  local preview = supplied_preview and redact_bounded(supplied_preview, Action.MAX_INLINE_PREVIEW_BYTES)
    or make_preview(stdout, stderr)
  if spilled and preview == "" then
    -- A normalized record may contain only the bounded preview and an existing
    -- blob reference. Preserve that useful preview; do not fabricate payload
    -- or replace an authoritative blob with an empty write.
    preview = redact_bounded(supplied_preview or "", Action.MAX_INLINE_PREVIEW_BYTES)
  elseif spilled and not supplied_preview and #stdout + #stderr > Action.MAX_INLINE_PREVIEW_BYTES then
    preview = head_tail_preview(stdout, stderr, blob_hash, total_bytes)
  end
  return {
    action_id = redact_bounded(raw.action_id, Action.MAX_DIAGNOSTIC_TEXT_BYTES),
    tool = redact_bounded(raw.tool, Action.MAX_DIAGNOSTIC_TEXT_BYTES),
    intent = redact_bounded(raw.intent, Action.MAX_DIAGNOSTIC_TEXT_BYTES),
    success = raw.success ~= false and exit_code == 0,
    status = (raw.status == "success" or raw.status == "failure" or raw.status == "error"
      or raw.status == "denied") and raw.status
      or ((raw.success ~= false and exit_code == 0) and "success" or "failure"),
    exit_code = exit_code,
    duration_ms = tonumber(raw.duration_ms) or 0,
    preview = redact_bounded(preview, Action.MAX_INLINE_PREVIEW_BYTES),
    stdout_preview = redact_bounded(raw.stdout_preview or stdout, Action.MAX_INLINE_PREVIEW_BYTES),
    stderr_preview = redact_bounded(raw.stderr_preview or stderr, Action.MAX_INLINE_PREVIEW_BYTES),
    size_bytes = normalized_input and (tonumber(raw.size_bytes) or total_bytes) or total_bytes,
    stdout_bytes = normalized_input and (tonumber(raw.stdout_bytes) or #stdout) or #stdout,
    stderr_bytes = normalized_input and (tonumber(raw.stderr_bytes) or #stderr) or #stderr,
    truncated = raw.truncated == true or raw.stdout_truncated == true or raw.stderr_truncated == true,
    timed_out = timed_out,
    spilled = spilled,
    blob_hash = spilled and blob_hash or nil,
    spillover_hash = spilled and blob_hash or nil,
    spillover_bytes = spilled and (tonumber(raw.spillover_bytes) or total_bytes) or 0,
    diagnostics = diagnostics,
    outcome = (raw.outcome == "timeout" or raw.outcome == "exited"
      or raw.outcome == "cancelled" or raw.outcome == "unverified") and raw.outcome
      or (timed_out and "timeout" or "exited"),
  }
end

return Action
