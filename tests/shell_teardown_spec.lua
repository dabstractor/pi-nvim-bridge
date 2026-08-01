-- === tests/shell_teardown_spec.lua — plenary/busted spec (the Level-2 gate, P2.M1.T2.S6) ===
-- Covers every Success Criterion of shell.lua's TEARDOWN layer (M.teardown + close_handles
-- + the _reset extension). MOCKS the bridge + injects a FAKE driver (so the REAL M.ensure
-- caches the INSTRUMENTED proc/pipes into state) + INSTRUMENTED fakes that COUNT
-- close/read_stop calls + SPY uv.process_kill. NO subprocess (the live fish leak proof is
-- in tests/shell_teardown_smoke.lua's gated block; the §17.15 spec intent).
--
-- state.pending_cb is module-local, so this spec uses the REAL M.request (S4) to ARM an
-- in-flight pending_cb, then asserts teardown finalizes it (cb(nil, {}, "") soft-degrade).
-- It also uses the _test_ seams (_test_gen / _test_inflight / _test_pending_is_nil) to
-- observe post-teardown state (mirrors shell_request_spec.lua).
--
-- NOTE: do NOT name a spec-local table `pending` — it shadows plenary.busted's global
-- `pending` (the test-SKIP function). We use `got`/`cb`/`calls` locals.
--
-- Run (from the repo root):
--   timeout 90 nvim --headless --clean -u tests/minimal_init.lua \
--     -c 'lua require("plenary.busted").run("tests/shell_teardown_spec.lua")'
local pi = require("pi-bridge")
local shell = require("pi-bridge.shell")
local uv = vim.uv

if pi.config == nil then pi.setup({}) end -- self-sufficient (mirror completion_spec.lua L18)

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
local function instrumented_pipe(opts)
	opts = opts or {}
	return {
		read_start      = function() end,
		write           = function() end,
		read_stop_calls = 0,
		close_calls     = 0,
		read_stop = function(self) self.read_stop_calls = self.read_stop_calls + 1 end,
		close     = function(self) self.close_calls = self.close_calls + 1 end,
		is_closing = function() return opts.closing or false end,
	}
end

-- --- an INSTRUMENTED fake proc that COUNTS close calls + records is_closing.
-- (process_kill is spied separately on `uv.process_kill` — close_handles calls the
-- module-level `uv.process_kill(handle, sig)`, NOT `handle:process_kill(sig)`.)
local function instrumented_proc(opts)
	opts = opts or {}
	return {
		close_calls = 0,
		close       = function(self) self.close_calls = self.close_calls + 1 end,
		is_closing  = function() return opts.closing or false end,
	}
end

-- --- a FAKE stdin that mirrors the luv pipe shape AND captures every written frame
-- (S4's M.request writes the __PIREQ__ frame). write invokes wcb(nil) (OK).
local function make_fake_stdin(opts)
	opts = opts or {}
	return {
		written = {},
		read_stop_calls = 0,
		close_calls     = 0,
		write = function(self, data, wcb)
			self.written[#self.written + 1] = data
			if wcb then wcb(nil) end
		end,
		read_stop = function(self) self.read_stop_calls = self.read_stop_calls + 1 end,
		close     = function(self) self.close_calls = self.close_calls + 1 end,
		is_closing = function() return opts.closing or false end,
	}
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

-- --- spy on `uv.process_kill` (close_handles calls the module-level fn, not a method).
-- Returns (kills, restore): kills is a list of {handle, sig} captured.
local function spy_process_kill()
	local orig = uv.process_kill
	local kills = {}
	uv.process_kill = function(handle, sig)
		kills[#kills + 1] = { handle = handle, sig = sig }
		return nil -- swallow (real fn would error on a fake table)
	end
	return kills, function() uv.process_kill = orig end
end

-- --- save/restore the globals the spec swaps per-case.
local orig_shell, orig_bridge, orig_desc, orig_shell_cfg

describe("pi-bridge.shell teardown (P2.M1.T2.S6)", function()
	before_each(function()
		orig_shell = vim.env.SHELL
		orig_bridge = pi.bridge
		orig_desc = pi.descriptor
		orig_shell_cfg = (pi.config and pi.config.shell) or nil
		pi.bridge = nil
		pi.descriptor = nil
		vim.env.SHELL = nil
		package.loaded["pi-bridge.shell.fish"] = nil
		shell.reset()
	end)
	after_each(function()
		vim.env.SHELL = orig_shell
		pi.bridge = orig_bridge
		pi.descriptor = orig_desc
		package.loaded["pi-bridge.shell.fish"] = nil
		if pi.config then pi.config.shell = orig_shell_cfg end
		shell.reset()
	end)

	it("exposes teardown as a function", function()
		assert.are.equals("function", type(shell.teardown))
	end)

	it("teardown on a spawned daemon: cancel_req_timer + pending_cb soft-degrade + close_handles + reset", function()
		local proc, stdout = instrumented_proc(), instrumented_pipe()
		local stdin = make_fake_stdin()
		inject_instrumented_driver(proc, stdin, stdout)
		pi.bridge = fake_bridge("/usr/bin/fish")
		shell.ensure(function() end)
		-- arm an in-flight pending_cb via the REAL S4 request
		local got_err, got_items, got_prefix = "U", nil, nil
		shell.request("git ch", 6, "", function(err, items, prefix)
			got_err, got_items, got_prefix = err, items, prefix
		end)
		assert.is_false(shell._test_pending_is_nil(), "pre-teardown: pending_cb armed")
		-- teardown (spy process_kill)
		local kills, restore_kill = spy_process_kill()
		shell.teardown()
		restore_kill()
		-- pending_cb soft-degrade: cb(nil, {}, "") — NOT ("teardown",...)
		assert.is_nil(got_err, "pending_cb delivered cb(nil,...) (got err=" .. tostring(got_err) .. ")")
		assert.are.same({}, got_items, "pending_cb delivered items == {}")
		assert.are.equals("", got_prefix, "pending_cb delivered prefix == ''")
		-- close_handles: stdout read_stop THEN close (exactly once)
		assert.are.equals(1, stdout.read_stop_calls, "stdout:read_stop once")
		assert.are.equals(1, stdout.close_calls, "stdout:close once")
		-- proc: uv.process_kill('sigkill') THEN close (the F3 leak fix)
		assert.are.equals(1, #kills, "uv.process_kill once")
		assert.are.equals("sigkill", kills[1].sig, "uv.process_kill(_, 'sigkill')")
		assert.are.equals(proc, kills[1].handle, "uv.process_kill(state.proc, ...)")
		assert.are.equals(1, proc.close_calls, "proc:close once (F3 leak fix)")
		-- stdin: close
		assert.are.equals(1, stdin.close_calls, "stdin:close once")
		-- reset: state cleared
		assert.are.equals(0, shell._test_gen(), "gen reset to 0")
		assert.is_true(shell._test_pending_is_nil(), "pending_cb cleared")
		assert.is_false(shell._test_inflight(), "inflight cleared")
	end)

	it("teardown is idempotent: 2nd + 3rd call are no-ops (VimLeavePre→ExitPre double-fire safe)", function()
		local proc, stdout = instrumented_proc(), instrumented_pipe()
		local stdin = make_fake_stdin()
		inject_instrumented_driver(proc, stdin, stdout)
		pi.bridge = fake_bridge("/usr/bin/fish")
		shell.ensure(function() end)
		local deliveries = 0
		shell.request("x", 1, "", function() deliveries = deliveries + 1 end)
		local kills, restore_kill = spy_process_kill()
		assert.has_no.errors(function()
			shell.teardown()
			shell.teardown()
			shell.teardown()
		end)
		restore_kill()
		-- close counts stay 1 (no double-close)
		assert.are.equals(1, stdout.read_stop_calls, "stdout:read_stop still 1 (no double-call)")
		assert.are.equals(1, stdout.close_calls, "stdout:close still 1")
		assert.are.equals(1, proc.close_calls, "proc:close still 1")
		assert.are.equals(1, stdin.close_calls, "stdin:close still 1")
		assert.are.equals(1, #kills, "uv.process_kill still 1 (no re-kill)")
		-- pending_cb delivered EXACTLY ONCE (no re-deliver)
		assert.are.equals(1, deliveries, "pending_cb delivered exactly once (no re-deliver)")
	end)

	it("teardown never throws on an un-spawned daemon (state all-nil)", function()
		-- state is fully nil (fresh reset)
		shell.reset()
		assert.has_no.errors(function()
			shell.teardown()
			shell.teardown() -- idempotent on nil state too
		end)
	end)

	it("teardown never throws with already-closing handles (post-_reset / EOF path)", function()
		local proc = instrumented_proc({ closing = true })
		local stdin = make_fake_stdin({ closing = true })
		local stdout = instrumented_pipe({ closing = true })
		inject_instrumented_driver(proc, stdin, stdout)
		pi.bridge = fake_bridge("/usr/bin/fish")
		shell.ensure(function() end)
		local kills, restore_kill = spy_process_kill()
		assert.has_no.errors(function() shell.teardown() end)
		restore_kill()
		-- is_closing guard skips → no close/kill calls
		assert.are.equals(0, stdout.close_calls, "closing stdout: close NOT called (is_closing guard)")
		assert.are.equals(0, proc.close_calls, "closing proc: close NOT called")
		assert.are.equals(0, stdin.close_calls, "closing stdin: close NOT called")
		assert.are.equals(0, #kills, "closing proc: uv.process_kill NOT called")
	end)

	it("teardown never throws with a throwing consumer cb (pcall swallows)", function()
		local proc, stdout = instrumented_proc(), instrumented_pipe()
		local stdin = make_fake_stdin()
		inject_instrumented_driver(proc, stdin, stdout)
		pi.bridge = fake_bridge("/usr/bin/fish")
		shell.ensure(function() end)
		shell.request("x", 1, "", function()
			error("consumer cb exploded")
		end)
		assert.has_no.errors(function() shell.teardown() end)
		-- the throwing cb did NOT prevent teardown from closing the handles
		assert.are.equals(1, proc.close_calls, "proc:close ran despite the throwing cb")
		assert.are.equals(1, stdout.close_calls, "stdout:close ran despite the throwing cb")
	end)

	it("teardown calls proc:close() (the F3 leak fix — process_kill alone LEAKS)", function()
		local proc, stdout = instrumented_proc(), instrumented_pipe()
		local stdin = make_fake_stdin()
		inject_instrumented_driver(proc, stdin, stdout)
		pi.bridge = fake_bridge("/usr/bin/fish")
		shell.ensure(function() end)
		shell.teardown()
		assert.are.equals(1, proc.close_calls, "proc:close() called (F3 leak fix)")
	end)

	it("teardown calls uv.process_kill(state.proc, 'sigkill')", function()
		local proc, stdout = instrumented_proc(), instrumented_pipe()
		local stdin = make_fake_stdin()
		inject_instrumented_driver(proc, stdin, stdout)
		pi.bridge = fake_bridge("/usr/bin/fish")
		shell.ensure(function() end)
		local kills, restore_kill = spy_process_kill()
		shell.teardown()
		restore_kill()
		assert.are.equals(1, #kills, "uv.process_kill called once")
		assert.are.equals(proc, kills[1].handle, "uv.process_kill(state.proc, ...)")
		assert.are.equals("sigkill", kills[1].sig, "uv.process_kill(_, 'sigkill')")
	end)

	it("teardown read_stop's stdout BEFORE close (the order, NOT reversed)", function()
		local stdout = instrumented_pipe()
		local stdin = make_fake_stdin()
		local proc = instrumented_proc()
		inject_instrumented_driver(proc, stdin, stdout)
		pi.bridge = fake_bridge("/usr/bin/fish")
		shell.ensure(function() end)
		shell.teardown()
		-- both called exactly once (the order is structural: read_stop is coded before close
		-- in close_handles; both fire on an open handle)
		assert.are.equals(1, stdout.read_stop_calls, "stdout:read_stop called")
		assert.are.equals(1, stdout.close_calls, "stdout:close called")
	end)

	it("teardown delivers pending_cb({}, '') (NOT ('teardown',...)) — respects S4's (items, prefix) signature", function()
		local proc, stdout = instrumented_proc(), instrumented_pipe()
		local stdin = make_fake_stdin()
		inject_instrumented_driver(proc, stdin, stdout)
		pi.bridge = fake_bridge("/usr/bin/fish")
		shell.ensure(function() end)
		local got_items, got_prefix = nil, nil
		shell.request("x", 1, "", function(err, items, prefix)
			assert.is_nil(err)
			got_items, got_prefix = items, prefix
		end)
		shell.teardown()
		-- items is a TABLE ({}), NOT the string "teardown" (the item-description bug)
		assert.is_table(got_items, "items is a table ({}), NOT the string 'teardown'")
		assert.are.equals(0, #got_items, "items is empty {}")
		assert.are.equals("", got_prefix, "prefix is '' (the soft-degrade)")
	end)

	it("teardown calls cancel_req_timer FIRST (per-request timer stopped before kill/close)", function()
		local proc, stdout = instrumented_proc(), instrumented_pipe()
		local stdin = make_fake_stdin()
		inject_instrumented_driver(proc, stdin, stdout)
		pi.bridge = fake_bridge("/usr/bin/fish")
		shell.ensure(function() end)
		shell.request("x", 1, "", function() end)
		assert.is_false(shell._test_pending_is_nil(), "pre-teardown: pending_cb armed (timer alive)")
		shell.teardown()
		-- cancel_req_timer ran → pending_cb was finalized (nil) — a leaked timer would have
		-- fired + delivered, but teardown nulls the slot first via cancel_req_timer → reset.
		assert.is_true(shell._test_pending_is_nil(), "cancel_req_timer ran → pending_cb finalized")
		assert.are.equals(0, shell._test_gen(), "gen reset to 0 (full reset ran)")
	end)

	it("_reset (EOF) now closes handles: fake close/read_stop/process_kill called", function()
		local proc, stdout = instrumented_proc(), instrumented_pipe()
		local stdin = make_fake_stdin()
		inject_instrumented_driver(proc, stdin, stdout)
		pi.bridge = fake_bridge("/usr/bin/fish")
		shell.ensure(function() end)
		local kills, restore_kill = spy_process_kill()
		assert.has_no.errors(function() shell._reset() end)
		restore_kill()
		-- the S6 extension: _reset now closes the handles (the EOF pipe leak fix)
		assert.are.equals(1, stdout.read_stop_calls, "_reset: stdout:read_stop called (S6 extension)")
		assert.are.equals(1, stdout.close_calls, "_reset: stdout:close called (S6 extension)")
		assert.are.equals(1, #kills, "_reset: uv.process_kill called (moot on EOF but harmless)")
		assert.are.equals("sigkill", kills[1].sig, "_reset: uv.process_kill(_, 'sigkill')")
		assert.are.equals(1, proc.close_calls, "_reset: proc:close called (S6 extension)")
		assert.are.equals(1, stdin.close_calls, "_reset: stdin:close called (S6 extension)")
	end)

	it("_reset still sets failed + does NOT call reset (S3 regression)", function()
		local proc, stdout = instrumented_proc(), instrumented_pipe()
		local stdin = make_fake_stdin()
		inject_instrumented_driver(proc, stdin, stdout)
		pi.bridge = fake_bridge("/usr/bin/fish")
		shell.ensure(function() end)
		shell._reset()
		-- failed=true → follow-up ensure short-circuits "daemon disabled" (reset() would
		-- have cleared failed → ensure would RE-SPAWN; _reset must NOT call reset)
		local got = "UNSET"
		shell.ensure(function(err) got = err end)
		assert.are.equals("daemon disabled", got, "_reset left failed=true (does NOT call reset)")
		-- gen is NOT reset by _reset (only teardown→reset clears it); it stays at whatever it was
		-- (we did not call request, so gen==0). The point: _reset does not touch gen/inflight.
	end)

	it("teardown finalizes an in-flight request: request()→teardown→cb(nil, {}, '')", function()
		local proc, stdout = instrumented_proc(), instrumented_pipe()
		local stdin = make_fake_stdin()
		inject_instrumented_driver(proc, stdin, stdout)
		pi.bridge = fake_bridge("/usr/bin/fish")
		shell.ensure(function() end)
		local called, got_err, got_items, got_prefix = 0, "U", nil, nil
		shell.request("git ch", 6, "", function(err, items, prefix)
			called = called + 1
			got_err, got_items, got_prefix = err, items, prefix
		end)
		shell.teardown()
		assert.are.equals(1, called, "the in-flight cb fired exactly once")
		assert.is_nil(got_err, "cb(nil, ...) — soft-degrade")
		assert.are.same({}, got_items, "cb(_, {}, ...) — empty items")
		assert.are.equals("", got_prefix, "cb(_, {}, '') — empty prefix")
	end)
end)