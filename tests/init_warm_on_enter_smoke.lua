-- === tests/init_warm_on_enter_smoke.lua — plenary-free Level-1 gate (P2.M3.T6.S1) ===
-- Verifies the §17.11 warm_on_enter behavior end-to-end WITHOUT plenary or a subprocess:
--   (1) warm_on_enter = true  + valid PI_NVIM_BRIDGE blob + fake driver → shell.ensure called once.
--   (2) warm_on_enter = false (default)                          → shell.ensure NOT called.
--   (3) enabled = false (master switch) gates warming            → shell.ensure NOT called.
--
-- The spy WRAPS shell.ensure (does not replace it) so shell.lua's real lifecycle still runs
-- (needed so the warm spawn does not crash on a half-initialized state). The fake fish driver
-- mirrors tests/shell_ensure_spec.lua's make_fake_driver (synchronous start cb, no subprocess).
--
-- Run (from the repo root):
--   timeout 60 nvim --headless --clean -u NORC +"luafile tests/init_warm_on_enter_smoke.lua" +qa
-- AGENTS.md HARD RULE: this is a FILE on disk run via :luafile — NEVER pipe a heredoc
-- into nvim's stdin (`nvim ... +"luafile /dev/stdin" +qa <<EOF` HANGS the session).
local me = debug.getinfo(1, "S").source:sub(2)
me = vim.fn.fnamemodify(me, ":p")
local plugin_root = vim.fn.fnamemodify(me, ":h:h") -- .../<repo-root> (the runtimepath entry)
vim.opt.runtimepath:append(plugin_root)

local pi = require("pi-bridge")
local shell = require("pi-bridge.shell")

if pi.config == nil then pi.setup({}) end -- self-sufficient (mirror completion_spec.lua)

local fails = 0
local function check(c, m)
  if not c then io.stderr:write("FAIL: " .. tostring(m) .. "\n"); fails = fails + 1 end
end

-- --- spy: count ensure() calls WITHOUT breaking shell.lua (wrap, don't replace) ---
local orig_ensure = shell.ensure
local ensure_calls = 0
shell.ensure = function(cb)
  ensure_calls = ensure_calls + 1
  return orig_ensure(cb)
end

-- --- a fake "fish" driver whose start cb succeeds SYNCHRONOUSLY (no subprocess) ---
-- mirrors tests/shell_ensure_spec.lua make_fake_driver's fake_pipe + start shape.
local function fake_pipe()
  return {
    read_start = function(_, cb) end, -- capture-free; shell.lua wires it but we never drive chunks
    write      = function() end,
    close      = function() end,
    read_stop  = function() end,
    is_closing = function() return false end,
  }
end
package.loaded["pi-bridge.shell.fish"] = {
  start = function(opts, cb)
    cb(nil, { is_closing = function() return false end }, fake_pipe(), fake_pipe())
  end,
}

-- --- a valid PI_NVIM_BRIDGE blob (transport=unix; includes §17.10 shell so prefer:"pi" resolves) ---
local function blob(shell_path)
  return vim.json.encode({
    transport = "unix",
    path = "/tmp/fake.sock",
    token = "t",
    pid = 1,
    cwd = "/tmp",
    fdAvailable = true,
    serverVersion = "0.0.1",
    shell = shell_path,
    shellSource = "pi",
  })
end

-- --- fake bridge so shell.lua's resolve_shell (prefer:"pi") reads descriptor.shell ---
-- activate() reads M.config.env_var (default PI_NVIM_BRIDGE). We also publish a fake bridge
-- so ensure() does not bail on a nil bridge.get_shell_info (it reads descriptor.shell first,
-- but bridge.get_shell_info is the fallback).
pi.bridge = {
  get_shell_info = function() return { shell = "/usr/bin/fish" } end,
  server_info = {},
}

-- === (1) warm_on_enter = TRUE → ensure called exactly once ===
pi.setup({ shell = { warm_on_enter = true } })
vim.env.PI_NVIM_BRIDGE = blob("/usr/bin/fish")
ensure_calls = 0
pi.descriptor = nil
shell.reset()
pi.activate()
-- the fake driver's start cb fires synchronously inside ensure → no vim.wait needed for the
-- call count; but give any scheduled notify a beat so it does not bleed into the next case.
vim.wait(50, function() return false end, 5)
check(ensure_calls == 1, "warm_on_enter=true → ensure called once (got " .. ensure_calls .. ")")

-- === (2) warm_on_enter = FALSE (default) → ensure NOT called ===
pi.setup({}) -- resets config.shell.warm_on_enter to false
ensure_calls = 0
pi.descriptor = nil
shell.reset()
pi.activate()
check(ensure_calls == 0, "warm_on_enter=false (default) → ensure NOT called (got " .. ensure_calls .. ")")

-- === (3) enabled = FALSE gates warming even if warm_on_enter = true ===
pi.setup({ shell = { warm_on_enter = true, enabled = false } })
ensure_calls = 0
pi.descriptor = nil
shell.reset()
pi.activate()
check(ensure_calls == 0, "enabled=false gates warming (got " .. ensure_calls .. ")")

-- === restore the global state we swapped ===
shell.ensure = orig_ensure
package.loaded["pi-bridge.shell.fish"] = nil
vim.env.PI_NVIM_BRIDGE = nil
pi.bridge = nil
pi.descriptor = nil
shell.reset()

if fails > 0 then
  io.stderr:write(fails .. " smoke check(s) FAILED\n")
  vim.cmd("cquit 1")
end
io.stdout:write("S1_WARM_SMOKE_OK\n")