-- lua/wheel/errors.lua
-- Wheel: typed runtime errors for command dispatch.
--
-- Capability denials follow the accepted Plugin API v1 bridge contract: a
-- catchable Lua error table with exactly `class`, `code`, and `message`
-- (`bitty-plugins-docs/sdk/reference/overview.md`). `E_CAPABILITY_DENIED` is
-- the accepted stable code for an ungranted capability, and the message
-- mirrors the host wording while naming the missing capability.
--
-- `E_INTERNAL` has no accepted host code yet. It is deliberately Wheel-local
-- and marks an unexpected handler failure so a real defect is never reported
-- as a capability denial. Replace it when the host vocabulary defines a
-- generic internal or runtime failure code.

local WheelErrors = {}

WheelErrors.CLASS_RUNTIME = "runtime"
WheelErrors.E_CAPABILITY_DENIED = "E_CAPABILITY_DENIED"
WheelErrors.E_INTERNAL = "E_INTERNAL"
WheelErrors.MESSAGE_MAX_LENGTH = 160

local CLASSES = {
  runtime = true,
  validation = true,
  resolution = true,
  budget = true,
}

local CODE_PATTERN = "^E_[A-Z0-9_]+$"
local IDENTIFIER_PATTERN = "^[%w_.:%-]+$"
local IDENTIFIER_MAX_LENGTH = 64

local unpack_values = table.unpack or unpack

--- Bound a message to one short line.
-- @param text string?
-- @param limit number
-- @return string?
local function bounded(text, limit)
  if type(text) ~= "string" then
    return nil
  end
  text = text:gsub("[\r\n]", " ")
  if #text > limit then
    text = text:sub(1, limit - 3) .. "..."
  end
  return text
end

--- Accept only static, bounded capability and command identifiers.
-- @param value any
-- @return boolean
local function valid_identifier(value)
  return type(value) == "string"
    and value ~= ""
    and #value <= IDENTIFIER_MAX_LENGTH
    and value:match(IDENTIFIER_PATTERN) ~= nil
end

--- Build a typed bridge-shaped error table.
-- @param class string
-- @param code string
-- @param message string
-- @return table
local function typed(class, code, message)
  local err = {
    class = class,
    code = code,
    message = bounded(message, WheelErrors.MESSAGE_MAX_LENGTH),
  }
  return setmetatable(err, {
    __tostring = function(self)
      return string.format("%s: %s (%s)", self.class, self.message, self.code)
    end,
  })
end

--- Build a typed capability denial naming the missing capability.
-- @param capability string Static capability identifier (`env.read`, ...).
-- @return table
function WheelErrors.capability_denied(capability)
  local name = valid_identifier(capability) and capability or "host"
  return typed(
    WheelErrors.CLASS_RUNTIME,
    WheelErrors.E_CAPABILITY_DENIED,
    string.format("capability '%s' is not granted", name)
  )
end

--- Build a generic internal failure for a command.
-- @param command_id string
-- @return table
function WheelErrors.internal(command_id)
  local id = valid_identifier(command_id) and command_id or "unknown"
  return typed(
    WheelErrors.CLASS_RUNTIME,
    WheelErrors.E_INTERNAL,
    string.format("internal error in wheel command '%s'", id)
  )
end

-- Missing sandbox surfaces mapped to the capability a host would have to
-- grant. Globals and member names are interpreter vocabulary, never echoed.
local NIL_CAPABILITIES = {
  io = "fs.read",
  loadfile = "fs.read",
  dofile = "fs.read",
  getenv = "env.read",
  execute = "process.spawn",
  tmpname = "tmp.create",
  remove = "fs.write",
  popen = "process.spawn",
  open = "fs.read",
}

--- Map a raw nil-global or nil-member failure to a capability identifier.
-- Supports the legacy Lua 5.1/LuaJIT wording and the Lua 5.2+ wording.
-- @param message string
-- @return string?
local function missing_capability(message)
  local global = message:match("attempt to index global '([%w_]+)' %(a nil value%)")
    or message:match("attempt to call global '([%w_]+)' %(a nil value%)")
    or message:match("attempt to index a nil value %(global '([%w_]+)'%)")
    or message:match("attempt to call a nil value %(global '([%w_]+)'%)")
  if global and NIL_CAPABILITIES[global] then
    return NIL_CAPABILITIES[global]
  end

  local field = message:match("attempt to call field '([%w_]+)' %(a nil value%)")
    or message:match("attempt to index field '([%w_]+)' %(a nil value%)")
    or message:match("attempt to call a nil value %(field '([%w_]+)'%)")
    or message:match("attempt to index a nil value %(field '([%w_]+)'%)")
  if field and NIL_CAPABILITIES[field] then
    return NIL_CAPABILITIES[field]
  end

  return nil
end

--- Return true when `err` already matches the accepted bridge error shape.
-- @param err any
-- @return boolean
function WheelErrors.is_typed(err)
  if type(err) ~= "table" then
    return false
  end
  if type(err.class) ~= "string" or not CLASSES[err.class] then
    return false
  end
  if type(err.code) ~= "string" or not err.code:match(CODE_PATTERN) then
    return false
  end
  if type(err.message) ~= "string" or err.message == "" then
    return false
  end
  if #err.message > WheelErrors.MESSAGE_MAX_LENGTH then
    return false
  end
  if err.message:find("\n", 1, true) or err.message:find("\r", 1, true) then
    return false
  end
  return true
end

--- Normalize a handler failure into a typed error table.
-- Typed errors pass through unchanged. A raw nil-global or nil-member failure
-- from the sandbox becomes a capability denial for the missing surface.
-- Opaque structured values (including the dispatch budget sentinel) pass
-- through so their meaning is preserved. Everything else becomes E_INTERNAL.
-- @param err any
-- @param command_id string
-- @return any
function WheelErrors.normalize(err, command_id)
  if WheelErrors.is_typed(err) then
    return err
  end
  if type(err) == "table" then
    return err
  end
  if type(err) == "string" then
    local capability = missing_capability(err)
    if capability then
      return WheelErrors.capability_denied(capability)
    end
  end
  return WheelErrors.internal(command_id)
end

local function pack(...)
  return { n = select("#", ...), ... }
end

--- Wrap a command handler with the typed dispatch boundary.
-- Registration metadata is untouched; only failures change shape.
-- @param command_id string
-- @param handler function
-- @return function
function WheelErrors.wrap(command_id, handler)
  assert(type(handler) == "function", "command handler must be a function")
  return function(...)
    local results = pack(pcall(handler, ...))
    if results[1] then
      return unpack_values(results, 2, results.n)
    end
    error(WheelErrors.normalize(results[2], command_id), 0)
  end
end

return WheelErrors
