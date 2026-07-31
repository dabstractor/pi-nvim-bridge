# Research Notes — P2.M7.T20.S33 (Tab handler: shouldTriggerFileCompletion + force getSuggestions)

The THIRD and final keymap handler of P2.M7 (after S30 `refresh` + S32 `accept`/`on_enter`).
The ftplugin (S22, COMPLETE) ALREADY dispatches `<Tab>` → `completion.on_tab(buf)`; today
`on_tab` is a forward-contract that does not exist, so Tab falls through to `feedkey("<Tab>")`
(indent). S33 makes `on_tab(buf)` exist + pi-faithful. This file consolidates the COMPLETE
research (codebase + pi source + `:help` + the test discipline) the PRP cites.

---

## §1. The S33 contract (from the plan + ftplugin + PRD)

- **Task**: `P2.M7.T20.S33` — "Tab handler — shouldTriggerFileCompletion + force getSuggestions".
- **Plan parent**: `P2.M7.T20` (Tab-triggered file completion). **Module parent**: `P2.M7`
  (Completion Flow). The completion MODULE (`plugin/lua/pi-editor/completion.lua`) is the file
  S33 modifies (additive — S30 `refresh`/`do_refresh`/`reset`/`current`/`on_results` + S32
  `accept`/`on_enter` stay UNCHANGED).
- **The ftplugin wiring (S22, COMPLETE — S33 does NOT touch it)**:
  `plugin/ftplugin/pi-prompt.lua` maps `map_dispatch("i","<Tab>","pi-editor.completion","on_tab")`.
  `dispatch` lazy-requires the module + calls `on_tab(buf)`; returns `true` ONLY if the module
  exists AND `on_tab` returned truthy → the ftplugin CONSUMES the Tab (no feedkey). If `on_tab`
  returns falsy (or the module/fn is absent) → `feedkey("<Tab>")` runs the DEFAULT (indent).
  `buf` is the pi-prompt buffer handle (buffer-local keymap). The dispatch is pcall-wrapped in
  the ftplugin, so `on_tab` never breaks the keymap chain — but be defensive anyway.
- **PRD §7.4 (heading h3.20 — the AUTHORITATIVE requirement)**:
  > - **Tab with no menu open** → call `shouldTriggerFileCompletion`; if true, call
  >   `getSuggestions(..., { force = true })` and show results (matches pi's Tab).
  > - **Tab / `<C-Y>` / `<CR>` with menu open** → accept (see below).
  - **NOTE**: the PRD §7.4 summary OMITS two pi behaviors that the in-tree research doc
    (`architecture/research-pi-autocomplete.md`) + the pi source DO document: (a) the
    slash-command `force:false` branch, (b) the single-item auto-apply. Because PRD §1's
    #1 goal is "completion behavior in Neovim is byte-for-byte identical to pi's TUI", S33
    replicates pi's ACTUAL `handleTabCompletion` (§2 below), of which the PRD's two bullets
    are the common-case simplification. See §3 for the precise branch mapping.
- **`shouldTriggerFileCompletion` is an RPC** (PRD §5.4 row; protocol.ts
  `ShouldTriggerFileCompletionParams {lines, cursorLine, cursorCol}` /
  `ShouldTriggerFileCompletionResult = boolean`; server handler S13, COMPLETE — delegates
  SYNCHRONOUSLY to pi's `AutocompleteProvider.shouldTriggerFileCompletion`). So the plugin
  calls it via `bridge.request("shouldTriggerFileCompletion", {lines, cursorLine, cursorCol}, cb)`
  — it is NOT reimplemented locally (reimplementing risks divergence + would miss
  `isSlashMenuAllowed`-style future changes). The `force` flag on `getSuggestions` is the
  OTHER half (protocol.ts `GetSuggestionsParams.force?`).

---

## §2. pi's ACTUAL Tab logic (the source of truth — editor.ts + autocomplete.ts)

The pi TUI dispatches `<Tab>` (`tui.input.tab`) in TWO mutually-exclusive places:

**(A) Tab when the menu is OPEN** — `editor.ts:664` (inside the `autocompleteState &&
autocompleteList` block):
```ts
if (kb.matches(data, "tui.input.tab")) {
    const selected = this.autocompleteList.getSelectedItem();
    if (selected && this.autocompleteProvider) {
        this.pushUndoSnapshot();
        const result = this.autocompleteProvider.applyCompletion(
            this.state.lines, this.state.cursorLine, this.state.cursorCol,
            selected, this.autocompletePrefix);
        this.state.lines = result.lines;
        this.state.cursorLine = result.cursorLine;
        this.setCursorCol(result.cursorCol);
        this.cancelAutocomplete();
        if (this.onChange) this.onChange(this.getText());
    }
    return;   // Tab CONSUMED
}
```
→ **apply the selected item** (the S32 `accept` core, verbatim).

**(B) Tab when the menu is CLOSED** — `editor.ts:714` (`!this.autocompleteState`):
```ts
if (kb.matches(data, "tui.input.tab") && !this.autocompleteState) {
    this.handleTabCompletion();
}
```

`handleTabCompletion` (`editor.ts:2126`) BRANCHES on the slash-command context:
```ts
private handleTabCompletion(): void {
    if (!this.autocompleteProvider) return;
    const currentLine = this.state.lines[this.state.cursorLine] || "";
    const beforeCursor = currentLine.slice(0, this.state.cursorCol);
    if (this.isInSlashCommandContext(beforeCursor) && !beforeCursor.trimStart().includes(" ")) {
        this.handleSlashCommandCompletion();   // → requestAutocomplete({force:false, explicitTab:true})
    } else {
        this.forceFileAutocomplete(true);      // → requestAutocomplete({force:true, explicitTab:true})
    }
}
```

`isInSlashCommandContext` (`editor.ts:2080`) + its gate `isSlashMenuAllowed` (`editor.ts:2068`):
```ts
private isSlashMenuAllowed(): boolean {
    return this.state.cursorLine === 0;          // ★ slash commands ONLY on the FIRST line
}
private isInSlashCommandContext(textBeforeCursor: string): boolean {
    return this.isSlashMenuAllowed() && textBeforeCursor.trimStart().startsWith("/");
}
```
So the slash branch fires iff: **`cursorLine === 0`** AND `beforeCursor.trimStart().startsWith("/")`
AND `!beforeCursor.trimStart().includes(" ")` (a bare `/cmd` on line 0 with no space yet).

`requestAutocomplete({force, explicitTab})` (`editor.ts:2147`) — the `force:true` path CONSULTS
the guard FIRST:
```ts
if (options.force) {
    const shouldTrigger =
        !this.autocompleteProvider.shouldTriggerFileCompletion ||
        this.autocompleteProvider.shouldTriggerFileCompletion(
            this.state.lines, this.state.cursorLine, this.state.cursorCol);
    if (!shouldTrigger) return;            // ★ ABORT — no fetch (the "bare slash command" case)
}
this.cancelAutocompleteRequest();
// ... debounce 0ms for explicitTab/force (getAutocompleteDebounceMs) → startAutocompleteRequest
```

`shouldTriggerFileCompletion` (`autocomplete.ts:775`) — the guard's BODY (returns false ONLY for a
bare slash command):
```ts
shouldTriggerFileCompletion(lines, cursorLine, cursorCol): boolean {
    const currentLine = lines[cursorLine] || "";
    const textBeforeCursor = currentLine.slice(0, cursorCol);
    if (textBeforeCursor.trim().startsWith("/") && !textBeforeCursor.trim().includes(" ")) {
        return false;
    }
    return true;
}
```

`getAutocompleteDebounceMs` (`editor.ts:2214`): **`0` for explicitTab OR force** (Tab is immediate;
no 25ms debounce). Otherwise 20ms only right after a trigger char.

**Single-item auto-apply** (`editor.ts:2253`, inside `runAutocompleteRequest`, the
`force && explicitTab && items.length === 1` case):
```ts
if (options.force && options.explicitTab && suggestions.items.length === 1) {
    const item = suggestions.items[0]!;
    this.pushUndoSnapshot();
    const result = this.autocompleteProvider.applyCompletion(
        this.state.lines, this.state.cursorLine, this.state.cursorCol,
        item, suggestions.prefix);          // ★ prefix = the getSuggestions result's prefix (NOT autocompletePrefix)
    this.state.lines = result.lines;
    this.state.cursorLine = result.cursorLine;
    this.setCursorCol(result.cursorCol);
    if (this.onChange) this.onChange(this.getText());
    this.tui.requestRender();
    return;                                 // ★ apply IMMEDIATELY, do NOT show the list
}
this.applyAutocompleteSuggestions(suggestions, options.force ? "force" : "regular");
```
So the **file-force** path (`force:true, explicitTab:true`) with EXACTLY 1 result applies it
WITHOUT showing the menu. The **slash** path (`force:false`) NEVER auto-applies (shows the menu
even with 1 item — `applyAutocompleteSuggestions` always sets the list).

### Key consequences for S33:
1. The slash branch (`force:false`) is reached ONLY when `cursorLine===0` + bare `/…`. In our
   plugin the per-keystroke refresh (S30, `force:false`) ALREADY keeps the slash menu populated
   while typing, so by Tab-time the menu is usually OPEN → branch (A) accepts. Branch (B)-slash
   matters only for the rare "menu closed while on `/cmd`" case (e.g. user dismissed, then Tab).
   We replicate it anyway for byte-for-byte fidelity.
2. `shouldTriggerFileCompletion` is consulted ONLY on the `force:true` (file-force) path; on the
   slash path (`force:false`) it is NOT called. And because the slash branch already excluded the
   "bare `/cmd`" case, the file-force path's `shouldTriggerFileCompletion` would in practice
   always return `true` — but we STILL call it (RPC) to honor PRD §7.4 verbatim + to stay robust
   to pi changes (belt-and-suspenders, exactly like pi).
3. The file-force single-item auto-apply needs the getSuggestions RESULT's `prefix`, not the
   menu's prefix (the menu is not shown). This is the ONE place S33 diverges from S32's
   `accept(item)` (which reads `menu.get_prefix()`). Resolution: add an OPTIONAL `prefix`
   override arg to `accept` (§6) — backward compatible (S32's `on_enter` calls `accept(item)`
   with no override → reads `menu.get_prefix()`).

---

## §3. The on_tab(buf) branch map (pi-faithful, maps §2 onto the plugin's COMPLETE seams)

```
on_tab(buf):
  GUARDS: buf valid + buf == current_buf (mirror accept/on_enter)         → else return false
  menu = require("pi-editor.menu")
  ── BRANCH 1 (menu OPEN + selected): pi editor.ts:664 ──
  if menu.is_open() and menu.has_items() and type(menu.get_selected())=="table":
      return M.accept(menu.get_selected())    -- S32 core; true iff applyCompletion issued
  ── BRANCH 2 (menu CLOSED): pi handleTabCompletion (editor.ts:2126) ──
  bridge = require("pi-editor").bridge         -- read FRESH
  GUARD: bridge connected                                                       → else return false (Tab→indent degrade)
  lines, cur = pcall nvim_buf_get_lines / nvim_win_get_cursor                  → else return false
  coords = require("pi-editor.coords")
  pi = coords.nvim_to_pi_coords(lines, cur[1], cur[2])   -- {lines, cursorLine, cursorCol(UTF-16)}
  -- beforeCursor (CHAR/UTF-16-faithful prefix; pi.cursorCol is the UTF-16 length of the prefix):
  line_str  = pi.lines[pi.cursorLine] or ""
  byte_end  = coords.utf16_to_byte(line_str, pi.cursorCol)   -- S28 primitive (COMPLETE)
  before    = line_str:sub(1, byte_end)                       -- UTF-8 prefix (char-faithful for ASCII checks)
  trimmed   = before:gsub("^%s+","") or ""                    -- trimStart
  is_slash_ctx = (pi.cursorLine == 0) and trimmed:sub(1,1) == "/"   -- isSlashMenuAllowed + trimStart starts "/"
  no_space     = not trimmed:find(" ")                              -- !trimStart().includes(" ")
  ── BRANCH 2a (slash command, force:false): pi handleSlashCommandCompletion ──
  if is_slash_ctx and no_space:
      M.force_fetch(buf, {force=false}, M._route_or_accept(buf, allow_auto=false))
      return true                       -- Tab CONSUMED (pi consumes it regardless of outcome)
  ── BRANCH 2b (file force, force:true): pi forceFileAutocomplete ──
  -- consult shouldTriggerFileCompletion (RPC) FIRST; if false → no fetch (pi:2150 abort)
  pcall(bridge.request, "shouldTriggerFileCompletion",
        {lines=pi.lines, cursorLine=pi.cursorLine, cursorCol=pi.cursorCol},
        function(err, ok)
          if err or ok ~= true then return end   -- false/no-op (Tab already consumed)
          M.force_fetch(buf, {force=true}, M._route_or_accept(buf, allow_auto=true))
        end)
  return true                           -- Tab CONSUMED
```

`force_fetch(buf, opts, on_items)` — a NEW private helper (ADDITIVE; do NOT refactor S30's
`do_refresh`). It is the IMMEDIATE (0-debounce), superseded sibling of `do_refresh`:
```
  cancel_timer()                        -- drop any pending refresh debounce (so it can't race)
  if state.inflight_id then bridge.cancel(state.inflight_id) end   -- supersede layer 1
  state.inflight_id = nil
  state.gen = state.gen + 1; local gen = state.gen                  -- supersede layer 2
  params = vim.tbl_extend("keep", pi_coords, { force = (opts.force == true) })
  id = pcall(bridge.request, "getSuggestions", params, function(err, result)
      if gen ~= state.gen then return end               -- STALE — drop, touch nothing
      state.inflight_id = nil
      if err then return end                            -- cancelled/timeout/error → touch nothing
      items  = (result and type(result.items)=="table")  and result.items  or {}
      prefix = (result and type(result.prefix)=="string") and result.prefix or ""
      state.last_result = {items=items, prefix=prefix}
      on_items(buf, items, prefix)                      -- route to menu OR auto-apply
  end)
  if id then state.inflight_id = id end
```
`_route_or_accept(buf, allow_auto)` returns a closure `function(buf, items, prefix)`:
```
  -- SINGLE-ITEM AUTO-APPLY (force+explicitTab+1 item): pi editor.ts:2253
  if allow_auto and #items == 1 then
      M.accept(items[1], prefix)          -- prefix OVERRIDE (the result's prefix; menu not shown)
      return
  end
  -- else route to the menu via the SAME seam S30 uses (empty→close, non-empty→open)
  if type(M.on_results) == "function" then pcall(M.on_results, buf, items, prefix) end
```

### Why `force_fetch` is SEPARATE from `do_refresh` (not a refactor):
- `do_refresh` DEBOUNCES (25ms via `vim.defer_fn`) — pi's natural-typing path. Tab is
  `explicitTab` → pi returns **0ms** debounce (`getAutocompleteDebounceMs`). on_tab must fire
  IMMEDIATELY. Reusing `do_refresh` would add a 25ms lag to Tab (diverges from pi).
- `do_refresh` is EXHAUSTIVELY tested (S30 spec). A refactor risks regressions. `force_fetch`
  is ADDITIVE + shares the SAME `state` (gen, inflight_id, debounce_timer) so supersession is
  CORRECT across refresh↔Tab (a keystroke after Tab supersedes the Tab fetch via the shared gen;
  Tab cancels a pending refresh debounce). This mirrors the codebase's "additive over refactor"
  preference (see the S31/S32 PRPs).
- The supersession mechanics (cancel_timer + cancel(inflight) + gen-guard) are DUPLICATED from
  `do_refresh`. That is intentional + low-risk (a few lines); document it in the [Mode A] header
  so a future reader sees the pair.

---

## §4. The `accept` prefix-override (the ONE backward-compatible change to S32)

S32's `M.accept(item)` reads `prefix = (menu.get_prefix() or "")`. The single-item auto-apply
path (§2) needs the getSuggestions RESULT's `prefix` (the menu is NOT shown, so
`menu.get_prefix()` is stale/empty). Resolution (minimal, backward-compatible):
```lua
function M.accept(item, prefix_override)
  ... (guards unchanged) ...
  local params = {
    lines = pi.lines, cursorLine = pi.cursorLine, cursorCol = pi.cursorCol,
    item  = item,
    prefix = (type(prefix_override) == "string") and prefix_override or (menu.get_prefix() or ""),
  }
  ... (cb unchanged) ...
end
```
- S32's `on_enter` calls `M.accept(item)` → `prefix_override` is nil → reads `menu.get_prefix()`
  (UNCHANGED behavior; S32's spec stays green).
- S33's auto-apply calls `M.accept(items[1], prefix)` → uses the result's prefix.
- The LuaCATS annotation gains `---@param prefix_override string?`.

---

## §5. nvim semantics (`:help`-verified — the on_tab context)

- **`on_tab` runs on the nvim MAIN LOOP** (it is a `vim.keymap.set("i", …)` callback — keymap
  callbacks fire on the main loop). So it may call `nvim_buf_get_lines` /
  `nvim_win_get_cursor` / `bridge.request` DIRECTLY (NO `vim.schedule` wrapper) — the SAME
  api-safety contract as `do_refresh` (research/vim-defer-fn-semantics.md §5) + `accept` (S32).
  `bridge.request`'s cb is itself `schedule_wrap`d → also api-safe.
- **`bridge.request` returns IMMEDIATELY** (the cb lands later). So `on_tab` returns `true`
  (Tab consumed) as soon as the fetch (or the `shouldTriggerFileCompletion` then fetch) is
  ISSUED; the menu population / auto-apply happens ASYNC in the cb (< `rpc_timeout_ms`).
  This mirrors `accept`/`on_enter`'s "return true on issue" contract (S32).
- **The Tab keymap is `expr`-FREE + uses `feedkey` fall-through** (ftplugin S22): `dispatch`
  returns truthy → the keymap's `function() … end` body does NOT call `feedkey` (Tab consumed).
  Falsy → `feedkey("<Tab>")` runs the DEFAULT. So `on_tab` returning `true`/`false` is the
  consume/fall-through signal — there is NO `<Tab>` expr-mode string contract to honor.
- **No `TextChangedI` re-entrancy from the auto-apply**: the auto-apply reuses `M.accept`, which
  mutates the buffer via `nvim_buf_set_lines` (an API mutation — does NOT fire `TextChangedI`,
  S32 research §5 / `:help TextChangedI`). So no refresh loop. (And a menu-populating Tab does
  NOT mutate the buffer at all — it only opens the menu.)
- **Single-item auto-apply leaves the user in Insert** (S32 already proved this: set_lines +
  set_cursor do not change `mode()`). No feedkeys dance.

---

## §6. Integration with the COMPLETE in-tree seams (what S33 READS + the 2 WRITES)

READS (all COMPLETE — read FRESH at call time, the codebase rule):
- `require("pi-editor").bridge` — `is_connected()`, `request(method, params, cb)` → `id|nil`,
  `cancel(id)`. The TWO-LAYER pending map holds getSuggestions / applyCompletion /
  shouldTriggerFileCompletion each in their OWN cb (they never mis-drop each other — S26).
- `require("pi-editor.menu")` — `is_open()`, `has_items()`, `get_selected()` (BRANCH 1 gate);
  `M.accept` internally reads `get_prefix()`/`get_buf()` (the prefix-override short-circuits
  the prefix read; buf is still read for the apply).
- `require("pi-editor.coords")` — `nvim_to_pi_coords(lines, row, byte_col)` →
  `{lines, cursorLine, cursorCol(UTF-16)}`; `utf16_to_byte(line, utf16_idx)` → byte offset
  (S28 primitive — used to slice `beforeCursor` at the UTF-16 boundary). `pi_to_nvim_coords`
  is used inside `accept` (S32) — S33 does not call it directly.
- `require("pi-editor").config` — `rpc_timeout_ms` (default 2000) governs the cb latency.

WRITES (the ONLY source-file changes in S33):
1. `plugin/lua/pi-editor/completion.lua` — ADD `M.on_tab(buf)` + the private `force_fetch` +
   `_route_or_accept` helpers + the `accept` prefix-override arg + the [Mode A] header update
   (on_tab → shipped; new on_tab/force_fetch block). S30/S32 code is ADDITIVE-untouched.
2. (tests) `plugin/tests/completion_spec.lua` — EXTEND with a `describe("on_tab", …)` block
   (reuse the S32 `populated_menu` helper + `fake_bridge`).
3. (tests) `plugin/tests/completion_tab_smoke.lua` — NEW plenary-free smoke (mirror
   `completion_accept_smoke.lua`'s fake-luv-server + REAL bridge + completion + menu).

DO NOT touch: `menu.lua`, `bridge.lua`, `coords.lua`, `init.lua`, the ftplugin, the shim,
`jsonlreader.lua`. The ftplugin ALREADY dispatches `on_tab` (S22) — S33 just makes it exist +
return the right truthy/falsy.

---

## §7. Test strategy (mirror S32's discipline — the spec helper + smoke bootstrap)

### Spec (`completion_spec.lua`, EXTEND — add `describe("on_tab", …)` after the S32 block):
Reuse the S32 `populated_menu(line, byte_col, items, prefix)` helper (drives the menu open via
the REAL seam: `fake_bridge` + `menu.attach()` + `refresh()` + resolve a getSuggestions). Also
add a `closed_menu(line, byte_col)` helper (a buf + cursor with NO refresh / an empty result, so
`menu.is_open()` is false). Cases:
- **(1) BRANCH 1 — menu open + Tab → accept**: `populated_menu("/mod", 3, {{value="/model",…}}, "/mo")`;
  `local n0=#fake.requests; local ok=completion.on_tab(buf)`; assert `ok==true` + the LAST request is
  `applyCompletion` with `params.item.value=="/model"` + `params.prefix=="/on_results prefix"`.
  (Proves Tab delegates to the S32 accept core.)
- **(2) BRANCH 2b — file-force: shouldTriggerFileCompletion=true → force getSuggestions**:
  `closed_menu("./src/com", 8)`; `on_tab(buf)`; assert the FIRST request after on_tab is
  `shouldTriggerFileCompletion` with `{lines, cursorLine=0, cursorCol=…}`; `fake.resolve_last(nil,true)`;
  assert the NEXT request is `getSuggestions` with `params.force==true`; resolve it with
  `>1` items → assert `menu.is_open()` (shown, not auto-applied).
- **(3) BRANCH 2b — shouldTriggerFileCompletion=false → NO getSuggestions**: same setup but
  `fake.resolve_last(nil,false)`; assert NO `getSuggestions` request is ever issued + Tab returned
  `true` (consumed, no fetch — pi:2150 abort). (Use a position where shouldTrigger would be false
  OR just drive the fake's reply — the plugin trusts the RPC.)
- **(4) SINGLE-ITEM AUTO-APPLY**: `closed_menu` (non-slash position); on_tab; resolve
  shouldTrigger→true; resolve the `force=true` getSuggestions with EXACTLY 1 item
  `{items={{value="x",…}}, prefix="…"}`; assert the NEXT request is `applyCompletion` with
  `params.item==items[1]` + `params.prefix==<the getSuggestions prefix>` (NOT menu.get_prefix,
  which is "" for a closed menu) + `menu.is_open()==false`.
- **(5) BRANCH 2a — slash ctx (cursorLine 0, bare `/cmd`) → force:FALSE getSuggestions (no
  shouldTrigger call)**: `closed_menu("/mod", 3)`; on_tab; assert the FIRST request is
  `getSuggestions` with `params.force==false` (NOT `shouldTriggerFileCompletion` first); resolve
  with items → `menu.is_open()` (shown; slash path never auto-applies even with 1 item).
- **(6) slash gate on cursorLine≠0**: a `/mod` on line 2 (multi-line buf, cursor on row 2) →
  `isSlashMenuAllowed` false → NOT the slash branch → file-force (`shouldTriggerFileCompletion`,
  which returns true) → `force=true`. (Proves the `cursorLine==0` gate.)
- **(7) never-throws / degrade**: `on_tab(nil)`; `on_tab` on a wiped buf; `pi.bridge=nil` →
  `on_tab(buf)` returns `false` (Tab → indent, no throw); bridge disconnected → `false`.
- **(8) supersession**: on_tab issues a force getSuggestions; before its cb, a `refresh(buf)`
  fires (TextChangedI) → assert the Tab request's cb is dropped (gen-guard) OR cancelled, + the
  refresh's request is the live one. (Mirror S30's two-layer supersession case.)
- DISCIPLINE: `reset()` (before/after_each) already clears `pi.bridge` + `completion.reset()` +
  `menu.reset()`. Do NOT name a spec-local `pending` (shadows plenary's skip fn). Drive menu state
  via the REAL seam (don't hand-set menu internals).

### Smoke (`completion_tab_smoke.lua`, NEW — mirror `completion_accept_smoke.lua`):
A fake luv unix-socket server + REAL `bridge.handshake` + REAL `completion` + `menu.attach()`.
Server cb branches on `req.method`: `hello`→ok; `getSuggestions`→(controlled reply);
`shouldTriggerFileCompletion`→(controlled bool); `applyCompletion`→reply `{lines,cursorLine,cursorCol}`
+ stash the observed req. Flow (vim.wait between each):
1. menu OPEN path: refresh → getSuggestions reply (items) → menu open → `on_tab(buf)` → server
   sees `applyCompletion` → reply → assert buffer + cursor + menu closed.
2. file-force path: `menu.close()` (menu closed) → `on_tab(buf)` → server sees
   `shouldTriggerFileCompletion` → reply `true` → server sees `getSuggestions` `force=true` →
   reply `>1` items → assert `menu.is_open()`.
3. single-item auto-apply: `menu.close()` → on_tab → shouldTrigger→true → getSuggestions reply
   with 1 item → server sees `applyCompletion` → reply → assert buffer applied + menu closed.
Footer: `if fails>0 then vim.cmd("cquit 1") end; io.stdout:write("SMOKE_PASS\n")`.
⚠️ AGENTS.md: run via `+"luafile tests/completion_tab_smoke.lua" +qa` (a FILE) — NEVER pipe a
heredoc into nvim stdin (it HANGS). Wrap in `timeout 60`.

---

## §8. Scope / non-regression / boundaries

- **IN SCOPE (S33)**: `M.on_tab(buf)` (+ `force_fetch` + `_route_or_accept` helpers) + the
  `accept` prefix-override arg + the [Mode A] header update + the spec extension + the new smoke.
- **OUT OF SCOPE**: the floating WINDOW (S34/S35 — `menu.render` stays a no-op; on_tab routes via
  `menu.on_results` which is STATE-only until S34). Navigation `on_next`/`on_prev` (S36). Dismiss
  `on_dismiss` (S37). Autosave/`on_exit` (S38). `:checkhealth` (S42). All stay forward-contracts.
- **Non-regression**: S30 (`refresh`/`do_refresh`/`reset`/`current`/`on_results`) + S32
  (`accept`/`on_enter`) stay GREEN unchanged. The `accept` signature change is ADDITIVE
  (optional 2nd arg) — S32's `on_enter` calls `accept(item)` (no override) → identical behavior.
- **The debounce_timer leak fix (S30)** applies to `force_fetch` too: `cancel_timer()` does
  `:stop()` THEN `:close()` (NEVER stop-only — leaks the `uv_timer_t` on nvim 0.12.x). Reuse the
  EXISTING `cancel_timer()` local (it is already correct) — do NOT reimplement it.
- **pi-faithfulness vs PRD §7.4 simplification**: S33 follows pi's ACTUAL `handleTabCompletion`
  (slash `force:false` branch + file-force `shouldTriggerFileCompletion` guard + single-item
  auto-apply) because PRD §1's #1 goal is byte-for-byte TUI parity. The PRD §7.4 two-bullet
  summary is the common-case view; this task implements the fuller truth the in-tree research
  doc already documents. If the implementer prefers the strict PRD-minimum, the slash branch +
  auto-apply are the descopable pieces (document the choice in the header) — but the DEFAULT +
  recommended path is full parity.