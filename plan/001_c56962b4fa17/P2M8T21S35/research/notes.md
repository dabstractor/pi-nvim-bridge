# Research — S35: Item rendering — two-column label/description + selected-row highlight

Consolidates the **live-verified** evidence (from
`plan/001_c56962b4fa17/P2M5T1S2/research/highlight-layering.md`, run against the
installed `NVIM v0.12.4`) with the **actual shipped S31/S34 module shape** of
`plugin/lua/pi-editor/menu.lua`, so the implementing agent can edit one file with
zero guessing. The P2M5T1S2 research was written against a *draft* API
(`_items` / `_selected` / `_render_lines` / `_apply_highlights` / `M.set_selected()`);
the real module uses `state.items` / `state.selected` (1-based) / a LOCAL `render_lines`
/ a LOCAL `render` / `M.open(items)`. §1 maps the two precisely.

## 0. Scope & non-goals (read FIRST)

- **S35 ENHANCES `menu.lua`'s SHOW path only.** It widens `render_lines` from
  label-only to **two-column** (label + gap + description), widens `compute_width`
  to budget for the description column, and **adds highlight application** (a NEW
  local `apply_highlights`) inside `render()` after `nvim_buf_set_lines`.
- **DO NOT implement navigation** (`next`/`prev`/`dismiss`) — that is **S36**. S35
  only re-applies highlights each time `render()` runs (which `open(items)` triggers
  with `state.selected == 1`; S36 will later change `state.selected` and call
  `render()` again — S35's highlight logic must already honor `state.selected`).
- **DO NOT implement auto-close autocmds** — that is **S37**.
- **DO NOT change the state layer** (`open`/`close`/`reset`/`on_results`/`get_*`) or
  the geometry helpers (`compute_geometry`/`compute_height`) — S31/S34 own them.
  S35 is **additive**: enhance `compute_width` + `render_lines`, add
  `apply_highlights` + `_truncate` + `column_metrics`, add a module namespace.
- **DO NOT touch** `init.lua`, `completion.lua`, the bridge, or the ftplugin. S35 is
  **contained to `menu.lua` + its tests**.

## 1. The S34 baseline (what S35 builds ON — verified by reading the shipped file)

`plugin/lua/pi-editor/menu.lua` currently:

- Has a module-level `state` singleton with `items`, `selected` (**1-based**: 1 after
  `open()`, 0 after `close()`), `open`, `win`, `menu_buf`, `buf`, `prefix`.
- Has 3 PURE geometry helpers (`compute_width`, `compute_height`, `compute_geometry`)
  exposed as `M._compute_*` (test seams).
- Has a LOCAL `render_lines(state, width)` that builds **label-only** lines padded to
  `width` (S34 content):
  ```lua
  local function render_lines(state, width)
    local lines = {}
    for i = 1, #state.items do
      local it = state.items[i]
      local label = (type(it) == "table" and type(it.label) == "string") and it.label or ""
      local lw = vim.fn.strdisplaywidth(label)
      lines[i] = label .. string.rep(" ", math.max(0, width - lw))
    end
    return lines
  end
  ```
- Has a LOCAL `render(state)` with a SHOW path that: `ensure_menu_buf` → reads config
  FRESH → live `screenrow`/`screencol` → `compute_width`/`compute_height` →
  `compute_geometry` → `nvim_buf_set_lines(buf, 0, -1, false, render_lines(state, g.width))`
  → `nvim_open_win` (or `nvim_win_set_config` if reusing) → sets `wrap=false`. **S35
  inserts the highlight call immediately after the `set_lines` pcall.**
- `M._state = state` is already exposed (test seam — S34 added it).

**The single seam S35 edits:** inside `render()`'s SHOW path, after
`pcall(vim.api.nvim_buf_set_lines, buf, 0, -1, false, render_lines(state, g.width))`,
add `apply_highlights(state, buf, label_w, desc_w)` (compute `label_w`/`desc_w` from
`g.width` + the items). And `render_lines` + `compute_width` are widened to two-column.

## 2. Live-verified highlight mechanics (from highlight-layering.md §1, §2, §5)

Every behavior below was verified headlessly against `NVIM v0.12.4`:

```lua
local ns = vim.api.nvim_create_namespace("pi-editor-menu")  -- returns a NUMBER id (e.g. 3); safe to cache at module scope
vim.api.nvim_buf_add_highlight(buf, ns, "PmenuSel", line, col_start, col_end)  -- line is 0-BASED
vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)            -- wipes every decoration in ns (reliable)
local marks = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })
-- each mark = { id, row(0-based), col, details = { end_col, hl_group, ... } }
```

- **`nvim_create_namespace`** returns a stable numeric id → cache ONCE at module scope.
- **Stacking order = LAST-WINS within a namespace** (neovim/neovim#8449: "whoever adds
  the highlight second wins"). `nvim_buf_add_highlight` has **no per-call priority**
  param → **insertion order is the mechanism**. ⇒ Apply in this deterministic order:
  1. CLEAR the namespace (`nvim_buf_clear_namespace(buf, ns, 0, -1)`).
  2. BASE: every row, whole line `[0, -1)` → `Pmenu` (uniform popup background so GAP
     + trailing-pad cells are NOT left as `NormalFloat` — a seam in some colorschemes).
  3. DESCRIPTION: each row that HAS a description, range
     `[label_w + DESC_GAP, label_w + DESC_GAP + desc_display_w)` → `Comment` (dimmed
     fg; `Comment` has fg only → it inherits `Pmenu`'s bg for the desired look). Added
     AFTER the base so it wins on those cells.
  4. SELECTED: the selected row, whole line `[0, -1)` → `PmenuSel`, added **LAST** so
     it wins on the selected row (overrides base `Pmenu` + the desc `Comment`).
  - Because label/desc ranges never overlap the selected whole-line range's coverage,
    only the selected row's highlight must be added last to guarantee it wins.
- **The 3 groups exist in stock nvim** (`nvim_get_hl(0, {name=…, create=false, link=true})`
  resolves `Pmenu`/`PmenuSel`/`Comment` in `--clean`) → **no `:highlight` setup needed.**
- **`screenattr()` is UNRELIABLE in `--headless`** (returns 0 for every cell) → the
  SAME class of limitation as S34's `screenrow()`/`screencol()`. **Tests assert the
  DECORATIONS via `nvim_buf_get_extmarks`** (which group landed on which row, and that
  the selected row's group is `PmenuSel`), NOT the rendered color. (§5 below.)

> **Design note (vs. the literal P2M5T1S2 research):** that doc specified only
> label→`Pmenu` + desc→`Comment` + selected→`PmenuSel`. S35 ADDS a base whole-line
> `Pmenu` (step 2) so the GAP + trailing-pad cells share the popup background — strictly
> better colorscheme robustness, still within the verified mechanism (`add_highlight`
> whole-line `[0,-1)` is verified in §1 of that file).

## 3. The two-column layout design (the S35 code shape)

A module-local constant for the inter-column gap (PRD §10.5 does not list a config
option for it; keep it a module constant — NOT configurable in v1):

```lua
local DESC_GAP = 2   -- blank cells between the label column and the description column
```

### 3a. PURE `column_metrics(items)` — the shared width computation (NEW, exposed)

`compute_width` (S34) and `render()` (S35) both need the max label width + whether any
item has a description. Factor it into ONE pure helper (DRY; deterministic-testable):

```lua
--- Max label + max description display widths + whether any item has a description.
--- PURE (no nvim state). type-guards each item (never throws). Exposed as M._column_metrics.
---@param items pi-editor.AutocompleteItem[]
---@return { max_label_w: integer, max_desc_w: integer, any_desc: boolean }
local function column_metrics(items)
  local max_label_w, max_desc_w, any_desc = 0, 0, false
  for _, it in ipairs(items) do
    if type(it) == "table" then
      if type(it.label) == "string" then
        local lw = vim.fn.strdisplaywidth(it.label)
        if lw > max_label_w then max_label_w = lw end
      end
      if type(it.description) == "string" and it.description ~= "" then
        any_desc = true
        local dw = vim.fn.strdisplaywidth(it.description)
        if dw > max_desc_w then max_desc_w = dw end
      end
    end
  end
  return { max_label_w = max_label_w, max_desc_w = max_desc_w, any_desc = any_desc }
end
```

### 3b. `compute_width` — ENHANCE (two-column total; collapses to label-only when no desc)

```lua
local function compute_width(items, ui_cols, border_h_overhead)
  local m = column_metrics(items)
  local w = m.any_desc and (m.max_label_w + DESC_GAP + m.max_desc_w) or m.max_label_w
  return math.max(1, math.min(w, ui_cols - border_h_overhead))
end
```

> **Backward-compat (the elegant part):** when NO item has a description, `any_desc`
> is false → `compute_width` returns `max_label_w` — **identical to S34**. Every
> existing `menu_geometry_spec.lua` compute_width case uses label-only items, so they
> ALL still pass unchanged. S35 only ADDS two-column cases.

### 3c. PURE `_truncate(text, max_w)` — ellipsis truncation (NEW, exposed)

Verified-green algorithm (highlight-layering.md §4). Uses `vim.fn` char-aware helpers
(NOT `#s` — CJK/double-width = 2 cells):

```lua
--- Truncate `text` to <= max_w DISPLAY cells, appending "…" when truncated.
--- PURE. Returns "" when max_w <= 0; returns the first char when only 1 cell of room.
---@param text string
---@param max_w integer max display width
---@return string
local function _truncate(text, max_w)
  if type(text) ~= "string" or max_w <= 0 then return "" end
  if vim.fn.strdisplaywidth(text) <= max_w then return text end
  local ellipsis = "…"
  local budget = max_w - vim.fn.strdisplaywidth(ellipsis)
  if budget <= 0 then
    -- only 1 cell of room: show the first char alone (no ellipsis fits)
    local first = vim.fn.strcharpart(text, 0, 1)
    return first
  end
  local out, w = "", 0
  local n = vim.fn.strchars(text)
  for i = 0, n - 1 do
    local ch = vim.fn.strcharpart(text, i, 1)
    local cw = vim.fn.strdisplaywidth(ch)
    if w + cw > budget then break end
    out = out .. ch
    w = w + cw
  end
  return out .. ellipsis
end
```

Verified sample (headless): `"/x"` truncated to 5 → `"/x"` (fits); `"verylong"` to 5 →
`"ver…"`; CJK `"日本語です"` to 5 → `"日本"` + `"…"` (each CJK char = 2 cells).

### 3d. `render_lines(state, label_w, desc_w)` — ENHANCE (two-column; pads to a rectangle)

```lua
local function render_lines(state, label_w, desc_w)
  local total = label_w + (desc_w > 0 and DESC_GAP or 0) + desc_w
  local lines = {}
  for i = 1, #state.items do
    local it = state.items[i]
    local label = (type(it) == "table" and type(it.label) == "string") and it.label or ""
    local lw = vim.fn.strdisplaywidth(label)
    local row = label .. string.rep(" ", math.max(0, label_w - lw))   -- label col, right-padded
    if desc_w > 0 and type(it) == "table" and type(it.description) == "string" and it.description ~= "" then
      row = row .. string.rep(" ", DESC_GAP)                          -- the gap
      local dt = _truncate(it.description, desc_w)                    -- desc, truncated
      local dw = vim.fn.strdisplaywidth(dt)
      row = row .. dt .. string.rep(" ", math.max(0, desc_w - dw))    -- desc col, right-padded
    elseif desc_w > 0 then
      -- column allocated but THIS row has no description: pad the desc col with blanks
      row = row .. string.rep(" ", DESC_GAP + desc_w)
    end
    -- final pad so every line is exactly `total` cells (clean rectangle; CJK-safe)
    local rw = vim.fn.strdisplaywidth(row)
    lines[i] = row .. string.rep(" ", math.max(0, total - rw))
  end
  return lines
end
```

> **Signature change:** S34's `render_lines(state, width)` → S35's
> `render_lines(state, label_w, desc_w)`. It is a LOCAL fn (only `render()` calls it),
> so the signature change is safe (no external callers). `render()` computes
> `label_w`/`desc_w` from `g.width` (see §3e).

### 3e. `apply_highlights(state, buf, label_w, desc_w)` — NEW local fn, called from render()

```lua
local function apply_highlights(state, buf, label_w, desc_w)
  if type(buf) ~= "number" or not vim.api.nvim_buf_is_valid(buf) then return end
  if type(ns) ~= "number" then return end                              -- namespace create failed → degrade
  -- (a) CLEAR every prior decoration (reliable; highlight-layering.md §1)
  pcall(vim.api.nvim_buf_clear_namespace, buf, ns, 0, -1)
  local n = #state.items
  if n == 0 then return end
  local desc_start = label_w + DESC_GAP
  -- (b) BASE: whole-line Pmenu on every row (uniform popup bg incl. gap + trailing pad)
  for i = 1, n do
    pcall(vim.api.nvim_buf_add_highlight, buf, ns, "Pmenu", i - 1, 0, -1)
  end
  -- (c) DESCRIPTION: Comment on the desc range of rows that HAVE one (added after base → wins)
  if desc_w > 0 then
    for i = 1, n do
      local it = state.items[i]
      if type(it) == "table" and type(it.description) == "string" and it.description ~= "" then
        local dw = math.min(desc_w, vim.fn.strdisplaywidth(it.description))
        if dw > 0 then
          pcall(vim.api.nvim_buf_add_highlight, buf, ns, "Comment", i - 1, desc_start, desc_start + dw)
        end
      end
    end
  end
  -- (d) SELECTED: whole-line PmenuSel on the selected row, added LAST → wins (1-based→0-based)
  if type(state.selected) == "number" and state.selected >= 1 and state.selected <= n then
    pcall(vim.api.nvim_buf_add_highlight, buf, ns, "PmenuSel", state.selected - 1, 0, -1)
  end
end
```

### 3f. The render() SHOW-path wiring (compute label_w/desc_w from g.width)

After `g = compute_geometry(...)` and BEFORE `nvim_buf_set_lines`, compute the column
split from the FINAL `g.width` (compute_geometry may have clamped it further than
`compute_width` — e.g. case 5 over-wide pins left + clamps width). Then build lines +
apply highlights:

```lua
  local g = compute_geometry(sr, sc, ui_lines, ui_cols, width, height, max_height, border)
  local m = column_metrics(state.items)
  local label_w = m.max_label_w
  local desc_w  = m.any_desc and math.max(0, g.width - label_w - DESC_GAP) or 0
  -- when the description budget is too thin (< ~3 cells) drop the column rather than show noise:
  if m.any_desc and desc_w < 3 then desc_w = 0 end
  pcall(vim.api.nvim_buf_set_lines, buf, 0, -1, false, render_lines(state, label_w, desc_w))
  apply_highlights(state, buf, label_w, desc_w)   -- ← THE S35 INSERTION
  local win_cfg = { ... }                          -- (unchanged from S34)
```

> The `desc_w < 3` floor keeps the menu from showing a 1–2 cell description sliver when
  the screen is very narrow; it collapses to label-only in that case. Tunable; 3 is a
  sane default (fits a 1-char desc + the ellipsis is dropped → just show labels).

## 4. The 1-based ↔ 0-indexed trap (CRITICAL — the #1 bug source)

- `state.selected` is **1-based** (S31: `1` after `open()`, `0` after `close()`).
- `nvim_buf_add_highlight(buf, ns, hl, line, …)` and `nvim_buf_get_extmarks` use
  **0-based** rows.
- ⇒ `apply_highlights` passes `state.selected - 1` as the line. **Tests must expect the
  `PmenuSel` decoration at row `state.selected - 1`** (row 0 when `selected == 1`).
- After `close()`, `state.selected == 0` → the `selected >= 1` guard skips PmenuSel
  (and `n == 0` returns early anyway). No off-by-one highlight.

## 5. Headless testing gotcha — assert DECORATIONS, not pixels (mirrors S34)

`vim.fn.screenattr(row, col)` returns **0** for every cell in `--headless` regardless of
applied highlights (verified). So tests CANNOT assert rendered color. Instead assert the
**decoration mechanism** via `nvim_buf_get_extmarks`:

```lua
local function hl_groups_on_row(buf, ns, row0)
  local marks = vim.api.nvim_buf_get_extmarks(buf, ns, {row0, 0}, {row0, -1}, { details = true })
  local groups = {}
  for _, mk in ipairs(marks) do
    if mk[4] and mk[4].hl_group then groups[mk[4].hl_group] = true end
  end
  return groups
end
-- after open() with selected=1: row 0 has PmenuSel (and Pmenu base); other rows have Pmenu.
local g0 = hl_groups_on_row(mbuf, ns, 0); assert(g0.PmenuSel == true)
local g1 = hl_groups_on_row(mbuf, ns, 1); assert(g0.PmenuSel == nil); assert(g1.Pmenu == true)
-- a row with a description: assert g_row.Comment == true
```

This is exactly analogous to S34 testing the PURE `compute_geometry` (synthetic inputs)
instead of a clamped `screenrow()`. Same philosophy: assert the mechanism, not the pixel.

> **`nvim_buf_get_extmarks` shape:** returns `{ { id, row(0-based), col, details }, ... }`
> (1-based outer array; `details` is the 4th element when `{details=true}`). The
> `end_col` for a whole-line `[0,-1)` highlight enumerates as `0` in details (the `-1`
> sentinel) → **assert `hl_group` + `row`, NOT `end_col`.**

## 6. Backward-compatibility analysis (why existing tests mostly still pass)

| Existing assertion (S34) | S35 behavior | Still passes? |
|---|---|---|
| `compute_width({label-only}, …)` cases in `menu_geometry_spec` | `any_desc=false` → returns `max_label_w` (S34-identical) | ✅ unchanged |
| `cfg.width == 6` for `{"/model","/mood"}` (no desc) in `menu_spec` case 19 | label-only → 6 | ✅ unchanged |
| `cfg.width == 9` for `/abcdefgh` (no desc) in `menu_spec` case 21 | label-only → 9 | ✅ unchanged |
| `lines[1]:match("^%s*(.-)%s*$") == "model"` (no desc) | label padded to label_w; strip → "model" | ✅ unchanged |
| full-flow window COUNT assertions (cases 18, smoke) | window still created/closed | ✅ unchanged |
| `reset()` nils win/menu_buf | unchanged | ✅ unchanged |

⇒ S35 is **additive**: it only changes OBSERVABLE behavior when items HAVE descriptions.
The new two-column + highlight cases are ADDED; the label-only cases stay green.

## 7. Anti-patterns & gotchas

- ❌ Don't implement navigation (`next`/`prev`/`dismiss`) or auto-close — S36/S37.
- ❌ Don't change `state.selected`'s meaning or the state layer — only READ it.
- ❌ Don't use `#s` / `string.sub` for width or truncation — CJK/double-width = 2 cells.
  Use `vim.fn.strdisplaywidth` / `strcharpart` / `strchars`.
- ❌ Don't assert `screenattr(...)` in tests (it's 0 headlessly) — assert via
  `nvim_buf_get_extmarks`.
- ❌ Don't add the selected-row `PmenuSel` highlight BEFORE the base/desc highlights —
  LAST-WINS means it must be added LAST to win (neovim#8449).
- ❌ Don't forget the 1-based→0-based conversion (`state.selected - 1`) — the #1 bug.
- ❌ Don't skip `nvim_buf_clear_namespace` at the start of `apply_highlights` — stale
  decorations from the previous render would linger on the reused scratch buffer.
- ❌ Don't let `apply_highlights`/`render_lines`/`_truncate` throw (per-keystroke +
  autocmd contract) — pcall every nvim call; type-guard every item/field.
- ❌ Don't pipe a heredoc into nvim stdin (it HANGS — AGENTS.md HARD RULE). Write test
  lua to a REAL file, then `+"luafile <path>" +qa`; wrap nvim in `timeout`.
- ❌ Don't add a new config option for `DESC_GAP` in v1 (PRD §10.5 doesn't list one) —
  keep it a module-local constant.