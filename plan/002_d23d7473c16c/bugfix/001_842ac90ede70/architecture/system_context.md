# System Context — Shell Completion Bug Fixes

## Project

`pi-nvim-bridge` — a Neovim plugin (Lua) + TypeScript extension that bridges Neovim
to the `pi` coding agent. This patch addresses 6 bugs found during E2E validation of
the §17 shell-completion feature (`!`/`!!` bash-mode lines): 2 Major, 4 Minor.

## Architecture Overview

The shell-completion stack has three layers:

```
extension/pi-nvim-bridge.ts  (TypeScript)
  └─ resolveShell() → ShellInfo{shell, shellSource, shellPath}
     └─ flows into BridgeDescriptor (env var) + HelloResult + PingResult (RPC)
        └─ descriptor.shell / descriptor.shellSource consumed by plugin ↓

lua/pi-bridge/shell.lua  (Lua — the daemon MANAGER)
  ├─ M.resolve_shell(prefer)   → (shell_path, source)     [§17.4 fallback chain]
  ├─ M.mismatch_target(...)    → richer_basename | nil     [§17.4.3 PURE condition]
  ├─ M.ensure(on_ready)        → spawn-if-needed + notice  [§17.5 lifecycle entry]
  ├─ M.complete_current(buf,cb)→ delegate to M.request     [§17.7 per-keystroke entry]
  ├─ M.session_cwd()           → cwd string | nil          [§17.5.2 cwd tracking]
  └─ M.request(line,cursor,after,cb) → framed protocol     [§17.5.2 gen-guard supersession]

lua/pi-bridge/shell/{fish,zsh,bash}.lua  (Lua — per-shell DRIVERS)
  ├─ M.start(opts, cb)   → spawn the daemon subshell
  ├─ M.cd(path)          → write __PICD__ frame (cwd re-tracking)  ⚠ DEAD CODE
  └─ DAEMON_SCRIPT / OUTER_SCRIPT  (embedded shell-string literals)
     └─ .line extraction → complete -C / compgen / zpty

lua/pi-bridge/completion.lua  (Lua — the completion ORCHESTRATOR)
  ├─ do_refresh(buf)     → classify context (shell/slash/path/nil) → dispatch
  ├─ do_shell_fetch(buf) → bump gen + shell.complete_current + gen-guarded cb
  └─ state.gen           → monotonic supersession counter (shared shell↔bridge)
```

## Issue → Code Location Map

| Issue | Severity | File(s) | Function(s) | Key Lines |
|-------|----------|---------|-------------|-----------|
| 1 | Major | `shell.lua` | `M.ensure()` notice block | 384–396 |
| 2 | Major | `shell.lua` + `pi-nvim-bridge.ts` | `M.ensure()` + `resolveShell()` | 382–396; ts:451–457 |
| 3 | Minor | `completion.lua` | `do_refresh()` ctx==nil branch | 543–548 |
| 4 | Minor | `shell.lua` + 3 drivers | `M.complete_current()` + `M.cd()` | 984–1047; fish:428, zsh:497, bash:477 |
| 5 | Minor | `shell.lua` + `health.lua` | `M.resolve_shell()` + `descriptor_shell()` | 168–189, 135–156; health:251–264 |
| 6 | Minor | 3 drivers | DAEMON_SCRIPT `.line` extraction | fish:118–130, zsh:192–196, bash:193–201 |

## Dependency Graph (fixes)

```
T1 (Issue 5: expose real shellSource) ──────────────┐
  │ resolve_shell returns descriptor.shellSource     │
  │                                                  ▼
  │                              T3 (Issue 2: detect $SHELL footgun)
  │                              needs source=="$SHELL" signal from T1
  │
T2 (Issue 2: gate notice on prefer=="pi")  ← independent of T1
T4 (Issue 3: supersession race)            ← independent (completion.lua)
T5 (Issue 4: wire cwd re-tracking)         ← independent (shell.lua + drivers)
T6 (Issue 6: quote-flood degrade)          ← independent (drivers only)
T7 (sync docs)                             ← depends on ALL above
```

## Key Architectural Invariants (must preserve)

1. **FRESH reads**: config + descriptor + bridge are read INSIDE each function
   (`require("pi-bridge")` lazy), NEVER cached at module load. The handshake is ASYNC
   and tests swap in fakes after require. (shell.lua header; completion.lua header.)

2. **`mismatch_target` is PURE**: no nvim, no vim.fn, no state, no notify. The PATH
   check (`vim.fn.executable`) lives at the CALL SITE (ensure). Do NOT add prefer/state
   logic inside this helper — gate at the caller.

3. **Gen-guard supersession**: `state.gen` is monotonic; every cb closure captures it.
   A newer request bumps gen → late stale cb hits `if gen ~= state.gen then return end`
   and is dropped. Every context-transition that could invalidate an in-flight result
   MUST bump gen. (The ctx==nil branch currently doesn't — Issue 3.)

4. **`resolve_shell` is shared**: called by both `ensure()` AND `health.lua`.
   Return-value changes must be compatible with both consumers.

5. **Driver scripts are STRING LITERALS**: the DAEMON_SCRIPT/OUTER_SCRIPT in each
   driver .lua file is an embedded shell script (fish/zsh/bash syntax). Editing them
   requires care with quoting/escaping inside the Lua string.

6. **descriptor_shell() is module-local**: only called by `resolve_shell` within
   shell.lua. Changing its return signature (1→2 values) is safe — no external callers.

## Reproduction Environment

Neovim 0.12.4, Node 26.4.0, fish 4.x, zsh 5.9, bash 5.3, Linux.
All repros deterministic. Test suite: 84 tests (66 Lua + 18 TS), all green.