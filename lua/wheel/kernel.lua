-- Wheel Kernel Lua Client
-- Provides an ergonomic Lua wrapper around WheelBridge JSON-RPC dispatch,
-- supporting DAG control plane, Merkle slots, cognitive checkpoints, action auto-spillover,
-- and three-zone context compilation.

local WheelKernel = {}
WheelKernel.__index = WheelKernel

-- ---------------------------------------------------------------------------
-- JSON Codec Resolution (bitty.json -> cjson -> pure-Lua fallback)
-- ---------------------------------------------------------------------------

local JSON = {}

local function escape_str(s)
  local in_char  = {'\\', '"', '\b', '\f', '\n', '\r', '\t'}
  local out_char = {'\\\\', '\\"', '\\b', '\\f', '\\n', '\\r', '\\t'}
  for i, c in ipairs(in_char) do
    s = s:gsub(c, out_char[i])
  end
  -- Escape all remaining ASCII control characters (0x00 to 0x1F) into \u00XX hex escapes
  s = s:gsub("[%z\1-\31]", function(c)
    return string.format("\\u00%02x", string.byte(c))
  end)
  return '"' .. s .. '"'
end

function JSON.encode(val)
  local t = type(val)
  if t == "nil" then
    return "null"
  elseif t == "boolean" then
    return val and "true" or "false"
  elseif t == "number" then
    if val ~= val or val == math.huge or val == -math.huge then
      return "null"
    end
    return tostring(val)
  elseif t == "string" then
    return escape_str(val)
  elseif t == "table" then
    local count = 0
    local max_idx = 0
    local is_array = true
    for k, _ in pairs(val) do
      count = count + 1
      if type(k) == "number" and math.floor(k) == k and k >= 1 then
        if k > max_idx then max_idx = k end
      else
        is_array = false
      end
    end
    if is_array and max_idx == count and count > 0 then
      local parts = {}
      for i = 1, count do
        table.insert(parts, JSON.encode(val[i]))
      end
      return "[" .. table.concat(parts, ",") .. "]"
    elseif count == 0 then
      return "{}"
    else
      local parts = {}
      local keys = {}
      for k in pairs(val) do
        table.insert(keys, tostring(k))
      end
      table.sort(keys)
      for _, k in ipairs(keys) do
        local v = val[k]
        if v == nil and tonumber(k) then
          v = val[tonumber(k)]
        end
        table.insert(parts, escape_str(k) .. ":" .. JSON.encode(v))
      end
      return "{" .. table.concat(parts, ",") .. "}"
    end
  else
    return "null"
  end
end

local function skip_ws(str, pos)
  local _, p = str:find("^[ \t\r\n]+", pos)
  if p then return p + 1 else return pos end
end

local parse_value

local function parse_string(str, pos)
  local i = pos + 1
  local chars = {}
  local len = #str
  while i <= len do
    local c = str:sub(i, i)
    if c == '"' then
      return table.concat(chars), i + 1
    elseif c == '\\' then
      i = i + 1
      local esc = str:sub(i, i)
      if esc == '"' then table.insert(chars, '"')
      elseif esc == '\\' then table.insert(chars, '\\')
      elseif esc == '/' then table.insert(chars, '/')
      elseif esc == 'b' then table.insert(chars, '\b')
      elseif esc == 'f' then table.insert(chars, '\f')
      elseif esc == 'n' then table.insert(chars, '\n')
      elseif esc == 'r' then table.insert(chars, '\r')
      elseif esc == 't' then table.insert(chars, '\t')
      elseif esc == 'u' then
        local hex = str:sub(i + 1, i + 4)
        local code = tonumber(hex, 16) or 63
        table.insert(chars, string.char(code % 256))
        i = i + 4
      else
        table.insert(chars, esc)
      end
    else
      table.insert(chars, c)
    end
    i = i + 1
  end
  error("unterminated string at pos " .. pos)
end

local function parse_number(str, pos)
  local _, p, num_str = str:find("^(-?%d+%.?%d*[eE]?[+-]?%d*)", pos)
  if num_str then
    return tonumber(num_str), p + 1
  end
  error("invalid number at pos " .. pos)
end

local function parse_array(str, pos)
  pos = skip_ws(str, pos + 1)
  local arr = {}
  if str:sub(pos, pos) == ']' then
    return arr, pos + 1
  end
  while true do
    local val, next_pos = parse_value(str, pos)
    table.insert(arr, val)
    pos = skip_ws(str, next_pos)
    local c = str:sub(pos, pos)
    if c == ']' then
      return arr, pos + 1
    elseif c == ',' then
      pos = skip_ws(str, pos + 1)
    else
      error("expected ']' or ',' at pos " .. pos .. " got " .. tostring(c))
    end
  end
end

local function parse_object(str, pos)
  pos = skip_ws(str, pos + 1)
  local obj = {}
  if str:sub(pos, pos) == '}' then
    return obj, pos + 1
  end
  while true do
    if str:sub(pos, pos) ~= '"' then
      error("expected string key at pos " .. pos)
    end
    local key, next_pos = parse_string(str, pos)
    pos = skip_ws(str, next_pos)
    if str:sub(pos, pos) ~= ':' then
      error("expected ':' at pos " .. pos)
    end
    pos = skip_ws(str, pos + 1)
    local val, v_pos = parse_value(str, pos)
    obj[key] = val
    pos = skip_ws(str, v_pos)
    local c = str:sub(pos, pos)
    if c == '}' then
      return obj, pos + 1
    elseif c == ',' then
      pos = skip_ws(str, pos + 1)
    else
      error("expected '}' or ',' at pos " .. pos)
    end
  end
end

parse_value = function(str, pos)
  pos = skip_ws(str, pos)
  local c = str:sub(pos, pos)
  if c == '"' then
    return parse_string(str, pos)
  elseif c == '{' then
    return parse_object(str, pos)
  elseif c == '[' then
    return parse_array(str, pos)
  elseif str:sub(pos, pos + 3) == 'true' then
    return true, pos + 4
  elseif str:sub(pos, pos + 4) == 'false' then
    return false, pos + 5
  elseif str:sub(pos, pos + 3) == 'null' then
    return nil, pos + 4
  else
    return parse_number(str, pos)
  end
end

function JSON.decode(str)
  local val, _ = parse_value(str, 1)
  return val
end

-- Resolve codec
local json_codec = JSON
if type(bitty) == "table" and bitty.json then
  json_codec = bitty.json
else
  local ok, cjson = pcall(require, "cjson")
  if ok and type(cjson) == "table" and cjson.encode and cjson.decode then
    json_codec = cjson
  end
end

WheelKernel.json = json_codec
WheelKernel.JSON = JSON

-- ---------------------------------------------------------------------------
-- In-Memory Mock Dispatcher
-- ---------------------------------------------------------------------------

local function create_mock_dispatcher()
  local state = {
    active_task = nil,
    head_checkpoint = nil,
    tree_hash = "0000000000000000000000000000000000000000000000000000000000000000",
    tasks = {},
    slots = {},
    checkpoints = {},
    recent_actions = {},
    budget_config = {
      max_total_bytes = 65536,
      max_zone1_bytes = 16384,
      max_zone2_bytes = 32768,
      max_zone3_bytes = 16384,
    },
    spillover_config = {
      threshold_bytes = 4096,
      max_inline_preview_bytes = 256,
      max_recent_actions = 16,
    },
  }

  local function mock_hash(input)
    local h = 5381
    for i = 1, #input do
      h = ((h * 33) + input:byte(i)) % 4294967296
    end
    return string.format("%08x%08x%08x%08x", h, h, h, h)
  end

  local function is_subset(sub, full)
    for _, item in ipairs(sub) do
      local found = false
      for _, f in ipairs(full) do
        if f == item then found = true; break end
      end
      if not found then return false end
    end
    return true
  end

  return function(command, payload_json)
    local payload = json_codec.decode(payload_json) or {}

    if command == "kernel.status" then
      local task_count = 0
      for _ in pairs(state.tasks) do task_count = task_count + 1 end
      local slot_count = 0
      for _ in pairs(state.slots) do slot_count = slot_count + 1 end

      local res = {
        active_task = state.active_task,
        head_checkpoint = state.head_checkpoint,
        tree_hash = state.tree_hash,
        slot_count = slot_count,
        task_count = task_count,
        recent_action_count = #state.recent_actions,
        budget_config = state.budget_config,
        spillover_config = state.spillover_config,
      }
      return json_codec.encode({ success = true, data = res })

    elseif command == "task.create" then
      local id = payload.id
      if not id or id == "" then
        return json_codec.encode({ success = false, error = "missing or invalid 'id'" })
      end
      if state.tasks[id] then
        return json_codec.encode({ success = false, error = "task already exists" })
      end
      local deps = payload.dependencies or {}
      local status = (#deps == 0) and "ready" or "pending"
      local task = {
        id = id,
        title = payload.title or id,
        description = payload.description or "",
        priority = payload.priority or 0,
        status = status,
        dependencies = deps,
        generation = 0,
        assigned_agent = payload.assigned_agent or payload.worker_id,
        worker_id = payload.assigned_agent or payload.worker_id,
        checkpoint = nil,
        failure_reason = nil,
        created_at_ms = payload.now_ms or 0,
        updated_at_ms = payload.now_ms or 0,
      }
      state.tasks[id] = task
      return json_codec.encode({ success = true, data = task })

    elseif command == "task.get" then
      local id = payload.id
      local task = state.tasks[id]
      return json_codec.encode({ success = true, data = task })

    elseif command == "task.list" then
      local list = {}
      for _, t in pairs(state.tasks) do
        table.insert(list, t)
      end
      table.sort(list, function(a, b) return a.id < b.id end)
      return json_codec.encode({ success = true, data = list })

    elseif command == "task.set_active" then
      local id = payload.id
      if id == "" or id == nil then
        state.active_task = nil
      else
        if not state.tasks[id] then
          return json_codec.encode({ success = false, error = "task not found: " .. tostring(id) })
        end
        state.active_task = id
      end
      return json_codec.encode({ success = true, data = { active_task = state.active_task } })

    elseif command == "task.start" then
      local id = payload.id
      local task = state.tasks[id]
      if not task then
        return json_codec.encode({ success = false, error = "task not found: " .. tostring(id) })
      end
      if (task.status or ""):lower() ~= "ready" then
        return json_codec.encode({ success = false, error = "task is not ready: " .. tostring(task.status) })
      end
      local worker = payload.assigned_agent or payload.worker_id or "worker"
      task.status = "running"
      task.generation = task.generation + 1
      task.assigned_agent = worker
      task.worker_id = worker
      task.updated_at_ms = payload.now_ms or 0
      return json_codec.encode({ success = true, data = task })

    elseif command == "task.complete" then
      local id = payload.id
      local task = state.tasks[id]
      if not task then
        return json_codec.encode({ success = false, error = "task not found" })
      end
      if (task.status or ""):lower() ~= "running" then
        return json_codec.encode({ success = false, error = "task is not running" })
      end
      if payload.expected_generation ~= task.generation then
        return json_codec.encode({ success = false, error = "stale generation" })
      end
      task.status = "succeeded"
      task.checkpoint = payload.checkpoint
      task.updated_at_ms = payload.now_ms or 0

      -- Promote pending dependents whose dependencies are now all succeeded
      for _, other in pairs(state.tasks) do
        if (other.status or ""):lower() == "pending" then
          local all_succeeded = true
          for _, dep_id in ipairs(other.dependencies) do
            local dep = state.tasks[dep_id]
            if not dep or (dep.status or ""):lower() ~= "succeeded" then
              all_succeeded = false
              break
            end
          end
          if all_succeeded then
            other.status = "ready"
            other.updated_at_ms = payload.now_ms or 0
          end
        end
      end
      return json_codec.encode({ success = true, data = task })

    elseif command == "task.fail" then
      local id = payload.id
      local task = state.tasks[id]
      if not task then
        return json_codec.encode({ success = false, error = "task not found" })
      end
      if payload.expected_generation ~= task.generation then
        return json_codec.encode({ success = false, error = "stale generation" })
      end
      local err_msg = payload.failure_reason or payload.error or "unknown failure"
      task.status = "failed"
      task.failure_reason = err_msg
      task.error = err_msg
      task.updated_at_ms = payload.now_ms or 0

      -- Cascade blocked to downstream dependents
      local function block_dependents(failed_id)
        for _, other in pairs(state.tasks) do
          for _, dep_id in ipairs(other.dependencies) do
            local other_st = (other.status or ""):lower()
            if dep_id == failed_id and other_st ~= "succeeded" and other_st ~= "failed" then
              other.status = "blocked"
              other.updated_at_ms = payload.now_ms or 0
              block_dependents(other.id)
            end
          end
        end
      end
      block_dependents(id)
      return json_codec.encode({ success = true, data = task })

    elseif command == "task.cancel" then
      local id = payload.id
      local task = state.tasks[id]
      if not task then
        return json_codec.encode({ success = false, error = "task not found" })
      end
      task.status = "cancelled"
      task.updated_at_ms = payload.now_ms or 0
      return json_codec.encode({ success = true, data = task })

    elseif command == "task.retry" then
      local id = payload.id
      local task = state.tasks[id]
      if not task then
        return json_codec.encode({ success = false, error = "task not found" })
      end
      local all_succeeded = true
      for _, dep_id in ipairs(task.dependencies) do
        local dep = state.tasks[dep_id]
        if not dep or (dep.status or ""):lower() ~= "succeeded" then
          all_succeeded = false
          break
        end
      end
      task.status = all_succeeded and "ready" or "pending"
      task.failure_reason = nil
      task.error = nil
      task.updated_at_ms = payload.now_ms or 0
      return json_codec.encode({ success = true, data = task })

    elseif command == "task.topological_sort" then
      -- Kahn's algorithm
      local in_degree = {}
      local adj = {}
      for id, t in pairs(state.tasks) do
        in_degree[id] = #t.dependencies
        adj[id] = {}
      end
      for id, t in pairs(state.tasks) do
        for _, dep in ipairs(t.dependencies) do
          if adj[dep] then
            table.insert(adj[dep], id)
          end
        end
      end
      local queue = {}
      for id, deg in pairs(in_degree) do
        if deg == 0 then table.insert(queue, id) end
      end
      table.sort(queue)
      local order = {}
      while #queue > 0 do
        local cur = table.remove(queue, 1)
        table.insert(order, cur)
        for _, nxt in ipairs(adj[cur] or {}) do
          in_degree[nxt] = in_degree[nxt] - 1
          if in_degree[nxt] == 0 then
            table.insert(queue, nxt)
          end
        end
        table.sort(queue)
      end
      return json_codec.encode({ success = true, data = order })

    elseif command == "slot.put" then
      local name = payload.name
      local content = payload.content or ""
      local h = mock_hash(content)
      state.slots[name] = {
        name = name,
        hash = h,
        content = content,
        size_bytes = #content,
      }
      state.tree_hash = mock_hash(state.tree_hash .. name .. h)
      return json_codec.encode({
        success = true,
        data = { name = name, hash = h, size_bytes = #content },
      })

    elseif command == "slot.get" then
      local slot = state.slots[payload.name]
      if slot then
        return json_codec.encode({
          success = true,
          data = { name = slot.name, found = true, content = slot.content, size_bytes = slot.size_bytes },
        })
      else
        return json_codec.encode({
          success = true,
          data = { name = payload.name, found = false },
        })
      end

    elseif command == "slot.remove" then
      local removed = (state.slots[payload.name] ~= nil)
      state.slots[payload.name] = nil
      return json_codec.encode({
        success = true,
        data = { name = payload.name, removed = removed },
      })

    elseif command == "slot.list" then
      local list = {}
      for _, s in pairs(state.slots) do
        table.insert(list, { name = s.name, hash = s.hash, kind = "Blob", size_bytes = s.size_bytes })
      end
      table.sort(list, function(a, b) return a.name < b.name end)
      return json_codec.encode({ success = true, data = list })

    elseif command == "checkpoint.commit" then
      local rat = payload.rationale or {}
      local h = mock_hash(json_codec.encode(rat) .. state.tree_hash)
      local cp = {
        hash = h,
        tree_hash = state.tree_hash,
        parents = state.head_checkpoint and { state.head_checkpoint } or {},
        rationale = rat,
        branch = payload.branch or "main",
        timestamp_ms = payload.now_ms or 0,
      }
      state.checkpoints[h] = cp
      state.head_checkpoint = h
      return json_codec.encode({ success = true, data = cp })

    elseif command == "checkpoint.get" then
      local cp = state.checkpoints[payload.hash]
      if not cp then
        return json_codec.encode({ success = false, error = "checkpoint not found" })
      end
      return json_codec.encode({ success = true, data = cp })

    elseif command == "checkpoint.log" then
      local list = {}
      local cur = state.head_checkpoint
      local depth = payload.max_depth or 16
      while cur and depth > 0 do
        local cp = state.checkpoints[cur]
        if not cp then break end
        table.insert(list, cp)
        cur = cp.parents and cp.parents[1]
        depth = depth - 1
      end
      return json_codec.encode({ success = true, data = list })

    elseif command == "action.record" then
      local raw_out = payload.raw_stdout or ""
      local raw_err = payload.raw_stderr or ""
      local is_spill = (#raw_out > 4096 or #raw_err > 4096)
      local action = {
        action_id = payload.action_id,
        success = payload.success ~= false,
        exit_code = payload.exit_code or 0,
        duration_ms = payload.duration_ms or 0,
        raw_stdout = raw_out,
        raw_stderr = raw_err,
        spilled = is_spill,
      }
      table.insert(state.recent_actions, action)
      if #state.recent_actions > 16 then
        table.remove(state.recent_actions, 1)
      end
      return json_codec.encode({ success = true, data = action })

    elseif command == "action.recent" then
      return json_codec.encode({ success = true, data = state.recent_actions })

    elseif command == "action.clear" then
      state.recent_actions = {}
      return json_codec.encode({ success = true, data = { cleared = true } })

    elseif command == "context.compile" then
      local sys = payload.system_instruction or ""
      local rules = table.concat(payload.project_rules or {}, "\n")
      local tools = table.concat(payload.tool_schemas or {}, "\n")
      local z1 = table.concat({ sys, rules, tools }, "\n\n")

      local task_lines = {}
      if state.active_task and state.tasks[state.active_task] then
        local t = state.tasks[state.active_task]
        table.insert(task_lines, string.format("Active Task: %s (%s) - %s", t.id, t.status, t.title))
      end
      for _, s in pairs(state.slots) do
        table.insert(task_lines, string.format("Slot [%s]: %s", s.name, s.content))
      end
      local z2 = table.concat(task_lines, "\n")

      local act_lines = {}
      for _, a in ipairs(state.recent_actions) do
        table.insert(act_lines, string.format("Action %s [exit=%s]: %s", a.action_id, tostring(a.exit_code), a.raw_stdout:sub(1, 100)))
      end
      table.insert(act_lines, payload.turn_prompt or "")
      local z3 = table.concat(act_lines, "\n")

      local pref_hash = mock_hash(z1)
      local full = z1 .. "\n\n" .. z2 .. "\n\n" .. z3

      local res = {
        zone1_prefix = z1,
        zone2_state = z2,
        zone3_tail = z3,
        prefix_hash = pref_hash,
        total_bytes = #full,
        prompt_string = full,
        pruned_slots = 0,
        summarized_checkpoints = 0,
        truncated_tail = false,
      }
      return json_codec.encode({ success = true, data = res })

    else
      return json_codec.encode({ success = false, error = "unknown mock command: " .. tostring(command) })
    end
  end
end

-- ---------------------------------------------------------------------------
-- WheelKernel Client Implementation
-- ---------------------------------------------------------------------------

function WheelKernel.new(dispatcher_or_opts)
  local dispatcher = nil
  if type(dispatcher_or_opts) == "function" then
    dispatcher = dispatcher_or_opts
  elseif type(dispatcher_or_opts) == "table" and type(dispatcher_or_opts.dispatcher) == "function" then
    dispatcher = dispatcher_or_opts.dispatcher
  end
  local self = setmetatable({}, WheelKernel)
  self.dispatcher = dispatcher or create_mock_dispatcher()
  return self
end

--- Create an in-memory mock WheelKernel instance for headless testing and previews.
--- @return table
function WheelKernel.new_mock()
  return WheelKernel.new(create_mock_dispatcher())
end

--- Internal helper executing a command over the dispatcher and decoding JSON response.
--- @param command string
--- @param payload table?
--- @return any
function WheelKernel:call(command, payload)
  local payload_str = json_codec.encode(payload or {})
  local resp_str = self.dispatcher(command, payload_str)
  local resp = json_codec.decode(resp_str)
  if not resp or not resp.success then
    error((resp and resp.error) or "unknown wheel bridge error")
  end
  return resp.data
end

--- Query kernel status and telemetry.
--- @return table
function WheelKernel:status()
  return self:call("kernel.status", {})
end

--- Create a new task in the control plane DAG.
--- @param draft table { id: string, title: string, description: string, priority: number?, dependencies: string[]?, now_ms: number? }
--- @return table
function WheelKernel:create_task(draft)
  return self:call("task.create", draft)
end

--- Retrieve a task by its identifier.
--- @param id string
--- @return table
function WheelKernel:get_task(id)
  return self:call("task.get", { id = id })
end

--- List all tasks currently managed in the DAG.
--- @return table[]
function WheelKernel:list_tasks()
  return self:call("task.list", {})
end

--- Set or clear the active task driving Zone 2 context compilation.
--- @param id string?
--- @return table
function WheelKernel:set_active_task(id)
  return self:call("task.set_active", { id = id })
end

--- Start a task, binding a worker identity.
--- @param id string
--- @param worker_id string?
--- @param now_ms number?
--- @return table
function WheelKernel:start_task(id, worker_id, now_ms)
  local worker = worker_id or "worker"
  return self:call("task.start", {
    id = id,
    worker_id = worker,
    assigned_agent = worker,
    now_ms = now_ms or 0,
  })
end

--- Complete a task successfully, promoting dependent tasks to Ready.
--- @param id string
--- @param expected_generation number
--- @param checkpoint string? Optional ContentHash string
--- @param now_ms number?
--- @return table
function WheelKernel:complete_task(id, expected_generation, checkpoint, now_ms)
  return self:call("task.complete", {
    id = id,
    expected_generation = expected_generation,
    checkpoint = checkpoint,
    now_ms = now_ms or 0,
  })
end

--- Mark a task failed, propagating Blocked across downstream dependents.
--- @param id string
--- @param expected_generation number
--- @param error_message string
--- @param now_ms number?
--- @return table
function WheelKernel:fail_task(id, expected_generation, error_message, now_ms)
  return self:call("task.fail", {
    id = id,
    expected_generation = expected_generation,
    error = error_message,
    failure_reason = error_message,
    now_ms = now_ms or 0,
  })
end

--- Cancel a task, propagating Blocked across downstream dependents.
--- @param id string
--- @param now_ms number?
--- @return table
function WheelKernel:cancel_task(id, now_ms)
  return self:call("task.cancel", {
    id = id,
    now_ms = now_ms or 0,
  })
end

--- Retry a failed or cancelled task.
--- @param id string
--- @param now_ms number?
--- @return table
function WheelKernel:retry_task(id, now_ms)
  return self:call("task.retry", {
    id = id,
    now_ms = now_ms or 0,
  })
end

--- Compute topological ordering of tasks.
--- @return string[]
function WheelKernel:topological_sort()
  return self:call("task.topological_sort", {})
end

--- Put a slot in the Merkle context tree and content store.
--- @param name string
--- @param content string
--- @param now_ms number?
--- @return table { name: string, hash: string, size_bytes: number }
function WheelKernel:put_slot(name, content, now_ms)
  return self:call("slot.put", {
    name = name,
    content = content,
    now_ms = now_ms or 0,
  })
end

--- Retrieve a slot from the Merkle context tree.
--- @param name string
--- @return table { name: string, found: boolean, content: string?, size_bytes: number? }
function WheelKernel:get_slot(name)
  return self:call("slot.get", { name = name })
end

--- Remove a slot from the active Merkle context tree.
--- @param name string
--- @return table { name: string, removed: boolean }
function WheelKernel:remove_slot(name)
  return self:call("slot.remove", { name = name })
end

--- List all slots in the active Merkle context tree.
--- @return table[]
function WheelKernel:list_slots()
  return self:call("slot.list", {})
end

--- Commit a cognitive checkpoint.
--- @param rationale table { why: string, what: string, where_focus: string?, how: string?, expected: string?, observed: string? }
--- @param branch string? Optional ref name
--- @param now_ms number?
--- @return table
function WheelKernel:commit_checkpoint(rationale, branch, now_ms)
  return self:call("checkpoint.commit", {
    rationale = rationale,
    branch = branch,
    now_ms = now_ms or 0,
  })
end

--- Retrieve a checkpoint by hash.
--- @param hash string
--- @return table
function WheelKernel:get_checkpoint(hash)
  return self:call("checkpoint.get", { hash = hash })
end

--- Retrieve backward checkpoint history log.
--- @param max_depth number?
--- @return table[]
function WheelKernel:log(max_depth)
  return self:call("checkpoint.log", { max_depth = max_depth or 16 })
end

--- Record an action outcome with auto-spillover.
--- @param action table { action_id: string, success: boolean?, exit_code: number?, duration_ms: number?, raw_stdout: string?, raw_stderr: string?, timestamp_ms: number? }
--- @return table
function WheelKernel:record_action(action)
  return self:call("action.record", action)
end

--- List recent action outcomes.
--- @return table[]
function WheelKernel:recent_actions()
  return self:call("action.recent", {})
end

--- Clear recent action outcomes.
function WheelKernel:clear_recent_actions()
  return self:call("action.clear", {})
end

--- Compile three-zone context prompt under multi-tier budget.
--- @param opts table { system_instruction: string?, project_rules: string[]?, tool_schemas: string[]?, turn_prompt: string? }
--- @return table { zone1_prefix: string, zone2_state: string, zone3_tail: string, prefix_hash: string, total_bytes: number, prompt_string: string, ... }
function WheelKernel:compile_context(opts)
  return self:call("context.compile", opts or {})
end

return WheelKernel
