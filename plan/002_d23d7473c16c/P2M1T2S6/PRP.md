# PRP — P2.M1.T2.S6: `teardown()` — `uv.process_kill` SIGKILL, close pipes, reset state

> **Plan mapping:** task `P2.M1.T2.S6` ("`teardown()` — uv.process_kill SIGKILL, close pipes, reset state").
> Sixth + final subtask of **P2.M1.T2** ("shell.lua daemon manager + fish spike") within the **Shell Completion for
> !/!! Bash Mode** epic (PRD §17). This is the **TEARDOWN layer** of `shell.lua`: it ADDS `M.teardown()` — kill the
> daemon (`uv.process_kill` SIGKILL), close the stdin/stdout/**proc** handles, finalize the in-flight request
> (soft-degrade), then `M.reset()`. IDEMPOTENT (safe to call twice — VimLeavePre **and** ExitPre both fire it).
> Called by ftplugin VimLeavePre/ExitPre (**P2.M3.T6.S3**) + S5's parse-failure threshold (§17.12). Plus a shared
> `close_handles()` local helper + the S3-anticipated extension of `M._reset()` to close the pipes on EOF.
>
> **Critical scope fact:** S6 is the ACTIVE-kill counterpart of S3's `_reset` (the EOF path). teardown owns the
> "the daemon is still alive (or wedged) and we must end it" path: SIGKILL + close every handle S3 stored
> (proc/stdin/stdout) + deliver the in-flight request's `cb` (soft-degrade) + full `reset()`. It does NOT spawn
> (S3 `ensure`), send (S4 `request`), parse (S5 `_feed`), notify (P2.M2.T3.S4), or route (P2.M2.T3). teardown is the
> LAST line of the daemon lifecycle — it must NEVER throw (it runs from `VimLeavePre` + S5's luv fast context) and
> MUST be idempotent.
>
> **Three LIVE-VERIFIED correctness facts (this session's `/tmp/teardown_probe.lua` + `/tmp/leak_probe.lua`):**
> 1. **`uv.process_kill(proc, "sigkill")` does NOT close the proc handle** — `proc:is_closing()` stays `false` even
>    AFTER `on_exit` fires. **Production teardown MUST call `proc:close()`** or the `uv_process_t` leaks for the
>    session. The fish spike omits this (acceptable — nvim exits); S6 fixes it.
> 2. **Double-`close()` throws "handle 0x.. is already closing"** → every close MUST be `is_closing()`-guarded +
>    `pcall`'d (bridge.lua GOTCHA 2).
> 3. **`vim.uv.loop()` / `gc_collect()` / `uv.walk` are UNAVAILABLE** in this luv build → the §17.15 leak assertion is
>    `is_closing()` on the created handles, NOT a loop walk/gc.
>
> **Sibling context (running in PARALLEL with S5):** S5 implements `_feed` + the §17.12 parse-failure counter, and
> forward-GUARDS `M.teardown()` on the threshold (`if type(M.teardown)=="function" then pcall(M.teardown) end`) +
> re-asserts `state.failed=true` after. **S6 treats S2/S3/S4/S5 as CONTRACTS** — S6 ADDS `M.teardown()` + the
> `close_handles()` local + extends S3's `_reset()` (the EOF pipe-close S3's [Mode A] header explicitly assigned to
> S6). S6 calls `cancel_req_timer()` (S4) + `M.reset()` (S2) + invokes `state.pending_cb` (S4) — it does NOT rewrite
> any of them.

---

## Goal

**Feature Goal**: Implement `M.teardown()` in `lua/pi-bridge/shell.lua` — the §17.5.2 / §17.12 daemon teardown layer.
On call: (1) `cancel_req_timer()` (stop the per-request timer from firing mid-teardown — S4's forward contract); (2)
finalize the in-flight request by invoking `state.pending_cb({}, "")` (soft-degrade empty result → the user
`cb(nil, {}, "")`; pcall'd + `type`-guarded so a throwing/absent cb can't escape); (3) `close_handles()` — a NEW
shared local that `read_stop`s + `close`s stdout, `process_kill("sigkill")`s + `close`s the proc handle (the leak the
fish spike omits — LIVE-VERIFIED F3), and `close`s stdin, ALL `is_closing()`-guarded + `pcall`'d (double-close throws
— F5); (4) `M.reset()` (full clean slate). IDEMPOTENT: a 2nd call sees `state.proc/stdin/stdout == nil` (reset nil'd
them) → every `if state.X` guard skips → all no-ops. NEVER throws (every luv call pcall'd; pending_cb pcall'd; plain
state writes; NO `vim.api.*`). Runs from libuv FAST context (S5's `_feed` caller) AND the nvim main loop (VimLeavePre/
ExitPre). Also: extract `close_handles()` as a module-local so S3's `M._reset()` (the EOF path) calls it too — closing
the stdin/stdout/proc handles that S3's stub left open on a mid-session daemon crash (the leak S3's header deferred to
S6; ZERO risk to S3's tests — the fake pipes absorb the calls).

**Deliverable** (ONE source file EDITED + 2 new test files — nothing else touched):
- **`lua/pi-bridge/shell.lua`** — THREE additive edits: (a) **ADD `local function close_handles()`** (the shared,
  idempotent kill+read_stop+close×N+close-proc routine) near `cancel_req_timer` (before `M.teardown`); (b) **ADD
  `function M.teardown()`** (~12-18 lines) after S4's `M.request` (before the TEST SEAMS block / `return M`);
  (c) **EXTEND S3's `M._reset()`** — prepend `close_handles()` as its FIRST line (S3's existing `state.failed=true` +
  nil-proc/pipes/driver/rx_buf body is UNCHANGED). Zero edits to S2's `state`/`reset`/resolution helpers, S3's
  `ensure`/read_start wiring, S4's `request`/`pending_cb`/`req_timer`/`cancel_req_timer`, S5's `_feed`/`parse_failures`,
  the `[Mode A]` header. Zero `vim.uv.spawn`; zero `vim.notify`/`notify.once`; zero `vim.schedule`; zero `vim.api.*`.
- **`tests/shell_teardown_smoke.lua`** — plenary-FREE smoke (mirror `tests/shell_ensure_smoke.lua` + the spike's
  run command): exercises the teardown matrix (kill+close+reset; idempotent double/triple-call; pending_cb
  soft-degrade; never-throws on nil state / already-closed handles; cancel_req_timer called; `_reset` closes handles;
  REAL fish integration gated on `fish` → assert `proc/stdin/stdout:is_closing()` + on_exit sig=9). Prints
  `SMOKE_PASS`; exit 0.
- **`tests/shell_teardown_spec.lua`** — plenary/busted spec (mirror `tests/shell_ensure_spec.lua`): the same matrix
  as focused `it(...)` cases with field-by-field asserts + before/after_each save/restore.

**Success Definition**:
- `require("pi-bridge.shell").teardown` is a function. After a spawned daemon (fake-driver injection): teardown calls
  `cancel_req_timer()`, invokes `state.pending_cb({}, "")` (the in-flight cb fires with `cb(nil, {}, "")`), calls
  `close_handles()` (read_stop + close on stdout; process_kill("sigkill") + close on proc; close on stdin — each
  exactly once, each `is_closing`-guarded), then `M.reset()` (state.proc/stdin/stdout/rx_buf/gen/inflight/driver/
  pending_cb/failed/shell/cwd/parse_failures all cleared).
- **Idempotent:** a 2nd + 3rd `teardown()` call are no-ops — no throw, no double-close error, no re-deliver (the
  `if state.pending_cb` guard + `if not h:is_closing()` guards + nil state refs). The VimLeavePre→ExitPre double-fire
  is safe.
- **Never throws:** `teardown()` on an un-spawned daemon (state all-nil) is a no-op (no throw). teardown with handles
  already `is_closing()==true` (e.g. called after `_reset`'s EOF) is a no-op on those handles. teardown with a
  throwing consumer `cb` is swallowed by the `pcall(state.pending_cb, ...)`.
- **The proc handle leak is fixed:** `close_handles()` calls `proc:close()` after `process_kill` (LIVE-VERIFIED F3:
  process_kill alone leaks the `uv_process_t`). The fish spike omits this; S6 does not.
- **`_reset` (EOF) now closes handles:** after EOF (`M._reset()`), the stdin/stdout/proc handles are closed (the leak
  S3 deferred to S6). S3's existing assertions (`failed=true`, nil proc, "does NOT call reset") still hold
  (`close_handles()` touches neither `failed` nor `reset`).
- **Real-fish integration (gated on `fish`):** spawn fish via the spike pattern → `teardown()` → `vim.wait` for
  on_exit (sig=9) → `assert(proc:is_closing() and stdin:is_closing() and stdout:is_closing())` (the robust leak
  assertion — §17.15's `loop:gc_collect()` is UNAVAILABLE, F9).
- `shell_teardown_smoke` prints `SMOKE_PASS` (exit 0); `shell_teardown_spec` green (0 fail, 0 error).
- `shell_spec` (S2), `shell_ensure_*` (S3), `shell_request_*` (S4, if landed), `shell_feed_*` (S5, if landed),
  `completion_spec`, `bridge_*_spec`, `init_spec` stay green (S6 is additive + the `_reset` prepend is fake-absorbed).
- NO file under `extension/`, `doc/`, `ftplugin/`, `plugin/`, `completion.lua`, `bridge.lua`, `init.lua`, `notify.lua`,
  `jsonlreader.lua`, or `README.md` is modified. NO `shell/*.lua` driver created. NO real subprocess in the UNIT tests
  (only the gated fish smoke spawns one). NO `vim.uv.spawn` / `notify.once` / `vim.schedule` / `vim.api.` CALL in S6's code.

## User Persona (if applicable)

**Target User**: the implementer of **P2.M3.T6.S3** (ftplugin VimLeavePre/ExitPre teardown). That task adds
`autocmd VimLeavePre,ExitPre <buffer> lua require("pi-bridge.shell").teardown()` — it calls `M.teardown()` and RELIES
on S6's idempotency guarantee (both autocmds fire on exit → teardown called twice → must be safe). Secondary
consumers: **S5** (`_feed`'s parse-failure threshold forward-GUARDS teardown + re-asserts `failed`); **P2.M2.T3.S3**
(`complete_current` — its `request()` cb is the `pending_cb` teardown finalizes with the soft-degrade empty result);
**:checkhealth** (P2.M3.T6.S2 — reads `state.failed`).

**Use Case**: (a) **VimLeavePre/ExitPre** — the editor is closing; teardown SIGKILLs the persistent completion daemon
(spawned once on first `!` activation by S3's `ensure`), closes its pipes so nvim exits cleanly with no lingering
child + no leaked `uv_handle_t`s, and resets state. (b) **S5's parse-failure threshold** — after N (default 5)
consecutive garbage daemon responses (a fragile zsh capture widget, §17.6.2), S5 marks the daemon broken + calls
teardown to kill it + free its handles; S5 then re-asserts `failed=true` so `ensure()` won't re-spawn a known-broken
daemon (§17.12 "no auto-respawn in v1"). (c) **EOF on the daemon pipe** (shell crashed mid-session, §17.12) — S3's
`_reset` runs; S6's extension makes it ALSO close the handles (the leak fix).

**Pain Points Addressed**: without S6, (1) the daemon is never killed on editor exit → an orphaned `fish`/`zsh`/
`bash` child lingers (a real resource leak, especially across many editor open/close cycles); (2) the proc + pipe
handles are never `:close()`d → `uv_handle_t` leaks (libuv owns the C structs; not GC'd until closed — the same
leak class bridge.lua GOTCHA 2 + completion.lua's `cancel_timer` fix address); (3) S5's parse-failure threshold has
no teardown to call (it forward-guards a non-existent function → the broken daemon lingers, handles open); (4) the
in-flight request on the parse-failure path is left dangling (its `cb` never fires → the menu could wedge). teardown
fixes all four.

## Why

- **It is the explicit §17.16 step-22 teardown half.** PRD §17.16 Phase 6 step 22: *"`shell.lua` daemon manager:
  resolution, spawn/**teardown**, framed protocol, gen-guard supersession, item normalization."* S2 = resolution+state;
  S3 = spawn; S4 = request/send; S5 = feed/parse; **S6 = teardown (the lifecycle closer)**. The §17.5.2 skeleton's
  `teardown()/on_exit()` comment is verbatim the S6 spec: "kill proc (uv.process_kill SIGKILL), close pipes, reset
  state." §17.12 names the two callers: EOF ("M._reset(), mark unhealthy") + parse-failure threshold ("daemon is killed
  and marked unhealthy").
- **The proc-handle leak is a REAL, verified defect in the reference spike.** LIVE-VERIFIED (F2/F3): `process_kill`
  does NOT close the `uv_process_t`; `is_closing()` stays `false` even after `on_exit`. The fish spike (`tests/shell_fish_spike.lua`
  L131-148) kills + closes the pipes but NOT the proc handle — it leaks (acceptable in a one-shot spike because nvim
  exits immediately). Production teardown, called across many editor sessions, MUST `proc:close()` or the handle leaks
  every session. S6 fixes this. (research §3.)
- **Idempotency is a hard requirement, not a nicety.** VimLeavePre AND ExitPre BOTH fire on exit (P2.M3.T6.S3 wires
  both). teardown MUST tolerate the double-call: the 2nd sees `state.proc==nil` (reset nil'd it) → skips; the
  `is_closing()` guard covers the narrow window between kill and reset. bridge.lua's `M.close()` solves the same
  problem with a shadow `state.closed` flag (GOTCHA 2); teardown needs no shadow flag (it nils the state refs).
- **The `pending_cb` conflict is a genuine cross-task contract resolution.** The item description says
  `state.pending_cb("teardown", {}, "")`, but S4's `pending_cb` signature is `(items, prefix)` — passing
  `("teardown",...)` makes `items="teardown"` (a string — type bug). S4 is a parallel contract S6 MUST NOT modify.
  S6 resolves this by calling `pending_cb({}, "")` (soft-degrade empty → user `cb(nil, {}, "")`, identical to S4's
  timeout path). This is the ONLY resolution that doesn't modify S4. §17.12 does not require distinguishing teardown
  from degrade. (research D-conflict.)
- **The `_reset` extension is explicitly assigned to S6 by S3.** S3's [Mode A] header: *"S6's teardown() will
  REPLACE/EXTEND this: prepend uv.process_kill + pipe:read_stop + pipe:close×3 THEN clear state (on EOF the proc is
  already dead, so kill is moot; **pipe-close matters for real handles — S6 owns it**)."* Without it, a daemon crash
  mid-session (§17.12 EOF) leaves the stdin/stdout/proc handles open for the rest of the session. The shared
  `close_handles()` local makes this a 1-line edit to `_reset` with ZERO risk to S3's tests (the fake pipes absorb
  read_stop/close). (research D7.)
- **"Never blocks, never throws" is a luv-callback + VimLeave safety requirement.** teardown runs from S5's `_feed`
  (the `stdout:read_start` luv callback — FAST context) AND from VimLeavePre (the nvim main loop). A throw would
  either escape the luv callback (spurious error) or, worse, wedge nvim's exit sequence. teardown pcalls EVERY luv
  call + the pending_cb invocation + guards every handle → it cannot throw on ANY input/state.

## What

**User-visible behavior**: none at runtime (no caller wires `shell.teardown()` into the plugin yet — the VimLeavePre
caller is P2.M3.T6.S3; the parse-failure caller is S5). The observable artifact is the module's `teardown` behavior +
the test verdicts:

```bash
$ timeout 60 nvim --headless --clean -u NORC -c 'set rtp+=.' +"luafile tests/shell_teardown_smoke.lua" +qa
SMOKE_PASS
$ echo "exit=$?"
exit=0
```

**Technical requirements** (all in `lua/pi-bridge/shell.lua` unless noted):
- **`local function close_handles()`** (NEW module-local, declared near `cancel_req_timer`, before `M.teardown`): the
  shared, idempotent, never-throws kill+close routine. (1) `if state.stdout and not state.stdout:is_closing() then
  pcall(read_stop) ; pcall(close) end` (read_stop THEN close — completion.lua `cancel_timer` order; stops the read cb
  re-entering `_feed`/`_reset` mid-teardown). (2) `if state.proc and not state.proc:is_closing() then
  pcall(uv.process_kill, state.proc, "sigkill") ; pcall(function() state.proc:close() end) end` (kill THEN close — F3:
  process_kill does NOT close the proc handle; the spike omits `proc:close()` and leaks it). (3) `if state.stdin and
  not state.stdin:is_closing() then pcall(function() state.stdin:close() end) end`. Every luv call `pcall`'d + every
  handle `is_closing()`-guarded (F5: double-close throws "already closing"). NO `vim.api.*`. NO notify.
- **`function M.teardown()`** (NEW, after S4's `M.request`, before the TEST SEAMS block): (1) `cancel_req_timer()`
  (S4's forward contract — stop a timer fire racing teardown; idempotent); (2) `if type(state.pending_cb)=="function"
  then pcall(state.pending_cb, {}, "") end` (finalize the in-flight request → user `cb(nil, {}, "")` soft-degrade;
  pcall'd so a throwing cb can't escape; `type`-guarded; BEFORE reset() since reset() nils pending_cb — D-conflict);
  (3) `close_handles()` (the kill+close); (4) `M.reset()` (full clean slate). Expand the JSDoc to document: the
  §17.5.2/§17.12 teardown contract; the idempotency (nil-guard + is_closing-guard); the callers (VimLeavePre/ExitPre
  P2.M3.T6.S3 + S5's parse-failure threshold); the pending_cb soft-degrade resolution (vs the item's literal
  `("teardown",...)` — D-conflict); the proc:close() leak fix (F3); the never-throws + luv-fast-context safety; the
  forward contracts (S5 re-asserts failed; the driver owns stderr; the consumer schedules its cb).
- **`M._reset()`** (EXTEND — S3's function; prepend `close_handles()` as the FIRST line): S3's existing body
  (`state.failed = true; state.proc=nil; ...; state.rx_buf=""`) is UNCHANGED. `_reset` does NOT call `reset()`
  (S3 contract — leaves `failed=true`, a crash is not a clean exit). `_reset` now ALSO closes the real handles (the
  EOF pipe leak S3 deferred to S6). On EOF the proc is already dead (libuv delivered `data==nil`) so `process_kill` is
  moot-but-harmless (pcall); the pipe-close is the real fix.
- **NEVER throws; NO `vim.api.*`; NO `vim.schedule`; NO `notify.once`.** teardown is synchronous lifecycle cleanup.

### Success Criteria

- [ ] `lua/pi-bridge/shell.lua` exposes `M.teardown` as a function; `close_handles` is a module-local; `M._reset`'s
      first line is `close_handles()`.
- [ ] After a spawned daemon (fake-driver), teardown: calls `cancel_req_timer()`; invokes `state.pending_cb({}, "")`
      (the in-flight user cb fires `cb(nil, {}, "")`); calls read_stop+close on stdout, process_kill("sigkill")+close
      on proc, close on stdin (each exactly once); then `M.reset()` (state fully cleared).
- [ ] teardown is IDEMPOTENT: a 2nd + 3rd call are no-ops (no throw, no double-close error, no re-deliver). The
      VimLeavePre→ExitPre double-fire is safe.
- [ ] teardown NEVER throws: on an un-spawned daemon (state all-nil); with handles already `is_closing()` (post-`_reset`);
      with a throwing consumer `cb` (pcall'd).
- [ ] The proc handle leak is fixed: `close_handles()` calls `proc:close()` after `process_kill` (F3).
- [ ] `_reset` (EOF) now closes handles: after EOF, stdin/stdout/proc are closed. S3's assertions (`failed=true`, nil
      proc, "does NOT call reset") still hold.
- [ ] `cancel_req_timer()` is called FIRST (before kill/close) — the per-request timer is stopped before teardown.
- [ ] pending_cb is invoked as `({}, "")` (NOT `("teardown", {}, "")`) — respects S4's `(items, prefix)` signature
      (D-conflict); pcall'd + type-guarded.
- [ ] Real-fish integration (gated): spawn fish → teardown → on_exit sig=9 → `proc/stdin/stdout:is_closing()` all true.
- [ ] `shell_teardown_smoke` prints `SMOKE_PASS` (exit 0); `shell_teardown_spec` green (0 fail, 0 error).
- [ ] `shell_spec` (S2), `shell_ensure_*` (S3), `shell_request_*` (S4), `shell_feed_*` (S5), `completion_spec`,
      `bridge_*_spec`, `init_spec` stay green.
- [ ] NO edit to `extension/*`, `doc/*`, `ftplugin/*`, `plugin/*`, `completion.lua`, `bridge.lua`, `init.lua`,
      `notify.lua`, `jsonlreader.lua`, `README.md`. NO `shell/*.lua` created. NO `vim.uv.spawn` / `notify.once` /
      `vim.schedule(` / `vim.api.` CALL in S6's code.

## All Needed Context

### Context Completeness Check

_Passes "No Prior Knowledge":_ an implementer who has never seen this repo gets (a) the verbatim §17.5.2/§17.12 spec
(the EXACT teardown contract: "kill proc (uv.process_kill SIGKILL), close pipes, reset state"; the two callers — EOF +
parse-failure threshold; the idempotency requirement), (b) the EXACT S2 `state`/`reset` S6 reads/calls + the EXACT S3
`ensure` read_start wiring + `_reset` stub S6 extends + the EXACT S4 `pending_cb`/`req_timer`/`cancel_req_timer`
contracts S6 invokes + the EXACT S5 forward-guard+re-assert (all four treated as contracts), (c) the canonical in-repo
references for EVERY non-obvious mechanic — the fish spike (the REAL luv teardown idiom — with the proc-leak S6 fixes),
bridge.lua `M.close()` + GOTCHA 2 (THE idempotent-close pattern — shadow flag + is_closing + pcall), completion.lua
`cancel_timer` L350-360 (the stop-then-close leak fix), the sibling `shell_ensure_spec` (the fake-driver/fake-pipe
test recipe), (d) the LIVE-VERIFIED facts (`/tmp/teardown_probe.lua` + `/tmp/leak_probe.lua` — process_kill doesn't
close the handle; double-close throws; read_stop-then-close; no loop/gc_collect API; "sigkill" works; on_exit sig=9),
(e) the two test files to mirror (`shell_ensure_smoke/spec` + the spike's run command), (f) the locked design
decisions (proc:close() required; read_stop-then-close order; is_closing+pcall idempotency; pending_cb soft-degrade
resolution; cancel_req_timer first; full reset(); the `_reset` extension; never-throws; the shared helper), and (g)
the scope fence (NOT: spawn, send, parse, notify, route, drivers, the VimLeavePre caller). The genuine judgment calls
(the item's `pending_cb("teardown",...)` vs S4's signature; the item's close-then-read_stop order; the missing
proc:close(); the missing is_closing guards; the `_reset` extension scope; the unavailable loop API for leak tests)
are decided in Design Decisions + Anti-Patterns.

### Documentation & References

```yaml
# MUST READ — the spec (reproduced from the task's selected PRD §17 content)
- docfile: PRD.md
  why: "§17.5.2 gives the shell.lua teardown skeleton comment ('teardown()/on_exit(): kill proc (uv.process_kill SIGKILL), close pipes, reset state'). §17.12 gives the two callers + the failure model ('EOF on the daemon pipe → M._reset(), mark unhealthy'; 'after N consecutive parse failures the daemon is killed and marked unhealthy'). §17.16 step 22 names spawn/teardown as one Phase-6 step. §17.15 shell_daemon_spec gives the leak-assertion INTENT ('teardown — no leaked uv handles via vim.uv.loop():gc_collect() / handle-count assert') — NOTE F9: loop:gc_collect is UNAVAILABLE; use is_closing() on the created handles."
  section: "h3.34 (§17.5 + §17.5.2 skeleton), h4.4 (§17.5.2 teardown comment), h3.41 (§17.12 failure modes), h3.44 (§17.15 testing), h3.45 (§17.16 phasing)"
  critical: "§17.15's 'vim.uv.loop():gc_collect() / handle-count assert' is NOT available in this luv build (F9). The robust leak assertion is `assert(proc:is_closing() and stdin:is_closing() and stdout:is_closing())` (F10). The item description's `state.pending_cb('teardown', {}, '')` conflicts with S4's `pending_cb(items, prefix)` signature (D-conflict); the item's `close`-then-`read_stop` order is reversed (D2); the item omits `proc:close()` which is REQUIRED (F3)."

# MUST READ — the canonical REAL luv teardown idiom (S6 is its production-grade fix)
- file: tests/shell_fish_spike.lua
  why: "L131-148 the spike's teardown: `pcall(function() if handle and not handle:is_closing() then uv.process_kill(handle, 'sigkill') end end)` + `pcall(function() if X and not X:is_closing() then X:close() end end)` for stdin/stdout/stderr. The EXACT is_closing-guard + pcall + 'sigkill' idiom S6's close_handles() mirrors. ALSO: stdout:read_start(function(rerr, data) ... data==nil ⇒ EOF) — confirms EOF is the data==nil path S3's read_cb routes to _reset."
  pattern: "is_closing()-guard + pcall EVERY luv call; 'sigkill' string; kill THEN close-pipes."
  gotcha: "the spike does NOT close the PROC handle (handle) — only process_kills it. F2/F3 PROVE that leaks the uv_process_t (is_closing stays false even after on_exit). S6's close_handles() ADDS `proc:close()` after kill. Do NOT copy the spike's omission. Also: the spike closes stderr (it created it); shell.lua does NOT store stderr (the driver owns it — S3 stores proc/stdin/stdout only). S6 closes only proc/stdin/stdout."

# MUST READ — THE idempotent-close reference (GOTCHA 2: double-close throws)
- file: lua/pi-bridge/bridge.lua
  why: "M.close() (L765+): `if state.closed then return end` (shadow flag set FIRST) + `is_closing()` + `pcall`. Header GOTCHA 2 (L20): 'DOUBLE-CLOSE THROWS: pipe:close() on an already-closing handle raises \"handle 0x.. is already closing\". close() is guarded by a shadow state.closed flag (set FIRST) + is_closing() + pcall. Idempotent across on_close / on_exit / ...'. This is THE pattern S6's close_handles() + teardown() idempotency mirror. (teardown needs NO shadow flag — it nils state.proc/stdin/stdout in reset() so a 2nd call's `if state.X` guard skips; the is_closing() guard covers the kill→reset window.)"
  pattern: "is_closing() guard + pcall on every close; the shadow-flag OR nil-state-ref gives idempotency."
  gotcha: "F5 LIVE-VERIFIES double-close throws 'already closing'. NEVER call :close() without `if not h:is_closing()` + pcall."

# MUST READ — the stop-then-close leak fix (the order S6 applies to stdout)
- file: lua/pi-bridge/completion.lua
  why: "L350-360 cancel_timer(): `pcall(function() if state.debounce_timer and not state.debounce_timer:is_closing() then state.debounce_timer:stop(); state.debounce_timer:close() end end)`. The EXACT stop-THEN-close (NEVER stop-only — leaks the uv_timer_t) + is_closing-guard + pcall pattern. S6 applies the SAME order to stdout: read_stop() THEN close() (the item description reverses this — close then read_stop — D2)."
  pattern: "stop the active op THEN close; is_closing() guard; pcall."
  gotcha: "a one-shot timer/handle only auto-stops after firing; :close() is REQUIRED to free the uv_handle_t (libuv owns the C struct; not GC'd until closed). Applies to uv_pipe_t + uv_process_t too."

# MUST READ — the IMMEDIATE upstream contract (S4: pending_cb + req_timer + cancel_req_timer). Treat as a contract.
- file: plan/002_d23d7473c16c/P2M1T2S4/PRP.md
  why: "defines state.pending_cb EXACTLY: `function(items, prefix) if gen ~= state.gen then return end cancel_req_timer(); state.pending_cb=nil; state.inflight=false; cb(nil, items, prefix) end` — the gen-guarded ONE-SHOT. S6 invokes it as `pcall(state.pending_cb, {}, '')` (NOT ('teardown',{},'') — D-conflict: pending_cb takes items/prefix, not err/items/prefix). ALSO defines cancel_req_timer (the module-local S6 calls FIRST) + req_timer (the module-local timer slot) + S4's forward contract: 'S6's teardown() calls cancel_req_timer() BEFORE uv.process_kill + pipe:close×3 THEN reset()'."
  critical: "S4 is editing shell.lua IN PARALLEL with S6 (request appends; S6 adds teardown + close_handles + extends _reset). S6 does NOT touch request/pending_cb/req_timer/cancel_req_timer. If S4 hasn't landed, cancel_req_timer + req_timer may not exist yet — S6 must DECLARE cancel_req_timer's existence (S4 owns it) and call it; the test gates on S4's presence OR the smoke proves the wiring once S4 lands. teardown invoking pending_cb({}, '') goes through S4's gen-guard (if superseded, dropped — correct)."

# MUST READ — the sibling test conventions (S3; the exact patterns S6's tests mirror)
- file: tests/shell_ensure_spec.lua
  why: "the bootstrap (require pi-bridge + shell; if pi.config==nil then pi.setup({}) end); fake_bridge(shell_path, server_cwd); make_fake_driver() with captured.read_cb + fake_pipe() (read_start/write/close/read_stop/is_closing — is_closing returns false, close/read_stop are no-ops → they absorb close_handles()); before_each/after_each save/restore SHELL/bridge/descriptor/config/package.loaded + shell.reset(). The ensure→short-circuit 'daemon disabled' probe (after state.failed) is how S6's tests assert teardown cleared state. S6's teardown tests INJECT the fake driver, ensure() to populate state, then call teardown() and assert the fake pipes' close/read_stop were called + state cleared."
  pattern: "fake-driver injection → real ensure caches fake stdin/stdout + wires read_cb → tests call teardown() → assert fake pipe call counts + state + ensure short-circuit."
  gotcha: "do NOT name a spec-local `pending` (shadows plenary.busted's skip fn). The fake pipes' is_closing() returns false → close_handles() WILL call their read_stop/close (no-ops) — so to assert 'exactly once', either (a) count calls on an instrumented fake, or (b) for the REAL leak assertion use a gated real-fish spawn (is_closing becomes true)."

# MUST READ — the S5 caller contract (parse-failure threshold forward-guards teardown + re-asserts failed)
- file: plan/002_d23d7473c16c/P2M1T2S5/PRP.md
  why: "S5's _feed, on N (default 5) consecutive parse failures: `state.failed=true; pcall(function() if type(M.teardown)=='function' then M.teardown() end end); state.failed=true` (D7: forward-guard + re-assert). S6's teardown just needs to EXIST + be safe from S5's luv fast context (the stdout:read_start cb). S6's reset() clears failed=false; S5 re-asserts — so on the parse-failure path the net is failed=true (§17.12 'marked unhealthy')."
  critical: "S5 is editing shell.lua IN PARALLEL with S6 (S5 replaces the _feed body + adds parse_failures to state/reset). S6 does NOT touch _feed/parse_failures. S6 ADDS the state.parse_failures clear implicitly via M.reset() (S2/S5 owns the field). The forward-guard `if type(M.teardown)=='function'` means S6 is a no-op until it lands — S5's tests pass pre-S6; S6's existence makes S5's threshold actually kill the daemon."

# MUST READ — local research notes (verified facts + the 9 locked design decisions + the algorithm + the gotchas)
- docfile: plan/002_d23d7473c16c/P2M1T2S6/research/notes.md
  why: "§0 the task-boundary fence (S6 vs S2/S3/S4/S5/drivers/routing/ftplugin). §1 the INPUT contracts (S2 state+reset, S3 read_start+_reset, S4 pending_cb+req_timer+cancel_req_timer, S5 forward-guard+re-assert). §2 the canonical in-repo references (fish spike teardown idiom, bridge.lua close/GOTCHA 2, completion.lua cancel_timer stop+close, notify.lua no-op, shell_ensure_spec test recipe). §3 the 10 LIVE-VERIFIED facts (/tmp/teardown_probe.lua + /tmp/leak_probe.lua: proc handle leak, double-close throws, read_stop order, no loop API, sigkill string, on_exit sig=9). §4 the 9 locked design decisions (D1 proc:close required; D2 read_stop-then-close; D3 is_closing+pcall idempotency; D-conflict pending_cb soft-degrade; D4 finalize in-flight; D5 cancel_req_timer first; D6 full reset; D7 _reset extension; D8 never-throws; D9 shared helper). §5 the teardown algorithm + close_handles() pseudocode. §6 the 18 gotchas. §7 the forward contracts. §8 references."

# SUPPORTING — the current shell.lua (S2+S3+S4+S5 output; S6 adds teardown + close_handles + extends _reset)
- file: lua/pi-bridge/shell.lua
  why: "the file S6 edits. S2's `local state = {...}` + M.reset() (the reset target S6 calls); S3's ensure read_start wiring (confirms EOF→_reset) + M._reset stub (the function S6 EXTENDS — prepend close_handles()); S4's request + state.pending_cb + req_timer + cancel_req_timer (the contracts S6 invokes — cancel_req_timer FIRST, pending_cb({}, '')); S5's _feed + parse_failures (S6 does not touch). The [Mode A] header documents the forward-contract seam (M.teardown() → S6)."

# SUPPORTING — architecture research (confirms the skeleton + teardown contract + failure model + testing)
- docfile: plan/002_d23d7473c16c/architecture/research-prd-section-17.md
  why: "§17.5.2 (the teardown skeleton comment). §17.12 (the two callers: EOF _reset + parse-failure threshold kill). §17.15 (shell_daemon_spec: 'teardown — no leaked uv handles' — NOTE the loop API is unavailable, F9). §17.16 step 22 (spawn/teardown as one phase step)."
  section: "§17.5.2, §17.12, §17.15, §17.16"

# SUPPORTING — the dedup notify mechanism (S6 references in HEADER only; does NOT call)
- file: lua/pi-bridge/notify.lua
  why: "M.once(category, level, msg). S6's header documents that the §17.12 one-time degrade notify (category e.g. 'shell-daemon') is P2.M2.T3.S4's job; S6 has ZERO notify.once calls (it sets only state.failed/calls reset — mirrors S3 _reset / S4 request)."
```

### Current Codebase tree (relevant slice)

```bash
lua/pi-bridge/
├── shell.lua          # ← S2 CREATED (state + resolve/pick/cwd/reset); S3 APPENDED ensure/_feed(STUB)/_reset;
│                      #   S4 APPENDED request/pending_cb/req_timer/cancel_req_timer; S5 REPLACES _feed body +
│                      #   adds parse_failures. S6 ADDS close_handles() + M.teardown() + EXTENDS M._reset()
│                      #   (prepend close_handles()). Does NOT touch S2/S3/S4/S5 functions.
├── bridge.lua         # READ-ONLY — M.close() + GOTCHA 2 (THE idempotent-close reference).
├── completion.lua     # READ-ONLY — cancel_timer L350-360 (stop-then-close leak fix).
├── init.lua           # READ-ONLY — M.config (nil until setup; teardown does not read config).
├── notify.lua         # READ-ONLY — M.once dedup (S6 header-only reference; NOT called).
└── jsonlreader.lua    # READ-ONLY (unrelated; the JSONL twin — S6 does not touch).
lua/pi-bridge/shell/   # DOES NOT EXIST YET — P2.M2.T4 (fish) / P2.M3.T5 (zsh/bash) create the drivers.
tests/
├── shell_fish_spike.lua      # READ-ONLY — the canonical real uv.spawn + kill + close×N (leaks proc — S6 fixes).
├── shell_ensure_smoke.lua    # READ-ONLY (S3) — the smoke convention S6's smoke mirrors.
├── shell_ensure_spec.lua     # READ-ONLY (S3) — the spec convention + fake-driver/fake-pipe recipe S6 mirrors.
├── (shell_request_smoke.lua, shell_request_spec.lua)   # S4's tests (if landed) — S6's tests are SIBLINGS.
├── (shell_feed_smoke.lua, shell_feed_spec.lua)         # S5's tests (if landed) — S6's tests are SIBLINGS.
└── (shell_teardown_smoke.lua, shell_teardown_spec.lua) # ← S6 CREATES both
```

### Desired Codebase tree with files to be added/edited

```bash
lua/pi-bridge/shell.lua             # EDIT — ADD `local function close_handles()` (~12 lines) near cancel_req_timer;
                                    #   ADD `function M.teardown()` (~12-18 lines) after M.request; PREPEND
                                    #   `close_handles()` as the FIRST line of S3's M._reset().
tests/shell_teardown_smoke.lua      # NEW — plenary-FREE smoke (the teardown matrix + a gated real-fish leak check).
tests/shell_teardown_spec.lua       # NEW — plenary/busted spec (the same matrix as it(...) cases).
# (NO other file is created or modified.)
```

### Known Gotchas of our codebase & Library Quirks

```lua
-- CRITICAL (AGENTS.md HARD RULE): run tests via `+"luafile tests/shell_teardown_smoke.lua" +qa` (a FILE on disk).
-- NEVER pipe a heredoc into nvim's stdin (`nvim ... +"luafile /dev/stdin" +qa <<EOF` HANGS the session —
-- ~10 killed sessions in this repo). Wrap every nvim in `timeout` (a hung headless nvim blocks the turn).

-- GOTCHA #1 — (F3, LIVE-VERIFIED) `uv.process_kill(proc, "sigkill")` does NOT close the uv_process_t handle.
-- `proc:is_closing()` stays FALSE even after on_exit fires. The fish spike omits `proc:close()` → it LEAKS.
-- S6's close_handles() MUST call `proc:close()` after kill. (research §3 F2/F3 / D1.)

-- GOTCHA #2 — (F5, LIVE-VERIFIED) DOUBLE-CLOSE THROWS "handle 0x.. is already closing". Every `:close()` MUST be
-- guarded by `if not h:is_closing()` + `pcall` (bridge.lua GOTCHA 2). teardown's idempotency (2nd call = no-op)
-- relies on BOTH the `if state.X` nil-guard (reset nils the refs) AND the `is_closing()` guard (the kill→reset
-- window + the EOF path where _reset already closed them). (research §3 F5 / D3.)

-- GOTCHA #3 — (item vs libuv) the item description says `state.stdout.close` THEN `state.stdout.read_stop`
-- (reversed). The correct order (completion.lua cancel_timer + libuv idiom) is `read_stop` THEN `close`:
-- stop the active read cb FIRST (so it can't re-enter _feed/_reset mid-teardown), then close. (research D2.)

-- GOTCHA #4 — (item vs S4 CONTRACT) the item says `state.pending_cb("teardown", {}, "")`. But S4's pending_cb is
-- `function(items, prefix)` — 2 params. Passing ("teardown",...) makes items="teardown" (a STRING — type bug).
-- S4 is a parallel contract S6 MUST NOT modify. Resolution: `pcall(state.pending_cb, {}, "")` → user cb(nil, {}, "")
-- (soft-degrade, identical to S4's timeout path). pcall'd + type-guarded. BEFORE reset() (reset nils pending_cb).
-- (research D-conflict.)

-- GOTCHA #5 — (F9, LIVE-VERIFIED) `vim.uv.loop()` is NIL; `stdin._loop` is nil; `uv.walk(loop,...)` FAILS;
-- `loop:gc_collect()` N/A; `uv.gcollect` doesn't exist. §17.15's "vim.uv.loop():gc_collect() / handle-count assert"
-- is UNAVAILABLE. The robust leak assertion is `assert(proc:is_closing() and stdin:is_closing() and
-- stdout:is_closing())` (F10: is_closing() is true after close). For unit tests use fake-pipe call counts.
-- (research §3 F9/F10.)

-- GOTCHA #6 — teardown runs from libuv FAST context (S5's _feed caller — the stdout:read_start cb) AND the nvim
-- main loop (VimLeavePre/ExitPre). NO `vim.api.*` (teardown is lifecycle, not UI). All luv calls pcall'd;
-- pending_cb pcall'd. NO `vim.schedule` (synchronous cleanup; the consumer's cb-scheduling is its concern per S4).
-- (research D8.)

-- GOTCHA #7 — deliver pending_cb BEFORE reset(). reset() nils state.pending_cb — if you reset FIRST, the `if
-- type(state.pending_cb)=="function"` guard skips → the in-flight request's cb NEVER fires (menu dangles on the
-- parse-failure path). Order: cancel_req_timer → pending_cb → close_handles → reset. (research D-conflict/D4.)

-- GOTCHA #8 — cancel_req_timer() FIRST. S4's forward contract: "S6's teardown() calls cancel_req_timer() BEFORE
-- uv.process_kill + pipe:close×3 THEN reset()". Stops the per-request timer from firing mid-teardown (a fire would
-- race teardown's own pending_cb deliver). cancel_req_timer is idempotent (nil-guarded + is_closing-guarded).
-- (research D5.)

-- GOTCHA #9 — M.reset() clears state.failed=false. On the parse-failure path S5 RE-ASSERTS failed=true AFTER
-- teardown (S5's D7/GOTCHA #7). On VimLeave, failed is moot (editor closing). Do NOT add a shadow flag or special-case
-- failed in teardown — just call reset(); S5 owns the re-assert. (research D6/§1d.)

-- GOTCHA #10 — _reset (EOF) must NOT call reset() (S3 contract — leaves failed=true; a crash is not a clean exit).
-- S6 only PREPENDS `close_handles()` to _reset's body. _reset's existing failed=true + nil-proc/pipes/driver/rx_buf
-- is UNCHANGED. (research D7.)

-- GOTCHA #11 — TAB indentation throughout (match shell.lua/completion.lua/bridge.lua). Every new line uses tabs.

-- GOTCHA #12 — no lua linter/formatter (no luacheck/selene/stylua/.luarc). The ONLY "type" surface is the luaemmy
-- @class/@field annotations (lua-language-server, NOT runtime-enforced). Validation = the smoke + spec.

-- GOTCHA #13 — the fake pipes in shell_ensure_spec (is_closing=()=>false, close/read_stop=()=>end) ABSORB
-- close_handles() calls → extending _reset is ZERO-RISK to S3's tests (S3's assertions: failed=true, nil proc,
-- "does NOT call reset" — all hold; close_handles touches neither failed nor reset). To assert 'closed exactly once'
-- in unit tests, instrument the fake (count close/read_stop calls). For the REAL leak, use the gated fish smoke.
-- (research §2e/§6 G13.)

-- GOTCHA #14 — stderr is NOT state.stdin/stdout. S3's ensure stores ONLY proc/stdin/stdout (the driver's start
-- returns (proc, stdin, stdout)). A driver that opens a stderr pipe owns it — shell.lua's teardown CANNOT close it
-- (never stored). The driver must close stderr on its own exit path (or leak one pipe). FORWARD CONTRACT for the
-- driver PRP (P2.M2.T4). Do NOT invent a state.stderr. (research §7.)

-- GOTCHA #15 — on_exit is the DRIVER's cb (the driver's start passed it to uv.spawn). shell.lua does not control it.
-- teardown's proc:close() frees the handle regardless of what on_exit does (F4: close succeeds after kill+on_exit).

-- GOTCHA #16 — Don't name a spec-local `pending` (shadows plenary.busted's skip fn). Use got/cb/captured.

-- GOTCHA #17 — state is module-local — teardown tests reach state.proc/stdin/stdout/pending_cb only via EFFECTS:
--   (a) the ensure→"daemon disabled" short-circuit (after teardown, state.failed was reset=false; reset it to true
--       or spawn-fail to re-trigger); (b) is_closing() on REAL handles (the gated fish smoke); (c) instrumented
--       fake-pipe call counts (the unit spec); (d) the in-flight cb firing (request()→teardown→cb(nil,{},")).
--   Do NOT reach into state directly (module-local). (research §6 G17.)

-- GOTCHA #18 — S6 ADDS teardown + close_handles + extends _reset. Do NOT touch S2's state/reset/resolution, S3's
-- ensure/read_start wiring, S4's request/pending_cb/req_timer/cancel_req_timer, or S5's _feed/parse_failures.
-- The [Mode A] header's forward-contract note for M.teardown() (→ S6) becomes accurate post-S6.
```

## Implementation Blueprint

### Design Decisions (READ FIRST)

**1. `proc:close()` is REQUIRED after `process_kill` (the leak the fish spike has).** LIVE-VERIFIED (F2/F3):
`uv.process_kill(proc, "sigkill")` sends the signal but does NOT close the `uv_process_t`; `proc:is_closing()` stays
`false` even after `on_exit` fires (the process is dead but the handle is open). libuv owns the C struct; it is not
GC'd until closed → the handle leaks for the session. The fish spike (`tests/shell_fish_spike.lua` L131-148) kills +
closes the pipes but omits `proc:close()` — acceptable in a one-shot spike (nvim exits) but a real leak across editor
sessions. **S6's `close_handles()` calls `proc:close()` after `process_kill`.** (D1.)

**2. Close order: `read_stop` → `process_kill` → close pipes → close proc.** The item description reverses read_stop
and close (`state.stdout.close` then `state.stdout.read_stop`). The libuv idiom (completion.lua `cancel_timer`
L350-360: `:stop()` THEN `:close()`) is: stop the active operation FIRST, then close. S6 `read_stop`s stdout FIRST
(stops the read cb from re-entering `_feed`/`_reset` mid-teardown), THEN kills the proc, THEN closes stdout, THEN
closes stdin, THEN closes the proc handle. (D2.)

**3. `is_closing()` guard + `pcall` on EVERY luv call (idempotency + double-close safety).** LIVE-VERIFIED (F5):
calling `:close()` twice throws "handle 0x.. is already closing". bridge.lua's `M.close()` (GOTCHA 2) guards with a
shadow `state.closed` flag + `is_closing()` + `pcall`. teardown's idempotency has TWO layers: (a) the `if state.X`
nil-guard (after `reset()`, state.proc/stdin/stdout are nil → a 2nd teardown call skips them); (b) the
`if not h:is_closing()` guard (covers the narrow window between kill and reset, AND the EOF path where `_reset`'s
`close_handles()` already closed them). teardown needs NO shadow flag (unlike bridge.lua's persistent socket — teardown
nils the state refs in `reset()`). (D3.)

**4 (D-conflict). pending_cb invocation: `pcall(state.pending_cb, {}, "")` — NOT `("teardown", {}, "")`.** The item
description says call `state.pending_cb("teardown", {}, "")`. But S4's `pending_cb` signature is `(items, prefix)` —
2 params (S4 is a parallel contract S6 MUST NOT modify). Passing `("teardown", {})` makes `items="teardown"` (a
string, not a table) → the user `cb` receives `cb(nil, "teardown", {})` — a type bug. Resolution: S6 calls
`pcall(state.pending_cb, {}, "")` → through S4's gen-guarded closure → user `cb(nil, {}, "")` (soft-degrade empty,
IDENTICAL to S4's timeout path). The "teardown" err-signal is undeliverable through S4's closure without modifying
S4; §17.12 does NOT require distinguishing teardown from degrade (both = "no completion this keystroke"). pcall'd so a
throwing consumer cb can't escape teardown's never-throws invariant. Delivered BEFORE `reset()` (reset nils the slot).
(D-conflict.)

**5. Finalize the in-flight request (deliver pending_cb) — matters for the parse-failure path; harmless on VimLeave.**
On S5's parse-failure threshold there IS an in-flight request whose `cb` hasn't fired (S5 only calls pending_cb on a
SUCCESSFUL parse; the garbage that tripped the threshold didn't parse). teardown delivering `{}` finalizes it (the
menu clears instead of dangling). On VimLeave, delivering is harmless (VimLeavePre fires while the editor is alive;
the consumer cb runs in the nvim main loop). teardown's pending_cb call runs in the SAME luv context S5's `_feed`
already invokes it from — no WORSE than S5; the consumer schedules its editor work per S4's forward contract. (D4.)

**6. `cancel_req_timer()` FIRST (S4's forward contract).** S4's `request` forward-contract note: "S6's teardown()
calls `cancel_req_timer()` BEFORE `uv.process_kill` + `pipe:close`×3 THEN `reset()`." Stops the per-request timer from
firing mid-teardown (a fire would call `state.pending_cb` → race with teardown's own deliver). `cancel_req_timer` is
idempotent (nil-guarded + is_closing-guarded — S4 owns it). (D5.)

**7. teardown calls `M.reset()` (full clean slate), NOT the item's subset.** The item lists a subset (proc/stdin/
stdout/rx_buf/gen/inflight/driver). `M.reset()` (S2) clears ALL of those PLUS shell/cwd/pending_cb/failed/
parse_failures — ALL of which SHOULD be cleared on teardown (a stale shell/cwd/pending_cb would be wrong on the next
spawn). reset() clears `failed=false`; S5 re-asserts `failed=true` on the parse-failure path (§1d); on VimLeave failed
is moot. (D6.)

**8. Extend S3's `_reset()` to close the pipes (the EOF leak S3 deferred to S6).** S3's [Mode A] header explicitly
assigns the EOF pipe-close to S6 ("pipe-close matters for real handles — S6 owns it"). Without it, a daemon crash
mid-session (§17.12 EOF) leaves the stdin/stdout/proc handles open for the rest of the session. S6's shared
`close_handles()` local serves BOTH teardown AND `_reset`. ZERO risk to S3's tests (the fake pipes absorb read_stop/
close; S3's assertions — `failed=true`, nil proc, "does NOT call reset" — all hold since `close_handles()` touches
neither `failed` nor calls `reset()`). `_reset` does NOT call `reset()` (S3 contract — leaves failed=true). (D7.)

**9. NEVER throws; runs from luv fast context AND the nvim main loop.** Every luv call pcall'd + is_closing-guarded;
pending_cb pcall'd; state writes are plain assignments. NO `vim.api.*` (teardown is lifecycle, not UI). NO
`vim.schedule` (synchronous cleanup; the consumer's cb-scheduling is its concern per S4). NO notify (§17.12's one-time
degrade notify is P2.M2.T3.S4). (D8.)

**10. Shared `close_handles()` local (DRY; serves teardown + `_reset`).** One idempotent kill+read_stop+close×N+
close-proc routine. Both teardown (active kill + reset) and `_reset` (EOF; proc dead; failed=true; partial clear) call
it. They differ only in what they do AROUND it (teardown: cancel_timer + pending_cb + reset; _reset: failed=true +
nil-proc/pipes/driver/rx_buf). (D9.)

### Data models and structure

S6 does NOT introduce new runtime types — it consumes S2's `state` + `M.reset()`, S3's `M._reset` (extends it), S4's
`state.pending_cb` + `cancel_req_timer` (invokes them). The only NEW contract surface is the **`M.teardown()` API +
the `close_handles()` local**:

```lua
--- teardown() — §17.5.2 + §17.12. Kill the daemon (SIGKILL), close stdin/stdout/proc handles, finalize the
--- in-flight request (soft-degrade empty), then reset state. IDEMPOTENT (safe VimLeavePre + ExitPre double-fire).
--- Called by: ftplugin VimLeavePre/ExitPre (P2.M3.T6.S3) + S5's parse-failure threshold (forward-guarded; S5
--- re-asserts state.failed after). NEVER throws (every luv call pcall'd + is_closing-guarded; pending_cb pcall'd).
--- Runs from libuv fast context (S5's _feed caller) AND the nvim main loop (VimLeave). NO vim.api.*; NO vim.schedule.
function M.teardown() ... end
```

```lua
-- close_handles() — the shared, idempotent, never-throws kill+close routine (used by teardown + _reset).
-- read_stop+close stdout; process_kill("sigkill")+close proc (F3: process_kill alone LEAKS the uv_process_t);
-- close stdin. Every luv call pcall'd; every handle is_closing()-guarded (F5: double-close throws).
local function close_handles() ... end
```

### Implementation Tasks (ordered by dependencies)

```yaml
Task 1: READ the contracts + the canonical references
  - READ lua/pi-bridge/shell.lua: confirm S2's `local state = {...}` + M.reset() (the reset target); confirm S3's
    M.ensure read_start wiring (`if chunk then M._feed(chunk) else M._reset() end` — confirms EOF→_reset); confirm
    S3's M._reset stub (the function S6 EXTENDS — prepend close_handles() as its FIRST line); confirm S4's
    cancel_req_timer (the module-local S6 calls FIRST) + state.pending_cb (the `(items,prefix)` closure S6 invokes
    as `({}, "")`) + req_timer; confirm the TEST SEAMS block + `return M` at the file's end (teardown goes BEFORE
    the TEST SEAMS block).
  - READ tests/shell_fish_spike.lua L131-148 (the REAL luv teardown idiom: is_closing-guard + pcall + "sigkill" +
    kill-then-close-pipes). NOTE: the spike omits proc:close() — S6 fixes (F3). NOTE: the spike closes stderr (it
    created it); shell.lua does NOT store stderr (the driver owns it — S3 stores proc/stdin/stdout only).
  - READ lua/pi-bridge/bridge.lua M.close() (L765+) + header GOTCHA 2 (L20): the idempotent-close pattern (shadow
    flag + is_closing + pcall; double-close throws).
  - READ lua/pi-bridge/completion.lua cancel_timer (L350-360): stop-THEN-close + is_closing-guard + pcall (the order
    S6 applies to stdout: read_stop then close).
  - READ tests/shell_ensure_spec.lua (the fake-driver/fake-pipe recipe + before/after_each + the ensure→"daemon
    disabled" probe — the test conventions S6's spec mirrors).
  - READ plan/002_d23d7473c16c/P2M1T2S4/PRP.md (the state.pending_cb + cancel_req_timer + req_timer contracts —
    S6 invokes them) + plan/002_d23d7473c16c/P2M1T2S5/PRP.md (S5's forward-guard + re-assert — S6's caller).
  - RUN /tmp/teardown_probe.lua + /tmp/leak_probe.lua (research §3) to re-confirm: process_kill doesn't close the
    handle; double-close throws; no loop API; is_closing() is the leak assertion. (Re-create them from research §3
    if gone.)

Task 2: ADD `local function close_handles()` (the shared, idempotent kill+close routine)
  - PLACE: near `cancel_req_timer` (after it; before `M.teardown`), OR immediately before `M.teardown`. It is a
    module-local (like `cancel_req_timer`/`req_timer` — NOT a state field; it's a helper, not state).
  - WRITE per Reference block C1 + Design Decisions §1-§10. Body:
      (1) stdout: `if state.stdout and not state.stdout:is_closing() then pcall(function() state.stdout:read_stop()
          end); pcall(function() state.stdout:close() end) end` (read_stop THEN close — D2; both pcall'd + guarded).
      (2) proc: `if state.proc and not state.proc:is_closing() then pcall(uv.process_kill, state.proc, "sigkill");
          pcall(function() state.proc:close() end) end` (kill THEN close — D1: process_kill does NOT close the
          uv_process_t; proc:close() is REQUIRED — the fish spike omits it and leaks).
      (3) stdin: `if state.stdin and not state.stdin:is_closing() then pcall(function() state.stdin:close() end) end`.
  - JSDoc: document the shared role (teardown + _reset), the read_stop-then-close order, the proc:close() leak fix
    (F3), the is_closing+pcall idempotency (F5), the "sigkill" string, the never-throws + luv-fast-context safety.
  - DO NOT: add a state.stderr (the driver owns it — GOTCHA #14). Do NOT touch failed/reset (close_handles is
    handle-only). Do NOT vim.schedule / notify / vim.api.

Task 3: ADD `function M.teardown()` (after S4's M.request, before the TEST SEAMS block)
  - PLACE: after S4's `M.request(...) end` and before the `-- ====... TEST SEAMS ...` comment block (or before
    `return M` if no TEST SEAMS block — but S4 adds one; teardown goes BEFORE the test seams so it's not mistaken
    for one).
  - WRITE per Reference block T1 + Design Decisions §1-§10. Body:
      (1) `cancel_req_timer()` — FIRST (S4 forward contract; idempotent).
      (2) `if type(state.pending_cb) == "function" then pcall(state.pending_cb, {}, "") end` — finalize the in-flight
          request (soft-degrade empty → cb(nil, {}, ""); pcall'd + type-guarded; BEFORE reset — D-conflict/D4).
      (3) `close_handles()` — the kill+close (Task 2).
      (4) `M.reset()` — full clean slate (D6).
  - JSDoc (expand richly): the §17.5.2/§17.12 teardown contract; idempotency (nil-guard + is_closing-guard — the
    VimLeavePre→ExitPre double-fire is safe); the callers (VimLeavePre/ExitPre P2.M3.T6.S3 + S5's parse-failure
    threshold); the pending_cb soft-degrade resolution (vs the item's literal `("teardown",...)` — D-conflict);
    cancel_req_timer first (S4); the proc:close() leak fix (F3); never-throws + luv-fast-context + nvim-main-loop
    safety; the forward contracts (S5 re-asserts failed; the driver owns stderr; the consumer schedules its cb).
  - DO NOT: call pending_cb with `("teardown",...)` (GOTCHA #4). Do NOT reset BEFORE pending_cb (GOTCHA #7). Do NOT
    special-case failed (GOTCHA #9 — S5 re-asserts). Do NOT vim.schedule / notify / vim.api.

Task 4: EXTEND S3's M._reset() — prepend close_handles() as its FIRST line
  - FIND S3's M._reset (the EOF stub): `function M._reset()\n\tstate.failed = true\n\tstate.proc   = nil\n...`.
  - PREPEND `close_handles()` as the FIRST statement (before `state.failed = true`). Leave S3's existing body
    UNCHANGED (failed=true; nil proc/stdin/stdout/driver; rx_buf=""). _reset does NOT call reset() (S3 contract).
  - UPDATE M._reset's JSDoc: note S6 added close_handles() (the EOF pipe-close S3 deferred to S6); on EOF the proc
    is dead (libuv delivered data==nil) so process_kill is moot-but-harmless (pcall); the pipe-close is the real fix.
  - DO NOT: make _reset call reset() (GOTCHA #10). Do NOT change _reset's failed=true or its nil-list.

Task 5: CREATE tests/shell_teardown_smoke.lua — plenary-FREE smoke (mirror shell_ensure_smoke + the spike)
  - WRITE the header doc-comment with the run command: `timeout 60 nvim --headless --clean -u NORC -c 'set rtp+=.'
    +"luafile tests/shell_teardown_smoke.lua" +qa`. Note the AGENTS.md HARD RULE.
  - BOOTSTRAP: `local me = debug.getinfo(1,"S").source:sub(2); local root = vim.fn.fnamemodify(me, ":h:h");
    vim.opt.runtimepath:append(root)`; `local pi = require("pi-bridge"); if pi.config==nil then pi.setup({}) end`;
    `local shell = require("pi-bridge.shell")`.
  - UNIT MATRIX (fake driver — no subprocess): for each case assert + count fails (mirror the spike's `check`):
      (a) spawn via ensure (fake fish driver) → teardown → assert state cleared (ensure short-circuits "daemon
          disabled" needs failed; OR assert proc/stdin/stdout nil via an instrumented fake that records close counts).
      (b) idempotent: teardown() x3 → no throw, no double-close error.
      (c) never-throws: teardown() on an un-spawned daemon (state all-nil) → no throw.
      (d) teardown after _reset (EOF) → handles already closing → no throw (is_closing guard).
      (e) pending_cb soft-degrade: request() (S4, if landed) arms pending_cb → teardown → cb(nil, {}, "").
      (f) _reset now closes handles: ensure → _reset() → assert fake pipe close/read_stop called.
  - GATED REAL-FISH LEAK CHECK (mirror the spike): if `vim.fn.executable("fish")==0` → print a SKIP line + continue
    (never fail for a missing shell — §17.15). Else: spawn fish via the spike's uv.spawn pattern (3 piped streams),
    store the handles in shell.state via a tiny shim OR assert on the LOCAL handles (the spike's pattern), call
    teardown() on those handles (or replicate close_handles inline), `vim.wait` for on_exit (sig=9), assert
    `proc:is_closing() and stdin:is_closing() and stdout:is_closing()` (F10 — the robust leak assertion; NOT
    loop:gc_collect which is unavailable, F9).
  - PRINT `SMOKE_PASS` + exit 0 (`vim.cmd("qa")` is via the +qa; just return). On fail: `io.stderr:write` +
    `vim.cmd("cquit 1")`.
  - GATE the real-fish block behind executable("fish") so CI without fish passes.

Task 6: CREATE tests/shell_teardown_spec.lua — plenary/busted spec (mirror shell_ensure_spec)
  - BOOTSTRAP + before/after_each save/restore (mirror shell_ensure_spec.lua): SHELL/bridge/descriptor/config/
    package.loaded[fish] + `shell.reset()`. Re-use `fake_bridge` + `make_fake_driver` + `fake_pipe` (copy them —
    they're test-local helpers, not a shared module). Instrument the fake pipe to COUNT close/read_stop/process_kill
    calls for the "exactly once" assertions.
  - CASES (it(...)):
      - "teardown is a function" (type check).
      - "teardown on spawned daemon: cancel_req_timer called + pending_cb soft-degrade + close_handles + reset".
        (ensure fake → request() if S4 landed to arm pending_cb, else inject a fake pending_cb via a seam — see
        GOTCHA #17; teardown → assert cb(nil,{},") + fake close counts == 1 + state cleared.)
      - "teardown is idempotent: 2nd + 3rd call are no-ops" (no throw; fake close counts stay 1; no re-deliver).
      - "teardown never throws on un-spawned daemon (state all-nil)".
      - "teardown never throws with already-closing handles (post-_reset)".
      - "teardown never throws with a throwing consumer cb" (inject a cb that error()s → pcall swallows → no throw).
      - "teardown calls proc:close() (the F3 leak fix)" — instrument the fake proc to count close(); assert 1.
      - "teardown calls process_kill('sigkill')" — instrument; assert the sig string.
      - "teardown read_stop's stdout BEFORE close" — instrument; assert read_stop called + close called.
      - "teardown delivers pending_cb({}, '') (NOT ('teardown',...))" — assert the cb received items=={} + prefix=="".
      - "teardown calls cancel_req_timer FIRST" (the per-request timer is closed — assert via S4's _test seams if
        landed, OR via an instrumented req_timer).
      - "_reset (EOF) now closes handles: fake close/read_stop called" (ensure → _reset() → assert counts).
      - "_reset still sets failed + does NOT call reset (S3 regression)" (after _reset → ensure short-circuits
        "daemon disabled").
      - (if S4 landed) "teardown finalizes an in-flight request: request()→teardown→cb(nil,{},")".
  - Do NOT name a spec-local `pending` (GOTCHA #16). Do NOT reach into state directly (module-local — use effects,
    GOTCHA #17). Do NOT spawn a real subprocess in the spec (that's the gated smoke's job).
```

### Implementation Patterns & Key Details

```lua
-- (C1) close_handles() — the shared, idempotent, never-throws kill+close routine.
-- Used by teardown (active kill + reset) AND _reset (EOF; proc dead). is_closing-guarded + pcall'd (F5).
local function close_handles()
	-- (1) stdout: read_stop THEN close (completion.lua cancel_timer order; stops the read cb re-entering
	--     _feed/_reset mid-teardown). pcall + is_closing-guard (F5: double-close throws).
	if state.stdout and not state.stdout:is_closing() then
		pcall(function() state.stdout:read_stop() end)
		pcall(function() state.stdout:close() end)
	end
	-- (2) proc: process_kill("sigkill") THEN close. F2/F3 LIVE-VERIFIED: process_kill does NOT close the
	--     uv_process_t (is_closing stays false even after on_exit) — proc:close() is REQUIRED or it LEAKS.
	--     The fish spike omits proc:close(); S6 does not. "sigkill" is unconditional (the daemon may be wedged).
	if state.proc and not state.proc:is_closing() then
		pcall(uv.process_kill, state.proc, "sigkill")
		pcall(function() state.proc:close() end)
	end
	-- (3) stdin: close (no read_start on it; is_closing-guarded + pcall'd).
	if state.stdin and not state.stdin:is_closing() then
		pcall(function() state.stdin:close() end)
	end
end

-- (T1) teardown() — the §17.5.2/§17.12 daemon teardown. Idempotent; never throws.
function M.teardown()
	-- (1) cancel the per-request timer FIRST (S4 forward contract: stop a fire racing teardown). Idempotent.
	cancel_req_timer()
	-- (2) finalize the in-flight request (soft-degrade empty). pcall'd + type-guarded (a throwing/absent cb
	--     can't escape teardown). BEFORE reset() — reset() nils pending_cb. D-conflict: invoke ({}, "") NOT
	--     ("teardown",...) — S4's pending_cb is (items, prefix), not (err, items, prefix).
	if type(state.pending_cb) == "function" then pcall(state.pending_cb, {}, "") end
	-- (3) kill + close the handles (idempotent; is_closing-guarded; pcall'd). close_handles() also closes
	--     the proc handle (the F3 leak fix).
	close_handles()
	-- (4) full clean slate. (S5 re-asserts state.failed=true AFTER teardown on the parse-failure path; on
	--     VimLeave failed is moot — editor closing.)
	M.reset()
end

-- (_reset EXTENSION) S3's M._reset — prepend close_handles() as the FIRST line. Body UNCHANGED after.
function M._reset()
	close_handles()               -- S6: close the real handles (the EOF pipe leak S3 deferred here)
	state.failed = true           -- S3 (unchanged): a crash is NOT a clean exit
	state.proc   = nil
	state.stdin  = nil
	state.stdout = nil
	state.driver = nil
	state.rx_buf = ""
end
```

### Integration Points

```yaml
STATE (lua/pi-bridge/shell.lua):
  - teardown() READS state.proc/stdin/stdout/pending_cb; CALLS M.reset() (clears all state incl. failed).
  - close_handles() READS state.proc/stdin/stdout (is_closing + close).
  - _reset() now calls close_handles() FIRST (the only structural change to S3's code).
  - NO new state field. NO edit to S2's state literal or M.reset().

MODULE-LOCAL (lua/pi-bridge/shell.lua):
  - close_handles() — NEW module-local (near cancel_req_timer).
  - cancel_req_timer() / req_timer — S4 OWNS (S6 CALLS cancel_req_timer; does not define it).
  - uv — already `local uv = vim.uv` at the top (S2); S6 reuses it (uv.process_kill).

CALLERS (do NOT implement; S6 is called BY these):
  - P2.M3.T6.S3 (ftplugin VimLeavePre/ExitPre): `autocmd VimLeavePre,ExitPre <buffer> lua require("pi-bridge.shell").teardown()`.
  - S5 (parse-failure threshold): forward-GUARDS `if type(M.teardown)=="function" then pcall(M.teardown) end` + re-asserts failed.

FORWARD CONTRACTS (do NOT implement; document):
  - The drivers (P2.M2.T4/P2.M3.T5) own stderr — shell.lua stores only proc/stdin/stdout (S3); a driver that opens
    stderr must close it itself (or leak one pipe on teardown).
  - P2.M2.T3.S4 owns the §17.12 one-time degrade notify (notify.once) — teardown sets only state.failed/calls reset.
  - :checkhealth (P2.M3.T6.S2) reads state.failed (cleared by reset; re-asserted by S5; moot on VimLeave).
```

## Validation Loop

### Level 1: Syntax & Style (Immediate Feedback)

```bash
# No lua linter/formatter in this repo (no luacheck/selene/stylua/.luarc — GOTCHA #12).
# The ONLY "type" surface is the luaemmy @ annotations (lua-language-server, NOT runtime-enforced).
# Validate by loading the module + running it (Level 2/3). A syntax error surfaces as a load failure.

# Quick load check (catches syntax errors + tab/whitespace issues):
timeout 30 nvim --headless --clean -u NORC -c 'set rtp+=.' -c 'lua local s=require("pi-bridge.shell"); assert(type(s.teardown)=="function"); assert(type(s._reset)=="function")' -c 'qa'
echo "exit=$?"   # 0 = module loads + teardown/_reset exist

# LSP diagnostics (if lua-language-server is configured):
# (run lsp_diagnostics on lua/pi-bridge/shell.lua after editing)
```

### Level 2: Unit Tests (Component Validation)

```bash
# S6's spec (the teardown matrix; fake driver — no subprocess):
timeout 90 nvim --headless --clean -u tests/minimal_init.lua \
  -c 'lua require("plenary.busted").run("tests/shell_teardown_spec.lua")'
echo "exit=$?"   # 0 = green (0 fail, 0 error)

# S6's smoke (plenary-FREE; includes the gated real-fish leak check):
timeout 60 nvim --headless --clean -u NORC -c 'set rtp+=.' +"luafile tests/shell_teardown_smoke.lua" +qa
echo "exit=$?"   # 0 = SMOKE_PASS (or SMOKE_SKIP-fish on a shell-less runner — still exit 0)

# Regression: the sibling suites S6 must NOT break:
timeout 90 nvim --headless --clean -u tests/minimal_init.lua -c 'lua require("plenary.busted").run("tests/shell_spec.lua")'
timeout 90 nvim --headless --clean -u tests/minimal_init.lua -c 'lua require("plenary.busted").run("tests/shell_ensure_spec.lua")'
# (if S4/S5 landed:)
timeout 90 nvim --headless --clean -u tests/minimal_init.lua -c 'lua require("plenary.busted").run("tests/shell_request_spec.lua")'
timeout 90 nvim --headless --clean -u tests/minimal_init.lua -c 'lua require("plenary.busted").run("tests/shell_feed_spec.lua")'
# (broader regression:)
timeout 90 nvim --headless --clean -u tests/minimal_init.lua -c 'lua require("plenary.busted").run("tests/completion_spec.lua")'

# Expected: all green. If a sibling fails, S6 likely touched shared code (state/reset/_reset) — re-read the scope fence.
```

### Level 3: Integration Testing (System Validation)

```bash
# The REAL luv teardown round-trip (the gated fish block in shell_teardown_smoke.lua, OR a manual repro):
# This is the F3 leak-fix proof + the idempotency proof on a REAL subprocess.
# (Re-create the /tmp/teardown_probe.lua from research §3 if the smoke's gated block is insufficient.)

# Manual idempotency + leak proof (write to a FILE — AGENTS.md HARD RULE; NEVER heredoc→nvim stdin):
cat > /tmp/s6_integration.lua <<'LUA'
local uv = vim.uv
local shell = require("pi-bridge.shell")
-- (spawn fish via the spike pattern; store handles; call shell.teardown() OR close_handles via a seam;
--  vim.wait for on_exit; assert is_closing on each handle.)
LUA
timeout 30 nvim --headless --clean -u NORC -c 'set rtp+=.' +"luafile /tmp/s6_integration.lua" +qa
echo "exit=$?"   # 0 = teardown killed + closed + no leaked handles (is_closing all true)

# Idempotency proof (double-call):
#   ensure fake → teardown() → teardown() → teardown()  (no throw; fake close counts == 1)
# (covered by shell_teardown_spec "idempotent" case + the smoke.)

# Expected: teardown kills the daemon (on_exit sig=9), closes proc/stdin/stdout (is_closing all true),
# resets state, and a 2nd/3rd call is a no-op. NO leaked uv_handle_t (F3 fix verified).
```

### Level 4: Creative & Domain-Specific Validation

```bash
# The §17.12 parse-failure → teardown → re-assert-failed round-trip (requires S5 landed):
# Feed N garbage responses → assert state.failed=true + the daemon killed (proc:is_closing).
# (S5's shell_feed_spec covers the parse-failure threshold; S6's existence makes S5's forward-guard fire.)
# This is a CROSS-TASK integration — run it only after S5 lands:
timeout 90 nvim --headless --clean -u tests/minimal_init.lua -c 'lua require("plenary.busted").run("tests/shell_feed_spec.lua")'

# VimLeavePre/ExitPre double-fire (requires P2.M3.T6.S3 landed — FORWARD; not testable in S6's window):
# Document that S6's idempotency guarantees the double-fire is safe; the caller just calls teardown().

# Expected: S5's threshold (when landed) kills the daemon via S6's teardown; failed stays true (S5 re-asserts).
```

## Final Validation Checklist

### Technical Validation

- [ ] Level 1: module loads; `type(shell.teardown)=="function"`; `type(shell._reset)=="function"`.
- [ ] Level 2: `shell_teardown_spec` green (0 fail, 0 error); `shell_teardown_smoke` prints SMOKE_PASS (exit 0).
- [ ] Level 2 regression: `shell_spec`, `shell_ensure_spec`, (S4/S5 if landed) `shell_request_spec`/`shell_feed_spec`,
      `completion_spec` all green.
- [ ] Level 3: the gated real-fish leak check passes (proc/stdin/stdout `is_closing()` all true; on_exit sig=9) OR
      SMOKE_SKIP on a fish-less runner (exit 0).
- [ ] Idempotency: teardown() x3 = no throw, no double-close, no re-deliver (spec + smoke).

### Feature Validation

- [ ] All Success Criteria from "What" section met (teardown function; close_handles local; _reset extension).
- [ ] teardown kills (process_kill "sigkill") + closes proc (the F3 leak fix) + closes stdin/stdout + resets state.
- [ ] teardown finalizes the in-flight request (pending_cb({}, "") → cb(nil, {}, "")) — soft-degrade, NOT ("teardown",...).
- [ ] teardown calls cancel_req_timer() FIRST.
- [ ] teardown is idempotent (VimLeavePre + ExitPre double-fire safe).
- [ ] teardown NEVER throws (un-spawned; already-closing handles; throwing cb).
- [ ] _reset (EOF) now closes handles; S3's failed=true + "does NOT call reset" invariants hold.
- [ ] Error cases handled gracefully (never-throws; all luv calls pcall'd + is_closing-guarded).

### Code Quality Validation

- [ ] Follows existing codebase patterns (bridge.lua close idempotency; completion.lua cancel_timer stop-then-close;
      fish spike is_closing+pcall+"sigkill"; shell_ensure_spec test recipe).
- [ ] File placement matches the desired codebase tree (close_handles + teardown in shell.lua; 2 test files).
- [ ] Anti-patterns avoided (see below).
- [ ] Dependencies properly managed (reuses S2 reset, S3 _reset, S4 cancel_req_timer/pending_cb; no new deps).
- [ ] TAB indentation throughout; rich JSDoc on teardown + close_handles + the _reset extension note.

### Documentation & Deployment

- [ ] teardown + close_handles JSDoc document the §17.5.2/§17.12 contract, the F3 leak fix, the D-conflict pending_cb
      resolution, the idempotency, the callers (VimLeavePre/ExitPre + S5), and the forward contracts.
- [ ] _reset's JSDoc notes S6 added close_handles() (the EOF pipe-close S3 deferred).
- [ ] No new env vars / config (teardown reads no config).
- [ ] The [Mode A] header's forward-contract seam for M.teardown() (→ S6) is now accurate.

---

## Anti-Patterns to Avoid

- ❌ **Don't omit `proc:close()`.** `process_kill` does NOT close the `uv_process_t` (F3, LIVE-VERIFIED) — it leaks.
  The fish spike omits it (acceptable in a spike); production MUST close it.
- ❌ **Don't call `:close()` without `if not h:is_closing()` + `pcall`.** Double-close throws "already closing" (F5,
  bridge.lua GOTCHA 2).
- ❌ **Don't reverse read_stop and close.** `read_stop` THEN `close` (completion.lua cancel_timer order), not the
  item description's close-then-read_stop (D2).
- ❌ **Don't call `state.pending_cb("teardown", {}, "")`.** S4's pending_cb is `(items, prefix)` — that makes
  `items="teardown"` (a string — type bug). Call `pcall(state.pending_cb, {}, "")` (soft-degrade; D-conflict).
- ❌ **Don't reset() BEFORE delivering pending_cb.** reset() nils the slot → the in-flight cb never fires. Order:
  cancel_req_timer → pending_cb → close_handles → reset (D-conflict/D4).
- ❌ **Don't special-case `state.failed` in teardown.** Call reset() (clears failed=false); S5 re-asserts on the
  parse-failure path (D6/§1d). On VimLeave failed is moot.
- ❌ **Don't make `_reset` call `reset()`.** S3's contract: `_reset` leaves `failed=true` (a crash is not a clean
  exit). S6 only PREPENDS `close_handles()` (D7/GOTCHA #10).
- ❌ **Don't invent `state.stderr`.** shell.lua stores only proc/stdin/stdout (S3). stderr is the driver's (GOTCHA #14).
- ❌ **Don't use `vim.uv.loop()` / `gc_collect()` / `uv.walk` for leak tests.** They're UNAVAILABLE (F9). Assert
  `is_closing()` on the created handles (F10).
- ❌ **Don't `vim.schedule` / `notify.once` / `vim.api.*` in teardown.** teardown is synchronous lifecycle cleanup;
  never-throws; no UI work (D8).
- ❌ **Don't touch S2/S3/S4/S5 functions.** S6 ADDS teardown + close_handles + extends _reset ONLY. The pending_cb /
  req_timer / cancel_req_timer / ensure / request / _feed / state-literal are CONTRACTS (GOTCHA #18).
- ❌ **Don't skip validation because "it should work".** The F3 leak + F5 double-close + the D-conflict pending_cb
  shape are NON-OBVIOUS — the spec + smoke + gated fish check are the proof.