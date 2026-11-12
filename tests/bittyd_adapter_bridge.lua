-- tests/bittyd_adapter_bridge.lua
-- Persistent JSON-lines stdio harness bridge driving the real Lua
-- `WheelBittydAdapter` (`lua/wheel/bittyd_adapter.lua`) for the Core shared
-- `bittyd` conformance corpus (`tests/bittyd_conformance_runner.py`).

package.path = "./lua/?.lua;./lua/?/init.lua;./bench/lib/?.lua;" .. package.path

local AdapterMod = require("wheel.bittyd_adapter")
local BenchJSON = require("json")

-- Minimal strict JSON decoder that marks JSON arrays with `__array = true` and
-- represents JSON `null` as a function sentinel (`type == "function"`), which
-- Lua tables can store without losing keys and `BenchJSON.encode` serializes
-- back to `"null"`.
local NULL_SENTINEL = function() end

local function decode_json(text)
  local pos = 1
  local len = #text

  local function skip_ws()
    local _, next_pos = text:find("^[ \t\r\n]+", pos)
    if next_pos then
      pos = next_pos + 1
    end
  end

  local parse_value

  local function parse_string()
    pos = pos + 1 -- skip opening quote
    local out = {}
    while pos <= len do
      local ch = text:sub(pos, pos)
      if ch == '"' then
        pos = pos + 1
        return table.concat(out)
      elseif ch == "\\" then
        pos = pos + 1
        local esc = text:sub(pos, pos)
        if esc == '"' or esc == "\\" or esc == "/" then
          out[#out + 1] = esc
          pos = pos + 1
        elseif esc == "b" then
          out[#out + 1] = "\b"
          pos = pos + 1
        elseif esc == "f" then
          out[#out + 1] = "\f"
          pos = pos + 1
        elseif esc == "n" then
          out[#out + 1] = "\n"
          pos = pos + 1
        elseif esc == "r" then
          out[#out + 1] = "\r"
          pos = pos + 1
        elseif esc == "t" then
          out[#out + 1] = "\t"
          pos = pos + 1
        elseif esc == "u" then
          local hex = text:sub(pos + 1, pos + 4)
          local code = tonumber(hex, 16) or 0
          if code < 0x80 then
            out[#out + 1] = string.char(code)
          elseif code < 0x800 then
            out[#out + 1] = string.char(
              0xC0 + math.floor(code / 64),
              0x80 + (code % 64)
            )
          else
            out[#out + 1] = string.char(
              0xE0 + math.floor(code / 4096),
              0x80 + (math.floor(code / 64) % 64),
              0x80 + (code % 64)
            )
          end
          pos = pos + 5
        else
          error("invalid JSON escape at " .. tostring(pos), 0)
        end
      else
        local start = pos
        local _, plain_end = text:find('^[^"\\]+', pos)
        if plain_end then
          out[#out + 1] = text:sub(start, plain_end)
          pos = plain_end + 1
        else
          out[#out + 1] = ch
          pos = pos + 1
        end
      end
    end
    error("unterminated JSON string", 0)
  end

  local function parse_array()
    pos = pos + 1 -- skip '['
    local arr = BenchJSON.array({})
    skip_ws()
    if text:sub(pos, pos) == "]" then
      pos = pos + 1
      return arr
    end
    local idx = 1
    while true do
      skip_ws()
      arr[idx] = parse_value()
      idx = idx + 1
      skip_ws()
      local sep = text:sub(pos, pos)
      if sep == "]" then
        pos = pos + 1
        return arr
      elseif sep == "," then
        pos = pos + 1
      else
        error("expected ',' or ']' at " .. tostring(pos), 0)
      end
    end
  end

  local function parse_object()
    pos = pos + 1 -- skip '{'
    local obj = {}
    skip_ws()
    if text:sub(pos, pos) == "}" then
      pos = pos + 1
      return obj
    end
    while true do
      skip_ws()
      if text:sub(pos, pos) ~= '"' then
        error("expected string key at " .. tostring(pos), 0)
      end
      local key = parse_string()
      skip_ws()
      if text:sub(pos, pos) ~= ":" then
        error("expected ':' at " .. tostring(pos), 0)
      end
      pos = pos + 1
      skip_ws()
      local val = parse_value()
      if val ~= NULL_SENTINEL then
        obj[key] = val
      else
        obj[key] = NULL_SENTINEL
      end
      skip_ws()
      local sep = text:sub(pos, pos)
      if sep == "}" then
        pos = pos + 1
        return obj
      elseif sep == "," then
        pos = pos + 1
      else
        error("expected ',' or '}' at " .. tostring(pos), 0)
      end
    end
  end

  parse_value = function()
    skip_ws()
    local ch = text:sub(pos, pos)
    if ch == '"' then
      return parse_string()
    elseif ch == "[" then
      return parse_array()
    elseif ch == "{" then
      return parse_object()
    elseif text:sub(pos, pos + 3) == "true" then
      pos = pos + 4
      return true
    elseif text:sub(pos, pos + 4) == "false" then
      pos = pos + 5
      return false
    elseif text:sub(pos, pos + 3) == "null" then
      pos = pos + 4
      return NULL_SENTINEL
    else
      local _, num_end, num_str = text:find("^(-?%d+%.?%d*[eE]?[+-]?%d*)", pos)
      if num_end then
        pos = num_end + 1
        return tonumber(num_str)
      end
      error("unexpected token at " .. tostring(pos), 0)
    end
  end

  local result = parse_value()
  return result
end

local function strip_sentinels(val)
  if val == NULL_SENTINEL then
    return nil
  end
  if type(val) ~= "table" then
    return val
  end
  local out = {}
  if val.__array then
    out.__array = true
    for i = 1, #val do
      out[i] = strip_sentinels(val[i])
    end
    return out
  end
  for k, v in pairs(val) do
    if v ~= NULL_SENTINEL then
      out[k] = strip_sentinels(v)
    end
  end
  return out
end

local function mark_arrays_for_encode(val)
  if type(val) ~= "table" then
    return val
  end
  if val.__array then
    local out = BenchJSON.array({})
    for i = 1, #val do
      out[i] = mark_arrays_for_encode(val[i])
    end
    return out
  end
  local count = 0
  local max_idx = 0
  local all_int = true
  for k, _ in pairs(val) do
    count = count + 1
    if type(k) == "number" and k >= 1 and math.floor(k) == k then
      if k > max_idx then
        max_idx = k
      end
    else
      all_int = false
    end
  end
  if count > 0 and all_int and max_idx == count then
    local out = BenchJSON.array({})
    for i = 1, count do
      out[i] = mark_arrays_for_encode(val[i])
    end
    return out
  end
  local out = {}
  for k, v in pairs(val) do
    out[k] = mark_arrays_for_encode(v)
  end
  return out
end

local function write_json(payload)
  io.stdout:write(BenchJSON.encode(mark_arrays_for_encode(payload)) .. "\n")
  io.stdout:flush()
end

local state = {
  server_available = true,
  refuse_connections = {},
  adapters = {},
  adapter_order = {},
}

local function get_adapter(conn_name)
  local existing = state.adapters[conn_name]
  if existing then
    return existing
  end
  local refuse_this = state.refuse_connections[conn_name] == true
  local transport_fn = nil
  if state.server_available then
    transport_fn = function(connection_name, envelope, opts)
      write_json({
        op = "transport",
        connection = connection_name,
        method = envelope.method,
        params = envelope.params,
        fault = opts and opts.fault or nil,
      })
      local reply_line = io.stdin:read("*l")
      if not reply_line then
        return { transport = "closed" }
      end
      return decode_json(reply_line)
    end
  end

  local adapter = AdapterMod.new_adapter({
    mode = AdapterMod.TRANSPORT_BITTYD,
    transport = transport_fn,
    connection_name = conn_name,
    allow_operator_stop = conn_name == "operator",
    policy_gate = refuse_this and function()
      return false, "PolicyDenied", "refused by Wheel adapter policy before connection", true
    end or nil,
  })
  state.adapters[conn_name] = adapter
  state.adapter_order[#state.adapter_order + 1] = conn_name
  return adapter
end

while true do
  local line = io.stdin:read("*l")
  if not line then
    break
  end
  local msg = strip_sentinels(decode_json(line))
  local cmd = msg and msg.cmd or nil

  if cmd == "reset" then
    state.server_available = msg.server_available ~= false
    state.refuse_connections = {}
    if type(msg.refuse_connections) == "table" then
      for i = 1, #msg.refuse_connections do
        state.refuse_connections[msg.refuse_connections[i]] = true
      end
    end
    state.adapters = {}
    state.adapter_order = {}
    write_json({ op = "reset_ok" })
  elseif cmd == "call" then
    local conn_name = msg.connection or "client"
    local adapter = get_adapter(conn_name)
    local opts = nil
    if msg.fault and msg.fault ~= NULL_SENTINEL then
      opts = { fault = msg.fault }
    end
    local params = msg.params
    if params == NULL_SENTINEL then
      params = nil
    end
    local reply = adapter:call(msg.method, params, opts)
    write_json({
      op = "result",
      reply = reply,
      closed = adapter.closed == true,
      instance_id = adapter.instance_id,
      client_id = adapter.client_id,
    })
  elseif cmd == "adapter_state" then
    local audit_chunks = {}
    local child_total = 0
    local by_conn = {}
    for _, name in ipairs(state.adapter_order) do
      local ad = state.adapters[name]
      local text = ad:audit_text()
      if text ~= "" then
        audit_chunks[#audit_chunks + 1] = text
      end
      child_total = child_total + ad:child_process_count()
      by_conn[name] = {
        negotiated = ad.negotiated,
        closed = ad.closed,
        instance_id = ad.instance_id,
        client_id = ad.client_id,
      }
    end
    write_json({
      op = "state",
      audit_text = table.concat(audit_chunks, "\n"),
      child_processes = child_total,
      connections = by_conn,
    })
  elseif cmd == "quit" then
    write_json({ op = "bye" })
    break
  else
    write_json({ op = "error", message = "unknown command: " .. tostring(cmd) })
  end
end
