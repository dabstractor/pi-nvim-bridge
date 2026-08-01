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

		it("double-quote \\-escape: echo \"a\\ b (escaped space inside dquote) → non-breaking", function()
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

		it("bash: 'a\"b' → \"'a\"b'\"  (\" is LITERAL inside single quotes; NOT escaped)", function()
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
		it("fish: 'a \"b c' (space) → \"\\\"a \\\\\\\"b c\\\"\"  (escape \\ and \" inside)", function()
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
end)