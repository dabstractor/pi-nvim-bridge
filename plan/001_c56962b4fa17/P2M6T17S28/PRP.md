---
name: "P2.M6.T17.S28 — coords.lua byte_to_utf16() / utf16_to_byte() primitives (the centralized byte↔UTF‑16 seam)"
description: |
  **CREATE `plugin/lua/pi-editor/coords.lua`** — a NEW stateless pure-function library exporting
  exactly TWO functions: `byte_to_utf16(line, byte_idx)` and `utf16_to_byte(line, utf16_idx)`.
  These are **THE centralized coordinate-conversion seam** that PRD §8 mandates ("MUST be
  centralized so the fix is one place"): every nvim↔pi translation funnels through them. The
  sibling **S29** composes them into `nvim_to_pi_coords()` / `pi_to_nvim_coords()` (the row/col
  wrappers); completion (S30+) calls those wrappers — none calls Neovim's str fns directly.
  **IMPLEMENTATION (the key refinement over PRD §8):** PRD §8 prescribes a 2-step codepoint path
  (`vim.str_utfindex(line, c-1)` → manual codepoint→UTF‑16 surrogate counting) and accepts a v1
  "codepoint≈utf16" approximation with a v1.1 `utf16_len_of_prefix` fix-up. **The project's own
  architecture doc (`plan/001_c56962b4fa17/architecture/external_deps.md` §1.1) already specifies
  the BETTER, EXACT path** — Neovim 0.11+'s 3-arg string-encoding overload — which does UTF‑16
  conversion **natively and exactly** (surrogate pairs counted as 2 units automatically):
  `byte_to_utf16` wraps `vim.str_utfindex(line, "utf-16", byte_idx)`; `utf16_to_byte` wraps
  `vim.str_byteindex(line, "utf-16", utf16_idx)`. **LIVE-VERIFIED on nvim 0.12.4** (research/notes.md §4):
  `byte_to_utf16("a😀b", 5)` == 3, `utf16_to_byte("a😀b", 3)` == 5 — astral chars handled exactly,
  supplanting the PRD's approximation + v1.1 helper in one simpler verified implementation.
  Both functions are **0-indexed both ways** (byte offset ↔ UTF‑16 code-unit offset; NO ±1 cursor
  arithmetic — that is S29's job), **never throw** (clamp input to `[0,max]` + `pcall`), and
  convert valid char-boundary positions EXACTLY (out-of-range is clamped to the nearest boundary,
  for robustness against caller off-by-ones). DELIVERABLES: (1) NEW `plugin/lua/pi-editor/coords.lua`
  (2 functions, [Mode A] header + LuaCATS); (2) NEW `plugin/tests/coords_spec.lua` (plenary/busted
  round-trip + exact-value + edge matrix); (3) NEW `plugin/tests/coords_smoke.lua` (plenary-FREE
  headless Level-1 smoke). NARROW scope guard — S28 does NOT add `nvim_to_pi_coords`/`pi_to_nvim_coords`
  (S29), call the bridge (S30+), or touch buffers/cursors (S29/S32). The 3-arg "utf-16" overload
  requires Neovim ≥ 0.11 (PRD §10.1 says "0.10+ (0.12 verified)" — the UTF‑16 path raises the
  effective floor to 0.11; document it; 0.12.4 verified).
---

## Goal

**Feature Goal**: Ship the lowest layer of the pi-editor.nvim coordinate-translation stack —
the two pure functions that convert a position within a single line between Neovim's native
unit (**byte offset**) and pi's unit (**UTF‑16 code-unit offset**, i.e. a JavaScript string
index = pi's `cursorCol`). They are the single, centralized implementation of PRD §8's
byte↔UTF‑16 contract: every nvim→pi (and pi→nvim) coordinate translation that S29/S30+/S32 will
ever do MUST route through these two functions, so the conversion — and any future fix — lives
in exactly one place. Implemented via Neovim 0.11+'s exact, native UTF‑16 string-encoding
overload (LIVE-VERIFIED on 0.12.4), which removes the PRD §8 v1 "codepoint≈utf16" approximation
and its v1.1 `utf16_len_of_prefix` fix-up entirely.

**Deliverable** (3 NEW files — the module + its two test gates):
- **NEW** `plugin/lua/pi-editor/coords.lua` — stateless pure-function library, `local M = {}`,
  exports exactly:
  - `M.byte_to_utf16(line, byte_idx) -> integer` — 0‑based byte offset → 0‑based UTF‑16 code-unit offset.
  - `M.utf16_to_byte(line, utf16_idx) -> integer` — 0‑based UTF‑16 offset → 0‑based byte offset.
  - A `[Mode A]` header (role + GOTCHA list, LIVE-VERIFIED facts cited), LuaCATS `---@param`/`---@return`
    on both functions, a "Node builtins analog" footer, and an explicit "this supersedes PRD §8's
    v1 approximation" note.
- **NEW** `plugin/tests/coords_spec.lua` — plenary/busted spec (the Level‑2 gate): round-trip
  invariant across ASCII / BMP multibyte (`é`, `日本語`) / astral (`😀`) / empty; exact known
  values; EOL-cursor (`byte_idx == #line`) cases; never-throws + clamp (negative / past-end /
  empty / non-string line).
- **NEW** `plugin/tests/coords_smoke.lua` — plenary‑FREE headless smoke (the Level‑1 gate;
  `:luafile`-sourced, prints `SMOKE_PASS` / exit 0).

> Reuses `plugin/tests/minimal_init.lua` (S19) unchanged. NO change to `init.lua`, `bridge.lua`,
> `jsonlreader.lua`, the ftplugin, or any other module. coords.lua is a NEW, self-contained,
> dependency-free file.

**Success Definition** (every assertion is LIVE‑VERIFIED — see `research/notes.md` §4 + Validation):
- **Round-trip exactness**: for every char-boundary byte index `b` in `[0, #line]`,
  `utf16_to_byte(line, byte_to_utf16(line, b)) == b` — for ASCII `hello`, BMP `héllo` / `日本語`,
  astral `a😀b`, and empty `` (LIVE-VERIFIED values in the test matrix).
- **Astral exactness (the headline)**: `byte_to_utf16("a😀b", 5)` == 3 AND `utf16_to_byte("a😀b", 3)`
  == 5 (😀 is a surrogate pair = 2 UTF‑16 units, counted natively — NOT the PRD §8 v1 approximation
  which would yield 2).
- **EOL cursor**: `byte_to_utf16("héllo", #line=6)` == 5 (the UTF‑16 length); `byte_to_utf16("a😀b", 6)` == 4.
- **Never-throws + clamp**: `byte_to_utf16("hi", -5)` == 0; `byte_to_utf16("hi", 99)` == 2;
  `utf16_to_byte("hi", 99)` == 2; `byte_to_utf16("", 0)` == 0; a non-string `line` returns 0 (no throw).
- **0-based both directions**: `byte_to_utf16("héllo", 0)` == 0 and `utf16_to_byte("héllo", 0)` == 0.
- Smoke prints `SMOKE_PASS` / exit 0; `coords_spec.lua` exits 0.
- `[Mode A]` header + LuaCATS docstrings present; the "supersedes PRD §8 v1 approximation" note present.
- Non-regression: all prior specs (init/shim/activate/ftplugin/jsonlreader/bridge) still pass unchanged.

## User Persona (if applicable)

**Target User**: A pi user editing a prompt containing non-ASCII text — accented Latin (`café`),
CJK (`日本語`), or emoji (`fix 🐛`) — in the Neovim external editor. They never see this code;
they experience it as "completion accepts at exactly the right column, even mid-multibyte line"
(pi's `applyCompletion` places the cursor exactly where it would in the TUI). A 1-off byte vs
UTF‑16 error here is a wrong-column cursor jump on every accept — visible and annoying.

**Use Case**: The coordinate-translation stack's FOUNDATION. S21 (gate) → S22 (buffer) →
S24–S27 (bridge transport) → **S28 (this: byte↔utf16 primitives)** → S29 (cursor wrappers) →
S30+ (completion uses S29 to send `getSuggestions(lines, cursorLine, cursorCol)` with a
correct UTF‑16 `cursorCol`) → S32 (accept uses S29 to turn pi's returned UTF‑16 `cursorCol`
back into a Neovim byte col for `nvim_win_set_cursor`). Without S28, S29/S30/S32 cannot exist
correctly.

**Pain Points Addressed**:
1. **Wrong-column cursor on multibyte lines** (PRD §8, "the single most error‑prone area"):
   naively equating byte index == UTF‑16 index is WRONG for any non-ASCII char (é: byte 1 vs utf16
   1 differ in offset; 😀: byte 1-4 vs utf16 1-2). S28 makes the conversion exact and centralized.
2. **Duplicated, divergent conversion logic** (the "fix is one place" mandate): without coords.lua,
   every consumer (S29, S30, S32, blink/cmp sources) would reinvent the conversion — and drift.
   S28 is the single chokepoint.
3. **Tech debt of a "v1 approximation"**: PRD §8 explicitly accepts an approximation + promises a
   v1.1 fix-up helper. S28 implements the exact path now (the architecture doc already chose it),
   deleting that debt before it ships.

## Why

- **PRD §8 is the requirement source** ("Coordinate & Encoding Contract"): it states the units
  (pi `cursorCol` = UTF‑16; nvim col = byte), the 0-based/1-based asymmetry, and the centralization
  mandate. S28 is the faithful, exact implementation of that contract.
- **The architecture doc already chose the exact path.** `architecture/external_deps.md` §1.1
  prescribes the 3-arg `"utf-16"` overload with a verified behavior table. S28 implements that
  prescription; it does NOT invent a new approach.
- **LIVE-VERIFIED, not assumed.** Every conversion value cited in this PRP was printed by
  `nvim --headless` on 0.12.4 (research/notes.md §4) — including the astral round-trip that proves
  the native overload counts surrogate pairs as 2 units.
- **Foundational + leaf.** S28 has NO upstream dependencies (no bridge, no buffer, no config) and
  is the upstream dependency of S29/S30/S32. Shipping it exactly + tested de-risks the entire
  completion-accept correctness story for every consumer.
- **Centralization pays off forever.** If a future Neovim changes the str fns (see neovim#30804),
  or if a pi change alters the cursorCol unit, the fix is ONE file.

## What

User-visible behavior: **none directly** (S28 is an internal library). Indirectly, via S29/S30/S32,
the user gets byte-exact completion acceptance on multibyte prompt lines.

Technical requirements (exact, LIVE‑VERIFIED; the API is the deliverable):
- `coords.byte_to_utf16(line, byte_idx)`:
  - Clamp `byte_idx` to `[0, #line]` (a real cursor is always in this range; the clamp is defensive).
  - `pcall(vim.str_utfindex, line, "utf-16", clamped)`; on success return the integer; on throw,
    fall back to `vim.str_utfindex(line, "utf-16")` clamped (or `#line`). Never throws.
  - Returns a 0‑based integer in `[0, utf16_len(line)]`.
- `coords.utf16_to_byte(line, utf16_idx)`:
  - Compute `utf16_len = vim.str_utfindex(line, "utf-16")` (pcall'd → 0 on throw); clamp `utf16_idx`
    to `[0, utf16_len]`.
  - `pcall(vim.str_byteindex, line, "utf-16", clamped)`; on success return the integer; on throw,
    fall back to `#line`. Never throws.
  - Returns a 0‑based integer in `[0, #line]`.
- Both: 0‑indexed inputs AND outputs (no ±1 — that is S29). Stateless (no `M.new`, no module state).
- A non-string `line` (or non-number index) degrades to a safe return (`0`) without throwing —
  the never-throws contract beats input validation here (a caller bug must not abort completion).

### Success Criteria
- [ ] `coords.lua` exports exactly `byte_to_utf16` + `utf16_to_byte` (both functions); nothing else public.
- [ ] Round-trip `utf16_to_byte(L, byte_to_utf16(L, b)) == b` for every char-boundary `b` in
      `[0, #L]`, for `L` ∈ {`hello`, `héllo`, `日本語`, `a😀b`, ``}.
- [ ] `byte_to_utf16("a😀b", 5)` == 3 (astral exactness — NOT 2).
- [ ] `utf16_to_byte("a😀b", 3)` == 5 (astral round-trip).
- [ ] `byte_to_utf16("héllo", 6)` == 5 (EOL cursor → utf16 length).
- [ ] `byte_to_utf16("a😀b", 6)` == 4 (EOL cursor on astral → utf16 length).
- [ ] `byte_to_utf16("hi", -5)` == 0 and `byte_to_utf16("hi", 99)` == 2 (clamp).
- [ ] `utf16_to_byte("hi", -5)` == 0 and `utf16_to_byte("hi", 99)` == 2 (clamp).
- [ ] `byte_to_utf16("", 0)` == 0 and `utf16_to_byte("", 0)` == 0 (empty string).
- [ ] A non-string `line` (`byte_to_utf16(nil, 0)`) returns 0 without throwing.
- [ ] Both functions are 0‑based both directions (`byte_to_utf16("héllo", 0)` == 0;
      `utf16_to_byte("héllo", 0)` == 0).
- [ ] `[Mode A]` header + LuaCATS `---@param`/`---@return` on both functions present.
- [ ] The "supersedes PRD §8 v1 approximation" + "centralized seam" notes present in the docstrings.
- [ ] Smoke (`coords_smoke.lua`) prints `SMOKE_PASS` / exit 0.
- [ ] `coords_spec.lua` exits 0 (full matrix).
- [ ] Non-regression: `init_spec` / `shim_spec` / `activate_spec` / `ftplugin_spec` /
      `jsonlreader_spec` / `bridge_spec` all still pass unchanged.

## All Needed Context

### Context Completeness Check
_Passes "No Prior Knowledge":_ an implementer needs only this PRP + `research/notes.md` + the
verified commands. The exact Neovim APIs (`vim.str_utfindex(line, "utf-16", byte_idx)` /
`vim.str_byteindex(line, "utf-16", utf16_idx)`) are quoted from the project's OWN
`architecture/external_deps.md` §1.1 AND LIVE-VERIFIED on 0.12.4 (research/notes.md §4 — every
value in the Success Criteria was printed by `nvim --headless`, not assumed). The module
conventions (`[Mode A]` header, LuaCATS, `local M = {}`/`return M`, never-throws, Node-builtins
footer) are READ VERBATIM from the sibling `bridge.lua` + `jsonlreader.lua`. The test harness
(plenary/busted via `minimal_init.lua`; plenary-FREE smoke) is reused from S19/S23/S24 and the
run command is VERIFIED green on the existing `bridge_spec.lua`. The three subtleties that make
or break this task — (1) the 3-arg `"utf-16"` overload supersedes the PRD §8 codepoint path;
(2) past-end indexes THROW (so clamp + pcall); (3) byte_idx == `#line` is a LEGAL EOL cursor
(do not clamp it away) — are all cited with verification.

### Documentation & References
```yaml
# MUST READ — PRD (read-only; the source of truth for behavior)
- url: "PRD.md §8 (heading:h2.8) — Coordinate & Encoding Contract"
  why: "THE requirement. States pi cursorCol = a JS string index (UTF-16 code units, 0-indexed);
        nvim col = a byte offset; the conversion is 'the single most error-prone area'; and
        'MUST be centralized so the fix is one place'. S28 is that centralized seam."
  critical: "PRD §8 then prescribes a CODEPOINT-intermediate path + accepts a v1 'codepoint≈utf16'
        approximation + a v1.1 utf16_len_of_prefix fix-up. S28 SUPERSEDES that with the EXACT
        native UTF-16 overload (architecture doc §1.1 + research/notes.md §1). Document the
        refinement in the docstring so a reader of PRD §8 isn't confused by the absence of
        utf16_len_of_prefix — and DO NOT add utf16_len_of_prefix (dead code)."
- url: "PRD.md §10.1 (heading:h3.26) — Prerequisites ('Neovim 0.10+ (0.12 verified)')"
  why: "The base floor. NOTE: the 3-arg 'utf-16' overload was ADDED in Neovim 0.11
        (News-0.11), so the UTF-16 path raises the effective floor to 0.11. 0.12.4 is verified."
  critical: "State the 0.11+ requirement in the docstring; 0.12.4 is the verified target."

# MUST READ — architecture (the project's OWN verified recipe — IMPLEMENT THIS, not the PRD path)
- docfile: "plan/001_c56962b4fa17/architecture/external_deps.md"
  why: "§1.1 'String Index Conversion — coords.lua' is the canonical recipe: it gives the EXACT
        3-arg calls AND a verified behavior table (héllo/日本語). §1.2 documents the cursor API
        index table S29 will compose on top of (nvim_win_get_cursor col is 0-based byte;
        vim.fn.col is 1-based byte) — S29's concern, NOT S28's, but reading it confirms S28's
        0-based string-level boundary."
  section: "§1.1 (the str calls + behavior table), §1.2 (cursor API — context only)."
  critical: "external_deps.md is the authority for the IMPLEMENTATION; PRD §8 is the authority
        for the REQUIREMENT. They agree on behavior; external_deps.md's path is exact+native."

# MUST READ — codebase conventions (READ VERBATIM — coords.lua MUST match this discipline)
- file: "plugin/lua/pi-editor/jsonlreader.lua   (S23 DONE — the style template for a pure lib)"
  why: "The closest sibling: a [Mode A] header with a GOTCHA list, `local M = {}`/`return M`,
        LuaCATS `---@param`/`---@return`, a 'Node builtins analog' footer, and a never-throws
        contract. coords.lua mirrors this shape (stateless pure functions; no M.new)."
  pattern: "Header: a one-line role + a GOTCHA list (each a LIVE-VERIFIED fact cited). Functions:
            `function M.name(self,...)` for instance OR `function M.name(...)` for pure. LuaCATS
            on every exported fn. Footer naming the Neovim builtins used."
  gotcha: "jsonlreader.lua:11 has a warning: 'Do NOT add vim.str_utfindex/utf8.len on partial
           chars — that is a BUG'. That is about STREAMING PARTIAL UTF-8 CHUNKS. coords.lua
           operates on COMPLETE buffer lines (nvim_buf_get_lines always returns valid UTF-8), so
           the str fns are SAFE here — distinguish this in the coords.lua docstring so nobody
           'fixes' a non-bug."
- file: "plugin/lua/pi-editor/bridge.lua   (S24 DONE — the [Mode A] header + LuaCATS reference)"
  why: "The richest example of the repo's documentation discipline (a ~40-line [Mode A] header
        with GOTCHAs). READ its header structure + its `---@class`/`---@field`/`---@param` style.
        NOTE: bridge.lua is a SINGLETON (module-level state) — coords.lua is NOT; it is a
        stateless pure-function library (no state, no M.new, no setup). Do not cargo-cult the
        singleton pattern."
- file: "plugin/lua/pi-editor/init.lua   (S19 DONE — the LuaCATS class-block style)"
  why: "Shows the repo's `---@class`/`---@field` annotation style for types (in case coords.lua
        wants a `---@class pi-editor.Coords` — optional; two functions may not need it)."

# MUST READ — tests (READ VERBATIM — mirror the harness + the smoke/spec split)
- file: "plugin/tests/minimal_init.lua   (S19 DONE — plenary harness; reused UNCHANGED)"
  why: "Prepends plenary + `plugin/` to rtp. Run: `cd plugin && nvim --headless --clean -u
        tests/minimal_init.lua -c 'lua require(\"plenary.busted\").run(\"tests/coords_spec.lua\")'`."
- file: "plugin/tests/bridge_spec.lua   (S24 spec — the plenary/busted PATTERN to mirror)"
  why: "Shows `describe`/`it`/`assert.are.equals`/`assert.is_true` + a `before_each`/module-reset
        structure. coords_spec mirrors it (simpler: no sockets — pure functions)."
- file: "plugin/tests/bridge_smoke.lua   (S24 smoke — the plenary-FREE Level-1 PATTERN to mirror)"
  why: "Shows the `check(cond,msg)`/`fails` tally + `vim.cmd(\"cquit 1\")` + `io.stdout:write(
        \"SMOKE_PASS\\n\")` pattern + rtp-from-`debug.getinfo`. coords_smoke mirrors it (no sockets)."

# Research (this PRP's own notes — LIVE-VERIFIED)
- docfile: "plan/001_c56962b4fa17/P2M6T17S28/research/notes.md"
  why: "The core finding (§1), codebase facts (§2), index contract (§3), the LIVE-VERIFIED
        behavior table + edge cases (§4), locked design (§5), test matrix (§6), scope boundary (§7)."
  section: "§4 (verified values — quote these in the spec asserts), §5 (locked design — the
            clamp+pcall recipe), §6 (test matrix), §7 (S28 vs S29 boundary)."
```

### Current Codebase tree (run `tree -L 3 plugin` or `find plugin -type f`)
```bash
plugin
├── ftplugin
│   └── pi-prompt.lua          # S22 (DONE) — untouched by S28
├── lua
│   └── pi-editor
│       ├── init.lua           # S19 (DONE) — untouched
│       ├── bridge.lua         # S24 (DONE) — the [Mode A] header/LuaCATS reference; untouched
│       └── jsonlreader.lua    # S23 (DONE) — the pure-lib style template; untouched
├── plugin
│   └── pi-editor.lua          # S20 (DONE) — untouched
└── tests
    ├── minimal_init.lua       # S19 (DONE) — plenary harness; reused UNCHANGED
    ├── init_spec.lua          # S19 spec (non-regression)
    ├── shim_spec.lua          # S20 spec (non-regression)
    ├── activate_spec.lua      # S21 spec (non-regression)
    ├── ftplugin_spec.lua      # S22 spec (non-regression)
    ├── jsonlreader_spec.lua   # S23 spec (non-regression)
    ├── jsonlreader_smoke.lua  # S23 smoke (the smoke PATTERN)
    ├── bridge_spec.lua        # S24 spec (non-regression) + the plenary PATTERN to mirror
    └── bridge_smoke.lua       # S24 smoke (the smoke PATTERN to mirror)
# NOTE: NO coords.lua / coords_spec.lua / coords_smoke.lua exist yet — S28 CREATES them.
```

### Desired Codebase tree with files to be added
```bash
plugin
├── lua
│   └── pi-editor
│       └── coords.lua         # NEW — byte_to_utf16 + utf16_to_byte (stateless pure lib)
└── tests
    ├── coords_spec.lua        # NEW — plenary/busted Level-2 gate (round-trip + exact + edge matrix)
    └── coords_smoke.lua       # NEW — plenary-FREE Level-1 headless smoke (prints SMOKE_PASS)
```

### Known Gotchas of our codebase & Library Quirks
```lua
-- CRITICAL (refinement over PRD §8): use the 3-arg STRING-ENCODING overload
--   `vim.str_utfindex(line, "utf-16", byte_idx)` / `vim.str_byteindex(line, "utf-16", utf16_idx)`,
--   NOT the 2-arg codepoint form PRD §8's prose describes. The string-encoding form does UTF-16
--   EXACTLY (surrogate pairs = 2 units) natively (Neovim 0.11+; verified 0.12.4). It supersedes
--   the PRD §8 v1 "codepoint≈utf16" approximation AND the v1.1 utf16_len_of_prefix helper —
--   do NOT add utf16_len_of_prefix (it would be dead code contradicting this decision).

-- GOTCHA 1 (past-end THROWS — LIVE-VERIFIED): `pcall(vim.str_utfindex, "hi", "utf-16", 99)` -> ok=FALSE
--   ("index out of range"; strict_indexing defaults true). Same for str_byteindex. => MUST clamp the
--   input to [0, max] BEFORE the call AND pcall the call. This is the load-bearing reason for the
--   never-throws contract + clamp. A real cursor is always in-range; the clamp is defensive.

-- GOTCHA 2 (byte_idx == #line is LEGAL — do NOT clamp it away): a cursor at end-of-line has byte
--   col == #line (one past the last byte). `str_utfindex("héllo", "utf-16", 6)` == 5 (the UTF-16
--   length) — this is the normal EOL case, NOT out-of-range. Clamp the UPPER bound to #line
--   (INCLUSIVE), so EOL maps to the UTF-16 length. Same for utf16_idx == utf16_len -> #line.

-- GOTCHA 3 (mid-character UTF-16 index rounds UP — LIVE-VERIFIED, a non-case): `str_byteindex(
--   "a😀b", "utf-16", 2)` (2 = the LOW surrogate) -> 5 (rounds to the NEXT codepoint's byte, not 1).
--   This is an INVALID cursor position (a cursor never points between surrogate halves) so it never
--   arises from real nvim/pi data. Document it; do NOT try to "fix" it (the result is a valid byte
--   offset; detecting mid-char adds complexity for a case that cannot occur).

-- GOTCHA 4 (UTF-16 length shortcut): `vim.str_utfindex(line, "utf-16")` with NO index returns the
--   UTF-16 LENGTH of the whole string (verified: "a😀b" -> 4). Use this for utf16_to_byte's upper
--   clamp bound; byte_to_utf16's upper clamp bound is just `#line`.

-- GOTCHA 5 (0-based BOTH directions): the str fns are documented "All indices are zero-based"
--   (neovim#32048 + Lua docs). pi cursorCol is also 0-based. So byte_to_utf16/utf16_to_byte do NO
--   ±1 arithmetic. The nvim CURSOR ±1 (row 1-based; vim.fn.col 1-based vs nvim_win_get_cursor
--   0-based byte) is S29's job — S28 is string-level only.

-- GOTCHA 6 (the jsonlreader warning does NOT apply here): jsonlreader.lua:11 warns "Do NOT add
--   vim.str_utfindex/utf8.len on partial chars — BUG". That is about STREAMING PARTIAL UTF-8 chunks
--   (a split multibyte char across socket reads). coords.lua operates on COMPLETE buffer lines
--   (nvim_buf_get_lines returns fully-formed UTF-8) — the str fns are SAFE. Distinguish in the docstring.

-- GOTCHA 7 (stateless, NOT a singleton): bridge.lua is a singleton (module-level state). coords.lua
--   is a PURE-FUNCTION library — no M.new, no module-level state, no setup. Each call is f(line,idx)
--   -> idx. Do not cargo-cult bridge.lua's state shape.

-- GOTCHA 8 (never-throws beats input validation): a non-string `line` or non-number index is a
--   caller BUG. Degrade to a safe return (0) via pcall/type-guard rather than throwing — coords is
--   called per-keystroke from completion (S30+); a throw would abort completion. (Optional: assert
--   in dev; but the shipped contract is never-throws.)

-- GOTCHA 9 (Neovim version floor): the 3-arg "utf-16" overload was ADDED in Neovim 0.11
--   (News-0.11). PRD §10.1 says "0.10+ (0.12 verified)"; the UTF-16 path raises the effective
--   floor to 0.11. Document in the docstring; 0.12.4 is the verified target.
```

## Implementation Blueprint

### Data models and structure
No data models. `coords.lua` is a stateless pure-function library: `local M = {}`, two exported
functions, `return M`. No `---@class` is strictly required (two functions), but a brief module
header docstring replaces it. No module-level mutable state. No configuration consumed.

### Implementation Tasks (ordered by dependencies)

```yaml
Task 1: CREATE plugin/lua/pi-editor/coords.lua (the module)
  - NEW file. `local M = {}`.
  - IMPLEMENT M.byte_to_utf16(line, byte_idx) -> integer:
      * guard: if type(line) ~= "string" then return 0 end  (never-throws; GOTCHA 8)
      * local n = #line
      * local b = byte_idx
      * if type(b) ~= "number" then b = 0 end
      * if b < 0 then b = 0 elseif b > n then b = n end     -- clamp [0, #line] INCLUSIVE (GOTCHA 2)
      * local ok, v = pcall(vim.str_utfindex, line, "utf-16", b)   -- 3-arg string-encoding (GOTCHA: refinement)
      * if ok and type(v) == "number" then return v end
      * -- fall back (shouldn't happen post-clamp): utf16 length of the clamped prefix
      *   local ok2, len = pcall(vim.str_utfindex, line, "utf-16"); return (ok2 and len) or n
  - IMPLEMENT M.utf16_to_byte(line, utf16_idx) -> integer:
      * guard: if type(line) ~= "string" then return 0 end
      * local ok_l, ulen = pcall(vim.str_utfindex, line, "utf-16")   -- GOTCHA 4: length shortcut
      * if not ok_l or type(ulen) ~= "number" then ulen = #line end   -- degrade (empty/odd)
      * local u = utf16_idx
      * if type(u) ~= "number" then u = 0 end
      * if u < 0 then u = 0 elseif u > ulen then u = ulen end        -- clamp [0, ulen] INCLUSIVE
      * local ok, v = pcall(vim.str_byteindex, line, "utf-16", u)    -- 3-arg string-encoding
      * if ok and type(v) == "number" then return v end
      * return #line   -- fall back (shouldn't happen post-clamp)
  - DOCSTRINGS: [Mode A] header (role + GOTCHA list, each a LIVE-VERIFIED fact cited) +
    LuaCATS `---@param`/`---@return` on BOTH functions. Include:
      * the "supersedes PRD §8 v1 approximation" note (GOTCHA: refinement) + "centralized seam" mandate;
      * the 0-based-both-ways contract + "no ±1 (that's S29)";
      * the never-throws + clamp semantics ("valid -> exact; out-of-range -> nearest boundary");
      * the jsonlreader-partial-chunk distinction (GOTCHA 6);
      * the Neovim 0.11+ requirement (GOTCHA 9).
  - FOOTER: "Node builtins analog: only `vim.str_utfindex` / `vim.str_byteindex` (both built in).
    No module-level mutable state — a pure-function library."
  - FOLLOW pattern: plugin/lua/pi-editor/jsonlreader.lua (the closest pure-lib sibling) +
    bridge.lua (the [Mode A] header reference). `local M = {}` + `return M`.
  - NAMING: `byte_to_utf16`, `utf16_to_byte` (snake_case, exact task-title names); `line`/`byte_idx`/
    `utf16_idx` params (match external_deps.md §1.1).
  - PLACEMENT: plugin/lua/pi-editor/coords.lua.

Task 2: CREATE plugin/tests/coords_spec.lua (Level-2 plenary/busted)
  - IMPLEMENT (mirror bridge_spec.lua's describe/it/assert structure; NO sockets — pure fns):
    * ROUND-TRIP: for L in {"hello","héllo","日本語","a😀b",""} do for each char-boundary byte b in
      [0,#L]: assert.are.equals(b, coords.utf16_to_byte(L, coords.byte_to_utf16(L, b))). For the
      multibyte strings, iterate the VALID char starts (héllo: 0,1,3,4,5,6; 日本語: 0,3,6,9; a😀b:
      0,1,5,6) — assert each round-trips. (The headline astral invariant.)
    * EXACT VALUES: byte_to_utf16("héllo",2)==2; byte_to_utf16("a😀b",5)==3; byte_to_utf16("日本語",3)==1;
      utf16_to_byte("héllo",2)==2; utf16_to_byte("a😀b",3)==5; utf16_to_byte("日本語",1)==3;
      byte_to_utf16("a😀b",1)==1; utf16_to_byte("a😀b",1)==1.
    * EOL CURSOR: byte_to_utf16("hello",5)==5; byte_to_utf16("héllo",6)==5; byte_to_utf16("a😀b",6)==4.
    * 0-BASED BOTH WAYS: byte_to_utf16("héllo",0)==0; utf16_to_byte("héllo",0)==0.
    * CLAMP: byte_to_utf16("hi",-5)==0; byte_to_utf16("hi",99)==2; utf16_to_byte("hi",-5)==0;
      utf16_to_byte("hi",99)==2.
    * EMPTY: byte_to_utf16("",0)==0; utf16_to_byte("",0)==0.
    * NEVER-THROWS: assert.has_no.errors on byte_to_utf16(nil,0); byte_to_utf16("hi","x");
      utf16_to_byte(nil,0); and assert byte_to_utf16(nil,0)==0.
    * SURFACE: assert.are.equals("function", type(coords.byte_to_utf16)); same for utf16_to_byte.
  - FOLLOW pattern: plugin/tests/bridge_spec.lua (S24) + jsonlreader_spec.lua (S23).
  - NAMING: describe("pi-editor.coords"); it("…") per case.
  - PLACEMENT: plugin/tests/coords_spec.lua. Reuse minimal_init.lua (S19) UNCHANGED.

Task 3: CREATE plugin/tests/coords_smoke.lua (Level-1 plenary-FREE smoke)
  - IMPLEMENT (mirror bridge_smoke.lua's check/fails/cquit/SMOKE_PASS pattern; NO sockets):
    * resolve rtp from debug.getinfo (as bridge_smoke does).
    * require("pi-editor.coords").
    * check() the headline cases: astral round-trip (byte_to_utf16("a😀b",5)==3 + utf16_to_byte
      back==5), EOL (byte_to_utf16("héllo",6)==5), clamp (byte_to_utf16("hi",99)==2), empty (==0),
      never-throws (pcall byte_to_utf16(nil,0)).
    * if fails>0 then vim.cmd("cquit 1"); else io.stdout:write("SMOKE_PASS\n").
  - RUN: cd plugin && nvim --headless --clean -u NORC +"luafile tests/coords_smoke.lua" +qa
  - PLACEMENT: plugin/tests/coords_smoke.lua.
```

### Implementation Patterns & Key Details
```lua
-- ===== plugin/lua/pi-editor/coords.lua (NEW — stateless pure-function library) =====
--- coords.lua — the CENTRALIZED byte↔UTF‑16 coordinate-conversion seam (PRD §8).
--
-- [Mode A] header — read before editing:
--  * CENTRALIZED SEAM (PRD §8 "MUST be centralized so the fix is one place"): EVERY nvim↔pi
--    coordinate translation MUST route through these two functions. Downstream (S29 wrappers,
--    S30 completion, S32 accept, blink/cmp sources) MUST `require("pi-editor.coords")` and call
--    these — they MUST NOT call vim.str_utfindex / vim.str_byteindex directly (Anti-Pattern).
--  * REFINEMENT OVER PRD §8 (LIVE-VERIFIED): PRD §8 prescribes a codepoint-intermediate path +
--    accepts a v1 "codepoint≈utf16" approximation + a v1.1 utf16_len_of_prefix fix-up. This module
--    uses Neovim 0.11+'s 3-arg STRING-ENCODING overload (vim.str_utfindex(line,"utf-16",byte_idx) /
--    vim.str_byteindex(line,"utf-16",utf16_idx)) which does UTF-16 EXACTLY (surrogate pairs = 2
--    units) natively — supplanting both the approximation AND utf16_len_of_prefix. Do NOT add
--    utf16_len_of_prefix (it would be dead code contradicting this decision). See research/notes.md §1.
--  * 0-BASED BOTH WAYS: inputs AND outputs are 0-indexed (the str fns are documented "All indices
--    are zero-based"; pi cursorCol is 0-based). NO ±1 arithmetic here — the nvim CURSOR ±1 (row
--    1-based; vim.fn.col 1-based vs nvim_win_get_cursor 0-based byte) is S29's job. S28 is
--    string-level only.
--  * NEVER THROWS + CLAMP (GOTCHA 1, LIVE-VERIFIED): past-end indexes THROW ("index out of range";
--    strict_indexing defaults true) => inputs are clamped to [0,max] AND the call is pcall'd. A
--    valid char-boundary position is converted EXACTLY; an out-of-range input is clamped to the
--    nearest boundary (defensive against caller off-by-ones; a real cursor is always in-range).
--  * byte_idx == #line is LEGAL (GOTCHA 2): the EOL cursor (byte col == #line) maps to the UTF-16
--    length — clamp the upper bound INCLUSIVE so EOL is not clamped away.
--  * MID-CHAR UTF-16 INDEX ROUNDS UP (GOTCHA 3, a non-case): a low-surrogate index (e.g. utf16=2 in
--    "a😀b") rounds to the NEXT codepoint's byte — an INVALID cursor position that never arises from
--    real nvim/pi data. Documented; not "fixed".
--  * THE JSONLREADER WARNING DOES NOT APPLY (GOTCHA 6): jsonlreader.lua:11 warns against str_utfindex
--    on PARTIAL UTF-8 chunks (a split multibyte char across socket reads). coords.lua operates on
--    COMPLETE buffer lines (nvim_buf_get_lines returns valid UTF-8) — the str fns are SAFE here.
--  * STATELESS (GOTCHA 7): a pure-function library — no M.new, no module state, no setup. Each call
--    is f(line,idx)->idx. (Contrast bridge.lua, a singleton — do not cargo-cult its state shape.)
--  * NEVER-THROWS > INPUT VALIDATION (GOTCHA 8): a non-string line / non-number index is a caller
--    bug; degrade to 0 via type-guard + pcall rather than throw (coords is called per-keystroke).
--  * VERSION (GOTCHA 9): the 3-arg "utf-16" overload was ADDED in Neovim 0.11 (News-0.11); 0.12.4
--    verified. PRD §10.1 says "0.10+ (0.12 verified)" — the UTF-16 path raises the floor to 0.11.
--
-- Node builtins analog: only `vim.str_utfindex` / `vim.str_byteindex` (both built in). No
-- module-level mutable state — a pure-function library.

local M = {}

--- Convert a 0-indexed BYTE offset in `line` to a 0-indexed UTF‑16 code-unit offset (pi's
--- `cursorCol` unit). For sending an nvim cursor position to pi (S29/S30 wrap this).
---
--- EXACT for valid char-boundary positions (incl. astral: 😀 = 2 UTF‑16 units). Out-of-range
--- `byte_idx` is clamped to `[0, #line]` (the EOL cursor `byte_idx == #line` is LEGAL and maps
--- to the UTF‑16 length). Never throws (clamp + pcall; a non-string `line` returns 0).
---
---@param line     string  A COMPLETE UTF‑8 line (as from nvim_buf_get_lines).
---@param byte_idx integer 0-indexed byte offset into `line` (`0..#line`).
---@return integer utf16_idx 0-indexed UTF‑16 code-unit offset (`0..utf16_len(line)`).
function M.byte_to_utf16(line, byte_idx)
  if type(line) ~= "string" then return 0 end          -- never-throws (GOTCHA 8)
  local n = #line
  local b = byte_idx
  if type(b) ~= "number" then b = 0 end
  if b < 0 then b = 0 elseif b > n then b = n end       -- clamp [0, #line] INCLUSIVE (GOTCHA 1/2)
  local ok, v = pcall(vim.str_utfindex, line, "utf-16", b)  -- 3-arg string-encoding (refinement)
  if ok and type(v) == "number" then return v end
  local _, len = pcall(vim.str_utfindex, line, "utf-16")    -- GOTCHA 4: length fallback
  return (type(len) == "number") and len or n
end

--- Convert a 0-indexed UTF‑16 code-unit offset (pi's `cursorCol`) to a 0-indexed BYTE offset in
--- `line`. For applying a pi result back to nvim (S29/S32 wrap this).
---
--- EXACT for valid positions (inverse of byte_to_utf16). Out-of-range `utf16_idx` is clamped to
--- `[0, utf16_len(line)]`. Never throws (clamp + pcall; a non-string `line` returns 0).
---
---@param line      string  A COMPLETE UTF‑8 line.
---@param utf16_idx integer 0-indexed UTF‑16 code-unit offset (`0..utf16_len(line)`).
---@return integer byte_idx 0-indexed byte offset (`0..#line`).
function M.utf16_to_byte(line, utf16_idx)
  if type(line) ~= "string" then return 0 end          -- never-throws (GOTCHA 8)
  local ok_l, ulen = pcall(vim.str_utfindex, line, "utf-16")  -- GOTCHA 4: utf-16 length
  if not ok_l or type(ulen) ~= "number" then ulen = #line end
  local u = utf16_idx
  if type(u) ~= "number" then u = 0 end
  if u < 0 then u = 0 elseif u > ulen then u = ulen end -- clamp [0, ulen] INCLUSIVE (GOTCHA 1/2)
  local ok, v = pcall(vim.str_byteindex, line, "utf-16", u)  -- 3-arg string-encoding (refinement)
  if ok and type(v) == "number" then return v end
  return #line                                         -- fallback (shouldn't happen post-clamp)
end

return M
```

```lua
-- ===== plugin/tests/coords_smoke.lua (NEW — plenary-FREE Level-1 headless smoke) =====
-- (skeleton — mirror bridge_smoke.lua's check/fails/cquit/SMOKE_PASS + debug.getinfo rtp)
local me = debug.getinfo(1, "S").source:sub(2)
me = vim.fn.fnamemodify(me, ":p")
local plugin_root = vim.fn.fnamemodify(me, ":h:h")
vim.opt.runtimepath:append(plugin_root)

local coords = require("pi-editor.coords")
local fails = 0
local function check(cond, msg) if not cond then io.stderr:write("FAIL: "..msg.."\n"); fails = fails + 1 end end

-- headline astral round-trip (the reason this module exists)
check(coords.byte_to_utf16("a😀b", 5) == 3, "astral byte_to_utf16 a😀b@5 == 3")
check(coords.utf16_to_byte("a😀b", 3) == 5, "astral utf16_to_byte a😀b@3 == 5")
-- EOL cursor (byte_idx == #line is legal)
check(coords.byte_to_utf16("héllo", 6) == 5, "EOL héllo@6 == 5 (utf16 len)")
check(coords.byte_to_utf16("a😀b", 6) == 4, "EOL a😀b@6 == 4 (utf16 len)")
-- clamp + empty + never-throws
check(coords.byte_to_utf16("hi", 99) == 2 and coords.byte_to_utf16("hi", -5) == 0, "clamp hi")
check(coords.byte_to_utf16("", 0) == 0 and coords.utf16_to_byte("", 0) == 0, "empty == 0")
check(pcall(coords.byte_to_utf16, nil, 0) and coords.byte_to_utf16(nil, 0) == 0, "nil line -> 0 no throw")
-- full round-trip on a multibyte line
local L = "日本語"
for _, b in ipairs({0, 3, 6, 9}) do
  check(coords.utf16_to_byte(L, coords.byte_to_utf16(L, b)) == b, "round-trip 日本語@"..b)
end

if fails > 0 then io.stderr:write(fails.." check(s) failed\n"); vim.cmd("cquit 1") end
io.stdout:write("SMOKE_PASS\n")
```

### Integration Points
```yaml
MODULE (lua/pi-editor/coords.lua — NEW, additive):
  - ADD: M.byte_to_utf16(line, byte_idx) -> integer
  - ADD: M.utf16_to_byte(line, utf16_idx) -> integer
  - NO module-level state; NO setup(); NO config consumed; NO M.new.

CONSUMERS (FUTURE — NOT wired by S28; documented so they import coords, not the str fns):
  - S29 (nvim_to_pi_coords / pi_to_nvim_coords): composes these two + the row/col ±1 arithmetic.
  - S30+ completion: uses S29 to send getSuggestions(lines, cursorLine, cursorCol=UTF16).
  - S32 accept: uses S29 to turn pi's returned UTF16 cursorCol into a byte col for nvim_win_set_cursor.
  - Anti-Pattern: any consumer calling vim.str_utfindex / vim.str_byteindex directly bypasses the
    centralization mandate (PRD §8) — reject in review.

NO: buffer/cursor reads or writes (S29/S32), bridge calls (S30+), autocmds, config, env vars,
package.json, or edits to any existing file. Pure additive new module + 2 test files.
```

## Validation Loop

### Level 1: Syntax & Style (Immediate Feedback)
```bash
# From the repo root. Lua has no project linter configured — luacheck if present, else rely on
# the nvim parser (the smoke + spec loads surface syntax/require errors immediately).
luacheck plugin/lua/pi-editor/coords.lua --no-config 2>/dev/null \
  || echo "(luacheck not installed — relying on nvim parser via smoke/spec below)"

# Headless parse check (loads the module — catches syntax/require errors immediately):
nvim --headless --clean -u NORC \
  -c "set rtp+=$(pwd)/plugin" \
  -c "lua require('pi-editor.coords')" +qa && echo "COORDS_LOADS_OK"
# Expected: COORDS_LOADS_OK. Fix any error before proceeding.

# (Optional) Stylua format if the repo adopts it later; not configured today.
```

### Level 2: Unit Tests (Component Validation)
```bash
# Level-1 smoke (plenary-FREE; fastest signal — the headline astral + clamp + EOL cases):
cd plugin && nvim --headless --clean -u NORC +"luafile tests/coords_smoke.lua" +qa
echo "exit=$?   # 0 = pass (prints 'SMOKE_PASS')"
# Expected: prints SMOKE_PASS, exit 0.

# Level-2 plenary/busted spec (the full matrix — round-trip + exact + EOL + clamp + empty + never-throws):
cd plugin && nvim --headless --clean -u tests/minimal_init.lua \
  -c 'lua require("plenary.busted").run("tests/coords_spec.lua")'
echo "exit=$?"
# Expected: exit 0, all `it` blocks green.
```

### Level 3: Integration Testing (System Validation)
```bash
# A) Prove the conversion is EXACT on real multibyte lines (no plenary — direct headless asserts):
cat > /tmp/s28_exact.lua <<'LUA'
  local c = require("pi-editor.coords")
  local function rt(L, bs)
    for _, b in ipairs(bs) do
      local u = c.byte_to_utf16(L, b); local back = c.utf16_to_byte(L, u)
      assert(back == b, ("round-trip FAIL %q @%d: byte->%d->byte->%d"):format(L, b, u, back))
    end
  end
  rt("hello", {0,1,2,3,4,5})
  rt("héllo", {0,1,3,4,5,6})      -- é = 2 bytes
  rt("日本語", {0,3,6,9})          -- 3×3-byte
  rt("a😀b", {0,1,5,6})           -- 😀 = 4 bytes = surrogate pair
  assert(c.byte_to_utf16("a😀b", 5) == 3, "astral exact (expect 3, NOT 2)")
  assert(c.byte_to_utf16("héllo", 6) == 5, "EOL cursor")
  assert(c.byte_to_utf16("hi", 99) == 2 and c.byte_to_utf16("hi", -5) == 0, "clamp")
  assert(c.byte_to_utf16(nil, 0) == 0, "nil line no-throw -> 0")
  print("COORDS_EXACT_PASS")
LUA
cd plugin && nvim --headless --clean -u NORC -c "set rtp+=$(pwd)" -c "luafile /tmp/s28_exact.lua" +qa
# Expected: COORDS_EXACT_PASS. (If astral yields 2 instead of 3, the wrong str overload was used.)

# B) Non-regression: every prior spec still green (S28 added a NEW file; nothing else changed):
cd plugin && for s in init shim activate ftplugin jsonlreader bridge; do
  nvim --headless --clean -u tests/minimal_init.lua \
    -c "lua require('plenary.busted').run('tests/${s}_spec.lua')" || echo "REGRESSION: $s"
done
# Expected: no REGRESSION lines.
```

### Level 4: Creative & Domain-Specific Validation
```bash
# The "wrong-column cursor" adversarial test — the WHOLE POINT of centralizing byte↔UTF‑16
# (PRD §8 "the single most error-prone area"). Simulate the accept path's coordinate round-trip
# on a line dense with multibyte chars; assert the byte position survives a byte->utf16->byte
# round-trip EXACTLY (a 1-off here is a wrong-column cursor jump on every completion accept).
cat > /tmp/s28_dense.lua <<'LUA'
  local c = require("pi-editor.coords")
  -- a prompt-like line: ascii + accented + CJK + emoji
  local L = "fix 🐛 in café 日本語 now"
  -- walk EVERY valid char boundary (byte offsets at codepoint starts); assert round-trip exact.
  local b = 0
  while b <= #L do
    local u = c.byte_to_utf16(L, b)
    local back = c.utf16_to_byte(L, u)
    assert(back == b, ("dense round-trip FAIL @byte %d (utf16 %d -> byte %d)"):format(b, u, back))
    -- advance to the next codepoint's byte start (decode one UTF‑8 seq):
    local fb = L:byte(b + 1) or 0
    local step = (fb < 0x80 and 1) or (fb < 0xE0 and 2) or (fb < 0xF0 and 3) or 4
    if b == #L then break end   -- EOL already covered; stop
    b = b + step
  end
  -- EOL: byte #L -> utf16 length (no throw, no clamp-away)
  assert(c.byte_to_utf16(L, #L) == c.byte_to_utf16(L, #L), "EOL stable")
  print("DENSE_ROUNDTRIP_PASS (utf16 len of dense line = " .. c.byte_to_utf16(L, #L) .. ")")
LUA
cd plugin && nvim --headless --clean -u NORC -c "set rtp+=$(pwd)" -c "luafile /tmp/s28_dense.lua" +qa
# Expected: DENSE_ROUNDTRIP_PASS. This is the real-world line completion will see.
```

## Final Validation Checklist

### Technical Validation
- [ ] Level 1: `COORDS_LOADS_OK`; luacheck clean (or n/a).
- [ ] Level 2: `coords_smoke.lua` prints `SMOKE_PASS` / exit 0.
- [ ] Level 2: `coords_spec.lua` exits 0 (round-trip + exact + EOL + clamp + empty + never-throws).
- [ ] Level 3: `COORDS_EXACT_PASS` (astral `byte_to_utf16("a😀b",5)==3` — NOT 2).
- [ ] Level 3: no `REGRESSION:` lines from the prior-spec loop.

### Feature Validation
- [ ] `coords.lua` exports exactly `byte_to_utf16` + `utf16_to_byte`.
- [ ] Round-trip `utf16_to_byte(L, byte_to_utf16(L, b)) == b` for all char-boundary `b` (ASCII/BMP/astral/empty).
- [ ] Astral exact: `byte_to_utf16("a😀b", 5)` == 3; `utf16_to_byte("a😀b", 3)` == 5.
- [ ] EOL cursor: `byte_to_utf16("héllo", 6)` == 5; `byte_to_utf16("a😀b", 6)` == 4.
- [ ] Clamp: negative -> 0; past-end -> max (`#line` / utf16 length).
- [ ] Empty string: both return 0.
- [ ] Never-throws: non-string `line` / non-number index returns 0 (no error).
- [ ] 0-based both directions (no ±1 in this layer).

### Code Quality Validation
- [ ] `[Mode A]` header (role + GOTCHA list, each a LIVE-VERIFIED fact cited).
- [ ] LuaCATS `---@param`/`---@return` on both functions.
- [ ] Stateless pure-function library (`local M = {}` + `return M`); no singleton state cargo-culted.
- [ ] Uses the 3-arg `"utf-16"` string-encoding overload (NOT the 2-arg codepoint form PRD §8 prose describes).
- [ ] The "supersedes PRD §8 v1 approximation" + "centralized seam" + jsonlreader-distinction notes present.
- [ ] NO `utf16_len_of_prefix` added (it is superseded — adding it is dead code).

### Documentation & Deployment
- [ ] Neovim 0.11+ requirement documented (the overload's floor; 0.12.4 verified).
- [ ] The 0-based-both-ways + "no ±1 (that's S29)" boundary documented.
- [ ] Anti-Pattern note: downstream consumers MUST import coords, not call the str fns directly.

---

## Anti-Patterns to Avoid

- ❌ Don't implement the PRD §8 CODEPOINT-intermediate path (`str_utfindex(line, c-1)` → manual
  surrogate counting) or add `utf16_len_of_prefix` — the 3-arg `"utf-16"` overload does UTF‑16
  EXACTLY and natively (architecture doc §1.1; LIVE-VERIFIED). The PRD's v1 approximation is
  SUPERSEDED, not "also needed".
- ❌ Don't use the 2-arg `vim.str_utfindex(line, idx)` (returns a CODEPOINT index — WRONG for
  astral chars: 😀 would count as 1, not 2 UTF‑16 units) or the OLD bool `str_byteindex(line, idx,
  true)`. Use the 3-arg STRING-ENCODING form: `str_utfindex(line, "utf-16", idx)` /
  `str_byteindex(line, "utf-16", idx)`.
- ❌ Don't add ±1 cursor arithmetic (row 1-based, `vim.fn.col` 1-based, etc.) in THIS layer — that
  is S29's job (`nvim_to_pi_coords` / `pi_to_nvim_coords`). S28 is string-level only; both offsets
  are 0-based.
- ❌ Don't skip the clamp + pcall — past-end indexes THROW (`strict_indexing` defaults true;
  LIVE-VERIFIED). The never-throws contract is load-bearing (coords is called per-keystroke).
- ❌ Don't clamp away the EOL cursor — `byte_idx == #line` is LEGAL (a cursor at end-of-line) and
  must map to the UTF‑16 length. Clamp the upper bound INCLUSIVE (`[0, #line]`).
- ❌ Don't add `nvim_to_pi_coords` / `pi_to_nvim_coords` here — that's S29. S28 ships ONLY the two
  primitives. (Narrow scope guard.)
- ❌ Don't read/write buffers or cursors, call the bridge, or touch config/autocmds — S28 is a
  pure-function library with zero side effects.
- ❌ Don't cargo-cult `bridge.lua`'s singleton module-level state — coords.lua is stateless
  (`local M = {}` + two pure functions + `return M`; no `M.new`, no `state`).
- ❌ Don't let any downstream consumer (S29/S30/S32/blink/cmp) call `vim.str_utfindex` /
  `vim.str_byteindex` directly — that violates PRD §8's centralization mandate ("the fix is one
  place"). They MUST `require("pi-editor.coords")`.
- ❌ Don't try to "fix" the mid-character (low-surrogate) UTF‑16 index rounding quirk (GOTCHA 3) —
  it is an invalid cursor position that never occurs from real data; the str fn returns a valid
  byte offset; detecting it adds complexity for a non-case.