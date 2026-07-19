--- coords.lua — the CENTRALIZED byte↔UTF‑16 coordinate-conversion seam (PRD §8).
--
-- Owns the LOWEST layer of parent task P2.M6.T17 ("coords.lua — byte↔UTF‑16 and
-- nvim↔pi cursor conversion"): two stateless pure functions that convert a position
-- WITHIN a single line string between Neovim/Lua's native unit (a BYTE offset) and
-- pi's unit (a UTF‑16 code-unit offset — i.e. a JavaScript string index = pi's
-- `cursorCol`). These are THE single, centralized implementation of PRD §8's
-- "Coordinate & Encoding Contract" — every nvim→pi (and pi→nvim) coordinate
-- translation that the sibling S29 (row/col wrappers) and S30+/S32 (completion /
-- accept) will ever do MUST route through these two functions, so the conversion —
-- and any future fix — lives in exactly ONE place ("MUST be centralized so the fix
-- is one place").
--
-- [Mode A] header — read before editing:
--  * CENTRALIZED SEAM (PRD §8 (heading:h2.8) "MUST be centralized so the fix is one
--    place"): EVERY nvim↔pi coordinate translation MUST route through these two
--    functions. Downstream consumers — S29 (`nvim_to_pi_coords` / `pi_to_nvim_coords`
--    row/col wrappers), S30+ completion (cursor→pi `cursorCol` for `getSuggestions`),
--    S32 accept (pi `cursorCol`→nvim byte col for `nvim_win_set_cursor`), and any
--    blink/cmp source — MUST `require("pi-editor.coords")` and call these. They MUST
--    NOT call `vim.str_utfindex` / `vim.str_byteindex` directly (Anti-Pattern: that
--    bypasses the centralization mandate and re-fragments the conversion).
--  * REFINEMENT OVER PRD §8 (LIVE‑VERIFIED, research/notes.md §1/§4): PRD §8
--    prescribes a CODEPOINT-intermediate path (`vim.str_utfindex(line, c-1)` → manual
--    codepoint→UTF‑16 surrogate counting) and accepts a v1 "codepoint≈utf16"
--    approximation with a v1.1 `utf16_len_of_prefix` fix-up. This module uses
--    Neovim 0.11+'s 3-arg STRING-ENCODING overload — `vim.str_utfindex(line,
--    "utf-16", byte_idx)` / `vim.str_byteindex(line, "utf-16", utf16_idx)` — which
--    does UTF‑16 conversion EXACTLY (surrogate pairs counted as 2 units)
--    natively. It SUPERSEDES both the v1 approximation AND `utf16_len_of_prefix`
--    in one simpler verified implementation. Do NOT add `utf16_len_of_prefix`
--    (it would be dead code contradicting this decision; a reader of PRD §8 should
--    not be surprised by its absence — that is why this note exists).
--  * 0-BASED BOTH WAYS: inputs AND outputs are 0-indexed (the str fns are documented
--    "All indices are zero-based"; pi `cursorCol` is 0-based = a JS string index).
--    NO ±1 arithmetic here — the nvim CURSOR ±1 (row 1-based; `vim.fn.col`
--    1-based vs `nvim_win_get_cursor` 0-based byte) is S29's job. S28 is
--    string-level only.
--  * NEVER THROWS + CLAMP (GOTCHA 1, LIVE‑VERIFIED): past-end indexes THROW
--    ("index out of range"; `strict_indexing` defaults true) — e.g.
--    `pcall(vim.str_utfindex, "hi", "utf-16", 99)` → ok=FALSE. => inputs are
--    clamped to `[0, max]` BEFORE the call AND the call is pcall'd. A VALID
--    char-boundary position is converted EXACTLY; an out-of-range input is
--    clamped to the nearest boundary (defensive against caller off-by-ones; a
--    real cursor is always in-range, so this never lies about a valid position).
--  * byte_idx == #line is LEGAL (GOTCHA 2): the EOL cursor (byte col == #line,
--    i.e. one past the last byte) maps to the UTF‑16 length — e.g.
--    `str_utfindex("héllo", "utf-16", 6)` == 5. Clamp the UPPER bound INCLUSIVE
--    (`[0, #line]`) so EOL is not clamped away. (Same for `utf16_idx ==
--    utf16_len` → `#line`.)
--  * MID-CHAR UTF‑16 INDEX ROUNDS UP (GOTCHA 3, a NON-CASE): a low-surrogate
--    index (e.g. utf16=2 in "a😀b") rounds to the NEXT codepoint's byte
--    (`str_byteindex("a😀b","utf-16",2)` == 5, not 1). This is an INVALID cursor
--    position (a cursor never points between surrogate halves) so it never
--    arises from real nvim/pi data. Documented; NOT "fixed" (the result is a
--    valid byte offset; detecting mid-char adds complexity for a non-case).
--  * UTF‑16 LENGTH SHORTCUT (GOTCHA 4): `vim.str_utfindex(line, "utf-16")` with
--    NO index returns the UTF‑16 LENGTH of the whole string (verified:
--    "a😀b" → 4). Used for `utf16_to_byte`'s upper clamp bound; `byte_to_utf16`'s
--    upper clamp bound is just `#line`.
--  * THE JSONLREADER WARNING DOES NOT APPLY (GOTCHA 6): `jsonlreader.lua:11`
--    warns "Do NOT add vim.str_utfindex/utf8.len on partial chars — BUG". That is
--    about STREAMING PARTIAL UTF‑8 chunks (a split multibyte char across socket
--    reads) on which the str fns require complete, valid UTF‑8. `coords.lua`
--    operates on COMPLETE buffer lines (`nvim_buf_get_lines` always returns
--    fully-formed UTF‑8) — the str fns are SAFE here. Do not "fix" a non-bug.
--  * STATELESS (GOTCHA 7): a PURE-FUNCTION library — `local M = {}` + two pure
--    functions + `return M`. No `M.new`, no module-level mutable state, no
--    `setup()`. Each call is `f(line, idx) → idx`. (Contrast `bridge.lua`, a
--    singleton with module-level `state`/`pending` — do NOT cargo-cult its
--    state shape here.)
--  * NEVER-THROWS > INPUT VALIDATION (GOTCHA 8): a non-string `line` or
--    non-number index is a caller BUG. Degrade to a safe return (0) via
--    type-guard + pcall rather than throw — `coords` is called per-keystroke
--    from completion (S30+); a throw would abort completion. The shipped
--    contract is never-throws.
--  * VERSION (GOTCHA 9): the 3-arg "utf-16" overload was ADDED in Neovim 0.11
--    (News-0.11). PRD §10.1 (heading:h3.26) says "Neovim 0.10+ (0.12 verified)";
--    the UTF‑16 path raises the effective floor to 0.11. 0.12.4 is the verified
--    target.
--
-- Node builtins analog: only `vim.str_utfindex` / `vim.str_byteindex` (both built
-- in). No module-level mutable state — a pure-function library.

local M = {}

--- Convert a 0-indexed BYTE offset in `line` to a 0-indexed UTF‑16 code-unit
--- offset (pi's `cursorCol` unit). For sending an nvim cursor position to pi
--- (S29/S30 wrap this).
---
--- EXACT for valid char-boundary positions (incl. astral: 😀 = 2 UTF‑16 units,
--- counted natively — NOT the PRD §8 v1 "codepoint≈utf16" approximation). An
--- out-of-range `byte_idx` is clamped to `[0, #line]`; the EOL cursor
--- (`byte_idx == #line`) is LEGAL and maps to the UTF‑16 length. Never throws
--- (clamp + pcall; a non-string `line` returns 0; a non-number index is treated
--- as 0).
---
---@param line     string  A COMPLETE UTF‑8 line (as from `nvim_buf_get_lines`).
---@param byte_idx integer 0-indexed byte offset into `line` (`0..#line`).
---@return integer utf16_idx 0-indexed UTF‑16 code-unit offset (`0..utf16_len(line)`).
function M.byte_to_utf16(line, byte_idx)
  if type(line) ~= "string" then return 0 end          -- never-throws (GOTCHA 8)
  local n = #line
  local b = byte_idx
  if type(b) ~= "number" then b = 0 end                 -- never-throws (GOTCHA 8)
  if b < 0 then b = 0 elseif b > n then b = n end       -- clamp [0, #line] INCLUSIVE (GOTCHA 1/2)
  local ok, v = pcall(vim.str_utfindex, line, "utf-16", b)  -- 3-arg string-encoding (refinement over PRD §8)
  if ok and type(v) == "number" then return v end
  -- fall back (shouldn't happen post-clamp): the UTF‑16 length of the whole line (GOTCHA 4)
  local _, len = pcall(vim.str_utfindex, line, "utf-16")
  return (type(len) == "number") and len or n
end

--- Convert a 0-indexed UTF‑16 code-unit offset (pi's `cursorCol`) to a 0-indexed
--- BYTE offset in `line`. The inverse of `byte_to_utf16`. For applying a pi
--- result back to nvim (S29/S32 wrap this).
---
--- EXACT for valid positions (inverse of `byte_to_utf16`). An out-of-range
--- `utf16_idx` is clamped to `[0, utf16_len(line)]`; the EOL index
--- (`utf16_idx == utf16_len`) maps to `#line`. Never throws (clamp + pcall; a
--- non-string `line` returns 0; a non-number index is treated as 0).
---
---@param line      string  A COMPLETE UTF‑8 line (as from `nvim_buf_get_lines`).
---@param utf16_idx integer 0-indexed UTF‑16 code-unit offset (`0..utf16_len(line)`).
---@return integer byte_idx 0-indexed byte offset (`0..#line`).
function M.utf16_to_byte(line, utf16_idx)
  if type(line) ~= "string" then return 0 end          -- never-throws (GOTCHA 8)
  local ok_l, ulen = pcall(vim.str_utfindex, line, "utf-16")  -- GOTCHA 4: UTF‑16 length
  if not ok_l or type(ulen) ~= "number" then ulen = #line end -- degrade (empty/odd)
  local u = utf16_idx
  if type(u) ~= "number" then u = 0 end                 -- never-throws (GOTCHA 8)
  if u < 0 then u = 0 elseif u > ulen then u = ulen end -- clamp [0, ulen] INCLUSIVE (GOTCHA 1/2)
  local ok, v = pcall(vim.str_byteindex, line, "utf-16", u)  -- 3-arg string-encoding (refinement over PRD §8)
  if ok and type(v) == "number" then return v end
  return #line                                         -- fall back (shouldn't happen post-clamp)
end

return M