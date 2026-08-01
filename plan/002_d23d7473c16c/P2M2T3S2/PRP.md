# PRP — P2.M2.T3.S2: shell branch in `do_refresh` + `force_fetch`/`on_tab` (gen-guard + 0 ms debounce)

**Parent:** P2.M2.T3 (completion.lua routing + shell.complete_current + notices)
**Component:** B (`pi-bridge.nvim`) — `lua/pi-bridge/completion.lua`
**PRD anchor:** §17.7 *Routing in the plugin (`completion.lua` extension)* (supported by §17.5.2 supersession, §17.9 Tab-force, §17.11 debounce, §17.14 shell byte offsets, §17.3/§17.13 daemon-is-not-the-bridge)
**Size:** 1 pt — the **routing** layer that consumes S1's `"shell"` gate.
**Builds on:** P2.M2.T3.S1 (COMPLETE — `completion_context()` now returns `"shell"` for `!`/`!!` line 1).

---

## Goal

**Feature Goal:** When `completion_context()` returns `"shell"` (a `!`/`!!` first line — S1), route the completion fetch to the §17 **shell-completion daemon** (`shell.complete_current`) instead of pi's bridge (`getSuggestions`) — in BOTH the debounced path (`do_refresh`) and the immediate Tab-force path (`on_tab`/`force_fetch`) — using the SAME shared generation-id supersession guard the bridge path uses, at a 0 ms debounce window. The bridge path for slash/path/plain stays byte-identical (regression-guarded).

**Deliverable:** Edited `lua/pi-bridge/completion.lua`:
1. A new **shared helper `do_shell_fetch(buf)`** (mirrors the codebase's helper-extraction pattern: `_route_or_accept`, `cancel_timer`, `compute_debounce`, `hide_and_cancel`) that: cancels any in-flight **bridge** request (layer-1 supersession for a slash→shell context switch), bumps + captures `state.gen` (layer-2 supersession), forward-guards + calls `shell.complete_current(buf, cb)`, and whose `cb` does the gen-guard → stores `last_result` → `vim.schedule`s `on_results` (the shell `cb` runs in **libuv fast context**, NOT the main loop — see §Known Gotchas).
2. A **restructure of `do_refresh`**: move the buffer-lines/cursor read + `completion_context` computation ABOVE the bridge-connected bail, and insert `if ctx == "shell" then do_shell_fetch(buf); return end` before the `if not ctx` block. (Shell completion is bridge-independent — §17.3/§17.13.)
3. A **restructure of `on_tab` BRANCH 2**: read lines+cursor early, compute `ctx`, and `if ctx == "shell" then do_shell_fetch(buf); return true end` BEFORE the bridge-connected check (the §17.9 "Tab-force in shell context mirrors file-force").
4. A one-line **`force_fetch` shell seam**: `if opts and opts.shell then do_shell_fetch(buf); return end` at the top (literal "force_fetch" coverage + a documented Tab-force entry; `on_tab` calls `do_shell_fetch` directly for clarity — shell uses byte offsets, not pi's UTF-16 coords).
5. **`compute_debounce` shell-awareness**: return `config.shell.debounce_ms` (default `0`) for a line-1 `!` BEFORE the attachment check (the "0 ms debounce" mechanism; honors the §17.11 config knob, read defensively).
6. New plenary cases in `tests/completion_spec.lua` that **mock `shell.complete_current`** (forward contract — S3 not yet defined) and assert the routing + gen-guard + 0 ms debounce + regression.

**Success Definition:**
- A `!git ch` buffer: `do_refresh` calls `shell.complete_current(buf, cb)` and issues **zero** `bridge.request("getSuggestions")` calls (verified via the fake bridge's request log being empty).
- A `!git ch` buffer with `pi.bridge == nil` (bridge never connected): shell completion STILL routes to `shell.complete_current` (bridge-independent).
- A slash→shell context switch (`/mod` then `!git`): the shell branch `bridge.cancel`s the prior in-flight bridge id (layer 1) AND the stale bridge cb is dropped by the gen-guard (layer 2); the shell fetch proceeds.
- Two rapid `!` keystrokes: the **stale** shell `cb` is dropped at the gen-guard (`gen ~= state.gen`); `on_results` fires **at most once** for the latest.
- `<Tab>` on a `!git` line with the menu closed: `shell.complete_current` is called immediately (no debounce wait); `on_tab` returns `true` (Tab consumed).
- A shell `cb` with `err` truthy → silent degrade (`on_results` NOT called; never throws).
- `shell.complete_current` absent (S3 not landed) → the shell branch is a **silent no-op** (forward-guard `type(...) == "function"`); no throw, no menu (S1→S3 intermediate state).
- **Regression:** `/mod` (slash), `@app` (path), `hello` (plain) → still issue `bridge.request("getSuggestions")`; `shell.complete_current` is NOT called for them.
- `tests/completion_spec.lua` plenary run is green (new cases + the full existing suite).

---

## User Persona

**Target User:** A pi user editing a prompt in the Neovim external editor (`Ctrl+G`) who types a `!`/`!!` line to run a shell command.

**Use Case:** The user types `!git ch` and (once S3 `complete_current` lands) gets their real shell's completions (`checkout`, `cherry`, …) in the floating menu. **S2 alone** does not yet render shell completions — it only wires the **routing** so that, the moment S3 lands, `!` lines stop issuing a wasted `getSuggestions` RPC and instead drive the daemon. S2 is the prerequisite seam; S1 was its gate.

**Pain Points Addressed:** Today (S1 shipped, S2 not) a `!` line in `do_refresh` returns `"shell"` (truthy) → bypasses the `if not ctx` close-branch → issues a `getSuggestions` RPC that pi returns `null` for (§17.1) → menu closes. S2 removes that wasted round-trip and points `!` lines at the daemon. It also makes `!` completion work even when the bridge is down (the daemon is a child of nvim, not pi).

---

## Why

- **Business value:** The routing half of the shell-completion seam (PRD §17). Without a `ctx == "shell"` branch in the fetch paths, S1's gate value is unrealized and a `!` line emits a wasted RPC.
- **Integration with existing features:** Additive — a new branch + a shared helper. The bridge path (slash/path/plain) is byte-identical and regression-tested. The shared `state.gen` makes shell↔bridge supersession correct out of the box.
- **Problems this solves, for whom:** Establishes the completion→daemon routing so the user's real shell completion engine (the thing pi's own provider does not provide, §17.1) is consulted for `!`/`!!` lines, including when Tab is pressed (force-fetch) and when the bridge is unreachable.

---

## What

### User-visible behavior
**None yet in S2.** S2 only changes internal routing (where the fetch goes). Visible shell completion arrives when S3 (`shell.complete_current`) lands; until then the shell branch is a silent no-op (forward-guarded). Document this so the implementer does not over-build into S3/S4.

### Technical requirements
1. `ctx == "shell"` routes the fetch to `require("pi-bridge.shell").complete_current(buf, cb)` — NOT `bridge.request`. Both `do_refresh` and `on_tab`/`force_fetch`.
2. The branch is reached BEFORE the `bridge.is_connected()` bail (shell completion does not depend on the bridge — the daemon is a child of nvim: §17.3, §17.13). A `!` line with no bridge still completes.
3. **Gen-guard supersession (shared):** the shell branch bumps + captures the SAME module-local `state.gen` the bridge path uses, so a shell↔bridge context switch + two shell keystrokes supersede correctly. The `cb` checks `if gen ~= state.gen then return end`.
4. **Layer-1 supersession (the slash→shell switch):** the shell branch `bridge.cancel(state.inflight_id)` any pending **bridge** request before bumping `gen` (frees the round-trip). `shell.lua` has NO cancel wire method (it's a local subprocess; its own `state.gen` + `pending_cb` supersede internally) — do NOT invent one.
5. **0 ms debounce:** `compute_debounce` returns `config.shell.debounce_ms` (default `0`) for a line-1 `!` (checked before the attachment branch). `!` lines are already non-attachment (so they'd fall to 0 anyway), but honoring the §17.11 config knob is the explicit contract.
6. **Fast-context safety:** the shell daemon's `cb` runs in **libuv fast context** (shell.lua:642/650 forward contract), NOT the main loop (unlike the bridge cb, which is `schedule_wrap`d). So the shell `cb` must `vim.schedule` the `on_results` menu hop; `state.last_result = {...}` is fast-safe (Lua table write). Never call `vim.api.*` directly from the shell `cb`.
7. **Never throws** (per-keystroke + autocmd contract): `pcall` every bridge/shell/external call; type-guard `shell.complete_current`; guard `buf` validity + currency.
8. **Forward-guard:** `if type(shell.complete_current) == "function"` → silent no-op until S3 lands. (Mirrors S1's inert intermediate-state posture.)
9. **No accept changes:** `on_tab` BRANCH 1 (menu open+selected → `M.accept`) is untouched. Shell accept is **P2.M2.T4** (`shell/accept.lua`). Tab on an OPEN shell menu (post-S3) hitting pi `applyCompletion` is a known intermediate wart (documented), NOT S2's to fix.

### Success Criteria
- [ ] `do_shell_fetch(buf)` helper implemented (gen-guard + cancel-bridge-inflight + forward-guarded `complete_current` + `vim.schedule(on_results)`).
- [ ] `do_refresh`: shell branch before `if not ctx`; bridge bail moved below it; bridge path byte-identical.
- [ ] `on_tab` BRANCH 2: shell branch before the bridge bail; slash/file logic unchanged.
- [ ] `force_fetch`: `opts.shell` seam added (delegates to `do_shell_fetch`).
- [ ] `compute_debounce`: shell-aware (returns `shell.debounce_ms`, default 0).
- [ ] `tests/completion_spec.lua`: new shell-routing cases (mocked `complete_current`) + regression guard; full suite green.
- [ ] No edits to `shell.lua`, `menu.lua`, `accept` paths, `ftplugin`, notices, health (S3/S4/S5 + P2.M2.T4).

---

## All Needed Context

### Context Completeness Check
A reader who knows nothing of this repo can implement S2 from: this PRP + the cited `completion.lua` regions (lines 316–360 `compute_debounce`, 416–515 `do_refresh`, 518–550 `force_fetch`, 758–820 `on_tab`) + `shell.lua`'s `complete_current` forward-contract comments (lines 420/436/642/650) + PRD §17.7 (quoted inline below). No daemon-internals knowledge is required — S2 only calls `complete_current(buf, cb)`; S3 owns its body.

### Documentation & References

```yaml
# MUST READ — the spec that defines this exact routing (verbatim code + rationale)
- url: PRD.md §17.7 "Routing in the plugin (completion.lua extension)"
  why: gives the EXACT branch skeleton do_refresh must add (ctx=="shell" → shell.complete_current
        with a gen-guarded cb identical to getSuggestions); explains line-1-only + ! vs !! equivalence
  critical: |
    the shell cb mirrors the getSuggestions cb SHAPE (gen-guard; err→touch-nothing; null→{items={},prefix=""};
    store last_result; fire on_results). Verbatim from the PRD:
      if ctx == "shell" then
        require("pi-bridge.shell").complete_current(buf, function(err, items, prefix)
          if gen ~= state.gen then return end          -- supersession (same gen-guard as getSuggestions)
          if err then return end                       -- silent degrade (notify dedup'd elsewhere)
          state.last_result = { items = items or {}, prefix = prefix or "" }
          if type(M.on_results)=="function" then pcall(M.on_results, buf, items or {}, prefix or "") end
        end)
        return
      end
- url: PRD.md §17.5.2 "shell.lua — reference skeleton" + §17.5 "The completion daemon"
  why: establishes the gen-guard supersession model shell.lua MIRRORS from completion.lua, + that
        ONLY ONE shell request is in-flight at a time (state.inflight; a new request supersedes)
  critical: |
    shell.lua's supersession is its OWN (state.gen + pending_cb); completion.lua's shell branch must
    bump COMPLETION's state.gen (the shared bridge/shell guard) so a bridge↔shell switch supersedes.
- url: PRD.md §17.9 "Trigger & UX parity with the TUI"
  why: "The <Tab>-closed path (force_fetch) forces an immediate fetch in shell context, mirroring the
        existing file-force behavior." → on_tab must route a `!` line to an immediate shell fetch.
  critical: shell Tab-force routes to the menu (on_results), NOT _route_or_accept — shell items are
            NOT pi items; pi's single-item auto-apply (editor.ts:2253) does not apply.
- url: PRD.md §17.11 "Configuration"
  why: defines shell.debounce_ms (default 0) — the "0 ms debounce" config knob S2 honors in compute_debounce
  critical: read defensively `(pi.config and pi.config.shell) or {}` — the shell={} config block is
            P2.M3.T6.S1 (not done yet); a nil config must NOT throw.
- url: PRD.md §17.3 "Architecture & integration points" + §17.13 "Security"
  why: the daemon is a child of the NVIM process, NOT pi; it never touches the bridge socket
  critical: |
    shell completion is BRIDGE-INDEPENDENT → a `!` line must route to the daemon EVEN IF the bridge is
    disconnected/nil. The do_refresh/on_tab bridge-connected bail must NOT gate the shell branch.
- url: PRD.md §17.14 "Coordinate & encoding notes (shell path)"
  why: shell uses BYTE offsets (no UTF-16 conversion); the shell branch needs NO coords.nvim_to_pi_coords call
  critical: do NOT pass `pi` coords to the shell path; on_tab's shell branch reads buf+cursor only.

# Codebase files to follow EXACTLY
- file: lua/pi-bridge/completion.lua
  why: the file being edited; the four regions cited (compute_debounce, do_refresh, force_fetch, on_tab)
  pattern: |
    do_refresh (416): guard buf → [S2: read lines+cursor, compute ctx, shell branch] → [S2: bridge bail]
              → if not ctx close → coords → supersede(L1 cancel + L2 gen) → bridge.request getSuggestions(cb).
    force_fetch (518): [S2: opts.shell→do_shell_fetch] → cancel_timer → supersede → bridge.request(cb).
    on_tab (758): BRANCH1 accept → [S2: read lines+cursor, compute ctx, shell→do_shell_fetch] → bridge bail
              → pi coords → is_slash_ctx → 2a/2b force_fetch.
    compute_debounce (339): [S2: shell→shell.debounce_ms(0)] → attachment→debounce_ms(20) → else 0.
  gotcha: |
    state.gen / state.inflight_id / state.debounce_timer are SHARED (completion.lua:217-225). The shell
    branch MUST bump state.gen (not a separate counter) so shell↔bridge supersession works. shell.lua's
    OWN state.gen is separate (the daemon's); completion.lua never touches it.
- file: lua/pi-bridge/shell.lua
  why: confirms complete_current is a FORWARD CONTRACT (grep → only docstring refs at 420/436/642/650);
        gives the cb signature + the fast-context constraint
  pattern: |
    -- shell.lua:642/650 (forward contract, verbatim):
    --   "The user `cb` runs in libuv FAST context → the consumer (P2.M2.T3.complete_current /
    --    P2.M2.T3.S2) must `vim.schedule` its editor-touching work (`M.on_results` → the menu hop
    --    is NOT fast-safe; `state.last_result = {}` is). FLAG FOR P2.M2.T3.S2."
    -- cb signature (consumed by S2): cb(err, items, prefix) where items is AutocompleteItem[] (already
    --   normalized by shell.lua _feed) + prefix is a string (may be "").
  gotcha: |
    DO NOT implement complete_current in S2 (it is S3). DO NOT spawn/read the daemon from completion.lua
    (shell.lua owns that). DO NOT call bridge.cancel for a shell request (no such method; the daemon
    supersedes internally). The shell cb is FAST-context — vim.schedule the menu hop (see §Known Gotchas).
- file: lua/pi-bridge/menu.lua
  why: confirms on_results MUST fire on the nvim MAIN LOOP (menu.lua:66: "NO schedule_wrap ON on_results:
        S30 fires on_results on the nvim MAIN LOOP (the bridge cb is schedule_wrap'd)")
  pattern: completion.on_results = function(buf, items, prefix) ... end (wired by menu.attach)
  gotcha: |
    the bridge path's cb is pre-schedule_wrap'd by bridge.lua → lands on the main loop (no extra schedule).
    The SHELL path's cb is FAST-context → MUST vim.schedule on_results (or it throws E5560 / corrupts UI).
- file: tests/completion_spec.lua
  why: the test harness; fake_bridge() + reset() + populated_menu() patterns; the S1 direct-unit block
        at line ~1057 (the completion_context gate cases)
  pattern: |
    -- fake bridge: pi.bridge = fake_bridge() with .request/.cancel/.is_connected/.resolve/.resolve_last
    -- reset(): pi.bridge=nil; completion.on_results=nil; completion.reset(); menu.reset(); restore debounce_ms
    -- async wait: vim.wait(ms, predicate, 5)  (mirrors bridge_request_spec)
  gotcha: |
    MOCK shell.complete_current by setting require("pi-bridge.shell").complete_current = fake_fn (the module
    table is cached, so this mutates the live module). reset() MUST restore it (save the prior value, which
    is nil until S3) so cases don't leak. Do NOT add a real daemon to the test.

# Internal architecture (read-only; NOT edited by S2)
- file: plan/002_d23d7473c16c/P2M2T3S1/research/notes.md
  why: documents the S1→S2 intermediate state (a `!` line currently issues one wasted getSuggestions RPC)
        that S2 removes
  pattern: S2 is the "route ctx=='shell' → shell.*" deliverable S1 explicitly deferred
  gotcha: S1's gate + S2's routing together make the seam; neither alone renders shell completions (S3 does).
```

### Current codebase tree (relevant slice)

```bash
pi-nvim-bridge/
├── lua/pi-bridge/
│   ├── completion.lua     # ← EDIT (do_shell_fetch helper + do_refresh/on_tab/force_fetch/compute_debounce branches)
│   ├── shell.lua          # complete_current is a FORWARD CONTRACT here (S3) — NOT edited by S2
│   └── menu.lua           # on_results consumer (main-loop) — NOT edited by S2
├── tests/
│   ├── completion_spec.lua   # ← EDIT (add shell-routing describe block; mock complete_current in reset)
│   └── minimal_init.lua      # plenary harness bootstrap (read-only)
└── PRD.md  (§17.3, §17.5.2, §17.7, §17.9, §17.11, §17.13, §17.14 — read-only reference)
```

### Desired codebase tree with files changed

```bash
lua/pi-bridge/completion.lua      # MODIFIED — +do_shell_fetch helper; do_refresh/on_tab shell branches;
                                  #            force_fetch opts.shell seam; compute_debounce shell-awareness
tests/completion_spec.lua         # MODIFIED — +describe("shell routing (§17.7)", …) + mock complete_current in reset()
```

### Known Gotchas of our codebase & Library Quirks

```lua
-- CRITICAL: AGENTS.md ⛔ HARD RULE — NEVER pipe a heredoc / stdin into nvim (it HANGS the session).
-- Write any ad-hoc test snippet to a .lua FILE, then run  +"luafile <file>" +qa .
-- Always wrap nvim invocations in `timeout` (e.g. `timeout 90 nvim …`).

-- CRITICAL: the shell daemon's cb runs in LIBUV FAST CONTEXT (shell.lua:642/650), NOT the nvim main loop
-- (unlike the bridge cb, which bridge.lua schedule_wrap's). So the shell cb MUST:
--   * do the gen-guard + state.last_result write DIRECTLY (fast-safe: table read/write, single-threaded);
--   * vim.schedule() the M.on_results(buf, items, prefix) call (it drives the menu — NOT fast-safe;
--     :help E5560). Forgetting this throws E5560 or corrupts the floating window mid-redraw.
-- Contrast: the BRIDGE cb needs NO extra schedule (it's already on the main loop). This asymmetry is the
-- #1 implementation trap in S2 — the shell branch is NOT a copy-paste of the bridge cb.

-- CRITICAL: state.gen is the SHARED supersession guard (completion.lua:223). The shell branch bumps the
-- SAME state.gen the bridge path bumps — do NOT introduce a separate shell-gen counter, or a slash→shell
-- (or shell→slash) switch will NOT supersede and stale menus will flicker. (shell.lua has its OWN state.gen
-- for the daemon's in-flight request; completion.lua never touches that one.)

-- GOTCHA: shell completion is BRIDGE-INDEPENDENT (the daemon is a child of nvim — §17.3/§17.13). The
-- do_refresh/on_tab "if not bridge.is_connected() then return end" bail MUST sit BELOW the shell branch,
-- or a `!` line with no bridge silently no-ops. Restructure: read lines+cursor → compute ctx → shell branch
-- → (only slash/path) bridge bail → bridge path.

-- GOTCHA: shell.lua has NO cancel wire method (it's a local subprocess; it supersedes internally via its
-- own state.gen + overwriting state.pending_cb). The shell branch's layer-1 supersession cancels only a
-- pending BRIDGE request (the slash→shell switch); it does NOT (cannot) cancel the shell request — calling
-- shell.complete_current again naturally supersedes at the daemon layer.

-- GOTCHA: shell.complete_current is a FORWARD CONTRACT (S3, not defined yet). Guard
-- `if type(shell.complete_current) == "function"` so S2 is a silent no-op until S3 lands. The cb signature
-- is (err, items, prefix); items is already AutocompleteItem[] (shell.lua _feed normalizes).

-- GOTCHA: read config + bridge + shell FRESH inside each function (lazy require), NEVER at module load.
-- The handshake is ASYNC (pi.bridge is nil at first-require) + tests swap fakes AFTER require. Caching
-- breaks both. (Mirrors completion.lua's header note L67 + shell.lua's FRESH-READS note.)

-- GOTCHA: do NOT pass pi coords (UTF-16) to the shell path. Shell uses BYTE offsets (§17.14). on_tab's
-- shell branch reads buf + cursor only; do_shell_fetch(buf) takes just the buf (shell.complete_current
-- reads the buffer itself in S3).

-- GOTCHA: keep `do_refresh`/`force_fetch`/`on_tab`/`compute_debounce` as the existing `local function`/
-- `function M.X` declarations; ADD the shell branch + the do_shell_fetch helper. Do not rewrite the bridge
-- path (it is exhaustively S30/S33-tested — additive-over-refactor is the codebase pattern).
```

---

## Implementation Blueprint

### Data models and structure
N/A — S2 adds no data model. It adds one shared helper + four branches, all operating on the EXISTING `state` table (`gen`, `inflight_id`, `last_result`) and the EXISTING `on_results` seam. The shell items are the same `AutocompleteItem` shape the bridge returns (shell.lua `_feed` normalizes them), so the menu renders them identically.

### Implementation Tasks (ordered by dependencies)

```yaml
Task 1: EDIT lua/pi-bridge/completion.lua — add the do_shell_fetch(buf) helper
  - LOCATE: the `local function cancel_timer() … end` block (~line 350-360) — add do_shell_fetch as a
    SIBLING local helper AFTER it + AFTER the `local do_refresh` / `local force_fetch` forward declarations
    (~line 309-311) so it can reference state + M.on_results. Place it BEFORE do_refresh's definition
    (do_refresh calls it).
  - NAMING: `local function do_shell_fetch(buf)` (lowerCamelCase-into-snake per the repo: do_refresh,
    force_fetch, _route_or_accept, hide_and_cancel, cancel_timer).
  - IMPLEMENT (NEVER throws; pcall every external call; reads bridge/shell/config FRESH):
      local function do_shell_fetch(buf)
        -- read bridge FRESH (only for canceling a pending BRIDGE request on a slash→shell switch)
        local bridge = require("pi-bridge").bridge
        -- layer 1: cancel any in-flight BRIDGE request (shell.lua has no cancel — it supersedes internally)
        if state.inflight_id and bridge and type(bridge.cancel) == "function" then
          pcall(bridge.cancel, state.inflight_id)
        end
        state.inflight_id = nil
        -- layer 2: gen-guard (SHARED with the bridge path — the shell↔bridge supersession boundary)
        state.gen = state.gen + 1
        local gen = state.gen
        -- FORWARD CONTRACT: shell.complete_current(buf, cb) is S3 (P2.M2.T3.S3). Not yet defined →
        -- silent no-op (S2→S3 intermediate state; mirrors S1's posture). cb(err, items, prefix).
        local shell = require("pi-bridge.shell")
        if type(shell.complete_current) ~= "function" then
          dbg("[do_shell_fetch] shell.complete_current NOT defined (S3) — silent degrade")
          return
        end
        pcall(shell.complete_current, buf, function(err, items, prefix)
          -- ⚠ FAST CONTEXT (libuv — shell.lua:642/650). gen-guard + state write are fast-safe;
          -- the on_results menu hop is NOT → vim.schedule it (:help E5560).
          if gen ~= state.gen then return end          -- STALE (superseded) — drop, touch nothing
          state.inflight_id = nil
          if err then dbg("[do_shell_fetch.cb] ERR=" .. tostring(err)); return end  -- silent degrade (S4 notifies)
          local its = items  or {}
          local pfx = prefix or ""
          state.last_result = { items = its, prefix = pfx }   -- fast-safe (Lua table write)
          if type(M.on_results) == "function" then
            vim.schedule(function() pcall(M.on_results, buf, its, pfx) end)  -- fast→main loop (menu hop)
          end
        end)
      end
  - DEPENDENCIES: none (state + M.on_results + dbg already exist).

Task 2: EDIT lua/pi-bridge/completion.lua — do_refresh shell branch + restructure
  - LOCATE: `do_refresh = function(buf)` (~line 416). The current flow is: guard buf (417-418) → READ
    BRIDGE + bail if not connected (422-427) → READ lines+cursor (431-434) → ctx (447) → if not ctx
    close (448-454) → coords → supersede → bridge.request.
  - RESTRUCTURE (move the lines/cursor read + ctx computation ABOVE the bridge bail; insert shell branch):
      do_refresh = function(buf)
        if type(buf) ~= "number" or not vim.api.nvim_buf_is_valid(buf) then return end
        if buf ~= vim.api.nvim_get_current_buf() then return end
        -- READ buffer lines + cursor FIRST (the shell branch does NOT need the bridge — §17.3/§17.13;
        -- only the slash/path branch does, so the bridge-connected bail moves BELOW the ctx computation).
        local ok, lines = pcall(vim.api.nvim_buf_get_lines, buf, 0, -1, false)
        if not ok or type(lines) ~= "table" then return end
        local cur
        ok, cur = pcall(vim.api.nvim_win_get_cursor, 0)
        if not ok or type(cur) ~= "table" then return end
        local row, byte_col = cur[1], cur[2]
        local ctx = completion_context(lines, row - 1, byte_col)
        -- ── SHELL CONTEXT (§17.7): route to the shell daemon, NOT the bridge ──
        if ctx == "shell" then
          do_shell_fetch(buf)
          return
        end
        if not ctx then
          dbg(...)                                           -- keep the existing dbg line
          if type(M.on_results) == "function" then pcall(M.on_results, buf, {}, "") end
          return
        end
        -- READ BRIDGE FRESH (only the slash/path path needs it)
        local pi_mod = require("pi-bridge")
        local bridge = pi_mod.bridge
        if not bridge or type(bridge.is_connected) ~= "function" or not bridge.is_connected() then
          dbg("[do_refresh] NOT CONNECTED — bail")
          return
        end
        -- …the rest (coords → supersede → bridge.request getSuggestions) is BYTE-IDENTICAL to today…
      end
  - DO NOT touch the bridge path below the shell branch (coords/supersede/RPC/cb stay byte-identical).
  - DEPENDENCIES: Task 1 (do_shell_fetch must exist).

Task 3: EDIT lua/pi-bridge/completion.lua — force_fetch opts.shell seam
  - LOCATE: `force_fetch = function(buf, pi, opts, on_items)` (~line 518). The FIRST statement is
    `cancel_timer()`.
  - INSERT at the very TOP of the body (before `cancel_timer()`):
      -- §17.9: shell Tab-force routes to the shell daemon (NOT the bridge). on_tab detects ctx=="shell"
      -- and calls do_shell_fetch directly; this seam lets a future caller drive it via force_fetch too.
      if opts and opts.shell == true then
        do_shell_fetch(buf)
        return
      end
  - DO NOT touch the rest of force_fetch (cancel_timer → supersede → bridge.request stays byte-identical).
  - DEPENDENCIES: Task 1.

Task 4: EDIT lua/pi-bridge/completion.lua — on_tab BRANCH 2 shell branch + restructure
  - LOCATE: `function M.on_tab(buf)` (~line 758). BRANCH 2 starts ~line 767:
    `local bridge = require("pi-bridge").bridge` (768) → bail if not connected → read lines+cursor
    (~773-778) → `local pi = coords.nvim_to_pi_coords(...)` (780) → before/trimmed/is_slash_ctx → 2a/2b.
  - RESTRUCTURE BRANCH 2 (read lines+cursor + compute ctx BEFORE the bridge bail; insert shell branch):
      -- ── BRANCH 2 (menu CLOSED): pi handleTabCompletion (editor.ts:2126) ──
      -- Read lines + cursor FIRST (the shell branch does not need the bridge).
      local ok, lines = pcall(vim.api.nvim_buf_get_lines, buf, 0, -1, false)
      if not ok or type(lines) ~= "table" then return false end
      local cur
      ok, cur = pcall(vim.api.nvim_win_get_cursor, 0)
      if not ok or type(cur) ~= "table" then return false end
      -- ── SHELL CONTEXT (§17.9): force an immediate shell fetch (mirrors file-force; 0 debounce) ──
      if completion_context(lines, cur[1] - 1, cur[2]) == "shell" then
        do_shell_fetch(buf)
        return true                       -- Tab CONSUMED
      end
      -- bridge-connected check (only the slash/file paths need the bridge)
      local bridge = require("pi-bridge").bridge
      if not bridge or type(bridge.is_connected) ~= "function" or not bridge.is_connected() then
        return false
      end
      -- …the rest (pi coords → before/trimmed → is_slash_ctx → 2a/2b force_fetch) is BYTE-IDENTICAL…
  - DO NOT touch BRANCH 1 (menu open+selected → M.accept) — shell accept is P2.M2.T4.
  - DEPENDENCIES: Task 1.

Task 5: EDIT lua/pi-bridge/completion.lua — compute_debounce shell-awareness (the 0 ms debounce)
  - LOCATE: `local function compute_debounce(lines, cursorLine, cursorCol)` (~line 339). The first body
    line is `local line = (type(lines) == "table") and (lines[cursorLine + 1] or "") or ""`.
  - INSERT at the TOP of the body, BEFORE the existing `local line = …`:
      -- §17.11: shell context uses config.shell.debounce_ms (default 0 — immediate; the daemon is warm
      -- after first use + the per-shell engine is fast). Checked BEFORE the attachment check (a "!git ch"
      -- line is non-attachment → would otherwise fall to the 0-ms default, which happens to match, but
      -- honoring the config knob is the explicit §17.11 contract). Read defensively (the shell={}
      -- config block is P2.M3.T6.S1, not done yet — a nil config must NOT throw).
      local line1 = (type(lines) == "table") and (lines[1] or "") or ""
      if cursorLine == 0 and line1:sub(1, 1) == "!" then
        local pi = require("pi-bridge")
        local cfg = (pi.config and pi.config.shell) or {}
        local ms = cfg.debounce_ms
        if type(ms) ~= "number" or ms < 0 then ms = 0 end
        return math.max(0, math.floor(ms))
      end
  - DO NOT touch the rest of compute_debounce (the attachment + else-0 branches stay byte-identical).
  - DEPENDENCIES: none.

Task 6: EDIT tests/completion_spec.lua — mock complete_current in reset() + add the shell-routing cases
  - LOCATE: the `local function reset()` (~line 75). It does `pi.bridge = nil; completion.on_results = nil;
    pcall(completion.reset); pcall(menu.reset); restore debounce_ms`.
  - ADD to reset(): save + restore `require("pi-bridge.shell").complete_current` so a case's fake does not
    leak (it is nil until S3). Save ONCE at module load (or in a before-each); restore in reset():
      -- at the top of the file (after `local pi = require("pi-bridge")`):
      local shell_mod = require("pi-bridge.shell")
      -- in reset():
      shell_mod.complete_current = nil        -- restore to the pre-S3 state (nil); cases set their own fake
  - LOCATE: a SIBLING of the `describe("error/cancelled/timeout -> touch nothing", …)` block or the
    S30 supersession cases (~line 256-290). Add a NEW describe block:
      describe("shell routing (ctx == 'shell') — §17.7", function() … end)
  - IMPLEMENT a fake complete_current (mirrors fake_bridge): store the cb; resolve via fake.resolve(err,items,prefix).
      local function fake_shell()
        local self = { calls = {}, last_cb = nil }
        function self.complete_current(buf, cb)
          self.calls[#self.calls + 1] = { buf = buf, cb = cb }
          self.last_cb = cb
        end
        function self.resolve(err, items, prefix)
          if self.last_cb then vim.schedule_wrap(self.last_cb)(err, items, prefix) end
        end
        return self
      end
  - CASES (use populated_menu-style buffer setup; set shell_mod.complete_current = fake.complete_current;
    set pi.bridge = fake_bridge() ONLY where the case needs it — several cases use bridge==nil):
      1. "!git ch" do_refresh → fake_shell.calls has 1 call; fake_bridge.requests has 0 (no getSuggestions).
      2. "!git ch" with pi.bridge = nil → still calls complete_current (bridge-independent; never throws).
      3. gen-guard: two "!g" refreshes → resolve the STALE (1st) cb with items → on_results fires 0 times;
         resolve the 2nd → on_results fires once + last_result == the 2nd items.
      4. slash→shell switch: "/mod" refresh (bridge inflight) → change buffer to "!git" → refresh →
         fake_bridge.cancels contains the bridge inflight id (layer 1) + complete_current called.
      5. on_tab "!git" (menu closed) → complete_current called immediately (no debounce wait); on_tab
         returns true (Tab consumed). (Use vim.wait to let the 0-ms defer + the immediate call settle.)
      6. shell err: resolve("daemon down", nil, nil) → on_results NOT called; never throws; last_result
         untouched (pre-seed it first).
      7. 0 ms debounce: three rapid "!g" refreshes (no wait) → at most one complete_current call after
         the collapse window (mirror the S30 debounce-collapse case).
      8. REGRESSION: "/mod" (slash), "@app" (path), "hello" (plain) → fake_bridge.requests has the
         getSuggestions; fake_shell.calls is empty (shell NOT consulted for non-bang lines).
  - PLACEMENT: alongside the other integration describes (after the S30 supersession block).
  - DEPENDENCIES: Tasks 1-5 (the routing must exist).

Task 7: VERIFY — run the gates (no file changes)
  - RUN: the plenary command in Validation Loop → Level 2 for tests/completion_spec.lua.
  - EXPECT: all green (new shell-routing cases + the full existing suite). If an existing case fails, it is
    almost certainly the do_refresh/on_tab restructure moving the bridge bail — RE-CHECK that the bridge
    path's behavior (slash/path/plain) is byte-identical below the shell branch. Do NOT weaken the new branch.
```

### Implementation Patterns & Key Details

```lua
-- === do_shell_fetch(buf): the shared shell-fetch helper (Task 1) ===
-- Key invariants:
--   * bumps the SHARED state.gen (shell↔bridge supersession); captures `gen` in the cb closure.
--   * cancels a pending BRIDGE inflight (the slash→shell switch); shell.lua has no cancel.
--   * forward-guards complete_current (S3) → silent no-op until S3 lands.
--   * the cb is FAST-CONTEXT → gen-guard + state.last_result write are direct; on_results is vim.scheduled.
local function do_shell_fetch(buf)
  local bridge = require("pi-bridge").bridge
  if state.inflight_id and bridge and type(bridge.cancel) == "function" then
    pcall(bridge.cancel, state.inflight_id)           -- layer 1 (slash→shell switch)
  end
  state.inflight_id = nil
  state.gen = state.gen + 1; local gen = state.gen     -- layer 2 (gen-guard)
  local shell = require("pi-bridge.shell")
  if type(shell.complete_current) ~= "function" then return end   -- forward-guard (S3)
  pcall(shell.complete_current, buf, function(err, items, prefix)
    if gen ~= state.gen then return end                 -- STALE — drop
    state.inflight_id = nil
    if err then return end                              -- silent degrade (S4 notifies once)
    local its, pfx = items or {}, prefix or ""
    state.last_result = { items = its, prefix = pfx }   -- fast-safe
    if type(M.on_results) == "function" then
      vim.schedule(function() pcall(M.on_results, buf, its, pfx) end) end   -- fast→main loop
  end)
end

-- === The do_refresh restructure (Task 2) — the ONE non-obvious move ===
-- The bridge-connected bail MOVES BELOW the shell branch. Before: bridge-check → lines → ctx.
-- After: lines → ctx → shell-branch → bridge-check → bridge-path. Reason: shell completion does
-- NOT need the bridge (the daemon is a child of nvim). A `!` line with no bridge must still route.

-- === The on_tab restructure (Task 4) — same move, BRANCH 2 ===
-- Read lines+cursor + compute ctx BEFORE the bridge bail. shell → do_shell_fetch + return true.
-- BRANCH 1 (accept) is UNTOUCHED (shell accept is P2.M2.T4).

-- === Why this is EXACTLY §17.7 + §17.9 (and not more) ===
-- * do_shell_fetch mirrors the getSuggestions cb SHAPE (gen-guard; err→touch-nothing; null→{items={}};
--   store; on_results) — the PRD §17.7 skeleton verbatim, + the vim.schedule the fast-context constraint
--   forces (the ONE refinement over the PRD sketch; documented per the codebase's "document every
--   refinement over PRD/docs" pattern).
-- * compute_debounce shell-awareness (§17.11) is the "0 ms debounce" deliverable.
-- * on_tab shell force (§17.9) routes to the menu (on_results), NOT _route_or_accept — shell items are
--   plain words, not pi AutocompleteItems.
```

### Integration Points

```yaml
ROUTING (the S2 deliverable):
  - do_refresh (completion.lua ~416): +`if ctx == "shell" then do_shell_fetch(buf); return end` (before
    `if not ctx`); bridge bail moved below. Bridge path byte-identical.
  - on_tab (completion.lua ~758 BRANCH 2): +`if completion_context(...) == "shell" then do_shell_fetch(buf);
    return true end` (before the bridge bail). BRANCH 1 + 2a/2b unchanged.
  - force_fetch (completion.lua ~518): +`if opts.shell then do_shell_fetch(buf); return end` (top of body).

SUPERSESSION (shared, the "gen-guard" deliverable):
  - state.gen (completion.lua:223): the shell branch bumps the SAME counter the bridge path bumps.
  - state.inflight_id: the shell branch cancels a pending BRIDGE id (layer 1); shell.lua has no cancel.

DEBOUNCE (the "0 ms debounce" deliverable):
  - compute_debounce (completion.lua ~339): +shell-aware branch (returns config.shell.debounce_ms, default 0).

FORWARD CONTRACT (do NOT implement in S2):
  - shell.complete_current(buf, cb) → S3 (P2.M2.T3.S3): reads buf, strips bangs, computes byte offsets,
    calls shell.request. S2 forward-guards `type(...) == "function"` → silent no-op until S3.
  - §17.4.3 mismatch notice / §17.9 first-run hint / §17.12 degrade notify → S4 (P2.M2.T3.S4).
  - menu visual_cue ($ gutter) → S5 (P2.M2.T3.S5).
  - shell accept (local word-replacement + quoting) → P2.M2.T4 (shell/accept.lua); on_tab BRANCH 1 untouched.

CONFIG:
  - reads (defensively): config.shell.debounce_ms (default 0). The shell={} block is P2.M3.T6.S1 (not done).
```

---

## Validation Loop

### Level 1: Syntax & Style (Immediate Feedback)

```bash
# From the repo root. Confirm the edited module LOADS with no Lua syntax/parse error.
# ⛔ NEVER heredoc→nvim stdin (AGENTS.md HARD RULE). Write to a FILE, then :luafile it.
cat > /tmp/s2_loadcheck.lua <<'LUA'
local ok, m = pcall(require, "pi-bridge.completion")
assert(ok, "require failed: " .. tostring(m))
-- the existing surface is intact
assert(type(m.refresh) == "function" and type(m.on_tab) == "function")
-- the S1 gate still works (regression)
assert(m.completion_context({"!git ch"}, 0, 4) == "shell", "shell gate")
assert(m.completion_context({"/model"}, 0, 6) == "slash", "slash regression")
-- shell.complete_current is a forward contract (nil until S3) — loading must NOT have called it
assert(type(require("pi-bridge.shell").complete_current) ~= "function", "S3 not landed yet")
print("S2_LOAD_OK")
LUA
timeout 30 nvim --headless --clean -u NORC -c 'set rtp+=.' +"luafile /tmp/s2_loadcheck.lua" +qa
echo "exit=$?   # 0 = pass (prints S2_LOAD_OK)"

# stylua formatting check (if the repo uses it — matches CI in PRD §14):
# stylua --check lua/pi-bridge/completion.lua tests/completion_spec.lua
```

### Level 2: Unit Tests (Component Validation) — THE GATE

```bash
# The plenary suite for the edited file. This is S2's primary validation gate.
timeout 90 nvim --headless --clean -u tests/minimal_init.lua \
  -c 'lua require("plenary.busted").run("tests/completion_spec.lua")'
echo "exit=$?   # 0 = all green (new shell-routing cases + existing suite)"

# (Optional, fast feedback) plenary-free smoke — confirms no load regression:
timeout 60 nvim --headless --clean -u NORC +"luafile tests/completion_smoke.lua" +qa
echo "exit=$?"
```

### Level 3: Integration Testing (System Validation)
N/A for S2 in isolation. The shell daemon + `complete_current` are S3; S2's routing is exercised end-to-end
only once S3 lands (the mocked `complete_current` in Task 6 IS the integration proof at the routing layer).
Per AGENTS.md: the plenary spec + file-based smoke cover the end-to-end surface; do NOT invent a stdin-based
nvim E2E. (Once S3 lands, a `tests/completion_shell_smoke.lua` driving a real fish/zsh daemon is the natural
follow-on — out of scope for S2.)

### Level 4: Creative & Domain-Specific Validation
N/A for S2 (no UI, no daemon, no health-check, no docs to ship — those are S3/S4/S5).

---

## Final Validation Checklist

### Technical Validation
- [ ] Level 1 load-check prints `S2_LOAD_OK`, exit 0.
- [ ] `tests/completion_spec.lua` plenary run exits 0 (new `describe("shell routing (§17.7)", …)` + full existing suite).
- [ ] `tests/completion_smoke.lua` (optional) still exits 0 (no load regression).
- [ ] No nvim command in this PRP pipes a heredoc into nvim stdin (AGENTS.md ⛔ HARD RULE); every nvim invocation is wrapped in `timeout`.

### Feature Validation
- [ ] `!` line → `do_refresh` calls `complete_current`; issues ZERO `getSuggestions` RPCs (case 1).
- [ ] `!` line with `pi.bridge == nil` → still routes to `complete_current`; never throws (case 2).
- [ ] Two `!` keystrokes → stale shell cb dropped at the gen-guard; `on_results` fires once (case 3).
- [ ] slash→shell switch → `bridge.cancel(prev inflight)` called + `complete_current` called (case 4).
- [ ] `<Tab>` on a `!` line (menu closed) → `complete_current` immediate; `on_tab` returns `true` (case 5).
- [ ] shell `err` → silent degrade; `on_results` NOT called; `last_result` untouched (case 6).
- [ ] 0 ms debounce: rapid `!` refreshes collapse to ≤ 1 `complete_current` call (case 7).
- [ ] Regression: `/mod` / `@app` / `hello` → `getSuggestions`; `complete_current` NOT called (case 8).

### Code Quality Validation
- [ ] `do_shell_fetch` is a single shared helper (DRY); both `do_refresh` + `on_tab` route to it.
- [ ] The shell cb `vim.schedule`s `on_results` (fast-context → main loop) — the #1 trap, documented.
- [ ] The shell branch bumps the SHARED `state.gen` (not a separate counter).
- [ ] The bridge path (slash/path/plain) below the shell branch is byte-identical to today.
- [ ] Reads of bridge/shell/config are FRESH (lazy `require`), never module-load-cached.
- [ ] No edits to `shell.lua`, `menu.lua`, `accept` paths, `ftplugin`, notices, health.
- [ ] Comments reference PRD §17.7/§17.9/§17.11 + shell.lua's fast-context forward contract.

### Documentation & Deployment
- [ ] Code is self-documenting (the `-- §17.7`/`-- FAST CONTEXT` comments explain the routing + the schedule).
- [ ] No new env vars, install steps, or config blocks (the `shell={}` block is P2.M3.T6.S1).

---

## Anti-Patterns to Avoid

- ❌ **Do NOT copy-paste the bridge cb into the shell branch without `vim.schedule`.** The bridge cb is `schedule_wrap`d by bridge.lua (main loop); the shell cb is FAST-context (libuv). Forgetting `vim.schedule(on_results)` throws E5560 or corrupts the floating window. `state.last_result = {...}` is fast-safe; the menu hop is NOT.
- ❌ **Do NOT introduce a separate shell gen counter.** Use the SHARED `state.gen` so a slash↔shell switch supersedes. (shell.lua's own `state.gen` is the daemon's — leave it alone.)
- ❌ **Do NOT gate the shell branch on `bridge.is_connected()`.** Shell completion is bridge-independent (the daemon is a child of nvim — §17.3/§17.13). Keep the bridge bail BELOW the shell branch in both `do_refresh` and `on_tab`.
- ❌ **Do NOT call `bridge.cancel` for a shell request.** shell.lua has no cancel wire method (it's a local subprocess; it supersedes internally via its own gen + `pending_cb`). The shell branch cancels only a pending BRIDGE request (the slash→shell switch).
- ❌ **Do NOT implement `shell.complete_current` in S2.** It is S3. Forward-guard `type(...) == "function"` so S2 is a silent no-op until S3 lands. Do NOT spawn/read the daemon from completion.lua.
- ❌ **Do NOT route the shell Tab-force through `_route_or_accept`.** Shell items are plain words, not pi `AutocompleteItem`s; pi's single-item auto-apply (editor.ts:2253) does not apply. Route to `on_results` (menu population); shell accept is P2.M2.T4.
- ❌ **Do NOT pass pi coords (UTF-16) to the shell path.** Shell uses BYTE offsets (§17.14). `do_shell_fetch(buf)` takes just the buf.
- ❌ **Do NOT touch `on_tab` BRANCH 1 (accept).** Shell accept is P2.M2.T4; the intermediate-state "Tab on an open shell menu hits pi applyCompletion" wart is theirs to fix, not S2's.
- ❌ **Do NOT rewrite the bridge path.** The coords/supersession/RPC/cb below the shell branch is exhaustively S30/S33-tested — additive-over-refactor is the codebase pattern.
- ❌ **Do NOT pipe a heredoc into `nvim` stdin** (AGENTS.md ⛔ HARD RULE — it hangs the session). Write test snippets to a `.lua` file and run with `+"luafile <file>" +qa`. Never run a bare nvim without `timeout`.

---

## Confidence Score

**8.5/10** for one-pass success. The routing is precisely specified by PRD §17.7 (verbatim skeleton) + §17.9/§17.11, with a clear forward-contract (`complete_current`, mocked in tests) and a well-established test harness (`fake_bridge` pattern, easily adapted to `fake_shell`). The shared `state.gen` + the `do_shell_fetch` helper make the supersession correct by construction. The two residual risks, both explicitly fenced by Anti-Patterns + Success Criteria: (1) the **fast-context `vim.schedule` asymmetry** (the shell cb differs from the bridge cb — the #1 trap; documented in 4 places); (2) the **do_refresh/on_tab restructure** moving the bridge bail below the shell branch (a careless edit could disturb the byte-identical bridge path — the regression-guard case 8 catches it). The forward-guard makes S2 inert until S3 lands, so it cannot break the live plugin even if a detail is off.