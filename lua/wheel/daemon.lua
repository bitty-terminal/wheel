-- lua/wheel/daemon.lua
-- Wheel: local session daemon (server side).
--
-- The daemon owns one WheelContext and one private runtime directory. It is
-- started detached by `scripts/wheel-session start`, opens the two session
-- FIFOs read/write, publishes metadata only after the FIFOs are ready, removes
-- the start lock, and serves newline-framed JSON requests until an explicit
-- `shutdown`.
--
-- The daemon is deliberately small: it does not own a task DAG, call a
-- provider, spawn an agent, or listen on a network. Its authority is the
-- session owner's existing local authority; the control plane adds no new
-- capability class. See `SECURITY-MODEL.md` for the same-user FIFO residual.

local script_path = type(arg) == "table" and arg[0] or ""
local lua_root = type(script_path) == "string" and script_path:match("^(.*)/wheel/daemon%.lua$") or nil
if lua_root and lua_root ~= "" then
  package.path = lua_root .. "/?.lua;" .. lua_root .. "/?/init.lua;" .. package.path
end

local Session = require("wheel.session")
local WheelContext = require("wheel.context")
local WheelHost = require("wheel.host")

local Daemon = {}

local PROTOCOL = Session.PROTOCOL
local MAX_REQUEST_BYTES = Session.MAX_REQUEST_BYTES
local MAX_RESPONSE_BYTES = Session.MAX_RESPONSE_BYTES

local function daemon_error(code, message, class)
  return Session.error(code, message, class)
end

local function err_args()
  return daemon_error("E_SESSION_ARGS_INVALID", "invalid session method arguments", "validation")
end

local function err_unknown()
  return daemon_error("E_SESSION_METHOD_UNKNOWN", "unknown session method", "validation")
end

local function err_context()
  return daemon_error("E_SESSION_CONTEXT_ERROR", "context operation failed")
end

local function err_context_limit()
  return daemon_error("E_SESSION_CONTEXT_LIMIT", "context store exceeds the session bound")
end

-- ---------------------------------------------------------------------------
-- Context snapshot
-- ---------------------------------------------------------------------------

local function slot_summaries(context, limit)
  local slots = context:list_slots()
  local summaries = Session.array()
  local count = 0
  for _, slot in ipairs(slots) do
    if count >= limit then
      break
    end
    summaries[#summaries + 1] = {
      name = slot.name,
      kind = slot.kind,
      hash = slot.hash,
      version = slot.version,
      size_bytes = slot.size_bytes,
    }
    count = count + 1
  end
  return summaries, #slots, #slots > limit
end

local function context_status(context)
  local slots = context:list_slots()
  return {
    slot_count = #slots,
    tree_hash = context:tree_hash(),
    head = context:head_commit_hash() or "",
  }
end

-- ---------------------------------------------------------------------------
-- Method dispatch
-- ---------------------------------------------------------------------------

local function params_are_empty(params)
  if params == nil then
    return true
  end
  if type(params) ~= "table" then
    return false
  end
  return next(params) == nil
end

local function valid_slot_name(name)
  return type(name) == "string"
    and #name > 0
    and #name <= Session.MAX_CONTEXT_NAME_BYTES
    and not name:find("[%z\1-\31]")
end

local function validate_put(params)
  if type(params) ~= "table" or not valid_slot_name(params.name) then
    return nil, err_args()
  end
  if type(params.content) ~= "string" or #params.content > Session.MAX_CONTEXT_CONTENT_BYTES then
    return nil, err_args()
  end
  local expected = params.expected_version
  if expected ~= nil and (type(expected) ~= "number" or expected % 1 ~= 0 or expected < 0) then
    return nil, err_args()
  end
  return {
    name = params.name,
    content = params.content,
    expected_version = expected,
  }, nil
end

local function handle_put(context, params)
  local request, args_err = validate_put(params)
  if not request then
    return nil, args_err
  end

  local slots = context:list_slots()
  local existing = context:get_slot(request.name)
  local total_bytes = 0
  for _, slot in ipairs(slots) do
    total_bytes = total_bytes + slot.size_bytes
  end
  if existing and existing.found then
    total_bytes = total_bytes - (existing.size_bytes or 0)
  elseif #slots >= Session.MAX_CONTEXT_SLOTS then
    return nil, err_context_limit()
  end
  if total_bytes + #request.content > Session.MAX_CONTEXT_TOTAL_BYTES then
    return nil, err_context_limit()
  end

  local result, put_err = context:put_slot(request.name, request.content, request.expected_version)
  if not result then
    if type(put_err) == "table" and put_err.error == "cas_conflict" then
      local expected = tonumber(put_err.expected_version) or 0
      local current = tonumber(put_err.current_version) or 0
      return nil, daemon_error(
        "E_SESSION_CAS_CONFLICT",
        string.format("context version conflict: expected %d, current is %d", expected, current)
      )
    end
    return nil, err_context()
  end
  return {
    success = true,
    name = result.name,
    hash = result.hash,
    version = result.version,
    kind = result.kind,
    size_bytes = result.size_bytes,
  }, nil
end

local function handle_get(context, params)
  if type(params) ~= "table" or not valid_slot_name(params.name) then
    return nil, err_args()
  end
  local slot = context:get_slot(params.name)
  if not slot or not slot.found then
    return { name = params.name, found = false }, nil
  end
  return {
    name = slot.name,
    found = true,
    content = slot.content,
    hash = slot.hash,
    version = slot.version,
    kind = slot.kind,
    size_bytes = slot.size_bytes,
    updated_at_ms = slot.updated_at_ms,
  }, nil
end

local function handle_list(context, params)
  local prefix = nil
  if params ~= nil then
    if type(params) ~= "table" then
      return nil, err_args()
    end
    prefix = params.prefix
    if prefix ~= nil then
      if type(prefix) ~= "string"
        or #prefix > Session.MAX_CONTEXT_NAME_BYTES
        or prefix:find("[%z\1-\31]") then
        return nil, err_args()
      end
    end
  end
  local slots = context:list_slots(prefix)
  local summaries = Session.array()
  local limit = math.min(#slots, Session.MAX_LIST_SLOTS)
  for index = 1, limit do
    local slot = slots[index]
    summaries[#summaries + 1] = {
      name = slot.name,
      kind = slot.kind,
      hash = slot.hash,
      version = slot.version,
      size_bytes = slot.size_bytes,
    }
  end
  return {
    slots = summaries,
    total = #slots,
    truncated = #slots > limit,
  }, nil
end

local function method_result(state, method, params)
  local context = state.context
  if method == "ping" then
    if not params_are_empty(params) then
      return nil, err_args()
    end
    return {
      protocol = PROTOCOL,
      name = state.name,
      pid = state.pid,
      started_at = state.started_at,
      uptime_seconds = math.max(0, WheelHost.time.now() - state.started_at),
      wheel_version = state.wheel_version,
      requests = state.requests,
    }, nil
  elseif method == "session.status" then
    if not params_are_empty(params) then
      return nil, err_args()
    end
    return {
      protocol = PROTOCOL,
      name = state.name,
      pid = state.pid,
      started_at = state.started_at,
      uptime_seconds = math.max(0, WheelHost.time.now() - state.started_at),
      wheel_version = state.wheel_version,
      requests = state.requests,
      context = context_status(context),
    }, nil
  elseif method == "session.snapshot" then
    if not params_are_empty(params) then
      return nil, err_args()
    end
    local summaries, total, truncated = slot_summaries(context, Session.MAX_SNAPSHOT_SLOTS)
    return {
      protocol = PROTOCOL,
      name = state.name,
      pid = state.pid,
      started_at = state.started_at,
      wheel_version = state.wheel_version,
      context = {
        slot_count = total,
        tree_hash = context:tree_hash(),
        head = context:head_commit_hash() or "",
        slots = summaries,
        truncated = truncated,
      },
    }, nil
  elseif method == "context.put" then
    return handle_put(context, params)
  elseif method == "context.get" then
    return handle_get(context, params)
  elseif method == "context.list" then
    return handle_list(context, params)
  elseif method == "shutdown" then
    if not params_are_empty(params) then
      return nil, err_args()
    end
    return {
      protocol = PROTOCOL,
      name = state.name,
      pid = state.pid,
      shutting_down = true,
    }, nil
  end
  return nil, err_unknown()
end

--- Dispatch one method inside the daemon's typed failure boundary.
-- A host-primitive denial or an unexpected context failure is caught and
-- converted to a static session error, so the daemon can answer and keep
-- serving instead of exiting through an unhandled Lua error.
-- @param state table daemon state
-- @param method string
-- @param params table?
-- @return table? result, table? err
local function dispatch(state, method, params)
  local ok, result, failure = pcall(method_result, state, method, params)
  if not ok then
    return nil, daemon_error("E_SESSION_CONTEXT_ERROR", "session method failed closed")
  end
  return result, failure
end
Daemon.dispatch = dispatch

local function build_response(request, result, failure)
  local response = {
    protocol = PROTOCOL,
    id = request and request.id or "",
    method = request and request.method or "",
    ok = failure == nil,
  }
  if failure then
    response.error = { class = failure.class, code = failure.code, message = failure.message }
  else
    response.result = result
  end
  return response
end

local function write_response(handle, response)
  local encoded_ok, encoded = pcall(Session.json_encode, response)
  if not encoded_ok then
    return false
  end
  if #encoded + 1 > MAX_RESPONSE_BYTES then
    local fallback = build_response({ id = response.id, method = response.method }, nil,
      Session.err_response_too_large())
    encoded_ok, encoded = pcall(Session.json_encode, fallback)
    if not encoded_ok or #encoded + 1 > MAX_RESPONSE_BYTES then
      return false
    end
  end
  return Session.write_frame(handle, encoded)
end

-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------

local function log_daemon_error(code, message)
  io.stderr:write(string.format("wheel-session-daemon: %s: %s\n", code, message))
end

local function cleanup(state)
  -- Only the holder of the start lock may unlink control files. If this daemon
  -- still owns the start lock from a failed post-handoff startup, treat it as
  -- held instead of re-acquiring (which would see its own pid as busy). A
  -- concurrent starter that owns it makes this cleanup a no-op.
  local owned_ok, owned = pcall(
    Session.lock_owned_by, state.session_dir, Session.FILE_START_LOCK, state.pid)
  local self_owned = owned_ok and owned == true
  local locked = self_owned
  if not locked then
    local acquire_ok, acquired = pcall(
      Session.acquire_lock, state.session_dir, Session.FILE_START_LOCK, state.pid)
    if not acquire_ok then
      pcall(Session.release_lock, state.session_dir, Session.FILE_START_LOCK, state.pid)
      pcall(Session.release_lock, state.session_dir,
        Session.FILE_START_LOCK .. ".mutex", state.pid)
      return
    end
    locked = acquired == true
  end
  if not locked then
    return
  end

  local meta = Session.read_metadata(state.session_dir, state.name)
  if meta then
    if meta.pid ~= state.pid then
      Session.release_start_lock(state.session_dir, state.pid)
      return
    end
  elseif not self_owned then
    -- Missing or unreadable metadata does not identify the files as this
    -- daemon's. A successor (live or starting) can be in exactly that state
    -- after a same-user tamper or a failed publish; leave its metadata/FIFOs
    -- alone. A failed post-handoff startup is safe to clean because the start
    -- lock is still self-owned.
    Session.release_start_lock(state.session_dir, state.pid)
    return
  end

  for _, fifo in ipairs({ Session.FILE_REQUEST, Session.FILE_RESPONSE }) do
    local path = state.session_dir .. "/" .. fifo
    local info = WheelHost.fs.stat(path)
    local euid = WheelHost.fs.euid()
    if info and info.exists and info.fifo and not info.symlink
      and info.uid == euid and info.mode == Session.PRIVATE_FILE_MODE and info.links == 1 then
      WheelHost.fs.remove_file(path)
    end
  end
  local meta_info = WheelHost.fs.stat(state.session_dir .. "/" .. Session.FILE_META)
  local euid = WheelHost.fs.euid()
  if meta_info and meta_info.exists and meta_info.regular and not meta_info.symlink
    and meta_info.uid == euid and meta_info.mode == Session.PRIVATE_FILE_MODE
    and meta_info.links == 1 then
    WheelHost.fs.remove_file(state.session_dir .. "/" .. Session.FILE_META)
  end
  local pruned = Session.prune_stale_files(state.session_dir, state.pid)
  if not pruned then
    Session.release_start_lock(state.session_dir, state.pid)
    return
  end
  Session.release_start_lock(state.session_dir, state.pid)
  local info = WheelHost.fs.stat(state.session_dir)
  if info and info.exists and info.directory and not info.symlink then
    WheelHost.fs.remove_dir(state.session_dir)
  end
end
Daemon.cleanup = cleanup

local function read_valid_meta(state)
  local meta, meta_err = Session.read_metadata(state.session_dir, state.name)
  if meta == nil then
    if meta_err and meta_err.code == "E_SESSION_NOT_RUNNING" then
      return nil, nil
    end
    return nil, meta_err
  end
  return meta, nil
end

--- Run the daemon until an explicit shutdown or a bounded protocol failure.
-- @param opts table { root, name, wheel_version }
-- @return number exit code
function Daemon.run(opts)
  opts = opts or {}
  local name = opts.name
  local name_ok, name_err = Session.validate_name(name)
  if not name_ok then
    log_daemon_error(name_err.code, name_err.message)
    return 2
  end
  local start_owner = opts.start_owner
  if type(start_owner) ~= "number" or start_owner % 1 ~= 0 or start_owner <= 1 then
    log_daemon_error("E_SESSION_START_FAILED", "a valid start owner pid is required")
    return 2
  end
  local root_ok, root_err = Session.validate_absolute_path(opts.root)
  if not root_ok then
    log_daemon_error(root_err.code, root_err.message)
    return 2
  end
  local root_call_ok, root_ready, root_ensure_err = pcall(Session.ensure_root, opts.root)
  if not root_call_ok or not root_ready then
    log_daemon_error(
      root_ensure_err and root_ensure_err.code or "E_SESSION_START_FAILED",
      root_ensure_err and root_ensure_err.message or "cannot verify the session root")
    return 3
  end
  local version = opts.wheel_version
  if type(version) ~= "string" or not version:match("^%d+%.%d+%.%d+$") then
    log_daemon_error("E_SESSION_START_FAILED", "a semantic version is required")
    return 2
  end

  local session_dir = opts.root .. "/" .. name
  local dir_call_ok, dir_info, dir_err = pcall(
    Session.ensure_session_dir, session_dir, false)
  if not dir_call_ok or not dir_info then
    log_daemon_error(
      dir_err and dir_err.code or "E_SESSION_START_FAILED",
      dir_err and dir_err.message or "cannot verify the session directory")
    return 3
  end

  local meta_ok, existing, existing_err = pcall(read_valid_meta, {
    session_dir = session_dir,
    name = name,
  })
  if not meta_ok then
    log_daemon_error("E_SESSION_START_FAILED", "cannot read existing session metadata")
    return 3
  end
  if existing_err then
    log_daemon_error(existing_err.code, existing_err.message)
    return 3
  end
  if existing then
    local alive_ok, alive, probe_err = pcall(WheelHost.proc.is_alive, existing.pid)
    if not alive_ok or probe_err ~= nil then
      log_daemon_error("E_SESSION_UNRESPONSIVE", "cannot verify the recorded daemon pid")
      return 3
    end
    if alive then
      log_daemon_error("E_SESSION_ALREADY_RUNNING", "session is already running")
      return 1
    end
  end

  local request_ok, request = pcall(
    WheelHost.fs.open_fifo, session_dir .. "/" .. Session.FILE_REQUEST)
  if not request_ok or not request then
    log_daemon_error("E_SESSION_IO", "cannot open the session request FIFO")
    return 3
  end
  local response_ok, response = pcall(
    WheelHost.fs.open_fifo, session_dir .. "/" .. Session.FILE_RESPONSE)
  if not response_ok or not response then
    pcall(request.close, request)
    log_daemon_error("E_SESSION_IO", "cannot open the session response FIFO")
    return 3
  end

  local pid_ok, pid = pcall(WheelHost.proc.pid)
  if not pid_ok or pid == nil then
    pcall(response.close, response)
    pcall(request.close, request)
    log_daemon_error("E_SESSION_START_FAILED", "cannot determine the daemon pid")
    return 3
  end

  -- Take ownership of the start lock before publishing metadata. A delayed
  -- starter whose lock was reclaimed by a newer start loses this handoff and
  -- aborts without touching meta.json or the new FIFOs.
  local handoff_ok, handoff = pcall(
    Session.handoff_start_lock, session_dir, start_owner, pid)
  if not handoff_ok or not handoff then
    pcall(Session.release_lock, session_dir, Session.FILE_START_LOCK .. ".mutex", pid)
    pcall(response.close, response)
    pcall(request.close, request)
    log_daemon_error("E_SESSION_START_FAILED", "cannot take ownership of the session start lock")
    return 3
  end

  local state = {
    name = name,
    pid = pid,
    started_at = nil,
    wheel_version = version,
    session_dir = session_dir,
    start_owner = start_owner,
    context = nil,
    requests = 0,
    request = request,
    response = response,
    running = true,
  }

  local time_ok, started_at = pcall(WheelHost.time.now)
  if not time_ok then
    pcall(cleanup, state)
    pcall(response.close, response)
    pcall(request.close, request)
    log_daemon_error("E_SESSION_START_FAILED", "the host time primitive is unavailable")
    return 3
  end
  state.started_at = started_at
  local context_ok, context = pcall(WheelContext.new, {})
  if not context_ok then
    pcall(cleanup, state)
    pcall(response.close, response)
    pcall(request.close, request)
    log_daemon_error("E_SESSION_START_FAILED", "cannot initialize the session context")
    return 3
  end
  state.context = context

  local wrote_ok, wrote, write_err = pcall(Session.write_metadata, session_dir, {
    protocol = PROTOCOL,
    name = name,
    pid = pid,
    started_at = started_at,
    wheel_version = version,
    start_owner = start_owner,
  })
  if not wrote_ok or not wrote then
    pcall(cleanup, state)
    pcall(response.close, response)
    pcall(request.close, request)
    log_daemon_error(write_err and write_err.code or "E_SESSION_IO", "cannot publish session metadata")
    return 3
  end
  local released_ok, released = pcall(Session.release_start_lock, session_dir, pid)
  if not released_ok or released == false then
    pcall(cleanup, state)
    pcall(response.close, response)
    pcall(request.close, request)
    log_daemon_error("E_SESSION_START_FAILED", "cannot release the session start lock")
    return 3
  end

  local loop_ok = pcall(function()
    while state.running do
      local line, status = Session.read_frame(state.request, MAX_REQUEST_BYTES)
      if not line then
        if status == "too_large" then
          write_response(state.response, build_response(nil, nil, Session.err_frame_too_large()))
        elseif status == "oversized" then
          write_response(state.response, build_response(nil, nil, Session.err_frame_too_large()))
          state.running = false
        elseif status == "io" then
          state.running = false
        else
          state.running = false
        end
      else
        local decoded_ok, request_value = pcall(Session.json_decode, line)
        if not decoded_ok or type(request_value) ~= "table" then
          write_response(state.response, build_response(
            { id = "", method = "" }, nil, Session.err_protocol()))
        else
          local valid, request_err = Session.validate_request(request_value)
          if not valid then
            write_response(state.response, build_response(request_value, nil, request_err))
          else
            state.requests = state.requests + 1
            local result, method_err = dispatch(state, request_value.method, request_value.params)
            local response_value = build_response(request_value, result, method_err)
            if not write_response(state.response, response_value) then
              state.running = false
            elseif request_value.method == "shutdown" and method_err == nil then
              state.running = false
            end
          end
        end
      end
    end
  end)

  local cleanup_ok = pcall(cleanup, state)
  pcall(response.close, response)
  pcall(request.close, request)
  if not loop_ok then
    log_daemon_error("E_SESSION_CONTEXT_ERROR", "session loop failed closed")
    return 1
  end
  if not cleanup_ok then
    log_daemon_error("E_SESSION_IO", "session cleanup failed closed")
    return 1
  end
  return 0
end

local function usage()
  io.stderr:write("usage: wheel-session-daemon --root <dir> --name <name> --version <x.y.z> --start-owner <pid>\n")
end

--- Daemon entry point. Arguments are script-style (`arg[1]` is the first flag).
-- @param argv table
-- @return number exit code
function Daemon.main(argv)
  local values = {}
  local index = 1
  while index <= #(argv or {}) do
    local flag = argv[index]
    local value = argv[index + 1]
    if flag == "--root" or flag == "--name" or flag == "--version" or flag == "--start-owner" then
      if value == nil then
        usage()
        return 2
      end
      values[flag:sub(3)] = value
      index = index + 2
    else
      usage()
      return 2
    end
  end
  if values.root == nil or values.name == nil or values.version == nil then
    usage()
    return 2
  end
  return Daemon.run({
    root = values.root,
    name = values.name,
    wheel_version = values.version,
    start_owner = tonumber(values["start-owner"] or ""),
  })
end

if type(arg) == "table" and type(arg[0]) == "string" and arg[0]:match("daemon%.lua$") then
  os.exit(Daemon.main(arg))
end

return Daemon
