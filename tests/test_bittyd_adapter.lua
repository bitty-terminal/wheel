-- tests/test_bittyd_adapter.lua
-- Unit and vector suite for `lua/wheel/bittyd_adapter.lua` (`wheel#108`, `CTX-0036`).

package.path = "./lua/?.lua;./lua/?/init.lua;" .. package.path

local AdapterMod = require("wheel.bittyd_adapter")
local WheelContext = require("wheel.context")

local checks = 0
local function check(cond, msg)
  checks = checks + 1
  if not cond then
    error("bittyd_adapter test failed: " .. tostring(msg), 0)
  end
end

-- ---------------------------------------------------------------------------
-- V-29: A driver with no server returns typed Unavailable and spawns 0 children
-- ---------------------------------------------------------------------------
do
  local adapter = AdapterMod.new_adapter({
    mode = AdapterMod.TRANSPORT_BITTYD,
    transport = nil,
  })
  local create_res = adapter:create_session({
    kind = "terminal",
    idempotency_key = "v29-create",
  })
  check(create_res.ok == false, "V-29 create must fail when daemon is absent")
  check(create_res.error and create_res.error.class == "Unavailable", "V-29 create error_class Unavailable")
  check(create_res.error and create_res.error.code == "Unavailable", "V-29 create error_code Unavailable")

  local status_res = adapter:status_session({
    session_id = "44444444444444444444444444444444",
  })
  check(status_res.ok == false, "V-29 status must fail when daemon is absent")
  check(status_res.error and status_res.error.class == "Unavailable", "V-29 status error_class Unavailable")
  check(status_res.error and status_res.error.code == "Unavailable", "V-29 status error_code Unavailable")
  check(adapter:child_process_count() == 0, "V-29 adapter must not spawn child processes when daemon is absent")
end

-- ---------------------------------------------------------------------------
-- V-30: Idle or refused adapter calls send no connection or frame to the daemon
-- ---------------------------------------------------------------------------
do
  local server = AdapterMod.new_fake_server({ host_grant = false })
  local idle_adapter = AdapterMod.new_adapter({
    mode = AdapterMod.TRANSPORT_BITTYD,
    transport = server,
  })
  check(idle_adapter ~= nil, "V-30 idle adapter constructed")
  check(server.connection_count == 0, "V-30 idle adapter opens 0 connections")
  check(#server:request_log() == 0, "V-30 idle adapter sends 0 requests")

  -- Version gate refusal before transport
  local bad_ver_adapter = AdapterMod.new_adapter({
    mode = AdapterMod.TRANSPORT_BITTYD,
    transport = server,
    client_version = { major = 2, minor = 0 },
  })
  local ver_refusal = bad_ver_adapter:negotiate()
  check(
    ver_refusal.ok == false
      and ver_refusal.error.class == "Validation"
      and ver_refusal.error.code == "VersionMismatch",
    "V-30 unsupported client version refused by adapter with Validation/VersionMismatch"
  )
  check(
    server.connection_count == 0 and #server:request_log() == 0,
    "V-30 adapter version refusal sends no connection to daemon"
  )

  -- Policy gate refusal before transport
  local policy_adapter = AdapterMod.new_adapter({
    mode = AdapterMod.TRANSPORT_BITTYD,
    transport = server,
    policy_gate = function()
      return false, "ConsentRequired", "user consent not granted"
    end,
  })
  local pol_refusal = policy_adapter:create_session({ kind = "terminal", idempotency_key = "v30-denied" })
  check(
    pol_refusal.ok == false and pol_refusal.error.code == "ConsentRequired",
    "V-30 policy gate refuses before transport"
  )
  check(
    server.connection_count == 0 and #server:request_log() == 0,
    "V-30 policy refusal sends no connection to daemon"
  )

  -- R-W13: consumer adapter refuses daemon.stop before transport
  local stop_refusal = idle_adapter:call("daemon.stop", { mode = "refuse" })
  check(
    stop_refusal.ok == false and stop_refusal.error.code == "ScopeViolation",
    "R-W13 consumer adapter refuses daemon.stop before transport"
  )
  check(
    server.connection_count == 0 and #server:request_log() == 0,
    "R-W13 daemon.stop refusal sends no connection to daemon"
  )

  -- Operator verifies daemon is running with 0 active sessions
  local op_neg = server:send_frame("operator", {
    method = "daemon.negotiate",
    params = {
      client_version = { major = 1, minor = 0 },
      operator_capability = server.operator_capability,
    },
  })
  check(op_neg.ok == true, "V-30 operator negotiate succeeds")
  local op_stat = server:send_frame("operator", {
    method = "daemon.status",
    params = nil,
  })
  check(op_stat.ok == true and op_stat.result.daemon_state == "running", "V-30 daemon_state is running")
  check(op_stat.result.active_sessions == 0, "V-30 active_sessions is 0")
end

-- ---------------------------------------------------------------------------
-- V-31: Dropped abort marks outcome_unknown and reconciles idempotently
-- ---------------------------------------------------------------------------
do
  local server = AdapterMod.new_fake_server({ host_grant = true })
  local creator = AdapterMod.new_adapter({
    mode = AdapterMod.TRANSPORT_BITTYD,
    transport = server,
    connection_name = "creator",
  })
  local neg = creator:negotiate({ host_grant = server.host_grant })
  check(neg.ok == true, "V-31 negotiate ok")
  check(creator.instance_id == server.instance_id, "V-31 adapter captures daemon_instance_id")

  local created = creator:create_session({
    kind = "terminal",
    idempotency_key = "v31-create",
  })
  check(created.ok == true, "V-31 create ok")
  local sid = created.result.session.session_id
  local create_token = created.result.control_token
  check(AdapterMod.is_hex_of_len(sid, 32), "V-31 session_id is 32 hex")
  check(AdapterMod.is_hex_of_len(create_token, 64), "V-31 control_token is 64 hex")

  local attached = creator:attach_session({
    session_id = sid,
    attach_role = "controller",
    expected_generation = 0,
    control_token = create_token,
    idempotency_key = "v31-claim",
  })
  check(attached.ok == true and attached.result.role == "controller", "V-31 controller attach ok")
  local controller_token = attached.result.control_token

  local dropped = creator:abort_session({
    session_id = sid,
    reason_class = "cancel",
    control_token = controller_token,
    generation = 0,
  }, { fault = "drop_before_reply" })
  check(dropped.transport == "closed", "V-31 dropped abort returns transport closed")
  check(creator.sessions[sid].outcome_unknown == true, "V-31 adapter marks outcome_unknown on transport drop")

  local operator = AdapterMod.new_adapter({
    mode = AdapterMod.TRANSPORT_BITTYD,
    transport = server,
    connection_name = "operator",
  })
  check(
    operator:negotiate({ operator_capability = server.operator_capability }).ok == true,
    "V-31 operator negotiate ok"
  )
  local reconciled = operator:status_session({ session_id = sid })
  check(reconciled.ok == true, "V-31 operator status ok")
  check(reconciled.result.session.state == "terminated", "V-31 session is terminated")
  check(reconciled.result.session.terminal_reason == "consumer_cancel", "V-31 terminal_reason is consumer_cancel")
  check(reconciled.result.session.cleanup == "not_started", "V-31 cleanup is not_started")
  local terminal_rev = reconciled.result.session.state_revision

  local second_abort = operator:abort_session({
    session_id = sid,
    reason_class = "operator",
    generation = 0,
  })
  check(second_abort.ok == true, "V-31 second abort returns ok envelope")
  check(
    second_abort.result.accepted == false and second_abort.result.not_running == true,
    "V-31 second abort is not applied twice"
  )
  check(
    second_abort.result.session.state_revision == terminal_rev,
    "V-31 terminal revision does not advance on duplicate abort"
  )
end

-- ---------------------------------------------------------------------------
-- V-32 & V-33: Request log has no pid field; audit carries identity, never tokens
-- ---------------------------------------------------------------------------
do
  local server = AdapterMod.new_fake_server({ host_grant = true })
  local creator = AdapterMod.new_adapter({
    mode = AdapterMod.TRANSPORT_BITTYD,
    transport = server,
    connection_name = "creator",
  })
  check(creator:negotiate({ host_grant = server.host_grant }).ok == true, "V-32/V-33 negotiate ok")
  local created = creator:create_session({
    kind = "terminal",
    idempotency_key = "v33-create",
    run_id = "run-1",
  })
  check(created.ok == true, "V-32/V-33 create ok")
  local sid = created.result.session.session_id
  local create_token = created.result.control_token

  -- R-W05: dual-run refusal for same run_id
  local dup_run = creator:create_session({
    kind = "terminal",
    idempotency_key = "v33-dup-run",
    run_id = "run-1",
  })
  check(
    dup_run.ok == false and dup_run.error.code == "DuplicateRunSession",
    "R-W05 adapter refuses second session for same run_id"
  )

  -- R-W06: explicit pid/signal on abort is refused before wire transmission
  local bad_abort = creator:abort_session({
    session_id = sid,
    reason_class = "cancel",
    generation = 0,
    pid = 12345,
  })
  check(
    bad_abort.ok == false and bad_abort.error.code == "InvalidRequest",
    "R-W06 adapter refuses abort carrying out-of-band pid"
  )

  local attached = creator:attach_session({
    session_id = sid,
    attach_role = "controller",
    expected_generation = 0,
    control_token = create_token,
    idempotency_key = "v32-claim",
  })
  check(attached.ok == true, "V-32 attach ok")

  local aborted = creator:abort_session({
    session_id = sid,
    reason_class = "cancel",
    generation = 0,
  })
  check(
    aborted.ok == true and aborted.result.accepted == true and aborted.result.reason == "consumer_cancel",
    "V-32 abort accepted"
  )

  -- V-32 request_log verification
  local reqs = server:request_log()
  local abort_count = 0
  for _, req in ipairs(reqs) do
    if req.method == "session.abort" then
      abort_count = abort_count + 1
    end
    if type(req.params) == "table" then
      check(req.params.pid == nil and req.params.signal == nil, "V-32 no request carries pid or signal")
    end
  end
  check(abort_count == 1, "V-32 exactly one session.abort request sent")

  -- V-33 audit verification on both adapter and fake server
  local adapter_audit = creator:audit_text()
  local server_audit = server:audit_text()
  check(
    adapter_audit:find("a=session.create r=ok", 1, true) ~= nil,
    "V-33 adapter audit contains 'a=session.create r=ok'"
  )
  check(
    adapter_audit:find("inst=" .. server.instance_id, 1, true) ~= nil,
    "V-33 adapter audit records daemon_instance_id"
  )
  check(
    adapter_audit:find("client=" .. creator.client_id, 1, true) ~= nil,
    "V-33 adapter audit records client_id"
  )
  check(adapter_audit:find("sid=" .. sid, 1, true) ~= nil, "V-33 adapter audit records session_id")
  check(adapter_audit:find(create_token, 1, true) == nil, "V-33 adapter audit never contains control_token")
  check(
    adapter_audit:find(server.operator_capability, 1, true) == nil,
    "V-33 adapter audit never contains operator_capability"
  )
  check(adapter_audit:find(server.host_grant, 1, true) == nil, "V-33 adapter audit never contains host_grant")
  check(
    server_audit:find("a=session.create r=ok", 1, true) ~= nil,
    "V-33 server audit contains 'a=session.create r=ok'"
  )
  check(server_audit:find(create_token, 1, true) == nil, "V-33 server audit never contains control_token")
end

-- ---------------------------------------------------------------------------
-- R-W02: WheelContext state is independent of transport and survives detach/reattach
-- ---------------------------------------------------------------------------
do
  local ctx = WheelContext.new()
  local put_res = assert(ctx:put_slot("plan.md", "# Architecture Plan\nStep 1: Adapter"))
  local pre_tree = ctx:tree_hash()

  local server = AdapterMod.new_fake_server({ host_grant = true })
  local adapter = AdapterMod.new_adapter({
    mode = AdapterMod.TRANSPORT_BITTYD,
    transport = server,
  })
  assert(adapter:negotiate({ host_grant = server.host_grant }).ok)
  local created = assert(adapter:create_session({ kind = "terminal", idempotency_key = "rw02-create" }))
  local sid = created.result.session.session_id
  local attached = assert(adapter:attach_session({
    session_id = sid,
    attach_role = "controller",
    expected_generation = 0,
    control_token = created.result.control_token,
  }))
  check(attached.ok == true, "R-W02 initial attach ok")

  local hb = assert(adapter:heartbeat_lease({ session_id = sid }))
  check(hb.ok == true and type(hb.result.lease_expires_at_ms) == "number", "R-W02 lease heartbeat ok")

  local detached = assert(adapter:detach_session({ session_id = sid }))
  check(detached.ok == true and detached.result.was_attached == true, "R-W02 detach ok")

  local reattached = assert(adapter:attach_session({
    session_id = sid,
    attach_role = "controller",
    expected_generation = 0,
    control_token = attached.result.control_token,
  }))
  check(reattached.ok == true and reattached.result.role == "controller", "R-W02 reattach ok")

  -- Expire session after abort + retention TTL; WheelContext must remain intact
  assert(adapter:abort_session({
    session_id = sid,
    reason_class = "timeout",
    control_token = reattached.result.control_token,
    generation = 0,
  }).ok)
  server:advance_clock(server.limits.terminal_retention_ms + 1)
  local expired_status = adapter:status_session({ session_id = sid })
  check(
    expired_status.ok == false and expired_status.error.code == "NotFound",
    "R-W02 session record collected after terminal_retention_ms"
  )

  local slot = ctx:get_slot("plan.md")
  check(
    slot and slot.found and slot.hash == put_res.hash and ctx:tree_hash() == pre_tree,
    "R-W02 WheelContext state survives detach, reattach, and session expiration unchanged"
  )
end

print(string.format("[PASS] test_bittyd_adapter: %d assertions passed", checks))
