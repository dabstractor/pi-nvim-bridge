name: "P4.M12.T29.S45 — blink.cmp completion source module (pi-editor.nvim)"
description: |

  Create `plugin/lua/pi-editor/blink_source.lua` — an OPT-IN [blink.cmp](https://github.com/Saghen/blink.cmp)
  completion source that exposes pi's **live** `AutocompleteProvider` (slash commands,
  `skill:` templates, argument completions, `@file` mentions, paths) through blink's
  source interface, by delegating to the COMPLETE in-tree bridge + coords modules.
  This is Component B §7.7's first optional integration (P4). The source is dormant
  outside pi prompt buffers and never requires blink.cmp at runtime.

---

## Goal

**Feature Goal**: A self-contained `blink.cmp.Source` module (`pi-editor.blink_source`)
that, when the user registers it in their blink.cmp config, drives blink's completion
menu from pi's live provider over the existing Unix-socket bridge — `get_trigger_characters`,
`get_completions`, and `execute` (accept). Insertion on accept is byte-for-byte
identical to pi's TUI because `execute` delegates to pi's authoritative `applyCompletion`.

**Deliverable**: One new Lua module `plugin/lua/pi-editor/blink_source.lua` exporting
`new(opts)` → a blink.cmp source object implementing `get_trigger_characters`,
`enabled`, `get_completions`, and `execute`; plus a plenary spec
`plugin/tests/blink_source_spec.lua` and a plenary-free smoke
`plugin/tests/blink_source_smoke.lua`.

**Success Definition**: A user who adds
`{ "Saghen/blink.cmp", opts = { sources = { providers = { pi = { name = "pi", module = "pi-editor.blink_source" } } } } }`
to their config, with the `pi-editor-bridge` extension installed and pi's editor
open, sees pi's `/commands`, `@files`, and paths in blink's menu; accepting an item
inserts it exactly as pi's TUI would (e.g. `/model` → `/model `, `comp.ts` →
`@/src/comp.ts `). The module loads cleanly when blink.cmp is NOT installed, and the
spec + smoke pass.

## Why

- Users who already run blink.cmp (a popular, performant completion engine) want pi's
  completions in **their** familiar UI rather than the plugin's dependency-free
  floating menu (P2.M8). PRD §1 Goal: "Integration with the user's existing
  completion engine is optional."
- The same live provider serves both UIs, so behavior stays identical to the TUI
  (PRD §1 Goal: "byte-for-byte identical… because the same live provider produces and
  applies the suggestions"). Acceptance is delegated back to pi's `applyCompletion`
  (PRD §7.7 / TL;DR) — the source never reimplements insertion edge cases.
- Reuses 100% of the existing infrastructure (bridge RPC, coords, config); adds no
  new sockets, no new state machines, no runtime dependency on blink.cmp.

## What

A `blink.cmp.Source` that:

- `new(opts)` → returns `setmetatable({}, { __index = M })` (codecompanion pattern).
- `get_trigger_characters()` → `{ "/", "@" }` (pi's two trigger chars; optionally `#`).
- `enabled()` → `vim.bo.filetype == "pi-prompt"` (source-level dormancy gate — the
  twin of `init.lua`'s VimEnter activation gate; safe to register globally).
- `get_completions(ctx, callback)` → reads the buffer + cursor, converts nvim→pi via
  coords, issues `getSuggestions` over the bridge (two-layer supersession via `ctx.id`
  + `bridge.cancel`), maps pi items → `lsp.CompletionItem`s (label/kind/detail/textEdit/data),
  and calls blink's `callback` exactly once. Error/nothing → `callback()` (nil).
- `execute(ctx, item, callback, default_implementation)` → reads the pre-accept
  snapshot from `item.data`, issues `applyCompletion` over the bridge, calls
  `callback()` immediately (responsive; never hangs blink), and in the async cb
  overwrites the WHOLE buffer + sets the cursor from pi's authoritative result.
- Never `require("blink.cmp")` at runtime (it is the user's plugin; we reference its
  types only via emmy `---@module 'blink.cmp'` comments).

### Success Criteria

- [ ] `require("pi-editor.blink_source")` succeeds with blink.cmp NOT installed
      (`package.loaded["blink.cmp"]` stays nil; no runtime `require("blink.cmp")`).
- [ ] `new()` returns a source object with `get_trigger_characters` / `enabled` /
      `get_completions` / `execute` all functions.
- [ ] `get_trigger_characters()` contains `"/"` and `"@"`.
- [ ] `enabled()` is true in a `pi-prompt` buffer, false otherwise.
- [ ] `get_completions` issues `getSuggestions` with the EXACT params completion.lua
      uses (`{lines, cursorLine, cursorCol, force=false}`, nvim→pi via coords).
- [ ] `get_completions` maps pi items to blink items with `label/kind/detail/textEdit/data`
      and calls `callback` exactly once with `{is_incomplete_forward=false, is_incomplete_backward=false, items}`.
- [ ] `get_completions` supersession: a newer `ctx.id` wins; an error/cancel/timeout
      resolves `callback()` (nil) — no throw, no stale items.
- [ ] `execute` issues `applyCompletion` with `{lines, cursorLine, cursorCol, item, prefix}`,
      calls `callback()` immediately, and the async cb replaces the whole buffer + sets
      the cursor (0-based byte col, NO `-1`) — byte-identical to completion.lua's accept.
- [ ] `execute` never throws and never fails to call `callback()` (malformed `item.data`,
      nil bridge, wiped buf → `callback()` + degrade).
- [ ] Plenary spec passes; plenary-free smoke passes (fake luv socket + real bridge
      handshake + real module, driven directly — no real blink.cmp).

## All Needed Context

### Context Completeness Check

An implementer who knows nothing about this repo gets, from this PRP: the EXACT
blink.cmp source contract (methods, item shape, `ctx` fields), the EXACT integration
seams (which in-tree modules to call and with what params), the load-bearing accept
design decision (why `execute` overwrites wholesale via `applyCompletion`), the
two-layer supersession pattern, the "never require blink.cmp" rule, the test
strategy, and the AGENTS.md hard rule on nvim invocation. All referenced files are
in-tree and COMPLETE.

### Documentation & References

```yaml
# MUST READ — the blink.cmp source contract (authoritative, master branch)
- url: https://github.com/Saghen/blink.cmp/blob/master/lua/blink/cmp/sources/lib/init.lua
  why: the Sources wrapper — confirms execute(ctx, item, default_implementation) is the accept hook,
        get_trigger_characters/get_completions/resolve/execute/should_show_items/enabled are the
        source methods, items are lsp.CompletionItem, and sources.execute runs AFTER the item's
        textEdit is applied by the accept pipeline.
  critical: "execute — After textEdit" (the load-bearing ordering for §Implementation Blueprint → accept).

- url: https://github.com/Saghen/blink.cmp/blob/master/lua/blink/cmp/sources/path/init.lua
  why: the canonical SIMPLE source — shows new(opts)=setmetatable, :get_trigger_characters,
        :get_completions(context, callback) building {is_incomplete_forward,is_incomplete_backward,items},
        callback() (nil) on nothing, vim.schedule_wrap(callback) ONLY when needed.
  pattern: method-style source; ctx.bounds.{line_number,start_col,length}; ctx.bufnr; ctx.line.
  gotcha: path wraps callback in schedule_wrap because ITS completion runs in a luv cb — OURS runs
          in the bridge's already-schedule_wrap'd cb, so we do NOT wrap (mirrors completion.lua).

- url: https://github.com/Saghen/blink.cmp/blob/master/lua/blink/cmp/types.lua
  why: blink.cmp.CompletionItem : lsp.CompletionItem — the item fields we set (label/kind/detail/
        documentation/textEdit/insertText/filterText/sortText/data). blink ADDS source_id/source_name/
        cursor_column/score itself — do NOT set those.
  critical: `data` is the ONLY field that round-trips our pi item + pre-accept snapshot into execute().

- url: https://github.com/olimorris/codecompanion.nvim/blob/master/lua/codecompanion/providers/completion/blink/init.lua
  why: the closest real-world analog — a chat-buffer slash-command completion source. MIRROR its:
        M.new()=setmetatable; M:enabled() filetype gate; M:get_trigger_characters(); M:get_completions
        building edit_range from ctx.bounds + mapping to {kind,label,textEdit,documentation,data};
        M:execute(ctx,item,callback,default_implementation) running custom logic then callback().
  critical: codecompanion's execute CLEARS the keyword then runs its own logic — WE DO NOT CLEAR
        (we overwrite the WHOLE buffer with applyCompletion's result, so clearing is redundant).
        Always reach a callback() exactly once or blink's accept hangs.

# MUST READ — this repo's seams (all COMPLETE + in-tree)
- file: plugin/lua/pi-editor/bridge.lua
  why: the bridge client. source uses: bridge.request(method, params, cb)->id|nil (cb(err,result),
        schedule_wrap'd → api-safe), bridge.is_connected(), bridge.cancel(id) (supersession),
        bridge.server_info.{cwd,fdAvailable}. Set on require("pi-editor").bridge ONLY after hello.
  pattern: "read bridge FRESH at call time" (handshake resolves async + tests swap fakes after require).
  gotcha: bridge.request cb NEVER includes the token in error strings (PRD §12); result:null → cb(nil,nil).

- file: plugin/lua/pi-editor/completion.lua
  why: the DO_REFRESH (getSuggestions) + ACCEPT (applyCompletion) reference. COPY its exact RPC param
        shapes + the two-layer supersession (cancel + gen-guard) + the "bridge read fresh" rule +
        the async-cb whole-buffer-replace + nvim_win_set_cursor with 0-based byte col (NO -1).
  pattern: getSuggestions params = vim.tbl_extend("keep", coords.nvim_to_pi_coords(...), {force=false});
        applyCompletion params = {lines, cursorLine, cursorCol, item, prefix}; result = {lines,cursorLine,cursorCol}.
  gotcha: error/cancel/timeout → touch nothing (no menu clear, no stale items).

- file: plugin/lua/pi-editor/coords.lua
  why: THE centralized byte↔UTF-16 + nvim↔pi seam (PRD §8 "MUST be centralized"). source uses
        nvim_to_pi_coords(lines, row, byte_col)->{lines,cursorLine,cursorCol} for getSuggestions,
        pi_to_nvim_coords(lines, cl, cc)->{lines,row,col} for the applyCompletion cb. NEVER call
        vim.str_utfindex/str_byteindex directly.
  gotcha: pi_to_nvim_coords returns a 0-based BYTE col ready for nvim_win_set_cursor UNCHANGED — NO -1
        (supersedes PRD §7.4's `bytecol - 1`, which would nudge the cursor one byte left on multibyte).

- file: plugin/lua/pi-editor/init.lua
  why: config + the bridge handle. require("pi-editor").config (rpc_timeout_ms, engine, debounce_ms);
        require("pi-editor").bridge (nil until handshake). setup() applies defaults if never called.
  gotcha: do NOT require("blink.cmp") — it is the user's optional plugin, not a project dependency.

- file: plugin/tests/completion_spec.lua
  why: the test PATTERN to mirror — a fake_bridge(opts) helper with controllable request/cancel/
        is_connected + resolve(i,err,result); the "one spec per module" rule; reset() before/after_each.

- file: plugin/tests/completion_accept_smoke.lua
  why: the plenary-free smoke PATTERN — fake luv unix-socket server + REAL bridge.handshake + REAL
        module + vim.wait; the file-based +qa invocation (AGENTS.md hard rule).

- docfile: AGENTS.md
  why: the ⛔ HARD RULE — NEVER pipe a heredoc into nvim stdin (it hangs). Write test Lua to a FILE,
        run `+"luafile tests/<file>.lua" +qa`; wrap every nvim call in `timeout`.
  section: "⛔ HARD RULE" + "test runner" (plenary spec + smoke commands).

- docfile: plan/001_c56962b4fa17/architecture/external_deps.md
  why: nvim API semantics (nvim_win_get_cursor[2] is 0-based byte; nvim_buf_set_lines does NOT fire
        TextChangedI; nvim_win_set_cursor is insert-safe). §1.2 cursor col contract.
```

### Current Codebase tree (relevant subset)

```bash
plugin/
  lua/pi-editor/
    init.lua           # setup() + activate(); holds .config + .bridge + .descriptor
    bridge.lua         # COMPLETE: socket client, handshake, request/cancel, on_notification/on_disconnect
    jsonlreader.lua    # COMPLETE: JSONL framing (not used directly by the source)
    coords.lua         # COMPLETE: byte↔utf16 + nvim↔pi (THE centralized seam)
    completion.lua     # COMPLETE: builtin-menu trigger/accept/Tab (the reference for RPC shapes)
    menu.lua           # COMPLETE: builtin floating popup (NOT used by the blink source)
    notify.lua  health.lua
  plugin/pi-editor.lua           # VimEnter shim (activation gate)
  ftplugin/pi-prompt.lua         # buffer-local autocmds → completion.lua (builtin engine)
  tests/
    minimal_init.lua  completion_spec.lua  completion_accept_smoke.lua  ... (one spec/smoke per module)
extension/  # the pi-side bridge (TypeScript) — COMPLETE, out of scope for S45
```

### Desired Codebase tree with files to be added

```bash
plugin/lua/pi-editor/blink_source.lua      # NEW — the blink.cmp source module (S45)
plugin/tests/blink_source_spec.lua         # NEW — plenary spec (fake bridge; mirrors completion_spec)
plugin/tests/blink_source_smoke.lua        # NEW — plenary-free smoke (fake luv server + real module)
# (S46 will add cmp_source.lua; S47 the NVIM_APPNAME doc — both OUT OF SCOPE for S45)
```

### Known Gotchas of our codebase & Library Quirks

```lua
-- CRITICAL: blink.cmp is the USER's plugin, NOT a project dependency.
-- NEVER `require("blink.cmp")` at runtime — it errors when blink isn't installed
-- (the common case for builtin-menu / nvim-cmp users) and breaks dormant-by-default.
-- Reference blink types ONLY via emmy `---@module 'blink.cmp'` COMMENTS (codecompanion line 1).

-- CRITICAL: blink applies the item's textEdit BEFORE calling execute. So by the time
-- execute(ctx,item,callback,default_impl) runs, the buffer already has blink's edit.
-- WE overwrite the WHOLE buffer with applyCompletion's result in the async cb — the
-- blink textEdit is a transient that gets clobbered. Do NOT also "clear the keyword"
-- (codecompanion clears because it does NOT full-buffer-replace; we DO → redundant).

-- CRITICAL: call blink's `callback` EXACTLY ONCE per get_completions / execute, or
-- blink's accept hangs. On get_completions error/timeout/cancel → callback() (nil).
-- On execute, call callback() right after issuing applyCompletion (responsive; never
-- hangs even if the RPC times out). The async cb does the buffer mutation.

-- CRITICAL: bridge.request cb is schedule_wrap'd → api-safe (main loop). Do NOT add
-- vim.schedule_wrap around blink's callback (a needless hop — mirrors completion.lua).
-- (Contrast path source, which DOES wrap because ITS completion runs in a luv cb.)

-- GOTCHA: nvim_win_set_cursor col is 0-based BYTE (coords.pi_to_nvim_coords returns
-- exactly that). NO `-1` (PRD §7.4's bytecol-1 is superseded — see coords.lua header).

-- GOTCHA: bridge is read FRESH at call time (require("pi-editor").bridge INSIDE the
-- fn), NOT a module-load local. The handshake resolves async after VimEnter; tests
-- swap a fake bridge in after require; /reload re-runs activate. Same for coords.

-- GOTCHA: supersession is TWO layers. Layer 1 = bridge.cancel(prev_id) (optimization).
-- Layer 2 = capture ctx.id in the cb closure; ignore the cb if ctx.id changed (cancel
-- can RACE; the id-guard CANNOT). Mirror completion.lua do_refresh (its `gen` guard).

-- GOTCHA: blink items ADD source_id/source_name/cursor_column/score themselves. We set
-- only lsp fields + label + kind + detail + textEdit + data. `data` round-trips our
-- {pi=pi_item, prefix=prefix, lines, cursorLine, cursorCol} snapshot into execute.

-- GOTCHA: lsp.CompletionItemKind values: 17=File, 19=Folder, 14=Keyword, 3=Function,
-- 1=Text. Map pi items: slash/template/skill → Keyword (or Function); @file → File;
-- directory → Folder; else → Text. Defensive: if pi item lacks a kind hint, use Text.

-- GOTCHA: the textEdit.range must be a VALID lsp.Range (0-based line + 0-based UTF-16
-- character). Derive it from the cursor + pi's prefix via coords (end=cursor utf16;
-- start=cursor utf16 - utf16_len(prefix)). The textEdit is the graceful-fallback
-- insertion (newText=pi.value); applyCompletion (in execute) is authoritative.
```

## Implementation Blueprint

### Data models / structure

The source is a singleton object (one per blink provider entry). State is minimal:

```lua
--- @class pi-editor.BlinkSourceState
--- @field current_id any        the latest ctx.id seen in get_completions (supersession guard)
--- @field inflight_id string?   the bridge.request id of the in-flight getSuggestions (for bridge.cancel)
local state = { current_id = nil, inflight_id = nil }
```

(The blink source owns NO buffer, NO socket, NO menu. All of that is the bridge's /
builtin engine's job. The source is a pure RPC→item-mapping adapter.)

The pre-accept snapshot carried on each blink item:

```lua
--- @class pi-editor.BlinkItemData
--- @field pi        pi-editor.AutocompleteItem  forwarded VERBATIM as applyCompletion's `item`
--- @field prefix    string                       the getSuggestions result.prefix (applyCompletion's `prefix`)
--- @field lines     string[]                     the buffer lines at getSuggestions issue time (applyCompletion's `lines`)
--- @field cursorLine integer                     0-indexed pi line (applyCompletion's `cursorLine`)
--- @field cursorCol  integer                     0-indexed UTF-16 pi col (applyCompletion's `cursorCol`)
```

### Implementation Tasks (ordered by dependencies)

```yaml
Task 1: CREATE plugin/lua/pi-editor/blink_source.lua — module skeleton + new + get_trigger_characters + enabled
  - IMPLEMENT: `local M = {}`; `M.new(opts)` = `setmetatable({}, { __index = M })`; the module-level
    `state = {current_id=nil, inflight_id=nil}`; `function M:get_trigger_characters()` returns
    `{ "/", "@" }` (optionally add `"#"` to mirror completion.lua's is_attachment_context).
  - IMPLEMENT: `function M:enabled()` returns `vim.bo.filetype == "pi-prompt"` (source-level dormancy).
  - FOLLOW pattern: codecompanion `providers/completion/blink/init.lua` (M.new / M:enabled / M:get_trigger_characters).
  - NAMING: colon-method style (`function M:foo(self,...)`); module returns `M`.
  - PLACEMENT: plugin/lua/pi-editor/blink_source.lua (alongside completion.lua / coords.lua).
  - GOTCHA: NO `require("blink.cmp")` at runtime. Type-hint only via `--- @module 'blink.cmp'` comment.

Task 2: IMPLEMENT M:get_completions(ctx, callback) — the data faucet
  - READ the bridge FRESH: `local bridge = require("pi-editor").bridge`. If nil / no is_connected /
    not a function → `callback()` (nil = "nothing from me"); return. (Graceful; matches path source's
    callback() on nothing.)
  - READ buffer + cursor (api-safe — the bridge cb path is scheduled; but get_completions itself runs
    on the main loop, so direct nvim calls are fine): `local lines = vim.api.nvim_buf_get_lines(ctx.bufnr, 0, -1, false)`;
    `local cur = vim.api.nvim_win_get_cursor(0)` → `{row 1-based, col 0-based byte}`. Guard buf valid.
  - CONVERT nvim→pi: `local pi = require("pi-editor.coords").nvim_to_pi_coords(lines, cur[1], cur[2])`.
  - SUPERSEDE layer 1: `if state.inflight_id and bridge.cancel then pcall(bridge.cancel, state.inflight_id) end`;
    `state.inflight_id = nil`.
  - SUPERSEDE layer 2: capture `local my_id = ctx.id; state.current_id = ctx.id` (or a monotonic local).
  - ISSUE: `local params = vim.tbl_extend("keep", pi, { force = false })` (EXACT shape completion.lua uses);
    `local ok, rid = pcall(bridge.request, "getSuggestions", params, function(err, result) ... end)`.
  - IN THE CB (schedule_wrap'd by bridge → api-safe):
      * `if my_id ~= state.current_id then return end` (STALE — drop, touch nothing; blink already moved on).
      * `state.inflight_id = nil`.
      * `if err then callback() return end` (timeout/cancel/rpc error → "nothing"; no throw, no stale items).
      * NORMALIZE null: `local items = (result and type(result.items)=="table") and result.items or {}`;
        `local prefix = (result and type(result.prefix)=="string") and result.prefix or ""`.
      * MAP: build `blink_items` via a `map_item(pi_item)` helper (Task 3) using `ctx.bounds`/cursor + coords
        for the textEdit.range + the snapshot fields. Skip non-table pi items defensively.
      * `callback({ is_incomplete_forward = false, is_incomplete_backward = false, items = blink_items })`.
  - TRACK inflight: `if ok and type(rid)=="string" then state.inflight_id = rid end`.
  - FOLLOW pattern: plugin/lua/pi-editor/completion.lua do_refresh (RPC shapes, two-layer supersession,
    "bridge read fresh", null→empty, error→touch-nothing). Adapted: completion.lua fires a menu seam; we
    call blink's `callback`. completion.lua's gen-int → our ctx.id.
  - NAMING: `map_item` local helper (Task 3); `guess_kind` local helper (Task 3).
  - GOTCHA: do NOT wrap blink's `callback` in vim.schedule_wrap (the bridge cb already runs on the main loop).

Task 3: IMPLEMENT map_item(pi_item, ctx, cursor, prefix, pi_coords) + guess_kind(pi_item) — the item mapper
  - guess_kind: `/...` slash/template/skill (value starts with "/") → `vim.lsp.protocol.CompletionItemKind.Keyword`;
    `@...` file (description/value looks like a file path) → File (17); directory → Folder (19); else → Text (1).
    Keep defensive + simple (pi items don't carry a kind; this is cosmetic for the icon/sort).
  - BUILD the textEdit.range (lsp.Range, 0-based line + 0-based UTF-16 character) covering pi's `prefix`:
      * line = pi_coords.cursorLine (0-based = ctx.bounds.line_number - 1).
      * end_char = pi_coords.cursorCol (already UTF-16).
      * start_char = pi_coords.cursorCol - utf16_len_of(prefix). Compute utf16_len via coords: the prefix
        is a prefix of `pi_coords.lines[cursorLine+1]`; its UTF-16 length =
        `coords.byte_to_utf16(line, byte_len_of_prefix)` where byte_len_of_prefix = `#prefix`. (Defensive:
        clamp start_char >= 0.) ALTERNATIVE SIMPLER: use `ctx.bounds`-derived range (blink's word bounds) —
        acceptable since applyCompletion overwrites everything; prefer the coords-derived range for prefix fidelity.
  - RETURN the blink item:
      `{ label = pi_item.label, kind = guess_kind(pi_item), detail = pi_item.description,
         textEdit = { newText = pi_item.value, range = { start={line=line, character=start_char}, ["end"]={line=line, character=end_char} } },
         data = { pi = pi_item, prefix = prefix, lines = pi_coords.lines, cursorLine = pi_coords.cursorLine, cursorCol = pi_coords.cursorCol } }`
  - GOTCHA: `pi_item` forwarded VERBATIM (the bridge server forwards it verbatim to pi; pi keys on the
    whole table — completion.lua accept does the same).
  - GOTCHA: blink items with NO documentation field are fine (resolve is optional + out of scope for S45).

Task 4: IMPLEMENT M:execute(ctx, item, callback, default_implementation) — accept via applyCompletion
  - DEFENSIVE: `local d = item and item.data; if type(d) ~= "table" or type(d.pi) ~= "table" then callback() return end`
    (malformed → tell blink "done"; never hang; never throw).
  - READ bridge FRESH: `local bridge = require("pi-editor").bridge`. If nil / not connected →
    `callback()` return (graceful: blink's textEdit already applied a basic insertion pre-execute; we leave it).
  - ISSUE applyCompletion with the snapshot: `local params = { lines = d.lines, cursorLine = d.cursorLine,
    cursorCol = d.cursorCol, item = d.pi, prefix = d.prefix }` (EXACT shape completion.lua accept uses);
    `pcall(bridge.request, "applyCompletion", params, function(err, result) ... end)`.
  - CALL `callback()` IMMEDIATELY after issuing (responsive; blink considers accept done; the buffer mutation
    is async fire-and-forget in the cb — mirrors completion.lua on_enter returning true once issued). DO NOT
    wait for the RPC (a timeout would hang blink's accept otherwise).
  - IN THE CB (api-safe): on success + table result →
      `local nv = require("pi-editor.coords").pi_to_nvim_coords(result.lines, result.cursorLine, result.cursorCol)`;
      `pcall(vim.api.nvim_buf_set_lines, ctx.bufnr, 0, -1, false, nv.lines)` (WHOLE buffer replace);
      `pcall(vim.api.nvim_win_set_cursor, 0, { nv.row, nv.col })` (0-based byte col, NO -1);
      also best-effort close the BUILTIN menu if open: `pcall(function() require("pi-editor.menu").close() end)`
      (avoid a stale builtin popup lingering when the user accepted via blink — defensive, never throws).
    On error / non-table result → leave the buffer as blink's textEdit left it (graceful degrade); never throw.
  - FOLLOW pattern: plugin/lua/pi-editor/completion.lua accept() (the 5-step applyCompletion flow: read
    lines+cursor [here from the snapshot, not live], convert, request, async cb: convert + set_lines +
    set_cursor + close). ONE-SHOT user action → NO gen-guard (capture nothing; the accept is authoritative).
  - GOTCHA: do NOT call default_implementation (we do NOT want blink's snippet/extra logic; we overwrite).
  - GOTCHA: nvim_buf_set_lines is an API mutation → does NOT fire TextChangedI → no refresh loop (completion.lua §5 Q2).

Task 5: CREATE plugin/tests/blink_source_spec.lua — plenary spec (fake bridge)
  - REUSE/ADAPT `fake_bridge(opts)` from plugin/tests/completion_spec.lua: a table with `request` (records
    calls + resolves via a stored cb the test drives), `cancel`, `is_connected` (default true), `server_info`.
    Set `require("pi-editor").bridge = fake` before each test; nil it after.
  - CASES (see Success Criteria — 10 cases): new() shape; get_trigger_characters; enabled (pi-prompt vs other);
    get_completions happy path (assert getSuggestions params + item mapping + callback shape); supersession
    (older cb dropped / callback() nil; newer wins); error → callback() nil; bridge nil/disconnected → callback();
    execute happy (applyCompletion params + callback() immediate + cb set_lines/set_cursor; MULTIBYTE cursor);
    execute error → buffer untouched; execute malformed data → callback() + no throw; assert package.loaded["blink.cmp"]==nil.
  - FOLLOW pattern: plugin/tests/completion_spec.lua (one describe block per behavior group; reset state before/after_each
    via a tiny `require("pi-editor.blink_source")._reset_for_test()` helper OR re-require; the repo's "never-throws" testing style).
  - BUILD a helper `make_ctx(bufnr, line, row, col, id)` constructing the blink ctx subset the source reads
    (bufnr, line, bounds={line_number,start_col,length}, cursor, trigger={character}, id).
  - NAMING: `test_bl source_<behavior>`; COVERAGE: all public methods + error + supersession + never-throws.

Task 6: CREATE plugin/tests/blink_source_smoke.lua — plenary-free smoke (fake luv server + real module)
  - MIRROR plugin/tests/completion_accept_smoke.lua's bootstrap: fake luv unix-socket server + REAL
    `bridge.handshake` + REAL `blink_source` + REAL `coords`. NO real blink.cmp (drive the module directly).
  - FLOW: set buffer `{"@sr"}`, filetype `pi-prompt`, cursor EOL; `src:get_completions(make_ctx(...), cb)` →
    server sees `getSuggestions` → reply `{items={{value="@/src/comp.ts", label="comp.ts", description="src/comp.ts"}},
    prefix="@sr"}` → vim.wait → assert resp.items[1].textEdit.newText=="@/src/comp.ts" + .data.pi.value + .data.prefix;
    then `src:execute(make_ctx(...), resp.items[1], function() end, function() end)` → server sees `applyCompletion`
    with `{item=<pi>, prefix="@sr", lines={"@sr"}, cursorLine=0, cursorCol=4}` → reply `{lines={"@/src/comp.ts "},
    cursorLine=0, cursorCol=15}` → vim.wait → assert buffer=={"@/src/comp.ts "} + cursor {1,15}.
  - TEARDOWN: bridge.close() + server stop. Print `SMOKE_PASS` / `vim.cmd('qa')` exit 0.
  - FOLLOW pattern: plugin/tests/completion_accept_smoke.lua (fake server; vim.wait; print PASS marker).
  - ⛔ AGENTS.md HARD RULE: write this Lua to the FILE (done — it IS the file), run via
    `timeout 60 nvim --headless --clean -u tests/minimal_init.lua +"luafile tests/blink_source_smoke.lua" +qa`.
    NEVER pipe a heredoc into nvim stdin.
```

### Implementation Patterns & Key Details

```lua
-- PATTERN: the source object (codecompanion-style). One file, method-style, returns M.
local M = {}
function M.new(opts)            -- opts = blink provider config; accept + ignore (read pi config live)
  return setmetatable({}, { __index = M })
end
function M:get_trigger_characters() return { "/", "@" } end
function M:enabled() return vim.bo.filetype == "pi-prompt" end

-- PATTERN: get_completions — read bridge fresh, convert, supersede (two-layer), issue, map, callback once.
function M:get_completions(ctx, callback)
  local bridge = require("pi-editor").bridge          -- FRESH (handshake async + test fakes)
  if not bridge or type(bridge.is_connected) ~= "function" or not bridge.is_connected() then
    return callback()                                  -- nothing (graceful; matches path source)
  end
  local lines = vim.api.nvim_buf_get_lines(ctx.bufnr, 0, -1, false)
  local cur   = vim.api.nvim_win_get_cursor(0)         -- {row 1-based, col 0-based byte}
  local pi    = require("pi-editor.coords").nvim_to_pi_coords(lines, cur[1], cur[2])
  -- supersede layer 1 (cancel prev in-flight)
  if state.inflight_id and type(bridge.cancel) == "function" then pcall(bridge.cancel, state.inflight_id) end
  state.inflight_id = nil
  -- supersede layer 2 (ctx.id guard)
  local my_id = ctx.id; state.current_id = ctx.id
  local params = vim.tbl_extend("keep", pi, { force = false })
  local ok, rid = pcall(bridge.request, "getSuggestions", params, function(err, result)
    if my_id ~= state.current_id then return end       -- STALE — drop, touch nothing
    state.inflight_id = nil
    if err then return callback() end                  -- timeout/cancel/rpc error → nothing
    local items  = (result and type(result.items)  == "table")  and result.items  or {}
    local prefix = (result and type(result.prefix) == "string") and result.prefix or ""
    callback({ is_incomplete_forward = false, is_incomplete_backward = false,
               items = vim.tbl_map(function(it) return map_item(it, pi, prefix) end,
                                   vim.tbl_filter(function(it) return type(it) == "table" end, items)) })
  end)
  if ok and type(rid) == "string" then state.inflight_id = rid end
end

-- PATTERN: execute — snapshot on item.data, issue applyCompletion, callback() immediately, async cb overwrites.
function M:execute(ctx, item, callback, default_implementation)
  local d = item and item.data
  if type(d) ~= "table" or type(d.pi) ~= "table" then return callback() end   -- never hang blink
  local bridge = require("pi-editor").bridge
  if not bridge or type(bridge.is_connected) ~= "function" or not bridge.is_connected() then
    return callback()                                  -- graceful: blink's textEdit already applied pre-execute
  end
  local params = { lines = d.lines, cursorLine = d.cursorLine, cursorCol = d.cursorCol,
                   item = d.pi, prefix = d.prefix }     -- EXACT applyCompletion shape (completion.lua accept)
  pcall(bridge.request, "applyCompletion", params, function(err, result)
    if err or type(result) ~= "table" then return end   -- degrade: buffer left as blink's textEdit
    local nv = require("pi-editor.coords").pi_to_nvim_coords(result.lines, result.cursorLine, result.cursorCol)
    pcall(vim.api.nvim_buf_set_lines, ctx.bufnr, 0, -1, false, nv.lines)   -- WHOLE buffer replace
    pcall(vim.api.nvim_win_set_cursor, 0, { nv.row, nv.col })              -- 0-based byte col, NO -1
    pcall(function() require("pi-editor.menu").close() end)                -- close stale builtin menu if open
  end)
  callback()                                           -- IMMEDIATE: never hang blink (RPC is fire-and-forget)
end
return M
```

### Integration Points

```yaml
CONFIG:
  - add to: the USER's blink.cmp config (NOT this repo's setup()).
    pattern: |
      { "Saghen/blink.cmp", opts = { sources = { default = { "pi" },
        providers = { pi = { name = "pi", module = "pi-editor.blink_source" } } } } }
  - this repo's setup() config.engine ("builtin"|"blink"|"cmp"): the source module READS it
    only to degrade (no behavioral change in S45). See "Known forward-contract" below.

ROUTES / RPC:
  - getSuggestions: {lines, cursorLine, cursorCol, force=false} → {items, prefix} | null. (completion.lua do_refresh shape)
  - applyCompletion: {lines, cursorLine, cursorCol, item, prefix} → {lines, cursorLine, cursorCol}. (completion.lua accept shape)
  - Both via require("pi-editor").bridge.request(method, params, cb) → cb(err, result). NO new sockets.

NO DB / NO MIGRATIONS / NO NEW FILES OUTSIDE the three listed in "Desired Codebase tree".
```

## Validation Loop

### Level 1: Syntax & Style (Immediate Feedback)

```bash
# Lua syntax check (luac) on the new module — run after creating it.
luac -p plugin/lua/pi-editor/blink_source.lua && echo "luac OK"
# If selene is configured in the repo (see plugin/ root), lint the new + test files:
selene plugin/lua/pi-editor/blink_source.lua plugin/tests/blink_source_spec.lua plugin/tests/blink_source_smoke.lua
# stylua format check (if plugin/stylua.toml exists):
stylua --check plugin/lua/pi-editor/blink_source.lua plugin/tests/blink_source_spec.lua plugin/tests/blink_source_smoke.lua
# Expected: zero errors. READ any output + fix before proceeding.
```

### Level 2: Unit Tests (Component Validation — plenary spec)

```bash
# The plenary spec (fake bridge; mirrors completion_spec.lua). Run from plugin/.
timeout 90 nvim --headless --clean -u tests/minimal_init.lua \
  -c 'lua require("plenary.busted").run("tests/blink_source_spec.lua")'
echo "exit=$?"
# Expected: all assertions pass (0 failures). On failure, READ the plenary output + fix the module.
```

### Level 3: Integration Testing (plenary-free smoke — fake luv socket + real module)

```bash
# The plenary-free smoke. Writes nothing to nvim stdin (AGENTS.md HARD RULE) — it IS the file.
timeout 60 nvim --headless --clean -u tests/minimal_init.lua \
  +"luafile tests/blink_source_smoke.lua" +qa
echo "exit=$?"
# Expected: prints `SMOKE_PASS` and exits 0. If it prints nothing / hangs / exits non-zero:
#   the smoke has a bug or the module regressed. Do NOT pipe a heredoc to fix it — edit the FILE.
```

### Level 4: Domain-Specific Validation (blink.cmp registration — MANUAL, optional)

```bash
# Manual / scripted: with the pi-editor-bridge extension installed + a real pi editor open,
# add the source to a blink.cmp config in a scratch nvim, type `/mo` in the pi prompt buffer,
# and confirm blink shows `/model` (etc.). Accepting inserts `/model ` (trailing space) —
# proving execute→applyCompletion is byte-identical to the TUI. This requires a real blink.cmp
# install (not in CI). Document the steps in the module docstring; do NOT block S45 on it.
# (Automated coverage of the same surface = the Level 3 smoke, which drives execute directly.)
```

## Final Validation Checklist

### Technical Validation

- [ ] Level 1 (luac/selene/stylua) clean on the 3 new files.
- [ ] Level 2 plenary spec passes (all 10 cases): `timeout 90 nvim … blink_source_spec.lua`.
- [ ] Level 3 plenary-free smoke prints `SMOKE_PASS` / exit 0: `timeout 60 nvim … +"luafile tests/blink_source_smoke.lua" +qa`.
- [ ] No nvim invocation pipes a heredoc into stdin (AGENTS.md ⛔ HARD RULE); all wrapped in `timeout`.

### Feature Validation

- [ ] `require("pi-editor.blink_source")` loads with blink.cmp NOT installed (`package.loaded["blink.cmp"]==nil`).
- [ ] `new()` object has `get_trigger_characters`/`enabled`/`get_completions`/`execute` as functions.
- [ ] `get_trigger_characters()` contains `"/"` + `"@"`; `enabled()` gates on `pi-prompt` filetype.
- [ ] `get_completions` issues `getSuggestions` with `{lines, cursorLine, cursorCol, force=false}` (coords-converted).
- [ ] `get_completions` maps items to `{label,kind,detail,textEdit,data}` + calls `callback` ONCE; supersession via `ctx.id`.
- [ ] `execute` issues `applyCompletion` with `{lines, cursorLine, cursorCol, item, prefix}` (snapshot) + calls `callback()` immediately; async cb replaces whole buffer + sets cursor (0-based byte, NO -1).
- [ ] Error/cancel/timeout → graceful (`callback()` nil on get_completions; buffer-untouched on execute); never throws; never hangs blink.

### Code Quality Validation

- [ ] Follows the repo's [Mode A] dense-docstring convention (every non-obvious decision documented; cross-refs to completion.lua / coords.lua / bridge.lua / AGENTS.md).
- [ ] Reads bridge + coords FRESH at call time (not module-load locals).
- [ ] Two-layer supersession (bridge.cancel + ctx.id guard) — mirrors completion.lua.
- [ ] No `require("blink.cmp")` at runtime (user's plugin); emmy type-hints only.
- [ ] Only the 3 new files added; NO modification of init.lua / completion.lua / bridge.lua / coords.lua / menu.lua / ftplugin / extension.

### Documentation & Coordination

- [ ] Module docstring documents the accept design (snapshot + execute overwrites wholesale) + the "never require blink.cmp" rule + the blink registration snippet.
- [ ] Known forward-contract documented: when `config.engine == "blink"`, the builtin menu autocmds should be suppressed by a FUTURE engine-wiring task (NOT S45) to avoid double-UI. S45's module is correct standalone + additive.

---

## Anti-Patterns to Avoid

- ❌ Do NOT `require("blink.cmp")` at runtime (user's optional plugin; breaks dormant-by-default).
- ❌ Do NOT reimplement insertion in the textEdit (trailing space, quotes, cursor) — `execute`→`applyCompletion` is authoritative; the textEdit is only the graceful fallback.
- ❌ Do NOT call `default_implementation()` in execute (we overwrite wholesale, not compose with blink's snippet logic).
- ❌ Do NOT "clear the keyword" in execute (codecompanion does, because it doesn't full-buffer-replace; we DO → redundant).
- ❌ Do NOT skip the ctx.id supersession guard (cancel alone can race; the id-guard is the correctness boundary).
- ❌ Do NOT forget to call blink's `callback` exactly once (a missed callback hangs blink's accept).
- ❌ Do NOT call `vim.str_utfindex`/`str_byteindex` directly — route through `coords.lua` (PRD §8 centralization).
- ❌ Do NOT add `bytecol - 1` (PRD §7.4 superseded by coords.lua's exact-UTF-16 design).
- ❌ Do NOT pipe a heredoc into nvim stdin in any validation command (AGENTS.md ⛔ HARD RULE — it hangs the session).
- ❌ Do NOT modify init.lua/completion.lua/bridge.lua/coords.lua/menu.lua/ftplugin/extension (out of scope for S45).

---

## Confidence Score

**8 / 10** for one-pass implementation success.

Rationale: the integration seams (bridge, coords, config) are all COMPLETE + in-tree +
exhaustively documented; the blink.cmp source contract is confirmed against the
authoritative repo + a real-world analog (codecompanion); the RPC shapes are copied
verbatim from the COMPLETE completion.lua; the accept design decision is reasoned
through (snapshot + execute overwrites wholesale) with a graceful fallback. The -2
is for: (a) blink's `ctx`/item shapes are confirmed via source-reading + codecompanion
but not via a live blink.cmp install in CI (the smoke drives the module directly, not
real blink) — a minor integration surface; (b) the textEdit.range UTF-16 derivation is
fiddly (mitigated: applyCompletion overwrites everything, so range precision is
non-critical); (c) the engine-suppression coordination is out of scope but could
surface as a double-UI if the user uses blink without the future wiring (documented).

## Known Forward-Contracts (out of scope for S45; documented for the follow-up)

1. **Engine wiring / double-UI suppression.** When `config.engine == "blink"|"cmp"`, the
   builtin floating menu (ftplugin autocmds → completion.lua → menu.lua) should be
   SUPPRESSED so only the user's engine shows. S45 ships the self-contained source; a
   later task wires the suppression into the ftplugin/init (likely: the ftplugin checks
   `require("pi-editor").config.engine` before arming the builtin autocmds).
2. **`resolve` for hover docs** (optional §15 enhancement): a future task could add
   `M:resolve(item, callback)` that calls the bridge's `getCommands` to enrich an item's
   documentation on hover. Out of scope for S45 (items already carry `description` as `detail`).
3. **nvim-cmp source (S46)** mirrors this module's shape (`source.new`, `get_trigger_characters`,
   `complete`) — S45's `map_item` + the snapshot accept strategy are reusable there.