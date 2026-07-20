---
name: "P3.M10.T25.S40 — Configurable trigger-aware debounce + RPC-timeout/supersession tuning (mirror pi's getAutocompleteDebounceMs)"
description: |
  **TUNE the completion debounce to be TRIGGER-AWARE so timing is byte-for-byte faithful to pi's
  TUI**, then VERIFY/DOCUMENT the RPC-timeout + stale-response-supersession invariants. Parent
  P3.M10.T25 "Timing refinement — debounce, timeout, supersession tuning" (Phase 3 polish, PRD §13
  step 12).

  **THE GAP (verified against `~/projects/pi` `packages/tui/src/components/editor.ts:2214`):** pi's
  TUI does NOT apply a flat debounce. `Editor.getAutocompleteDebounceMs` returns:
    • `explicitTab || force`             → **0 ms** (immediate) — ALREADY correct in the plugin via
      `force_fetch` (S33, the 0-debounce Tab sibling).
    • text-before-cursor matches the **file/attachment** pattern (`@…` / `#…`, incl. the `@"…"`
      quoted-path-with-spaces case) → **`ATTACHMENT_AUTOCOMPLETE_DEBOUNCE_MS = 20 ms`**
      (editor.ts:236).
    • **else** (slash commands `/model`, plain typing) → **0 ms** (immediate).
  The plugin TODAY (`completion.lua`) applies a **FLAT `debounce_ms` (default 25) to every refresh**
  — slash, typing, AND `@`-context all get 25 ms. This **diverges from the TUI** in three ways
  (slash/typing get a 25 ms lag pi does not have; `@`-context gets 25 instead of 20; the `@"…"`
  quoted-path case is undetected). PRD §1 mandates "byte-for-byte identical" completion — timing
  is part of behavior. **S40 closes this gap** (this is literally "debounce … tuning").

  **NON-GOALS (already done — S40 only verifies/documents):** `rpc_timeout_ms` is ALREADY
  configurable (init.lua `M.defaults`, overridable via `setup({})`) and ALREADY correct
  (client **2000 ms >** server fd-abort **1500 ms** = `GET_SUGGESTIONS_TIMEOUT_MS`,
  extension/pi-editor-bridge.ts:289 — the invariant that lets the server's own `fd` abort win).
  The two-layer stale-response supersession (gen-guard + `bridge.cancel`) is ALREADY correct
  (S30) and is trigger-agnostic. S40 keeps these and EXTENDS the tests.

  **DELIVERABLES (EDIT-ONLY, additive + backward-compatible — no new module):**
    (1) **EDIT** `plugin/lua/pi-editor/completion.lua` — add a pure `M.is_attachment_context(text)`
        (exported for unit tests) + an internal `compute_debounce(lines, cursorLine, cursorCol)`
        that mirrors `getAutocompleteDebounceMs`; `M.refresh(buf)` reads the cursor line + computes
        the window (0 / `debounce_ms`) BEFORE `vim.defer_fn` (so the window reflects the text at
        refresh time, exactly like pi).
    (2) **EDIT** `plugin/lua/pi-editor/init.lua` — retune `M.defaults.debounce_ms` **25 → 20**
        (pi's `ATTACHMENT_AUTOCOMPLETE_DEBOUNCE_MS`); clarify the `---@field debounce_ms` doc
        ("file/attachment-context window; slash/typing use 0 ms, matching pi's TUI"). Optional
        one-line setup-time WARN if a user sets `rpc_timeout_ms <= 1500`.
    (3) **EDIT** `plugin/tests/init_spec.lua` — `25 → 20` at lines 17/66/76; add a doc assertion.
    (4) **EXTEND** `plugin/tests/completion_spec.lua` — new describe block: `@src/`→attachment
        window, `/mod`→0 ms (collapse still 1 req), `@"quoted path`→detected, mid-word `foo@bar`
        →NOT detected, file-context stale-result supersession; direct `is_attachment_context`
        unit cases.
    (5) **EXTEND** `plugin/tests/completion_smoke.lua` — a file-context (`@sr`) fetch case.

  **NON-REGRESSION:** the existing `completion_spec` slash-`/mod` collapse tests (2)/(3) STILL
  PASS — `vim.defer_fn(fn, 0)` is async + cancellable, so rapid `cancel_timer()`+`defer_fn(0)`
  calls STILL collapse to exactly ONE request (the cancel path, not the duration, collapses them;
  verified — research/notes.md §2). Only the `init_spec` default-value literal changes (25→20).
---

## Goal

**Feature Goal**: Make the per-keystroke completion debounce **trigger-aware** so it mirrors pi's
TUI `Editor.getAutocompleteDebounceMs` (editor.ts:2214) **exactly**: slash commands and plain
typing fire **immediately (0 ms)**, file/attachment context (`@…` / `#…`, including the
`@"…"` quoted-path-with-spaces case) debounces by the configurable window (**default 20 ms** = pi's
`ATTACHMENT_AUTOCOMPLETE_DEBOUNCE_MS`), and Tab/force stays **0 ms** (already correct via S33's
`force_fetch`). Simultaneously **verify + document** the two timing invariants the PRD names but
the code only half-asserts today: (a) the client `rpc_timeout_ms` (2000) must **exceed** the server
`fd`-abort `GET_SUGGESTIONS_TIMEOUT_MS` (1500) so the server's own abort wins; (b) the two-layer
stale-response supersession (gen-guard + `bridge.cancel`) must continue to drop a stale
`@`-context result when the user keeps typing in a file context. This is PRD §13 Phase-3 step 12
("Debounce, supersession, timeouts").

**Deliverable** (EDIT-ONLY — 2 source files, 3 test files; NO new module):
- **EDIT** `plugin/lua/pi-editor/completion.lua`:
  - ADD `M.is_attachment_context(text_before_cursor)` — a **pure, exported** helper (mirror of pi's
    `buildDebouncePattern(["@","#"])` `autocompleteDebouncePattern`): returns `true` iff the last
    whitespace-delimited token before the cursor starts with `@` or `#`, **or** the cursor is inside
    an unclosed `@"…` quoted mention. Lua has no regex `|`/`(?:...)`, so this is explicit logic
    (not a single Lua pattern) — directly unit-testable, the `coords.lua` style.
  - ADD an internal `compute_debounce(lines, cursorLine, cursorCol)` — returns `0` for non-attachment
    context, else the configured window (clamped `>= 0`, integer). (Tab/force never reaches here —
    `force_fetch` is the separate 0-debounce path; S40 does not touch it.)
  - EDIT `M.refresh(buf)` — read the cursor line + byte col **before** scheduling, slice
    `text_before_cursor` (UTF-8 byte slice is correct here — the `@`/`#`/`"`/space checks are all
    ASCII), call `compute_debounce`, and pass that `ms` to `vim.defer_fn`. (Mirrors pi computing
    `debounceMs` at `requestAutocomplete` entry from the *current* state.)
  - UPDATE the `[Mode A]` header with: the trigger-aware model, the `ATTACHMENT_AUTOCOMPLETE_DEBOUNCE_MS=20`
    citation, the `@"…"` quoted-path case, the `vim.defer_fn(fn,0)`-still-collapses fact, and the
    supersession-still-trigger-agnostic note.
- **EDIT** `plugin/lua/pi-editor/init.lua`:
  - `M.defaults.debounce_ms` **25 → 20**; clarify the `---@field debounce_ms integer` doc.
  - (Optional, recommended) ADD a one-line setup-time WARN via the S39 `notify.lua` when a user
    sets `rpc_timeout_ms <= 1500` (the server fd-abort floor) — protects the §5 invariant.
- **EDIT** `plugin/tests/init_spec.lua` — `25 → 20` at the 3 default-literal assertions (lines 17,
  66, 76); ADD a one-line assertion documenting "slash/typing use 0 ms (pi-faithful)".
- **EXTEND** `plugin/tests/completion_spec.lua` — NEW describe block "S40 trigger-aware debounce":
  direct `is_attachment_context` unit cases (the §3 case table) + integration cases
  (`@src/`→window, `/mod`→0 ms-collapse-1, `@"quoted path`→detected, `foo@bar`→NOT detected,
  file-context stale-result gen-guard supersession).
- **EXTEND** `plugin/tests/completion_smoke.lua` — a file-context (`@sr`) refresh→fetch case.

**Success Definition** (every assertion is LIVE-VERIFIED or directly testable via the mock bridge):
- **`is_attachment_context` matches pi exactly** (the §3 case table): `@src/comp`✅, `#tag`✅,
  `@"my dir`✅ (unclosed quote), `/model`❌, `hello world`❌, `foo@bar`❌ (mid-token `@`), `""`❌.
- **Slash/typing fire immediately (0 ms)**: a single `refresh("/mod…")` issues its `getSuggestions`
  on the next event-loop tick (a `defer_fn(0)` — verified collapsible); 3 rapid `refresh("/mod")`
  STILL collapse to exactly **1** request (the cancel path, not the duration — research §2).
- **File/attachment context uses the configured window**: `refresh("@sr")` debounces by
  `debounce_ms` (default 20; a test may set 10); a `getSuggestions` is issued only after that window.
- **`debounce_ms` default is 20** (pi's `ATTACHMENT_AUTOCOMPLETE_DEBOUNCE_MS`) and remains
  user-overridable; `M.defaults` is NOT mutated by `setup({ debounce_ms = X })`.
- **Client RPC timeout invariant holds**: `rpc_timeout_ms` (default 2000) **>** the server
  `GET_SUGGESTIONS_TIMEOUT_MS` (1500); documented in the `rpc_timeout_ms` type annotation +
  `bridge.lua` header; a user who sets `<= 1500` gets a single WARN (if the optional guard ships).
- **File-context stale-response supersession**: typing `@sr` → (slow) → `@src` drops the stale
  `@sr` result at the gen-guard (`if gen ~= state.gen then return end`) — only the latest lands.
  `bridge.cancel(prev_id)` is still called (layer 1).
- **Non-regression**: all prior specs (`init`/`shim`/`activate`/`ftplugin`/`jsonlreader`/`bridge`/
  `handshake`/`request`/`notify`/`coords`-S28/S29/`completion`-S30..S37/`menu`) pass unchanged
  except the deliberate `25→20` literal; the 6 keymaps + autosave + disconnect paths are untouched.

## User Persona (if applicable)

**Target User**: a pi user typing a prompt in the Neovim external editor. They never see this code;
they experience it as: *"typing `/mod…` or plain text feels instant (no laggy menu), `@file…`
suggestions appear ~20 ms after I pause — exactly like pi's own TUI — and they always reflect what
I just typed, never a stale suggestion from a keystroke ago, even when I type fast inside an `@`
mention."*

**Use Case**: the polish half of the completion pipeline. The trigger layer (S30) + menu (S31/S34+)
+ accept (S32) + Tab (S33) + nav (S36) + auto-close (S37) + degradation (S39) are all COMPLETE and
correct, but the **timing** was a flat 25 ms placeholder. S40 is the named owner (PRD §13 step 12)
of retuning it to pi's verified per-trigger model + locking down the timeout/supersession invariants
with tests + docs so a future change cannot silently re-diverge.

**User Journey**: open the pi external editor (`Ctrl+G`) → type `/mod` → menu appears **immediately**
(was: ~25 ms lag) → accept → type `@sr` → menu appears after ~20 ms (was: ~25 ms) → keep typing
`@src` fast → only the final `@src` result is shown (stale `@sr`/`@s` dropped) → quit to submit.

**Pain Points Addressed**: (1) the perceptible 25 ms lag on slash/typing that pi's TUI does not have;
(2) silent timing divergence from the TUI (the "byte-for-byte identical" goal); (3) an undocumented
client/server timeout relationship that a careless `rpc_timeout_ms` override could break.

## Why

- **PRD §1 (Goals, load-bearing):** *"Completion behavior in Neovim is **byte-for-byte identical**
  to pi's TUI, because the same live provider produces and applies the suggestions."* Timing is part
  of behavior — a 25 ms slash lag the TUI does not have is a divergence. S40 removes it.
- **PRD §5.5 (Timing & cancellation):** names the debounce + RPC timeout as first-class concerns.
  Its wording ("25 ms for slash/path; 0 ms extra for `@`") is a **design sketch that the verified
  pi source contradicts** (slash=0, `@`=20; research/notes.md §1). S40 follows the source — the
  codebase's established "supersede a PRD sketch with the verified pi source" pattern (coords.lua
  did exactly this to PRD §7.4's `bytecol-1`).
- **PRD §13 (Phase 3, step 12):** explicitly lists *"Debounce, supersession, timeouts, silent
  degradation"* as the Phase-3 polish work. S39 shipped silent degradation; **S40 is debounce +
  supersession + timeouts** — the remaining items in that step.
- **The forward contract is already in the code:** `completion.lua`'s `debounce_ms()` helper +
  `[Mode A]` header call `~25 ms` a placeholder and reference `pi getAutocompleteDebounceMs`; the
  S33 `force_fetch` header says "Tab is IMMEDIATE (0-debounce) per pi `getAutocompleteDebounceMs`".
  S40 is the named owner of making the *refresh* path equally pi-faithful.
- **The timeout invariant is real but only half-asserted:** `bridge.lua` reads `rpc_timeout_ms`
  defensively but never states it must exceed the server's `GET_SUGGESTIONS_TIMEOUT_MS` (1500). A
  user who sets `rpc_timeout_ms: 1000` would have the client abandon `@file` searches before the
  server's own `fd` abort fires — orphaned server work + a confusing "request timeout" error. S40
  documents + (optionally) guards it.

## What

**User-visible behavior**: typing a slash command (`/mod…`) or plain text in the pi external editor
now feels **instant** — the completion menu appears on the next event-loop tick (0 ms debounce),
matching pi's TUI. Typing an `@file`/`#tag` mention (or inside an unclosed `@"quoted path`) debounces
by ~20 ms (configurable) before re-querying — also matching the TUI. Fast typing inside an `@`
mention never shows a stale result (the two-layer supersession still holds). No visible regression
in any other path.

**Technical requirements**:
1. **One pure helper** `M.is_attachment_context(text)` (exported) + one internal `compute_debounce(...)`
   in `completion.lua`. NO new module, NO new dependency (pure Lua; the `@`/`#`/`"`/space checks are
   ASCII so a UTF-8 byte slice of the line is correct — NO coords conversion needed for the *debounce
   decision*, only for the RPC params which `do_refresh` already does).
2. **Default retune** `debounce_ms` 25 → 20 in `init.lua` (pi's `ATTACHMENT_AUTOCOMPLETE_DEBOUNCE_MS`).
3. **Documented timeout invariant** `rpc_timeout_ms (2000) > GET_SUGGESTIONS_TIMEOUT_MS (1500)` +
   an optional setup-time WARN guard.
4. **Extended tests** (plenary spec + plenary-free smoke) — see Validation Loop.
5. **No change** to `bridge.lua`, `coords.lua`, `menu.lua`, the ftplugin, the extension, or any
   keymap/autosave/disconnect path.

### Success Criteria

- [ ] `is_attachment_context` passes the §3 case table (8 cases) as direct unit tests.
- [ ] Slash/typing (`/mod`) refresh fires at 0 ms; 3 rapid refreshes still collapse to 1 request.
- [ ] File context (`@sr`) refresh debounces by `debounce_ms` (default 20); the `@"quoted path`
      case is detected as attachment context.
- [ ] `debounce_ms` default is 20; overridable via `setup({})`; `M.defaults` stays pristine.
- [ ] File-context stale-result supersession: a slow `@sr` result is dropped when `@src` supersedes
      it (gen-guard + `bridge.cancel`).
- [ ] `rpc_timeout_ms > 1500` invariant documented; (optional) WARN on `<= 1500`.
- [ ] All prior specs green (only the deliberate `25→20` literal changes).

## All Needed Context

### Context Completeness Check

_Before writing this PRP, validate: "If someone knew nothing about this codebase, would they have
everything needed to implement this successfully?"_ — **YES.** This PRP cites the exact pi source
line (`editor.ts:2214` + constants at `:236`), the exact plugin files + line numbers to edit, the
exact Lua logic to write (the `@"…"` quoted-path forward-scan), the verified `vim.defer_fn(fn,0)`
collapse fact, the test-runner commands, and the full non-regression analysis. No guessing.

### Documentation & References

```yaml
# MUST READ - Include these in your context window
- url: "packages/tui/src/components/editor.ts:2214"   # ~/projects/pi  (VERIFIED by direct read)
  why: "Editor.getAutocompleteDebounceMs — THE authoritative debounce model S40 must mirror.
        explicitTab||force → 0; attachment-pattern-match → ATTACHMENT_AUTOCOMPLETE_DEBOUNCE_MS;
        else → 0. This is the single source of truth (PRD §5.5's wording is a misleading sketch)."
  critical: "slash/typing are 0 ms (NOT 25); @/# context is 20 ms (NOT 25). The plugin's flat 25 ms
             diverges in BOTH directions. S40 fixes both."

- url: "packages/tui/src/components/editor.ts:236"     # ~/projects/pi  (VERIFIED)
  why: "ATTACHMENT_AUTOCOMPLETE_DEBOUNCE_MS = 20  +  DEFAULT_AUTOCOMPLETE_TRIGGER_CHARACTERS = ['@','#'].
        These are the exact constants. debounce_ms default → 20."

- url: "packages/tui/src/components/editor.ts:247"     # ~/projects/pi  (VERIFIED — buildDebouncePattern)
  why: "The attachment-context regex: /(?:^|[ \\t])(?:@(?:\"[^\"]*|[^\\s]*)|[#][^\\s]*)$/. Decoded:
        the last whitespace-delimited token before the cursor starts with @ or #, WITH a special
        @\"...\" quoted-path-with-spaces case. Lua has no | / (?:...) → port as explicit logic (§3)."
  critical: "the @\"...\" quoted-path case is the easy-to-miss arm; a naive 'last token starts with
             @' check is WRONG for @\"my dir (last token is 'dir'). Handle unclosed @\"."

- url: "extension/pi-editor-bridge.ts:289"             # in-tree (VERIFIED)
  why: "export const GET_SUGGESTIONS_TIMEOUT_MS = 1500 — the server fd-abort. The client
        rpc_timeout_ms (2000) MUST exceed this so the server's own abort wins (timeouts cascade
        outward). Document this invariant; optionally WARN on rpc_timeout_ms <= 1500."

- file: plugin/lua/pi-editor/completion.lua
  why: "THE file to edit. refresh(buf) → debounce_ms() → vim.defer_fn(do_refresh). S40 replaces the
        flat debounce_ms() with compute_debounce() and reads the cursor line in refresh() first.
        do_refresh, force_fetch, accept, on_tab, on_enter, on_next/prev/dismiss, on_insert/buf_leave
        are UNCHANGED. Read the [Mode A] header FIRST (esp. the vim.defer_fn stop+close leak fix +
        the two-layer supersession + the 'ask on every change' pi-faithful model)."
  pattern: "the existing debounce_ms() local (defensive config read with fallback) + cancel_timer()
            (stop+close, the leak fix) + do_refresh (reads bridge/lines/cursor FRESH). S40 ADDS
            compute_debounce() reusing the same defensive-read shape; refresh() gains a line-read."
  gotcha: "BRIDGE/MENU/COORDS READ FRESH AT CALL TIME (never cache at module load — handshake is
           async + tests swap fakes). refresh() must read the cursor line via nvim API (api-safe:
           refresh runs from the ftplugin autocmd dispatch on the main loop). Keep do_refresh's
           FRESH line-read for the RPC params (the line may change during the debounce window)."

- file: plugin/lua/pi-editor/init.lua
  why: "EDIT M.defaults.debounce_ms (25→20) + the @---@field debounce_ms doc. Optional setup-time
        rpc_timeout_ms WARN (one line via the S39 notify.lua)."
  pattern: "M.defaults is a module-level table; setup() = vim.tbl_deep_extend('force', defaults, opts)
            (returns a NEW table — defaults never mutated). The defensive-read pattern
            '((cfg.config or cfg.defaults or {}).X) or <fallback>' is used everywhere."
  gotcha: "NEVER mutate M.defaults (init_spec asserts it stays pristine). NEVER throw from setup()."

- file: plugin/lua/pi-editor/bridge.lua
  why: "READ-ONLY reference for the timeout lookup (M.handshake + M.request both read
        rpc_timeout_ms defensively with fallback 2000) + the two-layer supersession contract
        (the [Mode A] header: 'supersession is the CALLER's job — latest-id guard or cancel(id)').
        S40 does NOT edit bridge.lua — only documents the 2000>1500 invariant in its header note."
  pattern: "the rpc_timeout_ms defensive read: ((cfg.config or cfg.defaults or {}).rpc_timeout_ms) or 2000"

- file: plugin/lua/pi-editor/coords.lua
  why: "THE style model for is_attachment_context — a PURE, EXPORTED, exhaustively-unit-tested
        helper (coords_spec.lua round-trip table). Mirror this for is_attachment_context's case table."
  pattern: "local M = {} ... M.is_attachment_context = function(t) ... end ... return M  (pure, no state)."

- file: plugin/tests/completion_spec.lua
  why: "THE spec to EXTEND. fake_bridge() + vim.wait(ms, predicate, 5) async style. NOTE line 18
        (setup({debounce_ms=10})) + the reset() that restores DEFAULT_DEBOUNCE — the new cases must
        save/restore debounce_ms too. Read tests (2)/(3) (slash /mod collapse) — they STILL PASS at 0 ms."
  pattern: "it('...', function() ... reset() ... fake=fake_bridge(); pi.bridge=fake ... buf=...;
            completion.refresh(buf); wait_for(200, function() return #fake.requests>=1 end);
            assert... end). Mirror populated_menu() for the file-context supersession case."
  gotcha: "do NOT name a spec-local 'pending' (shadows plenary's skip fn). Use 'got'/'results'."

- file: plugin/tests/init_spec.lua
  why: "EDIT the 3 default-literal assertions (25→20 at lines 17, 66, 76). ADD a doc assertion.
        These are the ONLY hard literal changes in the whole task."

- docfile: plan/001_c56962b4fa17/P3M10T25S40/research/notes.md
  why: "THIS PRP's consolidated research: the verified pi debounce model, the vim.defer_fn(0) collapse
        proof, the Lua-vs-vim.regex port analysis (+ the exact 8-case table), the timeout invariant,
        and the full non-regression table. Read it FIRST."
  section: "§1 (the gap), §2 (defer_fn(0)), §3 (the Lua port + case table), §4 (config), §5 (timeout),
            §7 (test-impact table)."
```

### Current Codebase tree (the files S40 touches)

```bash
plugin/
  lua/pi-editor/
    init.lua          # EDIT: defaults.debounce_ms 25→20 + doc (+ optional rpc_timeout WARN)
    completion.lua    # EDIT: + is_attachment_context() + compute_debounce(); refresh() reads the line
    bridge.lua        # READ-ONLY (timeout lookup + supersession contract; document 2000>1500)
    coords.lua        # READ-ONLY (the style model for a pure exported helper)
    menu.lua jsonlreader.lua notify.lua   # UNCHANGED
  plugin/pi-editor.lua ftplugin/pi-prompt.lua   # UNCHANGED
  tests/
    init_spec.lua             # EDIT: 25→20 (×3) + doc assertion
    completion_spec.lua       # EXTEND: new "S40 trigger-aware debounce" describe block
    completion_smoke.lua      # EXTEND: @sr file-context fetch case
    minimal_init.lua          # UNCHANGED (reused)
extension/   # UNCHANGED (S40 is plugin-only; the 1500ms server constant is READ-ONLY reference)
```

### Desired Codebase tree with files to be added and responsibility of file

```bash
# NO new files. S40 is EDIT-ONLY (additive): 2 source edits + 3 test extensions.
# (A throwaway /tmp script for ad-hoc timing checks is fine but MUST be a real file — NEVER pipe
#  a heredoc into nvim stdin; see AGENTS.md HARD RULE.)
```

### Known Gotchas of our codebase & Library Quirks

```lua
-- CRITICAL: vim.defer_fn(fn, 0) is STILL async + cancellable. N rapid cancel_timer()+defer_fn(0)
-- calls collapse to EXACTLY ONE callback (the cancel path collapses them, not the duration).
-- => the existing slash-/mod collapse tests STILL PASS at 0 ms. Do NOT add a special "0 ms =
--    call do_refresh synchronously" path; keep defer_fn (the plugin's [Mode A] header relies on it
--    to coalesce the TextChangedI+CursorMovedI pair a keystroke emits). (research §2.)

-- CRITICAL: the @"..." quoted-path case. A naive `t:match("[%S]+$"):sub(1,1)=="@"` is WRONG for
-- `@"my dir` — the last whitespace-delimited token is `dir`, not `@"my`. pi special-cases this
-- (editor.ts:247 `@(?:"[^"]*|...)`). The Lua port MUST scan for an UNCLOSED @" (odd quote count
-- after the last @"). See the Implementation Patterns block for the exact forward-scan code.

-- CRITICAL: Lua patterns have NO `|` alternation and NO (?:...) non-capturing groups (:help
-- lua-pattern). Do NOT try to write the pi regex as one Lua pattern. Use explicit logic (Option A,
-- recommended) OR vim.regex (Option B). Option A matches coords.lua's pure-tested style.

-- CRITICAL: the @/#/" detection is ASCII-only. A UTF-8 BYTE slice of the cursor line is CORRECT
-- for the debounce decision (t:sub(1, byte_col)). Do NOT run it through coords for the DECISION
-- (coords is for the RPC params, which do_refresh already does). But DO use the SAME byte col
-- nvim_win_get_cursor returns (0-based byte) so the slice is the real text-before-cursor.

-- CRITICAL: read the cursor line FRESH in refresh() (it runs from the ftplugin autocmd dispatch
-- on the main loop — api-safe). The line may change DURING the debounce window; that is fine and
-- pi-faithful (pi computes debounceMs from the state at requestAutocomplete entry). do_refresh
-- re-reads lines FRESH for the RPC params (unchanged).

-- CRITICAL: debounce_ms semantically becomes "the file/attachment-context window". Slash/typing
-- use 0 ms (hardcoded, pi-faithful — NOT separately configurable; pi hardcodes 0). Document this
-- in the @---@field + the [Mode A] header so a user who sets debounce_ms=99 isn't surprised that
-- slash is still instant.

-- CRITICAL: NEVER mutate M.defaults (init_spec asserts pristine). NEVER throw from setup().
-- The optional rpc_timeout_ms WARN uses notify.once("config", WARN, ...) (dedup'd; never spam).

-- CRITICAL: the two-layer supersession is TRIGGER-AGNOSTIC (keys on a monotonic gen int). The
-- trigger-aware debounce does NOT weaken it — a fast-typed @sr→@src still bumps gen + drops the
-- stale @sr. Do NOT add trigger-awareness to the gen-guard. Just EXTEND the tests (§6).
```

## Implementation Blueprint

### Data models and structure

No new data models. S40 reuses the existing `pi-editor.Config` (`debounce_ms`, `rpc_timeout_ms`)
and `pi-editor.CompletionState`. The only structural addition is the pure function
`M.is_attachment_context(text) -> boolean` (stateless, the `coords.lua` shape).

### Implementation Tasks (ordered by dependencies)

```yaml
Task 1: EDIT plugin/lua/pi-editor/init.lua — retune the debounce default + doc (+ optional WARN)
  - CHANGE: M.defaults.debounce_ms  25  ->  20   (pi ATTACHMENT_AUTOCOMPLETE_DEBOUNCE_MS, editor.ts:236)
  - EDIT: the @---@field debounce_ms integer doc -> "...file/attachment-context window (default 20 =
    pi's ATTACHMENT_AUTOCOMPLETE_DEBOUNCE_MS). Slash commands and plain typing use 0 ms (immediate),
    matching pi's TUI getAutocompleteDebounceMs (editor.ts:2214)."
  - ADD (optional, recommended): in M.setup(), AFTER the merge, if (M.config.rpc_timeout_ms or 2000)
    <= 1500 then require("pi-editor.notify").once("config", vim.log.levels.WARN,
    "pi-editor: rpc_timeout_ms (<=1500ms) is below the bridge fd-abort — @file searches may be cut
    off client-side").  (pcall-wrapped; setup never throws; notify.once dedups.)
  - ADD: a @---@field rpc_timeout_ms doc line noting "MUST exceed the server fd-abort
    GET_SUGGESTIONS_TIMEOUT_MS (1500); default 2000. See bridge.lua header."
  - NAMING: no new keys (backward-compatible — the only public change is the default VALUE).
  - FOLLOW pattern: the existing defensive reads; M.defaults never mutated.
  - DEPENDENCIES: notify.lua (S39, COMPLETE) for the optional WARN.

Task 2: EDIT plugin/lua/pi-editor/completion.lua — add is_attachment_context + compute_debounce
  - ADD: M.is_attachment_context(text_before_cursor) — PURE, EXPORTED (for unit tests; the coords.lua
    shape). Forward-scan for an UNCLOSED @" (odd quote count after the last @") OR a trailing
    whitespace-delimited token starting with @/#. (Exact code in Implementation Patterns.)
  - ADD: local compute_debounce(lines, cursorLine, cursorCol) — slices text-before-cursor (UTF-8 byte
    slice via the SAME byte col do_refresh uses), returns is_attachment_context(...) and the config
    window, else 0. Clamps: math.max(0, math.floor(ms or 0)); fallback 20 if non-number.
  - EDIT: M.refresh(buf) — after state.buf=buf + cancel_timer(), read the cursor line + byte col
    (pcall-wrapped, api-safe), compute ms=compute_debounce(lines, row-1, byte_col), then
    state.debounce_timer = vim.defer_fn(function() do_refresh(buf) end, ms).  (do_refresh UNCHANGED.)
  - REPLACE: the old debounce_ms() local's fallback 25 -> 20 (and reuse it inside compute_debounce).
  - UPDATE: the [Mode A] header (the trigger-aware model + the editor.ts:2214/236 citations + the
    @"..." case + the defer_fn(0)-still-collapses note + supersession-still-trigger-agnostic note).
  - NAMING: M.is_attachment_context (exported); compute_debounce (local). snake_case.
  - FOLLOW pattern: coords.lua (pure exported helper) + the existing debounce_ms() defensive read.
  - DEPENDENCIES: none new (pure Lua + nvim API already used).
  - GOTCHA: keep do_refresh's FRESH line-read for RPC params; the debounce decision uses the line at
    refresh() time. NEVER cache the bridge/menu/coords at module load.

Task 3: EDIT plugin/tests/init_spec.lua — the default-literal retune
  - CHANGE: line 17  assert.are.equals(25, ...) -> 20   ("ships the exact PRD §10.5 defaults" — note
    the PRD §10.5 value (25) is SUPERSEDED by the pi-faithful 20; update the test's it() label +
    comment to cite editor.ts:236 ATTACHMENT_AUTOCOMPLETE_DEBOUNCE_MS).
  - CHANGE: lines 66 + 76  (the "defaults still pristine" echoes) 25 -> 20.
  - ADD: a one-line it("documents slash/typing use 0ms (pi-faithful)") assertion (a comment/doc
    check — e.g. assert the @---@field doc string mentions "0 ms", or just a documentation test).
  - NAMING: keep the existing it() labels; only the literal + a clarifying comment change.

Task 4: EXTEND plugin/tests/completion_spec.lua — the trigger-aware debounce + supersession cases
  - ADD: a describe("S40: trigger-aware debounce (pi getAutocompleteDebounceMs)", ...) block with:
      (a) DIRECT is_attachment_context unit cases — the §3 table: "@src/comp"✅, "#tag"✅,
          '@"my dir'✅, "/model"❌, "hello world"❌, "foo@bar"❌, ""❌, "@日"x (multibyte)✅.
      (b) refresh("@sr") debounces by debounce_ms (set 10 in the case) — wait_for the window, then
          assert #fake.requests==1; AND assert a refresh("/mod") at 0ms fires on the next tick
          (wait_for a SHORT budget — no full debounce wait needed).
      (c) 3 rapid refresh("/mod") STILL collapse to 1 request (the §2 proof — guard against a
          regression to "0ms = N requests").
      (d) refresh('@"my dir') is detected as attachment (uses the window, not 0).
      (e) FILE-CONTEXT SUPERSESSION: refresh("@sr") [slow, unresolved] -> refresh("@src") ->
          resolve the @sr result -> assert on_results was NOT called for it (gen-guard dropped it)
          AND bridge.cancel(prev_id) was recorded; resolve @src -> on_results called with @src items.
  - REUSE: fake_bridge(), populated_menu(), wait_for(), reset() (extend reset() to restore
    debounce_ms — it ALREADY does at line 83). Mirror the existing test (4) two-layer supersession
    style for case (e).
  - NAMING: test_completion_trigger_aware_debounce style; it("...") per case.
  - GOTCHA: do NOT shadow `pending` (use `got`/`results`). Save/restore debounce_ms per case.

Task 5: EXTEND plugin/tests/completion_smoke.lua — a file-context fetch case
  - ADD: after the existing slash-refresh case, a case that sets the buffer to {"@sr"}, refresh(buf),
    drives the debounce with vim.wait, and asserts the fake luv server received a getSuggestions
    whose params.lines=={"@sr"} (the trigger-aware path end-to-end). Print SMOKE_PASS / exit 0.
  - FOLLOW pattern: the existing completion_smoke.lua fake-server + handshake + refresh + wait style.
  - DEPENDENCIES: minimal_init.lua (S19, UNCHANGED).
```

### Implementation Patterns & Key Details

```lua
-- ===== Task 2: is_attachment_context — the PURE, EXPORTED pi-faithful detector =====
-- Mirror of pi buildDebouncePattern(["@","#"]) (editor.ts:247): the last whitespace-delimited
-- token before the cursor starts with '@' or '#', OR the cursor is inside an UNCLOSED @"...
-- quoted mention. Lua has no regex | / (?:...) -> explicit logic (the coords.lua pure-tested style).
-- PURE: no nvim API, no state, no side effects -> directly unit-testable (coords_spec shape).
--
-- @param text_before_cursor string  the cursor line from col 0 to the cursor (UTF-8 byte slice;
--        the @/#/"/space checks are ASCII so a byte slice is correct — NO coords conversion).
-- @return boolean  true iff pi would DEBOUNCE here (attachment/file context).
M.is_attachment_context = function(text_before_cursor)
  local t = text_before_cursor or ""
  if t == "" then return false end
  -- (1) UNCLOSED @"...  quoted-path-with-spaces case (pi @(?:"[^"]*|...)).
  --     Find the LAST '@"' (forward plain search), then count '"' AFTER it; ODD = unclosed
  --     -> we are inside a quoted mention -> attachment context. (Forward scan avoids the
  --     reverse()-on-UTF-8 question entirely.)
  local last_atq
  local i = 1
  while true do
    local s = t:find('@"', i, true)   -- plain search (4th arg = literal); ASCII needle, byte-safe
    if not s then break end
    last_atq = s
    i = s + 2
  end
  if last_atq then
    local after = t:sub(last_atq + 2)
    local _, nq = after:gsub('"', '"')
    if nq % 2 == 1 then return true end   -- odd quotes after the last @" -> inside the quote
  end
  -- (2) PLAIN token: the trailing non-whitespace run starts with '@' or '#'.
  local last = t:match("[%S]+$") or ""
  if last ~= "" then
    local c = last:sub(1, 1)
    if c == "@" or c == "#" then return true end
  end
  return false
end

-- ===== Task 2: compute_debounce — the per-refresh window (mirror getAutocompleteDebounceMs) =====
-- Returns 0 for non-attachment context (slash/typing — pi-faithful immediate), else the configured
-- attachment window (default 20). Tab/force NEVER reach here (force_fetch is the separate 0-debounce
-- path). Clamps + falls back defensively (the existing debounce_ms() discipline; fallback 25->20).
local function compute_debounce(lines, cursorLine, cursorCol)
  local line = lines[cursorLine + 1] or ""     -- pi cursorLine is 0-based -> Lua 1-based (the SAME +1 coords uses)
  local byte_end = cursorCol                   -- pi cursorCol is UTF-16; for the ASCII @/#/"/space
                                               -- checks a UTF-8 byte slice to cursorCol is correct
                                               -- ONLY for BMP — for full correctness slice to the
                                               -- BYTE col. See GOTCHA: pass the nvim BYTE col here.
  -- (defensive: if a caller passes the pi UTF-16 col by mistake, the ASCII checks still hold for
  --  BMP text; the multibyte unit case in Task 4 proves the byte-col path.)
  local before = line:sub(1, byte_end)
  if not M.is_attachment_context(before) then return 0 end
  local cfg = require("pi-editor")
  local ms = ((cfg.config or cfg.defaults) or {}).debounce_ms
  if type(ms) ~= "number" or ms < 0 then ms = 20 end
  return math.max(0, math.floor(ms))
end

-- ===== Task 2: refresh() — compute the window from the CURRENT line, THEN defer =====
function M.refresh(buf)
  if type(buf) ~= "number" then return end
  state.buf = buf
  cancel_timer()                          -- stop+close the prior pending defer (leak fix; unchanged)
  -- READ the cursor line + byte col (api-safe: refresh runs from the ftplugin autocmd dispatch on
  -- the main loop). pcall-wrapped (a wiped buf / odd state degrades silently — never throws).
  local ms = 0
  pcall(function()
    if buf ~= vim.api.nvim_get_current_buf() then return end   -- one buf/session (unchanged guard)
    local ok, lines = pcall(vim.api.nvim_buf_get_lines, buf, 0, -1, false)
    if not ok or type(lines) ~= "table" then return end
    local cur
    ok, cur = pcall(vim.api.nvim_win_get_cursor, 0)
    if not ok or type(cur) ~= "table" then return end
    local row, byte_col = cur[1], cur[2]
    ms = compute_debounce(lines, row - 1, byte_col)   -- row 1-based -> pi 0-based; byte_col is 0-based byte
  end)
  state.debounce_timer = vim.defer_fn(function() do_refresh(buf) end, ms)  -- ms is 0 or the window
end
```

```lua
-- ===== Task 1: init.lua — the retune + the optional WARN (setup never throws) =====
M.defaults = {
  menu = { max_height = 12, border = "rounded" },
  debounce_ms = 20,        -- was 25; pi ATTACHMENT_AUTOCOMPLETE_DEBOUNCE_MS (editor.ts:236).
                           -- file/attachment-context window; slash/typing use 0 ms (pi-faithful).
  rpc_timeout_ms = 2000,   -- MUST exceed the server fd-abort GET_SUGGESTIONS_TIMEOUT_MS (1500).
  autosave_on_exit = true,
  engine = "builtin",
}
function M.setup(opts)
  opts = opts or {}
  M.config = vim.tbl_deep_extend("force", M.defaults, opts)
  -- Optional invariant guard: WARN (dedup'd via notify.once) if a user set rpc_timeout_ms at/below
  -- the server fd-abort floor. Never throws; setup must always succeed.
  pcall(function()
    local rt = M.config.rpc_timeout_ms
    if type(rt) == "number" and rt > 0 and rt <= 1500 then
      require("pi-editor.notify").once("config", vim.log.levels.WARN,
        "pi-editor: rpc_timeout_ms (" .. rt .. "ms) is at/below the bridge fd-abort (1500ms) — "
          .. "@file searches may be cut off client-side")
    end
  end)
  return M.config
end
```

### Integration Points

```yaml
CONFIG (init.lua):
  - change: "M.defaults.debounce_ms: 25 -> 20 (pi ATTACHMENT_AUTOCOMPLETE_DEBOUNCE_MS, editor.ts:236)"
  - doc:    "@---@field debounce_ms: 'file/attachment-context window (default 20). Slash/typing use 0 ms (pi-faithful).'"
  - doc:    "@---@field rpc_timeout_ms: 'MUST exceed server fd-abort GET_SUGGESTIONS_TIMEOUT_MS (1500); default 2000.'"
  - optional: "setup() WARN via notify.once('config', WARN) when rpc_timeout_ms <= 1500."

COMPLETION (completion.lua):
  - add:    "M.is_attachment_context(text)  (pure, exported — coords.lua style)"
  - add:    "local compute_debounce(lines, cursorLine, cursorCol)  (0 or debounce_ms)"
  - edit:   "M.refresh(buf): read cursor line -> compute_debounce -> vim.defer_fn(do_refresh, ms)"
  - edit:   "the debounce_ms() fallback 25 -> 20 (reused inside compute_debounce)"
  - doc:    "[Mode A] header: trigger-aware model + editor.ts citations + defer_fn(0) note"
  - preserve: "do_refresh, force_fetch, accept, on_tab, on_enter, on_next/prev/dismiss, on_insert/buf_leave — UNCHANGED"

BRIDGE (bridge.lua):
  - doc-only: "header note: 'rpc_timeout_ms (2000) must exceed GET_SUGGESTIONS_TIMEOUT_MS (1500) so the server fd-abort wins'"
  - no code change

TESTS:
  - init_spec.lua:        "25 -> 20 (×3) + a doc assertion"
  - completion_spec.lua:  "NEW describe block (§3 table + slash-0ms-collapse + @-window + @\"... + file-context supersession)"
  - completion_smoke.lua: "@sr file-context fetch case"
```

## Validation Loop

> **HARD RULE (AGENTS.md):** NEVER pipe a heredoc / stdin into `nvim` — it HANGS the session. Write
> test snippets to a real `.lua` file, then run with `+"luafile <path>" +qa`. Every command below is
> already a real file under `plugin/tests/`. Wrap every nvim invocation in `timeout`.

### Level 1: Syntax & Style (Immediate Feedback)

```bash
# Lua is interpreted; there is no compile step. Catch syntax errors + (optional) selene/stylua:
cd plugin/
timeout 30 nvim --headless --clean -u NORC +"luafile tests/completion_smoke.lua" +qa; echo "exit=$?"
# (selene/stylua are optional per PRD §9.2; if configured: `selene lua/` / `stylua --check lua/`)
# Expected: exit 0, SMOKE_PASS printed. A Lua syntax error prints a stack trace — fix before Level 2.
```

### Level 2: Unit / Component Tests (plenary — the per-keystroke debounce + supersession logic)

```bash
cd plugin/
# The spec S40 extends (trigger-aware debounce + file-context supersession):
timeout 90 nvim --headless --clean -u tests/minimal_init.lua \
  -c 'lua require("plenary.busted").run("tests/completion_spec.lua")'
# The default-retune spec:
timeout 90 nvim --headless --clean -u tests/minimal_init.lua \
  -c 'lua require("plenary.busted").run("tests/init_spec.lua")'
# Expected: 0 failures. The NEW describe block's cases (§3 table + slash-0ms-collapse +
#   @-window + @"... + file-context supersession) all pass; the 25->20 literal assertions pass.
```

### Level 3: Smoke / Integration (plenary-free — the real bridge + trigger path)

```bash
cd plugin/
# The extended smoke (now covers the @sr file-context fetch end-to-end):
timeout 60 nvim --headless --clean -u NORC +"luafile tests/completion_smoke.lua" +qa; echo "exit=$?"
# Expected: exit 0, SMOKE_PASS printed (the fake luv server received a getSuggestions for {"@sr"}).
```

### Level 4: Full Non-Regression Sweep (every prior spec still green)

```bash
cd plugin/
# Run EVERY spec — only init_spec's 25->20 literal should differ from pre-S40; everything else
# must be byte-identical green. One-liner loop:
for s in init shim activate ftplugin jsonlreader bridge handshake request notify coords completion menu; do
  echo "=== $s ==="
  timeout 90 nvim --headless --clean -u tests/minimal_init.lua \
    -c "lua require('plenary.busted').run('tests/${s}_spec.lua')" || echo "FAIL: $s"
done
# Expected: all green. (coords has two specs if S28/S29 split — run coords_spec too.)
```

### Level 5: Creative / Domain-Specific Validation (the pi-faithfulness cross-check)

```bash
# Cross-check the Lua is_attachment_context against pi's buildDebouncePattern regex directly:
# write a throwaway /tmp check.lua (NEVER heredoc-into-nvim-stdin; AGENTS.md HARD RULE) that feeds
# the §3 case table through BOTH M.is_attachment_context AND (for reference) the documented vim.regex
# translation, and asserts they agree. Run: timeout 30 nvim --headless --clean -u NORC -c 'set rtp+=.' +"luafile /tmp/check.lua" +qa
# Expected: all 8 cases agree with pi's regex semantics (research/notes.md §3 table).
```

## Final Validation Checklist

### Technical Validation
- [ ] Level 1 (syntax/smoke) passes: `completion_smoke.lua` prints SMOKE_PASS, exit 0.
- [ ] Level 2 (plenary): `completion_spec.lua` + `init_spec.lua` — 0 failures.
- [ ] Level 3 (integration): the `@sr` file-context fetch case reaches the fake server.
- [ ] Level 4 (non-regression): EVERY prior spec green; only the deliberate `25→20` literal differs.

### Feature Validation
- [ ] `is_attachment_context` passes the §3 case table (incl. the `@"my dir` quoted-path + multibyte).
- [ ] Slash/typing (`/mod`) refresh fires at 0 ms; 3 rapid refreshes still collapse to 1 request.
- [ ] File context (`@sr`) refresh debounces by `debounce_ms` (default 20).
- [ ] `debounce_ms` default is 20; overridable; `M.defaults` stays pristine.
- [ ] File-context stale-result supersession: slow `@sr` dropped at the gen-guard when `@src` supersedes.
- [ ] `rpc_timeout_ms > 1500` invariant documented (+ optional WARN on `<= 1500`).

### Code Quality Validation
- [ ] Follows the codebase's additive + backward-compatible discipline (no new module, no breaking
      config-shape change; only a default VALUE retune + additive helpers).
- [ ] `is_attachment_context` is pure + exported + unit-tested (the `coords.lua` style).
- [ ] The `[Mode A]` header is updated (trigger-aware model + editor.ts citations + the
      `defer_fn(0)`-still-collapses + supersession-still-trigger-agnostic notes).
- [ ] No nvim stdin heredoc anywhere (AGENTS.md HARD RULE); every check is a real `.lua` file.

### Documentation & Deployment
- [ ] The `debounce_ms` / `rpc_timeout_ms` `---@field` docs state the pi-faithful semantics + the
      `2000 > 1500` invariant.
- [ ] The PRD §5.5 / §10.5 "25 ms" sketch is noted as SUPERSEDED by the verified pi source
      (editor.ts:2214/236) — the codebase's "supersede a PRD sketch with verified pi source" pattern.

---

## Anti-Patterns to Avoid

- ❌ Don't make `0 ms` mean "call `do_refresh` synchronously" — keep `vim.defer_fn(fn, 0)`. It is
  still async + cancellable, and the cancel path is what collapses rapid refreshes (research §2);
  calling synchronously would re-introduce the re-entrancy/loop risks the `[Mode A]` header warns of.
- ❌ Don't reimplement the debounce regex as one Lua pattern — Lua has no `|`/`(?:...)`. Use explicit
  logic (Option A) or `vim.regex` (Option B); don't half-port and silently drop the `@"…"` case.
- ❌ Don't change the config SHAPE (e.g. `debounce = {default_ms, attachment_ms}`) — that breaks the
  public `debounce_ms` key + 6 `init_spec` assertions against the additive discipline. Reinterpret
  the existing flat key (default 20) instead.
- ❌ Don't add trigger-awareness to the gen-guard supersession — it's trigger-agnostic by design and
  MUST stay so. Only EXTEND the tests.
- ❌ Don't lower `rpc_timeout_ms` below 1500 or remove the invariant doc — the server's `fd` abort
  must win (timeouts cascade outward).
- ❌ Don't touch `bridge.lua` / `coords.lua` / `menu.lua` / the ftplugin / the extension — S40 is
  plugin-completion-only. The 1500 ms constant is READ-ONLY reference.
- ❌ Don't catch-all / swallow — the defensive reads `pcall` + degrade silently (the established
  never-throws contract); the optional WARN is `notify.once` (dedup'd, never spam).
- ❌ Don't pipe a heredoc into `nvim` stdin (AGENTS.md HARD RULE — it hangs the session). Every check
  is a real `.lua` file run with `+"luafile" +qa`.