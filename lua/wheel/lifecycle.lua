-- Harness-side AgentSession and Headless Panel lifecycle records.
-- This module persists references and bounded metadata only. Prompt, transcript,
-- context contents, provider responses, tool arguments, and tool output are
-- deliberately outside this contract.

local WheelErrors
local function load_submodule(subpath)
  local rooted = "wheel." .. subpath
  local ok, value = pcall(require, rooted)
  if ok then package.loaded["lua." .. rooted] = value; return value end
  package.loaded[rooted] = nil
  local first_error = value
  if type(value) ~= "string" or not value:find("module '" .. rooted .. "' not found", 1, true) then
    error(value, 0)
  end
  local alternate = "lua.wheel." .. subpath
  ok, value = pcall(require, alternate)
  if ok then package.loaded[rooted], package.loaded[alternate] = value, value; return value end
  package.loaded[alternate] = nil
  if WheelErrors and WheelErrors.is_typed and WheelErrors.is_typed(value) then error(value, 0) end
  if WheelErrors and WheelErrors.is_typed and WheelErrors.is_typed(first_error) then error(first_error, 0) end
  error("wheel.lifecycle: cannot load " .. rooted .. ": " .. tostring(value), 0)
end

WheelErrors = load_submodule("errors")
local Audit = load_submodule("audit")
-- The host and session modules use canonical names internally. Resolve and
-- alias their dependencies first when only the lua.wheel root is available.
load_submodule("job")
local WheelHost = load_submodule("host")
local Session = load_submodule("session")

local Lifecycle = {}
Lifecycle.__index = Lifecycle

Lifecycle.AgentSessionState = {
  CREATED = "created", ACTIVE = "active", PAUSED = "paused", STALE = "stale",
  ENDED = "ended", ABANDONED = "abandoned",
}
Lifecycle.PanelState = {
  CREATED = "created", READY = "ready", ATTACHED = "attached", ACTIVE = "active",
  PAUSED = "paused", DETACHED = "detached", CLOSED = "closed",
}
Lifecycle.AttachMode = { CONTROLLER = "controller", OBSERVER = "observer" }

local S = Lifecycle.AgentSessionState
local P = Lifecycle.PanelState
local TERMINAL = { [S.ENDED] = true, [S.ABANDONED] = true }
local PANEL_TERMINAL = { [P.CLOSED] = true }
local LIVE = { [S.CREATED] = true, [S.ACTIVE] = true, [S.PAUSED] = true, [S.STALE] = true }
local PANEL_STATES = {
  [P.CREATED] = true, [P.READY] = true, [P.ATTACHED] = true, [P.ACTIVE] = true,
  [P.PAUSED] = true, [P.DETACHED] = true, [P.CLOSED] = true,
}
local EVENT_TYPES = {
  ["panel.created"] = true, ["panel.ready"] = true, ["panel.attached"] = true,
  ["panel.observer_attached"] = true, ["panel.active"] = true, ["panel.paused"] = true,
  ["panel.detached"] = true, ["panel.closed"] = true, ["agent_session.created"] = true,
  ["agent_session.active"] = true, ["agent_session.paused"] = true, ["agent_session.stale"] = true,
  ["agent_session.recovered"] = true, ["agent_session.checkpointed"] = true,
  ["agent_session.ended"] = true, ["agent_session.abandoned"] = true,
}

local MAX_REGISTRY_BYTES = 4 * 1024 * 1024
local MAX_EVENTS = 2048
local MAX_SESSIONS = 512
local MAX_PANELS = 512
local MAX_COUNTER = 1000000000
local MAX_METADATA_KEYS = 32
local MAX_METADATA_BYTES = 4096
local MAX_STRING_BYTES = 256
local MAX_CONTEXT_HEAD_BYTES = 128
local PRIVATE_FILE_MODE = 384
local MAX_SAFE_INTEGER = 9007199254740991
local REASON_CODES = {
  explicit = true, stale = true, session_ended = true, session_abandoned = true,
  panel_detached = true, transfer = true, recovery = true, manual = true,
  complete = true, user_pause = true, owner_lost = true, checkpoint = true,
  redacted = true,
}

local function fail(code, message) return nil, { code = code, message = message } end
local function finite(value)
  return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end
local function timestamp(value)
  return finite(value) and value >= 0 and value % 1 == 0 and value <= MAX_SAFE_INTEGER
end
local function copy(value, depth, seen)
  if type(value) ~= "table" then return value end
  depth = depth or 0
  if depth > 8 then return nil end
  seen = seen or {}
  if seen[value] then return nil end
  seen[value] = true
  local result = {}
  for key, item in pairs(value) do
    local cloned = copy(item, depth + 1, seen)
    if cloned == nil and item ~= nil then return nil end
    result[key] = cloned
  end
  seen[value] = nil
  return result
end
local function now_ms() return math.floor(WheelHost.time.now() * 1000) end
local function text(value, label, required, limit)
  if value == nil and not required then return nil end
  limit = limit or MAX_STRING_BYTES
  if type(value) ~= "string" or value == "" or #value > limit then
    return nil, label .. " must be a non-empty bounded string"
  end
  if value:find("[%z\1-\31\127]") then return nil, label .. " contains a control character" end
  return value
end
local function id(value, label, required)
  local result, err = text(value, label, required, Session.MAX_ID_BYTES)
  if not result then return nil, err end
  if result and not result:match("^[A-Za-z0-9][A-Za-z0-9._:/%-]*$") then
    return nil, label .. " contains unsupported characters"
  end
  return result
end
local function identity_id(value, label, required)
  if value == nil and not required then return nil end
  local result, err = text(value, label, required, Session.MAX_SESSION_NAME_BYTES)
  if not result then return nil, err end
  if not result:match("^[A-Za-z0-9][A-Za-z0-9._:/%-]*$") then
    return nil, label .. " contains unsupported characters"
  end
  return result
end
local function array_has(list, value)
  for _, item in ipairs(list or {}) do if item == value then return true end end
  return false
end
local function array_remove(list, value)
  for index = #list, 1, -1 do if list[index] == value then table.remove(list, index) end end
end
local function reconcile_panel(panel)
  if panel.state == P.CLOSED or panel.attached_session_id then return end
  panel.state = #panel.observer_session_ids > 0 and P.ATTACHED or P.DETACHED
end
local function exact_keys(value, allowed)
  for key in pairs(value) do if not allowed[key] then return false end end
  return true
end
local function array_shape(value, maximum)
  if type(value) ~= "table" then return false, 0 end
  local count = 0
  for key in pairs(value) do
    if type(key) ~= "number" or key < 1 or key % 1 ~= 0 then return false, 0 end
    count = count + 1
    if count > maximum then return false, 0 end
  end
  for index = 1, count do if value[index] == nil then return false, 0 end end
  return true, count
end

-- Metadata has an allowlist, not merely a denylist. This prevents sensitive
-- data being moved under a new spelling or nested alternate key.
local METADATA_KEYS = {
  role = true, binding_id = true, provider = true, model = true, temperature = true,
  thinking = true, context_budget = true, retry = true, max_completion_tokens = true,
  enabled = true, gear = true, budget_tokens = true, max_tokens = true,
  max_retries = true, backoff_ms = true,
}
local META_FORBIDDEN_VALUE = { prompt=true, transcript=true, content=true, context=true, tool=true, output=true, response=true, secret=true, token=true, credential=true }
local ROLE_VALUES = { primary=true, commander=true, coding=true, debug=true, research=true, reviewer=true }
local GEAR_VALUES = { off=true, low=true, medium=true, high=true }
local function metadata(value, depth, state)
  if value == nil then return {} end
  if type(value) ~= "table" then return nil, "metadata must be plain data" end
  if getmetatable(value) ~= nil then return nil, "metadata must be plain data" end
  depth, state = depth or 0, state or { keys = 0, bytes = 0 }
  if depth > 3 then return nil, "metadata is too deeply nested" end
  local result = {}
  for key, item in pairs(value) do
    if type(key) ~= "string" or not METADATA_KEYS[key]
      or key:lower():find("prompt", 1, true) or key:lower():find("transcript", 1, true)
      or key:lower():find("output", 1, true) or key:lower():find("response", 1, true)
      or key:lower():find("content", 1, true) or key:lower():find("tool", 1, true) then
      return nil, "metadata contains a forbidden or unknown field"
    end
    state.keys = state.keys + 1
    if state.keys > MAX_METADATA_KEYS then return nil, "metadata has too many keys" end
    if type(item) == "string" then
      if #item > MAX_STRING_BYTES then return nil, "metadata string is too large" end
      local redacted = Audit.redact_bounded(item, MAX_STRING_BYTES)
      if item == "[redacted]" or redacted ~= item then
        item = "[redacted]"
      elseif not item:match("^[A-Za-z0-9._:/%-]+$") then
        return nil, "metadata string is not a safe identifier"
      end
      local lower = item:lower()
      for forbidden in pairs(META_FORBIDDEN_VALUE) do
        if lower:find(forbidden, 1, true) then return nil, "metadata contains prohibited content" end
      end
      state.bytes = state.bytes + #item
    elseif type(item) == "number" then
      if not finite(item) then return nil, "metadata number is not finite" end
    elseif type(item) == "boolean" then
      -- accepted
    elseif type(item) == "table" then
      local nested, err = metadata(item, depth + 1, state)
      if not nested then return nil, err end
      item = nested
    else
      return nil, "metadata must contain plain values"
    end
    result[key] = item
    if key == "role" and not ROLE_VALUES[item] then return nil, "role metadata is invalid" end
    if key == "gear" and not GEAR_VALUES[item] then return nil, "thinking gear is invalid" end
    if state.bytes > MAX_METADATA_BYTES then return nil, "metadata is too large" end
  end
  return result
end

local function normalize_session_metadata(record)
  if type(record.role_binding) ~= "table" or type(record.role_binding.role) ~= "string"
    or record.role_binding.role == "" then return false, "role binding is missing or invalid" end
  if type(record.model_profile) ~= "table" or type(record.model_profile.provider) ~= "string"
    or record.model_profile.provider == "" or type(record.model_profile.model) ~= "string"
    or record.model_profile.model == "" then return false, "model profile is missing or invalid" end
  local budget = { keys = 0, bytes = 0 }
  local role, role_err = metadata(record.role_binding, 0, budget)
  local model, model_err = metadata(record.model_profile, 0, budget)
  if not role or not model then return false, role_err or model_err end
  if not exact_keys(role, { role=true, binding_id=true }) or not exact_keys(model, {
    provider=true, model=true, temperature=true, thinking=true, context_budget=true,
    retry=true, max_completion_tokens=true,
  }) then return false, "role/model metadata has unknown fields" end
  for _, key in ipairs({ "provider", "model" }) do
    if type(model[key]) ~= "string" then return false, "model reference is invalid" end
  end
  if role.binding_id ~= nil and not id(role.binding_id, "binding_id", true) then return false, "binding reference invalid" end
  if model.temperature ~= nil and (not finite(model.temperature) or model.temperature < 0 or model.temperature > 2) then return false, "temperature invalid" end
  local groups = {
    thinking = { enabled="boolean", gear="string", budget_tokens="number" },
    context_budget = { max_tokens="number" },
    retry = { max_retries="number", backoff_ms="number" },
  }
  for key, fields in pairs(groups) do
    if model[key] ~= nil then
      if type(model[key]) ~= "table" or not exact_keys(model[key], fields) then return false, "model group invalid" end
      for field, item in pairs(model[key]) do
        if type(item) ~= fields[field] or (type(item) == "number" and (item < 0 or item % 1 ~= 0 or item > MAX_SAFE_INTEGER)) then
          return false, "model field invalid"
        end
      end
    end
  end
  if model.max_completion_tokens ~= nil and (not finite(model.max_completion_tokens)
    or model.max_completion_tokens < 1 or model.max_completion_tokens % 1 ~= 0
    or model.max_completion_tokens > MAX_SAFE_INTEGER) then return false, "completion bound invalid" end
  if not role.role or not model.provider or not model.model then return false, "role/model metadata is incomplete" end
  record.role_binding, record.model_profile = role, model
  return true
end

local function safe_context_head(value)
  if value == nil then return true end
  if type(value) ~= "string" or #value == 0 or #value > MAX_CONTEXT_HEAD_BYTES
    or not value:match("^[A-Za-z0-9._%-]+$")
    or value:lower():find("prompt", 1, true) or value:lower():find("context", 1, true)
    or value:lower():find("transcript", 1, true) or value:lower():find("content", 1, true) then
    return false
  end
  return true
end

local function reason(value, label, loaded)
  if value == nil then return nil end
  if type(value) == "string" and #value <= MAX_STRING_BYTES
    and Audit.redact_bounded(value, MAX_STRING_BYTES) ~= value then return "redacted" end
  if type(value) ~= "string" or not REASON_CODES[value] then
    return nil, label .. " must be an approved reason code"
  end
  return value
end

local function safe_registry_path(path)
  local ok = Session.validate_absolute_path(path)
  if not ok then return false, "registry path must be an absolute safe path" end
  local parent = path:match("^(.*)/[^/]+$")
  if not parent or parent == "" then parent = "/" end
  local prefix = ""
  for segment in parent:gmatch("[^/]+") do
    prefix = prefix .. "/" .. segment
    local component = WheelHost.fs.stat(prefix)
    if not component or not component.exists or component.symlink or not component.directory then
      return false, "registry ancestor is not a real directory"
    end
  end
  local info = WheelHost.fs.stat(parent)
  if not info or not info.exists or info.symlink or not info.directory then
    return false, "registry parent is not a real directory"
  end
  local uid = WheelHost.fs.euid()
  local mode = info.mode or 0
  local group_bits = math.floor(mode / 8) % 8
  local other_bits = mode % 8
  if uid == nil or info.uid ~= uid or group_bits ~= 0 or other_bits ~= 0 then
    return false, "registry parent is not owned privately"
  end
  return true
end
local function safe_registry_target(path, allow_missing)
  local ok, err = safe_registry_path(path)
  if not ok then return false, err end
  local info = WheelHost.fs.stat(path)
  if not info then return false, "registry stat failed" end
  if not info.exists then return allow_missing, allow_missing and nil or "registry is missing" end
  if info.symlink or not info.regular or info.uid ~= WheelHost.fs.euid()
    or info.mode ~= PRIVATE_FILE_MODE or info.links ~= 1 then
    return false, "registry target is not a private regular file"
  end
  return true
end

local function generated(prefix, counter)
  local bytes = WheelHost.fs.random_bytes(12)
  if type(bytes) ~= "string" or #bytes ~= 12 then error("secure lifecycle ID generation unavailable", 0) end
  local suffix = ""
  for i = 1, #bytes do suffix = suffix .. string.format("%02x", string.byte(bytes, i)) end
  return prefix .. "-" .. suffix .. "-" .. tostring(counter)
end

local function quarantine_registry(path)
  local quarantine = path .. ".invalid." .. generated("registry", 0)
  local info = WheelHost.fs.stat(quarantine)
  if info and info.exists then return false end
  local linked = WheelHost.fs.link_exclusive(path, quarantine)
  if not linked then return false end
  local removed = WheelHost.fs.remove_file(path)
  if not removed then
    WheelHost.fs.remove_file(quarantine)
    return false
  end
  return true
end

local function event_allowed(key)
  return key == "reason" or key == "recovery" or key == "checkpoint"
    or key == "mode" or key == "observer_session_id" or key == "controller_session_id" or key == "transfer"
end
local function event_extra(extra, loaded)
  local result = {}
  for key, value in pairs(extra or {}) do
    if not event_allowed(key) then return nil, "event contains unknown metadata" end
    if key == "reason" or key == "recovery" then
      local clean, err = reason(value, key, loaded); if not clean then return nil, err end; result[key] = clean
    elseif key == "checkpoint" or key == "observer_session_id" or key == "controller_session_id" then
      local clean, err = id(value, key, true); if not clean then return nil, err end; result[key] = clean
    elseif key == "mode" then
      if value ~= Lifecycle.AttachMode.CONTROLLER and value ~= Lifecycle.AttachMode.OBSERVER then
        return nil, "event mode is invalid"
      end
      result[key] = value
    elseif key == "transfer" then
      if type(value) ~= "boolean" then return nil, "event transfer is invalid" end
      result[key] = value
    end
  end
  return result
end

local function new_event(state, kind, record, from_state, to_state, extra, next_id)
  local clean, err = event_extra(extra)
  if not clean then return nil, err end
  local event = {
    event_id = next_id("event"), type = kind, timestamp_ms = now_ms(),
    session_id = record.session_id, panel_id = record.panel_id, agent_id = record.agent_id,
    task_id = record.task_id, from_state = from_state, to_state = to_state,
  }
  for key, value in pairs(clean) do event[key] = value end
  state.events[#state.events + 1] = event
  if #state.events > MAX_EVENTS then table.remove(state.events, 1) end
  return event
end

local function valid_event_transition(event)
  local from, to, kind = event.from_state, event.to_state, event.type
  local transitions = {
    ["panel.created"] = { ["nil:created"] = true },
    ["panel.ready"] = { ["created:ready"] = true },
    ["panel.attached"] = { ["ready:attached"] = true, ["detached:attached"] = true },
    ["panel.observer_attached"] = { ["ready:attached"] = true, ["detached:attached"] = true, ["active:active"] = true, ["paused:paused"] = true, ["attached:attached"] = true },
    ["panel.active"] = { ["attached:active"] = true, ["paused:active"] = true, ["ready:active"] = true, ["detached:active"] = true },
    ["panel.paused"] = { ["active:paused"] = true },
    ["panel.detached"] = { ["active:detached"] = true, ["paused:detached"] = true, ["attached:detached"] = true, ["ready:detached"] = true, ["detached:detached"] = true, ["active:active"] = true, ["paused:paused"] = true, ["attached:attached"] = true, ["active:attached"] = true, ["paused:attached"] = true },
    ["panel.closed"] = { ["created:closed"] = true, ["ready:closed"] = true, ["detached:closed"] = true },
    ["agent_session.created"] = { ["nil:created"] = true },
    ["agent_session.active"] = { ["created:active"] = true, ["paused:active"] = true },
    ["agent_session.paused"] = { ["active:paused"] = true },
    ["agent_session.stale"] = { ["active:stale"] = true, ["paused:stale"] = true },
    ["agent_session.recovered"] = { ["stale:paused"] = true },
    ["agent_session.checkpointed"] = { ["created:created"] = true, ["active:active"] = true, ["paused:paused"] = true, ["stale:stale"] = true },
    ["agent_session.ended"] = { ["created:ended"] = true, ["active:ended"] = true, ["paused:ended"] = true, ["stale:ended"] = true },
    ["agent_session.abandoned"] = { ["created:abandoned"] = true, ["active:abandoned"] = true, ["paused:abandoned"] = true, ["stale:abandoned"] = true },
  }
  if kind == "panel.attached" and event.transfer == true and to == P.ACTIVE
    and (from == P.READY or from == P.DETACHED or from == P.ATTACHED) then return true end
  if kind == "panel.attached" and from == P.ATTACHED and to == P.ATTACHED then return true end
  return transitions[kind] and transitions[kind][tostring(from or "nil") .. ":" .. tostring(to or "nil")] == true
end

local function registry_shape(value)
  if type(value) ~= "table" or value.version ~= 1 or not exact_keys(value, {
    version = true, revision = true, policy = true, next_counter = true,
    sessions = true, panels = true, events = true,
  }) then return false, "registry top-level schema is invalid" end
  if not finite(value.revision) or value.revision < 0 or value.revision % 1 ~= 0
    or value.revision > MAX_SAFE_INTEGER
    or not finite(value.next_counter) or value.next_counter < 0
    or value.next_counter % 1 ~= 0 or value.next_counter > MAX_COUNTER then
    return false, "registry counters are invalid"
  end
  local policy = value.policy
  if type(policy) ~= "table" or not exact_keys(policy, { max_sessions_per_agent = true, allow_multiple_tasks = true })
    or (policy.max_sessions_per_agent ~= nil and (not finite(policy.max_sessions_per_agent)
      or policy.max_sessions_per_agent < 1 or policy.max_sessions_per_agent % 1 ~= 0
      or policy.max_sessions_per_agent > MAX_SESSIONS))
    or type(policy.allow_multiple_tasks) ~= "boolean" then return false, "registry policy is invalid" end
  if type(value.sessions) ~= "table" or type(value.panels) ~= "table" or type(value.events) ~= "table" then
    return false, "registry collections are invalid"
  end
  local session_count, panel_count = 0, 0
  for session_id, record in pairs(value.sessions) do
    session_count = session_count + 1
    if session_count > MAX_SESSIONS or type(session_id) ~= "string" or type(record) ~= "table"
      or record.session_id ~= session_id or not exact_keys(record, {
        agent_id=true,session_id=true,panel_id=true,task_id=true,context_branch=true,context_head=true,
        role_binding=true,model_profile=true,worktree_id=true,state=true,checkpoint=true,created_at_ms=true,
        updated_at_ms=true,recovered_from=true,attachment_mode=true,
      }) or not LIVE[record.state] and not TERMINAL[record.state] then return false, "session schema is invalid" end
    local valid = identity_id(record.agent_id, "agent_id", true) and id(record.session_id, "session_id", true)
      and id(record.panel_id, "panel_id", true) and text(record.context_branch, "context_branch", true)
    if not valid or not value.panels[record.panel_id] or not safe_context_head(record.context_head)
      or not timestamp(record.created_at_ms) or not timestamp(record.updated_at_ms)
      or record.updated_at_ms < record.created_at_ms then return false, "session identity or bounds are invalid" end
    if record.task_id ~= nil and not id(record.task_id, "task_id", true) then return false, "task id invalid" end
    if record.worktree_id ~= nil and not id(record.worktree_id, "worktree_id", true) then return false, "worktree id invalid" end
    if record.checkpoint ~= nil and not id(record.checkpoint, "checkpoint", true) then return false, "checkpoint invalid" end
    if record.attachment_mode ~= nil and record.attachment_mode ~= "controller" and record.attachment_mode ~= "observer" then return false, "attachment mode invalid" end
    if record.recovered_from ~= nil and record.recovered_from ~= "stale" then return false, "recovery source invalid" end
    local metadata_ok, metadata_err = normalize_session_metadata(record)
    if not metadata_ok then return false, metadata_err end
  end
  for panel_id, panel in pairs(value.panels) do
    panel_count = panel_count + 1
    if panel_count > MAX_PANELS or type(panel_id) ~= "string" or type(panel) ~= "table"
      or panel.panel_id ~= panel_id or not exact_keys(panel, {
        panel_id=true,kind=true,headless=true,agent_id=true,state=true,attached_session_id=true,
        observer_session_ids=true,created_at_ms=true,updated_at_ms=true,
      }) or not id(panel.panel_id, "panel_id", true) or type(panel.kind) ~= "string"
      or #panel.kind > MAX_STRING_BYTES or not PANEL_STATES[panel.state]
      or type(panel.headless) ~= "boolean" or type(panel.observer_session_ids) ~= "table"
      or not timestamp(panel.created_at_ms) or not timestamp(panel.updated_at_ms)
      or panel.updated_at_ms < panel.created_at_ms or not text(panel.kind, "panel kind", true) then return false, "panel schema is invalid" end
    if panel.agent_id ~= nil and not identity_id(panel.agent_id, "agent_id", true) then return false, "panel agent invalid" end
    if panel.attached_session_id ~= nil and not id(panel.attached_session_id, "session_id", true) then return false, "controller invalid" end
    local observers_ok = array_shape(panel.observer_session_ids, MAX_SESSIONS)
    if not observers_ok then return false, "observer list is not a dense array" end
    local observer_seen = {}
    for _, observer_id in ipairs(panel.observer_session_ids) do
      if not id(observer_id, "observer_session_id", true) or observer_seen[observer_id] then return false, "observer invalid" end
      observer_seen[observer_id] = true
    end
  end
  local events_ok, event_count = array_shape(value.events, MAX_EVENTS)
  if not events_ok then return false, "event collection is not a dense array" end
  if event_count > MAX_EVENTS then return false, "event aggregate is too large" end
  local event_seen = {}
  -- Reconstruct the authority-bearing portion of the lifecycle while walking
  -- the event log. Final records cannot authorize an earlier event: a session
  -- may have moved or detached several times after that event was emitted.
  local replay_sessions, replay_panels = {}, {}
  local panel_creations, session_creations = {}, {}
  for _, event in ipairs(value.events) do
    if type(event) == "table" then
      if event.type == "panel.created" and event.panel_id then
        panel_creations[event.panel_id] = (panel_creations[event.panel_id] or 0) + 1
      elseif event.type == "agent_session.created" and event.session_id then
        session_creations[event.session_id] = (session_creations[event.session_id] or 0) + 1
      end
    end
  end
  local complete_history = true
  for panel_id in pairs(value.panels) do
    if panel_creations[panel_id] ~= 1 then complete_history = false; break end
  end
  if complete_history then
    for session_id in pairs(value.sessions) do
      if session_creations[session_id] ~= 1 then complete_history = false; break end
    end
  end
  local function replay_session(session_id)
    local result = replay_sessions[session_id]
    if result then return result end
    local record = value.sessions[session_id]
    if not record then return nil end
    result = { panel_id = nil, state = nil, mode = nil, created = false }
    replay_sessions[session_id] = result
    return result
  end
  local function replay_panel(panel_id)
    local result = replay_panels[panel_id]
    if result then return result end
    if not value.panels[panel_id] then return nil end
    result = { state = nil, controller = nil, observers = {} }
    replay_panels[panel_id] = result
    return result
  end
  local function replay_remove(panel, session_id)
    if panel.controller == session_id then
      panel.controller = nil
      return true
    end
    if panel.observers[session_id] then
      panel.observers[session_id] = nil
      return true
    end
    return false
  end
  local function replay_observer_count(panel)
    local count = 0
    for _ in pairs(panel.observers) do count = count + 1 end
    return count
  end
  local function replay_detach_candidate(panel, event)
    -- The panel state transition identifies controller detaches whenever the
    -- controller's active/paused state is being reconciled. Observer-only
    -- transitions are identified by the observer list. Legacy detach events
    -- have no session ID, so use the smallest remaining observer for the
    -- otherwise ambiguous observer-only case; subsequent attach events still
    -- verify that session's historical mode and panel.
    if event.from_state == P.ACTIVE or event.from_state == P.PAUSED then
      if event.to_state == P.ATTACHED or event.to_state == P.DETACHED then
        return panel.controller
      end
    end
    if event.to_state == P.DETACHED and panel.controller then
      if replay_observer_count(panel) == 0 then return panel.controller end
    end
    local candidate
    for session_id in pairs(panel.observers) do
      if not candidate or session_id < candidate then candidate = session_id end
    end
    if candidate then return candidate end
    return panel.controller
  end
  for event_index, event in ipairs(value.events) do
    if type(event) ~= "table" or not event.event_id or not id(event.event_id, "event_id", true)
      or event_seen[event.event_id] or type(event.type) ~= "string" or not EVENT_TYPES[event.type]
      or not timestamp(event.timestamp_ms) then return false, "event schema is invalid" end
    event_seen[event.event_id] = true
    if event.session_id ~= nil and not id(event.session_id, "session_id", true) then return false, "event session id invalid" end
    if event.panel_id ~= nil and not id(event.panel_id, "panel_id", true) then return false, "event panel id invalid" end
    if event.agent_id ~= nil and not identity_id(event.agent_id, "agent_id", true) then return false, "event agent id invalid" end
    if event.task_id ~= nil and not id(event.task_id, "task_id", true) then return false, "event task id invalid" end
    if event.from_state ~= nil and not (LIVE[event.from_state] or TERMINAL[event.from_state] or PANEL_STATES[event.from_state]) then return false, "event source state invalid" end
    if event.to_state ~= nil and not (LIVE[event.to_state] or TERMINAL[event.to_state] or PANEL_STATES[event.to_state]) then return false, "event target state invalid" end
    if not exact_keys(event, {
      event_id=true, type=true, timestamp_ms=true, session_id=true, panel_id=true,
      agent_id=true, task_id=true, from_state=true, to_state=true, reason=true,
      recovery=true, checkpoint=true, mode=true, observer_session_id=true, transfer=true,
      controller_session_id=true,
    }) then return false, "event contains unknown fields" end
    local extras = {}
    for _, key in ipairs({ "reason", "recovery", "checkpoint", "mode", "observer_session_id", "controller_session_id", "transfer" }) do
      if event[key] ~= nil then extras[key] = event[key] end
    end
    local clean, err = event_extra(extras, true); if not clean then return false, err end
    if not valid_event_transition(event) then return false, "event transition is illegal" end
    for key, item in pairs(clean) do event[key] = item end
    if event.type == "panel.attached" and (event.mode ~= "controller" or not event.controller_session_id) then return false, "controller event mode or identity invalid" end
    if event.type == "panel.observer_attached"
      and (event.mode ~= "observer" or not event.observer_session_id) then return false, "observer event identity invalid" end
    if event.type == "agent_session.checkpointed" and not event.checkpoint then return false, "checkpoint event value missing" end
    if event.type == "agent_session.recovered" and not event.recovery then return false, "recovery event value missing" end
    if event.session_id ~= nil and not value.sessions[event.session_id] then return false, "event references unknown session" end
    if event.panel_id ~= nil and not value.panels[event.panel_id] then return false, "event references unknown panel" end
    if event.observer_session_id ~= nil and not value.sessions[event.observer_session_id] then return false, "event references unknown observer" end
    if event.type:match("^agent_session%.") and (not event.session_id or not event.panel_id or not event.agent_id) then
      return false, "session event lacks identity"
    end
    if event.type:match("^panel%.") and not event.panel_id then return false, "panel event lacks identity" end
    if event.type == "panel.created" then
      if replay_panels[event.panel_id] then
        if complete_history then return false, "panel history contains duplicate creation" end
        replay_panels[event.panel_id].incomplete = true
      else
        replay_panels[event.panel_id] = { state = event.to_state, controller = nil, observers = {} }
      end
    elseif event.type == "agent_session.created" then
      if replay_sessions[event.session_id] and replay_sessions[event.session_id].created then
        if complete_history then return false, "session history contains duplicate creation" end
        replay_sessions[event.session_id].incomplete = true
      else
        local session = replay_session(event.session_id)
        if not session then return false, "session history references unknown session" end
        session.panel_id, session.state, session.mode, session.created = event.panel_id, event.to_state, nil, true
      end
    elseif event.type:match("^agent_session%.") then
      local session = replay_session(event.session_id)
      if not session then return false, "session event references unknown session" end
      if not session.created then
        if complete_history then return false, "session event has no historical creation" end
        session.incomplete = true
      elseif not session.incomplete then
        if session.panel_id ~= event.panel_id then return false, "session event/panel mismatch" end
        if session.state ~= event.from_state then return false, "session event state mismatch" end
        if event.agent_id ~= value.sessions[event.session_id].agent_id
          or event.task_id ~= value.sessions[event.session_id].task_id then
          return false, "session event/owner mismatch"
        end
        if event.type == "agent_session.active" and session.mode == nil then
          local panel = replay_panel(event.panel_id)
          if not panel or panel.incomplete
            or (panel.state ~= P.READY and panel.state ~= P.DETACHED and panel.state ~= P.ATTACHED)
            or panel.controller then
            return false, "active session cannot establish controller authority"
          end
          panel.controller, session.mode = event.session_id, Lifecycle.AttachMode.CONTROLLER
        elseif event.type == "agent_session.active" and session.mode ~= Lifecycle.AttachMode.CONTROLLER then
          return false, "active session is not a controller"
        end
        session.state = event.to_state
      end
    elseif event.type == "panel.attached" or event.type == "panel.observer_attached" then
      local panel = replay_panel(event.panel_id)
      local referenced_id = event.type == "panel.observer_attached"
        and event.observer_session_id or event.controller_session_id
      local expected_mode = event.type == "panel.observer_attached"
        and Lifecycle.AttachMode.OBSERVER or Lifecycle.AttachMode.CONTROLLER
      local session = replay_session(referenced_id)
      if not panel or not session or not session.created then
        if complete_history then return false, "attachment event has no historical panel or session" end
        if panel then panel.incomplete = true end
        if session then session.incomplete = true end
      elseif not panel.incomplete and not session.incomplete then
        if event.session_id ~= referenced_id then return false, "attachment event/session identity mismatch" end
        if event.agent_id ~= value.sessions[referenced_id].agent_id
          or event.task_id ~= value.sessions[referenced_id].task_id then
          return false, "attachment event/session identity mismatch"
        end
        if panel.state ~= event.from_state then return false, "attachment event panel state mismatch" end
        if session.mode ~= nil then return false, "session was already attached at event time" end
        if event.transfer ~= true and session.panel_id ~= event.panel_id then
          return false, "attachment event/session panel mismatch"
        end
        if event.transfer == true and session.panel_id ~= nil and session.panel_id ~= event.panel_id then
          return false, "transfer attachment event/session panel mismatch"
        end
        if expected_mode == Lifecycle.AttachMode.CONTROLLER then
          if panel.controller then return false, "panel already had a controller at event time" end
          panel.controller = referenced_id
        else
          if panel.observers[referenced_id] then return false, "session was already an observer at event time" end
          panel.observers[referenced_id] = true
        end
        session.panel_id, session.mode = event.panel_id, expected_mode
        panel.state = event.to_state
      end
    elseif event.type == "panel.detached" then
      local panel = replay_panel(event.panel_id)
      if not panel then return false, "detach event has no historical panel" end
      if not panel.incomplete then
        if panel.state ~= event.from_state then return false, "detach event panel state mismatch" end
        local detached_id = event.session_id
        if detached_id then
          local session = replay_session(detached_id)
          if not session or not session.created or session.incomplete
            or session.panel_id ~= event.panel_id or not session.mode then
            return false, "transfer detach event/session mismatch"
          end
          if not replay_remove(panel, detached_id) then return false, "transfer detach session was not attached" end
          session.mode = nil
          if event.transfer == true then session.panel_id = nil end
        else
          detached_id = replay_detach_candidate(panel, event)
          if not detached_id or not replay_remove(panel, detached_id) then
            return false, "detach event has no historical attachment"
          end
          local session = replay_sessions[detached_id]
          if not session then return false, "detach event has no historical session" end
          session.mode = nil
        end
        panel.state = event.to_state
      end
    elseif event.type == "panel.ready" or event.type == "panel.active"
      or event.type == "panel.paused" or event.type == "panel.closed" then
      local panel = replay_panel(event.panel_id)
      if not panel then return false, "panel event references unknown panel" end
      if not panel.incomplete then
        if panel.state ~= event.from_state then return false, "panel event state mismatch" end
        if event.type == "panel.active" then
          if not panel.controller then return false, "active panel has no historical controller" end
          local controller = replay_sessions[panel.controller]
          if not controller or controller.incomplete or controller.state ~= S.ACTIVE then return false, "active panel controller state mismatch" end
        elseif event.type == "panel.paused" then
          if not panel.controller then return false, "paused panel has no historical controller" end
          local controller = replay_sessions[panel.controller]
          if not controller or controller.incomplete or controller.state ~= S.PAUSED then return false, "paused panel controller state mismatch" end
        elseif event.type == "panel.closed" and (panel.controller or replay_observer_count(panel) > 0) then
          return false, "closed panel has historical attachments"
        end
        panel.state = event.to_state
      end
    end
    if event.session_id then
      local owner = value.sessions[event.session_id]
      if event.agent_id and event.agent_id ~= owner.agent_id then return false, "event/session agent mismatch" end
      if event.task_id ~= owner.task_id then return false, "event/session task mismatch" end
    end
  end
  -- Relationship and uniqueness invariants are checked after all IDs exist.
  local controllers, observers = {}, {}
  for panel_id, panel in pairs(value.panels) do
    if panel.attached_session_id then
      local session = value.sessions[panel.attached_session_id]
      if not session or session.panel_id ~= panel_id or session.attachment_mode ~= "controller" then return false, "controller relationship invalid" end
      if controllers[panel.attached_session_id] then return false, "session controls two panels" end
      controllers[panel.attached_session_id] = true
    end
    for _, observer_id in ipairs(panel.observer_session_ids) do
      local session = value.sessions[observer_id]
      if not session or session.panel_id ~= panel_id or session.attachment_mode ~= "observer" or observers[observer_id] then return false, "observer relationship invalid" end
      observers[observer_id] = true
    end
    if panel.state == P.CLOSED and (panel.attached_session_id or #panel.observer_session_ids > 0) then
      return false, "closed panel has attachments"
    end
    if (panel.state == P.CREATED or panel.state == P.READY) and (panel.attached_session_id or #panel.observer_session_ids > 0) then
      return false, "unattached panel state has references"
    end
    if panel.state == P.DETACHED and (panel.attached_session_id or #panel.observer_session_ids > 0) then
      return false, "detached panel has references"
    end
    if panel.state == P.ATTACHED and not panel.attached_session_id and #panel.observer_session_ids == 0 then
      return false, "attached panel has no references"
    end
  end
  local agent_counts = {}
  for session_id, session in pairs(value.sessions) do
    if LIVE[session.state] then agent_counts[session.agent_id] = (agent_counts[session.agent_id] or 0) + 1 end
    if policy.max_sessions_per_agent and (agent_counts[session.agent_id] or 0) > policy.max_sessions_per_agent then return false, "loaded session policy exceeded" end
    if session.attachment_mode == "controller" and not controllers[session_id] then return false, "orphan controller" end
    if session.attachment_mode == "observer" and not observers[session_id] then return false, "orphan observer" end
    if session.state == S.ACTIVE and session.attachment_mode ~= "controller" then return false, "active observer" end
    if TERMINAL[session.state] and session.attachment_mode ~= nil then return false, "terminal session retains attachment" end
    if session.state == S.STALE and session.attachment_mode ~= nil then return false, "stale session retains attachment" end
    if session.attachment_mode == "controller" then
      local panel = value.panels[session.panel_id]
      if panel.agent_id and panel.agent_id ~= session.agent_id then return false, "controller owner mismatch" end
    end
    if session.state == S.ACTIVE then
      local panel = value.panels[session.panel_id]
      if not panel or panel.attached_session_id ~= session_id or panel.state ~= P.ACTIVE then return false, "active session and panel mismatch" end
    elseif session.state == S.PAUSED and session.attachment_mode == "controller" then
      local panel = value.panels[session.panel_id]
      if not panel or panel.attached_session_id ~= session_id
        or (panel.state ~= P.PAUSED and panel.state ~= P.ATTACHED) then return false, "paused session and panel mismatch" end
    end
  end
  for panel_id, panel in pairs(value.panels) do
    if panel.state == P.ACTIVE then
      local controller = panel.attached_session_id and value.sessions[panel.attached_session_id]
      if not controller or controller.state ~= S.ACTIVE then return false, "active panel lacks active controller" end
    elseif panel.state == P.PAUSED then
      local controller = panel.attached_session_id and value.sessions[panel.attached_session_id]
      if not controller or controller.state ~= S.PAUSED then return false, "paused panel lacks paused controller" end
    end
  end
  return true
end

local function state_payload(self, state)
  return { version = 1, revision = state.revision, policy = state.policy, next_counter = state.next_counter,
    sessions = state.sessions, panels = state.panels, events = state.events }
end
local function from_payload(value)
  return { revision = value.revision, policy = value.policy, next_counter = value.next_counter,
    sessions = value.sessions, panels = value.panels, events = value.events }
end

function Lifecycle.new(opts)
  opts = opts or {}
  local self = setmetatable({}, Lifecycle)
  self.path = opts.path
  self.policy = { max_sessions_per_agent = opts.max_sessions_per_agent == nil and 1 or opts.max_sessions_per_agent,
    allow_multiple_tasks = opts.allow_multiple_tasks ~= false }
  if self.policy.max_sessions_per_agent ~= nil and (not finite(self.policy.max_sessions_per_agent)
    or self.policy.max_sessions_per_agent < 1 or self.policy.max_sessions_per_agent % 1 ~= 0
    or self.policy.max_sessions_per_agent > MAX_SESSIONS) then error("invalid session policy") end
  self.revision, self.next_counter = 0, 0
  self.sessions, self.panels, self.events_log = {}, {}, {}
  if self.path then
    local ok, err = self:load()
    if not ok then error(err, 0) end
  end
  return self
end

function Lifecycle:_state()
  return { revision = self.revision, policy = copy(self.policy), next_counter = self.next_counter,
    sessions = copy(self.sessions), panels = copy(self.panels), events = copy(self.events_log) }
end
function Lifecycle:_next_id(state, prefix)
  state.next_counter = state.next_counter + 1
  local candidate = generated(prefix, state.next_counter)
  local exists = true
  while exists do
    exists = false
    for key in pairs(state.sessions) do if key == candidate then exists = true end end
    for key in pairs(state.panels) do if key == candidate then exists = true end end
    for _, event in ipairs(state.events) do if event.event_id == candidate then exists = true end end
    if exists then state.next_counter = state.next_counter + 1; candidate = generated(prefix, state.next_counter) end
  end
  return candidate
end
function Lifecycle:_commit_locked(state)
  local valid, err = registry_shape({ version = 1, revision = state.revision, policy = state.policy,
    next_counter = state.next_counter, sessions = state.sessions, panels = state.panels, events = state.events })
  if not valid then return false, { code = "E_LIFECYCLE_INVALID", message = err } end
  local info = WheelHost.fs.stat(self.path)
  if info and info.exists then
    local safe, safe_err = safe_registry_target(self.path, false)
    if not safe then return false, { code = "E_LIFECYCLE_PATH", message = safe_err } end
    local raw = WheelHost.fs.read_file_bounded(self.path, MAX_REGISTRY_BYTES)
    local decoded_ok, decoded = pcall(Session.json_decode, raw or "")
    if not decoded_ok or type(decoded) ~= "table" then
      return false, { code = "E_LIFECYCLE_INVALID", message = "registry cannot be decoded" }
    end
    local disk_ok, disk_err = registry_shape(decoded)
    if not disk_ok then return false, { code = "E_LIFECYCLE_INVALID", message = disk_err } end
    if decoded.revision ~= self.revision then
      return false, { code = "E_LIFECYCLE_CONFLICT", message = "registry revision changed on disk" }
    end
  elseif self.revision ~= 0 then
    return false, { code = "E_LIFECYCLE_CONFLICT", message = "registry disappeared" }
  end
  if self.revision >= MAX_SAFE_INTEGER then
    return false, { code = "E_LIFECYCLE_LIMIT", message = "registry revision limit reached" }
  end
  state.revision = self.revision + 1
  local payload = Session.json_encode(state_payload(self, state))
  if #payload > MAX_REGISTRY_BYTES then return false, { code = "E_LIFECYCLE_LIMIT", message = "registry byte limit reached" } end
  local temporary = self.path .. ".tmp." .. generated("write", state.next_counter)
  self._temporary_path = temporary
  local staged, stage_err = WheelHost.fs.create_private_file(temporary, payload)
  if not staged then self._temporary_path = nil; return false, { code = "E_LIFECYCLE_PERSIST", message = stage_err or "cannot stage registry" } end
  local parent_ok, parent_err = safe_registry_path(self.path)
  if not parent_ok then WheelHost.fs.remove_file(temporary); self._temporary_path = nil; return false, { code = "E_LIFECYCLE_PATH", message = parent_err } end
  local target_ok, target_err = safe_registry_target(self.path, true)
  if not target_ok then WheelHost.fs.remove_file(temporary); self._temporary_path = nil; return false, { code = "E_LIFECYCLE_PATH", message = target_err } end
  local published, publish_err = WheelHost.fs.rename(temporary, self.path)
  if not published then WheelHost.fs.remove_file(temporary); self._temporary_path = nil; return false, { code = "E_LIFECYCLE_PERSIST", message = publish_err or "cannot publish registry" } end
  self._temporary_path = nil
  return true
end

function Lifecycle:_commit(state)
  if not self.path then
    local valid, err = registry_shape({ version = 1, revision = state.revision, policy = state.policy,
      next_counter = state.next_counter, sessions = state.sessions, panels = state.panels, events = state.events })
    if not valid then return false, { code = "E_LIFECYCLE_INVALID", message = err } end
    self.revision, self.policy, self.next_counter = state.revision, state.policy, state.next_counter
    self.sessions, self.panels, self.events_log = state.sessions, state.panels, state.events
    return true
  end
  local path_ok, path_err = safe_registry_path(self.path)
  if not path_ok then return false, { code = "E_LIFECYCLE_PATH", message = path_err } end
  local parent = self.path:match("^(.*)/[^/]+$") or "."
  local lock_name = (self.path:match("([^/]+)$") or "registry") .. ".lock"
  local owner_pid = WheelHost.proc.pid()
  local acquired, acquire_err = Session.acquire_lock(parent, lock_name, owner_pid)
  if not acquired then return false, { code = "E_LIFECYCLE_BUSY", message = acquire_err and acquire_err.message or "registry is locked" } end
  local protected, ok, result = pcall(function()
    local committed, commit_err = self:_commit_locked(state)
    return committed, commit_err
  end)
  if self._temporary_path then pcall(WheelHost.fs.remove_file, self._temporary_path); self._temporary_path = nil end
  local released, release_err = pcall(Session.release_lock, parent, lock_name, owner_pid)
  if not protected then return false, { code = "E_LIFECYCLE_PERSIST", message = "registry commit failed safely" } end
  if not ok then return false, result end
  self.revision, self.policy, self.next_counter = state.revision, state.policy, state.next_counter
  self.sessions, self.panels, self.events_log = state.sessions, state.panels, state.events
  -- Publication already committed. Do not report a failed transaction that a
  -- caller could retry: expose cleanup trouble separately and keep the new
  -- revision visible. The ownership-checked lock remains fail-closed.
  if not released or release_err == false then
    self.persistence_warning = { code = "E_LIFECYCLE_LOCK", message = "registry committed; lock cleanup failed" }
  else
    self.persistence_warning = nil
  end
  return true
end
function Lifecycle:_change(fn)
  local state = self:_state()
  local called, result, err = pcall(fn, state)
  if not called then return fail("E_LIFECYCLE_INTERNAL", "lifecycle transition failed safely") end
  if result == false then return nil, err end
  local ok, persist_err = self:_commit(state)
  if not ok then return nil, persist_err end
  return result
end
function Lifecycle:load()
  if not self.path then return true end
  local target_ok, target_err = safe_registry_target(self.path, true)
  if not target_ok then return false, { code = "E_LIFECYCLE_PATH", message = target_err } end
  local info = WheelHost.fs.stat(self.path)
  if not info.exists then return true end
  local raw = WheelHost.fs.read_file_bounded(self.path, MAX_REGISTRY_BYTES)
  if not raw or #raw >= MAX_REGISTRY_BYTES then
    quarantine_registry(self.path)
    return false, { code = "E_LIFECYCLE_INVALID", message = "registry is oversized" }
  end
  local ok, decoded = pcall(Session.json_decode, raw)
  local valid, err = ok and registry_shape(decoded)
  if not valid then
    -- Never overwrite a malformed input. Rename only verified regular files;
    -- symlinks are rejected above and remain untouched.
    quarantine_registry(self.path)
    return false, { code = "E_LIFECYCLE_INVALID", message = err or "registry is invalid" }
  end
  local state = from_payload(decoded)
  self.revision, self.policy, self.next_counter = state.revision, state.policy, state.next_counter
  self.sessions, self.panels, self.events_log = state.sessions, state.panels, state.events
  return true
end
function Lifecycle:save() return self:_commit(self:_state()) end
function Lifecycle:get_session(session_id) return copy(self.sessions[session_id]) end
function Lifecycle:get_panel(panel_id) return copy(self.panels[panel_id]) end
function Lifecycle:list_sessions(agent_id)
  local result = {}; for _, value in pairs(self.sessions) do if not agent_id or value.agent_id == agent_id then result[#result + 1] = copy(value) end end
  table.sort(result, function(a, b) return a.session_id < b.session_id end); return result
end
function Lifecycle:list_panels()
  local result = {}; for _, value in pairs(self.panels) do result[#result + 1] = copy(value) end
  table.sort(result, function(a, b) return a.panel_id < b.panel_id end); return result
end
function Lifecycle:events(limit)
  local result = {}; local first = limit and math.max(1, #self.events_log - limit + 1) or 1
  for i = first, #self.events_log do result[#result + 1] = copy(self.events_log[i]) end; return result
end
function Lifecycle:create_panel(opts)
  opts = opts or {}
  return self:_change(function(state)
    local panel_id, err = id(opts.panel_id or self:_next_id(state, "panel"), "panel_id", true); if not panel_id then return false, { code="E_LIFECYCLE_INVALID", message=err } end
    if state.panels[panel_id] then return false, { code="E_LIFECYCLE_EXISTS", message="panel already exists" } end
    local agent_id; agent_id, err = identity_id(opts.agent_id, "agent_id", false); if opts.agent_id ~= nil and not agent_id then return false, { code="E_LIFECYCLE_INVALID", message=err } end
    local kind; kind, err = text(opts.kind or "headless", "panel kind", true)
    if not kind then return false, { code="E_LIFECYCLE_INVALID", message=err } end
    if opts.headless ~= nil and type(opts.headless) ~= "boolean" then return false, { code="E_LIFECYCLE_INVALID", message="headless must be boolean" } end
    local record = { panel_id=panel_id, kind=kind, headless=opts.headless ~= false, agent_id=agent_id, state=P.CREATED, attached_session_id=nil, observer_session_ids={}, created_at_ms=now_ms(), updated_at_ms=now_ms() }
    state.panels[panel_id] = record; local event, event_err = new_event(state, "panel.created", record, nil, P.CREATED, nil, function(prefix) return self:_next_id(state, prefix) end); if not event then return false, { code="E_LIFECYCLE_INVALID", message=event_err } end
    return copy(record)
  end)
end
function Lifecycle:ready_panel(panel_id)
  return self:_change(function(state)
    local panel = state.panels[panel_id]; if not panel then return false, { code="E_LIFECYCLE_NOT_FOUND", message="panel not found" } end
    if panel.state ~= P.CREATED then return false, { code="E_LIFECYCLE_STATE", message="panel must be created before ready" } end
    local from = panel.state; panel.state, panel.updated_at_ms = P.READY, now_ms(); new_event(state, "panel.ready", panel, from, panel.state, nil, function(prefix) return self:_next_id(state, prefix) end); return copy(panel)
  end)
end
function Lifecycle:create_agent_session(opts)
  opts = opts or {}
  return self:_change(function(state)
    local agent_id, err = identity_id(opts.agent_id, "agent_id", true); if not agent_id then return false, { code="E_LIFECYCLE_INVALID", message=err } end
    local panel_id; panel_id, err = id(opts.panel_id, "panel_id", true); if not panel_id then return false, { code="E_LIFECYCLE_INVALID", message=err } end
    if not state.panels[panel_id] then return false, { code="E_LIFECYCLE_NOT_FOUND", message="panel not found" } end
    local live_count = 0; for _, item in pairs(state.sessions) do if item.agent_id == agent_id and LIVE[item.state] then live_count = live_count + 1 end end
    if state.policy.max_sessions_per_agent and live_count >= state.policy.max_sessions_per_agent then return false, { code="E_LIFECYCLE_POLICY", message="agent session policy limit reached" } end
    if not state.policy.allow_multiple_tasks then
      for _, item in pairs(state.sessions) do
        if item.agent_id == agent_id and LIVE[item.state] then
          return false, { code="E_LIFECYCLE_POLICY", message="agent cannot own multiple live session tasks" }
        end
      end
    end
    local session_count = 0
    for _ in pairs(state.sessions) do session_count = session_count + 1 end
    if session_count >= MAX_SESSIONS then
      local prune_id, prune_time
      for existing_id, item in pairs(state.sessions) do
        if TERMINAL[item.state] and (not prune_time or item.updated_at_ms < prune_time) then
          prune_id, prune_time = existing_id, item.updated_at_ms
        end
      end
      if not prune_id then return false, { code="E_LIFECYCLE_LIMIT", message="session registry is full" } end
      state.sessions[prune_id] = nil
      for index = #state.events, 1, -1 do
        if state.events[index].session_id == prune_id or state.events[index].observer_session_id == prune_id then table.remove(state.events, index) end
      end
    end
    local session_id; session_id, err = id(opts.session_id or self:_next_id(state, "session"), "session_id", true); if not session_id then return false, { code="E_LIFECYCLE_INVALID", message=err } end
    if state.sessions[session_id] then return false, { code="E_LIFECYCLE_EXISTS", message="session already exists" } end
    local task_id; task_id, err = id(opts.task_id, "task_id", false); if opts.task_id ~= nil and not task_id then return false, { code="E_LIFECYCLE_INVALID", message=err } end
    local branch = opts.context_branch or "(detached)"; branch, err = text(branch, "context_branch", true); if not branch then return false, { code="E_LIFECYCLE_INVALID", message=err } end
    local head = opts.context_head; if not safe_context_head(head) then return false, { code="E_LIFECYCLE_INVALID", message="context_head is invalid" } end
    local metadata_budget = { keys = 0, bytes = 0 }
    local role; role, err = metadata(opts.role_binding or { role = opts.role or "coding" }, 0, metadata_budget); if not role then return false, { code="E_LIFECYCLE_INVALID", message=err } end
    local model; model, err = metadata(opts.model_profile or { provider="unconfigured", model="unconfigured" }, 0, metadata_budget); if not model then return false, { code="E_LIFECYCLE_INVALID", message=err } end
    local worktree; worktree, err = id(opts.worktree_id, "worktree_id", false); if opts.worktree_id ~= nil and not worktree then return false, { code="E_LIFECYCLE_INVALID", message=err } end
    local record = { agent_id=agent_id, session_id=session_id, panel_id=panel_id, task_id=task_id, context_branch=branch, context_head=head, role_binding=role, model_profile=model, worktree_id=worktree, state=S.CREATED, checkpoint=nil, created_at_ms=now_ms(), updated_at_ms=now_ms(), recovered_from=nil, attachment_mode=nil }
    state.sessions[session_id] = record; local event, event_err = new_event(state, "agent_session.created", record, nil, S.CREATED, nil, function(prefix) return self:_next_id(state, prefix) end); if not event then return false, { code="E_LIFECYCLE_INVALID", message=event_err } end
    return copy(record)
  end)
end
function Lifecycle:_session_in(state, session_id)
  local record = state.sessions[session_id]; if not record then return nil, { code="E_LIFECYCLE_NOT_FOUND", message="agent session not found" } end; return record
end
function Lifecycle:_detach_refs(state, record, reason_text)
  for _, panel in pairs(state.panels) do
    local changed = false
    if panel.attached_session_id == record.session_id then panel.attached_session_id = nil; changed = true end
    if array_has(panel.observer_session_ids, record.session_id) then array_remove(panel.observer_session_ids, record.session_id); changed = true end
    if changed then
      local from = panel.state
      reconcile_panel(panel)
      panel.updated_at_ms = now_ms()
      new_event(state, "panel.detached", panel, from, panel.state, { reason = reason_text }, function(prefix) return self:_next_id(state, prefix) end)
    end
  end
  record.attachment_mode = nil
end
function Lifecycle:activate_session(session_id)
  return self:_change(function(state)
    local record, err = self:_session_in(state, session_id); if not record then return false, err end
    if record.attachment_mode == Lifecycle.AttachMode.OBSERVER then return false, { code="E_LIFECYCLE_AUTHORITY", message="observer cannot become active" } end
    if record.state ~= S.CREATED and record.state ~= S.PAUSED then return false, { code="E_LIFECYCLE_STATE", message="only created or paused sessions can activate" } end
    local panel = state.panels[record.panel_id]; if not panel or PANEL_TERMINAL[panel.state] then return false, { code="E_LIFECYCLE_STATE", message="session panel is unavailable" } end
    if panel.attached_session_id and panel.attached_session_id ~= session_id then return false, { code="E_LIFECYCLE_PANEL_BUSY", message="panel already has a controller" } end
    if panel.agent_id and panel.agent_id ~= record.agent_id then return false, { code="E_LIFECYCLE_AUTHORITY", message="session agent does not own panel" } end
    if record.attachment_mode == nil then
      if panel.state ~= P.READY and panel.state ~= P.DETACHED and panel.state ~= P.ATTACHED then return false, { code="E_LIFECYCLE_STATE", message="panel is not attachable" } end
      panel.attached_session_id = session_id; record.attachment_mode = Lifecycle.AttachMode.CONTROLLER
    end
    local from = record.state; record.state, record.updated_at_ms = S.ACTIVE, now_ms(); local panel_from = panel.state; panel.state, panel.updated_at_ms = P.ACTIVE, now_ms()
    new_event(state, "agent_session.active", record, from, record.state, nil, function(prefix) return self:_next_id(state, prefix) end); new_event(state, "panel.active", panel, panel_from, panel.state, nil, function(prefix) return self:_next_id(state, prefix) end); return copy(record)
  end)
end
function Lifecycle:pause_session(session_id, pause_reason)
  return self:_change(function(state)
    local record, err = self:_session_in(state, session_id); if not record then return false, err end
    if record.state ~= S.ACTIVE then return false, { code="E_LIFECYCLE_STATE", message="only active sessions can pause" } end
    local clean, reason_err = reason(pause_reason, "reason"); if pause_reason ~= nil and not clean then return false, { code="E_LIFECYCLE_INVALID", message=reason_err } end
    local panel = state.panels[record.panel_id]; local from = record.state; record.state, record.updated_at_ms = S.PAUSED, now_ms(); new_event(state, "agent_session.paused", record, from, record.state, { reason=clean }, function(prefix) return self:_next_id(state, prefix) end)
    if panel and panel.attached_session_id == session_id then local pf = panel.state; panel.state, panel.updated_at_ms = P.PAUSED, now_ms(); new_event(state, "panel.paused", panel, pf, panel.state, { reason=clean }, function(prefix) return self:_next_id(state, prefix) end) end; return copy(record)
  end)
end
function Lifecycle:mark_stale(session_id, stale_reason)
  return self:_change(function(state)
    local record, err = self:_session_in(state, session_id); if not record then return false, err end
    if record.state ~= S.ACTIVE and record.state ~= S.PAUSED then return false, { code="E_LIFECYCLE_STATE", message="only active or paused sessions can become stale" } end
    local clean, reason_err = reason(stale_reason, "reason"); if stale_reason ~= nil and not clean then return false, { code="E_LIFECYCLE_INVALID", message=reason_err } end
    local from = record.state; record.state, record.updated_at_ms = S.STALE, now_ms(); self:_detach_refs(state, record, clean or "stale"); new_event(state, "agent_session.stale", record, from, record.state, { reason=clean }, function(prefix) return self:_next_id(state, prefix) end); return copy(record)
  end)
end
function Lifecycle:recover_session(session_id, opts)
  opts = opts or {}
  return self:_change(function(state)
    local record, err = self:_session_in(state, session_id); if not record then return false, err end
    if record.state ~= S.STALE then return false, { code="E_LIFECYCLE_STATE", message="only stale sessions can be recovered" } end
    local recovery, recovery_err = reason(opts.recovery or "manual", "recovery"); if not recovery then return false, { code="E_LIFECYCLE_INVALID", message=recovery_err } end
    record.state, record.recovered_from, record.updated_at_ms = S.PAUSED, "stale", now_ms(); new_event(state, "agent_session.recovered", record, S.STALE, S.PAUSED, { recovery=recovery }, function(prefix) return self:_next_id(state, prefix) end); return copy(record)
  end)
end
function Lifecycle:checkpoint_session(session_id, checkpoint)
  return self:_change(function(state)
    local record, err = self:_session_in(state, session_id); if not record then return false, err end
    if TERMINAL[record.state] then return false, { code="E_LIFECYCLE_STATE", message="terminal session cannot checkpoint" } end
    local clean, checkpoint_err = id(checkpoint, "checkpoint", true); if not clean then return false, { code="E_LIFECYCLE_INVALID", message=checkpoint_err } end
    record.checkpoint, record.updated_at_ms = clean, now_ms(); new_event(state, "agent_session.checkpointed", record, record.state, record.state, { checkpoint=clean }, function(prefix) return self:_next_id(state, prefix) end); return copy(record)
  end)
end
function Lifecycle:resume_session(session_id)
  local record = self.sessions[session_id]; if not record or record.state ~= S.PAUSED then return fail("E_LIFECYCLE_STATE", "only paused sessions can resume") end
  return self:activate_session(session_id)
end
function Lifecycle:detach_session(session_id, opts)
  opts = opts or {}
  return self:_change(function(state)
    local record, err = self:_session_in(state, session_id); if not record then return false, err end
    if not record.attachment_mode then return false, { code="E_LIFECYCLE_STATE", message="session is not attached" } end
    local panel = state.panels[record.panel_id]; if not panel then return false, { code="E_LIFECYCLE_STATE", message="session panel is unavailable" } end
    local was_controller = record.attachment_mode == Lifecycle.AttachMode.CONTROLLER; if was_controller and panel.attached_session_id ~= session_id then return false, { code="E_LIFECYCLE_STATE", message="session is not the panel controller" } end
    local clean, reason_err = reason(opts.reason or "explicit", "reason"); if not clean then return false, { code="E_LIFECYCLE_INVALID", message=reason_err } end
    if was_controller then panel.attached_session_id = nil else array_remove(panel.observer_session_ids, session_id) end
    record.attachment_mode = nil; record.updated_at_ms = now_ms(); local pf = panel.state; reconcile_panel(panel); panel.updated_at_ms = now_ms(); new_event(state, "panel.detached", panel, pf, panel.state, { reason=clean }, function(prefix) return self:_next_id(state, prefix) end)
    if record.state == S.ACTIVE then local sf = record.state; record.state, record.updated_at_ms = S.PAUSED, now_ms(); new_event(state, "agent_session.paused", record, sf, record.state, { reason="panel_detached" }, function(prefix) return self:_next_id(state, prefix) end) end; return copy(record)
  end)
end
function Lifecycle:attach_session(session_id, panel_id, opts)
  opts = opts or {}
  return self:_change(function(state)
    local record, err = self:_session_in(state, session_id); if not record then return false, err end
    if record.state ~= S.CREATED and record.state ~= S.PAUSED then return false, { code="E_LIFECYCLE_STATE", message="only created or paused sessions can attach" } end
    local mode = opts.mode or Lifecycle.AttachMode.CONTROLLER; if mode ~= Lifecycle.AttachMode.CONTROLLER and mode ~= Lifecycle.AttachMode.OBSERVER then return false, { code="E_LIFECYCLE_INVALID", message="unsupported attach mode" } end
    local panel = state.panels[panel_id or record.panel_id]; if not panel then return false, { code="E_LIFECYCLE_NOT_FOUND", message="panel not found" } end
    if PANEL_TERMINAL[panel.state] then return false, { code="E_LIFECYCLE_STATE", message="closed panel cannot attach" } end
    if mode == Lifecycle.AttachMode.CONTROLLER
      and panel.agent_id ~= nil and panel.agent_id ~= record.agent_id then
      return false, { code="E_LIFECYCLE_AUTHORITY", message="session agent does not own panel" }
    end
    if panel.state == P.CREATED or (mode == Lifecycle.AttachMode.CONTROLLER
      and (panel.state == P.ACTIVE or panel.state == P.PAUSED)) then
      return false, { code="E_LIFECYCLE_STATE", message="panel is not attachable in its current state" }
    end
    if record.attachment_mode then return false, { code="E_LIFECYCLE_AUTHORITY", message="session is already attached" } end
    if panel.panel_id ~= record.panel_id then
      return false, { code="E_LIFECYCLE_TRANSFER_REQUIRED", message="detach and explicitly transfer before changing panels" }
    end
    if mode == Lifecycle.AttachMode.OBSERVER and record.state == S.ACTIVE then return false, { code="E_LIFECYCLE_AUTHORITY", message="active controller cannot become observer" } end
    if mode == Lifecycle.AttachMode.CONTROLLER and (panel.attached_session_id or #panel.observer_session_ids > 0 and panel.state == P.ACTIVE) then
      if panel.attached_session_id and panel.attached_session_id ~= session_id then return false, { code="E_LIFECYCLE_PANEL_BUSY", message="panel already has a controller" } end
    end
    if mode == Lifecycle.AttachMode.OBSERVER then
      if not array_has(panel.observer_session_ids, session_id) then panel.observer_session_ids[#panel.observer_session_ids + 1] = session_id end
    else panel.attached_session_id = session_id end
    record.panel_id, record.attachment_mode, record.updated_at_ms = panel.panel_id, mode, now_ms(); local from = panel.state
    if panel.state == P.READY or panel.state == P.DETACHED then panel.state = P.ATTACHED end; panel.updated_at_ms = now_ms()
    local kind = mode == Lifecycle.AttachMode.OBSERVER and "panel.observer_attached" or "panel.attached"; new_event(state, kind, record, from, panel.state, { mode=mode, observer_session_id=mode == "observer" and session_id or nil, controller_session_id=mode == "controller" and session_id or nil, transfer=opts.transfer == true }, function(prefix) return self:_next_id(state, prefix) end); return copy(record)
  end)
end
function Lifecycle:transfer_session(session_id, panel_id, opts)
  opts = opts or {}
  return self:_change(function(state)
    local record, err = self:_session_in(state, session_id); if not record then return false, err end
    if TERMINAL[record.state] then return false, { code="E_LIFECYCLE_STATE", message="terminal session cannot transfer" } end
    if not record.attachment_mode then return false, { code="E_LIFECYCLE_STATE", message="session is not attached" } end
    local target = state.panels[panel_id]
    if not target or PANEL_TERMINAL[target.state] then return false, { code="E_LIFECYCLE_STATE", message="target panel is unavailable" } end
    local mode = opts.mode or record.attachment_mode
    if mode ~= Lifecycle.AttachMode.CONTROLLER and mode ~= Lifecycle.AttachMode.OBSERVER then return false, { code="E_LIFECYCLE_INVALID", message="unsupported transfer mode" } end
    if mode ~= record.attachment_mode then return false, { code="E_LIFECYCLE_AUTHORITY", message="transfer cannot change attachment authority" } end
    if target.state == P.CREATED then return false, { code="E_LIFECYCLE_STATE", message="target panel is not ready" } end
    if mode == Lifecycle.AttachMode.CONTROLLER and target.agent_id ~= nil and target.agent_id ~= record.agent_id then
      return false, { code="E_LIFECYCLE_AUTHORITY", message="session agent does not own target panel" }
    end
    if mode == Lifecycle.AttachMode.CONTROLLER and target.attached_session_id
      and target.attached_session_id ~= session_id then
      return false, { code="E_LIFECYCLE_PANEL_BUSY", message="target panel already has a controller" }
    end
    local source = state.panels[record.panel_id]
    if not source then return false, { code="E_LIFECYCLE_STATE", message="source panel is unavailable" } end
    if record.attachment_mode == Lifecycle.AttachMode.CONTROLLER then
      if source.attached_session_id ~= session_id then
        return false, { code="E_LIFECYCLE_STATE", message="session is not the source controller" }
      end
      source.attached_session_id = nil
    else
      array_remove(source.observer_session_ids, session_id)
    end
    local source_from = source.state
    reconcile_panel(source)
    source.updated_at_ms = now_ms()
    local source_record = {
      panel_id = source.panel_id,
      session_id = record.session_id,
      agent_id = record.agent_id,
      task_id = record.task_id,
    }
    local target_panel_id = target.panel_id
    new_event(state, "panel.detached", {
      panel_id = source_record.panel_id,
      session_id = source_record.session_id,
      agent_id = source_record.agent_id,
      task_id = source_record.task_id,
    }, source_from, source.state, { reason="transfer", transfer=true }, function(prefix) return self:_next_id(state, prefix) end)
    if mode == Lifecycle.AttachMode.OBSERVER then
      if not array_has(target.observer_session_ids, session_id) then target.observer_session_ids[#target.observer_session_ids + 1] = session_id end
    else
      target.attached_session_id = session_id
    end
    record.panel_id, record.attachment_mode, record.updated_at_ms = target_panel_id, mode, now_ms()
    local target_from = target.state
    if record.state == S.ACTIVE and mode == Lifecycle.AttachMode.CONTROLLER then target.state = P.ACTIVE
    elseif target.state == P.CREATED or target.state == P.READY or target.state == P.DETACHED then target.state = P.ATTACHED end
    target.updated_at_ms = now_ms()
    new_event(state, mode == Lifecycle.AttachMode.OBSERVER and "panel.observer_attached" or "panel.attached",
      record, target_from, target.state, { mode=mode, observer_session_id=mode == "observer" and session_id or nil, controller_session_id=mode == "controller" and session_id or nil, transfer=true },
      function(prefix) return self:_next_id(state, prefix) end)
    return copy(record)
  end)
end
function Lifecycle:close_panel(panel_id, close_reason)
  return self:_change(function(state)
    local panel = state.panels[panel_id]; if not panel then return false, { code="E_LIFECYCLE_NOT_FOUND", message="panel not found" } end
    if panel.state == P.CLOSED or panel.attached_session_id or #panel.observer_session_ids > 0 then return false, { code="E_LIFECYCLE_STATE", message="panel attachments must be cleaned before closing" } end
    local clean, reason_err = reason(close_reason or "explicit", "reason"); if not clean then return false, { code="E_LIFECYCLE_INVALID", message=reason_err } end
    local from = panel.state; panel.state, panel.updated_at_ms = P.CLOSED, now_ms(); new_event(state, "panel.closed", panel, from, panel.state, { reason=clean }, function(prefix) return self:_next_id(state, prefix) end); return copy(panel)
  end)
end
function Lifecycle:end_session(session_id, end_reason)
  return self:_finish(session_id, S.ENDED, end_reason or "explicit")
end
function Lifecycle:abandon_session(session_id, abandon_reason)
  return self:_finish(session_id, S.ABANDONED, abandon_reason or "recovery")
end
function Lifecycle:_finish(session_id, target, finish_reason)
  return self:_change(function(state)
    local record, err = self:_session_in(state, session_id); if not record then return false, err end
    if TERMINAL[record.state] then return false, { code="E_LIFECYCLE_STATE", message="session is already terminal" } end
    local clean, reason_err = reason(finish_reason, "reason"); if not clean then return false, { code="E_LIFECYCLE_INVALID", message=reason_err } end
    self:_detach_refs(state, record, target == S.ENDED and "session_ended" or "session_abandoned")
    local from = record.state; record.state, record.updated_at_ms = target, now_ms(); new_event(state, target == S.ENDED and "agent_session.ended" or "agent_session.abandoned", record, from, target, { reason=clean }, function(prefix) return self:_next_id(state, prefix) end); return copy(record)
  end)
end

Lifecycle.create_session = Lifecycle.create_agent_session
Lifecycle.activate = Lifecycle.activate_session
Lifecycle.pause = Lifecycle.pause_session
Lifecycle.resume = Lifecycle.resume_session
Lifecycle.detach = Lifecycle.detach_session
Lifecycle.attach = Lifecycle.attach_session
Lifecycle.checkpoint = Lifecycle.checkpoint_session
Lifecycle.stale = Lifecycle.mark_stale
Lifecycle.recover = Lifecycle.recover_session

return Lifecycle
