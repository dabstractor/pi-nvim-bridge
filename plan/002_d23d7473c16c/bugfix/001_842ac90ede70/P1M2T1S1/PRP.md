---
name: "P1.M2.T4.S1 — Issue 3: bump state.gen + cancel inflight in do_refresh's ctx==nil branch"
description: |
  A 9-line fix in `lua/pi-bridge/completion.lua` + two plenary cases in
  `tests/completion_spec.lua`. The `do_refresh(buf)` `ctx==nil` (plain-typing) branch
  (~lines 543-548) closes the menu via `pcall(M.on_results, buf, {}, "", nil)` and returns
  WITHOUT bumping `state.gen` or canceling a pending BRIDGE inflight — the ONLY branch that
  skips both supersession layers. So deleting the leading `!` while a shell request is in
  flight lets the stale shell cb (whose closure captured `gen=N`) pass the gen-guard
  (`if gen ~= state.gen then return end`, L431) and `vim.schedule` on_results → the menu
  RE-OPENS for a buffer that no longer starts with `!`. Fix: BEFORE the existing close call,
  add layer 1 (cancel a pending BRIDGE inflight: `local b = require("pi-bridge").bridge;
  if state.inflight_id and b and type(b.cancel)=="function" then pcall(b.cancel,
  state.inflight_id) end; state.inflight_id = nil`) + layer 2 (`state.gen = state.gen + 1`).
  This mirrors the do_shell_fetch block (L414-419) + the slash/path block (L562-568). Shell
  requests have NO cancel wire (shell.lua has no cancel method) — the gen-guard is the SOLE
  protection against a late shell cb; the bump is essential. Tests: (A) shell→nil — inject a
  fake `shell.complete_current` that captures the cb, refresh "!git c" (gen=N, cb captured),
  edit to "git c", refresh (ctx==nil → close + gen=N+1), fire the stale shell cb → assert the
  on_results seam counter did NOT increment (gen-guard dropped it); (B) slash→nil — proves
  layer 1: refresh "/mod" (bridge inflight id1), edit to "mod", refresh (ctx==nil →
  cancel(id1) + gen bump), assert `fake.cancels[1]==id1` AND the stale bridge cb is dropped.
  Both use `fake_bridge({auto_cancel_fires=false})` + the file's `wait_for`/buffer helpers.
  NARROW: ONLY the `if not ctx then` block. No do_shell_fetch/slash-path/force_fetch/
  on_commands_changed change, no bridge.lua/shell.lua/menu.lua change, no shell-cancel wire,
  no config/env/API/doc surface change.
---

## Goal

**Feature Goal**: Eliminate the supersession race in `do_refresh`'s plain-typing branch: when
a user deletes the leading `!` (or `/`, or any trigger char) while a completion request is in
flight, the late response MUST NOT re-open the menu. Today the `ctx==nil` branch closes the
menu but does not bump `state.gen` or cancel the inflight request, so a stale shell cb passes
the gen-guard and re-opens the shell menu for a now-plain buffer (PRD §h3.3 Issue 3).

**Deliverable** (all under the repo root):
1. **MODIFY** `lua/pi-bridge/completion.lua` — in the `if not ctx then` block of `do_refresh`
   (~lines 543-548), insert the two supersession layers (cancel BRIDGE inflight + bump gen)
   BEFORE the existing `pcall(M.on_results, buf, {}, "", nil)` close call. 2-space indent
   (matches the file). ~9 inserted lines + comments.
2. **MODIFY** `tests/completion_spec.lua` — append TWO plenary `it(...)` cases inside the
   `describe("pi-bridge.completion", ...)` block: (A) the shell→nil race (the exact bug
   repro, layer-2 gen-guard) and (B) the slash→nil transition (layer-1 cancel + layer-2
   gen-guard). Both reuse the file's existing `fake_bridge`/`wait_for`/buffer-setup helpers.
3. **NO CHANGE** to any other branch, file, config, env var, API surface, or doc.

**Success Definition**:
- With buffer `"!git c"` (shell request in flight, cb captured) then edited to `"git c"`:
  the stale shell cb is DROPPED by the gen-guard → `on_results` does NOT re-fire → menu does
  NOT re-open. (Proven by Case A: seam counter stays at the post-close value 1.)
- The `ctx==nil` branch now cancels a pending BRIDGE inflight (proven by Case B:
  `fake.cancels[1] == id1`), mirroring the slash/path + do_shell_fetch blocks.
- Every existing `tests/completion_spec.lua` case (incl. (4) slash→slash supersession) +
  sibling specs (`completion_*`, `menu_*`, `shell_*`) still PASS.
- Only the `if not ctx then` block changed; `do_shell_fetch`, the slash/path branch,
  `force_fetch`, `on_commands_changed`, `completion_context`, `M.refresh`/`M.reset` unchanged.

## User Persona (if applicable)

**Target User**: Any `pi-bridge.nvim` user typing a `!`/`!!` shell line who backspaces over
the leading `!` (or types past a `/` or `@` trigger into plain prose) while a completion
request is still pending.

**Use Case**: User types `!git c` (shell menu offers `checkout`). They delete the `!`
(intending to type a normal message). Today, a fraction of a second later the stale shell
response arrives and the shell menu pops back open over plain text — confusing and wrong.
After this fix, the menu stays closed.

**Pain Points Addressed**: A late completion response re-opening a menu the user just closed
by changing context — a correctness deviation from PRD §5.5 (supersession) that the standard
test suite missed because supersession was only tested *within* shell and *within* slash/path,
never across the shell→plain boundary.

## Why

- **PRD §5.5 supersession + §h3.3 Issue 3**: every fetch path must supersede the previous one.
  The bug hunt (plan/002…/bug-hunt-transcript.log) proved the `ctx==nil` branch is the lone
  holdout — it closes the menu but leaves `state.gen` and `state.inflight_id` stale, so a late
  cb from any other branch slips past the gen-guard.
- **The gen-guard is the SOLE shell protection**: `shell.lua` has NO `cancel` method (the
  daemon is a local subprocess that supersedes internally via its own gen + overwriting
  `pending_cb`). Only the completion.lua `state.gen` guard can drop a late shell cb. Bumping
  gen in the nil branch is therefore ESSENTIAL, not optional — without it the race is
  unfixable for the shell path.
- **Consistency with the other branches**: do_shell_fetch (L414-419), the slash/path block
  (L562-568), force_fetch (L639), and on_commands_changed (L1083) ALL bump gen. The nil branch
  was simply missed. This fix makes it the 5th branch to do so — no new pattern.
- **Cheap & safe**: one block, mirroring two existing blocks verbatim; `pcall`-wrapped +
  `type(...)=="function"`-guarded so it never throws even if `pi.bridge` is nil or lacks
  cancel. No new state, no new function, no API change.
- **Parallel-safe**: the in-flight P1.M1.T3.S1 (Issue 2) edits `shell.lua` `M.ensure()` +
  `tests/shell_notices_spec.lua` + `doc/pi-bridge-shell.txt` — DISJOINT files from this task
  (`completion.lua` + `completion_spec.lua`). Zero conflict either order.

## What

A single block insertion in `do_refresh`'s `if not ctx then` arm + two plenary cases. The
insertion adds cancel-then-bump (layers 1 and 2) before the existing menu-close call. The
cases reuse the spec's existing harness (no new helpers).

### Success Criteria

- [ ] The `if not ctx then` block in `do_refresh` (completion.lua ~543-548) reads EXACTLY:
      `dbg(...)` → layer-1 cancel (`local b = require("pi-bridge").bridge; if state.inflight_id
      and b and type(b.cancel)=="function" then pcall(b.cancel, state.inflight_id) end;
      state.inflight_id = nil`) → layer-2 bump (`state.gen = state.gen + 1`) → the existing
      `if type(M.on_results)=="function" then pcall(M.on_results, buf, {}, "", nil) end` →
      `return`.
- [ ] The cancel is `pcall`-wrapped + `type(b.cancel)=="function"`-guarded (never throws if
      `pi.bridge` is nil or lacks cancel).
- [ ] `state.gen` is incremented BEFORE the `on_results` close call (so even the close itself
      runs under the new gen — a late cb captured at the old gen can never match).
- [ ] Indentation is 2-SPACE (matches completion.lua; NOT tabs).
- [ ] Case A (shell→nil) in `completion_spec.lua`: injects a fake `shell.complete_current`
      capturing the cb; refresh "!git c" (gen=N); edit to "git c"; refresh (ctx==nil close,
      gen=N+1); fire the stale shell cb with items; asserts the `on_results` seam counter did
      NOT increment (== 1, the post-close value) and `completion.current()` is nil.
- [ ] Case B (slash→nil): refresh "/mod" (bridge inflight id1); edit to "mod"; refresh
      (ctx==nil); asserts `fake.cancels[1] == id1` (layer 1) AND the stale bridge cb does NOT
      re-fire `on_results` (layer 2, seam stays at 1).
- [ ] Both cases use `fake_bridge({ auto_cancel_fires = false })` + the file's `wait_for` +
      buffer-setup helpers (no new harness code).
- [ ] `tests/completion_spec.lua` ALL cases PASS (the new two + every existing case incl.
      (1)-(8) and the error/cancelled/timeout describe).
- [ ] Sibling regression sweep PASS: `completion_accept_spec`, `completion_tab_smoke`,
      `menu_spec`, `shell_request_spec`, etc. (none touch the ctx==nil branch).
- [ ] ONLY the `if not ctx then` block changed. do_shell_fetch / slash-path / force_fetch /
      on_commands_changed / completion_context / M.refresh / M.reset UNCHANGED. No
      bridge.lua/shell.lua/menu.lua change. No shell-cancel wire added.

## All Needed Context

### Context Completeness Check

_Pass test_: An agent who has never seen this repo, given this PRP (which embeds the verbatim
current `if not ctx then` block, the verbatim new block, the two complete test cases, the
file's exact `fake_bridge`/`wait_for`/buffer-setup idiom, and the verified plenary command),
can apply the one `edit` + paste the two cases + run the gate and see green — with every
line number, helper name, and gotcha listed here.

### Documentation & References

```yaml
# MUST READ — the fix design (verbatim block + the "shell has no cancel wire → gen-guard is
# sole protection" rationale + the exact on_results seam-counter test pattern)
- docfile: plan/002_d23d7473c16c/bugfix/001_842ac90ede70/architecture/completion_drivers.md
  why: §"Issue 3: Supersession Race (ctx==nil branch doesn't bump gen)" gives the EXACT fix
       block + the race-repro steps + the seam-counter test pattern. This PRP transcribes it.
  section: "## Issue 3: Supersession Race (ctx==nil branch doesn't bump gen)"
  critical: |
    The gen bump (layer 2) is ESSENTIAL for the shell path: shell.lua has NO cancel method,
    so the completion.lua gen-guard is the SOLE protection against a late shell cb. Do NOT
    add a shell cancel (none exists; out of scope). Layer 1 (bridge cancel) helps only for a
    late BRIDGE cb (the slash→nil transition).

# MUST READ — the file being edited (the exact current `if not ctx then` block is quoted in
# Implementation Patterns; the do_shell_fetch + slash/path blocks it mirrors are at 411-445 +
# 543-600; state.gen/state.inflight_id at 263/257; M.on_results slot at 281)
- file: lua/pi-bridge/completion.lua
  why: the bug location (the `if not ctx then` block, ~543-548) + the two mirror blocks
       (do_shell_fetch 411-445; slash/path 543-600) it must match.
  pattern: "grep -nE 'if not ctx then|state\\.gen = state\\.gen \\+ 1|if gen ~= state\\.gen then return end' lua/pi-bridge/completion.lua"
  gotcha: |
    Match the edit by CONTENT (the `if not ctx then` ... `return` ... `end` block), not line
    number — the in-flight P1.M1.T3.S1 does NOT touch completion.lua, so lines are stable,
    but content-matching is robust. completion.lua uses 2-SPACE indent (NOT tabs — contrast
    shell.lua). Use the local name `b` (per contract) — a `bridge` local is declared LATER in
    do_refresh (the slash/path branch, ~L555) but that is AFTER the `if not ctx then` early
    `return`, so it is NOT in scope here; `b` avoids any confusion.

# MUST READ — the test home + the exact harness the two new cases reuse verbatim
- file: tests/completion_spec.lua
  why: defines `fake_bridge(opts)` (L30; `request` stores cb + returns id; `cancel` records
       id + if `auto_cancel_fires` fires cb "cancelled"), `reset()` (L78; clears
       pi.bridge/on_results/shell_mod.complete_current + completion.reset + menu.reset), the
       `wait_for(ms,pred)` helper (L95 = vim.wait(ms,pred,5)), and the buffer-setup idiom
       (create_buf + set_lines + win_set_buf + virtualedit=onemore + win_set_cursor). Case
       (4) at L180 is the seam-counter precedent; case (7) the touch-nothing precedent.
  pattern: "describe('pi-bridge.completion'); before_each(reset)/after_each(reset); local seam=0; completion.on_results=function() seam=seam+1 end; completion.refresh(buf); wait_for(200, ...); vim.schedule_wrap(cb)(err, result)"
  gotcha: |
    The SHELL path does NOT call bridge.request — do_shell_fetch calls shell.complete_current
    (L427). shell_mod.complete_current is nil by default (reset() L82 sets it nil) → do_shell_fetch
    early-returns at the "NOT defined (S3)" guard (L425) and NEVER captures a cb. So Case A
    MUST inject a fake `shell.complete_current = function(_b, cb) stale_shell_cb = cb end` to
    capture the gen-guarded cb. CRITICAL: refresh() DEBOUNCES (~10ms) — two refreshes
    back-to-back collapse into the LAST one, so you MUST `wait_for(stale_shell_cb ~= nil)`
    AFTER refresh #1 BEFORE editing the buffer + refresh #2 (else refresh #1's do_shell_fetch
    never runs). Case B mirrors case (4) (bridge.request stores the cb in fake.requests[i].cb).
    Do NOT name a spec-local table `pending` (shadows plenary skip fn).

# MUST READ — bridge.cancel signature (the layer-1 primitive the fix calls)
- file: lua/pi-bridge/bridge.lua
  why: M.cancel(id) (L719) takes the request id string, fires the matching cb with
       "cancelled", stops+closes its timer, deletes the pending entry (exactly-once). NEVER
       throws. The fix wraps it in pcall + a type()=="function" guard (defensive; mirrors
       do_shell_fetch L414-416).
  section: "L719 function M.cancel(id)"
  critical: |
    cancel(id) fires the cb with "cancelled" — so if `auto_cancel_fires` were true the stale
    bridge cb would be auto-resolved. Both new cases pass `{auto_cancel_fires=false}` so cbs
    are driven manually (the stale cb is held + fired by the test, exercising the gen-guard).

# MUST READ — test conventions (plenary runner + the nvim-stdin HARD RULE + the seam-counter)
- docfile: plan/002_d23d7473c16c/bugfix/001_842ac90ede70/architecture/test_conventions.md
  why: the exact plenary runner command; the on_results seam-counter pattern; the fake_bridge
       RPC surface; the auto_cancel_fires knob; the ⛔ HARD RULE (never heredoc→nvim stdin).
  section: "## Test Harness (plenary); ### Fake Bridge (RPC surface); ### Supersession Assertion (on_results seam counter); ## ⛔ HARD RULE"

# MUST READ — the PRD issue (the bug contract)
- docfile: plan/002_d23d7473c16c/bugfix/001_842ac90ede70/prd_snapshot.md
  why: §h3.3 Issue 3 — exact expected/actual/steps ("deleting the leading ! while a shell
       request is in flight lets the stale response re-open the shell menu").
  section: "### Issue 3: Supersession race — deleting the leading ! while a shell request is in flight ..."

# MUST READ — the in-flight prerequisite PRP (parallel-safety; DISJOINT files)
- docfile: plan/002_d23d7473c16c/bugfix/001_842ac90ede70/P1M1T3S1/PRP.md
  why: P1.M1.T3.S1 (Issue 2, IN-FLIGHT) edits shell.lua M.ensure() + tests/shell_notices_spec.lua
       + doc/pi-bridge-shell.txt. It does NOT touch completion.lua or completion_spec.lua →
       zero conflict with this task either order.
  section: "## What (Success Criteria); ## Integration Points (parallel-safety)"

# SUPPORTING — this task's full research (state-field table, debounce ordering, the two cases)
- docfile: plan/002_d23d7473c16c/bugfix/001_842ac90ede70/P1M2T1S1/research/notes.md
  why: §1 the bug (branch table); §2 the verbatim fix; §3 state fields; §4 bridge.cancel;
       §5 the test design (the shell-complete_current injection + debounce ordering); §6 scope.
```

### Current Codebase tree

```bash
$ ls -1 lua/pi-bridge/completion.lua lua/pi-bridge/bridge.lua lua/pi-bridge/shell.lua tests/completion_spec.lua tests/minimal_init.lua
lua/pi-bridge/bridge.lua            # M.cancel(id) (L719) — the layer-1 primitive (READ-ONLY for this task)
lua/pi-bridge/completion.lua        # <- EDIT the `if not ctx then` block in do_refresh (~543-548)
lua/pi-bridge/shell.lua             # has NO cancel method (the reason the gen-guard is sole shell protection)
tests/completion_spec.lua           # <- EDIT: append 2 it() cases inside the describe
tests/minimal_init.lua              # the plenary runner's -u init (sets debounce_ms=10, rtp, etc.)
```

### Desired Codebase tree with files to be added

```bash
lua/pi-bridge/completion.lua   # (MODIFY) insert cancel+bump in the `if not ctx then` block of do_refresh
tests/completion_spec.lua      # (MODIFY) append 2 plenary cases (A shell→nil, B slash→nil) inside the describe
# No new files. No bridge.lua/shell.lua/menu.lua change. No doc change.
```

### Known Gotchas of our codebase & Library Quirks

```lua
-- CRITICAL: completion.lua uses 2-SPACE indentation (NOT tabs). The `if not ctx then` body
--   (dbg / on_results / return) sits at 4 spaces. The inserted cancel/bump lines MUST be at
--   4 spaces to match. (Contrast shell.lua which uses TABS — different file, different style.)

-- CRITICAL: the gen bump (layer 2) is ESSENTIAL for the shell path. shell.lua has NO cancel
--   method (the daemon supersedes internally). The completion.lua `if gen ~= state.gen then
--   return end` guard (L431) is the SOLE protection against a late shell cb. Without the bump
--   the race is unfixable for shell. Do NOT add a shell cancel (none exists; out of scope).

-- CRITICAL: insert the cancel+bump BEFORE the existing `pcall(M.on_results, buf, {}, "", nil)`
--   close call (the contract is explicit: "BEFORE the existing on_results close call"). Putting
--   it after would bump gen after the close — harmless for the close itself, but the contract
--   orders it before; match the do_shell_fetch/slash-path blocks (cancel+bump, THEN the cb work).

-- CRITICAL (test, shell path): do_shell_fetch calls shell.complete_current(buf, cb) (L427), NOT
--   bridge.request. shell_mod.complete_current is nil by default → do_shell_fetch early-returns
--   at the "NOT defined (S3)" guard (L425) and captures NO cb. Case A MUST inject a fake
--   `shell.complete_current = function(_b, cb) stale_shell_cb = cb end` to capture the cb.
--   The captured cb IS the gen-guarded closure (gen=N in its scope).

-- CRITICAL (test, debounce): completion.refresh() DEBOUNCES (~10ms in minimal_init). Two
--   refreshes back-to-back collapse into the LAST one. So Case A MUST `wait_for(stale_shell_cb
--   ~= nil)` AFTER refresh #1 (let do_shell_fetch run + capture the cb) BEFORE editing the
--   buffer + refresh #2 — else refresh #1 never runs and no cb is captured. Case B mirrors
--   case (4): it waits `#fake.requests >= 1` between the two refreshes.

-- CRITICAL (test, schedule): the shell cb's on_results hop is `vim.schedule`d (L438). So after
--   firing the stale cb, drain schedules with `wait_for(150, function() return false end)` (a
--   no-op wait that lets the event loop tick) BEFORE asserting the seam counter — so a buggy
--   build's scheduled on_results would have fired (and been caught).

-- GOTCHA: use the local name `b` for the bridge (per contract). A `bridge` local is declared
--   LATER in do_refresh (the slash/path branch, ~L555) but that is AFTER the `if not ctx then`
--   early `return`, so it is NOT in scope in the nil branch. `b` avoids confusion + matches
--   do_shell_fetch's idiom (`local bridge = require("pi-bridge").bridge` at L412).

-- GOTCHA: the cancel is `pcall`-wrapped + `type(b.cancel)=="function"`-guarded. If pi.bridge
--   is nil (no bridge connected) or lacks cancel (a test stub), the cancel is a silent no-op.
--   This mirrors do_shell_fetch L414-416 exactly — never throws.

-- GOTCHA (AGENTS.md HARD RULE): the plenary runner uses a FILE path
--   (`-c 'lua require("plenary.busted").run("tests/completion_spec.lua")'`), NOT nvim stdin.
--   NEVER pipe a heredoc into nvim stdin (it HANGS). Write any throwaway check to a real
--   .lua file, then `:luafile` it. ALWAYS wrap nvim in `timeout`.

-- GOTCHA: do NOT name a spec-local table `pending` (shadows plenary.busted's global skip fn).
--   Use `seam`/`got`/`stale_shell_cb` locals (mirrors the file's existing cases).
```

## Implementation Blueprint

### Data models and structure

No data-model change. The fix consumes two EXISTING module-level fields:
- `state.gen` (completion.lua:263, `integer`, init 0) — bumped per fetch; captured in cb closures.
- `state.inflight_id` (completion.lua:257, `string?`, init nil) — the `bridge.request` id of
  the current in-flight getSuggestions (set at the end of the slash/path branch, L~599; cleared
  by do_shell_fetch L417 + the cb resolvers). My fix clears it in the nil branch too.

### Implementation Tasks (ordered by dependencies)

```yaml
Task 1: EDIT lua/pi-bridge/completion.lua — insert cancel+bump in the `if not ctx then` block
  - LOCATE the `if not ctx then` block in do_refresh (content-match; ~lines 543-548). It
    currently is: `dbg(...)` → `if type(M.on_results)=="function" then pcall(M.on_results,
    buf, {}, "", nil) end` → `return`.
  - INSERT, between the `dbg(...)` line and the `on_results` close line:
      (layer 1) `local b = require("pi-bridge").bridge`
                `if state.inflight_id and b and type(b.cancel) == "function" then`
                `  pcall(b.cancel, state.inflight_id)`
                `end`
                `state.inflight_id = nil`
      (layer 2) `state.gen = state.gen + 1`
  - The exact oldText→newText is in "Implementation Patterns & Key Details" below.
  - DO NOT: touch any other branch (do_shell_fetch, slash/path, force_fetch,
    on_commands_changed), completion_context, M.refresh, M.reset, or any other file.
  - DO NOT: add a shell cancel; change bridge.lua/shell.lua/menu.lua; add config/env/doc.
  - INDENTATION: 2-SPACE (the `if not ctx then` body level = 4 spaces). Match the file.
  - VERIFY: `grep -nE 'if not ctx then' lua/pi-bridge/completion.lua` → 1 hit; the new block
    sits inside it. `grep -cE 'state\.gen = state\.gen \+ 1' lua/pi-bridge/completion.lua` →
    now 5 (do_shell_fetch, slash/path, ctx==nil, force_fetch, on_commands_changed).

Task 2: EDIT tests/completion_spec.lua — append 2 plenary cases inside the describe
  - INSERT two `it(...)` blocks inside `describe("pi-bridge.completion", function() ... end)`.
    Placement is not load-bearing; group after case (4) (the supersession case) or after the
    error/cancelled/timeout describe for readability.
  - Case A (shell→nil, the exact Issue-3 repro): the body is in "Implementation Patterns &
    Key Details" below. Uses fake_bridge({auto_cancel_fires=false}); injects
    `shell_mod.complete_current = function(_b, cb) stale_shell_cb = cb end`; refresh "!git c";
    wait_for(stale_shell_cb ~= nil); set seam counter; edit buffer → "git c"; refresh;
    wait_for(seam >= 1); fire stale_shell_cb; wait to drain; assert seam == 1 +
    completion.current() == nil.
  - Case B (slash→nil): mirrors case (4). refresh "/mod"; wait_for(#fake.requests >= 1);
    capture id1 + stale_cb; set seam counter; edit buffer → "mod"; refresh; wait_for(seam >= 1);
    assert fake.cancels[1] == id1 (layer 1); fire stale_cb; assert seam == 1 (layer 2).
  - REUSE the file's existing helpers verbatim (fake_bridge, wait_for, the buffer-setup
    idiom, before_each/after_each via reset()). NO new harness code.
  - The exact case bodies are in "Implementation Patterns & Key Details" below.

Task 3: VALIDATE — run the gates (Validation Loop); all must be green.
```

### Implementation Patterns & Key Details

```lua
-- === lua/pi-bridge/completion.lua — Task 1 (the SOLE code edit) ===
-- Apply via the edit tool. OLD (verbatim current — the `if not ctx then` block, ~543-548):
  if not ctx then
    dbg(string.format("[do_refresh] ctx=nil (plain) line1=%q col=%s — close, no request", tostring((lines or {})[1] or ""), tostring(byte_col)))
    if type(M.on_results) == "function" then pcall(M.on_results, buf, {}, "", nil) end -- S5: explicit nil context (plain typing)
    return
  end
-- NEW (insert layer-1 cancel + layer-2 bump BEFORE the on_results close call):
  if not ctx then
    dbg(string.format("[do_refresh] ctx=nil (plain) line1=%q col=%s — close, no request", tostring((lines or {})[1] or ""), tostring(byte_col)))
    -- SUPERSEDE layer 1 (Issue 3): cancel a pending BRIDGE inflight (mirrors do_shell_fetch
    -- L414-416 + the slash/path block L562-564). pcall + type-guard so a nil/contractor-less
    -- bridge is a silent no-op. (Shell has NO cancel wire — shell.lua supersedes internally;
    -- the gen-guard below is the sole protection against a late shell cb.)
    local b = require("pi-bridge").bridge
    if state.inflight_id and b and type(b.cancel) == "function" then
      pcall(b.cancel, state.inflight_id)
    end
    state.inflight_id = nil
    -- SUPERSEDE layer 2 (gen-guard — the CORRECTNESS boundary; Issue 3): bump gen so a late
    -- shell/bridge cb (whose closure captured gen=N) finds state.gen=N+1 → dropped by the
    -- `if gen ~= state.gen then return end` guard. WITHOUT this bump, deleting `!` while a
    -- shell request is in flight lets the stale response re-open the menu.
    state.gen = state.gen + 1
    if type(M.on_results) == "function" then pcall(M.on_results, buf, {}, "", nil) end -- S5: explicit nil context (plain typing)
    return
  end
```

```lua
-- === tests/completion_spec.lua — Task 2 (the two new cases) ===
-- Append inside `describe("pi-bridge.completion", function() ... end)`. Reuse the file's
-- existing fake_bridge / wait_for / reset() / buffer-setup idiom (NO new helpers).

  -- (4b) ISSUE-3: shell→plain transition drops a late SHELL response (the exact repro).
  --      Shell has NO cancel wire → the gen-guard (layer 2) is the SOLE protection. The
  --      ctx==nil branch now bumps gen so the stale shell cb is dropped.
  it("ISSUE-3: deleting `!` while a shell request is in flight does NOT re-open the menu", function()
    local fake = fake_bridge({ auto_cancel_fires = false }) -- we drive cbs manually
    pi.bridge = fake
    local buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "!git c" })
    local win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(win, buf)
    vim.wo[win].virtualedit = "onemore"
    vim.api.nvim_win_set_cursor(win, { 1, 6 }) -- after "c" in "!git c"
    -- capture the SHELL cb (do_shell_fetch → shell.complete_current(buf, cb)); hold it stale.
    -- (shell_mod.complete_current is nil by default; do_shell_fetch early-returns otherwise.)
    local stale_shell_cb
    shell_mod.complete_current = function(_b, cb) stale_shell_cb = cb end
    -- 1st refresh -> ctx=="shell" -> do_shell_fetch (gen bumped to N; stale cb captured, NOT fired)
    completion.refresh(buf)
    wait_for(200, function() return stale_shell_cb ~= nil end)
    assert.is_not_nil(stale_shell_cb, "do_shell_fetch must invoke shell.complete_current")
    -- seam counter (set AFTER the shell fetch so the ctx==nil close is the first fire)
    local seam = 0
    completion.on_results = function() seam = seam + 1 end
    -- edit buffer: delete `!` -> "git c" -> ctx==nil -> menu closes (on_results({}, "", nil))
    -- AND gen bumped to N+1 (the fix). WITHOUT the fix, gen stays N here.
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "git c" })
    vim.api.nvim_win_set_cursor(win, { 1, 5 })
    completion.refresh(buf)
    wait_for(200, function() return seam >= 1 end) -- the ctx==nil close call fires on_results once
    assert.are.equals(1, seam, "ctx==nil close fired on_results exactly once")
    -- fire the STALE shell cb (closure captured gen=N) with items -> gen(N) != state.gen(N+1)
    -- -> DROPPED by the gen-guard (on_results must NOT re-fire).
    vim.schedule_wrap(stale_shell_cb)(nil,
      { items = { { value = "git checkout", label = "checkout" } }, prefix = "c" })
    wait_for(150, function() return false end) -- drain any scheduled on_results (none should fire)
    assert.are.equals(1, seam, "the stale shell response must NOT re-fire on_results (gen-guard)")
    assert.is_nil(completion.current(), "last_result must be untouched by the stale shell response")
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  -- (4c) ISSUE-3 layer 1: the ctx==nil branch ALSO cancels a pending BRIDGE inflight (the
  --      slash→plain transition). Mirrors case (4) but for the ctx==nil arm (case (4) is
  --      slash→slash). Proves BOTH layers: cancel(prev_id) AND the stale cb is gen-guarded.
  it("ISSUE-3: slash→plain transition cancels the pending bridge request in ctx==nil", function()
    local fake = fake_bridge({ auto_cancel_fires = false })
    pi.bridge = fake
    local buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "/mod" })
    local win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(win, buf)
    vim.wo[win].virtualedit = "onemore"
    vim.api.nvim_win_set_cursor(win, { 1, 4 }) -- after "/mod"
    -- 1st refresh -> ctx=="slash" -> bridge.request (inflight_id = id1; slow; do NOT resolve)
    completion.refresh(buf)
    wait_for(200, function() return #fake.requests >= 1 end)
    local id1 = fake.requests[1].id
    local stale_cb = fake.requests[1].cb
    local seam = 0
    completion.on_results = function() seam = seam + 1 end
    -- edit buffer: delete "/" -> "mod" -> ctx==nil -> cancel(id1) [layer1] + bump gen [layer2] + close
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "mod" })
    vim.api.nvim_win_set_cursor(win, { 1, 3 })
    completion.refresh(buf)
    wait_for(200, function() return seam >= 1 end) -- the ctx==nil close fires on_results once
    -- layer 1: cancel(prev bridge id) was called in the ctx==nil branch
    assert.is_true(#fake.cancels >= 1, "ctx==nil must cancel a pending bridge inflight (layer 1)")
    assert.are.equals(id1, fake.cancels[1], "the cancelled id is the slash inflight id")
    -- layer 2: the stale slash cb (closure captured gen=N) is dropped by the gen-guard
    vim.schedule_wrap(stale_cb)(nil, { items = { { value = "model", label = "model" } }, prefix = "/mod" })
    wait_for(150, function() return false end) -- drain schedules
    assert.are.equals(1, seam, "the stale bridge response must NOT re-fire on_results (gen-guard)")
    vim.api.nvim_buf_delete(buf, { force = true })
  end)
```

```lua
-- === Why every existing case stays green ===
-- The edit is strictly ADDITIVE inside one branch (ctx==nil) that NO existing case exercises
-- as a supersession SOURCE. Existing cases drive ctx=="slash"/"path" (cases 2,3,4,5,6,7,8) or
-- ctx==nil as a TERMINAL close (case 2's note about cursor at col 0). The new behavior:
--   - cancel(inflight_id): in the existing slash/path cases state.inflight_id is nil at the
--     ctx==nil arm (they never reach ctx==nil with an inflight) → the type-guarded pcall is a
--     no-op. For cases that DO reach ctx==nil (e.g. case 2 col-0), there's no inflight → no-op.
--   - state.gen += 1: bumps a counter that no existing case asserts an absolute value of
--     (they assert RELATIVE behavior — stale-vs-current — via the gen-guard, which still holds:
--     bumping gen in ctx==nil only makes MORE cbs stale, never fewer). completion.reset()
--     (before_each/after_each) zeroes state.gen, so cases start at gen=0 regardless.
-- => zero behavioral regression for the existing 8+ cases.
```

### Integration Points

```yaml
NO new integration points. The fix reuses existing module state + an existing bridge primitive.
  - state.gen (completion.lua:263) + state.inflight_id (completion.lua:257) — existing fields.
  - require("pi-bridge").bridge.cancel(id) (bridge.lua:719) — existing primitive; pcall+type-guarded.
  - The on_results close call (pcall(M.on_results, buf, {}, "", nil)) is UNCHANGED — the fix
    runs BEFORE it.
PARALLEL TASK (Issue 2 / P1.M1.T3.S1 — IN-FLIGHT):
  - Edits shell.lua M.ensure() + tests/shell_notices_spec.lua + doc/pi-bridge-shell.txt.
    DISJOINT from this task (completion.lua + completion_spec.lua). Zero conflict either order.
    Both consume `require("pi-bridge").bridge` read-fresh at call time — no shared mutation.
DOWNSTREAM (NOT this task):
  - Issue 4 (P1.M2.T5) wires shell cwd re-tracking in shell.lua complete_current — different
    function/file. Issue 6 (P1.M2.T6) edits the shell driver DAEMON_SCRIPTs. Issue 1 (DONE) +
    Issue 5 (DONE) are in shell.lua/health.lua. No conflict with the ctx==nil branch.
```

## Validation Loop

### Level 1: Syntax & Style (Immediate Feedback)

```bash
# Parse check (luac if available; the plenary load in L2 covers parse too). NEVER heredoc→nvim stdin.
luac -p lua/pi-bridge/completion.lua 2>/dev/null && echo "parse OK" || echo "luac unavailable (L2 covers parse)"

# Confirm the fix landed in the `if not ctx then` block (content grep):
grep -nA12 'if not ctx then' lua/pi-bridge/completion.lua | grep -E 'pcall\(b\.cancel|state\.gen = state\.gen \+ 1'
# Expected: BOTH lines present inside the `if not ctx then` block.

# Confirm there are now FIVE gen-bump sites (do_shell_fetch, slash/path, ctx==nil, force_fetch, on_commands_changed):
grep -cE 'state\.gen = state\.gen \+ 1' lua/pi-bridge/completion.lua
# Expected: 5 (was 4).

# Confirm the cancel is type-guarded + pcall-wrapped (mirrors do_shell_fetch):
grep -nE 'type\(b\.cancel\) == "function" then' lua/pi-bridge/completion.lua
# Expected: >= 1 hit (the new ctx==nil line; do_shell_fetch uses `bridge.cancel` not `b.cancel`).

# Confirm the two new cases landed:
grep -cE 'ISSUE-3' tests/completion_spec.lua
# Expected: >= 2 (Case A shell→nil + Case B slash→nil).

# Confirm indentation is 2-space (NOT tabs) in the new block:
awk '/if not ctx then/{f=1} f&&/state\.gen = state\.gen \+ 1/{print "gen-line-indent-spaces="length($0)-length(gensub(/^ */,"","g",$0)); f=0}' lua/pi-bridge/completion.lua
# Expected: a small even number (4) — the body level of `if not ctx then`.
```

### Level 2: Unit Tests (the gate — the spec with the 2 new cases)

```bash
# Primary: the completion spec (home of the 2 new cases + all existing cases).
timeout 90 nvim --headless --clean -u tests/minimal_init.lua \
  -c 'lua require("plenary.busted").run("tests/completion_spec.lua")'
# Expected: ALL `it` PASS, incl. (4b) shell→nil + (4c) slash→nil AND every existing case
#   ((1) surface, (2) debounce, (3) params, (4) slash→slash supersession, (5) on_results seam,
#   (6) null result, (7) error/cancelled/timeout, (8) fresh-bridge). `fail 0`.
# NOTE: if P1.M1.T3.S1 has also landed, its shell_notices cases must ALSO pass (DISJOINT file).
```

### Level 3: Regression Sweep (siblings that consume completion.lua — must be unaffected)

```bash
# completion-layer siblings (the accept/Tab/autosave flows consume do_refresh indirectly).
for spec in completion_accept_spec completion_tab_smoke; do
  timeout 90 nvim --headless --clean -u tests/minimal_init.lua \
    -c "lua require(\"plenary.busted\").run(\"tests/${spec}.lua\")" && echo "${spec}: PASS"
done
# Expected: each PASS (the edit is additive inside one branch no sibling exercises as a source).

# menu + shell siblings (different files; must be untouched).
for spec in menu_spec shell_request_spec shell_ensure_spec; do
  timeout 90 nvim --headless --clean -u tests/minimal_init.lua \
    -c "lua require(\"plenary.busted\").run(\"tests/${spec}.lua\")" && echo "${spec}: PASS"
done
# Expected: each PASS.
```

### Level 4: Manual / Adversarial (the EXACT bug repro — shell→nil race, live)

```bash
# Reproduce Issue 3 WITHOUT a real daemon: inject a fake shell.complete_current that captures
# the cb, drive refresh("!git c") then edit→"git c" then refresh, then fire the stale cb, and
# assert on_results did NOT re-fire. Heredoc→FILE is fine; nvim stdin is NOT (AGENTS.md HARD RULE).
cat > /tmp/issue3_check.lua <<'LUA'
local completion = require("pi-bridge.completion")
local pi = require("pi-bridge")
if pi.config == nil then pi.setup({ debounce_ms = 10 }) end
-- fake bridge: request stores cb, cancel is a no-op (we drive cbs manually)
pi.bridge = {
  is_connected = function() return true end,
  request = function(_m, _p, cb) return "1" end, -- (not used on the shell path, but keeps do_refresh happy)
  cancel = function(_id) end,
}
-- capture the SHELL cb
local stale_cb
require("pi-bridge.shell").complete_current = function(_buf, cb) stale_cb = cb end
local buf = vim.api.nvim_create_buf(true, false)
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "!git c" })
local win = vim.api.nvim_get_current_win()
vim.api.nvim_win_set_buf(win, buf)
vim.wo[win].virtualedit = "onemore"
vim.api.nvim_win_set_cursor(win, { 1, 6 })
local seam = 0
completion.on_results = function() seam = seam + 1 end
completion.refresh(buf)                                 -- "!git c" -> do_shell_fetch (gen=N, cb captured)
vim.wait(200, function() return stale_cb ~= nil end, 5)
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "git c" }) -- delete `!`
vim.api.nvim_win_set_cursor(win, { 1, 5 })
completion.refresh(buf)                                 -- ctx==nil -> close + gen=N+1
vim.wait(200, function() return seam >= 1 end, 5)      -- the close fired on_results once
local seam_after_close = seam
vim.schedule_wrap(stale_cb)(nil, { items = { { value = "git checkout", label = "checkout" } }, prefix = "c" })
vim.wait(150, function() return false end, 5)           -- drain schedules
print("seam_after_close=" .. seam_after_close .. " seam_after_stale=" .. seam)
assert(seam == seam_after_close, "BUG: stale shell cb re-fired on_results (Issue 3 regressed)")
print("ISSUE3_OK")
LUA
timeout 60 nvim --headless --clean -u NORC -c 'set rtp+=.' +"luafile /tmp/issue3_check.lua" +qa; echo "exit=$?"
# Expected: prints `seam_after_close=1 seam_after_stale=1` + ISSUE3_OK, exit=0. (With the BUG,
#   seam_after_stale would be 2 — the stale shell cb re-opened the menu.)
```

## Final Validation Checklist

### Technical Validation

- [ ] Level 1: `grep -A12 'if not ctx then'` shows BOTH `pcall(b.cancel, state.inflight_id)`
      + `state.gen = state.gen + 1` inside the block; `grep -c 'state\.gen = state\.gen \+ 1'` → 5;
      `grep 'ISSUE-3' tests/completion_spec.lua` → >= 2; new block is 2-space indented.
- [ ] Level 2: `tests/completion_spec.lua` PASS (incl. the 2 new cases + all existing).
- [ ] Level 3: `completion_accept_spec` + `completion_tab_smoke` + `menu_spec` + `shell_request_spec`
      + `shell_ensure_spec` PASS.
- [ ] Level 4: `/tmp/issue3_check.lua` prints `seam_after_stale=1` + ISSUE3_OK (the stale cb is dropped).

### Feature Validation

- [ ] Deleting `!` while a shell request is in flight → the stale shell cb is dropped by the
      gen-guard → `on_results` does NOT re-fire → menu does NOT re-open.
- [ ] The `ctx==nil` branch cancels a pending BRIDGE inflight (`fake.cancels[1] == id1`).
- [ ] The `ctx==nil` branch bumps `state.gen` (a late cb captured at the old gen is dropped).
- [ ] The cancel is `pcall`-wrapped + `type(b.cancel)=="function"`-guarded (never throws).
- [ ] Only the `if not ctx then` block changed; every other branch + file untouched.

### Code Quality Validation

- [ ] The new block mirrors do_shell_fetch (L414-419) + the slash/path block (L562-568) — no new pattern.
- [ ] 2-space indentation (matches completion.lua; NOT tabs).
- [ ] Local named `b` (per contract; avoids confusion with the later `bridge` local).
- [ ] The two test cases reuse the file's existing harness (fake_bridge / wait_for / buffer idiom);
      no new helpers; each cleans up its buffer (`nvim_buf_delete`).
- [ ] Edits are the SMALLEST possible (1 block + 2 cases); no refactors.

### Documentation & Deployment

- [ ] Inline comments in the new block explain WHY layer 2 (gen-guard) is essential for shell
      (no cancel wire) + that it mirrors the other branches.
- [ ] No user-facing/config/API/doc surface change (internal supersession fix — contract DOCS: none).

---

## Anti-Patterns to Avoid

- ❌ Don't skip the gen bump (layer 2) — for the shell path it is the SOLE protection (shell.lua has no cancel).
- ❌ Don't add a shell cancel — none exists and it's out of scope (Issue 4/6 territory is shell.lua, not here).
- ❌ Don't use TABS — completion.lua is 2-space indented (contrast shell.lua).
- ❌ Don't name the local `bridge` — a `bridge` local is declared later in do_refresh (the slash/path
  branch); use `b` to avoid confusion (matches do_shell_fetch's idiom).
- ❌ Don't insert the cancel+bump AFTER the `on_results` close call — the contract says BEFORE it
  (match the do_shell_fetch/slash-path ordering: cancel+bump, then the cb work).
- ❌ Don't drop the `pcall` + `type(...)=="function"` guard on cancel — `pi.bridge` can be nil or
  lack cancel (test stubs); an unguarded `b.cancel(...)` could throw into the autocmd chain.
- ❌ Don't write the shell-path test without injecting a fake `shell.complete_current` — the default
  nil makes do_shell_fetch early-return and capture NO cb, so the test can't fire a stale shell cb.
- ❌ Don't call refresh #2 immediately after refresh #1 without a `wait_for` — the debounce collapses
  them into the last refresh, so refresh #1's do_shell_fetch never runs.
- ❌ Don't pipe a heredoc into nvim stdin (AGENTS.md HARD RULE — it HANGS). Use the plenary runner
  (file path) or write Lua to a file then `:luafile`. Always wrap nvim in `timeout`.