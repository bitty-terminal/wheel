-- Deterministic, bounded action records and build diagnostics.
--
-- Raw process output is accepted only at the persistence boundary.  Recent
-- action records retain bounded previews and metadata; complete evidence is
-- stored separately as a content-addressed blob when it exceeds the
-- spillover threshold.

local Action = {}

Action.SPILLOVER_THRESHOLD_BYTES = 4096
Action.MAX_INLINE_PREVIEW_BYTES = 256
Action.MAX_DIAGNOSTICS_ITEMS = 32
Action.MAX_DIAGNOSTIC_TEXT_BYTES = 256

local function text(value)
  return type(value) == "string" and value or ""
end

local function bounded(value, limit)
  value = text(value)
  if #value <= limit then return value end
  local marker = " ...[truncated]"
  if limit <= #marker then return value:sub(1, limit) end
  return value:sub(1, limit - #marker) .. marker
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
  if not file then return nil end
  return {
    file = file,
    line = tonumber(line_number),
    column = column and tonumber(column) or nil,
    text = bounded(line, Action.MAX_DIAGNOSTIC_TEXT_BYTES),
  }, file .. ":" .. line_number
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
        append_unique(result.warnings, bounded(line, Action.MAX_DIAGNOSTIC_TEXT_BYTES))
      elseif stage == "compiler" then
        append_unique(result.errors, bounded(line, Action.MAX_DIAGNOSTIC_TEXT_BYTES))
      elseif stage == "test" then
        append_unique(result.failed_tests, bounded(line, Action.MAX_DIAGNOSTIC_TEXT_BYTES))
      elseif stage == "panic" or stage == "assertion" then
        append_unique(result.panic_assertions, bounded(line, Action.MAX_DIAGNOSTIC_TEXT_BYTES))
      end
      if lower:find("error", 1, true) and stage ~= "compiler" then
        append_unique(result.errors, bounded(line, Action.MAX_DIAGNOSTIC_TEXT_BYTES))
      end
      local location, file_line = location_from_line(line)
      if location then
        append_unique(result.file_lines, file_line)
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
  return bounded(output, Action.MAX_INLINE_PREVIEW_BYTES)
end

local function head_tail_preview(stdout, stderr, hash, total_bytes)
  local stream = stdout
  if stderr ~= "" then stream = stream .. (#stream > 0 and "\n" or "") .. "STDERR: " .. stderr end
  if #stream <= Action.MAX_INLINE_PREVIEW_BYTES then return stream end
  local marker = string.format("\n[... %d bytes spilled to blob: %s ...]\n", total_bytes, tostring(hash))
  local available = math.max(0, Action.MAX_INLINE_PREVIEW_BYTES - #marker)
  local head = math.floor(available / 2)
  local tail = available - head
  return stream:sub(1, head) .. marker .. (tail > 0 and stream:sub(-tail) or "")
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
  local spilled = (normalized_input and raw.spilled == true)
    or total_bytes > Action.SPILLOVER_THRESHOLD_BYTES
  local full_payload = stdout
  if stderr ~= "" then full_payload = full_payload .. "\n--- STDERR ---\n" .. stderr end
  local blob_hash = raw.blob_hash or raw.spillover_hash
  if spilled then
    if not blob_hash then
      local h = 5381
      for i = 1, #full_payload do h = (h * 33 + full_payload:byte(i)) % 4294967296 end
      blob_hash = string.format("%08x%08x%08x%08x", h, h, h, h)
    end
    if put_blob then put_blob(blob_hash, full_payload) end
  end
  local diagnostics = raw.diagnostics or Action.extract_diagnostics(stdout, stderr, exit_code, timed_out)
  local preview = raw.preview or raw.summary or make_preview(stdout, stderr)
  if spilled and (not raw.preview or #preview > Action.MAX_INLINE_PREVIEW_BYTES) then
    preview = head_tail_preview(stdout, stderr, blob_hash, total_bytes)
  else
    preview = bounded(preview, Action.MAX_INLINE_PREVIEW_BYTES)
  end
  return {
    action_id = raw.action_id,
    tool = raw.tool,
    intent = raw.intent,
    success = raw.success ~= false and exit_code == 0,
    status = raw.status or ((raw.success ~= false and exit_code == 0) and "success" or "failure"),
    exit_code = exit_code,
    duration_ms = tonumber(raw.duration_ms) or 0,
    preview = preview,
    stdout_preview = raw.stdout_preview or bounded(stdout, Action.MAX_INLINE_PREVIEW_BYTES),
    stderr_preview = raw.stderr_preview or bounded(stderr, Action.MAX_INLINE_PREVIEW_BYTES),
    size_bytes = tonumber(raw.size_bytes) or total_bytes,
    stdout_bytes = tonumber(raw.stdout_bytes) or #stdout,
    stderr_bytes = tonumber(raw.stderr_bytes) or #stderr,
    truncated = raw.truncated == true or raw.stdout_truncated == true or raw.stderr_truncated == true,
    timed_out = timed_out,
    spilled = spilled,
    blob_hash = spilled and blob_hash or nil,
    spillover_hash = spilled and blob_hash or nil,
    spillover_bytes = spilled and (tonumber(raw.spillover_bytes) or total_bytes) or 0,
    diagnostics = diagnostics,
    outcome = raw.outcome or (timed_out and "timeout" or "exited"),
  }
end

return Action
