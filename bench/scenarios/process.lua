-- bench/scenarios/process.lua
-- WheelHost.proc.run_program normal exit and timeout at 1/5/20 calls.
--
-- Every call runs the production bounded wrapper: supervisor, retained
-- session leader, GNU timeout, capture files, and the post-exit sweep grace.
-- The fixed 250 ms sweep grace is therefore part of every sample. The record
-- reports that floor separately from the command's own time so a future
-- empty-group fast path can be evaluated against the same numbers.
--
-- Wall time uses bench.lib.time (10 ms resolution on Linux); per-call values
-- are collected across all calls in all samples, not derived from batch totals.

local stats = require("bench.lib.stats")
local time = require("bench.lib.time")
local WheelHost = require("wheel.host")

local M = {}

M.name = "process"
M.description = "WheelHost.proc.run_program normal exit and timeout"
M.default_samples = 2
M.full_sizes = { 1, 5, 20 }
M.smoke_normal_sizes = { 1, 5 }
M.smoke_timeout_sizes = { 1 }
M.timeout_ms = 50

local function measure_call(mode)
  local started = time.wall()
  local result
  if mode == "normal" then
    result = WheelHost.proc.run_program("true", {})
  else
    result = WheelHost.proc.run_program("sleep", { "1" }, { timeout_ms = M.timeout_ms })
  end
  local elapsed_ms = time.millis(started, time.wall())
  return elapsed_ms, result
end

local function validate(mode, result)
  if mode == "normal" then
    if result.ok ~= true or result.code ~= 0 or result.timed_out then
      return false, string.format("normal call failed: ok=%s code=%s timed_out=%s",
        tostring(result.ok), tostring(result.code), tostring(result.timed_out))
    end
  else
    if result.timed_out ~= true then
      return false, string.format("timeout call did not report a timeout: code=%s outcome=%s",
        tostring(result.code), tostring(result.outcome))
    end
  end
  return true
end

local function summarize(values)
  local summary, summary_error = stats.summarize(values)
  if not summary then
    error(summary_error)
  end
  return stats.round(summary, 3)
end

--- Run the process scenario.
-- @param ctx table
-- @return table
function M.run(ctx)
  local smoke = (ctx.profile == "smoke")
  local samples = ctx.samples or M.default_samples
  local sweep_grace_ms = WheelHost.LIMITS.SWEEP_GRACE_MS
  local series = {}
  local derived = {}
  local cleanup = { swept = 0, unverified = 0, not_run = 0 }

  for _, mode in ipairs({ "normal", "timeout" }) do
    local sizes
    if not smoke then
      sizes = M.full_sizes
    elseif mode == "normal" then
      sizes = M.smoke_normal_sizes
    else
      sizes = M.smoke_timeout_sizes
    end

    for _, size in ipairs(sizes) do
      local calls = {}
      for _ = 1, samples do
        for _ = 1, size do
          local elapsed_ms, result = measure_call(mode)
          local valid, validate_error = validate(mode, result)
          if not valid then
            error(validate_error)
          end
          calls[#calls + 1] = elapsed_ms
          local cleanup_state = result.cleanup or "not_run"
          if cleanup[cleanup_state] ~= nil then
            cleanup[cleanup_state] = cleanup[cleanup_state] + 1
          end
        end
      end

      local summary = summarize(calls)
      series[#series + 1] = {
        name = mode,
        cardinality = size,
        unit = "ms",
        samples = #calls,
        stats = summary,
      }

      local fixed_ms = sweep_grace_ms
      if mode == "timeout" then
        fixed_ms = fixed_ms + M.timeout_ms
      end
      local overhead = summary.median - fixed_ms
      if overhead < 0 then
        overhead = 0
      end
      derived[#derived + 1] = {
        mode = mode,
        cardinality = size,
        fixed_floor_ms = fixed_ms,
        sweep_grace_ms = sweep_grace_ms,
        non_grace_overhead_ms = stats.round({ n = 1, median = overhead }, 3).median,
        grace_share = stats.round({ n = 1, median = sweep_grace_ms / summary.median }, 3).median,
      }
    end
  end

  return {
    name = M.name,
    description = M.description,
    series = series,
    extra = {
      sweep_grace_ms = sweep_grace_ms,
      timeout_ms = M.timeout_ms,
      cleanup = cleanup,
      derived = derived,
      sampling = "wall clock per call; " .. time.wall_source
        .. " at " .. tostring(time.wall_resolution_ms) .. " ms resolution",
    },
    notes = "Each call includes the production post-exit sweep grace; per-call medians are call distributions, not batch totals.",
  }
end

return M
