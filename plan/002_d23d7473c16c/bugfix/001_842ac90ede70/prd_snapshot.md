# Bug Fix Requirements

## Overview

**Scope tested:** End-to-end validation of the `pi-nvim-bridge` extension (TypeScript)
and `pi-bridge.nvim` plugin (Lua) against the original PRD, with emphasis on the newest,
most complex feature — **§17 shell completion for `!`/`!!` bash-mode lines** (Phase P2).
The core bridge (slash commands, `@file`, path completion, §8 UTF-16 coordinate contract,
handshake, autosave) was validated by code review + the existing 84-test suite.

**Method:** Ran the full existing test suite (all green: 66 Lua specs/smokes + 18
`node:test` TS suites), then went *beyond* it by driving the **real** production code
paths the unit tests stub out: real `fish`/`zsh`/`bash` daemons through the real
`shell.lua` (`ensure`→`request`→`_feed`), real-buffer `complete_current` + `accept.apply`
round-trips (including `!` and `!!`, quoted/space-containing candidates, directory
re-trigger), the `:checkhealth` shell section, the descriptor field flow, and targeted
adversarial repros for supersession, notice-scoping, and cwd-tracking edge cases.

**Quality assessment:** The implementation is exceptionally well-engineered and
well-tested — every standard test passes and the live shell drivers work end-to-end.
The issues below are **genuine gaps the standard validation missed**, not regressions.
None are Critical (core functionality works), but two are Major (correctness/UX
deviations from the PRD scope or the headline guarantee) and several are Minor polish.

**Reproduction environment:** Neovim 0.12.4, Node 26.4.0, fish 4.x, zsh 5.9, bash 5.3,
Linux. All repros are deterministic and were run multiple times.

---

## Critical Issues (Must Fix)

None. All core user journeys work: `/cmd` + `@file` + path completion via the bridge,
`!`/`!!` shell completion via fish/zsh/bash daemons, accept/quote, autosave-on-exit,
dormant-unless-`PI_NVIM_BRIDGE`, and graceful degradation throughout.

---

## Major Issues (Should Fix)

### Issue 1: `prefer = "bash"` (and `prefer = "/path/to/bash"`) wrongly fires the §17.4.3 "switch to your native shell" mismatch notice

**Severity**: Major
**PRD Reference**: §17.4.3 (the notice is scoped to *"`prefer:"pi"` resolves a shell poorer than `$SHELL`"*); contradicted by the user docs at `doc/pi-bridge-shell.txt:111-114` ("the daemon is spawned and `prefer` (the default `"pi"`) resolves to bash...").
**Component**: `lua/pi-bridge/shell.lua` — `M.mismatch_target()` + the notice block in `M.ensure()`.

**Expected Behavior**: The one-time "pi runs commands in bash; ... For your native zsh completions, set pi's `shellPath`..." notice should fire **only under `prefer = "pi"`** (the default), per PRD §17.4.3 and the help docs. A user who **explicitly** sets `prefer = "bash"` (or `prefer = "/bin/bash"`) has deliberately chosen bash completion; telling them to "set `shellPath` to `/usr/bin/zsh`" is misleading, and the advice is **inert** under `prefer = "bash"` (that setting forces bash regardless of `shellPath`).

**Actual Behavior**: `M.mismatch_target(resolved, env_shell)` checks only `basename(resolved) == "bash"` + `$SHELL` is zsh/fish — it has **no `prefer` check**. `ensure()` calls it unconditionally. So the notice fires whenever the *resolved* shell is bash and `$SHELL` is a richer shell, **regardless of how bash was chosen** (pi-default via `prefer:"pi"`, OR explicit `prefer:"bash"`, OR explicit `prefer:"/abs/path/to/bash"`).

**Steps to Reproduce** (deterministic; confirmed live):
1. `require("pi-bridge").setup({ shell = { prefer = "bash" } })` — explicit bash.
2. `descriptor.shell = "/bin/bash"`, `$SHELL = /usr/bin/zsh` (zsh on `PATH`).
3. `require("pi-bridge.shell").ensure(function() end)` (with a fake bash driver injected).
4. Observe the WARN notice: `"pi-bridge: pi runs commands in bash; using bash completion to match. For your native zsh completions, set pi's shellPath to /usr/bin/zsh (then completion and execution both use it)..."`.

(Repro script: `/tmp/e2e_bash_notice.lua`; the same notice was also observed during a real-driver run in `/tmp/e2e_bash_git.lua`.)

**Suggested Fix**: Gate the notice on `prefer == "pi"` in `ensure()` (the §17.4.3 scope). `M.mismatch_target` can stay pure (no `prefer` arg), but its sole caller in `ensure()` should only invoke it when `cfg.prefer == "pi"` (or `cfg.prefer` is nil/`"pi"`). The existing `shell_notices_spec.lua` does not cover the explicit-`prefer:"bash"` case, which is why this slipped through — add a case asserting no `shell-mismatch` notice under `prefer = "bash"`.

---

### Issue 2: The headline `prefer = "pi"` guarantee ("completions and execution always agree") is **not** honored in the most common configuration, and the §17.4.3 safety-net notice is dead code by default

**Severity**: Major (correctness/UX; stems from PRD §17.10.2's acknowledged limitation, faithfully implemented — surfaced for human review because it defeats the headline feature).
**PRD Reference**: §17.2 ("the central design constraint"), §17.4 (`prefer:"pi"` = "Always consistent (same shell executes)"), §17.4.3 (the mismatch notice), §17.10.2 (the honesty note).
**Components**: `extension/pi-nvim-bridge.ts` `resolveShell()` + `lua/pi-bridge/shell.lua` `resolve_shell()`.

**Expected Behavior**: PRD §17.2/§17.4 frame `prefer:"pi"` as the *correctness-preserving* default: completions should use the **same shell pi executes `!`/`!!` commands in**, so a completion never suggests a command that fails at execution (the zsh-alias `g=git` → `g: command not found` under bash footgun). PRD §17.4.3's mismatch notice exists specifically to warn when this consistency cannot be achieved and to point the user at the one-setting fix.

**Actual Behavior**: The extension **cannot read pi's resolved execution shell** (`settingsManager`/`getShellConfig` are not on `ExtensionContext` — PRD §17.10.2), so `resolveShell()` falls back to `process.env.SHELL`. For the overwhelmingly common case — a user whose `$SHELL = /bin/zsh` (or fish) who has **not** set pi's `shellPath`:

- pi still **executes `!`/`!!` in `/bin/bash`** (pi's `getShellConfig()` default, per PRD §17.2);
- but the descriptor advertises `shell = /bin/zsh` (from `$SHELL`), so `resolve_shell("pi")` returns **zsh**;
- the plugin completes with the **zsh** engine, which is **inconsistent** with bash execution — exactly the footgun `prefer:"pi"` was designed to prevent.
- The §17.4.3 mismatch notice (the documented safety net) **never fires** in this default case, because its condition is `resolved == bash && $SHELL ∈ {zsh,fish}` — but here `resolved` is already zsh, so `M.mismatch_target()` returns nil. The notice is only reachable in the narrow, near-contradictory config where a zsh user manually sets `PI_NVIM_SHELL=/bin/bash`.

Net effect for a default zsh/fish user: the plugin silently delivers *inconsistent* completions (the opposite of the §17.4 "always consistent" claim), with no notice to alert or guide them. The richness-recovery path (set `shellPath`/`PI_NVIM_SHELL`) is never surfaced.

**Steps to Reproduce / Reasoning** (logic trace, no live pi process needed):
1. Default config (`prefer = "pi"`), `$SHELL = /bin/zsh`, no `PI_NVIM_SHELL`, no pi `shellPath`.
2. Extension `resolveShell()` → `{ shell: "/bin/zsh", shellSource: "$SHELL" }` (the `$SHELL` branch).
3. Descriptor `shell = "/bin/zsh"`.
4. Plugin `resolve_shell("pi")` → `descriptor_shell()` → `/bin/zsh` → source `"pi"`.
5. Driver = zsh (tier-1). `M.mismatch_target("/bin/zsh", "/bin/zsh")` → basename `zsh` ≠ `bash` → **nil** → no notice.
6. User types `!g <Tab>`; zsh offers `g` (a `.zshrc` alias). User accepts → pi runs `!g …` in **bash** → `g: command not found`.

**Suggested Fix**: This is fundamentally constrained by PRD §17.10.2 (no public API to read pi's shell). Pragmatic mitigations, in increasing order of effort:
- **Detect & warn on the real footgun**: since the default execution shell is bash, fire the mismatch notice whenever `prefer == "pi"` **and** `$SHELL` is zsh/fish **and** `shellSource == "$SHELL"` (i.e. the descriptor fell back to `$SHELL` rather than a real pi setting) — this is the case where consistency is actually at risk. (Today this signal is discarded.)
- **Document the default explicitly** in `doc/pi-bridge-shell.txt` (the `prefer` section currently implies consistency holds by default; it does not for non-bash `$SHELL`).
- **Upstream** (PRD §15/§17.17): a tiny `ctx.getShellConfig()` so the descriptor can advertise pi's *actual* execution shell, making `prefer:"pi"` correct by default. The implementation should be updated to consume it once available.

---

## Minor Issues (Nice to Fix)

### Issue 3: Supersession race — deleting the leading `!` while a shell request is in flight lets the stale response re-open the shell menu

**Severity**: Minor
**PRD Reference**: §5.5 (timing & cancellation / supersession); the codebase's own "TOUCH NOTHING on a stale fetch" invariant (documented in `completion.lua` header: "ERROR/CANCELLED/TIMEOUT → TOUCH NOTHING").
**Component**: `lua/pi-bridge/completion.lua` `do_refresh()` (the `ctx == nil` branch) + `do_shell_fetch()`.

**Expected Behavior**: When the user edits the buffer so that the completion context changes (e.g. deletes the `!`, turning a shell line into plain prose), any in-flight shell-completion response that arrives afterwards must be **dropped** (superseded), so a stale shell menu never appears for a line that no longer starts with `!`.

**Actual Behavior**: `do_shell_fetch()` bumps `state.gen` and captures it in its callback (correct supersession vs. a *newer shell/slash/path* fetch). But the `ctx == nil` (plain-typing) branch of `do_refresh()` calls `M.on_results(buf, {}, "", nil)` to close the menu **without bumping `state.gen`**. So if a shell request is still in flight when the user deletes the `!`, the late shell response passes the `if gen ~= state.gen then return end` guard (gen unchanged) and **re-opens the shell menu** for a buffer that no longer starts with `!`. (Accepting the stale item then mis-routes to the bridge path, since `M.accept` re-checks `lines[1]:sub(1,1) == "!"`.)

**Steps to Reproduce** (deterministic; confirmed live via `/tmp/e2e_race.lua`):
1. Buffer `"!git c"`, cursor after `c`; `completion.refresh(buf)` → `ctx == "shell"` → `do_shell_fetch` (gen=1, shell request in flight, cb deferred).
2. Set buffer to `"git c"` (deleted `!`); `completion.refresh(buf)` → `ctx == nil` → menu closes via `on_results({}, "", nil)` (gen **not** bumped).
3. Fire the deferred shell response `cb(nil, { {value="checkout",...} }, "c")`.
4. Result: `menu.on_results` is invoked with `context == "shell"` and the checkout item → **menu re-opens** despite the buffer being plain `"git c"`.

**Suggested Fix**: Bump `state.gen` (and optionally cancel the in-flight shell request) on the `ctx == nil` close path in `do_refresh`, mirroring the slash/path/supersession discipline. Narrow impact (self-corrects on the next keystroke; requires a slow daemon + the specific delete-`!`-while-in-flight sequence), but it is a real supersession gap.

---

### Issue 4: Daemon cwd re-tracking is documented (PRD §17.5.2) and shipped (all three drivers define `M.cd`) but is **never wired** — dead code

**Severity**: Minor
**PRD Reference**: §17.5.2 ("if [the session cwd] changed since spawn, the driver re-`cd`s the daemon (each driver exposes a `cd(path)` over the framed channel) so path/relative completions match pi's working directory").
**Components**: `lua/pi-bridge/shell/fish.lua`, `shell/zsh.lua`, `shell/bash.lua` (all define `function M.cd(path)`); `lua/pi-bridge/shell.lua` `M.session_cwd()`.

**Expected Behavior**: Per §17.5.2, if pi's session cwd changes after the daemon spawned, the manager re-`cd`s the daemon so relative/path completions track the new cwd.

**Actual Behavior**: `M.session_cwd()` is read **exactly once** — at spawn time (`opts.cwd` in `M.ensure`, `shell.lua:419`). There is **no caller** of `driver.cd(path)` anywhere in the plugin (`grep -rn '\.cd(' lua/ ftplugin/ plugin/` returns only the driver definitions). The three drivers' `cd` methods (and the `__PICD__\t<path>` frame their scripts recognize) are dead code. Low practical impact for v1 (a pi editor session is single-shot and the cwd is fixed at spawn), but the feature is advertised in the PRD and the health check implies liveness.

**Suggested Fix**: Either (a) implement the re-cd (re-read `session_cwd()` on each `complete_current`/`request`; if changed since spawn, call `state.driver.cd(new)` before the next request), or (b) mark `M.cd`/`__PICD__` explicitly as unimplemented-for-v1 in the driver doc-comments and the PRD so readers don't assume it works. The zsh driver header already hedges ("`cd(path)` is ADVISORY (a documented no-op for v1)"); fish/bash do not and present `cd` as functional.

---

### Issue 5: `:checkhealth pi-bridge` shell section reports an inaccurate "source" label

**Severity**: Minor (cosmetic / misleading diagnostics)
**PRD Reference**: §17.10.1 (`shellSource`: `"pi" | "$SHELL" | "default"`).
**Component**: `lua/pi-bridge/shell.lua` `M.resolve_shell()` (returns the second value `source`) as consumed by `lua/pi-bridge/health.lua`.

**Expected Behavior**: The health report's "resolved shell: X (source: Y, prefer: Z)" should convey how the shell was **derived** — matching the extension's `descriptor.shellSource` (`"pi"` = from the `shellPath`/`PI_NVIM_SHELL` setting; `"$SHELL"` = fell back to `$SHELL`; `"default"` = `/bin/bash`).

**Actual Behavior**: `resolve_shell("pi")` returns the literal `"pi"` whenever `descriptor.shell` is present (the first hop of the `prefer:"pi"` chain), **regardless of what `descriptor.shellSource` actually says**. So a descriptor carrying `shell = "/bin/zsh", shellSource = "$SHELL"` (the extension derived it from `$SHELL`) is reported by health as `source: pi`. A user inspecting `:checkhealth` to debug Issue 2 would be misled into thinking the shell came from a pi setting when it actually came from `$SHELL`.

**Steps to Reproduce** (confirmed live via `/tmp/e2e_health.lua`): set `descriptor = { shell="/bin/zsh", shellSource="$SHELL" }`; run `health.check()`; observe `"resolved shell: /bin/zsh (source: pi, prefer: pi)"`.

**Suggested Fix**: Have `resolve_shell` return the descriptor's `shellSource` (when present) instead of the hard-coded hop label `"pi"`, or have `health.lua` read `bridge.get_shell_info().shellSource` directly for the report.

---

### Issue 6: Command lines containing a literal `"` produce an all-commands flood instead of a graceful "no results"

**Severity**: Minor (documented limitation; poor UX, no graceful empty result)
**PRD Reference**: §17.6.x driver sketches; the fish/zsh driver headers explicitly document this as a "KNOWN LIMITATION" (crude `"line":"([^"]*)"` regex extraction).
**Components**: `lua/pi-bridge/shell/fish.lua`, `shell/zsh.lua`, `shell/bash.lua` (`.line` extraction).

**Expected Behavior**: A shell command containing a literal double-quote (e.g. `!echo "feat` or `!git commit -m "wip`) should either complete sensibly or degrade to an **empty** result.

**Actual Behavior**: The crude `.line` extraction (`"line":"([^"]*)"` in fish/zsh; parameter-substitution `${payload#*\"line\":\"}` in bash) resolves the command to **empty** when the line contains a `"`. The daemon then runs `complete -C ""` (fish/zsh) or `compgen -abck` (bash), which returns **every** command on the system (observed: 158 items for zsh, ~all commands), flooding the floating menu.

**Steps to Reproduce** (confirmed live via `/tmp/e2e_edge.lua`): `shell.request('git "feature', 11, "", cb)` → `nitems = 158` (zsh) instead of `0` or a small relevant set.

**Suggested Fix**: Have the drivers emit an **empty** items array when the extracted `cmd` is empty after stripping the prefix (treat empty-cmd as "no completion"), rather than passing `""` to `complete -C`/`compgen`. Low effort; converts a confusing flood into a clean no-results.

---

## Testing Summary

- **Total tests performed**: 84 existing (66 Lua specs/smokes + 18 TS suites, all PASS) + ~15 original end-to-end/adversarial probes written for this hunt (real-driver `ensure`→`request`→`_feed`; real-buffer `complete_current`+`accept.apply` for `!`/`!!`, quoted/space/directory candidates; `:checkhealth`; descriptor flow; notice-scoping; supersession race; cwd-tracking audit).
- **Passing**: 84/84 standard; all live happy-path E2E probes (fish/zsh/bash daemon round-trips, accept cursor math, quoting, `!!` handling, autosave review) PASS.
- **Failing**: 0 standard tests. 6 issues found by going beyond the standard suite (2 Major, 4 Minor), each with a deterministic repro.
- **Areas with good coverage**: the slash/`@file`/path bridge path; §8 UTF-16 coordinate conversion; JSONL framing (U+2028/U+2029, multi-byte split); handshake/token gate; autosave-on-exit; shell daemon spawn/teardown handle hygiene; fish/zsh/bash live completion + accept/quote; `!!` bang-strip; dormant-unless-`PI_NVIM_BRIDGE`; omp host compat (dual-detection mode gate, type-only imports, manifest key).
- **Areas needing more attention**:
  - **Notice scoping** (`prefer:"bash"` fires the `prefer:"pi"`-scoped mismatch notice — Issue 1) — the `shell_notices_spec` lacks an explicit-`prefer:"bash"` case.
  - **The `prefer:"pi"` consistency guarantee in the default `$SHELL`-fallback case** (Issue 2) — no test asserts the guarantee holds (or warns when it can't) for a non-bash `$SHELL` user.
  - **Cross-context supersession** (shell↔nil — Issue 3) — supersession is tested within shell and within slash/path, but the *shell→plain-typing* transition is not.
  - **cwd re-tracking** (Issue 4) — `M.cd` has no caller and no test.
  - **Health "source" fidelity** (Issue 5) — no test asserts the reported source matches `descriptor.shellSource`.
  - **Quoted-command degrade** (Issue 6) — no test asserts an empty/quote-containing `.line` yields an empty (not flooded) result.
