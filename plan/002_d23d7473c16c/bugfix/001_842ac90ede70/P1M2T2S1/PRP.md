---
name: "P1.M2.T2.S1 — Issue 4: wire daemon cwd re-tracking in complete_current + driver M.cd doc-comments"
description: |
  A ~9-line insertion in `lua/pi-bridge/shell.lua`'s `M.complete_current` (between the
  empty-command guard and the `M.request` delegation) + a 3-line `_test_cwd()` test seam
  (mirroring `_test_gen`) + doc-comment refresh in all 3 drivers (`fish.lua`,
  `bash.lua`, `zsh.lua`) + two plenary cases in `tests/shell_complete_current_spec.lua`.
  Today every driver defines `M.cd(path)` (writes a `__PICD__\t<path>\n` frame to the
  daemon's stdin) but **NO caller exists** — `grep -rn '\.cd('` returns only the driver
  definitions, so `state.driver.cd` is dead code (PRD §h3.3 Issue 4). The daemon-side
  handlers ALREADY work: fish (`builtin cd`, fish.lua:114) + bash (`builtin cd`,
  bash.lua:189) honor `__PICD__` functionally; only zsh no-ops (empty `(__PICD*) ;;` body,
  zsh.lua:219 — a known v1 limitation). `complete_current` (the per-keystroke entry called
  by completion.lua's `do_shell_fetch`) is the right place to re-cd: BEFORE `M.request`
  writes its `__PIREQ__` frame, so the daemon processes `__PICD__` first (sequential pipe
  writes guarantee frame order). The fix: `local cwd_now = M.session_cwd()` (fresh read);
  `if cwd_now and state.cwd and cwd_now ~= state.cwd and state.driver and
  type(state.driver.cd) == "function" then pcall(state.driver.cd, cwd_now); state.cwd =
  cwd_now end`. The `state.cwd` update caches the new cwd (no re-cd every keystroke — only
  when it actually changes); `pcall` + the type-guard ensure a nil driver or a throwing
  `driver.cd` never aborts completion. Tests (shell_complete_current_spec.lua, the
  dedicated gate): inject a fake driver with a `cd` spy (`drv.cd = function(path)
  table.insert(drv.cd_calls, path) end` — NOTE: NOT `function(self, path)`; the call is
  `pcall(state.driver.cd, cwd_now)`, a plain fn call, so the first arg is `path`); ensure()
  with `server_info.cwd="/old"` (state.cwd="/old"); change to "/new"; `complete_current`;
  assert `cd_calls[1]=="/new"` + `shell._test_cwd()=="/new"`. Case B: no re-cd when cwd
  unchanged (behavioral proof of the cache update). NARROW: ONLY the complete_current cwd
  block + the `_test_cwd` seam + the 3 driver doc-comments + the 2 test cases. No
  session_cwd/ensure/request/reset change, no DAEMON_SCRIPT change (Issue 6 territory), no
  config/env/API/user-facing-doc surface change.
---

## Goal

**Feature Goal**: Wire the daemon cwd re-tracking that PRD §17.5.2 promises + the bug hunt
(plan/002…/bug-hunt-transcript.log, §h3.3 Issue 4) proved is dead code. All three shell
drivers define `M.cd(path)` (a `__PICD__\t<path>\n` frame to the daemon's stdin), and the
fish + bash daemons ALREADY honor it with a real `builtin cd` — but `M.cd` has NO caller
anywhere, so a daemon spawned at cwd `/a` never learns the user later `:cd /b`'d in nvim,
and completions stay rooted at the stale spawn cwd. Fix: in `M.complete_current` (the
per-keystroke entry), re-`cd` the daemon BEFORE the `M.request` `__PIREQ__` write whenever
a fresh `M.session_cwd()` differs from the cached `state.cwd`. (PRD §h3.3 Issue 4.)

**Deliverable** (all under the repo root):
1. **MODIFY** `lua/pi-bridge/shell.lua` — in `M.complete_current` (~line 1040), insert a cwd
   re-tracking block BETWEEN the step-(6) empty-command guard `end` and the step-(7) `-- (7)
   DELEGATE to M.request` comment. TAB indentation (matches shell.lua). ~9 inserted lines +
   a numbered-step comment (6.5). ALSO add a 3-line `_test_cwd()` test seam right after
   `_test_gen()` (~line 1113) mirroring it exactly (`return state.cwd`).
2. **MODIFY** `lua/pi-bridge/shell/fish.lua` — refresh the `M.cd` doc-comment (419-426) to
   note cd is **WIRED** (complete_current calls it on a cwd change) + **FUNCTIONAL** (the
   fish daemon honors `__PICD__` with a real `builtin cd`; the current "advisory" wording is
   stale/wrong — fish does a REAL cd).
3. **MODIFY** `lua/pi-bridge/shell/bash.lua` — refresh the `M.cd` doc-comment (466-475) to
   add the **WIRED** lead; keep the existing "REAL / functional" body.
4. **MODIFY** `lua/pi-bridge/shell/zsh.lua` — refresh the `M.cd` doc-comment (486-495) to add
   the **WIRED** lead; keep the existing "ADVISORY / documented no-op for v1" body (the
   daemon matches `__PICD__` but the inner zsh doesn't cd).
5. **MODIFY** `tests/shell_complete_current_spec.lua` — append TWO plenary `it(...)` cases
   inside the existing `describe("pi-bridge.shell complete_current", …)`: (A) cwd changed →
   `driver.cd` called with the new cwd + `state.cwd` updated + the `__PIREQ__` frame still
   written exactly once; (B) cwd unchanged → `driver.cd` NOT called (the cache guards against
   re-cd'ing every keystroke), then changed → fires exactly once, then unchanged again → no
   re-cd. Both reuse the file's existing `inject_fake_driver`/`make_fake_stdin`/`fake_bridge`/
   `buf_with` helpers (no new harness).
6. **NO CHANGE** to `M.session_cwd`, `M.ensure`, `M.request`, `M.reset`, or any other
   shell.lua function; NO change to the driver DAEMON_SCRIPTs (Issue 6 / P1.M2.T6 territory);
   NO change to the `__PICD__` frame protocol; NO config/env/API/user-facing-doc surface.

**Success Definition**:
- After a daemon is spawned at `server_info.cwd="/old"`, changing `server_info.cwd` to `"/new"`
  and typing a `!` command makes the NEXT `complete_current` call `state.driver.cd("/new")`
  BEFORE writing its `__PIREQ__` frame (proven by Case A: `drv.cd_calls[1]=="/new"` and
  `stdin.written[1]` is still the `__PIREQ__` frame, written exactly once).
- `state.cwd` is updated to `"/new"` so a subsequent keystroke at the SAME cwd does NOT
  re-cd (proven by Case B: a 2nd `complete_current` at `"/new"` leaves `#drv.cd_calls==1`).
- A nil `state.driver` (first keystroke, pre-spawn) or a `driver.cd` that throws is a silent
  no-op — completion NEVER aborts (the `pcall` + `type(...)=="function"` guard).
- zsh remains advisory (its daemon no-ops `__PICD__`) — the zsh doc-comment hedges this; no
  behavior change claimed for zsh.
- Every existing `tests/shell_complete_current_spec.lua` case + sibling specs
  (`shell_ensure_spec`, `shell_request_spec`, `shell_*_driver_*`, `completion_*`) still PASS.

## User Persona (if applicable)

**Target User**: Any `pi-bridge.nvim` user who spawns a shell-completion daemon (`!`/`!!` line)
and later changes nvim's working directory (`:cd`/`:lcd`/`:tcd`) mid-session, or whose `pi`
session cwd otherwise drifts after the daemon was spawned.

**Use Case**: User opens a prompt, types `!git c` (daemon spawns at cwd `/repo`), then does
`:cd /repo/sub` to work in a sub-directory, then types `!git c` again. Today the daemon is
still rooted at `/repo`, so path/command completions ignore the new cwd. After this fix, the
next `complete_current` re-cd's the daemon to `/repo/sub` BEFORE querying, so completions
reflect the current session cwd.

**Pain Points Addressed**: A silently-stale daemon cwd that makes shell completions disagree
with the user's actual working directory — a correctness gap (the dead `M.cd` was meant to
fix exactly this) that the standard test suite missed because `M.cd` has no caller AND no test.

## Why

- **PRD §17.5.2 "cwd tracking" + §h3.3 Issue 4**: the daemon is spawned ONCE with the session
  cwd (shell.lua:462 `opts.cwd = M.session_cwd()`, cached at 486 `state.cwd = opts.cwd`), then
  never re-synced. The `M.cd` re-cd primitive was SHIPPED in all 3 drivers but never WIRED —
  `grep -rn '\.cd('` finds only the definitions. This task closes that loop.
- **The daemon-side work is ALREADY DONE for fish + bash**: the embedded daemon scripts honor
  `__PICD__\t<path>\n` with a real `builtin cd "$path"` (fish.lua:111-115; bash.lua:187-191).
  Only zsh no-ops (zsh.lua:219 `(__PICD*) ;;`, empty body — a known v1 pty limitation). So
  wiring the single caller reaps a REAL cwd fix for the two functional drivers at zero daemon
  cost. zsh's doc-comment already hedges the limitation.
- **`complete_current` is the right entry**: it is the per-keystroke seam called by
  completion.lua's `do_shell_fetch` (the SOLE consumer; verified). Re-cd'ing here, BEFORE
  `M.request` writes `__PIREQ__`, means the daemon processes `__PICD__` first (sequential
  libuv writes to the same `state.stdin`) → the `builtin cd` takes effect for THIS
  completion's `compgen`/`complete -C`.
- **Cheap & safe**: one guarded block, mirroring the file's existing `pcall`+type-guard
  discipline (M.request pcall-wraps its writes; ensure pcall-wraps `driver.start`). No new
  state field (`state.cwd` already exists), no new function beyond a 3-line test seam, no API
  change, no protocol change.
- **Parallel-safe**: the in-flight P1.M1.T3.S1 (Issue 2) edits shell.lua `M.ensure()` + the
  in-flight P1.M2.T1S1 (Issue 3) edits completion.lua — DISJOINT functions/files from this
  task (`complete_current` ~1040 + `_test_cwd` ~1113 + the 3 driver doc-comments + the spec).
  Zero conflict either order. P1.M2.T6 (Issue 6) edits the driver DAEMON_SCRIPTs — different
  line ranges from the doc-comments I touch (~419-495).

## What

A single guarded block insertion in `complete_current` + a 3-line test seam + three doc-comment
refreshes + two plenary cases. The block reads the cwd fresh, re-cd's only on a real change,
updates the cache, and never throws.

### Success Criteria

- [ ] `M.complete_current` (shell.lua ~1040) has a cwd re-tracking block between the step-(6)
      empty-command guard `end` and the `-- (7) DELEGATE to M.request` comment, reading EXACTLY
      (modulo the numbered-step comment wording): `local cwd_now = M.session_cwd()` →
      `if cwd_now and state.cwd and cwd_now ~= state.cwd and state.driver and
      type(state.driver.cd) == "function" then pcall(state.driver.cd, cwd_now); state.cwd =
      cwd_now end`.
- [ ] The block is placed BEFORE the `M.request(line, cin, after, wrapper_cb)` call (so
      `__PICD__` is written before `__PIREQ__`).
- [ ] `pcall(state.driver.cd, cwd_now)` + the `type(state.driver.cd) == "function"` guard are
      both present (a throwing/nil `driver.cd` never aborts completion).
- [ ] `state.cwd = cwd_now` runs ONLY inside the `if` (so an unchanged/nil cwd leaves the cache
      untouched → no re-cd spam).
- [ ] Indentation is TABS (matches shell.lua; NOT 2-space like completion.lua).
- [ ] A `_test_cwd()` test seam exists right after `_test_gen()` (~line 1113), returning
      `state.cwd` (mirrors `_test_gen`).
- [ ] fish.lua `M.cd` doc-comment (419-426): notes cd is **WIRED** (complete_current calls it
      on a cwd change) + **FUNCTIONAL** (daemon honors `__PICD__` with `builtin cd`; removes
      the stale "advisory" wording that implied a no-op).
- [ ] bash.lua `M.cd` doc-comment (466-475): adds the **WIRED** lead; keeps the REAL/functional body.
- [ ] zsh.lua `M.cd` doc-comment (486-495): adds the **WIRED** lead; keeps the ADVISORY/no-op body.
- [ ] Case A in `shell_complete_current_spec.lua`: inject fake driver + cd spy; ensure() with
      `server_info.cwd="/old"` (assert `shell._test_cwd()=="/old"`); change to `"/new"`;
      `complete_current("!git ch")`; assert `#drv.cd_calls==1`, `drv.cd_calls[1]=="/new"`,
      `shell._test_cwd()=="/new"`, and `#stdin.written==1` with the frame being `__PIREQ__\t…`.
- [ ] Case B: ensure `"/srv"`; `complete_current` ×2 (cwd still `"/srv"`) → `#drv.cd_calls==0`;
      change to `"/etc"`; `complete_current` → `#drv.cd_calls==1`, `calls[1]=="/etc"`,
      `_test_cwd()=="/etc"`; `complete_current` again → `#drv.cd_calls==1` (no re-cd).
- [ ] Both cases use the file's existing `inject_fake_driver`/`make_fake_stdin`/`fake_bridge`/
      `buf_with` helpers + the `before_each`/`after_each` reset; the cd spy is `function(path)`
      (NOT `function(self, path)`); each case `nvim_buf_delete`s its buffer.
- [ ] `tests/shell_complete_current_spec.lua` ALL cases PASS (the two new + every existing case
      (1)-(13)).
- [ ] Sibling regression sweep PASS: `shell_ensure_spec`, `shell_request_spec`, the
      `shell_*_driver_*` specs, `completion_spec` (none touch complete_current's cwd block).
- [ ] ONLY `complete_current` (cwd block) + `_test_cwd` + the 3 driver doc-comments + the 2
      test cases changed. `M.session_cwd`/`M.ensure`/`M.request`/`M.reset` UNCHANGED. No
      DAEMON_SCRIPT change. No config/env/API/user-facing-doc surface.

## All Needed Context

### Context Completeness Check

_Pass test_: An agent who has never seen this repo, given this PRP (which embeds the verbatim
current `complete_current` step-(6)/(7) seam, the verbatim new block, the verbatim `_test_gen`
precedent for the seam, the exact old→new doc-comment text for all 3 drivers, the two complete
test cases, the file's exact harness idiom, and the verified plenary command), can apply 5
`edit`s + run the gate and see green — with every line number, helper name, and gotcha listed.

### Documentation & References

```yaml
# MUST READ — the fix design (verbatim block + the daemon-handler status table + the test design)
- docfile: plan/002_d23d7473c16c/bugfix/001_842ac90ede70/architecture/completion_drivers.md
  why: §"Issue 4: Daemon cwd Re-Tracking — Dead Code" gives the EXACT fix block, the daemon-side
       status (fish/bash functional, zsh no-op), the frame-ordering rationale, + the test sketch.
       This PRP transcribes + corrects it (the spy signature + the `_test_cwd` seam).
  section: "## Issue 4: Daemon cwd Re-Tracking — Dead Code"
  critical: |
    The block MUST go BEFORE M.request (so __PICD__ is written before __PIREQ__). The
    state.cwd update MUST be INSIDE the if (else it re-cd's every keystroke). pcall + the
    type-guard are mandatory (completion never aborts on a re-cd failure). zsh stays advisory.

# MUST READ — the file being edited (complete_current 1026-1046; M.session_cwd 270-294;
# state.cwd set at 486 + cleared at 342; M.request ensure-call at 841; the _test_ seams 1069-1120)
- file: lua/pi-bridge/shell.lua
  why: the insertion point (between step-(6) `end` ~1039 and `-- (7) DELEGATE` ~1040) + the
       state fields consumed (state.cwd, state.driver) + where to add _test_cwd (after _test_gen ~1113).
  pattern: "grep -nE 'function M\\.complete_current|function M\\.session_cwd|function M\\._test_gen|state\\.cwd' lua/pi-bridge/shell.lua"
  gotcha: |
    shell.lua uses TABS (verified: `sed -n '1036,1042p' lua/pi-bridge/shell.lua | cat -A` shows ^I).
    Match the edit by CONTENT (the step-(6) `if cmd == \"\"…end` + the `-- (7) DELEGATE` line),
    not line number — the in-flight P1.M1.T3.S1 edits M.ensure() (~379-504), well ABOVE the
    insertion point, so lines ~1040 are STABLE, but content-matching is robust. complete_current
    writes the __PIREQ__ frame SYNCHRONOUSLY before returning (proven by existing case 1 which
    asserts stdin.written[1] right after the call) → the cd block (which runs BEFORE M.request)
    is also synchronous → NO vim.wait needed in the tests.

# MUST READ — the test home + the exact harness the two new cases reuse verbatim
- file: tests/shell_complete_current_spec.lua
  why: defines fake_bridge(shell_path) (L41; returns get_shell_info + server_info={}), the
       make_fake_stdin() pipe (L52; captures written[]), inject_fake_driver(fake_stdin,
       driver_opts) (L91; returns drv with start that calls cb SYNCHRONOUSLY), buf_with(line,
       byte_col) (L139; virtualedit=onemore), + before_each/after_each reset (L165/L176). The
       existing cases (1)/(6)/(12) are the precedents: they `shell.ensure(function() end)` to
       spawn the fake driver, then `complete_current(buf, cb)` and assert stdin.written[1]
       IMMEDIATELY (proving synchronous frame writes).
  pattern: "drv = inject_fake_driver(stdin); drv.cd_calls={}; drv.cd=function(path) table.insert(drv.cd_calls, path) end; pi.bridge=fake_bridge('/usr/bin/fish'); pi.bridge.server_info={cwd='/old'}; shell.ensure(function() end); …; shell.complete_current(buf, function() end); assert.are.equals('/new', drv.cd_calls[1])"
  gotcha: |
    The cd spy MUST be `function(path)` (first arg = path), NOT `function(self, path)`.
    pcall(state.driver.cd, cwd_now) is a PLAIN function call (state.driver.cd(cwd_now)), NOT a
    method call (state.driver:cd(cwd_now)) — so `self` is NOT passed. With `function(self, path)`
    the spy would store self="/new" and path=nil. The real M.cd is `function M.cd(path)` (no self).
    Also: fake_bridge() hardcodes server_info={} (no cwd) — set pi.bridge.server_info={cwd=…}
    AFTER the assignment so M.session_cwd() returns the value at spawn (ensure caches it into
    state.cwd). The daemon MUST be spawned first (shell.ensure) so state.driver is non-nil — the
    cd block guards on state.driver (it's nil on the very first keystroke → no-op, correct).

# MUST READ — the 3 driver M.cd definitions + doc-comments being refreshed (fish 419-444,
# bash 466-493, zsh 486-513) + their daemon __PICD__ handlers (fish 111-115, bash 187-191, zsh 219)
- file: lua/pi-bridge/shell/fish.lua
  why: M.cd (428-444) + its doc-comment (419-426, currently MISLABELED "advisory" — fish's
       daemon does a REAL builtin cd at 114). The doc refresh notes WIRED + FUNCTIONAL.
- file: lua/pi-bridge/shell/bash.lua
  why: M.cd (477-493) + its doc-comment (466-475, already says "REAL"). The doc refresh adds
       the WIRED lead. Daemon handler at 187-191 is FUNCTIONAL (builtin cd).
- file: lua/pi-bridge/shell/zsh.lua
  why: M.cd (497-513) + its doc-comment (486-495, says "ADVISORY / no-op for v1"). The doc
       refresh adds the WIRED lead. Daemon handler at 219 `(__PICD*) ;;` is an EMPTY-NO-OP.
  gotcha: |
    Edit ONLY the doc-comment blocks (the --- lines ABOVE `function M.cd(path)`). Do NOT touch
    the M.cd function body or the DAEMON_SCRIPT (the embedded zsh/bash/fish script strings) —
    those are Issue 6 (P1.M2.T6) territory. Content-match each doc-comment by its first line
    ("--- Re-`cd` the daemon to `path` by writing a `__PICD__\\t<path>\\n` frame to its stdin.")
    which is identical across all 3 drivers — so match on the FULL block (incl. the divergent
    2nd+ lines) to keep each edit unique.

# MUST READ — test conventions (plenary runner + the nvim-stdin HARD RULE + the fake-driver idiom)
- docfile: plan/002_d23d7473c16c/bugfix/001_842ac90ede70/architecture/test_conventions.md
  why: the exact plenary runner command; the fake_bridge/fake-driver injection idiom; the
       ⛔ HARD RULE (never heredoc→nvim stdin). NOTE its "shell._test_* seams … do not add new
       ones" guidance — this task adds `_test_cwd` (mirroring `_test_gen`) because the contract
       explicitly requires asserting state.cwd and no cwd seam exists; the twin-of-_test_gen
       addition is the minimal faithful path (see research §4).
  section: "## Test Harness (plenary); ### Fake Driver Injection; ## ⛔ HARD RULE"

# MUST READ — the PRD issue (the bug contract)
- docfile: plan/002_d23d7473c16c/bugfix/001_842ac90ede70/prd_snapshot.md
  why: §h3.3 Issue 4 — "Daemon cwd re-tracking is documented (PRD §17.5.2) and shipped (all
       three drivers define M.cd) but is never wired — dead code".
  section: "### Issue 4: Daemon cwd re-tracking is documented (PRD §17.5.2) and shipped … but is never wired — dead code"

# MUST READ — the in-flight prerequisite PRPs (parallel-safety; DISJOINT functions/files)
- docfile: plan/002_d23d7473c16c/bugfix/001_842ac90ede70/P1M1T3S1/PRP.md
  why: P1.M1.T3.S1 (Issue 2, IN-FLIGHT) edits shell.lua M.ensure() + tests/shell_notices_spec.lua
       + doc/pi-bridge-shell.txt. M.ensure is ~379-504; this task edits complete_current (~1040) +
       _test_cwd (~1113) — DISJOINT functions in the same file. Zero conflict either order.
- docfile: plan/002_d23d7473c16c/bugfix/001_842ac90ede70/P1M2T1S1/PRP.md
  why: P1.M2.T1S1 (Issue 3, IN-FLIGHT) edits completion.lua + completion_spec.lua — fully
       disjoint files. No conflict.

# SUPPORTING — this task's full research (daemon-handler table, seam decision, test design)
- docfile: plan/002_d23d7473c16c/bugfix/001_842ac90ede70/P1M2T2S1/research/notes.md
  why: §1 the bug; §2 daemon-handler status (fish/bash functional, zsh no-op); §3 the fix +
       frame-ordering; §4 the _test_cwd seam decision; §5 the test design + the cd-spy signature
       gotcha; §6 the doc-comment updates; §7 parallel-safety; §8 scope guard.
```

### Current Codebase tree

```bash
$ ls -1 lua/pi-bridge/shell.lua lua/pi-bridge/shell/fish.lua lua/pi-bridge/shell/bash.lua lua/pi-bridge/shell/zsh.lua tests/shell_complete_current_spec.lua tests/minimal_init.lua
lua/pi-bridge/shell.lua                          # <- EDIT complete_current (~1040) + add _test_cwd (~1113)
lua/pi-bridge/shell/bash.lua                     # <- EDIT M.cd doc-comment (466-475) only
lua/pi-bridge/shell/fish.lua                     # <- EDIT M.cd doc-comment (419-426) only
lua/pi-bridge/shell/zsh.lua                      # <- EDIT M.cd doc-comment (486-495) only
tests/shell_complete_current_spec.lua            # <- EDIT: append 2 it() cases inside the describe
tests/minimal_init.lua                           # the plenary runner's -u init (sets rtp, etc.)
```

### Desired Codebase tree with files to be added

```bash
lua/pi-bridge/shell.lua                   # (MODIFY) cwd re-tracking block in complete_current + _test_cwd seam
lua/pi-bridge/shell/bash.lua              # (MODIFY) M.cd doc-comment — WIRED + REAL/functional
lua/pi-bridge/shell/fish.lua              # (MODIFY) M.cd doc-comment — WIRED + FUNCTIONAL (drop stale "advisory")
lua/pi-bridge/shell/zsh.lua               # (MODIFY) M.cd doc-comment — WIRED + ADVISORY/no-op (v1)
tests/shell_complete_current_spec.lua     # (MODIFY) append 2 plenary cases (A cd wired + cache; B no re-cd when unchanged)
# No new files. No DAEMON_SCRIPT change. No config/env/API/user-facing-doc change.
```

### Known Gotchas of our codebase & Library Quirks

```lua
-- CRITICAL: shell.lua uses TAB indentation (verified: sed -n '1036,1042p' | cat -A shows ^I).
--   The complete_current body is 1-TAB; an `if` block body inside it is 2-TAB. The new cwd
--   block's `local cwd_now`/`if`/`end` sit at 1-TAB (sibling to the step-(6) `if`); the if-body
--   (`pcall`/`state.cwd=`) at 2-TAB. (Contrast completion.lua which is 2-SPACE — different file.)

-- CRITICAL: insert the block BEFORE `M.request(line, cin, after, wrapper_cb)` (the step-(7)
--   delegation), AFTER the step-(6) empty-command guard `end`. The contract is explicit: cd
--   BEFORE request. Putting it after would write __PICD__ AFTER __PIREQ__ → the daemon processes
--   the request BEFORE the cd → THIS completion uses the stale cwd (defeats the purpose).

-- CRITICAL: `state.cwd = cwd_now` MUST be INSIDE the `if` (only when a re-cd actually happened).
--   Outside the `if` it would update the cache even when cwd_now was nil/unchanged → a later
--   real change wouldn't be detected (cwd_now == state.cwd → no re-cd). The cache invariant:
--   state.cwd always mirrors the last cwd the daemon was cd'd to.

-- CRITICAL: the cd spy signature is `function(path)` (first arg = path), NOT `function(self, path)`.
--   `pcall(state.driver.cd, cwd_now)` is a PLAIN fn call → state.driver.cd(cwd_now). `self` is
--   NOT passed (it's not a method call). The real M.cd is `function M.cd(path)`. With
--   `function(self, path)` the spy stores self="/new", path=nil → the assertion on calls[1]
--   would see nil. (The contract's example spy had this bug; corrected here.)

-- CRITICAL (test, daemon-must-be-spawned): the cd block guards on `state.driver`. On the very
--   FIRST complete_current state.driver is nil (no spawn yet) → the block is a no-op (correct:
--   ensure sets opts.cwd from session_cwd at spawn). To exercise the re-cd, the test MUST
--   `shell.ensure(function() end)` first (like existing cases 1/6/12) to set state.driver +
--   state.cwd, THEN change cwd, THEN complete_current.

-- CRITICAL (test, fresh read): M.session_cwd() reads `bridge.server_info.cwd` LIVE each call
--   (shell.lua:270-276). fake_bridge() hardcodes server_info={} → set `pi.bridge.server_info =
--   { cwd = "/old" }` AFTER the assignment so session_cwd returns it at spawn (ensure caches it
--   into state.cwd). Change `pi.bridge.server_info.cwd = "/new"` for the re-cd case (the SAME
--   table is read fresh on the next session_cwd call).

-- GOTCHA: complete_current writes the __PIREQ__ frame SYNCHRONOUSLY before returning (existing
--   case 1 asserts stdin.written[1] immediately). The cd block runs BEFORE M.request, so the cd
--   spy + stdin.written are populated before complete_current returns → NO vim.wait needed.

-- GOTCHA (doc-comment edits): the FIRST doc-comment line is IDENTICAL across all 3 drivers
--   ("--- Re-`cd` the daemon to `path` by writing a `__PICD__\\t<path>\\n` frame to its stdin.").
--   So match each edit on the FULL block (the divergent 2nd+ lines make each unique) — do NOT
--   try to match just the first line (it's not unique across files, though it IS unique WITHIN
--   each file; safest to include enough context).

-- GOTCHA (AGENTS.md HARD RULE): the plenary runner uses a FILE path
--   (`-c 'lua require("plenary.busted").run("tests/shell_complete_current_spec.lua")'`), NOT nvim
--   stdin. NEVER pipe a heredoc into nvim stdin (it HANGS). Write any throwaway check to a real
--   .lua file, then `:luafile` it. ALWAYS wrap nvim in `timeout`.

-- GOTCHA: do NOT name a spec-local table `pending` (shadows plenary.busted's global skip fn).
--   Use `drv`/`got`/`stdin` locals (mirrors the file's existing cases).
```

## Implementation Blueprint

### Data models and structure

No data-model change. The fix consumes EXISTING module-level state + an existing driver method:
- `state.cwd` (shell.lua, `string?`) — cached at spawn (486 `state.cwd = opts.cwd`), cleared by
  reset() (342). My fix READS it (the `cwd_now ~= state.cwd` guard) + WRITES it (the cache update).
- `state.driver` (shell.lua, `table?`) — the resolved driver module (set at 444
  `state.driver = M.pick_driver(resolved)`), cleared by reset() (341). My fix reads `.cd`.
- `M.session_cwd()` (shell.lua:270) — fresh read of `bridge.server_info.cwd` → `descriptor.cwd`.
- `state.driver.cd(path)` (fish.lua:428, bash.lua:477, zsh.lua:497) — writes `__PICD__\t<path>\n`.

The new `_test_cwd()` seam returns `state.cwd` (mirrors `_test_gen` returning `state.gen`).

### Implementation Tasks (ordered by dependencies)

```yaml
Task 1: EDIT lua/pi-bridge/shell.lua — insert the cwd re-tracking block in complete_current
  - LOCATE the step-(6) EMPTY-COMMAND GUARD + the step-(7) DELEGATE seam (content-match;
    ~lines 1037-1040). The current text is (TABS — shown as 1 leading tab):
      `	if cmd == "" or cmd:match("^%s*$") then`
      `		return cb(nil, {}, "")`
      `	end`
      `	-- (7) DELEGATE to M.request. The wrapper_cb runs in LIBUV FAST CONTEXT (M.request's`
  - INSERT, between the `end` (of step 6) and the `-- (7) DELEGATE` comment, a new numbered
    step (6.5) comment + the cwd block. The exact oldText→newText is in "Implementation
    Patterns & Key Details" below.
  - DO NOT: touch any other function (session_cwd, ensure, request, reset, _feed, _reset),
    change opts.cwd handling, or modify any other line of complete_current.
  - INDENTATION: TABS (1-TAB for the `local`/`if`/`end` + the comment; 2-TAB for the if-body).
  - VERIFY: `grep -nE 'cwd_now ~= state.cwd' lua/pi-bridge/shell.lua` → 1 hit inside
    complete_current. `grep -nE 'pcall\(state.driver.cd' lua/pi-bridge/shell.lua` → 1 hit.

Task 2: EDIT lua/pi-bridge/shell.lua — add the _test_cwd() test seam after _test_gen()
  - LOCATE `_test_gen` (~line 1107-1112). INSERT immediately after its `end` (and before the
    `_test_get_pending` doc-comment) a 3-line seam: doc-comment + `function M._test_cwd()
    return state.cwd end`. The exact oldText→newText is in "Implementation Patterns" below.
  - MIRRORS `_test_gen` EXACTLY (same doc-comment shape, same `return state.<field>` body).
  - DO NOT: touch _test_gen/_test_inflight/_test_pending_is_nil/_test_get_pending/_test_invoke_pending.

Task 3: EDIT the 3 driver doc-comments (fish.lua 419-426; bash.lua 466-475; zsh.lua 486-495)
  - REFRESH each M.cd doc-comment block (the `---` lines ABOVE `function M.cd(path)`):
      fish: drop the stale "advisory" wording; note cd is WIRED (complete_current calls it on a
            cwd change) + FUNCTIONAL (the fish daemon honors __PICD__ with a REAL builtin cd).
      bash: add the WIRED lead; keep the existing "REAL / functional" body.
      zsh:  add the WIRED lead; keep the existing "ADVISORY / documented no-op for v1" body.
  - The exact oldText→newText for each is in "Implementation Patterns" below.
  - DO NOT: touch the M.cd function bodies, the DAEMON_SCRIPT strings, or any other doc-comment.
    Content-match each block on its FULL text (the first line is identical across files).

Task 4: EDIT tests/shell_complete_current_spec.lua — append 2 plenary cases inside the describe
  - INSERT two `it(...)` blocks inside `describe("pi-bridge.shell complete_current", …)`.
    Placement is not load-bearing; group after case (12) (the no-leak case) for readability.
  - Case A (cd wired + cache updated): inject fake driver + cd spy (`drv.cd = function(path)
    table.insert(drv.cd_calls, path) end`); `pi.bridge = fake_bridge("/usr/bin/fish"); pi.bridge.
    server_info = { cwd = "/old" }`; `shell.ensure(function() end)`; assert `shell._test_cwd()
    == "/old"`; change `pi.bridge.server_info.cwd = "/new"`; `buf_with("!git ch", 7)`;
    `complete_current(buf, function() end)`; assert `#drv.cd_calls==1`, `drv.cd_calls[1]=="/new"`,
    `shell._test_cwd()=="/new"`, `#stdin.written==1` + frame is `__PIREQ__\t…`.
  - Case B (no re-cd when unchanged — behavioral cache proof): ensure `"/srv"`; complete_current
    ×2 (cwd still "/srv") → `#drv.cd_calls==0`; change to "/etc"; complete_current →
    `#drv.cd_calls==1`, `calls[1]=="/etc"`, `_test_cwd()=="/etc"`; complete_current again →
    `#drv.cd_calls==1` (no re-cd).
  - REUSE the file's existing helpers verbatim (inject_fake_driver, make_fake_stdin, fake_bridge,
    buf_with, before_each/after_each via reset()). NO new harness code. Each case nvim_buf_delete.
  - The exact case bodies are in "Implementation Patterns" below.

Task 5: VALIDATE — run the gates (Validation Loop); all must be green.
```

### Implementation Patterns & Key Details

```lua
-- === lua/pi-bridge/shell.lua — Task 1 (the SOLE behavior edit) ===
-- Apply via the edit tool. OLD (verbatim current — the step-(6)/(7) seam, TABS shown as leading ws):
	local cwd_now_PLACEHOLDER -- (no cwd block today)
	if cmd == "" or cmd:match("^%s*$") then
		return cb(nil, {}, "")
	end
	-- (7) DELEGATE to M.request. The wrapper_cb runs in LIBUV FAST CONTEXT (M.request's
-- NEW (insert the cwd block between the step-(6) `end` and `-- (7) DELEGATE`):
	if cmd == "" or cmd:match("^%s*$") then
		return cb(nil, {}, "")
	end
	-- (6.5) CWD RE-TRACKING (§17.5.2 — Issue 4): if the session cwd changed since spawn,
	--      re-cd the daemon BEFORE the __PIREQ__ frame. Sequential pipe writes guarantee the
	--      daemon processes __PICD__ BEFORE __PIREQ__ (cwd takes effect for THIS completion).
	--      pcall'd + type-guarded so a nil driver or a throwing driver.cd is a silent no-op
	--      (completion must NEVER abort on a re-cd failure). Updating state.cwd caches the new
	--      cwd so we don't re-cd every keystroke (only when it actually changes). zsh cd is
	--      ADVISORY — the daemon swallows __PICD__ (a known v1 limitation; the doc-comment hedges).
	local cwd_now = M.session_cwd()
	if cwd_now and state.cwd and cwd_now ~= state.cwd
		and state.driver and type(state.driver.cd) == "function" then
		pcall(state.driver.cd, cwd_now)
		state.cwd = cwd_now
	end
	-- (7) DELEGATE to M.request. The wrapper_cb runs in LIBUV FAST CONTEXT (M.request's
```

```lua
-- === lua/pi-bridge/shell.lua — Task 2 (the _test_cwd seam, after _test_gen) ===
-- OLD (verbatim current — the end of _test_gen + the _test_get_pending doc-comment):
function M._test_gen()
	return state.gen
end

--- TEST seam: return the current `state.pending_cb` closure (read-only). Used by the
-- NEW (insert _test_cwd between _test_gen's end and the _test_get_pending doc-comment):
function M._test_gen()
	return state.gen
end

--- TEST seam: read `state.cwd` (assert cwd re-tracking in complete_current updates the cache).
---@return string?
function M._test_cwd()
	return state.cwd
end

--- TEST seam: return the current `state.pending_cb` closure (read-only). Used by the
```

```lua
-- === fish.lua — Task 3a (doc-comment 419-426; drop stale "advisory", note WIRED + FUNCTIONAL) ===
-- OLD (verbatim current):
--- Re-`cd` the daemon to `path` by writing a `__PICD__\t<path>\n` frame to its stdin.
--- The daemon script recognizes `__PICD__` + `builtin cd`s (no response — cd is advisory).
--- Best-effort + silent: a dead/closing pipe is a noop (NOT an error — cd is advisory; the
--- next request's completions simply use the prior cwd). pcall'd + is_closing-guarded so a
--- throwing/closed stdin can't escape. Writes via `last_stdin` (cached by start(); there is
--- ONE daemon per session — shell.lua singleton state — so last_stdin is always the live one).
--- NEVER throws. Mirrors shell.lua request()'s write-cb discipline (a callback-less write
--- silently swallows EPIPE; we pass a noop cb so the write is fire-and-forget but luv-clean).
-- NEW:
--- Re-`cd` the daemon to `path` by writing a `__PICD__\t<path>\n` frame to its stdin.
--- WIRED (Issue 4): shell.lua complete_current calls this when the session cwd changed since
--- spawn (a fresh M.session_cwd() ~= state.cwd), re-cd'ing BEFORE the __PIREQ__ frame so the
--- daemon processes __PICD__ first (sequential pipe writes). FUNCTIONAL: the fish daemon honors
--- `__PICD__` with a REAL `builtin cd "$path"` (fish.lua:112 — no response; cd is best-effort,
--- NOT an advisory-noop like zsh v1). Best-effort + silent: a dead/closing pipe is a noop (NOT
--- an error — the next request's completions simply use the prior cwd). pcall'd +
--- is_closing-guarded so a throwing/closed stdin can't escape. Writes via `last_stdin` (cached
--- by start(); there is ONE daemon per session — shell.lua singleton state — so last_stdin is
--- always the live one). NEVER throws. Mirrors shell.lua request()'s write-cb discipline (a
--- callback-less write silently swallows EPIPE; we pass a noop cb so the write is
--- fire-and-forget but luv-clean).
```

```lua
-- === bash.lua — Task 3b (doc-comment 466-475; add WIRED lead, keep REAL body) ===
-- OLD (verbatim current):
--- Re-`cd` the daemon to `path` by writing a `__PICD__\t<path>\n` frame to its stdin.
--- For bash this is **REAL** (research §6 — unlike zsh v1's advisory no-op): the daemon's
--- `__PICD__` branch does `builtin cd "$path"` and subsequent path completions are relative
--- to the new cwd. A genuine quality advantage over the zsh driver for v1 (real cwd tracking).
--- Best-effort + silent: a dead/closing pipe is a noop (NOT an error — cd is best-effort;
--- the next request's completions use the prior cwd). pcall'd + is_closing-guarded so a
--- throwing/closed stdin can't escape. Writes via `last_stdin` (cached by start(); there is
--- ONE daemon per session — shell.lua singleton state — so last_stdin is always the live one).
--- NEVER throws. Mirrors shell.lua request()'s write-cb discipline (a callback-less write
--- silently swallows EPIPE; we pass a noop cb so the write is fire-and-forget but luv-clean).
-- NEW:
--- Re-`cd` the daemon to `path` by writing a `__PICD__\t<path>\n` frame to its stdin.
--- WIRED (Issue 4): shell.lua complete_current calls this when the session cwd changed since
--- spawn (a fresh M.session_cwd() ~= state.cwd), re-cd'ing BEFORE the __PIREQ__ frame so the
--- daemon processes __PICD__ first (sequential pipe writes). For bash this is **REAL** (research
--- §6 — unlike zsh v1's advisory no-op): the daemon's `__PICD__` branch does `builtin cd "$path"`
--- and subsequent path completions are relative to the new cwd. A genuine quality advantage
--- over the zsh driver for v1 (real cwd tracking). Best-effort + silent: a dead/closing pipe
--- is a noop (NOT an error — cd is best-effort; the next request's completions use the prior
--- cwd). pcall'd + is_closing-guarded so a throwing/closed stdin can't escape. Writes via
--- `last_stdin` (cached by start(); there is ONE daemon per session — shell.lua singleton
--- state — so last_stdin is always the live one). NEVER throws. Mirrors shell.lua request()'s
--- write-cb discipline (a callback-less write silently swallows EPIPE; we pass a noop cb so
--- the write is fire-and-forget but luv-clean).
```

```lua
-- === zsh.lua — Task 3c (doc-comment 486-495; add WIRED lead, keep ADVISORY body) ===
-- OLD (verbatim current):
--- Re-`cd` the daemon to `path` by writing a `__PICD__\t<path>\n` frame to its stdin.
--- For zsh v1 this is **ADVISORY / a documented no-op**: the OUTER recognizes `__PICD__`
--- but the INNER's Enter is bound to a noop widget (NEVER execute — Valodim's safety),
--- so a true inner `cd` needs a dedicated control-char widget (a documented future
--- enhancement). v1 bakes the spawn cwd into the inner (via `opts.cwd`); path completions
--- are relative to that; a mid-session cwd change re-spawns. The method EXISTS (the
--- contract requires it) + never throws, but does not change the inner's cwd.
--- Best-effort + silent: a dead/closing pipe is a noop (NOT an error). pcall'd +
--- is_closing-guarded so a throwing/closed stdin can't escape. Writes via `last_stdin`
--- (cached by start(); ONE daemon per session — shell.lua singleton state).
-- NEW:
--- Re-`cd` the daemon to `path` by writing a `__PICD__\t<path>\n` frame to its stdin.
--- WIRED (Issue 4): shell.lua complete_current calls this when the session cwd changed since
--- spawn (a fresh M.session_cwd() ~= state.cwd), re-cd'ing BEFORE the __PIREQ__ frame so the
--- daemon processes __PICD__ first (sequential pipe writes). For zsh v1 this is **ADVISORY /
--- a documented no-op**: the OUTER recognizes `__PICD__` but the INNER's Enter is bound to a
--- noop widget (NEVER execute — Valodim's safety), so a true inner `cd` needs a dedicated
--- control-char widget (a documented future enhancement). v1 bakes the spawn cwd into the
--- inner (via `opts.cwd`); path completions are relative to that; a mid-session cwd change
--- re-spawns. The method EXISTS (the contract requires it) + never throws, but does not change
--- the inner's cwd. Best-effort + silent: a dead/closing pipe is a noop (NOT an error). pcall'd
--- + is_closing-guarded so a throwing/closed stdin can't escape. Writes via `last_stdin`
--- (cached by start(); ONE daemon per session — shell.lua singleton state).
```

```lua
-- === tests/shell_complete_current_spec.lua — Task 4 (the two new cases) ===
-- Append inside `describe("pi-bridge.shell complete_current (P2.M2.T3.S3)", function() ... end)`.
-- Reuse the file's existing inject_fake_driver / make_fake_stdin / fake_bridge / buf_with /
-- before_each(reset) / after_each(reset) (NO new helpers). NOTE: cd spy is `function(path)`.

	-- (13) ISSUE-4: cwd re-tracking — complete_current re-cd's the daemon when the session cwd
	--      changed since spawn (writes __PICD__ BEFORE __PIREQ__), and updates state.cwd.
	it("ISSUE-4: complete_current re-cd's the daemon when the session cwd changes", function()
		local stdin = make_fake_stdin()
		local drv = inject_fake_driver(stdin)
		-- cd spy: pcall(state.driver.cd, path) is a PLAIN fn call → first arg is `path`, NOT self.
		drv.cd_calls = {}
		drv.cd = function(path) table.insert(drv.cd_calls, path) end
		pi.bridge = fake_bridge("/usr/bin/fish")
		pi.bridge.server_info = { cwd = "/old" } -- M.session_cwd reads this FRESH at spawn
		shell.ensure(function() end)             -- spawn fake daemon → state.driver=drv, state.cwd="/old"
		assert.are.equals("/old", shell._test_cwd(), "spawn cached state.cwd from session_cwd")
		-- change the LIVE session cwd (M.session_cwd reads server_info.cwd fresh each call)
		pi.bridge.server_info.cwd = "/new"
		local buf = buf_with("!git ch", 7)
		shell.complete_current(buf, function() end) -- cd block fires BEFORE M.request
		-- (A) driver.cd was called exactly once with the NEW cwd
		assert.are.equals(1, #drv.cd_calls, "driver.cd called exactly once")
		assert.are.equals("/new", drv.cd_calls[1], "driver.cd received the new session cwd")
		-- (B) state.cwd cache updated to the new cwd (prevents re-cd every keystroke)
		assert.are.equals("/new", shell._test_cwd(), "state.cwd cache updated to /new")
		-- (C) the __PIREQ__ frame is still written exactly once (cd wrote __PICD__ — a noop fake)
		assert.are.equals(1, #stdin.written, "exactly one __PIREQ__ frame written")
		assert.is_truthy(stdin.written[1]:find("__PIREQ__\t", 1, true), "frame is the __PIREQ__")
		vim.api.nvim_buf_delete(buf, { force = true })
	end)

	-- (14) ISSUE-4: NO re-cd when the session cwd is UNCHANGED (the state.cwd cache guards
	--      against re-cd'ing every keystroke — only when cwd actually changes). Behavioral
	--      proof of the cache update (needs NO _test_cwd seam): a 2nd keystroke at the same
	--      cwd would re-cd iff state.cwd weren't updated.
	it("ISSUE-4: complete_current does NOT re-cd when the session cwd is unchanged", function()
		local stdin = make_fake_stdin()
		local drv = inject_fake_driver(stdin)
		drv.cd_calls = {}
		drv.cd = function(path) table.insert(drv.cd_calls, path) end
		pi.bridge = fake_bridge("/usr/bin/fish")
		pi.bridge.server_info = { cwd = "/srv" }
		shell.ensure(function() end)             -- state.cwd="/srv"
		local buf = buf_with("!git", 4)
		-- 1st + 2nd keystroke: cwd_now == state.cwd ("/srv") → cd NOT called
		shell.complete_current(buf, function() end)
		assert.are.equals(0, #drv.cd_calls, "no cd on 1st keystroke (cwd unchanged since spawn)")
		shell.complete_current(buf, function() end)
		assert.are.equals(0, #drv.cd_calls, "no cd on 2nd keystroke with the same cwd")
		-- change cwd → the NEXT complete_current cd's exactly once + updates the cache
		pi.bridge.server_info.cwd = "/etc"
		shell.complete_current(buf, function() end)
		assert.are.equals(1, #drv.cd_calls, "cd fires once after the cwd change")
		assert.are.equals("/etc", drv.cd_calls[1])
		assert.are.equals("/etc", shell._test_cwd(), "cache updated; a follow-up keystroke won't re-cd")
		-- cwd still "/etc" → no re-cd (cache caught up)
		shell.complete_current(buf, function() end)
		assert.are.equals(1, #drv.cd_calls, "no re-cd after the cache caught up")
		vim.api.nvim_buf_delete(buf, { force = true })
	end)
```

```lua
-- === Why every existing case stays green ===
-- The edit is strictly ADDITIVE: one guarded block inside complete_current that fires ONLY when
-- (a) state.cwd is non-nil (post-spawn), (b) the fresh session_cwd differs from it, and (c)
-- state.driver + state.driver.cd exist. In EVERY existing complete_current case:
--   - The cwd is unchanged (fake_bridge hardcodes server_info={}, so session_cwd is nil → the
--     `cwd_now and state.cwd` guard short-circuits; or server_info.cwd was never set → state.cwd
--     is nil → short-circuit). So the block is a no-op: no cd call, no state.cwd write.
-- => the existing cases (1)-(13) see byte-identical behavior: same __PIREQ__ frame, same cb,
--    same err paths, same no-leak. The _test_cwd seam is a pure read (no side effect). The
--    doc-comment edits are comments only (no executable change). Zero behavioral regression.
```

### Integration Points

```yaml
NO new integration points. The fix reuses existing module state + an existing driver method.
  - state.cwd (shell.lua, set at 486, cleared at 342) + state.driver (set at 444, cleared at 441/341)
    — existing fields. My fix reads + writes state.cwd; reads state.driver.cd.
  - M.session_cwd() (shell.lua:270) — existing fresh read; called per complete_current now.
  - state.driver.cd(path) (fish.lua:428, bash.lua:477, zsh.lua:497) — existing driver method;
    pcall'd + type-guarded so a nil/throwing cd is a silent no-op.
  - The M.request __PIREQ__ write (shell.lua:908) is UNCHANGED — the cd runs BEFORE it.
PARALLEL TASKS (IN-FLIGHT):
  - P1.M1.T3.S1 (Issue 2): edits shell.lua M.ensure() (~379-504) + shell_notices_spec.lua +
    doc/pi-bridge-shell.txt. DISJOINT function (ensure vs complete_current) in the same file;
    the _test_cwd seam (~1113) is far below ensure. Zero conflict either order.
  - P1.M2.T1S1 (Issue 3): edits completion.lua + completion_spec.lua — fully disjoint files.
DOWNSTREAM (NOT this task):
  - Issue 6 (P1.M2.T6) edits the driver DAEMON_SCRIPTs (the empty-cmd guard) — different line
    ranges from the doc-comments I touch (~419-495); both can land. Issue 1/5 (DONE) + Issue 2
    (in-flight) are in shell.lua/health.lua — no conflict with complete_current's cwd block.
```

## Validation Loop

### Level 1: Syntax & Style (Immediate Feedback)

```bash
# Parse check (luac if available; the plenary load in L2 covers parse too). NEVER heredoc→nvim stdin.
luac -p lua/pi-bridge/shell.lua 2>/dev/null && echo "shell.lua parse OK" || echo "luac unavailable (L2 covers parse)"
for d in fish bash zsh; do luac -p lua/pi-bridge/shell/$d.lua 2>/dev/null && echo "$d.lua parse OK" || true; done

# Confirm the cwd block landed BEFORE M.request inside complete_current (content grep):
grep -nB2 -A6 'cwd_now ~= state.cwd' lua/pi-bridge/shell.lua
# Expected: the block sits between the step-(6) `if cmd == ""…end` and the `-- (7) DELEGATE` line.

# Confirm the pcall + type-guard are present (never aborts completion on a re-cd failure):
grep -nE 'pcall\(state\.driver\.cd, cwd_now\)|type\(state\.driver\.cd\) == "function"' lua/pi-bridge/shell.lua
# Expected: BOTH lines present inside complete_current.

# Confirm state.cwd is updated INSIDE the if (the cache invariant):
awk '/cwd_now ~= state\.cwd/{f=1} f&&/state\.cwd = cwd_now/{print "cache-update-inside-if OK"; f=0}' lua/pi-bridge/shell.lua
# Expected: "cache-update-inside-if OK".

# Confirm the _test_cwd seam landed after _test_gen:
grep -nA2 'function M\._test_cwd' lua/pi-bridge/shell.lua
# Expected: `function M._test_cwd()` → `return state.cwd` → `end`.

# Confirm the doc-comment refreshes landed (WIRED lead in all 3 drivers):
for d in fish bash zsh; do echo "== $d =="; grep -c 'WIRED (Issue 4)' lua/pi-bridge/shell/$d.lua; done
# Expected: 1 in each (fish, bash, zsh).

# Confirm the two new cases landed:
grep -cE 'ISSUE-4' tests/shell_complete_current_spec.lua
# Expected: >= 2 (Case A + Case B) + the comment lines.

# Confirm TAB indentation in the new block (NOT 2-space):
grep -nP '\tlocal cwd_now = M\.session_cwd\(\)' lua/pi-bridge/shell.lua
# Expected: 1 hit (the leading \t proves tab indent).
```

### Level 2: Unit Tests (the gate — the spec with the 2 new cases)

```bash
# Primary: the complete_current spec (home of the 2 new cases + all existing cases).
timeout 90 nvim --headless --clean -u tests/minimal_init.lua \
  -c 'lua require("plenary.busted").run("tests/shell_complete_current_spec.lua")'
# Expected: ALL `it` PASS, incl. (13) cd-wired + (14) no-re-cd AND every existing case
#   ((1) frame, (2) !! strip, (3) mid-word, (4) bare !, (5) whitespace, (6) cursor-on-bangs,
#   (7) err path, (8) write-fail, (9) multibyte, (10) bad args, (11) prefix, (12) no-leak,
#   surface). `fail 0`.
# NOTE: if P1.M1.T3.S1 has also landed, its shell_notices cases must ALSO pass (DISJOINT file).
```

### Level 3: Regression Sweep (siblings that consume shell.lua — must be unaffected)

```bash
# shell-layer siblings (ensure/request/teardown/feed/notices + the per-driver specs).
for spec in shell_ensure_spec shell_request_spec shell_feed_spec shell_teardown_spec \
            shell_notices_spec shell_fish_driver_spec shell_zsh_driver_spec \
            shell_bash_driver_spec shell_unknown_shell_spec; do
  timeout 90 nvim --headless --clean -u tests/minimal_init.lua \
    -c "lua require(\"plenary.busted\").run(\"tests/${spec}.lua\")" && echo "${spec}: PASS"
done
# Expected: each PASS (the edit is additive: a guarded no-op when cwd is unchanged/nil, which is
#   the case in every existing sibling — fake_bridge hardcodes server_info={} → session_cwd nil).

# completion-layer siblings (the consumer of complete_current via do_shell_fetch).
timeout 90 nvim --headless --clean -u tests/minimal_init.lua \
  -c 'lua require("plenary.busted").run("tests/completion_spec.lua")' && echo "completion_spec: PASS"
# Expected: PASS (do_shell_fetch calls complete_current; the cwd block is a no-op with the
#   completion_spec fake bridge which has no server_info.cwd).
```

### Level 4: Manual / Adversarial (the EXACT bug — stale cwd after spawn, fake-driver)

```bash
# Reproduce Issue 4 WITHOUT a real daemon: inject a fake driver with a cd spy, spawn it at
# cwd "/old", change the live cwd to "/new", call complete_current, and assert cd was called
# with "/new" + state.cwd updated. Heredoc→FILE is fine; nvim stdin is NOT (AGENTS.md HARD RULE).
cat > /tmp/issue4_check.lua <<'LUA'
local pi = require("pi-bridge")
local shell = require("pi-bridge.shell")
if pi.config == nil then pi.setup({}) end
-- fake bridge: get_shell_info controls the resolved shell; server_info.cwd is the session cwd.
pi.bridge = {
  get_shell_info = function() return { shell = "/usr/bin/fish" } end,
  server_info = { cwd = "/old" },
}
-- fake driver: start calls cb synchronously with fake pipes; cd is a spy.
local cd_calls = {}
local drv = {}
drv.start = function(opts, cb)
  cb(nil, { is_closing = function() return false end },
    { write = function() end, is_closing = function() return false end, close = function() end, read_stop = function() end },
    { read_start = function() end, is_closing = function() return false end, close = function() end })
end
drv.cd = function(path) table.insert(cd_calls, path) end
package.loaded["pi-bridge.shell.fish"] = drv
shell.reset()
shell.ensure(function() end)                 -- spawn → state.driver=drv, state.cwd="/old"
assert(shell._test_cwd() == "/old", "spawn cached cwd")
pi.bridge.server_info.cwd = "/new"           -- the live session cwd changed
local buf = vim.api.nvim_create_buf(false, true)
local win = vim.api.nvim_get_current_win()
vim.api.nvim_win_set_buf(win, buf)
vim.wo[win].virtualedit = "onemore"
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "!git ch" })
vim.api.nvim_win_set_cursor(win, { 1, 7 })
shell.complete_current(buf, function() end)  -- cd block fires BEFORE M.request
print("cd_calls=" .. vim.inspect(cd_calls) .. " state.cwd=" .. tostring(shell._test_cwd()))
assert(#cd_calls == 1 and cd_calls[1] == "/new", "BUG: driver.cd not called with /new (Issue 4)")
assert(shell._test_cwd() == "/new", "BUG: state.cwd cache not updated (Issue 4)")
vim.api.nvim_buf_delete(buf, { force = true })
print("ISSUE4_OK")
LUA
timeout 60 nvim --headless --clean -u NORC -c 'set rtp+=.' +"luafile /tmp/issue4_check.lua" +qa; echo "exit=$?"
# Expected: prints `cd_calls={ "/new" } state.cwd=/new` + ISSUE4_OK, exit=0. (With the BUG,
#   cd_calls={} and state.cwd=/old — the daemon was never re-cd'd.)
```

## Final Validation Checklist

### Technical Validation

- [ ] Level 1: `grep -B2 -A6 'cwd_now ~= state.cwd'` shows the block between step-(6) `end` and
      `-- (7) DELEGATE`; `grep 'pcall(state\.driver\.cd'` + `grep 'type(state\.driver\.cd'` both hit;
      the awk cache-update check prints OK; `_test_cwd` seam present after `_test_gen`; `WIRED (Issue 4)`
      count == 1 in each of fish/bash/zsh; `grep 'ISSUE-4'` in the spec >= 2; new block is TAB-indented.
- [ ] Level 2: `tests/shell_complete_current_spec.lua` PASS (incl. (13) + (14) + all existing).
- [ ] Level 3: the shell_* + completion regression specs all PASS.
- [ ] Level 4: `/tmp/issue4_check.lua` prints `cd_calls={ "/new" } state.cwd=/new` + ISSUE4_OK.

### Feature Validation

- [ ] After a daemon spawned at cwd "/old", changing the session cwd to "/new" + a `!` keystroke
      → `complete_current` calls `driver.cd("/new")` BEFORE writing `__PIREQ__`.
- [ ] `state.cwd` is updated to "/new" (a subsequent keystroke at "/new" does NOT re-cd).
- [ ] A nil `state.driver` (pre-spawn) or a throwing `driver.cd` is a silent no-op (pcall + guard).
- [ ] The re-cd only fires when the cwd actually CHANGES (the `cwd_now ~= state.cwd` guard).
- [ ] zsh remains advisory (daemon no-op) — doc-comment hedges; no zsh behavior claimed.

### Code Quality Validation

- [ ] The cwd block mirrors the file's `pcall` + `type(...)=="function"` discipline; TAB indent.
- [ ] `state.cwd = cwd_now` is INSIDE the `if` (cache invariant).
- [ ] The block is placed BEFORE `M.request` (frame ordering: __PICD__ then __PIREQ__).
- [ ] `_test_cwd` mirrors `_test_gen` exactly (doc-comment + `return state.<field>`).
- [ ] The 3 doc-comments accurately reflect post-wiring status (fish FUNCTIONAL, bash REAL,
      zsh ADVISORY) — fish's stale "advisory" wording is removed.
- [ ] The two test cases reuse the file's existing harness (no new helpers); each cleans up its buffer.
- [ ] Edits are the SMALLEST possible (1 block + 1 seam + 3 doc-comments + 2 cases); no refactors.

### Documentation & Deployment

- [ ] Inline comments in the new block explain WHY it's before M.request (frame ordering) + why
      state.cwd is cached (no re-cd spam) + the zsh advisory caveat.
- [ ] The 3 driver M.cd doc-comments note WIRED + the functional/advisory distinction.
- [ ] No user-facing/config/API/doc-surface change beyond the internal doc-comments (Mode A).

---

## Anti-Patterns to Avoid

- ❌ Don't put the cd block AFTER `M.request` — the daemon would process __PIREQ__ BEFORE __PICD__,
  so THIS completion uses the stale cwd (defeats the purpose). Contract: BEFORE.
- ❌ Don't move `state.cwd = cwd_now` OUTSIDE the `if` — it would cache even when cwd_now was
  nil/unchanged, hiding a later real change (the `cwd_now ~= state.cwd` guard would then be false).
- ❌ Don't drop the `pcall` + `type(state.driver.cd)=="function"` guard — a nil driver (first
  keystroke) or a throwing cd would abort completion (per-keystroke + autocmd contract).
- ❌ Don't write the cd spy as `function(self, path)` — `pcall(state.driver.cd, cwd_now)` is a
  PLAIN call (not `:cd`), so `self` isn't passed; `path` is the first arg. Use `function(path)`.
- ❌ Don't forget to spawn the daemon first (`shell.ensure`) in the test — the cd block guards on
  `state.driver` (nil pre-spawn → no-op); without ensure the spy never fires.
- ❌ Don't touch the DAEMON_SCRIPTs (Issue 6 / P1.M2.T6 territory) or the `__PICD__` protocol —
  the daemon-side handlers ALREADY work (fish/bash functional); only the caller was missing.
- ❌ Don't use 2-SPACE indent — shell.lua is TAB-indented (contrast completion.lua).
- ❌ Don't touch M.session_cwd/M.ensure/M.request/M.reset — only complete_current + the _test_cwd seam.
- ❌ Don't claim a zsh cwd fix — its daemon no-ops __PICD__ (known v1 limitation); the doc hedges.
- ❌ Don't pipe a heredoc into nvim stdin (AGENTS.md HARD RULE — it HANGS). Use the plenary runner
  (file path) or write Lua to a file then `:luafile`. Always wrap nvim in `timeout`.