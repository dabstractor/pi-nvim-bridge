# Research — P2.M8.T22.S36: Navigation & key handling (C-N/C-P/Up/Down, C-E dismiss, Tab/C-Y/CR accept)

S36 implements the **NAVIGATION + KEY-HANDLING half** of `menu.lua` (PRD §7.5): it adds the
three menu-state mutators (`next`/`prev`/`dismiss`), the three keymap-dispatch handlers
(`on_next`/`on_prev`/`on_dismiss`), and the three MISSING insert-mode keymaps (`<Down>`,
`<Up>`, `<C-Y>`) the ftplugin does not yet wire. The ACCEPT half is ALREADY DONE — `<Tab>`
(`on_tab`, S33) and `<CR>` (`on_enter`, S32) ship today; S36 only ADDS `<C-Y>` (which reuses
the existing `on_enter` accept-or-fall-through handler — §6). S37 (auto-close on
InsertLeave / CursorMoved-out / buffer-change) is a SEPARATE, later task.

## 0. What S31/S34/S35 already ship (the surface S36 builds on) — VERIFIED in-tree

`plugin/lua/pi-editor/menu.lua` (S31 state + S34 window + S35 two-column/highlights) already
implements everything navigation NEEDS to "just work":

- `state` singleton: `{attached, prev_on_results, buf, items, prefix, selected(1-based), open,
  win, menu_buf}`. `selected` is **1-INDEXED** (1 after `open()`, 0 after `close()`).
- **`render(state)` is a LOCAL fn** S34 implemented (scratch buffer + `nvim_open_win` /
  `nvim_win_set_config` in-place + `apply_highlights`). S35 wired `apply_highlights` into its
  SHOW path. **S36's `next()`/`prev()` set `state.selected` then call this LOCAL `render(state)`**
  — they do NOT call `open()` (which RESETS `selected` to 1) or `close()` (which hides).
- `M.open(items)` — items-only; sets `items`, `selected=1`, `open=true`; calls `render(state)`.
- `M.close()` — clears `items={}`, `selected=0`, `open=false`; calls `render(state)` (hide path:
  `nvim_win_close` + `state.win=nil`). Does NOT clear `buf`/`prefix` (only `reset()` does).
- `M.is_open()` → `state.open == true` (only true after `open()` with items, because
  `open()` sets `open=(#items>0)`).
- `M.has_items()` → `#state.items > 0`.
- `M._state = state` — the S34 test seam (specs reach `state.selected`/`win`/`menu_buf`).
- `apply_highlights(state, buf, label_w, desc_w)` (S35, LOCAL) — reads `state.selected` and
  paints `PmenuSel` at row `state.selected - 1` (1-based→0-based) **LAST** (last-wins,
  neovim#8449). It guards `if state.selected >= 1 and state.selected <= n`. ⇒ ANY valid
  selected index (1..n) is honored on the NEXT render. This is the mechanic S36 exploits:
  bump `selected` → `render(state)` → `apply_highlights` repaints `PmenuSel` on the new row.

So S36's menu work is **additive**: 3 PUBLIC mutators + header-comment updates. NO change to
`render`, `apply_highlights`, the state fields, or the geometry helpers.

`plugin/lua/pi-editor/completion.lua` (S30 refresh + S32 accept/on_enter + S33 on_tab) ships:
- `M.accept(item, prefix_override?)` — the core accept (applyCompletion RPC + buffer/cursor).
- `M.on_enter(buf)` — the `<CR>` handler: `return true` iff buf valid+current AND menu
  `is_open()` + `has_items()` + `get_selected()` is a table → `accept(item)`; else `false`
  (the ftplugin feeds `<CR>` literally → a NEWLINE; PRD §7.4 no Enter-to-submit). **This is
  the accept-or-fall-through handler `<C-Y>` will reuse (§6).**
- `M.on_tab(buf)` — pi's handleTabCompletion replication (BRANCH 1 accept / BRANCH 2 fetch).

The handlers' GATING PATTERN (the contract S36's `on_next`/`on_prev`/`on_dismiss` mirror):
```lua
function M.on_enter(buf)
  if type(buf) ~= "number" or not vim.api.nvim_buf_is_valid(buf) then return false end
  if buf ~= vim.api.nvim_get_current_buf() then return false end   -- one buf/session (PRD §11)
  local menu = require("pi-editor.menu")
  if not menu.is_open() or not menu.has_items() then return false end
  local item = menu.get_selected()
  if type(item) ~= "table" then return false end
  return M.accept(item) == true
end
```
`on_next`/`on_prev`/`on_dismiss` copy this gating skeleton (buf valid+current → menu-state
guard → delegate → `return true`), replacing the `accept` call with `menu.next()`/`prev()`/
`dismiss()`. They read `menu` FRESH (`require("pi-editor.menu")` at call time — the codebase
rule: handshake async + tests swap fakes after require + /reload re-runs activate). Never throw
(the ftplugin's `dispatch` is pcall-wrapped, but the handlers are defensive by construction).

`plugin/ftplugin/pi-prompt.lua` (S22) ALREADY wires 6 buffer-local insert keymaps via its
`map_dispatch("i", lhs, modname, fnname)` + `feedkey(lhs)` fall-through helper:
```lua
map_dispatch("i", "<Tab>",   "pi-editor.completion", "on_tab")     -- S33
map_dispatch("i", "<S-Tab>", "pi-editor.completion", "on_prev")    -- S36
map_dispatch("i", "<C-N>",   "pi-editor.completion", "on_next")    -- S36
map_dispatch("i", "<C-P>",   "pi-editor.completion", "on_prev")    -- S36
map_dispatch("i", "<C-E>",   "pi-editor.completion", "on_dismiss") -- S36 (ftplugin comment says S37; see §8)
map_dispatch("i", "<CR>",    "pi-editor.completion", "on_enter")   -- S32
```
**MISSING (PRD §7.5 + the S36 task title): `<Down>`, `<Up>`, `<C-Y>`.** S36 ADDS these three
(§5). Until the handlers land, the existing 3 dispatches (`on_next`/`on_prev`/`on_dismiss`)
return `false` (module field absent → `dispatch` bails) → the keys fall through to their
insert-mode defaults (C-N/C-P keyword-scan, C-E insert-char-below). S36 makes them LIVE.

## 1. The `next()`/`prev()` wraparound arithmetic (1-INDEXED, verified by hand + the spec)

`state.selected` is 1-INDEXED into `state.items` (1..n). The wraparound is the standard
cyclic form, verified for n=1, 2, 3:

```lua
-- next: 1→2→3→1 (for n=3); 1→1 (for n=1)
state.selected = (state.selected % #state.items) + 1
-- prev: 1→3→2→1 (for n=3); 1→1 (for n=1)
state.selected = (state.selected == 1) and #state.items or (state.selected - 1)
```

| #items | start | op | formula | result |
|--------|-------|----|---------|--------|
| 3 | 1 | next | (1%3)+1 | 2 |
| 3 | 2 | next | (2%3)+1 | 3 |
| 3 | 3 | next | (3%3)+1 | 1 (wrap) |
| 3 | 1 | prev | 1 and 3 | 3 (wrap) |
| 3 | 3 | prev | 3-1 | 2 |
| 1 | 1 | next | (1%1)+1 | 1 (no movement) |
| 1 | 1 | prev | 1 and 1 | 1 (no movement) |

Both are pure arithmetic on `state.selected`; both GUARD `if not state.open or #state.items ==
0 then return end` first (so selected is guaranteed 1..n when the math runs — `open()` sets
`selected=1` and `open=(#items>0)`).

## 2. The render-in-place property (S34/S35 already give us no-flicker navigation for free)

Per `plan/001_c56962b4fa17/P2M8T21S34/research/notes.md` §1 (blink.cmp live-verified):
- While the menu is showing, re-calling `render(state)` with a new `state.selected` takes the
  **`state.win` valid → `nvim_win_set_config`** branch — the SAME window id is repositioned/
  resized IN PLACE (no close+reopen, no flicker). S36's `next()`/`prev()` reuse this exact
  path: the cursor does NOT move on a consumed C-N/C-P (the keymap returns `true`), so
  `screenrow()`/`screencol()` are unchanged → `set_config` gets the same geometry → the window
  stays put; only the buffer content (`render_lines` — same items) + the decorations
  (`apply_highlights` — new `PmenuSel` row) change. This is the blink no-flicker guarantee.
- `apply_highlights` (S35) `nvim_buf_clear_namespace(buf, ns, 0, -1)` at its START, then
  repaints base `Pmenu` (every row) + `Comment` (desc ranges) + `PmenuSel` (selected row,
  LAST). ⇒ after `next()` bumps `selected` + `render(state)`, the `PmenuSel` decoration moves
  to the new row (the old selected row reverts to base `Pmenu` only).

**Test strategy (mirrors S35's headless-safe extmark assertion):** assert `hl_groups_on_row`
via `nvim_buf_get_extmarks` (NOT `screenattr` — it's 0 headlessly, per S34 §4/S35 §5), AND
assert the window id is UNCHANGED across `next()`/`prev()` (the in-place proof — `menu._state.win`
before == after). The `with_cursor_window` helper from `menu_spec.lua` (S35) provides the
cursor context the cursor-relative popup needs.

## 3. The `dismiss()` semantics (== `close()`; one-buf/session + pi-faithful re-fetch)

PRD §7.5: `<C-E>` dismiss. The built-in |popup-menu| uses `<C-E>` to dismiss WITHOUT accepting.
In our windowless-state model, "dismiss" = hide the menu + clear the candidate list. That is
EXACTLY what `M.close()` already does (`items={}`, `selected=0`, `open=false`, `render` hide).
There is NO behavioral difference between dismiss and close in the pi-faithful "ask on every
change" model: after dismiss, the user's next keystroke fires `TextChangedI` → `refresh` → a
fresh `getSuggestions` → `on_results` → `open`/`close`. Re-showing a stale cached list would
DIVERGE from the TUI. ⇒ **`M.dismiss()` forwards to `M.close()`** (DRY; satisfies the
documented `M.next/prev/dismiss` contract from menu.lua's header — dismiss EXISTS as a public
name; its body reuses `close()`). An inline copy (`state.items={}; state.selected=0;
state.open=false; render(state)`) is equivalent; the forwarder is recommended.

NOTE (why dismiss does NOT clear `buf`/`prefix`): `close()` leaves `state.buf`/`state.prefix`
intact (only `reset()` clears them). That is correct — dismiss is a UI hide, not a teardown;
the latest result context survives for the (unlikely) window between dismiss and the next fetch.

## 4. The completion handler pattern (gate → delegate → bool; mirrors on_enter/on_tab)

S36 adds THREE handlers to `completion.lua`, each a thin gate that delegates to the menu:

```lua
function M.on_next(buf)
  if type(buf) ~= "number" or not vim.api.nvim_buf_is_valid(buf) then return false end
  if buf ~= vim.api.nvim_get_current_buf() then return false end   -- one buf/session
  local menu = require("pi-editor.menu")                            -- READ FRESH
  if not menu.is_open() or not menu.has_items() then return false end
  menu.next()
  return true   -- key CONSUMED (C-N/Down does NOT move the cursor)
end
-- on_prev: symmetric (menu.prev()); same guards.
-- on_dismiss: guard on is_open() ONLY (has_items is implied by open()'s contract; we want to
--   hide whatever's showing); then menu.dismiss(); return true.
```

**Return contract (matches on_enter/on_tab):** `true` ⇒ the ftplugin CONSUMES the key (no
fall-through); `false` ⇒ `dispatch` feeds the literal key (C-N keyword-scan, Down cursor-move,
C-E insert-char-below, etc. — the user's normal insert-mode behavior when no menu is up).
`on_next`/`on_prev` return `true` ONLY when the menu is open+has-items (so the key navigates);
`on_dismiss` returns `true` ONLY when the menu is open (so C-E dismisses). When closed, ALL
return `false` → the keys behave normally. Never throw (type-guards + `nvim_buf_is_valid` + the
ftplugin's pcall). Read `menu` FRESH at call time (the codebase rule — §0).

**Why `buf == current` for navigation (it doesn't read buffer lines/cursor):** consistency +
safety. The menu is a singleton tied to `state.buf`; navigation makes sense only while the user
is in the pi-prompt buffer (the one buf/session, PRD §11). If a future multi-window setup ever
left the menu's `buf` != the current window's buffer, bailing (return `false`) is the safe
choice — it never navigates a menu the user can't see. The cost is nil (the guard is 2 lines).

## 5. The MISSING keymaps — `<Down>`, `<Up>`, `<C-Y>` (PRD §7.5)

PRD §7.5 lists the menu keys explicitly: "`<C-N>`/`<Down>` next, `<C-P>`/`<Up>` prev, `<C-E>`
dismiss, `<Tab>`/`<C-Y>`/`<CR>` accept." The ftplugin wires the FIRST six (`<C-N>`,`<C-P>`,
`<S-Tab>`,`<C-E>`,`<Tab>`,`<CR>`) but NOT `<Down>`,`<Up>`,`<C-Y>`. S36 ADDS:
```lua
map_dispatch("i", "<Down>", "pi-editor.completion", "on_next")   -- arrow: next item (mirrors <C-N>)
map_dispatch("i", "<Up>",   "pi-editor.completion", "on_prev")   -- arrow: prev item (mirrors <C-P>)
map_dispatch("i", "<C-Y>",  "pi-editor.completion", "on_enter")  -- accept (mirrors <CR>'s accept half)
```
- `<Down>`/`<Up>`: when the menu is OPEN, `on_next`/`on_prev` return `true` → arrow navigates
  the menu (does NOT move the text cursor); when CLOSED, they return `false` → `feedkey` feeds
  the literal arrow → normal cursor movement. This is the expected UX (arrows move the cursor
  normally until a menu appears, then navigate it).
- `<C-Y>`: reuses `on_enter` (the accept-or-fall-through handler — §6). When OPEN, `on_enter`
  returns `true` → `accept`; when CLOSED, returns `false` → `feedkey("<C-Y>")` → `:help i_CTRL-Y`
  (insert char from line below) — a rare, harmless default. `<C-Y>` in our plugin is NOT the
  built-in popupmenu (we render a custom float), so there is no conflict with the built-in
  popupmenu accept. PRD §7.5 groups `<C-Y>` with the accept keys; `on_enter` IS the accept.

The ftplugin's `map_dispatch` + `feedkey` fall-through machinery (S22) already handles all of
this — S36 only ADDS three `map_dispatch` lines. No new helper, no new option.

## 6. The `<C-Y>` → `on_enter` reuse decision (NO new `on_accept` handler)

Could S36 add a dedicated `on_accept(buf)`? NO — and it should NOT, because:
- The ftplugin's documented FORWARD CONTRACTS (lines 18–27) name exactly FIVE handlers:
  `on_tab`, `on_enter`, `on_next`, `on_prev`, `on_dismiss`. There is no `on_accept`.
- `on_enter(buf)` is ALREADY the "accept-when-menu-open, fall-through-otherwise" handler. Its
  ONLY consumer-specific behavior is the FALL-THROUGH key, which the ftplugin supplies
  (`feedkey("<CR>")` vs `feedkey("<C-Y>")`) — `on_enter` itself just returns `true`/`false`.
  So `<C-Y>` → `on_enter` is semantically exact: accept if the menu is open, else pass through.
- Adding `on_accept` would duplicate `on_enter`'s body + add a 6th handler to the contract for
  no behavioral gain. Reuse wins (minimal surface, the codebase's stated value).

`<CR>` and `<C-Y>` therefore share `on_enter`; the ONLY difference is the fall-through literal
(CR→newline, C-Y→i_CTRL-Y), which is the ftplugin's job. This is correct + minimal.

## 7. The on_dismiss ownership: S36, NOT S37 (task-tree vs ftplugin-comment discrepancy)

The ftplugin's inline comment says `<C-E>` → `on_dismiss` is "(S37)". The TASK TREE disagrees:
- **S36**: "Navigation & key handling — C-N/C-P/Up/Down, C-E dismiss, Tab/C-Y/CR accept".
- **S37**: "Auto-close on InsertLeave, CursorMoved out of prefix, buffer change".

So `on_dismiss` (the KEY handler, driven by `<C-E>`) is **S36** — it's a keypress handler, in
the same family as `on_next`/`on_prev`. S37 is the AUTOCMD-driven auto-close (InsertLeave /
CursorMoved-out-of-prefix / buffer-change), which will call `menu.close()`/`reset()` from
autocmd callbacks — NOT a keypress. The ftplugin's "(S37)" label is a minor doc imprecision
carried over from when the split was less clear. **S36 implements `menu.dismiss()` +
`completion.on_dismiss(buf)`** and corrects the ftplugin comment to "(S36)". S37 later wires
the auto-close AUTOCMDS (a separate, additive change that calls the already-shipped `close()`
+ `reset()` — no new menu/completion API).

## 8. Testing strategy (state + re-render for menu; gate+delegate for completion; keymap count for ftplugin; a nav smoke)

- **menu_spec.lua** (EDIT): add a `describe("S36: navigation")` block using the existing
  `with_cursor_window` helper (S35) so the cursor-relative popup has a context. Cases:
  (a) `next()` advances `state.selected` 1→2→3 + moves `PmenuSel` to the new row (via
  `hl_groups_on_row` extmarks) + the window id is UNCHANGED (in-place proof);
  (b) `next()` wraparound 3→1;
  (c) `prev()` 1→3 (wraparound) + 3→2;
  (d) n=1: `next()`/`prev()` keep selected=1 (no movement, no throw);
  (e) `dismiss()` → `is_open()==false`, `selected==0`, window INVALID, `state.win==nil`;
  (f) `next()`/`prev()`/`dismiss()` when CLOSED → no-op, no throw, no window created;
  (g) `next()`/`prev()` on `open({})` (defensive) → no-op, no throw.
- **completion_spec.lua** (EDIT): add a `describe("S36: on_next/on_prev/on_dismiss")` block
  using the existing `populated_menu`/`closed_menu` helpers (S32/S33). Cases: open-menu
  `on_next(buf)`→true + `menu._state.selected` advances; `on_prev(buf)`→true + retreats;
  `on_dismiss(buf)`→true + `menu.is_open()==false`; closed-menu all three → `false`; non-current
  buf → `false`; never-throws on nil/wiped buf.
- **ftplugin_spec.lua** (EDIT): UPDATE the "registers the 6 insert keymaps" case → "9 insert
  keymaps" (add `<Down>`, `<Up>`, `<C-Y>` to the asserted list). The desc-prefix check
  (`:sub(1,11) == "pi-editor: "`) stays.
- **menu_nav_smoke.lua** (NEW, plenary-free): mirror `menu_smoke.lua`'s fake-server bootstrap;
  populate the menu via `refresh`+reply (3 items); `on_next(buf)` cycle (1→2→3→1) asserting
  `menu._state.selected` + the `PmenuSel` extmark row + window-id-unchanged; `on_prev(buf)`
  retreat + wraparound; `on_dismiss(buf)` → menu closed + window closed. Prints SMOKE_PASS.

## 9. Gotchas / anti-patterns for the PRP

- **NEVER call `open()` from `next()`/`prev()`** — `open()` RESETS `selected` to 1. Bump
  `state.selected` then call the LOCAL `render(state)` (the documented S36 contract).
- **`render` is LOCAL** — `next()`/`prev()`/`dismiss()` are defined IN menu.lua, so they call
  `render(state)` directly (no `M._render` exposure needed; do NOT widen the public surface).
- **1-based `selected`, 0-based nvim rows** — `apply_highlights` already does `selected - 1`;
  S36's arithmetic stays in 1-based `selected` space (the wraparound formulas in §1).
- **next/prev/dismiss MUST NEVER throw** — they run inside an autocmd chain + a per-keystroke
  keymap. Guard `state.open`/`#items` first; `render` is already pcall-safe (S34/S35).
- **Read `menu` FRESH** in the completion handlers (`require("pi-editor.menu")` at call time) —
  the codebase rule (handshake async + test fakes + /reload).
- **`<C-Y>` reuses `on_enter`** (§6) — do NOT add `on_accept`. The only consumer-specific
  behavior (the fall-through literal) is the ftplugin's job.
- **on_dismiss is S36** (§7) — correct the ftplugin's "(S37)" comment to "(S36)".
- **dismiss == close** (§3) — forward, do NOT clear `buf`/`prefix`.
- **AGENTS.md HARD RULE** — write every lua check to a REAL FILE then `+"luafile <path>" +qa`;
  NEVER pipe a heredoc into nvim stdin (it HANGS). Wrap every nvim in `timeout`.
- **assert extmarks, NOT `screenattr`** (S34 §4/S35 §5 — `screenattr` is 0 headlessly).
- **do NOT implement S37** (auto-close autocmds) — S36 is the KEY handlers + the 3 keymaps only.