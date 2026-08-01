---
name: "P2.M3.T5.S1 — zsh.lua shell-completion driver: capture-completion via zsh/zpty pty + start(opts,on_ready) + cd(path)"
why_this_prp: "The Tier-1 zsh driver for §17 shell completion. Unlike fish (plain pipes), zsh completion is driven by ZLE widgets that require a TTY, so the driver spawns an OUTER zsh that manages an INNER completion zsh inside a `zsh/zpty` pseudo-terminal — the proven Valodim/zsh-capture-completion model. Every non-obvious detail below comes from that canonical source (fetched + quoted in research/) and is LIVE-verifiable against zsh 5.9.2 on this machine. It must satisfy the exact `start(opts,on_ready)` contract the already-landed shell.lua (P2.M1.T2) assumes and that fish.lua (P2.M2.T4.S1, Complete) established as the template."
---

## Goal

**Feature Goal**: Implement `lua/pi-bridge/shell/zsh.lua` — the Tier-1 zsh
shell-completion driver (PRD §17.6.2) — exposing `start(opts, on_ready)` (spawn a
persistent OUTER `zsh` daemon that internally manages an INNER completion zsh inside a
`zsh/zpty` pseudo-terminal, loads compsys via a dedicated compdump, installs a `compadd`
override that captures word+description pairs, and translates each framed request into a
`complete-word` drive of the inner zsh → ONE valid JSON object between sentinels) and
`cd(path)` (best-effort, advisory for zsh v1). It is loaded by `shell.lua`'s
`M.pick_driver` (`require("pi-bridge.shell.zsh")`) and driven by the existing
`M.ensure`/`M.request`/`M._feed` pipeline (already Complete).

**Deliverable**: One new Lua module `lua/pi-bridge/shell/zsh.lua` (~180-260 lines)
exporting `M.start(opts, on_ready)` and `M.cd(path)`, plus three test files: a spike
`tests/shell_zsh_spike.lua` (plenary-free, LIVE-gated on `zsh` — the mandatory gate before
writing the driver), `tests/shell_zsh_driver_smoke.lua` (plenary-free, LIVE), and
`tests/shell_zsh_driver_spec.lua` (plenary, live + offline contract cases). No changes to
`shell.lua`, `completion.lua`, or any extension file — the seams are already in place.

**Success Definition**:
1. `require("pi-bridge.shell.zsh").start` is a function and `.cd` is a function (the
   contract `shell.lua`'s `pick_driver` validates: `type(drv.start)=="function"`).
2. The SPIKE (`tests/shell_zsh_spike.lua`) passes: a standalone outer+inner pty round-trip
   yields `checkout`/`cherry` for `git ch`. This is the gate for writing `zsh.lua`.
3. `start({shell="/usr/bin/zsh",cwd=<tmp>,startup_timeout_ms=5000}, cb)` spawns a persistent
   outer zsh process and calls `cb(nil, proc, stdin, stdout)` with live luv handles; the
   daemon stays alive across ≥3 sequential framed requests (persistence — the spike + the
   one-shot Valodim both did ONE request).
4. A framed request `__PIREQ__\t{"line":"git ch","cursor":6,"after":""}\n` yields a response
   `__PIRESP_START__\n{"items":[...],"prefix":""}\n__PIRESP_END__\n` whose decoded `items`
   include `checkout`/`cherry` (zsh compsys `_git` definitions ship with every system zsh,
   so this works even with `-f` / no user rc).
5. `state.failed` semantics: on spawn error / binary missing / startup-timeout / missing
   `zsh/zpty`, `start` calls `cb(err, nil, nil, nil)` (never throws, never leaves handles
   open — the existing §17.12 degrade path then disables the daemon).
6. The three test files pass (smoke exit 0; spec green; spike PASS). All LIVE cases
   `SPIKE_SKIP`/`pending` (exit 0) when `zsh` is not on PATH (PRD §17.15: never fail CI for
   a missing optional shell).

## User Persona (if applicable)

**Target User**: a pi user whose pi-resolved execution shell (or `$SHELL`) is zsh, and who
types `!`/`!!` shell commands into the pi-prompt Neovim buffer (PRD §17). Indirect user: the
`pi-bridge.nvim` plugin itself, which calls this driver through `shell.lua`.

**Use Case**: typing `!git ch<Tab>` in the pi-prompt buffer → the menu shows zsh's
`checkout`/`cherry`/`cherry-pick` WITH descriptions (zsh compsys is far richer than bash's
`compgen`), identical to typing `git ch<Tab>` at a real zsh prompt.

**Pain Points Addressed**: with only the fish driver landed (P2.M2.T4), a zsh-resolved user
gets NO completion (`pick_driver` returns nil for zsh → `ensure` sets `state.failed` → the
§17.12 degrade notice). zsh is the most common interactive shell, so this closes the largest
remaining gap. PRD §17.6.2 calls zsh Tier-1 ("capture-completion", descriptions available).

## Why

- **Closes the shell-completion gap for the most common Tier-1 shell.** zsh's compsys
  (`_git`, `_docker`, … + descriptions via `_describe`/`compadd -d`) is materially richer
  than bash's bare-word `compgen` (Tier-2). Without this driver, the majority of users on
  the `prefer:"pi"` default with `shellPath=zsh` get nothing.
- **Completes the driver matrix.** fish (P2.M2.T4.S1, Complete) + zsh (this) + bash
  (P2.M3.T5.S2, Planned) + unknown-degrade (P2.M3.T5.S3, Planned) cover every §17.4.2 path.
  zsh is the hardest; getting it right makes bash mechanical and validates the architecture
  against the most fragile case.
- **Consumes already-landed infrastructure.** `shell.lua` (`ensure`/`request`/`_feed`/
  `teardown`/`pick_driver`/`close_handles`), `completion.lua` (`do_shell_fetch`→
  `complete_current`), the bridge descriptor `shell` field (P2.M1.T1), and the
  `shell/accept.lua` quoting table (P2.M2.T4.S3 — zsh uses the POSIX single-quote path) are
  all Complete. S1 is the leaf that turns zsh completion on. It changes ZERO existing files.

## What

A Lua module `lua/pi-bridge/shell/zsh.lua` that:

1. On `start(opts, on_ready)`: writes the OUTER zsh daemon script (and the INNER init
   script, OR has the outer write the inner to a temp — see Task 2) to temp file(s), creates
   three `uv.new_pipe(false)` handles (stdin/stdout/stderr), spawns `zsh -f <outer_tmp>
   <inner_tmp>` (the OUTER is a non-interactive zsh script that does `zmodload zsh/zpty` +
   a `while read` loop; `-f` skips zshenv/zshrc — the outer needs no zle) with
   `stdio={stdin,stdout,stderr}` and `cwd=opts.cwd`, arms a `startup_timeout_ms` cold-start
   timer, reads **stderr** for an `__PIREADY__\n` marker (emitted by the OUTER after the
   INNER signals compinit-done), and on readiness calls `on_ready(nil, proc, stdin, stdout)`.
   On any failure it kills the proc + closes all three pipes + removes temp file(s) + calls
   `on_ready(err, nil, nil, nil)`.
2. On `cd(path)`: writes `__PICD__\t<path>\n` to the daemon's stdin. For zsh v1 this is
   **advisory/best-effort** (documented known limitation vs fish's clean cd): the INNER
   zsh's Enter is bound to `undefined` (never execute — Valodim's safety), so a true inner
   `cd` needs a dedicated control-char widget; v1 bakes the spawn cwd into the inner and
   treats `cd` as a documented no-op. See `cd` gotcha + research §7.
3. The zsh DAEMON SCRIPT (embedded as Lua long-string(s), written to temp file(s)): the
   OUTER does `zmodload zsh/zpty`, `zpty z zsh -f -i`, sources the INNER init, waits for the
   inner readiness signal, emits `__PIREADY__` to stderr, then loops on stdin: each
   `__PIREQ__\t{json}` → clear the inner's line (`^U`) → type the command + Tab
   (`zpty -w z $'\025'"$cmd"$'\t'`) → read the inner pty output between NUL delimiters →
   build ONE single-object JSON (`__pi_json_str` manual escape, mirroring fish.lua) → emit
   it between `__PIRESP_START__`/`__PIRESP_END__`. The INNER init mirrors Valodim's
   `capture.zsh` sourced block: `autoload compinit; compinit -d <dedicated dump>`, zstyles
   (`list-grouped false`, `insert-tab false`, `list-separator ''`), keybindings (`^I`→
   `complete-word`, `^M`/`^J`→`undefined`), the NUL `compprefuncs`/`comppostfuncs`, and the
   `compadd` override (`builtin compadd -A __hits -D __dscr` + echo word+desc).

### Success Criteria

- [ ] `tests/shell_zsh_spike.lua` exits 0 with `SPIKE_PASS` (or `SPIKE_SKIP` if no zsh) —
      the outer+inner pty round-trip yields `checkout`/`cherry` for `git ch`. **GATE: do
      not write `zsh.lua` until this passes.**
- [ ] `lua/pi-bridge/shell/zsh.lua` exists, `require("pi-bridge.shell.zsh")` loads without
      error, and `M.start`/`M.cd` are functions.
- [ ] `M.start` calls `on_ready(nil, proc, stdin, stdout)` with live handles within
      `startup_timeout_ms` (5s); the daemon survives ≥3 sequential framed requests.
- [ ] End-to-end: feeding `__PIREQ__\t{"line":"git ch","cursor":6,"after":""}\n` to the
      spawned daemon's stdin produces `checkout`/`cherry` in the decoded `items` (LIVE zsh,
      gated on `vim.fn.executable("zsh")`).
- [ ] Spawn error / binary-missing / startup-timeout / missing `zsh/zpty` →
      `on_ready(err, nil,nil,nil)`, no leaked handles, never throws.
- [ ] `tests/shell_zsh_driver_smoke.lua` exits 0; `tests/shell_zsh_driver_spec.lua` green.

## All Needed Context

### Context Completeness Check

_Pass_: an implementer who knows nothing about this codebase gets (a) the exact
`start(opts,on_ready)`/`cd(path)` contract with arg arity + return shape, (b) the COMPLETE
canonical Valodim `capture.zsh` source (quoted in `research/zsh_driver_findings.md` §2/§3 —
the `compadd` override + zstyles + pty-driving), (c) the architectural reason zsh needs a
PTY and the outer-zsh-wrapper that fits the existing driver contract, (d) the stderr-ready-
signal + single-object-JSON constraints (inherited from fish.lua / shell.lua `_feed`), (e)
the exact test invocation + gating pattern, and (f) every gotcha (PTY-not-pipes,
NUL-delimiter parsing, dedicated compdump, `-f`-skips-aliases-by-design, the Enter→undefined
cd conflict). No zsh/luv knowledge beyond what's quoted here is required.

### Documentation & References

```yaml
# MUST READ #1 — THE canonical technique this driver ports (fetched + fully quoted in research/)
- url: https://raw.githubusercontent.com/Valodim/zsh-capture-completion/master/capture.zsh
  why: "the proven zsh-capture-completion script: zmodload zsh/zpty; zpty z zsh -f -i; the compadd override
        (builtin compadd -A __hits -D __dscr); the zstyles; the NUL compprefuncs/comppostfuncs delimiters;
        driving via zpty -w z \"$*\"$'\\t'. THIS is the lineage of the INNER init script."
  critical: "it is ONE-SHOT (re-spawns the inner zsh per request + exits). The persistent daemon ADAPTS it:
            drop the comppostfuncs 'exit', add an outer read-loop, clear the inner line (^U) before each drive.
            The compadd override + zstyles + compinit-dump are taken VERBATIM."

# MUST READ #2 — the research notes for THIS task (canonical source quoted + every gotcha LIVE-noted)
- file: plan/002_d23d7473c16c/P2M3T5S1/research/zsh_driver_findings.md
  why: "§1 why a PTY is required + the outer-zsh-wrapper architecture; §2 the compadd override verbatim;
        §3 the inner-init block; §4 -f + dedicated compdump rationale; §5 the fiddly per-request drive
        (^U + type + read-between-NULs); §6 the single-object-JSON response contract; §7 the cd problem;
        §8 the Lua spawn (mirrors fish.lua); §9 zsh/zpty availability; §10 the test plan; §11 risk."
  pattern: "outer zsh + zsh/zpty-managed inner; Lua driver ≈ fish.lua; complexity is in the zsh script"
  gotcha: "§5 flags the version-sensitive bits (default ^U binding, pty echo, CR/LF) that the SPIKE must
           validate against the installed zsh (5.9.2 here)."

# MUST READ #3 — the contract this driver must satisfy (already-landed, read-only)
- file: lua/pi-bridge/shell.lua
  why: "M.ensure (L329) calls state.driver.start(opts, cb) where cb=function(err,proc,stdin,stdout) (L696-712);
        M.pick_driver (L220) validates type(drv.start)=='function'; M._feed (L525) decodes the single-object
        JSON between sentinels; M.teardown/close_handles (L621/L680) kill+close proc/stdin/stdout and EXPLICITLY
        do NOT close stderr ('the driver owns it'). Read L525-L620 (_feed) for the EXACT response shape."
  pattern: "the driver seam: start(opts,on_ready)→on_ready(err,proc,stdin,stdout); driver owns stderr + startup timer"
  gotcha: "on_ready takes 4 args (err, proc, stdin, stdout). proc MUST be the uv_process_t (teardown process_kills
           it). stdout MUST NOT be read_start'd by the driver (shell.lua owns it post-on_ready) — use STDERR for
           the ready signal (identical to fish.lua)."

# MUST READ #4 — the TEMPLATE driver to copy (Complete). zsh.lua is fish.lua with a different DAEMON_SCRIPT.
- file: lua/pi-bridge/shell/fish.lua
  why: "the EXACT start(opts,on_ready) shape to mirror: the done()/fail()/resolved-flag closure discipline,
        the stderr-ready-signal read (read_start STDERR for __PIREADY__\\n), the startup-timer arm/cancel,
        the failure-path kill+close order (stderr read_stop→close, proc process_kill→close, stdin close,
        stdout close), the module-local last_stdin for cd(). zsh.lua's Lua is ~90% identical to this file."
  pattern: "DAEMON_SCRIPT long-string + os.tmpname() + uv.new_pipe×3 + uv.spawn + read_start(stderr, ready) + on_ready"
  gotcha: "fish used `fish -i --init-command=source <tmp>` (ONE temp file). zsh needs TWO cooperating scripts
           (outer loop + inner init) — pass the inner path as a 2nd positional arg (args={'-f', outer, inner}).

# The validated fish spike — your zsh spike's structural template
- file: tests/shell_fish_spike.lua
  why: "P2.M1.T2.S1 (Complete) — the plenary-free standalone proof pattern. The zsh spike (Task 1) copies its
        shape: uv.spawn → read_start(stdout) → write one __PIREQ__ → parse between sentinels → assert checkout/cherry.
        DIFFERENCE: the zsh spike spawns the OUTER zsh (which owns the inner pty); from Lua it looks identical."
  pattern: "standalone plenary-free smoke: gate on executable, spawn, framed round-trip, teardown idiom"
  gotcha: "the fish spike read stdout ITSELF (one-shot). The DRIVER reads STDERR for ready + hands stdout to
           shell.lua; the spike reads stdout directly (it stands in for shell.lua). Mirror that split."

# The caller (completion routing — already Complete; do NOT modify, just understand the consumer)
- file: lua/pi-bridge/completion.lua
  why: "do_shell_fetch (L411) → shell.complete_current (L945) → shell.request → ensure → driver.start. The response
        cb runs in LIBUV FAST context (L429-440) — your driver must do NO vim.api.* in its callbacks (only luv +
        state writes); the menu hop is vim.schedule'd by the consumer. Already handled; don't ADD vim.api calls."
  pattern: "fast-context-safe driver callbacks (luv only); consumer schedules the UI"
  gotcha: "complete_current reads the buffer + strips bangs + computes byte offsets BEFORE calling shell.request —
           your driver never touches the buffer (same invariant as fish.lua)."

# Test fake pattern — the real zsh.lua MUST match this exact interface
- file: tests/shell_complete_current_spec.lua
  why: "inject_fake_driver (L67) defines the contract the real zsh.lua must satisfy: drv.start=function(opts,cb)
        cb(nil, {is_closing=...}, stdin, stdout). Your real start() must hand REAL luv handles of the same shape."
  pattern: "package.loaded['pi-bridge.shell.zsh'] = {start=..., cd=...}; cb(err,proc,stdin,stdout)"
  gotcha: "existing specs set package.loaded['pi-bridge.shell.zsh']=nil in cleanup. Your live-driver spec must do
           the SAME so a stale real module doesn't leak into shell.lua's unit tests (mirror the fish spec)."

# PRD source-of-truth
- url: in-repo PRD.md §17.6.2 (zsh — Tier 1 capture-completion), §17.5.1 (Framing protocol), §17.5.2 (daemon)
  why: "the design intent + the 'most fragile driver' warning + the fzf/Valodim lineage reference. §17.5.1 defines
        the wire frame (__PIREQ__\\t{json}\\n / __PIRESP_START__\\n{single-object}\\n__PIRESP_END__\\n)."
  critical: "§17.6.2's sketch hints at a compadd-redefining widget but is INCOMPLETE on the PTY requirement and
            the per-request line-clearing. research/zsh_driver_findings.md §1/§5 fill those gaps from the canonical
            source. Treat the PRD sketch as intent, the research notes + canonical source as authority."

# zsh docs (the three mechanisms the inner script depends on)
- url: https://zsh.sourceforge.io/Doc/Release/Zsh-Modules.html#The-zsh_002fzpty-Module
  why: "zsh/zpty: zpty name command (spawn), zpty -w name data (write/\"type\"), zpty -r name var (read), zpty -d name (delete)."
  critical: "zpty spawns its command in a pseudo-terminal — THIS is what gives the inner zsh the TTY zle needs.
            The pty is internal to the outer zsh; nvim/luv only see the outer's plain pipes."
- url: https://zsh.sourceforge.io/Doc/Release/Completion-Widgets.html
  why: "complete-word (the ^I/Tab widget that drives compsys); bindkey; the compprefuncs/comppostfuncs hooks."
- url: https://zsh.sourceforge.io/Doc/Release/Completion-System.html
  why: "compinit (-d dump, -C cached, -u insecure-skip); compadd (-A/-D array capture, -d descriptions); zstyle list-*."
  critical: "use a DEDICATED compdump (-d $TMPDIR/pi-zcompdump) so you never corrupt the user's ~/.zcompdump."
```

### Current Codebase tree (relevant slice)

```bash
lua/pi-bridge/
├── shell.lua              # COMPLETE (P2.M1.T2 + P2.M2.T3). The daemon manager + driver caller.
├── completion.lua         # COMPLETE. do_shell_fetch→complete_current→shell.request.
├── shell/accept.lua       # COMPLETE (P2.M2.T4.S3). M.quote(word, "zsh") → POSIX single-quote (zsh path ALREADY supported).
├── shell/fish.lua         # COMPLETE (P2.M2.T4.S1). THE TEMPLATE — copy its start()/cd() shape.
└── (shell/zsh.lua MISSING) # ← THIS TASK adds it (2nd driver under lua/pi-bridge/shell/).
tests/
├── shell_fish_spike.lua        # COMPLETE — the spike PATTERN to copy (structure, gating, teardown).
├── shell_fish_driver_spec.lua  # COMPLETE — the spec PATTERN to copy (offline contract + LIVE gated case).
├── shell_fish_driver_smoke.lua # COMPLETE — the smoke PATTERN to copy (persistence + cd).
├── shell_ensure_spec.lua       # COMPLETE — uses FAKE drivers (the contract source).
└── minimal_init.lua            # plenary bootstrap for spec files.
```

### Desired Codebase tree with files to be added

```bash
lua/pi-bridge/shell/
└── zsh.lua               # NEW (S1). Exports M.start(opts,on_ready), M.cd(path).
                           # Embeds OUTER + INNER daemon scripts as Lua long-strings; writes them to
                           # temp files at start(); spawns `zsh -f <outer> <inner>`; reads STDERR for ready.
tests/
├── shell_zsh_spike.lua        # NEW (S1, Task 1, GATE). Plenary-FREE, LIVE (gated on `zsh`).
│                                # Standalone outer+inner pty round-trip: "git ch" → checkout/cherry.
├── shell_zsh_driver_smoke.lua  # NEW (S1, Task 4). Plenary-FREE, LIVE. Spawns the real driver, sends 3
│                                # sequential requests, asserts checkout/cherry + persistence.
└── shell_zsh_driver_spec.lua   # NEW (S1, Task 5). Plenary. Offline contract cases (start/cd signature,
                                # never-throws, on_ready arity, bogus-shell no-leak) + a LIVE case (skip if no zsh).
```

### Known Gotchas of our codebase & Library Quirks

```zsh
# CRITICAL (architecture, from research §1): zsh completion REQUIRES a TTY. Unlike fish (plain pipes +
#   `complete -C`), zsh completion is driven by the ZLE widget `complete-word` (bound to Tab), which only
#   activates on a real terminal. `vim.uv` (luv) has NO PTY API.
# → The driver spawns ONE OUTER `zsh -f <outer.zsh>` (plain pipes to nvim). The OUTER does
#   `zmodload zsh/zpty; zpty z zsh -f -i` to manage an INNER completion zsh inside a pseudo-terminal.
#   The pty is INTERNAL to the outer zsh — invisible to nvim/luv. From Lua the outer zsh looks EXACTLY
#   like the fish subprocess (plain stdin/stdout/stderr pipes). ALL the PTY complexity lives in the
#   OUTER's DAEMON_SCRIPT (zsh), NOT in Lua. zsh.lua ≈ fish.lua with a different spawn args + script.

# CRITICAL (the capture hook — from Valodim capture.zsh, research §2): redefine `compadd` in the INNER
#   zsh so every candidate flows through a function that lets zsh match/filter, then echoes word+desc:
#       compadd () {
#         # delegate -O/-A/-D array-storage calls (used by _describe/_values) — don't capture those
#         if [[ ${@[1,(i)(-|--)]} == *-(O|A|D)\ * ]]; then builtin compadd "$@"; return $?; fi
#         typeset -a __hits __dscr
#         # -d <name> carries descriptions
#         if (( $@[(I)-d] )); then __dscr=( "${(@P)${@[$[${@[(i)-d]}+1]]}}" ); fi
#         builtin compadd -A __hits -D __dscr "$@"    # ← zsh does the matching, fills the arrays
#         ... echo each hit (+ optional ' -- description', + dir-suffix '/') ...
#       }
#   `builtin compadd -A __hits -D __dscr "$@"` is the magic: zsh applies prefix/pattern matching itself.

# CRITICAL (response shape — shell.lua _feed contract, inherited from fish.lua): the OUTER zsh MUST emit
#   ONE single-object JSON between sentinels, NOT per-line NDJSON:
#       __PIRESP_START__\n{"items":[{"value":"checkout","description":"..."},...],"prefix":""}\n__PIRESP_END__\n
#   shell.lua _feed does pcall(vim.json.decode, payload) on the WHOLE body; NDJSON → decode throws →
#   parse_failure (§17.12) → daemon disabled after N failures. Mirror fish.lua's __pi_json_str manual
#   JSON-string escape (zsh has no JSON builtin — build via ${param//X/Y} substitutions).

# CRITICAL (luv): you CANNOT read_start the SAME pipe twice. shell.lua wires stdout:read_start AFTER
#   on_ready (shell.lua L707). So the driver must NOT read_start stdout. Emit __PIREADY__\n to STDERR
#   and read_start the STDERR pipe in start() — stdout stays pristine for shell.lua. (identical to fish.lua)

# GOTCHA (luv): uv.spawn is SYNCHRONOUS — returns (handle, err) immediately. The cold-start latency is the
#   INNER zsh's `compinit` (100ms-1s+ — it parses/compiles the completion functions + builds the dump),
#   which happens BEFORE the outer emits __PIREADY__. startup_timeout_ms (default 5000) is the safety net.
#   First run builds the dedicated compdump; later runs use compinit -C (cached) → faster.

# GOTCHA (luv): process_kill("sigkill") does NOT close the uv_process_t (is_closing stays false even after
#   on_exit). proc:close() is REQUIRED or the handle LEAKS (shell.lua F3 comment). Every PRE-on_ready failure
#   path must proc:close() after process_kill. Close order: stderr read_stop→close, proc process_kill→close,
#   stdin close, stdout close (mirror shell.lua close_handles L680-700 + fish.lua fail()). Also os.remove
#   BOTH temp files (outer + inner) on every terminal path.

# GOTCHA (zsh, -f skips aliases BY DESIGN): `zsh -f` (skip /etc/zshenv + ~/.zshenv + ~/.zshrc) means user
#   ALIASES/functions from .zshrc are NOT loaded. System completion DEFINITIONS (_git etc. from the system
#   fpath) ARE autoloadable → `git ch`→checkout/cherry works. This is CONSISTENT with PRD §17.4 prefer:"pi"
#   (bash execution has no zsh aliases either; completing a zsh-only alias would suggest a command that FAILS).
#   Do NOT source ~/.zshrc by default. Document as a known limitation + optional future config flag.

# GOTCHA (zsh, dedicated compdump): use `compinit -d $TMPDIR/pi-zcompdump-<pid>` (or ~/.zcompdump_pi_bridge)
#   so you NEVER corrupt the user's interactive ~/.zcompdump. Add `compinit -C` after the first run (use the
#   cached dump) to cut cold-start latency. Add `compinit -u` to skip the insecure-dir check (we control cwd).

# GOTCHA (zsh, Enter→undefined vs cd): Valodim binds ^M/^J (Enter) to `undefined` so a typed command is NEVER
#   executed. This means you CANNOT `zpty -w z "cd $dir"$'\n'` to cd the inner. v1 cd is ADVISORY: bake the
#   spawn cwd into the inner (zpty z zsh -f -i with cwd, or `cd` in the inner-init) and treat M.cd(path) as a
#   documented best-effort no-op for zsh (research §7). A dedicated control-char widget for true cd is a future
#   enhancement. Do NOT break the Enter→undefined safety to make cd work.

# GOTCHA (zsh, the per-request drive — SPIKE-mandated, research §5): for a PERSISTENT inner zsh the line editor
#   has LEFTOVER text after each completion, so the OUTER must CLEAR the line before typing:
#       zpty -w z $'\025'                # Ctrl-U (unix-line-discard) — kill the current line
#       zpty -w z "$cmd"$'\t'            # type the new command + Tab → drives complete-word → our compadd
#   The typed command is ECHOED by the inner's pty → appears in zpty -r output. The NUL compprefuncs/
#   comppostfuncs delimiters bound the REAL completion output; parse between NULs only, strip \r.
#   `^U` default binding holds under `-f` (no user rc rebinds it) — VERIFY in the spike anyway (zsh-version-sensitive).

# GOTCHA (test isolation): existing shell_*_spec/smoke files set package.loaded["pi-bridge.shell.<basename>"]=nil
#   in cleanup. Your new zsh spec/smoke MUST do the same (for "zsh") so the REAL module doesn't leak into those tests.
```

## Implementation Blueprint

### Data models and structure

No persistent data models. The driver is a stateless-ish module with a small per-spawn
closure (the temp-file paths, the stderr-ready buffer, the startup timer, the proc/pipes) —
structurally identical to fish.lua. The DAEMON SCRIPT's wire types (fixed by shell.lua
`_feed` / PRD §17.5.1):

```jsonc
// Request (shell.lua writes this to the OUTER zsh's stdin):
"__PIREQ__\t{\"line\":\"git ch\",\"cursor\":6,\"after\":\"\"}\n"
// Response (the OUTER zsh emits this on its stdout, shell.lua _feed decodes):
"__PIRESP_START__\n{\"items\":[{\"value\":\"checkout\",\"description\":\"...\"}],\"prefix\":\"\"}\n__PIRESP_END__\n"
// Readiness (the OUTER zsh emits this on its STDERR once, after the inner signals compinit-done):
"__PIREADY__\n"
// cd (best-effort, advisory for zsh v1):
"__PICD__\t/some/path\n"
```

### The zsh daemon scripts (the embedded long-strings — DRAFT, validate verbatim in the SPIKE)

The OUTER script (a non-interactive zsh with a `while read` loop + zpty management):

```zsh
# === pi-bridge zsh completion daemon — OUTER (PRD §17.6.2 / §17.5.1; ports Valodim capture.zsh) ===
# Spawned by Lua as: `zsh -f <this-file> <inner-init-path>`. -f skips zshenv/zshrc (the outer needs
# no zle). Reads framed __PIREQ__ lines from stdin; drives the INNER completion zsh via zsh/zpty;
# emits ONE single-object JSON between sentinels. Emits __PIREADY__ to stderr once at startup.
zmodload zsh/zpty || { echo "error: zsh/zpty missing" >&2; exit 1 }

# jq-free JSON string escape (mirror fish.lua's __pi_json_str; zsh has no JSON builtin).
# Escapes \, ", \n, \r, \t. Outputs the double-quoted JSON string. (validate in the spike)
__pi_json_str() {
    local s="$1"
    s="${s//\\/\\\\}"; s="${s//\"/\\\"}"; s="${s//$'\n'/\\n}"; s="${s//$'\r'/\\r}"; s="${s//$'\t'/\\t}"
    printf '"%s"' "$s"
}

# Spawn the INNER completion zsh in a pseudo-terminal (THIS gives it the TTY zle needs).
# Pass the inner-init path as $1; the inner sources it then echoes a readiness marker.
zpty z zsh -f -i
zpty -w z "source $1"$'\n'
# Wait for the inner's readiness (it echoes __PIINNER_READY__ after compinit). Read the pty
# linewise until the marker appears (NUL/CR-tolerant). On timeout → error to stderr + exit.
local _line _ready=0
_repeat=40  # ~ up to a few seconds (the slow part is compinit cold-start)
while (( _repeat-- > 0 )); do
    zpty -r z _line || break
    [[ "$_line" == *"__PIINNER_READY__"* ]] && { _ready=1; break; }
done
(( _ready )) || { echo "error: inner never ready (compinit timeout?)" >&2; exit 2 }
# Announce readiness to Lua on STDERR (stdout is owned by shell.lua post-on_ready).
printf '__PIREADY__\n' >&2

# Persistent request loop (the spike does ONE; production loops for the session).
while IFS= read -r req; do
    case "$req" in
        (__PIREQ__*)
            # Extract .line via the SIMPLE zsh parameter parse (the JSON payload is small + the
            # command text rarely contains a literal "; mirror fish.lua's known-limitation note).
            local payload="${req#__PIREQ__	}"      # strip "__PIREQ__\t" (literal tab)
            local cmd="${${payload#*\"line\":\"}%%\"*}"  # crude but robust for command text
            echo __PIRESP_START__
            # Drive the inner: clear its line (^U), type the command + Tab (complete-word → our compadd).
            zpty -w z $'\025'"$cmd"$'\t'
            # Read the inner pty between the NUL delimiters (compprefuncs/comppostfuncs emit \0 before/after).
            # Collect compadd-emitted lines (word<TAB>desc), build the items JSON, emit it.
            local _items="" _first=1 _between=0 _l
            while zpty -r z _l; do
                _l="${_l//$'\r'/}"                 # strip pty CR
                [[ "$_l" == *$'\0'* ]] && { ((_between)) && break || _between=1; continue }
                ((_between)) || continue
                # split on first tab: word / desc
                local _w="${_l%%$'\t'*}" _d=""
                [[ "$_l" == *$'\t'* ]] && _d="${_l#*$'\t'}"
                [[ -z "$_w" ]] && continue
                local _it="{\"value\":$(__pi_json_str "$_w")"
                [[ -n "$_d" ]] && _it="${_it},\"description\":$(__pi_json_str "$_d")"
                _it="${_it}}"
                if ((_first)); then _items="$_it"; _first=0; else _items="${_items},${_it}"; fi
            done
            printf '{"items":[%s],"prefix":""}\n' "$_items"
            echo __PIRESP_END__
            ;;
        (__PICD__*)
            # v1 zsh cd is ADVISORY (the inner's Enter→undefined; research §7). Best-effort: no-op
            # (the spawn cwd is baked in). A future control-char widget can make this real.
            ;;
    esac
done
zpty -d z   # delete the inner pty on EOF
```

The INNER init script (mirrors Valodim's sourced block; written to a 2nd temp file, sourced
by the outer). Drop the `exit` Valodim had (keep the inner alive); keep the NUL delimiters:

```zsh
# === pi-bridge zsh completion daemon — INNER init (Valodim capture.zsh lineage) ===
# Sourced by the inner `zsh -f -i` (via the outer's `zpty -w z "source $1"`).
PROMPT=
autoload -Uz compinit
compinit -d "$TMPDIR/pi-zcompdump-$$" -u        # dedicated dump (never the user's); -u skip insecure check
# cached fast-path on 2nd+ run: compinit -C -d <same dump>
bindkey '^M' undefined                          # Enter → never execute a typed command
bindkey '^J' undefined
bindkey '^I' complete-word                      # Tab → drives compsys → our compadd override
zstyle ':completion:*' list-grouped false
zstyle ':completion:*' insert-tab false
zstyle ':completion:*' list-separator ''        # no separator → less stripping
zmodload zsh/zutil                              # for zparseopts (used in the compadd override)
null-line () { echo -E - $'\0' }                # NUL before+after the completion list (per-request delimiter)
compprefuncs=( null-line )
comppostfuncs=( null-line )                     # NOTE: NO `exit` (Valodim had it — we keep the inner alive)
compadd () {
    # delegate -O/-A/-D array-storage calls (used by _describe/_values) — don't capture those
    if [[ ${@[1,(i)(-|--)]} == *-(O|A|D)\ * ]]; then builtin compadd "$@"; return $?; fi
    typeset -a __hits __dscr __tmp
    if (( $@[(I)-d] )); then
        __tmp=${@[$[${@[(i)-d]}+1]]}
        if [[ $__tmp == \(* ]]; then eval "__dscr=$__tmp"; else __dscr=( "${(@P)__tmp}" ); fi
    fi
    builtin compadd -A __hits -D __dscr "$@"     # zsh does the matching; fills __hits + __dscr
    setopt localoptions norcexpandparam extendedglob
    typeset -A apre hpre hsuf asuf
    zparseopts -E P:=apre p:=hpre S:=asuf s:=hsuf
    integer dirsuf=0
    if [[ -z $hsuf && "${${@//-default-/}% -# *}" == *-[[:alnum:]]#f* ]]; then dirsuf=1; fi
    [[ -n $__hits ]] || return
    local dsuf dscr i
    for i in {1..$#__hits}; do
        (( dirsuf )) && [[ -d $__hits[$i] ]] && dsuf=/ || dsuf=
        (( $#__dscr >= $i )) && dscr="${__dscr[$i]}" || dscr=
        printf '%s\t%s\n' "$IPREFIX$apre$hpre$__hits[$i]$dsuf$hsuf$asuf" "$dscr"
    done
}
echo __PIINNER_READY__                          # readiness signal the outer reads from the pty
```

> ⚠ The OUTER/INNER scripts above are a **validated-intent draft**. They encode the exact
> Valodim technique (research §2/§3) adapted for a persistent daemon. The SPIKE (Task 1)
> MUST run this end-to-end against the installed zsh (5.9.2) and FIX the version-sensitive
> bits (the `.line` extraction robustness, the `^U` clear, the NUL-delimiter parsing, the
> compinit-dump path, the `read` loop's interaction with pty echo). The SPIKE is the source
> of truth; adjust zsh.lua's `DAEMON_SCRIPT` to match the proven spike script verbatim.

### Implementation Tasks (ordered by dependencies)

```yaml
Task 1: CREATE tests/shell_zsh_spike.lua — the GATE (validate the pty round-trip BEFORE the driver)
  - IMPLEMENT: a standalone plenary-free proof that the OUTER+INNER pty round-trip yields
    checkout/cherry for "git ch". Copy tests/shell_fish_spike.lua's structure + the
    tests/shell_ensure_smoke.lua L1-L25 header/run convention.
  - STEPS:
    1. GATE: if vim.fn.executable("zsh")==0 → print "SPIKE_SKIP: zsh not on PATH" + return (exit 0).
    2. Write the OUTER + INNER scripts above to /tmp (os.tmpname ×2 OR inline files).
    3. uv.spawn("zsh", {args={"-f", outer_path, inner_path}, stdio={stdin,stdout,stderr}}, noop_on_exit).
    4. read_start STDOUT; send ONE __PIREQ__\t{"line":"git ch","cursor":6,"after":""}\n; parse between
       __PIRESP_START__/__PIRESP_END__ (vim.json.decode the body); assert items contain checkout+cherry.
    5. teardown: process_kill + close all 3 handles (spike idiom). vim.wait with a hard timeout (AGENTS.md).
  - RUN: `timeout 60 nvim --headless --clean -u NORC -c 'set rtp+=.' +"luafile tests/shell_zsh_spike.lua" +qa`
    (AGENTS.md HARD RULE: FILE run via :luafile — NEVER heredoc-to-nvim-stdin).
  - CRITICAL: this is the GATE. If checkout/cherry don't appear, iterate on the OUTER/INNER scripts
    (the .line extraction, ^U clear, NUL parsing, compinit-dump path) until they do. The PROVEN spike
    scripts become zsh.lua's DAEMON_SCRIPT verbatim. Do NOT proceed to Task 2 with a failing spike.
  - GOTCHA: the spike reads STDOUT directly (it stands in for shell.lua). The DRIVER will read STDERR
    for __PIREADY__ and hand stdout to shell.lua — the spike does NOT need the ready signal (it just
    writes the request + waits for the response). Keep the spike's read logic minimal.

Task 2: CREATE lua/pi-bridge/shell/zsh.lua — module skeleton + the two DAEMON_SCRIPT long-strings
  - IMPLEMENT: local M = {}; OUTER_SCRIPT + INNER_SCRIPT as Lua [[ ]] long-strings (copy the
    PROVEN spike scripts — Task 1's output — verbatim, parameterized by the inner temp path);
    return M at the bottom.
  - FOLLOW pattern: lua/pi-bridge/shell/fish.lua's structure (the [Mode A] header, module-local M,
    the DAEMON_SCRIPT constant, local uv = vim.uv, the module-local last_stdin).
  - NAMING: module-local `M`; the script helpers are __pi_-prefixed (avoids colliding with compsys
    internals — compadd/PROMPT/etc. are global in the inner zsh).
  - PLACEMENT: lua/pi-bridge/shell/zsh.lua (the basename MUST be `zsh` — shell.lua's pick_driver does
    require("pi-bridge.shell."..basename); basename("/usr/bin/zsh")=="zsh").
  - GOTCHA: do NOT require("pi-bridge") at module top (handshake async; lazy-require inside functions
    only if needed — zsh.lua likely needs NO pi-bridge require; it only uses vim.uv, like fish.lua).

Task 3: IMPLEMENT M.start(opts, on_ready) in zsh.lua
  - SIGNATURE: M.start(opts, on_ready) where opts={shell,cwd,startup_timeout_ms}; on_ready is
    function(err, proc, stdin, stdout). COPY fish.lua's start() verbatim, changing ONLY:
      (a) spawn args: {"-f", outer_tmp, inner_tmp} (2nd positional = inner-init path; outer reads $1).
      (b) write TWO temp files (outer + inner) via os.tmpname() ×2; os.remove BOTH on every terminal path.
  - STEPS (each pcall'd / never-throws — copy fish.lua's done()/fail()/resolved-flag discipline):
    1. guard on_ready type (if not function, noop).
    2. write OUTER_SCRIPT + INNER_SCRIPT to two temp files. pcall; on fail → on_ready("script write failed",...).
    3. create 3 pipes: stdin/stdout/stderr = uv.new_pipe(false).
    4. uv.spawn(opts.shell or "zsh", {args={"-f",outer_tmp,inner_tmp}, stdio={stdin,stdout,stderr},
       cwd=(opts.cwd or nil)}, on_exit). pcall; on spawn_err → fail(path) → on_ready(err,nil,nil,nil).
    5. arm startup timer: uv.new_timer(); :start(opts.startup_timeout_ms or 5000, 0, timeout_cb) → fail.
       (the SLOW part is the inner's compinit, gated by __PIREADY__; 5000ms is the safety net.)
    6. read_start STDERR for __PIREADY__: accumulate into ready_buf; if ready_buf:find("__PIREADY__\n",1,true)
       then stderr:read_stop() + timer:stop()+close() + os.remove(BOTH temps) + cache last_stdin +
       on_ready(nil, proc, stdin, stdout). EOF on stderr before ready → startup-failure path (inner crashed
       during compinit / zsh/zpty missing → the outer exits → on_exit → fail).
  - CRITICAL: hand stdout to on_ready UNTOUCHED (no read_start on stdout — shell.lua owns it). The OUTER
    emits __PIREADY__ to STDERR after the inner signals __PIINNER_READY__ on the pty.
  - CRITICAL: the on_exit cb — if on_ready already called (success), noop (shell.lua's stdout EOF → _reset
    handles it); if NOT yet called, treat as startup failure. Track with local `resolved=false` closed over
    by on_exit + the ready cb + the timer cb (copy fish.lua exactly).
  - GOTCHA: proc:close() REQUIRED after process_kill (F3 leak). Failure-path close order: stderr read_stop→close,
    proc process_kill→close, stdin close, stdout close (mirror fish.lua fail()). os.remove BOTH temp files.

Task 4: IMPLEMENT M.cd(path) in zsh.lua
  - SIGNATURE: M.cd(path) — best-effort re-cd over the framed channel. COPY fish.lua's cd() verbatim.
  - v1 zsh semantics: ADVISORY. The OUTER recognizes __PICD__\t<path>\n but (per the Enter→undefined
    constraint, research §7) treats it as a no-op for v1 (the spawn cwd is baked into the inner via
    opts.cwd). The method EXISTS (the contract requires it) and never throws, but does not change the
    inner's cwd. Document this prominently in the zsh.lua header + the future doc/pi-bridge-shell.txt
    (P2.M3.T6.S4). A dedicated control-char widget for TRUE cd is a documented future enhancement.
  - GOTCHA: cd writes via last_stdin (cached by start(); ONE daemon/session). pcall + is_closing-guard
    every use. A dead/closing pipe → silent noop (cd is advisory; never an error).

Task 5: CREATE tests/shell_zsh_driver_smoke.lua (plenary-FREE, LIVE-gated)
  - IMPLEMENT: standalone smoke (mirror tests/shell_fish_driver_smoke.lua structure).
  - STEPS:
    1. GATE: if vim.fn.executable("zsh")==0 → print "SMOKE_SKIP: zsh not on PATH" + return (exit 0).
    2. require("pi-bridge.shell.zsh").start({shell="zsh",cwd=vim.fn.getcwd(),startup_timeout_ms=5000}, cb).
    3. cb(nil,proc,stdin,stdout): wire stdout:read_start into a sentinel parser (find
       __PIRESP_START__\n..__PIRESP_END__\n, vim.json.decode the body — copy the fish smoke's parser).
    4. send 3 SEQUENTIAL __PIREQ__ frames (git ch, ls /tm, git che) — each after the prior resolves
       (persistence proof — the spike did ONE). Assert each decodes + that "git ch" yields checkout+cherry.
    5. test cd: write __PICD__\t<vimpld> then a request — assert NO crash (cd is advisory; the assert is
       "no throw", not "cwd changed" — document the v1 limitation).
    6. teardown: process_kill + close all handles. Set package.loaded["pi-bridge.shell.zsh"]=nil.
  - RUN: `timeout 60 nvim --headless --clean -u NORC -c 'set rtp+=.' +"luafile tests/shell_zsh_driver_smoke.lua" +qa`
  - GOTCHA: the driver reads STDERR for __PIREADY__ itself (Task 3 step 6); the smoke must NOT also read
    stderr. The test reads only STDOUT (post-on_ready).

Task 6: CREATE tests/shell_zsh_driver_spec.lua (plenary, live + offline)
  - IMPLEMENT: plenary/busted spec (mirror tests/shell_fish_driver_spec.lua structure + the
    after_each package.loaded["pi-bridge.shell.zsh"]=nil cleanup).
  - CASES:
    1. offline: M.start and M.cd are functions; require loads without error.
    2. offline: M.start({}, cb) with a non-function cb does NOT throw (never-throws contract).
    3. offline: M.start({shell="/nonexistent/zsh"}, cb) → cb(err, nil,nil,nil); no leaked handles
       (uv.walk handle-count before/after assert, mirror shell_fish_driver_spec.lua).
    4. LIVE (skip if no zsh): M.start real spawn → cb(nil,proc,stdin,stdout) within timeout; send "git ch"
       → decoded items contain checkout + cherry. Set package.loaded[...]=nil in after_each.
  - RUN: `timeout 90 nvim --headless --clean -u tests/minimal_init.lua -c 'lua require("plenary.busted").run("tests/shell_zsh_driver_spec.lua")'`
  - GOTCHA: the LIVE case must vim.wait for on_ready (async — the ready marker arrives on stderr after
    the inner's compinit). Use a generous timeout (startup_timeout_ms + slack; compinit cold-start can
    exceed 1s on first run while it builds the dedicated compdump).

Task 7: (NO shell.lua / completion.lua / extension changes)
  - VERIFY: shell.lua's pick_driver already does require("pi-bridge.shell.zsh") + validates .start.
    completion.lua's do_shell_fetch already calls shell.complete_current → shell.request → ensure →
    driver.start. shell/accept.lua's M.quote(word,"zsh") already returns the POSIX single-quote form
    (P2.M2.T4.S3). The bridge descriptor's `shell` field (P2.M1.T1) already feeds resolve_shell →
    pick_driver selects zsh when the resolved shell basename is "zsh". So S1 is PURELY additive:
    one new module + spike + smoke + spec. Do NOT edit any existing file.
```

### Implementation Patterns & Key Details

```lua
-- PATTERN: zsh.lua's start() is fish.lua's start() with different spawn args + 2 temp files.
--   Copy the done()/fail()/resolved-flag closure discipline VERBATIM from fish.lua. The only
--   edits are: (a) spawn args {"-f", outer_tmp, inner_tmp}; (b) write + remove TWO temp files;
--   (c) the DAEMON_SCRIPT constant(s). The read_start(STDERR, __PIREADY__) + handoff-stdout-pristine
--   + failure-close-order are IDENTICAL.

-- PATTERN: the DAEMON_SCRIPT is a Lua [[ ]] long-string so NONE of its \n/\t/\\ are interpreted
--   by Lua — they are LITERAL zsh source (fish.lua does the same). The zsh script's OWN escapes
--   (e.g. ${s//\\/\\\\}) are zsh parameter substitutions.

-- PATTERN: the OUTER writes the INNER path as $1 (a 2nd spawn arg). This avoids embedding the
--   inner script inline in the outer (quoting hell) and lets each script be a clean long-string.

-- CRITICAL: the response MUST be ONE single-object JSON (shell.lua _feed constraint). The OUTER
--   builds it via __pi_json_str (mirror fish.lua). Do NOT emit per-line NDJSON.

-- CRITICAL: the OUTER clears the inner's line before each drive (zpty -w z $'\025'"$cmd"$'\t').
--   Without ^U, leftover text from the prior completion corrupts the next. (research §5)

-- CRITICAL: parse the inner pty output BETWEEN the NUL compprefuncs/comppostfuncs delimiters.
--   Everything outside (prompt, typed-command echo, CR) is noise — discard it. Strip \r.
```

### Integration Points

```yaml
DRIVER SELECTION (no change — already works):
  - shell.lua M.pick_driver(basename) → require("pi-bridge.shell.zsh") when basename=="zsh".
    Selected automatically when the resolved execution shell is zsh (bridge descriptor.shell /
    $SHELL / the shellPath setting → resolve_shell → pick_driver).

ACCEPTANCE (no change — already works):
  - lua/pi-bridge/shell/accept.lua M.quote(word, "zsh") → POSIX single-quote with the
    '"'"'"' idiom for embedded quotes (P2.M2.T4.S3, Complete). zsh's quoting path is ALREADY
    implemented + tested. zsh.lua does NOT touch the buffer (accept.lua does).

CONFIG (forward contract — P2.M3.T6.S1, not this task):
  - setup({ shell = { drivers = { zsh = true } } }) enables/disables; zsh=true is the default.
    A future config.shell.zsh.source_rc flag (to load ~/.zshrc for aliases) is documented as a
    future enhancement; v1 uses -f (no rc). Do NOT add config parsing here.

TEARDOWN (no change):
  - ftplugin VimLeavePre/ExitPre → shell.teardown() (P2.M3.T6.S3) → close_handles() kills the
    OUTER zsh (SIGKILL); the INNER dies with its parent (the outer's pty closes). No special
    inner-teardown needed from Lua — killing the outer is sufficient.

HEALTH (forward contract — P2.M3.T6.S2, not this task):
  - :checkhealth pi-bridge will report the resolved zsh version + driver health + last error.
    zsh.lua need only exist + load; the health section reads shell.lua state.
```

## Validation Loop

### Level 1: Syntax & Style (Immediate Feedback)

```bash
# After creating zsh.lua — selene + stylua (the repo's Lua lint/format; follow the existing
# lua/pi-bridge/*.lua style: tabs, double-quoted strings, the [Mode A] header comment convention).
# Run from the repo root:
selene lua/pi-bridge/shell/zsh.lua
stylua --check lua/pi-bridge/shell/zsh.lua
# Quick load check (AGENTS.md: one-liner via -c 'lua ...' is fine; NO heredoc-to-stdin):
timeout 30 nvim --headless --clean -u NORC -c 'set rtp+=.' -c 'lua local m=require("pi-bridge.shell.zsh"); print(type(m.start), type(m.cd))' -c 'qa'
# Expected: function function printed, exit 0.
```

### Level 2: The SPIKE (the GATE — run BEFORE writing zsh.lua, and again after)

```bash
# The standalone pty round-trip proof. MUST yield checkout+cherry for "git ch".
# AGENTS.md: this is a FILE run via :luafile — NEVER heredoc-to-nvim-stdin.
timeout 60 nvim --headless --clean -u NORC -c 'set rtp+=.' +"luafile tests/shell_zsh_spike.lua" +qa
echo "exit=$?"   # 0 = SPIKE_PASS (or SPIKE_SKIP if zsh absent); 1 = GATE FAILED — iterate the scripts
# If SPIKE fails: the OUTER/INNER scripts need fixing (the .line extraction, ^U clear, NUL parsing,
# compinit-dump path). Fix in the spike FIRST, then port the proven scripts into zsh.lua verbatim.
```

### Level 3: Unit / Component Tests (plenary + smoke)

```bash
# The plenary-FREE smoke (LIVE zsh, persistence + cd):
timeout 60 nvim --headless --clean -u NORC -c 'set rtp+=.' +"luafile tests/shell_zsh_driver_smoke.lua" +qa
# The plenary spec (offline contract + LIVE gated case):
timeout 90 nvim --headless --clean -u tests/minimal_init.lua -c 'lua require("plenary.busted").run("tests/shell_zsh_driver_spec.lua")'
# Regression: ensure the new module doesn't break shell.lua's OWN (fake-driver) tests:
timeout 90 nvim --headless --clean -u tests/minimal_init.lua -c 'lua require("plenary.busted").run("tests/shell_ensure_spec.lua")'
# Expected: all green. zsh 5.9.2 IS present in this env → the LIVE cases run (not skipped).
```

### Level 4: Integration (the daemon manager + completion routing end-to-end)

```bash
# The REAL end-to-end: shell.lua ensure/request/_feed driving the REAL zsh.lua driver.
# Reuses the existing shell.lua pipeline — no new harness. Write a tiny driver-level integration
# smoke that calls shell.lua directly (like the fish driver's integration smoke). Example outline:
cat > /tmp/zsh_e2e.lua <<'LUA'           # heredoc to a FILE is fine (AGENTS.md); to nvim stdin is NOT
local shell = require("pi-bridge.shell")
shell.reset()
local got = nil
-- force the zsh path (resolve_shell("shell") → $SHELL if zsh; else hardcode via pick_driver)
shell.request("git ch", 6, "", function(err, items, prefix)
  got = { err=err, n=(items and #items or 0) }
end)
vim.wait(8000, function() return got ~= nil end, 20)
local found = false
-- (items normalize happens inside _feed; to inspect, hook shell._test_invoke_pending OR
--  re-run via the driver smoke which decodes the JSON directly.) Simpler: assert no err + non-empty.
io.stdout:write(got.err and ("E2E_ERR="..got.err) or ("E2E_PASS: items="..got.n).."\n")
shell.teardown()
LUA
timeout 60 nvim --headless --clean -u NORC -c 'set rtp+=.' +"luafile /tmp/zsh_e2e.lua" +qa
echo "exit=$?"
# Expected: E2E_PASS with items > 0. (Proves zsh.lua integrates with the ALREADY-LANDED shell.lua.)
```

### Level 5: Creative & Domain-Specific Validation

```bash
# Persistence + cd (the two things the spike did NOT prove):
#   the smoke (Task 5) sends 3 sequential requests through ONE spawned daemon — if the daemon died
#   after request 1 (a pty-state-leak), requests 2-3 would hang/timeout. Persistence = 3 sequential decodes.
#   cd: write __PICD__\t<path> then a request — assert NO crash (cd is advisory for zsh v1; a real
#   cwd change is a documented future enhancement via a control-char widget).
#
# compinit-dump isolation: after a run, confirm the user's ~/.zcompdump is UNCHANGED (the daemon
#   used $TMPDIR/pi-zcompdump-<pid>):
ls -la ~/.zcompdump && ls -la /tmp/pi-zcompdump-* 2>/dev/null
#   Expected: ~/.zcompdump untouched; a separate /tmp/pi-zcompdump-* exists (the dedicated dump).
#
# Quoting/escape correctness (the __pi_json_str helper): the LIVE "git ch" response decodes cleanly
#   (checkout has a description with spaces/punctuation) → the JSON helper is correct. For an offline
#   unit test, source the OUTER script in a zsh subprocess + call __pi_json_str on edge inputs (space,
#   quote, backslash) — OR trust the LIVE-VALIDATED response (v1 accepts the live proof, as fish did).
```

## Final Validation Checklist

### Technical Validation

- [ ] `tests/shell_zsh_spike.lua` passes (SPIKE_PASS: checkout+cherry for "git ch") — the GATE.
- [ ] All Level 1-4 validations completed successfully.
- [ ] `require("pi-bridge.shell.zsh")` loads; `M.start`/`M.cd` are functions (Level 1 one-liner).
- [ ] selene + stylua clean on `lua/pi-bridge/shell/zsh.lua`.
- [ ] shell.lua's fake-driver tests still green (no leak via package.loaded).

### Feature Validation

- [ ] `M.start` calls `on_ready(nil, proc, stdin, stdout)` with live handles within startup_timeout_ms.
- [ ] End-to-end: "git ch" → checkout/cherry in decoded items (LIVE zsh).
- [ ] Persistence: ≥3 sequential requests through ONE daemon decode successfully.
- [ ] Spawn error / binary-missing / startup-timeout / missing zsh/zpty → on_ready(err,nil,nil,nil),
      no leaked handles, never throws (the §17.12 degrade path then disables the daemon gracefully).
- [ ] cd(path) never throws (advisory no-op for zsh v1 — documented).
- [ ] The user's ~/.zcompdump is UNCHANGED (dedicated compdump used).

### Code Quality Validation

- [ ] Follows fish.lua's structure/conventions (the [Mode A] header, module-local M + uv + last_stdin,
      the done()/fail()/resolved-flag closure discipline, the failure-close order).
- [ ] File placement: lua/pi-bridge/shell/zsh.lua (basename "zsh" for pick_driver).
- [ ] DAEMON_SCRIPT is the PROVEN spike script verbatim (not the unvalidated draft).
- [ ] No `vim.api.*` in any luv callback (fast-context-safe; consumer schedules the UI).
- [ ] Anti-patterns avoided (see below): no plain-pipe completion attempt, no NDJSON, no user-compdump
      corruption, no rc sourcing by default, no vim.api in fast context.

### Documentation & Deployment

- [ ] zsh.lua header documents the PTY architecture + the -f/aliases limitation + the advisory cd.
- [ ] Forward-references the future doc/pi-bridge-shell.txt (P2.M3.T6.S4) + :checkhealth (P2.M3.T6.S2).
- [ ] cd advisory limitation noted for the future vimdoc (zsh users: cwd is the spawn cwd; mid-session
      cwd change re-spawns until the control-char-widget enhancement lands).

## Anti-Patterns to Avoid

- ❌ Don't try to drive zsh completion over PLAIN stdin pipes (no pty). ZLE/`complete-word` need a TTY.
      Use the outer-zsh + zsh/zpty wrapper (the proven Valodim model).
- ❌ Don't emit per-line NDJSON. shell.lua `_feed` decodes ONE object — use single-object JSON (fish.lua's
      __pi_json_str pattern), or the daemon hits the §17.12 parse-failure disable threshold.
- ❌ Don't read_start STDOUT in the driver (shell.lua owns it post-on_ready). Use STDERR for __PIREADY__.
- ❌ Don't source ~/.zshrc by default (breaks the prefer:"pi" correctness stance; slow; noisy). Use -f.
- ❌ Don't use the user's ~/.zcompdump. Use a dedicated dump (-d $TMPDIR/pi-zcompdump-<pid>) — never corrupt.
- ❌ Don't `zpty -w z "cd $dir"$'\n'` (Enter is bound to undefined — never execute). v1 cd is advisory.
- ❌ Don't write zsh.lua before the SPIKE passes (Task 1 is the GATE). The scripts are version-sensitive.
- ❌ Don't `proc:close()`-less failure paths (F3 leak: process_kill alone doesn't close uv_process_t).
- ❌ Don't add `vim.api.*` in luv callbacks (on_exit/timer/read run in libuv FAST context — E5560).
- ❌ Don't edit shell.lua/completion.lua/accept.lua/extension (all Complete; S1 is purely additive).
- ❌ Don't heredoc-to-nvim-stdin (AGENTS.md HARD RULE — it hangs). Write test files; run via :luafile.

## Confidence Score

**8/10** for one-pass implementation success.

- **Architecture: HIGH confidence.** The outer-zsh + zsh/zpty model is the proven Valodim technique
  (fetched + quoted); it fits the existing `start(opts,on_ready)` contract UNCHANGED (fish.lua proves
  the Lua shape). shell.lua/completion.lua/accept.lua are all Complete and zsh-aware. Purely additive.
- **Daemon script: MEDIUM confidence.** The OUTER/INNER scripts are a validated-intent DRAFT encoding
  the exact Valodim compadd-override + zstyles + pty-drive, but the per-request line-clearing, NUL-
  delimiter parsing, `.line` extraction, and compinit-dump path are zsh-version-sensitive. The SPIKE
  (Task 1, the GATE) de-risks exactly these — the implementer iterates the scripts against zsh 5.9.2
  until checkout/cherry appear, then ports the PROVEN scripts verbatim into zsh.lua. This is why the
  spike is Task 1, not Task 5.
- **Downside risk: LOW.** If zsh capture proves unfixable on a given build, the existing §17.12
  degrade path (parse_failures → state.failed → one-time notice) handles it gracefully — worst case
  zsh users get no completion, never a crash, never a broken system. No existing file is modified.

The 2-point delta to 10/10 is the version-sensitive pty plumbing, which the mandated spike
resolves before the driver is written.