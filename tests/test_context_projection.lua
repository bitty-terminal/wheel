-- Focused unit tests for deterministic role-aware Context projections (CTX-0037).

local WheelContext = require("wheel.context")

local ROLES = {
  WheelContext.Role.PLANNER,
  WheelContext.Role.DOCUMENTATION,
  WheelContext.Role.CODING,
  WheelContext.Role.DEBUG,
  WheelContext.Role.RESEARCH,
  WheelContext.Role.REVIEWER,
}

local function fixed_context()
  local context = WheelContext.new()
  assert(context:put_slot("workspace/project", "Wheel").success)
  assert(context:put_slot("architecture/overview", "Immutable context graph").success)
  assert(context:put_slot("decisions/security", "Fail closed").success)
  assert(context:put_slot("security/model", "Least privilege").success)
  assert(context:put_slot("tasks/TASK-1/plan", "Implement projection").success)
  assert(context:put_slot("code/src/main.lua", "return true").success)
  assert(context:put_slot("diagnostics/build", "clean").success)
  assert(context:put_slot("docs/guide", "Projection guide").success)
  assert(context:put_slot("research/finding", "Relevant finding").success)
  return context
end

local function assert_projection_error(context, options, label)
  local projection, err = context:project(options)
  assert(projection == nil, label .. " must be rejected")
  assert(type(err) == "table" and err.class == "validation"
    and err.code == "E_PROJECTION_INVALID", label .. " must return typed projection error")
  return err
end

return function(run_test)
  run_test("Context projections: all role fixtures are deterministic and layered", function()
    local context = fixed_context()
    local first = assert(context:commit_checkpoint({
      author = "fixture",
      task_id = "TASK-1",
      message = "fixture root",
      timestamp_ms = 1700000000000,
    }))
    assert(context:put_slot("workspace/project", "Wheel updated").success)
    local second = assert(context:commit_checkpoint({
      author = "fixture",
      task_id = "TASK-1",
      message = "fixture update",
      timestamp_ms = 1700000001000,
    }))

    for _, role in ipairs(ROLES) do
      local options = {
        base_commit = first.hash,
        current_commit = second.hash,
        role = role,
        task_id = "TASK-1",
        session_id = "SESSION-1",
        records = {
          { ref = "record/task", category = "tasks", task_id = "TASK-1", value = "deliverable" },
          { ref = "record/unrelated", category = "source", task_id = "OTHER", value = "unrelated" },
        },
        recent_records = {
          { ref = "tail/new", category = "diagnostics", timestamp_ms = 2, value = "new" },
          { ref = "tail/old", category = "diagnostics", timestamp_ms = 1, value = "old" },
        },
      }
      local projection = assert(context:project(options))
      assert(projection.version == WheelContext.PROJECTION_VERSION)
      assert(projection.role == role)
      assert(projection.base_commit == first.hash)
      assert(projection.current_commit == second.hash)
      assert(projection.relevant_scopes and #projection.relevant_scopes == 0)
      assert(projection.layers.P0 and projection.layers.P1 and projection.layers.P2
        and projection.layers.P3 and projection.layers.P4)
      local saw_slot_delta = false
      for _, record in ipairs(projection.layers.P3.records) do
        if record.ref == "slot:workspace/project" then saw_slot_delta = true end
      end
      assert(saw_slot_delta, role .. " must expose deterministic structured delta")
      local saw_task_slot = false
      for _, record in ipairs(projection.layers.P2.records) do
        if record.ref == "slot:tasks/TASK-1/plan" then saw_task_slot = true end
      end
      assert(saw_task_slot, role .. " must include task projection")
      assert(not projection.canonical_bytes:find("record/unrelated", 1, true),
        role .. " must not include unrelated task records")
      assert(projection.total_bytes <= projection.max_budget_bytes)
      local repeat_projection = assert(context:project(options))
      assert(projection.canonical_bytes == repeat_projection.canonical_bytes,
        role .. " projection must be byte-stable")
    end
  end)

  run_test("Context projections: documentation defaults exclude source slots", function()
    local context = fixed_context()
    local commit = assert(context:commit_checkpoint({
      author = "fixture", message = "documentation fixture", timestamp_ms = 1700000000000,
    }))
    local projection = assert(context:project({
      base_commit = commit.hash, current_commit = commit.hash,
      role = WheelContext.Role.DOCUMENTATION,
      recent_records = {
        { ref = "tail/source", category = "source", timestamp_ms = 1, value = "source" },
      },
    }))
    assert(projection.canonical_bytes:find("docs/guide", 1, true))
    assert(not projection.canonical_bytes:find("code/src/main.lua", 1, true),
      "documentation view must exclude unrelated source code")
    assert(not projection.canonical_bytes:find("tail/source", 1, true),
      "documentation tail must exclude unrelated source records")
  end)

  run_test("Context projections: omitted references identify byte-budget pruning", function()
    local context = fixed_context()
    local commit = assert(context:commit_checkpoint({
      author = "fixture", message = "budget fixture", timestamp_ms = 1700000000000,
    }))
    local projection = assert(context:project({
      base_commit = commit.hash, current_commit = commit.hash,
      role = WheelContext.Role.CODING,
      p0_max_bytes = 1, p1_max_bytes = 1, p2_max_bytes = 1,
      p3_max_bytes = 1, p4_max_bytes = 1, max_budget_bytes = 5,
    }))
    assert(#projection.omitted_references > 0)
    assert(projection.omitted_references[1].reason == "byte_budget")
  end)

  run_test("Context projections: semantic deltas compare structured records", function()
    local context = fixed_context()
    local first = assert(context:commit_checkpoint({
      author = "fixture", message = "delta root", timestamp_ms = 1700000000000,
    }))
    assert(context:put_slot("tasks/TASK-1/plan", "updated").success)
    local second = assert(context:commit_checkpoint({
      author = "fixture", message = "delta update", timestamp_ms = 1700000001000,
    }))
    local delta = assert(context:semantic_delta(first.hash, second.hash, {
      base_records = { { ref = "record/a", category = "tasks", value = "same" } },
      current_records = { { ref = "record/a", category = "tasks", value = "changed" } },
    }))
    assert(delta.count == 1)
    assert(delta.modified[1].ref == "slot:tasks/TASK-1/plan")
    assert(delta.records.modified[1].ref == "record/a")
    assert(delta.provenance.source_commit == second.hash)
    delta.modified[1].after.content = "caller mutation"
    assert(context:get_commit(second.hash).slots["tasks/TASK-1/plan"].content == "updated",
      "semantic delta must not expose mutable commit storage")
  end)

  run_test("Context projections: caller records require role and explicit scope eligibility", function()
    local context = fixed_context()
    local commit = assert(context:commit_checkpoint({
      author = "fixture", message = "eligibility fixture", timestamp_ms = 1700000000000,
    }))
    local projection = assert(context:project({
      base_commit = commit.hash, current_commit = commit.hash,
      role = WheelContext.Role.CODING,
      task_id = "TASK-1", session_id = "SESSION-1",
      relevant_scopes = { "workspace" },
      records = {
        { ref = "workspace/task", category = "project", task_id = "TASK-1", value = "allowed" },
        { ref = "source/matching-session", category = "source", session_id = "SESSION-1", value = "source leak" },
        { ref = "private/raw", category = "private", session_id = "SESSION-1", value = "private leak" },
      },
      recent_records = {
        { ref = "diagnostics/out-of-scope", category = "diagnostics", value = "diagnostic leak" },
      },
    }))
    assert(projection.canonical_bytes:find("allowed", 1, true))
    assert(not projection.canonical_bytes:find("source leak", 1, true))
    assert(not projection.canonical_bytes:find("private leak", 1, true))
    assert(not projection.canonical_bytes:find("diagnostic leak", 1, true))
    assert(#projection.omitted_references >= 2)
  end)

  run_test("Context projections: forbidden slot prefixes never enter project knowledge", function()
    local context = fixed_context()
    assert(context:put_slot("transcript/raw", "transcript leak").success)
    assert(context:put_slot("provider-cache/raw", "cache leak").success)
    assert(context:put_slot("bittyd/raw", "daemon leak").success)
    assert(context:put_slot("lifecycle/panel", "lifecycle leak").success)
    local commit = assert(context:commit_checkpoint({
      author = "fixture", message = "boundary fixture", timestamp_ms = 1700000000000,
    }))
    local projection = assert(context:project({
      base_commit = commit.hash, current_commit = commit.hash,
      role = WheelContext.Role.CODING,
    }))
    assert(not projection.canonical_bytes:find("transcript leak", 1, true))
    assert(not projection.canonical_bytes:find("cache leak", 1, true))
    assert(not projection.canonical_bytes:find("daemon leak", 1, true))
    assert(not projection.canonical_bytes:find("lifecycle leak", 1, true))
    assert(#projection.omitted_references >= 4)
  end)

  run_test("Context projections: identical caller records ignore generated provenance", function()
    local context = fixed_context()
    local first = assert(context:commit_checkpoint({
      author = "fixture", message = "provenance root", timestamp_ms = 1700000000000,
    }))
    local second = assert(context:commit_checkpoint({
      author = "fixture", message = "provenance child", timestamp_ms = 1700000001000,
    }))
    local delta = assert(context:semantic_delta(first.hash, second.hash, {
      base_records = { { ref = "record/a", category = "project", value = "same" } },
      current_records = { { ref = "record/a", category = "project", value = "same" } },
    }))
    assert(#delta.records.modified == 0)
    assert(#delta.records.unchanged == 1)
  end)

  run_test("Context projections: malformed records, scopes, and values fail closed", function()
    local context = fixed_context()
    local commit = assert(context:commit_checkpoint({
      author = "fixture", message = "validation fixture", timestamp_ms = 1700000000000,
    }))
    local base = { base_commit = commit.hash, current_commit = commit.hash,
      role = WheelContext.Role.CODING }
    assert_projection_error(context, { base_commit = commit.hash, current_commit = commit.hash,
      role = WheelContext.Role.CODING, records = { [2] = { ref = "a", category = "project" } } }, "sparse records")
    assert_projection_error(context, { base_commit = commit.hash, current_commit = commit.hash,
      role = WheelContext.Role.CODING, recent_records = { "not a record" } }, "non-table recent record")
    local cyclic = { ref = "cycle", category = "project" }; cyclic.self = cyclic
    assert_projection_error(context, { base_commit = commit.hash, current_commit = commit.hash,
      role = WheelContext.Role.CODING, records = { cyclic } }, "cyclic record")
    assert_projection_error(context, { base_commit = commit.hash, current_commit = commit.hash,
      role = WheelContext.Role.CODING, scopes = { 42 } }, "non-string scope")
    local delta, delta_err = context:semantic_delta(commit.hash, commit.hash,
      { base_records = "not an array" })
    assert(delta == nil and delta_err.code == "E_PROJECTION_INVALID")
    assert(base.role == WheelContext.Role.CODING)
  end)

  run_test("Context projections: zero and small budgets bound returned bytes", function()
    local context = fixed_context()
    local commit = assert(context:commit_checkpoint({
      author = "fixture", message = "budget boundary", timestamp_ms = 1700000000000,
    }))
    local zero = assert(context:project({
      base_commit = commit.hash, current_commit = commit.hash,
      role = WheelContext.Role.CODING,
      p0_max_bytes = 0, p1_max_bytes = 0, p2_max_bytes = 0,
      p3_max_bytes = 0, p4_max_bytes = 0, max_budget_bytes = 0,
    }))
    assert(zero.total_bytes == 0 and #zero.canonical_bytes == 0)
    local small = assert(context:project({
      base_commit = commit.hash, current_commit = commit.hash,
      role = WheelContext.Role.CODING,
      p0_max_bytes = 1, p1_max_bytes = 1, p2_max_bytes = 1,
      p3_max_bytes = 1, p4_max_bytes = 1, max_budget_bytes = 5,
      records = { { ref = "workspace/large", category = "project", value = string.rep("x", 1000) } },
    }))
    assert(small.total_bytes <= small.max_budget_bytes)
    assert(not small.canonical_bytes:find(string.rep("x", 100), 1, true))
    assert(#small.omitted_references > 0)
  end)
end
