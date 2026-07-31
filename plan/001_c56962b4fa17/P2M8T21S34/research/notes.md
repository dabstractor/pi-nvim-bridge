# Research — P2.M8.T21.S34: Floating window creation with cursor-relative positioning & edge clamping

S34 implements the **WINDOW half** of `menu.lua` (PRD §7.5): it replaces S31's local
no-op `render(state)` stub with a real floating window — scratch buffer + `nvim_open_win` /
`nvim_win_set_config` + cursor-relative positioning + edge clamping. S35 (the NEXT task)
enhances the rendering to two-column label/description + highlight selected row; S34 only
needs basic label-only line content so the window has something to show.

## 0. What S31 already ships (the surface S34 builds on) — VERIFIED in-tree

`plugin/lua/pi-editor/menu.lua` (S31, COMPLETE) is a **windowless menu-STATE module**
(blink.cmp `list.lua` model). It already implements:

- `state` singleton: `{attached, prev_on_results, buf, items, prefix, selected, open, win, menu_buf}`.
  **`win` and `menu_buf` are FORWARD-CONTRACT fields left `nil` until S34.**
- `render(state)` — a **LOCAL no-op stub** (`local render = function(_state) end`) that S31's
  `open()` and `close()` already call. **S34 EDITS THIS LOCAL fn to create/draw/close the
  floating window.** (Per S31's header: "S34 will EDIT menu.lua to implement it
  (`nvim_create_buf` + `nvim_open_win` + `nvim_buf_set_lines`).")
- `M.open(items)` — items-only signature; sets `state.items`, `state.selected=1`,
  `state.open=true`, then calls `render(state)`.
- `M.close()` — clears items, `state.selected=0`, `state.open=false`, then calls `render(state)`.
- `M.reset()` — `close()` + `detach()` + clears `buf`/`prefix`/`win`/`menu_buf` (teardown seam).
- `M.on_results(buf, items, prefix)` — the S30 seam consumer: empty→`close()`, non-empty→`open(items)`.
  Called on the nvim main loop (api-safe — see completion.lua's `do_refresh` cb).

So S34's work is **additive**: implement `render(state)` + add the pure geometry helpers +
manage the `state.win`/`state.menu_buf` lifecycle. **Do NOT rewrite the state layer.**

## 1. The window lifecycle pattern (blink.cmp VERIFIED at base commit 78336bc)

Researched the local blink.cmp checkout (`lua/blink/cmp/completion/windows/menu.lua` +
`lua/blink/cmp/lib/window/init.lua`). Authoritative findings:

- **Scratch buffer: create ONCE, reuse.** blink caches the buffer (`get_buf()` →
  `nvim_create_buf(false, true)` — listed=false, scratch=true). On hide it keeps the buffer;
  the next open reuses it.
- **Window: CLOSE on hide, RECREATE on next open (reusing the buffer).** blink does
  `nvim_win_close(id, true)` + `self.id=nil` on hide, then `nvim_open_win` again on the next
  show (same cached buffer).
- **Reposition/resize IN PLACE while open.** While a menu is showing, each cursor move calls
  `nvim_win_set_config` (+ `nvim_win_set_width/height`) on the SAME window id — **no
  close+reopen, no flicker.** This is the critical no-flicker property.

**Mapping to S34's `render(state)`:**
- **open path** (`state.open==true`, items present):
  - `_ensure_buf()`: if `state.menu_buf` nil/invalid → `nvim_create_buf(false, true)` + set
    buf options; store on `state.menu_buf`. (Reuse across opens.)
  - set buffer lines (`nvim_buf_set_lines`) — basic label-only content for S34.
  - compute geometry (pure `compute_geometry`, §3).
  - if `state.win` valid → `nvim_win_set_config(win, cfg)` (in-place reposition/resize).
  - else → `state.win = nvim_open_win(state.menu_buf, false, cfg)` (create).
  - set window-local options (`wrap=false`, …) via `nvim_set_option_value(…, {win=win})`.
- **close path** (`state.open==false`):
  - if `state.win` valid → `nvim_win_close(win, true)`.
  - `state.win = nil`. **Keep `state.menu_buf` for reuse** (S31's `reset()` already nils it).

> Because S31's `on_results` re-runs `open(items)` → `render(state)` on every non-empty
> result (the cursor may have moved between fetches), the open-path's "window valid?
> set_config : open_win" branch gives the no-flicker reposition for free — exactly blink's
> pattern. close() → `nvim_win_close` + reuse buffer matches blink's hide.

## 2. nvim_open_win config + window options (VERIFIED)

- **Config keys:** `relative = "cursor"`, `anchor` (see §3), `row`, `col` (may be NEGATIVE
  to shift left), `width`, `height`, `style = "minimal"`, `border` (from config:
  `"rounded"` default), `noautocmd = true` (suppress WinEnter/BufEnter for the scratch win),
  `zindex = 100`. blink omits `focusable`/`anchor`; this PRP ADDS `anchor` + `focusable=false`
  + `noautocmd=true` (the dependency-free best-practice shape — `:help nvim_open_win`).
- **`relative="cursor"` is NORMALIZED to `relative="win"` by `nvim_win_get_config`** (GOTCHA A
  from the live-verified prototype): opening with `relative="cursor"` at cursor
  winline=20/wincol=51 → `nvim_win_get_config` shows `relative="win", win=<handle>, row=20,
  col=50`. **Tests must NOT assert `cfg.relative == "cursor"`** — assert `width`/`height`/
  `anchor` instead, and assert positioning via the PURE `compute_geometry` (deterministic).
- **`border` in get_config is a TABLE** (chars) even when you pass `"rounded"` — don't
  string-compare `cfg.border`.
- **Window options:** use `nvim_set_option_value(opt, val, { win = win })` (non-deprecated,
  forward-proof; `nvim_win_set_option` still works on 0.12 but is the older form). Set
  `wrap=false` (single-line entries; CJK-safe). `focusable=false` is in the open_win config.
- **`nvim_win_set_config` reconfigures an EXISTING float IN PLACE** (same window id, no
  destroy/recreate, no flicker) and accepts the same config keys — VERIFIED. Always pass the
  full config including `relative`.
- **API refs:** `:help nvim_open_win`, `:help nvim_win_set_config`, `:help nvim_create_buf`,
  `:help nvim_win_close` — https://neovim.io/doc/user/api.html.

## 3. The positioning/clamping algorithm (LIVE-VERIFIED prototype, EXACT)

From `plan/001_c56962b4fa17/P2M5T1S1/research/positioning-math.md` + `live-verification.md`
(the earlier research for this same work; the prototype ran green: `MENU_VERIFY_PASS 0`).
The numbers below are EXACT outputs of a live-verified `compute_geometry` prototype.

**Inputs (read live in `render`, passed to the PURE helpers):**
- `screen_row = vim.fn.screenrow()` — cursor's screen row, 1-based from top of screen.
- `screen_col = vim.fn.screencol()` — cursor's screen col, 1-based.
- `ui_lines = vim.o.lines`, `ui_cols = vim.o.columns` — full screen size.

**Anchor semantics** (`:help nvim_open_win`): `anchor` names the window CORNER placed at
`(row,col)`. `"NW"` → top-left → window grows **down-right**; `"SW"` → bottom-left → window
grows **up-right** (sits ABOVE the caret). So: below caret = `anchor="NW", row=1`; above =
`anchor="SW", row=0`.

**Border overhead:** a non-`"none"` border (`"rounded"`, `"single"`, …) draws a 1-cell frame
on all four sides → **+2 rows, +2 cols** (`bv=2, bh=2`); `"none"` → `bv=0, bh=0`. Reserve
these so `height+bv` / `width+bh` never overflow.

**Pure helpers:**
```
-- WIDTH (S34 = label-only; S35 widens to label+gap+description)
local function compute_width(items, ui_cols, bh)
  local max_w = 0
  for _, it in ipairs(items) do
    local w = vim.fn.strdisplaywidth(it.label or "")   -- CJK/double-width aware (NOT #s)
    if w > max_w then max_w = w end
  end
  return math.max(1, math.min(max_w, ui_cols - bh))
end

-- HEIGHT
local function compute_height(n_items, max_height)
  if n_items <= 0 then return 0 end
  return math.min(n_items, max_height)
end

-- GEOMETRY (the clamping algorithm — returns {anchor, row, col, width, height})
local function compute_geometry(screen_row, screen_col, ui_lines, ui_cols, width, height, max_height, border)
  local bv = (border ~= "none") and 2 or 0
  local bh = (border ~= "none") and 2 or 0
  height = math.min(height, max_height)
  local reserve     = 1                                   -- never paint over the cmdline
  local space_below = (ui_lines - reserve) - screen_row   -- rows strictly below caret
  local space_above = screen_row - 1                       -- rows strictly above caret
  local need_h      = height + bv
  local anchor, row
  if space_below >= need_h then
    anchor, row = "NW", 1
  elseif space_above >= need_h then
    anchor, row = "SW", 0
  elseif space_below >= space_above then
    anchor, row = "NW", 1
    height = math.max(1, space_below - bv)
  else
    anchor, row = "SW", 0
    height = math.max(1, space_above - bv)
  end
  -- horizontal
  local col
  local need_w = width + bh
  local from_cursor_right = ui_cols - (screen_col - 1)
  if need_w <= from_cursor_right then
    col = 0
  else
    col = from_cursor_right - need_w                       -- NEGATIVE => shift left
    if col < -(screen_col - 1) then                         -- would spill past the LEFT edge
      col = -(screen_col - 1)
      width = math.max(1, ui_cols - bh)
    end
  end
  return { anchor = anchor, row = row, col = col, width = width, height = height }
end
```

**Verified case table** (ui_lines=24, ui_cols=80, border="rounded" ⇒ bv=2, bh=2):
| # | caret (row,col) | desired w×h | result (anchor,row,col,w,h) | why |
|---|-----------------|-------------|-----------------------------|-----|
| 1 | (1,1) top-left  | 40×3 | NW,1,0,40,3 | room below (space_below=22≥5) → below |
| 2 | (24,1) bottom   | 40×3 | SW,0,0,40,3 | space_below=-1<5, space_above=23≥5 → above |
| 3 | (20,1)          | 40×3 | SW,0,0,40,3 | space_below=3<5, space_above=19≥5 → above |
| 4 | (1,80) right edge | 40×3 | NW,1,**-41**,40,3 | need_w=42>1 ⇒ col=1-42=-41 (shift left) |
| 5 | (10,1), w=100   | 100×3 | NW,1,0,**78**,3 | w>screen ⇒ pin left, clamp w=80-2 |
| 6 | (12,1), 12 items | 40×12 | NW,1,0,40,**9** | neither side fits ⇒ clamp h=11-2=9 below |
| 7 | (24,1) border="none" | 40×3 | SW,0,0,40,3 | no border overhead; above caret |

All seven rows are EXACT outputs of the prototype's `compute_geometry`.

## 4. The HEADLESS testing gotcha (CRITICAL — why the pure-function split is mandatory)

**`vim.fn.screenrow()` / `vim.fn.screencol()` return `1` in `--headless`** regardless of the
real cursor position (verified: cursor at line 20 col 50 → `screenrow=1, screencol=1`, while
`winline()`/`wincol()` DO track). This is a known Neovim limitation (no real screen grid
headlessly). `:help screenrow` / `:help screencol`.

**Implication (the §3 mandate made concrete):**
- The PRODUCTION `render(state)` MUST call `vim.fn.screenrow()`/`vim.fn.screencol()` (they are
  correct interactively — that's the real target).
- The CLAMPING LOGIC lives in the PURE `compute_geometry(screen_row, screen_col, …)` taking
  EXPLICIT inputs → unit-tested with SYNTHETIC values (the 7 cases above), fully deterministic.
- `render(state)` INTEGRATION tests assert window CREATION/VALIDITY + `width`/`height`/
  `anchor` ONLY — NEVER a specific clamped position (headless `screenrow()` is pinned to 1).
- This mirrors `vim.lsp.util.make_floating_popup_options` (Neovim's own canonical float
  helper, which separates geometry from screen reads).

## 5. Reconciliation: P2M5T1S1 prototype vs. the ACTUAL shipped S31 menu.lua

The earlier research (positioning-math.md / live-verification.md) prototyped a DIFFERENT
module shape (module-level `_items`/`_selected`/`_buf`/`_win`/`_ensure_buf`/`M.open`/
`M.set_selected`/`M.move`). **S31 shipped a DIFFERENT (cleaner, blink-list-modeled) shape:**
a `state` singleton + `render(state)` LOCAL fn + `M.open(items)`/`M.close()`/`M.reset()`/
`M.on_results`. **S34 ADAPTS the prototype's WINDOW/GEOMETRY logic to the S31 shape:**
- `render(state)` IS the seam (NOT a public `M.render`/`M._render`).
- The geometry helpers become module-level LOCAL fns (testable via a thin export for specs, or
  by exposing them on `M` for testing — the codebase convention is to unit-test pure helpers,
  so expose `M._compute_geometry`/`M._compute_width`/`M._compute_height` OR keep them local +
  test through `render` integration; the S31 spec already tests pure helpers indirectly).
- `state.win`/`state.menu_buf` are the lifecycle handles (the prototype's `_win`/`_buf`).

## 6. Gotchas / anti-patterns for the PRP

- **NO rewrite of the state layer.** S34 EDITS the local `render(state)` + ADDS pure helpers +
  manages `state.win`/`state.menu_buf`. S31's `open()`/`close()`/`reset()`/`on_results`/
  accessors stay AS-IS.
- **`relative="cursor"` → `"win"` in get_config** (GOTCHA A). Tests assert `width`/`height`/
  `anchor`, not `relative`. Border is a TABLE in get_config — don't string-compare.
- **`screenrow()`/`screencol()` pinned to 1 headless** → pure-function split (§4).
- **`strdisplaywidth`, NOT `#s`** (CJK/double-width = 2 cells). Verified: `/model`=6, `日本語`=6.
- **Border overhead** +2/+2 unless `"none"` (§3).
- **Reuse the scratch buffer** across open/close (don't delete on close — blink pattern; only
  `reset()`/teardown nils it).
- **Close window on hide, recreate on next open** reusing the buffer; **reposition IN PLACE**
  (`nvim_win_set_config`) while open (no flicker).
- **render NEVER throws** (per-keystroke + autocmd contract — `on_results` is pcall'd by S30,
  but render itself must be defensive: pcall every nvim call; `nvim_win_is_valid` before
  set_config/close; `nvim_buf_is_valid` before set_lines).
- **NEVER-THROWS > silent degrade**: a window-creation failure must not abort completion —
  catch + leave state (the menu stays state-open; the next `on_results` retry recreates).
- **One buf/session** (PRD §11): the menu window shows a SCRATCH buffer (`state.menu_buf`),
  NOT the pi-prompt buffer (`state.buf`); positioning is relative to the cursor in the
  current (pi-prompt) window.
- **The existing menu_spec.lua case (18)** asserts "S31 must NOT create a floating window
  (S34's job)". **S34 FLIPS it**: the full flow now MUST create a window. The PRP tells the
  implementer to UPDATE that case (+ add pure-geometry + lifecycle cases).
- **`open({})` does NOT render a window**: S31's `open()` sets `state.open=(#items>0)`, so
  `open({})` → `open=false` → render's close path (no window). render must guard on
  `state.open and #state.items > 0`.