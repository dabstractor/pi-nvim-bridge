# PRP — P4.M1.T2.S1: cmp_source.lua — source.new, get_trigger_characters, complete (+ confirm override)

**Work item**: P4.M1.T2.S1 (a.k.a. plan id `P4M1T2S1` / PRD P4.M12.T30.S46) — "nvim-cmp source module"
**Phase**: P4 (Optional Integrations) → M12 (Completion Engine Sources & Optimization) → T30 → S46
**Scope**: ONE optional, self-contained module `plugin/lua/pi-editor/cmp_source.lua` (+ tests).
This is an **opt-in** completion-engine source (PRD §7.7). It reuses the **already-shipped** bridge
(`getSuggestions`) and accept flow (`applyCompletion`) — it adds NO new RPC, NO new
buffer-manipulation, NO change to the builtin engine. Sibling task S45 (blink.cmp source) is being
implemented **in parallel**; S47 (NVIM_APPNAME) is out of scope.

> **Parallel execution context**: This PRP is researched in parallel with **P4.M1.T1.S1**
> ("blink_source.lua"). The two are **independent siblings** (PRD §7.7 lists both as opt-in sources).
> They share the SAME reuse path (`bridge.request("getSuggestions", …)` + `completion.accept`) and
> the SAME shipped seams (`pi.bridge`, `coords.nvim_to_pi_coords`, `completion.accept`). They do NOT
> conflict: each is a SEPARATE, opt-in consumer of the bridge; the user registers at most one. This
> PRP treats the blink sibling's `blink_source.lua` as a **read-only structural reference** (same
> module shape: `local M = {}`, `M.new`, live-bridge reads, silent degrade, `KIND_TEXT=1` hardcoded,
  `vim.deepcopy` of the original item) and ADAPTS the one thing that genuinely differs between the
  two engines: **the acceptance path** (see the §"Why two different acceptance designs" box below).

---

## Goal

**Feature Goal**: A valid **nvim-cmp source** that a user registers in their cmp config to receive
pi-editor completions (slash commands + `@` mentions) rendered through the **nvim-cmp UI**, with the
actual text insertion delegated to pi's server-side `applyCompletion` (pi-faithful insertion — the
same path the builtin engine uses) via a provided confirm-override helper.

**Deliverable**: `plugin/lua/pi-editor/cmp_source.lua` exporting a `source` table with `new`,
`is_available`, `get_trigger_characters`, `complete`, and a module-level `confirm()` helper for
pi-faithful acceptance; plus a plenary-free smoke test (`plugin/tests/cmp_source_smoke.lua`) and a
plenary spec (`plugin/tests/cmp_source_spec.lua`).

**Success Definition**:
- The module satisfies the nvim-cmp source contract (verified against the locally-installed
  **blink.compat** adapter — the authoritative nvim-cmp source-API consumer; nvim-cmp itself is NOT
  installed locally).
- `source.new(opts)` returns an object with `is_available`, `get_trigger_characters`, `complete`.
- `source:is_available()` is `true` iff `vim.env.PI_NVIM_BRIDGE ~= nil and require("pi-editor").bridge ~= nil`.
- `source:get_trigger_characters()` returns `{ "/", "@" }`.
- `source:complete(params, callback)` extracts the **full buffer** + cursor from `params.context`,
  converts nvim→pi coords (with the **`params.context.cursor.col - 1`** correction — cmp cols are
  1-based byte), calls `bridge.request("getSuggestions", {lines, cursorLine, cursorCol})` (NO
  `force` key), maps each `AutocompleteItem` → an LSP-shaped `CompletionItem` (carrying the original
  pi item + prefix in the standard LSP `data` field for the confirm helper), and calls `callback`
  **exactly once**. A stale (superseded) `complete` call's cb is gen-guarded and dropped.
- `M.confirm()` returns a `cmp.mapping`-compatible `function(fallback)` that, for a pi item, calls
  `completion.accept(pi_item, pi_prefix)` + `cmp.abort()` (does NOT call `cmp.confirm` — cmp's
  additive text insertion would diverge from pi's TUI); for a non-pi item / no active entry it falls
  through to `fallback()` / `cmp.confirm`.
- All validation gates pass (smoke prints `SMOKE_PASS` / exit 0; plenary spec green).

## User Persona

**Target User**: A Neovim user who runs pi as `$EDITOR` AND uses [nvim-cmp](https://github.com/hrsh7th/nvim-cmp)
as their completion UI (instead of the plugin's dependency-free builtin popup or blink.cmp).

**Use Case**: While editing a pi prompt in Neovim, the user types `/` or `@` (or any prefix) and
nvim-cmp shows pi's completion candidates; accepting one inserts it exactly as pi's TUI would.

**User Journey**:
1. pi launches Neovim with `PI_NVIM_BRIDGE` set → the plugin activates + connects the bridge
   (`require("pi-editor").bridge` becomes non-nil).
2. The user's cmp config registers the source + the confirm override:
   `sources = { { name = 'pi-editor' } }` and `mapping['<CR>'] = cmp.mapping(require('pi-editor.cmp_source').confirm(), {'i'})`.
3. On typing, cmp calls `complete` → pi returns candidates → cmp renders them.
4. On `<CR>`, the confirm override calls pi's `applyCompletion` (replaces the whole buffer + cursor,
   pi-faithful) and aborts cmp's menu (no cmp text insertion).

**Pain Points Addressed**: Users who already run nvim-cmp don't want a *second* floating popup (the
builtin one) competing with it; they want pi's candidates inside the engine they already use.

## Why

- **PRD §7.7** explicitly calls for opt-in blink.cmp + nvim-cmp sources "so both reuse the same
  bridge + accept-via-`applyCompletion` path."
- Lets users keep their preferred completion UI (nvim-cmp) while preserving pi's exact insertion
  semantics (pi is authoritative — it returns the whole new buffer).
- The plugin already exposes `require("pi-editor").bridge` (init.lua) precisely so that "these
  (and user code) can issue RPCs" (PRD §7.7). This task is the consumer of that seam.

> ### Why two different acceptance designs (blink vs cmp) — READ THIS
> The **blink** sibling (S45) overrides acceptance via the source's **`execute`** method: blink's
> `execute(ctx, item, callback, default_implementation)` lets a source **skip the default text
> insertion** (don't call `default_implementation`) and do its own. nvim-cmp's `execute(item,
> callback)` has **NO such skip parameter** — cmp ALWAYS applies its own textEdit/insertText/label
> insertion FIRST, THEN calls `execute` (verified via the locally-installed `blink.compat` adapter's
> `source:execute`, which runs the default text FIRST then the source's execute). So a cmp source's
> `execute` CANNOT cleanly override insertion, and calling `completion.accept` from `execute` would
> be **broken** (by the time `execute` fires, cmp has already inserted the item, so `accept`'s fresh
> `nvim_buf_get_lines` would read the POST-insertion buffer and send WRONG lines to pi).
>
> **⇒ For nvim-cmp, the pi-faithful acceptance path is a USER-SIDE confirm mapping** (the work
> item's "override the confirm behavior" option) that calls `applyCompletion` and does NOT call
> `cmp.confirm`. This PRP provides that override as an ergonomic module-level helper `M.confirm()`
> (the cmp analogue of blink's in-module `execute`), so the two sibling PRPs are **parallel in
> spirit** (both handle acceptance in the module) while **correct per engine**. (research/notes.md §4/§5.)

## What

A single optional Lua module that adapts the nvim-cmp source contract to pi's bridge, PLUS a
module-level confirm-override helper. No new RPC methods, no buffer-editing logic of its own (it
reuses `completion.accept`), no module-level mutable connection state, no autocmds. Side-effect-free
at `require` time; all work happens inside the source methods / the confirm helper.

### Success Criteria

- [ ] `require("pi-editor.cmp_source").new(opts)` returns an object implementing `is_available`,
      `get_trigger_characters`, `complete`.
- [ ] `:is_available()` returns `true` only when the env var AND `pi.bridge` are both set; `false` otherwise.
- [ ] `:get_trigger_characters()` returns `{ "/", "@" }` (deep-equal, order-insensitive acceptable).
- [ ] `:complete(params, cb)` calls `bridge.request("getSuggestions", …)` with params
      `{ lines = <full buffer>, cursorLine = row-1, cursorCol = <UTF-16 of (params.context.cursor.col - 1)> }`
      and **no `force` key**.
- [ ] Each returned item is `{ label = ai.label, detail = ai.description, filterText = ai.value,
      kind = 1, data = { pi_item = deepcopy(ai), pi_prefix = prefix } }`.
- [ ] The cmp `callback` is invoked **exactly once** per resolved `complete` call (with the mapped
      items, or with empty/`nil` on any degrade path: no bridge / not connected / RPC error / null
      result / bad params). A superseded `complete`'s cb is gen-guarded and dropped (never calls `cb`).
- [ ] `complete` does NOT return a cancel function (nvim-cmp's contract has none); supersession is
      handled INTERNALLY via a gen-guard + `bridge.cancel(prev_inflight_id)`.
- [ ] `M.confirm()` returns a `function(fallback)` that: for a pi item calls
      `completion.accept(data.pi_item, data.pi_prefix)` + `cmp.abort()` and does NOT call `cmp.confirm`;
      for a non-pi item / no active entry / no cmp, calls `fallback()` or `cmp.confirm`.
- [ ] Smoke test passes (`SMOKE_PASS`, exit 0); plenary spec passes.

---

## All Needed Context

### Context Completeness Check

> "If someone knew nothing about this codebase, would they have everything needed to implement
> this successfully?" — **Yes.** The exact nvim-cmp source interface, the `params.context` shape
> (incl. the load-bearing **`cursor.col - 1`** 1-based-byte→0-based-byte correction), the
> additive-`execute` limitation (⇒ custom confirm mapping), the reuse path (`completion.accept`),
> and the bridge/coords APIs are all quoted verbatim below with file paths. No guessing required.

### Documentation & References

```yaml
# MUST READ — the nvim-cmp source contract (verified via the LOCAL blink.compat adapter; nvim-cmp
# itself is NOT installed locally — blink.compat is the authoritative source-API CONSUMER).
- file: /home/dustin/.local/share/nvim/lazy/blink.compat/lua/blink/compat/source.lua
  why: "The nvim-cmp source-API consumer: source.new(opts)→setmetatable; is_available?→bool (omitted⇒true);
        get_trigger_characters?→string[] (omitted⇒{}); get_keyword_pattern?→string; complete(params,cb)
        (REQUIRED — cb called with an LSP CompletionItem[] OR {items=…,isInComplete=…} OR nil/empty⇒no items);
        resolve?/execute? optional. complete() returns NOTHING (no cancel fn). execute(item,cb) is
        ADDITIVE: blink.compat applies the default text FIRST then calls s:execute (no skip param)."
  critical: "The contract has NO cancel/abort hook from complete(). execute() runs AFTER cmp's own
             text insertion (verified in source:execute). ⇒ Do NOT implement execute for acceptance
             (it would read a post-insertion buffer). Use a custom confirm mapping instead (M.confirm)."

- file: /home/dustin/.local/share/nvim/lazy/blink.compat/lua/blink/compat/lib/context.lua
  why: "The EXACT params.context shape nvim-cmp builds. VERBATIM: cursor = { row=ctx.cursor[1]
        (1-based), col=ctx.cursor[2]+1 (1-based BYTE), line=ctx.cursor[1]-1 (0-based),
        character=str_utfindex(...) }, cursor_line (full line string), cursor_before_line/after_line
        (byte substrings), bufnr, filetype, id (staleness token — we use our own gen-guard)."
  critical: "cursor.col is 1-based BYTE. To feed coords.nvim_to_pi_coords(lines,row,byte_col) which
             expects a 0-based BYTE col (the nvim_win_get_cursor()[2] convention), you MUST do
             byte_col = params.context.cursor.col - 1. THIS -1 IS THE SINGLE MOST IMPORTANT
             cmp-specific DETAIL (blink's col is already 0-based byte; cmp's is 1-based)."

- file: /home/dustin/.local/share/nvim/lazy/blink.compat/lua/blink/compat/registry.lua
  why: "register_source(name, instance) stores sources[name]=instance. Confirms
        require('cmp').register_source('pi-editor', source.new()) is correct (the instance is what
        new() returns). The user lists 'pi-editor' in cmp.setup sources."

- url: https://github.com/hrsh7th/nvim-cmp/blob/main/lua/cmp/source.lua
  why: "Canonical nvim-cmp source implementation (NOT fetched this session — cmp not installed
        locally + no web tools; the contract above was verified via blink.compat, the maintained
        faithful consumer). Implementer MAY spot-check here for exact internal line numbers."
  critical: "The cmp public API used by M.confirm() — cmp.get_active_entry(), cmp.abort(),
             cmp.confirm({behavior,select}), cmp.ConfirmBehavior.Replace, cmp.mapping(fn, modes) —
             is stable-from-knowledge but should be spot-checked against the user's cmp version."

- url: https://github.com/hrsh7th/nvim-cmp/wiki/Creating-A-Source
  why: "Official 'Create a source' guide (NOT fetched this session). Authoritative reference for the
        registration + source contract; cross-check against the blink.compat-verified contract above."

# MUST READ — the pi-editor reuse path (all SHIPPED — do not modify)
- file: plugin/lua/pi-editor/completion.lua   # M.accept(item, prefix_override?)  (S32)
  why: "The full PRD §7.4 accept flow: reads bridge + live buffer + cursor, converts nvim->pi via
        coords, issues bridge.request('applyCompletion', {lines,cursorLine,cursorCol,item,prefix}),
        and in the async cb replaces the WHOLE buffer + sets cursor (NO -1) + menu.close."
  pattern: "completion.accept(item, prefix_override) -> boolean (true iff RPC issued). It reads
            require('pi-editor').bridge fresh and falls back to the current buffer when the builtin
            menu is not attached (menu.get_buf() returns nil)."
  gotcha: "It uses prefix_override via short-circuit: `prefix_override OR menu.get_prefix() OR ''`.
           We ALWAYS pass prefix_override (the getSuggestions result's prefix stashed on the item),
           so menu.get_prefix() is never consulted. Safe WITHOUT menu.attach()."

- file: plugin/lua/pi-editor/bridge.lua   # M.request / M.cancel / M.is_connected  (S26)
  why: "The RPC primitive. M.request(method, params, on_result) -> string|nil id; on_result(err,
        result) called EXACTLY ONCE (vim.schedule_wrap'd => api-safe). M.cancel(id) fires the cb
        with 'cancelled' (no wire msg; no-op if resolved). M.is_connected() -> bool."
  critical: "getSuggestions params = {lines:string[], cursorLine:int, cursorCol:int(UTF-16),
             force?:bool}. OMIT force for the normal cmp trigger (matches the builtin TextChangedI
             path; only the Tab handler sets force=true). null result -> cb(nil,nil) -> treat as empty."

- file: plugin/lua/pi-editor/coords.lua   # M.nvim_to_pi_coords(lines, row_1_idx, byte_col_0_idx) (S29)
  why: "nvim cursor -> pi cursor. Returns {lines=lines, cursorLine=row-1, cursorCol=UTF-16(line,col)}.
        INPUT byte_col is 0-based BYTE (the nvim_win_get_cursor()[2] convention) — so pass
        params.context.cursor.col - 1 (cmp col is 1-based byte)."
  critical: "Do NOT hand-roll UTF-16. Route through coords.nvim_to_pi_coords exactly like
             completion.accept does (centralized seam; multibyte-safe). The ONLY cmp-specific tweak
             is the -1 on the column."

- file: plugin/lua/pi-editor/init.lua   # M.bridge (the published seam; PRD §7.7)
  why: "`require('pi-editor').bridge` is the singleton bridge client (nil until handshake succeeds;
        nil in dormant sessions). The cmp source reads it LIVE inside each method (never cache at
        module load — handshake resolves async)."
  gotcha: "Do NOT require('pi-editor.bridge') at module top-level and cache it — read
           require('pi-editor').bridge inside is_available()/complete()/confirm() so a late
           handshake (or a /reload) is picked up."

# Reference pattern — the gold-standard plenary-FREE smoke (mirror its bootstrap + fake server)
- file: plugin/tests/completion_accept_smoke.lua
  why: "The exact fake-luv-unix-socket-server + REAL-bridge idiom to mirror for cmp_source_smoke.lua:
        spin a server that replies hello->ok, getSuggestions->{items,prefix}; handshake the real
        bridge; drive the module; assert on the requests the server OBSERVED (lines/cursorLine/
        cursorCol). We do NOT round-trip applyCompletion in the cmp smoke (that path is
        completion.accept's, already tested by completion_accept_smoke) — we assert the COMPLETE
        round-trip + the mapped item shape + the -1 cursor correction."
  critical: "This is the Level-3 gate. It MUST be written to a real file and run with
             +\"luafile tests/cmp_source_smoke.lua\" +qa. NEVER pipe a heredoc into nvim stdin
             (AGENTS.md HARD RULE — it hangs the session forever)."

# Reference pattern — a plenary spec that exercises bridge.request (mirror its structure)
- file: plugin/tests/bridge_request_spec.lua
  why: "Plenary/busted layout: describe/it, before_each/after_each cleanup. For the cmp_source_spec
        we INJECT a fake pi.bridge (no socket needed) + a fake `cmp` module (for the confirm-helper
        cases) and spy completion.accept — simpler than a server round-trip and precise on the
        mapping logic + the -1 correction + supersession."

# Architecture note
- file: plan/001_c56962b4fa17/architecture/external_deps.md
  section: "## 3. nvim-cmp Source API"
  why: "The repo's own summary of the source contract + registration snippet. It shows the MINIMAL
        contract (new/is_available/get_trigger_characters/complete) and does NOT cover the
        additive-execute limitation or the cursor.col 1-based-byte detail — blink.compat (above) is
        more authoritative; treat it as the source of truth when they differ."
```

### Current Codebase tree (relevant slice)

```bash
plugin/
├── lua/pi-editor/
│   ├── init.lua          # M.bridge (published seam), M.config, M.descriptor   [SHIPPED — read-only here]
│   ├── bridge.lua        # M.request / M.cancel / M.is_connected / M.handshake [SHIPPED — read-only here]
│   ├── coords.lua        # M.nvim_to_pi_coords / M.pi_to_nvim_coords           [SHIPPED — read-only here]
│   ├── completion.lua    # M.accept(item, prefix_override?) — the REUSE path   [SHIPPED — read-only here]
│   ├── menu.lua          # builtin popup (NOT used by the cmp path)             [SHIPPED — read-only here]
│   ├── notify.lua        # M.once (we do NOT call it — silent degrade)          [SHIPPED — read-only here]
│   └── jsonlreader.lua                                                     [SHIPPED — read-only here]
├── ftplugin/pi-prompt.lua                                                  [SHIPPED — read-only here]
├── plugin/pi-editor.lua                                                    [SHIPPED — read-only here]
└── tests/
    ├── minimal_init.lua       # plenary harness bootstrap (PLENARY_PATH)
    ├── completion_accept_smoke.lua   # PATTERN to mirror (fake-server + real-bridge)
    └── bridge_request_spec.lua       # PATTERN to mirror (plenary layout)
```

### Desired Codebase tree with files to be ADDED (this task)

```bash
plugin/
├── lua/pi-editor/
│   └── cmp_source.lua      # NEW — the optional nvim-cmp source + M.confirm() override (this task's SOLE source file)
└── tests/
    ├── cmp_source_smoke.lua # NEW — plenary-FREE Level-3 gate (fake server + real bridge; complete round-trip + -1)
    └── cmp_source_spec.lua  # NEW — plenary Level-2 gate (fake bridge + fake cmp + spied completion.accept)
```

**File responsibilities**:
- `cmp_source.lua` — exports a `source` table: `new(opts)` constructor + `is_available` /
  `get_trigger_characters` / `complete` methods, AND a module-level `confirm()` helper (the
  pi-faithful acceptance override). No connection-level state; per-source supersession state only.
- `cmp_source_smoke.lua` — end-to-end: real bridge + fake server; proves the complete()
  round-trip (getSuggestions with correct coords incl. the -1, no force) → mapped items
  (label/detail/filterText/kind/data) → cb exactly once; + is_available/get_trigger_characters.
- `cmp_source_spec.lua` — unit-level: injects a fake `pi.bridge` + a fake `cmp` module, asserts
  exact params + the -1 correction + mapping + dedup-of-callback + supersession + confirm() behavior.

### Known Gotchas of our codebase & Library Quirks

```lua
-- CRITICAL (nvim-cmp cursor): params.context.cursor.col is 1-based BYTE. coords.nvim_to_pi_coords
-- expects a 0-based BYTE col (the nvim_win_get_cursor()[2] convention). ALWAYS do:
--   byte_col = params.context.cursor.col - 1    (and row = params.context.cursor.row, already 1-based)
-- For "/mo" at EOL: nvim col 3 (0-based) → cmp col 4 (1-based) → col-1=3 → UTF-16 cursorCol 3. ✓
-- (blink's col is already 0-based byte, so the blink source has NO -1 — cmp does. DON'T copy blindly.)

-- CRITICAL (nvim-cmp): getSuggestions needs the FULL buffer lines[]. params.context.cursor_line is
-- ONE line only. ALWAYS: vim.api.nvim_buf_get_lines(params.context.bufnr or 0, 0, -1, false).

-- CRITICAL (nvim-cmp execute is ADDITIVE): nvim-cmp's source:execute(item, cb) runs AFTER cmp's own
-- text insertion (textEdit→insertText→label) — it has NO skip param (unlike blink's
-- default_implementation). => DO NOT implement execute() to call completion.accept (it would read a
-- POST-insertion buffer). The pi-faithful path is the custom confirm mapping (M.confirm), which
-- intercepts <CR> BEFORE cmp.confirm and does applyCompletion + cmp.abort (no cmp insertion).

-- CRITICAL (callback once + supersession): complete()'s callback must fire EXACTLY ONCE per resolved
-- call. nvim-cmp issues a NEW complete() per keystroke and ignores a stale callback — so the SOURCE
-- must drop superseded async work itself (NO cancel fn is returned from complete). Use a cmp-source-
-- LOCAL gen-guard + bridge.cancel(prev_inflight_id). Do NOT touch completion.lua's singleton state
-- (that belongs to the builtin engine; the user runs ONE engine, PRD §7.7).

-- CRITICAL (filterText): cmp matches the typed keyword against item.filterText (defaults to label).
-- If the user types "/mo" and label is "model", cmp would NOT match. Set filterText = ai.value
-- (e.g. "/model") so the "/"/"@" prefix matches. (label stays ai.label for DISPLAY, per the work item.)

-- CRITICAL (prefix carry): the confirm helper only gets the cmp `entry` back — NOT the getSuggestions
-- result's `prefix`. STASH both pi_item (vim.deepcopy) and pi_prefix on each item's standard LSP `data`
-- field. cmp preserves `data` and returns it on entry.completion_item.data. (Mirrors the builtin
-- engine's fetch-time-prefix behavior; the server reconciles lines+cursor+prefix+item.)

-- CRITICAL (nvim stdin HANG): the smoke test MUST be a file run with +"luafile <path>" +qa.
-- NEVER pipe a heredoc / echo into nvim stdin (AGENTS.md HARD RULE — hangs the session forever).

-- GOTCHA (read bridge LIVE): require("pi-editor").bridge is nil until the async handshake resolves
-- and nil again after /reload before reconnect. Read it INSIDE each method, never at module load.

-- GOTCHA (do NOT require('cmp') at module load): the source module MUST load even when nvim-cmp is
-- NOT installed (so `require("pi-editor.cmp_source")` never throws in a blink-only setup). Read cmp
-- lazily INSIDE M.confirm() (pcall(require, "cmp")). Hardcode KIND_TEXT = 1 (don't require cmp.types).

-- GOTCHA (engine coexistence): this source is OPT-IN (PRD §7.7). If the user ALSO has engine="builtin"
-- active (the ftplugin triggers), BOTH the builtin popup and cmp would drive completion — a user
-- misconfiguration. We do NOT guard against it in code; document that the user should set
-- engine="cmp" (or disable the builtin triggers) in the module docstring. (Wiring engine="cmp" to
-- actually disable the builtin triggers is a SEPARATE concern, NOT this task.)

-- GOTCHA (silent degrade): on no-bridge / not-connected / RPC-error / null-result / bad-params, call
-- the cmp callback with NO items (empty / nil). NEVER vim.notify (the repo convention per S39;
-- double-toasts are worse than none). NEVER throw out of a source method.
```

---

## Implementation Blueprint

### Data models / structures

No new persistent data models beyond a per-source supersession record constructed inside the module:

```lua
-- A mapped cmp CompletionItem (LSP-shaped + our carry fields):
{
  label      = ai.label,          -- string (required by LSP; shown in menu; per work item)
  detail     = ai.description,    -- string? (LSP detail; shown secondary)
  filterText = ai.value,          -- string: so cmp's client-side filter matches the typed "/"/"@" prefix
  kind       = 1,                 -- int: LSP CompletionItemKind.Text == 1 (hardcoded — see gotcha)
  data       = {                  -- LSP-standard opaque field; cmp preserves + returns it on the entry
    pi_item   = vim.deepcopy(ai), -- the ORIGINAL AutocompleteItem {value,label,description} for accept
    pi_prefix = prefix,           -- string: this batch's getSuggestions result.prefix for accept
  },
}
-- NOTE: `data` is a STANDARD LSP field (not custom) — cmp treats it as opaque and hands it back
-- verbatim on entry.completion_item.data. Verified via blink.compat (data flows through untouched).

-- Per-source supersession state (module-local; NOT completion.lua's singleton):
local ss = { gen = 0, inflight_id = nil }  -- bumped per complete(); gen-guard drops stale cbs
```

### Implementation Tasks (ordered by dependencies)

```yaml
Task 1: CREATE plugin/lua/pi-editor/cmp_source.lua
  - IMPLEMENT: a `local M = {}` source table with M.new(opts), M:is_available(),
    M:get_trigger_characters(), M:complete(params, callback); PLUS a module-level M.confirm() helper
    (the pi-faithful acceptance override). Module-local supersession state {gen, inflight_id}.
  - FOLLOW pattern: the nvim-cmp source contract (blink.compat/source.lua) for signatures;
    completion.lua's do_refresh/accept (S30/S32) for the bridge.request + coords + supersession
    + degrade discipline; the blink sibling's blink_source.lua for module SHAPE (local M, KIND_TEXT=1,
    live bridge reads, silent degrade, vim.deepcopy of the original item).
  - NAMING: module returns `M`; constructor `M.new`; source methods colon-style `M:is_available`,
    `M:get_trigger_characters`, `M:complete` (cmp calls them as `source:method()`). The confirm
    helper is a PLAIN module function `M.confirm()` (NOT a source method) returning a `function(fallback)`.
  - PLACEMENT: plugin/lua/pi-editor/cmp_source.lua (PRD §7.2 module layout).
  - DETAILS: see "Implementation Patterns" below (full reference body).
  - DOCSTRING (Mode A): a Lua docstring at top explaining registration in cmp config (register_source
    + sources + the confirm mapping) + the engine="cmp" recommendation + the "execute is additive;
    use M.confirm for pi-faithful accept; a plain cmp.confirm inserts the label (not faithful)" note.

Task 2: CREATE plugin/tests/cmp_source_smoke.lua   (Level-3 gate, plenary-FREE)
  - IMPLEMENT: the fake-luv-server + REAL bridge idiom (mirror completion_accept_smoke.lua's bootstrap).
    Flows: (a) handshake -> pi.bridge set; (b) source.new() -> object; (c) :is_available() == true;
    (d) :get_trigger_characters() deep-equal {"/","@"}; (e) :complete(fake_params, cb) -> server
    OBSERVES getSuggestions {lines={"/mo"}, cursorLine=0, cursorCol=3(utf16), force==nil} (fake_params
    sets cursor = {row=1, col=4, line=0} — the 1-based-byte form — proving the -1 correction) ->
    cb fires with mapped item {label="model", detail=..., filterText="/model", kind=1,
    data.pi_item.value="/model", data.pi_prefix="/mo"}; (f) supersession: a second :complete() with a
    NEW cursor fires; the FIRST cb is dropped (gen-guard) and only the SECOND cb fires. (We do NOT
    round-trip applyCompletion here — that path is completion.accept's, already smoke-tested.)
  - FOLLOW pattern: plugin/tests/completion_accept_smoke.lua bootstrap (rtp append, fake server via
    jsonlreader, real bridge.handshake, vim.wait polling, check(cond,msg) accumulator, SMOKE_PASS/cquit).
  - NAMING: cmp_source_smoke.lua (matches the *_smoke.lua convention). Print "SMOKE_PASS" + exit 0.
  - CRITICAL: write to a FILE; run via +"luafile tests/cmp_source_smoke.lua" +qa. NO heredoc-to-stdin.
  - PLACEMENT: plugin/tests/cmp_source_smoke.lua.

Task 3: CREATE plugin/tests/cmp_source_spec.lua   (Level-2 gate, plenary/busted)
  - IMPLEMENT: unit cases with an INJECTED fake pi.bridge (set/restore around each case), an INJECTED
    fake `cmp` module (package.loaded["cmp"], for the confirm-helper cases), and a SPIED
    completion.accept (replace require("pi-editor.completion").accept with a recorder; restore after).
    Cases: (1) new returns object with is_available/get_trigger_characters/complete; (2) is_available
    true/false (env+bridge matrix); (3) get_trigger_characters {"/","@"}; (4) complete builds
    {lines,cursorLine,cursorCol} via coords WITH the -1 correction (params.context.cursor.col=4 ->
    cursorCol=3 for "/mo"), calls bridge.request("getSuggestions",…), maps items w/ kind=1 +
    filterText=value + data.pi_item/pi_prefix, calls cb EXACTLY ONCE; (5) complete empty/nil when
    not-connected / err / null / bad-params; (6) complete supersession (2 rapid complete() calls ->
    only the 2nd cb fires; bridge.cancel called on the 1st inflight id); (7) M.confirm(): with a fake
    cmp + an active entry whose completion_item.data has a pi_item -> calls completion.accept(pi_item,
    pi_prefix) + cmp.abort, NOT cmp.confirm; with no active entry -> fallback(); with a non-pi entry
    -> cmp.confirm; with cmp missing -> fallback().
  - FOLLOW pattern: plugin/tests/bridge_request_spec.lua (describe/it, before_each/after_each cleanup,
    reset of pi.bridge + completion.accept spy + the fake cmp module).
  - NAMING: cmp_source_spec.lua (matches *_spec.lua convention).
  - PLACEMENT: plugin/tests/cmp_source_spec.lua.
```

### Implementation Patterns & Key Details

```lua
--- === plugin/lua/pi-editor/cmp_source.lua — OPTIONAL nvim-cmp source (PRD §7.7) ===
--- Register in your nvim-cmp config:
---     local cmp = require('cmp')
---     cmp.register_source('pi-editor', require('pi-editor.cmp_source').new())
---     cmp.setup({
---       sources = { { name = 'pi-editor' } },
---       -- For PI-FAITHFUL insertion (pi computes the whole new buffer + cursor), override <CR>/<C-y>:
---       mapping = {
---         ['<CR>']  = cmp.mapping(require('pi-editor.cmp_source').confirm(), { 'i' }),
---         ['<C-y>'] = cmp.mapping(require('pi-editor.cmp_source').confirm(), { 'i' }),
---       },
---     })
--- Recommended: also set `require('pi-editor').setup({ engine = 'cmp' })` so the plugin's builtin
--- popup triggers do not compete with cmp. This source reuses the SAME bridge.getSuggestions +
--- completion.accept(applyCompletion) path as the builtin engine.
---
--- ACCEPTANCE CAVEAT (important): nvim-cmp's source `execute(item,cb)` runs AFTER cmp's own text
--- insertion (textEdit→insertText→label) and has NO skip param, so a source CANNOT cleanly override
--- insertion via execute. The pi-faithful path is the `M.confirm()` mapping above (it calls
--- applyCompletion + cmp.abort, never cmp.confirm). A PLAIN cmp.confirm on a pi item would insert
--- the item's `label` (item.label) — a reasonable display approximation but NOT byte-faithful to pi's
--- TUI (no trailing space / dir-vs-file / cursor reposition). Use M.confirm() for full fidelity.

local M = {}

-- LSP CompletionItemKind.Text == 1. Hardcode 1 (cheap, stable); do NOT require('cmp.types') or
-- 'vim.lsp.protocol' — this module must load even when nvim-cmp is absent (so `require` never throws).
local KIND_TEXT = 1

--- Per-source supersession state. nvim-cmp fires a NEW complete() per keystroke and ignores a stale
--- callback — there is NO cancel-fn returned from complete() (verified via blink.compat). So the
--- SOURCE drops superseded async work itself: gen-guard (correctness) + bridge.cancel(prev id)
--- (optimization). This is cmp-source-LOCAL state — do NOT touch completion.lua's singleton state
--- (that belongs to the builtin engine; the user runs ONE engine, PRD §7.7).
local ss = { gen = 0, inflight_id = nil }

--- The user calls require('pi-editor.cmp_source').new() and hands the result to register_source.
--- `opts` is ignored in v1 (the bridge is read LIVE from require("pi-editor").bridge so a late
--- handshake / /reload is always picked up).
function M.new(opts)                                -- opts ignored in v1
  return setmetatable({}, { __index = M })
end

--- Active iff pi spawned this editor (env var set) AND the bridge connected (pi.bridge ~= nil).
--- (PRD §7.7; mirrors external_deps §3.) Reads the env var + bridge LIVE.
function M:is_available()
  return vim.env.PI_NVIM_BRIDGE ~= nil and require("pi-editor").bridge ~= nil
end

--- Trigger characters (PRD §7.7): "/" (file/slash completion) + "@" (mentions).
function M:get_trigger_characters()
  return { "/", "@" }
end

--- Fetch completions. MUST call `callback` exactly once per resolved call (cmp contract). nvim-cmp
--- has NO cancel-fn return from complete (verified); supersession is handled INTERNALLY (gen-guard).
function M:complete(params, callback)
  local pi_mod = require("pi-editor")
  local bridge = pi_mod.bridge
  local function empty() callback() end   -- cmp treats a nil/empty callback arg as "no items"
  -- (1) silent degrade: no bridge / not connected / bad API -> empty (call cb once). Never throw.
  if not bridge
     or type(bridge.is_connected) ~= "function" or not bridge.is_connected()
     or type(bridge.request) ~= "function" then
    empty(); return
  end
  params = params or {}
  local ctx = (type(params.context) == "table") and params.context or {}
  -- (2) extract the FULL buffer (params.context.cursor_line is ONE line only) + cursor
  local bufnr = (type(ctx.bufnr) == "number") and ctx.bufnr or 0
  local ok, lines = pcall(vim.api.nvim_buf_get_lines, bufnr, 0, -1, false)
  if not ok or type(lines) ~= "table" then empty(); return end
  local cur = (type(ctx.cursor) == "table") and ctx.cursor or {}
  local row = (type(cur.row) == "number") and cur.row or 1           -- 1-based (== nvim row)
  local cmp_col = (type(cur.col) == "number") and cur.col or 1       -- 1-based BYTE (cmp convention)
  local byte_col = cmp_col - 1                                        -- ⚠ cmp 1-based byte -> nvim 0-based byte
  if byte_col < 0 then byte_col = 0 end                               -- defensive (cmp col >= 1)
  -- (3) nvim cursor -> pi cursor (UTF-16); route through the centralized coords seam (multibyte-safe)
  local pi_ok, pi_cur = pcall(require("pi-editor.coords").nvim_to_pi_coords, lines, row, byte_col)
  if not pi_ok or type(pi_cur) ~= "table" then empty(); return end
  local params_rpc = { lines = pi_cur.lines, cursorLine = pi_cur.cursorLine, cursorCol = pi_cur.cursorCol }
  -- NOTE: NO `force` key — matches the builtin normal (TextChangedI) trigger; only Tab sets force=true.
  -- (4) SUPERSEDE: cancel prev in-flight (optimization) + bump gen (correctness boundary).
  if ss.inflight_id and type(bridge.cancel) == "function" then pcall(bridge.cancel, ss.inflight_id) end
  ss.inflight_id = nil
  ss.gen = ss.gen + 1
  local gen = ss.gen
  -- (5) issue getSuggestions; map result -> cmp items; call cb EXACTLY ONCE (gen-guarded)
  local id
  local req_ok
  req_ok, id = pcall(bridge.request, "getSuggestions", params_rpc, function(err, result)
    if gen ~= ss.gen then return end                                   -- STALE (superseded) — drop, touch nothing
    ss.inflight_id = nil
    if err or type(result) ~= "table" then callback(); return end     -- err/null/malformed -> no items
    local raw    = (type(result.items) == "table") and result.items or {}
    local prefix = (type(result.prefix) == "string") and result.prefix or ""
    local mapped = {}
    for i = 1, #raw do
      local it = raw[i]
      if type(it) == "table" then
        mapped[#mapped + 1] = {
          label      = it.label,
          detail     = it.description,
          filterText = it.value,        -- so cmp's client-side filter matches the typed "/"/"@" prefix
          kind       = KIND_TEXT,
          data       = {                -- LSP-standard opaque field; cmp preserves + returns it
            pi_item   = vim.deepcopy(it),  -- ORIGINAL AutocompleteItem for accept (deepcopy: cmp mutates)
            pi_prefix = prefix,            -- this batch's prefix for accept (fetch-time; server reconciles)
          },
        }
      end
    end
    callback(mapped)                                                   -- cb exactly once with the LSP CompletionItem[]
  end)
  if req_ok and type(id) == "string" then ss.inflight_id = id end
  -- (6) NO cancel fn returned (nvim-cmp contract). Supersession handled in (4) + the gen-guard.
end

--- Returns a `function(fallback)` for cmp.mapping that does PI-FAITHFUL insertion for pi items and
--- falls through for non-pi items / no active entry. nvim-cmp's source execute() is ADDITIVE (cmp
--- inserts text FIRST, then calls execute — no skip param), so it CANNOT cleanly override insertion.
--- This confirm mapping intercepts <CR> BEFORE cmp.confirm, calls applyCompletion (pi rewrites the
--- whole buffer + cursor), and aborts cmp (NO cmp text insertion). (research/notes.md §4/§5.)
---
--- Usage: cmp.setup({ mapping = { ['<CR>'] = cmp.mapping(M.confirm(), { 'i' }) } })
function M.confirm()
  return function(fallback)
    local ok, cmp = pcall(require, "cmp")               -- lazy: module loads even without cmp installed
    if not ok or type(cmp) ~= "table" then
      if type(fallback) == "function" then fallback() end
      return
    end
    local entry = (type(cmp.get_active_entry) == "function") and cmp.get_active_entry() or nil
    if not entry then                                    -- no active entry -> default (newline)
      if type(fallback) == "function" then fallback() end
      return
    end
    local citem = (type(entry) == "table") and (entry.completion_item or {}) or {}
    local data = (type(citem.data) == "table") and citem.data or nil
    if not (data and type(data.pi_item) == "table") then
      -- not a pi item -> let cmp handle it normally (other sources' entries)
      if type(cmp.confirm) == "function" then
        local beh = (cmp.ConfirmBehavior and cmp.ConfirmBehavior.Replace) or 1
        cmp.confirm({ behavior = beh, select = false })
      elseif type(fallback) == "function" then
        fallback()
      end
      return
    end
    -- pi-faithful: applyCompletion rewrites the WHOLE buffer + cursor (pi-authoritative). Works
    -- WITHOUT the builtin menu attached (completion.accept falls back to the current buffer + uses
    -- prefix_override). Fire-and-forget (its cb is async); pcall so a bridge bug can't throw.
    pcall(require("pi-editor.completion").accept, data.pi_item, data.pi_prefix)
    if type(cmp.abort) == "function" then cmp.abort() end   -- close menu WITHOUT confirming (no insertion)
  end
end

return M
```

**Non-obvious decisions (justify each in the code comments):**
1. **`KIND_TEXT = 1` hardcoded** — avoids `require("cmp.types")` / `vim.lsp.protocol` so the module
   loads even when nvim-cmp isn't installed (graceful `:require`). The integer is stable across cmp
   versions.
2. **Read `require("pi-editor").bridge` LIVE inside every method** — never cache at module load
   (handshake resolves async; nil before connect / after `/reload`).
3. **`byte_col = params.context.cursor.col - 1`** — cmp's `cursor.col` is 1-based BYTE (verified via
   blink.compat `context.new`); `coords.nvim_to_pi_coords` expects a 0-based BYTE col. This `-1` is
   the single most important cmp-specific detail (the blink source has none — blink's col is already
   0-based byte).
4. **`filterText = it.value`** — cmp matches the typed keyword against `filterText` (defaults to
   `label`). With `label = it.label` (e.g. "model") the user's `/mo` wouldn't match; setting
   `filterText = it.value` (e.g. "/model") makes the `/`/`@` prefix match.
5. **Carry `pi_item` + `pi_prefix` in the standard LSP `data` field** — `data` is the LSP-standard
   opaque field (NOT custom); cmp preserves it and returns it on `entry.completion_item.data`. The
   confirm helper recovers it for `applyCompletion`. `vim.deepcopy` because cmp may mutate items.
6. **No `force` in getSuggestions params** — the normal cmp trigger must not force (only Tab does).
7. **cmp-source-LOCAL supersession state (`ss`)** — do NOT touch `completion.lua`'s singleton state
   (that's the builtin engine's; the user runs ONE engine). The gen-guard drops stale cbs;
   `bridge.cancel(prev_id)` is the optimization.
8. **No cancel fn returned from `complete`** — nvim-cmp's contract has none (verified via
   blink.compat); supersession is internal. (Contrast blink, whose `get_completions` returns a cancel
   fn — another engine-specific difference.)
9. **`execute` is NOT implemented for acceptance** — cmp's `execute` is additive (runs after cmp's
   text insertion, no skip param); calling `completion.accept` from it would read a post-insertion
   buffer. The pi-faithful path is `M.confirm()`.
10. **`M.confirm()` is a plain module function (not a source method)** — it's not part of the nvim-cmp
    source contract; it's a convenience the user binds to `<CR>`/`<C-y>`. Returns a `function(fallback)`
    (cmp.mapping's callback shape). Reads `cmp` lazily + type-guards so it degrades gracefully.

### Integration Points

```yaml
NO new RPC methods:        # reuses getSuggestions + applyCompletion (P1.M2.T6, both SHIPPED)
NO new autocmds:           # the source is driven entirely by cmp's lifecycle
NO buffer manipulation:    # delegates to completion.accept (S32) for the actual edit (via M.confirm)
NO new config keys:        # engine = "cmp" already exists in init.lua defaults (informational only)
REGISTRATION (user side):  # the user's nvim-cmp config (NOT our code):
  local cmp = require('cmp')
  cmp.register_source('pi-editor', require('pi-editor.cmp_source').new())
  cmp.setup({
    sources = { { name = 'pi-editor' } },
    mapping = {
      ['<CR>']  = cmp.mapping(require('pi-editor.cmp_source').confirm(), { 'i' }),
      ['<C-y>'] = cmp.mapping(require('pi-editor.cmp_source').confirm(), { 'i' }),
    },
  })
SEAM CONSUMED:             # require("pi-editor").bridge  (init.lua — published for exactly this use, PRD §7.7)
SEAM CONSUMED:             # require("pi-editor.completion").accept(item, prefix_override?)  (S32) [via M.confirm]
SEAM CONSUMED:             # require("pi-editor.coords").nvim_to_pi_coords(lines, row, byte_col)  (S29)
```

---

## Validation Loop

> **AGENTS.md HARD RULE (load-bearing):** every nvim invocation below writes the script to a real
> FILE and runs it with `+"luafile <path>" +qa`. **NEVER** pipe a heredoc / `echo` into nvim stdin —
> it deadlocks headless nvim and hangs the session forever. Always wrap with `timeout`.

### Level 1: Syntax & Style (run from `plugin/`)

```bash
# Load-check: the module must parse + require cleanly (nvim-cmp need NOT be installed).
timeout 30 nvim --headless --clean -u NORC \
  -c 'set rtp+=.' \
  -c 'lua local ok, M = pcall(require, "pi-editor.cmp_source"); assert(ok, "require failed: "..tostring(M)); assert(type(M.new)=="function", "M.new missing"); assert(type(M.confirm)=="function", "M.confirm missing"); local s = M.new(); assert(type(s.is_available)=="function" and type(s.get_trigger_characters)=="function" and type(s.complete)=="function", "source methods missing"); print("LOAD_OK")' \
  -c 'qa'
echo "exit=$?   # 0 + LOAD_OK = pass"

# If selene/luacheck are configured in this repo, lint the new file (best-effort; not blocking):
#   selene --config <repo-selene.toml> plugin/lua/pi-editor/cmp_source.lua   2>/dev/null || true
# Expected: LOAD_OK, exit 0. Fix any parse error before proceeding.
```

### Level 2: Unit Tests (plenary/busted) — run from `plugin/`

```bash
# The cmp source spec (fake bridge + fake cmp + spied completion.accept).
timeout 90 nvim --headless --clean -u tests/minimal_init.lua \
  -c 'lua require("plenary.busted").run("tests/cmp_source_spec.lua")'
echo "exit=$?   # 0 = all cases pass"

# Expected: 0 failures. If a case fails, READ the assertion message — it pinpoints the defect
# (bad params / wrong -1 / wrong kind / double-callback / supersession / confirm called default / etc.).
```

### Level 3: Integration (plenary-FREE smoke) — run from `plugin/`

```bash
# End-to-end: real bridge + fake server + the source module. Proves the complete() round-trip:
# handshake -> getSuggestions(correct coords incl. the -1, no force) -> mapped items (kind=1,
# filterText=value, data.pi_item/pi_prefix) -> cb exactly once; + is_available/get_trigger_characters;
# + supersession (a 2nd complete() drops the 1st cb).
timeout 60 nvim --headless --clean -u NORC +"luafile tests/cmp_source_smoke.lua" +qa
echo "exit=$?   # 0 + 'SMOKE_PASS' = pass; 1 = a check failed (read the FAIL: lines on stderr)"

# Expected: prints "SMOKE_PASS", exit 0. The smoke MUST assert:
#   * server saw getSuggestions { lines={"/mo"}, cursorLine=0, cursorCol=3(utf16), force==nil }
#     (fake_params.context.cursor = {row=1, col=4, line=0} — the 1-based-byte form — PROVES the -1)
#   * cb got items[1] = {label="model", detail=<desc>, filterText="/model", kind=1,
#     data.pi_item.value="/model", data.pi_prefix="/mo"}
#   * supersession: 2nd complete() (new cursor) -> only the 2nd cb fires; the 1st is dropped
```

### Level 4: Domain-specific (manual registration sanity, OPTIONAL)

```bash
# Only if nvim-cmp is installed in the test nvim: confirm register_source doesn't error and the source
# shows up. This is a manual/interactive check (open a pi-prompt buffer, type "/", confirm candidates;
# map <CR> to M.confirm() and confirm pi-faithful insertion). NOT automated — the Level-3 smoke already
# proves the source contract end-to-end with a fake bridge, so this level is informational. Skip if
# nvim-cmp isn't on the test runtimepath (it is NOT on this machine — only blink.cmp is installed).
```

---

## Final Validation Checklist

### Technical Validation
- [ ] Level 1: module loads (`LOAD_OK`, exit 0) without nvim-cmp installed.
- [ ] Level 2: `cmp_source_spec.lua` all cases pass (exit 0).
- [ ] Level 3: `cmp_source_smoke.lua` prints `SMOKE_PASS`, exit 0.
- [ ] No file other than the 3 new files (`cmp_source.lua` + 2 tests) was modified.

### Feature Validation
- [ ] `new(opts)` returns an object with `is_available`, `get_trigger_characters`, `complete`.
- [ ] `:is_available()` true iff env var AND `pi.bridge` set; false otherwise.
- [ ] `:get_trigger_characters()` == `{ "/", "@" }`.
- [ ] `:complete()` calls `bridge.request("getSuggestions", {lines, cursorLine, cursorCol})` with **no `force`**,
      via `coords.nvim_to_pi_coords(lines, row, params.context.cursor.col - 1)` (the -1 is verified).
- [ ] Mapped items are `{label, detail=description, filterText=value, kind=1, data={pi_item=deepcopy(orig), pi_prefix=prefix}}`.
- [ ] The cmp callback is called **exactly once** per resolved call; degrade paths emit empty/`nil`.
- [ ] A superseded `complete()` call's cb is gen-guarded and dropped; `bridge.cancel(prev_id)` is called.
- [ ] `complete()` does NOT return a cancel function (nvim-cmp contract).
- [ ] `M.confirm()` for a pi item calls `completion.accept(pi_item, pi_prefix)` + `cmp.abort()` and does NOT call `cmp.confirm`.
- [ ] `M.confirm()` for a non-pi item / no active entry / no cmp calls `fallback()` or `cmp.confirm`.
- [ ] `execute` is NOT implemented for acceptance (it's additive; would break applyCompletion).
- [ ] No `vim.notify` calls added (silent degrade; S39 owns toasts).

### Code Quality Validation
- [ ] Follows the repo's plenary-free smoke idiom (mirror `completion_accept_smoke.lua`).
- [ ] Mode-A Lua docstring documents nvim-cmp registration + the confirm mapping + `engine="cmp"` + the acceptance caveat.
- [ ] No connection-level module state; cmp-source-local supersession state only (does not touch completion.lua's).
- [ ] `cmp` is required LAZILY inside `M.confirm()` (pcall); the module loads without nvim-cmp installed.
- [ ] Every degrade path is `pcall`-safe / never throws out of a source method.
- [ ] Smoke test is a real file run with `:luafile` (never piped to nvim stdin — AGENTS.md HARD RULE).

---

## Anti-Patterns to Avoid

- ❌ Don't `require("pi-editor.bridge")` / `require("cmp")` at module top-level — read the bridge LIVE
  inside each method, and read `cmp` lazily (pcall) inside `M.confirm()` so the module loads without cmp.
- ❌ Don't use `params.context.cursor_line` as the `lines[]` for getSuggestions — it's ONE line; fetch the full buffer.
- ❌ Don't pass `params.context.cursor.col` directly to `coords.nvim_to_pi_coords` — it's 1-based BYTE;
  subtract 1 (`byte_col = col - 1`). (The blink source has no -1 because blink's col is 0-based byte.)
- ❌ Don't implement `source:execute` to call `completion.accept` — cmp's `execute` is ADDITIVE (runs
  after cmp's text insertion); it would read a post-insertion buffer. Use the `M.confirm()` mapping.
- ❌ Don't hand-roll UTF-16 — route through `coords.nvim_to_pi_coords`.
- ❌ Don't call the complete callback more than once per resolved invocation, and DON'T call it for a
  superseded (gen-guarded) call.
- ❌ Don't return a cancel function from `complete` (nvim-cmp's contract has none) — handle supersession internally.
- ❌ Don't set `label = it.value` (use it.label per the work item) WITHOUT also setting `filterText = it.value`
  — cmp filters against label by default and a "/mo" prefix wouldn't match a "model" label.
- ❌ Don't add `force=true` to the normal cmp trigger (only Tab forces).
- ❌ Don't `vim.notify` on degrade (silent empty-list is correct; S39 owns toasts).
- ❌ Don't touch `completion.lua`'s singleton state (that's the builtin engine's; keep cmp-source-local supersession).
- ❌ Don't pipe a heredoc into `nvim` stdin in ANY validation command (AGENTS.md HARD RULE — hangs).

---

## Confidence Score

**9 / 10** for one-pass success.

Rationale: every consumed API is already shipped and quoted verbatim (`completion.accept`,
`bridge.request`/`cancel`/`is_connected`, `coords.nvim_to_pi_coords`, `pi.bridge`). The nvim-cmp
source contract was verified against the locally-installed **blink.compat** adapter (the authoritative
nvim-cmp source-API consumer) — not guessed — including the load-bearing **`cursor.col - 1`** 1-based-byte
correction (confirmed verbatim from `blink.compat/lib/context.lua`). The one genuinely non-obvious
design point — that nvim-cmp's additive `execute` cannot cleanly override insertion, necessitating a
custom confirm mapping (`M.confirm`) — is fully specified with a justification and a defensive
implementation. The reuse of `completion.accept` means this module owns NO buffer-editing logic (the
riskiest part already exists and is tested). The only residual uncertainty is the cmp **public API**
used by `M.confirm()` (`get_active_entry`/`abort`/`confirm`/`mapping`) — stable-from-knowledge but not
line-verified (cmp not installed locally; no web tools this session). That risk is bounded: the
source-contract correctness (new/is_available/get_trigger_characters/complete) is proven end-to-end by
the Level-3 smoke with a fake bridge, and the confirm helper is defensive (pcall + type-guards) so a
cmp API mismatch degrades to a fallback rather than throwing.