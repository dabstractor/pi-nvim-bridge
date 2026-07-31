# PRP — P2.M8.T21.S34: Floating window creation with cursor-relative positioning & edge clamping

**Parent task:** P2.M8.T21 (menu.lua — popup creation, rendering & positioning)
**Module:** P2.M8 (Floating Completion Menu / `menu.lua`) — Neovim (Lua) side
**Plan path:** `plan/001_c56962b4fa17/P2M8T21S34/`
**Scope:** ONLY S34 (the WINDOW half). S35 (two-column rendering + highlights), S36
(navigation), S37 (auto-close) are SEPARATE, later tasks — do NOT implement them.

---

## Goal

**Feature Goal:** Replace S31's local no-op `render(state)` stub in
`plugin/lua/pi-editor/menu.lua` with a real **dependency-free floating completion popup** —
a scratch buffer + `nvim_open_win` / `nvim_win_set_config` — positioned **relative to the
cursor** with **deterministic edge-clamping** (above/below + left/right), so that when
`completion.on_results` delivers items, a visible window appears showing them and follows the
cursor without flicker.

**Deliverable:**
1. In `plugin/lua/pi-editor/menu.lua` (an EXISTING file — edit, do not rewrite):
   - Implement the local `render(state)` function (currently `local render = function(_state) end`)
     to **open/show** the floating window on the open path and **close** it on the close path.
   - Add three **pure, testable** geometry helpers: `compute_width`, `compute_height`,
     `compute_geometry` (module-level locals; expose via `M._compute_*` for unit-testing).
   - Manage the `state.win` / `state.menu_buf` lifecycle (lazy create, reuse buffer,
     in-place reposition via `nvim_win_set_config`, close window on hide).
   - Set basic **label-only** buffer content for S34 (so the window has visible rows);
     S35 will enhance to two-column label/description + highlights.
2. Update `plugin/tests/menu_spec.lua` (plenary) + `plugin/tests/menu_smoke.lua`
   (plenary-free) so they now assert the **window IS created/positioned/closed** correctly
   (the current spec explicitly asserts the OPPOSITE — "S34's job" — see Task 5).
3. (Optional but recommended) `plugin/tests/menu_geometry_spec.lua` — a focused plenary spec
   for the 3 pure geometry helpers against the verified case table (§Validation).

**Success Definition:**
- `menu.open(items)` produces a **valid floating window** (`nvim_win_is_valid`) showing the
  item labels; `menu.close()` closes it (`nvim_win_is_valid == false`); a second `open()`
  **reuses the scratch buffer** and repositions the same window in place (no flicker, no
  buffer leak); `reset()` closes the window + nils handles.
- The pure `compute_geometry` returns the EXACT 7-case results in the verified table
  (research/notes.md §3) for synthetic inputs.
- `menu.lua` introduces **zero new runtime dependencies** (only `vim.api` / `vim.fn` / `vim.o`).
- The full test suite (`menu_spec.lua`, `menu_smoke.lua`, + sibling specs/smokes) runs green
  headlessly; the plugin stays dormant in non-pi nvim sessions.

---

## All Needed Context

### Context Completeness Check

> "If someone knew nothing about this codebase, would they have everything needed to implement this successfully?"

**Yes.** This PRP embeds: the exact seam (`render(state)` in menu.lua, line-anchored), the
exact live-verified `compute_geometry` algorithm + its 7-case table, the
`nvim_open_win`/`nvim_win_set_config` config shape, the window lifecycle pattern (verified
against blink.cmp), the headless-testing gotcha + its pure-function mitigation, and the
exact validation commands. The implementing agent edits ONE existing file (`menu.lua`),
adapts the prototype geometry to the shipped S31 shape, and updates two existing test files.

### Documentation & References

```yaml
# ── THIS PRP's research (READ FIRST) ──
- file: plan/001_c56962b4fa17/P2M8T21S34/research/notes.md
  why: The consolidated research: the S31 surface S34 builds on, the blink.cmp window
       lifecycle pattern, the live-verified compute_geometry algorithm + 7-case table, the
       headless screenrow/screencol gotcha, the P2M5T1S1-prototype vs S31-shape reconciliation.
  critical: §3 (the EXACT clamping algorithm + verified case table), §4 (pure-function split
       mandate), §6 (gotchas). The compute_width/compute_height/compute_geometry code blocks
       are copy-paste-ready reference implementations.

# ── PRIOR live-verified research (the source of §3) ──
- file: plan/001_c56962b4fa17/P2M5T1S1/research/positioning-math.md
  why: The derivation of the clamping algorithm + the verified 7-case table (computed by a
       live prototype, MENU_VERIFY_PASS 0). This is the canonical geometry spec.
- file: plan/001_c56962b4fa17/P2M5T1S1/research/live-verification.md
  why: Live-verified API behaviors: nvim_open_win config shape, relative="cursor"→"win"
       normalization in get_config (GOTCHA A), nvim_win_set_config resizes in place,
       screenrow/screencol pinned to 1 headless, border overhead +2/+2, strdisplaywidth CJK,
       nvim_set_option_value form, the prototype's 26-check green run.
  pattern: Section §1 (nvim_open_win), §2 (set_config in-place), §3 (headless screenrow quirk).
- file: plan/001_c56962b4fa17/P2M5T1S2/research/highlight-layering.md
  why: S35's research (two-column + highlights). READ for the 1-based↔0-indexed trap + the
       Pmenu/PmenuSel/Comment groups + strdisplaywidth/strcharpart/strchars usage, but DO NOT
       implement two-column/highlights in S34 (that's S35). S34 uses label-only lines.

# ── THE FILE YOU EDIT (read fully first) ──
- file: plugin/lua/pi-editor/menu.lua
  why: S31's windowless menu-STATE module. S34 EDITS the local render(state) stub + ADDS
       pure geometry helpers + manages state.win/state.menu_buf. Do NOT touch the state layer.
  pattern: the `local render = function(_state) end` stub (search "S34 implements"); the
       `state` singleton with `win = nil, menu_buf = nil` forward-contract fields; open()/
       close()/reset()/on_results() that ALREADY call render(state).
  gotcha: open(items) sets state.open=(#items>0) BEFORE render — so render MUST guard on
       `state.open and #state.items > 0`; open({}) → close path (no window).

# ── THE DRIVER (how render is reached) ──
- file: plugin/lua/pi-editor/completion.lua
  why: The do_refresh cb fires M.on_results(buf, items, prefix) on the nvim MAIN LOOP
       (bridge cb is schedule_wrap'd → api-safe) → menu.on_results → open()/close() → render.
       Confirms render runs api-safe + per-keystroke (must NEVER throw).
  pattern: do_refresh reads `nvim_buf_get_lines` + `nvim_win_get_cursor` (the cursor the menu
       positions relative to lives in the current window showing state.buf).

# ── CONFIG CONTRACT (max_height, border) ──
- file: plugin/lua/pi-editor/init.lua
  why: M.config.menu.{max_height,border} — the resolved appearance config (defaults
       max_height=12, border="rounded"). render reads it FRESH via require("pi-editor").
  pattern: `((require("pi-editor").config or require("pi-editor").defaults) or {}).menu`
       (the codebase-wide config-read pattern; self-sufficient if setup() never ran).

# ── Neovim API docs (anchor-cited) ──
- url: https://neovim.io/doc/user/api.html#nvim_open_win()
  why: nvim_open_win config keys: relative/anchor/row/col/width/height/style/border/
       focusable/noautocmd/zindex. anchor="SW",row=0 ⇒ window ABOVE cursor (grows up); a
       NEGATIVE col shifts the window LEFT.
- url: https://neovim.io/doc/user/api.html#nvim_win_set_config()
  why: Reconfigures an EXISTING float IN PLACE (same window id, no flicker); accepts the same
       config keys. Used for the no-flicker reposition-while-open path.
- url: https://neovim.io/doc/user/api.html#nvim_create_buf()
  why: nvim_create_buf(false, true) ⇒ unlisted scratch buffer (the popup's content buffer).
- url: https://neovim.io/doc/user/builtin.html#strdisplaywidth()
  why: vim.fn.strdisplaywidth(s) — display-column width (CJK/double-width = 2 cells). NOT #s.
- url: https://neovim.io/doc/user/builtin.html#screenrow()
  why: vim.fn.screenrow()/screencol() — cursor screen position (1-based). NOTE: return 1
       headlessly (the pure-function-split mandate — research/notes.md §4).

# ── REFERENCE IMPLEMENTATIONS (cross-check, don't copy) ──
- url: https://github.com/Saghen/blink.cmp/blob/78336bc89ee5365633bcf754d93df01678b5c08f/lua/blink/cmp/lib/window/init.lua
  why: blink.cmp's float helper — create-buffer-once/reuse, close-on-hide/recreate-on-next-open,
       reposition-in-place via nvim_win_set_config. The window lifecycle S34 mirrors.
  pattern: the buffer is cached (create once); the window is closed on hide + recreated on the
       next open reusing the buffer; while open, every reposition uses nvim_win_set_config.
```

### Current Codebase tree (the files S34 touches)

```bash
plugin/
  lua/pi-editor/
    menu.lua          # ← EDIT: implement render(state) + add geometry helpers + lifecycle
    completion.lua    # (read-only) the driver that fires on_results → open/close → render
    init.lua          # (read-only) M.config.menu.{max_height,border}
  tests/
    menu_spec.lua     # ← EDIT: flip case (18) "no window" → "window created"; add lifecycle cases
    menu_smoke.lua    # ← EDIT: assert a window IS created in the real-bridge flow
    minimal_init.lua  # (read-only) plenary harness bootstrap (reuse as-is)
  plugin/pi-editor.lua  # (read-only) VimEnter shim
  ftplugin/pi-prompt.lua # (read-only) buffer-local wiring
```

### Desired Codebase tree (the change footprint)

```bash
plugin/
  lua/pi-editor/menu.lua            # MODIFIED — render(state) implemented + geometry helpers + lifecycle
  tests/menu_spec.lua               # MODIFIED — flip no-window assertion + add window-lifecycle cases
  tests/menu_smoke.lua              # MODIFIED — assert window created/closed in the flow
  tests/menu_geometry_spec.lua      # NEW (recommended) — pure compute_* cases vs the verified table
```

### Known Gotchas of our codebase & Neovim quirks

```lua
-- CRITICAL (research/notes.md §4): vim.fn.screenrow()/screencol() return 1 in --headless
-- regardless of the real cursor. The PRODUCTION render MUST call them (correct interactively),
-- but the CLAMPING LOGIC must live in PURE compute_geometry(screen_row, screen_col, …) taking
-- EXPLICIT inputs — unit-tested with synthetic values (the 7-case table). render's integration
-- tests assert width/height/anchor/validity ONLY, never a clamped position.

-- CRITICAL (GOTCHA A, live-verification.md §1): nvim_open_win with relative="cursor" is
-- NORMALIZED to relative="win" (win=<handle>, row/col resolved to the cursor cell) in
-- nvim_win_get_config. NEVER assert cfg.relative == "cursor" in tests — assert width/height/
-- anchor. Also: cfg.border is a TABLE (chars) even when you pass "rounded" — don't string-compare.

-- CRITICAL: strdisplaywidth, NOT #s (CJK/double-width = 2 cells). Verified: "/model"=6, "日本語"=6.
-- Use vim.fn.strdisplaywidth for ALL menu width math.

-- CRITICAL: border overhead — a non-"none" border adds a 1-cell frame on all 4 sides ⇒ +2 rows,
-- +2 cols (bv=2, bh=2). "none" ⇒ 0,0. Reserve these so height+bv / width+bh never overflow.

-- CRITICAL (S31 contract): render is reached per-keystroke via on_results (pcall'd by S30), but
-- render ITSELF must be defensive: pcall every nvim call; nvim_win_is_valid before set_config/
-- close; nvim_buf_is_valid before set_lines; NEVER throw (a window bug must not abort completion).

-- LIFECYCLE (blink pattern, verified): REUSE the scratch buffer across open/close (don't delete
-- on close — only reset()/teardown nils state.menu_buf). CLOSE the window on hide (nvim_win_close),
-- RECREATE on the next open reusing the buffer. REPOSITION IN PLACE (nvim_win_set_config) while
-- the window stays open (no close+reopen, no flicker).

-- open({}) is a CLOSE PATH: S31's open(items) sets state.open=(#items>0) BEFORE render, so an
-- empty items array ⇒ state.open=false ⇒ render must take the close path (no window). render MUST
-- guard: `if state.open and #state.items > 0 then <show> else <hide> end`.

-- nvim_set_option_value(opt, val, { win = win }) is the non-deprecated window-option form
-- (nvim_win_set_option still works on 0.12 but is older). Set wrap=false on the popup win.

-- The popup shows a SCRATCH buffer (state.menu_buf), NOT the pi-prompt buffer (state.buf).
-- Positioning is relative to the cursor in the CURRENT window (which shows state.buf — one
-- buf/session, PRD §11). screenrow()/screencol() give that cursor's screen position.
```

---

## Implementation Blueprint

### The geometry helpers (PURE, module-level locals in menu.lua)

Add these as module-level local functions (placed above `render`). Expose them on `M`
as `M._compute_width` / `M._compute_height` / `M._compute_geometry` so the spec can assert
them directly (the codebase convention — pure helpers are unit-tested; see `coords_spec.lua`).
These are the copy-paste-ready reference implementations from
`research/notes.md §3` (LIVE-VERIFIED):

```lua
-- ── PURE geometry helpers (no vim.fn.screenrow/col reads here — those are in render) ──
-- Width = label-only for S34 (S35 widens to label+gap+description). CJK-aware via
-- strdisplaywidth. Clamped to the available screen columns minus border overhead.
local function compute_width(items, ui_cols, border_h_overhead)
  local max_w = 0
  for _, it in ipairs(items) do
    local label = (type(it) == "table" and type(it.label) == "string") and it.label or ""
    local w = vim.fn.strdisplaywidth(label)
    if w > max_w then max_w = w end
  end
  return math.max(1, math.min(max_w, ui_cols - border_h_overhead))
end

-- Height = min(#items, max_height); 0 when empty (render's show guard handles 0).
local function compute_height(n_items, max_height)
  if type(n_items) ~= "number" or n_items <= 0 then return 0 end
  local mh = (type(max_height) == "number" and max_height > 0) and max_height or 12
  return math.min(math.floor(n_items), mh)
end

-- THE clamping algorithm. Returns {anchor,row,col,width,height} for nvim_open_win /
-- nvim_win_set_config. EXACT 7-case outputs in research/notes.md §3 (verified).
local function compute_geometry(screen_row, screen_col, ui_lines, ui_cols, width, height, max_height, border)
  local has_border = (border ~= nil) and (border ~= "none")
  local bv = has_border and 2 or 0   -- border vertical overhead (rows)
  local bh = has_border and 2 or 0   -- border horizontal overhead (cols)
  -- clamp height to max_height first (width already clamped by compute_width)
  height = math.min(height, max_height)
  -- VERTICAL: choose below (NW,row=1) vs above (SW,row=0), clamping to fit
  local reserve     = 1                                  -- never paint over the cmdline
  local space_below = (ui_lines - reserve) - screen_row  -- rows strictly below caret
  local space_above = screen_row - 1                      -- rows strictly above caret
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
  -- HORIZONTAL: fit right of caret, else shift left (negative col), else pin left + clamp width
  local col
  local need_w = width + bh
  local from_cursor_right = ui_cols - (screen_col - 1)
  if need_w <= from_cursor_right then
    col = 0
  else
    col = from_cursor_right - need_w                        -- NEGATIVE => shift window left
    if col < -(screen_col - 1) then                          -- would spill past the LEFT edge
      col = -(screen_col - 1)
      width = math.max(1, ui_cols - bh)
    end
  end
  return { anchor = anchor, row = row, col = col, width = width, height = height }
end
```

### The `render(state)` implementation (REPLACE the no-op stub)

Replace `local render = function(_state) end` with a real fn. It branches on
`state.open and #state.items > 0`:

```lua
-- ── S34: render(state) — create/show OR close the floating window ───────────────
-- Called by S31's open(items) and close() (on the nvim main loop via on_results — api-safe).
-- NEVER throws (pcall every nvim call; nvim_*_is_valid guards). Reads config FRESH.
-- Reuses state.menu_buf across opens (blink pattern); repositions an existing state.win
-- IN PLACE via nvim_win_set_config (no flicker); closes the window on the hide path.
local function ensure_menu_buf(state)
  if type(state.menu_buf) == "number" and vim.api.nvim_buf_is_valid(state.menu_buf) then
    return state.menu_buf
  end
  local ok, b = pcall(vim.api.nvim_create_buf, false, true) -- listed=false, scratch=true
  if not ok or type(b) ~= "number" then return nil end
  state.menu_buf = b
  return b
end

local function render_lines(state, width)
  -- S34: label-only lines (S35 widens to two-column + highlights). Pad to `width` so the
  -- window is a clean rectangle. NEVER throws (type-guard each item).
  local lines = {}
  for i = 1, #state.items do
    local it   = state.items[i]
    local label = (type(it) == "table" and type(it.label) == "string") and it.label or ""
    local lw   = vim.fn.strdisplaywidth(label)
    lines[i]   = label .. string.rep(" ", math.max(0, width - lw))
  end
  return lines
end

render = function(state)
  if state == nil then return end
  -- HIDE path: state closed (close(), or open({}) which set state.open=false) ⇒ close window.
  if not state.open or #state.items == 0 then
    if type(state.win) == "number" and vim.api.nvim_win_is_valid(state.win) then
      pcall(vim.api.nvim_win_close, state.win, true)
    end
    state.win = nil
    return
  end
  -- SHOW path: ensure scratch buffer (create once, reuse) + set lines + open/reposition window.
  local buf = ensure_menu_buf(state)
  if buf == nil then return end                            -- never throws (create failed → degrade)
  -- READ config FRESH (setup() may never have run — self-sufficient).
  local cfg = require("pi-editor")
  local menu_cfg = ((cfg.config or cfg.defaults) or {}).menu or {}
  local max_height = (type(menu_cfg.max_height) == "number" and menu_cfg.max_height > 0)
                       and menu_cfg.max_height or 12
  local border = (type(menu_cfg.border) == "string" or type(menu_cfg.border) == "table")
                  and menu_cfg.border or "rounded"
  local has_border = border ~= "none"
  local bh = has_border and 2 or 0
  -- LIVE screen reads (correct interactively; pinned to 1 headless → geometry is unit-tested
  -- via the pure compute_geometry, NOT through render). pcall (some embeds return err).
  local ui_lines, ui_cols = vim.o.lines, vim.o.columns
  local sr = (pcall(vim.fn.screenrow) and vim.fn.screenrow()) or 1
  local sc = (pcall(vim.fn.screencol) and vim.fn.screencol()) or 1
  local width  = compute_width(state.items, ui_cols, bh)
  local height = compute_height(#state.items, max_height)
  if height <= 0 then                                      -- defensive (items guard already)
    if type(state.win) == "number" and vim.api.nvim_win_is_valid(state.win) then
      pcall(vim.api.nvim_win_close, state.win, true)
    end
    state.win = nil
    return
  end
  local g = compute_geometry(sr, sc, ui_lines, ui_cols, width, height, max_height, border)
  -- set buffer content (toggle modifiable around set_lines — scratch buffers accept writes,
  -- but matching blink's pattern avoids surprises; plain nvim_buf_set_lines also works).
  pcall(vim.api.nvim_buf_set_lines, buf, 0, -1, false, render_lines(state, g.width))
  local win_cfg = {
    relative = "cursor", anchor = g.anchor, row = g.row, col = g.col,
    width = g.width, height = g.height, style = "minimal", border = border,
    focusable = false, noautocmd = true, zindex = 100,
  }
  if type(state.win) == "number" and vim.api.nvim_win_is_valid(state.win) then
    -- REPOSITION/RESIZE IN PLACE (no flicker) — blink pattern.
    pcall(vim.api.nvim_win_set_config, state.win, win_cfg)
  else
    local ok, w = pcall(vim.api.nvim_open_win, buf, false, win_cfg)
    if ok and type(w) == "number" then
      state.win = w
    else
      state.win = nil                                      -- create failed → degrade (next open retries)
      return
    end
  end
  -- window options (non-deprecated form): single-line entries, CJK-safe.
  pcall(vim.api.nvim_set_option_value, "wrap", false, { win = state.win })
end
```

> **Exposing pure helpers for tests:** add `M._compute_width = compute_width`,
> `M._compute_height = compute_height`, `M._compute_geometry = compute_geometry` at the end of
> the module (before `return M`) so the spec can assert them with synthetic inputs (the
> codebase convention — see how `coords_spec.lua` tests the pure `byte_to_utf16`/`utf16_to_byte`).
> These are INTERNAL test seams (underscore-prefixed); the public API (`open`/`close`/etc.)
> is unchanged.

### Implementation Tasks (ordered by dependencies)

```yaml
Task 1: READ plugin/lua/pi-editor/menu.lua + research/notes.md + the prior research files
  - READ FULLY: plugin/lua/pi-editor/menu.lua (the S31 module — understand state, render stub,
    open/close/reset/on_results, the forward-contract win/menu_buf fields).
  - READ: plan/001_c56962b4fa17/P2M8T21S34/research/notes.md (§3 geometry, §4 headless gotcha,
    §5 prototype-vs-S31 reconciliation, §6 anti-patterns).
  - READ: plan/001_c56962b4fa17/P2M5T1S1/research/positioning-math.md + live-verification.md
    (the source of the clamping algorithm + verified API behaviors).
  - NOTE: render is a LOCAL fn; open(items)/close()/reset() ALREADY call it. Do NOT rewrite
    the state layer — only EDIT render + ADD geometry helpers + manage win/menu_buf.

Task 2: ADD the 3 PURE geometry helpers to menu.lua (module-level locals, ABOVE render)
  - IMPLEMENT: compute_width(items, ui_cols, border_h_overhead), compute_height(n_items,
    max_height), compute_geometry(screen_row, screen_col, ui_lines, ui_cols, width, height,
    max_height, border) — copy-paste the reference implementations above.
  - VERIFY: compute_geometry returns the EXACT 7-case results in research/notes.md §3 /
    positioning-math.md (border="rounded" ⇒ bv=2,bh=2). CJK via strdisplaywidth (NOT #s).
  - EXPOSE: M._compute_width / M._compute_height / M._compute_geometry (test seams) before return M.

Task 3: IMPLEMENT render(state) — REPLACE the no-op stub
  - REPLACE: `local render = function(_state) end` with the show/hide implementation above
    (ensure_menu_buf + render_lines + live screen reads + compute_geometry + open-vs-set_config).
  - GUARD: `if state.open and #state.items > 0 then <show> else <hide> end` (open({}) ⇒ hide).
  - LIFECYCLE: reuse state.menu_buf (create once); reposition state.win in place via
    nvim_win_set_config when valid, else nvim_open_win; nvim_win_close on hide (keep buffer);
    state.win=nil on hide/create-fail.
  - NEVER THROWS: pcall every nvim call; nvim_buf_is_valid / nvim_win_is_valid guards;
    read config FRESH via require("pi-editor").
  - NAMING/PLACEMENT: keep render a LOCAL fn (S31's contract); helpers are module-level locals.

Task 4: SMOKE-VERIFY render in isolation (before touching specs)
  - WRITE /tmp/menu_s34_check.lua (a real FILE — NEVER heredoc into nvim stdin, see AGENTS.md):
    set rtp+=<repo>/plugin; require("pi-editor").setup({}); require("pi-editor.menu"); create a
    buffer + window; open a 3-item list; assert nvim_win_is_valid(state.win) (expose state via a
    test accessor if needed, OR assert via menu.is_open() + a window-count check); assert
    width==max label width; close; assert window closed. Run with:
    timeout 60 nvim --headless --clean -u NORC +"luafile /tmp/menu_s34_check.lua" +qa ; echo "exit=$?"

Task 5: UPDATE plugin/tests/menu_spec.lua — flip the "no window" assertion + add lifecycle cases
  - FLIP case (18): it currently asserts "S31 must NOT create a floating window (S34's job)" by
    counting windows before/after the full flow. S34 makes the flow CREATE a window. Change it to
    assert the menu's window IS created (a new float appears) and is closed on an empty result.
    Mirror the existing full-flow bootstrap (fake_bridge + buf + win + cursor).
  - ADD cases: (a) open(items) creates a valid floating window showing the labels; (b) close()
    closes it (nvim_win_is_valid==false); (c) a second open() reuses the SAME scratch buffer
    (nvim_buf_is_valid across close/reopen) and repositions (nvim_win_set_config path — assert
    the window is still valid + width tracks the new max label); (d) reset() closes the window +
    nils win/menu_buf; (e) open({}) does NOT create a window (close path). Assert width/height/
    anchor/validity ONLY (GOTCHA A: never assert cfg.relative=="cursor"; border is a table).
  - KEEP: all existing STATE cases (1-17) must still pass UNCHANGED (S34 is additive to the
    state layer — open/close/on_results/get_* behavior is identical).

Task 6: ADD plugin/tests/menu_geometry_spec.lua (recommended) — pure compute_* cases
  - IMPLEMENT: a plenary spec that feeds compute_width/compute_height/compute_geometry the
    synthetic inputs from the 7-case verified table (research/notes.md §3) and asserts the EXACT
    {anchor,row,col,width,height} results. Include: below-caret (case 1), above-caret (cases 2,3),
    right-edge shift-left (case 4), over-wide clamp (case 5), neither-fits height clamp (case 6),
    border="none" (case 7). Plus compute_width CJK (日本語=6) + empty items + over-screen clamp.
  - WHY: this is the DETERMINISTIC geometry proof (render integration can't test clamping
    headlessly — screenrow() is pinned to 1; research/notes.md §4).

Task 7: UPDATE plugin/tests/menu_smoke.lua — assert a window IS created in the real-bridge flow
  - The smoke currently drives the full flow + asserts menu STATE (is_open/get_items). S34 makes
    a window appear. ADD assertions (in CASE 1): after the non-empty reply, a NEW floating window
    exists beyond the test's own pi-prompt window (snapshot vim.api.nvim_list_wins() before/after);
    after the empty reply (CASE 2), that extra window is gone. Keep the STATE assertions.
  - KEEP the smoke plenary-free (it's the Level-2a gate; AGENTS.md: +"luafile …" +qa, NOT stdin).

Task 8: RUN the full validation suite (see Validation Loop) + fix until green
  - RUN: menu_spec.lua, menu_geometry_spec.lua, menu_smoke.lua (the changed/new files), THEN the
    sibling specs/smokes (completion_*, bridge_*, coords_*, init_*, ftplugin_*, shim_*, activate_*,
    jsonlreader_*) to confirm S34 broke NOTHING. All must be green (exit 0).
```

### Implementation Patterns & Key Details

```lua
-- PATTERN: read config FRESH (the codebase-wide rule — handshake async; tests mock after require;
-- /reload re-runs activate()). NEVER cache config at module load.
local cfg = require("pi-editor")
local menu_cfg = ((cfg.config or cfg.defaults) or {}).menu or {}

-- PATTERN: the no-flicker reposition (blink-verified). When the window already exists, update it
-- IN PLACE instead of close+reopen:
if vim.api.nvim_win_is_valid(state.win) then
  vim.api.nvim_win_set_config(state.win, win_cfg)   -- same window id, repositions + resizes
else
  state.win = vim.api.nvim_open_win(buf, false, win_cfg)  -- create (reuse buf)
end

-- PATTERN: reuse the scratch buffer across opens (blink-verified). Don't delete on close — only
-- reset()/teardown nils state.menu_buf. The window is closed (nvim_win_close) but the buffer
-- survives for the next open.

-- GOTCHA: relative="cursor" normalizes to relative="win" in get_config (don't assert "cursor").
-- GOTCHA: border in get_config is a TABLE (chars) even for border="rounded" (don't string-compare).
-- GOTCHA: screenrow()/screencol() == 1 headless → unit-test geometry via the PURE helpers.
-- GOTCHA: strdisplaywidth (NOT #s) for CJK/double-width (日本語 = 6 cells).
-- GOTCHA: open({}) sets state.open=false BEFORE render → render's HIDE path (no window). render
--         MUST guard on `state.open and #state.items > 0`.
-- GOTCHA (AGENTS.md): NEVER heredoc/pipe lua into nvim stdin (it HANGS). Write test snippets to a
--         real .lua file, then +"luafile <path>" +qa. Wrap nvim in `timeout`.
```

### Integration Points

```yaml
CONFIG (read-only, no change):
  - source: plugin/lua/pi-editor/init.lua M.defaults.menu { max_height=12, border="rounded" }
  - read in render FRESH: ((require("pi-editor").config or require("pi-editor").defaults) or {}).menu

STATE (S31, read-only contract):
  - state.win: integer|nil  — S34 OWNS this (nil until open; set by nvim_open_win; cleared on close/fail)
  - state.menu_buf: integer|nil — S34 OWNS this (lazy create; reused across opens; nil'd by reset())
  - state.items / state.selected / state.open: S31 OWNS these — S34 READS them in render ONLY

SEAM (no wiring change needed):
  - S31's open(items)/close()/reset() ALREADY call render(state). S21's activate() ALREADY calls
    menu.attach() (wires completion.on_results → menu.on_results). NO change to init.lua,
    completion.lua, or the ftplugin. S34 is CONTAINED to menu.lua + its tests.

TESTING HARNESS (reuse, no change):
  - Plenary spec: plugin/tests/minimal_init.lua (sets rtp to plugin/ + plenary).
  - Smoke: plenary-free, self-bootstraps rtp (the coords_smoke/menu_smoke pattern).
```

---

## Validation Loop

> **CRITICAL (AGENTS.md):** write every lua snippet to a real FILE then run
> `+"luafile <path>" +qa`. NEVER pipe a heredoc into nvim stdin (it HANGS). ALWAYS wrap nvim
> in `timeout`. Run from the `plugin/` directory.

### Level 1: Syntax & Style (after editing menu.lua)

```bash
cd /home/dustin/projects/pi-nvim-bridge/plugin
# luacheck/selene if configured; at minimum, a load-syntax check via a FILE (NOT stdin):
cat > /tmp/menu_loadcheck.lua <<'LUA'
local ok, err = loadfile("lua/pi-editor/menu.lua")
assert(ok, "menu.lua syntax error: " .. tostring(err))
print("MENU_LOAD_OK")
LUA
timeout 30 nvim --headless --clean -u NORC +"luafile /tmp/menu_loadcheck.lua" +qa ; echo "exit=$?"
# Expected: MENU_LOAD_OK, exit 0. (If selene/stylua config exists, also run `selene lua/pi-editor/menu.lua`
# and `stylua --check lua/pi-editor/menu.lua`; the repo's convention governs which.)
```

### Level 2: Unit Tests (plenary) — the pure geometry + window lifecycle proof

```bash
cd /home/dustin/projects/pi-nvim-bridge/plugin
# The pure geometry helpers (DETERMINISTIC — the 7-case verified table):
timeout 90 nvim --headless --clean -u tests/minimal_init.lua \
  -c 'lua require("plenary.busted").run("tests/menu_geometry_spec.lua")' ; echo "exit=$?"
# The window lifecycle + state (flipped case 18 + new cases):
timeout 90 nvim --headless --clean -u tests/minimal_init.lua \
  -c 'lua require("plenary.busted").run("tests/menu_spec.lua")' ; echo "exit=$?"
# Expected: both exit 0, all cases pass. Read the output + fix before proceeding.
```

### Level 3: Smoke (plenary-free, real bridge + real completion + real menu)

```bash
cd /home/dustin/projects/pi-nvim-bridge/plugin
timeout 60 nvim --headless --clean -u NORC +"luafile tests/menu_smoke.lua" +qa ; echo "exit=$?"
# Expected: SMOKE_PASS, exit 0. Asserts a window IS created on a non-empty getSuggestions reply
# and IS closed on an empty reply (in addition to the existing menu-STATE assertions).
```

### Level 4: Regression — S34 must break NOTHING in sibling modules

```bash
cd /home/dustin/projects/pi-nvim-bridge/plugin
# Run EVERY spec + smoke (S34 is contained to menu.lua, but confirm the completion/accept/tab
# flows — which call menu.open()/close() — still pass now that render creates a window):
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

### Level 4b: The rendered-isolation check (the "did render actually run?" proof)

```bash
# Write a REAL file (AGENTS.md: heredoc→file is fine; heredoc→nvim stdin is NOT). This proves
# render opens a window showing the labels, repositions in place, and closes — with no bridge.
cat > /tmp/menu_s34_e2e.lua <<'LUA'
local me = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(me, ":p:h")
vim.opt.runtimepath:append("/home/dustin/projects/pi-nvim-bridge/plugin")
local pi = require("pi-editor"); if pi.config == nil then pi.setup({}) end
local menu = require("pi-editor.menu")
local function wins() local n=0; for _ in ipairs(vim.api.nvim_list_wins()) do n=n+1 end; return n end
local buf = vim.api.nvim_create_buf(true,false)
local win = vim.api.nvim_open_win(buf, true, {relative="editor",row=1,col=1,width=60,height=8,border="none"})
vim.api.nvim_buf_set_lines(buf,0,-1,false,{"/mo"})
vim.wo[win].virtualedit="onemore"; vim.api.nvim_win_set_cursor(win,{1,3})
local before = wins()
menu.open({ {value="/model",label="/model"}, {value="/mood",label="/mood"}, {value="/more",label="/more"} })
vim.wait(100, function() end)
assert(menu.is_open(), "menu must be open")
local after = wins()
assert(after > before, "render must have created a floating window (before="..before.." after="..after..")")
assert(vim.api.nvim_win_is_valid(menu._state_win and menu._state_win() or 0) or after>before, "win valid")
menu.close()
vim.wait(50, function() end)
assert(not menu.is_open(), "menu closed")
local closed = wins()
-- the popup window is gone after close (the pi-prompt `win` remains):
print("MENU_S34_E2E_PASS before="..before.." open="..after.." closed="..closed)
vim.api.nvim_win_close(win,true); vim.api.nvim_buf_delete(buf,{force=true})
LUA
timeout 60 nvim --headless --clean -u NORC +"luafile /tmp/menu_s34_e2e.lua" +qa ; echo "exit=$?"
# NOTE: this reference reads menu's win via a `_state_win()` test accessor IF you add one; if not,
# assert purely via the window-count delta (before < after open, == before after close). The
# implementing agent may adapt this snippet (e.g. add `M._state = state` test seam mirroring how
# other modules expose internals to specs). Expected: MENU_S34_E2E_PASS, exit 0.
```

---

## Final Validation Checklist

### Technical Validation
- [ ] Level 1 load/syntax check passes (exit 0).
- [ ] `tests/menu_geometry_spec.lua` passes the 7-case verified table + CJK/empty/over-wide cases.
- [ ] `tests/menu_spec.lua` passes (case 18 flipped + new lifecycle cases; cases 1-17 unchanged).
- [ ] `tests/menu_smoke.lua` passes (SMOKE_PASS; asserts a window is created then closed).
- [ ] `/tmp/menu_s34_e2e.lua` prints MENU_S34_E2E_PASS (render opens/repositions/closes).
- [ ] Regression: every sibling spec/smoke green (no SPEC FAIL / SMOKE FAIL).

### Feature Validation
- [ ] `menu.open(items)` creates a valid floating window showing the item labels.
- [ ] `menu.close()` closes that window (`nvim_win_is_valid == false`); `state.win == nil`.
- [ ] A second `open()` REUSES the scratch buffer (`state.menu_buf` valid across close/reopen) and
      repositions the SAME window in place via `nvim_win_set_config` (no flicker).
- [ ] `open({})` does NOT create a window (render's hide path — state.open is false).
- [ ] `reset()` closes the window + nils `state.win`/`state.menu_buf`.
- [ ] `compute_geometry` returns the EXACT results in the verified 7-case table.
- [ ] The window is positioned relative to the cursor (below when room; above when not; shifted
      left / width-clamped near edges) — verified by the PURE helper tests (interactive correctness
      follows from using screenrow/screencol in render).
- [ ] Never throws (pcall-wrapped nvim; is_valid guards); a window-creation failure degrades
      silently (state stays open; next on_results retries).

### Code Quality Validation
- [ ] render is a LOCAL fn (S31's contract); geometry helpers are module-level locals; the public
      API (`open`/`close`/`reset`/`on_results`/`get_*`) is UNCHANGED.
- [ ] No new runtime dependencies (only `vim.api`/`vim.fn`/`vim.o`).
- [ ] Config read FRESH via `require("pi-editor")` (not cached at module load).
- [ ] Follows the codebase's Mode-A header + research-citation conventions (update menu.lua's
      header to note S34 implemented render; cite research/notes.md §3/§4).
- [ ] Test snippets are real files (AGENTS.md: never heredoc→nvim stdin); nvim wrapped in `timeout`.

### Documentation & Scope Discipline
- [ ] Did NOT implement S35 (two-column/highlights), S36 (navigation), S37 (auto-close) — render
      shows label-only lines; navigation/auto-close are future tasks.
- [ ] Did NOT modify `init.lua`, `completion.lua`, the ftplugin, or the bridge (S34 is contained).
- [ ] Did NOT touch PRD.md, tasks.json, prd_snapshot.md, or any plan/* PRP other than this one.

---

## Anti-Patterns to Avoid

- ❌ Don't rewrite the S31 state layer (open/close/reset/on_results/accessors) — only EDIT
  `render(state)` + ADD geometry helpers + manage `state.win`/`state.menu_buf`.
- ❌ Don't implement two-column rendering or highlights (that's S35) — label-only lines for S34.
- ❌ Don't implement navigation (next/prev/dismiss) or auto-close autocmds (S36/S37).
- ❌ Don't use `#s` for width — use `vim.fn.strdisplaywidth` (CJK/double-width = 2 cells).
- ❌ Don't assert `cfg.relative == "cursor"` or string-compare `cfg.border` in tests (GOTCHA A:
  relative normalizes to "win"; border is a table).
- ❌ Don't test clamped positioning through `render` (screenrow/screencol are pinned to 1
  headlessly) — test the PURE `compute_geometry` with synthetic inputs; test render's
  integration via window validity/width/height/anchor only.
- ❌ Don't close+reopen the window on every `on_results` (flicker) — reposition IN PLACE via
  `nvim_win_set_config` when the window already exists.
- ❌ Don't delete the scratch buffer on close — reuse it (blink pattern); only `reset()` nils it.
- ❌ Don't let `render` throw (per-keystroke + autocmd contract) — pcall every nvim call.
- ❌ Don't pipe a heredoc into nvim stdin (it HANGS — AGENTS.md HARD RULE). Write test lua to a
  real file, then `+"luafile <path>" +qa`; wrap nvim in `timeout`.

---

## Confidence Score: 9/10

**Why high:** The clamping algorithm + `nvim_open_win`/`nvim_win_set_config` config + window
lifecycle are all **live-verified** (the P2M5T1S1 prototype ran `MENU_VERIFY_PASS 0`; blink.cmp
cross-checks the lifecycle; the help-doc behaviors are confirmed). The seam (`render(state)`) is
a single local function already called by S31's `open()`/`close()` — S34 is purely additive to a
known-good state layer. The 7-case geometry table is a deterministic test oracle.

**Residual risk (the 1 point):** the headless `screenrow()`/`screencol()` quirk means interactive
positioning is verified by construction (the code calls the right fns) rather than by an
automated interactive assertion; the pure-function split mitigates this for the logic. Also, the
exact internal-test-seam choice (`M._state_win()` vs window-count-delta vs `M._compute_*`) is left
to the implementer's judgment within the documented convention — both paths are shown in Level 4b.