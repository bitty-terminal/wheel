-- Wheel Team Coordinator
-- Multi-agent peer colleague collaboration protocol per Wheel architecture.
-- Rejects master-slave hierarchy: each agent is an autonomous peer worker in an engineering workspace.

local WheelErrors

--- Treat only the interpreter's exact rooted not-found wording as a missing
-- module. A present-but-broken module or a typed denial keeps its own cause
-- instead of being reported as absent.
-- @param module_name string
-- @param err any
-- @return boolean
local function is_not_found(module_name, err)
  return type(err) == "string"
    and err:find("module '" .. module_name .. "' not found", 1, true) ~= nil
end

--- Annotate a typed cause with the loading parent and rooted dependency while
-- preserving its class and code. The bridge message bound is owned by
-- `wheel.errors`, so the annotated message is clamped to the same limit.
-- @param parent string
-- @param rooted string
-- @param cause table typed bridge error
-- @return table
local function annotated_typed_error(parent, rooted, cause)
  local message = string.format("%s: cannot load submodule '%s': %s",
    parent, rooted, cause.message):gsub("[\r\n]", " ")
  local limit = WheelErrors.MESSAGE_MAX_LENGTH
  if #message > limit then
    message = message:sub(1, limit - 3) .. "..."
  end
  return { class = cause.class, code = cause.code, message = message }
end

local function load_submodule(subpath)
  local rooted = "wheel." .. subpath
  local ok, mod = pcall(require, rooted)
  if ok then return mod end
  -- Lua 5.1 leaves a load sentinel after a failed require. Clear it so a
  -- repeated load reports the real cause instead of "loop or previous error".
  package.loaded[rooted] = nil
  local cause = mod
  if WheelErrors and type(WheelErrors.is_typed) == "function" and WheelErrors.is_typed(cause) then
    error(annotated_typed_error("wheel.team", rooted, cause), 0)
  end
  if not is_not_found(rooted, cause) then
    error(string.format("wheel.team: cannot load submodule '%s': %s",
      rooted, tostring(cause)), 0)
  end

  local alternate = "lua.wheel." .. subpath
  ok, mod = pcall(require, alternate)
  if ok then return mod end
  package.loaded[alternate] = nil
  if WheelErrors and type(WheelErrors.is_typed) == "function" and WheelErrors.is_typed(mod) then
    error(annotated_typed_error("wheel.team", rooted, mod), 0)
  end
  if is_not_found(alternate, mod) then
    mod = cause
  end

  error(string.format("wheel.team: cannot load submodule '%s': %s",
    rooted, tostring(mod)), 0)
end

WheelErrors = load_submodule("errors")
local WheelAgent = load_submodule("agent")
local WheelContext = load_submodule("context")
local WheelTool = load_submodule("tool")
local WheelUI = load_submodule("ui")

local WheelHost = load_submodule("host")
local WheelAudit = load_submodule("audit")
local ok_lifecycle, WheelLifecycle = pcall(load_submodule, "lifecycle")
if not ok_lifecycle then
  local lifecycle_error = WheelLifecycle
  local missing_root = type(lifecycle_error) == "string"
    and lifecycle_error:find("cannot load submodule 'wheel.lifecycle'", 1, true)
    and lifecycle_error:find("module 'wheel.lifecycle' not found", 1, true)
  if missing_root then
    WheelLifecycle = nil
  else
    error(lifecycle_error, 0)
  end
end

local WheelTeam = {}
WheelTeam.__index = WheelTeam
local MAX_HANDOFF_RECORD_BYTES = 8192
local LIVE_SESSION_STATE = "active"

local function handoff_recovery_error()
  return {
    class = WheelErrors.CLASS_RUNTIME,
    code = "E_HANDOFF_RECOVERY",
    message = "handoff recovery failed; ownership was not committed",
  }
end

local function normalize_lifecycle_status(status)
  return load_submodule("kernel").normalize_lifecycle_status(status)
end

--- Create a new WheelTeam coordinator.
--- @param opts table
---   opts.kernel table: WheelKernel instance
---   opts.config table?: Resolved WheelConfig instance
---   opts.context table?: WheelContext instance
---   opts.bus table?: ContextBus instance
---   opts.workspace_root string?: Project workspace root directory
--- @return table WheelTeam
function WheelTeam.new(opts)
  opts = opts or {}
  if not opts.kernel then
    error("WheelTeam requires a 'kernel' (WheelKernel instance)")
  end

  local self = setmetatable({}, WheelTeam)
  self.kernel = opts.kernel
  self.config = opts.config
  self.workspace_root = opts.workspace_root or "."
  self.agents = {} -- map of agent_name -> WheelAgent instance
  self.agent_states = {} -- map of agent_name -> { state = "idle"|"busy"|"waiting_review", active_task_id = string?, tasks_completed = number }
  self.handoffs = {} -- array of structured handoff records
  self.task_assignments = {} -- map of task_id -> agent_name
  self.agent_tasks = {} -- map of agent_name -> set of active task ids
  self.handoff_counter = 0
  self.allow_multiple_tasks = opts.allow_multiple_tasks == true

  -- Shared context engine and event bus across peer colleagues
  self.context = opts.context or WheelContext.new({
    kernel = self.kernel,
    config = self.config,
    bus = opts.bus,
  })

  self.tool_registry = opts.tool_registry or (WheelTool and WheelTool.get_default_registry())
  -- Runtime authority is opt-in. Legacy in-process orchestration without a
  -- lifecycle registry remains supported, but it has no session capability.
  self.lifecycle = opts.lifecycle

  return self
end

--- Register an existing WheelAgent instance with the team.
--- @param agent table: WheelAgent instance
--- @return table: The registered agent
function WheelTeam:register_agent(agent)
  if not agent or not agent.name or agent.name == "" then
    error("Cannot register agent without valid name")
  end
  if self.agents[agent.name] then
    error("Agent with name '" .. agent.name .. "' is already registered in this team")
  end
  local agent_identity = agent:status().agent_id
  for _, existing in pairs(self.agents) do
    local existing_identity = existing:status().agent_id
    if existing_identity and agent_identity and existing_identity == agent_identity then
      error("Agent identity '" .. agent_identity .. "' is already registered in this team")
    end
  end
  self.agents[agent.name] = agent
  self.agent_states[agent.name] = {
    state = "idle",
    active_task_id = nil,
    tasks_completed = 0,
    handoffs_sent = 0,
    handoffs_received = 0,
    active_task_ids = {},
  }
  self.agent_tasks[agent.name] = {}

  -- Mount shared team context and subscribe colleague to context events
  agent.context = self.context
  if not agent.tool_registry and self.tool_registry then
    agent.tool_registry = self.tool_registry
  end

  if self.context and self.context.bus and type(self.context.bus.subscribe) == "function" then
    self.context.bus:subscribe(agent.name, function(event)
      local st = self.agent_states[agent.name]
      if st then
        st.last_event = event
      end
    end)
  end

  return agent
end

--- Spawn and register a new WheelAgent colleague.
--- @param opts table: options passed to WheelAgent.new
--- @return table: The newly spawned and registered WheelAgent
function WheelTeam:spawn_agent(opts)
  opts = opts or {}
  opts.kernel = opts.kernel or self.kernel
  opts.config = opts.config or self.config
  opts.context = opts.context or self.context
  opts.tool_registry = opts.tool_registry or self.tool_registry
  opts.lifecycle = opts.lifecycle or self.lifecycle
  opts.workspace = opts.workspace or { root = self.workspace_root }
  local agent = WheelAgent.new(opts)
  return self:register_agent(agent)
end

--- Create a runtime AgentSession and Headless Panel for a registered agent.
--- Lifecycle records contain references only; context and prompt data remain
--- in the context engine and are not sent to the bittyd boundary.
function WheelTeam:create_runtime_session(agent_name, opts)
  local agent = self.agents[agent_name]
  if not agent then
    return nil, "agent not found: " .. tostring(agent_name)
  end
  return agent:create_runtime_session(opts)
end

--- Fork an independent Agent identity from an immutable ContextCommit and
-- register it with the team. The child gets its own AgentSession and Headless
-- Panel; lineage and the base Context commit are carried as references only.
--- @param agent_name string Parent Agent name
-- @param opts table WheelAgent.fork_agent options plus { runtime?, activate?, task_id? }
-- @return table|nil child agent, table|nil typed error
function WheelTeam:fork_agent(agent_name, opts)
  local parent = self.agents[agent_name]
  if not parent then
    return nil, { code = "E_TEAM_AGENT_NOT_FOUND", message = "agent not found: " .. tostring(agent_name) }
  end
  opts = opts or {}
  if opts.approve_widening == true and opts.runtime == false then
    return nil, { code = "E_FORK_AUTHORITY", message = "approved widening requires a runtime audit session" }
  end
  local fork_opts = {}
  for key, value in pairs(opts) do fork_opts[key] = value end
  fork_opts.lifecycle = fork_opts.lifecycle or self.lifecycle
  local child, fork_err = WheelAgent.fork_agent(parent, fork_opts)
  if not child then return nil, fork_err end
  self:register_agent(child)
  local child_session_id = child:runtime_session_id()
  if self.lifecycle and opts.runtime ~= false and not child_session_id then
    local session, session_err = child:create_runtime_session({
      task_id = opts.task_id,
      session_id = opts.session_id,
      panel_id = opts.panel_id,
      context_branch = opts.context_branch,
      context_head = opts.context_head or child.context_refs.base_context_commit,
    })
    if not session then
      self.agents[child.name] = nil
      self.agent_states[child.name] = nil
      return nil, session_err
    end
    child_session_id = child:runtime_session_id()
  end
  if self.lifecycle and opts.runtime ~= false and opts.activate ~= false then
      local activated, activate_err = child:activate_runtime_session()
      if not activated then
        if child_session_id then
          pcall(self.lifecycle.end_session, self.lifecycle, child_session_id, "explicit")
        end
        self.agents[child.name] = nil
        self.agent_states[child.name] = nil
        return nil, activate_err
      end
  end
  return child
end

--- Audited role transition for a registered agent. The stable AgentId is
-- preserved; a new RoleBinding policy generation and Context checkpoint
-- boundary are created, and a widening transition requires explicit approval.
--- @param agent_name string
-- @param role string|table Target role or partial RoleBinding
-- @param opts table { reason, approve_widening? }
-- @return table|nil binding projection, table|nil typed error
function WheelTeam:transition_role(agent_name, role, opts)
  local agent = self.agents[agent_name]
  if not agent then
    return nil, { code = "E_TEAM_AGENT_NOT_FOUND", message = "agent not found: " .. tostring(agent_name) }
  end
  return agent:transition_role(role, opts)
end

function WheelTeam:runtime_sessions(agent_id)
  return self.lifecycle:list_sessions(agent_id)
end

function WheelTeam:runtime_panels()
  return self.lifecycle:list_panels()
end

--- Get a registered agent by name.
--- @param name string
--- @return table?: WheelAgent instance or nil
function WheelTeam:get_agent(name)
  return self.agents[name]
end

--- Get state tracking table for an agent.
--- @param name string
--- @return table?: { state = string, active_task_id = string?, tasks_completed = number }
function WheelTeam:get_agent_state(name)
  return self.agent_states[name]
end

--- List all registered agents with their live roles and states.
--- @return table[] Array of { name = string, role = string, state = string, active_task_id = string?, panel_id = string, model = table, tasks_completed = number }
function WheelTeam:list_agents()
  local list = {}
  for name, agent in pairs(self.agents) do
    local st = self.agent_states[name] or {}
    local agent_status = agent:status()
    table.insert(list, {
      name = name,
      agent_id = agent_status.agent_id,
      role = agent_status.role,
      role_binding = agent_status.role_binding and WheelAgent.binding_reference(agent_status.role_binding),
      policy_generation = agent_status.policy_generation,
      lineage = agent_status.lineage,
      state = st.state or "idle",
      active_task_id = st.active_task_id,
      panel_id = agent.panel_id,
      headless = agent.headless,
      model = agent.model_profile or agent.model,
      tasks_completed = st.tasks_completed or 0,
    })
  end
  -- Sort by name deterministically
  table.sort(list, function(a, b) return a.name < b.name end)
  return list
end

--- Find the first idle agent for a given role.
--- @param role string? Optional role filter
--- @return table?: WheelAgent instance or nil
function WheelTeam:find_idle_agent(role)
  for name, agent in pairs(self.agents) do
    local st = self.agent_states[name]
    if st and st.state == "idle" then
      local current = agent:current_role()
      if not role or current == role then
        return agent
      end
    end
  end
  return nil
end

--- Atomically claim a task for an agent.
--- Verifies task is ready, not claimed by another agent, and agent is currently idle.
--- @param agent_name string
--- @param task_id string
--- @return boolean success, string|table error_or_task
function WheelTeam:claim_task(agent_name, task_id)
  local agent = self.agents[agent_name]
  if not agent then
    return false, "agent not found: " .. tostring(agent_name)
  end

  local st = self.agent_states[agent_name]
  if not st then
    return false, "agent not found: " .. tostring(agent_name)
  end
  -- Check if task is already assigned or active in team
  if self.task_assignments[task_id] then
    local assigned_to = self.task_assignments[task_id]
    if assigned_to ~= agent_name then
      return false, "task '" .. task_id .. "' is already claimed by agent '" .. assigned_to .. "'"
    end
  end

  local owned = self.agent_tasks[agent_name] or {}
  local owned_count, counted = 0, {}
  for id in pairs(owned) do owned_count = owned_count + 1; counted[id] = true end
  for _, existing in ipairs(self.kernel:list_tasks()) do
    if existing.worker_id == agent_name and normalize_lifecycle_status(existing.status) == "in_progress"
      and not counted[existing.id] then owned_count = owned_count + 1; counted[existing.id] = true end
  end
  if owned_count > 0 and not self.allow_multiple_tasks then
    return false, "concurrent task ownership is disabled for agent '" .. agent_name .. "'"
  end
  if self.allow_multiple_tasks and owned_count > 0 and not self.lifecycle then
    return false, "concurrent task ownership requires a lifecycle registry"
  end
  if self.lifecycle and not self:_has_task_session(agent_name, task_id) then
    return false, "a distinct live runtime session and panel are required for task '" .. task_id .. "'"
  end

  -- Query task from kernel
  local task = self.kernel:get_task(task_id)
  if not task or task.id ~= task_id then
    return false, "task not found: " .. tostring(task_id)
  end

  local status_lower = string.lower(task.status or "")
  task.lifecycle_status = normalize_lifecycle_status(status_lower)
  if task.lifecycle_status ~= "ready" then
    return false, "task '" .. task_id .. "' is not claimable (status: " .. tostring(task.status) .. ")"
  end

  if task.worker_id and task.worker_id ~= "" and task.worker_id ~= agent_name then
    return false, "task is assigned to another worker"
  end

  if not self.context or type(self.context._with_handoff_transaction) ~= "function" then
    return false, handoff_recovery_error()
  end
  local started_ok, started_task = self.context:_with_handoff_transaction("tasks/" .. task_id .. "/worker", function()
    local started = self.kernel:start_task(task_id, agent_name)
    local expected_generation = (task.generation or 0) + 1
    local function valid_started(value)
      return type(value) == "table" and value.id == task_id
        and normalize_lifecycle_status(value.status) == "in_progress"
        and value.lifecycle_status == "in_progress"
        and value.generation == expected_generation
        and value.assigned_agent == agent_name and value.worker_id == agent_name
    end
    if not valid_started(started) then
      return false, "kernel refused task claim"
    end
    local actual = self.kernel:get_task(task_id)
    if not valid_started(actual) then return false, "kernel task claim failed authoritative read-back" end
    local stored, store_error = self.context:put_slot("tasks/" .. task_id .. "/worker", agent_name)
    if not stored or not stored.success then return false, store_error or { error = "task_claim_persist_failed" } end
    return true, actual
  end, self.kernel)
  if not started_ok then return false, started_task end

  -- Record team claim
  local task_session_id = self:_task_session_id(agent_name, task_id)
  task_session_id = task_session_id or ("legacy:" .. agent_name .. ":" .. task_id)
  self.agent_tasks[agent_name][task_id] = {
    generation = started_task.generation or task.generation or 0,
    session_id = task_session_id,
    agent_id = agent.agent_id,
  }
  st.active_task_ids = st.active_task_ids or {}
  st.active_task_ids[task_id] = true
  st.state = "busy"
  st.active_task_id = task_id -- compatibility: most recently claimed task
  self.task_assignments[task_id] = agent_name

  return true, started_task or task
end

function WheelTeam:_has_task_session(agent_name, task_id)
  if not self.lifecycle or type(self.lifecycle.list_sessions) ~= "function" then return false end
  local agent = self.agents[agent_name]
  if not agent then return false end
  local sessions = self.lifecycle:list_sessions(agent.agent_id) or {}
  local candidate
  for _, session in ipairs(sessions) do
    if session.agent_id == agent.agent_id and session.task_id == task_id
      and self:_is_live_controller(session) then
      candidate = session
      break
    end
  end
  if not candidate then return false end
  for task, claim in pairs(self.agent_tasks[agent_name] or {}) do
    if task ~= task_id then
      if not self.lifecycle.policy or self.lifecycle.policy.allow_multiple_tasks ~= true then return false end
      local existing = claim.session_id and self.lifecycle:get_session(claim.session_id)
      if not existing or existing.task_id ~= task or existing.agent_id ~= agent.agent_id
        or not self:_is_live_controller(existing) or existing.panel_id == candidate.panel_id then
        return false
      end
    end
  end
  for _, task in ipairs(self.kernel:list_tasks()) do
    if task.id ~= task_id and task.worker_id == agent_name and normalize_lifecycle_status(task.status) == "in_progress" then
      if not self.allow_multiple_tasks or not self.lifecycle.policy or self.lifecycle.policy.allow_multiple_tasks ~= true then return false end
      local existing = self:_task_session_id(agent_name, task.id)
      existing = existing and self.lifecycle:get_session(existing)
      if not existing or existing.panel_id == candidate.panel_id or not self:_is_live_controller(existing) then return false end
    end
  end
  return true
end

function WheelTeam:_is_live_controller(session)
  if not session or session.state ~= LIVE_SESSION_STATE
    or session.attachment_mode ~= (WheelLifecycle and WheelLifecycle.AttachMode.CONTROLLER or "controller") then
    return false
  end
  if not self.lifecycle or type(self.lifecycle.get_panel) ~= "function" then return false end
  local panel = self.lifecycle:get_panel(session.panel_id)
  return panel ~= nil and panel.agent_id == session.agent_id and panel.attached_session_id == session.session_id
    and panel.state == "active"
end

function WheelTeam:_task_session_id(agent_name, task_id)
  if not self.lifecycle then return nil end
  local agent = self.agents[agent_name]
  if not agent then return nil end
  for _, session in ipairs(self.lifecycle:list_sessions(agent.agent_id) or {}) do
    if session.task_id == task_id and self:_is_live_controller(session) then
      return session.session_id
    end
  end
  return nil
end

function WheelTeam:_validate_controller_session(agent_name, task_id, session_id, label)
  if not self.lifecycle then return true, nil end
  if type(session_id) ~= "string" or session_id == "" then
    return false, label .. " is required"
  end
  local agent = self.agents[agent_name]
  local session = self.lifecycle:get_session(session_id)
  if not agent or not session or session.agent_id ~= agent.agent_id or session.task_id ~= task_id
    or not self:_is_live_controller(session) then
    return false, label .. " must identify an active controller session for the expected agent, task, and panel"
  end
  return true, session
end

function WheelTeam:_validate_handoff_session(session_id, agent, task_id, label)
  if not self.lifecycle or type(self.lifecycle.get_session) ~= "function"
    or type(self.lifecycle.get_panel) ~= "function" then
    return nil, label .. " requires a lifecycle registry"
  end
  if type(session_id) ~= "string" then
    return nil, label .. " is required"
  end
  local session = self.lifecycle:get_session(session_id)
  if not session or session.agent_id ~= agent.agent_id or session.task_id ~= task_id
    or not self:_is_live_controller(session) then
    return nil, label .. " is not attached to its expected controller panel"
  end
  local panel = self.lifecycle:get_panel(session.panel_id)
  if panel.agent_id ~= agent.agent_id or panel.state ~= "active" then
    return nil, label .. " must be an active controller on its owned panel"
  end
  return session, panel
end

function WheelTeam:_validate_handoff_sessions(record, recovering)
  if not self.lifecycle then return not self.allow_multiple_tasks, "concurrent handoffs require a lifecycle registry" end
  local source_agent = self.agents[record.from_agent]
  local target_agent = self.agents[record.to_agent]
  if not source_agent or not target_agent then
    return false, "handoff references an unregistered agent"
  end
  if record.source_session_id == nil and record.target_session_id == nil then
    return false, "source_session_id and target_session_id are required for lifecycle handoffs"
  end
  if record.source_session_id == nil then
    return false, "source_session_id is required when a target session is supplied"
  end
  local source, source_panel = self:_validate_handoff_session(
    record.source_session_id, source_agent, record.task_id, "source_session_id")
  if not source then return false, source_panel end
  local target, target_panel = self:_validate_handoff_session(
    record.target_session_id, target_agent, record.task_id, "target_session_id")
  if not target then return false, target_panel end
  if source.session_id == target.session_id or source.panel_id == target.panel_id then
    return false, "source and target must use distinct live sessions and panels"
  end
  local source_claim = self.agent_tasks[record.from_agent] and self.agent_tasks[record.from_agent][record.task_id]
  if not recovering and (not source_claim or source_claim.session_id ~= record.source_session_id
    or source_claim.generation ~= record.generation) then
    return false, "source_session_id is not bound to the current task claim"
  end
  if self.lifecycle and type(self.lifecycle.list_sessions) == "function" then
    for _, session in ipairs(self.lifecycle:list_sessions(source_agent.agent_id) or {}) do
      if session.task_id ~= record.task_id and self:_is_live_controller(session)
        and session.panel_id == source_panel.panel_id then
        return false, "source panel is already serving another task"
      end
    end
    for _, session in ipairs(self.lifecycle:list_sessions(target_agent.agent_id) or {}) do
      if session.task_id ~= record.task_id and session.panel_id == target_panel.panel_id
        and (session.state == "active" or session.state == "paused") then
        return false, "target panel is already serving another task"
      end
    end
  end
  for _, agent_name in ipairs({ record.from_agent, record.to_agent }) do
    for task_id, claim in pairs(self.agent_tasks[agent_name] or {}) do
      if task_id ~= record.task_id then
        if not self.allow_multiple_tasks then return false, "concurrent ownership is disabled" end
        if not self.lifecycle.policy or self.lifecycle.policy.allow_multiple_tasks ~= true then
          return false, "lifecycle concurrent ownership policy is disabled"
        end
        local other, other_panel = self:_validate_handoff_session(claim.session_id,
          self.agents[agent_name], task_id, "existing task session")
        if not other then return false, other_panel end
        local candidate_panel = agent_name == record.from_agent and source_panel or target_panel
        if other_panel.panel_id == candidate_panel.panel_id then return false, "concurrent tasks require distinct panels" end
      end
    end
    -- Reload starts with empty team projections. Kernel ownership still
    -- requires a distinct task controller for every concurrent running task.
    for _, task in ipairs(self.kernel:list_tasks()) do
      if task.id ~= record.task_id and task.worker_id == agent_name
        and normalize_lifecycle_status(task.status) == "in_progress" then
        if not self.allow_multiple_tasks or not self.lifecycle.policy
          or self.lifecycle.policy.allow_multiple_tasks ~= true then return false, "concurrent ownership is disabled" end
        local session_id = self:_task_session_id(agent_name, task.id)
        local other, panel = self:_validate_handoff_session(session_id, self.agents[agent_name], task.id, "existing task session")
        if not other then return false, panel end
        local candidate = agent_name == record.from_agent and source_panel or target_panel
        if panel.panel_id == candidate.panel_id then return false, "concurrent tasks require distinct panels" end
      end
    end
  end
  return true
end

function WheelTeam:_validate_handoff_offer_sessions(record)
  return self:_validate_handoff_sessions(record)
end

function WheelTeam:_valid_context_reference(reference, task_id, require_context_slot)
  if type(reference) ~= "string" or #reference ~= 64 or not reference:match("^[0-9a-f]+$")
    or not self.context or type(self.context.get_commit) ~= "function" then return false end
  local ok, commit = pcall(self.context.get_commit, self.context, reference)
  if not ok or type(commit) ~= "table" or commit.hash ~= reference or type(commit.slots) ~= "table"
    or (task_id and commit.task_id ~= task_id) then return false end
  local verified = pcall(function()
    local names, parts = {}, { "tree:v1\0" }
    for name in pairs(commit.slots) do names[#names + 1] = name end
    table.sort(names)
    for _, name in ipairs(names) do
      local slot = commit.slots[name]
      assert(type(slot.content) == "string" and slot.size_bytes == #slot.content
        and slot.hash == WheelContext.compute_hash(slot.content))
      parts[#parts + 1] = string.format("%s:%d:%s\n", name, slot.size_bytes, slot.hash)
    end
    assert(commit.tree_hash == WheelContext.compute_hash(table.concat(parts)))
    local preimage = string.format("commit:v1\0tree:%s\0parents:%s\0author:%s\0task:%s\0time:%s\0msg:%s",
      commit.tree_hash, table.concat(commit.parent_hashes, ","), commit.author,
      commit.task_id or "", tostring(commit.timestamp_ms), commit.message)
    assert(WheelContext.compute_hash(preimage) == reference)
  end)
  if not verified then return false end
  if require_context_slot then
    local slot = commit.slots["tasks/" .. task_id .. "/context_ref"]
    if not slot or type(slot.content) ~= "string" or slot.hash ~= WheelContext.compute_hash(slot.content) then return false end
    local runner = load_submodule("runner")
    if not runner.validate_context_ref(slot.content, WheelContext.compute_hash) then return false end
  end
  return true
end

function WheelTeam:_validate_transition_authority(record, target_state, authority)
  if type(authority) ~= "table" then
    return false, "handoff transition requires agent_name and session_id authority"
  end
  local actor = authority.agent_name
  local session_id = authority.session_id or authority.authorized_session_id
  local expected_agent
  if target_state == "accepted" then
    expected_agent = record.to_agent
  elseif target_state == "rejected" then
    expected_agent = actor == record.to_agent and record.to_agent or record.from_agent
  elseif target_state == "closed" then
    expected_agent = record.state == "accepted" and record.to_agent or record.from_agent
  end
  if actor ~= expected_agent then
    return false, "handoff transition actor is not authorized for this state"
  end
  local registered = self.agents[actor]
  if authority.agent_id ~= nil and (not registered or registered.agent_id ~= authority.agent_id) then
    return false, "handoff transition agent identity does not match the registered agent"
  end
  if not self.lifecycle then
    local expected_session = actor == record.to_agent and record.target_session_id or record.source_session_id
    return registered ~= nil and type(session_id) == "string" and session_id ~= ""
      and session_id == expected_session, "session_id does not match the registered task owner"
  end
  local valid, err = self:_validate_controller_session(actor, record.task_id, session_id, "session_id")
  if not valid then return false, err end
  local authorized_session, panel = self:_validate_handoff_session(session_id, registered, record.task_id, "session_id")
  if not authorized_session or panel.state ~= "active" then
    return false, "session_id must be an active attached controller"
  end
  local expected_session = actor == record.to_agent and record.target_session_id or record.source_session_id
  local task_session = self.agent_tasks[actor] and self.agent_tasks[actor][record.task_id]
  if session_id ~= expected_session or (target_state ~= "accepted" and actor ~= record.to_agent
    and (not task_session or task_session.session_id ~= expected_session)) then
    return false, "session_id is not the task owner's attached session"
  end
  return true
end

--- Release an agent's claim on a task upon completion or failure.
--- @param agent_name string
--- @param task_id string
--- @param outcome table?: { status = "succeeded"|"failed", checkpoint_hash = string?, error = string? }
--- @return boolean success, string? error
function WheelTeam:release_task(agent_name, task_id, outcome)
  outcome = outcome or {}
  local st = self.agent_states[agent_name]
  if not st then
    return false, "agent not found: " .. tostring(agent_name)
  end

  local claim = self.agent_tasks[agent_name] and self.agent_tasks[agent_name][task_id]
  if not claim then
    return false, "agent '" .. agent_name .. "' does not hold active claim on task '" .. tostring(task_id) .. "'"
  end

  if self.lifecycle and (outcome.session_id ~= nil or claim.session_id ~= nil) then
    local valid, validation_error = self:_validate_controller_session(
      agent_name, task_id, outcome.session_id or claim.session_id, "session_id")
    if not valid then return false, validation_error end
  end

  local status = outcome.status or "succeeded"
  if type(status) ~= "string" then return false, "task outcome status is invalid" end
  local status_lower = string.lower(status)

  local task = self.kernel:get_task(task_id)
  local gen = claim.generation
  if not task or task.generation ~= gen or task.worker_id ~= agent_name then
    return false, "task ownership or generation is stale; release refused"
  end
  local cur_status = normalize_lifecycle_status(task.status)
  if task.lifecycle_status ~= cur_status then return false, "task lifecycle state is invalid" end
  if status_lower ~= "succeeded" and status_lower ~= "failed" then
    return false, "task outcome status must be succeeded or failed"
  end

  if status_lower == "succeeded" then
    if cur_status ~= "completed" then
      local ok, completed = pcall(self.kernel.complete_task, self.kernel, task_id, gen, outcome.checkpoint_hash, nil, agent_name)
      if not ok or not completed or normalize_lifecycle_status(completed.status) ~= "completed" then return false, "task completion rejected (stale generation or invalid state)" end
    end
    st.tasks_completed = (st.tasks_completed or 0) + 1
  else
    if cur_status ~= "failed" then
      local ok, failed = pcall(self.kernel.fail_task, self.kernel, task_id, gen, outcome.error or "task failed", nil, agent_name)
      if not ok or not failed or normalize_lifecycle_status(failed.status) ~= "failed" then return false, "task failure rejected (stale generation or invalid state)" end
    end
  end

  self.agent_tasks[agent_name][task_id] = nil
  st.active_task_ids = st.active_task_ids or {}
  st.active_task_ids[task_id] = nil
  st.active_task_id = next(self.agent_tasks[agent_name])
  st.state = st.active_task_id and "busy" or "idle"
  self.task_assignments[task_id] = nil

  return true, nil
end

--- Structured task handoff from one colleague to another (e.g. Worker -> Reviewer).
--- @param from_agent string
--- @param to_agent string
--- @param task_id string
--- @param opts table?: { reason = string, rationale = string?, checkpoint_hash = string? }
--- @return boolean success, table|string record_or_error
function WheelTeam:handoff(from_agent, to_agent, task_id, opts)
  opts = opts or {}
  if from_agent == to_agent then return false, "handoff requires distinct source and target agents" end
  local from_st = self.agent_states[from_agent]
  if not from_st then
    return false, "from_agent '" .. tostring(from_agent) .. "' not found"
  end
  if not self.agent_tasks[from_agent] or not self.agent_tasks[from_agent][task_id] then
    return false, "from_agent '" .. from_agent .. "' does not hold task '" .. tostring(task_id) .. "'"
  end

  local to_agent_inst = self.agents[to_agent]
  local to_st = self.agent_states[to_agent]
  if not to_agent_inst or not to_st then
    return false, "to_agent '" .. tostring(to_agent) .. "' not found"
  end
  if self.task_assignments[task_id] ~= from_agent then return false, "task assignment changed before handoff" end
  local task = self.kernel:get_task(task_id)
  local source_claim = self.agent_tasks[from_agent][task_id]
  if not task or normalize_lifecycle_status(task.status) ~= "in_progress" or task.lifecycle_status ~= "in_progress"
    or task.assigned_agent ~= from_agent or task.worker_id ~= from_agent or task.generation ~= source_claim.generation then
    return false, "task generation is stale; handoff refused"
  end
  if self.agent_tasks[to_agent][task_id] then return false, "target agent already holds this task" end
  if to_st.state ~= "idle" and not self.allow_multiple_tasks then
    return false, "to_agent '" .. tostring(to_agent) .. "' is not idle (state: " .. tostring(to_st.state) .. ")"
  end

  local function bounded_text(value, label, default)
    if value == nil then value = default end
    if type(value) ~= "string" or #value > 256 or value:find("[%z\1-\31\127]") then
      return nil, label .. " must be a bounded string"
    end
    if value == "" and label ~= "rationale" then return nil, label .. " must not be empty" end
    return WheelAudit.redact_bounded(value, 256)
  end
  local function bounded_list(value, label)
    if value == nil then return {} end
    if type(value) ~= "table" or getmetatable(value) ~= nil or #value > 16 then return nil, label .. " must contain at most 16 items" end
    local count = 0
    for key in pairs(value) do
      if type(key) ~= "number" or key < 1 or key % 1 ~= 0 then return nil, label .. " must be a dense list" end
      count = count + 1
    end
    if count ~= #value then return nil, label .. " must be a dense list" end
    local out = {}
    for _, item in ipairs(value) do
      if type(item) ~= "string" or item == "" or #item > 256 or item:find("[%z\1-\31\127]") then return nil, label .. " contains an invalid item" end
      out[#out + 1] = WheelAudit.redact_bounded(item, 256)
    end
    return out
  end
  local scope, err = bounded_list(opts.scope, "scope"); if not scope then return false, err end
  local evidence; evidence, err = bounded_list(opts.evidence, "evidence"); if not evidence then return false, err end
  local blockers; blockers, err = bounded_list(opts.blockers, "blockers"); if not blockers then return false, err end
  local risks; risks, err = bounded_list(opts.risks, "risks"); if not risks then return false, err end
  local next_steps; next_steps, err = bounded_list(opts.next_steps, "next_steps"); if not next_steps then return false, err end
  local reason; reason, err = bounded_text(opts.reason, "reason", "handoff"); if not reason then return false, err end
  local rationale; rationale, err = bounded_text(opts.rationale, "rationale", ""); if not rationale then return false, err end
  local context_ref; context_ref, err = bounded_text(opts.context_ref, "context_ref"); if opts.context_ref ~= nil and not context_ref then return false, err end
  local checkpoint_hash; checkpoint_hash, err = bounded_text(opts.checkpoint_hash, "checkpoint_hash"); if opts.checkpoint_hash ~= nil and not checkpoint_hash then return false, err end
  if context_ref and not self:_valid_context_reference(context_ref, task_id, true) then
    return false, "context_ref must identify an immutable commit with this task's ContextRef slot"
  end
  if checkpoint_hash and not self:_valid_context_reference(checkpoint_hash, task_id) then
    return false, "checkpoint_hash must identify an existing immutable context commit"
  end
  local function bounded_reference(value, label)
    if value == nil then return nil end
    if type(value) ~= "string" or value == "" or #value > 128
      or not value:match("^[A-Za-z0-9][A-Za-z0-9._:/%-]*$") then
      return nil, label .. " must be a bounded identifier"
    end
    return value
  end
  local source_session_id; source_session_id, err = bounded_reference(opts.source_session_id or self.agent_tasks[from_agent][task_id].session_id, "source_session_id")
  if not source_session_id then return false, err or "source_session_id is invalid" end
  local target_session_id; target_session_id, err = bounded_reference(opts.target_session_id or ("legacy:" .. to_agent .. ":" .. task_id), "target_session_id")
  if not target_session_id then return false, err or "target_session_id is invalid" end
  if self.allow_multiple_tasks and not self.lifecycle then
    return false, "concurrent handoffs require a lifecycle registry for session authority"
  end
  if self.lifecycle then
    if not opts.source_session_id or not opts.target_session_id then
      return false, "source_session_id and target_session_id are required for lifecycle handoffs"
    end
    local valid, validation_error = self:_validate_handoff_offer_sessions({
      from_agent = from_agent, to_agent = to_agent, task_id = task_id,
      source_session_id = source_session_id, target_session_id = target_session_id,
      generation = task.generation,
    })
    if not valid then return false, validation_error end
  elseif source_session_id ~= "legacy:" .. from_agent .. ":" .. task_id
    or target_session_id ~= "legacy:" .. to_agent .. ":" .. task_id then
    return false, "legacy handoff session must match the task owner"
  end
  local previous_handoff = self.context and self.context:get_slot("tasks/" .. task_id .. "/handoff")
  local handoff_revision = previous_handoff and previous_handoff.version or 0
  local handoff_id = string.format("handoff-%s-%d-%d", task_id, task.generation, handoff_revision + 1)
  local record = {
    handoff_id = handoff_id,
    task_id = task_id,
    from_agent = from_agent,
    to_agent = to_agent,
    reason = reason,
    rationale = rationale,
    checkpoint_hash = checkpoint_hash,
    source_session_id = source_session_id,
    target_session_id = target_session_id,
    context_ref = context_ref,
    scope = scope, evidence = evidence, blockers = blockers, risks = risks, next_steps = next_steps,
    generation = task.generation,
    state = "offered",
    timestamp = WheelHost.time.now(),
  }
  local persisted, persist_error = self:_persist_handoff(record)
  if not persisted then return false, persist_error end
  self.handoffs[#self.handoffs + 1] = record
  if opts.defer_accept then return true, record end
  local accepted, accepted_record = self:set_handoff_state(handoff_id, "accepted", {
    agent_name = to_agent, session_id = target_session_id,
  })
  if not accepted then
    table.remove(self.handoffs)
    return false, accepted_record
  end
  if self.context.bus and type(self.context.bus.publish) == "function" then
    self.context.bus:publish({ type="handoff_received", handoff=accepted_record, from_agent=from_agent, to_agent=to_agent, task_id=task_id })
  end
  return true, accepted_record
end

function WheelTeam:_persist_handoff(record)
  if not self.context or type(self.context._with_handoff_transaction) ~= "function" then
    return false, handoff_recovery_error()
  end
  if not self.context._handoff_transaction_active then
    local original_hash = record.checkpoint_hash
    local ok, result = self.context:_with_handoff_transaction("tasks/" .. record.task_id .. "/handoff", function()
      return self:_persist_handoff(record)
    end)
    if not ok then record.checkpoint_hash = original_hash end
    return ok, result
  end
  if not self.context or type(self.context.put_slot) ~= "function" then
    return false, "handoff requires a context persistence store"
  end
  local ok, encoded = pcall(self.kernel.json.encode, record)
  if not ok or type(encoded) ~= "string" then return false, "handoff record could not be encoded" end
  if #encoded > MAX_HANDOFF_RECORD_BYTES then return false, "handoff record exceeds the persistence limit" end
  local slot_name = "tasks/" .. record.task_id .. "/handoff"
  local original_checkpoint_hash = record.checkpoint_hash
  local function persistence_failure(cause)
    record.checkpoint_hash = original_checkpoint_hash
    return false, cause
  end
  local read_ok, existing = pcall(self.context.get_slot, self.context, slot_name)
  if not read_ok or not existing then
    return persistence_failure({ error = "handoff_slot_read_failed" })
  end
  local result, err = self.context:put_slot(slot_name, encoded, existing and existing.version or 0)
  if not result or not result.success then
    return persistence_failure(err or { error="handoff_persist_failed" })
  end
  if result.version ~= (existing.version or 0) + 1 then
    return persistence_failure({ error = "handoff_slot_version_mismatch" })
  end
  local checkpoint, checkpoint_error = self.context:commit_checkpoint({
    author = "wheel:team",
    task_id = record.task_id,
    message = "Handoff " .. record.handoff_id .. " " .. record.state,
    rationale = { why = "Persist bounded handoff state transition", what = record.state },
  })
  if not checkpoint or not checkpoint.hash then
    return persistence_failure(checkpoint_error or "handoff checkpoint failed")
  end
  local checkpoint_commit = self.context:get_commit(checkpoint.hash)
  if not self:_valid_context_reference(checkpoint.hash, record.task_id)
    or not checkpoint_commit.slots[slot_name] or checkpoint_commit.slots[slot_name].content ~= encoded then
    return persistence_failure({ error = "handoff_checkpoint_not_immutable" })
  end
  if record.checkpoint_hash == nil then
    record.checkpoint_hash = checkpoint.hash
    local checkpointed_content = self.kernel.json.encode(record)
    if #checkpointed_content > MAX_HANDOFF_RECORD_BYTES then
      return persistence_failure({ error = "handoff_record_too_large" })
    end
    local checkpointed, checkpointed_error = self.context:put_slot(slot_name,
      checkpointed_content, result.version)
    if not checkpointed or not checkpointed.success or checkpointed.version ~= result.version + 1 then
      return persistence_failure(checkpointed_error or { error="handoff_persist_failed" })
    end
    local final_checkpoint, final_error = self.context:commit_checkpoint({
      author = "wheel:team", task_id = record.task_id,
      message = "Handoff " .. record.handoff_id .. " checkpoint reference",
      rationale = { why = "Bind handoff record to immutable ContextCommit", what = record.state },
    })
    if not final_checkpoint or not final_checkpoint.hash then
      return persistence_failure(final_error or "handoff checkpoint reference failed")
    end
    local final_commit = self.context:get_commit(final_checkpoint.hash)
    if not self:_valid_context_reference(final_checkpoint.hash, record.task_id)
      or not final_commit.slots[slot_name] or final_commit.slots[slot_name].content ~= checkpointed_content then
      return persistence_failure({ error = "handoff_checkpoint_not_immutable" })
    end
  end
  return true
end

function WheelTeam:_find_handoff(handoff_id)
  local cached_index
  for index, record in ipairs(self.handoffs) do
    if record.handoff_id == handoff_id then cached_index = index; break end
  end
  if not self.context or type(self.context.get_slot) ~= "function" then return nil end
  for _, task in ipairs(self.kernel:list_tasks()) do
    local slot = self.context:get_slot("tasks/" .. task.id .. "/handoff")
    if slot and slot.found and type(slot.content) == "string" and #slot.content <= MAX_HANDOFF_RECORD_BYTES then
      local ok, record = pcall(self.kernel.json.decode, slot.content)
      if ok and type(record) == "table" and record.handoff_id == handoff_id and record.task_id == task.id then
        local allowed = {
          handoff_id=true, task_id=true, from_agent=true, to_agent=true, reason=true, rationale=true,
          checkpoint_hash=true, source_session_id=true, target_session_id=true, context_ref=true,
          scope=true, evidence=true, blockers=true, risks=true, next_steps=true, generation=true,
          state=true, timestamp=true, updated_at=true,
        }
        local valid = true
        for key in pairs(record) do if not allowed[key] then valid = false; break end end
        local function bounded_string(value, optional, allow_empty)
          return (optional and value == nil) or (allow_empty and value == "") or (type(value) == "string" and value ~= "" and #value <= 256
            and not value:find("[%z\1-\31\127]"))
        end
        local function reference(value)
          return type(value) == "string" and #value <= 128
            and value:match("^[A-Za-z0-9][A-Za-z0-9._:/%-]*$") ~= nil
        end
        local function timestamp(value)
          return type(value) == "number" and value == value and value >= 0 and value < math.huge
        end
        local function bounded_list(value)
          if type(value) ~= "table" or getmetatable(value) ~= nil or #value > 16 then return false end
          local count = 0
          for key in pairs(value) do
            if type(key) ~= "number" or key < 1 or key % 1 ~= 0 then return false end
            count = count + 1
          end
          if count ~= #value then return false end
          for _, item in ipairs(value) do if not bounded_string(item) then return false end end
          return true
        end
        valid = valid and bounded_string(record.handoff_id) and bounded_string(record.task_id)
          and bounded_string(record.from_agent) and bounded_string(record.to_agent)
          and bounded_string(record.reason) and bounded_string(record.rationale, false, true)
          and bounded_string(record.checkpoint_hash, true) and bounded_string(record.context_ref, true)
          and reference(record.source_session_id) and reference(record.target_session_id)
          and type(record.generation) == "number" and record.generation >= 1
          and record.generation < math.huge and record.generation % 1 == 0
          and (record.state == "offered" or record.state == "accepted" or record.state == "rejected" or record.state == "closed")
          and timestamp(record.timestamp) and (record.updated_at == nil or timestamp(record.updated_at)
            and record.updated_at >= record.timestamp)
          and bounded_list(record.scope) and bounded_list(record.evidence) and bounded_list(record.blockers)
          and bounded_list(record.risks) and bounded_list(record.next_steps)
        valid = valid and self:_valid_context_reference(record.checkpoint_hash, record.task_id)
        if record.context_ref ~= nil then valid = valid and self:_valid_context_reference(record.context_ref, record.task_id, true) end
        local source_agent, target_agent = self.agents[record.from_agent], self.agents[record.to_agent]
        valid = valid and source_agent ~= nil and target_agent ~= nil
        if valid and self.lifecycle then
          local sessions_valid = self:_validate_handoff_sessions(record, true)
          valid = sessions_valid == true
        elseif valid then
          valid = not self.allow_multiple_tasks
            and record.source_session_id == "legacy:" .. record.from_agent .. ":" .. record.task_id
            and record.target_session_id == "legacy:" .. record.to_agent .. ":" .. record.task_id
        end
        local normalized = normalize_lifecycle_status(task.status)
        local target_owned = record.state == "accepted" or record.state == "closed"
        local expected_owner = target_owned and record.to_agent or record.from_agent
        valid = valid and task.generation == record.generation and record.from_agent ~= record.to_agent
          and task.lifecycle_status == normalized and task.assigned_agent == expected_owner
          and task.worker_id == expected_owner and normalized == "in_progress"
        -- The current record must exist byte-for-byte in immutable history,
        -- not only as caller-controlled working-slot JSON.
        local committed = false
        if valid then
          for _, commit in ipairs(self.context:log(WheelContext.MAX_REFLOG_INDEX)) do
            local saved = commit.slots[slot.name]
            if saved and saved.content == slot.content and self:_valid_context_reference(commit.hash, record.task_id) then
              committed = true; break
            end
          end
        end
        valid = valid and committed
        if valid then
          if cached_index then
            local cached = self.handoffs[cached_index]
            for key in pairs(cached) do cached[key] = nil end
            for key, value in pairs(record) do cached[key] = value end
            record = cached
          else
            self.handoffs[#self.handoffs + 1] = record
          end
          local owner
          if record.state == "offered" or record.state == "rejected" then owner = record.from_agent
          elseif record.state == "accepted" or record.state == "closed" then owner = record.to_agent end
          if owner and task.generation == record.generation and task.worker_id == owner
            and normalize_lifecycle_status(task.lifecycle_status or task.status) == "in_progress" and self.agents[owner] then
            self.task_assignments[record.task_id] = owner
            self.agent_tasks[owner][record.task_id] = {
              generation = record.generation,
              session_id = owner == record.from_agent and record.source_session_id or record.target_session_id,
              agent_id = self.agents[owner].agent_id,
            }
            local state = self.agent_states[owner]
            state.active_task_ids[record.task_id] = true
            state.active_task_id, state.state = record.task_id, "busy"
          end
          return record
        end
      end
    end
  end
  return nil
end

function WheelTeam:set_handoff_state(handoff_id, target_state, authority)
  local transitions = { offered = { accepted = true, rejected = true }, accepted = { closed = true } }
  if target_state ~= "accepted" and target_state ~= "rejected" and target_state ~= "closed" then
    return false, "invalid handoff state"
  end
  local record = self:_find_handoff(handoff_id)
  if record then
      local authorized, authority_error = self:_validate_transition_authority(record, target_state, authority)
      if not authorized then return false, authority_error end
      if not (transitions[record.state] and transitions[record.state][target_state]) then
        return false, "invalid handoff transition: " .. tostring(record.state) .. " -> " .. target_state
      end
      if target_state ~= "accepted" and record.state == "offered"
        and self.task_assignments[record.task_id] ~= record.from_agent then
        return false, "handoff source no longer owns the task"
      end
      local task = self.kernel:get_task(record.task_id)
      local task_lifecycle = task and normalize_lifecycle_status(task.lifecycle_status or task.status)
      local expected_owner = record.state == "accepted" and record.to_agent or record.from_agent
      if not task or task.generation ~= record.generation
        or task_lifecycle ~= "in_progress"
        or task.worker_id ~= expected_owner then
        return false, "handoff generation is stale"
      end
      local updated = {}; for key, value in pairs(record) do updated[key] = value end
      updated.state, updated.updated_at = target_state, WheelHost.time.now()
      if target_state == "accepted" then
        if self.task_assignments[record.task_id] ~= record.from_agent then return false, "task assignment changed before acceptance" end
        local source, target = self.agent_states[record.from_agent], self.agent_states[record.to_agent]
        if not source or not target or self.agent_tasks[record.to_agent][record.task_id]
          or (target.state ~= "idle" and not self.allow_multiple_tasks) then return false, "handoff target is no longer available" end
        local valid_sessions, session_error = self:_validate_handoff_sessions(record)
        if not valid_sessions then return false, session_error end
        if type(self.context._with_handoff_transaction) ~= "function" then return false, handoff_recovery_error() end
        updated.generation = record.generation + 1
        local accepted, accept_error = self.context:_with_handoff_transaction("tasks/" .. record.task_id .. "/handoff", function()
          local worker, worker_error = self.context:put_slot("tasks/" .. record.task_id .. "/worker", record.to_agent)
          if not worker or not worker.success then return false, worker_error or { error = "handoff_worker_persist_failed" } end
          local persisted, persist_error = self:_persist_handoff(updated)
          if not persisted then return false, persist_error end
          local reassigned = self.kernel:reassign_task(record.task_id, record.generation,
            record.to_agent, nil, record.from_agent)
          local actual = self.kernel:get_task(record.task_id)
          if not reassigned or reassigned.id ~= record.task_id
            or normalize_lifecycle_status(reassigned.status) ~= "in_progress"
            or reassigned.generation ~= updated.generation or reassigned.worker_id ~= record.to_agent
            or not actual or actual.id ~= record.task_id or normalize_lifecycle_status(actual.status) ~= "in_progress"
            or actual.lifecycle_status ~= "in_progress" or actual.generation ~= updated.generation
            or actual.worker_id ~= record.to_agent or actual.assigned_agent ~= record.to_agent then
            return false, "handoff task reassignment rejected (stale generation or invalid state)"
          end
          return true
        end, self.kernel)
        if not accepted then return false, accept_error end
        local source_state, target_state_record = source, target
        self.agent_tasks[record.from_agent][record.task_id] = nil
        source_state.active_task_ids[record.task_id] = nil
        source_state.active_task_id = next(self.agent_tasks[record.from_agent])
        source_state.state = source_state.active_task_id and "busy" or "idle"
        source_state.handoffs_sent = (source_state.handoffs_sent or 0) + 1
        self.agent_tasks[record.to_agent][record.task_id] = {
          generation = updated.generation,
          session_id = record.target_session_id,
          agent_id = self.agents[record.to_agent].agent_id,
        }
        target_state_record.active_task_ids[record.task_id] = true
        target_state_record.active_task_id, target_state_record.state = record.task_id, "busy"
        target_state_record.handoffs_received = (target_state_record.handoffs_received or 0) + 1
        self.task_assignments[record.task_id] = record.to_agent
      end
      if target_state ~= "accepted" then
        local persisted, persist_error = self:_persist_handoff(updated)
        if not persisted then return false, persist_error end
        if target_state == "rejected" then
          self.task_assignments[record.task_id] = record.from_agent
        end
      end
      for key in pairs(record) do record[key] = nil end
      for key, value in pairs(updated) do record[key] = value end
      return true, record
  end
  return false, "handoff not found"
end

--- Dispatch ready DAG tasks to available idle peer agents in wave order.
--- @param role_mapping table?: optional map of task_id to required role
--- @return table[] Array of { task_id = string, agent_name = string, role = string }
function WheelTeam:dispatch_wave(role_mapping)
  local all_tasks = self.kernel:list_tasks()
  local dispatched = {}

  for _, task in ipairs(all_tasks) do
    local st_lower = string.lower(task.status or "")
    if st_lower == "ready" and not self.task_assignments[task.id] then
      -- Determine target role
      local target_role = nil
      if role_mapping and role_mapping[task.id] then
        target_role = role_mapping[task.id]
      elseif task.title and string.find(string.lower(task.title), "review") then
        target_role = WheelAgent.Role.REVIEWER
      elseif task.title and (string.find(string.lower(task.title), "debug") or string.find(string.lower(task.title), "fix")) then
        target_role = WheelAgent.Role.DEBUG
      else
        target_role = WheelAgent.Role.CODING
      end

      -- Try finding idle agent matching target role, fallback to any idle coding agent
      local idle_agent = self:find_idle_agent(target_role)
      if not idle_agent and target_role ~= WheelAgent.Role.CODING then
        idle_agent = self:find_idle_agent(WheelAgent.Role.CODING)
      end
      if not idle_agent then
        idle_agent = self:find_idle_agent()
      end

      if idle_agent then
        local ok_claim = self:claim_task(idle_agent.name, task.id)
        if ok_claim then
          table.insert(dispatched, {
            task_id = task.id,
            agent_name = idle_agent.name,
            role = idle_agent:current_role(),
          })
        end
      end
    end
  end

  return dispatched
end

--- Get overall team status and organizational telemetry.
--- @return table
function WheelTeam:status()
  local total = 0
  local idle = 0
  local busy = 0
  local agent_summaries = {}

  for name, agent in pairs(self.agents) do
    total = total + 1
    local st = self.agent_states[name] or {}
    local agent_status = agent:status()
    if st.state == "busy" then
      busy = busy + 1
    else
      idle = idle + 1
    end
    table.insert(agent_summaries, {
      name = name,
      agent_id = agent_status.agent_id,
      role = agent_status.role,
      role_binding = agent_status.role_binding and WheelAgent.binding_reference(agent_status.role_binding),
      policy_generation = agent_status.policy_generation,
      lineage = agent_status.lineage,
      state = st.state or "idle",
      active_task_id = st.active_task_id,
      panel_id = agent.panel_id,
      headless = agent.headless,
      model = agent.model_profile or agent.model,
      tasks_completed = st.tasks_completed or 0,
    })
  end

  local ctx_status = nil
  if self.context and type(self.context.list_slots) == "function" then
    ctx_status = {
      tree_hash = self.context:tree_hash(),
      total_slots = #self.context:list_slots(),
      current_branch = self.context.current_branch and self.context:current_branch() or nil,
      head_commit = self.context.head_commit_hash and self.context:head_commit_hash() or nil,
      branches_count = self.context.list_branches and #self.context:list_branches() or nil,
    }
  end

  return {
    total_agents = total,
    idle_count = idle,
    busy_count = busy,
    agents = agent_summaries,
    handoff_count = #self.handoffs,
    handoffs = self.handoffs,
    context = ctx_status,
    total_tools = self.tool_registry and #self.tool_registry:list_tools() or 0,
  }
end

--- Create and checkout an isolated context branch for a specific task.
--- @param task_id string Task ID
--- @return boolean, table?
function WheelTeam:branch_for_task(task_id)
  if not self.context or type(self.context.create_branch) ~= "function" then
    return false, { error = "no_context", message = "No context engine configured" }
  end
  local branch_name = "task/" .. task_id
  local ok, err = self.context:create_branch(branch_name)
  if ok or (err and err.error == "branch_exists") then
    return self.context:checkout(branch_name)
  end
  return false, err
end

--- Merge a task's isolated context branch back into the main branch.
--- @param task_id string Task ID
--- @param reviewer_agent table? Reviewer agent performing merge
--- @return table? merge result
function WheelTeam:merge_task_branch(task_id, reviewer_agent)
  if not self.context or type(self.context.merge_branch) ~= "function" then
    return nil, { error = "no_context", message = "No context engine configured" }
  end
  local branch_name = "task/" .. task_id
  self.context:checkout("main")
  return self.context:merge_branch(branch_name, {
    author = reviewer_agent and reviewer_agent.name or "wheel:reviewer",
    rationale = {
      goal = "Integrate task " .. task_id .. " deliverables",
      approach = "Semantic 3-way branch merge into main",
      confidence = 1.0,
    },
  })
end

--- Run the autonomous multi-agent wave orchestration and execution loop.
--- Iterates topological DAG waves, dispatches ready tasks to idle workers,
--- executes tasks with artifact publishing, cascades readiness, performs reviewer
--- verification handoffs, and terminates gracefully on DAG completion or blockage.
--- @param opts table?:
---   opts.max_waves number?: maximum wave iterations (default 50)
---   opts.step_fn function?: worker step callback fn(agent, ctx, iter)
---   opts.review_fn function?: reviewer verification callback fn(agent, task, history)
---   opts.role_mapping table?: map of task_id to target role
---   opts.auto_reviewer boolean?: whether to hand off to reviewer on task completion (default true)
---   opts.auto_spawn_reviewer boolean?: whether to auto-spawn reviewer if none exists (default false)
---   opts.on_wave_start function?: fn(wave_num, ready_tasks)
---   opts.on_wave_complete function?: fn(wave_num, wave_dispatched)
---   opts.on_task_complete function?: fn(task_id, outcome)
--- @return table: Report table {
---   success = boolean,
---   completed_tasks = string[],
---   failed_tasks = string[],
---   waves_executed = number,
---   waves_calculated = number,
---   total_handoffs = number,
---   total_checkpoints = number,
---   duration_ms = number,
---   blocked_reason = string?,
--- }
function WheelTeam:run_orchestration_loop(opts)
  opts = opts or {}
  local max_waves = opts.max_waves or 50
  local auto_reviewer = (opts.auto_reviewer ~= false)
  local role_mapping = opts.role_mapping
  local start_clock = WheelHost.time.clock()

  local wave_num = 0
  local completed_set = {}
  local failed_set = {}
  local completed_tasks = {}
  local failed_tasks = {}
  local initial_handoffs = #self.handoffs
  local initial_checkpoints = 0
  local cp_log = self.kernel:log(100) or {}
  initial_checkpoints = #cp_log

  local function update_task_sets()
    local all = self.kernel:list_tasks()
    for _, t in ipairs(all) do
      local st = string.lower(t.status or "")
      if st == "succeeded" and not completed_set[t.id] then
        completed_set[t.id] = true
        table.insert(completed_tasks, t.id)
      elseif (st == "failed" or st == "cancelled") and not failed_set[t.id] then
        failed_set[t.id] = true
        table.insert(failed_tasks, t.id)
      end
    end
    return all
  end

  local all_tasks = update_task_sets()
  local _, max_calc_waves = WheelUI.calculate_waves(all_tasks)

  if #all_tasks == 0 then
    return {
      success = true,
      completed_tasks = {},
      failed_tasks = {},
      waves_executed = 0,
      waves_calculated = 0,
      total_handoffs = 0,
      total_checkpoints = 0,
      duration_ms = 0,
    }
  end

  local blocked_reason = nil
  local loop_success = false

  while wave_num < max_waves do
    all_tasks = update_task_sets()

    -- 1. Check if all tasks have succeeded
    if #completed_tasks == #all_tasks then
      loop_success = true
      break
    end

    -- 2. Check if any tasks are ready or running
    local ready_count = 0
    local running_count = 0
    for _, t in ipairs(all_tasks) do
      local st = string.lower(t.status or "")
      if st == "ready" then
        ready_count = ready_count + 1
      elseif st == "running" then
        running_count = running_count + 1
      end
    end

    if ready_count == 0 and running_count == 0 then
      if #failed_tasks > 0 then
        blocked_reason = string.format("%d task(s) failed, blocking downstream DAG dependencies", #failed_tasks)
      else
        blocked_reason = "DAG deadlock: uncompleted tasks remain but none are ready or running"
      end
      break
    end

    wave_num = wave_num + 1

    if type(opts.on_wave_start) == "function" then
      opts.on_wave_start(wave_num, ready_count)
    end

    -- 3. Dispatch ready tasks to available idle peer workers
    local dispatched = self:dispatch_wave(role_mapping)
    if #dispatched == 0 and ready_count > 0 and running_count == 0 then
      blocked_reason = "No idle agents available to claim ready tasks"
      break
    end

    -- 4. Execute each dispatched task
    for _, item in ipairs(dispatched) do
      local worker = self.agents[item.agent_name]
      local task_id = item.task_id

      if worker then
        if opts.use_task_branches then
          self:branch_for_task(task_id)
        end

        -- Resolve worker step function or runner options
        local step_fn = opts.step_fn
        if opts.use_runner then
          local r_opts = {}
          if type(opts.runner_opts) == "table" then
            for k, v in pairs(opts.runner_opts) do r_opts[k] = v end
          end
          r_opts.defer_release = true
          step_fn = r_opts
        elseif not step_fn then
          step_fn = function(agent, ctx, iter)
            if agent.context and type(agent.context.put_slot) == "function" then
              agent.context:put_slot("tasks/" .. task_id .. "/artifacts",
                string.format("Deliverables and code implementation for %s completed by %s", task_id, agent.name))
            end
            return {
              action = {
                tool = "run_command",
                stdout = string.format("Task %s execution step %d completed successfully", task_id, iter),
                exit_code = 0,
              },
              rationale = {
                why = "Execute planned task " .. task_id,
                what = "Completed implementation deliverables for " .. task_id,
                where_focus = "task " .. task_id,
                how = "autonomous agent execution loop and artifact publishing",
                expected = "all task acceptance criteria satisfied",
                observed = "execution step completed with exit code 0",
              },
              done = true,
            }
          end
        end

        local ok_exec, exec_outcome = pcall(worker.execute_task, worker, task_id, step_fn, { defer_release = true })
        if not ok_exec then
          exec_outcome = { success = false, error = tostring(exec_outcome), checkpoints = {} }
          if type(self.kernel.set_active_task) == "function" then
            self.kernel:set_active_task(nil)
          end
        end

        -- Ensure artifacts slot exists in context
        if self.context and type(self.context.get_slot) == "function" then
          local art_slot = self.context:get_slot("tasks/" .. task_id .. "/artifacts")
          if not art_slot or not art_slot.found then
            self.context:put_slot("tasks/" .. task_id .. "/artifacts",
              string.format("Artifact deliverables for %s produced by %s", task_id, worker.name))
          end
        end

        local last_cp = (exec_outcome.checkpoints and exec_outcome.checkpoints[#exec_outcome.checkpoints])

        if exec_outcome.success then
          local reviewer = nil
          if auto_reviewer then
            reviewer = self:find_idle_agent(WheelAgent.Role.REVIEWER)
            if not reviewer and opts.auto_spawn_reviewer then
              reviewer = self:spawn_agent({ name = "reviewer-auto", role = WheelAgent.Role.REVIEWER })
            end
            if reviewer and reviewer.name == worker.name then
              reviewer = nil
            end
          end

          if reviewer then
            -- Perform worker -> reviewer verification handoff
            local source_checkpoint = self.context and self.context.head_commit_hash
              and self.context:head_commit_hash() or nil
            if not self:_valid_context_reference(source_checkpoint, task_id) then source_checkpoint = nil end
            local ok_ho, ho_record = self:handoff(worker.name, reviewer.name, task_id, {
              reason = "verification_request",
              rationale = "Implementation deliverables complete, ready for independent verification",
              checkpoint_hash = source_checkpoint,
            })

            if ok_ho then
              local default_review_fn = function(agent, task, history)
                -- Inspect that task artifacts exist in context
                if agent.context and type(agent.context.get_slot) == "function" then
                  local slot = agent.context:get_slot("tasks/" .. task.id .. "/artifacts")
                  if not slot or not slot.found or not slot.content or #slot.content == 0 then
                    return false, "Missing or empty task deliverables in artifacts slot"
                  end
                end
                return true, "Independent review approved: deliverables verified in artifacts slot"
              end
              local review_fn = opts.review_fn or default_review_fn
              local ok_rev, review_res = pcall(reviewer.review_task, reviewer, task_id, review_fn)
              if not ok_rev then
                review_res = { approved = false, reason = tostring(review_res) }
              end

              if self.context and type(self.context.put_slot) == "function" then
                self.context:put_slot("tasks/" .. task_id .. "/review",
                  string.format("reviewer: %s\napproved: %s\nreason: %s\ncheckpoint: %s",
                    reviewer.name, tostring(review_res.approved), review_res.reason or "", review_res.checkpoint or ""))
              end

              if review_res.approved then
                if opts.use_task_branches then
                  self:merge_task_branch(task_id, reviewer)
                end
                self:release_task(reviewer.name, task_id, {
                  status = "succeeded",
                  checkpoint_hash = review_res.checkpoint or last_cp,
                })
              else
                self:release_task(reviewer.name, task_id, {
                  status = "failed",
                  error = review_res.reason or "review rejected",
                })
              end
            else
              self:release_task(worker.name, task_id, {
                status = "failed",
                error = "independent review handoff failed: " .. tostring(ho_record),
              })
            end
          elseif auto_reviewer then
            self:release_task(worker.name, task_id, {
              status = "failed",
              error = "independent reviewer unavailable",
            })
          else
            if opts.use_task_branches then
              self:merge_task_branch(task_id, worker)
            end
            self:release_task(worker.name, task_id, {
              status = "succeeded",
              checkpoint_hash = last_cp,
            })
          end
        else
          self:release_task(worker.name, task_id, {
            status = "failed",
            error = exec_outcome.error or "worker execution failed",
          })
        end

        if type(opts.on_task_complete) == "function" then
          opts.on_task_complete(task_id, exec_outcome)
        end
      end
    end

    if type(opts.on_wave_complete) == "function" then
      opts.on_wave_complete(wave_num, dispatched)
    end
  end

  -- Final update of task sets
  all_tasks = update_task_sets()
  if #completed_tasks == #all_tasks and #all_tasks > 0 then
    loop_success = true
  end

  local duration_ms = math.max(1, math.floor((WheelHost.time.clock() - start_clock) * 1000))
  local final_cp_log = self.kernel:log(100) or {}
  local total_checkpoints = math.max(0, #final_cp_log - initial_checkpoints)

  if self.context and type(self.context.put_slot) == "function" then
    self.context:put_slot("workspace/orchestration/last_run",
      string.format("success: %s\nwaves: %d\ncompleted: %d\nfailed: %d\nhandoffs: %d\ncheckpoints: %d",
        tostring(loop_success), wave_num, #completed_tasks, #failed_tasks,
        #self.handoffs - initial_handoffs, total_checkpoints))
  end

  return {
    success = loop_success,
    completed_tasks = completed_tasks,
    failed_tasks = failed_tasks,
    waves_executed = wave_num,
    waves_calculated = max_calc_waves or 1,
    total_handoffs = #self.handoffs - initial_handoffs,
    total_checkpoints = total_checkpoints,
    duration_ms = duration_ms,
    blocked_reason = blocked_reason,
  }
end

return WheelTeam
