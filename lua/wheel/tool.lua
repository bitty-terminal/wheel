-- lua/wheel/tool.lua
-- Wheel: Standardized Action Protocol, Tool Execution Engine, and Auto-Spillover Observation Pipeline
--
-- Pure Lua 5.1 / LuaJIT implementation with zero external C dependencies.
-- Provides:
-- 1. ActionIntent enum matching upstream Rust bitty-ai-slice ActionIntent.
-- 2. Strict workspace path sandboxing preventing directory traversal attacks.
-- 3. Destructive command detection and blocking.
-- 4. Built-in Core Engineering Tools (read_file, write_file, edit_file, run_command, list_directory, search_code, read_blob).
-- 5. Role authority gating (Research/Reviewer read-only enforcement).
-- 6. Content-addressed auto-spillover pipeline with head/tail observation preview.
-- 7. WheelToolRegistry for extensible tool registration and safe execution dispatch.

local WheelTool = {}

local ok_config, WheelConfig = pcall(require, "wheel.config")
if not ok_config then WheelConfig = nil end

local ok_context, WheelContext = pcall(require, "wheel.context")
if not ok_context then WheelContext = nil end

-- ---------------------------------------------------------------------------
-- Constants & Enums
-- ---------------------------------------------------------------------------

--- Standardized Action Intents matching Rust ActionIntent enum.
WheelTool.ActionIntent = {
  INSPECT = "inspect",
  MODIFY = "modify",
  EXECUTE = "execute",
  VERIFY = "verify",
  CUSTOM = "custom",
}

--- Standardized Action Outcome status.
WheelTool.OutcomeStatus = {
  SUCCESS = "success",
  FAILURE = "failure",
  ERROR = "error",
  DENIED = "denied",
}

--- Default auto-spillover threshold in bytes (4 KiB, matching Rust upstream).
WheelTool.DEFAULT_SPILLOVER_THRESHOLD = 4096

--- Maximum bytes to read for file operations by default.
WheelTool.DEFAULT_MAX_READ_BYTES = 65536

-- ---------------------------------------------------------------------------
-- Deterministic Hash Computation
-- ---------------------------------------------------------------------------

--- Compute deterministic 64-hex hash of content.
-- @param str string
-- @return string
function WheelTool.compute_hash(str)
  if WheelConfig and type(WheelConfig.compute_hash) == "function" then
    return WheelConfig.compute_hash(str)
  end
  if WheelContext and type(WheelContext.compute_hash) == "function" then
    return WheelContext.compute_hash(str)
  end
  local h1 = 0x811c9dc5
  local h2 = 0x27d4eb2f
  local len = #str
  for i = 1, len do
    local b = string.byte(str, i)
    h1 = (h1 * 16777619 + b) % 4294967296
    h2 = (h2 * 2166136261 + b) % 4294967296
  end
  return string.format("%08x%08x%08x%08x%08x%08x%08x%08x",
    h1, h2, (h1 + h2) % 4294967296, (h1 * 31 + h2) % 4294967296,
    h2, h1, (h2 * 17 + h1) % 4294967296, (h1 * 13 + h2 * 7) % 4294967296)
end

-- ---------------------------------------------------------------------------
-- Path Sandboxing & Canonicalization
-- ---------------------------------------------------------------------------

--- Canonicalize and sanitize a path relative to workspace_root.
-- Defensively prevents directory traversal attacks (e.g. "../../../etc/passwd").
-- @param path string Target path
-- @param workspace_root string? Workspace root (defaults to ".")
-- @return string|nil resolved_path, string|nil error_reason
function WheelTool.sanitize_path(path, workspace_root)
  if type(path) ~= "string" or #path == 0 then
    return nil, "empty_path"
  end

  local root = workspace_root or "."
  -- Normalize slashes
  path = path:gsub("\\", "/")
  root = root:gsub("\\", "/")

  -- Remove trailing slashes unless root is "/"
  if #root > 1 and root:sub(-1) == "/" then
    root = root:sub(1, -2)
  end

  -- Split components
  local function split_parts(p)
    local parts = {}
    for part in p:gmatch("[^/]+") do
      if part == "." then
        -- skip current dir
      elseif part == ".." then
        if #parts > 0 and parts[#parts] ~= ".." then
          table.remove(parts)
        else
          table.insert(parts, "..")
        end
      else
        table.insert(parts, part)
      end
    end
    return parts
  end

  local is_absolute = (path:sub(1, 1) == "/")
  local root_parts = split_parts(root)
  local path_parts = split_parts(path)

  local resolved_parts
  if is_absolute then
    -- Check if absolute path starts with root
    local root_is_abs = (root:sub(1, 1) == "/")
    if not root_is_abs then
      return nil, "path_traversal_denied: absolute path prohibited in relative workspace"
    end
    -- Must prefix match root_parts
    if #path_parts < #root_parts then
      return nil, "path_traversal_denied: path escapes workspace root"
    end
    for i = 1, #root_parts do
      if path_parts[i] ~= root_parts[i] then
        return nil, "path_traversal_denied: path escapes workspace root"
      end
    end
    resolved_parts = path_parts
  else
    -- Relative path: resolve against root_parts
    resolved_parts = {}
    for _, p in ipairs(root_parts) do
      table.insert(resolved_parts, p)
    end
    for _, p in ipairs(path_parts) do
      if p == ".." then
        if #resolved_parts <= #root_parts then
          return nil, "path_traversal_denied: path escapes workspace root"
        end
        table.remove(resolved_parts)
      else
        table.insert(resolved_parts, p)
      end
    end
  end

  -- Verify resolved path still begins with root_parts
  if #resolved_parts < #root_parts then
    return nil, "path_traversal_denied: path escapes workspace root"
  end
  for i = 1, #root_parts do
    if resolved_parts[i] ~= root_parts[i] then
      return nil, "path_traversal_denied: path escapes workspace root"
    end
  end

  local prefix = (root:sub(1, 1) == "/") and "/" or ""
  local clean = prefix .. table.concat(resolved_parts, "/")
  if clean == "" then clean = "." end
  return clean, nil
end

-- ---------------------------------------------------------------------------
-- Dangerous Command Guard
-- ---------------------------------------------------------------------------

local DANGEROUS_PATTERNS = {
  "rm%s+%-r?f?%s+/%s*$",
  "rm%s+%-r?f?%s+/[%s;%|%*]",
  "rm%s+%-r?f?%s+/[%a]+",
  "rm%s+%-r?f?%s+~",
  "rm%s+%-r?f?%s+%.%./",
  "mkfs%.",
  "dd%s+if=.*%s+of=/dev/",
  ">[%s]*/dev/sd",
  ":%(%){%s*:|:&%s*};:",
  "chmod%s+%-R?%s+777%s+/",
  "^%s*shutdown",
  "^%s*reboot",
  "[%s;|]shutdown",
  "[%s;|]reboot",
}

--- Check if a shell command matches any catastrophic pattern.
-- @param cmd string Command string
-- @return boolean is_dangerous, string? reason
function WheelTool.check_dangerous_command(cmd)
  if type(cmd) ~= "string" then
    return false, nil
  end
  for _, pattern in ipairs(DANGEROUS_PATTERNS) do
    if cmd:find(pattern) then
      return true, "dangerous_command_blocked: pattern matches catastrophic operation (" .. pattern .. ")"
    end
  end
  return false, nil
end

-- ---------------------------------------------------------------------------
-- Role Authority Gating
-- ---------------------------------------------------------------------------

--- Verify if an agent role has authority to execute a tool with the given intent.
-- Research and Reviewer roles are strictly read-only and fail-closed on Modify or Execute intents.
-- @param role string Role from WheelAgent.Role
-- @param tool_schema table Tool schema definition
-- @return boolean allowed, string? reason
function WheelTool.check_role_authority(role, tool_schema)
  local intent = tool_schema.intent or WheelTool.ActionIntent.INSPECT
  local role_lower = (role or ""):lower()

  if role_lower == "research" or role_lower == "reviewer" then
    if intent == WheelTool.ActionIntent.MODIFY then
      return false, string.format("role_authority_violation: role '%s' has read-only authority; cannot execute tool '%s' with intent 'modify'", role, tool_schema.name)
    elseif intent == WheelTool.ActionIntent.EXECUTE then
      return false, string.format("role_authority_violation: role '%s' has read-only authority; cannot execute tool '%s' with intent 'execute'", role, tool_schema.name)
    elseif intent == WheelTool.ActionIntent.CUSTOM and not tool_schema.read_only then
      return false, string.format("role_authority_violation: role '%s' has read-only authority; cannot execute mutating custom tool '%s'", role, tool_schema.name)
    end
  elseif role_lower == "commander" then
    if intent == WheelTool.ActionIntent.MODIFY then
      return false, string.format("role_authority_violation: role 'Commander' plans and orchestrates; direct code modification via '%s' must be delegated to a Worker", tool_schema.name)
    end
  end

  return true, nil
end

-- ---------------------------------------------------------------------------
-- Standardized Action Outcome & Auto-Spillover Pipeline
-- ---------------------------------------------------------------------------

local ActionOutcome = {}
ActionOutcome.__index = ActionOutcome

--- Format an outcome for insertion into Zone 3 dynamic prompt context.
-- If the outcome spilled, includes the content-addressed blob hash and head/tail preview.
-- @return string Formatted observation string
function ActionOutcome:format_observation()
  local lines = {}
  local header = string.format("[Tool: %s (exit=%d, %dms%s)]",
    self.tool or "unknown",
    self.exit_code or 0,
    self.duration_ms or 0,
    self.spilled and (", spilled=" .. tostring(self.spillover_hash):sub(1, 16) .. "...") or "")
  table.insert(lines, header)

  if self.preview and #self.preview > 0 then
    table.insert(lines, self.preview)
  elseif self.stdout and #self.stdout > 0 then
    table.insert(lines, self.stdout)
  end

  if self.stderr and #self.stderr > 0 and not self.spilled then
    table.insert(lines, "STDERR: " .. self.stderr)
  end

  return table.concat(lines, "\n")
end

--- Serialize outcome to plain table.
-- @return table
function ActionOutcome:to_table()
  return {
    action_id = self.action_id,
    tool = self.tool,
    intent = self.intent,
    success = self.success,
    status = self.status,
    exit_code = self.exit_code,
    duration_ms = self.duration_ms,
    stdout = self.stdout,
    stderr = self.stderr,
    spilled = self.spilled,
    spillover_hash = self.spillover_hash,
    spillover_bytes = self.spillover_bytes,
    preview = self.preview,
  }
end

WheelTool.ActionOutcome = ActionOutcome

--- Process raw tool outcome through the auto-spillover pipeline.
-- If stdout + stderr exceeds threshold, persists full output into context/kernel
-- as a content-addressed blob, and returns bounded head/tail preview.
-- @param raw table { tool = string, intent = string, success = boolean, exit_code = number, stdout = string, stderr = string, duration_ms = number, action_id = string? }
-- @param opts table? { threshold_bytes = number?, context = table?, kernel = table? }
-- @return table ActionOutcome instance
function WheelTool.process_spillover(raw, opts)
  opts = opts or {}
  local threshold = opts.threshold_bytes or WheelTool.DEFAULT_SPILLOVER_THRESHOLD
  local stdout = raw.stdout or ""
  local stderr = raw.stderr or ""
  local total_bytes = #stdout + #stderr

  local self = setmetatable({}, ActionOutcome)
  self.action_id = raw.action_id or ("act-" .. tostring(os.time()))
  self.tool = raw.tool or "unknown"
  self.intent = raw.intent or WheelTool.ActionIntent.INSPECT
  self.success = (raw.success ~= false)
  self.status = raw.status or (self.success and WheelTool.OutcomeStatus.SUCCESS or WheelTool.OutcomeStatus.FAILURE)
  self.exit_code = raw.exit_code or (self.success and 0 or 1)
  self.duration_ms = raw.duration_ms or 0
  self.stdout = stdout
  self.stderr = stderr

  if total_bytes > threshold then
    local full_payload = stdout
    if #stderr > 0 then
      full_payload = full_payload .. "\n--- STDERR ---\n" .. stderr
    end
    local hash = WheelTool.compute_hash(full_payload)

    -- Persist blob into context if context available
    if opts.context and type(opts.context.put_slot) == "function" then
      opts.context:put_slot("blobs/" .. hash, full_payload)
    elseif opts.kernel and type(opts.kernel.put_slot) == "function" then
      opts.kernel:put_slot("blobs/" .. hash, full_payload)
    end

    -- Construct bounded head/tail preview
    local lines = {}
    for line in stdout:gmatch("([^\r\n]*)\r?\n?") do
      if #line > 0 or #lines == 0 then
        table.insert(lines, line)
      end
    end

    local preview_lines = {}
    local max_head = 10
    local max_tail = 5
    local total_lines = #lines

    if total_lines <= (max_head + max_tail) then
      for _, l in ipairs(lines) do
        table.insert(preview_lines, l)
      end
    else
      for i = 1, max_head do
        table.insert(preview_lines, lines[i])
      end
      local spilled_count = total_bytes
      table.insert(preview_lines, string.format("\n[... %d bytes spilled to blob: %s (use read_blob to inspect full content) ...]\n", spilled_count, hash))
      for i = total_lines - max_tail + 1, total_lines do
        table.insert(preview_lines, lines[i])
      end
    end

    self.spilled = true
    self.spillover_hash = hash
    self.spillover_bytes = total_bytes
    self.preview = table.concat(preview_lines, "\n")
  else
    self.spilled = false
    self.spillover_hash = nil
    self.spillover_bytes = 0
    local p = stdout
    if #stderr > 0 then
      p = p .. (#p > 0 and "\n" or "") .. "STDERR: " .. stderr
    end
    self.preview = p
  end

  return self
end

-- ---------------------------------------------------------------------------
-- Core Engineering Tools Implementations
-- ---------------------------------------------------------------------------

--- Tool: read_file
-- Intent: INSPECT
local tool_read_file = {
  name = "read_file",
  intent = WheelTool.ActionIntent.INSPECT,
  description = "Read file content within workspace root with optional line range and bounds",
  parameters = {
    type = "object",
    properties = {
      path = { type = "string", description = "Relative path to file in workspace" },
      start_line = { type = "integer", description = "Optional 1-indexed start line" },
      end_line = { type = "integer", description = "Optional 1-indexed end line" },
      max_bytes = { type = "integer", description = "Max bytes to read (default 65536)" },
    },
    required = { "path" },
  },
  execute = function(args, env)
    local path = args.path
    local clean_path, err = WheelTool.sanitize_path(path, env.workspace_root)
    if not clean_path then
      return { success = false, exit_code = 1, stderr = err }
    end

    local f, open_err = io.open(clean_path, "r")
    if not f then
      return { success = false, exit_code = 1, stderr = "File not found: " .. tostring(path) .. " (" .. tostring(open_err) .. ")" }
    end

    local max_b = args.max_bytes or WheelTool.DEFAULT_MAX_READ_BYTES
    local start_l = args.start_line
    local end_l = args.end_line

    local lines = {}
    local line_no = 0
    local bytes_accum = 0
    local truncated = false

    for line in f:lines() do
      line_no = line_no + 1
      local in_range = true
      if start_l and line_no < start_l then
        in_range = false
      end
      if end_l and line_no > end_l then
        in_range = false
      end

      if in_range then
        local l_len = #line + 1
        if bytes_accum + l_len > max_b then
          truncated = true
          break
        end
        table.insert(lines, line)
        bytes_accum = bytes_accum + l_len
      end
      if end_l and line_no >= end_l then
        break
      end
    end
    f:close()

    local content = table.concat(lines, "\n")
    if truncated then
      content = content .. string.format("\n[... output truncated at %d bytes ...]", bytes_accum)
    end

    return {
      success = true,
      exit_code = 0,
      stdout = content,
      stderr = "",
      lines_read = #lines,
      total_lines = line_no,
    }
  end,
}

--- Tool: write_file
-- Intent: MODIFY
local tool_write_file = {
  name = "write_file",
  intent = WheelTool.ActionIntent.MODIFY,
  description = "Write content to a file within workspace root",
  parameters = {
    type = "object",
    properties = {
      path = { type = "string", description = "Relative path to file in workspace" },
      content = { type = "string", description = "Exact content to write" },
      overwrite = { type = "boolean", description = "Allow overwriting existing file (default false)" },
    },
    required = { "path", "content" },
  },
  execute = function(args, env)
    local path = args.path
    local clean_path, err = WheelTool.sanitize_path(path, env.workspace_root)
    if not clean_path then
      return { success = false, exit_code = 1, stderr = err }
    end

    -- Check if file already exists
    local existing = io.open(clean_path, "r")
    if existing then
      existing:close()
      if not args.overwrite then
        return { success = false, exit_code = 1, stderr = "File already exists and overwrite is false: " .. tostring(path) }
      end
    end

    -- Ensure parent directory exists
    local parent = clean_path:match("^(.*)/[^/]+$")
    if parent and parent ~= "" and parent ~= "." then
      os.execute(string.format("mkdir -p %q", parent))
    end

    local f, write_err = io.open(clean_path, "w")
    if not f then
      return { success = false, exit_code = 1, stderr = "Failed to open file for writing: " .. tostring(write_err) }
    end
    f:write(args.content or "")
    f:close()

    return {
      success = true,
      exit_code = 0,
      stdout = string.format("Wrote %d bytes to %s", #(args.content or ""), path),
      stderr = "",
    }
  end,
}

--- Tool: edit_file
-- Intent: MODIFY
local tool_edit_file = {
  name = "edit_file",
  intent = WheelTool.ActionIntent.MODIFY,
  description = "Replace exact target string with replacement in a file within workspace root",
  parameters = {
    type = "object",
    properties = {
      path = { type = "string", description = "Relative path to file in workspace" },
      target = { type = "string", description = "Exact target text to find" },
      replacement = { type = "string", description = "Replacement text" },
      allow_multiple = { type = "boolean", description = "Allow multiple matches (default false)" },
    },
    required = { "path", "target", "replacement" },
  },
  execute = function(args, env)
    local path = args.path
    local clean_path, err = WheelTool.sanitize_path(path, env.workspace_root)
    if not clean_path then
      return { success = false, exit_code = 1, stderr = err }
    end

    local f, open_err = io.open(clean_path, "r")
    if not f then
      return { success = false, exit_code = 1, stderr = "File not found: " .. tostring(path) .. " (" .. tostring(open_err) .. ")" }
    end
    local content = f:read("*a")
    f:close()

    local target = args.target
    local replacement = args.replacement
    if not target or #target == 0 then
      return { success = false, exit_code = 1, stderr = "Empty target string" }
    end

    -- Count occurrences using literal substring match
    local count = 0
    local pos = 1
    local t_len = #target
    local matches = {}
    while true do
      local s, e = string.find(content, target, pos, true)
      if not s then break end
      count = count + 1
      table.insert(matches, { s = s, e = e })
      pos = e + 1
    end

    if count == 0 then
      return { success = false, exit_code = 1, stderr = "Target string not found in " .. tostring(path) }
    end
    if count > 1 and not args.allow_multiple then
      return { success = false, exit_code = 1, stderr = string.format("Target string found %d times in %s (allow_multiple is false)", count, path) }
    end

    -- Perform replacements from end to beginning to keep offsets stable
    local new_content = content
    for i = #matches, 1, -1 do
      local m = matches[i]
      new_content = new_content:sub(1, m.s - 1) .. replacement .. new_content:sub(m.e + 1)
    end

    local out_f, write_err = io.open(clean_path, "w")
    if not out_f then
      return { success = false, exit_code = 1, stderr = "Failed to open file for writing: " .. tostring(write_err) }
    end
    out_f:write(new_content)
    out_f:close()

    return {
      success = true,
      exit_code = 0,
      stdout = string.format("Replaced %d occurrence(s) in %s", count, path),
      stderr = "",
    }
  end,
}

--- Tool: run_command
-- Intent: EXECUTE
local tool_run_command = {
  name = "run_command",
  intent = WheelTool.ActionIntent.EXECUTE,
  description = "Execute a shell command within workspace root directory",
  parameters = {
    type = "object",
    properties = {
      command = { type = "string", description = "Shell command line to execute" },
      cwd = { type = "string", description = "Optional working directory relative to workspace root" },
      timeout_ms = { type = "integer", description = "Optional timeout in milliseconds" },
    },
    required = { "command" },
  },
  execute = function(args, env)
    local cmd = args.command
    if not cmd or #cmd == 0 then
      return { success = false, exit_code = 1, stderr = "Empty command" }
    end

    local dangerous, reason = WheelTool.check_dangerous_command(cmd)
    if dangerous then
      return { success = false, exit_code = 126, stderr = reason }
    end

    -- Allow test double injection via env.command_runner
    if env.command_runner and type(env.command_runner) == "function" then
      return env.command_runner(args, env)
    end

    local cwd = env.workspace_root or "."
    if args.cwd then
      local clean_cwd, cwd_err = WheelTool.sanitize_path(args.cwd, env.workspace_root)
      if not clean_cwd then
        return { success = false, exit_code = 1, stderr = cwd_err }
      end
      cwd = clean_cwd
    end

    local full_cmd = string.format("cd %q && (%s) 2>&1", cwd, cmd)
    local p = io.popen(full_cmd, "r")
    if not p then
      return { success = false, exit_code = 1, stderr = "Failed to spawn shell process" }
    end

    local out = p:read("*a") or ""
    local ok_close, exit_type, exit_code = p:close()

    local code = 0
    if ok_close == true or ok_close == 0 then
      code = 0
    elseif type(exit_code) == "number" then
      code = exit_code
    elseif type(ok_close) == "number" then
      code = ok_close
    else
      code = (out:find("error") or out:find("FAILED")) and 1 or 0
    end

    return {
      success = (code == 0),
      exit_code = code,
      stdout = out,
      stderr = "",
    }
  end,
}

--- Tool: list_directory
-- Intent: INSPECT
local tool_list_directory = {
  name = "list_directory",
  intent = WheelTool.ActionIntent.INSPECT,
  description = "List entries in a directory relative to workspace root",
  parameters = {
    type = "object",
    properties = {
      path = { type = "string", description = "Relative directory path (default .)" },
      max_entries = { type = "integer", description = "Max entries to return (default 100)" },
    },
  },
  execute = function(args, env)
    local path = args.path or "."
    local clean_path, err = WheelTool.sanitize_path(path, env.workspace_root)
    if not clean_path then
      return { success = false, exit_code = 1, stderr = err }
    end

    local max_entries = args.max_entries or 100
    local cmd = string.format("ls -la %q 2>&1", clean_path)
    local p = io.popen(cmd, "r")
    if not p then
      return { success = false, exit_code = 1, stderr = "Failed to list directory: " .. clean_path }
    end

    local entries = {}
    local count = 0
    for line in p:lines() do
      count = count + 1
      if count <= max_entries then
        table.insert(entries, line)
      end
    end
    p:close()

    return {
      success = true,
      exit_code = 0,
      stdout = table.concat(entries, "\n"),
      stderr = "",
      total_entries = count,
    }
  end,
}

--- Tool: search_code
-- Intent: INSPECT
local tool_search_code = {
  name = "search_code",
  intent = WheelTool.ActionIntent.INSPECT,
  description = "Search files for a query string within workspace root",
  parameters = {
    type = "object",
    properties = {
      query = { type = "string", description = "Search query string" },
      path = { type = "string", description = "Subdirectory to search (default .)" },
      case_sensitive = { type = "boolean", description = "Case sensitive search (default true)" },
    },
    required = { "query" },
  },
  execute = function(args, env)
    local query = args.query
    if not query or #query == 0 then
      return { success = false, exit_code = 1, stderr = "Empty search query" }
    end

    local path = args.path or "."
    local clean_path, err = WheelTool.sanitize_path(path, env.workspace_root)
    if not clean_path then
      return { success = false, exit_code = 1, stderr = err }
    end

    local flag = (args.case_sensitive == false) and "-i" or ""
    local cmd = string.format("grep -rn %s -F %q %q 2>/dev/null | head -n 100", flag, query, clean_path)
    local p = io.popen(cmd, "r")
    if not p then
      return { success = false, exit_code = 1, stderr = "Failed to execute search" }
    end
    local out = p:read("*a") or ""
    p:close()

    return {
      success = true,
      exit_code = 0,
      stdout = out,
      stderr = "",
    }
  end,
}

--- Tool: read_blob
-- Intent: INSPECT
local tool_read_blob = {
  name = "read_blob",
  intent = WheelTool.ActionIntent.INSPECT,
  description = "Read spilled content-addressed blob from context memory or kernel",
  parameters = {
    type = "object",
    properties = {
      hash = { type = "string", description = "Content-addressed SHA-256 hash" },
      offset = { type = "integer", description = "Byte offset (default 0)" },
      length = { type = "integer", description = "Byte length to read" },
    },
    required = { "hash" },
  },
  execute = function(args, env)
    local hash = args.hash
    if not hash or #hash == 0 then
      return { success = false, exit_code = 1, stderr = "Missing blob hash" }
    end

    local slot_name = "blobs/" .. hash
    local content = nil

    if env.context and type(env.context.get_slot) == "function" then
      local s = env.context:get_slot(slot_name)
      if s and s.found then
        content = s.content
      end
    end

    if not content and env.kernel and type(env.kernel.get_slot) == "function" then
      local s = env.kernel:get_slot(slot_name)
      if s and s.found then
        content = s.content
      end
    end

    if not content then
      return { success = false, exit_code = 1, stderr = "Blob not found: " .. tostring(hash) }
    end

    local offset = args.offset or 0
    local len = args.length or #content
    local slice = content:sub(offset + 1, offset + len)

    return {
      success = true,
      exit_code = 0,
      stdout = slice,
      stderr = "",
      total_bytes = #content,
    }
  end,
}

WheelTool.CORE_TOOLS = {
  tool_read_file,
  tool_write_file,
  tool_edit_file,
  tool_run_command,
  tool_list_directory,
  tool_search_code,
  tool_read_blob,
}

-- ---------------------------------------------------------------------------
-- Tool Registry & Dispatch Engine
-- ---------------------------------------------------------------------------

local WheelToolRegistry = {}
WheelToolRegistry.__index = WheelToolRegistry

--- Create a new WheelToolRegistry.
-- @param opts table? { spillover_threshold = number? }
-- @return table WheelToolRegistry instance
function WheelToolRegistry.new(opts)
  opts = opts or {}
  local self = setmetatable({}, WheelToolRegistry)
  self._tools = {}
  self.spillover_threshold = opts.spillover_threshold or WheelTool.DEFAULT_SPILLOVER_THRESHOLD

  -- Register default core tools
  for _, tool in ipairs(WheelTool.CORE_TOOLS) do
    self:register_tool(tool)
  end

  return self
end

--- Register a tool schema into the registry.
-- @param tool table Tool definition with name, intent, description, execute
function WheelToolRegistry:register_tool(tool)
  if type(tool) ~= "table" then
    error("Tool definition must be a table")
  end
  if type(tool.name) ~= "string" or #tool.name == 0 then
    error("Tool requires a non-empty string 'name'")
  end
  if type(tool.execute) ~= "function" then
    error("Tool '" .. tool.name .. "' requires an 'execute' function")
  end
  tool.intent = tool.intent or WheelTool.ActionIntent.INSPECT
  self._tools[tool.name] = tool
end

--- Get a tool by name.
-- @param name string
-- @return table?
function WheelToolRegistry:get_tool(name)
  return self._tools[name]
end

--- List all registered tool schemas.
-- @return table[] List of tool schemas sorted by name
function WheelToolRegistry:list_tools()
  local list = {}
  for _, tool in pairs(self._tools) do
    table.insert(list, {
      name = tool.name,
      intent = tool.intent,
      description = tool.description or "",
      parameters = tool.parameters or {},
    })
  end
  table.sort(list, function(a, b) return a.name < b.name end)
  return list
end

--- Dispatch and execute a tool under environment safety boundaries.
-- Enforces:
-- 1. Tool existence check
-- 2. Role authority check (Research/Reviewer read-only fail-closed)
-- 3. Execution boundary inside pcall
-- 4. Latency measurement
-- 5. Auto-spillover pipeline
-- 6. Kernel action recording & ContextBus notification
-- @param name string Tool name
-- @param args table Tool arguments
-- @param env table Environment { role = string?, agent_name = string?, workspace_root = string?, kernel = table?, context = table?, command_runner = function? }
-- @return table ActionOutcome instance
function WheelToolRegistry:dispatch(name, args, env)
  args = args or {}
  env = env or {}
  local tool = self._tools[name]
  if not tool then
    return WheelTool.process_spillover({
      tool = name,
      intent = WheelTool.ActionIntent.CUSTOM,
      success = false,
      status = WheelTool.OutcomeStatus.ERROR,
      exit_code = 1,
      stderr = "Unknown tool: " .. tostring(name),
      duration_ms = 0,
    })
  end

  -- 1. Role authority verification
  if env.role then
    local allowed, reason = WheelTool.check_role_authority(env.role, tool)
    if not allowed then
      return WheelTool.process_spillover({
        tool = name,
        intent = tool.intent,
        success = false,
        status = WheelTool.OutcomeStatus.DENIED,
        exit_code = 126,
        stderr = reason,
        duration_ms = 0,
      })
    end
  end

  -- 2. Execute tool inside pcall
  local start_time = os.clock()
  local ok, res = pcall(tool.execute, args, env)
  local elapsed_ms = math.floor((os.clock() - start_time) * 1000)

  local raw_outcome
  if not ok then
    raw_outcome = {
      tool = name,
      intent = tool.intent,
      success = false,
      status = WheelTool.OutcomeStatus.ERROR,
      exit_code = 1,
      stderr = "Tool execution crashed: " .. tostring(res),
      duration_ms = elapsed_ms,
    }
  elseif type(res) ~= "table" then
    raw_outcome = {
      tool = name,
      intent = tool.intent,
      success = false,
      status = WheelTool.OutcomeStatus.ERROR,
      exit_code = 1,
      stderr = "Tool returned non-table result",
      duration_ms = elapsed_ms,
    }
  else
    raw_outcome = {
      tool = name,
      intent = tool.intent,
      success = (res.success ~= false),
      status = res.status or (res.success ~= false and WheelTool.OutcomeStatus.SUCCESS or WheelTool.OutcomeStatus.FAILURE),
      exit_code = res.exit_code or (res.success ~= false and 0 or 1),
      stdout = res.stdout or "",
      stderr = res.stderr or "",
      duration_ms = res.duration_ms or elapsed_ms,
    }
  end

  -- 3. Run auto-spillover pipeline
  local outcome = WheelTool.process_spillover(raw_outcome, {
    threshold_bytes = self.spillover_threshold,
    context = env.context,
    kernel = env.kernel,
  })

  -- 4. Record action in kernel if kernel present
  if env.kernel and type(env.kernel.record_action) == "function" then
    pcall(function()
      env.kernel:record_action({
        action_id = outcome.action_id,
        success = outcome.success,
        exit_code = outcome.exit_code,
        duration_ms = outcome.duration_ms,
        raw_stdout = outcome.stdout,
        raw_stderr = outcome.stderr,
      })
    end)
  end

  -- 5. Publish event to ContextBus if context.bus present
  if env.context and env.context.bus and type(env.context.bus.publish) == "function" then
    pcall(function()
      env.context.bus:publish({
        type = "action_executed",
        tool = outcome.tool,
        intent = outcome.intent,
        success = outcome.success,
        spilled = outcome.spilled,
        agent = env.agent_name or "unknown",
      })
    end)
  end

  return outcome
end

WheelTool.Registry = WheelToolRegistry

-- Global default registry singleton
local _default_registry = nil
function WheelTool.get_default_registry()
  if not _default_registry then
    _default_registry = WheelToolRegistry.new()
  end
  return _default_registry
end

return WheelTool
