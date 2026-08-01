# Research Notes — P2.M2.T3.S5: Menu visual_cue for shell context (gutter `$` prefix)

## Task scope (from plan_status + PRD §17.9)
When `completion_context == "shell"` (a `!`/`!!` bash-mode line), the floating menu shows a
visual cue so the user sees they are completing a shell command (mirrors pi's TUI border
recoloring on `isBashMode`). Configurable:
`setup({ shell = { visual_cue = "gutter" | "border" | "off" } })`, **default `"gutter"`**
= a `$ ` prefix on each menu item. This task's headline deliverable is the **gutter** path;
`"off"` (disable) and `"border"` (distinct border color) round out the config enum.

## The seam decision (the crux)
The menu's result-consumer seam is `on_results(buf, items, prefix)` and it does NOT carry the
completion context ("shell" vs "slash"/"path"/nil). Three ways to give the menu that knowledge:

- **(A) Thread an optional `context` arg through `on_results`.** `on_results(buf, items, prefix, context)`.
  Menu stores `state.context`. Backward-compatible (4th arg optional → nil = pi mode).
  Most robust: context is always coupled to the exact payload being rendered (no stale-gutter race).
- **(B) `menu.set_context(ctx)` mutator** called by completion before routing. Separate call to forget.
- **(C) Menu re-reads `state.buf` line 1.** Rejected: the menu's design explicitly does NOT re-query
  buffer/cursor (staleness false-negative race, see menu.lua header L43–L50); duplicates `completion_context`.

**CHOSEN: (A).** It aligns with the blink.cmp `list.lua` model the menu already cites (menu.lua L30
documents blink's `context` field) and keeps the cue coupled to the rendered payload.

## Exact call sites to thread (completion.lua)
`grep "M.on_results(" lua/pi-bridge/completion.lua` → 4 invocations:
- **L438** — `do_shell_fetch` cb (the shell daemon path). Pass **`"shell"`**.
- **L581** — `do_refresh` bridge cb. Pass **`ctx`** (in scope at L520; "slash"/"path").
- **L531** — `do_refresh` ctx==nil close. Pass **`nil`**.
- **L662** — `_route_or_accept` router (slash/file Tab path; shell Tab routes to `do_shell_fetch` first).
  Pass **`nil`** (non-shell is all the gutter distinguishes).

The gutter logic is simply `state.context == "shell" ? gutter : none`, so any non-"shell"
value (slash/path/nil) renders normally.

## menu.lua surface (the render pipeline to touch)
- `local state = {…}` (L151) → add `context = nil`.
- `column_metrics(items)` (L188) — PURE max label/desc widths. Unchanged (gutter is a fixed-width prefix).
- `compute_width(items, ui_cols, border_h_overhead)` (L251) — PURE, exposed `M._compute_width`.
  Add an optional 4th param `gutter_w` (default 0) so existing 3-arg unit tests stay green;
  the gutter adds 2 cells to the requested width before screen-clamp.
- `render_lines(state, label_w, desc_w)` (L352) — builds the padded rows. Add a `gutter` bool;
  when true prepend `GUTTER = "$ "` (2 cells) before the label, adjust total/padding.
- `apply_highlights(state, buf, label_w, desc_w)` (L387) — 3-layer highlights (Pmenu → Comment desc →
  PmenuSel last). Apply a `PiBridgeShellGutter` highlight on range `[0, GUTTER_W)` per row BEFORE PmenuSel
  (so the selected row's gutter blends into PmenuSel; non-selected rows show the distinct color).
- `render(state)` (L419) — orchestrator. Compute `cue` + `gutter_on`; thread into the above;
  for `"border"` mode add `winhighlight = "FloatBorder:PiBridgeShellBorder"` to `win_cfg` (both
  the nvim_open_win and nvim_win_set_config paths at ~L486/L494).
- `M.on_results(buf, items, prefix)` (L512) → `M.on_results(buf, items, prefix, context)`, store `state.context`.
- `M.close()` (L568) / `M.reset()` (L654) → nil `state.context` (hygiene; on_results always re-sets).

## No plugin highlight groups exist yet
`grep -rn "nvim_set_hl\|PiBridge\|set_hl" lua/ plugin/ ftplugin/` → **nothing.** Define defaults
lazily on first render (standard nvim-plugin pattern) with `default = true` so user themes win:
- `PiBridgeShellGutter` → link `SpecialKey` (or `Comment`).
- `PiBridgeShellBorder` → link `WarningMsg` (a yellow, mirrors pi's bash-mode border tint).

## No winhighlight on the floating win today
`grep "winhighlight\|FloatBorder" lua/pi-bridge/menu.lua` → none. Border mode = add `winhighlight`
to `win_cfg` conditionally (cheap; nvim_open_win + nvim_win_set_config both honor it).

## Config: `shell` block not formalized in init.lua yet
T6.S1 (init.lua `shell = {}` config block) is Planned and lands AFTER S5. So S5 reads
`config.shell.visual_cue` **defensively** (the established codebase pattern — e.g. shell.lua L340
`local cfg = (pi.config and pi.config.shell) or {}`):
`local cue = (pi.config and pi.config.shell and pi.config.shell.visual_cue) or "gutter"`.
Forward-compatible: T6.S1 formalizing the block changes nothing for S5.

## Test patterns (verified)
- Plenary spec harness: `tests/minimal_init.lua` (prepends plenary + plugin root to rtp).
  Run: `timeout 90 nvim --headless --clean -u tests/minimal_init.lua -c 'lua require("plenary.busted").run("tests/menu_spec.lua")'`
- `tests/menu_spec.lua` uses `with_cursor_window`, `menu.open({…})`, inspects `menu._state.menu_buf`
  buffer lines + namespace highlights via a `hl_groups_on_row(mbuf, ns, row)` helper; pure helpers
  tested via `M._compute_width`/`M._column_metrics`/`M._truncate` (the `M._` test-seam convention).
- Smoke (plenary-free): `tests/<module>_smoke.lua` run via `-u NORC +"luafile tests/<x>_smoke.lua" +qa`.
- Lint/format: selene + stylua (PRD §14 CI).

## Gotchas
- **Heredoc → nvim stdin HANGS** (AGENTS.md ⛔ HARD RULE): all nvim test invocations use `+"luafile <file>"`,
  NEVER pipe a heredoc into nvim. Wrap every nvim call in `timeout`.
- **FAST context (E5560):** the shell daemon cb (completion.lua L438) is libuv FAST context → already
  `vim.schedule`s the `on_results` hop. Threading the 4th `context` arg through it is free (a string).
- **CJK / double-width:** gutter is ASCII (`$ `), so `strdisplaywidth` == 2 always; no CJK math needed
  for the gutter itself (existing label/desc math already uses strdisplaywidth).
- **PmenuSel LAST-WINS** (neovim#8449): apply the gutter highlight BEFORE PmenuSel so the selected row's
  `$` stays visible (blends into the selection bg); do NOT apply it after.