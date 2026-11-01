-- tests/test_live_provider.lua
-- Opt-in live provider test for Wheel's OpenAIAdapter and runner.
--
-- Manual only: run with `just test-live`. The recipe is deliberately absent
-- from `just check` and CI. WHEEL_LIVE_PROVIDER selects `openrouter` (default),
-- `commandcode`, or `openai-cache`, case-insensitively. The test skips with exit 0 when the
-- selected provider's key environment variable is absent, and fails closed on
-- an unknown selector. The key is read from the inherited environment by the
-- test-only Python transport (tests/live_http_client.py); it is never passed
-- through argv, a request file, the Lua adapter, or captured output.

package.path = "./lua/?.lua;./lua/?/init.lua;" .. package.path

local PROVIDER_SELECTOR_ENV = "WHEEL_LIVE_PROVIDER"
local DEFAULT_PROVIDER = "openrouter"

local PROVIDERS = {
  openrouter = {
    name = "openrouter",
    api_key_env = "OPENROUTER_API_KEY",
    base_url = "https://openrouter.ai/api/v1",
    model = "deepseek/deepseek-v4.1-flash",
    smoke_max_completion_tokens = 256,
    runner_max_completion_tokens = 512,
  },
  commandcode = {
    name = "commandcode",
    api_key_env = "COMMANDCODE_API_KEY",
    base_url = "https://api.commandcode.ai/provider/v1",
    model = "deepseek/deepseek-v4.1-flash",
    -- The model is a reasoning model: a small budget can be consumed entirely
    -- by reasoning and return empty content with finish_reason=length. Keep
    -- content-bearing checks well above the 512-token minimum.
    smoke_max_completion_tokens = 1024,
    runner_max_completion_tokens = 1024,
  },
  ["openai-cache"] = {
    name = "openai-cache",
    api_key_env = "OPENAI_API_KEY",
    base_url = "https://api.openai.com/v1",
    model = "gpt-4o-mini",
    smoke_max_completion_tokens = 64,
    runner_max_completion_tokens = 64,
  },
}

local function trim(value)
  return (value:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function select_provider()
  local raw = os.getenv(PROVIDER_SELECTOR_ENV)
  local name = DEFAULT_PROVIDER
  if raw then
    local trimmed = trim(raw)
    if trimmed ~= "" then
      name = string.lower(trimmed)
    end
  end
  local config = PROVIDERS[name]
  if not config then
    io.stderr:write(string.format(
      "test-live: unsupported %s value; expected openrouter, commandcode, or openai-cache\n",
      PROVIDER_SELECTOR_ENV
    ))
    os.exit(2)
  end
  return config
end

local provider = select_provider()
local api_key = os.getenv(provider.api_key_env)
if not api_key or api_key == "" then
  print(string.format(
    "SKIP test-live: %s is not set for provider %s",
    provider.api_key_env,
    provider.name
  ))
  os.exit(0)
end

local WheelProvider = require("wheel.provider")
local WheelRunner = require("wheel.runner")
local WheelAgent = require("wheel.agent")
local WheelKernel = require("wheel.kernel")
local WheelContext = require("wheel.context")
local WheelTool = require("wheel.tool")

local MODEL = provider.model
local BASE_URL = provider.base_url
local PYTHON = "python3"
local CLIENT_SCRIPT = "tests/live_http_client.py"
local SMOKE_MAX_COMPLETION_TOKENS = provider.smoke_max_completion_tokens
local RUNNER_MAX_COMPLETION_TOKENS = provider.runner_max_completion_tokens
local STREAM_CHUNK_SIZE = 64

local captured_outputs = {}
local observed_budgets = {}
local helper_calls = 0
local cache_request_keys = {}
local cache_usages = {}

local function remember(text)
  if type(text) == "string" and #text > 0 then
    table.insert(captured_outputs, text)
  end
end

local function assert_no_key(text, label)
  if type(text) == "string" and text:find(api_key, 1, true) then
    error("credential material detected in " .. label, 0)
  end
end

local function fail_without_key(label, err)
  local message = tostring(err)
  assert_no_key(message, label .. " error")
  error(label .. " failed: " .. message, 0)
end

local function expect_response(label, res, err)
  if not res then
    fail_without_key(label, err)
  end
  return res
end

--- Invoke the test-only stdlib HTTP helper. The request JSON goes over stdin
--- through a temporary file; the key stays in the helper's environment.
local function run_helper(spec)
  local request_path = os.tmpname()
  local error_path = os.tmpname()
  local encoded = WheelProvider.JSON.encode(spec)
  assert_no_key(encoded, "request JSON")

  local request_file = assert(io.open(request_path, "wb"))
  request_file:write(encoded)
  request_file:close()

  local command = string.format("%s %q < %q 2> %q", PYTHON, CLIENT_SCRIPT, request_path, error_path)
  local pipe = assert(io.popen(command, "r"))
  local stdout = pipe:read("*a") or ""
  pipe:close()

  local error_file = io.open(error_path, "rb")
  local stderr = error_file and (error_file:read("*a") or "") or ""
  if error_file then
    error_file:close()
  end
  os.remove(request_path)
  os.remove(error_path)

  remember(stdout)
  remember(stderr)
  assert_no_key(stdout, "helper stdout")
  assert_no_key(stderr, "helper stderr")

  local status, body = stdout:match("^STATUS (%d+)\n(.*)$")
  if not status then
    return nil, "test HTTP helper produced no status: " .. stderr:sub(1, 256)
  end
  return tonumber(status), body
end

--- Adapter HTTP client used by the live test. The adapter itself has no API
--- key; the Python helper attaches the environment credential.
local function http_client(req)
  helper_calls = helper_calls + 1

  local decoded = WheelProvider.JSON.decode(req.body)
  if type(decoded) ~= "table" then
    return nil, "live request body is not JSON"
  end
  local budget = decoded.max_tokens
  if type(budget) ~= "number" or budget % 1 ~= 0 or budget <= 0 or budget > WheelProvider.MAX_COMPLETION_TOKENS then
    return nil, "live request is missing a bounded completion max_tokens"
  end
  table.insert(observed_budgets, budget)
  if provider.name == "openai-cache" then
    assert(decoded.prompt_cache_key ~= nil, "OpenAI cache request must include prompt_cache_key")
    table.insert(cache_request_keys, decoded.prompt_cache_key)
  end

  local headers = {}
  for name, value in pairs(req.headers or {}) do
    local lower = string.lower(name)
    if lower ~= "authorization" and lower ~= "x-api-key" then
      headers[name] = value
    end
  end

  local status, body = run_helper({
    url = req.url,
    method = req.method or "POST",
    headers = headers,
    body = req.body,
  })
  if not status then
    return nil, body
  end

  remember(req.body)
  remember(body)
  assert_no_key(req.body, "provider request")
  assert_no_key(body, "provider response")

  if req.stream and req.on_stream_chunk and #body > 0 then
    for i = 1, #body, STREAM_CHUNK_SIZE do
      req.on_stream_chunk(body:sub(i, i + STREAM_CHUNK_SIZE - 1))
    end
  end

  return { status = status, body = body }
end

local adapter = WheelProvider.OpenAIAdapter.new({
  base_url = BASE_URL,
  model = MODEL,
  temperature = 0.0,
  http_client = http_client,
  prompt_cache_supported = provider.name == "openai-cache",
  prompt_cache_policy = provider.name == "openai-cache" and "prefer" or nil,
})

-- The adapter never holds the key; only the out-of-process test helper does.
assert(adapter:describe().has_api_key == false, "live adapter must not store an API key")

if provider.name == "openai-cache" then
  -- This evidence path is intentionally limited to two same-prefix requests;
  -- it does not invoke the unrelated tool, stream, or runner live scenarios.
  local stable_prefix = "You are a concise assistant. Follow the user's request precisely."
  local request = {
    stable_context_prefix = stable_prefix,
    messages = {
      { role = "system", content = stable_prefix },
      { role = "user", content = "Reply with OK." },
    },
    max_completion_tokens = SMOKE_MAX_COMPLETION_TOKENS,
  }
  local expected_domain = WheelProvider.cache_domain(
    request, "openai", MODEL, BASE_URL .. "/chat/completions", "prefer")
  local config = require("wheel.config")
  local expected_key = config.compute_hash(table.concat({ expected_domain, stable_prefix }, "\0"))

  for attempt = 1, 2 do
    local response = expect_response("OpenAI cache completion " .. tostring(attempt),
      adapter:complete(request))
    assert(type(response.content) == "string" and #response.content > 0,
      "OpenAI cache completion must return content")
    assert(response.usage == nil or type(response.usage) == "table",
      "OpenAI cache completion usage must be normalized or absent")
    local usage = response.usage or {}
    local status = usage.provider_cache_status or "unknown"
    assert(status == "verified_hit" or status == "verified_miss" or status == "write_only"
      or status == "unknown" or status == "unsupported" or status == "error",
      "OpenAI cache status must reflect provider usage without inventing a hit")
    if usage.cache_read_tokens ~= nil then
      assert(type(usage.cache_read_tokens) == "number" and usage.cache_read_tokens >= 0,
        "normalized cache reads must come from a valid provider usage count")
    end
    if usage.cache_creation_tokens ~= nil then
      assert(type(usage.cache_creation_tokens) == "number" and usage.cache_creation_tokens >= 0,
        "normalized cache creation must come from a valid provider usage count")
    end
    if usage.prompt_tokens ~= nil and usage.cache_read_tokens ~= nil
      and usage.cache_read_tokens <= usage.prompt_tokens then
      assert(usage.uncached_input_tokens == usage.prompt_tokens - usage.cache_read_tokens,
        "uncached input must subtract only explicitly reported cached reads")
    end
    if status == "verified_hit" then
      assert(type(usage.cache_read_tokens) == "number" and usage.cache_read_tokens > 0,
        "a cache hit requires positive cached tokens in provider usage")
    end
    table.insert(cache_usages, usage)
  end
  assert(helper_calls == 2 and #observed_budgets == 2,
    "OpenAI cache evidence must use exactly two bounded requests")
  assert(#cache_request_keys == 2 and cache_request_keys[1] == expected_key
    and cache_request_keys[2] == expected_key,
    "both OpenAI prompt_cache_keys must derive from the exact domain and serialized stable prefix")
  for _, cache_key in ipairs(cache_request_keys) do
    assert_no_key(cache_key, "cache key")
  end
  assert(#cache_usages == 2, "both live responses must be checked independently")
  print("LIVE openai-cache repeated-prefix evidence complete")
  for index, output in ipairs(captured_outputs) do
    assert_no_key(output, "captured output " .. tostring(index))
  end
  print(string.format("LIVE %s tests passed (%d bounded requests)", provider.name, helper_calls))
  os.exit(0)
end

-- 1. Non-streaming completion with a bounded completion budget.
do
  local res = expect_response("complete", adapter:complete({
    messages = {
      { role = "user", content = "Reply with exactly OK and nothing else." },
    },
    max_completion_tokens = SMOKE_MAX_COMPLETION_TOKENS,
  }))
  assert(type(res.content) == "string" and #res.content > 0, "complete must return content")
  assert(res.finish_reason ~= "length", "complete must not exhaust the completion budget")
  assert(res.content:upper():find("OK", 1, true) ~= nil, "complete response should contain OK")
  print("LIVE " .. provider.name .. " complete OK")
end

-- 2. Tool call request with parsed arguments.
do
  local res = expect_response("tool call", adapter:complete({
    messages = {
      { role = "user", content = "Call the get_time tool once with timezone UTC. Do not answer with text." },
    },
    tools = {
      {
        name = "get_time",
        description = "Return the current time for a timezone.",
        parameters = {
          type = "object",
          properties = {
            timezone = { type = "string", description = "IANA timezone name" },
          },
          required = { "timezone" },
        },
      },
    },
    tool_choice = "required",
    max_completion_tokens = SMOKE_MAX_COMPLETION_TOKENS,
  }))
  assert(type(res.tool_calls) == "table" and #res.tool_calls >= 1, "tool call must be parsed")
  assert(res.finish_reason ~= "length", "tool call must not exhaust the completion budget")
  local call = res.tool_calls[1]
  assert(call.name == "get_time", "tool call name must be parsed")
  assert(type(call.arguments) == "table", "tool arguments must be decoded into a table")
  assert(type(call.arguments.timezone) == "string", "tool argument timezone must be parsed")
  print("LIVE " .. provider.name .. " tool call OK (" .. call.name .. ")")
end

-- 3. SSE streaming through the adapter parser.
do
  local chunks = 0
  local res = expect_response("stream", adapter:stream({
    messages = {
      { role = "user", content = "Reply with the three numbers 1, 2, 3 separated by commas." },
    },
    max_completion_tokens = SMOKE_MAX_COMPLETION_TOKENS,
  }, function(chunk)
    if chunk and chunk.delta then
      chunks = chunks + 1
    end
  end))
  assert(chunks > 0, "stream must deliver chunks")
  assert(type(res.content) == "string" and #res.content > 0, "stream must accumulate content")
  assert(res.finish_reason ~= "length", "stream must not exhaust the completion budget")
  assert(res.content:find("1", 1, true) ~= nil and res.content:find("3", 1, true) ~= nil,
    "stream response should contain the requested sequence")
  print("LIVE " .. provider.name .. " stream OK")
end

-- 4. One runner ReAct turn with a stub tool.
do
  local kernel = WheelKernel.new_mock()
  local context = WheelContext.new({ kernel = kernel })
  local registry = WheelTool.Registry.new()
  registry._tools = {}
  registry:register_tool({
    name = "get_time",
    intent = WheelTool.ActionIntent.INSPECT,
    description = "Return the current time for a timezone.",
    parameters = {
      type = "object",
      properties = {
        timezone = { type = "string", description = "IANA timezone name" },
      },
      required = { "timezone" },
    },
    execute = function(args)
      local timezone = (args and args.timezone) or "UTC"
      return {
        success = true,
        exit_code = 0,
        stdout = "2026-10-20T00:00:00Z (" .. tostring(timezone) .. ")",
        stderr = "",
        duration_ms = 1,
      }
    end,
  })

  local agent = WheelAgent.new({
    name = "live-runner-worker",
    role = WheelAgent.Role.CODING,
    kernel = kernel,
    context = context,
    tool_registry = registry,
    tools = { "get_time" },
    model_profile = {
      provider = "openai",
      model = MODEL,
      temperature = 0.0,
    },
    provider = adapter,
  })

  local task = kernel:create_task({
    id = "LIVE-RUNNER-01",
    title = "Live ReAct turn",
    description = "Call the get_time tool exactly once for timezone UTC, then report the returned timestamp.",
    priority = 1,
  })

  local tools_called = {}
  local report = WheelRunner.run_task(agent, task, {
    max_turns = 4,
    max_completion_tokens = RUNNER_MAX_COMPLETION_TOKENS,
    on_tool_call = function(tool_call)
      table.insert(tools_called, tool_call.name)
    end,
  })

  if not report.success then
    fail_without_key("runner", report.error)
  end
  remember(report.artifacts)
  assert(report.iterations >= 2, "runner must complete a tool turn and a final turn")
  assert(#tools_called >= 1 and tools_called[1] == "get_time", "runner must dispatch the stub tool")
  assert(type(report.artifacts) == "string" and #report.artifacts > 0, "runner must produce deliverables")
  print("LIVE " .. provider.name .. " runner OK (" .. tostring(report.iterations) .. " iterations)")
end

if provider.name == "commandcode" then
  assert(SMOKE_MAX_COMPLETION_TOKENS >= 512 and RUNNER_MAX_COMPLETION_TOKENS >= 512,
    "Command Code reasoning checks require at least 512 completion tokens")
end
assert(#observed_budgets >= 4, "every live request path must carry a bounded max_tokens")
for _, budget in ipairs(observed_budgets) do
  assert(budget > 0 and budget <= WheelProvider.MAX_COMPLETION_TOKENS,
    "live request budget must stay within the named bound")
end
assert(helper_calls == #observed_budgets, "every helper call must be a bounded provider request")

for index, output in ipairs(captured_outputs) do
  assert_no_key(output, "captured output " .. tostring(index))
end

print(string.format(
  "LIVE %s tests passed (%d bounded requests)",
  provider.name,
  helper_calls
))
