-- === shell/accept.lua — the PURE, offline-testable half of §17.8 (Local acceptance & quoting) ===
-- Exports exactly TWO pure functions (no `vim.*`, no `require`, no state, no side effects) so
-- they load under `-u NORC` + are trivially unit-testable offline (the coords.lua /
-- shell.shell_word_prefix / fish.parse pattern). S4 (P2.M2.T4.S4) is the FIRST consumer: its
-- buffer-mutation accept composes these two + `nvim_buf_set_text` to do the range edit.
--
--  * `M.current_shell_word(line, cursor)` — the QUOTE-AWARE current-shell-word computation
--    (PRD §17.8 step 1): the maximal substring of `line[1..cursor]` ending at the cursor,
--    delimited by UNQUOTED whitespace. Returns `(word, start_byte)` where `start_byte` is the
--    0-based BYTE offset where the word begins (the range S4's `nvim_buf_set_text` replaces).
--    This is the quote-aware EDIT word — it COEXISTS with shell.shell_word_prefix (the NAIVE
--    quote-UNaware trailing word used for menu DISPLAY); do NOT replace that one.
--
--  * `M.quote(word, shell)` — the per-shell quoting table (PRD §17.8 step 2 / §17.15). Returns
--    the splice-safe string: the ORIGINAL word when it needs no quoting, else the shell-correct
--    quoted form (`"…"` for fish when the word has a space; `'…'` for bash/zsh with the
--    `'…'"'"'…'` idiom for an embedded single quote — `" $ \ backtick are left UNTOUCHED
--    inside single quotes, neutralized for free). `shell` may be a PATH or a basename
--    (derived internally); unknown basename → the POSIX single-quote default.
--
-- BYTE-DOMAIN throughout (PRD §17.14): `cursor` + `start_byte` are 0-based BYTE offsets (NOT
-- UTF-16 — never call coords.byte_to_utf16 / vim.str_utfindex / coords.nvim_to_pi_coords; those
-- are §8's bridge path). The byte scan is UTF-8-safe because whitespace / single-quote /
-- double-quote / backslash are all ASCII (< 0x80); UTF-8 continuation bytes (>= 0x80) never
-- match them → a multibyte trailing word like "日cmd" is returned WHOLE.
--
-- [Mode A] header — read before editing:
--  * PURE + NEVER-THROWS + DEPENDENCY-FREE: no `vim.*`, no `require` (the fish.parse contract).
--    Non-string inputs return safe defaults; bad cursor is clamped to `[0,#line]`.
--  * v1 LIMITATIONS (PRD §17.8): `\-`-line-continuations are out of scope; unclosed quotes
--    extend the word to the cursor (the user is mid-quote — correct); an escaped space (`\ `)
--    is non-breaking (part of the word). Documented in the doc-comments, NOT papered over.
--  * REGISTRATION: NONE. pick_driver requires "pi-bridge.shell.<basename>" for shell basenames
--    (fish/zsh/bash) only — "accept" is not a shell basename → pick_driver never loads this.
--    S4 requires it by ABSOLUTE path `require("pi-bridge.shell.accept")` (resolves via &rtp /
--    package.path → this file). Just the FILE at this path is sufficient.
local M = {}

-- ===========================================================================
-- module-local helpers (kept LOCAL — accept.lua is dependency-free; do NOT require shell.lua)
-- ===========================================================================

--- The basename of a shell path ("/bin/zsh" → "zsh"). nil/non-string/empty → "?"
--- (a defensive sentinel; mirrors shell.lua's module-local basename but inlined here so
--- accept.lua requires nothing). NEVER throws.
---@param p string? The shell path or basename.
---@return string basename "fish" / "bash" / "zsh" / "?" (never empty).
local function basename(p)
	if type(p) ~= "string" or p == "" then
		return "?"
	end
	local b = p:gsub(".*/", "")
	return b == "" and "?" or b
end

-- The POSIX special-char set that TRIGGERS single-quoting (PRD §17.8): space, tab, $, \, `, ",
-- ', <, >, |, &, ;, (, ), ~. Built as a lookup table keyed by BYTE value — provably correct,
-- and immune to the Lua-pattern escaping pitfalls that `word:find("[%s$\\...]")` suffers (a
-- mis-escaped pattern class silently drops a char). A completion word never contains LF/CR, so
-- only space(32)+tab(9) constitute whitespace for this set.
local POSIX_SPECIALS = {
	[32] = true, -- space
	[9] = true, -- tab
	[36] = true, -- $
	[92] = true, -- \
	[96] = true, -- `
	[34] = true, -- "
	[39] = true, -- '
	[60] = true, -- <
	[62] = true, -- >
	[124] = true, -- |
	[38] = true, -- &
	[59] = true, -- ;
	[40] = true, -- (
	[41] = true, -- )
	[126] = true, -- ~
}

--- Whether `word` contains ANY POSIX special char (PRD §17.8) — a BYTE SCAN over
--- `POSIX_SPECIALS`. Short-circuits on the first match. NEVER throws.
---@param word string The candidate (assumed already type-guarded by the caller).
---@return boolean needs_quote true iff at least one special char is present.
local function needs_quote_posix(word)
	for i = 1, #word do
		if POSIX_SPECIALS[word:byte(i)] then
			return true
		end
	end
	return false
end

-- ===========================================================================
-- M.current_shell_word — PRD §17.8 step 1 (the quote-aware current-word computation)
-- ===========================================================================

--- Compute the current shell word (PRD §17.8 step 1): the maximal substring of `line` ending
--- at `cursor`, delimited by UNQUOTED whitespace. Quote-aware: whitespace inside single quotes
--- (`'...'`), double quotes (`"..."`), or after an unquoted backslash (`\ `) does NOT delimit.
---
--- Returns `(word, start_byte)` where `start_byte` is the 0-based BYTE offset where `word`
--- begins (the word occupies `line:sub(start_byte+1, cursor)` in Lua 1-indexed) — the range
--- S4's `nvim_buf_set_text(buf, row, start_byte, row, cursor, { ins })` replaces.
---
--- BYTE-DOMAIN throughout (PRD §17.14 — NOT UTF-16; NEVER call coords.byte_to_utf16 /
--- vim.str_utfindex / coords.nvim_to_pi_coords). The byte scan is UTF-8-safe: whitespace,
--- single-quote, double-quote, backslash are all ASCII (< 0x80); UTF-8 continuation bytes
--- (>= 0x80) never match them → a multibyte trailing word is returned WHOLE.
---
--- SINGLE-PASS STATE MACHINE: one byte at a time over `line[1..cursor]`, tracking three
--- boolean states — `single` (inside `'...'`), `double` (inside `"..."`), `escaped` (the byte
--- after an unquoted `\`). An UNQUOTED space/tab advances `word_start` past it; whitespace
--- inside a quote region or after a `\` does NOT (it is part of the word). Inside single
--- quotes `\` is a literal (POSIX — no escape processing in single quotes); inside double
--- quotes `\` escapes the NEXT byte (so a `\ ` stays non-breaking).
---
--- PURE + never-throws + dependency-free → fixture-testable offline (coords.lua /
--- shell_word_prefix / fish.parse style). Mirrors the S2 `M.parse` shape.
---
--- v1 LIMITATIONS (PRD §17.8, documented NOT papered over):
---   * `\-`-line-continuations are out of scope (the buffer is one logical line).
---   * Unclosed quotes: the word extends to the cursor (the quote is treated as still open —
---     correct, the user is mid-quote).
---   * Escaped space (`\ `): non-breaking (part of the word) — the quote-aware behavior.
---
--- KNOWN: this is MORE sophisticated than `shell.shell_word_prefix` (the naive quote-UNaware
--- trailing word, `line:match("[%S]+$")`, used for menu DISPLAY); the two COEXIST — do NOT
--- replace it. `current_shell_word` recomputes independently per §17.6.1 / §17.8.
---
---@param line string? The command text up to the cursor (UTF-8; bangs already stripped by complete_current).
---@param cursor integer? The 0-based BYTE offset into `line` (default `#line`; clamped to `[0,#line]`).
---@return string word The current shell word ("" if cursor is on/after unquoted whitespace).
---@return integer start_byte The 0-based BYTE offset where `word` begins.
function M.current_shell_word(line, cursor)
	if type(line) ~= "string" then
		return "", 0
	end
	cursor = math.max(0, math.min(#line, math.floor(tonumber(cursor) or #line)))
	local word_start = 1 -- 1-indexed; advances past each UNQUOTED whitespace byte
	local single, double, escaped = false, false, false
	for i = 1, cursor do
		local b = line:byte(i)
		if escaped then
			escaped = false -- consume the escaped byte (it is part of the word; never a delimiter)
		elseif single then
			if b == 39 then
				single = false
			end -- `'` closes single-quote (NO `\` escape processing inside single quotes — POSIX)
		elseif double then
			if b == 92 then
				escaped = true -- `\` escapes the next byte (inside double quotes)
			elseif b == 34 then
				double = false
			end -- `"` closes double-quote
		else
			-- NORMAL (unquoted) state
			if b == 39 then
				single = true -- `'` opens single-quote
			elseif b == 34 then
				double = true -- `"` opens double-quote
			elseif b == 92 then
				escaped = true -- `\` escapes the next byte
			elseif b == 32 or b == 9 then
				word_start = i + 1 -- UNQUOTED space/tab → boundary; word begins after it
			end
		end
	end
	return line:sub(word_start, cursor), word_start - 1 -- (word, 0-based start_byte)
end

-- ===========================================================================
-- M.quote — PRD §17.8 step 2 / §17.15 quoting table (the per-shell splice-safe form)
-- ===========================================================================

--- Quote `word` per the resolved shell's rules (PRD §17.8 step 2). Returns the splice-safe
--- string: the ORIGINAL `word` when it needs no quoting, else the shell-correct quoted form.
---
---   fish      : double-quote IFF the word contains a SPACE (escape `\` and `"` inside); else
---                unchanged. This is fish's LIGHTER rule (PRD §17.8) — `$`/`;`/`|` etc. do NOT
---                trigger quoting (LIVE-VERIFIED: fish `complete -C` returns UN-quoted words
---                with spaces, so `quote` MUST re-wrap a path-with-space or it splits).
---   bash/zsh  : single-quote IFF the word contains ANY POSIX special char (space $ \ ` " '
---                < > | & ; ( ) ~); ONLY `'` is re-quoted via the `'…'"'"'…'` idiom (gsub-THEN-
---                wrap, NOT wrap-then-sed). `" $ \ `backtick are LITERAL inside single quotes
---                (neutralized for FREE) — they are NEVER escaped (a common bug). This is the
---                safe default for an UNKNOWN shell too (matches pick_driver's degrade philosophy).
---
--- `shell` may be a PATH (`"/bin/zsh"`) or a basename (`"zsh"`) — derived internally via
--- `basename`. An unknown/nil basename (e.g. `"nu"`, `"elvish"`, `nil`) → the POSIX single-quote
--- default (the safe POSIX choice). PURE + never-throws + dependency-free → fixture-testable
--- offline (§17.15 quoting table).
---
---@param word string? The candidate to splice (e.g. AutocompleteItem.value).
---@param shell string? The resolved shell PATH or basename (nil/unknown → POSIX default).
---@return string quoted The (possibly quoted) string; "" on a non-string `word`.
function M.quote(word, shell)
	if type(word) ~= "string" then
		return ""
	end
	local base = basename(shell) -- "/bin/zsh"→"zsh"; nil/"?"→"?"
	if base == "fish" then
		-- fish lighter rule: double-quote ONLY on a space (escape `\` and `"` inside).
		if word:find(" ", 1, true) then -- PLAIN find (literal space; no Lua-pattern pitfall)
			local esc = word:gsub("\\", "\\\\"):gsub('"', '\\"') -- escape `\` FIRST, then `"`
			return '"' .. esc .. '"'
		end
		return word
	end
	-- POSIX (bash/zsh/unknown): single-quote IFF any special char.
	if needs_quote_posix(word) then
		-- gsub-THEN-wrap: only `'` is re-quoted via the idiom; `" $ \` backtick are literal
		-- inside single quotes (neutralized for free — do NOT escape them).
		return "'" .. word:gsub("'", "'\"'\"'") .. "'"
	end
	return word -- no special char → unchanged
end

return M