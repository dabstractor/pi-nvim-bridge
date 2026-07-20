# Research — P2.M8.T22.S37: Auto-close on InsertLeave, CursorMoved out of prefix, buffer change

S37 is the **AUTOCMD-driven auto-close half** of the floating completion menu's lifecycle
(PRD §7.5: "close on `InsertLeave`, `CursorMoved` out of prefix, or buffer write"). It is the
complement to S36 (the KEY handlers — `on_next`/`on_prev`/`on_dismiss`, COMPLETE). S37 wires
the **autocmds** that hide the menu when the user *leaves* the completion context (insert
mode, the buffer), without pressing a dismiss key.

The key design conclusion (§3): of the three named triggers, **two are genuine gaps** that S37
must add (`InsertLeave`, `BufLeave`), and **one is ALREADY handled pi-faithfully** by S30's
existing refresh path (`CursorMovedI → re-fetch → empty → close`). S37 VERIFIES + DOCUMENTS the
third but does NOT reimplement a local "prefix detector" (that would diverge from pi + duplicate
its completable-position logic — an explicit codebase anti-pattern, §9).

## 0. What S30/S31/S34/S36 already ship (the surface S37 builds on) — VERIFIED in-tree

`plugin/lua/pi-editor/completion.lua` (S30 refresh + S32 accept + S33 on_tab + S36 nav):
- `M.refresh(buf)` — the autocmd entry point. `cancel_timer()` (stops prior debounce) then
  `state.debounce_timer = vim.defer_fn(do_refresh, debounce_ms)`. **At most ONE pending debounce
  at any time** (cancel_timer runs before each new defer).
- `do_refresh(buf)` — the debounced body: gate (buf valid + current + bridge connected) → read
  lines+cursor → `coords.nvim_to_pi_coords` → supersede (cancel inflight + bump `state.gen`) →
  `bridge.request("getSuggestions", …, cb)`. The cb: gen-guard (`if gen ~= state.gen then return`)
  → normalize → store `last_result` → fire `M.on_results(buf, items, prefix)`.
- `M.reset()` — **THE cleanup seam** (its docstring literally says "The cleanup seam for tests +
  the future S37 InsertLeave/CursorMoved-out wiring"). Body: `cancel_timer()` + `bridge.cancel(inflight_id)`
  + clears `debounce_timer`/`inflight_id`/`last_result`/`state.buf`, **AND sets `state.gen = 0`**
  (which DROPS any in-flight cb — a stale cb captured gen=N (N>0); after reset gen=0, so the cb's
  `gen ~= state.gen` guard returns early → the stale `on_results` NEVER fires). Idempotent + never
  throws. Does NOT touch the menu (menu.close() is a separate call).
- `cancel_timer()` LOCAL — stop+close the `vim.defer_fn` timer (pcall + `is_closing()` guard; the
  S30 stop+close leak fix — NEVER stop-only).
- `state` fields: `buf`, `debounce_timer`, `gen`, `inflight_id`, `last_result`.
- The handlers' NEVER-THROWS contract + READ-MENU/BRIDGE-FRESH rule (the codebase pattern).

`plugin/lua/pi-editor/menu.lua` (S31 state + S34 window + S35 two-column + S36 nav):
- `M.close()` — clears items/selected/open + `render(state)` hide path (`nvim_win_close` + `state.win=nil`).
  No-op when already closed (re-runs the harmless hide path). Never throws.
- `M.is_open()` → `state.open == true`. `M.reset()` — `close()` + `detach()` + clear buf/prefix/win/menu_buf
  (its docstring: "the future S37 InsertLeave/CursorMoved-out wiring").
- `M._state = state` — the test seam (specs read `state.win`/`selected`/`open`).

`plugin/ftplugin/pi-prompt.lua` (S22 + S36) — the wiring surface:
- `group = nvim_create_augroup("pi-editor", { clear = false })` (SHARED with S20's VimEnter).
- `nvim_clear_autocmds({ buffer = buf, group = "pi-editor" })` — per-buffer idempotency (so a
  re-source does not stack duplicates; siblings untouched).
- `dispatch(modname, fnname, buf)` — lazy-require + pcall-call; returns true only if the fn
  returned truthy. **Autocmd callbacks are fire-and-forget** (return value ignored), so they use
  `dispatch(...)` purely for the no-op-safe-absent-module guarantee.
- The existing refresh autocmd loop: `for _, ev in ipairs({ "InsertEnter", "TextChangedI", "CursorMovedI" })`
  each → `dispatch("pi-editor.completion", "refresh", buf)`.
- The autosave loop: `{ "VimLeavePre", "ExitPre" }` → `dispatch("pi-editor.bridge", "on_exit", buf)`.

## 1. THE #1 bug S37 fixes: the stale-debounce re-open race (LIVE-VERIFIED in-tree)

`refresh()` ALWAYS schedules a `vim.defer_fn(do_refresh, debounce_ms)` (default 25 ms). If the user
presses `<Esc>` (→ `InsertLeave`) DURING that 25 ms window, and S37 does NOTHING, then:

1. `do_refresh(buf)` fires after the debounce — `buf` is STILL valid + STILL current (leaving insert
   does not switch buffers) + the bridge is STILL connected.
2. `do_refresh` reads the buffer (unchanged), issues `getSuggestions`, and its cb (on success with
   items) fires `M.on_results` → `menu.open(items)` — **the menu RE-OPENS in NORMAL mode** (after the
   user explicitly left insert). Bug.
3. Even if `do_refresh`'s `buf == current` check passed, there is no insert-mode guard in `do_refresh`.

**The fix (exactly what `M.reset()` already provides):** on `InsertLeave`/`BufLeave`, S37's handler
calls `cancel_timer()` (closes the pending `vim.defer_fn` so `do_refresh` NEVER runs) + `bridge.cancel`
+ `state.gen = 0` (so any ALREADY-in-flight `getSuggestions` cb is DROPPED by the gen-guard — the
  stale `on_results` never fires) + `menu.close()` (hide the window).

`M.reset()` does ALL of cancel_timer + cancel-inflight + gen=0 + clear-state. So S37's handler =
`menu.close()` then `M.reset()` (order: hide first, then cancel). This is the canonical teardown —
`reset()`'s OWN docstring promises it for "the future S37 … wiring."

## 2. How blink.cmp does it (the live-verified reference) — `lua/blink/cmp/completion/trigger/init.lua`

blink's `trigger.activate()` registers buffer-event callbacks via `buffer_events:listen`:

```lua
trigger.buffer_events:listen({
  on_char_added = on_char_added,
  on_cursor_moved = on_cursor_moved,
  on_insert_leave = function() trigger.hide() end,          -- ← InsertLeave → hide
  on_complete_changed = function() if pumvisible()==1 then trigger.hide() end end,
})
```

- **`on_insert_leave` → `trigger.hide()`** — unambiguous: leaving insert hides the menu. `trigger.hide()`
  sets `context = nil` + emits a `hide` event (the window closes downstream). This is S37's
  `InsertLeave` autocmd.
- **`on_cursor_moved` → `within_query_bounds(cursor)` else `trigger.hide()`** — the "out of prefix"
  decision. blink keeps the menu OPEN only while the cursor stays INSIDE the keyword bounds of the
  context that triggered completion; once the cursor leaves (different line, or col outside
  `[start_col, end_col]`), it hides. BUT blink implements its OWN keyword-regex bounds (it has a full
  `context.lua` with `bounds`). **Our plugin must NOT do this** (§3): pi's `getSuggestions` is the
  single source of truth for "is this position completable" — reimplementing bounds locally would
  DIVERGE from pi.
- **blink has NO separate buffer-switch handler** in the trigger — it relies on the buffer-scoped
  event subscription (its `buffer_events` is per-buffer, so switching buffers naturally stops the
  callbacks). Our ftplugin's autocmds are BUFFER-LOCAL (`{ buffer = buf }`), so `BufLeave` is the
  explicit analog.

Source: <https://github.com/Saghen/blink.cmp/blob/master/lua/blink/cmp/completion/trigger/init.lua>
(`on_insert_leave`, `on_cursor_moved`, `trigger.hide`).

## 3. The "CursorMoved out of prefix" trigger — ALREADY pi-faithful via S30 (S37 verifies + documents)

The CRITICAL design conclusion. The ftplugin ALREADY wires `CursorMovedI → dispatch("pi-editor.completion",
"refresh", buf)` (S22/S30). When the cursor moves out of a completable position in insert mode:

1. `CursorMovedI` fires → `refresh(buf)` → debounce → `do_refresh` → `getSuggestions` at the NEW cursor.
2. pi's provider returns **`null`** (no completion at that position) → S30 normalizes to `{items={},
   prefix=""}` → `M.on_results(buf, {}, "")` → `menu.on_results` routes empty → `menu.close()`.

So **the menu ALREADY closes pi-faithfully when the cursor leaves the prefix.** This is the
"ask-on-every-change + let-pi-decide" model the completion.lua header enshrines ("NEVER reimplement
pi's logic locally"). The task title lists "CursorMoved out of prefix" because the task tree groups
ALL auto-close under S37 — but the insert-mode cursor case is COVERED by S30's refresh (COMPLETE).

**What S37 ADDS for this trigger:** a TEST that proves it (open menu → move cursor to a
non-completable line → fire `CursorMovedI` → the refresh→empty→`menu.close()` path closes the menu),
and a prominent doc note. **What S37 does NOT add:** a local prefix/keyword-bounds detector (blink's
`within_query_bounds`). Reasons (the codebase's stated principles, §9):
- It would REIMPLEMENT pi's completable-position logic (the `#1` anti-pattern in this codebase:
  "NEVER reimplement pi's logic locally" — completion.lua S33 note (C), and the
  `shouldTriggerFileCompletion`-is-RPC'd-not-local rule).
- It would DIVERGE from the TUI (pi decides; we render).
- blink can afford local bounds because it OWNS the keyword regex; we delegate to pi.

**Residual nuance (harmless):** the refresh path is debounced 25 ms + async RPC, so there is a brief
window where a stale menu shows after a cursor move before pi's empty result closes it. This is
pi-faithful (the TUI re-evaluates on each change too) and is NOT worth a local shortcut.

## 4. The "buffer change" trigger — `BufLeave` autocmd (the singleton-menu hygiene gap)

The menu + completion are SINGLETONS (one per session, PRD §11 — "v1 supports completion in the buffer
that was active at VimEnter"). If the user switches buffers (`:bnext`, `:e file`, `:split` + edit
another) while the menu is open, the floating window would persist over the wrong buffer. `refresh`
does NOT fire on `BufLeave` (only the 3 insert events), so this is a genuine gap.

`BufLeave` (buffer-local, well-supported) fires before leaving the pi-prompt buffer for another →
S37's `on_buf_leave(buf)` → `menu.close()` + `M.reset()` (same teardown as on_insert_leave; clearing
`state.buf`/`last_result` is correct since we left the buffer — the next `refresh` on a future
pi-prompt buffer rebuilds). NEVER throws.

Why `BufLeave` and not `WinLeave`/`BufWinLeave`:
- `BufLeave` is robustly buffer-local (`nvim_create_autocmd("BufLeave", {buffer=buf})` — fires when
  leaving THAT buffer). It covers `:bnext`, `:e`, `:bd`, split-to-another-buffer.
- `WinLeave` is window-scoped and its buffer-local behavior is murkier; PRD §11 already scopes v1 to
  the single VimEnter buffer, so the same-buffer-two-windows edge case is explicitly out of scope.
- `BufWinLeave` (buffer removed from a window) is a superset that also fires on the VimLeave teardown
  path — redundant with the existing `VimLeavePre`/`ExitPre` autosave autocmds (S38's wiring).

## 5. The autocmd wiring (ftplugin) — additive, same augroup, same idempotency

S37 ADDS two buffer-local autocmd registrations in the ftplugin's autocmd block (after the refresh
loop, before the autosave block). They reuse the EXISTING `group` + `dispatch` + the
`nvim_clear_autocmds({buffer=buf, group="pi-editor"})` idempotency line (already in place). NO new
helper, NO new augroup, NO new option.

```lua
-- S37: auto-close the menu when the user leaves the completion context. InsertLeave covers <Esc>/
-- <C-\><C-n>; BufLeave covers :bnext/:e/split-to-another-buffer. CursorMoved-out-of-prefix is handled
-- pi-faithfully by the EXISTING CursorMovedI→refresh→re-fetch→empty→close path (S30, COMPLETE — S37
-- verifies it; no local prefix detector — would reimplement pi). Each cancels the pending refresh so
-- a stale do_refresh cannot re-open the menu in normal mode (research/notes.md §1).
vim.api.nvim_create_autocmd("InsertLeave", {
  group = group, buffer = buf,
  desc = "pi-editor: close completion menu on InsertLeave (cancel pending refresh)",
  callback = function() dispatch("pi-editor.completion", "on_insert_leave", buf) end,
})
vim.api.nvim_create_autocmd("BufLeave", {
  group = group, buffer = buf,
  desc = "pi-editor: close completion menu on BufLeave (buffer change)",
  callback = function() dispatch("pi-editor.completion", "on_buf_leave", buf) end,
})
```

## 6. The handlers (completion.lua) — two thin gates + the shared teardown (reset+close)

Two PUBLIC fire-and-forget handlers (autocmd callbacks; return value ignored), modeled on the
on_enter/on_next gating skeleton but returning nothing (fire-and-forget, NOT a keymap). Each gates
(buf valid) then runs the shared teardown (`menu.close()` + `M.reset()`). NEVER throws (pcall-wrap;
read menu FRESH). The teardown IS the §1 race fix.

```lua
-- the shared teardown: hide the window, then cancel the pending debounce + in-flight RPC + clear
-- state (M.reset sets state.gen=0 so a stale getSuggestions cb's gen-guard drops it — the stale
-- on_results never fires → no normal-mode re-open; research/notes.md §1).
local function hide_and_cancel()
  pcall(function() require("pi-editor.menu").close() end)   -- hide FIRST (immediate UX)
  M.reset()                                                  -- cancel_timer + cancel inflight + gen=0 + clear state
end

--- InsertLeave handler (autocmd-fired). Hides the menu + cancels the pending refresh so a stale
--- do_refresh cannot re-open the menu in normal mode. No-op when the menu is closed + nothing
--- pending (menu.close() / M.reset() are both idempotent + never throw). Never throws.
---@param buf integer The pi-prompt buffer handle (from the buffer-local InsertLeave autocmd).
function M.on_insert_leave(buf)
  if type(buf) ~= "number" or not vim.api.nvim_buf_is_valid(buf) then return end
  hide_and_cancel()
end

--- BufLeave handler (autocmd-fired). Same teardown as on_insert_leave; clearing state.buf/
--- last_result is correct since we left the buffer (the next refresh on a future pi-prompt buffer
--- rebuilds). Never throws.
---@param buf integer The pi-prompt buffer handle (from the buffer-local BufLeave autocmd).
function M.on_buf_leave(buf)
  if type(buf) ~= "number" or not vim.api.nvim_buf_is_valid(buf) then return end
  hide_and_cancel()
end
```

Why NOT also detach the menu (menu.reset): `M.reset()` (completion's) does NOT touch menu.attach —
the `on_results` seam STAYS wired, so re-entering insert / a new pi-prompt buffer re-populates the
menu with no re-attach. `menu.close()` only hides; it does not detach. Correct.

## 7. Why one shared teardown for both events (not two divergent bodies)

`InsertLeave` and `BufLeave` have IDENTICAL correct behavior: hide the menu + cancel any pending
refresh + drop any in-flight cb. The ONLY difference is conceptual (leaving insert vs leaving the
buffer), not behavioral. Two distinct PUBLIC names (`on_insert_leave` / `on_buf_leave`) keep the
ftplugin dispatch + the spec explicit (test each event's wiring), while the shared `hide_and_cancel`
local keeps the bodies DRY. This mirrors how S36's `on_next`/`on_prev` share the gating skeleton.

## 8. Testing strategy

- **completion_spec.lua** (EDIT): add `describe("S37: on_insert_leave / on_buf_leave")` reusing the
  existing `populated_menu(line, byte_col, items, prefix)` helper (S32/S33). Cases:
  (a) populated menu → `on_insert_leave(buf)` → `menu.is_open()==false` + `completion.current()==nil`
      (reset cleared last_result);
  (b) populated menu → `on_buf_leave(buf)` → same;
  (c) **THE RACE FIX** (§1): populated menu → `completion.refresh(buf)` AGAIN (schedules a fresh
      debounce, inflight not yet issued) → IMMEDIATELY `on_insert_leave(buf)` → `vim.wait(debounce*4)`
      → assert the menu did NOT re-open AND `#fake.requests` did NOT increase (the stale do_refresh
      was cancelled); 
  (d) inflight-supersession: resolve a pending request with items AFTER `on_insert_leave` (the cb
      captured an old gen; reset set gen=0) → menu does NOT re-open (gen-guard dropped the cb);
  (e) closed-menu / never-typed → `on_insert_leave(buf)` / `on_buf_leave(buf)` are harmless no-ops;
  (f) never-throws on nil/wiped buf.
- **ftplugin_spec.lua** (EDIT): add to the existing "registers completion autocmds" case (or a new
  case) an assertion that `InsertLeave` + `BufLeave` autocmds are registered in the `"pi-editor"`
  buffer-local group (via `nvim_get_autocmds({buffer=buf, group="pi-editor"})`, mirroring the existing
  InsertEnter/TextChangedI/CursorMovedI assertion). Add a "does not throw when firing InsertLeave/
  BufLeave with completion.lua absent" case (the no-op-safe contract).
- **completion_spec.lua** ALSO add a `describe("S37: CursorMoved-out-of-prefix closes via refresh")`
  case (§3 OWNERSHIP proof): populated menu → set cursor to a different line / out-of-prefix col →
  fire `CursorMovedI` (`nvim_exec_autocmds` or direct `refresh`) → resolve the getSuggestions with
  `{items={}, prefix=""}` → assert `menu.is_open()==false` (the EXISTING S30 path closes it). This
  proves S37 OWNS the third trigger via the pi-faithful mechanism (no local detector).
- **menu_autoclose_smoke.lua** (NEW, plenary-free): real fake-bridge + real bridge.handshake +
  menu.attach. Flow: refresh("/mo") → reply items → menu open → **simulate InsertLeave via
  `nvim_exec_autocmds("InsertLeave", {buffer=buf})`** → assert menu closed + window closed. Then a
  2nd buffer: refresh → menu open → simulate `BufLeave` → menu closed. Then a CursorMovedI-out case:
  menu open → move cursor to a blank line → refresh → reply empty → menu closed (the §3 path).
  Print SMOKE_PASS.

Headless autocmd simulation: `vim.api.nvim_exec_autocmds("InsertLeave", { buffer = buf })` fires the
buffer-local autocmd (its callback dispatches to `on_insert_leave`). This is the plenary-testable
seam (no real keystrokes needed) — same idiom the existing ftplugin_spec uses
(`nvim_exec_autocmds("TextChangedI", {buffer=b})`).

## 9. Gotchas / anti-patterns for the PRP

- **THE #1 bug (§1): a stale `do_refresh` re-opens the menu in normal mode after `<Esc>`** if S37's
  handler does not `cancel_timer()`. `M.reset()` already does this (cancel_timer + bridge.cancel +
  gen=0). S37's handler MUST call it (or equivalent). The spec MUST prove the race is fixed (case (c)).
- **NEVER reimplement a local prefix/keyword-bounds detector** (blink's `within_query_bounds`) — that
  reimplements pi's completable-position logic + diverges from the TUI (the codebase's #1 anti-pattern:
  "NEVER reimplement pi's logic locally"). The "CursorMoved out of prefix" trigger is OWNED by S30's
  refresh (re-fetch → empty → close); S37 verifies + documents it (§3).
- **`on_insert_leave` / `on_buf_leave` are fire-and-forget autocmd callbacks** (return value ignored)
  — they do NOT return a bool (unlike the on_enter/on_next/on_tab KEY handlers). The ftplugin's
  `dispatch` is used only for the no-op-safe-absent-module guarantee.
- **NEVER throw** (autocmd chain contract): pcall the menu.close + M.reset (M.reset is already
  pcall-safe internally, but the handler wraps defensively per the never-throws contract). Read menu
  FRESH (`require("pi-editor.menu")` at call time).
- **Do NOT detach the menu** in the handlers — `M.reset()` (completion) does not touch menu.attach;
  `menu.close()` only hides. The `on_results` seam STAYS wired so re-entry re-populates without
  re-attach.
- **autocmds are BUFFER-LOCAL + same `"pi-editor"` group + `clear=false`** — reuse the existing
  augroup + the `nvim_clear_autocmds({buffer=buf, group=...})` idempotency line (already in place).
  Do NOT create a new augroup (would fragment the shared group + risk the S20 VimEnter autocmd).
- **`BufLeave`, not `WinLeave`/`BufWinLeave`** (§4) — robustly buffer-local; covers buffer switches;
  avoids the VimLeave-teardown redundancy + the murky buffer-local WinLeave semantics.
- **Accept does not race with InsertLeave**: accept's cb (`menu.close()` after buffer-set) is a
  ONE-SHOT user action; the user is still in insert when they press `<CR>`/`<C-Y>`. InsertLeave fires
  AFTER, only if the user then leaves insert — by then accept's cb has already closed the menu, so
  `on_insert_leave`'s `menu.close()` is a harmless no-op. (`nvim_buf_set_lines`/`nvim_win_set_cursor`
  are API mutations — they do NOT fire `InsertLeave`/`TextChangedI`/`CursorMovedI`, per :help, so the
  accept flow never synthesizes an insert-leave. research/notes.md for S32 §5.)
- **AGENTS.md HARD RULE**: write every lua check to a REAL FILE then `+"luafile <path>" +qa`; NEVER
  pipe a heredoc into nvim stdin (it HANGS). Wrap every nvim in `timeout`.
- **assert menu-closed via `menu.is_open()==false` + `menu._state.win==nil`/`not nvim_win_is_valid`**
  (headless-safe — `screenattr` is 0 headlessly, per S34 §4/S35 §5).