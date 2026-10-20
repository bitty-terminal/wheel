-- Entry point for Wheel (bitty-terminal.wheel).
--
-- The host evaluates this file once per plugin activation and owns every
-- resource created here for the lifetime of that generation.
--
-- Capabilities used here match `bitty-plugin.toml`: platform.notify.
-- No other ambient authority is granted or assumed.
--
-- Activation loads only what command registration, `hello`, `status`, and the
-- catalog/help surface need: the typed error vocabulary, command schemas, the
-- command layer, the kernel instance, and the UI formatter. Agent, team,
-- context, tool, provider, runner, config, and host load on first use through
-- one lazy accessor. A missing module fails with a typed, bounded
-- `E_MODULE_LOAD_FAILED` error naming the rooted module and its cause.

local M = {}
local WheelErrors

--- Built only when `wheel.errors` itself cannot load, before the typed error
-- vocabulary exists. The reason stays one of two fixed, path-free categories.
local function bootstrap_activation_failure(module_name, cause)
  if type(cause) == "table" and type(cause.message) == "string" then
    cause = cause.message
  end
  local detail = "load error"
  if type(cause) == "string" and cause:find("not found", 1, true) then
    detail = "not found"
  end
  local err = {
    class = "resolution",
    code = "E_MODULE_LOAD_FAILED",
    message = string.format("activation failed for module '%s': %s", module_name, detail),
  }
  return setmetatable(err, {
    __tostring = function(self)
      return string.format("%s: %s (%s)", self.class, self.message, self.code)
    end,
  })
end

--- Build the typed activation failure through the error vocabulary when it is
-- available. Never include a raw stack trace or an unbounded loader message.
local function activation_failure(module_name, cause)
  if WheelErrors and type(WheelErrors.module_load_failed) == "function" then
    return WheelErrors.module_load_failed(module_name, cause)
  end
  return bootstrap_activation_failure(module_name, cause)
end

--- Return true when `err` is the interpreter's "module not found" diagnostic.
local function is_not_found(module_name, err)
  return type(err) == "string"
    and err:find("module '" .. module_name .. "' not found", 1, true) ~= nil
end

--- Require one Wheel submodule through a rooted package name.
-- Both accepted module roots are tried (`wheel.<name>` and `lua.wheel.<name>`).
-- There is deliberately no bare `require(name)` fallback: it would drop the
-- rooted context and mask the original cause. Any failure raises a typed,
-- attributed activation error instead.
local function load_module(name)
  local rooted = "wheel." .. name
  local ok, mod = pcall(require, rooted)
  if ok then return mod end
  -- Lua 5.1 leaves a load sentinel after a failed require. Clear it so a
  -- second lazy access reports the real cause instead of "loop or previous
  -- error"; this changes only error quality, not the activation contract.
  package.loaded[rooted] = nil

  local cause = mod
  if not is_not_found(rooted, cause) then
    error(activation_failure(rooted, cause), 0)
  end

  local alternate = "lua." .. rooted
  ok, mod = pcall(require, alternate)
  if ok then return mod end
  package.loaded[alternate] = nil

  local alternate_cause = mod
  if not is_not_found(alternate, alternate_cause) then
    error(activation_failure(rooted, alternate_cause), 0)
  end

  -- Both roots report the module absent. Keep the canonical rooted name and
  -- the first diagnostic so the message cannot drift to the alternate root.
  error(activation_failure(rooted, cause), 0)
end

WheelErrors = load_module("errors")
local WheelSchema = load_module("schema")
local WheelCommands = load_module("commands")
local WheelKernel = load_module("kernel")
local WheelUI = load_module("ui")

-- Required at activation: registration metadata, the kernel instance that
-- `status` and every command closure use, and the status/graph formatter.
M.kernel = WheelKernel.new()
M.ui = WheelUI
M.schema = WheelSchema
M.command_runtime = WheelCommands
M.WheelKernel = WheelKernel
M.WheelUI = WheelUI
M.WheelSchema = WheelSchema
M.WheelCommands = WheelCommands

-- Optional modules are absent from the activation path and load exactly once,
-- on first field access or first command dispatch. Loaded values are cached in
-- the module table (and in `lazy_cache`) so repeated access is cheap; a caller
-- can still replace a field with an injected double.
local LAZY_FIELDS = {
  agent = "agent",
  config = "config",
  team = "team",
  context = "context",
  tool = "tool",
  provider = "provider",
  runner = "runner",
  host = "host",
  WheelAgent = "agent",
  WheelConfig = "config",
  WheelTeam = "team",
  WheelContext = "context",
  WheelTool = "tool",
  WheelProvider = "provider",
  WheelRunner = "runner",
  WheelHost = "host",
  tools = "tools",
}

local lazy_cache = {}

local function lazy_module(name)
  local mod = lazy_cache[name]
  if mod == nil then
    mod = load_module(name)
    lazy_cache[name] = mod
  end
  return mod
end

--- Return the shared default tool registry, loading the tool module on first
-- use. `wheel.tools` and the `tools` command share this one cache.
local function lazy_tools()
  local registry = lazy_cache.tools
  if registry == nil then
    registry = lazy_module("tool").get_default_registry()
    lazy_cache.tools = registry
  end
  return registry
end

setmetatable(M, {
  __index = function(target, key)
    local name = LAZY_FIELDS[key]
    if not name then
      return nil
    end
    local value = name == "tools" and lazy_tools() or lazy_module(name)
    rawset(target, key, value)
    return value
  end,
})

-- Show a notification through the shared command layer, which owns the
-- host-compatible result bounds and the UTF-8-safe truncation.
-- @param title string
-- @param body string
-- @return table { title: string, body: string }
local function notify(title, body)
  return WheelCommands.notify(bitty, title, body)
end

--- Cut text at a UTF-8 boundary no later than `limit` bytes.
local function utf8_cut(text, limit)
  if #text <= limit then
    return text
  end
  local cut = limit
  while cut > 0 do
    local byte = text:byte(cut + 1)
    if byte == nil or byte < 0x80 or byte > 0xBF then
      break
    end
    cut = cut - 1
  end
  if cut == 0 then
    cut = limit
  end
  return text:sub(1, cut)
end

--- Split a consent report into notification-sized chunks.
-- The trust consent view is intentionally not truncated: an entry within the
-- 32 KiB cap must be shown in full even though one host notification is capped
-- at 8000 body bytes. Chunks split on line boundaries where possible and never
-- split a UTF-8 sequence.
local function chunk_report(text, limit)
  local chunks = {}
  local remaining = text
  while #remaining > limit do
    local slice = remaining:sub(1, limit)
    local newline = slice:match(".*()\n")
    local cut
    if newline and newline > 1 then
      cut = newline
    else
      cut = #utf8_cut(remaining, limit)
    end
    if cut == 0 then
      cut = limit
    end
    chunks[#chunks + 1] = remaining:sub(1, cut)
    remaining = remaining:sub(cut + 1)
  end
  if remaining ~= "" then
    chunks[#chunks + 1] = remaining
  end
  if #chunks == 0 then
    chunks[1] = ""
  end
  return chunks
end

--- Show a report across one or more bounded notifications.
-- The result body is `summary` when supplied; the full report is the
-- notification series. This keeps a result-only consumer from believing the
-- final chunk is the whole consent view.
local function notify_report(prefix, text, summary)
  local chunks = chunk_report(text, WheelCommands.RESULT_BODY_MAX_LENGTH)
  for index, chunk in ipairs(chunks) do
    notify(string.format("%s (%d/%d)", prefix, index, #chunks), chunk)
  end
  if summary then
    return notify(prefix .. " Summary", summary)
  end
  return nil
end

-- Lazy command table: metadata, argument schema, result schema, and handler
-- live in one declaration per command. Registration is a pure projection over
-- this table; no handler runs until the host dispatches it.
local WHEEL_COMMANDS = {
  -- 1. hello
  {
    id = "hello",
    title = "Wheel: hello",
    description = "Print a greeting from Wheel.",
    args_schema = WheelCommands.no_args_schema(),
    result_schema = WheelCommands.notification_result_schema(),
    run = function()
      return notify("Wheel", "Hello from bitty-terminal.wheel (Bittie 🐹).")
    end,
  },

  -- 2. status
  {
    id = "status",
    title = "Wheel: status",
    description = "Display Wheel kernel status and telemetry summary.",
    args_schema = WheelCommands.no_args_schema(),
    result_schema = WheelCommands.notification_result_schema(),
    run = function()
      local text = WheelUI.format_status(M.kernel)
      return notify("Wheel Status", text)
    end,
  },

  -- 3. graph
  {
    id = "graph",
    title = "Wheel: graph",
    description = "Render ASCII Task DAG and topological execution waves.",
    args_schema = WheelCommands.no_args_schema(),
    result_schema = WheelCommands.notification_result_schema(),
    run = function()
      local text = WheelUI.format_graph(M.kernel)
      return notify("Wheel Task DAG", text)
    end,
  },

  -- 4. plan
  {
    id = "plan",
    title = "Wheel: plan",
    description = "Initialize or decompose a software engineering plan in the Task DAG.",
    args_schema = WheelCommands.no_args_schema(),
    result_schema = WheelCommands.notification_result_schema(),
    run = function()
      local conf_res = M.config.load({ project_root = "." })
      if not conf_res.ok and conf_res.message then
        notify("Wheel Config Notice", conf_res.message)
      end

      local commander = M.agent.new({
        name = "commander-01",
        role = M.agent.Role.COMMANDER,
        kernel = M.kernel,
        config = conf_res.config,
      })
      commander:decompose_plan({
        { id = "CTX-0001", title = "Setup architecture and contracts", priority = 0 },
        { id = "CTX-0002", title = "Implement kernel client and roles", priority = 0, dependencies = { "CTX-0001" } },
        { id = "CTX-0003", title = "Verify and test quality gates", priority = 1, dependencies = { "CTX-0002" } },
      })
      return notify("Wheel Plan", "Initialized software engineering plan with 3 tasks in DAG.")
    end,
  },

  -- 5. run
  {
    id = "run",
    title = "Wheel: run",
    description = "Execute the next ready task in the DAG using WheelAgent.",
    args_schema = WheelCommands.no_args_schema(),
    result_schema = WheelCommands.notification_result_schema(),
    run = function()
      local tasks = M.kernel:list_tasks()
      local ready_task = nil
      for _, t in ipairs(tasks) do
        if (t.status or ""):lower() == "ready" then
          ready_task = t
          break
        end
      end

      if not ready_task then
        return notify("Wheel Run", "No ready tasks available to execute.")
      end

      local conf_res = M.config.load({ project_root = "." })
      if not conf_res.ok and conf_res.message then
        notify("Wheel Config Notice", conf_res.message)
      end

      local worker = M.agent.new({
        name = "worker-coding-01",
        role = M.agent.Role.CODING,
        kernel = M.kernel,
        config = conf_res.config,
      })

      local outcome = worker:execute_task(ready_task.id, function(agent, ctx, iter)
        return {
          action = { tool = "run_command", stdout = "executed step " .. iter, exit_code = 0 },
          rationale = {
            why = "Execute planned task " .. ready_task.id,
            what = "Ran task step " .. iter .. ": " .. ready_task.title,
          },
          done = true,
        }
      end)

      local msg
      if outcome.success then
        msg = string.format("Task %s completed successfully! (container: %s)", ready_task.id, outcome.panel_id or "headless")
      else
        msg = string.format("Task %s failed: %s", ready_task.id, tostring(outcome.error))
      end

      return notify("Wheel Run", msg)
    end,
  },

  -- 6. trust
  {
    id = "trust",
    title = "Wheel: trust",
    description = "Inspect, approve, or revoke project configuration trust.",
    args_schema = {
      type = "object",
      properties = {
        action = {
          type = "string",
          enum = { "show", "confirm", "revoke" },
          maxLength = 16,
        },
        hash = {
          type = "string",
          minLength = 64,
          maxLength = 64,
        },
        path = {
          type = "string",
          minLength = 1,
          maxLength = 4096,
        },
      },
      additionalProperties = false,
    },
    result_schema = WheelCommands.notification_result_schema(),
    run = function(args)
      args = args or {}
      local action = args.action or "show"
      local project_root = args.path or "."
      local config = M.config

      if action == "show" then
        local plan = config.trust_status(project_root)
        if not plan.ok then
          if plan.code == "E_PROJECT_CONFIG_MISSING" then
            return notify("Wheel Trust", string.format(
              "No project configuration found at %s\nCanonical project root: %s\nNothing was trusted.",
              tostring(plan.path), tostring(plan.root or "unresolved")))
          end
          return notify("Wheel Trust Error", config.format_trust_error(plan))
        end
        local nonce = config.consent_nonce()
        local report = config.format_trust_show(plan, nonce)
        local chunk_count = #chunk_report(report, WheelCommands.RESULT_BODY_MAX_LENGTH)
        local summary = config.format_trust_summary(plan, chunk_count)
        return notify_report("Wheel Trust", report, summary)
      end

      if action == "confirm" then
        if not args.hash then
          return notify("Wheel Trust Error",
            "Confirmation requires the full 64-hex SHA-256 shown by `trust`.")
        end
        local ok, err, hash, status = config.confirm_trust(project_root, args.hash)
        if not ok then
          return notify("Wheel Trust Refused", config.format_trust_error(err))
        end
        return notify("Wheel Trust Approved", config.format_trust_confirm(status))
      end

      if action == "revoke" then
        local ok, removed, root = config.revoke(project_root)
        if not ok then
          return notify("Wheel Trust Revoke Failed", config.format_trust_error(removed))
        end
        return notify("Wheel Trust Revoked",
          config.format_trust_revoke(root or project_root, removed))
      end
    end,
  },

  -- 7. team
  {
    id = "team",
    title = "Wheel: team status",
    description = "Display Wheel multi-agent peer colleague roster and live states.",
    args_schema = WheelCommands.no_args_schema(),
    result_schema = WheelCommands.notification_result_schema(),
    run = function()
      if not M._team then
        M._team = M.team.new({ kernel = M.kernel, config = M._last_config })
      end
      local st = M._team:status()
      local lines = {
        string.format("Wheel Team: %d colleagues (%d idle, %d busy, %d handoffs)",
          st.total_agents, st.idle_count, st.busy_count, st.handoff_count)
      }
      for _, a in ipairs(st.agents) do
        local model_info = (a.model and (a.model.provider .. "/" .. a.model.model)) or "default"
        table.insert(lines, string.format("  [%s] %s (%s) | %s | %s",
          a.state == "busy" and "RUN" or "IDLE", a.name, a.role, model_info, a.panel_id))
      end
      return notify("Wheel Team Roster", table.concat(lines, "\n"))
    end,
  },

  -- 8. context
  {
    id = "context",
    title = "Wheel: context",
    description = "Inspect active semantic slots, Merkle root, and prefix-cache status.",
    args_schema = WheelCommands.no_args_schema(),
    result_schema = WheelCommands.notification_result_schema(),
    run = function()
      if not M._team then
        M._team = M.team.new({ kernel = M.kernel, config = M._last_config })
      end
      local ctx = M._team.context or M.context.new({ kernel = M.kernel, config = M._last_config })
      local slots = ctx:list_slots()
      local tree_h = ctx:tree_hash()
      local lines = {
        string.format("Wheel Context: %d semantic slots | Tree: %s", #slots, tree_h:sub(1, 16)),
      }
      for _, s in ipairs(slots) do
        table.insert(lines, string.format("  [%s] %s (v%d, %d B)", s.kind:upper(), s.name, s.version, s.size_bytes))
      end
      return notify("Wheel Context State", table.concat(lines, "\n"))
    end,
  },

  -- 9. tools
  {
    id = "tools",
    title = "Wheel: tools",
    description = "List registered Wheel agent tools and intent schemas.",
    args_schema = WheelCommands.no_args_schema(),
    result_schema = WheelCommands.notification_result_schema(),
    run = function()
      local reg = M.tools
      local list = reg:list_tools()
      local lines = {
        string.format("Wheel Tools: %d registered core tools", #list),
      }
      for _, t in ipairs(list) do
        table.insert(lines, string.format("  [%s] %s - %s", t.intent:upper(), t.name, t.description))
      end
      return notify("Wheel Tools Registry", table.concat(lines, "\n"))
    end,
  },

  -- 10. orchestrate
  {
    id = "orchestrate",
    title = "Wheel: orchestrate",
    description = "Run autonomous multi-agent wave orchestration loop over Task DAG.",
    args_schema = WheelCommands.no_args_schema(),
    result_schema = WheelCommands.notification_result_schema(),
    run = function()
      if not M._team then
        M._team = M.team.new({ kernel = M.kernel, config = M._last_config })
      end
      local has_worker = false
      local has_reviewer = false
      for _, a in ipairs(M._team:list_agents()) do
        if a.role == M.agent.Role.CODING then
          has_worker = true
        elseif a.role == M.agent.Role.REVIEWER then
          has_reviewer = true
        end
      end
      if not has_worker then
        M._team:spawn_agent({ name = "worker-coding-01", role = M.agent.Role.CODING })
      end
      if not has_reviewer then
        M._team:spawn_agent({ name = "reviewer-01", role = M.agent.Role.REVIEWER })
      end

      local report = M._team:run_orchestration_loop()
      local msg
      if report.success then
        msg = string.format("Orchestration completed successfully in %d wave(s)!\nTasks completed: %d\nHandoffs: %d\nCheckpoints: %d\nDuration: %d ms",
          report.waves_executed, #report.completed_tasks, report.total_handoffs, report.total_checkpoints, report.duration_ms)
      else
        msg = string.format("Orchestration halted: %s\nCompleted: %d | Failed: %d\nWaves: %d",
          report.blocked_reason or "unknown blockage", #report.completed_tasks, #report.failed_tasks, report.waves_executed)
      end

      return notify("Wheel Orchestration", msg)
    end,
  },

  -- 11. models
  {
    id = "models",
    title = "Wheel: models",
    description = "Display configured model profiles, providers, and parameters.",
    args_schema = WheelCommands.no_args_schema(),
    result_schema = WheelCommands.notification_result_schema(),
    run = function()
      local agent = M.agent
      local roles = {
        agent.Role.COMMANDER,
        agent.Role.CODING,
        agent.Role.DEBUG,
        agent.Role.REVIEWER,
        agent.Role.RESEARCH,
      }
      local cfg = M.config and type(M.config.get) == "function" and M.config.get()
      local lines = { "=== Wheel Heterogeneous Model Profiles ===" }
      for _, r in ipairs(roles) do
        local prof = agent.get_default_model_profile(r)
        if cfg and cfg.roles and cfg.roles[r] and cfg.roles[r].model_profile then
          local override = cfg.roles[r].model_profile
          local merged = {}
          for k, v in pairs(prof) do merged[k] = v end
          for k, v in pairs(override) do merged[k] = v end
          prof = merged
        end
        local thinking_str = ""
        if prof.thinking and prof.thinking.enabled then
          thinking_str = string.format(" [thinking: %d tokens, %s]", prof.thinking.budget_tokens or 0, prof.thinking.gear or "default")
        end
        table.insert(lines, string.format("• %-10s : %s / %s (temp: %.1f)%s", r, prof.provider, prof.model, prof.temperature, thinking_str))
      end

      return notify("Wheel Models", table.concat(lines, "\n"))
    end,
  },

  -- 12. branch
  {
    id = "branch",
    title = "Wheel: branch",
    description = "List context branches or display active branch and HEAD commit.",
    args_schema = WheelCommands.no_args_schema(),
    result_schema = WheelCommands.notification_result_schema(),
    run = function()
      if not M._team then
        M._team = M.team.new({ kernel = M.kernel, config = M._last_config })
      end
      local ctx = M._team.context
      local branches = ctx:list_branches()
      local lines = { "=== Wheel Context Branches ===" }
      for _, b in ipairs(branches) do
        local marker = b.is_head and "* " or "  "
        local hash_str = b.hash and b.hash:sub(1, 8) or "(empty)"
        table.insert(lines, string.format("%s%-16s -> %s", marker, b.name, hash_str))
      end
      return notify("Wheel Context Branches", table.concat(lines, "\n"))
    end,
  },

  -- 13. checkpoint
  {
    id = "checkpoint",
    title = "Wheel: checkpoint",
    description = "Display recent context checkpoints (commit ancestry log).",
    args_schema = WheelCommands.no_args_schema(),
    result_schema = WheelCommands.notification_result_schema(),
    run = function()
      if not M._team then
        M._team = M.team.new({ kernel = M.kernel, config = M._last_config })
      end
      local ctx = M._team.context
      local commits = ctx:log(8)
      local lines = { "=== Wheel Context Checkpoints ===" }
      if #commits == 0 then
        table.insert(lines, "(no checkpoints committed yet)")
      else
        for _, c in ipairs(commits) do
          table.insert(lines, string.format("• %s | %s [%s]",
            c.hash:sub(1, 8), c.message, c.author or "unknown"))
        end
      end
      return notify("Wheel Checkpoints", table.concat(lines, "\n"))
    end,
  },

  -- 14. reflog
  {
    id = "reflog",
    title = "Wheel: reflog",
    description = "Display recent context reflog transitions and audit journal.",
    args_schema = WheelCommands.no_args_schema(),
    result_schema = WheelCommands.notification_result_schema(),
    run = function()
      if not M._team then
        M._team = M.team.new({ kernel = M.kernel, config = M._last_config })
      end
      local ctx = M._team.context
      local entries = ctx:reflog(8)
      local lines = { "=== Wheel Context Reflog ===" }
      if #entries == 0 then
        table.insert(lines, "(reflog empty)")
      else
        for _, r in ipairs(entries) do
          table.insert(lines, string.format("• %s..%s %s: %s",
            r.from_hash:sub(1, 7), r.to_hash:sub(1, 7), r.action, r.message))
        end
      end
      return notify("Wheel Reflog", table.concat(lines, "\n"))
    end,
  },
}

M.command_catalog = WHEEL_COMMANDS

-- Register plugin commands if running inside Bitty host environment. The
-- command layer validates both schemas before the host captures a definition,
-- validates arguments before a handler runs, and validates the result before
-- returning it.
if type(bitty) == "table" and type(bitty.commands) == "table" and bitty.commands.register then
  for _, def in ipairs(WHEEL_COMMANDS) do
    WheelCommands.register(def, bitty)
  end
end

return M
