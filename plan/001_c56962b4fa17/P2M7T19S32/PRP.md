---
name: "P2.M7.T19.S32 — completion.lua accept(item) + on_enter(buf): the PRD §7.4 applyCompletion accept flow (RPC → replace buffer → set cursor → close menu)"
description: |
  **MODIFY `plugin/lua/pi-editor/completion.lua`** — ADD `M.accept(item)` (the 5-step PRD §7.4 accept flow) + `M.on_enter(buf)` (the `<CR>` accept-or-newline handler the ftplugin ALREADY dispatches). `accept(item)` reads the selected item + prefix + buf from the COMPLETE `menu` module (S31), reads the CURRENT buffer lines + cursor, converts nvim→pi via the COMPLETE `coords.nvim_to_pi_coords` (S29), issues the `applyCompletion` JSON-RPC over the COMPLETE `bridge.request` (S26) with params `{lines, cursorLine, cursorCol, item, prefix}` (the EXACT mirror of `extension/protocol.ts` `ApplyCompletionParams`), and in the async `schedule_wrap`'d callback converts pi→nvim via `coords.pi_to_nvim_coords` + replaces the WHOLE buffer via `nvim_buf_set_lines(buf, 0, -1, false, nv.lines)` + positions the cursor via `nvim_win_set_cursor(0, {nv.row, nv.col})` (col is 0-based byte — **NO `-1`**; PRD §7.4's `bytecol - 1` is SUPERSEDED by `coords.lua`'s exact-UTF-16 design) + closes the menu via `menu.close()`. **CRITICAL nvim semantics (LIVE-VERIFIED via `:help` + the blink.cmp/nvim-cmp source layout):** (a) `nvim_buf_set_lines` is an API mutation that does **NOT** fire `TextChangedI` (only typed input does — `:help TextChangedI`) ⇒ the accept buffer-replace **CANNOT cause a `TextChangedI`→refresh→getSuggestions loop** (no re-entrancy guard is REQUIRED for correctness; a defensive `state.accepting` flag is OPTIONAL insurance for the narrow async race); (b) `nvim_win_set_cursor` moves the VISIBLE cursor in Insert mode AND scrolls it into view (`:help nvim_win_set_cursor`) WITHOUT firing `CursorMovedI` and WITHOUT a `redraw`/`feedkeys` nudge — so the user **STAYS in Insert mode** (no `<Esc>`/`<i>` dance — `:help mode()` confirms API mutations do not change mode); (c) insertion edge cases (slash `/cmd ` trailing space, `@file` trailing space, directories, quotes, cursor repositioning) are **PI'S job** — `applyCompletion` returns the COMPLETE new `lines` + cursor; S32 applies it WHOLESALE and NEVER reimplements insertion. **Scope (narrow):** S32 implements `accept(item)` + `on_enter(buf)` in `completion.lua` ONLY — it does NOT implement `on_tab` (Tab = trigger/accept/insert-`\t` — S33's contract), does NOT touch `menu.lua`/`bridge.lua`/`coords.lua`/the ftplugin/init/shim, and does NOT couple to the (Planned, S34) floating window (it calls `menu.close()` = state clear + no-op render). **DELIVERABLES:** (1) MODIFY `plugin/lua/pi-editor/completion.lua` (add `accept` + `on_enter` + update the [Mode A] header's forward-contracts list — the header currently says "the 6 keymaps (on_tab/on_enter/…) stay absent"; S32 lands `on_enter`); (2) EXTEND `plugin/tests/completion_spec.lua` with an additive `describe("accept/on_enter", …)` block (reuse the EXISTING `fake_bridge(opts)` helper + the `win`/`nvim_win_set_buf`/`virtualedit=onemore`/`vim.wait` async idiom from the S30 cases); (3) CREATE `plugin/tests/completion_accept_smoke.lua` (plenary-free; fake luv unix-socket server + REAL `bridge.handshake` + REAL `completion` + `menu.attach()`; drive `getSuggestions` reply → menu populated → `on_enter` → server observes `applyCompletion` with `{item, prefix, lines, cursorLine, cursorCol}` → reply `{lines, cursorLine, cursorCol}` → assert buffer replaced + cursor set + menu closed). **NON-REGRESSION:** the ONLY existing file modified is `completion.lua` (additive 2 functions + header-doc update; the S30 `refresh`/`reset`/`current`/`do_refresh`/`on_results` surface is unchanged); the spec extension is additive (S30 cases stay green — `reset()` before/after_each already clears state); the smoke is a NEW file. All prior specs (init/shim/activate/ftplugin/jsonlreader/bridge/handshake/request/notify/coords/completion/menu) stay green.
---

## Goal

**Feature Goal**: Ship the **accept** half of pi-bridge.nvim completion — `completion.accept(item)`
(the PRD §7.4 5-step applyCompletion flow) + `completion.on_enter(buf)` (the `<CR>`
accept-or-newline keymap handler). When the user presses `<CR>` with the completion menu open,
the selected item is sent to pi's `applyCompletion` over the bridge; pi returns the definitive
new buffer + cursor; the plugin replaces the buffer wholesale, positions the cursor, closes the
menu, and leaves the user in Insert mode ready to type the command's arguments. Insertion
behavior is **byte-for-byte identical to pi's TUI** because pi computes it.

**Deliverable** (1 MODIFIED source file + 1 EXTENDED test + 1 NEW smoke):
- **MODIFY** `plugin/lua/pi-editor/completion.lua` — add:
  - `M.accept(item)` — the core accept. Reads `prefix`/`buf` from `menu`; reads CURRENT lines +
    cursor; `coords.nvim_to_pi_coords`; `bridge.request("applyCompletion", {lines, cursorLine,
    cursorCol, item, prefix}, cb)`; in the async cb (success): `coords.pi_to_nvim_coords` →
    `nvim_buf_set_lines(buf, 0, -1, false, nv.lines)` + `nvim_win_set_cursor(0, {nv.row,
    nv.col})` (NO `-1`) + `menu.close()`; on cb error: leave the buffer UNTOUCHED +
    `menu.close()` (silent degrade — S39's job to notify once). Returns `true` if the RPC was
    issued. Never throws (pcall-wrapped nvim + bridge read fresh).
  - `M.on_enter(buf)` — the `<CR>` handler. Returns `true` (CR consumed) IFF `buf` is valid +
    current AND `menu.is_open()` AND `menu.get_selected()` is a table → calls `M.accept(item)`;
    else returns `false` (the ftplugin `feedkey("<CR>")` inserts a NEWLINE — PRD §7.4: no
    Enter-to-submit in the external editor; quitting submits). Never throws.
  - Update the `[Mode A]` header: move `on_enter` from the "forward contracts / stay absent"
    list to "shipped"; add an `accept` [Mode A] block (the PRD §7.4 5-step flow + the nvim
    insert-mode semantics: `nvim_buf_set_lines` does not fire `TextChangedI`; stay-in-insert;
    NO `-1`; insertion is pi's job; the async cb + TWO-LAYER bridge).
- **EXTEND** `plugin/tests/completion_spec.lua` — add a `describe("accept/on_enter", …)` block
  reusing the existing `fake_bridge(opts)` helper. Cases: (1) `accept` issues `applyCompletion`
  with the exact params shape; (2) cb success → buffer replaced + cursor set + menu closed
  (incl. a MULTIBYTE cursor case proving the byte-col + NO-`-1` conversion); (3) cb error →
  buffer untouched + menu closed + never-throws; (4) `on_enter` returns `true` on
  open+selected, `false` otherwise; (5) never-throws on bad args.
- **CREATE** `plugin/tests/completion_accept_smoke.lua` — plenary-free smoke (fake luv server +
  real bridge + real completion + `menu.attach()`): refresh → `getSuggestions` reply → menu
  populated → `on_enter` → server observes `applyCompletion` → reply `{lines, cursorLine,
  cursorCol}` → assert buffer + cursor + menu closed. Prints `SMOKE_PASS` / exit 0.

> Reuses `plugin/tests/minimal_init.lua` (S19) unchanged. The ONLY existing source file
> touched is `completion.lua` (2 additive functions + a header-doc update). NO change to
> `menu.lua` (S31 — S32 only READS it + calls `menu.close()`), `bridge.lua`, `coords.lua`,
> `jsonlreader.lua`, `init.lua`, the ftplugin (it ALREADY dispatches `on_enter`), or the shim.

**Success Definition** (every assertion directly testable — no floating window needed; the
menu is the COMPLETE state layer S31 ships):
- **`accept(item)` issues the RPC correctly**: with a fake bridge, after `accept(item)`,
  `fake.requests[#].method == "applyCompletion"` and `.params == {lines=<buf lines>,
  cursorLine=<row-1>, cursorCol=<S29 utf16 of byte col>, item=<item table verbatim>,
  prefix=<menu.get_prefix()>}`. `accept` returns `true` (RPC issued) when connected.
- **cb success applies pi's result exactly**: resolve the cb with `{lines={"/model "},
  cursorLine=0, cursorCol=7}` → after `vim.wait`, `nvim_buf_get_lines(buf,0,-1,false)` ==
  `{"/model "}` AND `nvim_win_get_cursor(0)` == `{1,7}` AND `menu.is_open()==false`.
- **MULTIBYTE cursor is byte-correct (NO `-1`)**: a result with a multibyte line positions the
  cursor at the exact BYTE offset from `coords.pi_to_nvim_coords` (e.g. `cursorCol` after `日`
  → byte col 6, not 5). Proves the PRD §7.4 `bytecol - 1` supersession.
- **cb error degrades silently**: resolve with `"rpc error -32603"` / `"request timeout"` →
  buffer UNTOUCHED + `menu.is_open()==false` + no throw.
- **`on_enter(buf)` is accept-or-newline**: menu open + selected → returns `true` + accept
  issued; menu closed / no selected / buf not current → returns `false` (CR fall-through).
- **Never-throws** on bad args (nil item, wiped buf, `pi.bridge==nil`, menu/coords absent).
- **No re-entrancy loop**: `accept`'s `nvim_buf_set_lines` does NOT fire `TextChangedI` (an API
  mutation, not typed input — `:help TextChangedI`); the refresh autocmd is not re-triggered.
- Non-regression: all prior specs (init/shim/activate/ftplugin/jsonlreader/bridge/handshake/
  request/notify/coords/completion/menu) stay green; the completion.lua change is additive.

## User Persona (if applicable)

**Target User**: A pi user typing a prompt (`/mod…`, `@src/comp…`, `./path/…`) in the Neovim
external editor. They press `<CR>` (or later `<Tab>`, S33) to accept the highlighted
completion. They experience: the slash command / file / path expands exactly as it does in
pi's TUI (trailing space for files, `/model ` with a space for commands, no trailing space for
directories, quotes handled), the cursor lands at the right spot (after the inserted text, or
inside an argument position), the menu closes, and they keep typing the command's argument
WITHOUT leaving Insert mode. (The menu WINDOW is S34 — until it lands the user still gets the
accept via `<CR>`; S32 is the accept LOGIC + the `<CR>` binding, testable via state + buffer
assertions without a popup.)

**Use Case**: The acceptance half of the completion pipeline. Activation (S21) → buffer (S22)
→ bridge transport+handshake+RPC (S24–S27, COMPLETE) → coords (S28/S29, COMPLETE) → S30
(refresh→debounce→fetch→supersede→`on_results`, COMPLETE) → S31 (`on_results` → menu state
population, COMPLETE) → **S32 (this: `<CR>` → menu.get_selected → applyCompletion → replace
buffer + cursor + close menu)** → S33 (`<Tab>` = trigger/accept/insert-`\t`, calls the SHARED
`accept`) → S34+ (floating window renders the state). Without S32, `<CR>` falls through to a
plain newline (the ftplugin's `feedkey("<CR>")`); the menu items can never be accepted.

**Pain Points Addressed**:
1. **No way to accept a completion**: S31 ships menu STATE (selected item, prefix, buf) but no
   consumer accepts it. S32 closes the loop — `<CR>` on an open menu applies the selection.
2. **Reimplementing pi's insertion would diverge**: a naive accept would string-replace the
   prefix in-place, getting trailing-space / directory / quote handling wrong. S32 delegates
   insertion to pi (`applyCompletion` returns the WHOLE new buffer) and applies it wholesale —
   byte-for-byte identical to the TUI.
3. **Cursor off-by-one on multibyte prompts**: PRD §7.4 step 4's `bytecol - 1` would nudge the
   cursor one byte LEFT on every accept (worst on CJK/emoji). S32 follows `coords.lua`'s
   exact-UTF-16 + 0-based-byte-cursor-API design (NO `-1`) — correct for the whole BMP.
4. **Completion-accept mode jank**: some editors leave Insert mode or need a `feedkeys` dance
   on accept. S32's two-API-call sequence (`nvim_buf_set_lines` + `nvim_win_set_cursor`) keeps
   the user in Insert mode with the cursor visibly correct (`:help`-verified).

## Why

- **PRD §7.4 (Accept flow)** is the requirement source: "(1) read current lines + cursor, (2)
  `applyCompletion(lines, cursorLine, cursorCol, selectedItem, prefix)`, (3) `nvim_buf_set_lines`,
  (4) `nvim_win_set_cursor`, (5) close menu, stay in insert mode." S32 implements steps 1–5.
  PRD §4 step 5 + §6.5: "pi's `applyCompletion` returns the ENTIRE line array + the final
  cursor — the plugin never reimplements insertion edge cases."
- **The S32 task contract** (`tasks.json`): "Implement `M.accept(item)` … calls
  `bridge.request('applyCompletion', {lines, cursorLine, cursorCol, item, prefix}, callback)` …
  in callback: `nvim_buf_set_lines(0, 0, -1, false, result.lines)`, convert
  `result.cursorLine/cursorCol` to nvim coords, `nvim_win_set_cursor(0, {row, byte_col})`,
  close menu." The S36 navigation contract pins the placement: "**completion.lua's accept()
  (S32)** which calls `M.get_selected()` then closes." → `accept` lives in `completion.lua`,
  reads `menu.get_selected()`, and calls `menu.close()`.
- **The wire shapes are FIXED** (`extension/protocol.ts` `ApplyCompletionParams` /
  `ApplyCompletionResult`) and the server handler is DONE + tested (P1.M2.T6.S12 — pure SYNC
  delegation, no AbortController/timeout). S32 is the client-side mirror.
- **The nvim accept semantics are `:help`-verified** (research/notes.md §5): API mutations do
  not fire `TextChangedI` (no loop) and do not change `mode()` (stay Insert); the sequence is
  two API calls, no feedkeys/redraw. This is the same approach blink.cmp (`accept/init.lua`) +
  nvim-cmp (`core.lua confirm`) take.
- **Leaf + mostly additive.** S32's only upstream dependencies that are COMPLETE are S31
  (`menu.get_selected/get_prefix/get_buf/is_open/has_items/close`), S29
  (`coords.nvim_to_pi_coords/pi_to_nvim_coords`), S26 (`bridge.request/is_connected`), and S30
  (`completion.lua` — the file S32 extends). It is the upstream dependency of S33 (`on_tab`
  calls the SHARED `accept`). The only existing source file touched is `completion.lua`.

## What

Two new methods on the EXISTING `plugin/lua/pi-editor/completion.lua` module + the [Mode A]
header update. Pipeline:

```lua
-- <CR> (the ftplugin ALREADY dispatches on_enter; S32 makes it return truthy):
--   ftplugin map_dispatch("i","<CR>","pi-editor.completion","on_enter")
--     → dispatch(...) → M.on_enter(buf) → if truthy: CR consumed; else feedkey("<CR>") (newline)
-- M.on_enter(buf):
--   if type(buf)~="number" or not nvim_buf_is_valid(buf) then return false end
--   if buf ~= nvim_get_current_buf() then return false end           -- one buf/session (PRD §11)
--   local menu = require("pi-editor.menu")
--   if not menu.is_open() or not menu.has_items() then return false end
--   local item = menu.get_selected()
--   if type(item) ~= "table" then return false end
--   return M.accept(item)                                            -- true iff RPC issued
-- M.accept(item):
--   local menu  = require("pi-editor.menu")                          -- read FRESH (handshake async)
--   local bridge= require("pi-editor").bridge                        -- read FRESH
--   if not bridge or type(bridge.is_connected)~="function" or not bridge.is_connected() then return false end
--   local buf = menu.get_buf()
--   if type(buf)~="number" or not nvim_buf_is_valid(buf) then return false end
--   if buf ~= nvim_get_current_buf() then return false end
--   local ok, lines = pcall(nvim_buf_get_lines, buf, 0, -1, false); if not ok then return false end
--   local cur; ok, cur = pcall(nvim_win_get_cursor, 0); if not ok then return false end
--   local pi = require("pi-editor.coords").nvim_to_pi_coords(lines, cur[1], cur[2])
--   local params = { lines=pi.lines, cursorLine=pi.cursorLine, cursorCol=pi.cursorCol,
--                    item=item, prefix=menu.get_prefix() or "" }
--   local issued = false
--   pcall(bridge.request, "applyCompletion", params, function(err, result)
--     -- async, schedule_wrap'd by bridge → nvim main loop (api-safe)
--     if err then menu.close(); return end                            -- degrade: buffer UNTOUCHED
--     if type(result)~="table" then menu.close(); return end          -- malformed → degrade
--     local nv = require("pi-editor.coords").pi_to_nvim_coords(result.lines, result.cursorLine, result.cursorCol)
--     pcall(nvim_buf_set_lines, buf, 0, -1, false, nv.lines)          -- replace WHOLE buffer
--     local row, col = nv.row, nv.col                                 -- col is 0-based BYTE (NO -1)
--     pcall(nvim_win_set_cursor, 0, { row, col })                     -- moves visible cursor in Insert; no redraw
--     menu.close()                                                    -- clear state (+ no-op render until S34)
--   end)
--   issued = true                                                     -- RPC accepted by the bridge (fire-and-forget cb)
--   return issued
```

### Success Criteria

- [ ] `completion.accept` and `completion.on_enter` are `function`s (added to the module).
- [ ] `accept(item)` with a fake bridge issues `applyCompletion` with `.params == {lines=<buf>,
      cursorLine=<row-1>, cursorCol=<S29 utf16>, item=<verbatim>, prefix=<menu prefix>}` and
      returns `true`; returns `false` (no throw) when the bridge is absent/disconnected, buf is
      wiped/not-current, or item is non-table.
- [ ] On a SUCCESS cb, the buffer is replaced with `result.lines` WHOLESALE, the cursor is at
      `{result.cursorLine+1, <byte col from coords.pi_to_nvim_coords>}` (NO `-1`), and
      `menu.is_open()==false`.
- [ ] A MULTIBYTE result (e.g. cursor after `日`) positions the cursor at the exact BYTE offset
      (proving the PRD §7.4 `bytecol - 1` supersession).
- [ ] On an ERROR cb (`"rpc error …"` / `"request timeout"`), the buffer is UNTOUCHED,
      `menu.is_open()==false`, and nothing throws.
- [ ] `on_enter(buf)` returns `true` iff buf is valid+current AND `menu.is_open()` AND
      `menu.get_selected()` is a table (and then `accept` is issued); otherwise `false`.
- [ ] The user STAYS in Insert mode after accept (`mode()` unchanged) — no `feedkeys`/`<Esc>` dance.
- [ ] `accept`'s `nvim_buf_set_lines` does NOT re-trigger the refresh autocmd (no
      `TextChangedI` from API mutations — `:help TextChangedI`); no refresh loop.
- [ ] `accept`/`on_enter` never throw on bad args (nil item, nil/wiped buf, `pi.bridge==nil`,
      menu/coords absent); the [Mode A] header is updated (on_enter moved to "shipped"; new
      accept block added).
- [ ] Non-regression: all prior specs green; the completion.lua change is additive (S30
      `refresh`/`reset`/`current`/`do_refresh`/`on_results` unchanged).

## All Needed Context

### Context Completeness Check

_If someone knew nothing about this codebase, would they have everything needed to implement
this successfully?_ **YES** — every upstream dependency is COMPLETE and in-tree with exhaustive
`[Mode A]` headers + PRPs: the S31 `menu` accessors (`get_selected`/`get_prefix`/`get_buf`/
`is_open`/`has_items`/`close`), the S29 `coords.nvim_to_pi_coords`/`pi_to_nvim_coords`
(including the documented PRD §7.4 `bytecol - 1` SUPERSESSION), the S26 `bridge.request`
(TWO-LAYER: applyCompletion racing getSuggestions each resolve to their own cb; the cb is
`schedule_wrap`'d → api-safe), the `ApplyCompletionParams`/`ApplyCompletionResult` wire shapes
(`extension/protocol.ts`), the server-side SYNC-delegation behavior (`makeApplyCompletionHandler`),
the fake_bridge test helper + the fake-server smoke bootstrap, and the `:help`-verified nvim
insert-mode accept semantics (no `TextChangedI` loop; stay-in-Insert; NO `-1`). The implementer
reads these, adds 2 functions to `completion.lua`, extends the spec, writes the smoke, and runs
the verified test commands. No guessing; no further external research required (all references
in-tree + the research file + the `:help` tags).

### Documentation & References

```yaml
# MUST READ - Include these in your context window
- url: https://neovim.io/doc/user/api.html#nvim_win_set_cursor()
  why: "The accept cursor-set. 'Move the window cursor … This will scroll the window such that
        the cursor is visible.' Does NOT fire CursorMoved/CursorMovedI. Confirms the visible
        cursor moves in Insert mode WITHOUT a redraw/feedkeys nudge. col is 0-indexed BYTE."
  critical: "col is 0-indexed BYTE — matches coords.pi_to_nvim_coords output DIRECTLY (NO -1).
             PRD §7.4 step 4's `bytecol - 1` DOUBLE-CORRECTS under this design (see coords.lua
             header) — S32 must NOT subtract 1."

- url: https://neovim.io/doc/user/autocmd.html#TextChangedI
  why: "Proves accept's nvim_buf_set_lines (an API mutation) does NOT fire TextChangedI — only
        TYPED input does. => S32's buffer-replace cannot re-trigger the refresh autocmd; NO
        re-entrancy guard is REQUIRED. (b:changedtick DOES increment — do not key refresh off it.)"
  critical: "If you route the accept edit through feedkeys 'to trigger refresh' you WILL fire
             TextChangedI and risk a loop. Use nvim_buf_set_lines (API) — it is loop-free by design."

- url: https://github.com/Saghen/blink.cmp/blob/main/lua/blink/cmp/completion/accept/init.lua
  why: "THE reference accept implementation. blink applies the edit via the buffer API
        (nvim_buf_set_text/set_lines) then positions the cursor with nvim_win_set_cursor — NO
        feedkeys/<Esc>/<i> dance, stays in Insert. S32 is the whole-buffer-replace variant of
        this (pi returns ALL lines). (Pin a commit SHA before quoting line numbers.)"
  critical: "nvim-cmp FUSES state+window + uses feedkeys/<C-g>U for undo grouping — do NOT copy
             cmp's confirm path. Model on blink's buffer-API + set_cursor sequence."

- file: plugin/lua/pi-editor/completion.lua
  why: "THE file S32 modifies. Read its [Mode A] header (esp. the FORWARD CONTRACTS block — it
        currently says 'the 6 keymaps (on_tab/on_enter/…) stay absent; S30 implements refresh
        ONLY'; S32 lands on_enter + accept) + do_refresh's cb (the api-safe main-loop contract +
        the bridge-read-fresh rule S32's accept MUST mirror) + M.current() (the items accessor)
        + M.reset() (the cleanup seam). The singleton `state` table is where an OPTIONAL
        `accepting` flag would live."
  pattern: "Read the bridge FRESH inside accept: `local bridge = require('pi-editor').bridge`
            (NOT a module-load local — the handshake resolves async + tests swap fakes after
            require). Same for menu + coords. The cb is schedule_wrap'd by bridge → it is
            api-safe (call nvim_buf_set_lines/nvim_win_set_cursor directly, NO extra vim.schedule)."
  gotcha: "do_refresh's two-layer supersession (cancel + gen-guard) is for getSuggestions.
           applyCompletion is a ONE-SHOT user action — NO gen-guard needed (capture buf in the
           closure; validate buf valid+current in the cb; the accept result is AUTHORITATIVE).
           The bridge holds both in pending[id] (TWO-LAYER) so they never mis-drop each other."

- file: plugin/lua/pi-editor/menu.lua
  why: "THE module S32 READS (+ the only menu WRITE is menu.close()). Read its public surface:
        get_selected() (items[selected] or nil), get_prefix() (string), get_buf() (integer?),
        is_open()/has_items() (bool), close() (clears items/selected/open + no-op render).
        S32 does NOT touch menu.lua — the windowless state layer (S31) is the accept authority."
  pattern: "on_enter gate order: is_open() AND has_items() AND type(get_selected())=='table'.
            accept reads prefix from get_prefix() and buf from get_buf() (the menu owns both —
            set by S31's on_results from the same getSuggestions payload)."
  gotcha: "menu.close() is STATE-clear + a no-op render until S34 (the floating window). S32 is
           fully testable via state + buffer assertions WITHOUT a popup. Do NOT call nvim_win_close
           in accept (that is S34's job inside menu's render())."

- file: plugin/lua/pi-editor/coords.lua
  why: "THE centralized coordinate seam S32 routes BOTH conversions through (PRD §8 'MUST be
        centralized'). nvim_to_pi_coords(lines, row, byte_col) → {lines, cursorLine=row-1,
        cursorCol=<utf16>}; pi_to_nvim_coords(lines, cursorLine, cursorCol) → {lines, row, col}
        where col is 0-based BYTE ready for nvim_win_set_cursor UNCHANGED."
  pattern: "accept: `local pi = coords.nvim_to_pi_coords(lines, cur[1], cur[2])` then params =
            {lines=pi.lines, cursorLine=pi.cursorLine, cursorCol=pi.cursorCol, item=item,
            prefix=prefix}. cb: `local nv = coords.pi_to_nvim_coords(result.lines,
            result.cursorLine, result.cursorCol)` then nvim_win_set_cursor(0, {nv.row, nv.col})."
  gotcha: "CRITICAL — NO `-1` on the cursor col. The coords.lua [Mode A] header EXPLICITLY
           documents that PRD §7.4 step 4's `bytecol - 1` is SUPERSEDED (it would nudge the
           cursor one byte LEFT on every accept, worst on multibyte lines). nv.col is already
           the 0-based byte value nvim_win_set_cursor expects. A reader of PRD §7.4 should not
           be surprised by the absent -1 — that is why the coords.lua note exists."

- file: plugin/lua/pi-editor/bridge.lua
  why: "THE RPC layer. Read the [Mode A] S26 block: M.request(method, params, cb) -> string|nil
        (cb is `function(err, result)` resolved EXACTLY ONCE by response/timeout/cancel/close,
        schedule_wrap'd → api-safe; returns the id or nil). The TWO-LAYER design: the `pending`
        map holds EVERY concurrent outstanding request — applyCompletion racing getSuggestions
        each resolve to their OWN cb. Supersession is the CALLER's job."
  pattern: "accept: `bridge.request('applyCompletion', params, function(err, result) … end)`.
            The cb runs on the nvim main loop (schedule_wrap'd at store time) → call
            nvim_buf_set_lines/nvim_win_set_cursor/menu.close DIRECTLY (no extra vim.schedule)."
  gotcha: "applyCompletion on the SERVER is SYNC (a pure fn, no AbortController —
           makeApplyCompletionHandler) but the RPC is ASYNC on ours (a socket round-trip). The
           cb lands in <2s (config.rpc_timeout_ms, default 2000). on_enter returns true as soon
           as the RPC is ISSUED (CR consumed); the buffer mutation is async. If the bridge
           returns nil (not connected / bad args) → accept returns false → on_enter returns
           false → CR falls through to a newline (degrade; menu wouldn't be open if bridge down)."

- file: extension/protocol.ts
  why: "THE wire shapes (authoritative). ApplyCompletionParams {lines, cursorLine, cursorCol,
        item: AutocompleteItem, prefix}; ApplyCompletionResult {lines, cursorLine, cursorCol}.
        item is forwarded VERBATIM (the whole AutocompleteItem table — {value,label,description?,…})."
  pattern: "Build params as a Lua table with EXACTLY those keys. vim.json.encode (called inside
            bridge.send) serializes the item table + lines array fine. result.lines is the
            COMPLETE new line array → nvim_buf_set_lines wholesale."
  gotcha: "result may be nil/vim.NIL on a null (the bridge normalizes vim.NIL→nil; cb(nil,nil)).
           Treat a non-table result as 'degrade: menu.close, buffer untouched' (defensive —
           applyCompletion should always return a result, but never trust the wire)."

- file: plugin/lua/pi-editor/init.lua
  why: "READ ONLY (S32 does NOT modify it). Confirms `require('pi-editor').bridge` is the
        published bridge (set by handshake on success; nil otherwise) + `require('pi-editor').config`
        holds the resolved config (rpc_timeout_ms). accept reads the bridge fresh from here."
  pattern: "`local bridge = require('pi-editor').bridge` inside accept (read fresh — see gotcha
            in completion.lua). `if not bridge or not bridge.is_connected() then return false end`."

- file: plugin/ftplugin/pi-prompt.lua
  why: "READ ONLY (S32 does NOT modify it — it ALREADY dispatches on_enter). Confirms the <CR>
        wiring: `map_dispatch('i','<CR>','pi-editor.completion','on_enter')` → if on_enter
        returns truthy, CR is CONSUMED; else `feedkey('<CR>')` inserts a NEWLINE. Also documents
        the no-Enter-to-submit rule (PRD §7.4): quitting submits, not <CR>."
  pattern: "on_enter(buf) must return `true` ONLY when it accepts (so the CR is consumed); return
            `false` (or nil) to fall through to a newline. buf is the pi-prompt buffer handle
            (buffer-local keymap). The dispatch is pcall-wrapped in the ftplugin — on_enter never
            breaks the autocmd chain even if it throws (but be defensive anyway)."

- file: plugin/tests/completion_spec.lua
  why: "THE test style S32's accept/on_enter cases EXTEND. Read its `fake_bridge(opts)` helper
        (controllable request/cancel/is_connected + resolve(i,err,result)/resolve_last — the
        fake stores EVERY cb; applyCompletion's cb is fake.requests[#]) + the `win`/
        nvim_win_set_buf/virtualedit=onemore/nvim_win_set_cursor buffer-cursor setup + the
        vim.wait(ms,predicate,5) async idiom + reset() before_each/after_each. S32 ADDS a
        describe('accept/on_enter') block to THIS file (one-spec-per-module rule)."
  pattern: "local fake = fake_bridge(); pi.bridge = fake; local buf = nvim_create_buf(true,false);
            set_lines({'/mo'}); nvim_win_set_buf(win,buf); nvim_win_set_cursor(win,{1,3});
            menu.attach(); completion.refresh(buf); wait_for(200, ()=>#fake.requests>=1);
            fake.resolve_last(nil,{items={{value='/model',label='model'}},prefix='/mo'});
            wait_for(…); assert menu.is_open(); local ok=completion.on_enter(buf); assert(ok);
            assert.are.equals('applyCompletion', fake.requests[#].method); …"
  gotcha: "Do NOT name a spec-local table `pending` (shadows plenary's skip fn — use `got`/`reqs`).
           Drive menu state via REAL menu.attach()+completion.refresh()+a getSuggestions reply so
           on_enter sees a populated menu (don't hand-set menu state). Set virtualedit=onemore so
           the cursor can sit at EOL (byte col 3 for '/mo')."

- file: plugin/tests/menu_smoke.lua
  why: "THE plenary-free smoke bootstrap S32's completion_accept_smoke.lua MIRRORS. Read its
        fake luv unix-socket server (unique path, jreader, hello reply, controlled getSuggestions
        reply) + REAL bridge.handshake + completion + menu.attach() + the check/fails/cquit/
        SMOKE_PASS footer. S32's smoke ADDS: after the menu is populated, call on_enter, observe
        applyCompletion on the server, reply {lines,cursorLine,cursorCol}, assert buffer+cursor."
  pattern: "Server's jsonlreader cb: branch on req.method — 'hello'→reply ok; 'getSuggestions'→
            reply {items,prefix}; 'applyCompletion'→ reply {lines=…,cursorLine=…,cursorCol=…} +
            stash the observed req for the assertion. vim.wait between each step. Print SMOKE_PASS."

- file: plugin/tests/bridge_request_spec.lua
  why: "THE fake-server pattern (with_request_server) if the smoke needs a more elaborate server
        (e.g. the dup/stale/error modes). S32's smoke is simpler (echo-style replies) but the
        bind/accept/read_start/jreader skeleton is identical to menu_smoke — reuse menu_smoke's."

- file: plan/001_c56962b4fa17/P2M7T19S32/research/notes.md
  why: "THE consolidated research (this task). §1 (the S32 contract verbatim + the S36 placement
        decision: completion.lua's accept() calls menu.get_selected()+menu.close()); §2 (the wire
        shapes + the server SYNC-delegation); §3 (the coords contract + the NO-`-1` supersession);
        §4 (the menu accessors); §5 (THE nvim insert-mode accept semantics — no TextChangedI loop,
        stay-Insert, no feedkeys/redraw, the blink/cmp reference); §6 (the async cb + TWO-LAYER
        bridge + the optional accepting flag); §7 (test strategy); §8 (non-regression/scope)."
  section: "all; esp. §3 (NO -1), §5 (nvim semantics), §6 (async cb)."

- docfile: PRD.md
  why: "§7.4 (the 5-step accept flow — the requirement), §4 step 5 + §6.5 (pi computes insertion;
        the plugin applies the WHOLE new buffer), §5.4 (the applyCompletion method row), §8 (the
        coordinate contract), §11 (one pi-prompt buffer per session)."
  section: "§7.4 (heading:h3.20); §8 (heading:h2.8); §5.4 (heading:h3.8); §6.5 (heading:h3.14)"
  gotcha: "PRD §7.4 step 4's `bytecol - 1` is SUPERSEDED by coords.lua's exact-UTF-16 +
           0-based-byte-cursor-API design (research §3 / coords.lua header). Do NOT subtract 1.
           PRD §7.4 step 5 'stay in insert mode' = do NOT feedkeys (<Esc>/<i>) — the two-API-call
           sequence keeps mode() unchanged (:help mode, research §5 Q5)."
```

### Current Codebase tree (run `tree` in the root of the project) to get an overview of the codebase

```bash
$ cd /home/dustin/projects/pi-nvim-bridge && tree -L 3 plugin plan/001_c56962b4fa17/architecture plan/001_c56962b4fa17/P2M7T19S32
plugin
├── ftplugin/pi-prompt.lua                 # buffer-local setup (S22, COMPLETE) — ALREADY dispatches on_enter (<CR>) + refresh autocmds + autosave. S32 DOES NOT touch it.
├── lua/pi-editor/
│   ├── bridge.lua                         # socket client + handshake + RPC (S24-S27, COMPLETE) — request(method,params,cb)/cancel/is_connected (TWO-LAYER pending map)
│   ├── completion.lua                     # per-keystroke TRIGGER (S30, COMPLETE) — refresh/debounce/fetch/supersede + on_results + current(). S32 ADDS accept(item)+on_enter(buf) HERE.
│   ├── coords.lua                         # nvim_to_pi_coords / pi_to_nvim_coords (S28/S29, COMPLETE) — pi_to_nvim_coords returns col = 0-based BYTE (NO -1)
│   ├── init.lua                           # setup() + VimEnter gate + activate() (S19-S21, COMPLETE) — publishes require("pi-editor").bridge
│   ├── menu.lua                           # windowless menu-STATE (S31, COMPLETE) — get_selected/get_prefix/get_buf/is_open/has_items/close. S32 READS it (+ close()).
│   └── jsonlreader.lua                    # JSONL framing (S23, COMPLETE)
├── plugin/pi-editor.lua                   # VimEnter auto-activation shim (S20, COMPLETE)
└── tests/
    ├── minimal_init.lua                   # plenary harness (S19; reused UNCHANGED)
    ├── completion_spec.lua                # fake_bridge helper + full-flow async style — S32 EXTENDS this with a describe("accept/on_enter") block
    ├── completion_smoke.lua               # plenary-free smoke style (S30)
    ├── menu_spec.lua + menu_smoke.lua     # the menu MODULE tests (S31) — the smoke bootstrap S32's smoke mirrors
    ├── bridge_request_spec.lua            # with_request_server fake-server pattern (S26)
    └── … (init/shim/activate/ftplugin/jsonlreader/bridge/handshake/notify/coords specs + smokes — all COMPLETE)
plan/001_c56962b4fa17/architecture/
├── external_deps.md                       # §1.2 (cursor API: nvim_win_get_cursor[2] / nvim_win_set_cursor col = 0-based BYTE) + §1.6 (autocmds)
└── research-pi-autocomplete.md            # applyCompletion handles ALL insertion edge cases; the 3 TUI call sites (editor.ts:669/690/2257) apply result.lines+cursor wholesale
plan/001_c56962b4fa17/P2M7T19S32/research/
└── notes.md                               # THE consolidated research for this task (§1-§8; esp. §3 NO-1, §5 nvim semantics, §6 async cb)
```

### Desired Codebase tree with files to be added and responsibility of file

```bash
plugin/lua/pi-editor/completion.lua              # MODIFY — ADD M.accept(item) + M.on_enter(buf) + update [Mode A] header (on_enter→shipped; new accept block)
plugin/tests/completion_spec.lua                 # EXTEND — add describe("accept/on_enter") block (fake_bridge; accept params + cb success/error + multibyte + on_enter gate + never-throws)
plugin/tests/completion_accept_smoke.lua         # NEW — plenary-free; fake luv server + real bridge + real completion + menu.attach; refresh→getSuggestions reply→menu populated→on_enter→server sees applyCompletion→reply{lines,cursor}→assert buffer+cursor+menu closed
```

### Known Gotchas of our codebase & Library Quirks

```lua
-- CRITICAL: NO "-1" on the accept cursor col. coords.pi_to_nvim_coords returns col = 0-based BYTE,
-- ready for nvim_win_set_cursor(0, {row, col}) UNCHANGED. PRD §7.4 step 4's `bytecol - 1` is
-- SUPERSEDED (coords.lua [Mode A] header — it would nudge the cursor one byte LEFT on every accept,
-- worst on multibyte lines). nvim_win_set_cursor's col is 0-based byte (external_deps.md §1.2) —
-- it matches coords DIRECTLY. (research/notes.md §3.)

-- CRITICAL: nvim_buf_set_lines does NOT fire TextChangedI (it is an API mutation, not typed input —
-- :help TextChangedI). => accept's buffer-replace CANNOT re-trigger the refresh autocmd; NO
-- re-entrancy guard is REQUIRED. Do NOT route the accept edit through feedkeys ("to trigger refresh")
-- — that WOULD fire TextChangedI + risk a loop. (research/notes.md §5 Q2.)

-- CRITICAL: STAY in Insert mode. nvim_buf_set_lines + nvim_win_set_cursor do NOT change mode()
-- (:help mode). Do NOT feedkeys("<Esc>")/("i") to "re-enter" Insert — you never left it. nvim_win_set_cursor
-- moves the VISIBLE cursor in Insert + scrolls into view WITHOUT a redraw/feedkeys nudge
-- (:help nvim_win_set_cursor). The sequence is TWO API calls in order (set_lines THEN set_cursor).
-- (research/notes.md §5 Q1/Q3/Q5 — the blink.cmp accept/init.lua + nvim-cmp core.lua reference.)

-- CRITICAL: insertion is PI'S JOB. applyCompletion returns the COMPLETE new lines[] + cursor (pi
-- computes trailing space / dir-vs-file / quotes / cursor reposition). S32 applies result.lines
-- WHOLESALE via nvim_buf_set_lines(buf,0,-1,false,nv.lines) — it NEVER string-replaces the prefix
-- in-place (that would diverge from the TUI on edge cases). (PRD §4 step 5 / §6.5; research §2.)

-- CRITICAL: the accept cb is ASYNC. bridge.request returns immediately (the cb lands later, on the
-- nvim main loop — it is schedule_wrap'd by the bridge). on_enter must return true (CR consumed) as
-- soon as the RPC is ISSUED; the buffer mutation happens in the cb. applyCompletion is SYNC on the
-- SERVER (a pure fn — makeApplyCompletionHandler) but the RPC round-trip is async on ours (<2s).

-- CRITICAL: applyCompletion is a ONE-SHOT user action — NO generation-id supersession guard (unlike
-- getSuggestions's two-layer cancel+gen-guard). Capture buf in the closure; in the cb validate buf
-- is still valid+current; apply. If the user typed between issue+cb, the accept result is AUTHORITATIVE
-- (the user explicitly accepted) — overwriting interim typing is the correct pi-faithful behavior.
-- The bridge's TWO-LAYER pending map holds applyCompletion + getSuggestions separately (they never
-- mis-drop each other). (research/notes.md §6; bridge.lua [Mode A] S26 block.)

-- CRITICAL: cb ERROR → degrade (buffer UNTOUCHED + menu.close + never throw). On "rpc error …" /
-- "request timeout" / "connection closed": do NOT nvim_buf_set_lines; the user's interim text stays;
-- menu.close() (the selection is stale). Silent degrade — S39's job to notify once.

-- READ bridge/menu/coords FRESH inside accept (NOT module-load locals): `local bridge =
-- require("pi-editor").bridge` / `require("pi-editor.menu")` / `require("pi-editor.coords")`.
-- (Same rule as completion.lua do_refresh — handshake resolves async + tests swap fakes after require
-- + a /reload re-runs activate().) coords is stateless so a local is fine, but reading fresh is uniform.

-- on_enter RETURN CONTRACT: return true ONLY when accept is issued (so the ftplugin CONSUMES the CR);
-- return false/nil otherwise (the ftplugin feedkey("<CR>") inserts a NEWLINE — PRD §7.4 no-Enter-to-submit;
-- quitting submits). Gate order: buf valid+current AND menu.is_open() AND menu.has_items() AND
-- type(menu.get_selected())=="table". (The ftplugin dispatch is pcall-wrapped — on_enter never breaks
-- the chain — but be defensive: every nvim call pcall'd.)

-- ONE-BUFFER-PER-SESSION (PRD §11): accept reads nvim_win_get_cursor(0) (the CURRENT window). Guard
-- `buf == nvim_get_current_buf()` (mirror do_refresh) so a non-current buf is a silent bail, not a
-- wrong-cursor apply. menu.get_buf() should equal the current buf (both are the pi-prompt buffer).

-- OPTIONAL defensive flag (NOT required for correctness): a `state.accepting` boolean (set on RPC
-- issue, cleared in the cb) that lets do_refresh skip work during the narrow async race (user types
-- between issue + cb → a stale getSuggestions might populate the menu post-accept). The race is narrow
-- + self-corrects on the next keystroke; add the flag only if you observe flicker. If added, gate the
-- TOP of do_refresh: `if state.accepting then return end`. (research/notes.md §5 Q4 / §6.)

-- DO NOT implement on_tab — that is S33 (Tab = trigger/accept/insert-\t). S32 implements on_enter
-- (CR) ONLY + the SHARED accept(item) core S33 will call. The ftplugin's on_tab dispatch still returns
-- false (fall-through → Tab indents) until S33 lands — CORRECT for S32's scope.

-- DO NOT couple to the floating window. accept calls menu.close() (STATE clear + no-op render until
-- S34). Do NOT call nvim_win_close / nvim_buf_delete in accept (the menu WINDOW is S34's job inside
-- menu's render()). S32 is fully testable via state + buffer assertions WITHOUT a popup.

-- DO NOT modify menu.lua / bridge.lua / coords.lua / jsonlreader.lua / init.lua / the ftplugin / the
-- shim. S32's ONLY existing-source-file change is completion.lua (2 additive functions + header-doc
-- update). The ftplugin ALREADY dispatches on_enter — S32 just makes it return truthy.
```

## Implementation Blueprint

### Data models and structure

No new data models — S32 reuses the COMPLETE in-tree types. The `accept` cb consumes the
`ApplyCompletionResult` wire shape (`extension/protocol.ts`):

```lua
--- ApplyCompletionResult (mirror of extension/protocol.ts ApplyCompletionResult — the
--- pi→nvim direction). pi's applyCompletion returns the COMPLETE new buffer + cursor; S32
--- applies it wholesale. Delivered as the `result` arg of the bridge.request cb (cb(nil, result)).
---@class pi-editor.ApplyCompletionResult
---@field lines      string[] The COMPLETE new line array (replace buf wholesale).
---@field cursorLine integer 0-indexed pi line (coords.pi_to_nvim_coords adds +1).
---@field cursorCol  integer 0-indexed UTF-16 offset (coords.pi_to_nvim_coords → 0-based byte; NO -1).
```

The singleton `completion.lua` `state` table gains (OPTIONALLY, see the defensive-flag gotcha)
one field; the REQUIRED additions are the two methods:

```lua
-- (additive to the EXISTING completion.lua `state` — the OPTIONAL defensive flag; omit if you
--  do not gate do_refresh on it)
---@field accepting boolean OPTIONAL: true while an applyCompletion RPC is in-flight (a defensive
---                             gate for the narrow async race; NOT required for correctness — see
---                             research/notes.md §5 Q4). Defaults false; set in accept; cleared in cb.

--- The 5-step PRD §7.4 accept flow. Reads the selected item's prefix + buf from the COMPLETE menu
--- module (S31) + the CURRENT buffer lines + cursor, converts nvim→pi via coords (S29), issues
--- `applyCompletion` over the bridge (S26), and in the ASYNC cb converts pi→nvim + replaces the
--- WHOLE buffer + sets the cursor (NO -1) + closes the menu. NEVER reimplements insertion (pi does
--- it — returns the whole new lines[]). Returns true iff the RPC was issued (the cb is fire-and-forget).
--- Never throws (pcall-wrapped nvim + bridge/menu/coords read FRESH). cb error → degrade (buffer
--- untouched + menu.close). (research/notes.md §2/§3/§5/§6.)
---@param item pi-editor.AutocompleteItem The selected item (from menu.get_selected()) — forwarded VERBATIM.
---@return boolean issued true iff the applyCompletion RPC was accepted by the bridge.
function M.accept(item) … end

--- The <CR> handler (accept-or-newline; the ftplugin ALREADY dispatches on_enter). Returns true
--- (CR CONSUMED) iff buf is valid+current AND the menu is open with a table selected item → calls
--- M.accept(item). Otherwise returns false (the ftplugin feedkey("<CR>") inserts a NEWLINE — PRD §7.4:
--- no Enter-to-submit in the external editor; quitting submits). Never throws.
---@param buf integer The pi-prompt buffer handle (from the buffer-local <CR> keymap dispatch).
---@return boolean handled true iff CR was consumed (accept issued); false to fall through to a newline.
function M.on_enter(buf) … end
```

### Implementation Tasks (ordered by dependencies)

```yaml
Task 1: READ (do NOT edit yet) — anchor on the COMPLETE seam + the wire shapes + the nvim semantics
  - READ: plugin/lua/pi-editor/completion.lua  (the [Mode A] header esp. the FORWARD CONTRACTS block —
      "the 6 keymaps (on_tab/on_enter/…) stay absent; S30 implements refresh ONLY"; do_refresh's cb —
      the api-safe main-loop contract + the bridge-read-fresh rule accept MUST mirror; the singleton
      `state` table; M.current(); M.reset())
  - READ: plugin/lua/pi-editor/menu.lua  (the public surface S32 READS: get_selected/get_prefix/
      get_buf/is_open/has_items; the only WRITE: close(); confirm close() is state-clear + no-op render)
  - READ: plugin/lua/pi-editor/coords.lua  (nvim_to_pi_coords + pi_to_nvim_coords signatures; the
      [Mode A] header's CRITICAL "NO -1" / "PRD §7.4 bytecol-1 SUPERSEDED" note)
  - READ: plugin/lua/pi-editor/bridge.lua  (the [Mode A] S26 block: request(method,params,cb)->id|nil;
      cb(err,result) EXACTLY ONCE; schedule_wrap'd → api-safe; TWO-LAYER pending map)
  - READ: plugin/ftplugin/pi-prompt.lua  (the <CR> map_dispatch → on_enter; the feedkey fall-through;
      the no-Enter-to-submit rule. CONFIRM S32 does NOT touch it.)
  - READ: extension/protocol.ts  (ApplyCompletionParams {lines,cursorLine,cursorCol,item,prefix} /
      ApplyCompletionResult {lines,cursorLine,cursorCol})
  - READ: plugin/tests/completion_spec.lua  (fake_bridge(opts) + resolve/resolve_last + the win/buf/
      cursor setup + vim.wait idiom + reset() — S32's cases EXTEND this file)
  - READ: plugin/tests/menu_smoke.lua  (the fake luv server + REAL bridge + completion + menu.attach
      bootstrap — S32's smoke MIRRORS it + adds the applyCompletion round-trip)
  - READ: plan/001_c56962b4fa17/P2M7T19S32/research/notes.md  (★ §3 NO-1; §5 nvim semantics; §6 async cb;
      §7 test strategy; §8 scope/non-regression)
  - WHY: locks the contract (menu accessors; coords NO-1; bridge async cb + TWO-LAYER; wire shapes;
      the no-TextChangedI-loop / stay-Insert nvim semantics; the test discipline) before writing.

Task 2: MODIFY completion.lua — M.accept(item) (the core accept flow)
  - IMPLEMENT (additive; place after M.current() / before `return M`):
      * local menu   = require("pi-editor.menu")                     -- read FRESH
      * local bridge = require("pi-editor").bridge                   -- read FRESH
      * GUARD: type(item)~="table" → return false. (defensive; on_enter pre-checks but direct callers may not)
      * GUARD: not bridge / no is_connected / not bridge.is_connected() → return false (silent degrade)
      * local buf = menu.get_buf(); GUARD: type(buf)~="number" or not nvim_buf_is_valid(buf) → return false
      * GUARD: buf ~= nvim_get_current_buf() → return false (one-buf/session; cursor is for the current win)
      * local ok, lines = pcall(nvim_buf_get_lines, buf, 0, -1, false); if not ok → return false
      * local cur; ok, cur = pcall(nvim_win_get_cursor, 0); if not ok → return false
      * local pi = require("pi-editor.coords").nvim_to_pi_coords(lines, cur[1], cur[2])
      * local params = { lines=pi.lines, cursorLine=pi.cursorLine, cursorCol=pi.cursorCol,
                         item=item, prefix=(menu.get_prefix() or "") }
      * (OPTIONAL) state.accepting = true   -- defensive flag for the async race (clear in cb)
      * local issued = false
      * pcall(bridge.request, "applyCompletion", params, function(err, result)
          -- async, schedule_wrap'd by bridge → nvim main loop (api-safe; NO extra vim.schedule)
          (if state.accepting ~= nil then state.accepting = false end)   -- clear the optional flag
          if err then pcall(menu.close); return end                       -- DEGRADE: buffer UNTOUCHED
          if type(result) ~= "table" then pcall(menu.close); return end   -- malformed → degrade
          local nv = require("pi-editor.coords").pi_to_nvim_coords(
              result.lines, result.cursorLine, result.cursorCol)
          pcall(nvim_buf_set_lines, buf, 0, -1, false, nv.lines)          -- replace WHOLE buffer
          pcall(nvim_win_set_cursor, 0, { nv.row, nv.col })               -- col 0-based BYTE (NO -1)
          pcall(menu.close)                                               -- clear state (+ no-op render)
        end)
      * issued = true   -- the bridge accepted the request (fire-and-forget cb)
      * return issued
  - NAMING: `M.accept(item)` (matches the S32 contract + the S36 "completion.lua's accept()" reference).
  - NEVER THROWS: every nvim call pcall'd; bridge/menu/coords read fresh + type-guarded; bad args → false.
  - NO -1: nv.col is the 0-based byte value nvim_win_set_cursor expects (coords.lua header).

Task 3: MODIFY completion.lua — M.on_enter(buf) (the <CR> accept-or-newline handler)
  - IMPLEMENT (additive; place after M.accept):
      * if type(buf) ~= "number" or not vim.api.nvim_buf_is_valid(buf) then return false end
      * if buf ~= vim.api.nvim_get_current_buf() then return false end
      * local menu = require("pi-editor.menu")
      * if not menu.is_open() or not menu.has_items() then return false end
      * local item = menu.get_selected()
      * if type(item) ~= "table" then return false end
      * return M.accept(item) == true        -- true iff the RPC was issued (CR consumed)
  - RETURN CONTRACT: true ONLY on accept-issued (ftplugin consumes CR); false/nil otherwise
      (ftplugin feedkey("<CR>") → newline). (PRD §7.4: no Enter-to-submit; quitting submits.)
  - NEVER THROWS: pcall not strictly needed (the dispatch is pcall-wrapped in the ftplugin + the
      guards are pure type/validity checks), but M.accept is defensive anyway.

Task 4: MODIFY completion.lua — update the [Mode A] header
  - EDIT the FORWARD CONTRACTS block: move on_enter from "stay absent" to "shipped (S32)". Keep
    on_tab/on_next/on_prev/on_dismiss as forward contracts (S33/S36/S37).
  - ADD an `accept` [Mode A] block (mirror the density of the S30 block): the 5-step PRD §7.4 flow;
    the nvim insert-mode semantics (nvim_buf_set_lines does NOT fire TextChangedI → no loop;
    nvim_win_set_cursor moves the visible cursor in Insert + no redraw/feedkeys; stay-Insert via
    mode() unchanged); the NO-`-1` cursor (coords.lua supersession of PRD §7.4 bytecol-1); insertion
    is pi's job (apply result.lines wholesale); the async cb (schedule_wrap'd → api-safe; on_enter
    returns true on issue); the ONE-SHOT nature (no gen-guard; the TWO-LAYER bridge holds it
    separately from getSuggestions); cb error → degrade; read bridge/menu/coords fresh.
  - (OPTIONAL) if you add the `state.accepting` flag, document it in the header (defensive; the race
    it guards; clear in the cb).

Task 5: EXTEND plugin/tests/completion_spec.lua — describe("accept/on_enter", …) (reuse fake_bridge)
  - ADD a describe block AFTER the existing S30 cases (before the final `end)`). before_each/after_each
    already `reset()` (clears pi.bridge + on_results + completion state); ALSO `menu.reset()` to clear
    menu state, + `pcall(menu.attach)` if you drive the menu via the real seam (see pattern below).
  - CASE (1) accept issues applyCompletion with the exact params:
      * fake=fake_bridge(); pi.bridge=fake; buf=nvim_create_buf(true,false); set_lines({'/mo'});
        win=nvim_get_current_win(); nvim_win_set_buf(win,buf); virtualedit=onemore; cursor {1,3}.
      * menu.attach(); completion.refresh(buf); wait_for(200,()=>#fake.requests>=1);
        fake.resolve_last(nil,{items={{value='/model',label='model'}},prefix='/mo'}); wait_for(menu open).
      * assert menu.is_open() + menu.get_selected().value=='/model' + menu.get_prefix()=='/mo'.
      * local n0=#fake.requests; local ok=completion.accept(menu.get_selected()); wait_for(req).
      * assert ok==true; local req=fake.requests[#fake.requests]; assert req.method=='applyCompletion';
        assert same({'/mo'}, req.params.lines); assert equals(0, req.params.cursorLine);
        assert equals(3, req.params.cursorCol); assert same({value='/model',label='model'}, req.params.item);
        assert equals('/mo', req.params.prefix); assert is_nil(req.params.force)  -- NO force on apply.
      * nvim_buf_delete(buf,{force=true}); menu.reset().
  - CASE (2) cb success applies pi's result EXACTLY (incl. the cursor):
      * same setup; after accept, fake.resolve_last(nil,{lines={'/model '},cursorLine=0,cursorCol=7});
        wait_for(200,()=>menu.is_open()==false).
      * assert same({'/model '}, nvim_buf_get_lines(buf,0,-1,false)); assert same({1,7}, nvim_win_get_cursor(0));
        assert menu.is_open()==false.
  - CASE (2b) MULTIBYTE cursor is byte-correct (NO -1): set_lines({'/café'}); cursor at EOL (byte 5,
      utf16 4 via coords); after a reply with lines={'/cafér'} cursorCol=6 (utf16; byte 7) → assert
      nvim_win_get_cursor=={1,7} (byte, NOT 6). Proves the NO-1 + the utf16→byte conversion.
  - CASE (3) cb error → degrade: same setup; after accept, fake.resolve_last('rpc error -32603',nil);
      wait_for; assert buffer UNTOUCHED (still {'/mo'}) + menu.is_open()==false + no throw. Repeat with
      'request timeout'.
  - CASE (4) on_enter gate: menu open+selected → on_enter(buf)==true + an applyCompletion was issued;
      menu closed (menu.reset()/close()) → on_enter(buf)==false; buf not current (nvim_win_set_buf a
      2nd buf) → on_enter(buf)==false.
  - CASE (5) never-throws: completion.accept(nil); accept on a wiped buf; on_enter(nil); pi.bridge=nil
      → accept returns false (no throw).
  - DISCIPLINE: do NOT name a spec-local table `pending` (shadows plenary's skip fn — use `got`/`reqs`).
    Drive menu state via REAL menu.attach()+completion.refresh()+a getSuggestions reply (don't hand-set
    menu state — test the real seam). Reset menu + completion + pi.bridge in before/after_each.

Task 6: CREATE plugin/tests/completion_accept_smoke.lua (plenary-free; mirror menu_smoke.lua)
  - BOOTSTRAP: the menu_smoke.lua header (add plugin_root to rtp; require bridge/completion/menu/pi;
    self-sufficient setup({debounce_ms=5}); the fails/check/cquit/SMOKE_PASS footer).
  - SERVER: fake luv unix-socket server (unique path) + jreader. The server cb branches on req.method:
      'hello'→reply {ok=true,serverVersion='0.1.0',cwd=DESC_CWD,fdAvailable=true};
      'getSuggestions'→reply {items={{value='/model',label='model'}},prefix='/mo'} + stash nothing;
      'applyCompletion'→ stash the observed req (for the assertion) + reply
        {lines={'/model '},cursorLine=0,cursorCol=7}.
  - FLOW: handshake the REAL bridge (menu_smoke pattern); set up a real buf {lines={'/mo'}} as the
    current window buffer; cursor {1,3}; menu.attach(); completion.refresh(buf); vim.wait for the menu
    to open (menu.is_open()); completion.on_enter(buf); vim.wait for the server to see applyCompletion
    + for menu.is_open()==false.
  - ASSERTIONS (check): the server saw an applyCompletion with params.item.value=='/model' +
    params.prefix=='/mo' + params.lines=={'/mo'} + params.cursorLine==0 + params.cursorCol==3;
    nvim_buf_get_lines(buf,0,-1,false)=={'/model '}; nvim_win_get_cursor(0)=={1,7}; menu.is_open()==false.
  - TEARDOWN: menu.reset(); completion.reset(); bridge.close(); server stop (srv:close(); os.remove(path)).
  - FOOTER: if fails>0 then vim.cmd('cquit 1') end; io.stdout:write('SMOKE_PASS\n').
  - ⚠️ AGENTS.md: this is a FILE run via `nvim … +"luafile tests/completion_accept_smoke.lua" +qa` —
    NEVER pipe a heredoc into nvim stdin (hangs). Wrap in `timeout 60`.
```

### Implementation Patterns & Key Details

```lua
-- The accept flow (the EXACT sequence — research/notes.md §5 + §3):
function M.accept(item)
  if type(item) ~= "table" then return false end
  local bridge = require("pi-editor").bridge                       -- read FRESH
  if not bridge or type(bridge.is_connected) ~= "function" or not bridge.is_connected() then
    return false                                                    -- silent degrade (S39 notifies)
  end
  local menu = require("pi-editor.menu")                            -- read FRESH
  local buf  = menu.get_buf()
  if type(buf) ~= "number" or not vim.api.nvim_buf_is_valid(buf) then return false end
  if buf ~= vim.api.nvim_get_current_buf() then return false end    -- one buf/session (cursor is current-win)
  local ok, lines = pcall(vim.api.nvim_buf_get_lines, buf, 0, -1, false)
  if not ok or type(lines) ~= "table" then return false end
  local cur
  ok, cur = pcall(vim.api.nvim_win_get_cursor, 0)
  if not ok or type(cur) ~= "table" then return false end
  local coords = require("pi-editor.coords")
  local pi = coords.nvim_to_pi_coords(lines, cur[1], cur[2])        -- {lines, cursorLine, cursorCol(UTF-16)}
  local params = {
    lines = pi.lines, cursorLine = pi.cursorLine, cursorCol = pi.cursorCol,
    item = item, prefix = (menu.get_prefix() or ""),
  }
  -- (OPTIONAL defensive flag) state.accepting = true
  local issued = false
  pcall(bridge.request, "applyCompletion", params, function(err, result)
    -- (clear the optional flag) if state.accepting ~= nil then state.accepting = false end
    if err then pcall(menu.close); return end                       -- DEGRADE: buffer UNTOUCHED
    if type(result) ~= "table" then pcall(menu.close); return end   -- malformed → degrade
    local nv = coords.pi_to_nvim_coords(result.lines, result.cursorLine, result.cursorCol)
    pcall(vim.api.nvim_buf_set_lines, buf, 0, -1, false, nv.lines)  -- replace WHOLE buffer (NOT TextChangedI)
    pcall(vim.api.nvim_win_set_cursor, 0, { nv.row, nv.col })       -- col 0-based BYTE (NO -1); Insert-safe
    pcall(menu.close)                                               -- clear state (+ no-op render until S34)
  end)
  issued = true                                                     -- bridge accepted the request
  return issued
end

-- The <CR> handler (accept-or-newline; the ftplugin ALREADY dispatches on_enter):
function M.on_enter(buf)
  if type(buf) ~= "number" or not vim.api.nvim_buf_is_valid(buf) then return false end
  if buf ~= vim.api.nvim_get_current_buf() then return false end
  local menu = require("pi-editor.menu")
  if not menu.is_open() or not menu.has_items() then return false end
  local item = menu.get_selected()
  if type(item) ~= "table" then return false end
  return M.accept(item) == true                                     -- true iff RPC issued (CR consumed)
end
```

### Integration Points

```yaml
KEYMAPS:
  - file: plugin/ftplugin/pi-prompt.lua
  - status: "ALREADY WIRED (S22). map_dispatch('i','<CR>','pi-editor.completion','on_enter') →
    if on_enter returns truthy the CR is CONSUMED; else feedkey('<CR>') inserts a NEWLINE. S32
    does NOT touch the ftplugin — it makes completion.on_enter exist + return truthy on accept."

RPC:
  - method: "applyCompletion"
  - params: "{lines:string[], cursorLine:int(0-idx), cursorCol:int(0-idx UTF-16), item:AutocompleteItem, prefix:string}"
  - result: "{lines:string[], cursorLine:int(0-idx), cursorCol:int(0-idx UTF-16)}" (pi's new buffer + cursor)
  - server: "extension/pi-editor-bridge.ts makeApplyCompletionHandler (P1.M2.T6.S12, COMPLETE) —
    SYNC pure-fn delegation, no AbortController/timeout; forwards (…,item,prefix) VERBATIM, returns
    pi's result UNCHANGED."

COORDINATES:
  - "nvim→pi: coords.nvim_to_pi_coords(lines, row(1-idx), byte_col(0-idx)) → {lines, cursorLine, cursorCol(UTF-16)}"
  - "pi→nvim: coords.pi_to_nvim_coords(result.lines, result.cursorLine, result.cursorCol) → {lines, row(1-idx), col(0-idx BYTE)}"
  - "CURSOR: nvim_win_set_cursor(0, {nv.row, nv.col}) — NO -1 (PRD §7.4 bytecol-1 SUPERSEDED by coords.lua)."

MENU:
  - "READ: menu.get_selected() / get_prefix() / get_buf() / is_open() / has_items()  (S31, COMPLETE)"
  - "WRITE: menu.close()  (the ONLY menu mutation in S32 — clears items/selected/open + no-op render)"

STATE (completion.lua):
  - "OPTIONAL: state.accepting (bool) — a defensive flag for the narrow async race; NOT required for
    correctness (nvim_buf_set_lines does not fire TextChangedI). If added: set in accept, clear in cb,
    gate the top of do_refresh."
```

## Validation Loop

### Level 1: Syntax & Style (Immediate Feedback)

```bash
# No ruff/mypy (this is Lua). Use selene (lint) + stylua (format) if configured.
cd /home/dustin/projects/pi-nvim-bridge
# (optional, if selene/stylua are installed) — the repo ships stylua.toml/selene.yml per the S31 PRP.
# selene --config plugin/selene.yml plugin/lua/pi-editor/completion.lua
# stylua --check plugin/lua/pi-editor/completion.lua

# A fast parse check (NO plenary) — write nothing to nvim stdin (AGENTS.md hard rule):
timeout 30 nvim --headless --clean -u NORC -c 'set rtp+=.' \
  -c 'lua require("pi-editor.completion"); print("parse-ok")' -c 'qa'
echo "exit=$?   # 0 = the module parses + require resolves"
# Expected: prints `parse-ok`, exit 0. (Run from plugin/ so 'pi-editor' resolves via rtp+=.)
```

### Level 2: Unit Tests (Component Validation — the plenary spec)

```bash
cd /home/dustin/projects/pi-nvim-bridge/plugin
# The S32 accept/on_enter cases (the additive describe block in completion_spec.lua):
timeout 90 nvim --headless --clean -u tests/minimal_init.lua \
  -c 'lua require("plenary.busted").run("tests/completion_spec.lua")'
echo "exit=$?   # 0 = all completion cases pass (S30 refresh/debounce/supersession + S32 accept/on_enter)"

# Full suite (non-regression — every prior spec must stay green):
for spec in init_spec shim_spec activate_spec ftplugin_spec jsonlreader_spec bridge_spec \
            bridge_handshake_spec bridge_request_spec bridge_notify_spec coords_spec \
            completion_spec menu_spec; do
  echo "--- $spec ---"
  timeout 90 nvim --headless --clean -u tests/minimal_init.lua \
    -c "lua require('plenary.busted').run('tests/${spec}.lua')" || echo "FAIL: $spec"
done
# Expected: every spec exits 0 (non-regression).
```

### Level 3: Integration Testing (the plenary-free smoke — real bridge + real completion + menu)

```bash
cd /home/dustin/projects/pi-nvim-bridge/plugin
# S32's NEW smoke: a fake luv server + REAL bridge.handshake + REAL completion + menu.attach;
# refresh → getSuggestions reply → menu populated → on_enter → server sees applyCompletion →
# reply {lines,cursor} → assert buffer + cursor + menu closed.
timeout 60 nvim --headless --clean -u NORC +"luafile tests/completion_accept_smoke.lua" +qa
echo "exit=$?   # 0 = pass (prints 'SMOKE_PASS'), 1 = a check failed"
# Expected: prints `SMOKE_PASS`, exit 0.
# ⚠️ AGENTS.md: this is a FILE + :luafile — NEVER pipe a heredoc into nvim stdin (it HANGS).
```

### Level 4: End-to-End Manual Check (optional — the real pi ↔ nvim round-trip)

```bash
# (Optional / manual — only if the bridge extension is installed + a real pi session is running.)
# In pi: press Ctrl+G to open $EDITOR; type `/mo`; confirm the menu (state — window is S34) selects
# /model; press <CR>; the buffer should become `/model ` with the cursor after the space.
# (Until S34 lands there is no visible popup, but the <CR> accept works + the buffer updates.)
# Automated equivalent: the Level-3 smoke IS the E2E proof (real bridge + real completion + the
# applyCompletion round-trip). Do NOT invent a stdin-based nvim check (AGENTS.md hard rule).
```

## Final Validation Checklist

### Technical Validation

- [ ] Level 1 parse check passes (the module require resolves; exit 0).
- [ ] Level 2: `completion_spec.lua` exits 0 (the additive `accept/on_enter` cases pass).
- [ ] Level 2 non-regression: every prior spec (init/shim/activate/ftplugin/jsonlreader/bridge/
      handshake/request/notify/coords/completion/menu) exits 0 unchanged.
- [ ] Level 3: `completion_accept_smoke.lua` prints `SMOKE_PASS` + exit 0.
- [ ] (If selene/stylua configured) zero lint/format errors on `completion.lua`.

### Feature Validation

- [ ] `accept(item)` issues `applyCompletion` with the EXACT params shape (`{lines, cursorLine,
      cursorCol, item, prefix}` — no `force`).
- [ ] cb SUCCESS → buffer replaced WHOLESALE with `result.lines` + cursor at `{result.cursorLine+1,
      <byte col>}` (NO `-1`) + `menu.is_open()==false`.
- [ ] MULTIBYTE result positions the cursor at the exact BYTE offset (proves the NO-`-1` + the
      utf16→byte conversion).
- [ ] cb ERROR → buffer UNTOUCHED + `menu.is_open()==false` + never throws (silent degrade).
- [ ] `on_enter(buf)` returns `true` iff buf valid+current AND menu open+table-selected (accept
      issued); `false` otherwise (CR → newline fall-through).
- [ ] User STAYS in Insert mode after accept (no feedkeys/`<Esc>`/`<i>` dance).
- [ ] No `TextChangedI` re-entrancy loop (API mutations don't fire it).
- [ ] `accept`/`on_enter` never throw on bad args + when bridge/menu/coords absent.
- [ ] The [Mode A] header is updated (on_enter→shipped; new accept block with the NO-`-1` + nvim
      insert-mode notes).

### Code Quality Validation

- [ ] Follows the existing codebase patterns: singleton `state` (mirrors bridge/menu/completion);
      read bridge/menu/coords FRESH inside the fn; pcall every nvim call (never-throws contract);
      LuaCATS annotations on `accept`/`on_enter` (match bridge.lua/completion.lua's density).
- [ ] Additive to `completion.lua` (S30 `refresh`/`reset`/`current`/`do_refresh`/`on_results`
      unchanged); the spec extension is additive (S30 cases stay green; `reset()` before/after_each).
- [ ] Anti-patterns avoided (see below): no in-place prefix string-replace; no `-1`; no feedkeys
      mode-dance; no TextChangedI routing; no window coupling; no on_tab (S33).
- [ ] Dependencies properly managed: only the in-tree bridge/coords/menu/pi modules; no new requires
      beyond what's in-tree; no new runtime files beyond the smoke.

### Documentation & Deployment

- [ ] The [Mode A] header docstring explains the 5-step PRD §7.4 accept flow + the nvim insert-mode
      semantics (no TextChangedI loop; stay-Insert; NO `-1`; insertion is pi's job; the async cb).
- [ ] No new env vars / config keys (accept reads the EXISTING `rpc_timeout_ms` via the bridge; no
      new setup() option).
- [ ] The smoke's SMOKE_PASS footer + the AGENTS.md `:luafile`-from-a-file discipline are followed.

---

## Anti-Patterns to Avoid

- ❌ Don't reimplement insertion (trailing space / dir-vs-file / quotes) — pi's `applyCompletion`
  returns the WHOLE new `lines`; apply it wholesale via `nvim_buf_set_lines`. In-place prefix
  string-replacement diverges from the TUI on edge cases.
- ❌ Don't subtract `1` from the cursor col — `coords.pi_to_nvim_coords` returns the 0-based byte
  value `nvim_win_set_cursor` expects (PRD §7.4 `bytecol - 1` is SUPERSEDED).
- ❌ Don't `feedkeys("<Esc>")`/`("i")` to "re-enter" Insert — `nvim_buf_set_lines` +
  `nvim_win_set_cursor` don't change `mode()`; you never left Insert.
- ❌ Don't route the accept edit through `feedkeys` "to trigger refresh" — that fires `TextChangedI`
  + risks a loop. `nvim_buf_set_lines` (API) is loop-free by design.
- ❌ Don't add a generation-id supersession guard to `accept` — it's a ONE-SHOT user action (unlike
  `getSuggestions`). The bridge's TWO-LAYER pending map already isolates it.
- ❌ Don't couple to the floating window (`nvim_win_close`) — call `menu.close()` (state); the window
  is S34's job inside `menu`'s `render()`.
- ❌ Don't implement `on_tab` — that's S33 (Tab = trigger/accept/insert-`\t`). S32 ships `on_enter`
  (CR) + the SHARED `accept(item)` core.
- ❌ Don't modify `menu.lua`/`bridge.lua`/`coords.lua`/the ftplugin/init/shim — S32's only
  existing-source-file change is `completion.lua` (additive). The ftplugin ALREADY dispatches `on_enter`.
- ❌ Don't catch-all `pcall(function() … end)` wrapping the whole accept — pcall the individual nvim
  calls (so a partial failure degrades cleanly) + read bridge/menu/coords fresh + type-guard.
- ❌ Don't trust a non-table `result` from the cb (a null/malformed response) — `menu.close()` +
  degrade (buffer untouched). Be defensive on the wire.