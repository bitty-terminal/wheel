-- Wheel Configuration Loader
-- Implements hierarchical configuration layering, the 8 function classes,
-- direnv-style security trust gates, and headless panel container policies
-- per bitty-ai-docs specifications.

local WheelKernel = nil
local WheelErrors = require("wheel.errors")
local WheelHost

local ok_host, host_or_err = pcall(require, "wheel.host")
if ok_host then
  WheelHost = host_or_err
else
  -- Lua 5.1 leaves a load sentinel after a failed require; clear it so the
  -- alternate root (and later tool/provider loaders) see the real cause.
  package.loaded["wheel.host"] = nil
  local cause = host_or_err
  if WheelErrors.is_typed(cause) then
    error(cause, 0)
  end
  if type(cause) ~= "string"
    or not cause:find("module 'wheel.host' not found", 1, true) then
    error("wheel.config: cannot load submodule 'wheel.host': " .. tostring(cause), 0)
  end

  local ok_alt, alternate = pcall(require, "lua.wheel.host")
  if ok_alt then
    WheelHost = alternate
  else
    package.loaded["lua.wheel.host"] = nil
    if WheelErrors.is_typed(alternate) then
      error(alternate, 0)
    end
    if type(alternate) == "string"
      and alternate:find("module 'lua.wheel.host' not found", 1, true) then
      -- Standalone config remains usable without the host seam; the caller
      -- fails closed if it reaches a host-dependent operation.
      WheelHost = nil
    else
      error("wheel.config: cannot load submodule 'wheel.host': " .. tostring(alternate), 0)
    end
  end
end

local function get_kernel()
  if not WheelKernel then
    local rooted = "wheel.kernel"
    local ok, mod = pcall(require, rooted)
    if ok then
      WheelKernel = mod
    else
      local cause = mod
      if type(cause) ~= "string"
        or not cause:find("module '" .. rooted .. "' not found", 1, true) then
        error("wheel.config: cannot load submodule '" .. rooted .. "': " .. tostring(cause), 0)
      end

      local alternate = "lua.wheel.kernel"
      ok, mod = pcall(require, alternate)
      if ok then
        WheelKernel = mod
      else
        if type(mod) == "string"
          and mod:find("module '" .. alternate .. "' not found", 1, true) then
          mod = cause
        end
        error("wheel.config: cannot load submodule '" .. rooted .. "': " .. tostring(mod), 0)
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

--- Extended daily-driver runtime defaults merged by load/resolve_effective_config
-- without modifying the 8 canonical function classes in DEFAULTS.
WheelConfig.RUNTIME_DEFAULTS = {
  default_provider = "opencode-go",
  thinking = "off",
  providers = {},
  commands = {},
  custom_tools = {},
  global_skills = {},
  permissions = {
    read_file = "allow",
    list_directory = "allow",
    search_code = "allow",
    read_blob = "allow",
    write_file = "allow",
    edit_file = "allow",
    run_command = "ask",
  },
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

-- ---------------------------------------------------------------------------
-- Security bounds for executable project configuration
-- ---------------------------------------------------------------------------

-- Maximum accepted `.wheel/init.lua` size. The consent view reads at most
-- `MAX_PROJECT_CONFIG_BYTES + 1` bytes so a larger entry is refused without
-- loading it whole. A 32 KiB entry is far above a practical configuration and
-- small enough that a native hash is effectively instantaneous.
WheelConfig.MAX_PROJECT_CONFIG_BYTES = 32 * 1024

-- Maximum accepted trust-store file size. The store contains the approved
-- entry content for the change diff, so it is larger than one entry but still
-- bounded; a store above this size is corrupt for this harness.
WheelConfig.MAX_TRUST_STORE_BYTES = 1024 * 1024

-- Maximum number of projects recorded in one trust store.
WheelConfig.MAX_TRUST_STORE_PROJECTS = 256

-- Best-effort evaluation memory bounds. These are per-call and cumulative caps
-- for the two allocation-prone library functions exposed to a project entry
-- (`string.rep` and `table.concat`). They are not a general Lua heap limit:
-- concatenation, formatting, pattern captures, and table growth outside these
-- wrappers remain bounded only by the instruction hook. A killable evaluation
-- subprocess is the durable fix and remains open.
WheelConfig.MAX_EVAL_STRING_BYTES = 1024 * 1024
WheelConfig.MAX_EVAL_TOTAL_STRING_BYTES = 4 * 1024 * 1024

local HASH_HEX_PATTERN = "^%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x"
  .. "%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x"
  .. "%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x"
  .. "%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x$"

local SHA256_MATCH_PATTERN = "(%x" .. string.rep("%x", 63) .. ")"

local function is_sha256_hex(value)
  return type(value) == "string" and value:match(HASH_HEX_PATTERN) ~= nil
end

local function trim_output(value)
  if type(value) ~= "string" then
    return ""
  end
  return (value:gsub("%s+$", ""))
end

local function has_control_chars(value)
  return type(value) == "string" and value:find("[%z\1-\31\127]") ~= nil
end

--- Return true when a POSIX mode grants group or world write permission.
-- Mode values are the decimal form of the octal permission bits. Bit 4 of the
-- group digit is 0o020 (16) and bit 1 of the world digit is 0o002 (2).
-- @param mode number?
-- @return boolean
local function mode_is_group_or_world_writable(mode)
  if type(mode) ~= "number" then
    return true
  end
  return math.floor(mode / 16) % 2 == 1 or math.floor(mode / 2) % 2 == 1
end

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

--- Return the host seam, failing closed when it did not load.
-- Configuration file access has no direct surface of its own: every read and
-- write goes through WheelHost, so a missing seam is a typed denial.
-- @param capability string
-- @return table
local function require_host(capability)
  if not WheelHost then
    error(WheelErrors.capability_denied(capability), 0)
  end
  return WheelHost
end

--- Read file content safely.
local function read_file(filepath)
  local content = require_host("fs.read").fs.read_file(filepath)
  return content
end

--- Write file content safely.
local function write_file(filepath, content)
  local ok = require_host("fs.write").fs.write_file(filepath, content)
  return ok == true
end

--- Read an environment variable through the checked host surface.
local function getenv(name)
  if type(os) ~= "table" or type(os.getenv) ~= "function" then
    error(WheelErrors.capability_denied("env.read"), 0)
  end
  return os.getenv(name)
end

--- Cheap file-existence check through the host seam.
local function file_exists(filepath)
  return require_host("fs.read").fs.exists(filepath)
end

local function trust_error(code, message)
  return { code = code, message = message }
end

local function empty_trust_store()
  return { version = 1, projects = {} }
end

--- Hash exact bytes with a native SHA-256 utility when one is available.
-- The content is written to a private temporary file so the utility hashes the
-- exact bytes that will be evaluated; the caller's project entry is never read
-- a second time. `tmp.create` creates the file exclusively with mode 0600 in
-- the harness-owned 0700 runtime directory, so a pre-existing path or symlink
-- is refused. The file is removed before returning; a cleanup failure is
-- fail-closed (nil digest) so the bounded pure-Lua path is used instead of
-- reporting success while leaving private bytes behind. Returns nil when no
-- native implementation can produce a digest.
-- @param content string
-- @return string? lowercase 64-hex digest
local function native_sha256(content)
  local host = require_host("fs.read")
  local ok_tmp, temp = pcall(function()
    return host.tmp.create(content)
  end)
  if not ok_tmp or type(temp) ~= "string" or temp == "" then
    return nil
  end

  local digest = nil
  local candidates = {
    { "sha256sum", { "--", temp } },
    { "shasum", { "-a", "256", "--", temp } },
    { "openssl", { "dgst", "-sha256", temp } },
  }
  for _, candidate in ipairs(candidates) do
    local call_ok, res = pcall(host.proc.run_program,
      candidate[1], candidate[2], { discard_stderr = true })
    if call_ok and res.ok and res.code == 0 then
      local found = (res.stdout or ""):match(SHA256_MATCH_PATTERN)
      if found then
        digest = found:lower()
        break
      end
    end
  end

  local removed = host.fs.remove_file(temp)
  if removed ~= true then
    -- Do not leave a 0600 copy of project configuration behind when the
    -- unlink fails; blanking it is best-effort and the digest still fails
    -- closed to the bounded pure-Lua path.
    pcall(function()
      host.fs.write_file(temp, "")
    end)
    return nil
  end
  return digest
end

--- Hash project configuration bytes.
-- Native SHA-256 is the normal path. The pure-Lua implementation is the
-- documented fallback when no `sha256sum`, `shasum`, or `openssl` is available;
-- it can take seconds at the 32 KiB cap on PUC Lua 5.1, so the bounded reader
-- above is what keeps that fallback from ever hashing an unbounded entry.
-- @param content string
-- @return string? lowercase 64-hex digest
function WheelConfig.compute_content_hash(content)
  if type(content) ~= "string" then content = tostring(content or "") end
  local native = native_sha256(content)
  if native then
    return native
  end
  if #content <= WheelConfig.MAX_PROJECT_CONFIG_BYTES then
    return sha256_pure(content)
  end
  return nil
end

--- Resolve a path to the current process's uid for store ownership checks.
local function current_uid()
  local res = require_host("process.spawn").proc.run_program(
    "id", { "-u" }, { discard_stderr = true })
  if res.ok and res.code == 0 then
    return tonumber(trim_output(res.stdout))
  end
  return nil
end

--- Verify that an existing store file or directory is user-owned and not
-- group- or world-writable.
-- @param info table `WheelHost.fs.stat` result
-- @param label string
-- @return boolean ok, table? err
local function check_store_owner(info, label, skip_mode_check)
  if type(info.uid) ~= "number" then
    return false, trust_error("E_TRUST_STORE_OWNER_UNVERIFIABLE",
      "cannot determine ownership for " .. label)
  end
  local uid = current_uid()
  if not uid then
    return false, trust_error("E_TRUST_STORE_OWNER_UNVERIFIABLE",
      "cannot determine the current uid for " .. label)
  end
  if info.uid ~= uid then
    return false, trust_error("E_TRUST_STORE_FOREIGN_OWNED",
      label .. " is not owned by the current user")
  end
  if not skip_mode_check then
    if type(info.mode) ~= "number" then
      return false, trust_error("E_TRUST_STORE_OWNER_UNVERIFIABLE",
        "cannot determine permissions for " .. label)
    end
    if mode_is_group_or_world_writable(info.mode) then
      return false, trust_error("E_TRUST_STORE_PERMISSIONS",
        label .. " is group- or world-writable")
    end
  end
  return true, nil
end

--- Normalize a decoded trust store to schema version 1.
-- A legacy flat store (`{root = "hash"}`) is accepted as hash-only metadata.
-- Unknown or malformed entries make the whole store corrupt so it cannot be
-- silently treated as empty.
-- @param data table
-- @return table? store, table? err
local function normalize_trust_store(data)
  if type(data) ~= "table" then
    return nil, trust_error("E_TRUST_STORE_CORRUPT", "trust store root is not an object")
  end

  local projects
  if data.version ~= nil then
    if data.version ~= 1 then
      return nil, trust_error("E_TRUST_STORE_VERSION",
        "unsupported trust store schema version " .. tostring(data.version))
    end
    if type(data.projects) ~= "table" then
      return nil, trust_error("E_TRUST_STORE_CORRUPT", "trust store projects is not an object")
    end
    projects = data.projects
  else
    -- Legacy flat map. An empty file/no entries is an empty store.
    projects = {}
    for key, value in pairs(data) do
      projects[key] = value
    end
  end

  local store = empty_trust_store()
  local count = 0
  for key, value in pairs(projects) do
    if type(key) ~= "string" or key == "" or key:sub(1, 1) ~= "/" or has_control_chars(key) then
      return nil, trust_error("E_TRUST_STORE_CORRUPT",
        "trust store contains a project key that is not a canonical absolute path")
    end

    local entry
    if type(value) == "string" then
      entry = { hash = value }
    elseif type(value) == "table" then
      entry = {
        hash = value.hash,
        content = value.content,
        approved_at = value.approved_at,
      }
      if entry.content ~= nil and type(entry.content) ~= "string" then
        return nil, trust_error("E_TRUST_STORE_CORRUPT",
          "trust store entry for a project has non-string content")
      end
      if entry.content ~= nil and #entry.content > WheelConfig.MAX_PROJECT_CONFIG_BYTES then
        return nil, trust_error("E_TRUST_STORE_CORRUPT",
          "trust store entry content exceeds the project configuration cap")
      end
      if entry.approved_at ~= nil
        and type(entry.approved_at) ~= "string"
        and type(entry.approved_at) ~= "number" then
        return nil, trust_error("E_TRUST_STORE_CORRUPT",
          "trust store entry has an invalid approval timestamp")
      end
    else
      return nil, trust_error("E_TRUST_STORE_CORRUPT",
        "trust store entry for a project is not an object")
    end

    if not is_sha256_hex(entry.hash) then
      return nil, trust_error("E_TRUST_STORE_CORRUPT",
        "trust store entry does not contain a full 64-hex SHA-256 hash")
    end
    count = count + 1
    if count > WheelConfig.MAX_TRUST_STORE_PROJECTS then
      return nil, trust_error("E_TRUST_STORE_CORRUPT",
        "trust store contains more than " .. WheelConfig.MAX_TRUST_STORE_PROJECTS .. " projects")
    end
    store.projects[key] = entry
  end

  return store, nil
end

local PROVIDER_API_KEY_ENV = {
  ["opencode-go"] = "OPENCODE_GO_API_KEY",
  openai = "OPENAI_API_KEY",
  anthropic = "ANTHROPIC_API_KEY",
  deepseek = "DEEPSEEK_API_KEY",
  openrouter = "OPENROUTER_API_KEY",
}

local PERMISSION_SEVERITY = {
  allow = 1,
  ask = 2,
  deny = 3,
}

local function lookup_env(name, env)
  if type(env) == "table" and env[name] ~= nil then
    return env[name]
  end
  if type(env) == "table" then
    return nil
  end
  return getenv(name)
end

--- Resolve global configuration directory (~/.config/wheel or $XDG_CONFIG_HOME/wheel).
function WheelConfig.get_global_config_dir(env)
  local xdg_config = lookup_env("XDG_CONFIG_HOME", env)
  if xdg_config and xdg_config ~= "" then
    return string.gsub(xdg_config, "/+$", "") .. "/wheel"
  end
  local home = lookup_env("HOME", env) or ""
  if home ~= "" then
    return string.gsub(home, "/+$", "") .. "/.config/wheel"
  end
  return nil
end

--- Resolve global configuration path (~/.config/wheel/init.lua or $XDG_CONFIG_HOME/wheel/init.lua).
function WheelConfig.get_global_config_path(env)
  local dir = WheelConfig.get_global_config_dir(env)
  if not dir then return nil end
  return dir .. "/init.lua"
end

--- Resolve private Wheel data directory (~/.local/share/wheel or $XDG_DATA_HOME/wheel).
function WheelConfig.get_data_dir(env)
  local xdg_data = lookup_env("XDG_DATA_HOME", env)
  if xdg_data and xdg_data ~= "" then
    return string.gsub(xdg_data, "/+$", "") .. "/wheel"
  end
  local home = lookup_env("HOME", env) or ""
  if home ~= "" then
    return string.gsub(home, "/+$", "") .. "/.local/share/wheel"
  end
  return nil
end

local function store_error(code, message)
  return trust_error(code, message)
end

local function ensure_private_data_dir(host, dir_path)
  if not dir_path or dir_path == "" or has_control_chars(dir_path) then
    return false, store_error("E_DATA_STORE_UNAVAILABLE", "data directory path is unavailable")
  end
  if not host.fs.mkdir_p(dir_path) then
    return false, store_error("E_DATA_STORE_WRITE_FAILED", "cannot create data directory")
  end
  local info = host.fs.stat(dir_path)
  if not info or not info.exists then
    return false, store_error("E_DATA_STORE_WRITE_FAILED", "data directory unavailable after creation")
  end
  if info.symlink then
    return false, store_error("E_DATA_STORE_SYMLINK", "data directory is a symbolic link")
  end
  if not info.directory then
    return false, store_error("E_DATA_STORE_NOT_DIR", "data path is not a directory")
  end
  local ok_owner, owner_err = check_store_owner(info, "wheel data directory", true)
  if not ok_owner then
    return false, owner_err
  end
  if host.fs.chmod(dir_path, "700") ~= true then
    return false, store_error("E_DATA_STORE_WRITE_FAILED", "cannot set wheel data directory to 0700")
  end
  local after = host.fs.stat(dir_path)
  local ok_after, after_err = check_store_owner(after, "wheel data directory")
  if not ok_after then
    return false, after_err
  end
  return true, nil
end

local function read_private_json_store(filepath, label)
  if not filepath then
    return {}, nil
  end
  local host = require_host("fs.read")
  local info = host.fs.stat(filepath)
  if not info or not info.exists then
    return {}, nil
  end
  if info.symlink then
    return nil, store_error("E_DATA_STORE_SYMLINK", label .. " is a symbolic link")
  end
  if not info.regular then
    return nil, store_error("E_DATA_STORE_NOT_REGULAR", label .. " is not a regular file")
  end
  if info.mode ~= 384 then
    return nil, store_error("E_DATA_STORE_MODE", label .. " must have mode 0600")
  end
  local ok_owner, owner_err = check_store_owner(info, label)
  if not ok_owner then
    return nil, owner_err
  end
  local content, rerr = host.fs.read_file_bounded(filepath, 1024 * 1024 + 1)
  if not content then
    return nil, store_error("E_DATA_STORE_UNREADABLE", label .. " could not be read: " .. tostring(rerr))
  end
  if #content > 1024 * 1024 then
    return nil, store_error("E_DATA_STORE_TOO_LARGE", label .. " exceeds 1 MiB cap")
  end
  if content:match("^%s*$") then
    return {}, nil
  end
  local K = get_kernel()
  local ok_dec, decoded = pcall(K.JSON.decode, content)
  if not ok_dec or type(decoded) ~= "table" then
    return nil, store_error("E_DATA_STORE_CORRUPT", label .. " contains invalid JSON")
  end
  return decoded, nil
end

local function write_private_json_store(dir_path, filepath, data, label)
  if type(data) ~= "table" then
    return false, store_error("E_DATA_STORE_INVALID", label .. " data must be a table")
  end
  local host = require_host("fs.write")
  local ok_dir, dir_err = ensure_private_data_dir(host, dir_path)
  if not ok_dir then
    return false, dir_err
  end
  local info = host.fs.stat(filepath)
  if info and info.exists then
    if info.symlink then
      return false, store_error("E_DATA_STORE_SYMLINK", "refusing to replace symlinked " .. label)
    end
    if not info.regular then
      return false, store_error("E_DATA_STORE_NOT_REGULAR", "refusing to replace non-regular " .. label)
    end
    local ok_owner, owner_err = check_store_owner(info, label, true)
    if not ok_owner then
      return false, owner_err
    end
  end
  local K = get_kernel()
  local encoded = K.JSON.encode(data) .. "\n"
  local now_s = (host.time and host.time.now and host.time.now()) or 0
  local tmp_suffix = tostring(now_s) .. "-" .. tostring(math.random(100000, 999999))
  if type(host.fs.random_bytes) == "function" then
    local ok_rb, rb = pcall(host.fs.random_bytes, 6)
    if ok_rb and type(rb) == "string" and #rb >= 6 then
      local hx = {}
      for i = 1, 6 do hx[i] = string.format("%02x", string.byte(rb, i)) end
      tmp_suffix = table.concat(hx, "")
    end
  end
  local tmp_path = filepath .. ".tmp." .. tmp_suffix
  if not host.fs.create_private_file(tmp_path, encoded) then
    pcall(host.fs.remove_file, tmp_path)
    return false, store_error("E_DATA_STORE_WRITE_FAILED", "failed to create private temp file for " .. label)
  end
  if not host.fs.rename(tmp_path, filepath) then
    pcall(host.fs.remove_file, tmp_path)
    return false, store_error("E_DATA_STORE_WRITE_FAILED", "failed to finalize private " .. label)
  end
  if host.fs.chmod(filepath, "600") ~= true then
    return false, store_error("E_DATA_STORE_WRITE_FAILED", "failed to chmod 0600 on " .. label)
  end
  local after = host.fs.stat(filepath)
  if not after or after.symlink or not after.regular or after.mode ~= 384 then
    return false, store_error("E_DATA_STORE_MODE", label .. " failed post-write 0600 verification")
  end
  return true, nil
end

--- Read private runtime settings from $XDG_DATA_HOME/wheel/settings.json.
function WheelConfig.read_data_settings(opts)
  opts = opts or {}
  local data_dir = opts.data_dir or WheelConfig.get_data_dir(opts.env)
  if not data_dir then return {}, nil end
  return read_private_json_store(data_dir .. "/settings.json", "wheel settings store")
end

--- Persist private runtime settings to 0700/0600 $XDG_DATA_HOME/wheel/settings.json.
function WheelConfig.write_data_settings(settings, opts)
  opts = opts or {}
  local data_dir = opts.data_dir or WheelConfig.get_data_dir(opts.env)
  if not data_dir then
    return false, store_error("E_DATA_STORE_UNAVAILABLE", "XDG_DATA_HOME and HOME are unset")
  end
  return write_private_json_store(data_dir, data_dir .. "/settings.json", settings, "wheel settings store")
end

--- Read private provider credentials from $XDG_DATA_HOME/wheel/credentials.json (0600 enforced).
function WheelConfig.read_credentials(opts)
  opts = opts or {}
  local data_dir = opts.data_dir or WheelConfig.get_data_dir(opts.env)
  if not data_dir then return {}, nil end
  local raw, err = read_private_json_store(data_dir .. "/credentials.json", "wheel credentials store")
  if not raw then return nil, err end
  local creds = type(raw.providers) == "table" and raw.providers or raw
  return creds, nil
end

--- Store or update a provider credential in 0700/0600 $XDG_DATA_HOME/wheel/credentials.json.
function WheelConfig.write_credential(provider_name, api_key, opts)
  opts = opts or {}
  if type(provider_name) ~= "string" or not provider_name:match("^[A-Za-z0-9_%-]+$") then
    return false, store_error("E_ARGS_INVALID", "invalid provider name")
  end
  if type(api_key) ~= "string" or api_key == "" or has_control_chars(api_key) then
    return false, store_error("E_ARGS_INVALID", "API key must be a non-empty single-line string")
  end
  local data_dir = opts.data_dir or WheelConfig.get_data_dir(opts.env)
  if not data_dir then
    return false, store_error("E_DATA_STORE_UNAVAILABLE", "XDG_DATA_HOME and HOME are unset")
  end
  local file_path = data_dir .. "/credentials.json"
  local existing, err = read_private_json_store(file_path, "wheel credentials store")
  if not existing then return false, err end
  local doc = { version = 1, providers = {} }
  local src = type(existing.providers) == "table" and existing.providers or existing
  for k, v in pairs(src) do
    if k ~= "version" and type(v) == "string" then
      doc.providers[string.lower(k)] = v
    end
  end
  doc.providers[string.lower(provider_name)] = api_key
  return write_private_json_store(data_dir, file_path, doc, "wheel credentials store")
end

--- Delete a provider credential from $XDG_DATA_HOME/wheel/credentials.json.
function WheelConfig.delete_credential(provider_name, opts)
  opts = opts or {}
  if type(provider_name) ~= "string" or provider_name == "" then
    return false, store_error("E_ARGS_INVALID", "invalid provider name")
  end
  local data_dir = opts.data_dir or WheelConfig.get_data_dir(opts.env)
  if not data_dir then
    return false, store_error("E_DATA_STORE_UNAVAILABLE", "XDG_DATA_HOME and HOME are unset")
  end
  local file_path = data_dir .. "/credentials.json"
  local existing, err = read_private_json_store(file_path, "wheel credentials store")
  if not existing then return false, err end
  local doc = { version = 1, providers = {} }
  local src = type(existing.providers) == "table" and existing.providers or existing
  for k, v in pairs(src) do
    if k ~= "version" and type(v) == "string" then
      doc.providers[string.lower(k)] = v
    end
  end
  doc.providers[string.lower(provider_name)] = nil
  return write_private_json_store(data_dir, file_path, doc, "wheel credentials store")
end

--- Resolve API key using precedence:
--   session_override > env_var > global_config > data_credentials > "".
function WheelConfig.resolve_api_key(provider_name, opts, env_override)
  opts = opts or {}
  local pname = string.lower(tostring(provider_name or ""))
  local sess = opts.session_override
  if type(sess) == "table" then
    if type(sess.api_key) == "string" and #sess.api_key > 0 then
      return sess.api_key, "session_override"
    end
    if type(sess.providers) == "table" and type(sess.providers[pname]) == "table"
      and type(sess.providers[pname].api_key) == "string" and #sess.providers[pname].api_key > 0 then
      return sess.providers[pname].api_key, "session_override"
    end
  end

  local active_env = opts.env or env_override
  local env_var = opts.api_key_env or PROVIDER_API_KEY_ENV[pname]
  if type(env_var) == "string" and #env_var > 0 then
    local val = lookup_env(env_var, active_env)
    if type(val) == "string" and #val > 0 then
      return val, "env"
    end
  end

  local global_cfg = opts.global_config
  if type(global_cfg) ~= "table" and opts.skip_global_lookup ~= true then
    local loaded_global = WheelConfig.load_global_only({
      env = active_env,
      global_path = opts.global_path,
      global_dir = opts.global_dir,
    })
    global_cfg = loaded_global
  end
  if type(global_cfg) == "table" and type(global_cfg.providers) == "table"
    and type(global_cfg.providers[pname]) == "table"
    and type(global_cfg.providers[pname].api_key) == "string"
    and #global_cfg.providers[pname].api_key > 0 then
    return global_cfg.providers[pname].api_key, "global_config"
  end

  local creds = opts.data_credentials
  if type(creds) ~= "table" then
    local read_creds = WheelConfig.read_credentials({ env = active_env, data_dir = opts.data_dir })
    creds = read_creds or {}
  end
  if type(creds[pname]) == "string" and #creds[pname] > 0 then
    return creds[pname], "data_credentials"
  end
  return "", "none"
end

--- Resolve project configuration path (<project_root>/.wheel/init.lua).
function WheelConfig.get_project_config_path(project_root)
  project_root = project_root or "."
  -- Strip trailing slash if present
  project_root = string.gsub(project_root, "/+$", "")
  return project_root .. "/.wheel/init.lua"
end

--- Resolve trust store path ($XDG_STATE_HOME/wheel/trusted_projects.json).
-- There is deliberately no `/tmp` or other predictable fallback: when neither
-- XDG_STATE_HOME nor HOME is set the trust gate fails closed. The optional
-- `env` table exists for deterministic tests; production callers omit it.
-- @param env table? environment overrides for tests
-- @return string? path
function WheelConfig.get_trust_store_path(env)
  local function value(name)
    if type(env) == "table" then
      return env[name]
    end
    return getenv(name)
  end

  local xdg_state = value("XDG_STATE_HOME")
  if type(xdg_state) == "string" and xdg_state ~= "" then
    return xdg_state .. "/wheel/trusted_projects.json"
  end
  local home = value("HOME")
  if type(home) == "string" and home ~= "" then
    return home .. "/.local/state/wheel/trusted_projects.json"
  end
  return nil
end

--- Resolve the trust-store path and reject relative or control-bearing values.
-- @param path_override string?
-- @param env table?
-- @return string? path, table? err
local function resolve_trust_store_path(path_override, env)
  local path = path_override or WheelConfig.get_trust_store_path(env)
  if not path or path == "" then
    return nil, trust_error("E_TRUST_STORE_UNAVAILABLE",
      "neither XDG_STATE_HOME nor HOME is set; the trust store has no non-XDG fallback")
  end
  if path:sub(1, 1) ~= "/" then
    return nil, trust_error("E_TRUST_STORE_UNAVAILABLE", "trust store path must be absolute")
  end
  if path:sub(-1) == "/" then
    return nil, trust_error("E_TRUST_STORE_UNAVAILABLE",
      "trust store path must name a file, not a directory")
  end
  local parent = path:match("^(.*)/[^/]+$")
  if not parent or parent == "" or parent == "/" then
    return nil, trust_error("E_TRUST_STORE_UNAVAILABLE",
      "trust store path must live in a non-root directory")
  end
  if has_control_chars(path) then
    return nil, trust_error("E_TRUST_STORE_UNAVAILABLE", "trust store path contains control bytes")
  end
  return path, nil
end

--- Read and validate the trust store.
-- A missing store is an empty store. A corrupt, unreadable, symlinked,
-- non-regular, foreign-owned, or group/world-writable store returns an empty
-- store plus a structured warning; every project stays untrusted. The warning
-- is never silently discarded.
-- @param path_override string?
-- @param env table? environment overrides for tests
-- @return table store, table? warning
function WheelConfig.read_trust_store(path_override, env)
  local path, path_err = resolve_trust_store_path(path_override, env)
  if not path then
    return empty_trust_store(), path_err
  end

  local host = require_host("fs.read")
  local parent = path:match("^(.*)/[^/]+$") or "/"
  local parent_info = host.fs.stat(parent)
  if parent_info.exists then
    if parent_info.symlink then
      return empty_trust_store(), trust_error("E_TRUST_STORE_SYMLINK",
        "trust store directory is a symbolic link")
    end
    if not parent_info.directory then
      return empty_trust_store(), trust_error("E_TRUST_STORE_NOT_REGULAR",
        "trust store parent path is not a directory")
    end
    local parent_ok, parent_err = check_store_owner(parent_info, "trust store directory")
    if not parent_ok then
      return empty_trust_store(), parent_err
    end
  end

  local info = host.fs.stat(path)
  if not info.exists then
    return empty_trust_store(), nil
  end
  if info.symlink then
    return empty_trust_store(), trust_error("E_TRUST_STORE_SYMLINK",
      "trust store is a symbolic link")
  end
  if not info.regular then
    return empty_trust_store(), trust_error("E_TRUST_STORE_NOT_REGULAR",
      "trust store is not a regular file")
  end

  local owner_ok, owner_err = check_store_owner(info, "trust store")
  if not owner_ok then
    return empty_trust_store(), owner_err
  end

  local raw, read_err = host.fs.read_file_bounded(path, WheelConfig.MAX_TRUST_STORE_BYTES + 1)
  if not raw then
    return empty_trust_store(), trust_error("E_TRUST_STORE_UNREADABLE",
      "trust store cannot be read: " .. tostring(read_err))
  end
  if #raw > WheelConfig.MAX_TRUST_STORE_BYTES then
    return empty_trust_store(), trust_error("E_TRUST_STORE_TOO_LARGE",
      "trust store exceeds the " .. WheelConfig.MAX_TRUST_STORE_BYTES .. "-byte cap")
  end
  if raw == "" then
    return empty_trust_store(), trust_error("E_TRUST_STORE_CORRUPT",
      "trust store is empty instead of a JSON object")
  end

  local K = get_kernel()
  local decoded_ok, data = pcall(function() return K.JSON.decode(raw) end)
  if not decoded_ok or type(data) ~= "table" then
    return empty_trust_store(), trust_error("E_TRUST_STORE_CORRUPT",
      "trust store JSON is corrupt")
  end
  local store, normalize_err = normalize_trust_store(data)
  if not store then
    return empty_trust_store(), normalize_err
  end
  return store, nil
end

--- Return the trust store with every resolvable project key canonicalized.
-- Unresolvable keys cannot name an existing project root and are dropped, so a
-- successful write never preserves a legacy lexical/alias key.
-- @param store table
-- @return table
local function canonicalize_store(store)
  local cleaned = empty_trust_store()
  if type(store) ~= "table" or type(store.projects) ~= "table" then
    return cleaned
  end
  for key, entry in pairs(store.projects) do
    local canonical = nil
    if type(key) == "string" and key:sub(1, 1) == "/" then
      local ok, resolved = pcall(WheelConfig.canonical_root, key)
      if ok and resolved then
        canonical = resolved
      end
    end
    -- Preserve an unresolvable record under its original key: a temporarily
    -- unmounted project must not silently lose its approval during an
    -- unrelated write. It remains untrusted until the path resolves again.
    cleaned.projects[canonical or key] = entry
  end
  return cleaned
end

--- Write the trust store atomically as a private file.
-- The parent directory is created (or repaired) with mode 0700, the file is
-- written to a same-directory `mktemp` file, chmodded 0600, then renamed over
-- the target. An insecure, foreign-owned, symlinked, or non-regular target is
-- rejected instead of replaced.
-- @param store table
-- @param path_override string?
-- @return boolean success, table? err
function WheelConfig.write_trust_store(store, path_override)
  local path, path_err = resolve_trust_store_path(path_override)
  if not path then
    return false, path_err
  end

  local host = require_host("fs.write")
  local parent = path:match("^(.*)/[^/]+$") or "/"

  local made = host.fs.mkdir_p(parent)
  if not made then
    return false, trust_error("E_TRUST_STORE_WRITE_FAILED",
      "cannot create the trust store directory")
  end

  if type(store) ~= "table" or type(store.projects) ~= "table" then
    return false, trust_error("E_TRUST_STORE_CORRUPT",
      "trust store to write is not an object with projects")
  end
  for key in pairs(store.projects) do
    if type(key) ~= "string" or key:sub(1, 1) ~= "/" or has_control_chars(key) then
      return false, trust_error("E_TRUST_STORE_CORRUPT",
        "refusing to write a non-absolute or control-bearing project key")
    end
  end

  local parent_info = host.fs.stat(parent)
  if not parent_info.exists then
    return false, trust_error("E_TRUST_STORE_WRITE_FAILED",
      "the trust store directory is unavailable after creation")
  end
  if parent_info.symlink then
    return false, trust_error("E_TRUST_STORE_SYMLINK",
      "trust store directory is a symbolic link")
  end
  if not parent_info.directory then
    return false, trust_error("E_TRUST_STORE_NOT_REGULAR",
      "trust store parent path is not a directory")
  end
  local parent_ok, parent_owner_err = check_store_owner(
    parent_info, "trust store directory", true)
  if not parent_ok then
    return false, parent_owner_err
  end
  local chmod_dir = host.fs.chmod(parent, "700")
  if chmod_dir ~= true then
    return false, trust_error("E_TRUST_STORE_WRITE_FAILED",
      "cannot set the trust store directory to mode 0700")
  end
  parent_info = host.fs.stat(parent)
  parent_ok, parent_owner_err = check_store_owner(parent_info, "trust store directory")
  if not parent_ok then
    return false, parent_owner_err
  end

  local info = host.fs.stat(path)
  if info.exists then
    if info.symlink then
      return false, trust_error("E_TRUST_STORE_SYMLINK", "refusing to replace a symlinked trust store")
    end
    if not info.regular then
      return false, trust_error("E_TRUST_STORE_NOT_REGULAR", "refusing to replace a non-regular trust store")
    end
    local file_ok, file_owner_err = check_store_owner(info, "trust store")
    if not file_ok then
      return false, file_owner_err
    end
  end

  local K = get_kernel()
  local candidate = canonicalize_store(store)
  local project_count = 0
  for _ in pairs(candidate.projects) do
    project_count = project_count + 1
  end
  if project_count > WheelConfig.MAX_TRUST_STORE_PROJECTS then
    return false, trust_error("E_TRUST_STORE_TOO_LARGE",
      "refusing to write more than " .. WheelConfig.MAX_TRUST_STORE_PROJECTS
        .. " trust records")
  end
  local json_str = K.JSON.encode(candidate)
  if #json_str > WheelConfig.MAX_TRUST_STORE_BYTES then
    return false, trust_error("E_TRUST_STORE_TOO_LARGE",
      "refusing to write a trust store above " .. WheelConfig.MAX_TRUST_STORE_BYTES
        .. " bytes; the file would fail the read cap and lose approvals")
  end

  local temp_result = host.proc.run_program(
    "mktemp", { path .. ".tmp.XXXXXX" }, { discard_stderr = true })
  if not (temp_result.ok and temp_result.code == 0) then
    return false, trust_error("E_TRUST_STORE_WRITE_FAILED",
      "cannot create a private temporary trust store")
  end
  local temp = trim_output(temp_result.stdout)
  if temp:sub(1, 1) ~= "/" then
    return false, trust_error("E_TRUST_STORE_WRITE_FAILED",
      "temporary trust store path is not absolute")
  end

  local wrote = host.fs.write_file(temp, json_str)
  if not wrote then
    host.fs.remove_file(temp)
    return false, trust_error("E_TRUST_STORE_WRITE_FAILED", "cannot write the temporary trust store")
  end
  local chmod_file = host.fs.chmod(temp, "600")
  if chmod_file ~= true then
    host.fs.remove_file(temp)
    return false, trust_error("E_TRUST_STORE_WRITE_FAILED", "cannot set the trust store to mode 0600")
  end
  local renamed = host.fs.rename(temp, path)
  if not renamed then
    host.fs.remove_file(temp)
    return false, trust_error("E_TRUST_STORE_WRITE_FAILED", "atomic trust store rename failed")
  end

  local final_info = host.fs.stat(path)
  if final_info.symlink or not final_info.regular then
    return false, trust_error("E_TRUST_STORE_WRITE_FAILED",
      "trust store is not a regular file after the atomic rename")
  end
  local final_ok, final_err = check_store_owner(final_info, "trust store")
  if not final_ok then
    return false, final_err
  end
  return true, nil
end

--- Resolve a path through the host to a canonical absolute directory.
-- Uses `realpath -e`, then `readlink -f`, then `cd -P ... && pwd -P`. The
-- process `PWD` is never consulted. Control bytes and unresolvable paths fail
-- closed.
-- @param path string?
-- @return string? canonical_root, table? err
function WheelConfig.canonical_root(path)
  if path == nil or path == "" then
    path = "."
  end
  if type(path) ~= "string" or has_control_chars(path) then
    return nil, trust_error("E_PROJECT_ROOT_UNRESOLVED",
      "project root must be a control-free path string")
  end

  local host = require_host("fs.read")
  local info = host.fs.stat(path)
  if not info.exists or not info.directory then
    return nil, trust_error("E_PROJECT_ROOT_UNRESOLVED",
      "project root is not an existing directory")
  end

  local function accept(candidate)
    if type(candidate) ~= "string" then
      return nil
    end
    local value = candidate:gsub("[\r\n]+$", "")
    if value == "" or value:sub(1, 1) ~= "/" or has_control_chars(value) then
      return nil
    end
    local resolved = host.fs.stat(value)
    if not resolved.exists or not resolved.directory then
      return nil
    end
    return value
  end

  local attempts = {
    { "realpath", { "-e", "--", path } },
    { "readlink", { "-f", "--", path } },
  }
  for _, attempt in ipairs(attempts) do
    local res = host.proc.run_program(attempt[1], attempt[2], { discard_stderr = true })
    if res.ok and res.code == 0 then
      local accepted = accept(res.stdout)
      if accepted then
        return accepted, nil
      end
    end
  end

  local quoted = host.proc.shell_quote(path)
  local cd_result = host.proc.run_command("cd -P -- " .. quoted .. " && pwd -P")
  if cd_result.ok and cd_result.code == 0 then
    local accepted = accept(cd_result.stdout)
    if accepted then
      return accepted, nil
    end
  end

  return nil, trust_error("E_PROJECT_ROOT_UNRESOLVED",
    "project root cannot be resolved to a canonical directory")
end

--- Resolve an existing file or directory path without requiring a directory.
-- @param path string
-- @return string? canonical_path
local function canonical_existing_path(path)
  if type(path) ~= "string" or has_control_chars(path) then
    return nil
  end
  local host = require_host("fs.read")
  local attempts = {
    { "realpath", { "-e", "--", path } },
    { "readlink", { "-f", "--", path } },
  }
  for _, attempt in ipairs(attempts) do
    local res = host.proc.run_program(attempt[1], attempt[2], { discard_stderr = true })
    if res.ok and res.code == 0 then
      local value = (res.stdout or ""):gsub("[\r\n]+$", "")
      if value ~= "" and value:sub(1, 1) == "/" and not has_control_chars(value) then
        local info = host.fs.stat(value)
        if info.exists then
          return value
        end
      end
    end
  end
  return nil
end

--- Inspect the project entry with the bounded reader and the trust rules.
-- The entry must be a regular, non-symlinked file no larger than
-- `MAX_PROJECT_CONFIG_BYTES`. The `.wheel` directory must not be a symlink and
-- the entry's canonical path must equal the path inside the canonical root, so
-- a repository cannot redirect the gate through a link. Nothing is evaluated.
-- @param project_root string?
-- @return table { ok, root?, path?, content?, hash?, bytes?, code?, message? }
function WheelConfig.inspect_project_config(project_root)
  local root, root_err = WheelConfig.canonical_root(project_root)
  if not root then
    return { ok = false, code = root_err.code, message = root_err.message }
  end

  local host = require_host("fs.read")
  local config_dir = root .. "/.wheel"
  local dir_info = host.fs.stat(config_dir)
  if dir_info.exists then
    if dir_info.symlink then
      return {
        ok = false,
        root = root,
        path = config_dir .. "/init.lua",
        code = "E_PROJECT_CONFIG_SYMLINK",
        message = "project configuration directory is a symbolic link",
      }
    end
    if not dir_info.directory then
      return {
        ok = false,
        root = root,
        path = config_dir,
        code = "E_PROJECT_CONFIG_NOT_REGULAR",
        message = "project configuration directory path is not a directory",
      }
    end
  end

  local path = WheelConfig.get_project_config_path(root)
  local info = host.fs.stat(path)
  if not info.exists then
    return {
      ok = false,
      root = root,
      path = path,
      code = "E_PROJECT_CONFIG_MISSING",
      message = "no project configuration at " .. path,
    }
  end
  if info.symlink then
    return {
      ok = false,
      root = root,
      path = path,
      code = "E_PROJECT_CONFIG_SYMLINK",
      message = "project configuration is a symbolic link",
    }
  end
  if not info.regular then
    return {
      ok = false,
      root = root,
      path = path,
      code = "E_PROJECT_CONFIG_NOT_REGULAR",
      message = "project configuration is not a regular file",
    }
  end

  local canonical = canonical_existing_path(path)
  if not canonical or canonical ~= path then
    return {
      ok = false,
      root = root,
      path = path,
      code = "E_PROJECT_CONFIG_SYMLINK",
      message = "project configuration resolves outside its canonical path",
    }
  end

  local content, read_err = host.fs.read_file_bounded(
    path, WheelConfig.MAX_PROJECT_CONFIG_BYTES + 1)
  if not content then
    return {
      ok = false,
      root = root,
      path = path,
      code = "E_PROJECT_CONFIG_UNREADABLE",
      message = "project configuration cannot be read: " .. tostring(read_err),
    }
  end
  if #content > WheelConfig.MAX_PROJECT_CONFIG_BYTES then
    return {
      ok = false,
      root = root,
      path = path,
      code = "E_PROJECT_CONFIG_TOO_LARGE",
      message = "project configuration exceeds the "
        .. WheelConfig.MAX_PROJECT_CONFIG_BYTES .. "-byte cap",
    }
  end

  local hash = WheelConfig.compute_content_hash(content)
  if not hash then
    return {
      ok = false,
      root = root,
      path = path,
      code = "E_PROJECT_CONFIG_HASH_UNAVAILABLE",
      message = "no SHA-256 implementation is available for the project configuration",
    }
  end

  return {
    ok = true,
    root = root,
    path = path,
    content = content,
    hash = hash,
    bytes = #content,
  }
end

--- Find a trust record by canonical root, including legacy/alias keys.
-- @param store table
-- @param root string canonical root
-- @return table? record, string? key, boolean alias
local function find_trust_record(store, root)
  if type(store) ~= "table" or type(store.projects) ~= "table" then
    return nil, nil, false
  end
  local direct = store.projects[root]
  if direct then
    return direct, root, false
  end
  for key, value in pairs(store.projects) do
    if type(key) == "string" and key:sub(1, 1) == "/" then
      local ok, canonical = pcall(WheelConfig.canonical_root, key)
      if ok and canonical == root then
        return value, key, true
      end
    end
  end
  return nil, nil, false
end

--- Build the full consent/inspection view without evaluating the entry.
-- @param project_root string?
-- @param trust_file string?
-- @return table
function WheelConfig.trust_status(project_root, trust_file)
  local entry = WheelConfig.inspect_project_config(project_root)
  if not entry.ok then
    return entry
  end

  local store, store_warning = WheelConfig.read_trust_store(trust_file)
  local record, record_key, alias = find_trust_record(store, entry.root)

  local trusted = false
  local status
  if not record then
    status = "not trusted (no record for this canonical root)"
  elseif record.hash == entry.hash then
    trusted = true
    status = "trusted (current hash matches the approved hash)"
  else
    status = "changed since the last approval"
  end

  local diff
  local diff_note
  if record and type(record.content) == "string" then
    diff = WheelConfig.compute_diff(record.content, entry.content)
  elseif record then
    diff_note = "unavailable: the previous record is a legacy hash-only entry; "
      .. "the next successful approval stores full content for future diffs"
  else
    diff_note = "none: there is no previously trusted content for this root"
  end

  local store_path = trust_file or WheelConfig.get_trust_store_path()

  return {
    ok = true,
    root = entry.root,
    path = entry.path,
    content = entry.content,
    hash = entry.hash,
    bytes = entry.bytes,
    store = store,
    store_warning = store_warning,
    store_path = store_path,
    record = record,
    record_key = record_key,
    alias = alias,
    trusted = trusted,
    status = status,
    diff = diff,
    diff_note = diff_note,
  }
end

--- Check a precomputed hash against the trust store.
-- @param root string canonical project root
-- @param current_hash string
-- @param trust_file string?
-- @return boolean trusted, string? trusted_hash, table? warning
function WheelConfig.is_hash_trusted(root, current_hash, trust_file)
  local store, store_warning = WheelConfig.read_trust_store(trust_file)
  local record = find_trust_record(store, root)
  local trusted_hash = record and record.hash or nil
  if store_warning then
    return false, trusted_hash, store_warning
  end
  return trusted_hash ~= nil and trusted_hash == current_hash, trusted_hash, nil
end

--- Check whether a project configuration is trusted.
-- A corrupt or insecure store makes every project untrusted and is returned as
-- the fourth value so a caller can surface it. No content is evaluated.
-- @param project_root string
-- @param content string? Optional exact entry content; if omitted, reads it
-- @param trust_file string? Optional trust store path override
-- @return boolean trusted, string current_hash, string? trusted_hash, table? warning
function WheelConfig.is_trusted(project_root, content, trust_file)
  local root, root_err = WheelConfig.canonical_root(project_root)
  if not root then
    return false, "", nil, root_err
  end

  local current_hash
  if content ~= nil then
    if #content > WheelConfig.MAX_PROJECT_CONFIG_BYTES then
      return false, "", nil, trust_error("E_PROJECT_CONFIG_TOO_LARGE",
        "project configuration exceeds the " .. WheelConfig.MAX_PROJECT_CONFIG_BYTES
          .. "-byte cap")
    end
    current_hash = WheelConfig.compute_content_hash(content)
  else
    local entry = WheelConfig.inspect_project_config(root)
    if not entry.ok then
      return false, "", nil, trust_error(entry.code, entry.message)
    end
    current_hash = entry.hash
  end

  local trusted, trusted_hash, warning = WheelConfig.is_hash_trusted(
    root, current_hash or "", trust_file)
  return trusted, current_hash or "", trusted_hash, warning
end

--- Repair a user-owned trust-store parent directory after a permission warning.
-- Only the parent mode is changed: the store file itself is never rewritten
-- here. Ownership, symlink, and directory type are re-checked before chmod, and
-- the caller re-reads the store and refuses to continue if any warning remains.
-- @param trust_file string?
-- @return boolean repaired, table? err
local function repair_trust_store_parent(trust_file)
  local path, path_err = resolve_trust_store_path(trust_file)
  if not path then
    return false, path_err
  end

  local host = require_host("fs.write")
  local parent = path:match("^(.*)/[^/]+$") or "/"
  local info = host.fs.stat(parent)
  if not info.exists then
    return false, trust_error("E_TRUST_STORE_PERMISSIONS",
      "trust store directory is missing")
  end
  if info.symlink then
    return false, trust_error("E_TRUST_STORE_SYMLINK",
      "trust store directory is a symbolic link")
  end
  if not info.directory then
    return false, trust_error("E_TRUST_STORE_NOT_REGULAR",
      "trust store parent path is not a directory")
  end

  local owner_ok, owner_err = check_store_owner(info, "trust store directory", true)
  if not owner_ok then
    return false, owner_err
  end
  local chmod_ok = host.fs.chmod(parent, "700")
  if chmod_ok ~= true then
    return false, trust_error("E_TRUST_STORE_WRITE_FAILED",
      "cannot repair the trust store directory to mode 0700")
  end
  local repaired = host.fs.stat(parent)
  local mode_ok, mode_err = check_store_owner(repaired, "trust store directory")
  if not mode_ok then
    return false, mode_err
  end
  return true, nil
end

--- Approve the current entry only when the supplied hash is exact.
-- The supplied hash must be the full 64-hex SHA-256 of the current bytes. The
-- store is re-read inside this call so a confirmation cannot approve content
-- that changed after the consent view.
-- @param project_root string
-- @param expected_hash string
-- @param trust_file string?
-- @return boolean success, table? err, string? hash, table? status
function WheelConfig.confirm_trust(project_root, expected_hash, trust_file)
  if not is_sha256_hex(expected_hash) then
    return false, trust_error("E_TRUST_HASH_INVALID",
      "confirmation requires the full 64-hex SHA-256 hash"), nil
  end

  local status = WheelConfig.trust_status(project_root, trust_file)
  if not status.ok then
    return false, { code = status.code, message = status.message }, nil
  end
  if status.store_warning then
    -- A group/world-writable parent is repairable only when it is a real,
    -- user-owned directory. Re-read the store afterwards: every existing
    -- project must be preserved, and every other warning remains fatal.
    if status.store_warning.code ~= "E_TRUST_STORE_PERMISSIONS" then
      return false, status.store_warning, nil
    end
    local repaired = repair_trust_store_parent(trust_file)
    if not repaired then
      return false, status.store_warning, nil
    end
    local repaired_store, repaired_warning = WheelConfig.read_trust_store(trust_file)
    if repaired_warning then
      return false, repaired_warning, nil
    end
    status.store = repaired_store
    status.store_warning = nil
  end
  if status.hash ~= expected_hash then
    return false, trust_error("E_TRUST_HASH_MISMATCH",
      "supplied hash does not match the current entry bytes; run `trust` again"), nil
  end

  local store = status.store or empty_trust_store()
  store.version = 1
  store.projects = store.projects or {}

  -- Migrate alias and legacy keys that resolve to this canonical root.
  for key in pairs(store.projects) do
    local remove = key == status.root
    if not remove and type(key) == "string" and key:sub(1, 1) == "/" then
      local canonical_ok, canonical = pcall(WheelConfig.canonical_root, key)
      remove = canonical_ok and canonical == status.root
    end
    if remove then
      store.projects[key] = nil
    end
  end

  local approved_at = require_host("time.now").time.now()
  store.projects[status.root] = {
    hash = status.hash,
    content = status.content,
    approved_at = approved_at,
  }

  local ok, write_err = WheelConfig.write_trust_store(store, trust_file)
  if not ok then
    return false, write_err or trust_error("E_TRUST_STORE_WRITE_FAILED",
      "failed to persist the trust store"), nil
  end
  return true, nil, status.hash, status
end

--- Backward-compatible approval entry point; it now requires the exact hash.
-- @param project_root string
-- @param expected_hash string
-- @param trust_file string?
-- @return boolean success, table? err, string? hash, table? status
function WheelConfig.trust(project_root, expected_hash, trust_file)
  return WheelConfig.confirm_trust(project_root, expected_hash, trust_file)
end

--- Revoke one canonical project root, including alias and legacy keys.
-- Revocation is independent of entry readability: the path must resolve, but
-- the project configuration file may already be gone.
-- @param project_root string
-- @param trust_file string?
-- @return boolean success, number|table removed_or_error
function WheelConfig.revoke(project_root, trust_file)
  local root, root_err = WheelConfig.canonical_root(project_root)
  if not root then
    return false, root_err
  end

  local store, store_warning = WheelConfig.read_trust_store(trust_file)
  if store_warning then
    return false, store_warning
  end

  local removed = 0
  for key in pairs(store.projects) do
    local remove = key == root or key == project_root
    if not remove and type(key) == "string" and key:sub(1, 1) == "/" then
      local canonical_ok, canonical = pcall(WheelConfig.canonical_root, key)
      remove = canonical_ok and canonical == root
    end
    if remove then
      store.projects[key] = nil
      removed = removed + 1
    end
  end

  if removed == 0 then
    return true, 0, root
  end

  store.version = 1
  local ok, write_err = WheelConfig.write_trust_store(store, trust_file)
  if not ok then
    return false, write_err or trust_error("E_TRUST_STORE_WRITE_FAILED",
      "failed to persist the revocation")
  end
  return true, removed, root
end

--- Revoke trust for a project configuration (legacy name).
-- @param project_root string
-- @param trust_file string?
-- @return boolean success, number|table removed_or_error
function WheelConfig.untrust(project_root, trust_file)
  return WheelConfig.revoke(project_root, trust_file)
end

--- Split text into lines while preserving trailing-newline distinction.
-- `"a"` and `"a\n"` produce different line arrays (`{"a"}` vs `{"a", ""}`),
-- so a whitespace-only final newline change still appears in the diff.
local function split_lines(value)
  local lines = {}
  if value == "" then
    return lines
  end
  local start = 1
  while true do
    local newline = value:find("\n", start, true)
    if not newline then
      lines[#lines + 1] = value:sub(start)
      break
    end
    lines[#lines + 1] = value:sub(start, newline - 1)
    start = newline + 1
  end
  return lines
end

--- Produce a bounded pure-Lua line diff.
-- The prefix/suffix trim makes the common case linear and caps the emitted
-- block at the changed lines; the 32 KiB entry cap bounds the total. Added,
-- removed, and changed lines are all represented, and the caller never turns
-- differing bytes into "(no changes)". This deliberately avoids an external
-- `diff` process, whose Lua 5.1 popen status is unobservable.
-- @param previous string
-- @param current string
-- @return string
local function pure_line_diff(previous, current)
  local old_lines = split_lines(previous)
  local new_lines = split_lines(current)
  local old_count = #old_lines
  local new_count = #new_lines

  local prefix = 0
  while prefix < old_count and prefix < new_count
    and old_lines[prefix + 1] == new_lines[prefix + 1] do
    prefix = prefix + 1
  end

  local suffix = 0
  while suffix < old_count - prefix and suffix < new_count - prefix
    and old_lines[old_count - suffix] == new_lines[new_count - suffix] do
    suffix = suffix + 1
  end

  local lines = { "--- trusted", "+++ current" }
  if prefix > 0 then
    lines[#lines + 1] = " " .. old_lines[prefix]
  end

  local old_start = prefix + 1
  local old_end = old_count - suffix
  local new_start = prefix + 1
  local new_end = new_count - suffix
  lines[#lines + 1] = string.format("@@ -%d,%d +%d,%d @@",
    old_start, old_end - old_start + 1, new_start, new_end - new_start + 1)
  for index = old_start, old_end do
    lines[#lines + 1] = "-" .. old_lines[index]
  end
  for index = new_start, new_end do
    lines[#lines + 1] = "+" .. new_lines[index]
  end
  if suffix > 0 then
    lines[#lines + 1] = " " .. old_lines[old_end + 1]
  end
  return table.concat(lines, "\n")
end

--- Compute a line diff between previously trusted and current content.
-- Pure Lua and bounded by the entry cap; never reports "(no changes)" unless
-- the byte strings are identical.
-- @param previous string
-- @param current string
-- @return string
function WheelConfig.compute_diff(previous, current)
  if type(previous) ~= "string" or type(current) ~= "string" then
    previous = tostring(previous or "")
    current = tostring(current or "")
  end
  if previous == current then
    return "(no changes)"
  end
  return pure_line_diff(previous, current)
end

local function single_line(value)
  local text = type(value) == "string" and value or tostring(value or "")
  return (text:gsub("[\r\n]", " "))
end

--- Escape one line for consent display.
-- Printable ASCII is preserved except backslash, which is doubled so `\xNN`
-- escapes are unambiguous. Every other byte (ESC, CR, NUL, other control bytes,
-- and non-ASCII bytes) is rendered as `\xNN`. The raw SHA-256 still covers the
-- original bytes, never this escaped rendering.
-- @param value string
-- @return string
local function escape_consent_text(value)
  local out = {}
  for index = 1, #value do
    local byte = value:byte(index)
    if byte == 92 then
      out[#out + 1] = "\\\\"
    elseif byte >= 32 and byte <= 126 then
      out[#out + 1] = string.char(byte)
    else
      out[#out + 1] = string.format("\\x%02X", byte)
    end
  end
  return table.concat(out)
end

--- Render one escaped, prefixed block so no content line can look like a
-- delimiter.
-- @param value string
-- @param prefix string
-- @return string[]
local function render_consent_block(value, prefix)
  local rendered = {}
  local lines = split_lines(value)
  if #lines == 0 then
    rendered[1] = prefix
    return rendered
  end
  for _, line in ipairs(lines) do
    rendered[#rendered + 1] = prefix .. escape_consent_text(line)
  end
  return rendered
end

--- Build a per-run nonce for the consent delimiters.
-- This is not a cryptographic token; it prevents a project entry from
-- pre-embedding the exact delimiter line. Every content line is also prefixed
-- and escaped, so guessing the nonce alone is not enough.
-- @return string
function WheelConfig.consent_nonce()
  local address = tostring({}):match("0x(%x+)") or "0"
  local now = "0"
  local ok, value = pcall(function()
    return require_host("time.now").time.now()
  end)
  if ok and type(value) == "number" then
    now = string.format("%x", math.floor(value))
  end
  return address .. "-" .. now
end

--- Render the full consent view. Content is escaped, line-prefixed, and
-- delimited by a per-run nonce. It is not truncated here; the command layer
-- chunks it across bounded notifications and returns a bounded summary.
-- @param plan table `trust_status` result
-- @param nonce string? per-run delimiter nonce
-- @return string
function WheelConfig.format_trust_show(plan, nonce)
  nonce = nonce or WheelConfig.consent_nonce()
  local lines = {
    "Wheel executable project configuration",
    "",
    "Canonical project root: " .. single_line(plan.root),
    "Entry: " .. single_line(plan.path),
    string.format("Entry size: %d bytes (cap %d bytes)", plan.bytes,
      WheelConfig.MAX_PROJECT_CONFIG_BYTES),
    "SHA-256: " .. plan.hash,
    "Trust status: " .. single_line(plan.status),
    "Trust store: " .. single_line(plan.store_path or "unavailable"),
  }

  if plan.record then
    lines[#lines + 1] = "Approved hash: " .. tostring(plan.record.hash)
    lines[#lines + 1] = "Approved at: "
      .. escape_consent_text(tostring(plan.record.approved_at or "unknown"))
    if plan.alias and plan.record_key then
      lines[#lines + 1] = "Record key: " .. single_line(plan.record_key)
        .. " (legacy/alias; the next approval migrates it to the canonical root)"
    end
  else
    lines[#lines + 1] = "Approved hash: none"
  end

  if plan.store_warning then
    lines[#lines + 1] = "Trust store warning: " .. single_line(plan.store_warning.code)
      .. " - " .. escape_consent_text(tostring(plan.store_warning.message))
    lines[#lines + 1] = "Every project is treated as untrusted until the store is repaired."
  end

  lines[#lines + 1] = ""
  lines[#lines + 1] = "Effects class: project configuration may request role/model profiles,"
  lines[#lines + 1] = "directives, tool allow/deny/custom declarations, skill filters,"
  lines[#lines + 1] = "verification commands, context budgets, panel policy, and lifecycle hooks."
  lines[#lines + 1] = "It may not add workspace roots, network destinations, secret names, or"
  lines[#lines + 1] = "role authority. The loader does not yet validate every field, so a"
  lines[#lines + 1] = "trusted entry remains code approved by the user, not a data-only contract."
  lines[#lines + 1] = ""
  lines[#lines + 1] = "Effects are evaluated only after confirmation. A concrete entry-specific"
  lines[#lines + 1] = "effects list cannot be produced without evaluating the entry, and this gate"
  lines[#lines + 1] = "does not evaluate untrusted project code before `trust confirm`."
  lines[#lines + 1] = "After confirmation the restricted loader evaluates it with no filesystem,"
  lines[#lines + 1] = "process, network, secret, environment, or module-load authority, under"
  lines[#lines + 1] = "an instruction hook and best-effort string/table memory bounds."
  lines[#lines + 1] = ""
  lines[#lines + 1] = "Content rendering: every line is prefixed and escaped. Backslash is"
  lines[#lines + 1] = "shown as \\\\ and non-printable/non-ASCII bytes as \\xNN. The SHA-256"
  lines[#lines + 1] = "covers the original bytes, not this escaped rendering."
  lines[#lines + 1] = ""
  lines[#lines + 1] = "--- BEGIN PROJECT CONFIGURATION CONTENT [" .. nonce .. "] ---"
  local content_lines = render_consent_block(plan.content, "    | ")
  for _, line in ipairs(content_lines) do
    lines[#lines + 1] = line
  end
  lines[#lines + 1] = "--- END PROJECT CONFIGURATION CONTENT [" .. nonce .. "] ---"
  lines[#lines + 1] = ""
  lines[#lines + 1] = "--- DIFF AGAINST PREVIOUSLY TRUSTED CONTENT [" .. nonce .. "] ---"
  if plan.diff then
    local diff_lines = render_consent_block(plan.diff, "    | ")
    for _, line in ipairs(diff_lines) do
      lines[#lines + 1] = line
    end
  else
    lines[#lines + 1] = "    | " .. escape_consent_text(plan.diff_note or "unavailable")
  end
  lines[#lines + 1] = "--- END DIFF [" .. nonce .. "] ---"
  lines[#lines + 1] = ""
  lines[#lines + 1] = "Approve exactly these bytes only after reviewing them:"
  lines[#lines + 1] = "  trust confirm " .. plan.hash
  lines[#lines + 1] = "Revoke this project:"
  lines[#lines + 1] = "  trust revoke"
  return table.concat(lines, "\n")
end

--- Render a bounded result summary for the trust show command.
-- The full escaped consent view is delivered as a notification series; the
-- command result cannot carry 32 KiB plus a diff inside the host body cap.
-- @param plan table
-- @param chunk_count number
-- @return string
function WheelConfig.format_trust_summary(plan, chunk_count)
  local lines = {
    "Wheel project trust consent summary",
    "Canonical project root: " .. single_line(plan.root),
    "Entry: " .. single_line(plan.path),
    string.format("Entry size: %d bytes (cap %d)", plan.bytes,
      WheelConfig.MAX_PROJECT_CONFIG_BYTES),
    "SHA-256: " .. plan.hash,
    "Trust status: " .. single_line(plan.status),
    "Trust store: " .. single_line(plan.store_path or "unavailable"),
    string.format("Consent view: %d notification chunk(s) shown before this summary.", chunk_count),
  }
  if plan.store_warning then
    lines[#lines + 1] = "Trust store warning: " .. single_line(plan.store_warning.code)
      .. " - " .. escape_consent_text(tostring(plan.store_warning.message))
  end
  lines[#lines + 1] = "This result body is a summary; review the notification series for the"
  lines[#lines + 1] = "escaped full entry and the diff before confirming the hash."
  return table.concat(lines, "\n")
end

--- Render the approval result.
-- @param status table
-- @return string
function WheelConfig.format_trust_confirm(status)
  return table.concat({
    "Wheel project configuration approved",
    "",
    "Canonical project root: " .. single_line(status.root),
    "Entry: " .. single_line(status.path),
    string.format("Entry size: %d bytes", status.bytes),
    "SHA-256: " .. status.hash,
    "Trust store: " .. single_line(status.store_path or "unavailable"),
    "",
    "The supplied hash matched the exact current entry bytes. No configuration",
    "was evaluated by the trust command; effects are applied only when a later",
    "configuration load reads this record under the restricted evaluator.",
  }, "\n")
end

--- Render the revocation result.
-- @param root string
-- @param removed number
-- @return string
function WheelConfig.format_trust_revoke(root, removed)
  return table.concat({
    "Wheel project trust revoked",
    "",
    "Canonical project root: " .. single_line(root),
    string.format("Trust records removed: %d (canonical root plus aliases/legacy keys)", removed),
    "",
    "Revocation applies to the next configuration load. An already running",
    "session may keep the configuration it loaded until it is restarted.",
  }, "\n")
end

--- Render a structured trust-gate refusal.
-- @param err table { code, message }
-- @return string
function WheelConfig.format_trust_error(err)
  local code = type(err) == "table" and err.code or "E_TRUST_ERROR"
  local message = type(err) == "table" and err.message or tostring(err)
  return "Trust gate refused (" .. single_line(code) .. "): "
    .. escape_consent_text(single_line(message))
end

-- File helpers that are not part of the trust gate remain local to the
-- loader; no extra public trust surface is added.

--- Safely evaluate a Lua configuration string in a sandboxed environment.
-- The environment intentionally omits `pcall` and `xpcall`: the instruction
-- hook raises an error the chunk must not be able to catch. String and table
-- concatenation are wrapped with per-call and cumulative byte caps. These are
-- best-effort bounds, not an OS or heap sandbox; a killable subprocess remains
-- the durable fix.
local function eval_config_chunk(content, chunk_name)
  local function copy_library(lib)
    local c = {}
    for k, v in pairs(lib or {}) do
      c[k] = v
    end
    return c
  end

  local total_allocated = 0

  local function account_bytes(size, label)
    if size > WheelConfig.MAX_EVAL_STRING_BYTES then
      error(label .. " exceeds the safety bound of "
        .. WheelConfig.MAX_EVAL_STRING_BYTES .. " bytes per call", 0)
    end
    total_allocated = total_allocated + size
    if total_allocated > WheelConfig.MAX_EVAL_TOTAL_STRING_BYTES then
      error(label .. " exceeds the cumulative safety bound of "
        .. WheelConfig.MAX_EVAL_TOTAL_STRING_BYTES .. " bytes", 0)
    end
  end

  local string_copy = copy_library(string)
  local real_string_rep = string.rep
  local orig_rep = real_string_rep
  local capped_rep = function(s, n, sep)
    if type(n) ~= "number" or n ~= n or n % 1 ~= 0 or n < 0 then
      error("string.rep count must be a non-negative integer number", 0)
    end
    if sep ~= nil and type(sep) ~= "string" then
      error("string.rep separator must be a string", 0)
    end
    local text = type(s) == "string" and s or tostring(s)
    local separator = sep or ""
    local size = #text * n
    if n > 0 then
      size = size + #separator * (n - 1)
    end
    account_bytes(size, "string.rep result")
    return orig_rep(text, n, separator)
  end
  string_copy.rep = capped_rep

  local table_copy = copy_library(table)
  local real_table_concat = table.concat
  local orig_concat = real_table_concat
  local capped_concat = function(t, sep, i, j)
    if type(t) ~= "table" then
      error("table.concat first argument must be a table", 0)
    end
    if sep ~= nil and type(sep) ~= "string" then
      error("table.concat separator must be a string", 0)
    end
    if i ~= nil and (type(i) ~= "number" or i % 1 ~= 0) then
      error("table.concat start index must be an integer number", 0)
    end
    if j ~= nil and (type(j) ~= "number" or j % 1 ~= 0) then
      error("table.concat end index must be an integer number", 0)
    end
    local first = i or 1
    local last = j or #t
    local size = 0
    for index = first, last do
      local value = t[index]
      if type(value) == "string" then
        size = size + #value
      elseif type(value) == "number" then
        size = size + #tostring(value)
      else
        error("table.concat entry " .. tostring(index) .. " is not a string or number", 0)
      end
    end
    if last >= first and sep then
      size = size + #sep * (last - first)
    end
    account_bytes(size, "table.concat result")
    return orig_concat(t, sep, i, j)
  end
  table_copy.concat = capped_concat

  -- Sandbox environment restricting ambient authority and isolating standard libraries.
  -- `pcall` and `xpcall` are deliberately absent so the instruction-hook error is
  -- not catchable by the evaluated chunk.
  local env = {
    ipairs = ipairs,
    pairs = pairs,
    type = type,
    tostring = tostring,
    tonumber = tonumber,
    string = string_copy,
    table = table_copy,
    math = copy_library(math),
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

  -- LuaJIT does not run debug count hooks inside JIT-compiled traces, so a hot
  -- loop in the evaluated chunk would bypass the instruction limit and hang
  -- the evaluation. Disable the JIT for this chunk (and every subfunction it
  -- creates) before it runs; the flag is attached to the discarded chunk, so
  -- the host's own code keeps its JIT state.
  if type(jit) == "table" and type(jit.off) == "function" then
    pcall(jit.off, chunk, true)
  end

  -- Method syntax such as `("x"):rep(n)` resolves the real string table through
  -- the string metatable. Patch the real tables for the duration of the chunk,
  -- not just the sandbox copies, and restore them on every path.
  local hook_installed = false
  local patched = false
  local ok, res
  local run_ok, run_err = pcall(function()
    string.rep = capped_rep
    table.concat = capped_concat
    patched = true
    if debug and debug.sethook then
      debug.sethook(function()
        error("configuration execution exceeded instruction limit", 0)
      end, "", 100000)
      hook_installed = true
    end
    ok, res = pcall(chunk)
  end)

  if hook_installed and debug and debug.sethook then
    pcall(function() debug.sethook() end)
  end
  if patched then
    string.rep = real_string_rep
    table.concat = real_table_concat
  end

  if not run_ok then
    return false, "runtime error in " .. chunk_name .. ": " .. tostring(run_err)
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
  -- List the skills directory through the argv-oriented process primitive.
  -- The existence probe keeps a missing directory from emitting stderr noise.
  local host = require_host("fs.read")
  if not host.fs.exists(skills_dir) then
    return { skills = discovered, count = 0 }
  end
  local list_res = host.proc.run_program("ls", { "-1", "--", skills_dir }, { discard_stderr = true })
  if list_res.ok then
    for entry in (list_res.stdout or ""):gmatch("[^\n]+") do
      local skill_path = skills_dir .. "/" .. entry .. "/SKILL.md"
      if file_exists(skill_path) then
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
local LUA_RESERVED_WORDS = {
  ["and"] = true, ["break"] = true, ["do"] = true, ["else"] = true, ["elseif"] = true,
  ["end"] = true, ["false"] = true, ["for"] = true, ["function"] = true, ["if"] = true,
  ["in"] = true, ["local"] = true, ["nil"] = true, ["not"] = true, ["or"] = true,
  ["repeat"] = true, ["return"] = true, ["then"] = true, ["true"] = true, ["until"] = true,
  ["while"] = true,
}

local function serialize_lua_value(val, indent, depth)
  depth = depth or 0
  if depth > 16 then return "nil" end
  local t = type(val)
  if t == "string" then
    return string.format("%q", val)
  elseif t == "number" or t == "boolean" then
    return tostring(val)
  elseif t ~= "table" then
    return "nil"
  end
  if next(val) == nil then
    return "{}"
  end
  local pad = string.rep("  ", indent)
  local inner_pad = string.rep("  ", indent + 1)
  if is_array(val) then
    local parts = {}
    for _, item in ipairs(val) do
      table.insert(parts, inner_pad .. serialize_lua_value(item, indent + 1, depth + 1))
    end
    return "{\n" .. table.concat(parts, ",\n") .. ",\n" .. pad .. "}"
  end
  local keys = {}
  for k in pairs(val) do
    if type(k) == "string" or type(k) == "number" then
      table.insert(keys, k)
    end
  end
  table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
  local parts = {}
  for _, k in ipairs(keys) do
    local key_expr
    if type(k) == "string" and k:match("^[A-Za-z_][A-Za-z0-9_]*$") and not LUA_RESERVED_WORDS[k] then
      key_expr = k
    elseif type(k) == "string" then
      key_expr = "[" .. string.format("%q", k) .. "]"
    else
      key_expr = "[" .. tostring(k) .. "]"
    end
    local encoded_v = serialize_lua_value(val[k], indent + 1, depth + 1)
    if encoded_v ~= "nil" then
      table.insert(parts, inner_pad .. key_expr .. " = " .. encoded_v)
    end
  end
  if #parts == 0 then return "{}" end
  return "{\n" .. table.concat(parts, ",\n") .. ",\n" .. pad .. "}"
end

local function load_lua_subdir(subdir, target_tbl)
  local host = require_host("fs.read")
  local st = host.fs.stat(subdir)
  if not st or not st.exists or not st.directory or st.symlink then
    return false
  end
  local list_res = host.proc.run_program("ls", { "-1", "--", subdir }, { discard_stderr = true })
  if not list_res or list_res.exit_code ~= 0 then
    return false
  end
  local lua_files = {}
  for name in (list_res.stdout or ""):gmatch("[^\n]+") do
    if name:sub(-4) == ".lua" and name:sub(1, 1) ~= "." then
      table.insert(lua_files, name)
    end
  end
  table.sort(lua_files)
  local any_loaded = false
  for _, fname in ipairs(lua_files) do
    local full = subdir .. "/" .. fname
    local fstat = host.fs.stat(full)
    if fstat and fstat.exists and fstat.regular and not fstat.symlink then
      local content = read_file(full)
      if content and content ~= "" then
        local ok_eval, tbl = eval_config_chunk(content, full)
        if ok_eval and type(tbl) == "table" then
          local key = (type(tbl.name) == "string" and tbl.name ~= "" and tbl.name) or fname:gsub("%.lua$", "")
          target_tbl[key] = deep_merge(target_tbl[key] or {}, tbl)
          any_loaded = true
        end
      end
    end
  end
  return any_loaded
end

local function load_global_skills_dir(skills_dir, target_skills)
  local host = require_host("fs.read")
  local st = host.fs.stat(skills_dir)
  if not st or not st.exists or not st.directory or st.symlink then
    return false
  end
  local list_res = host.proc.run_program("ls", { "-1", "--", skills_dir }, { discard_stderr = true })
  if not list_res or list_res.exit_code ~= 0 then
    return false
  end
  local names = {}
  for entry in (list_res.stdout or ""):gmatch("[^\n]+") do
    if entry ~= "" and entry:sub(1, 1) ~= "." then
      table.insert(names, entry)
    end
  end
  table.sort(names)
  local loaded = false
  for _, entry in ipairs(names) do
    local skill_path = skills_dir .. "/" .. entry .. "/SKILL.md"
    local skill_st = host.fs.stat(skill_path)
    if skill_st and skill_st.exists and skill_st.regular and not skill_st.symlink then
      target_skills[entry] = {
        name = entry,
        path = skill_path,
        origin = "global",
      }
      loaded = true
    end
  end
  return loaded
end

--- Load global configuration only (init.lua + optional modular subdirectories).
function WheelConfig.load_global_only(opts)
  opts = opts or {}
  local result = {}
  local any_loaded = false
  local global_path = opts.global_path or WheelConfig.get_global_config_path(opts.env)
  if global_path then
    local global_content = read_file(global_path)
    if global_content and global_content ~= "" then
      local ok, global_tbl = eval_config_chunk(global_content, global_path)
      if ok and type(global_tbl) == "table" then
        result = deep_merge(result, global_tbl)
        any_loaded = true
      end
    end
  end

  if opts.global_path == nil or opts.global_dir ~= nil then
    local global_dir = opts.global_dir or WheelConfig.get_global_config_dir(opts.env)
    if global_dir then
      result.providers = type(result.providers) == "table" and result.providers or {}
      result.roles = type(result.roles) == "table" and result.roles or {}
      result.commands = type(result.commands) == "table" and result.commands or {}
      result.custom_tools = type(result.custom_tools) == "table" and result.custom_tools or {}
      result.global_skills = type(result.global_skills) == "table" and result.global_skills or {}

      if load_lua_subdir(global_dir .. "/providers", result.providers) then any_loaded = true end
      if load_lua_subdir(global_dir .. "/agents", result.roles) then any_loaded = true end
      if load_lua_subdir(global_dir .. "/commands", result.commands) then any_loaded = true end
      if load_lua_subdir(global_dir .. "/tools", result.custom_tools) then
        result.tools = type(result.tools) == "table" and result.tools or {}
        result.tools.custom = deep_merge(result.tools.custom or {}, result.custom_tools)
        any_loaded = true
      end
      if load_global_skills_dir(global_dir .. "/skills", result.global_skills) then any_loaded = true end
    end
  end
  return result, any_loaded
end

--- Recursively strip secret fields before exporting merged global configuration.
local function scrub_export_secrets(val, depth)
  depth = depth or 0
  if depth > 16 or type(val) ~= "table" then
    return val
  end
  local out = {}
  for k, v in pairs(val) do
    if k ~= "api_key" and k ~= "credentials" then
      out[k] = scrub_export_secrets(v, depth + 1)
    end
  end
  return out
end

--- Export the merged global modular directory as a single sandbox-eval Lua chunk.
function WheelConfig.export_single_file(opts)
  local global_tbl = scrub_export_secrets(WheelConfig.load_global_only(opts or {}), 0)
  return "-- Generated by WheelConfig.export_single_file\nreturn " .. serialize_lua_value(global_tbl, 0, 0) .. "\n"
end

local function validate_project_override(base_config, project_tbl)
  if type(project_tbl) ~= "table" then
    return false, "project_config_escalation", "project config must return a table"
  end
  if project_tbl.api_key ~= nil or project_tbl.credentials ~= nil then
    return false, "project_config_escalation", "project config must not define api_key or credentials"
  end
  if type(project_tbl.providers) == "table" then
    if project_tbl.providers.api_key ~= nil or project_tbl.providers.base_url ~= nil then
      return false, "project_config_escalation", "project config must not set provider api_key or base_url"
    end
    for pname, pcfg in pairs(project_tbl.providers) do
      if type(pcfg) == "table" and (pcfg.api_key ~= nil or pcfg.base_url ~= nil) then
        return false, "project_config_escalation",
          "project config must not override api_key or base_url for provider '" .. tostring(pname) .. "'"
      end
    end
  end
  if type(project_tbl.permissions) == "table" then
    local base_perms = type(base_config.permissions) == "table" and base_config.permissions or {}
    for tool_name, mode in pairs(project_tbl.permissions) do
      if type(mode) ~= "string" or not PERMISSION_SEVERITY[mode] then
        return false, "project_config_escalation",
          "project config contains invalid permission mode for '" .. tostring(tool_name) .. "'"
      end
      local base_mode = base_perms[tool_name]
      if base_mode and PERMISSION_SEVERITY[base_mode]
        and PERMISSION_SEVERITY[mode] < PERMISSION_SEVERITY[base_mode] then
        return false, "project_config_escalation",
          string.format("project config cannot weaken permission for '%s' from '%s' to '%s'",
            tostring(tool_name), tostring(base_mode), tostring(mode))
      end
    end
  end
  return true, nil, nil
end

--- Load and resolve configuration with hierarchical layering:
--- Defaults (Layer 0) < Data Settings < Global (Layer 1) < Project (Layer 2) < Session overrides.
--- Enforces security trust gate and project non-escalation invariants.
function WheelConfig.load(opts)
  opts = opts or {}
  local project_root = opts.project_root or "."
  local trust_mode = opts.trust_mode or "strict"
  local layers_loaded = { defaults = true, data_settings = false, global = false, project = false }
  local active_config = deep_merge(deep_copy(WheelConfig.DEFAULTS), deep_copy(WheelConfig.RUNTIME_DEFAULTS))

  -- 0.5 Layer: Private XDG data settings ($XDG_DATA_HOME/wheel/settings.json)
  if opts.data_dir ~= false then
    local data_settings, ds_err = WheelConfig.read_data_settings({
      env = opts.env,
      data_dir = opts.data_dir,
    })
    if not data_settings then
      return {
        ok = false,
        error = "data_settings_rejected",
        code = ds_err and ds_err.code or "E_DATA_STORE_CORRUPT",
        message = ds_err and ds_err.message or "invalid wheel data settings store",
        config = active_config,
        layers = layers_loaded,
        trusted = false,
      }
    end
    if next(data_settings) ~= nil then
      active_config = deep_merge(active_config, data_settings)
      layers_loaded.data_settings = true
    end
  end

  -- 1. Layer 1: Global configuration (~/.config/wheel/init.lua + modular subdirs)
  local global_tbl, global_loaded = WheelConfig.load_global_only({
    env = opts.env,
    global_path = opts.global_path,
    global_dir = opts.global_dir,
  })
  if global_loaded then
    active_config = deep_merge(active_config, global_tbl)
    layers_loaded.global = true
  end

  -- 2. Layer 2: Project configuration (<project_root>/.wheel/init.lua)
  -- The entry is read once through the bounded reader, hashed from the exact
  -- bytes read, and never evaluated before the trust record matches.
  local entry = WheelConfig.inspect_project_config(project_root)
  local project_content = nil
  local project_path = nil
  local project_trusted = false
  local trust_store_warning = nil

  if not entry.ok and entry.code ~= "E_PROJECT_CONFIG_MISSING" then
    return {
      ok = false,
      error = "project_config_rejected",
      code = entry.code,
      message = entry.message,
      path = entry.path,
      config = active_config,
      layers = layers_loaded,
      trusted = false,
    }
  end

  if entry.ok then
    project_content = entry.content
    project_path = entry.path
  end

  if project_content and project_content ~= "" then
    if opts.trusted then
      project_trusted = true
    elseif trust_mode == "permissive" then
      project_trusted = true
    else
      local trusted, _, trust_warning = WheelConfig.is_hash_trusted(
        entry.root, entry.hash, opts.trust_file)
      project_trusted = trusted
      trust_store_warning = trust_warning
    end

    if not project_trusted then
      local message = "Project configuration at " .. project_path
        .. " is untrusted. Run `wheel trust` to inspect the full entry, its"
        .. " SHA-256 hash, and the change diff before confirming."
      if trust_store_warning then
        message = message .. " Trust store warning: "
          .. tostring(trust_store_warning.code) .. " - "
          .. tostring(trust_store_warning.message)
      end
      return {
        ok = false,
        error = "untrusted_project_config",
        message = message,
        code = trust_store_warning and trust_store_warning.code or "E_PROJECT_CONFIG_UNTRUSTED",
        path = project_path,
        root = entry.root,
        hash = entry.hash,
        config = active_config, -- Fallback to safe defaults + global
        layers = layers_loaded,
        trusted = false,
        trust_store_warning = trust_store_warning,
      }
    end

    -- Project config is trusted: execute safely and enforce non-escalation.
    local ok, project_tbl = eval_config_chunk(project_content, project_path)
    if not ok then
      return {
        ok = false,
        error = "project_config_eval_error",
        message = tostring(project_tbl),
        path = project_path,
        root = entry.root,
        config = active_config,
        layers = layers_loaded,
        trusted = true,
      }
    end

    local safe_ok, esc_err, esc_msg = validate_project_override(active_config, project_tbl)
    if not safe_ok then
      return {
        ok = false,
        error = esc_err,
        code = "E_PROJECT_CONFIG_ESCALATION",
        message = esc_msg,
        path = project_path,
        root = entry.root,
        config = active_config,
        layers = layers_loaded,
        trusted = true,
      }
    end

    -- Project config takes precedence over Global and Defaults within non-escalation bounds.
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
    root = entry.root,
  }
end

--- Resolve effective configuration with full runtime precedence:
--- session_override > trusted_project > global_config > data_settings > DEFAULTS.
function WheelConfig.resolve_effective_config(opts)
  opts = opts or {}
  local res = WheelConfig.load(opts)
  if not res.ok then
    return res
  end
  if type(opts.session_override) == "table" then
    res.config = deep_merge(res.config, opts.session_override)
    res.layers.session = true
  end
  return res
end

return WheelConfig
