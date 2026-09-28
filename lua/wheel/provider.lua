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

local ok_kernel, WheelKernel = pcall(require, "wheel.kernel")
if not ok_kernel then
  local ok_kernel2, WheelKernel2 = pcall(require, "lua.wheel.kernel")
  WheelKernel = ok_kernel2 and WheelKernel2 or nil
end

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
  local res = self:_next_response(request)
  return res, nil
end

--- Streaming completion.
-- @param request table Standard request
-- @param on_chunk fun(chunk: table): boolean? Callback receiving { delta, type }
-- @param opts table?
-- @return table final_response, string? error
function MockProvider:stream(request, on_chunk, opts)
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
--   opts.http_client function?: injectable client fn(req) -> { status, body, stream_fn }
-- @return table OpenAIAdapter instance
function OpenAIAdapter.new(opts)
  opts = opts or {}
  local self = setmetatable({}, OpenAIAdapter)
  self.name = "openai"
  self.api_key = opts.api_key or ""
  self.base_url = opts.base_url or "https://api.openai.com/v1"
  self.model = opts.model or "gpt-4o"
  self.temperature = opts.temperature or 0.0
  self.thinking = opts.thinking
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

  local payload = {
    model = request.model or self.model,
    messages = messages,
    temperature = request.temperature or self.temperature,
    stream = stream and true or false,
  }

  if request.max_tokens then
    payload.max_tokens = request.max_tokens
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
  local payload = self:_format_payload(request, false)
  local body_str = json.encode(payload)
  local endpoint = self.base_url:gsub("/+$", "") .. "/chat/completions"

  local headers = {
    ["Content-Type"] = "application/json",
  }
  if #self.api_key > 0 then
    headers["Authorization"] = "Bearer " .. self.api_key
  end

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
    usage = data.usage or {},
  }, nil
end

--- Execute streaming completion.
function OpenAIAdapter:stream(request, on_chunk, opts)
  opts = opts or {}
  local payload = self:_format_payload(request, true)
  local body_str = json.encode(payload)
  local endpoint = self.base_url:gsub("/+$", "") .. "/chat/completions"

  local headers = {
    ["Content-Type"] = "application/json",
    ["Accept"] = "text/event-stream",
  }
  if #self.api_key > 0 then
    headers["Authorization"] = "Bearer " .. self.api_key
  end

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

  local res, err = client({
    url = endpoint,
    method = "POST",
    headers = headers,
    body = body_str,
    stream = true,
    on_stream_chunk = function(chunk)
      parser:feed(chunk, function(evt)
        local raw = evt.data
        if not raw or raw == "[DONE]" then
          return true
        end

        local ok, chunk_data = pcall(json.decode, raw)
        if not ok or type(chunk_data) ~= "table" then
          return false
        end

        if chunk_data.usage then
          usage = chunk_data.usage
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
    end,
  })

  if not res then
    return nil, "Streaming HTTP request failed: " .. tostring(err)
  end
  if res.status and (res.status < 200 or res.status >= 300) then
    local preview = (res.body or ""):sub(1, 512)
    return nil, string.format("HTTP %d streaming error: %s", res.status, preview)
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
    usage = usage,
  }, nil
end

WheelProvider.OpenAIAdapter = OpenAIAdapter

-- ---------------------------------------------------------------------------
-- Anthropic Messages API Provider Adapter
-- ---------------------------------------------------------------------------

local AnthropicAdapter = {}
AnthropicAdapter.__index = AnthropicAdapter

--- Create a new Anthropic provider adapter (Claude 3.5 Sonnet, Claude 3 Opus).
-- @param opts table:
--   opts.api_key string?
--   opts.base_url string? (defaults to "https://api.anthropic.com/v1")
--   opts.model string? (defaults to "claude-3-5-sonnet-20241022")
--   opts.version string? (defaults to "2023-06-01")
--   opts.thinking table? { enabled = bool, budget_tokens = number }
--   opts.http_client function?: injectable client fn(req) -> { status, body, stream_fn }
-- @return table AnthropicAdapter instance
function AnthropicAdapter.new(opts)
  opts = opts or {}
  local self = setmetatable({}, AnthropicAdapter)
  self.name = "anthropic"
  self.api_key = opts.api_key or os.getenv("ANTHROPIC_API_KEY") or ""
  self.base_url = opts.base_url or "https://api.anthropic.com/v1"
  self.model = opts.model or "claude-3-5-sonnet-20241022"
  self.version = opts.version or "2023-06-01"
  self.thinking = opts.thinking
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

  local payload = {
    model = request.model or self.model,
    messages = messages,
    max_tokens = request.max_tokens or 4096,
    stream = stream and true or false,
  }

  if #system_parts > 0 then
    payload.system = table.concat(system_parts, "\n\n")
  end

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
  local payload = self:_format_payload(request, false)
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
    usage = data.usage or {},
  }, nil
end

--- Execute streaming completion.
function AnthropicAdapter:stream(request, on_chunk, opts)
  opts = opts or {}
  local payload = self:_format_payload(request, true)
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
    on_stream_chunk = function(chunk)
      if stream_err then return true end
      parser:feed(chunk, function(evt)
        if evt.event == "error" then
          local err_msg = evt.data or "unknown error"
          local ok, data = pcall(json.decode, evt.data or "")
          if ok and type(data) == "table" and data.error and data.error.message then
            err_msg = data.error.message
          end
          stream_err = "Anthropic stream error: " .. tostring(err_msg)
          return true
        end

        local raw = evt.data
        if not raw then return false end

        local ok, data = pcall(json.decode, raw)
        if not ok or type(data) ~= "table" then return false end

        local evt_type = data.type or evt.event

        if evt_type == "content_block_start" then
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
            usage = data.usage
          end
        elseif evt_type == "message_stop" then
          return true
        end

        return false
      end)
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
    usage = usage,
  }, nil
end

WheelProvider.AnthropicAdapter = AnthropicAdapter

-- ---------------------------------------------------------------------------
-- Stdio Subprocess Adapter
-- ---------------------------------------------------------------------------

local StdioAdapter = {}
StdioAdapter.__index = StdioAdapter

--- Create a new Stdio Subprocess Adapter for running local model CLI tools.
-- @param opts table?:
--   opts.command string|table: CLI command line or argv table (e.g. "ollama run qwen2.5-coder")
--   opts.runner function?: injectable runner for test isolation
-- @return table StdioAdapter instance
function StdioAdapter.new(opts)
  opts = opts or {}
  local self = setmetatable({}, StdioAdapter)
  self.name = "stdio"
  self.command = opts.command or "ollama run qwen2.5-coder"
  self.runner = opts.runner
  return self
end

function StdioAdapter:describe()
  return {
    provider = "stdio",
    command = self.command,
  }
end

function StdioAdapter:complete(request, opts)
  opts = opts or {}
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

  -- Secure command execution via redirected temporary file
  local tmp_file = os.tmpname()
  local f = io.open(tmp_file, "w")
  if not f then
    return nil, "Failed to open temporary file for stdio prompt: " .. tostring(tmp_file)
  end
  f:write(prompt)
  f:close()

  local safe_cmd = string.format("%s < %q 2>&1", self.command, tmp_file)
  local p = io.popen(safe_cmd, "r")
  if not p then
    os.remove(tmp_file)
    return nil, "Failed to spawn stdio model process: " .. tostring(self.command)
  end

  local out = p:read("*a") or ""
  local close_ok, close_reason, exit_code = p:close()
  os.remove(tmp_file)

  if close_ok ~= true then
    local code = exit_code or 1
    return nil, string.format("Command '%s' failed (exit code %s): %s", self.command, tostring(code), out:sub(1, 512))
  end

  return {
    content = out,
    finish_reason = "stop",
    usage = {},
  }, nil
end

function StdioAdapter:stream(request, on_chunk, opts)
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
-- @param opts table? Additional options (e.g. http_client, api_key, base_url)
-- @return table? WheelProvider adapter instance, or nil on failure
-- @return string? Error message on failure
function WheelProvider.create(profile, opts)
  profile = profile or {}
  opts = opts or {}
  local p_type = string.lower(profile.provider or opts.provider or "mock")

  if p_type == "mock" then
    return MockProvider.new({
      model = profile.model or opts.model or "mock-model",
      responses = opts.responses,
      completion_fn = opts.completion_fn,
      stream_chunk_size = opts.stream_chunk_size,
    })
  elseif p_type == "openai" then
    local api_key = opts.api_key or os.getenv("OPENAI_API_KEY") or ""
    return OpenAIAdapter.new({
      api_key = api_key,
      base_url = opts.base_url or "https://api.openai.com/v1",
      model = profile.model or opts.model or "gpt-4o",
      temperature = profile.temperature or opts.temperature or 0.0,
      thinking = profile.thinking or opts.thinking,
      http_client = opts.http_client,
    })
  elseif p_type == "deepseek" then
    local api_key = opts.api_key or os.getenv("DEEPSEEK_API_KEY") or ""
    return OpenAIAdapter.new({
      api_key = api_key,
      base_url = opts.base_url or "https://api.deepseek.com/v1",
      model = profile.model or opts.model or "deepseek-reasoner",
      temperature = profile.temperature or opts.temperature or 0.0,
      thinking = profile.thinking or opts.thinking,
      http_client = opts.http_client,
    })
  elseif p_type == "anthropic" then
    local api_key = opts.api_key or os.getenv("ANTHROPIC_API_KEY") or ""
    return AnthropicAdapter.new({
      api_key = api_key,
      base_url = opts.base_url or "https://api.anthropic.com/v1",
      model = profile.model or opts.model or "claude-3-5-sonnet-20241022",
      thinking = profile.thinking or opts.thinking,
      http_client = opts.http_client,
    })
  elseif p_type == "stdio" or p_type == "local" or p_type == "ollama" then
    local cmd = opts.command
    if cmd ~= nil and type(cmd) ~= "string" then
      return nil, "opts.command must be a string"
    end
    if not cmd then
      local m = profile.model or opts.model or "qwen2.5-coder"
      if type(m) ~= "string" or not m:match("^[%w%._%-:]+$") then
        return nil, "Invalid model name for local/ollama provider: " .. tostring(m)
      end
      cmd = "ollama run " .. m
    end
    return StdioAdapter.new({
      command = cmd,
      runner = opts.runner,
    })
  else
    return nil, "Unknown or unsupported provider type: " .. tostring(p_type)
  end
end

return WheelProvider
