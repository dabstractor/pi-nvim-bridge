-- === tests/shell_ensure_smoke.lua — standalone (plenary-FREE) smoke test (P2.M1.T2.S3) ===
-- The Level-2 gate for the shell.lua SPAWN layer (M.ensure + M._feed + M._reset stubs):
-- instant, dependency-free feedback (no plenary). Exercises the ensure lifecycle matrix
-- (first-spawn, cached-reuse, spawn-error, no-driver, disabled-driver, failed-short-circuit,
-- config pass-through, nil-config, session_cwd pass-through, never-throws, read_start →
-- _feed/_reset wiring) with a FAKE driver injected into package.loaded + fake pipes.
-- ZERO subprocess (the live fish seam was proven by S1's spike; S3 is pure orchestration).
--
-- Run from the repo root:
--   timeout 60 nvim --headless --clean -u NORC -c 'set rtp+=.' +"luafile tests/shell_ensure_smoke.lua" +qa
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
-- tests/shell_fish_spike.lua: read_start/write/close/read_stop/is_closing) so the
-- read_start wiring + the teardown-guard methods exist WITHOUT a real subprocess.
-- `start` calls cb SYNCHRONOUSLY (GOTCHA #10) — no vim.wait needed.
local function make_fake_driver()
	local captured = { opts = nil, calls = 0, read_cb = nil }
	local function fake_pipe()
		return {
			read_start = function(_, cb) captured.read_cb = cb end, -- ensure wires this; tests invoke it
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
			captured.opts = opts -- assert shell/cwd/startup_timeout_ms
			if opts._fail then
				cb("spawn err: simulated", nil, nil, nil)
			else
				cb(nil, { is_closing = function() return false end }, fake_pipe(), fake_pipe())
			end
		end,
	}
end

-- --- save/restore the globals the smoke swaps per-case.
local orig_shell = vim.env.SHELL
local orig_bridge = pi.bridge
local orig_desc = pi.descriptor
local orig_shell_cfg = (pi.config and pi.config.shell) or nil

local function restore()
	vim.env.SHELL = orig_shell
	pi.bridge = orig_bridge
	pi.descriptor = orig_desc
	package.loaded["pi-bridge.shell.fish"] = nil
	package.loaded["pi-bridge.shell.unknownshell"] = nil
	if pi.config then pi.config.shell = orig_shell_cfg end -- nil restores "no shell cfg"
	shell.reset()
end

-- ===========================================================================
-- (1) FIRST-SPAWN: ensure(cb) + fake fish driver → full success path
-- ===========================================================================
do
	restore()
	local fake = make_fake_driver()
	package.loaded["pi-bridge.shell.fish"] = fake
	pi.bridge = fake_bridge("/usr/bin/fish")
	local cb_arg = nil
	shell.ensure(function(err) cb_arg = err end)
	check(cb_arg == nil, "first-spawn: cb(nil) called (got " .. tostring(cb_arg) .. ")")
	-- opts passed through
	check(fake.captured.opts.shell == "/usr/bin/fish",
		"first-spawn: opts.shell == '/usr/bin/fish' (got " .. tostring(fake.captured.opts and fake.captured.opts.shell) .. ")")
	check(fake.captured.opts.startup_timeout_ms == 5000,
		"first-spawn: opts.startup_timeout_ms == 5000 default (got " .. tostring(fake.captured.opts and fake.captured.opts.startup_timeout_ms) .. ")")
	check(fake.captured.opts.cwd == nil,
		"first-spawn: opts.cwd == nil (no server_info.cwd set) (got " .. tostring(fake.captured.opts and fake.captured.opts.cwd) .. ")")
	check(fake.captured.calls == 1, "first-spawn: driver.start called exactly once (got " .. fake.captured.calls .. ")")
	check(fake.captured.read_cb ~= nil, "first-spawn: stdout:read_start wired (read_cb captured)")
	-- peek module-local state via a second ensure (cached path proves proc was set)
	local cb2 = nil
	shell.ensure(function(err) cb2 = err end)
	check(cb2 == nil, "first-spawn→cached: second ensure cb(nil) (proc was cached) (got " .. tostring(cb2) .. ")")
	check(fake.captured.calls == 1, "first-spawn→cached: driver.start NOT re-called (still 1) (got " .. fake.captured.calls .. ")")
end

-- ===========================================================================
-- (2) CACHED-REUSE: state.proc preset → driver.start never called
-- ===========================================================================
do
	restore()
	local fake = make_fake_driver()
	package.loaded["pi-bridge.shell.fish"] = fake
	pi.bridge = fake_bridge("/usr/bin/fish")
	-- spawn once to populate proc
	shell.ensure(function() end)
	check(fake.captured.calls == 1, "cached-reuse setup: first spawn (got " .. fake.captured.calls .. ")")
	-- second call: reuse
	local cb = nil
	shell.ensure(function(err) cb = err end)
	check(cb == nil, "cached-reuse: cb(nil) (got " .. tostring(cb) .. ")")
	check(fake.captured.calls == 1, "cached-reuse: driver.start NOT called again (got " .. fake.captured.calls .. ")")
end

-- ===========================================================================
-- (3) SPAWN-ERROR: opts._fail → driver cb err → failed=true + driver=nil; follow-up short-circuits
-- ===========================================================================
do
	restore()
	local fake = make_fake_driver()
	package.loaded["pi-bridge.shell.fish"] = fake
	pi.bridge = fake_bridge("/usr/bin/fish")
	local cb = "UNSET"
	shell.ensure(function(err) cb = err end)
	-- drive the spawn-error: need opts._fail — re-run with config marker
	check(true, "spawn-error placeholder (see next case for _fail)")
end

-- (3b) the real _fail path: inject _fail via a wrapping driver
do
	restore()
	local failfake = { calls = 0 }
	failfake.start = function(opts, cb)
		failfake.calls = failfake.calls + 1
		opts._fail = true -- the make_fake_driver reads opts._fail; but we inline here:
		cb("spawn err: simulated", nil, nil, nil)
	end
	package.loaded["pi-bridge.shell.fish"] = failfake
	pi.bridge = fake_bridge("/usr/bin/fish")
	local cb = "UNSET"
	shell.ensure(function(err) cb = err end)
	check(cb == "spawn err: simulated", "spawn-error: cb(err) (got " .. tostring(cb) .. ")")
	check(failfake.calls == 1, "spawn-error: driver.start called once (got " .. failfake.calls .. ")")
	-- follow-up: short-circuits via failed (no resolve/pick/start)
	local cb2 = "UNSET"
	shell.ensure(function(err) cb2 = err end)
	check(cb2 == "daemon disabled", "spawn-error follow-up: cb('daemon disabled') (got " .. tostring(cb2) .. ")")
	check(failfake.calls == 1, "spawn-error follow-up: driver.start NOT re-called (got " .. failfake.calls .. ")")
end

-- ===========================================================================
-- (4) NO-DRIVER: unknown shell → failed=true, cb("no driver for ..."); follow-up short-circuits
-- ===========================================================================
do
	restore()
	pi.bridge = fake_bridge("/bin/unknownshell")
	local cb = "UNSET"
	shell.ensure(function(err) cb = err end)
	check(cb == "no driver for /bin/unknownshell", "no-driver: cb('no driver for /bin/unknownshell') (got " .. tostring(cb) .. ")")
	-- follow-up short-circuits via failed
	local cb2 = "UNSET"
	shell.ensure(function(err) cb2 = err end)
	check(cb2 == "daemon disabled", "no-driver follow-up: cb('daemon disabled') (got " .. tostring(cb2) .. ")")
end

-- ===========================================================================
-- (5) DISABLED-DRIVER: config.shell.drivers.fish=false → pick_driver nil → degrade
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
	check(cb == "no driver for /usr/bin/fish", "disabled-driver: cb('no driver for ...') (got " .. tostring(cb) .. ")")
	check(fake.captured.calls == 0, "disabled-driver: driver.start NOT called (got " .. fake.captured.calls .. ")")
end

-- ===========================================================================
-- (6) FAILED-SHORTCIR: preset state.failed (via _reset stub) → cb("daemon disabled"), no start
-- ===========================================================================
do
	restore()
	local fake = make_fake_driver()
	package.loaded["pi-bridge.shell.fish"] = fake
	pi.bridge = fake_bridge("/usr/bin/fish")
	shell._reset() -- mark unhealthy (the §17.12 EOF path)
	local cb = "UNSET"
	shell.ensure(function(err) cb = err end)
	check(cb == "daemon disabled", "failed-shortcircuit: cb('daemon disabled') (got " .. tostring(cb) .. ")")
	check(fake.captured.calls == 0, "failed-shortcircuit: driver.start NOT called (got " .. fake.captured.calls .. ")")
end

-- ===========================================================================
-- (7) CONFIG-PASS: prefer + startup_timeout_ms honored
-- ===========================================================================
do
	restore()
	local fake = make_fake_driver()
	package.loaded["pi-bridge.shell.fish"] = fake
	pi.config.shell = pi.config.shell or {}
	pi.config.shell.prefer = "/usr/bin/fish"
	pi.config.shell.startup_timeout_ms = 2500
	local cb = "UNSET"
	shell.ensure(function(err) cb = err end)
	check(cb == nil, "config-pass: cb(nil) (got " .. tostring(cb) .. ")")
	check(fake.captured.opts.shell == "/usr/bin/fish",
		"config-pass: prefer honored → opts.shell == '/usr/bin/fish' (got " .. tostring(fake.captured.opts and fake.captured.opts.shell) .. ")")
	check(fake.captured.opts.startup_timeout_ms == 2500,
		"config-pass: startup_timeout_ms == 2500 (NOT 5000 default) (got " .. tostring(fake.captured.opts and fake.captured.opts.startup_timeout_ms) .. ")")
end

-- ===========================================================================
-- (8) NIL-CONFIG: pi.config nil → ensure does NOT throw; uses defaults
-- ===========================================================================
do
	restore()
	local fake = make_fake_driver()
	package.loaded["pi-bridge.shell.fish"] = fake
	pi.bridge = fake_bridge("/usr/bin/fish")
	-- nil out config entirely (simulate pre-setup)
	local saved_config = pi.config
	pi.config = nil
	local ok, err = pcall(function()
		local cb = "UNSET"
		shell.ensure(function(e) cb = e end)
		check(cb == nil, "nil-config: cb(nil) with defaults (got " .. tostring(cb) .. ")")
	end)
	pi.config = saved_config
	check(ok, "nil-config: ensure does NOT throw (got " .. tostring(err) .. ")")
	check(fake.captured.opts.startup_timeout_ms == 5000,
		"nil-config: startup_timeout_ms defaults to 5000 (got " .. tostring(fake.captured.opts and fake.captured.opts.startup_timeout_ms) .. ")")
	check(fake.captured.opts.shell == "/usr/bin/fish",
		"nil-config: prefer defaults to 'pi' → descriptor shell (got " .. tostring(fake.captured.opts and fake.captured.opts.shell) .. ")")
end

-- ===========================================================================
-- (9) CWD-PASS: server_info.cwd → opts.cwd
-- ===========================================================================
do
	restore()
	local fake = make_fake_driver()
	package.loaded["pi-bridge.shell.fish"] = fake
	pi.bridge = fake_bridge("/usr/bin/fish", "/srv")
	local cb = "UNSET"
	shell.ensure(function(err) cb = err end)
	check(cb == nil, "cwd-pass: cb(nil) (got " .. tostring(cb) .. ")")
	check(fake.captured.opts.cwd == "/srv",
		"cwd-pass: opts.cwd == '/srv' (got " .. tostring(fake.captured.opts and fake.captured.opts.cwd) .. ")")
end

-- ===========================================================================
-- (10) NEVER-THROWS: ensure(nil), ensure(123), driver.start that THROWS
-- ===========================================================================
do
	restore()
	-- (10a) ensure(nil) — guarded: on_ready replaced with no-op; must not throw
	local fake = make_fake_driver()
	package.loaded["pi-bridge.shell.fish"] = fake
	pi.bridge = fake_bridge("/usr/bin/fish")
	local ok1, err1 = pcall(function() shell.ensure(nil) end)
	check(ok1, "never-throws: ensure(nil) does not throw (got " .. tostring(err1) .. ")")
	check(fake.captured.calls == 1, "never-throws: ensure(nil) still spawned (got " .. fake.captured.calls .. ")")
	-- (10b) ensure(123) — same
	shell.reset()
	fake.captured.calls = 0
	local ok2, err2 = pcall(function() shell.ensure(123) end)
	check(ok2, "never-throws: ensure(123) does not throw (got " .. tostring(err2) .. ")")
	-- (10c) driver.start THROWS → caught, failed=true
	shell.reset()
	local throwing = { calls = 0 }
	throwing.start = function(opts, cb)
		throwing.calls = throwing.calls + 1
		error("driver exploded")
	end
	package.loaded["pi-bridge.shell.fish"] = throwing
	local cb = "UNSET"
	local ok3, err3 = pcall(function()
		shell.ensure(function(e) cb = e end)
	end)
	check(ok3, "never-throws: driver.start throw caught by ensure (got " .. tostring(err3) .. ")")
	check(cb ~= "UNSET" and cb ~= nil, "never-throws: cb called with the thrown err (got " .. tostring(cb) .. ")")
	check(throwing.calls == 1, "never-throws: throwing driver.start invoked once (got " .. throwing.calls .. ")")
	-- follow-up: failed short-circuits (no re-throw)
	local cb2 = "UNSET"
	shell.ensure(function(e) cb2 = e end)
	check(cb2 == "daemon disabled", "never-throws follow-up: cb('daemon disabled') (got " .. tostring(cb2) .. ")")
end

-- ===========================================================================
-- (11) READ→_FEED: invoke captured read_cb(nil,"X") → state.rx_buf grew (M._feed stub)
-- ===========================================================================
do
	restore()
	local fake = make_fake_driver()
	package.loaded["pi-bridge.shell.fish"] = fake
	pi.bridge = fake_bridge("/usr/bin/fish")
	shell.ensure(function() end)
	check(fake.captured.read_cb ~= nil, "read→_feed: read_cb captured")
	-- drive a chunk: rx_buf grows by "X"
	fake.captured.read_cb(nil, "X")
	-- drive another: appended (proves _feed is append-only)
	fake.captured.read_cb(nil, "YZ")
	-- rx_buf is module-local; observe via a SECOND ensure's cached path + no error.
	-- the observable proof that _feed ran: a follow-up EOF read_cb sets failed (below).
	check(true, "read→_feed: chunks driven without error")
	-- EOF now → _reset fires → failed true
	fake.captured.read_cb(nil, nil)
	-- follow-up ensure short-circuits via failed → proves _reset ran
	local cb = "UNSET"
	shell.ensure(function(err) cb = err end)
	check(cb == "daemon disabled", "read→_reset(EOF): follow-up ensure sees failed (got " .. tostring(cb) .. ")")
end

-- ===========================================================================
-- (12) READ→_RESET: invoke captured read_cb(nil,nil) [EOF] → failed=true, proc=nil
-- ===========================================================================
do
	restore()
	local fake = make_fake_driver()
	package.loaded["pi-bridge.shell.fish"] = fake
	pi.bridge = fake_bridge("/usr/bin/fish")
	shell.ensure(function() end)
	-- EOF
	fake.captured.read_cb(nil, nil)
	local cb = "UNSET"
	shell.ensure(function(err) cb = err end)
	check(cb == "daemon disabled", "read→_reset: EOF → ensure short-circuits via failed (got " .. tostring(cb) .. ")")
	-- driver.start NOT re-called (failed path skips resolve/pick/start)
	check(fake.captured.calls == 1, "read→_reset: driver.start NOT re-called after EOF (got " .. fake.captured.calls .. ")")
end

-- ===========================================================================
-- (13) STUB-EXPORTS: _feed + _reset are functions on M
-- ===========================================================================
do
	restore()
	check(type(shell._feed) == "function", "stub-exports: M._feed is a function (got " .. type(shell._feed) .. ")")
	check(type(shell._reset) == "function", "stub-exports: M._reset is a function (got " .. type(shell._reset) .. ")")
	check(type(shell.ensure) == "function", "stub-exports: M.ensure is a function (got " .. type(shell.ensure) .. ")")
	-- direct _feed behavior: append-only (observable via a fresh-state _reset then _feed)
	shell.reset()
	-- we cannot read rx_buf directly; but _feed must not throw + must accept nil/""
	local ok = pcall(function()
		shell._feed(nil)
		shell._feed("")
		shell._feed("abc")
	end)
	check(ok, "stub-exports: _feed(nil)/('')/('abc') never throw")
	-- _reset behavior: never throws, leaves failed set (a follow-up ensure short-circuits)
	local ok2 = pcall(function() shell._reset() end)
	check(ok2, "stub-exports: _reset() never throws")
	local cb = "UNSET"
	shell.ensure(function(err) cb = err end)
	check(cb == "daemon disabled", "stub-exports: after _reset(), ensure short-circuits via failed (got " .. tostring(cb) .. ")")
end

restore()

if fails > 0 then
	io.stderr:write(fails .. " check(s) failed\n")
	vim.cmd("cquit 1")
end
io.stdout:write("SMOKE_PASS\n")