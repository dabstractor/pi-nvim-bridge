# PRP — P2.M8.T22.S36: Navigation & key handling — C-N/C-P/Up/Down, C-E dismiss, Tab/C-Y/CR accept

**Parent task:** P2.M8.T22 (menu.lua — navigation, key handling & lifecycle)
**Module:** P2.M8 (Floating Completion Menu / `menu.lua`) — Neovim (Lua) side
**Plan path:** `plan/001_c56962b4fa17/P2M8T22S36/`
**Scope:** ONLY S36 (the NAVIGATION + KEY-HANDLING half). S31 (state), S34 (window), S35
(two-column/highlights) are **COMPLETE**; S37 (auto-close on InsertLeave / CursorMoved-out /
buffer-change) is a **SEPARATE, later task — do NOT implement it.** The ACCEPT half is also
ALREADY DONE — `<Tab>` (`on_tab`, S33) and `<CR>` (`on_enter`, S32) ship today; S36 only ADDS
`<C-Y>` (which REUSES the existing `on_enter` accept-or-fall-through handler — no new accept code).

---

## Goal

**Feature Goal:** Make the floating completion menu **navigable and dismissible from the
keyboard** with the exact key set PRD §7.5 specifies (`<C-N>`/`<Down>` next,
`<C-P>`/`<Up>` prev, `<C-E>` dismiss, and `<C-Y>` accept), by adding the three missing
menu-state mutators (`next`/`prev`/`dismiss`), the three keymap-dispatch handlers
(`on_next`/`on_prev`/`on_dismiss`), and the three ftplugin keymaps the plugin does not yet wire
(`<Down>`, `<Up>`, `<C-Y>`). Navigation re-renders the popup **in place** (no flicker) by
bumping `state.selected` and calling the already-shipped LOCAL `render(state)` — so
`apply_highlights` (S35) repaints the `PmenuSel` decoration on the newly selected row. Because
the handlers gate on menu state and return `true` (consume) only when the menu is open, every
key falls through to its normal insert-mode default (cursor move, keyword scan, etc.) when no
menu is showing.

**Deliverable:**
1. In `plugin/lua/pi-editor/menu.lua` (an EXISTING file — **edit, do not rewrite**):
   - ADD three PUBLIC mutators in the Public API section:
     - `M.next()` — guard `state.open and #state.items > 0`; `state.selected =
       (state.selected % #state.items) + 1` (1-indexed wraparound); call the LOCAL `render(state)`.
     - `M.prev()` — same guard; `state.selected = (state.selected == 1) and #state.items or
       (state.selected - 1)`; call the LOCAL `render(state)`.
     - `M.dismiss()` — forward to `M.close()` (DRY; clears items/selected/open + hides the
       window via render's hide path; leaves `buf`/`prefix` intact).
   - UPDATE the menu.lua header comment: mark `M.next/prev/dismiss` as S36-IMPLEMENTED (they
     are currently listed as a forward contract) + cite `research/notes.md` §1–§3.
2. In `plugin/lua/pi-editor/completion.lua` (an EXISTING file — **edit, do not rewrite**):
   - ADD three keymap-dispatch handlers (mirror the `on_enter`/`on_tab` gating skeleton):
     - `M.on_next(buf)` — gate (buf valid+current + `menu.is_open()` + `menu.has_items()`) →
       `menu.next()` → `return true`; else `return false`.
     - `M.on_prev(buf)` — symmetric, delegating to `menu.prev()`.
     - `M.on_dismiss(buf)` — gate (buf valid+current + `menu.is_open()`) → `menu.dismiss()` →
       `return true`; else `return false`.
   - UPDATE the completion.lua header comment: mark `on_next/on_prev/on_dismiss` as S36-SHIPPED.
3. In `plugin/ftplugin/pi-prompt.lua` (an EXISTING file — **edit, do not rewrite**):
   - ADD three buffer-local insert keymaps (the existing `map_dispatch` helper handles consume
     + `feedkey(lhs)` fall-through): `<Down>`→`on_next`, `<Up>`→`on_prev`, `<C-Y>`→`on_enter`.
   - CORRECT the existing `<C-E>` line comment from "(S37)" to "(S36)" (on_dismiss is S36; the
     auto-close AUTOCMDS are S37) + extend the FORWARD CONTRACTS doc to list `<Up>`/`<Down>`/`<C-Y>`.
4. UPDATE `plugin/tests/menu_spec.lua` (plenary) — ADD a `describe("S36: navigation")` block:
   `next()`/`prev()` advance/retreat/wrap `state.selected`, move the `PmenuSel` extmark to the
   new row (assert via `nvim_buf_get_extmarks`, NOT `screenattr`), and leave the window id
   UNCHANGED (in-place proof); `dismiss()` closes; all three no-op when closed (no throw).
5. UPDATE `plugin/tests/completion_spec.lua` (plenary) — ADD a `describe("S36:
   on_next/on_prev/on_dismiss")` block: open-menu handlers return `true` + delegate; closed-menu
   / non-current-buf → `false`; never-throws on nil/wiped buf.
6. UPDATE `plugin/tests/ftplugin_spec.lua` (plenary) — CHANGE the "registers the 6 insert
   keymaps" case to assert **9** keymaps (add `<Down>`, `<Up>`, `<C-Y>`).
7. CREATE `plugin/tests/menu_nav_smoke.lua` (plenary-free) — real-bridge + populated menu (3
   items) → `on_next(buf)` cycles 1→2→3→1 (selected + `PmenuSel` row + window-id-unchanged) →
   `on_prev(buf)` retreat + wraparound → `on_dismiss(buf)` closes the menu + window.

**Success Definition:**
- With the menu open, `<C-N>`/`<Down>` advance the selection (and reposition `PmenuSel` to the
  new row IN PLACE — same window id, no flicker); `<C-P>`/`<Up>` retreat; all wrap around at the
  ends; `<C-E>` dismisses (closes the menu + window); `<C-Y>` accepts (reuses `on_enter`).
- With the menu closed, ALL of those keys fall through to their normal insert-mode defaults
  (arrows move the cursor; `<C-N>`/`<C-P>` keyword-scan; `<C-E>` insert-char-below; `<C-Y>`
  `:help i_CTRL-Y`) — the handlers return `false`.
- `next()`/`prev()`/`dismiss()` + `on_next`/`on_prev`/`on_dismiss` NEVER throw (they run inside
  an autocmd chain + per-keystroke keymaps); bad args / wiped buf / closed menu are silent no-ops.
- `menu.open(items)` then `next()`/`prev()` REUSE the S34 window (id unchanged) and the S35
  `apply_highlights` repaints `PmenuSel` on the new row — S36 adds NO new window/highlight code.
- The full test suite (`menu_spec`, `completion_spec`, `ftplugin_spec`, `menu_nav_smoke`, +
  every sibling spec/smoke) runs green headlessly; the plugin stays dormant in non-pi nvim sessions.

---

## All Needed Context

### Context Completeness Check

> "If someone knew nothing about this codebase, would they have everything needed to implement this successfully?"

**Yes.** This PRP embeds: the exact files to edit (`menu.lua`, `completion.lua`,
`ftplugin/pi-prompt.lua`), the exact functions to add (`menu.next/prev/dismiss`,
`completion.on_next/on_prev/on_dismiss`) + the exact 3 keymaps to add (`<Down>`,`<Up>`,`<C-Y>`),
the **live-verified** wraparound arithmetic (the §1 table), the gating skeleton to copy from
`on_enter`, the in-place render property (S34/S35 give no-flicker navigation for free), the
`<C-Y>` → `on_enter` reuse rationale, the on_dismiss-is-S36 ownership clarification, and the
exact validation commands. The implementing agent edits THREE existing files using
copy-paste-ready reference implementations + adapts three test files + adds one smoke. There is
NO new window/highlight/IPC code — S36 is purely additive state + dispatch.

### Documentation & References

```yaml
# ── THIS PRP's research (READ FIRST — the consolidated evidence) ──
- file: plan/001_c56962b4fa17/P2M8T22S36/research/notes.md
  why: The consolidated S36 research: the S31/S34/S35 baseline S36 builds on (§0), the
       verified wraparound arithmetic (§1), the render-in-place property (§2 — no flicker for
       free), the dismiss==close semantics (§3), the handler gating pattern (§4), the missing
       keymaps (§5), the <C-Y>→on_enter reuse decision (§6), the on_dismiss-is-S36 ownership
       (§7), the testing strategy (§8), the gotchas (§9).
  critical: §1 (the 1-indexed wraparound formulas), §2 (call the LOCAL render — NOT open(),
       which resets selected), §6 (NO on_accept — reuse on_enter), §7 (on_dismiss is S36 not S37).

# ── PRIOR PRPs (the S34/S35 baseline contracts S36 builds on) ──
- file: plan/001_c56962b4fa17/P2M8T21S35/PRP.md
  why: Documents the S35 two-column + highlight layer (the apply_highlights that S36's navigation
       re-triggers by re-rendering) + the AGENTS.md HARD RULE + the codebase test conventions
       (pure helpers vs integration; plenary spec vs plenary-free smoke; minimal_init.lua bootstrap).
- file: plan/001_c56962b4fa17/P2M8T21S34/PRP.md
  why: Documents the S34 window lifecycle S36 reuses — render() in-place set_config branch (no
       flicker), scratch-buffer reuse, the no-op-safe hide path. Navigation bumps selected then
       calls this same render().

# ── THE FILES YOU EDIT (read fully first) ──
- file: plugin/lua/pi-editor/menu.lua
  why: S36 ADDS M.next/prev/dismiss. Read: the state singleton (selected is 1-BASED), the LOCAL
       render(state) (S34 — the show path calls render_lines + apply_highlights + set_config),
       apply_highlights (S35 — paints PmenuSel at state.selected - 1, honors any 1..n selected),
       open()/close() (close() is the dismiss body), M.is_open()/has_items()/_state (the gates +
       test seam). The header lists "M.next/prev/dismiss → S36 (navigation) set selected + call
       render()" as the forward contract S36 fulfills.
  pattern: M.close() (the dismiss body); M.open(items) (selected=1 + render — DO NOT call from
       next/prev, it resets selected); the Public API section (where next/prev/dismiss go).
- file: plugin/lua/pi-editor/completion.lua
  why: S36 ADDS on_next/on_prev/on_dismiss. Read: M.on_enter(buf) (THE gating skeleton to copy —
       buf valid+current + menu.is_open()/has_items() + delegate + return bool) + M.on_tab(buf)
       (the other keymap handler) + M.accept (on_enter delegates to it). Read menu FRESH.
  pattern: the on_enter gate (lines ~"function M.on_enter(buf)"); the S33 on_tab block (the model
       for a new describe'd S36 section). The header notes on_next/on_prev/on_dismiss are forward.
- file: plugin/ftplugin/pi-prompt.lua
  why: S36 ADDS 3 map_dispatch lines (<Down>,<Up>,<C-Y>) + corrects the <C-E> "(S37)"→"(S36)"
       comment. Read: map_dispatch("i", lhs, modname, fnname) + feedkey(lhs) (the consume/fall-through
       machinery S22 ships) + the 6 existing keymaps. <C-Y> reuses on_enter (NOT a new handler).
  pattern: the existing `map_dispatch("i", "<C-N>", "pi-editor.completion", "on_next")` line;
       the FORWARD CONTRACTS doc block (lines ~18–27).

# ── THE DRIVER (confirm next/prev re-render api-safe + per-keystroke) ──
- file: plugin/lua/pi-editor/completion.lua
  why: on_next/on_prev/on_dismiss are vim.keymap.set('i',…) callbacks → run on the nvim MAIN LOOP
       (api-safe — same contract as on_enter/on_tab/do_refresh). menu.next() calls the LOCAL
       render(state) which is pcall-safe (S34/S35). The ftplugin's dispatch pcall-wraps the handler.
  pattern: on_enter/on_tab are the api-safe keymap-handler models (NO vim.schedule wrapper needed).

# ── Neovim API docs (anchor-cited) ──
- url: https://neovim.io/doc/user/intro.html#popup-menu
  why: The built-in popupmenu key convention S36 mimics in a custom float: <C-N>/<C-P>/<Up>/<Down>
       navigate, <C-E> dismiss, <C-Y>/<CR>/<Tab> accept (PRD §7.5). Our menu is NOT a real
       popupmenu (custom float) so there is no conflict — but the key conventions match user habit.
- url: https://neovim.io/doc/user/insert.html#i_CTRL-Y
  why: <C-Y>'s insert-mode default when our menu is CLOSED (the fall-through) = "insert the char
       from the line below". Harmless; the handler returns false → feedkey("<C-Y>") runs this.
- url: https://neovim.io/doc/user/api.html#nvim_buf_get_extmarks()
  why: nvim_buf_get_extmarks(buf, ns, {row,0}, {row,-1}, {details=true}) enumerates the
       decorations on a row (with hl_group) — the HEADLESS-SAFE PmenuSel-moved assertion
       (screenattr()=0 headlessly — S34 §4/S35 §5). Reused from menu_spec's S35 helper.
- url: https://neovim.io/doc/user/api.html#nvim_win_set_config()
  why: render()'s "window valid? set_config : open_win" branch (S34) — the no-flicker in-place
       reposition/resize S36's next/prev reuse (the cursor does not move on a consumed C-N/C-P).
```

### Current Codebase tree (the files S36 touches)

```bash
plugin/
  lua/pi-editor/
    menu.lua          # ← EDIT: ADD M.next/prev/dismiss (Public API section); update header
    completion.lua    # ← EDIT: ADD M.on_next/on_prev/on_dismiss (new S36 section); update header
  ftplugin/
    pi-prompt.lua     # ← EDIT: ADD <Down>/<Up>/<C-Y> keymaps; fix <C-E> "(S37)"→"(S36)" comment
  tests/
    menu_spec.lua           # ← EDIT: ADD describe("S36: navigation") block
    completion_spec.lua     # ← EDIT: ADD describe("S36: on_next/on_prev/on_dismiss") block
    ftplugin_spec.lua       # ← EDIT: "6 keymaps" → "9 keymaps" (add Down/Up/C-Y)
    menu_nav_smoke.lua      # ← CREATE: plenary-free nav smoke (real bridge + populated menu)
    minimal_init.lua        # (read-only) plenary harness bootstrap (reuse as-is)
  plugin/pi-editor.lua       # (read-only) VimEnter shim
# NO new runtime modules. NO init.lua change. NO new config option.
```

### Desired Codebase tree (the change footprint)

```bash
plugin/
  lua/pi-editor/menu.lua              # MODIFIED — +M.next/M.prev/M.dismiss (3 public mutators)
  lua/pi-editor/completion.lua        # MODIFIED — +M.on_next/M.on_prev/M.on_dismiss (3 handlers)
  ftplugin/pi-prompt.lua              # MODIFIED — +<Down>/<Up>/<C-Y> (3 keymaps); <C-E> comment fix
  tests/menu_spec.lua                 # MODIFIED — +S36 navigation block (existing cases stay green)
  tests/completion_spec.lua           # MODIFIED — +S36 handler block (existing cases stay green)
  tests/ftplugin_spec.lua             # MODIFIED — 6→9 keymaps assertion
  tests/menu_nav_smoke.lua            # NEW — plenary-free nav smoke (SMOKE_PASS)
# No other files touched. No S37 (auto-close autocmds). No new accept code.
```

### Known Gotchas of our codebase & Neovim quirks

```lua
-- CRITICAL (the #1 bug): NEVER call M.open() from next()/prev(). open() RESETS state.selected
-- to 1 (and rebuilds items). next()/prev() BUMP state.selected then call the LOCAL render(state)
-- DIRECTLY. render re-applies render_lines (same items) + apply_highlights (new PmenuSel row) +
-- set_config (in-place, no flicker). This is the documented S36 contract (menu.lua header).

-- CRITICAL: render(state) is a LOCAL fn. next()/prev()/dismiss() are defined IN menu.lua, so they
-- call render(state) directly — do NOT expose M._render (do NOT widen the public surface).

-- CRITICAL (1-based ↔ 0-indexed): state.selected is 1-BASED (1 after open(), 0 after close()).
-- The wraparound formulas stay in 1-based space (research/notes.md §1):
--   next: state.selected = (state.selected % #state.items) + 1
--   prev: state.selected = (state.selected == 1) and #state.items or (state.selected - 1)
-- apply_highlights (S35) ALREADY converts to 0-based (state.selected - 1) internally — do NOT
-- re-convert in next/prev.

-- CRITICAL: dismiss() FORWARDS to close() (DRY). close() clears items/selected/open + render
-- (hide path: nvim_win_close + state.win=nil). Do NOT clear state.buf/state.prefix (only reset()
-- does) — dismiss is a UI hide, not a teardown. An inline copy of close's body is equivalent.

-- CRITICAL (on_dismiss is S36, NOT S37): the ftplugin's <C-E> comment says "(S37)" — that is a
-- stale label. on_dismiss (the KEY handler) is S36; S37 is the auto-close AUTOCMDS
-- (InsertLeave/CursorMoved-out/buffer-change) that call close()/reset() later. Correct the comment.

-- CRITICAL (NO on_accept): <C-Y> REUSES on_enter (the accept-or-fall-through handler). on_enter
-- returns true (accept) when menu open+selected, false otherwise. For <C-Y>, false → feedkey("<C-Y>")
-- → :help i_CTRL-Y (harmless). Do NOT add a 6th handler — the ftplugin's forward contract names 5.

-- CRITICAL: the handlers return true ONLY when the menu is open (+has_items for next/prev), so the
-- key is CONSUMED; otherwise false → the ftplugin feeds the literal key (arrows move the cursor,
-- C-N/C-P keyword-scan, etc. — normal insert-mode behavior when no menu is up).

-- CRITICAL: next/prev/dismiss + on_next/on_prev/on_dismiss MUST NEVER throw (per-keystroke keymap +
-- autocmd chain). Guard state.open/#items first (next/prev); type-guard + nvim_buf_is_valid
-- (handlers). render is already pcall-safe (S34/S35). Read menu FRESH in the handlers
-- (require("pi-editor.menu") at call time — handshake async + test fakes + /reload).

-- CRITICAL (headless testing): assert PmenuSel MOVED via nvim_buf_get_extmarks (NOT screenattr —
-- it's 0 headlessly, S34 §4/S35 §5). Assert the window id is UNCHANGED across next()/prev()
-- (menu._state.win before == after — the in-place no-flicker proof).

-- CRITICAL (AGENTS.md HARD RULE): NEVER pipe a heredoc / stdin into nvim — it HANGS the session.
-- Write every lua test/check to a REAL FILE, then +"luafile <path>" +qa. Wrap every nvim in timeout.
```

---

## Implementation Blueprint

### `menu.next()` / `menu.prev()` / `menu.dismiss()` — NEW public mutators (menu.lua)

Add these in the **Public API section** of `menu.lua` (after `M.is_open()`/`M.has_items()`, near
`M.close()`). They call the LOCAL `render(state)` (NOT `open()`, which resets `selected`).

```lua
-- ===========================================================================
-- S36: navigation mutators (next/prev/dismiss). Each is a thin STATE change that calls the
-- LOCAL render(state) — render re-applies render_lines (same items) + apply_highlights (new
-- PmenuSel row) + set_config (in-place, no flicker). next/prev bump state.selected (1-based
-- wraparound); dismiss forwards to close(). The completion handlers on_next/on_prev/on_dismiss
-- gate + delegate to these. NEVER throws (guards first; render is pcall-safe).
-- ===========================================================================

--- Advance the selection to the NEXT item (1-indexed wraparound), re-rendering in place.
--- No-op (never throws) when the menu is closed/empty. The cursor does NOT move (the handler
--- consumes the key), so render's set_config repositions to the SAME place — no flicker.
function M.next()
  if not state.open or #state.items == 0 then return end          -- guard (never throws)
  state.selected = (state.selected % #state.items) + 1            -- 1→2→…→n→1 (1-indexed wrap)
  render(state)                                                   -- LOCAL render: repaint PmenuSel in place
end

--- Retreat the selection to the PREVIOUS item (1-indexed wraparound), re-rendering in place.
--- No-op (never throws) when the menu is closed/empty.
function M.prev()
  if not state.open or #state.items == 0 then return end
  state.selected = (state.selected == 1) and #state.items or (state.selected - 1)  -- 1→n→…→2→1
  render(state)
end

--- Dismiss the menu (hide + clear the candidate list). Forwards to M.close() (identical
--- semantics in the pi-faithful "ask on every change" model — the next keystroke re-fetches).
--- Does NOT clear state.buf/state.prefix (only reset() does). Never throws.
function M.dismiss()
  M.close()                                                        -- items={}; selected=0; open=false; render hide
end
```

> **Why `dismiss()` forwards to `close()`** (research/notes.md §3): there is no behavioral
> difference in the pi-faithful model — both hide + clear; re-show always re-fetches. The
> forwarder satisfies the documented `M.next/prev/dismiss` contract (menu.lua header) without
> duplicating `close()`'s body. An inline copy is equivalent; the forwarder is recommended.

### `completion.on_next(buf)` / `on_prev(buf)` / `on_dismiss(buf)` — NEW handlers (completion.lua)

Add a new **S36 section** after the `on_tab` block. Each mirrors the `on_enter`/`on_tab` gating
skeleton: buf valid+current → menu-state guard → delegate → `return bool`. Read `menu` FRESH.

```lua
-- ===========================================================================
-- S36: on_next(buf) / on_prev(buf) / on_dismiss(buf) — the navigation/dismiss keymap handlers.
-- The ftplugin ALREADY dispatches <C-N>/<Down>→on_next, <S-Tab>/<C-P>/<Up>→on_prev,
-- <C-E>→on_dismiss. Each gates like on_enter/on_tab (buf valid+current + menu state) and
-- delegates to menu.next/prev/dismiss. Returns true (key CONSUMED) only when the menu is open;
-- false → the ftplugin feeds the literal key (normal insert-mode behavior). Never throws
-- (type-guards + nvim_buf_is_valid; the ftplugin's dispatch is also pcall-wrapped). Read menu
-- FRESH (require at call time — handshake async + test fakes + /reload). API-safe (main loop).
-- ===========================================================================

--- The `<C-N>`/`<Down>` handler (the ftplugin ALREADY dispatches on_next). Returns true (key
--- consumed) iff buf is valid+current AND the menu is open with items → menu.next(). Otherwise
--- false (the key falls through to its default). Never throws.
---@param buf integer The pi-prompt buffer handle (from the buffer-local keymap dispatch).
---@return boolean handled true iff the key was consumed (selection advanced).
function M.on_next(buf)
  if type(buf) ~= "number" or not vim.api.nvim_buf_is_valid(buf) then return false end
  if buf ~= vim.api.nvim_get_current_buf() then return false end    -- one buf/session (PRD §11)
  local menu = require("pi-editor.menu")                            -- READ FRESH
  if not menu.is_open() or not menu.has_items() then return false end
  menu.next()
  return true                                                       -- key CONSUMED (cursor does NOT move)
end

--- The `<S-Tab>`/`<C-P>`/`<Up>` handler. Symmetric to on_next → menu.prev(). Never throws.
---@param buf integer The pi-prompt buffer handle.
---@return boolean handled true iff the key was consumed (selection retreated).
function M.on_prev(buf)
  if type(buf) ~= "number" or not vim.api.nvim_buf_is_valid(buf) then return false end
  if buf ~= vim.api.nvim_get_current_buf() then return false end
  local menu = require("pi-editor.menu")
  if not menu.is_open() or not menu.has_items() then return false end
  menu.prev()
  return true
end

--- The `<C-E>` handler (the ftplugin ALREADY dispatches on_dismiss). Returns true (key consumed)
--- iff buf is valid+current AND the menu is open → menu.dismiss(). Otherwise false (C-E falls
--- through to :help i_CTRL-Y… actually i_CTRL-E insert-char-below). Never throws. (on_dismiss is
--- S36 — the KEY handler; the auto-close AUTOCMDS are S37. research/notes.md §7.)
---@param buf integer The pi-prompt buffer handle.
---@return boolean handled true iff the key was consumed (menu dismissed).
function M.on_dismiss(buf)
  if type(buf) ~= "number" or not vim.api.nvim_buf_is_valid(buf) then return false end
  if buf ~= vim.api.nvim_get_current_buf() then return false end
  local menu = require("pi-editor.menu")
  if not menu.is_open() then return false end                       -- has_items implied by open()'s contract
  menu.dismiss()
  return true
end
```

### The 3 ftplugin keymaps + the comment fix (ftplugin/pi-prompt.lua)

In the **Keymaps** section, ADD three `map_dispatch` lines (after the existing `<CR>` line) +
CORRECT the `<C-E>` comment:

```lua
-- ── Keymaps (insert-mode, buffer-local; PRD §7.6) ──────────────────────────────
map_dispatch("i", "<Tab>",   "pi-editor.completion", "on_tab")     -- trigger / accept the menu (S33)
map_dispatch("i", "<S-Tab>", "pi-editor.completion", "on_prev")    -- previous completion item (S36)
map_dispatch("i", "<C-N>",   "pi-editor.completion", "on_next")    -- next completion item (S36)
map_dispatch("i", "<C-P>",   "pi-editor.completion", "on_prev")    -- previous completion item (S36)
map_dispatch("i", "<C-E>",   "pi-editor.completion", "on_dismiss") -- dismiss the completion menu (S36)
map_dispatch("i", "<CR>",    "pi-editor.completion", "on_enter")   -- accept-or-newline (S32); no Enter-to-submit (PRD §7.4)
-- S36: the PRD §7.5 full key set — arrows navigate; <C-Y> accepts (reuses on_enter).
map_dispatch("i", "<Down>",  "pi-editor.completion", "on_next")    -- next completion item (S36; mirrors <C-N>)
map_dispatch("i", "<Up>",    "pi-editor.completion", "on_prev")    -- previous completion item (S36; mirrors <C-P>)
map_dispatch("i", "<C-Y>",   "pi-editor.completion", "on_enter")   -- accept (S36; reuses on_enter's accept-or-fall-through)
```

Also extend the ftplugin's **FORWARD CONTRACTS** doc block (lines ~18–27) to note `<Up>`/`<Down>`
mirror `<C-P>`/`<C-N>` and `<C-Y>` reuses `on_enter` (accept). And change the `on_dismiss` line's
`-- <C-E>: dismiss the menu (S37).` to `(S36)`.

### Implementation Tasks (ordered by dependencies)

```yaml
Task 1: READ the 3 files you edit + the S36 research + the prior PRPs
  - READ FULLY: plugin/lua/pi-editor/menu.lua (state singleton — selected is 1-BASED; the LOCAL
    render(state); apply_highlights reads state.selected; open() RESETS selected=1 — DO NOT call
    from next/prev; close() is the dismiss body; M.is_open()/has_items()/_state).
  - READ FULLY: plugin/lua/pi-editor/completion.lua (M.on_enter/on_tab — THE gating skeleton to
    copy; M.accept; "read menu FRESH" rule; the S33 on_tab section as the model for a new S36 block).
  - READ FULLY: plugin/ftplugin/pi-prompt.lua (map_dispatch + feedkey; the 6 existing keymaps; the
    FORWARD CONTRACTS doc block; the stale "(S37)" comment on <C-E>).
  - READ: plan/001_c56962b4fa17/P2M8T22S36/research/notes.md (§0 baseline, §1 arithmetic, §2
    render-in-place, §3 dismiss==close, §4 gating, §5 keymaps, §6 <C-Y>→on_enter, §7 ownership, §9 gotchas).

Task 2: ADD M.next/prev/dismiss to menu.lua (Public API section, near M.close())
  - ADD the 3 functions EXACTLY as the reference impl (next/prev: guard → bump selected (1-based
    wraparound) → LOCAL render(state); dismiss: forward to M.close()).
  - GUARD next/prev on `not state.open or #state.items == 0` (so selected is 1..n for the math).
  - VERIFY next/prev call the LOCAL render (NOT open — open resets selected). NEVER throws.
  - UPDATE the menu.lua header: mark "M.next/prev/dismiss → S36 IMPLEMENTED" + cite research §1–§3.

Task 3: ADD M.on_next/on_prev/on_dismiss to completion.lua (new S36 section after on_tab)
  - ADD the 3 handlers EXACTLY as the reference impl (gate like on_enter: buf valid+current →
    menu-state guard → delegate → return bool). Read menu FRESH. NEVER throws.
  - on_next/on_prev guard on is_open()+has_items(); on_dismiss guards on is_open() only.
  - UPDATE the completion.lua header: mark on_next/on_prev/on_dismiss as S36-SHIPPED (they are
    currently listed as forward contracts for S36/S37).

Task 4: ADD the 3 ftplugin keymaps + fix the <C-E> comment (ftplugin/pi-prompt.lua)
  - ADD: map_dispatch("i","<Down>",...,"on_next"); map_dispatch("i","<Up>",...,"on_prev");
    map_dispatch("i","<C-Y>",...,"on_enter"). (map_dispatch + feedkey already handle consume/fall-through.)
  - CHANGE the <C-E> line comment "(S37)" → "(S36)".
  - EXTEND the FORWARD CONTRACTS doc block: <Up>/<Down> mirror <C-P>/<C-N>; <C-Y> reuses on_enter
    (accept); on_dismiss is S36 (auto-close AUTOCMDS are S37).

Task 5: SMOKE-VERIFY navigation in isolation (before touching specs) — a REAL FILE (AGENTS.md)
  - WRITE /tmp/menu_s36_check.lua: rtp+=plugin; setup({}); with a cursor window, menu.open(3 items);
    assert selected==1 + PmenuSel@row0; menu.next() → selected==2 + PmenuSel@row1 + win UNCHANGED;
    menu.next() → selected==3 + PmenuSel@row2; menu.next() → selected==1 (wrap) + PmenuSel@row0;
    menu.prev() → selected==3 (wrap); menu.dismiss() → is_open()==false + win INVALID; menu.next()
    when closed → no-op (no throw). Run:
    timeout 60 nvim --headless --clean -u NORC +"luafile /tmp/menu_s36_check.lua" +qa ; echo "exit=$?"

Task 6: UPDATE plugin/tests/menu_spec.lua — ADD describe("S36: navigation")
  - REUSE the existing with_cursor_window(fn) + hl_groups_on_row(buf, ns, row0) helpers (S35).
  - ADD: open(3 items)→selected==1,PmenuSel@row0; next()→selected==2,PmenuSel@row1,PmenuSel NOT @row0,
    menu._state.win UNCHANGED (in-place); next()→selected==3,PmenuSel@row2; next()→selected==1 (wrap);
    prev()→selected==3 (wrap); prev()→selected==2; n=1 next()/prev()→selected stays 1 (no throw);
    dismiss()→is_open()==false,selected==0,win INVALID,win==nil; next()/prev()/dismiss() when CLOSED
    → no-op, no throw, no window created; next()/prev() on open({}) → no-op, no throw.
  - KEEP cases 1–31 UNCHANGED (S36 is purely additive; existing state/window/highlight cases stay green).

Task 7: UPDATE plugin/tests/completion_spec.lua — ADD describe("S36: on_next/on_prev/on_dismiss")
  - REUSE the existing populated_menu(line,col,items,prefix) + closed_menu(...) helpers (S32/S33).
  - ADD: populated→on_next(buf)==true + menu._state.selected advances (1→2); on_prev(buf)==true +
    retreats; on_dismiss(buf)==true + menu.is_open()==false; closed_menu→on_next/on_prev/on_dismiss all
    return false; non-current buf → false; never-throws on nil/wiped buf (on_next(nil)/on_next("x")/
    on_next(wiped-buf)).
  - KEEP the S30/S32/S33 cases UNCHANGED.

Task 8: UPDATE plugin/tests/ftplugin_spec.lua — "6 keymaps" → "9 keymaps"
  - CHANGE the asserted keymap list from { "<Tab>","<S-Tab>","<C-N>","<C-P>","<C-E>","<CR>" } to
    ALSO include { "<Down>","<Up>","<C-Y>" } (9 total). The desc-prefix check (:sub(1,11)=="pi-editor: ")
    stays. Rename the case "registers the 9 insert keymaps with 'pi-editor:' desc".

Task 9: CREATE plugin/tests/menu_nav_smoke.lua — plenary-free nav smoke
  - MIRROR menu_smoke.lua's fake-server bootstrap (fake luv socket + REAL bridge.handshake +
    menu.attach() + completion.refresh(buf) + a getSuggestions reply with 3 items).
  - FLOW 1 (next cycle): menu populated (3 items, selected==1) → on_next(buf)==true → assert
    menu._state.selected==2 + PmenuSel extmark on row 1 (via nvim_buf_get_extmarks) + menu._state.win
    UNCHANGED → on_next→selected==3→on_next→selected==1 (wraparound).
  - FLOW 2 (prev + wraparound): on_prev(buf)==true → selected==3 (wrap from 1) → on_prev→selected==2.
  - FLOW 3 (dismiss): on_dismiss(buf)==true → menu.is_open()==false + menu._state.win==nil (closed).
  - FLOW 4 (closed fall-through): on_next/on_prev/on_dismiss on a closed menu → false (no throw).
  - Print SMOKE_PASS / exit 0. Plenary-free (AGENTS.md: +"luafile …" +qa, NOT stdin).

Task 10: RUN the full validation suite (see Validation Loop) + fix until green
  - RUN: menu_spec.lua, completion_spec.lua, ftplugin_spec.lua, menu_nav_smoke.lua (the changed/new
    files), THEN every sibling spec/smoke (menu_geometry_spec, menu_smoke, completion_*smoke,
    bridge_*, coords_*, init_*, ftplugin_smoke, shim_*, activate_*, jsonlreader_*, smoke). All green.
```

### Implementation Patterns & Key Details

```lua
-- PATTERN: the gating skeleton (copy from on_enter/on_tab — research/notes.md §4):
--   if type(buf)~="number" or not nvim_buf_is_valid(buf) then return false end
--   if buf ~= nvim_get_current_buf() then return false end          -- one buf/session (PRD §11)
--   local menu = require("pi-editor.menu")                          -- READ FRESH
--   if not menu.is_open() or not menu.has_items() then return false end  -- (dismiss: is_open() only)
--   menu.next() / menu.prev() / menu.dismiss()
--   return true
-- PATTERN: next/prev bump state.selected then call the LOCAL render(state) — render re-applies
--   render_lines + apply_highlights (new PmenuSel row) + set_config (in-place, no flicker). The
--   cursor does NOT move on a consumed key, so set_config gets the same geometry → window stays put.
-- PATTERN: assert PmenuSel MOVED via extmarks (headless-safe); assert win id UNCHANGED (in-place):
local function hl_groups_on_row(buf, ns, row0)  -- reuse menu_spec's S35 helper
  local out = {}
  for _, mk in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns, {row0,0}, {row0,-1}, {details=true})) do
    if mk[4] and mk[4].hl_group then out[mk[4].hl_group] = true end
  end
  return out
end
-- GOTCHA: NEVER call open() from next/prev — it resets selected to 1. Call the LOCAL render.
-- GOTCHA: state.selected is 1-based; nvim rows are 0-based — apply_highlights already does -1.
-- GOTCHA: dismiss forwards to close() — do NOT clear buf/prefix (only reset() does).
-- GOTCHA: <C-Y> REUSES on_enter (NO on_accept). on_dismiss is S36 (NOT S37 — fix the comment).
-- GOTCHA (AGENTS.md): heredoc→file is fine; heredoc→nvim stdin HANGS. Wrap nvim in timeout.
```

### Integration Points

```yaml
CONFIG (read-only, NO change):
  - source: plugin/lua/pi-editor/init.lua M.defaults.menu { max_height, border } — read by render
    (S34). S36 adds NO config option (the key set is fixed by PRD §7.5; no debounce/timing added).

STATE (S31, read-only contract — S36 only WRITES state.selected via next/prev):
  - state.selected (1-based): next/prev bump it; dismiss (via close) resets to 0.
  - state.items / state.open: next/prev guard on them; dismiss (via close) clears them.
  - state.win / state.menu_buf: S34 owns; next/prev re-render keeps win; close (dismiss) nils win.

SEAM (NO completion.lua wiring change):
  - menu.attach() (S31) ALREADY wires completion.on_results → menu.on_results. S36's on_next/on_prev/
    on_dismiss are NEW top-level M fields the ftplugin dispatches to (the forward contract S22 named).
    NO change to refresh/accept/on_enter/on_tab. NO change to on_results.

KEYMAPS (the ONLY ftplugin change — 3 new map_dispatch lines):
  - <Down>→on_next, <Up>→on_prev, <C-Y>→on_enter. The existing <C-N>/<C-P>/<S-Tab>/<C-E>/<Tab>/<CR>
    lines are UNCHANGED (the <C-E> comment is corrected S37→S36). map_dispatch + feedkey (S22) handle
    consume + fall-through. No new helper.

TESTING HARNESS (reuse, no change):
  - Plenary spec: plugin/tests/minimal_init.lua (sets rtp to plugin/ + plenary).
  - Smoke: plenary-free, self-bootstraps rtp (the menu_smoke/menu_nav_smoke pattern).
```

---

## Validation Loop

> **CRITICAL (AGENTS.md HARD RULE):** write every lua snippet to a REAL FILE then run
> `+"luafile <path>" +qa`. NEVER pipe a heredoc into nvim stdin (it HANGS). ALWAYS wrap nvim
> in `timeout`. Run from the `plugin/` directory.

### Level 1: Syntax & Style (after editing menu.lua + completion.lua + the ftplugin)

```bash
cd /home/dustin/projects/pi-nvim-bridge/plugin
# load/syntax check via a FILE (NOT stdin):
cat > /tmp/s36_loadcheck.lua <<'LUA'
for _, f in ipairs({ "lua/pi-editor/menu.lua", "lua/pi-editor/completion.lua", "ftplugin/pi-prompt.lua" }) do
  local ok, err = loadfile(f)
  assert(ok, f .. " syntax error: " .. tostring(err))
end
print("S36_LOAD_OK")
LUA
timeout 30 nvim --headless --clean -u NORC +"luafile /tmp/s36_loadcheck.lua" +qa ; echo "exit=$?"
# Expected: S36_LOAD_OK, exit 0. (If selene/stylua config exists, also run them per repo convention.)
```

### Level 2: Unit Tests (plenary) — navigation state + handler gates + the 9 keymaps

```bash
cd /home/dustin/projects/pi-nvim-bridge/plugin
# menu.next/prev/dismiss (state + in-place re-render + PmenuSel-moved + wraparound + guards):
timeout 90 nvim --headless --clean -u tests/minimal_init.lua \
  -c 'lua require("plenary.busted").run("tests/menu_spec.lua")' ; echo "exit=$?"
# on_next/on_prev/on_dismiss (gate + delegate + closed/non-current → false + never-throws):
timeout 90 nvim --headless --clean -u tests/minimal_init.lua \
  -c 'lua require("plenary.busted").run("tests/completion_spec.lua")' ; echo "exit=$?"
# the 9 insert keymaps (<Down>/<Up>/<C-Y> added; the 6 existing stay):
timeout 90 nvim --headless --clean -u tests/minimal_init.lua \
  -c 'lua require("plenary.busted").run("tests/ftplugin_spec.lua")' ; echo "exit=$?"
# Expected: all three exit 0, every case passes. Read the output + fix before proceeding.
```

### Level 3: Smoke (plenary-free, real bridge + real completion + real menu — navigation end-to-end)

```bash
cd /home/dustin/projects/pi-nvim-bridge/plugin
# The NEW navigation smoke: fake server → populated menu (3 items) → on_next cycle + PmenuSel moves +
# win-unchanged → on_prev + wraparound → on_dismiss closes → closed fall-through.
timeout 60 nvim --headless --clean -u NORC +"luafile tests/menu_nav_smoke.lua" +qa ; echo "exit=$?"
# Expected: SMOKE_PASS, exit 0.
# ALSO re-run the existing menu smoke (S36 must not regress it):
timeout 60 nvim --headless --clean -u NORC +"luafile tests/menu_smoke.lua" +qa ; echo "exit=$?"
# Expected: SMOKE_PASS, exit 0.
```

### Level 4: Regression — S36 must break NOTHING in sibling modules

```bash
cd /home/dustin/projects/pi-nvim-bridge/plugin
for spec in menu_spec menu_geometry_spec completion_spec completion_accept_smoke completion_tab_smoke \
            completion_smoke bridge_spec bridge_smoke bridge_handshake_spec bridge_request_spec \
            bridge_notify_spec coords_spec coords_smoke init_spec activate_spec activate_smoke \
            ftplugin_spec ftplugin_smoke shim_spec shim_smoke jsonlreader_spec jsonlreader_smoke smoke; do
  if [[ -f "tests/${spec}.lua" ]]; then
    if grep -q "plenary" "tests/${spec}.lua" 2>/dev/null; then
      timeout 90 nvim --headless --clean -u tests/minimal_init.lua \
        -c "lua require(\"plenary.busted\").run(\"tests/${spec}.lua\")" || echo "SPEC FAIL: ${spec}"
    else
      timeout 60 nvim --headless --clean -u NORC +"luafile tests/${spec}.lua" +qa || echo "SMOKE FAIL: ${spec}"
    fi
  fi
done
echo "REGRESSION_DONE"
# Expected: no SPEC FAIL / SMOKE FAIL lines. Every spec/smoke green.
```

### Level 4b: The navigation-isolation check (the "does PmenuSel actually move in place?" proof)

```bash
# A REAL file (AGENTS.md: heredoc→file is fine; heredoc→nvim stdin is NOT). Proves next/prev move
# PmenuSel in place (same window id) + dismiss closes — with NO bridge.
cat > /tmp/menu_s36_e2e.lua <<'LUA'
vim.opt.runtimepath:append("/home/dustin/projects/pi-nvim-bridge/plugin")
local pi = require("pi-editor"); if pi.config == nil then pi.setup({}) end
local menu = require("pi-editor.menu")
-- a real cursor window so the cursor-relative popup has a context
local cbuf = vim.api.nvim_create_buf(true, false)
local cwin = vim.api.nvim_open_win(cbuf, true, {relative="editor",row=1,col=1,width=60,height=6,border="none"})
vim.api.nvim_buf_set_lines(cbuf,0,-1,false,{"/mo"})
vim.wo[cwin].virtualedit="onemore"; vim.api.nvim_win_set_cursor(cwin,{1,3})

local ns = vim.api.nvim_create_namespace("pi-editor-menu")
local function sel_row()  -- the 0-based row carrying PmenuSel, or nil
  for r = 0, 9 do
    local out = {}
    for _, mk in ipairs(vim.api.nvim_buf_get_extmarks(menu._state.menu_buf, ns, {r,0}, {r,-1}, {details=true})) do
      if mk[4] and mk[4].hl_group == "PmenuSel" then out.PmenuSel = true end
    end
    if out.PmenuSel then return r end
  end
  return nil
end

menu.open({
  { value="/model", label="/model", description="Switch the model" },
  { value="/mood",  label="/mood",  description="Set the mood" },
  { value="/more",  label="/more",  description="More" },
})
vim.wait(30, function() end)
assert(menu._state.selected == 1, "selected==1 after open")
assert(sel_row() == 0, "PmenuSel at row 0 (selected-1)")
local win0 = menu._state.win
assert(vim.api.nvim_win_is_valid(win0), "window valid after open")

-- next 1→2: PmenuSel moves to row 1; window UNCHANGED (in-place)
menu.next()
assert(menu._state.selected == 2, "next: selected==2")
assert(sel_row() == 1, "next: PmenuSel moved to row 1")
assert(menu._state.win == win0, "next: window id UNCHANGED (in-place, no flicker)")
-- next 2→3
menu.next()
assert(menu._state.selected == 3 and sel_row() == 2, "next: selected==3, PmenuSel@row2")
-- next 3→1 (wraparound)
menu.next()
assert(menu._state.selected == 1 and sel_row() == 0, "next wrap: selected==1, PmenuSel@row0")
-- prev 1→3 (wraparound)
menu.prev()
assert(menu._state.selected == 3 and sel_row() == 2, "prev wrap: selected==3, PmenuSel@row2")
-- prev 3→2
menu.prev()
assert(menu._state.selected == 2 and sel_row() == 1, "prev: selected==2, PmenuSel@row1")

-- dismiss: menu closed + window closed + selected==0
menu.dismiss()
assert(not menu.is_open(), "dismiss: menu closed")
assert(menu._state.selected == 0, "dismiss: selected==0")
assert(not vim.api.nvim_win_is_valid(win0), "dismiss: window closed")
assert(menu._state.win == nil, "dismiss: state.win nil")

-- n=1 wraparound (no movement, no throw)
menu.open({ { value="/x", label="/x" } })
vim.wait(20, function() end)
menu.next(); assert(menu._state.selected == 1, "n=1 next: stays 1")
menu.prev(); assert(menu._state.selected == 1, "n=1 prev: stays 1")

-- next/prev/dismiss when CLOSED → no-op, no throw, no window
menu.close()
assert(not menu.is_open())
menu.next(); menu.prev(); menu.dismiss()
assert(not menu.is_open(), "closed: nav no-ops do not reopen")
assert(menu._state.win == nil, "closed: nav no-ops create no window")

pcall(vim.api.nvim_win_close, cwin, true); pcall(vim.api.nvim_buf_delete, cbuf, {force=true})
pcall(menu.reset)
print("MENU_S36_E2E_PASS")
LUA
timeout 60 nvim --headless --clean -u NORC +"luafile /tmp/menu_s36_e2e.lua" +qa ; echo "exit=$?"
# Expected: MENU_S36_E2E_PASS, exit 0. (PmenuSel moves in place; wraparound; dismiss closes.)
```

---

## Final Validation Checklist

### Technical Validation
- [ ] Level 1 load/syntax check passes (exit 0) for menu.lua, completion.lua, ftplugin/pi-prompt.lua.
- [ ] `tests/menu_spec.lua` passes: cases 1–31 UNCHANGED + new S36 navigation cases green
      (next/prev advance/retreat/wrap, PmenuSel moves via extmarks, win id UNCHANGED, dismiss closes,
      closed/open({}) guards no-op without throwing).
- [ ] `tests/completion_spec.lua` passes: S30/S32/S33 cases UNCHANGED + new S36 handler cases green
      (open→true+delegate; closed/non-current→false; never-throws).
- [ ] `tests/ftplugin_spec.lua` passes: the 9-keymap assertion (Down/Up/C-Y added; the 6 existing stay).
- [ ] `tests/menu_nav_smoke.lua` passes (SMOKE_PASS; real-bridge nav cycle + PmenuSel-moved + dismiss).
- [ ] `tests/menu_smoke.lua` still passes (SMOKE_PASS; S36 regresses nothing).
- [ ] `/tmp/menu_s36_e2e.lua` prints MENU_S36_E2E_PASS (in-place PmenuSel move + wraparound + dismiss).
- [ ] Regression: every sibling spec/smoke green (no SPEC FAIL / SMOKE FAIL).

### Feature Validation
- [ ] With the menu open: `<C-N>`/`<Down>` advance + move `PmenuSel` IN PLACE (win id unchanged);
      `<C-P>`/`<Up>` retreat; both wrap at the ends; `<C-E>` dismisses (closes menu+window); `<C-Y>`
      accepts (reuses `on_enter`).
- [ ] With the menu closed: all those keys fall through to their insert-mode defaults (handlers return false).
- [ ] `next()`/`prev()` advance `state.selected` (1-based) and re-render via the LOCAL `render(state)`
      (NOT `open()`); `dismiss()` forwards to `close()` (clears items/selected/open; leaves buf/prefix).
- [ ] n=1: `next()`/`prev()` keep `selected==1` (no movement, no throw).
- [ ] `next()`/`prev()`/`dismiss()` + `on_next`/`on_prev`/`on_dismiss` never throw on bad args / wiped
      buf / closed menu (silent no-op or `return false`).

### Code Quality Validation
- [ ] `menu.next/prev/dismiss` are PUBLIC; they call the LOCAL `render(state)` (NOT exposed as
      `M._render`). `next`/`prev` use the 1-based wraparound arithmetic; `dismiss` forwards to `close`.
- [ ] `completion.on_next/on_prev/on_dismiss` mirror the `on_enter`/`on_tab` gating skeleton (buf
      valid+current + menu-state guard + delegate + bool); `menu` read FRESH at call time.
- [ ] The ftplugin ADDS exactly 3 keymaps (`<Down>`,`<Up>`,`<C-Y>`) via the existing `map_dispatch`;
      the `<C-E>` comment is corrected S37→S36; NO new helper/option.
- [ ] No new runtime dependencies (only `vim.api`/`vim.fn` already used); NO new config option.
- [ ] NO new accept code (`<C-Y>` reuses `on_enter`); NO new window/highlight code (reuses S34/S35).
- [ ] Follows the codebase's Mode-A header + research-citation conventions (update menu.lua +
      completion.lua headers to note S36 shipped; cite research/notes.md §1–§7).
- [ ] Test snippets are real files (AGENTS.md: never heredoc→nvim stdin); nvim wrapped in `timeout`.

### Documentation & Scope Discipline
- [ ] Did NOT implement S37 (auto-close on InsertLeave/CursorMoved-out/buffer-change autocmds).
- [ ] Did NOT change the state layer (`open`/`close`/`reset`/`on_results`/`get_*`), geometry helpers,
      `render`, or `apply_highlights` (S36 only ADDS next/prev/dismiss + reads state.selected).
- [ ] Did NOT modify `init.lua`, the bridge, `coords.lua`, or the refresh/accept/on_enter/on_tab flows.
- [ ] Did NOT add a new config option (the key set is fixed by PRD §7.5).
- [ ] Did NOT touch PRD.md, tasks.json, prd_snapshot.md, or any plan/* PRP other than this one.

---

## Anti-Patterns to Avoid

- ❌ Don't call `M.open()` from `next()`/`prev()` — it RESETS `selected` to 1. Bump `state.selected`
  then call the LOCAL `render(state)` (the documented S36 contract).
- ❌ Don't expose `M._render` or otherwise widen the menu's public surface to call render — `next`/
  `prev`/`dismiss` are defined IN menu.lua and call the LOCAL `render(state)` directly.
- ❌ Don't forget the 1-based `state.selected` (next/prev arithmetic stay 1-based; `apply_highlights`
  already does `selected - 1` for the 0-based nvim row).
- ❌ Don't reimplement `dismiss()` — forward to `close()` (DRY; identical semantics). Don't clear
  `buf`/`prefix` in dismiss (only `reset()` does).
- ❌ Don't add a 6th handler `on_accept` for `<C-Y>` — REUSE `on_enter` (the accept-or-fall-through
  handler). The fall-through literal is the ftplugin's job.
- ❌ Don't let `next`/`prev`/`dismiss` or `on_next`/`on_prev`/`on_dismiss` throw (per-keystroke keymap
  + autocmd chain) — guard state/menu first; the ftplugin's `dispatch` is also pcall-wrapped.
- ❌ Don't read `menu` at module load in the completion handlers — `require("pi-editor.menu")` FRESH
  at call time (handshake async + test fakes + /reload).
- ❌ Don't assert `screenattr(...)` in tests (it's 0 headlessly) — assert `PmenuSel` MOVED via
  `nvim_buf_get_extmarks` + assert the window id is UNCHANGED (the in-place proof).
- ❌ Don't implement the auto-close AUTOCMDS (InsertLeave/CursorMoved-out/buffer-change) — that's S37.
  S36 ships only the KEY handlers (`on_dismiss`) + the menu mutators + the 3 keymaps.
- ❌ Don't change `on_enter`/`on_tab`/`accept`/`refresh` or the state/window/highlight layers — S36 is
  purely additive (3 menu fns + 3 handlers + 3 keymaps).
- ❌ Don't pipe a heredoc into nvim stdin (it HANGS — AGENTS.md HARD RULE). Write test lua to a real
  file, then `+"luafile <path>" +qa`; wrap nvim in `timeout`.

---

## Confidence Score: 9/10

**Why high:** Every mechanism S36 uses is **already shipped + live-verified** by prior tasks:
- The 1-based `state.selected` + the LOCAL `render(state)` (S34) + `apply_highlights` honoring any
  `selected` 1..n (S35) — navigation is a pure state bump + a re-render through existing, tested code.
- The `on_enter`/`on_tab` gating skeleton (S32/S33) — the new handlers are mechanical copies.
- The `map_dispatch` + `feedkey` consume/fall-through machinery (S22) — the 3 new keymaps are 3 lines.
- The no-flicker in-place reposition (S34's `set_config` branch) — navigation reuses it for free
  (the cursor doesn't move on a consumed key).
The wraparound arithmetic is verified by hand (the §1 table) + the Level-4b e2e check. S36 has NO
new window/highlight/IPC/accept code — it is purely additive state + dispatch, building on four
COMPLETE, tested tasks. The backward-compat analysis (notes.md §0) shows every existing menu/completion/
ftplugin case stays green because S36 only ADDS public functions + keymaps + test blocks.

**Residual risk (the 1 point):** the precise "in-place, no flicker" guarantee depends on render's
`set_config` branch being called with an unchanged cursor position during a consumed C-N/C-P — which
holds by construction (the keymap returns `true`, so nvim does not advance the cursor), and the
Level-4b e2e asserts the window id is UNCHANGED across `next()`/`prev()`. If a future nvim version
fires a spurious `CursorMovedI` on the keymap return, the menu would re-fetch (harmless — it re-renders
to the same position). Also, the exact extmark-assertion shape (`mk[4].hl_group`) is pinned by the
Level-4b e2e (reusing menu_spec's S35 helper) before the spec relies on it.