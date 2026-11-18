-- tests/test_cli_correctness.lua
-- Regression suite for the Wheel CLI correctness fixes (CTX-0057 / wheel#148):
--   1. One model-precedence rule: --model > role config model (bare names apply
--      to the active provider) > provider template default. String, table, and
--      provider/model ids are resolved without retargeting catalogue providers.
--   2. Per-subcommand --help/-h and `help <command>` exit 0 without a provider
--      call; unknown options are usage errors, never prompt text.
--   3. --max-turns bounds and a distinct budget-exhaustion exit code/message.
--   4. --trace writes bounded, redacted tool-call diagnostics to stderr only.
--   5. Role tool lists are validated against the registry at construction.
--
-- No network and no real provider: every adapter call goes through an injected
-- http_client stub.

package.path = "./lua/?.lua;./lua/?/init.lua;" .. package.path

local WheelHost = require("wheel.host")
local WheelConfig = require("wheel.config")
local WheelProvider = require("wheel.provider")
local WheelAgent = require("wheel.agent")
local WheelKernel = require("wheel.kernel")
local WheelTool = require("wheel.tool")
local WheelErrors = require("wheel.errors")
local WheelCLI = require("wheel.cli")

local function make_temp_root(prefix)
  local base = os.getenv("WHEEL_TEST_TMP") or os.getenv("TMPDIR") or "/tmp/bitty"
  WheelHost.fs.mkdir_p(base)
  local pid = (WheelHost.proc and type(WheelHost.proc.pid) == "function" and WheelHost.proc.pid()) or 0
  local dir = base
    .. "/"
    .. prefix
    .. "-"
    .. tostring(os.time())
    .. "-"
    .. tostring(pid)
    .. "-"
    .. tostring(math.random(100000, 999999))
  assert(WheelHost.fs.mkdir_p(dir), "failed to create temp test dir: " .. dir)
  assert(WheelHost.fs.chmod(dir, "700"), "failed to chmod temp dir 0700")
  return dir
end

local function cleanup_dir(dir)
  if type(dir) == "string" and #dir > 10 then
    WheelHost.proc.run_program("rm", { "-rf", "--", dir }, { discard_stderr = true })
  end
end

local root = make_temp_root("wheel-cli-correctness")
local ok_all, test_err = pcall(function()
  local ws = root .. "/ws"
  assert(WheelHost.fs.mkdir_p(ws))
  local env = {
    HOME = root,
    XDG_CONFIG_HOME = root .. "/config",
    XDG_DATA_HOME = root .. "/data",
    XDG_STATE_HOME = root .. "/state",
    OPENCODE_GO_API_KEY = "test-key-not-a-secret",
    OPENROUTER_API_KEY = "test-openrouter-key",
    DEEPSEEK_API_KEY = "test-deepseek-key",
  }

  local function write_text(path, content)
    local parent = path:match("^(.*)/[^/]+$")
    if parent then assert(WheelHost.fs.mkdir_p(parent)) end
    local file = assert(io.open(path, "wb"))
    file:write(content)
    file:close()
  end

  local function capture_harness(extra)
    local harness = {
      env = env,
      stdout = function() end,
      stderr = function() end,
    }
    for k, v in pairs(extra or {}) do harness[k] = v end
    return harness
  end

  local function run_cli(argv, extra)
    local out_buf, err_buf = {}, {}
    local harness = capture_harness(extra)
    harness.stdout = function(s) table.insert(out_buf, tostring(s)) end
    harness.stderr = function(s) table.insert(err_buf, tostring(s)) end
    local rc = WheelCLI.main(argv, harness)
    return rc, table.concat(out_buf, ""), table.concat(err_buf, "")
  end

  local function stream_chunk(message, finish_reason)
    local chunk = WheelProvider.JSON.encode({
      choices = { { delta = message, finish_reason = finish_reason } },
    })
    return "data: " .. chunk .. "\n\ndata: [DONE]\n\n"
  end

  -- Scripted run stub: `tool_turns` tool-call turns, then a final answer.
  -- `always_tool` keeps requesting tools until the runner stops.
  local function make_run_http(opts)
    opts = opts or {}
    local state = { requests = 0, models = {}, urls = {} }
    local client = function(req)
      state.requests = state.requests + 1
      local decoded = WheelProvider.JSON.decode(req.body or "{}")
      table.insert(state.models, decoded.model)
      table.insert(state.urls, req.url)
      local message, finish
      if opts.always_tool or state.requests <= (opts.tool_turns or 0) then
        message = {
          content = "",
          tool_calls = {
            {
              index = 0,
              id = "call_" .. tostring(state.requests),
              type = "function",
              ["function"] = {
                name = opts.tool_name or "run_command",
                arguments = opts.tool_args or '{"command":"echo trace-ok"}',
              },
            },
          },
        }
        finish = "tool_calls"
      else
        message = { content = opts.final_content or "final answer" }
        finish = "stop"
      end
      req.on_stream_chunk(stream_chunk(message, finish))
      return { status = 200, body = "" }
    end
    return client, state
  end

  -- 1. Model precedence, resolved once and shared by every constructor path.
  do
    local coding = WheelAgent.Role.CODING
    local function resolve(model, role_model, extra)
      extra = extra or {}
      local opts = {
        model = model,
        provider_default_model = "deepseek-v4.1-flash",
        config = { roles = { [coding] = { model = role_model } } },
      }
      if not extra.no_active_provider then
        opts.provider_name = "opencode-go"
      end
      for k, v in pairs(extra) do
        if k ~= "no_active_provider" then opts[k] = v end
      end
      local profile, err = WheelAgent.resolve_model(coding, opts)
      assert(profile ~= nil, "resolve_model failed: " .. tostring(err))
      return profile
    end

    -- Role default (anthropic/claude) does not belong to opencode-go.
    local p_default = resolve(nil)
    assert(p_default.provider == "opencode-go" and p_default.model == "deepseek-v4.1-flash",
      "role default must fall back to the provider template default, got "
        .. tostring(p_default.provider) .. "/" .. tostring(p_default.model))

    -- A string --model wins and is adopted by the active provider.
    local p_string = resolve("deepseek-v4.1-flash")
    assert(p_string.model == "deepseek-v4.1-flash" and p_string.provider == "opencode-go",
      "string --model must be applied")

    -- `provider/model` selects the provider when no provider is selected yet.
    local p_prefixed = resolve("openrouter/deepseek/deepseek-chat", nil,
      { no_active_provider = true, provider_default_model = nil })
    assert(p_prefixed.provider == "openrouter" and p_prefixed.model == "deepseek/deepseek-chat",
      "provider/model must split on the known provider prefix, got "
        .. tostring(p_prefixed.provider) .. "/" .. tostring(p_prefixed.model))

    -- With an explicit provider, only a matching prefix is split. A catalogue
    -- id like OpenRouter's `deepseek/deepseek-chat` stays opaque.
    local p_catalogue = resolve("deepseek/deepseek-chat", nil,
      { provider_name = "openrouter", provider_default_model = "openrouter-default" })
    assert(p_catalogue.provider == "openrouter" and p_catalogue.model == "deepseek/deepseek-chat",
      "catalogue provider ids must not retarget the provider, got "
        .. tostring(p_catalogue.provider) .. "/" .. tostring(p_catalogue.model))
    local p_same_prefix = resolve("deepseek/deepseek-chat", nil,
      { provider_name = "deepseek", provider_default_model = "deepseek-chat" })
    assert(p_same_prefix.provider == "deepseek" and p_same_prefix.model == "deepseek-chat",
      "a prefix matching the explicit provider must be split")

    -- Table form keeps working, including temperature.
    local p_table = resolve({ name = "table-model", provider = "opencode-go", temperature = 0.3 })
    assert(p_table.model == "table-model" and p_table.provider == "opencode-go"
      and p_table.temperature == 0.3, "table --model must keep name/provider/temperature")

    -- A table without a model name is not a model selection and falls through
    -- to the provider default instead of sending the role default.
    local p_nameless = resolve({ temperature = 0.3 })
    assert(p_nameless.model == "deepseek-v4.1-flash" and p_nameless.provider == "opencode-go",
      "a nameless table model must fall through to the provider default, got "
        .. tostring(p_nameless.model))

    -- Role config model that belongs to the active provider outranks the default.
    local p_role = resolve(nil, { name = "deepseek-reasoner", provider = "opencode-go" })
    assert(p_role.model == "deepseek-reasoner" and p_role.provider == "opencode-go",
      "role model belonging to the active provider must win over the template default")

    -- Role config model from another provider is ignored.
    local p_foreign = resolve(nil, { name = "claude-3-5-sonnet", provider = "anthropic" })
    assert(p_foreign.model == "deepseek-v4.1-flash",
      "role model from another provider must not override the active provider model")

    -- A bare role model is an explicit model id for the active provider.
    local p_bare = resolve(nil, "my-custom-model")
    assert(p_bare.model == "my-custom-model" and p_bare.provider == "opencode-go",
      "a bare role model must be applied to the active provider, got "
        .. tostring(p_bare.model))

    -- A role-config string naming a foreign provider is skipped (foreign
    -- claim), matching the table form and the documented rule.
    local p_foreign_string = resolve(nil, "anthropic/claude-3-5-sonnet")
    assert(p_foreign_string.model == "deepseek-v4.1-flash"
      and p_foreign_string.provider == "opencode-go",
      "a foreign provider string claim must be skipped, got "
        .. tostring(p_foreign_string.model))

    -- A role-config string naming the active provider strips the prefix.
    local p_matching_string = resolve(nil, "opencode-go/my-model")
    assert(p_matching_string.model == "my-model" and p_matching_string.provider == "opencode-go",
      "a role-config string for the active provider must be split, got "
        .. tostring(p_matching_string.model))

    -- A nameless table role model keeps its tuning and falls through instead
    -- of keeping the role default model.
    local p_nameless_role = resolve(nil, { temperature = 0.3 })
    assert(p_nameless_role.model == "deepseek-v4.1-flash"
      and p_nameless_role.temperature == 0.3,
      "a nameless role model table must fall through to the provider default and keep tuning")

    -- A foreign-provider role model_profile is ignored like a foreign model.
    local p_foreign_profile = WheelAgent.resolve_model(coding, {
      provider_name = "opencode-go",
      provider_default_model = "deepseek-v4.1-flash",
      config = {
        roles = {
          [coding] = { model_profile = { provider = "anthropic", model = "claude-3-7-sonnet" } },
        },
      },
    })
    assert(p_foreign_profile.model == "deepseek-v4.1-flash",
      "role model_profile from another provider must not override the active provider model")

    -- A provider-less configured role profile is accepted and uses the active
    -- provider instead of aborting agent construction.
    local p_providerless_profile = WheelAgent.resolve_model(coding, {
      provider_name = "opencode-go",
      provider_default_model = "deepseek-v4.1-flash",
      config = { roles = { [coding] = { model_profile = { model = "go-profile-custom" } } } },
    })
    assert(p_providerless_profile.model == "go-profile-custom"
      and p_providerless_profile.provider == "opencode-go",
      "a provider-less role model_profile must use the active provider")

    local p_matching_profile = WheelAgent.resolve_model(coding, {
      provider_name = "opencode-go",
      provider_default_model = "deepseek-v4.1-flash",
      config = {
        roles = {
          [coding] = { model_profile = { provider = "opencode-go", model = "go-profile-model" } },
        },
      },
    })
    assert(p_matching_profile.model == "go-profile-model",
      "role model_profile for the active provider must be kept")

    -- The effective provider model outranks the built-in role default even when
    -- the role default names the same provider family.
    local p_same_family = WheelAgent.resolve_model(coding, {
      provider_name = "anthropic",
      provider_default_model = "configured-anthropic-model",
    })
    assert(p_same_family.model == "configured-anthropic-model"
      and p_same_family.provider == "anthropic",
      "the configured provider model must win over the hardcoded role default")

    -- --model outranks a belonging role config model.
    local p_flag = resolve("flag-model", { name = "deepseek-reasoner", provider = "opencode-go" })
    assert(p_flag.model == "flag-model", "--model must outrank role configuration")

    -- Library callers without an active provider keep the role default.
    local p_library = WheelAgent.resolve_model(coding, {})
    assert(p_library.provider == "anthropic" and p_library.model == "claude-3-5-sonnet",
      "no active provider must keep the role default profile")

    -- WheelAgent.new accepts a string model (the original defect).
    local kernel = WheelKernel.new({ in_memory = true })
    local string_agent = assert(WheelAgent.new({
      name = "string-model-agent",
      role = coding,
      kernel = kernel,
      model = "cli-string-model",
      provider_name = "opencode-go",
      provider_default_model = "deepseek-v4.1-flash",
    }))
    assert(string_agent.model_profile.model == "cli-string-model",
      "WheelAgent.new must apply a string model, got " .. tostring(string_agent.model_profile.model))
    assert(string_agent.model_profile.provider == "opencode-go",
      "WheelAgent.new must record the active provider")

    local table_agent = assert(WheelAgent.new({
      name = "table-model-agent",
      role = coding,
      kernel = kernel,
      model = { name = "cli-table-model", temperature = 0.4 },
      provider_name = "opencode-go",
      provider_default_model = "deepseek-v4.1-flash",
    }))
    assert(table_agent.model_profile.model == "cli-table-model"
      and table_agent.model_profile.temperature == 0.4,
      "WheelAgent.new must keep table model support")

    -- A table model that names a provider honours that claim (D1 must not
    -- return through the documented API form).
    local foreign_table_agent = assert(WheelAgent.new({
      name = "foreign-table-model-agent",
      role = coding,
      kernel = kernel,
      model = { name = "claude-3-5-sonnet", provider = "anthropic" },
      provider_name = "opencode-go",
      provider_default_model = "go-default",
    }))
    assert(foreign_table_agent.model_profile.provider == "anthropic"
      and foreign_table_agent.model_profile.model == "claude-3-5-sonnet",
      "a table provider claim must be honoured, got "
        .. tostring(foreign_table_agent.model_profile.provider))

    local catalogue_table_agent = assert(WheelAgent.new({
      name = "catalogue-table-model-agent",
      role = coding,
      kernel = kernel,
      model = { name = "deepseek/deepseek-chat", provider = "openrouter" },
      provider_name = "opencode-go",
      provider_default_model = "go-default",
    }))
    assert(catalogue_table_agent.model_profile.provider == "openrouter"
      and catalogue_table_agent.model_profile.model == "deepseek/deepseek-chat",
      "a table provider claim must keep its catalogue provider")

    -- A nameless table model must not keep the role default (D1 table form).
    local nameless_agent = assert(WheelAgent.new({
      name = "nameless-model-agent",
      role = coding,
      kernel = kernel,
      model = { temperature = 0.3 },
      provider_name = "opencode-go",
      provider_default_model = "go-default",
    }))
    assert(nameless_agent.model_profile.model == "go-default"
      and nameless_agent.model_profile.provider == "opencode-go"
      and nameless_agent.model_profile.temperature == 0.3,
      "a nameless table model must keep tuning and fall through to the provider default, got "
        .. tostring(nameless_agent.model_profile.model))

    -- A provider-less configured role model_profile is accepted.
    local profile_agent = assert(WheelAgent.new({
      name = "providerless-profile-agent",
      role = coding,
      kernel = kernel,
      provider_name = "opencode-go",
      provider_default_model = "go-default",
      config = { roles = { [coding] = { model_profile = { model = "go-profile-custom" } } } },
    }))
    assert(profile_agent.model_profile.model == "go-profile-custom"
      and profile_agent.model_profile.provider == "opencode-go",
      "a provider-less role model_profile must not abort construction")
    print("PASS model precedence (string, provider/model, table, role, template default)")
  end

  -- 1b. Role tool lists must only name registered tools.
  do
    local registry = WheelTool.get_default_registry()
    local registered = {}
    for _, schema in ipairs(registry:list_tools()) do
      registered[schema.name] = true
    end
    for role, role_cfg in pairs(WheelConfig.DEFAULTS.roles) do
      for _, name in ipairs(role_cfg.tools or {}) do
        assert(registered[name],
          string.format("roles.%s.tools names unregistered tool '%s'", tostring(role), tostring(name)))
      end
    end

    local ok_unknown, err_unknown = WheelAgent.validate_tool_list(
      "unknown-tool-agent", WheelAgent.Role.CODING, { "read_file", "not_a_tool" },
      WheelTool.get_default_registry())
    assert(not ok_unknown and err_unknown ~= nil, "an unregistered tool name must fail validation")
    assert(tostring(err_unknown):find("E_AGENT_TOOL_UNKNOWN", 1, true)
      and tostring(err_unknown):find("not_a_tool", 1, true),
      "the tool diagnostic must be typed and name the unknown tool: " .. tostring(err_unknown))
    assert(WheelTool.get_default_registry() ~= nil
      and WheelAgent.validate_tool_list("ok-agent", WheelAgent.Role.CODING,
        { "read_file", "run_command" }, WheelTool.get_default_registry()) == true,
      "registered role tools must pass validation")

    -- The "*" wildcard is a valid role tool list.
    assert(WheelAgent.validate_tool_list("wild-agent", WheelAgent.Role.CODING, { "*" },
      WheelTool.get_default_registry()) == true, "the '*' wildcard must pass validation")
    local wild_agent = assert(WheelAgent.new({
      name = "wild-agent",
      role = WheelAgent.Role.CODING,
      kernel = WheelKernel.new({ in_memory = true }),
      config = { roles = { coding = { tools = { "*" } } } },
    }))
    assert(wild_agent.tools[1] == "*" and wild_agent:is_tool_allowed("run_command") == true,
      "a wildcard role tool list must construct and authorize a registered tool")

    -- Map-shaped and sparse lists fail closed instead of being silently empty.
    local ok_map, err_map = WheelAgent.validate_tool_list(
      "map-tools-agent", WheelAgent.Role.CODING, { read_file = true },
      WheelTool.get_default_registry())
    assert(not ok_map and tostring(err_map):find("dense array", 1, true),
      "a map-shaped tool list must be rejected: " .. tostring(err_map))
    local ok_sparse, err_sparse = WheelAgent.validate_tool_list(
      "sparse-tools-agent", WheelAgent.Role.CODING, { [1] = "read_file", [3] = "run_command" },
      WheelTool.get_default_registry())
    assert(not ok_sparse and tostring(err_sparse):find("dense array", 1, true),
      "a sparse tool list must be rejected: " .. tostring(err_sparse))

    -- The unknown-tool diagnostic is typed and bounded.
    local many_unknown = {}
    for index = 1, 40 do many_unknown[index] = "unknown_" .. tostring(index) end
    local ok_many, err_many = WheelAgent.validate_tool_list(
      "many-tools-agent", WheelAgent.Role.CODING, many_unknown, WheelTool.get_default_registry())
    assert(not ok_many, "many unknown tools must fail validation")
    assert(WheelErrors.E_AGENT_TOOL_UNKNOWN ~= nil
      and tostring(err_many):find("E_AGENT_TOOL_UNKNOWN", 1, true),
      "E_AGENT_TOOL_UNKNOWN must be part of the typed vocabulary")
    assert(#err_many <= 200, "the tool diagnostic must be bounded, got " .. tostring(#err_many))
    assert(err_many:find("(+35 more)", 1, true) ~= nil,
      "the bounded diagnostic must count the remaining tools: " .. err_many)

    -- Config-driven role tools are validated too; the CLI reports exit 2.
    local bad_cfg_root = root .. "/bad-tools"
    local bad_env = {
      HOME = bad_cfg_root,
      XDG_CONFIG_HOME = bad_cfg_root .. "/config",
      XDG_DATA_HOME = bad_cfg_root .. "/data",
      XDG_STATE_HOME = bad_cfg_root .. "/state",
      OPENCODE_GO_API_KEY = "test-key-not-a-secret",
    }
    write_text(bad_cfg_root .. "/config/wheel/init.lua",
      'return { roles = { coding = { tools = { "read_file", "no_such_tool" } } } }\n')
    local rc_bad_tools, _, err_bad_tools = run_cli({
      "run", "--thinking", "off", "--workspace", ws, "task",
    }, {
      env = bad_env,
      http_client = function() error("provider must not be constructed with invalid tools") end,
      approver = function() return { decision = "allow_once" } end,
    })
    assert(rc_bad_tools == 2, "a bad role tool list must exit 2, got " .. tostring(rc_bad_tools))
    assert(err_bad_tools:find("E_AGENT_TOOL_UNKNOWN", 1, true)
      and err_bad_tools:find("no_such_tool", 1, true),
      "wheel run must report the typed tool diagnostic: " .. err_bad_tools)
    print("PASS role tool lists validated against the registry")
  end

  -- 2. The run path sends the requested model, not the role default.
  do
    local client, state = make_run_http({ tool_turns = 0 })
    local rc, out = run_cli({
      "run", "--model", "requested-model", "--thinking", "off", "--workspace", ws, "say done",
    }, { http_client = client, approver = function() return { decision = "allow_once" } end })
    assert(rc == 0, "run with --model must succeed")
    assert(state.models[1] == "requested-model",
      "request must carry --model, got " .. tostring(state.models[1]))
    assert(out:find("final answer", 1, true), "final answer must reach stdout")

    local client_default, state_default = make_run_http({ tool_turns = 0 })
    local rc_default = run_cli({
      "run", "--thinking", "off", "--workspace", ws, "say done",
    }, { http_client = client_default, approver = function() return { decision = "allow_once" } end })
    assert(rc_default == 0, "run without --model must succeed")
    assert(state_default.models[1] == "deepseek-v4.1-flash",
      "run without --model must use the provider template default, got "
        .. tostring(state_default.models[1]))

    -- ask honours --model and keeps working without it.
    local ask_models = {}
    local ask_client = function(req)
      local decoded = WheelProvider.JSON.decode(req.body or "{}")
      table.insert(ask_models, decoded.model)
      return {
        status = 200,
        body = '{"choices":[{"message":{"content":"ask ok"},"finish_reason":"stop"}]}',
      }
    end
    assert(run_cli({ "ask", "--model", "ask-model", "--no-stream", "hi" },
      { http_client = ask_client }) == 0, "ask --model must succeed")
    assert(run_cli({ "ask", "--no-stream", "hi" }, { http_client = ask_client }) == 0,
      "ask without flags must keep working")
    assert(ask_models[1] == "ask-model" and ask_models[2] == "deepseek-v4.1-flash",
      "ask must honour --model and default to the template model")

    -- Catalogue ids stay opaque when the provider is explicit: an OpenRouter
    -- model id must never retarget the endpoint.
    local client_or, state_or = make_run_http({ tool_turns = 0 })
    local rc_or = run_cli({
      "run", "--provider", "openrouter", "--model", "deepseek/deepseek-v4.1-flash",
      "--thinking", "off", "--workspace", ws, "say done",
    }, { http_client = client_or, approver = function() return { decision = "allow_once" } end })
    assert(rc_or == 0, "explicit OpenRouter catalogue id must not be a usage error")
    assert(state_or.models[1] == "deepseek/deepseek-v4.1-flash",
      "two-segment catalogue id must stay intact, got " .. tostring(state_or.models[1]))
    assert(state_or.urls[1]:find("openrouter.ai", 1, true),
      "two-segment catalogue id must keep the OpenRouter endpoint, got " .. tostring(state_or.urls[1]))

    local client_or3, state_or3 = make_run_http({ tool_turns = 0 })
    assert(run_cli({
      "run", "--provider", "openrouter", "--model", "openrouter/deepseek/deepseek-chat",
      "--thinking", "off", "--workspace", ws, "say done",
    }, { http_client = client_or3, approver = function() return { decision = "allow_once" } end }) == 0)
    assert(state_or3.models[1] == "deepseek/deepseek-chat",
      "three-segment id must strip only the matching provider prefix, got "
        .. tostring(state_or3.models[1]))
    assert(state_or3.urls[1]:find("openrouter.ai", 1, true), "three-segment id keeps OpenRouter")

    -- Without --provider a known provider prefix is the override syntax.
    local client_ds, state_ds = make_run_http({ tool_turns = 0 })
    assert(run_cli({
      "run", "--model", "deepseek/deepseek-chat", "--thinking", "off", "--workspace", ws, "say done",
    }, { http_client = client_ds, approver = function() return { decision = "allow_once" } end }) == 0)
    assert(state_ds.models[1] == "deepseek-chat" and state_ds.urls[1]:find("api.deepseek.com", 1, true),
      "without --provider a known prefix selects that provider")

    -- The same rule holds for ask.
    local ask_urls, ask_ids = {}, {}
    local ask_split_client = function(req)
      local decoded = WheelProvider.JSON.decode(req.body or "{}")
      table.insert(ask_ids, decoded.model)
      table.insert(ask_urls, req.url)
      return {
        status = 200,
        body = '{"choices":[{"message":{"content":"ask ok"},"finish_reason":"stop"}]}',
      }
    end
    assert(run_cli({ "ask", "--provider", "openrouter", "--model", "deepseek/deepseek-chat",
      "--no-stream", "hi" }, { http_client = ask_split_client }) == 0)
    assert(run_cli({ "ask", "--model", "deepseek/deepseek-chat", "--no-stream", "hi" },
      { http_client = ask_split_client }) == 0)
    assert(ask_ids[1] == "deepseek/deepseek-chat" and ask_urls[1]:find("openrouter.ai", 1, true),
      "ask must keep a catalogue id on the explicit provider")
    assert(ask_ids[2] == "deepseek-chat" and ask_urls[2]:find("api.deepseek.com", 1, true),
      "ask without --provider must honour a known provider prefix")

    -- --stream/--no-stream are ask-only; run/chat reject them instead of
    -- silently ignoring the flag.
    local no_provider = { http_client = function() error("provider must not be contacted") end }
    assert(run_cli({ "run", "--stream", "task" }, no_provider) == 2, "run must reject --stream")
    assert(run_cli({ "run", "--no-stream", "task" }, no_provider) == 2, "run must reject --no-stream")
    assert(run_cli({ "chat", "--stream" }, no_provider) == 2, "chat must reject --stream")
    print("PASS run/ask model wiring")
  end

  -- 3. Per-subcommand help and unknown-option handling never reach the provider.
  do
    local forbidden = function()
      error("provider must not be contacted for help or usage errors")
    end
    local prov = { http_client = forbidden }

    local rc_ask, out_ask = run_cli({ "ask", "--help" }, prov)
    assert(rc_ask == 0 and out_ask:find("Usage: wheel ask", 1, true),
      "wheel ask --help must print usage and exit 0")
    local rc_run, out_run = run_cli({ "run", "-h" }, prov)
    assert(rc_run == 0 and out_run:find("Usage: wheel run", 1, true),
      "wheel run -h must print usage and exit 0")
    local rc_chat, out_chat = run_cli({ "chat", "--help" }, prov)
    assert(rc_chat == 0 and out_chat:find("Usage: wheel chat", 1, true),
      "wheel chat --help must print usage and exit 0")
    local rc_help_run, out_help_run = run_cli({ "help", "run" }, prov)
    assert(rc_help_run == 0 and out_help_run:find("Usage: wheel run", 1, true),
      "wheel help run must print run usage")
    local rc_help, out_help = run_cli({ "help" }, prov)
    assert(rc_help == 0 and out_help:find("Usage: wheel <command>", 1, true),
      "wheel help must print top-level usage")
    assert(run_cli({ "help", "bogus" }, prov) == 2, "wheel help <unknown> must exit 2")

    local rc_unknown, _, err_unknown = run_cli({ "ask", "--bogus", "hi" }, prov)
    assert(rc_unknown == 2 and err_unknown:find("unknown option", 1, true),
      "unknown options must be usage errors, not prompts")
    assert(run_cli({ "run", "--max-turns" }, prov) == 2, "--max-turns without a value must exit 2")
    assert(run_cli({ "ask", "--max-turns", "3", "hi" }, prov) == 2,
      "run-only options must be rejected by ask")
    assert(run_cli({ "run", "--approval-mode", "bogus", "task" }, prov) == 2,
      "an invalid --approval-mode must be a usage error (exit 2)")
    print("PASS subcommand help and unknown-option rejection")
  end

  -- 4. --max-turns bounds, plumbing, and the distinct exhaustion exit code.
  do
    local prov = { http_client = function() error("provider must not be contacted for usage errors") end }
    for _, bad in ipairs({ "0", "201", "-1", "abc", "1.5" }) do
      local rc, _, err = run_cli({ "run", "--max-turns", bad, "task" }, prov)
      assert(rc == 2, "--max-turns " .. bad .. " must exit 2, got " .. tostring(rc))
      assert(err:find("--max-turns", 1, true), "bounds error must name --max-turns")
    end

    -- The budget is plumbed into WheelRunner.run_task: two requests, then stop.
    local client, state = make_run_http({ always_tool = true })
    local rc_exhausted, _, err_exhausted = run_cli({
      "run", "--max-turns", "2", "--thinking", "off", "--workspace", ws, "never finish",
    }, { http_client = client, approver = function() return { decision = "allow_once" } end })
    assert(rc_exhausted == 3,
      "budget exhaustion must exit the documented code 3, got "
        .. tostring(rc_exhausted) .. ": " .. err_exhausted)
    assert(WheelErrors.E_TURN_BUDGET_EXHAUSTED == "E_TURN_BUDGET_EXHAUSTED",
      "E_TURN_BUDGET_EXHAUSTED must be part of the typed error vocabulary")
    assert(state.requests == 2, "max_turns must bound provider requests, got " .. tostring(state.requests))
    assert(err_exhausted:find("Turn budget exhausted", 1, true),
      "exhaustion message must say the budget was exhausted")
    assert(err_exhausted:find("not resumed", 1, true),
      "exhaustion message must say the run is not resumed")
    assert(err_exhausted:find("No provider or persistence error", 1, true),
      "a clean final turn must not be misreported as a provider failure")
    assert(not err_exhausted:find("not a provider or tool failure", 1, true),
      "the message must not deny a tool failure that occurred")

    -- A tool failure on the final turn must be named, not denied.
    local client_fail, state_fail = make_run_http({ always_tool = true })
    local rc_fail, _, err_fail = run_cli({
      "run", "--max-turns", "1", "--auto-deny", "--thinking", "off", "--workspace", ws,
      "never finish",
    }, { http_client = client_fail, approver = function() return { decision = "deny" } end })
    assert(rc_fail == 3, "denied final turn must still exit 3, got " .. tostring(rc_fail))
    assert(state_fail.requests == 1, "max_turns=1 must issue exactly one request")
    assert(err_fail:find("tool call(s) failed on the final turn", 1, true),
      "the exhaustion message must name final-turn tool failures: " .. err_fail)

    -- A final answer inside the budget stays success.
    local client_ok, state_ok = make_run_http({ tool_turns = 0 })
    local rc_ok = run_cli({
      "run", "--max-turns", "1", "--thinking", "off", "--workspace", ws, "finish now",
    }, { http_client = client_ok, approver = function() return { decision = "allow_once" } end })
    assert(rc_ok == 0 and state_ok.requests == 1,
      "a final answer on the last allowed turn must succeed")
    print("PASS --max-turns bounds, plumbing, and exhaustion exit code")
  end

  -- 5. --trace prints bounded, redacted tool diagnostics to stderr only.
  do
    local client, _ = make_run_http({ tool_turns = 1 })
    local rc_trace, out_trace, err_trace = run_cli({
      "run", "--trace", "--thinking", "off", "--workspace", ws, "run echo trace-ok",
    }, { http_client = client, approver = function() return { decision = "allow_once" } end })
    assert(rc_trace == 0, "traced run must succeed: " .. err_trace)
    assert(err_trace:find("[wheel trace]", 1, true), "trace must be written to stderr")
    assert(err_trace:find("tool=run_command", 1, true), "trace must name the tool")
    assert(err_trace:find("status=success", 1, true), "trace must report the outcome status")
    assert(err_trace:find("out=", 1, true) and err_trace:find("err=", 1, true),
      "trace must report byte counts")
    assert(err_trace:find("trace-ok", 1, true),
      "trace must show the first observation content line")
    assert(not err_trace:find("[Tool:", 1, true),
      "trace must not repeat the [Tool: ...] header")
    assert(not out_trace:find("[wheel trace]", 1, true), "trace must never leak into stdout")

    -- Redaction happens before the trace line is bounded.
    local client_secret, _ = make_run_http({
      tool_turns = 1,
      tool_args = '{"command":"echo Authorization: Bearer trace-secret-12345"}',
    })
    local _, _, err_secret = run_cli({
      "run", "--trace", "--thinking", "off", "--workspace", ws, "echo a secret",
    }, { http_client = client_secret, approver = function() return { decision = "allow_once" } end })
    assert(not err_secret:find("trace-secret-12345", 1, true),
      "trace must redact secret-shaped observation content: " .. err_secret)
    assert(err_secret:find("%[redacted:"), "trace must mark the redacted value")

    local client_plain, _ = make_run_http({ tool_turns = 1 })
    local rc_plain, out_plain, err_plain = run_cli({
      "run", "--thinking", "off", "--workspace", ws, "run echo trace-ok",
    }, { http_client = client_plain, approver = function() return { decision = "allow_once" } end })
    assert(rc_plain == 0, "untraced run must succeed: " .. err_plain)
    assert(not err_plain:find("[wheel trace]", 1, true), "trace must be opt-in")
    assert(not out_plain:find("[wheel trace]", 1, true), "default stdout must stay unchanged")
    assert(out_plain == out_trace, "trace must not change stdout")
    print("PASS --trace stderr output and default silence")
  end
end)

cleanup_dir(root)
if not ok_all then
  error(test_err, 0)
end
print("PASS ALL test_cli_correctness checks")
