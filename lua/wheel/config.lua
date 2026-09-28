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

local function sha256_pure(msg)
  local bit = nil
  if type(bit32) == "table" then
    bit = bit32
  else
    local ok, b = pcall(require, "bit")
    if ok and type(b) == "table" then bit = b end
  end

  local band, bor, bxor, bnot, rshift, ror
  if bit then
    band = bit.band
    bor = bit.bor
    bxor = bit.bxor
    bnot = bit.bnot
    rshift = bit.rshift
    ror = bit.ror or function(x, n)
      return bor(rshift(x, n), bit.lshift(x, 32 - n))
    end
  else
    local MOD = 4294967296
    local function to_bits(n)
      local t = {}
      for i = 1, 32 do
        local r = n % 2
        t[i] = r
        n = (n - r) / 2
      end
      return t
    end
    local function from_bits(t)
      local n = 0
      local p = 1
      for i = 1, 32 do
        if t[i] == 1 then n = n + p end
        p = p * 2
      end
      return n
    end
    band = function(a, b)
      local ta, tb = to_bits(a % MOD), to_bits(b % MOD)
      local tr = {}
      for i = 1, 32 do tr[i] = (ta[i] == 1 and tb[i] == 1) and 1 or 0 end
      return from_bits(tr)
    end
    bor = function(a, b)
      local ta, tb = to_bits(a % MOD), to_bits(b % MOD)
      local tr = {}
      for i = 1, 32 do tr[i] = (ta[i] == 1 or tb[i] == 1) and 1 or 0 end
      return from_bits(tr)
    end
    bxor = function(a, b)
      local ta, tb = to_bits(a % MOD), to_bits(b % MOD)
      local tr = {}
      for i = 1, 32 do tr[i] = (ta[i] ~= tb[i]) and 1 or 0 end
      return from_bits(tr)
    end
    bnot = function(a) return (MOD - 1 - (a % MOD)) end
    rshift = function(a, n) return math.floor((a % MOD) / (2 ^ n)) end
    ror = function(a, n)
      local ta = to_bits(a % MOD)
      local tr = {}
      for i = 1, 32 do
        local src = i + n
        if src > 32 then src = src - 32 end
        tr[i] = ta[src]
      end
      return from_bits(tr)
    end
  end

  local K = {
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2
  }

  local H0, H1, H2, H3, H4, H5, H6, H7 =
    0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
    0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19

  local len = #msg
  local bitlen = len * 8

  local pad = msg .. string.char(0x80)
  local rem = (#pad) % 64
  local zeros = (56 - rem) % 64
  pad = pad .. string.rep(string.char(0), zeros)

  local high = math.floor(bitlen / 4294967296) % 4294967296
  local low = bitlen % 4294967296
  pad = pad .. string.char(
    math.floor(high / 16777216) % 256,
    math.floor(high / 65536) % 256,
    math.floor(high / 256) % 256,
    high % 256,
    math.floor(low / 16777216) % 256,
    math.floor(low / 65536) % 256,
    math.floor(low / 256) % 256,
    low % 256
  )

  local W = {}
  local num_blocks = #pad / 64
  for b = 0, num_blocks - 1 do
    local offset = b * 64
    for t = 0, 15 do
      local idx = offset + t * 4 + 1
      local b1, b2, b3, b4 = string.byte(pad, idx, idx + 3)
      W[t + 1] = (((b1 * 256 + b2) * 256 + b3) * 256 + b4) % 4294967296
    end
    for t = 16, 63 do
      local w_t_minus_15 = W[t - 15 + 1]
      local w_t_minus_2 = W[t - 2 + 1]
      local s0 = bxor(bxor(ror(w_t_minus_15, 7), ror(w_t_minus_15, 18)), rshift(w_t_minus_15, 3))
      local s1 = bxor(bxor(ror(w_t_minus_2, 17), ror(w_t_minus_2, 19)), rshift(w_t_minus_2, 10))
      W[t + 1] = (W[t - 16 + 1] + s0 + W[t - 7 + 1] + s1) % 4294967296
    end

    local a, b_val, c, d, e, f, g, h = H0, H1, H2, H3, H4, H5, H6, H7
    for t = 0, 63 do
      local S1 = bxor(bxor(ror(e, 6), ror(e, 11)), ror(e, 25))
      local ch = bxor(band(e, f), band(bnot(e), g))
      local temp1 = (h + S1 + ch + K[t + 1] + W[t + 1]) % 4294967296
      local S0 = bxor(bxor(ror(a, 2), ror(a, 13)), ror(a, 22))
      local maj = bxor(bxor(band(a, b_val), band(a, c)), band(b_val, c))
      local temp2 = (S0 + maj) % 4294967296

      h = g
      g = f
      f = e
      e = (d + temp1) % 4294967296
      d = c
      c = b_val
      b_val = a
      a = (temp1 + temp2) % 4294967296
    end

    H0 = (H0 + a) % 4294967296
    H1 = (H1 + b_val) % 4294967296
    H2 = (H2 + c) % 4294967296
    H3 = (H3 + d) % 4294967296
    H4 = (H4 + e) % 4294967296
    H5 = (H5 + f) % 4294967296
    H6 = (H6 + g) % 4294967296
    H7 = (H7 + h) % 4294967296
  end

  return string.format("%08x%08x%08x%08x%08x%08x%08x%08x", H0, H1, H2, H3, H4, H5, H6, H7)
end

--- Deterministic cryptographic SHA-256 content hash (pure Lua, zero external deps).
function WheelConfig.compute_hash(str)
  if type(str) ~= "string" then str = tostring(str or "") end
  return sha256_pure(str)
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

local function shell_quote(value)
  return "'" .. string.gsub(tostring(value or ""), "'", "'\\''") .. "'"
end

--- Save trust store JSON table.
--- @param store table
--- @param path_override string? Optional custom trust store file path
--- @return boolean success
function WheelConfig.write_trust_store(store, path_override)
  local path = path_override or WheelConfig.get_trust_store_path()
  local K = get_kernel()
  local json_str = K.JSON.encode(store or {})
  -- Ensure parent directory exists safely without shell injection
  local parent_dir = string.match(path, "^(.*)/[^/]+$")
  if parent_dir and parent_dir ~= "" then
    os.execute("mkdir -p -- " .. shell_quote(parent_dir) .. " 2>/dev/null")
  end
  return write_file(path, json_str)
end

--- Normalize a path string to an absolute canonical path for trust store matching.
local function normalize_path(path)
  if not path or path == "" or path == "." then
    local pwd = os.getenv("PWD")
    if pwd and pwd ~= "" then
      path = pwd
    else
      path = "."
    end
  elseif string.sub(path, 1, 1) ~= "/" then
    local pwd = os.getenv("PWD")
    if pwd and pwd ~= "" then
      path = pwd .. "/" .. path
    end
  end
  local p = string.gsub(path, "\\", "/")
  p = string.gsub(p, "/%./", "/")
  p = string.gsub(p, "/+", "/")
  p = string.gsub(p, "/+$", "")
  if p == "" then return "/" end
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
  local function copy_library(lib)
    local c = {}
    for k, v in pairs(lib or {}) do
      c[k] = v
    end
    return c
  end

  local string_copy = copy_library(string)
  local orig_rep = string_copy.rep
  string_copy.rep = function(s, n, sep)
    if type(n) == "number" and n > 65536 then
      error("string.rep count exceeds safety bound (max 65536)", 2)
    end
    return orig_rep(s, n, sep)
  end

  -- Sandbox environment restricting ambient authority and isolating standard libraries
  local env = {
    ipairs = ipairs,
    pairs = pairs,
    type = type,
    tostring = tostring,
    tonumber = tonumber,
    string = string_copy,
    table = copy_library(table),
    math = copy_library(math),
    pcall = pcall,
    xpcall = xpcall,
    select = select,
    unpack = unpack or table.unpack,
  }

  local chunk, err
  if setfenv then
    local load_fn = loadstring or load
    chunk, err = load_fn(content, chunk_name)
    if chunk then
      setfenv(chunk, env)
    end
  else
    chunk, err = load(content, chunk_name, "t", env)
  end

  if not chunk then
    return false, "syntax error in " .. chunk_name .. ": " .. tostring(err)
  end

  local hook_installed = false
  if debug and debug.sethook then
    debug.sethook(function()
      error("configuration execution exceeded instruction limit", 2)
    end, "", 100000)
    hook_installed = true
  end

  local ok, res = pcall(chunk)

  if hook_installed and debug and debug.sethook then
    debug.sethook()
  end

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
  -- Scan skills directory safely with shell_quote
  local handle = io.popen("ls -1 -- " .. shell_quote(skills_dir) .. " 2>/dev/null")
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
