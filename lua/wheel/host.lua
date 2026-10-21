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
--   WheelHost.fs.chmod(path, mode)          set a file mode
--   WheelHost.fs.rename(from, to)           atomically rename within a filesystem
--   WheelHost.fs.remove_file(path)          remove a file
--   WheelHost.fs.exists(path)               test for a readable file
--   WheelHost.fs.stat(path)                 lstat-style metadata and type probes
--   WheelHost.proc.run_command(shell_string, env?, opts?)
--                                           run a shell command line (explicit
--                                           shell-string primitive)
--   WheelHost.proc.run_program(program, args, opts?)
--                                           run argv with stdin, cwd, timeout,
--                                           output cap, and scrubbed env
--   WheelHost.proc.shell_quote(value)       quote one POSIX shell argument
--   WheelHost.tmp.dir()                     private runtime directory
--   WheelHost.tmp.name()                    unique path inside that directory
--   WheelHost.tmp.create(content)           exclusive 0600 file, returns path
--   WheelHost.tmp.create_exclusive(path, content)
--                                           exclusive 0600 file at a given path
--   WheelHost.time.now()                    wall-clock seconds
--   WheelHost.time.clock()                  CPU seconds
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
-- PID/PGID, then executes the scrubbed command under GNU `timeout` (or
-- `gtimeout`). On expiry timeout signals the command group and a bounded
-- kill-after escalates to SIGKILL. After the direct command exits for any
-- reason, the supervisor terminates any remaining members of the recorded PGID
-- with TERM and a bounded KILL, then preserves the direct command's status; a
-- child that calls `setsid` on its own can still escape. stdout and stderr are
-- redirected to private 0600 files and read back through a fixed cap
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
-- Process result shape: every `proc.*` primitive returns
-- { ok, code, exit_code, stdout, stderr, timed_out, truncated,
--   stdout_truncated, stderr_truncated, outcome } where `ok` reports that the
-- execution was launched by the backend (a nonzero `code` still has ok = true;
-- a timeout is a launched process), `code`/`exit_code` carry the POSIX exit
-- status recorded by the wrapper, and `outcome` is one of
-- `WheelHost.PROCESS_OUTCOME` (`exited`, `timeout`, `unavailable`, `failure`).
-- GNU timeout maps expiry to 124 and kill-after escalation to 137; a command
-- that itself exits 124/137 is indistinguishable and is reported as a timeout.
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
-- These are policy bounds, not suggestions. Every child process runs with one
-- explicit wall-clock timeout, and each stream is captured to a private file
-- and read back through a fixed byte cap, so a runaway child cannot exhaust
-- harness memory. Timeout enforcement is delegated to GNU `timeout` (coreutils
-- or `gtimeout`): it creates the child process group, records it, and signals
-- only that group on expiry. The harness never sends a name- or pattern-based
-- kill.

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

--- Grace period for the post-exit group sweep (TERM, then KILL).
local SWEEP_GRACE_MS = 250

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
  UNAVAILABLE = "unavailable",
  FAILURE = "failure",
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
}

--- Post-exit supervisor. It runs `setsid -w <leader>` (the leader is the
--- session/PGID leader), preserves the command status, then terminates any
--- remaining members of the recorded PGID with TERM and a bounded KILL. It never
--- uses a name or pattern; `$pgid` is validated as a numeric PGID greater than 1.
local SUPERVISOR_SCRIPT = 'pgid_file="$1"; grace="$2"; sleep_bin="$3"; shift 3; "$@"; status=$?; if [ -s "$pgid_file" ] && [ -f "$pgid_file" ] && [ ! -L "$pgid_file" ] && [ "$(stat -c \'%u %a %h\' -- "$pgid_file" 2>/dev/null)" = "$(id -u) 600 1" ]; then read -r pgid < "$pgid_file" || pgid=""; case "$pgid" in ""|*[!0-9]*) : ;; *) if [ "$pgid" -gt 1 ] && kill -0 -"$pgid" 2>/dev/null; then kill -TERM -"$pgid" 2>/dev/null || :; if kill -0 -"$pgid" 2>/dev/null; then "$sleep_bin" "$grace" 2>/dev/null || :; kill -KILL -"$pgid" 2>/dev/null || :; fi; fi ;; esac; fi; exit "$status"'

--- Session leader. It records its own PID/PGID in the exclusive file created
--- by the host, then replaces itself with the scrubbed command chain. No caller
--- value is interpolated into this script.
local LEADER_SCRIPT = 'pgid_file="$1"; shift; printf "%s\n" "$$" > "$pgid_file" || exit 125; exec "$@"'

--- Normalize an os.execute result into a POSIX exit status.
-- Lua 5.1 reports the raw wait status (exit 1 -> 256); 5.2+ reports the exit
-- code in the second result. Both shapes become a plain integer.
-- @param ok boolean|number|nil
-- @param code number|nil
-- @return number
local function normalized_exit_status(ok, code)
  if ok == true then
    return 0
  end
  if type(ok) == "number" then
    if ok >= 256 then
      return math.floor(ok / 256)
    end
    return ok
  end
  if type(code) == "number" then
    return code
  end
  return 1
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
  if info.mode ~= 384 then
    return false, "private path is not mode 0600"
  end
  if info.links ~= 1 then
    return false, "private path has an unexpected hard-link count"
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
-- calls. Trailing separators and `/.` segments are stripped so `test -L` sees
-- the harness-owned directory itself rather than a path that follows a link.
-- @param path string
-- @return string
local function normalize_tmp_dir(path)
  if type(path) ~= "string" then
    return path
  end
  local normalized = path
  while true do
    local next_path = normalized:gsub("/+$", "")
    next_path = next_path:gsub("/%.$", "")
    if next_path == normalized then
      break
    end
    normalized = next_path
  end
  if normalized == "" then
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
  -- `test` probes type and link status; `stat` supplies owner and mode when
  -- the platform provides it. A missing path returns exists = false without an
  -- error. A probe that cannot run fails closed with the typed denial, so an
  -- unavailable `test` is never read as "not a symlink" or "not a file".
  -- @param path string
  -- @return table { exists, symlink, regular, directory, uid?, mode? }
  function backend.stat(path)
    require_surface(type(os) == "table" and type(os.execute) == "function", "fs.read")

    local target = path
    if target:sub(1, 1) ~= "/" and target:sub(1, 1) ~= "." then
      target = "./" .. target
    end

    local function probe(flag)
      local ok, _, code = os.execute("test " .. flag .. " " .. shell_quote(target))
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
      error(WheelErrors.capability_denied("fs.read"), 0)
    end

    local symlink = probe("-L")
    local regular = probe("-f")
    local directory = probe("-d")
    local exists = regular or directory or symlink or probe("-e")

    local uid, mode
    local formats = {
      { "-c", "%u %a" },
      { "-f", "%u %Lp" },
    }
    for _, format in ipairs(formats) do
      local res = backend.run_program("stat", { format[1], format[2], "--", target },
        { discard_stderr = true })
      if res.ok and res.code == 0 then
        local owner, permissions = (res.stdout or ""):match("^%s*(%d+)%s+([0-7]+)")
        if owner and permissions then
          uid = tonumber(owner)
          mode = tonumber(permissions, 8)
          break
        end
      end
    end

    return {
      exists = exists,
      symlink = symlink,
      regular = regular,
      directory = directory,
      uid = uid,
      mode = mode,
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

  --- Execute one bounded child process and normalize its result.
  -- @param mode string "argv" or "shell"
  -- @param payload string program name or shell string
  -- @param payload_args string[]? argv elements for mode "argv"
  -- @param opts table?
  -- @return table process result
  local function execute_process(mode, payload, payload_args, opts)
    require_surface(type(io) == "table" and type(io.popen) == "function", "process.spawn")
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
      return process_failure(string.format(
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
      return process_failure("max_output_bytes must be an integer between 1 and "
        .. MAX_CAPTURE_BYTES)
    end

    local stdin_data = opts.stdin
    if stdin_data ~= nil then
      if type(stdin_data) ~= "string" then
        return process_failure("stdin must be a string")
      end
      if #stdin_data > MAX_STDIN_BYTES then
        return process_failure("stdin exceeds the " .. MAX_STDIN_BYTES .. " byte bound")
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
        return process_failure("cwd must be a control-free absolute or relative path")
      end
    end

    local env_parts, env_err, env_outcome =
      build_child_environment(os.getenv, opts.env)
    if not env_parts then
      return process_failure(env_err, env_outcome)
    end

    local env_bin = resolve_tool("env")
    if not env_bin then
      return process_failure(
        "the 'env' utility is unavailable; refusing to inherit the parent environment",
        WheelHost.PROCESS_OUTCOME.UNAVAILABLE)
    end
    local timeout_bin = resolve_timeout_tool()
    if not timeout_bin then
      return process_failure(
        "GNU 'timeout' is unavailable; refusing to run an unbounded process",
        WheelHost.PROCESS_OUTCOME.UNAVAILABLE)
    end
    local sh_bin = resolve_tool("sh")
    if not sh_bin then
      return process_failure("the POSIX 'sh' is unavailable",
        WheelHost.PROCESS_OUTCOME.UNAVAILABLE)
    end
    local setsid_bin = resolve_tool("setsid")
    if not setsid_bin then
      return process_failure(
        "the 'setsid' utility is unavailable; refusing to run without a recorded process group",
        WheelHost.PROCESS_OUTCOME.UNAVAILABLE)
    end
    local sleep_bin = resolve_tool("sleep")
    if not sleep_bin then
      return process_failure(
        "the 'sleep' utility is unavailable; cannot bound the process-group sweep",
        WheelHost.PROCESS_OUTCOME.UNAVAILABLE)
    end
    for _, required in ipairs({ "mktemp", "stat", "id" }) do
      if not resolve_tool(required) then
        return process_failure(
          "the '" .. required .. "' utility is unavailable; cannot validate private files",
          WheelHost.PROCESS_OUTCOME.UNAVAILABLE)
      end
    end

    local created = {}
    local function fresh_temp()
      local dir_ok, dir = pcall(backend.tmp_dir)
      if not dir_ok then
        return nil
      end
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

    local out_path = fresh_temp()
    local err_path = fresh_temp()
    local status_path = fresh_temp()
    local pgid_path = fresh_temp()
    local stdin_path
    if out_path and err_path and status_path and pgid_path then
      if stdin_data ~= nil then
        stdin_path = fresh_temp()
      end
    end
    if (not out_path) or (not err_path) or (not status_path) or (not pgid_path)
      or (stdin_data ~= nil and not stdin_path) then
      local errors = cleanup()
      local message = "cannot create private process-capture files"
      if #errors > 0 then
        message = message .. "; cleanup failed: " .. table.concat(errors, "; ")
      end
      return process_failure(message)
    end

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

    -- A constant wrapper: `$0` is `wheel-exec`, `$1` is the stdin path, and the
    -- remaining positional arguments are either the argv vector or
    -- `sh -c <shell string>` after the shifts. No caller value is interpolated
    -- into the script text. `--` stops env option parsing, and a program name
    -- that starts with `-` or contains `=` is refused so env cannot treat it as
    -- an option or environment assignment.
    local script
    local launch_args
    if mode == "argv" then
      if cwd then
        script = 'stdin="$1"; envbin="$2"; cwd="$3"; shift 3; case "$cwd" in -*) exit 126;; esac; case "$1" in ""|-*|*=*) exit 126;; esac; cd "$cwd" || exit 126; exec "$envbin" -u SHLVL -u PWD -u _ -- "$@" < "$stdin"'
        launch_args = { stdin_path, env_bin, cwd, payload }
      else
        script = 'stdin="$1"; envbin="$2"; shift 2; case "$1" in ""|-*|*=*) exit 126;; esac; exec "$envbin" -u SHLVL -u PWD -u _ -- "$@" < "$stdin"'
        launch_args = { stdin_path, env_bin, payload }
      end
      for _, arg in ipairs(payload_args or {}) do
        launch_args[#launch_args + 1] = arg
      end
    else
      if cwd then
        script = 'stdin="$1"; envbin="$2"; cwd="$3"; shift 3; case "$cwd" in -*) exit 126;; esac; case "$1" in ""|-*|*=*) exit 126;; esac; cd "$cwd" || exit 126; exec "$envbin" -u SHLVL -u PWD -u _ -- "$@" < "$stdin"'
        launch_args = { stdin_path, env_bin, cwd, sh_bin, "-c", payload }
      else
        script = 'stdin="$1"; envbin="$2"; shift 2; case "$1" in ""|-*|*=*) exit 126;; esac; exec "$envbin" -u SHLVL -u PWD -u _ -- "$@" < "$stdin"'
        launch_args = { stdin_path, env_bin, sh_bin, "-c", payload }
      end
    end

    local kill_after_ms = math.min(KILL_AFTER_MS, timeout_ms)
    local pieces = {
      shell_quote(sh_bin), "-c", shell_quote(SUPERVISOR_SCRIPT),
      shell_quote("wheel-supervisor"),
      shell_quote(pgid_path), shell_quote(format_sleep(SWEEP_GRACE_MS)),
      shell_quote(sleep_bin),
      shell_quote(setsid_bin), "-w",
      shell_quote(sh_bin), "-c", shell_quote(LEADER_SCRIPT),
      shell_quote("wheel-leader"),
      shell_quote(pgid_path),
      shell_quote(env_bin), "-i",
    }
    for _, assignment in ipairs(env_parts) do
      pieces[#pieces + 1] = shell_quote(assignment)
    end
    pieces[#pieces + 1] = shell_quote(timeout_bin)
    pieces[#pieces + 1] = "-k"
    pieces[#pieces + 1] = format_seconds(kill_after_ms)
    pieces[#pieces + 1] = format_seconds(timeout_ms)
    pieces[#pieces + 1] = shell_quote(sh_bin)
    pieces[#pieces + 1] = "-c"
    pieces[#pieces + 1] = shell_quote(script)
    pieces[#pieces + 1] = shell_quote("wheel-exec")
    for _, arg in ipairs(launch_args) do
      pieces[#pieces + 1] = shell_quote(arg)
    end

    local command = table.concat(pieces, " ")
      .. " > " .. shell_quote(out_path)
      .. " 2> " .. shell_quote(err_path)
      .. "; printf '%s' \"$?\" > " .. shell_quote(status_path)

    local pipe = io.popen(command, "r")
    if not pipe then
      local errors = cleanup()
      local message = "Failed to spawn the bounded process wrapper"
      if #errors > 0 then
        message = message .. "; cleanup failed: " .. table.concat(errors, "; ")
      end
      return process_failure(message)
    end
    pipe:read("*a")
    pipe:close()

    local status_raw = backend.read_file_bounded(status_path, 32) or ""
    local code = tonumber(status_raw:match("^%s*(%d+)%s*$"))
    local out_raw = backend.read_file_bounded(out_path, capture_cap + 1) or ""
    local err_raw = backend.read_file_bounded(err_path, capture_cap + 1) or ""
    local cleanup_errors = cleanup()

    if code == nil then
      local message = "the process wrapper did not report an exit status"
      if err_raw ~= "" then
        message = message .. ": " .. err_raw:sub(1, 512)
      end
      if #cleanup_errors > 0 then
        message = message .. "; cleanup failed: " .. table.concat(cleanup_errors, "; ")
      end
      return process_failure(message)
    end

    local timed_out = code == 124 or code == 137
    local outcome = timed_out
      and WheelHost.PROCESS_OUTCOME.TIMEOUT
      or WheelHost.PROCESS_OUTCOME.EXITED
    local ok = true
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

    return {
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
    }
  end

  --- Execute a shell command line inside the bounded, scrubbed process
  -- primitive. This is the explicit shell-string surface for Execute-intent
  -- tools; argv call sites use `run_program`.
  -- The command runs in a `setsid`-recorded process group under GNU `timeout`.
  -- Timeout expiry signals the group and a bounded kill-after escalates to
  -- SIGKILL; after any direct-command exit the supervisor sweeps remaining
  -- members of the recorded PGID with TERM/KILL and preserves the command
  -- status. stdout and stderr are redirected to private 0600 files and read
  -- back at most `opts.max_output_bytes` (default 256 KiB) so a runaway child
  -- cannot exhaust harness memory. The child environment is rebuilt from the
  -- allowlist; stdin is `/dev/null` unless `opts.stdin` supplies bytes.
  --
  -- Result: `ok` reports a launched process (a timeout is still launched),
  -- `code`/`exit_code` carry the shell status (124/137 map to timeout),
  -- `timed_out`, `truncated`, `stdout_truncated`, `stderr_truncated`, and
  -- `outcome` (exited|timeout|unavailable|failure) are explicit.
  -- @param shell_string string
  -- @param opts table? { timeout_ms, max_output_bytes, stdin, cwd, merge_stderr,
  --                         discard_stderr, env }
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
  --                      discard_stderr, env }
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

  --- Quote one POSIX shell argument for the explicit shell-string primitive.
  -- @param value string
  -- @return string
  function backend.shell_quote(value)
    return shell_quote(value)
  end

  --- Resolve, create, and repair the private temporary directory.
  -- The path is normalized (trailing `/`, `/.` stripped) before inspection.
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
      os.remove(path)
      return nil, write_err
    end
    return path
  end

  --- Wall-clock time in seconds since the epoch (os.time semantics).
  -- @return number
  function backend.now()
    require_surface(type(os) == "table" and type(os.time) == "function", "time.now")
    return os.time()
  end

  --- CPU time in seconds (os.clock semantics).
  -- @return number
  function backend.clock()
    require_surface(type(os) == "table" and type(os.clock) == "function", "time.clock")
    return os.clock()
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
-- @return table { exists, symlink, regular, directory, uid?, mode? }
function WheelHost.fs.stat(path)
  return invoke("fs.read", "stat", path)
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
  }
end

--- Execute a shell command line inside the bounded, scrubbed process
-- primitive. This is the explicit shell-string surface for Execute-intent
-- tools; argv call sites use `run_program`.
-- With `env.command_runner` set (the existing tool injection seam), the runner
-- is invoked with { command = shell_string } and its tool-shaped result is
-- normalized; otherwise the backend runs the command under the setsid-recorded
-- process group, timeout, post-exit group sweep, output cap, and environment
-- allowlist.
-- @param shell_string string
-- @param env table? { command_runner = function? }
-- @param opts table? { timeout_ms, max_output_bytes, stdin, cwd, env }
-- @return table process result
function WheelHost.proc.run_command(shell_string, env, opts)
  if env and type(env.command_runner) == "function" then
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
--                      discard_stderr, env }
-- @return table process result
function WheelHost.proc.run_program(program, args, opts)
  return invoke("process.spawn", "run_program", program, args, opts)
end

--- Quote one POSIX shell argument for an explicit shell-string call site.
-- @param value string
-- @return string
function WheelHost.proc.shell_quote(value)
  return invoke("process.spawn", "shell_quote", value)
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

return WheelHost
