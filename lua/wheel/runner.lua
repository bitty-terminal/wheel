-- lua/wheel/runner.lua
-- Wheel: Autonomous ReAct / Turn Execution Runner
--
-- Pure Lua 5.1 / LuaJIT implementation with zero external C dependencies.
-- Provides:
-- 1. Bounded Autonomous Multi-Turn ReAct Execution Loop (WheelRunner.run_task).
-- 2. Three-Zone Context compilation per turn with stable prefix alignment.
-- 3. Streaming token callbacks and structured Rationale extraction.
-- 4. Tool call dispatch through WheelAgent sandboxed execution engine.
-- 5. Automatic cognitive checkpointing and artifact publishing (tasks/<id>/artifacts).

local WheelRunner = {}
WheelRunner.__index = WheelRunner

local ok_audit, WheelAudit = pcall(require, "wheel.audit")
if not ok_audit then
  local ok_audit_alt, WheelAuditAlt = pcall(require, "lua.wheel.audit")
  WheelAudit = ok_audit_alt and WheelAuditAlt or nil
end

local ok_provider, WheelProvider = pcall(require, "wheel.provider")
if not ok_provider then
  local ok_p2, WheelP2 = pcall(require, "lua.wheel.provider")
  WheelProvider = ok_p2 and WheelP2 or nil
end

local ok_config, WheelConfig = pcall(require, "wheel.config")
if not ok_config then
  local ok_config_alt, WheelConfigAlt = pcall(require, "lua.wheel.config")
  WheelConfig = ok_config_alt and WheelConfigAlt or nil
end

-- Conversation policy is deliberately separate from provider budgets. These
-- bounds apply to the in-memory request history and to the structured state
-- written into WheelContext, so a provider cannot make a run grow without
-- limit.
WheelRunner.MAX_HISTORY_BYTES = 48 * 1024
WheelRunner.MAX_HISTORY_TURNS = 10
WheelRunner.RETAINED_TURNS = 4
WheelRunner.MAX_CONTEXT_REF_BYTES = 12 * 1024
WheelRunner.MAX_EVIDENCE_BYTES = 2048
WheelRunner.MAX_EVIDENCE_ITEMS = 8
WheelRunner.MAX_STATE_FIELD_BYTES = 1024
WheelRunner.MAX_REQUEST_BYTES = 48 * 1024
WheelRunner.MAX_REQUEST_MESSAGES = 12
WheelRunner.MAX_REQUEST_MESSAGE_BYTES = 4096
WheelRunner.MAX_REQUEST_VALUE_BYTES = 2048
WheelRunner.MAX_REQUEST_ARGUMENT_BYTES = 4096
WheelRunner.MAX_REQUEST_VALUE_NODES = 256
WheelRunner.MAX_REQUEST_NODES = 512
WheelRunner.MAX_REQUEST_KEYS = 512
WheelRunner.MAX_REQUEST_DEPTH = 64
WheelRunner.MAX_CONTEXT_REF_DEPTH = 64
WheelRunner.MAX_CHECKPOINT_ID_BYTES = 128
WheelRunner.MAX_CONTEXT_REF_TURNS = 9007199254740991

-- The runner's checkpoint rationale keeps the historical six-field contract;
-- structured rationale records add decision/risk/next_action/evidence fields.
local RATIONALE_TEXT_FIELDS = {
  "why", "what", "where_focus", "how", "expected", "observed",
  "decision", "uncertainty", "risk", "next_action",
}
local RATIONALE_LIST_FIELDS = { "evidence", "rejected_alternatives" }
local STATE_FIELDS = { "tool_calls", "failures", "decisions", "evidence", "risks", "next_actions" }

local function bound_text(value, limit)
  local text = type(value) == "string" and value or tostring(value or "")
  if #text <= limit then return text end
  if limit <= 3 then return text:sub(1, limit) end
  return text:sub(1, limit - 3) .. "..."
end

local function redact_bounded(value, limit)
  if WheelAudit and type(WheelAudit.redact_bounded) == "function" then
    return WheelAudit.redact_bounded(value, limit)
  end
  return "[omitted:redaction-unavailable]"
end

local function persistence_failure()
  return {
    class = "runtime",
    code = "E_CONTEXT_PERSISTENCE_FAILED",
    message = "context persistence failed; history was not compacted",
  }
end

local function normalize_rationale(rationale)
  local safe = {}
  if type(rationale) ~= "table" then
    if type(rationale) == "string" then
      return redact_bounded(rationale, WheelRunner.MAX_STATE_FIELD_BYTES)
    end
    return nil
  end
  for _, field in ipairs(RATIONALE_TEXT_FIELDS) do
    if type(rationale[field]) == "string" then
      safe[field] = redact_bounded(rationale[field], WheelRunner.MAX_STATE_FIELD_BYTES)
    end
  end
  for _, field in ipairs(RATIONALE_LIST_FIELDS) do
    local values = rationale[field]
    if type(values) == "string" then values = { values } end
    if type(values) == "table" then
      local bounded = {}
      for _, item in ipairs(values) do
        if type(item) ~= "string" or #item == 0 then
          -- A malformed structured record never contributes partial data.
          return nil
        end
        bounded[#bounded + 1] = redact_bounded(item, WheelRunner.MAX_STATE_FIELD_BYTES)
        if #bounded >= WheelRunner.MAX_EVIDENCE_ITEMS then break end
      end
      safe[field] = bounded
    end
  end
  return safe
end

local function safe_checkpoint_rationale(rationale)
  local normalized = normalize_rationale(rationale)
  if type(normalized) ~= "table" then
    return normalized or {}
  end
  -- Keep the structured marker so Rationale.for_persistence applies the
  -- bounded canonical schema; the Kernel sink re-redacts every field.
  if type(rationale) == "table" and rationale.schema ~= nil then
    normalized.schema = rationale.schema
  end
  if type(rationale) == "table"
    and (rationale.source == "fallback" or rationale.source == "provider" or rationale.source == "legacy") then
    normalized.source = rationale.source
  end
  -- Task/session linkage is durable context, not prompt content. Persistence
  -- bounds and redacts these IDs in Rationale.for_persistence.
  if type(rationale) == "table" and (rationale.schema ~= nil or rationale.source ~= nil) then
    for _, field in ipairs({ "task_id", "session_id" }) do
      local value = rationale[field]
      if type(value) == "string" and #value > 0 and #value <= WheelRunner.MAX_CHECKPOINT_ID_BYTES then
        normalized[field] = value
      end
    end
  end
  return normalized
end

local function message_bytes(value, seen)
  local value_type = type(value)
  if value_type == "string" then return #value end
  if value_type ~= "table" then return 8 end
  seen = seen or {}
  if seen[value] then return 0 end
  seen[value] = true
  local total = 0
  for key, item in pairs(value) do
    total = total + message_bytes(key, seen) + message_bytes(item, seen)
  end
  return total
end

local function append_unique_bounded(target, value, limit)
  local text = redact_bounded(value, limit)
  if type(text) ~= "string" or #text == 0 then return end
  -- Retain the newest items: a long run must keep its current failures,
  -- evidence, decisions, risks, and next actions rather than the first eight.
  for index, existing in ipairs(target) do
    if existing == text then table.remove(target, index); break end
  end
  target[#target + 1] = text
  while #target > WheelRunner.MAX_EVIDENCE_ITEMS do table.remove(target, 1) end
end

local function extract_state(turn_record, state)
  local response = turn_record.response or {}
  if type(response.content) == "string" and #response.content > 0 then
    append_unique_bounded(state.evidence, response.content, WheelRunner.MAX_EVIDENCE_BYTES)
  end
  -- Structured state comes only from the bounded rationale contract. Provider
  -- adapters do not guarantee arbitrary response fields, so nothing else is
  -- mined for decisions, risks, or next actions.
  local rationale = normalize_rationale(turn_record.rationale)
  if type(rationale) == "table" then
    if rationale.decision then
      append_unique_bounded(state.decisions, rationale.decision, WheelRunner.MAX_STATE_FIELD_BYTES)
    end
    if rationale.risk then
      append_unique_bounded(state.risks, rationale.risk, WheelRunner.MAX_STATE_FIELD_BYTES)
    end
    if rationale.uncertainty then
      append_unique_bounded(state.risks, rationale.uncertainty, WheelRunner.MAX_STATE_FIELD_BYTES)
    end
    if rationale.next_action then
      append_unique_bounded(state.next_actions, rationale.next_action, WheelRunner.MAX_STATE_FIELD_BYTES)
    end
    for _, item in ipairs(rationale.evidence or {}) do
      append_unique_bounded(state.evidence, item, WheelRunner.MAX_EVIDENCE_BYTES)
    end
    if rationale.observed then
      append_unique_bounded(state.evidence, rationale.observed, WheelRunner.MAX_EVIDENCE_BYTES)
    end
  elseif type(rationale) == "string" then
    append_unique_bounded(state.evidence, rationale, WheelRunner.MAX_EVIDENCE_BYTES)
  end
  for _, tool in ipairs(turn_record.tools or {}) do
    if tool.call then
      append_unique_bounded(state.tool_calls,
        string.format("%s:%s", tostring(tool.call.name or "tool"), tostring(tool.call.id or "call")),
        WheelRunner.MAX_STATE_FIELD_BYTES)
    end
    local outcome = tool.outcome or {}
    if outcome.success == false or (outcome.exit_code and outcome.exit_code ~= 0) then
      append_unique_bounded(state.failures,
        string.format("%s (exit=%s): %s", tostring(tool.call and tool.call.name or outcome.tool or "tool"),
          tostring(outcome.exit_code or 1),
          redact_bounded(outcome.stderr_preview or outcome.stderr or "tool failed",
            WheelRunner.MAX_STATE_FIELD_BYTES)),
        WheelRunner.MAX_STATE_FIELD_BYTES)
    end
    local evidence = (outcome.blob_hash or outcome.spillover_hash)
      and ("ref=" .. tostring(outcome.blob_hash or outcome.spillover_hash))
      or outcome.stdout_preview or outcome.stderr_preview or outcome.stdout or outcome.stderr
    if evidence then append_unique_bounded(state.evidence, evidence, WheelRunner.MAX_EVIDENCE_BYTES) end
  end
end

local sorted_keys
local canonical_value
local make_budget

-- Build a deterministic, bounded seed for the ContextRef identity. Each state
-- item and retained message contributes a fixed-size digest, so wide or deep
-- argument structures cannot force unbounded traversal or allocation and
-- equal-size histories still receive distinct identities.
local function seed_digest(value)
  local text = type(value) == "string" and value or tostring(value or "")
  local hash = WheelConfig and type(WheelConfig.compute_hash) == "function"
    and WheelConfig.compute_hash(text) or nil
  if type(hash) ~= "string" then
    return string.format("len:%d:%d", #text, #text > 0 and text:byte(1) or 0)
  end
  return hash
end

local function canonical_state(state, retained)
  local parts = {}
  for _, field in ipairs(STATE_FIELDS) do
    parts[#parts + 1] = field
    local values = state[field] or {}
    for index = 1, math.min(#values, WheelRunner.MAX_EVIDENCE_ITEMS) do
      parts[#parts + 1] = seed_digest(values[index])
    end
    parts[#parts + 1] = ";"
  end
  for record_index, record in ipairs(retained or {}) do
    parts[#parts + 1] = "r" .. tostring(record_index)
    local messages = record.messages or {}
    for message_index = 1, math.min(#messages, WheelRunner.MAX_REQUEST_MESSAGES) do
      local message = messages[message_index]
      parts[#parts + 1] = seed_digest(tostring(message.role) .. "\0" .. tostring(message.content))
      local calls = message.tool_calls or {}
      for call_index = 1, math.min(#calls, WheelRunner.MAX_REQUEST_VALUE_NODES) do
        local call = calls[call_index]
        local args
        if type(call.arguments) == "table" then
          args = canonical_value(call.arguments,
            make_budget(WheelRunner.MAX_REQUEST_VALUE_NODES, WheelRunner.MAX_REQUEST_KEYS,
              WheelRunner.MAX_REQUEST_ARGUMENT_BYTES, WheelRunner.MAX_CONTEXT_REF_DEPTH))
        else
          args = tostring(call.arguments or "")
        end
        parts[#parts + 1] = seed_digest(tostring(call.id) .. "\0" .. tostring(call.name) .. "\0"
          .. tostring(args or ""))
      end
    end
  end
  return table.concat(parts, "|")
end

local function encode_state_line(value)
  return "- " .. value:gsub("[%z\1-\31\127\\]", function(char)
    return string.format("\\x%02x", char:byte())
  end)
end

local function serialize_state(state, context_ref, hash_function)
  local lines = {
    "ContextRef v1",
    "id=" .. context_ref.id,
    "seed=" .. context_ref.hash,
    "body_hash=" .. string.rep("0", 64),
    "turns=" .. tostring(context_ref.turns),
    "bytes=" .. tostring(context_ref.bytes),
  }
  local marker = "[state truncated]"
  local used_bytes = #table.concat(lines, "\n")
    + math.max(0, #tostring(WheelRunner.MAX_CONTEXT_REF_BYTES) - #tostring(context_ref.bytes))
  -- Reserve every required section and the truncation marker before admitting
  -- any value. The digest placeholder already occupies its final wire width.
  local reserved_bytes = #marker + 1
  for _, field in ipairs(STATE_FIELDS) do reserved_bytes = reserved_bytes + #field + 3 end
  if used_bytes + reserved_bytes > WheelRunner.MAX_CONTEXT_REF_BYTES then return nil end
  local truncated = false
  for _, field in ipairs(STATE_FIELDS) do
    local section = "[" .. field .. "]"
    reserved_bytes = reserved_bytes - #section - 1
    lines[#lines + 1] = section
    used_bytes = used_bytes + #section + 1
    for index, value in ipairs(state[field] or {}) do
      if index > WheelRunner.MAX_EVIDENCE_ITEMS then truncated = true; break end
      local line = encode_state_line(redact_bounded(value, WheelRunner.MAX_STATE_FIELD_BYTES))
      if used_bytes + #line + 1 + reserved_bytes > WheelRunner.MAX_CONTEXT_REF_BYTES then
        truncated = true
        break
      end
      lines[#lines + 1] = line
      used_bytes = used_bytes + #line + 1
    end
  end
  if truncated then lines[#lines + 1] = marker end
  table.remove(lines, 4)
  local body_hash = hash_function(table.concat(lines, "\n"))
  table.insert(lines, 4, "body_hash=" .. body_hash)
  return table.concat(lines, "\n")
end

--- Validate the complete canonical ContextRef wire document, not just its hash.
-- O(bytes) time and space, bounded by MAX_CONTEXT_REF_BYTES.
function WheelRunner.validate_context_ref(content, hash_function)
  if type(content) ~= "string" or #content > WheelRunner.MAX_CONTEXT_REF_BYTES
    or content:find("[%z\1-\9\11-\31\127]") or content:sub(-1) == "\n" then return false end
  local lines = {}
  for line in (content .. "\n"):gmatch("([^\n]*)\n") do lines[#lines + 1] = line end
  if lines[1] ~= "ContextRef v1" then return false end
  local id = (lines[2] or ""):match("^id=(contextref:[0-9a-f]+)$")
  local seed = (lines[3] or ""):match("^seed=([0-9a-f]+)$")
  local body_hash = (lines[4] or ""):match("^body_hash=([0-9a-f]+)$")
  if not id or #id ~= 27 or not seed or #seed ~= 64 or not body_hash or #body_hash ~= 64
    or id ~= "contextref:" .. seed:sub(1, 16) then return false end
  local function count_field(line, label, maximum)
    local digits = (line or ""):match("^" .. label .. "=(%d+)$")
    if not digits or #digits > 16 or (#digits > 1 and digits:sub(1, 1) == "0") then return nil end
    local value = tonumber(digits)
    if not value or value < 0 or value > maximum or value % 1 ~= 0 then return nil end
    return value
  end
  if count_field(lines[5], "turns", WheelRunner.MAX_CONTEXT_REF_TURNS) == nil
    or count_field(lines[6], "bytes", WheelRunner.MAX_CONTEXT_REF_BYTES) ~= #content then return false end
  local section_index, item_count = 0, 0
  for index = 7, #lines do
    local line = lines[index]
    if section_index < #STATE_FIELDS and line == "[" .. STATE_FIELDS[section_index + 1] .. "]" then
      section_index, item_count = section_index + 1, 0
    elseif line == "[state truncated]" then
      if section_index ~= #STATE_FIELDS or index ~= #lines then return false end
    else
      if section_index == 0 or line:sub(1, 2) ~= "- " then return false end
      local text = line:sub(3)
      local decoded = text:gsub("\\x([0-9a-f][0-9a-f])", function(hex)
        local byte = tonumber(hex, 16)
        if byte <= 31 or byte == 127 or byte == 92 then return string.char(byte) end
        return "\\x" .. hex
      end)
      if encode_state_line(decoded) ~= line or #decoded > WheelRunner.MAX_STATE_FIELD_BYTES then return false end
      item_count = item_count + 1
      if item_count > WheelRunner.MAX_EVIDENCE_ITEMS then return false end
    end
  end
  if section_index ~= #STATE_FIELDS then return false end
  table.remove(lines, 4)
  return type(hash_function) == "function" and hash_function(table.concat(lines, "\n")) == body_hash
end

local function encoded_size(value)
  local codec = WheelProvider and WheelProvider.JSON
  if not codec or type(codec.encode) ~= "function" then return nil end
  local ok, encoded = pcall(codec.encode, value)
  return ok and type(encoded) == "string" and #encoded or nil
end

local function budget_bytes(budget, amount)
  if amount > budget.bytes then return false end
  budget.bytes = budget.bytes - amount
  return true
end

local function budget_node(budget)
  if budget.nodes <= 0 then return false end
  budget.nodes = budget.nodes - 1
  return true
end

local function budget_key(budget)
  if budget.keys <= 0 then return false end
  budget.keys = budget.keys - 1
  return true
end

local function copy_budget(budget)
  return { nodes = budget.nodes, keys = budget.keys, bytes = budget.bytes,
    depth = budget.depth, seen = {} }
end

local function safe_string(value, limit, budget)
  if not budget_node(budget) then return nil end
  local text = redact_bounded(value, limit)
  local size = encoded_size(text)
  if not size or not budget_bytes(budget, size) then return nil end
  return text
end

sorted_keys = function(value, limit)
  local keys = {}
  local overflow = false
  for key in pairs(value) do
    if limit and #keys >= limit then
      overflow = true
      break
    end
    keys[#keys + 1] = key
  end
  table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
  return keys, overflow
end

make_budget = function(nodes, keys, bytes, depth)
  return { nodes = nodes, keys = keys, bytes = bytes,
    depth = depth or WheelRunner.MAX_REQUEST_DEPTH, seen = {} }
end

canonical_value = function(value, budget, depth)
  if not budget_node(budget) then return nil end
  depth = depth or 0
  local value_type = type(value)
  if value_type == "string" then
    local text = redact_bounded(value, WheelRunner.MAX_REQUEST_VALUE_BYTES)
    local encoded = string.format("s%d:%s", #text, text)
    if budget_bytes(budget, #encoded) then return encoded end
    return nil
  end
  if value_type ~= "table" then
    local encoded = value_type .. ":" .. tostring(value)
    if budget_bytes(budget, #encoded) then return encoded end
    return nil
  end
  if depth >= budget.depth or budget.seen[value] then return nil end
  budget.seen[value] = true
  if not budget_bytes(budget, 2) then
    budget.seen[value] = nil
    return nil
  end
  local keys, overflow = sorted_keys(value, budget.keys)
  if overflow then budget.seen[value] = nil; return nil end
  budget.keys = budget.keys - #keys
  local parts = { "{" }
  for _, key in ipairs(keys) do
    local key_text = canonical_value(key, budget, depth + 1)
    local item_text = key_text and canonical_value(value[key], budget, depth + 1)
    if not item_text then budget.seen[value] = nil; return nil end
    local pair = key_text .. "=" .. item_text .. ";"
    if not budget_bytes(budget, #pair) then budget.seen[value] = nil; return nil end
    parts[#parts + 1] = pair
  end
  budget.seen[value] = nil
  return table.concat(parts) .. "}"
end

local function bounded_value(value, byte_limit, budget, depth)
  if not budget_node(budget) then return nil end
  if type(value) == "string" then
    local text = redact_bounded(value, byte_limit)
    local size = encoded_size(text)
    return size and budget_bytes(budget, size) and text or nil
  end
  if type(value) ~= "table" then
    if type(value) == "number" or type(value) == "boolean" then
      local size = encoded_size(value)
      return size and budget_bytes(budget, size) and value or nil
    end
    return nil
  end
  if (depth or 0) >= budget.depth or budget.seen[value] then return nil end
  budget.seen[value] = true
  if not budget_bytes(budget, 2) then budget.seen[value] = nil; return nil end
  local keys, overflow = sorted_keys(value, budget.keys)
  if overflow then budget.seen[value] = nil; return nil end
  budget.keys = budget.keys - #keys
  local result = {}
  for _, key in ipairs(keys) do
    local bounded_key = type(key) == "string" and redact_bounded(key, WheelRunner.MAX_REQUEST_VALUE_BYTES)
      or tostring(key)
    local key_size = encoded_size(bounded_key)
    if not key_size or not budget_bytes(budget, key_size + 1) then break end
    local bounded_item = bounded_value(value[key], byte_limit, budget, (depth or 0) + 1)
    if bounded_item ~= nil then
      result[bounded_key] = bounded_item
    end
  end
  budget.seen[value] = nil
  return result
end

local function encoded_request(request)
  local codec = WheelProvider and WheelProvider.JSON
  if not codec or type(codec.encode) ~= "function" then return nil end
  local ok, encoded = pcall(codec.encode, request)
  return ok and type(encoded) == "string" and encoded or nil
end

local function bounded_message(message, budget)
  budget = budget or make_budget(WheelRunner.MAX_REQUEST_VALUE_NODES,
    WheelRunner.MAX_REQUEST_KEYS, WheelRunner.MAX_REQUEST_ARGUMENT_BYTES)
  if not budget_node(budget) or not budget_bytes(budget, 2) then
    return nil
  end
  local bounded = {}
  local function field(name, value, limit)
    if not budget_key(budget) then return end
    local key_size = encoded_size(name)
    if not key_size or not budget_bytes(budget, key_size + 1) then return end
    local safe = safe_string(value, limit, budget)
    if safe ~= nil then bounded[name] = safe end
  end
  field("role", message.role or "user", WheelRunner.MAX_REQUEST_VALUE_BYTES)
  field("content", message.content or "", WheelRunner.MAX_REQUEST_MESSAGE_BYTES)
  if bounded.role == nil or bounded.content == nil then return nil end
  if message.tool_call_id then field("tool_call_id", message.tool_call_id, WheelRunner.MAX_REQUEST_VALUE_BYTES) end
  if type(message.tool_calls) == "table" then
    if not budget_key(budget) or not budget_node(budget) or not budget_bytes(budget, 2) then
      return bounded
    end
    bounded.tool_calls = {}
    for index, call in ipairs(message.tool_calls) do
      if index > WheelRunner.MAX_REQUEST_VALUE_NODES then break end
      if not budget_node(budget) or not budget_bytes(budget, 2) then break end
      local bounded_call = {}
      local function call_field(name, value)
        if not budget_key(budget) then return end
        local key_size = encoded_size(name)
        if not key_size or not budget_bytes(budget, key_size + 1) then return end
        local safe = safe_string(value, WheelRunner.MAX_REQUEST_VALUE_BYTES, budget)
        if safe ~= nil then bounded_call[name] = safe end
      end
      call_field("id", call.id or "call")
      call_field("name", call.name or "tool")
      if bounded_call.id == nil or bounded_call.name == nil then return nil end
      local arguments
      if type(call.arguments) == "table" then
        arguments = bounded_value(call.arguments, WheelRunner.MAX_REQUEST_VALUE_BYTES, budget) or {}
      elseif type(call.arguments) == "string" then
        arguments = #call.arguments <= WheelRunner.MAX_REQUEST_ARGUMENT_BYTES
          and safe_string(call.arguments, WheelRunner.MAX_REQUEST_ARGUMENT_BYTES, budget) or {}
      else
        arguments = {}
      end
      bounded_call.arguments = arguments
      bounded.tool_calls[#bounded.tool_calls + 1] = bounded_call
    end
  end
  return bounded
end

--- Bound request fields and serialized prefix together before provider dispatch.
local function bound_provider_request(request)
  local value_budget = make_budget(WheelRunner.MAX_REQUEST_NODES,
    WheelRunner.MAX_REQUEST_KEYS, WheelRunner.MAX_REQUEST_BYTES)
  local bounded = { messages = {} }
  local function top_level_key(name)
    if not budget_key(value_budget) then return false end
    local size = encoded_size(name)
    return size ~= nil and budget_bytes(value_budget, size + 1)
  end
  local function bounded_scalar(name, value, limit)
    if not top_level_key(name) then return nil end
    return safe_string(value, limit, value_budget)
  end
  bounded.model = bounded_scalar("model", request.model or "default-model", WheelRunner.MAX_REQUEST_VALUE_BYTES)
    or "default-model"
  if not top_level_key("messages") or not budget_node(value_budget) or not budget_bytes(value_budget, 2) then
    return { model = bounded.model, messages = {}, tools = {} }
  end
  if top_level_key("tools") then
    bounded.tools = bounded_value(request.tools or {}, WheelRunner.MAX_REQUEST_VALUE_BYTES, value_budget) or {}
  else
    bounded.tools = {}
  end
  bounded.temperature = request.temperature
  if request.thinking ~= nil and top_level_key("thinking") then
    bounded.thinking = bounded_value(request.thinking, WheelRunner.MAX_REQUEST_VALUE_BYTES, value_budget)
  end
  if request.max_completion_tokens ~= nil and top_level_key("max_completion_tokens") then
    bounded.max_completion_tokens = request.max_completion_tokens
  end
  for _, field in ipairs({ "prompt_cache_policy", "local_prefix_hash",
    "cache_policy_version", "tool_schema_version" }) do
    local value = request[field]
    if field == "prompt_cache_policy" and value ~= nil then
      if top_level_key(field) then bounded[field] = value end
    elseif type(value) == "string" and top_level_key(field) then
      bounded[field] = safe_string(value, WheelRunner.MAX_REQUEST_VALUE_BYTES, value_budget)
    end
  end
  if type(request.stable_context_prefix) == "string"
    and #request.stable_context_prefix <= WheelProvider.MAX_PROMPT_CACHE_PREFIX_BYTES
    and top_level_key("stable_context_prefix") then
    bounded.stable_context_prefix = safe_string(request.stable_context_prefix,
      WheelProvider.MAX_PROMPT_CACHE_PREFIX_BYTES, value_budget)
  end

  local source_messages = request.messages or {}
  local first_system = nil
  for _, message in ipairs(source_messages) do
    if message.role == "system" then first_system = message; break end
  end
  if first_system then
    local bounded_system = bounded_message(first_system, value_budget)
    if bounded_system then bounded.messages[#bounded.messages + 1] = bounded_system end
  end

  -- The original task instruction is pinned: tail selection and byte overflow
  -- must never drop the task the run is executing.
  local pinned_task = nil
  for _, message in ipairs(source_messages) do
    if message.role == "user" then pinned_task = message; break end
  end
  local pinned_bounded = nil
  if pinned_task then
    pinned_bounded = bounded_message(pinned_task, value_budget)
    if pinned_bounded then bounded.messages[#bounded.messages + 1] = pinned_bounded end
  end

  -- Select complete conversational groups from the tail. An assistant tool
  -- call and all matching observations are one indivisible group; orphan tool
  -- messages are never admitted to the bounded request.
  local groups = {}
  local index = 1
  while index <= #source_messages do
    local message = source_messages[index]
    if message == first_system or message == pinned_task then
      index = index + 1
    elseif message.role == "tool" then
      index = index + 1
    elseif message.role == "assistant" and type(message.tool_calls) == "table" and #message.tool_calls > 0 then
      local expected, found = {}, {}
      for _, call in ipairs(message.tool_calls) do expected[call.id] = true end
      local group = { message }
      local cursor = index + 1
      while cursor <= #source_messages and source_messages[cursor].role == "tool"
        and expected[source_messages[cursor].tool_call_id] do
        group[#group + 1] = source_messages[cursor]
        found[source_messages[cursor].tool_call_id] = true
        cursor = cursor + 1
      end
      local complete = true
      for id in pairs(expected) do if not found[id] then complete = false; break end end
      if complete then groups[#groups + 1] = group end
      index = cursor
    else
      groups[#groups + 1] = { message }
      index = index + 1
    end
  end
  local selected = {}
  local count = 0
  local available_messages = WheelRunner.MAX_REQUEST_MESSAGES - #bounded.messages
  for group_index = #groups, 1, -1 do
    local group = groups[group_index]
    if count + #group > available_messages then break end
    table.insert(selected, 1, group)
    count = count + #group
  end
  for _, group in ipairs(selected) do
    local trial_budget = copy_budget(value_budget)
    local bounded_group = {}
    for _, message in ipairs(group) do
      local bounded_item = bounded_message(message, trial_budget)
      if not bounded_item then
        bounded_group = nil
        break
      end
      bounded_group[#bounded_group + 1] = bounded_item
    end
    if bounded_group then
      value_budget = trial_budget
      for _, bounded_item in ipairs(bounded_group) do
        bounded.messages[#bounded.messages + 1] = bounded_item
      end
    end
  end

  local encoded = encoded_request(bounded)
  while encoded and #encoded > WheelRunner.MAX_REQUEST_BYTES do
    local removable = nil
    for index = 1, #bounded.messages do
      local candidate_message = bounded.messages[index]
      if candidate_message ~= pinned_bounded
        and (candidate_message.role == "assistant" or candidate_message.role == "user") then
        removable = index
        break
      end
    end
    if not removable then break end
    local candidate = table.remove(bounded.messages, removable)
    if candidate.role == "assistant" and candidate.tool_calls then
      local call_ids = {}
      for _, call in ipairs(candidate.tool_calls) do call_ids[call.id] = true end
      while bounded.messages[removable] and bounded.messages[removable].role == "tool"
        and call_ids[bounded.messages[removable].tool_call_id] do
        table.remove(bounded.messages, removable)
      end
    end
    encoded = encoded_request(bounded)
  end
  if encoded and #encoded > WheelRunner.MAX_REQUEST_BYTES then
    bounded.messages = {}
    if pinned_bounded then bounded.messages[1] = pinned_bounded end
    bounded.messages[#bounded.messages + 1] =
      { role = "user", content = "[request content omitted: request byte bound]" }
    bounded.tools = {}
    bounded.thinking = nil
    encoded = encoded_request(bounded)
  end
  if not encoded or #encoded > WheelRunner.MAX_REQUEST_BYTES then
    bounded = {
      model = "default-model",
      messages = pinned_bounded and { pinned_bounded }
        or { { role = "user", content = "[request omitted: request byte bound]" } },
      tools = {},
      max_completion_tokens = request.max_completion_tokens,
    }
  end
  return bounded
end

WheelRunner.bound_provider_request = bound_provider_request

local function copy_message(message)
  local budget = make_budget(WheelRunner.MAX_REQUEST_VALUE_NODES,
    WheelRunner.MAX_REQUEST_KEYS,
    WheelRunner.MAX_REQUEST_MESSAGE_BYTES + WheelRunner.MAX_REQUEST_ARGUMENT_BYTES + 256)
  local copied = bounded_message(message, budget)
  if copied then return copied end
  -- Never drop a retained message silently: keep role/content and the tool-call
  -- boundary, truncating each field to its established bound.
  local fallback = {
    role = redact_bounded(message.role or "user", WheelRunner.MAX_REQUEST_VALUE_BYTES),
    content = redact_bounded(message.content or "", WheelRunner.MAX_REQUEST_MESSAGE_BYTES),
  }
  if message.tool_call_id then
    fallback.tool_call_id = redact_bounded(message.tool_call_id, WheelRunner.MAX_REQUEST_VALUE_BYTES)
  end
  if type(message.tool_calls) == "table" then
    fallback.tool_calls = {}
    for index, call in ipairs(message.tool_calls) do
      if index > WheelRunner.MAX_REQUEST_VALUE_NODES then break end
      fallback.tool_calls[#fallback.tool_calls + 1] = {
        id = redact_bounded(call.id or "call", WheelRunner.MAX_REQUEST_VALUE_BYTES),
        name = redact_bounded(call.name or "tool", WheelRunner.MAX_REQUEST_VALUE_BYTES),
        arguments = type(call.arguments) == "table" and {}
          or redact_bounded(call.arguments or "", WheelRunner.MAX_REQUEST_ARGUMENT_BYTES),
      }
    end
  end
  return fallback
end

--- Compact a conversation while retaining complete recent turns. Assistant tool
-- calls are never separated from their observations; an unfinished call stays
-- in the retained prefix even when it is older than RETAINED_TURNS.
-- @param messages table Provider message array
-- @param turn_records table Recorded turns, oldest first
-- @param state table Structured retained state
-- @param opts table { context, task_id, author, force }
-- @return table messages, table|nil ContextRef
function WheelRunner.compact_history(messages, turn_records, state, opts)
  opts = opts or {}
  local context = opts.context
  local task_id = opts.task_id or "task"
  local old_bytes = message_bytes(messages)
  local over_budget = old_bytes > WheelRunner.MAX_HISTORY_BYTES
  local over_turns = #turn_records >= WheelRunner.MAX_HISTORY_TURNS
  if not opts.force and not over_budget and not over_turns then return messages, nil end

  state = state or {
    tool_calls = {}, failures = {}, decisions = {}, evidence = {}, risks = {}, next_actions = {},
  }
  for _, record in ipairs(turn_records) do extract_state(record, state) end
  local retained = {}
  local start = math.max(1, #turn_records - WheelRunner.RETAINED_TURNS + 1)
  for index, record in ipairs(turn_records) do
    local keep = index >= start
    for _, tool in ipairs(record.tools or {}) do
      local call_id = tool.call and tool.call.id
      if call_id and not tool.outcome then keep = true end
    end
    if keep then retained[#retained + 1] = record end
  end

  local ref_seed = table.concat({
    "ContextRef seed v2",
    redact_bounded(task_id, WheelRunner.MAX_STATE_FIELD_BYTES),
    tostring(#turn_records),
    tostring(old_bytes),
    canonical_state(state, retained),
  }, "\0")
  local hash_function = context and context.compute_hash
    or (WheelConfig and WheelConfig.compute_hash)
  hash_function = hash_function or function(value) return string.format("%08x", #value) end
  local ref_hash = hash_function and hash_function(ref_seed)
    or string.format("%08x", #ref_seed)
  local context_ref = {
    id = "contextref:" .. ref_hash:sub(1, 16),
    hash = ref_hash,
    turns = #turn_records,
    bytes = old_bytes,
    retained_turns = #retained,
  }
  local encoded = ""
  -- `bytes` is part of the serialized payload, so converge its decimal width
  -- before writing the slot. The bound guarantees this loop remains tiny.
  for _ = 1, 4 do
    encoded = serialize_state(state, context_ref, hash_function)
    if not encoded then return messages, nil, nil, persistence_failure() end
    local encoded_bytes = #encoded
    if context_ref.bytes == encoded_bytes then break end
    context_ref.bytes = encoded_bytes
  end
  encoded = serialize_state(state, context_ref, hash_function)
  if not encoded then return messages, nil, nil, persistence_failure() end
  context_ref.bytes = #encoded
  local final = serialize_state(state, context_ref, hash_function)
  if not final or #final ~= context_ref.bytes or #final > WheelRunner.MAX_CONTEXT_REF_BYTES then
    return messages, nil, nil, persistence_failure()
  end
  encoded = final

  if context and type(context.put_slot) == "function" then
    local slot_name = "tasks/" .. task_id .. "/context_ref"
    local put_ok, put_result = pcall(context.put_slot, context, slot_name, encoded)
    if not put_ok or type(put_result) ~= "table" or put_result.success ~= true then
      return messages, nil, nil, persistence_failure()
    end
    if type(context.commit_checkpoint) == "function" then
      local commit_ok, commit = pcall(context.commit_checkpoint, context, {
        author = opts.author or "wheel:runner",
        task_id = task_id,
        message = "ContextRef compaction " .. context_ref.id,
        rationale = {
          why = redact_bounded("Bound autonomous conversation history", WheelRunner.MAX_STATE_FIELD_BYTES),
          what = redact_bounded(context_ref.id, WheelRunner.MAX_STATE_FIELD_BYTES),
          observed = redact_bounded(string.format("retained %d of %d turns", #retained, #turn_records),
            WheelRunner.MAX_STATE_FIELD_BYTES),
        },
      })
      if not commit_ok or type(commit) ~= "table" or type(commit.hash) ~= "string" then
        return messages, nil, nil, persistence_failure()
      end
      context_ref.commit_hash = commit.hash
    end
  end

  local compacted = {}
  -- The provider's system message is rebuilt through compile_prompt on the
  -- next turn. Keep only a stable ContextRef user message and whole turns.
  local initial_message = messages[1]
  if initial_message and initial_message.role == "system" then
    compacted[#compacted + 1] = copy_message(initial_message)
    initial_message = messages[2]
  end
  if initial_message and initial_message.role == "user" then
    compacted[#compacted + 1] = copy_message(initial_message)
  end
  compacted[#compacted + 1] = {
    role = "user",
    content = "[ContextRef " .. context_ref.id .. "]\n" .. encoded,
  }
  for _, record in ipairs(retained) do
    for _, message in ipairs(record.messages or {}) do
      compacted[#compacted + 1] = copy_message(message)
    end
  end
  return compacted, context_ref, retained, nil
end

local ok_kernel, WheelKernel = pcall(require, "wheel.kernel")
if not ok_kernel then
  local ok_k2, WheelK2 = pcall(require, "lua.wheel.kernel")
  WheelKernel = ok_k2 and WheelK2 or nil
end

--- Create a new WheelRunner.
-- @param opts table?:
--   opts.max_turns number?: maximum turns per task execution (default 10)
--   opts.commit_checkpoints boolean?: whether to commit checkpoints per turn (default true)
--   opts.on_token function?: callback fn(delta, type)
--   opts.on_turn_start function?: callback fn(turn, task)
--   opts.on_tool_call function?: callback fn(tool_call)
--   opts.on_tool_result function?: callback fn(tool_call, outcome)
-- @return table WheelRunner instance
function WheelRunner.new(opts)
  opts = opts or {}
  local self = setmetatable({}, WheelRunner)
  self.max_turns = opts.max_turns or 10
  self.commit_checkpoints = (opts.commit_checkpoints ~= false)
  self.on_token = opts.on_token
  self.on_turn_start = opts.on_turn_start
  self.on_tool_call = opts.on_tool_call
  self.on_tool_result = opts.on_tool_result
  return self
end

--- Execute a task autonomously using the agent's LLM provider and ReAct turn loop.
-- @param agent table WheelAgent instance
-- @param task table Task definition from kernel
-- @param opts table?:
--   opts.provider table?: override provider adapter
--   opts.max_turns number?: turn limit
--   opts.max_completion_tokens number?: completion bound override
--   opts.on_token function?: callback fn(delta, type)
--   opts.on_turn_start function?: callback fn(turn, task)
--   opts.on_tool_call function?: callback fn(tool_call)
--   opts.on_tool_result function?: callback fn(tool_call, outcome)
-- @return table report {
--   success = boolean,
--   artifacts = string?,
--   checkpoints = string[],
--   iterations = number,
--   error = string?,
--   error_code = string?,
--   usage = table,
-- }
function WheelRunner.run_task(agent, task, opts)
  opts = opts or {}
  if not agent or not task then
    return { success = false, error = "Invalid agent or task argument", iterations = 0 }
  end

  -- Resolve one bounded completion budget per run. The context window is a
  -- separate budget on the model profile; this value caps completion tokens and
  -- is always sent so no provider assumes the model maximum.
  if not WheelProvider then
    return {
      success = false,
      error = "WheelProvider is not available",
      iterations = 0,
    }
  end
  local requested_budget = opts.max_completion_tokens
  if requested_budget == nil then
    requested_budget = agent.model_profile and agent.model_profile.max_completion_tokens
  end
  local completion_budget, budget_err = WheelProvider.validate_max_completion_tokens(requested_budget)
  if not completion_budget then
    return {
      success = false,
      error = tostring(budget_err),
      error_code = budget_err and budget_err.code,
      iterations = 0,
    }
  end

  local task_id = task.id or task.task_id
  local max_turns = opts.max_turns or (agent.budget and agent.budget.max_iterations) or 10
  local commit_checkpoints = (opts.commit_checkpoints ~= false)
  local on_token = opts.on_token
  local on_turn_start = opts.on_turn_start
  local on_tool_call = opts.on_tool_call
  local on_tool_result = opts.on_tool_result

  -- 1. Resolve Provider
  local provider = opts.provider or (agent.get_provider and agent:get_provider())
  if not provider then
    if WheelProvider and agent.model_profile then
      local p_inst, p_err = WheelProvider.create(agent.model_profile, opts)
      if not p_inst then
        return {
          success = false,
          error = "Failed to initialize provider: " .. tostring(p_err or "unknown"),
          iterations = 0,
        }
      end
      provider = p_inst
      if agent.set_provider then
        agent:set_provider(provider)
      end
    end
  end

  if not provider then
    return {
      success = false,
      error = "No provider adapter available",
      iterations = 0,
    }
  end

  -- 2. Bind active task in kernel and set attribution
  if agent.kernel and type(agent.kernel.set_active_task) == "function" then
    agent.kernel:set_active_task(task_id)
  end

  local st_lower = string.lower(task.status or "")
  if st_lower == "ready" and agent.kernel and type(agent.kernel.start_task) == "function" then
    agent.kernel:start_task(task_id, agent.name)
  end

  -- 3. Initialize conversation history
  local messages = {}
  local task_instruction = string.format("Task ID: %s\nTitle: %s\nDescription: %s\nPriority: %d",
    task_id,
    task.title or "",
    task.description or "",
    task.priority or 0)

  table.insert(messages, {
    role = "user",
    content = string.format("Please execute this task to completion:\n%s\nUse the available tools when needed. When finished, provide the final deliverables and summary.", task_instruction),
  })

  local checkpoints = {}
  local turn_records = {}
  local retained_state = {
    tool_calls = {},
    failures = {},
    decisions = {},
    evidence = {},
    risks = {},
    next_actions = {},
  }
  local context_ref = nil
  local total_usage = {
    prompt_tokens = 0,
    uncached_input_tokens = 0,
    completion_tokens = 0,
    thinking_tokens = 0,
    total_tokens = 0,
    cache_creation_tokens = 0,
    cache_read_tokens = 0,
    provider_cache_status = nil,
    local_prefix_hash = nil,
    local_prefix_reuse_ratio = nil,
  }

  local turn = 0
  local final_artifacts = nil
  local loop_success = false
  local final_error = nil
  local final_error_code = nil

  while turn < max_turns do
    turn = turn + 1

    if on_turn_start then
      on_turn_start(turn, task)
    end

    -- Compile Three-Zone Context
    local system_text = string.format("Agent: %s (Role: %s)\nSoftware Engineering domain only. Fail-closed on security violations.", agent.name, agent.role)
    local ctx_res = nil
    if agent.context and type(agent.context.compile_prompt) == "function" then
      ctx_res = agent.context:compile_prompt({
        system_instruction = system_text,
        project_rules = (agent.config and agent.config.directives) or { "Software Engineering domain only", "Fail-closed on security violations" },
        tool_schemas = agent.tools or {},
        active_task = task,
        recent_actions = (agent.kernel and agent.kernel.recent_actions and agent.kernel:recent_actions()) or {},
        turn_prompt = string.format("Execute turn %d for task %s", turn, task_id),
      })
      if ctx_res then
        agent.last_prefix_cache_key = ctx_res.prefix_cache_key
        agent.last_cache_share_ratio = ctx_res.cache_share_ratio
        total_usage.local_prefix_hash = ctx_res.prefix_cache_key
        total_usage.local_prefix_reuse_ratio = ctx_res.cache_share_ratio
        -- The projection/compiler is the provider request source. Only Zone 1
        -- is placed in the system message; its bytes remain stable while Zone
        -- 2/3 are supplied as a dynamic tail message.
        system_text = ctx_res.zone1_prefix
        ctx_res.dynamic_message = (ctx_res.zone2_state or "") .. "\n\n" .. (ctx_res.zone3_tail or "")
      end
    end

    -- Prepend / update system message at index 1
    if #messages > 0 and messages[1].role == "system" then
      messages[1].content = system_text
    else
      table.insert(messages, 1, { role = "system", content = system_text })
    end

    -- Collect available tools from registry
    local tools = {}
    if agent.tool_registry and type(agent.tool_registry.list_tools) == "function" then
      tools = agent.tool_registry:list_tools()
    end

    local request_messages = {}
    for index, message in ipairs(messages) do request_messages[index] = message end
    if ctx_res and ctx_res.dynamic_message and #ctx_res.dynamic_message > 0 then
      request_messages[#request_messages + 1] = {
        role = "user",
        content = ctx_res.dynamic_message,
      }
    end

    -- Build Provider Request
    local req = {
      model = (agent.model_profile and agent.model_profile.model) or "default-model",
      messages = request_messages,
      tools = tools,
      temperature = (agent.model_profile and agent.model_profile.temperature) or 0.0,
      thinking = agent.model_profile and agent.model_profile.thinking,
      max_completion_tokens = completion_budget,
      prompt_cache_policy = opts.prompt_cache_policy,
      stable_context_prefix = ctx_res and ctx_res.zone1_prefix or nil,
      local_prefix_hash = ctx_res and ctx_res.prefix_cache_key or nil,
      cache_policy_version = opts.cache_policy_version,
      tool_schema_version = opts.tool_schema_version,
    }

    -- Call model stream
    local stream_cb = function(chunk)
      if on_token and chunk.delta then
        on_token(chunk.delta, chunk.type or "content")
      end
    end

    req = bound_provider_request(req)
    local res, stream_err = provider:stream(req, stream_cb, opts)
    if not res then
      final_error = "Provider streaming failed: " .. tostring(stream_err)
      append_unique_bounded(retained_state.failures, final_error, WheelRunner.MAX_STATE_FIELD_BYTES)
      break
    end

    -- Accumulate usage telemetry
    if res.usage then
      total_usage.prompt_tokens = total_usage.prompt_tokens + (res.usage.prompt_tokens or 0)
      if total_usage.uncached_input_tokens ~= nil and res.usage.uncached_input_tokens ~= nil then
        total_usage.uncached_input_tokens = total_usage.uncached_input_tokens
          + res.usage.uncached_input_tokens
      else
        total_usage.uncached_input_tokens = nil
      end
      total_usage.completion_tokens = total_usage.completion_tokens + (res.usage.completion_tokens or 0)
      total_usage.thinking_tokens = total_usage.thinking_tokens + (res.usage.thinking_tokens or 0)
      total_usage.total_tokens = total_usage.total_tokens + (res.usage.total_tokens or 0)
      total_usage.cache_creation_tokens = total_usage.cache_creation_tokens + (res.usage.cache_creation_tokens or 0)
      total_usage.cache_read_tokens = total_usage.cache_read_tokens + (res.usage.cache_read_tokens or 0)
    else
      total_usage.uncached_input_tokens = nil
    end
    local cache_status = WheelProvider.cache_usage_status(res.usage, req, provider)
    total_usage.provider_cache_status = WheelProvider.aggregate_cache_status(
      total_usage.provider_cache_status, cache_status)

    -- Construct a bounded rationale.  Provider thinking is intentionally not
    -- copied here: it remains transient on `res` and cannot enter a prompt,
    -- checkpoint, or Context slot unless the provider returned a complete
    -- structured rationale object.
    local rationale = WheelProvider.parse_rationale(res, {
      task_id = task_id,
      session_id = opts.session_id or agent.session_id,
    })

    -- Handle tool calls
    local tool_calls = res.tool_calls or {}
    -- Prefer a provider-supplied structured rationale when an adapter
    -- produced one; otherwise use the bounded local turn record. Extraction
    -- only reads the documented rationale contract.
    local turn_rationale = type(res.rationale) == "table" and res.rationale or rationale
    local turn_record = { response = res, rationale = turn_rationale, tools = {}, messages = {} }
    if #tool_calls > 0 then
      -- Record assistant response message with tool calls
      local assistant_message = {
        role = "assistant",
        content = res.content or "",
        tool_calls = tool_calls,
      }
      table.insert(messages, assistant_message)
      table.insert(turn_record.messages, assistant_message)

      -- Execute each tool call
      for _, tc in ipairs(tool_calls) do
        if on_tool_call then
          on_tool_call(tc)
        end

        local dispatch_ok, outcome = pcall(agent.execute_tool, agent, tc.name, tc.arguments)
        if not dispatch_ok or type(outcome) ~= "table" or type(outcome.format_observation) ~= "function" then
          local dispatch_error = dispatch_ok and "Tool returned an invalid outcome" or tostring(outcome)
          local fallback_stderr = "Tool execution failed: " .. dispatch_error
          local fallback_preview = redact_bounded(fallback_stderr, WheelRunner.MAX_REQUEST_MESSAGE_BYTES)
          outcome = {
            tool = tc.name or "tool",
            success = false,
            exit_code = 1,
            duration_ms = 0,
            stdout = "",
            stderr = fallback_stderr,
            preview = fallback_preview,
            stderr_preview = fallback_preview,
            stdout_bytes = 0,
            stderr_bytes = #fallback_stderr,
            size_bytes = #fallback_stderr,
            format_observation = function(self)
              return string.format(
                "[Tool: %s (exit=%d, %dms)]\nSTDERR: %s",
                tostring(self.tool or "tool"),
                self.exit_code or 1,
                self.duration_ms or 0,
                self.stderr or ""
              )
            end,
          }
        end
        if on_tool_result then
          on_tool_result(tc, outcome)
        end
        turn_record.tools[#turn_record.tools + 1] = { call = tc, outcome = outcome }

        -- Record action in kernel
        if agent.kernel and type(agent.kernel.record_action) == "function" then
          agent.kernel:record_action({
            action_id = string.format("%s-t%d-%s", task_id, turn, tc.name or "tool"),
            success = outcome.success,
            exit_code = outcome.exit_code,
            duration_ms = outcome.duration_ms,
            tool = outcome.tool,
            intent = outcome.intent,
            preview = redact_bounded(outcome.preview or outcome.stdout_preview or outcome.stderr_preview or "",
              WheelRunner.MAX_REQUEST_MESSAGE_BYTES),
            stdout_preview = redact_bounded(outcome.stdout_preview or "", WheelRunner.MAX_REQUEST_MESSAGE_BYTES),
            stderr_preview = redact_bounded(outcome.stderr_preview or "", WheelRunner.MAX_REQUEST_MESSAGE_BYTES),
            size_bytes = outcome.size_bytes or ((outcome.stdout_bytes or 0) + (outcome.stderr_bytes or 0)),
            stdout_bytes = outcome.stdout_bytes,
            stderr_bytes = outcome.stderr_bytes,
            spilled = outcome.spilled,
            blob_hash = outcome.spillover_hash,
            spillover_bytes = outcome.spillover_bytes,
            diagnostics = outcome.diagnostics,
            timed_out = outcome.timed_out,
            truncated = outcome.truncated,
            outcome = outcome.outcome,
          })
        end

        -- Format observation string for next turn
        local observation = outcome:format_observation()
        local tool_message = {
          role = "tool",
          tool_call_id = tc.id,
          content = observation,
        }
        table.insert(messages, tool_message)
        table.insert(turn_record.messages, tool_message)
      end

      -- Commit turn checkpoint if enabled
      if commit_checkpoints and agent.kernel and type(agent.kernel.commit_checkpoint) == "function" then
        local cp = agent.kernel:commit_checkpoint(safe_checkpoint_rationale(rationale))
        if cp and cp.hash then
          table.insert(checkpoints, cp.hash)
        end
      end
    else
      -- Model produced text response without further tool calls -> Final answer / deliverables
      final_artifacts = res.content or string.format("Deliverables for %s completed by %s", task_id, agent.name)

      -- Publish deliverables to semantic slot
      if agent.context and type(agent.context.put_slot) == "function" then
        local safe_artifacts = redact_bounded(final_artifacts, WheelRunner.MAX_CONTEXT_REF_BYTES)
        local put_ok, put_result = pcall(agent.context.put_slot, agent.context,
          "tasks/" .. task_id .. "/artifacts", safe_artifacts)
        if not put_ok or type(put_result) ~= "table" or put_result.success ~= true then
          local failure = persistence_failure()
          final_error = failure.message
          final_error_code = failure.code
          break
        end
        local encoded = WheelProvider.JSON.encode(WheelProvider.Rationale.for_persistence(rationale))
        local rationale_ok, rationale_result = pcall(agent.context.put_slot, agent.context,
          "tasks/" .. task_id .. "/rationale", encoded)
        if not rationale_ok or type(rationale_result) ~= "table" or rationale_result.success ~= true then
          local failure = persistence_failure()
          final_error = failure.message
          final_error_code = failure.code
          break
        end
      end

      -- Commit completion checkpoint
      if commit_checkpoints and agent.kernel and type(agent.kernel.commit_checkpoint) == "function" then
        rationale.what = "Final deliverables produced for " .. task_id
        local cp = agent.kernel:commit_checkpoint(safe_checkpoint_rationale(rationale))
        if cp and cp.hash then
          table.insert(checkpoints, cp.hash)
        end
      end

      loop_success = true
      break
    end

    table.insert(turn_records, turn_record)
    extract_state(turn_record, retained_state)
    local compacted_messages, compacted_ref, retained_records, compact_error = WheelRunner.compact_history(messages, turn_records, retained_state, {
      context = agent.context,
      task_id = task_id,
      author = agent.name,
    })
    if compact_error then
      final_error = compact_error.message
      final_error_code = compact_error.code
      break
    end
    messages = compacted_messages
    if compacted_ref then
      context_ref = compacted_ref
      turn_records = retained_records
    end
  end

  if not loop_success and not final_error then
    final_error = string.format("Max turn budget (%d) reached without completing task %s", max_turns, task_id)
  end

  return {
    success = loop_success,
    artifacts = final_artifacts,
    checkpoints = checkpoints,
    iterations = turn,
    error = final_error,
    error_code = final_error_code,
    usage = total_usage,
    context_ref = context_ref,
  }
end

return WheelRunner
