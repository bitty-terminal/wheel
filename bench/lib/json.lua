-- bench/lib/json.lua
-- Minimal deterministic JSON encoder for benchmark records (Lua 5.1).
--
-- Arrays are explicit: build them with `json.array`. Empty plain tables
-- encode as `{}` so an empty series list cannot silently become `[]`.
-- Object keys are sorted, which keeps two records from the same run
-- byte-comparable and avoids depending on Lua hash order.

local M = {}

local ESCAPES = {
  ['"'] = '\\"',
  ["\\"] = "\\\\",
  ["\b"] = "\\b",
  ["\f"] = "\\f",
  ["\n"] = "\\n",
  ["\r"] = "\\r",
  ["\t"] = "\\t",
}

local function escape_string(value)
  local escaped = value:gsub('[%z\1-\31\\"]', function(char)
    local known = ESCAPES[char]
    if known then
      return known
    end
    return string.format("\\u%04x", string.byte(char))
  end)
  return '"' .. escaped .. '"'
end

local function format_number(value)
  if value ~= value or value == math.huge or value == -math.huge then
    return "null"
  end
  if value % 1 == 0 and math.abs(value) < 1e15 then
    return string.format("%d", value)
  end
  local text = string.format("%.6f", value):gsub("0+$", ""):gsub("%.$", "")
  if text == "-0" then
    return "0"
  end
  return text
end

--- Mark a table as a JSON array, including the empty case.
-- @param values table?
-- @return table
function M.array(values)
  local array = values or {}
  array.__array = true
  return array
end

local function encode_value(value)
  local kind = type(value)
  if kind == "nil" then
    return "null"
  elseif kind == "boolean" then
    return value and "true" or "false"
  elseif kind == "number" then
    return format_number(value)
  elseif kind == "string" then
    return escape_string(value)
  elseif kind == "table" then
    if value.__array then
      local parts = {}
      for index = 1, #value do
        parts[index] = encode_value(value[index])
      end
      return "[" .. table.concat(parts, ",") .. "]"
    end

    local keys = {}
    for key in pairs(value) do
      if key ~= "__array" then
        keys[#keys + 1] = key
      end
    end
    table.sort(keys, function(left, right)
      return tostring(left) < tostring(right)
    end)

    local parts = {}
    for _, key in ipairs(keys) do
      parts[#parts + 1] = escape_string(tostring(key)) .. ":" .. encode_value(value[key])
    end
    return "{" .. table.concat(parts, ",") .. "}"
  end
  return "null"
end

--- Encode a value as JSON.
-- @param value any
-- @return string
function M.encode(value)
  return encode_value(value)
end

return M
