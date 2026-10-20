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
--   WheelHost.fs.write_file(path, content)  write a whole file
--   WheelHost.fs.remove_file(path)          remove a file
--   WheelHost.fs.exists(path)               test for a readable file
--   WheelHost.proc.run_command(shell_string, env?)  run a shell command line
--   WheelHost.proc.run_program(program, args)       run argv with each element
--                                                   single-quoted for the
--                                                   standalone POSIX shell
--   WheelHost.proc.shell_quote(value)       quote one POSIX shell argument
--   WheelHost.tmp.dir()                     private runtime directory
--   WheelHost.tmp.name()                    unique path inside that directory
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
-- `io.popen`, `os.remove`, `os.execute`, `os.time`, and `os.clock`, preserving
-- the exact behavior the call sites had before this seam existed. The command
-- string passed to `proc.run_command` is the explicit shell-string primitive
-- used by Execute-intent tools; inspect-intent call sites use `run_program`,
-- which quotes each argv element and executes the joined command through the
-- standalone POSIX shell. No call site builds an unquoted shell string.
-- `WheelHost.backend` is the documented swap point for tests and for any
-- future in-process backend; call sites never touch it directly.
--
-- Temporary files:
-- `WheelHost.tmp.name()` never uses the ambient temporary-name API. It returns
-- a unique path inside a private directory: `$XDG_RUNTIME_DIR/wheel` when the
-- runtime directory is set, otherwise `$XDG_STATE_HOME/wheel/tmp`, otherwise
-- `$HOME/.local/state/wheel/tmp`. The directory is created (or repaired) with
-- mode 0700 before a path is returned, and callers remove the file when the
-- job closes. A caller may inject an explicit `tmp_root` (for example a
-- workspace-local `.wheel/tmp`) through the backend options.
--
-- Process result shape: every `proc.*` primitive returns
-- { ok, code, stdout, stderr } where `ok` reports that the execution was
-- launched by the backend (a nonzero `code` still has ok = true) and `code`
-- carries the POSIX exit status, or 1 when the execution could not be
-- launched. On Lua 5.1 / LuaJIT the popen status is not observable and
-- launched commands report code 0, exactly as the pre-seam tool did.
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

--- Decode a popen close() result into an exit code.
-- @param ok_close boolean|number|nil
-- @param exit_code number|nil
-- @return number|nil code
local function close_exit_code(ok_close, exit_code)
  if ok_close == true or ok_close == 0 then
    return 0
  end
  if type(exit_code) == "number" then
    return exit_code
  end
  if type(ok_close) == "number" then
    return ok_close
  end
  return nil
end

--- Fail with a typed capability denial when a primitive surface is absent.
-- @param available boolean
-- @param capability string
local function require_surface(available, capability)
  if not available then
    error(WheelErrors.capability_denied(capability), 0)
  end
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
  -- POSIX shell, but no call site builds a shell string. stderr is merged so a
  -- missing directory's diagnostic remains in the entry stream, matching the
  -- pre-seam tool.
  -- @param path string
  -- @return table { ok, code, stdout, stderr, entries, total }
  function backend.list_dir(path)
    local res = backend.run_program("ls", { "-la", "--", path }, { merge_stderr = true })
    local entries = split_lines(res.stdout)
    return {
      ok = res.ok,
      code = res.code,
      stdout = res.stdout,
      stderr = res.stderr,
      entries = entries,
      total = #entries,
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
    f:write(content or "")
    f:close()
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

  --- Execute a shell command line with popen semantics (stdout captured,
  -- stderr inherited unless the command redirects it).
  -- `ok` reports that the command was spawned; `code` carries the exit status
  -- (spawn failure: ok = false, code = 1). Lua 5.1/LuaJIT close() does not
  -- expose the child status, so spawned commands report code 0 there - the
  -- exact behavior the previous run_command tool had. The fallback heuristic
  -- for interpreters that do not report a numeric status is preserved too.
  -- @param shell_string string
  -- @return table { ok = boolean, code = number, stdout = string, stderr = string }
  function backend.run_command(shell_string)
    require_surface(type(io) == "table" and type(io.popen) == "function", "process.spawn")
    local p = io.popen(shell_string, "r")
    if not p then
      return { ok = false, code = 1, stdout = "", stderr = "Failed to spawn shell process" }
    end
    local out = p:read("*a") or ""
    local ok_close, _, exit_code = p:close()
    local code = close_exit_code(ok_close, exit_code)
    if code == nil then
      code = (out:find("error") or out:find("FAILED")) and 1 or 0
    end
    return { ok = true, code = code, stdout = out, stderr = "" }
  end

  --- Execute a program with an explicit argument vector, without shell parsing
  -- in the caller. Standalone: each element is single-quoted and joined, so
  -- the POSIX shell receives the argv verbatim; delegates to run_command.
  -- `opts.merge_stderr` appends `2>&1`; `opts.discard_stderr` appends
  -- `2>/dev/null`. Both are backend-level redirections for tools that do not
  -- otherwise capture stderr.
  -- @param program string
  -- @param args string[]?
  -- @param opts table? { merge_stderr = boolean?, discard_stderr = boolean? }
  -- @return table { ok = boolean, code = number, stdout = string, stderr = string }
  function backend.run_program(program, args, opts)
    local parts = { shell_quote(program) }
    for _, arg in ipairs(args or {}) do
      table.insert(parts, shell_quote(arg))
    end
    local command = table.concat(parts, " ")
    if type(opts) == "table" then
      if opts.merge_stderr then
        command = command .. " 2>&1"
      elseif opts.discard_stderr then
        command = command .. " 2>/dev/null"
      end
    end
    return backend.run_command(command)
  end

  --- Quote one POSIX shell argument for the explicit shell-string primitive.
  -- @param value string
  -- @return string
  function backend.shell_quote(value)
    return shell_quote(value)
  end

  --- Resolve, create, and repair the private temporary directory.
  -- The path is normalized (trailing `/`, `/.` stripped) before inspection. The
  -- harness-owned directory (and the `wheel` component of the state fallback)
  -- must not be a symbolic link: `chmod` must never follow a pre-existing link.
  -- Legitimate parent links such as `/tmp` are allowed because only the
  -- harness-owned path is inspected.
  -- @return string dir
  function backend.tmp_dir()
    local dir = tmp_root
    if not dir or dir == "" then
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
    if not dir or dir == "" then
      error(WheelErrors.capability_denied("fs.write"), 0)
    end
    dir = normalize_tmp_dir(dir)

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
  -- The file is not created; the caller owns creation and cleanup. Uniqueness
  -- is process-local: the backend instance token plus a monotonic sequence
  -- cannot repeat within this process. The token is not a cross-process
  -- uniqueness guarantee; exclusive `0600` creation remains CTX-0016 work. No
  -- wall-clock read is involved, so a missing `os.time` cannot produce a silent
  -- "0" fallback.
  -- @return string
  function backend.tmp_path()
    local dir = backend.tmp_dir()
    tmp_sequence = tmp_sequence + 1
    return string.format("%s/wheel-%s-%d", dir, process_token, tmp_sequence)
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

--- Write a whole file.
-- @param path string
-- @param content string
-- @return boolean ok, string? err
function WheelHost.fs.write_file(path, content)
  return invoke("fs.write", "write_file", path, content)
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

--- Process primitives.
WheelHost.proc = {}

--- Normalize a tool-shaped command_runner result into the WheelHost proc shape.
-- @param result table? { success, exit_code, stdout, stderr }
-- @return table { ok = boolean, code = number, stdout = string, stderr = string }
local function normalize_runner_result(result)
  if type(result) ~= "table" then
    return { ok = false, code = 1, stdout = "", stderr = "command_runner returned no result" }
  end
  local code = result.exit_code
  if type(code) ~= "number" then
    code = (result.success ~= false) and 0 or 1
  end
  return { ok = true, code = code, stdout = result.stdout or "", stderr = result.stderr or "" }
end

--- Execute a shell command line.
-- With `env.command_runner` set (the existing tool injection seam), the runner
-- is invoked with { command = shell_string } and its tool-shaped result is
-- normalized; otherwise the backend runs the command line as-is. On spawn
-- failure ok = false, code = 1, and stderr carries the reason.
-- @param shell_string string
-- @param env table? { command_runner = function? }
-- @return table { ok = boolean, code = number, stdout = string, stderr = string }
function WheelHost.proc.run_command(shell_string, env)
  if env and type(env.command_runner) == "function" then
    return normalize_runner_result(env.command_runner({ command = shell_string }, env))
  end
  return invoke("process.spawn", "run_command", shell_string)
end

--- Execute a program with an explicit argument vector (no unquoted shell
-- string at the call site). The standalone backend joins the single-quoted
-- elements and executes the command through the POSIX shell.
-- The command_runner override applies to shell-string execution only, so it is
-- not consulted here.
-- @param program string
-- @param args string[]?
-- @param opts table? { merge_stderr = boolean?, discard_stderr = boolean? }
-- @return table { ok = boolean, code = number, stdout = string, stderr = string }
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
