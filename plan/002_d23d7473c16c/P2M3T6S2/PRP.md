# PRP — P2.M3.T6.S2: `health.lua` shell section (`:checkhealth pi-bridge`)

**Parent:** P2.M3.T6 (`:checkhealth` shell section + `doc/pi-bridge-shell.txt` + config)
**Component:** B (`pi-bridge.nvim`) — `lua/pi-bridge/health.lua` (primary) + `lua/pi-bridge/shell.lua` (one read-only accessor)
**PRD anchor:** §17.15 *Testing strategy* (the `:checkhealth pi-bridge` shell bullet — "reports resolved shell, source, driver detected, daemon health, last error; live-spawns each available shell's driver for a 1-shot smoke"), §17.4 *Shell resolution* (the `source` labels), §17.6 *Per-shell drivers* (the tier labels), §17.12 *Failure modes & degradation* (the health-flag semantics)
**Size:** 1 pt — add a 5th section to `health.lua`'s `M.check()` reporting the §17 shell-completion subsystem state, plus a minimal read-only `shell.status()` accessor so `check()` (sync, never-throws, never-blocks) can surface daemon health without spawning.
**Builds on:** S1 (`init.lua` shell-config block, COMPLETE — `config.shell` is now populated, so health can read effective prefer/drivers), P2.M1.T2.S2–S6 (`shell.lua` resolve/ensure/request/teardown, COMPLETE), P2.M1.T1.S4 (`bridge.lua` exposes `server_info.shell/shellSource/shellPath` + `get_shell_info()`, COMPLETE), P2.M2.T3.S4 (shell notices via `notify.lua` — categories `"shell-mismatch"`/`"shell-degrade"`/`"shell-active"`, COMPLETE), P2.M3.T5.S1–S3 (zsh/bash/unknown drivers, COMPLETE), the existing `health.lua` (4 sections + the `M.check` loader contract + the "never spawn / never throw / never block" invariants, COMPLETE). It is the **diagnostic surface** that makes the shell subsystem observable — the last piece a user reaches for when `!git ch<Tab>` shows nothing.

---

## Goal

**Feature Goal:** Add a **5th section** to `:checkhealth pi-bridge` titled **"pi-bridge shell completion"** that reports, in one read-only pass, everything a user (or maintainer) needs to diagnose why shell completion in `!`/`!!` bash mode is or isn't working: the resolved execution shell + its resolution `source` (§17.4), the detected driver + its quality tier (§17.6), the daemon's liveness/health flags (§17.12), the effective `config.shell` knobs that drove the resolution, and the last shell-related notice that fired (the "last error" surrogate via `notify.did_notify`). The section follows the **exact invariants** the existing 4 sections already honor: it is a **pure read-only consumer** of state `shell.lua`/`init.lua`/`bridge.lua` already compute, it **never throws** (every probe `pcall`-wrapped), it **never spawns** a live daemon (uv.spawn is async; its cb fires after `check()` returns → incomplete report / hang risk — the same reason the existing sections never issue a live `ping`), and it treats **dormant** (no `PI_NVIM_BRIDGE`) as the expected `info` state, never an `error`/`warn`.

**Deliverable:** Edited `lua/pi-bridge/health.lua` (additive — one new section appended inside `M.check()`, after the existing 4) + one **new read-only accessor** `M.status()` added to `lua/pi-bridge/shell.lua` (returns a snapshot of `state`'s observable fields — `shell`, `driver_basename`, `proc_alive`, `inflight`, `failed`, `parse_failures` — without exposing the raw `state` table, preserving shell.lua's "minimal public surface" design). Plus plenary spec cases **appended to `tests/health_spec.lua`** (the established home — no new file) covering: dormant (section skipped with info), resolved-shell-with-source reporting, driver-detected+tier, daemon-not-yet-spawned (info, not error — lazy default), daemon-alive (ok), `state.failed=true` (warn with degrade advice), `notify.did_notify("shell-degrade")` surrogate, config-disabled driver (warn), and the never-throws/never-blocks invariants. Plus a plenary-free smoke assertion **appended to `tests/health_smoke.lua`** (Level-1 gate: the new section `start`s and `check()` exits 0 with no throw).

**Success Definition:**
- `:checkhealth pi-bridge` renders a 5th section **"pi-bridge shell completion"** in every session (dormant and active), whose content correctly reflects the live `shell.lua`/`init.lua`/`bridge.lua` state.
- The section reports the **resolved shell path + source label** (`"pi"`/`"$SHELL"`/`"default"`/`"config"`) via `shell.resolve_shell(config.shell.prefer)` (a PURE function — safe to call from `check()`; never mutates state), NOT by re-deriving it.
- The section reports the **detected driver** (fish/zsh/bash/none) + its **tier** (`"tier-1"` for fish/zsh, `"tier-2"` for bash, `"unknown"` otherwise) via the resolved-shell basename + a hardcoded tier map (drivers do NOT export `M.name`/`M.tier` — verified).
- The section reports **daemon health** via the new `shell.status()` accessor: `proc_alive` (running) → `ok`; not spawned yet + not failed → `info "not spawned (lazy; will start on first `!`)"`; `failed == true` → `warn` with the §17.12 advice ("the menu will not open for `!` lines; run `:messages` for the degrade notice").
- The section reports the **last shell notice** that fired via `notify.did_notify` for the three shell categories (`"shell-mismatch"`, `"shell-degrade"`, `"shell-active"`) — a deterministic, sync surrogate for "last error" (the actual last-error string is not stored; the category conveys it).
- The section reports the **effective config** that drove resolution: `config.shell.prefer`, `config.shell.enabled`, and which drivers are user-disabled (`config.shell.drivers.<base> == false`).
- **Dormant session** (`PI_NVIM_BRIDGE` unset): the section renders an `info "shell completion is dormant (no pi editor session)"` and skips the daemon probes (mirrors the existing dormant gate in sections 2–3). NEVER `error`/`warn` for dormancy.
- **Never throws** — every probe in the new section is `pcall`-wrapped (the loader pcall at runtime/health.lua:458 blanks the WHOLE report on one uncaught throw; the existing sections honor this; the new one must too).
- **Never blocks / never spawns** — the section issues NO `uv.spawn`, NO `bridge.request`, NO live daemon smoke. (PRD §17.15's "live-spawns each available shell's driver for a 1-shot smoke" is **aspirational** and **out of scope for v1** — it is in direct tension with the `check()` sync/never-block invariant; documented as a forward-contract in the PRP + surfaced as a `health.info` line pointing at `:help pi-bridge-shell`. The SAFE, in-variant behavior is state-only reporting.)
- Regression green: `health_spec.lua`, `health_smoke.lua`, `shell_spec.lua`, `shell_ensure_spec.lua`, `shell_request_spec.lua`, `init_spec.lua`, `completion_spec.lua`, `activate_spec.lua` ALL exit 0.

---

## User Persona

**Target User:** A pi user editing a prompt in the Neovim external editor (`Ctrl+G`) who typed `!git ch<Tab>` expecting shell completion and **nothing happened** — no menu, no error. They don't know whether the daemon failed to spawn, their shell is unsupported, their `$SHELL`/pi-shell mismatched, or they misconfigured `setup({ shell = ... })`.

**Use Case:** The user runs `:checkhealth pi-bridge`, scrolls to the **"pi-bridge shell completion"** section, and in one read sees: "resolved shell: `/bin/zsh` (source: `$SHELL`); driver: zsh (tier-1); daemon: not spawned (lazy; will start on first `!`); prefer: `pi`; drivers: fish/zsh/bash enabled." If something is wrong they see a `warn` with actionable advice ("daemon failed — run `:messages` for the degrade notice; the menu will not open for `!` lines"). They never have to read source or tail a debug log to diagnose the shell subsystem.

**User Journey:**
1. `!git ch<Tab>` shows nothing in a pi editor session.
2. User runs `:checkhealth pi-bridge`.
3. The shell section reports e.g. `warn: daemon failed to start (unknown shell /bin/dash); shell completion is disabled for this session` with advice `:help pi-bridge-shell` + "set `shellPath` to a supported shell or `prefer` to a supported path".
4. User fixes their config (`setup({ shell = { prefer = "zsh" } })`) or their pi `shellPath`, re-opens the editor, re-runs `:checkhealth` → `ok: daemon ready (zsh, tier-1)`.
5. `!git ch<Tab>` now completes.

**Pain Points Addressed:**
- **Silent degrade is invisible.** §17.12 mandates shell failures degrade *silently* (one dedup'd notice; never block). Without a health surface, a user whose daemon crashed mid-session has NO way to see that `state.failed == true` short of reading `:messages` (which may have scrolled). The health section makes the silent-degrade state **queryable on demand**.
- **"Why is completion bash-quality when I'm a zsh user?"** The §17.4.2 mismatch (pi runs `!` in bash; user's `$SHELL` is zsh) is the single sharpest correctness footgun. The health section surfaces the resolved shell + source so the user sees "resolved: `/bin/bash` (default)" vs their `$SHELL=/bin/zsh` and understands the §17.4.3 notice they may have missed.
- **Config mistakes are opaque.** A user who set `drivers = { zsh = false }` and wonders why zsh completion is off has no feedback loop. The health section reports the effective config so the cause is visible.

---

## Why

- **Business value:** `:checkhealth` is the *standard* Neovim diagnostic entrypoint — every plugin user reaches for it first when something is off. A shell subsystem that silently degrades (by design, §17.12) is *only* debuggable through `:checkhealth` or `:messages`. S2 makes the subsystem observable, turning "completion doesn't work and I don't know why" into a 10-second self-serve diagnosis. This is the difference between a shipped feature and a feature users abandon.
- **Integration with existing features:**
  - **`health.lua` (4 sections, COMPLETE)** already establishes every invariant the shell section must follow: `M.check` is a table field (loader contract), never-throws (pcall every probe), never-blocks (no live RPC), dormant-is-`info`-not-error, read `vim.health` once at `check()` top (stub-friendly for tests), read state from `require("pi-bridge")`/`.bridge` INSIDE `check()` (call-time, pcall-wrapped). S2 appends ONE section honoring all of these — zero new patterns.
  - **`shell.lua` (COMPLETE)** already exposes `M.get_shell()` (→ `state.shell`), `M.resolve_shell(prefer)` (PURE), `M.pick_driver(resolved)` (PURE), `M.mismatch_target(resolved, env)` (PURE). S2 adds ONE read-only `M.status()` snapshot accessor (the minimal seam to surface `failed`/`parse_failures`/`proc_alive`/`inflight` without exposing the raw `state` table — preserving shell.lua's "minimal public surface" design, L283-285).
  - **`init.lua` shell-config (S1, COMPLETE)** — `config.shell` is now populated, so health reads `config.shell.prefer`/`.enabled`/`.drivers` directly (defensively) to report the effective config.
  - **`bridge.lua` shell fields (P2.M1.T1.S4, COMPLETE)** — `bridge.server_info.shell`/`.shellSource`/`.shellPath` + `bridge.get_shell_info()` are available; health reports the descriptor's advertised shell as a cross-check against the resolved shell.
  - **`notify.lua` (COMPLETE)** — `did_notify("shell-degrade"|"shell-mismatch"|"shell-active")` is the sync, deterministic surrogate for "last error / last notice" (the actual last-error string isn't stored; the category + the `vim.log.levels` conveys it).
- **Problems this solves, for whom:** Gives end-users a single deterministic command to triage the shell subsystem. Gives maintainers a reproducible state snapshot in bug reports ("run `:checkhealth pi-bridge` and paste the shell section"). Closes the observability gap created by §17.12's silent-degrade design.

---

## What

### User-visible behavior
- `:checkhealth pi-bridge` now renders a 5th section, **"pi-bridge shell completion"**, after the existing "external tools (fd)" section.
- In a **dormant** session (no `PI_NVIM_BRIDGE`): the section renders a single `info "shell completion is dormant (no pi editor session)"` and skips the daemon probes.
- In an **active** session with the daemon **not yet spawned** (the lazy default — `warm_on_enter=false`): `info "daemon not spawned yet (lazy; starts on first `!`/`!!`)"` + the resolved shell/source/driver/tier + effective config.
- In an **active** session with the daemon **alive**: `ok "daemon ready (<basename>, <tier>)"` + resolved shell/source + effective config.
- In an **active** session with the daemon **failed** (`state.failed`): `warn "daemon failed — shell completion is disabled for `!`/`!!` lines this session"` with advice `[":messages for the degrade notice", ":help pi-bridge-shell"]` + the resolved shell/driver + `state.parse_failures` count.
- If a shell notice already fired (`notify.did_notify`), an `info` line reports which (`"a shell-mismatch notice fired earlier this session"` etc.).
- If a driver is user-disabled (`config.shell.drivers.<base> == false`) and it is the one that WOULD have been picked, a `warn` reports it.
- No change to any of the existing 4 sections. No change to `shell.lua` behavior (the new `M.status()` is a pure read). No new user-facing command or config key.

### Technical requirements
1. **New `M.status()` accessor in `shell.lua`** — returns a snapshot table of `state`'s observable fields WITHOUT exposing the raw `state` table (minimal surface, per shell.lua L283-285). Fields: `shell` (string|nil), `driver_basename` (string|nil — derived from `state.shell` basename, NOT a stored field), `proc_alive` (bool — `state.proc ~= nil`), `inflight` (bool), `failed` (bool), `parse_failures` (int). `M.status()` is a plain table-field read; **never throws** (mirrors `M.get_shell()`). Doc comment cites §17.15 ("read-only snapshot for `:checkhealth`") + the never-spawn-from-health invariant.
2. **New section in `health.lua`'s `M.check()`** — appended AFTER the existing 4 sections (lowest priority; the version/bridge/fd sections are more universally relevant). Section name: `"pi-bridge shell completion"`. Structure:
   - **Dormant gate first** — if `PI_NVIM_BRIDGE` is unset (no descriptor + no env var) → `health.info("shell completion is dormant (no pi editor session)")` and `return` from the section (skip the daemon probes). Mirrors sections 2–3's dormant gate. NEVER error/warn for dormancy.
   - **Resolved shell + source** — `pcall(shell.resolve_shell, config.shell.prefer)` → `(path, source)`; report both via `health.info`. Cross-check against `bridge.get_shell_info().shell` (the descriptor's advertised shell) via a second `info` if they differ. Use `shell.resolve_shell` (PURE, never mutates state) — do NOT call `shell.ensure` or read `state.shell` as the primary source (resolve shows the *would-be* resolution even pre-spawn; `state.shell` is nil pre-spawn).
   - **Driver + tier** — `basename(resolved)` + a local tier map `{fish="tier-1", zsh="tier-1", bash="tier-2"}`; report via `info`. If `shell.pick_driver(resolved)` returns nil → `warn "no driver for <basename> (unsupported shell or disabled via config)"`. Report user-disabled driver explicitly if `config.shell.drivers.<base> == false`.
   - **Daemon health** — `pcall(shell.status)`; branch on `failed` (warn + advice), `proc_alive` (ok), else (info "not spawned yet (lazy)"). Report `parse_failures` if `> 0`. Report `inflight` only if it is stuck (`inflight == true` AND a separate stale-detection heuristic — OUT OF SCOPE for v1; just report the flag via info if true).
   - **Last notice** — `pcall(notify.did_notify, cat)` for each of `{"shell-mismatch","shell-degrade","shell-active"}`; report the first that is true via `info`.
   - **Effective config** — `pcall` read `config.shell.prefer`/`.enabled`; report via `info`. Report `enabled == false` as a `warn "shell completion is disabled in config (enabled=false)"`.
3. **Never-throws invariant** — EVERY probe in the new section is wrapped in `pcall` (the loader pcall at runtime/health.lua:458 blanks the whole report on one throw; the existing sections honor this; the new one must too). Read `vim.health`, `require("pi-bridge")`, `require("pi-bridge.shell")`, `require("pi-bridge.notify")`, `require("pi-bridge.bridge")` INSIDE `check()` (call-time, not module-level — the test swaps `vim.health` in `before_each`).
4. **Never-blocks / never-spawns invariant** — the new section issues NO `uv.spawn`, NO `bridge.request`, NO live daemon smoke, NO `shell.ensure`. It reads ONLY: `shell.status()`, `shell.resolve_shell()`, `shell.pick_driver()` (all PURE / table-reads), `notify.did_notify()` (table-read), `bridge.get_shell_info()` (table-read), `config.shell.*` (table-read). PRD §17.15's "live-spawns each available shell's driver for a 1-shot smoke" is **aspirational and OUT OF SCOPE for v1** — it conflicts with the sync `check()` invariant (uv.spawn's cb fires after `check()` returns → incomplete report / hang). Document it as a forward-contract + emit a single `health.info` line: "for a live driver smoke, run `:PiBridgeShellSmoke` (planned, see `:help pi-bridge-shell`)" — OR omit the line entirely if that command doesn't exist yet (it doesn't — S2 does NOT add it; just the info pointer is optional). **Decision: omit the live-smoke pointer line** (don't reference a command that doesn't exist); document the forward-contract in the PRP only.
5. **`shell.status()` is the ONLY `shell.lua` edit.** No other shell.lua change. No edits to `bridge.lua`, `notify.lua`, `init.lua`, `completion.lua`, the drivers, `menu.lua`, `ftplugin/pi-prompt.lua` (S3 owns teardown wiring), `plugin/pi-bridge.lua`. S2 is `health.lua` + one accessor in `shell.lua` + tests ONLY.
6. **No new files** — tests APPEND to `tests/health_spec.lua` (the established home) + `tests/health_smoke.lua`. No new test files.

### Success Criteria
- [ ] `:checkhealth pi-bridge` renders a 5th section **"pi-bridge shell completion"** (verified: a `health.start("pi-bridge shell completion")` call is captured by the test stub).
- [ ] Dormant session (`PI_NVIM_BRIDGE` unset) → the section emits `info "shell completion is dormant ..."` and does NOT call `shell.status`/`resolve_shell`/`pick_driver` (the dormant gate returns before them — assert no `start("pi-bridge shell completion")`-section probes run, OR assert the dormant info line is present + no `error`/`warn`).
- [ ] Active session, daemon not spawned, `failed == false` → section emits `info` containing "not spawned" (or equivalent) + `info` with the resolved shell path + `info` with the source label + `info` with the driver basename + tier. NO `error`.
- [ ] Active session, `status.proc_alive == true` → section emits `ok` containing "daemon ready" + the basename + tier.
- [ ] Active session, `status.failed == true` → section emits `warn` containing "failed"/"disabled" with a TABLE advice (`["...", "..."]`) + an `info` with `parse_failures` count (if `> 0`).
- [ ] `notify.did_notify("shell-degrade") == true` → section emits `info` mentioning the degrade notice.
- [ ] `config.shell.enabled == false` → section emits `warn` mentioning `enabled` / disabled.
- [ ] Resolved shell basename with no driver (e.g. `/bin/dash`) → section emits `warn "no driver"` (via `pick_driver` returning nil).
- [ ] User-disabled driver (`config.shell.drivers.zsh == false`, resolved=zsh) → section emits `warn` mentioning the disabled driver.
- [ ] `shell.status()` returns a table with exactly `{shell, driver_basename, proc_alive, inflight, failed, parse_failures}`; `proc_alive == (state.proc ~= nil)`; `failed == state.failed`; `parse_failures == state.parse_failures`; it does NOT expose the raw `state` table or the `proc`/`stdin`/`stdout` handles.
- [ ] `shell.status()` never throws (a plain table-field read — assert it returns a table even when `state` is at its initial literal).
- [ ] `M.check()` never throws: wrap the whole new section in a top-level `pcall` (belt-and-suspenders, mirroring the existing sections' per-probe pcall + the loader's outer pcall) OR ensure every probe is individually pcall'd (the existing pattern). **Decision: per-probe pcall** (matches the existing sections exactly; a single section-level pcall would hide WHICH probe failed).
- [ ] The new section issues ZERO `uv.spawn` / `bridge.request` / `shell.ensure` calls (assert in spec via a spy on `shell.ensure` that it is NOT called during `check()`).
- [ ] Regression green: `health_spec.lua`, `health_smoke.lua`, `shell_spec.lua`, `shell_ensure_spec.lua`, `shell_request_spec.lua`, `init_spec.lua`, `completion_spec.lua`, `activate_spec.lua` all exit 0.

---

## All Needed Context

### Context Completeness Check
A reader who knows nothing of this repo can implement S2 from: this PRP + the cited `health.lua` region (the `M.check()` body L70-220, especially the dormant gate pattern L150-160 + the per-probe pcall idiom + the `vim.health` capture-at-top idiom) + `shell.lua`'s state table (L112-125), `get_shell()` (L285), `resolve_shell()` (L168), `pick_driver()` (L234), `mismatch_target()` (L211), and the existing `M.reset()` (L297 — the field list to mirror in `status()`) + `bridge.lua`'s `get_shell_info()` (search L350-360) + `notify.lua`'s `did_notify()` (L36) + `init.lua`'s `config.shell` block (S1, COMPLETE) + `tests/health_spec.lua` (the capturing-stub harness + the `find/has/any_error/any_info_substr/count` helpers) + `tests/health_smoke.lua` (the Level-1 smoke pattern) + PRD §17.4/§17.6/§17.12/§17.15 (quoted inline below). No daemon-internals knowledge beyond "status() is a read-only snapshot of state.shell/proc/failed/parse_failures" is required.

### Documentation & References

```yaml
# MUST READ - Include these in your context window
- url: (in-repo) PRD.md §17.15 "Testing strategy (shell-specific)" — the ":checkhealth pi-bridge shell section" bullet
  why: "The spec for EXACTLY what the section reports: 'resolved shell, source, driver detected, daemon health, last error; live-spawns each available shell driver for a 1-shot smoke.'"
  critical: "The 'live-spawns ... 1-shot smoke' clause is ASPIRATIONAL and OUT OF SCOPE for v1 — it conflicts with the check() sync/never-block invariant (uv.spawn cb fires after check() returns). S2 implements state-only reporting; the live smoke is a documented forward-contract. This is the single most important judgment call in the task — DO NOT spawn from check()."

- url: (in-repo) PRD.md §17.4 "Shell resolution — the prefer contract"
  why: "The source labels health must report: 'pi' | '$SHELL' | 'default' | 'config'. Defines resolve_shell's return contract."

- url: (in-repo) PRD.md §17.6 "Per-shell drivers"
  why: "The tier labels: fish='Tier 1 (clean win)', zsh='Tier 1 (capture-completion)', bash='Tier 2 (best-effort)', unknown='degrade'. Health maps basename→tier."

- url: (in-repo) PRD.md §17.12 "Failure modes & degradation"
  why: "The health-flag semantics: state.failed (permanent disable), parse_failures threshold, EOF-on-pipe → unhealthy. Drives the warn/advice text."

- file: lua/pi-bridge/health.lua
  why: "THE file to edit. The M.check() loader contract (M.check is a table field), the never-throws invariant (pcall every probe), the never-blocks invariant (no live ping), the dormant-is-info invariant, the capture-vim.health-at-top idiom."
  pattern: "Section structure: health.start(name) → dormant gate → per-probe pcall → health.ok/info/warn/error. Mirror EXACTLY for the 5th section."
  gotcha: "vim.health.warn(msg, advice) — advice is the 2nd arg, string|string[]; only the FIRST trailing arg is consumed → multi-line advice as a TABLE warn(msg, {\"a\",\"b\"}). vim.fn.has needs the 'nvim-' prefix for version checks. Read vim.health + require() INSIDE check() (call-time) — the test swaps vim.health in before_each; a module-level cache would freeze the real one."

- file: lua/pi-bridge/shell.lua
  why: "Add M.status() here (one read-only accessor). State table L112-125 has the fields to snapshot. M.reset() L297 lists the exact field set to mirror. M.get_shell() L285 is the precedent for a minimal read seam."
  pattern: "function M.status() return { shell = state.shell, driver_basename = basename(state.shell or ''), proc_alive = state.proc ~= nil, inflight = state.inflight, failed = state.failed, parse_failures = state.parse_failures } end — a plain table-field read, never throws (mirrors get_shell)."
  gotcha: "Do NOT expose the raw state table or the proc/stdin/stdout handles (minimal surface, L283-285). basename() is the module-local helper (L86). status() must be safe to call when state is at its initial literal (proc=nil etc.)."

- file: lua/pi-bridge/notify.lua
  why: "did_notify(category) is the sync surrogate for 'last notice/last error'. The three shell categories are 'shell-mismatch' (WARN), 'shell-degrade' (WARN), 'shell-active' (INFO)."
  pattern: "pcall(require('pi-bridge.notify').did_notify, 'shell-degrade') → bool. Call INSIDE check() (call-time)."

- file: tests/health_spec.lua
  why: "THE test file to append to. The capturing-stub harness (before_each builds a vim.health stub that pushes to `captured`), the find/has/any_error/any_info_substr/any_ok_substr/count helpers, the after_each restore."
  pattern: "Append a new describe('pi-bridge.health shell section (S2)', ...) block; stub shell.status/resolve_shell/pick_driver + notify.did_notify + config.shell on the required modules; assert via the existing helpers."
  gotcha: "Do NOT name a local `pending` (shadows plenary.busted's skip fn — cf. completion_spec.lua header). Restore vim.health + vim.fn.* + vim.env.* in after_each."

- file: tests/health_smoke.lua
  why: "THE Level-1 smoke to append to. Runs M.check() under a real (minimal) nvim, asserts no throw + exit 0."
  pattern: "Append an assertion that check() runs + the shell section start()s (capture via a wrap of vim.health or just assert check() returns without error)."
```

### Current Codebase tree (run `tree` in the root of the project)

```bash
lua/pi-bridge/
├── health.lua          # EDIT — append 5th section to M.check()
├── shell.lua           # EDIT — add M.status() read-only accessor
├── bridge.lua          # read-only (get_shell_info, server_info, is_connected)
├── notify.lua          # read-only (did_notify)
├── init.lua            # read-only (config.shell — S1 COMPLETE)
├── completion.lua      # unchanged
├── shell/{fish,zsh,bash}.lua  # unchanged (drivers; no M.name/M.tier export)
└── ...
tests/
├── health_spec.lua     # EDIT — append shell-section describe block
└── health_smoke.lua    # EDIT — append shell-section smoke assertion
```

### Desired Codebase tree with files to be added and responsibility of file

```bash
lua/pi-bridge/health.lua   # MODIFIED — +1 section in M.check() (shell completion diagnostics)
lua/pi-bridge/shell.lua    # MODIFIED — +M.status() read-only snapshot accessor
tests/health_spec.lua      # MODIFIED — +shell-section describe block (dormant/active/failed/etc.)
tests/health_smoke.lua     # MODIFIED — +shell-section smoke (check() no-throw + section start()s)
# NO new files.
```

### Known Gotchas of our codebase & Library Quirks

```lua
-- CRITICAL: health.lua's M.check() is run by the loader as
-- `require("pi-bridge.health").check()` (runtime/lua/vim/health.lua:152). So `check`
-- MUST be a TABLE FIELD (M.check), never `local function check()` — a local is invisible
-- to the loader and `:checkhealth` errors "report is empty".

-- CRITICAL: the loader pcall-wraps the WHOLE check() call (runtime/health.lua:458).
-- ONE uncaught throw blanks the ENTIRE report. → EVERY probe in the new section is
-- pcall-wrapped (per-probe, NOT a single section-level pcall — matches the existing
-- sections' idiom and surfaces which probe failed in dev).

-- CRITICAL: NEVER spawn a live daemon / issue a live bridge RPC from check(). uv.spawn
-- is async — its cb fires AFTER check() returns → incomplete report or a hang on a dead
-- server. This is the EXACT reason the existing sections never issue a live `ping`
-- (health.lua comment ~L40). PRD §17.15's "live-spawns ... 1-shot smoke" is aspirational
-- and OUT OF SCOPE for v1 — state-only reporting is the in-variant behavior.

-- vim.health.warn(msg, advice): `advice` is the 2nd arg, `string|string[]`. Only the
-- FIRST trailing arg is consumed → multi-line advice as a TABLE:
--   health.warn("daemon failed", { ":messages for the degrade notice", ":help pi-bridge-shell" })
-- NOT health.warn(msg, "a", "b") — that DROPS "b".

-- vim.fn.has("nvim-0.11") needs the "nvim-" prefix (has("0.11") probes a feature named
-- "0.11" → 0). (Already handled in section 1; the shell section doesn't need a version gate.)

-- Read vim.health + require("pi-bridge")/.shell/.notify/.bridge INSIDE check() (call-time),
-- NOT at module level — the unit test swaps vim.health in before_each (notify_spec.lua
-- idiom) and a module-level cache would freeze the real vim.health.

-- shell.lua's state table is NOT public (minimal surface, L283-285). M.status() returns a
-- SNAPSHOT (a fresh table of plain values), never the state table itself or its handles.
-- Mirrors M.get_shell() (a single field read) generalized to the observable subset.

-- Drivers do NOT export M.name/M.tier (verified: fish/zsh/bash expose only start/cd/return M).
-- Derive: driver name = basename(state.shell); tier = hardcoded map {fish,zsh="tier-1",
-- bash="tier-2"}, else "unknown".

-- Dormant (PI_NVIM_BRIDGE unset) is the EXPECTED state outside a pi session → info, NEVER
-- error/warn. The shell section's dormant gate mirrors sections 2-3 exactly.

-- basename() is shell.lua's module-local helper (L86) — M.status() can call it directly
-- (same module). health.lua CANNOT call basename() — it must derive via shell.status()'s
-- driver_basename field OR re-derive via string matching on the resolved path.

-- tests/health_spec.lua: do NOT name a local `pending` (shadows plenary.busted's skip fn).
```

---

## Implementation Blueprint

### Data models and structure

```lua
-- === shell.lua: new M.status() accessor (read-only snapshot) ===
--- Read-only snapshot of the shell-daemon state for `:checkhealth pi-bridge` (§17.15).
--- Returns a FRESH table of plain values — NEVER the raw `state` table or its luv handles
--- (minimal surface, per M.get_shell()'s design L283-285). Pure table-field reads; never
--- throws; safe to call when `state` is at its initial literal (proc=nil etc.). The
--- `:checkhealth` section reads this instead of spawning a live daemon (the never-block
--- invariant — uv.spawn's cb fires after check() returns).
---@return { shell: string?, driver_basename: string, proc_alive: boolean, inflight: boolean, failed: boolean, parse_failures: integer }
function M.status()
  return {
    shell           = state.shell,
    driver_basename = basename(state.shell or ""),  -- "" when unresolved
    proc_alive      = state.proc ~= nil,
    inflight        = state.inflight,
    failed          = state.failed,
    parse_failures  = state.parse_failures,
  }
end

-- === health.lua: the tier map (module-local, above M.check) ===
-- Drivers don't export M.tier (verified). Hardcoded from PRD §17.6 tier labels.
local SHELL_TIER = { fish = "tier-1", zsh = "tier-1", bash = "tier-2" }
```

### Implementation Tasks (ordered by dependencies)

```yaml
Task 1: ADD M.status() to lua/pi-bridge/shell.lua
  - IMPLEMENT: a read-only snapshot accessor returning { shell, driver_basename, proc_alive, inflight, failed, parse_failures }
  - FOLLOW pattern: M.get_shell() at L285 (single field read, never throws, doc cites the §17.15 health consumer)
  - NAMING: M.status (verb-free noun; matches M.reset/M.get_shell table-field style)
  - PLACEMENT: in the "State seam" block right AFTER M.get_shell() (L~290), before M.reset() (L297)
  - GOTCHA: use the module-local basename() helper (L86) for driver_basename; do NOT expose proc/stdin/stdout handles
  - DEPENDENCIES: none (reads only the existing `state` table)
  - TEST: append to tests/shell_spec.lua OR tests/shell_ensure_spec.lua — assert status() returns the 6 fields + mirrors state after a fake ensure/reset

Task 2: ADD the "pi-bridge shell completion" section to lua/pi-bridge/health.lua M.check()
  - IMPLEMENT: a 5th section appended AFTER the existing 4 (lowest priority). Structure: dormant gate → resolved shell+source → driver+tier → daemon health (via M.status) → last notice (via notify.did_notify) → effective config
  - FOLLOW pattern: the existing 4 sections in M.check() (per-probe pcall, capture vim.health at top, read require() call-time, dormant-is-info)
  - NAMING: section name "pi-bridge shell completion"; local tier map SHELL_TIER module-local above M.check
  - PLACEMENT: inside M.check(), AFTER the "external tools (fd)" section block, BEFORE the closing `end` of M.check()
  - GOTCHA: NEVER spawn/ensure/request (never-block); never throw (per-probe pcall); multi-line advice as TABLE; dormant gate returns before daemon probes
  - DEPENDENCIES: Task 1 (M.status); reads shell.resolve_shell/pick_driver (PURE, existing), notify.did_notify (existing), bridge.get_shell_info (existing), config.shell (S1 COMPLETE)
  - TEST: Task 4

Task 3: ADD module-local SHELL_TIER map + section header doc comment to health.lua
  - IMPLEMENT: `local SHELL_TIER = { fish = "tier-1", zsh = "tier-1", bash = "tier-2" }` above M.check(); a doc comment on the new section citing §17.4/§17.6/§17.12/§17.15 + the never-spawn invariant
  - FOLLOW pattern: the existing module-level doc comments (M.min_nvim L~58)
  - NAMING: SHELL_TIER (SCREAMING_SNAKE module constant)
  - PLACEMENT: module-level, near M.min_nvim
  - DEPENDENCIES: none
  - NOTE: this is a sub-step of Task 2; listed separately for the test assertion (tier reporting)

Task 4: APPEND shell-section cases to tests/health_spec.lua
  - IMPLEMENT: a new describe("pi-bridge.health shell section (S2)", ...) block; stub shell.status/resolve_shell/pick_driver + notify.did_notify + config.shell on the required modules; assert via the existing find/has/any_error/any_info_substr/count helpers
  - FOLLOW pattern: the existing describe blocks in health_spec.lua (capturing vim.health stub, before_each/after_each, the helper functions)
  - NAMING: describe "pi-bridge.health shell section (S2)"; it "reports dormant info when PI_NVIM_BRIDGE unset" etc.
  - COVERAGE: dormant (info, no probes); active-not-spawned (info + resolved shell/source/driver/tier, no error); active-proc_alive (ok "daemon ready"); failed (warn + advice TABLE + parse_failures info); did_notify surrogate; config.enabled=false (warn); no-driver (warn); user-disabled driver (warn); never-throws (inject a throwing shell.status → check() still returns, other sections intact); never-spawns (spy shell.ensure NOT called during check())
  - PLACEMENT: append to tests/health_spec.lua (the established home — NO new file)
  - DEPENDENCIES: Task 1, Task 2, Task 3

Task 5: APPEND shell-section smoke to tests/health_smoke.lua
  - IMPLEMENT: run M.check() under a real minimal nvim, assert no throw + exit 0 + the shell section start()s
  - FOLLOW pattern: the existing health_smoke.lua assertions
  - PLACEMENT: append to tests/health_smoke.lua
  - DEPENDENCIES: Task 2
```

### Implementation Patterns & Key Details

```lua
-- === health.lua: the new section (annotated skeleton) ===
-- Inside M.check(), AFTER the "external tools (fd)" section:

-- ===== Section 5: pi-bridge shell completion =====
-- Read-only diagnostics for the §17 shell subsystem. NEVER spawns a live daemon
-- (uv.spawn cb fires after check() returns → incomplete report / hang — the same
-- reason sections 2-3 never issue a live ping). Reports state shell.lua/init.lua/
-- bridge.lua already compute. Dormant (no PI_NVIM_BRIDGE) is the expected state
-- outside a pi session → info, never error/warn.
do
  health.start("pi-bridge shell completion")

  -- Dormant gate (mirrors sections 2-3): if the bridge env var is unset AND no
  -- descriptor was parsed, the shell subsystem is dormant — emit info + skip probes.
  local raw_env = vim.env[env_name]   -- env_name resolved in section 2
  local desc = (pi and pi.descriptor) or nil
  if raw_env == nil and desc == nil then
    health.info("shell completion is dormant (no pi editor session — `!`/`!!` completion only runs inside a pi-launched editor).")
  else
    -- Resolved shell + source (PURE resolve_shell — never mutates state; safe in check()).
    local shell_mod ---@type table|nil
    pcall(function() shell_mod = require("pi-bridge.shell") end)
    local notify_mod ---@type table|nil
    pcall(function() notify_mod = require("pi-bridge.notify") end)
    local cfg = (pi and pi.config and pi.config.shell) or {}
    local prefer = cfg.prefer or "pi"

    local resolved, source
    pcall(function() resolved, source = shell_mod.resolve_shell(prefer) end)
    if resolved then
      health.info(("resolved shell: %s (source: %s, prefer: %s)"):format(
        tostring(resolved), tostring(source), tostring(prefer)))
      -- tier from the basename via the module-local SHELL_TIER map
      local base = tostring(resolved):gsub(".*/", "")
      local tier = SHELL_TIER[base] or "unknown"
      health.info(("driver: %s (%s)"):format(base, tier))
    else
      health.warn("could not resolve a shell (resolve_shell returned nil — check config.shell.prefer).")
    end

    -- Driver picked? (PURE pick_driver — returns nil for unknown/disabled)
    local drv_ok, has_driver = pcall(function()
      return shell_mod.pick_driver(resolved) ~= nil
    end)
    if drv_ok and resolved and not has_driver then
      -- distinguish user-disabled vs unsupported
      local disabled = (cfg.drivers and cfg.drivers[tostring(resolved):gsub(".*/","")] == false)
      if disabled then
        health.warn(("driver for %s is disabled in config (shell.drivers.%s = false) — no completion for this shell."):format(
          tostring(resolved):gsub(".*/",""), tostring(resolved):gsub(".*/","")))
      else
        health.warn(("no driver for %s (unsupported shell — only fish/zsh/bash are supported; degrades to no completion)."):format(
          tostring(resolved):gsub(".*/","")))
      end
    end

    -- Daemon health via M.status() (read-only snapshot; never spawns).
    local st ---@type table?
    pcall(function() st = shell_mod.status() end)
    if type(st) == "table" then
      if st.failed then
        health.warn("daemon failed — shell completion is disabled for `!`/`!!` lines this session.", {
          "Run `:messages` for the degrade notice (category `shell-degrade`).",
          "See `:help pi-bridge-shell` (P2.M3.T6.S4) for resolution / config.",
        })
        if st.parse_failures and st.parse_failures > 0 then
          health.info(("consecutive parse failures: %d (threshold %d)"):format(
            st.parse_failures, cfg.max_parse_failures or 5))
        end
      elseif st.proc_alive then
        health.ok(("daemon ready (%s)"):format(st.driver_basename ~= "" and st.driver_basename or "?"))
      else
        health.info("daemon not spawned yet (lazy — starts on the first `!`/`!!`; or enable shell.warm_on_enter).")
      end
      if st.inflight then
        health.info("a completion request is in flight (daemon busy).")
      end
    end

    -- Last notice (sync surrogate for "last error" — did_notify is a table read).
    for _, cat in ipairs({ "shell-degrade", "shell-mismatch", "shell-active" }) do
      local fired = false
      pcall(function() fired = notify_mod and notify_mod.did_notify(cat) or false end)
      if fired then
        health.info(("a `%s` notice fired earlier this session (run `:messages` to see it)."):format(cat))
      end
    end

    -- Effective config (S1 COMPLETE — config.shell is populated).
    if cfg.enabled == false then
      health.warn("shell completion is disabled in config (shell.enabled = false).")
    else
      health.info(("config: enabled=%s, prefer=%s, warm_on_enter=%s"):format(
        tostring(cfg.enabled ~= false), tostring(prefer), tostring(cfg.warm_on_enter)))
    end

    -- Cross-check the descriptor's advertised shell vs the resolved one (advisory).
    local advertised
    pcall(function()
      local br = require("pi-bridge.bridge")
      if type(br.get_shell_info) == "function" then
        local si = br.get_shell_info()
        advertised = (si and si.shell) or (desc and desc.shell) or nil
      end
    end)
    if advertised and resolved and advertised ~= resolved then
      health.info(("note: descriptor advertises shell %q but resolve_shell picked %q (prefer=%s)."):format(
        tostring(advertised), tostring(resolved), tostring(prefer)))
    end
  end
end
```

### Integration Points

```yaml
HEALTH LOADER:
  - add to: lua/pi-bridge/health.lua M.check() (a 5th health.start block)
  - pattern: "health.start('pi-bridge shell completion') → per-probe pcall → health.ok/info/warn/error"
  - preserve: the existing 4 sections + the M.check table-field loader contract + never-throws

SHELL.LUA SURFACE:
  - add to: lua/pi-bridge/shell.lua (M.status accessor in the State-seam block)
  - pattern: "function M.status() return { ... } end — plain table-field reads, mirrors M.get_shell"
  - preserve: M.get_shell/M.reset/M.ensure/M.request/M.teardown semantics + the minimal-surface design (do NOT expose raw state)

TESTS:
  - add to: tests/health_spec.lua (append describe block) + tests/health_smoke.lua (append assertion)
  - pattern: "capturing vim.health stub + find/has helpers (existing) + stub shell.status/resolve_shell/pick_driver/notify.did_notify"
  - preserve: existing health_spec cases (dormant/active/malformed/fd) stay green

NO INTEGRATION POINTS IN: bridge.lua, notify.lua, init.lua, completion.lua, the drivers,
  menu.lua, ftplugin/pi-prompt.lua (S3 owns teardown), plugin/pi-bridge.lua. S2 is read-only
  w.r.t. all of them.
```

---

## Validation Loop

### Level 1: Syntax & Style (Immediate Feedback)

```bash
# Lua lint + format (the repo's CI gates — selene + stylua)
selene lua/pi-bridge/health.lua lua/pi-bridge/shell.lua
stylua --check lua/pi-bridge/health.lua lua/pi-bridge/shell.lua

# Expected: zero errors. If selene flags an unknown global (vim/vim.uv), ensure the
# existing selene.yml std is intact (the existing health.lua passes — mirror its style).
```

### Level 2: Unit Tests (Component Validation)

```bash
# The plenary spec (the established home — append, do NOT create a new file):
timeout 90 nvim --headless --clean -u tests/minimal_init.lua \
  -c 'lua require("plenary.busted").run("tests/health_spec.lua")'
echo "exit=$?"

# The shell.status() accessor tests (append to shell_spec.lua OR shell_ensure_spec.lua):
timeout 90 nvim --headless --clean -u tests/minimal_init.lua \
  -c 'lua require("plenary.busted").run("tests/shell_spec.lua")'
echo "exit=$?"

# Regression — the full affected suite:
for s in health shell shell_ensure shell_request shell_routing completion init activate; do
  timeout 90 nvim --headless --clean -u tests/minimal_init.lua \
    -c "lua require('plenary.busted').run('tests/${s}_spec.lua')" || echo "FAIL: $s"
done

# Expected: all exit 0. If health_spec fails, debug the captured stub calls (print `captured`).
```

### Level 3: Integration Testing (System Validation)

```bash
# Plenary-free smoke (the Level-1 gate; file-based, AGENTS.md-compliant — NO stdin heredoc):
timeout 60 nvim --headless --clean -u NORC +"luafile tests/health_smoke.lua" +qa
echo "exit=$?"

# Manual: render the real report under a minimal nvim (set a fake PI_NVIM_BRIDGE to
# exercise the active path). Write the lua to a FILE — never pipe a heredoc into nvim stdin:
cat > /tmp/pi_health_check.lua <<'LUA'   -- heredoc to a FILE is fine; to nvim stdin is NOT (AGENTS.md HARD RULE)
vim.env.PI_NVIM_BRIDGE = vim.json.encode({
  transport = "unix", path = "/tmp/fake.sock", token = "abc", pid = 12345,
  cwd = "/tmp", fdAvailable = true, serverVersion = "0.1.0",
  shell = "/bin/zsh", shellSource = "$SHELL",
})
vim.cmd("set rtp+=.")
require("pi-bridge").setup({})
local captured = {}
local orig = vim.health
vim.health = setmetatable({}, {__index = function(_,k) return function(msg, advice)
  captured[#captured+1] = {k=k, msg=msg, advice=advice} end end})
require("pi-bridge.health").check()
vim.health = orig
local found = false
for _, c in ipairs(captured) do
  if c.k == "start" and tostring(c.msg):find("shell completion", 1, true) then found = true end
end
print(found and "OK: shell section rendered" or "FAIL: shell section missing")
vim.cmd("qa!")
LUA
timeout 60 nvim --headless --clean -u NORC -c 'set rtp+=.' +"luafile /tmp/pi_health_check.lua"
echo "exit=$?"
# Expected: "OK: shell section rendered", exit 0.

# NEVER run (the AGENTS.md HARD RULE trap — for reference only, DO NOT EXECUTE):
#   nvim ... +"luafile /dev/stdin" +qa <<'LUA' ... LUA   # ❌ HANGS FOREVER
```

### Level 4: Creative & Domain-Specific Validation

```bash
# Real-world diagnosis simulation: simulate a FAILED daemon + assert the warn renders.
cat > /tmp/pi_health_failed.lua <<'LUA'
vim.env.PI_NVIM_BRIDGE = vim.json.encode({ transport="unix", path="/tmp/x.sock", token="t",
  pid=1, cwd="/tmp", fdAvailable=true, serverVersion="0.1.0", shell="/bin/dash" })
vim.cmd("set rtp+=.")
require("pi-bridge").setup({})
-- inject a failed daemon state via shell.reset + a direct state write is NOT possible
-- (state is module-local). Instead, stub shell.status to return failed=true:
package.loaded["pi-bridge.shell"] = package.loaded["pi-bridge.shell"] or require("pi-bridge.shell")
local sh = package.loaded["pi-bridge.shell"]
sh.status = function() return { shell="/bin/dash", driver_basename="dash", proc_alive=false,
  inflight=false, failed=true, parse_failures=7 } end
sh.resolve_shell = function(_) return "/bin/dash", "default" end
sh.pick_driver = function(_) return nil end  -- dash unsupported
local captured = {}
local orig = vim.health
vim.health = setmetatable({}, {__index = function(_,k) return function(msg, advice)
  captured[#captured+1] = {k=k, msg=msg, advice=advice} end end})
require("pi-bridge.health").check()
vim.health = orig
local saw_warn, saw_no_driver = false, false
for _, c in ipairs(captured) do
  if c.k == "warn" and tostring(c.msg):find("daemon failed", 1, true) then saw_warn = true end
  if c.k == "warn" and tostring(c.msg):find("no driver", 1, true) then saw_no_driver = true end
end
print((saw_warn and saw_no_driver) and "OK: failed+no-driver diagnosed" or "FAIL")
vim.cmd("qa!")
LUA
timeout 60 nvim --headless --clean -u NORC -c 'set rtp+=.' +"luafile /tmp/pi_health_failed.lua"
echo "exit=$?"
# Expected: "OK: failed+no-driver diagnosed", exit 0.

# Never-throws invariant: inject a throwing shell.status → check() still completes.
cat > /tmp/pi_health_throw.lua <<'LUA'
vim.env.PI_NVIM_BRIDGE = vim.json.encode({ transport="unix", path="/tmp/x.sock", token="t",
  pid=1, cwd="/tmp", fdAvailable=true, serverVersion="0.1.0" })
vim.cmd("set rtp+=.")
require("pi-bridge").setup({})
package.loaded["pi-bridge.shell"] = package.loaded["pi-bridge.shell"] or require("pi-bridge.shell")
local sh = package.loaded["pi-bridge.shell"]
sh.status = function() error("boom") end   -- a buggy/throwing accessor
sh.resolve_shell = function(_) error("boom") end
local ok = pcall(function() require("pi-bridge.health").check() end)
print(ok and "OK: check() did not throw" or "FAIL: check() threw")
vim.cmd("qa!")
LUA
timeout 60 nvim --headless --clean -u NORC -c 'set rtp+=.' +"luafile /tmp/pi_health_throw.lua"
echo "exit=$?"
# Expected: "OK: check() did not throw", exit 0 (per-probe pcall swallowed the throw).
```

---

## Final Validation Checklist

### Technical Validation
- [ ] Level 1 (selene + stylua) clean on `health.lua` + `shell.lua`.
- [ ] Level 2: `tests/health_spec.lua` exit 0 (incl. the new shell-section describe block).
- [ ] Level 2: `tests/shell_spec.lua` (or `shell_ensure_spec.lua`) exit 0 (incl. the new `M.status()` cases).
- [ ] Level 2 regression: `shell_request_spec.lua`, `shell_routing_spec.lua`, `completion_spec.lua`, `init_spec.lua`, `activate_spec.lua` all exit 0.
- [ ] Level 3: `tests/health_smoke.lua` exit 0; the `/tmp/pi_health_check.lua` integration prints "OK".
- [ ] Level 4: `/tmp/pi_health_failed.lua` prints "OK"; `/tmp/pi_health_throw.lua` prints "OK" (never-throws).

### Feature Validation
- [ ] `:checkhealth pi-bridge` renders a 5th section "pi-bridge shell completion" in dormant + active sessions.
- [ ] Dormant → `info "shell completion is dormant ..."`, no `error`/`warn`, no daemon probes run.
- [ ] Active + not spawned → `info` (resolved shell/source/driver/tier) + `info "not spawned yet (lazy)"`, no error.
- [ ] Active + `proc_alive` → `ok "daemon ready (<basename>)"`.
- [ ] Active + `failed` → `warn "daemon failed ..."` with a TABLE advice + `info` (parse_failures if >0).
- [ ] `notify.did_notify("shell-degrade")` → `info` mentioning the notice.
- [ ] `config.shell.enabled == false` → `warn "disabled in config"`.
- [ ] No-driver (`/bin/dash`) → `warn "no driver"`.
- [ ] User-disabled driver → `warn "disabled in config (shell.drivers.X = false)"`.
- [ ] `shell.status()` returns the 6-field snapshot; never throws; does not expose raw `state` or handles.
- [ ] `M.check()` never throws (per-probe pcall) and never spawns (`shell.ensure` NOT called during `check()`).

### Code Quality Validation
- [ ] Follows the existing `health.lua` section pattern (per-probe pcall, capture `vim.health` at top, call-time `require()`).
- [ ] `M.status()` follows the `M.get_shell()` minimal-surface pattern (single read seam, never throws).
- [ ] File placement: `health.lua` edit (1 section) + `shell.lua` edit (1 accessor) + 2 test appends — NO new files.
- [ ] Anti-patterns avoided: no module-level `vim.health` cache; no live spawn/RPC in `check()`; no raw-`state` exposure; no `local pending` in tests.
- [ ] Doc comments cite PRD §17.4/§17.6/§17.12/§17.15 + the never-spawn-from-health invariant.

### Documentation & Deployment
- [ ] `health.lua` section doc comment explains what it reports + why it never spawns.
- [ ] `shell.lua` `M.status()` doc comment cites §17.15 + the minimal-surface rationale.
- [ ] No new user-facing command or config key (the section is auto-rendered by `:checkhealth pi-bridge`).
- [ ] The live-driver-smoke forward-contract (PRD §17.15 aspirational clause) is documented in the PRP + the section's doc comment, NOT implemented (out of scope for v1 — conflicts with the never-block invariant).

---

## Anti-Patterns to Avoid

- ❌ **Don't spawn a live daemon from `check()`.** uv.spawn is async; its cb fires after `check()` returns → incomplete report or a hang on a dead server. PRD §17.15's "live-spawns ... 1-shot smoke" is aspirational; state-only reporting is the in-variant behavior. (Same reason the existing sections never issue a live `ping`.)
- ❌ **Don't expose the raw `state` table or the `proc`/`stdin`/`stdout` handles.** `M.status()` returns a SNAPSHOT of plain values (minimal surface, per `M.get_shell()`'s design).
- ❌ **Don't skip the per-probe `pcall`.** The loader pcall at runtime/health.lua:458 blanks the WHOLE report on one uncaught throw. Mirror the existing sections exactly.
- ❌ **Don't cache `vim.health` at module level.** The test swaps it in `before_each`; a module-level cache freezes the real one and defeats the stub.
- ❌ **Don't treat dormant as an error/warn.** Missing `PI_NVIM_BRIDGE` is the EXPECTED state outside a pi session → `info`.
- ❌ **Don't pass multi-line advice as varargs.** `health.warn(msg, "a", "b")` DROPS `"b"`. Use a TABLE: `health.warn(msg, {"a","b"})`.
- ❌ **Don't create new test files.** Append to `tests/health_spec.lua` + `tests/health_smoke.lua` (the established homes).
- ❌ **Don't edit `completion.lua`, `bridge.lua`, `notify.lua`, `init.lua`, the drivers, `menu.lua`, `ftplugin/pi-prompt.lua`, or `plugin/pi-bridge.lua`.** S2 is `health.lua` + one `shell.lua` accessor + tests ONLY. (S3 owns the ftplugin teardown wiring; S4 owns `doc/pi-bridge-shell.txt`.)
- ❌ **Don't pipe a heredoc into `nvim` stdin** (the AGENTS.md HARD RULE — it hangs the session). Write lua to a FILE, run with `+"luafile <path>"`.
- ❌ **Don't reference a command that doesn't exist.** The section does NOT mention `:PiBridgeShellSmoke` (it isn't implemented); the live-smoke is a documented forward-contract only.

---

**Confidence Score: 9/10** — One-pass success is highly likely. The task is a pure-additive, read-only diagnostic section following an established in-repo pattern (the existing 4 `health.lua` sections) with a fully-specified test harness (`tests/health_spec.lua`'s capturing stub) and a single trivial accessor (`M.status()` mirroring `M.get_shell()`). The one judgment call (state-only reporting vs PRD §17.15's aspirational live-smoke) is resolved explicitly and defensibly in the PRP. The residual 1/10 risk is selene/stylua style nits on the new code, caught by Level 1.