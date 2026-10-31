-- Wheel Agent Runtime
-- Software Engineering agent harness per research record 046.
-- Fixed domain: Software Engineering only (coding copilot, debugger, reviewer, commander).
-- Roles vary by configuration inside that domain, bounded by budgets and permissions.

local WheelAgent = {}
local AGENT_IDENTITY = setmetatable({}, { __mode = "k" })
local AGENT_AUTHORITY = setmetatable({}, { __mode = "k" })

local function authoritative_identity(agent)
  return AGENT_IDENTITY[agent]
end

local function authoritative_binding(agent)
  local authority = AGENT_AUTHORITY[agent]
  return authority and authority.role_binding or nil
end

local ok_tool, WheelTool = pcall(require, "wheel.tool")
if not ok_tool then
  local ok_tool2, WheelTool2 = pcall(require, "lua.wheel.tool")
  WheelTool = ok_tool2 and WheelTool2 or nil
end
WheelAgent.Tool = WheelTool

local ok_provider, WheelProvider = pcall(require, "wheel.provider")
if not ok_provider then
  local ok_p2, WheelP2 = pcall(require, "lua.wheel.provider")
  WheelProvider = ok_p2 and WheelP2 or nil
end
WheelAgent.Provider = WheelProvider

local ok_runner, WheelRunner = pcall(require, "wheel.runner")
if not ok_runner then
  local ok_r2, WheelR2 = pcall(require, "lua.wheel.runner")
  WheelRunner = ok_r2 and WheelR2 or nil
end
WheelAgent.Runner = WheelRunner

local function load_lifecycle()
  local rooted = "wheel.lifecycle"
  local ok, value = pcall(require, rooted)
  if ok then return value end
  package.loaded[rooted] = nil
  if type(value) ~= "string" or not value:find("module '" .. rooted .. "' not found", 1, true) then error(value, 0) end
  local alternate = "lua." .. rooted
  ok, value = pcall(require, alternate)
  if ok then return value end
  package.loaded[alternate] = nil
  if type(value) ~= "string" or not value:find("module '" .. alternate .. "' not found", 1, true) then error(value, 0) end
  return nil
end
local WheelLifecycle = load_lifecycle()
WheelAgent.Lifecycle = WheelLifecycle

--- Agent role definitions.
WheelAgent.Role = {
  COMMANDER = "commander",
  CODING = "coding",
  DEBUG = "debug",
  RESEARCH = "research",
  REVIEWER = "reviewer",
}

--- Read-only tool allowlist enforced for Research and Reviewer roles.
local READ_ONLY_TOOLS = {
  ["read_file"] = true,
  ["view_file"] = true,
  ["search_code"] = true,
  ["find_files"] = true,
  ["list_directory"] = true,
  ["inspect"] = true,
  ["git_diff"] = true,
  ["git_log"] = true,
  ["git_status"] = true,
  ["read_resource"] = true,
  ["list_resources"] = true,
  ["read_url_content"] = true,
  ["search_web"] = true,
  ["ask_question"] = true,
  ["get_outline"] = true,
}

WheelAgent.READ_ONLY_TOOLS = READ_ONLY_TOOLS

-- Capability vocabulary. Authorization is decided from the granted capability
-- set on the current RoleBinding, never from a role word in prompt or identity
-- text. The role matrix remains private to this module.
WheelAgent.Capability = {
  INSPECT = "inspect",
  VERIFY = "verify",
  ORCHESTRATE = "orchestrate",
  MODIFY = "modify",
  EXECUTE = "execute",
}

local CAPABILITY_ORDER = {
  WheelAgent.Capability.INSPECT,
  WheelAgent.Capability.VERIFY,
  WheelAgent.Capability.ORCHESTRATE,
  WheelAgent.Capability.MODIFY,
  WheelAgent.Capability.EXECUTE,
}
local CAPABILITY_VALUES = {}
for _, capability in ipairs(CAPABILITY_ORDER) do CAPABILITY_VALUES[capability] = true end

--- Canonical role capability matrix. Read-only roles never hold Modify or
-- Execute, and Commander orchestrates without direct code modification.
local ROLE_CAPABILITIES = {
  [WheelAgent.Role.COMMANDER] = {
    inspect = true, verify = true, orchestrate = true,
  },
  [WheelAgent.Role.CODING] = {
    inspect = true, verify = true, modify = true, execute = true,
  },
  [WheelAgent.Role.DEBUG] = {
    inspect = true, verify = true, modify = true, execute = true,
  },
  [WheelAgent.Role.RESEARCH] = {
    inspect = true, verify = true,
  },
  [WheelAgent.Role.REVIEWER] = {
    inspect = true, verify = true,
  },
}
local ROLE_VALUES = {}
for _, role in pairs(WheelAgent.Role) do ROLE_VALUES[role] = true end

local MAX_IDENTITY_BYTES = 128
local MAX_REASON_BYTES = 256
local MAX_BINDING_ID_BYTES = 128
local BINDING_ID_AGENT_BYTES = 48
local POLICY_GENERATION_START = 1
local MAX_POLICY_GENERATION = 9007199254740991
local IDENTIFIER_PATTERN = "^[A-Za-z0-9][A-Za-z0-9._:/%-]*$"
local COMMIT_HASH_PATTERN = "^[0-9a-f]+$"
local COMMIT_HASH_BYTES = 64

--- Return a defensive ordered copy of a capability set for a role.
-- @param role string Role from WheelAgent.Role
-- @return table|nil capabilities
function WheelAgent.role_capabilities(role)
  local matrix = ROLE_CAPABILITIES[role]
  if not matrix then return nil end
  local result = {}
  for _, capability in ipairs(CAPABILITY_ORDER) do
    if matrix[capability] then result[#result + 1] = capability end
  end
  return result
end

local function bounded_string(value, limit)
  if type(value) ~= "string" or value == "" or #value > limit then return nil end
  if value:find("[%z\1-\31\127]") then return nil end
  return value
end

local function capability_map(list)
  local result = {}
  for _, capability in ipairs(list or {}) do result[capability] = true end
  return result
end

local function capability_diff(left, right)
  local other = capability_map(right)
  local result = {}
  for _, capability in ipairs(left or {}) do
    if not other[capability] then result[#result + 1] = capability end
  end
  return result
end

local function normalize_capabilities(role, requested)
  local matrix = ROLE_CAPABILITIES[role]
  local canonical = WheelAgent.role_capabilities(role)
  if not matrix or not canonical then return nil, "unknown role: " .. tostring(role) end
  if requested == nil then return canonical end
  if type(requested) ~= "table" then return nil, "capabilities must be an array" end
  local seen = {}
  for key in pairs(requested) do
    if type(key) ~= "number" or key < 1 or key % 1 ~= 0 then
      return nil, "capabilities must be a dense array"
    end
  end
  local count = 0
  for index = 1, #requested do
    local capability = requested[index]
    if not CAPABILITY_VALUES[capability] then
      return nil, "unknown capability: " .. tostring(capability)
    end
    if seen[capability] then return nil, "duplicate capability: " .. capability end
    if not matrix[capability] then
      return nil, "role '" .. role .. "' may not hold capability '" .. capability .. "'"
    end
    seen[capability] = true
    count = count + 1
  end
  if count ~= #requested then return nil, "capabilities must be a dense array" end
  if count == 0 then return nil, "capabilities must not be empty" end
  local ordered = {}
  for _, capability in ipairs(CAPABILITY_ORDER) do
    if seen[capability] then ordered[#ordered + 1] = capability end
  end
  return ordered
end

local function default_binding_id(agent_id, generation)
  local component = tostring(agent_id or "agent"):gsub("[^A-Za-z0-9._%-]", "-")
  component = component:sub(1, BINDING_ID_AGENT_BYTES)
  if component == "" or component:sub(1, 1):match("^[A-Za-z0-9]$") == nil then
    component = "agent-" .. component
  end
  return string.format("role-binding:%s:%d", component, generation)
end

--- Validate and normalize a RoleBinding. A binding carries the granted
-- capability state and a monotonic policy generation. Explicit capabilities may
-- only narrow the canonical role matrix.
-- @param binding table|nil { role, binding_id?, policy_generation?, capabilities? }
-- @param agent_id string|nil Stable Agent identity the binding is issued to
-- @return table|nil normalized binding, string? error
function WheelAgent.normalize_role_binding(binding, agent_id)
  if type(binding) ~= "table" then return nil, "role binding must be a table" end
  local role = binding.role
  if type(role) ~= "string" or not ROLE_VALUES[role] then
    return nil, "invalid role: " .. tostring(role)
  end
  local generation = binding.policy_generation
  if generation == nil then generation = POLICY_GENERATION_START end
  if type(generation) ~= "number" or generation ~= generation or generation % 1 ~= 0
    or generation < POLICY_GENERATION_START or generation > MAX_POLICY_GENERATION then
    return nil, "policy_generation must be a positive integer"
  end
  local capabilities, capability_err = normalize_capabilities(role, binding.capabilities)
  if not capabilities then return nil, capability_err end
  local binding_id = binding.binding_id
  if binding_id == nil then
    binding_id = default_binding_id(agent_id, generation)
  else
    if not bounded_string(binding_id, MAX_BINDING_ID_BYTES) or not binding_id:match(IDENTIFIER_PATTERN) then
      return nil, "binding_id must be a bounded identifier"
    end
  end
  return {
    role = role,
    binding_id = binding_id,
    policy_generation = generation,
    capabilities = capabilities,
  }
end

local function copy_lineage(lineage)
  if type(lineage) ~= "table" then return nil end
  return {
    forked_from_agent = lineage.forked_from_agent,
    forked_from_session = lineage.forked_from_session,
    base_context_commit = lineage.base_context_commit,
    reason = lineage.reason,
  }
end

--- Validate immutable fork lineage. Lineage records references only; it never
-- carries transcripts, prompts, or copied context content.
-- @param lineage table
-- @return table|nil normalized lineage, string? error
function WheelAgent.validate_lineage(lineage)
  if type(lineage) ~= "table" then return nil, "lineage must be a table" end
  local allowed = {
    forked_from_agent = true, forked_from_session = true,
    base_context_commit = true, reason = true,
  }
  for key in pairs(lineage) do
    if not allowed[key] then return nil, "lineage contains an unknown field" end
  end
  local parent = bounded_string(lineage.forked_from_agent, MAX_IDENTITY_BYTES)
  if not parent then return nil, "lineage forked_from_agent is invalid" end
  local session = lineage.forked_from_session
  if session ~= nil and not bounded_string(session, MAX_IDENTITY_BYTES) then
    return nil, "lineage forked_from_session is invalid"
  end
  local base = lineage.base_context_commit
  if not bounded_string(base, COMMIT_HASH_BYTES) or #base ~= COMMIT_HASH_BYTES
    or not base:match(COMMIT_HASH_PATTERN) then
    return nil, "lineage base_context_commit must be an immutable commit hash"
  end
  local reason = bounded_string(lineage.reason, MAX_REASON_BYTES)
  if not reason then return nil, "lineage reason is invalid" end
  return copy_lineage({
    forked_from_agent = parent,
    forked_from_session = session,
    base_context_commit = base,
    reason = reason,
  })
end

--- Default heterogeneous model profiles per role.
local DEFAULT_MODEL_PROFILES = {
  [WheelAgent.Role.COMMANDER] = {
    provider = "anthropic",
    model = "claude-3-5-sonnet",
    temperature = 0.2,
    thinking = { enabled = true, gear = "medium", budget_tokens = 4096 },
    context_budget = { max_tokens = 65536 },
    retry = { max_retries = 3, backoff_ms = 1000 },
  },
  [WheelAgent.Role.CODING] = {
    provider = "anthropic",
    model = "claude-3-5-sonnet",
    temperature = 0.0,
    thinking = { enabled = false, gear = "off", budget_tokens = 0 },
    context_budget = { max_tokens = 65536 },
    retry = { max_retries = 3, backoff_ms = 1000 },
  },
  [WheelAgent.Role.DEBUG] = {
    provider = "deepseek",
    model = "deepseek-reasoner",
    temperature = 0.0,
    thinking = { enabled = true, gear = "high", budget_tokens = 8192 },
    context_budget = { max_tokens = 65536 },
    retry = { max_retries = 3, backoff_ms = 1000 },
  },
  [WheelAgent.Role.REVIEWER] = {
    provider = "openai",
    model = "gpt-4o",
    temperature = 0.0,
    thinking = { enabled = false, gear = "off", budget_tokens = 0 },
    context_budget = { max_tokens = 65536 },
    retry = { max_retries = 3, backoff_ms = 1000 },
  },
  [WheelAgent.Role.RESEARCH] = {
    provider = "local",
    model = "qwen2.5-coder",
    temperature = 0.4,
    thinking = { enabled = false, gear = "off", budget_tokens = 0 },
    context_budget = { max_tokens = 32768 },
    retry = { max_retries = 2, backoff_ms = 500 },
  },
}

--- Deep copy a table.
local function deep_copy(orig)
  if type(orig) ~= "table" then return orig end
  local copy = {}
  for k, v in pairs(orig) do
    copy[k] = deep_copy(v)
  end
  return copy
end

--- Get a copy of the default model profile for a given role.
--- @param role string: One of WheelAgent.Role
--- @return table: Model profile table
function WheelAgent.get_default_model_profile(role)
  local def = DEFAULT_MODEL_PROFILES[role] or DEFAULT_MODEL_PROFILES[WheelAgent.Role.CODING]
  return deep_copy(def)
end

--- Validate a model profile definition.
--- @param profile table
--- @return boolean is_valid, string? error_reason
function WheelAgent.validate_model_profile(profile)
  if type(profile) ~= "table" then
    return false, "model_profile must be a table"
  end
  if type(profile.provider) ~= "string" or profile.provider == "" then
    return false, "model_profile.provider must be a non-empty string"
  end
  if type(profile.model) ~= "string" or profile.model == "" then
    return false, "model_profile.model must be a non-empty string"
  end
  if profile.temperature ~= nil then
    if type(profile.temperature) ~= "number" or profile.temperature < 0.0 or profile.temperature > 2.0 then
      return false, "model_profile.temperature must be a number between 0.0 and 2.0"
    end
  end
  if profile.thinking ~= nil then
    if type(profile.thinking) ~= "table" then
      return false, "model_profile.thinking must be a table"
    end
    if profile.thinking.budget_tokens ~= nil then
      if type(profile.thinking.budget_tokens) ~= "number" or profile.thinking.budget_tokens < 0 then
        return false, "model_profile.thinking.budget_tokens must be a non-negative number"
      end
    end
  end
  if profile.max_completion_tokens ~= nil and WheelProvider then
    local budget, budget_err = WheelProvider.validate_max_completion_tokens(profile.max_completion_tokens)
    if not budget then
      return false, "model_profile.max_completion_tokens: "
        .. tostring(budget_err and budget_err.message or "invalid completion budget")
    end
  end
  return true, nil
end

--- Create a new Agent instance.
--- @param opts table
---   opts.name string: Agent identity (e.g. "commander-01", "worker-coding-01")
---   opts.role string: One of WheelAgent.Role
---   opts.kernel table: WheelKernel instance
---   opts.model table?: Model config { name = string, temperature = number }
---   opts.model_profile table?: Heterogeneous model profile table
---   opts.tools table?: List of allowed tool names
---   opts.budget table?: Budget limits { max_iterations = number, max_tokens = number }
---   opts.workspace table?: Workspace config { root = string }
--- @return table
function WheelAgent.new(opts)
  opts = opts or {}
  if not opts.name or opts.name == "" then
    error("Agent requires a non-empty 'name'")
  end
  local agent_id = opts.agent_id or opts.name
  if not bounded_string(agent_id, MAX_IDENTITY_BYTES) then
    error("Agent requires a bounded, control-free 'agent_id'")
  end
  local role = opts.role
  if role ~= nil and (type(role) ~= "string" or not ROLE_VALUES[role]) then
    error("Invalid agent role: " .. tostring(role))
  end
  local binding_input = opts.role_binding
  if binding_input == nil and role ~= nil then
    binding_input = {
      role = role,
      binding_id = opts.binding_id,
      capabilities = opts.capabilities,
    }
  end
  if binding_input == nil then binding_input = { role = WheelAgent.Role.CODING } end
  local role_binding, binding_err = WheelAgent.normalize_role_binding(binding_input, agent_id)
  if not role_binding then
    error("Invalid role binding for agent '" .. opts.name .. "': " .. tostring(binding_err))
  end
  if role ~= nil and role ~= role_binding.role then
    error("Agent 'role' conflicts with its role_binding role")
  end
  local lineage
  if opts.lineage ~= nil then
    local lineage_err
    lineage, lineage_err = WheelAgent.validate_lineage(opts.lineage)
    if not lineage then
      error("Invalid lineage for agent '" .. opts.name .. "': " .. tostring(lineage_err))
    end
  end
  if not opts.kernel then
    error("Agent requires a 'kernel' (WheelKernel instance)")
  end

  local self = setmetatable({}, WheelAgent)
  AGENT_IDENTITY[self] = { agent_id = agent_id, lineage = lineage }
  AGENT_AUTHORITY[self] = { role_binding = role_binding }
  self.name = opts.name
  self.role = role_binding.role
  self.policy_generation = role_binding.policy_generation
  self.kernel = opts.kernel

  -- Role config resolution from opts.config if present
  local role_cfg = (opts.config and opts.config.roles and opts.config.roles[role_binding.role]) or {}

  -- Model profile resolution (heterogeneous model profile support)
  local default_profile = WheelAgent.get_default_model_profile(role_binding.role)
  local user_profile = opts.model_profile or (role_cfg and role_cfg.model_profile)
  if user_profile then
    local ok_val, val_err = WheelAgent.validate_model_profile(user_profile)
    if not ok_val then
      error("Invalid model_profile for agent '" .. self.name .. "': " .. tostring(val_err))
    end
    for k, v in pairs(user_profile) do
      default_profile[k] = v
    end
  elseif opts.model or (role_cfg and role_cfg.model) then
    local m = opts.model or role_cfg.model
    if type(m) == "table" then
      default_profile.model = m.name or m.model or default_profile.model
      if m.temperature ~= nil then
        default_profile.temperature = m.temperature
      end
      if m.provider ~= nil then
        default_profile.provider = m.provider
      end
    end
  end
  self.model_profile = default_profile

  -- Backward-compatibility: maintain self.model table with name and temperature
  self.model = {
    name = self.model_profile.model,
    model = self.model_profile.model,
    provider = self.model_profile.provider,
    temperature = self.model_profile.temperature,
    thinking = self.model_profile.thinking,
  }

  self.tools = opts.tools or role_cfg.tools or { "read_file", "write_file", "run_command" }
  self.budget = opts.budget or role_cfg.budget or { max_iterations = 10, max_tokens = 65536 }
  self.workspace = opts.workspace or { root = "." }

  -- Headless Panel working container invariant:
  -- Bitty Core Rule R1: ExecutionContext is primary; panels describe presentation, not execution authority.
  -- Every agent defaults to running inside a Headless Panel working container.
  -- Presentation UI panels are optional observation projections.
  local cfg_panel = (opts.config and opts.config.panel) or {}
  self.panel_id = opts.panel_id or cfg_panel.panel_id or ("headless:panel:" .. self.name)
  if opts.headless ~= nil then
    self.headless = opts.headless
  elseif cfg_panel.headless ~= nil then
    self.headless = cfg_panel.headless
  else
    self.headless = true
  end
  self.config = opts.config
  self.context = opts.context
  self.tool_registry = opts.tool_registry or (WheelTool and WheelTool.get_default_registry())
  self.last_prefix_cache_key = nil
  self.last_cache_share_ratio = nil

  -- Lifecycle records are opt-in so existing in-process agents remain
  -- compatible. When supplied, the registry keeps identity, session, panel,
  -- task, context, role, model, and worktree references separate.
  self.lifecycle = opts.lifecycle
  self.session_id = opts.session_id
  self.worktree_id = opts.worktree_id

  self.provider = opts.provider
  if not self.provider and WheelProvider and self.model_profile then
    self.provider = WheelProvider.create(self.model_profile)
  end

  -- Structured references only. A forked agent points at immutable commits and
  -- identifiers; it never receives a copied transcript or slot snapshot.
  self.context_refs = opts.context_refs
  self.last_role_checkpoint = opts.last_role_checkpoint

  return self
end

--- Create the explicit runtime AgentSession and Headless Panel records for
--- this agent. The lifecycle registry stores references only; prompt/context
--- content remains in WheelContext and is never copied into bittyd metadata.
--- @param opts table? lifecycle record overrides
--- @return table session, table panel
function WheelAgent:create_runtime_session(opts)
  if not self.lifecycle or not WheelLifecycle then
    return nil, { code = "E_LIFECYCLE_UNAVAILABLE", message = "no lifecycle registry configured" }
  end
  opts = opts or {}
  local panel = self.lifecycle:get_panel(opts.panel_id or self.panel_id)
  local panel_err
  if not panel then
    panel, panel_err = self.lifecycle:create_panel({
      panel_id = opts.panel_id or self.panel_id,
      agent_id = self.agent_id,
      headless = self.headless,
      kind = opts.panel_kind or "headless",
    })
    if not panel then
      return nil, panel_err
    end
  end
  if panel.state == WheelLifecycle.PanelState.CREATED then
    panel, panel_err = self.lifecycle:ready_panel(panel.panel_id)
    if not panel then return nil, panel_err end
  end
  local session, session_err = self.lifecycle:create_agent_session({
    session_id = opts.session_id,
    agent_id = self.agent_id,
    panel_id = panel.panel_id,
    task_id = opts.task_id or self.active_task_id,
    context_branch = opts.context_branch or self:current_branch(),
    context_head = opts.context_head,
    role_binding = opts.role_binding or WheelAgent.binding_reference(self.role_binding),
    model_profile = opts.model_profile or self.model_profile,
    worktree_id = opts.worktree_id or self.worktree_id,
  })
  if not session then
    return nil, session_err
  end
  self.session_id = session.session_id
  self.panel_id = panel.panel_id
  return session, panel
end

--- Start this agent's runtime session after its panel is ready.
function WheelAgent:activate_runtime_session()
  if not self.lifecycle or not self.session_id then
    return nil, { code = "E_LIFECYCLE_UNAVAILABLE", message = "runtime session is not configured" }
  end
  return self.lifecycle:activate_session(self.session_id)
end

function WheelAgent:pause_runtime_session(reason)
  if not self.lifecycle or not self.session_id then
    return nil, { code = "E_LIFECYCLE_UNAVAILABLE", message = "runtime session is not configured" }
  end
  return self.lifecycle:pause_session(self.session_id, reason)
end

function WheelAgent:checkpoint_runtime_session(checkpoint)
  if not self.lifecycle or not self.session_id then
    return nil, { code = "E_LIFECYCLE_UNAVAILABLE", message = "runtime session is not configured" }
  end
  return self.lifecycle:checkpoint_session(self.session_id, checkpoint)
end

function WheelAgent:detach_runtime_session(opts)
  if not self.lifecycle or not self.session_id then
    return nil, { code = "E_LIFECYCLE_UNAVAILABLE", message = "runtime session is not configured" }
  end
  return self.lifecycle:detach_session(self.session_id, opts)
end

function WheelAgent:attach_runtime_session(panel_id, opts)
  if not self.lifecycle or not self.session_id then
    return nil, { code = "E_LIFECYCLE_UNAVAILABLE", message = "runtime session is not configured" }
  end
  return self.lifecycle:attach_session(self.session_id, panel_id, opts)
end

--- Get the active LLM Provider adapter.
--- @return table?: Provider adapter instance
function WheelAgent:get_provider()
  return self.provider
end

--- Set the LLM Provider adapter.
--- @param provider table Provider adapter instance
function WheelAgent:set_provider(provider)
  self.provider = provider
end

--- Get the active WheelContext engine.
--- @return table?: WheelContext instance
function WheelAgent:get_context()
  return self.context
end

--- Get a semantic slot from context.
--- @param name string
--- @return table: slot retrieval result
function WheelAgent:get_slot(name)
  if self.context then
    return self.context:get_slot(name)
  elseif self.kernel and type(self.kernel.get_slot) == "function" then
    return self.kernel:get_slot(name)
  end
  return { name = name, found = false }
end

--- Put a semantic slot into context with optional CAS.
--- @param name string
--- @param content string
--- @param expected_version integer|nil
--- @return table|nil, table|nil
function WheelAgent:put_slot(name, content, expected_version)
  if self.context then
    return self.context:put_slot(name, content, expected_version)
  elseif self.kernel and type(self.kernel.put_slot) == "function" then
    return self.kernel:put_slot(name, content)
  end
  return nil, { error = "no_context", message = "No context engine available" }
end

--- Check if a tool can be invoked under this agent's current RoleBinding.
-- Authorization is derived from the granted capability set on the binding, not
-- from `name`, prompt identity text, or a role word alone.
-- @param tool_name string
-- @return boolean, string?
function WheelAgent:is_tool_allowed(tool_name)
  local binding = authoritative_binding(self)
  if type(binding) ~= "table" then
    return false, "agent '" .. tostring(self.name) .. "' has no role binding"
  end
  local granted = capability_map(binding.capabilities)
  local role = binding.role

  -- 1. Check if tool is in agent's declared tools
  local declared = false
  for _, t in ipairs(self.tools) do
    if t == tool_name or t == "*" then
      declared = true
      break
    end
  end
  if not declared then
    return false, "tool '" .. tool_name .. "' is not in declared tools for " .. self.name
  end

  -- 2. Map the tool intent to the capability it needs.
  local required
  local intent
  local mutating = false
  if self.tool_registry and type(self.tool_registry.get_tool) == "function" and WheelTool then
    local tool_def = self.tool_registry:get_tool(tool_name)
    if tool_def then
      intent = tool_def.intent or WheelTool.ActionIntent.INSPECT
      if intent == WheelTool.ActionIntent.INSPECT or intent == WheelTool.ActionIntent.VERIFY then
        required = intent
      elseif intent == WheelTool.ActionIntent.MODIFY or intent == WheelTool.ActionIntent.EXECUTE then
        required = intent
        mutating = true
      elseif intent == WheelTool.ActionIntent.CUSTOM then
        required = tool_def.read_only and WheelAgent.Capability.INSPECT or WheelAgent.Capability.MODIFY
        mutating = not tool_def.read_only
      else
        return false, "tool '" .. tool_name .. "' has an unknown intent"
      end
      if not granted[required] then
        local role_matrix = ROLE_CAPABILITIES[role] or {}
        if mutating and not role_matrix.modify and not role_matrix.execute
          and not role_matrix.orchestrate then
          return false, string.format(
            "role_authority_violation: role '%s' has read-only authority; cannot execute tool '%s' with intent '%s'",
            role, tool_name, tostring(intent))
        end
        return false, string.format(
          "role_authority_violation: role '%s' lacks '%s' capability for tool '%s'",
          role, required, tool_name)
      end
      return true, nil
    end
  end

  -- 3. Unregistered tools still obey the same capability state.
  if granted[WheelAgent.Capability.MODIFY] or granted[WheelAgent.Capability.EXECUTE] then
    return true, nil
  end
  if not READ_ONLY_TOOLS[tool_name] then
    local role_matrix = ROLE_CAPABILITIES[role] or {}
    if not role_matrix.modify and not role_matrix.execute and not role_matrix.orchestrate then
      return false, "role '" .. role .. "' has read-only authority; denied: " .. tool_name
    end
    return false, "role '" .. role .. "' lacks 'modify' capability; denied: " .. tool_name
  end
  if not granted[WheelAgent.Capability.INSPECT] then
    return false, "role '" .. role .. "' lacks 'inspect' capability; denied: " .. tool_name
  end
  return true, nil
end

--- Execute a tool directly under this agent's security boundary and role authority.
--- Measures execution latency, auto-spills oversized output into context memory,
--- and records action outcome into kernel and ContextBus.
--- @param tool_name string Name of tool to execute
--- @param args table? Tool arguments
--- @return table ActionOutcome instance
function WheelAgent:execute_tool(tool_name, args)
  args = args or {}
  local allowed, reason = self:is_tool_allowed(tool_name)
  if not allowed then
    if WheelTool and type(WheelTool.process_spillover) == "function" then
      return WheelTool.process_spillover({
        tool = tool_name,
        success = false,
        status = WheelTool.OutcomeStatus.DENIED,
        exit_code = 126,
        stderr = reason,
      })
    end
    error(reason)
  end

  if not self.tool_registry then
    error("Agent " .. self.name .. " has no tool_registry configured")
  end

  return self.tool_registry:dispatch(tool_name, args, {
    role = self.role,
    agent_name = self.name,
    workspace_root = self.workspace and self.workspace.root or ".",
    kernel = self.kernel,
    context = self.context,
  })
end

--- Execute a batch of tool calls (e.g. from an LLM response).
--- @param tool_calls table[] Array of { id = string?, name = string, arguments = table|string? }
--- @return table[] Array of ActionOutcome instances
function WheelAgent:call_tools(tool_calls)
  tool_calls = tool_calls or {}
  local outcomes = {}
  for _, tc in ipairs(tool_calls) do
    local name = tc.name or tc.tool
    local args = tc.arguments or tc.args or {}
    if type(args) == "string" and WheelKernel and WheelKernel.json then
      local ok, decoded = pcall(WheelKernel.json.decode, args)
      if ok and type(decoded) == "table" then
        args = decoded
      end
    end
    local outcome = self:execute_tool(name, args)
    if tc.id then
      outcome.call_id = tc.id
    end
    table.insert(outcomes, outcome)
  end
  return outcomes
end

--- Execute a task in the DAG as a Worker.
--- Sets active task, binds worker, iterates step function under budget, records actions,
--- and commits cognitive checkpoints upon completion.
--- @param task_id string
--- @param step_fn fun(agent: table, ctx: table, iteration: number): table
---   step_fn returns:
---     action: table? { action_id = string, tool = string, stdout = string, stderr = string, exit_code = number, duration_ms = number }
---     rationale: table? { why = string, what = string, where_focus = string?, how = string?, expected = string?, observed = string? }
---     done: boolean?
---     error: string?
--- @return table { success: boolean, task: table, checkpoints: string[], iterations: number, error: string? }
function WheelAgent:execute_task(task_id, step_fn)
  local task = self.kernel:get_task(task_id)
  if not task then
    error("Task not found: " .. tostring(task_id))
  end
  local st_lower = (task.status or ""):lower()
  if st_lower ~= "ready" and st_lower ~= "running" then
    error("Task " .. task_id .. " is not Ready or Running (current status: " .. tostring(task.status) .. ")")
  end
  local assigned = task.assigned_agent
  if type(assigned) == "table" then
    assigned = assigned.assigned_agent or assigned.worker_id or ""
  end
  if not assigned or assigned == "" then
    assigned = task.worker_id
    if type(assigned) == "table" then
      assigned = assigned.worker_id or assigned.assigned_agent or ""
    end
  end
  if assigned and assigned ~= "" and assigned ~= self.name then
    error("Task " .. task_id .. " is already assigned to " .. tostring(assigned))
  end

  -- Autonomous ReAct loop via WheelRunner when step_fn is nil or table of options
  if type(step_fn) ~= "function" then
    if WheelRunner and type(WheelRunner.run_task) == "function" then
      local runner_opts = (type(step_fn) == "table") and step_fn or {}
      local runner_res = WheelRunner.run_task(self, task, runner_opts)
      local cur = self.kernel:get_task(task_id) or task
      local generation = cur.generation or task.generation or 0
      local last_cp = runner_res.checkpoints and runner_res.checkpoints[#runner_res.checkpoints]
      local finished
      if not runner_opts.defer_release then
        if runner_res.success then
          finished = self.kernel:complete_task(task_id, generation, last_cp)
        else
          finished = self.kernel:fail_task(task_id, generation, runner_res.error or "unknown failure")
        end
      end
      self.kernel:set_active_task(nil)
      return {
        success = runner_res.success,
        task = finished or self.kernel:get_task(task_id) or task,
        artifacts = runner_res.artifacts,
        checkpoints = runner_res.checkpoints,
        iterations = runner_res.iterations,
        error = runner_res.error,
        usage = runner_res.usage,
      }
    else
      error("WheelRunner not available to execute task without step_fn")
    end
  end

  -- 1. Set active task in kernel
  self.kernel:set_active_task(task_id)

  -- 2. Start task in kernel, getting generation (if not already started)
  local generation = task.generation or 0
  if st_lower == "ready" then
    local started = self.kernel:start_task(task_id, self.name)
    generation = (started and started.generation) or generation
  end

  local checkpoints = {}
  local last_checkpoint_hash = nil
  local iterations = 0
  local max_iter = self.budget.max_iterations or 10
  local execution_success = false
  local final_error = nil

  while iterations < max_iter do
    iterations = iterations + 1

    -- Compile three-zone context
    local ctx
    if self.context and type(self.context.compile_prompt) == "function" then
      local ctx_res = self.context:compile_prompt({
        system_instruction = string.format("Agent: %s (Role: %s)", self.name, self.role),
        project_rules = (self.config and self.config.directives) or { "Software Engineering domain only", "Fail-closed on security violations" },
        tool_schemas = self.tools or {},
        active_task = task,
        turn_prompt = string.format("Execute step %d for task %s: %s", iterations, task_id, task.title),
      })
      if ctx_res then
        self.last_prefix_cache_key = ctx_res.prefix_cache_key
        self.last_cache_share_ratio = ctx_res.cache_share_ratio
      end
      ctx = ctx_res or { prompt_string = "" }
    else
      ctx = self.kernel:compile_context({
        system_instruction = string.format("Agent: %s (Role: %s)", self.name, self.role),
        project_rules = { "Software Engineering domain only", "Fail-closed on security violations" },
        turn_prompt = string.format("Execute step %d for task %s: %s", iterations, task_id, task.title),
      })
    end

    -- Call step callback
    local step_result = step_fn(self, ctx, iterations) or {}

    -- Process action if produced
    if step_result.action then
      local act = step_result.action
      local tool = act.tool or "tool"
      local allowed, err_reason = self:is_tool_allowed(tool)
      if not allowed then
        final_error = err_reason
        break
      end

      self.kernel:record_action({
        action_id = act.action_id or (task_id .. "-act-" .. iterations),
        success = (act.exit_code == nil or act.exit_code == 0),
        exit_code = act.exit_code or 0,
        duration_ms = act.duration_ms or 10,
        tool = act.tool,
        intent = act.intent,
        preview = act.preview or act.stdout_preview or act.stdout or "",
        stdout_preview = act.stdout_preview or act.stdout or "",
        stderr_preview = act.stderr_preview or act.stderr or "",
        size_bytes = act.size_bytes ~= nil and act.size_bytes
          or (#(act.stdout or "") + #(act.stderr or "")),
        stdout_bytes = act.stdout_bytes ~= nil and act.stdout_bytes or #(act.stdout or ""),
        stderr_bytes = act.stderr_bytes ~= nil and act.stderr_bytes or #(act.stderr or ""),
        spilled = act.spilled,
        blob_hash = act.blob_hash or act.spillover_hash,
        spillover_bytes = act.spillover_bytes,
        diagnostics = act.diagnostics,
        timed_out = act.timed_out,
        truncated = act.truncated,
        outcome = act.outcome,
      })
    end

    -- Process cognitive checkpoint rationale
    if step_result.rationale then
      if self.context and type(self.context.commit_checkpoint) == "function" then
        local ctx_cp = self.context:commit_checkpoint({
          author = self.name,
          task_id = task_id,
          rationale = step_result.rationale,
        })
        if ctx_cp and ctx_cp.hash then
          last_checkpoint_hash = ctx_cp.hash
          table.insert(checkpoints, ctx_cp.hash)
        end
      end
      if self.kernel and type(self.kernel.commit_checkpoint) == "function" then
        local cp = self.kernel:commit_checkpoint(step_result.rationale)
        if cp and cp.hash then
          last_checkpoint_hash = cp.hash
          table.insert(checkpoints, cp.hash)
        end
      end
    end

    -- Check completion or failure
    if step_result.error then
      final_error = step_result.error
      break
    elseif step_result.done then
      execution_success = true
      break
    end
  end

  if not execution_success and not final_error and iterations >= max_iter then
    final_error = "iteration budget exhausted (" .. tostring(max_iter) .. " steps)"
  end

  local finished_task
  if execution_success then
    finished_task = self.kernel:complete_task(task_id, generation, last_checkpoint_hash)
  else
    finished_task = self.kernel:fail_task(task_id, generation, final_error or "unknown failure")
  end

  -- Clear active task
  self.kernel:set_active_task(nil)

  return {
    success = execution_success,
    task = finished_task,
    checkpoints = checkpoints,
    iterations = iterations,
    error = final_error,
    panel_id = self.panel_id,
    headless = self.headless,
    model_profile = self.model_profile,
    prefix_cache_key = self.last_prefix_cache_key,
    cache_share_ratio = self.last_cache_share_ratio,
  }
end

--- Get the resolved heterogeneous model profile for this agent.
--- @return table: Model profile definition
function WheelAgent:get_model_profile()
  return self.model_profile
end

--- Decompose and submit a software engineering plan into the Task DAG (Commander role).
--- @param plan_items table[] Array of { id = string, title = string, description = string, priority = number?, dependencies = string[]? }
--- @return table[] List of created task records
function WheelAgent:decompose_plan(plan_items)
  local role = self.role_binding.role
  if role ~= WheelAgent.Role.COMMANDER then
    error("Only Commander role may decompose project plans (current role: " .. role .. ")")
  end
  local created = {}
  for _, item in ipairs(plan_items) do
    local task = self.kernel:create_task(item)
    table.insert(created, task)
  end
  return created
end

--- Review a completed task and its artifacts (Reviewer role).
--- @param task_id string
--- @param review_fn fun(agent: table, task: table, history: table[])?: boolean, string
--- @return table { approved: boolean, reason: string?, checkpoint: string? }
function WheelAgent:review_task(task_id, review_fn)
  local role = self.role_binding.role
  if role ~= WheelAgent.Role.REVIEWER then
    error("Only Reviewer role may review tasks (current role: " .. role .. ")")
  end
  local task = self.kernel:get_task(task_id)
  if not task then
    error("Task not found: " .. tostring(task_id))
  end
  local st_lower = (task.status or ""):lower()
  if st_lower ~= "succeeded" and st_lower ~= "running" and st_lower ~= "waiting_review" then
    error("Cannot review uncompleted task " .. task_id .. " (status: " .. tostring(task.status) .. ")")
  end

  if type(review_fn) ~= "function" then
    error("review_fn is required for independent review")
  end

  local history = self.kernel:log(8)
  local approved, reason = review_fn(self, task, history)

  local cp_hash = nil
  if approved then
    local cp = self.kernel:commit_checkpoint({
      why = "Task verification and acceptance",
      what = "Independent review approved for " .. task_id,
      where_focus = "task " .. task_id,
      how = "evaluated task outcomes and code diffs against acceptance criteria",
      expected = "all quality gates and contracts satisfied",
      observed = reason or "verification passed cleanly",
    })
    cp_hash = cp.hash
  end

  return {
    approved = approved,
    reason = reason,
    checkpoint = cp_hash,
  }
end

--- Commit an immutable checkpoint commit to the agent's context.
--- @param rationale string|table Rationale behind the checkpoint
--- @param message string? Optional human-readable commit message
--- @return table|nil ContextCommit
function WheelAgent:commit_checkpoint(rationale, message)
  if self.context and type(self.context.commit_checkpoint) == "function" then
    return self.context:commit_checkpoint({
      author = self.name,
      task_id = self.active_task_id,
      rationale = rationale,
      message = message,
    })
  elseif self.kernel and type(self.kernel.commit_checkpoint) == "function" then
    return self.kernel:commit_checkpoint(rationale)
  end
  return nil
end

--- Create a new isolated context branch for this agent.
--- @param name string Branch name
--- @param start_point string? Optional commit hash or ref
--- @return boolean, table?
function WheelAgent:create_branch(name, start_point)
  if not self.context or type(self.context.create_branch) ~= "function" then
    error("Agent " .. self.name .. " has no context engine configured")
  end
  return self.context:create_branch(name, start_point)
end

--- Checkout an isolated context branch or commit for this agent.
--- @param target string Branch name or commit hash
--- @param opts table? Options
--- @return boolean, table?
function WheelAgent:checkout(target, opts)
  if not self.context or type(self.context.checkout) ~= "function" then
    error("Agent " .. self.name .. " has no context engine configured")
  end
  return self.context:checkout(target, opts)
end

--- Get the current active context branch name.
--- @return string
function WheelAgent:current_branch()
  if self.context and type(self.context.current_branch) == "function" then
    return self.context:current_branch()
  end
  return "(detached)"
end

--- Project a RoleBinding into the bounded reference shape used by lifecycle
-- records. Capability state is runtime authority and is not persisted as prompt
-- or tool content.
-- @param binding table
-- @return table|nil
function WheelAgent.binding_reference(binding)
  if type(binding) ~= "table" then return nil end
  return {
    role = binding.role,
    binding_id = binding.binding_id,
    policy_generation = binding.policy_generation,
  }
end

local function binding_copy(binding)
  if type(binding) ~= "table" then return nil end
  local capabilities = {}
  for index, capability in ipairs(binding.capabilities or {}) do capabilities[index] = capability end
  return {
    role = binding.role,
    binding_id = binding.binding_id,
    policy_generation = binding.policy_generation,
    capabilities = capabilities,
  }
end

local function capabilities_equal(left, right)
  if #left ~= #right then return false end
  for index = 1, #left do
    if left[index] ~= right[index] then return false end
  end
  return true
end

--- Current authoritative role, read from the RoleBinding.
-- @return string|nil
function WheelAgent:current_role()
  local binding = authoritative_binding(self)
  return binding and binding.role or nil
end

--- Check whether the current RoleBinding grants a capability.
-- @param capability string WheelAgent.Capability value
-- @return boolean
function WheelAgent:has_capability(capability)
  local binding = authoritative_binding(self)
  return capability_map(binding and binding.capabilities)[capability] == true
end

--- Get a defensive copy of the granted capability set.
-- @return table
function WheelAgent:capabilities()
  local result = {}
  local binding = authoritative_binding(self)
  for index, capability in ipairs(binding and binding.capabilities or {}) do
    result[index] = capability
  end
  return result
end

--- Audited role transition that preserves the stable Agent identity.
-- The transition issues a new RoleBinding with the next policy generation and
-- commits an immutable Context checkpoint boundary. A transition that would add
-- a capability fails closed unless the caller explicitly approves the widening;
-- there is no silent path from a wider-capability role to a narrower one.
-- @param target string|table Role name or a partial RoleBinding { role, capabilities }
-- @param opts table { reason = string, approve_widening = boolean?, model_profile = table? }
-- @return table|nil new binding projection, table|nil typed error
function WheelAgent:transition_role(target, opts)
  opts = opts or {}
  local requested = type(target) == "table" and target or { role = target }
  local reason = bounded_string(opts.reason, MAX_REASON_BYTES)
  if not reason then
    return nil, { code = "E_ROLE_INVALID", message = "role transition requires a bounded reason" }
  end
  local current = authoritative_binding(self)
  local identity = authoritative_identity(self)
  if type(current) ~= "table" then
    return nil, { code = "E_ROLE_INVALID", message = "agent has no role binding" }
  end
  local generation = (current.policy_generation or POLICY_GENERATION_START) + 1
  local normalized, binding_err = WheelAgent.normalize_role_binding({
    role = requested.role,
    capabilities = requested.capabilities or opts.capabilities,
    binding_id = requested.binding_id,
    policy_generation = generation,
  }, identity and identity.agent_id)
  if not normalized then
    return nil, { code = "E_ROLE_INVALID", message = tostring(binding_err) }
  end
  if normalized.role == current.role
    and capabilities_equal(normalized.capabilities, current.capabilities) then
    return nil, { code = "E_ROLE_NOOP", message = "role binding is already in the requested state" }
  end
  local added = capability_diff(normalized.capabilities, current.capabilities)
  if #added > 0 and opts.approve_widening ~= true then
    return nil, {
      code = "E_ROLE_AUTHORITY",
      message = string.format(
        "role transition '%s' -> '%s' would widen authority (%s); explicit approval required",
        current.role, normalized.role, table.concat(added, ",")),
    }
  end
  if not self.context or type(self.context.commit_checkpoint) ~= "function" then
    return nil, {
      code = "E_ROLE_CHECKPOINT",
      message = "role transition requires an immutable Context checkpoint boundary",
    }
  end
  local task_id = self.kernel and self.kernel.active_task_id or nil
  local checkpoint = self.context:commit_checkpoint({
    author = identity and identity.agent_id,
    task_id = task_id,
    message = string.format("Role transition %s -> %s (policy generation %d)",
      current.role, normalized.role, generation),
    rationale = {
      why = "Role transition requested: " .. reason,
      what = string.format("Reissued RoleBinding %s at policy generation %d",
        tostring(normalized.binding_id), generation),
      where_focus = "agent " .. tostring(identity and identity.agent_id),
      how = #added > 0
        and ("explicit widening approval granted for: " .. table.concat(added, ","))
        or "narrowed or re-scoped capabilities without widening authority",
      expected = "authority follows the new RoleBinding capability state only",
      observed = "previous generation " .. tostring(current.policy_generation or POLICY_GENERATION_START),
    },
  })
  if not checkpoint or not checkpoint.hash then
    return nil, { code = "E_ROLE_CHECKPOINT", message = "role transition checkpoint was not committed" }
  end
  -- The checkpoint is immutable and may remain if a later record fails; the
  -- in-memory binding is not applied until the lifecycle record succeeds, so a
  -- failure never widens authority.
  if not self.lifecycle or not self.session_id
    or type(self.lifecycle.record_role_transition) ~= "function" then
    return nil, {
      code = "E_ROLE_AUDIT",
      message = "role transition requires a lifecycle session for audit",
    }
  end
  local recorded, record_err = self.lifecycle:record_role_transition(self.session_id, {
    role_binding = WheelAgent.binding_reference(normalized),
    checkpoint = checkpoint.hash,
    reason = #added > 0 and "role_widening" or "role_transition",
  })
  if not recorded then
    return nil, record_err or {
      code = "E_ROLE_AUDIT",
      message = "role transition could not be recorded in the lifecycle registry",
    }
  end
  AGENT_AUTHORITY[self] = { role_binding = normalized }
  self.role = normalized.role
  self.policy_generation = normalized.policy_generation
  self.last_role_checkpoint = checkpoint.hash
  local projection = binding_copy(normalized)
  projection.checkpoint = checkpoint.hash
  projection.widened = #added > 0
  projection.added_capabilities = added
  return projection
end

--- Structured lineage projection shared by status, checkpoint, and context
-- projections. It contains references only.
-- @return table
function WheelAgent:lineage_projection()
  local lineage = self.lineage
  return {
    agent_id = self.agent_id,
    name = self.name,
    policy_generation = self.policy_generation,
    role_binding = self.role_binding and WheelAgent.binding_reference(self.role_binding) or nil,
    forked_from_agent = lineage and lineage.forked_from_agent or nil,
    forked_from_session = lineage and lineage.forked_from_session or nil,
    base_context_commit = lineage and lineage.base_context_commit or nil,
    reason = lineage and lineage.reason or nil,
    role_checkpoint = self.last_role_checkpoint,
  }
end

--- Structured Context references for this agent. A forked agent receives these
-- references instead of a copied transcript or slot snapshot.
-- @return table
function WheelAgent:context_reference()
  local refs = self.context_refs or {}
  return {
    agent_id = self.agent_id,
    base_context_commit = refs.base_context_commit,
    session_id = refs.session_id or self.session_id,
    branch = refs.branch or self:current_branch(),
    head = self.context and type(self.context.head_commit_hash) == "function"
      and self.context:head_commit_hash() or nil,
  }
end

--- Build a role-aware Context projection with this agent's identity, RoleBinding,
-- and lineage attached as provenance. Lineage is therefore visible in every
-- checkpoint projection without entering prompt or transcript content.
-- @param opts table WheelContext:project options
-- @return table|nil projection, table|nil typed error
function WheelAgent:context_projection(opts)
  opts = opts or {}
  if not self.context or type(self.context.project) ~= "function" then
    return nil, { code = "E_NO_CONTEXT", message = "agent has no context engine configured" }
  end
  local projection_opts = {}
  for key, value in pairs(opts) do projection_opts[key] = value end
  local identity = authoritative_identity(self)
  local authoritative_id = identity and identity.agent_id
  local expected_binding = WheelAgent.binding_reference(authoritative_binding(self))
  local expected_lineage = identity and copy_lineage(identity.lineage) or nil
  if projection_opts.agent_id ~= nil and projection_opts.agent_id ~= authoritative_id then
    return nil, { code = "E_IDENTITY_PROJECTION", message = "projection agent_id conflicts with Agent identity" }
  end
  if projection_opts.role_binding ~= nil then
    local supplied = WheelAgent.binding_reference(projection_opts.role_binding)
    if not supplied or supplied.agent_id ~= expected_binding.agent_id
      or supplied.role ~= expected_binding.role
      or supplied.binding_id ~= expected_binding.binding_id
      or supplied.policy_generation ~= expected_binding.policy_generation
      or not capabilities_equal(supplied.capabilities, expected_binding.capabilities) then
      return nil, { code = "E_IDENTITY_PROJECTION", message = "projection RoleBinding conflicts with Agent authority" }
    end
  else
    projection_opts.role_binding = expected_binding
  end
  if projection_opts.lineage ~= nil then
    local supplied = WheelAgent.validate_lineage(projection_opts.lineage)
    if not supplied or not expected_lineage
      or supplied.forked_from_agent ~= expected_lineage.forked_from_agent
      or supplied.forked_from_session ~= expected_lineage.forked_from_session
      or supplied.base_context_commit ~= expected_lineage.base_context_commit
      or supplied.reason ~= expected_lineage.reason then
      return nil, { code = "E_IDENTITY_PROJECTION", message = "projection lineage conflicts with Agent identity" }
    end
  elseif expected_lineage then
    projection_opts.lineage = expected_lineage
  end
  projection_opts.agent_id = authoritative_id
  if projection_opts.session_id == nil then projection_opts.session_id = self.session_id end
  return self.context:project(projection_opts)
end

--- Fork an independent Agent identity from an immutable ContextCommit.
-- The child shares the context engine by reference, records lineage identifiers,
-- and starts with its own RoleBinding. No transcript, prompt, or slot content is
-- copied, and a fork may not silently widen authority beyond its parent.
-- @param parent table WheelAgent instance
-- @param opts table { name, agent_id?, role?, role_binding?, reason,
--   base_context_commit?, forked_from_session?, approve_widening?, tools?,
--   budget?, workspace?, lifecycle?, panel_id?, headless? }
-- @return table|nil child agent, table|nil typed error
function WheelAgent.fork_agent(parent, opts)
  opts = opts or {}
  if type(parent) ~= "table" or parent.role_binding == nil then
    return nil, { code = "E_FORK_INVALID", message = "fork requires a parent Agent" }
  end
  local name = bounded_string(opts.name, MAX_IDENTITY_BYTES)
  if not name then
    return nil, { code = "E_FORK_INVALID", message = "fork requires a bounded child name" }
  end
  local agent_id = opts.agent_id or name
  if not bounded_string(agent_id, MAX_IDENTITY_BYTES) then
    return nil, { code = "E_FORK_INVALID", message = "fork requires a bounded child agent_id" }
  end
  if name == parent.name or agent_id == parent.agent_id then
    return nil, {
      code = "E_FORK_IDENTITY",
      message = "fork requires an independent Agent identity",
    }
  end
  if not parent.context or type(parent.context.get_commit) ~= "function" then
    return nil, {
      code = "E_FORK_CONTEXT",
      message = "fork requires a parent context engine with immutable commits",
    }
  end
  local base = opts.base_context_commit or parent.context:head_commit_hash()
  local commit = type(base) == "string" and parent.context:get_commit(base) or nil
  if not commit or type(commit.hash) ~= "string" or #commit.hash ~= COMMIT_HASH_BYTES then
    return nil, {
      code = "E_FORK_CONTEXT",
      message = "fork requires an immutable ContextCommit as base_context_commit",
    }
  end
  local reason = bounded_string(opts.reason, MAX_REASON_BYTES)
  if not reason then
    return nil, { code = "E_FORK_INVALID", message = "fork requires a bounded reason" }
  end
  local initial, binding_err = WheelAgent.normalize_role_binding(
    opts.role_binding or { role = opts.role or parent.role_binding.role,
      capabilities = opts.capabilities }, agent_id)
  if not initial then
    return nil, { code = "E_FORK_INVALID", message = tostring(binding_err) }
  end
  local added = capability_diff(initial.capabilities, parent.role_binding.capabilities)
  if #added > 0 and opts.approve_widening ~= true then
    return nil, {
      code = "E_FORK_AUTHORITY",
      message = "fork would widen authority (" .. table.concat(added, ",")
        .. "); explicit approval required",
    }
  end
  local forked_from_session = opts.forked_from_session or parent.session_id
  local lineage, lineage_err = WheelAgent.validate_lineage({
    forked_from_agent = parent.agent_id,
    forked_from_session = forked_from_session,
    base_context_commit = commit.hash,
    reason = reason,
  })
  if not lineage then
    return nil, { code = "E_FORK_INVALID", message = tostring(lineage_err) }
  end
  local context_refs = {
    base_context_commit = commit.hash,
    session_id = forked_from_session,
    branch = opts.base_context_branch or parent:current_branch(),
  }
  local child = WheelAgent.new({
    name = name,
    agent_id = agent_id,
    kernel = opts.kernel or parent.kernel,
    config = opts.config or parent.config,
    role_binding = initial,
    tools = opts.tools or deep_copy(parent.tools),
    budget = opts.budget or deep_copy(parent.budget),
    workspace = opts.workspace or deep_copy(parent.workspace),
    context = parent.context,
    tool_registry = opts.tool_registry or parent.tool_registry,
    provider = opts.provider,
    lifecycle = opts.lifecycle or parent.lifecycle,
    headless = opts.headless,
    panel_id = opts.panel_id,
    lineage = lineage,
    context_refs = context_refs,
  })
  if opts.approve_widening == true then child.approved_widening = true end
  return child
end

--- Get current agent status summary including headless panel container telemetry
-- and model profile. Identity, RoleBinding, policy generation, and lineage are
-- separate fields so no caller has to parse a role word out of prompt text.
-- @return table
function WheelAgent:status()
  return {
    name = self.name,
    agent_id = self.agent_id,
    role = self.role_binding.role,
    role_binding = binding_copy(self.role_binding),
    policy_generation = self.policy_generation,
    lineage = self:lineage_projection(),
    context_refs = self:context_reference(),
    panel_id = self.panel_id,
    headless = self.headless,
    model_profile = self.model_profile,
    model = self.model,
    tools = self.tools,
    budget = self.budget,
    workspace = self.workspace,
    active_task = self.kernel and self.kernel.active_task_id,
    prefix_cache_key = self.last_prefix_cache_key,
    cache_share_ratio = self.last_cache_share_ratio,
    tool_count = self.tool_registry and #self.tool_registry:list_tools() or #self.tools,
    provider = self.provider and (self.provider.describe and self.provider:describe() or { provider = self.provider.name }) or nil,
    context_branch = self:current_branch(),
    context_head = self.context and type(self.context.head_commit_hash) == "function" and self.context:head_commit_hash() or nil,
  }
end

-- Stable Agent identity, fork lineage, and the current RoleBinding are immutable
-- after construction. RoleBinding changes flow only through transition_role,
-- which issues a new binding and policy generation instead of rewriting history.
local IMMUTABLE_FIELDS = { agent_id = true, lineage = true, role_binding = true }

function WheelAgent.__index(target, key)
  if key == "agent_id" or key == "lineage" then
    local identity = AGENT_IDENTITY[target]
    if not identity then return nil end
    if key == "lineage" then return copy_lineage(identity.lineage) end
    return identity.agent_id
  end
  if key == "role_binding" then
    local authority = AGENT_AUTHORITY[target]
    return authority and binding_copy(authority.role_binding) or nil
  end
  return WheelAgent[key]
end

function WheelAgent.__newindex(target, key, value)
  if IMMUTABLE_FIELDS[key] then
    error("agent identity field '" .. tostring(key) .. "' is immutable", 2)
  end
  rawset(target, key, value)
end

return WheelAgent
