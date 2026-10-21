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
--
-- Command schema and argument failures use the SDK mock-host validation
-- vocabulary (`E_SCHEMA_INVALID`, `E_ARGS_INVALID`, `E_RESULT_INVALID`) with
-- class `validation`, and the same three-field bridge shape.
--
-- Context snapshot validation failures use a Wheel-local
-- `E_SNAPSHOT_INVALID` validation code. The snapshot is caller-supplied,
-- potentially tampered data; the cause stays a bounded single-line schema path
-- so validation never reflects slot content or an unbounded attacker-controlled
-- key.

local WheelErrors = {}

WheelErrors.CLASS_RUNTIME = "runtime"
WheelErrors.CLASS_VALIDATION = "validation"
WheelErrors.CLASS_RESOLUTION = "resolution"
WheelErrors.E_CAPABILITY_DENIED = "E_CAPABILITY_DENIED"
WheelErrors.E_INTERNAL = "E_INTERNAL"
WheelErrors.E_ARGS_INVALID = "E_ARGS_INVALID"
WheelErrors.E_SCHEMA_INVALID = "E_SCHEMA_INVALID"
WheelErrors.E_RESULT_INVALID = "E_RESULT_INVALID"
WheelErrors.E_COMPLETION_BUDGET_INVALID = "E_COMPLETION_BUDGET_INVALID"
WheelErrors.E_SNAPSHOT_INVALID = "E_SNAPSHOT_INVALID"
WheelErrors.E_MODULE_LOAD_FAILED = "E_MODULE_LOAD_FAILED"
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

local function validation_detail(command_id, label, detail)
  local id = valid_identifier(command_id) and command_id or "unknown"
  local reason = type(detail) == "string" and detail or "invalid shape"
  -- Argument field names are untrusted; keep the single-line diagnostic free
  -- of control characters so a crafted key cannot forge log lines.
  reason = reason:gsub("%c", "?")
  return string.format("%s in wheel command '%s': %s", label, id, reason)
end

--- Build a typed invalid-arguments failure.
-- The detail is a bounded schema path and reason; `typed` keeps the final
-- message to one line within `MESSAGE_MAX_LENGTH`.
-- @param command_id string
-- @param detail string
-- @return table
function WheelErrors.args_invalid(command_id, detail)
  return typed(
    WheelErrors.CLASS_VALIDATION,
    WheelErrors.E_ARGS_INVALID,
    validation_detail(command_id, "invalid arguments", detail)
  )
end

--- Build a typed invalid-schema failure.
-- Raised at registration, before the handler is wrapped or captured.
-- @param command_id string
-- @param detail string
-- @return table
function WheelErrors.schema_invalid(command_id, detail)
  return typed(
    WheelErrors.CLASS_VALIDATION,
    WheelErrors.E_SCHEMA_INVALID,
    validation_detail(command_id, "invalid command schema", detail)
  )
end

--- Build a typed invalid-result failure.
-- Raised after a handler returns when its result no longer matches the
-- registered `result_schema`.
-- @param command_id string
-- @param detail string
-- @return table
function WheelErrors.result_invalid(command_id, detail)
  return typed(
    WheelErrors.CLASS_VALIDATION,
    WheelErrors.E_RESULT_INVALID,
    validation_detail(command_id, "invalid command result", detail)
  )
end

--- Build a typed invalid completion-budget failure.
-- Provider and agent overrides must be positive integers within the named
-- bound; an invalid value is rejected before a request is sent.
-- @param detail string
-- @return table
function WheelErrors.completion_budget_invalid(detail)
  local reason = type(detail) == "string" and detail or "invalid bound"
  reason = reason:gsub("%c", "?")
  return typed(
    WheelErrors.CLASS_VALIDATION,
    WheelErrors.E_COMPLETION_BUDGET_INVALID,
    "invalid completion budget: " .. reason
  )
end

-- Snapshot schema paths can include a slot or commit key. Keep the diagnostic
-- short so the reason survives the bridge message bound.
local SNAPSHOT_DETAIL_MAX_LENGTH = 112

--- Build a typed invalid context-snapshot failure.
-- The detail is a bounded schema path and reason, never slot content. It is
-- sanitized to one line before the bridge message bound is applied.
-- @param detail string
-- @return table
function WheelErrors.snapshot_invalid(detail)
  local reason = type(detail) == "string" and detail or "invalid snapshot"
  -- Bound before sanitizing so an oversized key or path cannot be copied in
  -- full just to be discarded.
  if #reason > SNAPSHOT_DETAIL_MAX_LENGTH then
    reason = reason:sub(1, SNAPSHOT_DETAIL_MAX_LENGTH - 3) .. "..."
  end
  reason = reason:gsub("%c", "?")
  return typed(
    WheelErrors.CLASS_VALIDATION,
    WheelErrors.E_SNAPSHOT_INVALID,
    "invalid context snapshot: " .. reason
  )
end

-- Loader diagnostics can carry the interpreter's package search path, which
-- may embed a host checkout or system directory. Keep the cause bounded and
-- path-free: a not-found result is fully described by its rooted module name,
-- and parser/runtime failures keep only the source basename and line.
local MODULE_CAUSE_MAX_LENGTH = 96

local function sanitize_module_cause(cause)
  if type(cause) == "table" and type(cause.message) == "string" then
    cause = cause.message
  end
  if type(cause) ~= "string" or cause == "" then
    return "unknown cause"
  end
  local text = cause:gsub("%c", " "):gsub("\\", "/")

  local not_found = text:match("module%s+'[^']+'%s+not%s+found")
  if not_found then
    return not_found
  end

  text = text:gsub("error loading module '[^']+' from file '[^']*':%s*", "")
  text = text:gsub("[^%s:]*/([%w%._%-]+%.lua:%d+):", "%1:")
  text = text:gsub("[^%s]*/[^%s]*", "<path>")
  text = text:gsub("%s+", " ")
  text = text:gsub("^%s*(.-)%s*$", "%1")
  if #text > MODULE_CAUSE_MAX_LENGTH then
    text = text:sub(1, MODULE_CAUSE_MAX_LENGTH - 3) .. "..."
  end
  return text
end

--- Build a typed activation failure for a module that could not be loaded.
-- The message names the rooted module and a bounded, path-free cause. A loader
-- stack trace is never included.
-- @param module_name string Rooted module name (`wheel.agent`).
-- @param cause string? Underlying loader diagnostic.
-- @return table
function WheelErrors.module_load_failed(module_name, cause)
  local name = valid_identifier(module_name) and module_name or "unknown"
  return typed(
    WheelErrors.CLASS_RESOLUTION,
    WheelErrors.E_MODULE_LOAD_FAILED,
    string.format("activation failed for module '%s': %s", name, sanitize_module_cause(cause))
  )
end

-- Missing sandbox globals mapped to the capability a host would have to
-- grant. Only globals are classified: a bare field name such as `remove` or
-- `open` has no owning table in the interpreter message, so treating it as a
-- capability would mask ordinary table bugs. Table-member cases are covered
-- by the explicit guards at the call sites.
local NIL_CAPABILITIES = {
  io = "fs.read",
  loadfile = "fs.read",
  dofile = "fs.read",
  -- A wholly absent `os` table can only be classified conservatively at the
  -- boundary; explicit guards name the precise fs/process surface.
  os = "env.read",
}

--- Map a raw nil-global failure to a capability identifier.
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

  return nil
end

--- Return true when `err` matches the exact accepted bridge error shape.
-- Exactly three fields (`class`, `code`, `message`) are required; extra
-- fields, non-string values, and over-bound messages are treated as
-- malformed and normalized to E_INTERNAL.
-- @param err any
-- @return boolean
function WheelErrors.is_typed(err)
  if type(err) ~= "table" then
    return false
  end
  local fields = 0
  for key in pairs(err) do
    if key ~= "class" and key ~= "code" and key ~= "message" then
      return false
    end
    fields = fields + 1
  end
  if fields ~= 3 then
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

-- Unforgeable passthrough marker: a module-local key and token. Neither value
-- is reachable from a handler, so no table shaped like a sentinel can claim
-- passthrough by copying a field name or a boolean.
local PASSTHROUGH_KEY = {}
local PASSTHROUGH_TOKEN = {}

--- Mark an internal structured value as intentionally opaque.
-- The dispatch budget sentinel uses this so the boundary preserves its
-- identity instead of normalizing it to E_INTERNAL. This is not part of the
-- public error contract.
-- @param err table
-- @return table
function WheelErrors.passthrough(err)
  assert(type(err) == "table", "passthrough value must be a table")
  rawset(err, PASSTHROUGH_KEY, PASSTHROUGH_TOKEN)
  return err
end

--- Return true when `err` carries the module-local passthrough token.
-- @param err any
-- @return boolean
function WheelErrors.is_passthrough(err)
  return type(err) == "table"
    and rawget(err, PASSTHROUGH_KEY) == PASSTHROUGH_TOKEN
end

--- Normalize a handler failure into a typed error table.
-- Typed errors pass through unchanged. A raw nil-global failure from the
-- sandbox becomes a capability denial for the missing surface. Tables are
-- shape-enforced: malformed tables become E_INTERNAL, except for values
-- explicitly marked with `WheelErrors.passthrough` (the dispatch budget
-- sentinel). Everything else becomes E_INTERNAL.
-- @param err any
-- @param command_id string
-- @return any
function WheelErrors.normalize(err, command_id)
  if WheelErrors.is_typed(err) then
    return err
  end
  if WheelErrors.is_passthrough(err) then
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
