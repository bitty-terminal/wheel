-- Focused unit tests for WheelContext versioned snapshots (CTX-0026).
--
-- The shared test runner in `tests/test_wheel.lua` owns PASS/FAIL reporting.
-- This file returns one function that accepts that runner, so the snapshot
-- coverage stays readable without duplicating the suite harness.

local WheelContext = require("wheel.context")
local WheelContextSnapshot = require("wheel.context_snapshot")
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

  run_test("WheelContext snapshots: bounded reflog wraps and round-trips", function()
    local ctx = WheelContext.new()
    local total = WheelContext.MAX_REFLOG + 2
    for index = 1, total do
      ctx:commit_checkpoint({
        message = "wrap-" .. index,
        timestamp_ms = 1700000000000 + index,
      })
    end
    local snapshot = assert(ctx:export_snapshot())
    assert(#snapshot.reflog == WheelContext.MAX_REFLOG)
    for index = 2, #snapshot.reflog do
      assert(snapshot.reflog[index].index > snapshot.reflog[index - 1].index,
        "producer must keep reflog indexes strictly increasing across the ring")
    end

    local restored = assert(WheelContext.import_snapshot(snapshot))
    restored:commit_checkpoint({
      message = "after-restore",
      timestamp_ms = 1700000009000,
    })
    local after = assert(restored:export_snapshot())
    assert(#after.reflog == WheelContext.MAX_REFLOG)
    for index = 2, #after.reflog do
      assert(after.reflog[index].index > after.reflog[index - 1].index,
        "post-import commits must keep the reflog increasing")
    end
  end)

  run_test("WheelContext snapshots: version and reflog index maxima are enforced", function()
    local fixture = build_fixture()
    local snapshot = assert(fixture.ctx:export_snapshot())

    reject_mutation(snapshot, "slot version above maximum", function(copy)
      copy.slots["workspace/project"].version = WheelContext.MAX_SLOT_VERSION + 1
    end)
    reject_mutation(snapshot, "reflog index above maximum", function(copy)
      copy.reflog[1].index = WheelContext.MAX_REFLOG_INDEX + 1
    end)
    reject_mutation(snapshot, "huge slot version", function(copy)
      copy.slots["workspace/project"].version = 1e300
    end)
    reject_mutation(snapshot, "huge reflog index", function(copy)
      copy.reflog[1].index = 1e300
    end)

    local maxed = deep_copy(snapshot)
    maxed.slots["workspace/project"].version = WheelContext.MAX_SLOT_VERSION
    local count = #maxed.reflog
    for index, entry in ipairs(maxed.reflog) do
      entry.index = WheelContext.MAX_REFLOG_INDEX - count + index
    end
    local restored = assert(WheelContext.import_snapshot(maxed))
    assert(restored._slots["workspace/project"].version
      == WheelContext.MAX_SLOT_VERSION)
    local put_ok, put_err = restored:put_slot("workspace/project", "next")
    assert(put_ok == nil and put_err.error == "version_exhausted",
      "producer must fail closed at the slot version bound")

    restored:commit_checkpoint({
      message = "after-max-index",
      timestamp_ms = 1700000009000,
    })
    local after = assert(restored:export_snapshot())
    for index = 2, #after.reflog do
      assert(after.reflog[index].index > after.reflog[index - 1].index,
        "producer must repair an exhausted reflog index deterministically")
    end
  end)

  run_test("WheelContext snapshots: caller-supplied bus history is replaced, subscribers retained", function()
    local fixture = build_fixture()
    local snapshot = assert(fixture.ctx:export_snapshot())
    local bus = WheelContext.ContextBus.new()
    local notifications = {}
    bus:subscribe("peer", function(event)
      notifications[#notifications + 1] = event.type
    end)
    bus:publish({ type = "caller_history", timestamp_ms = 1 })

    local restored = assert(WheelContext.import_snapshot(snapshot, { bus = bus }))
    assert(restored.bus == bus, "import must keep the supplied bus identity")
    assert(bus:is_subscribed("peer") == true,
      "import must retain caller bus subscribers")
    local history = bus:history()
    assert_deep_equal(history, snapshot.bus_history, "bus_history")
    assert(#history == #snapshot.bus_history)
    for _, event in ipairs(history) do
      assert(event.type ~= "caller_history",
        "caller history must be replaced, not merged")
    end
    bus:publish({ type = "after_restore", timestamp_ms = 2 })
    assert(notifications[#notifications] == "after_restore",
      "retained subscribers must receive later events")
  end)

  run_test("WheelContext snapshots: oversized keys and key counts fail closed", function()
    local fixture = build_fixture()
    local snapshot = assert(fixture.ctx:export_snapshot())

    reject_mutation(snapshot, "oversized slot key", function(copy)
      local key = string.rep("s", WheelContext.MAX_SLOT_NAME_BYTES + 1)
      local slot = deep_copy(copy.slots["workspace/project"])
      slot.name = key
      copy.slots["workspace/project"] = nil
      copy.slots[key] = slot
    end)
    reject_mutation(snapshot, "oversized ref key", function(copy)
      local key = "refs/heads/" .. string.rep("r",
        WheelContext.MAX_REF_NAME_BYTES + 1)
      copy.refs[key] = fixture.c1.hash
    end)
    reject_mutation(snapshot, "oversized schema field key", function(copy)
      copy[string.rep("f", 300)] = true
    end)
    reject_mutation(snapshot, "oversized plain map key", function(copy)
      copy.bus_history[1][string.rep("p", 300)] = "value"
    end)

    local event = { type = "many_keys", timestamp_ms = 1 }
    for index = 1, 40 do
      event["key_" .. index] = index
    end
    local key_ctx = WheelContext.new()
    key_ctx.bus:publish(event)
    local saved_nodes = WheelContextSnapshot.MAX_VALUE_NODES
    WheelContextSnapshot.MAX_VALUE_NODES = 16
    local key_snapshot, key_err = key_ctx:export_snapshot()
    WheelContextSnapshot.MAX_VALUE_NODES = saved_nodes
    assert(key_snapshot == nil and WheelErrors.is_typed(key_err)
      and key_err.code == "E_SNAPSHOT_INVALID",
      "plain-data keys must count toward the node bound")
  end)

  run_test("WheelContext snapshots: option errors and live ref names are consistent", function()
    local fixture = build_fixture()
    local snapshot = assert(fixture.ctx:export_snapshot())
    local imported, import_err = WheelContext.import_snapshot(snapshot, "bad")
    assert(imported == nil and WheelErrors.is_typed(import_err)
      and import_err.code == "E_ARGS_INVALID",
      "invalid import options must be a typed argument failure")
    local exported, export_err = fixture.ctx:export_snapshot("bad")
    assert(exported == nil and WheelErrors.is_typed(export_err)
      and export_err.code == "E_ARGS_INVALID",
      "invalid export options must be a typed argument failure")

    local ctx = WheelContext.new()
    local too_long = string.rep("b", WheelContext.MAX_REF_NAME_BYTES + 1)
    local created, create_err = ctx:create_branch(too_long)
    assert(created == nil and create_err.error == "invalid_branch_name",
      "live branch creation must enforce the snapshot ref-name bound")
    assert(ctx:create_branch(string.rep("b", WheelContext.MAX_REF_NAME_BYTES)) == true,
      "a ref name at the snapshot bound must remain valid")
    assert(ctx:export_snapshot() ~= nil,
      "a live ref at the snapshot bound must export")
  end)

  run_test("WheelContext snapshots: stash content is redacted from bus history", function()
    local fixture = build_fixture()
    local ctx = fixture.ctx
    local stash_content = "stash-only-content-marker"
    assert(ctx:put_slot("scratch/wip", stash_content).success)
    assert(ctx:stash_push("wip") ~= nil)
    ctx.bus:subscribe("peer", function() end)

    local live_event
    for _, event in ipairs(ctx.bus:history()) do
      if event.type == "stash_pushed" then
        live_event = event
      end
    end
    assert(live_event and live_event.stash and live_event.stash.slots ~= nil,
      "the live bus must keep its full stash payload")

    local snapshot = assert(ctx:export_snapshot())
    local snapshot_event
    for _, event in ipairs(snapshot.bus_history) do
      if event.type == "stash_pushed" then
        snapshot_event = event
      end
    end
    assert(snapshot_event and snapshot_event.stash ~= nil,
      "snapshot must retain stash event metadata")
    assert(snapshot_event.stash.redacted == true,
      "snapshot stash events must be marked redacted")
    assert(snapshot_event.stash.slots == nil,
      "snapshot stash events must not carry the slot map")
    local canonical = assert(WheelContext.canonical_snapshot(snapshot))
    assert(canonical:find(stash_content, 1, true) == nil,
      "snapshot bytes must not leak stash slot content")

    local restored = assert(WheelContext.import_snapshot(snapshot, {
      max_budget_bytes = 4096,
    }))
    assert(#restored:stash_list() == 0,
      "snapshot v1 must not claim to restore stash entries")
    assert(restored.bus:is_subscribed("peer") == false,
      "snapshot v1 must not restore bus subscribers")
    assert(restored.max_budget_bytes == 4096,
      "local budgets come from import options, not the snapshot")
    for _, event in ipairs(restored.bus:history()) do
      if event.type == "stash_pushed" then
        assert(event.stash.redacted == true and event.stash.slots == nil,
          "restored stash events must remain redacted")
      end
    end
    assert(WheelContext.canonical_snapshot(snapshot)
      == WheelContext.canonical_snapshot(assert(restored:export_snapshot())),
      "redacted stash history must round-trip canonically")

    local defaults = assert(WheelContext.import_snapshot(snapshot))
    assert(defaults.max_budget_bytes == WheelContext.MAX_TOTAL_BUDGET_BYTES,
      "a snapshot without import options uses context defaults")

    assert(ctx:stash_pop(1) ~= nil)
    local popped = assert(ctx:export_snapshot())
    local popped_event
    for _, event in ipairs(popped.bus_history) do
      if event.type == "stash_popped" then
        popped_event = event
      end
    end
    assert(popped_event and popped_event.stash.redacted == true
      and popped_event.stash.slots == nil,
      "stash_popped events must also be redacted")
  end)

  run_test("WheelContext snapshots: import sanitizes unredacted stash bus events", function()
    local ctx = WheelContext.new()
    local marker = "crafted-stash-content-marker"
    assert(ctx:put_slot("scratch/wip", marker).success)
    local entry = assert(ctx:stash_push("wip"))
    -- Publish the matching pop event without applying it, so the marker exists
    -- only in stash payloads and never in the working slot tree.
    ctx.bus:publish({ type = "stash_popped", stash = entry })
    local snapshot = assert(ctx:export_snapshot())

    local crafted = deep_copy(snapshot)
    local smuggled_slots = {
      ["scratch/wip"] = {
        name = "scratch/wip",
        content = marker,
        hash = WheelContext.compute_hash(marker),
        version = 1,
        kind = "scratch",
        size_bytes = #marker,
        updated_at_ms = 1,
      },
    }
    local seen = {}
    for _, event in ipairs(crafted.bus_history) do
      if event.type == "stash_pushed" or event.type == "stash_popped" then
        seen[event.type] = true
        event.stash = {
          id = "stash@{0}",
          message = "crafted payload",
          branch = "main",
          timestamp_ms = 1700000000000,
          redacted = false,
          slots = smuggled_slots,
        }
      end
    end
    assert(seen.stash_pushed and seen.stash_popped,
      "fixture must carry both stash event types")
    local crafted_before = deep_copy(crafted)

    -- Validation normalizes stash payloads, so even canonical bytes for a
    -- crafted snapshot cannot carry the smuggled content.
    local canonical = assert(WheelContext.canonical_snapshot(crafted))
    assert(canonical:find(marker, 1, true) == nil,
      "canonical bytes must not contain an unredacted stash payload")

    local restored = assert(WheelContext.import_snapshot(crafted))
    assert(#restored:stash_list() == 0,
      "snapshot import must never materialize stash entries")
    for _, event in ipairs(restored.bus:history()) do
      if event.type == "stash_pushed" or event.type == "stash_popped" then
        assert(event.stash.redacted == true,
          "import must mark every stash event redacted")
        assert(event.stash.slots == nil,
          "import must drop the stash slot map")
        assert(event.stash.message == "crafted payload",
          "bounded stash metadata may be retained")
      end
    end
    assert_deep_equal(crafted, crafted_before,
      "import must not mutate the caller snapshot")
    assert(WheelContext.canonical_snapshot(assert(restored:export_snapshot()))
      == WheelContext.canonical_snapshot(crafted),
      "sanitized import must round-trip canonically")
  end)

  run_test("WheelContext snapshots: export leaves live bus history unchanged", function()
    local ctx = WheelContext.new()
    local marker = "live-stash-content-marker"
    assert(ctx:put_slot("scratch/wip", marker).success)
    assert(ctx:stash_push("wip") ~= nil)

    local live_event
    for _, event in ipairs(ctx.bus:history()) do
      if event.type == "stash_pushed" then
        live_event = event
      end
    end
    assert(live_event and live_event.stash and live_event.stash.slots ~= nil,
      "the live bus must keep its full stash payload")
    local before = deep_copy(ctx.bus:history())

    assert(ctx:export_snapshot() ~= nil)
    assert_deep_equal(ctx.bus:history(), before,
      "export must not mutate live bus history")
    assert(live_event.stash.redacted == nil,
      "export must not mark the live event redacted in place")
    assert(live_event.stash.slots["scratch/wip"].content == marker,
      "export must not strip live stash content")
  end)

  run_test("WheelContext snapshots: key nodes count toward the value node bound", function()
    local ctx = WheelContext.new()
    local event = { type = "key_bound", timestamp_ms = 1 }
    for index = 1, 28 do
      event["key_" .. index] = index
    end
    ctx.bus:publish(event)
    assert(count_keys(event) == 30, "fixture must carry exactly 30 keys")

    local saved_nodes = WheelContextSnapshot.MAX_VALUE_NODES
    WheelContextSnapshot.MAX_VALUE_NODES = 60
    local rejected, reject_err = ctx:export_snapshot()
    WheelContextSnapshot.MAX_VALUE_NODES = 61
    local accepted = ctx:export_snapshot()
    WheelContextSnapshot.MAX_VALUE_NODES = saved_nodes

    assert(rejected == nil and WheelErrors.is_typed(reject_err)
      and reject_err.code == "E_SNAPSHOT_INVALID",
      "30 keys must exceed a 60-node bound when keys count as nodes")
    assert(reject_err.message:find("node", 1, true) ~= nil,
      "node-bound rejection must name the bound: " .. reject_err.message)
    assert(accepted ~= nil,
      "the same event must fit when the bound is raised by one node")
  end)

  run_test("WheelContext snapshots: a committed 256-byte branch ref round-trips", function()
    local ctx = WheelContext.new()
    local name = string.rep("b", WheelContext.MAX_REF_NAME_BYTES)
    assert(#name == 256, "the caller-visible ref bound must stay 256 bytes")
    assert(ctx:put_slot("workspace/base", "base").success)
    assert(ctx:commit_checkpoint({
      message = "root",
      timestamp_ms = 1700000000000,
    }) ~= nil)
    assert(ctx:create_branch(name) == true)
    assert(ctx:checkout(name) == true)
    local commit = assert(ctx:commit_checkpoint({
      message = "boundary",
      timestamp_ms = 1700000001000,
    }))

    local ref = "refs/heads/" .. name
    local snapshot = assert(ctx:export_snapshot())
    assert(snapshot.head == ref, "HEAD must name the 256-byte branch")
    assert(snapshot.refs[ref] == commit.hash,
      "the 256-byte branch ref must round-trip through export")
    local restored = assert(WheelContext.import_snapshot(snapshot))
    assert(restored:current_branch() == name)
    assert(restored:head_commit_hash() == commit.hash)
    assert(WheelContext.canonical_snapshot(snapshot)
      == WheelContext.canonical_snapshot(assert(restored:export_snapshot())))
  end)

  run_test("WheelContext snapshots: stash_pop refuses an exhausted working slot version", function()
    local ctx = WheelContext.new()
    assert(ctx:put_slot("workspace/project", "stashed value").success)
    assert(ctx:stash_push("wip") ~= nil)

    local base = "working value"
    ctx._slots["workspace/project"] = {
      name = "workspace/project",
      content = base,
      hash = WheelContext.compute_hash(base),
      version = WheelContext.MAX_SLOT_VERSION,
      kind = "workspace",
      size_bytes = #base,
      updated_at_ms = 1,
    }
    ctx._tree_hash = nil

    local popped, pop_err = ctx:stash_pop(1)
    assert(popped == nil and pop_err.error == "version_exhausted",
      "stash_pop must fail closed before mutating an exhausted working slot")
    assert(#ctx:stash_list() == 1, "a refused pop must keep the stash entry")
    assert(ctx._slots["workspace/project"].content == base,
      "a refused pop must leave the working slot unchanged")
    assert(ctx:export_snapshot() ~= nil,
      "a refused pop must leave an exportable context")
  end)

  run_test("WheelContext snapshots: slot_removed clamps its event version at the bound", function()
    local ctx = WheelContext.new()
    assert(ctx:put_slot("workspace/project", "value").success)
    ctx._slots["workspace/project"].version = WheelContext.MAX_SLOT_VERSION

    local removed = assert(ctx:remove_slot("workspace/project"))
    assert(removed.removed == true)
    local event
    for _, candidate in ipairs(ctx.bus:history()) do
      if candidate.type == "slot_removed" then
        event = candidate
      end
    end
    assert(event and event.version == WheelContext.MAX_SLOT_VERSION,
      "slot_removed must clamp the event version instead of overflowing")
    assert(ctx:export_snapshot() ~= nil,
      "a clamped removal event must remain exportable")
  end)
end
