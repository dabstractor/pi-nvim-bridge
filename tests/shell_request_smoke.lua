-- === tests/shell_request_smoke.lua — standalone (plenary-FREE) smoke test (P2.M1.T2.S4) ===
-- The Level-2 gate for the shell.lua REQUEST layer (M.request): instant, dependency-free
-- feedback (no plenary). Exercises the full request matrix (happy-path response + the
-- EXACT __PIREQ__\t{json}\n wire shape, sequential reqs, late-response dropped, timeout
-- soft-degrade, timeout-superseded-dropped, write-fail async + sync, ensure-fails,
-- config-timeout pass, nil-config, never-throws, pending_cb one-shot, no timer leak) with
-- a FAKE driver + a FAKE stdin whose write(data,cb) captures the frame (so the EXACT wire
-- shape is asserted). ZERO subprocess (S1's fish spike proved the live seam; S4 is pure
-- orchestration over state.stdin:write + uv.new_timer).
--
-- Response delivery: state.pending_cb is module-local, so this smoke uses the _test_
-- seams on M (_test_invoke_pending / _test_inflight / _test_pending_is_nil / _test_gen /
-- _test_get_pending) to deliver a response as S5's _feed will in prod + to assert
-- post-finalize state + to capture req1's closure for the late-response-drop case. These
-- seams are internal (_test_ prefixed, NOT public API) and mirror how other suites
-- observe module-local state.
--
-- Run from the repo root:
--   timeout 60 nvim --headless --clean -u NORC -c 'set rtp+=.' +"luafile tests/shell_request_smoke.lua" +qa
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

-- --- a FAKE stdin that mirrors the luv pipe shape (write/is_closing/close/read_stop)
-- AND captures every written frame so tests assert the EXACT wire shape. `write` invokes
-- `wcb(nil)` (write OK → await response) or `wcb(opts.write_err)` (simulate async EPIPE),
-- OR THROWS (opts.write_throw) so the pcall'd write path is exercised. write frames are
-- captured on `.written`.
local function make_fake_stdin(opts)
	opts = opts or {}
	return {
		written = {}, -- captured frames (assert the EXACT wire shape)
		write = function(self, data, wcb)
			self.written[#self.written + 1] = data
			if opts.write_throw then error("write boom") end -- sync throw → pcall catches → cb("write failed")
			if opts.write_err then
				if wcb then wcb(opts.write_err) end -- simulate async EPIPE
			elseif wcb then
				wcb(nil) -- write OK → await response (S5 _feed → pending_cb)
			end
		end,
		is_closing = function() return false end,
		close = function() end,
		read_stop = function() end,
	}
end

local function make_fake_stdout()
	return {
		read_start = function() end, -- ensure wires read_start; S5 owns _feed (no-op here)
		is_closing = function() return false end,
		close = function() end,
	}
end

-- --- inject a FAKE driver (S3 Block H variant) whose start(opts,cb) hands the fake stdin
-- to the REAL M.ensure so state.stdin becomes the fake — reusing S3's ensure as a bonus.
-- Returns the driver so the test can read .calls.
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

-- --- count OPEN (not closing) uv_timer_t handles (the no-leak assertion). A terminal
-- request must have closed its one-shot timer (`:close()` marks it closing; luv frees it
-- on the next loop turn). uv.walk STILL yields closing handles until GC, so filter by
-- `is_closing()` — a properly closed timer reports closing==true and is excluded.
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
	if pi.config then pi.config.shell = orig_shell_cfg end -- nil restores "no shell cfg"
	shell.reset()
end

-- ===========================================================================
-- (1) HAPPY-PATH-RESPONSE: exact wire shape + cb-once + state post-response
-- ===========================================================================
do
	restore()
	local stdin = make_fake_stdin()
	local drv = inject_fake_driver(stdin)
	pi.bridge = fake_bridge("/usr/bin/fish")
	-- prime the daemon (real ensure caches the fake stdin into state)
	shell.ensure(function() end)
	check(drv.calls == 1, "happy-path setup: ensure spawned once (got " .. drv.calls .. ")")
	-- request
	local cb_calls, got_err, got_items, got_prefix = 0, "UNSET", nil, nil
	shell.request("git ch", 6, "", function(err, items, prefix)
		cb_calls = cb_calls + 1
		got_err, got_items, got_prefix = err, items, prefix
	end)
	-- EXACT wire shape
	check(stdin.written[1] == '__PIREQ__\t{"line":"git ch","cursor":6,"after":""}\n',
		"happy-path: exact wire shape (got " .. tostring(stdin.written[1]) .. ")")
	-- cb NOT yet called (awaiting the response via pending_cb)
	check(cb_calls == 0, "happy-path: cb not called before response (got " .. cb_calls .. ")")
	-- gen bumped + inflight true + pending_cb set (awaiting)
	check(shell._test_inflight() == true, "happy-path: inflight==true while awaiting response")
	check(shell._test_pending_is_nil() == false, "happy-path: pending_cb set while awaiting response")
	-- deliver the response via the test seam (S5 will do this from _feed)
	shell._test_invoke_pending({ { value = "checkout" } }, "ch")
	check(cb_calls == 1, "happy-path: cb called once after response (got " .. cb_calls .. ")")
	check(got_err == nil, "happy-path: cb(nil,...) (got err " .. tostring(got_err) .. ")")
	check(type(got_items) == "table" and got_items[1] and got_items[1].value == "checkout",
		"happy-path: items delivered (got " .. tostring(got_items) .. ")")
	check(got_prefix == "ch", "happy-path: prefix 'ch' (got " .. tostring(got_prefix) .. ")")
	-- post-response state: inflight false, pending_cb nil, timer closed (no leak)
	check(shell._test_inflight() == false, "happy-path: inflight==false post-response")
	check(shell._test_pending_is_nil() == true, "happy-path: pending_cb==nil post-response")
	check(count_open_timers() == 0, "happy-path: no timer leak (got " .. count_open_timers() .. ")")
	-- SECOND invocation of pending_cb (same gen) is a no-op (slot was nil'd)
	shell._test_invoke_pending({ { value = "stale" } }, "x")
	check(cb_calls == 1, "happy-path: 2nd pending_cb is a no-op (cb still 1) (got " .. cb_calls .. ")")
end

-- ===========================================================================
-- (2) SEQUENTIAL-REQS: req1→resp1→cb1; req2→resp2→cb2; no cross-talk
-- ===========================================================================
do
	restore()
	local stdin = make_fake_stdin()
	inject_fake_driver(stdin)
	pi.bridge = fake_bridge("/usr/bin/fish")
	shell.ensure(function() end)
	-- req1
	local c1, e1, i1 = 0, "U", nil
	shell.request("ls a", 4, "", function(err, items) c1 = c1 + 1; e1 = err; i1 = items end)
	shell._test_invoke_pending({ { value = "apple" } }, "a")
	check(c1 == 1 and e1 == nil and i1[1].value == "apple", "sequential: req1 → cb1(apple) (got " .. tostring(i1) .. ")")
	-- req2 (after req1 fully resolved — no supersession overlap)
	local c2, e2, i2 = 0, "U", nil
	shell.request("ls b", 4, "", function(err, items) c2 = c2 + 1; e2 = err; i2 = items end)
	shell._test_invoke_pending({ { value = "boat" } }, "b")
	check(c2 == 1 and e2 == nil and i2[1].value == "boat", "sequential: req2 → cb2(boat) (got " .. tostring(i2) .. ")")
	check(c1 == 1, "sequential: cb1 NOT re-called by req2 (got " .. c1 .. ")")
	check(count_open_timers() == 0, "sequential: no timer leak (got " .. count_open_timers() .. ")")
end

-- ===========================================================================
-- (3) LATE-RESPONSE-DROPPED: req1 superseded by req2 → req1's stale closure is dropped
--     by the gen-guard (capture req1's pending_cb BEFORE req2 overwrites the slot)
-- ===========================================================================
do
	restore()
	local stdin = make_fake_stdin()
	inject_fake_driver(stdin)
	pi.bridge = fake_bridge("/usr/bin/fish")
	shell.ensure(function() end)
	-- req1
	local c1 = 0
	shell.request("old", 3, "", function() c1 = c1 + 1 end)
	-- CAPTURE req1's pending_cb closure into a local BEFORE req2 overwrites state.pending_cb
	-- (mirrors the PRP research §5c recipe; in prod the sequential sentinel protocol means
	--  req1's response can't arrive after req2 is sent — this simulates the rare race.)
	local req1_closure = shell._test_get_pending()
	check(type(req1_closure) == "function", "late-drop: captured req1's pending_cb closure")
	-- req2 supersedes req1 (bumps gen; cancels req1's timer; overwrites the slot)
	local c2, i2 = 0, nil
	shell.request("new", 3, "", function(err, items) c2 = c2 + 1; i2 = items end)
	-- invoke the STALE (req1's) closure with a late response → gen-guard drops it (no-op)
	req1_closure({ { value = "STALE" } }, "s")
	check(c1 == 0, "late-drop: req1's stale cb NOT called (gen-guard dropped it) (got " .. c1 .. ")")
	-- deliver req2's response (current gen) → cb2 called with req2's OWN items
	shell._test_invoke_pending({ { value = "FRESH" } }, "n")
	check(c2 == 1, "late-drop: req2's cb called (got " .. c2 .. ")")
	check(i2[1].value == "FRESH", "late-drop: req2 got its own items (got " .. tostring(i2) .. ")")
	check(count_open_timers() == 0, "late-drop: no timer leak (got " .. count_open_timers() .. ")")
end

-- ===========================================================================
-- (4) TIMEOUT-SOFT-DEGRADE: timer fires → cb(nil, {}, ""); pending_cb nil; no leak
-- ===========================================================================
do
	restore()
	local stdin = make_fake_stdin()
	inject_fake_driver(stdin)
	pi.bridge = fake_bridge("/usr/bin/fish")
	pi.config.shell = pi.config.shell or {}
	pi.config.shell.timeout_ms = 5 -- tiny so the luv timer fires quickly
	shell.ensure(function() end)
	local cb_calls, got_err, got_items, got_prefix = 0, "U", nil, nil
	shell.request("slow", 4, "", function(err, items, prefix)
		cb_calls = cb_calls + 1
		got_err, got_items, got_prefix = err, items, prefix
	end)
	-- drain the luv loop so the 5ms timer fires (vim.wait runs the loop)
	local done = vim.wait(200, function() return cb_calls > 0 end, 5)
	check(done, "timeout: timer fired + cb called within vim.wait (cb_calls=" .. cb_calls .. ")")
	check(cb_calls == 1, "timeout: cb called exactly once (got " .. cb_calls .. ")")
	check(got_err == nil, "timeout: cb(nil,...) soft-degrade NOT an error (got err " .. tostring(got_err) .. ")")
	check(type(got_items) == "table" and #got_items == 0, "timeout: empty items {} (got " .. tostring(got_items) .. ")")
	check(got_prefix == "", "timeout: prefix '' (got " .. tostring(got_prefix) .. ")")
	check(shell._test_inflight() == false, "timeout: inflight==false post-timeout")
	check(shell._test_pending_is_nil() == true, "timeout: pending_cb==nil post-timeout")
	check(count_open_timers() == 0, "timeout: timer closed (no leak) (got " .. count_open_timers() .. ")")
end

-- ===========================================================================
-- (5) TIMEOUT-SUPERSEDED: req1 armed w/ timeout; req2 supersedes BEFORE fire → req1's
--     timer was closed by req2's cancel_req_timer; no cb1
-- ===========================================================================
do
	restore()
	local stdin = make_fake_stdin()
	inject_fake_driver(stdin)
	pi.bridge = fake_bridge("/usr/bin/fish")
	pi.config.shell = pi.config.shell or {}
	pi.config.shell.timeout_ms = 50 -- slow enough that req2 supersedes before fire
	shell.ensure(function() end)
	local c1 = 0
	shell.request("r1", 2, "", function() c1 = c1 + 1 end)
	-- req2 supersedes immediately (before the 50ms fires) → req1's timer is closed
	local c2, i2 = 0, nil
	shell.request("r2", 2, "", function(err, items) c2 = c2 + 1; i2 = items end)
	-- drain the loop to let any would-be timer fire (req1's was closed → no fire)
	vim.wait(120, function() return c2 > 0 end, 5)
	-- req1's timeout never fired (timer closed); cb1 NOT called
	check(c1 == 0, "timeout-superseded: req1 cb NOT called (timer was closed) (got " .. c1 .. ")")
	-- deliver req2's response
	shell._test_invoke_pending({ { value = "two" } }, "r")
	check(c2 == 1, "timeout-superseded: req2 cb called (got " .. c2 .. ")")
	check(count_open_timers() == 0, "timeout-superseded: no timer leak (got " .. count_open_timers() .. ")")
end

-- ===========================================================================
-- (6) WRITE-FAIL-ASYNC: fake_stdin write_err="EPIPE" → cb("write failed"); timer closed
-- ===========================================================================
do
	restore()
	local stdin = make_fake_stdin({ write_err = "EPIPE" })
	inject_fake_driver(stdin)
	pi.bridge = fake_bridge("/usr/bin/fish")
	shell.ensure(function() end)
	local cb_calls, got_err = 0, "U"
	shell.request("epipe", 5, "", function(err) cb_calls = cb_calls + 1; got_err = err end)
	check(cb_calls == 1, "write-fail-async: cb called once (got " .. cb_calls .. ")")
	check(got_err == "write failed", "write-fail-async: cb('write failed') (got " .. tostring(got_err) .. ")")
	check(shell._test_inflight() == false, "write-fail-async: inflight==false")
	check(shell._test_pending_is_nil() == true, "write-fail-async: pending_cb==nil")
	check(count_open_timers() == 0, "write-fail-async: timer closed (no leak) (got " .. count_open_timers() .. ")")
end

-- ===========================================================================
-- (7) WRITE-FAIL-SYNC: fake_stdin.write THROWS → pcall catches → cb("write failed")
-- ===========================================================================
do
	restore()
	local stdin = make_fake_stdin({ write_throw = true })
	inject_fake_driver(stdin)
	pi.bridge = fake_bridge("/usr/bin/fish")
	shell.ensure(function() end)
	local cb_calls, got_err = 0, "U"
	shell.request("throw", 5, "", function(err) cb_calls = cb_calls + 1; got_err = err end)
	check(cb_calls == 1, "write-fail-sync: cb called once (got " .. cb_calls .. ")")
	check(got_err == "write failed", "write-fail-sync: cb('write failed') (got " .. tostring(got_err) .. ")")
	check(shell._test_inflight() == false, "write-fail-sync: inflight==false")
	check(shell._test_pending_is_nil() == true, "write-fail-sync: pending_cb==nil")
	check(count_open_timers() == 0, "write-fail-sync: timer closed (no leak) (got " .. count_open_timers() .. ")")
end

-- ===========================================================================
-- (8) ENSURE-FAILS: daemon disabled → cb(err); NO gen bump / timer / write
-- ===========================================================================
do
	restore()
	local stdin = make_fake_stdin()
	inject_fake_driver(stdin)
	pi.bridge = fake_bridge("/usr/bin/fish")
	-- prime + then mark failed (the §17.12 daemon-disabled path)
	shell.ensure(function() end)
	shell._reset() -- sets state.failed → next ensure short-circuits w/ "daemon disabled"
	local gen_before = shell._test_gen()
	local cb_calls, got_err = 0, "U"
	shell.request("down", 4, "", function(err) cb_calls = cb_calls + 1; got_err = err end)
	check(cb_calls == 1, "ensure-fails: cb called once (got " .. cb_calls .. ")")
	check(got_err == "daemon disabled", "ensure-fails: cb('daemon disabled') (got " .. tostring(got_err) .. ")")
	check(shell._test_gen() == gen_before, "ensure-fails: gen NOT bumped")
	check(#stdin.written == 0, "ensure-fails: NO write happened (got " .. #stdin.written .. " frames)")
	check(count_open_timers() == 0, "ensure-fails: NO timer armed (got " .. count_open_timers() .. ")")
end

-- ===========================================================================
-- (9) CONFIG-TIMEOUT-PASS: spy uv.new_timer → spy.starts[1] == cfg.timeout_ms (not 1500)
-- ===========================================================================
do
	restore()
	local stdin = make_fake_stdin()
	inject_fake_driver(stdin)
	pi.bridge = fake_bridge("/usr/bin/fish")
	pi.config.shell = pi.config.shell or {}
	pi.config.shell.timeout_ms = 2500
	shell.ensure(function() end)
	-- spy uv.new_timer (capture the ms passed to :start without a real leak). luv handles
	-- are userdata whose methods CANNOT be reassigned, so return a WRAPPER table that
	-- delegates start/stop/close/is_closing to the real timer + records the ms.
	local orig_new_timer = uv.new_timer
	local starts = {}
	uv.new_timer = function()
		local t = orig_new_timer()
		return {
			start = function(_, ms, rep, f) starts[#starts + 1] = ms; return t:start(ms, rep, f) end,
			stop = function() return t:stop() end,
			close = function() return t:close() end,
			is_closing = function() return t:is_closing() end,
		}
	end
	local cb_calls = 0
	shell.request("cfg", 3, "", function() cb_calls = cb_calls + 1 end)
	uv.new_timer = orig_new_timer
	check(#starts == 1, "config-timeout: one timer armed (got " .. #starts .. ")")
	check(starts[1] == 2500, "config-timeout: timer started w/ 2500 (NOT 1500 default) (got " .. tostring(starts[1]) .. ")")
	-- drive to terminal (response) so no timer leaks
	shell._test_invoke_pending({}, "")
	check(cb_calls == 1, "config-timeout: response delivered (got " .. cb_calls .. ")")
	check(count_open_timers() == 0, "config-timeout: no timer leak (got " .. count_open_timers() .. ")")
end

-- ===========================================================================
-- (10) NIL-CONFIG: pi.config=nil → no throw; timer defaults to 1500
-- ===========================================================================
do
	restore()
	local stdin = make_fake_stdin()
	inject_fake_driver(stdin)
	pi.bridge = fake_bridge("/usr/bin/fish")
	shell.ensure(function() end)
	local saved_config = pi.config
	pi.config = nil
	local orig_new_timer = uv.new_timer
	local starts = {}
	uv.new_timer = function()
		local t = orig_new_timer()
		return {
			start = function(_, ms, rep, f) starts[#starts + 1] = ms; return t:start(ms, rep, f) end,
			stop = function() return t:stop() end,
			close = function() return t:close() end,
			is_closing = function() return t:is_closing() end,
		}
	end
	local cb_calls = 0
	local ok, err = pcall(function()
		shell.request("nil", 3, "", function() cb_calls = cb_calls + 1 end)
	end)
	uv.new_timer = orig_new_timer
	pi.config = saved_config
	check(ok, "nil-config: request does NOT throw (got " .. tostring(err) .. ")")
	check(#starts == 1, "nil-config: timer armed (got " .. #starts .. ")")
	check(starts[1] == 1500, "nil-config: defaults to 1500 (got " .. tostring(starts[1]) .. ")")
	-- drive to terminal so no timer leaks
	shell._test_invoke_pending({}, "")
	check(cb_calls == 1, "nil-config: response delivered (got " .. cb_calls .. ")")
	check(count_open_timers() == 0, "nil-config: no timer leak (got " .. count_open_timers() .. ")")
end

-- ===========================================================================
-- (11) NEVER-THROWS: request(nil,6,"",nil) / (...,123) / non-encodable payload
-- ===========================================================================
do
	restore()
	local stdin = make_fake_stdin()
	inject_fake_driver(stdin)
	pi.bridge = fake_bridge("/usr/bin/fish")
	shell.ensure(function() end)
	-- (11a) nil cb → replaced with a no-op; no throw
	local ok1 = pcall(function() shell.request("x", 1, "", nil) end)
	check(ok1, "never-throws: request(...,nil) does not throw")
	-- drive the armed request to terminal so no timer leaks
	shell._test_invoke_pending({}, "")
	-- (11b) non-function cb (123)
	shell.reset()
	shell.ensure(function() end)
	local ok2 = pcall(function() shell.request("x", 1, "", 123) end)
	check(ok2, "never-throws: request(...,123) does not throw")
	shell._test_invoke_pending({}, "")
	-- (11c) non-encodable payload (a function value in the line field)
	shell.reset()
	shell.ensure(function() end)
	local got_err = "U"
	local ok3 = pcall(function()
		shell.request({ bad = function() end }, 1, "", function(err) got_err = err end)
	end)
	check(ok3, "never-throws: request(non-encodable,...) does not throw")
	check(got_err == "encode failed", "never-throws: non-encodable → cb('encode failed') (got " .. tostring(got_err) .. ")")
	check(count_open_timers() == 0, "never-throws: no timer leak after encode-fail (got " .. count_open_timers() .. ")")
end

-- ===========================================================================
-- (12) PENDING-CB-ONE-SHOT (explicit): 2 invokes same gen → cb once
-- ===========================================================================
do
	restore()
	local stdin = make_fake_stdin()
	inject_fake_driver(stdin)
	pi.bridge = fake_bridge("/usr/bin/fish")
	shell.ensure(function() end)
	local c = 0
	shell.request("one", 3, "", function() c = c + 1 end)
	shell._test_invoke_pending({}, "")
	shell._test_invoke_pending({}, "")
	shell._test_invoke_pending({ { value = "x" } }, "p")
	check(c == 1, "pending-cb-one-shot: cb called exactly once (got " .. c .. ")")
	check(count_open_timers() == 0, "pending-cb-one-shot: no timer leak (got " .. count_open_timers() .. ")")
end

restore()

if fails > 0 then
	io.stderr:write(fails .. " check(s) failed\n")
	vim.cmd("cquit 1")
end
io.stdout:write("SMOKE_PASS\n")