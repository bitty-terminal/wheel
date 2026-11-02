package.path = "./lua/?.lua;./lua/?/init.lua;" .. package.path

local WheelProvider = require("wheel.provider")
local WheelRunner = require("wheel.runner")

local checks = 0
local function check(condition, message)
  checks = checks + 1
  if not condition then error("runner request assertion failed: " .. message, 0) end
end

local function format_openai(request)
  local adapter = WheelProvider.OpenAIAdapter.new({ model = "test-model", api_key = "" })
  return assert(adapter:_format_payload(request, false))
end

local function format_anthropic(request)
  local adapter = WheelProvider.AnthropicAdapter.new({ model = "test-model", api_key = "" })
  return assert(adapter:_format_payload(request, false))
end

local function schema_tool(name)
  return {
    name = name,
    description = "test tool",
    parameters = {
      type = "object",
      properties = {
        mode = { type = "string", enum = { "read", "inspect" } },
        paths = { type = "array", items = { type = "string" } },
      },
      required = { "mode", "paths" },
    },
  }
end

local source_tools = { schema_tool("inspect") }
local bounded = WheelRunner.bound_provider_request({
  model = "test-model",
  messages = {},
  tools = source_tools,
})
check(#bounded.tools == 1, "bounded tool definitions must remain an array")
check(bounded.tools[1].parameters.required[1] == "mode", "nested required arrays must retain indices")
check(bounded.tools[1].parameters.properties.mode.enum[2] == "inspect", "nested enum arrays must retain indices")
check(bounded.tools[1].parameters.properties.paths.items.type == "string", "nested schema maps must remain objects")
check(source_tools[1].parameters.required[1] == "mode", "bounding must not mutate the input")

local openai = format_openai(bounded)
local anthropic = format_anthropic(bounded)
check(#openai.tools == 1 and openai.tools[1]["function"].name == "inspect",
  "OpenAI formatting must receive the bounded tool array")
check(openai.tools[1]["function"].parameters.required[2] == "paths",
  "OpenAI formatting must preserve nested schema arrays")
check(#anthropic.tools == 1 and anthropic.tools[1].name == "inspect",
  "Anthropic formatting must receive the bounded tool array")
check(anthropic.tools[1].input_schema.required[1] == "mode",
  "Anthropic formatting must preserve nested schema arrays")

local tool_turns = 0
local executed_tool = false
local runner_provider = WheelProvider.MockProvider.new({
  completion_fn = function(request, turn)
    tool_turns = tool_turns + 1
    check(#request.tools == 1 and request.tools[1].name == "inspect",
      "actual runner requests must deliver the registered tool array")
    if turn == 1 then
      return { content = "inspect", tool_calls = {
        { id = "array-call", name = "inspect", arguments = { paths = { "a", "b" } } },
      } }
    end
    check(#request.messages >= 3 and request.messages[#request.messages - 1].role == "assistant",
      "the next provider turn must include the assistant tool call")
    check(request.messages[#request.messages].role == "tool",
      "the next provider turn must include the registered tool result")
    return { content = "complete", tool_calls = {} }
  end,
})
local runner_agent = {
  name = "runner-array-test",
  role = "Coding",
  tools = { "inspect" },
  model_profile = { model = "test-model" },
  tool_registry = { list_tools = function() return { schema_tool("inspect") } end },
  execute_tool = function(_, name, arguments)
    check(name == "inspect" and arguments.paths[2] == "b",
      "the tool call must preserve nested arguments through dispatch")
    executed_tool = true
    return {
      success = true,
      exit_code = 0,
      duration_ms = 0,
      stdout = "observed",
      stderr = "",
      stdout_preview = "observed",
      stderr_preview = "",
      format_observation = function() return "observed" end,
    }
  end,
}
local runner_result = WheelRunner.run_task(runner_agent,
  { id = "T-ARRAYS", title = "array tools", description = "offline", priority = 1 },
  { provider = runner_provider, max_turns = 2, commit_checkpoints = false })
check(runner_result.success and tool_turns == 2 and executed_tool,
  "offline runner must dispatch the tool and reach the following provider turn")

local many_tools = {}
for index = 1, 12 do many_tools[index] = schema_tool("tool-" .. index) end
local bounded_many = WheelRunner.bound_provider_request({ model = "test-model", messages = {}, tools = many_tools })
check(#bounded_many.tools == 12, "more than nine tools must retain the complete sequence")
for index = 1, 12 do
  check(bounded_many.tools[index].name == "tool-" .. index, "tool order must remain numeric at index " .. index)
end

local empty = WheelRunner.bound_provider_request({ model = "test-model", messages = {}, tools = {} })
check(type(empty.tools) == "table" and next(empty.tools) == nil, "empty arrays must remain valid empty tables")
local object = WheelRunner.bound_provider_request({ model = "test-model", messages = {}, tools = { enabled = true } })
check(object.tools.enabled == true, "string-keyed maps must remain objects")

local function bounded_tools(tools)
  return WheelRunner.bound_provider_request({ model = "test-model", messages = {}, tools = tools }).tools
end
check(next(bounded_tools({ [1] = schema_tool("one"), [3] = schema_tool("three") })) == nil,
  "sparse arrays must be rejected without reindexing")
check(next(bounded_tools({ [0] = schema_tool("zero") })) == nil,
  "zero-indexed arrays must be rejected")
check(next(bounded_tools({ [1.5] = schema_tool("fraction") })) == nil,
  "fractional numeric keys must be rejected")
check(next(bounded_tools({ [1] = schema_tool("one"), label = "mixed" })) == nil,
  "mixed numeric and string keys must be rejected")
local table_key = {}
check(next(bounded_tools({ [table_key] = "unsupported" })) == nil,
  "unsupported key types must be rejected")
local shared_key_prefix = string.rep("k", WheelRunner.MAX_REQUEST_VALUE_BYTES)
local collision = { [shared_key_prefix .. "a"] = "first", [shared_key_prefix .. "b"] = "second" }
check(next(bounded_tools(collision)) == nil, "redacted-key collisions must reject the whole map")

local cyclic = { value = "safe" }
cyclic.self = cyclic
local bounded_cycle = bounded_tools({ cyclic })
check(type(bounded_cycle[1]) == "table" and bounded_cycle[1].value == "safe" and bounded_cycle[1].self == nil,
  "cyclic descendants must be omitted without recursion")

local nested_array = { values = { "a", "b", "c" } }
local bounded_nested = bounded_tools({ nested_array })
check(bounded_nested[1].values[3] == "c", "nested arrays must remain ordered")

local secret = "Bearer sk-runner-array-secret-0001"
local redacted = bounded_tools({ { token = secret } })
check(not WheelProvider.JSON.encode(redacted):find("sk-runner-array-secret-0001", 1, true),
  "secret-shaped array values must remain redacted")
local malformed_number = bounded_tools({ { value = 0 / 0 } })
check(malformed_number[1].value == nil, "non-finite numeric values must be omitted")

local huge = string.rep("x", WheelRunner.MAX_REQUEST_VALUE_BYTES * 2)
local bounded_huge = bounded_tools({ { huge = huge } })
check(#WheelProvider.JSON.encode(bounded_huge) <= WheelRunner.MAX_REQUEST_BYTES,
  "oversized values must remain within request byte bounds")
local bounded_huge_request = WheelRunner.bound_provider_request({
  model = "test-model", messages = {}, tools = { { huge = huge } },
})
check(#WheelProvider.JSON.encode(bounded_huge_request) <= WheelRunner.MAX_REQUEST_BYTES,
  "the complete encoded request must remain within the byte budget")

local deep = { value = "at-limit" }
for _ = 1, WheelRunner.MAX_REQUEST_DEPTH do deep = { child = deep } end
local bounded_deep = bounded_tools({ deep })
check(#WheelProvider.JSON.encode(bounded_deep) <= WheelRunner.MAX_REQUEST_BYTES,
  "deep structures must terminate at the configured depth bound")
local wide = {}
for index = 1, WheelRunner.MAX_REQUEST_VALUE_NODES + 1 do wide[index] = index end
local bounded_wide = bounded_tools({ wide })
for index = 1, #bounded_wide[1] do
  check(bounded_wide[1][index] == index,
    "node exhaustion may retain only a contiguous ordered array prefix")
end

print("runner request regression: " .. checks .. " assertions passed")
