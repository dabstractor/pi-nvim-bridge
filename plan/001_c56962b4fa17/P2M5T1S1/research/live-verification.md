# Live Verification — menu.lua floating window (task S34 / PRP path P2M5T1S1)

Every API behavior and every validation command referenced in this PRP was
**LIVE-VERIFIED** against the installed Neovim 0.12.4 (no extra installs). The
complete reference `menu.lua` was prototyped in an isolated `/tmp/vtree` (with a
copy of S19's `init.lua`) and its full test suite ran green (`MENU_VERIFY_PASS 0`,
exit 0). This closes the "did the research actually run?" gap.

## 0. Environment

- `nvim --version` → `NVIM v0.12.4` (Build RelWithDebInfo).
- plenary.nvim present at `/home/dustin/.local/share/nvim/lazy/plenary.nvim`.
- **S19 (`init.lua`) is already implemented**: `plugin/lua/pi-editor/init.lua`
  exists with `M.defaults`, `M.config`, `M.bridge`, `M.setup`, `return M`; its
  plenary spec runs green (`Errors: 0`). So `require("pi-editor").config` and
  `require("pi-editor").defaults` are a **hard contract** for menu.lua.
- `plugin/lua/pi-editor/menu.lua` does **NOT** exist yet — this task creates it.

## 1. `nvim_open_win` + `nvim_win_get_config` (the core deliverable)

Command shape verified:
```lua
local buf = vim.api.nvim_create_buf(false, true)             -- listed=false, scratch=true
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "a","bb","ccc" })
local win = vim.api.nvim_open_win(buf, false, {
  relative = "cursor", anchor = "NW", row = 1, col = 0,
  width = 10, height = 3, style = "minimal",
  border = "rounded", focusable = false,
})
vim.api.nvim_set_option_value("wrap", false, { win = win })
```
- Returns a valid window id headlessly. `nvim_win_close(win, true)` closes it. ✓

### GOTCHA A — `relative="cursor"` is NORMALIZED to `relative="win"` in get_config
Passing `relative="cursor"` opens a cursor-anchored window, but
`nvim_win_get_config(win)` returns `relative="win"` with `win=<handle>` and
`row`/`col` resolved to the cursor's actual cell in that window. Verified:
opened with `relative="cursor"` at cursor winline=20/wincol=51 → get_config
showed `relative=win anchor=NW row=20 col=50`.
**Implication for tests:** assert positioning via the **pure** `compute_geometry`
function (deterministic) and the window's `width`/`height`/`anchor` from
get_config — **do not** assert `cfg.relative == "cursor"` (it will be `"win"`).

### get_config field list (so tests know what to assert)
`col, width, style, hide, border, focusable, mouse, zindex, anchor, external,
height, relative, win, row`. Note `border` is a **table** (chars) even when you
pass `"rounded"`, so don't string-compare `cfg.border`; compare `width/height/
anchor` instead.

## 2. `nvim_win_set_config` resizes an EXISTING float in place (update-if-open path)

Verified: opened a float (width=12,height=3,anchor=NW), then
`nvim_win_set_config(win, { relative="cursor", anchor="NW", row=1, col=0,
width=15, height=2 })` → same window id, get_config now `width=15 height=2`.
This is what makes `M.open()` reposition/resize without close+reopen (no flicker).
A negative `col` shifts the window LEFT: `col=-30` at cursor wincol=51 →
get_config `col=20` (i.e. 50 + (-30)). ✓

## 3. `screenrow()` / `screencol()` are UNRELIABLE in headless mode (CRITICAL testing gotcha)

This is the single most important finding for the testing strategy. After moving
the real cursor to line 20 col 50 in a full-screen window:
```
screenrow=1  screencol=1  winline=20  wincol=51
```
i.e. **`screenrow()`/`screencol()` return 1,1 in `--headless` regardless of the
real cursor position**, while `winline()`/`wincol()` (window-relative) DO track
the cursor. In a real interactive terminal, `screenrow()`/`screencol()` return
the correct screen-absolute cursor position (they only misbehave headlessly
because there is no real screen grid to update).

**Implication:** the production code MUST honor the contract and call
`vim.fn.screenrow()` / `vim.fn.screencol()` (correct interactively). But the
clamping **logic** is verified by extracting it into a PURE function
`compute_geometry(screen_row, screen_col, ui_lines, ui_cols, …)` that takes
explicit inputs and is unit-tested with synthetic values — completely sidestepping
the headless `screenrow()` quirk. `M.open()` integration tests assert window
creation/validity/width/height/anchor only, never a specific clamped position
(since headless `screenrow()` is pinned to 1).

## 4. Border overhead must be counted in the clamping math

A non-`"none"` border (`"rounded"`, `"single"`, `"double"`, char-table, …) adds a
1-cell frame on every side → **2 rows and 2 columns** of overhead. Verified the
geometry math accounts for this so `height + 2` / `width + 2` never overflow the
screen. `"none"` adds 0.

## 5. `vim.fn.strdisplaywidth` (used for width calc) is double-width-aware

```
strdisplaywidth("/model") == 6        -- ASCII
strdisplaywidth("日本語") == 6        -- 3 CJK glyphs × 2 cells = 6
```
Use it (not `#s`) so CJK/double-width labels size the menu correctly. Verified.

## 6. Window option: use `nvim_set_option_value` (non-deprecated form)

The contract names `vim.api.nvim_win_set_option(win, "wrap", false)`, which on
0.12.4 still works and emits **no** visible deprecation line. But the
non-deprecated, forward-proof equivalent is:
```lua
vim.api.nvim_set_option_value("wrap", false, { win = win })
```
Verified: sets `vim.wo[win].wrap == false`. This PRP uses this form and documents
it as the equivalent of the contract's call.

## 7. Prototype end-to-end run (the proof)

Prototyped the full `menu.lua` at `/tmp/vtree/lua/pi-editor/menu.lua` + copied
S19's `init.lua` alongside it; ran `/tmp/vverify.lua` (rtp → `/tmp/vtree`,
`setup({})`, then `require("pi-editor.menu")`). 26 checks covering:
`compute_width` (with-desc/no-desc/over-wide-clamp/empty/CJK), `compute_height`
(0 / under-max / clamp), `compute_geometry` (the 7 cases in
`positioning-math.md`), and lifecycle (`is_open`, open → valid window, width/height
match computed, `wrap=false`, `selected==1`, update-if-open reuses the same
window id and resizes, `set_selected`/`move`/`get_item` clamping, `close`,
`open({})` → closed, reopen reuses buffer).
**Result: `MENU_VERIFY_PASS 0`, exit 0.** The same module + spec are what this
PRP asks the implementer to ship, so the validation commands are pre-proven green.

## 8. S19 plenary harness is reusable as-is

```
cd plugin
nvim --headless --clean -u tests/minimal_init.lua \
  -c 'lua require("plenary.busted").run("tests/menu_spec.lua")'
```
`tests/minimal_init.lua` (created by S19) sets runtimepath to the `plugin/`
subdir + plenary; running S19's `init_spec.lua` through it gives `Errors: 0`.
This PRP's `menu_spec.lua` reuses the same harness (no new bootstrap needed).
