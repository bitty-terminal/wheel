package.path = "./lua/?.lua;./lua/?/init.lua;" .. package.path

local Telemetry = require("wheel.cache_telemetry")
local WheelContext = require("wheel.context")

local checks = 0
local function check(value, message)
  checks = checks + 1
  if not value then error("cache telemetry assertion failed: " .. message, 0) end
end

local function project(records, window)
  return Telemetry.project(records, { window = window })
end

local context = WheelContext.new()
local stable_prompt = {
  system_instruction = "You are a coding assistant.",
  project_rules = { "Keep changes focused", "Use deterministic tests" },
  tool_schemas = { "read_file", "write_file" },
}
local first_compile = assert(context:compile_prompt({
  system_instruction = stable_prompt.system_instruction,
  project_rules = stable_prompt.project_rules,
  tool_schemas = stable_prompt.tool_schemas,
  turn_prompt = "Inspect the current implementation.",
}))
local second_compile = assert(context:compile_prompt({
  system_instruction = stable_prompt.system_instruction,
  project_rules = stable_prompt.project_rules,
  tool_schemas = stable_prompt.tool_schemas,
  turn_prompt = "Now write a detailed regression test for the tail change.",
}))
check(first_compile.prefix_cache_key == second_compile.prefix_cache_key,
  "dynamic tail changes preserve the compiler stable-prefix key")
check(first_compile.cache_share_ratio ~= second_compile.cache_share_ratio,
  "dynamic tail changes update the compiler local reuse ratio")

local compiler_projection = project({
  { local_prefix_hash = first_compile.prefix_cache_key,
    local_prefix_reuse_ratio = first_compile.cache_share_ratio },
  { local_prefix_hash = second_compile.prefix_cache_key,
    local_prefix_reuse_ratio = second_compile.cache_share_ratio },
})
local first_compiled_sample, second_compiled_sample = unpack(compiler_projection.samples)
check(first_compiled_sample.local_prefix_reuse_ratio == first_compile.cache_share_ratio
  and second_compiled_sample.local_prefix_reuse_ratio == second_compile.cache_share_ratio,
  "projection preserves each compiler local reuse ratio separately")
check(first_compiled_sample.local_prefix_hash == nil and second_compiled_sample.local_prefix_hash == nil,
  "projection omits both compiler prefix hashes")
check(first_compiled_sample.provider_cache_status == "unknown"
  and second_compiled_sample.provider_cache_status == "unknown"
  and compiler_projection.provider_cache_hit_rate == nil,
  "local compiler digests do not imply provider cache evidence")

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

local fractional_provider_counts = project({
  { provider_cache_status = "verified_hit", cache_read_tokens = 4.5,
    provider_cache_read_denominator = 10 },
  { provider_cache_status = "verified_hit", cache_read_tokens = 4,
    provider_cache_read_denominator = 10.5 },
  { provider_cache_status = "write_only", cache_creation_tokens = 2.5 },
  { provider_cache_status = "write_only", cache_write_tokens = 3.5 },
})
local fractional_read, fractional_denominator, fractional_native_write, fractional_fallback_write =
  unpack(fractional_provider_counts.samples)
check(fractional_read.provider_cache_read_tokens == nil
  and fractional_read.provider_cache_read_ratio == nil,
  "fractional provider read counts do not project")
check(fractional_denominator.provider_cache_read_tokens == 4
  and fractional_denominator.provider_cache_read_ratio == nil,
  "fractional read denominator does not produce a ratio")
check(fractional_native_write.provider_cache_write_tokens == nil,
  "fractional native provider write counts do not project")
check(fractional_fallback_write.provider_cache_write_tokens == nil,
  "fractional provider write fallback does not project")
check(fractional_provider_counts.provider_cache_read_ratio == nil,
  "fractional provider counts do not produce an aggregate ratio")
local fractional_local_ratio = project({ { local_prefix_reuse_ratio = 0.75 } }).samples[1]
check(fractional_local_ratio.local_prefix_reuse_ratio == 0.75,
  "local prefix reuse ratio retains fractional precision")

local local_only = project({
  { local_prefix_hash = "local-hash", local_prefix_reuse_ratio = 1 },
})
check(local_only.samples[1].provider_cache_status == "unknown"
  and local_only.provider_cache_hit_rate == nil, "local hash cannot imply provider hit")
check(local_only.samples[1].local_prefix_hash == nil, "arbitrary local prefix hash is omitted")
check(local_only.samples[1].local_prefix_reuse_ratio == 1, "local metric stays separately available")
local valid_prefix_hash = string.rep("a", 64)
local valid_hash_sample = project({ { local_prefix_hash = valid_prefix_hash } }).samples[1]
check(valid_hash_sample.local_prefix_hash == nil, "valid local prefix digest is omitted")

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
  check(rejected.local_prefix_hash == nil, "malformed local prefix values are omitted")
end
local secret_hash_sample = project({ { local_prefix_hash = "sk-secret-value" } }).samples[1]
check(secret_hash_sample.local_prefix_hash == nil, "secret-shaped local prefix hash is omitted")
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
