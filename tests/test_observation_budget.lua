-- tests/test_observation_budget.lua
-- TDD suite for the model-facing observation window (CTX-0058 / wheel#149):
--   1. A ~4 KiB source file read arrives complete in the formatted observation.
--   2. Oversized output spills with a marker naming the dropped bytes and blob.
--   3. The configured window is tightenable and clamped by the Zone 3 budget.
--   4. Redaction still applies across the widened window.
--   5. The provider request projection carries the observation unchanged.

package.path = "./lua/?.lua;./lua/?/init.lua;" .. package.path

local WheelHost = require("wheel.host")
local WheelConfig = require("wheel.config")
local WheelTool = require("wheel.tool")
local WheelRunner = require("wheel.runner")

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

local function write_text(path, content)
  local file = assert(io.open(path, "wb"))
  file:write(content)
  file:close()
end

--- Build deterministic source-like content with `lines` numbered lines.
local function source_fixture(lines, prefix)
  local parts = {}
  for index = 1, lines do
    parts[#parts + 1] = string.format("%s %03d: local value = %d", prefix or "line", index, index)
  end
  return table.concat(parts, "\n") .. "\n"
end

local root = make_temp_root("wheel-observation-budget")
local ok_all, test_err = pcall(function()
  -- The defect bound: every observation used to be cut to this many bytes.
  local historical_bound = WheelTool.OBSERVATION_FALLBACK_BYTES
  local window = WheelTool.resolve_observation_budget(nil)
  assert(window >= 4096, "the default observation window must fit a source file: " .. tostring(window))

  -- 1. A ~4 KiB file read arrives complete.
  do
    local content = source_fixture(150, "sample")
    assert(#content >= 4096 and #content <= window,
      string.format("the 4 KiB fixture (%d bytes) must fit the window (%d)", #content, window))
    write_text(root .. "/sample.lua", content)

    local registry = WheelTool.get_default_registry()
    local outcome = registry:dispatch("read_file", { path = "sample.lua" }, {
      workspace_root = root,
    })
    assert(outcome.success == true, "read_file must succeed")
    assert(outcome.spilled == false, "a file inside the window must not spill")
    assert(#outcome.preview >= #content - 1,
      string.format("preview must carry the whole file: %d of %d bytes", #outcome.preview, #content))

    local observation = outcome:format_observation()
    assert(#observation > historical_bound * 4,
      "the formatted observation must exceed the historical 256-byte bound")
    -- Every line must survive the projection, including the last one.
    for _, expected in ipairs({ "sample 001:", "sample 075:", "sample 150:" }) do
      assert(observation:find(expected, 1, true) ~= nil,
        "observation must contain " .. expected)
    end
    assert(observation:find("truncated", 1, true) == nil,
      "a complete observation must not claim truncation")
    print(string.format("PASS observation of a %d-byte file arrives complete (%d bytes)",
      #content, #observation))
  end

  -- 2. Oversized output spills with a marker naming the dropped bytes.
  do
    local content = source_fixture(1200, "oversized")
    assert(#content > window, "the oversized fixture must exceed the window")
    write_text(root .. "/oversized.lua", content)

    local registry = WheelTool.get_default_registry()
    local outcome = registry:dispatch("read_file", { path = "oversized.lua" }, {
      workspace_root = root,
    })
    assert(outcome.success == true, "read_file must succeed")
    assert(outcome.spilled == true, "a result beyond the window must spill")
    assert(outcome.spillover_hash ~= nil and #outcome.spillover_hash == 64,
      "a spilled outcome must carry a content-addressed hash")
    assert(outcome.spillover_bytes == #outcome.stdout,
      "the spilled byte count must match the payload")

    local observation = outcome:format_observation()
    assert(#outcome.preview <= window, "the preview must stay inside the window")
    assert(observation:find(outcome.spillover_hash, 1, true) ~= nil,
      "the observation must name the blob that holds the rest")
    assert(observation:find("read_blob", 1, true) ~= nil,
      "the observation must say how to retrieve the rest")
    local dropped = observation:match("(%d+) bytes dropped")
    assert(dropped ~= nil, "the observation must state how many bytes were dropped")
    assert(tonumber(dropped) > 0, "a truncated observation must report a positive drop count")
    assert(not observation:find(content, 1, true),
      "a spilled observation must not present the complete payload")
    assert(observation:find("oversized 001:", 1, true) ~= nil,
      "the spilled preview must keep the head")
    assert(observation:find("oversized 1200:", 1, true) ~= nil,
      "the spilled preview must keep the tail")
    assert(observation:find("oversized 0600:", 1, true) == nil,
      "the spilled preview must omit the middle")
    print(string.format("PASS oversized output spills with a marker (%s bytes dropped)",
      dropped))
  end

  -- 3. The configured window is tightenable and clamped by the Zone 3 budget.
  do
    local defaults = WheelConfig.DEFAULTS.context
    local resolved_default = WheelConfig.resolve_observation_budget(nil)
    assert(resolved_default == defaults.observation_max_bytes,
      "the default window must come from the context defaults")

    local tightened = WheelConfig.resolve_observation_budget({
      context = { observation_max_bytes = 1024 },
    })
    assert(tightened == 1024, "a tightened override must take effect: " .. tostring(tightened))

    local widened = WheelConfig.resolve_observation_budget({
      context = { observation_max_bytes = defaults.zone3_max_bytes * 4 },
    })
    assert(widened == defaults.zone3_max_bytes,
      "a widened override must clamp at the Zone 3 budget: " .. tostring(widened))

    local zone_tightened = WheelConfig.resolve_observation_budget({
      context = { zone3_max_bytes = 1024 },
    })
    assert(zone_tightened == 1024,
      "the default window must follow a tightened Zone 3 budget: " .. tostring(zone_tightened))

    local invalid = WheelConfig.resolve_observation_budget({
      context = { observation_max_bytes = 0 },
    })
    assert(invalid == resolved_default, "an invalid override must fall back to the default")

    -- The tightened window is honored end to end by tool dispatch.
    local content = source_fixture(150, "sample")
    local registry = WheelTool.get_default_registry()
    local outcome = registry:dispatch("read_file", { path = "sample.lua" }, {
      workspace_root = root,
      config = { context = { observation_max_bytes = 1024 } },
    })
    assert(outcome.observation_max_bytes == 1024,
      "dispatch must resolve the configured window: " .. tostring(outcome.observation_max_bytes))
    assert(#outcome.preview <= 1024, "the tightened window must bound the preview")
    assert(outcome.spilled == true, "a 4 KiB file must spill inside a 1 KiB window")
    local dropped = outcome:format_observation():match("(%d+) bytes dropped")
    assert(dropped ~= nil, "the tightened window must still state the dropped bytes")

    -- An explicit registry bound wins over the configuration.
    local explicit = WheelTool.WheelToolRegistry.new({ observation_max_bytes = 512 })
    local explicit_outcome = explicit:dispatch("read_file", { path = "sample.lua" }, {
      workspace_root = root,
    })
    assert(explicit_outcome.observation_max_bytes == 512, "an explicit registry window must win")
    print("PASS configured window is tightenable and clamps at the Zone 3 budget")
  end

  -- 4. Redaction still applies across the widened window.
  do
    local secret = "sk-observation-budget-secret-7c3d9e"
    local content = source_fixture(90, "redaction")
      .. "local api_key = \"" .. secret .. "\"\n"
    assert(#content > WheelTool.OBSERVATION_FALLBACK_BYTES * 8,
      "the secret must sit beyond the historical preview bound")
    write_text(root .. "/secret.lua", content)

    local registry = WheelTool.get_default_registry()
    local outcome = registry:dispatch("read_file", { path = "secret.lua" }, {
      workspace_root = root,
    })
    local observation = outcome:format_observation()
    assert(#observation > WheelTool.OBSERVATION_FALLBACK_BYTES * 4,
      "redaction evidence requires the widened window")
    assert(not observation:find(secret, 1, true), "the widened window must still redact secrets")
    assert(observation:find("[redacted", 1, true) ~= nil, "a redaction marker must remain")

    -- The spilled tail path must redact as well.
    local tail_secret = "sk-observation-tail-secret-2b6f81"
    local oversized = source_fixture(1200, "oversized") .. "token = \"" .. tail_secret .. "\"\n"
    write_text(root .. "/oversized-secret.lua", oversized)
    local spilled = registry:dispatch("read_file", { path = "oversized-secret.lua" }, {
      workspace_root = root,
    })
    assert(spilled.spilled == true, "the oversized fixture must spill")
    assert(not spilled:format_observation():find(tail_secret, 1, true),
      "the spilled head/tail preview must redact the tail secret")
    print("PASS redaction applies to the widened and spilled windows")
  end

  -- 5. The provider request projection carries the observation unchanged.
  do
    local registry = WheelTool.get_default_registry()
    local outcome = registry:dispatch("read_file", { path = "sample.lua" }, {
      workspace_root = root,
    })
    local observation = outcome:format_observation()
    local expected_bound = WheelConfig.resolve_observation_message_bytes(nil)
    assert(WheelRunner.MAX_REQUEST_MESSAGE_BYTES >= expected_bound,
      "the request message bound must carry a full observation")

    local bounded = WheelRunner.bound_provider_request({
      model = "stub-model",
      tools = {},
      messages = {
        { role = "user", content = "read the sample file" },
        {
          role = "assistant",
          content = "",
          tool_calls = {
            { id = "call-1", name = "read_file", arguments = { path = "sample.lua" } },
          },
        },
        { role = "tool", tool_call_id = "call-1", content = observation },
      },
    })
    assert(type(bounded) == "table", "the request must stay boundable")
    local projected = nil
    for _, message in ipairs(bounded.messages or {}) do
      if message.role == "tool" then projected = message.content end
    end
    assert(projected ~= nil, "the tool observation must reach the bounded request")
    assert(projected == observation,
      "request projection must not truncate a complete observation again")
    print("PASS provider request projection carries the observation unchanged")
  end
end)

cleanup_dir(root)
if not ok_all then
  error(test_err, 0)
end
print("PASS ALL observation budget checks")
