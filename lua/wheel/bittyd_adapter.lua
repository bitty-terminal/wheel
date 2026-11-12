-- lua/wheel/bittyd_adapter.lua
-- Wheel: transport-injectable consumer adapter for the Core-owned `bittyd`
-- session-host contract (`bitty#2546`, `bitty#2605`, `wheel#108`, `CTX-0036`).
--
-- Ownership boundary (`R-W01..R-W13`):
--   * Wheel owns the task graph, roles, agent loop, context store, snapshots,
--     tool policy, consent gates, provider routing, and execution audit chain.
--   * `bittyd` owns the per-user session registry, attach/detach leases,
--     worker generation, supervision, bounded queues, and service API version.
--   * This module is the transport-injectable client adapter (`R-W03`) and the
--     in-memory reference fake server (`candidate-not-bittyd`) used by the
--     adapter unit suite. It owns no daemon lifecycle, socket server, or
--     competing session registry (`R-W01`), never calls `daemon.stop` from a
--     consumer handle (`R-W13`), never signals worker pids (`R-W06`), and
--     never falls back silently to an in-process run when `bittyd` transport
--     is selected and unavailable (`R-W04`, `V-29`).

local M = {}

M.ADAPTER_SCHEMA = "wheel-bittyd-adapter/1"
M.FAKE_DRIVER_LABEL = "candidate-not-bittyd"
M.WIRE_VERSION = 1
M.SUPPORTED_MAJOR = 1
M.SUPPORTED_MINOR = 0
M.MAX_SERVER_MINOR = 5

M.TRANSPORT_IN_PROCESS = "in_process"
M.TRANSPORT_BITTYD = "bittyd"

M.DEFAULT_LIMITS = {
  max_sessions = 16,
  max_attaches_per_session = 8,
  max_attaches_per_connection = 8,
  max_retained_terminal_records = 64,
  session_record_bytes = 4096,
  terminal_retention_ms = 600000,
  attach_lease_ttl_ms = 15000,
  observer_grant_ttl_ms = 60000,
  host_grant_ttl_ms = 300000,
  request_timeout_ms = 10000,
  max_frame_bytes = 262144,
}

M.BASELINE_SCOPES = {
  "session.inspect",
  "session.attach",
  "session.control",
  "terminal.inspect",
  "terminal.input",
  "terminal.manage",
  "process.spawn",
}

local function shallow_copy(tbl)
  if type(tbl) ~= "table" then
    return tbl
  end
  local out = {}
  for k, v in pairs(tbl) do
    out[k] = v
  end
  return out
end

local function deep_copy(val)
  if type(val) ~= "table" then
    return val
  end
  local out = {}
  for k, v in pairs(val) do
    out[deep_copy(k)] = deep_copy(v)
  end
  return out
end

local function hex_id(seq, width)
  return string.format("%0" .. tostring(width) .. "x", seq)
end

local function is_hex_of_len(value, expected_len)
  if type(value) ~= "string" or #value ~= expected_len then
    return false
  end
  return value:match("^[0-9a-f]+$") ~= nil
end

local function typed_error(class, code, message, extra)
  local err = {
    class = class,
    code = code,
    message = message or code,
  }
  if type(extra) == "table" then
    for k, v in pairs(extra) do
      if k ~= "class" and k ~= "code" and k ~= "message" then
        err[k] = deep_copy(v)
      end
    end
  end
  return {
    ok = false,
    error = err,
  }
end

local function typed_ok(result)
  return {
    ok = true,
    result = deep_copy(result or {}),
  }
end

M.typed_error = typed_error
M.typed_ok = typed_ok
M.is_hex_of_len = is_hex_of_len

-- ---------------------------------------------------------------------------
-- Audit formatting (`R-W09`, `V-33`)
-- ---------------------------------------------------------------------------
-- Records `daemon_instance_id`, `session_id`, `generation`, `state_revision`,
-- `client_id`, and `action` (`a=<method> r=<outcome>`), while never recording
-- any token, bearer, capability, or terminal/prompt content payload.

local FORBIDDEN_AUDIT_KEYS = {
  control_token = true,
  host_grant = true,
  observer_grant = true,
  operator_capability = true,
  grant_token = true,
  grant = true,
  bearer = true,
  secret = true,
  api_key = true,
  prompt = true,
  content = true,
  data = true,
}

local function format_audit_entry(fields)
  local action = tostring(fields.action or "unknown")
  local outcome = tostring(fields.outcome or "ok")
  local parts = { "v1" }
  if type(fields.daemon_instance_id) == "string" and fields.daemon_instance_id ~= "" then
    parts[#parts + 1] = string.format("inst=%s", fields.daemon_instance_id)
  end
  if type(fields.client_id) == "string" and fields.client_id ~= "" then
    parts[#parts + 1] = string.format("client=%s", fields.client_id)
  end
  if type(fields.session_id) == "string" and fields.session_id ~= "" then
    parts[#parts + 1] = string.format("sid=%s", fields.session_id)
  end
  if type(fields.generation) == "number" then
    parts[#parts + 1] = string.format("gen=%d", fields.generation)
  end
  if type(fields.state_revision) == "number" then
    parts[#parts + 1] = string.format("rev=%d", fields.state_revision)
  end
  parts[#parts + 1] = string.format("a=%s", action)
  parts[#parts + 1] = string.format("r=%s", outcome)
  if type(fields.error_code) == "string" and fields.error_code ~= "" then
    parts[#parts + 1] = string.format("c=%s", fields.error_code)
  end
  return table.concat(parts, " ")
end

M.format_audit_entry = format_audit_entry
M.FORBIDDEN_AUDIT_KEYS = FORBIDDEN_AUDIT_KEYS

local function has_forbidden_wire_field(value)
  if type(value) ~= "table" then
    return false
  end
  for k, v in pairs(value) do
    if k == "pid" or k == "signal" then
      return true
    end
    if type(v) == "table" and has_forbidden_wire_field(v) then
      return true
    end
  end
  return false
end

-- ---------------------------------------------------------------------------
-- In-memory reference fake server (`candidate-not-bittyd`)
-- ---------------------------------------------------------------------------

local FakeServer = {}
FakeServer.__index = FakeServer

function M.new_fake_server(opts)
  opts = opts or {}
  local limits = shallow_copy(M.DEFAULT_LIMITS)
  if type(opts.limits) == "table" then
    for k, v in pairs(opts.limits) do
      limits[k] = v
    end
  end
  local self = setmetatable({
    driver_label = M.FAKE_DRIVER_LABEL,
    clock_ms = tonumber(opts.clock_ms) or 0,
    id_seq = 0,
    limits = limits,
    worker_sessions = opts.worker_sessions == true,
    needs_host_grant = opts.host_grant == true,
    state = "running",
    sessions = {},
    connections = {},
    connection_count = 0,
    create_keys = {},
    requests = {},
    audit_lines = {},
  }, FakeServer)
  self.instance_id = self:_mint_id()
  self.operator_capability = self:_mint_token()
  self.host_grant = self.needs_host_grant and self:_mint_token() or nil
  self.host_grant_consumed = false
  return self
end

function FakeServer:_mint_id()
  self.id_seq = self.id_seq + 1
  return hex_id(self.id_seq, 32)
end

function FakeServer:_mint_token()
  self.id_seq = self.id_seq + 1
  return hex_id(self.id_seq, 64)
end

function FakeServer:advance_clock(delta_ms)
  local delta = tonumber(delta_ms) or 0
  if delta > 0 then
    self.clock_ms = self.clock_ms + delta
  end
  self:_sweep_expired()
  self:_expire_retained_sessions()
end

function FakeServer:_sweep_expired()
  for _, sess in pairs(self.sessions) do
    for aid, lease in pairs(sess.leases) do
      if lease.expires_ms <= self.clock_ms then
        sess.leases[aid] = nil
        sess.state_revision = sess.state_revision + 1
        if sess.controller_attach_id == aid then
          sess.controller_attach_id = nil
        end
        for _, conn in pairs(self.connections) do
          conn.leases[aid] = nil
        end
      end
    end
  end
end

function FakeServer:_expire_retained_sessions()
  local ttl = self.limits.terminal_retention_ms
  for sid, sess in pairs(self.sessions) do
    if sess.terminalized_ms ~= nil and (self.clock_ms - sess.terminalized_ms) >= ttl then
      self.sessions[sid] = nil
    end
  end
end

function FakeServer:active_session_count()
  local n = 0
  for _, sess in pairs(self.sessions) do
    if sess.state ~= "terminated" and sess.state ~= "exited" and sess.state ~= "failed" then
      n = n + 1
    end
  end
  return n
end

function FakeServer:child_process_count()
  local n = 0
  for _, sess in pairs(self.sessions) do
    if sess.generation >= 1 and sess.state ~= "terminated" and sess.state ~= "exited" and sess.state ~= "failed" then
      n = n + 1
    end
  end
  return n
end

function FakeServer:request_log()
  return deep_copy(self.requests)
end

function FakeServer:audit_text()
  return table.concat(self.audit_lines, "\n")
end

function FakeServer:_record_audit(action, outcome, session, err_code)
  local line = format_audit_entry({
    action = action,
    outcome = outcome,
    daemon_instance_id = self.instance_id,
    session_id = session and session.session_id or nil,
    generation = session and session.generation or nil,
    state_revision = session and session.state_revision or nil,
    error_code = err_code,
  })
  self.audit_lines[#self.audit_lines + 1] = line
end

function FakeServer:_conn(name)
  local conn = self.connections[name]
  if not conn then
    self.connection_count = self.connection_count + 1
    conn = {
      name = name,
      negotiated = false,
      closed = false,
      client_id = nil,
      is_operator = false,
      has_host_grant = false,
      leases = {},
    }
    self.connections[name] = conn
  end
  return conn
end

function FakeServer:_session_snapshot(sess)
  local attach_count = 0
  for _, lease in pairs(sess.leases) do
    if self.clock_ms < lease.expires_ms then
      attach_count = attach_count + 1
    end
  end
  return {
    session_id = sess.session_id,
    terminal_id = sess.terminal_id,
    kind = sess.kind,
    state = sess.state,
    generation = sess.generation,
    state_revision = sess.state_revision,
    attach_count = attach_count,
    attached = attach_count > 0,
    controller_present = sess.controller_attach_id ~= nil,
    pending_observer_grants = 0,
    created_at_ms = sess.created_ms,
    last_seen_ms = sess.last_seen_ms,
    state_changed_at_ms = sess.state_changed_ms,
    created_by_kind = sess.created_by_kind or "consumer",
    terminal_reason = sess.terminal_reason,
    cleanup = sess.cleanup,
  }
end

function FakeServer:send_frame(connection_name, envelope, opts)
  opts = opts or {}
  local conn = self:_conn(connection_name or "client")
  if conn.closed then
    return { transport = "closed" }
  end
  self:_sweep_expired()
  self:_expire_retained_sessions()

  if type(opts.raw_size) == "number" and opts.raw_size > self.limits.max_frame_bytes then
    conn.closed = true
    self:_record_audit("wire", "refused", nil, "limit_exceeded")
    return { transport = "closed" }
  end

  local method = type(envelope) == "table" and envelope.method or nil
  local params = type(envelope) == "table" and envelope.params or nil
  self.requests[#self.requests + 1] = {
    connection = conn.name,
    method = method,
    params = deep_copy(params),
  }

  if method == "daemon.negotiate" then
    return self:_handle_negotiate(conn, params)
  end

  if not conn.negotiated then
    conn.closed = true
    self:_record_audit(tostring(method or "unknown"), "refused", nil, "AlreadyNegotiated")
    return typed_error("Denied", "AlreadyNegotiated", "daemon.negotiate must succeed first")
  end

  if method == "daemon.status" then
    if not conn.is_operator then
      self:_record_audit("daemon.status", "refused", nil, "ScopeViolation")
      return typed_error("Denied", "ScopeViolation", "daemon.inspect scope required")
    end
    self:_record_audit("daemon.status", "ok", nil)
    return typed_ok({
      daemon_instance_id = self.instance_id,
      daemon_state = self.state,
      active_sessions = self:active_session_count(),
      uptime_ms = self.clock_ms,
    })
  elseif method == "session.create" then
    return self:_handle_create(conn, params)
  elseif method == "session.attach" then
    return self:_handle_attach(conn, params)
  elseif method == "session.detach" then
    return self:_handle_detach(conn, params)
  elseif method == "session.status" then
    return self:_handle_status(conn, params)
  elseif method == "session.list" then
    return self:_handle_list(conn)
  elseif method == "session.abort" then
    local reply = self:_handle_abort(conn, params)
    if opts.fault == "drop_before_reply" then
      conn.closed = true
      return { transport = "closed" }
    end
    return reply
  elseif method == "lease.heartbeat" then
    return self:_handle_heartbeat(conn, params)
  end

  self:_record_audit(tostring(method or "unknown"), "refused", nil, "NotFound")
  return typed_error("NotFound", "NotFound", "unknown method")
end

function FakeServer:_handle_negotiate(conn, params)
  if conn.negotiated then
    conn.closed = true
    self:_record_audit("daemon.negotiate", "refused", nil, "AlreadyNegotiated")
    return typed_error("Denied", "AlreadyNegotiated", "daemon.negotiate already completed")
  end
  if type(params) ~= "table" or type(params.client_version) ~= "table" then
    conn.closed = true
    self:_record_audit("daemon.negotiate", "refused", nil, "VersionMismatch")
    return typed_error("Validation", "VersionMismatch", "missing client_version")
  end
  local major = params.client_version.major
  local minor = params.client_version.minor
  if major ~= M.SUPPORTED_MAJOR or type(minor) ~= "number" or minor < 0 or minor > M.MAX_SERVER_MINOR then
    conn.closed = true
    self:_record_audit("daemon.negotiate", "refused", nil, "VersionMismatch")
    return typed_error("Validation", "VersionMismatch", "unsupported protocol version")
  end
  if params.operator_capability ~= nil then
    if params.operator_capability ~= self.operator_capability then
      conn.closed = true
      self:_record_audit("daemon.negotiate", "refused", nil, "Unauthenticated")
      return typed_error("Unauthenticated", "Unauthenticated", "operator_capability is invalid")
    end
    conn.is_operator = true
  end
  if type(params.host_grant) == "string" and self.host_grant ~= nil then
    if params.host_grant == self.host_grant and not self.host_grant_consumed then
      self.host_grant_consumed = true
      conn.has_host_grant = true
    end
  end
  conn.negotiated = true
  conn.client_id = self:_mint_id()
  local scopes = deep_copy(M.BASELINE_SCOPES)
  if conn.has_host_grant then
    table.insert(scopes, 2, "session.host")
  end
  if conn.is_operator then
    scopes[#scopes + 1] = "daemon.inspect"
    scopes[#scopes + 1] = "daemon.control"
  end
  self:_record_audit("daemon.negotiate", "ok", nil)
  return typed_ok({
    wire_version = M.WIRE_VERSION,
    service_api_version = {
      major = M.SUPPORTED_MAJOR,
      minor = M.MAX_SERVER_MINOR,
      min_client_minor = M.SUPPORTED_MINOR,
    },
    daemon_instance_id = self.instance_id,
    client_id = conn.client_id,
    scopes = scopes,
    capabilities = {
      terminal_sessions = true,
      worker_sessions = self.worker_sessions,
      events = true,
      observer_grants = true,
      control_transfer = true,
      idempotent_mutations = true,
    },
    limits = deep_copy(self.limits),
    server_monotonic_ms = self.clock_ms,
    daemon_state = self.state,
  })
end

function FakeServer:_handle_create(conn, params)
  if type(params) ~= "table" then
    return typed_error("Validation", "InvalidRequest", "params must be a table")
  end
  if not conn.has_host_grant then
    self:_record_audit("session.create", "refused", nil, "ConsentRequired")
    return typed_error("Denied", "ConsentRequired", "session.host grant required")
  end
  local kind = params.kind or "terminal"
  if kind ~= "terminal" and kind ~= "worker" then
    return typed_error("Validation", "InvalidRequest", "unknown session kind")
  end
  if kind == "worker" and not self.worker_sessions then
    self:_record_audit("session.create", "refused", nil, "UnsupportedCapability")
    return typed_error("Denied", "UnsupportedCapability", "worker_sessions capability is disabled")
  end
  local idem = params.idempotency_key
  if type(idem) ~= "string" or idem == "" then
    return typed_error("Validation", "InvalidRequest", "missing idempotency_key")
  end
  local fp = kind .. ":" .. tostring(params.terminal_id or "")
  local prior = self.create_keys[idem]
  if prior then
    if prior.fingerprint ~= fp then
      return typed_error("Denied", "IdempotencyConflict", "idempotency_key reused with different parameters")
    end
    local sess = self.sessions[prior.session_id]
    if sess then
      self:_record_audit("session.create", "ok", sess)
      return typed_ok({
        session = self:_session_snapshot(sess),
        control_token = sess.initial_token,
        replayed = true,
      })
    end
  end
  if self:active_session_count() >= self.limits.max_sessions then
    return typed_error("Framing", "LimitExceeded", "session table is full", {
      counts = { self:active_session_count(), self.limits.max_sessions },
    })
  end
  local sid = self:_mint_id()
  local tid = type(params.terminal_id) == "string" and params.terminal_id or self:_mint_id()
  local token = self:_mint_token()
  local sess = {
    session_id = sid,
    terminal_id = tid,
    kind = kind,
    state = "created",
    generation = 0,
    state_revision = 0,
    control_token = token,
    initial_token = token,
    controller_attach_id = nil,
    leases = {},
    created_ms = self.clock_ms,
    last_seen_ms = self.clock_ms,
    state_changed_ms = self.clock_ms,
    created_by_kind = conn.is_operator and "operator" or "consumer",
    terminalized_ms = nil,
    terminal_reason = nil,
    cleanup = nil,
  }
  self.sessions[sid] = sess
  self.create_keys[idem] = {
    session_id = sid,
    fingerprint = fp,
  }
  self:_record_audit("session.create", "ok", sess)
  return typed_ok({
    session = self:_session_snapshot(sess),
    control_token = token,
    replayed = false,
  })
end

function FakeServer:_session_visible(conn, sess, token)
  if conn.is_operator then
    return true
  end
  for aid, _ in pairs(conn.leases) do
    local lease = sess.leases[aid]
    if lease and lease.expires_ms > self.clock_ms then
      return true
    end
  end
  if type(token) == "string" and token == sess.control_token then
    return true
  end
  return false
end

function FakeServer:_handle_attach(conn, params)
  if type(params) ~= "table" or type(params.session_id) ~= "string" then
    return typed_error("Validation", "InvalidRequest", "missing session_id")
  end
  local sess = self.sessions[params.session_id]
  if not sess then
    return typed_error("NotFound", "NotFound", "session does not exist")
  end
  local role = params.attach_role
  if role ~= "controller" and role ~= "observer" then
    return typed_error("Validation", "InvalidRequest", "attach_role must be controller or observer")
  end
  if role == "controller" then
    if type(params.expected_generation) ~= "number" then
      return typed_error("Validation", "InvalidRequest", "missing expected_generation")
    end
    if not self:_session_visible(conn, sess, params.control_token) then
      if sess.state ~= "terminated" and sess.controller_attach_id == nil then
        return typed_error("Denied", "InvalidControlToken", "invalid control_token")
      end
      return typed_error("NotFound", "NotFound", "session does not exist")
    end
    if params.expected_generation ~= sess.generation then
      return typed_error("Denied", "StaleGeneration", "expected_generation mismatch")
    end
    if sess.controller_attach_id ~= nil then
      return typed_error("Denied", "ControlHeld", "session already has an active controller")
    end
    if params.control_token ~= sess.control_token then
      return typed_error("Denied", "InvalidControlToken", "control_token mismatch")
    end
    local attach_id = self:_mint_id()
    local next_token = self:_mint_token()
    local expires = self.clock_ms + self.limits.attach_lease_ttl_ms
    sess.control_token = next_token
    sess.initial_token = nil
    sess.controller_attach_id = attach_id
    sess.state_revision = sess.state_revision + 1
    sess.last_seen_ms = self.clock_ms
    sess.state_changed_ms = self.clock_ms
    sess.leases[attach_id] = {
      attach_id = attach_id,
      role = "controller",
      client_id = conn.client_id,
      expires_ms = expires,
    }
    conn.leases[attach_id] = true
    self:_record_audit("session.attach", "ok", sess)
    return typed_ok({
      attach_id = attach_id,
      role = "controller",
      lease_expires_at_ms = expires,
      control_token = next_token,
      replayed = false,
      session = self:_session_snapshot(sess),
      server_monotonic_ms = self.clock_ms,
    })
  end

  local attach_id = self:_mint_id()
  local expires = self.clock_ms + self.limits.attach_lease_ttl_ms
  sess.state_revision = sess.state_revision + 1
  sess.last_seen_ms = self.clock_ms
  sess.state_changed_ms = self.clock_ms
  sess.leases[attach_id] = {
    attach_id = attach_id,
    role = "observer",
    client_id = conn.client_id,
    expires_ms = expires,
  }
  conn.leases[attach_id] = true
  self:_record_audit("session.attach", "ok", sess)
  return typed_ok({
    attach_id = attach_id,
    role = "observer",
    lease_expires_at_ms = expires,
    replayed = false,
    session = self:_session_snapshot(sess),
    server_monotonic_ms = self.clock_ms,
  })
end

function FakeServer:_handle_detach(conn, params)
  if type(params) ~= "table" or type(params.attach_id) ~= "string" then
    return typed_error("Validation", "InvalidRequest", "missing attach_id")
  end
  local attach_id = params.attach_id
  local target = nil
  for _, sess in pairs(self.sessions) do
    if sess.leases[attach_id] ~= nil then
      target = sess
      break
    end
  end
  if not target then
    return typed_error("NotFound", "NotFound", "unknown attach_id")
  end
  local own = conn.leases[attach_id] == true
  if not own and not conn.is_operator then
    if params.control_token ~= target.control_token then
      return typed_error("Denied", "InvalidControlToken", "invalid control_token")
    end
  end
  target.leases[attach_id] = nil
  conn.leases[attach_id] = nil
  if target.controller_attach_id == attach_id then
    target.controller_attach_id = nil
  end
  target.state_revision = target.state_revision + 1
  target.state_changed_ms = self.clock_ms
  self:_record_audit("session.detach", "ok", target)
  return typed_ok({
    session = self:_session_snapshot(target),
    attach_id = attach_id,
    was_attached = true,
    not_attached = false,
    revoked = not own,
  })
end

function FakeServer:_handle_status(conn, params)
  if type(params) ~= "table" or type(params.session_id) ~= "string" then
    return typed_error("Validation", "InvalidRequest", "missing session_id")
  end
  local sess = self.sessions[params.session_id]
  if not sess or not self:_session_visible(conn, sess, params.control_token) then
    return typed_error("NotFound", "NotFound", "session does not exist")
  end
  self:_record_audit("session.status", "ok", sess)
  return typed_ok({
    session = self:_session_snapshot(sess),
  })
end

function FakeServer:_handle_list(conn)
  local list = {}
  for _, sess in pairs(self.sessions) do
    if self:_session_visible(conn, sess, nil) then
      list[#list + 1] = self:_session_snapshot(sess)
    end
  end
  self:_record_audit("session.list", "ok", nil)
  return typed_ok({ sessions = list })
end

function FakeServer:_handle_heartbeat(conn, params)
  if type(params) ~= "table" or type(params.attach_id) ~= "string" then
    return typed_error("Validation", "InvalidRequest", "missing attach_id")
  end
  local attach_id = params.attach_id
  if not conn.leases[attach_id] then
    return typed_error("NotFound", "NotFound", "unknown attach_id")
  end
  for _, sess in pairs(self.sessions) do
    local lease = sess.leases[attach_id]
    if lease and lease.expires_ms > self.clock_ms then
      lease.expires_ms = self.clock_ms + self.limits.attach_lease_ttl_ms
      sess.last_seen_ms = self.clock_ms
      self:_record_audit("lease.heartbeat", "ok", sess)
      return typed_ok({
        session = self:_session_snapshot(sess),
        attach_id = attach_id,
        lease_expires_at_ms = lease.expires_ms,
        server_monotonic_ms = self.clock_ms,
      })
    end
  end
  return typed_error("NotFound", "NotFound", "expired attach_id")
end

local REASON_MAP = {
  cancel = "consumer_cancel",
  timeout = "consumer_timeout",
  operator = "operator_abort",
}

local function resolve_generation(params)
  local gen = params.generation
  local alias = params.expected_generation
  if gen ~= nil and alias ~= nil and gen ~= alias then
    return nil
  end
  local chosen = gen ~= nil and gen or alias
  if type(chosen) ~= "number" or chosen < 0 then
    return nil
  end
  return chosen
end

function FakeServer:_handle_abort(conn, params)
  if type(params) ~= "table" or type(params.session_id) ~= "string" then
    return typed_error("Validation", "InvalidRequest", "missing session_id")
  end
  if has_forbidden_wire_field(params) then
    return typed_error("Validation", "InvalidRequest", "abort request must not carry pid or signal")
  end
  local gen = resolve_generation(params)
  if gen == nil then
    return typed_error("Validation", "InvalidRequest", "missing generation")
  end
  local sess = self.sessions[params.session_id]
  if not sess then
    return typed_error("NotFound", "NotFound", "session does not exist")
  end
  if not self:_session_visible(conn, sess, params.control_token) then
    if sess.state ~= "terminated" and sess.controller_attach_id == nil then
      return typed_error("Denied", "InvalidControlToken", "invalid control_token")
    end
    return typed_error("NotFound", "NotFound", "session does not exist")
  end
  if sess.state == "terminated" then
    self:_record_audit("session.abort", "ok", sess)
    return typed_ok({
      session = self:_session_snapshot(sess),
      accepted = false,
      not_running = true,
    })
  end
  if gen ~= sess.generation then
    return typed_error("Denied", "StaleGeneration", "generation mismatch")
  end
  local terminal_reason = REASON_MAP[params.reason_class]
  if not terminal_reason then
    return typed_error("Validation", "InvalidRequest", "unsupported abort reason_class")
  end
  if params.reason_class == "operator" and not conn.is_operator then
    return typed_error("Denied", "ScopeViolation", "daemon.control required for operator abort")
  end
  if not conn.is_operator then
    local holds_controller = sess.controller_attach_id ~= nil and conn.leases[sess.controller_attach_id] == true
    if not holds_controller and params.control_token ~= sess.control_token then
      return typed_error("Denied", "InvalidControlToken", "control_token mismatch")
    end
  end
  for aid, _ in pairs(sess.leases) do
    sess.leases[aid] = nil
    sess.state_revision = sess.state_revision + 1
    for _, c in pairs(self.connections) do
      c.leases[aid] = nil
    end
  end
  sess.controller_attach_id = nil
  sess.initial_token = nil
  sess.state = "terminated"
  sess.terminal_reason = terminal_reason
  sess.cleanup = sess.generation > 0 and "swept" or "not_started"
  sess.terminalized_ms = self.clock_ms
  sess.state_revision = sess.state_revision + 1
  sess.state_changed_ms = self.clock_ms
  sess.last_seen_ms = self.clock_ms
  self:_record_audit("session.abort", "ok", sess)
  return typed_ok({
    session = self:_session_snapshot(sess),
    accepted = true,
    reason = terminal_reason,
    stage = "not_started",
    cleanup = sess.cleanup,
  })
end

-- ---------------------------------------------------------------------------
-- Consumer Adapter (`WheelBittydAdapter`)
-- ---------------------------------------------------------------------------

local Adapter = {}
Adapter.__index = Adapter

function M.new_adapter(opts)
  opts = opts or {}
  local mode = opts.mode or M.TRANSPORT_BITTYD
  if mode ~= M.TRANSPORT_IN_PROCESS and mode ~= M.TRANSPORT_BITTYD then
    error("invalid transport mode: " .. tostring(mode), 0)
  end
  return setmetatable({
    mode = mode,
    transport = opts.transport,
    connection_name = opts.connection_name or "client",
    client_version = opts.client_version or {
      major = M.SUPPORTED_MAJOR,
      minor = M.SUPPORTED_MINOR,
    },
    enforce_version_gate = opts.enforce_version_gate ~= false,
    allow_operator_stop = opts.allow_operator_stop == true,
    policy_gate = opts.policy_gate,
    negotiated = false,
    is_operator = false,
    closed = false,
    instance_id = nil,
    client_id = nil,
    service_api_version = nil,
    scopes = nil,
    capabilities = nil,
    limits = nil,
    sessions = {},
    hosted_runs = {},
    audit_records = {},
    audit_lines = {},
    child_processes_spawned = 0,
  }, Adapter)
end

function Adapter:audit_text()
  return table.concat(self.audit_lines, "\n")
end

function Adapter:child_process_count()
  return self.child_processes_spawned
end

function Adapter:_append_audit(action, outcome, extra)
  extra = extra or {}
  local record = {
    action = action,
    outcome = outcome,
    daemon_instance_id = extra.daemon_instance_id or self.instance_id,
    client_id = extra.client_id or self.client_id,
    session_id = extra.session_id,
    generation = extra.generation,
    state_revision = extra.state_revision,
    error_code = extra.error_code,
  }
  self.audit_records[#self.audit_records + 1] = record
  self.audit_lines[#self.audit_lines + 1] = format_audit_entry(record)
end

function Adapter:_check_preconditions(action, params)
  -- R-W11: client-side version gate before opening a connection (V-30).
  if self.enforce_version_gate then
    local ver = self.client_version
    if
      type(ver) ~= "table"
      or ver.major ~= M.SUPPORTED_MAJOR
      or type(ver.minor) ~= "number"
      or ver.minor < 0
      or ver.minor > M.MAX_SERVER_MINOR
    then
      self.closed = true
      self:_append_audit(action, "refused", { error_code = "VersionMismatch" })
      return typed_error("Validation", "VersionMismatch", "adapter refuses unsupported protocol version")
    end
  end
  -- R-W10: Wheel role/consent/policy gate runs before reaching transport (V-30).
  if type(self.policy_gate) == "function" then
    local allowed, code, msg, close_transport = self.policy_gate(action, params, self.connection_name)
    if not allowed then
      local err_code = code or "PolicyDenied"
      self:_append_audit(action, "refused", { error_code = err_code })
      if close_transport == true then
        self.closed = true
        return { transport = "closed", refused_by_adapter = true, error_code = err_code }
      end
      return typed_error("Denied", err_code, msg or "denied by Wheel policy gate")
    end
  end
  -- R-W13: Consumer adapter never calls daemon.stop.
  if action == "daemon.stop" and not self.is_operator and not self.allow_operator_stop then
    self:_append_audit(action, "refused", { error_code = "ScopeViolation" })
    return typed_error("Denied", "ScopeViolation", "Wheel consumer adapter never calls daemon.stop")
  end
  -- R-W06 / V-32: Adapter never transmits pid or signal fields on session control requests.
  if (action == "session.abort" or action == "session.kill") and has_forbidden_wire_field(params) then
    self:_append_audit(action, "refused", { error_code = "InvalidRequest" })
    return typed_error("Validation", "InvalidRequest", "adapter refuses out-of-band pid or signal field")
  end
  -- R-W04 / V-29: If bittyd transport is selected and no server is available,
  -- return typed Unavailable without spawning a worker or falling back.
  if self.mode == M.TRANSPORT_BITTYD and self.transport == nil then
    self:_append_audit(action, "unavailable", { error_code = "Unavailable" })
    return typed_error("Unavailable", "Unavailable", "bittyd transport is not available")
  end
  return nil
end

function Adapter:_send_raw(method, params, opts)
  if type(self.transport) == "table" and type(self.transport.send_frame) == "function" then
    return self.transport:send_frame(self.connection_name, {
      method = method,
      params = params,
    }, opts)
  end
  return self.transport(self.connection_name, {
    method = method,
    params = params,
  }, opts)
end

function Adapter:_observe_reply(method, params, reply)
  if type(reply) ~= "table" then
    return
  end
  local req_sid = type(params) == "table" and type(params.session_id) == "string" and params.session_id or nil
  if reply.transport == "closed" then
    self.closed = true
    if method == "session.abort" or method == "session.kill" then
      -- R-W07 / V-31: transport loss on abort/kill records outcome_unknown until status reconciles.
      if req_sid and self.sessions[req_sid] then
        self.sessions[req_sid].outcome_unknown = true
      end
      self:_append_audit(method, "outcome_unknown", { session_id = req_sid })
    else
      self:_append_audit(method, "closed", { session_id = req_sid })
    end
    return
  end

  if reply.ok and type(reply.result) == "table" then
    local res = reply.result
    if method == "daemon.negotiate" then
      self.negotiated = true
      self.instance_id = res.daemon_instance_id or res.instance_id
      self.client_id = res.client_id
      self.service_api_version = deep_copy(res.service_api_version)
      self.scopes = deep_copy(res.scopes)
      self.capabilities = deep_copy(res.capabilities)
      self.limits = deep_copy(res.limits)
      if type(res.scopes) == "table" then
        for _, s in ipairs(res.scopes) do
          if s == "daemon.control" then
            self.is_operator = true
          end
        end
      end
      self:_append_audit(method, "ok", {
        daemon_instance_id = self.instance_id,
        client_id = self.client_id,
      })
      return
    end

    local sess = type(res.session) == "table" and res.session or nil
    if sess and type(sess.session_id) == "string" then
      local sid = sess.session_id
      local entry = self.sessions[sid] or {}
      entry.session_id = sid
      entry.terminal_id = sess.terminal_id
      entry.generation = sess.generation
      entry.state_revision = sess.state_revision
      entry.state = sess.state
      entry.terminal_reason = sess.terminal_reason
      entry.cleanup = sess.cleanup
      entry.outcome_unknown = false
      if type(res.control_token) == "string" then
        entry.control_token = res.control_token
      end
      if method == "session.attach" and type(res.attach_id) == "string" then
        entry.attach_id = res.attach_id
      elseif method == "session.detach" and res.was_attached == true then
        if entry.attach_id == res.attach_id then
          entry.attach_id = nil
        end
      elseif sess.state == "terminated" or sess.state == "exited" or sess.state == "failed" then
        entry.attach_id = nil
      end
      self.sessions[sid] = entry
      self:_append_audit(method, "ok", {
        session_id = sid,
        generation = sess.generation,
        state_revision = sess.state_revision,
      })
      return
    end

    self:_append_audit(method, "ok", { session_id = req_sid })
  else
    local code = reply.error and reply.error.code or "Error"
    self:_append_audit(method, "refused", {
      session_id = req_sid,
      error_code = code,
    })
  end
end

--- Generic RPC dispatch through the Wheel consumer adapter.
-- Every corpus and integration step can drive this method so preconditions,
-- audit scrubbing, `Unavailable` handling, and `outcome_unknown` tracking run
-- on the real Lua adapter path.
function Adapter:call(method, params, opts)
  local pre = self:_check_preconditions(method, params)
  if pre then
    return pre
  end
  local reply = self:_send_raw(method, params, opts)
  self:_observe_reply(method, params, reply)
  return reply
end

function Adapter:negotiate(opts)
  opts = opts or {}
  local params = {
    client_version = opts.client_version or self.client_version,
    host_grant = opts.host_grant,
    operator_capability = opts.operator_capability,
    client_correlation = opts.client_correlation,
    events = opts.events,
  }
  return self:call("daemon.negotiate", params)
end

function Adapter:create_session(params)
  params = params or {}
  -- R-W05: refuse dual-run when a run_id already has a live session.
  if type(params.run_id) == "string" and self.hosted_runs[params.run_id] ~= nil then
    self:_append_audit("session.create", "refused", { error_code = "DuplicateRunSession" })
    return typed_error("Conflict", "DuplicateRunSession", "run already has a hosted session")
  end
  local wire_params = {
    kind = params.kind or "terminal",
    idempotency_key = params.idempotency_key,
    terminal_id = params.terminal_id,
    argv = params.argv,
    env = params.env,
    cwd = params.cwd,
    cols = params.cols,
    rows = params.rows,
    term = params.term,
  }
  local reply = self:call("session.create", wire_params)
  if reply.ok and type(reply.result) == "table" and type(reply.result.session) == "table" then
    if type(params.run_id) == "string" then
      self.hosted_runs[params.run_id] = reply.result.session.session_id
    end
  end
  return reply
end

function Adapter:attach_session(params)
  params = params or {}
  local tracked = type(params.session_id) == "string" and self.sessions[params.session_id] or nil
  local wire_params = {
    session_id = params.session_id,
    attach_role = params.attach_role or "controller",
    expected_generation = params.expected_generation ~= nil and params.expected_generation
      or (tracked and tracked.generation or 0),
    control_token = params.control_token or (tracked and tracked.control_token or nil),
    observer_grant = params.observer_grant,
    idempotency_key = params.idempotency_key,
  }
  local reply = self:call("session.attach", wire_params)
  if reply.error and reply.error.code == "StaleGeneration" and type(params.session_id) == "string" then
    -- R-W08: refresh state on StaleGeneration and do not replay mutation.
    self:status_session({ session_id = params.session_id })
  end
  return reply
end

function Adapter:detach_session(params)
  params = params or {}
  local tracked = type(params.session_id) == "string" and self.sessions[params.session_id] or nil
  local wire_params = {
    attach_id = params.attach_id or (tracked and tracked.attach_id or nil),
    control_token = params.control_token,
  }
  return self:call("session.detach", wire_params)
end

function Adapter:status_session(params)
  params = params or {}
  local tracked = type(params.session_id) == "string" and self.sessions[params.session_id] or nil
  return self:call("session.status", {
    session_id = params.session_id,
    control_token = params.control_token or (tracked and tracked.control_token or nil),
  })
end

function Adapter:heartbeat_lease(params)
  params = params or {}
  local tracked = type(params.session_id) == "string" and self.sessions[params.session_id] or nil
  return self:call("lease.heartbeat", {
    attach_id = params.attach_id or (tracked and tracked.attach_id or nil),
  })
end

function Adapter:abort_session(params, opts)
  params = params or {}
  local tracked = type(params.session_id) == "string" and self.sessions[params.session_id] or nil
  if has_forbidden_wire_field(params) then
    self:_append_audit("session.abort", "refused", { error_code = "InvalidRequest" })
    return typed_error("Validation", "InvalidRequest", "adapter refuses out-of-band pid or signal field")
  end
  local wire_params = {
    session_id = params.session_id,
    reason_class = params.reason_class or "cancel",
    control_token = params.control_token or (tracked and tracked.control_token or nil),
    generation = params.generation ~= nil and params.generation or (tracked and tracked.generation or 0),
  }
  return self:call("session.abort", wire_params, opts)
end

return M
