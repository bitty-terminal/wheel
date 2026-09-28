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

  -- Slot store: [name] = { name, content, hash, version, kind, updated_at_ms }
  self._slots = {}
  self._tree_hash = nil

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
        base_hash = b_hash,
        our_hash = o_hash,
        their_hash = t_hash,
        base_content = b and b.content or nil,
        our_content = o and o.content or nil,
        their_content = t and t.content or nil,
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
