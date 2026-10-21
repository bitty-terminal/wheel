#!/usr/bin/env lua
-- bench/run.lua
-- Offline, deterministic benchmark runner for Bitty Wheel (Lua 5.1).
--
-- Usage: lua bench/run.lua [--scenario NAME] [--samples N] [--format human|json]
--                          [--smoke] [--warmup N]
--
-- The hidden `--child-cold` mode runs one cold activation in a fresh process
-- and is used by the activation scenario; it is not part of the public CLI.
--
-- No network, credentials, live providers, or filesystem state are used. The
-- full suite is manual; `--smoke` is the short bounded regression subset.

local function script_directory()
  local script = (arg and arg[0]) or "bench/run.lua"
  return script:match("^(.*)[/\\][^/\\]+$") or "."
end

local bench_dir = script_directory()
local root = bench_dir .. "/.."
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;"
  .. root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;"
  .. package.path

-- Hidden child mode for cold activation: parse and run before loading any
-- other benchmark module so the measured region contains only wheel activation.
if arg and arg[1] == "--child-cold" then
  local ok, activation = pcall(require, "bench.scenarios.activation")
  if not ok then
    io.stderr:write("bench: cannot load activation scenario: " .. tostring(activation) .. "\n")
    os.exit(1)
  end
  local ok_child, child_error = pcall(activation.child_main, arg[2] == "--instrument")
  if not ok_child then
    io.stderr:write("bench: cold activation failed: " .. tostring(child_error) .. "\n")
    os.exit(1)
  end
  os.exit(0)
end

local cli = require("bench.lib.cli")
local env = require("bench.lib.env")
local json = require("bench.lib.json")
local smoke = require("bench.lib.smoke")
local time = require("bench.lib.time")

local SCENARIO_MODULES = {
  activation = "bench.scenarios.activation",
  process = "bench.scenarios.process",
  runner = "bench.scenarios.runner",
  orchestration = "bench.scenarios.orchestration",
  context = "bench.scenarios.context",
}

local SMOKE_SAMPLES = {
  activation = 5,
  process = 1,
  runner = 3,
  orchestration = 1,
  context = 3,
}

local function format_value(value, unit)
  if unit == "instructions" then
    return string.format("%d", math.floor(value + 0.5)) .. " instr"
  elseif unit == "ms" then
    return string.format("%.2f ms", value)
  elseif unit == "ratio" then
    return string.format("%.2fx", value)
  end
  if value >= 1000 then
    return string.format("%.2f ms", value / 1000)
  end
  return string.format("%.1f us", value)
end

local function print_environment(environment)
  local dirty = ""
  if environment.dirty == true then
    dirty = " (dirty)"
  end
  print("Wheel benchmarks")
  print("  revision    " .. environment.revision .. dirty)
  print("  interpreter " .. environment.interpreter_name .. " / " .. environment.interpreter)
  print("  cpu         " .. tostring(environment.cpu)
    .. (environment.cpu_count and (" x" .. environment.cpu_count) or ""))
  print("  os          " .. environment.os .. ", kernel " .. environment.kernel
    .. ", " .. environment.arch)
  if environment.pinned_cpu ~= nil then
    print("  pinning     " .. environment.pinning .. ":" .. tostring(environment.pinned_cpu))
  else
    print("  pinning     none (results are not CPU-pinned)")
  end
  print("  wall clock  " .. time.wall_source
    .. " (" .. tostring(time.wall_resolution_ms) .. " ms resolution)")
  print("")
end

local function print_scenario(record)
  print(record.name .. " - " .. record.description)
  for _, series in ipairs(record.series) do
    local label = series.name
    if series.cardinality then
      label = label .. " x" .. tostring(series.cardinality)
    end
    local summary = series.stats
    print(string.format("  %-24s n=%-3d min %s  median %s  p95 %s  max %s  iqr %s",
      label, summary.n,
      format_value(summary.min, series.unit),
      format_value(summary.median, series.unit),
      format_value(summary.p95, series.unit),
      format_value(summary.max, series.unit),
      format_value(summary.iqr, series.unit)))
  end
  if record.notes then
    print("  note: " .. record.notes)
  end
  print("")
end

local function percent(numerator, denominator)
  if denominator == 0 then
    return 0
  end
  return (numerator / denominator) * 100
end

local function sorted_keys(map, numeric)
  local keys = {}
  for key in pairs(map) do
    keys[#keys + 1] = key
  end
  table.sort(keys, function(left, right)
    if numeric then
      return tonumber(left) < tonumber(right)
    end
    return left < right
  end)
  return keys
end

local function print_extras(records)
  for _, record in ipairs(records) do
    if record.name == "activation" then
      local rc1 = record.extra.rc1
      local warm = nil
      for _, series in ipairs(record.series) do
        if series.name == "warm_cpu" then
          warm = series
        end
      end
      if warm then
        print(string.format(
          "activation RC-1: warm cpu median %.2f%% of %d ms; warning threshold %d ms",
          percent(warm.stats.median / 1000, rc1.cpu_budget_ms), rc1.cpu_budget_ms, rc1.warning_ms))
      end
      local instructions = nil
      for _, series in ipairs(record.series) do
        if series.name == "warm_instructions" then
          instructions = series
        end
      end
      if instructions then
        print(string.format("activation RC-1: instructions median %.4f%% of %d",
          percent(instructions.stats.median, rc1.instruction_budget), rc1.instruction_budget))
      end
      print("")
    elseif record.name == "process" then
      print(string.format("process: sweep grace %.0f ms is charged per call; timeout %.0f ms",
        record.extra.sweep_grace_ms, record.extra.timeout_ms))
      for _, entry in ipairs(record.extra.derived) do
        print(string.format("  %-7s x%-3d fixed floor %.0f ms, non-grace overhead %.2f ms, grace share %.0f%%",
          entry.mode, entry.cardinality, entry.fixed_floor_ms,
          entry.non_grace_overhead_ms, entry.grace_share * 100))
      end
      print("")
    elseif record.name == "runner" then
      for _, turns in ipairs(sorted_keys(record.extra.derived, true)) do
        local entry = record.extra.derived[turns]
        print(string.format("runner: %s turn(s): %.1f us/turn total, %.1f us/turn overhead, provider share %.0f%%",
          turns, entry.total_us_per_turn, entry.overhead_us_per_turn, (entry.provider_share or 0) * 100))
      end
      print("")
    elseif record.name == "orchestration" then
      for _, size in ipairs(sorted_keys(record.extra.derived, true)) do
        local entry = record.extra.derived[size]
        print(string.format("orchestration: %s task(s): %.1f us/task, %d wave(s), %d handoff(s), %d checkpoint(s)",
          size, entry.us_per_task, entry.waves_executed, entry.handoffs, entry.checkpoints))
      end
      print("")
    elseif record.name == "context" then
      for _, size in ipairs(sorted_keys(record.extra.derived, true)) do
        local entry = record.extra.derived[size]
        print(string.format(
          "context: %s slot(s): %.1f us/slot compile, prompt %d bytes, tiers pruned/compressed/truncated %s/%s/%s",
          size, entry.compile_us_per_slot, entry.prompt_bytes,
          tostring(entry.tier1_pruned_scratch), tostring(entry.tier2_compressed_rationale),
          tostring(entry.tier3_truncated_tail)))
      end
      print("")
    end
  end
end

local function print_smoke_result(result)
  print("Release smoke (generous regression ceilings, not a host baseline):")
  for _, check in ipairs(result.checks) do
    print(string.format("  [%s] %-38s %s <= %s",
      check.ok and "PASS" or "FAIL", check.name,
      format_value(check.actual, check.unit),
      format_value(check.ceiling, check.unit)))
  end
  print("")
  print("smoke: " .. (result.passed and "PASS" or "FAIL"))
end

local function build_record(options, environment, records, started_at)
  local scenario_names = {}
  for _, record in ipairs(records) do
    scenario_names[#scenario_names + 1] = record.name
  end
  local config = {
    profile = options.profile,
    warmup = options.warmup or 1,
    samples_override = options.samples,
    scenarios = json.array(scenario_names),
  }
  local record = {
    schema_version = 1,
    generated_at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
    environment = environment,
    config = config,
    scenarios = json.array(records),
  }
  if options.smoke then
    local result = smoke.evaluate(records)
    record.smoke = {
      passed = result.passed,
      checks = json.array(result.checks),
    }
  end
  record.harness_cpu_ms = (os.clock() - started_at) * 1000
  return record
end

local function main(argv)
  local options, parse_error = cli.parse(argv)
  if not options then
    io.stderr:write("bench: " .. parse_error .. "\n\n" .. cli.usage() .. "\n")
    return 2
  end
  if options.help then
    print(cli.usage())
    return 0
  end

  local environment = env.collect(root)
  local generated = {}
  local started_at = os.clock()

  for _, name in ipairs(cli.SCENARIOS) do
    if options.selected[name] then
      local module_ok, scenario = pcall(require, SCENARIO_MODULES[name])
      if not module_ok then
        io.stderr:write("bench: cannot load scenario '" .. name .. "': "
          .. tostring(scenario) .. "\n")
        return 1
      end

      local samples = options.samples
      if samples == nil and options.smoke then
        samples = SMOKE_SAMPLES[name]
      end

      local ctx = {
        profile = options.profile,
        samples = samples,
        warmup = options.warmup or 1,
        environment = environment,
        time = time,
      }

      local ok, record = pcall(scenario.run, ctx)
      if not ok then
        io.stderr:write("bench: scenario '" .. name .. "' failed: " .. tostring(record) .. "\n")
        return 1
      end
      generated[#generated + 1] = record
    end
  end

  local record = build_record(options, environment, generated, started_at)

  if options.format == "json" then
    print(json.encode(record))
  else
    print_environment(environment)
    for _, scenario_record in ipairs(generated) do
      print_scenario(scenario_record)
    end
    print_extras(generated)
    if options.smoke then
      print_smoke_result(smoke.evaluate(generated))
    else
      print("Full suite is manual; use 'just bench-release-smoke' for the bounded regression subset.")
    end
  end

  if options.smoke and not record.smoke.passed then
    return 1
  end
  return 0
end

os.exit(main(arg or {}))
