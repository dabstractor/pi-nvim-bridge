# PRP — P2.M8.T21.S35: Item rendering — two-column label/description + selected-row highlight

**Parent task:** P2.M8.T21 (menu.lua — popup creation, rendering & positioning)
**Module:** P2.M8 (Floating Completion Menu / `menu.lua`) — Neovim (Lua) side
**Plan path:** `plan/001_c56962b4fa17/P2M8T21S35/`
**Scope:** ONLY S35 (the CONTENT/RENDERING half). S34 (window creation + geometry) is
**COMPLETE**; S36 (navigation: next/prev/dismiss), S37 (auto-close autocmds) are
**SEPARATE, later tasks — do NOT implement them.**

---

## Goal

**Feature Goal:** Enhance the S34 floating popup's content from **label-only** lines to a
**two-column layout** (`label` left + a gap + `description` right, truncated with an
ellipsis) and **highlight the selected row** (`PmenuSel`) — plus base `Pmenu` and dimmed
`Comment` (description) decorations — so the menu visually matches the built-in popupmenu
convention while rendering pi's live `AutocompleteItem`s. Because the popup reuses a
single scratch buffer and re-renders on every `on_results`, the highlights must be applied
**inside `render()`'s show path** and honor the (1-based) `state.selected`.

**Deliverable:**
1. In `plugin/lua/pi-editor/menu.lua` (an EXISTING file — **edit, do not rewrite**):
   - Widen the LOCAL `render_lines` from `(state, width)` label-only to
     `(state, label_w, desc_w)` two-column (label right-padded + `DESC_GAP` + description
     truncated to `desc_w`, whole line padded to a clean rectangle).
   - Widen `compute_width` to budget `max_label_w + DESC_GAP + max_desc_w` when any item
     has a description (collapsing to label-only `max_label_w` when none do — so all
     existing label-only tests still pass).
   - Add a NEW LOCAL `apply_highlights(state, buf, label_w, desc_w)` that clears the
     namespace, paints a base whole-line `Pmenu` per row, a `Comment` range on each row's
     description, and a whole-line `PmenuSel` on the selected row LAST (last-wins).
   - Add a module-level `ns = nvim_create_namespace("pi-editor-menu")` (cached).
   - Add two PURE helpers — `column_metrics(items)` and `_truncate(text, max_w)` —
     exposed as `M._column_metrics` / `M._truncate` for unit testing (the codebase
     convention for pure helpers, mirroring `M._compute_*`).
   - Wire `apply_highlights(...)` into `render()`'s SHOW path immediately after the
     `nvim_buf_set_lines` pcall, computing `label_w`/`desc_w` from the final `g.width`.
2. Update `plugin/tests/menu_spec.lua` (plenary) — ADD two-column + highlight cases (items
   WITH descriptions): assert the buffer line content (label + gap + desc), and assert the
   HIGHLIGHT DECORATIONS via `nvim_buf_get_extmarks` (base `Pmenu` on all rows, `Comment`
   on description rows, `PmenuSel` on the selected row at `state.selected - 1`). Add the
   explicit 1-based↔0-indexed assertion (PmenuSel at row 0 when `selected == 1`).
3. Update `plugin/tests/menu_geometry_spec.lua` (plenary) — ADD `compute_width` two-column
   cases (label+gap+desc) + `column_metrics` + `_truncate` pure cases. The existing
   label-only `compute_width` cases MUST stay green unchanged.
4. Update `plugin/tests/menu_smoke.lua` (plenary-free) — give the server reply's item a
   `description` and assert the buffer line contains the description (two-column content
   rendered in the real-bridge flow).

**Success Definition:**
- `menu.open(items)` where items have descriptions renders a buffer whose lines are
  `<label><pad><gap><description-or-truncated>`; the selected row (row 0 when `selected=1`)
  carries a `PmenuSel` decoration (asserted via extmarks); description cells carry
  `Comment`; every row carries a base `Pmenu`.
- `menu.open(items)` where items have NO descriptions behaves **identically to S34**
  (label-only width/content; no description column) — every existing menu spec/smoke/geometry
  case stays green.
- `_truncate` truncates with `…` and is CJK-correct (`strdisplaywidth`/`strcharpart`, NOT `#s`).
- `menu.lua` introduces **zero new runtime dependencies** (only `vim.api` / `vim.fn`).
- The full test suite (`menu_spec`, `menu_geometry_spec`, `menu_smoke`, + sibling specs/smokes)
  runs green headlessly; the plugin stays dormant in non-pi nvim sessions.

---

## All Needed Context

### Context Completeness Check

> "If someone knew nothing about this codebase, would they have everything needed to implement this successfully?"

**Yes.** This PRP embeds: the exact file to edit (`menu.lua`), the exact functions to
enhance (`render_lines`, `compute_width`) + add (`apply_highlights`, `_truncate`,
`column_metrics`), the exact insertion point in `render()` (after the `set_lines` pcall),
the **live-verified** highlight mechanics (namespace/add_highlight/clear/last-wins/group
existence) + CJK truncation algorithm, the **1-based↔0-indexed** trap, the headless
testing strategy (assert extmarks, NOT `screenattr`), the backward-compat analysis, and
the exact validation commands. The implementing agent edits ONE existing file and adapts
three existing test files using copy-paste-ready reference implementations.

### Documentation & References

```yaml
# ── THIS PRP's research (READ FIRST — the consolidated evidence) ──
- file: plan/001_c56962b4fa17/P2M8T21S35/research/notes.md
  why: The consolidated S35 research: the S34 baseline (§1), the live-verified highlight
       mechanics + the 3-layer design (§2/§3), the 1-based↔0-indexed trap (§4), the headless
       testing gotcha (§5), the backward-compat analysis (§6). The code blocks in §3 are
       copy-paste-ready reference implementations.
  critical: §2 (LAST-WINS ordering + the added base-Pmenu layer), §3a–§3f (the exact code
       shape), §4 (the selected-1 off-by-one), §5 (assert extmarks not screenattr), §6
       (why label-only tests stay green).

# ── PRIOR live-verified research (the EVIDENCE BASE for §2) ──
- file: plan/001_c56962b4fa17/P2M5T1S2/research/highlight-layering.md
  why: The raw live-verified evidence (run against NVIM v0.12.4): namespace mechanics,
       add_highlight/clear_namespace/get_extmarks shapes, LAST-WINS (neovim#8449), the 3
       groups exist in --clean, the CJK two-column formatting + _truncate algorithm, the
       screenattr()=0 headless gotcha, the AutocompleteItem shape.
  gotcha: it was written against a DRAFT API (_items/_selected/_render_lines/M.set_selected);
       the shipped module uses state.items/state.selected(1-based)/render_lines/render/M.open —
       notes.md §1 maps the two. Trust the MECHANICS, map the NAMES.

# ── THE FILE YOU EDIT (read fully first) ──
- file: plugin/lua/pi-editor/menu.lua
  why: The S31 (state) + S34 (window) module S35 ENHANCES. S35 edits compute_width,
       render_lines, the render() SHOW path (insert apply_highlights), + adds ns/_truncate/
       column_metrics/apply_highlights. Do NOT touch the state layer or geometry helpers.
  pattern: the LOCAL `render_lines(state, width)` (search "S34 label-only lines"); the LOCAL
       `render(state)` SHOW path's `pcall(vim.api.nvim_buf_set_lines, buf, 0, -1, false,
       render_lines(state, g.width))` (THE insertion point); `compute_width`; `M._state = state`
       + `M._compute_*` (the test-seam convention S35 mirrors for M._truncate/_column_metrics).

# ── PRIOR PRP (the S34 baseline contract) ──
- file: plan/001_c56962b4fa17/P2M8T21S34/PRP.md
  why: Documents the window lifecycle + geometry S34 shipped (which S35 builds on) + the
       AGENTS.md HARD RULE + the codebase test conventions (pure helpers vs integration;
       plenary spec vs plenary-free smoke; the minimal_init.lua bootstrap).

# ── THE DRIVER (confirm render runs api-safe + per-keystroke) ──
- file: plugin/lua/pi-editor/completion.lua
  why: do_refresh fires M.on_results(buf, items, prefix) on the nvim MAIN LOOP (the bridge cb
       is schedule_wrap'd → api-safe) → menu.on_results → open()/close() → render → apply_highlights.
       Confirms render + apply_highlights run api-safe + per-keystroke (MUST NEVER throw).
  pattern: M.on_results = nil until menu.attach() wires it; S30 normalizes a null getSuggestions
       result to {items={}, prefix=""} BEFORE firing on_results (so apply_highlights never sees nil).

# ── CONFIG CONTRACT (read-only — S35 adds NO new option) ──
- file: plugin/lua/pi-editor/init.lua
  why: M.config.menu.{max_height,border} — read FRESH in render (S34). S35 adds NO config
       option (DESC_GAP is a module-local constant, not user-config — PRD §10.5 lists none).
  pattern: ((require("pi-editor").config or require("pi-editor").defaults) or {}).menu

# ── Neovim API docs (anchor-cited) ──
- url: https://neovim.io/doc/user/api.html#nvim_buf_add_highlight()
  why: nvim_buf_add_highlight(buffer, ns_id, hl_group, line, col_start, col_end) — line is
       0-BASED; col_end=-1 means end-of-line. Last-added highlight in a namespace wins
       (neovim#8449) → selected-row PmenuSel MUST be added after the base/desc highlights.
- url: https://neovim.io/doc/user/api.html#nvim_buf_clear_namespace()
  why: nvim_buf_clear_namespace(buffer, ns_id, line_start, line_end) with (0,-1) wipes every
       decoration in the namespace. Called at the START of apply_highlights (the reused scratch
       buffer would otherwise carry stale decorations).
- url: https://neovim.io/doc/user/api.html#nvim_create_namespace()
  why: nvim_create_namespace(name) returns a stable numeric id — cache ONCE at module scope.
- url: https://neovim.io/doc/user/api.html#nvim_buf_get_extmarks()
  why: nvim_buf_get_extmarks(buf, ns, {row,0}, {row,-1}, {details=true}) enumerates the
       decorations on a row (with hl_group) — the HEADLESS-SAFE assertion (screenattr()=0).
- url: https://neovim.io/doc/user/builtin.html#strdisplaywidth()
  why: vim.fn.strdisplaywidth(s) = display-column width (CJK/double-width = 2 cells). NOT #s.
       Used by column_metrics, compute_width, render_lines, _truncate.
- url: https://neovim.io/doc/user/builtin.html#strcharpart()
  why: vim.fn.strcharpart(text, start, len) = substring by CHAR (codepoint), not byte — the
       CJK-correct truncation primitive. NOT string.sub.
- url: https://neovim.io/doc/user/syntax.html#Pmenu
  why: Pmenu / PmenuSel / Comment are built-in highlight groups (exist in --clean, no setup
       needed) — the three S35 uses (base / selected / dimmed description).

# ── REFERENCE (the built-in popupmenu convention S35 mimics) ──
- url: https://neovim.io/doc/user/vim_diff.html#popup-menu
  why: The built-in |popup-menu| uses Pmenu (normal item) + PmenuSel (selected item). S35's
       3-layer (Pmenu base + Comment desc + PmenuSel selected) reproduces that look in a
       dependency-free float (PRD §7.5 "two columns — label (left) and description (right)").
```

### Current Codebase tree (the files S35 touches)

```bash
plugin/
  lua/pi-editor/
    menu.lua          # ← EDIT: widen compute_width + render_lines; add apply_highlights +
                      #              _truncate + column_metrics + ns; wire render() SHOW path
    completion.lua    # (read-only) the driver that fires on_results → open/close → render
    init.lua          # (read-only) M.config.menu.{max_height,border} (S35 adds NO option)
  tests/
    menu_spec.lua           # ← EDIT: ADD two-column content + highlight-decoration cases
    menu_geometry_spec.lua  # ← EDIT: ADD compute_width two-column + column_metrics + _truncate cases
    menu_smoke.lua          # ← EDIT: give the reply item a description; assert two-column content
    minimal_init.lua        # (read-only) plenary harness bootstrap (reuse as-is)
  plugin/pi-editor.lua       # (read-only) VimEnter shim
  ftplugin/pi-prompt.lua     # (read-only) buffer-local wiring
```

### Desired Codebase tree (the change footprint)

```bash
plugin/
  lua/pi-editor/menu.lua              # MODIFIED — two-column render_lines + apply_highlights + ns
                                      #             + _truncate + column_metrics; compute_width widened
  tests/menu_spec.lua                 # MODIFIED — ADD two-column content + highlight cases (existing stay)
  tests/menu_geometry_spec.lua        # MODIFIED — ADD compute_width two-column + column_metrics/_truncate
  tests/menu_smoke.lua                # MODIFIED — reply item has description; assert two-column content
# NO new files. NO init.lua change. NO new config option.
```

### Known Gotchas of our codebase & Neovim quirks

```lua
-- CRITICAL (neovim#8449, live-verified): within a namespace, the LAST-added highlight
-- WINS. nvim_buf_add_highlight has NO per-call priority param. ⇒ apply_highlights order:
--   (a) clear  →  (b) base Pmenu every row  →  (c) Comment on desc ranges  →  (d) PmenuSel
--   on the selected row LAST. Only the selected whole-line must be last to guarantee it wins.

-- CRITICAL (the #1 bug — 1-based↔0-indexed): state.selected is 1-BASED (1 after open(), 0
-- after close()); nvim_buf_add_highlight / nvim_buf_get_extmarks use 0-BASED rows.
-- ⇒ apply_highlights passes `state.selected - 1` as the line. Tests expect PmenuSel at row
--   `state.selected - 1` (row 0 when selected==1). Guard: only paint PmenuSel when
--   `state.selected >= 1 and state.selected <= #items`.

-- CRITICAL (live-verified): vim.fn.screenattr(row, col) returns 0 for EVERY cell in
-- --headless. Tests MUST assert the decorations via nvim_buf_get_extmarks (which group
-- landed on which row), NOT the rendered color. (Same class as S34's screenrow()=1 quirk.)

-- CRITICAL (live-verified): strdisplaywidth / strcharpart / strchars (vim.fn), NOT #s /
-- string.sub — CJK/double-width = 2 cells. "日本語" = 6 display cells, 3 chars, 9 bytes.
-- _truncate MUST walk by char (strcharpart) and measure by strdisplaywidth.

-- CRITICAL (live-verified): a whole-line highlight [0,-1) enumerates in get_extmarks with
-- end_col == 0 in details (the -1 sentinel). ⇒ assert hl_group + row, NOT end_col.

-- CRITICAL (AGENTS.md HARD RULE): NEVER pipe a heredoc / stdin into nvim — it HANGS the
-- session. Write every lua test snippet to a REAL file, then +"luafile <path>" +qa. Wrap
-- every nvim invocation in `timeout`.

-- CRITICAL: apply_highlights / render_lines / _truncate / column_metrics MUST NEVER throw
-- (render runs per-keystroke inside an autocmd chain). pcall every nvim call; type-guard
-- every item/field (label/description may be nil/non-string on a malformed item).

-- CRITICAL: CLEAR the namespace at the start of apply_highlights (nvim_buf_clear_namespace
-- buf,ns,0,-1). The scratch buffer is REUSED across opens (S34 blink pattern); without the
-- clear, stale Pmenu/Comment/PmenuSel from the previous render would linger.

-- CRITICAL: Pmenu / PmenuSel / Comment all EXIST in stock nvim --clean (live-verified via
-- nvim_get_hl). NO :highlight / colorscheme setup is required in tests or at runtime.

-- CRITICAL (backward-compat): when NO item has a description, compute_width returns
-- max_label_w (label-only) — IDENTICAL to S34. render_lines with desc_w==0 produces a
-- label-only padded line. ⇒ every existing label-only test stays green. Do NOT special-case
-- label-only differently; the desc_w==0 branch handles it.

-- The description column may be dropped when the screen is too narrow: if
-- (g.width - label_w - DESC_GAP) < 3, set desc_w=0 (render label-only) rather than show a
-- 1–2 cell sliver. compute_width still REQUESTS the two-column width; compute_geometry may
-- clamp it (case 5 over-wide) → render() recomputes the split from the FINAL g.width.
```

---

## Implementation Blueprint

### The module namespace + `DESC_GAP` constant (add at module scope, ABOVE the geometry helpers)

```lua
-- ===========================================================================
-- S35: highlight namespace (cached ONCE — live-verified nvim_create_namespace returns a
-- stable numeric id) + the inter-column gap constant (PRD §10.5 lists no config option for
-- it; module-local constant in v1). Used by apply_highlights + render_lines/compute_width.
-- ===========================================================================
local DESC_GAP = 2
local ns = nil
do
  local ok, id = pcall(vim.api.nvim_create_namespace, "pi-editor-menu")
  if ok and type(id) == "number" then ns = id end   -- nil on failure (apply_highlights degrades)
end
```

### PURE `column_metrics(items)` (NEW — shared by compute_width + render)

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

### PURE `_truncate(text, max_w)` (NEW — ellipsis truncation, CJK-correct)

```lua
--- Truncate `text` to <= max_w DISPLAY cells, appending "…" when truncated.
--- PURE. "" when max_w <= 0; the first char alone when only 1 cell of room. Exposed as M._truncate.
---@param text string
---@param max_w integer max display width
---@return string
local function _truncate(text, max_w)
  if type(text) ~= "string" or max_w <= 0 then return "" end
  if vim.fn.strdisplaywidth(text) <= max_w then return text end
  local ellipsis = "…"
  local budget = max_w - vim.fn.strdisplaywidth(ellipsis)
  if budget <= 0 then return vim.fn.strcharpart(text, 0, 1) end   -- 1 cell: first char, no ellipsis
  local out, w = "", 0
  local n = vim.fn.strchars(text)
  for i = 0, n - 1 do
    local ch = vim.fn.strcharpart(text, i, 1)
    local cw = vim.fn.strdisplaywidth(ch)
    if w + cw > budget then break end
    out, w = out .. ch, w + cw
  end
  return out .. ellipsis
end
```

### `compute_width` — ENHANCE (two-column total; collapses to label-only when no desc)

```lua
-- REPLACE the S34 compute_width body with this (signature UNCHANGED: (items, ui_cols, bh)):
local function compute_width(items, ui_cols, border_h_overhead)
  local m = column_metrics(items)
  local w = m.any_desc and (m.max_label_w + DESC_GAP + m.max_desc_w) or m.max_label_w
  return math.max(1, math.min(w, ui_cols - border_h_overhead))
end
```

> Existing `menu_geometry_spec` compute_width cases use label-only items → `any_desc=false`
> → returns `max_label_w` (S34-identical). They stay green. ADD new two-column cases.

### `render_lines(state, label_w, desc_w)` — ENHANCE (two-column; signature CHANGES)

```lua
-- REPLACE the S34 render_lines(state, width) with this (signature: (state, label_w, desc_w)).
-- LOCAL fn — only render() calls it, so the signature change is safe.
local function render_lines(state, label_w, desc_w)
  local total = label_w + (desc_w > 0 and DESC_GAP or 0) + desc_w
  local lines = {}
  for i = 1, #state.items do
    local it = state.items[i]
    local label = (type(it) == "table" and type(it.label) == "string") and it.label or ""
    local lw = vim.fn.strdisplaywidth(label)
    local row = label .. string.rep(" ", math.max(0, label_w - lw))   -- label column, right-padded
    if desc_w > 0 then
      row = row .. string.rep(" ", DESC_GAP)                          -- the gap
      local has_desc = type(it) == "table" and type(it.description) == "string" and it.description ~= ""
      if has_desc then
        local dt = _truncate(it.description, desc_w)
        local dw = vim.fn.strdisplaywidth(dt)
        row = row .. dt .. string.rep(" ", math.max(0, desc_w - dw))  -- desc, truncated + padded
      else
        row = row .. string.rep(" ", desc_w)                          -- no desc → blank desc col
      end
    end
    local rw = vim.fn.strdisplaywidth(row)
    lines[i] = row .. string.rep(" ", math.max(0, total - rw))        -- clean rectangle (CJK-safe)
  end
  return lines
end
```

### `apply_highlights(state, buf, label_w, desc_w)` — NEW local fn

```lua
--- S35: apply the 3-layer highlight decoration to the popup's scratch buffer. Called from
--- render()'s SHOW path AFTER nvim_buf_set_lines. NEVER throws (pcall every nvim call;
--- type-guards; is_valid guards). Order is load-bearing (LAST-WINS, neovim#8449):
---   (a) clear  (b) base Pmenu every row  (c) Comment on desc ranges  (d) PmenuSel selected LAST.
---@param state pi-editor.MenuState reads state.items + state.selected (1-based).
---@param buf integer the scratch buffer (state.menu_buf).
---@param label_w integer the label column width.
---@param desc_w integer the description column width (0 ⇒ no desc column).
local function apply_highlights(state, buf, label_w, desc_w)
  if type(buf) ~= "number" or not vim.api.nvim_buf_is_valid(buf) then return end
  if type(ns) ~= "number" then return end                              -- namespace create failed → degrade
  pcall(vim.api.nvim_buf_clear_namespace, buf, ns, 0, -1)              -- (a) clear (reused scratch buf)
  local n = #state.items
  if n == 0 then return end
  local desc_start = label_w + DESC_GAP
  for i = 1, n do                                                      -- (b) base Pmenu whole-line (every row)
    pcall(vim.api.nvim_buf_add_highlight, buf, ns, "Pmenu", i - 1, 0, -1)
  end
  if desc_w > 0 then                                                   -- (c) Comment on desc ranges (rows w/ desc)
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
  if type(state.selected) == "number" and state.selected >= 1 and state.selected <= n then
    pcall(vim.api.nvim_buf_add_highlight, buf, ns, "PmenuSel", state.selected - 1, 0, -1)  -- (d) selected LAST
  end
end
```

### The `render()` SHOW-path wiring (THE S35 insertion — 4 lines)

Inside `render()`, REPLACE the S34 line
`pcall(vim.api.nvim_buf_set_lines, buf, 0, -1, false, render_lines(state, g.width))`
with the column-split + set_lines + apply_highlights block:

```lua
  local g = compute_geometry(sr, sc, ui_lines, ui_cols, width, height, max_height, border)
  -- S35: split the FINAL g.width (compute_geometry may have clamped it) into label + desc columns
  local m = column_metrics(state.items)
  local label_w = m.max_label_w
  local desc_w  = m.any_desc and math.max(0, g.width - label_w - DESC_GAP) or 0
  if m.any_desc and desc_w < 3 then desc_w = 0 end                      -- too thin → label-only (no sliver)
  pcall(vim.api.nvim_buf_set_lines, buf, 0, -1, false, render_lines(state, label_w, desc_w))
  apply_highlights(state, buf, label_w, desc_w)                         -- ← THE S35 INSERTION
  local win_cfg = {                                                     -- (unchanged from S34)
    relative = "cursor", anchor = g.anchor, row = g.row, col = g.col,
    width = g.width, height = g.height, style = "minimal", border = border,
    focusable = false, noautocmd = true, zindex = 100,
  }
  -- ... (rest of render's open-vs-set_config + wrap=false UNCHANGED)
```

> **HIDE path (unchanged):** `render()`'s close path stays exactly as S34 left it
> (`nvim_win_close` + `state.win = nil`). No highlight clearing needed there —
> `apply_highlights` clears at the start of every SHOW, and the buffer is never shown
> without a fresh `apply_highlights`. (`reset()` already nils `menu_buf`, so teardown is
> clean.)

### Expose the new pure test seams (before `return M`, next to the S34 `M._compute_*`)

```lua
-- S35 internal test seams (the pure helpers — mirror coords_spec's byte_to_utf16 convention).
M._column_metrics = column_metrics
M._truncate = _truncate
-- (M._compute_width / _compute_height / _compute_geometry / M._state already exposed by S34.)
```

### Implementation Tasks (ordered by dependencies)

```yaml
Task 1: READ menu.lua + the S35 research + the live-verified evidence
  - READ FULLY: plugin/lua/pi-editor/menu.lua (the S31+S34 module — understand state, render_lines,
    compute_width, render's SHOW path, M._compute_*/M._state seams).
  - READ: plan/001_c56962b4fa17/P2M8T21S35/research/notes.md (§1 S34 baseline, §2 mechanics,
    §3 the code shape, §4 off-by-one, §5 headless gotcha, §6 backward-compat).
  - READ: plan/001_c56962b4fa17/P2M5T1S2/research/highlight-layering.md (the raw evidence).
  - NOTE: render_lines is a LOCAL fn (only render() calls it) → its signature may change.
    apply_highlights is NEW + LOCAL. compute_width's SIGNATURE stays (items, ui_cols, bh).

Task 2: ADD the module namespace + DESC_GAP + column_metrics + _truncate (module scope)
  - ADD (above the geometry helpers): `local DESC_GAP = 2`; the `ns = pcall(create_namespace …)`
    do-block; `column_metrics(items)`; `_truncate(text, max_w)` — copy-paste the reference impls.
  - VERIFY pure-ness (no nvim state writes; type-guarded). EXPOSE M._column_metrics / M._truncate.

Task 3: ENHANCE compute_width (use column_metrics; two-column total; label-only fallback)
  - REPLACE the S34 compute_width body with the column_metrics-based version (signature UNCHANGED).
  - KEEP the math.max(1, math.min(...)) clamp + the ui_cols-border_h_overhead contract (S34).

Task 4: ENHANCE render_lines (two-column; signature (state, label_w, desc_w))
  - REPLACE render_lines(state, width) with render_lines(state, label_w, desc_w) — copy-paste
    the reference impl (label padded + DESC_GAP + _truncate(desc, desc_w) padded; total = clean rect).
  - VERIFY the desc_w==0 branch produces label-only padded lines (backward-compat with S34 tests).

Task 5: ADD apply_highlights(state, buf, label_w, desc_w) (the 3-layer decoration, LOCAL fn)
  - IMPLEMENT exactly the reference impl (clear → base Pmenu → Comment desc → PmenuSel selected LAST).
  - GUARD the selected index (1-based→0-based; only when 1<=selected<=#items). NEVER throws.

Task 6: WIRE render()'s SHOW path (the 4-line insertion)
  - REPLACE the single `pcall(nvim_buf_set_lines, buf, 0, -1, false, render_lines(state, g.width))`
    with: column_metrics split → label_w/desc_w → render_lines(state,label_w,desc_w) →
    apply_highlights(state, buf, label_w, desc_w). Keep win_cfg + the rest of render UNCHANGED.
  - ADD the `desc_w < 3 → desc_w = 0` floor. Do NOT touch the HIDE path.

Task 7: SMOKE-VERIFY rendering in isolation (before touching specs)
  - WRITE /tmp/menu_s35_check.lua (a REAL FILE — AGENTS.md HARD RULE: never heredoc→nvim stdin):
    set rtp+=plugin; require("pi-editor").setup({}); require("pi-editor.menu"); open a 3-item list
    WITH descriptions; assert the buffer line contains label+gap+desc; assert via
    nvim_buf_get_extmarks that row 0 (selected=1) has PmenuSel + a description row has Comment;
    close; assert decorations cleared on reopen. Run:
    timeout 60 nvim --headless --clean -u NORC +"luafile /tmp/menu_s35_check.lua" +qa ; echo "exit=$?"

Task 8: UPDATE plugin/tests/menu_geometry_spec.lua — ADD pure two-column cases
  - ADD describe("_truncate") cases: fits-as-is; ASCII truncation with "…" ("verylong"→5="ver…");
    CJK truncation ("日本語です"→5); max_w<=0 → ""; 1-cell room → first char. CJK via strdisplaywidth.
  - ADD describe("column_metrics") cases: label-only (any_desc=false, max_desc_w=0); mixed
    (max_label_w + max_desc_w correct); non-string fields guarded; CJK label/desc widths.
  - ADD compute_width two-column cases: items WITH descriptions ⇒ max_label_w+DESC_GAP+max_desc_w
    (clamped); label-only items still ⇒ max_label_w (the existing cases — re-confirm green).
  - KEEP all existing compute_height/compute_width(label-only)/compute_geometry cases UNCHANGED.

Task 9: UPDATE plugin/tests/menu_spec.lua — ADD two-column content + highlight cases
  - ADD: open(items-with-descriptions) → buffer lines contain `<label>  <desc>` (two spaces = GAP);
    cfg.width == max_label_w + 2 + max_desc_w (two-column). CJK item description renders/truncates.
  - ADD: highlight decorations via nvim_buf_get_extmarks: row 0 (selected=1) has hl_group "PmenuSel";
    every row has "Pmenu"; a row with a description has "Comment" on its desc range. Use a local
    hl_groups_on_row(buf, ns, row0) helper that collects mk[4].hl_group from get_extmarks.
  - ADD: the 1-based↔0-indexed assertion explicitly — open() sets selected=1 → PmenuSel at row 0
    (NOT row 1). After a 2-item open, row 1 must NOT have PmenuSel (only row 0).
  - ADD: label-only open(items-no-desc) still renders label-only lines + base Pmenu + PmenuSel on
    row 0, and NO Comment anywhere (backward-compat regression guard).
  - KEEP cases 1–25 UNCHANGED (they use label-only items; render_lines desc_w==0 branch → label-only
    lines; the `:match("^%s*(.-)%s*$")` strip still matches; cfg.width assertions still hold).

Task 10: UPDATE plugin/tests/menu_smoke.lua — two-column content in the real-bridge flow
  - CHANGE the CASE-1 server reply item to { value="/model", label="model",
    description="Switch the model" } and ASSERT the rendered buffer line contains "Switch" (the
    description rendered two-column). Keep the existing is_open/get_items/get_selected/window-count
    assertions. (CASE 2 empty-reply + CASE 3 reset unchanged.)
  - KEEP the smoke plenary-free (AGENTS.md: +"luafile …" +qa, NOT stdin).

Task 11: RUN the full validation suite (see Validation Loop) + fix until green
  - RUN: menu_geometry_spec.lua, menu_spec.lua, menu_smoke.lua (the changed files), THEN every
    sibling spec/smoke (completion_*, bridge_*, coords_*, init_*, ftplugin_*, shim_*, activate_*,
    jsonlreader_*, smoke). All must be green (exit 0) — S35 must break NOTHING.
```

### Implementation Patterns & Key Details

```lua
-- PATTERN: the LAST-WINS highlight order (load-bearing). Always: clear → base → desc → selected.
--   Never add PmenuSel before the base/desc, or it will be overridden (neovim#8449).
-- PATTERN: assert decorations via extmarks in tests (screenattr()=0 headlessly):
local function hl_groups_on_row(buf, ns, row0)
  local marks = vim.api.nvim_buf_get_extmarks(buf, ns, { row0, 0 }, { row0, -1 }, { details = true })
  local groups = {}
  for _, mk in ipairs(marks) do
    if mk[4] and mk[4].hl_group then groups[mk[4].hl_group] = true end
  end
  return groups
end
-- PATTERN: read config FRESH in render (the codebase-wide rule) — S34 already does this; S35
--   reuses `m = column_metrics(state.items)` for the column split (NO config read added).
-- PATTERN: pure helpers exposed as M._* for unit testing (mirrors M._compute_* / coords' fns).
-- GOTCHA: state.selected is 1-based; nvim rows are 0-based → `state.selected - 1` as the line.
-- GOTCHA: strdisplaywidth/strcharpart/strchars (NOT #s/string.sub) for CJK/double-width.
-- GOTCHA: a whole-line [0,-1) highlight enumerates with end_col==0 in details — assert hl_group+row.
-- GOTCHA: the namespace MUST be cleared at the start of apply_highlights (reused scratch buffer).
-- GOTCHA (AGENTS.md): heredoc→file is fine; heredoc→nvim stdin HANGS. Wrap nvim in `timeout`.
```

### Integration Points

```yaml
CONFIG (read-only, NO change):
  - source: plugin/lua/pi-editor/init.lua M.defaults.menu { max_height=12, border="rounded" }
  - S35 adds NO config option (DESC_GAP is a module-local constant; PRD §10.5 lists none).

STATE (S31, read-only contract):
  - state.items / state.selected (1-based) / state.open: S35 READS them in render+apply_highlights.
  - state.win / state.menu_buf: S34 owns; S35 writes highlights INTO state.menu_buf (read-only on win).

SEAM (NO wiring change):
  - S31's open(items)/close() ALREADY call render(state). S34 already made render create/show the
    window. S35 inserts apply_highlights AFTER the set_lines inside that same render. NO change to
    init.lua, completion.lua, or the ftplugin. S35 is CONTAINED to menu.lua + its tests.

NAMESPACE (NEW module-scope resource):
  - ns = nvim_create_namespace("pi-editor-menu") — cached ONCE at module load. apply_highlights is
    the ONLY writer. Tests READ via nvim_buf_get_extmarks(buf, ns, …). Never logged/echoed.

TESTING HARNESS (reuse, no change):
  - Plenary spec: plugin/tests/minimal_init.lua (sets rtp to plugin/ + plenary).
  - Smoke: plenary-free, self-bootstraps rtp (the menu_smoke pattern).
```

---

## Validation Loop

> **CRITICAL (AGENTS.md HARD RULE):** write every lua snippet to a REAL FILE then run
> `+"luafile <path>" +qa`. NEVER pipe a heredoc into nvim stdin (it HANGS). ALWAYS wrap nvim
> in `timeout`. Run from the `plugin/` directory.

### Level 1: Syntax & Style (after editing menu.lua)

```bash
cd /home/dustin/projects/pi-nvim-bridge/plugin
# load/syntax check via a FILE (NOT stdin):
cat > /tmp/menu_loadcheck.lua <<'LUA'
local ok, err = loadfile("lua/pi-editor/menu.lua")
assert(ok, "menu.lua syntax error: " .. tostring(err))
print("MENU_LOAD_OK")
LUA
timeout 30 nvim --headless --clean -u NORC +"luafile /tmp/menu_loadcheck.lua" +qa ; echo "exit=$?"
# Expected: MENU_LOAD_OK, exit 0. (If selene/stylua config exists, also run them per repo convention.)
```

### Level 2: Unit Tests (plenary) — pure helpers + two-column content + highlight decorations

```bash
cd /home/dustin/projects/pi-nvim-bridge/plugin
# The pure helpers (_truncate, column_metrics) + compute_width two-column + the geometry table:
timeout 90 nvim --headless --clean -u tests/minimal_init.lua \
  -c 'lua require("plenary.busted").run("tests/menu_geometry_spec.lua")' ; echo "exit=$?"
# The two-column content + highlight decorations + the unchanged state cases:
timeout 90 nvim --headless --clean -u tests/minimal_init.lua \
  -c 'lua require("plenary.busted").run("tests/menu_spec.lua")' ; echo "exit=$?"
# Expected: both exit 0, all cases pass. Read the output + fix before proceeding.
```

### Level 3: Smoke (plenary-free, real bridge + real completion + real menu)

```bash
cd /home/dustin/projects/pi-nvim-bridge/plugin
timeout 60 nvim --headless --clean -u NORC +"luafile tests/menu_smoke.lua" +qa ; echo "exit=$?"
# Expected: SMOKE_PASS, exit 0. Asserts the two-column line (label + description) is rendered in
# the real-bridge flow, in addition to the existing menu-STATE + window assertions.
```

### Level 4: Regression — S35 must break NOTHING in sibling modules

```bash
cd /home/dustin/projects/pi-nvim-bridge/plugin
for spec in completion_spec completion_accept_smoke completion_tab_smoke completion_smoke \
            bridge_spec bridge_smoke bridge_handshake_spec bridge_request_spec bridge_notify_spec \
            coords_spec coords_smoke init_spec activate_spec activate_smoke ftplugin_spec \
            ftplugin_smoke shim_spec shim_smoke jsonlreader_spec jsonlreader_smoke smoke; do
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

### Level 4b: The rendering-isolation check (the "did apply_highlights actually run?" proof)

```bash
# A REAL file (AGENTS.md: heredoc→file is fine; heredoc→nvim stdin is NOT). Proves two-column
# content + the 3-layer highlights render, with NO bridge.
cat > /tmp/menu_s35_e2e.lua <<'LUA'
vim.opt.runtimepath:append("/home/dustin/projects/pi-nvim-bridge/plugin")
local pi = require("pi-editor"); if pi.config == nil then pi.setup({}) end
local menu = require("pi-editor.menu")
-- a real window so screenrow()/screencol() have a context (the popup is relative to cursor)
local buf0 = vim.api.nvim_create_buf(true, false)
local win0 = vim.api.nvim_open_win(buf0, true, {relative="editor",row=1,col=1,width=60,height=6,border="none"})
vim.api.nvim_buf_set_lines(buf0,0,-1,false,{"/mo"})
vim.wo[win0].virtualedit="onemore"; vim.api.nvim_win_set_cursor(win0,{1,3})

local items = {
  { value="/model", label="/model", description="Switch the active model" },
  { value="/mood",  label="/mood",  description="Set the mood" },
}
menu.open(items)
vim.wait(50, function() end)
assert(menu.is_open(), "menu open")
local mbuf = menu._state.menu_buf
assert(vim.api.nvim_buf_is_valid(mbuf), "scratch buf valid")
local lines = vim.api.nvim_buf_get_lines(mbuf, 0, -1, false)
assert(#lines == 2, "two items ⇒ two lines")
-- two-column: line 1 contains the label AND the description text
assert(lines[1]:find("/model", 1, true), "row1 has label")
assert(lines[1]:find("Switch", 1, true), "row1 has description (two-column)")
-- the namespace id (read the same way the spec will)
local ns = vim.api.nvim_create_namespace("pi-editor-menu")
local function groups(row0)
  local out = {}
  for _, mk in ipairs(vim.api.nvim_buf_get_extmarks(mbuf, ns, {row0,0}, {row0,-1}, {details=true})) do
    if mk[4] and mk[4].hl_group then out[mk[4].hl_group] = true end
  end
  return out
end
local g0 = groups(0)   -- selected row (selected=1 ⇒ row 0)
assert(g0.Pmenu == true, "base Pmenu on row 0")
assert(g0.PmenuSel == true, "PmenuSel on the selected row 0 (selected=1)")
assert(g0.Comment == true, "Comment on row 0's description range")
local g1 = groups(1)   -- non-selected row
assert(g1.Pmenu == true, "base Pmenu on row 1")
assert(g1.PmenuSel == nil, "row 1 is NOT selected")
assert(g1.Comment == true, "Comment on row 1's description")
-- label-only regression: reopen without descriptions ⇒ no Comment anywhere
menu.open({ {value="/x", label="/x"} })
vim.wait(30, function() end)
local lines2 = vim.api.nvim_buf_get_lines(menu._state.menu_buf, 0, -1, false)
assert(lines2[1]:match("^%s*(.-)%s*$") == "/x", "label-only reopen ⇒ label-only line")
local gx = groups(0)
assert(gx.Pmenu == true and gx.PmenuSel == true, "label-only still has base+selected")
assert(gx.Comment == nil, "label-only ⇒ no Comment")
print("MENU_S35_E2E_PASS")
vim.api.nvim_win_close(win0, true); vim.api.nvim_buf_delete(buf0, {force=true})
LUA
timeout 60 nvim --headless --clean -u NORC +"luafile /tmp/menu_s35_e2e.lua" +qa ; echo "exit=$?"
# Expected: MENU_S35_E2E_PASS, exit 0.
```

---

## Final Validation Checklist

### Technical Validation
- [ ] Level 1 load/syntax check passes (exit 0).
- [ ] `tests/menu_geometry_spec.lua` passes: existing geometry + label-only compute_width cases
      UNCHANGED + new `_truncate`/`column_metrics`/two-column `compute_width` cases green.
- [ ] `tests/menu_spec.lua` passes: cases 1–25 UNCHANGED + new two-column-content +
      highlight-decoration + 1-based↔0-indexed + label-only-regression cases green.
- [ ] `tests/menu_smoke.lua` passes (SMOKE_PASS; two-column line rendered in the real-bridge flow).
- [ ] `/tmp/menu_s35_e2e.lua` prints MENU_S35_E2E_PASS (two-column + 3-layer highlights + label-only reopen).
- [ ] Regression: every sibling spec/smoke green (no SPEC FAIL / SMOKE FAIL).

### Feature Validation
- [ ] `menu.open(items)` with descriptions renders `<label><pad><gap><description-or-truncated>` lines.
- [ ] The selected row (row `state.selected - 1`) carries `PmenuSel` (asserted via extmarks).
- [ ] Every row carries a base `Pmenu`; description rows carry `Comment` on the desc range.
- [ ] The description is truncated with `…` when it exceeds `desc_w` (CJK-correct).
- [ ] `menu.open(items)` WITHOUT descriptions behaves identically to S34 (label-only; no Comment).
- [ ] The description column is dropped (`desc_w=0`) when the screen is too narrow (`< 3` cells).
- [ ] `apply_highlights` clears the namespace first (no stale decorations on the reused buffer).
- [ ] Never throws (pcall-wrapped nvim; is_valid/type guards); a highlight failure degrades silently.

### Code Quality Validation
- [ ] `render_lines`/`apply_highlights` are LOCAL fns (S31/S34 contract); `compute_width`'s signature
      is UNCHANGED; the state layer + geometry helpers are UNTOUCHED.
- [ ] No new runtime dependencies (only `vim.api`/`vim.fn`); one new module-scope resource (`ns`).
- [ ] Pure helpers (`column_metrics`, `_truncate`) exposed as `M._column_metrics`/`M._truncate`
      (the `M._compute_*` / coords convention); tested with synthetic inputs.
- [ ] Config read FRESH via `require("pi-editor")` (S34 already does this; S35 adds no config read).
- [ ] Follows the codebase's Mode-A header + research-citation conventions (update menu.lua's header
      to note S35 implemented two-column + highlights; cite research/notes.md §2/§3).
- [ ] Test snippets are real files (AGENTS.md: never heredoc→nvim stdin); nvim wrapped in `timeout`.

### Documentation & Scope Discipline
- [ ] Did NOT implement S36 (navigation: next/prev/dismiss) or S37 (auto-close autocmds).
- [ ] Did NOT change the state layer (`open`/`close`/`reset`/`on_results`/`get_*`) or geometry helpers.
- [ ] Did NOT modify `init.lua`, `completion.lua`, the bridge, or the ftplugin (S35 is contained).
- [ ] Did NOT add a new config option (DESC_GAP is a module-local constant; PRD §10.5 lists none).
- [ ] Did NOT touch PRD.md, tasks.json, prd_snapshot.md, or any plan/* PRP other than this one.

---

## Anti-Patterns to Avoid

- ❌ Don't implement navigation (`next`/`prev`/`dismiss`) or auto-close autocmds — S36/S37.
- ❌ Don't change `compute_width`'s SIGNATURE — only its body (existing geometry tests call
  `compute_width(items, 80, 2)`); keep it.
- ❌ Don't change the state layer or the geometry helpers (`compute_geometry`/`compute_height`) —
  S31/S34 own them; S35 only READS `state.items`/`state.selected`.
- ❌ Don't add the `PmenuSel` highlight BEFORE the base `Pmenu` / desc `Comment` — LAST-WINS
  (neovim#8449) means it must be added LAST to win on the selected row.
- ❌ Don't forget the 1-based→0-based conversion (`state.selected - 1`) — the #1 bug.
- ❌ Don't skip `nvim_buf_clear_namespace` at the start of `apply_highlights` (stale decorations).
- ❌ Don't use `#s` / `string.sub` for width/truncation — CJK/double-width = 2 cells. Use
  `vim.fn.strdisplaywidth` / `strcharpart` / `strchars`.
- ❌ Don't assert `screenattr(...)` in tests (it's 0 headlessly) — assert via `nvim_buf_get_extmarks`.
- ❌ Don't assert `end_col` from a whole-line `[0,-1)` highlight (it enumerates as 0) — assert
  `hl_group` + `row`.
- ❌ Don't let `apply_highlights`/`render_lines`/`_truncate`/`column_metrics` throw (per-keystroke +
  autocmd contract) — pcall every nvim call; type-guard every item/field.
- ❌ Don't add a config option for `DESC_GAP` in v1 — keep it a module-local constant.
- ❌ Don't pipe a heredoc into nvim stdin (it HANGS — AGENTS.md HARD RULE). Write test lua to a real
  file, then `+"luafile <path>" +qa`; wrap nvim in `timeout`.

---

## Confidence Score: 9/10

**Why high:** Every mechanism S35 uses is **live-verified** against `NVIM v0.12.4`
(namespace, `add_highlight`/`clear_namespace`/`get_extmarks`, LAST-WINS ordering, the 3
groups exist in `--clean`, the CJK two-column formatting + `_truncate` algorithm, the
`screenattr()=0` headless gotcha). The seam is a single insertion point in `render()`'s
already-working SHOW path (S34 is COMPLETE and tested); S35 is purely additive to a
known-good window layer. The backward-compat analysis (notes.md §6) shows every existing
label-only test stays green because `compute_width`/`render_lines` collapse to S34 behavior
when no item has a description. The 1-based↔0-indexed trap is called out as GOTCHA #1 in
both the research and the anti-patterns.

**Residual risk (the 1 point):** the exact `desc_w < 3` floor (when to drop the description
column on a narrow screen) is a judgment call — 3 cells is a sane default but a reviewer
might prefer 4 or a configurable threshold; the value is isolated to one line in `render()`
and trivially tunable. Also, the precise extmark-assertion helper shape (`mk[4].hl_group`
vs `mk.details.hl_group`) depends on the Neovim version's `get_extmarks` return shape; the
Level-4b e2e check pins the exact shape headlessly before the spec relies on it.