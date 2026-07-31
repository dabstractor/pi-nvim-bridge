# PRP — P2.M1.T2.S3: `ensure(on_ready)` — spawn via vim.uv.spawn + driver delegation

> **Plan mapping:** task `P2.M1.T2.S3` ("ensure(on_ready) — spawn via `vim.uv.spawn` + driver delegation").
> Third subtask of **P2.M1.T2** ("shell.lua daemon manager + fish spike") within the **Shell Completion for
> !/!! Bash Mode** epic (PRD §17). This is the **SPAWN layer** of `shell.lua`: it implements the one public
> lifecycle entry point — `M.ensure(on_ready)` — that spawns the persistent completion daemon on first `!`
> activation and caches it for the session. It does this by CALLING the S2 resolution helpers
> (`resolve_shell` + `pick_driver` + `session_cwd`) and then DELEGATING the actual `vim.uv.spawn` to the
> resolved per-shell driver's `start(opts, on_ready)` (the fish driver is P2.M2.T4.S1; not yet present).
>
> **Critical scope fact:** S3 contains **ZERO `vim.uv.spawn` calls.** The spawn (and the `startup_timeout_ms`
> cold-start timer) live INSIDE the driver. S3 is the ORCHESTRATION around it: resolve → pick → delegate →
> cache the returned proc/pipes in `state` → wire `stdout:read_start` → set `state.failed` on terminal
> failure. The live spawn seam was already proven end-to-end by the S1 fish spike (`tests/shell_fish_spike.lua`);
> S3 does NOT re-prove it. Tests use a FAKE driver (no real subprocess).
>
> **Sibling context (running in PARALLEL with S2):** S2 creates `lua/pi-bridge/shell.lua` (state + resolve_shell +
> pick_driver + session_cwd + reset) + its 2 tests. **This PRP treats S2's PRP as a CONTRACT** — S3 APPENDS
> `ensure` + two forward-contract stubs (`_feed`, `_reset`) to the module S2 produces, and reuses S2's helpers
> verbatim. P2.M1.T2.S4 (`request`) is the NEXT consumer (it calls `ensure`). The fish driver (P2.M2.T4.S1)
> implements the `start(opts, on_ready)` contract this PRP specifies.

---

## Goal

**Feature Goal**: Implement `M.ensure(on_ready)` in `lua/pi-bridge/shell.lua` — the §17.5.2 spawn layer of the
completion-daemon manager. On first call it resolves ONE shell (consistent with what pi EXECUTES) + its driver,
delegates the `vim.uv.spawn` to `driver.start(opts, on_ready)`, and on success caches the returned
`{proc, stdin, stdout}` in `state` + wires `stdout:read_start` to the `M._feed`/`M._reset` route. On any
terminal failure (no driver / spawn error / a previously-crashed daemon) it short-circuits via `state.failed`
and reports the error through `on_ready(err)` — NEVER throws, NEVER blocks, NEVER spawns twice. Includes two
MINIMAL forward-contract stubs (`M._feed` = append-only; `M._reset` = mark-unhealthy) that S5/S6 will replace.

**Deliverable** (ONE source file EDITED + 2 new test files — nothing else is touched):
- **`lua/pi-bridge/shell.lua`** — APPEND to the module S2 created: `M.ensure(on_ready)` (~40-55 lines) +
  `M._feed(chunk)` stub (~5 lines) + `M._reset()` stub (~10 lines), inserted BEFORE the existing `return M`.
  Zero `vim.uv.spawn`; zero `vim.notify`; zero edits to S2's existing functions/state literal.
- **`tests/shell_ensure_smoke.lua`** — plenary-FREE smoke (mirror `tests/shell_smoke.lua`/`notify_smoke.lua`):
  exercises ensure's lifecycle matrix (first-spawn, cached-reuse, spawn-error, no-driver, disabled-driver,
  failed-short-circuit, config pass-through, nil-config, session_cwd pass-through, never-throws, read_start
  wiring → _feed/_reset) with a FAKE driver injected into `package.loaded`. Prints `SMOKE_PASS`; exit 0.
- **`tests/shell_ensure_spec.lua`** — plenary/busted spec (mirror `tests/shell_spec.lua`/`notify_spec.lua`):
  the same matrix as focused `it(...)` cases with field-by-field asserts + before/after_each save/restore.

**Success Definition**:
- `require("pi-bridge.shell").ensure` is a function. First call with a present fake driver spawns (stores
  proc/stdin/stdout/shell/driver in `state`, wires `stdout:read_start`, passes `{shell, cwd, startup_timeout_ms}`
  to the driver, calls `on_ready(nil)`).
- A second call (state.proc set) reuses — the driver's `start` is NOT called again; `on_ready(nil)` is called
  immediately (the "subsequent calls are instant" contract).
- A spawn error (driver cb returns err) sets `state.driver=nil` AND `state.failed=true`, calls `on_ready(err)`;
  a follow-up call short-circuits via `failed` (`on_ready("daemon disabled")`) with NO resolve/pick/start.
- A no-driver path (unknown/disabled shell) sets `state.failed=true`, calls `on_ready("no driver for "..shell)`;
  follow-up short-circuits via `failed`.
- `M._feed(chunk)` appends to `state.rx_buf`; `M._reset()` sets `state.failed=true` + nils proc/pipes (the EOF
  path). Both are exported on M (S5/S6 replace them).
- `shell_ensure_smoke` prints `SMOKE_PASS` (exit 0); `shell_ensure_spec` green (0 fail, 0 error).
- `shell_spec` (S2), `completion_spec`, `bridge_handshake_spec`, `init_spec`, `notify_smoke` stay green (S3 is
  purely additive over S2's module).
- NO file under `extension/`, `doc/`, `ftplugin/`, `plugin/`, `completion.lua`, `bridge.lua`, `init.lua`,
  `notify.lua`, or `README.md` is modified. NO `shell/*.lua` driver is created (P2.M2/P2.M3). NO real subprocess
  is spawned (fake driver in tests).

## User Persona (if applicable)

**Target User**: the implementer of **P2.M1.T2.S4** (`request(line,cursor,after,cb)` — the framed protocol +
gen-guard bump). S4's `request` calls `M.ensure(cb)` FIRST — when ensure reports ready (proc cached), S4 bumps
`state.gen`, sets `state.pending_cb`, and writes the framed `__PIREQ__` line to `state.stdin`. Secondary
consumers: `:checkhealth pi-bridge` (P2.M3.T6.S2) reads `state.failed` + `state.shell`/source; the VimLeavePre
teardown (P2.M3.T6.S3) will call `M.teardown()` (S6) which reuses the proc/pipes ensure cached.

**Use Case**: at first `!`-line activation, completion routing (P2.M2.T3) needs the daemon UP before it can
issue a completion request. `ensure(on_ready)` is the single idempotent entry point: spawn-if-needed, then
proceed. Because spawning sources the user's rc + completion library (100ms–1s+), it happens ONCE and the proc
stays alive for the session — exactly the fzf-tab / zsh-capture-completion persistent-subshell pattern (§17.5).

**Pain Points Addressed**: without S3, S4's `request` would have to inline shell resolution + driver lookup +
spawn orchestration + the failed/proc cache + read_start wiring — one tangled, untestable function (a real
spawn can't be unit-tested). S3 isolates the ORCHESTRATION (trivially testable with a fake driver: first-spawn
/ cached-reuse / error / no-driver / failed-short-circuit) from the IMPURE spawn itself (the driver's job,
integration-proven by the S1 spike).

## Why

- **It is the explicit §17.16 step-22 spawn half.** PRD §17.16 orders Phase 6: *(21) Spike → ✔ → (22)
  `shell.lua` daemon manager: resolution, spawn/teardown, framed protocol, gen-guard supersession*. S2 was the
  **resolution + state** half; S3 is the **spawn** half of step 22 (S4/S5/S6 are request/feed/teardown). The
  driver-delegation design (vs inlining spawn) is exactly what the §17.5.2 skeleton specifies.
- **Consumes the S2 contract cleanly, ZERO file conflict.** S2 OWNS `shell.lua`'s state + resolution helpers.
  S3 APPENDS `ensure` + two stubs to the SAME file (the only edit is insertion before `return M`). S4 owns
  `request`; S5 owns `_feed`; S6 owns `teardown`/`_reset`. No overlap.
- **Delegation is the right layering.** Each shell (fish/zsh/bash) spawns differently (fish: `-i
  --init-command=source <startup.fish>`; zsh: a `zle` widget + `compinit`; bash: `COMP_*` + `compgen`).
  Centralizing spawn in `ensure` would force per-shell branching into `shell.lua` — wrong layer. The driver
  owns spawn; `ensure` owns lifecycle/cache/failure. (research §3 D1.)
- **The `state.failed` short-circuit is a correctness + UX requirement.** §17.12: "menu simply never opens
  for `!` lines" + "no auto-respawn in v1". Without `failed`, a broken daemon (missing binary / bad rc / unknown
  shell) would re-attempt resolve→pick→spawn (5s timeout!) on EVERY keystroke. `failed=true` makes the second
  attempt a sub-microsecond no-op. (research §3 D2.)
- **Fake-driver tests give full lifecycle coverage WITHOUT a real shell.** The spawn risk was retired by S1's
  spike. S3's logic (cache key = `state.proc`; failed short-circuit; driver delegation; config pass-through) is
  pure orchestration — exhaustively testable with an injected fake driver + fake pipes. (research §5.)

## What

**User-visible behavior**: none at runtime (no caller wires `shell.lua` into the plugin yet — completion routing
is P2.M2.T3). The observable artifact is the module's `ensure`/`_feed`/`_reset` API + the test verdicts:

```bash
$ timeout 60 nvim --headless --clean -u NORC -c 'set rtp+=.' +"luafile tests/shell_ensure_smoke.lua" +qa
SMOKE_PASS
$ echo "exit=$?"
exit=0
```

**Technical requirements** (all in `lua/pi-bridge/shell.lua` unless noted):
- **`M.ensure(on_ready)`** (the §17.5.2 skeleton, verbatim logic + the S3 hardening):
  1. `if state.failed then return on_ready("daemon disabled") end` — short-circuit (daemon previously
     crashed / permanently disabled). NO state mutation, NO resolve/pick/start.
  2. `if state.proc then return on_ready(nil) end` — already running (cache key = `state.proc`, set only on
     success; NOT `state.driver`, which is set before spawn). Contract point 4 ("subsequent calls instant").
  3. Read config FRESH (defensive — S2 GOTCHA #2): `local pi = require("pi-bridge"); local cfg = (pi.config
     and pi.config.shell) or {}`.
  4. `local resolved, source = M.resolve_shell(cfg.prefer or "pi")` (S2). Store `state.shell = resolved`.
  5. `state.driver = M.pick_driver(resolved)` (S2). If `state.driver == nil` → set `state.failed = true`;
     `return on_ready("no driver for " .. tostring(resolved))`.
  6. Build opts: `local opts = { shell = resolved, cwd = M.session_cwd(), startup_timeout_ms =
     cfg.startup_timeout_ms or 5000 }`.
  7. Delegate (pcall'd — D4): `local ok, spawn_err = pcall(state.driver.start, opts, function(err, proc,
     stdin, stdout) ... end)`. If `not ok` → `spawn_err` is a thrown error; treat as spawn failure (D2b).
  8. The driver's cb: if `err` (or `not ok`) → `state.driver = nil; state.failed = true; return on_ready(err
     or tostring(spawn_err))`. Else → `state.proc, state.stdin, state.stdout = proc, stdin, stdout; state.cwd
     = opts.cwd;` pcall `stdout:read_start(function(_, chunk) if chunk then M._feed(chunk) else M._reset()
     end end)`; `on_ready(nil)`.
  9. NEVER throws: guard `on_ready` type (`if type(on_ready)~="function" then ... end`); every luv/driver call
     pcall'd.
- **`M._feed(chunk)` stub** (forward contract for S5): `state.rx_buf = state.rx_buf .. (chunk or "")`.
  Documented as the seam S5 will replace with sentinel slicing + `vim.json.decode` + normalize → `pending_cb`.
- **`M._reset()` stub** (forward contract for S6; the §17.12 EOF path): `state.failed = true; state.proc = nil;
  state.stdin = nil; state.stdout = nil; state.driver = nil; state.rx_buf = ""`. Documented as the seam S6's
  `teardown()` will extend (prepend `uv.process_kill` + `pipe:read_stop()`+`:close()`; on EOF the proc is
  already dead so kill is moot, but pipe-close matters for real handles).

### Success Criteria

- [ ] `lua/pi-bridge/shell.lua` exposes `M.ensure`, `M._feed`, `M._reset` as functions (appended to S2's
      `M.resolve_shell`/`M.pick_driver`/`M.session_cwd`/`M.reset`); `return M` is preserved at EOF.
- [ ] First `ensure(cb)` with a present fake driver: spawns (state.proc/stdin/stdout/shell/driver set),
      `stdout:read_start` wired (cb captured), opts `{shell, cwd, startup_timeout_ms}` passed to the driver,
      `cb(nil)` called.
- [ ] Second `ensure(cb)` with `state.proc` set: driver's `start` NOT called again; `cb(nil)` called
      immediately (the cache/reuse path).
- [ ] Spawn error (driver cb `err` non-nil, OR `driver.start` throws): `state.driver==nil` AND
      `state.failed==true`; `cb(err)` called. Follow-up `ensure` short-circuits via `failed`
      (`cb("daemon disabled")`) — NO resolve/pick/start.
- [ ] No driver (unknown/disabled shell): `state.failed==true`; `cb("no driver for "..shell)`. Follow-up
      short-circuits via `failed`.
- [ ] Config pass-through: `config.shell.prefer` honored; `config.shell.startup_timeout_ms` passed to the
      driver (NOT the 5000 default when set). Nil `config` does not throw (uses defaults).
- [ ] `_feed(chunk)` appends to `state.rx_buf`; `_reset()` sets `failed=true` + nils proc/pipes. Both exported.
- [ ] `shell_ensure_smoke` prints `SMOKE_PASS` (exit 0); `shell_ensure_spec` green (0 fail, 0 error).
- [ ] `shell_spec` (S2), `completion_spec`, `bridge_handshake_spec`, `init_spec`, `notify_smoke` stay green.
- [ ] NO edit to `extension/*`, `doc/*`, `ftplugin/*`, `plugin/*`, `completion.lua`, `bridge.lua`, `init.lua`,
      `notify.lua`, or `README.md`. NO `shell/*.lua` created. NO real subprocess spawned. NO `vim.uv.spawn` /
      `vim.notify` / `notify.once` CALL in S3 (header references only).

## All Needed Context

### Context Completeness Check

_Passes "No Prior Knowledge":_ an implementer who has never seen this repo gets (a) the verbatim §17.5.2
reference skeleton (the `ensure` body + the read_start callback + the `_feed`/`_reset`/`teardown` comment),
(b) the EXACT S2 helper signatures + state literal this PRP consumes (treats S2's PRP as a contract), (c) the
EXACT driver `start(opts, on_ready)` contract this PRP introduces (opts fields + cb signature + who owns the
timer/spawn), (d) the canonical real `uv.spawn`+pipe+read+teardown example (`tests/shell_fish_spike.lua`) so the
driver contract is concrete, (e) the module to mirror (`completion.lua` — state/cache/reset/fresh-read/lazy-
require), (f) the two test files to mirror (`shell_smoke.lua`/`notify_smoke.lua` + `shell_spec.lua`/
`notify_spec.lua`) with the fake-driver + fake-pipe injection recipes, (g) the locked design decisions (spawn
delegation, `failed` on both terminal paths, stubs for S5/S6, pcall discipline, `state.proc` cache key), and
(h) the scope fence (what NOT to build: no spawn, no timer, no framed request, no parsing, no notify). The
genuine judgment calls (does no-driver set `failed`? do stubs get exported? does a thrown `driver.start` set
`failed`?) are decided in Design Decisions §1-§7 + Anti-Patterns.

### Documentation & References

```yaml
# MUST READ — the spec (reproduced in this PRP's <selected_prd_content>)
- docfile: PRD.md
  why: "§17.5.2 gives the shell.lua reference skeleton (the EXACT ensure() body + the read_start callback + the _feed/_reset/teardown comment). §17.12 gives the failure-model contract (spawn failure → degrade + ONE notify; EOF → _reset + mark unhealthy + no auto-respawn in v1; N parse fails → disabled). §17.13 confirms the daemon is a CHILD OF NVIM (local pipes; not network-exposed; not pi's child). §17.4.2 confirms driver selection (basename → module; user-disable). §17.11 gives the config block shape (not yet in init.lua — P2.M3.T6.S1; S3 defaults it)."
  section: "h3.34 (§17.5 + §17.5.2 skeleton), h4.4 (§17.5.2 skeleton), h3.40 (§17.11 config), h3.41 (§17.12 failure modes), h3.42 (§17.13 security)"
  critical: "The skeleton's ensure() LITERALLY calls state.driver.start({shell,cwd,startup_timeout_ms}, cb) — spawn is DELEGATED. startup_timeout_ms is passed THROUGH (the timer lives in the driver, not ensure). The read_start cb is `function(_, chunk) if chunk then M._feed(chunk) else M._reset() end end` — S3 wires it EXACTLY; _feed (S5) + _reset (S6) are the seams. The skeleton writes `require(\"pi-bridge\").config.shell or {}` — this THROWS if config is nil; S3 uses the defensive `(pi.config and pi.config.shell) or {}` (S2 GOTCHA #2)."

# MUST READ — the IMMEDIATE contract (S2 produces this; S3 appends to its module)
- file: plan/002_d23d7473c16c/P2M1T2S2/PRP.md
  why: "defines the EXACT module S3 edits: the `local state = { proc, stdin, stdout, rx_buf=\"\", gen=0, inflight=false, shell, driver, cwd, pending_cb=nil, failed=false }` literal; `M.resolve_shell(prefer)->(shell,source)` (PARAM, pure, never-throws); `M.pick_driver(resolved_shell)->table|nil` (EXPORTED; basename→require; disabled/unknown→nil); `M.session_cwd()->string|nil` (server_info.cwd→descriptor.cwd→nil); `M.reset()`. S3 APPENDS ensure+_feed+_reset BEFORE `return M`. S3 REUSES these 4 helpers verbatim — does NOT redefine them."
  critical: "S2's GOTCHAs are INHERITED by S3: #1 lazy require INSIDE functions (never module-top); #2 defensive config read `(pi.config and pi.config.shell) or {}`; #4 string:gsub returns 2 values (assign to local first); #6 no lua linter; #7 exported-on-M idiom; #8 fake-driver injection via `package.loaded[\"pi-bridge.shell.fish\"]`. S2's Design Decision #4 declares state.failed + state.pending_cb as S3/S4 scaffolding — S3 now SETS state.failed."

# MUST READ — the canonical REAL uv.spawn example (verified working, in-repo)
- file: tests/shell_fish_spike.lua
  why: "the SINGLE best reference for the luv API shape the DRIVER will use: uv.new_pipe(false)×3; uv.spawn(path,{args,stdio={in,out,err}},on_exit)->(handle,err); stdout:read_start(function(rerr,data)) with data==nil ⇒ EOF; stdin:write(data); teardown = uv.process_kill(handle,\"sigkill\") + each pipe:close() guarded by is_closing(). S3 does NOT call these (the driver does) — but S3's fake driver + fake pipes in tests mirror this shape so the read_start/close/is_closing methods exist. pcall EVERY uv call."
  pattern: "the proven spawn+pipe+read+write+teardown sequence; the `function(rerr, data) if rerr then...; if data then...; else --EOF end end` read_start cb signature."
  gotcha: "the spike is ALREADY E5560-safe: it calls only io.stderr:write + string ops inside read_start (NOT vim.api). nvim_echo runs post-vim.wait on the main loop. ⇒ S3's read_start cb (which calls M._feed → string/state ops) is fast-context-safe WITHOUT vim.schedule; the eventual menu call is S5's job to vim.schedule. (`:help E5560`.)"

# MUST READ — the module to MIRROR (PRD §17.5.2 says shell.lua "MIRRORS completion.lua's two-layer design")
- file: lua/pi-bridge/completion.lua
  why: "(1) the [Mode A] header style (S2 already copied it to shell.lua — S3's functions get JSDoc blocks in the same style). (2) the state singleton + the cache/reset seam (M.reset). (3) the lazy `require(\"pi-bridge\").bridge` INSIDE functions (S3 does the same for config/descriptor). (4) the pcall-everything, never-throws discipline. (5) the fire-and-forget cb style (ensure's on_ready mirrors do_refresh's bridge cb: store state, call a seam, never throw)."
  pattern: "lazy require INSIDE the fn; pcall every external call; guard cb type; set state in the async cb; return nothing (communicate via cb)."
  gotcha: "completion.lua's cancel_timer does stop()+close() on timers (the libuv `stop()≠close()` invariant — fundamental, NOT nvim-version-specific). S3 builds NO timer (the driver owns startup_timeout_ms); but the discipline applies to S6's teardown later."

# MUST READ — local research notes (verified facts + the 7 locked design decisions + the failed lifecycle)
- docfile: plan/002_d23d7473c16c/P2M1T2S3/research/notes.md
  why: "§0 the task-boundary fence (S3 vs S2/S4/S5/S6/drivers/notify/health). §1 the INPUT contracts (S2 helpers, the driver start() contract, config/descriptor, notify). §2 the canonical real example (the spike) + the verified luv facts + the researcher's 2 corrections (spike is E5560-safe; no nvim-0.12-specific timer leak). §3 the 7 locked design decisions (D1 delegate spawn; D2 failed on BOTH paths; D3 stubs for S5/S6; D4 pcall start+read_start; D5 proc cache key; D6 fresh reads; D7 cb-only return). §4 the state.failed lifecycle diagram (set by S3/S5/S6; read by health). §5 the testing strategy + fake-driver/fake-pipe recipes + the 12 mandated cases. §6 the 13 gotchas. §7 the forward contracts. §8 references."

# SUPPORTING — the dedup notify mechanism (S3 references in HEADER only; does NOT call)
- file: lua/pi-bridge/notify.lua
  why: "M.once(category, level, msg) — vim.schedule-wrapped + dedup by category. S3's header documents that the §17.12 one-time degrade notify (category e.g. \"shell-daemon\") is P2.M2.T3.S4's job; S3 only sets state.failed (the FACT). Confirms S3 has ZERO notify.once calls."
  pattern: "the one-responsibility-per-module + vim.schedule-from-fast-context idiom (S5's _feed will need the same when it routes to the menu)."

# SUPPORTING — the get_shell_info source (consumed by S2's resolve_shell via descriptor_shell; S3 calls session_cwd)
- file: lua/pi-bridge/bridge.lua
  why: "L884-899 M.get_shell_info() -> {shell,shellSource,shellPath}|nil (fresh table; never throws). L180-191 M.server_info (cwd field; set post-handshake). S3 reads neither directly — it calls M.session_cwd() (S2) which reads server_info.cwd→descriptor.cwd. Listed so the implementer knows the cwd opts field originates here."

# SUPPORTING — the config + descriptor source (S3 defensive-reads config.shell)
- file: lua/pi-bridge/init.lua
  why: "L42-44 M.config (nil until setup(); the shell={} block is P2.M3.T6.S1 — NOT yet present). L94-115 M.descriptor (set by activate(); .cwd required, .shell optional). S3 reads (pi.config and pi.config.shell) defensively."

# SUPPORTING — architecture research (confirms the skeleton + failure model + phasing)
- docfile: plan/002_d23d7473c16c/architecture/research-prd-section-17.md
  why: "§17.5.2 (L138-185) the shell.lua skeleton + the ensure() body. §17.12 (L413-419) the failure model (spawn fail → degrade+notify; EOF → _reset+unhealthy+no-respawn; N parse fails → disabled). §17.16 (L448+) the phasing (step 22 = the daemon manager). Confirms the driver-delegation design + the no-auto-respawn v1 contract."
  section: "§17.5.2, §17.12, §17.16"
```

### Current Codebase tree (relevant slice)

```bash
lua/pi-bridge/
├── shell.lua          # ← S2 CREATES this (state + resolve_shell + pick_driver + session_cwd + reset).
│                      #   S3 APPENDS ensure + _feed + _reset here (insert before `return M`).
├── completion.lua     # READ-ONLY — the module to MIRROR (state/cache/reset/lazy-require/pcall style).
├── bridge.lua         # READ-ONLY — M.get_shell_info() + M.server_info.cwd (consumed via S2's session_cwd).
├── init.lua           # READ-ONLY — M.config (nil until setup) + M.descriptor (cwd + optional shell*).
└── notify.lua         # READ-ONLY — M.once dedup (S3 header-only reference; NOT called in S3).
lua/pi-bridge/shell/   # DOES NOT EXIST YET — P2.M2.T4 (fish) / P2.M3.T5 (zsh/bash) create the drivers.
                      #   ensure delegates to driver.start; pick_driver pcall-requires them → nil until then.
                      #   S3 tests inject a FAKE driver into package.loaded (no real subprocess).
tests/
├── shell_fish_spike.lua  # READ-ONLY — the canonical real uv.spawn example (the driver contract shape).
├── notify_smoke.lua      # READ-ONLY — the smoke convention S3's smoke mirrors.
├── notify_spec.lua       # READ-ONLY — the spec convention S3's spec mirrors.
├── completion_spec.lua   # READ-ONLY — the pi.bridge=fake + self-sufficient-setup injection idiom.
└── (shell_ensure_smoke.lua, shell_ensure_spec.lua)   # ← S3 CREATES both
# (S2's shell_smoke.lua / shell_spec.lua also exist after S2 lands — S3's tests are SIBLINGS, not replacements.)
```

### Desired Codebase tree with files to be added/edited

```bash
lua/pi-bridge/shell.lua            # EDIT — APPEND M.ensure + M._feed + M._reset (before `return M`). ~+55-70 lines.
tests/shell_ensure_smoke.lua       # NEW — plenary-FREE smoke (the ensure lifecycle matrix; fake driver). SMOKE_PASS.
tests/shell_ensure_spec.lua        # NEW — plenary/busted spec (the same matrix as it(...) cases).
# (NO other file is created or modified.)
```

### Known Gotchas of our codebase & Library Quirks

```lua
-- CRITICAL (AGENTS.md HARD RULE): run tests via `+"luafile tests/shell_ensure_smoke.lua" +qa` (a FILE on disk).
-- NEVER pipe a heredoc into nvim's stdin (`nvim ... +"luafile /dev/stdin" +qa <<EOF` HANGS the session —
-- ~10 killed sessions in this repo). Wrap every nvim in `timeout` (a hung headless nvim blocks the turn).

-- GOTCHA #1 — ZERO vim.uv.spawn in S3. ensure DELEGATES to state.driver.start(opts, cb). The spawn + the
-- startup_timeout_ms timer live INSIDE the driver (fish = P2.M2.T4.S1). Adding uv.spawn in ensure would
-- bypass the per-shell driver layer (wrong) + break the fake-driver tests. (research §3 D1 / §6 G5.)

-- GOTCHA #2 — DEFENSIVE config read. `require("pi-bridge").config.shell or {}` THROWS if `config` is nil
-- (indexing nil; M.config is nil until setup() + the shell={} block is P2.M3.T6.S1 — NOT yet present).
-- Use `local pi = require("pi-bridge"); local cfg = (pi.config and pi.config.shell) or {}`. (S2 GOTCHA #2.)

-- GOTCHA #3 — CACHE KEY is state.proc, NOT state.driver. The "already running" guard `if state.proc then
-- return on_ready(nil) end` keys on proc (set ONLY on a successful spawn). state.driver is set BEFORE spawn
-- (step 5) — keying on it would false-positive "ready" if a second ensure fires mid-spawn. (research §3 D5.)

-- GOTCHA #4 — pcall state.driver.start AND stdout:read_start. driver.start is a Lua fn (a buggy driver must
-- not abort ensure); read_start is a genuine luv call on the handle the driver returned (could be malformed).
-- A throw from EITHER is a spawn error (D4): set failed=true + driver=nil + on_ready(err). (research §3 D4.)

-- GOTCHA #5 — state.failed on BOTH terminal paths (no-driver AND spawn error). Without it, every keystroke
-- on a ! line re-runs resolve→pick→spawn (5s timeout) for a permanently-broken daemon. §17.12 "menu never
-- opens for ! lines" + "no auto-respawn in v1". (research §3 D2.)

-- GOTCHA #6 — _feed/_reset are EXPORTED STUBS (forward contracts for S5/S6). S3 ships MINIMAL versions:
-- _feed appends to rx_buf; _reset sets failed=true + nils proc/pipes (EOF path). S5 replaces _feed (full
-- sentinel parsing); S6 extends _reset into teardown (kill+close). Do NOT implement parsing/pipe-close in S3.
-- Export them so S5/S6 replace via `M._feed = ...` AND tests can assert the read_start route. (research §3 D3.)

-- GOTCHA #7 — LAZY `require("pi-bridge")` INSIDE ensure, NEVER at module top. The handshake is ASYNC
-- (pi.bridge nil at first-require); tests swap fakes AFTER require. Caching breaks both. Also avoids a
-- circular-load hazard. (S2 GOTCHA #1 — inherited.)

-- GOTCHA #8 — the read_start callback runs on the libuv loop (FAST CONTEXT). S3's chain touches NO vim.api.*
-- (only state writes + luv calls + string ops in _feed) → NO vim.schedule needed. The eventual menu call is
-- S5's _feed→pending_cb→cb→menu — S5 must vim.schedule THAT hop (`:help E5560`). The spike is already safe
-- (io.stderr:write only, not vim.api). (research §2 / §6 G9.)

-- GOTCHA #9 — FAKE DRIVER injection via package.loaded. pick_driver does `pcall(require, "pi-bridge.shell.
-- <base>")` — require checks package.loaded FIRST. Inject `package.loaded["pi-bridge.shell.fish"] = fake_drv`
-- BEFORE ensure; nil it in after_each. resolve_shell must yield a "fish" basename → set bridge.get_shell_info
-- to {shell="/usr/bin/fish"} OR pass prefer="/usr/bin/fish" via config.shell.prefer. (S2 GOTCHA #8.)

-- GOTCHA #10 — the fake driver's start calls cb SYNCHRONOUSLY. So ensure(cb) completes fully before returning
-- — NO vim.wait needed (unlike the spike, which drives a REAL async fish). Mirror completion_spec's sync fakes
-- for determinism. (research §5.)

-- GOTCHA #11 — TAB indentation throughout (match completion.lua/bridge.lua/init.lua/S2's shell.lua). Every new
-- line uses tabs. (S2 GOTCHA #5 — inherited.)

-- GOTCHA #12 — no lua linter/formatter (no luacheck/selene/stylua/.luarc). The ONLY "type" surface is the
-- luaemmy `---@` annotations (lua-language-server, NOT runtime-enforced). Validation = the smoke + spec.
-- (S2 GOTCHA #6 — inherited.)

-- GOTCHA #13 — S3 EDITS shell.lua (APPENDS before `return M`), it does NOT create it. S2 created it. Do NOT
-- touch S2's state literal / resolve_shell / pick_driver / session_cwd / reset / the [Mode A] header. Insert
-- ensure + _feed + _reset AFTER reset, BEFORE `return M`. (research §6 G13.)

-- GOTCHA #14 — NO notify.once CALL in S3. The §17.12 one-time degrade notify is P2.M2.T3.S4. S3 sets
-- state.failed (the FACT); references notify.lua in the HEADER only. (S2 GOTCHA #12 / research §6 G8.)

-- GOTCHA #15 — ensure RETURNS NOTHING; communicates via on_ready(err|nil). Node-style cb. Do NOT `return
-- proc` or `return err` (S4 passes its own cb as on_ready; it ignores any return value). (research §3 D7.)
```

## Implementation Blueprint

### Design Decisions (READ FIRST)

**1. S3 DELEGATES spawn to `state.driver.start`; it does NOT call `vim.uv.spawn`.** The §17.5.2 skeleton's
`ensure` calls `state.driver.start({...}, cb)`. Each shell spawns differently (fish/zsh/bash), so spawn belongs
in the per-shell driver, not in shell.lua. `startup_timeout_ms` is passed THROUGH to the driver (the timer lives
in the driver, which owns the spawn lifecycle). S3 has zero `uv.spawn` + zero `uv.new_timer`. Verified against
the skeleton + the item contract point 1 ("delegates to driver.start() which spawns"). (research §3 D1.)

**2. `state.failed=true` is set on BOTH terminal paths (no-driver AND spawn error).** §17.12: "menu simply
never opens for `!` lines" + "no auto-respawn in v1". A broken spawn (missing binary, bad rc) or a permanently-
driverless shell (unknown/disabled) will NOT fix itself mid-session. Without `failed`, every keystroke re-runs
resolve→pick→(spawn→5s timeout) — catastrophic. So `ensure` sets `failed=true` on (a) no-driver AND (b) spawn
error (driver cb `err` non-nil OR `driver.start` threw). The top-of-ensure `if state.failed` short-circuit is
the fast no-op path. This matches S2's `state.failed` doc ("set by S3 ensure() on permanent spawn failure ...
ensure() won't retry; health reports it"). The degrade NOTIFY is P2.M2.T3.S4 — S3 sets only the FACT.
(research §3 D2.)

**3. S3 WIRES `stdout:read_start` with the LITERAL skeleton callback; ships `_feed` + `_reset` STUBS.** The
skeleton's read_start cb is `function(_, chunk) if chunk then M._feed(chunk) else M._reset() end end`. `_feed`
is S5; `_reset`/teardown is S6. S3 ships minimal stubs so the wiring is complete + safe (a stray chunk/EOF
during S3's window degrades to a no-op, never errors): `_feed` appends to `rx_buf`; `_reset` sets `failed=true`
+ nils proc/pipes (the §17.12 EOF mark-unhealthy path). Both EXPORTED on M (so S5/S6 replace via `M._feed=...`
and tests assert the route). This mirrors S2's "declare the seam + document it" pattern for state.gen/
pending_cb/failed. (research §3 D3.)

**4. `pcall` discipline — ensure pcalls `driver.start` AND `stdout:read_start`.** Contract point 3: "Every uv
call pcall'd." `driver.start` is a Lua fn (a buggy driver must not abort ensure); `read_start` is a luv call on
the handle the driver returned (could be malformed). A throw from either = spawn error (D2b: failed=true,
driver=nil, on_ready(err)). The resolution helpers (resolve_shell/pick_driver/session_cwd) are already never-
throws (S2). (research §3 D4.)

**5. `state.proc` is the "already running" cache key (NOT state.driver).** The skeleton: `if state.proc then
return on_ready(nil) end`. `proc` is set ONLY on a successful spawn; `driver` is set BEFORE spawn (step 5) —
keying on `driver` would false-positive "ready" if a second ensure fires mid-spawn. Contract point 4 ("subsequent
calls instant") = this guard. (research §3 D5.)

**6. ensure re-reads config + bridge + descriptor FRESH (never caches at module load).** Mirrors completion.lua
+ S2. `require("pi-bridge")` INSIDE ensure (async handshake; tests swap fakes after require). (research §3 D6 /
S2 GOTCHA #1.)

**7. ensure returns NOTHING; communicates via `on_ready(err|nil)`.** Node-style cb. `on_ready(nil)` on
success/cached-ready; `on_ready(err_string)` on every failure. S4's `request` passes its own cb. (research §3 D7.)

### Data models and structure

S3 does NOT introduce new runtime types — it consumes S2's `state` (a `pi-bridge.ShellState`) + adds three
functions. The only NEW contract is the **driver `start(opts, on_ready)` signature** (this is what the fish
driver P2.M2.T4.S1 will implement; S3's fake driver in tests mirrors it):

```lua
--- The opts table ensure passes to driver.start (the spawn delegation contract; PRD §17.5.2).
---@class pi-bridge.shell.DriverStartOpts
---@field shell              string         The resolved shell path (from M.resolve_shell; §17.4).
---@field cwd                string|nil      The session cwd (from M.session_cwd; nil acceptable).
---@field startup_timeout_ms integer         Cold-start budget ms (default 5000; the DRIVER owns the timer).

--- The cb signature ensure passes to driver.start. On success the driver calls cb(nil, proc, stdin, stdout);
---   on failure (binary missing / rc error / timeout) it calls cb(err, nil, nil, nil) AND tears down its own
---   half-spawned handles. proc/stdin/stdout are luv userdata handles (the spike's uv.spawn/new_pipe shapes).
---@alias pi-bridge.shell.DriverReady fun(err:string|nil, proc:userdata|nil, stdin:userdata|nil, stdout:userdata|nil)
```

S3 SETS these `state` fields (declared by S2): `proc, stdin, stdout` (from the driver cb), `shell, driver`
(from resolve/pick), `cwd` (from session_cwd), `failed` (on terminal failure), and `rx_buf` (via the `_feed`
stub). S3 does NOT touch `gen, inflight, pending_cb` (S4/S5).

### Implementation Tasks (ordered by dependencies)

```yaml
Task 1: READ S2's shell.lua (the contract) + the spike + completion.lua
  - READ lua/pi-bridge/shell.lua (S2's output): confirm `local state = {...}` has the 11 fields (proc, stdin,
    stdout, rx_buf="", gen=0, inflight=false, shell, driver, cwd, pending_cb=nil, failed=false); confirm
    M.resolve_shell / M.pick_driver / M.session_cwd / M.reset exist + are never-throws; confirm the file ends
    with `return M`. (If S2 hasn't landed yet, treat its PRP as the contract — the file WILL have this shape.)
  - READ tests/shell_fish_spike.lua: internalize the uv.spawn+pipe+read+teardown sequence (the driver will do
    this; S3's fake driver/pipes mirror it: read_start/write/close/is_closing methods).
  - READ lua/pi-bridge/completion.lua (skim the [Mode A] header + M.reset + the lazy-require + pcall style):
    the conventions S3's ensure follows.

Task 2: APPEND M.ensure(on_ready) to lua/pi-bridge/shell.lua (insert BEFORE `return M`)
  - WRITE the JSDoc block (mirror completion.lua's function docs): "The §17.5.2 spawn layer. Idempotent
    lifecycle entry: spawn-if-needed (via driver.start) then cache. Short-circuits on state.failed (daemon
    previously crashed) and state.proc (already running). Sets state.failed on no-driver + spawn error.
    NEVER throws (pcall driver.start + read_start; guard on_ready type). Returns nothing (cb-only)."
  - IMPLEMENT per Design Decisions §1-§7 + the What §technical-requirements steps 1-9. Use the Reference
    implementation block F below (the exact body).
  - DO NOT: call vim.uv.spawn / uv.new_timer (D1). Do NOT call notify.once (D2/GOTCHA #14). Do NOT key the
    cache on state.driver (D5/GOTCHA #3). Do NOT read config at module top (D6/GOTCHA #7).

Task 3: APPEND M._feed(chunk) stub + M._reset() stub (forward contracts for S5/S6)
  - WRITE M._feed(chunk): `state.rx_buf = state.rx_buf .. (chunk or "")`. JSDoc: "Forward contract for S5
    (sentinel slicing + JSON decode + normalize → pending_cb). S3 ships append-only so read_start wiring is
    complete + a stray chunk never errors. S5 replaces this body."
  - WRITE M._reset(): set state.failed=true; state.proc=nil; state.stdin=nil; state.stdout=nil;
    state.driver=nil; state.rx_buf="". JSDoc: "Forward contract for S6 (teardown). The §17.12 EOF path: shell
    crashed mid-session → mark unhealthy + nil proc/pipes (so the next ensure short-circuits on failed).
    S6's teardown() prepends uv.process_kill + pipe:read_stop()+close() (on EOF the proc is already dead, so
    kill is moot; pipe-close matters for real handles — S6 owns it). Does NOT call M.reset() (that clears
    failed=false; _reset must LEAVE failed=true so ensure short-circuits)."
  - DO NOT: implement sentinel parsing in _feed (S5). Do NOT uv.process_kill/pipe:close in _reset (S6). Do NOT
    call M.reset() from _reset (it would clear failed — WRONG; _reset marks a CRASH, reset is a clean teardown).

Task 4: CREATE tests/shell_ensure_smoke.lua — plenary-FREE smoke (mirror shell_smoke.lua/notify_smoke.lua)
  - WRITE the header doc-comment with the run command: `timeout 60 nvim --headless --clean -u NORC -c 'set
    rtp+=.' +"luafile tests/shell_ensure_smoke.lua" +qa`. Note the AGENTS.md HARD RULE.
  - BOOTSTRAP: `local me = debug.getinfo(1,"S").source:sub(2); local root = vim.fn.fnamemodify(me, ":h:h");
    vim.opt.runtimepath:append(root)`; `local pi = require("pi-bridge"); if pi.config==nil then pi.setup({}) end`;
    `local shell = require("pi-bridge.shell")`.
  - DEFINE the fake driver + fake pipes (see Reference block G). DEFINE `local fails=0; local function
    check(cond,msg) ...`.
  - CASES (each a `check`; see Validation Loop §Level-2-smoke for the full 12-case matrix): first-spawn,
    cached-reuse, spawn-error (+failed +short-circuit), no-driver (+failed), disabled-driver, failed-
    short-circuit, config pass-through (prefer + startup_timeout_ms), nil-config-no-throw, session_cwd
    pass-through, never-throws (ensure(nil)/ensure(123)/driver-throws), read_start→_feed (rx_buf grew),
    read_start→_reset (failed set), stub-exports-present. Use `shell.reset()` between cases to clear state;
    inject/nil `package.loaded["pi-bridge.shell.fish"]`; swap `pi.bridge`/`pi.descriptor` per case; restore.
  - FOOTER: `if fails>0 then io.stderr:write(fails.." check(s) failed\n"); vim.cmd("cquit 1") end;
    io.stdout:write("SMOKE_PASS\n")`.
  - DO NOT: spawn a real subprocess. Do NOT vim.wait (the fake driver calls cb synchronously — GOTCHA #10). Do
    NOT test request/_feed-parsing/teardown (S4/S5/S6).

Task 5: CREATE tests/shell_ensure_spec.lua — plenary/busted spec (mirror shell_spec.lua/notify_spec.lua)
  - WRITE the header doc-comment with the run command (minimal_init + plenary.busted.run).
  - BOOTSTRAP + before_each (save orig_shell/bridge/descriptor/config; nil pi.bridge/pi.descriptor;
    package.loaded["pi-bridge.shell.fish"]=nil; shell.reset()) + after_each (restore all + shell.reset()).
  - CASES: the same 12-case matrix as `it(...)` with `assert.are.equals`/`assert.is_nil`/`assert.is_same`/
    `assert.is_true`/`assert.is_false`. Group under `describe("pi-bridge.shell ensure (P2.M1.T2.S3)", ...)`.
  - DO NOT: spawn subprocess. Do NOT use spec-local `pending` (shadows plenary's skip fn). Do NOT test
    request/_feed/teardown (S4/S5/S6).
```

### Reference implementation

```lua
-- === Block F: M.ensure(on_ready) — APPEND to shell.lua, BEFORE `return M` ===
-- (Tabs throughout. Consumes S2's state + M.resolve_shell/M.pick_driver/M.session_cwd. Delegates spawn to
--  state.driver.start; the timer + uv.spawn live in the driver. Sets state.failed on no-driver + spawn error.)

--- The §17.5.2 spawn layer of the completion daemon. Idempotent lifecycle entry point: spawn-if-needed
--- (via `state.driver.start`) then cache the proc/pipes for the session. Called by S4's `request()` before
--- every framed request (and by completion routing P2.M2.T3 at first `!` activation).
---
--- Short-circuits on `state.failed` (daemon previously crashed / permanently disabled — §17.12 "no
--- auto-respawn in v1") and on `state.proc` (already running — the "subsequent calls are instant" cache).
--- On the spawn path: reads config FRESH (lazy require — async handshake + test mocks), resolves the shell
--- (§17.4 via M.resolve_shell), picks the driver (§17.4.2 via M.pick_driver), and delegates the actual
--- `vim.uv.spawn` to `state.driver.start({shell, cwd, startup_timeout_ms}, cb)`. The `startup_timeout_ms`
--- cold-start timer lives INSIDE the driver (S3 passes it through; it does NOT build a uv timer).
---
--- Sets `state.failed=true` on BOTH terminal paths (no-driver AND spawn error) so a broken daemon does not
--- re-attempt resolve→pick→spawn on every keystroke (§17.12 "menu never opens for ! lines"). The §17.12
--- one-time degrade NOTIFY is P2.M2.T3.S4's job — ensure sets only the FACT (`failed`).
---
--- NEVER throws: `pcall`s `state.driver.start` AND `stdout:read_start` (a buggy/malformed driver or handle
--- degrades to a spawn error); guards `on_ready`'s type; the resolution helpers are already never-throws (S2).
--- The driver's cb may fire from luv fast context — ensure's cb touches NO `vim.api.*` (only state writes +
--- `stdout:read_start` + `on_ready`), so NO `vim.schedule` is needed here (the eventual menu hop is S5's job).
--- Returns NOTHING; communicates via `on_ready(err|nil)` (node-style; S4 passes its own cb).
---
---@param on_ready fun(err:string|nil) Called with nil on success/cached-ready; an err string on every failure.
function M.ensure(on_ready)
	if type(on_ready) ~= "function" then on_ready = function() end end   -- never-throws on a bad arg
	-- (1) Short-circuit: daemon previously crashed / permanently disabled (§17.12 no-respawn-in-v1).
	if state.failed then return on_ready("daemon disabled") end
	-- (2) Cache: already running (proc is set ONLY on a successful spawn — NOT state.driver, which is set
	--     before spawn). Contract point 4 ("subsequent calls are instant").
	if state.proc then return on_ready(nil) end
	-- (3) Read config FRESH (lazy require — async handshake + test mocks; defensive: config.shell may be nil
	--     until P2.M3.T6.S1). ⚠️ NOT `pi.config.shell or {}` (throws if config nil) — use the AND-chain.
	local pi = require("pi-bridge")
	local cfg = (pi.config and pi.config.shell) or {}
	-- (4) Resolve ONE shell (§17.4; consistent with what pi EXECUTES) + (5) pick its driver (§17.4.2).
	local resolved = M.resolve_shell(cfg.prefer or "pi")   -- (shell, source); source unused by ensure (health uses it)
	state.shell = resolved
	state.driver = M.pick_driver(resolved)
	if not state.driver then
		state.failed = true                                 -- permanent: unknown/disabled shell (§17.6.4 degrade)
		return on_ready("no driver for " .. tostring(resolved))
	end
	-- (6) Build the driver opts (the spawn delegation contract; startup_timeout_ms passed THROUGH — the
	--     driver owns the cold-start timer). cwd nil is acceptable (driver may default its own cwd).
	local opts = {
		shell              = resolved,
		cwd                = M.session_cwd(),
		startup_timeout_ms = cfg.startup_timeout_ms or 5000,
	}
	-- (7) Delegate spawn to the driver. pcall so a buggy driver.start (throws vs calls cb with err) degrades
	--     to a spawn error. The driver calls cb from its own (possibly luv) context — our cb is fast-context-safe.
	local ok, spawn_err = pcall(state.driver.start, opts, function(err, proc, stdin, stdout)
		-- (8a) FAILURE: driver reported err (binary missing / rc error / startup timeout). Mark permanently
		--     failed (§17.12) so the next ensure short-circuits — do NOT retry a broken spawn per keystroke.
		if err then
			state.driver = nil
			state.failed = true
			return on_ready(err)
		end
		-- (8b) SUCCESS: cache the handles + cwd; wire stdout:read_start to the _feed/_reset route (the §17.5.2
		--     skeleton callback EXACTLY). pcall read_start (the handle could be malformed).
		state.proc, state.stdin, state.stdout = proc, stdin, stdout
		state.cwd = opts.cwd
		pcall(function()
			stdout:read_start(function(_, chunk)
				if chunk then M._feed(chunk) else M._reset() end   -- data → S5 parse stub; EOF → S6 teardown stub
			end)
		end)
		on_ready(nil)
	end)
	-- (8c) driver.start ITSELF threw (not just called cb with err): treat as spawn error (D4).
	if not ok then
		state.driver = nil
		state.failed = true
		on_ready(tostring(spawn_err))
	end
end
```

```lua
-- === Block G1: M._feed(chunk) stub (forward contract for S5) ===
--- Forward-contract stub for S5: append a stdout chunk to the rx buffer. S5 will REPLACE this body with the
--- full `__PIRESP_START__`/`__PIRESP_END__` sentinel slicing + `vim.json.decode` + AutocompleteItem
--- normalization → the gen-guarded `state.pending_cb`. S3 ships append-only so the read_start wiring ensure
--- installs is complete + a stray chunk during S3's window (before S5 lands) degrades to a no-op, never
--- errors. Runs on the libuv loop (fast context) — S5 must `vim.schedule` the final menu hop (`:help E5560`).
--- NEVER throws (string concat + a table write). Exported so S5 replaces via `M._feed = ...` + tests assert
--- the read_start route.
---@param chunk string? A stdout chunk (nil/"" tolerated).
function M._feed(chunk)
	state.rx_buf = state.rx_buf .. (chunk or "")
end

-- === Block G2: M._reset() stub (forward contract for S6; the §17.12 EOF path) ===
--- Forward-contract stub for S6: the §17.12 EOF-on-daemon-pipe path (shell crashed mid-session). Marks the
--- daemon unhealthy (`state.failed=true`) + nils proc/pipes so the next `ensure` short-circuits via the
--- `failed` guard (no auto-respawn in v1). S6's `teardown()` will REPLACE/EXTEND this: prepend
--- `uv.process_kill(proc, "sigkill")` + `pipe:read_stop()` + `pipe:close()`×3 THEN clear state (on EOF the
--- proc is already dead, so kill is moot; pipe-close matters for real handles — S6 owns it). Does NOT call
--- `M.reset()` (that clears `failed=false`; `_reset` must LEAVE `failed=true` — a CRASH is not a clean exit).
--- Runs on the libuv loop (fast context). NEVER throws (plain table assignments). Exported so S6 replaces it.
function M._reset()
	state.failed = true
	state.proc   = nil
	state.stdin  = nil
	state.stdout = nil
	state.driver = nil
	state.rx_buf = ""
end
```

```lua
-- === Block H: the fake driver + fake pipes for tests (tests/shell_ensure_smoke.lua + _spec.lua) ===
-- Mirrors the luv handle shape from tests/shell_fish_spike.lua (read_start/write/close/is_closing) so the
-- read_start wiring + the teardown-guard methods exist WITHOUT a real subprocess.
local function make_fake_driver()
	local captured = { opts = nil, calls = 0 }
	local function fake_pipe()
		return {
			read_start = function(_, cb) captured.read_cb = cb end,   -- ensure wires this; tests invoke it
			write      = function() end,
			close      = function() end,
			read_stop  = function() end,
			is_closing = function() return false end,
		}
	end
	return {
		captured = captured,
		start = function(opts, cb)
			captured.calls = captured.calls + 1
			captured.opts  = opts                                  -- assert shell/cwd/startup_timeout_ms
			if opts._fail then cb("spawn err: simulated", nil, nil, nil)
			else cb(nil, { is_closing = function() return false end }, fake_pipe(), fake_pipe()) end
		end,
	}
end
-- Inject: package.loaded["pi-bridge.shell.fish"] = fake. resolve_shell must yield a "fish" basename → set
--   pi.bridge = { get_shell_info = function() return { shell = "/usr/bin/fish" } end }
--   OR pi.config.shell.prefer = "/usr/bin/fish". Remove: package.loaded["pi-bridge.shell.fish"] = nil.
```

### Integration Points

```yaml
MODULE STATE (lua/pi-bridge/shell.lua — EDIT, additive append):
  - M.ensure(on_ready)            → NEW public lifecycle entry (spawn-if-needed + cache).
  - M._feed(chunk)                → NEW forward-contract stub (S5 replaces).
  - M._reset()                    → NEW forward-contract stub (S6 replaces/extends).
  - state SET by ensure: proc/stdin/stdout (driver cb), shell/driver (resolve/pick), cwd (session_cwd),
    failed (no-driver/spawn-error), rx_buf (via _feed).

NO EDITS to any existing file:
  - lua/pi-bridge/* other than shell.lua are READ-ONLY (completion.lua = the mirror; bridge.lua = the shell-
    info/cwd source; init.lua = config/descriptor; notify.lua = header-only ref).
  - S2's functions inside shell.lua (state literal, resolve_shell, pick_driver, session_cwd, reset, the [Mode
    A] header) are UNTOUCHED — S3 appends AFTER them, BEFORE `return M`.
  - extension/*, doc/*, ftplugin/*, plugin/* — all UNTOUCHED.
  - NO shell/*.lua driver created (P2.M2.T4 / P2.M3.T5). NO new config key, RPC method, env var, or helpdoc.

FORWARD CONTRACTS (do NOT implement in S3; just expose the stubs + document them):
  - M.request(line,cursor,after,cb) → S4: calls M.ensure(cb), bumps state.gen, sets state.pending_cb, writes
    the framed __PIREQ__ line to state.stdin.
  - M._feed(chunk) [REPLACE]        → S5: sentinel slicing + vim.json.decode + normalize → pending_cb (gen-guarded).
  - M.teardown() / M._reset() [EXTEND] → S6: uv.process_kill SIGKILL + pipe:read_stop()+close()×3 + reset().
  - state.pending_cb / state.gen / state.inflight → S4 (bump + assign + clear).
  - notify.once("shell-daemon", ...) → P2.M2.T3.S4 (the §17.12 one-time degrade notify; S3 sets failed only).
```

## Validation Loop

> Run from the repo root (`/home/dustin/projects/pi-nvim-bridge`). ALWAYS wrap nvim in `timeout`
> (AGENTS.md HARD RULE). No lua linter exists (GOTCHA #12) — the smoke + spec ARE the gate. S3 spawns NO real
> subprocess (fake driver) → no live-shell gate (the fish seam is S1's spike, already gated).

### Level 1: Syntax (the file parses; the symbols exist)

```bash
# 1a. Confirm ensure + the 2 stubs are appended (and S2's exports are intact):
grep -n "function M.ensure\|function M._feed\|function M._reset\|function M.resolve_shell\|function M.pick_driver\|function M.session_cwd\|function M.reset" lua/pi-bridge/shell.lua
# expect: 7 function definitions (S2's 4 + S3's 3). ensure/_feed/_reset are NEW.
grep -n "^return M" lua/pi-bridge/shell.lua              # expect 1 (the EOF; S3 inserted BEFORE it)
grep -n "vim.uv.spawn\|uv.new_timer\|notify.once" lua/pi-bridge/shell.lua   # expect: 0 (S3 delegates; no spawn/timer/notify)
# 1b. Byte-compile the module (catches a syntax error fast; no subprocess):
timeout 30 nvim --headless --clean -u NORC \
  -c 'lua assert(loadfile("lua/pi-bridge/shell.lua"))' -c 'qa' && echo "PARSE_OK exit=$?"
# Expected: PARSE_OK exit=0. If loadfile returns nil + err, READ it: likely a tab/space mix, an unbalanced
#   `end`/`function`, or a typo in ensure. (The `pcall(state.driver.start, opts, cb)` is correct — pcall passes
#   opts + cb as args to start. Do NOT wrap start in an extra function() ... end unless you also forward opts/cb.)
```

### Level 2-smoke: the plenary-FREE smoke (the full ensure lifecycle matrix)

```bash
# 2a. THE gate — run the smoke (prints SMOKE_PASS + exit 0):
timeout 60 nvim --headless --clean -u NORC -c 'set rtp+=.' +"luafile tests/shell_ensure_smoke.lua" +qa
echo "exit=$?"
# Expected: SMOKE_PASS, exit=0.
# The smoke MUST cover (mirror these `check(...)` cases — see Task 4 + research §5):
#   FIRST-SPAWN:     ensure(cb) + fake fish driver            → state.proc/stdin/stdout set; captured.opts.shell
#                    == "/usr/bin/fish"; captured.opts.startup_timeout_ms == 5000 (default); read_cb captured;
#                    state.driver==fake; state.shell=="/usr/bin/fish"; cb(nil); state.failed==false; captured.calls==1
#   CACHED-REUSE:    2nd ensure(cb2) with state.proc set       → captured.calls STAYS 1 (start NOT re-called); cb2(nil)
#   SPAWN-ERROR:     ensure(cb) + opts._fail=true              → state.driver==nil; state.failed==true; state.proc==nil; cb("spawn err...")
#                    FOLLOW-UP ensure(cb2)                      → short-circuits via failed: cb2("daemon disabled"); captured.calls unchanged
#   NO-DRIVER:       ensure(cb) + resolved "/bin/unknownshell" → state.failed==true; state.driver==nil; cb("no driver for /bin/unknownshell")
#                    FOLLOW-UP                                   → short-circuits via failed
#   DISABLED-DRIVER: config.shell.drivers.fish=false           → pick_driver nil → same as no-driver (failed=true, cb err)
#   FAILED-SHORTCIR: preset state.failed=true; ensure(cb)      → cb("daemon disabled"); start NOT called; no state mutation
#   CONFIG-PASS:     config.shell.prefer="/usr/bin/fish"; startup_timeout_ms=2500 → captured.opts.startup_timeout_ms==2500; prefer honored
#   NIL-CONFIG:      pi.config=nil (no setup)                   → ensure does NOT throw; defaults (prefer="pi", timeout 5000)
#   CWD-PASS:        pi.bridge.server_info.cwd="/srv"           → captured.opts.cwd=="/srv"
#   NEVER-THROWS:    ensure(nil), ensure(123), driver whose start THROWS → no error; failed=true on the throw; cb not called when non-fn
#   READ→_FEED:      invoke captured.read_cb(nil,"X")            → state.rx_buf grew by "X" (M._feed stub)
#   READ→_RESET:     invoke captured.read_cb(nil,nil) [EOF]      → state.failed==true; state.proc==nil (M._reset stub)
#   STUB-EXPORTS:    type(shell._feed)=="function"; type(shell._reset)=="function"
# If a check FAILS: re-read the FAIL line; the most common causes are (i) keying the cache on state.driver
#   instead of state.proc (GOTCHA #3), (ii) not setting state.failed on the no-driver path (GOTCHA #5),
#   (iii) reading config at module top or using `pi.config.shell or {}` (GOTCHA #2/#7), (iv) not pcall'ing
#   driver.start so a thrown start aborts the smoke (GOTCHA #4), (v) _reset calling M.reset() (clears failed).
```

### Level 2-spec: the plenary/busted spec (the same matrix, asserted)

```bash
# 2b. THE spec gate — run shell_ensure_spec (expect all pass, 0 fail, 0 error):
timeout 90 nvim --headless --clean -u tests/minimal_init.lua \
  -c 'lua require("plenary.busted").run("tests/shell_ensure_spec.lua")' 2>&1 | tail -8
echo "exit=${PIPESTATUS[0]}"
# Expected: "Success: <N>", "Failed : 0", "Errors : 0", exit 0. (~12-16 cases.)
# If a case fails: re-read its body vs the smoke case it mirrors — the assertion shapes must match
#   (assert.are.equals on opts.shell/startup_timeout_ms/cwd; assert.is_nil/is_truthy on proc/driver; assert.is_true
#   on failed). Verify before_each nils pi.bridge/pi.descriptor + package.loaded["pi-bridge.shell.fish"] AND
#   after_each restores them + calls shell.reset() (so failed/proc don't leak across cases).
```

### Level 3: Regression (the additive append breaks nothing)

```bash
# 3a. S2's own tests stay green (S3 appends to shell.lua; if S2 has landed, its spec must still pass):
timeout 90 nvim --headless --clean -u tests/minimal_init.lua \
  -c 'lua require("plenary.busted").run("tests/shell_spec.lua")' 2>&1 | grep -E 'Success:|Failed :|Errors :' | tr '\n' ' '; echo "(shell_spec / S2)"
# Expected: green (S3 is additive — S2's resolve/pick/cwd/reset are untouched). If S2 hasn't landed yet, skip.
# 3b. The suites that read the files S3 is adjacent to stay green:
timeout 90 nvim --headless --clean -u tests/minimal_init.lua \
  -c 'lua require("plenary.busted").run("tests/completion_spec.lua")' 2>&1 | grep -E 'Success:|Failed :|Errors :' | tr '\n' ' '; echo "(completion_spec)"
timeout 90 nvim --headless --clean -u tests/minimal_init.lua \
  -c 'lua require("plenary.busted").run("tests/bridge_handshake_spec.lua")' 2>&1 | grep -E 'Success:|Failed :|Errors :' | tr '\n' ' '; echo "(bridge_handshake_spec)"
timeout 60 nvim --headless --clean -u tests/minimal_init.lua \
  -c 'lua require("plenary.busted").run("tests/init_spec.lua")' 2>&1 | grep -E 'Success:|Failed :|Errors :' | tr '\n' ' '; echo "(init_spec)"
timeout 60 nvim --headless --clean -u NORC -c 'set rtp+=.' +"luafile tests/notify_smoke.lua" +qa 2>&1 | tail -1; echo "(notify_smoke)"
# Expected: completion_spec green; bridge_handshake_spec 15/0/0; init_spec 14/0/0; notify_smoke SMOKE_PASS.
# (S3 edits shell.lua + adds 2 tests; it touches NOTHING else — these can only fail if you accidentally
#   modified a sibling or S2's functions inside shell.lua.)

# 3c. Isolation — confirm the 3 expected files changed (shell.lua EDITED + 2 tests NEW; no sibling touched):
git status --porcelain
# Expected: ` M lua/pi-bridge/shell.lua`, `?? tests/shell_ensure_smoke.lua`, `?? tests/shell_ensure_spec.lua`.
#   (If shell.lua shows as `??` instead of ` M`, S2 hasn't committed yet — that's fine; treat it as new.)
```

### Level 4: (none — no MCP/Docker/Playwright/web/real-subprocess surface; S3 is pure lua + a fake driver)

## Final Validation Checklist

### Technical Validation

- [ ] Level 1a: ensure + `_feed` + `_reset` are present; S2's 4 exports intact; `return M` at EOF; ZERO
      `vim.uv.spawn`/`uv.new_timer`/`notify.once` (7 + 1 + 0 greps).
- [ ] Level 1b: `lua/pi-bridge/shell.lua` byte-compiles (`PARSE_OK exit=0`).
- [ ] Level 2a: `tests/shell_ensure_smoke.lua` prints `SMOKE_PASS` + `exit=0` (the 12-case ensure matrix).
- [ ] Level 2b: `tests/shell_ensure_spec.lua` green (all cases pass, 0 fail, 0 error).
- [ ] Level 3a: `shell_spec` (S2) green (if landed).
- [ ] Level 3b: `completion_spec`, `bridge_handshake_spec` (15/0/0), `init_spec` (14/0/0), `notify_smoke` green.
- [ ] Level 3c: `git status --porcelain` shows shell.lua (edited/new) + the 2 new tests ONLY.

### Feature Validation

- [ ] First `ensure(cb)` with a present fake driver spawns (state.proc/stdin/stdout/shell/driver set;
      `stdout:read_start` wired; opts `{shell, cwd, startup_timeout_ms}` passed; `cb(nil)`).
- [ ] Second `ensure(cb)` with `state.proc` set reuses (driver.start NOT re-called; `cb(nil)` immediately).
- [ ] Spawn error sets `state.driver==nil` AND `state.failed==true`; follow-up short-circuits via `failed`.
- [ ] No-driver path sets `state.failed==true`; follow-up short-circuits via `failed`.
- [ ] Config pass-through: `prefer` honored; `startup_timeout_ms` passed (NOT 5000 when set); nil config no-throw.
- [ ] `_feed(chunk)` appends to `rx_buf`; `_reset()` sets `failed=true` + nils proc/pipes (leaves `failed=true`).
- [ ] ensure NEVER throws (`ensure(nil)`, `ensure(123)`, driver.start that throws → caught, `failed=true`).
- [ ] ensure returns nothing (cb-only; `on_ready(err|nil)`).

### Code Quality Validation

- [ ] TAB indentation throughout (match S2's shell.lua / completion.lua).
- [ ] `require("pi-bridge")` is LAZY (inside ensure), NOT at module top (GOTCHA #7).
- [ ] No `vim.uv.spawn` / `uv.new_timer` / `vim.notify` / `notify.once` CALL in S3 (delegation + header-only).
- [ ] The cache key is `state.proc`, NOT `state.driver` (GOTCHA #3).
- [ ] `state.failed` set on BOTH no-driver AND spawn-error (GOTCHA #5).
- [ ] `_feed`/`_reset` are EXPORTED stubs (GOTCHA #6); `_reset` does NOT call `M.reset()` (would clear failed).
- [ ] `driver.start` + `stdout:read_start` are pcall'd (GOTCHA #4).
- [ ] Config read is defensive: `(pi.config and pi.config.shell) or {}` (GOTCHA #2).
- [ ] S2's functions + state literal + [Mode A] header inside shell.lua are UNTOUCHED (append before `return M`).
- [ ] No edit to `extension/*`, `doc/*`, `ftplugin/*`, `plugin/*`, `completion.lua`, `bridge.lua`, `init.lua`,
      `notify.lua`, or `README.md`. No `shell/*.lua` created. No real subprocess spawned.

### Documentation & Deployment

- [ ] JSDoc blocks on `ensure`/`_feed`/`_reset` document: the spawn-delegation design, the `startup_timeout_ms`
      pass-through, the `state.failed` lifecycle (no-driver/spawn-error/EOF), the cache key (`state.proc`), the
      never-throws/pcall discipline, the fast-context safety (no vim.schedule in S3), and the forward-contract
      seams (S5 replaces `_feed`; S6 extends `_reset`/teardown).
- [ ] No README / `doc/pi-bridge.txt` / `doc/pi-bridge-shell.txt` / `extension/README.md` change (Mode-B task
      P2.M4.T7 + vimdoc task P2.M3.T6.S4 own those; S3 is pre-doc).
- [ ] Inline comments cite PRD §17.5.2 / §17.12 / §17.4.2 so a future reader knows WHY each piece exists.

---

## Anti-Patterns to Avoid

- ❌ **Don't call `vim.uv.spawn` / `uv.new_timer` in ensure.** Spawn (and the `startup_timeout_ms` cold-start
  timer) live INSIDE the driver (`state.driver.start`). S3 is the ORCHESTRATION around it. Adding spawn in
  ensure would bypass the per-shell driver layer (wrong) + break the fake-driver tests. (Design Decision §1 /
  GOTCHA #1.)
- ❌ **Don't build the startup_timeout_ms timer in S3.** It is passed THROUGH to the driver in the opts table.
  The driver (fish = P2.M2.T4.S1) owns the `uv.new_timer` + the kill-on-timeout. (Design Decision §1.)
- ❌ **Don't key the "already running" cache on `state.driver`.** `driver` is set in step 5 (BEFORE spawn);
  keying on it would false-positive "ready" if a second ensure fires mid-spawn. Key on `state.proc` (set ONLY
  on a successful spawn). (Design Decision §5 / GOTCHA #3.)
- ❌ **Don't skip setting `state.failed` on the no-driver / spawn-error paths.** Without it, every keystroke on
  a `!` line re-runs resolve→pick→spawn (5s timeout) for a permanently-broken daemon — catastrophic UX. §17.12
  "menu never opens for ! lines" + "no auto-respawn in v1". Set `failed=true` on BOTH paths. (Design Decision §2
  / GOTCHA #5.) NOTE: this is a defensible enhancement over the literal skeleton (which only nils the driver);
  the skeleton's `if not state.driver then return on_ready(...)` without `failed` would re-resolve every call.
- ❌ **Don't have `_reset()` call `M.reset()`.** `M.reset()` (S2) clears `failed=false` — a CLEAN teardown.
  `_reset` is the EOF/CRASH path (§17.12): it must LEAVE `failed=true` so the next ensure short-circuits. S6's
  `teardown()` (clean VimLeavePre exit) calls `M.reset()`; S6's `_reset`/EOF path keeps `failed=true`. They are
  DIFFERENT. (GOTCHA #6 / research §4.)
- ❌ **Don't implement sentinel parsing or `pipe:close()` in `_feed`/`_reset`.** Those are S5 (`_feed` →
  `__PIRESP_*` slicing + decode) and S6 (`_reset`/teardown → `uv.process_kill` + `read_stop` + `close`). S3
  ships append-only / mark-unhealthy stubs. (Design Decision §3 / GOTCHA #6.)
- ❌ **Don't call `notify.once` in S3.** The §17.12 one-time degrade notify is P2.M2.T3.S4. S3 sets the FACT
  (`state.failed=true`); references notify.lua in the HEADER only. (GOTCHA #14.)
- ❌ **Don't read config at module top, and don't write `pi.config.shell or {}`.** `M.config` is nil until
  `setup()`; `pi.config.shell or {}` THROWS (indexing nil). Use `require("pi-bridge")` LAZILY inside ensure +
  `(pi.config and pi.config.shell) or {}`. (GOTCHA #2/#7 — inherited from S2.)
- ❌ **Don't forget to `pcall` `driver.start` AND `stdout:read_start`.** `driver.start` could throw (buggy
  driver); `read_start` is a luv call on a handle the driver returned (could be malformed). A throw from either
  is a spawn error (failed=true, driver=nil, on_ready(err)). The resolution helpers are already never-throws.
  (Design Decision §4 / GOTCHA #4.)
- ❌ **Don't touch S2's functions or state literal inside shell.lua.** S3 APPENDS ensure + `_feed` + `_reset`
  BEFORE `return M`. S2's `state`, `resolve_shell`, `pick_driver`, `session_cwd`, `reset`, and the `[Mode A]`
  header are UNTOUCHED. (GOTCHA #13.)
- ❌ **Don't spawn a real subprocess in the tests.** Inject a FAKE driver via `package.loaded["pi-bridge.shell.
  fish"]` + fake pipes (read_start/write/close/is_closing methods mirroring the spike's shape). The live spawn
  seam was already proven by S1's spike; S3 doesn't re-prove it. The fake driver calls cb SYNCHRONOUSLY (no
  `vim.wait` needed). (GOTCHA #9/#10.)
- ❌ **Don't return a value from `ensure`.** It communicates via `on_ready(err|nil)` (node-style). S4 passes its
  own cb as on_ready; it ignores any return. (Design Decision §7 / GOTCHA #15.)
- ❌ **Don't heredoc lua into nvim's stdin** (AGENTS.md HARD RULE — it hangs the session). Write the smoke to
  `tests/shell_ensure_smoke.lua` and run `+"luafile tests/shell_ensure_smoke.lua" +qa` (as shown). Wrap every
  nvim in `timeout`.