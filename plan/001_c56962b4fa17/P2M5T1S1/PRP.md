---
name: "P2.M8.T21.S34 (PRP path P2M5T1S1) — menu.lua floating window: cursor-relative positioning & edge clamping"
description: |
  **Create `plugin/lua/pi-editor/menu.lua`** for `pi-editor.nvim`: a dependency-free
  floating completion popup opened with `vim.api.nvim_open_win(buf, false, config)`
  (`relative="cursor"`, `style="minimal"`, `border`, `focusable=false`, then `wrap=false`).
  This task (logical id **S34 / P2.M8.T21.S34**; PRP output dir `P2M5T1S1`) owns the
  **window lifecycle + geometry only**: scratch-buffer create/reuse, width/height
  computation (content-driven, screen-clamped), and **edge clamping** (show above the
  caret when near the bottom; shift left when near the right edge; clamp height when
  neither side fits). The clamping math lives in a PURE, fully unit-tested function
  `compute_geometry(screen_row, screen_col, ui_lines, ui_cols, width, height, border)`.
  `M.open(items)` / `M.close()` / `M.is_open()` manage the popup; selection INDEX is
  tracked (`get_selected`/`set_selected`/`move`/`get_item`). [Mode A] LuaCATS docstrings
  explain the positioning model. Zero external Lua deps; Neovim 0.10+ (verified 0.12.4).
  NARROW scope guard — this task does NOT implement: two-column rendering + selected-row
  highlight (**S35**), navigation key handling (**S36**), or auto-close autocmds (**S37**).
  It reads its menu config from S19's already-shipped `require("pi-editor").config`.
  STATUS (planning): every validation command was LIVE-VERIFIED green against a
  prototype (research/live-verification.md §7: `MENU_VERIFY_PASS 0`).
---

## Goal

**Feature Goal**: Create `lua/pi-editor/menu.lua` — a zero-plugin floating completion
popup that opens at the caret via `nvim_open_win` and is **clamped to the screen edges**
(below the caret by default; above when near the bottom; shifted left when near the
right edge; height clamped when neither side fits). The clamping is a pure, deterministic
function; `M.open(items)` wires live `vim.fn.screenrow()/screencol()` + `vim.o.lines/
columns` into it. Width is content-driven (`max(label+gap+description)`) and screen-clamped;
height is `min(#items, menu.max_height)`. A reused scratch buffer backs the window and
`wrap` is forced off.

**Deliverable** (3 files — all NEW):
- `plugin/lua/pi-editor/menu.lua` — the module: `M.open`/`M.close`/`M.is_open`,
  `M.get_selected`/`M.set_selected`/`M.move`/`M.get_item`, the pure
  `M.compute_width`/`M.compute_height`/`M.compute_geometry`, internal scratch-buffer
  management, and [Mode A] LuaCATS docstrings. `return M`.
- `plugin/tests/menu_spec.lua` — plenary/busted spec (the Level-2 gate): pure-function
  clamping cases + lifecycle + selection. Reuses S19's `tests/minimal_init.lua` harness.
- `plugin/tests/smoke_menu.lua` — plenary-FREE standalone smoke test (the Level-1 gate;
  `:luafile`-sourced, `cquit(1)` on failure — same pattern as S19's `smoke.lua`).

**Success Definition** (all assertions below are LIVE-VERIFIED via the prototype — see
`research/live-verification.md` §7):
- `require("pi-editor.menu")` loads with no error (rtp = `plugin/`).
- `M.open(items)` for 3 `AutocompleteItem`s returns a valid window id; `M.is_open()` is
  true; `nvim_win_get_config(win).width == 25` (max of `/model …`=24 and `/compact …`=25)
  and `.height == 3`; `vim.wo[win].wrap == false`; `M.get_selected() == 1`.
- `M.open(new_items)` while open **reuses the same window id** and resizes it
  (`nvim_win_set_config`, no flicker).
- `M.close()` closes it; `M.is_open()` false; `M.open({})` (empty) is a no-op that also
  closes any open menu and returns nil.
- Reopening after close reuses the scratch buffer.
- `compute_geometry` returns the **exact** 7-case geometry table in
  `research/positioning-math.md` (below/above/shift-left/width-clamp/height-clamp/border-none).
- `compute_width` is double-width-aware (`日本語` ⇒ 6) and screen-clamped.
- Headless smoke test prints `MENU_SMOKE_PASS` / exit 0; plenary spec exits 0.

## User Persona (if applicable)

**Target User**: The plugin author and the downstream implementers of **S35** (rendering),
**S36** (key handling), **S37** (auto-close), **S32** (accept flow — calls `M.get_item()`),
and **S42** (health.lua). End users never call this module directly.

**Use Case**: `completion.lua` (S31) receives `AutocompleteItem[]` from the bridge and
calls `require("pi-editor.menu").open(items)`; the popup appears at the caret, clamped
on-screen. This task is the window/geometry half; S35 will fill in the two-column paint.

**Pain Points Addressed**: A floating menu that overflows the bottom/right of the screen
is unusable at window edges (exactly where prompt editing happens — bottom of a long
prompt). Correct clamping is the difference between a usable and a broken menu.

## Why

- **Primary UX surface (PRD §7.5).** This menu is the completion UI that must work with a
  stock Neovim and **no plugin manager**. It is the first thing a user sees.
- **Edge clamping is the hard part.** `relative="cursor"` alone overflows the screen near
  the bottom/right edges. The clamping math (above vs below; shift-left vs width-clamp;
  height-clamp when neither side fits) is what makes the menu usable everywhere.
- **Foundation for S35/S36/S37.** Those tasks need a stable module API: S35 enhances the
  rendering, S36 calls `M.move(±1)`/`M.get_item()`/`M.close()`, S37 calls `M.close()` on
  its autocmds. Locking the lifecycle + selection API here lets them layer on cleanly.
- **Integrates with the (complete) P1 extension + S19 config.** The bridge ships
  `AutocompleteItem { value, label, description? }` (PRD §5.4); S19 ships the
  `menu = { max_height, border }` config this module reads.

## What

User-visible behavior: a borderless-or-bordered floating window appears at the caret
showing one line per item, never spilling off-screen. (Polished two-column rendering and
the selected-row highlight arrive in S35; this task renders a basic `label + description`
per line so the window is correctly sized and visible.)

Technical requirements (from the work-item contract + PRD §7.5):
- Window: `nvim_open_win(buf, false, { relative="cursor", row, col, anchor, width, height,
  style="minimal", border=<config.menu.border>, focusable=false })` then `wrap=false`.
- Scratch buffer: `nvim_create_buf(false, true)` (listed=false, scratch=true), **reused**
  across opens.
- Width: `max(label + gap + description)` via `strdisplaywidth`, clamped to screen width
  minus border; gap = 2.
- Height: `min(#items, menu.max_height)`.
- Position/clamp via `vim.fn.screenrow()`, `vim.fn.screencol()`, `vim.o.lines`,
  `vim.o.columns` — show above when near bottom, shift left when near right edge.
- `M.open` updates in place (no flicker) if already open.

### Success Criteria

- [ ] `require("pi-editor.menu")` loads with rtp=`plugin/`; no error.
- [ ] `M.open(items)` opens a valid cursor-relative float; `M.is_open()` true.
- [ ] Window `width` == `compute_width(items, …)`; `height` == `min(#items, max_height)`.
- [ ] `wrap == false` on the popup window.
- [ ] Re-`open` while open reuses the **same** window id (resizes via `nvim_win_set_config`).
- [ ] `M.close()` closes the window (idempotent); `M.open({})`/`M.open(nil)` closes + returns nil.
- [ ] Reopen after close reuses the scratch buffer (no new buffer per open).
- [ ] `compute_geometry`: top-left⇒below(NW,1); bottom⇒above(SW,0); right-edge⇒col negative;
      over-wide⇒width clamped; neither-side-fits⇒height clamped; `"none"` border⇒no overhead.
- [ ] `compute_width` double-width-aware (CJK) and screen-clamped; empty⇒1.
- [ ] `set_selected`/`move` clamp to `[1,#items]`; `get_item()`/`get_item(i)` return items.
- [ ] Headless smoke test prints `MENU_SMOKE_PASS`, exit 0; plenary spec exits 0.
- [ ] [Mode A] LuaCATS annotations on all public functions + the `AutocompleteItem` class.

## All Needed Context

### Context Completeness Check

_Passes "No Prior Knowledge":_ an implementer who has never seen this repo needs only
this PRP + `research/{live-verification,positioning-math}.md` + the exact commands below.
Every Neovim API call (`nvim_open_win`, `nvim_win_set_config`, `nvim_win_get_config`,
`nvim_set_option_value`, `strdisplaywidth`, `screenrow`/`screencol`) is cited with a
LIVE-VERIFIED runnable example, and the reference implementation was prototyped and run
green end-to-end. The two non-obvious traps — **`screenrow()`/`screencol()` return 1,1
headlessly** (so clamping is verified via a pure function) and **`relative="cursor"`
normalizes to `relative="win"` in get_config** — are spelled out in §Known Gotchas and
baked into the test design.

### Documentation & References

```yaml
# MUST READ — primary contract sources (in <selected_prd_content> + research/)

- url: https://neovim.io/doc/user/api.html#nvim_open_win()   # :help nvim_open_win
  why: "Defines the float config: relative/anchor/row/col/width/height/style/border/focusable."
  critical: "'relative=\"cursor\"' anchors at the caret cell; anchor NW=row grows down (row=1 =>
             1 cell below), anchor SW=bottom-left grows up (row=0 => sits above caret). 'border'
             adds a 1-cell frame on ALL sides (+2 rows, +2 cols) — MUST be counted in clamping.
             noautocmd=true (0.9+) suppresses WinEnter/BufEnter for the popup."

- url: https://neovim.io/doc/user/builtin.html#screenrow()   # :help screenrow / screencol
  why: "The contract's mandated positioning inputs — cursor's SCREEN row/col, 1-based."
  critical: "These are correct INTERACTIVELY but return 1,1 in --headless (see
             research/live-verification.md §3). => keep the clamping math in a PURE function
             and unit-test it with synthetic inputs; do NOT assert clamped positions through
             M.open() headlessly."

- url: https://neovim.io/doc/user/api.html#nvim_win_set_config()  # :help nvim_win_set_config
  why: "Reposition/resize an EXISTING float in place (the update-if-open, no-flicker path)."
  critical: "LIVE-VERIFIED: same window id after set_config; a negative 'col' shifts the
             window left. Pass the geometry+appearance fields; 'noautocmd' is open-only."

- url: https://neovim.io/doc/user/options.html#'wrap'  # :help wrap + nvim_set_option_value
  why: "Force wrap off on the popup so long labels/descriptions never fold."
  critical: "Use the non-deprecated 'nvim_set_option_value(\"wrap\", false, { win = w })'
             (the contract's nvim_win_set_option is its deprecated alias; both work on 0.12.4
             with no visible warning — verified)."

- url: https://neovim.io/doc/user/builtin.html#strdisplaywidth()  # :help strdisplaywidth
  why: "Width calc that counts double-width glyphs (CJK) as 2 cells."
  critical: "Use this, NOT '#s', so CJK labels size the menu correctly. Verified: '/model'=6,
             '日本語'=6."

- file: plan/001_c56962b4fa17/architecture/external_deps.md
  why: "§1.3 'Floating Window — menu.lua' is the EXACT nvim_open_win skeleton (create_buf,
        set_lines, add_highlight, open_win config, wrap=false, win_close). §6 pins the
        plenary test stack + selene/stylua. This task implements §1.3's create/open/close +
        clamping (highlight is S35)."

- file: plan/001_c56962b4fa17/P2M5T1S1/research/live-verification.md
  why: "LIVE-VERIFIED proof of every API behavior + the two critical gotchas (screenrow
        headless, relative normalization) + the prototype's end-to-end green run."

- file: plan/001_c56962b4fa17/P2M5T1S1/research/positioning-math.md
  why: "The clamping algorithm derivation + the 7-case verified result table that the spec
        asserts verbatim."

- file: plan/001_c56962b4fa17/P2M4T11S19/PRP.md   # (already implemented — see plugin/lua/pi-editor/init.lua)
  why: "S19 ships M.config / M.defaults / M.setup. This module reads menu config via
        'require('pi-editor').config or require('pi-editor').defaults'. Field names are
        LOCKED: menu.max_height, menu.border. init.lua does NOT require this module (no cycle)."

- file: plugin/tests/minimal_init.lua   # created by S19
  why: "Plenary harness bootstrap (rtp = plugin/ subdir + plenary). menu_spec.lua reuses it
        unchanged — no new bootstrap file is needed."

- docfile: plan/001_c56962b4fa17/prd_snapshot.md
  section: "§7.5 (menu.lua), §7.2 (module layout), §5.4 (AutocompleteItem shape), §10.5 (menu defaults)"
  why: "The verbatim contract for this popup and the item/config shapes."
```

### Current Codebase tree (relevant slice)

```bash
pi-nvim-bridge/                       # repo root (monorepo)
├── extension/                        # P1 pi-editor-bridge (TypeScript) — COMPLETE
├── plugin/                           # P2 pi-editor.nvim (Lua) — S19 DONE, rest in progress
│   ├── lua/pi-editor/
│   │   └── init.lua                  # S19: M.defaults/M.config/M.bridge/M.setup (CONTRACT for this task)
│   └── tests/
│       ├── minimal_init.lua          # S19: plenary harness bootstrap (REUSED — do not recreate)
│       ├── init_spec.lua             # S19: setup() spec
│       └── smoke.lua                 # S19: setup() smoke
├── PRD.md  README.md  package.json
└── plan/001_c56962b4fa17/
    ├── architecture/{external_deps,system_context,…}.md
    └── P2M5T1S1/{PRP.md, research/{live-verification,positioning-math}.md}   # THIS task
# NOTE: plugin/lua/pi-editor/menu.lua does NOT exist yet — this task CREATES it.
# NOTE: stylua/selene NOT installed; nvim 0.12.4 + plenary ARE. Hard gates = smoke + plenary.
```

### Desired Codebase tree with files to be added

```bash
plugin/
├── lua/pi-editor/
│   └── menu.lua                      # NEW — floating menu: lifecycle + geometry + selection  [THE deliverable]
└── tests/
    ├── menu_spec.lua                 # NEW — plenary/busted spec (Level-2 gate): pure fns + lifecycle
    └── smoke_menu.lua                # NEW — plenary-FREE smoke (Level-1 gate; :luafile + cquit)
# (plugin/tests/minimal_init.lua is REUSED from S19 unchanged.)
```

### Known Gotchas of our codebase & Library Quirks

```lua
-- GOTCHA #1 — runtimepath MUST point at the plugin/ SUBDIRECTORY, not the repo root
--   (inherited from S19; LIVE-VERIFIED). require("pi-editor.menu") resolves only when
--   rtp contains .../plugin (it looks for .../plugin/lua/pi-editor/menu.lua).

-- GOTCHA #2 — vim.fn.screenrow()/screencol() return 1,1 in --headless even when the real
--   cursor is elsewhere (while winline()/wincol() track it). PRODUCTION code still calls
--   screenrow()/screencol() per the contract (correct interactively); the CLAMPING LOGIC
--   is extracted into a pure compute_geometry(...) and unit-tested with synthetic inputs.
--   M.open() integration tests assert window creation/width/height/anchor only — NEVER a
--   specific clamped position. (research/live-verification.md §3.)

-- GOTCHA #3 — relative="cursor" is NORMALIZED to relative="win" by nvim_win_get_config
--   (with row/col resolved to the caret cell). So in tests assert width/height/anchor, NOT
--   cfg.relative == "cursor". Also cfg.border is a TABLE (chars) even for border="rounded"
--   — don't string-compare it. (research/live-verification.md §1.)

-- GOTCHA #4 — a non-"none" border adds 2 rows AND 2 cols of footprint. The clamping math
--   MUST reserve bv/bh so height+bv and width+bh never overflow the screen. (Verified.)

-- GOTCHA #5 — nvim_win_set_option is DEPRECATED (still works on 0.12.4, no visible warning).
--   Use the non-deprecated nvim_set_option_value("wrap", false, { win = w }) instead. Both
--   are equivalent; the modern form is forward-proof. (research/live-verification.md §6.)

-- GOTCHA #6 — noautocmd=true is an OPEN-time flag, NOT stored in the window config (it does
--   NOT appear in nvim_win_get_config, and nvim_win_set_config ignores it). Pass it only in
--   the nvim_open_win call. set_config takes the geometry+appearance fields.

-- GOTCHA #7 — width is CONTENT-DRIVEN, screen-clamped as an UPPER bound. A single 1-char
--   label yields width 1 (not the screen width). Clamping only shrinks, never grows.
--   (Caught + fixed during prototype verification — see the over-wide-label test case.)

-- GOTCHA #8 — keep the scratch buffer's bufhidden at its DEFAULT ("hide") so it survives
--   window close and is REUSED next open(). Do NOT set bufhidden="wipe" (that would delete
--   the buffer on close, defeating reuse). listed=false keeps it out of :ls.

-- GOTCHA #9 — SCOPE GUARD. This task is window lifecycle + geometry + selection INDEX only.
--   Do NOT implement: two-column rendering / selected-row highlight (S35 — leave a clearly
--   marked "[S35]" comment where highlights hook in), navigation key bindings (S36), or
--   auto-close autocmds (S37). set_selected() tracks state only; it does NOT render the
--   highlight (S35 will). _render_lines is a BASIC placeholder S35 will override.

-- GOTCHA #10 — do NOT forward-reference pi-editor.Config for the menu-config type; S19's
--   init.lua is the source. Read config via require("pi-editor").config or .defaults (the
--   fallback covers the unlikely case setup() hasn't run yet). No require cycle: init.lua
--   does not require menu.lua.
```

## Implementation Blueprint

### Data models and structure (LuaCATS — the [Mode A] docs)

Define the `AutocompleteItem` class at the top of `menu.lua`. It mirrors pi's
`AutocompleteItem` (PRD §5.4) exactly — this module CONSUMES items produced by the bridge;
it does not construct them.

```lua
---@class pi-editor.AutocompleteItem
---@field value string The text pi will insert/apply (passed back via applyCompletion).
---@field label string Short text shown in the menu (left column).
---@field description? string Optional secondary text (right column, truncated by S35).
```

### Implementation Tasks (ordered by dependencies)

```yaml
Task 1: CREATE plugin/lua/pi-editor/menu.lua
  - CREATE the module (the directory plugin/lua/pi-editor/ already exists from S19).
  - CONTENT: `local M = {}`; the @---@class pi-editor.AutocompleteItem block; module state
        fields (_items/_selected/_buf/_win) with @---@type; the config reader (falls back
        to S19 defaults); the PURE functions _border_dims/compute_width/compute_height/
        compute_geometry (VERBATIM the reference impl below — its 7-case output is verified);
        _ensure_buf (create-or-reuse scratch, bufhidden stays default); _render_lines
        (BASIC placeholder — label + "  " + description; S35 overrides); open/close/is_open;
        get_selected/set_selected/move/get_item; `return M`.
  - DOCS MODE A: @---@param/@---@return on every public function; the class-level docstring
        at the top explains the positioning model (relative="cursor", anchor NW/SW, edge
        clamping, cmdline reserve) — this is the contract's required docstring.
  - PRODUCTION CALLS (honor the contract exactly): vim.fn.screenrow(), vim.fn.screencol(),
        vim.o.lines, vim.o.columns (in open()); nvim_open_win / nvim_win_set_config /
        nvim_win_close / nvim_create_buf / nvim_buf_set_lines / nvim_set_option_value /
        nvim_win_is_valid / nvim_buf_is_valid / vim.fn.strdisplaywidth.
  - PLACEMENT: plugin/lua/pi-editor/menu.lua (require("pi-editor.menu")).
  - DO NOT (GOTCHA #9): implement two-column paint/highlight (S35), key bindings (S36),
        auto-close autocmds (S37). set_selected tracks state only.

Task 2: CREATE plugin/tests/menu_spec.lua  (plenary/busted — the Level-2 gate)
  - CONTENT: `describe("pi-editor.menu", …)` with (a) pure-function `it` blocks asserting
        compute_width (with-desc/no-desc/over-wide-clamp/empty/CJK), compute_height
        (0/under-max/clamp), and the 7 compute_geometry cases from positioning-math.md;
        (b) lifecycle blocks: open→is_open/valid window/width==computed/height==3/wrap==
        false/selected==1, re-open reuses SAME window id + resizes, set_selected/move/
        get_item clamp, close, open({})→nil+closed, reopen reuses buffer.
  - before_each: `package.loaded["pi-editor.menu"]=nil; package.loaded["pi-editor"]=nil;
        require("pi-editor").setup({}); require("pi-editor.menu")`.
  - ASSERTIONS: assert.are.same (tables), assert.are.equals (scalars), assert.is_true/
        is_false/is_nil, assert.has_no.errors. (Same luassert semantics as S19's spec.)
  - PLACEMENT: plugin/tests/menu_spec.lua.
  - DEPENDENCIES: Task 1 (menu.lua) + S19's tests/minimal_init.lua (harness).

Task 3: CREATE plugin/tests/smoke_menu.lua  (plenary-FREE — the Level-1 gate)
  - CONTENT (see Implementation Patterns): standalone script — append plugin_root to rtp
        (debug.getinfo + fnamemodify ':p'/':h:h', same as S19's smoke.lua), require + setup,
        run ~15 check(cond,msg) assertions over the pure functions + one open/close cycle,
        and `vim.cmd("cquit 1")` on any failure (a raw assert throw in -c/+ does NOT yield a
        non-zero exit — S19 GOTCHA #10).
  - WHY: instant dependency-free feedback (no plenary). menu_spec.lua remains the formal suite.
  - GOTCHA: source via `:luafile`, never a `:lua <<HEREDOC` in a -c/+ arg (E5107 — S19 #10).
  - PLACEMENT: plugin/tests/smoke_menu.lua.
  - DEPENDENCIES: Task 1 (menu.lua).
```

### Implementation Patterns & Key Details

```lua
-- === plugin/lua/pi-editor/menu.lua — COMPLETE reference implementation ===
-- (Functionally identical to the LIVE-VERIFIED prototype — research/live-verification.md §7.)
-- (The implementer may ship this verbatim; it passes every Success Criterion + the spec.)

--- pi-editor.nvim — dependency-free floating completion menu.
--
-- A single-file, zero-plugin floating popup that renders pi's `AutocompleteItem`s near
-- the caret and clamps to the screen edges (PRD §7.5). This module owns WINDOW LIFECYCLE
-- + GEOMETRY + selection INDEX; two-column rendering/selection highlight (S35), navigation
-- keys (S36), and auto-close autocmds (S37) layer on top.
--
-- Positioning model:
--   * Opened `relative = "cursor"` so Neovim anchors the float at the caret cell. We then
--     choose the corner (`anchor`) and a (possibly negative) `col` to keep it on-screen.
--   * Vertical — if (height + border) rows fit below the caret: open BELOW (anchor="NW",
--     row=1). Else if they fit above: open ABOVE (anchor="SW", row=0). Else clamp the
--     height to whichever side has more room.
--   * Horizontal — if (width + border) fits to the right of the caret: col=0. Else shift
--     the window LEFT via a negative `col`; if that would spill past the left edge, pin it
--     to column 0 and clamp the width instead.
--   * The last screen line is reserved for the cmdline so the menu never overlaps it.
--
-- The clamping math is a PURE function (compute_geometry) so it is fully unit-testable
-- without depending on vim.fn.screenrow() (which is pinned to 1 in --headless).

---@class pi-editor.AutocompleteItem
---@field value string The text pi will insert/apply.
---@field label string Short text shown in the menu (left column).
---@field description? string Optional secondary text (right column).

local M = {}

--- Current items. Empty when the menu is closed.
---@type pi-editor.AutocompleteItem[]
M._items = {}

--- 1-based index of the selected item. Reset to 1 on each open().
---@type integer
M._selected = 1

--- Scratch buffer reused across opens (listed=false, scratch=true). nil until first open.
---@type integer|nil
M._buf = nil

--- Floating window handle. nil when the menu is closed.
---@type integer|nil
M._win = nil

-- ---------------------------------------------------------------------------
-- Config (reads S19's already-shipped init.lua)
-- ---------------------------------------------------------------------------

--- Resolve the menu config, falling back to shipped defaults if setup() was not called.
---@param opts? table optional { max_height?, border? } overrides
---@return { max_height: integer, border: string|table }
local function menu_config(opts)
  opts = opts or {}
  local pi = require("pi-editor")           -- S19 module; does NOT require this file (no cycle)
  local cfg = pi.config or pi.defaults
  local menu = (cfg and cfg.menu) or {}
  return {
    max_height = opts.max_height or menu.max_height or 12,
    border = opts.border or menu.border or "rounded",
  }
end

-- ---------------------------------------------------------------------------
-- Pure geometry (fully unit-testable — no vim.fn/vim.o dependency)
-- ---------------------------------------------------------------------------

--- Border footprint in (rows, cols). "none" adds nothing; every other style (string or
--- char-table) adds a 1-cell frame on every side.
---@param border string|table
---@return integer rows, integer cols
function M._border_dims(border)
  if border == "none" then return 0, 0 end
  return 2, 2
end

--- Window width from items: max(label + gap + description), clamped to the screen width
--- minus the border. Uses display width (double-width aware). Content-driven upper-clamp.
---@param items pi-editor.AutocompleteItem[]
---@param ui_cols integer vim.o.columns
---@param border string|table
---@return integer width
function M.compute_width(items, ui_cols, border)
  local _, bh = M._border_dims(border)
  local gap = 2
  local max_w = 1
  for _, it in ipairs(items or {}) do
    local lw = vim.fn.strdisplaywidth(it.label or "")
    local desc = it.description
    local w = lw
    if desc and desc ~= "" then
      w = lw + gap + vim.fn.strdisplaywidth(desc)
    end
    if w > max_w then max_w = w end
  end
  return math.max(1, math.min(max_w, ui_cols - bh))
end

--- Window height: min(#items, max_height). 0 when there are no items.
---@param n_items integer
---@param max_height integer
---@return integer height
function M.compute_height(n_items, max_height)
  if n_items <= 0 then return 0 end
  return math.min(n_items, max_height)
end

--- Compute a cursor-relative floating-window config clamped to the screen edges.
---
--- All inputs are EXPLICIT (not read from vim.fn/vim.o) so this is a pure, deterministic
--- function — the entire clamping contract is verified by unit tests with synthetic values.
--- M.open() simply reads live values (screenrow/screencol/o.lines/o.columns) and forwards them.
---
---@param screen_row integer cursor screen row, 1-based (vim.fn.screenrow())
---@param screen_col integer cursor screen column, 1-based (vim.fn.screencol())
---@param ui_lines integer total screen rows (vim.o.lines)
---@param ui_cols integer total screen columns (vim.o.columns)
---@param width integer desired width (from compute_width)
---@param height integer desired height (from compute_height)
---@param border string|table
---@return table config { relative, anchor, row, col, width, height }
function M.compute_geometry(screen_row, screen_col, ui_lines, ui_cols, width, height, border)
  local bv, bh = M._border_dims(border)
  local reserve = 1 -- reserve the last screen line for the cmdline

  local space_below = (ui_lines - reserve) - screen_row -- rows strictly below the caret
  local space_above = screen_row - 1                    -- rows strictly above the caret
  local need_h = height + bv

  local anchor, row, final_height
  if space_below >= need_h then
    anchor, row, final_height = "NW", 1, height          -- room below -> open below
  elseif space_above >= need_h then
    anchor, row, final_height = "SW", 0, height          -- no room below, room above -> open above
  elseif space_below >= space_above then
    anchor, row, final_height = "NW", 1, math.max(1, space_below - bv) -- clamp to fit below
  else
    anchor, row, final_height = "SW", 0, math.max(1, space_above - bv) -- clamp to fit above
  end

  local need_w = width + bh
  local from_cursor_right = ui_cols - (screen_col - 1)   -- cols from the caret to the right edge
  local col, final_width = 0, width
  if need_w > from_cursor_right then
    col = from_cursor_right - need_w                      -- NEGATIVE: shift the window left
    if col < -(screen_col - 1) then                       -- would spill past the LEFT edge
      col = -(screen_col - 1)
      final_width = math.max(1, ui_cols - bh)             -- clamp width to the full screen
    end
  end

  return { relative = "cursor", anchor = anchor, row = row, col = col, width = final_width, height = final_height }
end

```lua
-- === plugin/lua/pi-editor/menu.lua — continued (lifecycle + selection) ===

--- Create the scratch buffer if absent/deleted. Reused across opens (listed=false keeps it
--- out of :ls; bufhidden stays default "hide" so it survives window close — GOTCHA #8).
function M._ensure_buf()
  if M._buf and vim.api.nvim_buf_is_valid(M._buf) then return end
  M._buf = vim.api.nvim_create_buf(false, true) -- listed=false, scratch=true
end

--- [S34 BASIC renderer] One line per item: `label` + ("  " + description) when present.
--- S35 will OVERRIDE this with padded two-column formatting + truncation; the width this
--- module computes already accounts for label+gap+description so the window is sized right
--- either way.
---@param items pi-editor.AutocompleteItem[]
---@param width integer final window width (unused by the basic renderer; S35 truncates to it)
---@return string[]
function M._render_lines(items, width)
  local lines, gap = {}, "  "
  for _, it in ipairs(items or {}) do
    local desc = it.description
    if desc and desc ~= "" then
      lines[#lines + 1] = (it.label or "") .. gap .. desc
    else
      lines[#lines + 1] = it.label or ""
    end
  end
  return lines
end

--- Open (or update) the completion menu with `items`.
--- Empty/nil items closes any open menu and returns nil. If already open, the existing
--- window is repositioned/resized in place via nvim_win_set_config (no flicker).
---@param items? pi-editor.AutocompleteItem[]
---@param opts? { max_height?: integer, border?: string|table }
---@return integer|nil win the floating window id, or nil if nothing was shown
function M.open(items, opts)
  items = items or {}
  if #items == 0 then M.close(); return nil end

  local mc = menu_config(opts)
  local border = mc.border
  local ui_lines, ui_cols = vim.o.lines, vim.o.columns
  local screen_row, screen_col = vim.fn.screenrow(), vim.fn.screencol() -- contract inputs

  local width = M.compute_width(items, ui_cols, border)
  local height = M.compute_height(#items, mc.max_height)
  if height <= 0 then M.close(); return nil end

  local geo = M.compute_geometry(screen_row, screen_col, ui_lines, ui_cols, width, height, border)

  M._ensure_buf()
  vim.api.nvim_buf_set_lines(M._buf, 0, -1, false, M._render_lines(items, geo.width))

  local win_cfg = {
    relative = geo.relative, anchor = geo.anchor, row = geo.row, col = geo.col,
    width = geo.width, height = geo.height, style = "minimal", border = border, focusable = false,
  }
  if M.is_open() then
    vim.api.nvim_win_set_config(M._win, win_cfg)                 -- reposition/resize in place
  else
    -- noautocmd is OPEN-only (GOTCHA #6): suppress WinEnter/BufEnter for the popup.
    M._win = vim.api.nvim_open_win(M._buf, false, vim.tbl_extend("keep", win_cfg, { noautocmd = true }))
  end
  vim.api.nvim_set_option_value("wrap", false, { win = M._win }) -- contract: wrap off (GOTCHA #5)

  M._items = items
  M._selected = 1                                               -- fresh list -> top item
  -- [S35] apply two-column highlight for the selected row here.
  return M._win
end

--- Close the menu. Idempotent. The scratch buffer is kept for reuse by the next open().
function M.close()
  if M._win and vim.api.nvim_win_is_valid(M._win) then
    vim.api.nvim_win_close(M._win, true)
  end
  M._win = nil
end

--- Whether the menu is currently visible.
---@return boolean
function M.is_open()
  return M._win ~= nil and vim.api.nvim_win_is_valid(M._win)
end

-- ---- Selection (state only — rendering of the highlight is task S35) ----

---@return integer 1-based selected index (1 when the menu is empty)
function M.get_selected() return M._selected end

--- Set the selected index, clamped to [1, #items]. Returns the clamped value.
--- (Re-rendering the selection highlight is S35's job.)
---@param idx integer
---@return integer
function M.set_selected(idx)
  local n = M._items and #M._items or 0
  if n == 0 then M._selected = 1; return 1 end
  M._selected = math.max(1, math.min(n, idx))
  -- [S35] re-apply the selected-row highlight here.
  return M._selected
end

--- Move the selection by `delta` (clamped, no wrap). Returns the new index.
--- (Wrap-around, if desired, is decided by the key-handler in S36.)
---@param delta integer
---@return integer
function M.move(delta) return M.set_selected((M._selected or 1) + (delta or 0)) end

--- The item at `idx` (default: the selected item), or nil.
---@param idx? integer
---@return pi-editor.AutocompleteItem|nil
function M.get_item(idx)
  idx = idx or M._selected
  return M._items and M._items[idx] or nil
end

return M
```

```lua
-- === plugin/tests/smoke_menu.lua — plenary-FREE smoke (Level-1 gate) ===
-- Run from the REPO ROOT:
--   nvim --headless --clean -u NORC +"luafile plugin/tests/smoke_menu.lua" +qa ; echo exit=$?
-- Exits 0 (prints MENU_SMOKE_PASS) or 1 (via cquit on any check failure). Zero deps.
local me = debug.getinfo(1, "S").source:sub(2)
me = vim.fn.fnamemodify(me, ":p")                  -- absolute path of THIS file
local plugin_root = vim.fn.fnamemodify(me, ":h:h") -- .../plugin  (rtp entry — GOTCHA #1)
vim.opt.runtimepath:append(plugin_root)

local fails = 0
local function check(c, m) if not c then io.stderr:write("FAIL: " .. m .. "\n"); fails = fails + 1 end end

require("pi-editor").setup({})
local menu = require("pi-editor.menu")

-- pure: compute_width
local its = {
  { value="/model", label="/model", description="Switch the model" },     -- 6+2+16=24
  { value="/compact", label="/compact", description="Compact context" },  -- 8+2+15=25
  { value="x", label="hi" },
}
check(menu.compute_width(its, 80, "rounded") == 25, "width max(label+gap+desc)=25")
check(menu.compute_width({{value="a",label="abcdefghij"}}, 5, "rounded") == 3, "width clamp over-wide to 3")
check(menu.compute_width({{value="a",label="日本語"}}, 80, "rounded") == 6, "width CJK=6")
-- pure: compute_height
check(menu.compute_height(0, 12) == 0, "height 0 items")
check(menu.compute_height(30, 12) == 12, "height clamps to max")
-- pure: compute_geometry (the clamping contract — positioning-math.md table)
local g = function(...) return menu.compute_geometry(...) end
check(g(1,1,24,80,40,3,"rounded").anchor=="NW", "geo top-left below (NW)")
check(g(24,1,24,80,40,3,"rounded").anchor=="SW", "geo bottom above (SW)")
check(g(1,80,24,80,40,3,"rounded").col==-41, "geo right-edge shift left col=-41")
check(g(10,1,24,80,100,3,"rounded").width==78, "geo over-wide clamp width=78")
check(g(12,1,24,80,40,12,"rounded").height==9, "geo neither-side-fits clamp h=9")
-- lifecycle
check(menu.is_open()==false, "not open initially")
local w = menu.open(its)
check(menu.is_open()==true and vim.api.nvim_win_is_valid(w), "open() -> valid window")
check(vim.wo[w].wrap==false, "wrap=false on popup")
check(menu.get_selected()==1, "selected resets to 1")
local w2 = menu.open({{value="v1",label="a"},{value="v2",label="bb"},{value="v3",label="ccc"}})
check(w2==w, "re-open reuses same window id")
menu.set_selected(99); check(menu.get_selected()==3, "set_selected clamps to 3")
menu.close(); check(menu.is_open()==false, "closed")
check(menu.open({})==nil and menu.is_open()==false, "open({}) -> nil + closed")
menu.close()

if fails > 0 then io.stderr:write(fails .. " check(s) failed\n"); vim.cmd("cquit 1") end
io.stdout:write("MENU_SMOKE_PASS\n")
```

```lua
-- === plugin/tests/menu_spec.lua — plenary/busted spec (Level-2 gate) ===
-- Run (from the plugin/ dir, OR pass absolute path):
--   cd plugin && nvim --headless --clean -u tests/minimal_init.lua \
--     -c 'lua require("plenary.busted").run("tests/menu_spec.lua")'
describe("pi-editor.menu", function()
  local menu

  before_each(function()
    package.loaded["pi-editor.menu"] = nil
    package.loaded["pi-editor"] = nil
    require("pi-editor").setup({})
    menu = require("pi-editor.menu")
  end)

  after_each(function() menu.close() end)

  describe("compute_width", function()
    local its = {
      { value="/model", label="/model", description="Switch the model" },
      { value="/compact", label="/compact", description="Compact context" },
      { value="x", label="hi" },
    }
    it("is max(label+gap+description)", function()
      assert.are.equals(25, menu.compute_width(its, 80, "rounded"))
    end)
    it("is max label when no descriptions", function()
      assert.are.equals(5, menu.compute_width({{value="a",label="alpha"},{value="b",label="beta"}}, 80, "rounded"))
    end)
    it("clamps over-wide content to ui_cols-border", function()
      assert.are.equals(3, menu.compute_width({{value="a",label="abcdefghij"}}, 5, "rounded"))
    end)
    it("is 1 for empty items", function()
      assert.are.equals(1, menu.compute_width({}, 80, "rounded"))
    end)
    it("counts double-width glyphs (CJK)", function()
      assert.are.equals(6, menu.compute_width({{value="a",label="日本語"}}, 80, "rounded"))
    end)
  end)

  describe("compute_height", function()
    it("is 0 for no items", function() assert.are.equals(0, menu.compute_height(0, 12)) end)
    it("is #items when under max", function() assert.are.equals(5, menu.compute_height(5, 12)) end)
    it("clamps to max_height", function() assert.are.equals(12, menu.compute_height(30, 12)) end)
  end)

  describe("compute_geometry (edge clamping)", function()
    local function g(...) return menu.compute_geometry(...) end
    it("opens BELOW the caret when there is room (top-left)", function()
      local r = g(1,1,24,80,40,3,"rounded")
      assert.are.equals("NW", r.anchor); assert.are.equals(1, r.row); assert.are.equals(0, r.col)
      assert.are.equals(3, r.height); assert.are.equals(40, r.width)
    end)
    it("opens ABOVE the caret when near the bottom", function()
      local r = g(24,1,24,80,40,3,"rounded")
      assert.are.equals("SW", r.anchor); assert.are.equals(0, r.row)
    end)
    it("opens above when not enough room below even for a short menu", function()
      local r = g(20,1,24,80,40,3,"rounded") -- space_below=3 < need 5; space_above=19 >= 5
      assert.are.equals("SW", r.anchor); assert.are.equals(0, r.row)
    end)
    it("shifts LEFT (negative col) when near the right edge", function()
      local r = g(1,80,24,80,40,3,"rounded") -- need_w=42 > from_cursor_right=1 => col=-41
      assert.are.equals(-41, r.col); assert.are.equals(40, r.width)
    end)
    it("clamps WIDTH when wider than the screen", function()
      local r = g(10,1,24,80,100,3,"rounded") -- spill past left edge => pin left, width=78
      assert.are.equals(0, r.col); assert.are.equals(78, r.width)
    end)
    it("clamps HEIGHT when neither side fits the full menu", function()
      local r = g(12,1,24,80,40,12,"rounded") -- both sides 11 < need 14 => clamp h=9 below
      assert.are.equals("NW", r.anchor); assert.are.equals(9, r.height)
    end)
    it("treats border='none' as zero footprint", function()
      local r = g(24,1,24,80,40,3,"none")
      assert.are.equals("SW", r.anchor); assert.are.equals(0, r.row)
    end)
  end)

  describe("lifecycle", function()
    local its = {
      { value="/model", label="/model", description="Switch the model" },
      { value="/compact", label="/compact", description="Compact context" },
      { value="x", label="hi" },
    }
    it("open() shows a valid window with computed width/height, wrap off, selected=1", function()
      assert.is_false(menu.is_open())
      local w = menu.open(its)
      assert.is_not_nil(w)
      assert.is_true(menu.is_open())
      assert.is_true(vim.api.nvim_win_is_valid(w))
      local cfg = vim.api.nvim_win_get_config(w)
      assert.are.equals(25, cfg.width)   -- == compute_width(its, …)
      assert.are.equals(3, cfg.height)   -- == min(#items, max_height)
      assert.is_false(vim.wo[w].wrap)
      assert.are.equals(1, menu.get_selected())
    end)
    it("re-open while open reuses the SAME window id and resizes it", function()
      local w = menu.open(its)
      local more = {}
      for i=1,8 do more[i]={value="v"..i,label="item-"..i,description="d"..i} end
      local w2 = menu.open(more)
      assert.are.equals(w, w2)                       -- same handle (nvim_win_set_config)
      assert.are.equals(8, vim.api.nvim_win_get_config(w).height)
    end)
    it("close() is idempotent and closes the window", function()
      menu.open(its)
      menu.close(); assert.is_false(menu.is_open())
      menu.close(); assert.is_false(menu.is_open())  -- idempotent
    end)
    it("open({}) / open(nil) closes and returns nil", function()
      menu.open(its)
      assert.is_nil(menu.open({}))
      assert.is_false(menu.is_open())
    end)
    it("reopen after close reuses the scratch buffer", function()
      local b1 = menu._buf
      menu.open(its); menu.close()
      menu.open({{value="z",label="only"}})
      assert.are.equals(b1, menu._buf)               -- same buffer (reused, not recreated)
    end)
  end)

  describe("selection", function()
    it("set_selected clamps to [1,#items]", function()
      menu.open({{value="1",label="a"},{value="2",label="b"},{value="3",label="c"}})
      menu.set_selected(99); assert.are.equals(3, menu.get_selected())
      menu.set_selected(-5); assert.are.equals(1, menu.get_selected())
    end)
    it("move(delta) is clamped", function()
      menu.open({{value="1",label="a"},{value="2",label="b"},{value="3",label="c"}})
      menu.move(2); assert.are.equals(3, menu.get_selected())
      menu.move(-10); assert.are.equals(1, menu.get_selected())
    end)
    it("get_item() returns the selected item; get_item(i) the i-th", function()
      menu.open({{value="v1",label="a"},{value="v2",label="b"}})
      menu.set_selected(2)
      assert.are.equals("v2", menu.get_item().value)
      assert.are.equals("v1", menu.get_item(1).value)
    end)
  end)
end)
```

### Integration Points

```yaml
CONFIG (reads S19 — do NOT redefine):
  - require("pi-editor").config.menu.max_height  (default 12) and .border (default "rounded")
  - menu.lua reads (pi.config or pi.defaults).menu — survives even if setup() hasn't run.

MODULE SURFACE (public API, locked by this task):
  - require("pi-editor.menu").open(items, opts?) -> win|nil   (open or update-in-place)
  - require("pi-editor.menu").close()                          (idempotent)
  - require("pi-editor.menu").is_open() -> bool
  - require("pi-editor.menu").get_selected() / set_selected(i) / move(d) / get_item(i?)
  - PURE (testable): compute_width(items, ui_cols, border) / compute_height(n, max) /
    compute_geometry(screen_row, screen_col, ui_lines, ui_cols, w, h, border)

FORWARD CONTRACTS (do NOT implement here — just leave clean seams):
  - S35 (rendering) overrides M._render_lines and adds highlight calls at the marked
    "[S35]" points (in open() and set_selected()).
  - S36 (key handling) maps <C-N>/<C-P>/<Up>/<Down> to M.move(±1), <C-E> to M.close(),
    <Tab>/<C-Y>/<CR> accept to M.get_item() then M.close().
  - S37 (auto-close) calls M.close() from InsertLeave / CursorMoved-out-of-prefix autocmds.
  - S32 (accept flow) calls M.get_item() to read the selected AutocompleteItem.

NO DATABASE / NO NETWORK / NO AUTOCMDS / NO KEYMAPS in this task (GOTCHA #9).
```

## Validation Loop

> **Run all commands from the REPO ROOT** (`/home/dustin/projects/pi-nvim-bridge`).
> The plugin root is `$(pwd)/plugin`. **Every command below is LIVE-VERIFIED green**
> against the prototype (research/live-verification.md §7: `MENU_VERIFY_PASS 0`);
> the smoke + plenary commands run green once `menu.lua` + the two test files ship verbatim.

### Level 1: Syntax & Load (Immediate Feedback — dependency-free, no plenary)

```bash
# 1a. Smoke test via the deliverable plugin/tests/smoke_menu.lua (plenary-FREE fast feedback).
#     Sets its own runtimepath + cquit(1) on failure (reliable exit code; S19 GOTCHA #10).
#     Run from the REPO ROOT (source via :luafile — NEVER a :lua <<HEREDOC in -c/+ args).
nvim --headless --clean -u NORC +"luafile plugin/tests/smoke_menu.lua" +qa
echo "exit=$?   # 0 = pass (prints MENU_SMOKE_PASS), 1 = a check failed"
```

```bash
# 1b. (Optional, only if installed) Lua lint/format. NOT a hard gate.
command -v selene >/dev/null && selene -q plugin/lua/pi-editor/menu.lua || echo "selene not installed (skipped; optional)"
command -v stylua >/dev/null && stylua --check plugin || echo "stylua not installed (skipped; optional)"
```

### Level 2: Unit Tests (plenary spec — the formal clamping + lifecycle gate)

```bash
# 2a. In-process plenary run (reuses S19's tests/minimal_init.lua harness — no new bootstrap).
cd plugin
nvim --headless --clean -u tests/minimal_init.lua \
  -c 'lua require("plenary.busted").run("tests/menu_spec.lua")'
echo "exit=$?"   # 0 = all pass; 1 = an 'it' failed; 2 = load/error
cd ..
# Expected: ~25 'it' blocks pass (width×5, height×3, geometry×7, lifecycle×5, selection×3).
```

### Level 3: Integration (runtimepath + real floating window)

```bash
# 3a. Prove require("pi-editor.menu") resolves only with rtp=plugin/ (GOTCHA #1) and opens a float.
PLUGIN_ROOT="$(pwd)/plugin"
nvim --headless --clean -u NORC +"lua vim.opt.runtimepath:append('$PLUGIN_ROOT')" \
  +'lua require("pi-editor").setup({}); local m=require("pi-editor.menu"); local w=m.open({{value="a",label="/model",description="x"},{value="b",label="/compact"}}); io.stdout:write("win="..tostring(w).." open="..tostring(m.is_open()).." w="..vim.api.nvim_win_get_config(w).width.."\n"); m.close()' \
  +qa 2>&1 | tail -1
# Expected: win=<id> open=true w=8   (label "/compact"=8, no desc on second => max label 8)

# 3b. Verify the update-in-place path (re-open reuses the same window id) end to end.
nvim --headless --clean -u NORC +"lua vim.opt.runtimepath:append('$PLUGIN_ROOT')" \
  +'lua require("pi-editor").setup({}); local m=require("pi-editor.menu"); local w1=m.open({{value="a",label="x"}}); local w2=m.open({{value="b",label="y"},{value="c",label="z"},{value="d",label="q"}}); io.stdout:write("same="..tostring(w1==w2).." h="..vim.api.nvim_win_get_config(w1).height.."\n"); m.close()' \
  +qa 2>&1 | tail -1
# Expected: same=true h=3   (window resized from 1 to 3 rows without close+reopen)
```

### Level 4: Creative & Domain-Specific Validation (clamping proof)

```bash
# 4a. Prove the clamping contract via the PURE function across all cursor positions
#     (this is how edge clamping is verified — screenrow() is pinned to 1 headlessly,
#      so M.open() can't exercise it directly; the pure function can).
nvim --headless --clean -u NORC +"lua vim.opt.runtimepath:append('$PLUGIN_ROOT')" \
  +'lua local g=require("pi-editor.menu").compute_geometry; local function p(r) return ("anchor=%s row=%s col=%s w=%s h=%s"):format(r.anchor,tostring(r.row),tostring(r.col),r.width,r.height) end; io.stdout:write("topleft="..p(g(1,1,24,80,40,3,"rounded")).."\nbottom="..p(g(24,1,24,80,40,3,"rounded")).."\nright="..p(g(1,80,24,80,40,3,"rounded")).."\nhugew="..p(g(10,1,24,80,100,3,"rounded")).."\nmany="..p(g(12,1,24,80,40,12,"rounded")).."\n")' \
  +qa 2>&1 | tail -5
# Expected (matches research/positioning-math.md table verbatim):
#   topleft=anchor=NW row=1 col=0 w=40 h=3
#   bottom=anchor=SW row=0 col=0 w=40 h=3
#   right=anchor=NW row=1 col=-41 w=40 h=3
#   hugew=anchor=NW row=1 col=0 w=78 h=3
#   many=anchor=NW row=1 col=0 w=40 h=9
```

## Final Validation Checklist

### Technical Validation

- [ ] Level 1 smoke test prints `MENU_SMOKE_PASS` and `exit=0`.
- [ ] Level 2 plenary spec `tests/menu_spec.lua` exits 0 (~25 `it` blocks pass).
- [ ] Level 3a: `M.open` creates a valid float; width == `compute_width`.
- [ ] Level 3b: re-open reuses the same window id + resizes (no flicker).
- [ ] Level 4: `compute_geometry` outputs match the positioning-math.md table exactly.
- [ ] (Optional) selene/stylua clean IF installed (NOT a hard gate).

### Feature Validation

- [ ] `M.open(items)` shows a valid cursor-relative float; `M.is_open()` true.
- [ ] Window `width` == `compute_width(items,…)`; `height` == `min(#items, max_height)`.
- [ ] `wrap == false` on the popup (`nvim_set_option_value`).
- [ ] Re-`open` reuses the window id (in-place resize via `nvim_win_set_config`).
- [ ] `close()` idempotent; `open({})`/`open(nil)` close + return nil.
- [ ] Reopen after close reuses the scratch buffer (bufhidden default "hide").
- [ ] Clamping: below(top)/above(bottom)/shift-left(right)/width-clamp(huge)/height-clamp(many).
- [ ] `compute_width` double-width-aware (CJK); screen-clamped; empty⇒1.
- [ ] `set_selected`/`move` clamp; `get_item()`/`get_item(i)` return items.
- [ ] [Mode A] LuaCATS annotations on all public functions + `AutocompleteItem` class.

### Code Quality Validation

- [ ] Production code calls `vim.fn.screenrow()/screencol()` + `vim.o.lines/columns` (contract).
- [ ] Clamping math is PURE (`compute_geometry`) — not entangled with `vim.fn.*`.
- [ ] Border overhead (+2/+2, or 0 for "none") counted in all geometry math.
- [ ] Scratch buffer reused (bufhidden NOT "wipe"); listed=false; scratch=true.
- [ ] `noautocmd=true` only on the `nvim_open_win` call (GOTCHA #6).
- [ ] Public field/function names EXACTLY: open/close/is_open/get_selected/set_selected/move/
      get_item/compute_width/compute_height/compute_geometry (forward contracts for S35–S37/S32).
- [ ] Scope guard honored: NO two-column paint/highlight (S35), NO keymaps (S36), NO autocmds (S37).

### Documentation & Deployment

- [ ] [Mode A] module-level docstring explains the positioning model + clamping (contract's doc requirement).
- [ ] No new env vars, config keys, autocmds, or keymaps introduced.
- [ ] (doc/pi-editor.txt + README are separate tasks — S43/S44, NOT this task.)

---

## Anti-Patterns to Avoid

- ❌ Don't assert `cfg.relative == "cursor"` from `nvim_win_get_config` — it normalizes to
  `"win"` (GOTCHA #3). Assert `width`/`height`/`anchor`, and verify clamping via the pure
  `compute_geometry`.
- ❌ Don't test edge clamping through `M.open()` headlessly — `screenrow()`/`screencol()`
  are pinned to 1 in `--headless` (GOTCHA #2). Use `compute_geometry` with synthetic inputs.
- ❌ Don't set `bufhidden="wipe"` on the scratch buffer — it deletes the buffer on close and
  breaks reuse (GOTCHA #8). Leave it at default "hide".
- ❌ Don't forget border overhead (+2 rows / +2 cols) in the geometry math, or the popup will
  overflow the screen by the border width (GOTCHA #4).
- ❌ Don't pass `noautocmd=true` to `nvim_win_set_config` expecting it to apply — it's an
  open-only flag (GOTCHA #6); pass it only to `nvim_open_win`.
- ❌ Don't use `nvim_win_set_option` (deprecated) when `nvim_set_option_value("wrap", false,
  {win=w})` is the forward-proof equivalent (GOTCHA #5).
- ❌ Don't use `#label` for width — use `vim.fn.strdisplaywidth` so CJK/double-width glyphs
  size the menu correctly.
- ❌ Don't implement two-column rendering / highlight / keymaps / autocmds here — those are
  S35/S36/S37 (GOTCHA #9). Leave the marked `[S35]` seams and a basic `_render_lines`.
- ❌ Don't make validation depend on selene/stylua — they're not installed. The headless smoke
  test + plenary spec are the hard gates.
- ❌ Don't point `runtimepath` at the repo root — it must be the `plugin/` subdir (GOTCHA #1,
  inherited from S19) or `require("pi-editor.menu")` fails with "module not found".
