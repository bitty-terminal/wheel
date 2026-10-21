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

local script_path = type(arg) == "table" and arg[0] or "tests/test_session.lua"
local repo_root = script_path:match("^(.*)/tests/[^/]+$") or "."
local cli_path = repo_root .. "/scripts/wheel-session"

local test_base = (os.getenv("TMPDIR") or "/tmp")
  .. "/bitty/wheel-session-test-"
  .. tostring(WheelHost.proc.pid() or 0)
  .. "-"
  .. tostring(os.time())
local session_root = test_base .. "/sessions"
local started_pids = {}
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
    env = { WHEEL_SESSION_ROOT = session_root },
  })
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

-- Isolation: the whole test tree is private and disposable.
remove_tree(test_base)
assert(WheelHost.fs.mkdir_p(test_base) == true)
assert(WheelHost.fs.chmod(test_base, "700") == true)
assert(WheelHost.fs.mkdir_p(session_root) == true)
assert(WheelHost.fs.chmod(session_root, "700") == true)

local function cleanup()
  for _, pid in ipairs(started_pids) do
    local alive = WheelHost.proc.is_alive(pid)
    if alive then
      os.execute("kill -TERM " .. tostring(pid) .. " 2>/dev/null")
      wait_until_dead(pid)
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

-- ---------------------------------------------------------------------------
-- Integration: lifecycle, context persistence, snapshots
-- ---------------------------------------------------------------------------

run_test("Session: start publishes private metadata and a live control plane", function()
  local output = expect_ok("start", { "start", "demo" })
  local meta = decode_stdout("start", output)
  assert(meta.protocol == "wheel-session/1", "start must report the protocol marker")
  assert(meta.name == "demo")
  assert(type(meta.pid) == "number" and meta.pid > 1)
  started_pids[#started_pids + 1] = meta.pid

  local stored = read_meta("demo")
  assert(stored.pid == meta.pid, "start output must match published metadata")
  assert(stored.started_at == meta.started_at)
  assert(stored.wheel_version:match("^%d+%.%d+%.%d+$"))

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

  local broken = session_dir("brokenmeta")
  assert(WheelHost.fs.mkdir_p(broken) == true)
  assert(WheelHost.fs.chmod(broken, "700") == true)
  assert(WheelHost.fs.create_private_file(broken .. "/" .. Session.FILE_META, "{"))
  expect_error("invalid metadata", "E_SESSION_METADATA_INVALID", { "start", "brokenmeta" })
end)

run_test("Session: malformed and oversized frames fail closed", function()
  local bad_protocol = raw_exchange("demo",
    '{"protocol":"wheel-session/0","id":"raw-1","method":"ping","params":{}}')
  assert(bad_protocol.ok == false and bad_protocol.error.code == "E_SESSION_PROTOCOL")

  local unknown = raw_exchange("demo",
    '{"protocol":"wheel-session/1","id":"raw-2","method":"bogus","params":{}}')
  assert(unknown.ok == false and unknown.error.code == "E_SESSION_METHOD_UNKNOWN")

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
  assert(WheelHost.fs.create_private_file(lock_path, "999999\n"))
  decode_stdout("ping after stale lock", expect_ok("ping after stale lock", { "ping", "demo" }))
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
  started_pids[#started_pids + 1] = restart.pid
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
end)

print("\n==========================================")
print("  All Wheel session-daemon tests PASSED")
print("==========================================")

cleanup()
