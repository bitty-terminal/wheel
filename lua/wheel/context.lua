-- Wheel Context Engine (bitty-terminal.wheel)
-- Implements Phase 3: Shared Context Memory, Semantic Slot Bus, and
-- Prefix-Cache Optimization across peer colleague agents.
--
-- Pure Lua 5.1 compatible, zero external C dependencies, fail-closed security.

local WheelContext = {}
WheelContext.__index = WheelContext

local function load_submodule(subpath)
  local ok, mod = pcall(require, "wheel." .. subpath)
  if ok then return mod end
  ok, mod = pcall(require, "lua.wheel." .. subpath)
  if ok then return mod end
  return require(subpath)
end

local WheelConfig = load_submodule("config")

-- ---------------------------------------------------------------------------
-- Constants & Limits
-- ---------------------------------------------------------------------------

WheelContext.MAX_SLOT_NAME_BYTES = 256
WheelContext.MAX_SLOT_CONTENT_BYTES = 16 * 1024 * 1024 -- 16 MiB
WheelContext.MAX_TOTAL_BUDGET_BYTES = 64 * 1024 -- 64 KiB
WheelContext.DEFAULT_ZONE1_MAX_BYTES = 16 * 1024 -- 16 KiB
WheelContext.DEFAULT_ZONE2_MAX_BYTES = 32 * 1024 -- 32 KiB
WheelContext.DEFAULT_ZONE3_MAX_BYTES = 16 * 1024 -- 16 KiB
WheelContext.MAX_BUS_HISTORY = 64

WheelContext.SlotKind = {
  WORKSPACE = "workspace",
  TASK = "task",
  DECISION = "decision",
  SCRATCH = "scratch",
  CUSTOM = "custom",
}

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
  event.timestamp_ms = event.timestamp_ms or os.time() * 1000

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

  local h = WheelContext.compute_hash(content)
  local new_ver = current_ver + 1
  local kind = classify_slot_kind(name)
  local now_ms = os.time() * 1000

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
        updated_at_ms = os.time() * 1000,
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
    version = existing.version + 1,
    timestamp_ms = os.time() * 1000,
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

--- Append an audit record to the context reflog.
-- @param entry table Reflog descriptor
-- @return table The stored reflog record
function WheelContext:_append_reflog(entry)
  local record = {
    index = #self._reflog + 1,
    from_hash = entry.from_hash or "(empty)",
    to_hash = entry.to_hash or "(empty)",
    ref = entry.ref or self._head,
    action = entry.action or "unknown",
    message = entry.message or "",
    timestamp_ms = entry.timestamp_ms or (os.time() * 1000),
  }
  table.insert(self._reflog, record)
  if #self._reflog > 256 then
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
  local timestamp_ms = opts.timestamp_ms or (os.time() * 1000)

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
  if type(name) ~= "string" or not name:match("^[%w%._%-%/]+$") or name:find("%.%.") or name:sub(1, 1) == "/" or name:sub(-1) == "/" then
    return nil, { error = "invalid_branch_name", message = "Invalid branch name: " .. tostring(name) }
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
    timestamp_ms = os.time() * 1000,
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
      updated_at_ms = os.time() * 1000,
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
      updated_at_ms = os.time() * 1000,
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
      updated_at_ms = os.time() * 1000,
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
