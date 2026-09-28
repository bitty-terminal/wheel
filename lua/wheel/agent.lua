-- Wheel Agent Runtime
-- Software Engineering agent harness per research record 046.
-- Fixed domain: Software Engineering only (coding copilot, debugger, reviewer, commander).
-- Roles vary by configuration inside that domain, bounded by budgets and permissions.

local WheelAgent = {}
WheelAgent.__index = WheelAgent

--- Agent role definitions.
WheelAgent.Role = {
  COMMANDER = "commander",
  CODING = "coding",
  DEBUG = "debug",
  RESEARCH = "research",
  REVIEWER = "reviewer",
}

--- Read-only tool allowlist enforced for Research and Reviewer roles.
local READ_ONLY_TOOLS = {
  ["read_file"] = true,
  ["view_file"] = true,
  ["search_code"] = true,
  ["find_files"] = true,
  ["list_directory"] = true,
  ["inspect"] = true,
  ["git_diff"] = true,
  ["git_log"] = true,
  ["git_status"] = true,
  ["read_resource"] = true,
  ["list_resources"] = true,
  ["read_url_content"] = true,
  ["search_web"] = true,
  ["ask_question"] = true,
  ["get_outline"] = true,
}

WheelAgent.READ_ONLY_TOOLS = READ_ONLY_TOOLS

--- Create a new Agent instance.
--- @param opts table
---   opts.name string: Agent identity (e.g. "commander-01", "worker-coding-01")
---   opts.role string: One of WheelAgent.Role
---   opts.kernel table: WheelKernel instance
---   opts.model table?: Model config { name = string, temperature = number }
---   opts.tools table?: List of allowed tool names
---   opts.budget table?: Budget limits { max_iterations = number, max_tokens = number }
---   opts.workspace table?: Workspace config { root = string }
--- @return table
function WheelAgent.new(opts)
  opts = opts or {}
  if not opts.name or opts.name == "" then
    error("Agent requires a non-empty 'name'")
  end
  local role = opts.role or WheelAgent.Role.CODING
  local valid_role = false
  for _, r in pairs(WheelAgent.Role) do
    if r == role then
      valid_role = true
      break
    end
  end
  if not valid_role then
    error("Invalid agent role: " .. tostring(role))
  end
  if not opts.kernel then
    error("Agent requires a 'kernel' (WheelKernel instance)")
  end

  local self = setmetatable({}, WheelAgent)
  self.name = opts.name
  self.role = role
  self.kernel = opts.kernel
  self.model = opts.model or { name = "claude-3-5-sonnet", temperature = 0.2 }
  self.tools = opts.tools or { "read_file", "write_file", "run_command" }
  self.budget = opts.budget or { max_iterations = 10, max_tokens = 65536 }
  self.workspace = opts.workspace or { root = "." }

  return self
end

--- Check if a tool can be invoked under this agent's role authority.
--- @param tool_name string
--- @return boolean, string?
function WheelAgent:is_tool_allowed(tool_name)
  -- 1. Check if tool is in agent's declared tools
  local declared = false
  for _, t in ipairs(self.tools) do
    if t == tool_name or t == "*" then
      declared = true
      break
    end
  end
  if not declared then
    return false, "tool '" .. tool_name .. "' is not in declared tools for " .. self.name
  end

  -- 2. Role-based read-only gating: Research and Reviewer cannot call mutating tools
  if self.role == WheelAgent.Role.RESEARCH or self.role == WheelAgent.Role.REVIEWER then
    if not READ_ONLY_TOOLS[tool_name] then
      return false, "role '" .. self.role .. "' has read-only authority; denied: " .. tool_name
    end
  end

  return true, nil
end

--- Execute a task in the DAG as a Worker.
--- Sets active task, binds worker, iterates step function under budget, records actions,
--- and commits cognitive checkpoints upon completion.
--- @param task_id string
--- @param step_fn fun(agent: table, ctx: table, iteration: number): table
---   step_fn returns:
---     action: table? { action_id = string, tool = string, stdout = string, stderr = string, exit_code = number, duration_ms = number }
---     rationale: table? { why = string, what = string, where_focus = string?, how = string?, expected = string?, observed = string? }
---     done: boolean?
---     error: string?
--- @return table { success: boolean, task: table, checkpoints: string[], iterations: number, error: string? }
function WheelAgent:execute_task(task_id, step_fn)
  local task = self.kernel:get_task(task_id)
  if not task then
    error("Task not found: " .. tostring(task_id))
  end
  local st_lower = (task.status or ""):lower()
  if st_lower ~= "ready" then
    error("Task " .. task_id .. " is not Ready (current status: " .. tostring(task.status) .. ")")
  end
  local assigned = task.assigned_agent
  if not assigned or assigned == "" then
    assigned = task.worker_id
  end
  if assigned and assigned ~= "" and assigned ~= self.name then
    error("Task " .. task_id .. " is already assigned to " .. assigned)
  end

  -- 1. Set active task in kernel
  self.kernel:set_active_task(task_id)

  -- 2. Start task in kernel, getting generation
  local started = self.kernel:start_task(task_id, self.name)
  local generation = started.generation

  local checkpoints = {}
  local last_checkpoint_hash = nil
  local iterations = 0
  local max_iter = self.budget.max_iterations or 10
  local execution_success = false
  local final_error = nil

  while iterations < max_iter do
    iterations = iterations + 1

    -- Compile three-zone context
    local ctx = self.kernel:compile_context({
      system_instruction = string.format("Agent: %s (Role: %s)", self.name, self.role),
      project_rules = { "Software Engineering domain only", "Fail-closed on security violations" },
      turn_prompt = string.format("Execute step %d for task %s: %s", iterations, task_id, task.title),
    })

    -- Call step callback
    local step_result = step_fn(self, ctx, iterations) or {}

    -- Process action if produced
    if step_result.action then
      local act = step_result.action
      local tool = act.tool or "tool"
      local allowed, err_reason = self:is_tool_allowed(tool)
      if not allowed then
        final_error = err_reason
        break
      end

      self.kernel:record_action({
        action_id = act.action_id or (task_id .. "-act-" .. iterations),
        success = (act.exit_code == nil or act.exit_code == 0),
        exit_code = act.exit_code or 0,
        duration_ms = act.duration_ms or 10,
        raw_stdout = act.stdout or "",
        raw_stderr = act.stderr or "",
      })
    end

    -- Process cognitive checkpoint rationale
    if step_result.rationale then
      local cp = self.kernel:commit_checkpoint(step_result.rationale)
      if cp and cp.hash then
        last_checkpoint_hash = cp.hash
        table.insert(checkpoints, cp.hash)
      end
    end

    -- Check completion or failure
    if step_result.error then
      final_error = step_result.error
      break
    elseif step_result.done then
      execution_success = true
      break
    end
  end

  if not execution_success and not final_error and iterations >= max_iter then
    final_error = "iteration budget exhausted (" .. tostring(max_iter) .. " steps)"
  end

  local finished_task
  if execution_success then
    finished_task = self.kernel:complete_task(task_id, generation, last_checkpoint_hash)
  else
    finished_task = self.kernel:fail_task(task_id, generation, final_error or "unknown failure")
  end

  -- Clear active task
  self.kernel:set_active_task(nil)

  return {
    success = execution_success,
    task = finished_task,
    checkpoints = checkpoints,
    iterations = iterations,
    error = final_error,
  }
end

--- Decompose and submit a software engineering plan into the Task DAG (Commander role).
--- @param plan_items table[] Array of { id = string, title = string, description = string, priority = number?, dependencies = string[]? }
--- @return table[] List of created task records
function WheelAgent:decompose_plan(plan_items)
  if self.role ~= WheelAgent.Role.COMMANDER then
    error("Only Commander role may decompose project plans (current role: " .. self.role .. ")")
  end
  local created = {}
  for _, item in ipairs(plan_items) do
    local task = self.kernel:create_task(item)
    table.insert(created, task)
  end
  return created
end

--- Review a completed task and its artifacts (Reviewer role).
--- @param task_id string
--- @param review_fn fun(agent: table, task: table, history: table[]): boolean, string
--- @return table { approved: boolean, reason: string?, checkpoint: string? }
function WheelAgent:review_task(task_id, review_fn)
  if self.role ~= WheelAgent.Role.REVIEWER then
    error("Only Reviewer role may review tasks (current role: " .. self.role .. ")")
  end
  local task = self.kernel:get_task(task_id)
  if not task then
    error("Task not found: " .. tostring(task_id))
  end
  local st_lower = (task.status or ""):lower()
  if st_lower ~= "succeeded" then
    error("Cannot review uncompleted task " .. task_id .. " (status: " .. tostring(task.status) .. ")")
  end

  local history = self.kernel:log(8)
  local approved, reason = review_fn(self, task, history)

  local cp_hash = nil
  if approved then
    local cp = self.kernel:commit_checkpoint({
      why = "Task verification and acceptance",
      what = "Independent review approved for " .. task_id,
      where_focus = "task " .. task_id,
      how = "evaluated task outcomes and code diffs against acceptance criteria",
      expected = "all quality gates and contracts satisfied",
      observed = reason or "verification passed cleanly",
    })
    cp_hash = cp.hash
  end

  return {
    approved = approved,
    reason = reason,
    checkpoint = cp_hash,
  }
end

return WheelAgent
