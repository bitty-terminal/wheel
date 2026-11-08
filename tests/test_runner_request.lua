package.path = "./lua/?.lua;./lua/?/init.lua;" .. package.path

local WheelProvider = require("wheel.provider")
local WheelRunner = require("wheel.runner")

local checks = 0
local function check(condition, message)
  checks = checks + 1
  if not condition then error("runner request assertion failed: " .. message, 0) end
end

--- Format an offline OpenAI payload through the real adapter formatter.
-- @param request table bounded provider request
-- @return table? payload, string? validation error
local function format_openai(request)
  local adapter = WheelProvider.OpenAIAdapter.new({ model = "test-model", api_key = "" })
  return adapter:_format_payload(request, false)
end

--- Format an offline Anthropic payload through the real adapter formatter.
-- @param request table bounded provider request
-- @return table? payload, string? validation error
local function format_anthropic(request)
  local adapter = WheelProvider.AnthropicAdapter.new({ model = "test-model", api_key = "" })
  return adapter:_format_payload(request, false)
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

local function encode(value)
  return assert(WheelProvider.JSON.encode(value))
end

--- Build a bounded tool fixture whose named constraint is intentionally large.
-- @param field string either the top-level `required` or nested `enum`
-- @param count number number of array members
-- @return table tool descriptor
local function oversized_schema_tool(field, count)
  local values = {}
  for index = 1, count do values[index] = field .. "-" .. index end
  return {
    name = "oversized-" .. field,
    description = "test tool",
    parameters = {
      type = "object",
      properties = { field = { type = "string", enum = values } },
      required = field == "required" and values or { "field" },
    },
  }
end

--- Build a tool with an oversized nested object `required` constraint.
-- @param count number number of nested required members
-- @return table tool descriptor
local function oversized_nested_required_tool(count)
  local values = {}
  for index = 1, count do values[index] = "nested-" .. index end
  return {
    name = "oversized-nested-required",
    parameters = {
      type = "object",
      properties = {
        settings = {
          type = "object",
          properties = {},
          required = values,
        },
      },
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

local oversized_required = WheelRunner.bound_provider_request({
  model = "test-model", messages = {},
  tools = { oversized_schema_tool("required", WheelRunner.MAX_REQUEST_NODES + 1) },
})
check(oversized_required == nil,
  "an unboundable top-level required array must reject its enclosing tool")

local oversized_enum = WheelRunner.bound_provider_request({
  model = "test-model", messages = {},
  tools = { oversized_schema_tool("enum", WheelRunner.MAX_REQUEST_NODES + 1) },
})
check(oversized_enum == nil,
  "an unboundable nested enum array must reject its enclosing tool")

local oversized_nested_required = WheelRunner.bound_provider_request({
  model = "test-model", messages = {},
  tools = { oversized_nested_required_tool(WheelRunner.MAX_REQUEST_NODES + 1) },
})
check(oversized_nested_required == nil,
  "an unboundable nested required array must reject its enclosing tool")

local deep_schema = { type = "object", properties = {} }
local deep_cursor = deep_schema
for _ = 1, WheelRunner.MAX_REQUEST_DEPTH do
  deep_cursor.properties.child = { type = "object", properties = {} }
  deep_cursor = deep_cursor.properties.child
end
deep_cursor.properties.leaf = { type = "string" }
local bounded_deep_schema = WheelRunner.bound_provider_request({
  model = "test-model", messages = {},
  tools = { { name = "deep", parameters = deep_schema } },
})
check(bounded_deep_schema == nil,
  "a schema exceeding the depth bound must reject its enclosing tool")

local cyclic_schema = { type = "object", properties = {} }
cyclic_schema.properties.loop = cyclic_schema
local bounded_cyclic_schema = WheelRunner.bound_provider_request({
  model = "test-model", messages = {},
  tools = { { name = "cyclic", parameters = cyclic_schema } },
})
check(bounded_cyclic_schema == nil,
  "a cyclic schema member must reject its enclosing tool")

local near_node_tools = {}
for index = 1, WheelRunner.MAX_REQUEST_NODES - 20 do near_node_tools[index] = index end
local near_node_bounded = WheelRunner.bound_provider_request({
  model = "test-model", messages = {}, tools = near_node_tools,
})
check(#near_node_bounded.tools == #near_node_tools,
  "a near-bound tool array must remain available")
local saved_max_request_keys = WheelRunner.MAX_REQUEST_KEYS
local whole_node_tools = {}
for index = 1, WheelRunner.MAX_REQUEST_NODES + 1 do whole_node_tools[index] = index end
local whole_node_ok, whole_node_bounded = pcall(function()
  WheelRunner.MAX_REQUEST_KEYS = WheelRunner.MAX_REQUEST_NODES + 8
  return WheelRunner.bound_provider_request({
    model = "test-model", messages = {}, tools = whole_node_tools,
  })
end)
WheelRunner.MAX_REQUEST_KEYS = saved_max_request_keys
check(whole_node_ok and whole_node_bounded == nil,
  "whole-request node exhaustion must reject tools after the key budget is raised")

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
  local request = WheelRunner.bound_provider_request({ model = "test-model", messages = {}, tools = tools })
  return request and request.tools or nil
end
check(bounded_tools({ [1] = schema_tool("one"), [3] = schema_tool("three") }) == nil,
  "sparse arrays must be rejected without reindexing")
check(bounded_tools({ [0] = schema_tool("zero") }) == nil,
  "zero-indexed arrays must be rejected")
check(bounded_tools({ [1.5] = schema_tool("fraction") }) == nil,
  "fractional numeric keys must be rejected")
check(bounded_tools({ [1] = schema_tool("one"), label = "mixed" }) == nil,
  "mixed numeric and string keys must be rejected")
local table_key = {}
check(bounded_tools({ [table_key] = "unsupported" }) == nil,
  "unsupported key types must be rejected")
local shared_key_prefix = string.rep("k", WheelRunner.MAX_REQUEST_VALUE_BYTES)
local collision = { [shared_key_prefix .. "a"] = "first", [shared_key_prefix .. "b"] = "second" }
check(bounded_tools(collision) == nil, "redacted-key collisions must reject the whole map")

local cyclic = { value = "safe" }
cyclic.self = cyclic
local bounded_cycle = bounded_tools({ cyclic })
check(bounded_cycle == nil, "cyclic tool values must reject the enclosing tool")

local nested_array = { values = { "a", "b", "c" } }
local bounded_nested = bounded_tools({ nested_array })
check(bounded_nested[1].values[3] == "c", "nested arrays must remain ordered")

local normalization_schema = {
  type = "object",
  properties = {
    required = { type = "string" },
    settings = {
      type = "object",
      properties = {
        required = { type = "boolean" },
        nested = { type = "object", properties = { required = { type = "number" } } },
      },
      required = {},
    },
    empty = { type = "object", properties = {} },
    entries = {
      type = "array",
      items = {
        type = "object",
        properties = { required = { type = "integer" } },
        required = {},
      },
    },
  },
  required = {},
}
local normalization_before = encode(normalization_schema)
local normalization_request = { messages = {}, tools = {
  { name = "normalize", description = "schema", parameters = normalization_schema },
} }
local normalized_openai = format_openai(normalization_request)
local normalized_anthropic = format_anthropic(normalization_request)
local normalized_openai_encoded = encode(normalized_openai)
local normalized_anthropic_encoded = encode(normalized_anthropic)
check(normalized_openai.tools[1]["function"].parameters.required == nil,
  "OpenAI must omit an empty schema-level required array")
check(normalized_anthropic.tools[1].input_schema.required == nil,
  "Anthropic must omit an empty schema-level required array")
check(normalized_openai.tools[1]["function"].parameters.properties.required.type == "string",
  "OpenAI must preserve a meaningful data property named required")
check(normalized_anthropic.tools[1].input_schema.properties.settings.required == nil,
  "Anthropic must omit nested empty schema-level required arrays")
check(normalized_openai.tools[1]["function"].parameters.properties.settings.properties.required.type == "boolean",
  "OpenAI must preserve nested properties named required")
check(normalized_anthropic.tools[1].input_schema.properties.settings.properties.nested.properties.required.type == "number",
  "Anthropic must preserve deeper properties named required")
check(normalized_openai.tools[1]["function"].parameters.properties.entries.items.properties.required.type == "integer",
  "OpenAI must preserve nested array object properties named required")
check(type(normalized_openai.tools[1]["function"].parameters.properties.empty.properties) == "table"
    and next(normalized_openai.tools[1]["function"].parameters.properties.empty.properties) == nil,
  "OpenAI must preserve empty object-valued schema properties")
check(type(normalized_anthropic.tools[1].input_schema.properties.empty.properties) == "table"
    and next(normalized_anthropic.tools[1].input_schema.properties.empty.properties) == nil,
  "Anthropic must preserve nested empty object-valued schema properties")
check(normalized_openai_encoded:find('"required":{}', 1, true) == nil
    and normalized_anthropic_encoded:find('"required":{}', 1, true) == nil,
  "encoded provider payloads must not contain empty required objects")
check(normalization_before == encode(normalization_schema),
  "schema normalization must not mutate the registered schema")

local defaults_openai = format_openai({ messages = {}, tools = { { name = "default" } } })
local defaults_anthropic = format_anthropic({ messages = {}, tools = { { name = "default" } } })
check(defaults_openai.tools[1]["function"].parameters.properties ~= nil,
  "OpenAI must retain its valid default schema")
check(defaults_anthropic.tools[1].input_schema.properties ~= nil,
  "Anthropic must retain its valid default schema")

local provider_cyclic_schema = { type = "object", properties = {} }
provider_cyclic_schema.properties.loop = provider_cyclic_schema
local provider_cyclic_openai, provider_cyclic_openai_error = format_openai({ messages = {}, tools = {
  { name = "cyclic", parameters = provider_cyclic_schema },
} })
local provider_cyclic_anthropic, provider_cyclic_anthropic_error = format_anthropic({ messages = {}, tools = {
  { name = "cyclic", parameters = provider_cyclic_schema },
} })
check(provider_cyclic_openai == nil and provider_cyclic_anthropic == nil
    and type(provider_cyclic_openai_error) == "string" and type(provider_cyclic_anthropic_error) == "string",
  "cyclic provider schemas must be refused without permissive fallback")

local secret = "Bearer sk-runner-array-secret-0001"
local redacted = bounded_tools({ { token = secret } })
check(redacted == nil,
  "strict tool bounding must refuse secret-shaped tool schema values rather than sending altered constraints")
local truncated_enum_val = string.rep("e", WheelRunner.MAX_REQUEST_VALUE_BYTES + 1)
check(bounded_tools({ {
  name = "trunc-enum",
  parameters = {
    type = "object",
    properties = { mode = { type = "string", enum = { truncated_enum_val } } },
  },
} }) == nil, "strict tool bounding must reject over-limit enum constraint values")
local truncated_prop_name = string.rep("p", WheelRunner.MAX_REQUEST_VALUE_BYTES + 1)
check(bounded_tools({ {
  name = "trunc-prop",
  parameters = {
    type = "object",
    properties = { [truncated_prop_name] = { type = "string" } },
  },
} }) == nil, "strict tool bounding must reject over-limit property names")
local malformed_number = bounded_tools({ { value = 0 / 0 } })
check(malformed_number == nil, "non-finite numeric values must reject the enclosing tool")

local huge = string.rep("x", WheelRunner.MAX_REQUEST_VALUE_BYTES * 2)
local bounded_huge = bounded_tools({ { huge = huge } })
check(bounded_huge == nil,
  "oversized strict tool values must be rejected rather than silently truncated")
local bounded_huge_msg_request = WheelRunner.bound_provider_request({
  model = "test-model",
  messages = { { role = "user", content = huge } },
  tools = { schema_tool("inspect") },
})
check(bounded_huge_msg_request ~= nil
    and #bounded_huge_msg_request.tools == 1
    and #WheelProvider.JSON.encode(bounded_huge_msg_request) <= WheelRunner.MAX_REQUEST_BYTES,
  "oversized message content must remain bounded while preserving valid tools")

local false_schema_tool = {
  name = "boolean-false-tool",
  description = "preserves boolean false",
  parameters = {
    type = "object",
    properties = {
      flag = {
        type = "boolean",
        default = false,
        enum = { true, false },
      },
    },
    additionalProperties = false,
  },
}
local bounded_false = WheelRunner.bound_provider_request({
  model = "test-model", messages = {}, tools = { false_schema_tool },
})
check(bounded_false ~= nil and #bounded_false.tools == 1,
  "strict tool bounding must accept schemas containing boolean false")
check(bounded_false.tools[1].parameters.additionalProperties == false,
  "additionalProperties=false must be preserved")
check(bounded_false.tools[1].parameters.properties.flag.default == false,
  "default=false must be preserved")
check(bounded_false.tools[1].parameters.properties.flag.enum[1] == true
    and bounded_false.tools[1].parameters.properties.flag.enum[2] == false,
  "enum={true,false} must preserve both boolean values")

local shared_alias = { type = "object", properties = { ok = { type = "string" } }, required = {} }
local instance_and_maps_schema = {
  type = "object",
  properties = {
    alias_a = shared_alias,
    alias_b = shared_alias,
    cfg = {
      type = "object",
      default = { required = {} },
      const = { required = {} },
      enum = { { required = {} } },
      examples = { { required = {} } },
    },
  },
  patternProperties = {
    required = { type = "string" },
  },
  ["$defs"] = {
    required = { type = "object", properties = {}, required = {} },
  },
  dependentSchemas = {
    required = { type = "object", properties = {}, required = {} },
  },
  allOf = {
    { type = "object", properties = {}, required = {} },
  },
  required = {},
}
local instance_before = encode(instance_and_maps_schema)
local instance_req = { messages = {}, tools = {
  { name = "ctx-schema", description = "context test", parameters = instance_and_maps_schema },
} }
local ctx_openai = format_openai(instance_req)
local ctx_anthropic = format_anthropic(instance_req)
for _, params in ipairs({
  ctx_openai.tools[1]["function"].parameters,
  ctx_anthropic.tools[1].input_schema,
}) do
  check(params.required == nil, "top-level empty required must be omitted")
  check(params.properties.alias_a.required == nil and params.properties.alias_b.required == nil,
    "shared non-cyclic schema aliases must both be normalized")
  check(type(params.properties.cfg.default.required) == "table",
    "default instance object member named required={} must be preserved")
  check(type(params.properties.cfg.const.required) == "table",
    "const instance object member named required={} must be preserved")
  check(type(params.properties.cfg.enum[1].required) == "table",
    "enum instance object member named required={} must be preserved")
  check(type(params.properties.cfg.examples[1].required) == "table",
    "examples instance object member named required={} must be preserved")
  check(params.patternProperties.required.type == "string",
    "patternProperties entry named required must be preserved")
  check(type(params["$defs"].required) == "table" and params["$defs"].required.required == nil,
    "$defs entry named required must be preserved while its own empty required is omitted")
  check(type(params.dependentSchemas.required) == "table" and params.dependentSchemas.required.required == nil,
    "dependentSchemas entry named required must be preserved while its own empty required is omitted")
  check(type(params.allOf[1]) == "table" and params.allOf[1].required == nil,
    "allOf schema sequence member must omit empty required")
end
check(encode(instance_and_maps_schema) == instance_before,
  "context-aware normalization must not mutate input schema or aliases")

local nul_desc_tools = { {
  name = "nul-desc",
  description = string.rep("\0", 10000),
  parameters = { type = "object", properties = {} },
} }
check(( WheelProvider.format_tools_for_openai(nul_desc_tools) ) == nil,
  "OpenAI formatter must charge escaped JSON bytes for NUL descriptions")
check(( WheelProvider.format_tools_for_anthropic(nul_desc_tools) ) == nil,
  "Anthropic formatter must charge escaped JSON bytes for NUL descriptions")

local aggregate_tools = {}
for index = 1, 100 do
  aggregate_tools[index] = {
    name = "agg-" .. index,
    description = string.rep("d", 900),
    parameters = {
      type = "object",
      properties = {
        value = { type = "string", description = string.rep("v", 200) },
      },
    },
  }
end
check(( WheelProvider.format_tools_for_openai(aggregate_tools) ) == nil,
  "OpenAI formatter must share aggregate byte budget across all tools")
check(( WheelProvider.format_tools_for_anthropic(aggregate_tools) ) == nil,
  "Anthropic formatter must share aggregate byte budget across all tools")

local transport_calls = 0
local big_desc_req = {
  model = "test-model",
  messages = { { role = "user", content = "hi" } },
  tools = { {
    name = "big-desc",
    description = string.rep("x", 60000),
    parameters = { type = "object", properties = {} },
  } },
}
local oa_adapter = WheelProvider.OpenAIAdapter.new({
  model = "test-model",
  api_key = "k",
  http_client = function()
    transport_calls = transport_calls + 1
    return { status = 200, body = "{}" }
  end,
})
local an_adapter = WheelProvider.AnthropicAdapter.new({
  model = "test-model",
  api_key = "k",
  http_client = function()
    transport_calls = transport_calls + 1
    return { status = 200, body = "{}" }
  end,
})
local oa_res, oa_err = oa_adapter:complete(big_desc_req)
local an_res, an_err = an_adapter:complete(big_desc_req)
check(oa_res == nil and type(oa_err) == "string"
    and an_res == nil and type(an_err) == "string"
    and transport_calls == 0,
  "OpenAI and Anthropic adapters must refuse oversized tool descriptions before calling transport")

local props_25 = {}
for index = 1, 25 do
  props_25["p" .. index] = { type = "string", description = string.rep("x", 1915) }
end
local tool_25x1915 = { {
  name = "near-limit-tool",
  description = "test",
  parameters = { type = "object", properties = props_25 },
} }
local trim_preserved = WheelRunner.bound_provider_request({
  model = "test-model",
  messages = {
    { role = "system", content = string.rep("s", 8000) },
    { role = "user", content = "short pinned task" },
    { role = "assistant", content = string.rep("a", 8000) },
  },
  tools = { schema_tool("inspect") },
  thinking = { enabled = true, budget_tokens = 1024 },
})
check(trim_preserved ~= nil and #trim_preserved.tools == 1 and trim_preserved.tools[1].name == "inspect",
  "byte trimming of optional messages must preserve valid tools")
local refusal_calls = 0
local refusal_provider = WheelProvider.MockProvider.new({
  completion_fn = function()
    refusal_calls = refusal_calls + 1
    return { content = "unexpected", tool_calls = {} }
  end,
})
local refusal_agent = {
  name = "refusal-agent",
  role = "Coding",
  tools = { "near-limit-tool" },
  model_profile = { model = "test-model" },
  tool_registry = { list_tools = function() return tool_25x1915 end },
}
local refusal_result = WheelRunner.run_task(refusal_agent,
  { id = "T-REFUSE", title = "refuse", description = "near-limit tools", priority = 1 },
  { provider = refusal_provider, max_turns = 1, commit_checkpoints = false })
check(not refusal_result.success and refusal_calls == 0,
  "final byte trimming must refuse rather than dropping tools and calling the provider")
local oa_refusal_result = WheelRunner.run_task(refusal_agent,
  { id = "T-REFUSE-OA", title = "refuse", description = "near-limit tools", priority = 1 },
  { provider = oa_adapter, max_turns = 1, commit_checkpoints = false })
local an_refusal_result = WheelRunner.run_task(refusal_agent,
  { id = "T-REFUSE-AN", title = "refuse", description = "near-limit tools", priority = 1 },
  { provider = an_adapter, max_turns = 1, commit_checkpoints = false })
check(not oa_refusal_result.success and not an_refusal_result.success and transport_calls == 0,
  "real OpenAI and Anthropic adapters in run_task must not receive a tool-stripped request")

local deep = { value = "at-limit" }
for _ = 1, WheelRunner.MAX_REQUEST_DEPTH do deep = { child = deep } end
local bounded_deep = bounded_tools({ deep })
check(bounded_deep == nil,
  "strict tool bounding must reject structures that exceed the configured depth bound")
local wide = {}
for index = 1, WheelRunner.MAX_REQUEST_NODES + 1 do wide[index] = index end
local bounded_wide = bounded_tools({ wide })
check(bounded_wide == nil, "node exhaustion must reject the enclosing tool")

print("runner request regression: " .. checks .. " assertions passed")
