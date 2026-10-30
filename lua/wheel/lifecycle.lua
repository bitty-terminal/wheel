-- Wheel runtime lifecycle records.
--
-- This module models the harness-side relationship between an Agent identity,
-- its AgentSession records, and headless Panel records.  It deliberately
-- stores identifiers and lifecycle metadata only.  Prompt, transcript,
-- context-slot, provider-response, and tool-output content never belongs in a
-- lifecycle record or event.

local WheelHost = require("wheel.host")
local Session = require("wheel.session")
local PRIVATE_FILE_MODE_STRING = "600"

local Lifecycle = {}
Lifecycle.__index = Lifecycle

Lifecycle.AgentSessionState = {
  CREATED = "created",
  ACTIVE = "active",
  PAUSED = "paused",
  STALE = "stale",
  ENDED = "ended",
  ABANDONED = "abandoned",
}

Lifecycle.PanelState = {
  CREATED = "created",
  READY = "ready",
  ATTACHED = "attached",
  ACTIVE = "active",
  PAUSED = "paused",
  DETACHED = "detached",
  CLOSED = "closed",
}

Lifecycle.AttachMode = {
  CONTROLLER = "controller",
  OBSERVER = "observer",
}

local SESSION_TERMINAL = {
  [Lifecycle.AgentSessionState.ENDED] = true,
  [Lifecycle.AgentSessionState.ABANDONED] = true,
}

local PANEL_TERMINAL = {
  [Lifecycle.PanelState.CLOSED] = true,
}

local ACTIVE_SESSION_STATES = {
  [Lifecycle.AgentSessionState.CREATED] = true,
  [Lifecycle.AgentSessionState.ACTIVE] = true,
  [Lifecycle.AgentSessionState.PAUSED] = true,
  [Lifecycle.AgentSessionState.STALE] = true,
}

local function clone(value, depth)
  if type(value) ~= "table" then
    return value
  end
  depth = depth or 0
  if depth > 8 then
    return nil
  end
  local result = {}
  for key, item in pairs(value) do
    local copied = clone(item, depth + 1)
    if copied ~= nil then
      result[key] = copied
    end
  end
  return result
end

local function now_ms()
  return WheelHost.time.now() * 1000
end

local function value_string(value, label, required)
  if value == nil and not required then
    return nil
  end
  if type(value) ~= "string" or value == "" or #value > 256 then
    return nil, label .. " must be a non-empty string of at most 256 bytes"
  end
  if value:find("[%z\1-\31]") then
    return nil, label .. " contains a control character"
  end
  return value
end

local function id_string(value, label, required)
  local result, err = value_string(value, label, required)
  if not result then
    return nil, err
  end
  if result and not result:match("^[A-Za-z0-9][A-Za-z0-9._:/%-]*$") then
    return nil, label .. " contains unsupported characters"
  end
  return result
end

local function error_record(code, message)
  return { code = code, message = message }
end

local function transition_error(code, message)
  return nil, error_record(code, message)
end

local function event_copy(event)
  local result = clone(event)
  result.data = nil
  return result
end

local function generated_id(prefix, counter)
  local pid = WheelHost.proc.pid() or 0
  return string.format("%s-%d-%d-%d", prefix, math.floor(now_ms()), pid, counter)
end

local function contains(list, value)
  for _, item in ipairs(list) do
    if item == value then
      return true
    end
  end
  return false
end

local function copy_array(list)
  local result = {}
  for _, item in ipairs(list or {}) do
    result[#result + 1] = item
  end
  return result
end

local FORBIDDEN_METADATA_KEYS = {
  content = true,
  prompt = true,
  transcript = true,
  output = true,
  response = true,
}

local function sanitize_metadata(value, depth)
  if value == nil then return nil end
  local kind = type(value)
  if kind == "string" or kind == "number" or kind == "boolean" then
    if kind == "string" and #value > 256 then return nil, "metadata string is too large" end
    return value
  end
  if kind ~= "table" then return nil, "metadata must contain plain values" end
  depth = depth or 0
  if depth > 4 then return nil, "metadata is too deeply nested" end
  local result = {}
  for key, item in pairs(value) do
    if type(key) ~= "string" or FORBIDDEN_METADATA_KEYS[key:lower()] then
      return nil, "metadata contains forbidden content"
    end
    local clean, err = sanitize_metadata(item, depth + 1)
    if clean == nil and item ~= nil then return nil, err end
    result[key] = clean
  end
  return result
end

--- Create a lifecycle registry.
-- `max_sessions_per_agent` is explicit policy: one is the safe default, while
-- callers that need parallel work must opt into a larger bound. A value of nil
-- means no registry-imposed bound (still subject to panel exclusivity).
function Lifecycle.new(opts)
  opts = opts or {}
  local self = setmetatable({}, Lifecycle)
  self.policy = {
    max_sessions_per_agent = opts.max_sessions_per_agent == nil and 1
      or opts.max_sessions_per_agent,
    allow_multiple_tasks = opts.allow_multiple_tasks ~= false,
  }
  if self.policy.max_sessions_per_agent ~= nil
    and (type(self.policy.max_sessions_per_agent) ~= "number"
      or self.policy.max_sessions_per_agent < 1
      or self.policy.max_sessions_per_agent % 1 ~= 0) then
    error("max_sessions_per_agent must be a positive integer or nil")
  end
  self.path = opts.path
  self.sessions = {}
  self.panels = {}
  self.events_log = {}
  self.next_counter = 0
  if self.path then
    local loaded, load_err = self:load()
    if not loaded and load_err then
      error(load_err.message)
    end
  end
  return self
end

function Lifecycle:_next_id(prefix)
  self.next_counter = self.next_counter + 1
  return generated_id(prefix, self.next_counter)
end

function Lifecycle:_event(kind, record, from_state, to_state, extra)
  local event = {
    event_id = self:_next_id("event"),
    type = kind,
    timestamp_ms = now_ms(),
    session_id = record.session_id,
    panel_id = record.panel_id,
    agent_id = record.agent_id,
    task_id = record.task_id,
    from_state = from_state,
    to_state = to_state,
  }
  for key, value in pairs(extra or {}) do
    -- Lifecycle events contain references and bounded decision metadata only.
    if key ~= "content" and key ~= "prompt" and key ~= "context"
      and key ~= "transcript" and key ~= "output" and key ~= "response" then
      event[key] = clone(value)
    end
  end
  self.events_log[#self.events_log + 1] = event
  return event
end

function Lifecycle:_persist()
  if not self.path then
    return true
  end
  local payload = Session.json_encode({
    version = 1,
    policy = self.policy,
    next_counter = self.next_counter,
    sessions = self.sessions,
    panels = self.panels,
    events = self.events_log,
  })
  local temporary = self.path .. ".tmp." .. tostring(WheelHost.proc.pid() or 0)
  local wrote, write_err = WheelHost.fs.write_file(temporary, payload)
  if not wrote then
    return false, error_record("E_LIFECYCLE_PERSIST", "cannot write lifecycle registry")
  end
  if not WheelHost.fs.chmod(temporary, PRIVATE_FILE_MODE_STRING) then
    WheelHost.fs.remove_file(temporary)
    return false, error_record("E_LIFECYCLE_PERSIST", "cannot protect lifecycle registry")
  end
  local renamed, rename_err = WheelHost.fs.rename(temporary, self.path)
  if not renamed then
    WheelHost.fs.remove_file(temporary)
    return false, error_record("E_LIFECYCLE_PERSIST", "cannot publish lifecycle registry")
  end
  return true
end

function Lifecycle:load()
  if not self.path then
    return true
  end
  local raw = WheelHost.fs.read_file_bounded(self.path, 4 * 1024 * 1024)
  if not raw then
    return true
  end
  local ok, decoded = pcall(Session.json_decode, raw)
  if not ok or type(decoded) ~= "table" or decoded.version ~= 1 then
    return false, error_record("E_LIFECYCLE_INVALID", "lifecycle registry is invalid")
  end
  self.policy = decoded.policy or self.policy
  self.next_counter = decoded.next_counter or 0
  self.sessions = decoded.sessions or {}
  self.panels = decoded.panels or {}
  self.events_log = decoded.events or {}
  return true
end

function Lifecycle:save()
  return self:_persist()
end

function Lifecycle:get_session(session_id)
  return clone(self.sessions[session_id])
end

function Lifecycle:get_panel(panel_id)
  return clone(self.panels[panel_id])
end

function Lifecycle:list_sessions(agent_id)
  local result = {}
  for _, record in pairs(self.sessions) do
    if not agent_id or record.agent_id == agent_id then
      result[#result + 1] = clone(record)
    end
  end
  table.sort(result, function(left, right) return left.session_id < right.session_id end)
  return result
end

function Lifecycle:list_panels()
  local result = {}
  for _, record in pairs(self.panels) do
    result[#result + 1] = clone(record)
  end
  table.sort(result, function(left, right) return left.panel_id < right.panel_id end)
  return result
end

function Lifecycle:events(limit)
  local result = {}
  local first = 1
  if limit and #self.events_log > limit then
    first = #self.events_log - limit + 1
  end
  for index = first, #self.events_log do
    result[#result + 1] = event_copy(self.events_log[index])
  end
  return result
end

function Lifecycle:create_panel(opts)
  opts = opts or {}
  local panel_id, panel_err = id_string(opts.panel_id or self:_next_id("panel"), "panel_id", true)
  if not panel_id then return transition_error("E_LIFECYCLE_INVALID", panel_err) end
  if self.panels[panel_id] then
    return transition_error("E_LIFECYCLE_EXISTS", "panel already exists")
  end
  local agent_id, agent_err = id_string(opts.agent_id, "agent_id", false)
  if opts.agent_id ~= nil and not agent_id then
    return transition_error("E_LIFECYCLE_INVALID", agent_err)
  end
  local record = {
    panel_id = panel_id,
    kind = opts.kind or "headless",
    headless = opts.headless ~= false,
    agent_id = agent_id,
    state = Lifecycle.PanelState.CREATED,
    attached_session_id = nil,
    observer_session_ids = {},
    created_at_ms = now_ms(),
    updated_at_ms = now_ms(),
  }
  self.panels[panel_id] = record
  self:_event("panel.created", record, nil, record.state)
  local ok, persist_err = self:_persist()
  if not ok then return transition_error(persist_err.code, persist_err.message) end
  return clone(record)
end

function Lifecycle:ready_panel(panel_id)
  local panel = self.panels[panel_id]
  if not panel then return transition_error("E_LIFECYCLE_NOT_FOUND", "panel not found") end
  if panel.state ~= Lifecycle.PanelState.CREATED then
    return transition_error("E_LIFECYCLE_STATE", "panel must be created before ready")
  end
  local from = panel.state
  panel.state, panel.updated_at_ms = Lifecycle.PanelState.READY, now_ms()
  self:_event("panel.ready", panel, from, panel.state)
  local ok, persist_err = self:_persist()
  if not ok then return transition_error(persist_err.code, persist_err.message) end
  return clone(panel)
end

function Lifecycle:create_agent_session(opts)
  opts = opts or {}
  local agent_id, agent_err = id_string(opts.agent_id, "agent_id", true)
  if not agent_id then return transition_error("E_LIFECYCLE_INVALID", agent_err) end
  local panel_id, panel_err = id_string(opts.panel_id, "panel_id", true)
  if not panel_id then return transition_error("E_LIFECYCLE_INVALID", panel_err) end
  if not self.panels[panel_id] then
    return transition_error("E_LIFECYCLE_NOT_FOUND", "panel not found")
  end
  local sessions = self:list_sessions(agent_id)
  local live_count = 0
  for _, session in ipairs(sessions) do
    if ACTIVE_SESSION_STATES[session.state] then live_count = live_count + 1 end
  end
  if self.policy.max_sessions_per_agent and live_count >= self.policy.max_sessions_per_agent then
    return transition_error("E_LIFECYCLE_POLICY", "agent session policy limit reached")
  end
  if not self.policy.allow_multiple_tasks and #sessions > 0 then
    return transition_error("E_LIFECYCLE_POLICY", "agent cannot own multiple session tasks")
  end
  local session_id, session_err = id_string(opts.session_id or self:_next_id("session"), "session_id", true)
  if not session_id then return transition_error("E_LIFECYCLE_INVALID", session_err) end
  if self.sessions[session_id] then
    return transition_error("E_LIFECYCLE_EXISTS", "session already exists")
  end
  local task_id, task_err = id_string(opts.task_id, "task_id", false)
  if opts.task_id ~= nil and not task_id then
    return transition_error("E_LIFECYCLE_INVALID", task_err)
  end
  local worktree_id, worktree_err = id_string(opts.worktree_id, "worktree_id", false)
  if opts.worktree_id ~= nil and not worktree_id then
    return transition_error("E_LIFECYCLE_INVALID", worktree_err)
  end
  local branch = opts.context_branch or "(detached)"
  local branch_err
  branch, branch_err = value_string(branch, "context_branch", true)
  if not branch then return transition_error("E_LIFECYCLE_INVALID", branch_err) end
  local role_binding, role_err = sanitize_metadata(opts.role_binding or { role = opts.role })
  if not role_binding then return transition_error("E_LIFECYCLE_INVALID", role_err) end
  local model_profile, model_err = sanitize_metadata(opts.model_profile or {})
  if not model_profile then return transition_error("E_LIFECYCLE_INVALID", model_err) end
  local record = {
    agent_id = agent_id,
    session_id = session_id,
    panel_id = panel_id,
    task_id = task_id,
    context_branch = branch,
    context_head = opts.context_head,
    role_binding = role_binding,
    model_profile = model_profile,
    worktree_id = worktree_id,
    state = Lifecycle.AgentSessionState.CREATED,
    checkpoint = nil,
    created_at_ms = now_ms(),
    updated_at_ms = now_ms(),
    recovered_from = nil,
  }
  self.sessions[session_id] = record
  self:_event("agent_session.created", record, nil, record.state)
  local ok, persist_err = self:_persist()
  if not ok then return transition_error(persist_err.code, persist_err.message) end
  return clone(record)
end

function Lifecycle:_session(session_id)
  local record = self.sessions[session_id]
  if not record then return nil, error_record("E_LIFECYCLE_NOT_FOUND", "agent session not found") end
  return record
end

function Lifecycle:_panel_for_session(record)
  return self.panels[record.panel_id]
end

function Lifecycle:_transition_session(session_id, target, event_type)
  local record, err = self:_session(session_id)
  if not record then return transition_error(err.code, err.message) end
  if SESSION_TERMINAL[record.state] then
    return transition_error("E_LIFECYCLE_STATE", "terminal session cannot transition")
  end
  local from = record.state
  record.state, record.updated_at_ms = target, now_ms()
  self:_event(event_type, record, from, target)
  local ok, persist_err = self:_persist()
  if not ok then return transition_error(persist_err.code, persist_err.message) end
  return clone(record)
end

function Lifecycle:activate_session(session_id)
  local record, err = self:_session(session_id)
  if not record then return transition_error(err.code, err.message) end
  if record.state ~= Lifecycle.AgentSessionState.CREATED
    and record.state ~= Lifecycle.AgentSessionState.PAUSED then
    return transition_error("E_LIFECYCLE_STATE", "only created or paused sessions can activate")
  end
  local panel = self:_panel_for_session(record)
  if not panel or PANEL_TERMINAL[panel.state] then
    return transition_error("E_LIFECYCLE_STATE", "session panel is unavailable")
  end
  if panel.attached_session_id and panel.attached_session_id ~= session_id then
    return transition_error("E_LIFECYCLE_PANEL_BUSY", "panel already has a controller")
  end
  panel.attached_session_id = session_id
  local panel_from = panel.state
  panel.state, panel.updated_at_ms = Lifecycle.PanelState.ACTIVE, now_ms()
  local from = record.state
  record.state, record.updated_at_ms = Lifecycle.AgentSessionState.ACTIVE, now_ms()
  self:_event("agent_session.active", record, from, record.state)
  self:_event("panel.active", panel, panel_from, panel.state)
  local ok, persist_err = self:_persist()
  if not ok then return transition_error(persist_err.code, persist_err.message) end
  return clone(record)
end

function Lifecycle:pause_session(session_id, reason)
  local record, err = self:_session(session_id)
  if not record then return transition_error(err.code, err.message) end
  if record.state ~= Lifecycle.AgentSessionState.ACTIVE then
    return transition_error("E_LIFECYCLE_STATE", "only active sessions can pause")
  end
  local panel = self:_panel_for_session(record)
  local result = self:_transition_session(session_id, Lifecycle.AgentSessionState.PAUSED, "agent_session.paused")
  if not result then return result end
  if panel and panel.attached_session_id == session_id then
    local from = panel.state
    panel.state, panel.updated_at_ms = Lifecycle.PanelState.PAUSED, now_ms()
    self:_event("panel.paused", panel, from, panel.state, { reason = reason })
    self:_persist()
  end
  return result
end

function Lifecycle:mark_stale(session_id, reason)
  local record, err = self:_session(session_id)
  if not record then return transition_error(err.code, err.message) end
  if record.state ~= Lifecycle.AgentSessionState.ACTIVE
    and record.state ~= Lifecycle.AgentSessionState.PAUSED then
    return transition_error("E_LIFECYCLE_STATE", "only active or paused sessions can become stale")
  end
  local result = self:_transition_session(session_id, Lifecycle.AgentSessionState.STALE, "agent_session.stale")
  if not result then return result end
  local panel = self:_panel_for_session(record)
  if panel and panel.attached_session_id == session_id then
    local from = panel.state
    panel.attached_session_id = nil
    panel.state, panel.updated_at_ms = Lifecycle.PanelState.DETACHED, now_ms()
    self:_event("panel.detached", panel, from, panel.state, { reason = reason or "stale" })
    self:_persist()
  end
  return result
end

function Lifecycle:recover_session(session_id, opts)
  opts = opts or {}
  local record, err = self:_session(session_id)
  if not record then return transition_error(err.code, err.message) end
  if record.state ~= Lifecycle.AgentSessionState.STALE then
    return transition_error("E_LIFECYCLE_STATE", "only stale sessions can be recovered")
  end
  record.state = Lifecycle.AgentSessionState.PAUSED
  record.recovered_from = "stale"
  record.updated_at_ms = now_ms()
  self:_event("agent_session.recovered", record, Lifecycle.AgentSessionState.STALE, record.state,
    { recovery = opts.recovery or "manual" })
  local ok, persist_err = self:_persist()
  if not ok then return transition_error(persist_err.code, persist_err.message) end
  return clone(record)
end

function Lifecycle:checkpoint_session(session_id, checkpoint)
  local record, err = self:_session(session_id)
  if not record then return transition_error(err.code, err.message) end
  if SESSION_TERMINAL[record.state] then
    return transition_error("E_LIFECYCLE_STATE", "terminal session cannot checkpoint")
  end
  local checkpoint_id, checkpoint_err = id_string(checkpoint, "checkpoint", true)
  if not checkpoint_id then return transition_error("E_LIFECYCLE_INVALID", checkpoint_err) end
  record.checkpoint = checkpoint_id
  record.updated_at_ms = now_ms()
  self:_event("agent_session.checkpointed", record, record.state, record.state,
    { checkpoint = checkpoint_id })
  local ok, persist_err = self:_persist()
  if not ok then return transition_error(persist_err.code, persist_err.message) end
  return clone(record)
end

function Lifecycle:resume_session(session_id)
  local record, err = self:_session(session_id)
  if not record then return transition_error(err.code, err.message) end
  if record.state ~= Lifecycle.AgentSessionState.PAUSED then
    return transition_error("E_LIFECYCLE_STATE", "only paused sessions can resume; recover stale sessions first")
  end
  return self:activate_session(session_id)
end

function Lifecycle:detach_session(session_id, opts)
  opts = opts or {}
  local record, err = self:_session(session_id)
  if not record then return transition_error(err.code, err.message) end
  local panel = self:_panel_for_session(record)
  if not panel or panel.attached_session_id ~= session_id then
    return transition_error("E_LIFECYCLE_STATE", "session is not the panel controller")
  end
  local from = panel.state
  panel.attached_session_id = nil
  panel.state, panel.updated_at_ms = Lifecycle.PanelState.DETACHED, now_ms()
  self:_event("panel.detached", panel, from, panel.state, { reason = opts.reason or "explicit" })
  if opts.pause and record.state == Lifecycle.AgentSessionState.ACTIVE then
    record.state, record.updated_at_ms = Lifecycle.AgentSessionState.PAUSED, now_ms()
    self:_event("agent_session.paused", record, Lifecycle.AgentSessionState.ACTIVE, record.state,
      { reason = "panel_detached" })
  else
    record.updated_at_ms = now_ms()
  end
  local ok, persist_err = self:_persist()
  if not ok then return transition_error(persist_err.code, persist_err.message) end
  return clone(record)
end

function Lifecycle:attach_session(session_id, panel_id, opts)
  opts = opts or {}
  local record, err = self:_session(session_id)
  if not record then return transition_error(err.code, err.message) end
  local panel = self.panels[panel_id or record.panel_id]
  if not panel then return transition_error("E_LIFECYCLE_NOT_FOUND", "panel not found") end
  if PANEL_TERMINAL[panel.state] then return transition_error("E_LIFECYCLE_STATE", "closed panel cannot attach") end
  local mode = opts.mode or Lifecycle.AttachMode.CONTROLLER
  if mode == Lifecycle.AttachMode.OBSERVER then
    if not contains(panel.observer_session_ids, session_id) then
      panel.observer_session_ids[#panel.observer_session_ids + 1] = session_id
    end
    local from = panel.state
    if panel.state == Lifecycle.PanelState.CREATED or panel.state == Lifecycle.PanelState.DETACHED then
      panel.state = Lifecycle.PanelState.ATTACHED
    end
    panel.updated_at_ms = now_ms()
    self:_event("panel.observer_attached", panel, from, panel.state,
      { observer_session_id = session_id, mode = mode })
  else
    if panel.attached_session_id and panel.attached_session_id ~= session_id then
      local other = self.sessions[panel.attached_session_id]
      if other and other.state == Lifecycle.AgentSessionState.ACTIVE then
        return transition_error("E_LIFECYCLE_PANEL_BUSY", "panel already has an active session")
      end
      return transition_error("E_LIFECYCLE_PANEL_BUSY", "panel already has a controller")
    end
    panel.attached_session_id = session_id
    local from = panel.state
    if panel.state == Lifecycle.PanelState.CREATED or panel.state == Lifecycle.PanelState.DETACHED then
      panel.state = Lifecycle.PanelState.ATTACHED
    end
    panel.updated_at_ms = now_ms()
    self:_event("panel.attached", panel, from, panel.state, { mode = mode })
  end
  record.panel_id = panel.panel_id
  record.updated_at_ms = now_ms()
  local ok, persist_err = self:_persist()
  if not ok then return transition_error(persist_err.code, persist_err.message) end
  return clone(record)
end

function Lifecycle:close_panel(panel_id, reason)
  local panel = self.panels[panel_id]
  if not panel then return transition_error("E_LIFECYCLE_NOT_FOUND", "panel not found") end
  if panel.state == Lifecycle.PanelState.CLOSED then
    return transition_error("E_LIFECYCLE_STATE", "panel is already closed")
  end
  if panel.attached_session_id then
    return transition_error("E_LIFECYCLE_STATE", "detach the panel controller before closing")
  end
  local from = panel.state
  panel.state, panel.updated_at_ms = Lifecycle.PanelState.CLOSED, now_ms()
  self:_event("panel.closed", panel, from, panel.state, { reason = reason or "explicit" })
  local ok, persist_err = self:_persist()
  if not ok then return transition_error(persist_err.code, persist_err.message) end
  return clone(panel)
end

function Lifecycle:end_session(session_id, reason)
  local record, err = self:_session(session_id)
  if not record then return transition_error(err.code, err.message) end
  if SESSION_TERMINAL[record.state] then return transition_error("E_LIFECYCLE_STATE", "session is already terminal") end
  local panel = self:_panel_for_session(record)
  if panel and panel.attached_session_id == session_id then
    local panel_from = panel.state
    panel.attached_session_id = nil
    panel.state, panel.updated_at_ms = Lifecycle.PanelState.DETACHED, now_ms()
    self:_event("panel.detached", panel, panel_from, panel.state,
      { reason = "session_ended" })
  end
  local from = record.state
  record.state, record.updated_at_ms = Lifecycle.AgentSessionState.ENDED, now_ms()
  self:_event("agent_session.ended", record, from, record.state, { reason = reason or "explicit" })
  local ok, persist_err = self:_persist()
  if not ok then return transition_error(persist_err.code, persist_err.message) end
  return clone(record)
end

function Lifecycle:abandon_session(session_id, reason)
  local record, err = self:_session(session_id)
  if not record then return transition_error(err.code, err.message) end
  if SESSION_TERMINAL[record.state] then return transition_error("E_LIFECYCLE_STATE", "session is already terminal") end
  local panel = self:_panel_for_session(record)
  if panel and panel.attached_session_id == session_id then
    local panel_from = panel.state
    panel.attached_session_id = nil
    panel.state, panel.updated_at_ms = Lifecycle.PanelState.DETACHED, now_ms()
    self:_event("panel.detached", panel, panel_from, panel.state, { reason = "session_abandoned" })
  end
  local from = record.state
  record.state, record.updated_at_ms = Lifecycle.AgentSessionState.ABANDONED, now_ms()
  self:_event("agent_session.abandoned", record, from, record.state, { reason = reason or "recovery" })
  local ok, persist_err = self:_persist()
  if not ok then return transition_error(persist_err.code, persist_err.message) end
  return clone(record)
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
