-- lua/wheel/context_snapshot.lua
-- Versioned, deterministic WheelContext snapshot validation and encoding.
--
-- This module is deliberately transport-free: it performs no file I/O, logging,
-- or process work. `wheel.context` owns the in-memory state and calls this
-- module through `validate`, `canonical_encode`, and its public wrapper methods.
--
-- The snapshot is caller-owned sensitive data. Validation is fail-closed:
-- malformed, partial, oversized, or cryptographically inconsistent input is
-- rejected before a WheelContext object is constructed.

local WheelContextSnapshot = {}

local FORMAT = "wheel-context-snapshot/1"
local VERSION = 1

-- Snapshot bounds. Per-slot content uses the existing WheelContext limit; the
-- remaining bounds cap CPU, memory, and event-log amplification.
local MAX_SLOTS = 4096
local MAX_SLOT_ENTRIES = 65536
local MAX_COMMITS = 4096
local MAX_COMMIT_PARENTS = 64
local MAX_REFS = 256
local MAX_REFLOG = 256
local MAX_BUS_HISTORY = 64
local MAX_TOTAL_BYTES = 64 * 1024 * 1024
local MAX_METADATA_BYTES = 64 * 1024
local MAX_ACTION_BYTES = 64
local MAX_REF_NAME_BYTES = 256
local MAX_FIELD_NAME_BYTES = 64
local MAX_PLAIN_KEY_BYTES = 256
local MAX_SLOT_VERSION = 2147483647
local MAX_REFLOG_INDEX = 2147483647
local MAX_SAFE_INTEGER = 9007199254740991
local MAX_VALUE_DEPTH = 32
local MAX_VALUE_NODES = 100000
local VALUE_OVERHEAD_BYTES = 16

WheelContextSnapshot.FORMAT = FORMAT
WheelContextSnapshot.VERSION = VERSION
WheelContextSnapshot.MAX_SLOTS = MAX_SLOTS
WheelContextSnapshot.MAX_SLOT_ENTRIES = MAX_SLOT_ENTRIES
WheelContextSnapshot.MAX_COMMITS = MAX_COMMITS
WheelContextSnapshot.MAX_COMMIT_PARENTS = MAX_COMMIT_PARENTS
WheelContextSnapshot.MAX_REFS = MAX_REFS
WheelContextSnapshot.MAX_REFLOG = MAX_REFLOG
WheelContextSnapshot.MAX_BUS_HISTORY = MAX_BUS_HISTORY
WheelContextSnapshot.MAX_TOTAL_BYTES = MAX_TOTAL_BYTES
WheelContextSnapshot.MAX_METADATA_BYTES = MAX_METADATA_BYTES
WheelContextSnapshot.MAX_ACTION_BYTES = MAX_ACTION_BYTES
WheelContextSnapshot.MAX_REF_NAME_BYTES = MAX_REF_NAME_BYTES
WheelContextSnapshot.MAX_FIELD_NAME_BYTES = MAX_FIELD_NAME_BYTES
WheelContextSnapshot.MAX_PLAIN_KEY_BYTES = MAX_PLAIN_KEY_BYTES
WheelContextSnapshot.MAX_SLOT_VERSION = MAX_SLOT_VERSION
WheelContextSnapshot.MAX_REFLOG_INDEX = MAX_REFLOG_INDEX
WheelContextSnapshot.MAX_SAFE_INTEGER = MAX_SAFE_INTEGER
WheelContextSnapshot.MAX_VALUE_DEPTH = MAX_VALUE_DEPTH
WheelContextSnapshot.MAX_VALUE_NODES = MAX_VALUE_NODES

local TOP_LEVEL_FIELDS = {
  "format", "version", "slots", "tree_hash", "head", "refs", "commits",
  "reflog", "bus_history",
}

local SLOT_FIELDS = {
  "name", "content", "hash", "version", "kind", "size_bytes", "updated_at_ms",
}

local COMMIT_FIELDS = {
  "hash", "tree_hash", "slots", "parent_hashes", "author", "message",
  "timestamp_ms",
}

local COMMIT_OPTIONAL_FIELDS = { "task_id", "rationale" }

local REFLOG_FIELDS = {
  "index", "from_hash", "to_hash", "ref", "action", "message", "timestamp_ms",
}

-- A private sentinel keeps validation failures separate from programming
-- errors caught by the public pcall boundary.
local REJECTION_KEY = {}
local REJECTION_VALUE = {}

local function reject(path, reason)
  error({
    [REJECTION_KEY] = REJECTION_VALUE,
    detail = tostring(reason) .. " (" .. tostring(path) .. ")",
  }, 0)
end

local function byte_less(a, b)
  local shorter = math.min(#a, #b)
  for i = 1, shorter do
    local left = string.byte(a, i)
    local right = string.byte(b, i)
    if left ~= right then
      return left < right
    end
  end
  return #a < #b
end

local function sorted_keys(map)
  local keys = {}
  for key in pairs(map) do
    keys[#keys + 1] = key
  end
  table.sort(keys, byte_less)
  return keys
end

local function charge(state, deps, path, bytes)
  state.bytes = state.bytes + bytes
  if state.bytes > deps.max_total_bytes then
    reject(path, "exceeds the total snapshot byte bound")
  end
end

local function check_fields(value, path, required, optional, deps)
  if type(value) ~= "table" then
    reject(path, "must be a table")
  end
  local max_field_name_bytes = (deps and deps.max_field_name_bytes)
    or MAX_FIELD_NAME_BYTES
  local allowed = {}
  for _, field in ipairs(required) do
    allowed[field] = true
  end
  for _, field in ipairs(optional or {}) do
    allowed[field] = true
  end
  for key in pairs(value) do
    if type(key) ~= "string" then
      reject(path, "field names must be strings")
    end
    if #key > max_field_name_bytes then
      reject(path, "field name exceeds the maximum length")
    end
    if not allowed[key] then
      reject(path, "unknown field '" .. key .. "'")
    end
  end
  for _, field in ipairs(required) do
    if rawget(value, field) == nil then
      reject(path, "missing required field '" .. field .. "'")
    end
  end
end

local function check_string(value, path, max_bytes, allow_empty)
  if type(value) ~= "string" then
    reject(path, "must be a string")
  end
  if #value > max_bytes then
    reject(path, "exceeds the maximum string length")
  end
  if not allow_empty and #value == 0 then
    reject(path, "must not be empty")
  end
  return value
end

local function check_number(value, path)
  if type(value) ~= "number" or value ~= value
    or value == math.huge or value == -math.huge then
    reject(path, "must be a finite number")
  end
  return value
end

local function check_integer(value, path, minimum, maximum)
  check_number(value, path)
  maximum = maximum or MAX_SAFE_INTEGER
  if value ~= math.floor(value) or value < minimum or value > maximum then
    reject(path, "must be an integer between " .. tostring(minimum)
      .. " and " .. tostring(maximum))
  end
  return value
end

local function check_timestamp(value, path)
  check_number(value, path)
  if value < 0 then
    reject(path, "must not be negative")
  end
  return value
end

local function check_hash(value, path)
  if type(value) ~= "string" or #value ~= 64
    or value:match("^[0-9a-f]+$") == nil then
    reject(path, "must be a 64-character lowercase hexadecimal hash")
  end
  return value
end

local function check_slot_name(name, path, deps)
  check_string(name, path, deps.max_slot_name_bytes, false)
  if name:find("[%z\1-\31]") then
    reject(path, "must not contain control characters")
  end
  return name
end

local function check_branch_ref(ref, path, deps)
  local name = check_string(ref, path, deps.max_ref_name_bytes + 12, false)
  if name:sub(1, 11) ~= "refs/heads/" then
    reject(path, "must start with 'refs/heads/'")
  end
  local branch = name:sub(12)
  if #branch == 0 or #branch > deps.max_ref_name_bytes then
    reject(path, "has an invalid branch name length")
  end
  if branch:find("^[%w%._%-%/]+$") == nil or branch:find("%.%.") ~= nil
    or branch:sub(1, 1) == "/" or branch:sub(-1) == "/" then
    reject(path, "has an invalid branch name")
  end
  return name
end

local function check_array(value, path, max_length)
  if type(value) ~= "table" then
    reject(path, "must be an array")
  end
  local count = 0
  for key in pairs(value) do
    if type(key) ~= "number" or key < 1 or key ~= math.floor(key) then
      reject(path, "must be a dense array")
    end
    count = count + 1
  end
  if count > max_length then
    reject(path, "exceeds the maximum array length")
  end
  for index = 1, count do
    if rawget(value, index) == nil then
      reject(path, "must be a dense array")
    end
  end
  return count
end

local function compute_tree_hash(slots, deps)
  local names = {}
  for name in pairs(slots) do
    names[#names + 1] = name
  end
  table.sort(names)
  local parts = { "tree:v1\0" }
  for _, name in ipairs(names) do
    local slot = slots[name]
    parts[#parts + 1] = string.format("%s:%d:%s\n", name, slot.size_bytes, slot.hash)
  end
  return deps.compute_hash(table.concat(parts))
end

local function charge_string(state, deps, path, value)
  charge(state, deps, path, #value + VALUE_OVERHEAD_BYTES)
  return value
end

local function copy_slot_map(value, path, deps, state)
  if type(value) ~= "table" then
    reject(path, "must be a table")
  end

  local slots = {}
  local count = 0
  for key, slot in pairs(value) do
    count = count + 1
    if count > deps.max_slots then
      reject(path, "exceeds the maximum slot count")
    end
    if type(key) ~= "string" then
      reject(path, "slot keys must be strings")
    end
    -- Validate the key before building a path from it: an over-bound name must
    -- not amplify memory or the error detail.
    check_slot_name(key, path .. "[slot]", deps)

    local slot_path = path .. "[" .. key .. "]"
    check_fields(slot, slot_path, SLOT_FIELDS, nil, deps)
    if rawget(slot, "name") ~= key then
      reject(slot_path, "name must match its table key")
    end

    local content = rawget(slot, "content")
    if type(content) ~= "string" then
      reject(slot_path, "content must be a string")
    end
    if #content > deps.max_slot_content_bytes then
      reject(slot_path, "content exceeds the maximum slot size")
    end

    local size = rawget(slot, "size_bytes")
    check_integer(size, slot_path .. ".size_bytes", 0,
      deps.max_slot_content_bytes)
    if size ~= #content then
      reject(slot_path, "size_bytes does not match the content length")
    end

    state.slot_entries = state.slot_entries + 1
    if state.slot_entries > deps.max_slot_entries then
      reject(path, "exceeds the total slot entry bound")
    end
    charge(state, deps, slot_path, #content + #key + VALUE_OVERHEAD_BYTES)

    local hash = rawget(slot, "hash")
    check_hash(hash, slot_path .. ".hash")
    if hash ~= deps.compute_hash(content) then
      reject(slot_path, "hash does not match the content")
    end

    local version = rawget(slot, "version")
    check_integer(version, slot_path .. ".version", 1, deps.max_slot_version)

    local kind = rawget(slot, "kind")
    if type(kind) ~= "string" or not deps.slot_kinds[kind] then
      reject(slot_path, "kind must be a known slot kind")
    end
    if kind ~= deps.classify_slot_kind(key) then
      reject(slot_path, "kind does not match the slot name")
    end

    local updated_at_ms = rawget(slot, "updated_at_ms")
    check_timestamp(updated_at_ms, slot_path .. ".updated_at_ms")

    slots[key] = {
      name = key,
      content = content,
      hash = hash,
      version = version,
      kind = kind,
      size_bytes = size,
      updated_at_ms = updated_at_ms,
    }
  end

  return slots
end

local function copy_plain(value, path, deps, state, depth, visiting, memo)
  state.nodes = state.nodes + 1
  if state.nodes > deps.max_nodes then
    reject(path, "exceeds the total value node bound")
  end
  if depth > deps.max_depth then
    reject(path, "exceeds the maximum value depth")
  end

  local value_type = type(value)
  if value_type == "string" then
    if #value > deps.max_metadata_bytes then
      reject(path, "exceeds the maximum metadata string length")
    end
    return charge_string(state, deps, path, value)
  elseif value_type == "number" then
    check_number(value, path)
    charge(state, deps, path, VALUE_OVERHEAD_BYTES)
    return value
  elseif value_type == "boolean" then
    charge(state, deps, path, VALUE_OVERHEAD_BYTES)
    return value
  elseif value_type ~= "table" then
    reject(path, "must contain only strings, numbers, booleans, and tables")
  end

  if visiting[value] then
    reject(path, "must not contain a cycle")
  end
  local existing = memo[value]
  if existing ~= nil then
    return existing
  end
  visiting[value] = true

  local keys = {}
  local numeric_keys = 0
  local all_numeric = true
  for key in pairs(value) do
    local key_type = type(key)
    if key_type == "string" then
      if #key > deps.max_plain_key_bytes then
        reject(path, "map key exceeds the maximum length")
      end
      charge(state, deps, path, #key + VALUE_OVERHEAD_BYTES)
      all_numeric = false
    elseif key_type == "number" and key >= 1 and key == math.floor(key) then
      charge(state, deps, path, VALUE_OVERHEAD_BYTES)
      numeric_keys = numeric_keys + 1
    else
      reject(path, "table keys must be strings or a dense integer array")
    end

    -- Keys are structural nodes; counting them here bounds work before the
    -- key list is sorted or copied.
    state.nodes = state.nodes + 1
    if state.nodes > deps.max_nodes then
      reject(path, "exceeds the total value node bound")
    end
    keys[#keys + 1] = key
  end

  local is_array = false
  if all_numeric and numeric_keys > 0 then
    is_array = true
    for index = 1, numeric_keys do
      if rawget(value, index) == nil then
        is_array = false
        break
      end
    end
  end

  charge(state, deps, path, VALUE_OVERHEAD_BYTES)
  local copy = {}
  memo[value] = copy
  if is_array then
    for index = 1, numeric_keys do
      copy[index] = copy_plain(value[index], path .. "[" .. tostring(index) .. "]",
        deps, state, depth + 1, visiting, memo)
    end
    visiting[value] = nil
    return copy
  end

  for _, key in ipairs(keys) do
    if type(key) ~= "string" then
      reject(path, "table keys must be strings or a dense integer array")
    end
  end
  table.sort(keys, byte_less)
  for _, key in ipairs(keys) do
    copy[key] = copy_plain(value[key], path .. "." .. key, deps, state,
      depth + 1, visiting, memo)
  end
  visiting[value] = nil
  return copy
end

local function copy_commit_map(value, path, deps, state)
  if type(value) ~= "table" then
    reject(path, "must be a table")
  end

  local commits = {}
  local count = 0
  for key, commit in pairs(value) do
    count = count + 1
    if count > deps.max_commits then
      reject(path, "exceeds the maximum commit count")
    end
    if type(key) ~= "string" then
      reject(path, "commit keys must be strings")
    end

    local commit_path = path .. "[" .. key:sub(1, 8) .. "]"
    check_fields(commit, commit_path, COMMIT_FIELDS, COMMIT_OPTIONAL_FIELDS, deps)
    check_hash(rawget(commit, "hash"), commit_path .. ".hash")
    if rawget(commit, "hash") ~= key then
      reject(commit_path, "hash must match its table key")
    end

    local tree_hash = rawget(commit, "tree_hash")
    check_hash(tree_hash, commit_path .. ".tree_hash")
    local slots = copy_slot_map(rawget(commit, "slots"), commit_path .. ".slots",
      deps, state)
    if compute_tree_hash(slots, deps) ~= tree_hash then
      reject(commit_path .. ".tree_hash", "does not match the commit slot tree")
    end

    local parents = rawget(commit, "parent_hashes")
    local parent_count = check_array(parents, commit_path .. ".parent_hashes",
      deps.max_commit_parents)
    local parent_hashes = {}
    for index = 1, parent_count do
      parent_hashes[index] = check_hash(parents[index],
        commit_path .. ".parent_hashes[" .. tostring(index) .. "]")
      charge(state, deps, commit_path, 64 + VALUE_OVERHEAD_BYTES)
    end

    local author = charge_string(state, deps, commit_path .. ".author",
      check_string(rawget(commit, "author"), commit_path .. ".author",
        deps.max_metadata_bytes, true))
    local message = charge_string(state, deps, commit_path .. ".message",
      check_string(rawget(commit, "message"), commit_path .. ".message",
        deps.max_metadata_bytes, true))
    local timestamp_ms = rawget(commit, "timestamp_ms")
    check_timestamp(timestamp_ms, commit_path .. ".timestamp_ms")

    local task_id
    if rawget(commit, "task_id") ~= nil then
      task_id = charge_string(state, deps, commit_path .. ".task_id",
        check_string(rawget(commit, "task_id"), commit_path .. ".task_id",
          deps.max_metadata_bytes, true))
    end

    local rationale
    if rawget(commit, "rationale") ~= nil then
      rationale = copy_plain(rawget(commit, "rationale"), commit_path .. ".rationale",
        deps, state, 0, {}, {})
    end

    commits[key] = {
      hash = key,
      tree_hash = tree_hash,
      slots = slots,
      parent_hashes = parent_hashes,
      author = author,
      task_id = task_id,
      rationale = rationale,
      message = message,
      timestamp_ms = timestamp_ms,
    }
  end

  local names = sorted_keys(commits)

  -- Parent closure is checked before hashes so a crafted cyclic graph is
  -- rejected for its cycle instead of masking the structural defect.
  for _, hash in ipairs(names) do
    local commit = commits[hash]
    for _, parent in ipairs(commit.parent_hashes) do
      if commits[parent] == nil then
        reject(path .. "[" .. hash:sub(1, 8) .. "].parent_hashes",
          "references an unknown parent commit")
      end
    end
  end

  local color = {}
  for _, start in ipairs(names) do
    if color[start] == nil then
      local stack = { { hash = start, index = 0 } }
      while #stack > 0 do
        local frame = stack[#stack]
        local hash = frame.hash
        if color[hash] == nil then
          color[hash] = 1
        end
        local commit = commits[hash]
        local next_index = frame.index + 1
        frame.index = next_index
        if next_index <= #commit.parent_hashes then
          local parent = commit.parent_hashes[next_index]
          if color[parent] == 1 then
            reject(path .. "[" .. hash:sub(1, 8) .. "].parent_hashes",
              "contains a commit parent cycle")
          elseif color[parent] == nil then
            stack[#stack + 1] = { hash = parent, index = 0 }
          end
        else
          color[hash] = 2
          table.remove(stack)
        end
      end
    end
  end

  for _, hash in ipairs(names) do
    local commit = commits[hash]
    local preimage = string.format(
      "commit:v1\0tree:%s\0parents:%s\0author:%s\0task:%s\0time:%s\0msg:%s",
      commit.tree_hash, table.concat(commit.parent_hashes, ","), commit.author,
      commit.task_id or "", tostring(commit.timestamp_ms), commit.message)
    if deps.compute_hash(preimage) ~= commit.hash then
      reject(path .. "[" .. hash:sub(1, 8) .. "]", "commit hash does not match its content")
    end
  end

  return commits
end

local function copy_ref_map(value, path, commits, deps, state)
  if type(value) ~= "table" then
    reject(path, "must be a table")
  end

  local refs = {}
  local count = 0
  for ref, hash in pairs(value) do
    count = count + 1
    if count > deps.max_refs then
      reject(path, "exceeds the maximum ref count")
    end
    if type(ref) ~= "string" then
      reject(path, "ref keys must be strings")
    end
    -- Validate the name before building a path from it.
    check_branch_ref(ref, path .. "[ref]", deps)
    local ref_path = path .. "[" .. ref .. "]"
    check_hash(hash, ref_path)
    if commits[hash] == nil then
      reject(ref_path, "references an unknown commit")
    end
    charge(state, deps, path, #ref + 64 + VALUE_OVERHEAD_BYTES)
    refs[ref] = hash
  end
  return refs
end

local function check_reflog_endpoint(value, path, commits, deps)
  if type(value) ~= "string" then
    reject(path, "must be a string")
  end
  if value == "(empty)" or value == "(initial)" then
    return value
  end
  if value:sub(1, 11) == "refs/heads/" then
    return check_branch_ref(value, path, deps)
  end
  check_hash(value, path)
  if commits[value] == nil then
    reject(path, "references an unknown commit")
  end
  return value
end

local function check_reflog_ref(ref, path, commits, deps)
  if ref == "(detached)" then
    return ref
  end
  if type(ref) == "string" and ref:sub(1, 11) == "refs/heads/" then
    return check_branch_ref(ref, path, deps)
  end
  check_hash(ref, path)
  if commits[ref] == nil then
    reject(path, "references an unknown commit")
  end
  return ref
end

local function copy_reflog(value, path, commits, deps, state)
  local count = check_array(value, path, deps.max_reflog)
  local reflog = {}
  local last_index = 0
  for index = 1, count do
    local entry = value[index]
    local entry_path = path .. "[" .. tostring(index) .. "]"
    check_fields(entry, entry_path, REFLOG_FIELDS, nil, deps)

    local entry_index = rawget(entry, "index")
    check_integer(entry_index, entry_path .. ".index", 1, deps.max_reflog_index)
    if entry_index <= last_index then
      reject(entry_path .. ".index", "must be strictly increasing")
    end
    last_index = entry_index

    local from_hash = check_reflog_endpoint(rawget(entry, "from_hash"),
      entry_path .. ".from_hash", commits, deps)
    local to_hash = check_reflog_endpoint(rawget(entry, "to_hash"),
      entry_path .. ".to_hash", commits, deps)
    local ref = check_reflog_ref(rawget(entry, "ref"), entry_path .. ".ref",
      commits, deps)

    local action = rawget(entry, "action")
    check_string(action, entry_path .. ".action", deps.max_action_bytes, false)
    if action:find("[%z\1-\31]") then
      reject(entry_path .. ".action", "must not contain control characters")
    end

    local message = rawget(entry, "message")
    check_string(message, entry_path .. ".message", deps.max_metadata_bytes, true)
    local timestamp_ms = rawget(entry, "timestamp_ms")
    check_timestamp(timestamp_ms, entry_path .. ".timestamp_ms")

    charge(state, deps, entry_path, #from_hash + #to_hash + #ref + #action
      + #message + VALUE_OVERHEAD_BYTES)
    reflog[index] = {
      index = entry_index,
      from_hash = from_hash,
      to_hash = to_hash,
      ref = ref,
      action = action,
      message = message,
      timestamp_ms = timestamp_ms,
    }
  end
  return reflog
end

local function copy_bus_history(value, path, deps, state)
  local count = check_array(value, path, deps.max_bus_history)
  local history = {}
  for index = 1, count do
    local event = value[index]
    local event_path = path .. "[" .. tostring(index) .. "]"
    if type(event) ~= "table" then
      reject(event_path, "must be a table")
    end
    if rawget(event, "timestamp_ms") == nil then
      reject(event_path, "missing required field 'timestamp_ms'")
    end
    if rawget(event, "type") ~= nil then
      check_string(rawget(event, "type"), event_path .. ".type",
        deps.max_metadata_bytes, true)
    end

    local copied = copy_plain(event, event_path, deps, state, 0, {}, {})
    check_timestamp(copied.timestamp_ms, event_path .. ".timestamp_ms")
    history[index] = copied
  end
  return history
end

local function validate_snapshot(snapshot, deps)
  if type(deps) ~= "table" or type(deps.compute_hash) ~= "function"
    or type(deps.classify_slot_kind) ~= "function"
    or type(deps.slot_kinds) ~= "table" then
    reject("snapshot", "snapshot validator dependencies are incomplete")
  end

  check_fields(snapshot, "snapshot", TOP_LEVEL_FIELDS, nil, deps)
  if rawget(snapshot, "format") ~= deps.format then
    reject("snapshot.format", "unsupported snapshot format")
  end
  if rawget(snapshot, "version") ~= deps.version then
    reject("snapshot.version", "unsupported snapshot version")
  end

  local state = {
    bytes = 0,
    nodes = 0,
    slot_entries = 0,
  }

  local slots = copy_slot_map(rawget(snapshot, "slots"), "snapshot.slots", deps,
    state)
  local tree_hash = rawget(snapshot, "tree_hash")
  check_hash(tree_hash, "snapshot.tree_hash")
  if compute_tree_hash(slots, deps) ~= tree_hash then
    reject("snapshot.tree_hash", "does not match the working slot tree")
  end

  local commits = copy_commit_map(rawget(snapshot, "commits"), "snapshot.commits",
    deps, state)
  local refs = copy_ref_map(rawget(snapshot, "refs"), "snapshot.refs", commits,
    deps, state)

  local head = rawget(snapshot, "head")
  if type(head) ~= "string" then
    reject("snapshot.head", "must be a string")
  end
  if head:sub(1, 11) == "refs/heads/" then
    check_branch_ref(head, "snapshot.head", deps)
  else
    check_hash(head, "snapshot.head")
    if commits[head] == nil then
      reject("snapshot.head", "references an unknown commit")
    end
  end

  local reflog = copy_reflog(rawget(snapshot, "reflog"), "snapshot.reflog",
    commits, deps, state)
  local bus_history = copy_bus_history(rawget(snapshot, "bus_history"),
    "snapshot.bus_history", deps, state)

  if state.bytes > deps.max_total_bytes then
    reject("snapshot", "exceeds the total snapshot byte bound")
  end

  return {
    format = deps.format,
    version = deps.version,
    slots = slots,
    tree_hash = tree_hash,
    head = head,
    refs = refs,
    commits = commits,
    reflog = reflog,
    bus_history = bus_history,
  }
end

--- Validate a snapshot and return a deep, normalized copy.
-- @param snapshot table Caller-owned snapshot table.
-- @param deps table Hash, slot classification, and bound dependencies.
-- @return table|nil Normalized snapshot, or nil and a bounded schema detail.
function WheelContextSnapshot.validate(snapshot, deps)
  local ok, result = pcall(validate_snapshot, snapshot, deps)
  if ok then
    return result
  end
  if type(result) == "table" and result[REJECTION_KEY] == REJECTION_VALUE then
    return nil, result.detail
  end
  return nil, "snapshot validation failed"
end

local function quote(value)
  local out = { '"' }
  local chunk_start = 1
  for index = 1, #value do
    local byte = string.byte(value, index)
    local escaped
    if byte == 34 then
      escaped = '\\"'
    elseif byte == 92 then
      escaped = "\\\\"
    elseif byte == 10 then
      escaped = "\\n"
    elseif byte == 13 then
      escaped = "\\r"
    elseif byte == 9 then
      escaped = "\\t"
    elseif byte >= 32 and byte <= 126 then
      escaped = nil
    else
      escaped = string.format("\\x%02x", byte)
    end
    if escaped then
      if index > chunk_start then
        out[#out + 1] = value:sub(chunk_start, index - 1)
      end
      out[#out + 1] = escaped
      chunk_start = index + 1
    end
  end
  if chunk_start <= #value then
    out[#out + 1] = value:sub(chunk_start)
  end
  out[#out + 1] = '"'
  return table.concat(out)
end

local function format_number(value)
  if value ~= value or value == math.huge or value == -math.huge then
    reject("canonical", "number is not finite")
  end
  if value == 0 then
    return "0"
  end
  if value == math.floor(value) and math.abs(value) < 1e15 then
    return string.format("%.0f", value)
  end
  return string.format("%.17g", value)
end

local function encode_value(value, out, depth)
  if depth > MAX_VALUE_DEPTH then
    reject("canonical", "value exceeds the maximum depth")
  end

  local value_type = type(value)
  if value_type == "string" then
    out[#out + 1] = "s" .. quote(value)
  elseif value_type == "number" then
    out[#out + 1] = "n" .. format_number(value)
  elseif value_type == "boolean" then
    out[#out + 1] = value and "b1" or "b0"
  elseif value_type == "table" then
    local keys = {}
    local numeric_keys = 0
    local all_numeric = true
    for key in pairs(value) do
      keys[#keys + 1] = key
      if type(key) == "number" and key >= 1 and key == math.floor(key) then
        numeric_keys = numeric_keys + 1
      else
        all_numeric = false
      end
    end

    local is_array = false
    if all_numeric and numeric_keys > 0 then
      is_array = true
      for index = 1, numeric_keys do
        if rawget(value, index) == nil then
          is_array = false
          break
        end
      end
    end

    if is_array then
      out[#out + 1] = "a["
      for index = 1, numeric_keys do
        if index > 1 then out[#out + 1] = "," end
        encode_value(value[index], out, depth + 1)
      end
      out[#out + 1] = "]"
    else
      for _, key in ipairs(keys) do
        if type(key) ~= "string" then
          reject("canonical", "table keys must be strings or a dense integer array")
        end
      end
      table.sort(keys, byte_less)
      out[#out + 1] = "m{"
      for index, key in ipairs(keys) do
        if index > 1 then out[#out + 1] = ";" end
        out[#out + 1] = "k" .. quote(key) .. "="
        encode_value(value[key], out, depth + 1)
      end
      out[#out + 1] = "}"
    end
  else
    reject("canonical", "unsupported value type")
  end
end

--- Encode validated plain data as canonical bytes.
-- Map keys are sorted bytewise; strings are escaped to printable ASCII.
-- @param value table Validated snapshot or plain-data value.
-- @return string|nil Canonical bytes, or nil and a bounded detail.
function WheelContextSnapshot.canonical_encode(value)
  local ok, result = pcall(function()
    local out = {}
    encode_value(value, out, 0)
    return table.concat(out)
  end)
  if ok then
    return result
  end
  if type(result) == "table" and result[REJECTION_KEY] == REJECTION_VALUE then
    return nil, result.detail
  end
  return nil, "canonical encoding failed"
end

return WheelContextSnapshot
