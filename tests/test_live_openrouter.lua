-- tests/test_live_openrouter.lua
-- Opt-in live provider test for Wheel's OpenAIAdapter and runner.
--
-- Manual only: run with `just test-live`. The recipe is deliberately absent
-- from `just check` and CI. The test skips with exit 0 when OPENROUTER_API_KEY
-- is absent. The key is read from the inherited environment by the test-only
-- Python transport (tests/live_http_client.py); it is never passed through
-- argv, a request file, the Lua adapter, or captured output.

package.path = "./lua/?.lua;./lua/?/init.lua;" .. package.path

local api_key = os.getenv("OPENROUTER_API_KEY")
if not api_key or api_key == "" then
  print("SKIP test-live: OPENROUTER_API_KEY is not set")
  os.exit(0)
end

local WheelProvider = require("wheel.provider")
local WheelRunner = require("wheel.runner")
local WheelAgent = require("wheel.agent")
local WheelKernel = require("wheel.kernel")
local WheelContext = require("wheel.context")
local WheelTool = require("wheel.tool")

local MODEL = "deepseek/deepseek-v4.1-flash"
local BASE_URL = "https://openrouter.ai/api/v1"
local PYTHON = "python3"
local CLIENT_SCRIPT = "tests/live_http_client.py"
local SMOKE_MAX_COMPLETION_TOKENS = 256
local RUNNER_MAX_COMPLETION_TOKENS = 512
local STREAM_CHUNK_SIZE = 64

local captured_outputs = {}
local observed_budgets = {}
local helper_calls = 0

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
})

-- The adapter never holds the key; only the out-of-process test helper does.
assert(adapter:describe().has_api_key == false, "live adapter must not store an API key")

-- 1. Non-streaming completion with a bounded completion budget.
do
  local res = expect_response("complete", adapter:complete({
    messages = {
      { role = "user", content = "Reply with exactly OK and nothing else." },
    },
    max_completion_tokens = SMOKE_MAX_COMPLETION_TOKENS,
  }))
  assert(type(res.content) == "string" and #res.content > 0, "complete must return content")
  assert(res.content:upper():find("OK", 1, true) ~= nil, "complete response should contain OK")
  print("LIVE complete OK")
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
  local call = res.tool_calls[1]
  assert(call.name == "get_time", "tool call name must be parsed")
  assert(type(call.arguments) == "table", "tool arguments must be decoded into a table")
  assert(type(call.arguments.timezone) == "string", "tool argument timezone must be parsed")
  print("LIVE tool call OK (" .. call.name .. ")")
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
  assert(res.content:find("1", 1, true) ~= nil and res.content:find("3", 1, true) ~= nil,
    "stream response should contain the requested sequence")
  print("LIVE stream OK")
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
  print("LIVE runner OK (" .. tostring(report.iterations) .. " iterations)")
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

print(string.format("LIVE tests passed (%d bounded requests)", helper_calls))
