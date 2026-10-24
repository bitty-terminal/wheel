-- lua/wheel/host.lua
-- Wheel: Host-Capability Seam (filesystem / process / tmp / time)
--
-- Pure Lua 5.1 / LuaJIT implementation with zero external C dependencies.
--
-- WheelHost is the single seam between the Wheel harness and the machine it
-- runs on. Every filesystem, process, temporary-file, wall-clock, and CPU-time
-- primitive used by harness code is expressed here. The only direct
-- `io.open` / `io.popen` / `os.remove` / `os.execute` / `os.time` / `os.clock`
-- calls in `lua/wheel` live in this module's standalone backend; call sites use
-- the WheelHost wrappers:
--
--   WheelHost.fs.mkdir_p(path)              create a directory tree
--   WheelHost.fs.list_dir(path)             list directory entries
--   WheelHost.fs.read_file(path)            read a whole file
--   WheelHost.fs.read_file_bounded(path, n) read at most n bytes, chunked
--   WheelHost.fs.write_file(path, content)  write a whole file
--   WheelHost.fs.append_file(path, content) append to a private 0600 file
--   WheelHost.fs.create_private_file(path, content)
--                                           exclusive 0600 regular file at a path
--   WheelHost.fs.link_exclusive(from, to)   create a hard link without replacing
--   WheelHost.fs.mkfifo(path)               exclusive 0600 FIFO
--   WheelHost.fs.open_fifo(path)            open a verified 0600 FIFO read/write
--   WheelHost.fs.remove_dir(path)           remove one empty directory
--   WheelHost.fs.chmod(path, mode)          set a file mode
--   WheelHost.fs.mkdir(path)                create one 0700 directory exclusively
--   WheelHost.fs.random_bytes(count)        host random bytes (/dev/urandom)
--   WheelHost.fs.rename(from, to)           atomically rename within a filesystem
--   WheelHost.fs.remove_file(path)          remove a file
--   WheelHost.fs.exists(path)               test for a readable file
--   WheelHost.fs.stat(path)                 lstat-style metadata and type probes
--   WheelHost.fs.euid()                     current effective uid
--   WheelHost.proc.run_command(shell_string, env?, opts?)
--                                           run a shell command line (explicit
--                                           shell-string primitive)
--   WheelHost.proc.run_program(program, args, opts?)
--                                           run argv with stdin, cwd, timeout,
--                                           output cap, and scrubbed env
--   WheelHost.proc.start(program, args, opts?)
--                                           start a recorded job handle
--                                           (poll/wait/cancel/close)
--   WheelHost.proc.start_command(shell, opts?)
--                                           start a shell-string job handle
--   WheelHost.proc.cancel_job(job_id, opts?)
--                                           cancel a recorded job by id
--   WheelHost.proc.signal_group(pgid, sig)  recorded-PGID liveness/TERM/KILL
--   WheelHost.proc.shell_quote(value)       quote one POSIX shell argument
--   WheelHost.proc.pid()                    current process id
--   WheelHost.proc.is_alive(pid)            `kill -0` liveness probe
--   WheelHost.tmp.dir()                     private runtime directory
--   WheelHost.tmp.name()                    unique path inside that directory
--   WheelHost.tmp.create(content)           exclusive 0600 file, returns path
--   WheelHost.tmp.create_exclusive(path, content)
--                                           exclusive 0600 file at a given path
--   WheelHost.time.now()                    wall-clock seconds
--   WheelHost.time.clock()                  CPU seconds
--   WheelHost.time.sleep_ms(ms)             bounded host sleep
--
-- Backend selection (Option B):
-- The harness runs out of process and holds execution authority, so the
-- standalone POSIX backend is the production execution model. Selection is an
-- explicit, named call: `WheelHost.select_backend("standalone")`. The module
-- performs exactly that call once when the host seam is constructed (the first
-- host-dependent operation after lazy activation). There is deliberately no
-- `bitty.api_version` probe, no plugin-host adapter, and no second backend: a
-- Bitty panel or terminal supplies presentation and input only. A future host
-- IPC client would also be presentation-only and is not an execution adapter.
--
-- Standalone-only fallback decision: when the platform is not POSIX (Lua's
-- `package.config` directory separator is not `/`) or when a caller names an
-- unknown backend, backend construction fails closed with the typed
-- `E_CAPABILITY_DENIED` error instead of silently using a weaker surface.
-- Individual primitives fail closed the same way when their surface is absent
-- (for example a sandbox that removes `io` or `os.execute`); an unavailable
-- primitive never degrades to a nil call or a silent fallback.
--
-- Standalone backend:
-- The backend table executes against the local POSIX host with `io.open`,
-- `io.popen`, `os.remove`, `os.execute`, `os.time`, and `os.clock`. The command
-- string passed to `proc.run_command` is the explicit shell-string primitive
-- used by Execute-intent tools; inspect-intent call sites use `run_program`,
-- which passes each argv element as a positional argument to a constant POSIX
-- shell wrapper and then to `env -- "$@"` (stdin redirected from a positional
-- path). No call site builds an unquoted shell string, and a program named
-- `-S`/`-i` cannot become an env option.
--
-- Process bounds and environment:
-- A supervisor starts a `setsid -w` session leader that records its own
-- PID/PGID, then runs the scrubbed command under GNU `timeout` (or `gtimeout`)
-- with `--foreground`, so timeout signals only the direct child on expiry. The
-- session leader is retained through the bounded group sweep: it waits for the
-- command, writes the direct command's status to a private 0600 file before
-- signaling anything, ignores TERM, sends TERM to its own process group, waits
-- the sweep grace, records the sweep marker, and sends KILL to the group (which
-- includes the leader). Because the leader holds the recorded PGID until that
-- final KILL, the PGID cannot be reused while signals are sent, so the sweep
-- can only target the recorded group. If the leader dies before the sweep, no
-- signal is sent and the result reports `cleanup = "unverified"`. A child that
-- calls `setsid` or joins another process group can still escape. stdout and
-- stderr are redirected to private 0600 files and read back through a fixed cap
-- (`WheelHost.LIMITS.MAX_CAPTURE_BYTES`, 256 KiB) so output cannot exhaust
-- harness memory. The child environment is rebuilt from the allowlist in
-- `ENV_ALLOWLIST` (PATH, HOME, LANG/LC_ALL, TERM, TMPDIR,
-- XDG_RUNTIME_DIR/XDG_STATE_HOME/XDG_CONFIG_HOME) plus explicit `opts.env`
-- declarations; PATH is copied from the parent and sanitized to absolute
-- entries rather than inherited implicitly. Secret-shaped names are refused
-- even as explicit declarations, and the wrapper strips shell-added
-- `PWD`/`SHLVL`/`_` with `env -u` so an argv child sees only the allowlist. stdin
-- is `/dev/null` unless `opts.stdin` supplies bytes, which are staged in an
-- exclusive 0600 file. `setsid`, `sleep`, `env`, `timeout`/`gtimeout`, and `sh`
-- must be resolvable or the primitive fails closed as `unavailable`.
-- `WheelHost.backend` is the documented swap point for tests; call sites never
-- touch it directly.
--
-- Execution audit (CTX-0030):
-- `proc.run_program(program, args, opts)`, `proc.run_command(shell, env, opts)`,
-- and the asynchronous `proc.start` handle accept an optional `opts.audit`
-- table. The sink is opt-in: omitting it
-- never resolves, creates, or writes an audit directory, so existing call
-- sites and tests are unchanged. When supplied, the table may carry `dir` (an
-- explicit test/embedding override), `role`, `agent`, `task`, `tool`, `intent`,
-- `decision` (`"allow"` or `"deny"`), `reason`, and `high_risk`. A pre-spawn
-- record with the redacted argv or shell command, cwd, decision, reason, and a
-- stable command hash is written before the wrapper launches; a completion
-- record carries exit status, duration, truncation, and group cleanup. A
-- `"deny"` decision is a recorded refusal and never launches. When
-- `high_risk` is true and the pre-spawn write fails, the command is not
-- launched and the result carries the typed `E_AUDIT_UNAVAILABLE` error; a
-- lower-risk write failure continues with `result.audit_warning` set. The
-- process result therefore may also carry `spawned`, `denied`, `audit_error`,
-- and `audit_warning`. A recorded job also writes `process.cancel_requested`
-- and `process.cancel_outcome` through the same opt-in sink; a high-risk
-- cancellation whose request record cannot be written is refused before any
-- signal, while a lower-risk failure continues with `audit_warning`. Full
-- prompts, output, environment values, file contents, and provider responses
-- are never passed to the sink.
--
-- Process result shape: every `proc.*` primitive returns
-- { ok, code, exit_code, stdout, stderr, timed_out, truncated,
--   stdout_truncated, stderr_truncated, outcome, cleanup, pgid?,
--   cancel_requested?, terminal_reason?, job_id? } where `ok`
-- reports that the execution was launched by the backend (a nonzero `code`
-- still has ok = true; a timeout is a launched process), `code`/`exit_code`
-- carry the POSIX exit status recorded by the retained leader, and `outcome` is
-- one of `WheelHost.PROCESS_OUTCOME` (`exited`, `timeout`, `cancelled`,
-- `unavailable`, `failure`). `cleanup` is one of `WheelHost.GROUP_CLEANUP`
-- (`swept`, `unverified`, `not_run`), and `pgid` is the recorded process-group
-- id when the retained leader wrote it. GNU timeout maps expiry to 124
-- (kill-after escalation may surface 137); a command that itself exits 124/137
-- is indistinguishable and is reported as a timeout.
--
-- Recorded jobs and cancellation (CTX-0034):
-- `proc.start(program, args, opts)` returns a handle with `poll`,
-- `wait(timeout_ms)`, `cancel(opts)`, and `close`; `proc.start_command` is the
-- shell-string form. The command runs in the same `setsid`-recorded group under
-- the same timeout, capture, and environment bounds as `run_program`. The job
-- record is a private 0700 directory with an owned 0600 metadata file holding
-- a random job id, a random generation token, the recorded leader PID/PGID,
-- the timeout, and optional audit identity. Cancellation validates the record
-- and the live leader (generation, process group, and session) before sending
-- only `kill -0`, TERM, or KILL to the recorded PGID; there is no name- or
-- pattern-based kill and no fallback to an unrecorded PID. The request
-- publishes a first-writer-wins terminal reason, sends TERM, waits the bounded
-- grace, and sends KILL only if the group is still present. The terminal reason
-- distinguishes `cancelled` from `timeout`/`exited`; repeated cancellation is
-- idempotent and a terminal job is a typed no-op. `opts.job_root` is an
-- explicit test/embedding root (documented swap point); the default is
-- `<private tmp dir>/jobs`.
--
-- Temporary files:
-- `WheelHost.tmp.name()` never uses the ambient temporary-name API. It returns
-- a unique path inside a private directory: `$XDG_RUNTIME_DIR/wheel` when the
-- runtime directory is set, otherwise `$XDG_STATE_HOME/wheel/tmp`, otherwise
-- `$HOME/.local/state/wheel/tmp`. The directory is created (or repaired) with
-- mode 0700 before a path is returned. `tmp.create` and `tmp.create_exclusive`
-- create files with `set -C` (noclobber) under `umask 077`, so a pre-existing
-- file or symbolic link is refused rather than followed or truncated; callers
-- remove the file when the job closes. A caller may inject an explicit
-- `tmp_root` (for example a workspace-local `.wheel/tmp`) through the backend
-- options.
--
-- Command-override seam: `proc.run_command(shell_string, env)` honors
-- `env.command_runner` when set - the test-injection override already
-- supported by the run_command tool - and normalizes the tool-shaped runner
-- result ({ success, exit_code, stdout, stderr }) into the WheelHost proc
-- shape. The run_command tool also keeps calling an injected runner directly
-- first, so a runner's untrimmed result (including extra fields such as
-- `status` or `duration_ms`) continues to pass through untouched.

local WheelHost = {}
local WheelErrors = require("wheel.errors")
local WheelAudit = require("wheel.audit")
local WheelJob = require("wheel.job")

-- ---------------------------------------------------------------------------
-- Shared helpers
-- ---------------------------------------------------------------------------

--- Single-quote a value for safe inclusion in a POSIX shell command line.
-- @param value string
-- @return string
local function shell_quote(value)
  return "'" .. string.gsub(tostring(value or ""), "'", "'\\''") .. "'"
end

--- Split raw process output into lines with file:lines() semantics.
-- A trailing newline does not produce a trailing empty entry, empty input
-- produces no entries, and interior empty lines are preserved.
-- @param data string
-- @return string[] lines
local function split_lines(data)
  local lines = {}
  if type(data) ~= "string" or data == "" then
    return lines
  end
  local pos = 1
  while true do
    local nl = data:find("\n", pos, true)
    if not nl then
      if pos <= #data then
        table.insert(lines, data:sub(pos))
      end
      break
    end
    table.insert(lines, data:sub(pos, nl - 1))
    pos = nl + 1
  end
  return lines
end

--- Fail with a typed capability denial when a primitive surface is absent.
-- @param available boolean
-- @param capability string
local function require_surface(available, capability)
  if not available then
    error(WheelErrors.capability_denied(capability), 0)
  end
end

-- ---------------------------------------------------------------------------
-- Process and temporary-file bounds
-- ---------------------------------------------------------------------------
--
-- Process bounds are enforced below. Every child process runs with one
-- explicit wall-clock timeout, and each stream is captured to a private file
-- and read back through a fixed byte cap, so a runaway child cannot exhaust
-- harness memory. Timeout enforcement is delegated to GNU `timeout` (coreutils
-- or `gtimeout`) with `--foreground`, which signals only the direct child on
-- expiry. The harness retains the recorded session leader through the bounded
-- TERM/grace/KILL group sweep, so the recorded PGID cannot be reused while it
-- is being signaled. The harness never sends a name- or pattern-based kill.

--- Private file/FIFO mode required by the host-owned paths (0600).
local PRIVATE_FILE_MODE = 384

--- Maximum bytes read back from each captured stream (256 KiB).
local MAX_CAPTURE_BYTES = 256 * 1024

--- Default wall-clock timeout for one child process (120 s).
local DEFAULT_TIMEOUT_MS = 120000

--- Maximum caller-selectable timeout (10 min).
local MAX_TIMEOUT_MS = 600000

--- Minimum caller-selectable timeout (50 ms); GNU timeout accepts fractions.
local MIN_TIMEOUT_MS = 50

--- Grace period between SIGTERM and SIGKILL for the owned process group.
local KILL_AFTER_MS = 2000

--- Grace period for the retained-leader group sweep (TERM, then KILL).
local SWEEP_GRACE_MS = 250

--- Maximum leader-side attempts to acquire the terminal-transition lock.
-- The leader waits 200 x 10 ms (2 s), deliberately below the canceller's
-- bounded 3 s lock window, so a slow canceller keeps first-writer authority and
-- the leader never treats a lock it did not acquire as its own.
local LEADER_LOCK_ATTEMPTS = 200

--- Leader-side lock retry interval (10 ms).
local LEADER_LOCK_INTERVAL_MS = 10

--- Maximum bytes accepted for one stdin payload (1 MiB).
local MAX_STDIN_BYTES = 1024 * 1024

--- Maximum bytes captured while reading one file chunk.
local READ_CHUNK_BYTES = 8192

--- Maximum size of one environment value or path.
local MAX_ENV_VALUE_BYTES = 4096

--- Maximum number of PATH entries after sanitization.
local MAX_ENV_ENTRIES = 128

--- Maximum exclusive-creation attempts before failing closed.
local MAX_TMP_CREATE_ATTEMPTS = 16

--- Maximum bytes accepted from the host random source in one read.
local MAX_RANDOM_BYTES = 64

--- Maximum bounded host sleep (60 s).
local MAX_SLEEP_MS = 60000

--- Environment variables passed through when present. Nothing else is
--- inherited: the child environment is rebuilt from this list plus explicit
--- caller declarations. XDG_STATE_HOME/XDG_CONFIG_HOME are included because a
--- nested harness process (for example a trust-restart probe) must resolve the
--- same user state; they are paths, never secrets.
local ENV_ALLOWLIST = {
  "PATH",
  "HOME",
  "LANG",
  "LC_ALL",
  "TERM",
  "TMPDIR",
  "XDG_RUNTIME_DIR",
  "XDG_STATE_HOME",
  "XDG_CONFIG_HOME",
}

--- Allowlisted names whose value must be an absolute path.
local ENV_PATH_NAMES = {
  HOME = true,
  TMPDIR = true,
  XDG_RUNTIME_DIR = true,
  XDG_STATE_HOME = true,
  XDG_CONFIG_HOME = true,
}

--- Locale/terminal values accepted without shell-active characters.
local ENV_TOKEN_NAMES = {
  LANG = true,
  LC_ALL = true,
  TERM = true,
}

--- Names that can inject code or libraries into a child shell/runtime.
local ENV_FORBIDDEN_NAMES = {
  IFS = true,
  ENV = true,
  BASH_ENV = true,
  CDPATH = true,
  GLOBIGNORE = true,
  SHELLOPTS = true,
  BASHOPTS = true,
  PS4 = true,
  PROMPT_COMMAND = true,
}

--- Process outcome vocabulary returned by every process primitive.
WheelHost.PROCESS_OUTCOME = {
  EXITED = "exited",
  TIMEOUT = "timeout",
  CANCELLED = "cancelled",
  UNAVAILABLE = "unavailable",
  FAILURE = "failure",
}

--- Process-group cleanup vocabulary. `swept` means the retained session leader
--- completed the TERM/grace/KILL sweep of its own recorded group. `unverified`
--- means the leader did not report the sweep marker, so no signal was sent after
--- its identity was lost; descendants may survive. `not_run` means no group was
--- launched (validation, unavailable surface, or spawn failure).
WheelHost.GROUP_CLEANUP = {
  SWEPT = "swept",
  UNVERIFIED = "unverified",
  NOT_RUN = "not_run",
}

--- Named bounds exposed for callers, documentation, and tests.
WheelHost.LIMITS = {
  MAX_CAPTURE_BYTES = MAX_CAPTURE_BYTES,
  DEFAULT_PROCESS_TIMEOUT_MS = DEFAULT_TIMEOUT_MS,
  MAX_PROCESS_TIMEOUT_MS = MAX_TIMEOUT_MS,
  MIN_PROCESS_TIMEOUT_MS = MIN_TIMEOUT_MS,
  SWEEP_GRACE_MS = SWEEP_GRACE_MS,
  MAX_STDIN_BYTES = MAX_STDIN_BYTES,
  MAX_ENV_VALUE_BYTES = MAX_ENV_VALUE_BYTES,
  MAX_ENV_ENTRIES = MAX_ENV_ENTRIES,
  READ_CHUNK_BYTES = READ_CHUNK_BYTES,
  MAX_RANDOM_BYTES = MAX_RANDOM_BYTES,
  MAX_SLEEP_MS = MAX_SLEEP_MS,
  LEADER_LOCK_ATTEMPTS = LEADER_LOCK_ATTEMPTS,
  LEADER_LOCK_INTERVAL_MS = LEADER_LOCK_INTERVAL_MS,
}

--- Process-group supervisor wrapper. It runs the launch under `setsid -w` and
--- leaves stdout/stderr to the outer diagnostics redirection; the leader owns
--- the command's capture files. Its own stderr, including the shell's expected
--- SIGKILL report for the retained leader, therefore lands in the wrapper
--- diagnostics, never in the command's captured stderr. The leader performs the
--- group sweep, so the wrapper never signals anything and always exits 0.
local SUPERVISOR_SCRIPT = 'out="$1"; err="$2"; shift 2; "$@" > /dev/null; exit 0'

--- Session leader and group-identity holder. It records its own PID/PGID, runs
--- the scrubbed command in the same group with explicit private capture files,
--- writes the direct command's status before any signal, then holds the group
--- identity through TERM, the bounded grace, and the final KILL. The KILL
--- targets the whole recorded group and therefore takes the leader with it; the
--- status and sweep files are already written. The leader ignores TERM from its
--- start so a cancellation TERM can interrupt the command without killing the
--- identity holder; the direct child resets TERM to the default. When a job
--- terminal path is supplied, the leader publishes `exited`, `timeout`, or
--- `cancelled` exactly once under an exclusive `mkdir` lock. After recording
--- status, the leader sends its own stderr to `/dev/null`, so any shell
--- diagnostic for the self-KILL cannot leak into the wrapper's command stream.
--- A leader that exits early never signals anything. No caller value is
--- interpolated into the script; the generation token is a positional argument
--- used only as command-line identity for the canceller.
local LEADER_SCRIPT = 'umask 077; pgid_file="$1"; status_file="$2"; sweep_file="$3"; out="$4"; err="$5"; grace="$6"; sleep_bin="$7"; cancel_file="$8"; terminal_file="$9"; lock_dir="${10}"; generation="${11}"; lock_attempts="${12}"; lock_interval="${13}"; shift 13; trap "" TERM; printf "%s\\n" "$$" > "$pgid_file" || exit 125; ( trap - TERM; exec "$@" ) > "$out" 2> "$err" & child=$!; wait "$child"; status=$?; printf "%s" "$status" > "$status_file" || :; if [ -n "$terminal_file" ]; then lock_held=0; i=0; while [ "$i" -lt "$lock_attempts" ]; do if mkdir "$lock_dir" 2>/dev/null; then lock_held=1; break; fi; i=$((i+1)); "$sleep_bin" "$lock_interval" 2>/dev/null || break; done; if [ "$lock_held" = "1" ]; then if [ ! -e "$terminal_file" ]; then if [ -e "$cancel_file" ]; then printf "%s" "cancelled" > "$terminal_file"; elif [ "$status" = "124" ] || [ "$status" = "137" ]; then printf "%s" "timeout" > "$terminal_file"; else printf "%s" "exited" > "$terminal_file"; fi; fi; rmdir "$lock_dir" 2>/dev/null || :; fi; fi; exec 2>/dev/null; kill -TERM -"$$" 2>/dev/null || :; "$sleep_bin" "$grace" 2>/dev/null || :; printf "%s" "swept" > "$sweep_file" 2>/dev/null || :; kill -KILL -"$$" 2>/dev/null || :; exit "$status"'

--- Normalize an os.execute result into a POSIX exit status.
-- Lua 5.1 reports the raw wait status (exit 1 -> 256); Lua 5.2+ reports
-- `nil, "exit", code` (or `nil, "signal", signal`). All returns must be
-- captured; otherwise the string reason would be mistaken for a code and a
-- probe failure would look like exit status 1. A non-zero raw status below 256
-- is a signal, not an exit code: the low seven bits carry the signal number and
-- bit 7 is the core-dump flag.
-- @param ok boolean|number|nil
-- @param reason string|nil
-- @param code number|nil
-- @return number? status
local function normalized_exit_status(ok, reason, code)
  if ok == true then
    return 0
  end
  if type(ok) == "number" then
    if ok >= 256 then
      return math.floor(ok / 256)
    end
    if ok == 0 then
      return 0
    end
    return 128 + (ok % 128)
  end
  if ok == nil and reason == "exit" and type(code) == "number" then
    return code
  end
  if ok == nil and reason == "signal" and type(code) == "number" then
    return 128 + code
  end
  if type(code) == "number" then
    return code
  end
  return nil
end

--- Build a typed process result for a launch/validation failure.
-- @param message string
-- @param outcome string?
-- @return table
local function process_failure(message, outcome)
  return {
    ok = false,
    code = 1,
    exit_code = 1,
    stdout = "",
    stderr = tostring(message or "process failed"),
    timed_out = false,
    truncated = false,
    stdout_truncated = false,
    stderr_truncated = false,
    outcome = outcome or WheelHost.PROCESS_OUTCOME.FAILURE,
    cleanup = WheelHost.GROUP_CLEANUP.NOT_RUN,
  }
end

--- Sanitize PATH: absolute entries only, no empty (cwd) entries, no control
-- bytes, bounded length and entry count, duplicates removed. An empty result
-- fails closed instead of inheriting an implicit search path.
-- @param value string?
-- @return string? sanitized_path
local function sanitize_path_list(value)
  if type(value) ~= "string" or value == "" then
    return nil
  end
  local entries, seen = {}, {}
  for entry in value:gmatch("[^:]+") do
    if entry:sub(1, 1) == "/"
      and #entry <= MAX_ENV_VALUE_BYTES
      and not entry:find("[%z\n\r]")
      and not seen[entry] then
      seen[entry] = true
      entries[#entries + 1] = entry
      if #entries > MAX_ENV_ENTRIES then
        return nil
      end
    end
  end
  if #entries == 0 then
    return nil
  end
  return table.concat(entries, ":")
end

--- Test whether an environment variable name is safe to declare.
-- @param name string?
-- @return boolean
local function valid_env_name(name)
  return type(name) == "string"
    and #name <= 64
    and name:match("^[A-Z_][A-Z0-9_]*$") ~= nil
end

--- Test whether a name is forbidden or secret-shaped. Secret-shaped names are
-- never inherited, including through an explicit caller declaration.
-- @param name string
-- @return boolean
local function forbidden_env_name(name)
  if ENV_FORBIDDEN_NAMES[name]
    or name:match("^LD_") ~= nil
    or name:match("^DYLD_") ~= nil then
    return true
  end
  return name:match("_KEY$") ~= nil
    or name:match("_TOKEN$") ~= nil
    or name:match("_SECRET$") ~= nil
    or name:match("_PASSWORD$") ~= nil
    or name:match("_PASSWD$") ~= nil
    or name:match("_CREDENTIALS?$") ~= nil
end

--- Validate one environment value for its declared name.
-- @param name string
-- @param value string
-- @return boolean ok, string? reason
local function validate_env_value(name, value)
  if type(value) ~= "string" then
    return false, name .. " must be a string"
  end
  if #value > MAX_ENV_VALUE_BYTES or value:find("[%z\n\r]") then
    return false, name .. " is too long or contains control bytes"
  end
  if name == "PATH" then
    if sanitize_path_list(value) == nil then
      return false, "PATH must contain at least one absolute entry"
    end
    return true
  end
  if ENV_PATH_NAMES[name] and value:sub(1, 1) ~= "/" then
    return false, name .. " must be an absolute path"
  end
  if ENV_TOKEN_NAMES[name] and value:match("^[%w%._@%-]+$") == nil then
    return false, name .. " has an invalid value"
  end
  return true
end

--- Build the scrubbed child environment as a sorted list of NAME=value words.
-- @param getenv function os.getenv
-- @param overrides table? explicit caller declarations
-- @return table? assignments, string? err, string? outcome
local function build_child_environment(getenv, overrides)
  if type(getenv) ~= "function" then
    return nil, "environment access is unavailable",
      WheelHost.PROCESS_OUTCOME.UNAVAILABLE
  end
  local values = {}
  for _, name in ipairs(ENV_ALLOWLIST) do
    local value = getenv(name)
    if type(value) == "string" and value ~= "" then
      local ok = validate_env_value(name, value)
      if ok then
        values[name] = value
      end
    end
  end

  if overrides ~= nil then
    if type(overrides) ~= "table" then
      return nil, "process env overrides must be a table", WheelHost.PROCESS_OUTCOME.FAILURE
    end
    for name, value in pairs(overrides) do
      if not valid_env_name(name) then
        return nil, "invalid environment variable name", WheelHost.PROCESS_OUTCOME.FAILURE
      end
      if forbidden_env_name(name) then
        return nil, "environment variable '" .. name .. "' is not allowed for child processes",
          WheelHost.PROCESS_OUTCOME.FAILURE
      end
      local ok, reason = validate_env_value(name, value)
      if not ok then
        return nil, reason, WheelHost.PROCESS_OUTCOME.FAILURE
      end
      values[name] = value
    end
  end

  local path = sanitize_path_list(values.PATH)
  if path == nil then
    return nil, "PATH is not set or contains no absolute entries; refusing an implicit search path",
      WheelHost.PROCESS_OUTCOME.UNAVAILABLE
  end
  values.PATH = path

  local names = {}
  for name in pairs(values) do
    names[#names + 1] = name
  end
  table.sort(names)

  local assignments = {}
  for _, name in ipairs(names) do
    assignments[#assignments + 1] = name .. "=" .. values[name]
  end
  return assignments
end

--- Test whether <path> itself is a symbolic link (argv `test -L`).
-- Any result other than the POSIX true/false status fails closed, so a missing
-- `test` or an unexpected invocation error cannot be read as "not a link".
-- @param path string
-- @return boolean
local function path_is_symlink(path)
  require_surface(type(os) == "table" and type(os.execute) == "function", "fs.write")
  local ok, _, code = os.execute("test -L " .. shell_quote(path))
  -- Lua 5.1 reports the raw wait status (exit 1 -> 256); 5.2+ reports the
  -- exit code in `code`. Normalize both before deciding.
  local status
  if ok == true then
    status = 0
  elseif type(ok) == "number" then
    status = (ok >= 256) and math.floor(ok / 256) or ok
  else
    status = code
  end
  if status == 0 then
    return true
  end
  if status == 1 then
    return false
  end
  error(WheelErrors.capability_denied("fs.write"), 0)
end

--- Cached effective uid for private-file ownership checks.
local cached_euid = nil

--- Return the current effective uid, failing closed when it cannot be read.
-- @return number? uid
local function current_euid()
  if cached_euid ~= nil then
    return cached_euid
  end
  require_surface(type(io) == "table" and type(io.popen) == "function", "fs.write")
  local pipe = io.popen("id -u 2>/dev/null", "r")
  if not pipe then
    return nil
  end
  local line = pipe:read("*l")
  pipe:close()
  local uid = tonumber((line or ""):match("^%s*(%d+)%s*$"))
  if uid == nil then
    return nil
  end
  cached_euid = uid
  return uid
end

--- Read lstat-style metadata for a private file through `stat`.
-- The caller already rejects symlinks with `test -L`; this probe supplies
-- owner, mode, link count, and type. Any unparsable result fails closed.
-- @param path string
-- @return table? { uid, mode, links, kind }
local function private_file_metadata(path)
  require_surface(type(io) == "table" and type(io.popen) == "function", "fs.write")
  local pipe = io.popen("stat -c '%u %a %h %F' -- " .. shell_quote(path) .. " 2>/dev/null", "r")
  if not pipe then
    return nil
  end
  local line = pipe:read("*l")
  pipe:close()
  local uid, mode, links, kind = (line or ""):match("^(%d+)%s+(%d+)%s+(%d+)%s+(.+)$")
  if not uid or not mode or not links or not kind then
    return nil
  end
  return {
    uid = tonumber(uid),
    mode = tonumber(mode, 8),
    links = tonumber(links),
    kind = kind:lower(),
  }
end

--- Verify that <path> is the harness-owned regular 0600 file it claims to be.
-- Rejects symbolic links, FIFOs, devices, directories, foreign ownership,
-- group/world permissions, and multiply-linked paths before a caller opens it.
-- @param path string
-- @return boolean ok, string? err
local function verify_private_file(path)
  if path_is_symlink(path) then
    return false, "private path is a symbolic link"
  end
  local euid = current_euid()
  if euid == nil then
    return false, "cannot determine the effective uid"
  end
  local info = private_file_metadata(path)
  if info == nil then
    return false, "private path metadata is unavailable"
  end
  if not info.kind:match("^regular") then
    return false, "private path is not a regular file"
  end
  if info.uid ~= euid then
    return false, "private path is not owned by the current user"
  end
  if info.mode ~= PRIVATE_FILE_MODE then
    return false, "private path is not mode 0600"
  end
  if info.links ~= 1 then
    return false, "private path has an unexpected hard-link count"
  end
  return true
end

--- Verify that <path> is the harness-owned FIFO it claims to be.
-- Rejects symbolic links, regular files, devices, directories, foreign
-- ownership, group/world permissions, and multiply-linked paths before a
-- caller opens it.
-- @param path string
-- @return boolean ok, string? err
local function verify_private_fifo(path)
  if path_is_symlink(path) then
    return false, "private FIFO path is a symbolic link"
  end
  local euid = current_euid()
  if euid == nil then
    return false, "cannot determine the effective uid"
  end
  local info = private_file_metadata(path)
  if info == nil then
    return false, "private FIFO metadata is unavailable"
  end
  if not info.kind:match("^fifo") then
    return false, "private path is not a FIFO"
  end
  if info.uid ~= euid then
    return false, "private FIFO is not owned by the current user"
  end
  if info.mode ~= PRIVATE_FILE_MODE then
    return false, "private FIFO is not mode 0600"
  end
  if info.links ~= 1 then
    return false, "private FIFO has an unexpected hard-link count"
  end
  return true
end

--- Create a new empty 0600 regular file with `mktemp` in <dir> and verify it.
-- The caller receives a freshly created path, never a pre-existing one.
-- @param dir string
-- @return string? path, string? err
local function create_private_temp(dir)
  require_surface(type(io) == "table" and type(io.popen) == "function", "fs.write")
  local pipe = io.popen("mktemp " .. shell_quote(dir .. "/wheel-XXXXXX") .. " 2>/dev/null", "r")
  if not pipe then
    return nil, "mktemp is unavailable"
  end
  local path = pipe:read("*l")
  pipe:close()
  path = path and path:match("^%s*(.-)%s*$") or ""
  if path == "" or path:sub(1, #dir + 1) ~= dir .. "/" then
    return nil, "mktemp did not return a private path"
  end
  local ok, err = verify_private_file(path)
  if not ok then
    os.remove(path)
    return nil, err
  end
  return path
end

--- Write bytes to a verified private 0600 regular file that was just created.
-- The path is checked for regular-file type, ownership, mode, and link count
-- immediately before the open; `r+` never creates or truncates a path.
-- @param path string
-- @param content string
-- @return boolean ok, string? err
local function write_private_file(path, content)
  require_surface(type(io) == "table" and type(io.open) == "function", "fs.write")
  local verified, verify_err = verify_private_file(path)
  if not verified then
    return false, verify_err
  end
  local file, open_err = io.open(path, "r+")
  if not file then
    return false, tostring(open_err)
  end
  local wrote, write_err = file:write(content or "")
  if not wrote then
    file:close()
    return false, tostring(write_err or "write failed")
  end
  local close_ok, close_err = file:close()
  if not close_ok then
    return false, tostring(close_err or "close failed")
  end
  return true
end

--- Return the harness-owned parent component to guard alongside <dir>.
-- Only the `wheel` component of the state fallback (`.../wheel/tmp`) is
-- harness-owned. A legitimate parent such as `/tmp` (itself a symlink on some
-- systems) is intentionally not rejected.
-- @param dir string
-- @return string?
local function owned_parent_path(dir)
  if type(dir) ~= "string" then
    return nil
  end
  local prefix = dir:match("^(.*)/wheel/tmp$")
  if prefix then
    return prefix .. "/wheel"
  end
  return nil
end

--- Return true when any normalized path segment consists only of dots
-- (`.`, `..`, `...`, ...). This blocks both literal parent traversal and a
-- symlink whose name is all dots, which `test -L` would otherwise accept while
-- the path resolves through it.
-- @param path string
-- @return boolean
local function has_dot_only_segment(path)
  for segment in path:gmatch("[^/]+") do
    if segment:match("^%.+$") then
      return true
    end
  end
  return false
end

--- Normalize a temporary-directory path for the symlink guard and filesystem
-- calls. The path is rebuilt from its non-empty segments: repeated `/`
-- separators collapse, `.` segments are dropped everywhere (not only at the
-- end), and trailing separators disappear. The filesystem resolves
-- `.../wheel//tmp` and `.../wheel/./tmp` to `.../wheel/tmp`, so every guard
-- below must inspect that same collapsed form; otherwise the exact
-- `.../wheel/tmp` suffix check is skipped and a symlinked `wheel` parent is
-- followed. All-dots segments (`..`, `...`, ...) are preserved so
-- `has_dot_only_segment` can reject them before any mkdir/chmod.
-- @param path string
-- @return string
local function normalize_tmp_dir(path)
  if type(path) ~= "string" then
    return path
  end
  local absolute = path:sub(1, 1) == "/"
  local segments = {}
  for segment in path:gmatch("[^/]+") do
    if segment ~= "." then
      table.insert(segments, segment)
    end
  end
  local normalized = table.concat(segments, "/")
  if absolute then
    return "/" .. normalized
  end
  if normalized == "" then
    -- A relative path made only of separators and `.` segments is the process
    -- root once resolved; return `/` so the caller rejects it before use.
    return "/"
  end
  return normalized
end

--- Return the backend platform selected for construction.
-- An explicit `opts.platform` is honored for tests and embedding; otherwise the
-- interpreter's directory separator identifies a POSIX surface.
-- @param opts table?
-- @return string "posix" or "unsupported"
local function resolve_platform(opts)
  if type(opts) == "table" and opts.platform ~= nil then
    return tostring(opts.platform)
  end
  local config = type(package) == "table" and package.config or nil
  if type(config) == "string" and config:sub(1, 1) == "/" then
    return "posix"
  end
  return "unsupported"
end

-- ---------------------------------------------------------------------------
-- Standalone POSIX backend factory (the documented swap point)
-- ---------------------------------------------------------------------------

--- Standalone POSIX backend factory.
-- Construction validates only the platform identity; individual primitives
-- check their own surface at call time so a restricted sandbox still loads the
-- seam and receives typed denials instead of a module-load failure.
local standalone = {}

--- Build one standalone backend.
-- @param opts table? { platform = string?, tmp_root = string? }
-- @return table backend
function standalone.new(opts)
  opts = opts or {}
  local platform = resolve_platform(opts)
  if platform ~= "posix" then
    error(WheelErrors.capability_denied("host.backend.standalone"), 0)
  end

  local backend = {
    name = "standalone",
    platform = platform,
  }

  local tmp_root = opts.tmp_root
  local tmp_sequence = 0
  -- A backend-instance token narrows collisions within this process. It is not
  -- a cross-process uniqueness guarantee; exclusive 0600 creation is CTX-0016.
  local process_token = tostring({}):match("0x(%x+)") or "0"

  --- Create <path> and all missing parents (POSIX `mkdir -p`).
  -- Mirrors the previous per-call-site `os.execute("mkdir -p ...")`; errors
  -- are suppressed on stderr like the trust-store call site did.
  -- @param path string
  -- @return boolean ok, number code
  function backend.mkdir_p(path)
    require_surface(type(os) == "table" and type(os.execute) == "function", "fs.write")
    local ok, _, code = os.execute("mkdir -p -- " .. shell_quote(path) .. " 2>/dev/null")
    if ok == true or ok == 0 then
      return true, 0
    end
    return false, (type(code) == "number" and code or 1)
  end

  --- Create one directory with mode 0700, refusing an existing path.
  -- The exclusive create is the lock/job-directory primitive: `mkdir` fails
  -- atomically when the path exists (including a symlink), so two processes
  -- cannot both acquire the same lock.
  -- @param path string
  -- @return boolean ok, string? err
  function backend.mkdir_exclusive(path)
    require_surface(type(os) == "table" and type(os.execute) == "function", "fs.write")
    if type(path) ~= "string" or path == "" or path:find("[%z\n\r]") then
      return false, "invalid directory path"
    end
    local status = normalized_exit_status(os.execute(
      "umask 077; mkdir -m 700 -- " .. shell_quote(path) .. " 2>/dev/null"))
    if status == 0 then
      return true
    end
    return false, "path already exists or cannot be created"
  end

  --- List a directory as raw `ls -la` lines.
  -- The argv is passed one argument at a time; the standalone primitive is a
  -- POSIX shell, but no call site builds a shell string. stderr is kept
  -- separate, and a nonzero `ls` status or timeout is reported as failure so a
  -- missing/broken `ls` never becomes directory content.
  -- @param path string
  -- @return table { ok, code, stdout, stderr, entries, total, timed_out, truncated, outcome }
  function backend.list_dir(path)
    local res = backend.run_program("ls", { "-la", "--", path })
    local entries = split_lines(res.stdout)
    return {
      ok = res.ok and res.code == 0 and not res.timed_out,
      code = res.code,
      stdout = res.stdout,
      stderr = res.stderr,
      entries = entries,
      total = #entries,
      timed_out = res.timed_out,
      truncated = res.truncated == true,
      outcome = res.outcome,
    }
  end

  --- Read the whole file at <path>.
  -- @param path string
  -- @return string? content, string? err
  function backend.read_file(path)
    require_surface(type(io) == "table" and type(io.open) == "function", "fs.read")
    local f, err = io.open(path, "r")
    if not f then
      return nil, tostring(err)
    end
    local content = f:read("*a")
    f:close()
    return content
  end

  --- Read at most <max_bytes> bytes from <path>.
  -- The file is consumed in fixed-size chunks and stops at the bound, so a
  -- caller-supplied cap is enforced while reading instead of after a whole-file
  -- read. One byte beyond an application cap is how a bounded reader proves the
  -- cap was exceeded.
  -- @param path string
  -- @param max_bytes number
  -- @return string? content, string? err
  function backend.read_file_bounded(path, max_bytes)
    require_surface(type(io) == "table" and type(io.open) == "function", "fs.read")
    if type(max_bytes) ~= "number" or max_bytes < 0 or max_bytes % 1 ~= 0 then
      return nil, "invalid byte bound"
    end
    local f, err = io.open(path, "rb")
    if not f then
      return nil, tostring(err)
    end
    local chunks = {}
    local total = 0
    local read_err = nil
    while total < max_bytes do
      local want = math.min(READ_CHUNK_BYTES, max_bytes - total)
      local chunk, chunk_err = f:read(want)
      if chunk == nil then
        if chunk_err ~= nil then
          read_err = chunk_err
        end
        break
      end
      if chunk == "" then
        break
      end
      chunks[#chunks + 1] = chunk
      total = total + #chunk
    end
    local close_ok, close_err = f:close()
    if read_err ~= nil then
      return nil, tostring(read_err)
    end
    if close_ok == nil then
      return nil, tostring(close_err or "close failed")
    end
    return table.concat(chunks)
  end

  --- Write <content> to the file at <path>, replacing existing content.
  -- @param path string
  -- @param content string
  -- @return boolean ok, string? err
  function backend.write_file(path, content)
    require_surface(type(io) == "table" and type(io.open) == "function", "fs.write")
    local f, err = io.open(path, "w")
    if not f then
      return false, tostring(err)
    end
    local wrote, write_err = f:write(content or "")
    if not wrote then
      f:close()
      return false, tostring(write_err or "write failed")
    end
    local close_ok, close_err = f:close()
    if not close_ok then
      return false, tostring(close_err or "close failed")
    end
    return true
  end

  --- Append <content> to the existing private file at <path>.
  -- The path is verified as an owned, singly linked, mode-0600 regular file
  -- immediately before the append; a symbolic link, foreign owner, weaker
  -- mode, FIFO, device, or missing path is refused. The open uses append mode,
  -- so an existing record is never truncated. The audit sink creates the file
  -- with `create_private_file` before its first append.
  -- @param path string
  -- @param content string
  -- @return boolean ok, string? err
  function backend.append_file(path, content)
    require_surface(type(io) == "table" and type(io.open) == "function", "fs.write")
    if type(path) ~= "string" or path == "" or path:find("[%z\n\r]") then
      return false, "invalid appended file path"
    end
    if type(content) ~= "string" then
      return false, "appended content must be a string"
    end
    local verified, verify_err = verify_private_file(path)
    if not verified then
      return false, verify_err
    end
    local file, open_err = io.open(path, "a")
    if not file then
      return false, tostring(open_err)
    end
    local wrote, write_err = file:write(content)
    if not wrote then
      file:close()
      return false, tostring(write_err or "write failed")
    end
    local close_ok, close_err = file:close()
    if not close_ok then
      return false, tostring(close_err or "close failed")
    end
    return true
  end

  --- Remove the file at <path>.
  -- @param path string
  -- @return boolean ok, string? err
  function backend.remove_file(path)
    require_surface(type(os) == "table" and type(os.remove) == "function", "fs.write")
    local ok, err = os.remove(path)
    if ok then
      return true
    end
    return false, tostring(err)
  end

  --- Test whether a readable file exists at <path>.
  -- @param path string
  -- @return boolean
  function backend.exists(path)
    require_surface(type(io) == "table" and type(io.open) == "function", "fs.read")
    local f = io.open(path, "r")
    if not f then
      return false
    end
    f:close()
    return true
  end

  --- Return lstat-style metadata for <path>.
  -- One bounded shell probe reports link status, existence, and GNU/BSD stat
  -- metadata. This keeps the read-only probe cheap (the process supervisor is
  -- for command execution, not for per-path inspection) while preserving the
  -- existing shape: type probes follow a final symlink, `symlink` reports the
  -- link itself, and a missing path returns exists = false without an error.
  -- A probe that cannot run fails closed with the typed denial, so an
  -- unavailable surface is never read as "not a symlink" or "not a file".
  -- @param path string
  -- @return table { exists, symlink, regular, directory, fifo, uid?, mode?, links? }
  function backend.stat(path)
    require_surface(type(io) == "table" and type(io.popen) == "function", "fs.read")

    local target = path
    if type(target) ~= "string" or target == "" or target:find("[%z\n\r]") then
      error(WheelErrors.capability_denied("fs.read"), 0)
    end
    if target:sub(1, 1) ~= "/" and target:sub(1, 1) ~= "." then
      target = "./" .. target
    end

    local command = "p=$1; "
      .. "if test -L \"$p\"; then printf 'LINK\\n'; fi; "
      .. "if test -e \"$p\"; then printf 'EXISTS\\n'; fi; "
      .. "rc=0; stat -L -c '%u %a %h %s %F' -- \"$p\" 2>/dev/null "
      .. "|| stat -L -f '%u %Lp %l %z %HT' -- \"$p\" 2>/dev/null "
      .. "|| rc=$?; "
      .. "if [ \"$rc\" -ne 0 ] && test -e \"$p\"; then printf 'UNREADABLE\\n'; fi"
    local pipe = io.popen("sh -c " .. shell_quote(command) .. " sh " .. shell_quote(target) .. " 2>/dev/null", "r")
    if not pipe then
      error(WheelErrors.capability_denied("fs.read"), 0)
    end
    local output = pipe:read("*a")
    local closed = pipe:close()
    if closed == nil then
      error(WheelErrors.capability_denied("fs.read"), 0)
    end

    local symlink, exists = false, false
    local uid, mode, links, size
    for line in tostring(output or ""):gmatch("[^\n]+") do
      if line == "LINK" then
        symlink = true
      elseif line == "EXISTS" then
        exists = true
      elseif line == "UNREADABLE" then
        error(WheelErrors.capability_denied("fs.read"), 0)
      else
        local owner, permissions, link_count, byte_size, kind =
          line:match("^(%d+)%s+(%d+)%s+(%d+)%s+(%d+)%s+(.+)$")
        if owner and permissions and link_count and byte_size and kind then
          uid = tonumber(owner)
          mode = tonumber(permissions, 8)
          links = tonumber(link_count)
          size = tonumber(byte_size)
          exists = true
          local normalized = kind:lower()
          if normalized:find("regular", 1, true) then
            return {
              exists = true,
              symlink = symlink,
              regular = true,
              directory = false,
              fifo = false,
              uid = uid,
              mode = mode,
              links = links,
              size = size,
            }
          elseif normalized:find("directory", 1, true) then
            return {
              exists = true,
              symlink = symlink,
              regular = false,
              directory = true,
              fifo = false,
              uid = uid,
              mode = mode,
              links = links,
              size = size,
            }
          elseif normalized:find("fifo", 1, true) then
            return {
              exists = true,
              symlink = symlink,
              regular = false,
              directory = false,
              fifo = true,
              uid = uid,
              mode = mode,
              links = links,
              size = size,
            }
          end
        end
      end
    end

    return {
      exists = exists or symlink,
      symlink = symlink,
      regular = false,
      directory = false,
      fifo = false,
      uid = uid,
      mode = mode,
      links = links,
      size = size,
    }
  end

  --- Set the mode of <path> (octal string or number, for example "600").
  -- @param path string
  -- @param mode string|number
  -- @return boolean ok, string? err
  function backend.chmod(path, mode)
    require_surface(type(os) == "table" and type(os.execute) == "function", "fs.write")
    local text = tostring(mode)
    if not text:match("^[0-7]+$") then
      return false, "invalid mode"
    end
    local ok, _, code = os.execute("chmod " .. text .. " -- " .. shell_quote(path))
    if ok == true or ok == 0 or code == 0 then
      return true
    end
    return false, "chmod failed"
  end

  --- Return the current effective uid, or nil when it cannot be read.
  -- @return number? uid
  function backend.euid()
    return current_euid()
  end

  --- Read `count` bytes from the host random source (`/dev/urandom`).
  -- Job identifiers and cancellation generation tokens are capability material,
  -- so they must not be derived from a predictable clock or table address. A
  -- missing or short source fails closed instead of returning a weak token.
  -- @param count number
  -- @return string? bytes, string? err
  function backend.random_bytes(count)
    require_surface(type(io) == "table" and type(io.open) == "function", "fs.read")
    if type(count) ~= "number" or count ~= count or count % 1 ~= 0
      or count < 1 or count > MAX_RANDOM_BYTES then
      return nil, "invalid random byte count"
    end
    local file = io.open("/dev/urandom", "rb")
    if not file then
      return nil, "the host random source is unavailable"
    end
    local bytes = file:read(count)
    file:close()
    if type(bytes) ~= "string" or #bytes ~= count then
      return nil, "the host random source returned insufficient bytes"
    end
    return bytes
  end

  --- Create a new regular file with mode 0600 at <path> and write <content>.
  -- The content is written to a verified private temporary file in the same
  -- directory and published with an atomic hard link, so a crash cannot leave
  -- an empty half-created lock or metadata path. A pre-existing file, FIFO,
  -- device, or symbolic link is refused rather than followed or truncated. The
  -- caller owns removal.
  -- @param path string
  -- @param content string?
  -- @return boolean ok, string? err
  function backend.create_private_file(path, content)
    require_surface(type(os) == "table" and type(os.execute) == "function", "fs.write")
    require_surface(type(io) == "table" and type(io.open) == "function", "fs.write")
    if type(path) ~= "string" or path == "" or path:find("[%z\n\r]") then
      return false, "invalid private file path"
    end
    if content ~= nil and type(content) ~= "string" then
      return false, "private file content must be a string"
    end
    local parent = path:match("^(.*)/[^/]+$")
    if parent == nil then
      return false, "private file path must be absolute or contain a directory"
    end
    if parent == "" then
      parent = "/"
    end
    local temp, temp_err = create_private_temp(parent)
    if not temp then
      return false, temp_err or "cannot create a private temporary file"
    end
    local wrote, write_err = write_private_file(temp, content or "")
    if not wrote then
      os.remove(temp)
      return false, write_err or "cannot write the private temporary file"
    end
    local linked = normalized_exit_status(os.execute(
      "ln -- " .. shell_quote(temp) .. " " .. shell_quote(path) .. " 2>/dev/null"))
    if linked ~= 0 then
      os.remove(temp)
      return false, "private file path already exists or cannot be linked"
    end
    local removed, remove_err = os.remove(temp)
    if not removed then
      os.remove(path)
      return false, "temporary-link cleanup failed: " .. tostring(remove_err or temp)
    end
    local verified, verify_err = verify_private_file(path)
    if not verified then
      os.remove(path)
      return false, verify_err
    end
    return true
  end

  --- Create a hard link at <to> pointing at <from>; never replace <to>.
  -- POSIX `ln` fails atomically when the target exists, so this is the
  -- non-replacing restore primitive for a claimed lock. Both paths must be
  -- caller-controlled and already validated.
  -- @param from string
  -- @param to string
  -- @return boolean ok, string? err
  function backend.link_exclusive(from, to)
    require_surface(type(os) == "table" and type(os.execute) == "function", "fs.write")
    if type(from) ~= "string" or from == "" or from:find("[%z\n\r]")
      or type(to) ~= "string" or to == "" or to:find("[%z\n\r]") then
      return false, "invalid link path"
    end
    local status = normalized_exit_status(os.execute(
      "ln -- " .. shell_quote(from) .. " " .. shell_quote(to) .. " 2>/dev/null"))
    if status == 0 then
      return true
    end
    return false, "link target exists or cannot be linked"
  end

  --- Create a new FIFO with mode 0600 at <path>.
  -- The path must not exist; `mkfifo` fails on an existing path (including a
  -- symbolic link), and the result is verified as an owned, singly linked,
  -- mode-0600 FIFO before it is returned.
  -- @param path string
  -- @return boolean ok, string? err
  function backend.mkfifo(path)
    require_surface(type(os) == "table" and type(os.execute) == "function", "fs.write")
    if type(path) ~= "string" or path == "" or path:find("[%z\n\r]") then
      return false, "invalid FIFO path"
    end
    local exists = normalized_exit_status(os.execute(
      "test -e " .. shell_quote(path) .. " || test -L " .. shell_quote(path))) == 0
    if exists then
      return false, "FIFO path already exists"
    end
    local created = normalized_exit_status(os.execute(
      "umask 077; mkfifo -m 600 -- " .. shell_quote(path) .. " 2>/dev/null"))
    if created ~= 0 then
      return false, "FIFO creation failed"
    end
    return verify_private_fifo(path)
  end

  --- Open a verified private FIFO read/write.
  -- `r+` maps to POSIX O_RDWR, which neither blocks waiting for a peer nor
  -- reports a spurious end-of-file while the caller holds the handle. The
  -- path is verified as an owned mode-0600 FIFO immediately before the open;
  -- a symbolic link, foreign owner, or weaker mode is refused.
  -- @param path string
  -- @return file? handle, string? err
  function backend.open_fifo(path)
    require_surface(type(io) == "table" and type(io.open) == "function", "fs.read")
    local verified, verify_err = verify_private_fifo(path)
    if not verified then
      return nil, verify_err
    end
    local handle, open_err = io.open(path, "r+")
    if not handle then
      return nil, tostring(open_err or "cannot open FIFO")
    end
    return handle
  end

  --- Remove one empty directory (POSIX `rmdir`). Never recursive.
  -- @param path string
  -- @return boolean ok, string? err
  function backend.remove_dir(path)
    require_surface(type(os) == "table" and type(os.execute) == "function", "fs.write")
    local status = normalized_exit_status(os.execute("rmdir -- " .. shell_quote(path) .. " 2>/dev/null"))
    if status == 0 then
      return true
    end
    return false, "directory is not empty or cannot be removed"
  end

  --- Atomically rename <from> to <to> on the same filesystem.
  -- @param from string
  -- @param to string
  -- @return boolean ok, string? err
  function backend.rename(from, to)
    require_surface(type(os) == "table" and type(os.rename) == "function", "fs.write")
    local ok, err = os.rename(from, to)
    if ok then
      return true
    end
    return false, tostring(err)
  end

  --- Resolve a wrapper binary through the caller's PATH, once per backend.
  -- Only fixed wrapper names (`env`, `timeout`/`gtimeout`, `sh`) are resolved
  -- this way; the resolved absolute path is used for the launch so the
  -- scrubbed child PATH cannot change which wrapper runs. The child's own
  -- program lookup still uses the sanitized PATH passed in its environment.
  -- @param name string
  -- @return string? absolute_path
  local tool_cache = {}
  local function resolve_tool(name)
    local cached = tool_cache[name]
    if cached ~= nil then
      return cached or nil
    end
    require_surface(type(io) == "table" and type(io.popen) == "function", "process.spawn")
    local pipe = io.popen("command -v " .. shell_quote(name) .. " 2>/dev/null", "r")
    if not pipe then
      tool_cache[name] = false
      return nil
    end
    local path = pipe:read("*l")
    pipe:close()
    path = path and path:match("^%s*(.-)%s*$") or ""
    if path == "" or path:sub(1, 1) ~= "/" then
      tool_cache[name] = false
      return nil
    end
    tool_cache[name] = path
    return path
  end

  --- Resolve GNU timeout (coreutils `timeout`, or `gtimeout` from Homebrew).
  -- @return string? absolute_path
  local function resolve_timeout_tool()
    return resolve_tool("timeout") or resolve_tool("gtimeout")
  end

  --- Format a millisecond duration as a GNU timeout argument.
  -- @param ms number
  -- @return string
  local function format_seconds(ms)
    return string.format("%.3fs", ms / 1000)
  end

  --- Format a millisecond grace as a sleep argument (no unit suffix).
  -- @param ms number
  -- @return string
  local function format_sleep(ms)
    return string.format("%.3f", ms / 1000)
  end

  --- Validate and normalize the shared process options.
  -- This is the single validation path for the synchronous primitive and the
  -- asynchronous start handle; both must reject the same shapes before any
  -- file or process is created.
  -- @param opts table?
  -- @return table? normalized, table? failure
  local function normalize_process_options(opts)
    opts = type(opts) == "table" and opts or {}

    local timeout_ms = opts.timeout_ms
    if timeout_ms == nil then
      timeout_ms = DEFAULT_TIMEOUT_MS
    end
    if type(timeout_ms) ~= "number"
      or timeout_ms ~= timeout_ms
      or timeout_ms % 1 ~= 0
      or timeout_ms < MIN_TIMEOUT_MS
      or timeout_ms > MAX_TIMEOUT_MS then
      return nil, process_failure(string.format(
        "timeout_ms must be an integer between %d and %d", MIN_TIMEOUT_MS, MAX_TIMEOUT_MS))
    end

    local capture_cap = opts.max_output_bytes
    if capture_cap == nil then
      capture_cap = MAX_CAPTURE_BYTES
    end
    if type(capture_cap) ~= "number"
      or capture_cap ~= capture_cap
      or capture_cap % 1 ~= 0
      or capture_cap < 1
      or capture_cap > MAX_CAPTURE_BYTES then
      return nil, process_failure("max_output_bytes must be an integer between 1 and "
        .. MAX_CAPTURE_BYTES)
    end

    local stdin_data = opts.stdin
    if stdin_data ~= nil then
      if type(stdin_data) ~= "string" then
        return nil, process_failure("stdin must be a string")
      end
      if #stdin_data > MAX_STDIN_BYTES then
        return nil, process_failure("stdin exceeds the " .. MAX_STDIN_BYTES .. " byte bound")
      end
    end

    -- cwd is caller-resolved and caller-contained: this seam validates only
    -- shape, not workspace membership. Tool call sites must pass a path that
    -- already passed the workspace resolver.
    local cwd = opts.cwd
    if cwd ~= nil then
      if type(cwd) ~= "string"
        or cwd == ""
        or #cwd > MAX_ENV_VALUE_BYTES
        or cwd:find("[%z\n\r]") then
        return nil, process_failure("cwd must be a control-free absolute or relative path")
      end
    end

    -- Optional execution audit (CTX-0030). The sink is opt-in: a call without
    -- opts.audit never resolves or creates an audit directory, so existing
    -- tests and embedders keep their behavior. When supplied, the metadata is
    -- an allowlisted identity/decision table; command values and metadata are
    -- redacted by the sink, and no output, environment value, prompt, or file
    -- content is passed to it.
    local audit_meta = opts.audit
    if audit_meta ~= nil and type(audit_meta) ~= "table" then
      return nil, process_failure("audit metadata must be a table")
    end
    local audit_decision = "allow"
    if audit_meta ~= nil then
      audit_decision = audit_meta.decision
      if audit_decision == nil then
        audit_decision = "allow"
      end
      if audit_decision ~= "allow" and audit_decision ~= "deny" then
        return nil, process_failure("audit decision must be 'allow' or 'deny'")
      end
      if audit_meta.high_risk ~= nil and type(audit_meta.high_risk) ~= "boolean" then
        local failure = process_failure("audit high_risk must be a boolean")
        failure.audit_error = WheelErrors.args_invalid(
          "host.proc", "audit high_risk must be a boolean")
        return nil, failure
      end
    end

    return {
      opts = opts,
      timeout_ms = timeout_ms,
      capture_cap = capture_cap,
      stdin_data = stdin_data,
      cwd = cwd,
      audit_meta = audit_meta,
      audit_decision = audit_decision,
    }
  end

  --- Resolve every fixed wrapper tool required by the process seam.
  -- A missing tool is a typed `unavailable` failure, never an implicit weaker
  -- execution surface.
  -- @return table? tools, table? failure
  local function resolve_process_tools()
    local env_bin = resolve_tool("env")
    if not env_bin then
      return nil, process_failure(
        "the 'env' utility is unavailable; refusing to inherit the parent environment",
        WheelHost.PROCESS_OUTCOME.UNAVAILABLE)
    end
    local timeout_bin = resolve_timeout_tool()
    if not timeout_bin then
      return nil, process_failure(
        "GNU 'timeout' is unavailable; refusing to run an unbounded process",
        WheelHost.PROCESS_OUTCOME.UNAVAILABLE)
    end
    local sh_bin = resolve_tool("sh")
    if not sh_bin then
      return nil, process_failure("the POSIX 'sh' is unavailable",
        WheelHost.PROCESS_OUTCOME.UNAVAILABLE)
    end
    local setsid_bin = resolve_tool("setsid")
    if not setsid_bin then
      return nil, process_failure(
        "the 'setsid' utility is unavailable; refusing to run without a recorded process group",
        WheelHost.PROCESS_OUTCOME.UNAVAILABLE)
    end
    local sleep_bin = resolve_tool("sleep")
    if not sleep_bin then
      return nil, process_failure(
        "the 'sleep' utility is unavailable; cannot bound the process-group sweep",
        WheelHost.PROCESS_OUTCOME.UNAVAILABLE)
    end
    for _, required in ipairs({ "mktemp", "stat", "id" }) do
      if not resolve_tool(required) then
        return nil, process_failure(
          "the '" .. required .. "' utility is unavailable; cannot validate private files",
          WheelHost.PROCESS_OUTCOME.UNAVAILABLE)
      end
    end
    return {
      env_bin = env_bin,
      timeout_bin = timeout_bin,
      sh_bin = sh_bin,
      setsid_bin = setsid_bin,
      sleep_bin = sleep_bin,
    }
  end

  --- Allocate the private capture files for one launch.
  -- The caller owns cleanup; a partial allocation is removed before returning.
  -- @param dir string
  -- @param need_stdin boolean
  -- @return table? paths, function? cleanup, table? failure
  local function allocate_capture_paths(dir, need_stdin)
    local created = {}
    local function fresh_temp()
      for _ = 1, MAX_TMP_CREATE_ATTEMPTS do
        local path = create_private_temp(dir)
        if path then
          created[#created + 1] = path
          return path
        end
      end
      return nil
    end
    local function cleanup()
      local errors = {}
      for index = #created, 1, -1 do
        local ok, err = os.remove(created[index])
        if not ok then
          errors[#errors + 1] = tostring(err or created[index])
        end
      end
      return errors
    end

    local paths = {
      out = fresh_temp(),
      err = fresh_temp(),
      diag = fresh_temp(),
      status = fresh_temp(),
      sweep = fresh_temp(),
      pgid = fresh_temp(),
    }
    if need_stdin then
      paths.stdin = fresh_temp()
    end
    if not paths.out or not paths.err or not paths.diag or not paths.status
      or not paths.sweep or not paths.pgid
      or (need_stdin and not paths.stdin) then
      local errors = cleanup()
      local message = "cannot create private process-capture files"
      if #errors > 0 then
        message = message .. "; cleanup failed: " .. table.concat(errors, "; ")
      end
      return nil, nil, process_failure(message)
    end
    return paths, cleanup
  end

  --- Build the constant launch wrapper command.
  -- Every caller value crosses as a quoted positional argument; no caller value
  -- is interpolated into the script text.
  -- @param mode string
  -- @param payload string
  -- @param payload_args table?
  -- @param cwd string?
  -- @param stdin_path string
  -- @param tools table
  -- @param env_parts table
  -- @param paths table
  -- @param timeout_ms number
  -- @return string command
  local function build_launch_command(mode, payload, payload_args, cwd, stdin_path,
    tools, env_parts, paths, timeout_ms)
    local script
    local launch_args
    if mode == "argv" then
      if cwd then
        script = 'stdin="$1"; envbin="$2"; cwd="$3"; shift 3; case "$cwd" in -*) exit 126;; esac; case "$1" in ""|-*|*=*) exit 126;; esac; cd "$cwd" || exit 126; exec "$envbin" -u SHLVL -u PWD -u _ -- "$@" < "$stdin"'
        launch_args = { stdin_path, tools.env_bin, cwd, payload }
      else
        script = 'stdin="$1"; envbin="$2"; shift 2; case "$1" in ""|-*|*=*) exit 126;; esac; exec "$envbin" -u SHLVL -u PWD -u _ -- "$@" < "$stdin"'
        launch_args = { stdin_path, tools.env_bin, payload }
      end
      for _, arg in ipairs(payload_args or {}) do
        launch_args[#launch_args + 1] = arg
      end
    else
      if cwd then
        script = 'stdin="$1"; envbin="$2"; cwd="$3"; shift 3; case "$cwd" in -*) exit 126;; esac; case "$1" in ""|-*|*=*) exit 126;; esac; cd "$cwd" || exit 126; exec "$envbin" -u SHLVL -u PWD -u _ -- "$@" < "$stdin"'
        launch_args = { stdin_path, tools.env_bin, cwd, tools.sh_bin, "-c", payload }
      else
        script = 'stdin="$1"; envbin="$2"; shift 2; case "$1" in ""|-*|*=*) exit 126;; esac; exec "$envbin" -u SHLVL -u PWD -u _ -- "$@" < "$stdin"'
        launch_args = { stdin_path, tools.env_bin, tools.sh_bin, "-c", payload }
      end
    end

    local kill_after_ms = math.min(KILL_AFTER_MS, timeout_ms)
    local pieces = {
      shell_quote(tools.sh_bin), "-c", shell_quote(SUPERVISOR_SCRIPT),
      shell_quote("wheel-supervisor"),
      shell_quote(paths.out), shell_quote(paths.err),
      shell_quote(tools.setsid_bin), "-w",
      shell_quote(tools.sh_bin), "-c", shell_quote(LEADER_SCRIPT),
      shell_quote("wheel-leader"),
      shell_quote(paths.pgid), shell_quote(paths.status), shell_quote(paths.sweep),
      shell_quote(paths.out), shell_quote(paths.err),
      shell_quote(format_sleep(SWEEP_GRACE_MS)),
      shell_quote(tools.sleep_bin),
      shell_quote(paths.cancel or ""), shell_quote(paths.terminal or ""),
      shell_quote(paths.lock or ""), shell_quote(paths.generation or "-"),
      shell_quote(tostring(LEADER_LOCK_ATTEMPTS)),
      shell_quote(format_sleep(LEADER_LOCK_INTERVAL_MS)),
      shell_quote(tools.env_bin), "-i",
    }
    for _, assignment in ipairs(env_parts) do
      pieces[#pieces + 1] = shell_quote(assignment)
    end
    pieces[#pieces + 1] = shell_quote(tools.timeout_bin)
    pieces[#pieces + 1] = "--foreground"
    pieces[#pieces + 1] = "-k"
    pieces[#pieces + 1] = format_seconds(kill_after_ms)
    pieces[#pieces + 1] = format_seconds(timeout_ms)
    pieces[#pieces + 1] = shell_quote(tools.sh_bin)
    pieces[#pieces + 1] = "-c"
    pieces[#pieces + 1] = shell_quote(script)
    pieces[#pieces + 1] = shell_quote("wheel-exec")
    for _, arg in ipairs(launch_args) do
      pieces[#pieces + 1] = shell_quote(arg)
    end
    return table.concat(pieces, " ")
  end

  --- Execute one bounded child process and normalize its result.
  -- @param mode string "argv" or "shell"
  -- @param payload string program name or shell string
  -- @param payload_args string[]? argv elements for mode "argv"
  -- @param opts table?
  -- @return table process result
  local function execute_process(mode, payload, payload_args, opts)
    require_surface(type(io) == "table" and type(io.popen) == "function", "process.spawn")
    local normalized, option_failure = normalize_process_options(opts)
    if not normalized then
      return option_failure
    end
    opts = normalized.opts
    local timeout_ms = normalized.timeout_ms
    local capture_cap = normalized.capture_cap
    local stdin_data = normalized.stdin_data
    local cwd = normalized.cwd
    local audit_meta = normalized.audit_meta
    local audit_decision = normalized.audit_decision

    local function audit_clock_ms()
      local ok, now = pcall(WheelHost.time.now)
      if ok and type(now) == "number" and now >= 0 then
        return math.floor(now * 1000)
      end
      return nil
    end

    local function audit_event(name, extra)
      if audit_meta == nil then
        return nil
      end
      local event = {
        event = name,
        kind = mode,
        cwd = cwd,
        role = audit_meta.role,
        agent = audit_meta.agent,
        task = audit_meta.task,
        tool = audit_meta.tool,
        intent = audit_meta.intent,
        decision = audit_decision,
        reason = audit_meta.reason,
        high_risk = audit_meta.high_risk == true,
      }
      if mode == "argv" then
        event.program = payload
        event.args = payload_args
      else
        event.shell = payload
      end
      for key, value in pairs(extra or {}) do
        event[key] = value
      end
      return event
    end

    local audit_started = nil
    local audit_recorded = false
    local audit_warning = nil

    local function write_audit(event)
      local ok, recorded, audit_err =
        pcall(WheelAudit.record, event, { dir = audit_meta.dir })
      if not ok then
        return nil, WheelErrors.audit_unavailable()
      end
      return recorded, audit_err
    end

    local function finish_audit(result, spawned)
      if audit_meta == nil then
        return result
      end
      result.spawned = spawned
      if audit_warning then
        result.audit_warning = audit_warning
      end
      if not audit_recorded then
        return result
      end
      local finished = audit_clock_ms()
      local extra = {
        spawned = spawned,
        exit_code = result.exit_code,
        truncated = result.truncated == true,
        timed_out = result.timed_out == true,
        cleanup = result.cleanup,
        outcome = result.outcome,
      }
      if audit_started ~= nil and finished ~= nil then
        extra.duration_ms = math.max(0, finished - audit_started)
      end
      local recorded, audit_err = write_audit(
        audit_event(spawned and "process.completed" or "process.aborted", extra))
      if not recorded then
        result.audit_warning = result.audit_warning
          or "audit completion record could not be written"
        result.audit_error = result.audit_error or audit_err
      end
      return result
    end

    -- A caller-supplied deny decision is a recorded refusal, not a launch. The
    -- pre-spawn record is attempted first so a denial is auditable; either way
    -- the command never reaches the wrapper. A high-risk denial is still a
    -- denial even when the audit write fails.
    if audit_meta ~= nil and audit_decision == "deny" then
      local recorded, audit_err = write_audit(
        audit_event("process.pre_spawn", { spawned = false }))
      local denied = process_failure("process denied by policy")
      denied.denied = true
      denied.spawned = false
      if not recorded then
        denied.audit_error = audit_err
        denied.audit_warning = "audit record could not be written for a denied command"
      end
      return denied
    end

    local env_parts, env_err, env_outcome =
      build_child_environment(os.getenv, opts.env)
    if not env_parts then
      return process_failure(env_err, env_outcome)
    end

    local tools, tools_failure = resolve_process_tools()
    if not tools then
      return tools_failure
    end

    local tmp_ok, tmp_dir = pcall(backend.tmp_dir)
    local paths, cleanup
    if tmp_ok then
      paths, cleanup = allocate_capture_paths(tmp_dir, stdin_data ~= nil)
    end
    if not paths then
      if not tmp_ok then
        return process_failure("the private temporary directory is unavailable")
      end
      return process_failure("cannot create private process-capture files")
    end

    local stdin_path = paths.stdin
    local out_path = paths.out
    local err_path = paths.err
    local diag_path = paths.diag
    local status_path = paths.status
    local sweep_path = paths.sweep
    local pgid_path = paths.pgid
    if stdin_path then
      local wrote, write_err = write_private_file(stdin_path, stdin_data)
      if not wrote then
        local errors = cleanup()
        local message = "cannot stage process stdin: " .. tostring(write_err)
        if #errors > 0 then
          message = message .. "; cleanup failed: " .. table.concat(errors, "; ")
        end
        return process_failure(message)
      end
    else
      stdin_path = "/dev/null"
    end

    -- The supervisor always exits 0 and leaves its stderr to the outer diag
    -- file; the retained leader redirects the command into the private capture
    -- files itself. The expected SIGKILL of the leader therefore stays in the
    -- wrapper diagnostics, never in the command's captured stderr. The leader is
    -- the only process that signals the group and the only authority for the
    -- command status; the status, sweep marker, and recorded PGID are read back
    -- below.
    local command = build_launch_command(mode, payload, payload_args, cwd, stdin_path,
      tools, env_parts, {
        out = out_path,
        err = err_path,
        diag = diag_path,
        status = status_path,
        sweep = sweep_path,
        pgid = pgid_path,
        cancel = "",
        terminal = "",
        lock = "",
        generation = "-",
      }, timeout_ms) .. " 2> " .. shell_quote(diag_path)

    -- The pre-spawn record is written after every argument, environment, and
    -- temporary-file check but immediately before the launch. A high-risk
    -- operation fails closed when that write cannot complete; a lower-risk one
    -- continues with a visible result warning. Existing capture files are
    -- removed on the refusal path.
    if audit_meta ~= nil then
      audit_started = audit_clock_ms()
      local recorded, audit_err = write_audit(
        audit_event("process.pre_spawn", { spawned = false }))
      if recorded then
        audit_recorded = true
      elseif audit_meta.high_risk == true then
        cleanup()
        local refused = process_failure(
          "audit record could not be written; refusing a high-risk spawn")
        refused.spawned = false
        refused.audit_error = audit_err
        return refused
      else
        audit_warning =
          "audit record could not be written; continuing because the command is not marked high risk"
      end
    end

    local pipe = io.popen(command, "r")
    if not pipe then
      local errors = cleanup()
      local message = "Failed to spawn the bounded process wrapper"
      if #errors > 0 then
        message = message .. "; cleanup failed: " .. table.concat(errors, "; ")
      end
      return finish_audit(process_failure(message), false)
    end
    pipe:read("*a")
    pipe:close()

    local status_raw = backend.read_file_bounded(status_path, 32) or ""
    local sweep_raw = backend.read_file_bounded(sweep_path, 32) or ""
    local pgid_raw = backend.read_file_bounded(pgid_path, 32) or ""
    local code = tonumber(status_raw:match("^%s*(%d+)%s*$"))
    local pgid = tonumber(pgid_raw:match("^%s*(%d+)%s*$"))
    if pgid ~= nil and pgid <= 1 then
      pgid = nil
    end
    local swept = sweep_raw:match("^%s*swept%s*$") ~= nil
    local out_raw = backend.read_file_bounded(out_path, capture_cap + 1) or ""
    local err_raw = backend.read_file_bounded(err_path, capture_cap + 1) or ""
    local cleanup_errors = cleanup()

    if code == nil then
      local diag_raw = backend.read_file_bounded(diag_path, 512) or ""
      local message = "the process supervisor did not report the direct command's exit status; "
        .. (swept
          and "the recorded process group was swept without a confirmed status"
          or "the recorded process group was not swept because the retained leader did not complete the identity-held sweep")
      if err_raw ~= "" then
        message = message .. ": " .. err_raw:sub(1, 512)
      end
      if diag_raw ~= "" then
        message = message .. "; wrapper diagnostics: " .. diag_raw:sub(1, 512)
      end
      if #cleanup_errors > 0 then
        message = message .. "; cleanup failed: " .. table.concat(cleanup_errors, "; ")
      end
      local failure = process_failure(message)
      failure.cleanup = swept
        and WheelHost.GROUP_CLEANUP.SWEPT
        or WheelHost.GROUP_CLEANUP.UNVERIFIED
      failure.pgid = pgid
      return finish_audit(failure, true)
    end

    local timed_out = code == 124 or code == 137
    local outcome = timed_out
      and WheelHost.PROCESS_OUTCOME.TIMEOUT
      or WheelHost.PROCESS_OUTCOME.EXITED
    local ok = true
    local group_cleanup = swept
      and WheelHost.GROUP_CLEANUP.SWEPT
      or WheelHost.GROUP_CLEANUP.UNVERIFIED
    if group_cleanup == WheelHost.GROUP_CLEANUP.UNVERIFIED then
      err_raw = err_raw
        .. (#err_raw > 0 and "\n" or "")
        .. "process-group cleanup unverified: the retained session leader exited before the sweep completed; "
        .. "no signal was sent after the group identity was lost"
    end
    if #cleanup_errors > 0 then
      outcome = WheelHost.PROCESS_OUTCOME.FAILURE
      ok = false
      err_raw = err_raw
        .. (#err_raw > 0 and "\n" or "")
        .. "temporary-file cleanup failed: " .. table.concat(cleanup_errors, "; ")
    end

    local stdout_truncated = #out_raw > capture_cap
    local stderr_truncated = #err_raw > capture_cap
    local stdout = stdout_truncated and out_raw:sub(1, capture_cap) or out_raw
    local stderr = stderr_truncated and err_raw:sub(1, capture_cap) or err_raw
    if opts.merge_stderr then
      stdout = stdout .. stderr
      stderr = ""
    elseif opts.discard_stderr then
      stderr = ""
    end

    return finish_audit({
      ok = ok,
      code = code,
      exit_code = code,
      stdout = stdout,
      stderr = stderr,
      timed_out = timed_out,
      truncated = stdout_truncated or stderr_truncated,
      stdout_truncated = stdout_truncated,
      stderr_truncated = stderr_truncated,
      outcome = outcome,
      cleanup = group_cleanup,
      pgid = pgid,
      cancel_requested = false,
      terminal_reason = timed_out and "timeout" or "exited",
    }, true)
  end

  --- Read one bounded decimal file from a job record.
  -- @param path string
  -- @return number? value
  local function read_private_number(path)
    local raw = backend.read_file_bounded(path, 32)
    if type(raw) ~= "string" then
      return nil
    end
    return tonumber(raw:match("^%s*(%d+)%s*$"))
  end

  local function start_clock_ms()
    local ok, now = pcall(WheelHost.time.now)
    if ok and type(now) == "number" and now >= 0 then
      return math.floor(now * 1000)
    end
    return 0
  end

  local Handle = {}
  Handle.__index = Handle

  --- Return the recorded job id for this handle.
  -- @return string
  function Handle:job_id()
    return self.job.job_id
  end

  --- Return the job root (the directory holding this job's private record).
  -- @return string
  function Handle:job_root()
    return self.job.root
  end

  --- Return the recorded process-group id, when available.
  -- @return number? pgid
  function Handle:pgid()
    return self.job.recorded_pgid
  end

  --- Return true after `close` removed the private record.
  -- @return boolean
  function Handle:is_closed()
    return self.closed == true
  end

  local function handle_audit_identity(self, name, extra)
    if self.audit_meta == nil then
      return nil
    end
    local event = {
      event = name,
      kind = self.mode,
      cwd = self.cwd,
      role = self.audit_meta.role,
      agent = self.audit_meta.agent,
      task = self.audit_meta.task,
      tool = self.audit_meta.tool,
      intent = self.audit_meta.intent,
      decision = self.audit_decision,
      high_risk = self.audit_meta.high_risk == true,
      job_id = self.job.job_id,
    }
    if self.mode == "argv" then
      event.program = self.payload
      event.args = self.payload_args
    else
      event.shell = self.payload
    end
    for key, value in pairs(extra or {}) do
      event[key] = value
    end
    return event
  end

  local function handle_audit_finish(self, result, spawned)
    if self.audit_meta == nil or self.audit_dir == nil then
      return result
    end
    result.spawned = spawned
    if self.audit_warning then
      result.audit_warning = result.audit_warning or self.audit_warning
    end
    if not self.audit_recorded then
      return result
    end
    local extra = {
      spawned = spawned,
      exit_code = result.exit_code,
      truncated = result.truncated == true,
      timed_out = result.timed_out == true,
      cleanup = result.cleanup,
      outcome = result.outcome,
      cancel_requested = result.cancel_requested == true,
      terminal_reason = result.terminal_reason,
    }
    if self.audit_started ~= nil then
      extra.duration_ms = math.max(0, start_clock_ms() - self.audit_started)
    end
    local event = handle_audit_identity(self,
      spawned and "process.completed" or "process.aborted", extra)
    local ok, recorded = pcall(WheelAudit.record, event, { dir = self.audit_dir })
    if not ok or not recorded then
      result.audit_warning = result.audit_warning
        or "audit completion record could not be written"
    end
    return result
  end

  local function build_handle_result(self, terminal)
    local cap = self.capture_cap
    local out_raw = backend.read_file_bounded(self.job.paths.out, cap + 1) or ""
    local err_raw = backend.read_file_bounded(self.job.paths.err, cap + 1) or ""
    local status = self.job:exit_status()
    local swept = self.job:swept()
    local cancel = self.job:cancel_outcome()
    local pgid = self.job.recorded_pgid

    local result
    if terminal == "cancelled" then
      -- GNU timeout can leave its 124 sentinel in the leader's status when a
      -- cancellation wins the terminal race (CI observed this even though the
      -- local host usually reported 143/137). Cancellation evidence takes
      -- precedence over that sentinel: TERM maps to 143 and KILL to 137, while
      -- genuine 137/143 and a raw status without cancellation evidence are
      -- preserved.
      local code = status
      local cancel_evidence = cancel ~= nil
        and (cancel.term_sent == true or cancel.kill_sent == true)
      local signal_code = (cancel and cancel.kill_sent) and 137 or 143
      if code == nil then
        code = signal_code
      elseif cancel_evidence and (code == 0 or code == 124) then
        code = signal_code
      end
      local cleanup = WheelHost.GROUP_CLEANUP.UNVERIFIED
      if swept then
        cleanup = WheelHost.GROUP_CLEANUP.SWEPT
      elseif cancel and cancel.group_alive_after == false
        and (cancel.term_sent or cancel.kill_sent) then
        cleanup = WheelHost.GROUP_CLEANUP.SWEPT
      end
      result = {
        ok = true,
        code = code,
        exit_code = code,
        stdout = "",
        stderr = "",
        timed_out = false,
        truncated = false,
        stdout_truncated = false,
        stderr_truncated = false,
        outcome = WheelHost.PROCESS_OUTCOME.CANCELLED,
        cleanup = cleanup,
        pgid = pgid,
        cancel_requested = true,
        terminal_reason = "cancelled",
        job_id = self.job.job_id,
        spawned = true,
      }
    elseif terminal == "timeout" then
      local code = status or 124
      result = {
        ok = true,
        code = code,
        exit_code = code,
        stdout = "",
        stderr = "",
        timed_out = true,
        truncated = false,
        stdout_truncated = false,
        stderr_truncated = false,
        outcome = WheelHost.PROCESS_OUTCOME.TIMEOUT,
        cleanup = swept and WheelHost.GROUP_CLEANUP.SWEPT
          or WheelHost.GROUP_CLEANUP.UNVERIFIED,
        pgid = pgid,
        cancel_requested = false,
        terminal_reason = "timeout",
        job_id = self.job.job_id,
        spawned = true,
      }
    elseif terminal == "exited" and status ~= nil then
      result = {
        ok = true,
        code = status,
        exit_code = status,
        stdout = "",
        stderr = "",
        timed_out = false,
        truncated = false,
        stdout_truncated = false,
        stderr_truncated = false,
        outcome = WheelHost.PROCESS_OUTCOME.EXITED,
        cleanup = swept and WheelHost.GROUP_CLEANUP.SWEPT
          or WheelHost.GROUP_CLEANUP.UNVERIFIED,
        pgid = pgid,
        cancel_requested = false,
        terminal_reason = "exited",
        job_id = self.job.job_id,
        spawned = true,
      }
    else
      local message = terminal == "unverified"
        and "the recorded job terminal reason is unverified"
        or "the retained leader did not report the command's exit status"
      result = process_failure(message)
      result.cleanup = swept and WheelHost.GROUP_CLEANUP.SWEPT
        or WheelHost.GROUP_CLEANUP.UNVERIFIED
      result.pgid = pgid
      result.job_id = self.job.job_id
      result.cancel_requested = terminal == "cancelled"
      result.terminal_reason = terminal or "unverified"
      result.spawned = true
    end

    if result.cleanup == WheelHost.GROUP_CLEANUP.UNVERIFIED then
      err_raw = err_raw
        .. (#err_raw > 0 and "\n" or "")
        .. "process-group cleanup unverified: the retained session leader did not complete the recorded-group sweep"
    end

    local stdout_truncated = #out_raw > cap
    local stderr_truncated = #err_raw > cap
    result.stdout = stdout_truncated and out_raw:sub(1, cap) or out_raw
    result.stderr = stderr_truncated and err_raw:sub(1, cap) or err_raw
    result.stdout_truncated = stdout_truncated
    result.stderr_truncated = stderr_truncated
    result.truncated = stdout_truncated or stderr_truncated
    if self.merge_stderr then
      result.stdout = result.stdout .. result.stderr
      result.stderr = ""
    elseif self.discard_stderr then
      result.stderr = ""
    end
    return result
  end

  --- Poll one asynchronous job without blocking.
  -- @return table? result, table? err
  function Handle:poll()
    if self.result then
      return self.result
    end
    local terminal = self.job:terminal_reason()
    if terminal == nil then
      if self.job:leader_alive() then
        return nil
      end
      terminal = "unverified"
    elseif self.job:leader_alive() then
      -- The terminal reason is published before the retained leader sends its
      -- final group signals. Waiting for the leader to exit keeps `cleanup`
      -- honest: a sweep marker or cancellation evidence is not read while the
      -- identity holder is still working.
      return nil
    end
    local result = build_handle_result(self, terminal)
    self.result = result
    handle_audit_finish(self, result, true)
    return result
  end

  --- Wait for the job's terminal result, bounded by `timeout_ms`.
  -- A nil return means the wait bound expired; the handle remains usable and
  -- can be polled, cancelled, or waited again.
  -- @param timeout_ms number?
  -- @return table? result, table? err
  function Handle:wait(timeout_ms)
    if self.result then
      return self.result
    end
    local bound = timeout_ms
    if bound == nil then
      bound = self.timeout_ms + KILL_AFTER_MS + SWEEP_GRACE_MS + 1000
    end
    if type(bound) ~= "number" or bound ~= bound or bound % 1 ~= 0 or bound < 0 then
      return nil, process_failure("wait timeout must be a non-negative integer")
    end
    local poll_ms = WheelJob.LIMITS.POLL_MS
    local steps = math.max(1, math.floor(bound / poll_ms))
    for _ = 1, steps do
      local result = self:poll()
      if result then
        return result
      end
      local slept, sleep_err = backend.sleep_ms(poll_ms)
      if not slept then
        return nil, process_failure("bounded job polling failed: " .. tostring(sleep_err))
      end
    end
    return nil
  end

  --- Request cancellation of this job's recorded process group.
  -- Repeated calls are idempotent; a terminal job returns a typed no-op state.
  -- @param opts table? { grace_ms = number? }
  -- @return boolean ok, table? info, table? err
  function Handle:cancel(opts)
    if self.result then
      local state = self.result.terminal_reason == "cancelled"
        and "already_cancelled" or "already_exited"
      return true, {
        state = state,
        terminal_reason = self.result.terminal_reason,
        term_sent = false,
        kill_sent = false,
        pgid = self.result.pgid,
      }
    end
    local info, err = self.job:request_cancel(opts)
    if not info then
      return nil, err
    end
    return true, info
  end

  --- Remove this job's private record after it reaches a terminal state.
  -- A running job is refused; `close` never signals or cancels implicitly. The
  -- retained leader is given a bounded time to finish its sweep so its files
  -- are not removed underneath it.
  -- @return boolean ok, table? err
  function Handle:close()
    local result = self:poll()
    if not result then
      return false, process_failure("the job is still running; cancel or wait before close")
    end
    local poll_ms = WheelJob.LIMITS.POLL_MS
    local steps = math.floor((KILL_AFTER_MS + SWEEP_GRACE_MS + 1000) / poll_ms)
    for _ = 1, steps do
      if not self.job:leader_alive() then
        break
      end
      backend.sleep_ms(poll_ms)
    end
    if self.job:leader_alive() then
      return false, process_failure("the retained leader is still running; the job record was kept")
    end
    local cleaned, cleanup_err = self.job:cleanup()
    if not cleaned then
      return false, cleanup_err
    end
    self.closed = true
    return true
  end

  --- Start one bounded process without blocking and return its job handle.
  -- The launch is backgrounded by the outer POSIX shell; the retained session
  -- leader records its own PID/PGID, and `start` waits only for that record (not
  -- for the command) before publishing the private job metadata. The handle is
  -- the only owner of the job record: callers must `wait`/`poll` and then
  -- `close`, or the private files remain for diagnosis.
  -- @param mode string "argv" or "shell"
  -- @param payload string
  -- @param payload_args table?
  -- @param opts table?
  -- @return table? handle, table? failure
  local function start_process(mode, payload, payload_args, opts)
    require_surface(type(os) == "table" and type(os.execute) == "function", "process.spawn")
    local normalized, option_failure = normalize_process_options(opts)
    if not normalized then
      return nil, option_failure
    end
    opts = normalized.opts
    local audit_meta = normalized.audit_meta
    local audit_decision = normalized.audit_decision
    local job_audit = nil
    local audit_warning = nil

    local function start_failure(message, outcome, spawned)
      local failure = process_failure(message, outcome)
      failure.spawned = spawned == true
      if audit_warning then
        failure.audit_warning = audit_warning
      end
      return failure
    end

    if audit_meta ~= nil and audit_decision == "deny" then
      local denied = start_failure("process denied by policy", nil, false)
      denied.denied = true
      local event = {
        event = "process.pre_spawn",
        kind = mode,
        cwd = normalized.cwd,
        role = audit_meta.role,
        agent = audit_meta.agent,
        task = audit_meta.task,
        tool = audit_meta.tool,
        intent = audit_meta.intent,
        decision = "deny",
        reason = audit_meta.reason,
        high_risk = audit_meta.high_risk == true,
        spawned = false,
      }
      if mode == "argv" then
        event.program = payload
        event.args = payload_args
      else
        event.shell = payload
      end
      local ok, recorded = pcall(WheelAudit.record, event, { dir = audit_meta.dir })
      if not ok or not recorded then
        denied.audit_error = WheelErrors.audit_unavailable()
        denied.audit_warning = "audit record could not be written for a denied command"
      end
      return nil, denied
    end

    if audit_meta ~= nil then
      local dir, resolve_err = WheelAudit.resolve_dir({ dir = audit_meta.dir })
      if dir then
        job_audit = {
          dir = dir,
          high_risk = audit_meta.high_risk == true,
          role = audit_meta.role,
          agent = audit_meta.agent,
          task = audit_meta.task,
          tool = audit_meta.tool,
          intent = audit_meta.intent,
        }
      elseif audit_meta.high_risk == true then
        local failure = start_failure(
          "audit directory could not be resolved; refusing a high-risk spawn", nil, false)
        failure.audit_error = resolve_err or WheelErrors.audit_unavailable()
        return nil, failure
      else
        audit_warning = "audit directory could not be resolved; cancellation audit is unavailable"
      end
    end

    local job, job_err = WheelJob.create({ root = opts.job_root })
    if not job then
      local failure = start_failure("job record could not be created")
      failure.audit_error = job_err
      return nil, failure
    end

    local function cleanup_job()
      job:cleanup()
    end

    for _, name in ipairs({ "out", "err", "diag", "status", "sweep", "pgid" }) do
      local created = backend.create_private_file(job.paths[name], "")
      if not created then
        cleanup_job()
        local failure = start_failure("job capture files could not be created")
        failure.audit_error = WheelErrors.job_failure(
          WheelErrors.E_JOB_UNAVAILABLE, "job capture files could not be created")
        return nil, failure
      end
    end

    local stdin_path = "/dev/null"
    if normalized.stdin_data ~= nil then
      local staged = backend.create_private_file(job.paths.stdin, normalized.stdin_data)
      if not staged then
        cleanup_job()
        local failure = start_failure("job stdin could not be staged")
        failure.audit_error = WheelErrors.job_failure(
          WheelErrors.E_JOB_UNAVAILABLE, "job stdin could not be staged")
        return nil, failure
      end
      stdin_path = job.paths.stdin
    end

    local generation, generation_err = WheelJob.random_token(16)
    if not generation then
      cleanup_job()
      local failure = start_failure("job generation could not be created")
      failure.audit_error = generation_err
      return nil, failure
    end

    local env_parts, env_err, env_outcome =
      build_child_environment(os.getenv, opts.env)
    if not env_parts then
      cleanup_job()
      return nil, start_failure(env_err, env_outcome, false)
    end

    local tools, tools_failure = resolve_process_tools()
    if not tools then
      cleanup_job()
      return nil, tools_failure
    end

    local started_ms = start_clock_ms()
    local audit_started = nil
    local audit_recorded = false
    if audit_meta ~= nil and job_audit ~= nil then
      audit_started = started_ms
      local event = {
        event = "process.pre_spawn",
        kind = mode,
        cwd = normalized.cwd,
        role = audit_meta.role,
        agent = audit_meta.agent,
        task = audit_meta.task,
        tool = audit_meta.tool,
        intent = audit_meta.intent,
        decision = "allow",
        reason = audit_meta.reason,
        high_risk = audit_meta.high_risk == true,
        spawned = false,
        job_id = job.job_id,
      }
      if mode == "argv" then
        event.program = payload
        event.args = payload_args
      else
        event.shell = payload
      end
      local ok, recorded, audit_err = pcall(WheelAudit.record, event, { dir = job_audit.dir })
      if ok and recorded then
        audit_recorded = true
      elseif audit_meta.high_risk == true then
        cleanup_job()
        local failure = start_failure(
          "audit record could not be written; refusing a high-risk spawn", nil, false)
        failure.audit_error = (ok and audit_err) or WheelErrors.audit_unavailable()
        return nil, failure
      else
        audit_warning = "audit record could not be written; continuing because the command is not marked high risk"
      end
    end

    local function audit_stub()
      return {
        audit_meta = audit_meta,
        audit_dir = job_audit and job_audit.dir or nil,
        audit_recorded = audit_recorded,
        audit_started = audit_started,
        audit_warning = audit_warning,
        mode = mode,
        payload = payload,
        payload_args = payload_args,
        cwd = normalized.cwd,
        audit_decision = audit_decision,
        job = job,
      }
    end

    local command = build_launch_command(mode, payload, payload_args, normalized.cwd,
      stdin_path, tools, env_parts, {
        out = job.paths.out,
        err = job.paths.err,
        diag = job.paths.diag,
        status = job.paths.status,
        sweep = job.paths.sweep,
        pgid = job.paths.pgid,
        cancel = job.paths.cancel,
        terminal = job.paths.terminal,
        lock = job.paths.lock,
        generation = generation,
      }, normalized.timeout_ms)
    local launch = "umask 077; ( " .. command .. " ) > /dev/null 2> "
      .. shell_quote(job.paths.diag) .. " < /dev/null & echo $! > "
      .. shell_quote(job.paths.wrapper)
    local launch_status = normalized_exit_status(os.execute(launch))
    if launch_status ~= 0 then
      cleanup_job()
      local failure = start_failure("the job supervisor could not be launched", nil, false)
      handle_audit_finish(audit_stub(), failure, false)
      return nil, failure
    end

    local poll_ms = WheelJob.LIMITS.POLL_MS
    local pgid = nil
    local start_steps = math.floor(WheelJob.LIMITS.START_WAIT_MS / poll_ms)
    for _ = 1, start_steps do
      pgid = read_private_number(job.paths.pgid)
      if pgid and pgid > 1 then
        break
      end
      local wrapper = read_private_number(job.paths.wrapper)
      if wrapper and not backend.proc_is_alive(wrapper) then
        pgid = read_private_number(job.paths.pgid)
        if not pgid or pgid <= 1 then
          pgid = nil
          break
        end
      end
      backend.sleep_ms(poll_ms)
    end
    if not pgid or pgid <= 1 then
      -- The wrapper PID is a recorded child of this harness, but a group
      -- signal would target the harness's own group. Never do that: leave the
      -- bounded command to its own timeout and remove only the private record.
      cleanup_job()
      local failure = start_failure(
        "the job supervisor did not record its process group", nil, false)
      failure.audit_error = WheelErrors.job_failure(
        WheelErrors.E_JOB_UNAVAILABLE, "process group was not recorded")
      handle_audit_finish(audit_stub(), failure, false)
      return nil, failure
    end

    local meta_ok, meta_err = job:write_meta({
      generation = generation,
      pgid = pgid,
      leader_pid = pgid,
      timeout_ms = normalized.timeout_ms,
      started_ms = started_ms,
      audit = job_audit,
    })
    if not meta_ok then
      backend.signal_group(pgid, "TERM")
      backend.sleep_ms(SWEEP_GRACE_MS)
      if backend.signal_group(pgid, "0") then
        backend.signal_group(pgid, "KILL")
      end
      for _ = 1, math.floor(WheelJob.LIMITS.CANCEL_KILL_WAIT_MS / WheelJob.LIMITS.POLL_MS) do
        if not backend.signal_group(pgid, "0") then
          break
        end
        backend.sleep_ms(WheelJob.LIMITS.POLL_MS)
      end
      local group_gone = not backend.signal_group(pgid, "0")
      cleanup_job()
      local failure = start_failure(
        "the job metadata could not be published; the recorded group was terminated", nil, true)
      failure.cleanup = group_gone and WheelHost.GROUP_CLEANUP.SWEPT
        or WheelHost.GROUP_CLEANUP.UNVERIFIED
      failure.pgid = pgid
      failure.audit_error = meta_err
      handle_audit_finish(audit_stub(), failure, true)
      return nil, failure
    end

    local handle = setmetatable({
      job = job,
      mode = mode,
      payload = payload,
      payload_args = payload_args,
      cwd = normalized.cwd,
      timeout_ms = normalized.timeout_ms,
      capture_cap = normalized.capture_cap,
      merge_stderr = opts.merge_stderr == true,
      discard_stderr = opts.discard_stderr == true,
      audit_meta = audit_meta,
      audit_dir = job_audit and job_audit.dir or nil,
      audit_decision = audit_decision,
      audit_started = audit_started,
      audit_recorded = audit_recorded,
      audit_warning = audit_warning,
      result = nil,
      closed = false,
    }, Handle)
    return handle
  end

  --- Execute a shell command line inside the bounded, scrubbed process
  -- primitive. This is the explicit shell-string surface for Execute-intent
  -- tools; argv call sites use `run_program`.
  -- The command runs in a `setsid`-recorded process group under GNU `timeout`.
  -- Timeout expiry signals the direct child; the retained session leader then
  -- sweeps remaining members of the recorded PGID with TERM, the bounded grace,
  -- and KILL, and the direct command's status is preserved. stdout and stderr
  -- are redirected to private 0600 files and read back at most
  -- `opts.max_output_bytes` (default 256 KiB) so a runaway child cannot exhaust
  -- harness memory. The child environment is rebuilt from the allowlist; stdin
  -- is `/dev/null` unless `opts.stdin` supplies bytes.
  --
  -- Result: `ok` reports a launched process (a timeout is still launched),
  -- `code`/`exit_code` carry the shell status (124/137 map to timeout),
  -- `timed_out`, `truncated`, `stdout_truncated`, `stderr_truncated`,
  -- `outcome` (exited|timeout|unavailable|failure), and `cleanup`
  -- (swept|unverified|not_run) are explicit.
  -- @param shell_string string
  -- @param opts table? { timeout_ms, max_output_bytes, stdin, cwd, merge_stderr,
  --                         discard_stderr, env, audit }
  -- @return table process result
  function backend.run_command(shell_string, opts)
    if type(shell_string) ~= "string" then
      return process_failure("shell command must be a string")
    end
    return execute_process("shell", shell_string, nil, opts)
  end

  --- Execute a program with an explicit argument vector. The caller never
  -- builds a shell string: each element is passed as a positional argument to
  -- a constant `sh -c` wrapper and then to `env -- "$@"`, so no argv element is
  -- parsed as shell syntax or as an env option (including `-S`/`-i`). A program
  -- name that starts with `-` or contains `=` is refused before env runs. The
  -- wrapper applies stdin redirection and an optional cwd; callers must resolve
  -- and contain `opts.cwd` in the workspace themselves. `run_command` remains
  -- the shell-string primitive.
  -- `opts.merge_stderr` merges the captured streams, `opts.discard_stderr`
  -- drops captured stderr, and `opts.stdin` supplies the child's stdin bytes.
  -- @param program string
  -- @param args string[]?
  -- @param opts table? { timeout_ms, max_output_bytes, stdin, cwd, merge_stderr,
  --                      discard_stderr, env, audit }
  -- @return table process result
  function backend.run_program(program, args, opts)
    if type(program) ~= "string" or program == "" then
      return process_failure("program must be a non-empty string")
    end
    if args ~= nil and type(args) ~= "table" then
      return process_failure("program arguments must be a table")
    end
    local argv = {}
    for index, arg in ipairs(args or {}) do
      if type(arg) ~= "string" then
        return process_failure("program argument " .. tostring(index) .. " must be a string")
      end
      argv[#argv + 1] = arg
    end
    return execute_process("argv", program, argv, opts)
  end

  --- Start an argv process without blocking and return its job handle.
  -- The handle exposes `poll`, `wait`, `cancel`, and `close`; the synchronous
  -- `run_program` contract is unchanged.
  -- @param program string
  -- @param args string[]?
  -- @param opts table? same as run_program plus `job_root`
  -- @return table? handle, table? failure
  function backend.start_program(program, args, opts)
    if type(program) ~= "string" or program == "" then
      return nil, process_failure("program must be a non-empty string")
    end
    if args ~= nil and type(args) ~= "table" then
      return nil, process_failure("program arguments must be a table")
    end
    local argv = {}
    for index, arg in ipairs(args or {}) do
      if type(arg) ~= "string" then
        return nil, process_failure("program argument " .. tostring(index) .. " must be a string")
      end
      argv[#argv + 1] = arg
    end
    return start_process("argv", program, argv, opts)
  end

  --- Start a shell-string process without blocking and return its job handle.
  -- @param shell_string string
  -- @param opts table? same as run_command plus `job_root`
  -- @return table? handle, table? failure
  function backend.start_command(shell_string, opts)
    if type(shell_string) ~= "string" then
      return nil, process_failure("shell command must be a string")
    end
    return start_process("shell", shell_string, nil, opts)
  end

  --- Cancel one recorded job by id through its private metadata record.
  -- @param job_id string
  -- @param opts table? { root = string?, grace_ms = number? }
  -- @return table? info, table? err
  function backend.cancel_job(job_id, opts)
    opts = type(opts) == "table" and opts or {}
    local root = opts.root
    if root == nil or root == "" then
      local ok, dir = pcall(backend.tmp_dir)
      if not ok or type(dir) ~= "string" then
        return nil, WheelErrors.job_failure(
          WheelErrors.E_JOB_UNAVAILABLE, "the private runtime directory is unavailable")
      end
      root = dir .. "/jobs"
    end
    return WheelJob.cancel(root, job_id, opts)
  end

  --- Quote one POSIX shell argument for the explicit shell-string primitive.
  -- @param value string
  -- @return string
  function backend.shell_quote(value)
    return shell_quote(value)
  end

  --- Resolve, create, and repair the private temporary directory.
  -- The path is normalized before inspection: repeated `/` separators collapse
  -- and `.` segments are removed, so `.../wheel//tmp` and `.../wheel/./tmp`
  -- cannot skip the exact `.../wheel/tmp` suffix guard.
  -- The filesystem root and any all-dots segment (`.`, `..`, `...`, ...) are
  -- rejected before mkdir/chmod, so an all-dots symlink component cannot be
  -- followed. The harness-owned directory (and the `wheel` component of the
  -- state fallback) must not be a symbolic link: `chmod` must never follow a
  -- pre-existing link. Legitimate parent links such as `/tmp` are allowed
  -- because only the harness-owned path is inspected.
  -- @return string dir
  function backend.tmp_dir()
    local dir = tmp_root
    if dir == nil or dir == "" then
      require_surface(type(os) == "table" and type(os.getenv) == "function", "fs.write")
      local runtime = os.getenv("XDG_RUNTIME_DIR")
      if runtime and runtime ~= "" then
        dir = runtime .. "/wheel"
      else
        local state = os.getenv("XDG_STATE_HOME")
        if state and state ~= "" then
          dir = state .. "/wheel/tmp"
        else
          local home = os.getenv("HOME")
          if home and home ~= "" then
            dir = home .. "/.local/state/wheel/tmp"
          end
        end
      end
    end
    if type(dir) ~= "string" or dir == "" then
      error(WheelErrors.capability_denied("fs.write"), 0)
    end
    dir = normalize_tmp_dir(dir)
    -- The harness-owned temp directory must not be the filesystem root or
    -- contain an all-dots segment; reject before any mkdir/chmod.
    if dir == "/" or has_dot_only_segment(dir) then
      error(WheelErrors.capability_denied("fs.write"), 0)
    end

    local parent = owned_parent_path(dir)
    require_surface(type(os) == "table" and type(os.execute) == "function", "fs.write")
    if path_is_symlink(dir) or (parent and path_is_symlink(parent)) then
      error(WheelErrors.capability_denied("fs.write"), 0)
    end

    local mkdir_ok = os.execute("mkdir -p -- " .. shell_quote(dir) .. " 2>/dev/null")
    if not (mkdir_ok == true or mkdir_ok == 0) then
      error(WheelErrors.capability_denied("fs.write"), 0)
    end

    -- Re-check after mkdir so a link that appeared during creation is not
    -- chmodded; the check plus chmod narrows the remaining race window.
    if path_is_symlink(dir) or (parent and path_is_symlink(parent)) then
      error(WheelErrors.capability_denied("fs.write"), 0)
    end

    local chmod_ok = os.execute("chmod 700 -- " .. shell_quote(dir) .. " 2>/dev/null")
    if not (chmod_ok == true or chmod_ok == 0) then
      error(WheelErrors.capability_denied("fs.write"), 0)
    end
    return dir
  end

  --- Return a unique path inside the private temporary directory.
  -- The file is not created; callers use `tmp_create` or `tmp_create_exclusive`
  -- so creation is exclusive and mode 0600. Uniqueness is process-local: the
  -- backend instance token plus a monotonic sequence cannot repeat within this
  -- process. The token is not a cross-process uniqueness guarantee, so
  -- exclusive creation is required and a collision fails closed. No wall-clock
  -- read is involved, so a missing `os.time` cannot produce a silent "0"
  -- fallback.
  -- @return string
  function backend.tmp_path()
    local dir = backend.tmp_dir()
    tmp_sequence = tmp_sequence + 1
    return string.format("%s/wheel-%s-%d", dir, process_token, tmp_sequence)
  end

  --- Create <path> inside the private runtime directory with mode 0600 and
  -- write <content>. A pre-existing regular file, FIFO, device, or symbolic
  -- link is refused, never followed or truncated. The caller owns removal.
  -- @param path string
  -- @param content string?
  -- @return boolean ok, string? err
  function backend.tmp_create_exclusive(path, content)
    require_surface(type(os) == "table" and type(os.execute) == "function", "fs.write")
    if type(path) ~= "string" or path == "" or path:find("[%z\n\r]") then
      return false, "invalid temporary path"
    end
    if content ~= nil and type(content) ~= "string" then
      return false, "temporary content must be a string"
    end
    local dir_ok, dir = pcall(backend.tmp_dir)
    if not dir_ok or path:sub(1, #dir + 1) ~= dir .. "/" or has_dot_only_segment(path) then
      return false, "temporary path is outside the private directory"
    end
    local probe, probe_err = create_private_temp(dir)
    if not probe then
      return false, probe_err
    end
    local wrote, write_err = write_private_file(probe, content or "")
    if not wrote then
      local removed, remove_err = os.remove(probe)
      if not removed then
        return false, tostring(write_err)
          .. "; cleanup failed: " .. tostring(remove_err or probe)
      end
      return false, tostring(write_err)
    end
    local exists = normalized_exit_status(os.execute(
      "test -e " .. shell_quote(path) .. " || test -L " .. shell_quote(path))) == 0
    if exists then
      os.remove(probe)
      return false, "temporary path already exists"
    end
    local linked = normalized_exit_status(os.execute(
      "ln -- " .. shell_quote(probe) .. " " .. shell_quote(path) .. " 2>/dev/null"))
    if linked ~= 0 then
      os.remove(probe)
      return false, "temporary path already exists or cannot be linked"
    end
    local removed, remove_err = os.remove(probe)
    if not removed then
      os.remove(path)
      return false, "temporary-link cleanup failed: " .. tostring(remove_err or probe)
    end
    local verified, verify_err = verify_private_file(path)
    if not verified then
      os.remove(path)
      return false, verify_err
    end
    return true
  end

  --- Create a new exclusive 0600 file in the private directory and return its
  -- path. Collisions are retried with a fresh sequence number, bounded by
  -- `MAX_TMP_CREATE_ATTEMPTS`; an exhausted path list fails closed.
  -- @param content string?
  -- @return string? path, string? err
  function backend.tmp_create(content)
    if content ~= nil and type(content) ~= "string" then
      return nil, "temporary content must be a string"
    end
    local dir_ok, dir = pcall(backend.tmp_dir)
    if not dir_ok then
      return nil, "the private temporary directory is unavailable"
    end
    local path, create_err = create_private_temp(dir)
    if not path then
      return nil, create_err
    end
    local wrote, write_err = write_private_file(path, content or "")
    if not wrote then
      local removed, remove_err = os.remove(path)
      if not removed then
        return nil, tostring(write_err)
          .. "; cleanup failed: " .. tostring(remove_err or path)
      end
      return nil, tostring(write_err)
    end
    return path
  end

  --- Wall-clock time in seconds since the epoch (os.time semantics).
  -- @return number
  function backend.now()
    require_surface(type(os) == "table" and type(os.time) == "function", "time.now")
    return os.time()
  end

  --- Sleep for a bounded number of milliseconds using the resolved `sleep`.
  -- This is the one host primitive used by cancellation polling; callers never
  -- spin on `os.execute`. A missing `sleep` or a non-zero status fails closed.
  -- @param ms number
  -- @return boolean ok, string? err
  function backend.sleep_ms(ms)
    require_surface(type(os) == "table" and type(os.execute) == "function", "process.spawn")
    if type(ms) ~= "number" or ms ~= ms or ms % 1 ~= 0 or ms < 0 or ms > MAX_SLEEP_MS then
      return false, "invalid sleep duration"
    end
    if ms == 0 then
      return true
    end
    local sleep_bin = resolve_tool("sleep")
    if not sleep_bin then
      return false, "the 'sleep' utility is unavailable"
    end
    local status = normalized_exit_status(os.execute(
      shell_quote(sleep_bin) .. " " .. format_sleep(ms) .. " 2>/dev/null"))
    if status == 0 then
      return true
    end
    return false, "sleep failed"
  end

  --- CPU time in seconds (os.clock semantics).
  -- @return number
  function backend.clock()
    require_surface(type(os) == "table" and type(os.clock) == "function", "time.clock")
    return os.clock()
  end

  --- Return the current process id.
  -- A short-lived POSIX shell reports its own parent (`$PPID`), which is the
  -- interpreter process. Values that do not parse as a pid above 1 fail closed.
  -- @return number? pid
  function backend.pid()
    require_surface(type(io) == "table" and type(io.popen) == "function", "process.spawn")
    local pipe = io.popen('printf "%s" "$PPID" 2>/dev/null', "r")
    if not pipe then
      return nil
    end
    local line = pipe:read("*l")
    pipe:close()
    local pid = tonumber((line or ""):match("^%s*(%d+)%s*$"))
    if pid == nil or pid <= 1 then
      return nil
    end
    return pid
  end

  --- Probe whether <pid> is a live process for this user.
  -- `kill -0` only checks existence and permission; no signal is delivered.
  -- A permission denial is reported as not alive, which is the safe answer for
  -- a pid that cannot be this user's session daemon. An unavailable probe
  -- surface or an unexpected status returns an error so callers fail closed
  -- instead of treating "unknown" as stale.
  -- @param pid number
  -- @return boolean alive, string? err
  function backend.proc_is_alive(pid)
    require_surface(type(os) == "table" and type(os.execute) == "function", "process.spawn")
    if type(pid) ~= "number" or pid ~= pid or pid % 1 ~= 0 or pid <= 1 then
      return false, "invalid pid"
    end
    local status = normalized_exit_status(os.execute(
      "kill -0 " .. tostring(pid) .. " 2>/dev/null"))
    if status == 0 then
      return true
    end
    if status == 1 then
      return false
    end
    return false, "liveness probe failed"
  end

  --- Probe or signal one recorded process group.
  -- Only signal 0 (liveness), TERM, and KILL are accepted, and the target is a
  -- validated positive integer rendered directly into `kill -SIGNAL -PGID`.
  -- No name, pattern, or caller-supplied fragment is ever interpolated. The
  -- C-locale `kill` diagnostic distinguishes a denied target
  -- (`false, "permission denied"`) from a vanished group
  -- (`false, "no such process group"`) and from a probe failure, so a caller
  -- never treats a foreign target as an already-exited job.
  --
  -- Lua 5.1 `io.popen():close()` returns `true` without the child exit status,
  -- so the command appends its own status marker. The marker is parsed from the
  -- captured output; the close return is deliberately ignored.
  -- @param pgid number
  -- @param signal string "0", "TERM", or "KILL"
  -- @return boolean ok, string? err
  function backend.signal_group(pgid, signal)
    require_surface(type(io) == "table" and type(io.popen) == "function", "process.spawn")
    if type(pgid) ~= "number" or pgid ~= pgid or pgid % 1 ~= 0 or pgid <= 1
      or pgid > 2147483647 then
      return false, "invalid process group"
    end
    if signal ~= "0" and signal ~= "TERM" and signal ~= "KILL" then
      return false, "invalid signal"
    end
    local marker = "__WHEEL_SIGNAL_STATUS__"
    local pipe = io.popen(
      "LC_ALL=C kill -" .. signal .. " -" .. tostring(pgid)
        .. " 2>&1; printf '\\n" .. marker .. "%s' \"$?\"", "r")
    if not pipe then
      return false, "process-group signal probe unavailable"
    end
    local output = pipe:read("*a") or ""
    pipe:close()
    local diagnostic, status_text = output:match("^(.*)" .. marker .. "(%d+)%s*$")
    local status = tonumber(status_text)
    if status == nil then
      return false, "process-group signal probe failed"
    end
    if status == 0 then
      return true
    end
    if status == 1 then
      local text = tostring(diagnostic or ""):lower()
      if text:find("operation not permitted", 1, true)
        or text:find("not permitted", 1, true)
        or text:find("permission denied", 1, true) then
        return false, "permission denied"
      end
      return false, "no such process group"
    end
    return false, "process-group signal failed"
  end

  return backend
end

-- ---------------------------------------------------------------------------
-- Backend selection (the single named selection path)
-- ---------------------------------------------------------------------------

--- The only production backend identifier.
WheelHost.BACKEND_STANDALONE = "standalone"

--- Build a backend without installing it. Unknown names and non-POSIX
-- platforms fail closed with a typed capability denial.
-- @param name string
-- @param opts table? { platform = string?, tmp_root = string? }
-- @return table backend
function WheelHost.create_backend(name, opts)
  if name ~= WheelHost.BACKEND_STANDALONE then
    error(WheelErrors.capability_denied("host.backend"), 0)
  end
  return standalone.new(opts)
end

--- Select and install the backend for this harness process. This is the one
-- selection path; callers must not assign `WheelHost.backend` directly.
-- @param name string
-- @param opts table?
-- @return table backend
function WheelHost.select_backend(name, opts)
  local backend = WheelHost.create_backend(name, opts)
  WheelHost.backend = backend
  WheelHost.backend_name = backend.name
  return backend
end

-- Harness launch: construct and install the explicit standalone backend once.
-- On an unsupported platform this raises the typed denial at require time, so
-- the harness cannot start with an implicit or weaker execution surface.
WheelHost.select_backend(WheelHost.BACKEND_STANDALONE)

-- ---------------------------------------------------------------------------
-- Public seam (call sites use only these)
-- ---------------------------------------------------------------------------

--- Invoke one backend primitive, failing closed when it is unavailable.
-- @param capability string
-- @param method string
-- @param ... any
-- @return any
local function invoke(capability, method, ...)
  local backend = WheelHost.backend
  local fn = type(backend) == "table" and backend[method] or nil
  if type(fn) ~= "function" then
    error(WheelErrors.capability_denied(capability), 0)
  end
  return fn(...)
end

--- Filesystem primitives.
WheelHost.fs = {}

--- Create a directory tree (all missing parents).
-- @param path string
-- @return boolean ok, number code
function WheelHost.fs.mkdir_p(path)
  return invoke("fs.write", "mkdir_p", path)
end

--- Create one directory with mode 0700, refusing an existing path.
-- @param path string
-- @return boolean ok, string? err
function WheelHost.fs.mkdir(path)
  return invoke("fs.write", "mkdir_exclusive", path)
end

--- List directory entries.
-- @param path string
-- @return table { ok, code, stdout, stderr, entries, total }
function WheelHost.fs.list_dir(path)
  return invoke("fs.read", "list_dir", path)
end

--- Read a whole file.
-- @param path string
-- @return string? content, string? err
function WheelHost.fs.read_file(path)
  return invoke("fs.read", "read_file", path)
end

--- Read at most `max_bytes` bytes from a file.
-- @param path string
-- @param max_bytes number
-- @return string? content, string? err
function WheelHost.fs.read_file_bounded(path, max_bytes)
  return invoke("fs.read", "read_file_bounded", path, max_bytes)
end

--- Write a whole file.
-- @param path string
-- @param content string
-- @return boolean ok, string? err
function WheelHost.fs.write_file(path, content)
  return invoke("fs.write", "write_file", path, content)
end

--- Append to an existing private 0600 regular file without truncating it.
-- @param path string
-- @param content string
-- @return boolean ok, string? err
function WheelHost.fs.append_file(path, content)
  return invoke("fs.write", "append_file", path, content)
end

--- Set a file mode.
-- @param path string
-- @param mode string|number
-- @return boolean ok, string? err
function WheelHost.fs.chmod(path, mode)
  return invoke("fs.write", "chmod", path, mode)
end

--- Atomically rename a path on one filesystem.
-- @param from string
-- @param to string
-- @return boolean ok, string? err
function WheelHost.fs.rename(from, to)
  return invoke("fs.write", "rename", from, to)
end

--- Remove a file.
-- @param path string
-- @return boolean ok, string? err
function WheelHost.fs.remove_file(path)
  return invoke("fs.write", "remove_file", path)
end

--- Test for a readable file.
-- @param path string
-- @return boolean
function WheelHost.fs.exists(path)
  return invoke("fs.read", "exists", path)
end

--- Return lstat-style metadata and type probes for a path.
-- @param path string
-- @return table { exists, symlink, regular, directory, fifo, uid?, mode?, links? }
function WheelHost.fs.stat(path)
  return invoke("fs.read", "stat", path)
end

--- Return the current effective uid, or nil when it cannot be read.
-- @return number? uid
function WheelHost.fs.euid()
  return invoke("fs.read", "euid")
end

--- Read `count` bytes from the host random source (`/dev/urandom`).
-- @param count number
-- @return string? bytes, string? err
function WheelHost.fs.random_bytes(count)
  return invoke("fs.read", "random_bytes", count)
end

--- Create a new regular file with mode 0600 at `path` and write `content`.
-- The path must not exist; a pre-existing file, FIFO, device, or symbolic link
-- is refused rather than followed or truncated. The caller owns removal.
-- @param path string
-- @param content string?
-- @return boolean ok, string? err
function WheelHost.fs.create_private_file(path, content)
  return invoke("fs.write", "create_private_file", path, content)
end

--- Create a new FIFO with mode 0600 at `path`.
-- @param path string
-- @return boolean ok, string? err
function WheelHost.fs.mkfifo(path)
  return invoke("fs.write", "mkfifo", path)
end

--- Create a hard link at `to` pointing at `from`; never replace `to`.
-- @param from string
-- @param to string
-- @return boolean ok, string? err
function WheelHost.fs.link_exclusive(from, to)
  return invoke("fs.write", "link_exclusive", from, to)
end

--- Open a verified private FIFO read/write (O_RDWR; never blocks on a peer).
-- @param path string
-- @return file? handle, string? err
function WheelHost.fs.open_fifo(path)
  return invoke("fs.read", "open_fifo", path)
end

--- Remove one empty directory. Never recursive.
-- @param path string
-- @return boolean ok, string? err
function WheelHost.fs.remove_dir(path)
  return invoke("fs.write", "remove_dir", path)
end

--- Process primitives.
WheelHost.proc = {}

--- Normalize a tool-shaped command_runner result into the WheelHost proc shape.
-- @param result table? { success, exit_code, stdout, stderr }
-- @return table process result
local function normalize_runner_result(result)
  if type(result) ~= "table" then
    return process_failure("command_runner returned no result")
  end
  local code = result.exit_code
  if type(code) ~= "number" then
    code = (result.success ~= false) and 0 or 1
  end
  local timed_out = result.timed_out == true
  return {
    ok = true,
    code = code,
    exit_code = code,
    stdout = result.stdout or "",
    stderr = result.stderr or "",
    timed_out = timed_out,
    truncated = result.truncated == true,
    stdout_truncated = result.stdout_truncated == true,
    stderr_truncated = result.stderr_truncated == true,
    outcome = timed_out
      and WheelHost.PROCESS_OUTCOME.TIMEOUT
      or WheelHost.PROCESS_OUTCOME.EXITED,
    cleanup = WheelHost.GROUP_CLEANUP.NOT_RUN,
    cancel_requested = false,
    terminal_reason = timed_out and "timeout" or "exited",
  }
end

--- Execute a shell command line inside the bounded, scrubbed process
-- primitive. This is the explicit shell-string surface for Execute-intent
-- tools; argv call sites use `run_program`.
-- With `env.command_runner` set (the existing tool injection seam), the runner
-- is invoked with { command = shell_string } and its tool-shaped result is
-- normalized; otherwise the backend runs the command under the setsid-recorded
-- process group, timeout, retained-leader group sweep, output cap, and environment
-- allowlist.
-- @param shell_string string
-- @param env table? { command_runner = function? }
-- @param opts table? { timeout_ms, max_output_bytes, stdin, cwd, env, audit }
-- @return table process result
function WheelHost.proc.run_command(shell_string, env, opts)
  if env and type(env.command_runner) == "function" then
    -- The injected runner is a test seam that never crosses the host process
    -- boundary, so it cannot produce the real pre-spawn/completion records. An
    -- audit request is rejected rather than silently producing incomplete
    -- evidence.
    if type(opts) == "table" and opts.audit ~= nil then
      return process_failure(
        "audit is not supported with an injected command_runner")
    end
    return normalize_runner_result(env.command_runner({ command = shell_string }, env))
  end
  return invoke("process.spawn", "run_command", shell_string, opts)
end

--- Execute a program with an explicit argument vector (no unquoted shell
-- string at the call site). Every element crosses the seam as a positional
-- argument to a constant `env -- "$@"` wrapper; nothing is interpolated into a
-- shell script. `opts.cwd` is caller-resolved and must already be contained in
-- the workspace; this seam validates only its shape. The command_runner
-- override applies to shell-string execution only, so it is not consulted here.
-- @param program string
-- @param args string[]?
-- @param opts table? { timeout_ms, max_output_bytes, stdin, cwd, merge_stderr,
--                      discard_stderr, env, audit }
-- @return table process result
function WheelHost.proc.run_program(program, args, opts)
  return invoke("process.spawn", "run_program", program, args, opts)
end

--- Start a program with an explicit argument vector without blocking.
-- Returns a handle with `poll()`, `wait(timeout_ms)`, `cancel(opts)`, and
-- `close()`; the synchronous `run_program` contract is unchanged. `opts` is the
-- same table plus `job_root` for an explicit private job directory.
-- @param program string
-- @param args string[]?
-- @param opts table?
-- @return table? handle, table? failure
function WheelHost.proc.start(program, args, opts)
  return invoke("process.spawn", "start_program", program, args, opts)
end

--- Start a shell-string command without blocking and return its job handle.
-- @param shell_string string
-- @param opts table?
-- @return table? handle, table? failure
function WheelHost.proc.start_command(shell_string, opts)
  return invoke("process.spawn", "start_command", shell_string, opts)
end

--- Cancel one recorded job by id through `scripts/wheel-proc`.
-- The job id and root identify a private record; metadata, ownership, and the
-- recorded leader generation are validated before any signal.
-- @param job_id string
-- @param opts table? { root = string?, grace_ms = number? }
-- @return table? info, table? err
function WheelHost.proc.cancel_job(job_id, opts)
  return invoke("process.spawn", "cancel_job", job_id, opts)
end

--- Quote one POSIX shell argument for an explicit shell-string call site.
-- @param value string
-- @return string
function WheelHost.proc.shell_quote(value)
  return invoke("process.spawn", "shell_quote", value)
end

--- Return the current process id, or nil when it cannot be read.
-- @return number? pid
function WheelHost.proc.pid()
  return invoke("process.spawn", "pid")
end

--- Probe whether `pid` is a live process for this user (`kill -0`, no signal).
-- A permission denial is reported as not alive; an unavailable probe surface or
-- unexpected status returns an error so callers fail closed.
-- @param pid number
-- @return boolean alive, string? err
function WheelHost.proc.is_alive(pid)
  return invoke("process.spawn", "proc_is_alive", pid)
end

--- Probe or signal one recorded process group.
-- Signal 0 is a liveness probe; TERM and KILL target the recorded PGID. No
-- name or pattern is accepted.
-- @param pgid number
-- @param signal string "0", "TERM", or "KILL"
-- @return boolean ok, string? err
function WheelHost.proc.signal_group(pgid, signal)
  return invoke("process.spawn", "signal_group", pgid, signal)
end

--- Temporary-file primitives.
WheelHost.tmp = {}

--- Return the private runtime directory, creating it with mode 0700.
-- @return string
function WheelHost.tmp.dir()
  return invoke("fs.write", "tmp_dir")
end

--- Return a unique path inside the private runtime directory (file not created).
-- @return string
function WheelHost.tmp.name()
  return invoke("fs.write", "tmp_path")
end

--- Create a new file exclusively with mode 0600 in the private runtime
-- directory, write `content`, and return its path. Never follows or overwrites
-- a pre-existing path; collisions retry a bounded number of fresh names.
-- @param content string?
-- @return string? path, string? err
function WheelHost.tmp.create(content)
  return invoke("fs.write", "tmp_create", content)
end

--- Create `path` (inside the private runtime directory) exclusively with mode
-- 0600 and write `content`. A pre-existing file, FIFO, device, or symlink is
-- refused. The caller owns removal.
-- @param path string
-- @param content string?
-- @return boolean ok, string? err
function WheelHost.tmp.create_exclusive(path, content)
  return invoke("fs.write", "tmp_create_exclusive", path, content)
end

--- Time primitives.
WheelHost.time = {}

--- Wall-clock time in seconds since the epoch.
-- @return number
function WheelHost.time.now()
  return invoke("time.now", "now")
end

--- CPU time in seconds.
-- @return number
function WheelHost.time.clock()
  return invoke("time.clock", "clock")
end

--- Sleep for a bounded number of milliseconds through the host `sleep` tool.
-- @param ms number
-- @return boolean ok, string? err
function WheelHost.time.sleep_ms(ms)
  return invoke("time.sleep", "sleep_ms", ms)
end

return WheelHost
