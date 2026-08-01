# Research Notes — P1.M2.T2.S1 (Issue 4: wire daemon cwd re-tracking)

> Path label `P1M2T2S1` = plan_status `P1.M2.T5.S1` ("Wire cwd re-tracking in complete_current
> and update driver M.cd doc-comments"). The directory numbering and the plan_status numbering
> diverge; the TITLE + DESCRIPTION match exactly.

## 1. The bug — `M.cd` is dead code (PRD §h3.3 Issue 4)

- `M.session_cwd()` (shell.lua:270) reads `bridge.server_info.cwd` → `pi.descriptor.cwd`, FRESH
  per call. Called ONCE at spawn: `opts.cwd = M.session_cwd()` (shell.lua:462), then cached into
  `state.cwd = opts.cwd` (shell.lua:486, inside the spawn-success cb). `state.cwd = nil` in reset()
  (shell.lua:342).
- All 3 drivers define `M.cd(path)` writing `__PICD__\t<path>\n` to `last_stdin`:
  - fish.lua:428-444, bash.lua:477-493, zsh.lua:497-513.
- **`grep -rn '\.cd('`** across `lua/ ftplugin/ plugin/` returns ONLY the driver definitions —
  **NO caller**. `state.driver.cd` is never invoked anywhere. → `M.cd` is dead code.

## 2. The daemon-side `__PICD__` handlers (VERIFIED live by reading the embedded scripts)

| Driver | Handler | Behavior |
|--------|---------|----------|
| fish | fish.lua:111-115 `if string match -q '__PICD__*' … builtin cd "$p" 2>/dev/null … return` | **FUNCTIONAL** — real `builtin cd` |
| bash | bash.lua:187-191 `(__PICD__*) local p=…; builtin cd "$p" 2>/dev/null; return ;;` | **FUNCTIONAL** — real `builtin cd` |
| zsh  | zsh.lua:219 `(__PICD*) ;;` (EMPTY body) | **NO-OP** — known v1 limitation |

So wiring the call reaps a REAL cwd fix for fish + bash; zsh remains advisory (the daemon
swallows `__PICD__`). The fish doc-comment currently calls cd "advisory" — that is STALE/WRONG
(fish's daemon does a real cd); the zsh doc-comment already hedges "ADVISORY / documented no-op".

## 3. The fix — wire re-cd in `complete_current` BEFORE `M.request`

`M.complete_current(buf, cb)` (shell.lua:1026) structure (verified by full read 1026-1046):
1. guard buf
2. read line 1
3. read cursor
4. bang strip
5. compute byte triple
6. **EMPTY-COMMAND GUARD** (shell.lua:~1037-1039): `if cmd == "" or cmd:match("^%s*$") then
   return cb(nil, {}, "") end` — resolves cb DIRECTLY, does NOT spawn the daemon.
7. **DELEGATE to M.request** (shell.lua:~1040): `M.request(line, cin, after, wrapper_cb)`.

**Insertion point** (matches the contract exactly): a new step (6.5) BETWEEN the step-6
empty-cmd `end` and the step-7 `-- (7) DELEGATE` comment.

The block (contract §3, verbatim logic, reformatted to the file's multi-line `and`-chain style):
```lua
	local cwd_now = M.session_cwd()
	if cwd_now and state.cwd and cwd_now ~= state.cwd
		and state.driver and type(state.driver.cd) == "function" then
		pcall(state.driver.cd, cwd_now)
		state.cwd = cwd_now
	end
```

**Why BEFORE M.request:** `complete_current` calls `M.request` AFTER the cd block. `driver.cd`
writes `__PICD__\n` to `state.stdin`; `M.request` then writes `__PIREQ__\n` to the SAME
`state.stdin`. Sequential pipe writes → the daemon reads `__PICD__` FIRST (fish/bash `builtin cd`
takes effect for THIS completion's `compgen`/`complete -C`). Frame order is guaranteed by
sequential libuv writes to the same stream.

**Why each guard matters:**
- `cwd_now` truthy — skip if `M.session_cwd()` is nil (no bridge cwd / no descriptor cwd).
- `state.cwd` truthy — skip on the first call before spawn (state.cwd is nil until ensure()
  sets it). NOTE: complete_current→M.request→ensure spawns lazily, so on the very FIRST
  keystroke state.driver is nil → the whole block is a no-op (correct: cd at spawn already set
  the cwd via opts.cwd). The re-cd only matters on SUBSEQUENT keystrokes after the daemon is up.
- `cwd_now ~= state.cwd` — only re-cd when it actually CHANGED; updating state.cwd afterward
  prevents re-cd'ing EVERY keystroke (the cache invariant).
- `state.driver` + `type(state.driver.cd)=="function"` — defensive (a nil driver or a driver
  without a `cd` method is a silent no-op).
- `pcall(state.driver.cd, cwd_now)` — a throwing `driver.cd` MUST NEVER abort completion
  (per-keystroke + autocmd contract). Mirrors the file's discipline (M.request pcall-wraps writes).

## 4. The `_test_cwd()` seam decision

`state.cwd` is module-local. Existing `_test_*` seams: `_test_gen` (returns state.gen),
`_test_inflight`, `_test_pending_is_nil`, `_test_get_pending`, `_test_invoke_pending`. **NO seam
for cwd.** The contract (§4) requires asserting `state.cwd == "/new"`.

**Decision: add a minimal `_test_cwd()` seam mirroring `_test_gen()` (3 lines, returns
`state.cwd`).** Rationale: (a) the contract explicitly requires the assertion; (b) `_test_gen` is
the pristine precedent (same shape: read a module-local state field); (c) it is internal,
`_test_`-prefixed, and minimal — in the spirit of the existing seam pattern. test_conventions.md's
"do not add new [seams]" note yields to the contract's explicit assertion requirement + the exact
`_test_gen` precedent. Defense-in-depth: Case B (no-re-cd when unchanged) ALSO proves the
cache-update behaviorally WITHOUT the seam (a 2nd keystroke at the same cwd would re-cd iff
state.cwd weren't updated).

## 5. Test design — home: `tests/shell_complete_current_spec.lua`

This spec is the dedicated complete_current gate (P2.M2.T3.S3) and is the NATURAL home — it
already has the exact harness:
- `fake_bridge(shell_path)` → returns `{ get_shell_info=…, server_info={} }`. For cwd tests, set
  `pi.bridge.server_info = { cwd = "/old" }` AFTER assignment (or extend the helper; setting
  directly is non-invasive).
- `inject_fake_driver(fake_stdin, driver_opts)` → returns `drv` with `start` (calls cb
  SYNCHRONOUSLY). Add the cd spy to the RETURNED `drv`: `drv.cd_calls={}; drv.cd=function(path)
  table.insert(drv.cd_calls, path) end`.
- `make_fake_stdin()` → fake pipe capturing `written[]` frames (so we can assert __PIREQ__ ordering).
- `buf_with(line_text, byte_col)` → buffer + virtualedit=onemore cursor.
- before_each/after_each reset pi.bridge/descriptor/SHELL + purge `package.loaded["pi-bridge.shell.fish"]`
  + `shell.reset()`.

**CRITICAL cd-spy signature gotcha:** the contract's example spy `cd = function(self, path) …` is
WRONG. `pcall(state.driver.cd, cwd_now)` calls `state.driver.cd(cwd_now)` (NOT `:cd`), so the
FIRST arg is `path`, not `self`. The real `M.cd` signature is `function M.cd(path)` (no self).
The spy MUST be `function(path) …` — with `(self, path)` the spy would store `self="/new"` and
`path=nil`. Flagged in the PRP.

**Timing (verified against existing cases 1/6/12):** `complete_current` writes the __PIREQ__ frame
SYNCHRONOUSLY before returning (existing case 1 asserts `stdin.written[1]` immediately after the
call). The cd block runs BEFORE M.request, so the cd spy is populated before complete_current
returns. → NO `vim.wait` needed; assertions run right after the call.

**Daemon-must-be-spawned first:** the cd block guards on `state.driver`. On the first keystroke
state.driver is nil → no-op (spawn via ensure sets opts.cwd, already correct). To exercise the
re-cd, the test calls `shell.ensure(function() end)` first (like existing cases) to set
state.driver + state.cwd, THEN changes cwd, THEN calls complete_current.

### Case A — cd wired + state.cwd updated
1. inject fake driver; add cd spy.
2. `pi.bridge = fake_bridge("/usr/bin/fish"); pi.bridge.server_info = { cwd = "/old" }`.
3. `shell.ensure(function() end)` → state.driver=drv, state.cwd="/old".
4. assert `shell._test_cwd()=="/old"` (spawn cached it).
5. `pi.bridge.server_info.cwd = "/new"` (live change — session_cwd reads it fresh).
6. `buf_with("!git ch", 7)`; `complete_current(buf, noop_cb)`.
7. assert `#drv.cd_calls==1`, `drv.cd_calls[1]=="/new"`, `shell._test_cwd()=="/new"`,
   `#stdin.written==1` + it's the __PIREQ__ frame (cd wrote __PICD__ — a noop fake write here).

### Case B — no re-cd when cwd unchanged (behavioral proof of the cache update)
1. same setup; `server_info.cwd="/srv"`; ensure → state.cwd="/srv".
2. complete_current ×2 (cwd still "/srv") → `#drv.cd_calls==0` both times.
3. change to "/etc"; complete_current → `#drv.cd_calls==1`, `calls[1]=="/etc"`,
   `_test_cwd()=="/etc"`.
4. complete_current again (cwd still "/etc") → `#drv.cd_calls==1` (no re-cd — cache caught up).

## 6. Doc-comment updates (Mode A — all 3 drivers, M.cd only)

**fish.lua (419-426):** current doc says "cd is advisory" — STALE (fish daemon does a REAL
`builtin cd`, fish.lua:114). Update to: cd is WIRED (complete_current calls it on cwd change) +
FUNCTIONAL (daemon honors __PICD__ with builtin cd; best-effort, NOT advisory-noop like zsh).

**bash.lua (466-475):** current doc already says "this is REAL". Add the WIRED lead (complete_current
calls it on cwd change) + keep the REAL/functional body.

**zsh.lua (486-495):** current doc says "ADVISORY / documented no-op for v1". Add the WIRED lead
(complete_current calls it on cwd change) + keep the ADVISORY/no-op body (daemon matches __PICD__
but the inner zsh doesn't cd; known v1 limitation).

No user-facing/config/API/doc-surface change (internal). NOT touching `doc/pi-bridge-shell.txt`
(that's Issue 2 / P1.M1.T3.S1 territory, IN-FLIGHT).

## 7. Parallel-safety analysis

- **P1.M1.T3.S1 (Issue 2 — IN-FLIGHT):** edits shell.lua `M.ensure()` + tests/shell_notices_spec.lua
  + doc/pi-bridge-shell.txt. DISJOINT from this task: I edit `complete_current` (~line 1037-1040)
  + add `_test_cwd` (~line 1113, near the other _test_ seams). ensure() is ~line 379-504. No
  overlap. Both can merge cleanly either order (different functions in the same file).
- **P1.M2.T1S1 (Issue 3 — IN-FLIGHT, the prev PRP):** edits completion.lua + completion_spec.lua.
  Fully disjoint files. No conflict.
- **P1.M2.T6 (Issue 6 — planned):** edits the driver DAEMON_SCRIPTs (the __PIREQ__ empty-cmd
  guard). I edit only the M.cd DOC-COMMENTS in those same driver files. Different line ranges
  (doc-comments ~419-495 vs DAEMON_SCRIPT ~100-230). Both can land; content-match the edits and
  there's no overlap.

## 8. Scope guard (what NOT to do)

- Do NOT touch M.session_cwd, M.ensure, M.request, M.reset, or any other shell.lua function.
- Do NOT touch the driver DAEMON_SCRIPTs (Issue 6 territory).
- Do NOT change the cd frame protocol (`__PICD__\t<path>\n`) — it already works for fish/bash.
- Do NOT add a cancel wire to shell (out of scope; the gen-guard handles supersession).
- Do NOT add user-facing config/env/doc surface.