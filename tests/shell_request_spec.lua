-- === tests/shell_request_spec.lua — plenary/busted spec (the Level-2 gate, P2.M1.T2.S4) ===
-- Covers every Success Criterion of shell.lua's REQUEST layer (M.request + cancel_req_timer
-- + the module-local req_timer). MOCKS the bridge + injects a FAKE driver (so the REAL
-- M.ensure resolves "fish" + caches the FAKE stdin into state) + a FAKE stdin whose
-- write(data,cb) captures the frame (asserts the EXACT wire shape). NO subprocess.
--
-- Response delivery: state.pending_cb is module-local, so this spec uses the _test_ seams
-- on M (_test_invoke_pending / _test_inflight / _test_pending_is_nil / _test_gen /
-- _test_get_pending) to deliver a response as S5's _feed will in prod + to assert
-- post-finalize state + to capture req1's closure for the late-response-drop case. These
-- seams are internal (_test_ prefixed, NOT public API).
--
-- NOTE: do NOT name a spec-local table `pending` — it shadows plenary.busted's global
-- `pending` (the test-SKIP function). We use `got`/`cb`/`calls` locals.
--
-- Run (from the repo root):
--   timeout 90 nvim --headless --clean -u tests/minimal_init.lua \
--     -c 'lua require("plenary.busted").run("tests/shell_request_spec.lua")'
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

-- --- a FAKE stdin that mirrors the luv pipe shape (write/is_closing/close/read_stop) AND
-- captures every written frame. `write` invokes wcb(nil) (OK) or wcb(opts.write_err)
-- (async EPIPE), OR THROWS (opts.write_throw) for the sync-throw path.
local function make_fake_stdin(opts)
	opts = opts or {}
	return {
		written = {},
		write = function(self, data, wcb)
			self.written[#self.written + 1] = data
			if opts.write_throw then error("write boom") end
			if opts.write_err then
				if wcb then wcb(opts.write_err) end
			elseif wcb then
				wcb(nil)
			end
		end,
		is_closing = function() return false end,
		close = function() end,
		read_stop = function() end,
	}
end

local function make_fake_stdout()
	return {
		read_start = function() end,
		is_closing = function() return false end,
		close = function() end,
	}
end

-- --- inject a FAKE driver (S3 Block H variant) whose start(opts,cb) hands the fake stdin
-- to the REAL M.ensure so state.stdin becomes the fake — reusing S3's ensure as a bonus.
local function inject_fake_driver(fake_stdin, driver_opts)
	driver_opts = driver_opts or {}
	local drv = { calls = 0 }
	drv.start = function(opts, cb)
		drv.calls = drv.calls + 1
		if driver_opts.spawn_err then
			cb(driver_opts.spawn_err, nil, nil, nil)
		else
			cb(nil, { is_closing = function() return false end }, fake_stdin, make_fake_stdout())
		end
	end
	package.loaded["pi-bridge.shell.fish"] = drv
	return drv
end

-- --- count OPEN (not closing) uv_timer_t handles (the no-leak assertion). uv.walk STILL
-- yields closing handles until GC, so filter by `not is_closing()`.
local function count_open_timers()
	local n = 0
	uv.walk(function(h)
		if type(h) == "userdata" then
			if type(h.start) == "function"
				and type(h.stop) == "function"
				and type(h.send) ~= "function"
				and type(h.read_start) ~= "function"
				and not h:is_closing() then
				n = n + 1
			end
		end
	end)
	return n
end

-- --- spy uv.new_timer (capture the ms passed to :start). luv handles are userdata whose
-- methods CANNOT be reassigned, so return a WRAPPER table delegating start/stop/close/
-- is_closing to the real timer + recording the ms.
local function spy_new_timer()
	local orig = uv.new_timer
	local starts = {}
	uv.new_timer = function()
		local t = orig()
		return {
			start = function(_, ms, rep, f) starts[#starts + 1] = ms; return t:start(ms, rep, f) end,
			stop = function() return t:stop() end,
			close = function() return t:close() end,
			is_closing = function() return t:is_closing() end,
		}
	end
	return starts, function() uv.new_timer = orig end
end

-- --- save/restore the globals the spec swaps per-case.
local orig_shell, orig_bridge, orig_desc, orig_shell_cfg

describe("pi-bridge.shell request (P2.M1.T2.S4)", function()
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

	it("writes the EXACT __PIREQ__\\t{json}\\n frame + bumps gen + sets inflight/pending_cb", function()
		local stdin = make_fake_stdin()
		local drv = inject_fake_driver(stdin)
		pi.bridge = fake_bridge("/usr/bin/fish")
		shell.ensure(function() end)
		assert.are.equals(1, drv.calls)
		local calls = 0
		shell.request("git ch", 6, "", function() calls = calls + 1 end)
		-- EXACT wire shape (key order line,cursor,after)
		assert.are.equals('__PIREQ__\t{"line":"git ch","cursor":6,"after":""}\n', stdin.written[1])
		assert.are.equals(0, calls, "cb not called before the response")
		assert.is_true(shell._test_inflight(), "inflight==true while awaiting")
		assert.is_false(shell._test_pending_is_nil(), "pending_cb set while awaiting")
		-- deliver response → cb(nil, items, prefix) once
		local got_err, got_items, got_prefix
		calls = 0
		shell._test_invoke_pending({ { value = "checkout" } }, "ch")
		assert.are.equals(1, calls)
		assert.are.equals(0, count_open_timers(), "timer closed post-response")
		_ = got_err; _ = got_items; _ = got_prefix -- (cb asserted via calls count)
	end)

	it("delivers cb(nil, items, prefix) exactly once; pending_cb nil + inflight false after", function()
		local stdin = make_fake_stdin()
		inject_fake_driver(stdin)
		pi.bridge = fake_bridge("/usr/bin/fish")
		shell.ensure(function() end)
		local got_err, got_items, got_prefix = "U", nil, nil
		shell.request("x", 1, "", function(err, items, prefix)
			got_err, got_items, got_prefix = err, items, prefix
		end)
		shell._test_invoke_pending({ { value = "a" } }, "x")
		assert.is_nil(got_err)
		assert.are.equals("a", got_items[1].value)
		assert.are.equals("x", got_prefix)
		assert.is_false(shell._test_inflight())
		assert.is_true(shell._test_pending_is_nil())
	end)

	it("pending_cb is ONE-SHOT: a 2nd invocation (same gen) is a no-op (cb NOT re-called)", function()
		local stdin = make_fake_stdin()
		inject_fake_driver(stdin)
		pi.bridge = fake_bridge("/usr/bin/fish")
		shell.ensure(function() end)
		local calls = 0
		shell.request("one", 3, "", function() calls = calls + 1 end)
		shell._test_invoke_pending({}, "")
		shell._test_invoke_pending({}, "")
		shell._test_invoke_pending({ { value = "x" } }, "p")
		assert.are.equals(1, calls, "cb called exactly once")
		assert.are.equals(0, count_open_timers())
	end)

	it("supersession cancels the prior timer + drops the stale (req1) closure via the gen-guard", function()
		local stdin = make_fake_stdin()
		inject_fake_driver(stdin)
		pi.bridge = fake_bridge("/usr/bin/fish")
		shell.ensure(function() end)
		local c1 = 0
		shell.request("old", 3, "", function() c1 = c1 + 1 end)
		-- capture req1's pending_cb closure BEFORE req2 overwrites the slot
		local req1_closure = shell._test_get_pending()
		assert.is_function(req1_closure)
		local c2, i2 = 0, nil
		shell.request("new", 3, "", function(err, items) c2 = c2 + 1; i2 = items end)
		-- invoke the STALE (req1's) closure → gen-guard drops it
		req1_closure({ { value = "STALE" } }, "s")
		assert.are.equals(0, c1, "req1's stale cb NOT called (gen-guard dropped it)")
		-- deliver req2's response → cb2 called with its OWN items
		shell._test_invoke_pending({ { value = "FRESH" } }, "n")
		assert.are.equals(1, c2)
		assert.are.equals("FRESH", i2[1].value)
		assert.are.equals(0, count_open_timers())
	end)

	it("timeout soft-degrades: cb(nil, {}, ''); timer closed; pending_cb nil", function()
		local stdin = make_fake_stdin()
		inject_fake_driver(stdin)
		pi.bridge = fake_bridge("/usr/bin/fish")
		pi.config.shell = pi.config.shell or {}
		pi.config.shell.timeout_ms = 5
		shell.ensure(function() end)
		local got_err, got_items, got_prefix = "U", nil, nil
		shell.request("slow", 4, "", function(err, items, prefix)
			got_err, got_items, got_prefix = err, items, prefix
		end)
		-- drain the luv loop so the 5ms timer fires (vim.wait runs the loop)
		local done = vim.wait(200, function() return got_err ~= "U" end, 5)
		assert.is_true(done, "timer fired within vim.wait")
		assert.is_nil(got_err, "cb(nil,...) soft-degrade NOT an error")
		assert.is_same({}, got_items, "empty items {} on timeout")
		assert.are.equals("", got_prefix, "prefix '' on timeout")
		assert.is_false(shell._test_inflight())
		assert.is_true(shell._test_pending_is_nil())
		assert.are.equals(0, count_open_timers(), "timer closed post-timeout")
	end)

	it("timeout superseded before fire: req1's timer closed by req2; req1 cb NOT called", function()
		local stdin = make_fake_stdin()
		inject_fake_driver(stdin)
		pi.bridge = fake_bridge("/usr/bin/fish")
		pi.config.shell = pi.config.shell or {}
		pi.config.shell.timeout_ms = 50
		shell.ensure(function() end)
		local c1 = 0
		shell.request("r1", 2, "", function() c1 = c1 + 1 end)
		local c2 = 0
		shell.request("r2", 2, "", function() c2 = c2 + 1 end)
		-- drain the loop (req1's timer was closed by req2's cancel_req_timer → no fire)
		vim.wait(120, function() return c2 > 0 end, 5)
		assert.are.equals(0, c1, "req1 cb NOT called (timer was closed)")
		shell._test_invoke_pending({ { value = "two" } }, "r")
		assert.are.equals(1, c2)
		assert.are.equals(0, count_open_timers())
	end)

	it("write-fail async (EPIPE in the write cb): cb('write failed'); timer closed; pending_cb nil", function()
		local stdin = make_fake_stdin({ write_err = "EPIPE" })
		inject_fake_driver(stdin)
		pi.bridge = fake_bridge("/usr/bin/fish")
		shell.ensure(function() end)
		local got = "U"
		shell.request("epipe", 5, "", function(err) got = err end)
		assert.are.equals("write failed", got)
		assert.is_false(shell._test_inflight())
		assert.is_true(shell._test_pending_is_nil())
		assert.are.equals(0, count_open_timers())
	end)

	it("write-fail sync (stdin:write THROWS): pcall catches → cb('write failed')", function()
		local stdin = make_fake_stdin({ write_throw = true })
		inject_fake_driver(stdin)
		pi.bridge = fake_bridge("/usr/bin/fish")
		shell.ensure(function() end)
		local got = "U"
		shell.request("throw", 5, "", function(err) got = err end)
		assert.are.equals("write failed", got)
		assert.is_false(shell._test_inflight())
		assert.is_true(shell._test_pending_is_nil())
		assert.are.equals(0, count_open_timers())
	end)

	it("ensure-fails (daemon disabled): cb('daemon disabled'); NO gen bump / timer / write", function()
		local stdin = make_fake_stdin()
		inject_fake_driver(stdin)
		pi.bridge = fake_bridge("/usr/bin/fish")
		shell.ensure(function() end)
		shell._reset() -- marks failed → next ensure short-circuits w/ "daemon disabled"
		local gen_before = shell._test_gen()
		local got = "U"
		shell.request("down", 4, "", function(err) got = err end)
		assert.are.equals("daemon disabled", got)
		assert.are.equals(gen_before, shell._test_gen(), "gen NOT bumped on ensure-fail")
		assert.are.equals(0, #stdin.written, "NO write happened")
		assert.are.equals(0, count_open_timers(), "NO timer armed")
	end)

	it("config.shell.timeout_ms honored (NOT the 1500 default)", function()
		local stdin = make_fake_stdin()
		inject_fake_driver(stdin)
		pi.bridge = fake_bridge("/usr/bin/fish")
		pi.config.shell = pi.config.shell or {}
		pi.config.shell.timeout_ms = 2500
		shell.ensure(function() end)
		local starts, restore_timer = spy_new_timer()
		shell.request("cfg", 3, "", function() end)
		restore_timer()
		assert.are.equals(1, #starts, "one timer armed")
		assert.are.equals(2500, starts[1], "timer started w/ 2500 (NOT 1500 default)")
		-- drive to terminal so no timer leaks
		shell._test_invoke_pending({}, "")
		assert.are.equals(0, count_open_timers())
	end)

	it("nil config does not throw; timeout defaults to 1500", function()
		local stdin = make_fake_stdin()
		inject_fake_driver(stdin)
		pi.bridge = fake_bridge("/usr/bin/fish")
		shell.ensure(function() end)
		local saved = pi.config
		pi.config = nil
		local starts, restore_timer = spy_new_timer()
		local ok = pcall(function()
			shell.request("nil", 3, "", function() end)
		end)
		restore_timer()
		pi.config = saved
		assert.is_true(ok, "request must not throw when pi.config is nil")
		assert.are.equals(1, #starts)
		assert.are.equals(1500, starts[1])
		shell._test_invoke_pending({}, "")
		assert.are.equals(0, count_open_timers())
	end)

	it("never throws on bad cb args (nil / 123)", function()
		local stdin = make_fake_stdin()
		inject_fake_driver(stdin)
		pi.bridge = fake_bridge("/usr/bin/fish")
		shell.ensure(function() end)
		assert.has_no.errors(function() shell.request("x", 1, "", nil) end)
		shell._test_invoke_pending({}, "") -- drive to terminal
		shell.reset()
		shell.ensure(function() end)
		assert.has_no.errors(function() shell.request("x", 1, "", 123) end)
		shell._test_invoke_pending({}, "")
	end)

	it("never throws on a non-encodable payload → cb('encode failed')", function()
		local stdin = make_fake_stdin()
		inject_fake_driver(stdin)
		pi.bridge = fake_bridge("/usr/bin/fish")
		shell.ensure(function() end)
		local got = "U"
		assert.has_no.errors(function()
			shell.request({ bad = function() end }, 1, "", function(err) got = err end)
		end)
		assert.are.equals("encode failed", got)
		assert.are.equals(0, count_open_timers(), "no timer leak after encode-fail")
	end)

	it("exposes M.request as a function (+ the test seams are functions)", function()
		assert.are.equals("function", type(shell.request))
		assert.are.equals("function", type(shell._test_invoke_pending))
		assert.are.equals("function", type(shell._test_get_pending))
		assert.are.equals("function", type(shell._test_gen))
		assert.are.equals("function", type(shell._test_inflight))
		assert.are.equals("function", type(shell._test_pending_is_nil))
	end)
end)