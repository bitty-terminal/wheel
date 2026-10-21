-- Focused unit tests for WheelContext versioned snapshots (CTX-0026).
--
-- The shared test runner in `tests/test_wheel.lua` owns PASS/FAIL reporting.
-- This file returns one function that accepts that runner, so the snapshot
-- coverage stays readable without duplicating the suite harness.

local WheelContext = require("wheel.context")
local WheelErrors = require("wheel.errors")
local WheelHost = require("wheel.host")

local function deep_copy(value, seen)
  if type(value) ~= "table" then
    return value
  end
  seen = seen or {}
  if seen[value] then
    return seen[value]
  end
  local copy = {}
  seen[value] = copy
  for key, item in pairs(value) do
    copy[deep_copy(key, seen)] = deep_copy(item, seen)
  end
  return copy
end

local function count_keys(map)
  local count = 0
  for _ in pairs(map) do
    count = count + 1
  end
  return count
end

local function assert_deep_equal(actual, expected, path)
  path = path or "value"
  assert(type(actual) == type(expected),
    string.format("%s type mismatch: %s vs %s", path, type(actual), type(expected)))
  if type(actual) ~= "table" then
    assert(actual == expected,
      string.format("%s mismatch: %s vs %s", path, tostring(actual), tostring(expected)))
    return
  end
  assert(count_keys(actual) == count_keys(expected),
    path .. " key count mismatch")
  for key, value in pairs(actual) do
    assert_deep_equal(value, expected[key], path .. "." .. tostring(key))
  end
end

local function with_fixed_clock(fn)
  local backend = WheelHost.backend
  local saved_now = backend.now
  backend.now = function()
    return 1700000000
  end
  local ok, err = pcall(fn)
  backend.now = saved_now
  if not ok then
    error(err, 0)
  end
end

local function build_fixture()
  local fixture
  with_fixed_clock(function()
    local ctx = WheelContext.new()
    assert(ctx:put_slot("workspace/project", "Wheel Harness").success)
    assert(ctx:put_slot("decisions/runtime", "Pure Lua 5.1").success)
    local c1 = ctx:commit_checkpoint({
      author = "commander",
      task_id = "CTX-1",
      message = "root checkpoint",
      timestamp_ms = 1700000000000,
      rationale = { goal = "root", confidence = 0.9 },
    })
    assert(ctx:create_branch("experiment"))
    assert(ctx:checkout("experiment"))
    assert(ctx:put_slot("scratch/idea", "speculative").success)
    local c2 = ctx:commit_checkpoint({
      author = "worker",
      task_id = "CTX-2",
      message = "experiment checkpoint",
      timestamp_ms = 1700000001000,
      rationale = "try it",
    })
    assert(ctx:checkout("main"))
    fixture = { ctx = ctx, c1 = c1, c2 = c2 }
  end)
  return fixture
end

local function expect_snapshot_error(snapshot, label)
  local valid, validate_err = WheelContext.validate_snapshot(snapshot)
  assert(valid == nil, label .. " must be rejected by validate_snapshot")
  assert(WheelErrors.is_typed(validate_err),
    label .. " must return a typed wheel.errors cause")
  assert(validate_err.class == "validation" and validate_err.code == "E_SNAPSHOT_INVALID",
    label .. " must use validation/E_SNAPSHOT_INVALID, got "
      .. tostring(validate_err.class) .. "/" .. tostring(validate_err.code))

  local ctx, import_err = WheelContext.import_snapshot(snapshot)
  assert(ctx == nil, label .. " must not construct a context")
  assert(WheelErrors.is_typed(import_err) and import_err.code == "E_SNAPSHOT_INVALID",
    label .. " import must return the typed snapshot cause")
  return validate_err
end

local function reject_mutation(snapshot, label, mutate)
  local copy = deep_copy(snapshot)
  mutate(copy)
  return expect_snapshot_error(copy, label)
end

return function(run_test)
  run_test("WheelContext snapshots: empty context round-trips deterministically", function()
    local ctx = WheelContext.new()
    local snapshot = assert(ctx:export_snapshot())

    assert(snapshot.format == WheelContext.SNAPSHOT_FORMAT)
    assert(snapshot.version == WheelContext.SNAPSHOT_VERSION)
    assert(count_keys(snapshot.slots) == 0)
    assert(snapshot.tree_hash == ctx:tree_hash())
    assert(snapshot.head == "refs/heads/main")
    assert(count_keys(snapshot.refs) == 0)
    assert(count_keys(snapshot.commits) == 0)
    assert(#snapshot.reflog == 0)
    assert(#snapshot.bus_history == 0)

    assert(WheelContext.validate_snapshot(snapshot) == true)
    local restored = assert(WheelContext.import_snapshot(snapshot))
    assert(restored:current_branch() == "main")
    assert(restored:head_commit_hash() == nil)
    assert(restored:tree_hash() == snapshot.tree_hash)
    assert(#restored:list_slots() == 0)

    local first = assert(WheelContext.canonical_snapshot(snapshot))
    local second = assert(WheelContext.canonical_snapshot(assert(restored:export_snapshot())))
    assert(first == second, "empty snapshot round-trip must be canonical-byte stable")
  end)

  run_test("WheelContext snapshots: slots, commits, refs, head, reflog, and bus history round-trip", function()
    local fixture = build_fixture()
    local ctx = fixture.ctx
    local snapshot = assert(ctx:export_snapshot())

    assert(snapshot.slots["workspace/project"].content == "Wheel Harness")
    assert(snapshot.slots["workspace/project"].kind == "workspace")
    assert(snapshot.slots["workspace/project"].version == 1)
    assert(snapshot.slots["workspace/project"].size_bytes == #"Wheel Harness")
    assert(snapshot.slots["workspace/project"].hash
      == WheelContext.compute_hash("Wheel Harness"))
    assert(snapshot.tree_hash == ctx:tree_hash())
    assert(snapshot.head == "refs/heads/main")
    assert(snapshot.refs["refs/heads/main"] == fixture.c1.hash)
    assert(snapshot.refs["refs/heads/experiment"] == fixture.c2.hash)
    assert(snapshot.commits[fixture.c1.hash].message == "root checkpoint")
    assert(snapshot.commits[fixture.c1.hash].rationale.goal == "root")
    assert(snapshot.commits[fixture.c2.hash].parent_hashes[1] == fixture.c1.hash)
    assert(snapshot.commits[fixture.c2.hash].rationale == "try it")
    assert(#snapshot.reflog >= 4, "fixture must carry a reflog")
    assert(#snapshot.bus_history > 0 and #snapshot.bus_history <= WheelContext.MAX_BUS_HISTORY,
      "fixture must carry bounded bus history")

    local restored = assert(WheelContext.import_snapshot(snapshot))
    assert(restored:current_branch() == "main")
    assert(restored:head_commit_hash() == fixture.c1.hash)
    assert(restored:tree_hash() == snapshot.tree_hash)
    assert(restored:get_slot("workspace/project").content == "Wheel Harness")
    assert(restored:get_slot("workspace/project").version == 1)
    assert(restored:get_slot("decisions/runtime").content == "Pure Lua 5.1")
    assert(not restored:get_slot("scratch/idea").found)
    assert(restored:get_commit(fixture.c1.hash).rationale.goal == "root")
    assert(restored:get_commit(fixture.c2.hash).message == "experiment checkpoint")
    assert_deep_equal(restored._reflog, snapshot.reflog, "reflog")
    assert_deep_equal(restored.bus:history(), snapshot.bus_history, "bus_history")

    local branches = restored:list_branches()
    assert(#branches == 2)
    assert(branches[1].name == "experiment" and branches[1].hash == fixture.c2.hash)
    assert(branches[2].name == "main" and branches[2].hash == fixture.c1.hash
      and branches[2].is_head == true)

    local first = assert(WheelContext.canonical_snapshot(snapshot))
    local second = assert(WheelContext.canonical_snapshot(assert(restored:export_snapshot())))
    assert(first == second, "non-empty snapshot round-trip must be canonical-byte stable")

    -- Restored commits, slots, and refs still drive the normal context API.
    assert(restored:checkout("experiment") == true)
    assert(restored:current_branch() == "experiment")
    assert(restored:head_commit_hash() == fixture.c2.hash)
    assert(restored:get_slot("scratch/idea").content == "speculative")
  end)

  run_test("WheelContext snapshots: detached HEAD and branch-ref reflog endpoints round-trip", function()
    local fixture = build_fixture()
    local ctx = fixture.ctx
    assert(ctx:checkout("experiment"))
    assert(ctx:checkout(fixture.c2.hash))
    assert(ctx:current_branch() == "(detached)")
    assert(ctx:put_slot("scratch/detached", "detached work").success)
    local detached_commit = ctx:commit_checkpoint({
      author = "detached-worker",
      message = "detached checkpoint",
      timestamp_ms = 1700000002000,
    })

    local snapshot = assert(ctx:export_snapshot())
    assert(snapshot.head == detached_commit.hash)
    local saw_branch_endpoint = false
    local saw_hash_ref = false
    for _, entry in ipairs(snapshot.reflog) do
      if entry.from_hash == "refs/heads/experiment" then
        saw_branch_endpoint = true
      end
      if entry.ref == detached_commit.hash then
        saw_hash_ref = true
      end
    end
    assert(saw_branch_endpoint,
      "detached checkout must preserve its branch-ref reflog endpoint")
    assert(saw_hash_ref,
      "a commit on detached HEAD must preserve its hash-shaped reflog ref")

    local restored = assert(WheelContext.import_snapshot(snapshot))
    assert(restored:current_branch() == "(detached)")
    assert(restored:head_commit_hash() == detached_commit.hash)
    assert(restored:get_slot("scratch/detached").content == "detached work")
    assert(WheelContext.canonical_snapshot(snapshot)
      == WheelContext.canonical_snapshot(assert(restored:export_snapshot())))
  end)

  run_test("WheelContext snapshots: canonical bytes ignore hash-table insertion order", function()
    local function build_and_export(order)
      local snapshot
      with_fixed_clock(function()
        local ctx = WheelContext.new()
        for _, name in ipairs(order) do
          assert(ctx:put_slot(name, "value:" .. name).success)
        end
        snapshot = assert(ctx:export_snapshot())
      end)
      -- Bus history is chronological; clear it so only map ordering differs.
      snapshot.bus_history = {}
      return snapshot
    end

    local first = build_and_export({ "workspace/a", "workspace/b", "decisions/c" })
    local second = build_and_export({ "decisions/c", "workspace/a", "workspace/b" })
    assert(first.tree_hash == second.tree_hash)
    assert(WheelContext.canonical_snapshot(first) == WheelContext.canonical_snapshot(second),
      "slot insertion order must not affect canonical bytes")

    local fixture = build_fixture()
    local snapshot = assert(fixture.ctx:export_snapshot())
    local reordered = deep_copy(snapshot)

    local slot_names = {}
    for name in pairs(reordered.slots) do
      slot_names[#slot_names + 1] = name
    end
    table.sort(slot_names)
    local slots = {}
    for index = #slot_names, 1, -1 do
      slots[slot_names[index]] = reordered.slots[slot_names[index]]
    end
    reordered.slots = slots

    local commit_hashes = {}
    for hash in pairs(reordered.commits) do
      commit_hashes[#commit_hashes + 1] = hash
    end
    table.sort(commit_hashes)
    local commits = {}
    for index = #commit_hashes, 1, -1 do
      commits[commit_hashes[index]] = reordered.commits[commit_hashes[index]]
    end
    reordered.commits = commits

    local refs = {}
    local ref_names = { "refs/heads/main", "refs/heads/experiment" }
    for index = #ref_names, 1, -1 do
      refs[ref_names[index]] = reordered.refs[ref_names[index]]
    end
    reordered.refs = refs

    assert(WheelContext.canonical_snapshot(reordered)
      == WheelContext.canonical_snapshot(snapshot),
      "reordered slot/commit/ref maps must canonicalize identically")
  end)

  run_test("WheelContext snapshots: import deep-copies and never mutates the source", function()
    local fixture = build_fixture()
    local snapshot = assert(fixture.ctx:export_snapshot())
    local before = assert(WheelContext.canonical_snapshot(snapshot))

    local restored = assert(WheelContext.import_snapshot(snapshot))
    assert(restored:put_slot("workspace/project", "mutated restored context").success)
    assert(restored:create_branch("mutant"))
    assert(WheelContext.canonical_snapshot(snapshot) == before,
      "mutating the restored context must not mutate the source snapshot")

    local original_content = snapshot.slots["decisions/runtime"].content
    snapshot.slots["decisions/runtime"].content = "tampered after import"
    assert(restored:get_slot("decisions/runtime").content == original_content,
      "restored slots must not alias the source snapshot")
    snapshot.commits[fixture.c1.hash].message = "tampered after import"
    assert(restored:get_commit(fixture.c1.hash).message == "root checkpoint",
      "restored commits must not alias the source snapshot")

    local good = assert(fixture.ctx:export_snapshot())
    local bad = deep_copy(good)
    bad.version = 99
    local bad_before = deep_copy(bad)
    local failed, err = WheelContext.import_snapshot(bad)
    assert(failed == nil and WheelErrors.is_typed(err)
      and err.code == "E_SNAPSHOT_INVALID", "failed import must be typed and object-free")
    assert_deep_equal(bad, bad_before, "rejected snapshot input")

    local recovered = assert(WheelContext.import_snapshot(good))
    assert(recovered:get_slot("workspace/project").content == "Wheel Harness",
      "a failed import must not poison a later valid import")
  end)

  run_test("WheelContext snapshots: tampered and partial input fails closed", function()
    local fixture = build_fixture()
    local snapshot = assert(fixture.ctx:export_snapshot())

    reject_mutation(snapshot, "unknown format", function(copy)
      copy.format = "wheel-context-snapshot/2"
    end)
    reject_mutation(snapshot, "unknown version", function(copy)
      copy.version = 2
    end)
    reject_mutation(snapshot, "non-numeric version", function(copy)
      copy.version = "1"
    end)
    reject_mutation(snapshot, "missing slots", function(copy)
      copy.slots = nil
    end)
    reject_mutation(snapshot, "unknown top-level field", function(copy)
      copy.extra = true
    end)
    reject_mutation(snapshot, "missing head", function(copy)
      copy.head = nil
    end)

    reject_mutation(snapshot, "slot name/key mismatch", function(copy)
      copy.slots["workspace/project"].name = "workspace/other"
    end)
    reject_mutation(snapshot, "control character in slot name", function(copy)
      local slot = deep_copy(copy.slots["workspace/project"])
      slot.name = "bad\1name"
      copy.slots[slot.name] = slot
    end)
    reject_mutation(snapshot, "unknown slot kind", function(copy)
      copy.slots["workspace/project"].kind = "bogus"
    end)
    reject_mutation(snapshot, "slot kind/name mismatch", function(copy)
      copy.slots["workspace/project"].kind = "scratch"
    end)
    reject_mutation(snapshot, "slot hash mismatch", function(copy)
      copy.slots["workspace/project"].hash = string.rep("0", 64)
    end)
    reject_mutation(snapshot, "non-hex slot hash", function(copy)
      copy.slots["workspace/project"].hash = string.rep("A", 64)
    end)
    reject_mutation(snapshot, "slot size mismatch", function(copy)
      copy.slots["workspace/project"].size_bytes = 1
    end)
    reject_mutation(snapshot, "invalid slot version", function(copy)
      copy.slots["workspace/project"].version = 0
    end)
    reject_mutation(snapshot, "missing slot timestamp", function(copy)
      copy.slots["workspace/project"].updated_at_ms = nil
    end)
    reject_mutation(snapshot, "unknown slot field", function(copy)
      copy.slots["workspace/project"].extra = true
    end)

    reject_mutation(snapshot, "working tree hash mismatch", function(copy)
      copy.tree_hash = string.rep("a", 64)
    end)

    reject_mutation(snapshot, "malformed branch ref", function(copy)
      copy.refs["refs/heads/bad..name"] = fixture.c1.hash
    end)
    reject_mutation(snapshot, "ref to unknown commit", function(copy)
      copy.refs["refs/heads/main"] = string.rep("0", 64)
    end)

    reject_mutation(snapshot, "malformed head", function(copy)
      copy.head = "refs/heads/bad..head"
    end)
    reject_mutation(snapshot, "detached head to unknown commit", function(copy)
      copy.head = string.rep("0", 64)
    end)

    reject_mutation(snapshot, "commit hash mismatch", function(copy)
      copy.commits[fixture.c1.hash].message = "tampered"
    end)
    reject_mutation(snapshot, "commit tree hash mismatch", function(copy)
      copy.commits[fixture.c1.hash].tree_hash = copy.commits[fixture.c2.hash].tree_hash
    end)
    reject_mutation(snapshot, "commit key/hash mismatch", function(copy)
      copy.commits[fixture.c1.hash].hash = string.rep("0", 64)
    end)
    reject_mutation(snapshot, "unknown commit field", function(copy)
      copy.commits[fixture.c1.hash].extra = true
    end)

    reject_mutation(snapshot, "reflog unknown commit", function(copy)
      copy.reflog[1].to_hash = string.rep("0", 64)
    end)
    reject_mutation(snapshot, "reflog malformed ref", function(copy)
      copy.reflog[1].ref = "refs/heads/bad..ref"
    end)
    reject_mutation(snapshot, "reflog non-increasing index", function(copy)
      copy.reflog[2].index = copy.reflog[1].index
    end)

    reject_mutation(snapshot, "bus history function payload", function(copy)
      copy.bus_history[1].callback = function() end
    end)
    reject_mutation(snapshot, "bus history cycle", function(copy)
      local loop = {}
      loop.self = loop
      copy.bus_history[1].loop = loop
    end)
    reject_mutation(snapshot, "bus history missing timestamp", function(copy)
      copy.bus_history[1].timestamp_ms = nil
    end)
    reject_mutation(snapshot, "bus history exceeds bound", function(copy)
      copy.bus_history = {}
      for index = 1, WheelContext.MAX_BUS_HISTORY + 1 do
        copy.bus_history[index] = { type = "probe", timestamp_ms = index }
      end
    end)
  end)

  run_test("WheelContext snapshots: oversized content, total bound, and legacy limits fail closed", function()
    local fixture = build_fixture()
    local snapshot = assert(fixture.ctx:export_snapshot())

    assert(WheelContext.MAX_SLOT_CONTENT_BYTES == 16 * 1024 * 1024,
      "slot content limit must remain 16 MiB")
    assert(WheelContext.MAX_SNAPSHOT_BYTES == 64 * 1024 * 1024,
      "snapshot total bound must remain 64 MiB")

    reject_mutation(snapshot, "oversized slot content", function(copy)
      local slot = copy.slots["workspace/project"]
      slot.content = string.rep("x", WheelContext.MAX_SLOT_CONTENT_BYTES + 1)
      slot.size_bytes = #slot.content
    end)

    local saved_total = WheelContext.MAX_SNAPSHOT_BYTES
    WheelContext.MAX_SNAPSHOT_BYTES = 512
    local ok, err = WheelContext.validate_snapshot(snapshot)
    WheelContext.MAX_SNAPSHOT_BYTES = saved_total
    assert(ok == nil and WheelErrors.is_typed(err)
      and err.code == "E_SNAPSHOT_INVALID", "total bound must fail closed")
    assert(err.message:find("total", 1, true) ~= nil,
      "total-bound rejection must name the bound: " .. err.message)
  end)

  run_test("WheelContext snapshots: commit parent cycles and unknown parents fail closed", function()
    local fixture = build_fixture()
    local snapshot = assert(fixture.ctx:export_snapshot())

    local child = deep_copy(snapshot.commits[fixture.c1.hash])
    child.parent_hashes = { string.rep("f", 64) }
    local unknown_parent = deep_copy(snapshot)
    unknown_parent.commits[fixture.c1.hash] = child
    local err = expect_snapshot_error(unknown_parent, "unknown commit parent")
    assert(err.message:find("unknown parent", 1, true) ~= nil,
      "unknown-parent rejection must be explicit: " .. err.message)

    local left_hash = string.rep("a", 64)
    local right_hash = string.rep("b", 64)
    local left = deep_copy(snapshot.commits[fixture.c1.hash])
    left.hash = left_hash
    left.parent_hashes = { right_hash }
    local right = deep_copy(snapshot.commits[fixture.c1.hash])
    right.hash = right_hash
    right.parent_hashes = { left_hash }

    local cyclic = deep_copy(snapshot)
    cyclic.commits = { [left_hash] = left, [right_hash] = right }
    cyclic.refs = {}
    cyclic.head = "refs/heads/main"
    cyclic.reflog = {}
    cyclic.bus_history = {}
    err = expect_snapshot_error(cyclic, "commit parent cycle")
    assert(err.message:find("cycle", 1, true) ~= nil,
      "cycle rejection must be explicit: " .. err.message)
  end)

  run_test("WheelContext snapshots: non-ASCII slot names and content round-trip canonically", function()
    local ctx = WheelContext.new()
    local name = "workspace/caf\195\169"
    local content = "na\195\175ve\nvalue with \\ and \""
    assert(ctx:put_slot(name, content).success)
    local snapshot = assert(ctx:export_snapshot())
    assert(snapshot.tree_hash == ctx:tree_hash())

    local restored = assert(WheelContext.import_snapshot(snapshot))
    assert(restored:get_slot(name).content == content)
    assert(restored:tree_hash() == snapshot.tree_hash)
    local first = assert(WheelContext.canonical_snapshot(snapshot))
    local second = assert(WheelContext.canonical_snapshot(assert(restored:export_snapshot())))
    assert(first == second)
    assert(first:find("\\xc3", 1, true) ~= nil,
      "canonical bytes must escape non-ASCII bytes")
    assert(first:find("\\n", 1, true) ~= nil,
      "canonical bytes must escape newlines")
  end)

  run_test("WheelContext snapshots: stash, subscribers, and local budgets are not preserved", function()
    local fixture = build_fixture()
    local ctx = fixture.ctx
    assert(ctx:put_slot("scratch/wip", "work in progress").success)
    assert(ctx:stash_push("wip") ~= nil)
    ctx.bus:subscribe("peer", function() end)

    local snapshot = assert(ctx:export_snapshot())
    local restored = assert(WheelContext.import_snapshot(snapshot, {
      max_budget_bytes = 4096,
    }))
    assert(#restored:stash_list() == 0,
      "snapshot v1 must not claim to restore stash entries")
    assert(restored.bus:is_subscribed("peer") == false,
      "snapshot v1 must not restore bus subscribers")
    assert(restored.max_budget_bytes == 4096,
      "local budgets come from import options, not the snapshot")

    local defaults = assert(WheelContext.import_snapshot(snapshot))
    assert(defaults.max_budget_bytes == WheelContext.MAX_TOTAL_BUDGET_BYTES,
      "a snapshot without import options uses context defaults")
  end)
end
