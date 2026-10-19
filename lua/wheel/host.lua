-- lua/wheel/host.lua
-- Wheel: Host-Capability Seam (filesystem / process / tmp / time)
--
-- Pure Lua 5.1 / LuaJIT implementation with zero external C dependencies.
--
-- WheelHost is the single seam between the Wheel harness and the machine it
-- runs on. The migration is complete: filesystem, process, temporary-file, and
-- wall-clock primitives are expressed here, and no `lua/wheel` call site invokes
-- `os.execute`, `io.popen`, `os.tmpname`, or `os.time` directly. The standalone
-- backend below is the only place those four primitives appear; direct
-- `io.open` / `os.remove` / `os.clock` use outside this module is deliberately
-- out of scope:
--
--   WheelHost.fs.mkdir_p(path)              create a directory tree
--   WheelHost.fs.list_dir(path)             list directory entries
--   WheelHost.fs.read_file(path)            read a whole file
--   WheelHost.fs.write_file(path, content)  write a whole file
--   WheelHost.proc.run_command(shell_string, env?)  run a shell command line
--   WheelHost.proc.run_program(program, args)       run argv without a shell
--   WheelHost.tmp.name()                    temporary file name
--   WheelHost.time.now()                    wall-clock seconds
--
-- Standalone backend (the swap point):
-- The default `WheelHost.backend` table executes against the local POSIX host
-- with os.execute / io.popen / os.tmpname / os.time, preserving the exact
-- behavior the call sites had before this seam existed. A future Bitty host
-- integration replaces that table alone: the sandbox denies `io` and `os`, so
-- the adapter maps the same primitives onto the host ABI - filesystem
-- capabilities for `fs.*` and an argv-only `process.spawn:<tool>` for
-- `proc.run_program` (shell interpreters are prohibited on the host, so
-- `proc.run_command` is a standalone compatibility shim, not the portable
-- entry point). Call sites use the WheelHost.* wrappers only and never touch
-- `WheelHost.backend` directly, so swapping the backend adapts the whole
-- harness at once.
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
-- Standalone POSIX backend (the documented swap point)
-- ---------------------------------------------------------------------------

--- Standalone POSIX backend: the exact local behavior behind the seam.
-- A Bitty host adapter replaces this whole table (WheelHost.backend); the
-- WheelHost.fs / .proc / .tmp / .time wrappers stay untouched.
local standalone = {}

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

--- Fail with a typed capability denial when the standalone surface is absent.
-- @param available boolean
-- @param capability string
local function require_surface(available, capability)
  if not available then
    error(WheelErrors.capability_denied(capability), 0)
  end
end

--- Create <path> and all missing parents (POSIX `mkdir -p`).
-- Mirrors the previous per-call-site `os.execute("mkdir -p ...")`; errors are
-- suppressed on stderr like the trust-store call site did.
-- @param path string
-- @return boolean ok, number code
function standalone.mkdir_p(path)
  require_surface(type(os) == "table" and type(os.execute) == "function", "fs.write")
  local ok, _, code = os.execute("mkdir -p -- " .. shell_quote(path) .. " 2>/dev/null")
  if ok == true or ok == 0 then
    return true, 0
  end
  return false, (type(code) == "number" and code or 1)
end

--- List a directory as the raw `ls -la <path> 2>&1` lines used before the seam.
-- `ok` reports whether the listing process spawned; the POSIX exit status is
-- reported in `code`. A missing directory still spawns and returns its error
-- text through the entries, exactly like the previous popen-based tool.
-- @param path string
-- @return table { ok = boolean, code = number, stdout = string, stderr = string, entries = string[], total = number }
function standalone.list_dir(path)
  require_surface(type(io) == "table" and type(io.popen) == "function", "fs.read")
  local cmd = string.format("ls -la %q 2>&1", path)
  local p = io.popen(cmd, "r")
  if not p then
    return {
      ok = false,
      code = 1,
      stdout = "",
      stderr = "Failed to spawn directory listing process",
      entries = {},
      total = 0,
    }
  end
  local out = p:read("*a") or ""
  local ok_close, _, exit_code = p:close()
  local code = close_exit_code(ok_close, exit_code)
  if code == nil then
    code = 0
  end
  local entries = split_lines(out)
  return {
    ok = true,
    code = code,
    stdout = out,
    stderr = "",
    entries = entries,
    total = #entries,
  }
end

--- Read the whole file at <path>.
-- @param path string
-- @return string? content, string? err
function standalone.read_file(path)
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
function standalone.write_file(path, content)
  require_surface(type(io) == "table" and type(io.open) == "function", "fs.write")
  local f, err = io.open(path, "w")
  if not f then
    return false, tostring(err)
  end
  f:write(content or "")
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
function standalone.run_command(shell_string)
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

--- Execute a program with an explicit argument vector, without shell parsing.
-- Standalone: each element is single-quoted and joined, so the shell receives
-- the argv verbatim; delegates to standalone.run_command. The future Bitty
-- host ABI is argv-only (`process.spawn:<tool>`; shell interpreters are
-- prohibited), so hosts map this primitive directly.
-- @param program string
-- @param args string[]?
-- @return table { ok = boolean, code = number, stdout = string, stderr = string }
function standalone.run_program(program, args)
  local parts = { shell_quote(program) }
  for _, arg in ipairs(args or {}) do
    table.insert(parts, shell_quote(arg))
  end
  return standalone.run_command(table.concat(parts, " "))
end

--- Return a temporary file name (os.tmpname semantics: the file is not
-- created; the caller owns creation and cleanup).
-- @return string
function standalone.tmpname()
  require_surface(type(os) == "table" and type(os.tmpname) == "function", "fs.write")
  return os.tmpname()
end

--- Wall-clock time in seconds since the epoch (os.time semantics).
-- @return number
function standalone.now()
  return os.time()
end

-- ---------------------------------------------------------------------------
-- Public seam (call sites use only these)
-- ---------------------------------------------------------------------------

--- Backend in use. A host adapter replaces this table wholesale; tests swap
-- individual entries to capture call sites.
WheelHost.backend = standalone

--- Filesystem primitives.
WheelHost.fs = {}

--- Create a directory tree (all missing parents).
-- @param path string
-- @return boolean ok, number code
function WheelHost.fs.mkdir_p(path)
  return WheelHost.backend.mkdir_p(path)
end

--- List directory entries.
-- @param path string
-- @return table { ok, code, stdout, stderr, entries, total }
function WheelHost.fs.list_dir(path)
  return WheelHost.backend.list_dir(path)
end

--- Read a whole file.
-- @param path string
-- @return string? content, string? err
function WheelHost.fs.read_file(path)
  return WheelHost.backend.read_file(path)
end

--- Write a whole file.
-- @param path string
-- @param content string
-- @return boolean ok, string? err
function WheelHost.fs.write_file(path, content)
  return WheelHost.backend.write_file(path, content)
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
  return WheelHost.backend.run_command(shell_string)
end

--- Execute a program with an explicit argument vector (no shell parsing).
-- The future host ABI is argv-only (`process.spawn:<tool>`); this is the
-- portable entry point. The command_runner override applies to shell-string
-- execution only, so it is not consulted here.
-- @param program string
-- @param args string[]?
-- @return table { ok = boolean, code = number, stdout = string, stderr = string }
function WheelHost.proc.run_program(program, args)
  return WheelHost.backend.run_program(program, args)
end

--- Temporary-file primitives.
WheelHost.tmp = {}

--- Return a temporary file name (the file is not created).
-- @return string
function WheelHost.tmp.name()
  return WheelHost.backend.tmpname()
end

--- Wall-clock primitives.
WheelHost.time = {}

--- Wall-clock time in seconds since the epoch.
-- @return number
function WheelHost.time.now()
  return WheelHost.backend.now()
end

return WheelHost
