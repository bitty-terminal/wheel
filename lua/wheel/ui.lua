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
--- dependencies are all resolved in earlier waves.
--- @param tasks table[]
--- @return table<string, number>, number
local function calculate_waves(tasks)
  local task_map = {}
  for _, t in ipairs(tasks) do
    task_map[t.id] = t
  end

  local depths = {}
  local function get_depth(id, visited)
    if depths[id] then return depths[id] end
    visited = visited or {}
    if visited[id] then return 1 end -- cycle guard
    visited[id] = true

    local t = task_map[id]
    if not t or not t.dependencies or #t.dependencies == 0 then
      depths[id] = 1
      return 1
    end

    local max_dep = 0
    for _, dep_id in ipairs(t.dependencies) do
      local d = get_depth(dep_id, visited)
      if d > max_dep then max_dep = d end
    end
    depths[id] = max_dep + 1
    return depths[id]
  end

  local max_wave = 1
  for _, t in ipairs(tasks) do
    local d = get_depth(t.id)
    if d > max_wave then max_wave = d end
  end

  return depths, max_wave
end

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
        if t.checkpoint then
          table.insert(lines, string.format("      cp:   %s", t.checkpoint:sub(1, 16)))
        end
        local err_msg = t.failure_reason or t.error
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

return WheelUI
