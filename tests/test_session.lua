-- Integration tests for the experimental Wheel session daemon.
--
-- These tests start a real detached daemon in a temporary runtime root and
-- drive it through `scripts/wheel-session`, so every context update and read
-- crosses a separate client process. They also exercise the raw FIFO protocol
-- for malformed, oversized, and unauthenticated frames.
--
-- The suite records every daemon pid it starts and only ever signals that
-- recorded pid in the stale-daemon test. It never uses a name- or pattern-based
-- kill.

package.path = "./lua/?.lua;./lua/?/init.lua;" .. package.path

local WheelHost = require("wheel.host")
local Session = require("wheel.session")
local Daemon = require("wheel.daemon")

local script_path = type(arg) == "table" and arg[0] or "tests/test_session.lua"
local repo_root = script_path:match("^(.*)/tests/[^/]+$") or "."
local cli_path = repo_root .. "/scripts/wheel-session"

local test_base = (os.getenv("TMPDIR") or "/tmp")
  .. "/bitty/wheel-session-test-"
  .. tostring(WheelHost.proc.pid() or 0)
  .. "-"
  .. tostring(os.time())
local session_root = test_base .. "/sessions"
local started_sessions = {}
local cleanup

local function run_test(name, fn)
  local ok, err = pcall(fn)
  if ok then
    print("[PASS] " .. name)
  else
    print("[FAIL] " .. name .. ": " .. tostring(err))
    if cleanup then
      cleanup()
    end
    os.exit(1)
  end
end

local function shell_quote(value)
  return WheelHost.proc.shell_quote(value)
end

local function remove_tree(path)
  os.execute("rm -rf -- " .. shell_quote(path))
end

local function cli(args, opts)
  opts = opts or {}
  local argv = { cli_path }
  for _, value in ipairs(args) do
    argv[#argv + 1] = value
  end
  return WheelHost.proc.run_program("bash", argv, {
    stdin = opts.stdin,
    timeout_ms = 30000,
    env = { WHEEL_SESSION_ROOT = opts.root or session_root },
  })
end

--- Run the CLI from the test's own shell, not the host process supervisor.
-- `start` deliberately spawns the daemon with setsid; a supervisor group sweep
-- can race that detach when the CLI itself is a supervised child, so the
-- late-publication test uses the real user-facing shell path.
local function cli_direct(args, opts)
  opts = opts or {}
  local output_path = test_base .. "/cli.out"
  local error_path = test_base .. "/cli.err"
  local words = {
    "WHEEL_SESSION_ROOT=" .. shell_quote(opts.root or session_root),
    shell_quote(cli_path),
  }
  for _, value in ipairs(args) do
    words[#words + 1] = shell_quote(value)
  end
  words[#words + 1] = ">" .. shell_quote(output_path)
  words[#words + 1] = "2>" .. shell_quote(error_path)
  local status = os.execute(table.concat(words, " "))
  local output = WheelHost.fs.read_file(output_path) or ""
  local error_output = WheelHost.fs.read_file(error_path) or ""
  return status == true or status == 0, output, error_output
end

local function expect_ok(label, args, opts)
  local result = cli(args, opts)
  assert(result.ok == true, label .. ": launch failed: " .. tostring(result.stderr))
  assert(result.code == 0,
    label .. ": exit " .. tostring(result.code) .. ": " .. tostring(result.stderr))
  return result.stdout
end

local function expect_error(label, expected_code, args, opts)
  local result = cli(args, opts)
  assert(result.ok == true, label .. ": launch failed: " .. tostring(result.stderr))
  assert(result.code ~= 0, label .. ": expected a nonzero exit, got 0: " .. tostring(result.stdout))
  local decoded_ok, decoded = pcall(Session.json_decode, result.stderr)
  assert(decoded_ok and type(decoded) == "table" and decoded.ok == false,
    label .. ": stderr is not a session error: " .. tostring(result.stderr))
  assert(decoded.error and decoded.error.code == expected_code,
    label .. ": expected " .. expected_code .. ", got " .. tostring(decoded.error and decoded.error.code)
      .. " (" .. tostring(result.stderr) .. ")")
  return result
end

local function decode_stdout(label, output)
  local ok, decoded = pcall(Session.json_decode, output)
  assert(ok and type(decoded) == "table", label .. ": stdout is not JSON: " .. tostring(output))
  return decoded
end

local function session_dir(name)
  return session_root .. "/" .. name
end

local function read_meta(name)
  local meta, err = Session.read_metadata(session_dir(name), name)
  assert(meta, "metadata must be readable: " .. tostring(err and err.message))
  return meta
end

local function raw_exchange(name, line)
  local dir = session_dir(name)
  local request, request_err = WheelHost.fs.open_fifo(dir .. "/" .. Session.FILE_REQUEST)
  assert(request, "request FIFO must open: " .. tostring(request_err))
  local response, response_err = WheelHost.fs.open_fifo(dir .. "/" .. Session.FILE_RESPONSE)
  assert(response, "response FIFO must open: " .. tostring(response_err))
  local wrote = request:write(line .. "\n")
  assert(wrote, "raw frame write must succeed")
  request:flush()
  local reply = response:read("*l")
  request:close()
  response:close()
  assert(type(reply) == "string", "raw frame must receive a response")
  return decode_stdout("raw response", reply)
end

local function wait_until_dead(pid)
  for _ = 1, 100 do
    local alive = WheelHost.proc.is_alive(pid)
    if not alive then
      return true
    end
    os.execute("sleep 0.02")
  end
  return false
end

local function wait_for_meta(name)
  for _ = 1, 100 do
    local meta = Session.read_metadata(session_dir(name), name)
    if meta then
      return meta
    end
    os.execute("sleep 0.02")
  end
  return nil
end

-- Isolation: the whole test tree is private and disposable.
remove_tree(test_base)
assert(WheelHost.fs.mkdir_p(test_base) == true)
assert(WheelHost.fs.chmod(test_base, "700") == true)
assert(WheelHost.fs.mkdir_p(session_root) == true)
assert(WheelHost.fs.chmod(session_root, "700") == true)

cleanup = function()
  for _, record in ipairs(started_sessions) do
    local meta_ok, meta = pcall(Session.read_metadata, session_dir(record.name), record.name)
    local alive = WheelHost.proc.is_alive(record.pid)
    if meta_ok and meta and meta.pid == record.pid and alive then
      -- The metadata still names the pid this test started. Signal only that
      -- recorded pid; never a name/pattern and never an unverified one.
      os.execute("kill -TERM " .. tostring(record.pid) .. " 2>/dev/null")
      wait_until_dead(record.pid)
    end
  end
  remove_tree(test_base)
end

-- ---------------------------------------------------------------------------
-- Unit: strict JSON codec
-- ---------------------------------------------------------------------------

run_test("Session: strict JSON round trip and bounds", function()
  local original = {
    protocol = "wheel-session/1",
    text = "line\nquote\"backslash\\nul\0tab\t",
    values = { 1, 2, 3 },
    nested = { ok = true, none = false },
  }
  local encoded = Session.json_encode(original)
  local decoded = Session.json_decode(encoded)
  assert(decoded.text == original.text, "control characters must round trip")
  assert(#decoded.values == 3 and decoded.values[3] == 3, "arrays must round trip")
  assert(decoded.nested.ok == true and decoded.nested.none == false)
  assert(Session.json_encode(Session.array()) == "[]", "an explicit empty array must encode as []")
  assert(Session.json_encode({}) == "{}", "an empty object must encode as {}")

  local rejected_trailing = pcall(Session.json_decode, '{"a":1} garbage')
  assert(rejected_trailing == false, "trailing JSON must be rejected")
  local rejected_depth = pcall(Session.json_decode, string.rep("[", 40) .. string.rep("]", 40))
  assert(rejected_depth == false, "over-deep JSON must be rejected")
  local rejected_control = pcall(Session.json_decode, '"raw\ncontrol"')
  assert(rejected_control == false, "raw control characters must be rejected")
end)

run_test("Session: session name and path validation", function()
  assert(Session.validate_name("a"))
  assert(Session.validate_name("demo-1_x"))
  assert(Session.validate_name(string.rep("a", 32)))
  assert(not Session.validate_name(string.rep("a", 33)))
  assert(not Session.validate_name("Upper"))
  assert(not Session.validate_name("../escape"))
  assert(not Session.validate_name("a/b"))
  assert(not Session.validate_name(""))

  assert(Session.validate_absolute_path("/tmp/wheel-session"))
  assert(not Session.validate_absolute_path("/"))
  assert(not Session.validate_absolute_path("relative"))
  assert(not Session.validate_absolute_path("/tmp/../etc"))
  assert(not Session.validate_absolute_path("/tmp/a\nb"))
end)

run_test("Session: write_frame rejects nil write and flush results", function()
  local function handle(write_result, flush_result)
    return {
      write = function() return write_result end,
      flush = function() return flush_result end,
    }
  end
  assert(Session.write_frame(handle(nil), "x") == false,
    "a nil write result must fail the frame")
  assert(Session.write_frame(handle(true, nil), "x") == false,
    "a nil flush result must fail the frame")
  assert(Session.write_frame(handle(true, true), "x") == true,
    "successful write and flush results must pass")
end)

run_test("Session: stale-lock reclamation is serialized", function()
  local saved = {
    euid = WheelHost.fs.euid,
    stat = WheelHost.fs.stat,
    read = WheelHost.fs.read_file_bounded,
    create = WheelHost.fs.create_private_file,
    rename = WheelHost.fs.rename,
    remove = WheelHost.fs.remove_file,
    alive = WheelHost.proc.is_alive,
  }
  local store = { ["/fake/client.lock"] = "111111\n" }
  local fixed_euid = 1000
  local ok, err = pcall(function()
    WheelHost.fs.euid = function() return fixed_euid end
    WheelHost.fs.stat = function(path)
      if store[path] == nil then
        return { exists = false }
      end
      return {
        exists = true,
        regular = true,
        symlink = false,
        uid = fixed_euid,
        mode = 384,
        links = 1,
      }
    end
    WheelHost.fs.read_file_bounded = function(path) return store[path] end
    WheelHost.fs.create_private_file = function(path, content)
      if store[path] ~= nil then
        return false, "exists"
      end
      store[path] = content
      return true
    end
    WheelHost.fs.rename = function(from, to)
      if store[from] == nil then
        return false
      end
      store[to] = store[from]
      store[from] = nil
      return true
    end
    WheelHost.fs.remove_file = function(path)
      store[path] = nil
      return true
    end
    WheelHost.proc.is_alive = function(pid)
      coroutine.yield("probe:" .. tostring(pid))
      return pid ~= 111111
    end

    local function contender(pid)
      return coroutine.create(function()
        local acquired, acquire_err = Session.acquire_lock("/fake", "client.lock", pid)
        return acquired, acquire_err
      end)
    end
    local contenders = { contender(222222), contender(333333) }
    local results = {}
    for _ = 1, 64 do
      for index, co in ipairs(contenders) do
        if coroutine.status(co) == "suspended" then
          local resume_ok, result, acquire_err = coroutine.resume(co)
          assert(resume_ok, tostring(result))
          if coroutine.status(co) == "dead" then
            results[index] = { ok = result, err = acquire_err }
          end
        end
      end
      local all_done = true
      for _, co in ipairs(contenders) do
        if coroutine.status(co) ~= "dead" then
          all_done = false
        end
      end
      if all_done then
        break
      end
    end
    assert(results[1] and results[2], "both lock contenders must finish")
    assert(not (results[1].ok and results[2].ok),
      "two contenders must not both acquire the same session lock")
    assert(results[1].ok or results[2].ok, "one contender must acquire the lock")
  end)
  WheelHost.fs.euid = saved.euid
  WheelHost.fs.stat = saved.stat
  WheelHost.fs.read_file_bounded = saved.read
  WheelHost.fs.create_private_file = saved.create
  WheelHost.fs.rename = saved.rename
  WheelHost.fs.remove_file = saved.remove
  WheelHost.proc.is_alive = saved.alive
  if not ok then
    error(err)
  end
end)

run_test("Daemon: dispatch converts a context exception into a static error", function()
  local state = {
    name = "dispatch-test",
    pid = 424242,
    started_at = 1,
    wheel_version = "0.1.0",
    requests = 0,
    context = {
      get_slot = function() error("injected context failure") end,
    },
  }
  local result, err = Daemon.dispatch(state, "context.get", { name = "scratch/value" })
  assert(result == nil, "a context exception must not produce a result")
  assert(err and err.code == "E_SESSION_CONTEXT_ERROR",
    "a context exception must become a typed session error")
  assert(err.message == "session method failed closed", "the error message must be static")
  assert(err.class == "runtime", "a context exception is a runtime failure")

  local _, args_err = Daemon.dispatch(state, "context.get", {})
  assert(args_err and args_err.code == "E_SESSION_ARGS_INVALID")
  assert(args_err.class == "validation", "daemon argument errors must keep the validation class")

  local _, unknown_err = Daemon.dispatch(state, "bogus.method", {})
  assert(unknown_err and unknown_err.code == "E_SESSION_METHOD_UNKNOWN")
  assert(unknown_err.class == "validation", "daemon unknown-method errors must keep the validation class")
end)

run_test("Daemon: cleanup leaves files while another starter owns the start lock", function()
  local name = "cleanup-lock"
  local dir = session_dir(name)
  local meta_pid = 424242
  assert(WheelHost.fs.mkdir_p(dir) == true)
  assert(WheelHost.fs.chmod(dir, "700") == true)
  assert(Session.write_metadata(dir, {
    protocol = Session.PROTOCOL,
    name = name,
    pid = meta_pid,
    started_at = WheelHost.time.now(),
    wheel_version = "0.1.0",
  }))
  assert(WheelHost.fs.mkfifo(dir .. "/" .. Session.FILE_REQUEST) == true)
  assert(WheelHost.fs.mkfifo(dir .. "/" .. Session.FILE_RESPONSE) == true)
  local dead_pid = 2147483647
  assert(WheelHost.fs.create_private_file(dir .. "/" .. Session.FILE_CLIENT_LOCK,
    tostring(dead_pid) .. "\n"))
  assert(WheelHost.fs.create_private_file(dir .. "/" .. Session.FILE_CLIENT_LOCK .. ".mutex",
    tostring(dead_pid) .. "\n"))
  assert(WheelHost.fs.create_private_file(dir .. "/client.lock.stale.1.1",
    tostring(dead_pid) .. "\n"))
  assert(WheelHost.fs.create_private_file(dir .. "/meta.json.1.1.tmp", "temp"))

  local owner = WheelHost.proc.pid()
  assert(Session.acquire_lock(dir, Session.FILE_START_LOCK, owner) == true)
  local state = { session_dir = dir, name = name, pid = meta_pid, start_owner = nil }
  Daemon.cleanup(state)
  assert(WheelHost.fs.stat(dir .. "/" .. Session.FILE_META).exists == true,
    "cleanup must not remove metadata while a newer starter owns the start lock")
  assert(WheelHost.fs.stat(dir .. "/" .. Session.FILE_REQUEST).exists == true,
    "cleanup must not remove FIFOs while a newer starter owns the start lock")
  assert(WheelHost.fs.stat(dir .. "/" .. Session.FILE_CLIENT_LOCK).exists == true,
    "cleanup must not prune while a newer starter owns the start lock")

  assert(Session.release_lock(dir, Session.FILE_START_LOCK, owner) == true)
  Daemon.cleanup(state)
  assert(WheelHost.fs.stat(dir .. "/" .. Session.FILE_META).exists == false,
    "cleanup must remove metadata once it owns the start lock")
  assert(WheelHost.fs.stat(dir .. "/" .. Session.FILE_REQUEST).exists == false)
  assert(WheelHost.fs.stat(dir .. "/" .. Session.FILE_RESPONSE).exists == false)
  assert(WheelHost.fs.stat(dir .. "/" .. Session.FILE_CLIENT_LOCK).exists == false,
    "cleanup must prune a dead client lock")
  assert(WheelHost.fs.stat(dir .. "/" .. Session.FILE_CLIENT_LOCK .. ".mutex").exists == false,
    "cleanup must prune a dead client mutex")
  assert(WheelHost.fs.stat(dir .. "/client.lock.stale.1.1").exists == false,
    "cleanup must prune stale lock tails")
  assert(WheelHost.fs.stat(dir .. "/meta.json.1.1.tmp").exists == false,
    "cleanup must prune metadata temp files")
  assert(WheelHost.fs.stat(dir).exists == false, "cleanup must remove the empty session directory")
end)

-- ---------------------------------------------------------------------------
-- Integration: lifecycle, context persistence, snapshots
-- ---------------------------------------------------------------------------

run_test("Daemon: cleanup treats its own start lock as held", function()
  local name = "cleanup-owned"
  local dir = session_dir(name)
  local owner = WheelHost.proc.pid()
  assert(WheelHost.fs.mkdir_p(dir) == true)
  assert(WheelHost.fs.chmod(dir, "700") == true)
  assert(WheelHost.fs.mkfifo(dir .. "/" .. Session.FILE_REQUEST) == true)
  assert(WheelHost.fs.mkfifo(dir .. "/" .. Session.FILE_RESPONSE) == true)
  assert(Session.acquire_lock(dir, Session.FILE_START_LOCK, owner) == true)
  local state = { session_dir = dir, name = name, pid = owner, start_owner = nil }
  Daemon.cleanup(state)
  assert(WheelHost.fs.stat(dir .. "/" .. Session.FILE_REQUEST).exists == false)
  assert(WheelHost.fs.stat(dir .. "/" .. Session.FILE_RESPONSE).exists == false)
  assert(WheelHost.fs.stat(dir).exists == false)
end)

run_test("Daemon: an injected dispatch exception is typed and shutdown still cleans up", function()
  local name = "dispatch-live"
  local owner_pid = WheelHost.proc.pid()
  local prepared, prepare_err = Session.prepare_start(name, {
    root = session_root,
    owner_pid = owner_pid,
  })
  assert(prepared, "session preparation failed: " .. tostring(prepare_err and prepare_err.message))

  local lua_root = repo_root .. "/lua"
  local driver_path = test_base .. "/injected-session-driver.lua"
  local driver = assert(io.open(driver_path, "w"))
  driver:write(string.format([[
package.path = %q .. "/?.lua;" .. %q .. "/?/init.lua;" .. package.path
local WheelContext = require("wheel.context")
local original_new = WheelContext.new
WheelContext.new = function(...)
  local context = original_new(...)
  context.get_slot = function() error("injected context failure") end
  return context
end
local Daemon = require("wheel.daemon")
os.exit(Daemon.run({
  root = arg[1],
  name = arg[2],
  wheel_version = "0.1.0",
  start_owner = tonumber(arg[3]),
}))
]], lua_root, lua_root))
  driver:close()

  local lua_bin = os.getenv("WHEEL_TEST_LUA")
    or (type(arg) == "table" and arg[-1])
    or "lua5.1"
  local driver_log = test_base .. "/injected-driver.log"
  local launch_command = table.concat({
    "setsid",
    shell_quote(lua_bin),
    shell_quote(driver_path),
    shell_quote(session_root),
    shell_quote(name),
    tostring(owner_pid),
    "< /dev/null > /dev/null 2>" .. shell_quote(driver_log) .. " &",
  }, " ")
  local launch_status = os.execute(launch_command)
  assert(launch_status == true or launch_status == 0, "the injected daemon launch failed")

  local meta = wait_for_meta(name)
  if not meta then
    local log = WheelHost.fs.read_file(driver_log) or ""
    error("the injected daemon did not publish metadata; lua="
      .. tostring(lua_bin) .. " driver_log=" .. tostring(log))
  end
  started_sessions[#started_sessions + 1] = { name = name, pid = meta.pid }

  local result, err = Session.request(name, "context.get", { name = "scratch/value" }, {
    root = session_root,
  })
  assert(result == nil, "the injected dispatch exception must not return a result")
  assert(err and err.code == "E_SESSION_CONTEXT_ERROR",
    "the daemon must return a typed error for a dispatch exception")
  assert(Session.pid_alive(meta) == true, "the daemon must remain alive after the typed error")

  local stopped = Session.shutdown(name, { root = session_root })
  assert(stopped and stopped.shutting_down == true, "the daemon must still accept shutdown")
  assert(wait_until_dead(meta.pid), "the daemon must exit after the explicit shutdown")
  assert(WheelHost.fs.stat(session_dir(name)).exists == false,
    "shutdown after a dispatch exception must remove the session directory")
end)

run_test("Daemon: a delayed old daemon loses the start-lock handoff and cannot clobber metadata", function()
  local name = "late-publication"
  local dead_owner = 2147483647
  local prepared, prepare_err = Session.prepare_start(name, {
    root = session_root,
    owner_pid = dead_owner,
  })
  assert(prepared, "late-publication preparation failed: "
    .. tostring(prepare_err and prepare_err.message))

  local lua_root = repo_root .. "/lua"
  local driver_path = test_base .. "/late-publication-driver.lua"
  local marker_path = test_base .. "/late-handoff-marker"
  local barrier_path = test_base .. "/late-handoff-barrier"
  local driver_log = test_base .. "/late-publication.log"
  local driver = assert(io.open(driver_path, "w"))
  driver:write(string.format([[
package.path = %q .. "/?.lua;" .. %q .. "/?/init.lua;" .. package.path
local WheelHost = require("wheel.host")
local Session = require("wheel.session")
local original_handoff = Session.handoff_start_lock
Session.handoff_start_lock = function(...)
  local marker = assert(io.open(%q, "w"))
  marker:write(tostring(WheelHost.proc.pid()))
  marker:close()
  for _ = 1, 1500 do
    local barrier = io.open(%q, "r")
    if barrier then
      barrier:close()
      break
    end
    os.execute("sleep 0.02")
  end
  return original_handoff(...)
end
local Daemon = require("wheel.daemon")
os.exit(Daemon.run({
  root = arg[1],
  name = arg[2],
  wheel_version = "0.1.0",
  start_owner = tonumber(arg[3]),
}))
]], lua_root, lua_root, marker_path, barrier_path))
  driver:close()

  local lua_bin = os.getenv("WHEEL_TEST_LUA")
    or (type(arg) == "table" and arg[-1])
    or "lua5.1"
  local launch_status = os.execute(table.concat({
    "setsid",
    shell_quote(lua_bin),
    shell_quote(driver_path),
    shell_quote(session_root),
    shell_quote(name),
    tostring(dead_owner),
    "< /dev/null > /dev/null 2>" .. shell_quote(driver_log) .. " &",
  }, " "))
  assert(launch_status == true or launch_status == 0, "the delayed daemon launch failed")

  local marker
  for _ = 1, 100 do
    marker = WheelHost.fs.read_file(marker_path)
    if type(marker) == "string" and marker ~= "" then
      break
    end
    os.execute("sleep 0.02")
  end
  local old_pid = tonumber(marker or "")
  assert(old_pid and old_pid > 1, "the delayed daemon did not reach the handoff barrier")
  started_sessions[#started_sessions + 1] = { name = name, pid = old_pid }

  local new_ok, new_output, new_error = cli_direct({ "start", name })
  -- Release the old handoff only after the real start has completed (or
  -- failed), so the test cannot depend on a wall-clock sleep under load.
  WheelHost.fs.create_private_file(barrier_path, "go")
  assert(new_ok, "the late start failed: " .. tostring(new_error))
  local new_meta = decode_stdout("late start", new_output)
  assert(new_meta.name == name)
  assert(new_meta.pid ~= old_pid, "the new start must publish a new daemon pid")
  started_sessions[#started_sessions + 1] = { name = name, pid = new_meta.pid }

  assert(wait_until_dead(old_pid), "the delayed old daemon must abort after losing the handoff")
  local stored = read_meta(name)
  assert(stored.pid == new_meta.pid,
    "the delayed old daemon must not overwrite the newer metadata")
  local ping = decode_stdout("late ping", expect_ok("late ping", { "ping", name }))
  assert(ping.pid == new_meta.pid, "the newer daemon must remain reachable")

  local stopped = decode_stdout("late stop", expect_ok("late stop", { "stop", name }))
  assert(stopped.shutting_down == true)
  assert(wait_until_dead(new_meta.pid))
  assert(WheelHost.fs.stat(session_dir(name)).exists == false)
end)

run_test("Session: start publishes private metadata and a live control plane", function()
  local output = expect_ok("start", { "start", "demo" })
  local meta = decode_stdout("start", output)
  assert(meta.protocol == "wheel-session/1", "start must report the protocol marker")
  assert(meta.name == "demo")
  assert(type(meta.pid) == "number" and meta.pid > 1)
  started_sessions[#started_sessions + 1] = { name = "demo", pid = meta.pid }

  local stored = read_meta("demo")
  assert(stored.pid == meta.pid, "start output must match published metadata")
  assert(stored.started_at == meta.started_at)
  assert(stored.wheel_version:match("^%d+%.%d+%.%d+$"))
  assert(type(stored.start_owner) == "number", "metadata must bind the starter pid")
  local inspected, inspected_alive, inspect_err = Session.inspect("demo", {
    root = session_root,
    start_owner = stored.start_owner,
  })
  assert(inspected and inspected_alive == true,
    "metadata must match the recording starter: " .. tostring(inspect_err and inspect_err.message))
  local mismatched, _, mismatch_err = Session.inspect("demo", {
    root = session_root,
    start_owner = stored.start_owner + 1,
  })
  assert(mismatched == nil and mismatch_err and mismatch_err.code == "E_SESSION_START_MISMATCH",
    "a metadata record from another starter must be rejected")

  local dir_info = WheelHost.fs.stat(session_dir("demo"))
  assert(dir_info.directory and not dir_info.symlink and dir_info.mode == 448,
    "session directory must be an owned 0700 directory")
  local meta_info = WheelHost.fs.stat(session_dir("demo") .. "/" .. Session.FILE_META)
  assert(meta_info.regular and not meta_info.symlink and meta_info.mode == 384,
    "metadata must be an owned 0600 regular file")
  for _, fifo in ipairs({ Session.FILE_REQUEST, Session.FILE_RESPONSE }) do
    local info = WheelHost.fs.stat(session_dir("demo") .. "/" .. fifo)
    assert(info.fifo and not info.symlink and info.mode == 384,
      fifo .. " must be an owned 0600 FIFO")
  end

  local ping = decode_stdout("ping", expect_ok("ping", { "ping", "demo" }))
  assert(ping.protocol == "wheel-session/1")
  assert(ping.pid == meta.pid, "ping must report the same daemon pid")
  assert(type(ping.uptime_seconds) == "number" and ping.uptime_seconds >= 0)
  assert(ping.requests >= 1)

  local status = decode_stdout("status", expect_ok("status", { "status", "demo" }))
  assert(status.protocol == "wheel-session/1")
  assert(status.name == "demo")
  assert(status.context.slot_count == 0, "a fresh daemon must start with an empty context")
  assert(type(status.context.tree_hash) == "string" and #status.context.tree_hash == 64)
end)

run_test("Session: one-session duplicate start is rejected", function()
  local before = read_meta("demo")
  expect_error("duplicate start", "E_SESSION_ALREADY_RUNNING", { "start", "demo" })
  local after = read_meta("demo")
  assert(after.pid == before.pid, "a rejected duplicate start must not replace the daemon")
  local ping = decode_stdout("ping", expect_ok("ping", { "ping", "demo" }))
  assert(ping.pid == before.pid, "the original daemon must remain responsive")
end)

local persisted_content = "line one\nline two \"quoted\" \\ backslash \0nul\ttab \226\156\147"

run_test("Session: context survives separate client processes", function()
  local put = decode_stdout("put", expect_ok("put", {
    "put", "demo", "scratch/persist",
  }, { stdin = persisted_content }))
  assert(put.success == true and put.name == "scratch/persist")
  assert(put.version == 1, "a new slot must start at version 1")
  assert(put.size_bytes == #persisted_content)

  local got = expect_ok("get", { "get", "demo", "scratch/persist" })
  assert(got == persisted_content, "a later client process must read the exact stored bytes")

  local status = decode_stdout("status", expect_ok("status", { "status", "demo" }))
  assert(status.context.slot_count == 1, "status must report the persisted slot")

  local list = decode_stdout("list", expect_ok("list", { "list", "demo", "scratch/" }))
  assert(list.total == 1 and #list.slots == 1)
  assert(list.slots[1].name == "scratch/persist")
  assert(list.slots[1].version == 1)

  local missing = decode_stdout("get", expect_ok("get", { "get", "demo", "scratch/missing" }))
  assert(missing.found == false and missing.name == "scratch/missing")
end)

run_test("Session: snapshot is bounded and carries no slot content", function()
  local secret = "TOPSECRET-snapshot-" .. tostring(os.time())
  expect_ok("put secret", { "put", "demo", "scratch/secret" }, { stdin = secret })
  local raw = expect_ok("snapshot", { "snapshot", "demo" })
  assert(not raw:find(secret, 1, true), "snapshot must never expose slot content")
  local snapshot = decode_stdout("snapshot", raw)
  assert(snapshot.protocol == "wheel-session/1")
  assert(snapshot.context.slot_count == 2)
  assert(#snapshot.context.slots == 2)
  assert(snapshot.context.truncated == false)
  for _, slot in ipairs(snapshot.context.slots) do
    assert(type(slot.name) == "string" and type(slot.hash) == "string")
    assert(slot.content == nil, "snapshot slot entries must omit content")
  end
end)

run_test("Session: content at the escaped-frame bound round trips", function()
  local content = string.rep("\0", Session.MAX_CONTEXT_CONTENT_BYTES)
  local put, put_err = Session.request("demo", "context.put", {
    name = "scratch/escaped",
    content = content,
  }, { root = session_root })
  assert(put, "content at the documented bound must fit the request frame: "
    .. tostring(put_err and put_err.code))
  assert(put.size_bytes == #content)
  local got, get_err = Session.request("demo", "context.get", {
    name = "scratch/escaped",
  }, { root = session_root })
  assert(got, "escaped content must be readable: " .. tostring(get_err and get_err.code))
  assert(got.content == content, "escaped content must round trip byte-for-byte")
end)

run_test("Session: CAS conflicts surface a typed error and keep the slot", function()
  local update = decode_stdout("update", expect_ok("put", {
    "put", "demo", "scratch/persist", "1",
  }, { stdin = "replacement" }))
  assert(update.version == 2, "an expected-version match must increment the version")

  expect_error("cas conflict", "E_SESSION_CAS_CONFLICT", {
    "put", "demo", "scratch/persist", "1",
  }, { stdin = "stale" })
  local got = expect_ok("get after conflict", { "get", "demo", "scratch/persist" })
  assert(got == "replacement", "a rejected CAS update must not change the slot")
end)

-- ---------------------------------------------------------------------------
-- Security negatives
-- ---------------------------------------------------------------------------

run_test("Session: invalid names fail closed", function()
  local invalid = {
    "../escape",
    "Upper",
    "-leading",
    "with/slash",
    string.rep("a", 33),
    "",
  }
  for _, name in ipairs(invalid) do
    expect_error("invalid name " .. name, "E_SESSION_INVALID_NAME", { "status", name })
  end
end)

run_test("Session: unsafe session paths fail closed", function()
  local outside = test_base .. "/outside"
  assert(WheelHost.fs.mkdir_p(outside) == true)
  assert(WheelHost.fs.chmod(outside, "700") == true)
  local linked = session_dir("evil-link")
  os.execute("ln -s " .. shell_quote(outside) .. " " .. shell_quote(linked))
  expect_error("symlinked session dir", "E_SESSION_UNSAFE_PATH", { "status", "evil-link" })
  expect_error("symlinked start", "E_SESSION_UNSAFE_PATH", { "start", "evil-link" })

  local loose = session_dir("loose")
  assert(WheelHost.fs.mkdir_p(loose) == true)
  assert(WheelHost.fs.chmod(loose, "755") == true)
  expect_error("world-readable session dir", "E_SESSION_UNSAFE_PATH", { "status", "loose" })
  expect_error("world-readable start", "E_SESSION_UNSAFE_PATH", { "start", "loose" })

  local badfifo = session_dir("badfifo")
  assert(WheelHost.fs.mkdir_p(badfifo) == true)
  assert(WheelHost.fs.chmod(badfifo, "700") == true)
  local meta = read_meta("demo")
  local meta_json = Session.json_encode({
    protocol = Session.PROTOCOL,
    name = "badfifo",
    pid = meta.pid,
    started_at = meta.started_at,
    wheel_version = meta.wheel_version,
  })
  assert(WheelHost.fs.create_private_file(badfifo .. "/" .. Session.FILE_META, meta_json))
  assert(WheelHost.fs.mkfifo(badfifo .. "/" .. Session.FILE_REQUEST))
  assert(WheelHost.fs.mkfifo(badfifo .. "/" .. Session.FILE_RESPONSE))
  assert(WheelHost.fs.chmod(badfifo .. "/" .. Session.FILE_REQUEST, "666"))
  assert(WheelHost.fs.chmod(badfifo .. "/" .. Session.FILE_RESPONSE, "600"))
  expect_error("weaker FIFO mode", "E_SESSION_UNSAFE_PATH", { "status", "badfifo" })

  local badlink = session_dir("badfifosymlink")
  assert(WheelHost.fs.mkdir_p(badlink) == true)
  assert(WheelHost.fs.chmod(badlink, "700") == true)
  local target = badlink .. "/target"
  assert(WheelHost.fs.create_private_file(target, "not a fifo"))
  assert(Session.write_metadata(badlink, {
    protocol = Session.PROTOCOL,
    name = "badfifosymlink",
    pid = meta.pid,
    started_at = meta.started_at,
    wheel_version = meta.wheel_version,
  }))
  os.execute("ln -s " .. shell_quote(target) .. " " .. shell_quote(badlink .. "/" .. Session.FILE_REQUEST))
  assert(WheelHost.fs.mkfifo(badlink .. "/" .. Session.FILE_RESPONSE))
  expect_error("symlinked FIFO", "E_SESSION_UNSAFE_PATH", { "status", "badfifosymlink" })

  local root_link = test_base .. "/client-root-link"
  os.execute("ln -s " .. shell_quote(session_root) .. " " .. shell_quote(root_link))
  expect_error("symlinked client root", "E_SESSION_UNSAFE_PATH", { "status", "demo" },
    { root = root_link })
  expect_error("symlinked client probe", "E_SESSION_UNSAFE_PATH", { "probe", "demo" },
    { root = root_link })

  local weak_root = test_base .. "/weak-client-root"
  assert(WheelHost.fs.mkdir_p(weak_root) == true)
  assert(WheelHost.fs.chmod(weak_root, "755") == true)
  expect_error("weaker client root", "E_SESSION_UNSAFE_PATH", { "status", "demo" },
    { root = weak_root })

  local broken = session_dir("brokenmeta")
  assert(WheelHost.fs.mkdir_p(broken) == true)
  assert(WheelHost.fs.chmod(broken, "700") == true)
  assert(WheelHost.fs.create_private_file(broken .. "/" .. Session.FILE_META, "{"))
  expect_error("invalid metadata", "E_SESSION_METADATA_INVALID", { "start", "brokenmeta" })

  local hardmeta = session_dir("hardmeta")
  assert(WheelHost.fs.mkdir_p(hardmeta) == true)
  assert(WheelHost.fs.chmod(hardmeta, "700") == true)
  assert(Session.write_metadata(hardmeta, {
    protocol = Session.PROTOCOL,
    name = "hardmeta",
    pid = meta.pid,
    started_at = meta.started_at,
    wheel_version = meta.wheel_version,
  }))
  os.execute("ln " .. shell_quote(hardmeta .. "/" .. Session.FILE_META) .. " "
    .. shell_quote(hardmeta .. "/second-link"))
  expect_error("hard-linked metadata", "E_SESSION_UNSAFE_PATH", { "status", "hardmeta" })
end)

run_test("Session: malformed and oversized frames fail closed", function()
  local bad_protocol = raw_exchange("demo",
    '{"protocol":"wheel-session/0","id":"raw-1","method":"ping","params":{}}')
  assert(bad_protocol.ok == false and bad_protocol.error.code == "E_SESSION_PROTOCOL")

  local unknown = raw_exchange("demo",
    '{"protocol":"wheel-session/1","id":"raw-2","method":"bogus","params":{}}')
  assert(unknown.ok == false and unknown.error.code == "E_SESSION_METHOD_UNKNOWN")

  local scalar_params = raw_exchange("demo",
    '{"protocol":"wheel-session/1","id":"raw-p1","method":"ping","params":"not-an-object"}')
  assert(scalar_params.ok == false and scalar_params.error.code == "E_SESSION_ARGS_INVALID")

  local bad_get = raw_exchange("demo",
    '{"protocol":"wheel-session/1","id":"raw-p2","method":"context.get","params":{}}')
  assert(bad_get.ok == false and bad_get.error.code == "E_SESSION_ARGS_INVALID")

  local bad_put = raw_exchange("demo",
    '{"protocol":"wheel-session/1","id":"raw-p3","method":"context.put","params":{"name":123,"content":"x"}}')
  assert(bad_put.ok == false and bad_put.error.code == "E_SESSION_ARGS_INVALID")

  local oversized = raw_exchange("demo", Session.json_encode({
    protocol = "wheel-session/1",
    id = "raw-3",
    method = "context.put",
    params = { name = "scratch/oversized", content = string.rep("x", 70 * 1024) },
  }))
  assert(oversized.ok == false and oversized.error.code == "E_SESSION_FRAME_TOO_LARGE",
    "an oversized frame must be answered with E_SESSION_FRAME_TOO_LARGE")

  -- The daemon must resynchronise and stay responsive after the bounded drain.
  local ping = decode_stdout("ping", expect_ok("ping after oversized frame", { "ping", "demo" }))
  assert(ping.protocol == "wheel-session/1")

  local too_large = select(2, Session.request("demo", "context.put", {
    name = "scratch/too-large",
    content = string.rep("y", 70 * 1024),
  }, { root = session_root }))
  assert(too_large and too_large.code == "E_SESSION_FRAME_TOO_LARGE",
    "the client must reject an oversized request before writing it")
end)

run_test("Session: a live client lock serializes requests", function()
  local lock_path = session_dir("demo") .. "/" .. Session.FILE_CLIENT_LOCK
  local owner = WheelHost.proc.pid()
  assert(WheelHost.fs.create_private_file(lock_path, tostring(owner) .. "\n"))
  expect_error("busy control plane", "E_SESSION_BUSY", { "ping", "demo" })
  assert(WheelHost.fs.remove_file(lock_path))

  -- A dead owner is claimed by rename and the request proceeds.
  local dead_pid = 2147483647
  assert(WheelHost.proc.is_alive(dead_pid) ~= true,
    "the stale-lock test requires a pid above the host pid limit")
  assert(WheelHost.fs.create_private_file(lock_path, tostring(dead_pid) .. "\n"))
  decode_stdout("ping after stale lock", expect_ok("ping after stale lock", { "ping", "demo" }))
end)

run_test("Session: a stale mutex is reclaimed", function()
  local dir = session_dir("stale-mutex")
  local dead_pid = 2147483647
  assert(WheelHost.fs.mkdir_p(dir) == true)
  assert(WheelHost.fs.chmod(dir, "700") == true)
  assert(WheelHost.fs.create_private_file(
    dir .. "/" .. Session.FILE_CLIENT_LOCK .. ".mutex", tostring(dead_pid) .. "\n"))
  local owner = WheelHost.proc.pid()
  assert(Session.acquire_lock(dir, Session.FILE_CLIENT_LOCK, owner) == true)
  assert(Session.release_lock(dir, Session.FILE_CLIENT_LOCK, owner) == true)
  assert(WheelHost.fs.remove_dir(dir) == true)
end)

run_test("Session: prune does not remove a live client lock", function()
  local dir = session_dir("prune-live-client")
  local owner = WheelHost.proc.pid()
  assert(WheelHost.fs.mkdir_p(dir) == true)
  assert(WheelHost.fs.chmod(dir, "700") == true)
  assert(Session.acquire_lock(dir, Session.FILE_CLIENT_LOCK, owner) == true)
  local ok, err = Session.prune_stale_files(dir, owner)
  assert(ok, "prune must tolerate a live client: " .. tostring(err and err.code))
  assert(WheelHost.fs.stat(dir .. "/" .. Session.FILE_CLIENT_LOCK).exists == true,
    "prune must not remove a live canonical client lock")
  assert(Session.release_lock(dir, Session.FILE_CLIENT_LOCK, owner) == true)
  assert(WheelHost.fs.remove_dir(dir) == true)
end)

run_test("Session: prune restores a live stale tail when canonical is absent", function()
  local dir = session_dir("prune-live-tail")
  local owner = WheelHost.proc.pid()
  assert(WheelHost.fs.mkdir_p(dir) == true)
  assert(WheelHost.fs.chmod(dir, "700") == true)
  assert(WheelHost.fs.create_private_file(
    dir .. "/client.lock.stale.1.1", tostring(owner) .. "\n"))
  local ok, err = Session.prune_stale_files(dir, owner + 1)
  assert(ok, "prune must restore a live tail: " .. tostring(err and err.code))
  assert(WheelHost.fs.stat(dir .. "/client.lock").exists == true,
    "a live stale tail must be restored to the canonical lock")
  assert(WheelHost.fs.stat(dir .. "/client.lock.stale.1.1").exists == false,
    "the restored tail must be removed")
  assert(Session.release_lock(dir, Session.FILE_CLIENT_LOCK, owner) == true)
  assert(WheelHost.fs.remove_dir(dir) == true)
end)

run_test("Session: a pid dead daemon is reported without being signalled", function()
  local meta = read_meta("demo")
  local alive = WheelHost.proc.is_alive(meta.pid)
  assert(alive == true)
  local result = WheelHost.proc.run_command("kill -9 " .. tostring(meta.pid) .. " 2>/dev/null")
  assert(result.ok == true and result.code == 0, "the test must signal only its recorded pid")
  assert(wait_until_dead(meta.pid), "the recorded daemon pid must be gone")
  expect_error("dead daemon status", "E_SESSION_NOT_RUNNING", { "status", "demo" })

  local restart = decode_stdout("restart", expect_ok("restart after stale metadata", { "start", "demo" }))
  assert(restart.pid ~= meta.pid, "a restart must publish a new daemon pid")
  started_sessions[#started_sessions + 1] = { name = "demo", pid = restart.pid }
  local ping = decode_stdout("ping", expect_ok("ping after restart", { "ping", "demo" }))
  assert(ping.pid == restart.pid)
end)

run_test("Session: shutdown is explicit and leaves no control files", function()
  local meta = read_meta("demo")
  local stop = decode_stdout("stop", expect_ok("stop", { "stop", "demo" }))
  assert(stop.shutting_down == true)
  assert(stop.pid == meta.pid)
  assert(wait_until_dead(meta.pid), "the daemon must exit after shutdown")
  assert(WheelHost.fs.stat(session_dir("demo") .. "/" .. Session.FILE_META).exists == false,
    "metadata must be removed")
  assert(WheelHost.fs.stat(session_dir("demo") .. "/" .. Session.FILE_REQUEST).exists == false,
    "request FIFO must be removed")
  assert(WheelHost.fs.stat(session_dir("demo") .. "/" .. Session.FILE_RESPONSE).exists == false,
    "response FIFO must be removed")
  assert(WheelHost.fs.stat(session_dir("demo")).exists == false, "the session directory must be removed")
  expect_error("status after shutdown", "E_SESSION_NOT_RUNNING", { "status", "demo" })
end)

run_test("Session: a missing session reports not running", function()
  expect_error("missing session", "E_SESSION_NOT_RUNNING", { "status", "absent" })
end)

run_test("Session: invalid roots are refused before any write", function()
  local result = WheelHost.proc.run_program("bash", { cli_path, "--root", "relative", "start", "x" }, {
    timeout_ms = 30000,
  })
  assert(result.ok == true and result.code ~= 0)
  local decoded = decode_stdout("invalid root", result.stderr)
  assert(decoded.error and decoded.error.code == "E_SESSION_INVALID_ROOT")

  local root_link = test_base .. "/root-link"
  local root_target = test_base .. "/root-target"
  assert(WheelHost.fs.mkdir_p(root_target) == true)
  assert(WheelHost.fs.chmod(root_target, "700") == true)
  os.execute("ln -s " .. shell_quote(root_target) .. " " .. shell_quote(root_link))
  local linked_ok, linked_err = Session.prepare_start("x", { root = root_link })
  assert(linked_ok == nil and linked_err and linked_err.code == "E_SESSION_UNSAFE_PATH",
    "a symlinked session root must be refused")

  local bad_root = test_base .. "/bad-root"
  assert(WheelHost.fs.mkdir_p(bad_root) == true)
  assert(WheelHost.fs.chmod(bad_root, "755") == true)
  local mode_ok, mode_err = Session.prepare_start("x", { root = bad_root })
  assert(mode_ok == nil and mode_err and mode_err.code == "E_SESSION_UNSAFE_PATH",
    "a weaker-mode session root must be refused")
end)

print("\n==========================================")
print("  All Wheel session-daemon tests PASSED")
print("==========================================")

cleanup()
