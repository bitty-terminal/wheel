-- Comprehensive test suite for Bitty Wheel (bitty-terminal.wheel).
-- Tests WheelKernel, WheelAgent, WheelUI, and plugin command registration.

package.path = "./lua/?.lua;./lua/?/init.lua;" .. package.path

local WheelKernel = require("wheel.kernel")
local WheelAgent = require("wheel.agent")
local WheelUI = require("wheel.ui")

local function run_test(name, fn)
  local ok, err = pcall(fn)
  if ok then
    print("[PASS] " .. name)
  else
    print("[FAIL] " .. name .. ": " .. tostring(err))
    os.exit(1)
  end
end

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

run_test("Wheel Init: command registration and dispatch", function()
  -- Mock bitty host API
  local registered_commands = {}
  local notifications = {}

  bitty = {
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

  -- Load init.lua
  local wheel = require("wheel.init")
  assert(wheel.kernel ~= nil)
  assert(wheel.agent ~= nil)
  assert(wheel.ui ~= nil)

  -- Verify all 5 commands were registered
  assert(registered_commands["hello"] ~= nil, "hello command registered")
  assert(registered_commands["status"] ~= nil, "status command registered")
  assert(registered_commands["graph"] ~= nil, "graph command registered")
  assert(registered_commands["plan"] ~= nil, "plan command registered")
  assert(registered_commands["run"] ~= nil, "run command registered")

  -- Test running hello
  registered_commands["hello"].run()
  assert(#notifications == 1)
  assert(notifications[1].title == "Wheel")

  -- Test running plan
  registered_commands["plan"].run()
  assert(#notifications == 2)
  assert(notifications[2].title == "Wheel Plan")
  assert(#wheel.kernel:list_tasks() == 3)

  -- Test running status
  registered_commands["status"].run()
  assert(#notifications == 3)
  assert(notifications[3].title == "Wheel Status")

  -- Test running graph
  registered_commands["graph"].run()
  assert(#notifications == 4)
  assert(notifications[4].title == "Wheel Task DAG")

  -- Test running run (executes CTX-0001)
  registered_commands["run"].run()
  assert(#notifications == 5)
  assert(notifications[5].title == "Wheel Run")
  assert((wheel.kernel:get_task("CTX-0001").status or ""):lower() == "succeeded")
  -- CTX-0002 should now be Ready
  assert((wheel.kernel:get_task("CTX-0002").status or ""):lower() == "ready")
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

print("\n==========================================")
print("  All Wheel tests PASSED successfully! 🚀 ")
print("==========================================")
