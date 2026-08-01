# Research Notes — P2.M2.T3.S4 (Shell-completion notices)

Scope: the THREE user-facing `vim.notify` notices for `!`/`!!` Bash-mode completion
(per PRD §17.4.3, §17.9, §17.12). No new UI, no daemon logic — purely wiring the
existing `notify.lua` dedup'd-one-shot emitter into `shell.lua`'s lifecycle at the
points where each notice's *fact* becomes known.

## The three notices

| # | PRD | Category | Level | Fires when | Fact source |
|---|-----|----------|-------|------------|-------------|
| 1 | §17.4.3 | `"shell-mismatch"` | WARN | `prefer:"pi"` resolved **bash** AND `$SHELL` is **zsh/fish** AND that shell is on PATH | `state.shell` (set in `ensure` step 4) + `vim.env.SHELL` + `vim.fn.executable` |
| 2 | §17.9   | `"shell-active"`   | INFO | first successful daemon spawn (first real `!` command) | `ensure` step 8b (spawn-success cb) |
| 3 | §17.12  | `"shell-degrade"`  | WARN | daemon permanently failed (no-driver / spawn-err / EOF / parse-threshold) | `ensure` steps 5/8a/8c + `_reset` + `_feed` |

## Why emit from `shell.lua` (not `completion.lua`)

- `shell.lua`'s `ensure()` is THE single lifecycle entry (resolve → pick → spawn) and
  owns every fact each notice needs: `state.shell` (resolved), `state.driver`,
  `state.failed`. The failure paths (`_reset` EOF, `_feed` parse-threshold) also live
  here.
- `notify.lua`'s `once()` is **fast-context-safe** (it `vim.schedule`s the notify
  internally + pcalls `vim.notify`), so it can be called from the libuv driver cb in
  `ensure` step 8b WITHOUT an extra `vim.schedule` (verified: notify.lua L23-27).
- The completion.lua forward-contract note ("silent degrade (S4 notifies)",
  do_shell_fetch cb L433) is satisfied transitively: `do_shell_fetch` →
  `complete_current` → `M.request` → `M.ensure` → the notify fires there. completion.lua
  stays a thin router (no edit).
- Cohesion: all shell-notice logic in ONE module matches the repo's
  "one-responsibility-per-module" style (cf. jsonlreader.lua, notify.lua).
- A bare `!` (empty command) does NOT reach `ensure` (`complete_current`
  short-circuits it → `cb(nil, {}, "")`) so NO notice fires on a bare bang — correct
  UX ("no completion until a word exists", §17 edge case). The first-run hint fires on
  the first real `!<word>` that spawns the daemon.

## notify.lua surface (verified, L1-39)

```lua
M.once(category, level, msg)   -- dedup by category; vim.schedule's the notify; pcall'd; never throws
M.reset()                       -- clear the dedup set (tests + future re-arm)
M.did_notify(category)          -- bool, for test assertions
```
- Default category `"bridge"`; default level WARN. `once` schedules internally → safe
  from luv fast context (the handshake cb + the driver spawn cb).
- The `seen` dedup set is the once-per-session mechanism. Different categories
  (`shell-mismatch` / `shell-active` / `shell-degrade`) dedup independently.

## Self-gating of the mismatch condition

`mismatch_target(resolved, env_shell)` checks: resolved basename == `"bash"` (tier-2)
AND env_shell basename ∈ `{"zsh","fish"}` (tier-1). This is **self-gating**:
- `prefer:"pi"` + descriptor.shell=bash + `$SHELL`=/bin/zsh → TRUE (the footgun case).
- `prefer:"shell"` → resolved == `$SHELL` → can't be poorer than itself → FALSE.
- `prefer:"pi"` + descriptor omits shell → resolve falls through to `$SHELL` →
  resolved == `$SHELL` → FALSE.
So NO explicit `prefer` check is needed in the condition.

The PATH check (`vim.fn.executable(richer) == 1`) is kept at the CALL SITE (ensure
step 4), NOT inside the pure helper — so `mismatch_target` is 100% deterministic /
purely unit-testable (no vim.fn dependency). health.lua L181 already uses the
`vim.fn.executable`/`exepath` pair — same idiom.

## Exact emission points in shell.lua `ensure()` (VERIFIED against current source)

```
ensure(on_ready):
  (1) if state.failed then return on_ready("daemon disabled") end   [no notify — degrade already fired when failed was set]
  (2) if state.proc  then return on_ready(nil) end                   [cache hit — notices already fired on first spawn]
  (3) cfg = (pi.config and pi.config.shell) or {}
  (4) resolved = M.resolve_shell(cfg.prefer or "pi"); state.shell = resolved
      >>> INSERT mismatch check HERE (pure helper + vim.fn.executable + notify.once) <<<
  (5) state.driver = M.pick_driver(resolved)
      if not state.driver then
        state.failed = true
        >>> INSERT degrade notify HERE <<<                          [unknown shell §17.6.4]
        return on_ready("no driver for " .. tostring(resolved))
      end
  (6) opts = {...}
  (7) pcall(state.driver.start, opts, function(err, proc, stdin, stdout)
        (8a) if err then state.driver=nil; state.failed=true
               >>> INSERT degrade notify HERE <<<                    [spawn err §17.12]
               return on_ready(err) end
        (8b) state.proc/stdin/stdout = ...; state.cwd = opts.cwd; read_start(...)
             >>> INSERT first-run hint notify HERE <<<               [success §17.9]
             on_ready(nil)
      end)
      (8c) if not ok then state.driver=nil; state.failed=true
             >>> INSERT degrade notify HERE <<<                      [driver.start threw]
             on_ready(tostring(spawn_err)) end
```

`_reset()` (EOF path, shell.lua ~L560): after `state.failed = true` → INSERT degrade
notify (shell crashed mid-session; notify.once dedups with any earlier degrade).
`_feed()` parse-threshold (~L478): after the `state.failed = true` re-assert → INSERT
degrade notify (same category — dedup).

**Why steps 4/5/8 run ONCE per session:** `ensure` is called per-request via
`request`/`complete_current`, but the SECOND+ call hits the `state.proc` cache at
step (2) and returns immediately → steps 3-8 execute ONLY on the first spawn. So the
mismatch + first-run/degrade (spawn-path) logic naturally fires once (plus
notify.once is belt-and-suspenders). `_reset`/`_feed` degrade are the mid-session
cases; notify.once dedups them with the initial degrade if any.

## Message strings (match PRD wording)

- mismatch (WARN): `"pi-bridge: pi runs commands in bash; using bash completion to match. For your native <RICHER> completions, set pi's shellPath to <SHELL> (then completion and execution both use it). :help pi-bridge-shell"` (RICHER = basename like "zsh"; SHELL = full `$SHELL` path).
- first-run (INFO): `"pi-bridge: shell completion active (<BASE>); :help pi-bridge-shell"` (BASE = basename of state.shell).
- degrade (WARN): `"pi-bridge: shell completion unavailable for <BASE>; :help pi-bridge-shell"` (BASE = basename of state.shell; single canonical msg — notify.once dedups so only the first failure's context is shown).

## Ordering / suppression invariants

- FIRST `!` with a **healthy** spawn → mismatch (if holds) + first-run hint. Degrade
  does NOT fire (step 8a not reached).
- FIRST `!` with a **failed** spawn (no-driver / spawn-err) → mismatch (if holds) +
  degrade. First-run hint does NOT fire (step 8b not reached). [matches §17.9
  "Suppressed if the daemon failed (the degrade notice fires instead)"]
- MID-SESSION crash (EOF in `_reset`, parse-threshold in `_feed`) → degrade (once;
  dedup). First-run hint already fired earlier → not repeated.
- All three are independent categories → all can co-exist (max 3 toasts/session).

## Test harness (verified against existing shell_*_spec.lua)

- `tests/shell_ensure_spec.lua` already provides `fake_bridge(shell_path)` +
  `make_fake_driver()` + `inject_fake_driver`-equivalent (package.loaded injection) +
  before_each/after_each save-restore of `vim.env.SHELL`/`pi.bridge`/`pi.descriptor`/
  `pi.config.shell` + `package.loaded["pi-bridge.shell.fish"]=nil` + `shell.reset()`.
- For notices: ALSO `notify.reset()` in before_each (clears the dedup set) +
  `vim.wait(N, ...)` to flush `notify.once`'s `vim.schedule`, then assert
  `notify.did_notify("shell-mismatch" / "shell-active" / "shell-degrade")`.
- `mismatch_target` PURE unit cases (no nvim, no daemon): pass resolved+env_shell
  directly; deterministic.
- PATH check: stub `vim.fn.executable` (`local orig=vim.fn.executable; vim.fn.executable=function() return 1 end`) for the mismatch TRUE case; restore in after_each.
- Degrade from a failing spawn: `make_fake_driver({ _fail = true })` (the existing
  `_fail` opt → `cb("spawn err: simulated", ...)`).

## Config state (VERIFIED)

`config.shell` is NOT yet in `M.defaults` (init.lua L31-39) — it is P2.M3.T6.S1
(Planned). All shell.lua reads use the defensive `(pi.config and pi.config.shell) or
{} `. The notices do NOT need a new config key (dedup is via notify.lua categories, not
config) — so this task does NOT depend on P2.M3.T6.S1 and must read config the same
defensive way.

## No-change confirmations

- notify.lua: unchanged (its `once`/`did_notify`/`reset` already cover this).
- completion.lua: unchanged (do_shell_fetch stays a thin router; the degrade notify
  fires inside shell.lua's ensure, which do_shell_fetch triggers transitively).
- bridge.lua / extension/*: unchanged.
- No new config key, no new module, no new public API beyond `M.mismatch_target`
  (pure testable helper, internal-ish — exported for unit tests like
  `completion.M.is_attachment_context`).