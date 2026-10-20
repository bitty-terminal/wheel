-- lua/wheel/schema.lua
-- Wheel: bounded command schema validation.
--
-- The accepted command surface (Plugin API v1 Lua Surface RFC, ADR 0009,
-- LUA-OQ-3) carries bounded JSON Schema for command arguments and results.
-- The host validates those shapes; this module keeps Wheel's own declarations
-- honest at registration and validates invocation arguments before a handler
-- runs.
--
-- The vocabulary is deliberately finite and closed. One schema node supports
-- exactly these keywords:
--
--   type, properties, required, additionalProperties, items, enum,
--   minimum, maximum, minLength, maxLength, minItems, maxItems
--
-- and exactly these types: string, integer, number, boolean, array, object.
-- Every object schema must set `additionalProperties = false`, every string
-- schema must set `maxLength`, every array schema must set `maxItems` and
-- `items`, and every integer/number schema must set finite `minimum` and
-- `maximum` bounds. Any other keyword, type, or form is rejected instead of
-- being silently ignored, so this module is never more permissive than the
-- accepted contract.

local WheelSchema = {}

local LIMITS = {
  -- Schema admission bounds. The byte, depth, and node ceilings mirror the
  -- accepted CMD_SCHEMA_MAX_BYTES / depth-16 contract with a small node cap so
  -- a hostile schema cannot make registration unbounded work.
  SCHEMA_MAX_DEPTH = 16,
  SCHEMA_MAX_NODES = 512,
  SCHEMA_MAX_BYTES = 16 * 1024,
  SCHEMA_MAX_PROPERTIES = 32,
  SCHEMA_MAX_REQUIRED = 16,
  SCHEMA_MAX_ENUM_VALUES = 16,
  SCHEMA_MAX_PROPERTY_NAME_LENGTH = 64,
  SCHEMA_MAX_STRING_LENGTH = 16 * 1024,
  SCHEMA_MAX_ARRAY_ITEMS = 256,
  SCHEMA_MAX_ABSOLUTE_NUMBER = 1000000000,
  -- Value admission bounds. Arguments and results are untrusted data, so the
  -- validator bounds depth, node count, and bytes before it walks them.
  VALUE_MAX_DEPTH = 16,
  VALUE_MAX_NODES = 256,
  VALUE_MAX_BYTES = 16 * 1024,
}

WheelSchema.LIMITS = LIMITS

local TYPES = {
  string = true,
  integer = true,
  number = true,
  boolean = true,
  array = true,
  object = true,
}

WheelSchema.TYPES = TYPES

-- Keywords admitted per declared type. A keyword outside its type row is
-- rejected even when another type would accept it (for example `minLength`
-- on an integer schema).
local TYPE_KEYWORDS = {
  string = { type = true, enum = true, minLength = true, maxLength = true },
  integer = { type = true, enum = true, minimum = true, maximum = true },
  number = { type = true, enum = true, minimum = true, maximum = true },
  boolean = { type = true, enum = true },
  array = { type = true, items = true, minItems = true, maxItems = true },
  object = { type = true, properties = true, required = true, additionalProperties = true },
}

local PROPERTY_NAME_PATTERN = "^[a-z][a-z0-9_]*$"

local function is_finite_number(value)
  return type(value) == "number"
    and value == value
    and value ~= math.huge
    and value ~= -math.huge
end

local function is_non_negative_integer(value)
  return is_finite_number(value) and value >= 0 and value % 1 == 0
end

local function is_integer(value)
  return is_finite_number(value) and value % 1 == 0
end

local function array_length(value)
  local count = 0
  for key in pairs(value) do
    if not is_non_negative_integer(key) or key < 1 then
      return nil, "expected a contiguous array"
    end
    if key > count then
      count = key
    end
  end
  for index = 1, count do
    if value[index] == nil then
      return nil, "expected a contiguous array"
    end
  end
  return count, nil
end

-- Bounded structural scan. It rejects cycles, excessive depth, excessive
-- nodes, and excessive bytes before the vocabulary walk. Keys may be strings
-- (schema keywords) or numbers (array members such as required/enum); other
-- key types are rejected because no admitted schema form uses them.
local function measure(node, depth, seen, state, path)
  if type(node) ~= "table" then
    return nil, path .. ": expected a table"
  end
  if depth > LIMITS.SCHEMA_MAX_DEPTH then
    return nil, path .. ": schema depth exceeds " .. LIMITS.SCHEMA_MAX_DEPTH
  end
  if seen[node] then
    return nil, path .. ": schema contains a cyclic reference"
  end

  seen[node] = true
  state.nodes = state.nodes + 1
  if state.nodes > LIMITS.SCHEMA_MAX_NODES then
    return nil, path .. ": schema node count exceeds " .. LIMITS.SCHEMA_MAX_NODES
  end

  for key, value in pairs(node) do
    local key_kind = type(key)
    if key_kind == "string" then
      state.bytes = state.bytes + #key + 1
    elseif key_kind == "number" then
      state.bytes = state.bytes + 8
    else
      return nil, path .. ": schema tables use string or numeric keys"
    end

    local value_kind = type(value)
    if value_kind == "string" then
      state.bytes = state.bytes + #value
    elseif value_kind == "table" then
      local ok, reason = measure(value, depth + 1, seen, state, path .. "." .. tostring(key))
      if not ok then
        return nil, reason
      end
    elseif value_kind == "number" then
      state.bytes = state.bytes + 8
    elseif value_kind == "boolean" then
      state.bytes = state.bytes + 5
    else
      return nil, path .. "." .. tostring(key) .. ": unsupported schema value type " .. value_kind
    end

    if state.bytes > LIMITS.SCHEMA_MAX_BYTES then
      return nil, path .. ": schema exceeds " .. LIMITS.SCHEMA_MAX_BYTES .. " bytes"
    end
  end

  seen[node] = nil
  return true
end

local validate_node

local function validate_properties(schema, path, depth)
  local properties = schema.properties
  if properties == nil then
    return {}, nil
  end
  if type(properties) ~= "table" then
    return nil, path .. ".properties: expected a table"
  end

  local count = 0
  for name, child in pairs(properties) do
    count = count + 1
    if type(name) ~= "string" then
      return nil, path .. ".properties: property names must be strings"
    end
    if #name == 0 or #name > LIMITS.SCHEMA_MAX_PROPERTY_NAME_LENGTH then
      return nil, path .. ".properties: property name length must be 1.."
        .. LIMITS.SCHEMA_MAX_PROPERTY_NAME_LENGTH
    end
    if not name:match(PROPERTY_NAME_PATTERN) then
      return nil, path .. ".properties." .. name .. ": property names use lower_snake_case"
    end
    local ok, reason = validate_node(child, path .. ".properties." .. name, depth + 1)
    if not ok then
      return nil, reason
    end
  end
  if count == 0 then
    return nil, path .. ".properties: omit properties for a closed empty object; "
      .. "an empty Lua table encodes as a JSON array"
  end
  if count > LIMITS.SCHEMA_MAX_PROPERTIES then
    return nil, path .. ".properties: exceeds " .. LIMITS.SCHEMA_MAX_PROPERTIES .. " declared properties"
  end
  return properties, nil
end

local function validate_required(schema, properties, path)
  local required = schema.required
  if required == nil then
    return true
  end
  if type(required) ~= "table" then
    return nil, path .. ".required: expected an array of strings"
  end
  local count, reason = array_length(required)
  if not count then
    return nil, path .. ".required: " .. reason
  end
  if count > LIMITS.SCHEMA_MAX_REQUIRED then
    return nil, path .. ".required: exceeds " .. LIMITS.SCHEMA_MAX_REQUIRED .. " entries"
  end

  local seen = {}
  for index = 1, count do
    local name = required[index]
    if type(name) ~= "string" or name == "" then
      return nil, path .. ".required[" .. index .. "]: expected a non-empty string"
    end
    if seen[name] then
      return nil, path .. ".required: duplicate field '" .. name .. "'"
    end
    seen[name] = true
    if properties[name] == nil then
      return nil, path .. ".required: field '" .. name .. "' is not declared in properties"
    end
  end
  return true
end

local function validate_enum(schema, path)
  local enum = schema.enum
  if enum == nil then
    return true
  end
  if type(enum) ~= "table" then
    return nil, path .. ".enum: expected an array"
  end
  local count, reason = array_length(enum)
  if not count then
    return nil, path .. ".enum: " .. reason
  end
  if count == 0 then
    return nil, path .. ".enum: must not be empty"
  end
  if count > LIMITS.SCHEMA_MAX_ENUM_VALUES then
    return nil, path .. ".enum: exceeds " .. LIMITS.SCHEMA_MAX_ENUM_VALUES .. " values"
  end

  local declared = schema.type
  local seen = {}
  for index = 1, count do
    local value = enum[index]
    local matches = (declared == "string" and type(value) == "string")
      or (declared == "boolean" and type(value) == "boolean")
      or ((declared == "integer" or declared == "number") and is_finite_number(value))
    if not matches then
      return nil, path .. ".enum[" .. index .. "]: value does not match type " .. declared
    end
    if declared == "integer" and not is_integer(value) then
      return nil, path .. ".enum[" .. index .. "]: value must be an integer"
    end
    if declared == "string" then
      local max_length = schema.maxLength
      local min_length = schema.minLength or 0
      if #value < min_length or #value > max_length then
        return nil, path .. ".enum[" .. index .. "]: value is outside the declared length bounds"
      end
    elseif declared == "integer" or declared == "number" then
      if value < schema.minimum or value > schema.maximum then
        return nil, path .. ".enum[" .. index .. "]: value is outside the declared numeric bounds"
      end
    end
    local key = type(value) .. ":" .. tostring(value)
    if seen[key] then
      return nil, path .. ".enum: duplicate value " .. tostring(value)
    end
    seen[key] = true
  end
  return true
end

local function validate_bounds(schema, path)
  local declared = schema.type

  if declared == "string" then
    local max_length = schema.maxLength
    if not is_non_negative_integer(max_length) then
      return nil, path .. ".maxLength: string schemas require a non-negative integer maxLength"
    end
    if max_length > LIMITS.SCHEMA_MAX_STRING_LENGTH then
      return nil, path .. ".maxLength: exceeds " .. LIMITS.SCHEMA_MAX_STRING_LENGTH
    end
    local min_length = schema.minLength
    if min_length ~= nil then
      if not is_non_negative_integer(min_length) then
        return nil, path .. ".minLength: expected a non-negative integer"
      end
      if min_length > max_length then
        return nil, path .. ".minLength: cannot exceed maxLength"
      end
    end
  elseif declared == "array" then
    local max_items = schema.maxItems
    if not is_non_negative_integer(max_items) then
      return nil, path .. ".maxItems: array schemas require a non-negative integer maxItems"
    end
    if max_items > LIMITS.SCHEMA_MAX_ARRAY_ITEMS then
      return nil, path .. ".maxItems: exceeds " .. LIMITS.SCHEMA_MAX_ARRAY_ITEMS
    end
    local min_items = schema.minItems
    if min_items ~= nil then
      if not is_non_negative_integer(min_items) then
        return nil, path .. ".minItems: expected a non-negative integer"
      end
      if min_items > max_items then
        return nil, path .. ".minItems: cannot exceed maxItems"
      end
    end
  elseif declared == "integer" or declared == "number" then
    local minimum = schema.minimum
    local maximum = schema.maximum
    if not is_finite_number(minimum) then
      return nil, path .. ".minimum: numeric schemas require a finite minimum"
    end
    if not is_finite_number(maximum) then
      return nil, path .. ".maximum: numeric schemas require a finite maximum"
    end
    if declared == "integer" and (not is_integer(minimum) or not is_integer(maximum)) then
      return nil, path .. ": integer bounds must be integers"
    end
    if minimum > maximum then
      return nil, path .. ".minimum: cannot exceed maximum"
    end
    if math.abs(minimum) > LIMITS.SCHEMA_MAX_ABSOLUTE_NUMBER
      or math.abs(maximum) > LIMITS.SCHEMA_MAX_ABSOLUTE_NUMBER then
      return nil, path .. ": numeric bounds exceed " .. LIMITS.SCHEMA_MAX_ABSOLUTE_NUMBER
    end
  end

  return true
end

validate_node = function(schema, path, depth)
  if type(schema) ~= "table" then
    return nil, path .. ": expected a table"
  end
  if depth > LIMITS.SCHEMA_MAX_DEPTH then
    return nil, path .. ": schema depth exceeds " .. LIMITS.SCHEMA_MAX_DEPTH
  end

  local declared = schema.type
  if type(declared) ~= "string" or not TYPES[declared] then
    return nil, path .. ": type must be one of string/integer/number/boolean/array/object"
  end

  local allowed = TYPE_KEYWORDS[declared]
  for key in pairs(schema) do
    if type(key) ~= "string" or not allowed[key] then
      return nil, path .. ": unexpected keyword '" .. tostring(key) .. "' for type " .. declared
    end
  end

  if declared == "object" then
    if schema.additionalProperties ~= false then
      return nil, path .. ": object schemas require additionalProperties = false"
    end
    local properties, reason = validate_properties(schema, path, depth)
    if not properties then
      return nil, reason
    end
    local required_ok, required_reason = validate_required(schema, properties, path)
    if not required_ok then
      return nil, required_reason
    end
  elseif declared == "array" then
    if schema.items == nil then
      return nil, path .. ": array schemas require items"
    end
    local ok, reason = validate_node(schema.items, path .. ".items", depth + 1)
    if not ok then
      return nil, reason
    end
  end

  local bounds_ok, bounds_reason = validate_bounds(schema, path)
  if not bounds_ok then
    return nil, bounds_reason
  end

  local enum_ok, enum_reason = validate_enum(schema, path)
  if not enum_ok then
    return nil, enum_reason
  end

  return true
end

--- Validate one bounded schema declaration.
-- @param schema any
-- @param path string? Error path prefix, defaults to "$".
-- @return boolean ok, string? reason
function WheelSchema.validate_schema(schema, path)
  path = type(path) == "string" and path or "$"
  local state = { nodes = 0, bytes = 0 }
  local ok, reason = measure(schema, 0, {}, state, path)
  if not ok then
    return false, reason
  end
  local node_ok, node_reason = validate_node(schema, path, 0)
  if not node_ok then
    return false, node_reason
  end
  return true
end

local function enum_contains(schema, value)
  local enum = schema.enum
  if enum == nil then
    return true
  end
  for index = 1, #enum do
    if enum[index] == value then
      return true
    end
  end
  return false
end

local check_value

local function check_object(schema, value, path, depth, state)
  if type(value) ~= "table" then
    return nil, path .. ": expected an object"
  end
  if getmetatable(value) ~= nil then
    return nil, path .. ": expected a plain table"
  end

  local properties = schema.properties or {}
  for key in pairs(value) do
    if type(key) ~= "string" then
      return nil, path .. ": object keys must be strings"
    end
    state.bytes = state.bytes + #key
    if state.bytes > LIMITS.VALUE_MAX_BYTES then
      return nil, path .. ": value exceeds " .. LIMITS.VALUE_MAX_BYTES .. " bytes"
    end
    if properties[key] == nil then
      return nil, path .. "." .. key .. ": unknown field"
    end
  end

  local required = schema.required or {}
  for index = 1, #required do
    local name = required[index]
    if rawget(value, name) == nil then
      return nil, path .. "." .. name .. ": required field is missing"
    end
  end

  for name, child in pairs(properties) do
    local child_value = rawget(value, name)
    if child_value ~= nil then
      local ok, reason = check_value(child, child_value, path .. "." .. name, depth + 1, state)
      if not ok then
        return nil, reason
      end
    end
  end

  return true
end

local function check_array(schema, value, path, depth, state)
  if type(value) ~= "table" then
    return nil, path .. ": expected an array"
  end
  if getmetatable(value) ~= nil then
    return nil, path .. ": expected a plain table"
  end

  local count, reason = array_length(value)
  if not count then
    return nil, path .. ": " .. reason
  end
  local max_items = schema.maxItems
  if count > max_items then
    return nil, path .. ": at most " .. max_items .. " items are allowed"
  end
  local min_items = schema.minItems or 0
  if count < min_items then
    return nil, path .. ": at least " .. min_items .. " items are required"
  end

  for index = 1, count do
    local ok, item_reason = check_value(schema.items, value[index], path .. "[" .. index .. "]", depth + 1, state)
    if not ok then
      return nil, item_reason
    end
  end

  return true
end

local function check_scalar(schema, value, path)
  local declared = schema.type

  if declared == "string" then
    if type(value) ~= "string" then
      return nil, path .. ": expected a string"
    end
    local max_length = schema.maxLength
    if #value > max_length then
      return nil, path .. ": length exceeds " .. max_length
    end
    local min_length = schema.minLength or 0
    if #value < min_length then
      return nil, path .. ": length is below " .. min_length
    end
  elseif declared == "integer" then
    if not is_integer(value) then
      return nil, path .. ": expected an integer"
    end
    if value < schema.minimum or value > schema.maximum then
      return nil, path .. ": outside the declared range"
    end
  elseif declared == "number" then
    if not is_finite_number(value) then
      return nil, path .. ": expected a finite number"
    end
    if value < schema.minimum or value > schema.maximum then
      return nil, path .. ": outside the declared range"
    end
  elseif declared == "boolean" then
    if type(value) ~= "boolean" then
      return nil, path .. ": expected a boolean"
    end
  else
    return nil, path .. ": unsupported schema type " .. tostring(declared)
  end

  if not enum_contains(schema, value) then
    return nil, path .. ": value is not in the declared enum"
  end
  return true
end

check_value = function(schema, value, path, depth, state)
  if depth > LIMITS.VALUE_MAX_DEPTH then
    return nil, path .. ": value depth exceeds " .. LIMITS.VALUE_MAX_DEPTH
  end
  state.nodes = state.nodes + 1
  if state.nodes > LIMITS.VALUE_MAX_NODES then
    return nil, path .. ": value node count exceeds " .. LIMITS.VALUE_MAX_NODES
  end
  if type(value) == "string" then
    state.bytes = state.bytes + #value
  elseif type(value) == "table" then
    state.bytes = state.bytes + 8
  else
    state.bytes = state.bytes + 8
  end
  if state.bytes > LIMITS.VALUE_MAX_BYTES then
    return nil, path .. ": value exceeds " .. LIMITS.VALUE_MAX_BYTES .. " bytes"
  end

  local declared = schema.type
  if declared == "object" then
    return check_object(schema, value, path, depth, state)
  elseif declared == "array" then
    return check_array(schema, value, path, depth, state)
  end
  return check_scalar(schema, value, path)
end

--- Validate one argument or result value against a declaration.
-- The schema is expected to have passed `validate_schema`; a malformed schema
-- is reported rather than guessed at.
-- @param schema table
-- @param value any
-- @param path string? Error path prefix, defaults to "$".
-- @return boolean ok, string? reason
function WheelSchema.validate_value(schema, value, path)
  path = type(path) == "string" and path or "$"
  local schema_ok, schema_reason = WheelSchema.validate_schema(schema, path)
  if not schema_ok then
    return false, schema_reason
  end
  local state = { nodes = 0, bytes = 0 }
  local value_ok, value_reason = check_value(schema, value, path, 0, state)
  if not value_ok then
    return false, value_reason
  end
  return true
end

--- Validate command arguments; a nil argument set is an empty object.
-- @param schema table
-- @param args table?
-- @return boolean ok, string? reason
function WheelSchema.validate_args(schema, args)
  if args == nil then
    args = {}
  end
  return WheelSchema.validate_value(schema, args, "$args")
end

return WheelSchema
