-- Wheel Configuration Loader
-- Implements hierarchical configuration layering, the 8 function classes,
-- direnv-style security trust gates, and headless panel container policies
-- per bitty-ai-docs specifications.

local WheelKernel = nil

local function get_kernel()
  if not WheelKernel then
    local ok, mod = pcall(require, "wheel.kernel")
    if ok then
      WheelKernel = mod
    else
      ok, mod = pcall(require, "lua.wheel.kernel")
      if ok then
        WheelKernel = mod
      else
        WheelKernel = require("kernel")
      end
    end
  end
  return WheelKernel
end

local WheelConfig = {}
WheelConfig.__index = WheelConfig

--- Built-in default configuration (Layer 0).
WheelConfig.DEFAULTS = {
  -- 1. Role definitions and model references
  roles = {
    commander = {
      name = "commander",
      model = { name = "claude-3-7-sonnet", temperature = 0.2 },
      tools = { "read_file", "view_file", "search_code", "find_files", "list_directory", "inspect", "git_diff", "git_log", "git_status" },
      budget = { max_iterations = 20, max_tokens = 65536 },
    },
    coding = {
      name = "worker-coding",
      model = { name = "claude-3-5-sonnet", temperature = 0.2 },
      tools = { "read_file", "view_file", "write_file", "search_code", "run_command", "git_diff", "git_status" },
      budget = { max_iterations = 15, max_tokens = 65536 },
    },
    debug = {
      name = "worker-debug",
      model = { name = "claude-3-5-sonnet", temperature = 0.1 },
      tools = { "read_file", "view_file", "write_file", "search_code", "run_command", "git_diff", "git_status" },
      budget = { max_iterations = 15, max_tokens = 65536 },
    },
    research = {
      name = "worker-research",
      model = { name = "claude-3-5-sonnet", temperature = 0.3 },
      tools = { "read_file", "view_file", "search_code", "find_files", "list_directory", "read_resource", "list_resources", "read_url_content", "search_web", "ask_question", "get_outline" },
      budget = { max_iterations = 10, max_tokens = 65536 },
    },
    reviewer = {
      name = "reviewer",
      model = { name = "claude-3-7-sonnet", temperature = 0.1 },
      tools = { "read_file", "view_file", "search_code", "find_files", "list_directory", "git_diff", "git_log", "git_status" },
      budget = { max_iterations = 10, max_tokens = 65536 },
    },
  },
  -- 2. Structured prompt directives
  directives = {
    "Strictly English for all code, comments, documentation, and commits.",
    "Zero unwrap in library code; handle all errors with typed fail-closed patterns.",
  },
  -- 3. Tool allow/deny lists and custom tools
  tools = {
    allow = { "*" },
    deny = {},
    custom = {},
  },
  -- 4. Skill filters from .agents/
  skills = {
    enabled = {},
    disabled = {},
  },
  -- 5. Verification declarations
  verification = {
    change_gated = true,
    test_command = "just check",
  },
  -- 6. Budget & context policy
  context = {
    max_budget_bytes = 65536,
    zone1_max_bytes = 16384,
    zone2_max_bytes = 32768,
    zone3_max_bytes = 16384,
    spillover_threshold_bytes = 4096,
    prune_scratchpads = true,
  },
  -- 7. Headless panel container policy
  panel = {
    headless = true, -- Agent defaults to living in a Headless Panel working container
    name = "wheel-agent-main",
  },
  -- 8. Lifecycle hooks
  hooks = {},
}

--- Check if a table is an array-like sequence.
local function is_array(tbl)
  if type(tbl) ~= "table" then return false end
  local count = 0
  for k, _ in pairs(tbl) do
    if type(k) ~= "number" then return false end
    count = count + 1
  end
  for i = 1, count do
    if tbl[i] == nil then return false end
  end
  return count > 0
end

--- Deep copy a table.
local function deep_copy(orig)
  if type(orig) ~= "table" then return orig end
  local copy = {}
  for k, v in pairs(orig) do
    copy[k] = deep_copy(v)
  end
  return copy
end

--- Deep merge overlay into base, returning a new table.
--- Array lists are replaced by overlay, tables are recursively merged.
local function deep_merge(base, overlay)
  if type(base) ~= "table" then return deep_copy(overlay) end
  if type(overlay) ~= "table" then return deep_copy(base) end
  local result = deep_copy(base)
  for k, v in pairs(overlay) do
    if type(v) == "table" and type(result[k]) == "table" and not is_array(v) and not is_array(result[k]) then
      result[k] = deep_merge(result[k], v)
    else
      result[k] = deep_copy(v)
    end
  end
  return result
end

WheelConfig.deep_merge = deep_merge
WheelConfig.deep_copy = deep_copy

--- Deterministic multi-prime 64-hex content hash (pure Lua, zero external deps).
function WheelConfig.compute_hash(str)
  if type(str) ~= "string" then str = tostring(str or "") end
  -- 8 prime accumulators modulo 2^32
  local h = { 0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19 }
  local primes = { 31, 37, 41, 43, 47, 53, 59, 61 }
  local len = #str
  for i = 1, len do
    local b = string.byte(str, i)
    for j = 1, 8 do
      h[j] = (h[j] * primes[j] + b + (i * j)) % 4294967296
    end
  end
  local hex_parts = {}
  for j = 1, 8 do
    hex_parts[j] = string.format("%08x", h[j])
  end
  return table.concat(hex_parts, "")
end

--- Read file content safely.
local function read_file(filepath)
  local f = io.open(filepath, "r")
  if not f then return nil end
  local content = f:read("*a")
  f:close()
  return content
end

--- Write file content safely.
local function write_file(filepath, content)
  local f = io.open(filepath, "w")
  if not f then return false end
  f:write(content)
  f:close()
  return true
end

--- Resolve global configuration path (~/.config/wheel/init.lua or $XDG_CONFIG_HOME/wheel/init.lua).
function WheelConfig.get_global_config_path()
  local xdg_config = os.getenv("XDG_CONFIG_HOME")
  if xdg_config and xdg_config ~= "" then
    return xdg_config .. "/wheel/init.lua"
  end
  local home = os.getenv("HOME") or ""
  if home ~= "" then
    return home .. "/.config/wheel/init.lua"
  end
  return nil
end

--- Resolve project configuration path (<project_root>/.wheel/init.lua).
function WheelConfig.get_project_config_path(project_root)
  project_root = project_root or "."
  -- Strip trailing slash if present
  project_root = string.gsub(project_root, "/+$", "")
  return project_root .. "/.wheel/init.lua"
end

--- Resolve trust store path ($XDG_STATE_HOME/wheel/trusted_projects.json).
function WheelConfig.get_trust_store_path()
  local xdg_state = os.getenv("XDG_STATE_HOME")
  if xdg_state and xdg_state ~= "" then
    return xdg_state .. "/wheel/trusted_projects.json"
  end
  local home = os.getenv("HOME") or ""
  if home ~= "" then
    return home .. "/.local/state/wheel/trusted_projects.json"
  end
  return "/tmp/bitty/wheel_trusted_projects.json"
end

--- Read trust store JSON table.
--- @param path_override string? Optional custom trust store file path
--- @return table
function WheelConfig.read_trust_store(path_override)
  local path = path_override or WheelConfig.get_trust_store_path()
  local raw = read_file(path)
  if not raw or raw == "" then
    return {}
  end
  local K = get_kernel()
  local ok, data = pcall(function() return K.JSON.decode(raw) end)
  if ok and type(data) == "table" then
    return data
  end
  return {}
end

--- Save trust store JSON table.
--- @param store table
--- @param path_override string? Optional custom trust store file path
--- @return boolean success
function WheelConfig.write_trust_store(store, path_override)
  local path = path_override or WheelConfig.get_trust_store_path()
  local K = get_kernel()
  local json_str = K.JSON.encode(store or {})
  -- Ensure parent directory exists if using standard mkdir
  os.execute("mkdir -p \"$(dirname '" .. path .. "')\" 2>/dev/null")
  return write_file(path, json_str)
end

--- Normalize a path string for trust store matching.
local function normalize_path(path)
  if not path or path == "" then return "." end
  local p = string.gsub(path, "/+$", "")
  return p
end

--- Check if a project configuration is trusted.
--- @param project_root string
--- @param content string? Optional config content; if omitted, reads file
--- @param trust_file string? Optional trust store path override
--- @return boolean is_trusted, string current_hash, string? trusted_hash
function WheelConfig.is_trusted(project_root, content, trust_file)
  local path = WheelConfig.get_project_config_path(project_root)
  if not content then
    content = read_file(path)
  end
  if not content then
    return false, "", nil
  end
  local current_hash = WheelConfig.compute_hash(content)
  local store = WheelConfig.read_trust_store(trust_file)
  local key = normalize_path(project_root)
  local trusted_hash = store[key]
  if trusted_hash and trusted_hash == current_hash then
    return true, current_hash, trusted_hash
  end
  return false, current_hash, trusted_hash
end

--- Mark a project configuration as trusted (direnv-style explicit trust action).
--- @param project_root string
--- @param content string? Optional config content; if omitted, reads file
--- @param trust_file string? Optional trust store path override
--- @return boolean success, string? error, string? hash
function WheelConfig.trust(project_root, content, trust_file)
  local path = WheelConfig.get_project_config_path(project_root)
  if not content then
    content = read_file(path)
  end
  if not content then
    return false, "project config file not found: " .. path, nil
  end
  local hash = WheelConfig.compute_hash(content)
  local store = WheelConfig.read_trust_store(trust_file)
  local key = normalize_path(project_root)
  store[key] = hash
  local ok = WheelConfig.write_trust_store(store, trust_file)
  if ok then
    return true, nil, hash
  else
    return false, "failed to persist trust store", nil
  end
end

--- Revoke trust for a project configuration.
--- @param project_root string
--- @param trust_file string? Optional trust store path override
--- @return boolean success
function WheelConfig.untrust(project_root, trust_file)
  local store = WheelConfig.read_trust_store(trust_file)
  local key = normalize_path(project_root)
  store[key] = nil
  return WheelConfig.write_trust_store(store, trust_file)
end

--- Safely evaluate a Lua configuration string in a sandboxed environment.
local function eval_config_chunk(content, chunk_name)
  local load_fn = loadstring or load
  local chunk, err = load_fn(content, chunk_name)
  if not chunk then
    return false, "syntax error in " .. chunk_name .. ": " .. tostring(err)
  end

  -- Sandbox environment restricting ambient authority
  local env = {
    ipairs = ipairs,
    pairs = pairs,
    type = type,
    tostring = tostring,
    tonumber = tonumber,
    string = string,
    table = table,
    math = math,
    pcall = pcall,
    xpcall = xpcall,
    select = select,
    unpack = unpack or table.unpack,
  }
  setfenv(chunk, env)

  local ok, res = pcall(chunk)
  if not ok then
    return false, "runtime error in " .. chunk_name .. ": " .. tostring(res)
  end
  if type(res) ~= "table" then
    return false, chunk_name .. " must return a table, got " .. type(res)
  end
  return true, res
end

WheelConfig.eval_chunk = eval_config_chunk

--- Discover portable capabilities in .agents/ (Reference-not-copy rule).
--- Scans <workspace_root>/.agents/skills/ and applies skill filtering policies.
--- @param workspace_root string
--- @param filter table? Optional skill filter { enabled = table, disabled = table }
--- @return table { skills = table, count = number }
function WheelConfig.discover_agent_capabilities(workspace_root, filter)
  workspace_root = workspace_root or "."
  workspace_root = string.gsub(workspace_root, "/+$", "")
  local skills_dir = workspace_root .. "/.agents/skills"
  local filter_enabled = (filter and filter.enabled) or {}
  local filter_disabled = (filter and filter.disabled) or {}

  local disabled_map = {}
  for _, name in ipairs(filter_disabled) do
    disabled_map[name] = true
  end

  local enabled_whitelist = false
  local enabled_map = {}
  if #filter_enabled > 0 then
    enabled_whitelist = true
    for _, name in ipairs(filter_enabled) do
      enabled_map[name] = true
    end
  end

  local discovered = {}
  -- Scan skills directory if accessible via directory list or ls
  local handle = io.popen("ls -1 \"" .. skills_dir .. "\" 2>/dev/null")
  if handle then
    for entry in handle:lines() do
      local skill_path = skills_dir .. "/" .. entry .. "/SKILL.md"
      local skill_file = io.open(skill_path, "r")
      if skill_file then
        skill_file:close()
        local is_allowed = true
        if disabled_map[entry] then
          is_allowed = false
        elseif enabled_whitelist and not enabled_map[entry] then
          is_allowed = false
        end

        if is_allowed then
          table.insert(discovered, {
            name = entry,
            path = skill_path,
            origin = ".agents/skills",
          })
        end
      end
    end
    handle:close()
  end

  return {
    skills = discovered,
    count = #discovered,
  }
end

--- Load and resolve configuration with hierarchical layering:
--- Defaults (Layer 0) < Global (Layer 1) < Project (Layer 2, overrides global) < Explicit opts.
--- Enforces security trust gate: untrusted project configurations will NOT be executed.
--- @param opts table?
---   opts.project_root string?: Project root directory (default: ".")
---   opts.global_path string?: Custom global config path
---   opts.trust_mode string?: "strict" (default) or "permissive"
---   opts.trusted boolean?: If true, bypasses trust store check (e.g. CLI explicit approval)
--- @return table { ok = boolean, config = table, layers = table, error = string?, trusted = boolean? }
function WheelConfig.load(opts)
  opts = opts or {}
  local project_root = opts.project_root or "."
  local trust_mode = opts.trust_mode or "strict"
  local layers_loaded = { defaults = true, global = false, project = false }
  local active_config = deep_copy(WheelConfig.DEFAULTS)

  -- 1. Layer 1: Global configuration (~/.config/wheel/init.lua)
  local global_path = opts.global_path or WheelConfig.get_global_config_path()
  if global_path then
    local global_content = read_file(global_path)
    if global_content and global_content ~= "" then
      local ok, global_tbl = eval_config_chunk(global_content, global_path)
      if ok and type(global_tbl) == "table" then
        active_config = deep_merge(active_config, global_tbl)
        layers_loaded.global = true
      end
    end
  end

  -- 2. Layer 2: Project configuration (<project_root>/.wheel/init.lua)
  local project_path = WheelConfig.get_project_config_path(project_root)
  local project_content = read_file(project_path)
  local project_trusted = false

  if project_content and project_content ~= "" then
    local current_hash = WheelConfig.compute_hash(project_content)
    if opts.trusted then
      project_trusted = true
    elseif trust_mode == "permissive" then
      project_trusted = true
    else
      local trusted, _, _ = WheelConfig.is_trusted(project_root, project_content, opts.trust_file)
      project_trusted = trusted
    end

    if not project_trusted then
      return {
        ok = false,
        error = "untrusted_project_config",
        message = "Project configuration at " .. project_path .. " is untrusted. Run `wheel trust` or inspect before loading.",
        path = project_path,
        hash = current_hash,
        config = active_config, -- Fallback to safe defaults + global
        layers = layers_loaded,
        trusted = false,
      }
    end

    -- Project config is trusted: execute safely
    local ok, project_tbl = eval_config_chunk(project_content, project_path)
    if not ok then
      return {
        ok = false,
        error = "project_config_eval_error",
        message = tostring(project_tbl),
        path = project_path,
        config = active_config,
        layers = layers_loaded,
        trusted = true,
      }
    end

    -- Project config takes precedence over Global and Defaults!
    active_config = deep_merge(active_config, project_tbl)
    layers_loaded.project = true
  end

  -- 3. Discover portable capabilities from .agents/
  local agent_caps = WheelConfig.discover_agent_capabilities(project_root, active_config.skills)
  active_config.discovered_capabilities = agent_caps

  return {
    ok = true,
    config = active_config,
    layers = layers_loaded,
    trusted = project_trusted or false,
    project_path = project_content and project_path or nil,
  }
end

return WheelConfig
