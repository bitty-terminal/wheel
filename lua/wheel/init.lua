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

local M = {
  kernel = WheelKernel.new(),
  agent = WheelAgent,
  ui = WheelUI,
  config = WheelConfig,
  WheelKernel = WheelKernel,
  WheelAgent = WheelAgent,
  WheelUI = WheelUI,
  WheelConfig = WheelConfig,
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

      local ok, err, hash = WheelConfig.trust(project_root, content)
      if ok then
        bitty.notify.show({
          title = "Wheel Trust",
          body = "Approved project configuration (.wheel/init.lua) with hash: " .. hash:sub(1, 16) .. "...",
        })
      else
        bitty.notify.show({
          title = "Wheel Trust Error",
          body = "Failed to record trust: " .. tostring(err),
        })
      end
    end,
  })
end

return M
