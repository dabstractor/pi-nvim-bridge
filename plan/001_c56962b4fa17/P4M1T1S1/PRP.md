# PRP — P4.M12.T29.S45: blink_source.lua — source.new, get_trigger_characters, get_completions (+ execute)

**Work item**: P4.M12.T29.S45 (a.k.a. plan id `P4M1T1S1`) — "blink.cmp source module"
**Phase**: P4 (Optional Integrations) → M12 (Completion Engine Sources & Optimization) → T29 → S45
**Scope**: ONE optional, self-contained module `plugin/lua/pi-editor/blink_source.lua` (+ tests).
This is an **opt-in** completion-engine source (PRD §7.7). It reuses the **already-shipped**
bridge (`getSuggestions`) and accept flow (`applyCompletion`) — it adds NO new RPC, NO new
buffer-manipulation, NO change to the builtin engine. Sibling tasks S46 (nvim-cmp source) and
S47 (NVIM_APPNAME) are out of scope.

> **Parallel execution context**: This PRP is researched in parallel with **P3.M10.T24.S39**
> ("Graceful failure — single `vim.notify`"). S39 ships `plugin/lua/pi-editor/notify.lua`
> (`M.once(category, level, msg)`, dedup'd). Our source does NOT notify (silent degrade = empty
> list), so there is no dependency and no conflict. We treat S39's "silent degrade" convention as
> authoritative and emit **no** `vim.notify` ourselves.

---

## Goal

**Feature Goal**: A valid **blink.cmp source** that a user registers in their blink.cmp config to
receive pi-editor completions (slash commands + `@` mentions) rendered and accepted through the
**blink.cmp UI**, while delegating the actual text insertion to pi's server-side `applyCompletion`
(pi-faithful insertion — the same path the builtin engine uses).

**Deliverable**: `plugin/lua/pi-editor/blink_source.lua` exporting a `source` table with `new`,
`enabled`, `get_trigger_characters`, `get_completions`, and `execute`; plus a plenary-free smoke
test (`plugin/tests/blink_source_smoke.lua`) and a plenary spec
(`plugin/tests/blink_source_spec.lua`).

**Success Definition**:
- The module satisfies the `blink.cmp.Source` interface (verified against the locally-cloned
  blink.cmp `sources/lib/types.lua`).
- `source.new(opts, config)` returns an object with all five methods.
- `source:enabled()` is `true` iff `vim.env.PI_NVIM_BRIDGE ~= nil and require("pi-editor").bridge ~= nil`.
- `source:get_trigger_characters()` returns `{ "/", "@" }`.
- `source:get_completions(ctx, callback)` extracts the **full buffer** + cursor from `ctx`, converts
  nvim→pi coords, calls `bridge.request("getSuggestions", {lines, cursorLine, cursorCol})`, maps each
  `AutocompleteItem` → an LSP-shaped `CompletionItem`, calls `callback` **exactly once** with a
  `CompletionResponse`, and returns a cancel function.
- `source:execute(ctx, item, callback, default)` calls pi's accept flow (`applyCompletion`) with the
  original item + its prefix, calls `callback()`, and **does NOT call `default_implementation`**
  (blink's default textEdit path would diverge from pi's insertion rules).
- All validation gates pass (smoke prints `SMOKE_PASS` / exit 0; plenary spec green).

## User Persona

**Target User**: A Neovim user who runs pi as `$EDITOR` AND uses [blink.cmp](https://github.com/Saghen/blink.cmp)
as their completion UI (instead of the plugin's dependency-free builtin popup).

**Use Case**: While editing a pi prompt in Neovim, the user types `/` or `@` (or any prefix) and
blink.cmp shows pi's completion candidates; accepting one inserts it exactly as pi's TUI would.

**User Journey**:
1. pi launches Neovim with `PI_NVIM_BRIDGE` set → the plugin activates + connects the bridge
   (`require("pi-editor").bridge` becomes non-nil).
2. The user's blink.cmp config registers `["pi-editor"] = { module = "pi-editor.blink_source" }`.
3. On typing, blink calls `get_completions` → pi returns candidates → blink renders them.
4. On accept, blink calls `execute` → pi's `applyCompletion` rewrites the buffer (cursor + text
   pi-faithful) → blink's menu closes.

**Pain Points Addressed**: Users who already run blink.cmp don't want a *second* floating popup
(the builtin one) competing with it; they want pi's candidates inside the engine they already use.

## Why

- **PRD §7.7** explicitly calls for opt-in blink.cmp + nvim-cmp sources "so both reuse the same
  bridge + accept-via-`applyCompletion` path."
- Lets users keep their preferred completion UI (blink) while preserving pi's exact insertion
  semantics (pi is authoritative — it returns the whole new buffer).
- The plugin already exposes `require("pi-editor").bridge` (init.lua) precisely so that "these
  (and user code) can issue RPCs" (PRD §7.7). This task is the consumer of that seam.

## What

A single optional Lua module that adapts the `blink.cmp.Source` contract to pi's bridge. No new
RPC methods, no buffer-editing logic of its own (it reuses `completion.accept`), no global state,
no autocmds. Fully side-effect-free at `require` time; all work happens inside the source methods.

### Success Criteria

- [ ] `require("pi-editor.blink_source").new(opts, config)` returns an object implementing
      `enabled`, `get_trigger_characters`, `get_completions`, `execute`.
- [ ] `:enabled()` returns `true` only when the env var AND `pi.bridge` are both set; `false` otherwise.
- [ ] `:get_trigger_characters()` returns `{ "/", "@" }` (deep-equal, order-insensitive acceptable).
- [ ] `:get_completions(ctx, cb)` calls `bridge.request("getSuggestions", …)` with params
      `{ lines = <full buffer>, cursorLine = row-1, cursorCol = <UTF-16 of byte col> }` and **no `force` key**.
- [ ] Each returned item is `{ label = ai.label, detail = ai.description, kind = 1 (Text) }` and
      carries `pi_item` (deepcopy of the original) + `pi_prefix` for `execute`.
- [ ] The blink `callback` is invoked **exactly once** per `get_completions` call, with a
      `CompletionResponse` (empty `{items={},…}` on any degrade path: no bridge / not connected /
      RPC error / null result).
- [ ] `get_completions` returns a cancel function that calls `bridge.cancel(id)` (no-op if already resolved).
- [ ] `:execute(ctx, item, cb, default)` calls `require("pi-editor.completion").accept(item.pi_item, item.pi_prefix)`
      and then `cb()`; it does **not** call `default`.
- [ ] Smoke test passes (`SMOKE_PASS`, exit 0); plenary spec passes.

---

## All Needed Context

### Context Completeness Check

> "If someone knew nothing about this codebase, would they have everything needed to implement
> this successfully?" — **Yes.** The exact blink.cmp source interface, the `Context` shape, the
> `CompletionResponse`/`CompletionItemKind` enums, the reuse path (`completion.accept`), and the
> bridge/coords APIs are all quoted verbatim below with file paths. No guessing required.

### Documentation & References

```yaml
# MUST READ — the blink.cmp source contract (verified in the LOCAL clone)
- file: /home/dustin/.local/share/nvim/lazy/blink.cmp/lua/blink/cmp/sources/lib/types.lua
  why: "The EXACT blink.cmp.Source interface: new(opts, config), enabled?, get_trigger_characters?,
        get_completions?(self, context, callback) -> cancel|nil, execute?(self, context, item,
        callback, default_implementation) -> cancel|nil. ALL of our methods are OPTIONAL on the
        interface (marked '?'), so missing one won't crash blink — but we implement all five."
  critical: "get_completions returns an OPTIONAL cancel fn (we return one). The get_completions
             callback is `fun(response?: CompletionResponse)` — response is nullable for streaming,
             but WE always pass a concrete table exactly once."

- file: /home/dustin/.local/share/nvim/lazy/blink.cmp/lua/blink/cmp/completion/trigger/context.lua
  why: "The blink.cmp.Context shape we consume: context.bufnr (number), context.cursor
        {row(1-indexed), col(0-indexed BYTE)} — SAME convention as nvim_win_get_cursor — and
        context.line (the CURRENT line only)."
  critical: "context.line is ONE line, but bridge.getSuggestions needs the FULL lines[]. You MUST
             call vim.api.nvim_buf_get_lines(context.bufnr, 0, -1, false) yourself. context.cursor
             feeds directly into coords.nvim_to_pi_coords(lines, cursor[1], cursor[2])."

- file: /home/dustin/.local/share/nvim/lazy/blink.cmp/lua/blink/cmp/types.lua
  why: "blink.cmp.CompletionResponse {is_incomplete_forward, is_incomplete_backward, items} and the
        CompletionItemKind enum (Text == 1, File == 17, Folder == 19). blink keeps its OWN copy of
        this enum (some plugins mutate vim.lsp.protocol.CompletionItemKind)."
  critical: "Use kind = 1 (Text) for pi items — they are free-text candidates, not LSP symbols.
             Set BOTH is_incomplete_forward and is_incomplete_backward to false (pi returns a
             complete ranked list for the current prefix; blink filters client-side as you type)."

- file: /home/dustin/.local/share/nvim/lazy/blink.cmp/lua/blink/cmp/completion/accept/init.lua
  why: "PROVES why `execute` is mandatory: blink's DEFAULT accept (apply_item) computes and applies
        an LSP `item.textEdit`. pi items have NO textEdit — pi does prefix replacement server-side
        via applyCompletion and returns the whole new buffer."
  critical: "We MUST override `execute`, call applyCompletion, and NEVER call default_implementation.
             This is the single most important correctness decision in the task."

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
           so menu.get_prefix() is never consulted in the blink path. Safe WITHOUT menu.attach()."

- file: plugin/lua/pi-editor/bridge.lua   # M.request / M.cancel / M.is_connected  (S26)
  why: "The RPC primitive. M.request(method, params, on_result) -> string|nil id; on_result(err,
        result) called EXACTLY ONCE (vim.schedule_wrap'd => api-safe). M.cancel(id) fires the cb
        with 'cancelled' (no wire msg; no-op if resolved). M.is_connected() -> bool."
  critical: "getSuggestions params = {lines:string[], cursorLine:int, cursorCol:int(UTF-16),
             force?:bool}. OMIT force for the normal blink trigger (matches builtin TextChangedI
             path; only the Tab handler sets force=true). null result -> treat as empty."

- file: plugin/lua/pi-editor/coords.lua   # M.nvim_to_pi_coords(lines, row_1_idx, byte_col_0_idx) (S29)
  why: "nvim cursor -> pi cursor. Returns {lines=lines, cursorLine=row-1, cursorCol=UTF-16(line,col)}.
        context.cursor already matches the (row_1_indexed, byte_col_0_indexed) input convention."
  critical: "Do NOT hand-roll UTF-16. Route through coords.nvim_to_pi_coords exactly like
             completion.accept does (centralized seam; multibyte-safe)."

- file: plugin/lua/pi-editor/init.lua   # M.bridge (the published seam; PRD §7.7)
  why: "`require('pi-editor').bridge` is the singleton bridge client (nil until handshake succeeds;
        nil in dormant sessions). The blink source reads it LIVE inside each method (never cache at
        module load — handshake resolves async)."
  gotcha: "Do NOT require('pi-editor.bridge') at module top-level and cache it — read
           require('pi-editor').bridge inside enabled()/get_completions()/execute() so a late
           handshake (or a /reload) is picked up."

# Reference pattern — the gold-standard plenary-FREE smoke (mirror its bootstrap + fake server)
- file: plugin/tests/completion_accept_smoke.lua
  why: "The exact fake-luv-unix-socket-server + REAL-bridge + REAL-completion idiom to mirror for
        blink_source_smoke.lua: spin a server that replies hello->ok, getSuggestions->{items,prefix},
        applyCompletion->{lines,cursorLine,cursorCol}; handshake the real bridge; drive the module;
        assert on the requests the server OBSERVED (lines/cursorLine/cursorCol/item/prefix)."
  critical: "This is the Level-3 gate. It MUST be written to a real file and run with
             +\"luafile tests/blink_source_smoke.lua\" +qa. NEVER pipe a heredoc into nvim stdin
             (AGENTS.md HARD RULE — it hangs the session forever)."

# Reference pattern — a plenary spec that exercises bridge.request (mirror its structure)
- file: plugin/tests/bridge_request_spec.lua
  why: "Plenary/busted layout: describe/it, per-case socket servers, reset_module() cleanup. For the
        blink_source_spec we INSTEAD inject a fake pi.bridge (no socket needed) and spy
        completion.accept — simpler than a server round-trip and precise on the mapping logic."

# Architecture note
- file: plan/001_c56962b4fa17/architecture/external_deps.md
  section: "## 2. blink.cmp Source API"
  why: "The repo's own summary of the source contract + registration snippet. Less precise than the
        type files above (omits the 2nd `new` arg + the `execute` method), so treat the type files
        as authoritative when they disagree."
```

### Current Codebase tree (relevant slice)

```bash
plugin/
├── lua/pi-editor/
│   ├── init.lua          # M.bridge (published seam), M.config, M.descriptor   [SHIPPED — read-only here]
│   ├── bridge.lua        # M.request / M.cancel / M.is_connected / M.handshake [SHIPPED — read-only here]
│   ├── coords.lua        # M.nvim_to_pi_coords / M.pi_to_nvim_coords           [SHIPPED — read-only here]
│   ├── completion.lua    # M.accept(item, prefix_override?) — the REUSE path   [SHIPPED — read-only here]
│   ├── menu.lua          # builtin popup (NOT used by the blink path)           [SHIPPED — read-only here]
│   └── jsonlreader.lua                                                     [SHIPPED — read-only here]
├── ftplugin/pi-prompt.lua                                                  [SHIPPED — read-only here]
├── plugin/pi-editor.lua                                                    [SHIPPED — read-only here]
└── tests/
    ├── minimal_init.lua       # plenary harness bootstrap (PLENARY_PATH)
    ├── completion_accept_smoke.lua   # PATTERN to mirror (fake-server + real-bridge)
    ├── completion_tab_smoke.lua      # PATTERN to mirror (3-flow fake-server)
    └── bridge_request_spec.lua       # PATTERN to mirror (plenary layout)
```

### Desired Codebase tree with files to be ADDED (this task)

```bash
plugin/
├── lua/pi-editor/
│   └── blink_source.lua      # NEW — the optional blink.cmp source (this task's SOLE source file)
└── tests/
    ├── blink_source_smoke.lua # NEW — plenary-FREE Level-3 gate (fake server + real bridge + real completion)
    └── blink_source_spec.lua  # NEW — plenary Level-2 gate (fake bridge + spied completion.accept)
```

**File responsibilities**:
- `blink_source.lua` — exports a `source` table: `new(opts, config)` constructor + `enabled` /
  `get_trigger_characters` / `get_completions` / `execute` methods. Stateless (no module-level
  mutable state; reads the bridge live).
- `blink_source_smoke.lua` — end-to-end: real bridge + real completion + fake server; proves the
  whole getSuggestions→map→execute→applyCompletion→buffer-rewrite loop with a real Neovim buffer.
- `blink_source_spec.lua` — unit-level: injects a fake `pi.bridge`, asserts exact params + mapping
  + dedup-of-callback + execute-delegates-to-accept-and-skips-default.

### Known Gotchas of our codebase & Library Quirks

```lua
-- CRITICAL (blink.cmp): the get_completions callback is `fun(response?: CompletionResponse)`.
-- response is NULLABLE (a source MAY call cb(nil) then cb(real) for streaming). We always pass a
-- concrete table EXACTLY ONCE per call. Never call cb twice for the same get_completions invocation.

-- CRITICAL (blink.cmp): context.line is ONE line only. getSuggestions needs the FULL lines[].
-- ALWAYS: vim.api.nvim_buf_get_lines(context.bufnr, 0, -1, false).

-- CRITICAL (blink.cmp): blink's DEFAULT accept applies item.textEdit (accept/init.lua apply_item).
-- pi items have NO textEdit. => override `execute`, call applyCompletion, NEVER call
-- default_implementation. (Item description contract §1; verified in blink's accept/init.lua.)

-- CRITICAL (blink.cmp): "blink.cmp will mutate items; deepcopy if caching." We build FRESH tables
-- each call, but we stash the ORIGINAL pi item on each mapped item for execute — deepcopy it
-- (vim.deepcopy) so a blink mutation of OUR item can't corrupt the item we send to applyCompletion.

-- CRITICAL (prefix carry): execute only gets the `item` back — NOT the getSuggestions result's
-- `prefix`. STASH both pi_item and pi_prefix on each mapped item. This mirrors the builtin engine
-- (completion.accept passes menu.get_prefix(), which is the FETCH-TIME prefix). The server
-- reconciles lines+cursor+prefix+item, so a fetch-time prefix is correct-by-construction.

-- CRITICAL (nvim stdin HANG): the smoke test MUST be a file run with +"luafile <path>" +qa.
-- NEVER pipe a heredoc / echo into nvim stdin (AGENTS.md HARD RULE — hangs the session forever).

-- GOTCHA (read bridge LIVE): require("pi-editor").bridge is nil until the async handshake resolves
-- and nil again after /reload before reconnect. Read it INSIDE each method, never at module load.

-- GOTCHA (engine coexistence): this source is OPT-IN (PRD §7.7). If the user ALSO has engine="builtin"
-- active (the ftplugin triggers), BOTH the builtin popup and blink would drive completion — a user
-- misconfiguration. We do NOT guard against it in code; document that the user should set
-- engine="blink" (or disable the builtin triggers) in the module docstring. (Wiring engine="blink"
-- to actually disable the builtin triggers is a SEPARATE concern, NOT this task.)

-- GOTCHA (silent degrade): on no-bridge / not-connected / RPC-error / null-result, call the blink
-- callback with the EMPTY response {items={}, is_incomplete_*=false}. NEVER vim.notify (the repo
-- convention per S39; double-toasts are worse than none). NEVER throw out of a source method.
```

---

## Implementation Blueprint

### Data models / structures

No new persistent data models. The only structures are constructed on the fly inside methods:

```lua
-- A blink CompletionResponse we hand to the get_completions callback:
{ items = <blink.CompletionItem[]>, is_incomplete_backward = false, is_incomplete_forward = false }

-- Each mapped blink CompletionItem (LSP-shaped + our carry fields):
{
  label    = ai.label,          -- string (required by LSP)
  detail   = ai.description,    -- string? (LSP detail; shown secondary by blink)
  kind     = 1,                 -- int: blink.cmp CompletionItemKind.Text == 1
  pi_item  = vim.deepcopy(ai),  -- the ORIGINAL AutocompleteItem {value,label,description} for execute
  pi_prefix = prefix,           -- string: this batch's getSuggestions result.prefix for execute
}
-- NOTE: `pi_item` / `pi_prefix` are NON-STANDARD fields. blink passes our item object back to
-- execute verbatim (it only ADDS metadata: source_id, source_name, cursor_column). Verified safe.
```

### Implementation Tasks (ordered by dependencies)

```yaml
Task 1: CREATE plugin/lua/pi-editor/blink_source.lua
  - IMPLEMENT: a `local M = {}` source table with M.new(opts, config), M:enabled(),
    M:get_trigger_characters(), M:get_completions(context, callback), M:execute(context, item, callback, default).
  - FOLLOW pattern: the blink.cmp.Source interface (sources/lib/types.lua) for signatures;
    completion.lua's accept/do_refresh (S30/S32) for the bridge.request + coords + degrade discipline.
  - NAMING: module returns `M`; constructor `M.new`; methods colon-style `M:enabled`, `M:get_trigger_characters`,
    `M:get_completions`, `M:execute` (blink calls them as `source:method()`).
  - PLACEMENT: plugin/lua/pi-editor/blink_source.lua (PRD §7.2 module layout).
  - DETAILS: see "Implementation Patterns" below (full reference body).
  - DOCSTRING (Mode A): a Lua docstring at top explaining registration in blink.cmp config:
        require('blink.cmp').setup({
          sources = { providers = { ['pi-editor'] = { module = 'pi-editor.blink_source' } } },
        })
    plus the engine="blink" recommendation + the "execute overrides blink's textEdit default" note.

Task 2: CREATE plugin/tests/blink_source_smoke.lua   (Level-3 gate, plenary-FREE)
  - IMPLEMENT: the fake-luv-server + REAL bridge + REAL completion idiom (mirror completion_accept_smoke.lua).
    Flows: (a) handshake -> pi.bridge set; (b) source.new -> object; (c) :enabled() == true;
    (d) :get_trigger_characters() deep-equal {"/","@"}; (e) :get_completions(fake_ctx, cb) ->
    server OBSERVES getSuggestions {lines={"/mo"}, cursorLine=0, cursorCol=3(utf16), force==nil} ->
    cb fires with mapped item {label="model", detail=..., kind=1, pi_item.value="/model", pi_prefix="/mo"} ->
    returned cancel is a function; (f) :execute(ctx, item, exec_cb, default) -> server OBSERVES
    applyCompletion {item.value="/model", prefix="/mo", lines={"/mo"}} -> server replies
    {lines={"/model "}, cursorLine=0, cursorCol=7} -> buffer replaced to {"/model "}, cursor {1,7},
    exec_cb called true, default NOT called.
  - FOLLOW pattern: plugin/tests/completion_accept_smoke.lua bootstrap (rtp append, fake server via
    jsonlreader, real bridge.handshake, vim.wait polling, check(cond,msg) accumulator, SMOKE_PASS/cquit).
  - NAMING: blink_source_smoke.lua (matches the *_smoke.lua convention). Print "SMOKE_PASS" + exit 0.
  - CRITICAL: write to a FILE; run via +"luafile tests/blink_source_smoke.lua" +qa. NO heredoc-to-stdin.
  - PLACEMENT: plugin/tests/blink_source_smoke.lua.

Task 3: CREATE plugin/tests/blink_source_spec.lua   (Level-2 gate, plenary/busted)
  - IMPLEMENT: unit cases with an INJECTED fake pi.bridge (set/restore around each case) + a SPIED
    completion.accept (replace require("pi-editor.completion").accept with a recorder; restore after).
    Cases: (1) new returns object with all 5 methods; (2) enabled true/false (env+bridge matrix);
    (3) get_trigger_characters {"/","@"}; (4) get_completions builds {lines,cursorLine,cursorCol}
    via coords, calls bridge.request("getSuggestions",…), maps items w/ kind=1 + pi_item + pi_prefix,
    calls cb EXACTLY ONCE, returns a cancel fn; (5) get_completions empty-response when
    not-connected / err / null; (6) execute calls completion.accept(pi_item, pi_prefix) + cb() and
    does NOT call default.
  - FOLLOW pattern: plugin/tests/bridge_request_spec.lua (describe/it, before_each/after_each cleanup,
    reset of pi.bridge + completion.accept spy).
  - NAMING: blink_source_spec.lua (matches *_spec.lua convention).
  - PLACEMENT: plugin/tests/blink_source_spec.lua.
```

### Implementation Patterns & Key Details

```lua
--- === plugin/lua/pi-editor/blink_source.lua — OPTIONAL blink.cmp source (PRD §7.7) ===
--- Register in your blink.cmp config:
---     require('blink.cmp').setup({
---       sources = { providers = { ['pi-editor'] = { module = 'pi-editor.blink_source' } } },
---     })
--- Recommended: also set `require('pi-editor').setup({ engine = 'blink' })` so the plugin's builtin
--- popup triggers do not compete with blink. This source reuses the SAME bridge.getSuggestions +
--- completion.accept(applyCompletion) path as the builtin engine. `execute` overrides blink's default
--- textEdit application (pi items have no textEdit — pi does prefix replacement server-side).

local M = {}

-- blink.cmp CompletionItemKind.Text == 1 (types.lua). Hardcode 1 (cheap, stable); do NOT
-- require('blink.cmp.types') — this module must load even when blink.cmp is absent.
local KIND_TEXT = 1

--- blink calls require('pi-editor.blink_source').new(opts, config). Both args are the provider
--- config; unused in v1 (the bridge is read LIVE from require("pi-editor").bridge so a late
--- handshake / /reload is always picked up).
function M.new(opts, config)                       -- opts/config ignored in v1
  return setmetatable({}, { __index = M })
end

--- Active iff pi spawned this editor (env var set) AND the bridge connected (pi.bridge ~= nil).
--- (PRD §7.7; mirrors external_deps §2.) Reads the env var + bridge LIVE.
function M:enabled()
  return vim.env.PI_NVIM_BRIDGE ~= nil and require("pi-editor").bridge ~= nil
end

--- Trigger characters (PRD §7.7): "/" (file completion) + "@" (commands).
function M:get_trigger_characters()
  return { "/", "@" }
end

--- Fetch completions. MUST call `callback` at least once (blink contract). Returns a cancel fn.
function M:get_completions(context, callback)
  local pi_mod  = require("pi-editor")
  local bridge  = pi_mod.bridge
  local empty   = { items = {}, is_incomplete_backward = false, is_incomplete_forward = false }
  -- (1) silent degrade: no bridge / not connected / bad API -> empty (call cb exactly once)
  if not bridge
     or type(bridge.is_connected) ~= "function" or not bridge.is_connected()
     or type(bridge.request) ~= "function" then
    callback(empty); return function() end
  end
  -- (2) extract the FULL buffer (context.line is one line only) + cursor
  local bufnr = (context and type(context.bufnr) == "number") and context.bufnr or 0
  local ok, lines = pcall(vim.api.nvim_buf_get_lines, bufnr, 0, -1, false)
  if not ok or type(lines) ~= "table" then callback(empty); return function() end end
  local cursor   = (context and type(context.cursor) == "table") and context.cursor or { 1, 0 }
  local row      = cursor[1] or 1
  local byte_col = cursor[2] or 0          -- 0-indexed BYTE (same as nvim_win_get_cursor)
  -- (3) nvim cursor -> pi cursor (UTF-16); route through the centralized coords seam (multibyte-safe)
  local pi_cur = require("pi-editor.coords").nvim_to_pi_coords(lines, row, byte_col)
  local params = { lines = pi_cur.lines, cursorLine = pi_cur.cursorLine, cursorCol = pi_cur.cursorCol }
  -- NOTE: NO `force` key — matches the builtin normal (TextChangedI) trigger; only Tab sets force=true.
  -- (4) issue getSuggestions; map result -> blink items; call cb EXACTLY ONCE
  local id = bridge.request("getSuggestions", params, function(err, result)
    if err or type(result) ~= "table" then callback(empty); return end   -- err/null/malformed -> empty
    local raw    = (type(result.items) == "table") and result.items or {}
    local prefix = (type(result.prefix) == "string") and result.prefix or ""
    local mapped = {}
    for i = 1, #raw do
      local it = raw[i]
      if type(it) == "table" then
        mapped[#mapped + 1] = {
          label     = it.label,
          detail    = it.description,
          kind      = KIND_TEXT,
          pi_item   = vim.deepcopy(it),   -- ORIGINAL AutocompleteItem for execute (deepcopy: blink mutates)
          pi_prefix = prefix,             -- this batch's prefix for execute (fetch-time; server reconciles)
        }
      end
    end
    callback({ items = mapped, is_incomplete_backward = false, is_incomplete_forward = false })
  end)
  -- (5) return a cancel fn (bridge.cancel is a no-op if already resolved / unknown id)
  return function()
    if type(id) == "string" and type(bridge.cancel) == "function" then pcall(bridge.cancel, id) end
  end
end

--- Apply the selected item via pi's applyCompletion (pi-faithful insertion). We do NOT call
--- `default` — blink's default applies item.textEdit, which pi items lack. (Contract §1; PRD §7.7.)
function M:execute(context, item, callback, default)
  local completion = require("pi-editor.completion")
  local pi_item   = (type(item) == "table") and item.pi_item   or nil
  local pi_prefix = (type(item) == "table") and item.pi_prefix or nil
  -- completion.accept reads the LIVE buffer + cursor, converts coords, issues applyCompletion,
  -- and replaces the buffer + cursor in its async cb. Safe without the builtin menu attached
  -- (menu.get_buf()->nil falls back to current buf; we pass prefix_override so menu.get_prefix
  -- is never consulted). Fire-and-forget (its cb is async); pcall so a bridge bug can't throw.
  pcall(completion.accept, pi_item, pi_prefix)
  callback()              -- tell blink we handled it; blink will NOT apply its default
  -- default is intentionally NOT called.
  return function() end   -- optional cancel fn (applyCompletion is one-shot; nothing to abort)
end

return M
```

**Non-obvious decisions (justify each in the code comments):**
1. **`KIND_TEXT = 1` hardcoded** — avoids `require("blink.cmp.types")` so the module loads even when
   blink.cmp isn't installed yet (graceful `:require`). The integer is stable across blink versions.
2. **Read `require("pi-editor").bridge` LIVE inside every method** — never cache at module load
   (handshake resolves async; nil before connect / after `/reload`).
3. **Deepcopy the original item** into `pi_item` — blink mutates returned items; we must hand
   `applyCompletion` an untouched `{value,label,description}`.
4. **Stash `pi_prefix` per item** — `execute` only gets the item back; the prefix would otherwise be
   lost. Mirrors the builtin engine's fetch-time-prefix behavior.
5. **No `force` in getSuggestions params** — the normal blink trigger must not force (only Tab does).
6. **`execute` returns a no-op cancel** — `applyCompletion` is one-shot (no AbortController on the
   server for it); there's nothing to abort. Returning `nil` is also valid but a function is harmless.
7. **Silent degrade, no `vim.notify`** — repo convention (S39 owns the one-time toast); an empty list
   is the correct "no completions" signal to blink.

### Integration Points

```yaml
NO new RPC methods:        # reuses getSuggestions + applyCompletion (P1.M2.T6, both SHIPPED)
NO new autocmds:           # the source is driven entirely by blink's lifecycle
NO buffer manipulation:    # delegates to completion.accept (S32) for the actual edit
NO new config keys:        # engine = "blink" already exists in init.lua defaults (informational only)
REGISTRATION (user side):  # the user's blink.cmp config (NOT our code):
  sources.providers["pi-editor"] = { module = "pi-editor.blink_source" }
SEAM CONSUMED:             # require("pi-editor").bridge  (init.lua — published for exactly this use, PRD §7.7)
SEAM CONSUMED:             # require("pi-editor.completion").accept(item, prefix_override?)  (S32)
SEAM CONSUMED:             # require("pi-editor.coords").nvim_to_pi_coords(lines, row, byte_col)  (S29)
```

---

## Validation Loop

> **AGENTS.md HARD RULE (load-bearing):** every nvim invocation below writes the script to a real
> FILE and runs it with `+"luafile <path>" +qa`. **NEVER** pipe a heredoc / `echo` into nvim stdin —
> it deadlocks headless nvim and hangs the session forever. Always wrap with `timeout`.

### Level 1: Syntax & Style (run from `plugin/`)

```bash
# Load-check: the module must parse + require cleanly (blink.cmp need NOT be installed).
timeout 30 nvim --headless --clean -u NORC \
  -c 'set rtp+=.' \
  -c 'lua local ok, M = pcall(require, "pi-editor.blink_source"); assert(ok, "require failed: "..tostring(M)); assert(type(M.new)=="function", "M.new missing"); print("LOAD_OK")' \
  -c 'qa'
echo "exit=$?   # 0 + LOAD_OK = pass"

# If selene/luacheck are configured in this repo, lint the new file (best-effort; not blocking):
#   selene --config <repo-selene.toml> plugin/lua/pi-editor/blink_source.lua   2>/dev/null || true
# Expected: LOAD_OK, exit 0. Fix any parse error before proceeding.
```

### Level 2: Unit Tests (plenary/busted) — run from `plugin/`

```bash
# The blink source spec (fake bridge + spied completion.accept).
timeout 90 nvim --headless --clean -u tests/minimal_init.lua \
  -c 'lua require("plenary.busted").run("tests/blink_source_spec.lua")'
echo "exit=$?   # 0 = all cases pass"

# Expected: 0 failures. If a case fails, READ the assertion message — it pinpoints the defect
# (bad params / wrong kind / double-callback / execute called default / etc.).
```

### Level 3: Integration (plenary-FREE smoke) — run from `plugin/`

```bash
# End-to-end: real bridge + real completion + fake server + a real Neovim buffer.
# Proves the full loop: handshake -> getSuggestions(correct coords, no force) -> mapped items
# (kind=1, pi_item, pi_prefix) -> execute -> applyCompletion(item,prefix) -> buffer rewritten + cursor set.
timeout 60 nvim --headless --clean -u NORC +"luafile tests/blink_source_smoke.lua" +qa
echo "exit=$?   # 0 + 'SMOKE_PASS' = pass; 1 = a check failed (read the FAIL: lines on stderr)"

# Expected: prints "SMOKE_PASS", exit 0. The smoke MUST assert:
#   * server saw getSuggestions { lines={"/mo"}, cursorLine=0, cursorCol=3(utf16), force==nil }
#   * cb got {items=#1, is_incomplete_backward=false, is_incomplete_forward=false}
#   * items[1] = {label="model", detail=<desc>, kind=1, pi_item.value="/model", pi_prefix="/mo"}
#   * execute -> server saw applyCompletion {item.value="/model", prefix="/mo", lines={"/mo"}}
#   * after reply: buffer == {"/model "}, cursor == {1,7}, exec_cb called, default NOT called
```

### Level 4: Domain-specific (manual registration sanity, OPTIONAL)

```bash
# Only if blink.cmp is installed in the test nvim: confirm registration doesn't error and the source
# shows up. This is a manual/interactive check (open a pi-prompt buffer, type "/", confirm candidates).
# NOT automated — the Level-3 smoke already proves the source contract end-to-end with a fake bridge,
# so this level is informational. Skip if blink.cmp isn't on the test runtimepath.
```

---

## Final Validation Checklist

### Technical Validation
- [ ] Level 1: module loads (`LOAD_OK`, exit 0) without blink.cmp installed.
- [ ] Level 2: `blink_source_spec.lua` all cases pass (exit 0).
- [ ] Level 3: `blink_source_smoke.lua` prints `SMOKE_PASS`, exit 0.
- [ ] No file other than the 3 new files (`blink_source.lua` + 2 tests) was modified.

### Feature Validation
- [ ] `new(opts, config)` returns an object with `enabled`, `get_trigger_characters`, `get_completions`, `execute`.
- [ ] `:enabled()` true iff env var AND `pi.bridge` set; false otherwise.
- [ ] `:get_trigger_characters()` == `{ "/", "@" }`.
- [ ] `:get_completions()` calls `bridge.request("getSuggestions", {lines, cursorLine, cursorCol})` with **no `force`**, via `coords.nvim_to_pi_coords`.
- [ ] Mapped items are `{label, detail=description, kind=1, pi_item=deepcopy(orig), pi_prefix=prefix}`.
- [ ] The blink callback is called **exactly once**; degrade paths emit the empty response.
- [ ] `get_completions` returns a cancel fn that calls `bridge.cancel(id)`.
- [ ] `:execute()` calls `completion.accept(pi_item, pi_prefix)` + `callback()` and does NOT call `default`.
- [ ] No `vim.notify` calls added (silent degrade; S39 owns toasts).

### Code Quality Validation
- [ ] Follows the repo's plenary-free smoke idiom (mirror `completion_accept_smoke.lua`).
- [ ] Mode-A Lua docstring documents blink.cmp registration + the `engine="blink"` recommendation.
- [ ] No module-level mutable state; bridge read live in every method.
- [ ] Every degrade path is `pcall`-safe / never throws out of a source method.
- [ ] Smoke test is a real file run with `:luafile` (never piped to nvim stdin — AGENTS.md HARD RULE).

---

## Anti-Patterns to Avoid

- ❌ Don't `require("pi-editor.bridge")` at module top-level and cache it — read `require("pi-editor").bridge` LIVE (handshake is async).
- ❌ Don't use `context.line` as the `lines[]` for getSuggestions — it's ONE line; fetch the full buffer.
- ❌ Don't call `default_implementation` in `execute` — blink's textEdit diverges from pi's insertion.
- ❌ Don't hand-roll UTF-16 — route through `coords.nvim_to_pi_coords`.
- ❌ Don't call the get_completions callback more than once per invocation (no streaming for an RPC fetch).
- ❌ Don't add `force=true` to the normal blink trigger (only Tab forces).
- ❌ Don't `vim.notify` on degrade (silent empty-list is correct; S39 owns toasts).
- ❌ Don't pipe a heredoc into `nvim` stdin in ANY validation command (AGENTS.md HARD RULE — hangs).

---

## Confidence Score

**9 / 10** for one-pass success.

Rationale: every consumed API is already shipped and quoted verbatim (`completion.accept`,
`bridge.request`/`cancel`/`is_connected`, `coords.nvim_to_pi_coords`, `pi.bridge`). The blink.cmp
contract was verified against the locally-cloned source types (not guessed). The one non-obvious
design point — carrying the prefix + original item through to `execute` — is fully specified with a
justification. The reuse of `completion.accept` means this module owns NO buffer-editing logic (the
riskiest part already exists and is tested). The only residual uncertainty is the
`engine="blink"` coexistence story, which is explicitly out of scope (documented, not coded).