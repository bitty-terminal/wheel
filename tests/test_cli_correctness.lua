-- tests/test_cli_correctness.lua
-- Regression suite for the Wheel CLI correctness fixes (CTX-0057 / wheel#148):
--   1. One model-precedence rule: --model > role config model that belongs to the
--      active provider > provider template default. String and table models both
--      reach WheelAgent.new.
--   2. Per-subcommand --help/-h and `help <command>` exit 0 without a provider
--      call; unknown options are usage errors, never prompt text.
--   3. --max-turns bounds and a distinct budget-exhaustion exit code/message.
--   4. --trace writes tool-call diagnostics to stderr only.
--
-- No network and no real provider: every adapter call goes through an injected
-- http_client stub.

package.path = "./lua/?.lua;./lua/?/init.lua;" .. package.path

local WheelHost = require("wheel.host")
local WheelProvider = require("wheel.provider")
local WheelAgent = require("wheel.agent")
local WheelKernel = require("wheel.kernel")
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
  }

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
    local state = { requests = 0, models = {} }
    local client = function(req)
      state.requests = state.requests + 1
      local decoded = WheelProvider.JSON.decode(req.body or "{}")
      table.insert(state.models, decoded.model)
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
      local opts = {
        model = model,
        provider_name = "opencode-go",
        provider_default_model = "deepseek-v4.1-flash",
        config = { roles = { [coding] = { model = role_model } } },
      }
      for k, v in pairs(extra or {}) do opts[k] = v end
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

    -- `provider/model` selects the provider and keeps the remaining model id.
    local p_prefixed = resolve("openrouter/deepseek/deepseek-chat")
    assert(p_prefixed.provider == "openrouter" and p_prefixed.model == "deepseek/deepseek-chat",
      "provider/model must split on the known provider prefix")

    -- Table form keeps working, including temperature.
    local p_table = resolve({ name = "table-model", provider = "opencode-go", temperature = 0.3 })
    assert(p_table.model == "table-model" and p_table.provider == "opencode-go"
      and p_table.temperature == 0.3, "table --model must keep name/provider/temperature")

    -- Role config model that belongs to the active provider outranks the default.
    local p_role = resolve(nil, { name = "deepseek-reasoner", provider = "opencode-go" })
    assert(p_role.model == "deepseek-reasoner" and p_role.provider == "opencode-go",
      "role model belonging to the active provider must win over the template default")

    -- Role config model from another provider is ignored.
    local p_foreign = resolve(nil, { name = "claude-3-5-sonnet", provider = "anthropic" })
    assert(p_foreign.model == "deepseek-v4.1-flash",
      "role model from another provider must not override the active provider model")

    -- A bare role model inherits the role's default provider family (anthropic
    -- for Coding), so it is not applied to opencode-go either.
    local p_bare = resolve(nil, "deepseek-reasoner")
    assert(p_bare.model == "deepseek-v4.1-flash" and p_bare.provider == "opencode-go",
      "bare role model without a matching provider family must fall back to the provider default")

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
    print("PASS model precedence (string, provider/model, table, role, template default)")
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
    assert(run_cli({ "run", "--provider", "opencode-go", "--model", "openai/gpt-4o", "task" }, prov) == 2,
      "a --model provider prefix conflicting with --provider must exit 2")
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
    assert(rc_exhausted == WheelCLI.EXIT_BUDGET_EXHAUSTED,
      "budget exhaustion must exit " .. tostring(WheelCLI.EXIT_BUDGET_EXHAUSTED)
        .. ", got " .. tostring(rc_exhausted) .. ": " .. err_exhausted)
    assert(state.requests == 2, "max_turns must bound provider requests, got " .. tostring(state.requests))
    assert(err_exhausted:find("Turn budget exhausted", 1, true),
      "exhaustion message must say the budget was exhausted")
    assert(err_exhausted:find("not a provider or tool failure", 1, true),
      "exhaustion message must distinguish provider/tool failure")
    assert(WheelCLI.EXIT_BUDGET_EXHAUSTED ~= 1 and WheelCLI.EXIT_BUDGET_EXHAUSTED ~= 0,
      "budget exhaustion needs a distinct exit code")

    -- A final answer inside the budget stays success.
    local client_ok, state_ok = make_run_http({ tool_turns = 0 })
    local rc_ok = run_cli({
      "run", "--max-turns", "1", "--thinking", "off", "--workspace", ws, "finish now",
    }, { http_client = client_ok, approver = function() return { decision = "allow_once" } end })
    assert(rc_ok == 0 and state_ok.requests == 1,
      "a final answer on the last allowed turn must succeed")
    print("PASS --max-turns bounds, plumbing, and exhaustion exit code")
  end

  -- 5. --trace prints tool diagnostics to stderr only.
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
    assert(not out_trace:find("[wheel trace]", 1, true), "trace must never leak into stdout")

    local client_plain, _ = make_run_http({ tool_turns = 1 })
    local _, out_plain, err_plain = run_cli({
      "run", "--thinking", "off", "--workspace", ws, "run echo trace-ok",
    }, { http_client = client_plain, approver = function() return { decision = "allow_once" } end })
    assert(not err_plain:find("[wheel trace]", 1, true), "trace must be opt-in")
    assert(not out_plain:find("[wheel trace]", 1, true), "default stdout must stay unchanged")
    print("PASS --trace stderr output and default silence")
  end
end)

cleanup_dir(root)
if not ok_all then
  error(test_err, 0)
end
print("PASS ALL test_cli_correctness checks")
