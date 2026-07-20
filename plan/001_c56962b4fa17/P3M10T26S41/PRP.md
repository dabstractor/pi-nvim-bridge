---
name: "P3.M10.T26.S41 — Clear caches + re-query on `commandsChanged` (Neovim client)"
description: |
  Ship the **BEHAVIOR** half of the bridge's one server→client notification
  (`commandsChanged`, PRD §5.4 / §13 step 13 / §11). The **MECHANISM** is DONE: S27
  (`P2.M5.T16.S27`) added `bridge.on_notification(method, handler)` — a `schedule_wrap`'d
  handler registry + a `dispatch(msg)` branch that routes a
  `{"jsonrpc":"2.0","method":"commandsChanged"}` message (no `id`, no `params`) to the
  registered handler, plus `M.close()` clearing the registry. **S27 deliberately ships NO
  cache clearing** — its own research (`P2M5T16S27/research/notes.md` §5) names S41 as the
  consumer:

  ```lua
  require("pi-editor").bridge.on_notification("commandsChanged", function(_params)
    -- clear the cached command list; the next getSuggestions/getCommands re-queries pi.
    cached_commands = nil
  end)
  ```

  **THE BEHAVIOR (this task):** when pi rebuilds the autocomplete provider on
  `/reload`/`new`/`resume`/`fork` (`session_start`) and the bridge (S17, DONE) broadcasts
  `commandsChanged`, the Neovim client must (a) **clear its completion cache** — the items
  shown in / available to the menu were computed against the OLD command set and may now be
  stale (a command added/removed/renamed, a new prompt template) — and (b) **re-query** so
  a *live* menu reflects the rebuilt provider, without spuriously popping a menu when the
  user is not actively completing (PRD §11: "Reload during an open editor … The open
  editor's existing connection stays valid.").

  **DELIVERABLES (EDIT-ONLY, additive + backward-compatible — NO new module, NO TS change):**
    (1) **EDIT** `plugin/lua/pi-editor/completion.lua` — add a public `M.on_commands_changed(buf?)`
        that clears the cache (`cancel_timer` + `bridge.cancel(inflight_id)` + `state.last_result=nil`
        + `state.gen = state.gen+1` to drop a late stale cb) + closes the stale menu, then
        **conditionally re-queries** via `M.refresh(buf)` **iff the menu WAS open** (the precise
        "actively completing" signal) AND `buf` is valid + current. **Preserves `state.buf`**
        (unlike `M.reset()`, which nils it) so the re-query can target it. Idempotent + never throws.
    (2) **EDIT** `plugin/lua/pi-editor/init.lua` — in `M.activate()`, register the handler via
        `br.on_notification("commandsChanged", …)` in the SAME `pcall` block as `on_disconnect`,
        **AFTER** `br.handshake(…)` (GOTCHA D: `handshake()` runs `M.close()` at its start which
        clears `notification_handlers` — registering before is wiped). The handler is
        `schedule_wrap`'d by `on_notification` (api-safe — can touch buffers/menus).
    (3) **EXTEND** `plugin/tests/completion_spec.lua` — a new `describe("on_commands_changed", …)`
        block: clears `last_result`; closes the stale menu; drops a late stale cb (gen-bump +
        `cancel`); **re-queries when `was_open`** (fresh `getSuggestions` issued; on success the
        menu reopens with fresh items); **does NOT re-query when the menu was closed**; does NOT
        re-query when `buf` isn't current; never throws on bad state (nil/wiped buf, absent
        bridge); **preserves `state.buf`** (contrast `reset()`).
    (4) **EXTEND** `plugin/tests/completion_smoke.lua` — an end-to-end case: populate a menu,
        drive `commandsChanged` (call `on_commands_changed` directly), assert the cache cleared +
        a fresh `getSuggestions` re-fired + the menu reopened with the NEW items.
    (5) **EXTEND** `plugin/tests/bridge_notify_spec.lua` — ONE case that the S41 handler
        registered via `on_notification("commandsChanged", …)` runs on the real notification
        (observable: closes a stale menu). (Most of the mechanism is already covered by S27; this
        is the wiring assertion.)

  **NON-GOALS:** the S17 server-side broadcast + wire form are DONE (unchanged). The S27
  mechanism is DONE (unchanged). `vim.fn.mode()` is NOT used as the guard (fiddly to drive
  in headless plenary); `menu.is_open()` (captured before close) is the chosen "actively
  completing" signal. The empty-result menu-closed case does NOT re-query (accepted minor
  edge — the next keystroke fetches fresh; PRD §11 "existing connection stays valid" is
  satisfied; documented). No `getCommands`/hover menu (P3.M10 future). No TS edits.

  **NON-REGRESSION:** the existing `completion_spec` debounce/supersession/seam tests still
  pass (S41 adds ONE function + ONE registration block; it shares `state.gen`/`inflight_id`/
  `debounce_timer` with `do_refresh`/`force_fetch` exactly as `reset()` does — the gen-guard
  idiom is unchanged). `bridge_notify_spec` (S27) still passes (the registration is additive).
  `init_spec`/`activate_spec` still pass (the registration is inside the existing
  never-throws `pcall`).
---

# Goal

**Feature Goal**: Complete the client-side half of `commandsChanged` (PRD §5.4 / §13 step 13).
Consume the S27 `on_notification` API: register a `commandsChanged` handler that
**invalidates the completion cache** (the items the menu is showing were computed against
the pre-reload provider and may be stale) and **re-queries** so a *live* menu refreshes
against the rebuilt provider — **without** spuriously popping a menu when the user is not
actively completing. The handler runs on the nvim main loop (S27 `schedule_wrap`'s it) and
**never throws** (out-of-band event; must not break editing). This is the last behavioral
piece of the `commandsChanged` round-trip (S17 emit → S27 dispatch → **S41 react**).

**Deliverable** (EDIT-ONLY — 2 source files, 3 test files; NO new module, NO TS change):
- **`plugin/lua/pi-editor/completion.lua`** — new public `M.on_commands_changed(buf?)`
  (cache-invalidate + conditional re-query; preserves `state.buf`; never throws).
- **`plugin/lua/pi-editor/init.lua`** — register the handler in `M.activate()` via
  `br.on_notification("commandsChanged", …)` after `br.handshake(…)`.
- **`plugin/tests/completion_spec.lua`** — new `describe("on_commands_changed", …)` block.
- **`plugin/tests/completion_smoke.lua`** — end-to-end drive case.
- **`plugin/tests/bridge_notify_spec.lua`** — wiring assertion (handler runs on the notification).

**Success Definition**:
- A `commandsChanged` notification clears `completion.state.last_result` and closes the
  stale menu (its rendered items were computed against the OLD command set).
- Any in-flight `getSuggestions` is cancelled AND `state.gen` is bumped, so a **late** stale
  result (one already in flight when the notification arrived) is dropped by the gen-guard
  and **cannot** repopulate the cleared cache.
- **If a menu was open** when the notification arrived, the client issues a **fresh**
  `getSuggestions` against the rebuilt provider; on success the menu reopens with the NEW
  items (or closes if now empty) — exactly the live-update UX PRD §11 implies.
- **If no menu was open** (user not actively completing), the client does **not** issue a
  fresh request (no spurious pop; the next keystroke fetches fresh).
- The handler **never throws** (nil/wiped `buf`, absent/disconnected bridge, no menu module,
  bad `state`) and is **idempotent** (safe to fire twice).
- The handler is **api-safe** (runs on the nvim main loop via S27's `schedule_wrap`; a body
  that touches `vim.api.*` does not throw `E5560`).
- `state.buf` is **preserved** (contrast `M.reset()`, which nils it) so the re-query can
  target the pi-prompt buffer.
- The registration survives multiple editor open/close cycles within one session (the bridge
  server stays up; each editor is a new connection; `activate()` re-registers after each
  successful handshake — S27's `close()`-clears-registry is defense-in-depth, not relied on).
- All existing tests still pass (pure additive edit).

## User Persona

**Target User**: a pi user editing a prompt in the Neovim `$EDITOR` that pi launched, while
pi reloads / starts a new session / resumes / forks (any `session_start` reason).

**Use Case**: the user has typed `/mod` and the completion menu is showing `/model …`; they
trigger a pi action that rebuilds the provider (e.g. a `/reload`, or an extension registers
a new command). The menu must update to reflect the rebuilt command set **without** the user
retyping.

**Pain Points Addressed**: today the client would keep showing the stale `/model` items until
the next keystroke (the cache is never invalidated by an out-of-band event). For commands
that were *removed* this is actively misleading; for *added* commands the user must type a
throwaway char to see them.

## Why

- **PRD fidelity**: PRD §1 mandates the external editor's completion be "byte-for-byte
  identical" to the TUI because the *same live provider* produces the suggestions. After a
  provider rebuild, the TUI re-queries on the next keystroke; the external editor must do the
  same — and additionally react to the `commandsChanged` push so a *live* menu is correct.
- **Closes the round-trip**: S17 (emit) → S27 (dispatch) → **S41 (react)**. Without S41 the
  S17/S27 plumbing has no consumer; the cache is never invalidated out-of-band.
- **Phase 3 polish** (PRD §13 step 13): "`commandsChanged` notification handling (clear
  caches)" — this is literally that step.

## What

When the bridge pushes `{"jsonrpc":"2.0","method":"commandsChanged"}` (no `id`, no `params`),
the client:
1. Captures `was_open = menu.is_open()`.
2. Cancels the debounce timer + the in-flight `getSuggestions` (via `bridge.cancel`).
3. Clears `state.last_result` and bumps `state.gen` (drops a late stale cb).
4. Closes the menu (clears its rendered items).
5. **Iff `was_open`** and `state.buf` is valid + current, fires `M.refresh(state.buf)` → a
   fresh debounced `getSuggestions` against the rebuilt provider → on success the menu
   reopens with fresh items (or closes if empty).

### Success Criteria

- [ ] `commandsChanged` clears `state.last_result` + closes the menu + cancels in-flight +
      bumps `state.gen` (a late stale cb is dropped).
- [ ] Re-query fires **iff** the menu was open + `buf` valid + `buf == current` (a fresh
      `getSuggestions` is observable; on success the menu reopens with the new items).
- [ ] No re-query when the menu was closed (no fresh request observable).
- [ ] `state.buf` is preserved (NOT nil after the call — contrast `reset()`).
- [ ] Never throws on bad state (nil/wiped `buf`, absent bridge, no menu module); idempotent.
- [ ] Handler runs api-safe (main loop; `vim.api.*` does not throw `E5560`).
- [ ] Registered in `init.lua M.activate()` after `handshake()`; re-registered per session.

## All Needed Context

### Context Completeness Check

_Passed._ A reader who knows nothing of this codebase gets: the exact mechanism API (S27,
DONE), the exact cache fields + their semantics, the exact teardown idiom (`reset()` /
`hide_and_cancel()`), the exact registration site + its GOTCHA, the exact test harness
(`fake_bridge` + `populated_menu` + `wait_for`), the exact wire form, and copy-ready code.
No pi-source knowledge required (the server half is DONE; nothing on the TS side changes).

### Documentation & References

```yaml
# MUST READ — the mechanism S41 consumes (DONE; do NOT modify it)
- file: plugin/lua/pi-editor/bridge.lua
  why: |
    `M.on_notification(method, handler)` (line 716) is the registration API S41 calls.
    `schedule_wrap`'s the handler at store time → api-safe from the luv `read_start` callback
    (dispatch runs in luv fast context; GOTCHA 5). `close()` (line 743) clears the registry
    (S27 §6 defense-in-depth). The dispatch branch routes `{method, NO string id}` → handler.
  critical: |
    GOTCHA D (from S25, inherited by S41): `bridge.handshake()` runs `M.close()` at its start,
    which clears `notification_handlers`. S41's registration MUST come AFTER `handshake()` in
    `init.lua M.activate()` — exactly where `on_disconnect` is already registered. Registering
    before `handshake()` is silently wiped.

# MUST READ — the module S41 adds a function to
- file: plugin/lua/pi-editor/completion.lua
  why: |
    Singleton `local state = {buf, debounce_timer, gen, inflight_id, last_result}` (lines 252–259).
    `M.reset()` (line 526) = cancel_timer + cancel(inflight) + last_result=nil + gen=0 + buf=nil
    (S41 CANNOT reuse reset() — it nils `state.buf`, which the re-query needs).
    `cancel_timer()` (local, ~line 358) = stop()+close() the defer handle (the leak fix; never stop-only).
    `do_refresh(buf)` (line ~393) reads buf/cursor FRESH, supersede layers 1+2 (cancel inflight + gen-guard),
    issues `bridge.request("getSuggestions", {lines,cursorLine,cursorCol,force=false}, cb)`; cb stores
    `state.last_result` + fires `M.on_results(buf, items, prefix)`.
    `M.refresh(buf)` (line ~497) = the autocmd entry: sets `state.buf=buf`, cancel_timer, compute trigger-aware
    debounce (S40), `vim.defer_fn(do_refresh, ms)`.
    `M.on_results` = the result→menu seam (set by `menu.attach()`).
    S37 `hide_and_cancel()` (~line 786) = `menu.close()` then `M.reset()` — the lifecycle-teardown idiom to mirror.
  pattern: |
    S41's `on_commands_changed` is a NEW lifecycle-style public fn in the SAME shape as `on_insert_leave`/
    `on_buf_leave` (S37): validate buf, never-throw (pcall everything), reuse `cancel_timer()` + the cancel-inflight
    idiom. DIFFERENCES from `hide_and_cancel()`: (a) bump `gen` (don't zero) to drop a late cb; (b) preserve
    `state.buf`; (c) conditionally re-query via `M.refresh(buf)` iff `was_open`.
  gotcha: |
    Read `require("pi-editor").bridge` FRESH inside the fn (handshake resolves async; tests swap the fake in
    after require — the existing `do_refresh`/`force_fetch` discipline). `menu.is_open()` + `menu.close()` are
    read via `require("pi-editor.menu")` at call time (pcall-wrapped — the menu module may be absent in a test).

# MUST READ — the menu S41 closes + observes
- file: plugin/lua/pi-editor/menu.lua
  why: |
    `M.is_open()` (line 614) — accessor; the `was_open` re-query guard.
    `M.close()` (line 542) — clears `selected=0`, `open=false`; idempotent + never throws.
    `M.on_results(buf, items, prefix)` (line 492) — the seam: empty→close, non-empty→store+open.
    The menu holds its OWN copy of items → clearing `completion.last_result` does NOT clear the menu;
    S41 MUST call `menu.close()` explicitly.
  gotcha: menu state is independent of completion state; never assume clearing one clears the other.

# MUST READ — the registration site
- file: plugin/lua/pi-editor/init.lua
  why: |
    `M.activate()` (line 134) is where handlers are wired, in ONE `pcall(function() … end)` block:
      (1) `br.handshake(desc, cb)` (async connect + hello; sets `require("pi-editor").bridge` on success),
      (2) THEN `br.on_disconnect(function(_reason) menu.close(); completion.reset(); notify.once(...) end)`.
    S41 registers in the SAME block, IMMEDIATELY AFTER the `on_disconnect` block (same order discipline).
  pattern: mirror the EXACT shape of the `on_disconnect` registration (the `if type(br.on_disconnect)=="function" then … end`
    guard + `pcall(function() require("pi-editor.completion").on_commands_changed() end)` body).
  gotcha: GOTCHA D (above) — after `handshake()`, NOT before.

# The mechanism's research (the explicit S41 contract S27 left)
- file: plan/001_c56962b4fa17/P2M5T16S27/research/notes.md
  section: §5 "Public registration API" + "Downstream contract (for S41)"
  why: S27's notes NAME S41 as the consumer + sketch the handler shape (`cached_commands = nil`). S41 implements
    the real cache (`state.last_result`) + the re-query behavior S27's sketch omits.

# The wire form + server emit (DONE; do NOT modify)
- file: extension/connection.ts
  section: `sendNotification` (line 178) + `broadcastNotification` (line 206)
  why: |
    `broadcastNotification("commandsChanged")` iterates ONLY handshaken connections; `sendNotification`
    OMITS `params` on the wire when `undefined` → the wire line is EXACTLY
    `{"jsonrpc":"2.0","method":"commandsChanged"}` (no id, no params). `params` arrives as `nil` in the
    handler (verified by `bridge_notify_spec` case (2)). S41 ignores `params`.

# PRD anchors
- url: (in-repo) PRD §5.4 (methods table: `commandsChanged` S→C notification), §11 (Reload during an open editor),
  §13 step 13 (commandsChanged notification handling — clear caches)
  why: the spec S41 implements.
```

### Current Codebase tree (relevant slice)

```bash
plugin/
  lua/pi-editor/
    init.lua          # M.activate() — the registration site (EDIT: add on_notification block)
    bridge.lua        # M.on_notification (DONE S27) — S41 CALLS this; do NOT modify
    completion.lua    # singleton `state` + do_refresh/refresh/reset/on_insert_leave/on_buf_leave (EDIT: add on_commands_changed)
    menu.lua          # is_open/close/on_results (DONE) — S41 calls; do NOT modify
    coords.lua  jsonlreader.lua  notify.lua   # unchanged
  plugin/pi-editor.lua   # VimEnter shim (unchanged)
  ftplugin/pi-prompt.lua # buffer-local autocmds (unchanged)
  tests/
    minimal_init.lua          # plenary harness (unchanged)
    completion_spec.lua       # EDIT: add describe("on_commands_changed", …)
    completion_smoke.lua      # EDIT: add an end-to-end drive case
    bridge_notify_spec.lua    # EDIT: add ONE wiring assertion (S41 handler runs on the notification)
```

### Desired Codebase tree with files to be added and responsibility

```bash
# NO new files. EDIT-ONLY:
plugin/lua/pi-editor/completion.lua   # + M.on_commands_changed(buf?)  (cache-invalidate + conditional re-query)
plugin/lua/pi-editor/init.lua         # + br.on_notification("commandsChanged", …) registration in M.activate()
plugin/tests/completion_spec.lua      # + describe("on_commands_changed", …)
plugin/tests/completion_smoke.lua     # + end-to-end drive case
plugin/tests/bridge_notify_spec.lua   # + 1 wiring assertion
```

### Known Gotchas of our codebase & Library Quirks

```lua
-- CRITICAL (GOTCHA D, inherited from S25): bridge.handshake() runs M.close() at its start,
-- which CLEARS notification_handlers. S41's on_notification registration MUST come AFTER
-- handshake() in init.lua M.activate(). (The existing on_disconnect registration already
-- follows this order — mirror it EXACTLY.)

-- CRITICAL: completion.state.buf must be PRESERVED across on_commands_changed (the re-query
-- needs it). Do NOT call M.reset() (it nils state.buf + zeroes gen). Use a TARGETED invalidate.

-- CRITICAL: clearing completion.last_result does NOT clear the menu (menu holds its own copy).
-- MUST call menu.close() explicitly, else stale items stay rendered.

-- GOTCHA (luv fast context): the dispatch runs inline from the luv read_start callback.
-- S27 schedule_wrap's the handler at STORE time → on_commands_changed runs on the nvim main
-- loop → api-safe (vim.api.* is fine). Do NOT add a second schedule_wrap in on_commands_changed.

-- GOTCHA: read require("pi-editor").bridge FRESH (handshake resolves async; tests swap the fake
-- after require). Same for require("pi-editor.menu"). pcall both (a test may not load the menu).

-- NEVER stop()-only a timer — use the existing cancel_timer() (stop()+close(); the leak fix).
-- NEVER throw from on_commands_changed (out-of-band event; pcall every external call).
-- The gen-guard idiom: bump state.gen (NOT zero) so a late stale cb's captured gen != state.gen → dropped.
```

## Implementation Blueprint

### Data models and structure

No new data model. S41 reuses the existing `completion.state` singleton fields
(`last_result`, `inflight_id`, `gen`, `debounce_timer`, `buf`) and the `menu` module's
`is_open()`/`close()`. The only new state is a transient `was_open` LOCAL inside the fn.

### Implementation Tasks (ordered by dependencies)

```yaml
Task 1: EDIT plugin/lua/pi-editor/completion.lua — add M.on_commands_changed(buf?)
  - ADD: a public function M.on_commands_changed(buf) placed in the lifecycle-fn region
         (NEAR on_insert_leave/on_buf_leave, ~line 800, BEFORE `return M`).
  - SIGNATURE: function M.on_commands_changed(buf)  (buf optional; defaults to state.buf).
  - BODY (EXACT — copy-ready; pcall every external call; never throws):
      buf = buf or state.buf
      local was_open = false
      pcall(function() was_open = require("pi-editor.menu").is_open() end)
      cancel_timer()                                   -- stop()+close() the defer (leak fix; reuse existing local)
      local b = require("pi-editor").bridge            -- READ FRESH (handshake async; test mocks)
      if state.inflight_id and b and type(b.cancel) == "function" then
        pcall(b.cancel, state.inflight_id)             -- supersede layer 1 (cancel prev in-flight)
      end
      state.inflight_id = nil
      state.last_result = nil                          -- CLEAR THE CACHE
      state.gen = state.gen + 1                        -- supersede layer 2 (drop a late stale cb)
      pcall(function() require("pi-editor.menu").close() end)  -- clear the menu's OWN stale items
      if not was_open then return end                  -- not actively completing → next keystroke fetches fresh
      if type(buf) ~= "number" or not vim.api.nvim_buf_is_valid(buf) then return end
      if buf ~= vim.api.nvim_get_current_buf() then return end
      pcall(M.refresh, buf)                            -- re-query against the rebuilt provider (debounced; provider gates context)
  - DOC: a luadoc block (---@param buf integer?) + a header note: "S41 — clears cache +
         closes stale menu; re-queries iff the menu WAS open (actively completing) + buf
         valid+current. Idempotent + never throws. Preserves state.buf (contrast reset()).
         Called by init.lua's commandsChanged registration." Add a `-- S41` mode marker.
  - FOLLOW pattern: on_insert_leave/on_buf_leave (S37 lifecycle fns) — validate buf, pcall
         externals, reuse cancel_timer(); AND do_refresh/force_fetch's supersession idiom.
  - NAMING: on_commands_changed (snake_case; mirrors on_insert_leave/on_buf_leave).
  - PLACEMENT: lifecycle region of completion.lua, before `return M`.
  - DO NOT: call M.reset() (nils state.buf); zero state.gen (bump instead); add a second
         schedule_wrap (S27 already wraps); touch state.last_result after clearing (re-query repopulates).

Task 2: EDIT plugin/lua/pi-editor/init.lua — register the handler in M.activate()
  - FIND: the `pcall(function() … br.handshake(desc, cb) … if type(br.on_disconnect)=="function" then … end … end)`
         block inside M.activate() (~lines 152–178).
  - ADD: IMMEDIATELY AFTER the on_disconnect `if … end` block, INSIDE the same outer pcall:
      -- S41: clear caches + re-query on `commandsChanged` (server rebuilt the provider on
      -- /reload/new/resume/fork — PRD §11). Registered AFTER handshake() (handshake() runs
      -- M.close() which clears the registry — GOTCHA D). schedule_wrap'd by on_notification
      -- (api-safe). Never throws.
      if type(br.on_notification) == "function" then
        br.on_notification("commandsChanged", function(_params)
          pcall(function() require("pi-editor.completion").on_commands_changed() end)
        end)
      end
  - FOLLOW pattern: the EXACT shape of the on_disconnect registration (the `if type(br.X)=="function" then … end`
         guard + `pcall(function() require(...)… end)` body).
  - PRESERVE: the existing handshake + on_disconnect + menu.attach registrations + their order.
  - GOTCHA D: MUST be after br.handshake(…), NOT before (handshake() runs M.close() → clears registry).

Task 3: EDIT plugin/tests/completion_spec.lua — add describe("on_commands_changed", …)
  - ADD: a new `describe("pi-editor.completion on_commands_changed", function() … end)` block.
         Reuse the file's `fake_bridge`, `reset`, `wait_for`, `populated_menu` helpers (DO NOT redefine).
  - CASES (mirror the file's existing vim.wait style + assertions):
      (a) surface: exposes on_commands_changed as a function.
      (b) clears state.last_result (assert completion.current() == nil after) + closes the menu
          (assert menu.is_open()==false) — use populated_menu("/mod", 4, {…}, "/mod") first.
      (c) cancels the in-flight getSuggestions + bumps gen → a LATE stale cb (resolve_last with
          OLD items) does NOT repopulate the cache (completion.current() stays nil) and does NOT
          reopen the menu. (Use fake_bridge({auto_cancel_fires=false}) + a manual refresh to plant
          an inflight, then call on_commands_changed, then resolve_last the stale cb.)
      (d) RE-QUERIES when was_open: populated_menu, call on_commands_changed(), assert a FRESH
          getSuggestions is issued (#fake.requests increased), resolve it with NEW items, assert
          the menu reopens with the NEW items (menu.get_selected()/is_open).
      (e) does NOT re-query when the menu was CLOSED: NO populated_menu (just refresh+resolve an
          EMPTY result so menu is closed but last_result was set), call on_commands_changed,
          assert NO fresh getSuggestions (#fake.requests unchanged).
      (f) does NOT re-query when buf isn't current (set a different buf current) — even if was_open.
      (g) preserves state.buf (after on_commands_changed with a known buf, state is still bound —
          observable by a subsequent refresh targeting that buf). Contrast reset() (document in a comment).
      (h) never throws on bad state: on_commands_changed() with nil state.buf / wiped buf / pi.bridge==nil
          (pcall the call; assert no throw; assert cache cleared where applicable).
      (i) idempotent: call twice; no throw; cache still cleared; at most ONE fresh re-query request.
  - NAMING: `it("…", …)` one-line descriptions; mirror existing case grammar.
  - PLACEMENT: a new describe block (after the existing top-level describe's cases, OR a sibling
         describe — match how the file already groups, e.g. the "error/cancelled/timeout" describe).
  - NOTE: do NOT name a local `pending` (shadows plenary.busted's skip fn — file header warns).

Task 4: EDIT plugin/tests/completion_smoke.lua — add an end-to-end drive case
  - ADD: a case that (1) sets up a fake bridge + pi-prompt buf + menu.attach, (2) refresh +
         resolve to open a menu, (3) calls completion.on_commands_changed(buf), (4) asserts the
         cache cleared (completion.current()==nil) + a fresh getSuggestions re-fired, (5) resolves
         the fresh request with NEW items + asserts the menu reopened with them.
  - FOLLOW pattern: the existing completion_smoke.lua cases (fake bridge + vim.wait + assert + print OK).
  - This is the Level-3 (plenary-free) smoke gate per AGENTS.md.

Task 5: EDIT plugin/tests/bridge_notify_spec.lua — add ONE wiring assertion
  - ADD: ONE `it(...)` case (inside the existing `describe("pi-editor.bridge on_notification", …)`)
         that registers the S41 handler via on_notification, populates a menu (or sets a observable
         completion state), has the server push the REAL commandsChanged notification, and asserts
         the S41 behavior ran (e.g. the stale menu closed / cache cleared). Reuse with_handshaken_server.
  - WHY: proves the registration wire-up (Task 2) + the dispatch (S27) + the behavior (Task 1)
         compose end-to-end over a REAL socket. (S27 already proves dispatch; this proves the consumer.)
  - MOST behavior stays in completion_spec (fake bridge is faster + more precise over a socket).
```

### Implementation Patterns & Key Details

```lua
-- === completion.lua: the new fn (Task 1) — copy-ready ===
--- S41 — Clear the completion cache + close the stale menu; iff a menu WAS open (actively
--- completing) + `buf` valid+current, re-query so the menu reflects the rebuilt provider.
--- Called by init.lua's `commandsChanged` registration (S41; consumes S27's on_notification).
--- Idempotent + never throws (out-of-band event; pcall every external call). PRESERVES
--- `state.buf` (contrast `M.reset()`, which nils it) so the re-query can target the pi-prompt buf.
---@param buf integer? The pi-prompt buffer (defaults to state.buf).
function M.on_commands_changed(buf)
  buf = buf or state.buf
  local was_open = false
  pcall(function() was_open = require("pi-editor.menu").is_open() end)
  cancel_timer()                                              -- stop()+close() the pending defer (leak fix)
  local b = require("pi-editor").bridge                        -- READ FRESH (handshake async; test mocks)
  if state.inflight_id and b and type(b.cancel) == "function" then
    pcall(b.cancel, state.inflight_id)                         -- supersede layer 1 (cancel in-flight)
  end
  state.inflight_id = nil
  state.last_result = nil                                      -- CLEAR THE CACHE (the stale items)
  state.gen = state.gen + 1                                    -- supersede layer 2 (drop a late stale cb)
  pcall(function() require("pi-editor.menu").close() end)      -- clear the menu's OWN stale items
  if not was_open then return end                              -- not actively completing → next keystroke fetches fresh
  if type(buf) ~= "number" or not vim.api.nvim_buf_is_valid(buf) then return end
  if buf ~= vim.api.nvim_get_current_buf() then return end
  pcall(M.refresh, buf)                                        -- re-query (debounced; provider gates non-trigger context itself)
end

-- === init.lua: the registration (Task 2) — copy-ready, placed AFTER the on_disconnect block ===
    if type(br.on_notification) == "function" then
      br.on_notification("commandsChanged", function(_params)
        pcall(function() require("pi-editor.completion").on_commands_changed() end)
      end)
    end

-- KEY DETAIL (why `was_open`, not vim.fn.mode()): menu.is_open() is the precise "actively
-- completing with visible suggestions" signal + is trivially observable in a headless plenary
-- test (via populated_menu). vim.fn.mode() is fiddly to drive deterministically headless.
-- The provider itself returns null (→ empty → menu.close) for non-trigger cursor positions,
-- so a re-query never spuriously re-opens the menu.

-- KEY DETAIL (why bump gen, not zero): the gen-guard idiom (`gen ~= state.gen` → drop) is
-- shared with do_refresh/force_fetch. Bumping (forward) is clearer than zeroing; both drop a
-- late cb whose captured gen is now stale. reset() uses gen=0 (also drops) but ALSO nils buf.
```

### Integration Points

```yaml
EVENTS (Neovim autocmds): NONE new. commandsChanged arrives over the socket (S27 dispatch),
  not an autocmd. on_commands_changed is called from the S27-registered handler (init.lua).
STATE (completion.lua): reuses state.{last_result, inflight_id, gen, debounce_timer, buf};
  NO new field. The menu's state is touched only via menu.close()/is_open() (existing API).
CONFIG (init.lua defaults): NONE new. debounce_ms / rpc_timeout_ms unchanged (the re-query
  uses M.refresh → the S40 trigger-aware debounce).
BRIDGE (bridge.lua): NONE. S41 only CALLS M.on_notification (DONE S27); does not modify it.
EXTENSION (TS): NONE. S17 emit + wire form are DONE; unchanged.
```

## Validation Loop

> **AGENTS.md HARD RULE:** NEVER pipe a heredoc into `nvim` stdin (it hangs). Write test
> snippets to a FILE and run with `+"luafile <path>"`. Wrap EVERY nvim invocation in `timeout`.

### Level 1: Load + lint (no selene/luacheck/stylua config in-repo → the load IS the gate)

```bash
cd plugin
# The module must require() without error (catches syntax/typo). File-based; NEVER stdin.
timeout 60 nvim --headless --clean -u NORC -c 'set rtp+=.' \
  -c 'lua require("pi-editor.completion"); require("pi-editor"); print("load ok")' -c 'qa'
echo "exit=$?"   # Expected: exit=0, prints "load ok"
```

### Level 2: Unit/component tests (plenary/busted — the real gate)

```bash
cd plugin
# The new on_commands_changed spec (Task 3):
timeout 90 nvim --headless --clean -u tests/minimal_init.lua \
  -c 'lua require("plenary.busted").run("tests/completion_spec.lua")'
echo "exit=$?"   # Expected: exit=0, all cases pass (0 failures)

# The S27 mechanism + the S41 wiring assertion (Task 5) still pass:
timeout 90 nvim --headless --clean -u tests/minimal_init.lua \
  -c 'lua require("plenary.busted").run("tests/bridge_notify_spec.lua")'
echo "exit=$?"   # Expected: exit=0

# Non-regression: the full affected suite (debounce/supersession/seam + activate/init wiring):
timeout 90 nvim --headless --clean -u tests/minimal_init.lua \
  -c 'lua require("plenary.busted").run("tests/init_spec.lua")'
echo "exit=$?"
# Expected: all pass. If failing, READ the output and fix root cause (do not skip).
```

### Level 3: Smoke (plenary-free, file-based — the E2E gate per AGENTS.md)

```bash
cd plugin
# The end-to-end drive case (Task 4):
timeout 60 nvim --headless --clean -u NORC +"luafile tests/completion_smoke.lua" +qa
echo "exit=$?"   # Expected: exit=0, prints "ok" (the smoke prints OK on success)
```

### Level 4: Domain-specific validation (manual / scripted — optional but recommended)

```bash
cd plugin
# Full plenary sweep across the touched modules (catch cross-file regressions):
for s in completion_spec bridge_notify_spec bridge_request_spec bridge_disconnect_spec init_spec activate_spec menu_spec; do
  timeout 90 nvim --headless --clean -u tests/minimal_init.lua \
    -c "lua require('plenary.busted').run('tests/${s}.lua')" || echo "FAIL: ${s}"
done
# Expected: no FAIL lines.
```

## Final Validation Checklist

### Technical Validation
- [ ] Level 1 load passes (`require("pi-editor.completion")` + `require("pi-editor")` — no error).
- [ ] Level 2 `completion_spec.lua` passes (incl. the new `on_commands_changed` describe block).
- [ ] Level 2 `bridge_notify_spec.lua` passes (incl. the new S41 wiring assertion).
- [ ] Level 2 `init_spec.lua` / `activate_spec.lua` pass (registration is additive; non-regression).
- [ ] Level 3 `completion_smoke.lua` passes (end-to-end drive case).
- [ ] No new files outside the edit list; NO TS change; NO `protocol.ts`/`connection.ts` change.

### Feature Validation
- [ ] `commandsChanged` clears `state.last_result` + closes the menu.
- [ ] In-flight `getSuggestions` cancelled + `state.gen` bumped (a late stale cb is dropped).
- [ ] Re-query fires iff `was_open` + `buf` valid + `buf == current` (fresh request observable; menu reopens with new items on success).
- [ ] No re-query when the menu was closed (no fresh request).
- [ ] `state.buf` preserved (NOT nil after the call).
- [ ] Never throws (nil/wiped buf, absent bridge, no menu module); idempotent.
- [ ] Handler api-safe (runs on the nvim main loop via S27 `schedule_wrap`).

### Code Quality Validation
- [ ] Follows the existing lifecycle-fn pattern (`on_insert_leave`/`on_buf_leave`) + the supersession idiom (`do_refresh`/`force_fetch`).
- [ ] Reuses `cancel_timer()` (never stop-only); reads `bridge`/`menu` FRESH + pcall-wrapped.
- [ ] Registration mirrors `on_disconnect` exactly; placed AFTER `handshake()` (GOTCHA D).
- [ ] Luadoc on the new fn; `-- S41` mode marker; header note added.
- [ ] Anti-patterns avoided (see below).

### Documentation
- [ ] `-- S41` marker + luadoc explain the cache-invalidate + conditional re-query + the `was_open` choice.
- [ ] The empty-result non-refresh edge is documented (accepted minor; next keystroke fetches fresh).

---

## Anti-Patterns to Avoid

- ❌ Don't call `M.reset()` from `on_commands_changed` — it nils `state.buf` (the re-query needs it) and zeroes `gen`. Use a TARGETED invalidate.
- ❌ Don't zero `state.gen` — bump it (`state.gen = state.gen + 1`) so a late stale cb is dropped by the shared gen-guard idiom (matches `do_refresh`/`force_fetch`).
- ❌ Don't clear `last_result` and assume the menu clears — the menu holds its OWN items; MUST call `menu.close()` explicitly.
- ❌ Don't add a second `vim.schedule_wrap` inside `on_commands_changed` — S27 already wraps the handler at store time (double-wrap is harmless but redundant + signals a misunderstanding of the luv-fast-context fix).
- ❌ Don't use `vim.fn.mode()` as the "actively completing" guard — fiddly to drive in headless plenary; use `menu.is_open()` (captured before close).
- ❌ Don't register the handler BEFORE `br.handshake(…)` — `handshake()` runs `M.close()` which clears the registry (GOTCHA D). Register after, mirroring `on_disconnect`.
- ❌ Don't throw from `on_commands_changed` (out-of-band event) — pcall every external call (`menu.is_open`, `menu.close`, `bridge.cancel`, `M.refresh`).
- ❌ Don't unconditionally re-query — that pops a menu in NORMAL mode (the provider doesn't know vim mode). Guard on `was_open`.
- ❌ Don't touch the TS side — S17 emit + wire form are DONE; S41 is client-only.
- ❌ Don't pipe a heredoc into `nvim` stdin (AGENTS.md HARD RULE — it hangs). Write test snippets to a file.

---

## Confidence Score: 9/10

Pure additive client-only edit (1 new public fn + 1 registration block + tests) on a DONE
mechanism (S27) with an explicit, named downstream contract. The one design judgment call
(the `was_open` re-query guard) is well-justified + cleanly testable via the existing
`populated_menu` helper. Residual 1/10 = headless-plenary timing flakiness on the re-query
`vim.wait` (mitigated by the file's existing `wait_for` discipline + 200ms windows).