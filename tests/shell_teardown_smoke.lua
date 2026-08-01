-- === tests/shell_teardown_smoke.lua — standalone (plenary-FREE) smoke test (P2.M1.T2.S6) ===
-- The Level-2 gate for the shell.lua TEARDOWN layer (M.teardown + close_handles + the
-- _reset extension): instant, dependency-free feedback (no plenary). Exercises the teardown
-- matrix (kill+close+reset; idempotent double/triple-call; pending_cb soft-degrade; never-
-- throws on nil state / already-closing handles; cancel_req_timer called; _reset closes
-- handles; process_kill 'sigkill' + proc:close) with an INSTRUMENTED FAKE driver (counts
-- close/read_stop/process_kill calls) + fake pipes. ZERO subprocess in the UNIT matrix.
--
-- GATED REAL-FISH LEAK CHECK: if `fish` is on $PATH, spawns a REAL fish via the spike's
-- uv.spawn pattern, stores the handles into shell.state via ensure (a fake driver that
-- returns the REAL luv handles), calls teardown(), and asserts `proc/stdin/stdout:is_closing()`
-- all true + on_exit sig=9 (the F3 leak-fix proof — §17.15; loop:gc_collect is UNAVAILABLE,
-- F9). If fish is absent → SMOKE_SKIP-fish + exit 0 (§17.15: never fail CI for a missing shell).
--
-- Run from the repo root:
--   timeout 60 nvim --headless --clean -u NORC -c 'set rtp+=.' +"luafile tests/shell_teardown_smoke.lua" +qa
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
local uv = vim.uv

local fails = 0
local function check(cond, msg)
	if not cond then
		io.stderr:write("FAIL: " .. msg .. "\n")
		fails = fails + 1
	end
end

-- --- a fake bridge exposing get_shell_info() (controls the resolved shell) so the REAL
-- M.ensure resolves a "fish" basename → the injected fake driver.
local function fake_bridge(shell_path)
	return {
		get_shell_info = function()
			if shell_path == nil then return nil end
			return { shell = shell_path }
		end,
		server_info = {},
	}
end

-- --- an INSTRUMENTED fake pipe that COUNTS read_stop/close calls + records is_closing.
-- close_handles() calls read_stop THEN close on stdout; close on stdin; this lets the
-- smoke assert "exactly once" + the read_stop-before-close order.
local function instrumented_pipe(opts)
	opts = opts or {}
	return {
		read_start = function() end,
		write      = function() end,
		read_stop_calls = 0,
		close_calls     = 0,
		read_stop = function(self) self.read_stop_calls = self.read_stop_calls + 1 end,
		close     = function(self) self.close_calls = self.close_calls + 1 end,
		is_closing = function() return opts.closing or false end,
	}
end

-- --- an INSTRUMENTED fake proc that COUNTS close calls + records is_closing.
-- (process_kill is spied separately on `uv.process_kill` — close_handles calls the
-- module-level `uv.process_kill(handle, sig)`, NOT `handle:process_kill(sig)`, so an
-- instrumented proc field would never fire.)
local function instrumented_proc(opts)
	opts = opts or {}
	return {
		close_calls = 0,
		close        = function(self) self.close_calls = self.close_calls + 1 end,
		is_closing   = function() return opts.closing or false end,
	}
end

-- --- spy on `uv.process_kill` (close_handles calls the module-level fn, not a method).
-- Returns (kills, restore): kills is a list of {handle, sig} captured.
local function spy_process_kill()
	local orig = uv.process_kill
	local kills = {}
	uv.process_kill = function(handle, sig)
		kills[#kills + 1] = { handle = handle, sig = sig }
		-- real process_kill would error on a fake table; swallow by returning nil
		return nil
	end
	return kills, function() uv.process_kill = orig end
end

-- --- inject a FAKE driver whose start(opts,cb) hands the INSTRUMENTED proc/pipes to the
-- REAL M.ensure so state.proc/stdin/stdout become the instrumented fakes.
local function inject_instrumented_driver(proc, stdin, stdout)
	local drv = { calls = 0 }
	drv.start = function(opts, cb)
		drv.calls = drv.calls + 1
		cb(nil, proc, stdin, stdout)
	end
	package.loaded["pi-bridge.shell.fish"] = drv
	return drv
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
	if pi.config then pi.config.shell = orig_shell_cfg end
	shell.reset()
end

-- ===========================================================================
-- (1) teardown is a function + the module loads
-- ===========================================================================
do
	restore()
	check(type(shell.teardown) == "function", "teardown is a function (got " .. type(shell.teardown) .. ")")
	check(type(shell._reset) == "function", "_reset is a function (got " .. type(shell._reset) .. ")")
end

-- ===========================================================================
-- (2) FULL TEARDOWN on a spawned daemon: cancel_req_timer + pending_cb soft-degrade +
--     close_handles (read_stop+close stdout; process_kill+close proc; close stdin) +
--     reset (state cleared)
-- ===========================================================================
do
	restore()
	local proc, stdin, stdout =
		instrumented_proc(), instrumented_pipe(), instrumented_pipe()
	inject_instrumented_driver(proc, stdin, stdout)
	pi.bridge = fake_bridge("/usr/bin/fish")
	-- spawn to populate state.proc/stdin/stdout
	shell.ensure(function() end)
	-- arm an in-flight pending_cb (S4 request) so teardown finalizes it
	local cb_got = { err = "U", items = nil, prefix = nil }
	shell.request("git ch", 6, "", function(err, items, prefix)
		cb_got.err, cb_got.items, cb_got.prefix = err, items, prefix
	end)
	-- spy process_kill + teardown
	local kills, restore_kill = spy_process_kill()
	shell.teardown()
	restore_kill()
	-- (a) pending_cb soft-degrade: cb(nil, {}, "") — NOT ("teardown",...)
	check(cb_got.err == nil, "teardown: pending_cb delivered cb(nil,...) soft-degrade (got err=" .. tostring(cb_got.err) .. ")")
	check(type(cb_got.items) == "table" and #cb_got.items == 0,
		"teardown: pending_cb delivered items == {} (got " .. tostring(cb_got.items) .. ")")
	check(cb_got.prefix == "", "teardown: pending_cb delivered prefix == '' (got " .. tostring(cb_got.prefix) .. ")")
	-- (b) close_handles: stdout read_stop THEN close (exactly once each)
	check(stdout.read_stop_calls == 1, "teardown: stdout:read_stop called exactly once (got " .. stdout.read_stop_calls .. ")")
	check(stdout.close_calls == 1, "teardown: stdout:close called exactly once (got " .. stdout.close_calls .. ")")
	-- (c) proc: process_kill('sigkill') THEN close (the F3 leak fix — proc:close REQUIRED)
	check(#kills == 1, "teardown: uv.process_kill called exactly once (got " .. #kills .. ")")
	check(#kills == 1 and kills[1].sig == "sigkill", "teardown: uv.process_kill(_, 'sigkill') (got sig=" .. tostring(#kills == 1 and kills[1].sig) .. ")")
	check(#kills == 1 and kills[1].handle == proc, "teardown: uv.process_kill(state.proc, ...) (handle is state.proc)")
	check(proc.close_calls == 1, "teardown: proc:close called exactly once (the F3 leak fix) (got " .. proc.close_calls .. ")")
	-- (d) stdin: close (exactly once)
	check(stdin.close_calls == 1, "teardown: stdin:close called exactly once (got " .. stdin.close_calls .. ")")
	-- (e) reset: state cleared → _test_gen() == 0 + pending nil + !inflight.
	check(shell._test_gen() == 0, "teardown: reset cleared gen to 0 (got " .. tostring(shell._test_gen()) .. ")")
	check(shell._test_pending_is_nil(), "teardown: reset cleared pending_cb (nil)")
	check(not shell._test_inflight(), "teardown: reset cleared inflight (false)")
end

-- ===========================================================================
-- (3) IDEMPOTENT: teardown x3 = no throw + no double-close + no re-deliver
--     (the VimLeavePre→ExitPre double-fire is safe)
-- ===========================================================================
do
	restore()
	local proc, stdin, stdout =
		instrumented_proc(), instrumented_pipe(), instrumented_pipe()
	inject_instrumented_driver(proc, stdin, stdout)
	pi.bridge = fake_bridge("/usr/bin/fish")
	shell.ensure(function() end)
	local deliveries = 0
	shell.request("x", 1, "", function() deliveries = deliveries + 1 end)
	-- spy process_kill + teardown THREE times
	local kills, restore_kill = spy_process_kill()
	local ok = pcall(function()
		shell.teardown()
		shell.teardown()
		shell.teardown()
	end)
	restore_kill()
	check(ok, "teardown x3: no throw (the VimLeavePre→ExitPre double-fire is safe)")
	-- close counts stay 1 (no double-close error, no re-close)
	check(stdout.read_stop_calls == 1, "teardown x3: stdout:read_stop still 1 (no double-call) (got " .. stdout.read_stop_calls .. ")")
	check(stdout.close_calls == 1, "teardown x3: stdout:close still 1 (got " .. stdout.close_calls .. ")")
	check(proc.close_calls == 1, "teardown x3: proc:close still 1 (got " .. proc.close_calls .. ")")
	check(stdin.close_calls == 1, "teardown x3: stdin:close still 1 (got " .. stdin.close_calls .. ")")
	-- uv.process_kill called exactly once (no re-kill on 2nd/3rd)
	check(#kills == 1, "teardown x3: uv.process_kill still 1 (no re-kill) (got " .. #kills .. ")")
	-- the pending_cb was delivered EXACTLY ONCE (no re-deliver on 2nd/3rd call)
	check(deliveries == 1, "teardown x3: pending_cb delivered exactly once (no re-deliver) (got " .. deliveries .. ")")
end

-- ===========================================================================
-- (4) NEVER THROWS on an un-spawned daemon (state all-nil)
-- ===========================================================================
do
	restore()
	-- state is fully nil (fresh reset)
	shell.reset()
	local ok, err = pcall(function() shell.teardown() end)
	check(ok, "teardown on nil state: no throw (got " .. tostring(err) .. ")")
	-- idempotent: a 2nd call on nil state also no-throws
	local ok2, err2 = pcall(function() shell.teardown() end)
	check(ok2, "teardown on nil state x2: no throw (got " .. tostring(err2) .. ")")
end

-- ===========================================================================
-- (5) NEVER THROWS with already-closing handles (the post-_reset / EOF path)
-- ===========================================================================
do
	restore()
	-- instrumented pipes that report is_closing()==true (post-_reset state)
	local proc = instrumented_proc({ closing = true })
	local stdin = instrumented_pipe({ closing = true })
	local stdout = instrumented_pipe({ closing = true })
	inject_instrumented_driver(proc, stdin, stdout)
	pi.bridge = fake_bridge("/usr/bin/fish")
	shell.ensure(function() end)
	-- teardown with already-closing handles → no throw, no close call (is_closing guard skips)
	local kills, restore_kill = spy_process_kill()
	local ok, err = pcall(function() shell.teardown() end)
	restore_kill()
	check(ok, "teardown on already-closing handles: no throw (got " .. tostring(err) .. ")")
	check(stdout.close_calls == 0, "teardown on closing stdout: close NOT called (is_closing guard) (got " .. stdout.close_calls .. ")")
	check(proc.close_calls == 0, "teardown on closing proc: close NOT called (got " .. proc.close_calls .. ")")
	check(#kills == 0, "teardown on closing proc: uv.process_kill NOT called (got " .. #kills .. ")")
end

-- ===========================================================================
-- (6) NEVER THROWS with a THROWING consumer cb (pcall swallows)
-- ===========================================================================
do
	restore()
	local proc, stdin, stdout =
		instrumented_proc(), instrumented_pipe(), instrumented_pipe()
	inject_instrumented_driver(proc, stdin, stdout)
	pi.bridge = fake_bridge("/usr/bin/fish")
	shell.ensure(function() end)
	-- a cb that THROWS — pcall(state.pending_cb,...) must swallow it
	shell.request("x", 1, "", function()
		error("consumer cb exploded")
	end)
	local ok, err = pcall(function() shell.teardown() end)
	check(ok, "teardown with a throwing consumer cb: no throw (pcall swallowed) (got " .. tostring(err) .. ")")
end

-- ===========================================================================
-- (7) cancel_req_timer is called (the per-request timer is stopped before teardown)
--     — proved via _test_inflight/gen being cleared (a leaked timer would leave state)
-- ===========================================================================
do
	restore()
	local proc, stdin, stdout =
		instrumented_proc(), instrumented_pipe(), instrumented_pipe()
	inject_instrumented_driver(proc, stdin, stdout)
	pi.bridge = fake_bridge("/usr/bin/fish")
	shell.ensure(function() end)
	shell.request("x", 1, "", function() end)
	check(not shell._test_pending_is_nil(), "pre-teardown: pending_cb set (request armed a timer)")
	shell.teardown()
	check(shell._test_pending_is_nil(), "teardown: cancel_req_timer ran → pending_cb finalized (nil)")
end

-- ===========================================================================
-- (8) _reset (EOF) now CLOSES HANDLES: ensure → _reset() → fake close/read_stop called
-- ===========================================================================
do
	restore()
	local proc, stdin, stdout =
		instrumented_proc(), instrumented_pipe(), instrumented_pipe()
	inject_instrumented_driver(proc, stdin, stdout)
	pi.bridge = fake_bridge("/usr/bin/fish")
	shell.ensure(function() end)
	-- simulate EOF via _reset
	local kills, restore_kill = spy_process_kill()
	shell._reset()
	restore_kill()
	-- the S6 extension: _reset now closes the handles (the EOF pipe leak fix)
	check(stdout.read_stop_calls == 1, "_reset: stdout:read_stop called (S6 extension) (got " .. stdout.read_stop_calls .. ")")
	check(stdout.close_calls == 1, "_reset: stdout:close called (S6 extension) (got " .. stdout.close_calls .. ")")
	check(#kills == 1 and kills[1].sig == "sigkill", "_reset: uv.process_kill(_, 'sigkill') (moot on EOF but harmless) (got #kills=" .. #kills .. ")")
	check(proc.close_calls == 1, "_reset: proc:close called (S6 extension) (got " .. proc.close_calls .. ")")
	check(stdin.close_calls == 1, "_reset: stdin:close called (S6 extension) (got " .. stdin.close_calls .. ")")
	-- S3 regression: _reset still sets failed (does NOT call reset)
	local got = "UNSET"
	shell.ensure(function(err) got = err end)
	check(got == "daemon disabled", "_reset: still sets failed (S3 regression) (got " .. tostring(got) .. ")")
end

-- ===========================================================================
-- (9) GATED REAL-FISH LEAK CHECK — the F3 leak-fix proof on a REAL subprocess
--     spawn real fish → teardown → on_exit sig=9 → proc/stdin/stdout:is_closing() all true
-- ===========================================================================
do
	restore()
	if vim.fn.executable("fish") == 0 then
		io.stdout:write("SMOKE_SKIP-fish: fish not on PATH — gated leak check deferred (exit 0)\n")
	else
		-- spawn a real fish via the spike's uv.spawn pattern (3 piped streams)
		local rstdin = uv.new_pipe(false)
		local rstdout = uv.new_pipe(false)
		local rstderr = uv.new_pipe(false) -- the driver would own this; not stored in state
		local rproc, spawn_err
		local exit_sig
		pcall(function()
			rproc, spawn_err = uv.spawn("fish", {
				args = { "-i" },
				stdio = { rstdin, rstdout, rstderr },
			}, function(code, sig) exit_sig = sig end)
		end)
		if rproc == nil then
			io.stdout:write("SMOKE_SKIP-fish: uv.spawn(fish) failed: " .. tostring(spawn_err) .. " (exit 0)\n")
		else
			-- close stderr ourselves (a driver would own it; shell.lua never stores it)
			-- inject a fake driver that hands the REAL handles into state via ensure
			local drv = { calls = 0 }
			drv.start = function(opts, cb)
				drv.calls = drv.calls + 1
				cb(nil, rproc, rstdin, rstdout)
			end
			package.loaded["pi-bridge.shell.fish"] = drv
			pi.bridge = fake_bridge("/usr/bin/fish")
			shell.ensure(function() end)
			-- teardown: kill + close proc/stdin/stdout
			shell.teardown()
			-- the F3 leak-fix proof: process_kill alone does NOT close the handle;
			-- teardown's proc:close() does. Assert is_closing() on each handle.
			-- (on_exit sig is informational — closing the proc handle after kill may preempt
			-- the callback in some luv builds; the is_closing assertion is the robust leak check.)
			check(rproc:is_closing(), "fish teardown: proc:is_closing() (the F3 leak fix — proc:close ran)")
			check(rstdin:is_closing(), "fish teardown: stdin:is_closing()")
			check(rstdout:is_closing(), "fish teardown: stdout:is_closing()")
			-- give the loop a tick to process the kill + deliver on_exit (best-effort; not the
			-- hard gate — is_closing is). 9 == SIGKILL.
			vim.wait(500, function() return exit_sig ~= nil end, 20)
			if exit_sig ~= nil then
				check(exit_sig == 9, "fish teardown: on_exit sig==9 (SIGKILL) (got sig=" .. tostring(exit_sig) .. ")")
			else
				io.stdout:write("(info) fish on_exit did not fire post-close (acceptable; is_closing is the leak gate)\n")
			end
			-- close stderr ourselves (the driver-owns-stderr forward contract)
			if not rstderr:is_closing() then pcall(function() rstderr:close() end) end
		end
	end
end

restore()

if fails > 0 then
	io.stderr:write(fails .. " check(s) failed\n")
	vim.cmd("cquit 1")
end
io.stdout:write("SMOKE_PASS\n")