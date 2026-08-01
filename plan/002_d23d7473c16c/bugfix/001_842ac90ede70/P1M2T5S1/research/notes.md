# Research Notes — P1.M2.T5.S1 (Wire daemon cwd re-tracking, Issue 4)

## The gap (Issue 4, PRD §17.5.2)

`M.session_cwd()` (shell.lua) is read **exactly once** — at spawn time, as `opts.cwd` in
`M.ensure` (shell.lua:461), then cached into `state.cwd` (shell.lua:486). There is **NO
caller** of `state.driver.cd(path)` anywhere:

```
grep -rn '\.cd(' lua/ ftplugin/ plugin/   →  only the three driver DEFINITIONS
```

So the three drivers' `M.cd` + the `__PICD__\t<path>\n` frame their daemon scripts
recognize are **dead code**. PRD §17.5.2 advertises cwd re-tracking; it does not happen.

## Driver cd capability (verified by reading each daemon script)

| Driver | `M.cd(path)` writes | Daemon honors `__PICD__`? | Effective |
|--------|--------------------|---------------------------|-----------|
| fish.lua  | `__PICD__\t<path>\n` to `last_stdin` | YES — `__pi_handle` does `builtin cd "$p"` (silent, no response) | **REAL cd** |
| bash.lua  | `__PICD__\t<path>\n` to `last_stdin` | YES — `__pi_handle` does `builtin cd "$p"` (silent) | **REAL cd** |
| zsh.lua   | `__PICD__\t<path>\n` to `last_stdin` | NO — OUTER case `(__PICD*) ;;` is a no-op; INNER Enter bound to noop widget | **advisory no-op (v1)** |

Doc-comment accuracy today:
- fish: "cd is advisory" = best-effort/silent semantics (NOT a no-op); daemon honors it. ✓ mostly accurate.
- bash: explicitly "REAL". ✓ accurate.
- zsh: explicitly "ADVISORY / documented no-op for v1"; **BUT also claims "a mid-session cwd change re-spawns"** — that is FALSE (the daemon is persistent for the session; nothing re-spawns). Needs correction.

## Where to wire the re-cd (decided: `complete_current`)

`complete_current(buf, cb)` (shell.lua, the §17.7 buffer→daemon adapter) is the SOLE
production caller of `M.request`. It runs on the nvim **main loop** per keystroke
(called by completion.lua `do_shell_fetch`, which is driven by `do_refresh`/`on_tab`).
Putting the re-cd here keeps `M.request` a pure framing layer (it just frames + writes) and
puts "buffer→daemon translation, including cwd sync" in one place — matching the task title
("Wire cwd re-tracking in complete_current").

Insert point: AFTER the empty-command guard (step 6, the bare `!`/`!   ` short-circuit) and
BEFORE the `M.request` delegation (step 7). Rationale:
- A bare `!` must NOT spawn or cd the daemon (empty-cmd guard must stay first).
- If the daemon is NOT yet spawned (`state.proc == nil`), `M.request`→`M.ensure` spawns it
  with the CURRENT `session_cwd()` as `opts.cwd` → `state.cwd` is fresh → no re-cd needed.
- So the re-cd only fires when `state.proc` is set AND `session_cwd()` changed since spawn.

## Write-ordering guarantee (the crux — verified)

`state.driver.cd(cur)` writes `__PICD__\t<path>\n` to the driver-cached `last_stdin`.
`M.request` then writes `__PIREQ__\t{json}\n` to `state.stdin`.

**`last_stdin` and `state.stdin` are the SAME `uv_pipe_t`** — the driver hands `stdin` to
shell.lua via `on_ready(nil, proc, stdin, stdout)`, shell.lua stores it as `state.stdin`
(shell.lua:485), and the driver ALSO caches `last_stdin = stdin` on readiness.

libuv/libuv guarantees `uv_write_t` requests on a single `uv_stream_t` are queued and
written in **FIFO submission order**. Both writes are submitted synchronously within one
`complete_current` call (cd write → M.request write), so the daemon's `while read` loop
sees `__PICD__` FIRST (builtin cd) then `__PIREQ__` (completion in the new cwd) → the
CURRENT request's completions track the new cwd (not the next one).

## Edge cases to handle / test

1. daemon already spawned + cwd changed → `cd(new)` called; `__PICD__` queued before `__PIREQ__`.
2. cwd UNCHANGED since spawn → no cd call; only `__PIREQ__` written.
3. daemon NOT spawned → no cd call (ensure spawns with session_cwd); cd-calls empty.
4. `session_cwd()` returns nil → skip, no error, no cd.
5. driver has no `cd` (custom/buggy) → `type(...)=="function"` guard → skip, no throw.
6. never-throws: `pcall(state.driver.cd, cur_cwd)`.
7. post-crash: `_reset` nils `state.proc` (does NOT touch `state.cwd`); the `state.proc`
   guard means re-cd won't fire; on re-spawn `state.cwd = opts.cwd` (fresh session_cwd) →
   no stale-cwd bug.

## Test seam

`state.cwd` is module-local. Existing seams: `_test_gen`, `_test_inflight`,
`_test_pending_is_nil`, `_test_get_pending`, `_test_invoke_pending`. Add `_test_cwd()` to
read `state.cwd` (assert spawn seeds it; assert re-cd updates it) — consistent pattern.

The fake driver injection (`package.loaded["pi-bridge.shell.fish"] = drv`) makes
`state.driver == drv`, so a spying `drv.cd` is observable. To also assert FIFO ordering,
give the fake `cd` a body that writes `__PICD__\t<path>\n` to the fake stdin (mirrors the
real driver) → `stdin.written[1]` = `__PICD__…`, `stdin.written[2]` = `__PIREQ__…`.

## Validation

- Plenary: `timeout 90 nvim --headless --clean -u tests/minimal_init.lua -c 'lua require("plenary.busted").run("tests/shell_complete_current_spec.lua")'`
- Smoke (plenary-free): `timeout 60 nvim --headless --clean -u NORC +"luafile tests/shell_complete_current_smoke.lua" +qa`
- Regression sweep: also run `shell_ensure_spec` (it sets state.cwd) + `shell_smoke`,
  `shell_fish_driver_smoke`/`shell_bash_driver_smoke`/`shell_zsh_driver_smoke` (cd unit).
- No luacheck/stylua/selene config in repo (`.stylua.toml`/`.luacheckrc` absent) → nvim
  headless plenary + smoke ARE the Level-1/2 gates.
- ⛔ AGENTS.md: write any lua test to a FILE (`tests/*` or `/tmp`) + run via `+"luafile <path>"
  +qa`. NEVER pipe a heredoc into nvim stdin (hangs).