-- === tests/shell_smoke.lua — standalone (plenary-FREE) smoke test (P2.M1.T2.S2) ===
-- The Level-2 gate for the shell.lua resolution + state layer: instant, dependency-free
-- feedback (no plenary). Exercises the resolve_shell fallback matrix + pick_driver
-- selection (fake driver injected into package.loaded) + session_cwd source priority +
-- reset() + never-throws. ZERO subprocess (S2 is pure resolution).
--
-- Run from the repo root:
--   nvim --headless --clean -u NORC -c 'set rtp+=.' +"luafile tests/shell_smoke.lua" +qa
--   echo "exit=$?"   # 0 = pass (prints 'SMOKE_PASS'), 1 = a check failed
--
-- AGENTS.md HARD RULE: this is a FILE on disk run via :luafile — NEVER pipe a heredoc
-- into nvim's stdin (`nvim ... +"luafile /dev/stdin" +qa <<EOF` HANGS the session).
local me = debug.getinfo(1, "S").source:sub(2)
me = vim.fn.fnamemodify(me, ":p")
local plugin_root = vim.fn.fnamemodify(me, ":h:h") -- .../<repo-root> (the runtimepath entry)
vim.opt.runtimepath:append(plugin_root)

local pi = require("pi-bridge")
if pi.config == nil then pi.setup({}) end -- self-sufficient (mirror smoke.lua GOTCHA D)
local shell = require("pi-bridge.shell")

local fails = 0
local function check(cond, msg)
	if not cond then
		io.stderr:write("FAIL: " .. msg .. "\n")
		fails = fails + 1
	end
end

-- --- a fake bridge exposing the two surface points shell.lua reads FRESH:
-- get_shell_info() (S4 contract) + server_info.cwd (session_cwd). `shell` controls the
-- advertised descriptor shell (nil → no shell field; "" → malformed/unresolved).
local function fake_bridge(shell_path, server_cwd)
	return {
		get_shell_info = function()
			if shell_path == nil then return nil end
			return { shell = shell_path }
		end,
		server_info = (server_cwd == nil) and {} or { cwd = server_cwd },
	}
end

-- --- save/restore the globals the smoke swaps per-case (vim.env.SHELL + pi.bridge +
-- pi.descriptor + package.loaded[fish] + config.shell.drivers).
local orig_shell = vim.env.SHELL
local orig_bridge = pi.bridge
local orig_desc = pi.descriptor
local orig_drivers = (pi.config and pi.config.shell and pi.config.shell.drivers) or nil

local function restore()
	vim.env.SHELL = orig_shell
	pi.bridge = orig_bridge
	pi.descriptor = orig_desc
	package.loaded["pi-bridge.shell.fish"] = nil
	-- restore config.shell.drivers (the shell={} block is P2.M3.T6.S1; config.shell may be
	-- nil, in which case there was nothing to restore).
	if pi.config then
		if orig_drivers then
			pi.config.shell = pi.config.shell or {}
			pi.config.shell.drivers = orig_drivers
		elseif pi.config.shell then
			pi.config.shell.drivers = nil
		end
	end
	shell.reset()
end

-- ===========================================================================
-- resolve_shell — the §17.4 fallback chain
-- ===========================================================================

-- (1) prefer=="pi" + descriptor shell advertised → descriptor shell, source "pi"
do
	restore()
	pi.bridge = fake_bridge("/bin/zsh")
	local s, src = shell.resolve_shell("pi")
	check(s == "/bin/zsh" and src == "pi",
		"resolve(pi) w/ descriptor shell '/bin/zsh' → ('/bin/zsh','pi') (got " .. tostring(s) .. "," .. tostring(src) .. ")")
end

-- (2) prefer=="pi" + NO descriptor shell + SHELL set → $SHELL
do
	restore()
	pi.bridge = fake_bridge(nil)
	vim.env.SHELL = "/bin/zsh"
	local s, src = shell.resolve_shell("pi")
	check(s == "/bin/zsh" and src == "$SHELL",
		"resolve(pi) no descriptor + SHELL='/bin/zsh' -> ('/bin/zsh','$SHELL') (got " .. tostring(s) .. "," .. tostring(src) .. ")")
end

-- (3) prefer=="pi" + NO descriptor shell + SHELL nil → /bin/bash default
do
	restore()
	pi.bridge = fake_bridge(nil)
	vim.env.SHELL = nil
	local s, src = shell.resolve_shell("pi")
	check(s == "/bin/bash" and src == "default",
		"resolve(pi) no descriptor + no SHELL → ('/bin/bash','default') (got " .. tostring(s) .. "," .. tostring(src) .. ")")
end

-- (4) prefer=="pi" falls back to pi.descriptor.shell when bridge==nil (pre-handshake window)
do
	restore()
	pi.bridge = nil
	pi.descriptor = { shell = "/usr/local/bin/fish" }
	local s, src = shell.resolve_shell("pi")
	check(s == "/usr/local/bin/fish" and src == "pi",
		"resolve(pi) bridge==nil + descriptor.shell → descriptor ('pi') (got " .. tostring(s) .. "," .. tostring(src) .. ")")
end

-- (5) prefer=="shell" + SHELL set → $SHELL
do
	restore()
	pi.bridge = fake_bridge("/bin/ignored") -- descriptor shell MUST be ignored for prefer=="shell"
	vim.env.SHELL = "/bin/zsh"
	local s, src = shell.resolve_shell("shell")
	check(s == "/bin/zsh" and src == "$SHELL",
		"resolve(shell) + SHELL='/bin/zsh' -> ('/bin/zsh','$SHELL') (got " .. tostring(s) .. "," .. tostring(src) .. ")")
end

-- (6) prefer=="shell" + SHELL nil → /bin/bash default
do
	restore()
	vim.env.SHELL = nil
	local s, src = shell.resolve_shell("shell")
	check(s == "/bin/bash" and src == "default",
		"resolve(shell) no SHELL → ('/bin/bash','default') (got " .. tostring(s) .. "," .. tostring(src) .. ")")
end

-- (7) prefer=="bash" → /bin/bash default (ignores SHELL + descriptor)
do
	restore()
	vim.env.SHELL = "/bin/zsh"
	pi.bridge = fake_bridge("/bin/ignored")
	local s, src = shell.resolve_shell("bash")
	check(s == "/bin/bash" and src == "default",
		"resolve(bash) → ('/bin/bash','default') (got " .. tostring(s) .. "," .. tostring(src) .. ")")
end

-- (8) explicit path → that path, source "config"
do
	restore()
	local s, src = shell.resolve_shell("/usr/bin/fish")
	check(s == "/usr/bin/fish" and src == "config",
		"resolve('/usr/bin/fish') → ('/usr/bin/fish','config') (got " .. tostring(s) .. "," .. tostring(src) .. ")")
end

-- (9) prefer==nil defaults to "pi" → follows the pi chain
do
	restore()
	pi.bridge = fake_bridge("/bin/zsh")
	local s, src = shell.resolve_shell(nil)
	check(s == "/bin/zsh" and src == "pi",
		"resolve(nil) defaults to 'pi' (got " .. tostring(s) .. "," .. tostring(src) .. ")")
end

-- ===========================================================================
-- pick_driver — basename → driver module (or nil)
-- ===========================================================================

-- (10) present driver (fake injected into package.loaded) → returns the module
do
	restore()
	package.loaded["pi-bridge.shell.fish"] = { start = function() end }
	local drv = shell.pick_driver("/usr/bin/fish")
	check(type(drv) == "table" and type(drv.start) == "function",
		"pick_driver('/usr/bin/fish') w/ fake fish module → returns it (got " .. tostring(drv) .. ")")
end

-- (11) unknown shell (no module) → nil (degrade)
do
	restore()
	local drv = shell.pick_driver("/bin/unknownshell")
	check(drv == nil,
		"pick_driver('/bin/unknownshell') → nil (got " .. tostring(drv) .. ")")
end

-- (12) user-disabled driver (config.shell.drivers.bash == false) → nil
do
	restore()
	package.loaded["pi-bridge.shell.bash"] = { start = function() end } -- module IS loadable...
	-- ...but disabled: build the config.shell.drivers subtree (config.shell may not exist yet —
	-- the shell={} block is P2.M3.T6.S1; create it so pick_driver sees drivers.bash=false).
	pi.config.shell = pi.config.shell or {}
	pi.config.shell.drivers = { bash = false }
	local drv = shell.pick_driver("/bin/bash")
	check(drv == nil,
		"pick_driver('/bin/bash') w/ drivers.bash=false -> nil (got " .. tostring(drv) .. ")")
end

-- (13) nil + "" → nil (never throws)
do
	restore()
	check(shell.pick_driver(nil) == nil, "pick_driver(nil) → nil")
	check(shell.pick_driver("") == nil, "pick_driver('') → nil")
end

-- ===========================================================================
-- session_cwd — fresh server_info.cwd → descriptor.cwd → nil
-- ===========================================================================

-- (14) server_info.cwd present → it
do
	restore()
	pi.bridge = fake_bridge(nil, "/srv/proj")
	local c = shell.session_cwd()
	check(c == "/srv/proj", "session_cwd() w/ server_info.cwd='/srv/proj' → '/srv/proj' (got " .. tostring(c) .. ")")
end

-- (15) no server_info.cwd + descriptor.cwd present → descriptor.cwd
do
	restore()
	pi.bridge = fake_bridge(nil, nil)            -- server_info empty
	pi.descriptor = { cwd = "/desc/path" }
	local c = shell.session_cwd()
	check(c == "/desc/path", "session_cwd() w/ descriptor.cwd='/desc/path' → '/desc/path' (got " .. tostring(c) .. ")")
end

-- (16) neither → nil
do
	restore()
	pi.bridge = nil
	pi.descriptor = nil
	local c = shell.session_cwd()
	check(c == nil, "session_cwd() w/ neither → nil (got " .. tostring(c) .. ")")
end

-- ===========================================================================
-- reset() — restores state to its initial literal (all 11 fields)
-- ===========================================================================

do
	restore()
	-- mutate a few fields, then reset
	shell.reset()
	local st = require("pi-bridge.shell")        -- same module (cached); reset touches the upvalue
	-- (state is module-local; verify via observable behavior: resolve/pick/cwd still work post-reset)
	local s, src = shell.resolve_shell("bash")
	check(s == "/bin/bash" and src == "default", "post-reset resolve(bash) still works")
	check(shell.pick_driver("/bin/nope") == nil, "post-reset pick_driver still works")
	check(shell.session_cwd() == nil, "post-reset session_cwd (no bridge/desc) → nil")
end

-- ===========================================================================
-- never-throws on bad args
-- ===========================================================================

do
	restore()
	local ok = pcall(function()
		shell.resolve_shell(123)
		shell.resolve_shell("")
		shell.resolve_shell({})
		shell.pick_driver(123)
		shell.pick_driver({})
		shell.session_cwd()                       -- nil bridge + nil descriptor
	end)
	check(ok, "resolve_shell / pick_driver / session_cwd never throw on bad/nil args")
end

restore()

if fails > 0 then
	io.stderr:write(fails .. " check(s) failed\n")
	vim.cmd("cquit 1")
end
io.stdout:write("SMOKE_PASS\n")