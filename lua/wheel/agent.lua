-- Wheel Agent Runtime
-- Software Engineering agent harness per research record 046.
-- Fixed domain: Software Engineering only (coding copilot, debugger, reviewer, commander).
-- Roles vary by configuration inside that domain, bounded by budgets and permissions.

local WheelAgent = {}
WheelAgent.__index = WheelAgent

local ok_tool, WheelTool = pcall(require, "wheel.tool")
if not ok_tool then
  local ok_tool2, WheelTool2 = pcall(require, "lua.wheel.tool")
  WheelTool = ok_tool2 and WheelTool2 or nil
end
WheelAgent.Tool = WheelTool

local ok_provider, WheelProvider = pcall(require, "wheel.provider")
if not ok_provider then
  local ok_p2, WheelP2 = pcall(require, "lua.wheel.provider")
  WheelProvider = ok_p2 and WheelP2 or nil
end
WheelAgent.Provider = WheelProvider

local ok_runner, WheelRunner = pcall(require, "wheel.runner")
if not ok_runner then
  local ok_r2, WheelR2 = pcall(require, "lua.wheel.runner")
  WheelRunner = ok_r2 and WheelR2 or nil
end
WheelAgent.Runner = WheelRunner

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

--- Default heterogeneous model profiles per role.
local DEFAULT_MODEL_PROFILES = {
  [WheelAgent.Role.COMMANDER] = {
    provider = "anthropic",
    model = "claude-3-5-sonnet",
    temperature = 0.2,
    thinking = { enabled = true, gear = "medium", budget_tokens = 4096 },
    context_budget = { max_tokens = 65536 },
    retry = { max_retries = 3, backoff_ms = 1000 },
  },
  [WheelAgent.Role.CODING] = {
    provider = "anthropic",
    model = "claude-3-5-sonnet",
    temperature = 0.0,
    thinking = { enabled = false, gear = "off", budget_tokens = 0 },
    context_budget = { max_tokens = 65536 },
    retry = { max_retries = 3, backoff_ms = 1000 },
  },
  [WheelAgent.Role.DEBUG] = {
    provider = "deepseek",
    model = "deepseek-reasoner",
    temperature = 0.0,
    thinking = { enabled = true, gear = "high", budget_tokens = 8192 },
    context_budget = { max_tokens = 65536 },
    retry = { max_retries = 3, backoff_ms = 1000 },
  },
  [WheelAgent.Role.REVIEWER] = {
    provider = "openai",
    model = "gpt-4o",
    temperature = 0.0,
    thinking = { enabled = false, gear = "off", budget_tokens = 0 },
    context_budget = { max_tokens = 65536 },
    retry = { max_retries = 3, backoff_ms = 1000 },
  },
  [WheelAgent.Role.RESEARCH] = {
    provider = "local",
    model = "qwen2.5-coder",
    temperature = 0.4,
    thinking = { enabled = false, gear = "off", budget_tokens = 0 },
    context_budget = { max_tokens = 32768 },
    retry = { max_retries = 2, backoff_ms = 500 },
  },
}

--- Deep copy a table.
local function deep_copy(orig)
  if type(orig) ~= "table" then return orig end
  local copy = {}
  for k, v in pairs(orig) do
    copy[k] = deep_copy(v)
  end
  return copy
end

--- Get a copy of the default model profile for a given role.
--- @param role string: One of WheelAgent.Role
--- @return table: Model profile table
function WheelAgent.get_default_model_profile(role)
  local def = DEFAULT_MODEL_PROFILES[role] or DEFAULT_MODEL_PROFILES[WheelAgent.Role.CODING]
  return deep_copy(def)
end

--- Validate a model profile definition.
--- @param profile table
--- @return boolean is_valid, string? error_reason
function WheelAgent.validate_model_profile(profile)
  if type(profile) ~= "table" then
    return false, "model_profile must be a table"
  end
  if type(profile.provider) ~= "string" or profile.provider == "" then
    return false, "model_profile.provider must be a non-empty string"
  end
  if type(profile.model) ~= "string" or profile.model == "" then
    return false, "model_profile.model must be a non-empty string"
  end
  if profile.temperature ~= nil then
    if type(profile.temperature) ~= "number" or profile.temperature < 0.0 or profile.temperature > 2.0 then
      return false, "model_profile.temperature must be a number between 0.0 and 2.0"
    end
  end
  if profile.thinking ~= nil then
    if type(profile.thinking) ~= "table" then
      return false, "model_profile.thinking must be a table"
    end
    if profile.thinking.budget_tokens ~= nil then
      if type(profile.thinking.budget_tokens) ~= "number" or profile.thinking.budget_tokens < 0 then
        return false, "model_profile.thinking.budget_tokens must be a non-negative number"
      end
    end
  end
  return true, nil
end

--- Create a new Agent instance.
--- @param opts table
---   opts.name string: Agent identity (e.g. "commander-01", "worker-coding-01")
---   opts.role string: One of WheelAgent.Role
---   opts.kernel table: WheelKernel instance
---   opts.model table?: Model config { name = string, temperature = number }
---   opts.model_profile table?: Heterogeneous model profile table
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

  -- Role config resolution from opts.config if present
  local role_cfg = (opts.config and opts.config.roles and opts.config.roles[role]) or {}

  -- Model profile resolution (heterogeneous model profile support)
  local default_profile = WheelAgent.get_default_model_profile(role)
  local user_profile = opts.model_profile or (role_cfg and role_cfg.model_profile)
  if user_profile then
    local ok_val, val_err = WheelAgent.validate_model_profile(user_profile)
    if not ok_val then
      error("Invalid model_profile for agent '" .. self.name .. "': " .. tostring(val_err))
    end
    for k, v in pairs(user_profile) do
      default_profile[k] = v
    end
  elseif opts.model or (role_cfg and role_cfg.model) then
    local m = opts.model or role_cfg.model
    if type(m) == "table" then
      default_profile.model = m.name or m.model or default_profile.model
      if m.temperature ~= nil then
        default_profile.temperature = m.temperature
      end
      if m.provider ~= nil then
        default_profile.provider = m.provider
      end
    end
  end
  self.model_profile = default_profile

  -- Backward-compatibility: maintain self.model table with name and temperature
  self.model = {
    name = self.model_profile.model,
    model = self.model_profile.model,
    provider = self.model_profile.provider,
    temperature = self.model_profile.temperature,
    thinking = self.model_profile.thinking,
  }

  self.tools = opts.tools or role_cfg.tools or { "read_file", "write_file", "run_command" }
  self.budget = opts.budget or role_cfg.budget or { max_iterations = 10, max_tokens = 65536 }
  self.workspace = opts.workspace or { root = "." }

  -- Headless Panel working container invariant:
  -- Bitty Core Rule R1: ExecutionContext is primary; panels describe presentation, not execution authority.
  -- Every agent defaults to running inside a Headless Panel working container.
  -- Presentation UI panels are optional observation projections.
  local cfg_panel = (opts.config and opts.config.panel) or {}
  self.panel_id = opts.panel_id or cfg_panel.panel_id or ("headless:panel:" .. self.name)
  if opts.headless ~= nil then
    self.headless = opts.headless
  elseif cfg_panel.headless ~= nil then
    self.headless = cfg_panel.headless
  else
    self.headless = true
  end
  self.config = opts.config
  self.context = opts.context
  self.tool_registry = opts.tool_registry or (WheelTool and WheelTool.get_default_registry())
  self.last_prefix_cache_key = nil
  self.last_cache_share_ratio = nil

  self.provider = opts.provider
  if not self.provider and WheelProvider and self.model_profile then
    self.provider = WheelProvider.create(self.model_profile)
  end

  return self
end

--- Get the active LLM Provider adapter.
--- @return table?: Provider adapter instance
function WheelAgent:get_provider()
  return self.provider
end

--- Set the LLM Provider adapter.
--- @param provider table Provider adapter instance
function WheelAgent:set_provider(provider)
  self.provider = provider
end

--- Get the active WheelContext engine.
--- @return table?: WheelContext instance
function WheelAgent:get_context()
  return self.context
end

--- Get a semantic slot from context.
--- @param name string
--- @return table: slot retrieval result
function WheelAgent:get_slot(name)
  if self.context then
    return self.context:get_slot(name)
  elseif self.kernel and type(self.kernel.get_slot) == "function" then
    return self.kernel:get_slot(name)
  end
  return { name = name, found = false }
end

--- Put a semantic slot into context with optional CAS.
--- @param name string
--- @param content string
--- @param expected_version integer|nil
--- @return table|nil, table|nil
function WheelAgent:put_slot(name, content, expected_version)
  if self.context then
    return self.context:put_slot(name, content, expected_version)
  elseif self.kernel and type(self.kernel.put_slot) == "function" then
    return self.kernel:put_slot(name, content)
  end
  return nil, { error = "no_context", message = "No context engine available" }
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

  -- 2. If tool is in registry, enforce intent-based role authority gating
  if self.tool_registry and type(self.tool_registry.get_tool) == "function" and WheelTool then
    local tool_def = self.tool_registry:get_tool(tool_name)
    if tool_def then
      local ok_auth, auth_err = WheelTool.check_role_authority(self.role, tool_def)
      if not ok_auth then
        return false, auth_err
      end
      return true, nil
    end
  end

  -- 3. Fallback role-based read-only gating: Research and Reviewer cannot call mutating tools
  if self.role == WheelAgent.Role.RESEARCH or self.role == WheelAgent.Role.REVIEWER then
    if not READ_ONLY_TOOLS[tool_name] then
      return false, "role '" .. self.role .. "' has read-only authority; denied: " .. tool_name
    end
  end

  return true, nil
end

--- Execute a tool directly under this agent's security boundary and role authority.
--- Measures execution latency, auto-spills oversized output into context memory,
--- and records action outcome into kernel and ContextBus.
--- @param tool_name string Name of tool to execute
--- @param args table? Tool arguments
--- @return table ActionOutcome instance
function WheelAgent:execute_tool(tool_name, args)
  args = args or {}
  local allowed, reason = self:is_tool_allowed(tool_name)
  if not allowed then
    if WheelTool and type(WheelTool.process_spillover) == "function" then
      return WheelTool.process_spillover({
        tool = tool_name,
        success = false,
        status = WheelTool.OutcomeStatus.DENIED,
        exit_code = 126,
        stderr = reason,
      })
    end
    error(reason)
  end

  if not self.tool_registry then
    error("Agent " .. self.name .. " has no tool_registry configured")
  end

  return self.tool_registry:dispatch(tool_name, args, {
    role = self.role,
    agent_name = self.name,
    workspace_root = self.workspace and self.workspace.root or ".",
    kernel = self.kernel,
    context = self.context,
  })
end

--- Execute a batch of tool calls (e.g. from an LLM response).
--- @param tool_calls table[] Array of { id = string?, name = string, arguments = table|string? }
--- @return table[] Array of ActionOutcome instances
function WheelAgent:call_tools(tool_calls)
  tool_calls = tool_calls or {}
  local outcomes = {}
  for _, tc in ipairs(tool_calls) do
    local name = tc.name or tc.tool
    local args = tc.arguments or tc.args or {}
    if type(args) == "string" and WheelKernel and WheelKernel.json then
      local ok, decoded = pcall(WheelKernel.json.decode, args)
      if ok and type(decoded) == "table" then
        args = decoded
      end
    end
    local outcome = self:execute_tool(name, args)
    if tc.id then
      outcome.call_id = tc.id
    end
    table.insert(outcomes, outcome)
  end
  return outcomes
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
  if st_lower ~= "ready" and st_lower ~= "running" then
    error("Task " .. task_id .. " is not Ready or Running (current status: " .. tostring(task.status) .. ")")
  end
  local assigned = task.assigned_agent
  if type(assigned) == "table" then
    assigned = assigned.assigned_agent or assigned.worker_id or ""
  end
  if not assigned or assigned == "" then
    assigned = task.worker_id
    if type(assigned) == "table" then
      assigned = assigned.worker_id or assigned.assigned_agent or ""
    end
  end
  if assigned and assigned ~= "" and assigned ~= self.name then
    error("Task " .. task_id .. " is already assigned to " .. tostring(assigned))
  end

  -- Autonomous ReAct loop via WheelRunner when step_fn is nil or table of options
  if type(step_fn) ~= "function" then
    if WheelRunner and type(WheelRunner.run_task) == "function" then
      local runner_opts = (type(step_fn) == "table") and step_fn or {}
      local runner_res = WheelRunner.run_task(self, task, runner_opts)
      local cur = self.kernel:get_task(task_id) or task
      local generation = cur.generation or task.generation or 0
      local last_cp = runner_res.checkpoints and runner_res.checkpoints[#runner_res.checkpoints]
      local finished
      if not runner_opts.defer_release then
        if runner_res.success then
          finished = self.kernel:complete_task(task_id, generation, last_cp)
        else
          finished = self.kernel:fail_task(task_id, generation, runner_res.error or "unknown failure")
        end
      end
      self.kernel:set_active_task(nil)
      return {
        success = runner_res.success,
        task = finished or self.kernel:get_task(task_id) or task,
        artifacts = runner_res.artifacts,
        checkpoints = runner_res.checkpoints,
        iterations = runner_res.iterations,
        error = runner_res.error,
        usage = runner_res.usage,
      }
    else
      error("WheelRunner not available to execute task without step_fn")
    end
  end

  -- 1. Set active task in kernel
  self.kernel:set_active_task(task_id)

  -- 2. Start task in kernel, getting generation (if not already started)
  local generation = task.generation or 0
  if st_lower == "ready" then
    local started = self.kernel:start_task(task_id, self.name)
    generation = (started and started.generation) or generation
  end

  local checkpoints = {}
  local last_checkpoint_hash = nil
  local iterations = 0
  local max_iter = self.budget.max_iterations or 10
  local execution_success = false
  local final_error = nil

  while iterations < max_iter do
    iterations = iterations + 1

    -- Compile three-zone context
    local ctx
    if self.context and type(self.context.compile_prompt) == "function" then
      local ctx_res = self.context:compile_prompt({
        system_instruction = string.format("Agent: %s (Role: %s)", self.name, self.role),
        project_rules = (self.config and self.config.directives) or { "Software Engineering domain only", "Fail-closed on security violations" },
        tool_schemas = self.tools or {},
        active_task = task,
        turn_prompt = string.format("Execute step %d for task %s: %s", iterations, task_id, task.title),
      })
      if ctx_res then
        self.last_prefix_cache_key = ctx_res.prefix_cache_key
        self.last_cache_share_ratio = ctx_res.cache_share_ratio
      end
      ctx = ctx_res or { prompt_string = "" }
    else
      ctx = self.kernel:compile_context({
        system_instruction = string.format("Agent: %s (Role: %s)", self.name, self.role),
        project_rules = { "Software Engineering domain only", "Fail-closed on security violations" },
        turn_prompt = string.format("Execute step %d for task %s: %s", iterations, task_id, task.title),
      })
    end

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
    panel_id = self.panel_id,
    headless = self.headless,
    model_profile = self.model_profile,
    prefix_cache_key = self.last_prefix_cache_key,
    cache_share_ratio = self.last_cache_share_ratio,
  }
end

--- Get the resolved heterogeneous model profile for this agent.
--- @return table: Model profile definition
function WheelAgent:get_model_profile()
  return self.model_profile
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
--- @param review_fn fun(agent: table, task: table, history: table[])?: boolean, string
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
  if st_lower ~= "succeeded" and st_lower ~= "running" and st_lower ~= "waiting_review" then
    error("Cannot review uncompleted task " .. task_id .. " (status: " .. tostring(task.status) .. ")")
  end

  if type(review_fn) ~= "function" then
    error("review_fn is required for independent review")
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

--- Get current agent status summary including headless panel container telemetry and model profile.
--- @return table
function WheelAgent:status()
  return {
    name = self.name,
    role = self.role,
    panel_id = self.panel_id,
    headless = self.headless,
    model_profile = self.model_profile,
    model = self.model,
    tools = self.tools,
    budget = self.budget,
    workspace = self.workspace,
    active_task = self.kernel and self.kernel.active_task_id,
    prefix_cache_key = self.last_prefix_cache_key,
    cache_share_ratio = self.last_cache_share_ratio,
    tool_count = self.tool_registry and #self.tool_registry:list_tools() or #self.tools,
    provider = self.provider and (self.provider.describe and self.provider:describe() or { provider = self.provider.name }) or nil,
  }
end

return WheelAgent
