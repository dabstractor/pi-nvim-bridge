---
name: "P2.M8.T21.S35 (PRP path P2M5T1S2) — menu.lua item rendering: two-column label/description + selected-row highlight"
description: |
  **Enhance `plugin/lua/pi-editor/menu.lua`** (created in parallel by **S34** / PRP path
  `P2M5T1S1`) with the **rendering + highlight** half of the floating completion menu
  (PRD §7.5). This task owns the *paint*; S34 owns window lifecycle + geometry.
  Deliverables: (1) REPLACE the S34 basic `_render_lines(items, width)` placeholder with
  **two-column formatting** — label left-justified (padded) to the max label width, then a
  fixed gap, then the description **truncated** to the remaining width (CJK-aware via
  `strdisplaywidth`/`strcharpart`, ellipsis when cut); (2) ADD a module namespace via
  `vim.api.nvim_create_namespace`; (3) ADD `M.render(items, selected_idx, width?)` that sets
  buffer lines (`nvim_buf_set_lines`) + clears + applies highlights (`nvim_buf_clear_namespace`
  + `nvim_buf_add_highlight`); (4) highlight the **selected row** whole-line with `"PmenuSel"`
  (added LAST so it wins — last-wins within a namespace, verified: neovim/neovim#8449) and
  optionally the label/description columns (`"Pmenu"` / `"Comment"`); (5) WIRE the two `[S35]`
  seams S34 left in `open()` and `set_selected()`. Tests assert **decorations via
  `nvim_buf_get_extmarks`** (NOT rendered colors — `screenattr()` is 0 in --headless, same
  class of limitation as S34's `screenrow()`). [Mode A] LuaCATS docstring explains the
  two-column layout. Zero external Lua deps; Neovim 0.10+ (verified 0.12.4).
  NARROW scope guard — this task does NOT implement: navigation key handling (**S36**), or
  auto-close autocmds (**S37**). It does NOT change window geometry/positioning/clamping
  (that is S34's locked contract).
  STATUS (planning): every API behavior + validation command was LIVE-VERIFIED green
  (research/highlight-layering.md: namespace, clear, add_highlight, last-wins ordering, CJK
  truncation; the `_truncate`/two-column reference impl was prototyped and run green).
---

## Goal

**Feature Goal**: Give `menu.lua` (built by S34) real, polished item rendering. Each item
prints as **two columns**: the `label` left-justified to the widest label, a fixed 2-cell
gap, and the `description` truncated to fit the remaining window width (CJK-correct, with an
ellipsis when cut). The **selected row** is highlighted with the builtin `"PmenuSel"` group
across the whole line; the label/description columns get `"Pmenu"` / `"Comment"` groups. A
single public entry point `M.render(items, selected_idx, width?)` does the full paint (set
lines + clear namespace + apply highlights) and is wired into S34's `open()` (on show) and
`set_selected()` (on selection move).

**Deliverable** (3 files — 1 MODIFY + 2 NEW):
- **MODIFY** `plugin/lua/pi-editor/menu.lua` (created by S34):
  - Add module constant `GAP = 2`, module fields `M._ns` (namespace id) + `M._layout`
    (cached layout), and lazy `M._ensure_ns()`.
  - **REPLACE** the body of `M._render_lines(items, width)` (S34's basic placeholder) with
    two-column formatting driven by pure helpers `M._truncate`, `M._compute_label_width`.
  - **ADD** `M.render(items, selected_idx, width?)`, `M._apply_highlights(...)`,
    `M._render_selection()`.
  - **WIRE** the `[S35]` seam in `open()` → `M.render(items, 1, geo.width)`; the `[S35]`
    seam in `set_selected()` → `M._render_selection()`.
  - [Mode A] LuaCATS docstring at the top of the rendering section explains the two-column
    layout + last-wins highlight ordering.
- **CREATE** `plugin/tests/render_spec.lua` — plenary/busted spec (the Level-2 gate): pure
  formatting helpers + `render` decoration assertions (via `nvim_buf_get_extmarks`) +
  `open()`/`set_selected()` highlight wiring. Reuses S19's `tests/minimal_init.lua`.
- **CREATE** `plugin/tests/smoke_render.lua` — plenary-FREE standalone smoke (the Level-1
  gate; `:luafile`-sourced, `cquit(1)` on failure — same pattern as S19's `smoke.lua` /
  S34's `smoke_menu.lua`).

**Success Definition** (all assertions below are LIVE-VERIFIED via the prototype — see
`research/highlight-layering.md`):
- `require("pi-editor.menu")` loads (rtp = `plugin/`); `_truncate`/`_compute_label_width`/
  `_render_lines` produce the EXACT formatted lines verified in
  `research/highlight-layering.md` §4 (incl. CJK width + ellipsis truncation).
- `M.render(items, 1, width)` sets the buffer lines AND, enumerated via
  `nvim_buf_get_extmarks(buf, ns, 0, -1, {details=true})`, yields: one `"PmenuSel"` mark at
  row `0` (selected_idx 1 → 0-based line 0), `"Pmenu"` marks on every row over the label
  range, and `"Comment"` marks on rows that have a description.
- `M.open(items)` (S34's lifecycle) now leaves exactly ONE `"PmenuSel"` decoration, at the
  selected row; `M.set_selected(2)` (S34's selection) moves that single `"PmenuSel"`
  decoration to row `1` (0-based) — decorations, not pixels (GOTCHA: `screenattr` is 0
  headlessly).
- `M.close()` (S34) leaves the buffer's namespace decorations cleared on next render
  (`_apply_highlights` always clears before painting).
- Headless smoke test prints `RENDER_SMOKE_PASS` / exit 0; plenary spec exits 0.

## User Persona (if applicable)

**Target User**: The plugin author and the downstream implementers of **S36** (key handling
— calls `M.move(±1)`→`M.set_selected`→highlight moves) and **S32** (accept flow — calls
`M.get_item()` to read the selected `AutocompleteItem`). End users never call `M.render`
directly.

**Use Case**: `completion.lua` (S31) receives `AutocompleteItem[]` from the bridge and calls
`M.open(items)`; the user sees a clean two-column menu with the top item highlighted; arrow
keys (S36) move the highlight. This task is the *paint*; S34 is the *window*.

**Pain Points Addressed**: Raw `label + "  " + description` (S34's placeholder) looks ragged
when labels have different widths, and with no highlight the user can't tell which item is
selected. Left-justified columns + a visible selected row make the menu legible and usable.

## Why

- **Primary UX surface (PRD §7.5).** The menu is the completion UI that must work with stock
  Neovim and no plugin manager. Rendering quality is the difference between "feels native"
  and "looks broken."
- **The selected-row highlight is the contract.** PRD §7.5 mandates "selected row" via
  `nvim_buf_add_highlight`. Without it, arrow-key navigation (S36) has no visible feedback.
- **Two-column alignment is the readability win.** PRD §7.5: "two columns — `label` (left)
  and `description` (right, truncated)." Left-justifying labels to a common width is what
  makes descriptions line up into a readable column.
- **Builds on the (in-flight) S34 module + (done) S19 config.** S34 ships the lifecycle +
  geometry + selection-index state with two `[S35]` seams; S19 ships `menu.max_height`/
  `border`. This task fills the seams without touching geometry.

## What

User-visible behavior: each completion row shows a label, a 2-space gap, and a dimmed
description that is truncated (with `…`) if it would overflow the menu width; all labels are
padded to the same width so descriptions form a tidy right column; the currently-selected row
has the popup-menu selection background.

Technical requirements (from the work-item contract + PRD §7.5):
- Namespace: `vim.api.nvim_create_namespace("pi-editor-menu")`, created once, cached on `M._ns`.
- Lines: `M._render_lines(items, width)` → pure; per item `pad_right(label, max_label) ..
  (GAP spaces) .. truncate(description, width - max_label - GAP)`; description omitted when
  its budget ≤ 0; CJK-correct via `vim.fn.strdisplaywidth` / `strcharpart` / `strchars`.
- Highlights (`M._apply_highlights`, contract steps c/d/e):
  1. `nvim_buf_clear_namespace(buf, ns, 0, -1)` (clear).
  2. Per row: label range `[0, max_label)` → `"Pmenu"`; description range
     `[max_label+GAP, end)` → `"Comment"` (only when the item has a description and the
     description column is on-window).
  3. Selected row whole-line `[0, -1)` → `"PmenuSel"`, added **last** (last-wins → it wins).
- `selected_idx` is **1-based** (matches S34's `_selected`/`get_selected`); converted to
  0-based for `nvim_buf_add_highlight` (`line = selected_idx - 1`).
- `M.render(items, selected_idx, width?)` sets lines + applies highlights + caches layout.
  `open()` calls it with `geo.width`; `set_selected()` calls `M._render_selection()` which
  re-applies only highlights (lines unchanged on a selection move).

### Success Criteria

- [ ] `require("pi-editor.menu")` loads with rtp=`plugin/`; no error.
- [ ] `_truncate`: no-cut when fits; `"hell…"` for `("hello world",5)`; CJK-correct;
      `""` for `max_w<=0`.
- [ ] `_compute_label_width`: max label display width (0 for empty items); CJK-aware.
- [ ] `_render_lines`: pads labels to `max_label`, gaps `GAP`, truncates descriptions to
      `width - max_label - GAP`; omits description when budget ≤ 0.
- [ ] `M.render(items, 1, width)` sets buffer lines AND applies exactly ONE `"PmenuSel"`
      decoration at the selected row (0-based `selected_idx-1`), plus per-column `"Pmenu"`/
      `"Comment"` decorations (verified via `nvim_buf_get_extmarks`).
- [ ] `M.set_selected(2)` moves the single `"PmenuSel"` decoration to row `1` (0-based).
- [ ] Re-rendering clears stale decorations first (`nvim_buf_clear_namespace`) — no leftover
      `"PmenuSel"` from a previously-selected row.
- [ ] `M.open(items)` (S34) still opens a valid window with correct width/height (unchanged);
      the `[S35]` seam now drives `M.render`.
- [ ] Headless smoke test prints `RENDER_SMOKE_PASS`, exit 0; plenary spec exits 0.
- [ ] [Mode A] LuaCATS annotations on all new public/internal functions; a module/section
      docstring explaining the two-column layout + last-wins highlight ordering.

## All Needed Context

### Context Completeness Check

_Passes "No Prior Knowledge":_ an implementer who has never seen this repo needs only this
PRP + `research/highlight-layering.md` + the exact commands below. Every Neovim API call
(`nvim_create_namespace`, `nvim_buf_add_highlight`, `nvim_buf_clear_namespace`,
`nvim_buf_set_lines`, `nvim_buf_get_extmarks`, `strdisplaywidth`, `strcharpart`) is cited
with a LIVE-VERIFIED runnable example, and the two non-obvious traps — **last-wins highlight
ordering within a namespace** and **`screenattr()` returns 0 in --headless** (so tests assert
decorations, not pixels) — are spelled out in §Known Gotchas and baked into the test design.
The 1-based↔0-based indexing trap (`selected_idx - 1`) is GOTCHA #1.

### Documentation & References

```yaml
# MUST READ — primary contract sources (selected_prd_content + research/)

- url: https://neovim.io/doc/user/api.html#nvim_buf_add_highlight()   # :help nvim_buf_add_highlight
  why: "The contract's core call: decorate a byte range of a line with a highlight group."
  critical: "The `line` arg is 0-INDEXED; S34's selected index is 1-based => pass selected_idx-1.
             Multiple highlights in the SAME namespace stack: whoever is added LAST wins on
             overlapping ranges (neovim/neovim#8449). end_col=-1 means 'to end of line'."

- url: https://github.com/neovim/neovim/issues/8449   # nvim_buf_add_highlight priority
  why: "Authoritative proof of the LAST-WINS ordering within a namespace."
  critical: "'whoever adds the highlight second wins and overshadows the previous.' => add the
             selected-row PmenuSel highlight AFTER the per-column label/description highlights."

- url: https://neovim.io/doc/user/api.html#nvim_buf_clear_namespace()  # :help nvim_buf_clear_namespace
  why: "Contract step (c): clear existing highlights before each paint."
  critical: "nvim_buf_clear_namespace(buf, ns, line_start, line_end) with (buf, ns, 0, -1) wipes
             ALL decorations in the namespace — verified to leave 0 extmarks."

- url: https://neovim.io/doc/user/api.html#nvim_create_namespace()   # :help nvim_create_namespace
  why: "Contract: 'Create a namespace via vim.api.nvim_create_namespace.'"
  critical: "Returns a numeric id (e.g. 3); cache it on M._ns and reuse. Idempotent: passing the
             same name returns the same id."

- url: https://neovim.io/doc/user/api.html#nvim_buf_get_extmarks()   # :help nvim_buf_get_extmarks
  why: "How tests ASSERT the decorations were applied (screenattr() is 0 headlessly — GOTCHA)."
  critical: "nvim_buf_get_extmarks(buf, ns, 0, -1, {details=true}) -> { {id, row(0-based), col,
             {end_col, hl_group, ...}}, ... }. A whole-line add_highlight(buf,ns,h,l,0,-1) shows
             end_col==0 in details => assert hl_group+row, NOT end_col."

- url: https://neovim.io/doc/user/builtin.html#strdisplaywidth()   # :help strdisplaywidth
  why: "Label-width + truncation that counts double-width glyphs (CJK) as 2 cells."
  critical: "Use this (NOT #s). Verified: '/model'=6, '日本語'=6. Pair with strcharpart (substring
             by CHAR) and strchars (char count) for CJK-correct truncation."

- file: plan/001_c56962b4fa17/P2M5T1S1/PRP.md   # S34 — the module this task ENHANCES
  why: "S34 (in-flight) CREATES menu.lua with: M.open/close/is_open, get_selected/set_selected/
        move/get_item, compute_*, _ensure_buf, the BASIC _render_lines(items,width), and two
        [S35] seams (in open() and set_selected()). This task REPLACES _render_lines, ADDS
        render/_apply_highlights/_render_selection/_ensure_ns, and FILLS the seams. Module state
        fields (_items/_selected(1-based)/_buf/_win) are S34's locked contract — do NOT change them."

- file: plan/001_c56962b4fa17/P2M5T1S2/research/highlight-layering.md   # THIS task's verified research
  why: "LIVE-VERIFIED proof of: namespace/clear/add_highlight mechanics, last-wins ordering,
        screenattr-headless testing limitation, CJK-correct truncation, the 1-based↔0-based trap,
        and the AutocompleteItem shape."

- file: plan/001_c56962b4fa17/P2M4T11S19/PRP.md   # (implemented — plugin/lua/pi-editor/init.lua)
  why: "S19 ships M.config/M.defaults (menu.max_height, menu.border). render()'s default-width
        fallback reads (require('pi-editor').config or .defaults).menu.border — same pattern S34 uses."

- file: plugin/lua/pi-editor/init.lua   # S19 — the config contract (ALREADY IMPLEMENTED)
  why: "The exact Config/MenuConfig shape: menu.max_height (12), menu.border ('rounded'). menu.lua
        reads it; this task adds NO new config keys."

- file: plugin/tests/minimal_init.lua   # created by S19
  why: "Plenary harness bootstrap (rtp = plugin/ subdir + plenary). render_spec.lua reuses it
        unchanged — no new bootstrap file is needed."

- docfile: plan/001_c56962b4fa17/prd_snapshot.md
  section: "§7.5 (menu.lua), §5.4 (AutocompleteItem {value,label,description?}), §10.5 (menu defaults)"
  why: "The verbatim contract for this popup and the item/config shapes."
```

### Current Codebase tree (relevant slice)

```bash
pi-nvim-bridge/                       # repo root (monorepo)
├── extension/                        # P1 pi-editor-bridge (TypeScript) — COMPLETE
├── plugin/                           # P2 pi-bridge.nvim (Lua) — S19 DONE; S34 IN-FLIGHT; this task S35
│   ├── lua/pi-editor/
│   │   ├── init.lua                  # S19: M.defaults/M.config/M.bridge/M.setup (CONTRACT)
│   │   └── menu.lua                  # S34: lifecycle+geometry+selection + BASIC _render_lines + [S35] seams  <-- MODIFY
│   └── tests/
│       ├── minimal_init.lua          # S19: plenary harness bootstrap (REUSED — do not recreate)
│       ├── init_spec.lua             # S19
│       ├── smoke.lua                 # S19
│       ├── menu_spec.lua             # S34 (lifecycle+geometry+selection)  <-- do NOT touch
│       └── smoke_menu.lua            # S34                                  <-- do NOT touch
└── plan/001_c56962b4fa17/P2M5T1S2/{PRP.md, research/highlight-layering.md}   # THIS task
# NOTE: this task does NOT create menu.lua (S34 does). It MODIFIES S34's menu.lua.
# NOTE: this task's tests are render_spec.lua + smoke_render.lua (distinct from S34's files — no collision).
```

### Desired Codebase tree with files to be added/modified

```bash
plugin/
├── lua/pi-editor/
│   └── menu.lua                      # MODIFY — add GAP/_ns/_layout/_ensure_ns; REPLACE _render_lines;
│                                     #          ADD render/_apply_highlights/_render_selection; WIRE [S35] seams
└── tests/
    ├── render_spec.lua               # NEW — plenary/busted spec (Level-2 gate): pure fns + decoration asserts
    └── smoke_render.lua              # NEW — plenary-FREE smoke (Level-1 gate; :luafile + cquit)
# (plugin/tests/minimal_init.lua is REUSED from S19 unchanged; S34's menu_spec/smoke_menu are untouched.)
```

### Known Gotchas of our codebase & Library Quirks

```lua
-- GOTCHA #1 (CRITICAL) — selected_idx is 1-BASED, nvim_buf_add_highlight line is 0-INDEXED.
--   S34's M._selected / get_selected / set_selected are 1-based (reset to 1, clamped to [1,#items]).
--   nvim_buf_add_highlight(buf, ns, hl, LINE, c0, c1) and nvim_buf_get_extmarks rows are 0-based.
--   => _apply_highlights MUST pass (selected_idx - 1) as the line. Tests MUST expect the PmenuSel
--      decoration at row (selected_idx - 1). Forgetting this highlights the WRONG row (off by one).

-- GOTCHA #2 — LAST-WINS highlight ordering within a namespace.
--   nvim_buf_add_highlight has no per-call priority (unlike nvim_buf_set_extmark's `priority`).
--   Within one namespace, highlights added LATER override earlier ones on overlapping ranges
--   (neovim/neovim#8449). => In _apply_highlights: add per-column (Pmenu/Comment) highlights FIRST,
--      then the selected-row PmenuSel whole-line LAST, so PmenuSel wins on the selected row.
--      (Label and description ranges don't overlap each other, so their order is irrelevant.)

-- GOTCHA #3 — screenattr() returns 0 in --headless (TESTING limitation, mirrors S34's screenrow()).
--   You CANNOT assert the rendered color headlessly. Assert the DECORATIONS via
--   nvim_buf_get_extmarks(buf, ns, 0, -1, {details=true}) instead: assert which hl_group is on
--   which row, and that there's exactly ONE PmenuSel mark at the selected row. Same philosophy as
--   S34 testing compute_geometry (pure) instead of a clamped screenrow().

-- GOTCHA #4 — a whole-line add_highlight(buf, ns, hl, line, 0, -1) enumerates with end_col == 0
--   in the extmark details (the -1 sentinel). => in tests assert hl_group + row, NOT end_col.
--   (Verified live: add_highlight(...,1,0,-1) -> mark row=1 end_col=0 hl_group=….)

-- GOTCHA #5 — widths are DISPLAY widths, not byte/char counts. Use vim.fn.strdisplaywidth (NOT #s)
--   for label-width sizing AND truncation budgets, and vim.fn.strcharpart / strchars (NOT string.sub
--   or #) for CJK-correct substring/length in _truncate. Verified: '日本語' = 6 display cols.

-- GOTCHA #6 — clear BEFORE you paint, every time. _apply_highlights ALWAYS starts with
--   nvim_buf_clear_namespace(buf, ns, 0, -1). The buffer is REUSED across opens (S34 GOTCHA #8), so
--   stale decorations from a previous render (or a previously-selected row) would otherwise linger.

-- GOTCHA #7 — PmenuSel/Pmenu/Comment are built-in groups; no :highlight setup is needed (verified
--   they resolve in --clean). Do NOT create/define highlight groups — just reference the names.

-- GOTCHA #8 — do NOT recompute/reformat lines on a selection MOVE. set_selected() calls
--   _render_selection(), which re-applies ONLY highlights using the cached M._layout (set by render()).
--   Lines are unchanged when the cursor moves; reformatting would be wasteful and could flicker.

-- GOTCHA #9 — SCOPE GUARD. This task is RENDERING + HIGHLIGHT only. Do NOT implement: navigation key
--   bindings (S36), auto-close autocmds (S37), or any change to S34's window geometry/positioning/
--   clamping/selection-clamp logic. set_selected() keeps S34's clamp; it just ALSO calls
--   _render_selection() at the (existing) [S35] seam.

-- GOTCHA #10 — keep _render_lines PURE (returns string[], no buffer side effects). S34's tests +
--   this task's tests assert its output deterministically; it must not touch vim.api. The buffer
--   writes live in M.render() / open(); the highlight writes live in _apply_highlights().
```

## Implementation Blueprint

### Data models and structure (LuaCATS — the [Mode A] docs)

`menu.lua` already declares `pi-editor.AutocompleteItem` (S34); this task does NOT change it.
The item shape (PRD §5.4 — verified in `prd_snapshot.md`):

```lua
---@class pi-editor.AutocompleteItem   (defined by S34; included here for context)
---@field value string The text pi will insert/apply (consumed by S32 accept flow; untouched by rendering).
---@field label string Short text shown in the menu (left column).
---@field description? string Optional secondary text (right column, truncated by this task).
```

This task ADDS a layout cache class for the LuaCATS readers:

```lua
---@class pi-editor.MenuLayout   (internal — cached by M.render for _render_selection)
---@field max_label_width integer display width of the label column.
---@field width integer final window width the lines were formatted to.
---@field gap integer display columns between the label and description columns (= GAP).
```

### Implementation Tasks (ordered by dependencies)

```yaml
Task 1: MODIFY plugin/lua/pi-editor/menu.lua  (S34's module — additive edits)
  - ADD (near the top, after the existing module state): a `local GAP = 2` constant;
        module fields `M._ns` (integer|nil) + `M._layout` (pi-editor.MenuLayout|nil)
        with @---@type; a lazy `M._ensure_ns()` that does
        `M._ns = M._ns or vim.api.nvim_create_namespace("pi-editor-menu"); return M._ns`.
  - ADD pure helpers: a local `pad_right(s, width)` (right-pad to display width, never truncate);
        `M._truncate(text, max_w)` (CJK-aware truncate with "…", VERBATIM the reference impl below);
        `M._compute_label_width(items)` (max strdisplaywidth(label), 0 for empty).
  - REPLACE the BODY of `M._render_lines(items, width)` (S34's placeholder) with the two-column
        formatter below (same (items, width) SIGNATURE as S34 — drop the old label.."  "..desc body).
        Keep it PURE (returns string[]; no vim.api). CJK-aware. Description omitted when budget ≤ 0.
  - ADD `M._apply_highlights(items, selected_idx, max_label_width, width)`: ensure ns; CLEAR namespace;
        per row add label[0,max_label)->"Pmenu" and description[max_label+GAP,end)->"Comment" (guarded);
        FINALLY add selected row whole-line[0,-1)->"PmenuSel" at line (selected_idx-1) LAST (last-wins).
  - ADD `M._render_selection()`: re-apply highlights for M._items/M._selected using cached M._layout.
  - ADD `M.render(items, selected_idx, width?)`: ensure buf; default width via compute_width if nil;
        compute max_label; set lines via nvim_buf_set_lines; cache M._layout; call _apply_highlights.
  - WIRE open(): at the `[S35] apply two-column highlight` seam (after `M._selected = 1`), call
        `M.render(items, 1, geo.width)`, and REMOVE the earlier inline
        `nvim_buf_set_lines(M._buf, 0, -1, false, M._render_lines(items, geo.width))` line (render()
        now owns the set_lines). Everything else in open() is S34's — UNCHANGED.
  - WIRE set_selected(): at the `[S35] re-apply the selected-row highlight` seam (after the clamp),
        call `M._render_selection()`. The clamp math + return value stay S34's — UNCHANGED.
  - DOCS MODE A: @---@param/@---@return on every new function; a section docstring above the rendering
        helpers explaining the two-column layout (label padded, GAP, description truncated) AND the
        last-wins highlight ordering (why PmenuSel is added last) — this is the contract's docstring.
  - PRODUCTION CALLS (honor the contract exactly): nvim_create_namespace, nvim_buf_set_lines,
        nvim_buf_clear_namespace, nvim_buf_add_highlight, nvim_buf_is_valid, strdisplaywidth,
        strcharpart, strchars. (No new autocmds/keymaps/options — GOTCHA #9.)
  - DO NOT (GOTCHA #9): touch geometry/positioning/clamping (S34), add keymaps (S36), add autocmds (S37),
        or change S34's selection-clamp. Do NOT redefine highlight groups (PmenuSel/Pmenu/Comment exist).

Task 2: CREATE plugin/tests/render_spec.lua  (plenary/busted — the Level-2 gate)
  - CONTENT: `describe("pi-editor.menu rendering", …)` with (a) pure-function `it` blocks:
        _truncate (fits / ellipsis-cut "hell…" / CJK / max_w<=0), _compute_label_width (ascii/cjk/empty),
        _render_lines (padding alignment / gap / truncation / description-omitted-when-narrow / no-desc);
        (b) `render` decoration blocks: open buf, render, then enumerate via
        `nvim_buf_get_extmarks(M._buf, ns, 0, -1, {details=true})` and assert there's exactly ONE
        PmenuSel mark at row (selected-1), Pmenu marks on every row, Comment marks on rows-with-desc;
        (c) wiring: `menu.open(items)` leaves one PmenuSel at row 0; `menu.set_selected(2)` moves it
        to row 1; re-render clears the old PmenuSel (no leftover).
  - before_each: `package.loaded["pi-editor.menu"]=nil; package.loaded["pi-editor"]=nil;
        require("pi-editor").setup({}); require("pi-editor.menu")`. after_each: `menu.close()`.
  - ASSERT via a small helper that filters extmarks by hl_group/row (see Implementation Patterns).
        Assert DECORATIONS, never screenattr (GOTCHA #3). Assert end_col is NOT used (GOTCHA #4).
  - PLACEMENT: plugin/tests/render_spec.lua (distinct from S34's menu_spec.lua — no collision).
  - DEPENDENCIES: Task 1 (menu.lua) + S19's tests/minimal_init.lua + S34's menu.lua lifecycle.

Task 3: CREATE plugin/tests/smoke_render.lua  (plenary-FREE — the Level-1 gate)
  - CONTENT (see Implementation Patterns): standalone script — append plugin_root to rtp
        (debug.getinfo + fnamemodify ':p'/':h:h', same as S19's smoke.lua), require + setup, run
        ~14 check(cond,msg) assertions over the pure functions + one render/get_extmarks cycle +
        one open()/set_selected() decoration check, and `vim.cmd("cquit 1")` on any failure.
  - WHY: instant dependency-free feedback (no plenary). render_spec.lua is the formal suite.
  - GOTCHA: source via `:luafile`, never a `:lua <<HEREDOC` in a -c/+ arg (E5107 — S19 #10).
  - PLACEMENT: plugin/tests/smoke_render.lua.
  - DEPENDENCIES: Task 1 (menu.lua).
```

### Implementation Patterns & Key Details

```lua
-- === plugin/lua/pi-editor/menu.lua — S35 ADDITIONS/CHANGES (edit S34's module) ===
-- (These are the exact additions; they slot into S34's menu.lua. The reference impl was
--  prototyped + run green — see research/highlight-layering.md §4.)

-- (1) Near the top, after `local M = {}` and the existing module state, ADD:

--- Gap (display columns) between the label column and the description column.
local GAP = 2

--- Decoration namespace id for menu highlights (PRD §7.5). Created lazily by _ensure_ns.
---@type integer|nil
M._ns = nil

--- Cached layout from the last M.render(), so _render_selection() can re-apply highlights
--- without recomputing/reformatting (lines are unchanged on a selection move).
---@type pi-editor.MenuLayout|nil
M._layout = nil

-- (2) PURE formatting helpers (no buffer side effects — fully unit-testable) ----

--- Right-pad `s` with spaces to `width` DISPLAY columns. Never truncates a long label
--- (labels are sized into max_label_width by the caller; a label longer than the column
--- is rare and simply overflows its highlight range harmlessly).
---@param s? string
---@param width integer target display width
---@return string
local function pad_right(s, width)
  local pad = width - vim.fn.strdisplaywidth(s or "")
  if pad <= 0 then return s or "" end
  return (s or "") .. string.rep(" ", pad)
end

--- Two-column layout explanation (PRD §7.5): each row is
---   `<label padded to max_label_width>` + (GAP spaces) + `<description truncated to width - max_label_width - GAP>`.
--- Descriptions are omitted entirely when their budget (width - max_label_width - GAP) <= 0.
--- Highlight ordering: within a namespace nvim_buf_add_highlight is LAST-WINS
--- (neovim/neovim#8449), so _apply_highlights adds per-column (Pmenu/Comment) highlights
--- FIRST and the selected-row PmenuSel whole-line LAST so the selection wins.

--- Truncate `text` to `max_w` DISPLAY columns, appending "…" when cut (CJK-aware via
--- strdisplaywidth/strcharpart/strchars). Returns "" when max_w <= 0.
---@param text? string
---@param max_w integer max display columns for the result
---@return string truncated
function M._truncate(text, max_w)
  if max_w <= 0 then return "" end
  text = text or ""
  if vim.fn.strdisplaywidth(text) <= max_w then return text end
  local ell = "…"
  local budget = max_w - vim.fn.strdisplaywidth(ell)
  if budget <= 0 then return vim.fn.strcharpart(text, 0, 1) end -- only 1 cell of room
  local out, w, i, n = "", 0, 0, vim.fn.strchars(text)
  while i < n do
    local ch = vim.fn.strcharpart(text, i, 1)
    local cw = vim.fn.strdisplaywidth(ch)
    if w + cw > budget then break end
    out, w = out .. ch, w + cw
    i = i + 1
  end
  return out .. ell
end

--- Max DISPLAY width of any item's label (0 when there are no items).
---@param items? pi-editor.AutocompleteItem[]
---@return integer
function M._compute_label_width(items)
  local max_w = 0
  for _, it in ipairs(items or {}) do
    local lw = vim.fn.strdisplaywidth(it.label or "")
    if lw > max_w then max_w = lw end
  end
  return max_w
end

-- (3) REPLACE the body of S34's M._render_lines(items, width) with this (SAME signature):

--- Build two-column display lines for the menu buffer (OVERRIDES S34's basic placeholder).
--- Pure: no buffer side effects. CJK-aware via strdisplaywidth.
---@param items? pi-editor.AutocompleteItem[]
---@param width integer final window width (from compute_geometry / open)
---@return string[] lines one formatted line per item
function M._render_lines(items, width)
  items = items or {}
  local max_label = M._compute_label_width(items)
  local desc_w = width - max_label - GAP           -- description budget (display cols)
  local lines = {}
  for _, it in ipairs(items) do
    local left = pad_right(it.label or "", max_label)
    local desc = it.description
    if desc and desc ~= "" and desc_w > 0 then
      lines[#lines + 1] = left .. string.rep(" ", GAP) .. M._truncate(desc, desc_w)
    else
      lines[#lines + 1] = left                       -- no description (or no room) -> label only
    end
  end
  return lines
end

-- (4) Namespace + highlight application ----------------------------------------

--- Lazily create (once) and return the menu's decoration namespace (PRD §7.5).
---@return integer ns
function M._ensure_ns()
  if not M._ns then
    M._ns = vim.api.nvim_create_namespace("pi-editor-menu")
  end
  return M._ns
end

--- Apply menu highlights to M._buf. Contract steps: (c) CLEAR; (e) per-column label/desc;
--- (d) selected row LAST. NOTE selected_idx is 1-BASED (matches get_selected/set_selected)
--- and is converted to the 0-based line nvim_buf_add_highlight requires (GOTCHA #1).
---@param items pi-editor.AutocompleteItem[]
---@param selected_idx integer 1-based selected row (no PmenuSel if out of [1,#items])
---@param max_label_width integer from _compute_label_width
---@param width integer final window width
function M._apply_highlights(items, selected_idx, max_label_width, width)
  if not M._buf or not vim.api.nvim_buf_is_valid(M._buf) then return end
  local ns = M._ensure_ns()
  vim.api.nvim_buf_clear_namespace(M._buf, ns, 0, -1)               -- (c) clear existing (GOTCHA #6)

  local desc_start = max_label_width + GAP                           -- 0-based col where desc begins
  for i, it in ipairs(items) do
    local line = i - 1                                               -- 0-based line for the API
    -- (e) label column -> "Pmenu" over [0, max_label_width)
    vim.api.nvim_buf_add_highlight(M._buf, ns, "Pmenu", line, 0, max_label_width)
    -- (e) description column -> "Comment" (dimmed) over [desc_start, end) when on-window + present
    local desc = it.description
    if desc and desc ~= "" and desc_start < width then
      vim.api.nvim_buf_add_highlight(M._buf, ns, "Comment", line, desc_start, -1)
    end
  end

  -- (d) selected row, whole line -> "PmenuSel", added LAST so it WINS (last-wins, GOTCHA #2)
  if selected_idx and selected_idx >= 1 and selected_idx <= #items then
    vim.api.nvim_buf_add_highlight(M._buf, ns, "PmenuSel", selected_idx - 1, 0, -1)
  end
end

--- Re-apply ONLY highlights for the current items + current selection (lines unchanged).
--- Called by set_selected() on selection moves (GOTCHA #8 — never reformat on a move).
function M._render_selection()
  if not M._items or #M._items == 0 then return end
  local lay = M._layout or {}
  M._apply_highlights(M._items, M._selected, lay.max_label_width or 0, lay.width or 0)
end

--- [S35] Full paint: set buffer lines + apply highlights for `items` with `selected_idx`.
--- Ensures the buffer, builds two-column lines, writes them, caches the layout, and
--- applies the namespace highlights. open() calls this with geo.width; set_selected()
--- calls _render_selection() instead (no reformat on a move).
---@param items? pi-editor.AutocompleteItem[]
---@param selected_idx? integer 1-based selected row (default 1)
---@param width? integer window width for truncation (default: content-driven, screen-clamped)
function M.render(items, selected_idx, width)
  items = items or {}
  selected_idx = selected_idx or 1
  M._ensure_buf()
  if width == nil then
    local pi = require("pi-editor")
    local cfg = pi.config or pi.defaults
    width = M.compute_width(items, vim.o.columns, (cfg and cfg.menu and cfg.menu.border) or "rounded")
  end
  local max_label = M._compute_label_width(items)
  vim.api.nvim_buf_set_lines(M._buf, 0, -1, false, M._render_lines(items, width))  -- (b) set lines
  M._layout = { max_label_width = max_label, width = width, gap = GAP }
  M._apply_highlights(items, selected_idx, max_label, width)                        -- (c)(d)(e)
end
```

```lua
-- === WIRING into S34's open() and set_selected() (minimal, additive edits) ===

-- In S34's open(), FIND this block:
--   M._ensure_buf()
--   vim.api.nvim_buf_set_lines(M._buf, 0, -1, false, M._render_lines(items, geo.width))
--   local win_cfg = { ... }
--   ...
--   M._items = items
--   M._selected = 1                                               -- fresh list -> top item
--   -- [S35] apply two-column highlight for the selected row here.
--   return M._win
-- REPLACE the nvim_buf_set_lines line with NOTHING (render() owns set_lines now), and
-- REPLACE the [S35] comment line with a render call:
--   M._ensure_buf()
--   local win_cfg = { ... }
--   ...
--   M._items = items
--   M._selected = 1                                               -- fresh list -> top item
--   M.render(items, 1, geo.width)                                 -- [S35] two-column lines + highlight
--   return M._win

-- In S34's set_selected(), FIND:
--   M._selected = math.max(1, math.min(n, idx))
--   -- [S35] re-apply the selected-row highlight here.
--   return M._selected
-- REPLACE the [S35] comment line with a selection re-paint:
--   M._selected = math.max(1, math.min(n, idx))
--   M._render_selection()                                         -- [S35] move the PmenuSel highlight
--   return M._selected
```

```lua
-- === plugin/tests/smoke_render.lua — plenary-FREE smoke (Level-1 gate) ===
-- Run from the REPO ROOT:
--   nvim --headless --clean -u NORC +"luafile plugin/tests/smoke_render.lua" +qa ; echo exit=$?
-- Exits 0 (prints RENDER_SMOKE_PASS) or 1 (via cquit on any check failure). Zero deps.
local me = debug.getinfo(1, "S").source:sub(2)
me = vim.fn.fnamemodify(me, ":p")
local plugin_root = vim.fn.fnamemodify(me, ":h:h")               -- .../plugin (rtp entry — S19 GOTCHA #1)
vim.opt.runtimepath:append(plugin_root)

local fails = 0
local function check(c, m) if not c then io.stderr:write("FAIL: " .. m .. "\n"); fails = fails + 1 end end

require("pi-editor").setup({})
local menu = require("pi-editor.menu")

-- pure: _truncate
check(menu._truncate("hello", 10) == "hello", "truncate no-cut when it fits")
check(menu._truncate("hello world", 5) == "hell…", "truncate ellipsis cut -> hell…")
check(menu._truncate("日本語", 4) == "日…", "truncate CJK to 4 -> 日…")
check(menu._truncate("ab", 0) == "", "truncate max_w<=0 -> empty")
-- pure: _compute_label_width
check(menu._compute_label_width({ { label = "/model" }, { label = "/compact" } }) == 8, "label_width max=8")
check(menu._compute_label_width({ { label = "日本語" } }) == 6, "label_width CJK=6")
check(menu._compute_label_width({}) == 0, "label_width empty=0")
-- pure: _render_lines (two-column formatting)
local its = {
  { value = "/model", label = "/model", description = "Switch the model" },   -- width 6+2+14=22 at w=22
  { value = "/compact", label = "/compact", description = "Compact context" },
}
local lines = menu._render_lines(its, 40)                       -- max_label=8, desc_w=40-8-2=30 (no trunc)
-- "/model"(6) padded to 8 => "/model  ", then GAP(2) => "/model    " (4 spaces total), then desc
check(lines[1] == "/model    Switch the model", "line1 label padded(8)+gap(2)+desc")
check(lines[2] == "/compact  Compact context", "line2 label(8,no pad)+gap(2)+desc")
-- description omitted when budget <= 0
local narrow = menu._render_lines({ { label = "abcdef", description = "x" } }, 6) -- desc_w=6-6-2<0
check(narrow[1] == "abcdef", "description omitted when no room")

-- decoration assertions via nvim_buf_get_extmarks (screenattr is 0 headlessly — GOTCHA #3)
local function marks_of(buf, ns)
  local out = {}
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })) do
    out[#out + 1] = { row = m[2], hl = m[4].hl_group }          -- m = {id, row(0-based), col, details}
  end
  return out
end
local function count_hl(marks, hl, row)
  local n = 0
  for _, mk in ipairs(marks) do
    if mk.hl == hl and (row == nil or mk.row == row) then n = n + 1 end
  end
  return n
end

menu.render(its, 1, 40)
local mk = marks_of(menu._buf, menu._ensure_ns())
check(count_hl(mk, "PmenuSel") == 1, "exactly one PmenuSel")
check(count_hl(mk, "PmenuSel", 0) == 1, "PmenuSel at row 0 (selected 1 -> 0-based)")
check(count_hl(mk, "Pmenu") == 2, "Pmenu on both rows (label column)")
-- moving the selection moves the single PmenuSel
menu.render(its, 2, 40)
local mk2 = marks_of(menu._buf, menu._ensure_ns())
check(count_hl(mk2, "PmenuSel") == 1, "still one PmenuSel after re-render")
check(count_hl(mk2, "PmenuSel", 1) == 1, "PmenuSel moved to row 1 (selected 2)")
check(count_hl(mk2, "PmenuSel", 0) == 0, "no leftover PmenuSel at row 0 (cleared first)")

-- wiring: open() paints the selection; set_selected() moves it
local w = menu.open(its)
check(w ~= nil and menu.is_open(), "open() shows the window")
local mk3 = marks_of(menu._buf, menu._ensure_ns())
check(count_hl(mk3, "PmenuSel", 0) == 1, "open() -> PmenuSel at row 0")
menu.set_selected(2)
local mk4 = marks_of(menu._buf, menu._ensure_ns())
check(count_hl(mk4, "PmenuSel", 1) == 1, "set_selected(2) -> PmenuSel at row 1")
menu.close()

if fails > 0 then io.stderr:write(fails .. " check(s) failed\n"); vim.cmd("cquit 1") end
io.stdout:write("RENDER_SMOKE_PASS\n")
```

```lua
-- === plugin/tests/render_spec.lua — plenary/busted spec (Level-2 gate) ===
-- Run (from the plugin/ dir):
--   cd plugin && nvim --headless --clean -u tests/minimal_init.lua \
--     -c 'lua require("plenary.busted").run("tests/render_spec.lua")'
local function marks_of(menu)  -- enumerate (row, hl_group) decorations in the menu namespace
  local out = {}
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(menu._buf, menu._ensure_ns(), 0, -1, { details = true })) do
    out[#out + 1] = { row = m[2], hl = m[4].hl_group }
  end
  return out
end
local function count_hl(marks, hl, row)
  local n = 0
  for _, mk in ipairs(marks) do if mk.hl == hl and (row == nil or mk.row == row) then n = n + 1 end end
  return n
end

describe("pi-editor.menu rendering (S35)", function()
  local menu
  before_each(function()
    package.loaded["pi-editor.menu"] = nil
    package.loaded["pi-editor"] = nil
    require("pi-editor").setup({})
    menu = require("pi-editor.menu")
  end)
  after_each(function() menu.close() end)

  describe("_truncate", function()
    it("returns text as-is when it fits", function() assert.are.equals("hello", menu._truncate("hello", 10)) end)
    it("cuts with an ellipsis", function() assert.are.equals("hell…", menu._truncate("hello world", 5)) end)
    it("is CJK-aware", function() assert.are.equals("日…", menu._truncate("日本語", 4)) end)
    it("returns empty for max_w <= 0", function() assert.are.equals("", menu._truncate("ab", 0)) end)
  end)

  describe("_compute_label_width", function()
    it("is the max label display width", function()
      assert.are.equals(8, menu._compute_label_width({ { label = "/model" }, { label = "/compact" } }))
    end)
    it("counts double-width glyphs (CJK)", function() assert.are.equals(6, menu._compute_label_width({ { label = "日本語" } })) end)
    it("is 0 for empty items", function() assert.are.equals(0, menu._compute_label_width({})) end)
  end)

  describe("_render_lines (two-column)", function()
    local its = {
      { value = "/model", label = "/model", description = "Switch the model" },
      { value = "/compact", label = "/compact", description = "Compact context" },
    }
    it("pads labels to max width + gap + description", function()
      local lines = menu._render_lines(its, 40) -- max_label=8, desc_w=30 (no trunc)
      -- "/model"(6) padded to 8 => "/model  ", + GAP(2) => 4 spaces, then desc (verified live)
      assert.are.equals("/model    Switch the model", lines[1])
      assert.are.equals("/compact  Compact context", lines[2]) -- "/compact" already 8, just GAP
    end)
    it("truncates long descriptions with an ellipsis", function()
      local lines = menu._render_lines({ { label = "/x", description = "abcdefghij" } }, 10) -- desc_w=10-2-2=6
      assert.are.equals("/x  abcde…", lines[1])
    end)
    it("omits the description when there is no room", function()
      local lines = menu._render_lines({ { label = "abcdef", description = "x" } }, 6) -- desc_w<0
      assert.are.equals("abcdef", lines[1])
    end)
    it("omits the description when absent", function()
      local lines = menu._render_lines({ { label = "hi" } }, 20)
      assert.are.equals("hi", lines[1])
    end)
  end)

  describe("render + highlight decorations", function()
    local its = {
      { value = "/model", label = "/model", description = "Switch the model" },
      { value = "/compact", label = "/compact", description = "Compact context" },
    }
    it("sets lines and applies exactly one PmenuSel at the selected row (0-based)", function()
      menu.render(its, 1, 40)
      local mk = marks_of(menu)
      assert.are.equals(1, count_hl(mk, "PmenuSel"))          -- exactly one selected-row highlight
      assert.are.equals(1, count_hl(mk, "PmenuSel", 0))      -- selected 1 -> 0-based row 0
      assert.are.equals(2, count_hl(mk, "Pmenu"))            -- label column on every row
      assert.are.equals(2, count_hl(mk, "Comment"))          -- description column on every row (both have desc)
    end)
    it("moving the selected index moves the single PmenuSel (clear-then-paint)", function()
      menu.render(its, 1, 40)
      menu.render(its, 2, 40)
      local mk = marks_of(menu)
      assert.are.equals(1, count_hl(mk, "PmenuSel"))
      assert.are.equals(1, count_hl(mk, "PmenuSel", 1))      -- now at row 1
      assert.are.equals(0, count_hl(mk, "PmenuSel", 0))      -- none left at the old row
    end)
  end)

  describe("open()/set_selected() wiring", function()
    local its = {
      { value = "/model", label = "/model", description = "Switch the model" },
      { value = "/compact", label = "/compact", description = "Compact context" },
      { value = "x", label = "/x", description = "do x" },
    }
    it("open() paints the selected row; set_selected() moves it", function()
      menu.open(its)
      assert.is_true(menu.is_open())
      assert.are.equals(1, count_hl(marks_of(menu), "PmenuSel", 0))
      menu.set_selected(2)
      assert.are.equals(1, count_hl(marks_of(menu), "PmenuSel", 1))
      assert.are.equals(0, count_hl(marks_of(menu), "PmenuSel", 0))
      menu.set_selected(3)
      assert.are.equals(1, count_hl(marks_of(menu), "PmenuSel", 2))
    end)
  end)
end)
```

### Integration Points

```yaml
MODULE SURFACE (public/internal API — additions to S34's locked surface):
  - require("pi-editor.menu").render(items, selected_idx?, width?)   (the contract's M.render)
  - require("pi-editor.menu")._render_selection()                     (set_selected() calls this)
  - INTERNAL (testable): _truncate(text, max_w) / _compute_label_width(items) /
    _render_lines(items, width) / _apply_highlights(items, sel, max_label, width) /
    _ensure_ns()  ;  fields M._ns, M._layout, local GAP = 2

S34 SEAMS FILLED (do NOT change anything else in open()/set_selected()):
  - open():   the `-- [S35] apply two-column highlight` line -> `M.render(items, 1, geo.width)`;
              REMOVE the earlier inline `nvim_buf_set_lines(M._buf, 0, -1, false, M._render_lines(items, geo.width))`
              (render() now owns set_lines).
  - set_selected(): the `-- [S35] re-apply the selected-row highlight` line -> `M._render_selection()`.

CONFIG (reads S19 — do NOT redefine or add keys):
  - render()'s width fallback reads (require("pi-editor").config or .defaults).menu.border — same
    pattern S34's menu_config() uses. menu.max_height/border are S19's contract (unchanged).

HIGHLIGHT GROUPS (builtin — do NOT define them): "PmenuSel" (selected row), "Pmenu" (label column),
  "Comment" (description column, dimmed). All resolve in stock nvim (GOTCHA #7).

FORWARD CONTRACTS (do NOT implement here):
  - S36 (key handling) maps <C-N>/<C-P>/<Up>/<Down> to M.move(±1) (-> set_selected -> _render_selection
    moves the highlight), <C-E> to M.close(), <Tab>/<C-Y>/<CR> accept M.get_item() then M.close().
  - S37 (auto-close) calls M.close() from its autocmds.
  - S32 (accept flow) calls M.get_item() to read the selected AutocompleteItem.value.

NO DATABASE / NO NETWORK / NO AUTOCMDS / NO KEYMAPS / NO NEW OPTIONS in this task (GOTCHA #9).
```

## Validation Loop

> **Run all commands from the REPO ROOT** (`/home/dustin/projects/pi-nvim-bridge`).
> The plugin root is `$(pwd)/plugin`. **Every API behavior referenced is LIVE-VERIFIED**
> (research/highlight-layering.md: namespace, clear, add_highlight, last-wins, CJK truncation).
> The smoke + plenary commands run green once `menu.lua` (S34) + the S35 edits + the two new
> test files ship.

### Level 1: Syntax & Load (Immediate Feedback — dependency-free, no plenary)

```bash
# 1a. Smoke test via the deliverable plugin/tests/smoke_render.lua (plenary-FREE fast feedback).
#     Sets its own runtimepath + cquit(1) on failure. Source via :luafile (never a -c/+ heredoc).
#     Run from the REPO ROOT.
nvim --headless --clean -u NORC +"luafile plugin/tests/smoke_render.lua" +qa
echo "exit=$?   # 0 = pass (prints RENDER_SMOKE_PASS), 1 = a check failed"
```

```bash
# 1b. (Optional, only if installed) Lua lint/format. NOT a hard gate.
command -v selene >/dev/null && selene -q plugin/lua/pi-editor/menu.lua || echo "selene not installed (skipped; optional)"
command -v stylua >/dev/null && stylua --check plugin || echo "stylua not installed (skipped; optional)"
```

### Level 2: Unit Tests (plenary spec — the formal formatting + decoration gate)

```bash
# 2a. In-process plenary run (reuses S19's tests/minimal_init.lua harness — no new bootstrap).
cd plugin
nvim --headless --clean -u tests/minimal_init.lua \
  -c 'lua require("plenary.busted").run("tests/render_spec.lua")'
echo "exit=$?"   # 0 = all pass; 1 = an 'it' failed; 2 = load/error
cd ..
# Expected: ~17 'it' blocks pass (truncate×4, label_width×3, render_lines×4, render×2, wiring×1, ...).
# Also re-run S34's suite to prove the open()/set_selected() edits did not regress lifecycle/geometry:
nvim --headless --clean -u tests/minimal_init.lua -c 'lua require("plenary.busted").run("tests/menu_spec.lua")'
echo "menu_spec exit=$?   # 0 = S34 still green after the [S35] seam edits"
```

### Level 3: Integration (runtimepath + real buffer decorations)

```bash
# 3a. Prove the decorations land on the right rows after render() (the rendering contract),
#     enumerated via nvim_buf_get_extmarks (screenattr is 0 headlessly — GOTCHA #3).
PLUGIN_ROOT="$(pwd)/plugin"
nvim --headless --clean -u NORC +"lua vim.opt.runtimepath:append('$PLUGIN_ROOT')" \
  +'lua require("pi-editor").setup({}); local m=require("pi-editor.menu"); m.render({{value="a",label="/model",description="x"},{value="b",label="/compact",description="y"}},1,40); local cnt=0; for _,mk in ipairs(vim.api.nvim_buf_get_extmarks(m._buf,m._ensure_ns(),0,-1,{details=true})) do if mk[4].hl_group=="PmenuSel" then cnt=cnt+1; io.stdout:write("PmenuSel row="..mk[2].."\n") end end; io.stdout:write("pmenusel_count="..cnt.."\n")' \
  +qa 2>&1 | tail -2
# Expected: PmenuSel row=0  ;  pmenusel_count=1   (selected 1 -> 0-based row 0; exactly one)

# 3b. Verify open() (S34 lifecycle) still works AND paints the selection (the [S35] seam in open()).
nvim --headless --clean -u NORC +"lua vim.opt.runtimepath:append('$PLUGIN_ROOT')" \
  +'lua require("pi-editor").setup({}); local m=require("pi-editor.menu"); local w=m.open({{value="a",label="/model",description="x"},{value="b",label="/compact"}}); local sel=0; for _,mk in ipairs(vim.api.nvim_buf_get_extmarks(m._buf,m._ensure_ns(),0,-1,{details=true})) do if mk[4].hl_group=="PmenuSel" then sel=mk[2] end end; io.stdout:write("open_win="..tostring(w).." pmenusel_row="..sel.."\n"); m.close()' \
  +qa 2>&1 | tail -1
# Expected: open_win=<id> pmenusel_row=0   (open() painted the selection at row 0; window still valid)
```

### Level 4: Creative & Domain-Specific Validation (two-column + ordering proof)

```bash
# 4a. Prove the two-column formatting is CJK-correct and truncates with ellipsis (the pure helper).
nvim --headless --clean -u NORC +"lua vim.opt.runtimepath:append('$PLUGIN_ROOT')" \
  +'lua local m=require("pi-editor.menu"); require("pi-editor").setup({}); local L=m._render_lines({{label="/model",description="Switch the model"},{label="日本語",description="a long description"}},18); for i,l in ipairs(L) do io.stdout:write(i..":["..l.."] w="..vim.fn.strdisplaywidth(l).."\n") end' \
  +qa 2>&1 | tail -3
# Expected: line1 label padded to 6 + gap + truncated desc; line2 CJK label width 6 + gap + truncated.
#   (max_label = max(6,6) = 6; desc_w = 18-6-2 = 10)

# 4b. Prove last-wins ordering: the selected row's PmenuSel is added AFTER the per-column highlights
#     so it wins. Enumerate ALL decorations on the selected row in insertion order.
nvim --headless --clean -u NORC +"lua vim.opt.runtimepath:append('$PLUGIN_ROOT')" \
  +'lua require("pi-editor").setup({}); local m=require("pi-editor.menu"); m.render({{label="/a",description="x"},{label="/bb",description="y"}},2,30); for _,mk in ipairs(vim.api.nvim_buf_get_extmarks(m._buf,m._ensure_ns(),0,-1,{details=true})) do if mk[2]==1 then io.stdout:write("row1: hl="..mk[4].hl_group.."\n") end end' \
  +qa 2>&1 | tail -5
# Expected (selected row 1 = the 2nd item, 0-based): three marks on row 1 in insertion order —
#   "Pmenu" (label), "Comment" (desc), then "PmenuSel" (whole line, added LAST -> wins on screen).
```

## Final Validation Checklist

### Technical Validation

- [ ] Level 1 smoke test prints `RENDER_SMOKE_PASS` and `exit=0`.
- [ ] Level 2 `render_spec.lua` exits 0 (~17 `it` blocks); `menu_spec.lua` STILL exits 0
      (S34 not regressed by the `[S35]` seam edits).
- [ ] Level 3a: `render(items,1,40)` yields exactly ONE `PmenuSel` at row 0 (via get_extmarks).
- [ ] Level 3b: `open(items)` paints `PmenuSel` at row 0 AND returns a valid window.
- [ ] Level 4: two-column formatting is CJK-correct + ellipsis-truncating; selected row shows
      `Pmenu`→`Comment`→`PmenuSel` insertion order (last wins).
- [ ] (Optional) selene/stylua clean IF installed (NOT a hard gate).

### Feature Validation

- [ ] `_truncate` / `_compute_label_width` / `_render_lines` produce the verified formatted lines.
- [ ] `M.render(items, selected_idx, width)` sets lines AND applies highlights.
- [ ] Exactly ONE `PmenuSel` decoration exists, at row `selected_idx - 1` (0-based).
- [ ] `Pmenu` on every row's label range; `Comment` on rows with an on-window description.
- [ ] Re-rendering CLEARS first — no stale `PmenuSel` from a previously-selected row.
- [ ] `M.open(items)` (S34) opens a valid window with correct width/height; the `[S35]` seam
      now drives `M.render` (lines + highlight).
- [ ] `M.set_selected(k)` (S34) moves the single `PmenuSel` to row `k-1`.
- [ ] [Mode A] LuaCATS annotations on all new functions + a section docstring (two-column
      layout + last-wins ordering).

### Code Quality Validation

- [ ] `selected_idx` converted to 0-based (`-1`) for every `nvim_buf_add_highlight` line (GOTCHA #1).
- [ ] `_apply_highlights` adds the selected-row `PmenuSel` LAST (last-wins, GOTCHA #2).
- [ ] `_apply_highlights` CLEARS the namespace before every paint (GOTCHA #6).
- [ ] Widths computed with `vim.fn.strdisplaywidth`; truncation with `strcharpart`/`strchars` (GOTCHA #5).
- [ ] `_render_lines` is PURE (no `vim.api`); buffer/highlight writes only in `render`/`_apply_highlights`.
- [ ] S34's lifecycle/geometry/clamping/selection-clamp code is UNCHANGED (only the two seams filled).
- [ ] No new autocmds / keymaps / options / highlight-group definitions (GOTCHA #9, GOTCHA #7).
- [ ] Public/internal names EXACTLY: `render`, `_render_selection`, `_apply_highlights`, `_render_lines`,
      `_compute_label_width`, `_truncate`, `_ensure_ns` (forward contracts for S32/S36).

### Documentation & Deployment

- [ ] [Mode A] section docstring explains the two-column layout AND the last-wins highlight
      ordering (the contract's docstring requirement).
- [ ] No new env vars, config keys, autocmds, or keymaps introduced.
- [ ] (doc/pi-editor.txt + README are separate tasks — S43/S44, NOT this task.)

---

## Anti-Patterns to Avoid

- ❌ Don't pass the 1-based `selected_idx` straight to `nvim_buf_add_highlight` as the line —
  it's 0-indexed; you'll highlight the row BELOW the selection (off by one). Use `selected_idx - 1`
  (GOTCHA #1). Tests must expect the `PmenuSel` mark at `row == selected_idx - 1`.
- ❌ Don't add the selected-row `PmenuSel` highlight BEFORE the per-column highlights and expect
  it to win — within a namespace, LAST wins (neovim/neovim#8449). Add `PmenuSel` whole-line LAST
  (GOTCHA #2).
- ❌ Don't forget to `nvim_buf_clear_namespace(buf, ns, 0, -1)` at the start of every paint —
  the buffer is reused across opens/selections and stale decorations would linger (GOTCHA #6).
- ❌ Don't assert rendered COLORS via `screenattr()` in `--headless` — it returns 0 (GOTCHA #3,
  same class as S34's `screenrow()`). Assert DECORATIONS via `nvim_buf_get_extmarks`.
- ❌ Don't use `#s` / `string.sub` for widths/truncation — they're byte-based and break on CJK.
  Use `strdisplaywidth` / `strcharpart` / `strchars` (GOTCHA #5).
- ❌ Don't reformat lines on a selection MOVE — `set_selected()` calls `_render_selection()`,
  which re-applies ONLY highlights from the cached `M._layout` (GOTCHA #8).
- ❌ Don't assert `end_col` from a whole-line highlight's extmark details — it's `0` (the `-1`
  sentinel); assert `hl_group` + `row` (GOTCHA #4).
- ❌ Don't touch S34's window geometry/positioning/clamping or selection clamping — this task
  only fills the two `[S35]` seams and adds rendering (GOTCHA #9).
- ❌ Don't define `PmenuSel`/`Pmenu`/`Comment` highlight groups — they're builtin; just reference
  the names (GOTCHA #7).
- ❌ Don't create `menu_spec.lua`/`smoke_menu.lua` — those are S34's; this task ships
  `render_spec.lua`/`smoke_render.lua` (distinct files, no collision).
