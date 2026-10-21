-- tests/test_bench.lua
-- Unit and offline integration tests for the benchmark harness (CTX-0025).
--
-- Covers the statistics definitions, strict argument parsing, deterministic
-- JSON encoding, fail-closed malformed-scenario behavior, and one short
-- context-scenario run in JSON mode. It performs no network, provider, or
-- process-primitive work, so it can join `just check` cheaply.

package.path = "./lua/?.lua;./lua/?/init.lua;./?.lua;./?/init.lua;" .. package.path

local stats = require("bench.lib.stats")
local json = require("bench.lib.json")
local cli = require("bench.lib.cli")
local smoke = require("bench.lib.smoke")

local function run_test(name, fn)
  local ok, err = pcall(fn)
  if ok then
    print("[PASS] " .. name)
  else
    print("[FAIL] " .. name .. ": " .. tostring(err))
    os.exit(1)
  end
end

local function near(actual, expected)
  return math.abs(actual - expected) < 1e-9
end

local function shell_quote(value)
  return "'" .. tostring(value or ""):gsub("'", "'\\''") .. "'"
end

local interpreter = (arg and arg[-1]) or os.getenv("WHEEL_BENCH_LUA") or "lua5.1"

local function run_bench(arguments)
  local command = shell_quote(interpreter) .. " " .. shell_quote("bench/run.lua")
    .. " " .. arguments .. " 2>&1; printf '\\nEXIT:%d' $?"
  local pipe = io.popen(command, "r")
  assert(pipe, "cannot launch bench/run.lua")
  local output = pipe:read("*a")
  pipe:close()
  local body, code = output:match("^(.-)\nEXIT:(%d+)$")
  body = (body or output):match("^%s*(.-)%s*$") or ""
  return body, tonumber(code)
end

-- ===========================================================================
-- 1. Statistics
-- ===========================================================================

run_test("stats: odd-sized series", function()
  local summary = assert(stats.summarize({ 5, 1, 3 }))
  assert(summary.n == 3)
  assert(summary.min == 1 and summary.max == 5)
  assert(summary.median == 3)
  assert(summary.p95 == 5, "p95 must use nearest rank")
  assert(summary.q1 == 1 and summary.q3 == 5)
  assert(summary.iqr == 4)
  assert(near(summary.mean, 3))
end)

run_test("stats: even-sized series and quartiles", function()
  local summary = assert(stats.summarize({ 4, 1, 3, 2 }))
  assert(summary.n == 4)
  assert(summary.median == 2.5, "even median must average the middle pair")
  assert(summary.p95 == 4)
  assert(summary.q1 == 1 and summary.q3 == 3)
  assert(summary.iqr == 2)
end)

run_test("stats: single sample", function()
  local summary = assert(stats.summarize({ 7 }))
  assert(summary.n == 1)
  assert(summary.min == 7 and summary.median == 7 and summary.p95 == 7 and summary.max == 7)
  assert(summary.iqr == 0)
end)

run_test("stats: rejects empty and non-numeric samples", function()
  local summary, err = stats.summarize({})
  assert(summary == nil and err ~= nil, "empty series must be rejected")
  local bad, bad_err = stats.summarize({ 1, "2" })
  assert(bad == nil and bad_err ~= nil, "non-numeric sample must be rejected")
  local nan, nan_err = stats.summarize({ 0 / 0 })
  assert(nan == nil and nan_err ~= nil, "NaN must be rejected")
end)

run_test("stats: rounding and ratio guard", function()
  local rounded = stats.round({ n = 3, median = 1.23456, p95 = 9.87654 }, 2)
  assert(rounded.n == 3)
  assert(rounded.median == 1.23 and rounded.p95 == 9.88)
  assert(stats.ratio({ median = 4 }, { median = 2 }) == 2)
  assert(stats.ratio({ median = 4 }, { median = 0 }) == nil)
end)

-- ===========================================================================
-- 2. Argument parsing
-- ===========================================================================

run_test("cli: defaults select every scenario in canonical order", function()
  local options = assert(cli.parse({}))
  assert(options.format == "human")
  assert(options.profile == "full")
  assert(#options.scenarios == #cli.SCENARIOS)
  for index, name in ipairs(cli.SCENARIOS) do
    assert(options.scenarios[index] == name)
    assert(options.selected[name] == true)
  end
end)

run_test("cli: scenario selection, dedupe, and overrides", function()
  local options = assert(cli.parse({
    "--scenario", "runner,context",
    "--scenario", "runner",
    "--samples", "7",
    "--warmup", "0",
    "--format", "json",
  }))
  assert(#options.scenarios == 2)
  assert(options.scenarios[1] == "runner" and options.scenarios[2] == "context")
  assert(options.selected.activation == nil)
  assert(options.samples == 7)
  assert(options.warmup == 0)
  assert(options.format == "json")
end)

run_test("cli: smoke profile flag", function()
  local options = assert(cli.parse({ "--smoke" }))
  assert(options.smoke == true)
  assert(options.profile == "smoke")
end)

run_test("cli: help short-circuits", function()
  local options = assert(cli.parse({ "--help" }))
  assert(options.help == true)
end)

run_test("cli: malformed options fail closed", function()
  local cases = {
    { { "--scenario", "nope" }, "unknown scenario" },
    { { "--scenario" }, "requires a name" },
    { { "--format", "xml" }, "--format" },
    { { "--samples", "0" }, "positive integer" },
    { { "--samples", "two" }, "positive integer" },
    { { "--samples" }, "positive integer" },
    { { "--warmup", "-1" }, "non-negative" },
    { { "--bogus" }, "unknown option" },
    { { "extra" }, "unexpected argument" },
  }
  for _, case in ipairs(cases) do
    local options, err = cli.parse(case[1])
    assert(options == nil, "expected rejection for: " .. table.concat(case[1], " "))
    assert(type(err) == "string" and err:find(case[2], 1, true) ~= nil,
      "unexpected error: " .. tostring(err))
  end
end)

-- ===========================================================================
-- 3. JSON encoding
-- ===========================================================================

run_test("json: deterministic sorted keys, arrays, and escapes", function()
  local encoded = json.encode({
    b = 1,
    a = "line\n\"quote\"",
    values = json.array({ 1, 2, 3 }),
    empty = json.array({}),
    nested = { z = true },
  })
  assert(encoded == '{"a":"line\\n\\"quote\\"","b":1,"empty":[],"nested":{"z":true},"values":[1,2,3]}',
    "unexpected JSON: " .. encoded)
end)

run_test("json: numbers and control characters", function()
  assert(json.encode({ n = 1.5, i = 42 }) == '{"i":42,"n":1.5}')
  assert(json.encode({ s = "\1" }) == '{"s":"\\u0001"}')
  assert(json.encode({ bad = 0 / 0 }) == '{"bad":null}')
end)

-- ===========================================================================
-- 4. Fail-closed CLI integration
-- ===========================================================================

run_test("bench: unknown scenario exits 2 with a clear message", function()
  local output, code = run_bench("--scenario nope")
  assert(code == 2, "expected usage exit code 2, got " .. tostring(code))
  assert(output:find("unknown scenario 'nope'", 1, true) ~= nil,
    "missing failure message: " .. output)
end)

run_test("bench: invalid sample count exits 2", function()
  local output, code = run_bench("--samples 0")
  assert(code == 2, "expected usage exit code 2, got " .. tostring(code))
  assert(output:find("positive integer", 1, true) ~= nil, "missing failure message: " .. output)
end)

run_test("bench: help exits 0 and lists the scenarios", function()
  local output, code = run_bench("--help")
  assert(code == 0, "expected exit 0, got " .. tostring(code))
  assert(output:find("Usage: lua bench/run.lua", 1, true) ~= nil, output)
  for _, name in ipairs(cli.SCENARIOS) do
    assert(output:find(name, 1, true) ~= nil, "help must list " .. name)
  end
end)

-- ===========================================================================
-- 5. Short offline integration run
-- ===========================================================================

run_test("bench: context scenario emits a machine-readable record", function()
  local output, code = run_bench(
    "--scenario context --samples 1 --format json")
  assert(code == 0, "expected exit 0, got " .. tostring(code) .. ": " .. output)
  assert(output:sub(1, 1) == "{", "JSON record must start with an object")
  assert(output:sub(-1) == "}", "JSON record must end with an object")
  for _, needle in ipairs({
    '"schema_version":1',
    '"scenarios":["context"]',
    '"name":"context"',
    '"compile_prompt"',
    '"environment"',
    '"interpreter"',
    '"revision"',
  }) do
    assert(output:find(needle, 1, true) ~= nil, "missing JSON field " .. needle)
  end
  assert(output:find("EXIT", 1, true) == nil, "exit marker leaked into JSON")
end)

run_test("bench: activation scenario uses the fresh-process path", function()
  local output, code = run_bench(
    "--scenario activation --samples 1 --warmup 0 --format json")
  assert(code == 0, "expected exit 0, got " .. tostring(code) .. ": " .. output)
  assert(output:find('"cold_cpu"', 1, true) ~= nil, "missing cold series")
  assert(output:find('"cold_instructions"', 1, true) ~= nil, "missing cold instruction series")
  assert(output:find('"registrations":14', 1, true) ~= nil, "activation must register the 14 commands")
end)

run_test("bench: empty or subset smoke invocations fail closed", function()
  local output, code = run_bench(
    "--smoke --scenario context --samples 1 --format json")
  assert(code == 2, "smoke subset must be rejected, got " .. tostring(code) .. ": " .. output)
  local empty_output, empty_code = run_bench("--scenario , --samples 1 --format json")
  assert(empty_code == 2,
    "empty scenario selector must be rejected, got " .. tostring(empty_code) .. ": " .. empty_output)
  local mixed_output, mixed_code = run_bench(
    "--scenario activation --scenario , --samples 1 --format json")
  assert(mixed_code == 2,
    "a later empty selector must be rejected, got " .. tostring(mixed_code) .. ": " .. mixed_output)
end)

run_test("bench: smoke evaluation rejects missing groups and failing ceilings", function()
  local empty = smoke.evaluate({})
  assert(empty.passed == false, "empty smoke evidence must not pass")
  local record = {
    {
      name = "activation",
      series = {
        { name = "cold_cpu", cardinality = nil, stats = { median = 60000, p95 = 60000 } },
        { name = "warm_cpu", cardinality = nil, stats = { median = 60000, p95 = 60000 } },
        { name = "warm_instructions", cardinality = nil, stats = { median = 20000000, p95 = 20000000 } },
      },
    },
  }
  local evaluation = smoke.evaluate(record)
  assert(evaluation.passed == false, "a failing/missing smoke check must fail")
  local empty_groups = {}
  for _, name in ipairs({ "activation", "process", "runner", "orchestration", "context" }) do
    empty_groups[#empty_groups + 1] = { name = name, series = {} }
  end
  assert(smoke.evaluate(empty_groups).passed == false,
    "present but empty smoke groups must fail")
  local mixed_groups = {}
  for _, name in ipairs({ "activation", "process", "runner", "orchestration", "context" }) do
    if name == "activation" then
      mixed_groups[#mixed_groups + 1] = record[1]
    else
      mixed_groups[#mixed_groups + 1] = { name = name, series = {} }
    end
  end
  assert(smoke.evaluate(mixed_groups).passed == false,
    "a populated group plus empty groups must fail")
  local failed = 0
  for _, check in ipairs(evaluation.checks) do
    if not check.ok then failed = failed + 1 end
  end
  assert(failed > 0, "expected at least one failed smoke check")
end)

print("[PASS] all benchmark harness tests")
