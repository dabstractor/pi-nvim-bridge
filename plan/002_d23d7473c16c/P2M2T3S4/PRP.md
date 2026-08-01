# PRP — P2.M2.T3.S4: Shell-completion notices (mismatch §17.4.3 / first-run §17.9 / degrade §17.12)

**Parent:** P2.M2.T3 (completion.lua routing + shell.complete_current + notices)
**Component:** B (`pi-bridge.nvim`) — `lua/pi-bridge/shell.lua`
**PRD anchor:** §17.4.3 *The one-time educational notice*, §17.9 *Trigger & UX parity with the TUI* (first-run hint), §17.12 *Failure modes & degradation* (degrade notify), §17.6.4 (unknown-shell degrade wording)
**Size:** 1 pt — wire the existing `notify.lua` dedup'd-one-shot emitter into `shell.lua`'s daemon lifecycle.
**Builds on:** P2.M1.T2.S2 (COMPLETE — `M.resolve_shell` + `state`), P2.M1.T2.S3 (COMPLETE — `M.ensure` spawn layer + failure paths), P2.M1.T2.S5/S6 (COMPLETE — `_feed` parse-threshold + `_reset` EOF + `teardown`), P2.M2.T3.S3 (COMPLETE — `complete_current`, the trigger path that reaches `ensure`). `notify.lua` (S39) ships `once`/`did_notify`/`reset`.

---

## Goal

**Feature Goal:** Emit the three user-facing `!`/`!!` Bash-mode notices — (1) the §17.4.3 **mismatch** notice (pi resolved bash while the user's `$SHELL` is a richer zsh/fish that is on PATH), (2) the §17.9 **first-run** hint ("shell completion active"), (3) the §17.12 **degrade** notice (daemon permanently failed) — each **at most once per session** (dedup'd), at the exact lifecycle points where each notice's *fact* becomes known, using the shipped `notify.lua`. After this lands, a `!`/`!!` line either (a) silently activates completion with a single INFO toast telling the user which shell is driving it, (b) warns once that completion degraded (with a `:help` pointer), or (c) — for the unconfigured-zsh-user-with-pi-default-bash case — advises them how to get richer + consistent completion in one setting change.

**Deliverable:** Edited `lua/pi-bridge/shell.lua`:
1. One new pure helper **`M.mismatch_target(resolved_shell, env_shell)`** — the §17.4.3 mismatch condition (parts 1 & 2: resolved basename `=="bash"` AND env_shell basename ∈ `{"zsh","fish"}`). PURE (no nvim, no state, no notify) → directly unit-testable (mirrors `completion.M.is_attachment_context` / `M.shell_word_prefix`). The PATH check (`vim.fn.executable`) stays at the CALL SITE so the helper stays deterministic. Exported as `M.mismatch_target` for direct unit tests.
2. A module-local **`basename(path)`** helper (the `:gsub(".*/","")` idiom already used inline in `pick_driver`/`complete_current` — hoisted to one place for the notice messages).
3. **Six notify-emission points** wired into the existing `ensure()` / `_reset()` / `_feed()` bodies (NO signature changes; additive `pcall`-wrapped `notify.once` calls at the documented edit anchors):
   - `ensure` step 4 (after `state.shell = resolved`) → mismatch check + `notify.once("shell-mismatch", WARN, …)`.
   - `ensure` step 5 (no-driver) → `notify.once("shell-degrade", WARN, …)`.
   - `ensure` step 8a (spawn `err`) → `notify.once("shell-degrade", WARN, …)`.
   - `ensure` step 8b (spawn success) → `notify.once("shell-active", INFO, …)`.
   - `ensure` step 8c (`driver.start` threw) → `notify.once("shell-degrade", WARN, …)`.
   - `_reset` (EOF) + `_feed` (parse-threshold) → `notify.once("shell-degrade", WARN, …)` (same category → dedup'd to once with any earlier degrade).
4. New plenary spec **`tests/shell_notices_spec.lua`** — reuses the `fake_bridge` + `make_fake_driver` + `inject_fake_driver` + before_each/after_each save-restore harness from `tests/shell_ensure_spec.lua`; stubs `vim.fn.executable` for the mismatch PATH check; asserts each notice's category via `notify.did_notify` + the once-per-session dedup + the suppression invariants.
5. New plenary-free smoke **`tests/shell_notices_smoke.lua`** — load + one happy-path + one degrade-path call; the file-based Level-1 gate.

**Success Definition:**
- A session where `prefer:"pi"` resolves bash AND `$SHELL=/bin/zsh` AND zsh is on PATH → on the first `!<word>`, EXACTLY the mismatch toast fires (WARN, category `"shell-mismatch"`), with a message naming zsh + advising `shellPath`.
- A healthy daemon (fake driver spawn-success) → on first spawn EXACTLY the first-run hint fires (INFO, category `"shell-active"`), naming the resolved shell basename; the mismatch does NOT fire (resolved != bash).
- A failed spawn (no-driver, or `make_fake_driver({ _fail = true })`) → EXACTLY the degrade toast fires (WARN, category `"shell-degrade"`); the first-run hint does NOT fire (suppression, §17.9).
- Each category fires AT MOST ONCE per session (`notify.did_notify` is `true` after the first; a second trigger is a silent no-op — assert `seen` doesn't grow).
- `_reset` (EOF) / `_feed` (parse-threshold) firing mid-session → degrade fires once (dedup'd with an earlier degrade if any); no second toast.
- `notify.lua`, `completion.lua`, `bridge.lua`, the extension, and `init.lua` config are all UNCHANGED (additive only). `tests/shell_ensure_spec.lua` + `tests/shell_request_spec.lua` + `tests/shell_complete_current_spec.lua` + `tests/completion_spec.lua` + `tests/shell_spec.lua` STILL green (no regression).

---

## User Persona

**Target User:** A pi user editing a prompt in the Neovim external editor (`Ctrl+G`) who types a `!`/`!!` line to run a shell command.

**Use Case:** The user types `!git ch<Tab>`. With S4, they get a single, accurate `vim.notify` reflecting the state of shell completion: an INFO toast confirming which shell is driving completion (so a misconfiguration is visible), a WARN telling them completion is unavailable (with a `:help` pointer) if the daemon failed, or — for the common "zsh user, pi still runs bash" default — a one-time actionable hint that setting pi's `shellPath` unlocks both richer AND execution-consistent completion.

**Pain Points Addressed:** Today (S1–S3 shipped) `!`/`!!` completion either works (once a P2.M2.T4 driver lands) or fails **silently** — the §17.12 forward contracts in shell.lua say "the one-time degrade NOTIFY is P2.M2.T3.S4's job — ensure sets only the FACT (`failed`)". S4 closes that gap: the three UX feedback paths the PRD specifies are wired so the user is never left guessing whether shell completion is active, degraded, or suboptimal.

---

## Why

- **Business value:** The user-feedback half of the §17 shell-completion feature. S3 made the `complete_current` seam live; S4 makes its outcomes **visible**. The mismatch notice in particular is the PRD's chosen mechanism for nudging users toward the configuration that fixes both quality AND correctness at once (`prefer:"pi"` resolves bash by default; the notice makes the richer `$SHELL` recoverable in one setting — §17.2 "the central design constraint").
- **Integration with existing features:** Additive — one pure helper + one basename helper + six `pcall`-wrapped `notify.once` calls in `shell.lua`, plus tests. `notify.lua` (S39) is reused verbatim (`once` is already fast-context-safe + dedup'd). `completion.lua` is unchanged (its do_shell_fetch cb's "silent degrade (S4 notifies)" forward-contract is satisfied transitively: do_shell_fetch → complete_current → M.request → M.ensure → the notify fires there). The bridge / slash / path paths are untouched.
- **Problems this solves, for whom:** Centralizes ALL shell-notice logic in ONE module (shell.lua — the owner of `state.shell`/`state.driver`/`state.failed`) so there is a single source of truth for "what the user is told about shell completion". Avoids the trap of scattering notify calls across completion.lua / the drivers / ftplugin (each of which would only see a partial picture).

---

## What

### User-visible behavior
Three `vim.notify` toasts (title `"pi-bridge"`), each AT MOST ONCE per session, driven by the §17 lifecycle:

1. **First-run hint (§17.9, INFO)** — the first time a real `!`/`!!` command successfully spawns the daemon: `pi-bridge: shell completion active (<BASE>); :help pi-bridge-shell` (BASE = the resolved shell basename, e.g. `zsh`). Suppressed if the daemon failed (the degrade toast fires instead).
2. **Mismatch notice (§17.4.3, WARN)** — when `prefer:"pi"` resolved bash AND the user's `$SHELL` is zsh/fish AND that shell is on PATH: `pi-bridge: pi runs commands in bash; using bash completion to match. For your native <RICHER> completions, set pi's shellPath to <SHELL> (then completion and execution both use it). :help pi-bridge-shell`.
3. **Degrade notice (§17.12, WARN)** — when the daemon permanently fails (no driver / spawn error / EOF crash / parse-threshold): `pi-bridge: shell completion unavailable for <BASE>; :help pi-bridge-shell`.

A bare `!` (empty command) emits NOTHING (it does not reach `ensure` — `complete_current` short-circuits it).

### Technical requirements
1. **`M.mismatch_target(resolved_shell, env_shell)`** (PURE) — returns the richer basename (`"zsh"`/`"fish"`) when resolved basename `=="bash"` AND env_shell basename ∈ `{"zsh","fish"}`; else `nil`. NO `vim.fn.executable` call inside (PATH check stays at the call site so the helper is deterministic). Self-gating under every `prefer` value (verified — research §"Self-gating"). Never throws (defensive type-checks; non-string/empty → nil).
2. **`basename(path)`** module-local — `:gsub(".*/","")` (the idiom already inlined in `pick_driver`/`complete_current`); `nil`/non-string → `"?"`.
3. **Six emission points** in `ensure()` / `_reset()` / `_feed()`, each a `pcall`-wrapped `require("pi-bridge.notify").once(<category>, <level>, <msg>)`. Fast-context-safe (notify.once schedules internally — verified notify.lua L23-27). Categories: `"shell-mismatch"`, `"shell-active"`, `"shell-degrade"`.
4. **Mismatch PATH check** at the `ensure` step-4 call site: `M.mismatch_target(resolved, vim.env.SHELL)` → if non-nil, `pcall(vim.fn.executable, <richer>)` → if `==1`, emit. (Matches the health.lua L181 `vim.fn.executable`/`exepath` idiom.)
5. **Dedup** is `notify.lua`'s job (one `seen[category]` set) — NOT a new flag in `state`. The three categories dedup independently (max 3 toasts/session). The degrade category collapses ALL failure types (no-driver/spawn-err/EOF/parse-threshold) to ONE toast.
6. **Suppression (§17.9)** is STRUCTURAL: the first-run hint lives ONLY in `ensure` step 8b (spawn-success); the degrade lives in steps 5/8a/8c + `_reset`/`_feed`. A failed spawn never reaches 8b → first-run hint never fires. No explicit `state.shell_announced` flag is needed (the lifecycle structure + `notify.once` dedup enforce it).
7. **NEVER throws** (per-keystroke + autocmd + luv-fast-context contract): every `notify.once` call is `pcall`'d (notify.lua ALSO pcalls `vim.notify`, but double safety matches the init.lua L75 pattern); `vim.fn.executable` is `pcall`'d; `require` is `pcall`'d.
8. **Scope fence:** NO edits to `notify.lua` (its API already covers this), `completion.lua` (do_shell_fetch stays a thin router), `bridge.lua`, `init.lua` config (no new key — `config.shell` is P2.M3.T6.S1, not done; read it the same defensive `(pi.config and pi.config.shell) or {}` way), the drivers (P2.M2.T4/P2.M3.T5), `menu.lua` (the `$` gutter is S5), health/docs (P2.M3.T6).

### Success Criteria
- [ ] `M.mismatch_target(resolved, env_shell)` exported + pure (no nvim/vim.fn); self-gating across all `prefer` values.
- [ ] `basename(path)` module-local helper (nil-safe).
- [ ] Mismatch (§17.4.3): `prefer:"pi"` + descriptor bash + `$SHELL`=/bin/zsh + zsh on PATH → `notify.did_notify("shell-mismatch")` true after first spawn; message names zsh + `shellPath`.
- [ ] Mismatch does NOT fire when resolved == `$SHELL` (e.g. `prefer:"shell"`, or `prefer:"pi"` + descriptor=zsh + `$SHELL`=zsh).
- [ ] Mismatch does NOT fire when zsh/fish is absent from PATH (`vim.fn.executable` returns 0).
- [ ] First-run (§17.9): healthy fake-driver spawn → `notify.did_notify("shell-active")` true (INFO); message names the resolved basename; degrade does NOT fire.
- [ ] First-run suppressed on a failed spawn (`_fail=true` / no-driver): `notify.did_notify("shell-active")` false; `notify.did_notify("shell-degrade")` true.
- [ ] Degrade (§17.12): no-driver + spawn-err + driver-threw + `_reset` EOF + `_feed` parse-threshold each set the category once; a second trigger is a silent no-op (dedup).
- [ ] Bare `!` (empty command) → NO notice of any category (`ensure` not reached).
- [ ] Each category fires AT MOST once per session (assert `notify.did_notify` flips false→true exactly once across two triggers).
- [ ] Never throws: every `notify.once`/`vim.fn.executable`/`require` is `pcall`'d; bad inputs degrade to nil/no-op.
- [ ] Regression green: `shell_ensure_spec.lua`, `shell_request_spec.lua`, `shell_complete_current_spec.lua`, `completion_spec.lua`, `shell_spec.lua` all exit 0.

---

## All Needed Context

### Context Completeness Check
A reader who knows nothing of this repo can implement S4 from: this PRP + the cited `shell.lua` regions (`ensure` L285-360, `_reset` L~545-560, `_feed` L~440-490, `state` literal, `M.reset`) + `notify.lua` (L1-39, the `once`/`did_notify`/`reset` surface) + `completion.lua:411-447` (`do_shell_fetch`, the caller that triggers `ensure`) + PRD §17.4.3/§17.9/§17.12 (quoted inline) + the VERIFIED edit-anchor map in research §"Exact emission points". No daemon-internals knowledge beyond "ensure resolves the shell, picks a driver, spawns, and sets `state.failed=true` on every permanent failure" is required.

### Documentation & References

```yaml
# MUST READ — the spec that defines each notice's trigger + wording + level
- url: PRD.md §17.4.3 "The one-time educational notice"
  why: |
    defines the mismatch trigger VERBATIM: "When prefer:"pi" resolves a shell poorer than the user's
    $SHELL — specifically: resolved shell is bash (tier-2) AND $SHELL is zsh/fish (tier-1) AND that
    richer shell exists on PATH — emit ONE dedup'd vim.notify." Gives the exact message wording +
    the `:help pi-bridge-shell` pointer.
  critical: |
    the condition is self-gating: under prefer:"pi" it fires only when descriptor.shell==bash AND
    $SHELL∈{zsh,fish}; under any prefer where resolved==$SHELL it is structurally false. Do NOT add
    an explicit prefer check. The PATH check (vim.fn.executable) is MANDATORY (a richer $SHELL that
    isn't installed is not actionable advice).
- url: PRD.md §17.9 "Trigger & UX parity with the TUI" (the first-run hint paragraph)
  why: |
    "the first time a ! line is detected in a session, emit a one-time hint (dedup'd): 'Shell completion
    active (`<resolved shell>`); :help pi-bridge-shell.' Suppressed if the daemon failed (the degrade
    notice fires instead)."
  critical: |
    the suppression is STRUCTURAL in our design: the hint lives ONLY in ensure's spawn-success cb (8b);
    a failed spawn never reaches 8b. No explicit suppression flag is needed. "First ! line detected" is
    operationalized as "first spawn of the daemon" (a bare ! does not spawn → no hint — correct UX).
- url: PRD.md §17.12 "Failure modes & degradation"
  why: |
    lists every degrade trigger: daemon spawn failure (shell missing/rc error/startup timeout) → "silent
    degrade to a plain buffer + ONE vim.notify"; capture fragility (zsh/bash) "after N consecutive parse
    failures the daemon is killed and marked unhealthy"; EOF on the daemon pipe (shell crashed mid-session).
  critical: |
    EVERY one of these collapses to ONE category ("shell-degrade") via notify.once dedup — the user sees
    at most one degrade toast per session regardless of how many times the daemon fails. Never blocks
    editor startup; the menu simply never opens for ! lines.
- url: PRD.md §17.6.4 "unknown shells — degrade" + §17.4.2 (driver selection)
  why: |
    §17.6.4: an unknown basename → "shell/unknown.lua → silent no-op → a single vim.notify fires once:
    'Shell completion not supported for <shell>; degraded to no completion.'" §17.4.2: a user-disabled
    driver (drivers.bash=false) ALSO yields nil → degrade.
  critical: |
    the no-driver path (ensure step 5) covers BOTH unknown shells AND user-disabled drivers — both set
    state.failed=true and emit the SAME degrade category. No separate "unsupported" category.

# Codebase files to follow EXACTLY
- file: lua/pi-bridge/notify.lua
  why: the dedup'd one-shot emitter being reused; its API is the contract S4 depends on
  pattern: |
    M.once(category, level, msg) — dedup by category; vim.schedule's the notify; pcall's vim.notify;
      default category "bridge", default level WARN. FAST-CONTEXT-SAFE (the handshake cb already calls it
      from luv fast context — init.lua L167). Never throws.
    M.did_notify(category) — bool, for test assertions.
    M.reset() — clear the dedup set (call in before_each).
  gotcha: |
    once() SCHEDULES the notify (vim.schedule) — tests must vim.wait(N, ...) to flush it before asserting
    did_notify (the bridge_notify_spec.lua pattern). S4 reuses notify.lua UNCHANGED (do not add a level/
    category param — once already takes both).
- file: lua/pi-bridge/shell.lua
  why: the file being edited; ensure/_reset/_feed + state + M.reset live here
  pattern: |
    M.ensure(on_ready) (L285-360): the 8-step lifecycle (failed-shortcut → cache → cfg → resolve →
      pick-driver → opts → driver.start cb → threw-guard). Steps 4/5/8a/8b/8c are the EDIT ANCHORS
      (see research §"Exact emission points" — verified against current source).
    M._reset() (L~545-560, EOF path): close_handles() + state.failed=true + nil proc/pipes/driver/rx_buf.
      EDIT ANCHOR: after state.failed=true.
    M._feed(chunk) (L~440-490): parse-threshold branch increments state.parse_failures; at max_parse_failures()
      sets state.failed=true + forward-guard teardown + re-asserts failed. EDIT ANCHOR: after the re-assert.
    M.reset() (L~210): clears state (incl. failed/parse_failures). UNCHANGED — S4 adds NO state field.
    M.resolve_shell(prefer) (L~140): returns (shell_path, source). PURE-ish (reads descriptor/$SHELL lazily).
      The resolved basename drives the mismatch + first-run + degrade messages.
    state.shell: set in ensure step 4 BEFORE the spawn attempt — so the mismatch check (step 4) AND the
      degrade messages (steps 5/8) AND _reset/_feed all have a valid state.shell to name in the toast.
  gotcha: |
    ensure steps 4-8 run ONLY on the FIRST spawn per session (subsequent calls hit the state.proc cache at
    step 2 + return immediately). So the mismatch + first-run/spawn-degrade logic naturally fires once.
    _reset/_feed are the MID-SESSION cases (after a successful first spawn); notify.once dedups their
    degrade with any earlier degrade. state.shell is always set before _reset/_feed can fire (they only
    run after a successful spawn wired stdout:read_start in step 8b).
- file: lua/pi-bridge/completion.lua   (READ-ONLY — the caller; NOT edited by S4)
  why: |
    confirms the forward-contract "silent degrade (S4 notifies)" is satisfied transitively. do_shell_fetch
    (L411-447) → complete_current → M.request → M.ensure. The degrade notify fires INSIDE ensure; do_shell_fetch's
    cb stays a silent `if err then dbg(...); return end`.
  pattern: |
    -- completion.lua:433 (do_shell_fetch cb, S2/S3, COMPLETE):
    if err then dbg("[do_shell_fetch.cb] ERR=" .. tostring(err)); return end -- silent degrade (S4 notifies)
  gotcha: |
    do_shell_fetch already does the gen-guard + state.last_result + vim.schedule(on_results). S4 must NOT
    move the notify into do_shell_fetch — shell.lua owns the daemon facts (state.shell/failed). The notify
    fires inside ensure regardless of which caller reached it.
- file: tests/shell_ensure_spec.lua   (the test-harness TEMPLATE — copy its fakes + reset block)
  why: |
    the established fake-daemon pattern for ensure: fake_bridge(shell_path) + make_fake_driver() +
    package.loaded injection + before_each/after_each save-restore (vim.env.SHELL, pi.bridge,
    pi.descriptor, pi.config.shell, package.loaded["pi-bridge.shell.fish"], shell.reset()). S4's spec
    reuses ALL of these + ADDS notify.reset() + vim.fn.executable stubbing.
  pattern: |
    -- wire a fake "fish" daemon that succeeds:
    pi.bridge = fake_bridge("/usr/bin/fish"); inject_fake_driver(make_fake_driver())
    shell.ensure(function() end)   -- step 8b fires → notify.once("shell-active", ...)
    vim.wait(200, function() return notify.did_notify("shell-active") end, 5)
    assert.is_true(notify.did_notify("shell-active"))
  gotcha: |
    the spec's before_each MUST call notify.reset() (clear the dedup set) AND restore vim.fn.executable
    (it is stubbed for the mismatch PATH check) — otherwise cases leak across each other. The fake driver's
    start cb is SYNCHRONOUS (make_fake_driver calls cb inline) so no vim.wait is needed for ensure to
    complete — only for the notify.once vim.schedule to flush.
- file: lua/pi-bridge/health.lua   (READ-ONLY — the vim.fn.executable/exepath idiom reference)
  why: confirms the PATH-check idiom S4 reuses for the mismatch condition
  pattern: L181 `if vim.fn.executable(n) == 1 then return n, vim.fn.exepath(n) end` (returns 1/0; pcall-safe).
  gotcha: vim.fn.executable sees the nvim client's $PATH, not pi's — fine here (we only want "is zsh installed").

# Sibling PRPs (the immediate predecessor contracts — read for the seam, do not re-derive)
- file: plan/002_d23d7473c16c/P2M2T3S3/PRP.md
  why: S3 defined complete_current (the buffer→daemon bridge that triggers ensure). S4's notices fire
       inside the ensure that S3's complete_current reaches. Confirms S4 must NOT touch completion.lua.
- file: plan/002_d23d7473c16c/P2M1.T2.S6/PRP.md
  why: S6 (teardown) + the _reset/_feed failure paths. S4 adds the degrade notify to _reset/_feed —
       confirms those run in libuv FAST context (notify.once is fast-safe) and that state.failed is the
       single source of "daemon dead".
```

### Current codebase tree (relevant slice)

```bash
pi-nvim-bridge/
├── lua/pi-bridge/
│   ├── shell.lua          # ← EDIT (+M.mismatch_target +basename helper +6 notify.once calls)
│   ├── notify.lua         # the dedup'd emitter — REUSED UNCHANGED (once/did_notify/reset)
│   └── completion.lua     # do_shell_fetch (L411-447) — the caller; READ-ONLY (S2/S3 done)
├── tests/
│   ├── shell_ensure_spec.lua        # the fake-driver harness TEMPLATE (copy its fakes + reset block)
│   ├── shell_request_spec.lua       # make_fake_stdin/inject_fake_driver origin — READ-ONLY reference
│   ├── shell_complete_current_spec.lua  # S3's spec (real buffer + cursor) — READ-ONLY reference
│   ├── bridge_notify_spec.lua       # the notify.did_notify + vim.wait flush pattern — READ-ONLY ref
│   ├── shell_notices_spec.lua       # ← CREATE (plenary; the Level-2 gate)
│   ├── shell_notices_smoke.lua      # ← CREATE (plenary-free; the Level-1 gate)
│   └── minimal_init.lua             # plenary harness bootstrap (read-only)
└── PRD.md  (§17.4.3, §17.9, §17.12, §17.6.4, §17.4.2 — read-only reference)
```

### Desired codebase tree with files changed

```bash
lua/pi-bridge/shell.lua                # MODIFIED — +M.mismatch_target +basename +6 pcall'd notify.once calls
tests/shell_notices_spec.lua           # CREATED — plenary spec (fake driver; mismatch/first-run/degrade/dedup)
tests/shell_notices_smoke.lua          # CREATED — plenary-free load + happy-path + degrade-path smoke
```

### Known Gotchas of our codebase & Library Quirks

```lua
-- CRITICAL: AGENTS.md ⛔ HARD RULE — NEVER pipe a heredoc / stdin into nvim (it HANGS the session).
-- Write any ad-hoc test snippet to a .lua FILE, then run  +"luafile <file>" +qa . Always wrap in `timeout`.

-- CRITICAL: notify.once() SCHEDULES the notify (vim.schedule, notify.lua L23). Tests MUST vim.wait(N, ...)
-- for it to flush BEFORE asserting did_notify (the bridge_notify_spec.lua pattern — vim.wait(500, cond, 5)).
-- In PROD this is invisible (the schedule fires on the next loop tick), but a test that asserts
-- did_notify synchronously right after ensure() will see FALSE (the schedule hasn't run yet).

-- CRITICAL: the degrade notify fires from libuv FAST context in _reset (the read_start EOF cb) and _feed
-- (the read_start data cb). notify.once is FAST-SAFE — it does NO vim.api.* (only a table write to `seen`
-- + a vim.schedule of vim.notify). So calling it from _reset/_feed is correct (matches init.lua L167-178
-- calling once() from the handshake/disconnect cbs). Do NOT add a vim.schedule wrapper around the
-- notify.once call itself (notify.once schedules the NOTIFY, not the dedup-check — the check is fast-safe).

-- GOTCHA: ensure steps 4-8 run ONLY on the FIRST spawn per session (subsequent calls hit state.proc cache
-- at step 2). So the mismatch + first-run/spawn-degrade logic naturally fires once. _reset/_feed are the
-- MID-SESSION failure cases (after a successful first spawn); notify.once("shell-degrade", ...) dedups
-- them with any earlier degrade. Do NOT add a state.shell_announced flag — the lifecycle structure +
-- notify.once dedup already enforce once-per-session.

-- GOTCHA: the §17.9 suppression ("Suppressed if the daemon failed") is STRUCTURAL, not flag-driven.
-- The first-run hint lives ONLY in ensure step 8b (spawn-success); a failed spawn (step 5 no-driver /
-- step 8a spawn-err / step 8c threw) never reaches 8b. So the hint CANNOT fire on a failed spawn. Do
-- NOT add `if state.failed then return end` before the hint — the control flow already guarantees it.

-- GOTCHA: the mismatch condition is SELF-GATING across all prefer values (research §"Self-gating"):
--   prefer:"pi" + descriptor=bash + $SHELL=zsh → TRUE (the footgun)
--   prefer:"shell" → resolved==$SHELL → structurally FALSE
--   prefer:"pi" + descriptor omits shell → resolve falls through to $SHELL → resolved==$SHELL → FALSE
-- Do NOT add an explicit `cfg.prefer == "pi"` check — it would double-gate + could drift from resolve_shell.

-- GOTCHA: the PATH check (vim.fn.executable) is at the CALL SITE (ensure step 4), NOT inside
-- M.mismatch_target. This keeps mismatch_target PURE + deterministic for unit tests (no vim.fn dep).
-- vim.fn.executable returns 1/0; pcall it (a malformed name could throw on some builds). Restore the
-- original vim.fn.executable in after_each when stubbed.

-- GOTCHA: read config FRESH + lazily like the rest of shell.lua: `(pi.config and pi.config.shell) or {}`.
-- config.shell is NOT in M.defaults yet (P2.M3.T6.S1, Planned). The notices do NOT need a config key
-- (dedup is via notify.lua categories), so S4 does NOT depend on P2.M3.T6.S1 and must NOT add a config key.

-- GOTCHA: state.shell is set in ensure step 4 BEFORE the spawn attempt. So the mismatch check (step 4),
-- the degrade messages (steps 5/8a/8c — they name state.shell), AND _reset/_feed (mid-session, name
-- state.shell) all have a valid resolved shell to put in the toast. A defensive basename(nil) → "?"
-- guards the impossible "state.shell nil in _reset" case.

-- GOTCHA: require("pi-bridge.notify") is a sibling module require (notify.lua is at lua/pi-bridge/notify.lua).
-- It is safe to require repeatedly (Lua caches in package.loaded). Wrap in pcall at the emission sites
-- (a load-order oddity must never crash the daemon lifecycle). init.lua already does require("pi-bridge.notify").once(...).

-- GOTCHA: the SOLE consumer trigger is completion.lua:428 (do_shell_fetch → complete_current → M.request →
-- M.ensure). But _reset/_feed can ALSO be triggered by the daemon's own stdout EOF / garbage (independent
-- of completion.lua). So the degrade notify must fire from _reset/_feed themselves, not from a caller —
-- there is no single "caller" for the mid-session crash path.
```

---

## Implementation Blueprint

### Data models and structure
N/A — S4 adds no data model. `M.mismatch_target` operates on string args (pure); the six emission points use the EXISTING `state.shell` / `state.failed` and the EXISTING `notify.lua` `seen` set. No new `state` field, no new config key.

### Implementation Tasks (ordered by dependencies)

```yaml
Task 1: EDIT lua/pi-bridge/shell.lua — add M.mismatch_target + basename helper
  - LOCATE: place M.mismatch_target in the §17.4 resolution section (AFTER M.resolve_shell, BEFORE
    M.pick_driver — it is the resolution-time mismatch detector). Place basename as a module-local
    near the top (beside the existing `local close_handles` forward decl / `local function dbg`).
  - NAMING: `M.mismatch_target(resolved_shell, env_shell)` (the public pure helper; mirrors
    completion.M.is_attachment_context / M.shell_word_prefix). `basename` (module-local; mirrors the
    inline `:gsub(".*/","")` already in pick_driver/complete_current — hoisted to one place).
  - IMPLEMENT (NEVER throws; PURE; no vim.fn/vim.api/state):

      --- The basename of a shell path ("/bin/zsh" → "zsh"). Module-local so the notice messages + the
      --- existing pick_driver/complete_current inline idiom share ONE definition. nil/non-string → "?"
      --- (a defensive sentinel so a toast never reads "active (`nil`)"). NEVER throws.
      local function basename(p)
        if type(p) ~= "string" or p == "" then return "?" end
        local b = p:gsub(".*/", "")
        return b == "" and "?" or b
      end

      --- §17.4.3 mismatch condition (PURE — no nvim, no vim.fn, no state, no notify; directly
      --- unit-testable, the completion.M.is_attachment_context / M.shell_word_prefix style). Returns the
      --- richer shell's basename ("zsh"|"fish") when the mismatch condition's RESOLUTION parts hold:
      --- resolved basename == "bash" (tier-2) AND env_shell basename ∈ {"zsh","fish"} (tier-1). The PATH
      --- check (vim.fn.executable) is INTENTIONALLY at the CALL SITE (ensure step 4) so this helper stays
      --- deterministic + vim.fn-free for unit tests.
      ---
      --- SELF-GATING (research §"Self-gating"): under prefer:"pi" it is true ONLY when descriptor.shell
      --- is bash AND $SHELL is zsh/fish; under prefer:"shell" (resolved==$SHELL) it is structurally
      --- false; under prefer:"pi" with a descriptor that omits shell (resolve falls through to $SHELL)
      --- resolved==$SHELL → false. NO explicit prefer check is needed.
      ---
      --- NEVER throws: non-string/empty resolved → nil; non-string/empty env_shell → nil; basename via
      --- the shared helper. Returns nil (not false) so the call site reads `if M.mismatch_target(...) then`.
      ---@param resolved_shell string The resolved execution shell path (state.shell / M.resolve_shell result).
      ---@param env_shell string? The raw $SHELL env var (vim.env.SHELL; nil → no mismatch possible).
      ---@return string|nil richer_basename "zsh"|"fish" if the mismatch's resolution parts hold, else nil.
      function M.mismatch_target(resolved_shell, env_shell)
        if type(resolved_shell) ~= "string" or resolved_shell == "" then return nil end
        if basename(resolved_shell) ~= "bash" then return nil end   -- only bash (tier-2) can be "poorer"
        if type(env_shell) ~= "string" or env_shell == "" then return nil end
        local ebase = basename(env_shell)
        if ebase ~= "zsh" and ebase ~= "fish" then return nil end   -- tier-1 richer shells only
        return ebase
      end

  - DEPENDENCIES: none new. basename is used by the notice messages in Task 2.

Task 2: EDIT lua/pi-bridge/shell.lua — wire the 6 notify.once emission points
  - LOCATE + EDIT (use the EXACT anchor strings below — they are unique in the file). Each edit is a
    single pcall-wrapped notify.once insertion BEFORE the existing `return on_ready(...)` / after the
    `state.failed = true` line. NO signature changes; NO control-flow changes.

  - (A) ensure step 4 — MISMATCH (after `state.shell = resolved`):
      OLD anchor (unique):
        local resolved = M.resolve_shell(cfg.prefer or "pi")
        state.shell = resolved
      NEW (append the mismatch check):
        local resolved = M.resolve_shell(cfg.prefer or "pi")
        state.shell = resolved
        -- §17.4.3 one-time mismatch notice: prefer:"pi" resolved bash while $SHELL is a richer zsh/fish
        -- on PATH. PURE condition (M.mismatch_target) + the PATH check (vim.fn.executable, pcall'd).
        -- notify.once dedups to once-per-session. Fires here ONLY on the first spawn (steps 4-8 run once).
        pcall(function()
          local richer = M.mismatch_target(resolved, vim.env.SHELL)
          if richer then
            local ok, ex = pcall(vim.fn.executable, richer)
            if ok and ex == 1 then
              require("pi-bridge.notify").once("shell-mismatch", vim.log.levels.WARN,
                "pi-bridge: pi runs commands in bash; using bash completion to match. For your native "
                .. richer .. " completions, set pi's shellPath to " .. (vim.env.SHELL or richer)
                .. " (then completion and execution both use it). :help pi-bridge-shell")
            end
          end
        end)

  - (B) ensure step 5 — DEGRADE, no-driver (the `if not state.driver then` block):
      OLD anchor:
        if not state.driver then
          state.failed = true
          return on_ready("no driver for " .. tostring(resolved))
        end
      NEW (insert the notify BEFORE return):
        if not state.driver then
          state.failed = true
          pcall(function()
            require("pi-bridge.notify").once("shell-degrade", vim.log.levels.WARN,
              "pi-bridge: shell completion unavailable for `" .. basename(resolved)
              .. "`; :help pi-bridge-shell")
          end)
          return on_ready("no driver for " .. tostring(resolved))
        end

  - (C) ensure step 8a — DEGRADE, spawn err (inside the driver.start cb):
      OLD anchor:
        if err then
          state.driver = nil
          state.failed = true
          return on_ready(err)
        end
      NEW (insert the notify BEFORE return):
        if err then
          state.driver = nil
          state.failed = true
          pcall(function()
            require("pi-bridge.notify").once("shell-degrade", vim.log.levels.WARN,
              "pi-bridge: shell completion unavailable for `" .. basename(state.shell)
              .. "`; :help pi-bridge-shell")
          end)
          return on_ready(err)
        end

  - (D) ensure step 8b — FIRST-RUN HINT, spawn success (after the read_start wiring, before on_ready(nil)):
      OLD anchor:
        pcall(function()
          stdout:read_start(function(_, chunk)
            if chunk then M._feed(chunk) else M._reset() end
          end)
        end)
        on_ready(nil)
      NEW (insert the hint BETWEEN read_start + on_ready):
        pcall(function()
          stdout:read_start(function(_, chunk)
            if chunk then M._feed(chunk) else M._reset() end
          end)
        end)
        -- §17.9 first-run hint (INFO): fires ONCE on the first successful daemon spawn. Suppressed on a
        -- failed spawn STRUCTURALLY (steps 5/8a/8c return before reaching here). notify.once dedups.
        pcall(function()
          require("pi-bridge.notify").once("shell-active", vim.log.levels.INFO,
            "pi-bridge: shell completion active (`" .. basename(state.shell)
            .. "`); :help pi-bridge-shell")
        end)
        on_ready(nil)

  - (E) ensure step 8c — DEGRADE, driver.start threw (the `if not ok then` block):
      OLD anchor:
      if not ok then
        state.driver = nil
        state.failed = true
        on_ready(tostring(spawn_err))
      end
      NEW (insert the notify BEFORE on_ready):
      if not ok then
        state.driver = nil
        state.failed = true
        pcall(function()
          require("pi-bridge.notify").once("shell-degrade", vim.log.levels.WARN,
            "pi-bridge: shell completion unavailable for `" .. basename(state.shell)
            .. "`; :help pi-bridge-shell")
        end)
        on_ready(tostring(spawn_err))
      end

  - (F) _reset — DEGRADE, EOF (after `state.failed = true`):
      OLD anchor (in M._reset):
      close_handles()               -- S6: close the real handles (the EOF pipe leak S3 deferred here)
      state.failed = true           -- S3 (unchanged): a crash is NOT a clean exit
      NEW (append the notify after state.failed = true):
      close_handles()               -- S6: close the real handles (the EOF pipe leak S3 deferred here)
      state.failed = true           -- S3 (unchanged): a crash is NOT a clean exit
      -- §17.12 degrade notify (mid-session EOF crash). notify.once dedups with any earlier degrade.
      pcall(function()
        require("pi-bridge.notify").once("shell-degrade", vim.log.levels.WARN,
          "pi-bridge: shell completion unavailable for `" .. basename(state.shell)
          .. "`; :help pi-bridge-shell")
      end)

  - (G) _feed — DEGRADE, parse-threshold (after the `state.failed = true` RE-ASSERT in the threshold branch):
      OLD anchor (the threshold branch — find the SECOND `state.failed = true` inside _feed, the one
      AFTER `pcall(function() if type(M.teardown) == "function" then M.teardown() end end)`):
            pcall(function() if type(M.teardown) == "function" then M.teardown() end end)
            state.failed = true
      NEW (append the notify after the re-asserted state.failed = true):
            pcall(function() if type(M.teardown) == "function" then M.teardown() end end)
            state.failed = true
            -- §17.12 degrade notify (N consecutive parse failures). notify.once dedups.
            pcall(function()
              require("pi-bridge.notify").once("shell-degrade", vim.log.levels.WARN,
                "pi-bridge: shell completion unavailable for `" .. basename(state.shell)
                .. "`; :help pi-bridge-shell")
            end)

  - NOTE: edits (B)/(C)/(E)/(F)/(G) all emit the SAME category ("shell-degrade") + the SAME canonical
    message — notify.once collapses them to ONE toast per session (whichever fires first). This is
    intentional (§17.12: "ONE vim.notify"). The message names state.shell's basename.
  - NOTE: the anchor strings above are the EXACT current source (verified L285-360 for ensure, L~545-560
    for _reset, L~478-485 for _feed's threshold branch). If a prior sibling task (S5/S6) has drifted the
    surrounding text, LOCATE by the step semantics (state.failed = true on each permanent-failure path)
    rather than by a fragile line number.
  - DEPENDENCIES: Task 1 (basename + M.mismatch_target).

Task 3: CREATE tests/shell_notices_smoke.lua — the plenary-free Level-1 gate
  - PATTERN: tests/shell_ensure_spec.lua's fakes (fake_bridge / make_fake_driver / package.loaded
    injection) + notify.reset() + vim.wait flush. NO plenary, NO subprocess. Prints a parseable verdict.
  - IMPLEMENT (skeleton):
      local pi = require("pi-bridge"); local shell = require("pi-bridge.shell")
      local notify = require("pi-bridge.notify")
      if pi.config == nil then pi.setup({}) end
      local fails = 0
      local function check(c, m) if not c then io.stderr:write("FAIL: "..m.."\n"); fails=fails+1 end end

      -- fake "fish" daemon that spawns successfully
      local function fake_driver_ok()
        return { start = function(opts, cb)
          cb(nil, { is_closing=function() return false end },
               { write=function() end, is_closing=function() return false end, close=function() end, read_stop=function() end },
               { read_start=function() end, is_closing=function() return false end, close=function() end })
        end }
      end
      local function setup(shell_path)
        notify.reset(); shell.reset()
        package.loaded["pi-bridge.shell.fish"] = fake_driver_ok()
        pi.bridge = { get_shell_info=function() return {shell=shell_path} end, server_info={} }
      end
      local function teardown()
        package.loaded["pi-bridge.shell.fish"] = nil; pi.bridge = nil; notify.reset(); shell.reset()
      end

      -- (1) HAPPY PATH: resolved fish (==$SHELL) → first-run hint, NO mismatch, NO degrade
      setup("/usr/bin/fish"); vim.env.SHELL = "/usr/bin/fish"
      shell.ensure(function() end)
      vim.wait(200, function() return notify.did_notify("shell-active") end, 5)
      check(notify.did_notify("shell-active"), "first-run hint fires on healthy spawn")
      check(not notify.did_notify("shell-mismatch"), "no mismatch when resolved==$SHELL")
      check(not notify.did_notify("shell-degrade"), "no degrade on healthy spawn")
      teardown()

      -- (2) MISMATCH PATH: resolved bash + $SHELL=zsh + zsh on PATH (stub executable) → mismatch
      setup("/bin/bash"); vim.env.SHELL = "/bin/zsh"
      local orig_exec = vim.fn.executable
      vim.fn.executable = function(name) return name == "zsh" and 1 or 0 end
      shell.ensure(function() end)
      vim.wait(200, function() return notify.did_notify("shell-mismatch") end, 5)
      check(notify.did_notify("shell-mismatch"), "mismatch fires: bash resolved + zsh $SHELL + on PATH")
      vim.fn.executable = orig_exec
      teardown()

      -- (3) MISMATCH TARGET pure helper (no nvim, no daemon) — direct unit checks
      check(shell.mismatch_target("/bin/bash", "/bin/zsh") == "zsh", "mismatch: bash+ zsh→zsh")
      check(shell.mismatch_target("/bin/bash", "/usr/bin/fish") == "fish", "mismatch: bash+ fish→fish")
      check(shell.mismatch_target("/bin/zsh", "/bin/zsh") == nil, "no mismatch: resolved zsh")
      check(shell.mismatch_target("/bin/bash", "/bin/bash") == nil, "no mismatch: both bash")
      check(shell.mismatch_target("/bin/bash", nil) == nil, "no mismatch: nil $SHELL")
      check(shell.mismatch_target(nil, "/bin/zsh") == nil, "no mismatch: nil resolved")

      if fails > 0 then io.stderr:write(fails.." smoke check(s) FAILED\n"); vim.cmd("cquit 1") end
      io.stdout:write("S4_SMOKE_OK\n")
  - RUN: timeout 60 nvim --headless --clean -u NORC +"luafile tests/shell_notices_smoke.lua" +qa
  - DEPENDENCIES: Task 1 + Task 2.

Task 4: CREATE tests/shell_notices_spec.lua — the plenary Level-2 gate (THE gate)
  - PATTERN: copy tests/shell_ensure_spec.lua's fake_bridge + make_fake_driver + the before_each/after_each
    save-restore block. ADD notify.reset() to before_each/after_each + vim.fn.executable save/restore.
  - HELPERS (copy from shell_ensure_spec.lua): fake_bridge(shell_path), make_fake_driver(),
    inject_fake_driver (the package.loaded["pi-bridge.shell.fish"]=... pattern).
  - make_fake_driver ALREADY supports `{ _fail = true }` → cb("spawn err: simulated", ...) (use for the
    spawn-err degrade case).
  - before_each/after_each MUST save+restore: vim.env.SHELL, pi.bridge, pi.descriptor, pi.config.shell,
    vim.fn.executable (stubbed for mismatch PATH cases), package.loaded["pi-bridge.shell.fish"], AND call
    notify.reset() + shell.reset().
  - LOCAL helper: stub_executable(names_true_set) → returns orig + installs a vim.fn.executable override
    returning 1 for names in the set, 0 otherwise. Restore in after_each.
  - LOCAL helper: wait_notify(category) → `vim.wait(200, function() return notify.did_notify(category) end, 5)`.
  - CASES (each wires fake_bridge + inject_fake_driver + shell.ensure first):
      1. HAPPY (resolved fish, $SHELL=/usr/bin/fish): ensure → wait_notify("shell-active") true;
         did_notify("shell-mismatch") false; did_notify("shell-degrade") false. Message check: capture
         the notify via a stubbed vim.notify OR assert did_notify only (did_notify is the contract).
      2. MISMATCH (resolved bash via fake_bridge("/bin/bash"), $SHELL=/bin/zsh, stub executable{zsh}):
         ensure → wait_notify("shell-mismatch") true; did_notify("shell-active") FALSE (ensure step 8b
         DID run — spawn succeeded — so first-run ALSO fires; this is correct: mismatch + first-run are
         independent. ASSERT BOTH fire). did_notify("shell-degrade") false.
         NOTE: re-read §17.4.3 — mismatch is resolution-time (independent of spawn success). So a healthy
         daemon under the mismatch condition fires BOTH shell-mismatch AND shell-active. This is the
         intended UX (the user gets the hint AND knows completion is active in bash). Document it.
      3. MISMATCH no-PATH (resolved bash, $SHELL=/bin/zsh, executable returns 0 for zsh): ensure →
         did_notify("shell-mismatch") FALSE (PATH check fails). did_notify("shell-active") true
         (healthy spawn). Confirms the PATH gate.
      4. MISMATCH resolved==$SHELL (resolved /bin/zsh, $SHELL=/bin/zsh): ensure → did_notify("shell-mismatch")
         FALSE (self-gating). did_notify("shell-active") true.
      5. DEGRADE no-driver (resolved "/usr/bin/nushell" — unknown basename, no driver module): ensure →
         wait_notify("shell-degrade") true; did_notify("shell-active") FALSE (suppression — step 8b not
         reached); did_notify("shell-mismatch") false (not bash).
      6. DEGRADE spawn-err (inject make_fake_driver({ _fail = true }), resolved fish): ensure →
         wait_notify("shell-degrade") true; did_notify("shell-active") FALSE.
      7. DEGRADE driver-threw (inject a driver whose start THROWS: start = function() error("boom") end,
         resolved fish): ensure → did_notify("shell-degrade") true; did_notify("shell-active") FALSE.
         (pcall(state.driver.start, ...) catches the throw → step 8c.)
      8. DEGRADE mid-session EOF (_reset): setup a healthy spawn first (shell.ensure ok), THEN call
         shell._reset() (simulate EOF) → did_notify("shell-degrade") flips to true. Confirms _reset emits.
      9. DEGRADE mid-session parse-threshold (_feed): setup healthy spawn, then call shell._feed with N
         (max_parse_failures, default 5) garbage chunks that fail decode → after the 5th, did_notify
         ("shell-degrade") true. (Drive _feed directly — it is a public function.)
      10. DEDUP (once-per-session): healthy spawn → wait_notify("shell-active"); capture that a SECOND
          ensure (or a second healthy spawn via reset+respawn) does NOT fire a second toast — assert
          notify.did_notify stays true + (optional) stub vim.notify to count calls == 1. Simplest:
          stub vim.notify to count; ensure healthy spawn; ensure again (cache hit, no re-fire); assert
          the shell-active notify count == 1. Then trigger _reset (degrade) → assert degrade count == 1
          (a second _reset does NOT bump it).
      11. SUPPRESSION (§17.9): the spawn-err case (6) ALREADY asserts first-run hint false on failure.
          Add an explicit assertion: under a failed spawn, did_notify("shell-active") is false AND
          did_notify("shell-degrade") is true — the EITHER/OR the PRD specifies.
      12. MISMATCH_TARGET pure unit cases (no daemon, no nvim): ("/bin/bash","/bin/zsh")=="zsh";
          ("/bin/bash","/usr/bin/fish")=="fish"; ("/bin/bash","/bin/sh")==nil (sh not tier-1);
          ("/bin/zsh","/bin/zsh")==nil; ("/bin/bash","/bin/bash")==nil; ("/bin/bash",nil)==nil;
          (nil,"/bin/zsh")==nil; ("","/bin/zsh")==nil; ("/bin/bash","")==nil.
      13. BASENAME (indirect via the messages, OR expose for test): if basename is module-local, test it
          via the mismatch_target input (already covered) — do NOT add a public seam for it. (If a public
          seam is desired for health.lua reuse later, that is P2.M3.T6, not S4.)
      14. never-throws: ensure with a nil cfg (pi.config.shell=nil → the AND-chain default {}); ensure
          with vim.fn.executable stubbed to THROW (pcall guards); notify.once with a malformed message
          (notify.lua pcalls vim.notify). All no-throw.
  - PLACEMENT: a top-level describe("pi-bridge.shell notices (P2.M2.T3.S4)", function() … end).
  - DEPENDENCIES: Task 1 + Task 2.

Task 5: VERIFY — run the gates (no file changes)
  - RUN Level 1 (smoke): timeout 60 nvim --headless --clean -u NORC +"luafile tests/shell_notices_smoke.lua" +qa
  - RUN Level 2 (the new spec): timeout 90 nvim --headless --clean -u tests/minimal_init.lua -c 'lua require("plenary.busted").run("tests/shell_notices_spec.lua")'
  - RUN REGRESSION (the shell + completion suites MUST stay green — S4 is additive):
      timeout 90 nvim --headless --clean -u tests/minimal_init.lua -c 'lua require("plenary.busted").run("tests/shell_ensure_spec.lua")'
      timeout 90 nvim --headless --clean -u tests/minimal_init.lua -c 'lua require("plenary.busted").run("tests/shell_request_spec.lua")'
      timeout 90 nvim --headless --clean -u tests/minimal_init.lua -c 'lua require("plenary.busted").run("tests/shell_complete_current_spec.lua")'
      timeout 90 nvim --headless --clean -u tests/minimal_init.lua -c 'lua require("plenary.busted").run("tests/completion_spec.lua")'
      timeout 90 nvim --headless --clean -u tests/minimal_init.lua -c 'lua require("plenary.busted").run("tests/shell_spec.lua")'
  - EXPECT: all green. If shell_ensure_spec fails, it is almost certainly because a case asserts
    `state.failed == true` on a failure path AND the new notify.once call ran before the assert —
    re-check the insertion is BEFORE the `return on_ready(...)` / after `state.failed = true` (it must
    not change WHEN state.failed is set, only add a notify after). If completion_spec fails, S4 must NOT
    have touched completion.lua (revert any accidental edit there).
```

### Implementation Patterns & Key Details

```lua
-- === M.mismatch_target: the PURE §17.4.3 condition (Task 1) ===
-- Parts 1 & 2 only (resolved==bash AND $SHELL∈{zsh,fish}). PATH check is at the call site.
-- Self-gating across every `prefer` (research §"Self-gating"). Returns nil (not false) for `if X then`.
function M.mismatch_target(resolved_shell, env_shell)
  if type(resolved_shell) ~= "string" or resolved_shell == "" then return nil end
  if basename(resolved_shell) ~= "bash" then return nil end
  if type(env_shell) ~= "string" or env_shell == "" then return nil end
  local ebase = basename(env_shell)
  if ebase ~= "zsh" and ebase ~= "fish" then return nil end
  return ebase
end

-- === basename: the shared path-basename helper (Task 1) ===
local function basename(p)
  if type(p) ~= "string" or p == "" then return "?" end
  local b = p:gsub(".*/", "")
  return b == "" and "?" or b
end

-- === The mismatch emission (Task 2A, ensure step 4) — the ONE non-obvious wiring ===
-- PURE condition + the PATH gate (vim.fn.executable, pcall'd) + notify.once (dedup'd). Fast-safe.
pcall(function()
  local richer = M.mismatch_target(resolved, vim.env.SHELL)
  if richer then
    local ok, ex = pcall(vim.fn.executable, richer)
    if ok and ex == 1 then
      require("pi-bridge.notify").once("shell-mismatch", vim.log.levels.WARN,
        "pi-bridge: pi runs commands in bash; using bash completion to match. For your native "
        .. richer .. " completions, set pi's shellPath to " .. (vim.env.SHELL or richer)
        .. " (then completion and execution both use it). :help pi-bridge-shell")
    end
  end
end)

-- === The first-run hint (Task 2D, ensure step 8b) — structural suppression ===
-- Lives ONLY in the spawn-SUCCESS cb. A failed spawn (5/8a/8c) returns before reaching here →
-- the hint CANNOT fire on failure. No flag needed. notify.once dedups to once-per-session.
pcall(function()
  require("pi-bridge.notify").once("shell-active", vim.log.levels.INFO,
    "pi-bridge: shell completion active (`" .. basename(state.shell) .. "`); :help pi-bridge-shell")
end)

-- === The degrade emission (Task 2B/C/E/F/G) — ONE category, FIVE sites ===
-- All five collapse to category "shell-degrade" via notify.once dedup → ONE toast/session (§17.12).
-- The message is canonical (names state.shell's basename); whichever failure fires first wins.
pcall(function()
  require("pi-bridge.notify").once("shell-degrade", vim.log.levels.WARN,
    "pi-bridge: shell completion unavailable for `" .. basename(state.shell)
    .. "`; :help pi-bridge-shell")
end)

-- === Why this is fast-context-safe (the #1 trap) ===
-- _reset runs in the read_start EOF cb (libuv fast context); _feed runs in the read_start data cb.
-- notify.once does: a `seen[category]` table write (fast-safe) + a vim.schedule of vim.notify (deferred
-- to the nvim main loop). It does NO vim.api.* in the fast path. So calling it from _reset/_feed is
-- correct (mirrors init.lua L167-178 calling once() from the handshake/disconnect cbs). Do NOT wrap the
-- notify.once CALL in vim.schedule — only the notify itself is scheduled, and that is notify.lua's job.
```

### Integration Points

```yaml
NOTIFY EMITTER (REUSED — no change):
  - lua/pi-bridge/notify.lua: M.once(category, level, msg) / M.did_notify(category) / M.reset().
    Fast-context-safe (vim.schedule's the notify). Dedup by category. S4 reuses it UNCHANGED.

LIFECYCLE (the emission points — all pre-existing, S4 only inserts notify calls):
  - shell.lua M.ensure (L285-360): steps 4 (resolve → mismatch), 5 (no-driver → degrade),
    8a (spawn-err → degrade), 8b (spawn-success → first-run), 8c (driver-threw → degrade).
  - shell.lua M._reset (L~545-560, EOF → degrade).
  - shell.lua M._feed (L~440-490, parse-threshold → degrade).

TRIGGER PATH (UNCHANGED — S4 does not touch it):
  - completion.lua do_shell_fetch (L411-447) → shell.complete_current (S3) → M.request (S4 of P2.M1.T2)
    → M.ensure. The notices fire INSIDE ensure; do_shell_fetch's cb stays a silent `if err then return end`.

CONFIG (no new key):
  - S4 reads config the same defensive way as the rest of shell.lua: `(pi.config and pi.config.shell) or {}`.
    The notices need NO config key (dedup is via notify.lua categories). config.shell lands in P2.M3.T6.S1.

FORWARD CONTRACTS (do NOT implement in S4):
  - menu visual_cue ($ gutter for shell context) → S5 (P2.M2.T3.S5).
  - fish/zsh/bash drivers → P2.M2.T4 / P2.M3.T5 (their spawn success/failure flows THROUGH ensure, so the
    S4 notices fire for free once a driver exists — no driver-side notify code needed).
  - :checkhealth pi-bridge shell section → P2.M3.T6.S2 (may surface notify.did_notify state if desired).
  - doc/pi-bridge-shell.txt → P2.M3.T6.S4 (documents the three notices' wording + the trust model).
```

---

## Validation Loop

### Level 1: Syntax & Style (Immediate Feedback)

```bash
# From the repo root. Confirm the edited module LOADS + mismatch_target is a pure function.
# ⛔ NEVER heredoc→nvim stdin (AGENTS.md HARD RULE). Write to a FILE, then :luafile it.
cat > /tmp/s4_loadcheck.lua <<'LUA'
local ok, m = pcall(require, "pi-bridge.shell")
assert(ok, "require failed: " .. tostring(m))
assert(type(m.mismatch_target) == "function", "mismatch_target is a function")
-- PURE unit checks (no nvim, no vim.fn, no state — proves the helper is deterministic)
assert(m.mismatch_target("/bin/bash", "/bin/zsh") == "zsh", "bash+zsh → zsh")
assert(m.mismatch_target("/bin/bash", "/usr/bin/fish") == "fish", "bash+fish → fish")
assert(m.mismatch_target("/bin/bash", "/bin/bash") == nil, "both bash → nil")
assert(m.mismatch_target("/bin/zsh", "/bin/zsh") == nil, "resolved zsh → nil (self-gate)")
assert(m.mismatch_target("/bin/bash", nil) == nil, "nil $SHELL → nil")
assert(m.mismatch_target(nil, "/bin/zsh") == nil, "nil resolved → nil")
-- ensure/request/reset surface intact (regression — S4 added only mismatch_target + notify calls)
assert(type(m.ensure) == "function" and type(m.request) == "function" and type(m.reset) == "function")
print("S4_LOAD_OK")
LUA
timeout 30 nvim --headless --clean -u NORC -c 'set rtp+=.' +"luafile /tmp/s4_loadcheck.lua" +qa
echo "exit=$?   # 0 = pass (prints S4_LOAD_OK)"

# Then the plenary-free smoke (Task 3): the file-based end-to-end gate (fake driver; happy + mismatch paths).
timeout 60 nvim --headless --clean -u NORC +"luafile tests/shell_notices_smoke.lua" +qa
echo "exit=$?   # 0 = pass (prints S4_SMOKE_OK)"

# stylua formatting check (if the repo uses it — matches CI in PRD §14):
# stylua --check lua/pi-bridge/shell.lua tests/shell_notices_spec.lua tests/shell_notices_smoke.lua
```

### Level 2: Unit Tests (Component Validation) — THE GATE

```bash
# The new plenary spec for the notices (Task 4). This is S4's primary validation gate.
timeout 90 nvim --headless --clean -u tests/minimal_init.lua \
  -c 'lua require("plenary.busted").run("tests/shell_notices_spec.lua")'
echo "exit=$?   # 0 = all green (14 case groups: happy, mismatch±PATH, self-gate, degrade×5, dedup,
#        suppression, mismatch_target unit, never-throws)"

# (Optional, fast feedback) the existing shell smoke — confirms no load regression:
timeout 60 nvim --headless --clean -u NORC +"luafile tests/shell_smoke.lua" +qa
echo "exit=$?"
```

### Level 3: Integration Testing (System Validation)

```bash
# REGRESSION — the shell + completion suites MUST stay green. S4 is additive (notify calls + a pure
# helper); if any of these fail, S4 broke a shared seam (most likely a state.failed-timing change on a
# failure path, or an accidental completion.lua edit).
timeout 90 nvim --headless --clean -u tests/minimal_init.lua \
  -c 'lua require("plenary.busted").run("tests/shell_ensure_spec.lua")'           # ensure lifecycle (the edit target)
timeout 90 nvim --headless --clean -u tests/minimal_init.lua \
  -c 'lua require("plenary.busted").run("tests/shell_request_spec.lua")'          # M.request (ensure's caller)
timeout 90 nvim --headless --clean -u tests/minimal_init.lua \
  -c 'lua require("plenary.busted").run("tests/shell_complete_current_spec.lua")' # S3 (complete_current)
timeout 90 nvim --headless --clean -u tests/minimal_init.lua \
  -c 'lua require("plenary.busted").run("tests/completion_spec.lua")'             # do_shell_fetch routing
timeout 90 nvim --headless --clean -u tests/minimal_init.lua \
  -c 'lua require("plenary.busted").run("tests/shell_spec.lua")'                  # resolve_shell/pick_driver/reset
echo "all exit 0 = no regression"

# REAL-daemon integration (OPTIONAL follow-on; NOT required for S4 sign-off — the drivers are P2.M2.T4).
# Once a fish driver exists, a tests/completion_shell_smoke.lua driving a real `fish -i` daemon through
# complete_current → the menu is the natural end-to-end proof that the first-run hint fires against a
# REAL resolved shell. For S4, the mocked fake-driver spec (Task 4) IS the integration proof at the
# notice layer (it exercises the REAL ensure + REAL notify.lua against an injected fake driver — every
# layer except the subprocess). Per AGENTS.md: the plenary spec + file-based smoke cover the end-to-end
# surface; do NOT invent a stdin-based nvim E2E (the ⛔ HARD RULE heredoc trap).
```

### Level 4: Creative & Domain-Specific Validation
N/A for S4 (no UI, no daemon subprocess, no health-check, no docs to ship — those are S5 + P2.M2.T4 + P2.M3.T6). The vim.notify toast rendering itself is nvim's stock UI (no custom floating window).

---

## Final Validation Checklist

### Technical Validation
- [ ] Level 1 load-check prints `S4_LOAD_OK`, exit 0; `M.mismatch_target` is a function; pure unit cases pass.
- [ ] `tests/shell_notices_smoke.lua` prints `S4_SMOKE_OK`, exit 0.
- [ ] `tests/shell_notices_spec.lua` plenary run exits 0 (all 14 case groups).
- [ ] Regression: `shell_ensure_spec.lua` + `shell_request_spec.lua` + `shell_complete_current_spec.lua` + `completion_spec.lua` + `shell_spec.lua` all exit 0.
- [ ] No nvim command in this PRP pipes a heredoc into nvim stdin (AGENTS.md ⛔ HARD RULE); every nvim invocation is wrapped in `timeout`.

### Feature Validation
- [ ] Mismatch (§17.4.3): bash resolved + `$SHELL`=zsh/fish + on PATH → `notify.did_notify("shell-mismatch")` true (case 2).
- [ ] Mismatch PATH gate: zsh/fish NOT on PATH → no mismatch (case 3).
- [ ] Mismatch self-gating: resolved == `$SHELL` → no mismatch (case 4).
- [ ] First-run (§17.9): healthy spawn → `notify.did_notify("shell-active")` true (INFO) (case 1).
- [ ] First-run suppression: failed spawn → `shell-active` false, `shell-degrade` true (cases 5/6/7/11).
- [ ] Degrade (§17.12): no-driver + spawn-err + driver-threw + `_reset` EOF + `_feed` parse-threshold → `shell-degrade` true (cases 5/6/7/8/9).
- [ ] Dedup: each category fires at most once per session (case 10).
- [ ] Bare `!` → no notice of any category (complete_current short-circuits; ensure not reached).
- [ ] `M.mismatch_target` pure unit cases pass (case 12).
- [ ] Never throws (bad cfg / throwing vim.fn.executable / malformed msg) (case 14).

### Code Quality Validation
- [ ] Follows existing patterns: `notify.once` call shape matches init.lua L75/L167; pure helper matches `completion.M.is_attachment_context` / `M.shell_word_prefix`; basename matches the inline `:gsub(".*/","")` idiom.
- [ ] File placement: `M.mismatch_target` in the §17.4 section; `basename` module-local near `close_handles`/`dbg`; emission points at the documented anchors.
- [ ] Anti-patterns avoided: no new state field; no new config key; no completion.lua edit; no double-gating of the mismatch condition; no vim.schedule wrapper around notify.once (notify.lua schedules internally).
- [ ] Dependencies: `notify.lua` reused unchanged; no new `require` beyond `pi-bridge.notify` (already a sibling).
- [ ] pcall discipline: every `notify.once` + `vim.fn.executable` + `require` is `pcall`'d (fast-context + never-throws contract).

### Documentation & Deployment
- [ ] No new env var, no new config key (dedup is via notify.lua categories) → nothing for the user to set.
- [ ] The three notice messages include `:help pi-bridge-shell` (the doc lands in P2.M3.T6.S4 — the pointer is forward-compatible: an absent help tag degrades to "no help for pi-bridge-shell" harmlessly).
- [ ] The mismatch notice's `shellPath` advice is actionable as-is (the user sets pi's `shellPath` setting; no plugin-side config).

---

## Anti-Patterns to Avoid

- ❌ Don't move the degrade notify into `completion.lua`'s do_shell_fetch — `_reset`/`_feed` (mid-session daemon crashes) have NO completion.lua caller; the notify MUST fire from shell.lua where `state.failed` is set.
- ❌ Don't add a `state.shell_announced` / `state.degraded` flag — `notify.once`'s category dedup already enforces once-per-session; a flag is redundant + can drift.
- ❌ Don't add an explicit `cfg.prefer == "pi"` check to the mismatch condition — `M.mismatch_target` is self-gating across every `prefer` value (research §"Self-gating"); double-gating risks drifting from `resolve_shell`.
- ❌ Don't put the `vim.fn.executable` PATH check inside `M.mismatch_target` — it makes the helper non-deterministic (vim.fn-dependent) + hard to unit-test. Keep it at the call site.
- ❌ Don't wrap the `notify.once` call in `vim.schedule` — `notify.once` ALREADY schedules the notify internally (notify.lua L23); wrapping it double-defers for no benefit + can reorder vs the dedup-check.
- ❌ Don't edit `notify.lua` / `completion.lua` / `init.lua` config — S4 is additive to `shell.lua` only. `notify.lua`'s `once`/`did_notify`/`reset` already cover this; `completion.lua`'s do_shell_fetch "S4 notifies" forward-contract is satisfied transitively.
- ❌ Don't add a new config key — the notices need none (dedup via categories). `config.shell` is P2.M3.T6.S1's job; read it the same defensive `(pi.config and pi.config.shell) or {}` way.
- ❌ Don't catch all exceptions broadly — each `notify.once`/`vim.fn.executable`/`require` is individually `pcall`'d (targeted), matching init.lua L75 + the rest of shell.lua.
- ❌ Don't pipe a heredoc into `nvim` stdin (AGENTS.md ⛔ HARD RULE) — every test snippet goes in a `.lua` file run via `+"luafile <file>" +qa`, wrapped in `timeout`.

---

**Confidence Score: 9/10** — one-pass success. The task is small (1 pt: a pure helper + six pcall'd notify calls + tests) and every emission anchor is verified against the current `shell.lua` source (research §"Exact emission points"). The one residual risk is a sibling task (S5/S6) having drifted the exact anchor strings in `ensure`/`_reset`/`_feed` since this PRP was written — mitigated by the note to LOCATE by step semantics (the `state.failed = true` on each permanent-failure path) rather than fragile line numbers. The `notify.lua` API (`once`/`did_notify`/`reset`) is stable and already exercised by init.lua + bridge_notify_spec. Dedup semantics are well-understood (categories). No daemon subprocess, no UI, no config key, no dependency on unbuilt tasks (P2.M2.T4 drivers / P2.M3.T6 config) — the notices fire through `ensure` for free once a driver exists.