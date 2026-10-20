-- lua/wheel/commands.lua
-- Wheel: bounded command metadata, registration, and dispatch validation.
--
-- Command arguments and results are bounded by `wheel.schema`. The result
-- body has one additional cap: the current host bridge marshals a command
-- result through `DEFAULT_MAX_VALUE_BYTES` (8 KiB) in
-- `crates/bitty-lua/src/host.rs`. The body bound below subtracts a named
-- envelope reserve and the title bound so the complete `{ title, body }`
-- projection stays under that host cap.

local function load_sibling(name)
  local rooted = "wheel." .. name
  local ok, mod = pcall(require, rooted)
  if ok then return mod end
  local cause = mod

  local alternate = "lua.wheel." .. name
  ok, mod = pcall(require, alternate)
  if ok then return mod end

  error(string.format("wheel.commands: cannot load sibling '%s': %s",
    rooted, tostring(mod or cause)), 0)
end

local WheelErrors = load_sibling("errors")
local WheelSchema = load_sibling("schema")

local WheelCommands = {}

-- Host bridge result cap (`DEFAULT_MAX_VALUE_BYTES` in bitty-lua host.rs).
WheelCommands.HOST_RESULT_MAX_BYTES = 8 * 1024

-- Reserve for the result keys and a small margin. The host charges string
-- bytes for the two keys (`title` and `body` are 9 bytes) plus the title and
-- body; 128 is well above that overhead.
WheelCommands.RESULT_ENVELOPE_MAX_BYTES = 128

WheelCommands.RESULT_TITLE_MAX_LENGTH = 64

-- 8192 - 128 - 64 = 8000 bytes. The full projection has at most 8073 string
-- bytes under the host cap (9 key bytes + 64 title + 8000 body).
WheelCommands.RESULT_BODY_MAX_LENGTH = WheelCommands.HOST_RESULT_MAX_BYTES
  - WheelCommands.RESULT_ENVELOPE_MAX_BYTES
  - WheelCommands.RESULT_TITLE_MAX_LENGTH

assert(WheelCommands.RESULT_BODY_MAX_LENGTH > 0,
  "result body bound must be positive")

local function is_continuation_byte(byte)
  return byte ~= nil and byte >= 0x80 and byte <= 0xBF
end

--- Truncate a result body to the host-compatible bound.
-- The cut backs off to the previous UTF-8 boundary so a multibyte character is
-- never split. This intentionally does not depend on Lua 5.3 `utf8`; the
-- project runs on Lua 5.1/LuaJIT as well.
-- @param body string
-- @return string
function WheelCommands.truncate_body(body)
  if type(body) ~= "string" then
    body = tostring(body)
  end
  local limit = WheelCommands.RESULT_BODY_MAX_LENGTH
  if #body <= limit then
    return body
  end

  local cut = limit - 3
  while cut > 0 and is_continuation_byte(body:byte(cut + 1)) do
    cut = cut - 1
  end
  return body:sub(1, cut) .. "..."
end

--- Build the closed argument schema for a command that takes no arguments.
-- `properties` is omitted rather than set to an empty table because the host
-- marshaller encodes an empty Lua table as a JSON array; with no declared
-- properties and `additionalProperties = false`, the host still rejects every
-- supplied field.
-- @return table
function WheelCommands.no_args_schema()
  return {
    type = "object",
    additionalProperties = false,
  }
end

--- Build the bounded result schema for the notification projection.
-- Each command owns its own table, so a later per-command narrowing does not
-- mutate another command's contract.
-- @return table
function WheelCommands.notification_result_schema()
  return {
    type = "object",
    properties = {
      title = { type = "string", minLength = 1, maxLength = WheelCommands.RESULT_TITLE_MAX_LENGTH },
      body = { type = "string", minLength = 1, maxLength = WheelCommands.RESULT_BODY_MAX_LENGTH },
    },
    required = { "title", "body" },
    additionalProperties = false,
  }
end

--- Show a notification and return the exact projection declared by the result
-- schema. The body is bounded before the notification is shown, so a large
-- DAG, roster, or context listing cannot violate the contract or the host cap.
-- @param host table Host table with `notify.show`.
-- @param title string
-- @param body string
-- @return table { title: string, body: string }
function WheelCommands.notify(host, title, body)
  assert(type(host) == "table" and type(host.notify) == "table"
      and type(host.notify.show) == "function",
    "notification host surface is required")
  assert(type(title) == "string" and #title >= 1
      and #title <= WheelCommands.RESULT_TITLE_MAX_LENGTH,
    "notification title must be non-empty and bounded")

  local bounded = WheelCommands.truncate_body(body)
  host.notify.show({
    title = title,
    body = bounded,
  })
  return { title = title, body = bounded }
end

--- Validate a command definition, wrap its handler, and register it.
-- Schemas are admitted before the handler is wrapped; arguments are validated
-- before the handler runs; the result is validated before it is returned.
-- @param def table Command definition.
-- @param host table Host table with `commands.register`.
-- @return table The registered definition.
function WheelCommands.register(def, host)
  assert(type(host) == "table" and type(host.commands) == "table"
      and type(host.commands.register) == "function",
    "command host surface is required")
  assert(type(def) == "table", "command definition must be a table")
  local id = def.id
  assert(type(id) == "string" and id ~= "", "command definition requires an id")
  assert(type(def.run) == "function", "command handler must be a function for " .. id)

  local ok, reason = WheelSchema.validate_schema(def.args_schema, "args_schema")
  if not ok then
    error(WheelErrors.schema_invalid(id, reason), 0)
  end
  ok, reason = WheelSchema.validate_schema(def.result_schema, "result_schema")
  if not ok then
    error(WheelErrors.schema_invalid(id, reason), 0)
  end

  local args_schema = def.args_schema
  local result_schema = def.result_schema
  local handler = def.run
  def.run = WheelErrors.wrap(id, function(args)
    local valid, arg_reason = WheelSchema.validate_args(args_schema, args)
    if not valid then
      error(WheelErrors.args_invalid(id, arg_reason), 0)
    end
    local result = handler(args or {})
    local result_ok, result_reason = WheelSchema.validate_value(result_schema, result, "$result")
    if not result_ok then
      error(WheelErrors.result_invalid(id, result_reason), 0)
    end
    return result
  end)

  host.commands.register(def)
  return def
end

return WheelCommands
