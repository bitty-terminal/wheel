package.path = "./lua/?.lua;./lua/?/init.lua;" .. package.path

local Telemetry = require("wheel.cache_telemetry")

local checks = 0
local function check(value, message)
  checks = checks + 1
  if not value then error("cache telemetry assertion failed: " .. message, 0) end
end

local function project(records, window)
  return Telemetry.project(records, { window = window })
end

local empty = project({}, 3)
check(empty.sample_count == 0 and empty.provider_cache_hit_rate == nil, "zero samples have no rate")

local one = project({ { provider_cache_status = "verified_hit", cache_read_tokens = 4,
  provider_cache_read_denominator = 10 } })
check(one.sample_count == 1 and one.provider_cache_hit_rate == 1, "one verified hit")
check(one.provider_cache_read_ratio == 0.4, "explicit denominator enables read ratio")
check(one.samples[1].provider_cache_read_ratio == 0.4, "sample read ratio uses explicit denominator")

local statuses = { "write_only", "verified_miss", "verified_hit", "unknown", "unsupported",
  "not_requested", "error" }
local samples = {}
for _, status in ipairs(statuses) do
  samples[#samples + 1] = {
    provider_cache_status = status,
    cache_read_tokens = status == "verified_hit" and 4 or nil,
    cache_creation_tokens = status == "write_only" and 8 or nil,
    provider_cache_read_denominator = status == "verified_hit" and 10 or nil,
  }
end
local mixed = project(samples)
for _, status in ipairs(statuses) do
  check(mixed.provider_cache_status_counts[status] == 1, "count for " .. status)
end
check(mixed.provider_cache_hit_rate == 0.5, "hit rate includes only verified hits and misses")
check(mixed.provider_cache_read_ratio == 0.4, "read ratio aggregates authoritative denominators")

local warmup = project({ { provider_cache_status = "write_only", cache_creation_tokens = 12 } })
check(warmup.provider_cache_hit_rate == nil and warmup.samples[1].provider_cache_write_tokens == 12,
  "write-only warmup does not count as a hit")

local window = project({
  { provider_cache_status = "verified_hit", local_prefix_reuse_ratio = 0.9 },
  { provider_cache_status = "verified_miss" },
  { provider_cache_status = "error" },
}, 2)
check(window.sample_count == 2 and window.samples[1].provider_cache_status == "verified_miss"
  and window.samples[2].provider_cache_status == "error", "rolling window retains newest records")
check(window.provider_cache_hit_rate == 0, "window rotates hit out of aggregate")

local unknown_denominator = project({
  { provider_cache_status = "verified_hit", cache_read_tokens = 4 },
})
check(unknown_denominator.samples[1].provider_cache_read_ratio == nil
  and unknown_denominator.provider_cache_read_ratio == nil, "missing denominator stays unknown")
local inconsistent_denominator = project({
  { provider_cache_status = "verified_hit", cache_read_tokens = 11,
    provider_cache_read_denominator = 10 },
})
check(inconsistent_denominator.provider_cache_read_ratio == nil
  and inconsistent_denominator.samples[1].provider_cache_read_ratio == nil,
  "read counts above denominator remain unknown")

local local_only = project({
  { local_prefix_hash = "local-hash", local_prefix_reuse_ratio = 1 },
})
check(local_only.samples[1].provider_cache_status == "unknown"
  and local_only.provider_cache_hit_rate == nil, "local hash cannot imply provider hit")
check(local_only.samples[1].local_prefix_reuse_ratio == 1, "local metric stays separately available")

local bounded = project({ { provider_cache_status = "verified_miss" } }, 10000)
check(bounded.window == Telemetry.MAX_WINDOW, "window has a hard maximum")

local redacted = project({ {
  provider_cache_status = "verified_hit",
  prompt_cache_policy = "prefer",
  provider = "openai",
  model = "model-safe",
  endpoint = "https://user:secret@example.test/v1?token=secret",
  cache_domain = "raw-provider-cache-id-secret",
  local_prefix_hash = "sk-secret-value",
  prompt = "private prompt",
  authorization = "Bearer secret",
  api_key = "secret",
} })
local safe = redacted.samples[1]
check(safe.provider == "openai" and safe.model == "model-safe", "authoritative safe identities survive")
check(safe.prompt_cache_policy == "prefer", "known policy is projected")
check(safe.endpoint == nil and safe.cache_domain == nil and safe.local_prefix_hash == nil,
  "credential-bearing endpoint and raw identifiers are omitted")
check(safe.prompt == nil and safe.authorization == nil and safe.api_key == nil,
  "prompt and secret fields are not projected")
local safe_endpoint = project({ {
  provider_cache_status = "unknown",
  endpoint = "https://provider.example/v1/chat?token=secret#fragment",
} }).samples[1]
check(safe_endpoint.endpoint == "https://provider.example",
  "endpoint projection retains only an origin, not path, query, or fragment")

local absent = project({ { provider_cache_status = "unsupported" } }).samples[1]
check(absent.provider == nil and absent.model == nil and absent.cache_domain_version == nil,
  "missing provider evidence is not invented")

print("PASS: cache telemetry (" .. checks .. " assertions)")
