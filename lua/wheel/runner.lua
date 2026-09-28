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

local ok_provider, WheelProvider = pcall(require, "wheel.provider")
if not ok_provider then
  local ok_p2, WheelP2 = pcall(require, "lua.wheel.provider")
  WheelProvider = ok_p2 and WheelP2 or nil
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
--   usage = table,
-- }
function WheelRunner.run_task(agent, task, opts)
  opts = opts or {}
  if not agent or not task then
    return { success = false, error = "Invalid agent or task argument", iterations = 0 }
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
      provider = WheelProvider.create(agent.model_profile, opts)
      if agent.set_provider then
        agent:set_provider(provider)
      end
    end
  end

  if not provider then
    -- Fallback to MockProvider if no provider configured
    if WheelProvider then
      provider = WheelProvider.MockProvider.new({ model = "default-mock" })
    else
      return { success = false, error = "No provider adapter available", iterations = 0 }
    end
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
  local total_usage = {
    prompt_tokens = 0,
    completion_tokens = 0,
    thinking_tokens = 0,
    total_tokens = 0,
  }

  local turn = 0
  local final_artifacts = nil
  local loop_success = false
  local final_error = nil

  while turn < max_turns do
    turn = turn + 1

    if on_turn_start then
      on_turn_start(turn, task)
    end

    -- Compile Three-Zone Context
    local system_text = string.format("Agent: %s (Role: %s)\nSoftware Engineering domain only. Fail-closed on security violations.", agent.name, agent.role)
    if agent.context and type(agent.context.compile_prompt) == "function" then
      local ctx_res = agent.context:compile_prompt({
        system_instruction = system_text,
        project_rules = (agent.config and agent.config.directives) or { "Software Engineering domain only", "Fail-closed on security violations" },
        tool_schemas = agent.tools or {},
        active_task = task,
        turn_prompt = string.format("Execute turn %d for task %s", turn, task_id),
      })
      if ctx_res then
        agent.last_prefix_cache_key = ctx_res.prefix_cache_key
        agent.last_cache_share_ratio = ctx_res.cache_share_ratio
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

    -- Build Provider Request
    local req = {
      model = (agent.model_profile and agent.model_profile.model) or "default-model",
      messages = messages,
      tools = tools,
      temperature = (agent.model_profile and agent.model_profile.temperature) or 0.0,
      thinking = agent.model_profile and agent.model_profile.thinking,
    }

    -- Call model stream
    local stream_cb = function(chunk)
      if on_token and chunk.delta then
        on_token(chunk.delta, chunk.type or "content")
      end
    end

    local res, stream_err = provider:stream(req, stream_cb, opts)
    if not res then
      final_error = "Provider streaming failed: " .. tostring(stream_err)
      break
    end

    -- Accumulate usage telemetry
    if res.usage then
      total_usage.prompt_tokens = total_usage.prompt_tokens + (res.usage.prompt_tokens or 0)
      total_usage.completion_tokens = total_usage.completion_tokens + (res.usage.completion_tokens or 0)
      total_usage.thinking_tokens = total_usage.thinking_tokens + (res.usage.thinking_tokens or 0)
      total_usage.total_tokens = total_usage.total_tokens + (res.usage.total_tokens or 0)
    end

    -- Construct Structured Rationale
    local rationale = {
      why = string.format("Autonomous execution turn %d for task %s", turn, task_id),
      what = (res.content and #res.content > 0) and res.content:sub(1, 300) or ("Completed turn " .. turn),
      where_focus = "task " .. task_id,
      how = "autonomous LLM ReAct turn loop",
      expected = "Task deliverables and verification",
      observed = (res.thinking_content and #res.thinking_content > 0) and res.thinking_content:sub(1, 300) or "Model response processed",
    }

    -- Handle tool calls
    local tool_calls = res.tool_calls or {}
    if #tool_calls > 0 then
      -- Record assistant response message with tool calls
      table.insert(messages, {
        role = "assistant",
        content = res.content or "",
        tool_calls = tool_calls,
      })

      -- Execute each tool call
      for _, tc in ipairs(tool_calls) do
        if on_tool_call then
          on_tool_call(tc)
        end

        local outcome = agent:execute_tool(tc.name, tc.arguments)
        if on_tool_result then
          on_tool_result(tc, outcome)
        end

        -- Record action in kernel
        if agent.kernel and type(agent.kernel.record_action) == "function" then
          agent.kernel:record_action({
            action_id = string.format("%s-t%d-%s", task_id, turn, tc.name or "tool"),
            success = outcome.success,
            exit_code = outcome.exit_code,
            duration_ms = outcome.duration_ms,
            raw_stdout = outcome.stdout or "",
            raw_stderr = outcome.stderr or "",
          })
        end

        -- Format observation string for next turn
        local observation = outcome:format_observation()
        table.insert(messages, {
          role = "tool",
          tool_call_id = tc.id,
          content = observation,
        })
      end

      -- Commit turn checkpoint if enabled
      if commit_checkpoints and agent.kernel and type(agent.kernel.commit_checkpoint) == "function" then
        local cp = agent.kernel:commit_checkpoint(rationale)
        if cp and cp.hash then
          table.insert(checkpoints, cp.hash)
        end
      end
    else
      -- Model produced text response without further tool calls -> Final answer / deliverables
      final_artifacts = res.content or string.format("Deliverables for %s completed by %s", task_id, agent.name)

      -- Publish deliverables to semantic slot
      if agent.context and type(agent.context.put_slot) == "function" then
        agent.context:put_slot("tasks/" .. task_id .. "/artifacts", final_artifacts)
      end

      -- Commit completion checkpoint
      if commit_checkpoints and agent.kernel and type(agent.kernel.commit_checkpoint) == "function" then
        rationale.what = "Final deliverables produced for " .. task_id
        local cp = agent.kernel:commit_checkpoint(rationale)
        if cp and cp.hash then
          table.insert(checkpoints, cp.hash)
        end
      end

      loop_success = true
      break
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
    usage = total_usage,
  }
end

return WheelRunner
