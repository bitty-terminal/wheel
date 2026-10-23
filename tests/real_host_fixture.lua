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
--   * WHEEL_ROOT selects an installed artifact tree instead of the
--     development checkout; WHEEL_EVIDENCE_PATH keeps evidence out of that
--     tree. Both are test-controlled paths, not harness inputs.
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
--   * opt-in audit JSONL is inspected after a permitted and a denied command;
--     CTX-0034 adds real asynchronous cancellation (handle in every mode, the
--     separate scripts/wheel-proc client in a development checkout) with a
--     distinct cancelled terminal reason, swept group, no orphan, unrelated-job
--     isolation, idempotent repeat, timeout/cancel race, and cancellation
--     audit. Default-on audit wiring, OS sandbox, and Bitty panel/terminal
--     presentation are not covered. Timeout, retained-leader process-group
--     identity, stdin, and scrubbed-environment bounds are covered below; a
--     child that calls setsid or joins another group can still escape the
--     recorded group. Cancellation is same-user only and the installed-tree run
--     uses the handle because scripts/ is not packaged.
--   * single host and one interpreter per run; CPU frequency is not pinned.

-- WHEEL_ROOT points the fixture at an installed artifact tree instead of the
-- development checkout. It must be absolute, and the fixture verifies that the
-- loaded modules actually resolved from it. WHEEL_EVIDENCE_PATH redirects the
-- evidence write so an installed-tree run does not touch the repository.
local WHEEL_ROOT = os.getenv("WHEEL_ROOT")
if WHEEL_ROOT == "" then
  WHEEL_ROOT = nil
end
if WHEEL_ROOT then
  if WHEEL_ROOT:sub(1, 1) ~= "/" then
    io.stderr:write("real-host fixture: WHEEL_ROOT must be absolute\n")
    os.exit(1)
  end
  if WHEEL_ROOT:sub(-1) == "/" then
    WHEEL_ROOT = WHEEL_ROOT:sub(1, -2)
  end
  -- Hermetic installed-tree mode: no inherited repository path may satisfy a
  -- require. A missing installed module must fail instead of falling back.
  package.path = WHEEL_ROOT .. "/lua/?.lua;" .. WHEEL_ROOT .. "/lua/?/init.lua"
else
  package.path = "./lua/?.lua;./lua/?/init.lua;" .. package.path
end

local RC1_INSTRUCTION_BUDGET = 10000000
local RC1_CPU_BUDGET_SECONDS = 0.050
local RC1_WARNING_SECONDS = 0.008
local WARM_ACTIVATIONS = 5
local INSTRUMENTED_ACTIVATIONS = 5
local EVIDENCE_PATH = os.getenv("WHEEL_EVIDENCE_PATH")
if EVIDENCE_PATH == "" then
  EVIDENCE_PATH = nil
end
EVIDENCE_PATH = EVIDENCE_PATH or "recording/real-host-2026-10-21.md"

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
    "WHEEL_ROOT=" .. shell_quote(WHEEL_ROOT or ""),
    "WHEEL_EVIDENCE_PATH=" .. shell_quote(EVIDENCE_PATH),
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
    check(def.args_schema.type == "object" and def.args_schema.additionalProperties == false,
      label .. ": args_schema must stay closed for " .. expected_id)
    if expected_id == "trust" then
      check(type(def.args_schema.properties) == "table"
        and def.args_schema.properties.action ~= nil
        and def.args_schema.properties.hash ~= nil
        and def.args_schema.properties.path ~= nil,
        label .. ": trust must declare optional action/hash/path fields")
    else
      check(def.args_schema.properties == nil,
        label .. ": args_schema must stay property-free for " .. expected_id)
    end
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
  lines[#lines + 1] = "- Process timeout, the retained-leader process-group sweep (the"
  lines[#lines + 1] = "  recorded PGID is held until the final KILL), stdin, and"
  lines[#lines + 1] = "  scrubbed-environment bounds are covered. If the leader dies"
  lines[#lines + 1] = "  early, cleanup is reported `unverified` and no signal is sent."
  lines[#lines + 1] = "  CTX-0034 covers asynchronous cancellation through the handle in"
  lines[#lines + 1] = "  every mode and through the separate scripts/wheel-proc client in a"
  lines[#lines + 1] = "  development checkout; the installed-tree run uses the handle because"
  lines[#lines + 1] = "  the library artifact does not package scripts/. Cancellation is"
  lines[#lines + 1] = "  same-user only. A child that leaves the recorded group (setsid or"
  lines[#lines + 1] = "  another process group) is still not covered."
  lines[#lines + 1] = "- The audit section wrote a permitted pre-spawn/completion pair and a"
  lines[#lines + 1] = "  denied pre-spawn record into a private state directory, then read"
  lines[#lines + 1] = "  the JSONL back and checked fields, chain, modes, the absent denied"
  lines[#lines + 1] = "  side effect, redaction of a synthetic value, and a high-risk refusal."
  lines[#lines + 1] = "  The cancellation audit section additionally records"
  lines[#lines + 1] = "  `process.cancel_requested`/`process.cancel_outcome` and the cancelled"
  lines[#lines + 1] = "  completion, and proves a high-risk request with an unwritable sink is"
  lines[#lines + 1] = "  refused before any signal. The sink is opt-in at the process seam;"
  lines[#lines + 1] = "  default-on tool wiring is not covered and remains a follow-up."
  lines[#lines + 1] = "- No OS sandbox/containment evidence and no Bitty panel/terminal"
  lines[#lines + 1] = "  presentation run; the host table is a presentation double only."
  lines[#lines + 1] = "- `os.clock()` is process CPU time, not elapsed wall clock; CPU"
  lines[#lines + 1] = "  frequency is not pinned; the record covers one host and one"
  lines[#lines + 1] = "  interpreter per run."
  lines[#lines + 1] = "- SECURITY-MODEL.md Gate 2 requires broader evidence; this fixture"
  lines[#lines + 1] = "  is partial evidence for the standalone activation, command-smoke,"
  lines[#lines + 1] = "  opt-in audit, and cancellation surfaces only."
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
  local evidence_dir = EVIDENCE_PATH:match("^(.*)/[^/]+$") or "."
  WheelHost.fs.mkdir_p(evidence_dir)
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

  if WHEEL_ROOT then
    check(cold_wheel.command_runtime ~= nil and
      type(cold_wheel.command_runtime.register) == "function",
      "the entry module must expose the command runtime")
    local source = debug.getinfo(cold_wheel.command_runtime.register, "S").source
    check(source:sub(1, 1) == "@", "the command runtime must come from a file")
    check(source:sub(2, #WHEEL_ROOT + 1) == WHEEL_ROOT,
      "an installed-tree run must load modules from WHEEL_ROOT: " .. tostring(source))
    state.coverage[#state.coverage + 1] =
      "installed tree: wheel modules resolved from WHEEL_ROOT"
  end

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

  -- Exclusive 0600 creation refuses pre-existing files and symlinks.
  local exclusive = WheelHost.tmp.name()
  check(WheelHost.tmp.create_exclusive(exclusive, "exclusive-real-host"),
    "exclusive temporary creation must succeed on a fresh path")
  local exclusive_mode = WheelHost.proc.run_program("stat", { "-c", "%a", exclusive })
  check(exclusive_mode.ok and trim(exclusive_mode.stdout) == "600",
    "exclusive temporary files must be mode 0600: " .. tostring(exclusive_mode.stdout))
  local reused, reused_err = WheelHost.tmp.create_exclusive(exclusive, "overwrite")
  check(reused == false and type(reused_err) == "string",
    "exclusive temporary creation must refuse an existing path")
  check(WheelHost.fs.read_file(exclusive) == "exclusive-real-host",
    "an existing temporary file must not be truncated")
  local tmp_link = WheelHost.tmp.name()
  local made_link = WheelHost.proc.run_program("ln", { "-s", exclusive, tmp_link })
  check(made_link.ok and made_link.code == 0, "cannot create the temporary symlink fixture")
  local followed, followed_err = WheelHost.tmp.create_exclusive(tmp_link, "link-overwrite")
  check(followed == false and type(followed_err) == "string",
    "exclusive temporary creation must refuse a pre-existing symlink")
  check(WheelHost.fs.read_file(exclusive) == "exclusive-real-host",
    "a temporary symlink must never be followed")
  check(WheelHost.fs.remove_file(exclusive), "cannot remove the exclusive temporary file")
  check(WheelHost.fs.remove_file(tmp_link), "cannot remove the temporary symlink")

  state.coverage[#state.coverage + 1] =
    "WheelHost.tmp: private 0700 directory, unique paths, real write/read/remove"
  state.coverage[#state.coverage + 1] =
    "WheelHost.tmp.create_exclusive: 0600 exclusive creation, existing file/link refused"

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

  -- stdin crosses the argv primitive without a shell string.
  local stdin_result = WheelHost.proc.run_program("cat", {}, { stdin = "stdin-real-host" })
  check(stdin_result.ok and stdin_result.code == 0,
    "run_program must accept stdin bytes")
  check(stdin_result.stdout == "stdin-real-host",
    "run_program must deliver stdin to the child verbatim")

  -- The child environment is scrubbed: harness and secret-shaped variables
  -- from the parent process are absent, while PATH is explicit.
  local env_result = WheelHost.proc.run_program("sh", {
    "-c",
    'printf "%s|%s|%s" "${WHEEL_REAL_HOST_BASE-unset}" "${OPENROUTER_API_KEY-unset}" "$PATH"',
  })
  check(env_result.ok and env_result.code == 0, "the scrubbed environment probe must run")
  local env_parts = {}
  for part in (env_result.stdout .. "|"):gmatch("([^|]*)|") do
    env_parts[#env_parts + 1] = part
  end
  check(env_parts[1] == "unset" and env_parts[2] == "unset",
    "harness and secret-shaped variables must not reach a child: " .. tostring(env_result.stdout))
  check(type(env_parts[3]) == "string" and env_parts[3]:sub(1, 1) == "/",
    "the child PATH must be explicit and absolute: " .. tostring(env_parts[3]))

  -- Timeout and process-group ownership: a child and its grandchild must be
  -- terminated by the timeout's owned process group, not by a name/pattern
  -- kill. The PID is recorded by the child itself.
  local group_pid_file = BASE .. "/process-group.pid"
  local timed = WheelHost.proc.run_program("sh", {
    "-c",
    "sleep 30 & echo $! > " .. shell_quote(group_pid_file) .. "; wait",
  }, { timeout_ms = 500 })
  check(timed.ok and timed.timed_out and timed.outcome == WheelHost.PROCESS_OUTCOME.TIMEOUT,
    "a timed-out process must report the typed timeout outcome")
  check(timed.code == 124 or timed.code == 137,
    "GNU timeout must map expiry to 124/137, got " .. tostring(timed.code))
  check(timed.cleanup == WheelHost.GROUP_CLEANUP.SWEPT,
    "the retained leader must complete the timeout sweep, got " .. tostring(timed.cleanup))
  check(type(timed.pgid) == "number" and timed.pgid > 1,
    "the recorded PGID must be reported on a timeout")
  local grandchild = WheelHost.fs.read_file(group_pid_file)
  grandchild = grandchild and trim(grandchild) or ""
  check(grandchild:match("^%d+$") ~= nil, "the child must record its grandchild PID")
  local settle = WheelHost.proc.run_program("sleep", { "0.2" })
  check(settle.ok and settle.code == 0, "the bounded settle wait must run")
  local group_probe = WheelHost.proc.run_program("ps", { "-o", "stat=", "-p", grandchild },
    { discard_stderr = true })
  local group_state = group_probe.code == 0 and trim(group_probe.stdout) or ""
  check(group_state == "" or group_state:sub(1, 1) == "Z",
    "the timed-out process group must leave no running grandchild: " .. tostring(group_state))

  -- Normal completion must also sweep the recorded group, not only timeout.
  local normal_pid_file = BASE .. "/normal-exit.pid"
  local normal = WheelHost.proc.run_program("sh", {
    "-c",
    "sleep 30 & echo \"$! $(ps -o pgid= -p $!)\" > " .. shell_quote(normal_pid_file)
      .. "; exit 9",
  })
  check(normal.ok and normal.code == 9,
    "a normal command with a background child must preserve its exit status")
  check(normal.cleanup == WheelHost.GROUP_CLEANUP.SWEPT,
    "normal completion must report a completed sweep, got " .. tostring(normal.cleanup))
  local normal_record = WheelHost.fs.read_file(normal_pid_file)
  normal_record = normal_record and trim(normal_record) or ""
  local normal_pid, normal_pgid = normal_record:match("^(%d+)%s+(%d+)$")
  check(normal_pid ~= nil, "the child must record its background PID and PGID")
  check(tonumber(normal_pgid) == normal.pgid,
    "the recorded PGID must be the background child's group, got "
      .. tostring(normal_pgid) .. " vs " .. tostring(normal.pgid))
  local normal_probe = WheelHost.proc.run_program("ps", { "-o", "stat=", "-p", normal_pid },
    { discard_stderr = true })
  local normal_state = normal_probe.code == 0 and trim(normal_probe.stdout) or ""
  check(normal_state == "" or normal_state:sub(1, 1) == "Z",
    "normal completion must leave no running background child: " .. tostring(normal_state))

  check(type(WheelHost.time.now()) == "number" and WheelHost.time.now() > 0,
    "WheelHost.time.now must return a real wall-clock value")
  check(type(WheelHost.time.clock()) == "number" and WheelHost.time.clock() >= 0,
    "WheelHost.time.clock must return a real CPU-time value")
  state.coverage[#state.coverage + 1] =
    "WheelHost.proc: real argv execution and quoted shell-string execution"
  state.coverage[#state.coverage + 1] =
    "WheelHost.proc: stdin channel, scrubbed allowlist environment, and typed timeout"
  state.coverage[#state.coverage + 1] =
    "WheelHost.proc: timeout terminated the recorded process group (child and grandchild)"
  state.coverage[#state.coverage + 1] =
    "WheelHost.proc: normal completion preserved status 9 and swept the recorded process group (background child)"
  state.coverage[#state.coverage + 1] =
    "WheelHost.proc: retained session leader holds the recorded PGID through the sweep"
  state.coverage[#state.coverage + 1] =
    "WheelHost.time: real wall-clock and CPU-time reads"

  -- 6b. Execution audit (CTX-0030 Gate 2): a real permitted command, a real
  -- denied command that must not spawn, and a high-risk write failure that
  -- must refuse the spawn. The test itself reads the JSONL and checks the
  -- private modes, pre-spawn fields, chain, redaction, and denied side effect.
  local audit_state = os.getenv("XDG_STATE_HOME")
  check(type(audit_state) == "string" and audit_state ~= "",
    "the audit fixture requires a private XDG_STATE_HOME")
  local audit_dir = audit_state .. "/wheel/audit"
  check(audit_dir:sub(1, #BASE + 1) == BASE .. "/",
    "the audit directory must live under the fixture base")
  local cleared = WheelHost.proc.run_program("rm", { "-rf", audit_dir })
  check(cleared.ok and cleared.code == 0, "cannot clear the audit fixture directory")

  local synthetic_secret = "sk-wheel-audit-synthetic-gate2-4c1d9e7a"
  local audit_identity = {
    role = "coding",
    agent = "gate2-audit-agent",
    task = "CTX-0030",
    tool = "run_command",
  }

  local permitted_audit = {}
  for key, value in pairs(audit_identity) do
    permitted_audit[key] = value
  end
  permitted_audit.intent = "Gate 2 permitted command"
  permitted_audit.decision = "allow"
  permitted_audit.high_risk = true

  local permitted = WheelHost.proc.run_command(
    "printf '%s' audit-permitted", nil, {
      cwd = workspace,
      audit = permitted_audit,
    })
  check(permitted.ok and permitted.code == 0,
    "the audited permitted command must run: " .. tostring(permitted.stderr))
  check(permitted.stdout == "audit-permitted",
    "the audited permitted command must preserve its output")
  check(permitted.audit_warning == nil, "the permitted audit must not warn")
  check(permitted.spawned == true, "the permitted result must report a spawn")

  local denied_marker = workspace .. "/audit-denied-marker"
  check(WheelHost.fs.write_file(denied_marker, "must survive a denied command"),
    "cannot create the audit denial marker")
  local denied_command = "rm -f " .. shell_quote(denied_marker)
    .. " --token=" .. synthetic_secret
    .. " # Authorization: Bearer " .. synthetic_secret
  local denied = WheelHost.proc.run_command(denied_command, nil, {
    cwd = workspace,
    audit = {
      role = "coding",
      agent = "gate2-audit-agent",
      task = "CTX-0030",
      tool = "run_command",
      intent = "Gate 2 denied command",
      decision = "deny",
      reason = "destructive_command_blocked",
      high_risk = true,
    },
  })
  check(denied.ok == false and denied.denied == true,
    "the audited deny decision must return a denial")
  check(WheelHost.fs.exists(denied_marker),
    "the denied command must not delete its marker")

  local blocked_audit = BASE .. "/audit-blocked"
  check(WheelHost.fs.write_file(blocked_audit, "not a directory"),
    "cannot create the blocked audit path")
  local refused_marker = workspace .. "/audit-refused-marker"
  local refused = WheelHost.proc.run_command("touch " .. shell_quote(refused_marker), nil, {
    audit = {
      dir = blocked_audit .. "/audit",
      high_risk = true,
      decision = "allow",
    },
  })
  check(refused.ok == false, "a high-risk spawn without an audit sink must fail closed")
  check(type(refused.audit_error) == "table"
    and refused.audit_error.code == "E_AUDIT_UNAVAILABLE",
    "the high-risk refusal must carry the typed audit error")
  check(not WheelHost.fs.exists(refused_marker),
    "the high-risk refused command must not spawn")

  local audit_file = audit_dir .. "/audit.jsonl"
  check(WheelHost.fs.exists(audit_file), "the audit stream must exist after the runs")
  local audit_dir_mode = WheelHost.proc.run_program("stat", { "-c", "%a", audit_dir })
  check(audit_dir_mode.ok and trim(audit_dir_mode.stdout) == "700",
    "the audit directory must be mode 0700: " .. tostring(audit_dir_mode.stdout))
  local audit_file_mode = WheelHost.proc.run_program("stat", { "-c", "%a", audit_file })
  check(audit_file_mode.ok and trim(audit_file_mode.stdout) == "600",
    "the audit file must be mode 0600: " .. tostring(audit_file_mode.stdout))

  local audit_raw = WheelHost.fs.read_file(audit_file)
  check(type(audit_raw) == "string" and audit_raw ~= "",
    "the audit file must not be empty")
  check(audit_raw:find(synthetic_secret, 1, true) == nil,
    "the synthetic secret must not appear in the audit stream")
  check(audit_raw:find("Bearer " .. synthetic_secret, 1, true) == nil,
    "the authorization header value must not appear in the audit stream")

  local AuditJSON = require("wheel.kernel").JSON
  local audit_records = {}
  for line in audit_raw:gmatch("([^\n]+)") do
    check(#line <= 16 * 1024, "every audit record must stay within 16 KiB")
    local record = AuditJSON.decode(line)
    check(type(record) == "table", "every audit line must decode as JSON")
    audit_records[#audit_records + 1] = record
  end
  check(#audit_records >= 3, "the audit stream must contain pre-spawn records")

  local permitted_pre = nil
  local denied_pre = nil
  local completed = 0
  for _, record in ipairs(audit_records) do
    if record.event == "process.completed" then
      completed = completed + 1
    elseif record.event == "process.pre_spawn" and record.decision == "deny" then
      denied_pre = record
    elseif record.event == "process.pre_spawn" then
      permitted_pre = record
    end
  end
  check(permitted_pre ~= nil, "the permitted command must have a pre-spawn record")
  check(denied_pre ~= nil, "the denied command must have a pre-spawn record")
  check(completed == 1, "only the permitted command may write a completion record")
  check(permitted_pre.decision == "allow", "the permitted pre-spawn decision must be allow")
  check(permitted_pre.kind == "shell" and type(permitted_pre.shell) == "string",
    "the permitted record must carry the redacted shell command")
  check(permitted_pre.cwd == workspace, "the permitted record must carry its cwd")
  check(permitted_pre.role == "coding" and permitted_pre.agent == "gate2-audit-agent"
    and permitted_pre.task == "CTX-0030" and permitted_pre.tool == "run_command",
    "the permitted record must carry its identity fields")
  check(permitted_pre.intent == "Gate 2 permitted command",
    "the permitted record must carry its intent label")
  check(permitted_pre.high_risk == true, "the permitted record must carry its risk class")
  check(type(permitted_pre.command_hash) == "string"
    and #permitted_pre.command_hash == 64,
    "the permitted record must carry a 64-hex command hash")
  check(denied_pre.reason == "destructive_command_blocked",
    "the denied record must carry the policy reason")
  check(denied_pre.spawned == false, "the denied record must not claim a spawn")

  for index, record in ipairs(audit_records) do
    check(record.seq == index, "audit sequence must be monotonic")
    if index == 1 then
      check(record.prev == string.rep("0", 64),
        "the first audit record must start from the zero hash")
    else
      check(record.prev == audit_records[index - 1].hash,
        "each audit record must name the previous hash")
    end
  end
  state.coverage[#state.coverage + 1] =
    "audit: permitted pre-spawn/completion records, denied record without a spawn, private modes, chain, and redaction inspected from JSONL"
  state.coverage[#state.coverage + 1] =
    "audit: a high-risk spawn with an unwritable sink failed closed before launch"

  -- 6c. Asynchronous cancellation (CTX-0034): a real long command is started
  -- through the job handle, cancelled, and checked for a distinct terminal
  -- reason, a swept recorded group, no orphan, and an unrelated recorded job
  -- that keeps running. In a development checkout the same path is driven by
  -- the separate `scripts/wheel-proc` process; installed-tree runs skip that
  -- client because the library artifact does not package scripts/.
  local cancel_root = BASE .. "/cancel-jobs"
  local cancel_child_path = BASE .. "/cancel-child.pid"
  local cancel_grandchild_path = BASE .. "/cancel-grandchild.pid"

  local function fixture_process_state(pid)
    local probe = WheelHost.proc.run_program("ps", { "-o", "stat=", "-p", tostring(pid) },
      { discard_stderr = true })
    if probe.code ~= 0 then
      return nil
    end
    return trim(probe.stdout)
  end

  local function fixture_wait_gone(pid, label)
    for _ = 1, 100 do
      local state = fixture_process_state(pid)
      if state == nil or state:sub(1, 1) == "Z" then
        return
      end
      WheelHost.time.sleep_ms(20)
    end
    check(false, label .. " must not be running after cancellation")
  end

  local cancel_sentinel = WheelHost.proc.start("sleep", { "30" }, {
    timeout_ms = 60000,
    job_root = cancel_root,
  })
  check(cancel_sentinel ~= nil, "the cancellation sentinel job must start")
  local sentinel_pgid = cancel_sentinel:pgid()

  local cancel_target = WheelHost.proc.start("sh", {
    "-c",
    "echo $$ > " .. shell_quote(cancel_child_path)
      .. "; sleep 30 & echo $! > " .. shell_quote(cancel_grandchild_path)
      .. "; wait",
  }, { timeout_ms = 60000, job_root = cancel_root })
  check(cancel_target ~= nil, "the cancellation target job must start")
  check(cancel_target:job_id():match("^[0-9a-f]+$") ~= nil
    and #cancel_target:job_id() == 32, "the cancellation job id must be 32 hex")
  check(type(cancel_target:pgid()) == "number" and cancel_target:pgid() > 1,
    "the cancellation job must record its PGID")

  local cancel_cli_used = false
  if WHEEL_ROOT == nil then
    local cli = WheelHost.proc.run_program("./scripts/wheel-proc", {
      "cancel", cancel_target:job_id(), "--root", cancel_root,
    }, { timeout_ms = 10000 })
    check(cli.ok and cli.code == 0, "the cancellation CLI must accept the request: "
      .. tostring(cli.stderr))
    local cli_record = nil
    local decoded_ok, decoded = pcall(require("wheel.kernel").JSON.decode, cli.stdout)
    if decoded_ok then
      cli_record = decoded
    end
    check(type(cli_record) == "table" and cli_record.state == "requested",
      "the cancellation CLI must report a requested state")
    check(cli_record.terminal_reason == "cancelled" and cli_record.term_sent == true,
      "the cancellation CLI must record the cancelled reason and TERM")
    cancel_cli_used = true
  else
    local handle_ok, handle_info = cancel_target:cancel()
    check(handle_ok == true and handle_info.state == "requested",
      "the installed-tree handle cancellation must be accepted")
  end

  local cancel_result = cancel_target:wait(5000)
  check(cancel_result ~= nil, "the cancelled job must reach a terminal result")
  check(cancel_result.outcome == WheelHost.PROCESS_OUTCOME.CANCELLED,
    "cancellation must be a distinct typed outcome, got " .. tostring(cancel_result.outcome))
  check(cancel_result.cancel_requested == true and cancel_result.timed_out == false,
    "cancellation must set cancel_requested and not timed_out")
  check(cancel_result.terminal_reason == "cancelled",
    "cancellation must publish the cancelled terminal reason")
  check(cancel_result.code == 143 or cancel_result.code == 137,
    "cancellation must carry a signal-derived status, got " .. tostring(cancel_result.code))
  check(cancel_result.cleanup == WheelHost.GROUP_CLEANUP.SWEPT,
    "cancellation must complete the recorded-group sweep, got " .. tostring(cancel_result.cleanup))
  local cancel_child = WheelHost.fs.read_file(cancel_child_path)
  local cancel_grandchild = WheelHost.fs.read_file(cancel_grandchild_path)
  cancel_child = cancel_child and trim(cancel_child) or ""
  cancel_grandchild = cancel_grandchild and trim(cancel_grandchild) or ""
  check(cancel_child:match("^%d+$") ~= nil and cancel_grandchild:match("^%d+$") ~= nil,
    "the cancelled command must record its child and grandchild PIDs")
  fixture_wait_gone(cancel_child, "cancelled child")
  fixture_wait_gone(cancel_grandchild, "cancelled grandchild")
  check(cancel_sentinel:poll() == nil, "cancellation must not terminate an unrelated job")
  check(fixture_process_state(sentinel_pgid) ~= nil,
    "the unrelated job group must still be running after cancellation")

  local repeat_ok, repeat_info = cancel_target:cancel()
  check(repeat_ok == true and repeat_info.state == "already_cancelled",
    "repeated cancellation must be an idempotent no-op")
  check(repeat_info.term_sent == false, "repeated cancellation must not send another TERM")

  local cancel_timeout = WheelHost.proc.start("sleep", { "30" }, {
    timeout_ms = 300,
    job_root = cancel_root,
  })
  local timeout_result = cancel_timeout and cancel_timeout:wait(5000)
  check(timeout_result ~= nil and timeout_result.outcome == WheelHost.PROCESS_OUTCOME.TIMEOUT,
    "timeout must remain distinct from cancellation")
  check(timeout_result.timed_out == true and timeout_result.cancel_requested == false,
    "a timeout must not claim cancellation")
  check(timeout_result.terminal_reason == "timeout",
    "a timeout must publish the timeout terminal reason")
  check(timeout_result.cleanup == WheelHost.GROUP_CLEANUP.SWEPT,
    "a timeout must still sweep the recorded group")

  local sentinel_cancelled, sentinel_info = cancel_sentinel:cancel()
  check(sentinel_cancelled == true and sentinel_info.state == "requested",
    "the sentinel cleanup cancel must be accepted")
  check(cancel_sentinel:wait(5000) ~= nil, "the sentinel must reach a terminal result")
  check(cancel_target:close() == true, "the cancelled job record must close")
  check(cancel_timeout and cancel_timeout:close() == true, "the timeout job record must close")
  check(cancel_sentinel:close() == true, "the sentinel job record must close")

  state.coverage[#state.coverage + 1] =
    "cancellation: long command cancelled during execution with a distinct terminal reason"
  state.coverage[#state.coverage + 1] =
    "cancellation: recorded group swept, child and grandchild gone, unrelated job untouched"
  state.coverage[#state.coverage + 1] =
    "cancellation: repeated request idempotent; timeout and cancellation remain distinct"
  if cancel_cli_used then
    state.coverage[#state.coverage + 1] =
      "cancellation: separate scripts/wheel-proc process validated the job and signalled the recorded group"
  else
    state.coverage[#state.coverage + 1] =
      "cancellation: installed-tree handle path only (scripts/ is not packaged)"
  end

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

  -- 9. Project-configuration trust gate: bounded full-content consent, diff,
  -- exact-hash confirmation, persistence across a module restart, and
  -- user-facing revocation. The store is the fixture's private XDG state.
  local trust_project = BASE .. "/trust-project"
  check(WheelHost.fs.mkdir_p(trust_project .. "/.wheel"),
    "cannot create the trust fixture project")
  local trust_entry = trust_project .. "/.wheel/init.lua"
  local trust_v1 = 'return { verification = { test_command = "make trust-v1" } }\n'
  local trust_v2 = 'return { verification = { test_command = "make trust-v2" } }\n'
  check(WheelHost.fs.write_file(trust_entry, trust_v1),
    "cannot write the trust fixture entry")

  local trust_wheel, trust_capture = activate_uninstrumented("trust-flow")
  check(type(trust_wheel) == "table", "trust activation must return the entry module")
  local trust_def = trust_capture.registrations["trust"]
  check(trust_def ~= nil, "the trust command must be registered")

  local function run_trust(args)
    trust_capture.notifications = {}
    local ok, result = pcall(trust_def.run, args)
    check(ok, "trust command failed: " .. tostring(result))
    check(type(trust_capture.notifications) == "table"
      and #trust_capture.notifications >= 1,
      "trust command emitted no notification")
    local bodies = {}
    for _, notification in ipairs(trust_capture.notifications) do
      check(type(notification.body) == "string" and #notification.body > 0,
        "trust notification body must be non-empty")
      bodies[#bodies + 1] = notification.body
    end
    return table.concat(bodies, "\n"), result, #trust_capture.notifications
  end

  local show_text, show_result = run_trust({ path = trust_project })
  local shown_hash = show_text:match("SHA%-256: (%x+)")
  check(shown_hash ~= nil and #shown_hash == 64,
    "the consent view must contain the full 64-hex hash")
  check(show_text:find('return { verification = { test_command = "make trust-v1" }', 1, true) ~= nil,
    "the consent view must contain the full entry content")
  check(show_result ~= nil and type(show_result.body) == "string"
    and show_result.body:find("Wheel project trust consent summary", 1, true) ~= nil,
    "the command result must be a bounded consent summary")
  check(show_result.body:find(shown_hash, 1, true) ~= nil,
    "the command summary must carry the full hash")
  check(#show_result.body <= 8000,
    "the consent summary must fit the host result body cap")
  check(show_text:find("Canonical project root: " .. trust_project, 1, true) ~= nil,
    "the consent view must show the canonical project root")
  check(show_text:find("BEGIN PROJECT CONFIGURATION CONTENT [", 1, true) ~= nil,
    "the consent view must use a nonce-delimited content block")
  check(show_text:find("    | ", 1, true) ~= nil,
    "the consent view must prefix content lines")
  check(show_text:find("DIFF AGAINST PREVIOUSLY TRUSTED CONTENT [", 1, true) ~= nil,
    "the consent view must carry the nonce-delimited diff section")
  check(show_text:find("does not evaluate untrusted project code", 1, true) ~= nil,
    "the consent view must state the pre-consent effects limitation")
  check(WheelHost.fs.read_file(trust_entry) == trust_v1,
    "showing consent must not modify the entry")
  state.coverage[#state.coverage + 1] =
    "trust: consent showed canonical root, full entry, full SHA-256, diff section, and no pre-consent evaluation"

  local refused = run_trust({ action = "confirm", path = trust_project,
    hash = string.rep("0", 64) })
  check(refused:find("Trust gate refused", 1, true) ~= nil,
    "a mismatched confirmation hash must be refused")
  check(refused:find("E_TRUST_HASH_MISMATCH", 1, true) ~= nil,
    "a mismatched confirmation must name the typed hash failure")

  local approved = run_trust({ action = "confirm", path = trust_project, hash = shown_hash })
  check(approved:find("approved", 1, true) ~= nil,
    "an exact confirmation hash must approve the entry: " .. tostring(approved))
  check(approved:find(shown_hash, 1, true) ~= nil,
    "the approval result must echo the full hash")

  local store_path = os.getenv("XDG_STATE_HOME") .. "/wheel/trusted_projects.json"
  local store_raw = WheelHost.fs.read_file(store_path)
  check(type(store_raw) == "string" and store_raw ~= "",
    "the trust store must be written")
  check(store_raw:find('"version":1', 1, true) ~= nil,
    "the trust store must use schema version 1")
  check(store_raw:find('"content"', 1, true) ~= nil,
    "the trust store must retain full content for diffs")
  check(store_raw:find('"approved_at"', 1, true) ~= nil,
    "the trust store must retain the approval timestamp")
  local store_mode = WheelHost.proc.run_program("stat", { "-c", "%a", store_path })
  check(store_mode.ok and trim(store_mode.stdout) == "600",
    "the trust store must be mode 0600: " .. tostring(store_mode.stdout))
  local store_dir_mode = WheelHost.proc.run_program(
    "stat", { "-c", "%a", os.getenv("XDG_STATE_HOME") .. "/wheel" })
  check(store_dir_mode.ok and trim(store_dir_mode.stdout) == "700",
    "the trust store directory must be mode 0700: " .. tostring(store_dir_mode.stdout))

  local WheelConfig = require("wheel.config")
  local trusted_load = WheelConfig.load({ project_root = trust_project })
  check(trusted_load.ok == true and trusted_load.trusted == true,
    "the approved project must load: " .. tostring(trusted_load.error))
  check(trusted_load.config.verification.test_command == "make trust-v1",
    "the approved project configuration must apply")

  -- Content change invalidates the record and shows a diff on re-approval.
  check(WheelHost.fs.write_file(trust_entry, trust_v2), "cannot change the trust fixture entry")
  local changed_load = WheelConfig.load({ project_root = trust_project })
  check(changed_load.ok == false and changed_load.error == "untrusted_project_config",
    "changed content must invalidate trust before re-approval")
  local changed_text = run_trust({ path = trust_project })
  check(changed_text:find("changed since the last approval", 1, true) ~= nil,
    "the consent view must report changed content")
  check(changed_text:find("-" .. trust_v1:gsub("\n$", ""), 1, true) ~= nil,
    "the diff must show the previously trusted line")
  check(changed_text:find("+" .. trust_v2:gsub("\n$", ""), 1, true) ~= nil,
    "the diff must show the current line")
  local shown_v2 = changed_text:match("SHA%-256: (%x+)")
  check(shown_v2 ~= nil and shown_v2 ~= shown_hash,
    "the changed entry must have a different full hash")

  local stale = run_trust({ action = "confirm", path = trust_project, hash = shown_hash })
  check(stale:find("E_TRUST_HASH_MISMATCH", 1, true) ~= nil,
    "the previous hash must not approve changed content")
  local reapproved = run_trust({ action = "confirm", path = trust_project, hash = shown_v2 })
  check(reapproved:find("approved", 1, true) ~= nil,
    "the new hash must approve the changed content")

  -- True process restart: a separate Lua process reads the same store and loads
  -- the project. The child prints a marker because Lua 5.1 popen status is not
  -- observable reliably.
  local restart_script = BASE .. "/trust-restart.lua"
  local restart_source = string.format([[
package.path = %q
local C = require("wheel.config")
local res = C.load({ project_root = %q })
if res.ok and res.trusted
  and res.config.verification.test_command == "make trust-v2" then
  io.write("RESTART-TRUSTED\n")
  os.exit(0)
end
io.write("RESTART-NOT-TRUSTED\n")
os.exit(1)
]], package.path, trust_project)
  check(WheelHost.fs.write_file(restart_script, restart_source),
    "cannot write the restart probe")
  local interpreter = (arg and arg[-1]) or "lua5.1"
  local restart = WheelHost.proc.run_program(interpreter, { restart_script })
  check(restart.ok and (restart.stdout or ""):find("RESTART-TRUSTED", 1, true) ~= nil,
    "a separate process must see the approved project as trusted: "
      .. tostring(restart.stdout) .. tostring(restart.stderr))
  state.coverage[#state.coverage + 1] =
    "trust: a separate Lua process read the persisted approval and loaded the project"

  -- A consent view that exceeds one notification is chunked, not truncated:
  -- every byte of a 20 KiB entry must reach the notification series.
  local large_project = BASE .. "/trust-large"
  check(WheelHost.fs.mkdir_p(large_project .. "/.wheel"),
    "cannot create the large consent fixture")
  local padding = string.rep("-- consent padding line 0123456789\n", 600)
  local large_entry = padding .. 'return { verification = { test_command = "make large" } }\n'
  check(WheelHost.fs.write_file(large_project .. "/.wheel/init.lua", large_entry),
    "cannot write the large consent entry")
  local large_text, _, large_count = run_trust({ path = large_project })
  check(large_count >= 3,
    "a large consent view must span multiple notifications, got " .. tostring(large_count))
  check(large_text:find("-- consent padding line 0123456789", 1, true) ~= nil,
    "the chunked consent view must include the entry body")
  check(large_text:find('verification = { test_command = "make large" }', 1, true) ~= nil,
    "the chunked consent view must include the final entry line")

  -- Restart: clear module state and read the persisted store again.
  clear_wheel_modules()
  local WheelConfigRestart = require("wheel.config")
  local restarted = WheelConfigRestart.load({ project_root = trust_project })
  check(restarted.ok == true and restarted.trusted == true,
    "approval must persist across a module restart")
  check(restarted.config.verification.test_command == "make trust-v2",
    "the re-approved configuration must apply after restart")
  state.coverage[#state.coverage + 1] =
    "trust: approval, content change, re-approval, and persisted trust survived a module restart"

  -- Revocation is user-facing and removes the canonical record.
  local _, revoke_capture = activate_uninstrumented("trust-revoke")
  local revoke_def = revoke_capture.registrations["trust"]
  revoke_capture.notifications = {}
  local revoke_ok, revoke_result = pcall(revoke_def.run, { action = "revoke", path = trust_project })
  check(revoke_ok, "trust revoke failed: " .. tostring(revoke_result))
  local revoke_text = table.concat((function()
    local bodies = {}
    for _, notification in ipairs(revoke_capture.notifications) do
      bodies[#bodies + 1] = notification.body
    end
    return bodies
  end)(), "\n")
  check(revoke_text:find("Trust records removed: 1", 1, true) ~= nil,
    "trust revoke must report one removed record: " .. tostring(revoke_text))
  local revoked_load = require("wheel.config").load({ project_root = trust_project })
  check(revoked_load.ok == false and revoked_load.error == "untrusted_project_config",
    "revocation must invalidate the next configuration load")
  state.coverage[#state.coverage + 1] =
    "trust: user-facing revocation removed the record and invalidated the next load"

  -- 10. Evidence and cleanup.

  local cpu_cold = stats_for("cpu", "cold")
  local cpu_warm = stats_for("cpu", "warm")
  local instr_cold = stats_for("instructions", "cold")
  local instr_warm = stats_for("instructions", "warm")

  local write_ok, write_err = write_evidence("PASSED", nil)
  check(write_ok == true, "cannot write the real-host evidence: " .. tostring(write_err))

  print(string.format(
    "[PASS] real-host fixture: %d checks; 14/14 commands; hello; fs/proc/tmp/tool smoke; four denial classes; opt-in audit JSONL",
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
    -- Remove the ephemeral base from a temp root outside it: capture files for
    -- this command must survive the removal long enough to record the status.
    local cleanup_root = BASE .. ".cleanup"
    local cleanup_backend = WheelHost.create_backend("standalone", { tmp_root = cleanup_root })
    local removed = cleanup_backend.run_program("rm", { "-rf", BASE })
    if not (removed.ok and removed.code == 0) then
      print("[WARN] could not remove the ephemeral base: " .. tostring(removed.stderr))
    end
    os.execute("rmdir " .. shell_quote(cleanup_root) .. " 2>/dev/null")
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
