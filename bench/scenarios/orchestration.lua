-- bench/scenarios/orchestration.lua
-- WheelTeam:run_orchestration_loop at 1/5/10 agents and tasks.
--
-- The measurement is coordination only: one reviewer plus N coding workers,
-- N independent ready tasks, the default deterministic step function, and a
-- provider stub that is never called. No filesystem, process, or provider work
-- is part of the timed region; team and task construction are excluded.

local stats = require("bench.lib.stats")
local time = require("bench.lib.time")
local WheelKernel = require("wheel.kernel")
local WheelTeam = require("wheel.team")
local WheelAgent = require("wheel.agent")
local WheelTool = require("wheel.tool")

local M = {}

M.name = "orchestration"
M.description = "WheelTeam:run_orchestration_loop with mock workers"
M.default_samples = 30
M.full_sizes = { 1, 5, 10 }
M.smoke_sizes = { 1, 10 }
M.samples_by_size = { [1] = 15, [5] = 5, [10] = 3 }

local STUB_PROVIDER = { name = "bench-stub" }

function STUB_PROVIDER:stream()
  error("orchestration benchmark must not call the provider")
end

function STUB_PROVIDER:complete()
  error("orchestration benchmark must not call the provider")
end

function STUB_PROVIDER:describe()
  return { provider = "bench-stub", model = "none" }
end

local function run_once(size)
  local kernel = WheelKernel.new_mock()
  local team = WheelTeam.new({
    kernel = kernel,
    tool_registry = WheelTool.Registry.new(),
  })

  for index = 1, size do
    team:spawn_agent({
      name = string.format("worker-%02d", index),
      role = WheelAgent.Role.CODING,
      model_profile = { provider = "mock", model = "bench-mock" },
      provider = STUB_PROVIDER,
    })
  end
  team:spawn_agent({
    name = "reviewer-01",
    role = WheelAgent.Role.REVIEWER,
    model_profile = { provider = "mock", model = "bench-mock" },
    provider = STUB_PROVIDER,
  })

  for index = 1, size do
    kernel:create_task({
      id = string.format("T-%02d", index),
      title = string.format("Benchmark task %d", index),
      description = "Deterministic orchestration workload",
      priority = 5,
    })
  end

  local started = time.cpu()
  local report = team:run_orchestration_loop({
    max_waves = size + 2,
    auto_reviewer = true,
  })
  local elapsed_micros = time.micros(started, time.cpu())

  if not report.success or #report.completed_tasks ~= size then
    error(string.format(
      "orchestration sample did not complete %d task(s): success=%s completed=%d reason=%s",
      size, tostring(report.success), #report.completed_tasks, tostring(report.blocked_reason)))
  end
  if report.total_handoffs ~= size then
    error(string.format("orchestration sample produced %d handoff(s), expected %d",
      report.total_handoffs, size))
  end

  return elapsed_micros, report
end

local function summarize(values)
  local summary, summary_error = stats.summarize(values)
  if not summary then
    error(summary_error)
  end
  return stats.round(summary, 3)
end

local function samples_for(ctx, size)
  if ctx.samples then
    return ctx.samples
  end
  return M.samples_by_size[size] or M.default_samples
end

--- Run the orchestration scenario.
-- @param ctx table
-- @return table
function M.run(ctx)
  local sizes = (ctx.profile == "smoke") and M.smoke_sizes or M.full_sizes
  local timings = {}
  local reports = {}
  local counts = {}

  -- One cheap warm-up at the smallest size removes first-call effects without
  -- paying the largest cardinality twice.
  if ctx.warmup > 0 then
    run_once(sizes[1])
  end

  for _, size in ipairs(sizes) do
    local samples = samples_for(ctx, size)
    counts[size] = samples
    timings[size] = {}
    for _ = 1, samples do
      local elapsed_micros, report = run_once(size)
      timings[size][#timings[size] + 1] = elapsed_micros
      reports[size] = report
    end
  end

  local series = {}
  local derived = {}
  for _, size in ipairs(sizes) do
    local summary = summarize(timings[size])
    series[#series + 1] = {
      name = "run_orchestration_loop",
      cardinality = size,
      unit = "us",
      samples = #timings[size],
      stats = summary,
    }
    derived[tostring(size)] = {
      samples = counts[size],
      us_per_task = stats.round({ n = 1, median = summary.median / size }, 3).median,
      waves_executed = reports[size].waves_executed,
      handoffs = reports[size].total_handoffs,
      checkpoints = reports[size].total_checkpoints,
    }
  end

  return {
    name = M.name,
    description = M.description,
    series = series,
    extra = {
      derived = derived,
      agents = "N coding workers + 1 reviewer",
      sampling = "cpu=os.clock around run_orchestration_loop; setup excluded",
    },
    notes = "Coordination overhead only: default deterministic step function, no runner, filesystem, process, or provider work.",
  }
end

return M
