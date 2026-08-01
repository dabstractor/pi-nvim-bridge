-- === tests/shell_fish_spec.lua — plenary/busted OFFLINE golden parser spec (P2.M2.T4.S2) ===
-- The primary Level-2 gate for `M.parse` — the pure-Lua reference implementation of the
-- fish `complete -C` output parsing contract (PRD §17.6.1 / §17.15). Covers all 5 §17.15
-- golden fixture shapes (normal word⇥desc, descriptionless word, empty result, multiline,
-- literal-tab-in-value), the first-tab split invariant (PLAIN find — pattern-special chars
-- like `%`/`+`/`$`/`.` in words/descriptions never mis-split), the description-optional
-- invariant (ABSENT not "" when no tab / empty post-tab), a realistic `complete -C "git ch"`
-- blob, the never-throws discipline (nil/number/table/garbage → {}), the output-shape
-- contract (value:non-empty-string; description:absent-or-non-empty), and a confidence
-- guard that the prefix is derived CLIENT-SIDE in shell.lua (NOT duplicated in fish.lua).
--
-- OFFLINE: NO live `fish`, NO socket, NO daemon. `M.parse` is pure + dependency-free, so
-- this spec runs anywhere plenary runs. The S1 LIVE round-trip lives in
-- `tests/shell_fish_driver_spec.lua` (different file, gated on `fish`); S2 does NOT duplicate it.
--
-- Run (from the repo root):
--   timeout 90 nvim --headless --clean -u tests/minimal_init.lua \
--     -c 'lua require("plenary.busted").run("tests/shell_fish_spec.lua")'
local fish = require("pi-bridge.shell.fish")

describe("pi-bridge.shell.fish.parse (§17.6.1 / §17.15)", function()
	-- surface: M.parse is a function
	it("exports M.parse as a function", function()
		assert.are.equals("function", type(fish.parse))
	end)

	-- ────────────────────────────────────────────────────────────────────────
	-- §17.15 GOLDEN FIXTURES (the 5 mandated shapes) — one `it` per shape.
	-- ────────────────────────────────────────────────────────────────────────
	describe("§17.15 golden fixtures", function()
		-- (1) normal `word⇥desc` — the headline shape.
		it("normal word<TAB>desc → {value, description}", function()
			local got = fish.parse("checkout\tCheckout and switch to a branch\n")
			assert.are.equals(1, #got)
			assert.are.equals("checkout", got[1].value)
			assert.are.equals("Checkout and switch to a branch", got[1].description)
		end)

		-- (2) descriptionless `word` (no tab) → value ONLY; description key ABSENT.
		it("descriptionless word → {value} (no description key)", function()
			local got = fish.parse("cherry\n")
			assert.are.equals(1, #got)
			assert.are.equals("cherry", got[1].value)
			assert.is_nil(got[1].description) -- ABSENT, not ""
		end)

		-- (3) empty result → {} (no items).
		it("empty result → {}", function()
			assert.are.same({}, fish.parse(""))
		end)

		-- (4) multiline (N items) — mix of word⇥desc + bare word.
		it("multiline (N items) splits each line", function()
			local got = fish.parse("a\tA\nb\nc\tC")
			assert.are.equals(3, #got)
			assert.are.equals("a", got[1].value)
			assert.are.equals("A", got[1].description)
			assert.are.equals("b", got[2].value)
			assert.is_nil(got[2].description)
			assert.are.equals("c", got[3].value)
			assert.are.equals("C", got[3].description)
		end)

		-- (5) literal-tab-in-value — the KNOWN LIMITATION: the FIRST tab is the
		-- delimiter (format is unescaped tab-delimited), so a value containing a
		-- literal 0x09 cannot round-trip. word = bytes-before-first-tab; the
		-- description keeps the rest verbatim (including the second tab).
		it("literal-tab-in-value: first tab is the delimiter (value = bytes before it)", function()
			local got = fish.parse("a\tb\tc\n")
			assert.are.equals(1, #got)
			assert.are.equals("a", got[1].value)
			assert.are.equals("b\tc", got[1].description) -- 2nd tab kept verbatim in desc
		end)
	end)

	-- ────────────────────────────────────────────────────────────────────────
	-- FIRST-TAB SPLIT with PATTERN-SPECIAL CHARS — proves PLAIN find (4th arg true),
	-- not a Lua pattern. A word/desc containing `%`, `+`, `$`, `.`, `-`, `(` must NOT
	-- mis-split (a `line:match("^(.-)\t")` would misread these).
	-- ────────────────────────────────────────────────────────────────────────
	describe("first-tab split with pattern-special chars (PLAIN find, no pattern)", function()
		it("word containing `%` `$` `.` is not mis-split", function()
			local got = fish.parse("100%done\tparsed.price\n")
			assert.are.equals("100%done", got[1].value)
			assert.are.equals("parsed.price", got[1].description)
		end)

		it("word containing `+` `-` `(` is not mis-split", function()
			local got = fish.parse("a+b-c(x)\tdesc\n")
			assert.are.equals("a+b-c(x)", got[1].value)
			assert.are.equals("desc", got[1].description)
		end)

		it("description containing `%` is kept verbatim", function()
			local got = fish.parse("word\t80% complete\n")
			assert.are.equals("word", got[1].value)
			assert.are.equals("80% complete", got[1].description)
		end)
	end)

	-- ────────────────────────────────────────────────────────────────────────
	-- DESCRIPTION-OPTIONAL INVARIANTS
	-- ────────────────────────────────────────────────────────────────────────
	describe("description optionality", function()
		it("no tab → description ABSENT (not '')", function()
			assert.is_nil(fish.parse("word\n")[1].description)
		end)

		it("tab then nothing (word<TAB>) → description ABSENT (not '')", function()
			assert.is_nil(fish.parse("word\t\n")[1].description)
		end)

		it("word<TAB>desc → description present + non-empty", function()
			assert.are.equals("desc", fish.parse("word\tdesc\n")[1].description)
		end)

		it("description keeps a trailing tab pair verbatim", function()
			-- "word\t<tab>\t" → first tab is delimiter; desc = "<tab>\t" (a leading tab + the literal)
			local got = fish.parse("word\t\t\tend\n")
			assert.are.equals("\t\tend", got[1].description)
		end)
	end)

	-- ────────────────────────────────────────────────────────────────────────
	-- MIXED / REALISTIC — a real-ish `complete -C "git ch"` blob (mirrors LIVE output).
	-- ────────────────────────────────────────────────────────────────────────
	describe('mixed / realistic (complete -C "git ch")', function()
		it("decodes the realistic git-ch blob (checkout⇥desc, bare cherry, cherry-pick⇥desc)", function()
			local raw = "checkout\tCheckout and switch to a branch\n"
				.. "cherry\n"
				.. "cherry-pick\tApply a commit on another branch\n"
			local got = fish.parse(raw)
			assert.are.equals(3, #got)
			-- values in order
			assert.are.equals("checkout", got[1].value)
			assert.are.equals("cherry", got[2].value)
			assert.are.equals("cherry-pick", got[3].value)
			-- selective descriptions
			assert.are.equals("Checkout and switch to a branch", got[1].description)
			assert.is_nil(got[2].description) -- bare word
			assert.are.equals("Apply a commit on another branch", got[3].description)
		end)

		it("handles trailing newline + trailing blank lines (gmatch skips empties)", function()
			local got = fish.parse("a\tA\n\nb\n\n")
			assert.are.equals(2, #got)
			assert.are.equals("a", got[1].value)
			assert.are.equals("b", got[2].value)
		end)

		it("handles CRLF line endings (\\r\\n)", function()
			local got = fish.parse("a\tA\r\nb\r\n")
			assert.are.equals(2, #got)
			assert.are.equals("a", got[1].value)
			assert.are.equals("A", got[1].description)
			assert.are.equals("b", got[2].value)
			assert.is_nil(got[2].description)
		end)
	end)

	-- ────────────────────────────────────────────────────────────────────────
	-- NEVER-THROWS + OUTPUT-SHAPE CONTRACT
	-- ────────────────────────────────────────────────────────────────────────
	describe("never-throws + shape contract", function()
		it("non-string raw (nil/number/table/bool) → {} without throwing", function()
			assert.has_no.errors(function()
				fish.parse(nil)
				fish.parse(123)
				fish.parse({})
				fish.parse(true)
			end)
			assert.are.same({}, fish.parse(nil))
			assert.are.same({}, fish.parse(123))
			assert.are.same({}, fish.parse({}))
			assert.are.same({}, fish.parse(true))
		end)

		it("garbage string → still parses line-by-line without throwing", function()
			assert.has_no.errors(function()
				fish.parse("not a real completion\x00\xff\nmore garbage")
			end)
			local got = fish.parse("not a real completion\x00\xff\nmore garbage")
			-- two non-empty lines → two items (the 2nd is bare; the 1st has a control byte in value)
			assert.are.equals(2, #got)
		end)

		it("empty string → {}", function()
			assert.are.same({}, fish.parse(""))
		end)

		it("lone tab (empty word) is DROPPED — never emits {value=''}", function()
			-- a lone-tab line "\t" has word == "" → dropped (parity with normalize_item).
			assert.are.same({}, fish.parse("\t\n"))
			-- also a leading-tab line: "\tdesc" → word "" → dropped.
			assert.are.same({}, fish.parse("\tdesc\n"))
		end)

		-- SHAPE: every emitted item has a non-empty string value; description is
		-- absent-or-a-non-empty-string. This is EXACTLY what shell.lua normalize_item
		-- requires (Level-4 shape check codified as a spec).
		it("every item satisfies the normalize_item input shape (value non-empty; desc absent-or-non-empty)", function()
			local raw = "checkout\tCheckout and switch to a branch\n"
				.. "cherry\n"
				.. "cherry-pick\tApply\n"
				.. "\t\n"
				.. "a\tb\tc\n"
			for _, it in ipairs(fish.parse(raw)) do
				assert.are.equals("string", type(it.value), "value must be a string")
				assert.are_not.equals("", it.value, "value must be non-empty")
				-- description must be ABSENT or a non-empty string (the normalize_item input shape).
				local ok_desc = it.description == nil or (type(it.description) == "string" and it.description ~= "")
				assert.is_true(ok_desc, "desc must be absent-or-non-empty (got " .. tostring(it.description) .. ")")
			end
		end)
	end)

	-- ────────────────────────────────────────────────────────────────────────
	-- DAEMON PARITY — M.parse mirrors the S1 daemon's `__pi_handle` split semantics
	-- (first-tab split; description optional; empty-word skip). The daemon is the
	-- runtime implementation of the same spec; M.parse is the testable reference.
	-- (No code change to the daemon — this documents the contract.)
	-- ────────────────────────────────────────────────────────────────────────
	describe("daemon parity (M.parse mirrors __pi_handle split)", function()
		it("first-tab split (daemon: `string replace -r '\\t.*$' ''` for word)", function()
			-- the daemon's word = bytes-before-first-tab; desc = bytes-after-first-tab.
			-- M.parse uses the same plain first-tab split.
			local got = fish.parse("word\tdesc with spaces\n")
			assert.are.equals("word", got[1].value)
			assert.are.equals("desc with spaces", got[1].description)
		end)

		it('description optional (daemon: `test -n "$desc"` before emitting it)', function()
			-- the daemon emits description ONLY when non-empty; M.parse omits it otherwise.
			assert.is_nil(fish.parse("word\n")[1].description)
			assert.is_nil(fish.parse("word\t\n")[1].description)
		end)
	end)

	-- ────────────────────────────────────────────────────────────────────────
	-- PREFIX IS CLIENT-SIDE (shell.lua) — confidence guard. fish.lua does NOT
	-- duplicate prefix derivation; shell.shell_word_prefix / complete_current own it
	-- and OVERRIDE the daemon's advisory `"prefix":""`. (No fish.lua prefix code.)
	-- ────────────────────────────────────────────────────────────────────────
	describe("prefix is client-side (shell.lua, not fish.lua)", function()
		local shell = require("pi-bridge.shell")
		it("shell.shell_word_prefix derives the trailing word", function()
			assert.are.equals("ch", shell.shell_word_prefix("git ch"))
			assert.are.equals("", shell.shell_word_prefix("git ")) -- trailing space → no word
			assert.are.equals("/tmp/foo", shell.shell_word_prefix("cd /tmp/foo"))
		end)
	end)
end)
