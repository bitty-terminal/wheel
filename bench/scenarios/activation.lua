-- bench/scenarios/activation.lua
-- Cold and warm entry-point activation (wheel#86 / CTX-0025).
--
-- Cold samples run in a fresh interpreter process through the hidden
-- `--child-cold` mode of bench/run.lua, so process startup is outside the
-- measured region but module loading and registration are inside it. Warm
-- samples clear every wheel.* / lua.wheel.* module and re-require the entry in
-- this process with a warm OS page cache.
--
-- CPU time comes from os.clock(). Instruction counts come from separate
-- instrumented runs because a debug count hook inflates CPU time and must not
-- be mixed into the timing series.

local stats = require("bench.lib.stats")

local M = {}

M.name = "activation"
M.description = "require(\"wheel\") cold and warm, CPU time and VM instructions"
M.default_samples = 30
M.instrument_samples = 5

M.RC1 = {
  instruction_budget = 10000000,
  cpu_budget_ms = 50,
  warning_ms = 8,
}

local function shell_quote(value)
  return "'" .. tostring(value or ""):gsub("'", "'\\''") .. "'"
end

local function clear_wheel_modules()
  for name in pairs(package.loaded) do
    if name == "wheel"
      or name:match("^wheel%.") ~= nil
      or name:match("^lua%.wheel") ~= nil then
      package.loaded[name] = nil
    end
  end
end

local function install_host_double(counter)
  _G.bitty = {
    commands = {
      register = function()
        counter.registrations = counter.registrations + 1
        return 0
      end,
    },
    notify = {
      show = function()
        return true
      end,
    },
  }
end

local function require_entry(instrument)
  local counter = { registrations = 0 }
  clear_wheel_modules()
  install_host_double(counter)

  local instructions = 0
  if instrument then
    if type(debug) ~= "table" or type(debug.sethook) ~= "function" then
      error("instruction counting requires the debug library")
    end
    debug.sethook(function()
      instructions = instructions + 1
    end, "", 1)
  end

  local started = os.clock()
  local ok, module = pcall(require, "wheel")
  local cpu_micros = (os.clock() - started) * 1000000
  if instrument then
    debug.sethook()
  end
  if not ok then
    error("activation failed: " .. tostring(module))
  end

  local catalog_size = 0
  if type(module.command_catalog) == "table" then
    catalog_size = #module.command_catalog
  end
  if counter.registrations ~= catalog_size then
    error(string.format(
      "activation registered %d command(s) but the catalog has %d",
      counter.registrations, catalog_size))
  end

  return cpu_micros, instructions, counter.registrations, catalog_size
end

local function run_child(instrument)
  local interpreter = arg and arg[-1]
  local script = arg and arg[0]
  if type(interpreter) ~= "string" or type(script) ~= "string" then
    return nil, "cold activation requires an interpreter and a script path in arg"
  end

  local command = shell_quote(interpreter) .. " " .. shell_quote(script) .. " --child-cold"
  if instrument then
    command = command .. " --instrument"
  end

  local pipe = io.popen(command, "r")
  if not pipe then
    return nil, "cannot launch the cold activation child"
  end
  local output = pipe:read("*a")
  pipe:close()

  local micros, instructions, registrations, catalog =
    output:match("WHEEL%-BENCH%-COLD\t([%d%.]+)\t(%d+)\t(%d+)\t(%d+)")
  if not micros then
    return nil, "cold activation child produced no result record"
  end
  return {
    cpu_micros = tonumber(micros),
    instructions = tonumber(instructions),
    registrations = tonumber(registrations),
    catalog_size = tonumber(catalog),
  }
end

--- Run one cold activation in this (fresh) process; used by --child-cold.
-- @param instrument boolean
function M.child_main(instrument)
  local micros, instructions, registrations, catalog = require_entry(instrument)
  io.write(string.format("WHEEL-BENCH-COLD\t%.0f\t%d\t%d\t%d\n",
    micros, instructions, registrations, catalog))
end

--- Run the activation scenario.
-- @param ctx table
-- @return table
function M.run(ctx)
  local samples = ctx.samples or M.default_samples
  local instrument_samples = math.min(M.instrument_samples, samples)
  local warm_cpu = {}
  local cold_cpu = {}
  local warm_instructions = {}
  local cold_instructions = {}
  local registrations = nil
  local catalog_size = nil

  -- Warm-up activation (untimed) keeps first-use allocator effects out of the
  -- warm series. Cold samples always start a fresh process.
  for _ = 1, ctx.warmup do
    require_entry(false)
  end

  for _ = 1, samples do
    local record, child_error = run_child(false)
    if not record then
      error(child_error)
    end
    cold_cpu[#cold_cpu + 1] = record.cpu_micros
    registrations = record.registrations
    catalog_size = record.catalog_size
  end

  for _ = 1, samples do
    local micros, _, registered, catalog = require_entry(false)
    warm_cpu[#warm_cpu + 1] = micros
    registrations = registered
    catalog_size = catalog
  end

  for _ = 1, instrument_samples do
    local record, child_error = run_child(true)
    if not record then
      error(child_error)
    end
    cold_instructions[#cold_instructions + 1] = record.instructions
  end

  for _ = 1, instrument_samples do
    local _, instructions = require_entry(true)
    warm_instructions[#warm_instructions + 1] = instructions
  end

  local function series(name, unit, values)
    local summary, summary_error = stats.summarize(values)
    if not summary then
      error(name .. ": " .. summary_error)
    end
    return {
      name = name,
      unit = unit,
      samples = #values,
      stats = stats.round(summary, 3),
    }
  end

  return {
    name = M.name,
    description = M.description,
    series = {
      series("cold_cpu", "us", cold_cpu),
      series("warm_cpu", "us", warm_cpu),
      series("cold_instructions", "instructions", cold_instructions),
      series("warm_instructions", "instructions", warm_instructions),
    },
    extra = {
      rc1 = M.RC1,
      registrations = registrations,
      catalog_size = catalog_size,
      cold_processes = samples,
      sampling = "cpu=os.clock; cold=fresh process per sample; warm=package.loaded cleared per sample",
    },
    notes = "Instruction series are separate instrumented runs; the count hook inflates CPU time.",
  }
end

return M
