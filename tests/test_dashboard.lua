-- Agent Dashboard and bidirectional collaboration control-plane tests
-- (CTX-0050 / wheel#117).
--
-- Verifies that:
-- 1. Dashboard inspection exposes separate fields for Agent ID, RoleBinding,
--    AgentSession, Panel, Task, ContextBranch, ContextHead, provider status,
--    and lifecycle state without collapsing any pair into one identifier.
-- 2. Selecting an Agent projects its structured Context view (project, team,
--    task, session, semantic delta, omitted references, provenance) without
--    scraping unstructured text.
-- 3. Bidirectional collaboration controls (`ask_agent`, `request_clarification`,
--    `share_context`, `reply_request`, `respond_handoff`) persist durable
--    records in `collaboration/requests/<id>` anchored in immutable
--    `ContextCommit`s and reference Context by commit hash rather than copying
--    transcripts.
-- 4. Explicit Dashboard actions (`checkpoint`, `branch`, `fork`, `pause`,
--    `resume`, `attach`, `detach`, `cancel`) route through `RoleBinding`,
--    capability grants, audit, and lifecycle session/generation fencing;
--    mutating the Dashboard projection never mutates authoritative state.
-- 5. Bounded diagnostics and raw-output `blob_hash` references never dump
--    unbounded logs into the Dashboard view.

local WheelAgent = require("wheel.agent")
local WheelAudit = require("wheel.audit")
local WheelContext = require("wheel.context")
local WheelKernel = require("wheel.kernel")
local WheelLifecycle = require("wheel.lifecycle")
local WheelTeam = require("wheel.team")
local WheelUI = require("wheel.ui")

local function is_hex_hash(value)
  return type(value) == "string" and #value == 64 and value:match("^[0-9a-f]+$") ~= nil
end

local function make_dashboard_fixture()
  local kernel = WheelKernel.new({ in_memory = true })
  local context = WheelContext.new({ kernel = kernel })
  local lifecycle = WheelLifecycle.new({ in_memory = true })
  local audit = WheelAudit.new({ in_memory = true })

  assert(context:put_slot("workspace/overview", "Wheel Agent Harness architecture"))
  assert(context:put_slot("decisions/ADR-117", "Dashboard is a projection + control surface"))
  local initial_commit = assert(context:commit_checkpoint({
    author = "fixture",
    message = "initial workspace context",
    timestamp_ms = 1700000000000,
  }))

  local team = WheelTeam.new({
    kernel = kernel,
    context = context,
    lifecycle = lifecycle,
    audit = audit,
  })

  local commander = team:spawn_agent({
    name = "commander",
    role = WheelAgent.Role.COMMANDER,
    panel_id = "panel:commander",
  })
  local commander_session = assert(commander:create_runtime_session({
    panel_id = "panel:commander",
  }))
  assert(lifecycle:activate_session(commander_session.session_id))

  local coder = team:spawn_agent({
    name = "coder",
    role = WheelAgent.Role.CODING,
    panel_id = "panel:coder",
  })
  local reviewer = team:spawn_agent({
    name = "reviewer",
    role = WheelAgent.Role.REVIEWER,
    panel_id = "panel:reviewer",
  })
  local reviewer_session = assert(reviewer:create_runtime_session({
    task_id = "TASK-117",
    panel_id = "panel:reviewer",
  }))
  assert(lifecycle:activate_session(reviewer_session.session_id))

  kernel:create_task({
    id = "TASK-117",
    title = "Implement Agent Dashboard",
    priority = 10,
  })
  assert(context:put_slot("tasks/TASK-117/spec", "Structured inspection and controls"))
  local coder_task_session = assert(coder:create_runtime_session({
    task_id = "TASK-117",
    panel_id = "panel:coder-task-117",
  }))
  assert(lifecycle:activate_session(coder_task_session.session_id))
  assert(team:claim_task("coder", "TASK-117"))
  local claim_commit = assert(context:commit_checkpoint({
    author = "coder",
    task_id = "TASK-117",
    message = "claimed TASK-117",
    timestamp_ms = 1700000001000,
  }))

  return {
    team = team,
    kernel = kernel,
    context = context,
    lifecycle = lifecycle,
    audit = audit,
    commander = commander,
    coder = coder,
    reviewer = reviewer,
    coder_task_session = coder_task_session,
    reviewer_session = reviewer_session,
    initial_commit = initial_commit,
    claim_commit = claim_commit,
  }
end

return function(run_test)
  run_test("Dashboard: selecting an Agent inspects separate identity/session/panel/task/context fields and structured Context layers", function()
    local fx = make_dashboard_fixture()
    local team = fx.team

    local selected, sel_err = team:select_agent("coder", {
      base_commit = fx.initial_commit.hash,
      current_commit = fx.claim_commit.hash,
    })
    assert(selected ~= nil, "select_agent must succeed: " .. tostring(sel_err and sel_err.message))
    assert(selected.schema == WheelTeam.DASHBOARD_PROTOCOL)
    assert(selected.presentation_only == true)
    assert(selected.authority_bearing == false)

    -- Verify all required distinct fields on the inspected Agent card.
    assert(selected.name == "coder")
    assert(type(selected.agent_id) == "string" and #selected.agent_id > 0)
    assert(type(selected.role_binding) == "table")
    assert(selected.role_binding.role == WheelAgent.Role.CODING)
    assert(selected.role_binding.policy_generation == 1)
    assert(type(selected.role_binding.binding_id) == "string")
    assert(selected.role_binding.binding_id ~= selected.agent_id)

    assert(type(selected.agent_session) == "table")
    assert(type(selected.agent_session.session_id) == "string")
    assert(selected.agent_session.session_id ~= selected.agent_id)
    assert(selected.agent_session.session_id ~= selected.role_binding.binding_id)

    assert(type(selected.panel) == "table")
    assert(selected.panel.panel_id == "panel:coder-task-117")
    assert(selected.panel.panel_id ~= selected.agent_session.session_id)

    assert(type(selected.task) == "table")
    assert(selected.task.task_id == "TASK-117")
    assert(selected.task.generation == 1)

    assert(selected.context_branch == "main")
    assert(selected.context_head == fx.claim_commit.hash)

    assert(type(selected.provider_status) == "table")
    assert(type(selected.provider_status.model) == "string" and #selected.provider_status.model > 0)

    assert(type(selected.lifecycle_state) == "table")
    assert(selected.lifecycle_state.team_state == "busy")
    assert(selected.lifecycle_state.session_state == "active")

    -- Verify structured Context projection (project, team, task, session, delta, provenance)
    local cp = selected.context_projection
    assert(type(cp) == "table", "context_projection must be populated")
    assert(cp.read_only == true and cp.authority_bearing == false)
    assert(type(cp.project) == "table" and cp.project.scope == "project")
    assert(type(cp.team) == "table" and cp.team.scope == "team")
    assert(type(cp.task) == "table" and cp.task.scope == "task" and cp.task.task_id == "TASK-117")
    assert(type(cp.session) == "table" and cp.session.scope == "session")
    assert(type(cp.delta) == "table" and cp.delta.scope == "delta")
    assert(type(cp.layers) == "table")
    assert(type(cp.omitted_references) == "table")
    assert(type(cp.provenance) == "table")

    -- Mutating the returned Dashboard inspection must never mutate authoritative state.
    selected.role_binding.role = "commander"
    selected.task.task_id = "FORGED-TASK"
    selected.context_branch = "forged-branch"
    cp.project.scope = "forged"

    local fresh = assert(team:inspect_agent("coder"))
    assert(fresh.role_binding.role == WheelAgent.Role.CODING)
    assert(fresh.task.task_id == "TASK-117")
    assert(fresh.context_branch == "main")
    assert(fresh.context_projection.project.scope == "project")
  end)

  run_test("Dashboard: bidirectional collaboration controls persist durable request/reply records and reference Context by commit hash", function()
    local fx = make_dashboard_fixture()
    local team = fx.team
    local context = fx.context

    -- 1. Ask an Agent a question (`ask_agent`) and reply (`reply_request`).
    local asked, ask_err = team:ask_agent("coder", "Is the Context projection deterministic?", {
      from = "commander",
      task_id = "TASK-117",
      context_ref = fx.claim_commit.hash,
    })
    assert(asked ~= nil, "ask_agent must succeed: " .. tostring(ask_err and ask_err.message))
    assert(asked.kind == WheelTeam.CollaborationKind.ASK)
    assert(asked.status == "pending")
    assert(asked.from == "commander" and asked.to == "coder")
    assert(asked.context_ref == fx.claim_commit.hash)
    assert(is_hex_hash(asked.checkpoint_hash))

    -- Non-recipient cannot reply.
    local bad_reply, bad_reply_err = team:reply_request(asked.request_id, "Unauthorized answer", {
      responder = "reviewer",
    })
    assert(bad_reply == nil and bad_reply_err.code == "E_DASHBOARD_AUTHORITY")

    -- Recipient replies and anchors reply in a new immutable ContextCommit.
    local answered, ans_err = team:reply_request(asked.request_id, "Yes, keys are sorted canonically.", {
      responder = "coder",
      context_ref = fx.claim_commit.hash,
    })
    assert(answered ~= nil, "reply_request must succeed: " .. tostring(ans_err and ans_err.message))
    assert(answered.status == "replied")
    assert(type(answered.reply) == "table")
    assert(answered.reply.content == "Yes, keys are sorted canonically.")
    assert(answered.reply.responder == "coder")
    assert(is_hex_hash(answered.checkpoint_hash))
    assert(answered.checkpoint_hash ~= asked.checkpoint_hash)

    -- Re-replying to an already resolved request fails closed.
    local dup_reply, dup_err = team:reply_request(asked.request_id, "Second reply", {
      responder = "coder",
    })
    assert(dup_reply == nil and dup_err.code == "E_DASHBOARD_STATE")

    -- 2. Request clarification (`request_clarification`).
    local clar, clar_err = team:request_clarification(
      "coder",
      "commander",
      "Should cancel require explicit task_id when the Agent has a single active task?",
      { task_id = "TASK-117" }
    )
    assert(clar ~= nil, "request_clarification must succeed: " .. tostring(clar_err and clar_err.message))
    assert(clar.kind == WheelTeam.CollaborationKind.CLARIFICATION)
    assert(clar.status == "pending")

    -- 3. Share context by immutable reference (`share_context`) without copying transcripts.
    local bogus_share, bogus_err = team:share_context("coder", "reviewer", {
      context_ref = "not-a-commit-hash",
      message = "invalid ref",
    })
    assert(bogus_share == nil and bogus_err.code == "E_DASHBOARD_CONTEXT_REF",
      "share_context must reject unknown or mutable context references")

    local shared, share_err = team:share_context("coder", "reviewer", {
      task_id = "TASK-117",
      context_ref = fx.claim_commit.hash,
      slot_refs = { "tasks/TASK-117/spec" },
      message = "Ready for review at claim commit",
    })
    assert(shared ~= nil, "share_context must succeed: " .. tostring(share_err and share_err.message))
    assert(shared.kind == WheelTeam.CollaborationKind.CONTEXT_SHARE)
    assert(shared.context_ref == fx.claim_commit.hash)
    assert(shared.slot_refs[1] == "tasks/TASK-117/spec")
    assert(is_hex_hash(shared.checkpoint_hash))

    -- Verify requests are durable in Context slots (`collaboration/requests/<id>`) and filterable.
    local open_for_commander = team:list_requests({ agent_name = "commander", status = "pending" })
    assert(#open_for_commander == 1 and open_for_commander[1].request_id == clar.request_id)
    local slot = context:get_slot("collaboration/requests/" .. asked.request_id)
    assert(slot.found == true)

    -- 4. Offer a deferred handoff and accept/decline via `respond_handoff`.
    local reviewer_sess = fx.reviewer_session
    local ho_cp = assert(context:commit_checkpoint({
      author = "coder",
      task_id = "TASK-117",
      message = "handoff base checkpoint",
    }))

    local ho_ok, offer = team:handoff("coder", "reviewer", "TASK-117", {
      defer_accept = true,
      source_session_id = fx.coder_task_session.session_id,
      target_session_id = reviewer_sess.session_id,
      checkpoint_hash = ho_cp.hash,
      rationale = "Handing off Dashboard implementation for review",
    })
    assert(ho_ok == true and offer.state == "offered")

    -- Wrong agent cannot accept handoff through respond_handoff.
    local wrong_ho = team:respond_handoff(offer.handoff_id, "accept", {
      agent_name = "commander",
      session_id = fx.commander:runtime_session_id(),
    })
    assert(wrong_ho == nil)

    -- Target agent accepts handoff with live session authority.
    local acc_rec, acc_err = team:respond_handoff(offer.handoff_id, "accept", {
      agent_name = "reviewer",
      session_id = reviewer_sess.session_id,
    })
    assert(acc_rec ~= nil, "respond_handoff must succeed: " .. tostring(acc_err and acc_err.message))
    assert(acc_rec.state == "accepted")
    assert(fx.kernel:get_task("TASK-117").worker_id == "reviewer")
  end)

  run_test("Dashboard: explicit lifecycle/context actions enforce RoleBinding, capabilities, audit, and generation fencing", function()
    local fx = make_dashboard_fixture()
    local team = fx.team

    -- 1. Checkpoint action through dashboard_action.
    local cp_res, cp_err = team:dashboard_action("checkpoint", {
      agent_name = "coder",
      message = "dashboard checkpoint",
    })
    assert(cp_res ~= nil, "checkpoint action must succeed: " .. tostring(cp_err and cp_err.message))
    assert(is_hex_hash(cp_res.checkpoint_hash))

    -- 2. Branch action: reviewer lacks MODIFY/ORCHESTRATE capability and must be denied.
    local rev_branch, rev_branch_err = team:dashboard_action("branch", {
      agent_name = "reviewer",
      branch_name = "reviewer-branch",
    })
    assert(rev_branch == nil and rev_branch_err.code == "E_DASHBOARD_AUTHORITY",
      "reviewer must not be able to create a Context branch")

    -- Forged RoleBinding or mismatched policy_generation on dashboard_action fails closed.
    local forged_branch, forged_err = team:dashboard_action("branch", {
      agent_name = "coder",
      branch_name = "forged-branch",
      policy_generation = 99,
    })
    assert(forged_branch == nil and forged_err.code == "E_DASHBOARD_AUTHORITY")

    -- Coding agent has MODIFY capability and can create/switch a Context branch.
    local br_res, br_err = team:dashboard_action("branch", {
      agent_name = "coder",
      branch_name = "feat/dashboard-ui",
      start_point = cp_res.checkpoint_hash,
      checkout = true,
    })
    assert(br_res ~= nil, "coder branch action must succeed: " .. tostring(br_err and br_err.message))
    assert(br_res.current_branch == "feat/dashboard-ui")

    -- 3. Fork action: creates a child Agent anchored to an immutable Context commit reference.
    local fork_res, fork_err = team:dashboard_action("fork", {
      agent_name = "coder",
      name = "coder-fork",
      role = WheelAgent.Role.DEBUG,
      base_context_commit = cp_res.checkpoint_hash,
      task_id = "TASK-117",
      reason = "fork for debugging",
    })
    assert(fork_res ~= nil, "fork action must succeed: " .. tostring(fork_err and fork_err.message))
    assert(fork_res.child_name == "coder-fork")
    assert(fork_res.lineage.forked_from_agent == fx.coder.agent_id)
    assert(fork_res.lineage.base_context_commit == cp_res.checkpoint_hash)

    -- 4. Pause / Resume / Detach / Attach session controls.
    -- Mismatched session_id from another agent is rejected (`E_DASHBOARD_AUTHORITY`).
    local bad_pause, bad_pause_err = team:dashboard_action("pause", {
      agent_name = "coder",
      session_id = fx.reviewer:runtime_session_id(),
    })
    assert(bad_pause == nil and bad_pause_err.code == "E_DASHBOARD_AUTHORITY")

    local paused = assert(team:dashboard_action("pause", {
      agent_name = "coder",
    }))
    assert(paused.session.state == "paused")

    local resumed = assert(team:dashboard_action("resume", {
      agent_name = "coder",
    }))
    assert(resumed.session.state == "active")

    local detached = assert(team:dashboard_action("detach", {
      agent_name = "coder",
    }))
    assert(detached.session.state == "paused")
    assert(detached.session.attachment_mode == nil)

    local attached = assert(team:dashboard_action("attach", {
      agent_name = "coder",
      panel_id = "panel:coder-task-117",
      mode = "controller",
    }))
    assert(attached.session.panel_id == "panel:coder-task-117")
    assert(attached.session.attachment_mode == "controller")
    assert(fx.lifecycle:activate_session(attached.session.session_id))

    -- 5. Bounded cancel action enforces role capability and task generation fencing.
    local rev_cancel, rev_cancel_err = team:dashboard_action("cancel", {
      agent_name = "reviewer",
      task_id = "TASK-117",
      expected_generation = 1,
      reason = "unauthorized reviewer cancel",
    })
    assert(rev_cancel == nil and rev_cancel_err.code == "E_DASHBOARD_AUTHORITY",
      "reviewer without EXECUTE/MODIFY/ORCHESTRATE must not cancel tasks")

    local stale_cancel, stale_err = team:dashboard_action("cancel", {
      agent_name = "coder",
      task_id = "TASK-117",
      expected_generation = 999,
      reason = "stale generation test",
    })
    assert(stale_cancel == nil and stale_err.code == "E_DASHBOARD_FENCE",
      "cancel with mismatched generation must fail closed")
    assert(fx.kernel:get_task("TASK-117").status == "running")

    local cancel_res, cancel_err = team:dashboard_action("cancel", {
      agent_name = "coder",
      task_id = "TASK-117",
      expected_generation = 1,
      reason = "user requested bounded cancel from dashboard",
    })
    assert(cancel_res ~= nil, "bounded cancel must succeed: " .. tostring(cancel_err and cancel_err.message))
    assert(cancel_res.status == "cancelled")
    assert(fx.kernel:get_task("TASK-117").status == "cancelled")
    assert(team.agent_states.coder.state == "idle")
  end)

  run_test("Dashboard: bounded diagnostics truncate previews and preserve raw-output blob_hash references", function()
    local fx = make_dashboard_fixture()
    local team = fx.team
    local kernel = fx.kernel

    local huge_output = string.rep("STACKTRACE_LINE_0123456789_", 80)
    local blob_hash = WheelContext.compute_hash(huge_output)
    kernel:record_action({
      action_id = "act-117",
      tool = "command.run",
      intent = "run test suite",
      success = false,
      exit_code = 1,
      duration_ms = 42,
      truncated = true,
      spilled = true,
      size_bytes = #huge_output,
      preview = huge_output,
      blob_hash = blob_hash,
    })

    local diag = team:bounded_diagnostics({ limit = 4 })
    assert(diag.bounded == true)
    assert(diag.max_items == 4)
    assert(#diag.items >= 1)

    local found_cmd = nil
    for _, item in ipairs(diag.items) do
      if item.tool == "command.run" then
        found_cmd = item
        break
      end
    end
    assert(found_cmd ~= nil, "command.run action must appear in bounded diagnostics")
    assert(#found_cmd.preview <= diag.max_preview_bytes + 32, "preview must be bounded")
    assert(found_cmd.raw_output_ref.blob_hash == blob_hash, "raw output blob_hash reference must be preserved")
    assert(found_cmd.raw_output_ref.slot_ref == "blobs/" .. blob_hash)
    assert(found_cmd.raw_output_ref.omitted_reason == "spilled_to_blob")

    -- Host-facing UI projection & ASCII formatting test
    local view, view_err = WheelUI.build_dashboard_view(team, { selected_agent = "coder" })
    assert(view ~= nil, "WheelUI.build_dashboard_view must succeed: " .. tostring(view_err and view_err.error))
    assert(view.schema == WheelUI.DASHBOARD_SCHEMA)
    assert(view.presentation_only == true)
    assert(view.authority_bearing == false)
    assert(#view.cards == 3)

    local formatted = WheelUI.format_dashboard(team, { selected_agent = "coder" })
    assert(formatted:find("Bitty Wheel Agent Dashboard (wheel-dashboard/1)", 1, true) ~= nil)
    assert(formatted:find("role=coding@g1", 1, true) ~= nil)
    assert(formatted:find(huge_output, 1, true) == nil,
      "format_dashboard must never dump unbounded raw logs")

    local scene = WheelUI.render_dashboard_scene(team, { selected_agent = "coder" })
    assert(scene.type == "Text")
    assert(scene.metadata.schema == WheelUI.DASHBOARD_SCHEMA)
    assert(scene.metadata.selected_agent == "coder")
  end)
end
