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

Rationale.SCHEMA = "wheel-rationale/1"
Rationale.MAX_FIELD_BYTES = MAX_FIELD_BYTES
Rationale.MAX_LIST_ITEMS = MAX_LIST_ITEMS
Rationale.MAX_LIST_ITEM_BYTES = MAX_LIST_ITEM_BYTES
Rationale.MAX_TASK_ID_BYTES = MAX_TASK_ID_BYTES
Rationale.MAX_SESSION_ID_BYTES = MAX_SESSION_ID_BYTES
Rationale.MAX_LEGACY_FIELDS = MAX_LEGACY_FIELDS
Rationale.MAX_LEGACY_AGGREGATE_BYTES = MAX_LEGACY_AGGREGATE_BYTES

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
      local ok, decoded = pcall(json.decode, thinking)
      if ok then
        candidate = decoded
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

local function legacy_fallback()
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
    return Rationale.with_legacy_labels(copy_fallback("fallback"))
  end
  if type(value) == "string" then
    return redact_value(audit, value, MAX_FIELD_BYTES) or "Provider rationale unavailable"
  end
  if type(value) ~= "table" then
    return Rationale.with_legacy_labels(copy_fallback("fallback"))
  end
  if value.source == "fallback" then
    return legacy_fallback()
  end
  if value.schema == Rationale.SCHEMA then
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
      or Rationale.with_legacy_labels(copy_fallback("fallback"))
  end
  return sanitize_legacy(value, audit) or legacy_fallback()
end

return Rationale
