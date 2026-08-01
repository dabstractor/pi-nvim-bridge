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

-- ===========================================================================
-- M.apply — PRD §17.8 steps 3-5 (the IMPURE buffer-mutation consumer of S3's fns)
-- ===========================================================================

--- Apply a shell-completion candidate to the buffer via a WORD-RANGE edit (PRD §17.8
--- steps 3-5 — the shell counterpart to completion.M.accept's pi-bridge
--- `applyCompletion` path). Shell candidates are PLAIN WORDS, not pi
--- AutocompleteItems; pi's `applyCompletion` (which returns the WHOLE new lines[] +
--- computes pi-specific insertion) DOES NOT APPLY. So the shell path uses its OWN
--- accept: a local word-replacement via `nvim_buf_set_text` (a range edit on the
--- current shell token) + cursor positioning + a directory re-trigger.
---
--- Steps (VERIFIED against `:help api.txt` + autocmd.txt, Neovim ≥ 0.11):
---   1. validate buf (number + valid + current) + item (table with string `.value`).
---   2. read line 1 + cursor (BYTE-domain, PRD §17.14 — NO coords/UTF-16).
---   3. strip the `!`/`!!` bangs (the SAME math `shell.complete_current` uses).
---   4. `M.current_shell_word(cmd, cmd_cursor)` → `(word, start_byte)` (cmd-relative).
---   5. `M.quote(item.value, get_shell())` → the per-shell splice-safe form.
---   6. `nvim_buf_set_text(buf, 0, bangs+start_byte, 0, bangs+cmd_cursor, { quoted })`
---      — the word-range edit on row 0 (the start_byte/cmd_cursor are RELATIVE to the
---      bang-stripped command → ADD `bangs` for the BUFFER byte offset).
---   7. `nvim_win_set_cursor(0, { 1, bangs+start_byte+#quoted })` — cursor right after
---      the inserted text (row 1 = 1-BASED, the row asymmetry vs set_text's 0-based;
---      col is 0-based byte; `#quoted` is a Lua byte length → correct).
---   8. `menu.close()` (clear state + hide popup).
---   9. iff `item.value` ends with `/` → `completion.refresh(buf)` (re-queries the
---      daemon for the directory's contents; the 0 ms shell debounce re-opens the
---      menu iff non-empty). This re-trigger MUST be explicit: `nvim_buf_set_text`
---      does NOT fire TextChangedI (only bumps b:changedtick) — the autocmd will NOT
---      fire from the API edit.
---
--- LAZY REQUIRES are INSIDE the fn (NOT module top) so the module still loads under
--- `-u NORC` (the pure plenary-free smoke runs) + is test-mock-friendly (the
--- shell/menu/completion stubs swap in after require). `vim.api.*` referenced INSIDE
--- the fn is fine (it exists under NORC headless; just not called by the pure smoke).
---
--- NEVER THROWS (per-keystroke + accept contract): EVERY nvim call is `pcall`'d; a
--- wiped buf / non-current buf / bad arg → return `false` (no throw — the routing
--- returns it so `<Tab>`/`<CR>` fall through to indent/newline). Returns `true` iff
--- the edit was applied.
---
---@param buf integer  The pi-prompt buffer handle (MUST be valid + the current buf).
---@param item table    The selected candidate; MUST have a string `.value`.
---@return boolean applied true iff the edit was applied; false on any guard/never-throws failure.
function M.apply(buf, item)
	-- (1) validate (never-throws; return false on miss)
	if type(buf) ~= "number" or not vim.api.nvim_buf_is_valid(buf) then
		return false
	end
	if buf ~= vim.api.nvim_get_current_buf() then
		return false
	end -- one buf/session; cursor is current win's
	if type(item) ~= "table" or type(item.value) ~= "string" then
		return false
	end
	-- (2) read line 1 + cursor (pcall every nvim call; wiped buf mid-call → false)
	local ok, lines = pcall(vim.api.nvim_buf_get_lines, buf, 0, 1, false)
	if not ok or type(lines) ~= "table" or type(lines[1]) ~= "string" then
		return false
	end
	local line1 = lines[1]
	local cok, cur = pcall(vim.api.nvim_win_get_cursor, 0)
	if not cok or type(cur) ~= "table" or type(cur[2]) ~= "number" then
		return false
	end
	local byte_col = cur[2] -- 0-based BYTE offset (PRD §17.14)
	-- (3) bang strip (complete_current L987-990 — check "!!" FIRST; it also starts with "!")
	local bangs = 0
	if line1:sub(1, 2) == "!!" then
		bangs = 2
	elseif line1:sub(1, 1) == "!" then
		bangs = 1
	end
	local cmd = line1:sub(bangs + 1) -- command after bangs
	local cmd_cursor = math.max(0, byte_col - bangs) -- cursor offset into cmd (0-based byte)
	-- (4) S3 word range (cmd-relative; byte-domain by construction — UTF-8 safe)
	local _word, start_byte = M.current_shell_word(cmd, cmd_cursor)
	-- (5) S3 quote (shell via lazy get_shell; nil → POSIX default, harmless)
	local shell = require("pi-bridge.shell").get_shell()
	local quoted = M.quote(item.value, shell)
	-- (6) range edit (row 0; ADD BANGS to the cmd-relative offsets; set_text ≠ TextChangedI).
	--     start_byte/cmd_cursor are RELATIVE to the bang-stripped command → the BUFFER byte
	--     offset is `bangs + offset` (the #1 off-by-N trap). end_col is end-EXCLUSIVE.
	local buf_start = bangs + start_byte
	local buf_end = bangs + cmd_cursor
	local tok = pcall(vim.api.nvim_buf_set_text, buf, 0, buf_start, 0, buf_end, { quoted })
	if not tok then
		return false
	end
	-- (7) cursor after inserted text (row 1 = 1-BASED; col 0-based byte; Insert-safe +
	--     synchronous — mode() stays "i"; committed before the next Lua line; no re-trigger race).
	pcall(vim.api.nvim_win_set_cursor, 0, { 1, buf_start + #quoted })
	-- (8) close menu (idempotent; clears candidate list + hides popup; pcall'd).
	pcall(require("pi-bridge.menu").close)
	-- (9) directory re-trigger (EXPLICIT — set_text did NOT fire TextChangedI; refresh
	--     re-derives ctx=="shell" → do_shell_fetch → re-queries the daemon → re-opens iff
	--     the dir is non-empty; the 0 ms shell debounce makes it near-immediate).
	if item.value:sub(-1) == "/" then
		pcall(require("pi-bridge.completion").refresh, buf)
	end
	return true
end

return M
