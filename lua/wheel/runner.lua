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

local function bound_text(value, limit)
  local text = type(value) == "string" and value or tostring(value or "")
  if #text <= limit then return text end
  if limit <= 3 then return text:sub(1, limit) end
  return text:sub(1, limit - 3) .. "..."
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
  if #target >= WheelRunner.MAX_EVIDENCE_ITEMS then return end
  local text = bound_text(value, limit)
  if #text == 0 then return end
  for _, existing in ipairs(target) do
    if existing == text then return end
  end
  target[#target + 1] = text
end

local function extract_state(turn_record, state)
  local response = turn_record.response or {}
  for _, field in ipairs({ "decisions", "risks", "next_actions" }) do
    local values = response[field]
    if type(values) == "table" then
      for _, value in ipairs(values) do
        append_unique_bounded(state[field], value, WheelRunner.MAX_STATE_FIELD_BYTES)
      end
    elseif values ~= nil then
      append_unique_bounded(state[field], values, WheelRunner.MAX_STATE_FIELD_BYTES)
    end
  end
  if response.content then
    append_unique_bounded(state.evidence, response.content, WheelRunner.MAX_EVIDENCE_BYTES)
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
          tostring(outcome.exit_code or 1), outcome.stderr or "tool failed"), WheelRunner.MAX_STATE_FIELD_BYTES)
    end
    local evidence = (outcome.blob_hash or outcome.spillover_hash)
      and ("ref=" .. tostring(outcome.blob_hash or outcome.spillover_hash))
      or outcome.stdout or outcome.stderr
    if evidence then append_unique_bounded(state.evidence, evidence, WheelRunner.MAX_EVIDENCE_BYTES) end
  end
end

local function serialize_state(state, context_ref)
  local lines = {
    "ContextRef v1",
    "id=" .. context_ref.id,
    "turns=" .. tostring(context_ref.turns),
    "bytes=" .. tostring(context_ref.bytes),
  }
  local fields = { "tool_calls", "failures", "decisions", "evidence", "risks", "next_actions" }
  local truncated = false
  local function append_line(line)
    local current_bytes = #table.concat(lines, "\n")
    local extra_bytes = #line + (#lines > 0 and 1 or 0)
    if current_bytes + extra_bytes > WheelRunner.MAX_CONTEXT_REF_BYTES then
      truncated = true
      return false
    end
    lines[#lines + 1] = line
    return true
  end
  for _, field in ipairs(fields) do
    if not append_line("[" .. field .. "]") then break end
    for _, value in ipairs(state[field] or {}) do
      if not append_line(bound_text(value, WheelRunner.MAX_STATE_FIELD_BYTES)) then break end
    end
    if truncated then break end
  end
  if truncated then append_line("[state truncated]") end
  return table.concat(lines, "\n")
end

local function copy_message(message)
  local copy = {}
  for key, value in pairs(message) do
    if key == "content" then
      copy[key] = bound_text(value, WheelRunner.MAX_EVIDENCE_BYTES)
    else
      copy[key] = value
    end
  end
  return copy
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

  local ref_seed = table.concat({ task_id, tostring(#turn_records), tostring(old_bytes), tostring(#state.evidence) }, ":")
  local ref_hash = context and context.compute_hash and context.compute_hash(ref_seed)
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
    encoded = serialize_state(state, context_ref)
    local encoded_bytes = #encoded
    if context_ref.bytes == encoded_bytes then break end
    context_ref.bytes = encoded_bytes
  end
  encoded = serialize_state(state, context_ref)
  context_ref.bytes = #encoded
  if #serialize_state(state, context_ref) ~= context_ref.bytes then
    encoded = serialize_state(state, context_ref)
    context_ref.bytes = #encoded
  end

  if context and type(context.put_slot) == "function" then
    local slot_name = "tasks/" .. task_id .. "/context_ref"
    context:put_slot(slot_name, encoded)
    if type(context.commit_checkpoint) == "function" then
      local commit = context:commit_checkpoint({
        author = opts.author or "wheel:runner",
        task_id = task_id,
        message = "ContextRef compaction " .. context_ref.id,
        rationale = {
          why = "Bound autonomous conversation history",
          what = context_ref.id,
          observed = string.format("retained %d of %d turns", #retained, #turn_records),
        },
      })
      context_ref.commit_hash = commit and commit.hash or nil
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
  return compacted, context_ref, retained
end

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
      append_unique_bounded(retained_state.failures, final_error, WheelRunner.MAX_STATE_FIELD_BYTES)
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
    local turn_record = { response = res, tools = {}, messages = {} }
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
          outcome = {
            tool = tc.name or "tool",
            success = false,
            exit_code = 1,
            duration_ms = 0,
            stdout = "",
            stderr = "Tool execution failed: " .. dispatch_error,
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
            preview = outcome.preview,
            stdout_preview = outcome.stdout_preview,
            stderr_preview = outcome.stderr_preview,
            raw_stdout = outcome.stdout or "",
            raw_stderr = outcome.stderr or "",
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

    table.insert(turn_records, turn_record)
    extract_state(turn_record, retained_state)
    local compacted_messages, compacted_ref, retained_records = WheelRunner.compact_history(messages, turn_records, retained_state, {
      context = agent.context,
      task_id = task_id,
      author = agent.name,
    })
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
    usage = total_usage,
    context_ref = context_ref,
  }
end

return WheelRunner
