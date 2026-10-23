-- tests/test_cancel.lua
-- Gate 1/Gate 2 cancellation evidence for CTX-0034.
--
-- The suite runs the real standalone host seam and the real `scripts/wheel-proc`
-- CLI as a separate process. Every long command is started through
-- `WheelHost.proc.start`, cancelled by job id, and checked for a prompt terminal
-- result, no running child/grandchild, no signal to an unrelated recorded job,
-- idempotent repeat, typed after-exit no-op, and a timeout/cancel distinction.
-- The audit section uses a private explicit sink, reads the JSONL back, and
-- proves a high-risk cancellation is refused when the sink cannot be written.
--
-- Cleanup only targets recorded job handles or PIDs this test started. It never
-- kills by name or pattern.

package.path = "./lua/?.lua;./lua/?/init.lua;" .. package.path

local WheelHost = require("wheel.host")
local WheelKernel = require("wheel.kernel")
local WheelErrors = require("wheel.errors")

local JSON = WheelKernel.JSON

local checks = 0
local failures = 0
local base = nil
local job_root = nil
local handles = {}

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

local function check(condition, message)
  checks = checks + 1
  if not condition then
    error("cancel assertion failed: " .. tostring(message), 0)
  end
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

local function remove_tree(path)
  local cleanup_root = base and (base .. ".cleanup") or "/tmp/bitty"
  local backend = WheelHost.create_backend("standalone", { tmp_root = cleanup_root })
  local removed = backend.run_program("rm", { "-rf", path })
  return removed.ok and removed.code == 0
end

local function start(program, args, opts)
  local handle, err = WheelHost.proc.start(program, args, opts)
  if not handle then
    local code = type(err) == "table" and err.code or "nil"
    local message = type(err) == "table" and err.message or tostring(err)
    error("start failed: " .. tostring(code) .. " " .. tostring(message), 0)
  end
  handles[#handles + 1] = handle
  return handle
end

local function cli(args)
  local result = WheelHost.proc.run_program("scripts/wheel-proc", args, {
    timeout_ms = 10000,
  })
  local record = nil
  if type(result.stdout) == "string" and result.stdout ~= "" then
    local ok, decoded = pcall(JSON.decode, result.stdout)
    if ok then
      record = decoded
    end
  end
  return normalize_exit(result.code), record, result
end

local function process_state(pid)
  local probe = WheelHost.proc.run_program("ps", { "-o", "stat=", "-p", tostring(pid) }, {
    discard_stderr = true,
  })
  if probe.code ~= 0 then
    return nil
  end
  return (probe.stdout or ""):match("^%s*(%S+)")
end

local function wait_gone(pid, label)
  for _ = 1, 100 do
    local state = process_state(pid)
    if state == nil or state:sub(1, 1) == "Z" then
      return
    end
    WheelHost.time.sleep_ms(20)
  end
  local state = process_state(pid)
  error(label .. " is still running: " .. tostring(state), 0)
end

local function recorded_pid(path)
  local raw = read_file(path)
  if type(raw) ~= "string" then
    return nil
  end
  return tonumber(raw:match("^%s*(%d+)%s*$"))
end

local function fake_job(id, meta)
  local dir = job_root .. "/" .. id
  local created = WheelHost.fs.mkdir(dir)
  check(created, "cannot create the fabricated job directory")
  if meta then
    local content = meta
    if content:sub(-1) ~= "\n" then
      content = content .. "\n"
    end
    local wrote = WheelHost.fs.create_private_file(dir .. "/job.meta", content)
    check(wrote, "cannot write the fabricated job metadata")
  end
  return dir
end

local function job_meta(id)
  return read_file(job_root .. "/" .. id .. "/job.meta") or ""
end

local function parse_audit(dir)
  local content = read_file(dir .. "/audit.jsonl")
  check(type(content) == "string" and content ~= "", "the audit stream must exist")
  local records = {}
  for line in content:gmatch("([^\n]+)") do
    local record = JSON.decode(line)
    check(type(record) == "table", "every audit line must decode")
    records[#records + 1] = record
  end
  return records
end

local function find_event(records, name)
  for _, record in ipairs(records) do
    if record.event == name then
      return record
    end
  end
  return nil
end

local function main()
  check(WheelHost.backend_name == "standalone", "the cancellation suite requires the standalone backend")
  check(type(WheelHost.proc.start) == "function", "WheelHost.proc.start must be exposed")
  check(type(WheelHost.proc.cancel_job) == "function", "WheelHost.proc.cancel_job must be exposed")

  local created = WheelHost.proc.run_program("mktemp", {
    "-d", "-p", os.getenv("WHEEL_TEST_TMP") or "/tmp/bitty", "wheel-cancel.XXXXXX",
  })
  check(created.ok and created.code == 0, "cannot create the cancellation scratch base")
  base = (created.stdout or ""):match("^%s*(.-)%s*$")
  check(type(base) == "string" and base:sub(1, 1) == "/", "the scratch base must be absolute")
  job_root = base .. "/jobs"
  check(WheelHost.fs.mkdir_p(job_root), "cannot create the job root")

  local child_pid = base .. "/child.pid"
  local grandchild_pid = base .. "/grandchild.pid"
  local cancelled_marker = base .. "/cancelled-marker"

  -- 1. Cancel during execution from a separate process. A second recorded job
  -- is the unrelated-process sentinel.
  local sentinel = start("sleep", { "30" }, {
    timeout_ms = 60000,
    job_root = job_root,
  })
  local sentinel_pgid = sentinel:pgid()
  check(type(sentinel_pgid) == "number" and sentinel_pgid > 1,
    "the sentinel must record its process group")

  local target = start("sh", {
    "-c",
    "echo $$ > " .. shell_quote(child_pid)
      .. "; sleep 30 & echo $! > " .. shell_quote(grandchild_pid)
      .. "; wait",
  }, { timeout_ms = 60000, job_root = job_root })
  local target_pgid = target:pgid()
  local target_id = target:job_id()
  check(target_id:match("^[0-9a-f]+$") ~= nil and #target_id == 32,
    "the job id must be a 32-hex token")
  check(target_id ~= sentinel:job_id(), "jobs must have distinct ids")
  check(target:job_root() == job_root, "the handle must expose the job root")

  local started_seconds = os.time()
  local cli_status, cli_record, cli_run = cli({
    "cancel", target_id, "--root", job_root,
  })
  check(cli_status == 0, "the cancellation CLI must accept the request: "
    .. tostring(cli_run.stderr))
  check(type(cli_record) == "table", "the CLI must emit one JSON result")
  check(cli_record.state == "requested", "the first request must be reported as requested")
  check(cli_record.terminal_reason == "cancelled", "the CLI must publish a cancelled terminal reason")
  check(cli_record.term_sent == true, "the CLI must record the TERM it sent")
  check(cli_record.pgid == target_pgid, "the CLI must report the recorded PGID")

  local result = target:wait(5000)
  check(result ~= nil, "the cancelled job must reach a terminal result")
  check(result.outcome == WheelHost.PROCESS_OUTCOME.CANCELLED,
    "cancellation must have a distinct typed outcome: " .. tostring(result.outcome))
  check(result.cancel_requested == true, "the result must carry cancel_requested")
  check(result.terminal_reason == "cancelled", "the result must carry the cancelled terminal reason")
  check(result.timed_out == false, "cancellation must not be reported as a timeout")
  check(result.code == 143 or result.code == 137,
    "a cancelled command must carry a signal-derived status: " .. tostring(result.code))
  check(result.cleanup == WheelHost.GROUP_CLEANUP.SWEPT,
    "cancellation must sweep the recorded group: " .. tostring(result.cleanup))
  check(os.time() - started_seconds < 10,
    "cancellation must complete well before the 60 s command timeout")

  local child = recorded_pid(child_pid)
  local grandchild = recorded_pid(grandchild_pid)
  check(child ~= nil and grandchild ~= nil,
    "the command must record its child and grandchild PIDs")
  wait_gone(child, "cancelled child")
  wait_gone(grandchild, "cancelled grandchild")
  check(read_file(cancelled_marker) == nil, "the cancelled command must not run its final marker")

  -- The unrelated recorded job must still be running. This check would fail
  -- if cancellation targeted a name, the caller's group, or another job.
  check(sentinel:poll() == nil, "cancellation must not terminate an unrelated job")
  check(process_state(sentinel_pgid) ~= nil,
    "the unrelated job's recorded group must still be alive")
  check(sentinel_pgid ~= target_pgid, "the sentinel and target groups must differ")

  -- 2. Repeated cancellation is idempotent and a no-op after the terminal state.
  local repeat_status, repeat_record = cli({
    "cancel", target_id, "--root", job_root,
  })
  check(repeat_status == 0, "a repeated cancellation must be accepted")
  check(repeat_record.state == "already_cancelled",
    "a repeated cancellation must report already_cancelled: " .. tostring(repeat_record.state))
  check(repeat_record.terminal_reason == "cancelled",
    "a repeated cancellation must keep the cancelled reason")
  check(repeat_record.term_sent == false, "a repeated cancellation must not claim a new TERM")

  -- 3. Cancel after a normal exit is a typed no-op, not a signal.
  local short = start("true", {}, { timeout_ms = 5000, job_root = job_root })
  local short_result = short:wait(5000)
  check(short_result ~= nil and short_result.outcome == WheelHost.PROCESS_OUTCOME.EXITED,
    "the short command must exit normally")
  check(short_result.terminal_reason == "exited", "a normal exit must publish its terminal reason")
  check(short_result.cancel_requested == false, "a normal exit must not claim cancellation")
  local after_status, after_record = cli({
    "cancel", short:job_id(), "--root", job_root,
  })
  check(after_status == 3, "cancel-after-exit must exit with the typed no-op status")
  check(after_record.state == "already_exited", "cancel-after-exit must report already_exited")
  check(after_record.terminal_reason == "exited", "cancel-after-exit must report the exit reason")
  check(after_record.term_sent == false, "cancel-after-exit must not signal")

  -- 4. Timeout and cancellation remain distinct.
  local timed = start("sleep", { "30" }, { timeout_ms = 300, job_root = job_root })
  local timed_result = timed:wait(5000)
  check(timed_result ~= nil, "the timeout job must reach a result")
  check(timed_result.outcome == WheelHost.PROCESS_OUTCOME.TIMEOUT,
    "the timeout job must keep the timeout outcome")
  check(timed_result.timed_out == true, "the timeout job must set timed_out")
  check(timed_result.cancel_requested == false, "a timeout must not claim cancellation")
  check(timed_result.terminal_reason == "timeout", "a timeout must publish its terminal reason")
  check(timed_result.cleanup == WheelHost.GROUP_CLEANUP.SWEPT,
    "a timeout must still sweep the recorded group")
  check(timed_result.code == 124 or timed_result.code == 137,
    "a timeout must keep the timeout status mapping")
  local timeout_status, timeout_record = cli({
    "cancel", timed:job_id(), "--root", job_root,
  })
  check(timeout_status == 3, "cancel-after-timeout must be a typed no-op")
  check(timeout_record.state == "already_exited", "cancel-after-timeout must report already_exited")
  check(timeout_record.terminal_reason == "timeout", "cancel-after-timeout must report timeout")

  -- 4b. A cancellation racing the command timeout must produce exactly one
  -- terminal reason, never both flags.
  local raced = start("sleep", { "30" }, { timeout_ms = 500, job_root = job_root })
  local raced_ok, raced_info = raced:cancel()
  check(raced_ok == true and type(raced_info) == "table",
    "the racing cancellation must be accepted or a typed no-op")
  local raced_result = raced:wait(5000)
  check(raced_result ~= nil, "the cancellation/timeout race must reach a result")
  if raced_result.terminal_reason == "cancelled" then
    check(raced_result.cancel_requested == true and raced_result.timed_out == false,
      "the cancellation winner must not also claim a timeout")
  else
    check(raced_result.terminal_reason == "timeout",
      "the timeout winner must publish the timeout reason")
    check(raced_result.timed_out == true and raced_result.cancel_requested == false,
      "the timeout winner must not also claim cancellation")
  end
  check(raced_result.cleanup == WheelHost.GROUP_CLEANUP.SWEPT,
    "the cancellation/timeout race must still sweep the recorded group")

  -- 5. Cancel before spawn refuses without a signal.
  local missing_status, missing_record = cli({
    "cancel", string.rep("0", 32), "--root", job_root,
  })
  check(missing_status == 4, "a missing job must be refused")
  check(missing_record.error.code == WheelErrors.E_JOB_NOT_FOUND,
    "a missing job must report E_JOB_NOT_FOUND")

  local unstarted_id = string.rep("1", 32)
  fake_job(unstarted_id)
  local unstarted_status, unstarted_record = cli({
    "cancel", unstarted_id, "--root", job_root,
  })
  check(unstarted_status == 4, "a job without metadata must be refused")
  check(unstarted_record.error.code == WheelErrors.E_JOB_NOT_RUNNING,
    "an unpublished job must report E_JOB_NOT_RUNNING")

  local starting_id = string.rep("2", 32)
  fake_job(starting_id, table.concat({
    "format=wheel-job/1",
    "job_id=" .. starting_id,
    "generation=" .. string.rep("3", 32),
    "state=starting",
    "pgid=1",
    "leader_pid=1",
    "timeout_ms=1000",
    "started_ms=1",
  }, "\n"))
  local starting_status, starting_record = cli({
    "cancel", starting_id, "--root", job_root,
  })
  check(starting_status == 4, "a pre-spawn job must be refused")
  check(starting_record.error.code == WheelErrors.E_JOB_NOT_RUNNING,
    "a pre-spawn job must report E_JOB_NOT_RUNNING")

  local invalid_status, invalid_record = cli({
    "cancel", "../../escape", "--root", job_root,
  })
  check(invalid_status == 4, "an invalid job id must be refused")
  check(invalid_record.error.code == WheelErrors.E_JOB_METADATA_INVALID,
    "an invalid job id must report E_JOB_METADATA_INVALID")

  -- 6. A forged generation/foreign PID must be refused and must not signal.
  local sentinel_meta = job_meta(sentinel:job_id())
  local sentinel_generation = sentinel_meta:match("\ngeneration=([0-9a-f]+)")
  check(sentinel_generation ~= nil, "the sentinel metadata must carry a generation")
  local forged_id = string.rep("4", 32)
  fake_job(forged_id, table.concat({
    "format=wheel-job/1",
    "job_id=" .. forged_id,
    "generation=" .. string.rep("5", 32),
    "state=running",
    "pgid=" .. tostring(sentinel_pgid),
    "leader_pid=" .. tostring(sentinel_pgid),
    "timeout_ms=60000",
    "started_ms=1",
  }, "\n"))
  local forged_status, forged_record = cli({
    "cancel", forged_id, "--root", job_root,
  })
  check(forged_status == 4, "a forged generation must be refused")
  check(forged_record.error.code == WheelErrors.E_JOB_GENERATION_MISMATCH,
    "a forged generation must report E_JOB_GENERATION_MISMATCH")
  check(sentinel:poll() == nil, "the forged request must not signal the sentinel")
  check(process_state(sentinel_pgid) ~= nil, "the sentinel group must still be alive after a forgery")

  -- A valid generation copied into a record whose PGID/PID points at the test
  -- process (which is not a session leader) must fail the group/session
  -- identity check even though the generation text matches.
  local mismatch_id = string.rep("6", 32)
  local test_pid = WheelHost.proc.pid()
  check(type(test_pid) == "number" and test_pid > 1, "the test process id must be readable")
  fake_job(mismatch_id, table.concat({
    "format=wheel-job/1",
    "job_id=" .. mismatch_id,
    "generation=" .. sentinel_generation,
    "state=running",
    "pgid=" .. tostring(test_pid),
    "leader_pid=" .. tostring(test_pid),
    "timeout_ms=60000",
    "started_ms=1",
  }, "\n"))
  local mismatch_status = cli({ "cancel", mismatch_id, "--root", job_root })
  check(mismatch_status == 4, "a copied generation must not authorize a stale record")
  check(sentinel:poll() == nil, "a stale record must not signal a live job")

  -- 7. The in-process handle cancellation path.
  local handled = start("sleep", { "30" }, { timeout_ms = 60000, job_root = job_root })
  local cancel_ok, cancel_info = handled:cancel()
  check(cancel_ok == true, "the handle cancel path must accept the request")
  check(cancel_info.state == "requested", "the handle cancel path must report requested")
  local handled_result = handled:wait(5000)
  check(handled_result ~= nil and handled_result.outcome == WheelHost.PROCESS_OUTCOME.CANCELLED,
    "the handle cancel path must produce a cancelled result")
  check(handled_result.cancel_requested == true, "the handle result must carry cancel_requested")
  local repeat_ok, repeat_info = handled:cancel()
  check(repeat_ok == true and repeat_info.state == "already_cancelled",
    "the handle repeated cancel must be idempotent")

  -- 7b. The shell-string start path shares the same record and cancellation
  -- discipline; it is a distinct primitive from the argv handle above.
  local shell_job, shell_start_err = WheelHost.proc.start_command("sleep 30", {
    timeout_ms = 60000,
    job_root = job_root,
  })
  check(shell_job ~= nil, "the shell-string job must start: " .. tostring(shell_start_err))
  handles[#handles + 1] = shell_job
  local shell_cancel_ok, shell_cancel_info = shell_job:cancel()
  check(shell_cancel_ok == true and shell_cancel_info.state == "requested",
    "the shell-string handle cancel must be accepted")
  local shell_result = shell_job:wait(5000)
  check(shell_result ~= nil and shell_result.outcome == WheelHost.PROCESS_OUTCOME.CANCELLED,
    "the shell-string handle must produce a cancelled result")
  check(shell_result.cancel_requested == true and shell_result.timed_out == false,
    "the shell-string cancellation must be distinct from timeout")
  check(shell_result.cleanup == WheelHost.GROUP_CLEANUP.SWEPT,
    "the shell-string cancellation must sweep the recorded group")

  -- 8. Audit request/outcome records and the high-risk failure policy.
  local audit_dir = base .. "/audit"
  local audited = start("sleep", { "30" }, {
    timeout_ms = 60000,
    job_root = job_root,
    audit = {
      dir = audit_dir,
      role = "coding",
      agent = "cancel-suite",
      task = "CTX-0034",
      tool = "start",
      intent = "cancellation audit",
      high_risk = true,
    },
  })
  local audited_id = audited:job_id()
  local audited_generation = job_meta(audited_id):match("\ngeneration=([0-9a-f]+)")
  local audit_status, audit_record = cli({
    "cancel", audited_id, "--root", job_root,
  })
  check(audit_status == 0, "the audited cancellation must be accepted")
  check(audit_record.audit_warning == nil, "the audited cancellation must not warn")
  local audited_result = audited:wait(5000)
  check(audited_result ~= nil and audited_result.outcome == WheelHost.PROCESS_OUTCOME.CANCELLED,
    "the audited job must be cancelled")
  local records = parse_audit(audit_dir)
  local pre = find_event(records, "process.pre_spawn")
  local request = find_event(records, "process.cancel_requested")
  local outcome = find_event(records, "process.cancel_outcome")
  local completed = find_event(records, "process.completed")
  check(pre ~= nil and request ~= nil and outcome ~= nil and completed ~= nil,
    "the audit stream must carry pre-spawn, request, outcome, and completion records")
  check(request.cancel_requested == true and request.job_id == audited_id,
    "the request record must carry the job and cancellation state")
  check(outcome.terminal_reason == "cancelled" and outcome.outcome == "cancelled",
    "the outcome record must carry the cancelled terminal reason")
  check(completed.cancel_requested == true and completed.outcome == "cancelled",
    "the completion record must preserve cancellation")
  local previous = string.rep("0", 64)
  for _, record in ipairs(records) do
    check(record.prev == previous, "the audit chain must continue across CLI and harness writers")
    previous = record.hash
  end
  local audit_raw = read_file(audit_dir .. "/audit.jsonl") or ""
  check(audited_generation ~= nil and audit_raw:find(audited_generation, 1, true) == nil,
    "the audit stream must never record the generation token")

  -- A high-risk cancellation whose audit sink cannot be written is refused
  -- before any signal; the job then reaches its own timeout.
  local blocked_audit = base .. "/blocked-audit"
  local blocked = start("sleep", { "30" }, {
    timeout_ms = 1000,
    job_root = job_root,
    audit = { dir = blocked_audit, high_risk = true },
  })
  check(remove_tree(blocked_audit), "cannot remove the valid audit fixture directory")
  check(WheelHost.fs.write_file(blocked_audit, "not a directory"),
    "cannot create the blocked audit path")
  local blocked_status, blocked_record = cli({
    "cancel", blocked:job_id(), "--root", job_root,
  })
  check(blocked_status == 4, "a high-risk cancellation without audit must be refused")
  check(blocked_record.error.code == WheelErrors.E_AUDIT_UNAVAILABLE,
    "the refusal must carry the typed audit error")
  check(blocked:poll() == nil, "the refused cancellation must not signal the job")
  local blocked_result = blocked:wait(5000)
  check(blocked_result ~= nil and blocked_result.outcome == WheelHost.PROCESS_OUTCOME.TIMEOUT,
    "the refused job must run to its own timeout")
  check(blocked_result.cancel_requested == false,
    "the refused job must not be marked cancelled")

  -- 9. Close every handle and remove the scratch base.
  for _, handle in ipairs(handles) do
    local result = handle:poll()
    if result == nil then
      local ok, info = handle:cancel()
      check(ok == true, "cleanup cancel must be accepted: " .. tostring(info))
      result = handle:wait(5000)
    end
    if result ~= nil then
      local closed = handle:close()
      check(closed == true, "every terminal handle must close")
    end
  end
  check(remove_tree(base), "cannot remove the cancellation scratch base")
  os.execute("rmdir " .. shell_quote(base .. ".cleanup") .. " 2>/dev/null || :")
  print(string.format("[PASS] cancellation suite: %d checks", checks))
end

local ok, err = pcall(main)
if not ok then
  io.stderr:write("[FAIL] cancellation suite: " .. tostring(err) .. "\n")
  for _, handle in ipairs(handles) do
    pcall(function()
      local result = handle:poll()
      if result == nil then
        handle:cancel()
        handle:wait(3000)
      end
      handle:close()
    end)
  end
  if base and base:sub(1, 1) == "/" then
    remove_tree(base)
  end
  os.exit(1)
end
os.exit(0)
