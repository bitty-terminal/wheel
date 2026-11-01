-- CTX-0043: bounded runner history and deterministic ContextRef coverage.

local WheelRunner = require("wheel.runner")

local function message(role, content)
  return { role = role, content = content }
end

return function(run_test)
  run_test("WheelRunner history: compaction thresholds cover 1/5/10/over-budget turns", function()
    local function build(turns, content)
      local messages = { message("user", "initial") }
      local records = {}
      local state = { tool_calls = {}, failures = {}, decisions = {}, evidence = {}, risks = {}, next_actions = {} }
      for index = 1, turns do
        local assistant = message("assistant", content or ("turn-" .. index))
        local tool = {
          role = "tool",
          tool_call_id = "call-" .. index,
          content = "observed-" .. index,
        }
        messages[#messages + 1] = assistant
        messages[#messages + 1] = tool
        records[#records + 1] = {
          messages = { assistant, tool },
          response = { content = assistant.content },
          tools = {},
        }
      end
      return messages, records, state
    end

    local messages, records, state = build(1)
    local unchanged, ref = WheelRunner.compact_history(messages, records, state, { task_id = "T-1" })
    assert(unchanged == messages and ref == nil, "one turn must not compact")

    messages, records, state = build(5)
    local five_messages, five_ref = WheelRunner.compact_history(messages, records, state, { task_id = "T-5" })
    assert(five_ref == nil and five_messages == messages, "five turns remain below the turn bound")

    messages, records, state = build(10)
    local ten_messages, ten_ref = WheelRunner.compact_history(messages, records, state, { task_id = "T-10" })
    assert(ten_ref.turns == 10 and #ten_messages < #messages, "ten turns must compact")

    messages, records, state = build(1, string.rep("x", WheelRunner.MAX_HISTORY_BYTES))
    local over_messages, over_ref = WheelRunner.compact_history(messages, records, state, { task_id = "T-over" })
    local saw_context_ref = false
    for _, item in ipairs(over_messages) do
      if item.content and item.content:find("ContextRef", 1, true) then saw_context_ref = true end
    end
    assert(over_ref ~= nil and saw_context_ref, "over-budget history must compact")
  end)

  run_test("WheelRunner history: tool calls and failures survive compaction", function()
    local messages = { message("user", "start") }
    local records = {}
    local state = { tool_calls = {}, failures = {}, decisions = {}, evidence = {}, risks = {}, next_actions = {} }
    for index = 1, 10 do
      local call = { id = "call-" .. index, name = "inspect" }
      local assistant = { role = "assistant", content = "call", tool_calls = { call } }
      local outcome = {
        tool = "inspect",
        success = index ~= 1,
        exit_code = index == 1 and 2 or 0,
        stderr = index == 1 and "failure evidence" or "",
      }
      local tool = { role = "tool", tool_call_id = call.id, content = "result" }
      records[#records + 1] = {
        messages = { assistant, tool },
        response = { content = "evidence" },
        tools = { { call = call, outcome = outcome } },
      }
      messages[#messages + 1] = assistant
      messages[#messages + 1] = tool
    end
    local compacted = assert(WheelRunner.compact_history(messages, records, state, { task_id = "T-recovery" }))
    assert(state.tool_calls[#state.tool_calls] == "inspect:call-10", "the newest tool call identity must be retained")
    assert(state.failures[1]:find("failure evidence", 1, true), "failure evidence must be retained")
    local context_ref_content
    for _, item in ipairs(compacted) do
      if item.content and item.content:find("ContextRef", 1, true) then context_ref_content = item.content end
    end
    assert(context_ref_content and context_ref_content:find("failures", 1, true),
      "ContextRef must include structured failures")
    assert(compacted[#compacted].tool_call_id == "call-10", "recent complete turns must remain whole")
  end)

  run_test("WheelRunner history: ContextRef stays bounded and persists a checkpoint", function()
    local WheelContext = require("wheel.context")
    local context = WheelContext.new()
    local messages = { message("user", "start") }
    local records = {}
    local state = { tool_calls = {}, failures = {}, decisions = {}, evidence = {}, risks = {}, next_actions = {} }
    for index = 1, 10 do
      local assistant = message("assistant", "turn " .. index)
      records[index] = {
        messages = { assistant },
        response = {
          content = string.rep("evidence-" .. index, WheelRunner.MAX_EVIDENCE_BYTES),
          decisions = { string.rep("decision-" .. index, WheelRunner.MAX_STATE_FIELD_BYTES) },
          risks = { string.rep("hazard-" .. index, WheelRunner.MAX_STATE_FIELD_BYTES) },
          next_actions = { string.rep("action-" .. index, WheelRunner.MAX_STATE_FIELD_BYTES) },
        },
        tools = {},
      }
      messages[#messages + 1] = assistant
    end

    local compacted, context_ref = WheelRunner.compact_history(messages, records, state, {
      context = context,
      task_id = "T-bounded-ref",
      author = "test",
    })
    local slot = context:get_slot("tasks/T-bounded-ref/context_ref")
    assert(slot.found, "compaction must persist ContextRef in WheelContext")
    assert(#slot.content <= WheelRunner.MAX_CONTEXT_REF_BYTES, "persisted ContextRef must stay within its byte bound")
    assert(context_ref.bytes == #slot.content, "ContextRef byte metadata must match persisted content")
    assert(context_ref.commit_hash ~= nil, "persisted ContextRef must be checkpointed")
    assert(#compacted < #messages, "compaction must replace older messages")
  end)

  run_test("WheelRunner history: canonical ContextRefs reject self-consistent malformed bodies", function()
    local Context = require("wheel.context")
    local Kernel = require("wheel.kernel")
    local Team = require("wheel.team")
    local context = Context.new()
    local team = Team.new({ kernel = Kernel.new_mock(), context = context })
    local _, ref = WheelRunner.compact_history({}, {}, nil, {
      context = context, task_id = "CANONICAL-REF", force = true,
    })
    local valid = context:get_slot("tasks/CANONICAL-REF/context_ref").content
    assert(WheelRunner.validate_context_ref(valid, Context.compute_hash))
    assert(team:_valid_context_reference(ref.commit_hash, "CANONICAL-REF", true))
    -- Recompute both length and digest after each forgery: rejecting only bad
    -- hashes would not reject these syntactically invalid, immutable documents.
    local function reseal(content)
      for _ = 1, 4 do
        content = content:gsub("\nbytes=%d+", "\nbytes=" .. tostring(#content), 1)
      end
      local body = content:gsub("\nbody_hash=[0-9a-f]+\n", "\n", 1)
      return (content:gsub("\nbody_hash=[0-9a-f]+\n",
        "\nbody_hash=" .. Context.compute_hash(body) .. "\n", 1))
    end
    local variants = {
      (valid:gsub("\n%[tool_calls%].*", "\nINVALID BODY")),
      (valid:gsub("\n%[failures%]", "")),
      (valid:gsub("\n%[failures%]", "\n[failures]\n[failures]")),
      (valid:gsub("\n%[failures%]", "\n[UNKNOWN]")),
      (valid:gsub("\n%[tool_calls%]\n%[failures%]", "\n[failures]\n[tool_calls]")),
      (valid:gsub("\nturns=0", "\nturns=0\nturns=0")),
      (valid:gsub("\nturns=0", "\nturns=00")),
      (valid:gsub("\nturns=0", "\nturns=9007199254740992")),
      (valid:gsub("\nturns=0", "\nturns=" .. string.rep("9", 400))),
      (valid:gsub("\nturns=0", "\nturns=nan")),
      (valid:gsub("\nturns=0", "\nturns=-1")),
      (valid:gsub("\nturns=0", "\nturns=1.5")),
      (valid:gsub("\n%[decisions%]", "\n[decisions]\n- " .. string.rep("x", WheelRunner.MAX_STATE_FIELD_BYTES + 1))),
      (valid:gsub("\n%[evidence%]", "\n[evidence]" .. string.rep("\n- item", WheelRunner.MAX_EVIDENCE_ITEMS + 1))),
      (valid:gsub("\n%[risks%]", "\n[risks]\n- " .. string.rep("x", WheelRunner.MAX_CONTEXT_REF_BYTES))),
      valid .. "\n[UNKNOWN]",
      valid .. "\n",
      (valid:gsub("ContextRef v1", "ContextRef v2", 1)),
      (valid:gsub("\n%[next_actions%]", "\n[next_actions]\n- \\x41")),
    }
    for index, content in ipairs(variants) do
      local malformed = reseal(content)
      assert(context:put_slot("tasks/CANONICAL-REF/context_ref", malformed).success)
      local commit = context:commit_checkpoint({ task_id = "CANONICAL-REF" })
      assert(not WheelRunner.validate_context_ref(malformed, Context.compute_hash), "variant " .. index)
      assert(not team:_valid_context_reference(commit.hash, "CANONICAL-REF", true), "stored variant " .. index)
    end
    local invalid_bytes = valid:gsub("\nbytes=%d+", "\nbytes=0", 1)
    assert(not WheelRunner.validate_context_ref(invalid_bytes, Context.compute_hash))
    local state = { decisions = { "[failures]\nturns=99\\x00" } }
    local _, escaped = WheelRunner.compact_history({}, {}, state, {
      context = context, task_id = "CANONICAL-REF", force = true,
    })
    assert(escaped and team:_valid_context_reference(escaped.commit_hash, "CANONICAL-REF", true),
      "reserved syntax inside a state value must round-trip as escaped data")
    local largest = reseal(valid:gsub("\nturns=0", "\nturns=" .. string.format("%.0f", WheelRunner.MAX_CONTEXT_REF_TURNS)))
    assert(WheelRunner.validate_context_ref(largest, Context.compute_hash), "exact finite turn ceiling must be valid")
  end)

  run_test("WheelRunner history: ContextRef byte ceiling includes all final digest and header bytes", function()
    local Context = require("wheel.context")
    local fields = { "tool_calls", "failures", "decisions", "evidence", "risks", "next_actions" }
    local function compact(state)
      local context = Context.new()
      local _, ref = WheelRunner.compact_history({}, {}, state, {
        context = context, task_id = "EXACT-CEILING", force = true,
      })
      assert(ref)
      local content = context:get_slot("tasks/EXACT-CEILING/context_ref").content
      assert(ref.bytes == #content and #content <= WheelRunner.MAX_CONTEXT_REF_BYTES)
      assert(WheelRunner.validate_context_ref(content, Context.compute_hash))
      return content
    end
    local empty = compact({})
    local state, remaining = {}, WheelRunner.MAX_CONTEXT_REF_BYTES - #empty
      - (#tostring(WheelRunner.MAX_CONTEXT_REF_BYTES) - #tostring(#empty)) - #"\n[state truncated]"
    for _, field in ipairs(fields) do
      state[field] = {}
      for _ = 1, WheelRunner.MAX_EVIDENCE_ITEMS do
        local bytes = math.min(WheelRunner.MAX_STATE_FIELD_BYTES, remaining - 3)
        if bytes < 1 then break end
        state[field][#state[field] + 1] = string.rep("x", bytes)
        remaining = remaining - bytes - 3
      end
    end
    assert(remaining == 0, "boundary fixture must consume the exact value budget")
    state.next_actions[#state.next_actions + 1] = string.rep("y", WheelRunner.MAX_STATE_FIELD_BYTES)
    local first, second = compact(state), compact(state)
    assert(first == second, "equal bounded input must serialize deterministically")
    assert(#first == WheelRunner.MAX_CONTEXT_REF_BYTES, "final ref must exercise the exact named byte ceiling")
    assert(first:sub(-#"[state truncated]") == "[state truncated]")
    local reported = { tool_calls = {}, failures = {} }
    for index = 1, WheelRunner.MAX_EVIDENCE_ITEMS do
      reported.tool_calls[index] = string.rep("t", WheelRunner.MAX_STATE_FIELD_BYTES)
    end
    for index, length in ipairs({ 1024, 1024, 1024, 750 }) do
      reported.failures[index] = string.rep("f", length)
    end
    assert(compact(reported) == compact(reported), "the reported near-limit input must remain bounded and deterministic")
  end)

  run_test("WheelRunner history: retained turn window resets compaction counter", function()
    local messages = { message("user", "start") }
    local records = {}
    local state = { tool_calls = {}, failures = {}, decisions = {}, evidence = {}, risks = {}, next_actions = {} }
    for index = 1, WheelRunner.MAX_HISTORY_TURNS do
      local assistant = message("assistant", "turn " .. index)
      local tool = message("tool", "observation " .. index)
      records[index] = { messages = { assistant, tool }, response = {}, tools = {} }
      messages[#messages + 1] = assistant
      messages[#messages + 1] = tool
    end

    local compacted, first_ref, retained = WheelRunner.compact_history(messages, records, state, { task_id = "T-window" })
    assert(first_ref and #retained == WheelRunner.RETAINED_TURNS)
    local unchanged, next_ref = WheelRunner.compact_history(compacted, retained, state, { task_id = "T-window" })
    assert(unchanged == compacted and next_ref == nil,
      "retained turns must not trigger another compaction immediately")
  end)

  run_test("WheelRunner history: stable prefix survives tail-only compaction", function()
    local first = { message("system", "stable prefix bytes"), message("user", "one") }
    local second = { message("system", "stable prefix bytes"), message("user", "two") }
    local records = { { messages = { first[2] }, response = { content = "one" }, tools = {} } }
    local state = { tool_calls = {}, failures = {}, decisions = {}, evidence = {}, risks = {}, next_actions = {} }
    local compacted = WheelRunner.compact_history(second, records, state, { task_id = "T-prefix", force = true })
    assert(first[1].content == second[1].content, "system prefix bytes must not change")
    assert(compacted[1].role == "system", "ContextRef compaction must preserve the stable prefix")
  end)

  run_test("WheelRunner history: persistence failures preserve the original messages", function()
    local messages = { message("user", "original") }
    local records = {
      { messages = { message("assistant", "turn") }, response = { content = "evidence" }, tools = {} },
    }
    local state = { tool_calls = {}, failures = {}, decisions = {}, evidence = {}, risks = {}, next_actions = {} }
    local put_calls = 0
    local commit_calls = 0
    local put_failed = {
      put_slot = function()
        put_calls = put_calls + 1
        return nil, { error = "storage_unavailable" }
      end,
      commit_checkpoint = function()
        commit_calls = commit_calls + 1
        return { hash = "unexpected" }
      end,
    }
    local retained_messages, ref, _, put_error = WheelRunner.compact_history(messages, records, state, {
      context = put_failed,
      task_id = "T-put-failure",
      force = true,
    })
    assert(retained_messages == messages, "put_slot failure must preserve the original message table")
    assert(ref == nil and put_error.code == "E_CONTEXT_PERSISTENCE_FAILED",
      "put_slot failure must return the static typed persistence error")
    assert(put_calls == 1 and commit_calls == 0, "checkpoint must not run after put_slot failure")

    local checkpoint_failed = {
      put_slot = function()
        return { success = true }
      end,
      commit_checkpoint = function()
        commit_calls = commit_calls + 1
        return nil, { error = "checkpoint_unavailable" }
      end,
    }
    retained_messages, ref, _, put_error = WheelRunner.compact_history(messages, records, state, {
      context = checkpoint_failed,
      task_id = "T-checkpoint-failure",
      force = true,
    })
    assert(retained_messages == messages, "checkpoint failure must preserve the original message table")
    assert(ref == nil and put_error.code == "E_CONTEXT_PERSISTENCE_FAILED",
      "checkpoint failure must return the static typed persistence error")
    assert(commit_calls == 1, "checkpoint must be attempted after a successful slot write")
  end)

  run_test("WheelRunner history: persisted state is redacted and extracts rationale records", function()
    local WheelContext = require("wheel.context")
    local context = WheelContext.new()
    local messages = { message("user", "start") }
    local records = {
      {
        messages = { message("assistant", "turn") },
        response = { content = "sampled evidence" },
        rationale = {
          decision = "keep the bounded path",
          risk = "model_content_api_key=MODEL_CONTENT_SENTINEL",
          next_action = "run the regression",
          evidence = { "observed bounded state" },
        },
        tools = {},
      },
    }
    local state = { tool_calls = {}, failures = {}, decisions = {}, evidence = {}, risks = {}, next_actions = {} }
    local compacted, context_ref = WheelRunner.compact_history(messages, records, state, {
      context = context,
      task_id = "T-redacted-state",
      author = "test",
      force = true,
    })
    local slot = context:get_slot("tasks/T-redacted-state/context_ref")
    assert(compacted ~= messages and context_ref.commit_hash, "successful persistence must compact and checkpoint")
    assert(slot.found and not slot.content:find("MODEL_CONTENT_SENTINEL", 1, true),
      "ContextRef slots must not contain raw model content")
    assert(slot.content:find("keep the bounded path", 1, true),
      "bounded rationale decisions must be persisted")
    assert(slot.content:find("model_content_api_key", 1, true),
      "bounded rationale risks must be persisted")
    assert(slot.content:find("run the regression", 1, true),
      "bounded rationale next actions must be persisted")
    local checkpoint = context:get_commit(context_ref.commit_hash)
    local rationale = checkpoint and checkpoint.rationale or {}
    assert(not tostring(rationale):find("MODEL_CONTENT_SENTINEL", 1, true),
      "checkpoint rationale must not contain raw model content")
  end)

  run_test("WheelRunner history: equal-size histories receive distinct ContextRefs", function()
    local function compact(content)
      local messages = { message("user", "start") }
      local assistant = message("assistant", content)
      local records = { { messages = { assistant }, response = { content = content }, tools = {} } }
      local state = { tool_calls = {}, failures = {}, decisions = {}, evidence = {}, risks = {}, next_actions = {} }
      return WheelRunner.compact_history(messages, records, state, { task_id = "T-collision", force = true })
    end
    local _, first = compact("same-size-A")
    local _, second = compact("same-size-B")
    assert(#"same-size-A" == #"same-size-B", "the collision fixture must use equal-size content")
    assert(first.id ~= second.id, "ContextRef IDs must include canonical history content")
  end)

  run_test("WheelRunner history: provider requests bound nested arguments and retained messages", function()
    local huge = string.rep("nested-content", 2000)
    local request = {
      model = string.rep("model", 1000),
      messages = {},
      tools = { { type = "function", ["function"] = { name = "inspect", parameters = { huge = huge } } } },
      thinking = { enabled = true, details = { huge = huge } },
      max_completion_tokens = 128,
    }
    for index = 1, 30 do
      request.messages[#request.messages + 1] = {
        role = index % 2 == 0 and "assistant" or "user",
        content = huge,
      }
    end
    request.messages[#request.messages + 1] = {
      role = "assistant",
      content = huge,
      tool_calls = {
        { id = "call-1", name = "inspect", arguments = { nested = { value = huge } } },
      },
    }
    local bounded = WheelRunner.bound_provider_request(request)
    local provider = require("wheel.provider")
    local encoded = assert(provider.JSON.encode(bounded))
    assert(#encoded <= WheelRunner.MAX_REQUEST_BYTES, "provider request must stay within the exact byte bound")
    assert(#bounded.messages <= WheelRunner.MAX_REQUEST_MESSAGES, "provider message count must stay bounded")
    local last = bounded.messages[#bounded.messages]
    if last and last.tool_calls then
      local args = assert(provider.JSON.encode(last.tool_calls[1].arguments))
      assert(#args <= WheelRunner.MAX_REQUEST_ARGUMENT_BYTES,
        "nested tool-call arguments must stay within their byte bound")
    end
    for _, retained in ipairs(bounded.messages) do
      assert(#(retained.content or "") <= WheelRunner.MAX_REQUEST_MESSAGE_BYTES,
        "retained message content must stay within its node bound")
    end
  end)

  run_test("WheelRunner history: retained state keeps the newest items", function()
    local state = { tool_calls = {}, failures = {}, decisions = {}, evidence = {}, risks = {}, next_actions = {} }
    for index = 1, WheelRunner.MAX_EVIDENCE_ITEMS + 4 do
      WheelRunner.compact_history(
        { message("user", "start") },
        { {
          messages = { message("assistant", "turn " .. index) },
          response = { content = "evidence-" .. index },
          rationale = {
            decision = "decision-" .. index,
            risk = "hazard-" .. index,
            next_action = "next-action-" .. index,
          },
          tools = {},
        } },
        state,
        { task_id = "T-newest", force = true }
      )
    end
    local function contains(list, text)
      for _, item in ipairs(list) do
        if item == text or (type(item) == "string" and item:find(text, 1, true)) then return true end
      end
      return false
    end
    local function contains_exact(list, text)
      for _, item in ipairs(list) do
        if item == text then return true end
      end
      return false
    end
    local latest = WheelRunner.MAX_EVIDENCE_ITEMS + 4
    assert(contains(state.decisions, "decision-" .. latest), "newest decision must survive the bound")
    assert(contains(state.risks, "hazard-" .. latest), "newest hazard must survive the bound")
    assert(contains(state.next_actions, "next-action-" .. latest), "newest action must survive the bound")
    assert(not contains_exact(state.decisions, "decision-1"), "oldest decision must be dropped once full")
  end)

  run_test("WheelRunner history: the original task message survives truncation and compaction", function()
    local task_prompt = "TASK-PINNED-MARKER " .. string.rep("description ", 340)
    local messages = { message("user", task_prompt), message("system", "stable prefix") }
    for index = 1, 20 do
      messages[#messages + 1] = message("assistant", "answer-" .. index)
    end
    local compacted = WheelRunner.compact_history(messages, {
      { messages = { message("assistant", "turn") }, response = { content = "evidence" }, tools = {} },
    }, { tool_calls = {}, failures = {}, decisions = {}, evidence = {}, risks = {}, next_actions = {} },
      { task_id = "T-pinned", force = true })
    local kept_task = false
    for _, item in ipairs(compacted) do
      if item.role == "user" and item.content and item.content:find("TASK-PINNED-MARKER", 1, true) then
        kept_task = true
      end
    end
    assert(kept_task, "compaction must not drop a 4 KB task description")

    local request = { model = "test-model", messages = { message("system", "stable prefix") }, tools = {} }
    request.messages[#request.messages + 1] = message("user", task_prompt)
    for index = 1, 30 do
      request.messages[#request.messages + 1] = message("assistant", "answer-" .. index)
    end
    local bounded = WheelRunner.bound_provider_request(request)
    local pinned = false
    for _, item in ipairs(bounded.messages) do
      if item.content and item.content:find("TASK-PINNED-MARKER", 1, true) then pinned = true end
    end
    assert(pinned, "the original task message must remain pinned in a bounded request")
  end)

  run_test("WheelRunner history: action records never re-persist raw tool output", function()
    local WheelProvider = require("wheel.provider")
    local WheelAction = require("wheel.action")
    local sentinel = "RAW_SECRET_SENTINEL"
    local raw = sentinel .. string.rep("x", WheelRunner.MAX_REQUEST_MESSAGE_BYTES)
    local blobs = {}
    local recorded = {}
    local provider = WheelProvider.MockProvider.new({ responses = {
      { content = "", tool_calls = { { id = "call-1", name = "inspect", arguments = { path = "a" } } } },
      { content = "done", tool_calls = {} },
    } })
    local agent = {
      name = "raw-output-agent",
      role = "coding",
      model_profile = { model = "test-model" },
      execute_tool = function(_, name)
        return {
          tool = name,
          success = true,
          exit_code = 0,
          duration_ms = 1,
          stdout = raw,
          stdout_preview = "bounded preview",
          stdout_bytes = #raw,
          stderr = "",
          stderr_bytes = 0,
          format_observation = function() return "bounded observation" end,
        }
      end,
      kernel = {
        set_active_task = function() end,
        commit_checkpoint = function() return { hash = "checkpoint" } end,
        record_action = function(_, payload) recorded[#recorded + 1] = payload end,
      },
    }
    local result = WheelRunner.run_task(agent, {
      id = "T-raw-output", title = "raw output", description = "bounded action", priority = 1,
    }, { provider = provider, max_turns = 2, commit_checkpoints = false })
    assert(result.success == true, "the scripted runner turn must complete: " .. tostring(result.error))
    assert(#recorded == 1, "the tool turn must record exactly one action")
    local payload = recorded[1]
    assert(payload.stdout == nil and payload.raw_stdout == nil,
      "raw stdout must not be handed to the action record")
    assert(payload.stderr == nil and payload.raw_stderr == nil,
      "raw stderr must not be handed to the action record")
    local normalized = WheelAction.normalize(payload, function(hash, content)
      blobs[#blobs + 1] = content
    end)
    assert(normalized.blob_hash == nil or #blobs == 0,
      "the preview-only runner path must not spill a full payload")
    for _, content in ipairs(blobs) do
      assert(not content:find(sentinel, 1, true), "raw tool output must never reach an action blob")
    end
  end)

  run_test("WheelRunner history: request truncation never splits tool call groups", function()
    local request = { model = "test-model", messages = {}, tools = {} }
    request.messages[#request.messages + 1] = message("system", "stable prefix")
    for index = 1, 20 do
      request.messages[#request.messages + 1] = message("user", "prompt-" .. index)
      request.messages[#request.messages + 1] = message("assistant", "answer-" .. index)
      request.messages[#request.messages + 1] = {
        role = "assistant",
        content = "",
        tool_calls = { { id = "call-" .. index, name = "inspect", arguments = {} } },
      }
      request.messages[#request.messages + 1] = {
        role = "tool", tool_call_id = "call-" .. index, content = "observation-" .. index,
      }
    end
    -- A partial group (two calls, one observation) must never be admitted.
    request.messages[#request.messages + 1] = {
      role = "assistant",
      content = "",
      tool_calls = {
        { id = "partial-a", name = "inspect", arguments = {} },
        { id = "partial-b", name = "inspect", arguments = {} },
      },
    }
    request.messages[#request.messages + 1] = {
      role = "tool", tool_call_id = "partial-b", content = "only-one-result",
    }
    local bounded = WheelRunner.bound_provider_request(request)
    local open_calls = {}
    for _, item in ipairs(bounded.messages) do
      if item.role == "assistant" and item.tool_calls then
        for _, call in ipairs(item.tool_calls) do open_calls[call.id] = (open_calls[call.id] or 0) + 1 end
      elseif item.role == "tool" then
        assert(open_calls[item.tool_call_id] and open_calls[item.tool_call_id] > 0,
          "a tool observation must never appear without its assistant tool call")
        open_calls[item.tool_call_id] = open_calls[item.tool_call_id] - 1
      end
    end
    for id, count in pairs(open_calls) do
      assert(count == 0, "assistant tool call " .. tostring(id) .. " must keep all observations")
    end
    for _, item in ipairs(bounded.messages) do
      assert(not (item.role == "tool" and item.content == "only-one-result"),
        "a partial tool-call group must be dropped whole")
    end
  end)

  run_test("WheelRunner history: ContextRef seeds bound hostile wide and deep arguments", function()
    local function compact(seed)
      local deep = { value = seed }
      for _ = 1, 80 do deep = { nested = deep } end
      local wide = {}
      for index = 1, 600 do wide["key-" .. index] = string.rep(seed, 4) end
      local messages = { message("user", "start") }
      local call = { id = "call-deep", name = "inspect", arguments = { deep = deep, wide = wide } }
      local assistant = { role = "assistant", content = "call", tool_calls = { call } }
      local records = { { messages = { assistant }, rationale = { decision = seed }, tools = {} } }
      local state = { tool_calls = {}, failures = {}, decisions = {}, evidence = {}, risks = {}, next_actions = {} }
      return WheelRunner.compact_history(messages, records, state, { task_id = "T-hostile-seed", force = true })
    end
    local compacted, first = compact("seed-A")
    local _, second = compact("seed-B")
    assert(first and first.id and #first.id > 0, "hostile arguments must still produce a ContextRef")
    assert(compacted and compacted[#compacted].content ~= nil, "compaction must complete with a ContextRef message")
    assert(first.id ~= second.id, "bounded seeds must keep distinct identities for distinct histories")
  end)
end
