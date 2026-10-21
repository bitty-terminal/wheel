-- bench/lib/smoke.lua
-- Release-smoke ceilings for the benchmark records.
--
-- These are deliberately generous regression signals, not host baselines and
-- not release claims. They catch a gross break (a missing fast path, a
-- quadratic coordination path, a runaway context compile) without trying to
-- compare one machine against another. Absolute ceilings are wide multiples of
-- the observed local medians; relative checks compare the largest tested
-- cardinality with the smallest in the same run.

local M = {}

M.ACTIVATION_CPU_MEDIAN_US = 50000        -- RC-1 50 ms CPU budget
M.ACTIVATION_CPU_P95_US = 100000          -- 2x RC-1 budget; shared-host noise allowance
M.ACTIVATION_INSTRUCTION_MEDIAN = 10000000 -- RC-1 instruction budget

M.PROCESS_NORMAL_P95_MS = 2000
M.PROCESS_TIMEOUT_P95_MS = 3000

M.RUNNER_P95_US = 5000000                 -- 5 s for the largest runner cardinality
M.RUNNER_MAX_SCALING = 100                -- 10-turn median / 1-turn median

M.ORCHESTRATION_P95_US = 15000000         -- 15 s for the largest orchestration cardinality
M.ORCHESTRATION_MAX_SCALING = 200         -- 10-task median / 1-task median

M.CONTEXT_COMPILE_P95_US = 2000000        -- 2 s at the largest context cardinality
M.CONTEXT_MAX_SCALING = 500               -- 1000-slot median / 10-slot median

local function by_name(records)
  local map = {}
  for _, record in ipairs(records) do
    map[record.name] = record
  end
  return map
end

local function find_series(record, name, cardinality)
  if not record then
    return nil
  end
  for _, series in ipairs(record.series) do
    if series.name == name and (cardinality == nil or series.cardinality == cardinality) then
      return series
    end
  end
  return nil
end

local function min_cardinality(record, name)
  local best = nil
  for _, series in ipairs(record.series or {}) do
    if series.name == name and (best == nil or series.cardinality < best.cardinality) then
      best = series
    end
  end
  return best
end

local function max_cardinality(record, name)
  local best = nil
  for _, series in ipairs(record.series or {}) do
    if series.name == name and (best == nil or series.cardinality > best.cardinality) then
      best = series
    end
  end
  return best
end

local function evaluate(records)
  local map = by_name(records)
  local checks = {}

  local function add(name, ok, actual, ceiling, unit)
    checks[#checks + 1] = {
      name = name,
      ok = ok and true or false,
      actual = actual,
      ceiling = ceiling,
      unit = unit,
    }
  end

  local activation = map.activation
  local cold = find_series(activation, "cold_cpu")
  local warm = find_series(activation, "warm_cpu")
  local instructions = find_series(activation, "warm_instructions")
  if cold then
    add("activation.cold_cpu.median", cold.stats.median <= M.ACTIVATION_CPU_MEDIAN_US,
      cold.stats.median, M.ACTIVATION_CPU_MEDIAN_US, "us")
    add("activation.cold_cpu.p95", cold.stats.p95 <= M.ACTIVATION_CPU_P95_US,
      cold.stats.p95, M.ACTIVATION_CPU_P95_US, "us")
  end
  if warm then
    add("activation.warm_cpu.median", warm.stats.median <= M.ACTIVATION_CPU_MEDIAN_US,
      warm.stats.median, M.ACTIVATION_CPU_MEDIAN_US, "us")
  end
  if instructions then
    add("activation.warm_instructions.median",
      instructions.stats.median <= M.ACTIVATION_INSTRUCTION_MEDIAN,
      instructions.stats.median, M.ACTIVATION_INSTRUCTION_MEDIAN, "instructions")
  end

  local process = map.process
  if process then
    for _, series in ipairs(process.series) do
      if series.name == "normal" then
        add("process.normal_" .. tostring(series.cardinality) .. ".p95",
          series.stats.p95 <= M.PROCESS_NORMAL_P95_MS,
          series.stats.p95, M.PROCESS_NORMAL_P95_MS, "ms")
      elseif series.name == "timeout" then
        add("process.timeout_" .. tostring(series.cardinality) .. ".p95",
          series.stats.p95 <= M.PROCESS_TIMEOUT_P95_MS,
          series.stats.p95, M.PROCESS_TIMEOUT_P95_MS, "ms")
      end
    end
  end

  local runner = map.runner
  local runner_max = runner and max_cardinality(runner, "run_task")
  local runner_min = runner and min_cardinality(runner, "run_task")
  if runner_max then
    add("runner.max_p95", runner_max.stats.p95 <= M.RUNNER_P95_US,
      runner_max.stats.p95, M.RUNNER_P95_US, "us")
  end
  if runner_max and runner_min and runner_min.stats.median > 0 then
    local scaling = runner_max.stats.median / runner_min.stats.median
    add("runner.scaling", scaling <= M.RUNNER_MAX_SCALING,
      scaling, M.RUNNER_MAX_SCALING, "ratio")
  end

  local orchestration = map.orchestration
  local orchestration_max = orchestration and max_cardinality(orchestration, "run_orchestration_loop")
  local orchestration_min = orchestration and min_cardinality(orchestration, "run_orchestration_loop")
  if orchestration_max then
    add("orchestration.max_p95", orchestration_max.stats.p95 <= M.ORCHESTRATION_P95_US,
      orchestration_max.stats.p95, M.ORCHESTRATION_P95_US, "us")
  end
  if orchestration_max and orchestration_min and orchestration_min.stats.median > 0 then
    local scaling = orchestration_max.stats.median / orchestration_min.stats.median
    add("orchestration.scaling", scaling <= M.ORCHESTRATION_MAX_SCALING,
      scaling, M.ORCHESTRATION_MAX_SCALING, "ratio")
  end

  local context = map.context
  local compile_max = context and max_cardinality(context, "compile_prompt")
  local compile_min = context and min_cardinality(context, "compile_prompt")
  if compile_max then
    add("context.compile_prompt.max_p95", compile_max.stats.p95 <= M.CONTEXT_COMPILE_P95_US,
      compile_max.stats.p95, M.CONTEXT_COMPILE_P95_US, "us")
  end
  if compile_max and compile_min and compile_min.stats.median > 0 then
    local scaling = compile_max.stats.median / compile_min.stats.median
    add("context.compile_scaling", scaling <= M.CONTEXT_MAX_SCALING,
      scaling, M.CONTEXT_MAX_SCALING, "ratio")
  end

  local passed = true
  for _, check in ipairs(checks) do
    if not check.ok then
      passed = false
    end
  end
  return { passed = passed, checks = checks }
end

M.evaluate = evaluate

return M
