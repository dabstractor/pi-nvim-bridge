# PRP — P1.M2.T5.S1: Wire daemon cwd re-tracking (Issue 4 / PRD §17.5.2)

name: "P1.M2.T5.S1 — Wire cwd re-tracking in complete_current + update driver M.cd doc-comments"
description: >
  Issue 4: the three shell-completion drivers (fish/zsh/bash) each define `M.cd(path)` and
  their daemon scripts recognize a `__PICD__\t<path>\n` frame, but `driver.cd` has NO caller
  — `M.session_cwd()` is read exactly once (at spawn, `opts.cwd`) and cached in `state.cwd`.
  PRD §17.5.2 advertises mid-session cwd re-tracking; it never happens (dead code). This PRP
  Wires the re-cd in `shell.complete_current` (the per-keystroke buffer→daemon adapter) so
  path/relative completions track pi's working directory, and corrects the driver doc-comments
  (notably zsh's false "re-spawns" claim).

---

## Goal

**Feature Goal**: When pi's session cwd (`bridge.server_info.cwd` → `descriptor.cwd`, via
`M.session_cwd()`) changes AFTER the shell-completion daemon has spawned, the manager re-`cd`s
the daemon before the next completion request, so `!`/`!!` path/relative completions reflect
pi's current working directory — exactly as PRD §17.5.2 ("cwd tracking") specifies.

**Deliverable**:
1. A cwd re-track block inside `lua/pi-bridge/shell.lua` `M.complete_current` (after the
   empty-command guard, before `M.request`) that — when the daemon is already spawned AND
   `session_cwd()` differs from `state.cwd` — calls `state.driver.cd(new)` then updates
   `state.cwd`.
2. A `_test_cwd()` test seam in `shell.lua` (mirrors the existing `_test_gen` /
   `_test_inflight` / `_test_get_pending` seams) so tests can assert the tracked cwd.
3. Corrected `M.cd` / `session_cwd` doc-comments in `shell.lua` + `shell/fish.lua` +
   `shell/bash.lua` + `shell/zsh.lua` (fish/bash: cd is now WIRED + REAL; zsh: cd is now SENT
   but the daemon EATS it — advisory no-op for v1 — and the false "mid-session cwd change
   re-spawns" claim is removed).
4. New plenary cases in `tests/shell_complete_current_spec.lua` + a smoke check in
   `tests/shell_complete_current_smoke.lua` proving the re-cd fires, is FIFO-ordered before
   the `__PIREQ__` frame, and is correctly suppressed (unchanged cwd / unspawned / nil cwd).

**Success Definition**: A session that spawns the daemon while pi's cwd is `/old`, then moves
to `/new` (server_info.cwd updates), produces `!`/`!!` completions relative to `/new` on the
VERY NEXT keystroke (fish/bash); the `__PICD__\t/new\n` frame is written to the daemon stdin
BEFORE that request's `__PIREQ__` frame. zsh stays relative to the spawn cwd (documented v1
limitation) but the write is harmless. All existing + new tests pass; no handle leak.

## User Persona

**Target User**: A pi editor user driving `!`/`!!` Bash-Mode shell completion whose pi
session cwd changes mid-session (e.g. opened the prompt in `/repo`, then pi switched the
working directory to `/repo/src`).

**Use Case**: `!vim src/<Tab>` should complete files in pi's CURRENT cwd, not the stale
spawn-time cwd.

**Pain Points Addressed**: Path/relative completions silently lagging behind pi's real
working directory after a mid-session cwd change (Issue 4) — a correctness gap the standard
test suite never exercised.

## Why

- **PRD fidelity**: §17.5.2 "cwd tracking" explicitly promises: *"if [the session cwd]
  changed since spawn, the driver re-`cd`s the daemon (each driver exposes a `cd(path)` over
  the framed channel) so path/relative completions match pi's working directory."* Today the
  `cd(path)` exists but is never called — the feature is advertised but inert.
- **Correctness for fish/bash**: both daemons honor `__PICD__` with a real `builtin cd`, so
  wiring the call delivers a genuine, user-visible quality win (completions track cwd).
- **Honesty for zsh**: zsh's daemon EATS `__PICD__` (the inner's Enter is bound to a noop
  widget). Wiring the call is harmless (a no-op write) AND lets us correct zsh's doc-comment,
  which today FALSELY claims "a mid-session cwd change re-spawns" — a claim that would mislead
  any future maintainer into believing zsh already self-heals.
- **Low risk**: one new guarded block in a well-tested function; the cd write shares the
  existing libuv FIFO discipline already relied on by `M.request`'s write.

## What

### User-visible / behavioral
- After the daemon is spawned, if pi's session cwd changes, the next `!`/`!!` completion
  (fish/bash) returns path/relative results for the NEW cwd (the daemon is re-`cd`'d first).
- zsh completions stay relative to the spawn cwd for v1 (documented limitation; the `__PICD__`
  write is a harmless no-op).
- A bare `!` / `!   ` still does NOT spawn or touch the daemon (the empty-command guard stays
  first; the re-cd is after it).

### Success Criteria
- [ ] `M.complete_current` calls `state.driver.cd(new)` when `state.proc` is set AND
      `session_cwd() ~= state.cwd`, BEFORE writing the `__PIREQ__` frame.
- [ ] The `__PICD__\t<new>\n` frame is written to the SAME stdin pipe BEFORE the `__PIREQ__`
      frame (FIFO; asserted via `stdin.written` order).
- [ ] `state.cwd` is updated to the new cwd after the cd write (assertable via `_test_cwd()`).
- [ ] No re-cd when: cwd unchanged, daemon unspawned, `session_cwd()` nil, or driver has no
      `cd` function — and none of these throw.
- [ ] fish.lua + bash.lua doc-comments state `cd` is WIRED (called from `complete_current`)
      and REAL (daemon honors it).
- [ ] zsh.lua doc-comment: removes the false "mid-session cwd change re-spawns" claim; states
      `__PICD__` is now SENT but EATEN (advisory no-op for v1; path completions stay relative
      to the spawn cwd for the session).
- [ ] `M.session_cwd()` doc-comment notes it is now re-read per `complete_current` (not only
      at spawn).
- [ ] All existing tests still pass; new plenary + smoke cases pass; no `uv_timer_t` leak.

## All Needed Context

### Context Completeness Check
_"If someone knew nothing about this codebase, would they have everything needed to implement this successfully?"_
Yes — the exact function, the exact insertion point, the exact write-ordering invariant, the
driver cd capability matrix, the test-injection pattern, and the verified validation commands
are all below.

### Documentation & References

```yaml
# MUST READ — the canonical PRD text this implements
- docfile: plan/002_d23d7473c16c/architecture/research-prd-section-17.md
  section: "§17.5.2 shell.lua reference skeleton — cwd tracking bullet"
  why: |
    Verbatim: "cwd tracking: M.session_cwd() reads descriptor.cwd; if it changed since
    spawn, the driver re-cd's the daemon (each driver exposes a cd(path) over the framed
    channel) so path/relative completions match pi's working directory."
  critical: |
    This is the SOPE of the fix: re-read session_cwd per request; if changed since spawn,
    call driver.cd. Do NOT over-engineer (no cwd-watch autocmd; no async cd-ack protocol).

# The function being modified — read the WHOLE complete_current before editing
- file: lua/pi-bridge/shell.lua
  why: |
    M.complete_current(buf, cb) — the §17.7 buffer→daemon adapter. Steps: guard buf → read
    line1 → read cursor → bang strip → compute byte triple → EMPTY-CMD GUARD → [INSERT RE-CD
    HERE] → M.request(line, cin, after, wrapper_cb). Runs on the nvim MAIN LOOP (its doc says
    so; caller completion.lua do_shell_fetch is per-keystroke).
  pattern: |
    The empty-cmd guard (step 6) returns cb(nil, {}, "") for a bare "!"/"!   " BEFORE
    M.request. The re-cd MUST go AFTER it (a bare "!" must not spawn or cd the daemon) and
    BEFORE M.request (so __PICD__ is queued before __PIREQ__).
  gotcha: |
    M.request FIRST calls M.ensure — if the daemon is unspawned, ensure spawns it with
    session_cwd() as opts.cwd (shell.lua:461), seeding state.cwd (shell.lua:486). So the
    re-cd only matters AFTER spawn; guard on state.proc.

# The cwd source + the spawn-time cache site
- file: lua/pi-bridge/shell.lua
  why: |
    M.session_cwd() (reads bridge.server_info.cwd → pi.descriptor.cwd → nil, FRESH + lazy).
    state.cwd is set ONCE at spawn (shell.lua:486 `state.cwd = opts.cwd`) and cleared by
    M.reset() (shell.lua:342). The state table literal + @class are at shell.lua:96-122.
  pattern: |
    session_cwd() is already never-throws + lazy-required. Reuse it directly in the re-cd
    block — do NOT cache it.
  gotcha: |
    _reset (EOF crash path) nils state.proc but does NOT clear state.cwd. That is FINE: the
    re-cd guards on state.proc (nil after crash → skip); on re-spawn ensure re-seeds
    state.cwd. Do NOT add cwd clearing to _reset.

# The write-ordering invariant (the correctness crux)
- file: lua/pi-bridge/shell.lua
  why: |
    M.request writes the __PIREQ__ frame to state.stdin (shell.lua request(), the
    `state.stdin:write(frame, write_cb)` step). state.driver.cd writes __PICD__ to the
    driver-cached last_stdin.
  critical: |
    last_stdin (driver) and state.stdin (shell.lua) are the SAME uv_pipe_t — the driver's
    on_ready hands `stdin` to shell.lua (stored as state.stdin) AND caches last_stdin=stdin.
    libuv queues uv_write_t on a single uv_stream_t in FIFO SUBMISSION order, so a cd write
    submitted synchronously before M.request's write is processed FIRST by the daemon's
    `while read` loop (builtin cd, then the completion query in the new cwd). DO NOT
    vim.schedule or defer the cd — it must be submitted synchronously inside complete_current
    to preserve FIFO vs the immediately-following request write.

# The drivers' cd capability (verified by reading each DAEMON_SCRIPT)
- file: lua/pi-bridge/shell/fish.lua
  why: M.cd(path) + the __pi_handle "__PICD__*" branch does `builtin cd "$p"` (REAL cd).
  pattern: cd is best-effort/silent; write via last_stdin w/ a noop cb; is_closing-guarded.
  critical: fish daemon HONORS __PICD__ → wiring the call makes fish completions track cwd.
- file: lua/pi-bridge/shell/bash.lua
  why: M.cd(path) + __pi_handle "__PICD__*" → `builtin cd "$p"` (REAL cd, research §6).
  critical: bash daemon HONORS __PICD__ → wiring the call makes bash completions track cwd.
- file: lua/pi-bridge/shell/zsh.lua
  why: |
    M.cd(path) exists BUT the OUTER_SCRIPT case is `(__PICD*) ;;` — a literal no-op. The
    INNER's Enter is bound to a noop widget (Valodim safety), so a true inner cd is not wired.
  critical: |
    zsh v1 EATS __PICD__. Wiring the call is HARMLESS (a no-op write) but does NOT make zsh
    track cwd. The CURRENT doc FALSELY says "a mid-session cwd change re-spawns" — REMOVE
    that (the daemon is persistent for the session; nothing re-spawns).

# The test-injection pattern to copy
- file: tests/shell_complete_current_spec.lua
  why: |
    fake_bridge(shell_path) → {get_shell_info, server_info={}}. make_fake_stdin() captures
    written frames. inject_fake_driver(stdin) sets package.loaded["pi-bridge.shell.fish"]=drv
    so state.driver==drv (observable). buf_with(line, byte_col) sets virtualedit=onemore.
  pattern: |
    shell.ensure(cb) spawns the fake; shell.complete_current(buf, cb) drives it; deliver the
    response via shell._test_invoke_pending(items, prefix). before_each/after_each reset state
    + nil package.loaded["pi-bridge.shell.fish"] + restore pi.bridge.
  gotcha: |
    To seed state.cwd, set pi.bridge.server_info.cwd (fake_bridge sets server_info={}; mutate
    it, OR pass a cwd — shell_ensure_spec.lua fake_bridge(shell_path, server_cwd) takes one).
    To assert cd was called + FIFO order, give the fake drv.cd a body that writes
    "__PICD__\t<path>\n" to the fake stdin (mirrors a real driver) AND records drv.cd_calls.

# The cwd source test (proves session_cwd semantics already covered — do not duplicate)
- file: tests/shell_smoke.lua
  why: |
    Lines 199-241 already unit-test M.session_cwd() (server_info.cwd → descriptor.cwd → nil,
    post-reset, never-throws). The NEW tests assert the CALLER (complete_current) uses it to
    re-cd — they should NOT re-test session_cwd itself.
```

### Current Codebase tree (relevant slice)

```bash
lua/pi-bridge/
  shell.lua            # MODIFIED — complete_current re-cd block + _test_cwd seam + doc-comments
  shell/
    fish.lua           # MODIFIED — M.cd doc-comment (WIRED + REAL)
    zsh.lua            # MODIFIED — M.cd doc-comment (SENT but EATEN; remove false "re-spawns")
    bash.lua           # MODIFIED — M.cd doc-comment (WIRED + REAL)
tests/
  shell_complete_current_spec.lua   # MODIFIED — add cwd re-track cases
  shell_complete_current_smoke.lua  # MODIFIED — add a plenary-free re-cd smoke check
```

### Known Gotchas of our codebase & Library Quirks

```lua
-- CRITICAL: the cd write + the request write MUST both be submitted SYNCHRONOUSLY inside
--   one complete_current call, to the SAME uv_pipe_t, so libuv FIFO order guarantees the
--   daemon sees __PICD__ before __PIREQ__. Do NOT vim.schedule the cd (deferring it breaks
--   ordering — the request write could be queued first). Mirrors M.request's own write
--   discipline (it submits state.stdin:write synchronously inside its ensure cb).

-- CRITICAL: place the re-cd AFTER the empty-command guard (step 6) and BEFORE M.request
--   (step 7). A bare "!" must NOT spawn or cd the daemon. If daemon is unspawned
--   (state.proc == nil), LEAVE it to M.ensure (it spawns WITH session_cwd() as opts.cwd →
--   state.cwd is already fresh → no re-cd needed on first spawn).

-- GOTCHA: state.driver is set BEFORE spawn (shell.lua ensure step 5) but state.proc is set
--   ONLY on a SUCCESSFUL spawn. GUARD ON state.proc (not state.driver) for "is the daemon
--   alive" — state.driver alone is true even during a failed/never-spawned session.

-- GOTCHA: pick_driver only REQUIRES drv.start (shell.lua:243-244); a custom/3rd-party driver
--   may lack drv.cd. Guard `type(state.driver.cd) == "function"` before calling. NEVER
--   assume all drivers expose cd (the PRD calls it "(optionally) cd(path)").

-- GOTCHA: zsh's daemon EATS __PICD__ (advisory no-op for v1). Wiring the call is correct
--   (the contract is honored; future zsh work can make cd real) but do NOT assert zsh
--   completions track cwd — they don't yet. The doc MUST say so.

-- CRITICAL (AGENTS.md HARD RULE): write any lua test SNIPPET to a real FILE (tests/* or
--   /tmp/*.lua) then run via +"luafile <path>" +qa. NEVER pipe a heredoc into nvim stdin
--   (it hangs the session forever). Every nvim invocation gets a bounded `timeout`.

-- GOTCHA: never-throws is a per-keystroke + autocmd contract for complete_current. pcall the
--   cd call; guard session_cwd()'s return type; a dead/closed pipe is the DRIVER's problem
--   (driver.cd is_closing-guards + noop-returns) — complete_current does NOT need to check
--   pipe liveness itself.
```

## Implementation Blueprint

### Data models and structure

No new data models. The existing `pi-bridge.ShellState` (shell.lua:96-122) already has the
`cwd string?` field (documented as "The session cwd at spawn"). This task:
- REUSES `state.cwd` (now also the *tracked* cwd, updated on re-cd — extend its doc-comment).
- REUSES `state.driver`, `state.proc`, `M.session_cwd()`, each driver's `M.cd(path)`.
- ADDS one test seam `M._test_cwd()` (a plain read of `state.cwd`).

### Implementation Tasks (ordered by dependencies)

```yaml
Task 1: MODIFY lua/pi-bridge/shell.lua — wire the cwd re-track block in M.complete_current
  - FIND: M.complete_current (shell.lua, the §17.7 buffer→daemon adapter). Locate step (6)
          EMPTY-COMMAND GUARD (`if cmd == "" or cmd:match("^%s*$") then return cb(nil, {}, "") end`)
          and step (7) DELEGATE TO M.request.
  - INSERT (between step 6 and step 7 — i.e. AFTER the empty-cmd guard, BEFORE M.request):
      -- (6.5) CWD RE-TRACKING (Issue 4 / PRD §17.5.2 "cwd tracking"): if the daemon is
      --   ALREADY spawned AND pi's session cwd changed since spawn, re-`cd` the daemon so
      --   this request's path/relative completions track the new cwd. Submitted SYNCHRONOUSLY
      --   before M.request so the __PICD__ frame is queued on the SAME uv_pipe_t (last_stdin
      --   == state.stdin) BEFORE the __PIREQ__ frame — libuv FIFO write order on a single
      --   uv_stream_t guarantees the daemon's while-read loop sees __PICD__ first (builtin cd)
      --   then __PIREQ__ (completion in the new cwd). Daemon-not-spawned is left to M.ensure
      --   (it spawns WITH session_cwd() as opts.cwd → state.cwd fresh → no re-cd on first
      --   spawn). Guard state.driver.cd is a function (pick_driver only requires .start; a
      --   custom driver may lack cd). NEVER throws (pcall the cd). state.cwd updated
      --   optimistically (the write is queued; a failed write silently keeps the old cwd — a
      --   one-request stale degrade that self-heals next keystroke since session_cwd() is then
      --   unchanged).
      if state.proc and state.driver and type(state.driver.cd) == "function" then
          local cur_cwd = M.session_cwd()
          if type(cur_cwd) == "string" and cur_cwd ~= state.cwd then
              pcall(state.driver.cd, cur_cwd)
              state.cwd = cur_cwd
          end
      end
  - DO NOT touch: the empty-cmd guard, the bang strip, the byte-triple math, M.request, M.ensure,
          _reset, teardown, or any notice block.
  - NAMING: `cur_cwd` local (snake_case; mirrors the file's style).

Task 2: MODIFY lua/pi-bridge/shell.lua — extend the @field cwd doc-comment + session_cwd note
  - FIND: the `---@field cwd string?` line in the pi-bridge.ShellState @class (shell.lua:107).
  - CHANGE its why-text from "The session cwd at spawn (set by S3 ensure via session_cwd)." to
    note it is now the TRACKED cwd: "The session cwd, seeded at spawn (ensure via session_cwd)
    and re-synced by complete_current on a mid-session cwd change (Issue 4 / §17.5.2)."
  - FIND: M.session_cwd() doc-comment (shell.lua ~255-269). Change "Drivers use this as the
    spawn cwd ... a driver may re-cd over the framed channel if it changed since spawn." to
    state the re-cd is now WIRED: "... complete_current re-reads this per request and, if it
    changed since spawn, calls state.driver.cd(new) before the next request (Issue 4)."

Task 3: MODIFY lua/pi-bridge/shell.lua — add the _test_cwd() seam (mirrors _test_gen etc.)
  - FIND: the TEST SEAMS block near the end of shell.lua (after _test_get_pending).
  - ADD:
      --- TEST seam: read `state.cwd` (the spawn/tracked cwd; assert complete_current re-cd
      --- updates it on a mid-session cwd change — Issue 4 / §17.5.2). Mirrors _test_gen.
      ---@return string?
      function M._test_cwd()
          return state.cwd
      end
  - PLACEMENT: alongside the other _test_* seams (NOT in the public API section).

Task 4: MODIFY lua/pi-bridge/shell/fish.lua — M.cd doc-comment (WIRED + REAL)
  - FIND: the M.cd(path) doc-comment (fish.lua ~417-427) + the file header bullet that mentions cd.
  - CHANGE: prepend a note that cd is now CALLED — "Called by shell.complete_current whenever
    pi's session cwd (M.session_cwd()) changed since spawn (Issue 4 / §17.5.2): the daemon
    honors __PICD__ with a real builtin cd, so fish path/relative completions track the new
    cwd on the very next keystroke." Keep the existing best-effort/silent/is_closing-guard text.
  - DO NOT change the M.cd BODY or the DAEMON_SCRIPT (both already correct).

Task 5: MODIFY lua/pi-bridge/shell/bash.lua — M.cd doc-comment (WIRED + REAL)
  - FIND: the M.cd(path) doc-comment (bash.lua ~464-476) + the "REAL cd (NOT advisory like zsh
    v1)" header bullet.
  - CHANGE: prepend the same "Called by shell.complete_current on a cwd change (Issue 4 / §17.5.2)
    — bash honors __PICD__ with a real builtin cd, so completions track cwd" note. Keep "REAL".
  - DO NOT change the M.cd BODY or the DAEMON_SCRIPT.

Task 6: MODIFY lua/pi-bridge/shell/zsh.lua — M.cd doc-comment (SENT but EATEN; fix false claim)
  - FIND: the M.cd(path) doc-comment (zsh.lua ~485-496) + the header KNOWN LIMITATIONS bullet
    that says "cd(path) is ADVISORY (a documented no-op for v1) ... a mid-session cwd change
    re-spawns."
  - CHANGE:
      1. Note cd is now SENT on a cwd change by complete_current (Issue 4 / §17.5.2), BUT the
         zsh OUTER EATS __PICD__ (the case branch is `(__PICD*) ;;` — a no-op; the inner's
         Enter is bound to a noop widget). So zsh v1 does NOT track mid-session cwd: path
         completions stay relative to the spawn cwd for the session (documented limitation;
         a future control-char widget can make cd real).
      2. REMOVE the FALSE sentence "a mid-session cwd change re-spawns" — nothing re-spawns
         (the daemon is persistent for the session). This is a correctness fix to the doc.
  - DO NOT change the M.cd BODY or the OUTER_SCRIPT/INNER_SCRIPT (the no-op case is intentional
    for v1; making cd real is out of scope — a future task).

Task 7: MODIFY tests/shell_complete_current_spec.lua — add cwd re-track cases
  - ADD a helper `inject_fake_driver_with_cd(stdin)` next to the existing inject_fake_driver:
      it returns a drv whose start() hands the fake handles AND captures opts.cwd, and whose
      cd(path) both records drv.cd_calls AND writes "__PICD__\t<path>\n" to the fake stdin
      (mirrors a real driver → asserts cd-was-called AND FIFO write order).
      local function inject_fake_driver_with_cd(stdin)
          local drv = { cd_calls = {}, captured = {} }
          drv.start = function(opts, cb)
              drv.captured.opts = opts
              cb(nil, { is_closing = function() return false end }, stdin, make_fake_stdout())
          end
          drv.cd = function(path)
              drv.cd_calls[#drv.cd_calls + 1] = path
              stdin:write(string.format("__PICD__\t%s\n", path), function() end)
          end
          package.loaded["pi-bridge.shell.fish"] = drv
          return drv
      end
  - ADD cases (inside the existing describe block, after the existing cases):
      (a) re-cd FIRES + FIFO order:
            ensure() with server_info.cwd="/old"; assert shell._test_cwd()=="/old".
            mutate pi.bridge.server_info.cwd="/new"; buf "!git ch"; complete_current.
            assert drv.cd_calls=={"/new"}; stdin.written[1]=="__PICD__\t/new\n";
            stdin.written[2] (the __PIREQ__ frame) startsWith "__PIREQ__\t";
            shell._test_cwd()=="/new". Deliver response; assert prefix/items forward unchanged.
      (b) NO re-cd when cwd UNCHANGED: ensure w/ cwd "/old"; complete_current (cwd still "/old").
            assert drv.cd_calls=={}; stdin.written[1] startsWith "__PIREQ__" (no __PICD__);
            shell._test_cwd()=="/old".
      (c) NO re-cd when daemon NOT spawned: do NOT ensure() first; buf "!git"; complete_current
            with server_info.cwd="/new". Assert drv.cd_calls=={} (ensure spawns w/ "/new" as
            opts.cwd; re-cd skipped); shell._test_cwd()=="/new" (seeded by spawn, NOT by re-cd).
      (d) NIL session_cwd → no re-cd, no throw: ensure w/ no server_info.cwd (nil); buf "!git";
            complete_current. Assert drv.cd_calls=={}; shell._test_cwd()==nil; no error.
      (e) driver WITHOUT cd → no throw: inject a drv with NO cd field; ensure; mutate cwd;
            complete_current. Assert no error (the type()=="function" guard skips). (Optional
            but recommended — proves the custom-driver guard.)
  - before_each/after_each: already reset() + nil package.loaded + restore pi.bridge — reuse.
  - NAMING: test descriptions in the existing "..." style ("'!git ch' → ...").

Task 8: MODIFY tests/shell_complete_current_smoke.lua — add a plenary-free re-cd smoke check
  - ADD a section (C) after the existing (A)/(B): ensure() with server_info.cwd="/old";
    mutate to "/new"; buf "!git ch"; complete_current; assert stdin.written[1] ==
    "__PICD__\t/new\n" AND stdin.written[2] startsWith "__PIREQ__\t". Use check(c, msg).
  - Reuse the file's make_fake_stdin / inject_fake_driver, but the injected drv MUST have a cd
    that writes to stdin (copy the spec's inject_fake_driver_with_cd shape, minus the assert lib).
  - ⛔ This FILE is run via +"luafile tests/shell_complete_current_smoke.lua" +qa (AGENTS.md).
```

### Implementation Patterns & Key Details

```lua
-- PATTERN: the re-cd block (the whole deliverable in one place). Insert between the
-- empty-command guard and the M.request delegation in M.complete_current:
if state.proc and state.driver and type(state.driver.cd) == "function" then
    local cur_cwd = M.session_cwd()
    if type(cur_cwd) == "string" and cur_cwd ~= state.cwd then
        pcall(state.driver.cd, cur_cwd)   -- best-effort; driver is_closing-guards + noops
        state.cwd = cur_cwd               -- optimistic; FIFO-ordered before the __PIREQ__ write
    end
end

-- PATTERN: the test seam (mirrors _test_gen / _test_inflight / _test_get_pending exactly):
function M._test_cwd()
    return state.cwd
end

-- CRITICAL ordering reasoning (cite this in the code comment):
--   1. complete_current runs on the nvim MAIN LOOP (synchronous up to the M.request call).
--   2. state.driver.cd(cur) calls last_stdin:write("__PICD__\t<path>\n", noop) — a QUEUED
--      uv_write_t on the daemon stdin pipe.
--   3. M.request (called next) calls state.stdin:write("__PIREQ__\t{json}\n", cb) — ANOTHER
--      queued uv_write_t on the SAME pipe (last_stdin IS state.stdin).
--   4. libuv writes a single uv_stream_t in FIFO submission order → daemon reads __PICD__
--      first (builtin cd) then __PIREQ__ (completion in the new cwd). The CURRENT request
--      tracks the new cwd (not the next one).
-- DO NOT: vim.schedule the cd; defer it; call it from M.request (keeps request a pure framer);
--          add a cd-ack/response (the daemon's __PICD__ path emits NO response — fire-and-forget).

-- PATTERN: the fake driver cd for tests (asserts call + FIFO order):
drv.cd = function(path)
    drv.cd_calls[#drv.cd_calls + 1] = path
    stdin:write(string.format("__PICD__\t%s\n", path), function() end)
end
```

### Integration Points

```yaml
STATE (lua/pi-bridge/shell.lua):
  - field: state.cwd
    change: "doc-only — already exists; now also the TRACKED cwd (updated on re-cd). No new field."
  - seam: M._test_cwd()  (NEW — read state.cwd; mirrors _test_gen)

CALL GRAPH (no new edges to external systems):
  - complete_current → [NEW] state.driver.cd(new)  (fish/bash/zsh already define M.cd)
  - complete_current → M.session_cwd()  (existing helper; now ALSO called per request, not just spawn)
  - The cd write reuses the SAME uv_pipe_t as M.request's write (last_stdin == state.stdin).

DOCUMENTATION (doc-comments only — no doc/pi-bridge-shell.txt change REQUIRED for this task;
  P1.M2.T7.S1 owns the changeset doc sweep; if you touch pi-bridge-shell.txt keep it to the
  cwd-tracking sentence and note fish/bash track + zsh does not for v1):
  - lua/pi-bridge/shell.lua: @field cwd + session_cwd() + complete_current step (6.5) comments
  - lua/pi-bridge/shell/fish.lua: M.cd header + the file header bullet that mentions cd
  - lua/pi-bridge/shell/bash.lua: M.cd header + the "REAL cd" header bullet
  - lua/pi-bridge/shell/zsh.lua: M.cd header + KNOWN LIMITATIONS bullet (remove "re-spawns")

CONFIG: none (no new config key; §17.11 defines no cwd-retrack toggle).
```

## Validation Loop

> ⛔ AGENTS.md HARD RULE: write every lua snippet to a real FILE then run via
> `+"luafile <path>" +qa`. NEVER pipe a heredoc into nvim stdin (it hangs). Every nvim
> invocation is bounded by `timeout`. Run commands from the repo root.

### Level 1: Syntax & Style (Immediate Feedback)

```bash
# No luacheck/stylua/selene config in this repo — the headless load IS the syntax gate.
# (a) Compile-check each modified lua file loads cleanly under a real nvim (catches syntax
#     errors + a bad require path). One file per line; exit non-zero on any error.
for f in lua/pi-bridge/shell.lua lua/pi-bridge/shell/fish.lua lua/pi-bridge/shell/bash.lua lua/pi-bridge/shell/zsh.lua; do
  timeout 30 nvim --headless --clean -u NORC -c "set rtp+=." -c "lua require('$(echo $f | sed 's#lua/##;s#\.lua##;s#/#.#g')')" -c 'qa' \
    && echo "OK $f" || { echo "FAIL $f"; exit 1; }
done

# (b) The plenary spec + smoke (Level 2) ALSO exercise the load — a syntax error fails them.

# Expected: every file prints OK; zero errors. Fix before proceeding.
```

### Level 2: Unit Tests (Component Validation)

```bash
# The PRIMARY gate — the modified complete_current + the new cwd re-track cases.
timeout 90 nvim --headless --clean -u tests/minimal_init.lua \
  -c 'lua require("plenary.busted").run("tests/shell_complete_current_spec.lua")'
echo "exit=$?"

# The plenary-free smoke (file-based; covers the same surface without plenary).
timeout 60 nvim --headless --clean -u NORC +"luafile tests/shell_complete_current_smoke.lua" +qa
echo "exit=$?"   # expects S3_SMOKE_OK + exit 0

# Regression: ensure still seeds state.cwd (the re-cd seed); shell_smoke covers session_cwd.
timeout 90 nvim --headless --clean -u tests/minimal_init.lua \
  -c 'lua require("plenary.busted").run("tests/shell_ensure_spec.lua")'
timeout 60 nvim --headless --clean -u NORC +"luafile tests/shell_smoke.lua" +qa

# Regression: the driver cd unit tests still pass (cd is now CALLED, but the driver method
# itself is unchanged — these must stay green).
timeout 60 nvim --headless --clean -u NORC +"luafile tests/shell_fish_driver_smoke.lua" +qa
timeout 60 nvim --headless --clean -u NORC +"luafile tests/shell_bash_driver_smoke.lua" +qa
timeout 60 nvim --headless --clean -u NORC +"luafile tests/shell_zsh_driver_smoke.lua" +qa

# Expected: all PASS / exit 0. If a spec fails, READ the plenary output + fix the root cause
# (do NOT weaken an assertion to make it pass).
```

### Level 3: Integration Testing (System Validation)

```bash
# Full shell test surface (catches a regression in request/_feed/teardown/ensure from the
# complete_current edit, and confirms no uv_timer_t leak was introduced).
timeout 90 nvim --headless --clean -u tests/minimal_init.lua \
  -c 'lua require("plenary.busted").run("tests/shell_request_spec.lua")'
timeout 90 nvim --headless --clean -u tests/minimal_init.lua \
  -c 'lua require("plenary.busted").run("tests/shell_feed_spec.lua")'
timeout 90 nvim --headless --clean -u tests/minimal_init.lua \
  -c 'lua require("plenary.busted").run("tests/shell_spec.lua")'

# (Optional, real daemons — only if fish/zsh/bash are installed on the box; the fake-driver
#  tests above are the contract gate. Skip on CI boxes without the shells.)
# timeout 60 nvim --headless --clean -u NORC +"luafile tests/shell_fish_driver_smoke.lua" +qa

# Expected: all PASS. No hangs (every command has a bounded timeout per AGENTS.md).
```

### Level 4: Creative & Domain-Specific Validation

```bash
# No MCP/Docker/Playwright surface for this Lua plugin. The domain-specific validation is a
# REAL-driver cwd round-trip IF a fish (or bash) daemon is available on the box — proves the
# __PICD__ frame actually moves the daemon's cwd end-to-end. Write to a FILE (AGENTS.md):

cat > /tmp/pi_cwd_retrack_e2e.lua <<'LUA'
-- Proves Issue 4 end-to-end: spawn a real fish daemon at /tmp, then move cwd to /tmp/<sub>,
-- complete a relative path, assert the result is from the NEW cwd.
local shell = require("pi-bridge.shell")
local pi = require("pi-bridge")
if pi.config == nil then pi.setup({}) end
os.execute("rm -rf /tmp/pi_cwd_e2e; mkdir -p /tmp/pi_cwd_e2e/only_in_sub")
pi.bridge = { get_shell_info = function() return { shell = "/usr/bin/fish" } end,
              server_info = { cwd = "/tmp/pi_cwd_e2e" } }
local sub = "/tmp/pi_cwd_e2e/only_in_sub"
local function run()
  shell.complete_current(0, function(err, items)  -- 0 = current buf (set by the caller)
    if err then print("ERR", err); os.exit(1) end
    local hit = false
    for _, it in ipairs(items or {}) do if it.value and it.value:find("only_in_sub") then hit = true end end
    print(hit and "CWD_RETRACK_OK" or "CWD_RETRACK_FAIL")
    vim.cmd("qa")
  end)
end
-- set up a buffer + cursor, seed cwd at /tmp/pi_cwd_e2e, spawn, then move to sub, then run:
local buf = vim.api.nvim_create_buf(false, true); vim.api.nvim_win_set_buf(0, buf)
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "!only_" })
vim.wo[0].virtualedit = "onemore"; vim.api.nvim_win_set_cursor(0, { 1, 6 })
shell.ensure(function() pi.bridge.server_info.cwd = sub; run() end)
LUA
# (Seed cwd at /tmp/pi_cwd_e2e, then the e2e moves server_info.cwd to the subdir BEFORE the
#  first complete_current — so the re-cd must fire on that very request.)
timeout 60 nvim --headless --clean -u NORC -c 'set rtp+=.' +"luafile /tmp/pi_cwd_retrack_e2e.lua" +qa
echo "exit=$?"   # fish present → prints CWD_RETRACK_OK ; absent → skip (the fake tests gate it)

# Expected (fish/bash present): CWD_RETRACK_OK. (zsh: advisory no-op — do NOT expect OK; the
# doc-comment change is the deliverable there, not behavior.)
```

## Final Validation Checklist

### Technical Validation
- [ ] Level 1: every modified `.lua` loads headless (the `for f in ... nvim ...` loop prints OK).
- [ ] Level 2: `tests/shell_complete_current_spec.lua` PASS (incl. the NEW cwd re-track cases).
- [ ] Level 2: `tests/shell_complete_current_smoke.lua` prints `S3_SMOKE_OK` + exit 0.
- [ ] Level 2: `tests/shell_ensure_spec.lua` + `tests/shell_smoke.lua` PASS (cwd seed/regression).
- [ ] Level 2: driver cd unit smokes (`shell_{fish,bash,zsh}_driver_smoke.lua`) PASS.
- [ ] Level 3: `shell_request_spec` / `shell_feed_spec` / `shell_spec` PASS (no regression).
- [ ] No `uv_timer_t` leak (the existing no-leak case in the spec still passes — the re-cd
      adds no timer).

### Feature Validation
- [ ] re-cd fires when spawned + cwd changed; `__PICD__` written BEFORE `__PIREQ__` (FIFO).
- [ ] `state.cwd` updated (assert via `_test_cwd()`).
- [ ] No re-cd when: cwd unchanged / daemon unspawned / `session_cwd()` nil / driver lacks cd.
- [ ] None of the above throw.
- [ ] fish.lua + bash.lua doc-comments say cd is WIRED + REAL.
- [ ] zsh.lua doc-comment: `__PICD__` SENT but EATEN (advisory no-op v1); false "re-spawns" removed.
- [ ] `M.session_cwd()` + `@field cwd` doc-comments note the per-request re-read / tracking.

### Code Quality Validation
- [ ] The re-cd block mirrors the file's never-throws + pcall + type-guard discipline.
- [ ] No new public API beyond the `_test_cwd()` seam (internal, `_test_` prefixed — NOT API).
- [ ] No change to `M.request` / `M.ensure` / `_reset` / `teardown` / the daemon scripts / the
      empty-cmd guard / the bang strip / the byte-triple math.
- [ ] Comments cite PRD §17.5.2 + Issue 4 + the FIFO-ordering reasoning.
- [ ] Doc-comment edits are accurate to each driver's REAL capability (fish/bash REAL; zsh no-op).

### Documentation & Deployment
- [ ] Code is self-documenting (the re-cd block explains the ordering invariant inline).
- [ ] No new env var / config key (§17.11 defines none for cwd re-track).
- [ ] (P1.M2.T7.S1 owns the README/doc/pi-bridge-shell.txt sweep — keep this task to code + tests
      + the in-file doc-comments; if you touch pi-bridge-shell.txt, note fish/bash track + zsh does not.)

---

## Anti-Patterns to Avoid

- ❌ Do NOT `vim.schedule`/defer the `cd` write — it MUST be submitted synchronously inside
  `complete_current` to preserve FIFO order vs the immediately-following `__PIREQ__` write.
- ❌ Do NOT put the re-cd in `M.request` — that breaks its purity as a framing layer AND would
  fire the cd on every low-level request (tests call `M.request` directly). The task title is
  explicit: wire it in `complete_current`.
- ❌ Do NOT put the re-cd BEFORE the empty-command guard — a bare `!` would then cd (and
  possibly spawn) the daemon. The empty-cmd guard stays first.
- ❌ Do NOT guard on `state.driver` alone for "is the daemon alive" — it is set before spawn;
  guard on `state.proc`.
- ❌ Do NOT assume all drivers expose `cd` — `pick_driver` only requires `.start`. Guard the type.
- ❌ Do NOT add cwd-clearing to `_reset` — the `state.proc` guard already prevents a stale re-cd,
  and re-spawn re-seeds `state.cwd`. Clearing it would mask nothing and risk a new bug.
- ❌ Do NOT make zsh `cd` "real" in this task — that needs an INNER control-char widget (out of
  scope; a future task). Just SEND the frame (harmless no-op) + fix the doc-comment.
- ❌ Do NOT weaken a test assertion to make it pass; if a case fails, fix the implementation.
- ❌ Do NOT pipe a heredoc into `nvim` stdin (AGENTS.md HARD RULE — it hangs the session). Write
  lua to a FILE, run via `+"luafile <path>" +qa`, always bounded by `timeout`.

---

**Confidence Score: 9/10** — the fix is a single well-localized guarded block in an already
heavily-tested function, reusing three drivers' already-correct `M.cd` + `__PICD__` plumbing
and libuv's guaranteed FIFO write order. The only residual uncertainty is the real-driver
Level-4 round-trip (depends on fish/bash being installed on the validation box) — but the
fake-driver plenary + smoke cases are the binding contract gate and are fully self-contained.