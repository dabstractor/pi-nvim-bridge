-- === tests/shell_accept_smoke.lua — plenary-FREE, OFFLINE accept smoke (P2.M2.T4.S3) ===
-- The secondary Level-2 gate for `pi-bridge.shell.accept` (the PURE, offline-testable half of
-- PRD §17.8). Drives ~10 representative cases through `current_shell_word` + `quote` and asserts
-- the outputs WITHOUT plenary (the `-u NORC` harness). NOT gated on any shell — the functions
-- are pure Lua, run anywhere (PRD §17.15 "no live shell needed for the quoting table").
-- Prints SMOKE_PASS + exits 0 (or SMOKE_FAIL + stderr + cquit 1).
--
-- The plenary spec (tests/shell_accept_spec.lua) is the exhaustive gate; this smoke is the
-- fast file-based end-to-end load+representative-cases check (proves the module loads under
-- `-u NORC` = pure/dependency-free + the headline contract holds).
--
-- Run from the REPO ROOT:
--   timeout 60 nvim --headless --clean -u NORC -c 'set rtp+=.' +"luafile tests/shell_accept_smoke.lua" +qa
--   echo "exit=$?"   # 0 + SMOKE_PASS = good; 1 + SMOKE_FAIL = bad
--
-- AGENTS.md HARD RULE: this IS a file on disk — run via :luafile. NEVER heredoc-to-nvim-stdin.
local accept = require("pi-bridge.shell.accept")

local fails = 0
local function check(cond, msg)
	if not cond then
		io.stderr:write("FAIL: " .. msg .. "\n")
		fails = fails + 1
	end
end

-- (1) surface: both pure functions are exported.
check(type(accept.current_shell_word) == "function", "current_shell_word is not a function")
check(type(accept.quote) == "function", "quote is not a function")

-- (2) current_shell_word — plain word + byte offset.
do
	local w, s = accept.current_shell_word("git ch", 6)
	check(w == "ch" and s == 4, "git ch@6 → (ch,4); got (" .. tostring(w) .. "," .. tostring(s) .. ")")
end

-- (3) current_shell_word — trailing space → empty word.
do
	local w, s = accept.current_shell_word("git ", 4)
	check(w == "" and s == 4, "git @4 → ('',4); got (" .. tostring(w) .. "," .. tostring(s) .. ")")
end

-- (4) current_shell_word — quote-aware (open double-quote keeps the word together).
do
	local w, s = accept.current_shell_word('echo "hello', 11)
	check(w == '"hello' and s == 5, 'echo "hello@11 → ("hello,5); got (' .. tostring(w) .. "," .. tostring(s) .. ")")
end

-- (5) current_shell_word — escaped space non-breaking.
do
	local w, s = accept.current_shell_word("echo a\\ b", 9)
	check(w == "a\\ b" and s == 5, "echo a\\ b@9 → (a\\ b,5); got (" .. tostring(w) .. "," .. tostring(s) .. ")")
end

-- (6) current_shell_word — UTF-8 byte correctness (multibyte trailing word returned whole).
do
	local w, s = accept.current_shell_word("日cmd", 6)
	check(w == "日cmd" and s == 0, "日cmd@6 → (日cmd,0); got (" .. tostring(w) .. "," .. tostring(s) .. ")")
end

-- (7) quote — unchanged (no special char).
check(accept.quote("checkout", "bash") == "checkout", "bash checkout unchanged")
check(accept.quote("checkout", "fish") == "checkout", "fish checkout unchanged")

-- (8) quote — spaces (bash single-quote; fish double-quote).
check(accept.quote("my file.txt", "bash") == "'my file.txt'", "bash 'my file.txt' → single-quote")
check(accept.quote("my file.txt", "fish") == '"my file.txt"', "fish 'my file.txt' → double-quote")

-- (9) quote — the embedded-' idiom (bash) + the lighter fish rule.
check(accept.quote("a'b", "bash") == "'a'\"'\"'b'", "bash a'b → the idiom")
check(accept.quote("a$b", "fish") == "a$b", "fish a$b unchanged (lighter rule — no space)")

-- (10) quote — the bash single-quote NEUTRALIZES " (literal inside; NOT escaped).
check(accept.quote('a"b', "bash") == "'a\"b'", 'bash a"b → " is literal inside single quotes')

-- (11) quote — fish double-quote escapes \ and " inside (on a space).
check(accept.quote('a "b c', "fish") == '"a \\"b c"', "fish 'a \"b c' → escape \\ and \" inside dquote")

-- (12) quote — shell accepts PATH or basename; unknown → POSIX default.
check(accept.quote("my file.txt", "/bin/zsh") == accept.quote("my file.txt", "zsh"), "PATH == basename (zsh)")
check(accept.quote("my file.txt", "nu") == "'my file.txt'", "unknown basename 'nu' → POSIX default")

-- (13) never-throws discipline.
check(pcall(accept.quote, nil, "bash") ~= nil and accept.quote(nil, "bash") == "", "quote(nil) → '' no throw")
check(pcall(accept.current_shell_word, nil, 3) ~= nil, "current_shell_word(nil) no throw")
do
	local w, s = accept.current_shell_word(nil, 3)
	check(w == "" and s == 0, "current_shell_word(nil,3) → ('',0)")
end

-- ============================================================================
-- S4 buffer-mutation section (M.apply — PRD §17.8 step 3-5).
-- headless nvim under -u NORC HAS vim.api (coords_smoke/menu_smoke create buffers under NORC).
-- M.apply lazy-requires shell.get_shell / menu.close / completion.refresh INSIDE the fn →
-- stub them via package.loaded so no daemon/bridge is needed (the pure quote/word fns +
-- nvim_buf_set_text are the whole path). virtualedit=onemore is REQUIRED for cursor-at-EOL.
-- ============================================================================

-- (14) surface: M.apply + shell.get_shell are functions.
check(type(accept.apply) == "function", "M.apply is not a function")
check(type(require("pi-bridge.shell").get_shell) == "function", "shell.get_shell is not a function")

-- stub the 3 lazy-required modules (save originals so the pure smoke's module load is intact).
local saved_shell_mod = package.loaded["pi-bridge.shell"]
local saved_menu_mod = package.loaded["pi-bridge.menu"]
local saved_completion_mod = package.loaded["pi-bridge.completion"]
package.loaded["pi-bridge.shell"] = {
	get_shell = function()
		return "bash"
	end,
	reset = function() end,
}
package.loaded["pi-bridge.menu"] = { close = function() end }
local smoke_refreshed = false
package.loaded["pi-bridge.completion"] = {
	refresh = function()
		smoke_refreshed = true
	end,
}

-- a buffer with line 1 + a cursor (byte col); virtualedit=onemore for EOL placement.
local function apply_buf_with(line_text, byte_col)
	local buf = vim.api.nvim_create_buf(false, true)
	local win = vim.api.nvim_get_current_win()
	vim.api.nvim_win_set_buf(win, buf)
	vim.wo[win].virtualedit = "onemore"
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, { line_text })
	vim.api.nvim_win_set_cursor(win, { 1, byte_col })
	return buf
end

-- (15) plain word: "!git ch" cursor end accept "checkout" → "!git checkout" + cursor after.
do
	local buf = apply_buf_with("!git ch", 7)
	local r = accept.apply(buf, { value = "checkout" })
	local got = vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1]
	local col = vim.api.nvim_win_get_cursor(0)[2]
	check(r == true, "apply returned true (plain word)")
	check(got == "!git checkout", "plain word buffer = " .. tostring(got))
	check(col == 13, "plain word cursor col = " .. tostring(col) .. " (expected 13)")
	pcall(vim.api.nvim_buf_delete, buf, { force = true })
end

-- (16) bash quote (space): "!cd my" accept "my file.txt" → "!cd 'my file.txt'".
do
	local buf = apply_buf_with("!cd my", 6)
	local r = accept.apply(buf, { value = "my file.txt" })
	local got = vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1]
	check(r == true, "apply returned true (bash quote)")
	check(got == "!cd 'my file.txt'", "bash quote buffer = " .. tostring(got))
	pcall(vim.api.nvim_buf_delete, buf, { force = true })
end

-- (17) directory re-trigger: "!cd /tm" accept "/tmp/" → "!cd /tmp/" + completion.refresh called.
smoke_refreshed = false
do
	local buf = apply_buf_with("!cd /tm", 7)
	local r = accept.apply(buf, { value = "/tmp/" })
	local got = vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1]
	check(r == true, "apply returned true (dir)")
	check(got == "!cd /tmp/", "dir buffer = " .. tostring(got))
	check(smoke_refreshed == true, "completion.refresh called for the directory value")
	pcall(vim.api.nvim_buf_delete, buf, { force = true })
end

-- restore the stubbed modules (so any later require sees the real ones).
package.loaded["pi-bridge.shell"] = saved_shell_mod
package.loaded["pi-bridge.menu"] = saved_menu_mod
package.loaded["pi-bridge.completion"] = saved_completion_mod

if fails > 0 then
	io.stderr:write(fails .. " check(s) failed — accept smoke GATE FAILED\n")
	vim.cmd("cquit 1")
end
io.stdout:write("SMOKE_PASS: shell.accept current_shell_word + quote + M.apply (pure+buffer) OK\n")
