# Research — P2.M7.T18.S31: getSuggestions result → menu population

The CONSUMER of the S30 `completion.on_results(buf, items, prefix)` seam. S31 creates
`menu.lua` (the windowless menu-STATE module, blink.cmp `list.lua` model) + the
completion→menu WIRING, and registers itself on the seam from `activate()`.

---

## 1. What S30 already ships (the seam S31 consumes) — VERIFIED in-tree

`plugin/lua/pi-editor/completion.lua` (S30, COMPLETE):

- `M.refresh(buf)` — the autocmd entry point (InsertEnter/TextChangedI/CursorMovedI,
  wired buffer-local by the COMPLETE ftplugin S22). Debounces (~25 ms via `vim.defer_fn`,
  stop+close on reschedule), reads buffer+cursor, converts via S29 `coords.nvim_to_pi_coords`,
  issues `bridge.request("getSuggestions", {lines,cursorLine,cursorCol,force=false}, cb)`.
- **The cb (two-layer supersession):**
  - `if gen ~= state.gen then return end` — STALE dropped, touch nothing.
  - `if err then return end` — cancelled/timeout/error → touch nothing.
  - normalize null result → `{items={}, prefix=""}`.
  - `state.last_result = { items, prefix }`.
  - **`if type(M.on_results) == "function" then pcall(M.on_results, buf, items, prefix) end`**
    — THE SEAM. Fires ONLY for the latest non-stale success, on the nvim main loop
    (the bridge cb is `schedule_wrap`d S26 → on_results is api-safe).
- `M.on_results` — a settable nil slot (the forward contract S30 left for S31).
- `M.current()` — read-only `{items, prefix}` (shallow copy) for S32/S33.
- `M.reset()` — cancel timer + inflight, clear state.

**Critical implication:** S30 GUARANTEES `on_results` fires ONLY for the latest request
whose params matched the buffer at issue time. Any newer keystroke bumps `gen` → the
prior result is dropped at the gen-guard. So **the consumer (menu) receives items that
ARE current** — no redundant staleness guard needed (see §3).

---

## 2. External model — blink.cmp `list.lua` (windowless menu-STATE module)

Research verdict: model S31's `menu.lua` on **blink.cmp `lua/blink/cmp/completion/list.lua`**
(a pure Lua windowless singleton state module), NOT on nvim-cmp's fused `custom_entries_view.lua`.

`list.lua` (blink v1.10.2, `lua/blink/cmp/completion/list.lua`):
- State fields: `context`, `items = {}`, `selected_item_idx`, `is_explicitly_selected`.
- `list.show(context, items_by_source)` does EXACTLY the S31 routing:
  ```lua
  list.context = context
  list.items = list.fuzzy(context, items_by_source)   -- STORE latest items in state
  if #list.items == 0 then
    list.hide_emitter:emit({ context = context })     -- empty -> close
  else
    list.show_emitter:emit({ items = list.items, context = context })  -- non-empty -> open
  end
  ```
- `list.accept(opts)` reads selection DIRECTLY from state, **zero window coupling**:
  ```lua
  local item = list.items[opts.index or list.selected_item_idx]  -- reads state, not the popup
  if item == nil then return false end
  ```
- The window (`completion/windows/menu.lua`) is a DOWNSTREAM SUBSCRIBER; `list` never
  imports it.

**blink base (v1.10.2):** `https://github.com/Saghen/blink.cmp/blob/78336bc89ee5365633bcf754d93df01678b5c08f/`
- list.show routing: `.../lua/blink/cmp/completion/list.lua#L90-L120`
- list.accept (state-only): `.../lua/blink/cmp/completion/list.lua#L359-L375`
- the two-layer-supersession seam (cancel + `event.context.id ~= trigger.context.id`):
  `.../lua/blink/cmp/completion/init.lua#L27-L58`
- cancel half (destroy() neutralizes cb + cancels task):
  `.../lua/blink/cmp/sources/lib/queue.lua#L40-L44`

**nvim-cmp cross-check** (base `2ffe79f1f021def8dd1fcd81deb16f1bb0d989f3`):
- source response guard: `.../lua/cmp/source.lua#L348-L392` (`if self.context ~= ctx then return end`).
- `complete_dedup` (the generation counter): `.../lua/cmp/utils/async.lua#L130-L143`.
- cmp FUSES state+window in `view/custom_entries_view.lua` (the anti-pattern for S31).

---

## 3. Callback registration: last-wins OVERWRITE (NOT save-and-restore)

Research verdict: for a SINGLE forward-contract slot (`on_results`), use **last-wins
overwrite** — `completion.on_results = M.on_results`. This is exactly cmp's
single-callback-seam pattern (`source:complete(ctx, callback)` is a bare closure, no
save/restore). blink/cmp use multi-listener `table.insert` + identity `off` ONLY for
pub/sub event emitters (multiple consumers) — NOT for a single forward contract.

- Save-and-restore-the-previous-slot appears ONLY for imperative global state (cmp's
  indentkeys save/restore in `core.lua`), NOT for forward-contract callbacks.
- **Idempotency for S31:** guard attach with a module `attached` flag so a second
  `attach()` is a no-op (does not re-save `prev_on_results`, which would lose the
  original). `completion.on_results` is last-wins, but the `attached` flag prevents
  stacking and makes `attach()` safe to call from `activate()` on every `/reload`.

---

## 4. NO redundant staleness guard in the consumer — VERIFIED

Research verdict: **neither cmp nor blink adds a staleness guard INSIDE the menu layer.**
Each guards ONCE, at the source→consumer seam:
- blink: `event.context.id ~= trigger.context.id` at the scheduled seam (`completion/init.lua`
  L34-58), then `list.show` trusts it (no re-check).
- cmp: `if self.context ~= ctx then return end` in the source response (`source.lua`
  L348-392); the view pulls fresh entries, no re-check.

**The S31 contract's "guard against stale responses (if needed)" is NOT needed** because
S30's two-layer supersession (cancel + gen-guard) already guarantees `on_results` fires
ONLY for the latest request. A consumer-side re-query of `nvim_win_get_cursor` /
`nvim_buf_get_lines` as a staleness signal is a **FALSE-NEGATIVE RACE** (the buffer may
legitimately advance past the request position even for a valid latest result). S31's
`on_results` handler routes on the PAYLOAD ONLY (buf/items/prefix from the cb args) and
guards buf validity (`nvim_buf_is_valid`) — it does NOT independently re-derive staleness.

---

## 5. API-safety + render seam (testability)

- **schedule_wrap is API-safe** (main loop): `nvim_buf_get_lines`/`nvim_win_get_cursor` are
  safe inside it. S30's `on_results` runs on the main loop (bridge cb is `schedule_wrap`d),
  so S31's handler may read nvim state — though it needs only the payload (`buf`/`items`/
  `prefix` are args) + a `nvim_buf_is_valid(buf)` guard.
- **Render seam (research point 5):** keep `menu.lua` a PURE STATE module — NO
  `nvim_open_win`/`nvim_create_buf` (those are S34). Inject a `render(state)` no-op stub
  that S31's `open()`/`close()` call; S34 implements it to create/draw the floating window.
  This makes S31 testable via STATE assertions (`items`/`selected`/`is_open`) with no UI —
  exactly cmp's split (`source_spec.lua` exists; no `view` spec). blink's `list.lua` is
  inherently unit-testable for the same reason (windowless).

---

## 6. Wiring locus — `init.lua` `activate()` (the ONE existing-file modification)

`M.activate()` (S21, COMPLETE) already orchestrates session wiring:
- sets `vim.bo[buf].filetype = "pi-prompt"` → fires FileType → ftplugin S22 (wires refresh
  autocmds + the 6 keymaps + autosave).
- kicks off `bridge.handshake(desc, cb)` via `pcall(function() local ok,br = pcall(require,
  "pi-editor.bridge"); if ok and type(br.handshake)=="function" then br.handshake(...) end end)`
  → sets `require("pi-editor").bridge` on success.

S31 ADDS the mirror-line for the menu attach, AFTER the filetype set (so the refresh
autocmds are wired) and alongside the bridge handshake pcall (it is safe even if the bridge
isn't connected yet — `completion.refresh` degrades silently when `pi.bridge` is nil):

```lua
-- S31: wire completion results -> menu population (forward-contract no-op-safe, mirrors the
-- bridge.handshake pcall above). menu.attach() registers completion.on_results. Safe to call
-- before the bridge connects (refresh is a silent no-op then); idempotent across /reload.
pcall(function()
  local ok, menu = pcall(require, "pi-editor.menu")
  if ok and type(menu.attach) == "function" then menu.attach() end
end)
```

This is the EXACT pattern of the existing `bridge.handshake` pcall — minimal, consistent,
no-op-safe. It is S31's ONLY modification to an existing file.

---

## 7. Forward-compatibility with S34/S35/S36/S37 (the window/navigation tasks)

S34 contract (`tasks.json`): "Create `plugin/lua/pi-editor/menu.lua`. Implement `M.open(items)`"
(steps: create/reuse scratch buffer, compute display lines, compute width/height, position w/
edge clamping, open floating window, track selected index). S36 adds `M.next()`/`M.prev()`/
`M.dismiss()`/`M.get_selected()`.

**S31 creates menu.lua FIRST** (S34 is Planned, depends only on S19). To make S34 ADDITIVE
(not a rewrite), S31's `menu.lua`:
- Implements the STATE + the `on_results` wiring + `open(items)`/`close()`/`get_selected()`/
  `get_items()`/`get_prefix()`/`get_buf()`/`is_open()`/`has_items()`/`reset()`.
- `open(items)` signature == S34's `M.open(items)` (items only — `buf`+`prefix` are stored by
  the `on_results` handler BEFORE calling `open`, so accept (S32) reads them via accessors).
- `open()`/`close()` call a LOCAL `render(state)` no-op stub (the S34 DI seam). S34 implements
  `render` to `nvim_create_buf`+`nvim_open_win`; S35 enhances it to two-column rendering;
  S36 adds `next`/`prev`/`dismiss` (which set `selected` + call `render`); S37 auto-close
  calls `M.close()`/`M.reset()`.
- Leaves forward-contract fields in state (`win`, `menu_buf` — nil until S34).

**Selected-index policy:** `selected = 1` after `open()` (1-indexed, matches S36's
`M.next()`/`M.prev()` wraparound arithmetic and `get_selected()` returning `items[selected]`).

---

## 8. Gotchas / anti-patterns to encode in the PRP

- **NO window in S31.** `nvim_open_win`/`nvim_create_buf` are S34. S31 = state + wiring +
  the no-op render seam. (blink list.lua model — research §5.)
- **NO redundant staleness guard.** Trust S30's on_results (latest-only). Do NOT re-query
  `nvim_win_get_cursor`/`nvim_buf_get_lines` to derive staleness (false-negative race — §4).
  Only `nvim_buf_is_valid(buf)` guard (a wiped buffer during the debounce).
- **last-wins overwrite** for `on_results`, guarded by an `attached` flag for idempotency.
  No save-and-restore (§3).
- **Read `completion` + the bridge FRESH at call time** (the codebase-wide rule — handshake
  resolves async; tests swap fakes after require). `attach()` does
  `require("pi-editor.completion").on_results = M.on_results`.
- **`open(items)` items-only signature** for S34 compatibility. buf+prefix stored by the
  `on_results` handler.
- **render is a LOCAL no-op stub** (the S34 seam), called from open()/close(). NOT a public
  M._render override (keep the surface minimal; S34 will edit menu.lua to implement it).
- **Never-throws** (the per-keystroke + autocmd contract): pcall the completion.on_results
  set/restore + type-guard every accessor. A missing/disconnected bridge = silent degrade
  (S30's refresh bails; on_results never fires).
- **Singleton state** (one pi-prompt buffer per session — PRD §11). reset() clears state +
  detaches for tests + the future S37 InsertLeave wiring.
- **normalize items** defensively (the extension protocol's AutocompleteItem is `{value,
  label, description?}` — S31 is shape-agnostic like S30; store the array as-is).

---

## 9. Test strategy (mirrors completion_spec.lua's fake-bridge style)

- **menu_spec.lua (plenary/busted):** state-only assertions (NO window). Cases:
  attach wires on_results + idempotent (double-attach no-op); on_results(buf, items, prefix)
  routing — non-empty → is_open true + get_selected==items[1] + get_items/get_prefix/get_buf;
  empty → close (is_open false, selected 0); null items (non-table) → close; detach restores
  on_results (or nil); reset idempotent + detaches; never-throws (bad args, wiped buf);
  FULL FLOW: real completion + fake bridge (the completion_spec fake_bridge helper) +
  menu.attach() → refresh → resolve cb → menu populated + get_items matches. This proves the
  S30→S31 seam end-to-end without a socket.
- **menu_smoke.lua (plenary-free):** fake luv unix-socket server (bridge_request_spec
  with_request_server pattern) + real bridge.handshake + real completion + menu.attach();
  set buffer lines {"/mo"}; refresh; server observes getSuggestions; server replies
  {items={{value="/model",label="model"}}, prefix="/mo"}; vim.wait; assert menu.is_open() and
  menu.get_items()[1].value == "/model" and menu.get_selected().value == "/model". Then a
  2nd reply with empty items → menu.is_open() false. Then menu.reset(); bridge.close();
  server stop. Prints SMOKE_PASS / exit 0.