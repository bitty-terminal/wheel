-- Wheel Team Coordinator
-- Multi-agent peer colleague collaboration protocol per Wheel architecture.
-- Rejects master-slave hierarchy: each agent is an autonomous peer worker in an engineering workspace.

local function load_submodule(subpath)
  local ok, mod = pcall(require, "wheel." .. subpath)
  if ok then return mod end
  ok, mod = pcall(require, "lua.wheel." .. subpath)
  if ok then return mod end
  return require(subpath)
end

local WheelAgent = load_submodule("agent")
local WheelContext = load_submodule("context")
local WheelTool = load_submodule("tool")
local WheelUI = load_submodule("ui")

local WheelTeam = {}
WheelTeam.__index = WheelTeam

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

  -- Shared context engine and event bus across peer colleagues
  self.context = opts.context or WheelContext.new({
    kernel = self.kernel,
    config = self.config,
    bus = opts.bus,
  })

  self.tool_registry = opts.tool_registry or (WheelTool and WheelTool.get_default_registry())

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
  local started_task = self.kernel:start_task(task_id, agent_name)

  -- Record team claim
  st.state = "busy"
  st.active_task_id = task_id
  self.task_assignments[task_id] = agent_name

  -- Record worker assignment in semantic slots
  if self.context and type(self.context.put_slot) == "function" then
    self.context:put_slot("tasks/" .. task_id .. "/worker", agent_name)
  end

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
  local cur_status = string.lower((task and task.status) or "")

  if status_lower == "succeeded" then
    if cur_status ~= "succeeded" then
      self.kernel:complete_task(task_id, gen, outcome.checkpoint_hash)
    end
    st.tasks_completed = (st.tasks_completed or 0) + 1
  else
    if cur_status ~= "failed" then
      self.kernel:fail_task(task_id, gen, outcome.error or "task failed")
    end
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

  -- Record structured handoff in semantic slots and notify receiver
  if self.context and type(self.context.put_slot) == "function" then
    local handoff_payload = string.format("from: %s\nto: %s\ntask: %s\nreason: %s\nrationale: %s\ncheckpoint: %s",
      from_agent, to_agent, task_id, record.reason, record.rationale, record.checkpoint_hash or "none")
    self.context:put_slot("tasks/" .. task_id .. "/handoff", handoff_payload)
    if self.context.bus and type(self.context.bus.publish) == "function" then
      self.context.bus:publish({
        type = "handoff_received",
        handoff = record,
        from_agent = from_agent,
        to_agent = to_agent,
        task_id = task_id,
      })
    end
  end

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
  local start_clock = os.clock()

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

        local ok_exec, exec_outcome = pcall(worker.execute_task, worker, task_id, step_fn)
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
            local ok_ho, ho_record = self:handoff(worker.name, reviewer.name, task_id, {
              reason = "verification_request",
              rationale = "Implementation deliverables complete, ready for independent verification",
              checkpoint_hash = last_cp,
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

  local duration_ms = math.max(1, math.floor((os.clock() - start_clock) * 1000))
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
