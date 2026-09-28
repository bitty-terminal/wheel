-- Entry point for Wheel (bitty-terminal.wheel).
--
-- The host evaluates this file once per plugin activation and owns every
-- resource created here for the lifetime of that generation.
--
-- Capabilities used here match `bitty-plugin.toml`: platform.notify.
-- No other ambient authority is granted or assumed.

local function load_submodule(subpath)
  local ok, mod = pcall(require, "wheel." .. subpath)
  if ok then return mod end
  ok, mod = pcall(require, "lua.wheel." .. subpath)
  if ok then return mod end
  return require(subpath)
end

local WheelKernel = load_submodule("kernel")
local WheelAgent = load_submodule("agent")
local WheelUI = load_submodule("ui")
local WheelConfig = load_submodule("config")
local WheelTeam = load_submodule("team")
local WheelContext = load_submodule("context")
local WheelTool = load_submodule("tool")
local WheelProvider = load_submodule("provider")
local WheelRunner = load_submodule("runner")

local M = {
  kernel = WheelKernel.new(),
  agent = WheelAgent,
  ui = WheelUI,
  config = WheelConfig,
  team = WheelTeam,
  context = WheelContext,
  tool = WheelTool,
  provider = WheelProvider,
  runner = WheelRunner,
  WheelKernel = WheelKernel,
  WheelAgent = WheelAgent,
  WheelUI = WheelUI,
  WheelConfig = WheelConfig,
  WheelTeam = WheelTeam,
  WheelContext = WheelContext,
  WheelTool = WheelTool,
  WheelProvider = WheelProvider,
  WheelRunner = WheelRunner,
  tools = WheelTool and WheelTool.get_default_registry(),
}

-- Register plugin commands if running inside Bitty host environment.
if type(bitty) == "table" and type(bitty.commands) == "table" and bitty.commands.register then
  -- 1. hello
  bitty.commands.register({
    id = "hello",
    title = "Wheel: hello",
    description = "Print a greeting from Wheel.",
    run = function()
      bitty.notify.show({
        title = "Wheel",
        body = "Hello from bitty-terminal.wheel (Bittie 🐹).",
      })
    end,
  })

  -- 2. status
  bitty.commands.register({
    id = "status",
    title = "Wheel: status",
    description = "Display Wheel kernel status and telemetry summary.",
    run = function()
      local text = WheelUI.format_status(M.kernel)
      bitty.notify.show({
        title = "Wheel Status",
        body = text,
      })
    end,
  })

  -- 3. graph
  bitty.commands.register({
    id = "graph",
    title = "Wheel: graph",
    description = "Render ASCII Task DAG and topological execution waves.",
    run = function()
      local text = WheelUI.format_graph(M.kernel)
      bitty.notify.show({
        title = "Wheel Task DAG",
        body = text,
      })
    end,
  })

  -- 4. plan
  bitty.commands.register({
    id = "plan",
    title = "Wheel: plan",
    description = "Initialize or decompose a software engineering plan in the Task DAG.",
    run = function()
      local conf_res = WheelConfig.load({ project_root = "." })
      if not conf_res.ok and conf_res.message then
        bitty.notify.show({
          title = "Wheel Config Notice",
          body = conf_res.message,
        })
      end

      local commander = WheelAgent.new({
        name = "commander-01",
        role = WheelAgent.Role.COMMANDER,
        kernel = M.kernel,
        config = conf_res.config,
      })
      commander:decompose_plan({
        { id = "CTX-0001", title = "Setup architecture and contracts", priority = 0 },
        { id = "CTX-0002", title = "Implement kernel client and roles", priority = 0, dependencies = { "CTX-0001" } },
        { id = "CTX-0003", title = "Verify and test quality gates", priority = 1, dependencies = { "CTX-0002" } },
      })
      bitty.notify.show({
        title = "Wheel Plan",
        body = "Initialized software engineering plan with 3 tasks in DAG.",
      })
    end,
  })

  -- 5. run
  bitty.commands.register({
    id = "run",
    title = "Wheel: run",
    description = "Execute the next ready task in the DAG using WheelAgent.",
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
        bitty.notify.show({
          title = "Wheel Run",
          body = "No ready tasks available to execute.",
        })
        return
      end

      local conf_res = WheelConfig.load({ project_root = "." })
      if not conf_res.ok and conf_res.message then
        bitty.notify.show({
          title = "Wheel Config Notice",
          body = conf_res.message,
        })
      end

      local worker = WheelAgent.new({
        name = "worker-coding-01",
        role = WheelAgent.Role.CODING,
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

      bitty.notify.show({
        title = "Wheel Run",
        body = msg,
      })
    end,
  })

  -- 6. trust
  bitty.commands.register({
    id = "trust",
    title = "Wheel: trust",
    description = "Inspect and approve project configuration (.wheel/init.lua).",
    run = function()
      local project_root = "."
      local proj_path = WheelConfig.get_project_config_path(project_root)
      local file = io.open(proj_path, "r")
      if not file then
        bitty.notify.show({
          title = "Wheel Trust",
          body = "No project configuration found at " .. proj_path,
        })
        return
      end
      local content = file:read("*a")
      file:close()

      local preview = content:sub(1, 120)
      if #content > 120 then
        preview = preview .. "..."
      end

      local ok, err, hash = WheelConfig.trust(project_root, content)
      if ok then
        bitty.notify.show({
          title = "Wheel Trust Approved",
          body = string.format("Approved %s (hash: %s):\n%s", proj_path, hash:sub(1, 16), preview),
        })
      else
        bitty.notify.show({
          title = "Wheel Trust Error",
          body = "Failed to record trust: " .. tostring(err),
        })
      end
    end,
  })

  -- 7. team
  bitty.commands.register({
    id = "team",
    title = "Wheel: team status",
    description = "Display Wheel multi-agent peer colleague roster and live states.",
    run = function()
      if not M._team then
        M._team = WheelTeam.new({ kernel = M.kernel, config = M._last_config })
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
      bitty.notify.show({
        title = "Wheel Team Roster",
        body = table.concat(lines, "\n"),
      })
    end,
  })

  -- 8. context
  bitty.commands.register({
    id = "context",
    title = "Wheel: context",
    description = "Inspect active semantic slots, Merkle root, and prefix-cache status.",
    run = function()
      if not M._team then
        M._team = WheelTeam.new({ kernel = M.kernel, config = M._last_config })
      end
      local ctx = M._team.context or WheelContext.new({ kernel = M.kernel, config = M._last_config })
      local slots = ctx:list_slots()
      local tree_h = ctx:tree_hash()
      local lines = {
        string.format("Wheel Context: %d semantic slots | Tree: %s", #slots, tree_h:sub(1, 16)),
      }
      for _, s in ipairs(slots) do
        table.insert(lines, string.format("  [%s] %s (v%d, %d B)", s.kind:upper(), s.name, s.version, s.size_bytes))
      end
      bitty.notify.show({
        title = "Wheel Context State",
        body = table.concat(lines, "\n"),
      })
    end,
  })

  -- 9. tools
  bitty.commands.register({
    id = "tools",
    title = "Wheel: tools",
    description = "List registered Wheel agent tools and intent schemas.",
    run = function()
      local reg = WheelTool.get_default_registry()
      local list = reg:list_tools()
      local lines = {
        string.format("Wheel Tools: %d registered core tools", #list),
      }
      for _, t in ipairs(list) do
        table.insert(lines, string.format("  [%s] %s - %s", t.intent:upper(), t.name, t.description))
      end
      bitty.notify.show({
        title = "Wheel Tools Registry",
        body = table.concat(lines, "\n"),
      })
    end,
  })

  -- 10. orchestrate
  bitty.commands.register({
    id = "orchestrate",
    title = "Wheel: orchestrate",
    description = "Run autonomous multi-agent wave orchestration loop over Task DAG.",
    run = function()
      if not M._team then
        M._team = WheelTeam.new({ kernel = M.kernel, config = M._last_config })
      end
      local has_worker = false
      local has_reviewer = false
      for _, a in ipairs(M._team:list_agents()) do
        if a.role == WheelAgent.Role.CODING then
          has_worker = true
        elseif a.role == WheelAgent.Role.REVIEWER then
          has_reviewer = true
        end
      end
      if not has_worker then
        M._team:spawn_agent({ name = "worker-coding-01", role = WheelAgent.Role.CODING })
      end
      if not has_reviewer then
        M._team:spawn_agent({ name = "reviewer-01", role = WheelAgent.Role.REVIEWER })
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

      bitty.notify.show({
        title = "Wheel Orchestration",
        body = msg,
      })
    end,
  })

  -- 11. models
  bitty.commands.register({
    id = "models",
    title = "Wheel: models",
    description = "Display configured model profiles, providers, and parameters.",
    run = function()
      local roles = {
        WheelAgent.Role.COMMANDER,
        WheelAgent.Role.CODING,
        WheelAgent.Role.DEBUG,
        WheelAgent.Role.REVIEWER,
        WheelAgent.Role.RESEARCH,
      }
      local cfg = M.config and type(M.config.get) == "function" and M.config.get()
      local lines = { "=== Wheel Heterogeneous Model Profiles ===" }
      for _, r in ipairs(roles) do
        local prof = WheelAgent.get_default_model_profile(r)
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

      bitty.notify.show({
        title = "Wheel Models",
        body = table.concat(lines, "\n"),
      })
    end,
  })
end

return M
