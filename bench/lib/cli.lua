-- bench/lib/cli.lua
-- Argument parsing for bench/run.lua.
--
-- Parsing is deliberately strict and has no defaults hidden in scenario code:
-- an unknown option, scenario, format, or non-positive sample count is a
-- usage error (exit 2 in run.lua) instead of a silently ignored input. This
-- keeps a malformed CI or release-smoke invocation from reporting a passing
-- benchmark that never ran the requested workload.

local M = {}

M.SCENARIOS = { "activation", "process", "runner", "orchestration", "context" }

local VALID_SCENARIO = {}
for _, name in ipairs(M.SCENARIOS) do
  VALID_SCENARIO[name] = true
end

--- Human-readable usage text.
-- @return string
function M.usage()
  return table.concat({
    "Usage: lua bench/run.lua [options]",
    "",
    "Options:",
    "  --scenario NAME[,NAME]  run only the named scenario(s) (default: all)",
    "  --samples N             timing samples per series (default: scenario specific)",
    "  --warmup N              untimed warm-up samples before each series (default: 1)",
    "  --format human|json     output format (default: human)",
    "  --smoke                 release-smoke profile: bounded subset with ceilings",
    "  -h, --help              show this help",
    "",
    "Scenarios: " .. table.concat(M.SCENARIOS, ", "),
    "",
    "The suite is offline and deterministic: mock providers only, no network,",
    "no credentials, and no live provider latency.",
  }, "\n")
end

local function add_scenario(options, value)
  for name in value:gmatch("[^,]+") do
    if not VALID_SCENARIO[name] then
      return string.format("unknown scenario '%s'; valid scenarios: %s",
        name, table.concat(M.SCENARIOS, ", "))
    end
    if not options.selected[name] then
      options.selected[name] = true
      options.scenarios[#options.scenarios + 1] = name
    end
  end
  return nil
end

local function parse_positive_integer(option, value)
  local number = tonumber(value)
  if number == nil or number % 1 ~= 0 or number < 1 then
    return nil, string.format("%s requires a positive integer, got '%s'", option, tostring(value))
  end
  return number, nil
end

--- Parse an argument vector.
-- @param argv string[]
-- @return table|nil options, string|nil error
function M.parse(argv)
  local options = {
    scenarios = {},
    selected = {},
    samples = nil,
    warmup = nil,
    format = "human",
    profile = "full",
    smoke = false,
    help = false,
  }

  local index = 1
  while index <= #argv do
    local current = argv[index]
    if current == "--help" or current == "-h" then
      options.help = true
      return options
    elseif current == "--smoke" then
      options.smoke = true
      options.profile = "smoke"
    elseif current == "--format" then
      index = index + 1
      local value = argv[index]
      if value ~= "human" and value ~= "json" then
        return nil, "--format must be 'human' or 'json'"
      end
      options.format = value
    elseif current == "--scenario" then
      index = index + 1
      local value = argv[index]
      if type(value) ~= "string" or value == "" then
        return nil, "--scenario requires a name"
      end
      local scenario_error = add_scenario(options, value)
      if scenario_error then
        return nil, scenario_error
      end
    elseif current == "--samples" then
      index = index + 1
      local number, number_error = parse_positive_integer("--samples", argv[index])
      if not number then
        return nil, number_error
      end
      options.samples = number
    elseif current == "--warmup" then
      index = index + 1
      local value = argv[index]
      local number = tonumber(value)
      if number == nil or number % 1 ~= 0 or number < 0 then
        return nil, string.format("--warmup requires a non-negative integer, got '%s'",
          tostring(value))
      end
      options.warmup = number
    elseif current:sub(1, 2) == "--" then
      return nil, string.format("unknown option '%s'", current)
    else
      return nil, string.format("unexpected argument '%s'", current)
    end
    index = index + 1
  end

  if #options.scenarios == 0 then
    for _, name in ipairs(M.SCENARIOS) do
      options.scenarios[#options.scenarios + 1] = name
      options.selected[name] = true
    end
  end

  return options
end

return M
