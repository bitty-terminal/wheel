-- Real-host activation and command-smoke fixture (CTX-0017 / wheel#53).
--
-- Boundary:
--   * The standalone harness process is the real host boundary. No Bitty
--     plugin VM, plugin loader, or plugin capability grant is involved.
--   * `_G.bitty` is a presentation-only double with exactly
--     `commands.register` and `notify.show`. It is not a filesystem, process,
--     temporary-file, network, or time mock.
--   * Every filesystem, process, temporary-file, wall-clock, and CPU-time
--     operation in the harness under test is real OS behavior through
--     `WheelHost` and its standalone POSIX backend.
--   * Bootstrap exception: Lua 5.1 has no os.setenv, so the parent process
--     creates the ephemeral base with real shell commands and re-executes the
--     child with a private environment. The parent performs no harness
--     operation and is not part of the measured boundary.
--
-- Measurements:
--   * cold = first activation in this process.
--   * warm = a later activation after the Wheel module state is cleared; the
--     OS page cache is warm.
--   * CPU time = os.clock() (process CPU seconds), not elapsed wall clock.
--   * instructions = a debug.sethook count hook, interval 1, around the
--     activation require.
--   * RC-1 budget = 10^7 VM instructions and 50 ms CPU; 8 ms soft warning.
--
-- Limitations (documented in README.md):
--   * offline; no network, credentials, release claim, or plugin-VM evidence.
--   * no process timeout, cancellation, process-group, or scrubbed-environment
--     bounds (CTX-0016).
--   * no OS sandbox or Bitty panel/terminal presentation run.
--   * single host and one interpreter per run; CPU frequency is not pinned.

package.path = "./lua/?.lua;./lua/?/init.lua;" .. package.path

local RC1_INSTRUCTION_BUDGET = 10000000
local RC1_CPU_BUDGET_SECONDS = 0.050
local RC1_WARNING_SECONDS = 0.008
local WARM_ACTIVATIONS = 5
local INSTRUMENTED_ACTIVATIONS = 5
local EVIDENCE_PATH = "recording/real-host-2026-10-21.md"

local EXPECTED_COMMAND_IDS = {
  "hello",
  "status",
  "graph",
  "plan",
  "run",
  "trust",
  "team",
  "context",
  "tools",
  "orchestrate",
  "models",
  "branch",
  "checkpoint",
  "reflog",
}

local EAGER_MODULE_NAMES = {
  "errors",
  "schema",
  "commands",
  "kernel",
  "ui",
}

local LAZY_MODULE_NAMES = {
  "agent",
  "config",
  "team",
  "context",
  "tool",
  "provider",
  "runner",
  "host",
}

-- ---------------------------------------------------------------------------
-- Bootstrap: Lua 5.1 has no os.setenv, so the fixture re-executes itself once
-- with a private base, XDG directories, and HOME in the child environment.
-- The parent only creates the ephemeral base and launches the child; every
-- harness operation below runs in the child after the environment is set.
-- ---------------------------------------------------------------------------

local function shell_quote(value)
  local quoted = tostring(value or ""):gsub("'", "'\\''")
  return "'" .. quoted .. "'"
end

local function normalize_exit(status)
  if status == true then
    return 0
  end
  if type(status) ~= "number" then
    return 1
  end
  if status >= 256 then
    return math.floor(status / 256)
  end
  return status
end

local function bootstrap_child()
  local scratch_root = os.getenv("WHEEL_REAL_HOST_SCRATCH") or "/tmp/bitty"
  local mkdir_status = normalize_exit(os.execute("mkdir -p " .. shell_quote(scratch_root)))
  if mkdir_status ~= 0 then
    io.stderr:write("real-host fixture: cannot create the scratch root\n")
    os.exit(1)
  end

  local pipe = io.popen("mktemp -d " .. shell_quote(scratch_root .. "/real-host.XXXXXX"))
  if not pipe then
    io.stderr:write("real-host fixture: cannot create an ephemeral base\n")
    os.exit(1)
  end
  local base = pipe:read("*l")
  pipe:close()
  if type(base) ~= "string" or base == "" then
    io.stderr:write("real-host fixture: mktemp returned no base directory\n")
    os.exit(1)
  end

  local interpreter = (arg and arg[-1]) or "lua5.1"
  local script = (arg and arg[0]) or "tests/real_host_fixture.lua"
  local command = table.concat({
    "env",
    "WHEEL_REAL_HOST_BASE=" .. shell_quote(base),
    "WHEEL_REAL_HOST_OWNED=1",
    "XDG_RUNTIME_DIR=" .. shell_quote(base .. "/runtime"),
    "XDG_CONFIG_HOME=" .. shell_quote(base .. "/config"),
    "XDG_STATE_HOME=" .. shell_quote(base .. "/state"),
    "HOME=" .. shell_quote(base .. "/home"),
    shell_quote(interpreter),
    shell_quote(script),
  }, " ")

  local status = normalize_exit(os.execute(command))
  if status ~= 0 then
    io.stderr:write("real-host fixture failed; ephemeral base retained at " .. base .. "\n")
  end
  os.exit(status)
end

if not os.getenv("WHEEL_REAL_HOST_BASE") or os.getenv("WHEEL_REAL_HOST_BASE") == "" then
  bootstrap_child()
end

local BASE = os.getenv("WHEEL_REAL_HOST_BASE")
local OWNS_BASE = os.getenv("WHEEL_REAL_HOST_OWNED") == "1"
local RUNTIME_DIR = os.getenv("XDG_RUNTIME_DIR")
local WheelHost = nil

-- ---------------------------------------------------------------------------
-- Assertions and measurement records
-- ---------------------------------------------------------------------------

local state = {
  checks = 0,
  series = {},
  coverage = {},
  warnings = {},
}

local function check(condition, message)
  state.checks = state.checks + 1
  if not condition then
    error("real-host assertion failed: " .. tostring(message), 0)
  end
end

local function record(label, metric, value)
  check(type(value) == "number" and value >= 0, "invalid " .. metric .. " sample for " .. label)
  state.series[#state.series + 1] = {
    label = label,
    metric = metric,
    value = value,
  }
end

local function clear_wheel_modules()
  local names = {}
  for name in pairs(package.loaded) do
    if name == "wheel"
      or name:match("^wheel%.") ~= nil
      or name == "lua.wheel"
      or name:match("^lua%.wheel%.") ~= nil then
      names[#names + 1] = name
    end
  end
  for _, name in ipairs(names) do
    package.loaded[name] = nil
  end
end

-- The only host double: presentation and input, never execution authority.
local function new_presentation()
  local capture = {
    order = {},
    registrations = {},
    notifications = {},
  }
  local host = {
    commands = {
      register = function(def)
        check(type(def) == "table" and type(def.id) == "string",
          "a command registration must carry an id")
        check(capture.registrations[def.id] == nil,
          "duplicate command registration: " .. tostring(def.id))
        capture.registrations[def.id] = def
        capture.order[#capture.order + 1] = def.id
        return #capture.order
      end,
    },
    notify = {
      show = function(payload)
        capture.notifications[#capture.notifications + 1] = payload
        return true
      end,
    },
  }
  return host, capture
end

local function assert_catalog(capture, label)
  check(#capture.order == #EXPECTED_COMMAND_IDS,
    string.format("%s: expected %d registrations, got %d",
      label, #EXPECTED_COMMAND_IDS, #capture.order))

  local registered = 0
  for _ in pairs(capture.registrations) do
    registered = registered + 1
  end
  check(registered == #EXPECTED_COMMAND_IDS,
    string.format("%s: expected %d unique registrations, got %d",
      label, #EXPECTED_COMMAND_IDS, registered))

  for index, expected_id in ipairs(EXPECTED_COMMAND_IDS) do
    local actual_id = capture.order[index]
    check(actual_id == expected_id,
      string.format("%s: registration %d must be %s, got %s",
        label, index, expected_id, tostring(actual_id)))

    local def = capture.registrations[expected_id]
    check(def ~= nil, label .. ": missing registration " .. expected_id)
    check(type(def.run) == "function", label .. ": handler is missing for " .. expected_id)
    check(type(def.args_schema) == "table", label .. ": args_schema is missing for " .. expected_id)
    check(def.args_schema.type == "object" and def.args_schema.additionalProperties == false
      and def.args_schema.properties == nil,
      label .. ": args_schema must stay closed and property-free for " .. expected_id)
    check(type(def.result_schema) == "table"
      and type(def.result_schema.properties) == "table"
      and type(def.result_schema.properties.title) == "table"
      and type(def.result_schema.properties.body) == "table",
      label .. ": result_schema must stay the title/body contract for " .. expected_id)
  end
end

local function assert_activation_state(label)
  check(package.loaded["wheel"] ~= nil, label .. ": the entry module must be loaded")
  for _, name in ipairs(EAGER_MODULE_NAMES) do
    check(package.loaded["wheel." .. name] ~= nil,
      label .. ": eager module not loaded: wheel." .. name)
  end
  for _, name in ipairs(LAZY_MODULE_NAMES) do
    check(package.loaded["wheel." .. name] == nil,
      label .. ": lazy module loaded eagerly: wheel." .. name)
  end
end

local function activate_uninstrumented(label)
  collectgarbage("collect")
  clear_wheel_modules()
  local host, capture = new_presentation()
  _G.bitty = host
  local started = os.clock()
  local ok, wheel = pcall(require, "wheel")
  local elapsed = os.clock() - started
  check(ok, label .. ": activation failed: " .. tostring(wheel))
  assert_catalog(capture, label)
  assert_activation_state(label)
  return wheel, capture, elapsed
end

local function activate_instrumented(label)
  check(type(debug) == "table" and type(debug.sethook) == "function",
    "debug.sethook is required for the instruction count")
  collectgarbage("collect")
  clear_wheel_modules()
  local host, capture = new_presentation()
  _G.bitty = host

  local instructions = 0
  local function count_hook()
    instructions = instructions + 1
  end

  debug.sethook(count_hook, "", 1)
  local ok, wheel = pcall(require, "wheel")
  debug.sethook()

  check(ok, label .. ": instrumented activation failed: " .. tostring(wheel))
  check(instructions > 0, label .. ": the instruction hook observed no instructions")
  assert_catalog(capture, label)
  assert_activation_state(label)
  return wheel, capture, instructions
end

local function assert_budget()
  for _, sample in ipairs(state.series) do
    if sample.metric == "cpu" then
      check(sample.value < RC1_CPU_BUDGET_SECONDS,
        string.format("%s: %.3f ms CPU exceeds the 50 ms RC-1 budget",
          sample.label, sample.value * 1000))
      if sample.value >= RC1_WARNING_SECONDS then
        local warning = string.format("%s: %.3f ms CPU crossed the 8 ms RC-1 warning",
          sample.label, sample.value * 1000)
        state.warnings[#state.warnings + 1] = warning
        print("[WARN] " .. warning)
      end
    elseif sample.metric == "instructions" then
      check(sample.value < RC1_INSTRUCTION_BUDGET,
        string.format("%s: %d instructions exceed the 10^7 RC-1 budget",
          sample.label, sample.value))
    end
  end
end

local function stats_for(metric, prefix)
  local values = {}
  for _, sample in ipairs(state.series) do
    if sample.metric == metric and sample.label:sub(1, #prefix) == prefix then
      values[#values + 1] = sample.value
    end
  end
  if #values == 0 then
    return nil
  end
  table.sort(values)
  return {
    count = #values,
    min = values[1],
    -- Upper median for an even count; the series is small and recorded
    -- verbatim beside this summary.
    median = values[math.ceil(#values / 2)],
    max = values[#values],
  }
end

-- ---------------------------------------------------------------------------
-- Evidence
-- ---------------------------------------------------------------------------

local function trim(value)
  local text = tostring(value or "")
  text = text:gsub("^%s+", "")
  text = text:gsub("%s+$", "")
  return text
end

local function md_cell(value)
  local text = tostring(value or "")
  text = text:gsub("|", "\\|")
  text = text:gsub("[\r\n]+", " ")
  return text
end

local function format_ms(seconds)
  return string.format("%.3f", seconds * 1000)
end

local function environment_info()
  local info = {
    interpreter = _VERSION,
  }
  if type(jit) == "table" and jit.version then
    info.interpreter = info.interpreter .. " / " .. jit.version
  end

  local interpreter_path = (arg and arg[-1]) or "lua"
  local version_probe = WheelHost.proc.run_program(interpreter_path, { "-v" }, { merge_stderr = true })
  if version_probe.ok then
    local probe_text = trim((version_probe.stdout or "") .. (version_probe.stderr or ""))
    if probe_text ~= "" then
      info.interpreter = info.interpreter .. " (" .. probe_text .. ")"
    end
  end

  local cpuinfo = WheelHost.fs.read_file("/proc/cpuinfo")
  local cpu_model = cpuinfo and cpuinfo:match("model name%s*:%s*([^\n]+)")
  info.cpu = trim(cpu_model or "unavailable")

  local os_release = WheelHost.fs.read_file("/etc/os-release")
  local pretty_name = os_release and os_release:match('PRETTY_NAME="([^"]+)"')
  local uname = WheelHost.proc.run_program("uname", { "-srm" })
  local uname_text = (uname.ok and trim(uname.stdout)) or ""
  if pretty_name and uname_text ~= "" then
    info.os = pretty_name .. " / " .. uname_text
  else
    info.os = pretty_name or uname_text
  end
  if info.os == "" then
    info.os = "unavailable"
  end

  local revision = WheelHost.proc.run_program("git", { "rev-parse", "HEAD" }, { discard_stderr = true })
  if revision.ok and revision.code == 0 then
    info.revision = trim(revision.stdout)
  else
    info.revision = "unavailable"
  end
  if info.revision == "" then
    info.revision = "unavailable"
  end

  return info
end

local function build_evidence(status, failure)
  local info = environment_info()
  local lines = {
    "# Real-host activation and command-smoke evidence (2026-10-21)",
    "",
    "Status: " .. status .. " durable scratch evidence for CTX-0017 / wheel#53.",
    "It is implementation evidence, not a canonical specification, not a release",
    "claim, and not a plugin-VM or Bitty-host result.",
    "",
  }

  if failure then
    lines[#lines + 1] = "Failure: `" .. md_cell(failure) .. "`"
    lines[#lines + 1] = ""
  end

  lines[#lines + 1] = "## Environment"
  lines[#lines + 1] = ""
  lines[#lines + 1] = "| Item | Value |"
  lines[#lines + 1] = "| --- | --- |"
  lines[#lines + 1] = "| wheel revision | `" .. md_cell(info.revision) .. "` |"
  lines[#lines + 1] = "| interpreter | " .. md_cell(info.interpreter) .. " |"
  lines[#lines + 1] = "| CPU | " .. md_cell(info.cpu) .. " |"
  lines[#lines + 1] = "| OS | " .. md_cell(info.os) .. " |"
  lines[#lines + 1] = "| host boundary | standalone harness process (Option B); no plugin VM |"
  lines[#lines + 1] = "| RC-1 budget | 10^7 VM instructions / 50 ms CPU; 8 ms warning |"
  lines[#lines + 1] = ""

  lines[#lines + 1] = "## Activation series"
  lines[#lines + 1] = ""
  lines[#lines + 1] = "| Run | Metric | Value | Budget sample |"
  lines[#lines + 1] = "| --- | --- | --- | --- |"
  for _, sample in ipairs(state.series) do
    if sample.metric == "cpu" then
      lines[#lines + 1] = string.format("| `%s` | CPU time | %s ms | yes |",
        md_cell(sample.label), format_ms(sample.value))
    else
      lines[#lines + 1] = string.format("| `%s` | VM instructions | %d | yes |",
        md_cell(sample.label), sample.value)
    end
  end
  lines[#lines + 1] = ""

  local cpu_cold = stats_for("cpu", "cold")
  local cpu_warm = stats_for("cpu", "warm")
  local instr_cold = stats_for("instructions", "cold")
  local instr_warm = stats_for("instructions", "warm")

  local function stat_line(label, stats, format_value)
    if not stats then
      return "- " .. label .. ": no samples"
    end
    local sample_word = stats.count == 1 and "sample" or "samples"
    return string.format("- %s: %s (%d %s; min %s, median %s, max %s)",
      label, format_value(stats.median), stats.count, sample_word,
      format_value(stats.min), format_value(stats.median), format_value(stats.max))
  end

  lines[#lines + 1] = "## Summary"
  lines[#lines + 1] = ""
  lines[#lines + 1] = "Cold activation is the first require in this process. Warm"
  lines[#lines + 1] = "activation clears the Wheel module state and requires the entry"
  lines[#lines + 1] = "again; the OS page cache is warm. CPU time is os.clock()"
  lines[#lines + 1] = "(process CPU, not elapsed wall clock). Instruction counts come"
  lines[#lines + 1] = "from separate instrumented runs; their CPU time is not a budget"
  lines[#lines + 1] = "sample because the count hook inflates it."
  lines[#lines + 1] = ""
  lines[#lines + 1] = stat_line("cold CPU", cpu_cold, function(value)
    return format_ms(value) .. " ms"
  end)
  lines[#lines + 1] = stat_line("warm CPU", cpu_warm, function(value)
    return format_ms(value) .. " ms"
  end)
  lines[#lines + 1] = stat_line("cold instructions", instr_cold, function(value)
    return string.format("%d", value)
  end)
  lines[#lines + 1] = stat_line("warm instructions", instr_warm, function(value)
    return string.format("%d", value)
  end)
  if #state.warnings == 0 then
    lines[#lines + 1] = "- 8 ms warnings: none"
  else
    for _, warning in ipairs(state.warnings) do
      lines[#lines + 1] = "- 8 ms warning: " .. md_cell(warning)
    end
  end
  lines[#lines + 1] = ""

  lines[#lines + 1] = "## Coverage"
  lines[#lines + 1] = ""
  for _, item in ipairs(state.coverage) do
    lines[#lines + 1] = "- " .. item
  end
  lines[#lines + 1] = ""

  lines[#lines + 1] = "## Boundary and evidence limits"
  lines[#lines + 1] = ""
  lines[#lines + 1] = "- The only host double is the `bitty` presentation table"
  lines[#lines + 1] = "  (`commands.register`, `notify.show`). It is not an"
  lines[#lines + 1] = "  fs/process/temp/time mock; no plugin loader or plugin VM ran."
  lines[#lines + 1] = "- Every harness-primitive filesystem, process, temporary-file,"
  lines[#lines + 1] = "  wall-clock, and CPU-time operation ran against the real OS through"
  lines[#lines + 1] = "  `WheelHost.select_backend(\"standalone\")`. The parent bootstrap only"
  lines[#lines + 1] = "  creates the ephemeral base and re-executes the child with a private"
  lines[#lines + 1] = "  environment; it performs no harness operation."
  lines[#lines + 1] = "- The fixture is offline: no network, credentials, or secret"
  lines[#lines + 1] = "  environment read."
  lines[#lines + 1] = "- No release artifact, compatibility claim, or released-host"
  lines[#lines + 1] = "  integration is claimed."
  lines[#lines + 1] = "- Process timeout, cancellation, process-group, and scrubbed-"
  lines[#lines + 1] = "  environment bounds are not covered (CTX-0016)."
  lines[#lines + 1] = "- No OS sandbox/containment evidence and no Bitty panel/terminal"
  lines[#lines + 1] = "  presentation run; the host table is a presentation double only."
  lines[#lines + 1] = "- `os.clock()` is process CPU time, not elapsed wall clock; CPU"
  lines[#lines + 1] = "  frequency is not pinned; the record covers one host and one"
  lines[#lines + 1] = "  interpreter per run."
  lines[#lines + 1] = "- SECURITY-MODEL.md Gate 2 requires broader evidence; this fixture"
  lines[#lines + 1] = "  is partial evidence for the standalone activation and command-smoke"
  lines[#lines + 1] = "  surface only."
  lines[#lines + 1] = ""
  lines[#lines + 1] = "The ephemeral base and workspace were removed on success; no"
  lines[#lines + 1] = "absolute host path is recorded in this file."
  lines[#lines + 1] = ""

  return table.concat(lines, "\n")
end

local function write_evidence(status, failure)
  if not WheelHost then
    return false, "WheelHost is not loaded"
  end
  WheelHost.fs.mkdir_p("recording")
  return WheelHost.fs.write_file(EVIDENCE_PATH, build_evidence(status, failure))
end

-- ---------------------------------------------------------------------------
-- Main
-- ---------------------------------------------------------------------------

local function assert_typed_denial(err, expected_message)
  check(type(err) == "table", "a denied backend must return a typed error table")
  local fields = 0
  for key in pairs(err) do
    check(key == "class" or key == "code" or key == "message",
      "unexpected typed denial field: " .. tostring(key))
    fields = fields + 1
  end
  check(fields == 3, "a typed denial must carry exactly class/code/message")
  check(err.class == "runtime" and err.code == "E_CAPABILITY_DENIED",
    "a denied backend must use runtime/E_CAPABILITY_DENIED")
  check(err.message == expected_message,
    "unexpected typed denial message: " .. tostring(err.message))
end

local function main()
  check(BASE ~= nil and BASE ~= "", "WHEEL_REAL_HOST_BASE must be set")
  check(RUNTIME_DIR ~= nil and RUNTIME_DIR ~= "", "XDG_RUNTIME_DIR must be set before require")
  check(type(_G.bitty) == "nil",
    "the standalone fixture must start without an ambient Bitty host table")

  -- Cleanup below is a recursive remove scoped to the ephemeral base. Guard it
  -- to the fixture's own naming pattern before any harness operation so an
  -- externally supplied environment cannot point it at an arbitrary path.
  if OWNS_BASE then
    local scratch_root = os.getenv("WHEEL_REAL_HOST_SCRATCH") or "/tmp/bitty"
    local expected_prefix = scratch_root .. "/real-host."
    check(BASE:sub(1, #expected_prefix) == expected_prefix,
      "an owned base must live under the scratch root: " .. BASE)
    check(BASE ~= "/" and BASE:sub(-1) ~= "/" and BASE:find("%.%.") == nil,
      "an owned base must be a non-root real-host directory: " .. BASE)
    check(#BASE > #expected_prefix,
      "an owned base must carry a unique mktemp suffix: " .. BASE)
  end

  -- 1. Cold activation, catalog, lazy/eager split, and hello.
  local cold_capture
  local cold_cpu
  local cold_wheel
  cold_wheel, cold_capture, cold_cpu = activate_uninstrumented("cold-cpu")
  check(cold_wheel ~= nil, "cold activation must return the entry module")
  record("cold-cpu", "cpu", cold_cpu)
  state.coverage[#state.coverage + 1] =
    "activation: cold require registered exactly 14 commands in catalog order"
  state.coverage[#state.coverage + 1] =
    "activation: eager errors/schema/commands/kernel/ui loaded; the eight lazy modules stayed unloaded"

  local hello = cold_capture.registrations["hello"]
  local hello_ok, hello_result = pcall(hello.run, {})
  check(hello_ok, "hello dispatch failed: " .. tostring(hello_result))
  check(type(hello_result) == "table", "hello must return a result table")
  check(hello_result.title == "Wheel", "hello result title drifted")
  check(hello_result.body == "Hello from bitty-terminal.wheel (Bittie 🐹).",
    "hello result body drifted")
  check(#cold_capture.notifications == 1,
    "hello must emit exactly one notification, got " .. tostring(#cold_capture.notifications))
  local notification = cold_capture.notifications[1]
  check(type(notification) == "table", "hello notification must be a table")
  local notification_fields = 0
  for key in pairs(notification) do
    check(key == "title" or key == "body",
      "unexpected hello notification field: " .. tostring(key))
    notification_fields = notification_fields + 1
  end
  check(notification_fields == 2, "hello notification must carry exactly title/body")
  check(notification.title == "Wheel", "hello notification title drifted")
  check(notification.body == hello_result.body,
    "hello notification body must match the handler result")
  for _, name in ipairs(LAZY_MODULE_NAMES) do
    check(package.loaded["wheel." .. name] == nil,
      "hello must not load lazy module wheel." .. name)
  end
  state.coverage[#state.coverage + 1] =
    "hello: one notification with the exact title/body and no lazy module load"

  -- 2. Cold and warm instruction series.
  local _, _, cold_instructions = activate_instrumented("cold-instructions")
  record("cold-instructions", "instructions", cold_instructions)

  for index = 1, WARM_ACTIVATIONS do
    local _, _, warm_cpu = activate_uninstrumented("warm-" .. index .. "-cpu")
    record("warm-" .. index .. "-cpu", "cpu", warm_cpu)
  end

  for index = 1, INSTRUMENTED_ACTIVATIONS do
    local _, _, warm_instructions = activate_instrumented("warm-" .. index .. "-instructions")
    record("warm-" .. index .. "-instructions", "instructions", warm_instructions)
  end

  assert_budget()
  state.coverage[#state.coverage + 1] = string.format(
    "budget: %d cold/warm samples stayed under 10^7 instructions and 50 ms CPU; 8 ms warnings: %d",
    #state.series, #state.warnings)

  -- 3. Real host boundary: standalone backend and presentation-only double.
  WheelHost = require("wheel.host")
  WheelHost.select_backend(WheelHost.BACKEND_STANDALONE)
  check(WheelHost.backend_name == "standalone",
    "the real-host fixture must run on the standalone backend")
  check(type(_G.bitty) == "table", "the presentation double must still be installed")
  check(_G.bitty.commands ~= nil and _G.bitty.notify ~= nil,
    "the presentation double must expose commands.register and notify.show")
  check(_G.bitty.fs == nil and _G.bitty.process == nil and _G.bitty.host == nil,
    "the presentation double must not expose an fs/process/host surface")
  state.coverage[#state.coverage + 1] =
    "boundary: explicit standalone backend selected; the bitty double is presentation-only"

  local workspace = BASE .. "/workspace"
  check(WheelHost.fs.mkdir_p(workspace), "cannot create the real workspace")
  check(WheelHost.fs.mkdir_p(workspace .. "/nested"), "cannot create the nested workspace directory")
  check(WheelHost.fs.mkdir_p(RUNTIME_DIR), "cannot create the private runtime directory")
  local chmod_runtime = WheelHost.proc.run_program("chmod", { "700", RUNTIME_DIR })
  check(chmod_runtime.ok and chmod_runtime.code == 0,
    "cannot set the private runtime directory to 0700")

  -- 4. Temporary-file primitive: private directory, unique names, real I/O.
  local tmp_dir = WheelHost.tmp.dir()
  check(tmp_dir == RUNTIME_DIR .. "/wheel",
    "WheelHost.tmp.dir must resolve inside the private XDG_RUNTIME_DIR")
  local ls_dir = WheelHost.proc.run_program("ls", { "-ld", tmp_dir })
  check(ls_dir.ok and ls_dir.code == 0, "cannot inspect the private temp directory")
  check(ls_dir.stdout:sub(1, 10) == "drwx------",
    "the private temp directory must be 0700, got " .. tostring(ls_dir.stdout:sub(1, 10)))

  local tmp_one = WheelHost.tmp.name()
  local tmp_two = WheelHost.tmp.name()
  check(tmp_one ~= tmp_two, "WheelHost.tmp.name must return unique paths")
  check(tmp_one:sub(1, #tmp_dir + 1) == tmp_dir .. "/",
    "WheelHost.tmp.name must stay inside the private temp directory")
  check(WheelHost.fs.write_file(tmp_one, "tmp-real-host"), "cannot write a temporary file")
  check(WheelHost.fs.read_file(tmp_one) == "tmp-real-host", "cannot read the temporary file")
  check(WheelHost.fs.remove_file(tmp_one), "cannot remove the temporary file")
  state.coverage[#state.coverage + 1] =
    "WheelHost.tmp: private 0700 directory, unique paths, real write/read/remove"

  -- 5. Filesystem primitive with real files.
  local file_path = workspace .. "/nested/real-host.txt"
  local file_content = "alpha\nbeta\nneedle gamma\n"
  check(WheelHost.fs.write_file(file_path, file_content), "cannot write the real workspace file")
  check(WheelHost.fs.exists(file_path), "the real workspace file must exist")
  check(WheelHost.fs.read_file(file_path) == file_content,
    "the real workspace file must round-trip exactly")
  local listing = WheelHost.fs.list_dir(workspace .. "/nested")
  check(listing.ok and listing.code == 0, "cannot list the real workspace directory")
  check(listing.stdout:find("real-host.txt", 1, true) ~= nil,
    "the workspace listing must include the real file")
  check(WheelHost.fs.remove_file(file_path), "cannot remove the real workspace file")
  check(not WheelHost.fs.exists(file_path), "the removed workspace file must be gone")
  state.coverage[#state.coverage + 1] =
    "WheelHost.fs: real write/read/exists/list_dir/remove_file round-trip"

  -- 6. Process primitives: explicit argv and the quoted shell-string surface.
  local argv_result = WheelHost.proc.run_program("printf", { "%s", "argv-real-host" })
  check(argv_result.ok and argv_result.code == 0, "run_program must launch")
  check(argv_result.stdout == "argv-real-host",
    "run_program must preserve an argv element verbatim")
  local quoted_command = "printf '%s' " .. WheelHost.proc.shell_quote("shell-real-host")
  local shell_result = WheelHost.proc.run_command(quoted_command)
  check(shell_result.ok and shell_result.code == 0, "run_command must launch")
  check(shell_result.stdout == "shell-real-host",
    "run_command must execute the quoted shell-string primitive")
  check(type(WheelHost.time.now()) == "number" and WheelHost.time.now() > 0,
    "WheelHost.time.now must return a real wall-clock value")
  check(type(WheelHost.time.clock()) == "number" and WheelHost.time.clock() >= 0,
    "WheelHost.time.clock must return a real CPU-time value")
  state.coverage[#state.coverage + 1] =
    "WheelHost.proc: real argv execution and quoted shell-string execution"
  state.coverage[#state.coverage + 1] =
    "WheelHost.time: real wall-clock and CPU-time reads"

  -- 7. Tool paths with real files and commands.
  local WheelTool = require("wheel.tool")
  local WheelAgent = require("wheel.agent")
  local registry = WheelTool.get_default_registry()
  local coding_env = {
    workspace_root = workspace,
    role = WheelAgent.Role.CODING,
  }

  local tool_content = "tool alpha\ntool needle beta\n"
  local write_outcome = registry:dispatch("write_file", {
    path = "nested/tool.txt",
    content = tool_content,
    overwrite = true,
  }, coding_env)
  check(write_outcome.success == true,
    "tool write_file failed: " .. tostring(write_outcome.stderr))
  check(write_outcome.exit_code == 0, "tool write_file must exit 0")

  local read_outcome = registry:dispatch("read_file", { path = "nested/tool.txt" }, coding_env)
  check(read_outcome.success == true,
    "tool read_file failed: " .. tostring(read_outcome.stderr))
  check(read_outcome.stdout == "tool alpha\ntool needle beta",
    "tool read_file must return the real file content")

  local edit_outcome = registry:dispatch("edit_file", {
    path = "nested/tool.txt",
    target = "alpha",
    replacement = "ALPHA",
  }, coding_env)
  check(edit_outcome.success == true,
    "tool edit_file failed: " .. tostring(edit_outcome.stderr))
  local edited = WheelHost.fs.read_file(workspace .. "/nested/tool.txt")
  check(type(edited) == "string" and edited:find("ALPHA", 1, true) ~= nil,
    "tool edit_file must persist the replacement")

  local search_outcome = registry:dispatch("search_code", { query = "needle" }, coding_env)
  check(search_outcome.success == true,
    "tool search_code failed: " .. tostring(search_outcome.stderr))
  check(search_outcome.stdout:find("tool needle beta", 1, true) ~= nil,
    "tool search_code must find the real workspace content")

  local list_outcome = registry:dispatch("list_directory", { path = "nested" }, coding_env)
  check(list_outcome.success == true,
    "tool list_directory failed: " .. tostring(list_outcome.stderr))
  check(list_outcome.stdout:find("tool.txt", 1, true) ~= nil,
    "tool list_directory must list the real workspace file")

  local run_outcome = registry:dispatch("run_command", { command = "pwd", cwd = "nested" }, coding_env)
  check(run_outcome.success == true,
    "tool run_command failed: " .. tostring(run_outcome.stderr))
  local run_cwd = run_outcome.stdout:gsub("%s+$", "")
  check(run_cwd == workspace .. "/nested",
    "tool run_command must execute in the real workspace cwd: " .. tostring(run_outcome.stdout))

  local quoted_tool_command = "printf '%s' " .. WheelHost.proc.shell_quote("tool-shell-ok")
  local quoted_tool_outcome = registry:dispatch("run_command", {
    command = quoted_tool_command,
  }, coding_env)
  check(quoted_tool_outcome.success == true,
    "tool run_command shell-string path failed: " .. tostring(quoted_tool_outcome.stderr))
  check(quoted_tool_outcome.stdout == "tool-shell-ok",
    "tool run_command must execute the quoted shell-string argument")
  state.coverage[#state.coverage + 1] =
    "tool: read_file/write_file/edit_file/list_directory/search_code/run_command on real files and processes"

  -- 8. Denials: outside-workspace paths, destructive commands, role gates,
  -- and unavailable backends.
  local parent_escape = registry:dispatch("read_file", {
    path = "../outside-workspace.txt",
  }, coding_env)
  check(parent_escape.success == false, "a parent traversal must be denied")
  check(parent_escape.stderr == "path_traversal_denied: path escapes workspace root",
    "a parent traversal must report the typed path denial: " .. tostring(parent_escape.stderr))

  local absolute_escape = registry:dispatch("read_file", { path = "/etc/hostname" }, coding_env)
  check(absolute_escape.success == false, "an absolute outside path must be denied")
  check(absolute_escape.stderr == "path_traversal_denied: path escapes workspace root",
    "an absolute outside path must report the typed path denial: "
      .. tostring(absolute_escape.stderr))
  state.coverage[#state.coverage + 1] =
    "denial: ../outside-workspace.txt and /etc/hostname are rejected with path_traversal_denied"

  local dangerous = registry:dispatch("run_command", { command = "rm -rf /" }, coding_env)
  check(dangerous.success == false, "a destructive command must be denied")
  check(dangerous.exit_code == 126,
    "a destructive command must return exit 126, got " .. tostring(dangerous.exit_code))
  check(dangerous.stderr:find("dangerous_command_blocked", 1, true) ~= nil,
    "a destructive command must report dangerous_command_blocked: " .. tostring(dangerous.stderr))
  state.coverage[#state.coverage + 1] =
    "denial: rm -rf / is rejected with dangerous_command_blocked and exit 126"

  local research_env = {
    workspace_root = workspace,
    role = WheelAgent.Role.RESEARCH,
  }
  local role_denied = registry:dispatch("write_file", {
    path = "nested/role-denied.txt",
    content = "not allowed",
    overwrite = true,
  }, research_env)
  check(role_denied.success == false, "the read-only Research role must not modify files")
  check(role_denied.status == WheelTool.OutcomeStatus.DENIED,
    "the Research role denial must carry the denied status")
  check(role_denied.stderr:find("role_authority_violation", 1, true) ~= nil,
    "the Research role denial must report role_authority_violation")
  check(not WheelHost.fs.exists(workspace .. "/nested/role-denied.txt"),
    "a denied Research write must not create the file")
  state.coverage[#state.coverage + 1] =
    "denial: the read-only Research role cannot write files and no file is created"

  local unknown_backend_ok, unknown_backend_err = pcall(WheelHost.create_backend, "plugin-host")
  check(not unknown_backend_ok, "an unknown execution backend must fail closed")
  assert_typed_denial(unknown_backend_err, "capability 'host.backend' is not granted")

  local platform_ok, platform_err = pcall(WheelHost.create_backend, "standalone", {
    platform = "windows",
  })
  check(not platform_ok, "a non-POSIX platform must fail closed")
  assert_typed_denial(platform_err, "capability 'host.backend.standalone' is not granted")
  check(WheelHost.backend_name == "standalone",
    "a denied backend construction must not replace the active backend")
  state.coverage[#state.coverage + 1] =
    "denial: unknown backend and non-POSIX platform return typed E_CAPABILITY_DENIED"

  -- 9. Evidence and cleanup.
  local cpu_cold = stats_for("cpu", "cold")
  local cpu_warm = stats_for("cpu", "warm")
  local instr_cold = stats_for("instructions", "cold")
  local instr_warm = stats_for("instructions", "warm")

  local write_ok, write_err = write_evidence("PASSED", nil)
  check(write_ok == true, "cannot write the real-host evidence: " .. tostring(write_err))

  print(string.format(
    "[PASS] real-host fixture: %d checks; 14/14 commands; hello; fs/proc/tmp/tool smoke; four denial classes",
    state.checks))
  if cpu_cold and instr_cold then
    print(string.format("[INFO] cold: %s ms CPU, %d instructions",
      format_ms(cpu_cold.median), instr_cold.median))
  end
  if cpu_warm and instr_warm then
    print(string.format("[INFO] warm: median %s ms CPU (%d runs), median %d instructions (%d runs)",
      format_ms(cpu_warm.median), cpu_warm.count, instr_warm.median, instr_warm.count))
  end
  if #state.warnings == 0 then
    print("[INFO] RC-1: under 10^7 instructions and 50 ms CPU; no 8 ms warning")
  else
    print(string.format("[WARN] RC-1: %d sample(s) crossed the 8 ms warning", #state.warnings))
  end
  print("[INFO] evidence: " .. EVIDENCE_PATH)

  if OWNS_BASE then
    local removed = WheelHost.proc.run_program("rm", { "-rf", BASE })
    if not (removed.ok and removed.code == 0) then
      print("[WARN] could not remove the ephemeral base: " .. tostring(removed.stderr))
    end
  end
end

local ok, err = pcall(main)
if not ok then
  io.stderr:write("[FAIL] real-host fixture: " .. tostring(err) .. "\n")
  if WheelHost then
    local evidence_ok, evidence_written = pcall(write_evidence, "FAILED", tostring(err))
    if evidence_ok and evidence_written == true then
      io.stderr:write("[FAIL] failure evidence written to " .. EVIDENCE_PATH .. "\n")
    end
  end
  if OWNS_BASE and BASE then
    io.stderr:write("[FAIL] ephemeral base retained for diagnosis: " .. BASE .. "\n")
  end
  os.exit(1)
end
os.exit(0)
