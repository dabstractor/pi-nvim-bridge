# Research Notes — P2.M3.T6.S2: `health.lua` shell section

## Task scope
Add a 5th section to `:checkhealth pi-bridge` reporting the §17 shell-completion
subsystem state. Per PRD §17.15: "reports resolved shell, source, driver
detected, daemon health, last error; live-spawns each available shell's driver
for a 1-shot smoke." Parent P2.M3.T6; sibling to S1 (config, COMPLETE), S3
(ftplugin teardown, Planned), S4 (docs, Planned).

## Existing `health.lua` (lua/pi-bridge/health.lua) — the established pattern
- `M.check()` is a **table field** (loader runs `require("pi-bridge.health").check()`,
  health.lua:152 loader contract). NOT a local function.
- **NEVER throws** — every probe is `pcall`-wrapped (loader pcall at :458 blanks
  the whole report on one throw). This invariant MUST hold for the shell section.
- Reads `vim.health` ONCE at top of `check()` (the stub-friendly capture; tests
  swap `vim.health` in `before_each`). Do NOT cache at module level.
- 4 existing sections via `vim.health.start(name)`: "pi-bridge" (version),
  "pi-bridge bridge (environment)", "pi-bridge bridge (connection)",
  "pi-bridge external tools (fd)".
- New API: `vim.health.start/ok/info/warn/error` (`report_*` removed by 0.12).
  `warn(msg, advice)` — `advice` is 2nd arg `string|string[]`; only first trailing
  arg consumed → multi-line advice as a TABLE.
- **DORMANT ≠ ERROR**: missing `PI_NVIM_BRIDGE` is the EXPECTED state outside a
  pi session → `info "dormant"`, never error/warn. Sections gate on env var / live
  descriptor. The shell section MUST follow the same gate (no shell state when
  dormant → info, not warn).

## `shell.lua` state + exports — what health can READ (read-only consumer)
Health must be a PURE read-only consumer (mirrors health.lua's design: "Pure
READ-ONLY consumer of state init.lua + bridge.lua already compute. Modifies
nothing"). Available read seams:
- `require("pi-bridge.shell").get_shell()` → `state.shell` (string path | nil).
  THIS is the only public field-read; `state` table itself is NOT exposed (minimal
  surface — shell.lua comment L283-285).
- `require("pi-bridge.shell").resolve_shell(prefer)` → `(path, source)` PURE
  function (no state mutation). Can be called to show the *would-be* resolution.
- `require("pi-bridge.shell").pick_driver(resolved)` → driver module | nil (PURE).
- `require("pi-bridge.shell").mismatch_target(resolved, env_shell)` → richer
  basename | nil (PURE; deterministic, vim.fn-free).

**GAP / decision:** `state.failed`, `state.parse_failures`, `state.driver`,
`state.proc`, `state.inflight` are NOT exposed. The PRP must add a minimal
read-only accessor (e.g. `M.status()` returning a snapshot table) OR health reads
only `get_shell()`. Decision: add `M.status()` (read-only snapshot) — it is the
cleanest seam and matches "read-only consumer of state shell.lua already
computes". Health MUST NOT spawn / kill / drive the daemon from `check()` (the
health.lua comment explicitly says "never issue a live ping RPC — async, risks a
hang on a dead server"; same applies to a live daemon smoke from sync `check()`).

**CRITICAL RE-READ of PRD §17.15:** "live-spawns each available shell's driver
for a 1-shot smoke." This is IN tension with the health.lua "never issue a live
ping" invariant. **Resolution:** the 1-shot driver smoke is OPTIONAL / aspirational
(§17.15 is a "would be nice"). The SAFE, in-variant behavior is to report the
daemon's CURRENT state (resolved shell, source, driver module name, health flags)
WITHOUT spawning. A live spawn from a sync `check()` risks a hang (uv.spawn is
async; the cb fires later; `check()` returns before it → incomplete report). The
PRP specifies: report state-only; the live-spawn smoke is a documented
forward-contract / future enhancement (consistent with §17.17's posture). This
avoids the hang trap that killed the §2.x stdin-nvim sessions (AGENTS.md HARD
RULE spirit — never block `check()`).

## Driver modules — what `state.driver` IS
`M.pick_driver` returns `require("pi-bridge.shell.<basename>")` (fish/zsh/bash).
Each driver exports `M.start(opts, on_ready)` + `M.cd(path)` + `return M`.
**Drivers do NOT export `M.name` / `M.tier`** (verified: fish.lua/zsh.lua/bash.lua
only expose start/cd). So health derives:
- **driver name** = `basename(state.shell)` (e.g. "zsh") via `get_shell()`.
- **tier** = hardcoded map `{fish="tier-1", zsh="tier-1", bash="tier-2"}`,
  fallback "tier-? (unknown)" — matches PRD §17.6 tier labels ("Tier 1 (clean
  win)", "Tier 2 (best-effort)").

## `notify.lua` categories health can observe (did_notify)
shell.lua emits (all `notify.once`, dedup'd once/session):
- `"shell-mismatch"` (WARN) — §17.4.3 prefer:"pi" bash-vs-zsh/fish notice.
- `"shell-degrade"` (WARN) — §17.12 spawn failure / unknown shell / disabled driver.
- `"shell-active"` (INFO) — §17.9 first-`!` hint (successful daemon start).

`require("pi-bridge.notify").did_notify(category)` → bool. Health can surface
"last notice fired: shell-degrade" as a diagnostic ("last error" surrogate —
the actual last-error string isn't stored; the category + level conveys it).

## `bridge.lua` read seams (already used by health sections 2-4)
- `bridge.server_info` (table | nil) — set by handshake result; has
  `.shell`/`.shellSource`/`.shellPath`/`.cwd`/`.fdAvailable`/`.serverVersion`
  (P2.M1.T1.S4 wired the shell fields in).
- `bridge.is_connected()` → bool.
- `bridge.get_shell_info()` → merges server_info→descriptor (shell.lua uses it).
`pi.descriptor` (set by activate()) also carries `.shell`/`.shellSource`/`.shellPath`.

## `init.lua` config (S1, COMPLETE)
`require("pi-bridge").config.shell` is now a fully-populated block (enabled,
prefer, drivers, warm_on_enter, timeout_ms, startup_timeout_ms, visual_cue,
debounce_ms, max_parse_failures). Health reads it to report the EFFECTIVE config
(prefer value, which drivers are enabled). Consumers read defensively; health
should too (`(config and config.shell) or {}`).

## Test pattern — tests/health_spec.lua (the established home)
- Plenary/busted; stubs all 5 `vim.health.*` to a capturing table in `before_each`
  (notify_spec.lua idiom); asserts via helpers `find/has/any_error/any_info_substr/
  any_ok_substr/count`.
- Stubs `vim.fn.executable` / `vim.fn.has` / `vim.env.PI_NVIM_BRIDGE` + the module
  state on `require("pi-bridge")` / `.bridge`.
- `after_each` restores originals.
- New shell cases APPEND to this file (no new file) — mirror the existing
  dormant/active/malformed/fd describe blocks with shell-context cases.
- Plenary-free smoke: `tests/health_smoke.lua` (the Level-1 gate) — add a shell
  assertion that the section `start`s + doesn't throw.

## FTplugin teardown (S3, Planned — NOT this task)
S3 will wire `shell.teardown()` into VimLeavePre/ExitPre. It is OUT OF SCOPE for
S2. Health only READS state; it does not depend on teardown wiring.

## Run commands (AGENTS.md compliant — file-based, no stdin heredoc)
- Plenary spec: `timeout 90 nvim --headless --clean -u tests/minimal_init.lua
  -c 'lua require("plenary.busted").run("tests/health_spec.lua")'`
- Smoke: `timeout 60 nvim --headless --clean -u NORC +"luafile tests/health_smoke.lua" +qa`

## Gotchas
- `vim.fn.has("nvim-0.11")` needs the `nvim-` prefix (health.lua:65 comment).
- NEVER spawn a live daemon from `check()` (async uv cb fires after check returns
  → hang risk / incomplete report). State-only.
- The new section must gate on dormant (no `PI_NVIM_BRIDGE`) → `info`, not error.
- `vim.health.warn(msg, advice)` — multi-line advice as a TABLE.