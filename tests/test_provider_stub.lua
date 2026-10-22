-- tests/test_provider_stub.lua
-- Gate 2 provider-stub evidence (CTX-0029 / wheel#95).
--
-- Boundary:
--   * The stub is a real HTTP server on `127.0.0.1:0`; the transport is a
--     real Python `http.client` request from a separate process.
--   * The credential is a fixed, clearly synthetic value. It reaches only the
--     stub and client child environments (exported over an anonymous `sh -s`
--     script pipe), never argv, a request file, a response file, or a log.
--   * The adapter under test is the real `OpenAIAdapter`; the injected HTTP
--     client is the only double, and it is key-blind (the Python helper reads
--     the key from its own environment and strips caller Authorization).
--   * No real credential, external network, or live provider is involved.
--
-- Evidence limits (recorded in SECURITY-MODEL.md Gate 2 and
-- tests/PROVIDER-STUB.md): this is not audit-gate evidence, not asynchronous
-- cancellation evidence, and not a Bitty panel/terminal presentation run.

package.path = "./lua/?.lua;./lua/?/init.lua;" .. package.path

local WheelProvider = require("wheel.provider")

local JSON = WheelProvider.JSON
local OpenAIAdapter = WheelProvider.OpenAIAdapter

-- Fixed synthetic values: unmistakably test fixtures, never real credentials.
local SYNTHETIC_KEY = "sk-wheel-provider-stub-synthetic-not-a-secret-0001"
local WRONG_KEY = "sk-wheel-provider-stub-synthetic-not-a-secret-0002"
local KEY_ENV = "WHEEL_PROVIDER_STUB_KEY"
local STUB_SCRIPT = "tests/provider_stub.py"
local CLIENT_SCRIPT = "tests/provider_stub_client.py"
local PYTHON = "python3"
local READY_PROTOCOL = "wheel-provider-stub/1"
local STUB_CONTENT = "stub-ok"
local STUB_MODEL = "wheel-stub-model"

local READINESS_POLLS = 400
local SHUTDOWN_POLLS = 100
local POLL_SECONDS = "0.05"
local MAX_READ_BYTES = 4 * 1024 * 1024
local MAX_DIAGNOSTIC_BYTES = 256

local checks = 0
local captured = {}
local pass_lines = {}
local request_count = 0
local base = nil
local scratch_root = nil
local stub_pid = nil
local stub_terminated = false

local function check(condition, message)
  checks = checks + 1
  if not condition then
    error("provider-stub assertion failed: " .. tostring(message), 0)
  end
end

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

local function read_file(path)
  local handle = io.open(path, "rb")
  if not handle then
    return nil
  end
  local data = handle:read(MAX_READ_BYTES + 1)
  handle:close()
  if data and #data > MAX_READ_BYTES then
    error("provider-stub assertion failed: a captured artifact exceeded the read bound", 0)
  end
  return data
end

local function write_file(path, content)
  local handle = assert(io.open(path, "wb"))
  handle:write(content)
  handle:close()
end

local function trim(text)
  return (tostring(text or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function assert_no_key(text, label)
  if type(text) ~= "string" then
    return
  end
  check(text:find(SYNTHETIC_KEY, 1, true) == nil,
    "synthetic credential material detected in " .. label)
  check(text:find(WRONG_KEY, 1, true) == nil,
    "synthetic wrong-key material detected in " .. label)
end

local function capture(label, text)
  assert_no_key(text, label)
  captured[#captured + 1] = { label = label, text = text or "" }
end

local function pass(message)
  assert_no_key(message, "test output")
  pass_lines[#pass_lines + 1] = message
  print("[PASS] " .. message)
end

--- Feed a short shell script to `sh -s` over an anonymous pipe.
--- The synthetic key crosses this pipe as an `export` line, so it never
--- enters an argv vector or a file. Outputs are redirected by the caller.
local function run_script(script)
  local pipe = assert(io.popen("sh -s", "w"))
  local ok, err = pcall(function()
    pipe:write(script)
  end)
  pipe:close()
  if not ok then
    error("provider-stub assertion failed: the child script could not be written: "
      .. tostring(err), 0)
  end
end

local function is_alive(pid)
  if type(pid) ~= "number" or pid <= 1 then
    return false
  end
  return normalize_exit(os.execute("kill -0 " .. tostring(pid) .. " 2>/dev/null")) == 0
end

local function file_mode(path)
  local pipe = io.popen("stat -c %a " .. shell_quote(path) .. " 2>/dev/null", "r")
  if not pipe then
    return nil
  end
  local mode = trim(pipe:read("*l") or "")
  pipe:close()
  return mode
end

local function wait_for_file(path, polls)
  for _ = 1, polls do
    local content = read_file(path)
    if content and #content > 0 then
      return content
    end
    os.execute("sleep " .. POLL_SECONDS)
  end
  return nil
end

local function wait_until_dead(pid, polls)
  for _ = 1, polls do
    if not is_alive(pid) then
      return true
    end
    os.execute("sleep " .. POLL_SECONDS)
  end
  return not is_alive(pid)
end

local function cleanup()
  if stub_pid and not stub_terminated then
    stub_terminated = true
    if is_alive(stub_pid) then
      -- Signal only the pid published in the stub's readiness record.
      os.execute("kill -TERM " .. tostring(stub_pid) .. " 2>/dev/null")
      if not wait_until_dead(stub_pid, SHUTDOWN_POLLS) then
        os.execute("kill -KILL " .. tostring(stub_pid) .. " 2>/dev/null")
        wait_until_dead(stub_pid, SHUTDOWN_POLLS)
      end
    end
  end
  if base and scratch_root then
    local prefix = scratch_root .. "/provider-stub."
    if base:sub(1, #prefix) == prefix and base:find("%.%.") == nil then
      os.execute("rm -rf -- " .. shell_quote(base))
    end
  end
end

--- Run one request through the test-only Python transport.
-- The key is exported to the child environment over the pipe; argv is
-- only the script path. Returns { status, body } or nil plus a diagnostic.
local function run_client(spec, key, label)
  request_count = request_count + 1
  local stem = string.format("%s/client-%02d", base, request_count)
  local request_path = stem .. ".request.json"
  local response_path = stem .. ".response.json"
  local stdout_path = stem .. ".stdout"
  local stderr_path = stem .. ".stderr"

  local encoded = JSON.encode(spec)
  assert_no_key(encoded, label .. " request specification")
  write_file(request_path, encoded)

  local script = {}
  if key and #key > 0 then
    script[#script + 1] = "export " .. KEY_ENV .. "=" .. shell_quote(key)
  end
  script[#script + 1] = table.concat({
    "exec " .. PYTHON .. " " .. shell_quote(CLIENT_SCRIPT),
    " < " .. shell_quote(request_path),
    " > " .. shell_quote(stdout_path),
    " 2> " .. shell_quote(stderr_path),
  })
  run_script(table.concat(script, "\n") .. "\n")

  local stdout = read_file(stdout_path) or ""
  local stderr = read_file(stderr_path) or ""
  capture(label .. " client stdout", stdout)
  capture(label .. " client stderr", stderr)

  if #stdout == 0 then
    return nil, trim(stderr:sub(1, MAX_DIAGNOSTIC_BYTES))
  end

  local decoded_ok, decoded = pcall(JSON.decode, stdout)
  check(decoded_ok and type(decoded) == "table",
    label .. " helper output is not a response object")
  check(type(decoded.status) == "number", label .. " helper output has no status")
  check(type(decoded.body) == "string", label .. " helper output has no body")
  return { status = decoded.status, body = decoded.body, stderr = stderr }
end

local function make_http_client(key)
  return function(req)
    local headers = {}
    local authorization = nil
    for name, value in pairs(req.headers or {}) do
      local lower = string.lower(name)
      if lower == "authorization" then
        authorization = value
      end
      if lower ~= "authorization" and lower ~= "x-api-key" then
        headers[name] = value
      end
    end
    if key and #key > 0 then
      check(authorization == "Bearer " .. key,
        "the adapter must attach the synthetic key only in the authorization header")
    end

    local result, err = run_client({
      url = req.url,
      method = req.method or "POST",
      headers = headers,
      body = req.body,
    }, key, "provider request")
    if not result then
      return nil, "test HTTP transport failed: " .. tostring(err)
    end
    capture("provider response body", result.body)
    return { status = result.status, body = result.body }
  end
end

local function request_records()
  local raw = read_file(base .. "/stub-requests.jsonl") or ""
  local records = {}
  for line in (raw .. "\n"):gmatch("(.-)\n") do
    if #line > 0 then
      local ok, record = pcall(JSON.decode, line)
      check(ok and type(record) == "table", "stub request record is not JSON")
      records[#records + 1] = record
    end
  end
  return records
end

local function select_scratch_root()
  local configured = os.getenv("WHEEL_TEST_TMP")
  if configured and configured ~= "" then
    scratch_root = configured:gsub("/+$", "")
  else
    scratch_root = (os.getenv("TMPDIR") or "/tmp"):gsub("/+$", "") .. "/bitty"
  end
  check(scratch_root:sub(1, 1) == "/", "the scratch root must be absolute")
  check(scratch_root ~= "/" and scratch_root:find("%.%.") == nil,
    "the scratch root must be a real directory")
  local mkdir_status = normalize_exit(os.execute("mkdir -p -- " .. shell_quote(scratch_root)))
  check(mkdir_status == 0, "cannot create the scratch root")
end

local function start_stub()
  local ready_path = base .. "/stub-ready.json"
  local requests_path = base .. "/stub-requests.jsonl"
  local pid_path = base .. "/stub.pid"
  local stdout_path = base .. "/stub.stdout"
  local stderr_path = base .. "/stub.stderr"

  run_script(table.concat({
    "export " .. KEY_ENV .. "=" .. shell_quote(SYNTHETIC_KEY),
    "exec " .. PYTHON .. " " .. shell_quote(STUB_SCRIPT)
      .. " --ready " .. shell_quote(ready_path)
      .. " --requests " .. shell_quote(requests_path)
      .. " > " .. shell_quote(stdout_path)
      .. " 2> " .. shell_quote(stderr_path) .. " &",
    "echo $! > " .. shell_quote(pid_path),
    "",
  }, "\n"))

  -- Record the launched pid before waiting for readiness, so a stub that
  -- fails to initialize can still be terminated by the pid it was started as.
  local pid_raw = wait_for_file(pid_path, 50)
  check(pid_raw ~= nil, "the stub launch did not record its pid")
  local launched_pid = tonumber(trim(pid_raw))
  check(type(launched_pid) == "number" and launched_pid % 1 == 0 and launched_pid > 1,
    "the recorded stub pid is not a process identifier")
  stub_pid = launched_pid

  local ready_raw = wait_for_file(ready_path, READINESS_POLLS)
  if not ready_raw then
    local stderr = trim((read_file(stderr_path) or ""):sub(1, MAX_DIAGNOSTIC_BYTES))
    error("provider-stub assertion failed: the stub did not become ready: "
      .. stderr, 0)
  end

  local ok, ready = pcall(JSON.decode, ready_raw)
  check(ok and type(ready) == "table", "the readiness record is not a JSON object")
  check(ready.protocol == READY_PROTOCOL, "the readiness record protocol drifted")
  check(ready.host == "127.0.0.1", "the stub must bind loopback only")
  check(type(ready.port) == "number" and ready.port % 1 == 0
    and ready.port > 0 and ready.port < 65536,
    "the readiness record must carry a valid port")
  check(type(ready.pid) == "number" and ready.pid % 1 == 0 and ready.pid > 1,
    "the readiness record must carry the stub pid")
  check(ready.pid == stub_pid, "the readiness pid must match the launched pid")
  check(ready.key_env == KEY_ENV, "the readiness record must name the key env")
  check(ready.path == "/chat/completions", "the readiness record path drifted")

  check(is_alive(stub_pid), "the recorded stub pid must be alive after readiness")
  capture("stub stdout", read_file(stdout_path) or "")

  -- The credential travels only through the child environment. The launched
  -- stub's argv must be key-free; its environment is the expected transport
  -- (and is never persisted by this test).
  local cmdline = read_file("/proc/" .. tostring(stub_pid) .. "/cmdline") or ""
  check(cmdline:find(SYNTHETIC_KEY, 1, true) == nil,
    "the stub argv must not carry the synthetic key")
  local environ = read_file("/proc/" .. tostring(stub_pid) .. "/environ")
  if environ then
    check(environ:find(KEY_ENV .. "=" .. SYNTHETIC_KEY, 1, true) ~= nil,
      "the stub must receive the synthetic key through its environment")
  end
  environ = nil

  return ready.port
end

local function main()
  select_scratch_root()
  local pipe = assert(io.popen(
    "mktemp -d -- " .. shell_quote(scratch_root .. "/provider-stub.XXXXXX"), "r"))
  base = trim(pipe:read("*l") or "")
  pipe:close()
  check(base:sub(1, #scratch_root + 1) == scratch_root .. "/",
    "mktemp must create the run directory under the scratch root")

  local port = start_stub()
  local base_url = "http://127.0.0.1:" .. tostring(port)

  -- 1. Deterministic completion through the real adapter and real transport.
  local adapter = OpenAIAdapter.new({
    base_url = base_url,
    api_key = SYNTHETIC_KEY,
    model = STUB_MODEL,
    temperature = 0,
    http_client = make_http_client(SYNTHETIC_KEY),
  })
  local description = adapter:describe()
  check(description.provider == "openai", "the adapter description drifted")
  check(description.base_url == base_url, "the adapter description base_url drifted")
  check(description.has_api_key == true, "the adapter must hold the synthetic key")
  check(description.api_key == nil, "the adapter description must not expose the key")
  capture("adapter description", JSON.encode(description))

  local result, completion_err = adapter:complete({
    messages = {
      { role = "user", content = "Reply with the stub marker." },
    },
    max_completion_tokens = 64,
  }, {})
  check(result ~= nil, "the stub completion failed: " .. trim((completion_err or ""):sub(1, MAX_DIAGNOSTIC_BYTES)))
  check(result.content == STUB_CONTENT,
    "the stub completion content drifted: " .. tostring(result.content))
  check(result.finish_reason == "stop", "the stub finish reason drifted")
  capture("completion content", result.content)
  pass("provider-stub: deterministic completion through the loopback stub")

  -- 2. The stub saw the exact synthetic key; the request record has no key.
  local records = request_records()
  check(#records == 1, "the stub must record exactly one accepted request")
  check(file_mode(base) == "700", "the run directory must be private 0700")
  check(file_mode(base .. "/stub-ready.json") == "600",
    "the readiness record must be private 0600")
  check(file_mode(base .. "/stub-requests.jsonl") == "600",
    "the request record must be private 0600")
  local accepted = records[1]
  check(accepted.path == "/chat/completions", "the stub request path drifted")
  check(accepted.method == "POST", "the stub request method drifted")
  check(accepted.status == 200, "the accepted request must return 200")
  check(accepted.authorization_present == true,
    "the stub must observe the authorization header")
  check(accepted.authorization_valid == true,
    "the stub must observe the exact synthetic key")
  local request_text = read_file(base .. "/client-01.request.json") or ""
  local request_ok, request_spec = pcall(JSON.decode, request_text)
  check(request_ok and type(request_spec) == "table",
    "the captured request specification is not JSON")
  check(type(request_spec.url) == "string" and request_spec.url == base_url .. "/chat/completions",
    "the captured request url drifted")
  local sent_ok, sent_body = pcall(JSON.decode, request_spec.body)
  check(sent_ok and type(sent_body) == "table", "the captured request body is not JSON")
  check(sent_body.model == STUB_MODEL, "the captured request model drifted")
  check(type(sent_body.messages) == "table" and #sent_body.messages == 1,
    "the captured request messages drifted")
  local header_names = {}
  for name in pairs(request_spec.headers or {}) do
    header_names[#header_names + 1] = string.lower(name)
  end
  for _, name in ipairs(header_names) do
    check(name ~= "authorization" and name ~= "x-api-key",
      "the captured request must not carry an authorization header")
  end
  pass("provider-stub: the stub observed the exact synthetic key and no key reached the request record")

  -- 3. A wrong key fails closed with 401 and is recorded as invalid.
  local wrong_adapter = OpenAIAdapter.new({
    base_url = base_url,
    api_key = WRONG_KEY,
    model = STUB_MODEL,
    http_client = make_http_client(WRONG_KEY),
  })
  local wrong_result, wrong_err = wrong_adapter:complete({
    messages = { { role = "user", content = "wrong key probe" } },
    max_completion_tokens = 64,
  }, {})
  check(wrong_result == nil, "a wrong key must not produce a completion")
  check(type(wrong_err) == "string" and wrong_err:find("401", 1, true) ~= nil,
    "a wrong key must surface the stub's 401: " .. trim((wrong_err or ""):sub(1, MAX_DIAGNOSTIC_BYTES)))
  capture("wrong-key error", wrong_err)
  records = request_records()
  check(#records == 2, "the stub must record the rejected request")
  check(records[2].status == 401, "the wrong-key request must return 401")
  check(records[2].authorization_present == true,
    "the wrong-key request must still carry an authorization header")
  check(records[2].authorization_valid == false,
    "the stub must record the wrong key as invalid")
  pass("provider-stub: a wrong key fails closed with 401 and is recorded as invalid")

  -- 4. A missing key environment fails before any request reaches the stub.
  local before_missing = #request_records()
  local missing_result, missing_err = run_client({
    url = base_url .. "/chat/completions",
    method = "POST",
    headers = { ["Content-Type"] = "application/json" },
    body = JSON.encode({ model = STUB_MODEL, messages = {} }),
  }, nil, "missing-key probe")
  check(missing_result == nil, "a missing key environment must not send a request")
  check(type(missing_err) == "string" and missing_err:find(KEY_ENV, 1, true) ~= nil,
    "a missing key must name the key environment variable")
  capture("missing-key error", missing_err)
  check(#request_records() == before_missing,
    "a missing key must not reach the stub")
  pass("provider-stub: a missing key environment fails closed before any request")

  -- 5. Destinations outside the loopback allowlist are refused locally.
  local refusals = {
    {
      label = "non-loopback host",
      spec = {
        url = "http://example.com/chat/completions",
        method = "POST",
        headers = {},
        body = "{}",
      },
      fragment = "loopback",
    },
    {
      label = "userinfo",
      spec = {
        url = "http://user:pass@127.0.0.1:" .. tostring(port) .. "/chat/completions",
        method = "POST",
        headers = {},
        body = "{}",
      },
      fragment = "userinfo",
    },
    {
      label = "non-completion path",
      spec = {
        url = base_url .. "/redirect",
        method = "POST",
        headers = {},
        body = "{}",
      },
      fragment = "completion path",
    },
    {
      label = "non-POST method",
      spec = {
        url = base_url .. "/chat/completions",
        method = "GET",
        headers = {},
        body = "",
      },
      fragment = "POST",
    },
  }
  for _, refusal in ipairs(refusals) do
    local refused, refusal_err = run_client(refusal.spec, SYNTHETIC_KEY, refusal.label)
    check(refused == nil, refusal.label .. " must be refused before any connection")
    check(type(refusal_err) == "string" and refusal_err:find(refusal.fragment, 1, true) ~= nil,
      refusal.label .. " must be refused with a static diagnostic: "
        .. trim((refusal_err or ""):sub(1, MAX_DIAGNOSTIC_BYTES)))
    capture(refusal.label .. " error", refusal_err)
  end
  check(#request_records() == before_missing,
    "refused destinations must not reach the stub")
  pass("provider-stub: non-loopback hosts, userinfo, other paths, and other methods are refused")

  -- 6. The whole run directory is key-free, including logs and artifacts.
  local find_pipe = assert(io.popen(
    "find " .. shell_quote(base) .. " -type f -print 2>/dev/null", "r"))
  local files = {}
  for line in find_pipe:lines() do
    files[#files + 1] = line
  end
  find_pipe:close()
  check(#files >= 8, "the run directory must contain the captured artifacts")
  for _, path in ipairs(files) do
    local content = read_file(path) or ""
    assert_no_key(content, "artifact " .. path:gsub("^" .. base .. "/", ""))
  end
  for index, channel in ipairs(captured) do
    assert_no_key(channel.text, "captured channel " .. tostring(index) .. " (" .. channel.label .. ")")
  end
  pass("provider-stub: the key is absent from stdout, stderr, errors, description, requests, and every artifact")

  pass(string.format("provider-stub evidence passed offline (%d checks)", checks))
end

local ok, err = pcall(main)
local cleanup_ok, cleanup_err = pcall(cleanup)
if cleanup_err then
  io.stderr:write("[WARN] provider-stub cleanup failed: " .. tostring(cleanup_err) .. "\n")
end
if not ok then
  io.stderr:write("[FAIL] provider-stub: " .. tostring(err) .. "\n")
  os.exit(1)
end
if not cleanup_ok then
  os.exit(1)
end
os.exit(0)
