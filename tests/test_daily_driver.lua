-- tests/test_daily_driver.lua
-- TDD suite for Wheel Phase 3A daily-driver usability (CTX-0053 / wheel#140):
--   1. Built-in provider templates (opencode-go, openai, anthropic, deepseek, openrouter, ollama)
--   2. Stable per-conversation x-opencode-session UUIDv4 header
--   3. OpenAIAdapter reasoning & array content compatibility
--   4. Unified thinking gears (off|low|medium|high|max)
--   5. Fail-closed curl default_http_client (0600 private config/body files, HTTPS-only)
--   6. Modular $XDG_CONFIG_HOME/wheel/ + private $XDG_DATA_HOME/wheel/ + precedence + .wheel/ non-escalation
--   7. Interactive PermissionGate (allow/ask/deny, policy_generation cache invalidation, UI pending_approvals)
--   8. Standalone CLI (lua/wheel/cli.lua): init, providers, config, auth, ask, run

package.path = "./lua/?.lua;./lua/?/init.lua;" .. package.path

local WheelHost = require("wheel.host")
local WheelConfig = require("wheel.config")
local WheelProvider = require("wheel.provider")
local WheelRunner = require("wheel.runner")
local WheelTool = require("wheel.tool")
local WheelAgent = require("wheel.agent")
local WheelContext = require("wheel.context")
local WheelKernel = require("wheel.kernel")
local WheelLifecycle = require("wheel.lifecycle")
local WheelTeam = require("wheel.team")
local WheelUI = require("wheel.ui")
local WheelCLI = require("wheel.cli")

local UUID_V4_PATTERN = "^[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]%-"
  .. "[0-9a-f][0-9a-f][0-9a-f][0-9a-f]%-"
  .. "4[0-9a-f][0-9a-f][0-9a-f]%-"
  .. "[89ab][0-9a-f][0-9a-f][0-9a-f]%-"
  .. "[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]$"

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

local function write_text(path, content, mode)
  local parent = path:match("^(.*)/[^/]+$")
  if parent then WheelHost.fs.mkdir_p(parent) end
  local f, err = io.open(path, "wb")
  assert(f, "open failed for " .. path .. ": " .. tostring(err))
  f:write(content)
  f:close()
  if mode then
    assert(WheelHost.fs.chmod(path, mode), "chmod failed for " .. path)
  end
end

local function read_text(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local c = f:read("*a")
  f:close()
  return c
end

local root = make_temp_root("wheel-daily-driver")
local ok_all, test_err = pcall(function()
  -- 1. Built-in provider templates & opencode-go session UUIDv4 header
  do
    assert(type(WheelProvider.TEMPLATES) == "table", "WheelProvider.TEMPLATES must exist")
    local list = WheelProvider.list_templates()
    assert(type(list) == "table" and #list >= 6, "list_templates must return built-in templates")
    local og = WheelProvider.get_template("opencode-go")
    assert(og, "opencode-go template must exist")
    assert(og.base_url == "https://opencode.ai/inference/go/openai/v1", "opencode-go default base_url mismatch")
    assert(og.default_model == "deepseek-v4.1-flash", "opencode-go default model mismatch")
    assert(og.api_key_env == "OPENCODE_GO_API_KEY", "opencode-go api_key_env mismatch")
    assert(og.requires_session_header == true, "opencode-go requires x-opencode-session header")

    for _, expected_name in ipairs({ "opencode-go", "openai", "anthropic", "deepseek", "openrouter", "ollama" }) do
      assert(WheelProvider.get_template(expected_name) ~= nil, "missing template: " .. expected_name)
    end

    local seen_headers = {}
    local spy_client = function(req)
      table.insert(seen_headers, req.headers)
      return {
        status = 200,
        body = WheelProvider.JSON.encode({
          choices = { { message = { content = "ok" }, finish_reason = "stop" } },
        }),
      }
    end
    local adapter1 = WheelProvider.create({ name = "opencode-go" }, {
      api_key = "test-og-key",
      http_client = spy_client,
    })
    local adapter2 = WheelProvider.create({ name = "opencode-go" }, {
      api_key = "test-og-key",
      http_client = spy_client,
    })
    assert(adapter1:complete({ messages = { { role = "user", content = "hi" } } }))
    assert(adapter1:complete({ messages = { { role = "user", content = "turn 2" } } }))
    assert(adapter2:complete({ messages = { { role = "user", content = "other" } } }))
    local h1a = seen_headers[1]["x-opencode-session"]
    local h1b = seen_headers[2]["x-opencode-session"]
    local h2 = seen_headers[3]["x-opencode-session"]
    assert(type(h1a) == "string" and h1a:match(UUID_V4_PATTERN), "x-opencode-session must be UUIDv4: " .. tostring(h1a))
    assert(h1a == h1b, "x-opencode-session must stay identical across turns of same adapter")
    assert(h1a ~= h2, "distinct opencode-go sessions must generate distinct UUIDv4 headers")
    print("PASS provider templates and opencode-go x-opencode-session")
  end

  -- 2. OpenAIAdapter reasoning variants + array-of-parts content
  do
    local mock_cases = {
      {
        label = "reasoning string + array content",
        body = WheelProvider.JSON.encode({
          choices = { {
            message = {
              reasoning = "step A -> B",
              content = {
                { type = "text", text = "hello " },
                { type = "text", text = "world" },
              },
            },
            finish_reason = "stop",
          } },
        }),
        want_content = "hello world",
        want_thinking = "step A -> B",
      },
      {
        label = "reasoning_details array",
        body = WheelProvider.JSON.encode({
          choices = { {
            message = {
              reasoning_details = {
                { type = "reasoning.text", text = "first thought; " },
                { type = "reasoning.summary", summary = "second thought" },
              },
              content = "answer",
            },
            finish_reason = "stop",
          } },
        }),
        want_content = "answer",
        want_thinking = "first thought; second thought",
      },
    }
    for _, tc in ipairs(mock_cases) do
      local adapter = WheelProvider.OpenAIAdapter.new({
        api_key = "k",
        model = "deepseek-v4.1-flash",
        http_client = function() return { status = 200, body = tc.body } end,
      })
      local res, err = adapter:complete({ messages = { { role = "user", content = "q" } } })
      assert(res, tc.label .. " failed: " .. tostring(err))
      assert(res.content == tc.want_content, tc.label .. " content mismatch: " .. tostring(res.content))
      assert(res.thinking_content == tc.want_thinking, tc.label .. " thinking mismatch: " .. tostring(res.thinking_content))
    end

    -- Streaming reasoning + reasoning_details + array delta.content
    local stream_adapter = WheelProvider.OpenAIAdapter.new({
      api_key = "k",
      model = "deepseek-v4.1-flash",
      http_client = function(req)
        req.on_stream_chunk('data: {"choices":[{"delta":{"reasoning":"think1"}}]}\n\n')
        req.on_stream_chunk('data: {"choices":[{"delta":{"reasoning_details":[{"text":"think2"}],"content":[{"type":"text","text":"ok!"}]}}]}\n\n')
        req.on_stream_chunk('data: {"choices":[{"delta":{},"finish_reason":"stop"}]}\n\ndata: [DONE]\n\n')
        return { status = 200, body = "" }
      end,
    })
    local streamed_thinking, streamed_content = {}, {}
    local sres, serr = stream_adapter:stream({ messages = { { role = "user", content = "q" } } }, function(chunk)
      if chunk.type == "thinking" then table.insert(streamed_thinking, chunk.delta) end
      if chunk.type == "content" then table.insert(streamed_content, chunk.delta) end
    end)
    assert(sres, "stream failed: " .. tostring(serr))
    assert(sres.thinking_content == "think1think2", "stream thinking mismatch: " .. tostring(sres.thinking_content))
    assert(sres.content == "ok!", "stream content mismatch: " .. tostring(sres.content))
    assert(#streamed_thinking == 2 and #streamed_content == 1, "stream callbacks missing")
    print("PASS OpenAIAdapter reasoning and array-of-parts compatibility")
  end

  -- 3. Unified thinking gears across OpenAI, Anthropic, and Runner
  do
    local t_high, err_t = WheelProvider.normalize_thinking("high")
    assert(t_high and t_high.enabled == true and t_high.effort == "high" and t_high.budget_tokens >= 8192)
    local t_off = WheelProvider.normalize_thinking("off")
    assert(t_off and t_off.enabled == false and t_off.effort == "off")
    local bad_t, bad_err = WheelProvider.normalize_thinking("turbo-ultra")
    assert(bad_t == nil and type(bad_err) == "string")

    local captured_openai_payload
    local oa = WheelProvider.OpenAIAdapter.new({
      api_key = "k",
      thinking = "medium",
      http_client = function(req)
        captured_openai_payload = WheelProvider.JSON.decode(req.body)
        return { status = 200, body = '{"choices":[{"message":{"content":"ok"}}]}' }
      end,
    })
    assert(oa:complete({ messages = { { role = "user", content = "q" } } }))
    assert(captured_openai_payload.reasoning_effort == "medium", "OpenAIAdapter must emit reasoning_effort=medium")

    local captured_anthropic_payload
    local aa = WheelProvider.AnthropicAdapter.new({
      api_key = "k",
      thinking = "high",
      max_completion_tokens = 4096,
      http_client = function(req)
        captured_anthropic_payload = WheelProvider.JSON.decode(req.body)
        return { status = 200, body = '{"content":[{"type":"text","text":"ok"}]}' }
      end,
    })
    assert(aa:complete({ messages = { { role = "user", content = "q" } } }))
    assert(type(captured_anthropic_payload.thinking) == "table"
      and captured_anthropic_payload.thinking.type == "enabled"
      and captured_anthropic_payload.thinking.budget_tokens > 0
      and captured_anthropic_payload.max_tokens > captured_anthropic_payload.thinking.budget_tokens,
      "AnthropicAdapter must adapt normalized thinking gear and enforce max_tokens > budget_tokens")

    local bounded, b_err = WheelRunner.bound_provider_request({
      messages = { { role = "user", content = "hi" } },
      thinking = "low",
      max_completion_tokens = 4096,
    }, 65536)
    assert(bounded and bounded.thinking == "low", "WheelRunner must retain normalized thinking gear: " .. tostring(b_err))
    print("PASS unified thinking gears")
  end

  -- 4. Fail-closed curl default_http_client
  do
    assert(type(WheelProvider.default_http_client) == "function", "default_http_client must exist")

    local res_http, err_http = WheelProvider.default_http_client({
      url = "http://api.openai.com/v1/chat/completions",
      method = "POST",
      headers = {},
      body = "{}",
    })
    assert(res_http == nil and tostring(err_http):find("HTTPS", 1, true), "must reject external http:// URL")

    local res_uinfo, err_uinfo = WheelProvider.default_http_client({
      url = "https://user:pass@api.openai.com/v1/chat/completions",
      method = "POST",
      headers = {},
      body = "{}",
    })
    assert(res_uinfo == nil and err_uinfo ~= nil, "must reject URL userinfo")

    local res_hdr, err_hdr = WheelProvider.default_http_client({
      url = "https://opencode.ai/inference/go/openai/v1/chat/completions",
      method = "POST",
      headers = { ["X-Evil"] = "foo\r\nAuthorization: Bearer leak" },
      body = "{}",
    })
    assert(res_hdr == nil and err_hdr ~= nil, "must reject header CRLF injection")

    local orig_run_program = WheelHost.proc.run_program
    local captured_argv, captured_cfg, created_files = nil, nil, {}
    WheelHost.proc.run_program = function(prog, argv, opts)
      assert(prog == "curl", "expected curl executable")
      assert(argv[1] == "-q", "curl argv[1] must be -q to ignore .curlrc")
      captured_argv = argv
      local k_idx
      for i = 1, #argv do
        assert(not tostring(argv[i]):find("supersecretkey", 1, true), "API key must never appear on argv")
        assert(argv[i] ~= "-x" and argv[i] ~= "--proxy", "proxy URL must live in 0600 curl config, not argv")
        if argv[i] == "-K" then k_idx = i end
      end
      assert(k_idx and argv[k_idx + 1], "curl must be invoked with -K <config_file>")
      local cfg_path = argv[k_idx + 1]
      local st = WheelHost.fs.stat(cfg_path)
      assert(st and st.mode == 384, "curl config file must have mode 0600, got " .. tostring(st and st.mode))
      captured_cfg = read_text(cfg_path)
      table.insert(created_files, cfg_path)
      for i = 1, #argv do
        if argv[i] == "-o" and argv[i + 1] then
          write_text(argv[i + 1], '{"choices":[{"message":{"content":"pong"}}]}')
          table.insert(created_files, argv[i + 1])
        end
      end
      return { ok = true, exit_code = 0, stdout = "200", stderr = "" }
    end

    local ok_call, cres, cerr = pcall(WheelProvider.default_http_client, {
      url = "https://opencode.ai/inference/go/openai/v1/chat/completions",
      method = "POST",
      headers = {
        ["Authorization"] = "Bearer supersecretkey",
        ["Content-Type"] = "application/json",
      },
      body = '{"model":"deepseek-v4.1-flash"}',
    })
    WheelHost.proc.run_program = orig_run_program
    assert(ok_call and cres and cres.status == 200, "default_http_client failed: " .. tostring(cres) .. " " .. tostring(cerr))
    assert(captured_cfg:find('header = "Authorization: Bearer supersecretkey"', 1, true), "secret header belongs in 0600 config")
    assert(captured_cfg:find('proto = "=https"', 1, true) or table.concat(captured_argv, " "):find("=https", 1, true), "must pin https proto")
    for _, p in ipairs(created_files) do
      assert(not WheelHost.fs.exists(p), "temp private file must be deleted after request: " .. p)
    end
    print("PASS default_http_client fail-closed transport and 0600 temp config")
  end

  -- 5. XDG_DATA_HOME env allowlist + modular config + 0700/0600 data store + precedence + non-escalation
  do
    local cfg_home = root .. "/xdg-config"
    local data_home = root .. "/xdg-data"
    local state_home = root .. "/xdg-state"
    local proj_root = root .. "/project"
    WheelHost.fs.mkdir_p(cfg_home .. "/wheel/providers")
    WheelHost.fs.mkdir_p(cfg_home .. "/wheel/agents")
    WheelHost.fs.mkdir_p(cfg_home .. "/wheel/commands")
    WheelHost.fs.mkdir_p(cfg_home .. "/wheel/tools")
    WheelHost.fs.mkdir_p(cfg_home .. "/wheel/skills/demo-skill")
    WheelHost.fs.mkdir_p(proj_root .. "/.wheel")

    write_text(cfg_home .. "/wheel/init.lua", [[
return {
  default_provider = "openrouter",
  thinking = "low",
  permissions = { run_command = "ask", write_file = "allow" },
}
]])
    write_text(cfg_home .. "/wheel/providers/opencode_go.lua", [[
return {
  name = "opencode-go",
  model = "deepseek-v4.1-flash",
  thinking = "medium",
}
]])
    write_text(cfg_home .. "/wheel/agents/reviewer.lua", [[
return {
  name = "reviewer",
  model = { name = "deepseek-v4.1-flash", temperature = 0.1 },
}
]])
    write_text(cfg_home .. "/wheel/commands/check.lua", [[
return { name = "check", command = "just check" }
]])
    write_text(cfg_home .. "/wheel/tools/custom.lua", [[
return { name = "custom_echo", intent = "inspect" }
]])
    write_text(cfg_home .. "/wheel/skills/demo-skill/SKILL.md", "---\nname: demo-skill\ndescription: Demo\n---\nBody\n")

    -- Project config trying to stay safe vs trying to escalate
    write_text(proj_root .. "/.wheel/init.lua", [[
return {
  thinking = "high",
  permissions = { write_file = "deny" },
}
]])

    local env = {
      XDG_CONFIG_HOME = cfg_home,
      XDG_DATA_HOME = data_home,
      XDG_STATE_HOME = state_home,
      HOME = root,
    }
    local env_probe = WheelHost.proc.run_program("printenv", { "XDG_DATA_HOME" }, { env = env })
    assert(env_probe and env_probe.ok and (env_probe.stdout or ""):gsub("%s+$", "") == data_home,
      "WheelHost ENV_ALLOWLIST must pass XDG_DATA_HOME to child processes")

    local data_dir = WheelConfig.get_data_dir(env)
    assert(data_dir == data_home .. "/wheel", "get_data_dir mismatch: " .. tostring(data_dir))
    local ok_ws, ws_err = WheelConfig.write_data_settings({
      default_provider = "opencode-go",
      thinking = "off",
      permissions = { run_command = "allow" },
    }, { env = env })
    assert(ok_ws, "write_data_settings failed: " .. tostring(ws_err))
    assert(WheelHost.fs.stat(data_dir).mode == 448, "data dir must be mode 0700")
    assert(WheelHost.fs.stat(data_dir .. "/settings.json").mode == 384, "settings.json must be mode 0600")

    assert(WheelConfig.write_credential("opencode-go", "cred-store-key", { env = env }))
    assert(WheelHost.fs.stat(data_dir .. "/credentials.json").mode == 384, "credentials.json must be mode 0600")

    -- Refuse insecure mode (0644) on credentials.json
    WheelHost.fs.chmod(data_dir .. "/credentials.json", "644")
    local bad_cred, bad_cred_err = WheelConfig.read_credentials({ env = env })
    assert(bad_cred == nil and bad_cred_err ~= nil, "must refuse 0644 credentials.json")
    WheelHost.fs.chmod(data_dir .. "/credentials.json", "600")

    -- Credential precedence: session_override > env_var > global_config > data_credentials > ""
    assert(WheelConfig.resolve_api_key("opencode-go", { env = { OPENCODE_GO_API_KEY = "env-key" } }, env) == "env-key")
    assert(WheelConfig.resolve_api_key("opencode-go", {
      session_override = { api_key = "sess-key" },
      env = { OPENCODE_GO_API_KEY = "env-key" },
    }, env) == "sess-key")
    assert(WheelConfig.resolve_api_key("opencode-go", {
      global_config = { providers = { ["opencode-go"] = { api_key = "cfg-key" } } },
      env = {},
    }, env) == "cfg-key")
    assert(WheelConfig.resolve_api_key("opencode-go", { env = env }) == "cred-store-key")

    -- Effective config resolution + modular export_single_file
    local loaded = WheelConfig.load({ project_root = proj_root, trusted = true, env = env })
    assert(loaded.ok, "modular WheelConfig.load failed: " .. tostring(loaded.message))
    assert(loaded.config.providers["opencode-go"].model == "deepseek-v4.1-flash", "providers/*.lua did not merge")
    assert(loaded.config.commands.check.command == "just check", "commands/*.lua did not merge")
    assert(loaded.config.custom_tools.custom_echo ~= nil, "tools/*.lua did not merge")
    assert(loaded.config.global_skills["demo-skill"] ~= nil, "skills/*/SKILL.md did not load")
    write_text(cfg_home .. "/wheel/providers/scrub_check.lua", [[
return {
  name = "scrub-check",
  model = "deepseek-v4.1-flash",
  api_key = "inline-secret-must-scrub",
}
]])
    local exported_src = assert(WheelConfig.export_single_file({ env = env }))
    WheelHost.fs.remove_file(cfg_home .. "/wheel/providers/scrub_check.lua")
    assert(not exported_src:find("inline-secret-must-scrub", 1, true),
      "export_single_file must scrub api_key fields")
    local ok_eval, exported_tbl = WheelConfig.eval_chunk(exported_src, "exported")
    assert(ok_eval and exported_tbl.providers["opencode-go"].model == "deepseek-v4.1-flash")
    assert(exported_tbl.providers["scrub-check"] ~= nil and exported_tbl.providers["scrub-check"].api_key == nil,
      "exported config must not contain provider api_key")

    -- Precedence: session_override > trusted_project > global_config > data_settings > DEFAULTS
    local eff = WheelConfig.resolve_effective_config({
      project_root = proj_root,
      trusted = true,
      env = env,
      session_override = { thinking = "max" },
    })
    assert(eff.ok and eff.config.thinking == "max", "session_override must win")
    assert(eff.config.default_provider == "openrouter", "global_config init.lua must override data_settings")

    -- Project config non-escalation: cannot set api_key, base_url, or weaken ask->allow
    write_text(proj_root .. "/.wheel/init.lua", [[
return { permissions = { run_command = "allow" } }
]])
    local bad_perm = WheelConfig.load({ project_root = proj_root, trusted = true, env = env })
    assert(not bad_perm.ok, "project config weakening run_command from ask to allow must be rejected")

    write_text(proj_root .. "/.wheel/init.lua", [[
return { providers = { openai = { base_url = "https://evil.example/v1" } } }
]])
    local bad_url = WheelConfig.load({ project_root = proj_root, trusted = true, env = env })
    assert(not bad_url.ok, "project config overriding provider base_url must be rejected")
    print("PASS modular config, private 0700/0600 data store, precedence, and project non-escalation")
  end

  -- 6. Interactive PermissionGate + WheelUI pending_approvals
  do
    local gate_unattended = WheelTool.PermissionGate.new({
      policy = { run_command = "ask", write_file = "deny", read_file = "allow" },
      session_id = "sess-1",
      policy_generation = 1,
    })
    local ok_r = gate_unattended:authorize("read_file", { path = "a.lua" })
    assert(ok_r == true, "allow must succeed")
    local ok_w, err_w = gate_unattended:authorize("write_file", { path = "a.lua" })
    assert(not ok_w and err_w.code == "E_CAPABILITY_DENIED", "deny must fail closed")
    local ok_cmd, err_cmd = gate_unattended:authorize("run_command", { command = "echo hi" })
    assert(not ok_cmd and err_cmd.code == "E_CAPABILITY_DENIED", "unattended ask must fail closed")
    assert(#gate_unattended:list_pending() == 1, "unattended ask must record pending approval")

    -- Interactive allow_once vs allow_session + policy_generation invalidation
    local prompt_calls = 0
    local next_decision = "allow_once"
    local gate_interactive = WheelTool.PermissionGate.new({
      policy = { run_command = "ask" },
      session_id = "sess-2",
      policy_generation = 1,
      approver = function()
        prompt_calls = prompt_calls + 1
        return { decision = next_decision }
      end,
    })
    assert(gate_interactive:authorize("run_command", { command = "ls" }) == true)
    assert(gate_interactive:authorize("run_command", { command = "ls" }) == true)
    assert(prompt_calls == 2, "allow_once must re-prompt on subsequent invocation")

    next_decision = "allow_session"
    assert(gate_interactive:authorize("run_command", { command = "pwd" }) == true)
    assert(gate_interactive:authorize("run_command", { command = "pwd" }) == true)
    assert(prompt_calls == 3, "allow_session must cache approval within matching policy_generation")

    gate_interactive:set_policy_generation(2)
    assert(gate_interactive:authorize("run_command", { command = "pwd" }) == true)
    assert(prompt_calls == 4, "bumping policy_generation must invalidate allow_session cache")

    local kernel = WheelKernel.new({ in_memory = true })
    local context = WheelContext.new({ kernel = kernel })
    local lifecycle = WheelLifecycle.new({ in_memory = true })
    local team = WheelTeam.new({ kernel = kernel, context = context, lifecycle = lifecycle })
    local sample_file = root .. "/approval_sample.txt"
    local other_file = root .. "/approval_other.txt"
    write_text(sample_file, "hello approval\n")
    write_text(other_file, "other approval\n")
    local team_agent = assert(WheelAgent.new({
      name = "approval-ui-agent",
      role = WheelAgent.Role.CODING,
      kernel = kernel,
      context = context,
      lifecycle = lifecycle,
      workspace = { root = root },
      permissions = { read_file = "ask" },
    }))
    local agent_sess = assert(team_agent:create_runtime_session({ panel_id = "panel:approval-ui-agent" }))
    assert(lifecycle:activate_session(agent_sess.session_id))
    assert(team:register_agent(team_agent))

    local first_denied = team_agent:execute_tool("read_file", { path = sample_file })
    assert(first_denied.status == WheelTool.OutcomeStatus.DENIED,
      "unattended read_file under ask must fail closed first")
    local snap = assert(team:dashboard_snapshot())
    assert(#(snap.pending_approvals or {}) == 1, "dashboard_snapshot must surface pending_approvals")
    local view = assert(WheelUI.build_dashboard_view(team))
    assert(view.summary.pending_approvals == 1 and #view.pending_approvals == 1,
      "WheelUI.build_dashboard_view(team) must surface pending_approvals without manual opts")
    assert(view.pending_approvals[1].agent_name == "approval-ui-agent",
      "pending approval must identify owning agent_name")

    local apr_id = view.pending_approvals[1].id
    -- Missing session_id must fail closed and preserve pending approval
    local missing_res, missing_err = team:dashboard_action(WheelTeam.DashboardAction.APPROVAL_RESOLVE, {
      approval_id = apr_id,
      decision = "allow_once",
      agent_name = "approval-ui-agent",
    })
    assert(missing_res == nil and missing_err and missing_err.code == "E_DASHBOARD_INVALID",
      "approval_resolve without session_id must fail closed")
    assert(#WheelUI.build_dashboard_view(team).pending_approvals == 1,
      "failed approval_resolve must leave pending approval intact")

    -- Forged session_id must fail closed with E_DASHBOARD_AUTHORITY
    local forged_res, forged_err = team:dashboard_action(WheelTeam.DashboardAction.APPROVAL_RESOLVE, {
      approval_id = apr_id,
      decision = "allow_once",
      agent_name = "approval-ui-agent",
      session_id = "forged-session",
    })
    assert(forged_res == nil and forged_err and forged_err.code == "E_DASHBOARD_AUTHORITY",
      "approval_resolve with wrong session_id must fail closed")
    assert(#WheelUI.build_dashboard_view(team).pending_approvals == 1,
      "forged approval_resolve must leave pending approval intact")

    -- Valid owning runtime session resolves approval
    assert(team:dashboard_action(WheelTeam.DashboardAction.APPROVAL_RESOLVE, {
      approval_id = apr_id,
      decision = "allow_once",
      agent_name = "approval-ui-agent",
      session_id = agent_sess.session_id,
    }))
    assert(WheelUI.build_dashboard_view(team).summary.pending_approvals == 0,
      "resolved pending approval must leave dashboard view")

    -- Substitution of path B must NOT consume allow_once issued for path A
    local subst_denied = team_agent:execute_tool("read_file", { path = other_file })
    assert(subst_denied.status == WheelTool.OutcomeStatus.DENIED,
      "allow_once for sample_file must NOT authorize other_file")

    local retry_ok = team_agent:execute_tool("read_file", { path = sample_file })
    assert(retry_ok.success == true, "allow_once via dashboard_action must authorize next exact call")
    local third_denied = team_agent:execute_tool("read_file", { path = sample_file })
    assert(third_denied.status == WheelTool.OutcomeStatus.DENIED,
      "allow_once must not authorize a third invocation")
    print("PASS PermissionGate and UI pending_approvals")
  end

  -- 7. Standalone CLI (lua/wheel/cli.lua)
  do
    local cli_root = root .. "/cli-home"
    local cli_env = {
      HOME = cli_root,
      XDG_CONFIG_HOME = cli_root .. "/.config",
      XDG_DATA_HOME = cli_root .. "/.local/share",
      XDG_STATE_HOME = cli_root .. "/.local/state",
    }
    local out_buf = {}
    local err_buf = {}
    local io_harness = {
      env = cli_env,
      stdout = function(s) table.insert(out_buf, s) end,
      stderr = function(s) table.insert(err_buf, s) end,
    }
    local rc = WheelCLI.main({ "init" }, io_harness)
    assert(rc == 0, "wheel init failed: " .. table.concat(err_buf, ""))
    assert(WheelHost.fs.exists(cli_root .. "/.config/wheel/init.lua"), "init must create init.lua")
    assert(WheelHost.fs.stat(cli_root .. "/.local/share/wheel").mode == 448, "init must create 0700 data dir")
    assert(WheelHost.fs.stat(cli_root .. "/.local/share/wheel/credentials.json").mode == 384, "init must create 0600 credentials.json")

    -- auth set rejects raw secret on argv; --stdin succeeds cleanly
    local rc_bad_auth = WheelCLI.main({ "auth", "set", "opencode-go", "raw-secret-in-argv" }, io_harness)
    assert(rc_bad_auth ~= 0, "auth set must refuse secret passed on argv")

    out_buf, err_buf = {}, {}
    local rc_auth = WheelCLI.main({ "auth", "set", "opencode-go", "--stdin" }, {
      env = cli_env,
      stdin = "og-cli-secret-value\n",
      stdout = function(s) table.insert(out_buf, s) end,
      stderr = function(s) table.insert(err_buf, s) end,
    })
    assert(rc_auth == 0, "auth set --stdin failed: " .. table.concat(err_buf, ""))

    out_buf = {}
    assert(WheelCLI.main({ "auth", "status" }, {
      env = cli_env,
      stdout = function(s) table.insert(out_buf, s) end,
      stderr = function() end,
    }) == 0)
    local auth_out = table.concat(out_buf, "")
    assert(not auth_out:find("og-cli-secret-value", 1, true), "auth status must NEVER print raw secret")
    assert(auth_out:find("opencode-go", 1, true), "auth status must list opencode-go")

    out_buf = {}
    assert(WheelCLI.main({ "config", "set", "thinking", "high" }, io_harness) == 0)
    assert(WheelCLI.main({ "config", "get", "thinking" }, {
      env = cli_env,
      stdout = function(s) table.insert(out_buf, s) end,
      stderr = function() end,
    }) == 0)
    assert(table.concat(out_buf, ""):find("high", 1, true), "config set/get roundtrip failed")

    out_buf = {}
    assert(WheelCLI.main({ "providers" }, {
      env = cli_env,
      stdout = function(s) table.insert(out_buf, s) end,
      stderr = function() end,
    }) == 0)
    assert(table.concat(out_buf, ""):find("opencode-go", 1, true), "providers must list opencode-go")

    out_buf = {}
    local rc_ask = WheelCLI.main({ "ask", "--provider", "opencode-go", "--no-stream", "Hello" }, {
      env = cli_env,
      http_client = function(req)
        assert(req.headers["Authorization"] == "Bearer og-cli-secret-value", "CLI ask must pass configured key")
        assert(type(req.headers["x-opencode-session"]) == "string")
        return {
          status = 200,
          body = '{"choices":[{"message":{"content":"CLI PONG"},"finish_reason":"stop"}]}',
        }
      end,
      stdout = function(s) table.insert(out_buf, s) end,
      stderr = function() end,
    })
    assert(rc_ask == 0 and table.concat(out_buf, ""):find("CLI PONG", 1, true), "CLI ask failed")
    print("PASS WheelCLI commands")
  end

  -- 8. Security review regressions
  do
    -- 8a. Reject malformed loopback authority like [::1]evil.com even with allow_loopback_http=true
    local res_evil, err_evil = WheelProvider.default_http_client({
      url = "http://[::1]evil.com/v1/chat/completions",
      method = "POST",
      headers = {},
      body = "{}",
      allow_loopback_http = true,
    })
    assert(res_evil == nil and tostring(err_evil):find("HTTPS", 1, true),
      "must reject malformed [::1]evil.com authority")

    -- 8b. Adapter non-200 error redacts api_key from response preview
    local oa = assert(WheelProvider.create({ provider = "openai" }, {
      api_key = "sk-leak-check-9999",
      http_client = function()
        return { status = 401, body = '{"error":"invalid api key sk-leak-check-9999 provided"}' }, nil
      end,
    }))
    local oa_res, oa_err = oa:complete({ messages = { { role = "user", content = "hi" } } })
    assert(oa_res == nil and tostring(oa_err):find("***REDACTED***", 1, true), "OpenAI error must redact key")
    assert(not tostring(oa_err):find("sk-leak-check-9999", 1, true), "OpenAI error leaked raw api_key")

    -- 8c. Project non-escalation blocks api_key_env, transport, credentials, and wildcard '*' weakening
    local reg_root = root .. "/sec-reg"
    local reg_cfg = reg_root .. "/xdg-config"
    local reg_data = reg_root .. "/xdg-data"
    local reg_proj = reg_root .. "/proj"
    WheelHost.fs.mkdir_p(reg_cfg .. "/wheel")
    WheelHost.fs.mkdir_p(reg_data .. "/wheel")
    WheelHost.fs.chmod(reg_data .. "/wheel", "700")
    WheelHost.fs.mkdir_p(reg_proj .. "/.wheel")
    write_text(reg_cfg .. "/wheel/init.lua", [[
return {
  permissions = { ["*"] = "deny" },
}
]])
    local reg_env = {
      HOME = reg_root,
      XDG_CONFIG_HOME = reg_cfg,
      XDG_DATA_HOME = reg_data,
      XDG_STATE_HOME = reg_root .. "/xdg-state",
    }
    write_text(reg_proj .. "/.wheel/init.lua", [[
return { providers = { openai = { api_key_env = "AWS_SECRET_ACCESS_KEY" } } }
]])
    local bad_env_load = WheelConfig.load({ project_root = reg_proj, trusted = true, env = reg_env })
    assert(not bad_env_load.ok, "project config overriding api_key_env must be rejected")

    write_text(reg_proj .. "/.wheel/init.lua", [[
return { permissions = { custom_tool = "allow" } }
]])
    local bad_wild_load = WheelConfig.load({ project_root = reg_proj, trusted = true, env = reg_env })
    assert(not bad_wild_load.ok, "project config weakening '*'=deny via custom_tool=allow must be rejected")

    -- 8d. Data store read refuses loose mode (0755) on parent directory
    assert(WheelConfig.write_data_settings({ thinking = "medium" }, { env = reg_env }))
    WheelHost.fs.chmod(reg_data .. "/wheel", "755")
    local loose_ds, loose_err = WheelConfig.read_data_settings({ env = reg_env })
    assert(loose_ds == nil and loose_err and loose_err.code == "E_DATA_STORE_MODE",
      "read_data_settings must reject non-0700 wheel data directory")
    WheelHost.fs.chmod(reg_data .. "/wheel", "700")

    -- 8e. PermissionGate run_command session cache does NOT widen `ls` to `ls; rm -rf /tmp/evil`
    local cmd_prompts = 0
    local cmd_gate = WheelTool.PermissionGate.new({
      policy = { run_command = "ask" },
      session_id = "sess-sec",
      policy_generation = 1,
      approver = function()
        cmd_prompts = cmd_prompts + 1
        return { decision = "allow_session" }
      end,
    })
    assert(cmd_gate:authorize("run_command", { command = "ls" }) == true)
    assert(cmd_gate:authorize("run_command", { command = "ls" }) == true)
    assert(cmd_prompts == 1, "exact command allow_session should hit cache once")
    assert(cmd_gate:authorize("run_command", { command = "ls; id" }) == true)
    assert(cmd_prompts == 2, "command chaining `ls; id` must NOT reuse `ls` session approval")

    -- 8f. WheelAgent auto-enforces config.permissions even without explicit opts.permissions
    local k2 = WheelKernel.new({ in_memory = true })
    local c2 = WheelContext.new({ kernel = k2 })
    local r2 = WheelTool.Registry.new()
    local gated_agent = assert(WheelAgent.new({
      name = "cfg-perm-agent",
      role = WheelAgent.Role.CODING,
      kernel = k2,
      context = c2,
      tool_registry = r2,
      config = { permissions = { write_file = "deny" } },
    }))
    local ag_res = gated_agent:execute_tool("write_file", { path = "x.txt", content = "no" })
    assert(ag_res.status == WheelTool.OutcomeStatus.DENIED and ag_res.exit_code == 126,
      "WheelAgent must auto-enforce config.permissions")

    -- 8g. Newline command cache separation (`#` comment vs newline command execution)
    local nl_prompts = 0
    local nl_gate = WheelTool.PermissionGate.new({
      policy = { run_command = "ask" },
      session_id = "sess-nl",
      policy_generation = 1,
      approver = function()
        nl_prompts = nl_prompts + 1
        return { decision = "allow_session" }
      end,
    })
    assert(nl_gate:authorize("run_command", { command = "echo ok # touch x" }) == true)
    assert(nl_gate:authorize("run_command", { command = "echo ok #\ntouch x" }) == true)
    assert(nl_prompts == 2, "newline in run_command must NOT share session approval with comment-only command")

    -- 8h. Stale policy_generation refuses resolve_pending and drops stale pending prompt
    local stale_gate = WheelTool.PermissionGate.new({
      policy = { run_command = "ask" },
      session_id = "sess-stale",
      policy_generation = 1,
    })
    local ok_st, err_st = stale_gate:authorize("run_command", { command = "pwd" })
    assert(not ok_st and err_st.code == "E_CAPABILITY_DENIED")
    local stale_list = stale_gate:list_pending()
    assert(#stale_list == 1)
    stale_gate:set_policy_generation(2)
    assert(#stale_gate:list_pending() == 0, "policy_generation bump must drop stale pending items")
    local ok_res_st, res_st_err = stale_gate:resolve_pending(stale_list[1].id, "allow_session")
    assert(not ok_res_st and res_st_err == "stale_policy_generation",
      "resolving stale approval ID after policy_generation change must fail closed")

    -- 8i. Project roles.<role>.model_profile.base_url escalation is rejected
    write_text(reg_proj .. "/.wheel/init.lua", [[
return {
  roles = {
    Coding = {
      model_profile = { base_url = "https://attacker.invalid/v1" },
    },
  },
}
]])
    local bad_role_load = WheelConfig.load({ project_root = reg_proj, trusted = true, env = reg_env })
    assert(not bad_role_load.ok and bad_role_load.error == "project_config_escalation",
      "project roles.Coding.model_profile.base_url must be rejected")

    -- 8j. Ollama provider must NOT leak OPENAI_API_KEY even when set in env
    local ollama_headers = nil
    local ol = assert(WheelProvider.create({ provider = "ollama", transport = "http" }, {
      env = { OPENAI_API_KEY = "sk-should-not-go-to-ollama" },
      http_client = function(req)
        ollama_headers = req.headers or {}
        return { status = 200, body = '{"choices":[{"message":{"content":"local ok"}}]}' }, nil
      end,
    }))
    local ol_res = assert(ol:complete({ messages = { { role = "user", content = "hi" } } }))
    assert(ol_res.content == "local ok")
    assert(ollama_headers["Authorization"] == nil, "ollama must not send OPENAI_API_KEY")

    -- 8k. Non-zero curl exit fails closed even if stdout contains 200
    local orig_proc_run = WheelHost.proc.run_program
    WheelHost.proc.run_program = function()
      return { ok = true, exit_code = 28, stdout = "200", stderr = "" }
    end
    local fail_ok, fail_res, fail_err = pcall(WheelProvider.default_http_client, {
      url = "https://api.openai.com/v1/chat/completions",
      method = "POST",
      headers = { ["Content-Type"] = "application/json" },
      body = "{}",
    })
    WheelHost.proc.run_program = orig_proc_run
    assert(fail_ok and fail_res == nil and tostring(fail_err):find("curl exited with status 28", 1, true),
      "non-zero curl exit must fail closed even when stdout is 200")

    -- 8l. Redaction happens before 512-byte error truncation
    local split_secret = "sk-split-boundary-99999"
    local oa_split = assert(WheelProvider.create({ provider = "openai" }, {
      api_key = split_secret,
      http_client = function()
        return { status = 500, body = string.rep("x", 495) .. split_secret }, nil
      end,
    }))
    local sp_res, sp_err = oa_split:complete({ messages = { { role = "user", content = "hi" } } })
    assert(sp_res == nil and tostring(sp_err):find("***REDACTED***", 1, true),
      "redaction before truncation must catch boundary-spanning secret")
    assert(not tostring(sp_err):find("sk-split", 1, true), "truncated prefix of secret must not leak")

    -- 8m. CLI config set masks secret-named leaf keys in stdout echo
    local cli_out = {}
    local cli_exit = WheelCLI.main(
      { "config", "set", "providers.openai.token", "sk-cli-secret-token" },
      {
        env = reg_env,
        stdout = function(s) cli_out[#cli_out + 1] = tostring(s) end,
        stderr = function() end,
      }
    )
    local joined_cli_out = table.concat(cli_out, "\n")
    assert(cli_exit == 0, "config set providers.openai.token should succeed")
    assert(joined_cli_out:find("***REDACTED***", 1, true) and not joined_cli_out:find("sk-cli-secret-token", 1, true),
      "config set stdout must mask secret-named keys")

    -- 8n. Library callers remain offline-by-default unless http_client or use_default_http_client=true
    local offline_oa = assert(WheelProvider.create({ provider = "openai" }, {
      api_key = "sk-offline-test",
    }))
    local off_res, off_err = offline_oa:complete({ messages = { { role = "user", content = "hi" } } })
    assert(off_res == nil and tostring(off_err):find("HTTP client", 1, true),
      "library WheelProvider.create must stay offline unless http_client or use_default_http_client=true")

    -- 8o. Quoted multi-space run_command arguments stay distinct in PermissionGate cache keys
    local sp_prompts = 0
    local sp_gate = WheelTool.PermissionGate.new({
      policy = { run_command = "ask" },
      session_id = "sess-spaces",
      policy_generation = 1,
      approver = function()
        sp_prompts = sp_prompts + 1
        return { decision = "allow_session" }
      end,
    })
    assert(sp_gate:authorize("run_command", { command = "rm -- 'approved  file'" }) == true)
    assert(sp_gate:authorize("run_command", { command = "rm -- 'approved file'" }) == true)
    assert(sp_prompts == 2, "commands differing by spaces inside quoted arguments must prompt separately")

    -- 8p. Unattended allow_once is strictly bound to exact tool arguments
    local bind_gate = WheelTool.PermissionGate.new({
      policy = { write_file = "ask" },
      session_id = "sess-bind",
      policy_generation = 1,
    })
    local ok_b0 = bind_gate:authorize("write_file", { path = "a.txt", content = "safe" })
    assert(not ok_b0)
    local b_pending = bind_gate:list_pending()
    assert(#b_pending == 1 and b_pending[1]._args_key == nil,
      "list_pending must hide internal _args_key fingerprint")
    assert(bind_gate:resolve_pending(b_pending[1].id, "allow_once") == true)
    local ok_tamper = bind_gate:authorize("write_file", { path = "a.txt", content = "tampered" })
    assert(not ok_tamper, "allow_once must reject modified write_file content")
    local ok_other_path = bind_gate:authorize("write_file", { path = "b.txt", content = "safe" })
    assert(not ok_other_path, "allow_once must reject substituted write_file path")
    assert(bind_gate:authorize("write_file", { path = "a.txt", content = "safe" }) == true,
      "allow_once must still authorize the original exact arguments once")

    print("PASS security review regressions")
  end

  -- 9. Dashboard approvals store, thinking toggles, and CLI runtime wiring (CTX-0054)
  do
    local apr_root = root .. "/approvals-xdg"
    local apr_data = apr_root .. "/.local/share/wheel"
    local apr_env = {
      HOME = apr_root,
      XDG_CONFIG_HOME = apr_root .. "/.config",
      XDG_DATA_HOME = apr_root .. "/.local/share",
      XDG_STATE_HOME = apr_root .. "/.local/state",
    }

    -- 9a. 0700/0600 permissions, <= 32 cap pruning oldest resolved first, and symlink refusal
    local first_id = nil
    local pending_ids = {}
    for idx = 1, 35 do
      local enq, eerr = WheelConfig.enqueue_approval({
        tool = "run_command",
        scope_key = "run_command:echo " .. tostring(idx),
        args_key = "cmd:" .. tostring(idx),
        summary = "echo " .. tostring(idx),
        session_id = "sess-cap",
        policy_generation = 1,
      }, { env = apr_env, now = 1000 + idx })
      assert(enq ~= nil, "enqueue_approval failed: " .. tostring(eerr and eerr.message))
      if idx == 1 then first_id = enq.id end
      if idx <= 5 then
        local res_ok, rerr = WheelConfig.resolve_approval_store(enq.id, "deny", { env = apr_env, now = 1000 + idx })
        assert(res_ok ~= nil, "resolve_approval_store failed: " .. tostring(rerr and rerr.message))
      else
        table.insert(pending_ids, enq.id)
      end
    end
    assert(WheelHost.fs.stat(apr_data).mode == 448, "approvals data dir must be 0700")
    assert(WheelHost.fs.stat(apr_data .. "/approvals.json").mode == 384, "approvals.json must be 0600")
    local store = assert(WheelConfig.read_approvals({ env = apr_env }))
    assert(#store.entries == 32, "approvals store must be capped at 32 entries, got " .. tostring(#store.entries))
    assert(WheelConfig.get_approval(first_id, { env = apr_env }) == nil,
      "oldest resolved entry must be pruned first when capping at 32 entries")
    assert(WheelConfig.get_approval(pending_ids[1], { env = apr_env }) ~= nil,
      "pending entries must survive pruning while older resolved entries exist")

    -- Reclaim dead-owner tokenized .approvals.lock/owner.<token> lock + dead stage dir + interrupted empty lock dir
    local stale_stage_dir = apr_data .. "/.approvals.lock.stage.99999999-1-1"
    assert(WheelHost.fs.mkdir(stale_stage_dir) == true)
    assert(WheelHost.fs.write_file(stale_stage_dir .. "/owner.99999999-1-1", "99999999\n") == true)
    local stale_lock_dir = apr_data .. "/.approvals.lock"
    assert(WheelHost.fs.mkdir(stale_lock_dir) == true)
    assert(WheelHost.fs.write_file(stale_lock_dir .. "/owner.99999999-stale-1", "99999999\n") == true)
    local after_reclaim, reclaim_err = WheelConfig.resolve_approval_store(pending_ids[1], "allow_once", { env = apr_env, now = 1010 })
    assert(after_reclaim ~= nil, "resolve_approval_store must reclaim dead tokenized lock: " .. tostring(reclaim_err and reclaim_err.message))
    assert(not WheelHost.fs.exists(stale_lock_dir), "tokenized .approvals.lock must be removed after mutation")
    assert(not WheelHost.fs.exists(stale_stage_dir), "dead .approvals.lock.stage.<token> dir must be swept")

    assert(WheelHost.fs.mkdir(stale_lock_dir) == true)
    local after_empty_reclaim, empty_reclaim_err = WheelConfig.resolve_approval_store(pending_ids[2], "allow_once", { env = apr_env, now = 1011 })
    assert(after_empty_reclaim ~= nil, "resolve_approval_store must reclaim interrupted empty lock dir: " .. tostring(empty_reclaim_err and empty_reclaim_err.message))
    assert(not WheelHost.fs.exists(stale_lock_dir), "empty .approvals.lock must be removed after mutation")

    -- Symlink refusal on approvals.json
    local sym_root = root .. "/approvals-symlink"
    WheelHost.fs.mkdir_p(sym_root .. "/share/wheel")
    WheelHost.fs.chmod(sym_root .. "/share/wheel", "700")
    WheelHost.fs.write_file(sym_root .. "/real.json", '{"version":1,"entries":[]}\n')
    WheelHost.proc.run_program("ln", { "-s", sym_root .. "/real.json", sym_root .. "/share/wheel/approvals.json" })
    local sym_read, sym_err = WheelConfig.read_approvals({ data_dir = sym_root .. "/share/wheel" })
    assert(sym_read == nil and sym_err and sym_err.code == "E_DATA_STORE_SYMLINK",
      "read_approvals must refuse symlinked approvals.json")
    local sym_enq, sym_enq_err = WheelConfig.enqueue_approval({ tool = "run_command" }, { data_dir = sym_root .. "/share/wheel" })
    assert(sym_enq == nil and sym_enq_err and sym_enq_err.code == "E_DATA_STORE_SYMLINK",
      "enqueue_approval must refuse symlinked approvals.json")

    -- 9b. wheel init non-shadowing + thinking_enabled/gear CLI + layer override + project non-escalation
    local cfg_root = root .. "/thinking-xdg"
    local cfg_env = {
      HOME = cfg_root,
      XDG_CONFIG_HOME = cfg_root .. "/.config",
      XDG_DATA_HOME = cfg_root .. "/.local/share",
      XDG_STATE_HOME = cfg_root .. "/.local/state",
    }
    assert(WheelCLI.main({ "init" }, { env = cfg_env, stdout = function() end, stderr = function() end }) == 0)
    assert(WheelCLI.main({ "config", "set", "providers.opencode-go.model", "custom-go-model" },
      { env = cfg_env, stdout = function() end, stderr = function() end }) == 0)
    assert(WheelCLI.main({ "config", "set", "thinking_enabled", "true" },
      { env = cfg_env, stdout = function() end, stderr = function() end }) == 0)
    assert(WheelCLI.main({ "config", "set", "thinking_gear", "high" },
      { env = cfg_env, stdout = function() end, stderr = function() end }) == 0)
    local eff1 = assert(WheelConfig.resolve_effective_config({ env = cfg_env, project_root = cfg_root }))
    assert(eff1.ok, "init + settings config load must succeed")
    assert(eff1.config.providers["opencode-go"].model == "custom-go-model",
      "starter providers/opencode-go.lua must not shadow Layer 0.5 settings.json model")
    assert(WheelConfig.effective_thinking(eff1.config) == "high",
      "thinking_enabled=true + thinking_gear=high must resolve effective_thinking=high")

    -- Disabling thinking_enabled keeps thinking_gear preserved while effective_thinking is off
    assert(WheelCLI.main({ "config", "set", "thinking_enabled", "false" },
      { env = cfg_env, stdout = function() end, stderr = function() end }) == 0)
    local eff2 = assert(WheelConfig.resolve_effective_config({ env = cfg_env, project_root = cfg_root }))
    assert(eff2.config.thinking_gear == "high", "thinking_gear must stay preserved when disabled")
    assert(WheelConfig.effective_thinking(eff2.config) == "off", "effective_thinking must be off when disabled")

    -- Layer 1 legacy `thinking = "low"` overrides Layer 0.5 toggle
    WheelHost.fs.write_file(cfg_root .. "/.config/wheel/init.lua", 'return { thinking = "low" }\n')
    assert(WheelCLI.main({ "config", "set", "thinking_enabled", "true" },
      { env = cfg_env, stdout = function() end, stderr = function() end }) == 0)
    local eff3 = assert(WheelConfig.resolve_effective_config({ env = cfg_env, project_root = cfg_root }))
    assert(WheelConfig.effective_thinking(eff3.config) == "low",
      "Layer 1 legacy thinking=low must override Layer 0.5 thinking_enabled=true")

    -- Invalid CLI settings values fail with exit code 2
    assert(WheelCLI.main({ "config", "set", "thinking_enabled", "maybe" },
      { env = cfg_env, stdout = function() end, stderr = function() end }) == 2)
    assert(WheelCLI.main({ "config", "set", "thinking_gear", "ultra" },
      { env = cfg_env, stdout = function() end, stderr = function() end }) == 2)
    assert(WheelCLI.main({ "config", "set", "approval_mode", "yolo" },
      { env = cfg_env, stdout = function() end, stderr = function() end }) == 2)

    -- Project config cannot weaken approval_mode to prompt or dashboard; auto-deny is allowed
    local proj_root = root .. "/proj-approval-escalation"
    WheelHost.fs.mkdir_p(proj_root .. "/.wheel")
    WheelHost.fs.write_file(proj_root .. "/.wheel/init.lua", 'return { approval_mode = "dashboard" }\n')
    local esc_res = WheelConfig.resolve_effective_config({ env = cfg_env, project_root = proj_root, trusted = true })
    assert(not esc_res.ok and esc_res.error == "project_config_escalation",
      "project config setting approval_mode=dashboard must fail with project_config_escalation")
    WheelHost.fs.write_file(proj_root .. "/.wheel/init.lua", 'return { approval_mode = "auto-deny" }\n')
    local strict_res = WheelConfig.resolve_effective_config({ env = cfg_env, project_root = proj_root, trusted = true })
    assert(strict_res.ok and strict_res.config.approval_mode == "auto-deny",
      "project config may tighten approval_mode to auto-deny")

    -- 9b-2. thinking_enabled=false overrides legacy thinking="high", legacy thinking=false stays disabled,
    -- and oversized scope_key is bounded.
    assert(WheelConfig.effective_thinking({ thinking = "high", thinking_enabled = false, thinking_gear = "high" }) == "off",
      "explicit thinking_enabled=false must return off even when legacy thinking is set")
    WheelHost.fs.write_file(cfg_root .. "/.config/wheel/init.lua", 'return { thinking = false }\n')
    local false_think = WheelConfig.resolve_effective_config({ env = cfg_env, project_root = proj_root, trusted = true })
    assert(false_think.ok and false_think.config.thinking_enabled == false and false_think.config.thinking == "off",
      "legacy thinking=false must keep thinking_enabled=false")
    local long_scope = string.rep("x", 400)
    local bounded_entry = WheelConfig.enqueue_approval({
      tool = "run_command",
      scope_key = long_scope,
      summary = "oversized scope test",
    }, { env = apr_env, now = 2000 })
    assert(bounded_entry and bounded_entry.scope_key:match("^bounded:[0-9a-f]+$") and #bounded_entry.scope_key <= 256,
      "oversized scope_key must be hashed to bounded:<sha256>")

    -- 9c. wheel approvals list / resolve + wheel run --approval-mode dashboard
    local dash_root = root .. "/dash-run"
    WheelHost.fs.mkdir_p(dash_root .. "/ws")
    local dash_env = {
      HOME = dash_root,
      XDG_CONFIG_HOME = dash_root .. "/.config",
      XDG_DATA_HOME = dash_root .. "/.local/share",
      XDG_STATE_HOME = dash_root .. "/.local/state",
    }
    assert(WheelCLI.main({ "init" }, { env = dash_env, stdout = function() end, stderr = function() end }) == 0)
    assert(WheelCLI.main({ "auth", "set", "opencode-go", "--stdin" }, {
      env = dash_env,
      stdin = "og-dash-secret\n",
      stdout = function() end,
      stderr = function() end,
    }) == 0)

    local function make_tool_loop_http(cmd_str, check_tool_body)
      local turn = 0
      return function(req)
        turn = turn + 1
        if turn == 2 and type(check_tool_body) == "function" then
          check_tool_body(req.body)
        end
        local body_obj = {
          choices = {
            {
              message = (turn == 1) and {
                content = "",
                tool_calls = {
                  {
                    index = 0,
                    id = "call_dash_" .. tostring(turn),
                    type = "function",
                    ["function"] = {
                      name = "run_command",
                      arguments = WheelProvider.JSON.encode({ command = cmd_str or "echo dash-approved" }),
                    },
                  },
                },
              } or {
                content = "tool step complete",
              },
              finish_reason = (turn == 1) and "tool_calls" or "stop",
            },
          },
        }
        if req.stream and type(req.on_stream_chunk) == "function" then
          local delta = body_obj.choices[1].message
          local chunk = WheelProvider.JSON.encode({
            choices = { { delta = delta, finish_reason = body_obj.choices[1].finish_reason } },
          })
          req.on_stream_chunk("data: " .. chunk .. "\n\ndata: [DONE]\n\n")
          return { status = 200, body = "" }
        end
        return { status = 200, body = WheelProvider.JSON.encode(body_obj) }
      end
    end

    local function count_successful_tool_outputs(raw_body, expected_substr)
      if type(raw_body) ~= "string" then
        return 0
      end
      local ok_dec, decoded = pcall(WheelProvider.JSON.decode, raw_body)
      if not ok_dec or type(decoded) ~= "table" or type(decoded.messages) ~= "table" then
        return 0
      end
      local matches = 0
      local seen_seq = 0
      local seen_ids = {}
      for _, msg in ipairs(decoded.messages) do
        if type(msg) == "table" and msg.role == "tool" and type(msg.content) == "string" then
          local ok_res, tool_res = pcall(WheelProvider.JSON.decode, msg.content)
          local is_success = (ok_res and type(tool_res) == "table" and tool_res.ok == true)
            or (not msg.content:find("denied", 1, true) and not msg.content:find("E_CAPABILITY_DENIED", 1, true))
          if is_success and msg.content:find(expected_substr, 1, true) then
            seen_seq = seen_seq + 1
            local key = tostring(msg.tool_call_id or ("idx-" .. tostring(seen_seq)))
            if not seen_ids[key] then
              seen_ids[key] = true
              matches = matches + 1
            end
          end
        end
      end
      return matches
    end

    -- Case 1: allow_once permits execution once
    local run_out, run_err = {}, {}
    local listed_during_wait = nil
    local saw_tool_output = false
    local rc_once = WheelCLI.main({
      "run", "--approval-mode", "dashboard", "--workspace", dash_root .. "/ws", "run echo",
    }, {
      env = dash_env,
      http_client = make_tool_loop_http("echo dash-approved", function(body)
        if count_successful_tool_outputs(body, "dash-approved") >= 1 then
          saw_tool_output = true
        end
      end),
      approval_timeout_sec = 30,
      poll_wait = function(approval_id)
        local l_out = {}
        assert(WheelCLI.main({ "approvals", "list" }, {
          env = dash_env,
          stdout = function(s) table.insert(l_out, s) end,
          stderr = function() end,
        }) == 0)
        listed_during_wait = table.concat(l_out, "")
        assert(WheelCLI.main({ "approvals", "resolve", approval_id, "allow_once" }, {
          env = dash_env,
          stdout = function() end,
          stderr = function() end,
        }) == 0)
      end,
      stdout = function(s) table.insert(run_out, s) end,
      stderr = function(s) table.insert(run_err, s) end,
    })
    assert(rc_once == 0, "dashboard allow_once run failed: " .. table.concat(run_err, ""))
    assert(listed_during_wait and listed_during_wait:find("pending", 1, true),
      "approvals list must show pending entry during dashboard wait")
    assert(saw_tool_output, "allow_once must execute run_command and pass output to turn 2")
    assert(table.concat(run_err, ""):find("Pending in Dashboard:", 1, true),
      "dashboard approver must log pending id to stderr")

    -- Case 1b: allow_session caches for repeated identical invocation without second poll
    local sess_polls = 0
    local sess_turn = 0
    local sess_outputs = 0
    local rc_sess = WheelCLI.main({
      "run", "--approval-mode", "dashboard", "--workspace", dash_root .. "/ws", "run echo twice",
    }, {
      env = dash_env,
      http_client = function(req)
        sess_turn = sess_turn + 1
        if sess_turn >= 2 then
          local c = count_successful_tool_outputs(req.body, "sess-approved")
          if c > sess_outputs then
            sess_outputs = c
          end
        end
        local msg
        if sess_turn <= 2 then
          msg = {
            content = "",
            tool_calls = {
              {
                index = 0,
                id = "call_sess_" .. tostring(sess_turn),
                type = "function",
                ["function"] = { name = "run_command", arguments = '{"command":"echo sess-approved"}' },
              },
            },
          }
        else
          msg = { content = "session cached complete" }
        end
        local chunk = WheelProvider.JSON.encode({
          choices = { { delta = msg, finish_reason = (sess_turn <= 2) and "tool_calls" or "stop" } },
        })
        if req.stream and type(req.on_stream_chunk) == "function" then
          req.on_stream_chunk("data: " .. chunk .. "\n\ndata: [DONE]\n\n")
          return { status = 200, body = "" }
        end
        return { status = 200, body = chunk }
      end,
      approval_timeout_sec = 30,
      poll_wait = function(approval_id)
        sess_polls = sess_polls + 1
        assert(WheelCLI.main({ "approvals", "resolve", approval_id, "allow_session" }, {
          env = dash_env,
          stdout = function() end,
          stderr = function() end,
        }) == 0)
      end,
      stdout = function() end,
      stderr = function() end,
    })
    assert(rc_sess == 0, "dashboard allow_session run failed")
    assert(sess_polls == 1, "allow_session must cache approval and prompt only once, polled=" .. tostring(sess_polls))
    assert(sess_outputs >= 2, "allow_session must permit both matching run_command calls")

    -- Case 1c: deny blocks tool execution
    local deny_blocked = false
    local rc_deny = WheelCLI.main({
      "run", "--approval-mode", "dashboard", "--workspace", dash_root .. "/ws", "run deny",
    }, {
      env = dash_env,
      http_client = make_tool_loop_http("echo should-not-run", function(body)
        if type(body) == "string" and (body:find("denied", 1, true) or body:find("blocked", 1, true) or body:find("rejected", 1, true) or body:find("E_CAPABILITY_DENIED", 1, true)) then
          deny_blocked = true
        end
      end),
      approval_timeout_sec = 30,
      poll_wait = function(approval_id)
        assert(WheelCLI.main({ "approvals", "resolve", approval_id, "deny" }, {
          env = dash_env,
          stdout = function() end,
          stderr = function() end,
        }) == 0)
      end,
      stdout = function() end,
      stderr = function() end,
    })
    assert(rc_deny == 0 and deny_blocked, "explicit deny must block run_command execution")

    -- Case 2: bad approvals resolve usage fails with exit 2; missing/already resolved fails with exit 1
    assert(WheelCLI.main({ "approvals", "resolve", "apr-missing", "bogus" }, {
      env = dash_env,
      stdout = function() end,
      stderr = function() end,
    }) == 2)
    assert(WheelCLI.main({ "approvals", "resolve", "apr-missing", "deny" }, {
      env = dash_env,
      stdout = function() end,
      stderr = function() end,
    }) == 1)

    -- Case 3: tampered args_sha256 fails closed to deny even if status=resolved decision=allow_once
    local tamper_calls = 0
    local tamper_blocked = false
    local rc_tamper = WheelCLI.main({
      "run", "--approval-mode", "dashboard", "--workspace", dash_root .. "/ws", "run echo tamper",
    }, {
      env = dash_env,
      http_client = function(req)
        tamper_calls = tamper_calls + 1
        local msg
        if tamper_calls == 1 then
          msg = {
            content = "",
            tool_calls = {
              {
                index = 0,
                id = "call_tamper",
                type = "function",
                ["function"] = { name = "run_command", arguments = '{"command":"echo tamper"}' },
              },
            },
          }
        else
          -- Ensure tool result reports Permission denied (failed closed)
          if type(req.body) == "string" and (req.body:find("denied", 1, true) or req.body:find("blocked", 1, true) or req.body:find("rejected", 1, true) or req.body:find("E_CAPABILITY_DENIED", 1, true)) then
            tamper_blocked = true
          end
          msg = { content = "blocked cleanly" }
        end
        local chunk = WheelProvider.JSON.encode({
          choices = { { delta = msg, finish_reason = (tamper_calls == 1) and "tool_calls" or "stop" } },
        })
        if req.stream and type(req.on_stream_chunk) == "function" then
          req.on_stream_chunk("data: " .. chunk .. "\n\ndata: [DONE]\n\n")
          return { status = 200, body = "" }
        end
        return { status = 200, body = chunk }
      end,
      approval_timeout_sec = 30,
      poll_wait = function(approval_id)
        local path = dash_root .. "/.local/share/wheel/approvals.json"
        local raw = assert(WheelHost.fs.read_file(path))
        local doc = WheelKernel.JSON.decode(raw)
        for _, e in ipairs(doc.entries) do
          if e.id == approval_id then
            e.status = "resolved"
            e.decision = "allow_once"
            e.args_sha256 = string.rep("0", 64)
          end
        end
        WheelHost.fs.write_file(path, WheelKernel.JSON.encode(doc))
      end,
      stdout = function() end,
      stderr = function() end,
    })
    assert(rc_tamper == 0 and tamper_blocked, "tampered approval args_sha256 must fail closed to deny")

    -- Case 4: timeout fail closed (deterministic mocked clock)
    local fake_clock = 5000
    local orig_time_now = WheelHost.time.now
    WheelHost.time.now = function() return fake_clock end
    local to_ok, to_err = pcall(function()
      local out_t, err_t = {}, {}
      local to_turns = 0
      local timeout_blocked = false
      local rc_t = WheelCLI.main({
        "run", "--approval-mode", "dashboard", "--workspace", dash_root .. "/ws", "run timeout",
      }, {
        env = dash_env,
        approval_timeout_sec = 2,
        poll_wait = function() fake_clock = fake_clock + 3 end,
        http_client = function(req)
          to_turns = to_turns + 1
          local msg
          if to_turns == 1 then
            msg = {
              content = "",
              tool_calls = {
                {
                  index = 0,
                  id = "call_to",
                  type = "function",
                  ["function"] = { name = "run_command", arguments = '{"command":"echo timeout"}' },
                },
              },
            }
          else
            if type(req.body) == "string" and (req.body:find("denied", 1, true) or req.body:find("blocked", 1, true) or req.body:find("E_CAPABILITY_DENIED", 1, true)) then
              timeout_blocked = true
            end
            msg = { content = "timed out" }
          end
          local chunk = WheelProvider.JSON.encode({
            choices = { { delta = msg, finish_reason = (to_turns == 1) and "tool_calls" or "stop" } },
          })
          if req.stream and type(req.on_stream_chunk) == "function" then
            req.on_stream_chunk("data: " .. chunk .. "\n\ndata: [DONE]\n\n")
            return { status = 200, body = "" }
          end
          return { status = 200, body = chunk }
        end,
        stdout = function(s) table.insert(out_t, s) end,
        stderr = function(s) table.insert(err_t, s) end,
      })
      assert(rc_t == 0 and timeout_blocked and table.concat(err_t, ""):find("timed out waiting for Dashboard decision", 1, true),
        "dashboard wait must time out and deny")
    end)
    WheelHost.time.now = orig_time_now
    assert(to_ok, to_err)

    print("PASS dashboard approvals and thinking controls")
  end
end)

cleanup_dir(root)
if not ok_all then
  error(test_err, 0)
end
print("PASS ALL test_daily_driver checks")
