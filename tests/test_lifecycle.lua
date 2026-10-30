-- AgentSession and Headless Panel lifecycle tests.
-- The child invocation reloads the registry from disk and performs the
-- transition, exercising the same file-backed boundary used by a separate
-- Wheel process. No prompt, context, transcript, provider response, or tool
-- output is put in the lifecycle registry.

package.path = "./lua/?.lua;./lua/?/init.lua;" .. package.path

local WheelHost = require("wheel.host")
local Lifecycle = require("wheel.lifecycle")

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
local registry = root .. "/lifecycle.json"

local function cleanup()
  os.execute("rm -rf -- " .. shell_quote(root))
end

local ok, err = pcall(function()
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
