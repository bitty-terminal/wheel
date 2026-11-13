-- lua/wheel/cli.lua
-- Standalone daily-driver CLI for Wheel (CTX-0053 / wheel#140).
-- Subcommands: init, providers, config, auth, ask, run, chat.
-- Deliberately loaded on demand by scripts/wheel (never eagerly from wheel.init).

local WheelConfig = require("wheel.config")
local WheelHost = require("wheel.host")
local WheelProvider = require("wheel.provider")
local WheelTool = require("wheel.tool")
local WheelKernel = require("wheel.kernel")
local WheelContext = require("wheel.context")
local WheelAgent = require("wheel.agent")
local WheelRunner = require("wheel.runner")

local WheelCLI = {}

local function trim(s)
  if type(s) ~= "string" then return "" end
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function make_io(harness)
  harness = type(harness) == "table" and harness or {}
  local out_fn = harness.stdout or function(text) io.stdout:write(text) end
  local err_fn = harness.stderr or function(text) io.stderr:write(text) end
  local read_line_fn
  if type(harness.stdin) == "string" then
    local buf = harness.stdin
    local pos = 1
    read_line_fn = function()
      if pos > #buf then return nil end
      local nl = buf:find("\n", pos, true)
      if nl then
        local line = buf:sub(pos, nl - 1):gsub("\r$", "")
        pos = nl + 1
        return line
      end
      local line = buf:sub(pos):gsub("\r$", "")
      pos = #buf + 1
      return line
    end
  elseif type(harness.read_line) == "function" then
    read_line_fn = harness.read_line
  else
    read_line_fn = function() return io.stdin:read("*l") end
  end
  return {
    env = harness.env,
    http_client = harness.http_client,
    approver = harness.approver,
    poll_wait = harness.poll_wait,
    approval_timeout_sec = harness.approval_timeout_sec,
    out = out_fn,
    err = err_fn,
    read_line = read_line_fn,
    println = function(text) out_fn((text or "") .. "\n") end,
    errln = function(text) err_fn((text or "") .. "\n") end,
  }
end

local function collect_args_list(argv)
  local list = {}
  if type(argv) ~= "table" then return list end
  for i = 1, #argv do
    if type(argv[i]) == "string" then
      table.insert(list, argv[i])
    end
  end
  return list
end

local SECRET_FIELD_NAMES = {
  api_key = true,
  credentials = true,
  token = true,
  secret = true,
  password = true,
  access_token = true,
  refresh_token = true,
}

local function is_secret_key(k)
  if type(k) ~= "string" then return false end
  local lower = string.lower(k)
  if SECRET_FIELD_NAMES[lower] then return true end
  return lower:match("_key$") ~= nil or lower:match("_token$") ~= nil
    or lower:match("_secret$") ~= nil or lower:match("_password$") ~= nil
end

local function clone_masked_config(value, in_secret)
  if type(value) ~= "table" then
    if in_secret and type(value) == "string" and #value > 0 then
      return "***REDACTED***"
    end
    return value
  end
  local out = {}
  for k, v in pairs(value) do
    local child_secret = in_secret or is_secret_key(k)
    if child_secret and type(v) ~= "table" then
      out[k] = (type(v) == "string" and #v > 0) and "***REDACTED***" or v
    else
      out[k] = clone_masked_config(v, child_secret)
    end
  end
  return out
end

local function dotted_get(tbl, key)
  if type(tbl) ~= "table" or type(key) ~= "string" or key == "" then return nil end
  if tbl[key] ~= nil then return tbl[key] end
  local cur = tbl
  for seg in key:gmatch("[^%.]+") do
    if type(cur) ~= "table" then return nil end
    cur = cur[seg]
  end
  return cur
end

local function dotted_set(tbl, key, value)
  local parts = {}
  for seg in key:gmatch("[^%.]+") do
    table.insert(parts, seg)
  end
  if #parts == 0 then return false end
  local cur = tbl
  for i = 1, #parts - 1 do
    local seg = parts[i]
    if type(cur[seg]) ~= "table" then
      cur[seg] = {}
    end
    cur = cur[seg]
  end
  cur[parts[#parts]] = value
  return true
end

local function parse_scalar(raw)
  if raw == "true" then return true end
  if raw == "false" then return false end
  local num = tonumber(raw)
  if num ~= nil and raw:match("^%-?%d+%.?%d*$") then return num end
  return raw
end

local function build_cli_approver(io_ctx, mode_flag, cfg)
  if type(io_ctx.approver) == "function" then
    return io_ctx.approver
  end
  local effective_mode = mode_flag or (type(cfg) == "table" and cfg.approval_mode) or "prompt"
  if effective_mode == "auto-deny" then
    return function() return { decision = "deny" } end
  end
  if effective_mode == "dashboard" then
    return function(req)
      local args_sha256 = WheelConfig.compute_hash(tostring(req.args_key or ""))
      local entry, enq_err = WheelConfig.enqueue_approval({
        tool = req.tool,
        scope_key = req.scope_key,
        args_sha256 = args_sha256,
        summary = req.summary,
        session_id = req.session_id,
        policy_generation = req.policy_generation,
        agent_name = req.agent_name,
        ttl_sec = io_ctx.approval_timeout_sec,
      }, { env = io_ctx.env })
      if not entry then
        io_ctx.errln("wheel approval: failed to enqueue dashboard request: "
          .. tostring(enq_err and enq_err.message or "error"))
        return { decision = "deny" }
      end
      io_ctx.errln(string.format("[wheel approval] Pending in Dashboard: id=%s tool=%s summary=%s",
        tostring(entry.id), tostring(req.tool), tostring(req.summary)))
      local timeout_sec = tonumber(io_ctx.approval_timeout_sec) or 120
      if timeout_sec <= 0 then
        timeout_sec = 120
      end
      local start_ts = WheelHost.time.now()
      while true do
        local current, gerr = WheelConfig.get_approval(entry.id, { env = io_ctx.env })
        if not current then
          if gerr then
            io_ctx.errln("wheel approval: failed to read approval state: " .. tostring(gerr.message or "error"))
          end
          return { decision = "deny" }
        end
        if current.status == "resolved" then
          local expected_gen = tonumber(req.policy_generation) or 1
          local expected_sid = req.session_id ~= nil and tostring(req.session_id) or nil
          if current.session_id ~= expected_sid
            or tonumber(current.policy_generation) ~= expected_gen
            or current.args_sha256 ~= args_sha256
          then
            io_ctx.errln("wheel approval: rejected mismatched approval response for " .. tostring(entry.id))
            return { decision = "deny" }
          end
          if current.decision == "allow_once" or current.decision == "allow_session" then
            return { decision = current.decision }
          end
          return { decision = "deny" }
        end
        local now_ts = WheelHost.time.now()
        if (now_ts - start_ts) >= timeout_sec then
          pcall(WheelConfig.resolve_approval_store, entry.id, "deny", { env = io_ctx.env, now = now_ts })
          io_ctx.errln("wheel approval: timed out waiting for Dashboard decision on " .. tostring(entry.id))
          return { decision = "deny" }
        end
        if type(io_ctx.poll_wait) == "function" then
          io_ctx.poll_wait(entry.id, 250)
        elseif type(WheelHost.time.sleep_ms) == "function" then
          WheelHost.time.sleep_ms(250)
        else
          pcall(WheelConfig.resolve_approval_store, entry.id, "deny", { env = io_ctx.env, now = now_ts })
          return { decision = "deny" }
        end
      end
    end
  end
  return function(req)
    io_ctx.errln(string.format("[wheel approval] tool=%s summary=%s",
      tostring(req.tool), tostring(req.summary)))
    io_ctx.err("[wheel approval] Allow? [y] once / [s] session / [N] deny: ")
    local ans = string.lower(trim(io_ctx.read_line() or ""))
    if ans == "y" or ans == "yes" then
      return { decision = "allow_once" }
    elseif ans == "s" or ans == "session" then
      return { decision = "allow_session" }
    end
    return { decision = "deny" }
  end
end

local function cmd_init(args, io_ctx)
  local force = false
  for _, a in ipairs(args) do
    if a == "--force" then force = true end
  end
  local cfg_dir = WheelConfig.get_global_config_dir(io_ctx.env)
  local data_dir = WheelConfig.get_data_dir(io_ctx.env)
  if not cfg_dir or not data_dir then
    io_ctx.errln("wheel init: HOME or XDG_CONFIG_HOME/XDG_DATA_HOME must be set")
    return 1
  end

  local subdirs = { "", "/providers", "/agents", "/commands", "/tools", "/skills" }
  for _, sub in ipairs(subdirs) do
    if not WheelHost.fs.mkdir_p(cfg_dir .. sub) then
      io_ctx.errln("wheel init: failed to create directory " .. cfg_dir .. sub)
      return 1
    end
  end

  local init_path = cfg_dir .. "/init.lua"
  if force or not WheelHost.fs.exists(init_path) then
    local starter_init = [[-- Wheel global configuration (~/.config/wheel/init.lua).
-- Any value returned here overrides ~/.local/share/wheel/settings.json.
-- Modular drop-ins live under providers/, agents/, commands/, tools/, skills/.
return {
  -- default_provider = "opencode-go",
  -- thinking = "medium",
  -- permissions = { run_command = "ask" },
}
]]
    if not WheelHost.fs.write_file(init_path, starter_init) then
      io_ctx.errln("wheel init: failed to write " .. init_path)
      return 1
    end
  end

  local og_path = cfg_dir .. "/providers/opencode-go.lua"
  if force or not WheelHost.fs.exists(og_path) then
    local starter_og = [[-- Built-in template defaults for OpenCode Go (deepseek-v4.1-flash).
-- Uncomment model below only if you want Layer 1 config.lua to override $XDG_DATA_HOME/wheel/settings.json.
return {
  name = "opencode-go",
  -- model = "deepseek-v4.1-flash",
}
]]
    if not WheelHost.fs.write_file(og_path, starter_og) then
      io_ctx.errln("wheel init: failed to write " .. og_path)
      return 1
    end
  end

  local settings, ds_err = WheelConfig.read_data_settings({ env = io_ctx.env })
  if not settings then
    io_ctx.errln("wheel init: " .. tostring(ds_err and ds_err.message or "invalid settings store"))
    return 1
  end
  if next(settings) == nil or force then
    local ok_ws, ws_err = WheelConfig.write_data_settings({
      default_provider = "opencode-go",
      thinking = "off",
      thinking_enabled = false,
      thinking_gear = "medium",
      approval_mode = "prompt",
      permissions = {
        read_file = "allow",
        list_directory = "allow",
        search_code = "allow",
        read_blob = "allow",
        write_file = "allow",
        edit_file = "allow",
        run_command = "ask",
      },
    }, { env = io_ctx.env })
    if not ok_ws then
      io_ctx.errln("wheel init: " .. tostring(ws_err and ws_err.message or "failed to write settings"))
      return 1
    end
  end

  local cred_file = data_dir .. "/credentials.json"
  if not WheelHost.fs.exists(cred_file) then
    local ok_dir = WheelHost.fs.mkdir_p(data_dir)
    if ok_dir then WheelHost.fs.chmod(data_dir, "700") end
    local ok_c = WheelHost.fs.create_private_file(cred_file, '{"providers":{},"version":1}\n')
    if not ok_c then
      io_ctx.errln("wheel init: failed to initialize 0600 credentials store")
      return 1
    end
  end

  io_ctx.println("Initialized Wheel config at " .. cfg_dir .. " and private store at " .. data_dir)
  return 0
end

local function cmd_providers(_, io_ctx)
  local list = WheelProvider.list_templates()
  local eff = WheelConfig.resolve_effective_config({ env = io_ctx.env, project_root = "." })
  local global_cfg = eff and eff.config or {}
  io_ctx.println("Built-in Wheel providers:")
  for _, tmpl in ipairs(list) do
    local key, src = WheelConfig.resolve_api_key(tmpl.name, {
      env = io_ctx.env,
      global_config = global_cfg,
      api_key_env = tmpl.api_key_env,
    })
    local status = (#key > 0) and ("configured (" .. src .. ")") or "not set"
    io_ctx.println(string.format("  %-12s model=%-28s env=%-20s auth=%s",
      tmpl.name, tmpl.default_model, tostring(tmpl.api_key_env or "(local)"), status))
  end
  return 0
end

local function cmd_config(args, io_ctx)
  local sub = args[1] or "show"
  if sub == "show" then
    local eff = WheelConfig.resolve_effective_config({ env = io_ctx.env, project_root = "." })
    if not eff.ok then
      io_ctx.errln("wheel config show: " .. tostring(eff.message or eff.error))
      return 1
    end
    io_ctx.println(WheelKernel.JSON.encode(clone_masked_config(eff.config)))
    return 0
  elseif sub == "get" then
    local key = args[2]
    if not key or key == "" then
      io_ctx.errln("Usage: wheel config get <key>")
      return 2
    end
    local eff = WheelConfig.resolve_effective_config({ env = io_ctx.env, project_root = "." })
    if not eff.ok then
      io_ctx.errln("wheel config get: " .. tostring(eff.message or eff.error))
      return 1
    end
    local val = dotted_get(clone_masked_config(eff.config), key)
    if val == nil then
      io_ctx.errln("wheel config get: key not found: " .. key)
      return 1
    end
    io_ctx.println(type(val) == "table" and WheelKernel.JSON.encode(val) or tostring(val))
    return 0
  elseif sub == "set" then
    local key, raw_val = args[2], args[3]
    if not key or raw_val == nil then
      io_ctx.errln("Usage: wheel config set <key> <value>")
      return 2
    end
    if key == "api_key" or key:find("api_key", 1, true) or key:find("credential", 1, true) then
      io_ctx.errln("wheel config set: credentials belong in `wheel auth set <provider> --stdin`, not settings")
      return 2
    end
    if key == "thinking" then
      local _, terr = WheelProvider.normalize_thinking(raw_val)
      if terr then
        io_ctx.errln("wheel config set: " .. terr)
        return 2
      end
    end
    if key == "thinking_enabled" then
      if raw_val ~= "true" and raw_val ~= "false" then
        io_ctx.errln("wheel config set: thinking_enabled must be true or false")
        return 2
      end
    end
    if key == "thinking_gear" then
      if raw_val ~= "low" and raw_val ~= "medium" and raw_val ~= "high" and raw_val ~= "max" then
        io_ctx.errln("wheel config set: thinking_gear must be low, medium, high, or max")
        return 2
      end
    end
    if key == "approval_mode" then
      if raw_val ~= "prompt" and raw_val ~= "dashboard" and raw_val ~= "auto-deny" then
        io_ctx.errln("wheel config set: approval_mode must be prompt, dashboard, or auto-deny")
        return 2
      end
    end
    if key:match("^permissions%.") then
      if raw_val ~= "allow" and raw_val ~= "ask" and raw_val ~= "deny" then
        io_ctx.errln("wheel config set: permission must be allow, ask, or deny")
        return 2
      end
    end
    local settings, derr = WheelConfig.read_data_settings({ env = io_ctx.env })
    if not settings then
      io_ctx.errln("wheel config set: " .. tostring(derr and derr.message or "failed to read settings"))
      return 1
    end
    dotted_set(settings, key, parse_scalar(raw_val))
    if key == "thinking" then
      settings.thinking_enabled = (raw_val ~= "off")
      if raw_val ~= "off" then
        settings.thinking_gear = raw_val
      end
    elseif key == "thinking_enabled" or key == "thinking_gear" then
      local enabled = settings.thinking_enabled == true
      local gear = settings.thinking_gear or "medium"
      settings.thinking = enabled and gear or "off"
    end
    local ok_w, werr = WheelConfig.write_data_settings(settings, { env = io_ctx.env })
    if not ok_w then
      io_ctx.errln("wheel config set: " .. tostring(werr and werr.message or "failed to write settings"))
      return 1
    end
    local leaf = key:match("([^%.]+)$") or key
    local shown = (is_secret_key(leaf) or key:match("^credentials%.")) and "***REDACTED***" or tostring(raw_val)
    io_ctx.println(key .. " = " .. shown)
    return 0
  elseif sub == "export" then
    io_ctx.out(WheelConfig.export_single_file({ env = io_ctx.env }))
    return 0
  end
  io_ctx.errln("Usage: wheel config [show | get <key> | set <key> <val> | export]")
  return 2
end

local function cmd_auth(args, io_ctx)
  local sub = args[1] or "status"
  if sub == "status" then
    local eff = WheelConfig.resolve_effective_config({ env = io_ctx.env, project_root = "." })
    local global_cfg = eff and eff.config or {}
    for _, tmpl in ipairs(WheelProvider.list_templates()) do
      local key, src = WheelConfig.resolve_api_key(tmpl.name, {
        env = io_ctx.env,
        global_config = global_cfg,
        api_key_env = tmpl.api_key_env,
      })
      io_ctx.println(string.format("%-12s configured=%-5s source=%s",
        tmpl.name, tostring(#key > 0), src))
    end
    return 0
  elseif sub == "set" then
    local provider = args[2]
    local flag = args[3]
    if not provider or provider == "" then
      io_ctx.errln("Usage: wheel auth set <provider> --stdin")
      return 2
    end
    if flag ~= "--stdin" or args[4] ~= nil then
      io_ctx.errln("wheel auth set refuses secrets in command-line arguments; pipe the key via `--stdin`")
      return 2
    end
    local line = trim(io_ctx.read_line() or "")
    if line == "" then
      io_ctx.errln("wheel auth set: empty API key on stdin")
      return 2
    end
    local ok_w, werr = WheelConfig.write_credential(provider, line, { env = io_ctx.env })
    if not ok_w then
      io_ctx.errln("wheel auth set: " .. tostring(werr and werr.message or "failed to save credential"))
      return 1
    end
    io_ctx.println("Saved credential for " .. string.lower(provider) .. " in 0600 store")
    return 0
  elseif sub == "remove" then
    local provider = args[2]
    if not provider or provider == "" then
      io_ctx.errln("Usage: wheel auth remove <provider>")
      return 2
    end
    local ok_d, derr = WheelConfig.delete_credential(provider, { env = io_ctx.env })
    if not ok_d then
      io_ctx.errln("wheel auth remove: " .. tostring(derr and derr.message or "failed to remove credential"))
      return 1
    end
    io_ctx.println("Removed credential for " .. string.lower(provider))
    return 0
  end
  io_ctx.errln("Usage: wheel auth [status | set <provider> --stdin | remove <provider>]")
  return 2
end

local function parse_runtime_flags(args)
  local opts = {
    stream = true,
    positional = {},
  }
  local i = 1
  while i <= #args do
    local a = args[i]
    if a == "--provider" and args[i + 1] then
      opts.provider = args[i + 1]
      i = i + 2
    elseif a == "--model" and args[i + 1] then
      opts.model = args[i + 1]
      i = i + 2
    elseif a == "--thinking" and args[i + 1] then
      opts.thinking = args[i + 1]
      i = i + 2
    elseif a == "--workspace" and args[i + 1] then
      opts.workspace = args[i + 1]
      i = i + 2
    elseif a == "--no-stream" then
      opts.stream = false
      i = i + 1
    elseif a == "--stream" then
      opts.stream = true
      i = i + 1
    elseif a == "--auto-deny" then
      opts.approval_mode = "auto-deny"
      i = i + 1
    elseif a == "--approval-mode" and args[i + 1] then
      opts.approval_mode = args[i + 1]
      i = i + 2
    else
      table.insert(opts.positional, a)
      i = i + 1
    end
  end
  return opts
end

local function build_provider_from_cli(parsed, io_ctx)
  if parsed.approval_mode ~= nil
    and parsed.approval_mode ~= "prompt"
    and parsed.approval_mode ~= "dashboard"
    and parsed.approval_mode ~= "auto-deny"
  then
    return nil, nil, "invalid approval_mode: expected prompt, dashboard, or auto-deny"
  end
  local eff = WheelConfig.resolve_effective_config({
    env = io_ctx.env,
    project_root = parsed.workspace or ".",
  })
  if not eff.ok then
    return nil, nil, eff.message or eff.error
  end
  local cfg = eff.config
  local pname = string.lower(parsed.provider or cfg.default_provider or "opencode-go")
  local pcfg = (type(cfg.providers) == "table" and cfg.providers[pname]) or {}
  local tmpl = WheelProvider.get_template(pname)
  local model = parsed.model or pcfg.model or cfg.default_model or (tmpl and tmpl.default_model)
  local thinking = parsed.thinking or pcfg.thinking or WheelConfig.effective_thinking(cfg)
  local api_key = WheelConfig.resolve_api_key(pname, {
    env = io_ctx.env,
    global_config = cfg,
    api_key_env = pcfg.api_key_env or (tmpl and tmpl.api_key_env),
  })
  if pname ~= "ollama" and pname ~= "mock" and pname ~= "local" and pname ~= "stdio" and api_key == "" then
    return nil, nil, string.format("missing API key for provider '%s' (set %s or run `wheel auth set %s --stdin`)",
      pname, tostring((tmpl and tmpl.api_key_env) or "env var"), pname)
  end
  local adapter, perr = WheelProvider.create({
    provider = pname,
    model = model,
    base_url = pcfg.base_url,
    thinking = thinking,
    max_completion_tokens = pcfg.max_completion_tokens or 4096,
    transport = pcfg.transport,
  }, {
    api_key = api_key,
    http_client = io_ctx.http_client or WheelProvider.default_http_client,
    use_default_http_client = true,
    session_id = parsed.session_id,
  })
  if not adapter then
    return nil, nil, perr
  end
  return adapter, {
    config = cfg,
    permission_layers = eff.permission_layers,
    provider_name = pname,
    model = model,
    thinking = thinking,
  }, nil
end

local function cmd_ask(args, io_ctx)
  local parsed = parse_runtime_flags(args)
  local prompt = trim(table.concat(parsed.positional, " "))
  if prompt == "" then
    io_ctx.errln("Usage: wheel ask [--provider P] [--model M] [--thinking G] [--no-stream] <prompt>")
    return 2
  end
  local adapter, _, err = build_provider_from_cli(parsed, io_ctx)
  if not adapter then
    io_ctx.errln("wheel ask: " .. tostring(err))
    return 1
  end
  local req = {
    messages = { { role = "user", content = prompt } },
  }
  local res, rerr
  if parsed.stream and type(adapter.stream) == "function" then
    local wrote_thinking_header = false
    local wrote_content_header = false
    res, rerr = adapter:stream(req, function(chunk)
      if chunk.type == "thinking" and chunk.delta then
        if not wrote_thinking_header then
          io_ctx.out("[thinking] ")
          wrote_thinking_header = true
        end
        io_ctx.out(chunk.delta)
      elseif chunk.type == "content" and chunk.delta then
        if wrote_thinking_header and not wrote_content_header then
          io_ctx.out("\n")
          wrote_content_header = true
        end
        io_ctx.out(chunk.delta)
      end
    end)
    if res then io_ctx.out("\n") end
  else
    res, rerr = adapter:complete(req)
    if res then
      if type(res.thinking_content) == "string" and #res.thinking_content > 0 then
        io_ctx.println("[thinking] " .. res.thinking_content)
      end
      io_ctx.println(res.content or "")
    end
  end
  if not res then
    io_ctx.errln("wheel ask: " .. tostring(rerr))
    return 1
  end
  return 0
end

local function cmd_run(args, io_ctx)
  local parsed = parse_runtime_flags(args)
  local task_desc = trim(table.concat(parsed.positional, " "))
  if task_desc == "" then
    io_ctx.errln("Usage: wheel run [--provider P] [--model M] [--thinking G] [--workspace DIR] [--approval-mode prompt|dashboard|auto-deny] <task>")
    return 2
  end
  local adapter, meta, err = build_provider_from_cli(parsed, io_ctx)
  if not adapter then
    io_ctx.errln("wheel run: " .. tostring(err))
    return 1
  end
  local workspace_root = parsed.workspace or "."
  local kernel = WheelKernel.new({ in_memory = true })
  local context = WheelContext.new({ kernel = kernel })
  local registry = WheelTool.Registry.new()
  local approver = build_cli_approver(io_ctx, parsed.approval_mode, meta.config)
  local gate = WheelTool.PermissionGate.new({
    policy = meta.config.permissions or { run_command = "ask" },
    layers = meta.permission_layers,
    session_id = "cli-run",
    policy_generation = 1,
    approver = approver,
  })
  local agent = WheelAgent.new({
    name = "wheel-cli",
    role = WheelAgent.Role.CODING,
    kernel = kernel,
    context = context,
    tool_registry = registry,
    workspace = { root = workspace_root },
    provider = adapter,
    permission_gate = gate,
    config = meta.config,
  })
  local task = kernel:create_task({
    id = "CLI-TASK-1",
    title = task_desc:sub(1, 80),
    description = task_desc,
    priority = 1,
  })
  local report = WheelRunner.run_task(agent, task, {
    max_turns = 12,
    on_token = function(delta, kind)
      if kind == "content" and delta then
        io_ctx.out(delta)
      end
    end,
  })
  if report.success then
    io_ctx.out("\n")
    return 0
  end
  io_ctx.errln("wheel run: " .. tostring(report.error or "task failed"))
  return 1
end

local function cmd_chat(args, io_ctx)
  local parsed = parse_runtime_flags(args)
  local adapter, meta, err = build_provider_from_cli(parsed, io_ctx)
  if not adapter then
    io_ctx.errln("wheel chat: " .. tostring(err))
    return 1
  end
  local session_id = WheelProvider.derive_opencode_session_id()
  parsed.session_id = session_id
  local messages = {}
  io_ctx.println(string.format("Wheel chat (%s / %s). Commands: /thinking <gear>, /exit",
    meta.provider_name, meta.model))
  while true do
    io_ctx.out("> ")
    local line = io_ctx.read_line()
    if not line then break end
    local trimmed = trim(line)
    if trimmed == "/exit" or trimmed == "/quit" then
      break
    elseif trimmed:match("^/thinking%s+") then
      local gear = trim(trimmed:sub(11))
      local norm, terr = WheelProvider.normalize_thinking(gear)
      if not norm then
        io_ctx.errln("invalid thinking gear: " .. tostring(terr))
      else
        parsed.thinking = gear
        adapter.thinking = gear
        io_ctx.println("thinking = " .. gear)
      end
    elseif trimmed ~= "" then
      table.insert(messages, { role = "user", content = trimmed })
      local res, rerr = adapter:stream({ messages = messages }, function(chunk)
        if chunk.type == "content" and chunk.delta then
          io_ctx.out(chunk.delta)
        end
      end)
      if not res then
        io_ctx.errln("chat error: " .. tostring(rerr))
      else
        io_ctx.out("\n")
        table.insert(messages, { role = "assistant", content = res.content or "" })
      end
    end
  end
  return 0
end

local function cmd_approvals(args, io_ctx)
  local sub = args[1] or "list"
  if sub == "list" then
    local store, err = WheelConfig.read_approvals({ env = io_ctx.env })
    if not store then
      io_ctx.errln("wheel approvals list: " .. tostring(err and err.message or "failed to read approvals"))
      return 1
    end
    if #store.entries == 0 then
      io_ctx.println("No pending or recent approvals.")
      return 0
    end
    for _, e in ipairs(store.entries) do
      if type(e) == "table" then
        io_ctx.println(string.format("%-20s status=%-8s decision=%-13s tool=%-12s %s",
          tostring(e.id or "-"),
          tostring(e.status or "-"),
          tostring(e.decision or "-"),
          tostring(e.tool or "-"),
          tostring(e.summary or "")))
      end
    end
    return 0
  elseif sub == "resolve" then
    local id, decision = args[2], args[3]
    if not id or id == "" or not decision or decision == "" then
      io_ctx.errln("Usage: wheel approvals resolve <id> <allow_once|allow_session|deny>")
      return 2
    end
    if decision ~= "allow_once" and decision ~= "allow_session" and decision ~= "deny" then
      io_ctx.errln("wheel approvals resolve: decision must be allow_once, allow_session, or deny")
      return 2
    end
    local updated, rerr = WheelConfig.resolve_approval_store(id, decision, { env = io_ctx.env })
    if not updated then
      io_ctx.errln("wheel approvals resolve: " .. tostring(rerr and rerr.message or "failed to resolve approval"))
      return 1
    end
    io_ctx.println(string.format("Resolved %s -> %s", tostring(updated.id), tostring(updated.decision)))
    return 0
  end
  io_ctx.errln("Usage: wheel approvals [list | resolve <id> <allow_once|allow_session|deny>]")
  return 2
end

local function print_usage(io_ctx)
  io_ctx.println([[Usage: wheel <command> [options]

Commands:
  init        Initialize ~/.config/wheel/ and private ~/.local/share/wheel/
  providers   List built-in provider templates and credential status
  config      Inspect or update configuration (show | get | set | export)
  auth        Manage credentials securely (status | set <provider> --stdin | remove)
  approvals   Inspect or resolve pending Dashboard approvals (list | resolve)
  ask         Send a prompt using resolved provider and thinking settings
  run         Run an agent task with tool approval gating
  chat        Start a multi-turn interactive chat session]])
end

--- Entry point callable from both `scripts/wheel` and offline unit tests.
function WheelCLI.main(argv, harness)
  local io_ctx = make_io(harness)
  local list = collect_args_list(argv)
  local cmd = list[1]
  if not cmd or cmd == "-h" or cmd == "--help" or cmd == "help" then
    print_usage(io_ctx)
    return 0
  end
  local rest = {}
  for i = 2, #list do
    table.insert(rest, list[i])
  end
  if cmd == "init" then return cmd_init(rest, io_ctx) end
  if cmd == "providers" then return cmd_providers(rest, io_ctx) end
  if cmd == "config" then return cmd_config(rest, io_ctx) end
  if cmd == "auth" then return cmd_auth(rest, io_ctx) end
  if cmd == "approvals" then return cmd_approvals(rest, io_ctx) end
  if cmd == "ask" then return cmd_ask(rest, io_ctx) end
  if cmd == "run" then return cmd_run(rest, io_ctx) end
  if cmd == "chat" then return cmd_chat(rest, io_ctx) end
  io_ctx.errln("wheel: unknown command '" .. tostring(cmd) .. "'")
  print_usage(io_ctx)
  return 2
end

if type(arg) == "table" and type(arg[0]) == "string" and arg[0]:match("lua/wheel/cli%.lua$") then
  os.exit(WheelCLI.main(arg))
end

return WheelCLI
