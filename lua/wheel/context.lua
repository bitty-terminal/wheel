-- Wheel Context Engine (bitty-terminal.wheel)
-- Implements Phase 3: Shared Context Memory, Semantic Slot Bus, and
-- Prefix-Cache Optimization across peer colleague agents.
--
-- Pure Lua 5.1 compatible, zero external C dependencies, fail-closed security.

local WheelContext = {}
WheelContext.__index = WheelContext

local WheelErrors

--- Treat only the interpreter's exact rooted not-found wording as a missing
-- module. A present-but-broken module or a typed denial keeps its own cause
-- instead of being reported as absent.
-- @param module_name string
-- @param err any
-- @return boolean
local function is_not_found(module_name, err)
  return type(err) == "string"
    and err:find("module '" .. module_name .. "' not found", 1, true) ~= nil
end

--- Annotate a typed cause with the loading parent and rooted dependency while
-- preserving its class and code. The bridge message bound is owned by
-- `wheel.errors`, so the annotated message is clamped to the same limit.
-- @param parent string
-- @param rooted string
-- @param cause table typed bridge error
-- @return table
local function annotated_typed_error(parent, rooted, cause)
  local message = string.format("%s: cannot load submodule '%s': %s",
    parent, rooted, cause.message):gsub("[\r\n]", " ")
  local limit = WheelErrors.MESSAGE_MAX_LENGTH
  if #message > limit then
    message = message:sub(1, limit - 3) .. "..."
  end
  return { class = cause.class, code = cause.code, message = message }
end

local function load_submodule(subpath)
  local rooted = "wheel." .. subpath
  local ok, mod = pcall(require, rooted)
  if ok then return mod end
  -- Lua 5.1 leaves a load sentinel after a failed require. Clear it so a
  -- repeated load reports the real cause instead of "loop or previous error".
  package.loaded[rooted] = nil
  local cause = mod
  if WheelErrors and type(WheelErrors.is_typed) == "function" and WheelErrors.is_typed(cause) then
    error(annotated_typed_error("wheel.context", rooted, cause), 0)
  end
  if not is_not_found(rooted, cause) then
    error(string.format("wheel.context: cannot load submodule '%s': %s",
      rooted, tostring(cause)), 0)
  end

  local alternate = "lua.wheel." .. subpath
  ok, mod = pcall(require, alternate)
  if ok then return mod end
  package.loaded[alternate] = nil
  if WheelErrors and type(WheelErrors.is_typed) == "function" and WheelErrors.is_typed(mod) then
    error(annotated_typed_error("wheel.context", rooted, mod), 0)
  end
  if is_not_found(alternate, mod) then
    mod = cause
  end

  error(string.format("wheel.context: cannot load submodule '%s': %s",
    rooted, tostring(mod)), 0)
end

WheelErrors = load_submodule("errors")
local WheelConfig = load_submodule("config")

local WheelHost = load_submodule("host")
local WheelSnapshot = load_submodule("context_snapshot")

-- ---------------------------------------------------------------------------
-- Constants & Limits
-- ---------------------------------------------------------------------------

WheelContext.MAX_SLOT_NAME_BYTES = 256
WheelContext.MAX_SLOT_CONTENT_BYTES = 16 * 1024 * 1024 -- 16 MiB
WheelContext.MAX_TOTAL_BUDGET_BYTES = 64 * 1024 -- 64 KiB
WheelContext.DEFAULT_ZONE1_MAX_BYTES = 16 * 1024 -- 16 KiB
WheelContext.DEFAULT_ZONE2_MAX_BYTES = 32 * 1024 -- 32 KiB
WheelContext.DEFAULT_ZONE3_MAX_BYTES = 16 * 1024 -- 16 KiB

-- Context projection budgets are deliberately independent from provider
-- settings. They bound deterministic, caller-owned plain data before prompt
-- compilation and keep each projection layer observable.
WheelContext.DEFAULT_PROJECTION_BUDGET_BYTES = WheelContext.MAX_TOTAL_BUDGET_BYTES
WheelContext.DEFAULT_P0_BUDGET_BYTES = 16 * 1024
WheelContext.DEFAULT_P1_BUDGET_BYTES = 8 * 1024
WheelContext.DEFAULT_P2_BUDGET_BYTES = 16 * 1024
WheelContext.DEFAULT_P3_BUDGET_BYTES = 16 * 1024
WheelContext.DEFAULT_P4_BUDGET_BYTES = 8 * 1024
WheelContext.PROJECTION_VERSION = 1

WheelContext.Role = {
  PLANNER = "Planner",
  DOCUMENTATION = "Documentation",
  CODING = "Coding",
  DEBUG = "Debug",
  RESEARCH = "Research",
  REVIEWER = "Reviewer",
}

local ROLE_VALUES = {}
for _, role in pairs(WheelContext.Role) do
  ROLE_VALUES[role] = true
end

-- These defaults are selection policy, not authority. A caller may supply
-- explicit scopes and records; a role lens only decides which eligible
-- categories are useful by default.
local ROLE_LENSES = {
  Planner = { "project", "decisions", "tasks", "architecture", "security", "diagnostics" },
  Documentation = { "project", "decisions", "architecture", "documentation", "security", "tasks" },
  Coding = { "project", "decisions", "architecture", "source", "diagnostics", "tasks" },
  Debug = { "project", "decisions", "source", "diagnostics", "logs", "tasks" },
  Research = { "project", "decisions", "architecture", "research", "security", "tasks" },
  Reviewer = { "project", "decisions", "architecture", "source", "diagnostics", "security", "tasks" },
}

local PROJECTION_LAYERS = {
  { id = "P0", name = "project", budget = "p0_max_bytes" },
  { id = "P1", name = "role", budget = "p1_max_bytes" },
  { id = "P2", name = "task", budget = "p2_max_bytes" },
  { id = "P3", name = "session_delta", budget = "p3_max_bytes" },
  { id = "P4", name = "recent_tail", budget = "p4_max_bytes" },
}

-- Snapshot policy constants have one source: the snapshot module. Keeping the
-- public context aliases avoids a second format/version/bound that can drift.
WheelContext.MAX_BUS_HISTORY = WheelSnapshot.MAX_BUS_HISTORY
WheelContext.MAX_REFLOG = WheelSnapshot.MAX_REFLOG
WheelContext.SNAPSHOT_FORMAT = WheelSnapshot.FORMAT
WheelContext.SNAPSHOT_VERSION = WheelSnapshot.VERSION
WheelContext.MAX_SNAPSHOT_BYTES = WheelSnapshot.MAX_TOTAL_BYTES
WheelContext.MAX_REFLOG_INDEX = WheelSnapshot.MAX_REFLOG_INDEX
WheelContext.MAX_SLOT_VERSION = WheelSnapshot.MAX_SLOT_VERSION
WheelContext.MAX_REF_NAME_BYTES = WheelSnapshot.MAX_REF_NAME_BYTES

WheelContext.SlotKind = {
  WORKSPACE = "workspace",
  TASK = "task",
  DECISION = "decision",
  SCRATCH = "scratch",
  CUSTOM = "custom",
}

-- Membership set of accepted slot-kind values for snapshot validation.
local SLOT_KIND_VALUES = {}
for _, kind in pairs(WheelContext.SlotKind) do
  SLOT_KIND_VALUES[kind] = true
end

-- ---------------------------------------------------------------------------
-- Cryptographic Hash Utility
-- ---------------------------------------------------------------------------

--- Compute deterministic 64-hex SHA-256 digest of input string.
-- @param str string
-- @return string (64 lowercase hex characters)
function WheelContext.compute_hash(str)
  if WheelConfig and type(WheelConfig.compute_hash) == "function" then
    return WheelConfig.compute_hash(str)
  end
  -- Fallback deterministic multi-prime rolling hash if config unavailable
  local h1 = 0x811c9dc5
  local h2 = 0x27d4eb2f
  local len = #str
  for i = 1, len do
    local b = string.byte(str, i)
    h1 = (h1 * 16777619 + b) % 4294967296
    h2 = (h2 * 2166136261 + b) % 4294967296
  end
  return string.format("%08x%08x%08x%08x%08x%08x%08x%08x",
    h1, h2, (h1 + h2) % 4294967296, (h1 * 31 + h2) % 4294967296,
    h2, h1, (h2 * 17 + h1) % 4294967296, (h1 * 13 + h2 * 7) % 4294967296)
end

-- ---------------------------------------------------------------------------
-- Context Event Bus (ContextBus)
-- ---------------------------------------------------------------------------

local ContextBus = {}
ContextBus.__index = ContextBus

function ContextBus.new()
  local self = setmetatable({}, ContextBus)
  self._subscribers = {} -- [subscriber_id] = callback
  self._history = {}
  return self
end

--- Subscribe a peer agent or observer to context events.
-- @param id string Unique identifier for subscriber
-- @param callback function(event) Callback invoked on event publication
function ContextBus:subscribe(id, callback)
  if type(id) ~= "string" or #id == 0 then
    error("ContextBus: subscriber id must be non-empty string")
  end
  if type(callback) ~= "function" then
    error("ContextBus: callback must be a function")
  end
  self._subscribers[id] = callback
end

--- Unsubscribe an agent from the bus.
-- @param id string
function ContextBus:unsubscribe(id)
  self._subscribers[id] = nil
end

--- Check if an agent is subscribed.
-- @param id string
-- @return boolean
function ContextBus:is_subscribed(id)
  return self._subscribers[id] ~= nil
end

--- Publish an event across all active subscribers.
-- @param event table Event payload (type, payload fields)
-- @return number Number of successfully notified subscribers
function ContextBus:publish(event)
  if type(event) ~= "table" then
    error("ContextBus: event must be a table")
  end
  event.timestamp_ms = event.timestamp_ms or WheelHost.time.now() * 1000

  -- Record event in bounded history ring
  table.insert(self._history, event)
  if #self._history > WheelContext.MAX_BUS_HISTORY then
    table.remove(self._history, 1)
  end

  local notified = 0
  for _, callback in pairs(self._subscribers) do
    local ok, _ = pcall(callback, event)
    if ok then
      notified = notified + 1
    end
  end
  return notified
end

--- Retrieve recent bus events.
-- @return table Array of recent event tables
function ContextBus:history()
  local copy = {}
  for i, ev in ipairs(self._history) do
    copy[i] = ev
  end
  return copy
end

WheelContext.ContextBus = ContextBus

-- ---------------------------------------------------------------------------
-- Helper Functions
-- ---------------------------------------------------------------------------

--- Classify slot kind from hierarchical slot name.
-- @param name string
-- @return string SlotKind enum
local function classify_slot_kind(name)
  if name:find("^workspace/") then
    return WheelContext.SlotKind.WORKSPACE
  elseif name:find("^tasks/") then
    return WheelContext.SlotKind.TASK
  elseif name:find("^decisions/") then
    return WheelContext.SlotKind.DECISION
  elseif name:find("^scratch/") then
    return WheelContext.SlotKind.SCRATCH
  else
    return WheelContext.SlotKind.CUSTOM
  end
end

--- Validate slot name conformance.
-- @param name string
-- @return boolean, string|nil
local function validate_slot_name(name)
  if type(name) ~= "string" or #name == 0 then
    return false, "slot name must be non-empty string"
  end
  if #name > WheelContext.MAX_SLOT_NAME_BYTES then
    return false, string.format("slot name exceeds maximum length of %d bytes", WheelContext.MAX_SLOT_NAME_BYTES)
  end
  -- Reject control characters
  if name:find("[%z\1-\31]") then
    return false, "slot name contains illegal control characters"
  end
  return true, nil
end

--- Bound a caller-controlled label for a diagnostic.
-- @param value any
-- @param limit number Maximum bytes before truncation
-- @return string
local function bounded_label(value, limit)
  local text = type(value) == "string" and value or tostring(value)
  if #text > limit then
    return text:sub(1, limit - 3) .. "..."
  end
  return text
end

--- Assemble the snapshot validator's dependency and bound table.
-- Snapshot-wide bounds are read at call time so a caller can tighten them
-- without editing the shared module. The per-slot content and total limits are
-- the same policy constants the live context enforces.
-- @return table
local function snapshot_deps()
  return {
    format = WheelContext.SNAPSHOT_FORMAT,
    version = WheelContext.SNAPSHOT_VERSION,
    compute_hash = WheelContext.compute_hash,
    classify_slot_kind = classify_slot_kind,
    slot_kinds = SLOT_KIND_VALUES,
    max_slots = WheelSnapshot.MAX_SLOTS,
    max_slot_name_bytes = WheelContext.MAX_SLOT_NAME_BYTES,
    max_slot_content_bytes = WheelContext.MAX_SLOT_CONTENT_BYTES,
    max_total_bytes = WheelContext.MAX_SNAPSHOT_BYTES,
    max_slot_entries = WheelSnapshot.MAX_SLOT_ENTRIES,
    max_slot_version = WheelContext.MAX_SLOT_VERSION,
    max_commits = WheelSnapshot.MAX_COMMITS,
    max_commit_parents = WheelSnapshot.MAX_COMMIT_PARENTS,
    max_refs = WheelSnapshot.MAX_REFS,
    max_reflog = WheelContext.MAX_REFLOG,
    max_reflog_index = WheelContext.MAX_REFLOG_INDEX,
    max_bus_history = WheelContext.MAX_BUS_HISTORY,
    max_metadata_bytes = WheelSnapshot.MAX_METADATA_BYTES,
    max_action_bytes = WheelSnapshot.MAX_ACTION_BYTES,
    max_ref_name_bytes = WheelContext.MAX_REF_NAME_BYTES,
    max_field_name_bytes = WheelSnapshot.MAX_FIELD_NAME_BYTES,
    max_plain_key_bytes = WheelSnapshot.MAX_PLAIN_KEY_BYTES,
    max_depth = WheelSnapshot.MAX_VALUE_DEPTH,
    max_nodes = WheelSnapshot.MAX_VALUE_NODES,
  }
end

-- ---------------------------------------------------------------------------
-- WheelContext Constructor & Slot Management
-- ---------------------------------------------------------------------------

--- Create a new WheelContext instance.
-- @param opts table|nil Configuration options:
--   - kernel: WheelKernel instance (optional)
--   - config: Wheel configuration table (optional)
--   - bus: ContextBus instance (optional; new bus created if nil)
--   - max_budget_bytes: integer total prompt limit (default 65536)
--   - zone1_max_bytes: integer Zone 1 limit (default 16384)
--   - zone2_max_bytes: integer Zone 2 limit (default 32768)
--   - zone3_max_bytes: integer Zone 3 limit (default 16384)
function WheelContext.new(opts)
  opts = opts or {}
  local self = setmetatable({}, WheelContext)

  self.kernel = opts.kernel
  self.config = opts.config
  self.bus = opts.bus or ContextBus.new()

  -- Slot store: [name] = { name, content, hash, version, kind, size_bytes, updated_at_ms }
  self._slots = {}
  self._tree_hash = nil

  -- Git-Model Context Versioning State
  self._refs = { ["refs/heads/main"] = nil }
  self._head = "refs/heads/main"
  self._commits = {}
  self._reflog = {}
  self._stash = {}

  -- Multi-tier budget configuration
  local ctx_conf = (self.config and self.config.context) or {}
  self.max_budget_bytes = opts.max_budget_bytes or ctx_conf.max_budget_bytes or WheelContext.MAX_TOTAL_BUDGET_BYTES
  self.zone1_max_bytes = opts.zone1_max_bytes or ctx_conf.zone1_max_bytes or WheelContext.DEFAULT_ZONE1_MAX_BYTES
  self.zone2_max_bytes = opts.zone2_max_bytes or ctx_conf.zone2_max_bytes or WheelContext.DEFAULT_ZONE2_MAX_BYTES
  self.zone3_max_bytes = opts.zone3_max_bytes or ctx_conf.zone3_max_bytes or WheelContext.DEFAULT_ZONE3_MAX_BYTES

  return self
end

--- Put a semantic slot into the context store with optimistic CAS concurrency.
-- @param name string Hierarchical slot name
-- @param content string Slot text content
-- @param expected_version integer|nil If specified, current slot version must match
-- @return table|nil result { success = true, name = name, hash = hash, version = version }, or nil, error_table
function WheelContext:put_slot(name, content, expected_version)
  local valid_name, err_name = validate_slot_name(name)
  if not valid_name then
    return nil, { error = "invalid_name", message = err_name }
  end

  if type(content) ~= "string" then
    return nil, { error = "invalid_content", message = "slot content must be a string" }
  end

  if #content > WheelContext.MAX_SLOT_CONTENT_BYTES then
    return nil, { error = "payload_too_large", message = "slot content exceeds maximum size" }
  end

  local existing = self._slots[name]
  local current_ver = existing and existing.version or 0

  -- Optimistic Concurrency Control (CAS)
  if expected_version ~= nil then
    if expected_version ~= current_ver then
      return nil, {
        error = "cas_conflict",
        message = string.format("CAS version conflict on slot '%s': expected %d, current is %d",
          name, expected_version, current_ver),
        expected_version = expected_version,
        current_version = current_ver,
      }
    end
  end

  if current_ver >= WheelContext.MAX_SLOT_VERSION then
    return nil, {
      error = "version_exhausted",
      message = "slot version bound reached for '" .. name .. "'",
    }
  end

  local h = WheelContext.compute_hash(content)
  local new_ver = current_ver + 1
  local kind = classify_slot_kind(name)
  local now_ms = WheelHost.time.now() * 1000

  local slot = {
    name = name,
    content = content,
    hash = h,
    version = new_ver,
    kind = kind,
    size_bytes = #content,
    updated_at_ms = now_ms,
  }

  self._slots[name] = slot
  self._tree_hash = nil -- Invalidate cached Merkle tree root

  -- Synchronize with underlying WheelKernel if present
  if self.kernel and type(self.kernel.put_slot) == "function" then
    pcall(function() self.kernel:put_slot(name, content) end)
  end

  -- Publish slot update event to peer colleagues on the bus
  self.bus:publish({
    type = "slot_updated",
    name = name,
    hash = h,
    version = new_ver,
    kind = kind,
    size_bytes = #content,
    updated_at_ms = now_ms,
  })

  return {
    success = true,
    name = name,
    hash = h,
    version = new_ver,
    kind = kind,
    size_bytes = #content,
  }
end

--- Retrieve a semantic slot by name.
-- @param name string
-- @return table { name = name, found = boolean, content = string, hash = string, version = number, kind = string }
function WheelContext:get_slot(name)
  local slot = self._slots[name]
  if slot then
    return {
      name = slot.name,
      found = true,
      content = slot.content,
      hash = slot.hash,
      version = slot.version,
      kind = slot.kind,
      size_bytes = slot.size_bytes,
      updated_at_ms = slot.updated_at_ms,
    }
  end

  -- Fallback to query Kernel if slot not present in local cache
  if self.kernel and type(self.kernel.get_slot) == "function" then
    local ok, res = pcall(function() return self.kernel:get_slot(name) end)
    if ok and res and res.found then
      local h = WheelContext.compute_hash(res.content or "")
      local cached = {
        name = name,
        content = res.content or "",
        hash = h,
        version = 1,
        kind = classify_slot_kind(name),
        size_bytes = #(res.content or ""),
        updated_at_ms = WheelHost.time.now() * 1000,
      }
      self._slots[name] = cached
      return {
        name = name,
        found = true,
        content = cached.content,
        hash = cached.hash,
        version = cached.version,
        kind = cached.kind,
        size_bytes = cached.size_bytes,
      }
    end
  end

  return { name = name, found = false }
end

--- Remove a semantic slot with optional CAS check.
-- @param name string
-- @param expected_version integer|nil
-- @return table|nil result { success = true, removed = boolean }, or nil, error_table
function WheelContext:remove_slot(name, expected_version)
  local existing = self._slots[name]
  if not existing then
    return { success = true, removed = false }
  end

  if expected_version ~= nil and expected_version ~= existing.version then
    return nil, {
      error = "cas_conflict",
      message = string.format("CAS conflict removing slot '%s': expected version %d, current is %d",
        name, expected_version, existing.version),
      expected_version = expected_version,
      current_version = existing.version,
    }
  end

  self._slots[name] = nil
  self._tree_hash = nil

  if self.kernel and type(self.kernel.remove_slot) == "function" then
    pcall(function() self.kernel:remove_slot(name) end)
  end

  self.bus:publish({
    type = "slot_removed",
    name = name,
    version = math.min(existing.version + 1, WheelContext.MAX_SLOT_VERSION),
    timestamp_ms = WheelHost.time.now() * 1000,
  })

  return { success = true, removed = true }
end

--- List slots matching an optional prefix, canonically sorted by name.
-- @param prefix string|nil
-- @return table Array of slot summaries
function WheelContext:list_slots(prefix)
  local list = {}
  for name, slot in pairs(self._slots) do
    if not prefix or name:sub(1, #prefix) == prefix then
      table.insert(list, {
        name = slot.name,
        hash = slot.hash,
        version = slot.version,
        kind = slot.kind,
        size_bytes = slot.size_bytes,
      })
    end
  end
  table.sort(list, function(a, b) return a.name < b.name end)
  return list
end

--- Compute canonical Merkle root hash of all active slots.
-- @return string 64-hex Merkle tree root hash
function WheelContext:tree_hash()
  if self._tree_hash then
    return self._tree_hash
  end

  local sorted_names = {}
  for name in pairs(self._slots) do
    table.insert(sorted_names, name)
  end
  table.sort(sorted_names)

  local manifest_parts = { "tree:v1\0" }
  for _, name in ipairs(sorted_names) do
    local s = self._slots[name]
    table.insert(manifest_parts, string.format("%s:%d:%s\n", name, s.size_bytes, s.hash))
  end

  local manifest = table.concat(manifest_parts)
  self._tree_hash = WheelContext.compute_hash(manifest)
  return self._tree_hash
end

-- ---------------------------------------------------------------------------
-- Semantic 3-Way Slot Merge
-- ---------------------------------------------------------------------------

--- Perform a semantic 3-way merge on slot trees (base, ours, theirs).
-- Unconflicting additions or edits are automatically accepted.
-- Conflicting concurrent slot modifications surface structured conflict records.
--
-- @param base_tree table Map of [slot_name] = { content = "...", hash = "..." }
-- @param our_tree table Map of [slot_name] = { content = "...", hash = "..." }
-- @param their_tree table Map of [slot_name] = { content = "...", hash = "..." }
-- @return table { merged = table, conflicts = table, conflict_count = number }
function WheelContext.merge_3way(base_tree, our_tree, their_tree)
  base_tree = base_tree or {}
  our_tree = our_tree or {}
  their_tree = their_tree or {}

  local all_keys = {}
  for k in pairs(base_tree) do all_keys[k] = true end
  for k in pairs(our_tree) do all_keys[k] = true end
  for k in pairs(their_tree) do all_keys[k] = true end

  local merged = {}
  local conflicts = {}

  for name in pairs(all_keys) do
    local b = base_tree[name]
    local o = our_tree[name]
    local t = their_tree[name]

    local b_hash = b and (b.hash or WheelContext.compute_hash(b.content or "")) or nil
    local o_hash = o and (o.hash or WheelContext.compute_hash(o.content or "")) or nil
    local t_hash = t and (t.hash or WheelContext.compute_hash(t.content or "")) or nil

    if o_hash == t_hash then
      -- Case 1: Both sides match (identical content or both deleted)
      if o then
        merged[name] = { content = o.content, hash = o_hash }
      end
    elseif o_hash == b_hash then
      -- Case 2: Only theirs changed
      if t then
        merged[name] = { content = t.content, hash = t_hash }
      end
    elseif t_hash == b_hash then
      -- Case 3: Only ours changed
      if o then
        merged[name] = { content = o.content, hash = o_hash }
      end
    else
      -- Case 4: Both sides changed differently -> Conflict
      table.insert(conflicts, {
        slot = name,
        name = name,
        base_hash = b_hash,
        our_hash = o_hash,
        their_hash = t_hash,
        base_content = b and b.content or nil,
        our_content = o and o.content or nil,
        their_content = t and t.content or nil,
        our_value = o and o.content or nil,
        their_value = t and t.content or nil,
      })
      -- Preserve our version in the merged preview, but flag conflict
      if o then
        merged[name] = { content = o.content, hash = o_hash, conflict = true }
      end
    end
  end

  return {
    merged = merged,
    conflicts = conflicts,
    conflict_count = #conflicts,
  }
end

-- ---------------------------------------------------------------------------
-- Git-Model Context Versioning (Commits, Branches, Reflog, Stash, Merge)
-- ---------------------------------------------------------------------------

--- Deep copy a slot map preserving metadata.
-- @param src table Source slot map
-- @return table Copied slot map
local function deep_copy_slots(src)
  if not src then return {} end
  local dst = {}
  for k, v in pairs(src) do
    if type(v) == "table" then
      dst[k] = {
        name = v.name,
        content = v.content,
        hash = v.hash,
        version = v.version,
        kind = v.kind,
        size_bytes = v.size_bytes or (v.content and #v.content) or 0,
        updated_at_ms = v.updated_at_ms,
      }
    else
      dst[k] = v
    end
  end
  return dst
end

--- Restore working slots from an immutable commit snapshot.
-- @param commit table ContextCommit object
function WheelContext:_restore_slots_from_commit(commit)
  self._slots = deep_copy_slots(commit.slots)
  self._tree_hash = commit.tree_hash
end

--- Choose the next reflog index, repairing an exhausted or non-monotonic
-- retained ring deterministically. Normal entries advance from the last
-- retained index, not from the array length, so a trimmed ring keeps a strictly
-- increasing sequence.
-- @param reflog table Retained reflog records
-- @return number
local function next_reflog_index(reflog)
  local last = reflog[#reflog]
  if not last then
    return 1
  end
  local last_index = last.index
  local monotonic = type(last_index) == "number"
    and last_index == math.floor(last_index)
    and last_index >= 1
    and last_index < WheelContext.MAX_REFLOG_INDEX
  if monotonic then
    for index = 1, #reflog do
      local entry_index = reflog[index].index
      local previous = reflog[index - 1]
      if type(entry_index) ~= "number"
        or entry_index ~= math.floor(entry_index)
        or entry_index < 1
        or (previous and (type(previous.index) ~= "number"
          or entry_index <= previous.index)) then
        monotonic = false
        break
      end
    end
  end
  if not monotonic then
    for index, entry in ipairs(reflog) do
      entry.index = index
    end
    return #reflog + 1
  end
  return last_index + 1
end

--- Append an audit record to the context reflog.
-- @param entry table Reflog descriptor
-- @return table The stored reflog record
function WheelContext:_append_reflog(entry)
  local record = {
    index = next_reflog_index(self._reflog),
    from_hash = entry.from_hash or "(empty)",
    to_hash = entry.to_hash or "(empty)",
    ref = entry.ref or self._head,
    action = entry.action or "unknown",
    message = entry.message or "",
    timestamp_ms = entry.timestamp_ms or (WheelHost.time.now() * 1000),
  }
  table.insert(self._reflog, record)
  if #self._reflog > WheelContext.MAX_REFLOG then
    table.remove(self._reflog, 1)
  end
  return record
end

--- Commit current working context as an immutable checkpoint commit.
-- Binds Merkle tree hash, parent commit hashes, author, task ID, structured rationale, and timestamp.
--
-- @param opts table|nil Checkpoint commit options:
--   - author: string Author agent or user (default "wheel:system")
--   - task_id: string|nil Associated task ID
--   - rationale: string|table|nil Structured 6-field rationale or string
--   - message: string|nil Commit message
--   - parents: table|nil Array of parent commit hashes (defaults to current HEAD)
--   - timestamp_ms: number|nil Epoch timestamp
-- @return table ContextCommit
function WheelContext:commit_checkpoint(opts)
  opts = opts or {}
  local author = opts.author or "wheel:system"
  local task_id = opts.task_id
  local rationale = opts.rationale
  local message = opts.message
  local timestamp_ms = opts.timestamp_ms or (WheelHost.time.now() * 1000)

  local parents = opts.parents
  if not parents then
    local cur_head = self:head_commit_hash()
    if cur_head then
      parents = { cur_head }
    else
      parents = {}
    end
  end

  local tree_hash = self:tree_hash()
  local slots_snapshot = deep_copy_slots(self._slots)

  local rationale_summary = ""
  if type(rationale) == "table" then
    rationale_summary = rationale.goal or rationale.approach or rationale.what or ""
  elseif type(rationale) == "string" then
    rationale_summary = rationale
  end

  if not message or #message == 0 then
    if #rationale_summary > 0 then
      message = rationale_summary
    elseif task_id then
      message = "Checkpoint for task " .. task_id
    else
      message = "Checkpoint at tree " .. tree_hash:sub(1, 8)
    end
  end

  -- Deterministic 64-hex commit content hash
  local parent_str = table.concat(parents, ",")
  local preimage = string.format("commit:v1\0tree:%s\0parents:%s\0author:%s\0task:%s\0time:%s\0msg:%s",
    tree_hash, parent_str, author, task_id or "", tostring(timestamp_ms), message)
  local commit_hash = WheelContext.compute_hash(preimage)

  local commit = {
    hash = commit_hash,
    tree_hash = tree_hash,
    slots = slots_snapshot,
    parent_hashes = parents,
    author = author,
    task_id = task_id,
    rationale = rationale,
    message = message,
    timestamp_ms = timestamp_ms,
  }

  self._commits[commit_hash] = commit

  local old_hash = self:head_commit_hash()
  if self._head:match("^refs/heads/") then
    self._refs[self._head] = commit_hash
  else
    self._head = commit_hash
  end

  self:_append_reflog({
    from_hash = old_hash or "(initial)",
    to_hash = commit_hash,
    ref = self._head,
    action = "commit",
    message = message,
    timestamp_ms = timestamp_ms,
  })

  self.bus:publish({
    type = "checkpoint_committed",
    commit = commit,
    ref = self._head,
    branch = self:current_branch(),
  })

  return commit
end

--- Resolve current HEAD to a commit hash.
-- @return string|nil Commit hash, or nil if no commits exist
function WheelContext:head_commit_hash()
  if self._head:match("^refs/heads/") then
    return self._refs[self._head]
  end
  return self._head
end

--- Get the current active branch name.
-- @return string Branch name, or "(detached)" if in detached HEAD state
function WheelContext:current_branch()
  if self._head:match("^refs/heads/") then
    return self._head:sub(12)
  end
  return "(detached)"
end

--- Retrieve a commit by hash.
-- @param hash string
-- @return table|nil ContextCommit
function WheelContext:get_commit(hash)
  if type(hash) ~= "string" then return nil end
  return self._commits[hash]
end

--- Create a new branch pointing to an existing commit or current HEAD.
-- @param name string Branch name (must be valid ref name without '..')
-- @param start_point string|nil Commit hash or ref to branch from (default current HEAD)
-- @return boolean, table|nil true on success, or nil, error table
function WheelContext:create_branch(name, start_point)
  if type(name) ~= "string" or #name > WheelContext.MAX_REF_NAME_BYTES
    or not name:match("^[%w%._%-%/]+$") or name:find("%.%.")
    or name:sub(1, 1) == "/" or name:sub(-1) == "/" then
    return nil, {
      error = "invalid_branch_name",
      message = "Invalid branch name: " .. bounded_label(name, 64),
    }
  end
  local ref = "refs/heads/" .. name
  if self._refs[ref] ~= nil then
    return nil, { error = "branch_exists", message = "Branch '" .. name .. "' already exists" }
  end

  local target_hash = start_point
  if not target_hash then
    target_hash = self:head_commit_hash()
  elseif self._refs["refs/heads/" .. target_hash] then
    target_hash = self._refs["refs/heads/" .. target_hash]
  elseif not self._commits[target_hash] then
    return nil, { error = "invalid_start_point", message = "Start point commit not found: " .. tostring(start_point) }
  end

  self._refs[ref] = target_hash

  self:_append_reflog({
    from_hash = target_hash or "(empty)",
    to_hash = target_hash or "(empty)",
    ref = ref,
    action = "branch",
    message = "branch: created " .. name,
  })

  return true
end

--- List all known branches and their tip commit hashes.
-- @return table Array of { name = string, ref = string, hash = string|nil, is_head = boolean }
function WheelContext:list_branches()
  local list = {}
  local cur = self:current_branch()
  for ref, hash in pairs(self._refs) do
    if ref:match("^refs/heads/") then
      local bname = ref:sub(12)
      table.insert(list, {
        name = bname,
        ref = ref,
        hash = hash,
        is_head = (bname == cur),
      })
    end
  end
  table.sort(list, function(a, b) return a.name < b.name end)
  return list
end

--- Delete a branch reference.
-- Fails closed if deleting active branch or 'main' without force.
-- @param name string Branch name
-- @param force boolean? Allow deleting active branch
-- @return boolean, table|nil
function WheelContext:delete_branch(name, force)
  local ref = "refs/heads/" .. name
  local exists = false
  for r, _ in pairs(self._refs) do
    if r == ref then exists = true; break end
  end
  if not exists then
    return nil, { error = "not_found", message = "Branch '" .. name .. "' not found" }
  end

  if self:current_branch() == name and not force then
    return nil, { error = "cannot_delete_active_branch", message = "Cannot delete currently checked out branch" }
  end
  if name == "main" and not force then
    return nil, { error = "protected_branch", message = "Cannot delete default branch 'main'" }
  end

  self._refs[ref] = nil
  return true
end

--- Checkout a branch, commit, or tag, restoring slot tree.
-- @param target string Branch name or commit hash
-- @param opts table|nil Checkout options (create_branch, start_point)
-- @return boolean, table|nil
function WheelContext:checkout(target, opts)
  opts = opts or {}
  if type(target) ~= "string" or #target == 0 then
    return nil, { error = "invalid_target", message = "Checkout target must be non-empty string" }
  end

  if opts.create_branch then
    local ok, err = self:create_branch(target, opts.start_point)
    if not ok then return nil, err end
  end

  local ref = target:match("^refs/heads/") and target or ("refs/heads/" .. target)
  local has_branch = false
  for r, _ in pairs(self._refs) do
    if r == ref then has_branch = true; break end
  end

  if has_branch then
    local old_ref = self._head
    local target_commit_hash = self._refs[ref]
    self._head = ref
    if target_commit_hash and self._commits[target_commit_hash] then
      self:_restore_slots_from_commit(self._commits[target_commit_hash])
    end
    self:_append_reflog({
      from_hash = self:head_commit_hash() or "(empty)",
      to_hash = target_commit_hash or "(empty)",
      ref = self._head,
      action = "checkout",
      message = string.format("checkout: moving from %s to %s", old_ref, ref),
    })
    return true
  elseif self._commits[target] then
    local old_ref = self._head
    self._head = target
    self:_restore_slots_from_commit(self._commits[target])
    self:_append_reflog({
      from_hash = old_ref,
      to_hash = target,
      ref = "(detached)",
      action = "checkout",
      message = string.format("checkout: moving from %s to %s (detached HEAD)", old_ref, target),
    })
    return true
  else
    return nil, { error = "not_found", message = "Reference or commit not found: " .. target }
  end
end

--- Retrieve recent audit reflog records in reverse chronological order.
-- @param limit number? Maximum records to return (default 50)
-- @return table Array of reflog records
function WheelContext:reflog(limit)
  limit = limit or 50
  local entries = {}
  local total = #self._reflog
  local count = math.min(limit, total)
  for i = 1, count do
    table.insert(entries, self._reflog[total - i + 1])
  end
  return entries
end

--- Reset HEAD / branch reference to a target commit.
-- @param target string Commit hash or branch name
-- @param mode string? "soft" (default: moves ref only) or "hard" (reverts working slots)
-- @return boolean, table|nil
function WheelContext:reset(target, mode)
  mode = mode or "soft"
  local commit_hash
  if self._commits[target] then
    commit_hash = target
  elseif self._refs["refs/heads/" .. target] then
    commit_hash = self._refs["refs/heads/" .. target]
  else
    return nil, { error = "not_found", message = "Target commit not found: " .. tostring(target) }
  end

  local target_commit = self._commits[commit_hash]
  local old_hash = self:head_commit_hash()

  if mode == "hard" then
    self:_restore_slots_from_commit(target_commit)
  end

  if self._head:match("^refs/heads/") then
    self._refs[self._head] = commit_hash
  else
    self._head = commit_hash
  end

  self:_append_reflog({
    from_hash = old_hash or "(empty)",
    to_hash = commit_hash,
    ref = self._head,
    action = "reset",
    message = string.format("reset (%s) to %s", mode, commit_hash:sub(1, 8)),
  })

  return true
end

--- Push current working slots onto the stash stack and revert slots to HEAD.
-- @param message string? Optional description
-- @return table Stash record
function WheelContext:stash_push(message)
  local cur_branch = self:current_branch()
  local cur_head = self:head_commit_hash()
  local msg = message or string.format("WIP on %s: %s", cur_branch, cur_head and cur_head:sub(1, 8) or "initial")

  local entry = {
    id = "stash@{0}",
    message = msg,
    slots = deep_copy_slots(self._slots),
    head_hash = cur_head,
    branch = cur_branch,
    timestamp_ms = WheelHost.time.now() * 1000,
  }

  table.insert(self._stash, 1, entry)
  for i, s in ipairs(self._stash) do
    s.id = string.format("stash@{%d}", i - 1)
  end

  if cur_head and self._commits[cur_head] then
    self:_restore_slots_from_commit(self._commits[cur_head])
  else
    self._slots = {}
    self._tree_hash = nil
  end

  self.bus:publish({ type = "stash_pushed", stash = entry })
  return entry
end

--- Pop a stashed working context from the stack and merge/restore into working slots.
-- @param index number? 1-based index (default 1)
-- @return table, table|nil Stash record, or nil, error table
function WheelContext:stash_pop(index)
  index = index or 1
  if #self._stash == 0 then
    return nil, { error = "stash_empty", message = "No stash entries found" }
  end
  if index < 1 or index > #self._stash then
    return nil, { error = "invalid_index", message = "Stash index out of range: " .. tostring(index) }
  end

  -- Refuse before mutating either the stash stack or the working slots.
  local candidate = self._stash[index]
  for key in pairs(candidate.slots) do
    local existing = self._slots[key]
    if existing and type(existing.version) == "number"
      and existing.version >= WheelContext.MAX_SLOT_VERSION then
      return nil, {
        error = "version_exhausted",
        message = "slot version bound reached for '" .. key .. "'",
      }
    end
  end

  local entry = table.remove(self._stash, index)
  for i, s in ipairs(self._stash) do
    s.id = string.format("stash@{%d}", i - 1)
  end

  for k, v in pairs(entry.slots) do
    self._slots[k] = {
      name = v.name,
      content = v.content,
      hash = v.hash,
      version = (self._slots[k] and self._slots[k].version or 0) + 1,
      kind = v.kind,
      size_bytes = v.size_bytes or (v.content and #v.content) or 0,
      updated_at_ms = WheelHost.time.now() * 1000,
    }
  end
  self._tree_hash = nil

  self.bus:publish({ type = "stash_popped", stash = entry })
  return entry
end

--- List all active stashed contexts.
-- @return table Array of stash records
function WheelContext:stash_list()
  local copy = {}
  for i, s in ipairs(self._stash) do
    copy[i] = s
  end
  return copy
end

--- Drop a specific stash entry without applying it.
-- @param index number? 1-based index (default 1)
-- @return table, table|nil Dropped record
function WheelContext:stash_drop(index)
  index = index or 1
  if index < 1 or index > #self._stash then
    return nil, { error = "invalid_index", message = "Stash index out of range" }
  end
  local removed = table.remove(self._stash, index)
  for i, s in ipairs(self._stash) do
    s.id = string.format("stash@{%d}", i - 1)
  end
  return removed
end

--- Find lowest common ancestor (LCA) commit between two commits in the DAG.
-- @param hash_a string Commit hash
-- @param hash_b string Commit hash
-- @return string|nil Commit hash of LCA, or nil
function WheelContext:find_common_ancestor(hash_a, hash_b)
  if not hash_a or not hash_b then return nil end
  if hash_a == hash_b then return hash_a end

  local ancestors_a = {}
  local queue_a = { hash_a }
  while #queue_a > 0 do
    local curr = table.remove(queue_a, 1)
    if not ancestors_a[curr] then
      ancestors_a[curr] = true
      local c = self._commits[curr]
      if c and c.parent_hashes then
        for _, p in ipairs(c.parent_hashes) do
          table.insert(queue_a, p)
        end
      end
    end
  end

  local visited_b = {}
  local queue_b = { hash_b }
  while #queue_b > 0 do
    local curr = table.remove(queue_b, 1)
    if ancestors_a[curr] then
      return curr
    end
    if not visited_b[curr] then
      visited_b[curr] = true
      local c = self._commits[curr]
      if c and c.parent_hashes then
        for _, p in ipairs(c.parent_hashes) do
          table.insert(queue_b, p)
        end
      end
    end
  end

  return nil
end

--- Cherry-pick decisions and artifacts from a specific commit into current working context.
-- Applies 3-way merge against commit's parent, committing the result as a new checkpoint.
--
-- @param commit_hash string Hash of commit to cherry-pick
-- @param opts table|nil Cherry-pick options (author, message, force)
-- @return table, table|nil New ContextCommit on success, or nil, error table
function WheelContext:cherry_pick(commit_hash, opts)
  opts = opts or {}
  local commit = self:get_commit(commit_hash)
  if not commit then
    return nil, { error = "not_found", message = "Commit not found: " .. tostring(commit_hash) }
  end

  local base_slots = {}
  if commit.parent_hashes and #commit.parent_hashes > 0 then
    local parent_c = self:get_commit(commit.parent_hashes[1])
    if parent_c and parent_c.slots then
      base_slots = parent_c.slots
    end
  end

  local merge_res = WheelContext.merge_3way(base_slots, self._slots, commit.slots)
  if #merge_res.conflicts > 0 and not opts.force then
    return nil, {
      error = "cherry_pick_conflict",
      message = string.format("Cherry-pick encountered %d conflict(s)", #merge_res.conflicts),
      conflicts = merge_res.conflicts,
    }
  end

  self._slots = {}
  for k, v in pairs(merge_res.merged) do
    self._slots[k] = {
      name = v.name or k,
      content = v.content,
      hash = v.hash or WheelContext.compute_hash(v.content or ""),
      version = (self._slots[k] and self._slots[k].version or 0) + 1,
      kind = classify_slot_kind(k),
      size_bytes = (v.content and #v.content) or 0,
      updated_at_ms = WheelHost.time.now() * 1000,
    }
  end
  self._tree_hash = nil

  local msg = opts.message or string.format("[cherry-pick] %s (from %s)", commit.message, commit.hash:sub(1, 8))
  local new_commit = self:commit_checkpoint({
    author = opts.author or "wheel:cherry-pick",
    task_id = commit.task_id,
    rationale = commit.rationale,
    message = msg,
  })

  return new_commit
end

--- Perform a 3-way semantic merge of a source branch or commit into current branch.
-- Fast-forwards when possible unless opts.no_ff is set. On merge conflict, records
-- conflict diagnostics in decisions/conflicts/* unless allow_conflicts is set.
--
-- @param source string Branch name or commit hash
-- @param opts table|nil Merge options (author, message, rationale, no_ff, allow_conflicts)
-- @return table, table|nil { success = boolean, fast_forward = boolean, commit = table }, or nil, error table
function WheelContext:merge_branch(source, opts)
  opts = opts or {}
  local their_hash
  if self._refs["refs/heads/" .. source] then
    their_hash = self._refs["refs/heads/" .. source]
  elseif self._commits[source] then
    their_hash = source
  else
    return nil, { error = "not_found", message = "Source branch or commit not found: " .. tostring(source) }
  end

  local their_commit = self._commits[their_hash]
  if not their_commit then
    return nil, { error = "not_found", message = "Source commit data missing: " .. tostring(their_hash) }
  end

  local our_hash = self:head_commit_hash()
  if not our_hash then
    -- Fast-forward checkout if current HEAD has no commits
    local ok = self:checkout(source)
    if ok then
      return { success = true, fast_forward = true, commit = their_commit }
    else
      return nil, { error = "checkout_failed", message = "Could not checkout " .. source }
    end
  end

  if our_hash == their_hash then
    return { success = true, fast_forward = false, already_up_to_date = true, commit = their_commit }
  end

  local base_hash = self:find_common_ancestor(our_hash, their_hash)
  local base_slots = (base_hash and self._commits[base_hash] and self._commits[base_hash].slots) or {}

  if base_hash == our_hash and not opts.no_ff then
    if self._head:match("^refs/heads/") then
      self._refs[self._head] = their_hash
    else
      self._head = their_hash
    end
    self:_restore_slots_from_commit(their_commit)
    self:_append_reflog({
      from_hash = our_hash,
      to_hash = their_hash,
      ref = self._head,
      action = "merge",
      message = string.format("merge: fast-forward to %s", their_hash:sub(1, 8)),
    })
    return { success = true, fast_forward = true, commit = their_commit }
  end

  local merge_res = WheelContext.merge_3way(base_slots, self._slots, their_commit.slots)
  if #merge_res.conflicts > 0 and not opts.allow_conflicts then
    for _, c in ipairs(merge_res.conflicts) do
      local cslot = "decisions/conflicts/" .. (c.name or c.slot)
      local ctext = string.format("CONFLICT on %s:\n[ours]: %s\n[theirs]: %s",
        c.name or c.slot, tostring(c.our_content or c.our_value), tostring(c.their_content or c.their_value))
      self:put_slot(cslot, ctext)
    end
    return nil, {
      error = "merge_conflict",
      message = string.format("Merge conflict in %d slot(s)", #merge_res.conflicts),
      conflicts = merge_res.conflicts,
    }
  end

  self._slots = {}
  for k, v in pairs(merge_res.merged) do
    self._slots[k] = {
      name = v.name or k,
      content = v.content,
      hash = v.hash or WheelContext.compute_hash(v.content or ""),
      version = 1,
      kind = classify_slot_kind(k),
      size_bytes = (v.content and #v.content) or 0,
      updated_at_ms = WheelHost.time.now() * 1000,
    }
  end
  self._tree_hash = nil

  local msg = opts.message or string.format("Merge branch '%s' into %s", source, self:current_branch())
  local merge_commit = self:commit_checkpoint({
    author = opts.author or "wheel:merge",
    parents = { our_hash, their_hash },
    message = msg,
    rationale = opts.rationale or {
      goal = "Merge " .. tostring(source),
      approach = "3-way semantic slot merge",
      confidence = 1.0,
    },
  })

  return { success = true, fast_forward = false, commit = merge_commit }
end

--- Traverse commit ancestry and return commit log.
-- @param limit number? Maximum commits to return (default 50)
-- @return table Array of ContextCommit objects
function WheelContext:log(limit)
  limit = limit or 50
  local list = {}
  local curr = self:head_commit_hash()
  local visited = {}
  while curr and #list < limit do
    if visited[curr] then break end
    visited[curr] = true
    local c = self._commits[curr]
    if not c then break end
    table.insert(list, c)
    if c.parent_hashes and #c.parent_hashes > 0 then
      curr = c.parent_hashes[1]
    else
      curr = nil
    end
  end
  return list
end

--- Compute slot diff between two references or commits.
-- @param from_ref string Reference or commit hash
-- @param to_ref string|nil Target reference, commit hash, or working context if nil
-- @return table Diff report { added, modified, removed, unchanged, count }
function WheelContext:diff(from_ref, to_ref)
  local from_slots = {}
  if type(from_ref) == "string" then
    local c = self:get_commit(from_ref) or (self._refs["refs/heads/" .. from_ref] and self:get_commit(self._refs["refs/heads/" .. from_ref]))
    if c then from_slots = c.slots or {} end
  elseif type(from_ref) == "table" then
    from_slots = from_ref
  end

  local to_slots = {}
  if to_ref == nil then
    to_slots = self._slots
  elseif type(to_ref) == "string" then
    local c = self:get_commit(to_ref) or (self._refs["refs/heads/" .. to_ref] and self:get_commit(self._refs["refs/heads/" .. to_ref]))
    if c then to_slots = c.slots or {} end
  elseif type(to_ref) == "table" then
    to_slots = to_ref
  end

  local all_keys = {}
  for k in pairs(from_slots) do all_keys[k] = true end
  for k in pairs(to_slots) do all_keys[k] = true end

  local added = {}
  local modified = {}
  local removed = {}
  local unchanged = {}
  local count = 0

  for name in pairs(all_keys) do
    local f = from_slots[name]
    local t = to_slots[name]
    if f and not t then
      removed[name] = f
      count = count + 1
    elseif not f and t then
      added[name] = t
      count = count + 1
    elseif f and t then
      if f.hash ~= t.hash or f.content ~= t.content then
        modified[name] = { from = f, to = t }
        count = count + 1
      else
        unchanged[name] = t
      end
    end
  end

  return {
    added = added,
    modified = modified,
    removed = removed,
    unchanged = unchanged,
    count = count,
  }
end

-- ---------------------------------------------------------------------------
-- Deterministic Context Graph Projections
-- ---------------------------------------------------------------------------

local PROJECT_CATEGORIES = {
  architecture = true,
  decisions = true,
  documentation = true,
  project = true,
  security = true,
}

local PROJECTION_CATEGORY_BY_PREFIX = {
  workspace = "project",
  architecture = "architecture",
  decisions = "decisions",
  docs = "documentation",
  security = "security",
  tasks = "tasks",
  code = "source",
  diagnostics = "diagnostics",
  logs = "logs",
  research = "research",
}

local PROJECTION_CATEGORY_VALUES = {}
for _, category in pairs(PROJECTION_CATEGORY_BY_PREFIX) do
  PROJECTION_CATEGORY_VALUES[category] = true
end

local PROJECTION_MAX_RECORDS = 4096
local PROJECTION_MAX_VALUE_NODES = 100000
local PROJECTION_MAX_STRING_BYTES = 64 * 1024
local PROJECTION_MAX_REFERENCE_BYTES = 256
local PROJECTION_MAX_SEMANTIC_BYTES = 64 * 1024
local PROJECTION_MAX_BUDGET_BYTES = WheelContext.MAX_TOTAL_BUDGET_BYTES
local PROJECTION_WORK_NODES_PER_BYTE = 16
local PROJECTION_MIN_WORK_NODES = 64
local PROJECTION_MAX_SCALAR = 9007199254740991

local function projection_byte_less(left, right)
  local length = math.min(#left, #right)
  for index = 1, length do
    local left_byte = string.byte(left, index)
    local right_byte = string.byte(right, index)
    if left_byte ~= right_byte then
      return left_byte < right_byte
    end
  end
  return #left < #right
end

local function projection_escape(value)
  return (value:gsub("[\\\"\n\r\t%z\1-\31]", function(char)
    local escapes = { ["\\"] = "\\\\", ["\""] = "\\\"", ["\n"] = "\\n",
      ["\r"] = "\\r", ["\t"] = "\\t" }
    return escapes[char] or string.format("\\x%02x", string.byte(char))
  end))
end

-- Canonical plain-data encoding is intentionally local to projections. It is
-- not a wire format and rejects executable/cyclic values before they can enter
-- a caller-owned view.
local function canonical_projection_value(value, visiting, state)
  state = state or { nodes = 0, bytes = 0, bytes_limit = nil, nodes_limit = PROJECTION_MAX_VALUE_NODES }
  state.nodes = state.nodes + 1
  if state.nodes > (state.nodes_limit or PROJECTION_MAX_VALUE_NODES) then
    return nil, "value node bound exceeded"
  end
  local function charge(bytes)
    if state.bytes_limit and state.bytes + bytes > state.bytes_limit then
      return nil, "value byte bound exceeded"
    end
    state.bytes = state.bytes + bytes
    return true
  end
  local value_type = type(value)
  if value_type == "nil" then
    local ok, err = charge(4)
    if not ok then return nil, err end
    return "null"
  end
  if value_type == "string" then
    if #value > PROJECTION_MAX_STRING_BYTES then return nil, "string byte bound exceeded" end
    if state.bytes_limit and state.bytes + #value + 2 > state.bytes_limit then
      return nil, "value byte bound exceeded"
    end
    local encoded = projection_escape(value)
    local ok, err = charge(#encoded + 2)
    if not ok then return nil, err end
    return '"' .. encoded .. '"'
  end
  if value_type == "boolean" then
    local ok, err = charge(value and 4 or 5)
    if not ok then return nil, err end
    return value and "true" or "false"
  end
  if value_type == "number" then
    if value ~= value or value == math.huge or value == -math.huge then
      return nil, "non-finite number"
    end
    local encoded = string.format("%.17g", value)
    local ok, err = charge(#encoded)
    if not ok then return nil, err end
    return encoded
  end
  if value_type ~= "table" then return nil, "unsupported value type" end

  visiting = visiting or {}
  if visiting[value] then return nil, "cyclic value" end
  visiting[value] = true

  local keys = {}
  local array = true
  local count = 0
  for key in pairs(value) do
    count = count + 1
    if type(key) ~= "number" or key < 1 or key ~= math.floor(key) then
      array = false
    end
    keys[#keys + 1] = key
  end
  if array then
    for index = 1, count do
      if rawget(value, index) == nil then array = false; break end
    end
  end

  local encoded = {}
  local opening_ok, opening_err = charge(array and 1 or 1)
  if not opening_ok then visiting[value] = nil; return nil, opening_err end
  if array then
    for index = 1, count do
      local item, err = canonical_projection_value(value[index], visiting, state)
      if not item then visiting[value] = nil; return nil, err end
      if index > 1 then
        local separator_ok, separator_err = charge(1)
        if not separator_ok then visiting[value] = nil; return nil, separator_err end
      end
      encoded[index] = item
    end
    local closing_ok, closing_err = charge(1)
    if not closing_ok then visiting[value] = nil; return nil, closing_err end
    visiting[value] = nil
    return "[" .. table.concat(encoded, ",") .. "]"
  end

  for _, key in ipairs(keys) do
    if type(key) ~= "string" then
      visiting[value] = nil
      return nil, "map keys must be strings"
    end
  end
  table.sort(keys, projection_byte_less)
  for _, key in ipairs(keys) do
    local item, err = canonical_projection_value(value[key], visiting, state)
    if not item then visiting[value] = nil; return nil, err end
    local key_encoded = projection_escape(key)
    local key_ok, key_err = charge(#key_encoded + 4)
    if not key_ok then visiting[value] = nil; return nil, key_err end
    if #encoded > 0 then
      local separator_ok, separator_err = charge(1)
      if not separator_ok then visiting[value] = nil; return nil, separator_err end
    end
    encoded[#encoded + 1] = '"' .. key_encoded .. '":' .. item
  end
  local closing_ok, closing_err = charge(1)
  if not closing_ok then visiting[value] = nil; return nil, closing_err end
  visiting[value] = nil
  return "{" .. table.concat(encoded, ",") .. "}"
end

local function copy_projection_value(value, visiting)
  if type(value) ~= "table" then return value end
  visiting = visiting or {}
  if visiting[value] then return nil end
  visiting[value] = true
  local copy = {}
  for key, item in pairs(value) do
    local item_copy = copy_projection_value(item, visiting)
    if item_copy == nil and item ~= nil then
      visiting[value] = nil
      return nil
    end
    copy[key] = item_copy
  end
  visiting[value] = nil
  return copy
end

local function validate_projection_value(value, visiting, state)
  state = state or { nodes = 0, nodes_limit = PROJECTION_MAX_VALUE_NODES }
  state.nodes = state.nodes + 1
  if state.nodes > (state.nodes_limit or PROJECTION_MAX_VALUE_NODES) then return false, "value node bound exceeded" end
  local value_type = type(value)
  if value_type == "nil" or value_type == "boolean" then return true end
  if value_type == "string" then
    if #value > PROJECTION_MAX_STRING_BYTES then return false, "string byte bound exceeded" end
    return true
  end
  if value_type == "number" then
    if value ~= value or value == math.huge or value == -math.huge then
      return false, "non-finite number"
    end
    return true
  end
  if value_type ~= "table" then return false, "unsupported value type" end
  visiting = visiting or {}
  if visiting[value] then return false, "cyclic value" end
  visiting[value] = true
  local keys = {}
  local numeric = true
  local string_keys = false
  local count = 0
  for key in pairs(value) do
    count = count + 1
    if type(key) == "number" and key >= 1 and key == math.floor(key) then
      keys[#keys + 1] = key
    elseif type(key) == "string" and #key <= PROJECTION_MAX_REFERENCE_BYTES then
      numeric = false
      string_keys = true
      keys[#keys + 1] = key
    else
      visiting[value] = nil
      return false, "invalid map key"
    end
  end
  if numeric == false and #keys ~= count then
    visiting[value] = nil
    return false, "invalid map key"
  end
  if string_keys then
    for _, key in ipairs(keys) do
      if type(key) ~= "string" then
        visiting[value] = nil
        return false, "mixed array and map keys"
      end
    end
  end
  if numeric then
    for index = 1, count do
      if rawget(value, index) == nil then
        visiting[value] = nil
        return false, "sparse array"
      end
    end
  end
  for _, key in ipairs(keys) do
    local ok, err = validate_projection_value(value[key], visiting, state)
    if not ok then visiting[value] = nil; return false, err end
  end
  visiting[value] = nil
  return true
end

local function validate_projection_records(records, label, nodes_limit, records_limit)
  if records == nil then return {}, nil end
  if type(records) ~= "table" then return nil, label .. " must be an array" end
  local count = 0
  for key in pairs(records) do
    if type(key) ~= "number" or key < 1 or key ~= math.floor(key) then
      return nil, label .. " must be a dense array"
    end
    count = count + 1
    if count > (records_limit or PROJECTION_MAX_RECORDS) then
      return nil, label .. " exceeds the record bound"
    end
  end
  for index = 1, count do
    if rawget(records, index) == nil then return nil, label .. " must be a dense array" end
    if type(records[index]) ~= "table" then
      return nil, label .. "[" .. tostring(index) .. "] must be a table"
    end
    local valid, validation_err = validate_projection_value(records[index], nil,
      { nodes = 0, nodes_limit = nodes_limit or PROJECTION_MAX_VALUE_NODES })
    if not valid then
      return nil, label .. "[" .. tostring(index) .. "]: " .. validation_err
    end
  end
  return records, nil
end

local function projection_category(name)
  if type(name) ~= "string" then return nil end
  local prefix = name:match("^([^/]+)/")
  return prefix and PROJECTION_CATEGORY_BY_PREFIX[prefix] or nil
end

local function projection_work_nodes_for_budget(budget)
  return math.min(PROJECTION_MAX_VALUE_NODES,
    math.max(PROJECTION_MIN_WORK_NODES, budget * PROJECTION_WORK_NODES_PER_BYTE))
end

local function validate_projection_scalar(value, name, max_bytes)
  if value == nil then return true end
  if type(value) ~= "string" or #value == 0 or #value > max_bytes then
    return false, name .. " must be a bounded non-empty string"
  end
  return true
end

local function validate_projection_options(opts)
  local valid, err = validate_projection_scalar(opts.task_id, "task_id", PROJECTION_MAX_REFERENCE_BYTES)
  if not valid then return false, err end
  valid, err = validate_projection_scalar(opts.session_id, "session_id", PROJECTION_MAX_REFERENCE_BYTES)
  if not valid then return false, err end
  if opts.confidence ~= nil then
    if type(opts.confidence) ~= "number" or opts.confidence ~= opts.confidence
      or opts.confidence == math.huge or opts.confidence == -math.huge
      or opts.confidence < 0 or opts.confidence > 1 then
      return false, "confidence must be a finite number between 0 and 1"
    end
  end
  return true
end

local function projection_records_for_budget(budget)
  return math.min(PROJECTION_MAX_RECORDS, math.max(1, budget * 4 + 1))
end

local function projection_internal_limit(value, default, maximum)
  if value == nil then return default end
  if type(value) ~= "number" or value ~= value or value == math.huge
    or value == -math.huge or value < 1 or value ~= math.floor(value) then
    return nil
  end
  return math.min(value, maximum)
end

local function projection_scope_matches(name, category, scopes)
  if not scopes or #scopes == 0 then return true end
  for _, scope in ipairs(scopes) do
    if scope == "*" or scope == category or name == scope
      or name:sub(1, #scope + 1) == scope .. "/" then
      return true
    end
  end
  return false
end

local function role_allows_category(role, category)
  for _, allowed in ipairs(ROLE_LENSES[role] or {}) do
    if allowed == category then return true end
  end
  return false
end

local function projection_record_eligible(role, record, scopes, opts, requirement)
  local category = record.category
  if type(record.ref) ~= "string" or #record.ref == 0
    or #record.ref > PROJECTION_MAX_REFERENCE_BYTES then
    return false, "invalid_reference"
  end
  if type(category) ~= "string" or not PROJECTION_CATEGORY_VALUES[category] then
    return false, "unknown_category"
  end
  if not role_allows_category(role, category) then return false, "role_lens" end
  if record.scope ~= nil and type(record.scope) ~= "string" then
    return nil, "record scope must be a string"
  end
  if record.scope_path ~= nil and type(record.scope_path) ~= "string" then
    return nil, "record scope_path must be a string"
  end
  local scope_name = record.ref
  if record.scope_path and not projection_scope_matches(record.scope_path, category, scopes) then
    return false, "scope"
  end
  if record.scope and not projection_scope_matches(record.scope, category, scopes) then
    return false, "scope"
  end
  if not projection_scope_matches(scope_name, category, scopes) then return false, "scope" end
  if requirement == "task" and (not opts.task_id or record.task_id ~= opts.task_id) then
    return false, "task"
  end
  if requirement == "session" and (not opts.session_id or record.session_id ~= opts.session_id) then
    return false, "session"
  end
  if opts.task_id and record.task_id and record.task_id ~= opts.task_id then return false, "task" end
  if opts.session_id and record.session_id and record.session_id ~= opts.session_id then return false, "session" end
  return true
end

local function projection_commit(context, reference)
  if reference == nil then
    local hash = context:head_commit_hash()
    return hash and context:get_commit(hash) or nil
  end
  if type(reference) == "table" then
    for _, commit in pairs(context._commits) do
      if commit == reference then return commit end
    end
    return nil
  end
  if type(reference) ~= "string" then return nil end
  return context:get_commit(reference)
    or (context._refs["refs/heads/" .. reference]
      and context:get_commit(context._refs["refs/heads/" .. reference]))
end

local function projection_provenance(commit, opts, revision)
  return {
    source_commit = commit and commit.hash or nil,
    source_task = (commit and commit.task_id) or opts.task_id,
    source_session = opts.session_id,
    revision = revision or (commit and commit.timestamp_ms) or 0,
    confidence = opts.confidence or 1.0,
  }
end

local function projection_slot_record(slot, commit, opts)
  return {
    ref = "slot:" .. slot.name,
    category = projection_category(slot.name),
    name = slot.name,
    content = slot.content,
    kind = slot.kind,
    revision = slot.version,
    provenance = projection_provenance(commit, opts, slot.version),
  }
end

local function projection_slot_copy(slot)
  if not slot then return nil end
  return {
    name = slot.name,
    content = slot.content,
    hash = slot.hash,
    version = slot.version,
    kind = slot.kind,
    size_bytes = slot.size_bytes,
    updated_at_ms = slot.updated_at_ms,
  }
end

local function projection_record(record, commit, opts, index, include_provenance, nodes_limit)
  if type(record) ~= "table" then return nil, "record must be a table" end
  local valid, validation_err = validate_projection_value(record, nil,
    { nodes = 0, nodes_limit = nodes_limit or PROJECTION_MAX_VALUE_NODES })
  if not valid then return nil, validation_err end
  local copy = copy_projection_value(record)
  if not copy then return nil, "cyclic value" end
  if type(copy.ref) ~= "string" or #copy.ref == 0
    or #copy.ref > PROJECTION_MAX_REFERENCE_BYTES then
    return nil, "record ref must be a bounded non-empty string"
  end
  for _, field in ipairs({ "timestamp_ms", "revision" }) do
    local value = copy[field]
    if value ~= nil and (type(value) ~= "number" or value ~= value
        or value == math.huge or value == -math.huge
        or value < 0 or value > PROJECTION_MAX_SCALAR) then
      return nil, field .. " must be a finite bounded number"
    end
  end
  local derived_category = projection_category(copy.ref)
  if copy.category ~= nil and type(copy.category) ~= "string" then
    return nil, "record category must be a string"
  end
  if derived_category and copy.category ~= nil and copy.category ~= derived_category then
    return nil, "record category does not match its ref prefix"
  end
  copy.category = derived_category
  if include_provenance then
    copy.provenance = copy.provenance or projection_provenance(commit, opts,
      copy.revision or copy.timestamp_ms or index)
  else
    copy.provenance = nil
  end
  return copy
end

local function projection_sorted_records(records)
  table.sort(records, function(left, right)
    return tostring(left.ref) < tostring(right.ref)
  end)
end

local function projection_layer(id, name, budget, candidates, provenance)
  local selected = {}
  local omitted = {}
  local used = 0
  for _, candidate in ipairs(candidates) do
    local encoded = candidate._encoded
    local size = encoded and #encoded or (budget + 1)
    local separator = #selected > 0 and 1 or 0
    if encoded and used + separator + size <= budget then
      selected[#selected + 1] = candidate
      used = used + separator + size
    else
      omitted[#omitted + 1] = {
        ref = candidate.ref,
        reason = "byte_budget",
        bytes = size,
        provenance = candidate.provenance,
      }
    end
  end
  local rendered = {}
  for _, candidate in ipairs(selected) do rendered[#rendered + 1] = candidate._encoded end
  return {
    id = id,
    name = name,
    budget_bytes = budget,
    bytes = used,
    records = selected,
    omitted_references = omitted,
    provenance = provenance,
    text = table.concat(rendered, "\n"),
  }
end

local function prepare_projection_candidates(candidates, byte_limit)
  for _, candidate in ipairs(candidates) do
    local state = { nodes = 0, bytes = 0, bytes_limit = byte_limit and byte_limit + 1 or nil }
    local encoded, err = canonical_projection_value(candidate, nil, state)
    if not encoded and err == "value byte bound exceeded" then
      candidate._projection_oversized = true
      candidate._encoded = nil
    elseif not encoded then
      return nil, err
    else
      candidate._encoded = encoded
    end
  end
  return candidates
end

local function clean_projection_candidates(candidates)
  for _, candidate in ipairs(candidates) do
    candidate._encoded = nil
    candidate._projection_oversized = nil
  end
end

local function projection_budget(opts, name, default)
  local value = opts[name]
  if value == nil then return default end
  if type(value) ~= "number" or value ~= value or value == math.huge or value == -math.huge
    or value < 0 or value ~= math.floor(value) then return nil end
  return value
end

local function projection_error(message)
  return WheelErrors.projection_invalid(message)
end

--- Compute a structured semantic delta between two immutable commits.
-- Slot content is compared by its structured hash/record fields; no textual
-- subtraction or transcript access is involved.
-- @param base_ref string|table Base commit hash, branch, or commit
-- @param current_ref string|table Current commit hash, branch, or commit
-- @param opts table|nil { base_records, current_records, records }
-- @return table|nil Delta, or nil and an error table
function WheelContext:semantic_delta(base_ref, current_ref, opts)
  opts = opts or {}
  if type(opts) ~= "table" then return nil, projection_error("options must be a table") end
  local options_valid, options_err = validate_projection_options(opts)
  if not options_valid then return nil, projection_error(options_err) end
  local semantic_nodes_limit = projection_internal_limit(opts._projection_nodes_limit,
    PROJECTION_MAX_VALUE_NODES, PROJECTION_MAX_VALUE_NODES)
  local semantic_records_limit = projection_internal_limit(opts._projection_records_limit,
    PROJECTION_MAX_RECORDS, PROJECTION_MAX_RECORDS)
  if not semantic_nodes_limit or not semantic_records_limit then
    return nil, projection_error("internal projection limits are invalid")
  end
  local base = projection_commit(self, base_ref)
  local current = projection_commit(self, current_ref)
  if not base or not current then
    return nil, projection_error("base_commit and current_commit must resolve to commits")
  end

  local names = {}
  local seen = {}
  for name in pairs(base.slots or {}) do seen[name] = true end
  for name in pairs(current.slots or {}) do seen[name] = true end
  for name in pairs(seen) do names[#names + 1] = name end
  table.sort(names, projection_byte_less)

  local delta = { added = {}, modified = {}, removed = {}, unchanged = {}, count = 0 }
  for _, name in ipairs(names) do
    local before = (base.slots or {})[name]
    local after = (current.slots or {})[name]
    local before_hash = before and before.hash
    local after_hash = after and after.hash
    if not before then
      delta.added[#delta.added + 1] = { ref = "slot:" .. name, after = projection_slot_copy(after) }
      delta.count = delta.count + 1
    elseif not after then
      delta.removed[#delta.removed + 1] = { ref = "slot:" .. name, before = projection_slot_copy(before) }
      delta.count = delta.count + 1
    elseif before_hash ~= after_hash or before.version ~= after.version then
      delta.modified[#delta.modified + 1] = { ref = "slot:" .. name,
        before = projection_slot_copy(before), after = projection_slot_copy(after) }
      delta.count = delta.count + 1
    else
      delta.unchanged[#delta.unchanged + 1] = { ref = "slot:" .. name, after = projection_slot_copy(after) }
    end
  end

  local base_records, base_records_err = validate_projection_records(
    opts.base_records, "base_records", semantic_nodes_limit, semantic_records_limit)
  if not base_records then return nil, projection_error(base_records_err) end
  local current_records, current_records_err = validate_projection_records(
    opts.current_records or opts.records, "current_records", semantic_nodes_limit,
    semantic_records_limit)
  if not current_records then return nil, projection_error(current_records_err) end
  local before_by_ref, after_by_ref = {}, {}
  for index, record in ipairs(base_records) do
    local normalized, normalize_err = projection_record(record, base, opts, index, false,
      semantic_nodes_limit)
    if not normalized then
      return nil, projection_error("base_records[" .. tostring(index) .. "]: " .. normalize_err)
    end
    before_by_ref[normalized.ref] = normalized
  end
  for index, record in ipairs(current_records) do
    local normalized, normalize_err = projection_record(record, current, opts, index, false,
      semantic_nodes_limit)
    if not normalized then
      return nil, projection_error("current_records[" .. tostring(index) .. "]: " .. normalize_err)
    end
    after_by_ref[normalized.ref] = normalized
  end
  local record_refs = {}
  for ref in pairs(before_by_ref) do record_refs[ref] = true end
  for ref in pairs(after_by_ref) do record_refs[ref] = true end
  local sorted_record_refs = {}
  for ref in pairs(record_refs) do sorted_record_refs[#sorted_record_refs + 1] = ref end
  table.sort(sorted_record_refs, projection_byte_less)
  delta.records = { added = {}, modified = {}, removed = {}, unchanged = {} }
  for _, ref in ipairs(sorted_record_refs) do
    local before_record, after_record = before_by_ref[ref], after_by_ref[ref]
    local before_encoded, before_encode_err = before_record
      and canonical_projection_value(before_record, nil,
        { nodes = 0, bytes = 0, bytes_limit = PROJECTION_MAX_SEMANTIC_BYTES })
    local after_encoded, after_encode_err = after_record
      and canonical_projection_value(after_record, nil,
        { nodes = 0, bytes = 0, bytes_limit = PROJECTION_MAX_SEMANTIC_BYTES })
    if (before_record and not before_encoded) or (after_record and not after_encoded) then
      return nil, projection_error("semantic record exceeds bounded canonical size: "
        .. tostring(before_encode_err or after_encode_err))
    end
    if not before_record then
      delta.records.added[#delta.records.added + 1] = { ref = ref, after = after_record }
    elseif not after_record then
      delta.records.removed[#delta.records.removed + 1] = { ref = ref, before = before_record }
    elseif before_encoded ~= after_encoded then
      delta.records.modified[#delta.records.modified + 1] = { ref = ref, before = before_record, after = after_record }
    else
      delta.records.unchanged[#delta.records.unchanged + 1] = { ref = ref, after = after_record }
    end
  end
  delta.base_commit = base.hash
  delta.current_commit = current.hash
  delta.provenance = {
    source_commit = current.hash,
    base_commit = base.hash,
    source_task = current.task_id or opts.task_id,
    source_session = opts.session_id,
    revision = current.timestamp_ms,
    confidence = opts.confidence or 1.0,
  }
  return delta
end

WheelContext.compute_semantic_delta = WheelContext.semantic_delta

--- Build a deterministic role-aware P0-P4 Context projection.
-- The result is plain data and can be reconstructed from immutable commits and
-- caller-owned structured records; it never reads conversation transcripts.
-- @param opts table { base_commit, current_commit, role, task_id, session_id,
--   relevant_scopes/scopes, records, recent_records, p0_max_bytes..p4_max_bytes }
-- @return table|nil Projection, or nil and an error table
function WheelContext:project(opts)
  opts = opts or {}
  if type(opts) ~= "table" then return nil, projection_error("options must be a table") end
  local options_valid, options_err = validate_projection_options(opts)
  if not options_valid then return nil, projection_error(options_err) end
  local role = opts.role or WheelContext.Role.CODING
  if not ROLE_VALUES[role] then return nil, projection_error("unknown role: " .. tostring(role)) end
  local base = projection_commit(self, opts.base_commit)
  local current = projection_commit(self, opts.current_commit)
  if not current then return nil, projection_error("current_commit must resolve to a commit") end
  if not base then base = current end
  local scopes = opts.relevant_scopes or opts.scopes or {}
  if type(scopes) ~= "table" then return nil, projection_error("scopes must be an array") end
  local scope_count = 0
  for key, scope in pairs(scopes) do
    if type(key) ~= "number" or key < 1 or key ~= math.floor(key)
      or type(scope) ~= "string" or #scope == 0
      or #scope > PROJECTION_MAX_REFERENCE_BYTES then
      return nil, projection_error("scopes must be a dense array of bounded strings")
    end
    scope_count = scope_count + 1
  end
  for index = 1, scope_count do
    if rawget(scopes, index) == nil then return nil, projection_error("scopes must be a dense array") end
  end

  local budgets = {
    p0_max_bytes = projection_budget(opts, "p0_max_bytes", WheelContext.DEFAULT_P0_BUDGET_BYTES),
    p1_max_bytes = projection_budget(opts, "p1_max_bytes", WheelContext.DEFAULT_P1_BUDGET_BYTES),
    p2_max_bytes = projection_budget(opts, "p2_max_bytes", WheelContext.DEFAULT_P2_BUDGET_BYTES),
    p3_max_bytes = projection_budget(opts, "p3_max_bytes", WheelContext.DEFAULT_P3_BUDGET_BYTES),
    p4_max_bytes = projection_budget(opts, "p4_max_bytes", WheelContext.DEFAULT_P4_BUDGET_BYTES),
  }
  for name, value in pairs(budgets) do
    if not value or value > PROJECTION_MAX_BUDGET_BYTES then
      return nil, projection_error(name .. " must be an integer between 0 and "
        .. tostring(PROJECTION_MAX_BUDGET_BYTES))
    end
  end
  local total_budget = projection_budget(opts, "max_budget_bytes", WheelContext.DEFAULT_PROJECTION_BUDGET_BYTES)
  if not total_budget or total_budget > PROJECTION_MAX_BUDGET_BYTES then
    return nil, projection_error("max_budget_bytes must be an integer between 0 and "
      .. tostring(PROJECTION_MAX_BUDGET_BYTES))
  end
  local layer_budget_sum = budgets.p0_max_bytes + budgets.p1_max_bytes + budgets.p2_max_bytes
    + budgets.p3_max_bytes + budgets.p4_max_bytes
  if layer_budget_sum > total_budget then
    return nil, projection_error("max_budget_bytes must cover the layer budgets")
  end

  local provenance = projection_provenance(current, opts, current.timestamp_ms)
  local p0, p2, p4 = {}, {}, {}
  local assigned_record_refs = {}
  local omitted_input = {}
  local function add_omitted(ref, reason, provenance_source)
    omitted_input[#omitted_input + 1] = {
      ref = type(ref) == "string" and ref:sub(1, PROJECTION_MAX_REFERENCE_BYTES) or "(invalid)",
      reason = reason,
      provenance = provenance_source,
    }
  end
  for _, slot in ipairs((current.slots and (function()
    local list = {}
    for _, value in pairs(current.slots) do list[#list + 1] = value end
    table.sort(list, function(left, right) return left.name < right.name end)
    return list
  end)()) or {}) do
    local category = projection_category(slot.name)
    local candidate = projection_slot_record(slot, current, opts)
    if PROJECT_CATEGORIES[category] and projection_scope_matches(slot.name, category, scopes) then
      p0[#p0 + 1] = candidate
    elseif not category then
      add_omitted("slot:" .. slot.name, "unknown_category", projection_provenance(current, opts, slot.version))
    elseif not PROJECT_CATEGORIES[category] then
      add_omitted("slot:" .. slot.name, "role_lens", projection_provenance(current, opts, slot.version))
    end
    local task_prefix = opts.task_id and ("tasks/" .. opts.task_id) or nil
    if category == "tasks" and (not task_prefix or slot.name == task_prefix
        or slot.name:sub(1, #task_prefix + 1) == task_prefix .. "/")
      and projection_scope_matches(slot.name, category, scopes) then
      p2[#p2 + 1] = candidate
    end
  end

  local p1 = {}
  for _, category in ipairs(ROLE_LENSES[role]) do
    if projection_scope_matches(category, category, scopes) then
      p1[#p1 + 1] = {
        ref = "lens:" .. role .. ":" .. category,
        role = role,
        category = category,
        selected = true,
        provenance = provenance,
      }
    end
  end

  local work_nodes = projection_work_nodes_for_budget(math.min(
    budgets.p2_max_bytes, budgets.p3_max_bytes, budgets.p4_max_bytes))
  local work_records = projection_records_for_budget(math.min(
    budgets.p2_max_bytes, budgets.p3_max_bytes, budgets.p4_max_bytes))
  local current_records, current_records_err = validate_projection_records(
    opts.records, "records", work_nodes, work_records)
  if not current_records then return nil, projection_error(current_records_err) end
  local base_records, base_records_err = validate_projection_records(
    opts.base_records, "base_records", work_nodes, work_records)
  if not base_records then return nil, projection_error(base_records_err) end
  local recent_records, recent_records_err = validate_projection_records(
    opts.recent_records, "recent_records", work_nodes, work_records)
  if not recent_records then return nil, projection_error(recent_records_err) end
  for index, record in ipairs(current_records) do
    local normalized, normalize_err = projection_record(record, current, opts, index, true, work_nodes)
    if not normalized then return nil, projection_error("records[" .. tostring(index) .. "]: " .. normalize_err) end
    local eligible, eligibility_reason = projection_record_eligible(role, normalized, scopes, opts, "task")
    if eligible == nil then return nil, projection_error("records[" .. tostring(index) .. "]: " .. eligibility_reason) end
    if eligible then
      if normalized.task_id == opts.task_id then
        p2[#p2 + 1] = normalized
        assigned_record_refs[normalized.ref] = "P2"
      end
    else
      if eligibility_reason ~= "task" and eligibility_reason ~= "session" then
        add_omitted(normalized.ref, eligibility_reason, normalized.provenance)
      end
    end
    local session_eligible, session_reason = projection_record_eligible(role, normalized, scopes, opts, "session")
    if session_eligible == nil then return nil, projection_error("records[" .. tostring(index) .. "]: " .. session_reason) end
    if session_eligible and not (eligible and normalized.task_id == opts.task_id) then
      if normalized.session_id == opts.session_id then
        if not assigned_record_refs[normalized.ref] then
          p4[#p4 + 1] = normalized
          assigned_record_refs[normalized.ref] = "P4"
        end
      end
    elseif session_reason ~= "task" and session_reason ~= "session" then
      add_omitted(normalized.ref, session_reason, normalized.provenance)
    end
  end
  for index, record in ipairs(recent_records) do
    local normalized, normalize_err = projection_record(record, current, opts, index, true, work_nodes)
    if not normalized then return nil, projection_error("recent_records[" .. tostring(index) .. "]: " .. normalize_err) end
    local eligible, eligibility_reason = projection_record_eligible(role, normalized, scopes, opts)
    if eligible == nil then return nil, projection_error("recent_records[" .. tostring(index) .. "]: " .. eligibility_reason) end
    if eligible and not assigned_record_refs[normalized.ref] then
      local task_eligible, task_reason = projection_record_eligible(role, normalized, scopes, opts, "task")
      if task_eligible == nil then
        return nil, projection_error("recent_records[" .. tostring(index) .. "]: " .. task_reason)
      end
      if task_eligible and normalized.task_id == opts.task_id then
        p2[#p2 + 1] = normalized
        assigned_record_refs[normalized.ref] = "P2"
      else
        p4[#p4 + 1] = normalized
        assigned_record_refs[normalized.ref] = "P4"
      end
    elseif eligible and assigned_record_refs[normalized.ref] then
      add_omitted(normalized.ref, "duplicate_reference", normalized.provenance)
    else
      add_omitted(normalized.ref, eligibility_reason, normalized.provenance)
    end
  end
  projection_sorted_records(p0)
  projection_sorted_records(p1)
  projection_sorted_records(p2)
  table.sort(p4, function(left, right)
    local left_time = left.timestamp_ms or left.revision or 0
    local right_time = right.timestamp_ms or right.revision or 0
    if left_time ~= right_time then return left_time > right_time end
    return tostring(left.ref) < tostring(right.ref)
  end)

  local delta, delta_err = self:semantic_delta(base, current, {
    base_records = opts.base_records,
    current_records = current_records,
    task_id = opts.task_id,
    session_id = opts.session_id,
    relevant_scopes = copy_projection_value(scopes),
    confidence = opts.confidence,
    _projection_nodes_limit = work_nodes,
    _projection_records_limit = work_records,
  })
  if not delta then return nil, delta_err end
  local p3 = {}
  for _, operation in ipairs({ "added", "modified", "removed" }) do
    for _, item in ipairs(delta[operation]) do
      local category = projection_category(item.ref:sub(6))
      local slot_name = item.ref:sub(6)
      if role_allows_category(role, category)
        and projection_scope_matches(slot_name, category, scopes) then
        p3[#p3 + 1] = { ref = item.ref, operation = operation, category = category,
          before = item.before, after = item.after, provenance = delta.provenance }
      elseif not category then
        add_omitted(item.ref, "unknown_category", delta.provenance)
      end
    end
  end
  for _, operation in ipairs({ "added", "modified", "removed" }) do
    for _, item in ipairs(delta.records[operation]) do
      local before_eligible, before_reason = true, nil
      local after_eligible, after_reason = true, nil
      if item.before then before_eligible, before_reason = projection_record_eligible(role, item.before, scopes, opts) end
      if item.after then after_eligible, after_reason = projection_record_eligible(role, item.after, scopes, opts) end
      if before_eligible == nil or after_eligible == nil then
        return nil, projection_error("delta record " .. tostring(item.ref) .. ": "
          .. tostring(before_reason or after_reason))
      end
      if before_eligible and after_eligible then
        local category = (item.after or item.before).category
        p3[#p3 + 1] = { ref = item.ref, operation = operation, category = category,
          before = item.before, after = item.after, provenance = delta.provenance }
      else
        add_omitted(item.ref, before_reason or after_reason, delta.provenance)
      end
    end
  end
  projection_sorted_records(p3)
  local candidates = { p0, p1, p2, p3, p4 }
  local candidate_budgets = { budgets.p0_max_bytes, budgets.p1_max_bytes,
    budgets.p2_max_bytes, budgets.p3_max_bytes, budgets.p4_max_bytes }
  for index, list in ipairs(candidates) do
    local prepared, prepare_err = prepare_projection_candidates(list, candidate_budgets[index])
    if not prepared then return nil, projection_error(prepare_err) end
  end

  local layers = {}
  for index, definition in ipairs(PROJECTION_LAYERS) do
    layers[definition.id] = projection_layer(definition.id, definition.name,
      budgets[definition.budget], candidates[index], provenance)
  end
  local total_bytes = 0
  local omitted = {}
  for _, definition in ipairs(PROJECTION_LAYERS) do
    local layer = layers[definition.id]
    total_bytes = total_bytes + layer.bytes
    for _, reference in ipairs(layer.omitted_references) do omitted[#omitted + 1] = {
      layer = definition.id, ref = reference.ref, reason = reference.reason, bytes = reference.bytes,
      provenance = reference.provenance,
    } end
  end
  for _, reference in ipairs(omitted_input) do
    omitted[#omitted + 1] = reference
  end
  local canonical_parts = {}
  for _, definition in ipairs(PROJECTION_LAYERS) do
    canonical_parts[#canonical_parts + 1] = layers[definition.id].text
  end
  local canonical_bytes = table.concat(canonical_parts)
  total_bytes = #canonical_bytes
  for _, list in ipairs(candidates) do clean_projection_candidates(list) end
  if total_bytes > total_budget then
    return nil, projection_error("projection exceeds max_budget_bytes")
  end
  local projection = {
    version = WheelContext.PROJECTION_VERSION,
    base_commit = base.hash,
    current_commit = current.hash,
    role = role,
    task_id = opts.task_id,
    session_id = opts.session_id,
    relevant_scopes = copy_projection_value(scopes),
    budgets = budgets,
    max_budget_bytes = total_budget,
    total_bytes = total_bytes,
    layers = layers,
    omitted_references = omitted,
    provenance = provenance,
  }
  if total_bytes > total_budget then
    return nil, projection_error("projection exceeds max_budget_bytes")
  end
  projection.canonical_bytes = canonical_bytes
  return projection
end

WheelContext.project_context = WheelContext.project

-- ---------------------------------------------------------------------------
-- Versioned Snapshot Export and Restore
-- ---------------------------------------------------------------------------

-- Stash entries are intentionally outside snapshot v1, but their bus events
-- carry the full slot map. Replace that payload with bounded metadata so a
-- snapshot never smuggles stash content through the event history. Import
-- applies the same sanitizer through snapshot validation, so a crafted or
-- pre-fix unredacted snapshot cannot restore stash content either.
local SNAPSHOT_STASH_EVENT_TYPES = {
  stash_pushed = true,
  stash_popped = true,
}

local function snapshot_bus_history(bus)
  local history = bus:history()
  local sanitized = {}
  for index, event in ipairs(history) do
    if type(event) == "table" and SNAPSHOT_STASH_EVENT_TYPES[event.type]
      and type(event.stash) == "table" then
      local stash = event.stash
      local redacted = {
        id = stash.id,
        message = stash.message,
        head_hash = stash.head_hash,
        branch = stash.branch,
        timestamp_ms = stash.timestamp_ms,
        redacted = true,
      }
      local copy = {}
      for key, value in pairs(event) do
        copy[key] = value
      end
      copy.stash = redacted
      sanitized[index] = copy
    else
      sanitized[index] = event
    end
  end
  return sanitized
end

--- Export the complete in-memory context state as a versioned snapshot.
-- The snapshot is a deep, caller-owned copy: mutating it never changes the
-- context. It preserves working slots, the Merkle tree hash, HEAD, refs,
-- commits, the bounded reflog, and the bounded bus history. Stash entries,
-- bus subscribers, the kernel link, `config` directives, and local budget
-- configuration are not part of snapshot v1. Stash event slot payloads are
-- redacted from the preserved bus history on export and again by validation on
-- import, so a crafted or pre-fix unredacted snapshot cannot restore them.
-- @param opts table|nil Reserved; must be a table when provided
-- @return table|nil snapshot, or nil and a typed cause
function WheelContext:export_snapshot(opts)
  if opts ~= nil and type(opts) ~= "table" then
    return nil, WheelErrors.args_invalid("context.export_snapshot",
      "options must be a table")
  end

  local raw = {
    format = WheelContext.SNAPSHOT_FORMAT,
    version = WheelContext.SNAPSHOT_VERSION,
    slots = self._slots,
    tree_hash = self:tree_hash(),
    head = self._head,
    refs = self._refs,
    commits = self._commits,
    reflog = self._reflog,
    bus_history = snapshot_bus_history(self.bus),
  }
  local snapshot, detail = WheelSnapshot.validate(raw, snapshot_deps())
  if not snapshot then
    return nil, WheelErrors.snapshot_invalid(detail)
  end
  return snapshot
end

--- Validate a context snapshot without constructing a WheelContext.
-- @param snapshot table
-- @return boolean|nil true when valid, or nil and a typed E_SNAPSHOT_INVALID cause
function WheelContext.validate_snapshot(snapshot)
  local normalized, detail = WheelSnapshot.validate(snapshot, snapshot_deps())
  if not normalized then
    return nil, WheelErrors.snapshot_invalid(detail)
  end
  return true
end

--- Restore a new WheelContext from a validated snapshot.
-- Validation and deep copying complete before the new object is populated, so
-- a failed import never exposes a partially restored context. The snapshot
-- table is never mutated. When `opts.bus` is supplied, the snapshot bus history
-- replaces that bus's existing history and its subscribers are retained; the
-- provided bus is the only caller-owned object import mutates.
-- @param snapshot table
-- @param opts table|nil WheelContext.new options (kernel, config, bus, budgets)
-- @return WheelContext|nil, or nil and a typed cause
function WheelContext.import_snapshot(snapshot, opts)
  if opts ~= nil and type(opts) ~= "table" then
    return nil, WheelErrors.args_invalid("context.import_snapshot",
      "options must be a table")
  end

  local normalized, detail = WheelSnapshot.validate(snapshot, snapshot_deps())
  if not normalized then
    return nil, WheelErrors.snapshot_invalid(detail)
  end

  local ctx = WheelContext.new(opts)
  ctx._slots = normalized.slots
  ctx._tree_hash = normalized.tree_hash
  ctx._head = normalized.head
  ctx._refs = normalized.refs
  ctx._commits = normalized.commits
  ctx._reflog = normalized.reflog
  ctx.bus._history = normalized.bus_history
  return ctx
end

--- Canonicalize a snapshot for deterministic byte comparison.
-- Map keys are sorted bytewise and strings are escaped to printable ASCII, so
-- two semantically identical snapshots produce identical bytes regardless of
-- Lua hash-table iteration order.
-- @param snapshot table
-- @return string|nil canonical bytes, or nil and a typed cause
function WheelContext.canonical_snapshot(snapshot)
  local normalized, detail = WheelSnapshot.validate(snapshot, snapshot_deps())
  if not normalized then
    return nil, WheelErrors.snapshot_invalid(detail)
  end
  local bytes, encode_detail = WheelSnapshot.canonical_encode(normalized)
  if not bytes then
    return nil, WheelErrors.snapshot_invalid(encode_detail)
  end
  return bytes
end

-- ---------------------------------------------------------------------------
-- Prefix-Cache-Friendly Three-Zone Prompt Compilation
-- ---------------------------------------------------------------------------

--- Assemble the prompt under strict Three-Zone ordering and multi-tier budget.
--
-- Layering:
--   Zone 1 (Stable Prefix): Runtime Protocol + Rules + Tools (Pinned & Byte-stable)
--   Zone 2 (Cognitive State): Active Task + Decisions + Workspace Slots
--   Zone 3 (Dynamic Tail): Trailing Action Outcomes + Turn Prompt
--
-- @param opts table Compilation options:
--   - system_instruction: string
--   - project_rules: table Array of rule strings
--   - tool_schemas: table Array of tool schemas or definitions
--   - active_task: table|nil Active task node (id, title, status)
--   - recent_actions: table Array of recent action outcome records
--   - turn_prompt: string Current turn prompt
--   - prune_scratch: boolean If true or over budget, prunes scratch/* slots
-- @return table|nil CompiledContext, or nil, error_table
function WheelContext:compile_prompt(opts)
  opts = opts or {}

  -- 1. Construct Zone 1: Stable Invariant Prefix
  local sys = opts.system_instruction or "You are a professional software engineering AI colleague."
  local rules_arr = opts.project_rules or (self.config and self.config.directives) or {}
  local tools_arr = opts.tool_schemas or {}

  -- Canonical sort rules and tools for byte-stable prefix invariance
  local sorted_rules = {}
  for _, r in ipairs(rules_arr) do table.insert(sorted_rules, r) end
  table.sort(sorted_rules)

  local sorted_tools = {}
  for _, t in ipairs(tools_arr) do
    if type(t) == "table" and t.name then
      table.insert(sorted_tools, t.name .. ": " .. (t.description or ""))
    else
      table.insert(sorted_tools, tostring(t))
    end
  end
  table.sort(sorted_tools)

  local z1_parts = { sys }
  if #sorted_rules > 0 then
    table.insert(z1_parts, "## Core Engineering Directives\n" .. table.concat(sorted_rules, "\n"))
  end
  if #sorted_tools > 0 then
    table.insert(z1_parts, "## Available Capabilities & Tools\n" .. table.concat(sorted_tools, "\n"))
  end
  local zone1 = table.concat(z1_parts, "\n\n")

  -- Zone 1 Fail-closed check: Never silently mutate or truncate the stable prefix
  if #zone1 > self.zone1_max_bytes then
    return nil, {
      error = "zone1_budget_exceeded",
      message = string.format("Zone 1 prefix size (%d bytes) exceeds budget of %d bytes",
        #zone1, self.zone1_max_bytes),
      zone1_bytes = #zone1,
      zone1_max_bytes = self.zone1_max_bytes,
    }
  end

  local prefix_cache_key = WheelContext.compute_hash(zone1)

  -- 2. Construct Zone 2: Cognitive State (Merkle Slots)
  local function build_zone2(exclude_scratch, compress_rationale)
    local z2_parts = {}

    -- Active task context
    local act_task = opts.active_task
    if act_task then
      table.insert(z2_parts, string.format("## Active Task [%s]\nTitle: %s\nStatus: %s\nPriority: %s",
        act_task.id or "TASK", act_task.title or "", act_task.status or "running", tostring(act_task.priority or 0)))
    end

    -- Canonical sorted slots
    local all_slots = self:list_slots()
    local task_slots = {}
    local decision_slots = {}
    local workspace_slots = {}
    local scratch_slots = {}

    for _, s in ipairs(all_slots) do
      local full = self._slots[s.name]
      if full then
        if s.kind == WheelContext.SlotKind.TASK then
          table.insert(task_slots, full)
        elseif s.kind == WheelContext.SlotKind.DECISION then
          table.insert(decision_slots, full)
        elseif s.kind == WheelContext.SlotKind.WORKSPACE then
          table.insert(workspace_slots, full)
        elseif s.kind == WheelContext.SlotKind.SCRATCH and not exclude_scratch then
          table.insert(scratch_slots, full)
        end
      end
    end

    if #decision_slots > 0 then
      table.insert(z2_parts, "## Architecture & Technical Decisions")
      for _, s in ipairs(decision_slots) do
        local body = compress_rationale and s.content:sub(1, 256) or s.content
        table.insert(z2_parts, string.format("### %s\n%s", s.name, body))
      end
    end

    if #workspace_slots > 0 then
      table.insert(z2_parts, "## Workspace Context")
      for _, s in ipairs(workspace_slots) do
        table.insert(z2_parts, string.format("### %s\n%s", s.name, s.content))
      end
    end

    if #task_slots > 0 then
      table.insert(z2_parts, "## Task State & Artifacts")
      for _, s in ipairs(task_slots) do
        local body = compress_rationale and s.content:sub(1, 512) or s.content
        table.insert(z2_parts, string.format("### %s\n%s", s.name, body))
      end
    end

    if #scratch_slots > 0 then
      table.insert(z2_parts, "## Ephemeral Scratchpad")
      for _, s in ipairs(scratch_slots) do
        table.insert(z2_parts, string.format("### %s\n%s", s.name, s.content))
      end
    end

    return table.concat(z2_parts, "\n\n")
  end

  -- 3. Construct Zone 3: Dynamic Tail
  local function build_zone3(max_tail_len)
    local z3_parts = {}
    local acts = opts.recent_actions or {}
    if #acts > 0 then
      table.insert(z3_parts, "## Recent Action Outcomes")
      for _, a in ipairs(acts) do
        local summary = a.summary or a.raw_stdout or ""
        if a.spilled then
          summary = string.format("[Output spilled > %s bytes; ref=%s preview=%s]",
            tostring(a.size_bytes or 4096), a.blob_hash or "blob", summary:sub(1, 120))
        elseif #summary > 300 then
          summary = summary:sub(1, 300) .. " ...[truncated]"
        end
        table.insert(z3_parts, string.format("- Action [%s] (exit=%s, %sms): %s",
          a.action_id or a.tool or "cmd", tostring(a.exit_code or 0), tostring(a.duration_ms or 0), summary))
      end
    end

    if opts.turn_prompt and #opts.turn_prompt > 0 then
      table.insert(z3_parts, "## Current Turn Instruction\n" .. opts.turn_prompt)
    end

    local text = table.concat(z3_parts, "\n\n")
    if max_tail_len and #text > max_tail_len then
      text = text:sub(1, max_tail_len) .. "\n...[tail truncated to preserve budget]"
    end
    return text
  end

  -- Initial compilation
  local exclude_scratch = opts.prune_scratch or false
  local compress_rationale = false
  local max_tail_bytes = self.zone3_max_bytes

  local zone2 = build_zone2(exclude_scratch, compress_rationale)
  local zone3 = build_zone3(max_tail_bytes)

  local tiers_applied = {
    tier1_pruned_scratch = false,
    tier2_compressed_rationale = false,
    tier3_truncated_tail = false,
  }

  local total_bytes = #zone1 + #zone2 + #zone3

  -- Multi-tier Budget Reduction Pipeline
  if total_bytes > self.max_budget_bytes or #zone2 > self.zone2_max_bytes then
    -- Tier 1: Prune unpinned scratchpads
    exclude_scratch = true
    tiers_applied.tier1_pruned_scratch = true
    zone2 = build_zone2(exclude_scratch, compress_rationale)
    total_bytes = #zone1 + #zone2 + #zone3
  end

  if total_bytes > self.max_budget_bytes or #zone2 > self.zone2_max_bytes then
    -- Tier 2: Compress rationales and slot previews
    compress_rationale = true
    tiers_applied.tier2_compressed_rationale = true
    zone2 = build_zone2(exclude_scratch, compress_rationale)
    total_bytes = #zone1 + #zone2 + #zone3
  end

  if total_bytes > self.max_budget_bytes then
    -- Tier 3: Truncate dynamic tail (Zone 3)
    local remaining_budget = math.max(1024, self.max_budget_bytes - #zone1 - #zone2)
    max_tail_bytes = math.min(self.zone3_max_bytes, remaining_budget)
    tiers_applied.tier3_truncated_tail = true
    zone3 = build_zone3(max_tail_bytes)
    total_bytes = #zone1 + #zone2 + #zone3
  end

  local full_prompt = zone1 .. "\n\n" .. zone2 .. "\n\n" .. zone3

  return {
    success = true,
    prompt_string = full_prompt,
    zone1_prefix = zone1,
    zone2_state = zone2,
    zone3_tail = zone3,
    prefix_cache_key = prefix_cache_key,
    total_bytes = #full_prompt,
    zone1_bytes = #zone1,
    zone2_bytes = #zone2,
    zone3_bytes = #zone3,
    cache_share_ratio = (#full_prompt > 0) and (#zone1 / #full_prompt) or 0.0,
    tiers_applied = tiers_applied,
  }
end

return WheelContext
