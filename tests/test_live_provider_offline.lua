-- Run live scenarios with the real adapter and in-memory runner/
-- helper double. No provider credential, subprocess, file, or network is used.
package.path = "./lua/?.lua;./lua/?/init.lua;" .. package.path

local provider_name = assert(arg[1])
assert(provider_name == "openrouter" or provider_name == "commandcode" or provider_name == "openai-cache")
local MAX_HELPER_REQUEST_BYTES = 1024 * 1024
local MIN_CACHE_PROMPT_TOKENS = 1024
local SYNTHETIC_PROMPT_TOKENS = 2048
local CACHE_COMPLETION_BUDGET = 64
local failure_mode = arg[2]
local WheelProvider = require("wheel.provider")
local WheelRunner = require("wheel.runner")
local original_run_task = WheelRunner.run_task
local original_getenv = os.getenv
local original_open = io.open
local original_popen = io.popen
local original_tmpname = os.tmpname
local original_remove = os.remove
local original_exit = os.exit
local request_json
local requests = 0
local probes = 0
local paths = 0
local cache_prefix
local cache_key
local cache_completed = false

--- Select the offline provider while refusing every Lua credential read.
os.getenv = function(name)
  assert(not name:match("_API_KEY$"), "Lua must never read a provider credential")
  if name == "WHEEL_LIVE_PROVIDER" then return provider_name end
  return original_getenv(name)
end
os.tmpname = function()
  paths = paths + 1
  return "synthetic-helper-file-" .. tostring(paths)
end
os.remove = function() return true end
--- Keep request files in memory and synthesize only expected diagnostics.
io.open = function(_, mode)
  if mode == "wb" then
    return {
      write = function(_, value) request_json = value end,
      close = function() end,
    }
  end
  assert(mode == "rb")
  return {
    --- Supply only synthetic helper diagnostics on the failure path.
    read = function() return failure_mode == "failure" and "synthetic untrusted helper diagnostic" or "" end,
    close = function() end,
  }
end
--- Emulate helper responses and inspect the actual serialized adapter payload.
io.popen = function(command, mode)
  assert(mode == "r" and command:find("tests/live_http_client.py", 1, true),
    "only the test helper may be invoked")
  local output
  if command:find("--check-key", 1, true) then
    probes = probes + 1
    output = "KEY_PRESENT\n"
  else
    requests = requests + 1
    local spec = assert(WheelProvider.JSON.decode(request_json))
    for name in pairs(spec.headers) do
      assert(name:lower() ~= "authorization" and name:lower() ~= "x-api-key",
        "synthetic helper specification must have no credential headers")
    end
    local payload = assert(WheelProvider.JSON.decode(spec.body))
    if provider_name == "openai-cache" then
      assert(spec.url == "https://api.openai.com/v1/chat/completions")
      assert(#request_json <= MAX_HELPER_REQUEST_BYTES, "encoded helper specification must stay bounded")
      local prefix = payload.messages[1].content
      local _, words = prefix:gsub("%S+", "")
      assert(words > MIN_CACHE_PROMPT_TOKENS and #prefix <= WheelProvider.MAX_PROMPT_CACHE_PREFIX_BYTES,
        "stable prefix must exceed the minimum in words and fit the cache-key bound")
      assert(not payload.stream and payload.max_tokens == CACHE_COMPLETION_BUDGET and not payload.tools)
      assert(type(payload.prompt_cache_key) == "string")
      if cache_prefix then
        assert(prefix == cache_prefix and payload.prompt_cache_key == cache_key,
          "both cache requests must reuse the exact stable prefix and domain key")
      end
      cache_prefix, cache_key = prefix, payload.prompt_cache_key
      local usage = { prompt_tokens = SYNTHETIC_PROMPT_TOKENS, prompt_tokens_details = { cached_tokens = 0 } }
      if failure_mode == "hit" then usage.prompt_tokens_details.cached_tokens = MIN_CACHE_PROMPT_TOKENS end
      if failure_mode == "unknown" then usage.prompt_tokens_details = nil end
      if failure_mode == "error" then usage.prompt_tokens_details.cached_tokens = "bad" end
      if failure_mode == "short" then usage.prompt_tokens = MIN_CACHE_PROMPT_TOKENS end
      local body = WheelProvider.JSON.encode({
        choices = { { message = { content = "OK synthetic cache completion" }, finish_reason = "stop" } },
        usage = usage,
      })
      return { read = function() return "STATUS 200\n" .. body end, close = function() return true end }
    end
    local message = { role = "assistant", content = "OK synthetic completion" }
    local finish_reason = "stop"
    local has_tool_result = false
    for _, item in ipairs(payload.messages) do
      if item.role == "tool" then has_tool_result = true end
    end
    if payload.tools and #payload.tools > 0 and not has_tool_result then
      message.content = ""
      message.tool_calls = { {
        id = "synthetic-tool-call",
        type = "function",
        ["function"] = { name = "get_time", arguments = '{"timezone":"UTC"}' },
      } }
      finish_reason = "tool_calls"
    end
    local body
    if payload.stream then
      if not message.tool_calls then message.content = "1, 2, 3" end
      body = "data: " .. WheelProvider.JSON.encode({
        choices = { { delta = message, finish_reason = finish_reason } },
      }) .. "\n\ndata: [DONE]\n\n"
    else
      body = WheelProvider.JSON.encode({
        choices = { { message = message, finish_reason = finish_reason } },
      })
    end
    output = failure_mode and "" or "STATUS 200\n" .. body
  end
  return { read = function() return output end, close = function() return true end }
end

WheelRunner.run_task = function(agent, _, opts)
  assert(provider_name ~= "openai-cache", "cache evidence must not enter runner scenarios")
  local messages = { { role = "user", content = "Call get_time for UTC." } }
  local request = {
    messages = messages,
    tools = agent.tool_registry:list_tools(),
    max_completion_tokens = opts.max_completion_tokens,
  }
  local response = assert(agent.provider:stream(request))
  local call = assert(response.tool_calls[1], "synthetic runner must receive a parsed tool call")
  opts.on_tool_call(call)
  messages[#messages + 1] = { role = "assistant", content = "", tool_calls = response.tool_calls }
  messages[#messages + 1] = { role = "tool", tool_call_id = call.id, content = "synthetic tool result" }
  response = assert(agent.provider:stream(request))
  return { success = true, iterations = 2, artifacts = response.content }
end

if provider_name == "openai-cache" then
  os.exit = function(code)
    assert(code == 0)
    cache_completed = true
    error("synthetic cache scenario complete", 0)
  end
end
local ok, err = pcall(dofile, "tests/test_live_provider.lua")
WheelRunner.run_task = original_run_task
os.getenv = original_getenv
io.open = original_open
io.popen = original_popen
os.tmpname = original_tmpname
os.remove = original_remove
os.exit = original_exit
assert(probes == 1, "legacy selector must reach the helper probe")
if provider_name == "openai-cache" then
  if failure_mode == "short" then
    assert(not ok and not cache_completed and requests == 1
      and tostring(err):find("reported live prompt usage must exceed", 1, true),
      "below-minimum measured prompt usage must fail the live evidence check")
  else
    assert(not ok and cache_completed and err == "synthetic cache scenario complete")
    assert(requests == 2, "cache evidence must make exactly two bounded helper calls")
  end
elseif failure_mode then
  assert(not ok and err == "complete failed: HTTP request failed: test HTTP helper produced no status",
    "Lua must report a static failure without forwarding helper diagnostics")
  assert(requests == 1)
else
  assert(ok, tostring(err) .. " (synthetic requests: " .. tostring(requests) .. ")")
  assert(requests >= 5, "legacy selector must complete adapter and runner scenarios")
end
print("PASS offline live scenarios " .. provider_name)
