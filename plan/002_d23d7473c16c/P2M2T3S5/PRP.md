# PRP — P2.M2.T3.S5: Menu visual_cue for shell context (gutter `$` prefix)

> Component B (`pi-bridge.nvim`), Phase 6 shell-completion (PRD §17.9). This is an
> **additive rendering concern** inside `menu.lua` + a one-arg threading through the
> existing `on_results` seam. No new modules, no bridge changes, no daemon work.

---

## Goal

**Feature Goal**: When the completion menu is populated for a **shell-context** line
(`!`/`!!` bash mode — `completion_context == "shell"`), the floating menu renders a
**visual cue** so the user sees they are completing a shell command (mirroring pi's TUI
border recoloring on `isBashMode`). Default cue = a **`$ ` gutter prefix** on every menu
item. Alternative cues (`"border"` = a distinct border tint, `"off"` = disabled) round out
the config enum `setup({ shell = { visual_cue = "gutter"|"border"|"off" } })`.

**Deliverable**:
1. `menu.lua` learns the **completion context** (shell vs pi) and renders the cue
   accordingly — gutter prepended to each line, OR a distinct floating-win border, OR none.
2. `completion.lua` threads that context through the existing `on_results(buf, items, prefix)`
   seam as an optional 4th argument (backward-compatible).
3. Two default highlight groups (`PiBridgeShellGutter`, `PiBridgeShellBorder`) defined lazily
   with `default = true` so user themes win.
4. A plenary spec extension + a plenary-free smoke test proving the cue.

**Success Definition**: In a pi-launched `nvim` editing a `!`-prefixed prompt, the completion
menu shows a `$ ` prefix on each shell candidate (default), the menu **width grows by 2** to
accommodate it, the cue is **absent** for `/cmd` and `@file` completions, and switching
`shell.visual_cue` to `"off"`/`"border"` behaves as documented. No regression in the existing
`menu_spec`/`completion_spec` suites. The plugin stays dormant in every ordinary nvim session.

---

## User Persona

**Target User**: a pi user who edits prompts in Neovim (pi's `$EDITOR`) and types `!`/`!!`
shell commands (pi's bash mode), using the new shell-completion daemon (P2.M1/P2.M2.T3/T4).

**Use Case**: User types `!git ch⇥` in the pi-prompt buffer; the floating menu shows shell
candidates with a `$ ` gutter, signalling "this is a shell command you're completing", not a
pi slash command or file mention.

**Pain Points Addressed**: Without a cue, shell candidates are visually indistinguishable from
pi slash/path completions (same `Pmenu` styling), so a user can't tell at a glance they're in
bash mode. PRD §17.9 calls this out explicitly.

---

## Why

- **UX parity with pi's TUI**: pi recolors the editor border on `isBashMode`
  (`interactive-mode.ts:2583`); the external editor has no border recolor, so the menu itself
  must carry the signal (PRD §17.9).
- **Zero new dependencies / seams**: reuses the existing floating menu, the existing
  `on_results` seam, the existing `apply_highlights` 3-layer pipeline, and the existing
  shell-routing already landed in P2.M2.T3.S1–S4. This task is purely the **rendering** of a
  cue the routing already enables.
- **Cheap + additive**: ~1 module + ~4 one-arg call-site edits + 2 default hl groups. Does not
  touch the bridge, the daemon, or accept logic.

---

## What

### Visible behavior
- **Default (`visual_cue = "gutter"`)**: when the menu is showing **shell** candidates, every
  line is prefixed with `$ ` (dollar + space, 2 display cells). The menu width grows by 2 to
  fit it. Non-shell contexts (slash/path) render exactly as today (no prefix).
- **`visual_cue = "off"`**: never render a cue (shell candidates look like any other).
- **`visual_cue = "border"`**: render a **distinct floating-window border color** (via
  `winhighlight FloatBorder:PiBridgeShellBorder`) instead of the gutter.
- CJK/double-width safe (the gutter is ASCII; existing label/desc math already uses
  `strdisplaywidth`).
- Cue state is **always coupled to the rendered payload** (set via the `on_results` seam), so a
  stale menu never shows the wrong cue.

### Success Criteria
- [ ] `menu.on_results(buf, items, prefix, "shell")` → `open` → each rendered line starts with
      `$ ` and the popup width == pre-change width + 2.
- [ ] `menu.on_results(buf, items, prefix, "slash")` (or nil) → **no** gutter (identical to today).
- [ ] `visual_cue = "off"` → no gutter even for shell context.
- [ ] `visual_cue = "border"` + shell context → the floating win's `winhighlight` maps
      `FloatBorder:PiBridgeShellBorder` (gutter off).
- [ ] `PiBridgeShellGutter` / `PiBridgeShellBorder` default highlights exist (linked), but a
      user `:hi PiBridgeShellGutter …` overrides them (`default = true`).
- [ ] `M._compute_width(items, ui_cols, bh, gutter_w)` pure helper: with `gutter_w=2` the
      result is exactly `+2` vs `gutter_w=0` for the same items (unit-tested).
- [ ] Existing `menu_spec.lua` + `completion_spec.lua` stay green (no seam breakage — 4th arg
      is optional).

---

## All Needed Context

### Context Completeness Check
_Pass_: an implementer who knows nothing about this repo can implement this from the file:line
references below + the PRD §17.9 excerpt. No external libraries beyond Neovim 0.11+ built-ins
(`vim.api`, `vim.fn`, `vim.uv`-free here — menu only touches `vim.api`/`vim.fn`/`vim.o`).

### Documentation & References

```yaml
# MUST READ — the spec slice this task implements
- url: PRD.md §17.9 (Trigger & UX parity with the TUI) — see selected_prd_content
  why: defines visual_cue = "gutter"|"border"|"off", default "gutter", the $ gutter-on-each-item
        behavior, and the bashMode-border-recolor motivation.
  critical: "gutter" is the default; "border" is a distinct border color; the cue mirrors
        pi's isBashMode TUI border recolor.

# The render pipeline to modify (read fully before editing)
- file: lua/pi-bridge/menu.lua
  why: this is where the cue is rendered. Single module; ~660 lines; all targets listed below.
  pattern: render(state) orchestrates compute_width → render_lines → apply_highlights → nvim_open_win.
  gotcha: PmenuSel is applied LAST (LAST-WINS, neovim#8449) — apply the gutter highlight BEFORE it
          so the selected row's `$` stays visible (blends into the selection bg). Never apply a
          highlight after PmenuSel on the same range.

# The seam to thread (4 call sites)
- file: lua/pi-bridge/completion.lua
  why: completion owns on_results and already computes ctx = completion_context(...).
  pattern: on_results(buf, items, prefix) is called from 4 sites; add an optional 4th `context` arg.
  gotcha: the shell cb (L438) runs in libuv FAST context and already vim.schedule's the on_results
          hop (E5560) — threading a string arg through it is free; do NOT add another schedule.

# The config the cue reads (shell.visual_cue) — NOT yet formalized
- file: lua/pi-bridge/init.lua
  why: M.config + M.defaults live here. There is NO `shell` config block yet (T6.S1, Planned).
  pattern: read config DEFENSIVELY (shell.lua L340 already does: `local cfg = (pi.config and pi.config.shell) or {}`).
  gotcha: do NOT add the `shell = {}` defaults block here (that is T6.S1's job, later). S5 reads
          config.shell.visual_cue with a `"gutter"` fallback so it works before AND after T6.S1.

# The routing that already classifies shell context (proves the cue is reachable)
- file: lua/pi-bridge/completion.lua  (completion_context, ~L444; do_shell_fetch, ~L370)
  why: confirms "shell" is returned iff line 1 begins with "!" and routed to the daemon.
  pattern: completion_context returns "shell"|"slash"|"path"|nil; do_shell_fetch is the shell fetch path.

# Test patterns to extend
- file: tests/menu_spec.lua
  why: the plenary spec for the menu — exact helpers to reuse (with_cursor_window, hl_groups_on_row, M._compute_width).
  pattern: open items, assert on menu._state.menu_buf lines + namespace highlights; pure helpers via M._ seam.
- file: tests/menu_shell_visual_cue_smoke.lua  (NEW — create this)
  why: plenary-free smoke (run via -u NORC +"luafile …" +qa); proves the gutter end-to-end in a real nvim.

# How to run tests (verified commands — AGENTS.md)
- docfile: AGENTS.md
  section: "Test runner" — plenary + smoke invocation forms + the ⛔ heredoc-into-nvim rule.
```

### Current codebase tree (relevant slice)

```bash
lua/pi-bridge/
├── menu.lua          # ← TARGET: render pipeline + on_results seam consumer
├── completion.lua    # ← TARGET: thread `context` through 4 on_results call sites
├── init.lua          # ← READ ONLY (no shell block yet; T6.S1 owns it). Cue reads config.shell.visual_cue defensively.
└── shell.lua         # context (already Complete): complete_current, resolve_shell — UNCHANGED here
tests/
├── menu_spec.lua                 # ← EXTEND with gutter/border/off cases
├── completion_spec.lua           # green-after guard (optional context arg is back-compat)
└── menu_shell_visual_cue_smoke.lua   # ← NEW plenary-free smoke
```

### Desired codebase tree with files to be added/changed

```bash
lua/pi-bridge/menu.lua                     # MODIFY — gutter+border+off rendering, state.context, default hl groups
lua/pi-bridge/completion.lua               # MODIFY — thread `context` (4th arg) into 4 on_results sites
tests/menu_spec.lua                        # MODIFY — add visual_cue spec block (gutter/border/off/non-shell/pure-helper)
tests/menu_shell_visual_cue_smoke.lua      # NEW    — plenary-free end-to-end smoke
```

### Known Gotchas of our codebase & Library Quirks

```lua
-- CRITICAL: AGENTS.md ⛔ HARD RULE — NEVER pipe a heredoc into nvim stdin (it HANGS).
--   Write test lua to a FILE, run via +"luafile <file>" +qa. Wrap every nvim call in `timeout`.

-- PmenuSel is LAST-WINS within a namespace (neovim#8449; menu.lua apply_highlights L408–L411).
--   Apply PiBridgeShellGutter BEFORE PmenuSel so the selected row shows the `$` (blends into
--   the selection bg). Do NOT apply any highlight AFTER PmenuSel on the same range.

-- The shell cb (completion.lua L438) runs in libuv FAST context — it ALREADY vim.schedule's
--   the on_results hop (E5560 guard). Threading the 4th `context` string arg costs nothing;
--   do NOT add a second schedule or touch fast-context safety.

-- `config.shell` is nil until T6.S1 lands (later task). READ DEFENSIVELY:
--   local cue = (pi.config and pi.config.shell and pi.config.shell.visual_cue) or "gutter"
--   (mirror shell.lua L340's `(pi.config and pi.config.shell) or {}` pattern).

-- nvim default highlights must use default = true so a user's :hi / theme wins:
--   pcall(vim.api.nvim_set_hl, 0, "PiBridgeShellGutter", { link = "SpecialKey", default = true })

-- No floating-win winhighlight exists today (grep winhighlight menu.lua = none). Border mode
--   ADDS winhighlight = "FloatBorder:PiBridgeShellBorder" to win_cfg (both open + set_config paths).

-- strdisplaywidth("$ ") == 2 always (ASCII); no CJK math needed for the gutter. Existing
--   label/desc math in render_lines/column_metrics already uses strdisplaywidth.
```

---

## Implementation Blueprint

### Data models and structure

Add a `context` field to the menu's singleton state and extend the `on_results` seam with an
optional 4th argument. The cue config (`shell.visual_cue`) is read fresh at render time (never
cached) — matching the menu's existing `menu_cfg` read pattern.

```lua
-- menu.lua — state gains a context field (the ONLY source of truth for the cue at render time)
---@class pi-bridge.MenuState
---@field context string|nil  # NEW — "shell" renders the cue; slash/path/nil render normally.
--   Set by on_results (coupled to the payload); nil'd by close()/reset() for hygiene.
local state = {
  -- …existing fields…
  context = nil,   -- NEW
}

-- The seam (backward-compatible — 4th arg optional; nil = pi mode = today's behavior).
---@param context string|nil "shell"|"slash"|"path"|nil — "shell" activates the visual cue.
function M.on_results(buf, items, prefix, context)  -- context is NEW (optional)
  -- …existing wipe/items guards…
  state.context = (type(context) == "string") and context or nil  -- store; nil for unknown
  -- …existing empty→close / non-empty→store+open…
end
```

### Implementation Tasks (ordered by dependencies)

```yaml
Task 1: MODIFY menu.lua — add state.context + thread the on_results seam
  - IMPLEMENT: `state.context = nil` (MenuState table, ~L151) + the @field doc.
  - IMPLEMENT: `M.on_results(buf, items, prefix, context)` (~L512) stores
      `state.context = (type(context)=="string") and context or nil` BEFORE the empty/open routing.
  - MODIFY: `M.close()` (~L568) and `M.reset()` (~L654) to set `state.context = nil` (hygiene).
  - WHY FIRST: the render pipeline (Tasks 2–4) reads state.context; the seam (Task 6) writes it.
  - GOTCHA: do NOT reset context in `M.open()` (on_results already set it before calling open).

Task 2: MODIFY menu.lua — gutter constants + the pure width helper
  - ADD (module locals near DESC_GAP, ~L169):
      local GUTTER = "$ "        -- the 2-cell prefix prepended to each shell line
      local GUTTER_W = 2         -- vim.fn.strdisplaywidth(GUTTER)
  - MODIFY `compute_width(items, ui_cols, border_h_overhead)` (~L251) → add optional 4th param
      `gutter_w` (default 0): `w = <existing two-column/label-only math> + (gutter_w or 0)`
      BEFORE the `math.max(1, math.min(w, ui_cols - border_h_overhead))` clamp.
  - NAMING: gutter_w (snake_case); GUTTER/GUTTER_W (module-local UPPER constants, mirror DESC_GAP).
  - BACK-COMPAT: existing 3-arg callers + the `M._compute_width` test-seam stay green (gutter_w defaults to 0).

Task 3: MODIFY menu.lua — render_lines prepends the gutter
  - MODIFY `render_lines(state, label_w, desc_w)` (~L352) → add a `gutter` bool param.
      When `gutter` true, each row starts with GUTTER before the (already right-padded) label column,
      and `total` grows by GUTTER_W so the clean-rectangle padding is correct.
      Pseudocode: `row = (gutter and GUTTER or "") .. <label col> .. <gap?> .. <desc col?>`
  - GOTCHA: the label column width math (label_w) is UNCHANGED — the gutter is a fixed prefix added
      once per row, so per-item label/desc padding is unaffected; only `total` and the row prefix change.
  - NEVER THROWS: existing type-guards + :gsub sanitize remain; GUTTER is a literal string.

Task 4: MODIFY menu.lua — apply_highlights paints the gutter; default hl groups defined lazily
  - ADD a lazy default-highlight definer (call once at top of apply_highlights, or module-load):
      pcall(vim.api.nvim_set_hl, 0, "PiBridgeShellGutter", { link = "SpecialKey", default = true })
  - MODIFY `apply_highlights(state, buf, label_w, desc_w)` (~L387) → add a `gutter` bool param.
      When true, AFTER the base `Pmenu` whole-line loop (b) and the desc `Comment` loop (c), and
      BEFORE the `PmenuSel` selected row (d), add per row i:
        pcall(nvim_buf_add_highlight, buf, ns, "PiBridgeShellGutter", i-1, 0, GUTTER_W)
      (So: Pmenu → Comment → PiBridgeShellGutter → PmenuSel last. PmenuSel wins on the selected row,
       which is correct — the `$` char remains, tinted by PmenuSel there.)
  - GOTCHA: order is load-bearing (LAST-WINS). PiBridgeShellGutter MUST precede PmenuSel.

Task 5: MODIFY menu.lua — render() decides the cue + threads it; border mode sets winhighlight
  - IN `render(state)` (~L419), after reading `menu_cfg`, ALSO read the cue defensively:
      local shell_cfg = (cfg.config and cfg.config.shell) or {}
      local cue = (type(shell_cfg.visual_cue) == "string" and shell_cfg.visual_cue) or "gutter"
      local is_shell = state.context == "shell"
      local gutter_on = is_shell and cue == "gutter"
  - THREAD gutter_on into: `compute_width(items, ui_cols, bh, gutter_on and GUTTER_W or 0)`,
      `render_lines(state, label_w, desc_w, gutter_on)`, `apply_highlights(state, buf, label_w, desc_w, gutter_on)`.
  - BORDER MODE: when `is_shell and cue == "border"`, add to the `win_cfg` table (~L486 open path AND
      ~L494 set_config path): `winhighlight = "FloatBorder:PiBridgeShellBorder"`, and define the
      default once: `pcall(vim.api.nvim_set_hl, 0, "PiBridgeShellBorder", { link = "WarningMsg", default = true })`.
      When NOT border-shell, do NOT set winhighlight (leave today's behavior).
  - GOTCHA: both nvim_open_win and nvim_win_set_config honor `winhighlight`; setting it on set_config
      re-applies in place (no flicker) — mirror the existing in-place reposition pattern.

Task 6: MODIFY completion.lua — thread `context` into the 4 on_results call sites
  - L438 (do_shell_fetch cb): `pcall(M.on_results, buf, its, pfx, "shell")` (inside the existing vim.schedule).
  - L581 (do_refresh bridge cb): `pcall(M.on_results, buf, items, prefix, ctx)` — `ctx` is in scope (L520).
  - L531 (do_refresh ctx==nil close): `pcall(M.on_results, buf, {}, "", nil)` (explicit nil; non-shell).
  - L662 (_route_or_accept router — slash/file Tab): `pcall(M.on_results, buf, items, prefix, nil)`
      (shell Tab routes to do_shell_fetch before reaching here; this path is never shell).
  - GOTCHA: the 4th arg is OPTIONAL + defaults to nil — the menu treats anything != "shell" as
      "render normally". This keeps the change back-compatible if a future caller omits it.

Task 7: EXTEND tests/menu_spec.lua — visual_cue spec block
  - ADD a `describe("shell visual_cue", …)` block REUSING existing helpers (with_cursor_window, hl_groups_on_row).
  - CASES:
      (a) gutter default: open shell-context items → each line starts with "$ "; win width == old+2;
          PiBridgeShellGutter extmark present on each row.
      (b) non-shell (slash): open with context "slash"/nil → NO "$ " prefix; width == old.
      (c) visual_cue "off": stub config.shell.visual_cue="off" + context "shell" → NO gutter.
      (d) visual_cue "border": context "shell" + cue "border" → win winhighlight contains FloatBorder:PiBridgeShellBorder; NO gutter.
      (e) pure helper: M._compute_width(items, ui_cols, bh, 2) == M._compute_width(items, ui_cols, bh, 0) + 2.
  - HOW TO SET CONTEXT WITHOUT A DAEMON: call `menu.on_results(buf, items, prefix, "shell")` directly
      (the spec already drives the menu via menu.open/on_results; this is the established unit-test seam).
  - NAMING: `it("shell context renders a $ gutter prefix …")`, etc. (codebase `it("…")` convention).

Task 8: CREATE tests/menu_shell_visual_cue_smoke.lua — plenary-free end-to-end smoke
  - IMPLEMENT: a standalone lua (NO plenary) that: sets up a fake buffer, sets `vim.env.PI_NVIM_BRIDGE`-free
      state, calls `require("pi-bridge").setup({ shell = { visual_cue = "gutter" } })`, drives
      `menu.on_results(buf, items, prefix, "shell")`, asserts `menu._state.menu_buf` line 1 starts with "$ ",
      then `on_results(buf, items, prefix, "slash")` asserts NO prefix. Print "PASS"/"FAIL" + os.exit.
  - FOLLOW pattern: tests/menu_smoke.lua (the existing plenary-free menu smoke) for the open/assert shape.
  - RUN via: `timeout 60 nvim --headless --clean -u NORC +"luafile tests/menu_shell_visual_cue_smoke.lua" +qa`
  - GOTCHA: write the file with the `write` tool; NEVER pipe a heredoc into nvim (AGENTS.md ⛔).
```

### Implementation Patterns & Key Details

```lua
-- (1) render() decides the cue ONCE, reading config fresh (the menu_cfg pattern, ~L432):
local cfg = require("pi-bridge")
local menu_cfg = ((cfg.config or cfg.defaults) or {}).menu or {}
local shell_cfg = (cfg.config and cfg.config.shell) or {}                 -- DEFENSIVE (T6.S1 not yet landed)
local cue = (type(shell_cfg.visual_cue)=="string" and shell_cfg.visual_cue) or "gutter"
local is_shell = state.context == "shell"
local gutter_on = is_shell and cue == "gutter"
local width = compute_width(state.items, ui_cols, bh, gutter_on and GUTTER_W or 0)
-- …existing compute_geometry split into label_w/desc_w from g.width (unchanged)…
local lines = render_lines(state, label_w, desc_w, gutter_on)
apply_highlights(state, buf, label_w, desc_w, gutter_on)

-- (2) render_lines: the gutter is a fixed 2-cell prefix; only `total` + the row prefix change:
local function render_lines(state, label_w, desc_w, gutter)
  local total = (gutter and GUTTER_W or 0) + label_w + (desc_w>0 and DESC_GAP or 0) + desc_w
  for i = 1, #state.items do
    local labelcol = <existing right-padded label + optional gap+desc>   -- UNCHANGED
    local row = (gutter and GUTTER or "") .. labelcol
    -- …existing clean-rectangle pad to `total`…
  end
end

-- (3) apply_highlights order (PmenuSel LAST-WINS — gutter BEFORE it):
--   (a) clear  (b) Pmenu whole-line  (c) Comment desc  (c.5) PiBridgeShellGutter [0,GUTTER_W)  (d) PmenuSel
if gutter then
  for i = 1, n do pcall(vim.api.nvim_buf_add_highlight, buf, ns, "PiBridgeShellGutter", i-1, 0, GUTTER_W) end
end
-- …then the existing PmenuSel block…

-- (4) border mode — winhighlight on BOTH the open + set_config win_cfg:
if is_shell and cue == "border" then
  pcall(vim.api.nvim_set_hl, 0, "PiBridgeShellBorder", { link = "WarningMsg", default = true })
  win_cfg.winhighlight = "FloatBorder:PiBridgeShellBorder"
end
```

### Integration Points

```yaml
CONFIG:
  - add to: NOTHING in init.lua (T6.S1 owns the formal `shell = {}` block, later).
  - pattern: menu.lua READS `config.shell.visual_cue` DEFENSIVELY with a "gutter" fallback
      (so S5 works before AND after T6.S1). T6.S1 will later document the option in defaults.

HIGHLIGHTS:
  - add to: NOTHING (no hl module exists yet). Define LAZILY on first render with default=true:
      PiBridgeShellGutter → link SpecialKey ; PiBridgeShellBorder → link WarningMsg
  - pattern: pcall(vim.api.nvim_set_hl, 0, NAME, { link = LINK, default = true }) — standard nvim plugin form.

SEAM:
  - change: completion.on_results seam gains an OPTIONAL 4th `context` arg (back-compatible).
  - callers: 4 sites in completion.lua (L438/L531/L581/L662) — listed in Task 6.
  - preserve: every other behavior (supersession, debounce, fast-context safety, degrade paths).
```

---

## Validation Loop

> Every nvim invocation MUST be wrapped in `timeout` and use `+"luafile <file>" +qa` — NEVER pipe a
> heredoc into nvim stdin (AGENTS.md ⛔ HARD RULE).

### Level 1: Syntax & Style (Immediate Feedback)

```bash
# Run after editing menu.lua / completion.lua — fix before proceeding.
selene lua/pi-bridge/menu.lua lua/pi-bridge/completion.lua tests/menu_spec.lua   # lint (PRD §14)
stylua --check lua/pi-bridge/menu.lua lua/pi-bridge/completion.lua tests/         # format check
# auto-fix if needed:
stylua lua/pi-bridge/menu.lua lua/pi-bridge/completion.lua tests/
# Expected: zero errors. If any, READ the output and fix before proceeding.
```

### Level 2: Unit Tests (Component Validation)

```bash
# The menu spec (extended in Task 7) — PRIMARY validation.
timeout 90 nvim --headless --clean -u tests/minimal_init.lua \
  -c 'lua require("plenary.busted").run("tests/menu_spec.lua")'

# Regression guard: completion spec must stay green (the 4th-arg seam is back-compatible).
timeout 90 nvim --headless --clean -u tests/minimal_init.lua \
  -c 'lua require("plenary.busted").run("tests/completion_spec.lua")'

# If you touched shell routing at all, also run the shell suite (you should NOT need to):
# timeout 90 nvim --headless --clean -u tests/minimal_init.lua \
#   -c 'lua require("plenary.busted").run("tests/shell_complete_current_spec.lua")'
# Expected: all pass. If failing, debug root cause — the 4th arg must be optional.
```

### Level 3: Smoke / Integration (End-to-End)

```bash
# The NEW plenary-free smoke (Task 8) — proves the gutter in a real headless nvim.
timeout 60 nvim --headless --clean -u NORC +"luafile tests/menu_shell_visual_cue_smoke.lua" +qa
echo "exit=$?"   # 0 = PASS

# Existing menu smoke (regression — must still pass).
timeout 60 nvim --headless --clean -u NORC +"luafile tests/menu_smoke.lua" +qa
echo "exit=$?"
# Expected: exit 0 / "PASS" for both.
```

### Level 4: Domain-Specific Validation (manual/scripted visual proof)

```bash
# Optional — a real-pi visual proof (only if a pi session is available). Type a `!` line in the
# pi-launched editor and confirm the `$ ` gutter appears; type `/mod` and confirm NO gutter.
# This is a manual UX check, not an automated gate. The Level 2/3 gates above are the contract.
```

---

## Final Validation Checklist

### Technical Validation
- [ ] Level 1 passed: `selene` + `stylua --check` clean on changed files.
- [ ] Level 2 passed: `tests/menu_spec.lua` green (incl. the new visual_cue block).
- [ ] Level 2 passed: `tests/completion_spec.lua` green (no seam regression).
- [ ] Level 3 passed: `tests/menu_shell_visual_cue_smoke.lua` exits 0.
- [ ] Level 3 passed: `tests/menu_smoke.lua` still exits 0 (regression).

### Feature Validation
- [ ] Shell-context (`context=="shell"`) menu items render a `$ ` prefix; width == old + 2.
- [ ] Non-shell contexts (`slash`/`path`/nil) render NO prefix (identical to pre-change).
- [ ] `visual_cue = "off"` → no gutter for shell context.
- [ ] `visual_cue = "border"` → floating win `winhighlight` maps `FloatBorder:PiBridgeShellBorder`.
- [ ] `PiBridgeShellGutter` / `PiBridgeShellBorder` default highlights exist but are user-overridable.
- [ ] `M._compute_width(items, ui_cols, bh, 2) == …(…,0) + 2` (pure-helper unit test).

### Code Quality Validation
- [ ] Follows existing menu.lua conventions (module-local UPPER constants, `_` test-seam exports,
      pcall every nvim call, read config fresh, never-throws guards).
- [ ] The 4th `on_results` arg is OPTIONAL (back-compatible — no caller forced to pass it).
- [ ] Cue state is coupled to the payload (set in `on_results`, not a separate setter) — no stale-gutter race.
- [ ] No new modules, no bridge changes, no daemon changes — purely additive rendering.

### Documentation
- [ ] `state.context` field documented (`@field context string|nil`).
- [ ] The cue's config knob (`shell.visual_cue`) is consumed defensively; T6.S1 will document it in
      `init.lua` defaults + `doc/pi-bridge-shell.txt` (NOT this task's deliverable — note in code).

---

## Anti-Patterns to Avoid

- ❌ Don't re-query `state.buf` / cursor in the menu to *derive* shell context (the menu's design
  explicitly forbids it — staleness false-negative race; menu.lua header L43–L50). Thread the context
  via the `on_results` payload instead.
- ❌ Don't apply the gutter highlight AFTER `PmenuSel` (LAST-WINS — it would hide the `$` on the
  selected row's range; actually it would override PmenuSel there, which is worse). Apply it BEFORE.
- ❌ Don't add a `shell = {}` defaults block to `init.lua` (that's T6.S1's scope, later). Read defensively.
- ❌ Don't change `compute_width`'s existing 3-arg behavior (breaks `M._compute_width` unit tests) —
  add `gutter_w` as an OPTIONAL 4th param defaulting to 0.
- ❌ Don't touch the bridge, the shell daemon, or accept logic — this task is rendering-only.
- ❌ Don't pipe a heredoc into `nvim` (AGENTS.md ⛔ HARD RULE — it hangs the session). Write test lua
  to a file, run via `+"luafile <file>" +qa`, always wrapped in `timeout`.

---

## Confidence Score

**9/10** — one-pass success likelihood. The task is a small, additive rendering change in a single
well-understood module (`menu.lua`) plus a back-compatible one-arg threading through 4 documented call
sites. All targets have exact file:line references; the seam decision (extend `on_results`) is justified
against the codebase's own blink.cmp-model docs and avoids the menu's documented staleness anti-pattern.
The −1 is for the `"border"` mode (winhighlight plumbing has minor cross-version nuance) — but it is
optional/secondary and the `"gutter"` default + `"off"` are the core, low-risk deliverables.