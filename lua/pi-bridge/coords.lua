--- coords.lua — the CENTRALIZED byte↔UTF‑16 + nvim↔pi coordinate-conversion seam
-- (PRD §8).
--
-- Owns the FULL nvim↔pi coordinate-translation stack for parent task P2.M6.T17
-- ("coords.lua — byte↔UTF‑16 and nvim↔pi cursor conversion"): the LOWEST layer —
-- two stateless pure functions that convert a position WITHIN a single line string
-- between Neovim/Lua's native unit (a BYTE offset) and pi's unit (a UTF‑16
-- code-unit offset — i.e. a JavaScript string index = pi's `cursorCol`) — PLUS the
-- S29 row/col wrappers (`nvim_to_pi_coords` / `pi_to_nvim_coords`) that compose
-- these primitives with the nvim↔pi row ±1 and cursor-API alignment — THE public
-- nvim↔pi cursor API for S30+ completion / S32 accept. These are THE single,
-- centralized implementation of PRD §8's "Coordinate & Encoding Contract" — every
-- nvim→pi (and pi→nvim) coordinate translation that S30+/S32 (completion / accept)
-- and any blink/cmp source will ever do MUST route through these wrappers (which
-- in turn route through the byte/utf16 primitives), so the conversion — and any
-- future fix — lives in exactly ONE place ("MUST be centralized so the fix is one
-- place").
--
-- [Mode A] header — read before editing:
--  * CENTRALIZED SEAM (PRD §8 (heading:h2.8) "MUST be centralized so the fix is one
--    place"): EVERY nvim↔pi coordinate translation MUST route through these two
--    functions. Downstream consumers — S29 (`nvim_to_pi_coords` / `pi_to_nvim_coords`
--    row/col wrappers), S30+ completion (cursor→pi `cursorCol` for `getSuggestions`),
--    S32 accept (pi `cursorCol`→nvim byte col for `nvim_win_set_cursor`), and any
--    blink/cmp source — MUST `require("pi-bridge.coords")` and call these. They MUST
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
--  * CURSOR-API COL IS 0-BASED BYTE (external_deps.md §1.2, LIVE‑VERIFIED):
--    `nvim_win_get_cursor(0)` returns `{row 1-indexed, col 0-indexed BYTE}` and
--    `nvim_win_set_cursor(0, {row, col})` takes the SAME 0-indexed BYTE col
--    (unlike `vim.fn.col`, which is 1-indexed). So the COLUMN conversion in the
--    S29 wrappers is ±0 — S28's byte domain aligns with the cursor API DIRECTLY;
--    the ONLY ±1 in the whole module is the ROW (nvim row 1-based ↔ pi cursorLine
--    0-based). `nvim_to_pi_coords` reads `byte_col` from `nvim_win_get_cursor[2]`
--    unchanged; `pi_to_nvim_coords` returns a `col` ready for `nvim_win_set_cursor`
--    unchanged.
--  * PRD §7.4 `bytecol - 1` IS SUPERSEDED (refinement over PRD): PRD §7.4 step 4
--    says `nvim_win_set_cursor(0, {row, bytecol - 1})`. Under the exact-UTF‑16 +
--    0-based-byte-API design (S28 + external_deps.md §1.2) that `-1` DOUBLE-
--    CORRECTS — it would nudge the cursor ONE BYTE LEFT on every accept (worst on
--    multibyte lines). S29 follows `external_deps.md §1.2` over PRD §7.4. A reader
--    of PRD §7.4 should not be surprised by the absence of the `-1` in
--    `pi_to_nvim_coords` — that is why this note exists (mirrors the S28
--    utf16_len_of_prefix supersession pattern: document every refinement over PRD).
--
-- Node builtins analog: only `vim.str_utfindex` / `vim.str_byteindex` (both built
-- in). No module-level mutable state — a pure-function library.

local M = {}

--- Result of nvim_to_pi_coords: nvim-native cursor → pi-native. `lines` is
--- pass-through (SAME table reference as the input) so the result drops straight
--- into a `getSuggestions` RPC params object (`vim.tbl_extend("keep", …)`).
---@class pi-bridge.PiCoords
---@field lines      string[] The buffer lines (UNCHANGED — same reference as input).
---@field cursorLine integer 0-indexed line (pi's unit) == nvim `row` - 1.
---@field cursorCol  integer 0-indexed UTF‑16 code-unit offset (pi's `cursorCol`).

--- Result of pi_to_nvim_coords: pi-native cursor → nvim-native. `lines` is
--- pass-through (SAME table reference as the input).
---@class pi-bridge.NvimCoords
---@field lines string[] The buffer lines (UNCHANGED — same reference as input).
---@field row   integer 1-indexed nvim row == pi `cursorLine` + 1 (nvim_win_set_cursor[1]).
---@field col   integer 0-indexed BYTE offset (nvim_win_set_cursor[2] — NO `-1`; see header).

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

-- ─────────────────────────────────────────────────────────────────────────────
-- S29: the row/col wrappers — THE public nvim↔pi cursor API.
-- Compose S28's byte/utf16 primitives with the nvim↔pi ROW ±1 + cursor-API
-- alignment. PURE functions over explicit `(lines, …)` args (NOT a buffer/win):
-- the caller reads the buffer/cursor and passes values in (S30 completion /
-- S32 accept). ROUTE THROUGH S28 — never `vim.str_utfindex`/`str_byteindex` here.
-- COLUMN math is ±0 (cursor-API col is 0-based byte; see header); the ONLY ±1 is
-- the ROW. NEVER THROWS (type-guard `lines`; `or ""` line guard; S28 inherited).
--
-- CALLER pattern (FUTURE S30/S32 — NOT implemented here, design only):
--   completion (nvim → pi):
--     local cur   = vim.api.nvim_win_get_cursor(0)             -- {row 1-based, col 0-based byte}
--     local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
--     local pi    = coords.nvim_to_pi_coords(lines, cur[1], cur[2])
--     bridge.request("getSuggestions",
--       vim.tbl_extend("keep", pi, { force = force }), cb)       -- {lines, cursorLine, cursorCol, force?}
--   accept (pi → nvim):
--     local nv = coords.pi_to_nvim_coords(r.lines, r.cursorLine, r.cursorCol)
--     vim.api.nvim_buf_set_lines(0, 0, -1, false, nv.lines)
--     vim.api.nvim_win_set_cursor(0, { nv.row, nv.col })        -- NO -1 (PRD §7.4 superseded)
-- ─────────────────────────────────────────────────────────────────────────────

--- nvim-native cursor → pi-native. For sending the nvim cursor to pi (S30
--- `getSuggestions`). `row` is 1-indexed (nvim); `byte_col` is **0-indexed BYTE**
--- (the value `nvim_win_get_cursor(0)[2]` already returns — NO ±1 on the column).
---
--- Routes through S28's `byte_to_utf16` (the centralized seam); the column
--- conversion is ±0 — the ONLY index arithmetic is `cursorLine = row - 1`. Never
--- throws (type-guard `lines`; `lines[row] or ""` guards the line access so a
--- missing/out-of-range line degrades to `""` → `cursorCol` 0; the ROW is NOT
--- clamped — a real nvim cursor is always in range, clamping would hide caller
--- bugs; the LINE guard is the defensive boundary).
---
---@param lines    string[] Buffer lines (as from `nvim_buf_get_lines(0,0,-1,false)`).
---@param row      integer  1-indexed nvim row (`nvim_win_get_cursor(0)[1]`).
---@param byte_col integer  0-indexed BYTE offset (`nvim_win_get_cursor(0)[2]`) — NO ±1.
---@return pi-bridge.PiCoords `{lines, cursorLine, cursorCol}` (lines is pass-through).
function M.nvim_to_pi_coords(lines, row, byte_col)
  if type(lines) ~= "table" then lines = {} end        -- never-throws (non-table → safe)
  local r = (type(row) == "number") and row or 1       -- never-throws; default row 1
  local line = lines[r] or ""                         -- Lua 1-based array (nvim row already 1-based); guard missing (→ "" → col 0)
  return {
    lines      = lines,                               -- pass-through (SAME table reference)
    cursorLine = r - 1,                               -- nvim row 1-based → pi cursorLine 0-based (the ONLY ±1)
    cursorCol  = M.byte_to_utf16(line, byte_col),     -- S28 primitive; ±0 on the column
  }
end

--- pi-native cursor → nvim-native. The EXACT inverse of `nvim_to_pi_coords`. For
--- applying a pi result back to nvim (S32 `applyCompletion` → `nvim_win_set_cursor`).
--- `col` is **0-indexed BYTE**, ready for `nvim_win_set_cursor(0, {row, col})`
--- UNCHANGED — **NO `-1`** (PRD §7.4's `bytecol - 1` is superseded under this
--- design; see header — it would nudge the cursor one byte LEFT on every accept).
---
--- Routes through S28's `utf16_to_byte` (the centralized seam); the column
--- conversion is ±0 — the ONLY index arithmetic is `row = cursorLine + 1`. Never
--- throws (same guards as `nvim_to_pi_coords`; `lines[cursorLine + 1] or ""`
--- handles the pi-0-based → Lua-1-based indexing asymmetry).
---
---@param lines      string[] Buffer/result lines.
---@param cursorLine integer  0-indexed pi line.
---@param cursorCol  integer  0-indexed UTF‑16 offset (pi's `cursorCol` unit).
---@return pi-bridge.NvimCoords `{lines, row, col}` (lines is pass-through; col is 0-based byte — NO -1).
function M.pi_to_nvim_coords(lines, cursorLine, cursorCol)
  if type(lines) ~= "table" then lines = {} end        -- never-throws
  local cl = (type(cursorLine) == "number") and cursorLine or 0  -- never-throws; default cursorLine 0
  local line = lines[cl + 1] or ""                    -- pi 0-based → Lua 1-based; guard missing (→ "" → col 0)
  return {
    lines = lines,                                    -- pass-through (SAME table reference)
    row   = cl + 1,                                   -- pi 0-based → nvim 1-based (the ONLY ±1)
    col   = M.utf16_to_byte(line, cursorCol),         -- S28 primitive; 0-based byte (NO -1)
  }
end

return M