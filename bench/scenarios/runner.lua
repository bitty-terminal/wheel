-- bench/scenarios/runner.lua
-- WheelRunner.run_task against the deterministic Mock provider at 1/5/10 turns.
--
-- The workload is the production ReAct loop with one trivial inspection tool
-- call per non-final turn, a fresh in-memory kernel/context per sample, and a
-- mock provider that never sleeps. Provider streaming CPU is measured by a
-- thin wrapper and subtracted from the run total, so the record separates
-- runner/context/checkpoint overhead from mock-provider work.

local stats = require("bench.lib.stats")
local time = require("bench.lib.time")
local WheelKernel = require("wheel.kernel")
local WheelContext = require("wheel.context")
local WheelAgent = require("wheel.agent")
local WheelTool = require("wheel.tool")
local WheelProvider = require("wheel.provider")
local WheelRunner = require("wheel.runner")

local M = {}

M.name = "runner"
M.description = "WheelRunner.run_task mock-provider turns"
M.default_samples = 30
M.full_turns = { 1, 5, 10 }
M.smoke_turns = { 1, 10 }

local function mock_response(turns)
  return function(_, call_count)
    if call_count < turns then
      return {
        content = "Inspect benchmark input on turn " .. tostring(call_count),
        tool_calls = {
          { id = "bench-call-" .. tostring(call_count), name = "inspect_file",
            arguments = { path = "bench.txt" } },
        },
        finish_reason = "tool_calls",
        usage = { prompt_tokens = 20, completion_tokens = 5, total_tokens = 25 },
      }
    end
    return {
      content = "Benchmark deliverables complete after " .. tostring(turns) .. " turn(s).",
      tool_calls = {},
      finish_reason = "stop",
      usage = { prompt_tokens = 20, completion_tokens = 5, total_tokens = 25 },
    }
  end
end

local function run_once(turns)
  local kernel = WheelKernel.new_mock()
  local context = WheelContext.new({ kernel = kernel })

  local registry = WheelTool.Registry.new()
  registry:register_tool({
    name = "inspect_file",
    intent = WheelTool.ActionIntent.INSPECT,
    description = "Return a fixed benchmark observation",
    execute = function()
      return { success = true, exit_code = 0, stdout = "benchmark observation" }
    end,
  })

  local mock = WheelProvider.MockProvider.new({
    completion_fn = mock_response(turns),
    stream_chunk_size = 16,
  })

  local provider_cpu_seconds = 0
  local timed_provider = {
    name = "bench-mock",
    stream = function(_, request, on_chunk, opts)
      local started = time.cpu()
      local response, stream_error = mock:stream(request, on_chunk, opts)
      provider_cpu_seconds = provider_cpu_seconds + (time.cpu() - started)
      return response, stream_error
    end,
    complete = function(_, request, opts)
      return mock:complete(request, opts)
    end,
    describe = function()
      return { provider = "mock", model = "bench-mock" }
    end,
  }

  local agent = WheelAgent.new({
    name = "bench-worker",
    role = WheelAgent.Role.CODING,
    kernel = kernel,
    context = context,
    tool_registry = registry,
    tools = { "inspect_file" },
    model_profile = {
      provider = "mock",
      model = "bench-mock",
      temperature = 0.0,
    },
    provider = timed_provider,
  })

  local task = kernel:create_task({
    id = "T-BENCH",
    title = "Benchmark runner task",
    description = "Deterministic mock-provider turn loop",
    priority = 5,
  })

  local started = time.cpu()
  local result = WheelRunner.run_task(agent, task, {
    max_turns = turns + 2,
    provider = timed_provider,
  })
  local total_micros = time.micros(started, time.cpu())
  local provider_micros = provider_cpu_seconds * 1000000
  local overhead_micros = total_micros - provider_micros
  if overhead_micros < 0 then
    overhead_micros = 0
  end

  if not result.success or result.iterations ~= turns then
    error(string.format("runner sample did not complete %d turn(s): success=%s iterations=%s",
      turns, tostring(result.success), tostring(result.iterations)))
  end

  return total_micros, provider_micros, overhead_micros
end

local function summarize(values)
  local summary, summary_error = stats.summarize(values)
  if not summary then
    error(summary_error)
  end
  return stats.round(summary, 3)
end

--- Run the runner scenario.
-- @param ctx table
-- @return table
function M.run(ctx)
  local turns_list = (ctx.profile == "smoke") and M.smoke_turns or M.full_turns
  local samples = ctx.samples or M.default_samples
  local totals = {}
  local provider = {}
  local overhead = {}
  local derived = {}

  for _, turns in ipairs(turns_list) do
    totals[turns] = {}
    provider[turns] = {}
    overhead[turns] = {}
    for _ = 1, ctx.warmup do
      run_once(turns)
    end
    for _ = 1, samples do
      local total_micros, provider_micros, overhead_micros = run_once(turns)
      totals[turns][#totals[turns] + 1] = total_micros
      provider[turns][#provider[turns] + 1] = provider_micros
      overhead[turns][#overhead[turns] + 1] = overhead_micros
    end
  end

  local function series(name, values, turns)
    return {
      name = name,
      cardinality = turns,
      unit = "us",
      samples = #values,
      stats = summarize(values),
    }
  end

  local series_list = {}
  for _, turns in ipairs(turns_list) do
    series_list[#series_list + 1] = series("run_task", totals[turns], turns)
    series_list[#series_list + 1] = series("provider", provider[turns], turns)
    series_list[#series_list + 1] = series("runner_overhead", overhead[turns], turns)
    local total_summary = summarize(totals[turns])
    local overhead_summary = summarize(overhead[turns])
    derived[tostring(turns)] = {
      total_us_per_turn = stats.round({ n = 1, median = total_summary.median / turns }, 3).median,
      overhead_us_per_turn = stats.round({ n = 1, median = overhead_summary.median / turns }, 3).median,
    }
  end

  -- Provider share is computed from the medians because each sample keeps its
  -- own provider total; a sum of per-sample ratios would weight outliers twice.
  for turns_key, entry in pairs(derived) do
    local turns = tonumber(turns_key)
    local total_median = summarize(totals[turns]).median
    local provider_median = summarize(provider[turns]).median
    if total_median > 0 then
      entry.provider_share = stats.round({ n = 1, median = provider_median / total_median }, 3).median
    end
  end

  return {
    name = M.name,
    description = M.description,
    series = series_list,
    extra = {
      derived = derived,
      sampling = "cpu=os.clock around run_task; provider cpu measured inside the mock stream wrapper",
    },
    notes = "One trivial inspect tool call per non-final turn; the mock provider performs no I/O and no sleeps.",
  }
end

return M
