-- bench/lib/time.lua
-- Clock helpers for the Wheel benchmark suite (pure Lua 5.1).
--
-- CPU time always comes from os.clock(), which is process CPU time on the
-- supported interpreters. `WheelHost.time.now()` is not used for wall-clock
-- benchmarking because the standalone POSIX backend maps it to os.time(),
-- whose one-second resolution cannot time sub-second scenarios.
--
-- Wall time prefers /proc/uptime (Linux, 10 ms resolution, monotonic and
-- cheap to read). When that file is unavailable the fallback is os.time(),
-- and the recorded resolution becomes one second. The chosen source is part
-- of the result metadata so no reader assumes better precision than exists.

local M = {}

local function read_proc_uptime()
  local file = io.open("/proc/uptime", "r")
  if not file then
    return nil
  end
  local line = file:read("*l")
  file:close()
  if type(line) ~= "string" then
    return nil
  end
  local seconds = line:match("^(%d+%.?%d*)")
  return tonumber(seconds)
end

if read_proc_uptime() ~= nil then
  M.wall_source = "proc_uptime"
  M.wall_resolution_ms = 10
else
  M.wall_source = "os.time"
  M.wall_resolution_ms = 1000
end

--- Process CPU seconds.
-- @return number
function M.cpu()
  return os.clock()
end

--- Monotonic wall-clock seconds at the best available resolution.
-- @return number
function M.wall()
  local uptime = read_proc_uptime()
  if uptime ~= nil then
    return uptime
  end
  return os.time()
end

--- Convert a pair of clock readings to microseconds.
-- @param before number
-- @param after number
-- @return number
function M.micros(before, after)
  return (after - before) * 1000000
end

--- Convert a pair of clock readings to milliseconds.
-- @param before number
-- @param after number
-- @return number
function M.millis(before, after)
  return (after - before) * 1000
end

return M
