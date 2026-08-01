-- === tests/shell_complete_current_smoke.lua — plenary-free Level-1 smoke (P2.M2.T3.S3) ===
-- A file-based end-to-end gate for shell.complete_current(buf, cb): wires a FAKE "fish"
-- daemon (NO subprocess) so the REAL complete_current → REAL M.request → REAL M.ensure
-- resolves "fish" + caches the fake stdin, then asserts the EXACT §17.5.1 wire frame +
-- the cb shape + the empty-command short-circuit. Mirrors tests/shell_request_spec.lua's
-- fake-daemon pattern (fake_bridge / make_fake_stdin / inject_fake_driver) + the
-- completion_spec.lua buffer+cursor setup. NO plenary; prints a parseable verdict.
--
-- ⛔ AGENTS.md HARD RULE: this FILE is run via +"luafile <path>" +qa — NEVER pipe a heredoc
--    into nvim stdin (it hangs the session). Bounded by `timeout`.
--
-- Run (from the repo root):
--   timeout 60 nvim --headless --clean -u NORC +"luafile tests/shell_complete_current_smoke.lua" +qa
local pi = require("pi-bridge")
local shell = require("pi-bridge.shell")

if pi.config == nil then pi.setup({}) end -- self-sufficient (mirror completion_spec.lua L18)

local fails = 0
local function check(c, m)
	if not c then io.stderr:write("FAIL: " .. m .. "\n"); fails = fails + 1 end
end

-- --- a FAKE stdin (luv pipe shape) that captures every written frame. wcb(nil) = OK.
local function make_fake_stdin()
	return {
		written = {},
		write = function(self, data, wcb)
			self.written[#self.written + 1] = data
			if wcb then wcb(nil) end
		end,
		is_closing = function() return false end,
		close = function() end,
		read_stop = function() end,
	}
end

-- --- a FAKE driver whose start(opts, cb) hands the fake stdin/stdout to the REAL M.ensure
-- (so state.stdin becomes the fake — reusing S3's ensure as a bonus).
local function inject_fake_driver(stdin)
	package.loaded["pi-bridge.shell.fish"] = {
		start = function(opts, cb)
			cb(nil,
				{ is_closing = function() return false end }, -- fake proc
				stdin,
				{ read_start = function() end, is_closing = function() return false end, close = function() end })
		end,
	}
end

-- --- a buffer with line 1 + a cursor (byte col); returns (buf, win).
-- virtualedit=onemore is REQUIRED to place the cursor at EOL (col == #line1) — without it
-- nvim clamps col to #line1-1, which would shrink the frame's `cursor` by 1 (the
-- completion_spec.lua:107 pattern).
local function buf_with(line_text, byte_col)
	local buf = vim.api.nvim_create_buf(false, true)
	local win = vim.api.nvim_get_current_win()
	vim.api.nvim_win_set_buf(win, buf)
	vim.wo[win].virtualedit = "onemore" -- allow cursor at EOL
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, { line_text })
	vim.api.nvim_win_set_cursor(win, { 1, byte_col })
	return buf, win
end

-- === (A) "!git ch" (cursor end) → EXACT §17.5.1 frame + client-derived prefix ===
pi.bridge = { get_shell_info = function() return { shell = "/usr/bin/fish" } end, server_info = {} }
local stdin = make_fake_stdin()
inject_fake_driver(stdin)
shell.reset()
local buf, win = buf_with("!git ch", 7)
shell.ensure(function() end) -- cache the fake proc/stdin into state

local got
shell.complete_current(buf, function(err, items, prefix) got = { err = err, items = items, prefix = prefix } end)
check(stdin.written[1] == '__PIREQ__\t{"line":"git ch","cursor":6,"after":""}\n',
	"frame shape (__PIREQ__\\t{line,cursor,after}\\n)")
-- deliver a response (as S5's _feed will in prod) → wrapper_cb → user cb
shell._test_invoke_pending({ { value = "checkout" }, { value = "cherry" } }, "IGNORED_DAEMON_PREFIX")
check(got and got.err == nil, "cb resolves with nil err on success")
check(got and got.prefix == "ch",
	"prefix is CLIENT-derived ('ch'), NOT the daemon's advisory prefix")
check(got and got.items and got.items[1].value == "checkout", "items forwarded from the daemon response")
check(got and got.items and #got.items == 2, "both items forwarded")

-- === (B) bare "!" → empty-command guard: cb(nil, {}, ""); daemon NOT spawned ===
shell.reset()
stdin.written = {}
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "!" })
vim.api.nvim_win_set_cursor(win, { 1, 1 }) -- cursor on the bang (byte col 1)
local got2
shell.complete_current(buf, function(err, items, prefix) got2 = { err = err, items = items, prefix = prefix } end)
check(got2 and got2.err == nil and (got2.items or {})[1] == nil, "bare ! → cb(nil, {}, '') immediate")
check(got2 and got2.prefix == "", "bare ! → prefix '' ")
check(#stdin.written == 0, "bare ! → daemon NOT spawned (0 frames written)")

-- === teardown ===
package.loaded["pi-bridge.shell.fish"] = nil
pi.bridge = nil
shell.reset()

if fails > 0 then
	io.stderr:write(fails .. " smoke check(s) FAILED\n")
	vim.cmd("cquit 1")
end
io.stdout:write("S3_SMOKE_OK\n")