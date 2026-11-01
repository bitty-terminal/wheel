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
          { ref = "tasks/TASK-1/record", category = "tasks", task_id = "TASK-1", value = "deliverable" },
          { ref = "code/unrelated", category = "source", task_id = "OTHER", value = "unrelated" },
        },
        recent_records = {
          { ref = "diagnostics/tail-new", category = "diagnostics", timestamp_ms = 2, value = "new" },
          { ref = "diagnostics/tail-old", category = "diagnostics", timestamp_ms = 1, value = "old" },
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
      assert(not projection.canonical_bytes:find("code/unrelated", 1, true),
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
        { ref = "code/tail-source", category = "source", timestamp_ms = 1, value = "source" },
      },
    }))
    assert(projection.canonical_bytes:find("docs/guide", 1, true))
    assert(not projection.canonical_bytes:find("code/src/main.lua", 1, true),
      "documentation view must exclude unrelated source code")
      assert(not projection.canonical_bytes:find("code/tail-source", 1, true),
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
      base_records = { { ref = "tasks/TASK-1/record", category = "tasks", value = "same" } },
      current_records = { { ref = "tasks/TASK-1/record", category = "tasks", value = "changed" } },
    }))
    assert(delta.count == 1)
    assert(delta.modified[1].ref == "slot:tasks/TASK-1/plan")
    assert(delta.records.modified[1].ref == "tasks/TASK-1/record")
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
      base_records = { { ref = "workspace/record", category = "project", value = "same" } },
      current_records = { { ref = "workspace/record", category = "project", value = "same" } },
    }))
    assert(#delta.records.modified == 0)
    assert(#delta.records.unchanged == 1)
    assert(delta.records.unchanged[1].ref == "workspace/record")
  end)

  run_test("Context projections: malformed records, scopes, and values fail closed", function()
    local context = fixed_context()
    local commit = assert(context:commit_checkpoint({
      author = "fixture", message = "validation fixture", timestamp_ms = 1700000000000,
    }))
    local base = { base_commit = commit.hash, current_commit = commit.hash,
      role = WheelContext.Role.CODING }
    assert_projection_error(context, { base_commit = commit.hash, current_commit = commit.hash,
      role = WheelContext.Role.CODING, records = { [2] = { ref = "workspace/a", category = "project" } } }, "sparse records")
    assert_projection_error(context, { base_commit = commit.hash, current_commit = commit.hash,
      role = WheelContext.Role.CODING, recent_records = { "not a record" } }, "non-table recent record")
    local cyclic = { ref = "workspace/cycle", category = "project" }; cyclic.self = cyclic
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

  run_test("Context projections: category is derived from the record reference", function()
    local context = fixed_context()
    local commit = assert(context:commit_checkpoint({
      author = "fixture", message = "category authority", timestamp_ms = 1700000000000,
    }))
    local projection = assert(context:project({
      base_commit = commit.hash, current_commit = commit.hash,
      role = WheelContext.Role.CODING, relevant_scopes = { "source" },
      recent_records = {
        { ref = "private/raw", category = "source", value = "spoofed source" },
      },
    }))
    assert(not projection.canonical_bytes:find("spoofed source", 1, true))
    assert(#projection.omitted_references > 0)

    local transition = assert(context:project({
      base_commit = commit.hash, current_commit = commit.hash,
      role = WheelContext.Role.CODING, relevant_scopes = { "workspace" },
      base_records = { { ref = "private/raw", category = "private", value = "SECRET_OLD" } },
      records = { { ref = "workspace/record", category = "project", value = "new" } },
    }))
    assert(not transition.canonical_bytes:find("SECRET_OLD", 1, true))
    assert_projection_error(context, {
      base_commit = commit.hash, current_commit = commit.hash,
      role = WheelContext.Role.CODING, relevant_scopes = { "workspace" },
      base_records = { { ref = "workspace/record", category = "private", value = "SECRET_BEFORE" } },
      records = { { ref = "workspace/record", category = "project", value = "allowed after" } },
    }, "category spoof transition")
  end)

  run_test("Context projections: scalar options and budget caps fail closed", function()
    local context = fixed_context()
    local commit = assert(context:commit_checkpoint({
      author = "fixture", message = "scalar options", timestamp_ms = 1700000000000,
    }))
    assert_projection_error(context, { current_commit = commit.hash, task_id = {} }, "table task_id")
    assert_projection_error(context, { current_commit = commit.hash, session_id = {} }, "table session_id")
    assert_projection_error(context, { current_commit = commit.hash, confidence = 2 }, "confidence above one")
    assert_projection_error(context, { current_commit = commit.hash, confidence = 0 / 0 }, "non-finite confidence")
    assert_projection_error(context, { current_commit = commit.hash, max_budget_bytes = 64 * 1024 + 1 },
      "total budget above policy ceiling")
    assert_projection_error(context, { current_commit = commit.hash, p0_max_bytes = 64 * 1024 + 1 },
      "layer budget above policy ceiling")
  end)

  run_test("Context projections: requested budget bounds candidate work", function()
    local context = fixed_context()
    local commit = assert(context:commit_checkpoint({
      author = "fixture", message = "work bound", timestamp_ms = 1700000000000,
    }))
    local nested = {}
    local cursor = nested
    for index = 1, 128 do
      cursor.next = { value = index }
      cursor = cursor.next
    end
    assert_projection_error(context, {
      base_commit = commit.hash, current_commit = commit.hash,
      role = WheelContext.Role.CODING,
      p0_max_bytes = 0, p1_max_bytes = 0, p2_max_bytes = 1,
      p3_max_bytes = 0, p4_max_bytes = 0, max_budget_bytes = 1,
      records = { { ref = "workspace/large", category = "project", value = nested } },
    }, "one-byte candidate work")
  end)

  run_test("Context projections: candidate work uses the largest active layer budget", function()
    local context = fixed_context()
    local first = assert(context:commit_checkpoint({
      author = "fixture", message = "large-layer work root", timestamp_ms = 1700000000000,
    }))
    assert(context:put_slot("workspace/large-layer", "updated").success)
    local second = assert(context:commit_checkpoint({
      author = "fixture", message = "large-layer work update", timestamp_ms = 1700000001000,
    }))
    local projection = assert(context:project({
      base_commit = first.hash, current_commit = second.hash,
      role = WheelContext.Role.CODING,
      p0_max_bytes = 0, p1_max_bytes = 0, p2_max_bytes = 0,
      p3_max_bytes = 1024, p4_max_bytes = 0, max_budget_bytes = 1024,
      base_records = { { ref = "workspace/record", category = "project", value = "old" } },
      records = { { ref = "workspace/record", category = "project", value = "new" } },
    }))
    local saw_record = false
    for _, record in ipairs(projection.layers.P3.records) do
      if record.ref == "workspace/record" then saw_record = true end
    end
    assert(saw_record)
  end)

  run_test("Context projections: task records take precedence over session tail", function()
    local context = fixed_context()
    local commit = assert(context:commit_checkpoint({
      author = "fixture", message = "partition fixture", timestamp_ms = 1700000000000,
    }))
    local projection = assert(context:project({
      base_commit = commit.hash, current_commit = commit.hash,
      role = WheelContext.Role.CODING, task_id = "TASK-1", session_id = "SESSION-1",
      records = {
        { ref = "workspace/both", category = "project", task_id = "TASK-1", session_id = "SESSION-1", value = "one copy" },
      },
    }))
    local p2_count, p4_count = 0, 0
    for _, record in ipairs(projection.layers.P2.records) do
      if record.ref == "workspace/both" then p2_count = p2_count + 1 end
    end
    for _, record in ipairs(projection.layers.P4.records) do
      if record.ref == "workspace/both" then p4_count = p4_count + 1 end
    end
    assert(p2_count == 1 and p4_count == 0)
  end)

  run_test("Context projections: task/session refs are disjoint across collections", function()
    local context = fixed_context()
    local commit = assert(context:commit_checkpoint({
      author = "fixture", message = "collection deduplication", timestamp_ms = 1700000000000,
    }))
    local projection = assert(context:project({
      base_commit = commit.hash, current_commit = commit.hash,
      role = WheelContext.Role.CODING, task_id = "TASK-1", session_id = "SESSION-1",
      records = {
        { ref = "workspace/shared", category = "project", task_id = "TASK-1", session_id = "SESSION-1", value = "P2 copy" },
      },
      recent_records = {
        { ref = "workspace/shared", category = "project", task_id = "TASK-1", session_id = "SESSION-1", value = "P4 duplicate" },
        { ref = "workspace/session-only", category = "project", session_id = "SESSION-1", value = "P4 only" },
      },
    }))
    local p2_shared, p4_shared, p4_only = 0, 0, 0
    for _, record in ipairs(projection.layers.P2.records) do
      if record.ref == "workspace/shared" then p2_shared = p2_shared + 1 end
    end
    for _, record in ipairs(projection.layers.P4.records) do
      if record.ref == "workspace/shared" then p4_shared = p4_shared + 1 end
      if record.ref == "workspace/session-only" then p4_only = p4_only + 1 end
    end
    assert(p2_shared == 1 and p4_shared == 0 and p4_only == 1)
    assert(not projection.canonical_bytes:find("P4 duplicate", 1, true))
  end)

  run_test("Context projections: malformed commit tables fail with typed errors", function()
    local context = fixed_context()
    local commit = assert(context:commit_checkpoint({
      author = "fixture", message = "commit table validation", timestamp_ms = 1700000000000,
    }))
    assert_projection_error(context, { current_commit = { slots = "bad" } }, "malformed current commit table")
    local delta, err = context:semantic_delta({ slots = "bad" }, commit.hash)
    assert(delta == nil and err.code == "E_PROJECTION_INVALID")
    local valid_table = context:get_commit(commit.hash)
    assert(context:project({ current_commit = valid_table }).current_commit == commit.hash)
    valid_table.slots["workspace/project"].content = "forged projection state"
    assert_projection_error(context, { current_commit = valid_table }, "mutated immutable commit copy")
    assert(context:get_commit(commit.hash).slots["workspace/project"].content == "Wheel")
  end)

  run_test("Context projections: explicit unresolved bases fail with typed errors", function()
    local context = fixed_context()
    local commit = assert(context:commit_checkpoint({
      author = "fixture", message = "base resolution", timestamp_ms = 1700000000000,
    }))
    assert_projection_error(context, {
      base_commit = "missing-base", current_commit = commit.hash,
    }, "unresolved explicit base")
    assert(context:project({ current_commit = commit.hash }).base_commit == commit.hash)
  end)

  run_test("Context projections: deeply nested records fail before copy or encoding", function()
    local context = fixed_context()
    local commit = assert(context:commit_checkpoint({
      author = "fixture", message = "depth boundary", timestamp_ms = 1700000000000,
    }))
    local nested = {}
    local cursor = nested
    for _ = 1, 64 do
      cursor.next = {}
      cursor = cursor.next
    end
    assert_projection_error(context, {
      current_commit = commit.hash,
      records = { { ref = "workspace/deep", category = "project", value = nested } },
    }, "deeply nested record")
  end)

  run_test("Context projections: timestamp and revision fields are finite numbers", function()
    local context = fixed_context()
    local commit = assert(context:commit_checkpoint({
      author = "fixture", message = "timestamp validation", timestamp_ms = 1700000000000,
    }))
    local malformed_values = { "text", {}, 0 / 0, math.huge }
    for _, value in ipairs(malformed_values) do
      assert_projection_error(context, {
        current_commit = commit.hash, role = WheelContext.Role.CODING,
        recent_records = { { ref = "diagnostics/bad-time", category = "diagnostics", timestamp_ms = value } },
      }, "malformed timestamp")
      assert_projection_error(context, {
        current_commit = commit.hash, role = WheelContext.Role.CODING,
        recent_records = { { ref = "diagnostics/bad-revision", category = "diagnostics", revision = value } },
      }, "malformed revision")
    end
  end)

  run_test("Context projections: agent identity and fork lineage stay structured references", function()
    local context = fixed_context()
    local commit = assert(context:commit_checkpoint({
      author = "fixture", message = "identity provenance", timestamp_ms = 1700000000000,
    }))
    local options = {
      current_commit = commit.hash,
      role = WheelContext.Role.REVIEWER,
      agent_id = "agent-fork-1",
      role_binding = { role = "reviewer", binding_id = "role-binding:agent-fork-1:2", policy_generation = 2 },
      lineage = {
        forked_from_agent = "agent-parent",
        forked_from_session = "session-parent",
        base_context_commit = commit.hash,
        reason = "independent verification",
      },
    }
    local projection = assert(context:project(options))
    assert(projection.identity.agent_id == "agent-fork-1")
    assert(projection.identity.role_binding.policy_generation == 2)
    assert(projection.identity.lineage.forked_from_agent == "agent-parent")
    assert(projection.identity.lineage.base_context_commit == commit.hash)
    assert(projection.provenance.agent_id == "agent-fork-1")
    assert(projection.provenance.policy_generation == 2)
    local replay = assert(context:project(options))
    assert(replay.canonical_bytes == projection.canonical_bytes)
    assert(not projection.canonical_bytes:find("prompt", 1, true))
    assert(not projection.canonical_bytes:find("transcript", 1, true))

    assert_projection_error(context, {
      current_commit = commit.hash,
      lineage = { forked_from_agent = "parent", transcript = "not a reference" },
    }, "unknown lineage field")
    assert_projection_error(context, {
      current_commit = commit.hash,
      lineage = { base_context_commit = commit.hash },
    }, "lineage without a source agent")
    assert_projection_error(context, {
      current_commit = commit.hash,
      agent_id = "agent\ninjected",
    }, "control characters in agent identity")
    assert_projection_error(context, {
      current_commit = commit.hash,
      role_binding = { role = "reviewer", policy_generation = 0 },
    }, "non-positive policy generation")
    assert_projection_error(context, {
      current_commit = commit.hash,
      role_binding = { role = "reviewer", binding_id = "id", extra = "field" },
    }, "unknown role binding field")
  end)
end
