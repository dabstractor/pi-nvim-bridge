# Positioning & Edge-Clamping Math — menu.lua (task S34 / PRP path P2M5T1S1)

The clamping algorithm and **every numeric result below were computed by the
live-verified prototype** (`/tmp/vverify.lua` → `MENU_VERIFY_PASS 0`). This file
is the derivation; the PRP embeds the matching reference implementation.

## Coordinate model (Neovim)

- `screen_row = vim.fn.screenrow()` — cursor's **screen** row, 1-based from the
  top of the whole screen (the contract's mandated call; correct interactively,
  pinned to 1 headlessly — see live-verification.md §3).
- `screen_col = vim.fn.screencol()` — cursor's **screen** column, 1-based.
- `ui_lines = vim.o.lines`, `ui_cols = vim.o.columns` — full screen size.
- `relative="cursor"` anchors the float at the caret cell. We then pick the
  **corner** via `anchor` and a (possibly negative) `col` to keep it on-screen.

## Anchor semantics

| `anchor` | corner at (row,col) | meaning |
|----------|----------------------|---------|
| `"NW"`   | top-left             | window grows **down-right**; `row=1` ⇒ top edge one cell **below** the caret |
| `"SW"`   | bottom-left          | window grows **up-right**; `row=0` ⇒ bottom edge **at** the caret row (window sits **above** the caret) |

So: below caret = `anchor="NW", row=1`; above caret = `anchor="SW", row=0`.

## Border overhead

`border` (unless `"none"`) draws a 1-cell frame on all four sides ⇒ **+2 rows,
+2 cols** of footprint. The geometry math must reserve `bv` rows / `bh` cols so
`height+bv` and `width+bh` never exceed the available space.

## Vertical clamping

Reserve 1 row for the cmdline (so the menu never paints over the command line):

```
reserve      = 1
space_below  = (ui_lines - reserve) - screen_row      -- rows strictly below caret
space_above  = screen_row - 1                          -- rows strictly above caret
need_h       = height + bv

if space_below >= need_h        -> anchor=NW, row=1, height            (room below)
elseif space_above >= need_h    -> anchor=SW, row=0, height            (room above)
elseif space_below >= space_above -> anchor=NW, row=1, height=max(1, space_below-bv)  (clamp to fit below)
else                              -> anchor=SW, row=0, height=max(1, space_above-bv)  (clamp to fit above)
```

The last two branches (neither side fits the full `height`) clamp the height to
the larger side rather than letting the window overflow the screen.

## Horizontal clamping

```
need_w            = width + bh
from_cursor_right = ui_cols - (screen_col - 1)        -- cols from caret col to right edge

if need_w <= from_cursor_right  -> col = 0                                      (fits right)
else
  col = from_cursor_right - need_w                         -- NEGATIVE => shift window left
  if col < -(screen_col - 1)                               -- would spill past the LEFT edge
     col = -(screen_col - 1)                               -- pin left edge to column 0
     width = max(1, ui_cols - bh)                          -- clamp width to full screen
```

A **negative `col`** with `relative="cursor"` shifts the window left; verified
live (`col=-30` at caret wincol 51 ⇒ placed at column 20).

## Verified case table (ui_lines=24, ui_cols=80, border="rounded" ⇒ bv=2, bh=2)

| # | caret (row,col) | desired w×h | result (anchor,row,col,w,h) | why |
|---|-----------------|-------------|-----------------------------|-----|
| 1 | (1,1) top-left  | 40×3 | NW,1,0,40,3 | room below (space_below=22≥5) → open below |
| 2 | (24,1) bottom   | 40×3 | SW,0,0,40,3 | space_below=-1<5, space_above=23≥5 → open above |
| 3 | (20,1)          | 40×3 | SW,0,0,40,3 | space_below=3<5, space_above=19≥5 → above |
| 4 | (1,80) right edge | 40×3 | NW,1,**-41**,40,3 | need_w=42>1 ⇒ col=1-42=-41 (shift left) |
| 5 | (10,1), w=100   | 100×3 | NW,1,0,**78**,3 | w>screen ⇒ shift would pass left edge ⇒ pin left, clamp w=80-2 |
| 6 | (12,1), 12 items | 40×12 | NW,1,0,40,**9** | space_below=11<14 & space_above=11<14 ⇒ clamp h=11-2=9 below |
| 7 | (24,1) border="none" | 40×3 | SW,0,0,40,3 | no border overhead; above caret |

All seven rows are exact outputs of the prototype's `compute_geometry`.

## Width computation (content-driven, screen-clamped)

```
gap   = 2                       -- spaces between label and description columns
max_w = max over items of:
          strdisplaywidth(label) + (description ? gap + strdisplaywidth(description) : 0)
width = max(1, min(max_w, ui_cols - bh))
```

`strdisplaywidth` (not `#s`) so double-width glyphs (CJK) are counted correctly
(verified: `/model`=6, `日本語`=6).

## Height computation

```
height = items==0 ? 0 : min(#items, max_height)
```

## Why the pure-function split is mandatory for testing

Because `screenrow()`/`screencol()` are pinned to 1 in `--headless`
(live-verification.md §3), a headless `M.open()` cannot exercise the
above/below/shift math through the real `vim.fn.*` calls. Extracting
`compute_geometry(screen_row, screen_col, …)` as a **pure** function and
feeding it synthetic inputs makes the entire clamping contract deterministic and
unit-testable; `M.open()` simply reads live values and forwards them.
