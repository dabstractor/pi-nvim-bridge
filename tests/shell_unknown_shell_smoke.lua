-- === tests/shell_unknown_shell_smoke.lua — standalone (plenary-FREE) smoke test (P2.M3.T5.S3) ===
-- The Level-1, dependency-free gate for the unknown-shell DEGRADE path (mirrors
-- shell_ensure_smoke.lua's shape). Exercises the FULL end-to-end degrade contract
-- (pick_driver nil → ensure failed/cb/short-circuit → single notice → complete_current
-- err → disabled-driver → never-throws) with a FAKE driver injected into package.loaded
-- + a notify.once recorder spy. ZERO subprocess, ZERO plenary.
--
-- Run from the repo root:
--   timeout 60 nvim --headless --clean -u NORC -c 'set rtp+=.' +"luafile tests/shell_unknown_shell_smoke.lua" +qa
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
local notify = require("pi-bridge.notify")

local fails = 0
local function check(cond, msg)
	if not cond then
		io.stderr:write("FAIL: " .. msg .. "\n")
		fails = fails + 1
	end
end

-- --- a fake bridge exposing the surface points ensure/resolve/session_cwd read FRESH:
-- get_shell_info() (controls the resolved shell) + server_info.cwd (session_cwd).
local function fake_bridge(shell_path, server_cwd)
	return {
		get_shell_info = function()
			if shell_path == nil then return nil end
			return { shell = shell_path }
		end,
		server_info = (server_cwd == nil) and {} or { cwd = server_cwd },
	}
end

-- --- the fake driver + fake pipes (mirrors the luv handle shape from
-- tests/shell_ensure_smoke.lua: read_start/write/close/read_stop/is_closing) so the
-- read_start wiring + the teardown-guard methods exist WITHOUT a real subprocess.
-- `start` calls cb SYNCHRONOUSLY.
local function make_fake_driver()
	local captured = { opts = nil, calls = 0, read_cb = nil }
	local function fake_pipe()
		return {
			read_start = function(_, cb) captured.read_cb = cb end,
			write      = function() end,
			close      = function() end,
			read_stop  = function() end,
			is_closing = function() return false end,
		}
	end
	return {
		captured = captured,
		start = function(opts, cb)
			captured.calls = captured.calls + 1
			captured.opts = opts
			if opts._fail then
				cb("spawn err: simulated", nil, nil, nil)
			else
				cb(nil, { is_closing = function() return false end }, fake_pipe(), fake_pipe())
			end
		end,
	}
end

-- --- a notify.once recorder spy: counts calls per category key.
-- REPLICATES notify.once's dedup semantics (the FIRST call per category counts; later
-- calls with the same category are silent no-ops) so the spy behaves identically to
-- the real module — this makes the "fires exactly once across two ensure() calls" +
-- the cross-shell dedup assertions correct.
local function make_notify_spy()
	local calls = {}
	local seen = {} -- the dedup set (mirrors notify.lua's internal `seen`)
	return {
		calls = calls,
		spy = {
			once = function(category, level, msg)
				local k = (type(category) == "string" and category ~= "") and category or "bridge"
				if seen[k] then return end -- dedup (mirrors notify.lua)
				seen[k] = true
				calls[k] = (calls[k] or 0) + 1
			end,
			did_notify = function(category)
				local k = (type(category) == "string" and category ~= "") and category or "bridge"
				return (calls[k] or 0) > 0
			end,
			reset = function()
				calls = {}
				seen = {}
			end,
		},
	}
end

-- --- save/restore the globals the smoke swaps per-case.
local orig_shell = vim.env.SHELL
local orig_bridge = pi.bridge
local orig_desc = pi.descriptor
local orig_shell_cfg = (pi.config and pi.config.shell) or nil
local orig_pkg_notify = package.loaded["pi-bridge.notify"]

local function restore()
	vim.env.SHELL = orig_shell
	pi.bridge = orig_bridge
	pi.descriptor = orig_desc
	for _, base in ipairs({ "fish", "bash", "zsh", "noshell", "elvish", "unknownshell" }) do
		package.loaded["pi-bridge.shell." .. base] = nil
	end
	if pi.config then pi.config.shell = orig_shell_cfg end -- nil restores "no shell cfg"
	package.loaded["pi-bridge.notify"] = orig_pkg_notify
	notify.reset()
	shell.reset()
end

-- ===========================================================================
-- (1) pick_driver: returns nil for unknown shell basename (/bin/noshell, /usr/local/bin/elvish)
-- ===========================================================================
do
	restore()
	package.loaded["pi-bridge.shell.noshell"] = nil
	check(shell.pick_driver("/bin/noshell") == nil,
		"pick_driver: nil for unknown basename '/bin/noshell' (got " .. tostring(shell.pick_driver("/bin/noshell")) .. ")")
	package.loaded["pi-bridge.shell.elvish"] = nil
	check(shell.pick_driver("/usr/local/bin/elvish") == nil,
		"pick_driver: nil for unknown basename '/usr/local/bin/elvish' (got " .. tostring(shell.pick_driver("/usr/local/bin/elvish")) .. ")")
end

-- ===========================================================================
-- (2) pick_driver: returns nil for a user-disabled driver (config.drivers.fish=false)
-- ===========================================================================
do
	restore()
	package.loaded["pi-bridge.shell.fish"] = { start = function() end } -- module IS loadable...
	pi.config.shell = pi.config.shell or {}
	pi.config.shell.drivers = { fish = false } -- ...but disabled (flag checked BEFORE require)
	check(shell.pick_driver("/usr/bin/fish") == nil,
		"pick_driver: nil for a disabled driver (fish=false) (got " .. tostring(shell.pick_driver("/usr/bin/fish")) .. ")")
end

-- ===========================================================================
-- (3) pick_driver: returns nil when the module lacks .start
-- ===========================================================================
do
	restore()
	package.loaded["pi-bridge.shell.fish"] = { no_start = true }
	check(shell.pick_driver("/usr/bin/fish") == nil,
		"pick_driver: nil when module lacks .start (got " .. tostring(shell.pick_driver("/usr/bin/fish")) .. ")")
end

-- ===========================================================================
-- (4) pick_driver: never throws on nil / '' / non-string resolved_shell
-- ===========================================================================
do
	restore()
	local ok = pcall(function()
		shell.pick_driver(nil)
		shell.pick_driver("")
		shell.pick_driver(123)
		shell.pick_driver({})
	end)
	check(ok, "pick_driver: never throws on nil/''/non-string")
	check(shell.pick_driver(nil) == nil, "pick_driver(nil) == nil")
	check(shell.pick_driver("") == nil, "pick_driver('') == nil")
end

-- ===========================================================================
-- (5) ensure(no driver): sets failed=true + cb('no driver for <shell>')
-- ===========================================================================
do
	restore()
	pi.bridge = fake_bridge("/bin/noshell") -- unknown basename → pick_driver nil
	local cb = "UNSET"
	shell.ensure(function(err) cb = err end)
	check(cb == "no driver for /bin/noshell",
		"ensure(no driver): cb('no driver for /bin/noshell') (got " .. tostring(cb) .. ")")
	-- failed flag observable via the follow-up short-circuit
	local cb2 = "UNSET"
	shell.ensure(function(err) cb2 = err end)
	check(cb2 == "daemon disabled",
		"ensure(no driver): follow-up short-circuits via failed (got " .. tostring(cb2) .. ")")
end

-- ===========================================================================
-- (6) ensure(no driver): fires notify.once('shell-degrade') EXACTLY ONCE across two calls
-- ===========================================================================
do
	restore()
	local rec = make_notify_spy()
	package.loaded["pi-bridge.notify"] = rec.spy -- swap BEFORE ensure (lazy require inside)
	pi.bridge = fake_bridge("/bin/noshell")
	shell.ensure(function() end)
	shell.ensure(function() end) -- follow-up must NOT re-notify
	check((rec.calls["shell-degrade"] or 0) == 1,
		"ensure(no driver): degrade notice fires exactly once across two calls (got " .. tostring(rec.calls["shell-degrade"]) .. ")")
	-- a SECOND unknown shell must ALSO dedup (the SAME "shell-degrade" key)
	shell.reset()
	pi.bridge = fake_bridge("/usr/local/bin/elvish") -- different unknown basename, SAME category key
	shell.ensure(function() end)
	check((rec.calls["shell-degrade"] or 0) == 1,
		"ensure(no driver): 2nd unknown shell does NOT re-fire degrade (same dedup key) (got " .. tostring(rec.calls["shell-degrade"]) .. ")")
end

-- ===========================================================================
-- (7) follow-up ensure: short-circuits with cb('daemon disabled'); driver.start NOT re-called
-- ===========================================================================
do
	restore()
	-- inject a fake driver for fish so we CAN observe .start NOT being called on the degrade path
	local fake = make_fake_driver()
	package.loaded["pi-bridge.shell.fish"] = fake
	pi.bridge = fake_bridge("/bin/noshell") -- unknown basename (NOT fish)
	shell.ensure(function() end) -- degrade: failed=true
	check(fake.captured.calls == 0,
		"follow-up setup: first ensure did not call driver.start (no driver for noshell) (got " .. fake.captured.calls .. ")")
	local cb2 = "UNSET"
	shell.ensure(function(err) cb2 = err end)
	check(cb2 == "daemon disabled",
		"follow-up ensure: cb('daemon disabled') (got " .. tostring(cb2) .. ")")
	check(fake.captured.calls == 0,
		"follow-up ensure: driver.start NOT re-called (got " .. fake.captured.calls .. ")")
end

-- ===========================================================================
-- (8) complete_current: receives (err truthy, nil items, falsy prefix) when degraded
-- ===========================================================================
do
	restore()
	pi.bridge = fake_bridge("/bin/noshell")
	shell.ensure(function() end) -- sets state.failed=true (degrade)
	local buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "!git ch" })
	local win = vim.api.nvim_get_current_win()
	vim.api.nvim_win_set_buf(win, buf)
	vim.api.nvim_win_set_cursor(win, { 1, #("!git ch") })
	local err, items, prefix = "UNSET", "UNSET", "UNSET"
	shell.complete_current(buf, function(e, it, pf) err, items, prefix = e, it, pf end)
	check(err ~= nil and err ~= "UNSET",
		"complete_current: forwards the degrade err (got " .. tostring(err) .. ")")
	check(items == nil,
		"complete_current: items is nil (no fake items leak) (got " .. tostring(items) .. ")")
	check(not prefix,
		"complete_current: prefix is falsy on the err path (got " .. tostring(prefix) .. ")")
	vim.api.nvim_buf_delete(buf, { force = true })
end

-- ===========================================================================
-- (9) disabled-driver path: ensure cb('no driver for <shell>'); .start NEVER called
-- ===========================================================================
do
	restore()
	local fake = make_fake_driver()
	package.loaded["pi-bridge.shell.fish"] = fake -- module IS loadable...
	pi.bridge = fake_bridge("/usr/bin/fish")
	pi.config.shell = pi.config.shell or {}
	pi.config.shell.drivers = { fish = false } -- ...but disabled
	local cb = "UNSET"
	shell.ensure(function(err) cb = err end)
	check(cb == "no driver for /usr/bin/fish",
		"disabled-driver: cb('no driver for /usr/bin/fish') (got " .. tostring(cb) .. ")")
	check(fake.captured.calls == 0,
		"disabled-driver: driver.start NEVER called (got " .. fake.captured.calls .. ")")
	-- follow-up short-circuits via failed
	local cb2 = "UNSET"
	shell.ensure(function(err) cb2 = err end)
	check(cb2 == "daemon disabled",
		"disabled-driver follow-up: cb('daemon disabled') (got " .. tostring(cb2) .. ")")
	check(fake.captured.calls == 0,
		"disabled-driver follow-up: driver.start NOT re-called (got " .. fake.captured.calls .. ")")
end

-- ===========================================================================
-- (10) never-throws: nil bridge / nil descriptor / nil config / nil on_ready
-- ===========================================================================
do
	-- (10a) nil bridge + unknown $SHELL → degrade path runs without throwing
	restore()
	pi.bridge = nil
	pi.descriptor = nil
	vim.env.SHELL = "/bin/noshell" -- force unknown resolved shell
	local ok1, err1 = pcall(function() shell.ensure(function() end) end)
	check(ok1, "never-throws: nil bridge/descriptor + unknown $SHELL (got " .. tostring(err1) .. ")")
	-- (10b) nil pi.config entirely — the AND-chain default {} must save it
	restore()
	local saved_config = pi.config
	pi.config = nil
	pi.bridge = fake_bridge("/bin/noshell")
	local ok2, err2 = pcall(function() shell.ensure(function() end) end)
	pi.config = saved_config
	check(ok2, "never-throws: nil pi.config (got " .. tostring(err2) .. ")")
	-- (10c) nil on_ready — guarded (replaced with a no-op)
	restore()
	pi.bridge = fake_bridge("/bin/noshell")
	local ok3, err3 = pcall(function() shell.ensure(nil) end)
	check(ok3, "never-throws: ensure(nil) (got " .. tostring(err3) .. ")")
	-- (10d) non-function on_ready (123)
	restore()
	pi.bridge = fake_bridge("/bin/noshell")
	local ok4, err4 = pcall(function() shell.ensure(123) end)
	check(ok4, "never-throws: ensure(123) (got " .. tostring(err4) .. ")")
end

-- ===========================================================================
-- (11) exports sanity — the seams under test exist
-- ===========================================================================
do
	restore()
	check(type(shell.pick_driver) == "function", "exports: pick_driver is a function (got " .. type(shell.pick_driver) .. ")")
	check(type(shell.ensure) == "function", "exports: ensure is a function (got " .. type(shell.ensure) .. ")")
	check(type(shell.complete_current) == "function", "exports: complete_current is a function (got " .. type(shell.complete_current) .. ")")
	check(type(shell.reset) == "function", "exports: reset is a function (got " .. type(shell.reset) .. ")")
end

restore()

if fails > 0 then
	io.stderr:write(fails .. " check(s) failed\n")
	vim.cmd("cquit 1")
end
io.stdout:write("SMOKE_PASS\n")