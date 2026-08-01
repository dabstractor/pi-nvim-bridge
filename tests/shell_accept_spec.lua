-- === tests/shell_accept_spec.lua — plenary/busted OFFLINE quoting/word spec (P2.M2.T4.S3) ===
-- The primary Level-2 gate for `pi-bridge.shell.accept` — the PURE, offline-testable half of
-- PRD §17.8 (Local acceptance & quoting). Covers:
--   * `current_shell_word` (§17.8 step 1): the quote-aware current-word computation — plain
--     words, leading/multiple whitespace, empty command, cursor-on-whitespace (empty word),
--     single/double-quoted regions (whitespace inside is non-breaking), backslash-escaped
--     spaces, multibyte trailing words (UTF-8 BYTE correctness), never-throws + cursor clamp.
--   * `quote` (§17.8 step 2 / §17.15 quoting table): unchanged when no special char; `"…"` for
--     fish on a space; `'…'` for bash/zsh on any POSIX special; the `'…'"'"'…'` idiom for an
--     embedded `'`; `"`/`$`/`\`/backtick LEFT UNTOUCHED inside bash single quotes; fish's
--     lighter (space-only) rule; shell accepts PATH or basename; unknown → POSIX default;
--     never-throws.
--
-- OFFLINE: NO live `fish`/`bash`, NO socket, NO daemon, NO nvim API. The two functions are
-- pure + dependency-free → this spec runs anywhere plenary runs (PRD §17.15 "no live shell
-- needed for the quoting table"). The S4 buffer-mutation cases (nvim_buf_set_text range +
-- cursor) will be ADDED to this SAME file by P2.M2.T4.S4; S3 owns the pure half.
--
-- Run (from the repo root):
--   timeout 90 nvim --headless --clean -u tests/minimal_init.lua \
--     -c 'lua require("plenary.busted").run("tests/shell_accept_spec.lua")'
local accept = require("pi-bridge.shell.accept")
local shell = require("pi-bridge.shell")

describe("pi-bridge.shell.accept (§17.8 / §17.15)", function()
	-- surface: both pure functions are exported
	it("exports current_shell_word + quote as functions", function()
		assert.are.equals("function", type(accept.current_shell_word))
		assert.are.equals("function", type(accept.quote))
	end)

	-- ────────────────────────────────────────────────────────────────────────
	-- current_shell_word (§17.8 step 1 — the quote-aware current-word computation)
	-- ────────────────────────────────────────────────────────────────────────
	describe("current_shell_word (§17.8 step 1)", function()
		-- ── plain words ──
		it("'git ch' cursor@6 → ('ch', 4)", function()
			local w, s = accept.current_shell_word("git ch", 6)
			assert.are.equals("ch", w)
			assert.are.equals(4, s)
		end)

		it("'checkout' cursor@8 → ('checkout', 0)", function()
			local w, s = accept.current_shell_word("checkout", 8)
			assert.are.equals("checkout", w)
			assert.are.equals(0, s)
		end)

		it("'cd /tmp/foo' cursor@11 → ('/tmp/foo', 3)", function()
			local w, s = accept.current_shell_word("cd /tmp/foo", 11)
			assert.are.equals("/tmp/foo", w)
			assert.are.equals(3, s)
		end)

		-- ── whitespace boundaries ──
		it("'git ' trailing-space cursor@4 → ('', 4) (empty word)", function()
			local w, s = accept.current_shell_word("git ", 4)
			assert.are.equals("", w)
			assert.are.equals(4, s)
		end)

		it("'git  ch' (2 spaces) cursor@7 → ('ch', 5)", function()
			-- bytes: g(1) i(2) t(3) SP(4) SP(5) c(6) h(7); word starts at byte 6 → start_byte=5
			local w, s = accept.current_shell_word("git  ch", 7)
			assert.are.equals("ch", w)
			assert.are.equals(5, s)
		end)

		it("'   leading spaces' cursor@16 → ('spaces', 11)", function()
			-- "   leading spaces": 3 spaces + "leading"(7) + SP + "spaces"(6) = 3+7+1+6 = 17 chars
			-- word "spaces" starts at byte 12 (1-indexed) → start_byte=11
			local w, s = accept.current_shell_word("   leading spaces", 17)
			assert.are.equals("spaces", w)
			assert.are.equals(11, s)
		end)

		it("'' empty command → ('', 0)", function()
			local w, s = accept.current_shell_word("", 0)
			assert.are.equals("", w)
			assert.are.equals(0, s)
		end)

		-- ── quote-aware (the §17.8 contract) ──
		it('echo "hello (open dquote) cursor@11 → ("hello, 5)', function()
			-- the opening `"` is PART of the word; whitespace inside the (open) double quote is
			-- non-breaking. bytes: e c h o SP " h e l l o = 11; word_start advances past byte 5
			-- (the space) then `"` at byte 6 opens double → word = bytes 6..11 = '"hello'.
			local w, s = accept.current_shell_word('echo "hello', 11)
			assert.are.equals('"hello', w)
			assert.are.equals(5, s)
		end)

		it("echo 'a b' (single-quoted space) cursor@10 → ('a b', 5)", function()
			-- bytes: e c h o SP ' a SP b ' = 10; `'` at byte 6 opens single-quote (space at byte 8
			-- is non-breaking); `'` at byte 10 closes. word = bytes 6..10 = "'a b'".
			local w, s = accept.current_shell_word("echo 'a b'", 10)
			assert.are.equals("'a b'", w)
			assert.are.equals(5, s)
		end)

		it("echo a\\ b (escaped space) cursor@9 → (a\\ b, 5)", function()
			-- bytes: e c h o SP a \ SP b = 9; `\` at byte 7 escapes the space at byte 8 → the space
			-- is non-breaking (part of the word). word = bytes 6..9 = "a\ b".
			local w, s = accept.current_shell_word("echo a\\ b", 9)
			assert.are.equals("a\\ b", w)
			assert.are.equals(5, s)
		end)

		it('double-quote \\-escape: echo "a\\ b (escaped space inside dquote) → non-breaking', function()
			-- inside double quotes, `\` escapes the next byte, so `\ ` is non-breaking.
			-- bytes: e c h o SP " a \ SP b = 10; word = bytes 6..10 = '"a\ b'.
			local w, s = accept.current_shell_word('echo "a\\ b', 10)
			assert.are.equals('"a\\ b', w)
			assert.are.equals(5, s)
		end)

		-- ── BYTE correctness (UTF-8) — §17.14 ──
		it("'日cmd' (3-byte 日 + cmd) cursor@6 → ('日cmd', 0) (multibyte whole)", function()
			-- 日 is 3 UTF-8 bytes (0xE6 0x97 0xA5); continuation bytes >=0x80 never match
			-- whitespace/squote/dquote/backslash → the trailing word is returned WHOLE + the
			-- start_byte reflects BYTE length (0), not codepoint/UTF-16.
			local w, s = accept.current_shell_word("日cmd", 6)
			assert.are.equals("日cmd", w)
			assert.are.equals(0, s)
		end)

		it("'cd 日/cmd' cursor@10 → ('日/cmd', 3) (multibyte mid-line, byte offset)", function()
			-- "cd 日/cmd": c d SP 日(3 bytes) / c m d = 2+1+3+1+3 = 10 bytes. word "日/cmd" starts
			-- at byte 4 (1-indexed) → start_byte=3.
			local w, s = accept.current_shell_word("cd 日/cmd", 10)
			assert.are.equals("日/cmd", w)
			assert.are.equals(3, s)
		end)

		-- ── never-throws + cursor clamp ──
		it("non-string line (nil/number/table) → ('', 0) without throwing", function()
			assert.has_no.errors(function()
				accept.current_shell_word(nil, 3)
				accept.current_shell_word(123, 3)
				accept.current_shell_word({}, 3)
			end)
			assert.are.equals("", (accept.current_shell_word(nil, 3)))
			assert.are.equals(0, (select(2, accept.current_shell_word(nil, 3))))
		end)

		it("negative cursor clamps to 0 → ('', 0) (a 0 cursor = empty range → empty word)", function()
			-- clamp: max(0, min(#line, -5)) = 0. The loop runs for i=1..0 → zero iterations →
			-- word_start stays 1, and line:sub(1,0) = "" (a 0 cursor means nothing selected yet).
			local w, s = accept.current_shell_word("abc", -5)
			assert.are.equals("", w)
			assert.are.equals(0, s)
		end)

		it("oversize cursor clamps to #line → ('abc', 0) (word begins at byte 0)", function()
			-- clamp: min(3, 999) = 3. Loop scans bytes 1..3 (no whitespace) → word_start stays 1.
			-- word = line:sub(1,3) = "abc"; start_byte = word_start-1 = 0 (the WORD begins at byte 0).
			-- The second return is start_byte (where the word BEGINS), NOT the cursor end.
			local w, s = accept.current_shell_word("abc", 999)
			assert.are.equals("abc", w)
			assert.are.equals(0, s)
		end)

		it("non-numeric cursor defaults to #line", function()
			-- "git ch" with cursor=nil → defaults to #line (6) → ("ch", 4)
			local w, s = accept.current_shell_word("git ch", nil)
			assert.are.equals("ch", w)
			assert.are.equals(4, s)
		end)
	end)

	-- ────────────────────────────────────────────────────────────────────────
	-- quote per-shell (§17.8 step 2 / §17.15 quoting table)
	-- ────────────────────────────────────────────────────────────────────────
	describe("quote per-shell (§17.8 step 2 / §17.15 table)", function()
		-- ── unchanged (no special char) ──
		it("bash: 'checkout' unchanged", function()
			assert.are.equals("checkout", accept.quote("checkout", "bash"))
		end)

		it("fish: 'checkout' unchanged", function()
			assert.are.equals("checkout", accept.quote("checkout", "fish"))
		end)

		it("bash: 'a/b/c' (slashes only) unchanged", function()
			assert.are.equals("a/b/c", accept.quote("a/b/c", "bash"))
		end)

		-- ── spaces ──
		it("bash: 'my file.txt' → \"'my file.txt'\"", function()
			assert.are.equals("'my file.txt'", accept.quote("my file.txt", "bash"))
		end)

		it("fish: 'my file.txt' → '\"my file.txt\"'", function()
			-- fish lighter rule: double-quote on a space (no escaping needed here).
			assert.are.equals('"my file.txt"', accept.quote("my file.txt", "fish"))
		end)

		-- ── POSIX specials (bash TRIGGERS; fish does NOT — lighter rule) ──
		it("bash: 'a$b' → \"'a$b'\"", function()
			assert.are.equals("'a$b'", accept.quote("a$b", "bash"))
		end)

		it("fish: 'a$b' unchanged (no space — the lighter rule)", function()
			assert.are.equals("a$b", accept.quote("a$b", "fish"))
		end)

		it("bash: 'a;b' → \"'a;b'\"", function()
			assert.are.equals("'a;b'", accept.quote("a;b", "bash"))
		end)

		it("bash: 'a|b' → \"'a|b'\"", function()
			assert.are.equals("'a|b'", accept.quote("a|b", "bash"))
		end)

		it("bash: 'a~b' → \"'a~b'\"", function()
			assert.are.equals("'a~b'", accept.quote("a~b", "bash"))
		end)

		it("bash: 'a&b' → \"'a&b'\"", function()
			assert.are.equals("'a&b'", accept.quote("a&b", "bash"))
		end)

		it("bash: 'a(b)c' → \"'a(b)c'\"", function()
			assert.are.equals("'a(b)c'", accept.quote("a(b)c", "bash"))
		end)

		it("bash: 'a<b>c' → \"'a<b>c'\"", function()
			assert.are.equals("'a<b>c'", accept.quote("a<b>c", "bash"))
		end)

		it("bash: 'a`b' (backtick) → \"'a`b'\"  (backtick is literal inside single quotes)", function()
			assert.are.equals("'a`b'", accept.quote("a`b", "bash"))
		end)

		it("bash: 'a\\b' (backslash) → \"'a\\b'\"  (backslash is literal inside single quotes)", function()
			assert.are.equals("'a\\b'", accept.quote("a\\b", "bash"))
		end)

		-- ── embedded single quote (the idiom) + double-quote-inside-single (neutralized) ──
		it("bash: \"a'b\" → \"'a'\\\"'\\\"'b'\"  (the gsub-then-wrap idiom)", function()
			-- 'a'"'"'b' = 'a' + "'" + 'b' = a'b  ✓ (LIVE-VERIFIED, research §3)
			assert.are.equals("'a'\"'\"'b'", accept.quote("a'b", "bash"))
		end)

		it('bash: \'a"b\' → "\'a"b\'"  (" is LITERAL inside single quotes; NOT escaped)', function()
			-- single quotes are OPAQUE: the " is neutralized for free — DO NOT escape it.
			assert.are.equals("'a\"b'", accept.quote('a"b', "bash"))
		end)

		it("bash: 'a$b`c\"d' (combined specials) → single-quote, only ' needs the idiom", function()
			-- no ' in the word → just wrap. $ ` " are literal inside single quotes.
			assert.are.equals("'a$b`c\"d'", accept.quote('a$b`c"d', "bash"))
		end)

		it("bash: \"a'b'c\" (multiple embedded ') → idiom applied per '", function()
			-- a'b'c → 'a'"'"'b'"'"'c  = 'a' + "'" + 'b' + "'" + 'c = a'b'c  ✓
			assert.are.equals("'a'\"'\"'b'\"'\"'c'", accept.quote("a'b'c", "bash"))
		end)

		-- ── fish double-quote escaping (escape \ and " inside) ──
		it('fish: \'a "b c\' (space) → "\\"a \\\\\\"b c\\""  (escape \\ and " inside)', function()
			-- word has a space → double-quote; escape `\` FIRST then `"`: 'a "b c' → '"a \"b c'
			-- (the leading \ is escaped to \\, the " is escaped to \").
			assert.are.equals('"a \\"b c"', accept.quote('a "b c', "fish"))
		end)

		it("fish: 'a\\b c' (backslash + space) → escape \\ inside the double quotes", function()
			-- backslash escaped FIRST (\\), then the space triggers the double-quote.
			assert.are.equals('"a\\\\b c"', accept.quote("a\\b c", "fish"))
		end)

		it("fish: 'a\"b' (a \" + NO space) → unchanged (fish rule is space-only)", function()
			assert.are.equals('a"b', accept.quote('a"b', "fish"))
		end)

		it("fish: 'a\\b' (backslash + NO space) → unchanged", function()
			assert.are.equals("a\\b", accept.quote("a\\b", "fish"))
		end)

		-- ── shell accepts PATH or basename ──
		it("quote(word,'/bin/zsh') == quote(word,'zsh') (PATH or basename)", function()
			assert.are.equals(accept.quote("my file.txt", "/bin/zsh"), accept.quote("my file.txt", "zsh"))
			assert.are.equals(accept.quote("a'b", "/usr/bin/bash"), accept.quote("a'b", "bash"))
		end)

		it("fish PATH '/usr/bin/fish' == basename 'fish'", function()
			assert.are.equals(accept.quote("my file.txt", "/usr/bin/fish"), accept.quote("my file.txt", "fish"))
		end)

		it("unknown basename ('nu'/'elvish') → bash/zsh single-quote default", function()
			assert.are.equals("'my file.txt'", accept.quote("my file.txt", "nu"))
			assert.are.equals("'a'\"'\"'b'", accept.quote("a'b", "elvish"))
		end)

		-- ── never-throws ──
		it("quote(nil, 'bash') → '' without throwing", function()
			assert.has_no.errors(function()
				accept.quote(nil, "bash")
			end)
			assert.are.equals("", accept.quote(nil, "bash"))
		end)

		it("quote(123, 'bash') → '' (non-string word)", function()
			assert.are.equals("", accept.quote(123, "bash"))
		end)

		it("quote(word, nil) → POSIX default (no throw)", function()
			assert.has_no.errors(function()
				accept.quote("my file.txt", nil)
			end)
			assert.are.equals("'my file.txt'", accept.quote("my file.txt", nil))
		end)
	end)

	-- ────────────────────────────────────────────────────────────────────────
	-- M.apply (§17.8 step 3-5 — the IMPURE buffer-mutation consumer)
	-- ────────────────────────────────────────────────────────────────────────
	describe("M.apply (§17.8 step 3-5 — buffer mutation)", function()
		local saved_shell, saved_menu, saved_completion
		local fake_shell, fake_menu, fake_completion
		-- stub the 3 modules M.apply lazy-requires (so get_shell returns a controlled
		-- shell + we can spy on menu.close / completion.refresh). Save originals for restore.
		local function stub_deps(shell_str, refresh_spy)
			saved_shell = package.loaded["pi-bridge.shell"]
			saved_menu = package.loaded["pi-bridge.menu"]
			saved_completion = package.loaded["pi-bridge.completion"]
			fake_shell = {
				get_shell = function()
					return shell_str
				end,
				reset = function() end,
			}
			fake_menu = { close = function() end }
			fake_completion = { refresh = refresh_spy or function() end }
			package.loaded["pi-bridge.shell"] = fake_shell
			package.loaded["pi-bridge.menu"] = fake_menu
			package.loaded["pi-bridge.completion"] = fake_completion
		end
		local function restore_deps()
			package.loaded["pi-bridge.shell"] = saved_shell
			package.loaded["pi-bridge.menu"] = saved_menu
			package.loaded["pi-bridge.completion"] = saved_completion
		end

		-- the buf_with helper (copied from shell_complete_current_spec L86-93): scratch buf +
		-- virtualedit=onemore (REQUIRED to place the cursor at EOL — else nvim clamps col to
		-- #line1-1, shifting every byte-math assertion by 1).
		local function buf_with(line_text, byte_col)
			local buf = vim.api.nvim_create_buf(false, true)
			local win = vim.api.nvim_get_current_win()
			vim.api.nvim_win_set_buf(win, buf)
			vim.wo[win].virtualedit = "onemore"
			vim.api.nvim_buf_set_lines(buf, 0, -1, false, { line_text })
			vim.api.nvim_win_set_cursor(win, { 1, byte_col })
			return buf, win
		end
		local function close_buf(buf)
			pcall(vim.api.nvim_buf_delete, buf, { force = true })
		end

		before_each(function()
			shell.reset()
		end)
		after_each(function()
			restore_deps()
			shell.reset()
		end)

		-- ── surface: M.apply + shell.get_shell are functions ──
		it("exports M.apply as a function; shell.get_shell is a function", function()
			assert.are.equals("function", type(accept.apply))
			assert.are.equals("function", type(shell.get_shell))
		end)

		-- ── plain word: "!git ch" cursor end accept "checkout" ──
		it("'!git ch' (cursor end) accept 'checkout' → '!git checkout' + cursor after", function()
			stub_deps("bash")
			local buf = buf_with("!git ch", 7) -- #line1=7; onemore → col 7 (past 'h')
			local r = accept.apply(buf, { value = "checkout" })
			local got = vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1]
			local col = vim.api.nvim_win_get_cursor(0)[2]
			assert.is_true(r)
			assert.are.equals("!git checkout", got) -- splice verbatim; shell adds NO trailing space
			-- cmd="git ch"; word="ch" start_byte=4; buf_start=5,buf_end=7 → splice "checkout" at
			-- buf byte 5 → "!git checkout" (no trailing space; the space before 'ch' is preserved).
			-- cursor = buf_start(5) + #quoted(8) = 13.
			assert.are.equals(13, col)
			close_buf(buf)
		end)

		-- ── trailing-space empty word: "!git " accept "git" ──
		it("'!git ' (cursor end) accept 'git' → '!git git' + cursor after", function()
			stub_deps("bash")
			local buf = buf_with("!git ", 5)
			local r = accept.apply(buf, { value = "git" })
			local got = vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1]
			local col = vim.api.nvim_win_get_cursor(0)[2]
			assert.is_true(r)
			-- cmd="git "; word=""(empty, trailing space) start_byte=4; buf_start=5,buf_end=5 → splice
			-- "git" at byte 5 → "!git git" (8 bytes); cursor=5+3=8.
			assert.are.equals("!git git", got)
			assert.are.equals(8, col)
			close_buf(buf)
		end)

		-- ── bash quote (space): "!cd my" accept "my file.txt" ──
		it("'!cd my' accept 'my file.txt' (bash) → \"!cd 'my file.txt'\"", function()
			stub_deps("bash")
			local buf = buf_with("!cd my", 6)
			local r = accept.apply(buf, { value = "my file.txt" })
			local got = vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1]
			local col = vim.api.nvim_win_get_cursor(0)[2]
			assert.is_true(r)
			-- cmd="cd my"; word="my" start_byte=3; quoted="'my file.txt'"(13) → buf_start=4;
			-- splice bytes [4..6) → "!cd 'my file.txt'"; cursor=4+13=17.
			assert.are.equals("!cd 'my file.txt'", got)
			assert.are.equals(17, col)
			close_buf(buf)
		end)

		-- ── fish quote (space): double-quote ──
		it("'!cd my' accept 'my file.txt' (fish) → \"!cd \"my file.txt\"\"", function()
			stub_deps("fish")
			local buf = buf_with("!cd my", 6)
			local r = accept.apply(buf, { value = "my file.txt" })
			local got = vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1]
			local col = vim.api.nvim_win_get_cursor(0)[2]
			assert.is_true(r)
			-- quoted='"my file.txt"'(13) → "!cd \"my file.txt\""; cursor=4+13=17.
			assert.are.equals('!cd "my file.txt"', got)
			assert.are.equals(17, col)
			close_buf(buf)
		end)

		-- ── directory re-trigger: "!cd /tm" accept "/tmp/" + refresh called ──
		it("'!cd /tm' accept '/tmp/' → '!cd /tmp/' + completion.refresh called (dir re-trigger)", function()
			local refreshed = false
			local refresh_arg
			stub_deps("bash", function(b)
				refreshed = true
				refresh_arg = b
			end)
			local buf = buf_with("!cd /tm", 7)
			local r = accept.apply(buf, { value = "/tmp/" })
			local got = vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1]
			local col = vim.api.nvim_win_get_cursor(0)[2]
			assert.is_true(r)
			-- cmd="cd /tm"; word="/tm" start_byte=3; quoted="/tmp/"(5, no special) → buf_start=4;
			-- splice bytes [4..7) → "!cd /tmp/"; cursor=4+5=9.
			assert.are.equals("!cd /tmp/", got)
			assert.are.equals(9, col)
			assert.is_true(refreshed, "completion.refresh called for a directory value")
			assert.are.equals(buf, refresh_arg, "refresh called with the buf")
			close_buf(buf)
		end)

		-- ── NOT a directory → refresh NOT called ──
		it("non-dir value does NOT call completion.refresh", function()
			local refreshed = false
			stub_deps("bash", function()
				refreshed = true
			end)
			local buf = buf_with("!git ch", 7)
			accept.apply(buf, { value = "checkout" })
			assert.is_false(refreshed, "refresh NOT called for a non-dir value")
			close_buf(buf)
		end)

		-- ── embedded-quote idiom (bash) ──
		it("accept 'a\\'b' (bash) → splices the '…\"'\"'…' idiom", function()
			stub_deps("bash")
			local buf = buf_with("!git add a", 10) -- cmd "git add a", word "a" start_byte=8
			local r = accept.apply(buf, { value = "a'b" })
			local got = vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1]
			-- quoted = "'a'\"'\"'b'" (7 bytes); buf_start=9; splice byte 9 → "!git add 'a'\"'\"'b'"
			assert.is_true(r)
			-- expected buffer: "!git add " + 'a'"'"'b'  (the bash idiom for a'b)
			local expected = "!git add " .. "'a'\"'\"'b'"
			assert.are.equals(expected, got)
			close_buf(buf)
		end)

		-- ── cursor mid-word: "!git check" cursor@6 (on 'c') accept "checkout" ──
		it("'!git check' cursor@6 accept 'checkout' → replaces the cursor byte only; 'heck' preserved", function()
			stub_deps("bash")
			-- "!git check": !(1)g i t SP(5) c(6) h(7) e c k; cursor@6 (on 'c' of 'check').
			-- cmd="git check"; cmd_cursor=6-1=5; current_shell_word("git check",5): the space at
			-- cmd byte 4 advances word_start to 5, so word = cmd:sub(5,5) = "c" (only the byte at
			-- the cursor), start_byte=4. buf_start=5, buf_end=6 → replaces the single 'c' with
			-- "checkout"; the "heck" after is preserved.
			local buf = buf_with("!git check", 6)
			local r = accept.apply(buf, { value = "checkout" })
			local got = vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1]
			local col = vim.api.nvim_win_get_cursor(0)[2]
			assert.is_true(r)
			-- byte 5..6 (the single 'c') replaced with "checkout" → "!git checkoutheck"
			assert.are.equals("!git checkout" .. "heck", got)
			-- cursor = buf_start(5) + #quoted(8) = 13 (between 'checkout' and 'heck').
			assert.are.equals(13, col)
			close_buf(buf)
		end)

		-- ── multibyte byte-correct: "!日cmd" ──
		it("'!日cmd' (3-byte 日) accept → byte offsets on char boundaries", function()
			stub_deps("bash")
			-- "!日cmd" = !(1) + 日(3 bytes: 2,3,4) + c(5) m(6) d(7) = 7 bytes; cursor@7 (end).
			-- cmd="日cmd"(6 bytes); cmd_cursor=6; current_shell_word("日cmd",6) → ("日cmd",0)
			-- (continuation bytes never match whitespace). buf_start=1, buf_end=7.
			local buf = buf_with("!日cmd", 7)
			local r = accept.apply(buf, { value = "日result" }) -- 日result = 3+6 = 9 bytes
			local got = vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1]
			local col = vim.api.nvim_win_get_cursor(0)[2]
			assert.is_true(r)
			assert.are.equals("!日result", got) -- the whole "日cmd" replaced with "日result"
			-- cursor = buf_start(1) + #quoted(9) = 10 (after 日result; on a char boundary).
			assert.are.equals(10, col)
			close_buf(buf)
		end)

		-- ── never-throws + returns false ──
		it("never-throws + false: apply(nil,item), apply(buf,nil), invalid buf, non-current buf", function()
			stub_deps("bash")
			local good = buf_with("!git ch", 7)
			-- nil buf
			assert.is_false(accept.apply(nil, { value = "x" }))
			-- nil item / non-table item / item without string value
			assert.is_false(accept.apply(good, nil))
			assert.is_false(accept.apply(good, {}))
			assert.is_false(accept.apply(good, { value = 123 }))
			-- invalid buf (a wiped/fake number)
			assert.is_false(accept.apply(999999, { value = "x" }))
			-- non-current buf: create a buf but DO NOT set it current
			local other = vim.api.nvim_create_buf(false, true)
			vim.api.nvim_buf_set_lines(other, 0, -1, false, { "!git ch" })
			assert.is_false(accept.apply(other, { value = "x" }))
			close_buf(good)
			close_buf(other)
		end)

		-- ── routing: completion.M.accept on a '!' line delegates to accept.apply ──
		it("routing: M.accept(item) on a '!' line → accept.apply called (NOT the bridge)", function()
			-- stub accept.apply to record the call + return true; stub the bridge to a sentinel
			-- that would throw if the pi path ran. Verify the shell branch short-circuits.
			local called = false
			local apply_arg_item
			local real_accept = package.loaded["pi-bridge.shell.accept"]
			package.loaded["pi-bridge.shell.accept"] = setmetatable({
				apply = function(b, it)
					called = true
					apply_arg_item = it
					return true
				end,
			}, { __index = real_accept })
			-- poison the bridge: if the pi path runs, is_connected throws → test fails.
			local saved_pi_bridge = require("pi-bridge").bridge
			require("pi-bridge").bridge = {
				is_connected = function()
					error("pi path must NOT run for a ! line")
				end,
			}
			local buf = buf_with("!git ch", 7)
			local completion = require("pi-bridge.completion")
			local r = completion.accept({ value = "checkout" })
			assert.is_true(called, "accept.apply was called for a ! line")
			assert.is_true(r, "M.accept returned accept.apply's true")
			assert.are.equals("checkout", apply_arg_item.value)
			-- restore
			package.loaded["pi-bridge.shell.accept"] = real_accept
			require("pi-bridge").bridge = saved_pi_bridge
			close_buf(buf)
		end)

		-- ── routing regression: a '/model ' line runs the pi path (returns false w/o bridge) ──
		it("routing: '/model ' line does NOT route to accept.apply (pi path; no bridge → false)", function()
			-- With no bridge connected, M.accept returns false for a non-'!' line WITHOUT calling
			-- accept.apply (proves the shell branch is gated on '!').
			local called = false
			local real_accept = package.loaded["pi-bridge.shell.accept"]
			package.loaded["pi-bridge.shell.accept"] = setmetatable({
				apply = function()
					called = true
					return true
				end,
			}, { __index = real_accept })
			local saved_pi_bridge = require("pi-bridge").bridge
			require("pi-bridge").bridge = nil -- no bridge → pi path returns false
			local buf = buf_with("/model foo", 10)
			local completion = require("pi-bridge.completion")
			local r = completion.accept({ value = "bar" })
			assert.is_false(called, "accept.apply NOT called for a non-'!' line")
			assert.is_false(r, "M.accept returns false (no bridge, pi path)")
			package.loaded["pi-bridge.shell.accept"] = real_accept
			require("pi-bridge").bridge = saved_pi_bridge
			close_buf(buf)
		end)

		-- ── no-leak: no uv_timer_t left open after apply ──
		it("does not leak a uv_timer_t (the directory re-trigger is 0 ms defer_fn)", function()
			-- the refresh spy is a no-op (stubbed) → no real defer_fn is scheduled by this path;
			-- this is a sanity check that apply itself schedules nothing.
			local uv = vim.loop or vim.uv
			local function count_open_timers()
				local n = 0
				uv.walk(function(h)
					if
						type(h) == "userdata"
						and type(h.start) == "function"
						and type(h.stop) == "function"
						and type(h.send) ~= "function"
						and type(h.read_start) ~= "function"
						and not h:is_closing()
					then
						n = n + 1
					end
				end)
				return n
			end
			local before = count_open_timers()
			stub_deps("bash")
			local buf = buf_with("!cd /tm", 7)
			accept.apply(buf, { value = "/tmp/" }) -- refresh stubbed → no real defer
			vim.wait(50, function()
				return false
			end, 5) -- drain (no-op: nothing scheduled)
			assert.are.equals(before, count_open_timers(), "no new open timer after apply")
			close_buf(buf)
		end)
	end)
end)
