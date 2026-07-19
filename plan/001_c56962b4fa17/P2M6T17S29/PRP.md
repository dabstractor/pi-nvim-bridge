---
name: "P2.M6.T17.S29 — coords.lua nvim_to_pi_coords() / pi_to_nvim_coords() (the nvim↔pi cursor wrapper layer)"
description: |
  **APPEND TWO FUNCTIONS to the EXISTING `plugin/lua/pi-editor/coords.lua`** — the row/col
  wrappers that compose S28's `byte_to_utf16`/`utf16_to_byte` primitives with the nvim↔pi
  index arithmetic into the public nvim↔pi cursor-translation API. **THE public face of
  PRD §8's "Coordinate & Encoding Contract"** for every consumer (S30+ completion, S32 accept,
  blink/cmp): they take nvim-native coordinates (1-indexed row + 0-indexed byte col, as
  `nvim_win_get_cursor` reports them) and return pi-native coordinates (0-indexed
  `cursorLine` + 0-indexed UTF-16 `cursorCol`, as pi's `getSuggestions`/`applyCompletion`
  consume them) — and the exact inverse. **IMPLEMENTATION (the key refinement over PRD §7.4):**
  PRD §8 says nvim col is 1-indexed; PRD §7.4 step 4 says `nvim_win_set_cursor(…, bytecol - 1)`.
  The project's OWN `architecture/external_deps.md §1.2` (LIVE-VERIFIED on nvim 0.12.4)
  documents that `nvim_win_get_cursor`/`nvim_win_set_cursor` col is **0-indexed BYTE** — the
  EXACT same domain S28's primitives consume/produce. So the column conversion is a clean
  `byte_to_utf16(line, col)` / `utf16_to_byte(line, col)` with **NO ±1 on the column**; the
  ONLY index arithmetic is the **ROW ±1** (`cursorLine = row - 1`; `row = cursorLine + 1`).
  PRD §7.4's `-1` DOUBLE-CORRECTS under this design (would place the cursor one byte left on
  every accept — a visible wrong-column bug worst on multibyte lines). S29 follows
  `external_deps.md §1.2` over PRD §7.4 and DOCUMENTS the supersession (the S28 PRP pattern for
  refinements over PRD). **LIVE-VERIFIED on nvim 0.12.4** (research/notes.md §4): round-trip
  `nvim_to_pi_coords`/`pi_to_nvim_coords` is EXACT across ASCII / BMP (`héllo`, `日本語`) /
  astral (`a😀b`) / multi-line / EOL-cursor; e.g. `nvim_to_pi_coords({"a😀b"}, 1, 5).cursorCol == 3`
  and `pi_to_nvim_coords({"a😀b"}, 0, 3).col == 5`. Both wrappers are **PURE functions over
  explicit `(lines, …)` args** (NOT buffer-reading — matches S28's stateless pure-function
  philosophy; testable with the existing plenary harness and NO buffer), **never throw**
  (`lines[idx] or ""` guards the line access; a missing line / out-of-range row degrades to a
  safe return, never aborts the per-keystroke completion caller), and return a **TABLE**
  (`{lines, cursorLine, cursorCol}` / `{lines, row, col}`) whose `lines` is pass-through so the
  result drops straight into pi RPC params and the nvim APIs. DELIVERABLES: (1) MODIFY
  `plugin/lua/pi-editor/coords.lua` — add the two functions to the existing `local M = {}` (NO
  new file), extend the `[Mode A]` header with the PRD §7.4 `-1` refinement + the
  cursor-API-0-based-byte fact, add LuaCATS; (2) MODIFY `plugin/tests/coords_spec.lua` — APPEND
  a new `describe("pi-editor.coords nvim_to_pi_coords / pi_to_nvim_coords", …)` block
  (non-regression: the 19 existing S28 assertions stay byte-identical); (3) MODIFY
  `plugin/tests/coords_smoke.lua` — APPEND headline wrapper checks. NARROW scope guard — S29
  does NOT read/write the buffer or cursor (that's the CALLER: completion S30 / accept S32),
  call the bridge (S30+), touch menu.lua (S34+), or modify S28's primitives/their tests.
---

## Goal

**Feature Goal**: Ship the **upper layer** of the pi-editor.nvim coordinate-translation stack —
two pure wrapper functions that translate the **whole cursor** (not just a within-line offset)
between Neovim's native coordinate system (**1-indexed row + 0-indexed byte col**, as
`nvim_win_get_cursor` reports) and pi's coordinate system (**0-indexed `cursorLine` +
0-indexed UTF-16 `cursorCol`**, as pi's `getSuggestions`/`applyCompletion` consume). They are
**THE public face** of PRD §8's "Coordinate & Encoding Contract": every consumer (S30+
completion, S32 accept, blink/cmp sources) calls THESE wrappers — never S28's primitives
directly for a cursor translation, never `vim.str_utfindex`/`str_byteindex` directly. They
compose S28 (which is COMPLETE) with the row ±1 + the cursor-API index alignment, so the entire
nvim↔pi conversion — and any future fix — lives in **one module** (`coords.lua`).

**Deliverable** (3 MODIFIED files — the module + its two test gates; NO new files):
- **MODIFY** `plugin/lua/pi-editor/coords.lua` — add exactly TWO functions to the existing
  `local M = {}` table (S28's `byte_to_utf16`/`utf16_to_byte` stay unchanged — non-regression):
  - `M.nvim_to_pi_coords(lines, row, byte_col) -> table` — `{lines, cursorLine = row-1,
    cursorCol = byte_to_utf16(lines[row], byte_col)}`. For sending the nvim cursor to pi
    (`getSuggestions`). `row` is 1-indexed (nvim); `byte_col` is **0-indexed byte** (the value
    `nvim_win_get_cursor(0)[2]` already returns — NO ±1).
  - `M.pi_to_nvim_coords(lines, cursorLine, cursorCol) -> table` — `{lines, row = cursorLine+1,
    col = utf16_to_byte(lines[cursorLine+1], cursorCol)}`. The inverse — for applying a pi
    result back to nvim (`applyCompletion` → `nvim_win_set_cursor`). `col` is **0-indexed byte**,
    ready for `nvim_win_set_cursor(0, {row, col})` UNCHANGED (**NO `-1`** — see §Why / GOTCHA).
  - Extend the existing `[Mode A]` header with the two new facts: (a) the cursor-API col is
    0-indexed byte (`external_deps.md §1.2`), so column conversion is ±0; (b) the PRD §7.4
    `bytecol - 1` is superseded (double-corrects under this design). Add LuaCATS `---@param`/
    `---@return` on both functions matching S28's annotation density.
- **MODIFY** `plugin/tests/coords_spec.lua` — **APPEND** a new `describe("pi-editor.coords
  nvim_to_pi_coords / pi_to_nvim_coords", …)` block (the existing 19 S28 assertions stay
  byte-identical — non-regression). Covers: round-trip exactness (nvim→pi→nvim preserves
  row + 0-based byte col) across ASCII / BMP (`héllo`, `日本語`) / astral (`a😀b`) / multi-line /
  EOL-cursor; row ±1; exact known values; lines pass-through; never-throws + line guard.
- **MODIFY** `plugin/tests/coords_smoke.lua` — **APPEND** headline wrapper checks (no plenary):
  astral round-trip, row ±1, EOL, never-throws on empty lines. Prints `SMOKE_PASS` / exit 0.

> Reuses `plugin/tests/minimal_init.lua` (S19) unchanged. NO new file. NO change to S28's
> primitives, `init.lua`, `bridge.lua`, `jsonlreader.lua`, the ftplugin, or any other module.

**Success Definition** (every assertion is LIVE-VERIFIED — research/notes.md §4 + Validation):
- **Round-trip exactness**: `pi_to_nvim_coords(nvim_to_pi_coords(lines,row,col))` returns the
  SAME `{row, col}` — for ASCII `{"hello"}`, BMP `{"héllo"}` / `{"日本語"}`, astral `{"a😀b"}`
  (at col 1 AND 5), multi-line `{"héllo","line2"}` row 2, and empty single line.
- **Astral headline**: `nvim_to_pi_coords({"a😀b"}, 1, 5).cursorCol == 3` AND
  `pi_to_nvim_coords({"a😀b"}, 0, 3).col == 5` (😀 = surrogate pair = 2 UTF-16 units — exact via
  S28's native overload, NOT an approximation; and the inverse returns 0-based byte with NO `-1`).
- **Row ±1**: `nvim_to_pi_coords({"x","y"}, 2, 0).cursorLine == 1` and
  `pi_to_nvim_coords({"x","y"}, 1, 0).row == 2`.
- **EOL cursor**: `nvim_to_pi_coords({"héllo"}, 1, 6).cursorCol == 5` (utf16 len); round-trips
  back to `col == 6`.
- **lines pass-through**: the returned `lines` is the SAME table reference (`==` the input).
- **Never-throws + line guard**: `nvim_to_pi_coords({}, 5, 9)` and `pi_to_nvim_coords({}, 9, 9)`
  do NOT throw (missing line → `""` → cursorCol/col 0); a non-table `lines` degrades (no throw).
- Smoke prints `SMOKE_PASS` / exit 0; `coords_spec.lua` exits 0 (19 prior + new assertions).
- `[Mode A]` header extended + LuaCATS on both new functions; the "supersedes PRD §7.4 `-1`"
  note present.
- Non-regression: all prior specs (init/shim/activate/ftplugin/jsonlreader/bridge/coords-S28)
  still pass unchanged.

## User Persona (if applicable)

**Target User**: A pi user editing a prompt containing non-ASCII text — accented Latin (`café`),
CJK (`日本語`), or emoji (`fix 🐛`) — in the Neovim external editor. They never see this code;
they experience it as "completion accepts at exactly the right row AND column, even on a
multibyte line in a multi-line prompt" (pi's `applyCompletion` places the cursor exactly where
it would in the TUI). A row off-by-one drops the cursor on the wrong line; a column `-1` bug
(PRD §7.4) nudges it one byte left on every accept — both visible and annoying, worst on
multibyte text.

**Use Case**: The coordinate-translation stack's PUBLIC API. S21 (gate) → S22 (buffer) →
S24–S27 (bridge transport) → S28 (byte↔utf16 primitives, COMPLETE) → **S29 (this: the cursor
wrappers)** → S30+ (completion calls `nvim_to_pi_coords` to send
`getSuggestions(lines, cursorLine, cursorCol)` with a correct UTF-16 `cursorCol`) → S32 (accept
calls `pi_to_nvim_coords` to turn pi's returned UTF-16 `cursorCol` back into a Neovim byte col
for `nvim_win_set_cursor`). Without S29, S30/S32 would each reimplement the row ±1 + cursor-API
index juggling — and drift (exactly the "fix is one place" failure PRD §8 warns about).

**Pain Points Addressed**:
1. **Wrong-row / wrong-column cursor on accept** (PRD §8, "the single most error‑prone area"):
   pi and nvim disagree on row base (0 vs 1) AND column unit/byte-vs-UTF-16. S29 centralizes the
   full-cursor translation so every consumer is correct by construction.
2. **The PRD §7.4 `-1` trap**: a literal reading of PRD §7.4 step 4 (`bytecol - 1`) introduces a
   one-byte-left bug under the exact-UTF-16 + `nvim_win_set_cursor` (0-based byte) design. S29
   implements the LIVE-VERIFIED correct math and DOCUMENTS the supersession so no future editor
   reintroduces it.
3. **Duplicated, divergent conversion logic**: without these wrappers, S30 and S32 would each
   hand-roll `row - 1` + `byte_to_utf16(...)`. S29 is the single chokepoint (and S28 beneath it).

## Why

- **PRD §8 is the requirement source** ("Coordinate & Encoding Contract"): it states pi's units
  (`cursorLine` 0-indexed; `cursorCol` = UTF-16), nvim's units (row 1-indexed; col byte), and the
  centralization mandate ("MUST be centralized so the fix is one place"). S29 is the faithful
  implementation of the FULL-cursor half of that contract (S28 did the within-line half).
- **The architecture doc already pinned the cursor-API indexing.** `external_deps.md §1.2`
  documents that `nvim_win_get_cursor`/`nvim_win_set_cursor` col is **0-indexed byte** (LIVE-VERIFIED).
  This is the fact that makes S29's column conversion ±0 — S28's byte domain aligns with the
  cursor API directly. S29 implements that alignment; it does NOT invent new math.
- **LIVE-VERIFIED, not assumed.** Every conversion value cited was printed by `nvim --headless`
  on 0.12.4 (research/notes.md §4) — including the astral round-trip and the no-`-1` inverse.
- **Foundational + leaf-ish.** S29's only upstream dependency is S28 (COMPLETE); it is the
  upstream dependency of S30/S32. Shipping it exactly + tested de-risks the completion-accept
  cursor correctness for every consumer.
- **Centralization pays off forever.** If pi's `cursorCol` unit ever changes, or the cursor API
  indexing shifts, the fix is ONE module (`coords.lua`), not N call sites.

## What

Two pure functions added to `plugin/lua/pi-editor/coords.lua`. Both take an explicit `lines`
array + index args (NOT a buffer/win — the caller reads the buffer/cursor and passes values in),
return a TABLE whose `lines` field is the same reference passed in (pass-through), and never throw.

```lua
--- nvim → pi. `row` 1-indexed (nvim); `byte_col` 0-indexed BYTE (nvim_win_get_cursor[2]).
M.nvim_to_pi_coords(lines, row, byte_col)
  -- cursorLine = row - 1
  -- cursorCol  = M.byte_to_utf16(lines[row] or "", byte_col)   -- S28 primitive; ±0 on the col
  -> { lines = lines, cursorLine = <int>, cursorCol = <int> }   -- drop-in for pi RPC params

--- pi → nvim (inverse). `cursorLine`/`cursorCol` 0-indexed (pi units).
M.pi_to_nvim_coords(lines, cursorLine, cursorCol)
  -- row = cursorLine + 1
  -- col = M.utf16_to_byte(lines[cursorLine + 1] or "", cursorCol)  -- S28; 0-based byte, NO `-1`
  -> { lines = lines, row = <int>, col = <int> }   -- nvim_win_set_cursor(0, {row, col}) ready
```

(Note the Lua **1-based array** indexing: pi `cursorLine` is 0-based but `lines` is a Lua array
indexed from 1, so `lines[row]` reads the nvim cursor's line and `lines[cursorLine + 1]` reads
pi's cursor line. Guarded with `or ""` so a missing line never throws.)

### Success Criteria

- [ ] `coords.nvim_to_pi_coords` and `coords.pi_to_nvim_coords` exist and are `function`s.
- [ ] Round-trip `pi_to_nvim_coords(pi_from_nvim).{row,col} == {row,col}` for ASCII/BMP/CJK/
      astral/multi-line/EOL/empty (LIVE-VERIFIED values in the test matrix).
- [ ] `nvim_to_pi_coords({"a😀b"}, 1, 5).cursorCol == 3`; `pi_to_nvim_coords({"a😀b"}, 0, 3).col == 5`.
- [ ] Row ±1 correct; EOL cursor maps to the UTF-16 length and round-trips.
- [ ] Returned `lines` is the SAME table reference (pass-through).
- [ ] Never-throws on empty/missing-line/out-of-range-row/non-table `lines`.
- [ ] Column math has **NO `-1`** (PRD §7.4 supersession documented in the header).
- [ ] Non-regression: 19 prior S28 assertions + all other specs still green.

## All Needed Context

### Context Completeness Check

_If someone knew nothing about this codebase, would they have everything needed to implement
this successfully?_ **YES** — S28 (the prerequisite) is COMPLETE and its module + PRP +
research are all in-tree; the conversion contract is pinned by PRD §8 + the LIVE-VERIFIED
`architecture/external_deps.md §1.2`; every assertion value was printed by nvim 0.12.4; the
exact test-harness commands are verified green. The implementer needs to: read S28's
`coords.lua` + its `[Mode A]` header (to match discipline), read `external_deps.md §1.1/§1.2`
(the verified recipe), append two functions + extend the header, and append test blocks. No
guessing; no external research required (all references in-tree + one Neovim doc URL).

### Documentation & References

```yaml
# MUST READ - Include these in your context window
- url: https://neovim.io/doc/user/lua/
  why: "nvim_win_get_cursor / nvim_win_set_cursor — confirm col is 0-indexed BYTE
        (row 1-indexed). This is the load-bearing fact: the cursor-API col aligns with S28's
        byte domain, so S29's column conversion is ±0 (only the ROW gets ±1)."
  critical: "nvim_win_set_cursor col is 0-indexed (UNLIKE vim.fn.col which is 1-indexed). Do NOT
             apply PRD §7.4's `bytecol - 1` — it double-corrects and nudges the cursor one byte
             left on every accept."

- file: plugin/lua/pi-editor/coords.lua
  why: "THE file you MODIFY. S28's byte_to_utf16/utf16_to_byte already ship here (COMPLETE) with
        a [Mode A] header (role + LIVE-VERIFIED GOTCHA list) + LuaCATS. APPEND the two wrappers
        to the SAME `local M = {}`; match its header/LuaCATS style verbatim; extend the header
        with the two new facts (cursor-API 0-based byte; PRD §7.4 -1 supersession)."
  pattern: "Stateless pure-function library: `local M = {}` + `function M.name(...)` + `return M`.
            No `M.new`, no module-level state, no setup. NEVER throws (clamp + pcall + `or ""`).
            Cites PRD §X + 'LIVE-VERIFIED' in comments. 'Node builtins analog' footer."
  gotcha: "Do NOT call vim.str_utfindex/str_byteindex directly here — ROUTE THROUGH the S28
           primitives (byte_to_utf16/utf16_to_byte). S29's ONLY new logic is row ±1 + line
           indexing + cursor-API alignment. Do NOT touch/modify the existing S28 functions or
           their tests (non-regression). Lua arrays are 1-based: pi cursorLine is 0-based, so
           index `lines[row]` (nvim) / `lines[cursorLine + 1]` (pi); guard with `or ''`."

- file: plan/001_c56962b4fa17/architecture/external_deps.md
  why: "§1.1 gives the verified 3-arg `\"utf-16\"` str-fn recipe (what S28 wraps); §1.2 gives the
        Buffer/Window/Cursor API index table that S29 implements — esp. the row 'nvim_win_get_cursor
        row 1-indexed, col 0-indexed byte' vs 'pi cursorLine 0-indexed' rows. This is the source
        of the ±0-column / ±1-row decision and the PRD §7.4 -1 supersession."
  section: "§1.1 (String Index Conversion) + §1.2 (Buffer/Window/Cursor API)"
  gotcha: "§1.2 note verbatim: 'nvim_win_set_cursor col is 0-indexed (unlike vim.fn.col which is
           1-indexed).' That is the fact PRD §7.4's -1 contradicts; follow §1.2."

- file: plugin/tests/coords_spec.lua
  why: "THE plenary spec you MODIFY. APPEND a new `describe(\"pi-editor.coords nvim_to_pi_coords /
        pi_to_nvim_coords\", …)` block; do NOT edit the 19 existing S28 assertions (non-regression).
        Mirror its describe/it/assert.are.equals style; pure functions → NO setup/teardown/buffer."
  pattern: "describe → it → assert.are.equals(expected, actual). Group: round-trip, row ±1, exact
            values, EOL, lines pass-through, never-throws, surface."

- file: plugin/tests/coords_smoke.lua
  why: "THE plenary-FREE smoke you MODIFY. APPEND headline wrapper checks (no plenary): astral
        round-trip, row ±1, EOL, never-throws on empty lines. Uses the existing `check(cond,msg)` /
        `fails` tally / `vim.cmd('cquit 1')` helpers — ADD to them, don't rewrite."
  pattern: "`local function check(cond, msg) if not cond then io.stderr:write('FAIL: '..msg..'\\n');
            fails=fails+1 end end` … `if fails>0 then vim.cmd('cquit 1') end; io.stdout:write('SMOKE_PASS\\n')`."

- file: plan/001_c56962b4fa17/P2M6T17S28/PRP.md
  why: "The SIBLING PRP (S28, COMPLETE). It established the EXACT conventions to match: the [Mode A]
        header discipline, the 'document every refinement over PRD' pattern (S28 superseded the
        v1 codepoint≈utf16 approximation + utf16_len_of_prefix; S29 supersedes PRD §7.4's -1), the
        pure-function-library contract, the LuaCATS density, the test-matrix rigor, and the
        'LIVE-VERIFIED, not assumed' bar."
  pattern: "Read S28's PRP 'All Needed Context' + 'Implementation Blueprint' + 'Validation Loop' —
            S29 mirrors them at the wrapper layer."

- docfile: PRD.md
  why: "§8 (Coordinate & Encoding Contract — the requirement source; the units + the centralization
        mandate) and §7.4 (Accept flow step 1-4 — the -1 supersession TARGET)."
  section: "§8 (heading:h2.8); §7.4 (heading:h3.20)"
  gotcha: "PRD §8 table calls the byte col '1-indexed' and §7.4 step 4 says `bytecol - 1`. Both are
           superseded by external_deps.md §1.2 (LIVE-VERIFIED): the cursor-API col is 0-indexed byte,
           so S29 uses ±0 on the column. Document this in the coords.lua header."
```

### Current Codebase tree (run `tree` in the root of the project) to get an overview of the codebase

```bash
$ cd /home/dustin/projects/pi-nvim-bridge && tree -L 3 plugin plan/001_c56962b4fa17/architecture
plugin
├── ftplugin/pi-prompt.lua                 # buffer-local setup (S22, COMPLETE)
├── lua/pi-editor/
│   ├── bridge.lua                         # socket client + handshake + RPC (S24-S27, COMPLETE)
│   ├── coords.lua                         # ★ THIS FILE — S28 primitives COMPLETE; APPEND S29 wrappers
│   ├── init.lua                           # setup() + VimEnter gate (S19-S21, COMPLETE)
│   └── jsonlreader.lua                    # JSONL framing (S23, COMPLETE)
├── plugin/pi-editor.lua                   # VimEnter auto-activation shim (S20, COMPLETE)
└── tests/
    ├── coords_smoke.lua                   # ★ APPEND S29 smoke checks (S28's are here)
    ├── coords_spec.lua                    # ★ APPEND S29 describe block (S28's 19 asserts are here)
    ├── minimal_init.lua                   # plenary harness (S19; reused UNCHANGED)
    └── … (bridge/ftplugin/init/jsonlreader/shim/activate specs + smokes — all COMPLETE)
plan/001_c56962b4fa17/architecture/
├── external_deps.md                       # §1.1 (str-fn recipe) + §1.2 (cursor-API index table) — READ
├── research-pi-autocomplete.md
├── research-pi-extension-api.md
└── system_context.md
```

### Desired Codebase tree with files to be added and responsibility of file

```bash
plugin/lua/pi-editor/coords.lua            # MODIFIED — +2 wrapper fns (nvim_to_pi_coords, pi_to_nvim_coords)
plugin/tests/coords_spec.lua               # MODIFIED — +1 describe block (wrappers); S28 asserts unchanged
plugin/tests/coords_smoke.lua              # MODIFIED — +headline wrapper smoke checks
# (NO new files. NO other module touched.)
```

### Known Gotchas of our codebase & Library Quirks

```lua
-- CRITICAL (the headline refinement): PRD §7.4 step 4 says `nvim_win_set_cursor(0, {row, bytecol - 1})`.
-- That -1 is an ERROR under this design. The 3-arg "utf-16" overload (what S28 wraps) is 0-based in →
-- 0-based out, AND nvim_win_set_cursor's col is 0-indexed BYTE (external_deps.md §1.2, LIVE-VERIFIED).
-- So pi_to_nvim_coords returns a 0-based byte col and the caller passes it UNCHANGED (no -1). Applying
-- PRD §7.4's -1 would nudge the cursor one byte LEFT on every accept — worst on multibyte lines.
-- S29 FOLLOWS external_deps.md §1.2 over PRD §7.4. DOCUMENT the supersession in the coords.lua header
-- (the S28 PRP pattern: 'a reader of PRD §7.4 should not be surprised by the absence of the -1').

-- CRITICAL: ROUTE THROUGH S28. Do NOT call vim.str_utfindex / vim.str_byteindex directly in the wrappers
-- — call M.byte_to_utf16 / M.utf16_to_byte (the centralized seam). S29's ONLY new math is row ±1 +
-- line indexing. (Anti-Pattern: bypassing S28 re-fragments the conversion PRD §8 centralizes.)

-- CRITICAL: Lua arrays are 1-BASED; pi cursorLine is 0-BASED. So read nvim's line as lines[row]
-- (row already 1-based) and pi's line as lines[cursorLine + 1] (0-based → 1-based). ALWAYS guard
-- the line access with `or ""` so a missing/out-of-range line degrades to "" (→ col 0) instead of
-- throwing — coords is called per-keystroke from completion; a throw would abort completion.

-- ROW is NOT clamped (by design): cursorLine = row - 1 passes through even for an out-of-range row.
-- A real nvim cursor is always in range; clamping the row would hide caller bugs. The LINE access
-- (`or ""`) is the defensive boundary, not the row. (Verified: nvim_to_pi_coords({}, 5, 9) → no throw.)

-- 0-BASED COLUMN BOTH WAYS, ±0: nvim_win_get_cursor col (0-based byte) → byte_to_utf16 → pi cursorCol
-- (0-based utf16); pi cursorCol → utf16_to_byte → nvim col (0-based byte) → nvim_win_set_cursor.
-- The ONLY ±1 in the whole module is the ROW. (S28 deliberately left the row ±1 to S29; S28 is
-- string-level ±0. This alignment is the designed seam — not luck.)

-- NEVER THROWS (per-keystroke contract): type-guard `lines` (non-table → treat as {}), guard each line
-- access with `or ""`, and rely on S28's already-never-throws primitives. pcall-safety is inherited
-- from S28; do NOT add a pcall layer that swallows real bugs (S28's primitives already degrade).

-- PURE FUNCTIONS, explicit args: do NOT read the buffer/cursor inside the wrappers (no nvim_win_get_cursor,
-- no nvim_buf_get_lines). The CALLER (completion S30 / accept S32) does the buffer I/O and passes
-- (lines, row/col) in. This keeps coords.lua testable with NO buffer (the spec calls the fns directly)
-- and matches S28's stateless pure-function philosophy. Returning a TABLE with `lines` pass-through lets
-- the caller `vim.tbl_extend("keep", pi, {force=...})` straight into the RPC params.

-- NON-REGRESSION: S28's byte_to_utf16/utf16_to_byte + their 19 spec assertions + the smoke checks are
# COMPLETE and GREEN. APPEND only — do not edit S28's functions, docstrings, or assertions.
```

## Implementation Blueprint

### Data models and structure

No external data model — the wrappers operate on plain Lua values and return plain tables.
Define the two return shapes inline in the LuaCATS (match S28's annotation style):

```lua
--- Result of nvim_to_pi_coords: nvim-native cursor → pi-native. `lines` is pass-through
--- (same reference) so the table drops straight into a getSuggestions RPC params object.
---@class pi-editor.PiCoords
---@field lines string[] The buffer lines (UNCHANGED — same reference as the input).
---@field cursorLine integer 0-indexed line (pi's unit) == nvim row - 1.
---@field cursorCol  integer 0-indexed UTF-16 code-unit offset (pi's cursorCol unit).

--- Result of pi_to_nvim_coords: pi-native cursor → nvim-native. `lines` is pass-through.
---@class pi-editor.NvimCoords
---@field lines string[] The buffer lines (UNCHANGED — same reference as the input).
---@field row integer 1-indexed nvim row == pi cursorLine + 1 (for nvim_win_set_cursor[1]).
---@field col integer 0-indexed BYTE offset (for nvim_win_set_cursor[2] — NO `-1`; see header).
```

### Implementation Tasks (ordered by dependencies)

```yaml
Task 1: READ (do NOT edit yet) — anchor on S28 + the verified recipe
  - READ: plugin/lua/pi-editor/coords.lua  (the file you MODIFY; S28's [Mode A] header + primitives)
  - READ: plan/001_c56962b4fa17/architecture/external_deps.md §1.1 + §1.2  (the str-fn recipe + cursor-API index table)
  - READ: plugin/tests/coords_spec.lua + plugin/tests/coords_smoke.lua  (the test files you APPEND to)
  - SKIM: plan/001_c56962b4fa17/P2M6T17S28/PRP.md  (the conventions to mirror at the wrapper layer)
  - WHY: locks the conversion contract (±0 column / ±1 row / no-`-1`) + the header/LuaCATS/test
         discipline before writing. Every value below was LIVE-VERIFIED on nvim 0.12.4.

Task 2: MODIFY plugin/lua/pi-editor/coords.lua — ADD nvim_to_pi_coords
  - IMPLEMENT: function M.nvim_to_pi_coords(lines, row, byte_col) returning
      { lines = lines, cursorLine = row - 1, cursorCol = M.byte_to_utf16(line, byte_col) }
      where line = (lines or {})[row] or ""   (Lua 1-based array; nvim row already 1-based; guard missing)
  - ROUTE THROUGH S28: call M.byte_to_utf16 (NOT vim.str_utfindex). Column math is ±0.
  - NEVER THROWS: type-guard `lines` (non-table → {}); the `or ""` line guard; S28's primitive is already
      never-throws. Do NOT add a pcall that hides bugs.
  - ADD LuaCATS: @param lines string[]; @param row integer (1-indexed nvim row); @param byte_col integer
      (0-indexed byte, as from nvim_win_get_cursor[2]); @return pi-editor.PiCoords. Match S28's density.
  - NAMING: M.nvim_to_pi_coords (snake_case module method on the existing M table).
  - PLACEMENT: directly BELOW M.utf16_to_byte (keep the two S28 primitives together at top; wrappers after).
  - DEPENDENCIES: M.byte_to_utf16 (S28, already in this module — same file, no new require).

Task 3: MODIFY plugin/lua/pi-editor/coords.lua — ADD pi_to_nvim_coords (the inverse)
  - IMPLEMENT: function M.pi_to_nvim_coords(lines, cursorLine, cursorCol) returning
      { lines = lines, row = cursorLine + 1, col = M.utf16_to_byte(line, cursorCol) }
      where line = (lines or {})[cursorLine + 1] or ""   (pi cursorLine 0-based → Lua 1-based; guard missing)
  - ROUTE THROUGH S28: call M.utf16_to_byte (NOT vim.str_byteindex). col is 0-based byte — NO `-1`.
  - NEVER THROWS: same guards as Task 2.
  - ADD LuaCATS: @param lines string[]; @param cursorLine integer (0-indexed pi line);
      @param cursorCol integer (0-indexed UTF-16, pi's unit); @return pi-editor.NvimCoords.
  - NAMING/PLACEMENT: M.pi_to_nvim_coords, directly below nvim_to_pi_coords.
  - DEPENDENCIES: M.utf16_to_byte (S28).

Task 4: MODIFY plugin/lua/pi-editor/coords.lua — EXTEND the [Mode A] header
  - ADD two new GOTCHA/fact entries to the header comment block (do NOT remove/edit S28's entries):
      (a) "CURSOR-API COL IS 0-BASED BYTE (external_deps.md §1.2, LIVE-VERIFIED): nvim_win_get_cursor
          returns {row 1-indexed, col 0-indexed byte}; nvim_win_set_cursor takes the same. So the
          column conversion is ±0 — S28's byte domain aligns with the cursor API. The ONLY ±1 is the ROW."
      (b) "PRD §7.4 `bytecol - 1` IS SUPERSEDED: under the exact-UTF-16 + 0-based-byte-API design it
          double-corrects (cursor one byte left on every accept). S29 follows external_deps.md §1.2.
          A reader of PRD §7.4 should not be surprised by the absence of the -1 — that is why this note exists."
          (mirror S28's utf16_len_of_prefix supersession note verbatim in spirit).
  - ADD a one-line role update to the header's opening: "…+ the S29 row/col wrappers
      (nvim_to_pi_coords / pi_to_nvim_coords) that compose these primitives with the nvim↔pi row ±1
      and cursor-API alignment — THE public nvim↔pi cursor API for S30+ completion / S32 accept."
  - ADD the two @class blocks (pi-editor.PiCoords / pi-editor.NvimCoords) near the top (by the module doc).

Task 5: MODIFY plugin/tests/coords_spec.lua — APPEND the wrapper describe block
  - APPEND: describe("pi-editor.coords nvim_to_pi_coords / pi_to_nvim_coords", function() … end)
      as a NEW top-level describe (sibling to the existing "pi-editor.coords" S28 describe). Do NOT
      edit the 19 existing S28 assertions.
  - COVER (LIVE-VERIFIED values — research/notes.md §4):
      * surface: both are functions.
      * round-trip: pi_to_nvim_coords(nvim_to_pi_coords(L,r,c)).{row,col} == {r,c} for
        {"hello"}@1,3 / {"héllo"}@1,3 / {"日本語"}@1,3 / {"a😀b"}@1,1 / {"a😀b"}@1,5 / {"héllo","line2"}@2,2.
      * row ±1: nvim_to_pi_coords({"x","y"},2,0).cursorLine==1; pi_to_nvim_coords({"x","y"},1,0).row==2.
      * exact: nvim_to_pi_coords({"héllo"},1,3).cursorCol==2; nvim_to_pi_coords({"a😀b"},1,5).cursorCol==3;
        pi_to_nvim_coords({"a😀b"},0,3).col==5 (the no-`-1` headline).
      * EOL: nvim_to_pi_coords({"héllo"},1,6).cursorCol==5; round-trip → col==6.
      * lines pass-through: local L={}; assert(coords.nvim_to_pi_coords(L,1,0).lines == L) (same ref);
        same for pi_to_nvim_coords.
      * never-throws + line guard: assert.has_no.errors on nvim_to_pi_coords({},5,9) &
        pi_to_nvim_coords({},9,9); assert their cursorCol/col == 0 (missing line → "" → 0);
        non-table lines (nil) degrades (no throw).
  - STYLE: assert.are.equals(expected, actual); describe/it nesting like the S28 block.
  - PLACEMENT: after the existing S28 describe, before the final `});` / EOF.
  - COVERAGE: every Success Criterion above maps to ≥1 assertion.

Task 6: MODIFY plugin/tests/coords_smoke.lua — APPEND headline wrapper checks
  - APPEND (no plenary; reuse the file's existing `check`/`fails` helpers — ADD to them, don't rewrite):
      * astral round-trip: pi_to_nvim_coords(nvim_to_pi_coords({"a😀b"},1,5)).col == 5  AND
        nvim_to_pi_coords({"a😀b"},1,5).cursorCol == 3.
      * row ±1: nvim_to_pi_coords({"x","y"},2,0).cursorLine == 1.
      * EOL: nvim_to_pi_coords({"héllo"},1,6).cursorCol == 5.
      * never-throws: pcall(nvim_to_pi_coords, {}, 5, 9) and pcall(pi_to_nvim_coords, {}, 9, 9) are truthy.
  - KEEP the trailing `if fails > 0 then … cquit 1 end; io.stdout:write("SMOKE_PASS\n")` intact.
  - RUN: `cd plugin && nvim --headless --clean -u NORC +"luafile tests/coords_smoke.lua" +qa` → SMOKE_PASS / exit 0.
```

### Implementation Patterns & Key Details

```lua
-- === nvim_to_pi_coords — the canonical composition (PATTERN, not copy-paste; match S28's style) ===
-- Routes through S28 (byte_to_utf16); row ±1 is the ONLY index arithmetic; column is ±0; never throws.
---@param lines    string[] Buffer lines (as from nvim_buf_get_lines(0,0,-1,false)).
---@param row      integer  1-indexed nvim row (nvim_win_get_cursor(0)[1]).
---@param byte_col integer  0-indexed BYTE offset (nvim_win_get_cursor(0)[2]) — NO ±1.
---@return pi-editor.PiCoords
function M.nvim_to_pi_coords(lines, row, byte_col)
  if type(lines) ~= "table" then lines = {} end          -- never-throws (non-table → safe)
  local r = (type(row) == "number") and row or 1
  local line = lines[r] or ""                            -- Lua 1-based; guard missing line (→ "" → col 0)
  return {
    lines      = lines,                                  -- pass-through (same reference)
    cursorLine = r - 1,                                  -- nvim row 1-based → pi 0-based (the ONLY ±1)
    cursorCol  = M.byte_to_utf16(line, byte_col),        -- S28 primitive; ±0 on the column
  }
end

-- === pi_to_nvim_coords — the exact inverse (PATTERN) ===
-- col is 0-based byte, ready for nvim_win_set_cursor UNCHANGED. NO `-1` (PRD §7.4 superseded — see header).
---@param lines      string[] Buffer/result lines.
---@param cursorLine integer  0-indexed pi line.
---@param cursorCol  integer  0-indexed UTF-16 offset (pi's cursorCol unit).
---@return pi-editor.NvimCoords
function M.pi_to_nvim_coords(lines, cursorLine, cursorCol)
  if type(lines) ~= "table" then lines = {} end          -- never-throws
  local cl = (type(cursorLine) == "number") and cursorLine or 0
  local line = lines[cl + 1] or ""                       -- pi 0-based → Lua 1-based; guard missing
  return {
    lines = lines,                                       -- pass-through (same reference)
    row   = cl + 1,                                      -- pi 0-based → nvim 1-based (the ONLY ±1)
    col   = M.utf16_to_byte(line, cursorCol),            -- S28 primitive; 0-based byte (NO -1)
  }
end

-- === CALLER pattern (for FUTURE S30 completion / S32 accept — NOT implemented here) ===
-- completion (nvim → pi):
--   local cur   = vim.api.nvim_win_get_cursor(0)             -- {row 1-based, col 0-based byte}
--   local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
--   local pi    = coords.nvim_to_pi_coords(lines, cur[1], cur[2])
--   bridge.request("getSuggestions",
--     vim.tbl_extend("keep", pi, { force = force }), cb)     -- {lines, cursorLine, cursorCol, force?}
-- accept (pi → nvim):
--   local nv = coords.pi_to_nvim_coords(result.lines, result.cursorLine, result.cursorCol)
--   vim.api.nvim_buf_set_lines(0, 0, -1, false, nv.lines)
--   vim.api.nvim_win_set_cursor(0, { nv.row, nv.col })       -- NO -1 (PRD §7.4 superseded)
```

### Integration Points

```yaml
MODULE (coords.lua):
  - append: "two functions (nvim_to_pi_coords, pi_to_nvim_coords) + two @class blocks to the EXISTING
    local M = {} table; extend the [Mode A] header with the cursor-API-0-based-byte fact + the
    PRD §7.4 -1 supersession note. NO new file. NO change to S28's primitives."

CALLERS (FUTURE — do NOT implement in S29; just design the signatures to serve them):
  - S30 completion: "calls nvim_to_pi_coords(lines, nvim_win_get_cursor[1], nvim_win_get_cursor[2]);
    passes the result (lines/cursorLine/cursorCol) into getSuggestions RPC params."
  - S32 accept: "calls pi_to_nvim_coords(applyResult.lines, applyResult.cursorLine, applyResult.cursorCol);
    applies nv.lines via nvim_buf_set_lines and {nv.row, nv.col} via nvim_win_set_cursor (NO -1)."
  - blink/cmp sources: "reuse the same wrappers (the plugin exposes require('pi-editor.coords'))."

NO INTEGRATION with: init.lua, bridge.lua, jsonlreader.lua, the ftplugin, menu.lua (S34+), or any
config/settings. coords.lua remains a self-contained, dependency-free pure-function library.
```

## Validation Loop

> Reuses `plugin/tests/minimal_init.lua` (S19) unchanged. nvim 0.12.4 verified. Plenary at
> `/home/dustin/.local/share/nvim/lazy/plenary.nvim`. Run all commands from the `plugin/` dir.

### Level 1: Syntax & Style (Immediate Feedback)

```bash
# Load-check the modified module (catches syntax/LuaCATS errors instantly) — headless, no plenary.
cd /home/dustin/projects/pi-nvim-bridge/plugin
nvim --headless --clean -u NORC \
  -c 'set rtp+=.' \
  -c 'lua local c=require("pi-editor.coords"); assert(type(c.nvim_to_pi_coords)=="function" and type(c.pi_to_nvim_coords)=="function")' \
  -c 'qa'
echo "exit=$?   # 0 = module loads + both exports present"
# Expected: exit 0. If non-zero, READ the nvim stderr (syntax/typo/LuaCATS) and fix before proceeding.

# Optional lint (the repo lints Lua ad-hoc — match the S28 PRP: rely on the load + spec; luacheck if present):
luacheck lua/pi-editor/coords.lua --std luajit 2>/dev/null || true
```

### Level 2: Unit Tests (Component Validation)

```bash
cd /home/dustin/projects/pi-nvim-bridge/plugin

# 2a. Plenary-FREE smoke (instant, the S28 gate extended) — APPENDED wrapper checks must pass.
nvim --headless --clean -u NORC +"luafile tests/coords_smoke.lua" +qa
echo "exit=$?   # 0 + prints SMOKE_PASS"
# Expected: SMOKE_PASS / exit 0.

# 2b. Plenary/busted spec — the APPENDED describe block + all 19 prior S28 assertions green.
nvim --headless --clean -u tests/minimal_init.lua \
  -c 'lua require("plenary.busted").run("tests/coords_spec.lua")'
echo "exit=$?"
# Expected: "Success: <19 + new>" / "Failed: 0" / "Errors: 0" / exit 0. The new nvim_to_pi_coords /
# pi_to_nvim_coords assertions appear in the Success list; the 19 S28 assertions are unchanged.

# If failing: READ the failing assertion name + actual vs expected, debug root cause, fix implementation
# (do NOT weaken the assertion — the values are LIVE-VERIFIED).
```

### Level 3: Integration Testing (System Validation)

```bash
cd /home/dustin/projects/pi-nvim-bridge/plugin

# 3a. Non-regression — run EVERY prior spec to confirm S29's append didn't break siblings.
for spec in tests/init_spec.lua tests/shim_spec.lua tests/activate_spec.lua tests/ftplugin_spec.lua \
            tests/jsonlreader_spec.lua tests/bridge_spec.lua tests/coords_spec.lua; do
  echo "--- $spec ---"
  nvim --headless --clean -u tests/minimal_init.lua -c "lua require('plenary.busted').run('$spec')"
done
echo "exit=$?"
# Expected: each spec "Failed: 0 / Errors: 0"; coords_spec.lua shows 19 prior + new S29 assertions.

# 3b. End-to-end conversion sanity (live round-trip over real nvim str fns — proves the composition
# matches research/notes.md §4). Headless, no plenary; mirrors the verify_wrap.lua script.
nvim --headless --clean -u NORC +"luafile /dev/stdin" +qa <<'LUA'
local c = require("pi-editor.coords"); vim.cmd("set rtp+="..vim.fn.fnamemodify(debug.getinfo(1,'S').source:sub(2), ":h:h"))
-- (rtp already set above via -c in real runs; this inline is illustrative)
local pi = c.nvim_to_pi_coords({"a😀b"}, 1, 5)
assert(pi.cursorLine==0 and pi.cursorCol==3, "astral nvim->pi")
local nv = c.pi_to_nvim_coords(pi.lines, pi.cursorLine, pi.cursorCol)
assert(nv.row==1 and nv.col==5, "astral pi->nvim round-trip (NO -1)")
io.stdout:write("E2E_PASS\n")
LUA
echo "exit=$?"
# Expected: E2E_PASS / exit 0 (astral round-trip exact; col==5, NOT 4 — proves the no-`-1` decision).
```

### Level 4: Creative & Domain-Specific Validation

```bash
# No external/creative tooling for this layer (coords.lua is pure Lua; no sockets, no buffers, no UI).
# Domain-specific validation IS the round-trip exactness across encodings (Level 2/3 cover it):
#   ASCII / BMP-Latin (é) / BMP-CJK (日本語) / astral (😀 surrogate pair) / multi-line / EOL-cursor.
# The astral case is the headline: 😀 must count as 2 UTF-16 units (native via S28), and the inverse
# must return the EXACT byte col with NO -1. If a future pi change alters cursorCol's unit, the fix is
# ONE module (coords.lua) — re-run Levels 1-3.

# Optional: confirm the Neovim version floor (the 3-arg "utf-16" overload S28 uses needs >= 0.11).
nvim --version | head -1   # 0.12.4 verified; document the >= 0.11 floor in the header if not already.
```

## Final Validation Checklist

### Technical Validation

- [ ] Level 1 load-check exits 0 (module loads; both exports are functions).
- [ ] Level 2a smoke prints `SMOKE_PASS` / exit 0 (APPENDED wrapper checks pass).
- [ ] Level 2b plenary spec: `Success: <19 + new>` / `Failed: 0` / `Errors: 0` / exit 0.
- [ ] Level 3a non-regression: every prior spec still `Failed: 0 / Errors: 0`.
- [ ] Level 3b E2E round-trip prints `E2E_PASS` (astral col==5, NOT 4).
- [ ] No syntax/lint errors blocking module load.

### Feature Validation

- [ ] All Success Criteria from "What" section met (both functions exist; round-trip exact across
      ASCII/BMP/CJK/astral/multi-line/EOL; row ±1; EOL maps to utf16 len + round-trips; lines
      pass-through; never-throws; column math has NO `-1`).
- [ ] Manual/live round-trip successful (Level 3b — `nvim_to_pi_coords({"a😀b"},1,5).cursorCol==3`
      and `pi_to_nvim_coords({"a😀b"},0,3).col==5`).
- [ ] The PRD §7.4 `-1` supersession is DOCUMENTED in the coords.lua header (a reader of PRD §7.4
      is not surprised by the absence of `-1`).
- [ ] Wrappers route through S28's `byte_to_utf16`/`utf16_to_byte` (no direct `vim.str_*` calls).
- [ ] Caller pattern (S30/S32) is documented in the PRP + a header/code comment so the wrappers'
      signatures demonstrably serve their future consumers.

### Code Quality Validation

- [ ] Follows existing coords.lua conventions (S28's [Mode A] header style, LuaCATS density,
      stateless pure-function-library shape, "Node builtins analog" footer, PRD §X + LIVE-VERIFIED citations).
- [ ] APPEND-only — S28's primitives + their 19 spec assertions + the existing smoke checks unchanged.
- [ ] Anti-patterns avoided (see below): no direct str-fn calls, no buffer I/O in the wrappers,
      no `-1` on the column, no row clamp that hides caller bugs, no new pcall that swallows real bugs.
- [ ] No new dependencies (pure Lua + S28 in-module + Neovim builtins only).

### Documentation & Deployment

- [ ] coords.lua header extended with the two new facts (cursor-API 0-based byte; PRD §7.4 -1 supersession)
      + a one-line role update naming the S29 wrappers as THE public nvim↔pi cursor API.
- [ ] LuaCATS `---@param`/`---@return` + the two `---@class` blocks present.
- [ ] The caller pattern (completion S30 / accept S32) documented in a code comment so the signatures'
      purpose is self-evident to the next implementer.

---

## Anti-Patterns to Avoid

- ❌ **Don't apply PRD §7.4's `bytecol - 1`.** It double-corrects under the exact-UTF-16 + 0-based-byte
  `nvim_win_set_cursor` design (cursor one byte left on every accept). Follow `external_deps.md §1.2`
  (LIVE-VERIFIED); DOCUMENT the supersession. (This is S29's headline refinement over PRD.)
- ❌ **Don't call `vim.str_utfindex`/`vim.str_byteindex` directly** in the wrappers. Route through
  S28's `byte_to_utf16`/`utf16_to_byte` — that is the centralization mandate (PRD §8 "MUST be centralized
  so the fix is one place"). S29's ONLY new math is row ±1 + line indexing.
- ❌ **Don't read the buffer/cursor inside the wrappers** (no `nvim_win_get_cursor`, no `nvim_buf_get_lines`).
  They are PURE functions over explicit `(lines, …)` args — the caller does the I/O. (Matches S28; keeps
  coords testable with no buffer.)
- ❌ **Don't clamp the ROW.** A real nvim cursor is always in range; clamping hides caller bugs. The
  `lines[idx] or ""` line guard is the defensive boundary, not the row.
- ❌ **Don't swallow real bugs with an extra pcall layer.** S28's primitives are already never-throws;
  add only the type-guard + `or ""` line guard, not a blanket pcall that masks broken callers.
- ❌ **Don't edit S28's primitives, their docstrings, or their 19 spec assertions.** APPEND only —
  non-regression is a hard gate.
- ❌ **Don't create a new module file.** Both wrappers go in the EXISTING `coords.lua` (one module,
  one centralized seam — the whole point).
- ❌ **Don't forget the Lua 1-based array vs pi 0-based cursorLine asymmetry.** `lines[row]` (nvim,
  already 1-based) vs `lines[cursorLine + 1]` (pi 0-based → 1-based). Always guard with `or ""`.

---

## Confidence Score

**9/10** for one-pass implementation success. Rationale: the prerequisite (S28) is COMPLETE and
in-tree; the conversion contract is pinned by PRD §8 + the LIVE-VERIFIED `external_deps.md §1.2`;
every assertion value was printed by nvim 0.12.4 (research/notes.md §4 + the verify_wrap.lua run);
the test harness + exact commands are verified green; and the only non-trivial decision (the
PRD §7.4 `-1` supersession) is documented with the S28 PRP's proven "refinement-over-PRD" pattern.
The one residual risk is a reviewer pushing back on the no-`-1` choice — mitigated by the explicit
header note + the LIVE-VERIFIED round-trip. (Not 10/10 only because Lua array-vs-pi-indexing is a
subtle off-by-one trap if the implementer skips the "Known Gotchas" section.)