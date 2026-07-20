name: "P4.M12.T30.S46 — nvim-cmp completion source module (pi-editor.nvim)"
description: |

  Create `plugin/lua/pi-editor/cmp_source.lua` — an OPT-IN [nvim-cmp](https://github.com/hrsh7th/nvim-cmp)
  completion source that exposes pi's **live** `AutocompleteProvider` (slash commands,
  `skill:` templates, argument completions, `@file` mentions, paths) through nvim-cmp's
  source interface, by delegating to the COMPLETE in-tree bridge + coords modules. This
  is Component B §7.7's second optional integration (P4) and the DIRECT ANALOG of the
  COMPLETE `blink_source.lua` (S45). The source is dormant outside pi prompt buffers and
  NEVER requires `cmp` at runtime.

---

## Goal

**Feature Goal**: A self-contained nvim-cmp source module (`pi-editor.cmp_source`) that,
when the USER registers it in their nvim-cmp config, drives nvim-cmp's completion menu
from pi's live provider over the existing Unix-socket bridge — `new` /
`get_trigger_characters` / `is_available` / `complete` / `execute` (accept). Insertion on
accept is byte-for-byte identical to pi's TUI because `execute` delegates to pi's
authoritative `applyCompletion`.

**Deliverable**: One new Lua module `plugin/lua/pi-editor/cmp_source.lua` exporting
`source.new()` → an nvim-cmp source object implementing `is_available`,
`get_trigger_characters`, `get_keyword_pattern`, `complete`, and `execute`; plus a
plenary spec `plugin/tests/cmp_source_spec.lua` and a plenary-free smoke
`plugin/tests/cmp_source_smoke.lua`.

**Success Definition**: A user who adds
`require("cmp").register_source("pi", require("pi-editor.cmp_source").new())` to their
nvim-cmp config (with the `pi-editor-bridge` extension installed and pi's editor open)
sees pi's `/commands`, `@files`, and paths in nvim-cmp's menu; accepting an item inserts
it exactly as pi's TUI would (e.g. `/model` → `/model `, `comp.ts` → `@/src/comp.ts `).
The module loads cleanly when nvim-cmp is NOT installed, and the spec + smoke pass.

## User Persona

**Target User**: A pi user who already runs nvim-cmp (the established Lua completion
engine) and wants pi's completions in **their** familiar nvim-cmp menu rather than the
plugin's dependency-free floating menu (P2.M8) or blink.cmp (S45).

**Use Case**: Editing a pi prompt in `$EDITOR=nvim` with the bridge active, typing `/mo`
and accepting `/model` from the nvim-cmp popup.

**Pain Points Addressed**: Reuse the user's existing nvim-cmp config (keymaps, window,
formatting, kind icons) without forcing a second completion engine. No re-learning of
keybindings; no double-UI (the source is opt-in + gated on the `pi-prompt` filetype).

## Why

- Users who already run nvim-cmp want pi's completions in **their** UI rather than the
  plugin's dependency-free floating menu (P2.M8) or blink.cmp (S45). PRD §1 Goal:
  "Integration with the user's existing completion engine is optional."
- The same live provider serves all three UIs, so behavior stays identical to the TUI
  (PRD §1 Goal: "byte-for-byte identical… because the same live provider produces and
  applies the suggestions"). Acceptance is delegated back to pi's `applyCompletion`
  (PRD §7.7 / TL;DR) — the source never reimplements insertion edge cases.
- Reuses 100% of the existing infrastructure (bridge RPC, coords, config); adds no new
  sockets, no new state machines, no runtime dependency on nvim-cmp. The module is the
  near-verbatim nvim-cmp-flavored twin of the COMPLETE `blink_source.lua` (S45).

## What

An nvim-cmp source (the "classic" module convention used by `cmp-buffer` / `cmp-path` /
codecompanion-cmp) that:

- `source.new()` → returns `setmetatable({}, { __index = source })`.
- `is_available()` → `vim.bo.filetype == "pi-prompt"` (source-level dormancy gate — the
  twin of `init.lua`'s VimEnter activation gate + blink's `enabled()`; safe to register
  globally).
- `get_trigger_characters()` → `{ "/", "@" }` (pi's two trigger chars; optionally `#`).
- `get_keyword_pattern(params)` → `[[\k\+]]` (the cmp default; informational — our items
  always carry an explicit `textEdit` that overrides the keyword-derived range).
- `complete(request, callback)` → reads the buffer + cursor, converts nvim→pi via coords,
  issues `getSuggestions` over the bridge (two-layer supersession via `state.gen` +
  `bridge.cancel`), maps pi items → `lsp.CompletionItem`s (label/kind/detail/textEdit/data),
  and calls nvim-cmp's `callback` exactly once with `{ items = {...}, isIncomplete = false }`.
  Error/nothing → `callback()`.
- `execute(completion_item, callback)` → reads the pre-accept snapshot from
  `completion_item.data` (which MUST include `bufnr` — nvim-cmp's `execute` takes NO
  request/context, unlike blink's), issues `applyCompletion` over the bridge, calls
  `callback(completion_item)` immediately (responsive; never stalls cmp), and in the async
  cb overwrites the WHOLE buffer + sets the cursor from pi's authoritative result.
- Never `require("cmp")` at runtime (it is the user's plugin; we reference its contract
  only via the method names + a short docstring).

### Success Criteria

- [ ] `require("pi-editor.cmp_source")` succeeds with nvim-cmp NOT installed
      (`package.loaded["cmp"]` stays nil; no runtime `require("cmp")`).
- [ ] `source.new()` returns a source object with `is_available` / `get_trigger_characters`
      / `get_keyword_pattern` / `complete` / `execute` all functions.
- [ ] `get_trigger_characters()` contains `"/"` and `"@"`.
- [ ] `is_available()` is true in a `pi-prompt` buffer, false otherwise.
- [ ] `complete` issues `getSuggestions` with the EXACT params completion.lua uses
      (`{lines, cursorLine, cursorCol, force=false}`, nvim→pi via coords).
- [ ] `complete` maps pi items to cmp items with `label/kind/detail/textEdit/data` and
      calls `callback` exactly once with `{items=…, isIncomplete=false}`; `data` includes
      `bufnr` + the pi item + prefix + lines + cursorLine + cursorCol snapshot.
- [ ] `complete` supersession: a newer `state.gen` wins; an error/cancel/timeout resolves
      `callback()` — no throw, no stale items.
- [ ] `execute` issues `applyCompletion` with `{lines, cursorLine, cursorCol, item, prefix}`,
      calls `callback(item)` immediately, and the async cb replaces the whole buffer + sets
      the cursor (0-based byte col, NO `-1`) on `data.bufnr` — byte-identical to
      completion.lua's accept + blink's execute.
- [ ] `execute` never throws and never fails to call `callback(item)` (malformed
      `completion_item.data`, nil bridge, wiped buf → `callback(item)` + degrade).
- [ ] Plenary spec passes; plenary-free smoke passes (fake luv socket + real bridge
      handshake + real module, driven directly — no real nvim-cmp).

## All Needed Context

### Context Completeness Check

An implementer who knows nothing about this repo gets, from this PRP: the EXACT nvim-cmp
source contract (method names, `request`/`callback`/item shapes, units of every
`context.cursor` field), the EXACT integration seams (which in-tree modules to call and
with what params), the load-bearing accept design decision (why `execute` overwrites
wholesale via `applyCompletion`), the two-layer supersession pattern (using `state.gen`
since cmp gives no id, unlike blink's `ctx.id`), the "never require cmp" rule, the test
strategy, and the AGENTS.md hard rule on nvim invocation. The DIRECTLY-ANALOGOUS
`blink_source.lua` (S45, COMPLETE) is the #1 reference — this module is its nvim-cmp twin.
All referenced files are in-tree and COMPLETE.

### Documentation & References

```yaml
# MUST READ — the DIRECT ANALOG (this module is its nvim-cmp twin; ~80% of the code ports verbatim)
- file: plugin/lua/pi-editor/blink_source.lua
  why: the COMPLETE blink.cmp source (S45). It is the proven template for EXACTLY this task:
        pass-through new()/trigger chars/filetype-gate; read-bridge-fresh; nvim→pi via coords;
        getSuggestions with {lines,cursorLine,cursorCol,force=false}; TWO-LAYER supersession;
        map_item via coords (textEdit.range + data snapshot); guess_kind; accept-via-execute
        (applyCompletion + whole-buffer overwrite + 0-based-byte cursor NO -1 + menu.close).
  pattern: "read bridge FRESH at call time"; "pcall every bridge/nvim call"; "never throws".
  critical: PORT the map_item + guess_kind + execute cb bodies VERBATIM (cmp items are the SAME
        lsp.CompletionItem shape blink uses). ONLY the method names, the ctx→request arg shape,
        the callback success-shape, and the execute signature (no ctx → bufnr in data) differ.

# MUST READ — the nvim-cmp source contract (authoritative; cross-checked locally via blink.compat)
- url: https://github.com/hrsh7th/nvim-cmp/blob/master/doc/cmp.txt
  why: ":help cmp-development" / ":help cmp-source" — the authoritative custom-source contract.
        Confirms source.complete(request, callback) is the primary method; the SourceRequestParams
        shape; the {items, isIncomplete} response; that resolve/execute are the optional
        per-item hooks; and the registration via cmp.register_source.
  critical: execute is the CONFIRM hook; nvim-cmp applies the item's textEdit BEFORE calling execute.

- url: https://github.com/hrsh7th/nvim-cmp/blob/master/lua/cmp/context.lua
  why: the cmp.Context + cursor units. context.cursor.row = nvim_win_get_cursor(0)[1] (1-based);
        context.cursor.col = nvim_win_get_cursor(0)[2] + 1 (1-based BYTE); context.cursor.line = row-1
        (0-based); context.cursor.character = codepoint. context.bufnr / cursor_line / cursor_before_line.
  critical: col is 1-based BYTE — we sidestep the ±1 by reading nvim_win_get_cursor(0) DIRECTLY in
        complete (same as blink), using request.context.bufnr only to pick the buffer. See research notes §2b.

- url: https://github.com/olimorris/codecompanion.nvim/blob/main/lua/codecompanion/providers/completion/cmp/init.lua
  why: the closest real-world analog — a chat-buffer slash-command nvim-cmp source. MIRROR its:
        source.new()=setmetatable; source:is_available() filetype gate; source:get_trigger_characters();
        source:complete(request, callback) reading request.context.cursor + request.offset and building
        {items={lsp.CompletionItem}, isIncomplete=false}; source:execute(completion_item, callback).
  critical: codecompanion-cmp calls callback() / callback(completion_item) EXACTLY ONCE.

- url: https://github.com/hrsh7th/cmp-buffer/blob/main/lua/cmp_buffer/init.lua
  why: the canonical SIMPLE source — confirms source.new/setmetatable, get_trigger_characters,
        get_keyword_pattern, complete(request, callback) reading request.context.cursor_line +
        request.offset to compute the keyword range, building lsp.CompletionItems with textEdit.
  pattern: the structural template we mirror verbatim.

# MUST READ — this repo's seams (all COMPLETE + in-tree)
- file: plugin/lua/pi-editor/bridge.lua
  why: the bridge client. source uses: bridge.request(method, params, cb)->id|nil (cb(err,result),
        schedule_wrap'd → api-safe), bridge.is_connected(), bridge.cancel(id) (supersession),
        bridge.server_info.{cwd,fdAvailable}. Set on require("pi-editor").bridge ONLY after hello.
  pattern: "read bridge FRESH at call time" (handshake resolves async + tests swap fakes after require).
  gotcha: bridge.request cb NEVER includes the token in error strings (PRD §12); result:null → cb(nil,nil).

- file: plugin/lua/pi-editor/completion.lua
  why: the DO_REFRESH (getSuggestions) + ACCEPT (applyCompletion) reference. COPY its exact RPC param
        shapes + the two-layer supersession (cancel + `state.gen` guard — completion.lua uses `gen`, the
        cmp source's correct analog since cmp gives NO ctx.id, unlike blink) + the "bridge read fresh" rule
        + the async-cb whole-buffer-replace + nvim_win_set_cursor with 0-based byte col (NO -1).
  pattern: getSuggestions params = vim.tbl_extend("keep", coords.nvim_to_pi_coords(...), {force=false});
        applyCompletion params = {lines, cursorLine, cursorCol, item, prefix}; result = {lines,cursorLine,cursorCol}.
  gotcha: error/cancel/timeout → touch nothing (no menu clear, no stale items).

- file: plugin/lua/pi-editor/coords.lua
  why: THE centralized byte↔UTF-16 + nvim↔pi seam (PRD §8 "MUST be centralized"). source uses
        nvim_to_pi_coords(lines, row, byte_col)->{lines,cursorLine,cursorCol} for getSuggestions,
        pi_to_nvim_coords(lines, cl, cc)->{lines,row,col} for the applyCompletion cb. NEVER call
        vim.str_utfindex/str_byteindex directly. nvim_to_pi_coords wants row 1-based + byte_col 0-based
        BYTE (the raw nvim_win_get_cursor(0)[2]) — so complete reads the cursor via nvim_win_get_cursor(0)
        directly (NOT request.context.cursor.col, which is 1-based) for byte-identical conversion to blink.
  gotcha: pi_to_nvim_coords returns a 0-based BYTE col ready for nvim_win_set_cursor UNCHANGED — NO -1
        (supersedes PRD §7.4's `bytecol - 1`, which would nudge the cursor one byte left on multibyte).

- file: plugin/lua/pi-editor/init.lua
  why: config + the bridge handle. require("pi-editor").config (rpc_timeout_ms, engine, debounce_ms);
        require("pi-editor").bridge (nil until handshake). setup() applies defaults if never called.
  gotcha: do NOT require("cmp") — it is the user's optional plugin, not a project dependency.

- file: plugin/tests/blink_source_spec.lua
  why: the DIRECT test PATTERN to mirror (fake_bridge(opts) with controllable request/cancel/is_connected
        + resolve(i,err,result) / resolve_last; the vim.wait(ms,predicate,5) async style; reset() before/
        after_each; the "one spec per module" rule; never-throws cases). The cmp spec is the same suite
        with: ctx.id→state.gen; callback shape {items,isIncomplete=false}; execute signature (item,cb) with
        bufnr in data; callback(item) on accept.

- file: plugin/tests/blink_source_smoke.lua
  why: the plenary-free smoke PATTERN — fake luv unix-socket server + REAL bridge.handshake + REAL
        module + vim.wait; the file-based +qa invocation (AGENTS.md hard rule). Mirror VERBATIM; swap
        blink→cmp + get_completions→complete + the execute signature.

- docfile: AGENTS.md
  why: the ⛔ HARD RULE — NEVER pipe a heredoc into nvim stdin (it hangs). Write test Lua to a FILE,
        run `+"luafile tests/<file>.lua" +qa`; wrap every nvim call in `timeout`.
  section: "⛔ HARD RULE" + "test runner" (plenary spec + smoke commands).

- docfile: plan/001_c56962b4fa17/P4M12T30S46/research/nvim-cmp-source-contract.md
  why: the consolidated nvim-cmp source-contract brief (units, callback shapes, the gen-vs-ctx.id
        supersession choice, the execute-has-no-ctx→bufnr-in-data gotcha, the full blink-vs-cmp
        diff table in §9). The authoritative quick-reference for this module.
  section: §2 (complete request/context units), §3 (execute signature + ordering), §7 (gen supersession), §9 (diff table).
```

### Current Codebase tree (relevant subset)

```bash
plugin/
  lua/pi-editor/
    init.lua           # setup() + activate(); holds .config + .bridge + .descriptor   [COMPLETE]
    bridge.lua         # socket client, handshake, request/cancel, on_notification     [COMPLETE]
    jsonlreader.lua    # JSONL framing (not used directly by the source)               [COMPLETE]
    coords.lua         # byte↔utf16 + nvim↔pi (THE centralized seam)                    [COMPLETE]
    completion.lua     # builtin-menu trigger/accept/Tab (the reference for RPC shapes) [COMPLETE]
    menu.lua           # builtin floating popup (NOT used by the cmp source)            [COMPLETE]
    blink_source.lua   # the DIRECT ANALOG (S45, COMPLETE) — the template for this task [COMPLETE]
    notify.lua  health.lua
  plugin/pi-editor.lua           # VimEnter shim (activation gate)
  ftplugin/pi-prompt.lua         # buffer-local autocmds → completion.lua (builtin engine)
  tests/
    minimal_init.lua
    completion_spec.lua  completion_accept_smoke.lua
    blink_source_spec.lua  blink_source_smoke.lua   # the test patterns to mirror
    ... (one spec + smoke per module)
extension/  # the pi-side bridge (TypeScript) — COMPLETE, out of scope for S46
```

### Desired Codebase tree with files to be added

```bash
plugin/lua/pi-editor/cmp_source.lua      # NEW — the nvim-cmp source module (S46)
plugin/tests/cmp_source_spec.lua         # NEW — plenary spec (fake bridge; mirrors blink_source_spec)
plugin/tests/cmp_source_smoke.lua        # NEW — plenary-free smoke (fake luv server + real module)
# (S47 the NVIM_APPNAME doc — OUT OF SCOPE for S46)
```

### Known Gotchas of our codebase & Library Quirks

```lua
-- CRITICAL: nvim-cmp is the USER's plugin, NOT a project dependency.
-- NEVER `require("cmp")` at runtime — it errors when nvim-cmp isn't installed (the COMMON case
-- for builtin-menu / blink users) and breaks dormant-by-default. Reference cmp's contract ONLY
-- via the method names + a short docstring. Unlike blink (lazy `module=` registration), nvim-cmp
-- registration is the USER's explicit `require("cmp").register_source("pi", …)` in THEIR config.

-- CRITICAL: nvim-cmp applies the item's textEdit BEFORE calling execute (same ordering as blink).
-- So by the time execute(completion_item, callback) runs, the buffer already has cmp's edit. WE
-- overwrite the WHOLE buffer with applyCompletion's result in the async cb — cmp's textEdit is a
-- transient that gets clobbered. The textEdit is therefore only a GRACEFUL FALLBACK insertion
-- (newText=pi.value); applyCompletion (in execute) is AUTHORITATIVE.

-- CRITICAL: call nvim-cmp's `callback` EXACTLY ONCE per complete / execute, or cmp stalls. On
-- complete error/timeout/cancel → callback() (nil). On execute, call callback(completion_item)
-- IMMEDIATELY after issuing applyCompletion (responsive; NEVER stalls cmp even if the RPC times
-- out — the buffer mutation is async fire-and-forget in the cb).

-- CRITICAL (difference vs blink): nvim-cmp's execute signature is execute(completion_item, callback)
-- — NO request/context argument (blink's was execute(ctx, item, cb, default_impl)). THEREFORE the
-- buffer handle MUST be carried on completion_item.data.bufnr (captured at complete time). On accept,
-- read bufnr from the snapshot, NOT from a ctx.

-- CRITICAL (difference vs blink): nvim-cmp passes NO id to complete (blink passed ctx.id). So the
-- layer-2 supersession guard uses a SELF-INCREMENTED state.gen (mirrors completion.lua's `gen`, NOT
-- blink's ctx.id). Two layers: bridge.cancel(prev_inflight_id) (optimization) + my_gen==state.gen in
-- the cb (correctness; cmp itself discards stale responses, but the gen guard prevents a stale cb
-- from racing an execute's whole-buffer-replace).

-- GOTCHA: request.context.cursor.col is 1-based BYTE; nvim_to_pi_coords wants 0-based byte. SIDESTEP:
-- read the cursor DIRECTLY via nvim_win_get_cursor(0) in complete (same as blink), using
-- request.context.bufnr only to pick the buffer. This keeps the coords conversion byte-identical to
-- blink/completion.lua (no ±1 footgun).

-- GOTCHA: bridge.request cb is schedule_wrap'd → api-safe (main loop). Do NOT add vim.schedule_wrap
-- around nvim-cmp's callback (a needless hop — mirrors completion.lua + blink_source).

-- GOTCHA: nvim_win_set_cursor col is 0-based BYTE (coords.pi_to_nvim_coords returns exactly that).
-- NO `-1` (PRD §7.4's bytecol-1 is superseded by coords.lua's exact-UTF-16 design).

-- GOTCHA: bridge is read FRESH at call time (require("pi-editor").bridge INSIDE the fn), NOT a
-- module-load local. The handshake resolves async after VimEnter; tests swap a fake bridge in after
-- require; /reload re-runs activate. Same for coords.

-- GOTCHA: cmp items take ONLY lsp fields + label + kind + detail + textEdit + data (cmp does NOT add
-- source_id/source_name to the table the way blink does, but it tracks the source internally — we set
-- nothing extra). `data` is the ONLY field that round-trips our pi item + bufnr + pre-accept snapshot
-- into execute() (cmp passes the accepted item — including data — back to us).

-- GOTCHA: lsp.CompletionItemKind values: 17=File, 19=Folder, 14=Keyword, 3=Function, 1=Text. Map pi
-- items (pi items don't carry a kind): slash/template/skill (value starts with "/") → Keyword; @file →
-- File; directory → Folder; else → Text. PORT guess_kind VERBATIM from blink_source.lua.

-- GOTCHA: the textEdit.range must be a VALID lsp.Range (0-based line + 0-based UTF-16 character).
-- PORT the coords-derived range VERBATIM from blink_source.lua map_item (end=cursor utf16; start=end -
-- utf16_len(prefix) via coords.byte_to_utf16). The textEdit is the graceful-fallback insertion
-- (newText=pi.value); applyCompletion (in execute) is authoritative.

-- GOTCHA: get_keyword_pattern is NON-CRITICAL (our items always carry an explicit textEdit that
-- overrides the keyword-derived range). Return [[\k\+]] (cmp default). Trigger chars "/" + "@" fire
-- complete regardless; subsequent chars are \k so cmp keeps the context.
```

## Implementation Blueprint

### Data models / structure

The source is a singleton object (one per nvim-cmp registration). State is minimal:

```lua
--- @class pi-editor.CmpSourceState
--- @field gen         integer   the latest complete-call generation (the supersession guard; cmp gives no id)
--- @field inflight_id string?   the bridge.request id of the in-flight getSuggestions (for bridge.cancel)
local state = { gen = 0, inflight_id = nil }
```

(The cmp source owns NO buffer, NO socket, NO menu. All of that is the bridge's / builtin
engine's job. The source is a pure RPC→item-mapping adapter — exactly like blink_source.)

The pre-accept snapshot carried on each cmp item (NOTE: `bufnr` is required here because
nvim-cmp's `execute` takes NO context, unlike blink's):

```lua
--- @class pi-editor.CmpItemData
--- @field bufnr      integer                     the buffer to mutate on accept (cmp's execute has no ctx)
--- @field pi         pi-editor.AutocompleteItem  forwarded VERBATIM as applyCompletion's `item`
--- @field prefix     string                      the getSuggestions result.prefix (applyCompletion's `prefix`)
--- @field lines      string[]                    the buffer lines at getSuggestions issue time (applyCompletion's `lines`)
--- @field cursorLine integer                     0-indexed pi line (applyCompletion's `cursorLine`)
--- @field cursorCol  integer                     0-indexed UTF-16 pi col (applyCompletion's `cursorCol`)
```

### Implementation Tasks (ordered by dependencies)

```yaml
Task 1: CREATE plugin/lua/pi-editor/cmp_source.lua — module skeleton + new + is_available + get_trigger_characters + get_keyword_pattern
  - IMPLEMENT: `local source = {}`; `source.new()` = `setmetatable({}, { __index = source })`; the module-level
    `state = {gen=0, inflight_id=nil}`; a TEST-ONLY `source._reset_for_test()` (sets gen=0, inflight_id=nil —
    mirrors blink's seam so specs can isolate cases).
  - IMPLEMENT: `function source:is_available()` returns `vim.bo.filetype == "pi-prompt"` (source-level dormancy).
  - IMPLEMENT: `function source:get_trigger_characters()` returns `{ "/", "@" }`.
  - IMPLEMENT: `function source:get_keyword_pattern(params)` returns `[[\k\+]]` (the cmp default; informational —
    our items always carry an explicit textEdit). params is cmp's option table; accept + ignore (read pi config live).
  - FOLLOW pattern: plugin/lua/pi-editor/blink_source.lua (new/get_trigger_characters/enabled shape — PORT VERBATIM,
    renaming enabled→is_available; adding get_keyword_pattern) + cmp-buffer / codecompanion-cmp (the nvim-cmp template).
  - NAMING: the module table is `source` (the nvim-cmp convention — cmp-buffer/cmp-path/codecompanion all use
    `source`); colon-method style (`function source:foo(self,...)`); module returns `source`.
  - PLACEMENT: plugin/lua/pi-editor/cmp_source.lua (alongside blink_source.lua / completion.lua / coords.lua).
  - GOTCHA: NO `require("cmp")` at runtime. Type-hint only via a short docstring (no emmy @module needed — cmp's
    contract is method-name-based, not type-based).

Task 2: IMPLEMENT source:complete(request, callback) — the data faucet
  - DEFENSIVE: a nil/non-table request → callback() (degrade; never throw). nvim-cmp always passes one.
  - READ the bridge FRESH: `local bridge = require("pi-editor").bridge`. If nil / no is_connected / not a function
    → callback() (nil = "nothing from me"); return. (Graceful; matches cmp-buffer's callback() on nothing.)
  - READ bufnr from the request: `local bufnr = (request and request.context and type(request.context.bufnr)=="number")
    and request.context.bufnr or 0`. Guard buf valid: `if not vim.api.nvim_buf_is_valid(bufnr) then return callback() end`.
  - READ buffer + cursor DIRECTLY (api-safe — complete runs on the main loop; sidesteps request.context.cursor.col's
    1-based-byte ±1 footgun by matching blink/coords.lua's 0-based-byte contract):
      `local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)`;
      `local cur   = vim.api.nvim_win_get_cursor(0)` → `{row 1-based, col 0-based byte}`.
  - CONVERT nvim→pi: `local pi_coords = require("pi-editor.coords").nvim_to_pi_coords(lines, cur[1], cur[2])`.
  - SUPERSEDE layer 1: `if state.inflight_id and type(bridge.cancel)=="function" then pcall(bridge.cancel, state.inflight_id) end`;
    `state.inflight_id = nil`.
  - SUPERSEDE layer 2 (cmp gives no id — self-incremented gen, mirrors completion.lua): `state.gen = (state.gen or 0) + 1;
    local my_gen = state.gen`.
  - ISSUE: `local params = vim.tbl_extend("keep", pi_coords, { force = false })` (EXACT shape completion.lua uses);
    `local ok, rid = pcall(bridge.request, "getSuggestions", params, function(err, result) ... end)`.
  - IN THE CB (schedule_wrap'd by bridge → api-safe):
      * `if my_gen ~= state.gen then return end` (STALE — drop, touch nothing; cmp itself also discards stale responses).
      * `state.inflight_id = nil`.
      * `if err then return callback() end` (timeout/cancel/rpc error → "nothing"; no throw, no stale items).
      * NORMALIZE null: `local items  = (result and type(result.items)  == "table")  and result.items  or {}`;
        `local prefix = (result and type(result.prefix) == "string") and result.prefix or ""`.
      * MAP: build `cmp_items` via a `map_item(pi_item, pi_coords, prefix, bufnr)` helper (Task 3). Skip non-table pi
        items defensively.
      * `callback({ items = cmp_items, isIncomplete = false })`.
  - TRACK inflight: `if ok and type(rid)=="string" then state.inflight_id = rid end`.
  - FOLLOW pattern: plugin/lua/pi-editor/blink_source.lua get_completions (RPC shapes, two-layer supersession,
    "bridge read fresh", null→empty, error→touch-nothing). DIFFERENCES: ctx.id → state.gen; ctx.bufnr → request.context.bufnr;
    cursor read directly (NOT via request.context.cursor); callback success shape {items, isIncomplete=false}.
  - GOTCHA: do NOT wrap nvim-cmp's `callback` in vim.schedule_wrap (the bridge cb already runs on the main loop).

Task 3: IMPLEMENT map_item(pi_item, pi_coords, prefix, bufnr) + guess_kind(pi_item) — the item mapper
  - PORT guess_kind VERBATIM from blink_source.lua: `/...` → Keyword (14); `@...` → File (17); directory (ends `/`) →
    Folder (19); else → Text (1). Type-guard pi_item; defensive default Text. Never throws.
  - BUILD the textEdit.range (lsp.Range, 0-based line + 0-based UTF-16 character) — PORT VERBATIM from blink_source.lua
    map_item: line = pi_coords.cursorLine; end_char = pi_coords.cursorCol; start_char = end_char -
    coords.byte_to_utf16(cursor_line, #prefix) (cursor_line = pi_coords.lines[cursorLine+1]); clamp start_char >= 0.
  - RETURN the cmp item (cmp items are the SAME lsp.CompletionItem shape blink uses; cmp does NOT add source_id to the
    table, but tracks the source internally — we set nothing extra):
      `{ label = pi_item.label, kind = guess_kind(pi_item), detail = (string)pi_item.description or nil,
         textEdit = { newText = pi_item.value, range = { start={line=line,character=start_char}, ["end"]={line=line,character=end_char} } },
         data = { bufnr=bufnr, pi=pi_item, prefix=prefix, lines=pi_coords.lines, cursorLine=pi_coords.cursorLine, cursorCol=pi_coords.cursorCol } }`
  - GOTCHA: `data.bufnr` is REQUIRED (nvim-cmp's execute has no ctx — unlike blink). PORT the rest of `data` VERBATIM
    from blink; ADD `bufnr`.
  - GOTCHA: `pi_item` forwarded VERBATIM (the bridge server forwards it verbatim to pi; pi keys on the whole table —
    completion.lua accept does the same).

Task 4: IMPLEMENT source:execute(completion_item, callback) — accept via applyCompletion
  - DEFENSIVE: `local d = completion_item and completion_item.data; if type(d) ~= "table" or type(d.pi) ~= "table" then
    return callback(completion_item) end` (malformed → tell cmp "done"; never stall; never throw). NOTE: pass
    completion_item back to callback (cmp convention; never nil).
  - READ bridge FRESH: `local bridge = require("pi-editor").bridge`. If nil / not connected →
    `callback(completion_item)` return (graceful: cmp's textEdit already applied a basic insertion pre-execute; leave it).
  - READ bufnr from the snapshot (cmp's execute has NO ctx): `local bufnr = (type(d.bufnr)=="number") and d.bufnr or 0`.
    Guard valid: if not nvim_buf_is_valid(bufnr) → `callback(completion_item)` return.
  - ISSUE applyCompletion with the snapshot (EXACT shape completion.lua accept uses): `local params = { lines=d.lines,
    cursorLine=d.cursorLine, cursorCol=d.cursorCol, item=d.pi, prefix=d.prefix }`;
    `pcall(bridge.request, "applyCompletion", params, function(err, result) ... end)`.
  - CALL `callback(completion_item)` IMMEDIATELY after issuing (responsive; cmp considers confirm done; the buffer
    mutation is async fire-and-forget in the cb — mirrors completion.lua on_enter returning true once issued). DO NOT
    wait for the RPC (a timeout would stall cmp's confirm otherwise).
  - IN THE CB (api-safe): on success + table result →
      `local nv = require("pi-editor.coords").pi_to_nvim_coords(result.lines, result.cursorLine, result.cursorCol)`;
      `pcall(vim.api.nvim_buf_set_lines, bufnr, 0, -1, false, nv.lines)` (WHOLE buffer replace on the snapshot buf);
      `pcall(vim.api.nvim_win_set_cursor, 0, { nv.row, nv.col })` (0-based byte col, NO -1);
      also best-effort close the BUILTIN menu if open: `pcall(function() require("pi-editor.menu").close() end)`
      (avoid a stale builtin popup lingering when the user accepted via nvim-cmp — defensive, never throws).
    On error / non-table result → leave the buffer as cmp's textEdit left it (graceful degrade); never throw.
  - FOLLOW pattern: plugin/lua/pi-editor/blink_source.lua execute() + completion.lua accept() (the 5-step applyCompletion
    flow). DIFFERENCES: NO ctx param (bufnr from data); NO default_implementation param (cmp's execute doesn't pass it);
    callback(item) instead of callback(). ONE-SHOT user action → NO gen-guard (capture nothing; the accept is authoritative).
  - GOTCHA: nvim_buf_set_lines is an API mutation → does NOT fire TextChangedI → no refresh loop (completion.lua §5 Q2).

Task 5: CREATE plugin/tests/cmp_source_spec.lua — plenary spec (fake bridge)
  - REUSE/ADAPT `fake_bridge(opts)` from plugin/tests/blink_source_spec.lua: a table with `request` (records calls +
    resolves via a stored cb the test drives), `cancel`, `is_connected` (default true), `server_info`. Set
    `require("pi-editor").bridge = fake` before each test; nil it after.
  - CASES (see Success Criteria): new() shape (is_available/get_trigger_characters/get_keyword_pattern/complete/execute
    all functions); get_trigger_characters contains "/"+"@"; get_keyword_pattern returns a string; is_available (pi-prompt
    vs other); complete happy path (assert getSuggestions params {lines,cursorLine,cursorCol,force=false} + item mapping
    + {items,isIncomplete=false} callback shape + data.bufnr); item-kind heuristic (@file→File, dir→Folder, plain→Text);
    supersession (older cb dropped at the gen-guard / callback() nil; newer wins; cancel(prev_id) called); error/cancelled/
    timeout → callback() nil; null result → callback with empty items; bridge nil/disconnected → callback() nil; execute
    happy (applyCompletion params + callback(item) immediate + cb set_lines/set_cursor on data.bufnr; MULTIBYTE cursor);
    execute error → buffer untouched; execute malformed data → callback(item) + no throw; execute does NOT use a default_
    implementation arg (cmp's execute has none); assert package.loaded["cmp"]==nil; never-throws (wiped buf, nil request).
  - FOLLOW pattern: plugin/tests/blink_source_spec.lua (one describe block per behavior group; reset via
    source._reset_for_test() + pi.bridge=nil before/after_each; the vim.wait(ms,predicate,5) async style). DIFFERENCES:
    make_request(bufnr) builds the cmp request subset {context={bufnr=bufnr, cursor={row,col,line,character}, cursor_line=…,
    cursor_before_line=…}, offset=…, completion_context={triggerKind=2, triggerCharacter="/"}; the source reads bufnr +
    cursor(nvim_win_get_cursor) so the request's cursor fields are informational; supersession driven by state.gen (a 2nd
    complete call bumps gen; resolve the 1st cb → callback NOT fired).
  - NAMING: `pi-editor.cmp_source` describe block; COVERAGE: all public methods + error + supersession + never-throws.
  - NOTE: do NOT name a spec-local table `pending` (shadows plenary.busted's global skip fn — mirrors blink_source_spec).

Task 6: CREATE plugin/tests/cmp_source_smoke.lua — plenary-free smoke (fake luv server + real module)
  - MIRROR plugin/tests/blink_source_smoke.lua's bootstrap VERBATIM: fake luv unix-socket server + REAL `bridge.handshake`
    + REAL `cmp_source` + REAL `coords`. NO real nvim-cmp (drive the module directly).
  - FLOW: set buffer `{"@sr"}`, filetype `pi-prompt`, cursor EOL; `src:complete(make_request(bufnr), cb)` → server sees
    `getSuggestions` → reply `{items={{value="@/src/comp.ts",label="comp.ts",description="src/comp.ts"}}, prefix="@sr"}` →
    vim.wait → assert resp.items[1].textEdit.newText=="@/src/comp.ts" + .data.pi.value + .data.prefix + .data.bufnr==bufnr;
    then `src:execute(resp.items[1], function() end)` → server sees `applyCompletion` with `{item=<pi>, prefix="@sr",
    lines={"@sr"}, cursorLine=0, cursorCol=4}` → reply `{lines={"@/src/comp.ts "}, cursorLine=0, cursorCol=14}` → vim.wait →
    assert buffer=={"@/src/comp.ts "} + cursor {1,14}.
  - TEARDOWN: bridge.close() + server stop. Print `SMOKE_PASS` / `vim.cmd('cquit 1')` on fail / exit 0.
  - FOLLOW pattern: plugin/tests/blink_source_smoke.lua (fake server; vim.wait; print PASS marker). make_request builds the
    cmp request subset (context.bufnr + cursor_*); the smoke asserts the source reads bufnr + cursor correctly.
  - ⛔ AGENTS.md HARD RULE: this Lua IS the file (written via the write tool, NEVER heredoc→nvim stdin). Run via
    `timeout 60 nvim --headless --clean -u tests/minimal_init.lua +"luafile tests/cmp_source_smoke.lua" +qa`.
```

### Implementation Patterns & Key Details

```lua
-- PATTERN: the source object (cmp-buffer / codecompanion-cmp convention). One file, method-style, returns source.
local source = {}
source.new = function()
  return setmetatable({}, { __index = source })
end
function source:is_available()              return vim.bo.filetype == "pi-prompt" end
function source:get_trigger_characters()    return { "/", "@" } end
function source:get_keyword_pattern(_params) return [[\k\+]] end -- informational (textEdit overrides)

-- PATTERN: complete — read bridge fresh, read bufnr from request.context + cursor via nvim API, supersede (two-layer:
-- cancel + gen), issue, map, callback once with {items, isIncomplete=false}.
function source:complete(request, callback)
  if type(request) ~= "table" then return callback() end
  local bridge = require("pi-editor").bridge          -- FRESH (handshake async + test fakes)
  if not bridge or type(bridge.is_connected) ~= "function" or not bridge.is_connected() then
    return callback()                                  -- nothing (graceful; matches cmp-buffer)
  end
  local bufnr = (request.context and type(request.context.bufnr) == "number") and request.context.bufnr or 0
  if not vim.api.nvim_buf_is_valid(bufnr) then return callback() end
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local cur   = vim.api.nvim_win_get_cursor(0)         -- {row 1-based, col 0-based byte} (sidesteps cmp's 1-based col)
  local pi_coords = require("pi-editor.coords").nvim_to_pi_coords(lines, cur[1], cur[2])
  -- supersede layer 1 (cancel prev in-flight)
  if state.inflight_id and type(bridge.cancel) == "function" then pcall(bridge.cancel, state.inflight_id) end
  state.inflight_id = nil
  -- supersede layer 2 (gen guard — cmp gives no ctx.id; mirrors completion.lua)
  state.gen = (state.gen or 0) + 1
  local my_gen = state.gen
  local params = vim.tbl_extend("keep", pi_coords, { force = false })
  local ok, rid = pcall(bridge.request, "getSuggestions", params, function(err, result)
    if my_gen ~= state.gen then return end             -- STALE — drop, touch nothing
    state.inflight_id = nil
    if err then return callback() end                  -- timeout/cancel/rpc error → nothing
    local items  = (result and type(result.items)  == "table")  and result.items  or {}
    local prefix = (result and type(result.prefix) == "string") and result.prefix or ""
    local cmp_items = {}
    for _, it in ipairs(items) do
      if type(it) == "table" then cmp_items[#cmp_items + 1] = map_item(it, pi_coords, prefix, bufnr) end
    end
    callback({ items = cmp_items, isIncomplete = false })
  end)
  if ok and type(rid) == "string" then state.inflight_id = rid end
end

-- PATTERN: execute — snapshot on completion_item.data (incl bufnr), issue applyCompletion, callback(item) immediately,
-- async cb overwrites the WHOLE buffer on data.bufnr + sets cursor (0-based byte, NO -1).
function source:execute(completion_item, callback)
  local d = completion_item and completion_item.data
  if type(d) ~= "table" or type(d.pi) ~= "table" then return callback(completion_item) end -- never stall cmp
  local bridge = require("pi-editor").bridge
  if not bridge or type(bridge.is_connected) ~= "function" or not bridge.is_connected() then
    return callback(completion_item)                   -- graceful: cmp's textEdit already applied pre-execute
  end
  local bufnr = (type(d.bufnr) == "number") and d.bufnr or 0
  if not vim.api.nvim_buf_is_valid(bufnr) then return callback(completion_item) end
  local params = { lines = d.lines, cursorLine = d.cursorLine, cursorCol = d.cursorCol,
                   item = d.pi, prefix = d.prefix }     -- EXACT applyCompletion shape (completion.lua accept)
  pcall(bridge.request, "applyCompletion", params, function(err, result)
    if err or type(result) ~= "table" then return end   -- degrade: buffer left as cmp's textEdit
    local nv = require("pi-editor.coords").pi_to_nvim_coords(result.lines, result.cursorLine, result.cursorCol)
    pcall(vim.api.nvim_buf_set_lines, bufnr, 0, -1, false, nv.lines)   -- WHOLE buffer replace (NOT TextChangedI)
    pcall(vim.api.nvim_win_set_cursor, 0, { nv.row, nv.col })          -- 0-based byte col, NO -1
    pcall(function() require("pi-editor.menu").close() end)            -- close stale builtin menu if open
  end)
  callback(completion_item)                             -- IMMEDIATE: never stall cmp (RPC is fire-and-forget)
end
return source

-- PATTERN: map_item + guess_kind — PORT VERBATIM from blink_source.lua; ONLY ADD `data.bufnr`.
-- (see blink_source.lua map_item/guess_kind; the textEdit.range derivation is byte-identical.)
```

### Integration Points

```yaml
CONFIG:
  - add to: the USER's nvim-cmp config (NOT this repo's setup()).
    pattern: |
      require("cmp").setup({
        sources = cmp.config.sources({ { name = "pi" } }),
      })
      -- register once (e.g. in the cmp config or a lazy.nvim `config` fn):
      require("cmp").register_source("pi", require("pi-editor.cmp_source").new())
  - this repo's setup() config.engine ("builtin"|"blink"|"cmp"): the source module READS it
    only to degrade (no behavioral change in S46). See "Known forward-contract" below.

ROUTES / RPC:
  - getSuggestions: {lines, cursorLine, cursorCol, force=false} → {items, prefix} | null. (completion.lua do_refresh shape)
  - applyCompletion: {lines, cursorLine, cursorCol, item, prefix} → {lines, cursorLine, cursorCol}. (completion.lua accept shape)
  - Both via require("pi-editor").bridge.request(method, params, cb) → cb(err, result). NO new sockets.

NO DB / NO MIGRATIONS / NO NEW FILES OUTSIDE the three listed in "Desired Codebase tree".
```

## Validation Loop

### Level 1: Syntax & Style (Immediate Feedback)

```bash
# Lua syntax check (luac) on the new module — run after creating it. (from plugin/)
luac -p plugin/lua/pi-editor/cmp_source.lua && echo "luac OK"
# If selene is configured in the repo, lint the new + test files:
selene plugin/lua/pi-editor/cmp_source.lua plugin/tests/cmp_source_spec.lua plugin/tests/cmp_source_smoke.lua
# stylua format check (if plugin/stylua.toml exists):
stylua --check plugin/lua/pi-editor/cmp_source.lua plugin/tests/cmp_source_spec.lua plugin/tests/cmp_source_smoke.lua
# Expected: zero errors. READ any output + fix before proceeding.
```

### Level 2: Unit Tests (Component Validation — plenary spec)

```bash
# The plenary spec (fake bridge; mirrors blink_source_spec.lua). Run from plugin/.
timeout 90 nvim --headless --clean -u tests/minimal_init.lua \
  -c 'lua require("plenary.busted").run("tests/cmp_source_spec.lua")'
echo "exit=$?"
# Expected: all assertions pass (0 failures). On failure, READ the plenary output + fix the module.
```

### Level 3: Integration Testing (plenary-free smoke — fake luv socket + real module)

```bash
# The plenary-free smoke. Writes nothing to nvim stdin (AGENTS.md HARD RULE) — it IS the file.
timeout 60 nvim --headless --clean -u tests/minimal_init.lua \
  +"luafile tests/cmp_source_smoke.lua" +qa
echo "exit=$?"
# Expected: prints `SMOKE_PASS` and exits 0. If it prints nothing / hangs / exits non-zero:
#   the smoke has a bug or the module regressed. Do NOT pipe a heredoc to fix it — edit the FILE.
```

### Level 4: Domain-Specific Validation (nvim-cmp registration — MANUAL, optional)

```bash
# Manual / scripted: with the pi-editor-bridge extension installed + a real pi editor open, register
# the source in a scratch nvim-cmp config (cmp.register_source("pi", require("pi-editor.cmp_source").new())),
# type `/mo` in the pi prompt buffer, and confirm nvim-cmp shows `/model` (etc.). Accepting inserts
# `/model ` (trailing space) — proving execute→applyCompletion is byte-identical to the TUI. This requires
# a real nvim-cmp install (NOT in CI — the env here runs blink.cmp). Document the steps in the module
# docstring; do NOT block S46 on it. (Automated coverage of the same surface = the Level 3 smoke, which
# drives execute directly.)
```

## Final Validation Checklist

### Technical Validation

- [ ] Level 1 (luac/selene/stylua) clean on the 3 new files.
- [ ] Level 2 plenary spec passes (all cases): `timeout 90 nvim … cmp_source_spec.lua`.
- [ ] Level 3 plenary-free smoke prints `SMOKE_PASS` / exit 0: `timeout 60 nvim … +"luafile tests/cmp_source_smoke.lua" +qa`.
- [ ] No nvim invocation pipes a heredoc into stdin (AGENTS.md ⛔ HARD RULE); all wrapped in `timeout`.

### Feature Validation

- [ ] `require("pi-editor.cmp_source")` loads with nvim-cmp NOT installed (`package.loaded["cmp"]==nil`).
- [ ] `source.new()` object has `is_available`/`get_trigger_characters`/`get_keyword_pattern`/`complete`/`execute` as functions.
- [ ] `get_trigger_characters()` contains `"/"` + `"@"`; `is_available()` gates on `pi-prompt` filetype; `get_keyword_pattern()` returns a string.
- [ ] `complete` issues `getSuggestions` with `{lines, cursorLine, cursorCol, force=false}` (coords-converted; cursor read via nvim_win_get_cursor, NOT request.context.cursor.col's 1-based footgun).
- [ ] `complete` maps items to `{label,kind,detail,textEdit,data}` (data includes `bufnr`) + calls `callback` ONCE with `{items, isIncomplete=false}`; supersession via `state.gen`.
- [ ] `execute` issues `applyCompletion` with `{lines, cursorLine, cursorCol, item, prefix}` (snapshot) + calls `callback(completion_item)` immediately; async cb replaces whole buffer on `data.bufnr` + sets cursor (0-based byte, NO -1).
- [ ] Error/cancel/timeout → graceful (`callback()` nil on complete; buffer-untouched on execute); never throws; never stalls cmp.

### Code Quality Validation

- [ ] Follows the repo's [Mode A] dense-docstring convention (every non-obvious decision documented; cross-refs to blink_source.lua / completion.lua / coords.lua / bridge.lua / AGENTS.md + the research notes).
- [ ] Reads bridge + coords FRESH at call time (not module-load locals).
- [ ] Two-layer supersession (bridge.cancel + state.gen) — mirrors completion.lua (cmp gives no ctx.id, unlike blink).
- [ ] `map_item` + `guess_kind` PORTED VERBATIM from blink_source.lua (cmp items are the same lsp.CompletionItem shape); only `data.bufnr` is added.
- [ ] No `require("cmp")` at runtime (user's plugin); no emmy `@module 'cmp'` needed (cmp's contract is method-name-based).
- [ ] Only the 3 new files added; NO modification of init.lua / completion.lua / bridge.lua / coords.lua / menu.lua / ftplugin / extension / blink_source.lua.

### Documentation & Coordination

- [ ] Module docstring documents: the accept design (snapshot + execute overwrites wholesale), the "never require cmp" rule, the registration snippet (`cmp.register_source`), the gen-vs-ctx.id supersession choice, and the execute-has-no-ctx→bufnr-in-data gotcha.
- [ ] Known forward-contract documented: when `config.engine == "cmp"`, the builtin menu autocmds should be suppressed by a FUTURE engine-wiring task (NOT S46) to avoid double-UI. S46's module is correct standalone + additive (mirrors S45's note).

---

## Anti-Patterns to Avoid

- ❌ Do NOT `require("cmp")` at runtime (user's optional plugin; breaks dormant-by-default). Registration is the USER's `cmp.register_source` call, NOT this repo's load.
- ❌ Do NOT reimplement insertion in the textEdit (trailing space, quotes, cursor) — `execute`→`applyCompletion` is authoritative; the textEdit is only the graceful fallback (PORT from blink).
- ❌ Do NOT expect a `ctx`/`request`/`default_implementation` argument in `execute` — nvim-cmp's `execute(completion_item, callback)` takes NEITHER (unlike blink). `bufnr` MUST come from `completion_item.data`.
- ❌ Do NOT use `request.context.cursor.col` for the coords conversion — it is 1-based BYTE and would mis-convert. Read `nvim_win_get_cursor(0)` directly (0-based byte, matches coords.lua + blink).
- ❌ Do NOT use `ctx.id` for supersession — nvim-cmp passes NO id to `complete`. Use a self-incremented `state.gen` (mirrors completion.lua's `gen`).
- ❌ Do NOT skip the gen supersession guard (cancel alone can race; the gen guard is the correctness boundary for a stale cb racing an execute's whole-buffer-replace).
- ❌ Do NOT forget to call nvim-cmp's `callback` exactly once (a missed callback stalls cmp's complete/confirm). Pass `completion_item` back on execute (cmp convention).
- ❌ Do NOT call `vim.str_utfindex`/`str_byteindex` directly — route through `coords.lua` (PRD §8 centralization).
- ❌ Do NOT add `bytecol - 1` (PRD §7.4 superseded by coords.lua's exact-UTF-16 design).
- ❌ Do NOT pipe a heredoc into nvim stdin in any validation command (AGENTS.md ⛔ HARD RULE — it hangs the session).
- ❌ Do NOT modify init.lua/completion.lua/bridge.lua/coords.lua/menu.lua/ftplugin/extension/blink_source.lua (out of scope for S46 — PORT from blink, do not edit it).

---

## Confidence Score

**8 / 10** for one-pass implementation success.

Rationale: this module is the near-verbatim nvim-cmp-flavored twin of the COMPLETE
`blink_source.lua` (S45) — `map_item` / `guess_kind` / the execute cb body port verbatim,
and the accept design is proven by S45 + completion.lua. The integration seams (bridge,
coords, config) are all COMPLETE + in-tree + exhaustively documented. The nvim-cmp source
contract is long-stable (`:help cmp-development`) and cross-checked locally via the
`blink.compat` adapter. The -2 is for: (a) the structural novelties vs S45 — `data.bufnr`
round-trip (cmp's `execute` has no ctx) + `state.gen` supersession (cmp gives no id) —
both are low-complexity and spec'd in the research notes §3/§7/§9, but they ARE new code
paths to get right; (b) no real nvim-cmp install in CI (the env runs blink.cmp) — the
smoke drives the module directly (not real cmp), so the cmp-facing surface (callback
shapes, trigger semantics) is verified against the contract + blink.compat, not a live
cmp; (c) the engine-suppression coordination is out of scope but could surface as a
double-UI if the user uses cmp without the future wiring (documented, same as S45).

## Known Forward-Contracts (out of scope for S46; documented for the follow-up)

1. **Engine wiring / double-UI suppression.** When `config.engine == "blink"|"cmp"`, the
   builtin floating menu (ftplugin autocmds → completion.lua → menu.lua) should be
   SUPPRESSED so only the user's engine shows. S46 ships the self-contained source; a
   later task wires the suppression into the ftplugin/init (likely: the ftplugin checks
   `require("pi-editor").config.engine` before arming the builtin autocmds). Same note as S45.
2. **`resolve` for hover docs** (optional §15 enhancement): a future task could add
   `source:resolve(completion_item, callback)` that calls the bridge's `getCommands` to
   enrich an item's documentation on hover. Out of scope for S46 (items already carry
   `description` as `detail`).
3. **Per-source `option`** (e.g. a user-tunable trigger-char override): `complete` receives
   `request.option` from the registration config. A future task could honor it; S46 reads
   pi config live and ignores `option` (mirrors S45 ignoring blink's opts).