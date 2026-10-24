-- tests/test_audit.lua
-- Gate 1 unit evidence for the local execution audit sink (CTX-0030).
--
-- The suite exercises the real sink and the real process seam. Every record
-- file lives under one private per-run scratch root; the test removes only the
-- root it created. No ambient audit directory is touched, and every command
-- used as a probe is either `true`/`printf` or writes one marker file that the
-- test removes with its root.

package.path = "./lua/?.lua;./lua/?/init.lua;" .. package.path

local WheelAudit = require("wheel.audit")
local WheelConfig = require("wheel.config")
local WheelErrors = require("wheel.errors")
local WheelHost = require("wheel.host")
local WheelKernel = require("wheel.kernel")

local JSON = WheelKernel.JSON

local checks = 0
local failures = 0
local scratch_root = nil
local base = nil

local function check(condition, message)
  checks = checks + 1
  if not condition then
    error("audit assertion failed: " .. tostring(message), 0)
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
  local content = handle:read("*a")
  handle:close()
  return content
end

local function write_file(path, content)
  local handle = assert(io.open(path, "wb"))
  assert(handle:write(content))
  assert(handle:close())
end

local function append_file(path, content)
  local handle = assert(io.open(path, "ab"))
  assert(handle:write(content))
  assert(handle:close())
end

local function file_mode(path)
  local pipe = io.popen("stat -c %a " .. shell_quote(path) .. " 2>/dev/null", "r")
  if not pipe then
    return nil
  end
  local mode = pipe:read("*l")
  pipe:close()
  return mode and mode:match("^%s*(.-)%s*$") or nil
end

local function parse_records(dir, limits)
  local max_files = limits and limits.max_files or WheelAudit.LIMITS.MAX_FILES
  local paths = {}
  for index = max_files - 1, 1, -1 do
    paths[#paths + 1] = dir .. "/audit." .. tostring(index) .. ".jsonl"
  end
  paths[#paths + 1] = dir .. "/audit.jsonl"

  local records = {}
  for _, path in ipairs(paths) do
    local content = read_file(path)
    if content then
      for line in content:gmatch("([^\n]+)") do
        local record = JSON.decode(line)
        assert(type(record) == "table", "every retained line must decode as JSON")
        records[#records + 1] = record
      end
    end
  end
  return records
end

local function record_bytes(dir, limits)
  local max_files = limits and limits.max_files or WheelAudit.LIMITS.MAX_FILES
  local paths = { dir .. "/audit.jsonl" }
  for index = 1, max_files - 1 do
    paths[#paths + 1] = dir .. "/audit." .. tostring(index) .. ".jsonl"
  end
  local bytes = 0
  for _, path in ipairs(paths) do
    local content = read_file(path)
    if content then
      bytes = bytes + #content
    end
  end
  return bytes
end

local function assert_no_secret(text, secret, label)
  check(type(text) ~= "string" or text:find(secret, 1, true) == nil,
    label .. " must not contain the synthetic secret")
end

local function test(name, fn)
  local ok, err = pcall(fn)
  if ok then
    print("[PASS] " .. name)
  else
    failures = failures + 1
    print("[FAIL] " .. name .. ": " .. tostring(err))
  end
end

local function select_scratch_root()
  local configured = os.getenv("WHEEL_TEST_TMP")
  if type(configured) == "string" and configured ~= "" then
    scratch_root = configured:gsub("/+$", "")
  else
    scratch_root = (os.getenv("TMPDIR") or "/tmp"):gsub("/+$", "") .. "/bitty"
  end
  check(scratch_root:sub(1, 1) == "/", "the scratch root must be absolute")
  check(scratch_root ~= "/" and scratch_root:find("%.%.") == nil,
    "the scratch root must not be root or contain '..'")
  check(normalize_exit(os.execute("mkdir -p -- " .. shell_quote(scratch_root))) == 0,
    "cannot create the scratch root")
end

local function select_base()
  local pipe = assert(io.popen(
    "mktemp -d -- " .. shell_quote(scratch_root .. "/audit-test.XXXXXX"), "r"))
  base = pipe:read("*l")
  pipe:close()
  base = base and base:match("^%s*(.-)%s*$") or nil
  check(type(base) == "string" and base ~= "", "mktemp must return a base directory")
  check(base:sub(1, #scratch_root + 1) == scratch_root .. "/",
    "the run base must live under the scratch root")
end

local function cleanup()
  if base and scratch_root and base:sub(1, #scratch_root + 1) == scratch_root .. "/" then
    os.execute("rm -rf -- " .. shell_quote(base))
  end
end

-- ---------------------------------------------------------------------------
-- Tests
-- ---------------------------------------------------------------------------

local function run_tests()
  test("WheelAudit: append writes private JSONL with a monotonic hash chain", function()
    local dir = base .. "/append"
    local sink = assert(WheelAudit.new({ dir = dir }))

    local first_ok, first_err = sink:record({
      event = "process.pre_spawn",
      kind = "argv",
      program = "printf",
      args = { "%s", "append-one" },
      cwd = base,
      role = "coding",
      agent = "audit-agent",
      task = "CTX-0030",
      tool = "run_program",
      intent = "append probe",
      decision = "allow",
      high_risk = true,
      spawned = false,
    })
    check(first_ok == true, "the first append must succeed: " .. tostring(first_err))
    local second_ok, second_err = sink:record({
      event = "process.completed",
      kind = "argv",
      program = "printf",
      args = { "%s", "append-one" },
      cwd = base,
      decision = "allow",
      high_risk = true,
      spawned = true,
      exit_code = 0,
      duration_ms = 7,
      cleanup = "swept",
      outcome = "exited",
    })
    check(second_ok == true, "the completion append must succeed: " .. tostring(second_err))

    local active = dir .. "/audit.jsonl"
    check(file_mode(active) == "600", "the audit file must be mode 0600")
    check(file_mode(dir) == "700", "the audit directory must be mode 0700")

    local records = parse_records(dir)
    check(#records == 2, "two records must be appended")
    check(records[1].seq == 1 and records[2].seq == 2,
      "sequence numbers must be monotonic")
    check(records[1].prev == string.rep("0", 64),
      "the first record must start from the zero hash")
    check(records[2].prev == records[1].hash,
      "the second record must name the first record's hash")
    check(records[1].command_hash == records[2].command_hash,
      "the pre-spawn and completion records must share a stable command hash")
    check(records[1].role == "coding" and records[1].agent == "audit-agent"
      and records[1].task == "CTX-0030" and records[1].tool == "run_program",
      "supplied identity fields must be recorded")
    check(records[1].cwd == base, "the cwd must be recorded")
    check(records[1].high_risk == true and records[1].spawned == false,
      "the pre-spawn record must carry its risk and non-spawn state")
    check(records[2].exit_code == 0 and records[2].duration_ms == 7
      and records[2].cleanup == "swept" and records[2].spawned == true,
      "the completion record must carry exit, duration, cleanup, and spawn state")

    local verified, verify_err, verify_reason = WheelAudit.verify({ dir = dir })
    check(verified ~= nil,
      "the retained chain must verify: " .. tostring(verify_reason) .. " " .. tostring(verify_err))
    check(verified.records == 2 and verified.files == 1,
      "verify must report the two records and one file")
    check(verified.last_seq == 2, "verify must report the last sequence")
  end)

  test("WheelAudit: redaction removes credential shapes and keeps a stable hash", function()
    local dir = base .. "/redaction"
    local secret = "sk-audit-synthetic-4f8c2d1e9a7b6c5d"
    local password = "audit-synthetic-password-91c4"
    local userinfo = "audit-synthetic-userinfo-27ab"
    local expected = "[redacted:" .. WheelConfig.compute_hash(secret):sub(1, 16) .. "]"

    local shell = table.concat({
      "curl -H " .. shell_quote("Authorization: Bearer " .. secret),
      " --token=" .. secret,
      " API_KEY=" .. secret,
      " --header 'X-Api-Key: " .. secret .. "'",
      " https://operator:" .. userinfo .. "@example.invalid/path?access_token=" .. secret,
    }, "")

    local ok, err = WheelAudit.record({
      event = "process.pre_spawn",
      kind = "shell",
      shell = shell,
      decision = "allow",
      reason = "curl probe",
    }, { dir = dir })
    check(ok == true, "the redaction probe must be recorded: " .. tostring(err))

    local argv_ok = WheelAudit.record({
      event = "process.pre_spawn",
      kind = "argv",
      program = "deploy",
      args = { "--password", password, "--token=" .. secret, "target" },
      decision = "allow",
    }, { dir = dir })
    check(argv_ok == true, "the argv redaction probe must be recorded")

    local raw = read_file(dir .. "/audit.jsonl") or ""
    assert_no_secret(raw, secret, "the audit stream")
    assert_no_secret(raw, password, "the audit stream")
    assert_no_secret(raw, userinfo, "the audit stream")
    check(raw:find("Authorization", 1, true) == nil,
      "the authorization header line must not be recorded")
    check(raw:find("Bearer", 1, true) == nil,
      "the bearer scheme must not be recorded")
    check(raw:find("X-Api-Key", 1, true) == nil,
      "a secret-shaped header name must not be recorded")
    check(raw:find(expected, 1, true) ~= nil,
      "the stable secret marker must use the value's SHA-256 prefix")
    check(raw:find("[redacted:" .. WheelConfig.compute_hash(password):sub(1, 16) .. "]",
      1, true) ~= nil,
      "a context-redacted argv value must keep its own stable marker")

    local records = parse_records(dir)
    check(records[1].redactions ~= nil and records[1].redactions >= 3,
      "the redaction count must be recorded")
    check(records[1].shell == nil or records[1].shell:find(secret, 1, true) == nil,
      "the stored shell must not retain the secret")

    for _, record in ipairs(records) do
      for _, forbidden in ipairs({ "stdout", "stderr", "prompt", "content", "response" }) do
        check(record[forbidden] == nil, "audit records must not carry a " .. forbidden .. " field")
      end
    end
  end)

  test("WheelAudit: Authorization variants redact the complete value", function()
    local dir = base .. "/auth-headers"
    local values = {
      token = "opaque-token-4d1f9a",
      api_scheme = "opaque-scheme-71c2e8",
      ssws = "opaque-ssws-9b3a55",
      digest = "opaque-digest-response-2c7f10",
      aws4 = "opaque-aws4-signature-6e8d43",
      proxy = "opaque-proxy-apikey-1a9c77",
      json = "opaque-json-ssws-5f2b90",
      quoted = "opaque-shell-quoted-3e6d18",
      argv = "opaque-argv-digest-8a4c21",
      unquoted = "opaque-unquoted-tail-0d7e62",
    }

    local shell = table.concat({
      "curl -H 'Authorization: Token " .. values.token .. "'",
      " -H 'Authorization: ApiKey " .. values.api_scheme .. "'",
      " -H 'Authorization: SSWS " .. values.ssws .. "'",
      " -H 'Authorization: Digest username=\"operator\", realm=\"audit\", "
        .. "nonce=\"n-1\", response=\"" .. values.digest .. "\"'",
      " -H 'Authorization: AWS4-HMAC-SHA256 Credential=AKIAEXAMPLE/20261022, "
        .. "SignedHeaders=host, Signature=" .. values.aws4 .. "'",
      " -H 'Proxy-Authorization: ApiKey " .. values.proxy .. "'",
      " -H 'Authorization: Token " .. values.quoted .. "'",
      " -d '{\"Authorization\":\"SSWS " .. values.json .. "\",\"keep\":\"json-keep\"}'",
      " target",
    }, "")

    local ok, err = WheelAudit.record({
      event = "process.pre_spawn",
      kind = "shell",
      shell = shell,
      decision = "allow",
      reason = "authorization header probe",
    }, { dir = dir })
    check(ok == true, "the header probe must be recorded: " .. tostring(err))

    local argv_ok = WheelAudit.record({
      event = "process.pre_spawn",
      kind = "argv",
      program = "curl",
      args = { "-H", "Authorization: Digest username=\"u\", response=\""
        .. values.argv .. "\"", "target" },
      decision = "allow",
    }, { dir = dir })
    check(argv_ok == true, "the argv header probe must be recorded")

    local unquoted_ok = WheelAudit.record({
      event = "process.pre_spawn",
      kind = "shell",
      shell = "curl -H Authorization: Token " .. values.unquoted,
      decision = "allow",
    }, { dir = dir })
    check(unquoted_ok == true, "the unquoted tail probe must be recorded")

    local raw = read_file(dir .. "/audit.jsonl") or ""
    for name, secret in pairs(values) do
      assert_no_secret(raw, secret, "the audit stream (" .. name .. ")")
    end
    check(raw:find("Authorization", 1, true) == nil,
      "no Authorization header line may be recorded")
    check(raw:find("Proxy-Authorization", 1, true) == nil,
      "no Proxy-Authorization header line may be recorded")
    check(raw:find("Digest", 1, true) == nil, "no Digest scheme may be recorded")
    check(raw:find("AWS4-HMAC-SHA256", 1, true) == nil,
      "no AWS4 scheme may be recorded")
    check(raw:find("SSWS", 1, true) == nil, "no SSWS scheme may be recorded")
    check(raw:find("ApiKey", 1, true) == nil, "no ApiKey scheme may be recorded")
    check(raw:find("json-keep", 1, true) ~= nil,
      "the JSON body outside the authorization value must remain")
    check(raw:find("[redacted:" .. WheelConfig.compute_hash(
      "Token " .. values.token):sub(1, 16) .. "]", 1, true) ~= nil,
      "the full authorization value must keep a stable marker")

    -- A denied real command carrying the same headers must not echo them in
    -- its result or typed error, and its audit record must remain redacted.
    local denied = WheelHost.proc.run_command(shell, nil, {
      audit = {
        dir = dir,
        decision = "deny",
        reason = "authorization probe denial",
        high_risk = true,
      },
    })
    check(denied.ok == false and denied.denied == true,
      "the probe command must be denied without executing")
    check(denied.stdout == "" and denied.stderr:find(values.token, 1, true) == nil,
      "the denial result must not carry a credential")
    check(denied.audit_error == nil or type(denied.audit_error.message) ~= "string"
      or denied.audit_error.message == "the audit record could not be written",
      "the denial error must stay static")

    -- A write failure must not copy a credential into the typed error.
    local blocked = base .. "/auth-blocked"
    write_file(blocked, "not a directory")
    local failed, failed_err = WheelAudit.record({
      event = "process.pre_spawn",
      kind = "shell",
      shell = shell,
      decision = "allow",
    }, { dir = blocked .. "/audit" })
    check(failed == nil and type(failed_err) == "table",
      "the blocked audit write must fail with a typed error")
    for name, secret in pairs(values) do
      assert_no_secret(failed_err.message, secret, "the typed error (" .. name .. ")")
      assert_no_secret(tostring(failed_err), secret, "the typed error string (" .. name .. ")")
    end

    local records = parse_records(dir)
    local last = records[#records]
    for name, secret in pairs(values) do
      assert_no_secret(last.shell or "", secret, "the denied record (" .. name .. ")")
    end
  end)

  test("WheelHost: escaped JSON Authorization headers do not leak", function()
    local dir = base .. "/escaped-json"
    local escaped_auth_value = "opaque-escaped-json-value-6c1a"
    local escaped_proxy_value = "opaque-escaped-json-proxy-4b9d"
    local digest_value = "opaque-digest-value-8e2f"
    local auth_shell = string.format(
      [[true -d "{\"Authorization\":\"Token %s\"}"]], escaped_auth_value)
    local proxy_shell = string.format(
      [[true -d "{\"Proxy-Authorization\":\"ApiKey %s\"}"]], escaped_proxy_value)
    local digest_shell = string.format(
      [[true -d "{\"Authorization\":\"Digest username=\\\"u\\\", response=\\\"%s\\\"\"}"]],
      digest_value)

    local permitted = WheelHost.proc.run_command(auth_shell, nil, {
      audit = { dir = dir, decision = "allow", high_risk = true },
    })
    check(permitted.ok == true and permitted.code == 0,
      "the escaped JSON command must run: " .. tostring(permitted.stderr))
    assert_no_secret(permitted.stdout, escaped_auth_value, "the permitted stdout")
    assert_no_secret(permitted.stderr, escaped_auth_value, "the permitted stderr")

    local proxy_result = WheelHost.proc.run_command(proxy_shell, nil, {
      audit = { dir = dir, decision = "allow", high_risk = true },
    })
    check(proxy_result.ok == true and proxy_result.code == 0,
      "the escaped proxy command must run: " .. tostring(proxy_result.stderr))

    local digest_result = WheelHost.proc.run_command(digest_shell, nil, {
      audit = { dir = dir, decision = "allow", high_risk = true },
    })
    check(digest_result.ok == true and digest_result.code == 0,
      "the escaped Digest command must run: " .. tostring(digest_result.stderr))
    assert_no_secret(digest_result.stdout, digest_value, "the Digest stdout")

    local denied = WheelHost.proc.run_command(auth_shell, nil, {
      audit = {
        dir = dir,
        decision = "deny",
        reason = "escaped JSON probe",
        high_risk = true,
      },
    })
    check(denied.ok == false and denied.denied == true,
      "the escaped JSON command must be denied")
    assert_no_secret(denied.stdout, escaped_auth_value, "the denial stdout")
    assert_no_secret(denied.stderr, escaped_auth_value, "the denial stderr")

    local digest_denied = WheelHost.proc.run_command(digest_shell, nil, {
      audit = {
        dir = dir,
        decision = "deny",
        reason = "escaped Digest probe",
        high_risk = true,
      },
    })
    check(digest_denied.ok == false and digest_denied.denied == true,
      "the escaped Digest command must be denied")
    assert_no_secret(digest_denied.stderr, digest_value, "the Digest denial stderr")

    local raw = read_file(dir .. "/audit.jsonl") or ""
    assert_no_secret(raw, escaped_auth_value, "the audit stream")
    assert_no_secret(raw, escaped_proxy_value, "the audit stream")
    assert_no_secret(raw, digest_value, "the audit stream")
    check(raw:find("response", 1, true) == nil,
      "the escaped Digest parameter name must not survive over-redaction")
    check(raw:find("Authorization", 1, true) == nil,
      "the escaped Authorization key must not be recorded")
    check(raw:find("Proxy-Authorization", 1, true) == nil,
      "the escaped Proxy-Authorization key must not be recorded")
    check(raw:find("[redacted:", 1, true) ~= nil,
      "the escaped JSON values must produce stable markers")

    for _, record in ipairs(parse_records(dir)) do
      assert_no_secret(record.shell or "", escaped_auth_value, "a pre-spawn/completion record")
      assert_no_secret(record.shell or "", escaped_proxy_value, "a pre-spawn/completion record")
      assert_no_secret(record.shell or "", digest_value, "a pre-spawn/completion record")
      check((record.shell or ""):find("response", 1, true) == nil,
        "the Digest parameter name must not survive in a record")
      check((record.shell or ""):find("Digest", 1, true) == nil,
        "the Digest scheme must not survive in a record")
      check((record.shell or ""):find("username", 1, true) == nil,
        "the Digest username parameter must not survive over-redaction")
    end

    local blocked = base .. "/escaped-json-blocked"
    write_file(blocked, "not a directory")
    for _, candidate in ipairs({ auth_shell, digest_shell }) do
      local failed, failed_err = WheelAudit.record({
        event = "process.pre_spawn",
        kind = "shell",
        shell = candidate,
        decision = "allow",
      }, { dir = blocked .. "/audit" })
      check(failed == nil and type(failed_err) == "table",
        "the blocked escaped-JSON write must fail with a typed error")
      assert_no_secret(failed_err.message, escaped_auth_value, "the typed error")
      assert_no_secret(tostring(failed_err), escaped_auth_value, "the typed error string")
      assert_no_secret(failed_err.message, digest_value, "the typed error")
    end
  end)

  test("WheelHost: authorization env assignments and flags redact complete values", function()
    local dir = base .. "/auth-env-flags"
    local env_auth_value = "opaque-env-auth-value-2f7c"
    local http_auth_value = "opaque-http-auth-value-9d4a"
    local flag_auth_value = "opaque-flag-auth-value-5b8e"
    local inner_env_value = "opaque-env-inner-value-7c3a"
    local inner_flag_value = "opaque-flag-inner-value-1e6b"
    local shell = "true AUTHORIZATION='Token " .. env_auth_value .. "'"
      .. " HTTP_AUTHORIZATION='Token " .. http_auth_value .. "'"
      .. " --authorization 'Token " .. flag_auth_value .. "'"
    local inner_env_shell = string.format(
      [[true AUTHORIZATION="Token \"%s\""]], inner_env_value)
    local inner_flag_shell = string.format(
      [[true --authorization "Token \"%s\""]], inner_flag_value)

    local permitted = WheelHost.proc.run_command(shell, nil, {
      audit = { dir = dir, decision = "allow", high_risk = true },
    })
    check(permitted.ok == true and permitted.code == 0,
      "the env/flag audit command must run: " .. tostring(permitted.stderr))
    check(permitted.stdout == "", "the audit probe must not echo its arguments")

    for _, candidate in ipairs({ inner_env_shell, inner_flag_shell }) do
      local result = WheelHost.proc.run_command(candidate, nil, {
        audit = { dir = dir, decision = "allow", high_risk = true },
      })
      check(result.ok == true and result.code == 0,
        "the escaped inner-quote command must run: " .. tostring(result.stderr))
      assert_no_secret(result.stdout, inner_env_value, "the inner-quote stdout")
      assert_no_secret(result.stdout, inner_flag_value, "the inner-quote stdout")
    end

    local denied = WheelHost.proc.run_command(shell, nil, {
      audit = {
        dir = dir,
        decision = "deny",
        reason = "env/flag probe",
        high_risk = true,
      },
    })
    check(denied.ok == false and denied.denied == true,
      "the env/flag command must be denied")
    assert_no_secret(denied.stdout, env_auth_value, "the denial stdout")
    assert_no_secret(denied.stderr, env_auth_value, "the denial stderr")
    assert_no_secret(denied.stderr, flag_auth_value, "the denial stderr")

    local raw = read_file(dir .. "/audit.jsonl") or ""
    for _, secret in ipairs({ env_auth_value, http_auth_value, flag_auth_value,
      inner_env_value, inner_flag_value }) do
      assert_no_secret(raw, secret, "the audit stream")
    end
    for _, secret in ipairs({ env_auth_value, http_auth_value, flag_auth_value }) do
      check(raw:find("[redacted:" .. WheelConfig.compute_hash(
        "Token " .. secret):sub(1, 16) .. "]", 1, true) ~= nil,
        "the complete env/flag value must keep a stable marker")
    end
    check(raw:find("[redacted:", 1, true) ~= nil,
      "the escaped inner-quote values must produce markers")
    for _, record in ipairs(parse_records(dir)) do
      for _, secret in ipairs({ env_auth_value, http_auth_value, flag_auth_value,
        inner_env_value, inner_flag_value }) do
        assert_no_secret(record.shell or "", secret, "a pre-spawn/completion record")
      end
    end

    local blocked = base .. "/auth-env-flags-blocked"
    write_file(blocked, "not a directory")
    local failed, failed_err = WheelAudit.record({
      event = "process.pre_spawn",
      kind = "shell",
      shell = shell,
      decision = "allow",
    }, { dir = blocked .. "/audit" })
    check(failed == nil and type(failed_err) == "table",
      "the blocked env/flag write must fail with a typed error")
    for _, secret in ipairs({ env_auth_value, http_auth_value, flag_auth_value }) do
      assert_no_secret(failed_err.message, secret, "the typed error")
      assert_no_secret(tostring(failed_err), secret, "the typed error string")
    end
  end)

  test("WheelAudit: records stay within 16 KiB and command previews are bounded", function()
    local dir = base .. "/bounds"
    local record_ok = WheelAudit.record({
      event = "process.pre_spawn",
      kind = "shell",
      shell = string.rep("A", 100000),
      intent = string.rep("B", 100000),
      decision = "allow",
    }, { dir = dir })
    check(record_ok == true, "an oversized event must be bounded, not rejected")

    local content = read_file(dir .. "/audit.jsonl") or ""
    local line = content:match("^([^\n]*)\n$")
    check(line ~= nil, "exactly one complete line must be written")
    check(#line <= WheelAudit.LIMITS.MAX_RECORD_BYTES,
      "one record must stay within the 16 KiB bound, got " .. tostring(#line))
    local record = JSON.decode(line)
    check(record.command_truncated == true, "the truncated command must be marked")
    check(#record.shell <= WheelAudit.LIMITS.MAX_COMMAND_BYTES,
      "the retained command preview must stay within its bound")
    check(#record.intent <= WheelAudit.LIMITS.MAX_INTENT_BYTES,
      "the retained intent must stay within its bound")
    check(record.seq == 1, "the bounded record must still carry its sequence")
  end)

  test("WheelAudit: rotation retains a bounded set of private files", function()
    local dir = base .. "/rotation"
    local limits = { max_file_bytes = 800, max_files = 3 }
    local sink = assert(WheelAudit.new({ dir = dir, limits = limits }))
    for index = 1, 15 do
      local ok, err = sink:record({
        event = "test.rotation",
        kind = "shell",
        shell = "printf record-" .. tostring(index),
        decision = "allow",
      })
      check(ok == true, "rotation record " .. tostring(index) .. " failed: " .. tostring(err))
    end

    check(file_mode(dir .. "/audit.jsonl") == "600", "the active file must stay 0600")
    check(file_mode(dir .. "/audit.1.jsonl") == "600", "rotated file 1 must stay 0600")
    check(file_mode(dir .. "/audit.2.jsonl") == "600", "rotated file 2 must stay 0600")
    check(file_mode(dir .. "/audit.3.jsonl") == nil,
      "retention must not create a file beyond max_files")
    for _, path in ipairs({ "audit.jsonl", "audit.1.jsonl", "audit.2.jsonl" }) do
      local content = read_file(dir .. "/" .. path) or ""
      check(#content <= limits.max_file_bytes,
        path .. " must stay within the rotation bound, got " .. tostring(#content))
    end
    check(record_bytes(dir, limits) <= limits.max_file_bytes * limits.max_files,
      "retained bytes must stay within the file-count bound")

    local verified, verify_err, verify_reason =
      WheelAudit.verify({ dir = dir, limits = limits })
    check(verified ~= nil, "the rotated chain must verify: " .. tostring(verify_reason)
      .. " " .. tostring(verify_err))
    check(verified.last_seq == 15, "the last sequence must survive rotation")
    check(verified.files == 3, "verify must inspect the three retained files")
  end)

  test("WheelAudit: a new sink continues the sequence and chain after restart", function()
    local dir = base .. "/restart"
    local limits = { max_file_bytes = 800, max_files = 3 }
    local first = assert(WheelAudit.new({ dir = dir, limits = limits }))
    check(first:record({ event = "test.restart", kind = "shell", shell = "printf 1",
      decision = "allow" }) == true, "the first sink must write")
    local second = assert(WheelAudit.new({ dir = dir, limits = limits }))
    check(second:record({ event = "test.restart", kind = "shell", shell = "printf 2",
      decision = "allow" }) == true, "the second sink must write")

    local records = parse_records(dir, limits)
    check(#records == 2, "both records must remain retained")
    check(records[2].seq == records[1].seq + 1,
      "a restart must not reset the sequence")
    check(records[2].prev == records[1].hash,
      "a restart must continue the previous-hash chain")
    local verified = assert(WheelAudit.verify({ dir = dir, limits = limits }))
    check(verified.last_seq == records[2].seq, "verify must see the continued sequence")
  end)

  test("WheelAudit: verify detects an edited retained record", function()
    local dir = base .. "/tamper"
    local ok, err = WheelAudit.record({
      event = "test.tamper",
      kind = "shell",
      shell = "printf tamper",
      decision = "allow",
    }, { dir = dir })
    check(ok == true, "the tamper baseline must write: " .. tostring(err))

    local content = read_file(dir .. "/audit.jsonl") or ""
    local edited, replacements = content:gsub('"decision":"allow"', '"decision":"deny"', 1)
    check(replacements == 1, "the fixture must contain one decision field")
    write_file(dir .. "/audit.jsonl", edited)

    local verified, verify_err, reason = WheelAudit.verify({ dir = dir })
    check(verified == nil, "an edited record must not verify")
    check(type(verify_err) == "table" and verify_err.code == WheelErrors.E_AUDIT_UNAVAILABLE,
      "a tampered record must return the typed audit failure")
    check(reason == "audit_corrupt", "a tampered record must report corruption")
  end)

  test("WheelAudit: middle corruption does not block append but verify detects it", function()
    local dir = base .. "/middle-corrupt"
    local sink = assert(WheelAudit.new({ dir = dir }))
    for index = 1, 3 do
      local ok, err = sink:record({
        event = "test.middle",
        kind = "shell",
        shell = "printf middle-" .. tostring(index),
        decision = "allow",
      })
      check(ok == true, "the baseline record must write: " .. tostring(err))
    end

    local content = read_file(dir .. "/audit.jsonl") or ""
    local edited, replacements = content:gsub('"decision":"allow"', '"decision":"deny"', 1)
    check(replacements == 1, "the middle fixture must contain one decision field")
    write_file(dir .. "/audit.jsonl", edited)

    -- Open-time recovery inspects only the tail, so the intact last line lets
    -- the next append proceed. The full verifier must still report the edited
    -- middle line.
    local restarted = assert(WheelAudit.new({ dir = dir }))
    local appended, append_err = restarted:record({
      event = "test.middle",
      kind = "shell",
      shell = "printf middle-4",
      decision = "allow",
    })
    check(appended == true, "an intact tail must allow the next append: " .. tostring(append_err))
    local verified, verify_err, reason = WheelAudit.verify({ dir = dir })
    check(verified == nil, "middle corruption must fail full verification")
    check(type(verify_err) == "table" and verify_err.code == WheelErrors.E_AUDIT_UNAVAILABLE,
      "middle corruption must return the typed audit failure")
    check(reason == "audit_corrupt", "middle corruption must report corruption")
  end)

  test("WheelAudit: a torn tail or corrupt line fails closed", function()
    local dir = base .. "/corrupt"
    local sink = assert(WheelAudit.new({ dir = dir }))
    check(sink:record({ event = "test.corrupt", kind = "shell", shell = "printf ok",
      decision = "allow" }) == true, "the baseline record must write")
    append_file(dir .. "/audit.jsonl", "{")

    local restarted = assert(WheelAudit.new({ dir = dir }))
    local ok, err, reason = restarted:record({
      event = "test.corrupt",
      kind = "shell",
      shell = "printf refused",
      decision = "allow",
    })
    check(ok == nil, "a torn tail must refuse the next append")
    check(type(err) == "table" and err.code == WheelErrors.E_AUDIT_UNAVAILABLE,
      "a torn tail must return the typed audit failure")
    check(reason == "audit_corrupt", "a torn tail must report the corrupt reason")
    check((read_file(dir .. "/audit.jsonl") or ""):sub(-1) == "{",
      "a refused append must not alter the file")
  end)

  test("WheelAudit: a symlinked audit directory is refused", function()
    local real = base .. "/real-audit"
    local link = base .. "/linked-audit"
    check(normalize_exit(os.execute("mkdir -p -- " .. shell_quote(real))) == 0,
      "cannot create the real audit directory")
    check(normalize_exit(os.execute(
      "ln -s -- " .. shell_quote(real) .. " " .. shell_quote(link))) == 0,
      "cannot create the audit symlink")

    local ok, err, reason = WheelAudit.record({
      event = "test.symlink",
      kind = "shell",
      shell = "printf refused",
      decision = "allow",
    }, { dir = link })
    check(ok == nil, "a symlinked directory must be refused")
    check(type(err) == "table" and err.code == WheelErrors.E_AUDIT_UNAVAILABLE,
      "the refusal must be the typed audit failure")
    check(reason == "audit_directory", "the refusal must name the directory reason")
    check(read_file(real .. "/audit.jsonl") == nil,
      "the sink must not write through the symlink")
  end)

  test("WheelAudit: an unsafe active audit file is refused", function()
    local mode_dir = base .. "/unsafe-mode"
    local mode_ok = WheelAudit.record({
      event = "test.unsafe",
      kind = "shell",
      shell = "printf unsafe",
      decision = "allow",
    }, { dir = mode_dir })
    check(mode_ok == true, "the mode baseline must write")
    local mode_file = mode_dir .. "/audit.jsonl"
    check(normalize_exit(os.execute("chmod 644 -- " .. shell_quote(mode_file))) == 0,
      "cannot weaken the audit file mode")

    local mode_sink = assert(WheelAudit.new({ dir = mode_dir }))
    local mode_written, mode_err, mode_reason = mode_sink:record({
      event = "test.unsafe",
      kind = "shell",
      shell = "printf refused",
      decision = "allow",
    })
    check(mode_written == nil, "a mode-0644 audit file must be refused")
    check(type(mode_err) == "table" and mode_err.code == WheelErrors.E_AUDIT_UNAVAILABLE,
      "the mode refusal must be the typed audit failure")
    check(mode_reason == "audit_file", "the mode refusal must name the file reason")

    local link_dir = base .. "/unsafe-link"
    local link_ok = WheelAudit.record({
      event = "test.unsafe",
      kind = "shell",
      shell = "printf link",
      decision = "allow",
    }, { dir = link_dir })
    check(link_ok == true, "the symlink baseline must write")
    local target = link_dir .. "/target.jsonl"
    local active = link_dir .. "/audit.jsonl"
    check(WheelHost.fs.write_file(target, "target-content"), "cannot create the link target")
    check(normalize_exit(os.execute("chmod 600 -- " .. shell_quote(target))) == 0,
      "cannot set the link target mode")
    check(normalize_exit(os.execute("rm -- " .. shell_quote(active))) == 0,
      "cannot remove the active audit file")
    check(normalize_exit(os.execute(
      "ln -s -- " .. shell_quote(target) .. " " .. shell_quote(active))) == 0,
      "cannot create the active audit symlink")

    local link_sink = assert(WheelAudit.new({ dir = link_dir }))
    local link_written, link_err, link_reason = link_sink:record({
      event = "test.unsafe",
      kind = "shell",
      shell = "printf refused",
      decision = "allow",
    })
    check(link_written == nil, "a symlinked audit file must be refused")
    check(type(link_err) == "table" and link_err.code == WheelErrors.E_AUDIT_UNAVAILABLE,
      "the symlink refusal must be the typed audit failure")
    check(link_reason == "audit_file", "the symlink refusal must name the file reason")
    check(read_file(target) == "target-content",
      "the sink must not write through the active symlink")
  end)

  test("WheelAudit: explicit and environment directory resolution is strict", function()
    check(WheelAudit.resolve_dir({ dir = "relative/audit" }) == nil,
      "a relative override must be refused")
    check(WheelAudit.resolve_dir({ dir = "/" }) == nil,
      "the filesystem root must not be an audit directory")
    check(WheelAudit.resolve_dir({ dir = "/synthetic/../audit" }) == nil,
      "an explicit override with '..' must be refused")

    local state = WheelAudit.resolve_dir({ env = { XDG_STATE_HOME = "/synthetic-state" } })
    check(state == "/synthetic-state/wheel/audit",
      "XDG_STATE_HOME must resolve to wheel/audit")
    local home = WheelAudit.resolve_dir({ env = { HOME = "/synthetic-home" } })
    check(home == "/synthetic-home/.local/state/wheel/audit",
      "HOME must resolve to .local/state/wheel/audit")
    check(WheelAudit.resolve_dir({ env = {} }) == nil,
      "no state base must fail closed")
    check(WheelAudit.resolve_dir({ env = { XDG_STATE_HOME = "relative" } }) == nil,
      "a relative XDG_STATE_HOME must fail closed instead of falling back")
    check(WheelAudit.resolve_dir({ env = { HOME = "relative" } }) == nil,
      "a relative HOME must fail closed")
  end)

  test("WheelHost: a high-risk spawn fails closed when the pre-spawn write fails", function()
    local blocked = base .. "/high-risk-blocked"
    write_file(blocked, "not a directory")
    local marker = base .. "/high-risk-marker"
    local result = WheelHost.proc.run_command("touch " .. shell_quote(marker), nil, {
      audit = {
        dir = blocked .. "/audit",
        role = "coding",
        high_risk = true,
        decision = "allow",
      },
    })
    check(result.ok == false, "a high-risk spawn must fail closed")
    check(result.spawned == false,
      "a refused high-risk spawn must report spawned=false")
    check(WheelHost.fs.exists(marker) == false,
      "the high-risk command must not run when its audit record cannot be written")
    check(type(result.audit_error) == "table"
      and result.audit_error.code == WheelErrors.E_AUDIT_UNAVAILABLE,
      "the refusal must carry the typed audit error")
    check(type(result.audit_error.message) == "string"
      and result.audit_error.message == "the audit record could not be written",
      "the typed error must carry only the static message")
    check(result.stderr:find(blocked, 1, true) == nil,
      "the refusal diagnostic must not leak the audit path")
  end)

  test("WheelHost: a non-high-risk spawn warns and continues", function()
    local blocked = base .. "/low-risk-blocked"
    write_file(blocked, "not a directory")
    local marker = base .. "/low-risk-marker"
    local result = WheelHost.proc.run_command("touch " .. shell_quote(marker), nil, {
      audit = {
        dir = blocked .. "/audit",
        high_risk = false,
        decision = "allow",
      },
    })
    check(result.ok == true and result.code == 0,
      "a non-high-risk command must continue after an audit failure")
    check(WheelHost.fs.exists(marker) == true,
      "the non-high-risk command must have run")
    check(type(result.audit_warning) == "string"
      and result.audit_warning:find("continuing", 1, true) ~= nil,
      "the result must carry a visible audit warning")
    check(result.audit_error == nil, "a continued command must not carry a fatal audit error")
  end)

  test("WheelHost: a completion audit failure warns without failing a launched command", function()
    local dir = base .. "/completion-failure"
    local saved_record = WheelAudit.record
    local calls = 0
    WheelAudit.record = function(event, opts)
      calls = calls + 1
      if calls == 2 then
        return nil, WheelErrors.audit_unavailable(), "write_failed"
      end
      return saved_record(event, opts)
    end
    local ok, result = pcall(WheelHost.proc.run_program, "true", {}, {
      audit = { dir = dir, decision = "allow", high_risk = true },
    })
    WheelAudit.record = saved_record

    check(ok, "the launched command must return a result: " .. tostring(result))
    check(result.ok == true and result.code == 0,
      "a completion audit failure must not change a successful command result")
    check(type(result.audit_warning) == "string"
      and result.audit_warning:find("completion", 1, true) ~= nil,
      "the result must warn about the completion record")
    check(type(result.audit_error) == "table"
      and result.audit_error.code == WheelErrors.E_AUDIT_UNAVAILABLE,
      "the result must carry the typed completion failure")
    check(calls == 2, "the seam must attempt exactly one pre-spawn and one completion record")
  end)

  test("WheelHost: a deny decision is recorded and never spawns", function()
    local dir = base .. "/denied"
    local marker = base .. "/denied-marker"
    local result = WheelHost.proc.run_command("touch " .. shell_quote(marker), nil, {
      audit = {
        dir = dir,
        role = "coding",
        tool = "run_command",
        intent = "denied probe",
        decision = "deny",
        reason = "destructive_command_blocked",
        high_risk = true,
      },
    })
    check(result.ok == false and result.denied == true,
      "the deny decision must return a denied result")
    check(WheelHost.fs.exists(marker) == false,
      "a denied command must not run")
    check(result.audit_error == nil, "a successful denial record must be written")

    local records = parse_records(dir)
    check(#records == 1, "a denial writes exactly one pre-spawn record")
    check(records[1].event == "process.pre_spawn" and records[1].decision == "deny",
      "the denial record must carry the deny decision")
    check(records[1].reason == "destructive_command_blocked",
      "the denial reason must be recorded")
    check(records[1].spawned == false, "the denial record must not claim a spawn")
    for _, record in ipairs(records) do
      check(record.event ~= "process.completed",
        "a denied command must not have a completion record")
    end
  end)

  test("WheelHost: a high-risk denial without an audit sink still does not spawn", function()
    local blocked = base .. "/deny-blocked"
    write_file(blocked, "not a directory")
    local marker = base .. "/deny-blocked-marker"
    local result = WheelHost.proc.run_command("touch " .. shell_quote(marker), nil, {
      audit = {
        dir = blocked .. "/audit",
        decision = "deny",
        reason = "destructive_command_blocked",
        high_risk = true,
      },
    })
    check(result.ok == false and result.denied == true,
      "the command must remain denied")
    check(WheelHost.fs.exists(marker) == false,
      "a denial must never spawn when its record cannot be written")
    check(type(result.audit_error) == "table",
      "the denial result must carry the audit failure")
  end)

  test("WheelHost: audit is opt-in and an invalid audit table fails before spawn", function()
    local marker = base .. "/opt-in-marker"
    local audit_calls = 0
    local saved_record = WheelAudit.record
    WheelAudit.record = function(...)
      audit_calls = audit_calls + 1
      return saved_record(...)
    end
    local plain_ok, plain = pcall(WheelHost.proc.run_program, "true", {}, {})
    WheelAudit.record = saved_record
    check(plain_ok and plain.ok == true, "a command without opts.audit must run")
    check(audit_calls == 0,
      "a command without opts.audit must not attempt an audit write")

    local invalid = WheelHost.proc.run_command("touch " .. shell_quote(marker), nil, {
      audit = "not-a-table",
    })
    check(invalid.ok == false, "a malformed audit option must fail closed")
    check(WheelHost.fs.exists(marker) == false,
      "a malformed audit option must fail before spawn")

    local runner_calls = 0
    local runner_audit = base .. "/runner-audit"
    local rejected = WheelHost.proc.run_command("ignored-command", {
      command_runner = function()
        runner_calls = runner_calls + 1
        return { success = true, exit_code = 0, stdout = "runner-double", stderr = "" }
      end,
    }, {
      audit = { dir = runner_audit },
    })
    check(rejected.ok == false, "audit with an injected command_runner must be rejected")
    check(runner_calls == 0, "the injected runner must not run when audit is requested")
    check(WheelHost.fs.exists(runner_audit) == false,
      "a rejected runner audit must not create an audit directory")
  end)

  test("WheelHost: non-boolean high_risk fails closed before audit or spawn", function()
    local blocked = base .. "/high-risk-type-blocked"
    write_file(blocked, "not a directory")
    for index, value in ipairs({ "true", 1 }) do
      local marker = base .. "/high-risk-type-marker-" .. tostring(index)
      local result = WheelHost.proc.run_command("touch " .. shell_quote(marker), nil, {
        audit = {
          dir = blocked .. "/audit",
          high_risk = value,
          decision = "allow",
        },
      })
      check(result.ok == false,
        "high_risk=" .. tostring(value) .. " must be rejected before spawn")
      check(result.spawned == false or result.spawned == nil,
        "a rejected high_risk value must not report a spawn")
      check(WheelHost.fs.exists(marker) == false,
        "a rejected high_risk value must not run the command")
      check(type(result.audit_error) == "table"
        and result.audit_error.code == WheelErrors.E_ARGS_INVALID,
        "the rejection must carry the typed E_ARGS_INVALID error")
      check(result.audit_error.message:find("high_risk", 1, true) ~= nil,
        "the typed error must name the high_risk field")
    end
    check(WheelHost.fs.exists(blocked .. "/audit") == false,
      "the rejected metadata must not create an audit directory")
  end)

  test("WheelHost: completion records exit, duration, truncation, and cleanup", function()
    local dir = base .. "/completion"
    local result = WheelHost.proc.run_program("printf", { "%s", "completion-ok" }, {
      cwd = base,
      audit = {
        dir = dir,
        role = "coding",
        agent = "completion-agent",
        task = "CTX-0030",
        tool = "run_program",
        intent = "completion probe",
        decision = "allow",
        high_risk = true,
      },
    })
    check(result.ok == true and result.code == 0, "the audited command must run")
    check(result.stdout == "completion-ok", "the command output must still be returned")
    check(result.audit_warning == nil and result.audit_error == nil,
      "a successful audit must not warn")

    local records = parse_records(dir)
    check(#records == 2, "the run must write a pre-spawn and a completion record")
    local pre, completed = records[1], records[2]
    check(pre.event == "process.pre_spawn" and completed.event == "process.completed",
      "the records must use the pre-spawn and completion event names")
    check(pre.seq == 1 and completed.seq == 2 and completed.prev == pre.hash,
      "completion must continue the chain")
    check(completed.exit_code == 0 and completed.spawned == true,
      "completion must record the exit and spawn state")
    check(type(completed.duration_ms) == "number" and completed.duration_ms >= 0,
      "completion must record a non-negative duration")
    check(completed.cleanup == WheelHost.GROUP_CLEANUP.SWEPT,
      "completion must record the group cleanup state")
    check(completed.truncated == false or completed.truncated == nil,
      "a small command must not be marked truncated")
    check(completed.command_hash == pre.command_hash,
      "pre-spawn and completion must share the command hash")
  end)

  test("WheelAudit: sequential writers in one process keep appends monotonic", function()
    local dir = base .. "/sequential"
    WheelAudit.reset()
    for index = 1, 3 do
      local ok, err = WheelAudit.record({
        event = "test.sequential",
        kind = "shell",
        shell = "printf sequential-" .. tostring(index),
        decision = "allow",
      }, { dir = dir })
      check(ok == true, "sequential append " .. tostring(index) .. " failed: " .. tostring(err))
    end
    local records = parse_records(dir)
    check(#records == 3, "all sequential records must be present")
    for index = 1, 3 do
      check(records[index].seq == index, "sequential sequence must increment")
      if index > 1 then
        check(records[index].prev == records[index - 1].hash,
          "sequential records must form one chain")
      end
    end
  end)

  test("WheelAudit: a non-private rotated path fails rotation closed", function()
    local dir = base .. "/rotation-blocked"
    local limits = { max_file_bytes = 800, max_files = 2 }
    local sink = assert(WheelAudit.new({ dir = dir, limits = limits }))
    check(sink:record({ event = "test.rotation", kind = "shell", shell = "printf first",
      decision = "allow" }) == true, "the first record must write")

    -- Replace the rotated target with a directory before the active file
    -- reaches the rotation bound. The sink must fail closed with a typed reason.
    check(normalize_exit(os.execute(
      "mkdir -- " .. shell_quote(dir .. "/audit.1.jsonl"))) == 0,
      "cannot create the blocked rotation target")
    local ok, err, reason = sink:record({
      event = "test.rotation",
      kind = "shell",
      shell = string.rep("c", 700),
      decision = "allow",
    })
    check(ok == nil, "rotation must fail closed on an unsafe target")
    check(type(err) == "table" and err.code == WheelErrors.E_AUDIT_UNAVAILABLE,
      "the rotation failure must be the typed audit error")
    check(reason == "rotation_failed", "the rotation failure must name its reason")
  end)
end

select_scratch_root()
select_base()

local ok, err = pcall(run_tests)
cleanup()
if not ok then
  failures = failures + 1
  print("[FAIL] audit suite: " .. tostring(err))
end

if failures > 0 then
  print(string.format("[FAIL] audit suite: %d failing test(s), %d checks", failures, checks))
  os.exit(1)
end

print(string.format("[PASS] audit suite: %d checks", checks))
os.exit(0)
