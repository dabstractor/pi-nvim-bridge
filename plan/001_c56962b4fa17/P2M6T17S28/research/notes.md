# Research Notes — P2.M6.T17.S28
## `coords.lua` — `byte_to_utf16(line, byte_idx)` + `utf16_to_byte(line, utf16_idx)` primitives

Logical id **S28** ("byte↔UTF‑16 primitives"). Parent task **P2.M6.T17** ("coords.lua —
byte↔UTF‑16 and nvim↔pi cursor conversion"). PRP output dir `P2M6T17S28`.

S28 ships the LOWEST layer of the coordinate-translation stack: the two pure functions that
convert between a **byte offset** (Neovim/Lua's native unit) and a **UTF‑16 code‑unit offset**
(pi's `cursorCol` unit — JavaScript string indexing). These are **THE** centralized seam
PRD §8 ("MUST be centralized so the fix is one place") mandates; every nvim↔pi translation
funnels through them. The sibling **S29** composes them into `nvim_to_pi_coords()` /
`pi_to_nvim_coords()` (the row/col-indexing wrappers); completion (S30+) calls the wrappers.

---

## 1. The core finding — Neovim ships NATIVE UTF‑16 conversion (no manual surrogate math)

**PRD §8's prescribed path is OBSOLETE-able.** PRD §8 says:

> "codepoint = `vim.str_utfindex(line, c - 1)`; for full correctness convert codepoint→UTF‑16
> units (surrogates for astral plane) … For v1 it is acceptable to approximate by treating
> codepoint index == UTF‑16 index … provide a `coords.lua` helper `utf16_len_of_prefix(line,
> byte_end)` that counts surrogate pairs for full correctness as a v1.1 refinement."

**But Neovim 0.11+ added a string‑encoding overload** (News‑0.11: "`vim.str_byteindex()` and
`vim.str_utfindex()` gained overload signatures supporting two new parameters, `encoding` and
`strict_indexing`.") that does UTF‑16 conversion **natively and exactly** — surrogate pairs
are counted as 2 units automatically. The project's OWN architecture doc
(`plan/001_c56962b4fa17/architecture/external_deps.md` §1.1) already specifies this exact path:

```lua
local utf16_idx = vim.str_utfindex(line, "utf-16", byte_idx)   -- byte -> utf16
local byte_idx  = vim.str_byteindex(line, "utf-16", utf16_idx) -- utf16 -> byte
```

**DECISION: implement the EXACT path natively** (the 3‑arg `"utf-16"` overload). This
**supersedes** both the PRD §8 v1 approximation AND the v1.1 `utf16_len_of_prefix` refinement
in a single, simpler, verified implementation. Justified because: (a) the architecture doc
already mandates it; (b) it is LIVE‑VERIFIED (§4); (c) it is strictly better (exact, ~3 LOC
each, zero tech debt). **No hand‑rolled UTF‑8 walking, no surrogate counting** — the PRD §8
"do not reimplement UTF‑8 walking by hand" rule still holds; we delegate entirely to Neovim.

> Document this as a **deliberate refinement over PRD §8** in the PRP so a reviewer/implementer
> who reads PRD §8 first is not confused by the absence of `utf16_len_of_prefix`.

---

## 2. Codebase facts (LIVE‑READ, not assumed)

### 2a. NO `coords.lua` exists yet — this task CREATES the module
`ls plugin/lua/pi-editor/` → `init.lua`, `bridge.lua`, `jsonlreader.lua` (the only sibling
modules). A grep for `coords|str_utfindex|str_byteindex|utf16|utf-16` across `plugin/` returns
ONE hit: a *warning comment* in `jsonlreader.lua:11` ("Do NOT add vim.str_utfindex/utf8.len on
partial chars — that is a BUG"). That warning is about **partial UTF‑8 chunks in a streaming
buffer** and does NOT apply here: `coords.lua` operates on **complete buffer lines**
(`nvim_buf_get_lines` always returns fully‑formed UTF‑8 lines), so the functions are always
called on valid, complete UTF‑8. (Distinguish in the docstring so a future editor doesn't
"fix" a non‑bug.)

### 2b. Established module conventions (READ VERBATIM from `bridge.lua` / `jsonlreader.lua`)
Every Lua module in this repo follows the same discipline — `coords.lua` MUST match:
- **`[Mode A] header`**: a top block comment with a one‑line role + a GOTCHA list, each gotcha
  a LIVE‑VERIFIED fact with a citation (PRD §X / "LIVE‑VERIFIED"). See `bridge.lua` (~40‑line
  header) and `jsonlreader.lua` (~30‑line header).
- **`local M = {}` + `return M`** module‑table pattern; methods are `function M.name(...)`.
- **LuaCATS annotations** (`---@param`, `---@return`, `---@class`, `---@field`) on every
  exported function — the repo uses strict emmylua/lua‑cat docs (see `init.lua`'s `---@class
  pi-editor.Config` blocks).
- **"NEVER throws" contract**: every public function is `pcall`‑safe; bad args degrade to a
  sane return (never aborts the caller, which for coords is a per‑keystroke completion call).
- **Node‑builtins‑analog footer**: a comment naming the Neovim builtins used (e.g. "Neovim
  builtins analog: only `vim.str_utfindex` / `vim.str_byteindex` (both built in). No
  module‑level mutable state — a pure‑function library.").
- **PRD heading citations** like `PRD §8 (heading:h2.8)` (the S38 PRP uses `heading:h2.11`
  style — match it for `§8` → `heading:h2.8`).

### 2c. State model: PURE FUNCTION LIBRARY (NOT a singleton like bridge.lua)
Unlike `bridge.lua` (singleton transport with module‑level `state`/`pending` tables) and
unlike `jsonlreader.lua` (instance‑based `M.new`), `coords.lua` is a **stateless pure‑function
library** — no `M.new`, no module‑level mutable state, no setup. Each call is `f(line, idx) →
idx`. This is the right shape: conversion is referentially transparent and called at high
frequency (every `getSuggestions` request + every `applyCompletion` accept). Document this
explicitly so an implementer doesn't cargo‑cult the singleton pattern from bridge.lua.

### 2d. Test harness (reused UNCHANGED — same as every prior Lua task)
- **Level‑2 (plenary/busted spec)**: `cd plugin && nvim --headless --clean -u tests/minimal_init.lua
  -c 'lua require("plenary.busted").run("tests/coords_spec.lua")'`. `minimal_init.lua` (S19)
  prepends plenary + `plugin/` to rtp. Plenary at
  `/home/dustin/.local/share/nvim/lazy/plenary.nvim`. **VERIFIED** this command runs green
  on the existing `bridge_spec.lua` (11 success / 0 failed / exit 0).
- **Level‑1 (plenary‑FREE smoke)**: `cd plugin && nvim --headless --clean -u NORC
  +"luafile tests/coords_smoke.lua" +qa` → prints `SMOKE_PASS` / exit 0. Pattern from
  `bridge_smoke.lua` (S24) / `jsonlreader_smoke.lua` (S23): a `check(cond,msg)` helper that
  tallies `fails` and `vim.cmd("cquit 1")` on any fail; resolves rtp from `debug.getinfo`.
- **nvim**: 0.12.4 (`nvim --version | head -1`).
- **No selene/stylua config exists yet** (the repo lints Lua only ad‑hoc; the S38 PRP relies on
  the nvim parser + luacheck‑if‑present). Match: rely on the smoke/spec load + optional luacheck.

---

## 3. Index conventions — the contract (CRYSTAL clear; the single most error‑prone area)

`S28` is **string‑level only** — NO nvim cursor (row/col) 1‑indexing, NO pi `cursorLine`
0‑vs‑1 adjustment. That is **S29's** job (the wrappers compose S28 + the row/col arithmetic).
S28 converts a position WITHIN a single line string between two 0‑based offset units:

| Function | Input | Output | Unit notes |
|---|---|---|---|
| `byte_to_utf16(line, byte_idx)` | `byte_idx`: **0‑indexed byte offset** into `line` (`0..#line`) | **0‑indexed UTF‑16 code‑unit offset** | byte_idx == `#line` is the EOL cursor (legal) |
| `utf16_to_byte(line, utf16_idx)` | `utf16_idx`: **0‑indexed UTF‑16 code‑unit offset** (`0..utf16_len(line)`) | **0‑indexed byte offset** | utf16_idx == `utf16_len` is EOL (legal) |

**Both offsets are 0‑based.** Neovim's `str_utfindex`/`str_byteindex` are documented 0‑based
("All indices are zero‑based" — neovim/neovim#32048 + the Lua docs). pi's `cursorCol` is also
0‑based (a JS string index). So the conversion is **unit‑only** (byte ↔ utf16), with NO ±1
adjustment at this layer — that symmetry is exactly why it is testable in isolation.

> The nvim **cursor col** itself is reported 1‑based by `vim.fn.col` but **0‑based** by
> `nvim_win_get_cursor` (the `external_deps.md` §1.2 table). S29 handles that; S28 does not.

---

## 4. LIVE‑VERIFIED behaviors (nvim 0.12.4, `--headless --clean -u NORC`)

Verified by direct `nvim --headless` calls (script `/tmp/verify_utf.lua` style). Every value
below was printed by nvim, not assumed.

### 4a. The 3‑arg string‑encoding overload is supported
```
vim.str_utfindex(s, "utf-16", byte_idx) -> utf16_idx   (byte -> utf16)
vim.str_byteindex(s, "utf-16", utf16_idx) -> byte_idx  (utf16 -> byte)
vim.str_utfindex(s, "utf-16")            -> utf16_len  (NO index = full length; verified: "a😀b" -> 4)
```
Both the OLD 2‑arg (`str_utfindex(s,i)` → codepoint) and OLD 3‑arg bool (`str_byteindex(s,i,true)`)
forms ALSO still work on 0.12.4, but the string‑encoding form is what the architecture doc
mandates and what does UTF‑16 exactly. **Use the 3‑arg string‑encoding form.**

### 4b. Round‑trip is EXACT for every valid (char‑boundary) position
| String | byte_idx | `str_utfindex(_,"utf-16",_)` | `str_byteindex(_,"utf-16",back)` | rt? |
|---|---|---|---|---|
| `hello` (ASCII) | 0..5 | 0..5 | 0..5 | ✅ all |
| `héllo` (BMP, é=2 bytes=1 utf16) | 2 (1st 'l') | 2 | 2 | ✅ |
| `héllo` | `#s`=6 (EOL) | 5 (utf16 len) | — | ✅ (byte 6 → utf16 5, the EOL cursor) |
| `日本語` (BMP, 3×3 bytes) | 0,3,6,9 | 0,1,2,3 | 0,3,6,9 | ✅ all |
| `a😀b` (astral, 😀=4 bytes=2 utf16/surrogate pair) | 0 (a) | 0 | 0 | ✅ |
| `a😀b` | 1 (😀 start) | 1 | 1 | ✅ |
| `a😀b` | 5 (b) | 3 | 5 | ✅ |

**This is the proof the PRD §8 v1 "codepoint≈utf16" caveat does NOT apply** — astral chars
(😀) are counted as **2** UTF‑16 units natively (`a😀b` utf16_len=4, NOT 3).

### 4c. Edge cases — the clamping/never‑throws rationale
- **Empty string `""`**: `str_utfindex("","utf-16")`=0, `str_utfindex("","utf-16",0)`=0,
  `str_byteindex("","utf-16",0)`=0. Safe (no throw). → `byte_to_utf16("",0)`=0,
  `utf16_to_byte("",0)`=0.
- **Byte index at `#s` (EOL cursor)**: `str_utfindex("héllo","utf-16",6)`=5 (utf16 len). **Legal** —
  a cursor at end‑of‑line has byte col `#line`; it maps to the utf16 length. ✅ (do NOT clamp
  this away — it is the normal EOL case).
- **Past‑end index (byte=99 / utf16=99)**: `pcall(vim.str_utfindex,"hello","utf-16",99)` →
  **`ok=false`** (THROWS "index out of range"; `strict_indexing` defaults true). Same for
  `str_byteindex`. → **MUST pcall AND clamp** the input to `[0, max]` BEFORE calling (or wrap in
  pcall and clamp the throw to the boundary). This is the load‑bearing reason for the
  never‑throws contract + clamp.
- **Mid‑character UTF‑16 index (low surrogate)**: `str_byteindex("a😀b","utf-16",2)` → **5**
  (rounds to the NEXT codepoint's byte, not 1). This is an **invalid cursor position** (a
  cursor never points between surrogate halves) so it never occurs from real nvim/pi data.
  Document it; do NOT try to "fix" it (the result is at least a valid byte offset, and detecting
  it adds complexity for a non‑case). Confirms neovim#32048's "index in the middle of a
  sequence is rounded upwards to the end of that sequence."

### 4d. Length shortcut (used by the clamp in `utf16_to_byte`)
`vim.str_utfindex(line, "utf-16")` with **no index** returns the **UTF‑16 length** of the whole
string (verified: `"a😀b"` → 4). Use this to compute the upper clamp bound for `utf16_idx`
(`utf16_len = vim.str_utfindex(line, "utf-16")`). The upper clamp bound for `byte_idx` is simply
`#line`.

---

## 5. Design decisions (LOCKED)

- **`byte_to_utf16(line, byte_idx)`**: clamp `byte_idx` to `[0, #line]`; `pcall(vim.str_utfindex,
  line, "utf-16", clamped)`; on throw (shouldn't happen post‑clamp) fall back to the utf16
  length of the clamped prefix. Returns a 0‑indexed integer in `[0, utf16_len(line)]`.
- **`utf16_to_byte(line, utf16_idx)`**: compute `utf16_len = vim.str_utfindex(line, "utf-16")`
  (pcall'd; 0 if it throws); clamp `utf16_idx` to `[0, utf16_len]`; `pcall(vim.str_byteindex,
  line, "utf-16", clamped)`; on throw fall back to `#line`. Returns a 0‑indexed integer in
  `[0, #line]`.
- **0‑based offsets, both directions** (§3). No ±1 here — that's S29.
- **Stateless pure‑function library** (`local M = {}` + two functions + `return M`); NO `M.new`,
  NO module‑level state, NO `setup()`. (§2c.)
- **NEVER throws** (clamp + pcall on every call). A bad arg returns the nearest boundary, never
  aborts the per‑keystroke completion caller.
- **[Mode A] header + LuaCATS** on both functions (§2b). Cite PRD §8 + the refinement over the
  v1 approximation (§1). Distinguish from the jsonlreader partial‑chunk warning (§2a).
- **Centralization**: coords.lua is THE single import point. Downstream (S29 wrappers, S30+
  completion, S32 accept) MUST `require("pi-editor.coords")` and call these — they MUST NOT call
  `vim.str_utfindex`/`str_byteindex` directly. State this as an Anti‑Pattern + in the docstring.

> Clamp semantics: valid inputs (the normal case — a real cursor is always a char boundary in
> `[0, #line]` / `[0, utf16_len]`) are converted EXACTLY. Out‑of‑range inputs are clamped to the
> nearest boundary. This makes the functions defensive against off‑by‑one bugs in callers
> without ever lying about a valid position.

---

## 6. Test matrix (plenary/busted `coords_spec.lua` + smoke `coords_smoke.lua`)

**Round‑trip (the headline invariant):** for every char‑boundary byte index `b` in `[0, #line]`,
`utf16_to_byte(line, byte_to_utf16(line, b)) == b`. Assert for:
- ASCII `"hello"` (all 6 positions incl. EOL).
- BMP multibyte `"héllo"` (é = 2 bytes = 1 utf16; all positions).
- BMP CJK `"日本語"` (3×3‑byte; positions 0,3,6,9).
- Astral `"a😀b"` (😀 = surrogate pair; positions 0,1,5 — the valid char boundaries).
- Empty `""` (only position 0 → 0↔0).

**Exact known values:**
- `byte_to_utf16("héllo", 2)` == 2; `byte_to_utf16("a😀b", 5)` == 3; `byte_to_utf16("日本語",3)`==1.
- `utf16_to_byte("héllo", 2)` == 2; `utf16_to_byte("a😀b", 3)` == 5; `utf16_to_byte("日本語",1)`==3.
- `byte_to_utf16("a😀b", 1)` == 1 (😀 high surrogate start); `utf16_to_byte("a😀b", 1)` == 1.

**EOL cursor (byte_idx == #line):** `byte_to_utf16("hello", 5)` == 5;
`byte_to_utf16("héllo", 6)` == 5 (utf16 len); `byte_to_utf16("a😀b", 6)` == 4 (utf16 len).

**UTF‑16 length helper path:** the spec asserts the clamp uses `str_utfindex(line,"utf-16")`
indirectly — covered by the `utf16_to_byte` EOL + astral cases above (they exercise the length).

**Never‑throws + clamp (defensive):**
- `byte_to_utf16("hi", -5)` == 0 (clamped low); `byte_to_utf16("hi", 99)` == 2 (clamped high = utf16 len).
- `utf16_to_byte("hi", -5)` == 0; `utf16_to_byte("hi", 99)` == 2 (== #line).
- `byte_to_utf16("", 0)` == 0; `utf16_to_byte("", 0)` == 0 (empty string).
- `byte_to_utf16(nil, 0)` — bad line type → return 0 (never throws). Document: a non‑string
  `line` is a caller bug; we degrade to 0 rather than throw. (Optional assert; the never‑throws
  contract wins.)

**Non‑regression:** all prior specs (init/shim/activate/ftplugin/jsonlreader/bridge) still pass.

---

## 7. Scope boundary — S28 (primitives) vs S29 (wrappers) vs S30+ (consumers)

**S28 OWNS (this task):** the two string‑level primitives `byte_to_utf16` / `utf16_to_byte` in a
NEW `plugin/lua/pi-editor/coords.lua`, + `coords_spec.lua` + `coords_smoke.lua`. Nothing else.

**S28 does NOT (out of scope — narrow guard):**
- Add `nvim_to_pi_coords()` / `pi_to_nvim_coords()` — that is **S29** (the row 1↔0, col
  byte↔utf16, `nvim_win_get_cursor`/`set_cursor` wrappers that COMPOSE these primitives).
- Call the bridge (`getSuggestions`/`applyCompletion`) — that is S30+ completion.
- Read/write the buffer or cursor — S29/S32.
- Add a `utf16_len_of_prefix` helper — **superseded** by the native overload (§1); do NOT add it
  (it would be dead code that contradicts the "exact path" decision).

**Consumers (future, MUST go through coords — state as Anti‑Pattern):** S29 wrappers, S30
completion (cursor→pi cursorCol for `getSuggestions`), S32 accept (pi cursorCol→nvim byte col
for `nvim_win_set_cursor`). None of these call `vim.str_utfindex`/`str_byteindex` directly.

---

## 8. References (for the PRP's Documentation & References section)

- **Neovim News‑0.11** (the version the overload shipped):
  https://neovim.io/doc/user/news-0.11/ — "vim.str_byteindex() and vim.str_utfindex() gained
  overload signatures supporting two new parameters, encoding and strict_indexing." → **the
  3‑arg `"utf-16"` form requires Neovim ≥ 0.11** (PRD §10.1 says "0.10+ (0.12 verified)" — the
  3‑arg UTF‑16 path bumps the effective floor to 0.11; document it; 0.12.4 is verified).
- **Neovim Lua docs** (str_utfindex/str_byteindex, "All indices are zero-based"):
  https://neovim.io/doc/user/lua/
- **neovim/neovim#32048** (mid‑sequence rounding rule; confirms 0‑based): the discussion that
  documents "An {index} in the middle of a UTF‑8 sequence is rounded upwards."
- **neovim/neovim#30804** (future of these fns — context for why the overload exists).
- **PRD §8** (`heading:h2.8`) — the Coordinate & Encoding Contract (the requirement source;
  S28 refines its implementation per §1 above).
- **`plan/001_c56962b4fa17/architecture/external_deps.md` §1.1** — the project's OWN verified
  recipe (the 3‑arg `"utf-16"` form + the cursor‑API index table S29 will use).