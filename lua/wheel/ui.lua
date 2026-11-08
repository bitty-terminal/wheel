-- Wheel UI Visualizer
-- ASCII / TUI Task DAG visualizer and execution telemetry renderer.
-- Renders topological execution waves, lifecycle state badges, and multi-tier telemetry.

local WheelUI = {}

--- Status glyphs and badges for task states.
WheelUI.STATUS_BADGES = {
  ["succeeded"] = "[✓]",
  ["running"]   = "[▶]",
  ["ready"]     = "[•]",
  ["blocked"]   = "[⏸]",
  ["pending"]   = "[⏳]",
  ["failed"]    = "[✗]",
  ["cancelled"] = "[🚫]",
  ["Succeeded"] = "[✓]",
  ["Running"]   = "[▶]",
  ["Ready"]     = "[•]",
  ["Blocked"]   = "[⏸]",
  ["Pending"]   = "[⏳]",
  ["Failed"]    = "[✗]",
  ["Cancelled"] = "[🚫]",
}

--- Format kernel status and telemetry summary as a readable string.
--- @param kernel table: WheelKernel instance
--- @return string
function WheelUI.format_status(kernel)
  local status = kernel:status()
  local tasks = kernel:list_tasks()

  local counts = {
    total = #tasks,
    succeeded = 0,
    running = 0,
    ready = 0,
    blocked = 0,
    pending = 0,
    failed = 0,
    cancelled = 0,
  }

  for _, t in ipairs(tasks) do
    local s = (t.status or ""):lower()
    if counts[s] ~= nil then
      counts[s] = counts[s] + 1
    end
  end

  local lines = {
    "=======================================================",
    "  🐹 Bitty Wheel Agent Harness (bitty-terminal.wheel)   ",
    "=======================================================",
    string.format("Active Task:     %s", status.active_task or "(none)"),
    string.format("Head Checkpoint: %s", status.head_checkpoint and status.head_checkpoint:sub(1, 16) or "(none)"),
    string.format("Merkle Tree:     %s", status.tree_hash and status.tree_hash:sub(1, 16) or "(empty)"),
    string.format("Slots Count:     %d", status.slot_count or 0),
    string.format("Recent Actions:  %d", status.recent_action_count or 0),
    "-------------------------------------------------------",
    string.format("Tasks: %d total  [✓ %d | ▶ %d | • %d | ⏸ %d | ⏳ %d | ✗ %d]",
      counts.total, counts.succeeded, counts.running, counts.ready,
      counts.blocked, counts.pending, counts.failed),
    "=======================================================",
  }

  return table.concat(lines, "\n")
end

--- Calculate topological wave depths for each task.
--- Wave 1 contains tasks with zero dependencies; Wave N contains tasks whose
--- dependencies are all resolved in earlier waves: wave(u) = 1 + max(wave(v) for v in deps(u)).
--- Cycle detection is guarded via recursion stack tracking.
--- @param tasks table[]
--- @return table<string, number>, number
local function calculate_waves(tasks)
  local task_map = {}
  for _, t in ipairs(tasks) do
    task_map[t.id] = t
  end

  local depths = {}
  local in_stack = {}

  local function get_depth(id)
    if depths[id] then
      return depths[id]
    end
    if in_stack[id] then
      -- Cycle guard: break recursive loop and fallback to wave 1
      return 1
    end

    local t = task_map[id]
    local deps = (t and t.dependencies) or {}
    if #deps == 0 then
      depths[id] = 1
      return 1
    end

    in_stack[id] = true
    local max_dep = 0
    for _, dep_id in ipairs(deps) do
      local d = get_depth(dep_id)
      if d > max_dep then
        max_dep = d
      end
    end
    in_stack[id] = nil

    depths[id] = max_dep + 1
    return depths[id]
  end

  local max_wave = 1
  for _, t in ipairs(tasks) do
    local d = get_depth(t.id)
    if d > max_wave then
      max_wave = d
    end
  end

  return depths, max_wave
end

WheelUI.calculate_waves = calculate_waves

--- Render the Task DAG into an ASCII graph grouped by topological execution waves.
--- @param kernel table: WheelKernel instance
--- @return string
function WheelUI.format_graph(kernel)
  local status = kernel:status()
  local tasks = kernel:list_tasks()

  if #tasks == 0 then
    return "=======================================================\n"
        .. "  🐹 Bitty Wheel Task DAG Visualizer (empty graph)     \n"
        .. "======================================================="
  end

  local depths, max_wave = calculate_waves(tasks)
  local waves = {}
  for i = 1, max_wave do
    waves[i] = {}
  end

  for _, t in ipairs(tasks) do
    local d = depths[t.id] or 1
    table.insert(waves[d], t)
  end

  local active_id = status.active_task

  local lines = {
    "=======================================================",
    "  🐹 Bitty Wheel Task DAG Visualizer (Topological Waves)",
    "=======================================================",
    string.format("Active Task: %s | Total Tasks: %d | Head: %s",
      active_id or "(none)", #tasks,
      status.head_checkpoint and status.head_checkpoint:sub(1, 8) or "(none)"),
    "",
  }

  for wave_idx = 1, max_wave do
    local wave_tasks = waves[wave_idx]
    if #wave_tasks > 0 then
      table.insert(lines, string.format("-- Wave %d --------------------------------------------", wave_idx))
      for _, t in ipairs(wave_tasks) do
        local st = t.status or ""
        local badge = WheelUI.STATUS_BADGES[st:lower()] or WheelUI.STATUS_BADGES[st] or "[?]"
        local active_tag = (t.id == active_id) and " <-- ACTIVE" or ""
        local prio_tag = (t.priority and t.priority > 0) and string.format(" (P%d)", t.priority) or ""
        local line = string.format("  %s %s%s: %s%s", badge, t.id, prio_tag, t.title or "", active_tag)
        table.insert(lines, line)

        if t.dependencies and #t.dependencies > 0 then
          table.insert(lines, string.format("      deps: %s", table.concat(t.dependencies, ", ")))
        end
        local worker = t.assigned_agent
        if not worker or worker == "" then
          worker = t.worker_id
        end
        if worker and worker ~= "" then
          table.insert(lines, string.format("      worker: %s", worker))
        end
        if t.checkpoint then
          table.insert(lines, string.format("      cp:   %s", t.checkpoint:sub(1, 16)))
        end
        local err_msg = t.failure_reason
        if not err_msg or err_msg == "" then
          err_msg = t.error
        end
        if err_msg and err_msg ~= "" then
          table.insert(lines, string.format("      err:  %s", err_msg))
        end
      end
      table.insert(lines, "")
    end
  end

  table.insert(lines, "=======================================================")
  return table.concat(lines, "\n")
end

--- Render context compilation telemetry.
--- @param compiled table: CompiledContext returned by kernel:compile_context()
--- @return string
function WheelUI.format_telemetry(compiled)
  if not compiled then return "(no compiled context)" end
  local lines = {
    "-------------------------------------------------------",
    "  Context Compiler Telemetry                           ",
    "-------------------------------------------------------",
    string.format("Prefix Hash:   %s", compiled.prefix_hash and compiled.prefix_hash:sub(1, 16) or "(none)"),
    string.format("Total Bytes:   %d", compiled.total_bytes or 0),
    string.format("Zone 1 Prefix: %d bytes", compiled.zone1_prefix and #compiled.zone1_prefix or 0),
    string.format("Zone 2 State:  %d bytes", compiled.zone2_state and #compiled.zone2_state or 0),
    string.format("Zone 3 Tail:   %d bytes", compiled.zone3_tail and #compiled.zone3_tail or 0),
    string.format("Pruned Slots:  %d", compiled.pruned_slots or 0),
    string.format("Summarized CP: %d", compiled.summarized_checkpoints or 0),
    string.format("Tail Trunc:    %s", compiled.truncated_tail and "yes" or "no"),
    "-------------------------------------------------------",
  }
  return table.concat(lines, "\n")
end

--- Build a declarative Bitty UI scene node for mounting into a slot (e.g. "top" or "bottom").
--- @param kernel table: WheelKernel instance
--- @return table BittySceneNode
function WheelUI.render_scene_node(kernel)
  local text = WheelUI.format_graph(kernel)
  return {
    type = "Text",
    content = text,
  }
end

--- Schema version for the Agent Dashboard projection (`CTX-0050`).
WheelUI.DASHBOARD_SCHEMA = "wheel-dashboard/1"

local function clone_ui_value(value)
  if type(value) ~= "table" then
    return value
  end
  local out = {}
  for k, v in pairs(value) do
    out[clone_ui_value(k)] = clone_ui_value(v)
  end
  return out
end

--- Build a structured, non-authoritative Dashboard view from a `WheelTeam` or
--- pre-computed `dashboard_snapshot` table.
--- @param team_or_snapshot table
--- @param opts table|nil
--- @return table|nil, table|nil
function WheelUI.build_dashboard_view(team_or_snapshot, opts)
  opts = type(opts) == "table" and opts or {}
  if type(team_or_snapshot) ~= "table" then
    return nil, { error = "invalid_dashboard_source" }
  end
  local snapshot
  if type(team_or_snapshot.dashboard_snapshot) == "function" then
    local err
    snapshot, err = team_or_snapshot:dashboard_snapshot(opts)
    if not snapshot then
      return nil, err
    end
  elseif team_or_snapshot.schema == WheelUI.DASHBOARD_SCHEMA then
    snapshot = clone_ui_value(team_or_snapshot)
  else
    return nil, { error = "invalid_dashboard_source" }
  end

  local cards = {}
  local idle_count, busy_count = 0, 0
  for i = 1, #(snapshot.agents or {}) do
    local entry = snapshot.agents[i]
    local team_st = entry.lifecycle_state and entry.lifecycle_state.team_state or "idle"
    if team_st == "busy" then
      busy_count = busy_count + 1
    else
      idle_count = idle_count + 1
    end
    cards[i] = {
      name = entry.name,
      selected = entry.name == snapshot.selected_agent,
      agent_id = entry.agent_id,
      role_binding = clone_ui_value(entry.role_binding),
      agent_session = clone_ui_value(entry.agent_session),
      panel = clone_ui_value(entry.panel),
      task = clone_ui_value(entry.task),
      context_branch = clone_ui_value(entry.context_branch),
      context_head = clone_ui_value(entry.context_head),
      context_refs = clone_ui_value(entry.context_refs),
      lineage = clone_ui_value(entry.lineage),
      provider_status = clone_ui_value(entry.provider_status),
      lifecycle_state = clone_ui_value(entry.lifecycle_state),
      requests = clone_ui_value(entry.requests),
      diagnostics = clone_ui_value(entry.diagnostics),
    }
  end

  local open_requests = 0
  for _, req in ipairs(snapshot.requests or {}) do
    if req.status == "pending" then
      open_requests = open_requests + 1
    end
  end
  local pending_handoffs = 0
  for _, ho in ipairs(snapshot.handoffs or {}) do
    if ho.state == "offered" then
      pending_handoffs = pending_handoffs + 1
    end
  end

  local sel_view = snapshot.selected_view
  return {
    schema = WheelUI.DASHBOARD_SCHEMA,
    presentation_only = true,
    authority_bearing = false,
    selected_agent = snapshot.selected_agent,
    summary = {
      total_agents = #cards,
      idle_count = idle_count,
      busy_count = busy_count,
      open_requests = open_requests,
      pending_handoffs = pending_handoffs,
    },
    context_head = {
      branch = sel_view and sel_view.context_branch or "main",
      commit_hash = sel_view and sel_view.context_head or nil,
    },
    cards = cards,
    selected_view = clone_ui_value(sel_view),
    requests = clone_ui_value(snapshot.requests or {}),
    handoffs = clone_ui_value(snapshot.handoffs or {}),
    diagnostics = clone_ui_value(snapshot.diagnostics),
  }
end

--- Inspect one Agent's structured Dashboard card and Context projection.
--- @param team table
--- @param agent_name string
--- @param opts table|nil
--- @return table|nil, table|nil
function WheelUI.inspect_agent_card(team, agent_name, opts)
  if type(team) ~= "table" or type(team.inspect_agent) ~= "function" then
    return nil, { error = "invalid_team_instance" }
  end
  return team:inspect_agent(agent_name, opts)
end

--- Render a human-readable ASCII summary of the Agent Dashboard without
--- exposing unbounded raw logs (raw outputs remain referenced by `blob_hash`).
--- @param team_or_snapshot table
--- @param opts table|nil
--- @return string
function WheelUI.format_dashboard(team_or_snapshot, opts)
  local view, err = WheelUI.build_dashboard_view(team_or_snapshot, opts)
  if not view then
    return string.format("(dashboard unavailable: %s)", tostring(err and err.error or "unknown"))
  end

  local head_short = view.context_head and type(view.context_head.commit_hash) == "string"
    and view.context_head.commit_hash:sub(1, 12) or "(none)"
  local lines = {
    "=======================================================",
    "  🐹 Bitty Wheel Agent Dashboard (wheel-dashboard/1)   ",
    "=======================================================",
    string.format(
      "Agents: %d total [idle %d | busy %d] | Selected: %s",
      view.summary and view.summary.total_agents or 0,
      view.summary and view.summary.idle_count or 0,
      view.summary and view.summary.busy_count or 0,
      view.selected_agent or "(none)"
    ),
    string.format(
      "Context Head: %s (branch %s)",
      head_short,
      view.context_head and view.context_head.branch or "main"
    ),
    string.format(
      "Collaboration: %d open requests | %d pending handoffs",
      view.summary and view.summary.open_requests or 0,
      view.summary and view.summary.pending_handoffs or 0
    ),
    "-------------------------------------------------------",
  }

  for _, card in ipairs(view.cards) do
    local marker = card.selected and "*" or " "
    local role_name = card.role_binding and card.role_binding.role or "unknown"
    local role_gen = card.role_binding and card.role_binding.policy_generation or 1
    local state = card.lifecycle_state and card.lifecycle_state.session_state
      or (card.lifecycle_state and card.lifecycle_state.team_state) or "idle"
    local task_id = card.task and card.task.task_id or "(idle)"
    local panel_id = card.panel and card.panel.panel_id or "(detached)"
    local provider = card.provider_status and card.provider_status.model or "(none)"
    local branch_name = type(card.context_branch) == "string" and card.context_branch or "main"
    local commit_short = type(card.context_head) == "string"
      and card.context_head:sub(1, 12) or "(none)"
    table.insert(lines, string.format(
      "%s [%s] id=%s role=%s@g%d state=%s task=%s",
      marker,
      card.name,
      card.agent_id or "?",
      role_name,
      role_gen,
      state,
      task_id
    ))
    table.insert(lines, string.format(
      "    session=%s panel=%s branch=%s@%s model=%s",
      card.agent_session and card.agent_session.session_id or "(none)",
      panel_id,
      branch_name,
      commit_short,
      provider
    ))
  end

  if view.selected_view and view.selected_view.context_projection then
    local cp = view.selected_view.context_projection
    table.insert(lines, "-------------------------------------------------------")
    table.insert(lines, string.format(
      "Selected Context View (%s): branch=%s head=%s bytes=%d/%d",
      view.selected_agent or "?",
      cp.context_branch or "main",
      type(cp.context_head) == "string" and cp.context_head:sub(1, 12) or "(none)",
      cp.total_bytes or 0,
      cp.max_budget_bytes or 0
    ))
    table.insert(lines, string.format(
      "  Scopes: project=%d team=%d task=%d session=%d delta=%d omitted=%d",
      #(cp.project and cp.project.records or {}),
      #(cp.team and cp.team.role_lenses or {}),
      #(cp.task and cp.task.records or {}),
      #(cp.session and cp.session.records or {}),
      #(cp.delta and cp.delta.records or {}),
      #(cp.omitted_references or {})
    ))
  end

  table.insert(lines, "=======================================================")
  return table.concat(lines, "\n")
end

--- Build a declarative Bitty UI scene node for the Agent Dashboard.
--- @param team_or_snapshot table
--- @param opts table|nil
--- @return table BittySceneNode
function WheelUI.render_dashboard_scene(team_or_snapshot, opts)
  local view = WheelUI.build_dashboard_view(team_or_snapshot, opts)
  return {
    type = "Text",
    content = WheelUI.format_dashboard(view or team_or_snapshot, opts),
    metadata = {
      schema = WheelUI.DASHBOARD_SCHEMA,
      selected_agent = view and view.selected_agent or nil,
    },
  }
end

return WheelUI
