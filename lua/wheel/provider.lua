-- lua/wheel/provider.lua
-- Wheel: Uniform Model Provider Abstraction, SSE Streaming Parser, and Adapters
--
-- Pure Lua 5.1 / LuaJIT implementation with zero external C dependencies.
-- Provides:
-- 1. Uniform Provider Interface (complete, stream).
-- 2. Line-buffered SSE Parser (WheelProvider.SSEParser) handling fragmented chunks and [DONE].
-- 3. Tool schema formatters for OpenAI (type="function") and Anthropic (input_schema).
-- 4. Adapters:
--    - MockProvider: In-memory completion and streaming simulation for offline tests/CI.
--    - OpenAIAdapter: /v1/chat/completions REST and SSE streaming (GPT-4o, DeepSeek, Ollama).
--    - AnthropicAdapter: /v1/messages REST and SSE streaming (Claude 3.5 Sonnet, thinking blocks).
--    - StdioAdapter: Subprocess CLI streaming runner.
-- 5. Factory (WheelProvider.create) binding heterogeneous ModelProfiles to adapters.

local WheelProvider = {}
local WheelErrors = require("wheel.errors")
local ok_rationale, Rationale = pcall(require, "wheel.rationale")
if not ok_rationale then
  local ok_rationale2, Rationale2 = pcall(require, "lua.wheel.rationale")
  Rationale = ok_rationale2 and Rationale2 or nil
end
if not Rationale then
  error("wheel.provider: cannot load bounded rationale schema", 0)
end

WheelProvider.Rationale = Rationale

local ok_kernel, WheelKernel = pcall(require, "wheel.kernel")
if not ok_kernel then
  local ok_kernel2, WheelKernel2 = pcall(require, "lua.wheel.kernel")
  WheelKernel = ok_kernel2 and WheelKernel2 or nil
end

--- Load the host seam strictly for the StdioAdapter temp-file and process path.
-- Remote adapters do not touch the seam, but the module owns one loader so a
-- broken installation fails at the seam rather than at a nil call site. A
-- typed seam error (for example an unsupported platform) is re-raised
-- unchanged so its class/code survive.
local function load_host()
  local rooted = "wheel.host"
  local ok, mod = pcall(require, rooted)
  if ok then return mod end
  package.loaded[rooted] = nil
  local cause = mod
  if WheelErrors.is_typed(cause) then
    error(cause, 0)
  end
  if type(cause) ~= "string"
    or not cause:find("module '" .. rooted .. "' not found", 1, true) then
    error("wheel.provider: cannot load submodule 'wheel.host': " .. tostring(cause), 0)
  end

  local alternate = "lua.wheel.host"
  ok, mod = pcall(require, alternate)
  if ok then return mod end
  package.loaded[alternate] = nil
  if WheelErrors.is_typed(mod) then
    error(mod, 0)
  end
  if type(mod) == "string"
    and mod:find("module '" .. alternate .. "' not found", 1, true) then
    mod = cause
  end
  error("wheel.provider: cannot load submodule 'wheel.host': " .. tostring(mod), 0)
end

local WheelHost = load_host()

local json = (WheelKernel and WheelKernel.JSON) or nil
if not json then
  local ok_json, cjson = pcall(require, "cjson")
  if ok_json then
    json = cjson
  end
end

-- Fallback JSON stringifier/parser if none loaded
if not json then
  json = {
    encode = function(val)
      if val == nil then return "null" end
      local t = type(val)
      if t == "number" or t == "boolean" then return tostring(val) end
      if t == "string" then return string.format("%q", val) end
      if t == "table" then
        local is_array = (#val > 0)
        local items = {}
        if is_array then
          for _, v in ipairs(val) do table.insert(items, json.encode(v)) end
          return "[" .. table.concat(items, ",") .. "]"
        else
          for k, v in pairs(val) do
            table.insert(items, string.format("%q:%s", tostring(k), json.encode(v)))
          end
          return "{" .. table.concat(items, ",") .. "}"
        end
      end
      return "null"
    end,
    decode = function(str)
      return { raw = str }
    end,
  }
end

WheelProvider.JSON = json

--- Convert a provider response into a bounded rationale record.
-- Provider thinking remains on the transient response object and is never
-- copied into this record unless it is a complete, schema-valid JSON object.
-- @param response table|nil
-- @param opts table? { task_id = string?, session_id = string? }
-- @return table bounded rationale
function WheelProvider.parse_rationale(response, opts)
  return Rationale.with_legacy_labels(Rationale.from_response(response, json, opts))
end

-- ---------------------------------------------------------------------------
-- Completion Budget
-- ---------------------------------------------------------------------------

--- Named default completion-token budget sent with every provider request.
-- The context window is a separate budget (`context_budget` on model
-- profiles); this limit caps generated completion tokens only. Sending it
-- explicitly prevents a provider from assuming the model's maximum completion
-- window for credit, latency, and cost checks.
WheelProvider.DEFAULT_MAX_COMPLETION_TOKENS = 4096

--- Hard upper bound for a caller-supplied completion-token budget.
WheelProvider.MAX_COMPLETION_TOKENS = 32768

WheelProvider.DEFAULT_PROMPT_CACHE_POLICY = "prefer"
WheelProvider.PROMPT_CACHE_POLICIES = { off = true, prefer = true, required = true }
WheelProvider.PROMPT_CACHE_CAPABILITY_VERSION = "wheel-prompt-cache/1"
WheelProvider.MAX_PROMPT_CACHE_PREFIX_BYTES = 64 * 1024
local OPENAI_BASE_URL = "https://api.openai.com/v1"
local ANTHROPIC_BASE_URL = "https://api.anthropic.com/v1"

--- Hash cache identity through the shared configuration boundary, or decline.
local function prompt_cache_digest(value)
  local ok, config = pcall(require, "wheel.config")
  if not ok then ok, config = pcall(require, "lua.wheel.config") end
  if ok and type(config.compute_hash) == "function" then
    return config.compute_hash(value)
  end
  return nil
end

--- Resolve request, adapter, then default policy and reject invalid values.
function WheelProvider.resolve_prompt_cache_policy(request, configured)
  local request_policy = request and request.prompt_cache_policy
  if request_policy ~= nil and type(request_policy) ~= "string" then
    return nil, "prompt_cache_policy must be off, prefer, or required"
  end
  if configured ~= nil and type(configured) ~= "string" then
    return nil, "prompt_cache_policy must be off, prefer, or required"
  end
  local policy = request_policy
  if policy == nil then policy = configured end
  if policy == nil then policy = WheelProvider.DEFAULT_PROMPT_CACHE_POLICY end
  if not WheelProvider.PROMPT_CACHE_POLICIES[policy] then
    return nil, "prompt_cache_policy must be off, prefer, or required"
  end
  return policy
end

--- Reject required caching before transport when capability or prefix is absent.
function WheelProvider.validate_prompt_cache_request(request, adapter)
  local policy, err = WheelProvider.resolve_prompt_cache_policy(request, adapter and adapter.prompt_cache_policy)
  if not policy then return nil, err end
  if policy == "required" and not (adapter and adapter.prompt_cache_supported) then
    return nil, "required prompt caching is unsupported by this provider"
  end
  if policy == "required" and (type(request.stable_context_prefix) ~= "string"
    or #request.stable_context_prefix == 0) then
    return nil, "required prompt caching needs a stable Context prefix"
  end
  return policy
end

--- Build the cache-key domain from provider identity, request policy, and schema.
-- The returned digest intentionally excludes prompt content; callers combine
-- it with the exact serialized stable prefix before producing a provider key.
function WheelProvider.cache_domain(request, provider, model, endpoint, policy)
  request = request or {}
  local schema = request.tools and json.encode(request.tools) or "[]"
  local material = table.concat({
    tostring(provider or ""), tostring(model or ""), tostring(endpoint or ""),
    tostring(policy or WheelProvider.DEFAULT_PROMPT_CACHE_POLICY), schema,
    tostring(request.cache_policy_version or "1"), tostring(request.tool_schema_version or "1"),
    WheelProvider.PROMPT_CACHE_CAPABILITY_VERSION,
  }, "\0")
  return prompt_cache_digest(material)
end

--- Normalize only explicit provider usage fields into cross-provider telemetry.
-- Missing cache counters stay unknown, malformed counters produce `error`, and
-- OpenAI uncached input excludes only explicitly reported cached reads.
-- Native counters precede top-level read/write/creation aliases. Conflicting
-- duplicates report error without replacing the first selected counter.
function WheelProvider.normalize_usage(usage, provider)
  if type(usage) ~= "table" then return nil end
  local normalized = {}
  local read_count, read_present, write_count
  local malformed_cache_usage = false
  --- Accept only finite, nonnegative integer token counts.
  local function valid_cache_count(value)
    return type(value) == "number" and value >= 0 and value % 1 == 0
  end
  --- Select the first present counter once; validate every duplicate alias.
  local function select_cache_count(...)
    local selected, count
    for index = 1, select("#", ...) do
      local value = select(index, ...)
      if value ~= nil then
        local valid = valid_cache_count(value)
        if not valid then malformed_cache_usage = true end
        if selected == nil then
          selected = value
          if valid then count = value end
        elseif value ~= selected then
          malformed_cache_usage = true
        end
      end
    end
    return count, selected ~= nil
  end
  --- Copy a valid usage count without coercing missing or malformed values.
  local function copy(target, source)
    local value = usage[source]
    if type(value) == "number" and value >= 0 and value % 1 == 0 then
      normalized[target] = value
    end
  end
  if provider == "anthropic" then
    -- Anthropic input_tokens excludes cache-read tokens; retain that exact
    -- uncached-input meaning in the explicit cross-provider field.
    copy("prompt_tokens", "input_tokens")
    copy("uncached_input_tokens", "input_tokens")
    copy("completion_tokens", "output_tokens")
    copy("input_tokens", "input_tokens")
    copy("output_tokens", "output_tokens")
    read_count, read_present = select_cache_count(usage.cache_read_input_tokens, usage.cache_read_tokens)
    write_count = select_cache_count(usage.cache_creation_input_tokens,
      usage.cache_write_tokens, usage.cache_creation_tokens)
  else
    -- OpenAI prompt_tokens includes cached tokens when the provider reports
    -- them. The uncached field removes cache reads; cache writes are not reads.
    copy("prompt_tokens", "prompt_tokens")
    local details = type(usage.prompt_tokens_details) == "table" and usage.prompt_tokens_details or {}
    if usage.prompt_tokens_details ~= nil and type(usage.prompt_tokens_details) ~= "table" then
      malformed_cache_usage = true
    end
    read_count, read_present = select_cache_count(details.cached_tokens, usage.cache_read_tokens)
    write_count = select_cache_count(details.cache_write_tokens,
      usage.cache_write_tokens, usage.cache_creation_tokens)
  end
  if provider ~= "anthropic" or usage.output_tokens == nil then
    copy("completion_tokens", "completion_tokens")
  end
  copy("total_tokens", "total_tokens")
  normalized.cache_read_tokens = read_count
  normalized.cache_creation_tokens = write_count
  if provider ~= "anthropic" and normalized.prompt_tokens ~= nil
    and read_present and read_count ~= nil and not malformed_cache_usage
    and read_count <= normalized.prompt_tokens then
    normalized.uncached_input_tokens = normalized.prompt_tokens - read_count
  end
  if provider ~= "anthropic" and normalized.prompt_tokens ~= nil
    and read_count ~= nil and read_count > normalized.prompt_tokens then
    malformed_cache_usage = true
  end
  if malformed_cache_usage then
    normalized.provider_cache_status = "error"
  elseif read_count ~= nil and read_count > 0 then
    normalized.provider_cache_status = "verified_hit"
  elseif write_count ~= nil and write_count > 0 then
    normalized.provider_cache_status = "write_only"
  elseif provider == "openai" and read_present and read_count == 0 then
    -- OpenAI reports cached_tokens=0 on an uncached request and normally has
    -- no cache-write counter. Explicit zero read evidence is sufficient here;
    -- Anthropic still needs both counters to prove a miss.
    normalized.provider_cache_status = "verified_miss"
  elseif read_count ~= nil and write_count ~= nil then
    normalized.provider_cache_status = "verified_miss"
  else
    normalized.provider_cache_status = "unknown"
  end
  return next(normalized) and normalized or nil
end

--- Merge stream usage snapshots while retaining the strongest cache status.
local function merge_usage(current, incoming)
  current = current or {}
  incoming = incoming or {}
  local retained_status = WheelProvider.aggregate_cache_status(
    current.provider_cache_status, incoming.provider_cache_status)
  local retain_incoming_cache = retained_status == incoming.provider_cache_status
    and incoming.provider_cache_status ~= nil
  local cache_fields = {
    cache_read_tokens = true,
    cache_creation_tokens = true,
    uncached_input_tokens = true,
  }
  if retain_incoming_cache then
    for field in pairs(cache_fields) do current[field] = nil end
  end
  for field, value in pairs(incoming) do
    if field == "provider_cache_status" then
      current.provider_cache_status = retained_status
    elseif not cache_fields[field] or retain_incoming_cache or current.provider_cache_status == nil then
      current[field] = value
    end
  end
  return current
end

-- Aggregated cache status reports the strongest evidence seen across turns.
-- Errors dominate positive evidence; then a hit, write-only, verified miss,
-- unknown, not-requested, and unsupported. This field is independent of token
-- totals, which are always accumulated separately by the runner.
local CACHE_STATUS_PRIORITY = {
  unsupported = 1,
  not_requested = 2,
  unknown = 3,
  verified_miss = 4,
  write_only = 5,
  verified_hit = 6,
  error = 7,
}

--- Retain the strongest observed cache status regardless of arrival order.
function WheelProvider.aggregate_cache_status(current, incoming)
  local current_priority = CACHE_STATUS_PRIORITY[current] or 0
  local incoming_priority = CACHE_STATUS_PRIORITY[incoming] or 0
  if incoming_priority > current_priority then return incoming end
  return current
end

--- Combine request policy and capability with explicit provider usage evidence.
function WheelProvider.cache_usage_status(usage, request, adapter)
  request = request or {}
  local policy = WheelProvider.resolve_prompt_cache_policy(request, adapter and adapter.prompt_cache_policy)
  if not policy then return "error" end
  if policy == "off" or type(request.stable_context_prefix) ~= "string"
    or #request.stable_context_prefix == 0 then
    return "not_requested"
  end
  if not adapter or not adapter.prompt_cache_supported then return "unsupported" end
  return usage and usage.provider_cache_status or "unknown"
end

--- Attach provider-native cache metadata when the serialized stable prefix matches.
-- In `prefer` mode any unsupported or unverifiable setup leaves the payload
-- unchanged; `required` mode returns an error instead.
local function apply_prompt_cache(payload, request, adapter, provider, endpoint)
  local policy, policy_err = WheelProvider.resolve_prompt_cache_policy(request, adapter.prompt_cache_policy)
  if not policy then return nil, policy_err end
  if policy == "off" then return payload end
  local prefix = request.stable_context_prefix
  if type(prefix) == "string" and #prefix > WheelProvider.MAX_PROMPT_CACHE_PREFIX_BYTES then
    if policy == "required" then
      return nil, "required stable Context prefix exceeds the cache-key bound"
    end
    return payload
  end
  if type(prefix) ~= "string" or #prefix == 0 then
    if policy == "required" then return nil, "required prompt caching needs a stable Context prefix" end
    return payload
  end
  if not adapter.prompt_cache_supported then
    if policy == "required" then return nil, "required prompt caching is unsupported by this provider" end
    return payload
  end
  local wire_system
  if provider == "anthropic" then
    wire_system = type(payload.system) == "string" and payload.system or nil
  else
    for _, message in ipairs(payload.messages or {}) do
      if message.role == "system" then
        wire_system = type(message.content) == "string" and message.content or nil
        break
      end
    end
  end
  local wire_prefix = wire_system and wire_system:sub(1, #prefix) or nil
  if wire_prefix ~= prefix then
    if policy == "required" then
      return nil, "required stable Context prefix does not match the serialized system prefix"
    end
    return payload
  end
  local domain = WheelProvider.cache_domain(request, provider, request.model or adapter.model or "", endpoint, policy)
  local cache_key = domain and prompt_cache_digest(table.concat({ domain, wire_prefix }, "\0")) or nil
  if not cache_key then
    if policy == "required" then return nil, "required prompt caching needs a stable SHA-256 implementation" end
    return payload
  end
  if provider == "anthropic" then
    if type(payload.system) ~= "string" or #payload.system == 0 then
      if policy == "required" then return nil, "required prompt caching needs a stable Anthropic system prefix" end
      return payload
    end
    payload.system = {
      {
        type = "text",
        text = payload.system,
        cache_control = { type = "ephemeral" },
      },
    }
  else
    payload.prompt_cache_key = cache_key
  end
  return payload
end

--- Validate a completion-token budget override.
-- @param value number? Explicit bound; nil selects the named default.
-- @return number? effective bound, table? typed validation error
function WheelProvider.validate_max_completion_tokens(value)
  if value == nil then
    return WheelProvider.DEFAULT_MAX_COMPLETION_TOKENS, nil
  end
  if type(value) ~= "number" or value ~= value or value == math.huge or value == -math.huge then
    return nil, WheelErrors.completion_budget_invalid("max_completion_tokens must be a finite integer")
  end
  if value % 1 ~= 0 then
    return nil, WheelErrors.completion_budget_invalid("max_completion_tokens must be an integer")
  end
  if value <= 0 then
    return nil, WheelErrors.completion_budget_invalid("max_completion_tokens must be greater than zero")
  end
  if value > WheelProvider.MAX_COMPLETION_TOKENS then
    return nil, WheelErrors.completion_budget_invalid(string.format(
      "max_completion_tokens must not exceed %d",
      WheelProvider.MAX_COMPLETION_TOKENS
    ))
  end
  return value, nil
end

--- Resolve the effective completion budget for a request.
-- Precedence: request.max_completion_tokens, legacy request.max_tokens,
-- adapter/config override, named default. Every path is validated.
-- @param request table? Provider request.
-- @param configured number? Adapter or model-profile override.
-- @return number? effective bound, table? typed validation error
function WheelProvider.resolve_max_completion_tokens(request, configured)
  request = request or {}
  local value = request.max_completion_tokens
  if value == nil then
    value = request.max_tokens
  end
  if value == nil then
    value = configured
  end
  return WheelProvider.validate_max_completion_tokens(value)
end

-- ---------------------------------------------------------------------------
-- Opt-in Caller Attribution
-- ---------------------------------------------------------------------------
--
-- Attribution is caller-declared identity for gateway-side aggregation, not a
-- credential and not inferred. It is opt-in: an adapter with no attribution
-- configuration sends no identity headers and remains private/unattributed.
-- No product URL or title is defaulted here, and the values never enter a
-- prompt, request body, or log; they travel only as validated request headers.
--
-- Header names follow the OpenRouter Apps mechanism. `HTTP-Referer` is the
-- application identity, `X-OpenRouter-Title` only changes the display name,
-- and `X-OpenRouter-App-Visibility: hidden` applies when an app is created.
-- `categories` is an array of one or two lowercase tokens, joined into the
-- comma-separated header value. Callers who configure attribution own that
-- choice; Wheel ships no default.

--- Maximum byte length of the attribution referer.
WheelProvider.ATTRIBUTION_REFERER_MAX = 2048

--- Maximum byte length of the attribution display title.
WheelProvider.ATTRIBUTION_TITLE_MAX = 120

--- Maximum byte length of one category token.
WheelProvider.ATTRIBUTION_CATEGORY_MAX = 30

--- Maximum number of categories in one attribution block.
WheelProvider.ATTRIBUTION_MAX_CATEGORIES = 2

--- Maximum byte length of the joined category header (tokens plus commas).
WheelProvider.ATTRIBUTION_CATEGORIES_MAX = WheelProvider.ATTRIBUTION_MAX_CATEGORIES
  * WheelProvider.ATTRIBUTION_CATEGORY_MAX
  + (WheelProvider.ATTRIBUTION_MAX_CATEGORIES - 1)

local ATTRIBUTION_HEADER_NAMES = {
  referer = "HTTP-Referer",
  title = "X-OpenRouter-Title",
  categories = "X-OpenRouter-Categories",
  visibility = "X-OpenRouter-App-Visibility",
}

local ATTRIBUTION_FIELDS = {
  referer = true,
  title = true,
  categories = true,
  visibility = true,
}

--- Build the typed invalid-attribution failure.
-- Details are static diagnostic text; an untrusted value is never echoed.
-- @param detail string
-- @return table typed validation error
local function attribution_invalid(detail)
  return WheelErrors.args_invalid("provider.attribution", detail)
end

--- Split text on a literal single-character separator, keeping empty parts.
-- @param text string
-- @param separator string
-- @return table parts
local function split_literal(text, separator)
  local parts = {}
  local start = 1
  while true do
    local position = text:find(separator, start, true)
    if not position then
      parts[#parts + 1] = text:sub(start)
      return parts
    end
    parts[#parts + 1] = text:sub(start, position - 1)
    start = position + #separator
  end
end

--- Validate a dotted-decimal IPv4 address.
-- @param value string
-- @return boolean
local function valid_ipv4(value)
  local parts = split_literal(value, ".")
  if #parts ~= 4 then
    return false
  end
  for _, part in ipairs(parts) do
    if part == "" or #part > 3 or not part:match("^%d+$") then
      return false
    end
    if tonumber(part) > 255 then
      return false
    end
  end
  return true
end

--- Count IPv6 groups in one side of a `::` compression.
-- A trailing dotted-decimal IPv4 part consumes two groups and must be last.
-- @param segment string
-- @return number? groups, boolean ok
local function ipv6_group_count(segment)
  if segment == "" then
    return 0, true
  end
  local parts = split_literal(segment, ":")
  local groups = 0
  for index, part in ipairs(parts) do
    if part == "" then
      return nil, false
    end
    if part:find(".", 1, true) then
      if index ~= #parts or not valid_ipv4(part) then
        return nil, false
      end
      groups = groups + 2
    else
      if #part > 4 or not part:match("^[0-9A-Fa-f]+$") then
        return nil, false
      end
      groups = groups + 1
    end
  end
  return groups, true
end

--- Validate a bracketed IPv6 address (without the brackets).
-- Rejects empty, malformed, and multiply-compressed forms. A single `::`
-- may compress one or more zero groups; an IPv4 tail occupies two groups.
-- @param value string
-- @return boolean
local function valid_ipv6(value)
  if value == "" then
    return false
  end
  local compression = value:find("::", 1, true)
  if compression then
    local _, count = value:gsub("::", "")
    if count ~= 1 then
      return false
    end
    local head = value:sub(1, compression - 1)
    local tail = value:sub(compression + 2)
    -- An embedded IPv4 address must be the final 32 bits, so it cannot
    -- appear in the head of a compressed address.
    if head:find(".", 1, true) then
      return false
    end
    local head_groups, head_ok = ipv6_group_count(head)
    if not head_ok then
      return false
    end
    local tail_groups, tail_ok = ipv6_group_count(tail)
    if not tail_ok then
      return false
    end
    return head_groups + tail_groups < 8
  end
  local groups, ok = ipv6_group_count(value)
  return ok and groups == 8
end

--- Validate one DNS host label.
-- @param label string
-- @return boolean
local function valid_host_label(label)
  if label == "" or #label > 63 then
    return false
  end
  if not label:match("^[A-Za-z0-9][A-Za-z0-9-]*$") then
    return false
  end
  return label:sub(-1) ~= "-"
end

--- Validate a registered host name (DNS name or dotted-decimal IPv4).
-- A final dot is accepted as a rooted FQDN; empty labels are not.
-- @param host string
-- @return boolean
local function valid_registered_host(host)
  if host:sub(-1) == "." then
    host = host:sub(1, -2)
  end
  if host == "" or #host > 253 then
    return false
  end
  if host:match("^[%d%.]+$") then
    return valid_ipv4(host)
  end
  for _, label in ipairs(split_literal(host, ".")) do
    if not valid_host_label(label) then
      return false
    end
  end
  return true
end

--- Validate a complete URL authority (host plus optional port).
-- Bracketed IPv6 is parsed as one host; extra trailing bytes are rejected.
-- An unbracketed host may carry exactly one numeric port in 1..65535.
-- @param authority string
-- @return boolean ok, table? typed validation error
local function validate_attribution_authority(authority)
  if authority == "" then
    return false, attribution_invalid("attribution.referer must include a host")
  end
  if authority:find("@", 1, true) then
    return false, attribution_invalid("attribution.referer must not contain userinfo")
  end

  local port = nil
  if authority:sub(1, 1) == "[" then
    local inside, rest = authority:match("^%[([^%]]*)%](.*)$")
    if not inside or not valid_ipv6(inside) then
      return false, attribution_invalid(
        "attribution.referer must use a valid bracketed IPv6 host"
      )
    end
    if rest ~= "" then
      local digits = rest:match("^:(%d+)$")
      if not digits then
        return false, attribution_invalid("attribution.referer port must be numeric")
      end
      port = digits
    end
  else
    if authority:find("[%[%]]") then
      return false, attribution_invalid(
        "attribution.referer must use a valid bracketed IPv6 host"
      )
    end
    local colon = authority:find(":", 1, true)
    if colon then
      local host = authority:sub(1, colon - 1)
      port = authority:sub(colon + 1)
      if not port:match("^%d+$") then
        return false, attribution_invalid("attribution.referer port must be numeric")
      end
      if not valid_registered_host(host) then
        return false, attribution_invalid("attribution.referer must include a valid host")
      end
    elseif not valid_registered_host(authority) then
      return false, attribution_invalid("attribution.referer must include a valid host")
    end
  end

  if port ~= nil then
    local number = tonumber(port)
    if not number or number < 1 or number > 65535 then
      return false, attribution_invalid("attribution.referer port must be between 1 and 65535")
    end
  end
  return true, nil
end

--- Validate the attribution referer: an absolute http(s) URL.
-- @param value any
-- @return string? normalized referer, table? typed validation error
local function validate_attribution_referer(value)
  if type(value) ~= "string" then
    return nil, attribution_invalid("attribution.referer must be a string")
  end
  if value == "" then
    return nil, attribution_invalid("attribution.referer must not be empty")
  end
  if #value > WheelProvider.ATTRIBUTION_REFERER_MAX then
    return nil, attribution_invalid(string.format(
      "attribution.referer must not exceed %d bytes",
      WheelProvider.ATTRIBUTION_REFERER_MAX
    ))
  end
  -- Reject CR, LF, tabs, other controls, and non-ASCII bytes before the value
  -- can reach a header. Header values are a newline-terminated wire format.
  if value:find("[^\32-\126]") then
    return nil, attribution_invalid("attribution.referer must be printable ASCII")
  end
  -- RFC 3986 characters only: this also rejects spaces, backslashes, quotes,
  -- angle brackets, and other bytes that have no place in a URL header.
  if value:find("[^%w%-._~:/?#%[%]@!$&'()*+,;=%%]") then
    return nil, attribution_invalid("attribution.referer contains characters not allowed in a URL")
  end

  local scheme, rest = value:match("^([A-Za-z][A-Za-z0-9+.-]*)://(.*)$")
  if not scheme or rest == "" then
    return nil, attribution_invalid("attribution.referer must be an absolute http(s) URL")
  end
  scheme = scheme:lower()
  if scheme ~= "http" and scheme ~= "https" then
    return nil, attribution_invalid("attribution.referer must be an absolute http(s) URL")
  end

  local authority = rest:match("^([^/?#]*)")
  local authority_ok, authority_err = validate_attribution_authority(authority)
  if not authority_ok then
    return nil, authority_err
  end

  return value, nil
end

--- Validate the display title: printable ASCII, non-blank, bounded.
-- @param value any
-- @return string? normalized title, table? typed validation error
local function validate_attribution_title(value)
  if type(value) ~= "string" then
    return nil, attribution_invalid("attribution.title must be a string")
  end
  if value == "" then
    return nil, attribution_invalid("attribution.title must not be empty")
  end
  if #value > WheelProvider.ATTRIBUTION_TITLE_MAX then
    return nil, attribution_invalid(string.format(
      "attribution.title must not exceed %d bytes",
      WheelProvider.ATTRIBUTION_TITLE_MAX
    ))
  end
  if value:find("[^\32-\126]") then
    return nil, attribution_invalid("attribution.title must be printable ASCII")
  end
  if value:find("^%s") or value:find("%s$") then
    return nil, attribution_invalid("attribution.title must not have leading or trailing whitespace")
  end
  return value, nil
end

--- Validate the optional categories: an array of one or two lowercase tokens.
-- The API takes an array (not a comma-separated string). Each token must match
-- `[a-z0-9-]{1,30}`; at most two tokens are accepted. The joined header is
-- bounded by `ATTRIBUTION_CATEGORIES_MAX`.
-- @param value any
-- @return table? normalized categories, table? typed validation error
local function validate_attribution_categories(value)
  if value == nil then
    return nil, nil
  end
  if type(value) ~= "table" then
    return nil, attribution_invalid(
      "attribution.categories must be an array of one or two category strings"
    )
  end
  if getmetatable(value) ~= nil then
    return nil, attribution_invalid("attribution.categories must be a plain array")
  end

  local count = 0
  for key in pairs(value) do
    if type(key) ~= "number" or key % 1 ~= 0 or key < 1 then
      return nil, attribution_invalid("attribution.categories must be a plain array")
    end
    count = count + 1
  end
  if count < 1 or count > WheelProvider.ATTRIBUTION_MAX_CATEGORIES then
    return nil, attribution_invalid(string.format(
      "attribution.categories must contain one or two categories (got %d)",
      count
    ))
  end

  local normalized = {}
  for index = 1, count do
    local category = value[index]
    if type(category) ~= "string" or category == "" then
      return nil, attribution_invalid(
        "attribution.categories entries must be non-empty strings"
      )
    end
    if #category > WheelProvider.ATTRIBUTION_CATEGORY_MAX then
      return nil, attribution_invalid(string.format(
        "attribution.categories entry must not exceed %d bytes",
        WheelProvider.ATTRIBUTION_CATEGORY_MAX
      ))
    end
    if not category:match("^[a-z0-9-]+$") then
      return nil, attribution_invalid(
        "attribution.categories entries must match [a-z0-9-]{1,30}"
      )
    end
    normalized[index] = category
  end

  if #table.concat(normalized, ",") > WheelProvider.ATTRIBUTION_CATEGORIES_MAX then
    return nil, attribution_invalid(string.format(
      "attribution.categories must not exceed %d bytes when joined",
      WheelProvider.ATTRIBUTION_CATEGORIES_MAX
    ))
  end
  return normalized, nil
end

--- Validate and normalize the opt-in caller attribution block.
-- A nil block is the explicit unattributed default: no identity headers are
-- sent. A configured block requires `referer` and `title`; `categories` (an
-- array of one or two lowercase tokens) and `visibility` are optional.
-- `visibility` accepts only `"hidden"`, the one value the OpenRouter
-- mechanism defines. Unknown fields fail closed so a misspelled key cannot
-- silently produce unattributed traffic.
-- @param value any
-- @return table? normalized attribution, table? typed validation error
function WheelProvider.validate_attribution(value)
  if value == nil then
    return nil, nil
  end
  if type(value) ~= "table" then
    return nil, attribution_invalid("attribution must be a table")
  end
  if getmetatable(value) ~= nil then
    return nil, attribution_invalid("attribution must be a plain table")
  end
  for key in pairs(value) do
    if type(key) ~= "string" or not ATTRIBUTION_FIELDS[key] then
      return nil, attribution_invalid("attribution has an unknown field")
    end
  end

  local referer, referer_err = validate_attribution_referer(value.referer)
  if not referer then
    return nil, referer_err
  end
  local title, title_err = validate_attribution_title(value.title)
  if not title then
    return nil, title_err
  end
  local categories, categories_err = validate_attribution_categories(value.categories)
  if categories_err then
    return nil, categories_err
  end

  local visibility = value.visibility
  if visibility ~= nil and visibility ~= "hidden" then
    return nil, attribution_invalid("attribution.visibility must be 'hidden' when set")
  end

  return {
    referer = referer,
    title = title,
    categories = categories,
    visibility = visibility,
  }, nil
end

--- Build the adapter-owned attribution headers from a validated block.
-- @param attribution table?
-- @return table? headers
local function build_attribution_headers(attribution)
  if not attribution then
    return nil
  end
  local headers = {
    [ATTRIBUTION_HEADER_NAMES.referer] = attribution.referer,
    [ATTRIBUTION_HEADER_NAMES.title] = attribution.title,
  }
  if attribution.categories then
    headers[ATTRIBUTION_HEADER_NAMES.categories] = table.concat(attribution.categories, ",")
  end
  if attribution.visibility then
    headers[ATTRIBUTION_HEADER_NAMES.visibility] = attribution.visibility
  end
  return headers
end

--- Merge adapter-owned attribution headers into a request header table.
-- Applied last so an attribution value always wins over any standard header
-- with the same name; caller-supplied maps are never merged into the request.
-- @param headers table
-- @param attribution_headers table?
-- @return table headers
local function apply_attribution_headers(headers, attribution_headers)
  if not attribution_headers then
    return headers
  end
  for name, value in pairs(attribution_headers) do
    headers[name] = value
  end
  return headers
end

-- ---------------------------------------------------------------------------
-- Line-Buffered SSE Parser
-- ---------------------------------------------------------------------------

local SSEParser = {}
SSEParser.__index = SSEParser

--- Create a new line-buffered SSE Parser.
-- @param opts table? Optional configuration { max_buffer_size = number }
-- @return table SSEParser instance
function SSEParser.new(opts)
  opts = opts or {}
  local self = setmetatable({}, SSEParser)
  self.buffer = ""
  self.current_event = nil
  self.current_data = {}
  self.max_buffer_size = opts.max_buffer_size or 1048576 -- 1 MiB limit
  return self
end

--- Reset the parser state.
function SSEParser:reset()
  self.buffer = ""
  self.current_event = nil
  self.current_data = {}
end

--- Feed a chunk of data into the parser, invoking callback on complete events.
-- @param chunk string New raw data received from stream
-- @param on_event fun(event: table): boolean Callback receiving { event = string?, data = string }
function SSEParser:feed(chunk, on_event)
  if type(chunk) ~= "string" or #chunk == 0 then return end
  self.buffer = self.buffer .. chunk

  -- Enforce maximum unterminated buffer length to prevent memory exhaustion
  if #self.buffer > (self.max_buffer_size or 1048576) and not self.buffer:find("\n", 1, true) then
    self:reset()
    return nil, "SSE line exceeds maximum buffer length (1 MiB)"
  end

  local pos = 1
  local stopped = false

  while true do
    local newline_pos = self.buffer:find("\n", pos, true)
    if not newline_pos then
      break
    end

    local line = self.buffer:sub(pos, newline_pos - 1)
    pos = newline_pos + 1

    -- Trim trailing carriage return
    if #line > 0 and line:sub(-1) == "\r" then
      line = line:sub(1, -2)
    end

    if #line == 0 then
      -- Blank line: dispatch accumulated event if data exists
      if #self.current_data > 0 then
        local combined_data = table.concat(self.current_data, "\n")
        local evt = {
          event = self.current_event,
          data = combined_data,
        }
        self.current_event = nil
        self.current_data = {}

        if on_event then
          local should_stop = on_event(evt)
          if should_stop then
            stopped = true
            break
          end
        end
      end
    elseif line:sub(1, 1) == ":" then
      -- SSE comment / keep-alive: ignore
    elseif line:sub(1, 6) == "event:" then
      local val = line:sub(7)
      if val:sub(1, 1) == " " then val = val:sub(2) end
      self.current_event = val
    elseif line:sub(1, 5) == "data:" then
      local val = line:sub(6)
      if val:sub(1, 1) == " " then val = val:sub(2) end
      table.insert(self.current_data, val)
    end
  end

  -- Single compaction at end of feed loop
  if pos > 1 then
    self.buffer = self.buffer:sub(pos)
  end

  return stopped
end

WheelProvider.SSEParser = SSEParser

-- ---------------------------------------------------------------------------
-- Tool Schema Formatters
-- ---------------------------------------------------------------------------

--- Format tool schemas for OpenAI-compatible function calling API.
-- @param tools table[] List of tool descriptors { name, description, parameters }
-- @return table[] List of OpenAI tool definitions
function WheelProvider.format_tools_for_openai(tools)
  if type(tools) ~= "table" then return {} end
  local formatted = {}
  for _, tool in ipairs(tools) do
    if tool.name then
      table.insert(formatted, {
        type = "function",
        ["function"] = {
          name = tool.name,
          description = tool.description or "",
          parameters = tool.parameters or {
            type = "object",
            properties = {},
          },
        },
      })
    end
  end
  return formatted
end

--- Format tool schemas for Anthropic Messages API tool definitions.
-- @param tools table[] List of tool descriptors { name, description, parameters }
-- @return table[] List of Anthropic tool definitions
function WheelProvider.format_tools_for_anthropic(tools)
  if type(tools) ~= "table" then return {} end
  local formatted = {}
  for _, tool in ipairs(tools) do
    if tool.name then
      table.insert(formatted, {
        name = tool.name,
        description = tool.description or "",
        input_schema = tool.parameters or {
          type = "object",
          properties = {},
        },
      })
    end
  end
  return formatted
end

-- ---------------------------------------------------------------------------
-- Mock Provider Adapter
-- ---------------------------------------------------------------------------

local MockProvider = {}
MockProvider.__index = MockProvider

--- Create a new in-memory Mock Provider for offline testing and deterministic simulation.
-- @param opts table?:
--   opts.responses table?: list of mock ProviderResponses or functions
--   opts.completion_fn function?: dynamic generator fn(request) -> ProviderResponse
--   opts.stream_chunk_size number?: chunk character size for streaming (default 4)
-- @return table MockProvider instance
function MockProvider.new(opts)
  opts = opts or {}
  local self = setmetatable({}, MockProvider)
  self.name = "mock"
  self.model = opts.model or "mock-model"
  self.responses = opts.responses or {}
  self.completion_fn = opts.completion_fn
  self.stream_chunk_size = opts.stream_chunk_size or 4
  self.max_completion_tokens = opts.max_completion_tokens
  self.prompt_cache_policy = opts.prompt_cache_policy
  self.prompt_cache_supported = opts.prompt_cache_supported == true
  self.call_history = {}
  self._call_count = 0
  return self
end

--- Queue an expected response.
function MockProvider:queue_response(res)
  table.insert(self.responses, res)
end

function MockProvider:describe()
  return {
    provider = "mock",
    model = self.model,
    call_count = self._call_count,
  }
end

function MockProvider:_next_response(request)
  self._call_count = self._call_count + 1
  table.insert(self.call_history, request)

  if self.completion_fn then
    return self.completion_fn(request, self._call_count)
  end

  if #self.responses > 0 then
    return table.remove(self.responses, 1)
  end

  -- Default fallback response
  return {
    content = "Mock response for step " .. tostring(self._call_count),
    thinking_content = "Mock reasoning: analyzing request step " .. tostring(self._call_count),
    tool_calls = {},
    usage = {
      prompt_tokens = 120,
      completion_tokens = 45,
      thinking_tokens = 25,
      total_tokens = 190,
    },
    finish_reason = "stop",
  }
end

--- Synchronous completion.
-- @param request table Standard request { model, messages, tools, ... }
-- @param opts table?
-- @return table response, string? error
function MockProvider:complete(request, opts)
  local policy, policy_err = WheelProvider.validate_prompt_cache_request(request or {}, self)
  if not policy then return nil, policy_err end
  local res = self:_next_response(request)
  return res, nil
end

--- Streaming completion.
-- @param request table Standard request
-- @param on_chunk fun(chunk: table): boolean? Callback receiving { delta, type }
-- @param opts table?
-- @return table final_response, string? error
function MockProvider:stream(request, on_chunk, opts)
  local policy, policy_err = WheelProvider.validate_prompt_cache_request(request or {}, self)
  if not policy then return nil, policy_err end
  local res = self:_next_response(request)

  -- Stream thinking content first if present
  if res.thinking_content and #res.thinking_content > 0 and on_chunk then
    local tc = res.thinking_content
    local chunk_size = self.stream_chunk_size
    for i = 1, #tc, chunk_size do
      local sub = tc:sub(i, i + chunk_size - 1)
      on_chunk({ delta = sub, type = "thinking" })
    end
  end

  -- Stream regular content
  if res.content and #res.content > 0 and on_chunk then
    local c = res.content
    local chunk_size = self.stream_chunk_size
    for i = 1, #c, chunk_size do
      local sub = c:sub(i, i + chunk_size - 1)
      on_chunk({ delta = sub, type = "content" })
    end
  end

  -- Stream tool calls notification
  if res.tool_calls and #res.tool_calls > 0 and on_chunk then
    for _, tc in ipairs(res.tool_calls) do
      on_chunk({
        type = "tool_call",
        tool_call = tc,
        delta = string.format("\n[Tool Call: %s]\n", tc.name or ""),
      })
    end
  end

  return res, nil
end

WheelProvider.MockProvider = MockProvider

-- ---------------------------------------------------------------------------
-- OpenAI-Compatible Provider Adapter
-- ---------------------------------------------------------------------------

local OpenAIAdapter = {}
OpenAIAdapter.__index = OpenAIAdapter

--- Create a new OpenAI-compatible provider adapter (OpenAI, DeepSeek, Ollama, vLLM).
-- @param opts table:
--   opts.api_key string?
--   opts.base_url string? (defaults to "https://api.openai.com/v1")
--   opts.model string? (defaults to "gpt-4o")
--   opts.temperature number?
--   opts.thinking table?
--   opts.max_completion_tokens number?: validated completion bound override
--   opts.stream_include_usage boolean?: send stream_options.include_usage;
--     defaults true only for the canonical official OpenAI endpoint
--   opts.attribution table?: opt-in caller attribution
--     { referer = string, title = string, categories = string[]?, visibility = "hidden"? }
--   opts.http_client function?: injectable client fn(req) -> { status, body, stream_fn }
-- @return table OpenAIAdapter instance
function OpenAIAdapter.new(opts)
  opts = opts or {}
  local attribution, attribution_err = WheelProvider.validate_attribution(opts.attribution)
  if attribution_err then
    error(attribution_err, 0)
  end
  local self = setmetatable({}, OpenAIAdapter)
  self.name = "openai"
  self.api_key = opts.api_key or ""
  self.base_url = opts.base_url or OPENAI_BASE_URL
  self.model = opts.model or "gpt-4o"
  self.temperature = opts.temperature or 0.0
  self.thinking = opts.thinking
  self.max_completion_tokens = opts.max_completion_tokens
  self.prompt_cache_policy = opts.prompt_cache_policy
  self.prompt_cache_supported = opts.prompt_cache_supported == true
  if opts.stream_include_usage == nil then
    self.stream_include_usage = self.base_url:gsub("/+$", "") == OPENAI_BASE_URL
  else
    self.stream_include_usage = opts.stream_include_usage == true
  end
  self.attribution = attribution
  -- Precompute the adapter-owned header table. Request and opts header maps
  -- are not a header channel, so a caller cannot inject or override these.
  self._attribution_headers = build_attribution_headers(attribution)
  self.http_client = opts.http_client
  return self
end

function OpenAIAdapter:describe()
  return {
    provider = "openai",
    base_url = self.base_url,
    model = self.model,
    has_api_key = (#self.api_key > 0),
  }
end

--- Format standard messages array for OpenAI endpoint.
function OpenAIAdapter:_format_payload(request, stream)
  local messages = {}
  for _, m in ipairs(request.messages or {}) do
    local msg = {
      role = m.role or "user",
      content = m.content or "",
    }
    if m.tool_call_id then
      msg.tool_call_id = m.tool_call_id
    end
    if m.tool_calls and type(m.tool_calls) == "table" then
      local out_tcs = {}
      for _, tc in ipairs(m.tool_calls) do
        local args_str = "{}"
        if type(tc.arguments) == "string" then
          args_str = tc.arguments
        elseif type(tc.arguments) == "table" then
          args_str = json.encode(tc.arguments)
        end
        table.insert(out_tcs, {
          id = tc.id or ("call_" .. tostring(math.random(100000, 999999))),
          type = "function",
          ["function"] = {
            name = tc.name or "",
            arguments = args_str,
          },
        })
      end
      msg.tool_calls = out_tcs
    end
    table.insert(messages, msg)
  end

  local max_tokens, budget_err = WheelProvider.resolve_max_completion_tokens(request, self.max_completion_tokens)
  if not max_tokens then
    return nil, budget_err
  end

  local payload = {
    model = request.model or self.model,
    messages = messages,
    temperature = request.temperature or self.temperature,
    max_tokens = max_tokens,
    stream = stream and true or false,
  }

  local endpoint = self.base_url:gsub("/+$", "") .. "/chat/completions"
  local cache_payload, cache_err = apply_prompt_cache(payload, request, self, self.name, endpoint)
  if not cache_payload then return nil, cache_err end
  payload = cache_payload
  if stream and self.stream_include_usage then
    payload.stream_options = { include_usage = true }
  end

  if request.tools and #request.tools > 0 then
    payload.tools = WheelProvider.format_tools_for_openai(request.tools)
    payload.tool_choice = request.tool_choice or "auto"
  end

  return payload
end

--- Execute complete request.
function OpenAIAdapter:complete(request, opts)
  opts = opts or {}
  local payload, payload_err = self:_format_payload(request, false)
  if not payload then
    return nil, payload_err
  end
  local body_str = json.encode(payload)
  local endpoint = self.base_url:gsub("/+$", "") .. "/chat/completions"

  local headers = {
    ["Content-Type"] = "application/json",
  }
  if #self.api_key > 0 then
    headers["Authorization"] = "Bearer " .. self.api_key
  end
  apply_attribution_headers(headers, self._attribution_headers)

  local client = opts.http_client or self.http_client
  if not client then
    return nil, "No HTTP client configured for OpenAIAdapter"
  end

  local res, err = client({
    url = endpoint,
    method = "POST",
    headers = headers,
    body = body_str,
  })

  if not res then
    return nil, "HTTP request failed: " .. tostring(err)
  end
  if res.status ~= 200 then
    local preview = (res.body or ""):sub(1, 512)
    return nil, string.format("HTTP %d error: %s", res.status, preview)
  end

  local data = json.decode(res.body)
  if not data or not data.choices or #data.choices == 0 then
    return nil, "Invalid OpenAI response format"
  end

  local choice = data.choices[1]
  local msg = choice.message or {}

  local tool_calls = {}
  if msg.tool_calls and type(msg.tool_calls) == "table" then
    for _, tc in ipairs(msg.tool_calls) do
      local fn_call = tc["function"] or {}
      local args = fn_call.arguments or "{}"
      if type(args) == "string" then
        local ok, dec = pcall(json.decode, args)
        if ok and type(dec) == "table" then args = dec end
      end
      table.insert(tool_calls, {
        id = tc.id or ("call_" .. tostring(#tool_calls + 1)),
        name = fn_call.name or "",
        arguments = args,
      })
    end
  end

  return {
    content = msg.content or "",
    thinking_content = msg.reasoning_content or nil,
    tool_calls = tool_calls,
    finish_reason = choice.finish_reason or "stop",
    usage = WheelProvider.normalize_usage(data.usage, self.name),
  }, nil
end

--- Execute streaming completion.
function OpenAIAdapter:stream(request, on_chunk, opts)
  opts = opts or {}
  local payload, payload_err = self:_format_payload(request, true)
  if not payload then
    return nil, payload_err
  end
  local body_str = json.encode(payload)
  local endpoint = self.base_url:gsub("/+$", "") .. "/chat/completions"

  local headers = {
    ["Content-Type"] = "application/json",
    ["Accept"] = "text/event-stream",
  }
  if #self.api_key > 0 then
    headers["Authorization"] = "Bearer " .. self.api_key
  end
  apply_attribution_headers(headers, self._attribution_headers)

  local client = opts.http_client or self.http_client
  if not client then
    return nil, "No HTTP client configured for OpenAIAdapter"
  end

  local parser = SSEParser.new()
  local accumulated_content = {}
  local accumulated_thinking = {}
  local tool_calls_map = {}
  local finish_reason = "stop"
  local usage = {}
  local stream_err = nil

  local res, err = client({
    url = endpoint,
    method = "POST",
    headers = headers,
    body = body_str,
    stream = true,
    --- Parse OpenAI transport fragments without losing usage-only events.
    on_stream_chunk = function(chunk)
      if stream_err then return true end
      --- Merge explicit usage before processing optional choice deltas.
      local ok, perr = parser:feed(chunk, function(evt)
        local raw = evt.data
        if not raw or raw == "[DONE]" then
          return true
        end

        local ok, chunk_data = pcall(json.decode, raw)
        if not ok or type(chunk_data) ~= "table" then
          return false
        end

        if chunk_data.usage then
          usage = merge_usage(usage, WheelProvider.normalize_usage(chunk_data.usage, self.name))
        end

        local choices = chunk_data.choices
        if choices and #choices > 0 then
          local ch = choices[1]
          if ch.finish_reason then
            finish_reason = ch.finish_reason
          end

          local delta = ch.delta
          if delta then
            -- 1. Thinking / reasoning content delta (DeepSeek reasoner)
            if delta.reasoning_content and #delta.reasoning_content > 0 then
              table.insert(accumulated_thinking, delta.reasoning_content)
              if on_chunk then
                on_chunk({ delta = delta.reasoning_content, type = "thinking" })
              end
            end

            -- 2. Standard content delta
            if delta.content and #delta.content > 0 then
              table.insert(accumulated_content, delta.content)
              if on_chunk then
                on_chunk({ delta = delta.content, type = "content" })
              end
            end

            -- 3. Tool calls delta
            if delta.tool_calls and type(delta.tool_calls) == "table" then
              for _, tc_delta in ipairs(delta.tool_calls) do
                local idx = tc_delta.index or 0
                local existing = tool_calls_map[idx]
                if not existing then
                  existing = {
                    id = tc_delta.id or ("call_" .. tostring(idx)),
                    name = (tc_delta["function"] and tc_delta["function"].name) or "",
                    arguments_raw = {},
                  }
                  tool_calls_map[idx] = existing
                end
                if tc_delta["function"] and tc_delta["function"].arguments then
                  table.insert(existing.arguments_raw, tc_delta["function"].arguments)
                  if on_chunk then
                    on_chunk({ delta = tc_delta["function"].arguments, type = "tool_call_delta" })
                  end
                end
              end
            end
          end
        end
        return false
      end)
      if ok == nil and perr then
        stream_err = perr
        return true
      end
    end,
  })

  if not res then
    return nil, "Streaming HTTP request failed: " .. tostring(err)
  end
  if res.status and (res.status < 200 or res.status >= 300) then
    local preview = (res.body or ""):sub(1, 512)
    return nil, string.format("HTTP %d streaming error: %s", res.status, preview)
  end
  if stream_err then
    return nil, stream_err
  end

  -- Assemble tool calls
  local finalized_tool_calls = {}
  local indices = {}
  for idx in pairs(tool_calls_map) do table.insert(indices, idx) end
  table.sort(indices)
  for _, idx in ipairs(indices) do
    local tc = tool_calls_map[idx]
    local arg_str = table.concat(tc.arguments_raw or {}, "")
    local args = {}
    if #arg_str > 0 then
      local ok, dec = pcall(json.decode, arg_str)
      if ok and type(dec) == "table" then args = dec end
    end
    table.insert(finalized_tool_calls, {
      id = tc.id,
      name = tc.name,
      arguments = args,
    })
  end

  local full_content = table.concat(accumulated_content, "")
  local full_thinking = #accumulated_thinking > 0 and table.concat(accumulated_thinking, "") or nil

  return {
    content = full_content,
    thinking_content = full_thinking,
    tool_calls = finalized_tool_calls,
    finish_reason = finish_reason,
    usage = next(usage) and usage or nil,
  }, nil
end

WheelProvider.OpenAIAdapter = OpenAIAdapter

-- ---------------------------------------------------------------------------
-- Anthropic Messages API Provider Adapter
-- ---------------------------------------------------------------------------

local AnthropicAdapter = {}
AnthropicAdapter.__index = AnthropicAdapter

--- Read an environment variable through the checked host surface.
local function getenv(name)
  if type(os) ~= "table" or type(os.getenv) ~= "function" then
    error(WheelErrors.capability_denied("env.read"), 0)
  end
  return os.getenv(name)
end

--- Create a new Anthropic provider adapter (Claude 3.5 Sonnet, Claude 3 Opus).
-- @param opts table:
--   opts.api_key string?
--   opts.base_url string? (defaults to "https://api.anthropic.com/v1")
--   opts.model string? (defaults to "claude-3-5-sonnet-20241022")
--   opts.version string? (defaults to "2023-06-01")
--   opts.thinking table? { enabled = bool, budget_tokens = number }
--   opts.max_completion_tokens number?: validated completion bound override
--   opts.http_client function?: injectable client fn(req) -> { status, body, stream_fn }
-- @return table AnthropicAdapter instance
function AnthropicAdapter.new(opts)
  opts = opts or {}
  local self = setmetatable({}, AnthropicAdapter)
  self.name = "anthropic"
  self.api_key = opts.api_key or getenv("ANTHROPIC_API_KEY") or ""
  self.base_url = opts.base_url or ANTHROPIC_BASE_URL
  self.model = opts.model or "claude-3-5-sonnet-20241022"
  self.version = opts.version or "2023-06-01"
  self.thinking = opts.thinking
  self.max_completion_tokens = opts.max_completion_tokens
  self.prompt_cache_policy = opts.prompt_cache_policy
  self.prompt_cache_supported = opts.prompt_cache_supported == true
  self.http_client = opts.http_client
  return self
end

function AnthropicAdapter:describe()
  return {
    provider = "anthropic",
    base_url = self.base_url,
    model = self.model,
    has_api_key = (#self.api_key > 0),
  }
end

--- Format standard messages array for Anthropic /v1/messages endpoint.
function AnthropicAdapter:_format_payload(request, stream)
  local system_parts = {}
  local messages = {}

  for _, m in ipairs(request.messages or {}) do
    local r = m.role or "user"
    if r == "system" then
      table.insert(system_parts, m.content or "")
    elseif r == "tool" then
      local block = {
        type = "tool_result",
        tool_use_id = m.tool_call_id or "tool_0",
        content = m.content or "",
      }
      local last_msg = messages[#messages]
      if last_msg and last_msg.role == "user" and type(last_msg.content) == "table" then
        table.insert(last_msg.content, block)
      else
        table.insert(messages, {
          role = "user",
          content = { block },
        })
      end
    elseif r == "assistant" then
      if m.tool_calls and #m.tool_calls > 0 then
        local blocks = {}
        if m.content and #m.content > 0 then
          table.insert(blocks, {
            type = "text",
            text = m.content,
          })
        end
        for _, tc in ipairs(m.tool_calls) do
          table.insert(blocks, {
            type = "tool_use",
            id = tc.id or ("tool_" .. tostring(#blocks + 1)),
            name = tc.name or "",
            input = type(tc.arguments) == "table" and tc.arguments or {},
          })
        end
        table.insert(messages, {
          role = "assistant",
          content = blocks,
        })
      else
        table.insert(messages, {
          role = "assistant",
          content = m.content or "",
        })
      end
    else
      table.insert(messages, {
        role = r,
        content = m.content or "",
      })
    end
  end

  local max_tokens, budget_err = WheelProvider.resolve_max_completion_tokens(request, self.max_completion_tokens)
  if not max_tokens then
    return nil, budget_err
  end

  local payload = {
    model = request.model or self.model,
    messages = messages,
    max_tokens = max_tokens,
    stream = stream and true or false,
  }

  if #system_parts > 0 then
    payload.system = table.concat(system_parts, "\n\n")
  end

  local endpoint = self.base_url:gsub("/+$", "") .. "/messages"
  local cache_payload, cache_err = apply_prompt_cache(payload, request, self, self.name, endpoint)
  if not cache_payload then return nil, cache_err end
  payload = cache_payload

  -- Thinking configuration
  local thinking = request.thinking or self.thinking
  if thinking and thinking.enabled and thinking.budget_tokens and thinking.budget_tokens > 0 then
    payload.thinking = {
      type = "enabled",
      budget_tokens = thinking.budget_tokens,
    }
    -- Temperature must be 1.0 when thinking is enabled per Anthropic specification
    payload.temperature = 1.0
  elseif request.temperature then
    payload.temperature = request.temperature
  end

  if request.tools and #request.tools > 0 then
    payload.tools = WheelProvider.format_tools_for_anthropic(request.tools)
  end

  return payload
end

--- Execute complete request.
function AnthropicAdapter:complete(request, opts)
  opts = opts or {}
  local payload, payload_err = self:_format_payload(request, false)
  if not payload then
    return nil, payload_err
  end
  local body_str = json.encode(payload)
  local endpoint = self.base_url:gsub("/+$", "") .. "/messages"

  local headers = {
    ["Content-Type"] = "application/json",
    ["anthropic-version"] = self.version,
  }
  if #self.api_key > 0 then
    headers["x-api-key"] = self.api_key
  end

  local client = opts.http_client or self.http_client
  if not client then
    return nil, "No HTTP client configured for AnthropicAdapter"
  end

  local res, err = client({
    url = endpoint,
    method = "POST",
    headers = headers,
    body = body_str,
  })

  if not res then
    return nil, "HTTP request failed: " .. tostring(err)
  end
  if res.status ~= 200 then
    local preview = (res.body or ""):sub(1, 512)
    return nil, string.format("HTTP %d error: %s", res.status, preview)
  end

  local data = json.decode(res.body)
  if not data or not data.content then
    return nil, "Invalid Anthropic response format"
  end

  local text_parts = {}
  local thinking_parts = {}
  local tool_calls = {}

  for _, block in ipairs(data.content) do
    if block.type == "text" then
      table.insert(text_parts, block.text or "")
    elseif block.type == "thinking" then
      table.insert(thinking_parts, block.thinking or "")
    elseif block.type == "tool_use" then
      table.insert(tool_calls, {
        id = block.id or ("tool_" .. tostring(#tool_calls + 1)),
        name = block.name or "",
        arguments = block.input or {},
      })
    end
  end

  return {
    content = table.concat(text_parts, ""),
    thinking_content = #thinking_parts > 0 and table.concat(thinking_parts, "") or nil,
    tool_calls = tool_calls,
    finish_reason = data.stop_reason or "end_turn",
    usage = WheelProvider.normalize_usage(data.usage, self.name),
  }, nil
end

--- Execute streaming completion.
function AnthropicAdapter:stream(request, on_chunk, opts)
  opts = opts or {}
  local payload, payload_err = self:_format_payload(request, true)
  if not payload then
    return nil, payload_err
  end
  local body_str = json.encode(payload)
  local endpoint = self.base_url:gsub("/+$", "") .. "/messages"

  local headers = {
    ["Content-Type"] = "application/json",
    ["Accept"] = "text/event-stream",
    ["anthropic-version"] = self.version,
  }
  if #self.api_key > 0 then
    headers["x-api-key"] = self.api_key
  end

  local client = opts.http_client or self.http_client
  if not client then
    return nil, "No HTTP client configured for AnthropicAdapter"
  end

  local parser = SSEParser.new()
  local text_parts = {}
  local thinking_parts = {}
  local tool_calls_map = {}
  local active_block_index = nil
  local stop_reason = "end_turn"
  local usage = {}
  local stream_err = nil

  local res, err = client({
    url = endpoint,
    method = "POST",
    headers = headers,
    body = body_str,
    stream = true,
    --- Parse Anthropic transport fragments and stop after a protocol error.
    on_stream_chunk = function(chunk)
      if stream_err then return true end
      --- Merge native message-start and message-delta usage independently.
      local ok, perr = parser:feed(chunk, function(evt)
        if evt.event == "error" then
          local err_msg = evt.data or "unknown error"
          local ok_d, data = pcall(json.decode, evt.data or "")
          if ok_d and type(data) == "table" and data.error and data.error.message then
            err_msg = data.error.message
          end
          stream_err = "Anthropic stream error: " .. tostring(err_msg)
          return true
        end

        local raw = evt.data
        if not raw then return false end

        local ok_d, data = pcall(json.decode, raw)
        if not ok_d or type(data) ~= "table" then return false end

        local evt_type = data.type or evt.event

        if evt_type == "message_start" then
          local message = data.message or {}
          if message.usage then
            usage = merge_usage(usage, WheelProvider.normalize_usage(message.usage, self.name))
          end
        elseif evt_type == "content_block_start" then
          active_block_index = data.index or 0
          local cb = data.content_block or {}
          if cb.type == "tool_use" then
            tool_calls_map[active_block_index] = {
              id = cb.id or ("tool_" .. tostring(active_block_index)),
              name = cb.name or "",
              arguments_raw = {},
            }
          end
        elseif evt_type == "content_block_delta" then
          local delta = data.delta or {}
          if delta.type == "text_delta" and delta.text then
            table.insert(text_parts, delta.text)
            if on_chunk then on_chunk({ delta = delta.text, type = "content" }) end
          elseif delta.type == "thinking_delta" and delta.thinking then
            table.insert(thinking_parts, delta.thinking)
            if on_chunk then on_chunk({ delta = delta.thinking, type = "thinking" }) end
          elseif delta.type == "input_json_delta" and delta.partial_json then
            local tc = tool_calls_map[data.index or active_block_index]
            if tc then
              table.insert(tc.arguments_raw, delta.partial_json)
              if on_chunk then on_chunk({ delta = delta.partial_json, type = "tool_call_delta" }) end
            end
          end
        elseif evt_type == "message_delta" then
          if data.delta and data.delta.stop_reason then
            stop_reason = data.delta.stop_reason
          end
          if data.usage then
            usage = merge_usage(usage, WheelProvider.normalize_usage(data.usage, self.name))
          end
        elseif evt_type == "message_stop" then
          return true
        end

        return false
      end)
      if ok == nil and perr then
        stream_err = perr
        return true
      end
    end,
  })

  if not res then
    return nil, "Streaming HTTP request failed: " .. tostring(err)
  end
  if res.status and (res.status < 200 or res.status >= 300) then
    local preview = (res.body or ""):sub(1, 512)
    return nil, string.format("HTTP %d streaming error: %s", res.status, preview)
  end
  if stream_err then
    return nil, stream_err
  end

  local tool_calls = {}
  local indices = {}
  for idx in pairs(tool_calls_map) do table.insert(indices, idx) end
  table.sort(indices)
  for _, idx in ipairs(indices) do
    local tc = tool_calls_map[idx]
    local arg_str = table.concat(tc.arguments_raw or {}, "")
    local args = {}
    if #arg_str > 0 then
      local ok, dec = pcall(json.decode, arg_str)
      if ok and type(dec) == "table" then args = dec end
    end
    table.insert(tool_calls, {
      id = tc.id,
      name = tc.name,
      arguments = args,
    })
  end

  return {
    content = table.concat(text_parts, ""),
    thinking_content = #thinking_parts > 0 and table.concat(thinking_parts, "") or nil,
    tool_calls = tool_calls,
    finish_reason = stop_reason,
    usage = next(usage) and usage or nil,
  }, nil
end

WheelProvider.AnthropicAdapter = AnthropicAdapter

-- ---------------------------------------------------------------------------
-- Stdio Subprocess Adapter
-- ---------------------------------------------------------------------------

local StdioAdapter = {}
StdioAdapter.__index = StdioAdapter

--- Shell syntax that is rejected in a stdio command string. Expansion,
-- substitution, globbing, redirection, pipelines, and command separators have
-- no place in an argv primitive; a caller that needs them must pass an explicit
-- argv table instead.
local STDIO_SHELL_SYNTAX = "[|&;<>()$`\\*?%[%]{}~!]"

--- Split a stdio command string into an argv table without shell evaluation.
-- Quotes group words that contain spaces; no expansion or substitution is
-- performed. A table command is validated and copied.
-- @param command string|string[]
-- @return string[]? argv, string? err
local function stdio_command_argv(command)
  if type(command) == "table" then
    local argv = {}
    for index, word in ipairs(command) do
      if type(word) ~= "string" or word == "" or word:find("[%z\n\r]") then
        return nil, "stdio command argv element " .. tostring(index) .. " is invalid"
      end
      argv[#argv + 1] = word
    end
    if #argv == 0 then
      return nil, "stdio command argv must not be empty"
    end
    if #argv > 64 then
      return nil, "stdio command argv is too long"
    end
    return argv
  end

  if type(command) ~= "string" or command:match("^%s*$") ~= nil then
    return nil, "stdio command must be a non-empty string or argv table"
  end
  if command:find("[%z\n\r]") then
    return nil, "stdio command must not contain control bytes"
  end

  local argv, index = {}, 1
  while index <= #command do
    local char = command:sub(index, index)
    if char:match("%s") then
      index = index + 1
    else
      local word = {}
      while index <= #command do
        char = command:sub(index, index)
        if char:match("%s") then
          break
        end
        if char == "'" then
          local close = command:find("'", index + 1, true)
          if not close then
            return nil, "unterminated single quote in stdio command"
          end
          word[#word + 1] = command:sub(index + 1, close - 1)
          index = close + 1
        elseif char == '"' then
          local close = index + 1
          local closed = false
          while close <= #command do
            local inner = command:sub(close, close)
            if inner == "\\" then
              local escaped = command:sub(close + 1, close + 1)
              if escaped == '"' or escaped == "\\" then
                word[#word + 1] = escaped
                close = close + 2
              else
                word[#word + 1] = inner
                close = close + 1
              end
            elseif inner == '"' then
              closed = true
              close = close + 1
              break
            else
              word[#word + 1] = inner
              close = close + 1
            end
          end
          if not closed then
            return nil, "unterminated double quote in stdio command"
          end
          index = close
        else
          if char:match(STDIO_SHELL_SYNTAX) then
            return nil, "stdio command contains shell syntax; pass an argv table instead"
          end
          word[#word + 1] = char
          index = index + 1
        end
      end
      if #word == 0 then
        return nil, "empty stdio command word"
      end
      argv[#argv + 1] = table.concat(word)
      if #argv > 64 then
        return nil, "stdio command argv is too long"
      end
    end
  end

  if #argv == 0 then
    return nil, "stdio command must not be empty"
  end
  return argv
end

--- Create a new Stdio Subprocess Adapter for running local model CLI tools.
-- The prompt is delivered on the child's stdin through the argv process
-- primitive; no shell string and no prompt temp file are used. `command` is an
-- argv source: a whitespace-separated string with optional quotes, or an
-- explicit argv table for anything that would need shell syntax.
-- @param opts table?:
--   opts.command string|table: CLI command (default "ollama run qwen2.5-coder")
--   opts.timeout_ms number?: process timeout override (host-bounded)
--   opts.runner function?: injectable runner for test isolation
-- @return table StdioAdapter instance
function StdioAdapter.new(opts)
  opts = opts or {}
  local self = setmetatable({}, StdioAdapter)
  self.name = "stdio"
  self.command = opts.command or "ollama run qwen2.5-coder"
  self.timeout_ms = opts.timeout_ms
  self.runner = opts.runner
  self.prompt_cache_policy = opts.prompt_cache_policy
  return self
end

function StdioAdapter:describe()
  return {
    provider = "stdio",
    command = self.command,
  }
end

--- Validate cache policy before invoking the bounded stdio completion runner.
function StdioAdapter:complete(request, opts)
  opts = opts or {}
  local policy, policy_err = WheelProvider.validate_prompt_cache_request(request or {}, self)
  if not policy then return nil, policy_err end
  local runner = opts.runner or self.runner
  local prompt = ""
  for _, m in ipairs(request.messages or {}) do
    prompt = prompt .. string.format("\n[%s]\n%s\n", m.role or "user", m.content or "")
  end

  if runner then
    local out = runner(self.command, prompt)
    return {
      content = out or "",
      finish_reason = "stop",
      usage = {},
    }, nil
  end

  local argv, argv_err = stdio_command_argv(self.command)
  if not argv then
    return nil, argv_err
  end
  local program = table.remove(argv, 1)

  local res = WheelHost.proc.run_program(program, argv, {
    stdin = prompt,
    timeout_ms = self.timeout_ms,
  })
  if not res.ok then
    return nil, "Failed to spawn stdio model process: " .. program
      .. " (" .. tostring(res.stderr or res.outcome) .. ")"
  end
  if res.timed_out then
    return nil, "stdio model process timed out: " .. program
  end
  if res.truncated then
    return nil, "stdio model output exceeded the capture bound: " .. program
  end

  local out = res.stdout or ""
  if res.code ~= 0 then
    local code = res.code or 1
    local detail = res.stderr ~= "" and res.stderr or out
    return nil, string.format("Command '%s' failed (exit code %s): %s",
      program, tostring(code), detail:sub(1, 512))
  end

  return {
    content = out,
    finish_reason = "stop",
    usage = {},
  }, nil
end

--- Deliver stdio completion chunks after the same fail-closed policy checks.
function StdioAdapter:stream(request, on_chunk, opts)
  local policy, policy_err = WheelProvider.validate_prompt_cache_request(request or {}, self)
  if not policy then return nil, policy_err end
  -- For stdio processes, stream line by line if possible or deliver in chunks
  local res, err = self:complete(request, opts)
  if not res then return nil, err end

  if on_chunk and res.content and #res.content > 0 then
    local chunk_size = 16
    for i = 1, #res.content, chunk_size do
      local sub = res.content:sub(i, i + chunk_size - 1)
      on_chunk({ delta = sub, type = "content" })
    end
  end

  return res, nil
end

WheelProvider.StdioAdapter = StdioAdapter

-- ---------------------------------------------------------------------------
-- Provider Factory
-- ---------------------------------------------------------------------------

--- Create a model provider adapter based on model profile or role specification.
-- @param profile table ModelProfile { provider = string, model = string, temperature = number, thinking = table, ... }
-- @param opts table? Additional options (e.g. http_client, api_key, base_url, attribution)
-- @return table? WheelProvider adapter instance, or nil on failure
-- @return string? Error message on failure
function WheelProvider.create(profile, opts)
  profile = profile or {}
  opts = opts or {}
  local p_type = string.lower(profile.provider or opts.provider or "mock")

  local requested_budget = profile.max_completion_tokens
  if requested_budget == nil then
    requested_budget = opts.max_completion_tokens
  end
  local completion_budget, budget_err = WheelProvider.validate_max_completion_tokens(requested_budget)
  if not completion_budget then
    return nil, budget_err
  end

  -- Attribution applies to the OpenAI-compatible adapter family (the
  -- `openai` and `deepseek` routes). Validate before construction so the
  -- factory returns its usual `nil, typed error` contract; the adapter
  -- constructor re-validates for direct callers and raises.
  local attribution = nil
  if p_type == "openai" or p_type == "deepseek" then
    local attribution_err
    attribution, attribution_err = WheelProvider.validate_attribution(opts.attribution)
    if attribution_err then
      return nil, attribution_err
    end
  end

  if p_type == "mock" then
    return MockProvider.new({
      model = profile.model or opts.model or "mock-model",
      responses = opts.responses,
      completion_fn = opts.completion_fn,
      stream_chunk_size = opts.stream_chunk_size,
      max_completion_tokens = completion_budget,
      prompt_cache_policy = opts.prompt_cache_policy,
       prompt_cache_supported = opts.prompt_cache_supported == true,
    })
  elseif p_type == "openai" then
    local api_key = opts.api_key or getenv("OPENAI_API_KEY") or ""
    local base_url = opts.base_url or OPENAI_BASE_URL
    local cache_supported = base_url:gsub("/+$", "") == OPENAI_BASE_URL
    if opts.prompt_cache_supported ~= nil then cache_supported = opts.prompt_cache_supported == true end
    return OpenAIAdapter.new({
      api_key = api_key,
      base_url = base_url,
      model = profile.model or opts.model or "gpt-4o",
      temperature = profile.temperature or opts.temperature or 0.0,
       thinking = profile.thinking or opts.thinking,
       max_completion_tokens = completion_budget,
       prompt_cache_policy = opts.prompt_cache_policy,
       prompt_cache_supported = cache_supported,
      stream_include_usage = opts.stream_include_usage,
      attribution = attribution,
      http_client = opts.http_client,
    })
  elseif p_type == "deepseek" then
    local api_key = opts.api_key or getenv("DEEPSEEK_API_KEY") or ""
    return OpenAIAdapter.new({
      api_key = api_key,
      base_url = opts.base_url or "https://api.deepseek.com/v1",
      model = profile.model or opts.model or "deepseek-reasoner",
      temperature = profile.temperature or opts.temperature or 0.0,
      thinking = profile.thinking or opts.thinking,
      max_completion_tokens = completion_budget,
      prompt_cache_policy = opts.prompt_cache_policy,
       prompt_cache_supported = opts.prompt_cache_supported == true,
      stream_include_usage = opts.stream_include_usage,
      attribution = attribution,
      http_client = opts.http_client,
    })
  elseif p_type == "anthropic" then
    local api_key = opts.api_key or getenv("ANTHROPIC_API_KEY") or ""
    local base_url = opts.base_url or ANTHROPIC_BASE_URL
    local cache_supported = base_url:gsub("/+$", "") == ANTHROPIC_BASE_URL
    if opts.prompt_cache_supported ~= nil then cache_supported = opts.prompt_cache_supported == true end
    return AnthropicAdapter.new({
      api_key = api_key,
      base_url = base_url,
      model = profile.model or opts.model or "claude-3-5-sonnet-20241022",
      thinking = profile.thinking or opts.thinking,
      max_completion_tokens = completion_budget,
      prompt_cache_policy = opts.prompt_cache_policy,
      prompt_cache_supported = cache_supported,
      http_client = opts.http_client,
    })
  elseif p_type == "stdio" or p_type == "local" or p_type == "ollama" then
    local cmd = opts.command
    if cmd ~= nil and type(cmd) ~= "string" and type(cmd) ~= "table" then
      return nil, "opts.command must be a string or argv table"
    end
    if not cmd then
      local m = profile.model or opts.model or "qwen2.5-coder"
      if type(m) ~= "string" or not m:match("^[%w%._%-:]+$") then
        return nil, "Invalid model name for local/ollama provider: " .. tostring(m)
      end
      cmd = { "ollama", "run", m }
    end
    return StdioAdapter.new({
      command = cmd,
      timeout_ms = opts.timeout_ms,
      runner = opts.runner,
      prompt_cache_policy = opts.prompt_cache_policy,
    })
  else
    return nil, "Unknown or unsupported provider type: " .. tostring(p_type)
  end
end

return WheelProvider
