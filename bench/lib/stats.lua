-- bench/lib/stats.lua
-- Pure Lua 5.1 descriptive statistics for the Wheel benchmark suite.
--
-- Definitions are fixed so a recorded series has one interpretation:
--   median = middle value for odd n, mean of the two middle values for even n
--   p95    = nearest rank, ceil(0.95 * n)
--   q1/q3  = nearest rank, ceil(0.25 * n) / ceil(0.75 * n)
--   iqr    = q3 - q1
-- No rounding is applied here; the renderers round for display only.

local M = {}

--- Describe a numeric sample series.
-- @param samples number[]
-- @return table|nil summary, string|nil error
function M.summarize(samples)
  if type(samples) ~= "table" or #samples == 0 then
    return nil, "statistics require at least one sample"
  end

  local sorted = {}
  local sum = 0
  for index = 1, #samples do
    local value = samples[index]
    if type(value) ~= "number" or value ~= value or value == math.huge or value == -math.huge then
      return nil, string.format("sample %d is not a finite number", index)
    end
    sorted[index] = value
    sum = sum + value
  end
  table.sort(sorted)

  local n = #sorted
  local function nearest_rank(percent)
    local index = math.ceil(percent * n)
    if index < 1 then index = 1 end
    if index > n then index = n end
    return sorted[index]
  end

  local median
  if n % 2 == 1 then
    median = sorted[(n + 1) / 2]
  else
    median = (sorted[n / 2] + sorted[n / 2 + 1]) / 2
  end

  local q1 = nearest_rank(0.25)
  local q3 = nearest_rank(0.75)

  return {
    n = n,
    min = sorted[1],
    median = median,
    p95 = nearest_rank(0.95),
    max = sorted[n],
    q1 = q1,
    q3 = q3,
    iqr = q3 - q1,
    mean = sum / n,
    sum = sum,
  }
end

--- Round every numeric field in a summary to `digits` decimal places.
-- @param summary table
-- @param digits integer?
-- @return table
function M.round(summary, digits)
  digits = digits or 3
  local factor = 10 ^ digits
  local out = {}
  for key, value in pairs(summary) do
    if key == "n" then
      out[key] = value
    elseif type(value) == "number" then
      out[key] = math.floor(value * factor + 0.5) / factor
    else
      out[key] = value
    end
  end
  return out
end

--- Report the ratio of two summaries, guarding a zero denominator.
-- @param numerator table
-- @param denominator table
-- @return number|nil
function M.ratio(numerator, denominator)
  if type(numerator) ~= "table" or type(denominator) ~= "table" then
    return nil
  end
  if denominator.median == 0 then
    return nil
  end
  return numerator.median / denominator.median
end

return M
