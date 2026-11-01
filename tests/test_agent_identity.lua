-- Agent identity, RoleBinding policy generations, fork lineage, and runtime
-- authorization tests (CTX-0046 / wheel#115).
--
-- These tests keep identity, RoleBinding, Session, Panel, and Context separate:
-- authority is read from the binding's capability state, role transitions issue
-- a new policy generation plus checkpoint boundary, and forks carry references
-- to immutable Context commits instead of copied transcripts.

local WheelAgent = require("wheel.agent")
local WheelContext = require("wheel.context")
local WheelKernel = require("wheel.kernel")
local WheelLifecycle = require("wheel.lifecycle")
local WheelTeam = require("wheel.team")

local function fixed_context(kernel)
  local context = WheelContext.new({ kernel = kernel })
  assert(context:put_slot("workspace/project", "Wheel"))
  return context
end

local function checkpoint(context, message, timestamp_ms)
  return assert(context:commit_checkpoint({
    author = "fixture",
    message = message,
    timestamp_ms = timestamp_ms or 1700000000000,
  }))
end

local function is_hex_hash(value)
  return type(value) == "string" and #value == 64 and value:match("^[0-9a-f]+$") ~= nil
end

return function(run_test)
  run_test("Agent identity: RoleBinding is separate from Agent identity and roles bound capabilities", function()
    local agent = WheelAgent.new({
      name = "identity-agent",
      role = WheelAgent.Role.CODING,
      kernel = WheelKernel.new_mock(),
    })
    assert(agent.agent_id == "identity-agent")
    assert(agent.role_binding.role == WheelAgent.Role.CODING)
    assert(agent.role_binding.policy_generation == 1)
    assert(agent.role_binding.binding_id ~= nil)
    assert(agent:has_capability(WheelAgent.Capability.MODIFY))
    assert(agent:has_capability(WheelAgent.Capability.EXECUTE))
    assert(not agent:has_capability(WheelAgent.Capability.ORCHESTRATE))

    -- Explicit capability lists may narrow the role matrix but never widen it.
    local narrowed = WheelAgent.new({
      name = "narrowed-agent",
      role = WheelAgent.Role.CODING,
      capabilities = { WheelAgent.Capability.INSPECT },
      kernel = WheelKernel.new_mock(),
    })
    assert(not narrowed:has_capability(WheelAgent.Capability.MODIFY))
    local allowed, reason = narrowed:is_tool_allowed("write_file")
    assert(allowed == false)
    assert(reason:find("lacks 'modify' capability", 1, true) ~= nil)

    local widened, widen_err = pcall(WheelAgent.new, {
      name = "widened-agent",
      role = WheelAgent.Role.REVIEWER,
      capabilities = { WheelAgent.Capability.MODIFY },
      kernel = WheelKernel.new_mock(),
    })
    assert(widened == false)
    assert(tostring(widen_err):find("may not hold capability", 1, true) ~= nil)

    -- The stable Agent identity and current RoleBinding cannot be rewritten in place.
    assert(not pcall(function() agent.agent_id = "rewritten" end))
    assert(not pcall(function()
      agent.role_binding = {
        role = WheelAgent.Role.CODING,
        binding_id = "forged-binding",
        policy_generation = 9,
        capabilities = { "inspect", "verify", "modify", "execute" },
      }
    end))
    local exposed_binding = agent.role_binding
    exposed_binding.capabilities = { "inspect", "verify", "modify", "execute", "orchestrate" }
    exposed_binding.policy_generation = 99
    assert(not agent:has_capability(WheelAgent.Capability.ORCHESTRATE),
      "mutating a returned RoleBinding must not widen authority")
    assert(agent.role_binding.policy_generation == 1,
      "mutating a returned RoleBinding must not change policy generation")
    assert(WheelAgent.ROLE_CAPABILITIES == nil,
      "the mutable authorization matrix must not be exported")
    assert(rawget(agent, "_authority") == nil and rawget(agent, "_identity") == nil,
      "authoritative identity and policy state must not be stored on the public Agent table")
    rawset(agent, "_authority", { role_binding = { role = WheelAgent.Role.CODING,
      capabilities = { "inspect", "verify", "modify", "execute" }, policy_generation = 99 } })
    rawset(agent, "_identity", { agent_id = "forged", lineage = nil })
    assert(agent:current_role() == WheelAgent.Role.CODING)
    assert(agent.agent_id == "identity-agent")
    assert(not agent:has_capability(WheelAgent.Capability.ORCHESTRATE),
      "shadow backing fields must not affect authoritative authorization")
    assert(agent.agent_id == "identity-agent")
    assert(agent.role_binding.policy_generation == 1)

    rawset(agent, "agent_id", "forged-agent-id")
    rawset(agent, "lineage", { forked_from_agent = "forged-parent" })
    rawset(agent, "policy_generation", 99)
    local authoritative_status = agent:status()
    assert(authoritative_status.agent_id == "identity-agent")
    assert(authoritative_status.policy_generation == 1)
    assert(authoritative_status.lineage.agent_id == "identity-agent")
    assert(authoritative_status.lineage.forked_from_agent == nil)
    assert(agent:context_reference().agent_id == "identity-agent")
  end)

  run_test("Agent identity: audited role transition preserves AgentId and never widens silently", function()
    local kernel = WheelKernel.new_mock()
    local context = fixed_context(kernel)
    local lifecycle = WheelLifecycle.new({ max_sessions_per_agent = 4 })
    local agent = WheelAgent.new({
      name = "transition-agent",
      role = WheelAgent.Role.CODING,
      kernel = kernel,
      context = context,
      lifecycle = lifecycle,
    })
    local stable_id = agent.agent_id
    checkpoint(context, "role baseline")
    assert(agent:create_runtime_session())
    assert(agent:activate_runtime_session())

    local narrowed, transition_err = agent:transition_role(WheelAgent.Role.REVIEWER, {
      reason = "independent verification assignment",
    })
    assert(narrowed, transition_err and transition_err.message or "role transition failed")
    assert(agent.agent_id == stable_id)
    assert(narrowed.role == WheelAgent.Role.REVIEWER)
    assert(narrowed.policy_generation == 2)
    assert(narrowed.widened == false and #narrowed.added_capabilities == 0)
    assert(is_hex_hash(narrowed.checkpoint))
    assert(agent.last_role_checkpoint == narrowed.checkpoint)
    assert(agent.role_binding.role == WheelAgent.Role.REVIEWER)
    assert(not agent:has_capability(WheelAgent.Capability.MODIFY))
    local denied, denial = agent:is_tool_allowed("write_file")
    assert(denied == false)
    assert(denial:find("read-only authority", 1, true) ~= nil)

    -- Widening back to a mutating role fails closed without explicit approval.
    local rejected, rejection = agent:transition_role(WheelAgent.Role.CODING, {
      reason = "resume implementation",
      binding_id = "forged-authority-binding",
    })
    assert(rejected == nil)
    assert(rejection.code == "E_ROLE_AUTHORITY")
    assert(agent.role_binding.role == WheelAgent.Role.REVIEWER)
    assert(agent.role_binding.policy_generation == 2)
    assert(agent.role_binding.binding_id ~= "forged-authority-binding")

    -- Explicit approval is audited with a new policy generation and checkpoint.
    local widened = assert(agent:transition_role(WheelAgent.Role.CODING, {
      reason = "approved return to implementation",
      approve_widening = true,
    }))
    assert(widened.widened == true)
    assert(widened.policy_generation == 3)
    assert(widened.added_capabilities[1] == WheelAgent.Capability.MODIFY)
    assert(agent:has_capability(WheelAgent.Capability.MODIFY))
    assert(widened.checkpoint ~= narrowed.checkpoint)

    -- A transition without a reason or checkpoint boundary fails closed.
    local no_reason, reason_err = agent:transition_role(WheelAgent.Role.REVIEWER, {})
    assert(no_reason == nil and reason_err.code == "E_ROLE_INVALID")
    local no_context = WheelAgent.new({
      name = "no-context-agent", role = WheelAgent.Role.CODING, kernel = kernel,
    })
    local no_checkpoint, checkpoint_err = no_context:transition_role(WheelAgent.Role.REVIEWER, {
      reason = "verification assignment",
    })
    assert(no_checkpoint == nil and checkpoint_err.code == "E_ROLE_CHECKPOINT")
    assert(no_context.role_binding.role == WheelAgent.Role.CODING)
    assert(no_context.role_binding.policy_generation == 1)

    local no_lifecycle_context = fixed_context(kernel)
    checkpoint(no_lifecycle_context, "role baseline without lifecycle")
    local no_lifecycle = WheelAgent.new({
      name = "no-lifecycle-agent", role = WheelAgent.Role.CODING,
      kernel = kernel, context = no_lifecycle_context,
    })
    local unaudited, audit_err = no_lifecycle:transition_role(WheelAgent.Role.REVIEWER, {
      reason = "must have an audit record",
    })
    assert(unaudited == nil and audit_err.code == "E_ROLE_AUDIT")
    assert(no_lifecycle.role_binding.role == WheelAgent.Role.CODING)
    assert(no_lifecycle.role_binding.policy_generation == 1)
  end)

  run_test("Agent identity: runtime authorization ignores prompt identity text", function()
    local agent = WheelAgent.new({
      name = "prompt-spoof-agent",
      role = WheelAgent.Role.REVIEWER,
      tools = { "read_file", "write_file", "run_command" },
      kernel = WheelKernel.new_mock(),
    })
    -- Simulate drifting/malicious identity text: the readable role projection is
    -- rewritten, but authorization must still follow the RoleBinding.
    agent.role = WheelAgent.Role.CODING
    local write_allowed, write_reason = agent:is_tool_allowed("write_file")
    assert(write_allowed == false)
    assert(write_reason:find("read-only authority", 1, true) ~= nil)
    local exec_allowed, exec_reason = agent:is_tool_allowed("run_command")
    assert(exec_allowed == false)
    assert(exec_reason:find("read-only authority", 1, true) ~= nil)
    local read_allowed = agent:is_tool_allowed("read_file")
    assert(read_allowed == true)
    assert(agent:current_role() == WheelAgent.Role.REVIEWER)

    -- A Commander binding can orchestrate but not modify code directly.
    local commander = WheelAgent.new({
      name = "commander-binding",
      role = WheelAgent.Role.COMMANDER,
      tools = { "read_file", "write_file" },
      kernel = WheelKernel.new_mock(),
    })
    assert(commander:has_capability(WheelAgent.Capability.ORCHESTRATE))
    assert(not commander:has_capability(WheelAgent.Capability.MODIFY))
    local commander_allowed, commander_reason = commander:is_tool_allowed("write_file")
    assert(commander_allowed == false)
    assert(commander_reason:find("lacks 'modify' capability", 1, true) ~= nil)
  end)

  run_test("Agent identity: rawset role binding cannot authorize plan decomposition", function()
    local kernel = WheelKernel.new_mock()
    local reviewer = WheelAgent.new({
      name = "rawset-plan-reviewer",
      role = WheelAgent.Role.REVIEWER,
      kernel = kernel,
    })
    rawset(reviewer, "role_binding", {
      role = WheelAgent.Role.COMMANDER,
      binding_id = "forged-commander-binding",
      policy_generation = 1,
      capabilities = { "inspect", "verify", "orchestrate" },
    })

    local decomposed, reason = pcall(function()
      reviewer:decompose_plan({ { id = "RAWSET-PLAN", title = "forged plan" } })
    end)
    assert(decomposed == false, "a rawset-forged Commander binding must not decompose plans")
    assert(tostring(reason):find("Only Commander role", 1, true) ~= nil)
    assert(reviewer:current_role() == WheelAgent.Role.REVIEWER)

    local review_result, review_reason = pcall(function()
      reviewer:review_task("RAWSET-PLAN", function() return true end)
    end)
    assert(review_result == false, "the missing task must keep review from proceeding")
    assert(tostring(review_reason):find("Task not found", 1, true) ~= nil,
      "role-gated review must use the authoritative Reviewer binding")
  end)

  run_test("Agent identity: runtime and provenance fields cannot cross agents", function()
    local kernel = WheelKernel.new_mock()
    local context = fixed_context(kernel)
    local lifecycle = WheelLifecycle.new({ max_sessions_per_agent = 4 })
    local first = WheelAgent.new({ name = "runtime-first", role = WheelAgent.Role.CODING,
      kernel = kernel, context = context, lifecycle = lifecycle })
    local second = WheelAgent.new({ name = "runtime-second", role = WheelAgent.Role.CODING,
      kernel = kernel, context = context, lifecycle = lifecycle })
    assert(first:create_runtime_session({ session_id = "runtime-first-session" }))
    assert(second:create_runtime_session({ session_id = "runtime-second-session" }))
    rawset(first, "session_id", "runtime-second-session")
    rawset(first, "policy_generation", 99)
    rawset(first, "last_role_checkpoint", "forged-checkpoint")
    rawset(first, "context_refs", { session_id = "runtime-second-session", branch = "forged" })
    assert(first:runtime_session_id() == "runtime-first-session")
    assert(first:context_reference().session_id == "runtime-first-session")
    assert(first:lineage_projection().policy_generation == 1)
    assert(first:lineage_projection().role_checkpoint == nil)
    assert(first:activate_runtime_session() ~= nil)
    assert(lifecycle:get_session("runtime-first-session").state == WheelLifecycle.AgentSessionState.ACTIVE)
    assert(lifecycle:get_session("runtime-second-session").state == WheelLifecycle.AgentSessionState.CREATED)
  end)

  run_test("Agent identity: exported read-only allowlist cannot authorize a new tool", function()
    local kernel = WheelKernel.new_mock()
    local agent = WheelAgent.new({ name = "allowlist-shadow", role = WheelAgent.Role.REVIEWER,
      tools = { "forged_read_tool" }, kernel = kernel })
    WheelAgent.READ_ONLY_TOOLS.forged_read_tool = true
    local allowed, reason = agent:is_tool_allowed("forged_read_tool")
    assert(allowed == false and reason:find("canonical read-only allowlist", 1, true) ~= nil)
  end)

  run_test("Agent identity: exported Capability mutations cannot grant unregistered mutation", function()
    local agent = WheelAgent.new({
      name = "capability-table-agent",
      role = WheelAgent.Role.REVIEWER,
      tools = { "unregistered_mutating_tool" },
      kernel = WheelKernel.new_mock(),
    })
    local exported = WheelAgent.Capability
    local original = {}
    for name, value in pairs(exported) do
      original[name] = value
      exported[name] = "inspect"
      local allowed, reason = agent:is_tool_allowed("unregistered_mutating_tool")
      assert(allowed == false, "mutating " .. name .. " must not grant mutation")
      assert(reason:find("read-only authority", 1, true) ~= nil,
        "denial must remain read-only after " .. name .. " mutation")
    end
    for name, value in pairs(original) do exported[name] = value end

    local replacement = WheelAgent.Capability
    WheelAgent.Capability = {
      INSPECT = "inspect",
      VERIFY = "inspect",
      ORCHESTRATE = "inspect",
      MODIFY = "inspect",
      EXECUTE = "inspect",
    }
    local allowed, reason = agent:is_tool_allowed("unregistered_mutating_tool")
    assert(allowed == false, "replacing Capability must not grant mutation")
    assert(reason:find("read-only authority", 1, true) ~= nil,
      "replacing Capability must preserve read-only denial")
    WheelAgent.Capability = replacement
  end)

  run_test("Agent identity: replacing role capability export cannot grant unregistered mutation", function()
    local original = WheelAgent.role_capabilities
    WheelAgent.role_capabilities = function()
      return { "inspect", "verify", "modify", "execute" }
    end

    local ok, reviewer = pcall(WheelAgent.new, {
      name = "replaced-role-capabilities-agent",
      role = WheelAgent.Role.REVIEWER,
      tools = { "unregistered_mutating_tool" },
      kernel = WheelKernel.new_mock(),
    })
    WheelAgent.role_capabilities = original

    assert(ok, "Reviewer construction must not depend on the compatibility export")
    assert(not reviewer:has_capability(WheelAgent.Capability.MODIFY))
    local allowed, reason = reviewer:is_tool_allowed("unregistered_mutating_tool")
    assert(allowed == false, "replacing role_capabilities must not grant mutation")
    assert(reason:find("read-only authority", 1, true) ~= nil,
      "unregistered mutation must remain denied after role_capabilities replacement")
  end)

  run_test("Agent identity: fork from an immutable ContextCommit keeps references only", function()
    local kernel = WheelKernel.new_mock()
    local context = fixed_context(kernel)
    local parent = WheelAgent.new({
      name = "fork-parent",
      role = WheelAgent.Role.CODING,
      kernel = kernel,
      context = context,
    })
    local base = checkpoint(context, "fork base", 1700000000000)
    assert(context:put_slot("workspace/project", "Wheel updated").success)
    local head = checkpoint(context, "fork head", 1700000001000)
    local lifecycle = WheelLifecycle.new({ max_sessions_per_agent = 4 })
    parent = WheelAgent.new({
      name = "fork-parent-runtime",
      role = WheelAgent.Role.CODING,
      kernel = kernel,
      context = context,
      lifecycle = lifecycle,
    })
    assert(parent:create_runtime_session({ session_id = "fork-parent-session" }))

    local child = assert(WheelAgent.fork_agent(parent, {
      name = "fork-child",
      role = WheelAgent.Role.REVIEWER,
      reason = "parallel independent verification",
      base_context_commit = base.hash,
    }))
    assert(child.agent_id ~= parent.agent_id)
    assert(child.lineage.forked_from_agent == parent.agent_id)
    assert(child.lineage.forked_from_session == "fork-parent-session")
    assert(child.lineage.base_context_commit == base.hash)
    assert(child.lineage.reason == "parallel independent verification")
    assert(child.context == parent.context, "fork shares the context engine by reference")
    assert(child.context_refs.base_context_commit == base.hash)
    assert(child.context_refs.slots == nil and child.context_refs.transcript == nil)
    assert(child.context_refs.session_id == "fork-parent-session")
    assert(child.panel_id ~= parent.panel_id)
    assert(child.policy_generation == 1)
    assert(child.role_binding.role == WheelAgent.Role.REVIEWER)
    assert(not child:has_capability(WheelAgent.Capability.MODIFY))

    local status = child:status()
    assert(status.agent_id == child.agent_id)
    assert(status.lineage.forked_from_agent == parent.agent_id)
    assert(status.lineage.base_context_commit == base.hash)
    assert(status.role_binding.policy_generation == 1)
    local reference = child:context_reference()
    assert(reference.base_context_commit == base.hash)
    assert(reference.head == head.hash)

    -- Forking without an immutable commit, or with the same identity, is refused.
    local missing, missing_err = WheelAgent.fork_agent(parent, {
      name = "fork-missing", reason = "invalid base", base_context_commit = string.rep("0", 64),
    })
    assert(missing == nil and missing_err.code == "E_FORK_CONTEXT")
    local duplicate, duplicate_err = WheelAgent.fork_agent(parent, {
      name = parent.name, reason = "duplicate identity", base_context_commit = base.hash,
    })
    assert(duplicate == nil and duplicate_err.code == "E_FORK_IDENTITY")

    -- A fork may not silently widen authority beyond the parent.
    local wide_parent = WheelAgent.new({
      name = "fork-reviewer-parent",
      role = WheelAgent.Role.REVIEWER,
      kernel = kernel,
      context = context,
    })
    local widened, widened_err = WheelAgent.fork_agent(wide_parent, {
      name = "fork-wide-child",
      role = WheelAgent.Role.CODING,
      reason = "attempted escalation",
      base_context_commit = base.hash,
    })
    assert(widened == nil and widened_err.code == "E_FORK_AUTHORITY")
    local approved, approved_err = WheelAgent.fork_agent(wide_parent, {
      name = "fork-wide-child",
      role = WheelAgent.Role.CODING,
      reason = "approved escalation",
      approve_widening = true,
      base_context_commit = base.hash,
    })
    assert(approved == nil and approved_err.code == "E_FORK_AUTHORITY",
      "approved widening without lifecycle audit must fail closed")

    local audited_lifecycle = WheelLifecycle.new({ max_sessions_per_agent = 4 })
    local audited_parent = WheelAgent.new({
      name = "audited-wide-parent",
      role = WheelAgent.Role.REVIEWER,
      kernel = kernel,
      context = context,
      lifecycle = audited_lifecycle,
    })
    assert(audited_parent:create_runtime_session({ session_id = "audited-wide-parent-session" }))
    local audited_child = assert(WheelAgent.fork_agent(audited_parent, {
      name = "audited-wide-child",
      role = WheelAgent.Role.CODING,
      reason = "approved audited escalation",
      approve_widening = true,
      base_context_commit = base.hash,
    }))
    assert(audited_child:runtime_session_id() ~= nil)
    local widening_event
    for _, event in ipairs(audited_lifecycle:events()) do
      if event.type == "agent_session.authority_widened" then widening_event = event end
    end
    assert(widening_event)
    assert(widening_event.parent_session_id == "audited-wide-parent-session")
    assert(widening_event.child_session_id == audited_child:runtime_session_id())
    assert(widening_event.parent_agent_id == audited_parent.agent_id)
    assert(widening_event.child_agent_id == audited_child.agent_id)
    assert(widening_event.capability_delta == "modify,execute")

    -- A public-field shadow must not make a read-only parent appear to hold
    -- capabilities that a fork would otherwise inherit.
    rawset(wide_parent, "role_binding", {
      role = WheelAgent.Role.COMMANDER,
      binding_id = "forged-commander-binding",
      policy_generation = 1,
      capabilities = { "inspect", "verify", "modify", "execute", "orchestrate" },
    })
    local shadow_widened, shadow_widened_err = WheelAgent.fork_agent(wide_parent, {
      name = "fork-shadow-wide-child",
      role = WheelAgent.Role.CODING,
      reason = "rawset authority inheritance attempt",
      base_context_commit = base.hash,
    })
    assert(shadow_widened == nil and shadow_widened_err.code == "E_FORK_AUTHORITY",
      "a rawset-forged parent binding must not authorize inherited fork capabilities")
    assert(wide_parent:current_role() == WheelAgent.Role.REVIEWER)
  end)

  run_test("Agent identity: forked agents run in independent Sessions and Panels", function()
    local kernel = WheelKernel.new_mock()
    local context = fixed_context(kernel)
    local lifecycle = WheelLifecycle.new({ max_sessions_per_agent = 4 })
    local team = WheelTeam.new({
      kernel = kernel,
      context = context,
      lifecycle = lifecycle,
    })
    local parent = team:spawn_agent({ name = "team-parent", role = WheelAgent.Role.CODING })
    local parent_session = assert(parent:create_runtime_session({ task_id = "TASK-PARENT" }))
    assert(parent:activate_runtime_session())
    local base = checkpoint(context, "team fork base")

    local child = assert(team:fork_agent("team-parent", {
      name = "team-child",
      role = WheelAgent.Role.REVIEWER,
      reason = "independent verification",
      base_context_commit = base.hash,
      task_id = "TASK-CHILD",
    }))
    assert(child.session_id ~= nil and child.session_id ~= parent.session_id)
    assert(child.panel_id ~= nil and child.panel_id ~= parent.panel_id)
    assert(child.agent_id ~= parent.agent_id)

    local child_session = assert(lifecycle:get_session(child.session_id))
    assert(child_session.agent_id == child.agent_id)
    assert(child_session.context_head == base.hash)
    assert(child_session.role_binding.role == WheelAgent.Role.REVIEWER)
    assert(child_session.role_binding.policy_generation == 1)
    assert(child_session.state == WheelLifecycle.AgentSessionState.ACTIVE)

    local sessions = lifecycle:list_sessions()
    local active = 0
    for _, session in ipairs(sessions) do
      if session.state == WheelLifecycle.AgentSessionState.ACTIVE then
        active = active + 1
        assert(session.agent_id ~= nil)
      end
    end
    assert(active == 2, "parent and fork must hold independent active sessions")

    -- Role transitions on the parent flow into the lifecycle audit trail
    -- without touching the forked child's binding.
    local transition = assert(team:transition_role("team-parent", WheelAgent.Role.REVIEWER, {
      reason = "hand off to verification",
    }))
    assert(transition.policy_generation == 2)
    local parent_after = assert(lifecycle:get_session(parent_session.session_id))
    assert(parent_after.role_binding.role == WheelAgent.Role.REVIEWER)
    assert(parent_after.role_binding.policy_generation == 2)
    assert(parent_after.checkpoint == transition.checkpoint)
    assert(parent.role_binding.policy_generation == 2)
    assert(child.role_binding.role == WheelAgent.Role.REVIEWER)
    assert(child.role_binding.policy_generation == 1)

    local saw_transition = false
    for _, event in ipairs(lifecycle:events(20)) do
      if event.type == "agent_session.role_transition"
        and event.session_id == parent_session.session_id then
        saw_transition = true
        assert(event.policy_generation == 2)
        assert(event.checkpoint == transition.checkpoint)
      end
    end
    assert(saw_transition, "role transition must be recorded in the lifecycle registry")

    local team_status = team:status()
    assert(team_status.total_agents == 2)
    local saw_child_lineage = false
    for _, summary in ipairs(team_status.agents) do
      if summary.agent_id == child.agent_id then
        saw_child_lineage = summary.lineage.base_context_commit == base.hash
          and summary.lineage.forked_from_agent == parent.agent_id
      end
    end
    assert(saw_child_lineage, "team status must expose fork lineage")
  end)

  run_test("Agent identity: checkpoint projections expose identity and lineage provenance", function()
    local kernel = WheelKernel.new_mock()
    local context = fixed_context(kernel)
    local parent = WheelAgent.new({
      name = "projection-parent",
      role = WheelAgent.Role.CODING,
      kernel = kernel,
      context = context,
    })
    local base = checkpoint(context, "projection base")
    local child = assert(WheelAgent.fork_agent(parent, {
      name = "projection-child",
      role = WheelAgent.Role.REVIEWER,
      reason = "projection lineage",
      base_context_commit = base.hash,
    }))
    local projection = assert(child:context_projection({
      base_commit = base.hash,
      current_commit = base.hash,
      role = WheelContext.Role.REVIEWER,
      task_id = "TASK-PROJECTION",
    }))
    assert(projection.identity.agent_id == child.agent_id)
    assert(projection.identity.role_binding.role == WheelAgent.Role.REVIEWER)
    assert(projection.identity.role_binding.policy_generation == 1)
    assert(projection.identity.lineage.forked_from_agent == parent.agent_id)
    assert(projection.identity.lineage.base_context_commit == base.hash)
    assert(projection.provenance.agent_id == child.agent_id)
    assert(projection.provenance.policy_generation == 1)

    local forged_identity, identity_err = child:context_projection({
      base_commit = base.hash,
      current_commit = base.hash,
      role = WheelContext.Role.REVIEWER,
      task_id = "TASK-PROJECTION",
      agent_id = parent.agent_id,
    })
    assert(forged_identity == nil and identity_err.code == "E_IDENTITY_PROJECTION")
    local forged_binding, binding_err = child:context_projection({
      base_commit = base.hash,
      current_commit = base.hash,
      role = WheelContext.Role.REVIEWER,
      task_id = "TASK-PROJECTION",
      role_binding = WheelAgent.binding_reference(parent.role_binding),
    })
    assert(forged_binding == nil and binding_err.code == "E_IDENTITY_PROJECTION")
    local forged_lineage, lineage_err = child:context_projection({
      base_commit = base.hash,
      current_commit = base.hash,
      role = WheelContext.Role.REVIEWER,
      task_id = "TASK-PROJECTION",
      lineage = {
        forked_from_agent = "forged-parent",
        forked_from_session = child.lineage.forked_from_session,
        base_context_commit = base.hash,
        reason = child.lineage.reason,
      },
    })
    assert(forged_lineage == nil and lineage_err.code == "E_IDENTITY_PROJECTION")

    local replay = assert(child:context_projection({
      base_commit = base.hash,
      current_commit = base.hash,
      role = WheelContext.Role.REVIEWER,
      task_id = "TASK-PROJECTION",
    }))
    assert(replay.canonical_bytes == projection.canonical_bytes)

    -- Identity provenance is validated as bounded plain data.
    local invalid, invalid_err = context:project({
      current_commit = base.hash,
      lineage = { forked_from_agent = "parent", base_context_commit = base.hash, transcript = "x" },
    })
    assert(invalid == nil and invalid_err.code == "E_PROJECTION_INVALID")
    local bad_generation, generation_err = context:project({
      current_commit = base.hash,
      role_binding = { role = "coding", policy_generation = 0 },
    })
    assert(bad_generation == nil and generation_err.code == "E_PROJECTION_INVALID")
  end)
end
