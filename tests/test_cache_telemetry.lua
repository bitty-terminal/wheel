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
local valid_prefix_hash = string.rep("a", 64)
local hashed = project({ { local_prefix_hash = valid_prefix_hash } })
check(hashed.samples[1].local_prefix_hash == valid_prefix_hash,
  "Wheel SHA-256 digest is retained")

local bounded = project({ { provider_cache_status = "verified_miss" } }, 10000)
check(bounded.window == Telemetry.MAX_WINDOW, "window has a hard maximum")
local nan_window = project({}, 0 / 0)
check(nan_window.window == Telemetry.DEFAULT_WINDOW, "NaN window uses the default")
local infinite_window = project({}, math.huge)
check(infinite_window.window == Telemetry.DEFAULT_WINDOW, "infinite window uses the default")

local max_finite = 1.7976931348623157e308
local large_counts = project({
  { cache_read_tokens = max_finite, provider_cache_read_denominator = max_finite },
  { cache_read_tokens = max_finite, provider_cache_read_denominator = max_finite },
})
check(large_counts.provider_cache_read_ratio ~= nil
  and large_counts.provider_cache_read_ratio >= 0 and large_counts.provider_cache_read_ratio <= 1,
  "large finite counters produce a finite bounded aggregate ratio")

local redacted = project({ {
  provider_cache_status = "verified_hit",
  prompt_cache_policy = "prefer",
  provider = "openai",
  model = "model-safe",
  cache_domain_version = "1.2",
  cache_policy_version = "v2",
  tool_schema_version = "3",
  capability_version = "1.0.4",
  evidence_source = "provider_usage",
  endpoint = "https://user:secret@example.test/v1?token=secret",
  cache_domain = "raw-provider-cache-id-secret",
  local_prefix_hash = "sk-secret-value",
  prompt = "private prompt",
  authorization = "Bearer secret",
  api_key = "secret",
} })
local safe = redacted.samples[1]
check(safe.provider == "openai" and safe.model == "model-safe", "authoritative safe identities survive")
local legacy_ollama = project({ { provider = "ollama" } }).samples[1]
check(legacy_ollama.provider == "ollama", "legacy ollama provider identity is allowlisted")
check(safe.cache_domain_version == "1.2" and safe.cache_policy_version == "v2"
  and safe.tool_schema_version == "3" and safe.capability_version == "1.0.4"
  and safe.evidence_source == "provider_usage", "known bounded metadata survives")
check(safe.prompt_cache_policy == "prefer", "known policy is projected")
check(safe.endpoint == nil and safe.cache_domain == nil and safe.local_prefix_hash == nil,
  "credential-bearing endpoint and raw identifiers are omitted")
check(safe.prompt == nil and safe.authorization == nil and safe.api_key == nil,
  "prompt and secret fields are not projected")
local rejected_metadata = {
  { provider = "my-private-gateway-secret" },
  { provider = "openai api_key=abc" },
  { model = "Bearer abc.def" },
  { model = "ghp_abcdefghijklmnopqrstuvwxyz0123456789" },
  { model = "akia1234567890EXAMPLE" },
  { model = "xoxb-123456-secret" },
  { model = "token=private-value" },
  { model = "authorization:private-value" },
  { model = "x-api-key=private-value" },
  { model = string.rep("a", 48) },
  { model = "ya29." .. string.rep("a", 32) },
  { model = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.signature" },
}
for _, fields in ipairs(rejected_metadata) do
  local rejected = project({ fields }).samples[1]
  check(rejected.provider == nil and rejected.model == nil,
    "unrecognized or secret-shaped identity metadata is omitted")
end
local malformed_hashes = { "local-hash", string.rep("a", 63), string.rep("a", 65),
  string.rep("A", 64), string.rep("g", 64), "sha256:" .. string.rep("a", 64) }
for _, hash in ipairs(malformed_hashes) do
  local rejected = project({ { local_prefix_hash = hash } }).samples[1]
  check(rejected.local_prefix_hash == nil, "non-digest local prefix values are omitted")
end
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
