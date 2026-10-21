-- lua/wheel/session_cli.lua
-- Script entry point for `scripts/wheel-session`.
--
-- The shell wrapper selects the interpreter, supplies argument vectors, and
-- owns the detached daemon launch. This file only bootstraps the module path
-- from its own location and delegates to `wheel.session.main`.

local script_path = type(arg) == "table" and arg[0] or ""
local lua_root = type(script_path) == "string" and script_path:match("^(.*)/wheel/session_cli%.lua$") or nil
if lua_root and lua_root ~= "" then
  package.path = lua_root .. "/?.lua;" .. lua_root .. "/?/init.lua;" .. package.path
end

local Session = require("wheel.session")
os.exit(Session.main(arg))
