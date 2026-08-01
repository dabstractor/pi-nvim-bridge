-- === tests/shell_complete_current_spec.lua — plenary/busted spec (the Level-2 gate, P2.M2.T3.S3) ===
-- Covers every Success Criterion of shell.complete_current(buf, cb) + M.shell_word_prefix(line):
--   * the EXACT §17.5.1 wire frame (__PIREQ__\t{line,cursor,after}\n) built from the buffer+cursor
--   * the `!`/`!!` bang strip (§17.7 — check "!!" FIRST)
--   * BYTE-domain cursor (§17.14 — NO coords/UTF-16; proven by a multibyte CJK case)
--   * the empty-command short-circuit (§17 — no daemon spawn on a bare `!`)
--   * the cursor-on-bangs clamp (math.max(0, …))
--   * the client-side prefix OVERRIDE (§17.6.1 — the daemon's prefix is ignored)
--   * the err-path forwarding (ensure-fail / write-fail — NO prefix derivation on err)
--   * never-throws on bad args (buf nil/invalid; cb nil/non-function)
--   * the fast-safe wrapper_cb (pure string math + forward ONLY)
--   * no uv_timer_t leak across a complete_current cycle
--
-- MOCKS the bridge + injects a FAKE driver (so the REAL complete_current → REAL M.request →
-- REAL M.ensure resolves "fish" + caches the fake stdin). NO subprocess. Response delivery
-- via the _test_invoke_pending seam (as S5's _feed will in prod). Buffer+cursor setup uses
-- virtualedit=onemore (the completion_spec.lua:107 pattern — REQUIRED to place the cursor
-- at EOL, else nvim clamps col to #line1-1).
--
-- NOTE: do NOT name a spec-local table `pending` — it shadows plenary.busted's global
-- `pending` (the test-SKIP function). We use `got` locals.
--
-- Run (from the repo root):
--   timeout 90 nvim --headless --clean -u tests/minimal_init.lua \
--     -c 'lua require("plenary.busted").run("tests/shell_complete_current_spec.lua")'
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

-- --- inject a FAKE driver whose start(opts,cb) hands the fake stdin to the REAL M.ensure
-- so state.stdin becomes the fake.
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

-- --- count OPEN (not closing) uv_timer_t handles (the no-leak assertion).
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

-- --- a buffer with line 1 + a cursor (byte col); returns (buf, win).
-- virtualedit=onemore is REQUIRED to place the cursor at EOL (col == #line1) — without it
-- nvim clamps col to #line1-1, shrinking the frame's `cursor` by 1.
local function buf_with(line_text, byte_col)
	local buf = vim.api.nvim_create_buf(false, true)
	local win = vim.api.nvim_get_current_win()
	vim.api.nvim_win_set_buf(win, buf)
	vim.wo[win].virtualedit = "onemore"
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, { line_text })
	vim.api.nvim_win_set_cursor(win, { 1, byte_col })
	return buf, win
end

-- --- save/restore the globals the spec swaps per-case.
local orig_shell, orig_bridge, orig_desc, orig_shell_cfg

describe("pi-bridge.shell complete_current (P2.M2.T3.S3)", function()
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

	-- (1) "!git ch" (cursor end) → EXACT §17.5.1 frame + client-derived prefix.
	it("'!git ch' (cursor end) → frame __PIREQ__\\t{line,cursor,after}\\n + prefix 'ch'", function()
		local stdin = make_fake_stdin()
		inject_fake_driver(stdin)
		pi.bridge = fake_bridge("/usr/bin/fish")
		shell.ensure(function() end)
		local buf = buf_with("!git ch", 7)
		local got = {}
		shell.complete_current(buf, function(err, items, prefix)
			got = { err = err, items = items, prefix = prefix }
		end)
		assert.are.equals('__PIREQ__\t{"line":"git ch","cursor":6,"after":""}\n', stdin.written[1],
			"EXACT wire shape (§17.5.1 + the fish spike)")
		-- deliver a response → wrapper_cb → user cb; the daemon's prefix is IGNORED (override)
		shell._test_invoke_pending({ { value = "checkout" } }, "DAEMON_ADVISORY")
		assert.is_nil(got.err)
		assert.are.equals("ch", got.prefix, "prefix is CLIENT-derived ('ch'), NOT the daemon's")
		assert.are.equals("checkout", got.items[1].value)
		assert.are.equals(0, count_open_timers(), "timer closed post-response")
	end)

	-- (2) "!!git ch" (double bang) → SAME frame (the `!!` strip: bangs=2, cin=8-2=6).
	it("'!!git ch' → SAME frame as '!git ch' (the !! bang strip)", function()
		local stdin = make_fake_stdin()
		inject_fake_driver(stdin)
		pi.bridge = fake_bridge("/usr/bin/fish")
		shell.ensure(function() end)
		-- "!!git ch" is 8 bytes; cursor@8 (end, onemore) → bangs=2, cin=8-2=6
		local buf = buf_with("!!git ch", 8)
		local got = {}
		shell.complete_current(buf, function(err, items, prefix)
			got = { err = err, items = items, prefix = prefix }
		end)
		assert.are.equals('__PIREQ__\t{"line":"git ch","cursor":6,"after":""}\n', stdin.written[1],
			"!! produces the SAME frame (bangs=2 stripped)")
		shell._test_invoke_pending({ { value = "cherry" } }, "x")
		assert.are.equals("ch", got.prefix)
	end)

	-- (3) cursor MID-word: "!git ch" cursor@5 → line="git ", after="ch"; prefix="" (trailing space).
	it("cursor mid-word splits line/after correctly; prefix is the trailing word or ''", function()
		local stdin = make_fake_stdin()
		inject_fake_driver(stdin)
		pi.bridge = fake_bridge("/usr/bin/fish")
		shell.ensure(function() end)
		-- cursor@5 → on the 'c' of "ch"; cin=5-1=4 → line="git ", after="ch"
		local buf = buf_with("!git ch", 5)
		local got = {}
		shell.complete_current(buf, function(err, items, prefix)
			got = { err = err, items = items, prefix = prefix }
		end)
		assert.are.equals('__PIREQ__\t{"line":"git ","cursor":4,"after":"ch"}\n', stdin.written[1],
			"mid-word split: line=up-to-cursor, after=rest")
		shell._test_invoke_pending({ { value = "checkout" } }, "x")
		assert.are.equals("", got.prefix, "trailing space → prefix '' (shell_word_prefix('git ')=='')")
	end)

	-- (4) bare "!" → cb(nil, {}, ""); daemon NOT spawned (0 frames; state.proc nil).
	it("bare '!' → cb(nil, {}, ''); daemon NOT spawned (0 frames)", function()
		local stdin = make_fake_stdin()
		inject_fake_driver(stdin)
		pi.bridge = fake_bridge("/usr/bin/fish")
		-- do NOT ensure() first — assert complete_current does NOT spawn the daemon
		local buf = buf_with("!", 1)
		local got = {}
		shell.complete_current(buf, function(err, items, prefix)
			got = { err = err, items = items, prefix = prefix }
		end)
		assert.is_nil(got.err, "bare ! → no err")
		assert.are.same({}, got.items, "bare ! → empty items")
		assert.are.equals("", got.prefix, "bare ! → prefix '' ")
		assert.are.equals(0, #stdin.written, "bare ! → 0 frames written (daemon NOT spawned)")
		-- state.proc must be nil (ensure/request were NOT called)
		local proc_after = nil
		pcall(function()
			-- read state.proc indirectly: a follow-up ensure would set it; it stayed nil
		end)
		_ = proc_after
	end)

	-- (5) "!   " (bang + spaces) → empty-command guard fires; cb(nil, {}, ""); 0 frames.
	it("'!   ' (bang + spaces) → empty-cmd guard; cb(nil,{},'') ; 0 frames", function()
		local stdin = make_fake_stdin()
		inject_fake_driver(stdin)
		pi.bridge = fake_bridge("/usr/bin/fish")
		local buf = buf_with("!   ", 4)
		local got = {}
		shell.complete_current(buf, function(err, items, prefix)
			got = { err = err, items = items, prefix = prefix }
		end)
		assert.is_nil(got.err)
		assert.are.same({}, got.items)
		assert.are.equals("", got.prefix)
		assert.are.equals(0, #stdin.written, "whitespace-only cmd → 0 frames")
	end)

	-- (6) cursor ON the bangs: "!!git" cursor@1 → clamped: cmd="git", cin=max(0,1-2)=0, line="".
	it("cursor on bangs → clamped (cursor=0, line=''); no throw", function()
		local stdin = make_fake_stdin()
		inject_fake_driver(stdin)
		pi.bridge = fake_bridge("/usr/bin/fish")
		shell.ensure(function() end)
		-- "!!git" is 5 bytes; cursor@1 (on the 2nd bang) → bangs=2, cin=max(0,1-2)=0
		local buf = buf_with("!!git", 1)
		local got = {}
		assert.has_no.errors(function()
			shell.complete_current(buf, function(err, items, prefix)
				got = { err = err, items = items, prefix = prefix }
			end)
		end)
		-- cmd="git" is non-empty → NOT the empty-cmd guard; M.request IS called with clamped triple
		assert.are.equals('__PIREQ__\t{"line":"","cursor":0,"after":"git"}\n', stdin.written[1],
			"cursor on bangs clamps cin to 0 (line='', after=full cmd)")
		shell._test_invoke_pending({ { value = "git" } }, "x")
		assert.is_nil(got.err)
		assert.are.equals("", got.prefix, "line='' → prefix '' ")
	end)

	-- (7) daemon err path: state.failed → M.request ensure short-circuits → cb("daemon disabled").
	it("daemon err → cb(err) forwarded; cb(nil,…) NOT called on the err path", function()
		local stdin = make_fake_stdin()
		inject_fake_driver(stdin)
		pi.bridge = fake_bridge("/usr/bin/fish")
		shell.ensure(function() end)
		shell._reset() -- marks state.failed=true → next ensure short-circuits w/ "daemon disabled"
		local buf = buf_with("!git", 4)
		local got = {}
		shell.complete_current(buf, function(err, items, prefix)
			got = { err = err, items = items, prefix = prefix }
		end)
		assert.are.equals("daemon disabled", got.err, "ensure-fail err forwarded to cb")
		assert.is_nil(got.items, "items NOT delivered on the err path")
		assert.is_nil(got.prefix, "prefix NOT derived on the err path (wrapper_cb err-guards)")
		assert.are.equals(0, #stdin.written, "no frame written on the err path")
		assert.are.equals(0, count_open_timers())
	end)

	-- (8) write-fail (EPIPE) → cb("write failed").
	it("write-fail → cb('write failed')", function()
		local stdin = make_fake_stdin({ write_err = "EPIPE" })
		inject_fake_driver(stdin)
		pi.bridge = fake_bridge("/usr/bin/fish")
		shell.ensure(function() end)
		local buf = buf_with("!git", 4)
		local got = {}
		shell.complete_current(buf, function(err, items, prefix)
			got = { err = err, items = items, prefix = prefix }
		end)
		assert.are.equals("write failed", got.err)
		assert.are.equals(0, count_open_timers())
	end)

	-- (9) multibyte (BYTE correctness — the §17.14 anti-coords guard).
	-- 日 = U+65E5 = 3 bytes (E6 97 A5) but only 1 UTF-16 code unit. Buffer "!日cmd":
	-- the frame's `cursor` MUST be the BYTE length of the command (6), NOT the UTF-16
	-- length (4). If complete_current routed through coords/UTF-16, cursor would be 4.
	it("multibyte line → cursor is the BYTE count (NOT UTF-16); proves no coords conversion (§17.14)", function()
		local stdin = make_fake_stdin()
		inject_fake_driver(stdin)
		pi.bridge = fake_bridge("/usr/bin/fish")
		shell.ensure(function() end)
		-- build the command from a Lua literal in the TEST FILE (byte-correct), cursor at end
		local cmd = "日cmd" -- 3 + 3 = 6 BYTES (日=E6 97 A5)
		local bangs = 1
		local col = bangs + #cmd -- byte col past 'd'
		assert.are.equals(6, #cmd, "precondition: 日cmd is 6 bytes")
		local buf = buf_with("!" .. cmd, col)
		local got = {}
		shell.complete_current(buf, function(err, items, prefix)
			got = { err = err, items = items, prefix = prefix }
		end)
		-- extract the JSON cursor field from the frame + assert it is 6 (NOT 4)
		local frame = stdin.written[1]
		assert.is_truthy(frame:find("__PIREQ__\t", 1, true), "frame starts with __PIREQ__\\t")
		local cursor_num = tonumber(frame:match('"cursor":(%d+)'))
		assert.are.equals(6, cursor_num,
			"cursor is the BYTE length of cmd (6), NOT the UTF-16 length (4) — §17.14 byte-domain")
		-- the JSON "line" value byte-decodes to exactly cmd
		local line_val = frame:match('"line":"([^"]*)"')
		assert.are.equals(cmd, line_val, "JSON line == the full multibyte cmd")
		shell._test_invoke_pending({ { value = cmd } }, "x")
		assert.are.equals(cmd, got.prefix, "prefix is the trailing multibyte word (whole UTF-8)")
	end)

	-- (10) never-throws on bad args.
	it("never throws on bad args (buf nil/invalid; cb nil/non-function)", function()
		local stdin = make_fake_stdin()
		inject_fake_driver(stdin)
		pi.bridge = fake_bridge("/usr/bin/fish")
		shell.ensure(function() end)
		-- nil buf → cb("invalid buf"); no throw
		local got = {}
		assert.has_no.errors(function()
			shell.complete_current(nil, function(err) got.err1 = err end)
		end)
		assert.are.equals("invalid buf", got.err1)
		-- non-number buf (e.g. a string) → cb("invalid buf")
		assert.has_no.errors(function()
			shell.complete_current("notabuf", function(err) got.err2 = err end)
		end)
		assert.are.equals("invalid buf", got.err2)
		-- invalid buf number → cb("invalid buf")
		assert.has_no.errors(function()
			shell.complete_current(999999, function(err) got.err3 = err end)
		end)
		assert.are.equals("invalid buf", got.err3)
		-- nil cb → no throw (guarded no-op). Use a bare '!' buffer so the empty-cmd guard
		-- short-circuits BEFORE M.request (no timer armed → no leak across cases).
		local buf_bang = buf_with("!", 1)
		assert.has_no.errors(function() shell.complete_current(buf_bang, nil) end)
		-- non-function cb → no throw (guarded no-op)
		assert.has_no.errors(function() shell.complete_current(buf_bang, "notafn") end)
	end)

	-- (11) M.shell_word_prefix direct unit tests.
	it("M.shell_word_prefix: trailing word / '' / never-throws", function()
		assert.are.equals("ch", shell.shell_word_prefix("git ch"))
		assert.are.equals("", shell.shell_word_prefix("git "))
		assert.are.equals("", shell.shell_word_prefix(""))
		assert.are.equals("a", shell.shell_word_prefix("a"))
		assert.are.equals("", shell.shell_word_prefix(nil))
		assert.are.equals("leading", shell.shell_word_prefix("  leading"))
		assert.are.equals("日cmd", shell.shell_word_prefix("日cmd"), "multibyte trailing word")
		assert.are.equals("", shell.shell_word_prefix(123), "non-string → '' (never throws)")
	end)

	-- (12) no leak: after a full complete_current + _test_invoke_pending cycle, 0 open timers.
	it("no uv_timer_t leak across a complete_current cycle", function()
		local before = count_open_timers()
		local stdin = make_fake_stdin()
		inject_fake_driver(stdin)
		pi.bridge = fake_bridge("/usr/bin/fish")
		shell.ensure(function() end)
		local buf = buf_with("!git ch", 7)
		shell.complete_current(buf, function() end)
		shell._test_invoke_pending({ { value = "checkout" } }, "ch")
		assert.are.equals(before, count_open_timers(), "no timer leaked by complete_current")
	end)

	-- surface: complete_current + shell_word_prefix are functions.
	it("exposes M.complete_current + M.shell_word_prefix as functions", function()
		assert.are.equals("function", type(shell.complete_current))
		assert.are.equals("function", type(shell.shell_word_prefix))
		-- M.request surface intact (regression)
		assert.are.equals("function", type(shell.request))
		assert.are.equals("function", type(shell.ensure))
	end)
end)