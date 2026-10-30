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
    assert(state.tool_calls[1] == "inspect:call-1", "tool call identity must be retained")
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
          risks = { string.rep("risk-" .. index, WheelRunner.MAX_STATE_FIELD_BYTES) },
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
        messages = { message("assistant", "Decision: keep the bounded path") },
        response = {
          content = "Decision: keep the bounded path\nRisk: model_content_api_key=MODEL_CONTENT_SENTINEL\nNext-Action: run the regression",
          thinking_content = "Risk: inspect provider limits",
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
    assert(slot.content:find("decisions", 1, true), "bounded rationale decisions must be persisted")
    assert(slot.content:find("risks", 1, true), "bounded rationale risks must be persisted")
    assert(slot.content:find("next_actions", 1, true), "bounded rationale next actions must be persisted")
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
end
