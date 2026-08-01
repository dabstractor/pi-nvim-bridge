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

if fails > 0 then
	io.stderr:write(fails .. " check(s) failed — accept smoke GATE FAILED\n")
	vim.cmd("cquit 1")
end
io.stdout:write("SMOKE_PASS: shell.accept current_shell_word + quote (pure, offline) OK\n")