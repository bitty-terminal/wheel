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
local AnthropicAdapter = WheelProvider.AnthropicAdapter

-- Fixed synthetic values: unmistakably test fixtures, never real credentials.
local SYNTHETIC_KEY = "sk-wheel-provider-stub-synthetic-not-a-secret-0001"
local WRONG_KEY = "sk-wheel-provider-stub-synthetic-not-a-secret-0002"
local AMBIENT_KEY = "sk-wheel-provider-stub-synthetic-not-a-secret-0003"
local CRLF_KEY = "sk-wheel-provider-stub-synthetic-not-a-secret-0004\r\nX-Injected: no"
local AUDIT_KEYS = { SYNTHETIC_KEY, WRONG_KEY, AMBIENT_KEY, CRLF_KEY }
local KEY_ENV = "WHEEL_PROVIDER_STUB_KEY"
local STUB_SCRIPT = "tests/provider_stub.py"
local CLIENT_SCRIPT = "tests/provider_stub_client.py"
local PYTHON = "python3"
local READY_PROTOCOL = "wheel-provider-stub/1"
local STUB_CONTENT = "stub-ok"
local STUB_MODEL = "wheel-stub-model"
-- A defect that followed the redirect would reach this loopback discard port,
-- never an external host. The client must refuse the 3xx before any hop.
local REDIRECT_TARGET = "http://127.0.0.1:9/chat/completions"

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
local stub_pids = {}

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
  for _, key in ipairs(AUDIT_KEYS) do
    check(text:find(key, 1, true) == nil,
      "synthetic credential material detected in " .. label)
  end
end

--- Bound and redact a child diagnostic before it can reach an error message.
-- Never interpolate raw child output: a malformed credential must not bypass
-- the capture assertions and reappear in a failure path.
local function safe_diagnostic(text)
  local bounded = tostring(text or ""):sub(1, MAX_DIAGNOSTIC_BYTES)
  for _, key in ipairs(AUDIT_KEYS) do
    if bounded:find(key, 1, true) ~= nil then
      return "[redacted diagnostic]"
    end
  end
  return bounded
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
--- Synthetic keys cross this pipe as `export` lines, so they never enter an
--- argv vector or a file. Outputs are redirected by the caller.
local function run_script(script)
  local pipe = assert(io.popen("sh -s", "w"))
  local ok, err = pcall(function()
    pipe:write(script)
  end)
  pipe:close()
  if not ok then
    error("provider-stub assertion failed: the child script could not be written: "
      .. safe_diagnostic(err), 0)
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

--- Terminate one recorded stub pid. TERM first; KILL is only a bounded
--- fallback for a wedged test fixture, never a name- or pattern-based kill.
local function terminate_stub(pid)
  if not is_alive(pid) then
    return true
  end
  os.execute("kill -TERM " .. tostring(pid) .. " 2>/dev/null")
  if wait_until_dead(pid, SHUTDOWN_POLLS) then
    return true
  end
  os.execute("kill -KILL " .. tostring(pid) .. " 2>/dev/null")
  return wait_until_dead(pid, SHUTDOWN_POLLS)
end

local function cleanup()
  for _, pid in ipairs(stub_pids) do
    terminate_stub(pid)
  end
  if base and scratch_root then
    local prefix = scratch_root .. "/provider-stub."
    if base:sub(1, #prefix) == prefix and base:find("%.%.") == nil then
      os.execute("rm -rf -- " .. shell_quote(base))
    end
  end
end

--- Run one request through the test-only Python transport.
-- The key is exported to the child environment over the pipe; argv is only the
-- script path. `ambient_key` simulates an inherited value that the generated
-- `unset` must remove for a missing-key probe. Returns { status, body } or nil
-- plus a key-free diagnostic.
local function run_client(spec, key, label, ambient_key)
  request_count = request_count + 1
  local stem = string.format("%s/client-%02d", base, request_count)
  local request_path = stem .. ".request.json"
  local stdout_path = stem .. ".stdout"
  local stderr_path = stem .. ".stderr"

  local encoded = JSON.encode(spec)
  assert_no_key(encoded, label .. " request specification")
  write_file(request_path, encoded)

  local script = {}
  if ambient_key and #ambient_key > 0 then
    script[#script + 1] = "export " .. KEY_ENV .. "=" .. shell_quote(ambient_key)
  end
  -- Always clear an inherited value; the explicit export below is the only
  -- source the client may observe.
  script[#script + 1] = "unset " .. KEY_ENV
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
    return nil, safe_diagnostic(stderr)
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
      return nil, "test HTTP transport failed: " .. safe_diagnostic(err)
    end
    capture("provider response body", result.body)
    return { status = result.status, body = result.body }
  end
end

local function request_records(path)
  local raw = read_file(path) or ""
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

--- Launch a stub instance. `extra_args` entries must already be shell-quoted.
local function start_stub(stem, extra_args, stopped_path)
  local ready_path = base .. "/" .. stem .. "-ready.json"
  local requests_path = base .. "/" .. stem .. "-requests.jsonl"
  local pid_path = base .. "/" .. stem .. ".pid"
  local stdout_path = base .. "/" .. stem .. ".stdout"
  local stderr_path = base .. "/" .. stem .. ".stderr"

  local command = {
    "exec", PYTHON, shell_quote(STUB_SCRIPT),
    "--ready", shell_quote(ready_path),
    "--requests", shell_quote(requests_path),
  }
  for _, argument in ipairs(extra_args or {}) do
    command[#command + 1] = argument
  end
  if stopped_path then
    command[#command + 1] = "--stopped"
    command[#command + 1] = shell_quote(stopped_path)
  end
  local launch_line = table.concat(command, " ")
    .. " > " .. shell_quote(stdout_path)
    .. " 2> " .. shell_quote(stderr_path) .. " &"

  run_script(table.concat({
    "unset " .. KEY_ENV,
    "export " .. KEY_ENV .. "=" .. shell_quote(SYNTHETIC_KEY),
    launch_line,
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
  stub_pids[#stub_pids + 1] = launched_pid

  local ready_raw = wait_for_file(ready_path, READINESS_POLLS)
  if not ready_raw then
    local stderr = safe_diagnostic(read_file(stderr_path) or "")
    error("provider-stub assertion failed: the stub did not become ready"
      .. (stderr ~= "" and " (" .. stderr .. ")" or ""), 0)
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
  check(ready.pid == launched_pid, "the readiness pid must match the launched pid")
  check(ready.key_env == KEY_ENV, "the readiness record must name the key env")
  check(ready.path == "/chat/completions", "the readiness record path drifted")

  check(is_alive(launched_pid), "the recorded stub pid must be alive after readiness")
  capture(stem .. " stdout", read_file(stdout_path) or "")

  -- The credential travels only through the child environment. The launched
  -- stub's argv must be key-free; its environment is the expected transport
  -- (and is never persisted by this test). An unreadable cmdline is a failed
  -- check, never a vacuous pass.
  local cmdline = read_file("/proc/" .. tostring(launched_pid) .. "/cmdline")
  check(type(cmdline) == "string" and #cmdline > 0,
    "the stub /proc cmdline must be readable to prove key-free argv")
  check(cmdline:find(SYNTHETIC_KEY, 1, true) == nil,
    "the stub argv must not carry the synthetic key")
  local environ = read_file("/proc/" .. tostring(launched_pid) .. "/environ")
  if environ then
    check(environ:find(KEY_ENV .. "=" .. SYNTHETIC_KEY, 1, true) ~= nil,
      "the stub must receive the synthetic key through its environment")
  end
  environ = nil

  return {
    port = ready.port,
    pid = launched_pid,
    ready = ready_path,
    requests = requests_path,
    stopped = stopped_path,
    stdout = stdout_path,
    stderr = stderr_path,
  }
end

--- Run one refused stub launch and capture its status plus raw stderr.
local function run_stub_once(label, env_key, arguments)
  local stem = base .. "/once-" .. label
  local ready_path = stem .. "-ready.json"
  local requests_path = stem .. "-requests.jsonl"
  local stdout_path = stem .. ".stdout"
  local stderr_path = stem .. ".stderr"
  local status_path = stem .. ".status"

  local script = { "unset " .. KEY_ENV }
  if env_key and #env_key > 0 then
    script[#script + 1] = "export " .. KEY_ENV .. "=" .. shell_quote(env_key)
  end
  script[#script + 1] = table.concat({
    PYTHON, " ", shell_quote(STUB_SCRIPT),
    " --ready ", shell_quote(ready_path),
    " --requests ", shell_quote(requests_path),
    arguments and (" " .. arguments) or "",
    " > ", shell_quote(stdout_path),
    " 2> ", shell_quote(stderr_path),
  })
  script[#script + 1] = "echo $? > " .. shell_quote(status_path)
  run_script(table.concat(script, "\n") .. "\n")

  local status = tonumber(trim(read_file(status_path) or ""))
  local stdout = read_file(stdout_path) or ""
  local stderr = read_file(stderr_path) or ""
  capture(label .. " stdout", stdout)
  capture(label .. " stderr", stderr)
  check(read_file(ready_path) == nil, label .. " must not publish a readiness record")
  return status, stderr
end

local function main()
  select_scratch_root()
  local pipe = assert(io.popen(
    "mktemp -d -- " .. shell_quote(scratch_root .. "/provider-stub.XXXXXX"), "r"))
  base = trim(pipe:read("*l") or "")
  pipe:close()
  check(base:sub(1, #scratch_root + 1) == scratch_root .. "/",
    "mktemp must create the run directory under the scratch root")

  local main_stub = start_stub("stub", nil, base .. "/stub-stopped.json")
  local port = main_stub.port
  local base_url = "http://127.0.0.1:" .. tostring(port)

  local function records()
    return request_records(main_stub.requests)
  end

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
  check(result ~= nil,
    "the stub completion failed: " .. safe_diagnostic(completion_err))
  check(result.content == STUB_CONTENT,
    "the stub completion content drifted: " .. safe_diagnostic(result.content))
  check(result.finish_reason == "stop", "the stub finish reason drifted")
  check(result.usage.prompt_tokens == 1 and result.usage.completion_tokens == 1,
    "explicit provider usage must be normalized")
  local bounded = WheelProvider.parse_rationale(result, { task_id = "stub-task" })
  check(bounded.source == "fallback" or bounded.decision == "Use the deterministic stub response",
    "provider-stub rationale must be deterministic")
  check(bounded.task_id == "stub-task", "provider-stub rationale must carry the task link")
  check((bounded.thinking_content or ""):find("loopback request accepted", 1, true) == nil,
    "provider-stub rationale must not retain the thinking stream")
  capture("completion content", result.content)
  pass("provider-stub: deterministic completion through the loopback stub")

  local cache_adapter = OpenAIAdapter.new({
    base_url = base_url,
    api_key = SYNTHETIC_KEY,
    model = STUB_MODEL,
    prompt_cache_supported = true,
    http_client = make_http_client(SYNTHETIC_KEY),
  })
  local cache_request = {
    messages = { { role = "system", content = "stable" }, { role = "user", content = "miss" } },
    stable_context_prefix = "stable",
    tools = {},
    max_completion_tokens = 64,
  }
  local cache_payload = assert(cache_adapter:_format_payload(cache_request, false))
  check(type(cache_payload.prompt_cache_key) == "string" and #cache_payload.prompt_cache_key == 64,
    "supported provider must receive an opaque cache key")
  local cache_request_variant = {}
  for key, value in pairs(cache_request) do cache_request_variant[key] = value end
  cache_request_variant.stable_context_prefix = "different stable prefix"
  local variant_payload = assert(cache_adapter:_format_payload(cache_request_variant, false))
  check(cache_payload.prompt_cache_key ~= variant_payload.prompt_cache_key,
    "provider cache key must bind the stable prefix")
  local mismatched_prefix_request = {}
  for key, value in pairs(cache_request) do mismatched_prefix_request[key] = value end
  mismatched_prefix_request.messages = {
    { role = "system", content = "different serialized prefix" },
    { role = "user", content = "miss" },
  }
  local mismatched_prefix_payload = assert(cache_adapter:_format_payload(mismatched_prefix_request, false))
  check(mismatched_prefix_payload.prompt_cache_key == nil,
    "cache key must be omitted when the declared prefix differs from serialized system bytes")
  mismatched_prefix_request.prompt_cache_policy = "required"
  local required_mismatch_payload, required_mismatch_err = cache_adapter:_format_payload(mismatched_prefix_request, false)
  check(required_mismatch_payload == nil and required_mismatch_err:find("does not match", 1, true),
    "required cache policy must fail closed on a serialized-prefix mismatch")
  local oversized_prefix = string.rep("x", WheelProvider.MAX_PROMPT_CACHE_PREFIX_BYTES + 1)
  local max_bounded_prefix = string.rep("x", WheelProvider.MAX_PROMPT_CACHE_PREFIX_BYTES)
  local max_bounded_payload = assert(cache_adapter:_format_payload({
    messages = { { role = "system", content = max_bounded_prefix } },
    stable_context_prefix = max_bounded_prefix,
  }, false))
  check(type(max_bounded_payload.prompt_cache_key) == "string",
    "cache key must bind a wire prefix exactly at the configured byte bound")
  local bounded_prefix_payload = assert(cache_adapter:_format_payload({
    messages = { { role = "system", content = oversized_prefix } },
    stable_context_prefix = oversized_prefix,
  }, false))
  check(bounded_prefix_payload.prompt_cache_key == nil,
    "cache key must be omitted when the declared system prefix exceeds its byte bound")
  local domain_a = WheelProvider.cache_domain(cache_request, "openai", STUB_MODEL, base_url, "prefer")
  local domain_b = WheelProvider.cache_domain(cache_request, "openai", STUB_MODEL, base_url, "required")
  check(domain_a ~= domain_b, "cache domain must include policy")
  local unsupported = OpenAIAdapter.new({
    prompt_cache_policy = "required",
    prompt_cache_supported = false,
  })
  unsupported.http_client = function() error("unsupported required mode must not send") end
  local unsupported_payload, unsupported_err = unsupported:_format_payload(cache_request, false)
  check(unsupported_payload == nil and unsupported_err:find("unsupported", 1, true),
    "required mode must fail closed when cache capability is unavailable")
  local unsupported_stream = OpenAIAdapter.new({ base_url = base_url })
  local unsupported_stream_payload = assert(unsupported_stream:_format_payload(cache_request, true))
  check(unsupported_stream_payload.prompt_cache_key == nil
    and unsupported_stream_payload.stream_options
    and unsupported_stream_payload.stream_options.include_usage == true,
    "providers without cache capability must still request streaming usage telemetry")
  local false_policy, false_policy_err = cache_adapter:_format_payload({
    messages = cache_request.messages, stable_context_prefix = "stable", prompt_cache_policy = false,
  }, false)
  check(false_policy == nil and false_policy_err:find("must be off", 1, true),
    "false cache policy must be rejected instead of defaulting")
  local mock_required = WheelProvider.MockProvider.new({ prompt_cache_policy = "required" })
  local mock_result, mock_err = mock_required:complete({ messages = cache_request.messages })
  check(mock_result == nil and mock_err:find("unsupported", 1, true),
    "unsupported MockProvider must reject required cache policy")
  local stream_payload = assert(cache_adapter:_format_payload(cache_request, true))
  check(stream_payload.stream_options and stream_payload.stream_options.include_usage == true,
    "OpenAI streaming must request explicit usage telemetry")
  local custom = assert(WheelProvider.create({ provider = "openai", model = STUB_MODEL }, {
    base_url = base_url .. "/custom", api_key = SYNTHETIC_KEY,
  }))
  local custom_payload = assert(custom:_format_payload(cache_request, false))
  check(custom_payload.prompt_cache_key == nil,
    "custom endpoints must not receive cache controls without explicit capability")
  local custom_stream_payload = assert(custom:_format_payload(cache_request, true))
  check(custom_stream_payload.stream_options and custom_stream_payload.stream_options.include_usage == true,
    "custom OpenAI endpoints must still request streaming usage telemetry")
  local off_adapter = OpenAIAdapter.new({ prompt_cache_policy = "off", prompt_cache_supported = true })
  local off_payload = assert(off_adapter:_format_payload(cache_request, false))
  check(off_payload.prompt_cache_key == nil, "off policy must not attach cache controls")
  local off_stream_payload = assert(off_adapter:_format_payload(cache_request, true))
  check(off_stream_payload.prompt_cache_key == nil
    and off_stream_payload.stream_options and off_stream_payload.stream_options.include_usage == true,
    "cache off policy must preserve streaming usage telemetry without cache controls")
  local normalized = WheelProvider.normalize_usage({ prompt_tokens = "bad", prompt_tokens_details = { cached_tokens = -1 } }, "openai")
  check(normalized.provider_cache_status == "error" and normalized.prompt_tokens == nil,
    "malformed usage must be surfaced as error without inventing token counts")
  local anthropic_usage = WheelProvider.normalize_usage({ input_tokens = 20,
    cache_creation_input_tokens = 8, cache_read_input_tokens = 0 }, "anthropic")
  check(anthropic_usage.cache_creation_tokens == 8 and anthropic_usage.cache_read_tokens == 0,
    "explicit provider cache miss/create evidence must normalize")
  check(anthropic_usage.prompt_tokens == 20 and anthropic_usage.uncached_input_tokens == 20,
    "Anthropic input_tokens must remain uncached input; cache creation is separate")
  check(anthropic_usage.provider_cache_status == "write_only",
    "cache creation without reads must remain write-only, not a hit")
  local openai_usage = WheelProvider.normalize_usage({
    prompt_tokens = 40,
    prompt_tokens_details = { cached_tokens = 16, cache_write_tokens = 4 },
  }, "openai")
  check(openai_usage.cache_read_tokens == 16 and openai_usage.cache_creation_tokens == 4
    and openai_usage.provider_cache_status == "verified_hit",
    "OpenAI explicit cached and cache-write usage must normalize as verified evidence")
  check(openai_usage.prompt_tokens == 40 and openai_usage.uncached_input_tokens == 24,
    "OpenAI prompt_tokens must include cached reads and expose uncached input separately")
  check(openai_usage.uncached_input_tokens + openai_usage.cache_read_tokens
      == openai_usage.prompt_tokens,
    "OpenAI cached reads must be a subset of prompt_tokens, not counted twice")
  local explicit_miss = WheelProvider.normalize_usage({
    prompt_tokens = 40, prompt_tokens_details = { cached_tokens = 0, cache_write_tokens = 0 },
  }, "openai")
  check(explicit_miss.provider_cache_status == "verified_miss",
    "explicit zero cached/write counts must represent a verified miss")
  local absent_usage = WheelProvider.normalize_usage({ prompt_tokens = 40 }, "openai")
  check(absent_usage.provider_cache_status == "unknown",
    "usage without cache fields must remain unknown")
  local invalid_usage = WheelProvider.normalize_usage({
    prompt_tokens = 40, prompt_tokens_details = { cached_tokens = "bad" },
  }, "openai")
  check(invalid_usage.provider_cache_status == "error",
    "malformed cache usage must not be reported as a miss or hit")

  local status_order = { "unsupported", "not_requested", "unknown", "verified_miss",
    "write_only", "verified_hit", "error" }
  for _, stronger in ipairs(status_order) do
    for _, weaker in ipairs(status_order) do
      local forward = WheelProvider.aggregate_cache_status(stronger, weaker)
      local reverse = WheelProvider.aggregate_cache_status(weaker, stronger)
      local expected = 1
      for index, status in ipairs(status_order) do
        if status == stronger or status == weaker then
          expected = math.max(expected, index)
        end
      end
      check(forward == status_order[expected] and reverse == status_order[expected],
        "cache status aggregation must be order independent: " .. stronger .. ", " .. weaker)
    end
  end
  local function aggregate_sequence(first, second)
    return WheelProvider.aggregate_cache_status(
      WheelProvider.aggregate_cache_status("unknown", first), second)
  end
  check(aggregate_sequence("verified_hit", "verified_miss") == "verified_hit"
    and aggregate_sequence("verified_miss", "verified_hit") == "verified_hit",
    "mixed stream/turn cache statuses must preserve a hit in either order")
  check(aggregate_sequence("error", "verified_hit") == "error"
    and aggregate_sequence("verified_hit", "error") == "error",
    "mixed stream/turn cache statuses must preserve an error in either order")

  local anthropic = AnthropicAdapter.new({
    api_key = SYNTHETIC_KEY,
    prompt_cache_supported = true,
  })
  local anthropic_payload = assert(anthropic:_format_payload({
    model = STUB_MODEL,
    messages = {
      { role = "system", content = "stable system prefix" },
      { role = "user", content = "request" },
    },
    stable_context_prefix = "stable system prefix",
    tools = {},
    max_completion_tokens = 64,
  }, false))
  check(type(anthropic_payload.system) == "table"
    and anthropic_payload.system[1].cache_control.type == "ephemeral"
    and anthropic_payload.prompt_cache_key == nil,
    "Anthropic must use documented cache_control breakpoints, not OpenAI cache keys")
  pass("provider-stub: cache negotiation, domain key, unsupported required mode, and measured usage only")

  -- 2. The stub saw the exact synthetic key; the request record has no key.
  local current = records()
  check(#current == 1, "the stub must record exactly one accepted request")
  check(file_mode(base) == "700", "the run directory must be private 0700")
  check(file_mode(main_stub.ready) == "600",
    "the readiness record must be private 0600")
  check(file_mode(main_stub.requests) == "600",
    "the request record must be private 0600")
  local accepted = current[1]
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
    "a wrong key must surface the stub's 401: " .. safe_diagnostic(wrong_err))
  capture("wrong-key error", wrong_err)
  current = records()
  check(#current == 2, "the stub must record the rejected request")
  check(current[2].status == 401, "the wrong-key request must return 401")
  check(current[2].authorization_present == true,
    "the wrong-key request must still carry an authorization header")
  check(current[2].authorization_valid == false,
    "the stub must record the wrong key as invalid")
  pass("provider-stub: a wrong key fails closed with 401 and is recorded as invalid")

  -- 4. A missing key fails before any request, even with an ambient value.
  local before_missing = #records()
  local missing_result, missing_err = run_client({
    url = base_url .. "/chat/completions",
    method = "POST",
    headers = { ["Content-Type"] = "application/json" },
    body = JSON.encode({ model = STUB_MODEL, messages = {} }),
  }, nil, "missing-key probe", AMBIENT_KEY)
  check(missing_result == nil, "a missing key environment must not send a request")
  check(type(missing_err) == "string" and missing_err:find(KEY_ENV, 1, true) ~= nil,
    "a missing key must name the key environment variable: "
      .. safe_diagnostic(missing_err))
  capture("missing-key error", missing_err)
  check(#records() == before_missing,
    "a missing key must not reach the stub even with an ambient value")
  pass("provider-stub: a missing key fails closed before any request, even with an ambient value")

  -- 5. A CRLF key is rejected by http.client with a ValueError whose message
  -- embeds the header value. Only the exception type may reach stderr.
  local before_crlf = #records()
  local crlf_result, crlf_err = run_client({
    url = base_url .. "/chat/completions",
    method = "POST",
    headers = { ["Content-Type"] = "application/json" },
    body = JSON.encode({ model = STUB_MODEL, messages = {} }),
  }, CRLF_KEY, "CRLF-key probe")
  check(crlf_result == nil, "a CRLF key must not produce a response")
  check(type(crlf_err) == "string" and crlf_err:find("ValueError", 1, true) ~= nil,
    "a CRLF key must report only the static ValueError exception type")
  check(crlf_err:find("X-Injected", 1, true) == nil,
    "the rejected header value must not be echoed")
  check(crlf_err:find("Bearer", 1, true) == nil,
    "the authorization header must not be echoed")
  capture("CRLF-key error", crlf_err)
  check(#records() == before_crlf, "a rejected header must not reach the stub")
  pass("provider-stub: a CRLF key reports only the static exception type and never the value")

  -- 6. A request with no Authorization header is recorded as a 401.
  local before_noauth = #records()
  local noauth_result, noauth_err = run_client({
    url = base_url .. "/chat/completions",
    method = "POST",
    headers = { ["Content-Type"] = "application/json" },
    body = JSON.encode({ model = STUB_MODEL, messages = {} }),
    omit_authorization = true,
  }, SYNTHETIC_KEY, "missing-authorization probe")
  check(noauth_result ~= nil and noauth_result.status == 401,
    "a missing authorization header must return 401: " .. safe_diagnostic(noauth_err))
  capture("missing-authorization body", noauth_result and noauth_result.body or noauth_err)
  current = records()
  check(#current == before_noauth + 1,
    "the stub must record the unauthenticated request")
  local unauthenticated = current[#current]
  check(unauthenticated.status == 401,
    "a missing authorization header must return 401")
  check(unauthenticated.authorization_present == false,
    "the stub must record the absent authorization header")
  check(unauthenticated.authorization_valid == false,
    "an absent authorization header must not be recorded as valid")
  pass("provider-stub: a request without an authorization header is rejected with 401")

  -- 7. Destinations outside the loopback allowlist are refused locally.
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
      label = "query string",
      spec = {
        url = base_url .. "/chat/completions?probe=1",
        method = "POST",
        headers = {},
        body = "{}",
      },
      fragment = "query",
    },
    {
      label = "fragment",
      spec = {
        url = base_url .. "/chat/completions#probe",
        method = "POST",
        headers = {},
        body = "{}",
      },
      fragment = "query",
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
        .. safe_diagnostic(refusal_err))
    capture(refusal.label .. " error", refusal_err)
  end
  check(#records() == before_noauth + 1,
    "refused destinations must not reach the stub")
  pass("provider-stub: non-loopback hosts, userinfo, other paths, query/fragment, and other methods are refused")

  -- 8. SIGTERM shuts the recorded stub down through its signal handler. The
  -- clean-shutdown marker is absent before the signal and written afterwards;
  -- a SIGKILL fallback would leave it missing.
  check(read_file(main_stub.stopped) == nil,
    "the stub must not publish a clean-shutdown marker before SIGTERM")
  check(terminate_stub(main_stub.pid),
    "the stub must exit after the recorded SIGTERM")
  local stopped_raw = read_file(main_stub.stopped)
  check(type(stopped_raw) == "string" and #stopped_raw > 0,
    "the stub must publish a clean-shutdown marker; a SIGKILL fallback is not graceful")
  capture("clean-shutdown marker", stopped_raw)
  local stopped_ok, stopped = pcall(JSON.decode, stopped_raw)
  check(stopped_ok and type(stopped) == "table" and stopped.status == "stopped",
    "the clean-shutdown marker must carry the stopped status")
  pass("provider-stub: a recorded SIGTERM completes the stub's graceful shutdown path")

  -- 9. A 302 from the stub is refused without a second hop.
  local redirect_stub = start_stub("stub-redirect",
    { "--redirect", shell_quote(REDIRECT_TARGET) },
    base .. "/stub-redirect-stopped.json")
  local redirect_url = "http://127.0.0.1:" .. tostring(redirect_stub.port)
  local redirect_result, redirect_err = run_client({
    url = redirect_url .. "/chat/completions",
    method = "POST",
    headers = { ["Content-Type"] = "application/json" },
    body = JSON.encode({ model = STUB_MODEL, messages = {} }),
  }, SYNTHETIC_KEY, "redirect probe")
  check(redirect_result == nil, "a redirect must not produce a response")
  check(type(redirect_err) == "string" and redirect_err:find("redirect refused", 1, true) ~= nil,
    "the client must refuse the redirect: " .. safe_diagnostic(redirect_err))
  capture("redirect error", redirect_err)
  local redirect_records = request_records(redirect_stub.requests)
  check(#redirect_records == 1,
    "the client must not follow the redirect to a second hop")
  check(redirect_records[1].status == 302,
    "the redirect stub must record the 302 response")
  check(redirect_records[1].authorization_valid == true,
    "the redirect probe must carry the exact synthetic key")
  check(terminate_stub(redirect_stub.pid),
    "the redirect stub must exit after the recorded SIGTERM")
  check(read_file(redirect_stub.stopped) ~= nil,
    "the redirect stub must also publish its clean-shutdown marker")
  pass("provider-stub: a 302 is refused without a second hop")

  -- 10. Stub launch refusals are static and key-free.
  local no_key_status, no_key_stderr = run_stub_once("stub-no-key", nil, "")
  check(no_key_status ~= nil and no_key_status ~= 0,
    "the stub must refuse to start without a key environment")
  check(no_key_stderr:find("is not set", 1, true) ~= nil,
    "a missing stub key must report the static environment diagnostic: "
      .. safe_diagnostic(no_key_stderr))

  local argv_status, argv_stderr = run_stub_once("stub-argv-key", SYNTHETIC_KEY,
    "--unexpected " .. shell_quote(SYNTHETIC_KEY))
  check(argv_status ~= nil and argv_status ~= 0,
    "the stub must refuse a key-bearing argv")
  check(argv_stderr:find("argv", 1, true) ~= nil,
    "a key-bearing argv must report the static argv diagnostic: "
      .. safe_diagnostic(argv_stderr))
  check(argv_stderr:find("unrecognized", 1, true) == nil,
    "the argv guard must run before argparse can echo the value")
  pass("provider-stub: missing-key and key-bearing-argv launches fail with static diagnostics")

  -- 11. The whole run directory is key-free, including logs and artifacts.
  local find_pipe = assert(io.popen(
    "find " .. shell_quote(base) .. " -type f -print 2>/dev/null", "r"))
  local files = {}
  for line in find_pipe:lines() do
    files[#files + 1] = line
  end
  find_pipe:close()
  check(#files >= 12, "the run directory must contain the captured artifacts")
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
  io.stderr:write("[WARN] provider-stub cleanup failed: " .. safe_diagnostic(cleanup_err) .. "\n")
end
if not ok then
  io.stderr:write("[FAIL] provider-stub: " .. safe_diagnostic(err) .. "\n")
  os.exit(1)
end
if not cleanup_ok then
  os.exit(1)
end
os.exit(0)
