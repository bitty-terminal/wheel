-- lua/wheel/job.lua
-- Wheel: private process-job record and recorded-group cancellation.
--
-- A job is one private directory under `<job root>/<32-hex id>` containing:
--
--   job.meta        owned 0600 key=value record (format, id, generation,
--                   recorded PGID/leader PID, timeout, and optional audit
--                   identity)
--   pgid, status,   written by the retained session leader (status is written
--   sweep           before any group signal)
--   cancel.request  exclusive 0600 request marker
--   terminal        exclusive 0600 terminal reason (`exited`, `timeout`,
--                   `cancelled`, or `unverified`)
--   cancel.outcome  TERM/KILL evidence written by the cancelling process
--   stdout, stderr, private 0600 capture files
--   diag, wrapper.pid
--   lock            a `mkdir` lock serializing the terminal transition
--
-- Security boundary:
--   * A cancellation request validates the job id, metadata shape, file
--     ownership/modes, and the recorded leader generation before any signal.
--     The generation token is present in the retained leader's argv and is
--     compared against `/proc/<leader_pid>` (or a `ps` fallback): the leader
--     must be alive, its process group and session must equal the recorded
--     PGID, and its command line must carry both `wheel-leader` and the exact
--     generation token. A stale or tampered record is refused, never guessed.
--   * The only signal targets are the recorded process group (`-PGID`), or a
--     liveness probe with signal 0. There is no name- or pattern-based kill.
--   * The retained leader ignores TERM while it waits for the direct child, so
--     a group TERM interrupts the command without losing the recorded PGID.
--     The request process sends TERM, waits a bounded grace (the same
--     `SWEEP_GRACE_MS` discipline as the leader), then sends KILL to the same
--     recorded group if the leader is still present. The leader also performs
--     its normal TERM/grace/KILL sweep after the direct child exits.
--   * The terminal transition is serialized by an exclusive `mkdir` lock. The
--     first writer wins: a cancellation request writes `cancelled` before it
--     signals, and the leader writes `exited`/`timeout` only when no terminal
--     reason exists. A request that loses the lock sees the published terminal
--     reason and is a typed no-op.
--   * Cancellation is same-user only. The job root and files are private, but a
--     same-user process can read the record and act with the same OS authority;
--     the generation check protects against stale PID/PGID reuse, not against
--     that user. Cross-user isolation is not claimed and Windows is not
--     supported by this slice.
--
-- The module deliberately uses only WheelHost primitives; `wheel.host` is
-- required lazily because host.lua requires this module at load time.

local WheelJob = {}

local WheelErrors = require("wheel.errors")

local FORMAT = "wheel-job/1"
local OUTCOME_FORMAT = "wheel-cancel-outcome/1"

-- Private directory/file modes as decimal permission bits.
local DIR_MODE = 448
local FILE_MODE = 384

local LIMITS = {
  META_BYTES = 4096,
  TERMINAL_BYTES = 32,
  OUTCOME_BYTES = 512,
  ID_HEX = 32,
  GENERATION_HEX = 32,
  META_VALUE_BYTES = 512,
  CREATE_ATTEMPTS = 8,
  LOCK_ATTEMPTS = 300,
  POLL_MS = 10,
  START_WAIT_MS = 5000,
  CANCEL_GRACE_MS = 250,
  CANCEL_KILL_WAIT_MS = 1000,
  MAX_CANCEL_GRACE_MS = 2000,
}

WheelJob.FORMAT = FORMAT
WheelJob.OUTCOME_FORMAT = OUTCOME_FORMAT
WheelJob.DIR_MODE = DIR_MODE
WheelJob.FILE_MODE = FILE_MODE
WheelJob.LIMITS = LIMITS

local cached_host = nil

local function host()
  if cached_host then
    return cached_host
  end
  local ok, mod = pcall(require, "wheel.host")
  if not ok then
    package.loaded["wheel.host"] = nil
    ok, mod = pcall(require, "lua.wheel.host")
  end
  if ok and type(mod) == "table" then
    cached_host = mod
    return mod
  end
  return nil
end

local cached_audit = nil

local function audit_module()
  if cached_audit then
    return cached_audit
  end
  local ok, mod = pcall(require, "wheel.audit")
  if not ok then
    package.loaded["wheel.audit"] = nil
    ok, mod = pcall(require, "lua.wheel.audit")
  end
  if ok and type(mod) == "table" and type(mod.record) == "function" then
    cached_audit = mod
    return mod
  end
  return nil
end

local function job_error(code, detail)
  return WheelErrors.job_failure(code, detail)
end

local function is_control_free(value)
  return type(value) == "string" and value:find("[%z\n\r]") == nil
end

local function valid_int(value, minimum, maximum)
  return type(value) == "number"
    and value == value
    and value % 1 == 0
    and value >= minimum
    and value <= maximum
end

local function valid_hex(value, digits)
  return type(value) == "string"
    and #value == digits
    and value:match("^[0-9a-f]+$") ~= nil
end

--- Normalize a private absolute directory path.
-- Rejects the filesystem root, relative paths, control bytes, and `.`/`..`
-- segments. The path is rebuilt with one separator between segments so a
-- normalized form is the one inspected and used.
-- @param path string?
-- @return string? path
local function normalize_absolute_dir(path)
  if type(path) ~= "string" or path == "" or #path > 4096 then
    return nil
  end
  if path:sub(1, 1) ~= "/" or not is_control_free(path) then
    return nil
  end
  local segments = {}
  for segment in path:gmatch("[^/]+") do
    if segment == "." or segment == ".." then
      return nil
    end
    segments[#segments + 1] = segment
  end
  if #segments == 0 then
    return nil
  end
  return "/" .. table.concat(segments, "/")
end

local function join(dir, name)
  return dir .. "/" .. name
end

local function paths_for(dir)
  return {
    meta = join(dir, "job.meta"),
    pgid = join(dir, "pgid"),
    status = join(dir, "status"),
    sweep = join(dir, "sweep"),
    cancel = join(dir, "cancel.request"),
    terminal = join(dir, "terminal"),
    outcome = join(dir, "cancel.outcome"),
    out = join(dir, "stdout"),
    err = join(dir, "stderr"),
    diag = join(dir, "diag"),
    stdin = join(dir, "stdin"),
    wrapper = join(dir, "wrapper.pid"),
    lock = join(dir, "lock"),
  }
end

local function hex_encode(bytes)
  return (bytes:gsub(".", function(char)
    return string.format("%02x", string.byte(char))
  end))
end

local function random_hex(byte_count)
  local h = host()
  if not h or type(h.fs) ~= "table" or type(h.fs.random_bytes) ~= "function" then
    return nil, job_error(WheelErrors.E_JOB_UNAVAILABLE, "the host random source is unavailable")
  end
  local bytes, err = h.fs.random_bytes(byte_count)
  if type(bytes) ~= "string" or #bytes ~= byte_count then
    return nil, job_error(WheelErrors.E_JOB_UNAVAILABLE, err or "the host random source failed")
  end
  return hex_encode(bytes)
end

local function verify_directory(path)
  local h = host()
  if not h or type(h.fs) ~= "table" then
    return false, job_error(WheelErrors.E_JOB_UNAVAILABLE, "the host filesystem is unavailable")
  end
  local info = h.fs.stat(path)
  if not info.exists or info.symlink or not info.directory then
    return false, job_error(WheelErrors.E_JOB_UNAVAILABLE, "the job path is not a real directory")
  end
  if info.mode ~= DIR_MODE then
    return false, job_error(WheelErrors.E_JOB_UNAVAILABLE, "the job directory is not mode 0700")
  end
  local euid = h.fs.euid()
  if euid == nil or info.uid ~= euid then
    return false, job_error(WheelErrors.E_JOB_UNAVAILABLE, "the job directory is not owned by the current user")
  end
  return true
end

local Job = {}
Job.__index = Job

--- Return the recorded job id.
-- @return string
function Job:id()
  return self.job_id
end

--- Return the job root used by this record.
-- @return string
function Job:root_path()
  return self.root
end

--- Return the private job directory.
-- @return string
function Job:directory()
  return self.dir
end

--- Return the recorded process-group id, when the leader recorded it.
-- @return number? pgid
function Job:pgid()
  return self.recorded_pgid
end

--- Return the recorded leader process id, when the leader recorded it.
-- @return number? leader_pid
function Job:leader_pid()
  return self.recorded_leader_pid
end

--- Read one bounded numeric file in the job directory.
-- @param path string
-- @return number? value
local function read_number_file(path)
  local h = host()
  if not h then
    return nil
  end
  local raw = h.fs.read_file_bounded(path, 32)
  if type(raw) ~= "string" then
    return nil
  end
  return tonumber(raw:match("^%s*(%d+)%s*$"))
end

--- Read the published terminal reason.
-- A missing terminal file is `nil` (still running or not yet transitioned). An
-- unrecognized value is reported as `unverified` so a caller never reads a
-- corrupt marker as a normal exit.
-- @return string? reason
function Job:terminal_reason()
  local h = host()
  if not h then
    return nil
  end
  local raw = h.fs.read_file_bounded(self.paths.terminal, LIMITS.TERMINAL_BYTES)
  if type(raw) ~= "string" then
    return nil
  end
  local reason = raw:match("^%s*(.-)%s*$")
  if reason == "exited" or reason == "timeout" or reason == "cancelled" then
    return reason
  end
  return "unverified"
end

--- Read the retained leader's recorded exit status.
-- @return number? status
function Job:exit_status()
  return read_number_file(self.paths.status)
end

--- Return true when the retained leader completed its group sweep.
-- @return boolean
function Job:swept()
  local h = host()
  if not h then
    return false
  end
  local raw = h.fs.read_file_bounded(self.paths.sweep, 32)
  return type(raw) == "string" and raw:match("^%s*swept%s*$") ~= nil
end

--- Read the cancellation outcome evidence written by the canceller.
-- `group_alive_after` is `true`, `false`, or nil when the final probe was
-- unknown; nil must never be read as swept.
-- @return table { term_sent, kill_sent, group_alive_after?, grace_ms }
function Job:cancel_outcome()
  local h = host()
  if not h then
    return nil
  end
  local raw = h.fs.read_file_bounded(self.paths.outcome, LIMITS.OUTCOME_BYTES)
  if type(raw) ~= "string" or raw == "" then
    return nil
  end
  local outcome = {}
  for line in raw:gmatch("[^\n]+") do
    local key, value = line:match("^([a-z_]+)=(.*)$")
    if key then
      outcome[key] = value
    end
  end
  local group_alive_after = nil
  if outcome.group_alive_after == "1" then
    group_alive_after = true
  elseif outcome.group_alive_after == "0" then
    group_alive_after = false
  end
  return {
    term_sent = outcome.term_sent == "1",
    kill_sent = outcome.kill_sent == "1",
    group_alive_after = group_alive_after,
    grace_ms = tonumber(outcome.grace_ms),
  }
end

--- Return true while the recorded leader is alive.
-- A permission or probe failure is reported as not alive; callers that need a
-- fail-closed answer use `validate_generation` instead.
-- @return boolean
function Job:leader_alive()
  if self.recorded_leader_pid == nil then
    return false
  end
  local h = host()
  if not h or type(h.proc) ~= "table" or type(h.proc.is_alive) ~= "function" then
    return false
  end
  local alive = h.proc.is_alive(self.recorded_leader_pid)
  return alive == true
end

--- Probe the recorded process group without delivering a signal.
-- The three-state result keeps an unknown probe distinct from a vanished
-- group: `true` means present, `false` means the group is gone (ESRCH), and
-- `nil, err` means the result is unknown (permission denial or probe failure).
-- @return boolean? alive, string? err
function Job:group_alive()
  if self.recorded_pgid == nil then
    return false
  end
  local h = host()
  if not h or type(h.proc) ~= "table" or type(h.proc.signal_group) ~= "function" then
    return nil, "process-group probe unavailable"
  end
  local ok, reason = h.proc.signal_group(self.recorded_pgid, "0")
  if ok == true then
    return true
  end
  if reason == "no such process group" then
    return false
  end
  return nil, reason or "process-group probe failed"
end

--- Acquire the job's exclusive terminal-transition lock.
-- @return boolean ok, string? err
function Job:acquire_lock()
  local h = host()
  if not h then
    return false, job_error(WheelErrors.E_JOB_UNAVAILABLE, "the host seam is unavailable")
  end
  for _ = 1, LIMITS.LOCK_ATTEMPTS do
    if h.fs.mkdir(self.paths.lock) then
      return true
    end
    local slept = h.time.sleep_ms(LIMITS.POLL_MS)
    if not slept then
      return false, job_error(WheelErrors.E_JOB_UNAVAILABLE, "the bounded sleep is unavailable")
    end
  end
  return false, job_error(WheelErrors.E_JOB_BUSY, "the job transition lock is held")
end

--- Release the job's terminal-transition lock.
-- A failed removal is reported so a caller does not continue as if the lock
-- were gone; there is deliberately no recursive or permissive cleanup.
-- @return boolean ok
function Job:release_lock()
  local h = host()
  if not h then
    return false
  end
  return h.fs.remove_dir(self.paths.lock) == true
end

--- Write the job metadata exactly once.
-- The file is created exclusively at 0600; a pre-existing metadata file is
-- refused. Values are bounded, control-free, and never include the generation
-- in an error message.
-- @param fields table { generation, pgid, leader_pid, timeout_ms, started_ms, audit? }
-- @return boolean ok, table? err
function Job:write_meta(fields)
  local h = host()
  if not h then
    return false, job_error(WheelErrors.E_JOB_UNAVAILABLE, "the host seam is unavailable")
  end
  if type(fields) ~= "table" then
    return false, job_error(WheelErrors.E_JOB_METADATA_INVALID, "job metadata must be a table")
  end
  if not valid_hex(fields.generation, LIMITS.GENERATION_HEX) then
    return false, job_error(WheelErrors.E_JOB_METADATA_INVALID, "invalid job generation")
  end
  if not valid_int(fields.pgid, 2, 2147483647)
    or not valid_int(fields.leader_pid, 2, 2147483647)
    or fields.pgid ~= fields.leader_pid then
    return false, job_error(WheelErrors.E_JOB_METADATA_INVALID, "invalid recorded process identity")
  end
  if not valid_int(fields.timeout_ms, 50, 600000) then
    return false, job_error(WheelErrors.E_JOB_METADATA_INVALID, "invalid job timeout")
  end
  if not valid_int(fields.started_ms, 0, 9007199254740991) then
    return false, job_error(WheelErrors.E_JOB_METADATA_INVALID, "invalid job start time")
  end

  local lines = {
    "format=" .. FORMAT,
    "job_id=" .. self.job_id,
    "generation=" .. fields.generation,
    "state=running",
    "pgid=" .. tostring(fields.pgid),
    "leader_pid=" .. tostring(fields.leader_pid),
    "timeout_ms=" .. tostring(fields.timeout_ms),
    "started_ms=" .. tostring(fields.started_ms),
  }

  local audit = fields.audit
  if audit ~= nil then
    if type(audit) ~= "table" then
      return false, job_error(WheelErrors.E_JOB_METADATA_INVALID, "invalid audit metadata")
    end
    local dir = normalize_absolute_dir(audit.dir)
    if not dir then
      return false, job_error(WheelErrors.E_JOB_METADATA_INVALID, "invalid audit directory")
    end
    lines[#lines + 1] = "audit_dir=" .. dir
    lines[#lines + 1] = "audit_high_risk=" .. (audit.high_risk == true and "true" or "false")
    for _, name in ipairs({ "role", "agent", "task", "tool", "intent" }) do
      local value = audit[name]
      if value ~= nil then
        if type(value) ~= "string" or #value > LIMITS.META_VALUE_BYTES
          or not is_control_free(value) then
          return false, job_error(WheelErrors.E_JOB_METADATA_INVALID,
            "invalid audit identity value")
        end
        lines[#lines + 1] = "audit_" .. name .. "=" .. value
      end
    end
  end

  local content = table.concat(lines, "\n") .. "\n"
  if #content > LIMITS.META_BYTES then
    return false, job_error(WheelErrors.E_JOB_METADATA_INVALID, "job metadata exceeds its bound")
  end
  local created = h.fs.create_private_file(self.paths.meta, content)
  if not created then
    return false, job_error(WheelErrors.E_JOB_METADATA_INVALID,
      "job metadata could not be created")
  end
  self.generation = fields.generation
  self.recorded_pgid = fields.pgid
  self.recorded_leader_pid = fields.leader_pid
  self.timeout_ms = fields.timeout_ms
  self.started_ms = fields.started_ms
  self.audit = audit
  self.meta = {
    format = FORMAT,
    job_id = self.job_id,
    generation = fields.generation,
    state = "running",
    pgid = fields.pgid,
    leader_pid = fields.leader_pid,
    timeout_ms = fields.timeout_ms,
    started_ms = fields.started_ms,
    audit_dir = audit and audit.dir or nil,
    audit_high_risk = audit and audit.high_risk == true or false,
    audit_role = audit and audit.role or nil,
    audit_agent = audit and audit.agent or nil,
    audit_task = audit and audit.task or nil,
    audit_tool = audit and audit.tool or nil,
    audit_intent = audit and audit.intent or nil,
  }
  return true
end

-- ---------------------------------------------------------------------------
-- Metadata parsing and generation validation
-- ---------------------------------------------------------------------------

local ALLOWED_META_KEYS = {
  format = true,
  job_id = true,
  generation = true,
  state = true,
  pgid = true,
  leader_pid = true,
  timeout_ms = true,
  started_ms = true,
  audit_dir = true,
  audit_high_risk = true,
  audit_role = true,
  audit_agent = true,
  audit_task = true,
  audit_tool = true,
  audit_intent = true,
}

--- Parse and validate one metadata body.
-- Unknown keys are rejected so a record cannot smuggle a redirect or a second
-- identity into the canceller. Values are bounded and control-free.
-- @param content string
-- @param job_id string
-- @return table? meta, table? err
local function parse_meta(content, job_id)
  if type(content) ~= "string" or content == "" or #content > LIMITS.META_BYTES then
    return nil, job_error(WheelErrors.E_JOB_METADATA_INVALID, "job metadata is empty or oversized")
  end
  if content:sub(-1) ~= "\n" then
    return nil, job_error(WheelErrors.E_JOB_METADATA_INVALID, "job metadata is not line terminated")
  end

  local raw = {}
  for line in content:gmatch("([^\n]*)\n") do
    if line ~= "" then
      local key, value = line:match("^([a-z_]+)=(.*)$")
      if not key or not ALLOWED_META_KEYS[key] or raw[key] ~= nil then
        return nil, job_error(WheelErrors.E_JOB_METADATA_INVALID, "job metadata contains an invalid field")
      end
      if #value > LIMITS.META_VALUE_BYTES or not is_control_free(value) then
        return nil, job_error(WheelErrors.E_JOB_METADATA_INVALID, "job metadata value is invalid")
      end
      raw[key] = value
    end
  end

  if raw.format ~= FORMAT then
    return nil, job_error(WheelErrors.E_JOB_METADATA_INVALID, "job metadata format is unsupported")
  end
  if raw.job_id ~= job_id or not valid_hex(raw.job_id, LIMITS.ID_HEX) then
    return nil, job_error(WheelErrors.E_JOB_METADATA_INVALID, "job id does not match its directory")
  end
  if raw.state ~= "running" then
    return nil, job_error(WheelErrors.E_JOB_NOT_RUNNING, "job did not reach the running state")
  end
  if not valid_hex(raw.generation, LIMITS.GENERATION_HEX) then
    return nil, job_error(WheelErrors.E_JOB_METADATA_INVALID, "job generation is invalid")
  end

  local pgid = tonumber(raw.pgid)
  local leader_pid = tonumber(raw.leader_pid)
  local timeout_ms = tonumber(raw.timeout_ms)
  local started_ms = tonumber(raw.started_ms)
  if not valid_int(pgid, 2, 2147483647)
    or not valid_int(leader_pid, 2, 2147483647)
    or pgid ~= leader_pid then
    return nil, job_error(WheelErrors.E_JOB_METADATA_INVALID, "job process identity is invalid")
  end
  if not valid_int(timeout_ms, 50, 600000) then
    return nil, job_error(WheelErrors.E_JOB_METADATA_INVALID, "job timeout is invalid")
  end
  if not valid_int(started_ms, 0, 9007199254740991) then
    return nil, job_error(WheelErrors.E_JOB_METADATA_INVALID, "job start time is invalid")
  end

  local meta = {
    format = raw.format,
    job_id = raw.job_id,
    generation = raw.generation,
    state = raw.state,
    pgid = pgid,
    leader_pid = leader_pid,
    timeout_ms = timeout_ms,
    started_ms = started_ms,
  }

  if raw.audit_dir ~= nil then
    local dir = normalize_absolute_dir(raw.audit_dir)
    if not dir then
      return nil, job_error(WheelErrors.E_JOB_METADATA_INVALID, "job audit directory is invalid")
    end
    meta.audit_dir = dir
    meta.audit_high_risk = raw.audit_high_risk == "true"
    if raw.audit_high_risk ~= nil
      and raw.audit_high_risk ~= "true"
      and raw.audit_high_risk ~= "false" then
      return nil, job_error(WheelErrors.E_JOB_METADATA_INVALID, "job audit risk flag is invalid")
    end
    for _, name in ipairs({ "role", "agent", "task", "tool", "intent" }) do
      local value = raw["audit_" .. name]
      if value ~= nil then
        meta["audit_" .. name] = value
      end
    end
  else
    for key in pairs(raw) do
      if key:sub(1, 6) == "audit_" then
        return nil, job_error(WheelErrors.E_JOB_METADATA_INVALID,
          "job audit identity exists without an audit directory")
      end
    end
  end

  return meta
end

local function read_proc_stat(pid)
  local h = host()
  if not h then
    return nil
  end
  local stat = h.fs.read_file("/proc/" .. tostring(pid) .. "/stat")
  if type(stat) ~= "string" or stat == "" then
    return nil
  end
  local head = stat:match("^(.*)%)")
  if not head then
    return nil
  end
  local rest = stat:sub(#head + 2)
  local state, _, pgrp, session = rest:match("^%s*(%S+)%s+(%S+)%s+(%S+)%s+(%S+)")
  if not state or not pgrp or not session then
    return nil
  end
  return {
    state = state,
    pgrp = tonumber(pgrp),
    session = tonumber(session),
  }
end

local function cmdline_has_token(cmdline, token)
  if type(cmdline) ~= "string" or type(token) ~= "string" then
    return false
  end
  for part in (cmdline .. "\0"):gmatch("([^%z]*)%z") do
    if part == token then
      return true
    end
  end
  return false
end

--- Split a `ps args=` line into tokens and compare one exactly.
-- Exact token matching prevents a crafted generation from matching as a
-- substring of a longer argument.
-- @param args string
-- @param token string
-- @return boolean
local function args_has_token(args, token)
  if type(args) ~= "string" or type(token) ~= "string" then
    return false
  end
  for part in args:gmatch("%S+") do
    if part == token then
      return true
    end
  end
  return false
end

--- Read the recorded leader's real and effective uid from `/proc`.
-- `/proc/<pid>/status` is the primary source; `/proc/<pid>` ownership is the
-- fallback when the status file is unreadable. A missing owner is unknown, not
-- an implicit match.
-- @param pid number
-- @return number? real_uid, number? effective_uid
local function proc_owner(pid)
  local h = host()
  if not h then
    return nil, nil
  end
  local status = h.fs.read_file_bounded("/proc/" .. tostring(pid) .. "/status", 8192)
  if type(status) == "string" then
    local fields = status:match("\nUid:%s*([^\n]+)")
    if fields then
      local real, effective = fields:match("^%s*(%d+)%s+(%d+)")
      if real and effective then
        return tonumber(real), tonumber(effective)
      end
    end
  end
  local info = h.fs.stat("/proc/" .. tostring(pid))
  if info.exists and type(info.uid) == "number" then
    return info.uid, info.uid
  end
  return nil, nil
end

--- Verify the recorded generation and owner against the live retained leader.
-- Linux uses `/proc`; other POSIX hosts fall back to `ps -ww`. Both checks
-- require the leader's real/effective uid to equal the current effective uid,
-- its process group/session to equal the recorded PGID, and its command line
-- to carry `wheel-leader` plus the exact generation token. A foreign or
-- credential-transitioned leader is refused before any audit or signal.
-- @param meta table
-- @return boolean ok, table? err
local function validate_generation(meta)
  local h = host()
  if not h then
    return false, job_error(WheelErrors.E_JOB_UNAVAILABLE, "the host seam is unavailable")
  end
  local euid = h.fs.euid()
  if euid == nil then
    return false, job_error(WheelErrors.E_JOB_UNAVAILABLE,
      "the current effective uid is unavailable")
  end

  local stat = read_proc_stat(meta.leader_pid)
  if stat then
    local real_uid, effective_uid = proc_owner(meta.leader_pid)
    if real_uid == nil or effective_uid == nil then
      return false, job_error(WheelErrors.E_JOB_UNAVAILABLE,
        "the recorded leader owner is unavailable")
    end
    if real_uid ~= euid or effective_uid ~= euid then
      return false, job_error(WheelErrors.E_JOB_GENERATION_MISMATCH,
        "the recorded leader is not owned by the current user")
    end
    if stat.state == "Z" or stat.state == "X" then
      return false, job_error(WheelErrors.E_JOB_NOT_RUNNING, "the recorded leader is not running")
    end
    if stat.pgrp ~= meta.pgid or stat.session ~= meta.pgid then
      return false, job_error(WheelErrors.E_JOB_GENERATION_MISMATCH,
        "the recorded leader group identity does not match")
    end
    local cmdline = h.fs.read_file("/proc/" .. tostring(meta.leader_pid) .. "/cmdline")
    if not cmdline_has_token(cmdline, "wheel-leader")
      or not cmdline_has_token(cmdline, meta.generation) then
      return false, job_error(WheelErrors.E_JOB_GENERATION_MISMATCH,
        "the recorded leader generation does not match")
    end
    return true
  end

  if type(h.proc) ~= "table" or type(h.proc.run_program) ~= "function" then
    return false, job_error(WheelErrors.E_JOB_UNAVAILABLE, "the process probe is unavailable")
  end
  local probe = h.proc.run_program("ps", {
    "-ww", "-p", tostring(meta.leader_pid), "-o", "pgid=,sess=,stat=,uid=,args=",
  }, { timeout_ms = 5000, discard_stderr = true })
  if not probe.ok or probe.code ~= 0 then
    return false, job_error(WheelErrors.E_JOB_NOT_RUNNING, "the recorded leader is not running")
  end
  local pgid, session, state, uid, args =
    probe.stdout:match("^%s*(%d+)%s+(%d+)%s+(%S+)%s+(%d+)%s+(.+)$")
  if not pgid or not session or not state or not uid or not args then
    return false, job_error(WheelErrors.E_JOB_UNAVAILABLE,
      "the recorded leader metadata is unreadable")
  end
  if tonumber(uid) ~= euid then
    return false, job_error(WheelErrors.E_JOB_GENERATION_MISMATCH,
      "the recorded leader is not owned by the current user")
  end
  if tonumber(pgid) ~= meta.pgid or tonumber(session) ~= meta.pgid then
    return false, job_error(WheelErrors.E_JOB_GENERATION_MISMATCH,
      "the recorded leader group identity does not match")
  end
  if state:sub(1, 1) == "Z" then
    return false, job_error(WheelErrors.E_JOB_NOT_RUNNING, "the recorded leader is not running")
  end
  if not args_has_token(args, "wheel-leader") or not args_has_token(args, meta.generation) then
    return false, job_error(WheelErrors.E_JOB_GENERATION_MISMATCH,
      "the recorded leader generation does not match")
  end
  return true
end

-- ---------------------------------------------------------------------------
-- Audit
-- ---------------------------------------------------------------------------

local function audit_event(meta, name, extra)
  local event = {
    event = name,
    job_id = meta.job_id,
    role = meta.audit_role,
    agent = meta.audit_agent,
    task = meta.audit_task,
    tool = meta.audit_tool,
    intent = meta.audit_intent,
    decision = "allow",
    high_risk = meta.audit_high_risk == true,
    spawned = true,
  }
  for key, value in pairs(extra or {}) do
    event[key] = value
  end
  return event
end

local function record_audit(meta, event)
  if meta.audit_dir == nil then
    return true
  end
  local mod = audit_module()
  if not mod then
    return nil, WheelErrors.audit_unavailable()
  end
  local ok, recorded, audit_err = pcall(mod.record, event, { dir = meta.audit_dir })
  if not ok then
    return nil, WheelErrors.audit_unavailable()
  end
  return recorded, audit_err
end

-- ---------------------------------------------------------------------------
-- Cancellation
-- ---------------------------------------------------------------------------

local function encode_group_alive(value)
  if value == true then
    return "1"
  end
  if value == false then
    return "0"
  end
  return "unknown"
end

local function write_cancel_outcome(job, term_sent, kill_sent, group_alive_after, grace_ms)
  local h = host()
  if not h then
    return false
  end
  if h.fs.exists(job.paths.outcome) then
    return true
  end
  local content = table.concat({
    OUTCOME_FORMAT,
    "term_sent=" .. (term_sent and "1" or "0"),
    "kill_sent=" .. (kill_sent and "1" or "0"),
    "group_alive_after=" .. encode_group_alive(group_alive_after),
    "grace_ms=" .. tostring(grace_ms),
  }, "\n") .. "\n"
  return h.fs.create_private_file(job.paths.outcome, content) == true
end

--- Request cancellation of one recorded job.
-- The caller's `opts.grace_ms` bounds the TERM-to-KILL interval; it is clamped
-- to the documented range. The metadata's audit identity is used for request
-- and outcome records, so an external CLI cancels with the same audit context
-- as the spawner. A high-risk request whose audit record cannot be written is
-- refused before any signal.
-- @param opts table? { grace_ms = number? }
-- @return table? info, table? err
function Job:request_cancel(opts)
  opts = type(opts) == "table" and opts or {}
  local h = host()
  if not h then
    return nil, job_error(WheelErrors.E_JOB_UNAVAILABLE, "the host seam is unavailable")
  end

  local grace_ms = opts.grace_ms
  if grace_ms == nil then
    grace_ms = LIMITS.CANCEL_GRACE_MS
  end
  if not valid_int(grace_ms, 10, LIMITS.MAX_CANCEL_GRACE_MS) then
    return nil, job_error(WheelErrors.E_JOB_METADATA_INVALID, "invalid cancellation grace")
  end

  local function terminal_no_op(reason)
    return {
      state = reason == "cancelled" and "already_cancelled" or "already_exited",
      terminal_reason = reason,
      term_sent = false,
      kill_sent = false,
      pgid = self.recorded_pgid,
    }
  end

  -- The terminal reason is immutable once published (only `close` removes the
  -- record after the leader is gone), so a repeated request can answer before
  -- touching the transition lock. This keeps repeated cancel idempotent even
  -- when a crashed canceller left a stale lock behind.
  local observed = self:terminal_reason()
  if observed ~= nil then
    return terminal_no_op(observed)
  end

  local locked, lock_err = self:acquire_lock()
  if not locked then
    return nil, lock_err
  end

  local function unlock()
    self:release_lock()
  end

  observed = self:terminal_reason()
  if observed ~= nil then
    unlock()
    return terminal_no_op(observed)
  end

  local valid, generation_err = validate_generation(self.meta)
  if not valid then
    unlock()
    return nil, generation_err
  end

  local repeated = h.fs.exists(self.paths.cancel)
  local audit_warning = nil

  if not repeated then
    local recorded, audit_err = record_audit(self.meta, audit_event(self.meta,
      "process.cancel_requested", { cancel_requested = true }))
    if not recorded then
      if self.meta.audit_high_risk == true then
        unlock()
        return nil, audit_err or WheelErrors.audit_unavailable()
      end
      audit_warning = "the cancellation request audit record could not be written"
    end
  end

  local marker_created = false
  if not repeated then
    local created = h.fs.create_private_file(self.paths.cancel, "")
    if not created then
      unlock()
      return nil, job_error(WheelErrors.E_JOB_UNAVAILABLE,
        "the cancellation request marker could not be created")
    end
    marker_created = true
  end

  local function discard_marker()
    if marker_created then
      h.fs.remove_file(self.paths.cancel)
    end
  end

  -- Signal while holding the transition lock. The leader cannot publish a
  -- terminal reason until it acquires the same lock, so a refused signal never
  -- leaves `cancelled` behind: the terminal record is written only after a
  -- delivered TERM. The cancel marker is still created before the signal so a
  -- leader that wins the race after the lock is released records `cancelled`.
  local term_ok, term_reason = h.proc.signal_group(self.recorded_pgid, "TERM")
  if not term_ok then
    discard_marker()
    unlock()
    if term_reason == "no such process group" then
      local after = self:terminal_reason()
      if after ~= nil then
        return terminal_no_op(after)
      end
      return nil, job_error(WheelErrors.E_JOB_NOT_RUNNING,
        "the recorded process group is not running")
    end
    if term_reason == "permission denied" then
      return nil, job_error(WheelErrors.E_JOB_GENERATION_MISMATCH,
        "the recorded group is not signalable by the current user")
    end
    return nil, job_error(WheelErrors.E_JOB_SIGNAL_FAILED,
      "the recorded group could not be signalled")
  end

  -- The first writer wins. Writing the terminal reason before releasing the
  -- lock means a leader that is killed during the grace still has a durable
  -- reason; a leader that exits normally sees the existing marker and leaves it
  -- alone.
  local terminal_written = true
  if not h.fs.exists(self.paths.terminal) then
    terminal_written = h.fs.create_private_file(self.paths.terminal, "cancelled\n") == true
    if not terminal_written and h.fs.exists(self.paths.terminal) then
      -- A concurrent writer may have published the same terminal reason after
      -- the existence check; that is a success for this request.
      terminal_written = true
    end
  end

  unlock()

  local alive_state = true
  local probe_failure = nil
  local sleep_failure = nil
  local grace_steps = math.max(1, math.floor(grace_ms / LIMITS.POLL_MS))
  for _ = 1, grace_steps do
    local alive, probe_err = self:group_alive()
    if alive == false then
      alive_state = false
      break
    end
    if alive == nil then
      alive_state = nil
      probe_failure = probe_err
      break
    end
    local slept = h.time.sleep_ms(LIMITS.POLL_MS)
    if not slept then
      sleep_failure = "the bounded grace sleep failed"
      break
    end
  end

  local kill_sent = false
  if alive_state == true and probe_failure == nil and sleep_failure == nil then
    local kill_ok = h.proc.signal_group(self.recorded_pgid, "KILL")
    kill_sent = kill_ok == true
    local kill_steps = math.max(1, math.floor(LIMITS.CANCEL_KILL_WAIT_MS / LIMITS.POLL_MS))
    for _ = 1, kill_steps do
      local alive, probe_err = self:group_alive()
      if alive == false then
        alive_state = false
        break
      end
      if alive == nil then
        alive_state = nil
        probe_failure = probe_err
        break
      end
      local slept = h.time.sleep_ms(LIMITS.POLL_MS)
      if not slept then
        sleep_failure = "the bounded kill-wait sleep failed"
        break
      end
    end
  end

  local group_alive_after, final_probe_err = self:group_alive()
  if group_alive_after == nil then
    probe_failure = probe_failure or final_probe_err
  end

  local outcome_written = write_cancel_outcome(
    self, true, kill_sent, group_alive_after, grace_ms)
  local outcome_warning = nil
  if not terminal_written then
    outcome_warning = "the cancellation terminal record could not be written"
  end
  if not outcome_written then
    outcome_warning = outcome_warning or
      "the cancellation outcome record could not be written"
  end
  if probe_failure ~= nil or sleep_failure ~= nil then
    outcome_warning = outcome_warning or
      "the recorded-group state is unverified: "
      .. tostring(probe_failure or sleep_failure)
  end

  local recorded, audit_err = record_audit(self.meta, audit_event(self.meta,
    "process.cancel_outcome", {
      cancel_requested = true,
      terminal_reason = "cancelled",
      outcome = "cancelled",
      cleanup = group_alive_after == false and "swept" or "unverified",
    }))
  if not recorded then
    audit_warning = audit_warning
      or "the cancellation outcome audit record could not be written"
  end

  return {
    state = repeated and "already_requested" or "requested",
    terminal_reason = "cancelled",
    term_sent = true,
    kill_sent = kill_sent,
    group_alive_after = group_alive_after,
    grace_ms = grace_ms,
    pgid = self.recorded_pgid,
    audit_warning = audit_warning,
    audit_error = recorded and nil or audit_err,
    outcome_warning = outcome_warning,
  }
end

--- Remove this job's private files and directory.
-- Only the fixed job paths are removed; the job root and other jobs are never
-- touched. A live group or a failed removal is reported, not retried with a
-- broader path.
-- @return boolean ok, table? err
function Job:cleanup()
  local h = host()
  if not h then
    return false, job_error(WheelErrors.E_JOB_UNAVAILABLE, "the host seam is unavailable")
  end
  local names = {
    self.paths.lock,
    self.paths.wrapper,
    self.paths.outcome,
    self.paths.terminal,
    self.paths.cancel,
    self.paths.sweep,
    self.paths.status,
    self.paths.pgid,
    self.paths.out,
    self.paths.err,
    self.paths.diag,
    self.paths.stdin,
    self.paths.meta,
  }
  local first_err = nil
  for _, path in ipairs(names) do
    local info = h.fs.stat(path)
    if info.exists then
      if info.directory then
        if not h.fs.remove_dir(path) and first_err == nil then
          first_err = "a job control directory could not be removed"
        end
      elseif not info.symlink and info.regular then
        if not h.fs.remove_file(path) and first_err == nil then
          first_err = "a job file could not be removed"
        end
      elseif first_err == nil then
        first_err = "a job path is not a regular file"
      end
    end
  end
  if first_err == nil and not h.fs.remove_dir(self.dir) then
    first_err = "the job directory is not empty or could not be removed"
  end
  if first_err then
    return false, job_error(WheelErrors.E_JOB_CLEANUP_FAILED, first_err)
  end
  return true
end

-- ---------------------------------------------------------------------------
-- Public constructors and lookup
-- ---------------------------------------------------------------------------

--- Resolve and prepare the private job root.
-- `opts.root` is an explicit test/embedding override; otherwise the root is
-- `<private tmp dir>/jobs`. The directory is repaired to owned 0700.
-- @param opts table? { root = string? }
-- @return string? root, table? err
function WheelJob.resolve_root(opts)
  local h = host()
  if not h then
    return nil, job_error(WheelErrors.E_JOB_UNAVAILABLE, "the host seam is unavailable")
  end
  local root = type(opts) == "table" and opts.root or nil
  if root == nil or root == "" then
    local ok, dir = pcall(h.tmp.dir)
    if not ok or type(dir) ~= "string" then
      return nil, job_error(WheelErrors.E_JOB_UNAVAILABLE, "the private runtime directory is unavailable")
    end
    root = dir .. "/jobs"
  end
  root = normalize_absolute_dir(root)
  if not root then
    return nil, job_error(WheelErrors.E_JOB_UNAVAILABLE, "the job root must be a private absolute directory")
  end
  local info = h.fs.stat(root)
  if info.exists then
    if info.symlink or not info.directory then
      return nil, job_error(WheelErrors.E_JOB_UNAVAILABLE, "the job root is not a real directory")
    end
  elseif not h.fs.mkdir_p(root) then
    return nil, job_error(WheelErrors.E_JOB_UNAVAILABLE, "the job root could not be created")
  end
  -- Re-check immediately before chmod (a link can appear after the first
  -- stat) and immediately after it, so chmod never intentionally follows a
  -- replaced component of an explicit job_root.
  local before_chmod = h.fs.stat(root)
  if not before_chmod.exists or before_chmod.symlink or not before_chmod.directory then
    return nil, job_error(WheelErrors.E_JOB_UNAVAILABLE, "the job root is not a real directory")
  end
  if not h.fs.chmod(root, "700") then
    return nil, job_error(WheelErrors.E_JOB_UNAVAILABLE, "the job root mode could not be repaired")
  end
  local after_chmod = h.fs.stat(root)
  if not after_chmod.exists or after_chmod.symlink or not after_chmod.directory then
    return nil, job_error(WheelErrors.E_JOB_UNAVAILABLE, "the job root is not a real directory")
  end
  local verified, err = verify_directory(root)
  if not verified then
    return nil, err
  end
  return root
end

--- Return a job root without creating or repairing it.
-- Read-only lookup paths (the cancellation CLI) use this so a missing root is
-- a typed not-found instead of a directory-creation side effect.
-- @param root string
-- @return string? normalized, table? err
function WheelJob.existing_root(root)
  local normalized = normalize_absolute_dir(root)
  if not normalized then
    return nil, job_error(WheelErrors.E_JOB_UNAVAILABLE, "the job root must be a private absolute directory")
  end
  local h = host()
  if not h then
    return nil, job_error(WheelErrors.E_JOB_UNAVAILABLE, "the host seam is unavailable")
  end
  local info = h.fs.stat(normalized)
  if not info.exists or info.symlink or not info.directory then
    return nil, job_error(WheelErrors.E_JOB_NOT_FOUND, "the job root does not exist")
  end
  local verified, err = verify_directory(normalized)
  if not verified then
    return nil, err
  end
  return normalized
end

--- Create a fresh private job directory.
-- @param opts table? { root = string? }
-- @return table? job, table? err
function WheelJob.create(opts)
  local h = host()
  if not h then
    return nil, job_error(WheelErrors.E_JOB_UNAVAILABLE, "the host seam is unavailable")
  end
  local root, root_err = WheelJob.resolve_root(opts)
  if not root then
    return nil, root_err
  end

  for _ = 1, LIMITS.CREATE_ATTEMPTS do
    local job_id, id_err = random_hex(LIMITS.ID_HEX / 2)
    if not job_id then
      return nil, id_err
    end
    local dir = join(root, job_id)
    if h.fs.mkdir(dir) then
      local verified, verify_err = verify_directory(dir)
      if not verified then
        h.fs.remove_dir(dir)
        return nil, verify_err
      end
      local job = setmetatable({
        root = root,
        job_id = job_id,
        dir = dir,
        paths = paths_for(dir),
        generation = nil,
        recorded_pgid = nil,
        recorded_leader_pid = nil,
        timeout_ms = nil,
        started_ms = nil,
        audit = nil,
        meta = nil,
      }, Job)
      return job
    end
  end
  return nil, job_error(WheelErrors.E_JOB_UNAVAILABLE, "a fresh job directory could not be created")
end

--- Open and validate an existing job record.
-- @param root string
-- @param job_id string
-- @return table? job, table? err
function WheelJob.open(root, job_id)
  if not valid_hex(job_id, LIMITS.ID_HEX) then
    return nil, job_error(WheelErrors.E_JOB_METADATA_INVALID, "invalid job id")
  end
  local existing, root_err = WheelJob.existing_root(root)
  if not existing then
    return nil, root_err
  end
  local h = host()
  if not h then
    return nil, job_error(WheelErrors.E_JOB_UNAVAILABLE, "the host seam is unavailable")
  end
  local dir = join(existing, job_id)
  local info = h.fs.stat(dir)
  if not info.exists then
    return nil, job_error(WheelErrors.E_JOB_NOT_FOUND, "job not found")
  end
  local verified, verify_err = verify_directory(dir)
  if not verified then
    return nil, verify_err
  end

  local meta_info = h.fs.stat(join(dir, "job.meta"))
  if not meta_info.exists then
    return nil, job_error(WheelErrors.E_JOB_NOT_RUNNING, "job metadata is not published")
  end
  if meta_info.symlink or not meta_info.regular or meta_info.mode ~= FILE_MODE
    or meta_info.links ~= 1 then
    return nil, job_error(WheelErrors.E_JOB_METADATA_INVALID, "job metadata is not a private file")
  end
  local euid = h.fs.euid()
  if euid == nil or meta_info.uid ~= euid then
    return nil, job_error(WheelErrors.E_JOB_METADATA_INVALID, "job metadata is not owned by the current user")
  end
  local content = h.fs.read_file_bounded(join(dir, "job.meta"), LIMITS.META_BYTES + 1)
  if type(content) ~= "string" or #content > LIMITS.META_BYTES then
    return nil, job_error(WheelErrors.E_JOB_METADATA_INVALID, "job metadata is unreadable or oversized")
  end
  local meta, meta_err = parse_meta(content, job_id)
  if not meta then
    return nil, meta_err
  end

  local job = setmetatable({
    root = existing,
    job_id = job_id,
    dir = dir,
    paths = paths_for(dir),
    generation = meta.generation,
    recorded_pgid = meta.pgid,
    recorded_leader_pid = meta.leader_pid,
    timeout_ms = meta.timeout_ms,
    started_ms = meta.started_ms,
    audit = meta.audit_dir and {
      dir = meta.audit_dir,
      high_risk = meta.audit_high_risk == true,
      role = meta.audit_role,
      agent = meta.audit_agent,
      task = meta.audit_task,
      tool = meta.audit_tool,
      intent = meta.audit_intent,
    } or nil,
    meta = meta,
  }, Job)
  return job
end

--- Return a random lowercase hex token (for job ids and generation tokens).
-- @param byte_count number
-- @return string? token, table? err
function WheelJob.random_token(byte_count)
  if not valid_int(byte_count, 1, 64) then
    return nil, job_error(WheelErrors.E_JOB_METADATA_INVALID, "invalid token size")
  end
  return random_hex(byte_count)
end

--- Resolve the default private job root without creating it.
-- The path mirrors `WheelHost.tmp.dir()` plus the `jobs` component, so the
-- read-only CLI can report a missing root as a typed not-found instead of
-- creating a directory as a side effect of a refused cancel.
-- @return string? root
local function default_root()
  local runtime = os.getenv("XDG_RUNTIME_DIR")
  if type(runtime) == "string" and runtime ~= "" then
    return runtime .. "/wheel/jobs"
  end
  local state = os.getenv("XDG_STATE_HOME")
  if type(state) == "string" and state ~= "" then
    return state .. "/wheel/tmp/jobs"
  end
  local home = os.getenv("HOME")
  if type(home) == "string" and home ~= "" then
    return home .. "/.local/state/wheel/tmp/jobs"
  end
  return nil
end

--- Cancel one recorded job by id.
-- @param root string? explicit job root; defaults to the private runtime root
-- @param job_id string
-- @param opts table? { grace_ms = number? }
-- @return table? info, table? err
function WheelJob.cancel(root, job_id, opts)
  if root == nil or root == "" then
    root = default_root()
  end
  if root == nil then
    return nil, job_error(WheelErrors.E_JOB_UNAVAILABLE,
      "the private runtime directory is unavailable")
  end
  local job, open_err = WheelJob.open(root, job_id)
  if not job then
    return nil, open_err
  end
  return job:request_cancel(opts)
end

-- ---------------------------------------------------------------------------
-- CLI surface (used by scripts/wheel-proc)
-- ---------------------------------------------------------------------------

local CLI_FORMAT = "wheel-proc/1"
local CLI_EXIT_OK = 0
local CLI_EXIT_USAGE = 2
local CLI_EXIT_ALREADY_EXITED = 3
local CLI_EXIT_REFUSED = 4

local CLI_USAGE = [[
Usage: wheel-proc cancel JOB_ID [--root DIR] [--grace-ms N]

Commands:
  cancel JOB_ID   validate the private job record and cancel its recorded group
  help            show this help

The job root defaults to <private runtime>/wheel/jobs. --root is the explicit
job root used by WheelHost.proc.start({ job_root = ... }). --grace-ms bounds
the TERM-to-KILL interval (default 250, maximum 2000). The command is
same-user only; it refuses a missing, tampered, or stale generation.
]]

local function json_escape(value)
  local text = tostring(value or "")
  text = text:gsub("\\", "\\\\")
  text = text:gsub('"', '\\"')
  text = text:gsub("\n", "\\n")
  text = text:gsub("\r", "\\r")
  text = text:gsub("\t", "\\t")
  text = text:gsub("%c", function(char)
    return string.format("\\u%04x", string.byte(char))
  end)
  return '"' .. text .. '"'
end

local function json_value(value)
  local kind = type(value)
  if kind == "string" then
    return json_escape(value)
  end
  if kind == "number" then
    if value ~= value or value == math.huge or value == -math.huge then
      return "null"
    end
    return tostring(value)
  end
  if kind == "boolean" then
    return value and "true" or "false"
  end
  if kind == "table" then
    local parts = {}
    for key, item in pairs(value) do
      parts[#parts + 1] = json_escape(key) .. ":" .. json_value(item)
    end
    return "{" .. table.concat(parts, ",") .. "}"
  end
  return "null"
end

local function cli_emit(record)
  io.stdout:write(json_value(record), "\n")
  io.stdout:flush()
end

local function cli_usage_error(message)
  io.stderr:write("wheel-proc: " .. tostring(message) .. "\n")
  io.stderr:write(CLI_USAGE)
  return CLI_EXIT_USAGE
end

--- Run the `scripts/wheel-proc` command surface.
-- The shell wrapper supplies the positional `arg` table. This function never
-- resolves a name or pattern to a signal target: the job id selects a private
-- metadata record, and `WheelJob.open` validates ownership, mode, size, and the
-- recorded leader generation before any signal.
-- @param argv table? positional arguments (Lua `arg`)
-- @return number process exit status
function WheelJob.cli(argv)
  local args = type(argv) == "table" and argv or {}
  local command = nil
  local job_id = nil
  local root = nil
  local grace_ms = nil
  local index = 1

  while args[index] ~= nil do
    local value = tostring(args[index])
    if value == "-h" or value == "--help" or value == "help" then
      command = "help"
      index = index + 1
    elseif value == "--root" then
      local next_value = args[index + 1]
      if next_value == nil or next_value == "" then
        return cli_usage_error("--root requires a directory")
      end
      root = tostring(next_value)
      index = index + 2
    elseif value == "--grace-ms" then
      local next_value = args[index + 1]
      local number = tonumber(next_value)
      if number == nil or number ~= math.floor(number) then
        return cli_usage_error("--grace-ms requires an integer")
      end
      grace_ms = number
      index = index + 2
    elseif value:sub(1, 1) == "-" then
      return cli_usage_error("unknown option: " .. value)
    elseif command == nil then
      command = value
      index = index + 1
    elseif job_id == nil then
      job_id = value
      index = index + 1
    else
      return cli_usage_error("too many arguments")
    end
  end

  if command == "help" then
    io.stdout:write(CLI_USAGE)
    return CLI_EXIT_OK
  end
  if command ~= "cancel" then
    return cli_usage_error(command == nil and "missing command"
      or "unknown command: " .. tostring(command))
  end
  if job_id == nil or job_id == "" then
    return cli_usage_error("cancel requires a job id")
  end

  local info, err = WheelJob.cancel(root, job_id, { grace_ms = grace_ms })
  if not info then
    local failure = type(err) == "table" and err or {}
    cli_emit({
      format = CLI_FORMAT,
      job_id = job_id,
      state = "refused",
      error = {
        class = type(failure.class) == "string" and failure.class or "runtime",
        code = type(failure.code) == "string" and failure.code or "E_INTERNAL",
        message = type(failure.message) == "string" and failure.message
          or "the job could not be cancelled",
      },
    })
    return CLI_EXIT_REFUSED
  end

  cli_emit({
    format = CLI_FORMAT,
    job_id = job_id,
    state = info.state,
    terminal_reason = info.terminal_reason,
    term_sent = info.term_sent == true,
    kill_sent = info.kill_sent == true,
    group_alive_after = info.group_alive_after,
    pgid = info.pgid,
    audit_warning = info.audit_warning,
    outcome_warning = info.outcome_warning,
  })

  if info.state == "already_exited" then
    return CLI_EXIT_ALREADY_EXITED
  end
  return CLI_EXIT_OK
end

return WheelJob
