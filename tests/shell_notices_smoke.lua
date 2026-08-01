-- === tests/shell_notices_smoke.lua — standalone (plenary-FREE) smoke test (P2.M2.T3.S4) ===
-- The Level-1 gate for the shell.lua NOTICE wiring: the §17.4.3 mismatch notice, the
-- §17.9 first-run hint, and the §17.12 degrade notice — each emitted at most once per
-- session via notify.once. Instant, dependency-free feedback (no plenary). Exercises the
-- three notice paths with a FAKE driver injected into package.loaded + fake pipes +
-- vim.fn.executable stubbing for the mismatch PATH check. ZERO subprocess.
--
-- Run from the repo root:
--   timeout 60 nvim --headless --clean -u NORC -c 'set rtp+=.' +"luafile tests/shell_notices_smoke.lua" +qa
--   echo "exit=$?"   # 0 = pass (prints 'S4_SMOKE_OK'), 1 = a check failed
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

-- --- a fake bridge exposing get_shell_info() (controls the resolved shell).
local function fake_bridge(shell_path)
	return {
		get_shell_info = function()
			if shell_path == nil then return nil end
			return { shell = shell_path }
		end,
		server_info = {},
	}
end

-- --- a fake driver whose start(opts,cb) spawns successfully (the happy path) OR
-- fails (opts._fail → cb(err)). Calls cb SYNCHRONOUSLY. Mirrors shell_ensure_smoke.lua.
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

-- --- INJECT the fake driver under the basename of the resolved shell path so
-- pick_driver(resolved) finds it. Returns the fake for capture assertions.
local function inject_for(resolved_shell_path)
	local base = resolved_shell_path:gsub(".*/", "")
	local fake = make_fake_driver()
	package.loaded["pi-bridge.shell." .. base] = fake
	return fake
end

-- --- save/restore the globals the smoke swaps per-case.
local orig_shell = vim.env.SHELL
local orig_bridge = pi.bridge
local orig_desc = pi.descriptor
local orig_shell_cfg = (pi.config and pi.config.shell) or nil
local orig_exec = vim.fn.executable

local function restore()
	vim.env.SHELL = orig_shell
	pi.bridge = orig_bridge
	pi.descriptor = orig_desc
	-- clear every fake driver we may have injected (all basenames)
	for _, base in ipairs({ "fish", "bash", "zsh", "noshell", "unknownshell" }) do
		package.loaded["pi-bridge.shell." .. base] = nil
	end
	if pi.config then pi.config.shell = orig_shell_cfg end
	vim.fn.executable = orig_exec
	notify.reset()
	shell.reset()
	-- drain any pending vim.schedule'd vim.notify calls from the prior case so they do
	-- not leak into a later case's counting stub (notify.once schedules the notify).
	vim.wait(60, function() return false end, 5)
end

-- wait for a notify category to flush (notify.once vim.schedule's the notify; did_notify
-- is set synchronously BEFORE the schedule, so this is a belt-and-suspenders flush).
local function wait_notify(category)
	vim.wait(200, function() return notify.did_notify(category) end, 5)
end

-- ===========================================================================
-- (1) HAPPY PATH: resolved fish (==$SHELL) → first-run hint, NO mismatch, NO degrade
-- ===========================================================================
do
	restore()
	inject_for("/usr/bin/fish")
	pi.bridge = fake_bridge("/usr/bin/fish")
	vim.env.SHELL = "/usr/bin/fish"
	shell.ensure(function() end)
	wait_notify("shell-active")
	check(notify.did_notify("shell-active"), "happy: first-run hint fires on healthy spawn")
	check(not notify.did_notify("shell-mismatch"), "happy: NO mismatch when resolved==$SHELL")
	check(not notify.did_notify("shell-degrade"), "happy: NO degrade on healthy spawn")
end

-- ===========================================================================
-- (2) MISMATCH PATH: resolved bash + $SHELL=zsh + zsh on PATH (stub executable) → mismatch
--     Note: a healthy spawn ALSO fires the first-run hint (mismatch + active are independent).
-- ===========================================================================
do
	restore()
	inject_for("/bin/bash")
	pi.bridge = fake_bridge("/bin/bash")
	vim.env.SHELL = "/bin/zsh"
	vim.fn.executable = function(name) return name == "zsh" and 1 or 0 end
	shell.ensure(function() end)
	wait_notify("shell-mismatch")
	check(notify.did_notify("shell-mismatch"), "mismatch: fires (bash resolved + zsh $SHELL + on PATH)")
	check(notify.did_notify("shell-active"), "mismatch: first-run hint ALSO fires (healthy spawn)")
	check(not notify.did_notify("shell-degrade"), "mismatch: NO degrade (healthy spawn)")
end

-- ===========================================================================
-- (3) MISMATCH no-PATH: resolved bash + $SHELL=zsh BUT executable returns 0 → no mismatch
-- ===========================================================================
do
	restore()
	inject_for("/bin/bash")
	pi.bridge = fake_bridge("/bin/bash")
	vim.env.SHELL = "/bin/zsh"
	vim.fn.executable = function(_) return 0 end -- zsh NOT on PATH
	shell.ensure(function() end)
	wait_notify("shell-active") -- healthy spawn fires the hint
	check(not notify.did_notify("shell-mismatch"), "no-PATH: mismatch does NOT fire (PATH gate)")
	check(notify.did_notify("shell-active"), "no-PATH: first-run hint still fires (healthy spawn)")
end

-- ===========================================================================
-- (4) MISMATCH self-gate: resolved zsh (==$SHELL) → no mismatch (resolved != bash)
-- ===========================================================================
do
	restore()
	inject_for("/bin/zsh")
	pi.bridge = fake_bridge("/bin/zsh")
	vim.env.SHELL = "/bin/zsh"
	shell.ensure(function() end)
	wait_notify("shell-active")
	check(not notify.did_notify("shell-mismatch"), "self-gate: resolved==$SHELL → no mismatch")
	check(notify.did_notify("shell-active"), "self-gate: first-run hint fires")
end

-- ===========================================================================
-- (5) DEGRADE no-driver: unknown shell → degrade, NO first-run hint (suppression)
-- ===========================================================================
do
	restore()
	pi.bridge = fake_bridge("/bin/noshell") -- unknown basename, no driver module
	shell.ensure(function() end)
	wait_notify("shell-degrade")
	check(notify.did_notify("shell-degrade"), "no-driver: degrade fires")
	check(not notify.did_notify("shell-active"), "no-driver: first-run hint SUPPRESSED (no spawn)")
	check(not notify.did_notify("shell-mismatch"), "no-driver: no mismatch (not bash)")
end

-- ===========================================================================
-- (6) DEGRADE spawn-err: fake driver cb(err) → degrade, NO first-run hint
-- ===========================================================================
do
	restore()
	local failfake = { calls = 0 }
	failfake.start = function(opts, cb)
		opts._fail = true
		local inner = make_fake_driver()
		inner.start(opts, cb) -- drives the _fail → cb("spawn err: simulated", ...)
	end
	package.loaded["pi-bridge.shell.fish"] = failfake
	pi.bridge = fake_bridge("/usr/bin/fish")
	shell.ensure(function() end)
	wait_notify("shell-degrade")
	check(notify.did_notify("shell-degrade"), "spawn-err: degrade fires")
	check(not notify.did_notify("shell-active"), "spawn-err: first-run hint SUPPRESSED")
end

-- ===========================================================================
-- (7) DEGRADE driver-threw: start throws → degrade (pcall catches)
-- ===========================================================================
do
	restore()
	local throwing = { calls = 0 }
	throwing.start = function(_opts, _cb)
		throwing.calls = throwing.calls + 1
		error("driver exploded")
	end
	package.loaded["pi-bridge.shell.fish"] = throwing
	pi.bridge = fake_bridge("/usr/bin/fish")
	local ok = pcall(function() shell.ensure(function() end) end)
	check(ok, "driver-threw: ensure does NOT throw (pcall catches)")
	wait_notify("shell-degrade")
	check(notify.did_notify("shell-degrade"), "driver-threw: degrade fires")
	check(not notify.did_notify("shell-active"), "driver-threw: first-run hint SUPPRESSED")
end

-- ===========================================================================
-- (8) DEGRADE mid-session EOF (_reset): healthy spawn first, then _reset → degrade once
-- ===========================================================================
do
	restore()
	inject_for("/usr/bin/fish")
	pi.bridge = fake_bridge("/usr/bin/fish")
	shell.ensure(function() end) -- healthy spawn (first-run hint fires)
	wait_notify("shell-active")
	check(not notify.did_notify("shell-degrade"), "EOF pre: no degrade yet (healthy spawn)")
	-- simulate EOF crash mid-session
	shell._reset()
	wait_notify("shell-degrade")
	check(notify.did_notify("shell-degrade"), "EOF: degrade fires on _reset")
end

-- ===========================================================================
-- (9) DEGRADE mid-session parse-threshold (_feed): drive 5 garbage pairs → degrade
-- ===========================================================================
do
	restore()
	inject_for("/usr/bin/fish")
	pi.bridge = fake_bridge("/usr/bin/fish")
	shell.ensure(function() end)
	wait_notify("shell-active")
	-- 5 _feed calls each carrying a complete-but-undecodable START/END pair → trips the
	-- §17.12 parse-threshold (default 5 consecutive failures → state.failed + degrade).
	local garbage = "__PIRESP_START__\n{NOT JSON}\n__PIRESP_END__\n"
	for _ = 1, 5 do
		shell._feed(garbage)
	end
	wait_notify("shell-degrade")
	check(notify.did_notify("shell-degrade"), "parse-threshold: degrade fires after N failures")
end

-- ===========================================================================
-- (10) DEDUP: a SECOND trigger of the SAME category does NOT fire a 2nd toast.
--      Drive a healthy spawn (first-run hint), then trigger _reset twice — the degrade
--      category fires exactly ONCE (notify.once dedups by category).
-- ===========================================================================
do
	restore()
	local active_calls = 0
	local degrade_calls = 0
	local orig_vnotify = vim.notify
	vim.notify = function(msg, _lvl, _opts)
		if msg and msg:find("shell completion active") then active_calls = active_calls + 1 end
		if msg and msg:find("shell completion unavailable") then degrade_calls = degrade_calls + 1 end
	end
	inject_for("/usr/bin/fish")
	pi.bridge = fake_bridge("/usr/bin/fish")
	shell.ensure(function() end) -- healthy spawn → first-run hint (1 active call)
	vim.wait(100, function() return active_calls >= 1 end, 5)
	-- a second ensure is a proc-cache hit → no re-fire (active stays 1)
	shell.ensure(function() end)
	vim.wait(50, function() return false end, 5) -- settle any stray schedule
	check(active_calls == 1, "dedup: 2nd ensure (cache hit) does NOT re-fire the hint (got " .. active_calls .. ")")
	-- now trigger _reset TWICE → degrade fires ONCE (category dedup)
	shell._reset()
	shell._reset() -- already-failed; _reset still no-ops the notify (seen set holds)
	vim.wait(100, function() return degrade_calls >= 1 end, 5)
	check(degrade_calls == 1, "dedup: degrade fires EXACTLY once across two _reset triggers (got " .. degrade_calls .. ")")
	vim.notify = orig_vnotify
end

-- ===========================================================================
-- (11) MISMATCH_TARGET pure unit cases (no daemon, no nvim) — direct checks
-- ===========================================================================
do
	restore()
	check(shell.mismatch_target("/bin/bash", "/bin/zsh") == "zsh", "mt: bash+zsh→zsh")
	check(shell.mismatch_target("/bin/bash", "/usr/bin/fish") == "fish", "mt: bash+fish→fish")
	check(shell.mismatch_target("/bin/zsh", "/bin/zsh") == nil, "mt: resolved zsh→nil")
	check(shell.mismatch_target("/bin/bash", "/bin/bash") == nil, "mt: both bash→nil")
	check(shell.mismatch_target("/bin/bash", "/bin/sh") == nil, "mt: sh not tier-1→nil")
	check(shell.mismatch_target("/bin/bash", nil) == nil, "mt: nil $SHELL→nil")
	check(shell.mismatch_target(nil, "/bin/zsh") == nil, "mt: nil resolved→nil")
	check(shell.mismatch_target("", "/bin/zsh") == nil, "mt: empty resolved→nil")
	check(shell.mismatch_target("/bin/bash", "") == nil, "mt: empty env→nil")
end

-- ===========================================================================
-- (12) BARE '!' → NO notice of any category (ensure not reached by complete_current).
--      complete_current short-circuits an empty command BEFORE calling M.request/ensure;
--      here we simply assert that with ensure NEVER run, no notify fired.
-- ===========================================================================
do
	restore()
	notify.reset()
	check(not notify.did_notify("shell-active"), "bare-!: no active notice (ensure not run)")
	check(not notify.did_notify("shell-mismatch"), "bare-!: no mismatch notice")
	check(not notify.did_notify("shell-degrade"), "bare-!: no degrade notice")
end

restore()

if fails > 0 then
	io.stderr:write(fails .. " smoke check(s) FAILED\n")
	vim.cmd("cquit 1")
end
io.stdout:write("S4_SMOKE_OK\n")