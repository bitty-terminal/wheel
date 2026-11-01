local WheelCacheTelemetry = {}

WheelCacheTelemetry.DEFAULT_WINDOW = 20
WheelCacheTelemetry.MAX_WINDOW = 100
WheelCacheTelemetry.MAX_ID_BYTES = 128

local STATUS = {
  verified_hit = true,
  verified_miss = true,
  write_only = true,
  not_requested = true,
  unsupported = true,
  unknown = true,
  error = true,
}

local ID_FIELDS = {
  "endpoint",
  "cache_domain_version",
  "cache_policy_version",
  "tool_schema_version",
  "capability_version",
  "evidence_source",
}

local PROVIDERS = {
  anthropic = true,
  deepseek = true,
  mock = true,
  ollama = true,
  openai = true,
  stdio = true,
}
PROVIDERS["local"] = true

local EVIDENCE_SOURCES = {
  provider_response = true,
  provider_usage = true,
}

local function secret_shaped(value)
  local lower = value:lower()
  return lower:find("bearer%s+[%w%._%-]+") ~= nil
    or lower:find("sk%-[%w_%-]+") ~= nil
    or lower:find("gh[pousr]_[%w]+") ~= nil
    or lower:find("akia[%w]+") ~= nil
    or lower:find("ya29%.[%w_%-]+") ~= nil
    or lower:find("x%-api%-key%s*[:=]") ~= nil
    or lower:find("authorization%s*[:=]") ~= nil
    or lower:find("api[_%-]?key%s*[:=]") ~= nil
    or lower:find("token%s*[:=]") ~= nil
    or lower:find("secret%s*[:=]") ~= nil
    or lower:find("password%s*[:=]") ~= nil
    or lower:find("xox[baprs]%-[%w%-]+") ~= nil
    or lower:find("-----begin[%w%s%-]+private key-----") ~= nil
    or value:match("^[0-9a-fA-F]+$") ~= nil and #value >= 32
    or value:match("^[A-Za-z0-9_%-]+$") ~= nil and #value >= 48
    or value:match("^[%w_-]+%.[%w_-]+%.[%w_-]+$") ~= nil
end

local function bounded_identifier(value)
  if type(value) ~= "string" or value == "" then return nil end
  if secret_shaped(value) or value:find("\n", 1, true)
    or value:find("\r", 1, true) then
    return nil
  end
  if #value > WheelCacheTelemetry.MAX_ID_BYTES then return nil end
  return value
end

local function version_identifier(value)
  if type(value) ~= "string" or #value > 32 then return nil end
  if value:match("^v?%d+$") or value:match("^v?%d+%.%d+$")
    or value:match("^v?%d+%.%d+%.%d+$") then
    return value
  end
  return nil
end

local function endpoint_origin(value)
  if type(value) ~= "string" or #value > WheelCacheTelemetry.MAX_ID_BYTES then return nil end
  local scheme, authority = value:match("^(https?)://([^/?#]+)")
  if not scheme or authority:find("@", 1, true) or secret_shaped(authority) then return nil end
  if not authority:match("^[%w%.%-]+$") and not authority:match("^[%w%.%-]+:%d+$") then
    return nil
  end
  return scheme .. "://" .. authority
end

local function non_negative_number(value)
  return type(value) == "number" and value >= 0 and value < math.huge and value or nil
end

local function project_sample(source)
  local sample = {}
  local status = type(source.provider_cache_status) == "string"
    and source.provider_cache_status or "unknown"
  sample.provider_cache_status = STATUS[status] and status or "unknown"

  for _, field in ipairs(ID_FIELDS) do
    local value
    if field == "endpoint" then
      value = endpoint_origin(source[field])
    elseif field == "evidence_source" then
      local source_name = source[field]
      value = type(source_name) == "string" and EVIDENCE_SOURCES[source_name] and source_name or nil
    else
      value = version_identifier(source[field])
    end
    if value then sample[field] = value end
  end
  if type(source.provider) == "string" and PROVIDERS[source.provider] then
    sample.provider = source.provider
  end
  local model = bounded_identifier(source.model)
  if model and model:match("^[%w][%w._:/%-]*$") then sample.model = model end
  if source.prompt_cache_policy == "off" or source.prompt_cache_policy == "prefer"
    or source.prompt_cache_policy == "required" then
    sample.prompt_cache_policy = source.prompt_cache_policy
  end
  if type(source.prompt_cache_supported) == "boolean" then
    sample.prompt_cache_supported = source.prompt_cache_supported
  end

  sample.provider_cache_read_tokens = non_negative_number(source.cache_read_tokens)
  sample.provider_cache_write_tokens = non_negative_number(source.cache_creation_tokens)
  if sample.provider_cache_write_tokens == nil then
    sample.provider_cache_write_tokens = non_negative_number(source.cache_write_tokens)
  end

  local denominator = non_negative_number(source.provider_cache_read_denominator)
  if sample.provider_cache_read_tokens ~= nil and denominator and denominator > 0
    and sample.provider_cache_read_tokens <= denominator then
    sample.provider_cache_read_ratio = sample.provider_cache_read_tokens / denominator
  end

  local local_prefix_hash = type(source.local_prefix_hash) == "string"
    and source.local_prefix_hash:match("^[0-9a-f]+$")
    and #source.local_prefix_hash == 64 and source.local_prefix_hash or nil
  local local_prefix_reuse_ratio = non_negative_number(source.local_prefix_reuse_ratio)
  if local_prefix_hash then sample.local_prefix_hash = local_prefix_hash end
  if local_prefix_reuse_ratio and local_prefix_reuse_ratio <= 1 then
    sample.local_prefix_reuse_ratio = local_prefix_reuse_ratio
  end
  return sample, denominator
end

local function bounded_window(value)
  if type(value) ~= "number" or value ~= value or value == math.huge or value == -math.huge then
    value = WheelCacheTelemetry.DEFAULT_WINDOW
  else
    value = math.floor(value)
  end
  if value < 1 then return 1 end
  if value > WheelCacheTelemetry.MAX_WINDOW then return WheelCacheTelemetry.MAX_WINDOW end
  return value
end

--- Project the newest bounded window of normalized usage records.
function WheelCacheTelemetry.project(records, opts)
  records = type(records) == "table" and records or {}
  opts = type(opts) == "table" and opts or {}
  local window = bounded_window(opts.window)
  local ring, size, next_index = {}, 0, 1
  local record_count = #records
  local first_record = math.max(1, record_count - window + 1)

  for index = first_record, record_count do
    local source = records[index]
    if type(source) == "table" then
      local sample, denominator = project_sample(source)
      ring[next_index] = { sample = sample, denominator = denominator }
      next_index = next_index % window + 1
      size = math.min(size + 1, window)
    end
  end

  local samples = {}
  local start_index = size == window and next_index or 1
  for offset = 0, size - 1 do
    local index = (start_index + offset - 1) % window + 1
    samples[#samples + 1] = ring[index]
  end

  local status_counts = {}
  for status in pairs(STATUS) do status_counts[status] = 0 end
  local hits, misses, max_denominator = 0, 0, 0
  local projected_samples = {}
  for index, entry in ipairs(samples) do
    local sample = entry.sample
    projected_samples[index] = sample
    local status = sample.provider_cache_status
    status_counts[status] = status_counts[status] + 1
    if status == "verified_hit" then hits = hits + 1 end
    if status == "verified_miss" then misses = misses + 1 end
    if sample.provider_cache_read_tokens ~= nil and entry.denominator and entry.denominator > 0
      and sample.provider_cache_read_tokens <= entry.denominator then
      max_denominator = math.max(max_denominator, entry.denominator)
    end
  end

  local scaled_reads, scaled_denominators = 0, 0
  if max_denominator > 0 then
    for _, entry in ipairs(samples) do
      local read_tokens = entry.sample.provider_cache_read_tokens
      local denominator = entry.denominator
      if read_tokens ~= nil and denominator and denominator > 0 and read_tokens <= denominator then
        scaled_reads = scaled_reads + read_tokens / max_denominator
        scaled_denominators = scaled_denominators + denominator / max_denominator
      end
    end
  end

  local projection = {
    sample_count = size,
    window = window,
    samples = projected_samples,
    provider_cache_status_counts = status_counts,
    provider_cache_hit_rate = hits + misses > 0 and hits / (hits + misses) or nil,
    provider_cache_hit_samples = hits,
    provider_cache_miss_samples = misses,
    provider_cache_read_ratio = scaled_denominators > 0
      and math.min(1, scaled_reads / scaled_denominators) or nil,
  }
  return projection
end

return WheelCacheTelemetry
