-- lua/wheel/rationale.lua
-- Bounded, provider-neutral rationale records.
--
-- Provider thinking is private transient input.  Only an explicitly structured
-- record is admitted to a checkpoint or Context slot; malformed or prose-only
-- thinking receives the deterministic fallback below.

local Rationale = {}

local MAX_FIELD_BYTES = 256
local MAX_LIST_ITEMS = 4
local MAX_LIST_ITEM_BYTES = 256
local MAX_TASK_ID_BYTES = 128
local MAX_SESSION_ID_BYTES = 128
local MAX_LEGACY_FIELDS = 8
local MAX_LEGACY_AGGREGATE_BYTES = 2048
local MAX_TAGGED_FIELDS = MAX_LEGACY_FIELDS + 6 + 4
local MAX_THINKING_JSON_BYTES = 16 * 1024
local MAX_JSON_DEPTH = 8
local MAX_JSON_NODES = 128

Rationale.SCHEMA = "wheel-rationale/1"
Rationale.MAX_FIELD_BYTES = MAX_FIELD_BYTES
Rationale.MAX_LIST_ITEMS = MAX_LIST_ITEMS
Rationale.MAX_LIST_ITEM_BYTES = MAX_LIST_ITEM_BYTES
Rationale.MAX_TASK_ID_BYTES = MAX_TASK_ID_BYTES
Rationale.MAX_SESSION_ID_BYTES = MAX_SESSION_ID_BYTES
Rationale.MAX_LEGACY_FIELDS = MAX_LEGACY_FIELDS
Rationale.MAX_LEGACY_AGGREGATE_BYTES = MAX_LEGACY_AGGREGATE_BYTES
Rationale.MAX_THINKING_JSON_BYTES = MAX_THINKING_JSON_BYTES

local FIELDS = {
  decision = true,
  evidence = true,
  uncertainty = true,
  risk = true,
  rejected_alternatives = true,
  next_action = true,
}

local LEGACY_FIELDS = {
  why = true,
  what = true,
  where_focus = true,
  how = true,
  expected = true,
  observed = true,
  goal = true,
  approach = true,
}

local TAGGED_FIELDS = {
  schema = true, source = true, task_id = true, session_id = true,
  decision = true, evidence = true, uncertainty = true, risk = true,
  rejected_alternatives = true, next_action = true, why = true, what = true,
  where_focus = true, how = true, expected = true, observed = true,
  goal = true, approach = true,
}

local FALLBACK = {
  decision = "Provider response processed",
  evidence = {},
  uncertainty = "Provider rationale unavailable",
  risk = "No provider rationale persisted",
  rejected_alternatives = {},
  next_action = "Continue task execution",
}

local function bounded_string(value, limit)
  if type(value) ~= "string" then
    return nil
  end
  if #value == 0 then
    return nil
  end
  if #value > limit then
    return nil
  end
  return value:sub(1, limit or MAX_FIELD_BYTES)
end

local function bounded_list(value)
  if type(value) == "string" then
    value = { value }
  end
  if type(value) ~= "table" then
    return nil
  end

  local count = 0
  for key in pairs(value) do
    if type(key) ~= "number" or key < 1 or key % 1 ~= 0 then
      return nil
    end
    if key > MAX_LIST_ITEMS then
      return nil
    end
    count = math.max(count, key)
  end

  local result = {}
  for index = 1, count do
    local item = bounded_string(value[index], MAX_LIST_ITEM_BYTES)
    if not item then
      -- A malformed or sparse item invalidates the structured record rather
      -- than allowing a partial provider object to become durable state.
      return nil
    end
    result[#result + 1] = item
  end
  return result
end

local function copy_fallback(source, task_id, session_id)
  local result = {
    schema = Rationale.SCHEMA,
    source = source or "fallback",
    decision = FALLBACK.decision,
    evidence = {},
    uncertainty = FALLBACK.uncertainty,
    risk = FALLBACK.risk,
    rejected_alternatives = {},
    next_action = FALLBACK.next_action,
  }
  if type(task_id) == "string" and #task_id > 0 then
    result.task_id = task_id:sub(1, MAX_TASK_ID_BYTES)
  end
  if type(session_id) == "string" and #session_id > 0 then
    result.session_id = session_id:sub(1, MAX_SESSION_ID_BYTES)
  end
  return result
end

local function is_plain_table(value)
  return type(value) == "table" and getmetatable(value) == nil
end

local function strict_json_document(text)
  if type(text) ~= "string" or #text == 0 or #text > MAX_THINKING_JSON_BYTES then
    return false
  end
  local position = 1
  local nodes = 0

  local function whitespace()
    while true do
      local byte = text:byte(position)
      if byte == 32 or byte == 9 or byte == 10 or byte == 13 then
        position = position + 1
      else
        return
      end
    end
  end

  whitespace()
  if text:sub(position, position) ~= "{" then
    return false
  end

  local function string_token()
    if text:sub(position, position) ~= '"' then return false end
    position = position + 1
    local decoded = {}
    local function append_codepoint(codepoint)
      if codepoint <= 0x7f then
        decoded[#decoded + 1] = string.char(codepoint)
      elseif codepoint <= 0x7ff then
        decoded[#decoded + 1] = string.char(0xc0 + math.floor(codepoint / 0x40), 0x80 + codepoint % 0x40)
      elseif codepoint <= 0xffff then
        decoded[#decoded + 1] = string.char(0xe0 + math.floor(codepoint / 0x1000),
          0x80 + math.floor(codepoint / 0x40) % 0x40, 0x80 + codepoint % 0x40)
      else
        decoded[#decoded + 1] = string.char(0xf0 + math.floor(codepoint / 0x40000),
          0x80 + math.floor(codepoint / 0x1000) % 0x40,
          0x80 + math.floor(codepoint / 0x40) % 0x40, 0x80 + codepoint % 0x40)
      end
    end
    while position <= #text do
      local byte = text:byte(position)
      if byte == 34 then
        position = position + 1
        return table.concat(decoded)
      elseif byte == 92 then
        position = position + 1
        local escape = text:sub(position, position)
        local simple_escapes = {
          ['"'] = '"', ["\\"] = "\\", ["/"] = "/",
          b = "\b", f = "\f", n = "\n", r = "\r", t = "\t",
        }
        if simple_escapes[escape] then
          decoded[#decoded + 1] = simple_escapes[escape]
          position = position + 1
        elseif escape == "u" then
          local hex = text:sub(position + 1, position + 4)
          if not hex:match("^%x%x%x%x$") then return false end
          local codepoint = tonumber(hex, 16)
          position = position + 5
          if codepoint >= 0xd800 and codepoint <= 0xdbff then
            if text:sub(position, position + 1) ~= "\\u" then return false end
            local low_hex = text:sub(position + 2, position + 5)
            if not low_hex:match("^%x%x%x%x$") then return false end
            local low = tonumber(low_hex, 16)
            if low < 0xdc00 or low > 0xdfff then return false end
            codepoint = 0x10000 + (codepoint - 0xd800) * 0x400 + (low - 0xdc00)
            position = position + 6
          elseif codepoint >= 0xdc00 and codepoint <= 0xdfff then
            return false
          end
          append_codepoint(codepoint)
        else
          return false
        end
      elseif byte < 32 then
        return false
      else
        decoded[#decoded + 1] = text:sub(position, position)
        position = position + 1
      end
    end
    return false
  end

  local parse_value
  local function number_token()
    local start = position
    if text:sub(position, position) == "-" then position = position + 1 end
    local first = text:sub(position, position)
    if first == "0" then
      position = position + 1
      if text:sub(position, position):match("%d") then return false end
    elseif first:match("[1-9]") then
      repeat position = position + 1 until not text:sub(position, position):match("%d")
    else
      return false
    end
    if text:sub(position, position) == "." then
      position = position + 1
      if not text:sub(position, position):match("%d") then return false end
      repeat position = position + 1 until not text:sub(position, position):match("%d")
    end
    local exponent = text:sub(position, position)
    if exponent == "e" or exponent == "E" then
      position = position + 1
      local sign = text:sub(position, position)
      if sign == "+" or sign == "-" then position = position + 1 end
      if not text:sub(position, position):match("%d") then return false end
      repeat position = position + 1 until not text:sub(position, position):match("%d")
    end
    return position > start
  end

  parse_value = function(depth)
    if depth > MAX_JSON_DEPTH then return false end
    nodes = nodes + 1
    if nodes > MAX_JSON_NODES then return false end
    whitespace()
    local current = text:sub(position, position)
    if current == '"' then return string_token() end
    if current == "{" then
      position = position + 1
      whitespace()
      if text:sub(position, position) == "}" then position = position + 1; return true end
      local keys = {}
      while true do
        whitespace()
        local key = string_token()
        if key == false then return false end
        if keys[key] then return false end
        keys[key] = true
        whitespace()
        if text:sub(position, position) ~= ":" then return false end
        position = position + 1
        if not parse_value(depth + 1) then return false end
        whitespace()
        local delimiter = text:sub(position, position)
        if delimiter == "}" then position = position + 1; return true end
        if delimiter ~= "," then return false end
        position = position + 1
      end
    end
    if current == "[" then
      position = position + 1
      whitespace()
      if text:sub(position, position) == "]" then position = position + 1; return true end
      while true do
        if not parse_value(depth + 1) then return false end
        whitespace()
        local delimiter = text:sub(position, position)
        if delimiter == "]" then position = position + 1; return true end
        if delimiter ~= "," then return false end
        position = position + 1
      end
    end
    for _, literal in ipairs({ "true", "false" }) do
      if text:sub(position, position + #literal - 1) == literal then
        position = position + #literal
        return true
      end
    end
    -- JSON null is not admissible in any rationale field. Reject it here
    -- before a lossy decoder can collapse it into a missing Lua value.
    if text:sub(position, position + 3) == "null" then return false end
    return number_token()
  end

  if not parse_value(0) then return false end
  whitespace()
  return position > #text
end

local function validate_tagged_map(value)
  if not is_plain_table(value) then return false end
  local count = 0
  local aggregate_bytes = 2
  for key, item in pairs(value) do
    count = count + 1
    if count > MAX_TAGGED_FIELDS then return false end
    if type(key) ~= "string"
      or #key > 64 or not TAGGED_FIELDS[key] then
      return false
    end
    aggregate_bytes = aggregate_bytes + #key + 6
    if key == "evidence" or key == "rejected_alternatives" then
      if item == nil then return false end
      local list = bounded_list(item)
      if not list then return false end
      for _, entry in ipairs(list) do aggregate_bytes = aggregate_bytes + #entry + 4 end
    elseif key == "schema" then
      if item ~= Rationale.SCHEMA then return false end
      aggregate_bytes = aggregate_bytes + #item
    elseif key == "source" then
      if item ~= "provider" and item ~= "legacy" and item ~= "fallback" then return false end
      aggregate_bytes = aggregate_bytes + #item
    elseif key == "task_id" or key == "session_id" then
      local limit = key == "task_id" and MAX_TASK_ID_BYTES or MAX_SESSION_ID_BYTES
      if item ~= nil then
        if not bounded_string(item, limit) then return false end
        aggregate_bytes = aggregate_bytes + #item
      end
    else
      if item == nil or not bounded_string(item, MAX_FIELD_BYTES) then return false end
      aggregate_bytes = aggregate_bytes + #item
    end
    if aggregate_bytes > MAX_LEGACY_AGGREGATE_BYTES then
      return false
    end
  end
  return true
end

--- Normalize an explicitly structured rationale object.
-- @param value table Provider-supplied structured object
-- @param opts table? { task_id = string?, session_id = string? }
-- @return table|nil bounded record
function Rationale.normalize(value, opts)
  opts = opts or {}
  if not is_plain_table(value) then
    return nil
  end
  for key in pairs(value) do
    if type(key) ~= "string" or (not FIELDS[key] and key ~= "schema") then
      return nil
    end
  end
  if value.schema ~= nil and value.schema ~= Rationale.SCHEMA then
    return nil
  end

  local decision = bounded_string(value.decision, MAX_FIELD_BYTES)
  local uncertainty = bounded_string(value.uncertainty, MAX_FIELD_BYTES)
  local risk = bounded_string(value.risk, MAX_FIELD_BYTES)
  local next_action = bounded_string(value.next_action, MAX_FIELD_BYTES)
  if (value.decision ~= nil and not decision)
    or (value.uncertainty ~= nil and not uncertainty)
    or (value.risk ~= nil and not risk)
    or (value.next_action ~= nil and not next_action) then
    return nil
  end
  decision = decision or FALLBACK.decision
  uncertainty = uncertainty or FALLBACK.uncertainty
  risk = risk or FALLBACK.risk
  next_action = next_action or FALLBACK.next_action
  local evidence = bounded_list(value.evidence)
  local rejected = bounded_list(value.rejected_alternatives)
  if value.evidence == nil then evidence = {} end
  if value.rejected_alternatives == nil then rejected = {} end
  if not evidence or not rejected then
    return nil
  end

  local result = {
    schema = Rationale.SCHEMA,
    source = "provider",
    decision = decision,
    evidence = evidence,
    uncertainty = uncertainty,
    risk = risk,
    rejected_alternatives = rejected,
    next_action = next_action,
  }
  if type(opts.task_id) == "string" and #opts.task_id > 0 then
    result.task_id = opts.task_id:sub(1, MAX_TASK_ID_BYTES)
  end
  if type(opts.session_id) == "string" and #opts.session_id > 0 then
    result.session_id = opts.session_id:sub(1, MAX_SESSION_ID_BYTES)
  end
  return result
end

--- Parse provider response rationale without retaining private thinking.
-- A response's `rationale` field is preferred.  Otherwise thinking content is
-- accepted only when it is a complete JSON object matching the schema.  Plain
-- prose, truncated JSON, and malformed objects deterministically fall back.
-- @param response table Provider response
-- @param json table JSON codec with decode(string) -> value
-- @param opts table? { task_id = string?, session_id = string? }
-- @return table bounded record
function Rationale.from_response(response, json, opts)
  opts = opts or {}
  local candidate = type(response) == "table" and response.rationale or nil
  if candidate == nil and type(response) == "table" then
    local thinking = response.thinking_content or response.reasoning_content
    if type(thinking) == "string" and #thinking > 0 and json and type(json.decode) == "function" then
      if strict_json_document(thinking) then
        local ok, decoded = pcall(json.decode, thinking)
        if ok and is_plain_table(decoded) and decoded.schema == Rationale.SCHEMA then
          local has_rationale_field = false
          for key in pairs(decoded) do
            if key ~= "schema" then
              has_rationale_field = true
              break
            end
          end
          if has_rationale_field then
            candidate = decoded
          end
        end
      end
    end
  end
  local normalized = Rationale.normalize(candidate, opts)
  if normalized then
    return normalized
  end
  return copy_fallback("fallback", opts.task_id, opts.session_id)
end

--- Add legacy bounded labels used by existing checkpoint consumers.
-- These labels are derived from the bounded record and never from raw thinking.
function Rationale.with_legacy_labels(record)
  record = record or copy_fallback()
  local decision = record.decision or record.goal or record.why or FALLBACK.decision
  local next_action = record.next_action or record.what or record.approach or FALLBACK.next_action
  record.why = record.why or decision
  record.what = record.what or next_action
  record.where_focus = record.where_focus or (record.task_id and ("task " .. record.task_id) or "task")
  record.how = record.how or "bounded provider rationale"
  record.expected = record.expected or next_action
  record.observed = record.observed or decision
  return record
end

local function load_audit()
  local ok, audit = pcall(require, "wheel.audit")
  if not ok then
    ok, audit = pcall(require, "lua.wheel.audit")
  end
  if ok and type(audit) == "table" and type(audit.redact_bounded) == "function" then
    return audit
  end
  return nil
end

local function redact_value(audit, value, limit)
  if type(value) ~= "string" then
    return nil
  end
  local ok, redacted = pcall(audit.redact_bounded, value, limit)
  if not ok or type(redacted) ~= "string" then
    return nil
  end
  if value ~= "" and redacted == "" then
    return nil
  end
  return redacted
end

local function within_aggregate_bound(record)
  local bytes = 2
  local fields = 0
  local function string_size(value)
    local size = #value + 2
    for index = 1, #value do
      local byte = value:byte(index)
      if byte == 34 or byte == 92 then
        size = size + 1
      elseif byte < 32 then
        size = size + 5
      end
    end
    return size
  end
  for key, value in pairs(record) do
    if type(key) ~= "string" then
      return false
    end
    fields = fields + 1
    bytes = bytes + string_size(key) + 1
    if type(value) == "string" then
      bytes = bytes + string_size(value)
    elseif type(value) == "table" then
      bytes = bytes + 2
      for index, item in ipairs(value) do
        if index > MAX_LIST_ITEMS or type(item) ~= "string" then
          return false
        end
        if index > 1 then bytes = bytes + 1 end
        bytes = bytes + string_size(item)
      end
    else
      return false
    end
    if fields > 32 then
      return false
    end
    if fields > 1 then bytes = bytes + 1 end
    if bytes > MAX_LEGACY_AGGREGATE_BYTES then
      return false
    end
  end
  return true
end

local function sanitize_record(record, audit)
  local result = {
    schema = Rationale.SCHEMA,
    source = "provider",
    evidence = {},
    rejected_alternatives = {},
  }
  for _, field in ipairs({ "decision", "uncertainty", "risk", "next_action" }) do
    result[field] = redact_value(audit, record[field], MAX_FIELD_BYTES)
    if not result[field] then
      return nil
    end
  end
  for _, field in ipairs({ "evidence", "rejected_alternatives" }) do
    for index, item in ipairs(record[field] or {}) do
      local redacted = redact_value(audit, item, MAX_LIST_ITEM_BYTES)
      if not redacted then
        return nil
      end
      result[field][index] = redacted
    end
  end
  for _, field in ipairs({ "task_id", "session_id" }) do
    if record[field] ~= nil then
      local limit = field == "task_id" and MAX_TASK_ID_BYTES or MAX_SESSION_ID_BYTES
      result[field] = redact_value(audit, record[field], limit)
      if not result[field] then
        return nil
      end
    end
  end
  result = Rationale.with_legacy_labels(result)
  return within_aggregate_bound(result) and result or nil
end

local function persistence_fallback(audit, task_id, session_id)
  local result = copy_fallback("fallback", task_id, session_id)
  if audit then
    for _, field in ipairs({ "task_id", "session_id" }) do
      if result[field] ~= nil then
        local limit = field == "task_id" and MAX_TASK_ID_BYTES or MAX_SESSION_ID_BYTES
        result[field] = redact_value(audit, result[field], limit)
      end
    end
  else
    result.task_id = nil
    result.session_id = nil
  end
  result = Rationale.with_legacy_labels(result)
  if within_aggregate_bound(result) then
    return result
  end
  return Rationale.with_legacy_labels(copy_fallback("fallback"))
end

local function sanitize_legacy(value, audit)
  if not is_plain_table(value) then
    return nil
  end

  local field_count = 0
  local fields = {}
  for key, item in pairs(value) do
    field_count = field_count + 1
    if field_count > MAX_LEGACY_FIELDS
      or type(key) ~= "string"
      or not LEGACY_FIELDS[key]
      or type(item) ~= "string"
      or #item == 0
      or #item > MAX_FIELD_BYTES then
      return nil
    end
    fields[key] = redact_value(audit, item, MAX_FIELD_BYTES)
    if not fields[key] then
      return nil
    end
  end

  local aggregate_bytes = 2
  for key, item in pairs(fields) do
    -- This is a conservative JSON-size bound: it includes both quoted key
    -- and value bytes plus separators. Unknown keys never reach this point.
    aggregate_bytes = aggregate_bytes + #key + #item + 6
    if aggregate_bytes > MAX_LEGACY_AGGREGATE_BYTES then
      return nil
    end
  end

  local decision = fields.why or fields.goal or FALLBACK.decision
  local next_action = fields.what or fields.approach or FALLBACK.next_action
  local result = {
    schema = Rationale.SCHEMA,
    source = "legacy",
    decision = decision,
    evidence = fields.observed and { fields.observed } or {},
    uncertainty = fields.expected or FALLBACK.uncertainty,
    risk = FALLBACK.risk,
    rejected_alternatives = {},
    next_action = next_action,
  }
  for key, item in pairs(fields) do
    result[key] = item
  end
  result = Rationale.with_legacy_labels(result)
  return within_aggregate_bound(result) and result or nil
end

--- Prepare rationale for a durable checkpoint or Context sink.
-- Every persisted string, including list items and compatibility labels, passes
-- through the shared audit redaction boundary. If that boundary is unavailable
-- or rejects a value, a static fallback is returned instead of raw input.
-- @param value string|table|nil
-- @return string|table bounded, redacted rationale
function Rationale.for_persistence(value)
  local audit = load_audit()
  if not audit then
    if type(value) == "string" then
      return "Provider rationale unavailable"
    end
    return persistence_fallback(nil)
  end
  if type(value) == "string" then
    return redact_value(audit, value, MAX_FIELD_BYTES) or "Provider rationale unavailable"
  end
  if type(value) ~= "table" then
    return persistence_fallback(audit)
  end
  local task_id = bounded_string(value.task_id, MAX_TASK_ID_BYTES)
  local session_id = bounded_string(value.session_id, MAX_SESSION_ID_BYTES)
  if value.source == "fallback" then
    return persistence_fallback(audit, task_id, session_id)
  end
  if value.schema == Rationale.SCHEMA then
    if not validate_tagged_map(value) then
      return persistence_fallback(audit, task_id, session_id)
    end
    local candidate = {}
    for _, field in ipairs({
      "schema", "decision", "evidence", "uncertainty", "risk",
      "rejected_alternatives", "next_action",
    }) do
      candidate[field] = value[field]
    end
    if candidate.decision == nil and value.why ~= nil then
      candidate.decision = value.why
    end
    if candidate.next_action == nil and value.what ~= nil then
      candidate.next_action = value.what
    end
    local normalized = Rationale.normalize(candidate, {
      task_id = value.task_id,
      session_id = value.session_id,
    })
    return (normalized and sanitize_record(normalized, audit))
      or persistence_fallback(audit, task_id, session_id)
  end
  return sanitize_legacy(value, audit) or persistence_fallback(audit, task_id, session_id)
end

return Rationale
