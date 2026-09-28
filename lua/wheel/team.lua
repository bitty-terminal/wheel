-- Wheel Team Coordinator
-- Multi-agent peer colleague collaboration protocol per Wheel architecture.
-- Rejects master-slave hierarchy: each agent is an autonomous peer worker in an engineering workspace.

local WheelAgent = require("wheel.agent")

local WheelTeam = {}
WheelTeam.__index = WheelTeam

--- Create a new WheelTeam coordinator.
--- @param opts table
---   opts.kernel table: WheelKernel instance
---   opts.config table?: Resolved WheelConfig instance
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
  self.agents[agent.name] = agent
  self.agent_states[agent.name] = {
    state = "idle",
    active_task_id = nil,
    tasks_completed = 0,
    handoffs_sent = 0,
    handoffs_received = 0,
  }
  return agent
end

--- Spawn and register a new WheelAgent colleague.
--- @param opts table: options passed to WheelAgent.new
--- @return table: The newly spawned and registered WheelAgent
function WheelTeam:spawn_agent(opts)
  opts = opts or {}
  opts.kernel = opts.kernel or self.kernel
  opts.config = opts.config or self.config
  opts.workspace = opts.workspace or { root = self.workspace_root }
  local agent = WheelAgent.new(opts)
  return self:register_agent(agent)
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
    table.insert(list, {
      name = name,
      role = agent.role,
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
      if not role or agent.role == role then
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
  if not st or st.state ~= "idle" then
    return false, "agent '" .. agent_name .. "' is not idle (current state: " .. tostring(st and st.state) .. ")"
  end

  -- Check if task is already assigned or active in team
  if self.task_assignments[task_id] then
    local assigned_to = self.task_assignments[task_id]
    if assigned_to ~= agent_name then
      return false, "task '" .. task_id .. "' is already claimed by agent '" .. assigned_to .. "'"
    end
  end

  -- Query task from kernel
  local task = self.kernel:get_task(task_id)
  if not task then
    return false, "task not found: " .. tostring(task_id)
  end

  local status_lower = string.lower(task.status or "")
  if status_lower ~= "ready" and status_lower ~= "pending" and status_lower ~= "running" then
    return false, "task '" .. task_id .. "' is not claimable (status: " .. tostring(task.status) .. ")"
  end

  -- Check if task was started by another worker in kernel
  if task.worker_id and task.worker_id ~= "" and task.worker_id ~= agent_name and status_lower == "running" then
    return false, "task '" .. task_id .. "' is already claimed by worker '" .. tostring(task.worker_id) .. "'"
  end

  -- Start task in kernel with agent attribution
  local started_task = self.kernel:start_task(task_id, {
    worker_id = agent_name,
    assigned_agent = agent_name,
  })

  -- Record team claim
  st.state = "busy"
  st.active_task_id = task_id
  self.task_assignments[task_id] = agent_name

  return true, started_task or task
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

  if st.active_task_id ~= task_id then
    return false, "agent '" .. agent_name .. "' does not hold active claim on task '" .. tostring(task_id) .. "'"
  end

  local status = outcome.status or "succeeded"
  local status_lower = string.lower(status)

  local task = self.kernel:get_task(task_id)
  local gen = (task and task.generation) or 1

  if status_lower == "succeeded" then
    self.kernel:complete_task(task_id, gen, outcome.checkpoint_hash)
    st.tasks_completed = (st.tasks_completed or 0) + 1
  else
    self.kernel:fail_task(task_id, gen, outcome.error or "task failed")
  end

  st.state = "idle"
  st.active_task_id = nil
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
  local from_st = self.agent_states[from_agent]
  if not from_st then
    return false, "from_agent '" .. tostring(from_agent) .. "' not found"
  end
  if from_st.active_task_id ~= task_id then
    return false, "from_agent '" .. from_agent .. "' does not hold task '" .. tostring(task_id) .. "'"
  end

  local to_agent_inst = self.agents[to_agent]
  local to_st = self.agent_states[to_agent]
  if not to_agent_inst or not to_st then
    return false, "to_agent '" .. tostring(to_agent) .. "' not found"
  end
  if to_st.state ~= "idle" then
    return false, "to_agent '" .. tostring(to_agent) .. "' is not idle (state: " .. tostring(to_st.state) .. ")"
  end

  local handoff_id = string.format("handoff-%d-%s", #self.handoffs + 1, task_id)
  local record = {
    handoff_id = handoff_id,
    task_id = task_id,
    from_agent = from_agent,
    to_agent = to_agent,
    reason = opts.reason or "handoff",
    rationale = opts.rationale or "",
    checkpoint_hash = opts.checkpoint_hash,
    timestamp = os.time(),
  }

  table.insert(self.handoffs, record)

  -- Transition states
  from_st.state = "idle"
  from_st.active_task_id = nil
  from_st.handoffs_sent = (from_st.handoffs_sent or 0) + 1

  to_st.state = "busy"
  to_st.active_task_id = task_id
  to_st.handoffs_received = (to_st.handoffs_received or 0) + 1

  self.task_assignments[task_id] = to_agent

  return true, record
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
            role = idle_agent.role,
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
    if st.state == "busy" then
      busy = busy + 1
    else
      idle = idle + 1
    end
    table.insert(agent_summaries, {
      name = name,
      role = agent.role,
      state = st.state or "idle",
      active_task_id = st.active_task_id,
      panel_id = agent.panel_id,
      headless = agent.headless,
      model = agent.model_profile or agent.model,
      tasks_completed = st.tasks_completed or 0,
    })
  end

  table.sort(agent_summaries, function(a, b) return a.name < b.name end)

  return {
    total_agents = total,
    idle_count = idle,
    busy_count = busy,
    agents = agent_summaries,
    handoff_count = #self.handoffs,
    handoffs = self.handoffs,
  }
end

return WheelTeam
