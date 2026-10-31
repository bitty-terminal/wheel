-- AgentSession and Headless Panel lifecycle tests.
-- The child invocation reloads the registry from disk and performs the
-- transition, exercising the same file-backed boundary used by a separate
-- Wheel process. No prompt, context, transcript, provider response, or tool
-- output is put in the lifecycle registry.

package.path = "./lua/?.lua;./lua/?/init.lua;" .. package.path

local WheelHost = require("wheel.host")
local Lifecycle = require("wheel.lifecycle")
local Session = require("wheel.session")
local WheelAgent = require("wheel.agent")
local WheelContext = require("wheel.context")
local WheelKernel = require("wheel.kernel")

local function success(status) return status == true or status == 0 end
local function interpreter()
  return os.getenv("WHEEL_LUA") or (WheelHost.proc.run_program("bash", {
    "scripts/test-gate.sh", "--print-selection",
  }).stdout or ""):gsub("%s+$", "")
end

local function shell_quote(value)
  return WheelHost.proc.shell_quote(value)
end

local script_path = type(arg) == "table" and arg[0] or "tests/test_lifecycle.lua"
local registry_path = type(arg) == "table" and arg[2] or nil

if arg[1] == "child" then
  local lifecycle = Lifecycle.new({ path = registry_path })
  local session = assert(lifecycle:resume_session("cross-session"))
  assert(session.state == Lifecycle.AgentSessionState.ACTIVE)
  assert(session.checkpoint == "cross-checkpoint")
  os.exit(0)
end
if arg[1] == "writer" then
  local life = Lifecycle.new({ path = registry_path })
  local value, err = life:create_panel({ panel_id = arg[3] })
  if not value then assert(err.code == "E_LIFECYCLE_LIMIT"); os.exit(3) end
  os.exit(0)
end
if arg[1] == "writer-race" then
  local path, barrier, name = arg[2], arg[3], arg[4]
  local life = Lifecycle.new({ path = path })
  assert(WheelHost.fs.create_private_file(barrier .. "/" .. name, "ready"))
  local peer = name == "race-a" and "race-b" or "race-a"
  local ready = false
  for _ = 1, 20000 do
    if WheelHost.fs.stat(barrier .. "/" .. peer).exists then ready = true; break end
  end
  if not ready then os.exit(5) end
  local value, err = life:create_panel({ panel_id = name })
  if not value then
    assert(err.code == "E_LIFECYCLE_CONFLICT" or err.code == "E_LIFECYCLE_BUSY")
    os.exit(4)
  end
  os.exit(0)
end
if arg[1] == "alternate-root" then
  for name in pairs(package.loaded) do
    if name:match("^wheel%.") or name:match("^lua%.wheel%.") then package.loaded[name] = nil end
  end
  package.path = "./?.lua;./?/init.lua"
  local alt = require("lua.wheel.lifecycle")
  assert(alt.new():create_panel({ panel_id = "alternate" }))
  os.exit(0)
end

local function run_test(name, fn)
  local ok, err = pcall(fn)
  if ok then
    print("[PASS] " .. name)
  else
    print("[FAIL] " .. name .. ": " .. tostring(err))
    os.exit(1)
  end
end

local root = os.tmpname()
os.remove(root)
assert(WheelHost.fs.mkdir_p(root) == true)
assert(WheelHost.fs.chmod(root, "700"))
local registry = root .. "/lifecycle.json"

local function cleanup()
  os.execute("rm -rf -- " .. shell_quote(root))
end

local ok, err = pcall(function()
  local function fixture()
    local life = Lifecycle.new({ max_sessions_per_agent = 3 })
    for _, id in ipairs({ "p1", "p2" }) do
      assert(life:create_panel({ panel_id = id }))
      assert(life:ready_panel(id))
    end
    for _, id in ipairs({ "s1", "s2" }) do
      assert(life:create_agent_session({ session_id = id, agent_id = id, panel_id = "p1" }))
    end
    return life
  end

  run_test("Lifecycle: controller cannot alias panels or bypass authority", function()
    local life = fixture()
    assert(life:activate_session("s1"))
    assert(not life:attach_session("s1", "p2"))
    assert(life:get_panel("p1").attached_session_id == "s1")
    assert(life:get_panel("p2").attached_session_id == nil)
    assert(life:detach_session("s1", { pause = true }))
    assert(not life:attach_session("s1", "p2"))
    assert(life:get_session("s1").panel_id == "p1")
    assert(life:resume_session("s1"))
    assert(life:end_session("s1"))
    assert(not life:attach_session("s1", "p1"))
    assert(not life:attach_session("s2", "p1", { mode = "typo" }))
    assert(life:create_panel({ panel_id = "owned", agent_id = "owner" }))
    assert(life:ready_panel("owned"))
    assert(not life:attach_session("s2", "owned"))
  end)

  run_test("Lifecycle: explicit transfer moves one controller atomically", function()
    local life = fixture()
    assert(life:activate_session("s1"))
    local moved = assert(life:transfer_session("s1", "p2"))
    assert(moved.panel_id == "p2" and moved.attachment_mode == Lifecycle.AttachMode.CONTROLLER)
    assert(life:get_panel("p1").attached_session_id == nil)
    assert(life:get_panel("p2").attached_session_id == "s1")
    assert(life:transfer_session("s1", "p1"))
    assert(life:get_panel("p1").attached_session_id == "s1")
    assert(life:get_panel("p2").attached_session_id == nil)
  end)

  run_test("Lifecycle: multiple task sessions require explicit agent policy", function()
    local restricted = Lifecycle.new({ max_sessions_per_agent = 2 })
    assert(restricted:create_panel({ panel_id = "policy-panel-a" }))
    assert(restricted:create_panel({ panel_id = "policy-panel-b" }))
    assert(restricted:ready_panel("policy-panel-a"))
    assert(restricted:ready_panel("policy-panel-b"))
    assert(restricted:create_agent_session({ session_id = "policy-session-a", agent_id = "policy-agent", task_id = "task-a", panel_id = "policy-panel-a" }))
    local denied, policy_error = restricted:create_agent_session({ session_id = "policy-session-b", agent_id = "policy-agent", task_id = "task-b", panel_id = "policy-panel-b" })
    assert(not denied and policy_error.code == "E_LIFECYCLE_POLICY")

    local allowed = Lifecycle.new({ max_sessions_per_agent = 2, allow_multiple_tasks = true })
    assert(allowed:create_panel({ panel_id = "multi-panel-a" }))
    assert(allowed:create_panel({ panel_id = "multi-panel-b" }))
    assert(allowed:ready_panel("multi-panel-a"))
    assert(allowed:ready_panel("multi-panel-b"))
    assert(allowed:create_agent_session({ session_id = "multi-session-a", agent_id = "multi-agent", task_id = "task-a", panel_id = "multi-panel-a" }))
    assert(allowed:create_agent_session({ session_id = "multi-session-b", agent_id = "multi-agent", task_id = "task-b", panel_id = "multi-panel-b" }))
  end)

  run_test("Lifecycle: persisted transfer and detach history remains valid", function()
    local path = root .. "/transfer-history.json"
    local life = Lifecycle.new({ path = path, max_sessions_per_agent = 2 })
    assert(life:create_panel({ panel_id = "history-p1" }))
    assert(life:ready_panel("history-p1"))
    assert(life:create_panel({ panel_id = "history-p2" }))
    assert(life:ready_panel("history-p2"))
    assert(life:create_agent_session({
      session_id = "history-session", agent_id = "history-agent", panel_id = "history-p1",
    }))
    assert(life:activate_session("history-session"))
    assert(life:transfer_session("history-session", "history-p2"))
    assert(life:detach_session("history-session"))

    local loaded = Lifecycle.new({ path = path })
    assert(loaded:get_session("history-session").panel_id == "history-p2")
    assert(loaded:get_session("history-session").attachment_mode == nil)
    assert(#loaded:events() >= 8)
  end)

  run_test("Lifecycle: replay rejects controller event rewritten to detached observer", function()
    local path = root .. "/attachment-event-replay.json"
    local life = Lifecycle.new({ path = path, max_sessions_per_agent = 2 })
    assert(life:create_panel({ panel_id = "replay-panel" }))
    assert(life:ready_panel("replay-panel"))
    assert(life:create_agent_session({
      session_id = "replay-controller", agent_id = "replay-agent", task_id = "replay-task", panel_id = "replay-panel",
    }))
    assert(life:create_agent_session({
      session_id = "replay-observer", agent_id = "replay-agent", task_id = "replay-task", panel_id = "replay-panel",
    }))
    assert(life:attach_session("replay-controller", "replay-panel"))
    assert(life:detach_session("replay-controller"))
    assert(life:attach_session("replay-observer", "replay-panel", { mode = "observer" }))
    assert(life:detach_session("replay-observer"))

    local clean = Lifecycle.new({ path = path })
    assert(clean:get_session("replay-controller").attachment_mode == nil)
    assert(clean:get_session("replay-observer").attachment_mode == nil)
    local value = clean:_state(); value.version = 1
    for _, event in ipairs(value.events) do
      if event.type == "panel.attached" then
        event.controller_session_id = "replay-observer"
        break
      end
    end
    assert(WheelHost.fs.write_file(path, Session.json_encode(value)))
    local accepted, failure = pcall(Lifecycle.new, { path = path })
    assert(not accepted and failure.code == "E_LIFECYCLE_INVALID")
    assert(not WheelHost.fs.stat(path).exists)
  end)

  run_test("Lifecycle: replay rejects session panel substitutions across transfers", function()
    local path = root .. "/transfer-event-replay.json"
    local life = Lifecycle.new({ path = path })
    for _, panel_id in ipairs({ "replay-p1", "replay-p2", "replay-p3" }) do
      assert(life:create_panel({ panel_id = panel_id }))
      assert(life:ready_panel(panel_id))
    end
    assert(life:create_agent_session({
      session_id = "replay-transfer", agent_id = "replay-transfer-agent", panel_id = "replay-p1",
    }))
    assert(life:activate_session("replay-transfer"))
    assert(life:transfer_session("replay-transfer", "replay-p2"))
    assert(life:transfer_session("replay-transfer", "replay-p3"))
    local valid = Lifecycle.new({ path = path })
    assert(valid:get_session("replay-transfer").panel_id == "replay-p3")

    for _, event_type in ipairs({ "agent_session.created", "agent_session.active" }) do
      local value = valid:_state(); value.version = 1
      for _, event in ipairs(value.events) do
        if event.type == event_type and event.session_id == "replay-transfer" then
          event.panel_id = "replay-p2"
          break
        end
      end
      assert(WheelHost.fs.write_file(path, Session.json_encode(value)))
      local accepted, failure = pcall(Lifecycle.new, { path = path })
      assert(not accepted and failure.code == "E_LIFECYCLE_INVALID",
        event_type .. " panel substitution accepted: " .. tostring(accepted) .. ", " .. tostring(failure and failure.message))
      assert(not WheelHost.fs.stat(path).exists)
      -- The loader quarantines a bad registry; restore a valid persisted history
      -- before testing the next independently mutated event.
      assert(WheelHost.fs.create_private_file(path, Session.json_encode(valid:_state())))
    end
  end)

  run_test("Lifecycle: observers cannot promote and are cleaned on every exit", function()
    for _, ending in ipairs({ "detach_session", "end_session", "abandon_session" }) do
      local life = fixture()
      assert(life:attach_session("s1", "p1", { mode = "observer" }))
      assert(not life:activate_session("s1"))
      assert(not life:attach_session("s1", "p2", { mode = "observer" }))
      assert(not life:attach_session("s1", "p1", { mode = "controller" }))
      assert(not life:close_panel("p1"))
      assert(life[ending](life, "s1"))
      assert(#life:get_panel("p1").observer_session_ids == 0)
      assert(life:close_panel("p1"))
    end
    local life = fixture()
    assert(life:end_session("s1"))
    assert(not life:attach_session("s1", "p1", { mode = "observer" }))
  end)

  run_test("Lifecycle: panel transitions require readiness and matching state", function()
    local life = Lifecycle.new()
    assert(life:create_panel({ panel_id = "p" }))
    assert(life:create_agent_session({ session_id = "s", agent_id = "a", panel_id = "p" }))
    assert(not life:activate_session("s"))
    assert(not life:attach_session("s", "p"))
    assert(life:ready_panel("p"))
    assert(life:activate_session("s"))
    assert(not life:ready_panel("p"))
    assert(not life:close_panel("p"))
  end)

  run_test("Lifecycle: reasons and metadata are bounded plain redacted data", function()
    local life = fixture()
    assert(life:activate_session("s1"))
    local before = #life:events()
    assert(not life:pause_session("s1", { nested = { providerResponse = "private" } }))
    assert(not life:pause_session("s1", string.rep("x", 257)))
    assert(#life:events() == before and life:get_session("s1").state == "active")
    assert(life:pause_session("s1", "Authorization: Bearer synthetic-secret-value"))
    local encoded = require("wheel.session").json_encode(life:events())
    assert(not encoded:find("synthetic-secret-value", 1, true))
    assert(life:events()[#life:events()].reason == "redacted")
    for _, data in ipairs({
      { context_head = {} }, { context_head = string.rep("x", 129) },
      { model_profile = { context_slots = "private" } },
      { model_profile = { ToolOutput = "private" } },
      { model_profile = { arbitrary = "private" } },
      { role_binding = setmetatable({}, {}) },
      { role_binding = { role = 0 / 0 } },
      { role_binding = { role = "coding", policy_generation = 0 } },
      { role_binding = { role = "coding", policy_generation = 1.5 } },
      { role_binding = { role = "coding", policy_generation = "2" } },
      { agent_id = string.rep("a", 33) },
    }) do
      data.session_id, data.agent_id, data.panel_id = "bad", data.agent_id or "bad", "p2"
      assert(not life:create_agent_session(data))
    end
  end)

  run_test("Lifecycle: role transitions advance one policy generation with a checkpoint boundary", function()
    local life = fixture()
    assert(life:activate_session("s1"))
    local checkpoint = string.rep("ab", 32)
    local updated, authority_err = life:record_role_transition("s1", {
      role_binding = { role = "reviewer", binding_id = "role-binding:s1:2", policy_generation = 2 },
      checkpoint = checkpoint,
      reason = "role_transition",
    })
    assert(updated == nil and authority_err.code == "E_LIFECYCLE_AUTHORITY",
      "caller supplied role metadata must not authorize a lifecycle transition")
    assert(life:get_session("s1").role_binding.policy_generation == nil)
    local forged, forged_err = life:record_role_transition("s1", {
      role_binding = { role = "reviewer", binding_id = "role-binding:s1:2", policy_generation = 2 },
      checkpoint = checkpoint,
      reason = "role_transition",
      authority_reference = {},
    })
    assert(forged == nil and forged_err.code == "E_LIFECYCLE_AUTHORITY")
    assert(life:get_session("s1").role_binding.policy_generation == nil)

    local context = WheelContext.new({ kernel = WheelKernel.new_mock() })
    assert(context:put_slot("workspace/project", "Wheel"))
    local bound_life = Lifecycle.new({ max_sessions_per_agent = 3 })
    assert(bound_life:create_panel({ panel_id = "bound-panel", agent_id = "bound-agent" }))
    assert(bound_life:ready_panel("bound-panel"))
    local agent = WheelAgent.new({ name = "bound-agent", role = "coding",
      kernel = context.kernel, context = context, lifecycle = bound_life })
    assert(agent:create_runtime_session({ session_id = "bound-session", panel_id = "bound-panel" }))
    assert(agent:activate_runtime_session())
    local transitioned = assert(agent:transition_role("reviewer", { reason = "role transition" }))
    assert(transitioned.policy_generation == 2)
    assert(bound_life:get_session("bound-session").role_binding.policy_generation == 2)
    local transition_event = bound_life:events()[#bound_life:events()]
    assert(transition_event.type == "agent_session.role_transition")
    assert(transition_event.policy_generation == 2 and transition_event.checkpoint == transitioned.checkpoint)

    local function transition(binding, value)
      return bound_life:record_role_transition("bound-session", {
        role_binding = binding,
        checkpoint = value or string.rep("cd", 32),
        reason = "role_transition",
        authority_reference = agent:authority_reference(),
      })
    end
    local stale, stale_err = transition({
      role = "coding", binding_id = "role-binding:s1:3", policy_generation = 2,
    })
    assert(stale == nil and stale_err.code == "E_LIFECYCLE_AUTHORITY")
    local skipped, skipped_err = transition({
      role = "coding", binding_id = "role-binding:s1:4", policy_generation = 4,
    })
    assert(skipped == nil and skipped_err.code == "E_LIFECYCLE_AUTHORITY")
    local reused, reused_err = transition({
      role = "coding", binding_id = "role-binding:s1:2", policy_generation = 3,
    })
    assert(reused == nil and reused_err.code == "E_LIFECYCLE_AUTHORITY")
    local missing_checkpoint, checkpoint_err = bound_life:record_role_transition("bound-session", {
      role_binding = { role = "coding", binding_id = "role-binding:s1:3", policy_generation = 3 },
      reason = "role_transition",
      authority_reference = agent:authority_reference(),
    })
    assert(missing_checkpoint == nil and checkpoint_err.code == "E_LIFECYCLE_INVALID")
    local wrong_reason, reason_err = bound_life:record_role_transition("bound-session", {
      role_binding = { role = "coding", binding_id = "role-binding:s1:3", policy_generation = 3 },
      checkpoint = string.rep("ef", 32),
      reason = "manual",
      authority_reference = agent:authority_reference(),
    })
    assert(wrong_reason == nil and reason_err.code == "E_LIFECYCLE_INVALID")

    assert(bound_life:get_session("bound-session").role_binding.policy_generation == 2)
    assert(bound_life:end_session("bound-session"))
    local terminal, terminal_err = transition({
      role = "coding", binding_id = "role-binding:s1:3", policy_generation = 3,
    })
    assert(terminal == nil and terminal_err.code == "E_LIFECYCLE_STATE")
    assert(bound_life:get_session("bound-session").role_binding.policy_generation == 2)
  end)

  run_test("Lifecycle: callers cannot mint canonical Agent authority", function()
    local life = Lifecycle.new({ max_sessions_per_agent = 3 })
    assert(life:create_panel({ panel_id = "forged-panel" }))
    local token = {}
    local calls = 0
    local function forged_resolver(candidate)
      calls = calls + 1
      return { agent_id = "forged-agent", role_binding = candidate,
        capabilities = { "inspect", "verify", "modify", "execute" } }
    end
    local initial = { role = "reviewer", binding_id = "forged-binding:1", policy_generation = 1 }
    local created, create_err = life:create_agent_session({
      session_id = "forged-session", agent_id = "forged-agent", panel_id = "forged-panel",
      role_binding = initial, authority_reference = token, authority_resolver = forged_resolver,
    })
    assert(created == nil and create_err.code == "E_LIFECYCLE_AUTHORITY")
    assert(calls == 0 and life:get_session("forged-session") == nil)
    local token_only, token_err = life:create_agent_session({
      session_id = "forged-session", agent_id = "forged-agent", panel_id = "forged-panel",
      role_binding = initial, authority_reference = token,
    })
    assert(token_only == nil and token_err.code == "E_LIFECYCLE_AUTHORITY")
    local plain = assert(life:create_agent_session({
      session_id = "plain-session", agent_id = "forged-agent", panel_id = "forged-panel",
      role_binding = initial,
    }))
    -- Public-looking backing fields and a caller resolver cannot turn metadata
    -- sessions into canonical Agent sessions, including the reviewer's exploit.
    life._authority_tokens = { [plain.session_id] = token }
    life._authority_resolvers = { [plain.session_id] = forged_resolver }
    life._authorize_session = function() return true end
    life._resolve_session_authority = function(_, _, _, candidate) return forged_resolver(candidate) end
    local changed, err = life:record_role_transition(plain.session_id, {
      role_binding = { role = "coding", binding_id = "forged-binding:2", policy_generation = 2 },
      checkpoint = string.rep("ab", 32), reason = "role_widening", authority_reference = token,
    })
    assert(changed == nil and err.code == "E_LIFECYCLE_AUTHORITY")
    assert(calls == 0 and life:authority_reference(plain.session_id) == nil)
    assert(life:get_session(plain.session_id).role_binding.role == "reviewer")
    assert(life:get_session(plain.session_id).role_binding.policy_generation == 1)
    assert(#life:events() == 2)

    local second = assert(life:create_agent_session({
      session_id = "plain-child", agent_id = "plain-child", panel_id = "forged-panel",
      role_binding = { role = "coding", binding_id = "plain-child:1", policy_generation = 1 },
    }))
    life._authority_tokens[second.session_id] = token
    life._authority_resolvers[second.session_id] = forged_resolver
    local widened, widen_err = life:record_authority_widening(plain.session_id, second.session_id, {
      parent_authority_reference = token, child_authority_reference = token,
      checkpoint = string.rep("ab", 32), capability_delta = "modify,execute",
    })
    assert(widened == nil and widen_err.code == "E_LIFECYCLE_AUTHORITY" and calls == 0)

    local kernel = WheelKernel.new_mock()
    local context = WheelContext.new({ kernel = kernel })
    assert(context:put_slot("workspace/project", "Wheel"))
    local reviewer = WheelAgent.new({ name = "issuer-reviewer", role = "reviewer",
      kernel = kernel, context = context, lifecycle = life })
    local session = assert(reviewer:create_runtime_session({ session_id = "issuer-session" }))
    local reference = reviewer:authority_reference()
    assert(reference == life:authority_reference(session.session_id))
    local candidate = { role = "coding", binding_id = "role-binding:issuer-reviewer:2", policy_generation = 2 }
    local forged_transition, forged_err = life:record_role_transition(session.session_id, {
      role_binding = candidate, checkpoint = string.rep("cd", 32),
      reason = "role_widening", authority_reference = reference,
    })
    assert(forged_transition == nil and forged_err.code == "E_LIFECYCLE_AUTHORITY")
    assert(not reviewer:has_capability("modify") and reviewer.agent_id == session.agent_id)
    local borrowed, borrow_err = life:create_agent_session({
      session_id = "borrowed-session", agent_id = reviewer.agent_id, panel_id = session.panel_id,
      role_binding = reviewer.role_binding, authority_reference = reference,
    })
    assert(borrowed == nil and borrow_err.code == "E_LIFECYCLE_AUTHORITY")
    local issuer = getmetatable(WheelAgent)
    assert(not pcall(function() issuer.resolve = forged_resolver end))
    assert(not pcall(rawset, issuer, "resolve", forged_resolver))
    assert(not pcall(setmetatable, WheelAgent, { __metatable = { resolve = forged_resolver } }))
    assert(reviewer:transition_role("coding", { reason = "approved escalation", approve_widening = true }))
    assert(reviewer:has_capability("modify"))
  end)

  run_test("Lifecycle: persisted policy generations reject a forged history", function()
    local path = root .. "/role-transition.json"
    local life = Lifecycle.new({ path = path })
    assert(life:create_panel({ panel_id = "role-panel", agent_id = "role-agent" }))
    assert(life:ready_panel("role-panel"))
    local kernel = WheelKernel.new_mock()
    local context = WheelContext.new({ kernel = kernel })
    assert(context:put_slot("workspace/project", "Wheel"))
    local agent = WheelAgent.new({ name = "role-agent", role = "coding",
      kernel = kernel, context = context, lifecycle = life })
    assert(agent:create_runtime_session({ session_id = "role-session", panel_id = "role-panel" }))
    local checkpoint = assert(context:commit_checkpoint({ author = "role-agent", message = "baseline" }))
    assert(agent:transition_role("debug", { reason = "role transition" }))
    local persisted_checkpoint = life:get_session("role-session").checkpoint
    assert(persisted_checkpoint == checkpoint.hash or type(persisted_checkpoint) == "string")

    local reloaded = assert(Lifecycle.new({ path = path }))
    local record = assert(reloaded:get_session("role-session"))
    assert(record.role_binding.role == "debug")
    assert(record.role_binding.policy_generation == 2)
    assert(type(record.checkpoint) == "string")
    local resumed, resume_err = reloaded:record_role_transition("role-session", {
      role_binding = { role = "coding", binding_id = "reloaded:3", policy_generation = 3 },
      reason = "role_widening", checkpoint = record.checkpoint,
      authority_reference = agent:authority_reference(),
    })
    assert(resumed == nil and resume_err.code == "E_LIFECYCLE_AUTHORITY",
      "persisted metadata must not restore in-process Agent authority")

    local raw = assert(WheelHost.fs.read_file(path))
    local forged = Session.json_decode(raw)
    forged.sessions["role-session"].role_binding.policy_generation = 5
    assert(WheelHost.fs.remove_file(path))
    assert(WheelHost.fs.create_private_file(path, Session.json_encode(forged)))
    assert(not pcall(Lifecycle.new, { path = path }))
    assert(not WheelHost.fs.stat(path).exists)
  end)

  run_test("Lifecycle: replay rejects skipped successive policy generations", function()
    local path = root .. "/skipped-policy-generation.json"
    local life = Lifecycle.new({ path = path })
    local kernel = WheelKernel.new_mock()
    local context = WheelContext.new({ kernel = kernel })
    assert(context:put_slot("workspace/project", "Wheel"))
    local agent = WheelAgent.new({ name = "successive-policy-agent", role = "coding",
      kernel = kernel, context = context, lifecycle = life })
    local session = assert(agent:create_runtime_session())
    assert(agent:transition_role("debug", { reason = "first successive generation" }))
    assert(agent:transition_role("coding", { reason = "second successive generation" }))
    assert(Lifecycle.new({ path = path }):get_session(session.session_id).role_binding.policy_generation == 3)
    local forged = Session.json_decode(assert(WheelHost.fs.read_file(path)))
    for _, event in ipairs(forged.events) do
      if event.type == "agent_session.role_transition" and event.policy_generation == 3 then
        event.policy_generation = 4
      end
    end
    forged.sessions[session.session_id].role_binding.policy_generation = 4
    assert(WheelHost.fs.remove_file(path))
    for _, retained in ipairs({ false, true }) do
      if retained then table.remove(forged.events, 1) end
      assert(WheelHost.fs.create_private_file(path, Session.json_encode(forged)))
      assert(not pcall(Lifecycle.new, { path = path }), "forged 2 -> 4 transition must fail full and retained replay")
      assert(not WheelHost.fs.stat(path).exists)
    end
  end)

  run_test("Lifecycle: registry symlink never overwrites its target", function()
    local target, link = root .. "/sentinel", root .. "/link.json"
    assert(WheelHost.fs.create_private_file(target, "preserve-this"))
    assert(success(os.execute("ln -s -- " .. shell_quote(target) .. " " .. shell_quote(link))))
    local accepted = pcall(Lifecycle.new, { path = link })
    assert(not accepted)
    assert(WheelHost.fs.read_file(target) == "preserve-this")
  end)

  run_test("Lifecycle: stale writers conflict, failures roll back, generated IDs are unique", function()
    local path = root .. "/atomic.json"
    local first, stale = Lifecycle.new({ path = path }), Lifecycle.new({ path = path })
    assert(first:create_panel({ panel_id = "first" }))
    assert(not stale:create_panel({ panel_id = "lost" }))
    assert(stale:get_panel("lost") == nil and #stale:events() == 0)
    assert(stale:load())
    local old_rename = WheelHost.fs.rename
    WheelHost.fs.rename = function() return false, "injected" end
    local result, failure = stale:create_panel({ panel_id = "failed" })
    WheelHost.fs.rename = old_rename
    assert(not result and failure and stale:get_panel("failed") == nil)
    assert(stale:create_panel({ panel_id = "retry" }))
    local ids = {}
    for _ = 1, 10 do
      local life = Lifecycle.new()
      local panel = assert(life:create_panel())
      assert(not ids[panel.panel_id]); ids[panel.panel_id] = true
      local session = assert(life:create_agent_session({ agent_id = "a", panel_id = panel.panel_id }))
      assert(not ids[session.session_id]); ids[session.session_id] = true
      for _, event in ipairs(life:events()) do
        assert(not ids[event.event_id]); ids[event.event_id] = true
      end
    end
  end)

  run_test("Lifecycle: malformed and oversized registries fail closed", function()
    local JSON = require("wheel.session")
    local path = root .. "/corrupt.json"
    local good = { version = 1, revision = 0, policy = { max_sessions_per_agent = 1, allow_multiple_tasks = true },
      next_counter = 0, sessions = {}, panels = {}, events = {} }
    local variants = { "{", string.rep("x", 4 * 1024 * 1024 + 1) }
    for _, change in ipairs({
      function(v) v.sessions = "wrong" end,
      function(v) v.policy.allow_multiple_tasks = "yes" end,
      function(v) v.next_counter = -1 end,
      function(v) v.panels.p = { panel_id = "different" } end,
      function(v) v.events = { { type = "unknown" } } end,
      function(v) v.extra = "not allowed" end,
    }) do
      local value = JSON.json_decode(JSON.json_encode(good)); change(value)
      variants[#variants + 1] = JSON.json_encode(value)
    end
    for _, raw in ipairs(variants) do
      assert(WheelHost.fs.create_private_file(path, raw))
      assert(not pcall(Lifecycle.new, { path = path }))
      -- Invalid data is quarantined at a private sibling; retry is an explicit fresh start.
      assert(not WheelHost.fs.stat(path).exists)
    end
  end)

  run_test("Lifecycle: loaded records reject inconsistent relationships and illegal history", function()
    local life = fixture()
    assert(life:activate_session("s1"))
    local good = life:_state()
    good.version = 1
    local mutations = {
      function(v) v.sessions.s1.panel_id = "absent" end,
      function(v) v.sessions.s1.state = "ended" end,
      function(v) v.sessions.s1.state = "abandoned" end,
      function(v) v.panels.p1.state = "attached" end,
      function(v) v.sessions.s1.recovered_from = "arbitrary" end,
      function(v) v.sessions.s1.context_head = "private transcript excerpt: customer-design" end,
      function(v) v.sessions.s1.role_binding = nil end,
      function(v) v.sessions.s1.model_profile = nil end,
      function(v) v.sessions.s1.model_profile = {} end,
      function(v) v.sessions.s1.model_profile.model = { tool_output = "private" } end,
      function(v) v.sessions.s1.model_profile.model = "private transcript excerpt" end,
      function(v) v.events[1].from_state = "closed" end,
      function(v) v.events[1].to_state = "active" end,
      function(v) v.events[1].reason = "private transcript excerpt: customer-design" end,
      function(v) v.revision = 9007199254740992 end,
      function(v) v.events[2].event_id = v.events[1].event_id end,
      function(v) v.panels.p1.observer_session_ids = { unknown = "s2" } end,
      function(v) v.sessions.s1.model_profile.retry = { max_retries = "private" } end,
    }
    local path = root .. "/invalid-state.json"
    for index, change in ipairs(mutations) do
      local value = Session.json_decode(Session.json_encode(good))
      change(value)
      assert(WheelHost.fs.create_private_file(path, Session.json_encode(value)))
      local accepted, failure = pcall(Lifecycle.new, { path = path })
      assert(not accepted and type(failure) == "table", "invalid loaded state " .. index)
      assert(failure.code == "E_LIFECYCLE_INVALID")
      assert(not WheelHost.fs.stat(path).exists)
    end
  end)

  run_test("Lifecycle: loaded events reject forged session and attachment identities", function()
    local life = fixture()
    assert(life:attach_session("s1", "p1"))
    assert(life:attach_session("s2", "p1", { mode = "observer" }))
    assert(life:create_agent_session({ session_id = "s3", agent_id = "agent3", panel_id = "p2" }))
    assert(life:attach_session("s3", "p2"))
    assert(life:create_agent_session({ session_id = "s4", agent_id = "agent4", panel_id = "p2" }))
    assert(life:attach_session("s4", "p2", { mode = "observer" }))
    local good = life:_state(); good.version = 1
    local mutations = {
      function(value)
        for _, event in ipairs(value.events) do
          if event.type == "agent_session.created" then event.agent_id = "forged-agent"; return end
        end
        error("session event fixture missing")
      end,
      function(value)
        for _, event in ipairs(value.events) do
          if event.type == "agent_session.created" then event.task_id = "forged-task"; return end
        end
        error("session event fixture missing")
      end,
      function(value)
        for _, event in ipairs(value.events) do
          if event.type == "agent_session.created" and event.session_id == "s1" then event.panel_id = "p2"; return end
        end
        error("session event fixture missing")
      end,
      function(value)
        for _, event in ipairs(value.events) do
          if event.type == "panel.attached" and event.panel_id == "p1" then event.controller_session_id = "s3"; return end
        end
        error("controller event fixture missing")
      end,
      function(value)
        for _, event in ipairs(value.events) do
          if event.type == "panel.attached" and event.panel_id == "p1" then event.panel_id = "p2"; return end
        end
        error("controller event fixture missing")
      end,
      function(value)
        for _, event in ipairs(value.events) do
          if event.type == "panel.attached" and event.panel_id == "p1" then event.agent_id = "forged-agent"; return end
        end
        error("controller event fixture missing")
      end,
      function(value)
        for _, event in ipairs(value.events) do
          if event.type == "panel.attached" and event.panel_id == "p1" then event.task_id = "forged-task"; return end
        end
        error("controller event fixture missing")
      end,
      function(value)
        for _, event in ipairs(value.events) do
          if event.type == "panel.observer_attached" and event.panel_id == "p1" then event.panel_id = "p2"; return end
        end
        error("observer event fixture missing")
      end,
      function(value)
        for _, event in ipairs(value.events) do
          if event.type == "panel.observer_attached" and event.panel_id == "p1" then event.observer_session_id = "s4"; return end
        end
        error("observer event fixture missing")
      end,
      function(value)
        for _, event in ipairs(value.events) do
          if event.type == "panel.observer_attached" and event.panel_id == "p1" then event.observer_session_id = "s1"; return end
        end
        error("observer event fixture missing")
      end,
      function(value)
        for _, event in ipairs(value.events) do
          if event.type == "panel.attached" then event.mode = "observer"; return end
        end
        error("controller event fixture missing")
      end,
      function(value)
        for _, event in ipairs(value.events) do
          if event.type == "panel.observer_attached" then event.observer_session_id = "unknown-observer"; return end
        end
        error("observer event fixture missing")
      end,
      function(value)
        for _, event in ipairs(value.events) do
          if event.type == "panel.attached" then event.panel_id = "p2"; return end
        end
        error("controller event fixture missing")
      end,
      function(value)
        for _, event in ipairs(value.events) do
          if event.type == "panel.observer_attached" then event.panel_id = "p2"; return end
        end
        error("observer event fixture missing")
      end,
      function(value)
        for _, event in ipairs(value.events) do
          if event.type == "panel.attached" then event.mode = "observer"; return end
        end
        error("controller event fixture missing")
      end,
      function(value)
        value.sessions.s1.attachment_mode = "observer"
      end,
      function(value)
        for _, event in ipairs(value.events) do
          if event.type == "panel.observer_attached" then event.session_id = "s1"; return end
        end
        error("observer event fixture missing")
      end,
    }
    local path = root .. "/invalid-events.json"
    for index, change in ipairs(mutations) do
      local value = Session.json_decode(Session.json_encode(good))
      change(value)
      assert(WheelHost.fs.create_private_file(path, Session.json_encode(value)))
      local accepted, failure = pcall(Lifecycle.new, { path = path })
      assert(not accepted and failure.code == "E_LIFECYCLE_INVALID", "invalid event " .. index)
      assert(not WheelHost.fs.stat(path).exists)
    end
  end)

  run_test("Lifecycle: loaded sanitizers replace credentials before getters and save", function()
    local life = fixture()
    assert(life:activate_session("s1"))
    assert(life:pause_session("s1", "user_pause"))
    local value = life:_state(); value.version = 1
    value.sessions.s1.model_profile.model = "Authorization: Bearer synthetic-loaded-secret"
    value.events[#value.events].reason = "Authorization: Bearer synthetic-event-secret"
    local path = root .. "/sanitize.json"
    assert(WheelHost.fs.create_private_file(path, Session.json_encode(value)))
    local loaded = Lifecycle.new({ path = path })
    assert(loaded:get_session("s1").model_profile.model == "[redacted]")
    assert(loaded:events()[#loaded:events()].reason == "redacted")
    assert(loaded:save())
    local raw = assert(WheelHost.fs.read_file(path))
    assert(not raw:find("synthetic-loaded-secret", 1, true))
    assert(not raw:find("synthetic-event-secret", 1, true))
    assert(Lifecycle.new({ path = path }):get_session("s1").model_profile.model == "[redacted]")
    assert(not loaded:pause_session("s2", "private transcript excerpt"))
    assert(not loaded:end_session("s1", "private transcript excerpt"))
  end)

  run_test("Lifecycle: revisions remain exact across process writes and stale handles", function()
    local path = root .. "/revision.json"
    local life = Lifecycle.new({ path = path })
    assert(life:create_panel({ panel_id = "initial" }))
    local value = Session.json_decode(assert(WheelHost.fs.read_file(path)))
    value.revision = 9007199254740989
    assert(WheelHost.fs.write_file(path, Session.json_encode(value)))
    local stale = Lifecycle.new({ path = path })
    for _, name in ipairs({ "child-one", "child-two" }) do
      local child = WheelHost.proc.run_program(interpreter(), { script_path, "writer", path, name })
      assert(child.exit_code == 0, tostring(child.stderr))
    end
    local rejected, err = stale:create_panel({ panel_id = "stale" })
    assert(not rejected and err.code == "E_LIFECYCLE_CONFLICT")
    assert(stale:get_panel("stale") == nil)
    local last = Lifecycle.new({ path = path })
    assert(last.revision == 9007199254740991)
    assert(last:get_panel("child-one") and last:get_panel("child-two"))
    local capped = WheelHost.proc.run_program(interpreter(), { script_path, "writer", path, "capped" })
    assert(capped.exit_code == 3)
    assert(not last:get_panel("capped"))
  end)

  run_test("Lifecycle: concurrent processes serialize one revision update", function()
    local path, barrier = root .. "/race.json", root .. "/race-barrier"
    assert(WheelHost.fs.mkdir(barrier))
    assert(Lifecycle.new({ path = path }):create_panel({ panel_id = "base" }))
    local command = table.concat({
      shell_quote(interpreter()), shell_quote(script_path), "writer-race", shell_quote(path),
      shell_quote(barrier), "race-a", "& a=$!;",
      shell_quote(interpreter()), shell_quote(script_path), "writer-race", shell_quote(path),
      shell_quote(barrier), "race-b", "& b=$!; wait \"$a\"; a_status=$?; wait \"$b\"; b_status=$?;",
      "if [ \"$a_status\" -eq 0 ] && [ \"$b_status\" -eq 4 ]; then exit 0; fi;",
      "if [ \"$b_status\" -eq 0 ] && [ \"$a_status\" -eq 4 ]; then exit 0; fi; exit 1",
    }, " ")
    local result = WheelHost.proc.run_program("bash", { "-c", command }, { cwd = "." })
    assert(result.ok and result.exit_code == 0,
      "race command failed " .. tostring(result.exit_code) .. ": " .. tostring(result.stderr))
    local loaded = Lifecycle.new({ path = path })
    assert(loaded:get_panel("base"))
    assert((loaded:get_panel("race-a") ~= nil) ~= (loaded:get_panel("race-b") ~= nil))
    assert(loaded.revision == 2)
  end)

  run_test("Lifecycle: commit exceptions release owned locks and preserve retry state", function()
    local path = root .. "/exception.json"
    local life = Lifecycle.new({ path = path })
    assert(life:create_panel({ panel_id = "p" }))
    local before = assert(WheelHost.fs.read_file(path))
    local cases = {
      { target = WheelHost.fs, key = "random_bytes" },
      { target = Session, key = "json_encode" },
      { target = WheelHost.fs, key = "create_private_file" },
      { target = WheelHost.fs, key = "rename" },
    }
    for _, item in ipairs(cases) do
      local original = item.target[item.key]
      item.target[item.key] = function() error("injected exception", 0) end
      local called, result = pcall(life.save, life)
      item.target[item.key] = original
      assert(called and not result, item.key)
      assert(not WheelHost.fs.stat(path .. ".lock").exists, item.key)
      assert(not WheelHost.fs.stat(path .. ".lock.mutex").exists, item.key)
      assert(WheelHost.fs.read_file(path) == before)
      assert(life:get_panel("p").state == "created")
      assert(life:save())
      before = assert(WheelHost.fs.read_file(path))
    end
    local listing = WheelHost.fs.list_dir(root)
    assert(not listing.stdout:find("exception.json.tmp.", 1, true))
  end)

  run_test("Lifecycle: history capacity never blocks pause or terminal-session turnover", function()
    local life = fixture()
    assert(life:activate_session("s1"))
    local template = life:events()[1]
    for index = 1, 2048 do
      local event = Session.json_decode(Session.json_encode(template))
      event.event_id = "retained-" .. index
      life.events_log[index] = event
    end
    assert(life:pause_session("s1", "user_pause"))
    assert(#life:events() == 2048)
    assert(life:get_session("s1").state == "paused")
    local terminal = life:get_session("s2"); terminal.state = "ended"
    for index = 1, 510 do
      local record = Session.json_decode(Session.json_encode(terminal))
      record.session_id, record.agent_id = "terminal-" .. index, "terminal-" .. index
      life.sessions[record.session_id] = record
    end
    local new = assert(life:create_agent_session({ session_id="after-cap", agent_id="new", panel_id="p2" }))
    assert(new.state == "created" and #life:list_sessions() == 512)
    assert(life:get_session("s1").checkpoint == nil and life:get_session("s1").state == "paused")
    assert(life:resume_session("s1"))
    assert(life:end_session("s1"))
  end)

  run_test("Lifecycle: alternate root and typed agent errors remain visible", function()
    local child = WheelHost.proc.run_program(interpreter(), { script_path, "alternate-root" })
    assert(child.exit_code == 0, tostring(child.stderr))
    local Agent = require("wheel.agent")
    local original = package.preload["wheel.lifecycle"]
    local saved = package.loaded["wheel.lifecycle"]
    local saved_agent = package.loaded["wheel.agent"]
    for _ = 1, 2 do
      package.loaded["wheel.agent"], package.loaded["wheel.lifecycle"] = nil, nil
      package.preload["wheel.lifecycle"] = function() error({ code="E_TEST_LOADER", message="typed denial" }, 0) end
      local accepted, failure = pcall(require, "wheel.agent")
      assert(not accepted and type(failure) == "table" and failure.code == "E_TEST_LOADER")
      assert(package.loaded["wheel.lifecycle"] == nil)
    end
    package.preload["wheel.lifecycle"] = original
    package.loaded["wheel.lifecycle"], package.loaded["wheel.agent"] = saved, saved_agent
    local marker = { code="E_TEST_READY", message="cannot ready" }
    local fake = {
      get_panel = function() return { panel_id="p", state="created" } end,
      ready_panel = function() return nil, marker end,
      create_agent_session = function() error("must not create session", 0) end,
    }
    local agent = Agent.new({
      name = "typed-lifecycle-agent",
      role = Agent.Role.CODING,
      kernel = require("wheel.kernel").new_mock(),
      lifecycle = fake,
      panel_id = "p",
    })
    local result, failure = agent:create_runtime_session()
    assert(not result and failure == marker)
  end)

  run_test("Lifecycle: cross-process persistence and recovery", function()
    local lifecycle = Lifecycle.new({ path = registry, max_sessions_per_agent = 2 })
    assert(lifecycle:create_panel({ panel_id = "cross-panel", agent_id = "cross-agent" }))
    assert(lifecycle:ready_panel("cross-panel"))
    local session = assert(lifecycle:create_agent_session({
      session_id = "cross-session",
      agent_id = "cross-agent",
      panel_id = "cross-panel",
      task_id = "cross-task",
      context_branch = "refs/heads/cross",
      context_head = "cross-head",
      role_binding = { role = "coding" },
      model_profile = { provider = "mock", model = "mock" },
      prompt = "must not be persisted",
    }))
    assert(lifecycle:activate_session(session.session_id))
    assert(lifecycle:checkpoint_session(session.session_id, "cross-checkpoint"))
    assert(lifecycle:pause_session(session.session_id))

    local interpreter = os.getenv("WHEEL_LUA")
    if not interpreter or interpreter == "" then
      local selection = WheelHost.proc.run_program("bash", { "scripts/test-gate.sh", "--print-selection" })
      interpreter = (selection.stdout or ""):gsub("%s+$", "")
    end
    assert(interpreter ~= "" and interpreter ~= "none", "a Lua interpreter is required")
    local child = WheelHost.proc.run_program(interpreter, { script_path, "child", registry }, { cwd = "." })
    assert(child.ok and child.exit_code == 0,
      "child process must resume the persisted session: " .. tostring(child.stderr))

    local reloaded = Lifecycle.new({ path = registry })
    local recovered = reloaded:get_session("cross-session")
    assert(recovered.state == Lifecycle.AgentSessionState.ACTIVE)
    local events = reloaded:events()
    assert(#events >= 7)
    for _, event in ipairs(events) do
      assert(event.prompt == nil and event.context == nil and event.content == nil)
    end
  end)

  run_test("Lifecycle: observer and conflicting controller separation", function()
    local lifecycle = Lifecycle.new({ max_sessions_per_agent = 3 })
    assert(lifecycle:create_panel({ panel_id = "observer-panel" }))
    assert(lifecycle:ready_panel("observer-panel"))
    assert(lifecycle:create_agent_session({ session_id = "controller", agent_id = "a", panel_id = "observer-panel" }))
    assert(lifecycle:create_agent_session({ session_id = "observer", agent_id = "b", panel_id = "observer-panel" }))
    assert(lifecycle:activate_session("controller"))
    assert(lifecycle:attach_session("observer", "observer-panel", { mode = Lifecycle.AttachMode.OBSERVER }))
    local controller = lifecycle:create_agent_session({ session_id = "controller-2", agent_id = "c", panel_id = "observer-panel" })
    assert(controller)
    local activated, activation_err = lifecycle:activate_session(controller.session_id)
    assert(not activated and activation_err.code == "E_LIFECYCLE_PANEL_BUSY")
  end)
end)

cleanup()
if not ok then
  error(err, 0)
end
print("All lifecycle tests PASSED")
