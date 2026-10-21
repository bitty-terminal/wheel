-- bench/scenarios/context.lua
-- Context slot write/read and Three-Zone compilation at 10/100/1,000 slots.
--
-- Every sample starts from a fresh WheelContext, writes N unique slots from a
-- realistic mix of task, decision, and workspace names, reads them back, and
-- compiles the prompt. N=1,000 exceeds the 64 KiB default budget on purpose,
-- so the compile series exercises the multi-tier reduction pipeline rather
-- than only the fast path.
--
-- Slot writes call the deterministic content hash. On PUC Lua 5.1 without a
-- native bit library, that hash is the pure-Lua SHA-256 fallback and dominates
-- the write cost (about 5 ms per 48-byte slot on the recorded host). Content
-- is therefore kept under the 56-byte one-block boundary and larger
-- cardinalities use fewer samples; the record states the real n for each
-- series. Merkle tree hashing is a separate cost and is not measured here.

local stats = require("bench.lib.stats")
local time = require("bench.lib.time")
local WheelContext = require("wheel.context")

local M = {}

M.name = "context"
M.description = "WheelContext slot write/read and Three-Zone compile"
M.default_samples = 30
M.full_sizes = { 10, 100, 1000 }
M.smoke_sizes = { 10, 100 }
M.samples_by_size = { [10] = 30, [100] = 5, [1000] = 1 }

local function slot_name(index)
  if index % 10 == 0 then
    return string.format("decisions/bench-%04d", index)
  elseif index % 10 == 5 then
    return string.format("workspace/bench-%04d", index)
  end
  return string.format("tasks/bench-%04d/artifacts", index)
end

local function slot_content(index)
  -- One SHA-256 block only (< 56 bytes), including the index prefix.
  return string.format("bench slot %04d ", index) .. string.rep("y", 32)
end

local function measure_once(size)
  local names = {}
  local contents = {}
  for index = 1, size do
    names[index] = slot_name(index)
    contents[index] = slot_content(index)
  end

  local context = WheelContext.new()
  local operations = {}

  local started = time.cpu()
  for index = 1, size do
    local result, put_error = context:put_slot(names[index], contents[index])
    if not result then
      error(string.format("put_slot failed at slot %d: %s", index,
        tostring(put_error and put_error.message or put_error)))
    end
  end
  operations.put_us = time.micros(started, time.cpu())

  started = time.cpu()
  for index = 1, size do
    local result = context:get_slot(names[index])
    if not result.found or result.content ~= contents[index] then
      error(string.format("get_slot returned the wrong content at slot %d", index))
    end
  end
  operations.get_us = time.micros(started, time.cpu())

  started = time.cpu()
  local compiled = context:compile_prompt({
    system_instruction = "Benchmark system instruction for Three-Zone compilation.",
    project_rules = { "Software Engineering domain only", "Fail-closed on security violations" },
    tool_schemas = { "inspect_file", "read_file", "write_file" },
    turn_prompt = "Compile the benchmark context.",
  })
  operations.compile_us = time.micros(started, time.cpu())
  if not compiled or not compiled.success then
    error("compile_prompt failed")
  end
  operations.compiled = compiled

  return operations
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

--- Run the context scenario.
-- @param ctx table
-- @return table
function M.run(ctx)
  local sizes = (ctx.profile == "smoke") and M.smoke_sizes or M.full_sizes
  local collected = {}
  local counts = {}
  local last_compile = {}

  for _, size in ipairs(sizes) do
    local samples = samples_for(ctx, size)
    counts[size] = samples
    collected[size] = { put_us = {}, get_us = {}, compile_us = {} }

    -- Honor the requested warm-up exactly. At 1,000 slots a warm-up would
    -- double the most expensive series for little information, so that one
    -- cardinality deliberately runs cold; the record and README say so.
    local warmup = ctx.warmup
    if size >= 1000 then
      warmup = 0
    end
    for _ = 1, warmup do
      measure_once(size)
    end
    for _ = 1, samples do
      local operations = measure_once(size)
      collected[size].put_us[#collected[size].put_us + 1] = operations.put_us
      collected[size].get_us[#collected[size].get_us + 1] = operations.get_us
      collected[size].compile_us[#collected[size].compile_us + 1] = operations.compile_us
      last_compile[size] = operations.compiled
    end
  end

  local series = {}
  local derived = {}
  for _, size in ipairs(sizes) do
    local definitions = {
      { key = "put_us", name = "put_slot" },
      { key = "get_us", name = "get_slot" },
      { key = "compile_us", name = "compile_prompt" },
    }
    for _, definition in ipairs(definitions) do
      local values = collected[size][definition.key]
      series[#series + 1] = {
        name = definition.name,
        cardinality = size,
        unit = "us",
        samples = #values,
        stats = summarize(values),
      }
    end

    local compiled = last_compile[size]
    derived[tostring(size)] = {
      samples = counts[size],
      compile_us_per_slot = stats.round({
        n = 1,
        median = summarize(collected[size].compile_us).median / size,
      }, 3).median,
      prompt_bytes = compiled.total_bytes,
      zone1_bytes = compiled.zone1_bytes,
      zone2_bytes = compiled.zone2_bytes,
      zone3_bytes = compiled.zone3_bytes,
      tier1_pruned_scratch = compiled.tiers_applied.tier1_pruned_scratch,
      tier2_compressed_rationale = compiled.tiers_applied.tier2_compressed_rationale,
      tier3_truncated_tail = compiled.tiers_applied.tier3_truncated_tail,
    }
  end

  return {
    name = M.name,
    description = M.description,
    series = series,
    extra = {
      derived = derived,
      sampling = "cpu=os.clock per operation batch; context construction excluded",
      samples_by_size = M.samples_by_size,
      max_budget_bytes = WheelContext.MAX_TOTAL_BUDGET_BYTES,
    },
    notes = "N=1,000 exceeds the default 64 KiB budget; writes include the pure-Lua SHA-256 content hash at one block per slot.",
  }
end

return M
