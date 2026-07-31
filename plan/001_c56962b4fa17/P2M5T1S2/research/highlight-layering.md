# Research — Item rendering & highlight layering (task S35 / PRP path P2M5T1S2)

Every API behavior below was **LIVE-VERIFIED** against the installed Neovim 0.12.4
(`nvim --headless --clean -u NORC +"luafile …" +qa`). This file is the evidence base
for the rendering/highlight design in `PRP.md`.

## 0. Environment

- `nvim --version` → `NVIM v0.12.4`.
- `plugin/lua/pi-editor/menu.lua` does **NOT** exist yet — **S34 (PRP path P2M5T1S1)
  creates it in parallel.** This task (S35) ENHANCES that module: replaces the
  `_render_lines` placeholder, adds namespace + highlight logic, adds `M.render`, and
  wires the two `[S35]` seams left by S34 (in `open()` and `set_selected()`).
- S34's contract (read at `plan/001_c56962b4fa17/P2M5T1S1/PRP.md`) defines the module
  fields/state this task builds on: `_items`, `_selected` (1-based), `_buf`, `_win`,
  `_ensure_buf()`, the basic `_render_lines(items, width)`, and the `[S35]` seams.

## 1. Namespace + buffer highlight mechanics (VERIFIED)

```lua
local ns = vim.api.nvim_create_namespace("pi-editor-menu")   -- returns a NUMBER id (e.g. 3)
-- decorate:
vim.api.nvim_buf_add_highlight(buf, ns, "Error", line, col_start, col_end)  -- line is 0-based
-- enumerate decorations in the namespace:
local marks = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })
-- each mark = { id, row(0-based), col, details = { end_col, hl_group, ... } }
-- clear ALL decorations in the namespace (line range 0..-1):
vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
```

**Verified output** (5 highlights added → 5 marks; clear → 0 marks):
```
ns=3 (type number)
extmark_count=5
  mark id=1 row=0 col_end=6 hl_group=Error
  mark id=4 row=1 col_end=0 hl_group=Comment
  mark id=5 row=1 col_end=0 hl_group=IncSearch
after_clear_count=0 (expect 0)
```

Conclusions:
- `nvim_create_namespace` returns a stable numeric id; safe to cache on the module.
- A whole-line highlight `add_highlight(buf, ns, hl, line, 0, -1)` enumerates with
  `end_col == 0` in the details (the `-1` sentinel is how it shows up) — **so in tests,
  assert the mark's `hl_group` + `row`, NOT `end_col`.**
- `nvim_buf_clear_namespace(buf, ns, 0, -1)` reliably wipes every decoration in `ns`.
  This is the contract's step (c) "clear existing highlights."

## 2. Stacking order = LAST-WINS within a namespace (VERIFIED via upstream)

> neovim/neovim#8449: *"nvim_buf_add_highlight, so whoever adds the highlight **second
> wins** and overshadows the previous highlight."*

This is THE key fact for the selected-row highlight. The correct, verified render order
inside `_apply_highlights` is:

1. **CLEAR** the namespace (step c).
2. Per-row **column** highlights: label range `[0, max_label_width)` → `"Pmenu"`;
   description range `[max_label_width+GAP, end)` → `"Comment"` (dimmed).
3. **Selected row, whole line `[0, -1)` → `"PmenuSel"`, added LAST** → it overrides the
   per-column highlights on that one row (the user sees a single selected line).

Because label and description ranges do not overlap each other, their relative order is
irrelevant; only the selected-row highlight must be added AFTER them to win.

> Note: a `priority` parameter exists on the newer `nvim_buf_set_extmark` extmark API,
> but `nvim_buf_add_highlight` (the contract's mandated call) has no per-call priority —
> ordering by insertion is the mechanism. Adding the selected-row highlight last is
> therefore the deterministic way to guarantee it wins.

## 3. `screenattr()` is UNRELIABLE in --headless (testing gotcha — mirrors S34)

`vim.fn.screenattr(row, col)` returns **0** for every cell in `--headless` regardless of
the applied highlights (verified: selected-row label cell and unselected-row label cell
both returned `0`). This is the **same class of limitation** as S34's `screenrow()`/
`screencol()` being pinned to 1 headlessly.

**Implication (testing strategy, identical philosophy to S34):**
- The PRODUCTION code still calls `nvim_buf_add_highlight` per the contract (it renders
  correctly interactively).
- The **TESTS assert the DECORATIONS via `nvim_buf_get_extmarks`** (which group was added
  to which row, and that the selected row's group is `PmenuSel`), NOT the rendered color.
- This is exactly analogous to S34 testing `compute_geometry` (pure) instead of a clamped
  `screenrow()`. Here we assert the highlight *mechanism* (extmarks) instead of the
  *rendered pixels* (which need a real terminal + colorscheme).

## 4. CJK-correct two-column formatting (VERIFIED)

Pure helpers verified green headlessly:

```
line=[/model      Switch the …] width=24 (label padded to 10 + gap 2 + desc truncated to 12)
line=[日本語  a long …]        width=16 (CJK label display width = 6)
line=[/x    veryl…]            width=12 (desc truncated with "…")
line=[/y    ab]                width=8  (short desc, no truncation, no ellipsis)
```

Helpers used (all `vim.fn`, double-width-aware):
- `vim.fn.strdisplaywidth(s)` → display columns (CJK = 2/char). **NOT** `#s`.
- `vim.fn.strcharpart(s, start, len)` → substring by *char* (codepoint), not byte.
- `vim.fn.strchars(s)` → char count (not byte count).

The `_truncate(text, max_w)` algorithm: if `strdisplaywidth(text) <= max_w` return as-is;
else set `budget = max_w - strdisplaywidth("…")`, greedily append chars while cumulative
width ≤ budget, then append `"…"`. If `budget <= 0` (only 1 cell of room) return the first
char. Returns `""` when `max_w <= 0`.

## 5. Highlight groups exist in stock nvim (VERIFIED)

`vim.api.nvim_get_hl(0, {name=…, create=false, link=true})` resolves all three contract
groups in `--clean`:
- `PmenuSel` — the popup-menu selected-line group (resolves to a real hl).
- `Pmenu` — the popup-menu normal group (has a bg).
- `Comment` — the comment group (has a dimmed fg) — used for the description column.

All three are built-in; no `:highlight` setup is required.

## 6. The 1-based ↔ 0-indexed trap (CRITICAL)

- S34's `M._selected`, `M.get_selected()`, `M.set_selected()` are **1-based** (reset to 1
  on open, clamped to `[1, #items]`).
- `nvim_buf_add_highlight(buf, ns, hl, line, …)` and `nvim_buf_get_extmarks` use
  **0-based** rows.
- => `_apply_highlights` MUST pass `selected_idx - 1` as the line. Tests MUST expect the
  `PmenuSel` decoration at row `selected_idx - 1`. This is the single most common bug;
  it is called out as GOTCHA #1 in the PRP.

## 7. AutocompleteItem shape (PRD §5.4 — VERIFIED in prd_snapshot)

```ts
interface AutocompleteItem { value: string; label: string; description?: string; }
```

`label` is always present; `description` is OPTIONAL. `_render_lines` / `_apply_highlights`
must tolerate `description == nil` or `""` (omit the description column for that row; the
line is just the padded label). `value` is the text pi inserts (consumed by S32's accept
flow via `M.get_item()`, untouched by rendering).
