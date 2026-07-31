# Research Notes — P2.M6.T17.S29
## `coords.lua` — `nvim_to_pi_coords()` + `pi_to_nvim_coords()` (the row/col wrappers)

Logical id **S29** ("nvim↔pi cursor coordinate wrapper functions"). Parent task
**P2.M6.T17** ("coords.lua — byte↔UTF‑16 and nvim↔pi cursor conversion"). PRP output
dir `P2M6T17S29`. **Prerequisite S28 is COMPLETE** — `byte_to_utf16`/`utf16_to_byte`
already ship in `plugin/lua/pi-editor/coords.lua` (read VERBATIM; header + LuaCATS +
the live-verified "refinement over PRD §8" decision all present). S29 composes those
primitives with the nvim↔pi row/col index arithmetic into two pure wrapper functions
that the completion/accept flow (S30+/S32) will call instead of touching the str fns.

---

## 1. The codebase state (LIVE‑READ, not assumed)

- `ls plugin/lua/pi-editor/` → `bridge.lua`, `coords.lua`, `init.lua`, `jsonlreader.lua`
  (NO `completion.lua`, NO `menu.lua` yet — those are S30+/S34+, FUTURE consumers).
- `coords.lua` EXISTS and ships exactly the two S28 primitives `byte_to_utf16` /
  `utf16_to_byte`, with a `[Mode A]` header (role + GOTCHA list, every fact LIVE‑VERIFIED
  + cited to PRD §8 / architecture external_deps.md §1.1), LuaCATS on both fns, and the
  "stateless pure‑function library — `local M = {}` + `return M`, no `M.new`, no
  module‑level state" contract. **S29 APPENDS to this same module** (does NOT create a new
  file). Match its header discipline + LuaCATS style verbatim.
- `plugin/tests/coords_spec.lua` + `plugin/tests/coords_smoke.lua` EXIST (created by S28),
  19 plenary tests green + `SMOKE_PASS`. **S29 APPENDS new `describe` blocks** to BOTH
  (non‑regression: the existing S28 assertions stay byte‑identical; S29 only ADDS blocks
  for the two new wrappers). One module → one spec file is the established organization.
- `plugin/tests/minimal_init.lua` (S19) prepends plenary (`/home/dustin/.local/share/nvim/
  lazy/plenary.nvim`) + `plugin/` to rtp; **reused UNCHANGED**. `nvim --version` = **0.12.4**.
- `.gitignore` does NOT ignore `plan/` (only `node_modules/`, `venv/`, `.pi-subagents/`, etc.).
  No `Makefile`/test runner script — tests run via direct `nvim --headless` commands.

### 1a. Consumer contract (FUTURE — what S30+/S32 will need from these wrappers)

PRD §7.4 Accept flow step 1‑4 + §8 table imply the two compositions:

```
completion (nvim → pi, for getSuggestions):
  cursor = nvim_win_get_cursor(0)          -- {row 1-based, col 0-based BYTE}
  lines  = nvim_buf_get_lines(0,0,-1,false)
  pi     = coords.nvim_to_pi_coords(lines, cursor[1], cursor[2])
  bridge.request("getSuggestions", { lines=pi.lines, cursorLine=pi.cursorLine,
                                     cursorCol=pi.cursorCol, force=... }, cb)

accept (pi → nvim, after applyCompletion):
  result = bridge.request("applyCompletion", ...)   -- {lines, cursorLine, cursorCol}
  nv     = coords.pi_to_nvim_coords(result.lines, result.cursorLine, result.cursorCol)
  nvim_buf_set_lines(0,0,-1,false, nv.lines)
  nvim_win_set_cursor(0, { nv.row, nv.col })
```

This is the **target caller pattern** S29's signatures must support. Note both wrappers
RETURN their `lines` (pass‑through) so the result drops straight into the pi RPC params /
`nvim_buf_set_lines`.

---

## 2. The conversion contract (PRD §8 table — the requirement source)

PRD §8 "Coordinate & Encoding Contract" table (heading:h2.8) — nvim → pi:

| From (nvim) | To (pi) | How |
|---|---|---|
| row `r` (1‑indexed) | `cursorLine` (0‑indexed) | `cursorLine = r - 1` |
| byte col `c` (1‑indexed) | `cursorCol` (0‑indexed UTF‑16) | `vim.str_utfindex(line, c-1)` → UTF‑16 |
| `nvim_buf_get_lines(0,0,-1,false)` | `lines` | direct (Lua↔JSON strings) |

On apply (pi → nvim): `result.cursorCol` (UTF‑16) → byte via `str_byteindex`; cursor row = `result.cursorLine + 1`.

PRD §8 also says: "**Reuse `vim.str_byteindex` / `vim.str_utfindex` … Do NOT reimplement
UTF‑8 walking by hand.**" → S29 ROUTES THROUGH S28's primitives (`byte_to_utf16` /
`utf16_to_byte`); it does NOT call the str fns directly. S29's ONLY new logic is the
**row ±1** + **line indexing** + **cursor‑API alignment**.

---

## 3. THE KEY REFINEMENT — cursor‑API columns are 0‑based BYTE (kills the PRD §7.4 `-1`)

PRD §8's table describes the byte col as **1‑indexed** (matching `vim.fn.col(".")`).
BUT the project's OWN architecture doc `external_deps.md §1.2` (LIVE‑VERIFIED on 0.12.4)
documents that the **`nvim_win_get_cursor`/`nvim_win_set_cursor` col is 0‑indexed BYTE**
(`nvim_win_get_cursor` returns `{row 1-indexed, col 0-indexed byte}`; "nvim_win_set_cursor
col is 0-indexed (unlike vim.fn.col which is 1-indexed)").

**This is the load‑bearing simplification:** because the cursor‑API col is ALREADY 0‑based
byte — the EXACT same domain S28's `byte_to_utf16` consumes and `utf16_to_byte` produces —
the column conversion is a clean `byte_to_utf16(line, col)` / `utf16_to_byte(line, col)`
with **NO ±1 on the column**. The ONLY ±1 is on the **ROW** (`row 1↔0`).

This is precisely WHY the S28 PRP chose "0‑based both ways, no ±1 at the string layer"
(documented in S28 notes §3: "the nvim CURSOR ±1 … is S29's job"). S28 deferred the row ±1
to S29 and aligned its byte domain with the cursor API's 0‑based byte col — so S29 inherits
a column‑arithmetic‑free composition. **This is not luck; it is the designed seam.**

### 3a. GOTCHA — PRD §7.4 step 4's `bytecol - 1` is an ERROR under this design (supersede it)

PRD §7.4 Accept flow step 4 says:
> "Position cursor: convert `result.cursorCol` (char index) → byte col (`vim.str_byteindex`),
>  then `vim.api.nvim_win_set_cursor(0, { result.cursorLine + 1, bytecol - 1 })`."

That `-1` **double‑corrects** when (a) the conversion is the exact 3‑arg `"utf-16"` overload
(0‑based in → 0‑based out) AND (b) the target API (`nvim_win_set_cursor`) takes a **0‑based**
byte col. Applying the PRD's `-1` would place the cursor ONE BYTE LEFT of where pi intended
on every accept — a visible wrong‑column bug, worst on multibyte lines. (It reads as if PRD
§7.4 was drafted against `vim.fn.col` 1‑based semantics + the v1 codepoint path, then not
reconciled with §8's "reuse the str fns" + the verified cursor‑API indexing.)

**DECISION (matches the S28 PRP's "document every refinement over PRD" pattern): S29 follows
`external_deps.md §1.2` (LIVE‑VERIFIED) over PRD §7.4.** The wrapper returns a 0‑based byte
col; the caller passes it to `nvim_win_set_cursor` UNCHANGED (no `-1`). Document this
prominently in the coords.lua header + the PRP so a reviewer who reads PRD §7.4 first is not
surprised by the absence of the `-1` — exactly as S28 documented the absence of
`utf16_len_of_prefix`. (Future S32 — the accept caller — must ALSO honor this; flag it there.)

---

## 4. LIVE‑VERIFIED behaviors (nvim 0.12.4, `--headless --clean -u NORC`)

Verified by `/tmp/verify_wrap.lua` (composed the proposed wrappers over real nvim str fns,
then ran the round‑trip + exact‑value + defensive matrix). Every value below was printed by
nvim, exit 0 (`VERIFY_PASS`).

### 4a. Proposed signatures (both PURE, explicit args — no buffer I/O)
```lua
-- nvim → pi: row is 1-indexed, byte_col is 0-indexed BYTE (as from nvim_win_get_cursor[2])
M.nvim_to_pi_coords(lines, row, byte_col)
  -> { lines = lines, cursorLine = row - 1, cursorCol = byte_to_utf16(lines[row], byte_col) }

-- pi → nvim: cursorLine 0-indexed, cursorCol 0-indexed UTF-16 (pi's units)
M.pi_to_nvim_coords(lines, cursorLine, cursorCol)
  -> { lines = lines, row = cursorLine + 1, col = utf16_to_byte(lines[cursorLine+1], cursorCol) }
```
(`lines[idx] or ""` guards the line access — a missing line degrades to "" → 0, never throws.
Note the Lua **1‑based array** indexing: pi `cursorLine` is 0‑based but `lines` is a Lua array
indexed from 1, so `lines[cursorLine + 1]` / `lines[row]`.)

### 4b. ROUND‑TRIP is EXACT (nvim→pi→nvim preserves the original row + 0‑based byte col)
| lines | nvim row | nvim col (0‑based byte) | → pi cursorLine | → pi cursorCol | → back nvim col |
|---|---|---|---|---|---|
| `{"hello"}` (ASCII) | 1 | 3 | 0 | 3 | 3 ✅ |
| `{"héllo"}` (BMP) | 1 | 3 (1st 'l') | 0 | 2 | 3 ✅ |
| `{"日本語"}` (CJK) | 1 | 3 (本) | 0 | 1 | 3 ✅ |
| `{"a😀b"}` (astral) | 1 | 1 (😀 start) | 0 | 1 | 1 ✅ |
| `{"a😀b"}` (astral) | 1 | 5 ('b') | 0 | 3 | 5 ✅ |
| `{"héllo","line2"}` (multi‑line) | 2 | 2 | 1 | 2 | 2 ✅ |

### 4c. EXACT known values (the headline conversion facts)
- `nvim_to_pi_coords({"héllo"}, 1, 3)` → `cursorLine=0`, `cursorCol=2` (byte 3 = 1st 'l' = utf16 2).
- `nvim_to_pi_coords({"a😀b"}, 1, 5)` → `cursorCol=3` (astral 'b': 😀 counted as 2 utf16 units).
- `pi_to_nvim_coords({"a😀b"}, 0, 3)` → `row=1`, `col=5` (the inverse — exact, 0‑based, NO `-1`).
- EOL: `nvim_to_pi_coords({"héllo"}, 1, 6)` (col = #line) → `cursorCol=5` (utf16 len); round‑trips back to `col=6`.

### 4d. NEVER THROWS + defensive (a missing line / out‑of‑range row degrades, never aborts)
- `pcall(nvim_to_pi_coords, {}, 5, 9)` → ok (no throw); `lines[6] or ""` → "" → cursorCol 0.
- `pcall(pi_to_nvim_coords, {}, 9, 9)` → ok (no throw).
- This is the per‑keystroke safety contract (completion calls nvim_to_pi_coords on every change).

> Row clamp: the verification let `cursorLine = row - 1` pass through un‑clamped (a real nvim
> cursor is always in range; clamping the ROW would hide caller bugs and isn't needed — the
> LINE access is what's guarded). The LINE access `lines[idx] or ""` is the defensive boundary.

---

## 5. Design decisions (LOCKED)

- **APPEND to EXISTING `coords.lua`** — two new functions on the SAME `local M = {}` table.
  No new module file. Reuses the S28 header block (add a new sub‑section / extend the GOTCHA
  list with the PRD §7.4 `-1` refinement + the cursor‑API‑0‑based‑byte fact).
- **PURE functions, explicit `(lines, …)` args** — NOT buffer‑reading. Matches S28's
  stateless‑pure‑function philosophy; testable with the existing plenary harness and **NO
  buffer** (the spec calls `nvim_to_pi_coords({"héllo"}, 1, 3)` directly). Keeps the
  conversion centralized + inspectable + fast (called per‑keystroke).
- **Return a TABLE** (`{lines, cursorLine, cursorCol}` / `{lines, row, col}`) so the result
  drops straight into the pi RPC params (`vim.tbl_extend("keep", pi, {force=…})`) and the
  nvim APIs (`nvim_buf_set_lines(…,nv.lines)`; `nvim_win_set_cursor(0, {nv.row, nv.col})`).
  `lines` is pass‑through (same reference) — documented.
- **Route through S28 primitives** (`byte_to_utf16`/`utf16_to_byte`) — do NOT call
  `vim.str_utfindex`/`str_byteindex` directly (Anti‑Pattern; breaks centralization). The
  wrappers are the row/col + cursor‑API‑alignment layer ONLY.
- **Row ±1, column ±0** — the ONLY index arithmetic is `cursorLine = row - 1` / `row =
  cursorLine + 1`. Column conversion is `byte_to_utf16(line, col)` / `utf16_to_byte(line, col)`
  with NO ±1 (§3 — the cursor‑API col is 0‑based byte, aligned with S28's domain).
- **NEVER throws** — `lines[idx] or ""` guards the line access; a non‑table `lines` /
  non‑number index degrades to safe defaults (row‑1 still computes; col → 0). pcall‑safe.
- **LuaCATS** on both new functions (match S28's annotation density). A new GOTCHA note
  documenting the PRD §7.4 `-1` supersession (§3a) so the absence of `-1` is intentional +
  explained.
- **Centralization statement** — S30+ completion + S32 accept MUST call THESE wrappers (not
  the str fns, not even S28's primitives directly for the cursor translation). State as the
  module's role + as an Anti‑Pattern.

---

## 6. Test matrix (APPEND to `coords_spec.lua` + `coords_smoke.lua`)

**New `describe("pi-editor.coords nvim_to_pi_coords / pi_to_nvim_coords", …)` block** —
non‑regression: the existing 19 S28 assertions stay unchanged; S29 only ADDS.

- **Round‑trip** `pi_to_nvim_coords(nvim_to_pi_coords(lines,row,col)).{row,col} == {row,col}`
  for ASCII / BMP (`héllo`) / CJK (`日本語`) / astral (`a😀b` at col 1 AND 5) / multi‑line
  (row 2) / empty single line (`{"""}`).
- **Row ±1**: `nvim_to_pi_coords({"x","y"}, 2, 0).cursorLine == 1`;
  `pi_to_nvim_coords({"x","y"}, 1, 0).row == 2`.
- **Exact conversions** (LIVE‑VERIFIED §4c): `nvim_to_pi_coords({"héllo"},1,3).cursorCol==2`;
  `nvim_to_pi_coords({"a😀b"},1,5).cursorCol==3`; `pi_to_nvim_coords({"a😀b"},0,3).col==5`.
- **EOL cursor**: `nvim_to_pi_coords({"héllo"},1,6).cursorCol==5`; round‑trip back to col 6.
- **lines pass‑through**: returned `lines` is the SAME table reference (`==` the input table).
- **Never‑throws + line guard**: `nvim_to_pi_coords({}, 5, 9)` no throw + cursorCol 0 (missing
  line → ""); `pi_to_nvim_coords({}, 9, 9)` no throw; non‑table `lines` degrades (no throw).
- **Surface**: both new exports are `function`s; `coords.nvim_to_pi_coords`/`pi_to_nvim_coords`.

**Smoke (`coords_smoke.lua`)** — APPEND headline checks (no plenary): astral round‑trip
(`a😀b` col 5 → cursorCol 3 → back to col 5), row ±1, EOL, never‑throws on empty lines.
Prints `SMOKE_PASS` / exit 0.

---

## 7. Scope boundary — S29 (wrappers) vs S28 (primitives) vs S30+ (consumers)

**S29 OWNS (this task):** the two wrapper functions in EXISTING `coords.lua` + new
`describe`/smoke blocks in the EXISTING test files. Nothing else.

**S29 does NOT (out of scope — narrow guard):**
- Read/write the buffer or cursor (that's the CALLER — completion S30 / accept S32). S29 is
  the PURE conversion; the caller does `nvim_buf_get_lines` + `nvim_win_get_cursor`, passes
  to the wrapper, and applies the wrapper's result.
- Call the bridge / issue RPCs (S30+).
- Touch `menu.lua` (S34+), `init.lua`, `bridge.lua`, `jsonlreader.lua`, or the ftplugin.
- Add `utf16_len_of_prefix` (superseded per S28 — do NOT add).
- Change S28's existing primitives or their tests (non‑regression).

**Consumers (future, MUST go through S29 — Anti‑Pattern if they don't):** S30 completion
(nvim cursor → pi `cursorLine`/`cursorCol` for `getSuggestions`); S32 accept (pi result →
nvim `nvim_win_set_cursor`, honoring the no‑`-1` refinement §3a); blink/cmp sources.

---

## 8. References (for the PRP's Documentation & References section)

- **PRD §8** (`heading:h2.8`) — the Coordinate & Encoding Contract (requirement source).
- **PRD §7.4** (`heading:h3.20`) — Accept flow step 1‑4 (the §3a `-1` supersession target).
- **`architecture/external_deps.md` §1.1 + §1.2** — the project's OWN verified recipe (3‑arg
  `"utf-16"` str fns + the cursor‑API 0‑based‑byte index table that §3 builds on).
- **S28 PRP** (`plan/001_c56962b4fa17/P2M6T17S28/PRP.md`) + **S28 notes** (sibling) — the
  "document every refinement over PRD" pattern + the exact header/LuaCATS/test discipline to
  match verbatim.
- **Neovim Lua docs** (`nvim_win_get_cursor`/`nvim_win_set_cursor` 0‑based byte col):
  https://neovim.io/doc/user/lua/