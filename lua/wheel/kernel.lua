-- Wheel Kernel Lua Client
-- Provides an ergonomic Lua wrapper around WheelBridge JSON-RPC dispatch,
-- supporting DAG control plane, Merkle slots, cognitive checkpoints, action auto-spillover,
-- and three-zone context compilation.

local WheelKernel = {}
local MAX_TASK_GENERATION = 9007199254740991

local TASK_STATUS = {
  pending = "pending", ready = "ready", running = "in_progress", in_progress = "in_progress",
  succeeded = "completed", completed = "completed", failed = "failed",
  cancelled = "cancelled", blocked = "blocked",
}

function WheelKernel.normalize_lifecycle_status(status)
  return TASK_STATUS[type(status) == "string" and status:lower() or ""] or "unknown"
end
local TASK_TRANSITIONS = {
  ["task.complete"] = { in_progress = true }, ["task.fail"] = { in_progress = true },
  ["task.cancel"] = { in_progress = true }, ["task.reassign"] = { in_progress = true },
  ["task.retry"] = { failed = true, cancelled = true },
}

local function task_transition_error(task, payload, allowed, owner_field)
  local status = WheelKernel.normalize_lifecycle_status(task.status)
  if not allowed[status] or task.lifecycle_status ~= status then return "task lifecycle state is invalid" end
  if type(task.generation) ~= "number" or task.generation < 1
    or task.generation > MAX_TASK_GENERATION or task.generation % 1 ~= 0
    or type(payload.expected_generation) ~= "number" or payload.expected_generation ~= task.generation then
    return "stale generation"
  end
  local owner = payload[owner_field or "assigned_agent"]
  if type(owner) ~= "string" or owner == "" or task.worker_id ~= owner
    or task.assigned_agent ~= owner then return "task owner mismatch" end
end

local function task_start_error(task, payload, tasks)
  local status = WheelKernel.normalize_lifecycle_status(task.status)
  if status ~= "ready" or task.lifecycle_status ~= "ready" then return "task is not ready" end
  if type(task.generation) ~= "number" or task.generation < 0
    or task.generation >= MAX_TASK_GENERATION or task.generation % 1 ~= 0 then
    return "task generation exhausted or invalid"
  end
  if payload.expected_generation ~= nil
    and (type(payload.expected_generation) ~= "number"
      or payload.expected_generation ~= task.generation) then
    return "stale generation"
  end
  local worker = payload.assigned_agent or payload.worker_id
  if type(worker) ~= "string" or worker == "" then return "worker identity is required" end
  if task.worker_id and task.worker_id ~= "" and task.worker_id ~= worker then return "task owner mismatch" end
  for _, dependency_id in ipairs(task.dependencies or {}) do
    local dependency = tasks and tasks[dependency_id]
    if not dependency or WheelKernel.normalize_lifecycle_status(dependency.status) ~= "completed" then
      return "task dependencies are not completed"
    end
  end
end
WheelKernel.__index = WheelKernel

local ok_action, WheelAction = pcall(require, "wheel.action")
if not ok_action then WheelAction = nil end
local ok_rationale, Rationale = pcall(require, "wheel.rationale")
if not ok_rationale then Rationale = nil end

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
    return string.format("%.17g", val)
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

local function append_utf8(chars, codepoint)
  if codepoint <= 0x7f then
    table.insert(chars, string.char(codepoint))
  elseif codepoint <= 0x7ff then
    table.insert(chars, string.char(
      0xc0 + math.floor(codepoint / 0x40),
      0x80 + codepoint % 0x40
    ))
  elseif codepoint <= 0xffff then
    table.insert(chars, string.char(
      0xe0 + math.floor(codepoint / 0x1000),
      0x80 + math.floor(codepoint / 0x40) % 0x40,
      0x80 + codepoint % 0x40
    ))
  else
    table.insert(chars, string.char(
      0xf0 + math.floor(codepoint / 0x40000),
      0x80 + math.floor(codepoint / 0x1000) % 0x40,
      0x80 + math.floor(codepoint / 0x40) % 0x40,
      0x80 + codepoint % 0x40
    ))
  end
end

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
        if not hex:match("^%x%x%x%x$") then
          error("invalid Unicode escape at pos " .. i)
        end
        local codepoint = tonumber(hex, 16)
        i = i + 4
        if codepoint >= 0xd800 and codepoint <= 0xdbff then
          if str:sub(i + 1, i + 2) ~= "\\u" then
            error("missing low surrogate at pos " .. i)
          end
          local low_hex = str:sub(i + 3, i + 6)
          if not low_hex:match("^%x%x%x%x$") then
            error("invalid low surrogate at pos " .. (i + 2))
          end
          local low = tonumber(low_hex, 16)
          if low < 0xdc00 or low > 0xdfff then
            error("invalid low surrogate at pos " .. (i + 2))
          end
          codepoint = 0x10000 + (codepoint - 0xd800) * 0x400 + (low - 0xdc00)
          i = i + 6
        elseif codepoint >= 0xdc00 and codepoint <= 0xdfff then
          error("unexpected low surrogate at pos " .. i)
        end
        append_utf8(chars, codepoint)
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

local function valid_dependency_list(tasks, task_id, dependencies)
  if type(dependencies) ~= "table" or getmetatable(dependencies) ~= nil then return false end
  local count, seen = 0, {}
  for key in pairs(dependencies) do
    if type(key) ~= "number" or key < 1 or key % 1 ~= 0 then return false end
    count = count + 1
  end
  if count ~= #dependencies then return false end
  for _, dependency_id in ipairs(dependencies) do
    if type(dependency_id) ~= "string" or dependency_id == "" or #dependency_id > 128
      or not dependency_id:match("^[A-Za-z0-9][A-Za-z0-9._:/%-]*$")
      or dependency_id == task_id or seen[dependency_id] or not tasks[dependency_id] then
      return false
    end
    seen[dependency_id] = true
  end
  return true
end

-- Kahn validation plus a memoized parent walk: O(tasks + edges) time/space.
local function valid_dependency_graph(tasks)
  local indegree, downstream, count = {}, {}, 0
  for task_id, task in pairs(tasks) do
    if not valid_dependency_list(tasks, task_id, task.dependencies) then return false end
    indegree[task_id], downstream[task_id] = #task.dependencies, {}
    count = count + 1
  end
  for task_id, task in pairs(tasks) do
    for _, dependency_id in ipairs(task.dependencies) do
      downstream[dependency_id][#downstream[dependency_id] + 1] = task_id
    end
  end
  local queue = {}
  for task_id, degree in pairs(indegree) do
    if degree == 0 then queue[#queue + 1] = task_id end
  end
  local index = 1
  while index <= #queue do
    for _, dependent in ipairs(downstream[queue[index]]) do
      indegree[dependent] = indegree[dependent] - 1
      if indegree[dependent] == 0 then queue[#queue + 1] = dependent end
    end
    index = index + 1
  end
  if #queue ~= count then return false end
  local complete = {}
  for task_id in pairs(tasks) do
    local current, path = task_id, {}
    while current and not complete[current] do
      if path[current] or not tasks[current] then return false end
      path[current] = true
      local parent = tasks[current].parent_task_id
      if parent ~= nil and (type(parent) ~= "string" or parent == "" or not tasks[parent]) then return false end
      current = parent
    end
    for ancestor in pairs(path) do complete[ancestor] = true end
  end
  return true
end

local function create_mock_dispatcher()
  local lifecycle_status = WheelKernel.normalize_lifecycle_status
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

  local function transition_error(task, payload, allowed, owner_field)
    if not valid_dependency_graph(state.tasks) then return "task dependency graph is invalid" end
    return task_transition_error(task, payload, allowed, owner_field)
  end

  local function dispatch(command, payload_json)
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
      if type(id) ~= "string" or id == "" or #id > 128
        or not id:match("^[A-Za-z0-9][A-Za-z0-9._:/%-]*$") then
        return json_codec.encode({ success = false, error = "missing or invalid 'id'" })
      end
      if state.tasks[id] then
        return json_codec.encode({ success = false, error = "task already exists" })
      end
      if not valid_dependency_graph(state.tasks) then
        return json_codec.encode({ success = false, error = "task dependency graph is invalid" })
      end
      local deps = payload.dependencies == nil and {} or payload.dependencies
      if type(deps) ~= "table" or getmetatable(deps) ~= nil then
        return json_codec.encode({ success = false, error = "dependencies must be a plain dense list" })
      end
      local dep_count = 0
      for key in pairs(deps) do
        if type(key) ~= "number" or key < 1 or key % 1 ~= 0 then
          return json_codec.encode({ success = false, error = "dependencies must be a plain dense list" })
        end
        dep_count = dep_count + 1
      end
      if dep_count ~= #deps then
        return json_codec.encode({ success = false, error = "dependencies must be a plain dense list" })
      end
      local seen_dependencies = {}
      for _, dep_id in ipairs(deps) do
        if type(dep_id) ~= "string" or dep_id == "" or #dep_id > 128
          or not dep_id:match("^[A-Za-z0-9][A-Za-z0-9._:/%-]*$") then
          return json_codec.encode({ success = false, error = "dependency id is invalid" })
        end
        if dep_id == id then
          return json_codec.encode({ success = false, error = "task cannot depend on itself" })
        end
        if seen_dependencies[dep_id] then
          return json_codec.encode({ success = false, error = "duplicate task dependency" })
        end
        if not state.tasks[dep_id] then
          return json_codec.encode({ success = false, error = "dependency task not found: " .. dep_id })
        end
        seen_dependencies[dep_id] = true
      end
      if payload.parent_task_id ~= nil and (type(payload.parent_task_id) ~= "string"
        or payload.parent_task_id == "" or #payload.parent_task_id > 128
        or payload.parent_task_id:find("[%z\1-\31\127]")
        or not payload.parent_task_id:match("^[A-Za-z0-9][A-Za-z0-9._:/%-]*$")) then
        return json_codec.encode({ success = false, error = "parent_task_id is invalid" })
      end
      if payload.parent_task_id and not state.tasks[payload.parent_task_id] then
        return json_codec.encode({ success = false, error = "parent task not found: " .. tostring(payload.parent_task_id) })
      end
      if payload.parent_task_id == id then
        return json_codec.encode({ success = false, error = "task cannot be its own parent" })
      end
      local ancestor, seen_ancestors = payload.parent_task_id, {}
      while ancestor do
        if ancestor == id then
          return json_codec.encode({ success = false, error = "parent task cycle detected" })
        end
        if seen_ancestors[ancestor] then
          return json_codec.encode({ success = false, error = "parent task hierarchy is invalid" })
        end
        seen_ancestors[ancestor] = true
        local ancestor_task = state.tasks[ancestor]
        if not ancestor_task then
          return json_codec.encode({ success = false, error = "parent task hierarchy is invalid" })
        end
        ancestor = ancestor_task.parent_task_id
      end
      local status = "ready"
      for _, dependency_id in ipairs(deps) do
        if lifecycle_status(state.tasks[dependency_id].status) ~= "completed" then status = "pending"; break end
      end
      local task = {
        id = id,
        title = payload.title or id,
        description = payload.description or "",
        priority = payload.priority or 0,
        status = status,
        lifecycle_status = lifecycle_status(status),
        dependencies = deps,
        parent_task_id = payload.parent_task_id,
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
      if not valid_dependency_graph(state.tasks) then
        return json_codec.encode({ success = false, error = "task dependency graph is invalid" })
      end
      local worker = payload.assigned_agent or payload.worker_id or "worker"
      local start_error = task_start_error(task, {
        expected_generation = payload.expected_generation,
        assigned_agent = worker,
        worker_id = worker,
      }, state.tasks)
      if start_error then return json_codec.encode({ success = false, error = start_error }) end
      task.status = "running"
      task.lifecycle_status = lifecycle_status(task.status)
      task.generation = task.generation + 1
      task.assigned_agent = worker
      task.worker_id = worker
      task.updated_at_ms = payload.now_ms or 0
      return json_codec.encode({ success = true, data = task })

    elseif command == "task.reassign" then
      local task = state.tasks[payload.id]
      if not task then return json_codec.encode({ success = false, error = "task not found" }) end
      local err = transition_error(task, payload, { in_progress = true }, "source_agent")
      if err then return json_codec.encode({ success = false, error = err }) end
      if task.generation >= MAX_TASK_GENERATION then return json_codec.encode({ success = false, error = "task generation exhausted" }) end
      if type(payload.assigned_agent) ~= "string" or payload.assigned_agent == "" then
        return json_codec.encode({ success = false, error = "assigned_agent is required" })
      end
      task.status = "running"
      task.lifecycle_status = lifecycle_status(task.status)
      task.generation = task.generation + 1
      task.assigned_agent, task.worker_id = payload.assigned_agent, payload.assigned_agent
      task.updated_at_ms = payload.now_ms or 0
      return json_codec.encode({ success = true, data = task })

    elseif command == "task.complete" then
      local id = payload.id
      local task = state.tasks[id]
      if not task then
        return json_codec.encode({ success = false, error = "task not found" })
      end
      local err = transition_error(task, payload, { in_progress = true })
      if err then return json_codec.encode({ success = false, error = err }) end
      task.status = "succeeded"
      task.lifecycle_status = lifecycle_status(task.status)
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
            other.lifecycle_status = lifecycle_status(other.status)
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
      local err = transition_error(task, payload, { in_progress = true })
      if err then return json_codec.encode({ success = false, error = err }) end
      local err_msg = payload.failure_reason or payload.error or "unknown failure"
      task.status = "failed"
      task.lifecycle_status = lifecycle_status(task.status)
      task.failure_reason = err_msg
      task.error = err_msg
      task.updated_at_ms = payload.now_ms or 0

      -- Cascade blocked to downstream dependents
      local visited = {}
      local function block_dependents(failed_id)
        if visited[failed_id] then return end
        visited[failed_id] = true
        for _, other in pairs(state.tasks) do
          for _, dep_id in ipairs(other.dependencies) do
            local other_st = lifecycle_status(other.status)
            if dep_id == failed_id and (other_st == "pending" or other_st == "ready" or other_st == "blocked") then
              other.status = "blocked"
              other.lifecycle_status = lifecycle_status(other.status)
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
      local err = transition_error(task, payload, { in_progress = true })
      if err then return json_codec.encode({ success = false, error = err }) end
      task.status = "cancelled"
      task.lifecycle_status = lifecycle_status(task.status)
      task.updated_at_ms = payload.now_ms or 0
      return json_codec.encode({ success = true, data = task })

    elseif command == "task.retry" then
      local id = payload.id
      local task = state.tasks[id]
      if not task then
        return json_codec.encode({ success = false, error = "task not found" })
      end
      local err = transition_error(task, payload, { failed = true, cancelled = true })
      if err then return json_codec.encode({ success = false, error = err }) end
      if task.generation >= MAX_TASK_GENERATION then return json_codec.encode({ success = false, error = "task generation exhausted" }) end
      local all_succeeded = true
      for _, dep_id in ipairs(task.dependencies) do
        local dep = state.tasks[dep_id]
        if not dep or (dep.status or ""):lower() ~= "succeeded" then
          all_succeeded = false
          break
        end
      end
      task.status = all_succeeded and "ready" or "pending"
      task.lifecycle_status = lifecycle_status(task.status)
      task.generation = task.generation + 1
      task.assigned_agent, task.worker_id = nil, nil
      task.failure_reason = nil
      task.error = nil
      task.updated_at_ms = payload.now_ms or 0
      return json_codec.encode({ success = true, data = task })

    elseif command == "task.topological_sort" then
      -- Kahn's algorithm
      local in_degree = {}
      local adj = {}
      local task_count = 0
      if not valid_dependency_graph(state.tasks) then
        return json_codec.encode({ success = false, error = "task dependency graph is invalid" })
      end
      for id, t in pairs(state.tasks) do
        task_count = task_count + 1
        in_degree[id] = #t.dependencies
        adj[id] = {}
      end
      for id, t in pairs(state.tasks) do
        for _, dep in ipairs(t.dependencies) do
          table.insert(adj[dep], id)
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
      if #order ~= task_count then
        return json_codec.encode({ success = false, error = "task dependency cycle detected" })
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
      local rat = Rationale and Rationale.for_persistence(payload.rationale)
        or { why = "Provider rationale unavailable", what = "Continue task execution" }
      local h = mock_hash(json_codec.encode(rat) .. state.tree_hash)
      local cp = {
        hash = h,
        tree_hash = state.tree_hash,
        parents = state.head_checkpoint and { state.head_checkpoint } or {},
        rationale = rat,
        task_id = rat.task_id,
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
      local action
      if WheelAction then
        action = WheelAction.normalize(payload, function(hash, content)
          if type(hash) ~= "string" or #hash ~= 64 or content == "" then return end
          local slot_name = "blobs/" .. hash
          if not state.slots[slot_name] then
            local h = hash
            state.slots[slot_name] = {
              name = slot_name, hash = h, content = content, size_bytes = #content,
            }
            state.tree_hash = mock_hash(state.tree_hash .. slot_name .. h)
          end
        end)
      else
        local preview = payload.preview or payload.stdout_preview or payload.stderr_preview or ""
        local raw_stdout = type(payload.raw_stdout) == "string" and payload.raw_stdout or ""
        local raw_stderr = type(payload.raw_stderr) == "string" and payload.raw_stderr or ""
        action = {
          action_id = payload.action_id,
          success = payload.success ~= false,
          exit_code = payload.exit_code or 0,
          duration_ms = payload.duration_ms or 0,
          preview = preview:sub(1, 256),
          stdout_preview = (payload.stdout_preview or ""):sub(1, 256),
          stderr_preview = (payload.stderr_preview or ""):sub(1, 256),
          size_bytes = payload.size_bytes
            or (tonumber(payload.stdout_bytes) or #raw_stdout)
              + (tonumber(payload.stderr_bytes) or #raw_stderr),
          stdout_bytes = tonumber(payload.stdout_bytes) or #raw_stdout,
          stderr_bytes = tonumber(payload.stderr_bytes) or #raw_stderr,
        }
      end
      table.insert(state.recent_actions, action)
      if #state.recent_actions > state.spillover_config.max_recent_actions then
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
        table.insert(act_lines, string.format("Action %s [exit=%s]: %s", a.action_id, tostring(a.exit_code), a.preview or a.stdout_preview or ""))
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
  local transaction_active = false
  local function transaction(operation)
    if transaction_active then return false, { error = "kernel_transaction_busy" } end
    -- These projections belong to this in-process dispatcher. Keep the old
    -- state outside the command surface so a failed compensating write cannot
    -- strand an owner or advance its generation. No cross-process claim.
    local function clone(value)
      if type(value) ~= "table" then return value end
      local result = {}
      for key, item in pairs(value) do result[key] = clone(item) end
      return result
    end
    local original = clone(state)
    transaction_active = true
    local called, success, result = pcall(operation)
    transaction_active = false
    if not called or success ~= true then state = original end
    if not called then return false, { error = "kernel_transaction_failed" } end
    return success == true, result
  end
  return dispatch, transaction
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
  if dispatcher then
    self.dispatcher = dispatcher
  else
    self.dispatcher, self._handoff_transaction = create_mock_dispatcher()
  end
  return self
end

--- Create an in-memory mock WheelKernel instance for headless testing and previews.
--- @return table
function WheelKernel.new_mock()
  return WheelKernel.new()
end

--- Atomic rollback is available only for the owned in-process dispatcher.
--- An injected bridge must supply its own transaction contract before use.
function WheelKernel:_with_handoff_transaction(operation)
  if not self._handoff_transaction then
    return false, { error = "kernel_handoff_transaction_unavailable" }
  end
  return self._handoff_transaction(operation)
end

--- Internal helper executing a command over the dispatcher and decoding JSON response.
--- @param command string
--- @param payload table?
--- @return any
function WheelKernel:call(command, payload)
  payload = payload or {}
  local expected_start_generation
  if command == "task.start" then
    local tasks = self:_validated_task_graph()
    local task = tasks[payload.id]
    if not task then error("task not found") end
    local start_error = task_start_error(task, payload, tasks)
    if start_error then error(start_error) end
    expected_start_generation = task.generation
    payload.expected_generation = expected_start_generation
  end
  if not self._handoff_transaction and TASK_TRANSITIONS[command] then
    local task = self:get_task(payload.id)
    if not task then error("task not found") end
    local err = task_transition_error(task, payload, TASK_TRANSITIONS[command],
      command == "task.reassign" and "source_agent" or "assigned_agent")
    if err then error(err) end
    if (command == "task.retry" or command == "task.reassign") and task.generation >= MAX_TASK_GENERATION then
      error("task generation exhausted")
    end
  end
  local payload_str = json_codec.encode(payload)
  local resp_str = self.dispatcher(command, payload_str)
  local resp = json_codec.decode(resp_str)
  if not resp or not resp.success then
    error((resp and resp.error) or "unknown wheel bridge error")
  end
  local function project(task)
    if type(task) == "table" and task.status ~= nil then
      local normalized = WheelKernel.normalize_lifecycle_status(task.status)
      if normalized == "unknown" or (task.lifecycle_status ~= nil and task.lifecycle_status ~= normalized) then
        error("task lifecycle state is invalid")
      end
      task.lifecycle_status = normalized
      local owner = task.assigned_agent
      if type(owner) ~= "string" or owner == "" then owner = task.worker_id end
      if type(task.assigned_agent) == "string" and task.assigned_agent ~= ""
        and type(task.worker_id) == "string" and task.worker_id ~= "" and task.worker_id ~= task.assigned_agent then
        error("task owner fields are inconsistent")
      end
      if type(owner) == "string" and owner ~= "" then task.assigned_agent, task.worker_id = owner, owner end
    end
  end
  if command == "task.list" then
    for _, task in ipairs(resp.data or {}) do project(task) end
  elseif command:match("^task%.") then project(resp.data) end
  if command == "task.start" then
    local started = resp.data
    local worker = payload.assigned_agent or payload.worker_id
    if type(started) ~= "table"
      or WheelKernel.normalize_lifecycle_status(started.status) ~= "in_progress"
      or started.lifecycle_status ~= "in_progress"
      or started.generation ~= expected_start_generation + 1
      or started.assigned_agent ~= worker or started.worker_id ~= worker then
      error("task start response failed lifecycle fence")
    end
    local actual = self:get_task(payload.id)
    if type(actual) ~= "table"
      or WheelKernel.normalize_lifecycle_status(actual.status) ~= "in_progress"
      or actual.lifecycle_status ~= "in_progress"
      or actual.generation ~= expected_start_generation + 1
      or actual.assigned_agent ~= worker or actual.worker_id ~= worker then
      error("task start state failed lifecycle fence")
    end
    resp.data = actual
  end
  return resp.data
end

--- Query kernel status and telemetry.
--- @return table
function WheelKernel:status()
  return self:call("kernel.status", {})
end

--- Create a new task in the control plane DAG.
--- @param draft table { id: string, title: string, description: string, priority: number?, dependencies: string[]?, parent_task_id: string?, now_ms: number? }
--- @return table
function WheelKernel:create_task(draft)
  if not self._handoff_transaction then
    local tasks = self:_validated_task_graph()
    if type(draft) ~= "table" or type(draft.id) ~= "string" or draft.id == "" or #draft.id > 128
      or not draft.id:match("^[A-Za-z0-9][A-Za-z0-9._:/%-]*$") or tasks[draft.id]
      or not valid_dependency_list(tasks, draft.id, draft.dependencies == nil and {} or draft.dependencies) then
      error("invalid task or dependency list")
    end
    if draft.parent_task_id ~= nil and (type(draft.parent_task_id) ~= "string"
      or not tasks[draft.parent_task_id] or draft.parent_task_id == draft.id) then error("invalid parent task hierarchy") end
  end
  return self:call("task.create", draft)
end

function WheelKernel:_validated_task_graph()
  local tasks = {}
  for _, task in ipairs(self:list_tasks()) do
    if type(task.id) ~= "string" or tasks[task.id] then error("invalid task graph identity") end
    tasks[task.id] = task
  end
  if not valid_dependency_graph(tasks) then error("task dependency graph or parent hierarchy is invalid") end
  return tasks
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
function WheelKernel:start_task(id, worker_id, now_ms, expected_generation)
  local worker = worker_id or "worker"
  if type(worker) == "table" then
    worker = worker.worker_id or worker.assigned_agent or "worker"
  end
  return self:call("task.start", {
    id = id,
    worker_id = worker,
    assigned_agent = worker,
    now_ms = now_ms or 0,
    expected_generation = expected_generation,
  })
end

--- Reassign a running task while fencing stale owners by advancing generation.
--- @param id string
--- @param expected_generation number
--- @param assigned_agent string
--- @param now_ms number?
--- @param source_agent string Current owner of the expected generation
--- @return table
function WheelKernel:reassign_task(id, expected_generation, assigned_agent, now_ms, source_agent)
  return self:call("task.reassign", {
    id = id,
    expected_generation = expected_generation,
    source_agent = source_agent,
    assigned_agent = assigned_agent,
    now_ms = now_ms or 0,
  })
end

--- Complete a task successfully, promoting dependent tasks to Ready.
--- @param id string
--- @param expected_generation number
--- @param checkpoint string? Optional ContentHash string
--- @param now_ms number?
--- @param assigned_agent string Current owner of the expected generation
--- @return table
function WheelKernel:complete_task(id, expected_generation, checkpoint, now_ms, assigned_agent)
  return self:call("task.complete", {
    id = id,
    expected_generation = expected_generation,
    assigned_agent = assigned_agent,
    checkpoint = checkpoint,
    now_ms = now_ms or 0,
  })
end

--- Mark a task failed, propagating Blocked across downstream dependents.
--- @param id string
--- @param expected_generation number
--- @param error_message string
--- @param now_ms number?
--- @param assigned_agent string Current owner of the expected generation
--- @return table
function WheelKernel:fail_task(id, expected_generation, error_message, now_ms, assigned_agent)
  return self:call("task.fail", {
    id = id,
    expected_generation = expected_generation,
    assigned_agent = assigned_agent,
    error = error_message,
    failure_reason = error_message,
    now_ms = now_ms or 0,
  })
end

--- Cancel a running task with owner and generation fencing.
--- @param id string
--- @param expected_generation number
--- @param assigned_agent string
--- @param now_ms number?
--- @return table
function WheelKernel:cancel_task(id, expected_generation, assigned_agent, now_ms)
  return self:call("task.cancel", {
    id = id,
    expected_generation = expected_generation,
    assigned_agent = assigned_agent,
    now_ms = now_ms or 0,
  })
end

--- Retry a failed or cancelled task.
--- @param id string
--- @param expected_generation number
--- @param assigned_agent string
--- @param now_ms number?
--- @return table
function WheelKernel:retry_task(id, expected_generation, assigned_agent, now_ms)
  return self:call("task.retry", {
    id = id,
    expected_generation = expected_generation,
    assigned_agent = assigned_agent,
    now_ms = now_ms or 0,
  })
end

--- Compute topological ordering of tasks.
--- @return string[]
function WheelKernel:topological_sort()
  if not self._handoff_transaction then self:_validated_task_graph() end
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
  local persisted_rationale = Rationale and Rationale.for_persistence(rationale)
    or { why = "Provider rationale unavailable", what = "Continue task execution" }
  return self:call("checkpoint.commit", {
    rationale = persisted_rationale,
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
