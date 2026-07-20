-- === plugin/tests/smoke.lua — standalone (plenary-FREE) smoke test for setup() ===
-- Run from the REPO ROOT:
--   nvim --headless --clean -u NORC +"luafile plugin/tests/smoke.lua" +qa ; echo exit=$?
-- Exits 0 on pass, 1 on any check failure (via cquit). Zero dependencies.
-- (The plenary suite tests/init_spec.lua is the formal Level-2 gate; this is fast feedback.)
local me = debug.getinfo(1, "S").source:sub(2)
me = vim.fn.fnamemodify(me, ":p")                  -- absolute path of THIS file
local plugin_root = vim.fn.fnamemodify(me, ":h:h") -- .../plugin  (rtp entry — GOTCHA #1)
vim.opt.runtimepath:append(plugin_root)

local fails = 0
local function check(cond, msg)
  if not cond then io.stderr:write("FAIL: " .. msg .. "\n"); fails = fails + 1 end
end

local ok, pi = pcall(require, "pi-editor")
check(ok, "require('pi-editor') failed: " .. tostring(pi))
pi = ok and pi or {}

check(type(pi.setup) == "function", "setup is not a function")
check(pi.defaults.debounce_ms == 20, "default debounce_ms")
check(pi.defaults.rpc_timeout_ms == 2000, "default rpc_timeout_ms")
check(pi.defaults.autosave_on_exit == true, "default autosave_on_exit")
check(pi.defaults.engine == "builtin", "default engine")
check(pi.defaults.menu.max_height == 12, "default menu.max_height")
check(pi.defaults.menu.border == "rounded", "default menu.border")
check(pi.config == nil, "config should be nil before setup")

pi.setup({})
check(pi.config ~= nil, "config nil after setup({})")
check(pi.config.debounce_ms == 20, "config.debounce_ms after empty setup")
check(pi.config.autosave_on_exit == true, "config.autosave_on_exit after empty setup")
check(pi.config.menu.border == "rounded", "config.menu.border after empty setup")

pi.setup({ debounce_ms = 50, autosave_on_exit = false, menu = { max_height = 40 } })
check(pi.config.debounce_ms == 50, "scalar override debounce_ms")
check(pi.config.autosave_on_exit == false, "false-overrides-true (autosave)")
check(pi.config.menu.max_height == 40, "nested override menu.max_height")
check(pi.config.menu.border == "rounded", "nested default menu.border preserved")
check(pi.defaults.debounce_ms == 20, "defaults.debounce_ms was MUTATED")
check(pi.defaults.menu.max_height == 12, "defaults.menu.max_height was MUTATED")
check(pi.bridge == nil, "bridge is not the nil placeholder")

-- S25 dormant-session guard: WITHOUT the PI_EDITOR_BRIDGE env var, activate() must leave
-- pi.bridge == nil (the handshake never runs in a non-pi session). Also confirms a
-- broken/missing bridge module can NEVER set it (activate's handshake call is pcall'd).
do
  local saved = vim.env.PI_EDITOR_BRIDGE
  vim.env.PI_EDITOR_BRIDGE = nil -- simulate an ordinary (non-pi) nvim session
  local desc = pi.activate()    -- dormant -> returns nil, must NOT throw / NOT notify
  check(desc == nil, "activate() must return nil without PI_EDITOR_BRIDGE")
  check(pi.bridge == nil, "pi.bridge must stay nil in a dormant session")
  vim.env.PI_EDITOR_BRIDGE = saved -- restore (other tests / downstream may rely on it)
end

local cfg = pi.setup({ rpc_timeout_ms = 9000 })
check(cfg.rpc_timeout_ms == 9000, "setup return value")
check(cfg == pi.config, "setup did not return the same table as M.config")

if fails > 0 then
  io.stderr:write(fails .. " check(s) failed\n")
  vim.cmd("cquit 1")
end
io.stdout:write("SMOKE_PASS\n")
