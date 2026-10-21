-- bench/lib/env.lua
-- Environment metadata for benchmark records.
--
-- Durable records are per-environment evidence, not cross-host comparisons.
-- This module records the interpreter, CPU model, OS/kernel/architecture,
-- affinity pin, and Wheel revision, but never the checkout path, the user
-- name, the hostname, or any other host path. Values that cannot be
-- discovered become "unknown" rather than a guessed default.

local M = {}

local function shell_quote(value)
  return "'" .. tostring(value or ""):gsub("'", "'\\''") .. "'"
end

local function first_line(path)
  local file = io.open(path, "r")
  if not file then
    return nil
  end
  local line = file:read("*l")
  file:close()
  return line
end

local function read_small_file(path, max_bytes)
  local file = io.open(path, "r")
  if not file then
    return nil
  end
  local data = file:read(max_bytes or 65536)
  file:close()
  return data
end

local function trim(value)
  if type(value) ~= "string" then
    return nil
  end
  return value:match("^%s*(.-)%s*$")
end

local function command_output(command)
  local pipe = io.popen(command .. " 2>/dev/null", "r")
  if not pipe then
    return nil
  end
  local output = pipe:read("*a")
  pipe:close()
  return output
end

local function basename(path)
  if type(path) ~= "string" or path == "" then
    return nil
  end
  return path:match("([^/\\]+)$") or path
end

local function cpu_model()
  local data = read_small_file("/proc/cpuinfo", 131072)
  if not data then
    return "unknown"
  end
  local model = data:match("model name%s*:%s*([^\n]+)")
  return trim(model) or "unknown"
end

local function cpu_count()
  local data = read_small_file("/proc/cpuinfo", 262144)
  if not data then
    return nil
  end
  local count = 0
  for _ in data:gmatch("\nprocessor%s*:") do
    count = count + 1
  end
  if count == 0 then
    return nil
  end
  return count
end

local function os_name()
  local data = read_small_file("/etc/os-release", 8192)
  if not data then
    return "unknown"
  end
  local pretty = data:match('PRETTY_NAME="([^"]*)"') or data:match("PRETTY_NAME=([^\n]+)")
  return trim(pretty) or "unknown"
end

local function git_value(root, arguments)
  local output = command_output("git -C " .. shell_quote(root) .. " " .. arguments)
  return trim(output)
end

--- Collect environment metadata for one benchmark run.
-- @param root string repository root (used for git, never recorded)
-- @return table
function M.collect(root)
  local revision = git_value(root, "rev-parse --short=12 HEAD")
  if revision == "" then
    revision = nil
  end

  local dirty_status = git_value(root, "status --porcelain")
  local dirty = nil
  if revision ~= nil then
    dirty = (dirty_status ~= nil and dirty_status ~= "")
  end

  local interpreter_name = basename(arg and arg[-1]) or "unknown"
  local is_jit = type(jit) == "table"
  local interpreter = _VERSION or "unknown"
  if is_jit then
    interpreter = interpreter .. " (" .. tostring(jit.version) .. ")"
  end

  local pinned = tonumber(os.getenv("WHEEL_BENCH_PINNED_CPU"))
  local pinning = "none"
  if pinned ~= nil then
    pinning = "taskset"
  end

  return {
    revision = revision or "unknown",
    dirty = dirty,
    interpreter = interpreter,
    interpreter_name = interpreter_name,
    jit = is_jit,
    cpu = cpu_model(),
    cpu_count = cpu_count(),
    os = os_name(),
    kernel = trim(read_small_file("/proc/sys/kernel/osrelease", 256)) or "unknown",
    arch = trim(command_output("uname -m")) or "unknown",
    pinning = pinning,
    pinned_cpu = pinned,
  }
end

return M
