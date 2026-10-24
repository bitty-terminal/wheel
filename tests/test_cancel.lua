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
local WheelJob = require("wheel.job")
local WheelKernel = require("wheel.kernel")
local WheelErrors = require("wheel.errors")

local JSON = WheelKernel.JSON

local checks = 0
local failures = 0
local scratch_root = nil
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

local function wait_for_file(path, label)
  for _ = 1, 100 do
    if read_file(path) ~= nil then
      return
    end
    WheelHost.time.sleep_ms(20)
  end
  error(label .. " was not written", 0)
end

local function within_scratch(path)
  if type(path) ~= "string" or type(scratch_root) ~= "string" then
    return false
  end
  if path:sub(1, #scratch_root + 1) ~= scratch_root .. "/" then
    return false
  end
  return path:find("%.%.") == nil
end

local function remove_tree(path)
  if not within_scratch(path) then
    return false
  end
  return normalize_exit(os.execute("rm -rf -- " .. shell_quote(path))) == 0
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

local function find_foreign_pid()
  local euid = WheelHost.fs.euid()
  if euid == nil then
    return nil
  end
  local probe = WheelHost.proc.run_program("ps", { "-eo", "pid=,uid=" }, {
    discard_stderr = true,
  })
  if not probe.ok or probe.code ~= 0 then
    return nil
  end
  local chosen = nil
  for line in (probe.stdout or ""):gmatch("[^\n]+") do
    local pid, uid = line:match("^%s*(%d+)%s+(%d+)")
    local number = tonumber(pid)
    if number and number > 1 and tonumber(uid) ~= euid
      and (chosen == nil or number < chosen) then
      chosen = number
    end
  end
  return chosen
end

-- Find a process group whose members are all owned by another user, so a
-- signal-0 probe exercises the EPERM branch without signalling anyone.
local function find_foreign_group()
  local euid = WheelHost.fs.euid()
  if euid == nil or euid == 0 then
    return nil
  end
  local probe = WheelHost.proc.run_program("ps", { "-eo", "pid=,uid=,pgid=" }, {
    discard_stderr = true,
  })
  if not probe.ok or probe.code ~= 0 then
    return nil
  end
  local groups = {}
  for line in (probe.stdout or ""):gmatch("[^\n]+") do
    local pid, uid, pgid = line:match("^%s*(%d+)%s+(%d+)%s+(%d+)")
    local group = tonumber(pgid)
    if pid and group and group > 1 then
      if groups[group] == nil then
        groups[group] = tonumber(uid) ~= euid
      elseif tonumber(uid) == euid then
        groups[group] = false
      end
    end
  end
  local chosen = nil
  for group, foreign in pairs(groups) do
    if foreign and (chosen == nil or group < chosen) then
      chosen = group
    end
  end
  return chosen
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

local function wait_leader_gone(handle, label)
  local pgid = handle:pgid()
  for _ = 1, 100 do
    if not WheelHost.proc.is_alive(pgid) then
      return
    end
    WheelHost.time.sleep_ms(20)
  end
  error(label .. " retained leader is still running", 0)
end

local function wait_no_process_with(fragment, label)
  for _ = 1, 150 do
    local probe = WheelHost.proc.run_program("ps", { "-ww", "-eo", "args=" }, {
      discard_stderr = true,
    })
    local found = false
    if probe.ok and probe.code == 0 then
      for line in (probe.stdout or ""):gmatch("[^\n]+") do
        if line:find(fragment, 1, true) then
          found = true
          break
        end
      end
    end
    if not found then
      return
    end
    WheelHost.time.sleep_ms(20)
  end
  error(label .. " is still running", 0)
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

  local missing_ok, missing_reason = WheelHost.proc.signal_group(2147483000, "0")
  check(missing_ok == false and missing_reason == "no such process group",
    "a missing process group must be reported as absent, got "
      .. tostring(missing_ok) .. "/" .. tostring(missing_reason))

  local foreign_group = find_foreign_group()
  if foreign_group ~= nil then
    local foreign_ok, foreign_reason = WheelHost.proc.signal_group(foreign_group, "0")
    check(foreign_ok == false and foreign_reason == "permission denied",
      "a foreign process group must be reported as denied, got "
        .. tostring(foreign_ok) .. "/" .. tostring(foreign_reason))
  else
    print("[INFO] no foreign-owned process group available; EPERM probe not exercised")
  end

  local created = WheelHost.proc.run_program("mktemp", {
    "-d", "--", scratch_root .. "/wheel-cancel.XXXXXX",
  })
  check(created.ok and created.code == 0, "cannot create the cancellation scratch base")
  base = (created.stdout or ""):match("^%s*(.-)%s*$")
  check(type(base) == "string" and base:sub(1, 1) == "/", "the scratch base must be absolute")
  check(within_scratch(base), "the cancellation base must live under the scratch root")
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
      .. "; sleep 30 & bg=$!; echo $bg > " .. shell_quote(grandchild_pid)
      .. "; wait $bg; [ $? -eq 0 ] && : > " .. shell_quote(cancelled_marker),
  }, { timeout_ms = 60000, job_root = job_root })
  local target_pgid = target:pgid()
  local target_id = target:job_id()
  check(target_id:match("^[0-9a-f]+$") ~= nil and #target_id == 32,
    "the job id must be a 32-hex token")
  check(target_id ~= sentinel:job_id(), "jobs must have distinct ids")
  check(target:job_root() == job_root, "the handle must expose the job root")
  wait_for_file(child_pid, "target child pid")
  wait_for_file(grandchild_pid, "target grandchild pid")

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
  check(cli_record.group_alive_after == false,
    "the CLI must observe the recorded group gone after cancellation")
  check(cli_record.pgid == target_pgid, "the CLI must report the recorded PGID")

  local result = target:wait(5000)
  check(result ~= nil, "the cancelled job must reach a terminal result")
  check(result.outcome == WheelHost.PROCESS_OUTCOME.CANCELLED,
    "cancellation must have a distinct typed outcome: " .. tostring(result.outcome)
      .. " (terminal=" .. tostring(result.terminal_reason)
      .. ", cleanup=" .. tostring(result.cleanup)
      .. ", code=" .. tostring(result.code) .. ")")
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

  -- 1b. A refused TERM must be a typed failure and must not publish a
  -- cancelled terminal reason.
  local refused = start("sleep", { "30" }, { timeout_ms = 60000, job_root = job_root })
  local refused_id = refused:job_id()
  local real_signal_group = WheelHost.proc.signal_group
  WheelHost.proc.signal_group = function(pgid, sig)
    if sig == "TERM" then
      return false, "no such process group"
    end
    return real_signal_group(pgid, sig)
  end
  local refusal_ok, refusal_err = refused:cancel()
  WheelHost.proc.signal_group = real_signal_group
  check(refusal_ok == nil and type(refusal_err) == "table",
    "a refused TERM must be a typed failure")
  check(refusal_err.code == WheelErrors.E_JOB_NOT_RUNNING,
    "a vanished group after validation must report E_JOB_NOT_RUNNING")
  check(not WheelHost.fs.stat(job_root .. "/" .. refused_id .. "/terminal").exists,
    "a refused TERM must not publish a cancelled terminal")
  local refused_cancel_ok, refused_info = refused:cancel()
  check(refused_cancel_ok == true and refused_info.state == "requested",
    "the refused job must be cancellable after the probe is restored")
  check(refused:wait(5000) ~= nil, "the refused job must reach a terminal result")

  -- 1c. CI observed GNU timeout's 124 sentinel in the retained leader's status
  -- for a cancelled job. The cancellation evidence must map that sentinel to
  -- the TERM-derived 143 instead of leaking a timeout code.
  local timeout_sentinel = start("sleep", { "30" }, {
    timeout_ms = 60000,
    job_root = job_root,
  })
  local sentinel_cancel_ok, sentinel_cancel_info = timeout_sentinel:cancel()
  check(sentinel_cancel_ok == true and sentinel_cancel_info.term_sent == true,
    "the 124-mapping job must receive a TERM")
  wait_leader_gone(timeout_sentinel, "124-mapping job")
  local sentinel_status_path = job_root .. "/" .. timeout_sentinel:job_id() .. "/status"
  check(WheelHost.fs.write_file(sentinel_status_path, "124"),
    "cannot synthesize the timeout sentinel status")
  local sentinel_result = timeout_sentinel:wait(1000)
  check(sentinel_result ~= nil and sentinel_result.code == 143,
    "a cancelled 124 sentinel must map to 143, got "
      .. tostring(sentinel_result and sentinel_result.code))
  check(sentinel_result.outcome == WheelHost.PROCESS_OUTCOME.CANCELLED
    and sentinel_result.timed_out == false,
    "the 124-mapped result must remain a cancellation, not a timeout")

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

  -- 2b. A stale transition lock must not defeat terminal idempotency or be
  -- removed by the repeat request.
  local stale_lock = job_root .. "/" .. target_id .. "/lock"
  check(WheelHost.fs.mkdir(stale_lock), "cannot create the stale-lock fixture")
  local stale_status, stale_record = cli({
    "cancel", target_id, "--root", job_root,
  })
  check(stale_status == 0, "a repeated cancellation must ignore a stale lock")
  check(stale_record.state == "already_cancelled",
    "a stale lock must not change the terminal no-op: " .. tostring(stale_record.state))
  check(WheelHost.fs.stat(stale_lock).exists,
    "a repeated cancellation must not remove a foreign/stale lock")
  check(WheelHost.fs.remove_dir(stale_lock), "cannot remove the stale-lock fixture")

  -- 2c. A leader that cannot acquire the terminal lock must not publish a
  -- terminal reason or remove the lock it did not acquire. Hold the lock while
  -- a short command exits; the leader's bounded wait (2 s) expires first.
  local lock_job = start("sleep", { "0.5" }, {
    timeout_ms = 10000,
    job_root = job_root,
  })
  local lock_job_dir = job_root .. "/" .. lock_job:job_id()
  local held_lock = lock_job_dir .. "/lock"
  local held_terminal = lock_job_dir .. "/terminal"
  check(WheelHost.fs.mkdir(held_lock), "cannot create the leader-contention lock")
  WheelHost.time.sleep_ms(2500)
  check(not WheelHost.fs.stat(held_terminal).exists,
    "a leader without the lock must not publish a terminal reason")
  check(WheelHost.fs.stat(held_lock).exists,
    "a leader without the lock must not remove the held lock")
  check(WheelHost.fs.remove_dir(held_lock), "cannot release the held lock")
  local lock_result = lock_job:wait(5000)
  local lock_cancel_ok, lock_cancel_info = lock_job:cancel()
  check(lock_cancel_ok == true,
    "the contention job cancel must be a typed no-op or request: "
      .. tostring(lock_cancel_info))
  if lock_result == nil then
    lock_result = lock_job:wait(5000)
  end
  check(lock_result ~= nil, "the contention job must still reach a result")

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

  -- A record whose PID belongs to another user must be refused by the owner
  -- check before any audit or signal. Only a same-user process can be signalled
  -- in this test environment, so use an existing foreign-owned PID.
  local foreign_pid = find_foreign_pid()
  if foreign_pid ~= nil then
    local foreign_id = string.rep("7", 32)
    fake_job(foreign_id, table.concat({
      "format=wheel-job/1",
      "job_id=" .. foreign_id,
      "generation=" .. sentinel_generation,
      "state=running",
      "pgid=" .. tostring(foreign_pid),
      "leader_pid=" .. tostring(foreign_pid),
      "timeout_ms=60000",
      "started_ms=1",
    }, "\n"))
    local foreign_status, foreign_record = cli({
      "cancel", foreign_id, "--root", job_root,
    })
    check(foreign_status == 4, "a foreign-owner PID must be refused")
    check(foreign_record.error.code == WheelErrors.E_JOB_GENERATION_MISMATCH,
      "a foreign-owner PID must report E_JOB_GENERATION_MISMATCH")
  else
    print("[INFO] no foreign-owner process available; foreign-UID refusal not exercised")
  end

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

  -- 7a. A TERM-ignoring direct child must deterministically escalate to KILL.
  local stubborn = start("sh", {
    "-c",
    "trap '' TERM; while sleep 1; do :; done",
  }, { timeout_ms = 60000, job_root = job_root })
  local stubborn_ok, stubborn_info = stubborn:cancel()
  check(stubborn_ok == true and stubborn_info.state == "requested",
    "the TERM-ignoring job cancel must be accepted")
  check(stubborn_info.kill_sent == true,
    "the TERM-ignoring job must receive the KILL escalation")
  check(stubborn_info.group_alive_after == false,
    "the KILL-escalated group must be observed gone")
  wait_leader_gone(stubborn, "KILL-escalation job")
  local stubborn_status_path = job_root .. "/" .. stubborn:job_id() .. "/status"
  check(WheelHost.fs.write_file(stubborn_status_path, "124"),
    "cannot synthesize the KILL-path timeout sentinel")
  local stubborn_result = stubborn:wait(5000)
  check(stubborn_result ~= nil and stubborn_result.outcome == WheelHost.PROCESS_OUTCOME.CANCELLED,
    "the TERM-ignoring job must reach a cancelled result")
  check(stubborn_result.code == 137,
    "the KILL-escalated job must carry the KILL-derived status: "
      .. tostring(stubborn_result.code))
  check(stubborn_result.cleanup == WheelHost.GROUP_CLEANUP.SWEPT,
    "the KILL-escalated group must be observed swept, got "
      .. tostring(stubborn_result.cleanup))

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
  check(outcome.cleanup == "swept",
    "the cancellation outcome must record a swept group, got "
      .. tostring(outcome.cleanup))
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
    timeout_ms = 3000,
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

  -- 8b. Post-launch start failures must still close the audit pair.
  local pgid_audit = base .. "/pgid-audit"
  local pgid_pid_file = base .. "/pgid-fail.pid"
  local real_read_bounded = WheelHost.backend.read_file_bounded
  local real_start_wait = WheelJob.LIMITS.START_WAIT_MS
  WheelHost.backend.read_file_bounded = function(path, count)
    if type(path) == "string" and path:match("/pgid$") then
      return nil
    end
    return real_read_bounded(path, count)
  end
  WheelJob.LIMITS.START_WAIT_MS = 200
  local pgid_ok, pgid_failed, pgid_err = pcall(WheelHost.proc.start, "sh", {
    "-c",
    "echo $$ > " .. shell_quote(pgid_pid_file) .. "; sleep 2",
  }, {
    timeout_ms = 1000,
    job_root = job_root,
    audit = { dir = pgid_audit, task = "CTX-0034" },
  })
  WheelJob.LIMITS.START_WAIT_MS = real_start_wait
  WheelHost.backend.read_file_bounded = real_read_bounded
  check(pgid_ok, "the pgid-failure probe must not throw: " .. tostring(pgid_failed))
  check(pgid_failed == nil and type(pgid_err) == "table",
    "a missing pgid must fail the start")
  local pgid_records = parse_audit(pgid_audit)
  check(find_event(pgid_records, "process.pre_spawn") ~= nil,
    "the pgid failure must have a pre-spawn record")
  check(find_event(pgid_records, "process.aborted") ~= nil,
    "the pgid failure must have an aborted record")
  wait_for_file(pgid_pid_file, "pgid-failure command pid")
  local pgid_child = recorded_pid(pgid_pid_file)
  check(pgid_child ~= nil, "the pgid-failure command must record its pid")
  wait_gone(pgid_child, "pgid-failure child")

  local meta_audit = base .. "/meta-audit"
  local real_create_private = WheelHost.backend.create_private_file
  WheelHost.backend.create_private_file = function(path, content)
    if type(path) == "string" and path:match("/job%.meta$") then
      return false, "/private/tmp/wheel-job-meta-leak"
    end
    return real_create_private(path, content)
  end
  local meta_ok, meta_failed, meta_err = pcall(WheelHost.proc.start, "sleep", { "30" }, {
    timeout_ms = 3000,
    job_root = job_root,
    audit = { dir = meta_audit, task = "CTX-0034" },
  })
  WheelHost.backend.create_private_file = real_create_private
  check(meta_ok, "the metadata-failure probe must not throw: " .. tostring(meta_failed))
  check(meta_failed == nil and type(meta_err) == "table",
    "a metadata publish failure must fail the start")
  check(type(meta_err.audit_error) == "table"
    and meta_err.audit_error.code == WheelErrors.E_JOB_METADATA_INVALID,
    "the metadata publish failure must carry the typed job error")
  check(not tostring(meta_err.message):find("wheel-job-meta-leak", 1, true)
    and not tostring(meta_err.audit_error.message):find("wheel-job-meta-leak", 1, true),
    "a typed job error must not leak host path diagnostics")
  local meta_records = parse_audit(meta_audit)
  check(find_event(meta_records, "process.pre_spawn") ~= nil,
    "the metadata failure must have a pre-spawn record")
  check(find_event(meta_records, "process.completed") ~= nil,
    "the metadata failure must have a completion record")

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
  -- A post-launch start failure deliberately leaves an unrecorded group to its
  -- own timeout; wait for that leader/supervisor to finish before removing the
  -- scratch records it is still using.
  wait_no_process_with(base, "a cancellation scratch process")
  check(remove_tree(base), "cannot remove the cancellation scratch base")
  print(string.format("[PASS] cancellation suite: %d checks", checks))
end

select_scratch_root()
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
