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

Rationale.SCHEMA = "wheel-rationale/1"
Rationale.MAX_FIELD_BYTES = MAX_FIELD_BYTES
Rationale.MAX_LIST_ITEMS = MAX_LIST_ITEMS
Rationale.MAX_LIST_ITEM_BYTES = MAX_LIST_ITEM_BYTES
Rationale.MAX_TASK_ID_BYTES = MAX_TASK_ID_BYTES
Rationale.MAX_SESSION_ID_BYTES = MAX_SESSION_ID_BYTES

local FIELDS = {
  decision = true,
  evidence = true,
  uncertainty = true,
  risk = true,
  rejected_alternatives = true,
  next_action = true,
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
  record.why = record.decision
  record.what = record.next_action
  record.where_focus = record.task_id and ("task " .. record.task_id) or "task"
  record.how = "bounded provider rationale"
  record.expected = record.next_action
  record.observed = record.decision
  return record
end

return Rationale
