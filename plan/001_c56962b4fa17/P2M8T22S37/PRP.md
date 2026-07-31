# PRP — P2.M8.T22.S37: Auto-close on InsertLeave, CursorMoved out of prefix, buffer change

**Parent task:** P2.M8.T22 (menu.lua — navigation, key handling & lifecycle)
**Module:** P2.M8 (Floating Completion Menu) — Neovim (Lua) side
**Plan path:** `plan/001_c56962b4fa17/P2M8T22S37/`
**Scope:** ONLY S37 (the AUTOCMD-driven auto-close half). S31 (state), S34 (window), S35
(two-column/highlights), S36 (navigation + KEY handlers — `on_next`/`on_prev`/`on_dismiss`) are
**COMPLETE.** S37 wires the AUTOCMDS that hide the menu when the user LEAVES the completion
context (insert mode, the buffer) — NOT a keypress. It does NOT add menu/window/accept code.

**The key design decision (see research/notes.md §3):** of the three named triggers, **two are
genuine gaps** S37 must add (`InsertLeave`, `BufLeave`), and **one is ALREADY handled
pi-faithfully** by the COMPLETE S30 refresh path (`CursorMovedI → re-fetch → empty → close`).
S37 VERIFIES + DOCUMENTS the third (with a test) but does **NOT** reimplement a local
prefix/keyword-bounds detector (that would reimplement pi's completable-position logic — the
codebase's #1 anti-pattern: "NEVER reimplement pi's logic locally").

---

## Goal

**Feature Goal:** Make the floating completion menu **auto-hide on lifecycle transitions** the
user triggers by leaving the completion context — pressing `<Esc>`/`<C-\><C-n>` (insert leave),
or switching buffers (`:bnext`, `:e file`, split-to-another-buffer) — by wiring two buffer-local
autocmds (`InsertLeave`, `BufLeave`) that each call a new completion handler closing the menu +
**cancelling the pending debounced refresh** (the critical race fix: without it a stale
`do_refresh` would re-open the menu in normal mode). The third named trigger — "CursorMoved out
of prefix" — is OWNED by the existing `CursorMovedI → refresh → re-fetch → empty → close` path
(S30, COMPLETE); S37 verifies it with a test and documents it, but adds **no local prefix
detector** (pi-faithfulness: pi decides completable-position; we render).

**Deliverable:**
1. In `plugin/lua/pi-editor/completion.lua` (an EXISTING file — **edit, do not rewrite**):
   - ADD a LOCAL `hide_and_cancel()` helper: `menu.close()` (hide the window FIRST) then `M.reset()`
     (cancel the debounce timer + cancel/supersede the in-flight RPC via `state.gen=0` so its stale
     cb's gen-guard drops it + clear `last_result`/`buf`). This IS the §1 race fix.
   - ADD two PUBLIC fire-and-forget handlers (autocmd callbacks; return value IGNORED — NOT keymap
     handlers, so NO bool return):
     - `M.on_insert_leave(buf)` — gate (`type(buf)=="number" and nvim_buf_is_valid(buf)`) →
       `hide_and_cancel()`.
     - `M.on_buf_leave(buf)` — same gate → `hide_and_cancel()` (clearing `state.buf`/`last_result`
       is correct since we left the buffer; the next `refresh` rebuilds).
   - UPDATE the completion.lua header comment: mark `on_insert_leave`/`on_buf_leave` as S37-SHIPPED
     (the `reset()` docstring ALREADY names "the future S37 InsertLeave/CursorMoved-out wiring").
2. In `plugin/ftplugin/pi-prompt.lua` (an EXISTING file — **edit, do not rewrite**):
   - ADD two buffer-local autocmd registrations in the existing `"pi-editor"` augroup (after the
     refresh loop, before the autosave block): `InsertLeave` → `dispatch("pi-editor.completion",
     "on_insert_leave", buf)`; `BufLeave` → `dispatch("pi-editor.completion", "on_buf_leave", buf)`.
     Reuse the EXISTING `group` + `dispatch` + the `nvim_clear_autocmds({buffer=buf, group=...})`
     idempotency line (already in place). NO new augroup, NO new helper, NO new option.
   - UPDATE the FORWARD CONTRACTS doc block to name `on_insert_leave`/`on_buf_leave` + note the
     "CursorMoved out of prefix" is owned by the existing refresh path.
3. UPDATE `plugin/tests/completion_spec.lua` (plenary) — ADD two `describe` blocks:
   - `describe("S37: on_insert_leave / on_buf_leave")`: populated-menu → handler → menu closed +
     `completion.current()==nil`; closed-menu/nothing-pending → harmless no-op; **THE RACE FIX**
     (refresh-then-immediately-leave → stale `do_refresh` does NOT re-open + no new RPC issued);
     inflight-supersession (resolve a pending req AFTER leave → menu does NOT re-open, gen-guard
     dropped the cb); never-throws on nil/wiped buf.
   - `describe("S37: CursorMoved-out-of-prefix closes via refresh")`: populated menu → move cursor
     out of prefix → fire `CursorMovedI`/`refresh` → resolve empty → `menu.is_open()==false`
     (proves the EXISTING S30 path owns the third trigger — no local detector).
4. UPDATE `plugin/tests/ftplugin_spec.lua` (plenary) — assert `InsertLeave` + `BufLeave` autocmds
   are registered in the `"pi-editor"` buffer-local group (mirror the existing refresh-autocmd
   assertion), + a "does not throw when firing InsertLeave/BufLeave with completion.lua absent" case.
5. CREATE `plugin/tests/menu_autoclose_smoke.lua` (plenary-free) — real fake-bridge + real
   `bridge.handshake` + `menu.attach()`. Flow: `refresh("/mo")` → reply items → menu open → simulate
   `InsertLeave` via `nvim_exec_autocmds("InsertLeave", {buffer=buf})` → menu + window closed →
   re-open → simulate `BufLeave` → closed → re-open → move cursor out of prefix + `CursorMovedI` →
   reply empty → closed (the §3 path). Print SMOKE_PASS.

**Success Definition:**
- With the menu open, pressing `<Esc>` (→ `InsertLeave`) hides the menu + its floating window
  immediately, AND a pending debounced refresh does NOT re-open it in normal mode (the §1 race fix).
- With the menu open, switching buffers (`:bnext`/`:e`/split-to-another, → `BufLeave`) hides the
  menu + window + tears down the completion state for the left buffer.
- With the menu open, moving the cursor OUT of the completable prefix in insert mode (→
  `CursorMovedI` → `refresh` → pi returns empty) hides the menu — via the EXISTING S30 path (S37
  verifies this; no local detector).
- `on_insert_leave` / `on_buf_leave` NEVER throw (autocmd chain); bad args / wiped buf / closed menu
  / nothing-pending are silent no-ops (`menu.close()` + `M.reset()` are idempotent + pcall-safe).
- The handlers do NOT detach the menu's `on_results` seam (`M.reset()` is completion's, not menu's) —
  re-entering insert / a new pi-prompt buffer re-populates the menu with NO re-attach.
- The full test suite (`completion_spec`, `ftplugin_spec`, `menu_autoclose_smoke`, + every sibling
  spec/smoke) runs green headlessly; the plugin stays dormant in non-pi nvim sessions.

---

## All Needed Context

### Context Completeness Check

> "If someone knew nothing about this codebase, would they have everything needed to implement this successfully?"

**Yes.** This PRP embeds: the exact files to edit (`completion.lua`, `ftplugin/pi-prompt.lua`), the
exact handlers to add (`on_insert_leave`/`on_buf_leave`) + the exact 2 autocmds to add
(`InsertLeave`, `BufLeave`), the **live-verified** `M.reset()` teardown that ALREADY cancels the
debounce + in-flight RPC (its docstring promises it for S37), the §1 stale-debounce re-open race
this fixes, the blink.cmp reference (`on_insert_leave → hide()`), the pi-faithful ownership of the
"CursorMoved out of prefix" trigger by S30's refresh (with the why-not-reimplement argument), the
copy-paste-ready handler + autocmd reference impls, and the exact validation commands. The
implementing agent edits TWO existing files using reference implementations + adapts two test files
+ adds one smoke. There is NO new menu/window/highlight/IPC/accept code — S37 is purely additive
autocmd wiring + two thin fire-and-forget handlers.

### Documentation & References

```yaml
# ── THIS PRP's research (READ FIRST — the consolidated evidence) ──
- file: plan/001_c56962b4fa17/P2M8T22S37/research/notes.md
  why: The consolidated S37 research: the S30/S31/S34/S36 baseline S37 builds on (§0), THE #1 bug —
       the stale-debounce re-open race — + the exact fix via M.reset() (§1), the blink.cmp
       on_insert_leave→hide reference (§2), the "CursorMoved out of prefix" is OWNED by S30's
       refresh (§3 — the key design decision), the BufLeave-vs-WinLeave choice (§4), the autocmd
       wiring (§5), the handler design (§6), why one shared teardown (§7), the testing strategy
       (§8), the gotchas (§9).
  critical: §1 (the race fix — MUST call M.reset()), §3 (do NOT reimplement a prefix detector —
       it's owned by S30's refresh), §6 (hide FIRST then reset; never detach the menu).

# ── PRIOR PRPs (the contracts S37 builds on) ──
- file: plan/001_c56962b4fa17/P2M8T22S36/PRP.md
  why: The S36 sibling (navigation + KEY handlers). S37 is its complement: S36 added the KEY handlers
       (on_next/on_prev/on_dismiss); S37 adds the AUTOCMD handlers (on_insert_leave/on_buf_leave).
       Same gating-skeleton convention (gate → delegate), same never-throws contract, same
       read-menu-FRESH rule, same test conventions (fake_bridge + populated_menu + nvim_exec_autocmds),
       same AGENTS.md HARD RULE.
- file: plan/001_c56962b4fa17/P2M7T18S30/PRP.md
  why: S30 owns the refresh path (CursorMovedI→refresh→re-fetch→empty→close) that OWNS the
       "CursorMoved out of prefix" trigger (§3). S37's on_insert_leave/on_buf_leave REUSE M.reset()
       (S30's cleanup seam — its docstring promises it for "the future S37 InsertLeave/CursorMoved-out
       wiring"). Confirms cancel_timer stop+close (the leak fix) + the gen-guard supersession.

# ── THE FILES YOU EDIT (read fully first) ──
- file: plugin/lua/pi-editor/completion.lua
  why: S37 ADDS on_insert_leave/on_buf_leave + the local hide_and_cancel(). Read: M.reset() (THE
       teardown — cancel_timer + bridge.cancel(inflight) + gen=0 + clear state; its docstring names
       S37), cancel_timer() LOCAL (the stop+close leak fix), state fields (buf/debounce_timer/gen/
       inflight_id/last_result), do_refresh (the debounced body + its gen-guard cb — the stale one the
       race fix must drop), the on_enter/on_next gating skeleton (S32/S36 — the model, but S37's
       handlers are fire-and-forget, NO bool return), M.on_results (nil today; set by menu.attach).
  pattern: M.reset() (the teardown body); the on_enter/on_next gate (lines ~"function M.on_next(buf)").
- file: plugin/ftplugin/pi-prompt.lua
  why: S37 ADDS 2 autocmd registrations. Read: the `group = nvim_create_augroup("pi-editor",
       {clear=false})` (SHARED with S20 — do NOT clear=true), the `nvim_clear_autocmds({buffer=buf,
       group="pi-editor"})` idempotency line, the `dispatch(modname, fnname, buf)` helper (no-op-safe
       against absent modules), the refresh autocmd loop ({InsertEnter,TextChangedI,CursorMovedI}→refresh),
       the autosave loop (VimLeavePre/ExitPre→bridge.on_exit). S37's autocmds go BETWEEN those two loops.
  pattern: the existing `vim.api.nvim_create_autocmd(ev, { group=group, buffer=buf, desc=...,
       callback=function() dispatch("pi-editor.completion","refresh",buf) end })` form.

# ── THE REFERENCE (how a mature plugin auto-closes) ──
- url: https://github.com/Saghen/blink.cmp/blob/master/lua/blink/cmp/completion/trigger/init.lua
  why: blink's trigger.activate() registers `on_insert_leave = function() trigger.hide() end` — the
       LIVE-VERIFIED pattern for "leaving insert hides the menu" (S37's InsertLeave autocmd). blink
       ALSO has on_cursor_moved→within_query_bounds→else hide, but S37 does NOT copy that (it
       reimplements keyword bounds locally; our plugin delegates completable-position to pi — §3).
  critical: on_insert_leave→hide is the exact analog of S37's InsertLeave→menu.close(). Do NOT copy
       the within_query_bounds detector.

# ── Neovim API docs (anchor-cited) ──
- url: https://neovim.io/doc/user/autocmd.html#InsertLeave
  why: InsertLeave fires after leaving Insert/Replace mode (Esc, Ctrl-C, Ctrl-\ Ctrl-N, etc.). S37's
       primary autocmd. Fires AFTER mode change; the buffer is still current → the race (a pending
       do_refresh would run post-leave) is real → S37 cancels it.
- url: https://neovim.io/doc/user/autocmd.html#BufLeave
  why: BufLeave fires before leaving the current buffer for another (covers :bnext/:e/:bd/split-
       to-another-buffer). Robustly buffer-local (nvim_create_autocmd("BufLeave",{buffer=buf})).
       S37's second autocmd.
- url: https://neovim.io/doc/user/api.html#nvim_exec_autocmds()
  why: nvim_exec_autocmds("InsertLeave", {buffer=buf}) is the HEADLESS autocmd-simulation seam for
       plenary tests (no real keystrokes) — same idiom the existing ftplugin_spec uses
       (nvim_exec_autocmds("TextChangedI",{buffer=b})). Asserts the autocmd→dispatch→handler wiring.
- url: https://neovim.io/doc/user/api.html#nvim_win_close()
  why: menu.close() (S31) closes the floating window via render's hide path (pcall nvim_win_close,
       force=true). S37's on_insert_leave/on_buf_leave call menu.close() — no new window code.
```

### Current Codebase tree (the files S37 touches)

```bash
plugin/
  lua/pi-editor/
    completion.lua    # ← EDIT: ADD local hide_and_cancel() + M.on_insert_leave/M.on_buf_leave; update header
  ftplugin/
    pi-prompt.lua     # ← EDIT: ADD InsertLeave + BufLeave autocmds (between the refresh + autosave loops)
  tests/
    completion_spec.lua     # ← EDIT: ADD describe("S37: on_insert_leave/on_buf_leave") + describe("S37: CursorMoved-out-of-prefix")
    ftplugin_spec.lua       # ← EDIT: assert InsertLeave + BufLeave autocmds registered + no-throw-absent-module
    menu_autoclose_smoke.lua# ← CREATE: plenary-free auto-close smoke (real bridge + nvim_exec_autocmds)
    minimal_init.lua        # (read-only) plenary harness bootstrap (reuse as-is)
  lua/pi-editor/menu.lua      # (read-only) — S37 only CALLS menu.close() (no edit)
  plugin/pi-editor.lua        # (read-only) VimEnter shim
# NO new runtime modules. NO menu.lua change. NO init.lua change. NO new config option.
```

### Desired Codebase tree (the change footprint)

```bash
plugin/
  lua/pi-editor/completion.lua             # MODIFIED — +local hide_and_cancel +M.on_insert_leave +M.on_buf_leave
  ftplugin/pi-prompt.lua                   # MODIFIED — +InsertLeave autocmd +BufLeave autocmd (+ FORWARD CONTRACTS note)
  tests/completion_spec.lua                # MODIFIED — +2 S37 describe blocks (existing cases stay green)
  tests/ftplugin_spec.lua                  # MODIFIED — +InsertLeave/BufLeave registration assert + no-throw-absent case
  tests/menu_autoclose_smoke.lua           # NEW — plenary-free auto-close smoke (SMOKE_PASS)
# No other files touched. NO local prefix detector. NO menu/window/accept change.
```

### Known Gotchas of our codebase & Neovim quirks

```lua
-- CRITICAL (THE #1 bug — research §1): a stale do_refresh RE-OPENS the menu in normal mode after
-- <Esc> if the handler does not cancel the pending debounce. completion.refresh() ALWAYS schedules a
-- vim.defer_fn(do_refresh, debounce_ms). If InsertLeave fires during that 25ms window, the deferred
-- do_refresh runs post-leave (buf STILL valid+current+bridge connected) → getSuggestions → on_results
-- → menu.open() in NORMAL MODE. THE FIX: the handler MUST call M.reset() (cancel_timer + bridge.cancel
-- + state.gen=0 so the in-flight cb's gen-guard drops it). reset()'s OWN docstring promises this for S37.

-- CRITICAL (do NOT reimplement a prefix detector — research §3): the "CursorMoved out of prefix"
-- trigger is OWNED by S30's refresh (CursorMovedI→refresh→re-fetch→empty→menu.close()). S37
-- VERIFIES it with a test + documents it. Do NOT add a local within_query_bounds/keyword detector
-- (blink's approach) — that reimplements pi's completable-position logic + diverges from the TUI
-- (the codebase's #1 anti-pattern: "NEVER reimplement pi's logic locally").

-- CRITICAL: on_insert_leave/on_buf_leave are FIRE-AND-FORGET autocmd callbacks (return value IGNORED).
-- They do NOT return a bool (unlike on_enter/on_next/on_tab KEY handlers). The ftplugin's dispatch is
-- used only for the no-op-safe-absent-module guarantee. Do NOT model their return contract on on_next.

-- CRITICAL (never detach the menu): hide_and_cancel calls menu.close() (hides; does NOT detach) +
-- M.reset() (completion's reset — does NOT touch menu.attach). The completion.on_results→menu.on_results
-- seam STAYS wired, so re-entering insert / a new pi-prompt buffer re-populates the menu with NO
-- re-attach. Do NOT call menu.reset() (which detaches + nils menu_buf).

-- CRITICAL (autocmds are BUFFER-LOCAL + same "pi-editor" group + clear=false): reuse the EXISTING
-- augroup + the nvim_clear_autocmds({buffer=buf, group="pi-editor"}) idempotency line (already in place).
-- Do NOT create a new augroup (would fragment the SHARED group + risk the S20 VimEnter autocmd).

-- CRITICAL (BufLeave, NOT WinLeave/BufWinLeave — research §4): BufLeave is robustly buffer-local +
-- covers buffer switches. WinLeave's buffer-local behavior is murky; BufWinLeave overlaps the
-- VimLeave teardown path (redundant with S38's VimLeavePre/ExitPre). PRD §11 scopes v1 to the single
-- VimEnter buffer, so the same-buffer-two-windows edge is explicitly out of scope.

-- CRITICAL (accept does NOT race with InsertLeave): accept's cb (menu.close after buffer-set) is a
-- ONE-SHOT user action while still in insert; InsertLeave fires AFTER, only if the user then leaves
-- insert — by then accept already closed the menu, so on_insert_leave's menu.close() is a harmless
-- no-op. nvim_buf_set_lines/nvim_win_set_cursor are API mutations — they do NOT fire InsertLeave/
-- TextChangedI/CursorMovedI (:help) — so accept never synthesizes an insert-leave.

-- CRITICAL (hide FIRST, then reset): order matters for UX — menu.close() hides the window IMMEDIATELY
-- (the user sees it vanish), then M.reset() cancels the pending refresh. Reversed order also works
-- (reset doesn't touch the window) but hide-first is the snappier UX + matches blink's hide().

-- CRITICAL (headless testing): simulate InsertLeave/BufLeave via nvim_exec_autocmds("InsertLeave",
-- {buffer=buf}) (NO real keystrokes) — same idiom the existing ftplugin_spec uses. Assert menu-closed
-- via menu.is_open()==false + menu._state.win==nil (NOT screenattr — it's 0 headlessly).

-- CRITICAL (AGENTS.md HARD RULE): NEVER pipe a heredoc / stdin into nvim — it HANGS the session.
-- Write every lua test/check to a REAL FILE, then +"luafile <path>" +qa. Wrap every nvim in timeout.
```

---

## Implementation Blueprint

### The shared teardown + the two handlers — NEW (completion.lua)

Add a LOCAL `hide_and_cancel()` near `cancel_timer` (or just above the Public API section) + two
PUBLIC handlers in the Public API section (after `on_dismiss`, mirroring the S36 section style).
They are FIRE-AND-FORGET autocmd callbacks (no bool return).

```lua
-- ===========================================================================
-- S37: on_insert_leave(buf) / on_buf_leave(buf) — the AUTOCMD-driven auto-close handlers
-- (the complement to S36's KEY handlers). The ftplugin dispatches InsertLeave→on_insert_leave +
-- BufLeave→on_buf_leave (buffer-local, the "pi-editor" augroup). Each hides the menu + CANCELS the
-- pending debounced refresh so a stale do_refresh cannot re-open the menu in normal mode (THE race
-- fix — research/notes.md §1; reset()'s docstring promised it for S37). The "CursorMoved out of
-- prefix" trigger is OWNED by the EXISTING CursorMovedI→refresh→re-fetch→empty→close path (S30,
-- COMPLETE — research §3; no local prefix detector). Fire-and-forget (autocmd; return value ignored);
-- never throws (pcall; type-guard; nvim_buf_is_valid). Read menu FRESH (require at call time).
-- Does NOT detach the menu (M.reset is completion's, not menu's) — re-entry re-populates w/o re-attach.
-- ===========================================================================

--- The shared S37 teardown: hide the window FIRST (immediate UX), then cancel the pending debounce +
--- in-flight RPC + clear completion state (M.reset sets state.gen=0 → a stale getSuggestions cb's
--- gen-guard drops it → the stale on_results never fires → no normal-mode re-open). Never throws
--- (menu.close + M.reset are both idempotent + pcall-safe). (research/notes.md §1/§6.)
local function hide_and_cancel()
  pcall(function() require("pi-editor.menu").close() end)   -- hide the floating window FIRST
  M.reset()                                                  -- cancel_timer + cancel inflight + gen=0 + clear state
end

--- InsertLeave handler (autocmd-fired by the ftplugin). Hides the menu + cancels the pending refresh
--- so a stale do_refresh cannot re-open the menu in normal mode. No-op when the menu is closed +
--- nothing pending (menu.close/M.reset are idempotent + never throw). Never throws.
---@param buf integer The pi-prompt buffer handle (from the buffer-local InsertLeave autocmd).
function M.on_insert_leave(buf)
  if type(buf) ~= "number" or not vim.api.nvim_buf_is_valid(buf) then return end
  hide_and_cancel()
end

--- BufLeave handler (autocmd-fired by the ftplugin). Same teardown as on_insert_leave; clearing
--- state.buf/last_result is correct since we left the buffer (the next refresh on a future pi-prompt
--- buffer rebuilds). Never throws. (research/notes.md §4/§6.)
---@param buf integer The pi-prompt buffer handle (from the buffer-local BufLeave autocmd).
function M.on_buf_leave(buf)
  if type(buf) ~= "number" or not vim.api.nvim_buf_is_valid(buf) then return end
  hide_and_cancel()
end
```

> **Why `hide_and_cancel` reuses `M.reset()`** (research/notes.md §1/§6): `reset()` ALREADY does
> exactly the teardown S37 needs — `cancel_timer()` (closes the pending `vim.defer_fn`), `bridge.cancel(inflight_id)`,
> `state.gen = 0` (drops any in-flight cb via the gen-guard), and clears `last_result`/`buf`. It is
> idempotent + never throws, and its OWN docstring promises it for "the future S37 InsertLeave/
> CursorMoved-out wiring." Reusing it (vs an inline copy) is DRY + guarantees the stale-cb supersession
> matches do_refresh's exact gen-guard semantics. The `menu.close()` call BEFORE it hides the window
> immediately (reset does not touch the menu).

### The 2 autocmds (ftplugin/pi-prompt.lua)

In the **Autocmds** section, ADD two `nvim_create_autocmd` calls BETWEEN the refresh loop and the
autosave loop. Reuse the existing `group` + `dispatch` + the `nvim_clear_autocmds({buffer=buf,
group="pi-editor"})` idempotency line (already in place — no change to it).

```lua
-- ── S37: auto-close the menu when the user leaves the completion context (PRD §7.5) ─────────────
-- InsertLeave covers <Esc>/<C-\><C-n>; BufLeave covers :bnext/:e/split-to-another-buffer. Each hides
-- the menu + cancels the pending refresh so a stale do_refresh cannot re-open the menu in normal mode
-- (research §1). The "CursorMoved out of prefix" trigger is owned pi-faithfully by the EXISTING
-- CursorMovedI→refresh→re-fetch→empty→close path above (S30, COMPLETE; no local prefix detector — §3).
-- Fire-and-forget (autocmd; dispatch's bool return is ignored here — used only for the no-op-safe-
-- absent-module guarantee). Buffer-local + the SHARED "pi-editor" group + clear=false (idempotent via
-- the nvim_clear_autocmds line above).
for _, ev in ipairs({ "InsertLeave", "BufLeave" }) do
  local fn = (ev == "InsertLeave") and "on_insert_leave" or "on_buf_leave"
  vim.api.nvim_create_autocmd(ev, {
    group = group,
    buffer = buf,
    desc = "pi-editor: auto-close completion menu on " .. ev,
    callback = function() dispatch("pi-editor.completion", fn, buf) end,
  })
end
```

Also extend the ftplugin's **FORWARD CONTRACTS** doc block (near the top) to name
`on_insert_leave`/`on_buf_leave` (InsertLeave/BufLeave autocmds; S37) + note that
"CursorMoved out of prefix" is owned by the existing `refresh` path (S30, pi-faithful — no local
detector). And add `on_insert_leave(buf)` / `on_buf_leave(buf)` to the
`require("pi-editor.completion")` forward-contract list with a `(S37)` tag.

### Implementation Tasks (ordered by dependencies)

```yaml
Task 1: READ the 2 files you edit + the S37 research + the prior PRPs
  - READ FULLY: plugin/lua/pi-editor/completion.lua (M.reset() — THE teardown, its docstring names S37;
    cancel_timer LOCAL; state fields; do_refresh's gen-guard cb — the stale one the race fix drops;
    on_enter/on_next gating skeleton — the model, but S37 handlers are fire-and-forget NO bool;
    M.on_results nil today, set by menu.attach).
  - READ FULLY: plugin/ftplugin/pi-prompt.lua (the group = augroup "pi-editor" clear=false SHARED with
    S20; the nvim_clear_autocmds idempotency line; the dispatch helper; the refresh autocmd loop;
    the autosave loop — S37 goes BETWEEN them).
  - READ: plan/001_c56962b4fa17/P2M8T22S37/research/notes.md (§1 the race fix, §3 the CursorMoved
    ownership, §4 BufLeave-vs-WinLeave, §6 the handler design, §9 gotchas).
  - READ: plan/001_c56962b4fa17/P2M8T22S36/PRP.md (the S36 sibling — same test conventions, same
    never-throws contract).

Task 2: ADD the local hide_and_cancel() + M.on_insert_leave/on_buf_leave to completion.lua
  - ADD the LOCAL hide_and_cancel() EXACTLY as the reference impl (menu.close() FIRST, then M.reset()).
  - ADD the 2 PUBLIC handlers EXACTLY as the reference impl (gate type+valid → hide_and_cancel()).
    FIRE-AND-FORGET (NO bool return). Read menu FRESH inside hide_and_cancel. NEVER throws (pcall).
  - DO NOT detach the menu (no menu.reset) — M.reset is completion's; the on_results seam stays wired.
  - UPDATE the completion.lua header: mark on_insert_leave/on_buf_leave as S37-SHIPPED + cite research §1/§6.
    (M.reset's docstring ALREADY names "the future S37 InsertLeave/CursorMoved-out wiring" — confirm it.)

Task 3: ADD the 2 ftplugin autocmds (ftplugin/pi-prompt.lua)
  - ADD the for-loop over {InsertLeave, BufLeave} (or 2 explicit nvim_create_autocmd calls) BETWEEN the
    refresh loop and the autosave loop. Reuse the EXISTING group + dispatch + the idempotency line.
    Each: { group=group, buffer=buf, desc="pi-editor: auto-close completion menu on <ev>",
    callback=function() dispatch("pi-editor.completion", <on_insert_leave|on_buf_leave>, buf) end }.
  - EXTEND the FORWARD CONTRACTS doc block: list on_insert_leave(buf)/on_buf_leave(buf) (S37); note
    "CursorMoved out of prefix" is owned by the existing refresh path (S30, pi-faithful; no local detector).

Task 4: SMOKE-VERIFY the race fix + auto-close in isolation (before touching specs) — a REAL FILE
  - WRITE /tmp/completion_s37_check.lua: rtp+=plugin; setup({debounce_ms=20}); fake bridge (controllable
    request/cancel); pi.bridge=fake. FLOW 1 (the race): populated menu via refresh+resolve(items) →
    menu.is_open()==true; refresh(buf) AGAIN (schedules a NEW debounce, inflight not yet issued) →
    IMMEDIATELY completion.on_insert_leave(buf) → vim.wait(120) → assert NOT menu.is_open() AND
    #fake.requests did NOT increase (stale do_refresh cancelled). FLOW 2 (inflight supersession):
    populated menu → refresh → resolve PENDING (don't resolve yet) → on_insert_leave(buf) → NOW resolve
    the pending req with items → vim.wait(80) → assert NOT menu.is_open() (gen-guard dropped the stale
    cb). FLOW 3 (BufLeave): populated menu → on_buf_leave(buf) → NOT menu.is_open() +
    completion.current()==nil. FLOW 4 (CursorMoved-out via refresh): populated menu → move cursor out
    → refresh → resolve empty → NOT menu.is_open() (the §3 path). Run:
    timeout 60 nvim --headless --clean -u NORC +"luafile /tmp/completion_s37_check.lua" +qa ; echo "exit=$?"

Task 5: UPDATE plugin/tests/completion_spec.lua — ADD describe("S37: on_insert_leave/on_buf_leave")
  - REUSE the existing fake_bridge() + populated_menu(line, byte_col, items, prefix) helpers (S32/S33).
  - ADD: (a) populated→on_insert_leave(buf)→menu.is_open()==false + completion.current()==nil;
    (b) populated→on_buf_leave(buf)→same; (c) THE RACE FIX: populated→refresh(buf) again (new debounce,
    not yet issued)→IMMEDIATELY on_insert_leave(buf)→vim.wait(debounce*4)→assert NOT menu.is_open() AND
    #fake.requests unchanged (stale do_refresh cancelled); (d) inflight supersession: refresh→on_insert_leave
    (before resolving)→THEN resolve_last(items)→vim.wait→assert NOT menu.is_open() (gen-guard dropped);
    (e) closed-menu/nothing-pending→on_insert_leave/on_buf_leave harmless no-op (no throw);
    (f) never-throws on nil/wiped buf (on_insert_leave(nil)/on_insert_leave("x")/on_insert_leave(wiped-buf)).
  - ADD describe("S37: CursorMoved-out-of-prefix closes via refresh"): populated menu→set cursor to a
    different line (vim.api.nvim_win_set_cursor to row 2 on a 2-line buffer)→completion.refresh(buf)→
    resolve_last(nil, {items={}, prefix=""})→vim.wait→assert NOT menu.is_open() (the EXISTING S30 path).
  - KEEP the S30/S32/S33/S36 cases UNCHANGED (S37 is purely additive).

Task 6: UPDATE plugin/tests/ftplugin_spec.lua — assert InsertLeave + BufLeave autocmds registered
  - ADD to the existing "registers completion autocmds (InsertEnter/TextChangedI/CursorMovedI)" case
    (or a new case): assert evs["InsertLeave"]==true + evs["BufLeave"]==true (via nvim_get_autocmds
    {buffer=b, group="pi-editor"} — mirroring the existing InsertEnter assertion).
  - ADD a case: "does not throw when firing InsertLeave/BufLeave with completion.lua absent" —
    nvim_exec_autocmds("InsertLeave",{buffer=b}) + nvim_exec_autocmds("BufLeave",{buffer=b}) under
    assert.has_no.errors (the no-op-safe-absent-module contract, mirroring the existing TextChangedI case).

Task 7: CREATE plugin/tests/menu_autoclose_smoke.lua — plenary-free auto-close smoke
  - MIRROR menu_smoke.lua/completion_accept_smoke.lua's fake-server bootstrap (fake luv socket + REAL
    bridge.handshake + menu.attach() + completion.refresh(buf) + a getSuggestions reply with items).
  - FLOW 1 (InsertLeave): refresh("/mo")→reply items→menu open→nvim_exec_autocmds("InsertLeave",{buffer=buf})
    →assert NOT menu.is_open() + menu._state.win==nil (window closed).
  - FLOW 2 (BufLeave): refresh→reply items→menu open→nvim_exec_autocmds("BufLeave",{buffer=buf})→
    NOT menu.is_open().
  - FLOW 3 (CursorMoved-out via refresh — §3): refresh→reply items→menu open→move cursor to a blank
    line→completion.refresh(buf)→reply empty→NOT menu.is_open() (the EXISTING S30 path closes it).
  - FLOW 4 (race): refresh→menu open→refresh AGAIN→IMMEDIATELY nvim_exec_autocmds("InsertLeave")→
    vim.wait(120)→NOT menu.is_open() (no stale re-open).
  - Print SMOKE_PASS / exit 0. Plenary-free (AGENTS.md: +"luafile …" +qa, NOT stdin).

Task 8: RUN the full validation suite (see Validation Loop) + fix until green
  - RUN: completion_spec.lua, ftplugin_spec.lua, menu_autoclose_smoke.lua (the changed/new files),
    THEN every sibling spec/smoke (menu_spec, menu_geometry_spec, menu_smoke, menu_nav_smoke,
    completion_accept_smoke, completion_tab_smoke, completion_smoke, bridge_*, coords_*, init_*,
    activate_*, ftplugin_smoke, shim_*, jsonlreader_*, smoke). All green.
```

### Implementation Patterns & Key Details

```lua
-- PATTERN: the fire-and-forget autocmd handler (NOT the on_enter/on_next bool-returning keymap handler):
--   function M.on_insert_leave(buf)
--     if type(buf) ~= "number" or not vim.api.nvim_buf_is_valid(buf) then return end  -- gate (never throws)
--     hide_and_cancel()   -- menu.close() FIRST (hide), then M.reset() (cancel pending + gen=0 + clear)
--   end
--   -- NO `return true/false` (autocmd callback; return value ignored). on_buf_leave is identical.
-- PATTERN: the shared teardown reuses M.reset() (THE cleanup seam — its docstring names S37):
local function hide_and_cancel()
  pcall(function() require("pi-editor.menu").close() end)   -- hide the window (immediate UX); never throws
  M.reset()                                                  -- cancel_timer + bridge.cancel(inflight) + gen=0 + clear
end
-- PATTERN: the autocmd wiring (ftplugin — reuse group/dispatch/idempotency, BETWEEN refresh + autosave):
for _, ev in ipairs({ "InsertLeave", "BufLeave" }) do
  local fn = (ev == "InsertLeave") and "on_insert_leave" or "on_buf_leave"
  vim.api.nvim_create_autocmd(ev, {
    group = group, buffer = buf, desc = "pi-editor: auto-close completion menu on " .. ev,
    callback = function() dispatch("pi-editor.completion", fn, buf) end,
  })
end
-- PATTERN: headless autocmd simulation in tests (no real keystrokes):
vim.api.nvim_exec_autocmds("InsertLeave", { buffer = buf })   -- fires the buffer-local autocmd → on_insert_leave
-- PATTERN: assert menu-closed headless-safe:
assert(not menu.is_open(), "menu closed")
assert(menu._state.win == nil, "window handle nil'd")         -- NOT screenattr (0 headlessly)
-- GOTCHA: hide FIRST then reset (snappier UX; reset doesn't touch the window so order is safe).
-- GOTCHA: NEVER detach the menu (no menu.reset) — M.reset is completion's; the on_results seam stays wired.
-- GOTCHA: do NOT reimplement a prefix detector for "CursorMoved out of prefix" — it's owned by S30's
--   refresh (re-fetch→empty→close). S37 verifies + documents it; the local within_query_bounds is blink's,
--   not ours (would reimplement pi).
-- GOTCHA (AGENTS.md): heredoc→file is fine; heredoc→nvim stdin HANGS. Wrap nvim in timeout.
```

### Integration Points

```yaml
CONFIG (read-only, NO change):
  - source: plugin/lua/pi-editor/init.lua M.defaults (debounce_ms etc.) — read by completion.refresh.
    S37 adds NO config option (the autocmd set is fixed by PRD §7.5; the teardown reuses M.reset).

STATE (S30, read-only contract — S37 only CANCELS it via M.reset + hides via menu.close):
  - completion.state: debounce_timer (cancelled by reset), inflight_id (cancelled by reset),
    gen (reset to 0 — drops stale cbs), last_result (cleared by reset), buf (cleared by reset).
  - menu.state: items/selected/open (cleared by menu.close), win (nil'd by menu.close's render hide).
    state.buf/prefix (left intact by menu.close — only menu.reset clears them; S37 does NOT call menu.reset).

SEAM (NO completion.lua wiring change to refresh/accept/on_results):
  - menu.attach() (S31) ALREADY wires completion.on_results → menu.on_results. S37's on_insert_leave/
    on_buf_leave are NEW top-level M fields the ftplugin dispatches to (the forward contract S22 will name).
    NO change to refresh/accept/on_enter/on_tab/on_next/on_prev/on_dismiss/on_results. NO change to menu.

AUTOCMDS (the ONLY ftplugin change — 2 new buffer-local registrations):
  - InsertLeave→on_insert_leave, BufLeave→on_buf_leave. The existing refresh autocmds (InsertEnter/
    TextChangedI/CursorMovedI) + autosave autocmds (VimLeavePre/ExitPre) are UNCHANGED. Reuse the SHARED
    "pi-editor" augroup (clear=false) + the nvim_clear_autocmds({buffer=buf,group=...}) idempotency line.

TESTING HARNESS (reuse, no change):
  - Plenary spec: plugin/tests/minimal_init.lua (sets rtp to plugin/ + plenary).
  - Smoke: plenary-free, self-bootstraps rtp (the menu_smoke/completion_accept_smoke pattern).
```

---

## Validation Loop

> **CRITICAL (AGENTS.md HARD RULE):** write every lua snippet to a REAL FILE then run
> `+"luafile <path>" +qa`. NEVER pipe a heredoc into nvim stdin (it HANGS). ALWAYS wrap nvim in
> `timeout`. Run from the `plugin/` directory.

### Level 1: Syntax & Style (after editing completion.lua + the ftplugin)

```bash
cd /home/dustin/projects/pi-nvim-bridge/plugin
# load/syntax check via a FILE (NOT stdin):
cat > /tmp/s37_loadcheck.lua <<'LUA'
for _, f in ipairs({ "lua/pi-editor/completion.lua", "ftplugin/pi-prompt.lua" }) do
  local ok, err = loadfile(f)
  assert(ok, f .. " syntax error: " .. tostring(err))
end
print("S37_LOAD_OK")
LUA
timeout 30 nvim --headless --clean -u NORC +"luafile /tmp/s37_loadcheck.lua" +qa ; echo "exit=$?"
# Expected: S37_LOAD_OK, exit 0. (If selene/stylua config exists, also run them per repo convention.)
```

### Level 2: Unit Tests (plenary) — the handlers + the autocmd wiring + the CursorMoved-out ownership

```bash
cd /home/dustin/projects/pi-nvim-bridge/plugin
# on_insert_leave/on_buf_leave (gate + teardown + THE RACE FIX + inflight supersession + closed/never-throws):
timeout 90 nvim --headless --clean -u tests/minimal_init.lua \
  -c 'lua require("plenary.busted").run("tests/completion_spec.lua")' ; echo "exit=$?"
# InsertLeave + BufLeave autocmds registered + no-throw-absent-module:
timeout 90 nvim --headless --clean -u tests/minimal_init.lua \
  -c 'lua require("plenary.busted").run("tests/ftplugin_spec.lua")' ; echo "exit=$?"
# Expected: both exit 0, every case passes. Read the output + fix before proceeding.
```

### Level 3: Smoke (plenary-free, real bridge + real completion + real menu — auto-close end-to-end)

```bash
cd /home/dustin/projects/pi-nvim-bridge/plugin
# The NEW auto-close smoke: fake server → populated menu → simulate InsertLeave (menu+window closed) →
# BufLeave (closed) → CursorMoved-out-of-prefix (closed via the §3 refresh path) → the race (no stale re-open).
timeout 60 nvim --headless --clean -u NORC +"luafile tests/menu_autoclose_smoke.lua" +qa ; echo "exit=$?"
# Expected: SMOKE_PASS, exit 0.
# ALSO re-run the existing menu/completion smokes (S37 must not regress them):
timeout 60 nvim --headless --clean -u NORC +"luafile tests/menu_smoke.lua" +qa ; echo "exit=$?"
timeout 60 nvim --headless --clean -u NORC +"luafile tests/menu_nav_smoke.lua" +qa ; echo "exit=$?"
timeout 60 nvim --headless --clean -u NORC +"luafile tests/completion_smoke.lua" +qa ; echo "exit=$?"
# Expected: SMOKE_PASS, exit 0 for each.
```

### Level 4: Regression — S37 must break NOTHING in sibling modules

```bash
cd /home/dustin/projects/pi-nvim-bridge/plugin
for spec in menu_spec menu_geometry_spec completion_spec menu_nav_smoke menu_smoke \
            completion_accept_smoke completion_tab_smoke completion_smoke bridge_spec bridge_smoke \
            bridge_handshake_spec bridge_request_spec bridge_notify_spec coords_spec coords_smoke \
            init_spec activate_spec activate_smoke ftplugin_spec ftplugin_smoke shim_spec shim_smoke \
            jsonlreader_spec jsonlreader_smoke smoke; do
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

### Level 4b: The auto-close + race-fix isolation check (the "does InsertLeave actually cancel the stale refresh?" proof)

```bash
# A REAL file (AGENTS.md: heredoc→file is fine; heredoc→nvim stdin is NOT). Proves the §1 race fix +
# the CursorMoved-out ownership WITHOUT a socket (a fake bridge).
cat > /tmp/completion_s37_e2e.lua <<'LUA'
vim.opt.runtimepath:append("/home/dustin/projects/pi-nvim-bridge/plugin")
local pi = require("pi-editor"); if pi.config == nil then pi.setup({ debounce_ms = 20 }) end
local completion = require("pi-editor.completion")
local menu = require("pi-editor.menu")
menu.attach() -- wire completion.on_results -> menu.on_results

-- a fake bridge: controllable request (stores cb) + cancel + is_connected
local fake = { connected = true, requests = {}, cancels = {} }
function fake.is_connected() return fake.connected end
function fake.request(method, params, cb)
  fake.requests[#fake.requests + 1] = { method = method, params = params, cb = cb }
  return tostring(#fake.requests)
end
function fake.cancel(id) fake.cancels[#fake.cancels + 1] = id end
local function resolve_last(err, result)
  local e = fake.requests[#fake.requests]; if e then vim.schedule_wrap(e.cb)(err, result) end
end
pi.bridge = fake

-- a pi-prompt-ish buffer + window (cursor context for the cursor-relative popup)
local buf = vim.api.nvim_create_buf(true, false)
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "/mo", "" })
local win = vim.api.nvim_open_win(buf, true, {relative="editor",row=1,col=1,width=60,height=6,border="none"})
vim.wo[win].virtualedit = "onemore"; vim.api.nvim_win_set_cursor(win, {1, 3})

-- helper: populate the menu via the REAL seam (refresh -> resolve items -> menu open)
local function populate()
  local n0 = #fake.requests
  completion.refresh(buf)
  vim.wait(200, function() return #fake.requests > n0 end, 5)
  resolve_last(nil, { items = { { value = "/model", label = "model" } }, prefix = "/mo" })
  vim.wait(200, function() return menu.is_open() end, 5)
end

-- ── FLOW 1: THE RACE FIX (refresh-then-immediately-leave does NOT re-open) ──
populate()
assert(menu.is_open(), "F1: menu open")
local reqs_before = #fake.requests
completion.refresh(buf)                 -- schedules a NEW debounce (do_refresh not yet issued)
completion.on_insert_leave(buf)         -- InsertLeave: hide + cancel the pending debounce
vim.wait(120, function() end)           -- let the would-be 20ms debounce elapse
assert(not menu.is_open(), "F1: stale do_refresh did NOT re-open the menu")
assert(#fake.requests == reqs_before, "F1: no new getSuggestions issued (debounce cancelled)")

-- ── FLOW 2: inflight supersession (a stale cb is dropped by the gen-guard) ──
populate()
completion.refresh(buf)
vim.wait(200, function() return #fake.requests > 0 end, 5)  -- the new req is in-flight
completion.on_insert_leave(buf)         -- reset: state.gen = 0
resolve_last(nil, { items = { { value = "/model", label = "model" } }, prefix = "/mo" })  -- stale cb (old gen)
vim.wait(80, function() end)
assert(not menu.is_open(), "F2: the stale in-flight cb was dropped (gen-guard) — no re-open")

-- ── FLOW 3: BufLeave hides + clears state ──
populate()
assert(menu.is_open(), "F3: menu open")
completion.on_buf_leave(buf)
assert(not menu.is_open(), "F3: BufLeave closed the menu")
assert(completion.current() == nil, "F3: last_result cleared (reset)")

-- ── FLOW 4: CursorMoved-out-of-prefix closes via the EXISTING refresh path (§3) ──
populate()
assert(menu.is_open(), "F4: menu open")
vim.api.nvim_win_set_cursor(win, { 2, 0 })  -- move cursor to the blank line 2 (out of the /mo prefix)
completion.refresh(buf)                      -- CursorMovedI -> refresh
vim.wait(200, function() return #fake.requests > 0 end, 5)
resolve_last(nil, { items = {}, prefix = "" })  -- pi returns empty (not completable on a blank line)
vim.wait(200, function() return not menu.is_open() end, 5)
assert(not menu.is_open(), "F4: CursorMoved-out -> refresh -> empty -> menu.close() (the S30 path)")

-- ── FLOW 5: closed-menu/nothing-pending on_insert_leave is a harmless no-op ──
completion.on_insert_leave(buf)
assert(not menu.is_open(), "F5: no-op when closed (no throw)")
completion.on_insert_leave(nil)      -- never-throws on bad args
completion.on_buf_leave("x")
assert(not menu.is_open(), "F5: bad-args no-op")

pcall(vim.api.nvim_win_close, win, true); pcall(vim.api.nvim_buf_delete, buf, {force=true})
pcall(menu.reset); pcall(completion.reset)
print("COMPLETION_S37_E2E_PASS")
LUA
timeout 60 nvim --headless --clean -u NORC +"luafile /tmp/completion_s37_e2e.lua" +qa ; echo "exit=$?"
# Expected: COMPLETION_S37_E2E_PASS, exit 0. (InsertLeave cancels the stale refresh; inflight superseded;
# BufLeave hides+clears; CursorMoved-out closes via the §3 refresh path; closed/bad-args no-ops.)
```

---

## Final Validation Checklist

### Technical Validation
- [ ] Level 1 load/syntax check passes (exit 0) for completion.lua, ftplugin/pi-prompt.lua.
- [ ] `tests/completion_spec.lua` passes: S30/S32/S33/S36 cases UNCHANGED + new S37 cases green
      (on_insert_leave/on_buf_leave hide+clear; THE RACE FIX — stale do_refresh does NOT re-open +
      no new RPC; inflight supersession — stale cb dropped; CursorMoved-out closes via refresh;
      closed/nothing-pending no-op; never-throws on nil/wiped buf).
- [ ] `tests/ftplugin_spec.lua` passes: InsertLeave + BufLeave autocmds registered in the `"pi-editor"`
      buffer-local group; no-throw when firing them with completion.lua absent.
- [ ] `tests/menu_autoclose_smoke.lua` passes (SMOKE_PASS; real-bridge InsertLeave/BufLeave close +
      CursorMoved-out via refresh + the race).
- [ ] `tests/menu_smoke.lua` + `menu_nav_smoke.lua` + `completion_smoke.lua` still pass (SMOKE_PASS;
      S37 regresses nothing).
- [ ] `/tmp/completion_s37_e2e.lua` prints COMPLETION_S37_E2E_PASS (the race fix + CursorMoved-out
      ownership + BufLeave + no-ops).
- [ ] Regression: every sibling spec/smoke green (no SPEC FAIL / SMOKE FAIL).

### Feature Validation
- [ ] With the menu open, `<Esc>` (→ `InsertLeave`) hides the menu + window IMMEDIATELY, and a pending
      debounced refresh does NOT re-open it in normal mode (the §1 race fix — verified by the e2e FLOW 1).
- [ ] With the menu open, a buffer switch (→ `BufLeave`) hides the menu + window + clears completion
      state for the left buffer.
- [ ] With the menu open, moving the cursor OUT of the completable prefix in insert mode (→
      `CursorMovedI` → `refresh` → pi returns empty) hides the menu — via the EXISTING S30 path
      (no local prefix detector).
- [ ] `on_insert_leave`/`on_buf_leave` are fire-and-forget (NO bool return); never throw on bad args /
      wiped buf / closed menu / nothing-pending (silent no-op).
- [ ] The handlers do NOT detach the menu's `on_results` seam — re-entering insert / a new pi-prompt
      buffer re-populates the menu with NO re-attach.

### Code Quality Validation
- [ ] `hide_and_cancel` reuses `M.reset()` (DRY — the cleanup seam; its docstring names S37); hides the
      window FIRST via `menu.close()`, then resets.
- [ ] `on_insert_leave`/`on_buf_leave` mirror the on_enter/on_next gate (type+valid) but are
      fire-and-forget (NO bool); `menu` read FRESH inside `hide_and_cancel`.
- [ ] The ftplugin ADDS exactly 2 buffer-local autocmds (`InsertLeave`, `BufLeave`) in the SHARED
      `"pi-editor"` group (`clear=false`), reusing `dispatch` + the existing idempotency line; NO new
      helper/option/augroup.
- [ ] No new runtime dependencies (only `vim.api`/`vim.fn` already used); NO new config option.
- [ ] NO local prefix/keyword-bounds detector ("CursorMoved out of prefix" owned by S30's refresh).
- [ ] NO new menu/window/highlight/accept code (reuses menu.close + M.reset); NO menu.detach.
- [ ] Follows the codebase's Mode-A header + research-citation conventions (update completion.lua header
      to note S37 shipped; cite research/notes.md §1/§3/§6).
- [ ] Test snippets are real files (AGENTS.md: never heredoc→nvim stdin); nvim wrapped in `timeout`.

### Documentation & Scope Discipline
- [ ] Did NOT add a local prefix detector / reimplement pi's completable-position logic.
- [ ] Did NOT change the menu module (`open`/`close`/`reset`/`on_results`/`next`/`prev`/`dismiss`/
      `render`/`apply_highlights`), the state fields, the geometry helpers, or the bridge/coords.
- [ ] Did NOT change `refresh`/`accept`/`on_enter`/`on_tab`/`on_next`/`on_prev`/`on_dismiss`/
      `on_results` (S37 only ADDS on_insert_leave/on_buf_leave + the shared hide_and_cancel).
- [ ] Did NOT add a new config option, augroup, or `WinLeave`/`BufWinLeave` autocmd (PRD §11 scopes
      v1 to the single VimEnter buffer).
- [ ] Did NOT touch PRD.md, tasks.json, prd_snapshot.md, or any plan/* PRP other than this one.

---

## Anti-Patterns to Avoid

- ❌ Don't forget to CANCEL the pending refresh in the handler — a stale `do_refresh` RE-OPENS the menu
  in normal mode after `<Esc>` (the §1 race). ALWAYS call `M.reset()` (it cancels the debounce +
  inflight + sets gen=0 to drop the stale cb). The spec + e2e MUST prove this.
- ❌ Don't reimplement a local prefix/keyword-bounds detector for "CursorMoved out of prefix" — it's
  OWNED by S30's `CursorMovedI → refresh → re-fetch → empty → close` path (pi-faithful). A local
  detector would reimplement pi's completable-position logic + diverge from the TUI (the codebase's #1
  anti-pattern). S37 verifies + documents it (the spec's "CursorMoved-out-of-prefix closes via refresh"
  block + the smoke's FLOW 3).
- ❌ Don't make `on_insert_leave`/`on_buf_leave` return a bool — they're FIRE-AND-FORGET autocmd
  callbacks (return value ignored), NOT keymap handlers. The on_enter/on_next bool contract does NOT apply.
- ❌ Don't call `menu.reset()` (which DETACHES the `on_results` seam + nils `menu_buf`) — call
  `menu.close()` (hides only) + `M.reset()` (completion's reset — does NOT touch menu.attach). The seam
  must stay wired so re-entry re-populates without re-attach.
- ❌ Don't create a NEW augroup or use `clear=true` — the `"pi-editor"` group is SHARED with S20's
  VimEnter autocmd. Reuse it (`clear=false`) + the existing `nvim_clear_autocmds({buffer=buf, group=...})`
  idempotency line.
- ❌ Don't use `WinLeave`/`BufWinLeave` — `BufLeave` is robustly buffer-local + covers buffer switches;
  WinLeave's buffer-local behavior is murky + BufWinLeave overlaps S38's VimLeave teardown path.
- ❌ Don't let `on_insert_leave`/`on_buf_leave` throw (autocmd chain) — gate type+valid first;
  `menu.close()`/`M.reset()` are pcall-safe + idempotent. Read `menu` FRESH.
- ❌ Don't change `refresh`/`accept`/`on_enter`/`on_tab`/`on_next`/`on_prev`/`on_dismiss`/`on_results` or
  the menu/window/state/bridge/coords layers — S37 is purely additive (2 handlers + a shared local + 2
  autocmds).
- ❌ Don't pipe a heredoc into nvim stdin (it HANGS — AGENTS.md HARD RULE). Write test lua to a real
  file, then `+"luafile <path>" +qa`; wrap nvim in `timeout`.

---

## Confidence Score: 9/10

**Why high:** Every mechanism S37 uses is **already shipped + live-verified** by prior tasks:
- The teardown `M.reset()` (S30) ALREADY cancels the debounce timer + the in-flight RPC + sets
  `state.gen=0` (which drops any stale cb via do_refresh's gen-guard) — its docstring LITERALLY
  promises it for "the future S37 InsertLeave/CursorMoved-out wiring." S37 reuses it verbatim.
- The hide `menu.close()` (S31/S34) ALREADY closes the floating window via render's pcall-safe hide path.
- The "CursorMoved out of prefix" close is ALREADY implemented by S30's `CursorMovedI → refresh →
  re-fetch → empty → on_results → menu.close()` path — S37 only verifies + documents it (the spec's
  "CursorMoved-out-of-prefix closes via refresh" block + the smoke's FLOW 3 + the e2e's FLOW 4).
- The `on_enter`/`on_next` gating skeleton (S32/S36) — the new handlers are mechanical copies (minus
  the bool return, since they're fire-and-forget autocmd callbacks).
- The ftplugin's `group` + `dispatch` + `nvim_clear_autocmds` idempotency (S22) — the 2 new autocmds
  are 2 `nvim_create_autocmd` calls reusing all of it.
- The blink.cmp reference (`on_insert_leave → hide()`) confirms the InsertLeave-close is the
  industry-standard pattern.
S37 has NO new menu/window/highlight/IPC/accept/prefix-detector code — it is purely additive
autocmd wiring + two thin fire-and-forget handlers reusing `menu.close()` + `M.reset()`.

**Residual risk (the 1 point):** the precise "stale do_refresh is cancelled before it re-opens the
menu" guarantee depends on `M.reset()`'s `cancel_timer()` (which `:stop()`+`:close()`es the
`vim.defer_fn` timer) being called before the deferred `do_refresh` runs. This holds by construction
(InsertLeave is a synchronous autocmd callback on the main loop; `vim.defer_fn` callbacks also run on
the main loop — they cannot interleave), and the Level-4b e2e FLOW 1 asserts the menu does NOT re-open
+ no new RPC is issued. Also, the inflight-supersession path (FLOW 2/e2e FLOW 2) relies on the gen-guard
dropping a cb whose captured `gen` != the post-reset `state.gen=0` — verified by the e2e. The
"CursorMoved out of prefix" ownership claim is pinned by the spec block + the e2e FLOW 4 (the refresh
path closes the menu on an empty result) before any reader trusts the "no local detector" assertion.