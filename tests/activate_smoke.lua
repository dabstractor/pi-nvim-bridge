-- === tests/activate_smoke.lua — standalone (plenary-FREE) smoke test for activate() ===
-- Run from the REPO ROOT:
--   nvim --headless --clean -u NORC +"luafile tests/activate_smoke.lua" +qa ; echo exit=$?
-- Exits 0 on pass (prints SMOKE_PASS), 1 on any check failure (via cquit). Zero deps.
-- (The plenary suite tests/activate_spec.lua is the formal Level-2 gate; this is fast feedback.)
local me = debug.getinfo(1, "S").source:sub(2)
me = vim.fn.fnamemodify(me, ":p")                  -- absolute path of THIS file
local plugin_root = vim.fn.fnamemodify(me, ":h:h") -- .../<repo-root>  (rtp entry — S19 GOTCHA #1)
vim.opt.runtimepath:append(plugin_root)

local fails = 0
local function check(cond, msg)
  if not cond then io.stderr:write("FAIL: " .. msg .. "\n"); fails = fails + 1 end
end

local ok, pi = pcall(require, "pi-bridge")
check(ok, "require('pi-bridge') failed: " .. tostring(pi))
pi = ok and pi or {}

check(type(pi.activate) == "function", "activate is not a function")
check(pi.descriptor == nil, "descriptor should be nil before activate")

-- Dormant: no env var.
vim.env.PI_NVIM_BRIDGE = nil
vim.bo[0].filetype = ""
check(pi.activate() == nil, "no env var -> activate should return nil")
check(pi.descriptor == nil, "no env var -> descriptor should stay nil")
check(vim.bo[0].filetype == "", "no env var -> filetype should be untouched")

-- Activate: valid Unix descriptor.
vim.env.PI_NVIM_BRIDGE =
  '{"transport":"unix","path":"/tmp/x.sock","token":"t","pid":2,"cwd":"/p","fdAvailable":false,"serverVersion":"0.1.0"}'
local d = pi.activate()
check(d ~= nil, "valid descriptor -> activate should return non-nil")
check(pi.descriptor ~= nil and pi.descriptor.path == "/tmp/x.sock", "descriptor.path should be stored")
check(vim.bo[0].filetype == "pi-prompt", "valid descriptor -> filetype should be pi-prompt")

if fails > 0 then
  io.stderr:write(fails .. " check(s) failed\n")
  vim.cmd("cquit 1")
end
io.stdout:write("SMOKE_PASS\n")
