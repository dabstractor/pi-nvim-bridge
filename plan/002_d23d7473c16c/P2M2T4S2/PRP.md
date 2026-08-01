name: "P2.M2.T4.S2 — fish.lua response parsing (pure-Lua `M.parse`) + AutocompleteItem/prefix verification"
description: |

  Add the pure-Lua, **fixture-testable** `complete -C` output parser to the fish
  driver (`lua/pi-bridge/shell/fish.lua`) — the §17.15-mandated parsing contract
  that is currently implemented only inside the fish DAEMON (S1) and therefore
  cannot be golden-tested without a live `fish` subprocess. Then verify the
  downstream AutocompleteItem-normalization + client-side prefix paths are correct
  for fish, and lock both with offline specs + a parser smoke.

---

## Goal

**Feature Goal**: Provide a pure-Lua, never-throws parser `M.parse(raw)` in
`lua/pi-bridge/shell/fish.lua` that maps raw fish `complete -C` output
(newline-delimited `word⇥description` lines) onto the driver's raw-item wire shape
`{value, description?}[]`, exactly matching the parsing the S1 daemon performs in
fish — so the parsing contract is unit-testable with static fixtures (no live
`fish`, no socket, no daemon). This closes the §17.15 "golden parsing" gap.

**Deliverable**:
1. `M.parse(raw)` — new pure-Lua export in `lua/pi-bridge/shell/fish.lua`.
2. Verification (no new runtime code) that the daemon's emitted items shape
   `{value, description?}` flows correctly through shell.lua's `normalize_item`
   into `AutocompleteItem {value, label, description?}`.
3. Verification (no new runtime code) that prefix derivation is correct for fish
   via shell.lua's `shell_word_prefix` / `complete_current` (daemon's
   `"prefix":""` is intentionally overridden client-side).
4. `tests/shell_fish_spec.lua` — plenary/busted OFFLINE golden parser tests.
5. `tests/shell_fish_smoke.lua` — plenary-free parser smoke (N→O).

**Success Definition**:
- `require("pi-bridge.shell.fish").parse` is a function; it maps the 5 §17.15
  fixture shapes (normal `word⇥desc`, descriptionless `word`, empty result,
  multiline, literal-tab-in-value) to the exact expected raw-item arrays.
- It NEVER throws on any input (nil/number/table/empty/garbage → `{}`).
- `tests/shell_fish_spec.lua` passes via plenary; `tests/shell_fish_smoke.lua`
  exits 0. The pre-existing S1 live round-trip (`shell_fish_driver_spec.lua`)
  still passes (daemon parsing unchanged/regression-free).

## User Persona (if applicable)

**Target User**: The pi-bridge.nvim maintainer / CI runner.

**Use Case**: Regression-testing the fish completion parsing contract quickly,
deterministically, and without requiring `fish` on `PATH` (CI environments that
lack fish still validate the parser; environments with fish additionally run the
gated live round-trip).

**Pain Points Addressed**: Today the `word⇥desc` parsing lives only inside the
fish daemon script (S1), so it can only be exercised by spawning a real `fish`
subprocess — slow, environment-dependent, and impossible to fixture-test. A typo
or spec drift in the tab-split / description-optional / empty-line handling would
only surface in a live integration run.

## Why

- **PRD §17.15 explicitly mandates** a `shell_fish_spec.lua` that does "golden
  parsing of `complete -C` output … using a fixture string (no live fish needed
  for the parser)". That parser does not yet exist; S2 creates it.
- The parser is the **canonical, documented contract** of what `complete -C`
  output means (first-tab delimiter, description optional, empty lines skipped,
  literal-tab limitation). The S1 daemon is the *runtime* implementation of the
  same spec in fish; `M.parse` is the *testable reference* in Lua. Two independent
  implementations of one spec catch drift.
- It is **additive + low-risk**: a pure function with no side effects, no socket,
  no nvim API calls, no dependency on the daemon or shell.lua state. It cannot
  regress the live completion path (which keeps using the daemon-emitted JSON).

## What

A new module-level function `M.parse(raw)` in `lua/pi-bridge/shell/fish.lua`:

- **Input**: `raw` — the text fish's `complete -C "<cmd>"` prints to stdout
  (UTF-8; one candidate per line; `word⇥description` with a LITERAL 0x09 tab as
  delimiter; bare `word` when no description). `raw` may be a non-string
  (nil/number/table) in defensive/fixture paths → returns `{}`.
- **Output**: an array (Lua 1-indexed) of raw items `{ value:string,
  description?:string }` — the EXACT shape shell.lua's `normalize_item`
  (shell.lua:445) consumes to build `AutocompleteItem {value, label, description?}`.
  `value` is always a non-empty string (empty-word lines are dropped); `description`
  is present only when a tab exists AND the text after it is non-empty.
- **Algorithm**: iterate lines via `raw:gmatch("[^\r\n]+")`; for each non-empty
  line, find the FIRST literal tab with `line:find("\t", 1, true)` (plain find —
  no pattern, so `%`/`+`/`$`/`.` in words/descriptions never corrupt the split);
  word = bytes before the tab (or the whole line if no tab); description = bytes
  after the tab (verbatim, may itself contain tabs); drop the line if word is "".
- **NEVER throws** (`type(raw)~="string"` → `{}`; pure string math; no `vim.*`).

No change to the daemon script, shell.lua, completion.lua, or the live path.

### Success Criteria

- [ ] `require("pi-bridge.shell.fish").parse` is a function.
- [ ] `M.parse` maps each §17.15 fixture shape to the exact expected raw-item array.
- [ ] `M.parse` is byte-identical to the daemon's parsing for the same input (the
      contract the daemon implements in fish); documented in the spec.
- [ ] `M.parse` never throws on bad input (nil/number/table/empty/garbage).
- [ ] `tests/shell_fish_spec.lua` (plenary) passes offline (no `fish` required).
- [ ] `tests/shell_fish_smoke.lua` (plenary-free) prints `SMOKE_PASS` + exits 0.
- [ ] S1's `tests/shell_fish_driver_spec.lua` + `_smoke.lua` still pass (daemon
      parsing unchanged; the live round-trip still yields checkout/cherry).

## All Needed Context

### Context Completeness Check

_Pass_: "If someone knew nothing about this codebase, would they have everything
needed to implement this successfully?" — **Yes.** The PRD excerpts (§17.6.1, §17.15,
§17.5.1, §17.14), the S1 research findings, the exact shell.lua seams
(`normalize_item`, `shell_word_prefix`, `complete_current`), the fish `complete -C`
format, the verified validation commands, and the reference implementation are all
below. The implementer edits exactly one file (`lua/pi-bridge/shell/fish.lua`) to
add one pure function, then adds two test files.

### Documentation & References

```yaml
# MUST READ - Include these in your context window
- url: https://fishshell.com/docs/current/cmds/complete.html
  why: "the `complete -C` / `--do-complete` option: 'Given a string, returns all
        completions' — emits `word<HTAB>description` lines (HTAB = literal 0x09),
        one per candidate; bare `word` when no description."
  critical: "the delimiter is the FIRST literal tab; fish does NOT escape tabs in
        the output → a word containing a literal 0x09 cannot round-trip (split on
        first tab). `M.parse` must mirror this: plain `find(\"\\t\",1,true)`, no
        pattern, no unescape step."

- file: plan/002_d23d7473c16c/P2M2T4S1/research/fish_driver_findings.md
  why: "S1's LIVE-VERIFIED findings (fish 4.8.1). §5 = the robust first-tab split
        the daemon uses (`string replace -r '\\t.*$' ''` for word). §10 = the S1
        scope fence: 'No Lua-side normalization needed in fish.lua' + prefix is the
        consumer's job. §3 = fish 4.x has NO JSON builtin (daemon concern, not
        `M.parse`'s)."
  pattern: "S1 daemon `__pi_handle` IS the runtime implementation of the spec
        `M.parse` codifies in Lua — match its semantics exactly (first-tab split,
        description optional, empty-word skip)."
  gotcha: "the daemon emits single-object JSON `{\"items\":[...],\"prefix\":\"\"}`
        (NOT NDJSON) because shell.lua `_feed` decodes the WHOLE body as one object
        (S1 findings §2). `M.parse` is NOT on that JSON path — it parses the RAW
        `complete -C` text the daemon would have consumed BEFORE building JSON."

- file: lua/pi-bridge/shell.lua
  why: "the downstream consumers S2 must stay compatible with."
  pattern:
    - "L445 `normalize_item(raw)`: takes `{value,description?,label?}` →
       `AutocompleteItem{value,label,description?}`; `label` defaults to `value`
       when absent/empty; `description` carried iff non-empty. THIS is why `M.parse`
       emits `{value,description?}` with NO label — `normalize_item` fills it."
    - "L917 `M.shell_word_prefix(line)` = `line:match(\"[%S]+$\")` (trailing
       non-whitespace run). L945 `complete_current` calls it + OVERRIDES the
       daemon's `\"prefix\":\"\"` (L991). Byte-safe (UTF-8 continuation bytes are
       not ASCII whitespace). THIS is the prefix path — S2 verifies, does NOT
       reimplement."
    - "L525 `M._feed(chunk)`: sentinel-slice → `pcall(vim.json.decode)` → for each
       `decoded.items[i]` call `normalize_item` → `state.pending_cb(items,prefix)`.
       `prefix` read from `decoded.prefix` (default \"\"); complete_current ignores
       it. `M.parse` is NOT called by `_feed` (the daemon pre-parses to JSON)."
  gotcha: "`normalize_item` and the daemon both DROP malformed items (non-table /
        empty-value) silently — `M.parse` must likewise skip empty-word lines
        (never emit a `{value:\"\"}` item)."

- file: lua/pi-bridge/shell/fish.lua
  why: "the file S2 edits. It exports `M.start(opts,on_ready)` + `M.cd(path)` (S1).
        S2 ADDS `M.parse(raw)` + its doc-comment. The daemon lives in `DAEMON_SCRIPT`
        (a fish long-string) — DO NOT touch it; S2 only reads it for parity."
  pattern: "module shape: `local M = {}` ... `function M.<name>(...) ... end` ...
        `return M`. `M.parse` follows the same shape + the never-throws discipline
        (pcall-free pure function: type-guard + string math only)."
  gotcha: "fish.lua does NOT `require(\"pi-bridge\")` or any nvim API at module top
        (the handshake is async; S1 kept it dependency-light). `M.parse` must stay
        dependency-free (no `vim.*`, no require) so it is trivially unit-testable
        in a `--clean -u NORC` smoke."

- file: tests/coords_spec.lua
  why: "the plenary/busted spec STRUCTURE to mirror for `tests/shell_fish_spec.lua`:
        `local m = require(...)`; `describe(...)`/`it(...)`/`assert.are.equals`;
        surface-export `it`; round-trip/known-value `describe` blocks;
        never-throws `describe`; a header comment with the exact run command."
  pattern: "pure-function specs need NO setup/teardown (no sockets/state). Group
        the §17.15 fixture shapes into one `describe(\"M.parse §17.15 golden
        fixtures\", ...)` with one `it` per shape."

- file: tests/shell_fish_driver_spec.lua
  why: "the EXISTING S1 LIVE round-trip (gated on `fish`). It already asserts
        `checkout`/`cherry` decode from the daemon's JSON for `\"git ch\"`. S2
        must NOT duplicate it; S2's `shell_fish_spec.lua` is the OFFLINE parser
        complement (different file, different concern)."
  gotcha: "S1's spec sets `package.loaded[\"pi-bridge.shell.fish\"]=nil` in
        `after_each` so the real module doesn't leak into shell.lua's fake-driver
        tests. S2's parser spec does NOT need that (it doesn't inject fakes), but
        must not break if run in the same plenary session."

- docfile: PRD §17.6.1 (fish — Tier 1) + §17.15 (testing) + §17.5.1 (framing) + §17.14 (coords)
  why: "§17.6.1 Parsing (Lua): 'split each response line on the first \\t; left =
        value (and label), right = description. Map to AutocompleteItem. The
        current word (for prefix) is derivable client-side (last
        whitespace-delimited token of line[1..cursor])'. §17.15 enumerates the 5
        golden fixture shapes. §17.14: shell path is BYTE-domain (no UTF-16)."
  section: "§17.6.1 'Parsing (Lua)'; §17.15 'shell_fish_spec.lua'; §17.5.1 framing
        (the daemon emits between sentinels — context only, `M.parse` works on the
        RAW `complete -C` text, pre-framing)."
```

### Current Codebase tree (run `tree` in the root of the project)

```bash
lua/pi-bridge/
├── shell.lua                 # daemon manager: _feed(normalize_item) / shell_word_prefix / complete_current / request / ensure / teardown  (COMPLETE)
├── health.lua  notify.lua  coords.lua  jsonlreader.lua  bridge.lua  completion.lua  menu.lua  init.lua  blink_source.lua  cmp_source.lua
└── shell/
    └── fish.lua              # S1: M.start(opts,on_ready) + M.cd(path) + DAEMON_SCRIPT(__pi_handle)   <-- S2 EDITS THIS
ftplugin/pi-prompt.lua  plugin/pi-bridge.lua  doc/pi-bridge.txt
tests/
├── shell_fish_spike.lua          # Phase-6 step-21 spike (framed round-trip proof) — reference, do not touch
├── shell_fish_driver_smoke.lua   # S1 LIVE plenary-free smoke (start→3 sequential reqs→checkout/cherry) — keep green
├── shell_fish_driver_spec.lua    # S1 LIVE plenary spec (start contract + gated 'git ch'→checkout) — keep green
├── coords_spec.lua  ... (flat *_spec.lua / *_smoke.lua convention)
└── minimal_init.lua              # plenary harness bootstrap (rtp:prepend plenary + rtp:append repo root)
extension/  (TypeScript pi extension — UNRELATED to S2)
```

### Desired Codebase tree with files to be added and responsibility of file

```bash
lua/pi-bridge/shell/fish.lua     # MODIFY: add `M.parse(raw)` + doc-comment (pure Lua, never-throws)
tests/shell_fish_spec.lua        # CREATE: plenary/busted OFFLINE golden parser tests of M.parse (no live fish)
tests/shell_fish_smoke.lua       # CREATE: plenary-free parser smoke (fixture→M.parse→assert→SMOKE_PASS, exit 0)
```

### Known Gotchas of our codebase & Library Quirks

```lua
-- CRITICAL: the delimiter in `complete -C` output is the FIRST LITERAL 0x09 byte.
-- Use PLAIN find: `line:find("\t", 1, true)`. Do NOT use a Lua PATTERN for the split
-- (a word/description containing `%`, `+`, `$`, `.`, `-`, `(` would be misread).
-- `string.find(s, "\t", 1, true)` == plain substring search (4th arg = plain).

-- CRITICAL: `M.parse` must NEVER throw. A non-string `raw` (nil/number/table from a
-- defensive caller or a buggy fixture) → return `{}`. No assert/pcall needed — a
-- leading `if type(raw) ~= "string" then return {} end` is sufficient (pure fn).

-- CRITICAL: `M.parse` returns RAW items `{value, description?}` — NOT AutocompleteItems.
-- It deliberately OMITS `label` (shell.lua `normalize_item` defaults `label=value`).
-- Emitting a `label` here would be redundant + diverge from the daemon's wire shape.

-- GOTCHA: drop empty-word lines. A line that is "" (gmatch skips it), or a lone tab
-- (word == ""), or whitespace-only — must NOT yield a `{value=""}` item (`normalize_item`
-- drops empty-value items anyway; stay consistent + never emit them).

-- GOTCHA: description is OPTIONAL. A line with NO tab → `{value=line}` (no description key).
-- A line `word\t` (tab then nothing) → `{value=word}` (description omitted, not "").
-- A line `word\tdesc` → `{value=word, description="desc"}`.

-- GOTCHA: a description MAY itself contain tabs (everything after the FIRST tab is the
-- description, verbatim). Do NOT re-split on subsequent tabs. fish descriptions rarely
-- contain tabs, but the contract must be deterministic.

-- GOTCHA (literal-tab limitation, §17.15 "value containing a literal tab (escaped)"):
-- `complete -C` is UNESCAPED tab-delimited → a candidate WORD containing a literal 0x09
-- cannot be represented unambiguously (the first tab is the delimiter). `M.parse` treats
-- the first tab as the delimiter (word = bytes before it). Document this in the spec:
-- the fixture injects a second `\t` mid-value and asserts word = bytes-before-first-tab.
-- Do NOT invent an escape/unescape scheme (none exists in the raw format; the daemon
-- doesn't unescape either). LIVE-VERIFY during validation: `fish -c 'complete -C "<a path
-- with a tab>"'` and align the test to reality.

-- GOTCHA: keep `M.parse` dependency-free (no `vim.*`, no `require`). The plenary-free
-- smoke runs under `nvim --headless --clean -u NORC -c 'set rtp+=.'` — `require` of a
-- nvim-only module at function-call time would still work under nvim, but keeping it
-- pure makes the contract obvious + trivially portable/testable.

-- GOTCHA: do NOT route the LIVE completion path through `M.parse`. The daemon pre-builds
-- single-object JSON; shell.lua `_feed` decodes + normalizes that. `M.parse` is the
-- OFFLINE/testable reference of the SAME spec the daemon implements in fish. Wiring it
-- into `_feed` would require changing the locked daemon/`_feed` protocol — out of scope.
```

## Implementation Blueprint

### Data models and structure

No new data models. `M.parse` consumes/produces existing shapes:

```lua
-- INPUT: raw fish `complete -C` stdout (a UTF-8 Lua string; bytes; §17.14 byte-domain):
--   "checkout\tCheckout and switch to a branch\ncherry\ncherry-pick\tApply a cherry...\n"
-- OUTPUT: raw-item array — the EXACT shape shell.lua normalize_item consumes:
--   {
--     { value = "checkout",    description = "Checkout and switch to a branch" },
--     { value = "cherry" },                                           -- descriptionless
--     { value = "cherry-pick", description = "Apply a cherry..." },
--   }
-- (normalize_item then maps each to AutocompleteItem {value, label=value, description?}.)
```

### Implementation Tasks (ordered by dependencies)

```yaml
Task 1: ADD M.parse(raw) to lua/pi-bridge/shell/fish.lua
  - IMPLEMENT: a pure-Lua function `M.parse(raw)` mapping raw `complete -C` output
    (newline-delimited `word⇥desc` lines) → `{value, description?}[]`.
  - ALGORITHM:
      * `if type(raw) ~= "string" then return {} end`
      * `local items = {}`
      * `for line in raw:gmatch("[^\r\n]+") do`           -- split on \n (and \r); skips empty lines
          - `local tab = line:find("\t", 1, true)`         -- FIRST literal tab, PLAIN find (4th arg true)
          - `local value = tab and line:sub(1, tab - 1) or line`
          - `local desc   = tab and line:sub(tab + 1) or nil`
          - `if value ~= "" then`
              `local item = { value = value }`
              `if desc and desc ~= "" then item.description = desc end`
              `items[#items + 1] = item`
            `end`
        `end`
      * `return items`
  - NAMING: `M.parse` (short; the driver namespace `fish.parse` is unambiguous; matches
    the §17.15 "parser" language). Alternative `M.parse_complete_output` is acceptable
    if `parse` feels too generic — but `parse` is preferred for brevity.
  - PLACEMENT: in `lua/pi-bridge/shell/fish.lua`, AFTER the `DAEMON_SCRIPT` long-string
    definition and BEFORE (or near) `M.start`, so the file reads: script → parser →
    spawn → cd. Add a `-- === M.parse — pure-Lua complete -C parser (§17.6.1/§17.15) ===`
    section header (mirrors the existing `M.start`/`M.cd` section headers).
  - DOC-COMMENT: a `---` luadoc block stating: pure; input = raw `complete -C` stdout;
    output = `{value, description?}[]` (the `normalize_item` input shape); first-tab
    split; description optional; empty-word lines dropped; never-throws (non-string → {});
    the literal-tab limitation; that it is the OFFLINE/testable reference of the spec the
    daemon implements in fish (NOT on the live JSON path).
  - FOLLOW pattern: the existing `M.cd(path)` doc-comment style in the same file (terse
    `---` luadoc, never-throws note, pcall-free pure math).
  - NEVER-THROWS: by construction (type-guard + string math; no `vim.*`, no require).

Task 2: VERIFY daemon/Lua parsing parity (NO code change unless a divergence is found)
  - READ `DAEMON_SCRIPT`'s `__pi_handle` (the fish function in fish.lua). Confirm its
    `complete -C "$cmd" | while read -l raw` loop + `string replace -r '\t.*$' ''` (word)
    + `string replace -r '^[^\t]*\t' ''` (desc) produces the SAME raw-item shape `M.parse`
    does, for the 5 §17.15 cases. (It should — S1 research §5 documented this exact split.)
  - IF a divergence is found (e.g. the daemon trims/escapes where `M.parse` does not):
    align `M.parse` to the daemon's actual runtime behavior (the daemon is the source of
    truth for the live path; `M.parse` documents it). Note any alignment in the spec.
  - DO NOT modify `DAEMON_SCRIPT` (out of scope; S1 is Complete + LIVE-verified).

Task 3: VERIFY the downstream AutocompleteItem-normalization path (NO code change)
  - CONFIRM shell.lua `normalize_item` (L445) maps `{value, description?}` (no label) →
    `AutocompleteItem {value, label=value, description?}`. (True by construction.)
  - The proof is the EXISTING S1 live round-trip: `tests/shell_fish_driver_spec.lua`
    decodes the daemon's JSON + asserts `checkout`/`cherry` appear as item values.
    Re-run it (Validation Level 2) to confirm green after adding `M.parse`.

Task 4: VERIFY the prefix-derivation path (NO code change; document)
  - CONFIRM shell.lua `M.shell_word_prefix(line)` (L917) = `line:match("[%S]+$")` returns
    the trailing non-whitespace run — the fish completion prefix. CONFIRM
    `complete_current` (L945) OVERRIDES the daemon's `"prefix":""` with it (L991).
  - DOCUMENT in the `M.parse` doc-comment + the spec's header that prefix is derived
    CLIENT-SIDE in shell.lua (NOT in fish.lua) and is correct for fish's word model.
  - NO new prefix code in fish.lua (avoid duplicating shell.lua's already-complete,
    already-tested helper). The spec MAY include 2-3 `shell_word_prefix` assertions for
    fish scenarios (`"git ch"`→`"ch"`, `"git "`→`""`, `"cd /tmp/foo"`→`"/tmp/foo"`) as a
    confidence guard, calling `require("pi-bridge.shell").shell_word_prefix` directly.

Task 5: CREATE tests/shell_fish_spec.lua (plenary/busted, OFFLINE golden parser tests)
  - IMPLEMENT: `describe("pi-bridge.shell.fish.parse (§17.6.1/§17.15)")` with:
      * `it("exports M.parse as a function")` — surface guard.
      * `describe("§17.15 golden fixtures", ...)` — ONE `it` per shape:
          - normal `word⇥desc`: `"checkout\tCheckout and switch to a branch\n"` →
            `{ {value="checkout", description="Checkout and switch to a branch"} }`.
          - descriptionless `word`: `"cherry\n"` → `{ {value="cherry"} }` (NO desc key;
            assert `raw[1].description == nil`).
          - empty result: `""` → `{}`.
          - multiline (N items): `"a\tA\nb\n c\tx"` — wait, leading space is part of the
            word per the contract; use `"a\tA\nb\nc\tC"` → 3 items. (Pick unambiguous
            fixtures; avoid leading-whitespace words unless intentionally testing that.)
          - literal-tab-in-value: `"a\tb\tc\n"` → word=`"a"`, description=`"b\tc"`
            (description keeps the second tab verbatim). ASSERT the first-tab split.
      * `describe("mixed / realistic", ...)` — a multi-line blob combining the shapes
        (e.g. real-ish `complete -C "git ch"` output: checkout⇥desc, cherry (bare),
        cherry-pick⇥desc) → assert values + selective descriptions.
      * `describe("never-throws + shape", ...)` — `M.parse(nil)`→`{}`, `M.parse(123)`→`{}`,
        `M.parse({})`→`{}`, `M.parse("   \n\n")`→`{}` (whitespace-only lines: word="   "
        is non-empty → actually yields `{value="   "}`; DECIDE: either accept that as
        contract OR also skip whitespace-only — prefer ACCEPT for parity with the daemon
        which does `test -z "$raw"` only; document). Confirm every item has a string
        non-empty `value`; `description` is absent-or-a-non-empty-string.
      * (optional confidence) `describe("prefix is client-side (shell.lua)", ...)` —
        2-3 `shell.shell_word_prefix` assertions for fish scenarios.
  - FOLLOW pattern: `tests/coords_spec.lua` (structure: surface `it`, known-value
    `describe`, never-throws `describe`; header comment with the run command).
  - NAMING: `tests/shell_fish_spec.lua` (FLAT — matches the sibling `tests/shell_fish_driver_spec.lua`;
    see Context §tree + Gotchas; PRD §17.15 mentions `tests/shell/` but the repo's live
    convention is flat and S1 set it — follow flat, lowest friction).
  - COVERAGE: all 5 §17.15 shapes + never-throws + the literal-tab contract.
  - NO live `fish` required (pure fixtures). NO `vim.fn.executable` gate in this spec.

Task 6: CREATE tests/shell_fish_smoke.lua (plenary-free parser smoke)
  - IMPLEMENT: a `local fails = 0 / check(cond,msg)` harness (mirror
    `tests/shell_fish_driver_smoke.lua`'s header + `SMOKE_PASS`/exit-0 convention).
    Require `fish`; run 3-5 representative `M.parse` inputs through it; assert the
    output shape/values; print `SMOKE_PASS` (or `SMOKE_FAIL` + stderr, exit 1).
  - NOT gated on `fish` (the parser is offline). If you WANT a live cross-check, add an
    OPTIONAL gated block: `if vim.fn.executable("fish")==1 then` pipe a known
    `complete -C` through `vim.uv` and assert `M.parse` of its raw stdout includes
    `checkout` for `"git ch"` — but keep it OPTIONAL (the smoke must pass offline).
  - FOLLOW pattern: `tests/shell_fish_driver_smoke.lua` (header comment, `check()`,
    `fails`, final `if fails>0 then ... end`).
  - RUN: `timeout 60 nvim --headless --clean -u NORC -c 'set rtp+=.' +"luafile tests/shell_fish_smoke.lua" +qa && echo "exit=$?"`
```

### Implementation Patterns & Key Details

```lua
-- === The canonical M.parse (reference; the implementer may align naming/placement) ===
-- Pure Lua, never-throws, dependency-free. Mirrors the S1 daemon's first-tab split
-- (research/fish_driver_findings.md §5) and emits the raw-item shape normalize_item
-- consumes (shell.lua:445). NOT on the live JSON path — the OFFLINE/testable reference.

--- Parse raw fish `complete -C` output (newline-delimited `word⇥description` lines,
--- 0x09 = the first-tab delimiter) into the driver's raw-item wire shape
--- `{ value:string, description?:string }[]` — the exact input shell.lua `normalize_item`
--- consumes to build `AutocompleteItem {value, label=value, description?}` (PRD §17.6.1).
--- Pure Lua + never-throws + dependency-free (no `vim.*`/require) → fixture-testable
--- offline (PRD §17.15 "no live fish needed for the parser"). Mirrors the S1 daemon's
--- `__pi_handle` split semantics (first literal tab; description optional; empty-word
--- lines dropped). KNOWN LIMITATION: a candidate WORD containing a literal 0x09 cannot
--- round-trip (the format is unescaped tab-delimited; first tab = delimiter) — documented
--- in the spec; do not add an escape scheme. NOT called by shell.lua `_feed` (the daemon
--- pre-builds single-object JSON; `M.parse` is the testable reference of the same spec).
---@param raw string? Raw `complete -C` stdout (UTF-8; non-string → {}).
---@return table[] items `{ value:string, description?:string }[]` (may be empty).
function M.parse(raw)
	if type(raw) ~= "string" then return {} end
	local items = {}
	for line in raw:gmatch("[^\r\n]+") do          -- split lines; empty lines skipped by gmatch
		local tab = line:find("\t", 1, true)        -- FIRST literal tab, PLAIN find (no pattern)
		local value = tab and line:sub(1, tab - 1) or line
		if value ~= "" then                          -- drop empty-word lines (parity with normalize_item)
			local item = { value = value }
			local desc = tab and line:sub(tab + 1) or nil
			if desc and desc ~= "" then item.description = desc end  -- description OPTIONAL (omit if absent/empty)
			items[#items + 1] = item
		end
	end
	return items
end

-- === KEY INVARIANTS the spec must pin ===
--  1. first-tab split (plain find) — a word/desc with `%`,`+`,`$` is never misread.
--  2. description is ABSENT (not "") when there's no tab or the post-tab text is empty.
--  3. a description KEEPS any further tabs verbatim ("a\tb\tc" → value="a", desc="b\tc").
--  4. empty-word lines (lone tab, or empty) are dropped; never emit {value=""}.
--  5. never-throws: nil/number/table/garbage → {}.
```

### Integration Points

```yaml
NO RUNTIME INTEGRATION (pure additive function):
  - `M.parse` is called ONLY by tests. The live completion path is UNCHANGED:
      user types `!git ch` → completion.lua do_shell_fetch → shell.complete_current
      → shell.request → daemon `__pi_handle` (fish) builds JSON → shell._feed decodes
      → normalize_item → AutocompleteItem[] → menu. `M.parse` is absent from this chain.
  - DO NOT add `M.parse` to `_feed`, `complete_current`, or the daemon. Wiring it in
    would require changing the locked daemon/`_feed` single-object-JSON protocol (S1/S5)
    — explicitly OUT OF SCOPE.

DOCUMENTATION (inform future tasks):
  - P2.M3.T5 (zsh/bash drivers): each driver SHOULD expose an analogous `M.parse(raw)`
    for its own output format, so §17.15's `shell_zsh_spec.lua`/`shell_bash_spec.lua`
    can golden-test offline. `fish.M.parse` is the template.
  - P2.M3.T6 health/docs: `:checkhealth pi-bridge` may note the fish parser tier.
```

## Validation Loop

### Level 1: Syntax & Style (Immediate Feedback)

```bash
# After adding M.parse — confirm the module still loads + the function exists.
# (AGENTS.md: write snippets to a FILE, never heredoc→nvim stdin. This is a one-liner -c 'lua …' — allowed.)
timeout 30 nvim --headless --clean -u NORC -c 'set rtp+=.' \
  -c 'lua local f=require("pi-bridge.shell.fish"); assert(type(f.parse)=="function"); print("parse=ok")' -c 'qa'
echo "exit=$?"   # 0 + "parse=ok" = good

# Optional: luac syntax check (fast, no nvim).
luac -p lua/pi-bridge/shell/fish.lua && echo "luac=ok"

# stylua (repo convention) — format the edited file + new tests.
stylua lua/pi-bridge/shell/fish.lua tests/shell_fish_spec.lua tests/shell_fish_smoke.lua 2>/dev/null \
  || echo "(stylua not installed — skip; not a hard gate)"

# selene lint (if configured) — informational.
# Expected: parse=ok / luac=ok. Fix any load error before proceeding.
```

### Level 2: Unit Tests (Component Validation)

```bash
# S2's OFFLINE golden parser spec (plenary) — the primary gate. NO live fish needed.
timeout 90 nvim --headless --clean -u tests/minimal_init.lua \
  -c 'lua require("plenary.busted").run("tests/shell_fish_spec.lua")'
echo "exit=$?"   # 0 = all assertions passed

# S2's plenary-free parser smoke.
timeout 60 nvim --headless --clean -u NORC -c 'set rtp+=.' +"luafile tests/shell_fish_smoke.lua" +qa
echo "exit=$?"   # 0 + SMOKE_PASS = good

# REGRESSION: re-run S1's LIVE round-trip to confirm the daemon parsing is unchanged
# (M.parse added nothing to the live path; this must stay green). Gated on `fish` (present here: 4.8.1).
timeout 90 nvim --headless --clean -u tests/minimal_init.lua \
  -c 'lua require("plenary.busted").run("tests/shell_fish_driver_spec.lua")'
echo "exit=$?"
timeout 60 nvim --headless --clean -u NORC -c 'set rtp+=.' +"luafile tests/shell_fish_driver_smoke.lua" +qa
echo "exit=$?"

# Expected: shell_fish_spec passes offline; smokes print SMOKE_PASS (or SMOKE_SKIP for the
# driver smoke if fish absent — here fish IS present so the live path runs). If a spec
# fails, READ the assertion message + fix M.parse (or the fixture) before proceeding.
```

### Level 3: Integration Testing (System Validation)

```bash
# HUMAN-VERIFY the `complete -C` output format `M.parse` is built against (the source spec).
fish -c 'complete -C "git ch"' | cat -A | head    # cat -A shows tabs as ^I — confirm word^Idesc
fish -c 'complete -C "git"'    | head             # bare-word lines (no description) appear

# OPTIONAL live cross-check (only if `fish` present): feed a real `complete -C` stdout
# through M.parse + assert a known value. (Already covered by S1's driver spec, but this
# pins the PARSER→raw-fish-output link directly.) Write to a FILE (AGENTS.md HARD RULE):
cat > /tmp/pi_fish_parse_check.lua <<'LUA'
local fish = require("pi-bridge.shell.fish")
local uv = vim.uv
local function run(cmd, cb)
  local stdout = uv.new_pipe(false)
  uv.spawn("fish", { args = { "-c", cmd }, stdio = { nil, stdout, nil } },
    function(code) uv.close(stdout_ or stdout) end) -- (keep simple: let +qa reap)
  local buf = ""
  stdout:read_start(function(err, data)
    if err or data == nil then return cb(buf) end
    buf = buf .. data
  end)
end
run('complete -C "git ch"', function(raw)
  local items = fish.parse(raw)
  local found = {}
  for _, it in ipairs(items) do found[it.value] = true end
  print(("parsed=%d items; checkout=%s cherry=%s"):format(#items,
    tostring(found["checkout"] == true), tostring(found["cherry"] == true)))
  vim.cmd("qa")
end)
LUA
timeout 30 nvim --headless --clean -u NORC -c 'set rtp+=.' +"luafile /tmp/pi_fish_parse_check.lua" +qa
echo "exit=$?"   # expect: parsed=N items; checkout=true cherry=true
# (If fish is absent this errors harmlessly — skip; the offline spec is the real gate.)

# Expected: `complete -C "git ch"` shows `checkout^ICheckout…` + bare `cherry`; the live
# parse check prints checkout=true cherry=true. This proves M.parse ↔ real fish output.
```

### Level 4: Creative & Domain-Specific Validation

```bash
# Direct-provider fidelity cross-check (paranoia, optional): confirm shell.lua's
# normalize_item turns M.parse's raw output into proper AutocompleteItems. normalize_item
# is module-LOCAL (not exported), so exercise it THROUGH _feed via shell.lua's test seam
# OR just assert the SHAPE contract M.parse guarantees (value:non-empty-string;
# description:absent-or-non-empty-string) — which is exactly what normalize_item requires.
cat > /tmp/pi_shape_check.lua <<'LUA'
local fish = require("pi-bridge.shell.fish")
local raw = "checkout\tCheckout and switch to a branch\ncherry\ncherry-pick\tApply\n"
for _, it in ipairs(fish.parse(raw)) do
  assert(type(it.value)=="string" and it.value ~= "", "bad value")
  assert(it.description == nil or (type(it.description)=="string" and it.description ~= ""), "bad desc")
end
print("shape=ok (normalize_item-compatible)")
LUA
timeout 30 nvim --headless --clean -u NORC -c 'set rtp+=.' +"luafile /tmp/pi_shape_check.lua" +qa
echo "exit=$?"   # 0 + "shape=ok" = the raw items are normalize_item-compatible
# Expected: shape=ok. This closes the "AutocompleteItem normalization" verification:
# M.parse's output is provably the input shape normalize_item consumes.
```

## Final Validation Checklist

### Technical Validation

- [ ] Level 1: `M.parse` loads + is a function (`parse=ok`); `luac -p` clean.
- [ ] Level 2: `tests/shell_fish_spec.lua` passes offline via plenary (exit 0).
- [ ] Level 2: `tests/shell_fish_smoke.lua` prints `SMOKE_PASS` + exit 0.
- [ ] Level 2 REGRESSION: S1 `shell_fish_driver_spec.lua` + `_smoke.lua` still pass.
- [ ] Level 3: `fish -c 'complete -C "git ch"'` shows the `word^Idesc` / bare-`word` format.
- [ ] Level 3 (optional): live parse check prints `checkout=true cherry=true`.
- [ ] Level 4: shape check confirms `M.parse` output is `normalize_item`-compatible.

### Feature Validation

- [ ] All 5 §17.15 golden fixture shapes handled: normal `word⇥desc`, descriptionless
      `word`, empty result, multiline (N items), literal-tab-in-value (first-tab split).
- [ ] `M.parse` never throws on nil/number/table/empty/garbage (→ `{}`).
- [ ] Every emitted item has a non-empty string `value`; `description` is absent-or-non-empty.
- [ ] The daemon's runtime parsing (S1) is UNCHANGED — `M.parse` is additive only.
- [ ] Prefix derivation documented as client-side (`shell.shell_word_prefix`); no fish.lua dup.
- [ ] AutocompleteItem normalization verified downstream (normalize_item compatibility).

### Code Quality Validation

- [ ] `M.parse` follows the existing `M.start`/`M.cd` module shape + doc-comment style.
- [ ] File placement: `M.parse` in `lua/pi-bridge/shell/fish.lua`; tests flat in `tests/`.
- [ ] Anti-patterns avoided: no live-path coupling, no `vim.*`/require in `M.parse`, no
      escape/unescape scheme, no duplicate normalization/prefix code.
- [ ] The literal-tab limitation is documented (doc-comment + spec), not papered over.

### Documentation & Deployment

- [ ] `M.parse` has a `---` luadoc block (input/output/contract/limitation/never-throws).
- [ ] Spec + smoke header comments include the exact run command (mirror S1's headers).
- [ ] (Forward note for P2.M3.T5: zsh/bash `M.parse` should follow this template.)

---

## Anti-Patterns to Avoid

- ❌ Don't route the live completion path through `M.parse` — the daemon pre-builds JSON
  and shell.lua `_feed` decodes it. Wiring `M.parse` in changes the locked protocol.
- ❌ Don't reimplement AutocompleteItem normalization in fish.lua — `normalize_item`
  (shell.lua:445) already does it (label defaults to value). `M.parse` emits raw
  `{value, description?}` only.
- ❌ Don't reimplement prefix derivation in fish.lua — `shell.shell_word_prefix` /
  `complete_current` (shell.lua) already derive it client-side + override the daemon's
  `"prefix":""`. Verify + document; do not duplicate.
- ❌ Don't split with a Lua PATTERN (`line:match("^(.-)\t")`) — a word/description
  containing `%`,`+`,`$`,`.`,`-` would be misread. Use PLAIN `line:find("\t",1,true)`.
- ❌ Don't emit `{value=""}` or `{description=""}` — drop empty-word lines; omit an
  empty/absent description key (parity with `normalize_item`'s drop/omit semantics).
- ❌ Don't add an escape/unescape scheme for literal tabs — the `complete -C` format is
  unescaped; the first tab is the delimiter. Document the limitation; don't invent escapes.
- ❌ Don't modify `DAEMON_SCRIPT` (S1 is Complete + LIVE-verified) or shell.lua/completion.lua.
- ❌ Don't gate the OFFLINE parser spec on `vim.fn.executable("fish")` — §17.15 requires it
  run with NO live fish. (The DRIVER spec/smoke stay gated; the PARSER spec/smoke do not.)
- ❌ Don't pipe a heredoc into `nvim`'s stdin (AGENTS.md HARD RULE) — write test snippets
  to a FILE then `+"luafile <file>" +qa`, or use a one-line `-c 'lua …'`.

---

## Confidence Score: 9/10

One-pass success is very likely: the deliverable is a single pure function + two
test files, fully specified with a reference implementation, exact fixtures, and
verified validation commands. The −1 reserves for the literal-tab edge: the
implementer should LIVE-VERIFY `fish -c 'complete -C "<tab-path>"'` during
validation and align the one literal-tab fixture to fish's actual behavior (the
spec prescribes first-tab-split, which is the documented contract, but real fish
output for an embedded tab is the one thing not yet machine-confirmed here).