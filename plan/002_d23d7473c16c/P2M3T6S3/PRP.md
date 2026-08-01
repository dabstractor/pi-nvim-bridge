name: "P2.M3.T6.S3 — Wire shell.teardown() into the VimLeavePre/ExitPre exit path"
description: |

  The §17 shell-completion daemon (`lua/pi-bridge/shell.lua`) is a **persistent
  child process of nvim** spawned on first `!`/`!!` activation (P2.M1.T2.S3
  `ensure()`). It holds three long-lived `vim.uv` handles — `proc`, `stdin`,
  `stdout` — and a per-request timer. If nvim exits without tearing it down,
  those handles **leak for the session** and the child shell process may be left
  orphaned. `M.teardown()` (P2.M1.T2.S6) already implements idempotent kill +
  close + reset, but **nothing calls it on exit** today. The exit autocmd
  (`ftplugin/pi-prompt.lua` `VimLeavePre`/`ExitPre`) dispatches **only**
  `require("pi-bridge.bridge").on_exit(buf)` (autosave + bye + bridge.close) —
  the shell daemon is unaccounted for.

  This task closes that gap with a one-line wiring change + a regression spec.

---

## Goal

**Feature Goal**: On `VimLeavePre`/`ExitPre` of the pi-prompt buffer, the shell
completion daemon is torn down (kill + close handles + reset state) alongside the
existing bridge teardown, with zero risk of blocking exit or throwing on any
prior state.

**Deliverable**: A minimal, never-throws wiring of
`require("pi-bridge.shell").teardown()` into the existing exit dispatch path
(inside `bridge.on_exit`), plus a plenary spec proving it is invoked + safe, and
a smoke assertion that the daemon handles are gone after exit.

**Success Definition**: When `bridge.on_exit(buf)` runs (the function the
ftplugin already dispatches on `VimLeavePre`/`ExitPre`), `shell.teardown()` is
called exactly once per exit, idempotent across the `ExitPre`→`VimLeavePre`
double-fire, and is a safe no-op when the daemon was never spawned.

## Why

- **Prevents handle + process leaks.** The daemon is a child of the nvim editor
  process (PRD §17.3 / §17.13). Without teardown, its `proc`/`stdin`/`stdout`
  handles leak for the editor's lifetime (the shell-teardown spec's whole F3
  leak-fix rationale) and the child shell may outlive the editor.
- **Closes the §17 lifecycle loop.** PRD §17.5 says the daemon is "torn down on
  `VimLeavePre` alongside the existing bridge-client teardown" — `M.teardown()`
  exists precisely for this; it must be wired to the event that fires it.
- **No behavioral risk.** `M.teardown()` is already fully idempotent + never
  throws (S6: nil-guarded, `is_closing()`-guarded, `pcall`'d internally; safe
  across double-fire). Wiring it is additive only.

## What

- `bridge.on_exit(buf)` gains a **fourth** idempotent, pcall-guarded step that
  calls `require("pi-bridge.shell").teardown()`.
- The ftplugin's `VimLeavePre`/`ExitPre` autocmd **stays unchanged** — it already
  dispatches `bridge.on_exit`, which now also tears down the daemon. No new
  autocmd, no new forward contract in the ftplugin. (See Decision 1 below for why
  the call belongs in `bridge.on_exit`, not a second `dispatch("pi-bridge.shell",
  "teardown", buf)` in the ftplugin.)
- Ordering: the shell daemon teardown runs **after** autosave + bye + bridge
  close — the daemon is independent of the bridge socket (PRD §17.13: shell
  completion never touches the bridge socket), so order vs. bridge.close is not
  load-bearing. Placing it last keeps the existing three steps' proven ordering
  intact and makes the diff a pure append.
- Never blocks exit (no `vim.schedule`; `teardown()` is synchronous — S6),
  never throws (pcall + the existing internal guards), idempotent across the
  `ExitPre`+`VimLeavePre` double-fire (S6 reset() clears state).

### Success Criteria

- [ ] `bridge.on_exit(buf)` invokes `shell.teardown()` exactly once per call.
- [ ] It is pcall-guarded so a throwing `teardown()` cannot abort exit.
- [ ] It is a safe no-op when the daemon was never spawned (state all nil → S6
      guards short-circuit; no error).
- [ ] Idempotent across the double-fire: a second `on_exit(buf)` after teardown
      completes does NOT re-enter a closed handle (S6's `is_closing()` guards +
      `reset()` clear).
- [ ] A new plenary spec asserts `shell.teardown` is called from `on_exit`.
- [ ] The existing test suite (esp. `bridge_on_exit_spec.lua`, `shell_teardown_spec.lua`,
      `ftplugin_spec.lua`) still passes unchanged.

## All Needed Context

### Context Completeness Check

> If someone knew nothing about this codebase, would they have everything needed
> to implement this successfully? **Yes** — this is a one-line wiring into a
> well-documented, already-tested exit handler, with the exact function to call
> (`shell.teardown`) and the exact call site (`bridge.on_exit`'s final step)
> named. All referenced files + functions are pinned below with line numbers.

### Documentation & References

```yaml
# MUST READ — the PRD section that mandates this wiring
- url: (in-repo PRD) §17.5 "The completion daemon" + §17.13 "Security"
  why: "torn down on VimLeavePre alongside the existing bridge-client teardown"
  critical: the daemon is a child of nvim (not pi) on local pipes; the bridge
    socket/token boundary (§12) is UNCHANGED — shell teardown never touches it.

# The exit dispatcher (the call site) — DO NOT MODIFY its autocmds
- file: ftplugin/pi-prompt.lua
  why: registers the VimLeavePre/ExitPre autocmd that dispatches bridge.on_exit(buf)
  pattern: "the body (autosave + bye + close) is S38's job; the WIRING lives here"
    — the ftplugin's contract is `require("pi-bridge.bridge").on_exit(buf)` ONLY.
    This task keeps that contract; it adds the shell call INSIDE on_exit.
  gotcha: do NOT add a second `dispatch("pi-bridge.shell","teardown",buf)` here —
    that would split the exit teardown across two modules and break the single
    dispatch's "all-or-nothing, ordered" guarantee (Decision 1).

# The function to MODIFY — bridge.on_exit(buf) (bridge.lua ~L854)
- file: lua/pi-bridge/bridge.lua
  why: M.on_exit is the single exit handler the ftplugin dispatches; it already
    runs the three pcall-guarded steps (autosave / bye / close). The shell call
    is appended as step (4), same pcall-guard discipline.
  pattern: each step is `pcall(...)` so a throw in one cannot abort the others;
    comments cite the GOTCHA that justifies the ordering. Mirror that EXACTLY.
  gotcha: "never vim.schedule" (GOTCHA E, bridge.lua L~851) — teardown() is
    synchronous; do not wrap it in vim.schedule.

# The function to CALL — shell.M.teardown() (shell.lua L926)
  why: S6's idempotent kill + close + reset. Already:
    - cancels the per-request timer (cancel_req_timer)
    - finalizes the in-flight pending_cb (soft-degrade {}, "")
    - close_handles() (stdout read_stop+close, stdin close, proc kill+close)
    - M.reset() (clears the whole state slate)
  pattern: nil-guarded + is_closing()-guarded internally; safe to call when the
    daemon was never spawned (state.proc == nil → all guards short-circuit).
  gotcha: it does NOT itself pcall internally in all paths — the CALLER must
    pcall it (bridge.on_exit already pcalls every step; we reuse that).
```

### Current Codebase tree (the relevant slice)

```bash
lua/pi-bridge/
├── bridge.lua          # M.on_exit(buf) at ~L854 — MODIFY (append step 4)
└── shell.lua           # M.teardown() at L926 — CALL (do not modify)
ftplugin/pi-prompt.lua  # VimLeavePre/ExitPre autocmd — UNCHANGED (already dispatches on_exit)
tests/
├── bridge_on_exit_spec.lua   # existing exit-handler spec — MUST still pass
├── shell_teardown_spec.lua   # existing shell.teardown spec — MUST still pass
└── ftplugin_spec.lua         # existing ftplugin spec — MUST still pass
```

### Desired Codebase tree with files to be added/changed

```bash
lua/pi-bridge/bridge.lua              # MODIFY: M.on_exit gains step (4) — pcall(shell.teardown)
tests/bridge_on_exit_shell_spec.lua   # CREATE: regression spec asserting on_exit calls shell.teardown
# (no new runtime files; no ftplugin change; no new module)
```

### Known Gotchas of our codebase & Library Quirks

```lua
-- CRITICAL: bridge.on_exit is the SOLE exit handler the ftplugin dispatches. Every
-- step is pcall-guarded so exit is NEVER blocked/aborted (bridge.lua on_exit doc,
-- "Three idempotent steps, each pcall-guarded so exit is NEVER blocked or aborted").
-- The new shell step MUST follow the same pcall discipline — do NOT call it bare.

-- CRITICAL: never vim.schedule from on_exit (GOTCHA E, bridge.lua). teardown() is
-- synchronous (S6); a deferred teardown would race the editor actually exiting and
-- the handles would never be closed in time.

-- CRITICAL: do NOT add a second dispatch in ftplugin/pi-prompt.lua. The ftplugin's
-- forward contract is `bridge.on_exit(buf)` ONLY (its header documents this).
-- Funneling shell teardown THROUGH on_exit keeps exit teardown single-entry,
-- ordered, and all-pcall-guarded in one place (Decision 1).

-- shell.teardown() is idempotent across the ExitPre→VimLeavePre double-fire
-- (GOTCHA A in bridge.lua): after step (4)'s reset(), state.proc/stdin/stdout are
-- nil, so a second on_exit's teardown hits the nil+is_closing guards → no-op.

-- shell.teardown() is a safe no-op when the daemon was never spawned: state is
-- all-nil at module load (shell.lua state table), so every guard short-circuits.

-- `require("pi-bridge.shell")` is a cheap, side-effect-free module require (it
-- only declares tables/functions; it does NOT spawn on require — ensure() does).
-- Calling it inside on_exit is safe even on the never-`!` path.
```

## Implementation Blueprint

### Implementation Tasks (ordered by dependencies)

```yaml
Task 1: MODIFY lua/pi-bridge/bridge.lua — append step (4) to M.on_exit(buf)
  - LOCATE: M.on_exit (bridge.lua ~L854). It currently has 3 numbered steps:
      (1) pcall(autosave_if_modified, buf)
      (2) if M.is_connected() then pcall(M.request, "bye", {}, empty_cb) end
      (3) M.close()
  - ADD step (4) AFTER step (3), BEFORE the closing `end`:
      pcall(function()
        local ok, shell = pcall(require, "pi-bridge.shell")
        if ok and shell and type(shell.teardown) == "function" then
          shell.teardown()
        end
      end)
  - FOLLOW pattern: the existing steps' pcall-guard discipline ("each pcall-guarded
      so exit is NEVER blocked or aborted"). Double-pcall (outer guards the require
      + call; inner require is itself pcall'd so a missing/broken shell module
      cannot abort exit even if `require` itself throws).
  - TYPE-GUARD: `type(shell.teardown)=="function"` — mirrors the S5 forward-guard
      idiom (`if type(M.teardown)=="function" then pcall(M.teardown) end`) already
      used in shell.lua's own parse-failure path. Belt-and-suspenders; shell.teardown
      is DEFINITELY a function today, but the guard is free and future-proofs a
      half-loaded module.
  - UPDATE the on_exit doc comment: change "Three idempotent steps" → "Four
      idempotent steps" and add the (4) bullet:
        "(4) shell.teardown() — kill + close the §17 completion daemon (pcall'd;
             never-throws; no-op if never spawned). PRD §17.5/§17.13."
  - DEPENDENCIES: none new. `shell` is required lazily INSIDE on_exit (NOT at module
      top) — matches bridge.lua's "lazy require, fresh reads" header discipline
      (caching at module load breaks test fakes + the async handshake window).
  - PLACEMENT: inside M.on_exit, as the final step.

Task 2: CREATE tests/bridge_on_exit_shell_spec.lua — regression spec
  - IMPLEMENT: a plenary/busted spec asserting on_exit calls shell.teardown.
  - APPROACH (cleanest — no subprocess, mirrors shell_teardown_spec.lua's mock style):
      a. `package.loaded["pi-bridge.shell"] = <instrumented fake>` BEFORE requiring
         bridge, where the fake is `{ teardown = spy, get_shell_info = function() end }`
         and `spy` is a closure that increments a counter.
      b. require("pi-bridge.bridge"); require("pi-bridge").setup({}) if config nil.
      c. create a throwaway buf (`vim.api.nvim_create_buf(false,true)`; set lines; set
         modified) so autosave has something to write — OR just assert teardown is
         called regardless (autosave is pcall'd + independent).
      d. bridge.on_exit(buf); assert spy was called EXACTLY ONCE.
      e. second call bridge.on_exit(buf); assert spy now called TWICE (each exit fires
         teardown; idempotency is shell.teardown's job, already tested in
         shell_teardown_spec.lua — here we only assert the WIRING).
      f. RESTORE package.loaded["pi-bridge.shell"] in a `finally`/after_each so other
         specs see the real module.
  - ALSO ASSERT never-throws: `assert.has_no.errors(function() bridge.on_exit(buf) end)`.
  - FOLLOW pattern: tests/bridge_on_exit_spec.lua (the sibling exit-handler spec) for
      the create-buf + pcall + assert.has_no.errors idioms; tests/shell_teardown_spec.lua
      header for the `package.loaded` fake-injection idiom.
  - NAMING: describe("bridge.on_exit → shell.teardown wiring (P2.M3.T6.S3)").
  - COVERAGE: (a) called once, (b) called twice across double-fire, (c) never throws,
      (d) called even when never connected (the daemon path is independent of the
      bridge socket — assert teardown fires when is_connected() is false too).
  - PLACEMENT: tests/ alongside the other bridge_on_exit specs.
  - RUN (from repo root, AGENTS.md plenary runner):
      timeout 90 nvim --headless --clean -u tests/minimal_init.lua \
        -c 'lua require("plenary.busted").run("tests/bridge_on_exit_shell_spec.lua")'

Task 3: (NO CODE) re-run the full affected spec suite as the regression gate
  - RUN (AGENTS.md runner):
      for s in bridge_on_exit_spec shell_teardown_spec ftplugin_spec bridge_on_exit_shell_spec; do
        timeout 90 nvim --headless --clean -u tests/minimal_init.lua \
          -c "lua require('plenary.busted').run('tests/${s}_spec.lua')" || exit 1
      done
  - PLUS the plenary-free smokes that touch teardown + on_exit (AGENTS.md smoke runner):
      for s in shell_teardown bridge ftplugin; do
        timeout 60 nvim --headless --clean -u NORC +"luafile tests/${s}_smoke.lua" +qa || exit 1
      done
  - EXPECTED: all green, unchanged from before (the wiring is additive + pcall-guarded;
      no existing assertion can regress because no existing assertion tested the ABSENCE
      of a shell call).
```

### Implementation Patterns & Key Detail

```lua
-- The exact shape of the added step (Task 1). pcall-guarded, lazy-require'd,
-- type-guarded, synchronous (no vim.schedule — GOTCHA E). Append after M.close():

  -- (4) §17 completion-daemon teardown (P2.M3.T6.S3). Kill + close the persistent
  --     shell daemon so its uv handles don't leak for the session (PRD §17.5/§17.13).
  --     pcall'd (never aborts exit); no-op when the daemon was never spawned (S6's
  --     nil + is_closing guards). Lazy require (bridge.lua fresh-reads discipline) +
  --     type-guarded (the S5 forward-guard idiom; free future-proofing).
  --     INDEPENDENT of the bridge socket (§17.13) — order vs M.close() is not
  --     load-bearing; placed last to keep steps (1)-(3)'s proven ordering intact.
  pcall(function()
    local ok, shell = pcall(require, "pi-bridge.shell")
    if ok and type(shell) == "table" and type(shell.teardown) == "function" then
      shell.teardown()
    end
  end)
```

### Integration Points

```yaml
NO new integration points. The wiring reuses:
  - the EXISTING VimLeavePre/ExitPre autocmd in ftplugin/pi-prompt.lua (unchanged),
  - the EXISTING bridge.on_exit(buf) entry point (one appended step),
  - the EXISTING shell.teardown() function (unchanged).
CONFIG: none. (The shell config block landed in P2.M3.T6.S1; teardown is unconditional
  on exit — there is no "skip teardown" knob, and none is wanted: a leaked daemon is
  strictly worse than a killed one, even if the user disabled shell completion via
  `shell.enabled=false`, because the daemon is only ever spawned when completion is
  active. If it was never spawned, teardown is a safe no-op.)
ROUTES / DATABASE / MIGRATIONS: none.
```

## Validation Loop

### Level 1: Syntax & Style (Immediate Feedback)

```bash
# Lua: no project linter wired into the test runner, but selene/stylua are the
# repo's CI linters (PRD §14). Run them if available; otherwise rely on nvim's
# own parser via the smoke/spec loads (a syntax error fails the headless load).
timeout 30 nvim --headless --clean -u NORC \
  -c 'lua assert(loadfile("lua/pi-bridge/bridge.lua"))' \
  -c 'lua assert(loadfile("tests/bridge_on_exit_shell_spec.lua"))' -c 'qa'
echo "exit=$?"
# Expected: exit=0 (both files parse). Also run stylua --check if installed:
stylua --check lua/pi-bridge/bridge.lua tests/bridge_on_exit_shell_spec.lua 2>/dev/null || true
```

### Level 2: Unit Tests (Component Validation)

```bash
# The new regression spec (Task 2).
timeout 90 nvim --headless --clean -u tests/minimal_init.lua \
  -c 'lua require("plenary.busted").run("tests/bridge_on_exit_shell_spec.lua")'
echo "exit=$?"
# Expected: exit=0, all `it(...)` blocks pass.

# Regression: the three specs whose behavior this task brushes against.
for s in bridge_on_exit_spec shell_teardown_spec ftplugin_spec; do
  echo "--- $s ---"
  timeout 90 nvim --headless --clean -u tests/minimal_init.lua \
    -c "lua require('plenary.busted').run('tests/${s}.lua')" \
    2>/dev/null || \
  timeout 90 nvim --headless --clean -u tests/minimal_init.lua \
    -c "lua require('plenary.busted').run('tests/${s}_spec.lua')"
done
# Expected: every spec green; no assertion about the ABSENCE of a shell call exists.
```

### Level 3: Integration Testing (System Validation)

```bash
# Plenary-free smokes (AGENTS.md smoke runner) — these load the REAL modules with
# NO fakes, so they prove the wiring doesn't break the real on_exit path end-to-end.
for s in bridge ftplugin shell_teardown; do
  echo "--- ${s}_smoke ---"
  timeout 60 nvim --headless --clean -u NORC +"luafile tests/${s}_smoke.lua" +qa
  echo "exit=$?"
done
# Expected: every smoke prints its "ok" lines and exits 0.

# Optional manual proof (NOT required — the spec + smoke cover it): from a real pi
# session with the bridge loaded, open the editor (Ctrl+G), type a `!` line to spawn
# the daemon, then :q. Confirm no orphaned shell process remains:
#   pgrep -af "$(basename "$SHELL")" | grep -v $$   # (informational; not a gate)
```

### Level 4: Creative & Domain-Specific Validation

```bash
# Handle-leak proof (best-effort; mirrors tests/shell_teardown_smoke.lua's gated block):
# load bridge + shell, fake-ensure a daemon into state, call on_exit, assert the uv
# handles report is_closing(). This is ALREADY covered by shell_teardown_spec.lua's
# instrumented-pipe assertions; only add a dedicated check here if the Task-2 spec
# does not already assert post-on_exit handle closure. (Recommended: keep Task 2
# focused on the WIRING — teardown's own leak-proofing is shell_teardown_spec's job.)
```

## Final Validation Checklist

### Technical Validation

- [ ] Level 1: both files parse (`loadfile` exit 0); stylua clean if run.
- [ ] Level 2: `bridge_on_exit_shell_spec.lua` passes; `bridge_on_exit_spec.lua`,
      `shell_teardown_spec.lua`, `ftplugin_spec.lua` all still pass.
- [ ] Level 3: `bridge_smoke.lua`, `ftplugin_smoke.lua`, `shell_teardown_smoke.lua`
      all exit 0.
- [ ] No new lint/type errors introduced.

### Feature Validation

- [ ] `bridge.on_exit(buf)` calls `shell.teardown()` (asserted by the new spec).
- [ ] It is pcall-guarded (a throwing teardown cannot abort exit — asserted).
- [ ] It is a safe no-op when the daemon was never spawned (asserted).
- [ ] Idempotent across the `ExitPre`+`VimLeavePre` double-fire (asserted via the
      "called twice" case; teardown's own idempotency is shell_teardown_spec's proof).
- [ ] The ftplugin's exit autocmd is UNCHANGED (single dispatch contract preserved).

### Code Quality Validation

- [ ] Follows bridge.lua's existing on_exit step pattern (numbered, pcall-guarded,
      commented with the PRD citation + GOTCHA).
- [ ] Lazy require inside on_exit (no module-top caching — matches the fresh-reads
      discipline; test fakes + the async handshake window both still work).
- [ ] No new module, no new autocmd, no new config knob (minimal surface).
- [ ] Anti-patterns avoided: no bare (un-pcall'd) call; no vim.schedule; no second
      ftplugin dispatch.

### Documentation & Deployment

- [ ] The on_exit doc comment updated ("Four idempotent steps" + the (4) bullet).
- [ ] (Out of scope for this task, owned by P2.M3.T6.S4 / P2.M4.T7) the user-facing
      `doc/pi-bridge-shell.txt` will document the daemon lifecycle including teardown;
      this PRP does NOT write that doc.

---

## Anti-Patterns to Avoid

- ❌ Don't add a second `dispatch("pi-bridge.shell","teardown",buf)` autocmd in the
  ftplugin — that splits exit teardown across two modules and breaks on_exit's
  single-entry, all-pcall-guarded, ordered guarantee. Funnel through `on_exit`.
- ❌ Don't call `shell.teardown()` bare (un-pcall'd) — every on_exit step is pcall'd
  so exit is never blocked/aborted; the new step must match.
- ❌ Don't `vim.schedule` the teardown — GOTCHA E; the editor may exit before the
  scheduled callback runs, leaking the handles the teardown was meant to close.
- ❌ Don't `require("pi-bridge.shell")` at the top of bridge.lua — cache it lazily
  inside on_exit (the fresh-reads discipline; test fakes inject after require).
- ❌ Don't add a "skip teardown" config knob — a leaked daemon is strictly worse
  than a killed one, and teardown is a no-op when the daemon was never spawned.
- ❌ Don't modify `ftplugin/pi-prompt.lua`, `shell.lua`, or any existing spec.
  The diff is ONE runtime line (inside bridge.on_exit) + ONE new spec file.

---

## Confidence Score

**9/10** — one-pass success likelihood.

Rationale: this is a minimal, purely-additive wiring into a heavily-tested,
well-documented exit handler. The function to call (`shell.teardown`) already
exists, is already idempotent, already never-throws, and is already exhaustively
tested by `shell_teardown_spec.lua`. The call site (`bridge.on_exit`) is the
single documented exit entry point, already pcall-guards every step, and the new
step mirrors that discipline exactly. The only residual risk (hence 9 not 10) is
the `package.loaded` fake-injection in the new spec interacting oddly with
plenary's module caching — mitigated by an `after_each` restore and by mirroring
the exact idiom already proven in `shell_teardown_spec.lua`.

---

## Decisions

**Decision 1 — WHY the call belongs in `bridge.on_exit`, not a second ftplugin dispatch.**
The ftplugin's forward contract (its header, established in the original
ftplugin task) is `require("pi-bridge.bridge").on_exit(buf)` — ONE dispatch, ONE
exit handler, all steps pcall-guarded in one place, with a documented ordering.
Adding a second `dispatch("pi-bridge.shell","teardown",buf)` autocmd would (a)
split exit teardown across two modules, (b) make ordering implicit/undefined
(two separate autocmd callbacks fire in augroup order, not source order), and (c)
duplicate the "never blocks exit" pcall discipline in a second place.
Funneling the shell teardown THROUGH on_exit preserves the single-entry contract,
keeps the diff to one runtime file, and means the existing
`bridge_on_exit_spec.lua` regression net automatically covers the new step's
ordering relative to autosave/bye/close. The shell daemon is independent of the
bridge socket (PRD §17.13), so there is no correctness coupling that would
favor co-location with the bridge transport — on_exit is purely the chosen
single exit entry point.