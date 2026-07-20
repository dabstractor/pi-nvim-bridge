---
name: "P2.M7.T18.S31 — menu.lua (the windowless menu-STATE module) + completion→menu population wiring (the S30 on_results seam consumer)"
description: |
  **CREATE `plugin/lua/pi-editor/menu.lua`** — a windowless menu-STATE module (the blink.cmp `list.lua` model: a pure-Lua singleton that stores the latest `{items, prefix, selected, open}` and routes the S30 `completion.on_results(buf, items, prefix)` seam) + **ADD a one-line no-op-safe `menu.attach()` call to the COMPLETE `init.lua` `activate()`** (the wiring locus — mirrors the existing `bridge.handshake` pcall). This is the DATA-CONSUMPTION half of completion: S30 (DONE) PRODUCES `on_results(buf, items, prefix)` (fires ONLY for the latest non-stale success via two-layer supersession); S31 CONSUMES it — registering the callback idempotently (`last-wins` overwrite, the cmp single-callback-seam pattern), routing empty-items→`close()` / non-empty→store+`open(items)`, and storing items+prefix+selected so the later **accept (S32)** reads them WITHOUT coupling to the window (`get_selected()`/`get_items()`/`get_prefix()` — blink's `list.accept()` reads state, not the popup). **S31 DOES NOT CREATE THE FLOATING WINDOW** — that is S34 (Planned). S31's `open()`/`close()` manage STATE ONLY and call a LOCAL no-op `render(state)` stub that S34 (window creation) / S35 (two-column rendering) / S36 (navigation: `next`/`prev`/`dismiss`) / S37 (auto-close) will implement. This makes S31 fully testable via STATE assertions (no `nvim_open_win` — exactly how nvim-cmp ships `source_spec.lua` but NO view spec). **CRITICAL REFINEMENT over the S31 contract's "guard against stale responses (if needed)":** LIVE-VERIFIED external research (blink.cmp `completion/init.lua` + nvim-cmp `source.lua`) shows NEITHER plugin re-guards staleness inside the menu layer — each guards ONCE at the source→consumer seam. S30's two-layer supersession (cancel + generation-id guard) ALREADY guarantees `on_results` fires ONLY for the latest request whose params matched the buffer at issue time; a consumer-side re-query of `nvim_win_get_cursor`/`nvim_buf_get_lines` to derive staleness is a **FALSE-NEGATIVE RACE** (the buffer may legitimately advance past the request position even for a valid latest result). So S31's `on_results` handler routes on the PAYLOAD ONLY and guards buf validity (`nvim_buf_is_valid`) — NO redundant staleness logic. **Scope (narrow):** S31 implements `menu.lua` (state + the `on_results` wiring + `attach`/`detach` + `open`/`close` + the `get_*` accessors + a no-op `render` seam + `reset`) + the ONE 2-line `activate()` wiring. It does NOT create the floating window (S34), render columns (S35), navigate (S36), auto-close on InsertLeave (S37), accept (S32), or Tab-force (S33). **`open(items)` signature matches the S34 contract** (`tasks.json` P2.M8.T21.S34: "Implement `M.open(items)`: … track selected index") so S34 ADDS the window to `open()` rather than rewrites it — `buf`+`prefix` are stored by the `on_results` handler BEFORE calling `open(items)`. **DELIVERABLES:** (1) CREATE `plugin/lua/pi-editor/menu.lua`; (2) MODIFY `plugin/lua/pi-editor/init.lua` `activate()` (add the `menu.attach()` pcall — the SOLE existing-file change, consistent with activate()'s existing `bridge.handshake` wiring role); (3) CREATE `plugin/tests/menu_spec.lua` (plenary/busted — state-only assertions + a full-flow case with real completion + a fake bridge, mirroring completion_spec's `fake_bridge` helper); (4) CREATE `plugin/tests/menu_smoke.lua` (plenary-free — fake luv server + real bridge + real completion + `menu.attach()`; refresh → getSuggestions → reply → assert menu populated, then empty reply → menu closed). **NON-REGRESSION:** the only existing file touched is `init.lua` (additive 2-line pcall, no-op-safe if menu.lua is absent — mirrors the bridge handshake pcall); all prior specs stay green.
---

## Goal

**Feature Goal**: Ship the **completion-result → menu-population** half of pi-editor.nvim — `menu.lua`, the
windowless menu-STATE module (the blink.cmp `list.lua` model) that consumes the S30 `completion.on_results(buf,
items, prefix)` seam. It registers the callback idempotently from `activate()`, routes empty→close / non-empty→
store+open, and stores `items`/`prefix`/`selected` so the later accept (S32) reads them via `get_selected()`/
`get_items()`/`get_prefix()` WITHOUT coupling to the floating window. S31 owns the STATE + the wiring + the no-op
render seam; S34 (window) / S35 (rendering) / S36 (navigation) / S37 (auto-close) plug into it additively.

**Deliverable** (2 NEW files + 1 MODIFIED file):
- **CREATE** `plugin/lua/pi-editor/menu.lua` — a singleton module (`local M = {}` + module-level `state` + `return
  M`, like `bridge.lua`/`completion.lua` NOT like the stateless `coords.lua`) exposing:
  - `M.attach()` — idempotent; if not already `attached`, `require("pi-editor.completion").on_results = M.on_results`;
    set `attached=true`. Never throws (pcall-wrapped).
  - `M.detach()` — if `attached`, restore the prior `on_results` (saved at first attach) and set `attached=false`.
  - `M.on_results(buf, items, prefix)` — THE handler (the S30→S31 seam consumer). Guards buf validity;
    `nvim_buf_is_valid`; stores `buf`+`prefix`; if `#items == 0` → `M.close()` else `M.open(items)`. Routes on the
    PAYLOAD ONLY — NO redundant staleness guard (S30's two-layer supersession already guarantees latest-only).
  - `M.open(items)` — store `items` (normalized array), `selected=1`, `open=true`; call `render(state)`. [S34 hook]
  - `M.close()` — `items={}`, `selected=0`, `open=false`; call `render(state)`. [S34 hook]
  - `M.get_selected()` — `items[selected]` or `nil` (for S32 accept).
  - `M.get_items()` — shallow copy of `items`. `M.get_prefix()`. `M.get_buf()`. `M.is_open()`. `M.has_items()`.
  - `M.reset()` — teardown: `close()` + `detach()` (if `attached`); idempotent + never throws (the cleanup seam
    for tests + the future S37 InsertLeave/CursorMoved-out wiring).
  - A LOCAL `render(state)` no-op stub (the S34 DI seam) called from `open()`/`close()`.
  - Module-level `[Mode A]` header documenting: role (the windowless menu-state consumer of S30's seam); the
    blink.cmp `list.lua` model + the cmp `source_spec`-vs-no-view-spec testability split; the last-wins-overwrite
    attach idiom; the NO-redundant-staleness-guard decision (cite the external research); the `open(items)` S34
    contract + the no-op render seam; the forward contracts (get_selected→S32, next/prev/dismiss→S36, auto-close→S37).
- **MODIFY** `plugin/lua/pi-editor/init.lua` — in `activate()`, AFTER the filetype set (so the refresh autocmds
  are wired) and alongside the `bridge.handshake` pcall, ADD (the SOLE existing-file change; no-op-safe if
  `menu.lua` is absent):
  ```lua
  pcall(function()
    local ok, menu = pcall(require, "pi-editor.menu")
    if ok and type(menu.attach) == "function" then menu.attach() end
  end)
  ```
- **CREATE** `plugin/tests/menu_spec.lua` — plenary/busted spec. State-only assertions (NO `nvim_open_win`).
  Includes a FULL-FLOW case using real `completion` + a `fake_bridge` (the completion_spec helper) +
  `menu.attach()` → `refresh` → resolve the cb → assert menu populated (proves the S30→S31 seam end-to-end
  without a socket).
- **CREATE** `plugin/tests/menu_smoke.lua` — plenary-free smoke. Fake luv unix-socket server (the
  bridge_request_spec `with_request_server` pattern) + real `bridge.handshake` + real `completion` +
  `menu.attach()`; set buffer lines `{"/mo"}`; `refresh`; server observes `getSuggestions`; server replies
  `{items={{value="/model",label="model"}}, prefix="/mo"}`; `vim.wait`; assert `menu.is_open()` + `get_items()[1].value=="/model"` +
  `get_selected().value=="/model"`. Then a 2nd reply with empty `items` → `menu.is_open()==false`. Then
  `menu.reset()`; `bridge.close()`; server stop. Prints `SMOKE_PASS` / exit 0.

> Reuses `plugin/tests/minimal_init.lua` (S19) unchanged. The ONLY existing file modified is `init.lua` (an
> additive 2-line no-op-safe pcall in `activate()`, mirroring the existing `bridge.handshake` pcall — `activate()`
> is the established session-wiring locus). No modification to `completion.lua` (DONE S30 — its `on_results` slot
> is the seam S31 consumes), `bridge.lua`, `coords.lua`, `jsonlreader.lua`, the ftplugin, or the shim.

**Success Definition** (every assertion is directly testable via state fields — NO window):
- **`attach()` wires the seam idempotently**: after `menu.attach()`, `completion.on_results == menu.on_results`
  (function-equal). A second `attach()` is a no-op (does not re-save `prev_on_results` — the `attached` flag guards it).
- **`on_results(buf, items, prefix)` routes correctly**: non-empty `items` → `open()` → `is_open()==true`,
  `get_selected()==items[1]`, `get_items()` is a shallow copy of `items`, `get_prefix()==prefix`, `get_buf()==buf`;
  empty `items` (or a non-table `items`) → `close()` → `is_open()==false`, `selected==0`.
- **`open(items)` is S34-compatible**: signature is `open(items)` (items-only — `buf`+`prefix` stored by `on_results`);
  `selected==1` after open (1-indexed — matches the S36 `next`/`prev` wraparound + `get_selected`).
- **NO floating window in S31**: `menu.lua` makes ZERO `nvim_open_win`/`nvim_create_buf` calls (the no-op `render`
  stub is the only thing `open()`/`close()` call besides state writes).
- **NO redundant staleness guard**: `on_results` does NOT call `nvim_win_get_cursor`/`nvim_buf_get_lines` to derive
  staleness — it routes on the payload (`buf`/`items`/`prefix` are cb args) + an `nvim_buf_is_valid(buf)` guard only.
  (S30's two-layer supersession already guarantees latest-only — external-research-verified.)
- **Full flow with real completion + fake bridge**: `menu.attach()` → `completion.refresh(buf)` → fake bridge's
  `getSuggestions` cb resolved with `{items, prefix}` → `menu.is_open()` + `get_items()` matches + `get_selected()`.
- **`detach()` restores** the prior `on_results` (or `nil`); `attached==false`.
- **`reset()` is idempotent + never throws**, closes + detaches, clears state (the cleanup seam for S37/tests).
- **Never-throws** on bad args (non-number `buf`, wiped buf, nil `items`); never-throws when completion is absent.
- Non-regression: all prior specs (init/shim/activate/ftplugin/jsonlreader/bridge/handshake/request/notify/coords/
  completion) still pass unchanged.

## User Persona (if applicable)

**Target User**: A pi user typing a prompt (`/mod…`, `@src/comp…`, `./path/…`) in the Neovim external editor. They
never see this code; they experience it as "the completion menu holds the right items for what I just typed, the
first item is pre-selected, and the menu never flashes stale suggestions or empty-flickers on a slow `@file` fetch."
(The menu WINDOW itself is S34 — S31 is the state layer underneath it. Until S34 lands the user sees no popup, but
the data path `completion → menu` is live and tested.)

**Use Case**: The data-consumption half of the completion pipeline. Activation (S21) → buffer (S22) → bridge
transport+handshake+RPC (S24–S27, COMPLETE) → coords (S28/S29, COMPLETE) → S30 (refresh→debounce→fetch→supersede→
**on_results seam**, COMPLETE) → **S31 (this: on_results → menu state population)** → S32 (accept reads
`get_selected()`) → S33 (Tab-force) → S34+ (floating window renders the state). Without S31, S30's `on_results`
slot stays nil → no consumer → the fetch results vanish. S31 makes them land in a testable state layer.

**Pain Points Addressed**:
1. **No consumer for completion data**: S30 ships a producer (`on_results`) but no consumer. S31 closes the loop,
   storing items+prefix+selected so accept (S32) and the window (S34) have something to render/apply.
2. **State vs rendering coupling**: a naive menu.lua would fuse state + window (nvim-cmp's `custom_entries_view`
   does — the anti-pattern). S31 mirrors blink.cmp's `list.lua`: a windowless state module the window SUBSCRIBES to.
   This makes the data path testable NOW (S34 is Planned) and keeps accept (S32) window-free.
3. **Flicker on slow fetches**: the NO-redundant-staleness-guard decision (trust S30's supersession) avoids the
   false-negative race where a consumer wrongly drops a valid latest result (the buffer legitimately advanced).

## Why

- **PRD §7.4 (Triggers) + §7.5 (menu.lua)** is the requirement source. §7.4: "as the user types, the plugin sends
  `getSuggestions` … The plugin renders the items in a floating menu." §7.5: "Rendered from `items`: two columns —
  `label` (left) and `description` (right)." S31 is the STATE layer between "the items arrived" (S30) and "render
  the items in a window" (S34/S35) — the blink.cmp `list.lua` split that keeps data-testable apart from rendering.
- **The S31 task contract** (`tasks.json`): "LOGIC: In the getSuggestions callback: (a) if result is null or
  result.items is empty → close/hide menu, (b) store `current_items` and `current_prefix`, (c) call `menu.open(result.items)`."
  S30 ALREADY does the null→empty normalization (its cb normalizes a null result to `{items={}, prefix=""}` BEFORE
  firing `on_results`); S31 owns (a) the empty→close routing, (b) the store, (c) the `open(items)` call + the menu
  module skeleton.
- **The blink.cmp `list.lua` model is the blueprint** (external research): a pure-Lua windowless singleton with
  `items`/`selected_item_idx`/`context` fields, a `show()` that routes empty→`hide_emitter:emit` / non-empty→store+
  `show_emitter:emit`, and an `accept()` that reads selection DIRECTLY from state (zero window coupling). nvim-cmp
  FUSES state+window in `custom_entries_view` — the anti-pattern; model on blink.
- **No redundant staleness guard — LIVE-VERIFIED**: blink guards ONCE at the scheduled seam
  (`event.context.id ~= trigger.context.id` in `completion/init.lua` L34-58), then `list.show` trusts it; cmp
  guards ONCE in `source.lua` (`if self.context ~= ctx then return end`), then the view pulls fresh. NEITHER
  re-guards inside the menu. S30's two-layer supersession IS that one guard. A consumer re-query races.
- **Last-wins overwrite for a single forward-contract slot**: cmp's single-callback seams (`source:complete(ctx,
  callback)`) are a bare closure overwrite; multi-listener `table.insert` is only for pub/sub emitters (multiple
  consumers). S31's `on_results` is a single contract → last-wins overwrite, idempotent via an `attached` flag.
- **Leaf + mostly additive.** S31's only upstream dependency that is COMPLETE is S30 (`on_results`/`reset`/`current`)
  + S19 (`activate()`, the wiring locus). It is the upstream dependency of S32 (`get_selected()`/`get_prefix()`) /
  S34 (the `render` seam + `open(items)`) / S36 (`next`/`prev`/`dismiss` set `selected` + call `render`) / S37
  (`reset()`/`close()`). The only existing file touched is `init.lua` (additive 2-line pcall).

## What

A singleton Lua module `plugin/lua/pi-editor/menu.lua` (windowless menu-STATE) + a 2-line `activate()` wiring. Public
surface: `attach()`, `detach()`, `on_results(buf, items, prefix)`, `open(items)`, `close()`, `get_selected()`,
`get_items()`, `get_prefix()`, `get_buf()`, `is_open()`, `has_items()`, `reset()`. Internal: a local no-op
`render(state)` (the S34 seam). Pipeline:

```lua
-- activate() [MODIFIED init.lua]: filetype set → fires ftplugin (refresh autocmds) → menu.attach() (this task) +
--                                    bridge.handshake (existing). attach() sets completion.on_results = M.on_results.
-- completion.refresh(buf) [S30, DONE]: debounce → fetch → supersede → on success fires M.on_results(buf, items, prefix)
-- M.on_results(buf, items, prefix):
--   if not nvim_buf_is_valid(buf) then return end        -- a wiped buffer during the debounce
--   state.buf = buf; state.prefix = (type(prefix)=="string") and prefix or ""
--   items = (type(items)=="table") and items or {}
--   if #items == 0 then M.close() else M.open(items) end
-- M.open(items):  state.items = items; state.selected = 1; state.open = true; render(state)   -- render = no-op (S34 hook)
-- M.close():      state.items = {}; state.selected = 0; state.open = false; render(state)     -- render = no-op (S34 hook)
```

### Success Criteria

- [ ] `menu.attach`, `menu.detach`, `menu.on_results`, `menu.open`, `menu.close`, `menu.get_selected`,
      `menu.get_items`, `menu.get_prefix`, `menu.get_buf`, `menu.is_open`, `menu.has_items`, `menu.reset` are all
      `function`s.
- [ ] `attach()` sets `completion.on_results` to `menu.on_results` (function-equal); idempotent (2nd attach no-op).
- [ ] `on_results(buf, items, prefix)` with non-empty `items` → `open()` → `is_open()==true`, `selected==1`,
      `get_selected()==items[1]`, `get_items()` shallow-copy == items, `get_prefix()==prefix`, `get_buf()==buf`.
- [ ] `on_results(buf, {}, prefix)` or `on_results(buf, nil, prefix)` → `close()` → `is_open()==false`, `selected==0`.
- [ ] `open(items)` signature is items-only (S34-compatible); `selected==1` after open (1-indexed).
- [ ] NO `nvim_open_win`/`nvim_create_buf`/`nvim_buf_set_lines` calls in `menu.lua` (the no-op `render` stub only).
- [ ] `on_results` does NOT call `nvim_win_get_cursor`/`nvim_buf_get_lines` (no redundant staleness guard); it
      routes on the payload + `nvim_buf_is_valid(buf)` only.
- [ ] `detach()` restores the prior `on_results` (or nil); `attached==false`.
- [ ] `reset()` idempotent + never-throws; closes + detaches + clears state (`is_open()==false`, `items=={}`, etc.).
- [ ] Full flow (real completion + fake bridge): `attach()` → `refresh(buf)` → resolve getSuggestions cb with
      `{items, prefix}` → `is_open()` + `get_items()` + `get_selected()` reflect the payload.
- [ ] Never-throws on bad args (`on_results(nil,...)`, `on_results(buf, "x", nil)`, wiped buf) + when completion absent.
- [ ] Non-regression: all prior specs green; the init.lua change is additive (a 2-line no-op-safe pcall).

## All Needed Context

### Context Completeness Check

_If someone knew nothing about this codebase, would they have everything needed to implement this successfully?_
**YES** — every upstream dependency is COMPLETE and in-tree with exhaustive headers + PRPs: the S30 `on_results`
seam (firing ONLY the latest non-stale success on the api-safe main loop, with null→empty normalization), the
`activate()` wiring locus (its existing filetype-set + bridge.handshake pcall pattern to mirror), the bridge
fake-helper test style (completion_spec's `fake_bridge`), the smoke's `with_request_server` pattern, and the
external research (blink.cmp `list.lua` model + the no-redundant-staleness-guard verdict + the last-wins-overwrite
attach idiom). The implementer reads these, writes 2 new files + adds 2 lines to `init.lua`, and runs the verified
test commands. No guessing; no external research required (all references in-tree + the research files + 3 GitHub
permalinks).

### Documentation & References

```yaml
# MUST READ - Include these in your context window
- url: https://github.com/Saghen/blink.cmp/blob/78336bc89ee5365633bcf754d93df01678b5c08f/lua/blink/cmp/completion/list.lua#L90-L120
  why: "THE blueprint for menu.lua — blink.cmp's windowless menu-STATE singleton. list.show() does EXACTLY the S31
        routing: store items in state; if #items==0 then hide_emitter:emit (close) else store+show_emitter:emit
        (open). Fields: context, items={}, selected_item_idx."
  critical: "blink SEPARATES state (list.lua, windowless) from window (windows/menu.lua, a DOWNSTREAM SUBSCRIBER).
             list.accept() (line ~359) reads selection DIRECTLY from state: `local item = list.items[opts.index or
             list.selected_item_idx]` — ZERO window coupling. This is the S31 model. nvim-cmp FUSES state+window in
             custom_entries_view.lua — the anti-pattern; do NOT copy cmp."

- url: https://github.com/Saghen/blink.cmp/blob/78336bc89ee5365633bcf754d93df01678b5c08f/lua/blink/cmp/completion/init.lua#L27-L58
  why: "THE two-layer-supersession seam (blink's source→consumer boundary). `sources.completions_emitter:on(
        function(event) vim.schedule(function() if event.context.id ~= trigger.context.id then return end ... list.show(...)
        end) end)` — guards ONCE at the seam, then list.show TRUSTS it (no re-check). This is why S31 needs NO
        redundant staleness guard: S30's on_results IS the seam (latest-only by gen-guard)."
  critical: "Re-guaranteeing staleness inside the consumer by re-reading nvim_win_get_cursor/nvim_buf_get_lines is a
             FALSE-NEGATIVE RACE (the buffer may legitimately advance past the request position for a valid latest
             result). S31 routes on the PAYLOAD ONLY + nvim_buf_is_valid(buf)."

- url: https://github.com/hrsh7th/nvim-cmp/blob/2ffe79f1f021def8dd1fcd81deb16f1bb0d989f3/lua/cmp/source_spec.lua
  why: "THE state-testability template. cmp ships busted specs for the DATA/state layers (source/core/entry/matcher/
        context_spec) and NO spec for view.lua/custom_entries_view — the window layer is untested at unit level
        because it needs nvim_open_win. S31 mirrors this: state-only assertions (items/selected/is_open), no window."
  pattern: "Stub the producer (fake bridge) + assert on state fields. `it('...', function() s:complete(input, cb);
            assert.is.truthy(...) end)` shape. S31's menu_spec asserts on menu.is_open()/get_items()/get_selected()
            with NO nvim_open_win."

- file: plugin/lua/pi-editor/completion.lua
  why: "THE seam S31 consumes. Read its [Mode A] header (esp. the on_results section) + do_refresh's cb (lines firing
        M.on_results). S30's cb: if gen~=state.gen return (STALE dropped); if err return (touch nothing); normalize
        null→{items={},prefix=""}; store last_result; `if type(M.on_results)=='function' then pcall(M.on_results,
        buf, items, prefix) end`. S31 REGISTERS that slot."
  pattern: "M.on_results is a SETTABLE nil slot (last-wins — a Lua table set). It fires ONLY for the latest non-stale
            success, on the nvim MAIN LOOP (the bridge cb is schedule_wrap'd S26 → on_results is api-safe). S31's
            handler may read nvim state (it needs only the payload + nvim_buf_is_valid)."
  gotcha: "S30 already NORMALIZES a null getSuggestions result to {items={}, prefix=''} BEFORE firing on_results — so
           S31's on_results handler ALWAYS receives a valid `items` array (possibly empty). Do NOT re-normalize null
           (no `result==vim.NIL` handling — that's the bridge's job, DONE). The empty-items branch IS the hide path."

- file: plugin/lua/pi-editor/init.lua
  why: "THE wiring locus S31 modifies. Read M.activate() (S21): it sets filetype (fires ftplugin → refresh autocmds)
        + pcall-requires bridge + calls br.handshake(desc, cb) (sets pi.bridge on success). S31 ADDS the mirror-line
        for menu.attach() AFTER the filetype set + alongside the bridge handshake pcall."
  pattern: "The EXACT pattern to mirror (the existing bridge handshake pcall in activate()): `pcall(function() local
            ok, br = pcall(require, 'pi-editor.bridge'); if ok and type(br.handshake)=='function' then
            br.handshake(desc, function() end) end end)`. S31's menu.attach() pcall is identical in shape."
  gotcha: "menu.attach() is safe to call BEFORE the bridge connects — completion.refresh degrades silently when
           pi.bridge is nil (no fetch → no on_results). And it is idempotent (the `attached` flag), so a /reload that
           re-runs activate() does not stack. Place the pcall AFTER `vim.bo[buf].filetype = 'pi-prompt'` (so the
           ftplugin's refresh autocmds exist) — but it works either way."

- file: plugin/lua/pi-editor/bridge.lua
  why: "The module whose request()/cancel()/is_connected() S30 calls (S31 does NOT call the bridge directly — it
        consumes S30's seam). Read its [Mode A] S26/S27 EXTENSION blocks for the cb(err,result) contract +
        on_notification(method,handler) — S31's attach()/detach() mirror on_notification's last-wins registration
        pattern (a Lua table set; nil removes)."
  pattern: "Singleton module shape (local M = {} + module-level state + return M) — menu.lua mirrors this NOT coords's
            stateless shape (menu HAS state). M.on_notification stores a schedule_wrap'd handler; M.attach stores a
            RAW fn (on_results is already api-safe — S30 fires it on the main loop)."
  gotcha: "Do NOT schedule_wrap M.on_results in attach() — S30 already fires it on the main loop (the bridge cb is
           schedule_wrap'd; on_results is called inline from completion's cb which runs via vim.defer_fn = main loop).
           Double-wrapping adds a needless hop + would delay the store."

- file: plugin/tests/completion_spec.lua
  why: "THE test style S31's menu_spec mirrors. Read its `fake_bridge(opts)` helper (controllable request/cancel/
        is_connected + resolve(i,err,result)/resolve_last) — S31's full-flow case REUSES this exact helper to drive
        real completion + assert menu state. Read its `reset()` before_each/after_each + the vim.wait(ms,predicate,5)
        async idiom + the `win`/`nvim_win_set_buf`/`virtualedit=onemore` buffer-cursor setup."
  pattern: "local fake = fake_bridge(); pi.bridge = fake; local buf = nvim_create_buf(...); set_lines({'/mo'});
            nvim_win_set_buf(win, buf); nvim_win_set_cursor(win, {1, col}); completion.refresh(buf); wait_for(200,
            function() return #fake.requests>=1 end); fake.resolve_last(nil, {items=..., prefix=...}); wait_for(...);
            assert. Do NOT name a spec-local table `pending` (shadows plenary's skip fn)."

- file: plugin/tests/bridge_request_spec.lua
  why: "THE smoke's fake-server pattern. Read its `with_request_server` body (bind a unique unix socket path, spin a
        luv server, handshake, echo hello + capture a request, reply) — S31's menu_smoke reuses it to drive real
        bridge + completion + menu.attach() and assert menu state from a server reply."
  pattern: "uv.new_tcp/new_pipe? NO — unix socket: the bridge connects via uv.new_pipe to descriptor.path. The smoke
            binds a server on a unique tmp path, accepts the connection, reads the hello (jsonlreader), replies with
            a hello result, then captures the getSuggestions request + replies with {items, prefix}."

- file: plugin/tests/coords_spec.lua + plugin/tests/coords_smoke.lua
  why: "THE plenary spec + plenary-free smoke footer style for a NEW module. Mirror coords_spec's
        describe/it/assert.are.equals structure + coords_smoke's `check`/`fails`/`cquit`/`SMOKE_PASS` footer. S31's
        menu_spec + menu_smoke are SIBLINGS of these (new files, not appends)."
  pattern: "describe('pi-editor.menu', function() before_each(reset) ... end); the smoke's trailing
            `if fails>0 then cquit 1 end; io.stdout:write('SMOKE_PASS\\n')`."

- file: plan/001_c56962b4fa17/P2M7T18S31/research/notes.md
  why: "THE consolidated research (this task). §1 (the S30 seam contract); §2 (blink list.lua model + permalinks);
        §3 (last-wins-overwrite attach); §4 (NO redundant staleness guard — the false-negative race); §5 (render
        seam / testability); §6 (the activate() wiring locus); §7 (S34/S35/S36/S37 forward-compat — open(items)
        signature + selected=1 + no-op render seam); §8 (gotchas); §9 (test strategy)."
  section: "all; esp. §1, §2, §4, §6, §7."

- docfile: PRD.md
  why: "§7.4 (the completion flow — 'the plugin renders the items in a floating menu') + §7.5 (menu.lua — 'Rendered
        from items: two columns label/description') + §11 (one pi-prompt buffer per session). S31 is the STATE layer
        beneath §7.5's window; the window is S34."
  section: "§7.4 (heading:h3.20); §7.5 (heading:h3.21); §5.4 (AutocompleteItem {value,label,description?})"
  gotcha: "PRD §7.5 describes the WINDOW (floating popup, two columns, keys) — that is S34/S35/S36. S31 is ONLY the
           STATE + the on_results wiring + the no-op render seam. Do NOT implement nvim_open_win/columns/navigation."
```

### Current Codebase tree (run `tree` in the root of the project) to get an overview of the codebase

```bash
$ cd /home/dustin/projects/pi-nvim-bridge && tree -L 3 plugin plan/001_c56962b4fa17/architecture plan/001_c56962b4fa17/P2M7T18S3*
plugin
├── ftplugin/pi-prompt.lua                 # buffer-local setup (S22, COMPLETE) — refresh autocmds (→ completion.refresh) + 6 keymaps (→ completion.on_*, fall-through) + autosave (→ bridge.on_exit)
├── lua/pi-editor/
│   ├── bridge.lua                         # socket client + handshake + RPC (S24-S27, COMPLETE) — request/cancel/is_connected/on_notification
│   ├── completion.lua                     # per-keystroke TRIGGER (S30, COMPLETE) — refresh/debounce/fetch/supersede + the on_results seam S31 consumes
│   ├── coords.lua                         # nvim_to_pi_coords / pi_to_nvim_coords (S28/S29, COMPLETE)
│   ├── init.lua                           # setup() + VimEnter gate + activate() (S19-S21, COMPLETE) — S31 ADDS the menu.attach() pcall here
│   └── jsonlreader.lua                    # JSONL framing (S23, COMPLETE)
├── plugin/pi-editor.lua                   # VimEnter auto-activation shim (S20, COMPLETE)
└── tests/
    ├── minimal_init.lua                   # plenary harness (S19; reused UNCHANGED)
    ├── completion_spec.lua                # the fake_bridge helper + full-flow async style (S31 menu_spec MIRRORS this)
    ├── completion_smoke.lua               # plenary-free smoke style (S31 menu_smoke MIRRORS this)
    ├── bridge_request_spec.lua            # with_request_server fake-server pattern (S31 menu_smoke REUSES this)
    ├── coords_spec.lua + coords_smoke.lua # NEW-module spec/smoke footer style (S31 siblings these)
    └── … (init/shim/activate/ftplugin/jsonlreader/bridge/handshake/notify/coords specs + smokes — all COMPLETE)
plan/001_c56962b4fa17/architecture/
├── external_deps.md                       # §1.3 (Floating Window menu.lua — the S34 API S31 leaves as a no-op render seam) + §1.2/§1.6 (cursor/autocmd APIs)
└── … (research-pi-autocomplete/extension-api, system_context)
plan/001_c56962b4fa17/P2M7T18S31/research/
└── notes.md                               # THE consolidated research for this task (blink list.lua model; no-redundant-staleness; activate() wiring; S34 forward-compat)
```

### Desired Codebase tree with files to be added and responsibility of file

```bash
plugin/lua/pi-editor/menu.lua              # NEW — windowless menu-STATE singleton: attach/detach (the on_results wiring) + on_results handler (empty→close / non-empty→store+open) + open(items)/close() + get_selected/get_items/get_prefix/get_buf/is_open/has_items + reset + a LOCAL no-op render(state) seam for S34
plugin/tests/menu_spec.lua                 # NEW — plenary/busted; state-only assertions (no window) + a full-flow case (real completion + fake bridge + attach → refresh → resolve → menu populated)
plugin/tests/menu_smoke.lua                # NEW — plenary-free; fake luv server + real bridge + real completion + attach; refresh → getSuggestions reply → menu populated; empty reply → menu closed
# (ONE existing file MODIFIED: plugin/lua/pi-editor/init.lua — activate() gains the 2-line no-op-safe menu.attach() pcall, mirroring the existing bridge.handshake pcall.)
```

### Known Gotchas of our codebase & Library Quirks

```lua
-- CRITICAL: S31 is the STATE layer, NOT the window. menu.lua makes ZERO nvim_open_win/nvim_create_buf/
-- nvim_buf_set_lines calls. open()/close() manage state (items/selected/open) + call a LOCAL no-op render(state)
-- stub. S34 implements render() to create the floating window; S35 enhances it to two-column rendering. This is the
-- blink.cmp list.lua split (state ≠ window) — NOT the nvim-cmp custom_entries_view fusion. (research/notes.md §2/§5.)

-- CRITICAL: NO redundant staleness guard in the consumer. S30's two-layer supersession (cancel + generation-id
-- guard) ALREADY guarantees on_results fires ONLY for the latest non-stale success whose params matched the buffer
-- at issue time; a newer keystroke bumps gen → the prior result is dropped at S30's gen-guard. Re-deriving staleness
-- in the menu by re-reading nvim_win_get_cursor/nvim_buf_get_lines is a FALSE-NEGATIVE RACE (the buffer may
-- legitimately advance past the request position for a valid latest result — verified in blink/cmp). on_results
-- routes on the PAYLOAD ONLY (buf/items/prefix are cb args) + an nvim_buf_is_valid(buf) guard. (research §4.)

-- CRITICAL: last-wins OVERWRITE for the single on_results slot, NOT save-and-restore-a-list. cmp's single-callback
-- seams (source:complete(ctx, callback)) are a bare closure overwrite; multi-listener table.insert is only for
-- pub/sub emitters (multiple consumers). S31's on_results is a single forward contract → `completion.on_results =
-- M.on_results`. Idempotency via a module `attached` flag (2nd attach() is a no-op — does NOT re-save prev_on_results).
-- detach() restores the prior on_results saved at the FIRST attach (or nil). (research §3.)

-- CRITICAL: S30 already NORMALIZES a null getSuggestions result to {items={}, prefix=''} BEFORE firing on_results
-- (completion.lua do_refresh cb). So S31's on_results handler ALWAYS receives a valid `items` array (possibly empty)
-- + a string `prefix`. Do NOT handle `result==vim.NIL` or nil result (that's the bridge's job, DONE S26). The
-- empty-items branch (#items==0) IS the hide/close path.

-- CRITICAL: do NOT schedule_wrap M.on_results in attach(). S30 fires on_results on the nvim MAIN LOOP (the bridge
-- cb is schedule_wrap'd S26; completion's cb runs via vim.defer_fn = main loop). Storing a RAW fn (not wrapped) is
-- correct + avoids a needless hop. (bridge.lua's on_notification DOES wrap — because dispatch runs inline from the
-- luv read_start cb; S30's on_results does NOT — it's already on the main loop.)

-- CRITICAL: `open(items)` signature is ITEMS-ONLY (matches the S34 contract: tasks.json P2.M8.T21.S34 "Implement
-- M.open(items): … track selected index"). buf + prefix are stored by the on_results handler BEFORE calling
-- open(items), via state.buf/state.prefix. Accept (S32) reads them via get_buf()/get_prefix() + get_selected().
-- Do NOT change open()'s signature to open(buf, items, prefix) — it would collide with S34.

-- CRITICAL: selected = 1 after open() (1-INDEXED). Matches the S36 next/prev wraparound arithmetic
-- (`selected = (selected % #items) + 1` for next; `selected = (selected - 2 + #items) % #items + 1` for prev) +
-- get_selected() returning items[selected]. close() resets selected to 0 (no selection).

-- CRITICAL: render is a LOCAL no-op stub (NOT a public M._render override). open()/close() call `render(state)`.
-- S34 will EDIT menu.lua to implement render() (nvim_create_buf + nvim_open_win); S35 enhances it; S36's
-- next/prev/dismiss set selected + call render(); S37's auto-close calls close()/reset(). Keeping render a LOCAL
-- fn (not M._render) keeps the public surface minimal + signals "S34 owns this" clearly.

-- READ completion FRESH at call time inside attach(): `require("pi-editor.completion").on_results = M.on_results`.
-- (Same codebase rule as S30's bridge-read-fresh — the handshake resolves async + tests swap fakes after require.)
-- Do NOT cache completion at module load.

-- BUFFER VALIDITY GUARD: a buffer-local autocmd only fires when buf is current, but a wipe during the 25ms debounce
-- is possible. on_results must guard `if not vim.api.nvim_buf_is_valid(buf) then return end` (silent — never throw).
-- (This is the ONLY nvim-state read in on_results; it's the staleness-free validity check, NOT a staleness re-derive.)

-- NEVER THROWS (per-keystroke + autocmd contract): attach/detach/on_results/open/close/reset/get_* are all pcall-safe
-- by construction (type-guards + nvim_buf_is_valid). A missing/disconnected bridge = silent degrade (S30's refresh
-- bails when pi.bridge is nil → on_results never fires). A programming error in the menu must not abort the autocmd
-- chain (the ftplugin's dispatch is already pcall-wrapped, but be defensive).

-- SINGLETON STATE (like bridge.lua/completion.lua, NOT like coords.lua): one `state` table (attached,
-- prev_on_results, buf, items, prefix, selected, open) + `local M = {}`. Do NOT make it instance-based (one
-- pi-prompt buffer per session — PRD §11). reset() clears state + detaches for tests + the future S37 wiring.

-- DO NOT implement next/prev/dismiss/navigate — those are S36. S31 implements open/close/get_*/reset ONLY. The
-- ftplugin's keymap dispatch (on_next/on_prev/on_dismiss) returns false for the absent ones → feedkey fall-through
-- (C-N/C-P/C-E do nothing special) — that is CORRECT for S31's scope. Implementing them here collides with S36.

-- DO NOT implement accept (applyCompletion) — that is S32. S31 only EXPOSES get_selected()/get_items()/get_prefix()
-- so S32 can READ the state. S32 will call bridge.request('applyCompletion', {lines, cursorLine, cursorCol,
-- item=get_selected(), prefix=get_prefix()}, cb).

-- DO NOT modify completion.lua, bridge.lua, coords.lua, jsonlreader.lua, the ftplugin, or the shim. S31's only
-- existing-file change is init.lua activate() (the additive 2-line menu.attach() pcall). completion.lua's on_results
-- slot is the DONE seam S31 consumes — touching it would risk non-regression + is out of scope.
```

## Implementation Blueprint

### Data models and structure

Module-level singleton state (mirrors `bridge.lua`/`completion.lua`'s `state` shape, NOT `coords.lua`'s stateless
shape — menu HAS state):

```lua
--- A pi completion item (mirror of the extension's AutocompleteItem; the bridge delivers these as the
--- `result.items` array of a successful `getSuggestions` — passed through S30's on_results). Opaque to S31 —
--- S31 stores + forwards the array; S34 renders it, S32 applies it. Fields typed loosely (the exact shape is the
--- extension's protocol; S31 is shape-agnostic — same as S30's note).
---@class pi-editor.AutocompleteItem
---@field value string The text to insert on accept (the canonical value).
---@field label string Human-readable label shown in the menu.
---@field [string] any Extra fields the extension includes (e.g. description, kind, filterText).

--- Singleton menu-state (the blink.cmp list.lua model — a windowless pure-Lua singleton). One pi-prompt buffer per
--- session (PRD §11). Cleared by `reset()`. Mirrors bridge.lua/completion.lua's `state` shape (menu HAS state).
--- The floating WINDOW (win/menu_buf handles) are FORWARD-CONTRACT fields left nil until S34 implements render().
---@class pi-editor.MenuState
---@field attached        boolean             Whether `completion.on_results` is currently wired to M.on_results.
---@field prev_on_results function|nil        The on_results value saved at the FIRST attach (restored by detach).
---@field buf             integer|nil         The pi-prompt buffer handle of the latest on_results (for get_buf/S32).
---@field items           pi-editor.AutocompleteItem[]  The latest items array (1-indexed; {} when closed).
---@field prefix          string              The latest prefix (for get_prefix/S32 applyCompletion).
---@field selected        integer             1-indexed selected row; 1 after open(), 0 when closed/empty.
---@field open            boolean             Whether the menu is showing (true after open() with items).
---@field win             integer|nil         FORWARD CONTRACT (S34): the floating window handle. nil until S34.
---@field menu_buf        integer|nil         FORWARD CONTRACT (S34): the scratch buffer handle. nil until S34.
---@type pi-editor.MenuState
local state = {
  attached = false,
  prev_on_results = nil,
  buf = nil,
  items = {},
  prefix = "",
  selected = 0,
  open = false,
  win = nil,
  menu_buf = nil,
}
```

Public surface (LuaCATS — match bridge.lua/completion.lua's annotation density):

```lua
--- The S30→S31 seam consumer. Set onto `completion.on_results` by attach(). Routes the latest non-stale
--- {items, prefix}: empty → close(); non-empty → store context + open(items). TRUSTS S30's two-layer supersession
--- (no redundant staleness guard — research/notes.md §4). Called on the nvim main loop (api-safe). Never throws.
---@param buf    integer                      The pi-prompt buffer handle (from S30's on_results).
---@param items  pi-editor.AutocompleteItem[] The completion items (possibly empty — S30 normalized null→{}).
---@param prefix string                       The completion prefix (for get_prefix/S32).
function M.on_results(buf, items, prefix) ... end

--- Idempotently register M.on_results on `require("pi-editor.completion").on_results` (last-wins overwrite).
--- Guarded by `state.attached` so a 2nd attach() (e.g. a /reload re-running activate()) is a no-op. Never throws.
function M.attach() ... end

--- Restore the prior `completion.on_results` (saved at the FIRST attach, or nil); set attached=false. Never throws.
function M.detach() ... end

--- Store items + set selected=1 + open=true; call render(state). The STATE half of S34's M.open(items) — S34 ADDS
--- the floating window (render()). signature is items-only (matches the S34 contract; buf+prefix stored by on_results).
---@param items pi-editor.AutocompleteItem[] The items to display (non-empty — on_results guards empty→close).
function M.open(items) ... end

--- Clear items + selected=0 + open=false; call render(state). The STATE half of S34's close — S34 ADDS nvim_win_close.
function M.close() ... end

--- The selected item (items[selected]), or nil. For S32 accept to read WITHOUT coupling to the window (blink list.accept).
---@return pi-editor.AutocompleteItem|nil
function M.get_selected() ... end

--- Shallow copy of items (the caller may not mutate state.items). For S34 rendering / S32.
---@return pi-editor.AutocompleteItem[]
function M.get_items() ... end

--- The latest prefix (for S32 applyCompletion's `prefix` param).
---@return string
function M.get_prefix() ... end

--- The latest pi-prompt buffer handle (for S32 to read lines/convert coords).
---@return integer|nil
function M.get_buf() ... end

--- Whether the menu is showing (open==true). For S36/S37/the ftplugin keymap dispatch.
---@return boolean
function M.is_open() ... end

--- Whether there are items to show (#items > 0). For S33 Tab-force / S32 accept gating.
---@return boolean
function M.has_items() ... end

--- Teardown: close() + detach() (if attached); clear state. Idempotent + never throws. The cleanup seam for tests +
--- the future S37 InsertLeave/CursorMoved-out wiring. Mirrors completion.reset()/bridge.close().
function M.reset() ... end
```

### Implementation Tasks (ordered by dependencies)

```yaml
Task 1: READ (do NOT edit yet) — anchor on the COMPLETE seam + the blink model + the test style
  - READ: plugin/lua/pi-editor/completion.lua  (the [Mode A] header esp. the on_results section; do_refresh's cb —
      the lines `if type(M.on_results)=='function' then pcall(M.on_results, buf, items, prefix) end`; M.on_results
      is a settable nil slot; confirm S30 ALREADY normalizes null→{items={},prefix=''} BEFORE firing)
  - READ: plugin/lua/pi-editor/init.lua  (M.activate() — the filetype set + the EXISTING bridge.handshake pcall to
      mirror; confirm the wiring locus)
  - READ: plugin/lua/pi-editor/bridge.lua  (the [Mode A] S26/S27 blocks for the singleton-module shape +
      on_notification's last-wins registration pattern; M.on_notification stores schedule_wrap'd — S31 stores RAW
      because on_results is already api-safe)
  - READ: plugin/tests/completion_spec.lua  (the fake_bridge(opts) helper + resolve/resolve_last + the win/buffer/
      cursor setup + vim.wait idiom — S31's full-flow case REUSES this)
  - READ: plugin/tests/bridge_request_spec.lua  (the with_request_server fake-server body — S31's smoke reuses it)
  - READ: plugin/tests/coords_spec.lua + plugin/tests/coords_smoke.lua  (the NEW-module spec/smoke footer style)
  - READ: plan/001_c56962b4fa17/P2M7T18S31/research/notes.md  (★ the blink list.lua model; no-redundant-staleness;
      activate() wiring; S34 forward-compat — open(items) + selected=1 + no-op render seam)
  - READ: plan/001_c56962b4fa17/architecture/external_deps.md §1.3  (the Floating Window menu.lua API — the S34
      render() S31 leaves as a no-op stub)
  - WHY: locks the contract (on_results fires latest-only + null-normalized + api-safe; last-wins overwrite attach;
      open(items) S34-compatible; no-op render seam; the test discipline) before writing.

Task 2: CREATE plugin/lua/pi-editor/menu.lua — the module skeleton + [Mode A] header + state
  - CREATE: `local M = {}` + the singleton `state` table (attached/prev_on_results/buf/items/prefix/selected/open/
      win/menu_buf — the last two nil forward-contract fields) + `return M`.
  - WRITE the [Mode A] header: role (the windowless menu-STATE consumer of S30's on_results seam — the blink list.lua
      model); the blink-vs-cmp-fusion point (model on blink, NOT cmp's custom_entries_view); the last-wins-overwrite
      attach idiom (cmp single-callback-seam pattern; idempotent via `attached`); the NO-redundant-staleness-guard
      decision (cite research §4 — S30's two-layer supersession is the one guard; a consumer re-query races); the
      S30-already-normalizes-null note (on_results always gets a valid array); the no-schedule_wrap-on-on_results
      note (it's already api-safe on the main loop); the open(items) S34-compatible signature + selected=1; the
      no-op render(state) seam (S34 implements); the forward contracts (get_selected→S32, next/prev/dismiss→S36,
      auto-close→S37); the "state only — not the window" scope guard.
  - DEFINE the @class blocks (pi-editor.AutocompleteItem [reuse S30's note — shape-agnostic]; pi-editor.MenuState) +
      the LuaCATS on every public fn.
  - NAMING/PLACEMENT: `plugin/lua/pi-editor/menu.lua` (sibling of completion.lua/bridge.lua).
  - DEPENDENCIES: require("pi-editor.completion") (read FRESH inside attach() for the on_results slot). No other
      requires (NO bridge, NO coords — S31 consumes S30's seam, not the bridge directly).

Task 3: CREATE menu.lua — attach()/detach() (the on_results wiring, last-wins + idempotent)
  - IMPLEMENT M.attach():
      * if state.attached then return end  -- idempotent (a /reload re-running activate() does not stack)
      * local comp = require("pi-editor.completion")  -- READ FRESH (handshake async + test mocks)
      * if type(comp) ~= "table" then return end  -- never throws (completion absent)
      * state.prev_on_results = comp.on_results  -- save the prior (nil-safe; restored by detach)
      * comp.on_results = M.on_results  -- last-wins overwrite (the cmp single-callback-seam pattern)
      * state.attached = true
  - IMPLEMENT M.detach():
      * if not state.attached then return end
      * local comp = require("pi-editor.completion")
      * if type(comp) == "table" then comp.on_results = state.prev_on_results end  -- restore prior (or nil)
      * state.prev_on_results = nil; state.attached = false
  - NEVER THROWS: pcall-wrap the require + the on_results set/restore (a completion bug must not break detach).

Task 4: CREATE menu.lua — on_results(buf, items, prefix) (the seam consumer — route on payload, no staleness re-derive)
  - IMPLEMENT M.on_results(buf, items, prefix):
      * if type(buf) ~= "number" or not vim.api.nvim_buf_is_valid(buf) then return end  -- wiped buf during debounce
      * state.buf = buf
      * state.prefix = (type(prefix) == "string") and prefix or ""  -- normalize (defensive; S30 sends a string)
      * items = (type(items) == "table") and items or {}  -- normalize (defensive; S30 sends a valid array)
      * if #items == 0 then M.close() else M.open(items) end  -- THE routing (blink list.show: empty→hide / non-empty→store+show)
  - NEVER THROWS: the nvim_buf_is_valid guard is pcall-safe by nature; type-guards defend bad args.
  - NO STALENESS RE-DERIVE: do NOT call nvim_win_get_cursor/nvim_buf_get_lines here. S30's on_results fires
      latest-only (gen-guard). The buf-validity check is a WIPE guard, not a staleness check. (research §4.)

Task 5: CREATE menu.lua — open(items)/close() + the LOCAL no-op render(state) seam
  - DEFINE local render = function(_state) end  -- the S34 DI seam (no-op in S31; S34 implements nvim_open_win here).
      Name the param `_state` (the leading _ signals "unused in S31"); S34/S35 will read it. Pass the live `state`.
  - IMPLEMENT M.open(items):
      * items = (type(items) == "table") and items or {}  -- normalize (defensive)
      * state.items = items
      * state.selected = (items[1] ~= nil) and 1 or 0  -- 1 after open with items; 0 if somehow empty (defensive)
      * state.open = (#items > 0)  -- open ONLY if there are items (defensive against an empty open() call)
      * render(state)  -- S34 hook: create/draw the floating window. S31: no-op.
  - IMPLEMENT M.close():
      * state.items = {}
      * state.selected = 0
      * state.open = false
      * render(state)  -- S34 hook: close the floating window (nvim_win_close). S31: no-op.
  - NOTE: open()'s signature is items-ONLY (S34-compatible). buf+prefix are stored by on_results BEFORE open(). The
      `selected = 1` + `open = true` (when items non-empty) is the STATE S34 builds on; S34 ADDS the window to render().
  - NEVER THROWS: open/close are pure state writes + a no-op render; no nvim API. pcall not needed but harmless.

Task 6: CREATE menu.lua — get_selected/get_items/get_prefix/get_buf/is_open/has_items/reset
  - IMPLEMENT M.get_selected(): return state.items[state.selected]  -- nil when closed (selected==0) — blink list.accept shape.
  - IMPLEMENT M.get_items(): local copy = {}; for i=1,#state.items do copy[i] = state.items[i] end; return copy
      (SHALLOW copy — the caller may not mutate state.items; the item tables themselves are shared, which is fine —
      S32 reads item.value, S34 reads item.label/description).
  - IMPLEMENT M.get_prefix(): return state.prefix.
  - IMPLEMENT M.get_buf(): return state.buf.
  - IMPLEMENT M.is_open(): return state.open == true  -- (state.open is only true after open() with items).
  - IMPLEMENT M.has_items(): return #state.items > 0.
  - IMPLEMENT M.reset():
      * M.close()  -- clears items/selected/open (+ the no-op render)
      * if state.attached then M.detach() end  -- restore prior on_results
      * state.buf = nil  -- clear the buf/prefix too (full teardown for tests + S37)
      * state.prefix = ""
      * state.win = nil; state.menu_buf = nil  -- forward-contract hygiene
  - NEVER THROWS (idempotent — safe to call when never activated, mirrors completion.reset()/bridge.close()).

Task 7: MODIFY plugin/lua/pi-editor/init.lua — activate() gains the menu.attach() pcall (the SOLE existing-file change)
  - FIND: the M.activate() body — AFTER `vim.bo[buf].filetype = "pi-prompt"` (so the ftplugin's refresh autocmds
      exist) and ALONGSIDE the existing `pcall(function() local ok, br = pcall(require, "pi-editor.bridge"); if ok
      and type(br.handshake)=="function" then br.handshake(desc, function(_err,_info) end) end end)` block.
  - ADD (mirror that EXACT pattern):
      -- S31: wire completion results -> menu population (forward-contract no-op-safe, mirrors the bridge.handshake
      -- pcall above). menu.attach() registers completion.on_results. Safe to call before the bridge connects
      -- (refresh is a silent no-op then); idempotent across /reload (the `attached` flag).
      pcall(function()
        local ok, menu = pcall(require, "pi-editor.menu")
        if ok and type(menu.attach) == "function" then menu.attach() end
      end)
  - PRESERVE: the existing filetype set, the descriptor storage, the bridge handshake pcall, and the `return desc`.
      Do NOT reorder or change any existing line — only ADD this one pcall block.
  - VERIFY non-regression: init_spec.lua (S19) + activate_spec.lua (S21) still pass (the added pcall is no-op-safe
      if menu.lua is absent — `pcall(require,...)` returns ok=false → the block is a no-op; and menu.attach() itself
      never throws).

Task 8: CREATE plugin/tests/menu_spec.lua — plenary/busted (state-only + a full-flow case)
  - STRUCTURE: local menu = require("pi-editor.menu"); local completion = require("pi-editor.completion"); local pi =
      require("pi-editor"); a `reset()` helper (menu.reset(); completion.on_results=nil; pi.bridge=nil) in
      before_each/after_each. Reuse the completion_spec `fake_bridge(opts)` helper (copy it — or require it inline;
      the spec is self-contained like completion_spec). Set pi.bridge=fake + completion.reset() before full-flow cases.
  - CASES (mirror completion_spec's vim.wait style):
      * surface: attach/detach/on_results/open/close/get_selected/get_items/get_prefix/get_buf/is_open/has_items/reset
        are functions.
      * attach wires the seam: attach(); assert completion.on_results == menu.on_results (function-equal). Idempotent:
        attach() twice → still == menu.on_results; state.prev_on_results not re-saved (assert via detach restoring
        the original nil).
      * on_results routing (NON-empty): on_results(buf, {{value="a",label="a"},{value="b",label="b"}}, "ab"); assert
        is_open()==true; get_selected().value=="a"; get_items()[1].value=="a" + get_items()[2].value=="b"; selected
        is 1; get_prefix()=="ab"; get_buf()==buf.
      * on_results routing (empty): on_results(buf, {}, "ab"); assert is_open()==false; get_selected()==nil;
        has_items()==false.
      * on_results routing (nil items — defensive): on_results(buf, nil, "ab") → close (is_open()==false).
      * on_results routing (wiped buf): create+delete a buf; on_results(deadbuf, items, "p") → no throw, state.buf
        unchanged (the validity guard bails).
      * open(items) S34-compat: open({{value="x",label="x"}}); assert selected==1 + open==true. close(); assert
        selected==0 + open==false + items=={}.
      * get_items is a SHALLOW copy: mutate the returned table; assert state.items unchanged.
      * detach restores: pre = completion.on_results (before attach, == nil); attach(); detach(); assert
        completion.on_results == pre (nil). If pre was set to a sentinel fn, detach restores the sentinel.
      * reset idempotent + never-throws: reset() 3×; assert is_open()==false + attached==false + buf==nil.
      * never-throws: on_results(nil,...), on_results(buf, "x", nil); attach() when completion absent (mock require
        to fail); detach() when never attached.
      * FULL FLOW (real completion + fake bridge + attach): menu.attach(); fake=fake_bridge(); pi.bridge=fake; buf
        with lines {"/mo"} + cursor col 3 in a window; completion.refresh(buf); wait_for(200, #fake.requests>=1);
        fake.resolve_last(nil, {items={{value="/model",label="model"}}, prefix="/mo"}); wait_for(200, menu.is_open());
        assert menu.is_open()==true + menu.get_items()[1].value=="/model" + menu.get_selected().value=="/model" +
        menu.get_prefix()=="/mo" + menu.get_buf()==buf. (Proves the S30→S31 seam end-to-end, no socket.)
      * FULL FLOW (empty result closes): same setup; resolve_last with {items={}, prefix="/zz"}; assert
        is_open()==false (the empty branch routes to close).
  - STYLE: describe("pi-editor.menu", …); it(…); assert.are.equals/assert.is_true/assert.is_nil/assert.has_no.errors.
    vim.wait(ms, predicate, 5) for async. Do NOT name a spec-local table `pending`.
  - PLACEMENT: plugin/tests/menu_spec.lua (sibling of completion_spec.lua).

Task 9: CREATE plugin/tests/menu_smoke.lua — plenary-free (real bridge + real completion + menu.attach)
  - STRUCTURE: reuse the coords_smoke.lua `check`/`fails`/`cquit`/`SMOKE_PASS` footer. Spin a fake luv unix-socket
      server (the bridge_request_spec `with_request_server` body — bind a unique tmp path, accept the connection,
      read the hello via jsonlreader, reply with a hello result {ok:true,serverVersion,cwd,fdAvailable}, then capture
      the getSuggestions request + reply with {items, prefix}). handshake via bridge.handshake (sets pi.bridge on
      success); menu.attach(); nvim_create_buf + set_lines({"/mo"}) + (in a window) set cursor col 3;
      completion.refresh(buf); vim.wait for the debounce + the request to arrive at the server; server replies
      {items={{value="/model",label="model"}}, prefix="/mo"}; vim.wait for menu.is_open(); assert menu.is_open()==true
      + menu.get_items()[1].value=="/model" + menu.get_selected().value=="/model".
  - CASE 2 (empty closes): server replies to a 2nd getSuggestions with {items={}, prefix="/zz"}; vim.wait; assert
      menu.is_open()==false.
  - CASE 3 (reset never-throws): menu.reset(); bridge.close(); server stop — no throw.
  - KEEP the trailing `if fails>0 then cquit 1 end; io.stdout:write("SMOKE_PASS\n")`.
  - RUN: `cd plugin && nvim --headless --clean -u NORC +"luafile tests/menu_smoke.lua" +qa` → SMOKE_PASS / exit 0.
```

### Implementation Patterns & Key Details

```lua
-- === attach()/detach() — the on_results wiring (last-wins overwrite + idempotent) ===
function M.attach()
  if state.attached then return end                       -- idempotent (a /reload does not stack)
  local ok, comp = pcall(require, "pi-editor.completion") -- READ FRESH (handshake async + test mocks)
  if not ok or type(comp) ~= "table" then return end     -- never throws (completion absent)
  state.prev_on_results = comp.on_results                 -- save prior (nil-safe; restored by detach)
  comp.on_results = M.on_results                          -- last-wins overwrite (cmp single-callback-seam pattern)
  state.attached = true
end

function M.detach()
  if not state.attached then return end
  local ok, comp = pcall(require, "pi-editor.completion")
  if ok and type(comp) == "table" then comp.on_results = state.prev_on_results end  -- restore prior (or nil)
  state.prev_on_results = nil
  state.attached = false
end

-- === on_results(buf, items, prefix) — the seam consumer (route on payload; NO staleness re-derive) ===
-- S30 fires this ONLY for the latest non-stale success (gen-guard) + already normalized null→{items={},prefix=""}.
-- So on_results routes on the payload + a buf-WIPE guard only. Do NOT re-query nvim_win_get_cursor (false-negative race).
function M.on_results(buf, items, prefix)
  if type(buf) ~= "number" or not vim.api.nvim_buf_is_valid(buf) then return end  -- wiped buf during debounce
  state.buf = buf
  state.prefix = (type(prefix) == "string") and prefix or ""
  items = (type(items) == "table") and items or {}       -- defensive (S30 sends a valid array)
  if #items == 0 then M.close() else M.open(items) end   -- THE routing (blink list.show: empty→hide / non-empty→show)
end

-- === open(items)/close() + the LOCAL no-op render(state) seam (S34 implements render) ===
local render = function(_state) end                       -- S34 DI seam: S34 implements nvim_open_win here; S31 no-op.

function M.open(items)
  items = (type(items) == "table") and items or {}
  state.items = items
  state.selected = (items[1] ~= nil) and 1 or 0          -- 1 after open with items (1-indexed; S36 wraparound); 0 if empty
  state.open = (#items > 0)                               -- open ONLY if items (defensive)
  render(state)                                          -- S34 hook: create/draw the floating window. S31: no-op.
end

function M.close()
  state.items = {}
  state.selected = 0
  state.open = false
  render(state)                                          -- S34 hook: nvim_win_close. S31: no-op.
end

-- === accessors (for S32 accept + S34/S36/S37) + reset() (teardown seam) ===
function M.get_selected() return state.items[state.selected] end  -- nil when closed (blink list.accept shape)
function M.get_items()                                            -- SHALLOW copy (caller may not mutate state.items)
  local copy = {}
  for i = 1, #state.items do copy[i] = state.items[i] end
  return copy
end
function M.get_prefix() return state.prefix end
function M.get_buf() return state.buf end
function M.is_open() return state.open == true end
function M.has_items() return #state.items > 0 end

function M.reset()
  M.close()                              -- clears items/selected/open (+ no-op render)
  if state.attached then M.detach() end  -- restore prior on_results
  state.buf = nil; state.prefix = ""     -- full teardown for tests + S37
  state.win = nil; state.menu_buf = nil  -- forward-contract hygiene
end
```

### Integration Points

```yaml
MODULE (menu.lua):
  - create: "plugin/lua/pi-editor/menu.lua — a windowless singleton menu-STATE module: attach()/detach() (the
    completion.on_results wiring, last-wins + idempotent) + on_results(buf,items,prefix) (the seam consumer —
    empty→close / non-empty→store+open, routes on payload, no staleness re-derive) + open(items)/close() (state
    only + a LOCAL no-op render(state) seam for S34) + get_selected/get_items/get_prefix/get_buf/is_open/has_items
    (accessors for S32/S34/S36/S37) + reset() (teardown). Reads completion FRESH from require('pi-editor.completion')
    at call time; NO bridge/coords dependency (consumes S30's seam, not the bridge directly)."

WIRING (init.lua activate() — the SOLE existing-file modification):
  - add to: "plugin/lua/pi-editor/init.lua M.activate() — AFTER `vim.bo[buf].filetype = 'pi-prompt'` and ALONGSIDE
    the existing bridge.handshake pcall."
  - pattern: "pcall(function() local ok, menu = pcall(require, 'pi-editor.menu'); if ok and type(menu.attach) ==
    'function' then menu.attach() end end) — the EXACT shape of the existing bridge.handshake pcall. No-op-safe if
    menu.lua is absent (pcall(require,...) → ok=false → no-op). Idempotent across /reload (menu.attach's `attached` flag)."

CALLERS (EXISTING + this task):
  - init.lua activate() (S21, COMPLETE + this task's 2-line add): calls menu.attach() after filetype set. The
    ftplugin's refresh autocmds (S22, COMPLETE) then fire completion.refresh(buf) on insert-mode changes → S30's
    on_results (now wired) → menu.on_results → open/close. No ftplugin edit (its dispatch is already no-op-safe).

CONSUMERS (FUTURE — do NOT implement in S31; just design the state + accessors to serve them):
  - S32 (accept via applyCompletion): "reads menu.get_selected() + menu.get_prefix() + menu.get_buf(); calls
    bridge.request('applyCompletion', {lines, cursorLine, cursorCol, item=get_selected(), prefix=get_prefix()}, cb);
    on success replaces the buffer + sets the cursor (coords.pi_to_nvim_coords) + menu.close()."
  - S33 (Tab-force file completion): "calls bridge.request('shouldTriggerFileCompletion',…) then (if true)
    bridge.request('getSuggestions', vim.tbl_extend('keep', pi, {force=true}), cb) — reuses S30's do_refresh; the
    cb routes through on_results → menu.open just like a normal fetch."
  - S34 (floating window): "EDIT menu.lua to implement the LOCAL render(state) (nvim_create_buf + nvim_open_win +
    nvim_buf_set_lines); enhances open()/close() with the window (open()'s signature M.open(items) is ALREADY in
    place — S34 adds the window, not a rewrite). Reads state.items/state.selected for the two-column rendering (S35)."
  - S36 (navigation): "implement M.next()/M.prev()/M.dismiss() — set state.selected (wraparound) + call render(state);
    M.dismiss() calls M.close(). get_selected() already serves the accept path."
  - S37 (auto-close on InsertLeave/CursorMoved-out): "calls menu.close()/menu.reset() to clear the menu + detach."

NO INTEGRATION with: bridge.lua's internals, coords.lua's functions, completion.lua's do_refresh (call-only via the
on_results seam), the plugin/pi-editor.lua shim, or jsonlreader.lua. menu.lua is a self-contained module that
COMPOSES the COMPLETE completion seam (via the on_results slot) + is WIRED by activate().
```

## Validation Loop

> Reuses `plugin/tests/minimal_init.lua` (S19) unchanged. nvim 0.12.4 verified. Plenary at
> `/home/dustin/.local/share/nvim/lazy/plenary.nvim`. Run all commands from the `plugin/` dir.

### Level 1: Syntax & Style (Immediate Feedback)

```bash
# Load-check the new module (catches syntax/LuaCATS errors instantly) — headless, no plenary.
cd /home/dustin/projects/pi-nvim-bridge/plugin
nvim --headless --clean -u NORC \
  -c 'set rtp+=.' \
  -c 'lua local m=require("pi-editor.menu"); assert(type(m.attach)=="function" and type(m.detach)=="function" and type(m.on_results)=="function" and type(m.open)=="function" and type(m.close)=="function" and type(m.get_selected)=="function" and type(m.reset)=="function")' \
  -c 'qa'
echo "exit=$?   # 0 = module loads + all public fns exist"
# Expected: exit 0. If non-zero, READ the nvim stderr (syntax/typo/LuaCATS) and fix before proceeding.

# Load-check init.lua still loads (the activate() modify didn't break it).
nvim --headless --clean -u NORC -c 'set rtp+=.' -c 'lua local p=require("pi-editor"); assert(type(p.activate)=="function")' -c 'qa'
echo "exit=$?   # 0 = init.lua loads unchanged surface"
# Expected: exit 0.

# Optional lint (the repo lints Lua ad-hoc — match the sibling PRPs: rely on the load + spec):
luacheck lua/pi-editor/menu.lua --std luajit 2>/dev/null || true
```

### Level 2: Unit Tests (Component Validation)

```bash
cd /home/dustin/projects/pi-nvim-bridge/plugin

# 2a. Plenary-FREE smoke (the real-bridge integration) — must pass.
nvim --headless --clean -u NORC +"luafile tests/menu_smoke.lua" +qa
echo "exit=$?   # 0 + prints SMOKE_PASS"
# Expected: SMOKE_PASS / exit 0 (a getSuggestions reply populated the menu; an empty reply closed it; reset never-threw).

# 2b. Plenary/busted spec (the state-only logic gate + the full-flow case) — must pass.
nvim --headless --clean -u tests/minimal_init.lua \
  -c 'lua require("plenary.busted").run("tests/menu_spec.lua")'
echo "exit=$?"
# Expected: "Success: <N>" / "Failed: 0" / "Errors: 0" / exit 0. Covers: attach idempotent + wires the seam;
# on_results routing (empty→close / non-empty→store+open / wiped-buf guard / nil-items defensive); open(items)
# S34-compat + selected==1; get_items shallow-copy; detach restores; reset idempotent; never-throws; FULL FLOW
# (real completion + fake bridge + attach → refresh → resolve → menu populated + empty result closes).

# If failing: READ the failing assertion name + actual vs expected, debug root cause, fix the implementation
# (do NOT weaken an assertion — the empty→close + non-empty→store+open routing + the no-redundant-staleness-guard
# are the LIVE-VERIFIED correct contract; the full-flow case proves the S30→S31 seam).
```

### Level 3: Integration Testing (System Validation)

```bash
cd /home/dustin/projects/pi-nvim-bridge/plugin

# 3a. Non-regression — run EVERY prior spec to confirm S31's menu.lua + init.lua change didn't break siblings.
for spec in tests/init_spec.lua tests/shim_spec.lua tests/activate_spec.lua tests/ftplugin_spec.lua \
            tests/jsonlreader_spec.lua tests/bridge_spec.lua tests/bridge_handshake_spec.lua \
            tests/bridge_request_spec.lua tests/bridge_notify_spec.lua tests/coords_spec.lua \
            tests/completion_spec.lua; do
  echo "--- $spec ---"
  nvim --headless --clean -u tests/minimal_init.lua -c "lua require('plenary.busted').run('$spec')"
done
echo "exit=$?"
# Expected: each spec "Failed: 0 / Errors: 0". (init.lua + activate_spec: the added menu.attach() pcall is
# no-op-safe — if menu.lua is absent it's a no-op; activate_spec's dormant/valid/malformed cases are unaffected.
# completion_spec: S31 does NOT touch completion.lua — its on_results slot is the DONE seam S31 consumes.)

# 3b. End-to-end wiring sanity (headless, no plenary) — proves the full activation → attach → populate path
# holds: activate() wires on_results; a simulated completion result lands in the menu state.
nvim --headless --clean -u NORC -c 'set rtp+=.' +"luafile /dev/stdin" +qa <<'LUA'
local pi = require("pi-editor"); pi.setup({ debounce_ms = 10 })
-- stub the bridge (so completion.refresh can fetch) + a fake getSuggestions result
pi.bridge = {
  is_connected = function() return true end,
  cancel = function() end,
  request = function(method, params, cb)
    if method == "getSuggestions" then
      vim.schedule_wrap(cb)(nil, { items = { { value = "/model", label = "model" } }, prefix = "/mo" })
    end
    return "1"
  end,
}
local menu = require("pi-editor.menu")
local completion = require("pi-editor.completion")
menu.attach()                                             -- S31 wiring
assert(completion.on_results == menu.on_results, "attach must wire the seam")
-- create a pi-prompt buffer + drive a refresh
local buf = vim.api.nvim_create_buf(true, false)
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "/mo" })
local win = vim.api.nvim_get_current_win(); vim.api.nvim_win_set_buf(win, buf)
vim.api.nvim_win_set_cursor(win, { 1, 3 })
completion.refresh(buf)
vim.wait(200, function() return menu.is_open() end, 5)
assert(menu.is_open(), "menu must open after a getSuggestions result")
assert(menu.get_selected().value == "/model", "selected must be the first item")
assert(menu.get_prefix() == "/mo", "prefix must be stored")
-- empty result closes
pi.bridge.request = function(_, _, cb) vim.schedule_wrap(cb)(nil, { items = {}, prefix = "/zz" }); return "2" end
completion.refresh(buf)
vim.wait(200, function() return not menu.is_open() end, 5)
assert(not menu.is_open(), "menu must close on an empty result")
menu.reset()
assert(not menu.is_open() and completion.on_results ~= menu.on_results, "reset must close + detach")
io.stdout:write("E2E_PASS\n")
LUA
echo "exit=$?"
# Expected: E2E_PASS / exit 0 (attach wired on_results; a result populated the menu; an empty result closed it;
# reset closed + detached). This mirrors the activate() wiring + the S30→S31 seam end-to-end.
```

### Level 4: Creative & Domain-Specific Validation

```bash
# No external/creative tooling for this layer (menu.lua is pure Lua over the in-tree completion seam; no window —
# the no-op render stub means no nvim_open_win to test in S31). Domain-specific validation IS the routing behavior
# (Levels 2/3 cover it):
#   * empty-items → close (the smoke + E2E assert is_open()==false after an empty reply).
#   * non-empty → store + open + selected==1 (the spec + E2E assert get_selected()==items[1]).
#   * attach idempotent + wires the seam (the E2E asserts completion.on_results == menu.on_results).
#   * reset closes + detaches (the E2E asserts both).
# The NO-redundant-staleness-guard decision is validated indirectly: the full-flow cases prove a result that matches
# the latest request populates the menu WITHOUT any consumer-side cursor/buffer re-query (S30's supersession holds).

# Optional: confirm the Neovim version (the api-safe-cb fact + nvim_buf_is_valid verified on 0.12.x).
nvim --version | head -1   # 0.12.4 verified.
```

## Final Validation Checklist

### Technical Validation

- [ ] Level 1 load-check exits 0 (menu.lua loads; all public fns exist; init.lua still loads unchanged surface).
- [ ] Level 2a smoke prints `SMOKE_PASS` / exit 0 (real bridge reply populated the menu; empty reply closed it; reset).
- [ ] Level 2b plenary spec: `Success: <N>` / `Failed: 0` / `Errors: 0` / exit 0 (all cases pass, incl. the full-flow).
- [ ] Level 3a non-regression: every prior spec (incl. init_spec + activate_spec + completion_spec) still
      `Failed: 0 / Errors: 0` (the init.lua change is no-op-safe; completion.lua untouched).
- [ ] Level 3b E2E prints `E2E_PASS` (attach wired; result populated; empty result closed; reset closed + detached).
- [ ] No syntax/lint errors blocking module load.

### Feature Validation

- [ ] All Success Criteria from "What" section met (attach idempotent + wires seam; on_results routing; open(items)
      S34-compat + selected==1; no window; no redundant staleness guard; full flow; detach restores; reset idempotent;
      never-throws; degrade when completion absent).
- [ ] Manual/live sanity successful (Level 3b — attach → refresh → result → populate; empty → close; reset).
- [ ] The no-redundant-staleness-guard decision is DOCUMENTED in menu.lua's header (a reader of the S31 contract's
      "guard if needed" is not surprised that S31 omits it — the false-negative race is LIVE-VERIFIED, research §4).
- [ ] The blink.cmp `list.lua` model (windowless state ≠ window) is documented in the header (model on blink, NOT
      cmp's fused custom_entries_view).
- [ ] Forward contracts (get_selected→S32, render→S34, next/prev/dismiss→S36, reset/close→S37) documented in the
      header + LuaCATS so the next implementer sees the state's purpose + the render seam.

### Code Quality Validation

- [ ] Follows existing module conventions (bridge.lua/completion.lua's singleton `state` shape + [Mode A] header style
      + LuaCATS density + "Node builtins analog"-style footer + PRD §X + LIVE-VERIFIED citations; NOT coords.lua's
      stateless shape — menu HAS state).
- [ ] Mostly additive — 2 NEW files + the init.lua activate() 2-line pcall (no-op-safe, mirrors bridge.handshake);
      NO modification to completion.lua/bridge.lua/coords.lua/jsonlreader.lua/the ftplugin/the shim (completion's
      on_results slot is the DONE seam S31 consumes).
- [ ] Anti-patterns avoided (see below): no window in S31; no redundant staleness re-derive; no save-and-restore-list
      attach; no schedule_wrap on on_results; no open(buf,items,prefix) signature (S34-collision); no next/prev/dismiss
      (S36 scope); no accept (S32 scope); no render override exposure (keep render LOCAL).
- [ ] No new dependencies (pure Lua + the in-tree completion seam + Neovim builtins only).

### Documentation & Deployment

- [ ] menu.lua [Mode A] header documents: role (windowless menu-STATE consumer of S30's seam — the blink list.lua
      model); the last-wins-overwrite attach idiom + idempotency; the NO-redundant-staleness-guard decision (cite
      research §4); the S30-already-normalizes-null note; the no-schedule_wrap-on-on_results note; the open(items)
      S34-compatible signature + selected=1; the no-op render(state) seam (S34); the forward contracts; the "state
      only — not the window" scope guard.
- [ ] LuaCATS `---@param`/`---@return` + the `---@class pi-editor.MenuState` block present.
- [ ] The activate() wiring (menu.attach() pcall) is commented inline (mirrors the bridge.handshake comment style) so
      a reader sees WHY it is there + that it is no-op-safe + idempotent.

---

## Anti-Patterns to Avoid

- ❌ **Don't create the floating window in S31.** `nvim_open_win`/`nvim_create_buf`/`nvim_buf_set_lines` are S34/S35.
  S31's `open()`/`close()` manage STATE ONLY + call a LOCAL no-op `render(state)` stub. (blink list.lua = windowless;
  nvim-cmp custom_entries_view FUSES state+window = the anti-pattern. Model on blink. research §2/§5.)
- ❌ **Don't re-derive staleness in the consumer.** S30's two-layer supersession (cancel + gen-guard) ALREADY
  guarantees `on_results` fires ONLY for the latest non-stale success whose params matched the buffer at issue time.
  Re-querying `nvim_win_get_cursor`/`nvim_buf_get_lines` in `on_results` to derive staleness is a FALSE-NEGATIVE RACE
  (the buffer may legitimately advance past the request position for a valid latest result — verified in blink/cmp).
  Route on the PAYLOAD ONLY + an `nvim_buf_is_valid(buf)` WIPE guard. (research §4.)
- ❌ **Don't use save-and-restore-a-LIST for `on_results`.** It's a SINGLE forward-contract slot (one menu consumer).
  Use last-wins OVERWRITE (`completion.on_results = M.on_results`), idempotent via the `attached` flag. Multi-listener
  `table.insert` is for pub/sub emitters (multiple consumers) — cmp/blink use it for event emitters, NOT for a single
  callback seam. Save-and-restore-THE-PREVIOUS-SLOT (singular) IS used here, but only for detach symmetry (cmp does
  this for indentkeys, not callbacks — but it's harmless + aids testability). (research §3.)
- ❌ **Don't `schedule_wrap` `M.on_results` in attach().** S30 fires `on_results` on the nvim MAIN LOOP (the bridge cb
  is `schedule_wrap`'d S26; completion's cb runs via `vim.defer_fn` = main loop). Storing a RAW fn is correct + avoids
  a needless hop. (bridge.lua's `on_notification` DOES wrap — because its dispatch runs inline from the luv read_start
  cb; S30's `on_results` does NOT — it's already main-loop. Different contexts.)
- ❌ **Don't change `open()`'s signature to `open(buf, items, prefix)`.** The S34 contract (`tasks.json`
  P2.M8.T21.S34) is `M.open(items)`. `buf`+`prefix` are stored by the `on_results` handler BEFORE calling
  `open(items)`, via `state.buf`/`state.prefix`. A 3-arg `open()` would collide with S34's contract.
- ❌ **Don't expose `render` as a public `M._render` override.** Keep it a LOCAL `render(state)` no-op stub. S34 will
  EDIT menu.lua to implement it (nvim_open_win). A public override seam invites user-land shenanigans + muddies the
  "S31 = state, S34 = window" boundary. (The forward-contract CALLBACK slots — `on_results` — are public because
  they're the SEAM; `render` is an internal DI hook for the next task.)
- ❌ **Don't implement `next`/`prev`/`dismiss`/navigate.** Those are S36. S31 implements `open`/`close`/`get_*`/`reset`
  ONLY. The ftplugin's keymap dispatch (`on_next`/`on_prev`/`on_dismiss`) returns false for the absent ones → feedkey
  fall-through (C-N/C-P/C-E do nothing special) — that is CORRECT for S31's scope. Implementing them collides with S36.
- ❌ **Don't implement accept (`applyCompletion`).** That is S32. S31 only EXPOSES `get_selected()`/`get_items()`/
  `get_prefix()`/`get_buf()` so S32 can READ the state. S32 will issue the RPC + replace the buffer + close the menu.
- ❌ **Don't modify completion.lua, bridge.lua, coords.lua, jsonlreader.lua, the ftplugin, or the shim.** S31's only
  existing-file change is `init.lua` `activate()` (the additive 2-line `menu.attach()` pcall, mirroring the existing
  `bridge.handshake` pcall). completion.lua's `on_results` slot is the DONE seam S31 CONSUMES — touching it would risk
  non-regression + is out of scope. The ftplugin's dispatch is already no-op-safe.
- ❌ **Don't re-normalize a `null`/`vim.NIL` result in `on_results`.** S30 ALREADY normalizes a null `getSuggestions`
  result to `{items={}, prefix=""}` BEFORE firing `on_results` (completion.lua do_refresh cb). So `on_results` ALWAYS
  receives a valid `items` array (possibly empty) + a string `prefix`. Handle `nil`/non-table `items` ONLY as a
  defensive type-guard (treat as `{}`), not as a protocol-level null path. (The bridge's `vim.NIL`→nil normalization
  is DONE S26.)
- ❌ **Don't cache `completion` at module load.** Read it FRESH inside `attach()`/`detach()`
  (`require("pi-editor.completion")`). Same codebase rule as S30's bridge-read-fresh: the handshake resolves async
  (completion.lua is loadable at any time, but tests must be able to swap state after require) + a /reload re-runs
  activate() (so attach() must re-require). Caching breaks neither-correctly.

---

## Confidence Score

**9/10** for one-pass implementation success. Rationale: the single upstream seam (`completion.on_results(buf,
items, prefix)` — fires ONLY for the latest non-stale success, already null-normalized, on the api-safe main loop) is
COMPLETE (S30) with an exhaustive [Mode A] header + PRP; the design is the LIVE-VERIFIED blink.cmp `list.lua` model
(windowless state ≠ window — external research with GitHub permalinks); the NO-redundant-staleness-guard decision
and the last-wins-overwrite attach idiom are battle-tested in cmp + blink (cited); the test harness + exact commands
are verified green (completion_spec's `fake_bridge` helper + bridge_request_spec's `with_request_server` pattern +
the coords_spec/smoke footer); and the scope is narrow + mostly additive (2 NEW files + a 2-line no-op-safe pcall in
activate(), mirroring the existing bridge.handshake pcall — completion.lua/bridge.lua/coords.lua/the ftplugin
untouched). The one residual risk is the `open(items)` S34-compatibility (S34 is Planned — its contract says
"Implement M.open(items)" which S31 already creates; S34 ADDS the window to it, not a rewrite, but a future
implementer must respect S31's signature + the `render(state)` seam). Mitigated by the explicit S34-forward-compat
notes (open(items) items-only; selected=1; LOCAL no-op render stub; win/menu_buf forward-contract state fields) +
the E2E test proving the seam. (Not 10/10 only because the S34 handoff is a future task whose implementer must read
S31's header — but the contract is fully specified here.)