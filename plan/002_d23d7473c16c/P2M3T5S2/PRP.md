---
name: "P2.M3.T5.S2 — bash.lua shell-completion driver: COMP_*/compgen dispatch via plain pipes + start(opts,on_ready) + cd(path)"
why_this_prp: "The Tier-2 bash driver for §17 shell completion — the LAST concrete driver before the unknown-shell degrade (S3). Unlike zsh (which needs a PTY because completion is driven by zle widgets), bash's `compgen` + `complete -F` dispatch are ordinary builtins callable non-interactively over PLAIN pipes — so bash.lua is structurally ≈ fish.lua (one process, one temp file, stderr-ready-signal, REAL cd). Every non-obvious detail below is LIVE-VERIFIED against bash 5.3.15 on this machine, including a CRITICAL fix: the PRD §17.6.3 `COMP_CWORD` accumulation loop is BUGGY for trailing-space inputs (`ls ` → wrong word); the proven truncated-prefix + trailing-whitespace detection fix is specified verbatim. It must satisfy the exact `start(opts,on_ready)` contract the already-landed shell.lua (P2.M1.T2) assumes and that fish.lua (P2.M2.T4.S1, Complete) established as the template."
---

## Goal

**Feature Goal**: Implement `lua/pi-bridge/shell/bash.lua` — the Tier-2 bash
shell-completion driver (PRD §17.6.3) — exposing `start(opts, on_ready)` (spawn a persistent
`bash <daemon_script>` subprocess that best-effort sources `bash-completion`, then loops on
stdin: each framed request sets `COMP_LINE`/`COMP_POINT`/`COMP_WORDS`/`COMP_CWORD` (via the
LIVE-VALIDATED trailing-whitespace-aware computation — NOT the PRD sketch's buggy loop),
dispatches to the command's `complete -F` function when one is registered, else falls back
to `compgen -f -d` (files/dirs — always works) or `compgen -abck` (command names, when
completing the first word), and emits ONE valid JSON object of `{value}`-only items between
sentinels) and `cd(path)` (REAL cd — bash is a plain script loop, not a zle-constrained
inner like zsh; mirrors fish.lua's cd verbatim). It is loaded by `shell.lua`'s
`M.pick_driver` (`require("pi-bridge.shell.bash")`) and driven by the existing
`M.ensure`/`M.request`/`M._feed` pipeline (already Complete).

**Deliverable**: One new Lua module `lua/pi-bridge/shell/bash.lua` (~140-200 lines)
exporting `M.start(opts, on_ready)` and `M.cd(path)`, plus a pure-Lua `M.parse(raw)` helper,
and three test files: a spike `tests/shell_bash_spike.lua` (plenary-free, LIVE — the
mandatory gate before writing the driver; runs unconditionally since `bash` is universal),
`tests/shell_bash_driver_smoke.lua` (plenary-free, LIVE; persistence + REAL cd), and
`tests/shell_bash_driver_spec.lua` (plenary; offline contract + LIVE cases). No changes to
`shell.lua`, `completion.lua`, `accept.lua`, or any extension file — the seams are already
in place (S1/zsh's landing proved the additive-only invariant).

**Success Definition**:
1. `require("pi-bridge.shell.bash").start` is a function and `.cd`/`.parse` are functions
   (the contract `shell.lua`'s `pick_driver` validates: `type(drv.start)=="function"`).
2. The SPIKE (`tests/shell_bash_spike.lua`) passes: a standalone `bash <script>` round-trip
   yields `/tmp` for `ls /tm` (works with ZERO completion infrastructure — this box has no
   `bash-completion`). This is the gate for writing `bash.lua`.
3. `start({shell="/usr/bin/bash",cwd=<tmp>,startup_timeout_ms=5000}, cb)` spawns a persistent
   bash process and calls `cb(nil, proc, stdin, stdout)` with live luv handles; the daemon
   stays alive across ≥3 sequential framed requests (persistence).
4. A framed request `__PIREQ__\t{"line":"ls /tm","cursor":6,"after":""}\n` yields a response
   `__PIRESP_START__\n{"items":[{"value":"/tmp"}],"prefix":""}\n__PIRESP_END__\n` whose decoded
   `items` include `/tmp` (the §17.6.3 "files/dirs always work" floor — proven even with no
   `bash-completion` installed).
5. Trailing-space correctness (the §3 fix): `ls ` (point=3) → `cur=""` → file/dir completion
   of the cwd, NOT command-name completion of `ls` (the PRD sketch's bug). LIVE-VALIDATED.
6. `state.failed` semantics: on spawn error / binary missing / startup-timeout, `start` calls
   `cb(err, nil, nil, nil)` (never throws, never leaves handles open — the existing §17.12
   degrade path then disables the daemon).
7. The three test files pass (smoke exit 0; spec green; spike PASS). LIVE cases run
   UNCONDITIONALLY (`bash` is universal on Linux CI — no `pending`/skip needed, stronger
   coverage than fish/zsh; PRD §17.15).

## User Persona (if applicable)

**Target User**: a pi user whose pi-resolved execution shell is bash (the `prefer:"pi"`
DEFAULT — pi executes `!`/`!!` via `/bin/bash -c` unless `shellPath` is set), and who types
`!`/`!!` shell commands into the pi-prompt Neovim buffer (PRD §17). Indirect user: the
`pi-bridge.nvim` plugin itself, which calls this driver through `shell.lua`.

**Use Case**: typing `!git ad<Tab>` in the pi-prompt buffer → the menu shows `add` (if
`bash-completion` + the `_git` compspec are installed) or `!ls /tm<Tab>` → `/tmp` (always,
even with zero completion infrastructure). Identical to typing `git ad<Tab>` / `ls /tm<Tab>`
at a real bash prompt.

**Pain Points Addressed**: with only fish (P2.M2.T4) + zsh (P2.M3.T5.S1, Complete) landed,
a bash-resolved user — the DEFAULT under `prefer:"pi"` — gets NO completion (`pick_driver`
returns nil for bash → `ensure` sets `state.failed` → the §17.12 degrade notice). Since bash
is pi's default execution shell, this closes the gap for the majority of UNCONFIGURED users.
PRD §17.6.3 calls bash Tier-2 ("best-effort", no descriptions, `compgen`-bare-words).

## Why

- **Closes the shell-completion gap for pi's DEFAULT execution shell.** Under `prefer:"pi"`
  (the spec default, §17.4) and no `shellPath` override, pi runs `!`/`!!` in `/bin/bash`. So
  the majority of unconfigured users resolve to bash — and today get NOTHING. This is the
  single largest remaining user cohort.
- **Completes the driver matrix.** fish (Complete) + zsh (Complete) + bash (this) + unknown
  (S3, Planned) cover every §17.4.2 path. With bash landed, only the `unknown` basename
  remains (a pure-degrade no-op, S3) — completing P2.M3.T5.
- **Consumes already-landed infrastructure; changes ZERO existing files.** `shell.lua`
  (`ensure`/`request`/`_feed`/`teardown`/`pick_driver`/`close_handles`), `completion.lua`
  (`do_shell_fetch`→`complete_current`), the bridge descriptor `shell` field (P2.M1.T1), and
  the `shell/accept.lua` quoting table (P2.M2.T4.S3 — bash uses the POSIX single-quote path,
  ALREADY implemented + tested) are all Complete. S2 is the leaf that turns bash completion
  on. It is PURELY additive (S1/zsh proved this invariant).

## What

A Lua module `lua/pi-bridge/shell/bash.lua` that:

1. On `start(opts, on_ready)`: writes the bash DAEMON_SCRIPT to a temp file, creates three
   `uv.new_pipe(false)` handles (stdin/stdout/stderr), spawns `bash <daemon_tmp>` (the script
   as a positional arg — NON-interactive script mode; `bash` does NOT need `-i` and `-i` is
   actively worse, see research §7) with `stdio={stdin,stdout,stderr}` and `cwd=opts.cwd`,
   arms a `startup_timeout_ms` cold-start timer, reads **stderr** for an `__PIREADY__\n`
   marker (emitted by the daemon after its best-effort `bash-completion` sourcing), and on
   readiness calls `on_ready(nil, proc, stdin, stdout)`. On any failure it kills the proc +
   closes all three pipes + removes the temp file + calls `on_ready(err, nil, nil, nil)`.
2. On `cd(path)`: writes `__PICD__\t<path>\n` to the daemon's stdin. For bash this is
   **REAL** (not advisory like zsh v1): the daemon's `__PICD__` branch does
   `builtin cd "$path"`, and subsequent path completions are relative to the new cwd. Mirrors
   fish.lua's `cd()` verbatim (research §6).
3. The bash DAEMON_SCRIPT (embedded as a Lua long-string, written to temp file): best-effort
   sources `bash-completion` (the 4 canonical paths, each `[ -r ]`-guarded + `|| true`),
   defines `__pi_json_str` (pure-bash parameter-substitution JSON escape — NO `python3`
   dependency, research §2), defines `__pi_complete` (sets `COMP_*` via the LIVE-VALIDATED
   trailing-whitespace-aware computation — research §3; dispatches `complete -F fn` if a
   compspec exists, else `compgen -abck` for `COMP_CWORD==0` else `compgen -f -d`),
   recognizes `__PIREQ__` (extract `.line`/`.cursor` via parameter substitution) and
   `__PICD__` frames, emits `__PIREADY__` to stderr once at startup, then enters a persistent
   `while IFS= read -r req` loop wrapping each request in `__PIRESP_START__`/`__PIRESP_END__`
   sentinels (single-object JSON — the shell.lua `_feed` contract).
4. Exports `M.parse(raw)` — a pure-Lua parser for raw `compgen`/`COMPREPLY` output
   (newline-delimited bare words; no descriptions) into `{ value:string }[]` — the testable
   offline reference of the same spec (mirrors fish.lua's/zsh.lua's `parse`; used only by the
   spec, NOT by shell.lua `_feed` which decodes the daemon's pre-built JSON).

### Success Criteria

- [ ] `tests/shell_bash_spike.lua` exits 0 with `SPIKE_PASS` — the `bash <script>` round-trip
      yields `/tmp` for `ls /tm` (works with NO `bash-completion`). **GATE: do not write
      `bash.lua` until this passes.**
- [ ] `lua/pi-bridge/shell/bash.lua` exists, `require("pi-bridge.shell.bash")` loads without
      error, and `M.start`/`M.cd`/`M.parse` are functions.
- [ ] `M.start` calls `on_ready(nil, proc, stdin, stdout)` with live handles within
      `startup_timeout_ms` (5s); the daemon survives ≥3 sequential framed requests.
- [ ] End-to-end: feeding `__PIREQ__\t{"line":"ls /tm","cursor":6,"after":""}\n` to the
      spawned daemon's stdin produces `/tmp` in the decoded `items` (LIVE bash; runs
      unconditionally — `bash` is universal).
- [ ] Trailing-space fix (§3): `ls ` (point=3) → `cur=""` → cwd file/dir completion (NOT
      command completion of `ls`). LIVE-VALIDATED; assert in the smoke.
- [ ] REAL cd: writing `__PICD__\t<vimpld>` then a `ls ` request yields the new cwd's entries
      (cd is REAL for bash — assert cwd CHANGED, unlike zsh's advisory no-op).
- [ ] Spawn error / binary-missing / startup-timeout → `on_ready(err, nil,nil,nil)`, no
      leaked handles, never throws.
- [ ] `tests/shell_bash_driver_smoke.lua` exits 0; `tests/shell_bash_driver_spec.lua` green.

## All Needed Context

### Context Completeness Check

_Pass_: an implementer who knows nothing about this codebase gets (a) the exact
`start(opts,on_ready)`/`cd(path)` contract with arg arity + return shape, (b) the COMPLETE
LIVE-VALIDATED bash daemon script (COMP_* computation, compgen dispatch, JSON escape, cd —
all proven against bash 5.3.15 in `research/bash_driver_findings.md`), (c) the architectural
reason bash is plain-pipes (unlike zsh's PTY) and why it's ≈ fish.lua, (d) the
stderr-ready-signal + single-object-JSON constraints (inherited from fish.lua / shell.lua
`_feed`), (e) the **critical §3 fix** (the PRD §17.6.3 `COMP_CWORD` loop is buggy; the
truncated-prefix + trailing-whitespace detection is the proven replacement), (f) the exact
test invocation + gating pattern (bash runs unconditionally — no skip), and (g) every gotcha
(no-descriptions Tier-2, no-`~/.bashrc`-by-design, no-`python3`-dependency, real-cd-vs-zsh).
No bash/luv knowledge beyond what's quoted here is required.

### Documentation & References

```yaml
# MUST READ #1 — THE canonical technique this driver ports (programmatic bash completion)
- url: https://brbsix.github.io/2015/11/29/accessing-tab-completion-programmatically-in-bash/
  why: "the brbsix reference for tapping bash completion non-interactively: set COMP_LINE/COMP_POINT/
        COMP_WORDS/COMP_CWORD, read the command's compspec via `complete -p cmd`, extract the -F function,
        call it (it populates COMPREPLY), else fall back to compgen. THIS is the lineage of __pi_complete."
  critical: "the article + its gist (https://gist.github.com/sandipchitale/09b7516537364c11d010970de70ae90e)
            is the authoritative COMP_* setup. The PRD §17.6.3 sketch omits the cword==0 command-name branch
            and has a BUGGY COMP_CWORD loop (research §3) — the brbsix approach + research §3's fix are authority."

# MUST READ #2 — the research notes for THIS task (every mechanic LIVE-VERIFIED + the §3 fix)
- file: plan/002_d23d7473c16c/P2M3T5S2/research/bash_driver_findings.md
  why: "§1 why bash is plain-pipes (≈ fish, NOT zsh); §2 the pure-bash JSON escape (python3-free, with output
        for every edge case); §3 THE COMP_CWORD fix (the PRD sketch is buggy; the truncated-prefix + trailing-ws
        detection is proven — full case table); §4 command-name completion (cword==0 → compgen -abck); §5 no
        bash-completion → compgen -f -d degrade (LIVE on this box); §6 REAL cd (vs zsh advisory); §7 the spawn
        form (bash <script>, non-interactive, source bash-completion best-effort); §8 no descriptions (Tier-2);
        §9 .line/.cursor extraction; §10 fragility + the subshell wrap; §11 the test plan."
  pattern: "bash.lua ≈ fish.lua (plain pipes, one temp file, real cd, stderr-ready-signal); complexity is the
            bash DAEMON_SCRIPT's COMP_* computation (LIVE-VALIDATED + fixed)"
  gotcha: "§3 is the single highest-risk item — the PRD §17.6.3 COMP_CWORD accumulation loop is WRONG for
           trailing-space inputs; use the §3b proven computation verbatim."

# MUST READ #3 — the contract this driver must satisfy (already-landed, read-only)
- file: lua/pi-bridge/shell.lua
  why: "M.ensure (L343) calls state.driver.start(opts, cb) where cb=function(err,proc,stdin,stdout);
        M.pick_driver (L234) validates type(drv.start)=='function'; M._feed (L539) decodes the single-object
        JSON between sentinels + increments state.parse_failures on a decode throw (§17.12 threshold=5);
        M.teardown/close_handles (L621/L705) kill+close proc/stdin/stdout and EXPLICITLY do NOT close stderr
        ('the driver owns it'). Read L539-L620 (_feed) for the EXACT response shape + parse-failure handling."
  pattern: "the driver seam: start(opts,on_ready)→on_ready(err,proc,stdin,stdout); driver owns stderr + startup timer"
  gotcha: "on_ready takes 4 args (err, proc, stdin, stdout). proc MUST be the uv_process_t (teardown process_kills
           it). stdout MUST NOT be read_start'd by the driver (shell.lua owns it post-on_ready) — use STDERR for
           the ready signal (identical to fish.lua/zsh.lua)."

# MUST READ #4 — the TEMPLATE driver to copy (Complete). bash.lua is fish.lua with a different DAEMON_SCRIPT.
- file: lua/pi-bridge/shell/fish.lua
  why: "the EXACT start(opts,on_ready) shape to mirror: the done()/fail()/resolved-flag closure discipline,
        the stderr-ready-signal read (read_start STDERR for __PIREADY__\\n), the startup-timer arm/cancel,
        the failure-path kill+close order (stderr read_stop→close, proc process_kill→close, stdin close,
        stdout close), the module-local last_stdin for cd(), the M.parse(raw) pure-Lua helper. bash.lua's Lua
        is ~95% identical to fish.lua (one process, one temp file, real cd — UNLIKE zsh's two scripts)."
  pattern: "DAEMON_SCRIPT long-string + os.tmpname() + uv.new_pipe×3 + uv.spawn + read_start(stderr, ready) + on_ready"
  gotcha: "fish used `fish -i --init-command=source <tmp>`. bash uses `bash <tmp>` (script as positional arg,
           NON-interactive — NO -i; research §7). ONE temp file (like fish; NOT two like zsh)."

# The most recent sibling driver (zsh, Complete) — bash is SIMPLER (no PTY/outer-inner split)
- file: lua/pi-bridge/shell/zsh.lua
  why: "the second concrete driver (P2.M3.T5.S1, Complete). bash.lua mirrors its [Mode A] header convention
        + the M.parse helper + the bogus-shell no-leak test pattern. DIFFERENCE: zsh needs an OUTER+INNER pty
        split + advisory cd; bash is plain pipes + REAL cd → structurally CLOSER to fish.lua than to zsh.lua.
        Use zsh.lua for header/parse/test SHAPE; use fish.lua for the spawn/cd BODY."
  pattern: "the [Mode A] header + M.parse + the after_each package.loaded['pi-bridge.shell.bash']=nil cleanup"
  gotcha: "zsh's cd is ADVISORY (documented no-op); bash's cd is REAL. Do NOT copy zsh's advisory-cd caveat."

# The validated fish/zsh spikes — your bash spike's structural template
- file: tests/shell_fish_spike.lua
  why: "P2.M1.T2.S1 (Complete) — the plenary-free standalone proof pattern. The bash spike (Task 1) copies its
        shape: uv.spawn → read_start(stdout) → write one __PIREQ__ → parse between sentinels → assert.
        DIFFERENCE: the bash spike asserts `/tmp` for `ls /tm` (works with no bash-completion) — a weaker
        environment requirement than fish/zsh's `git ch`→checkout (which needs compsys/bash-completion)."
  pattern: "standalone plenary-free smoke: gate on executable (optional for bash — universal), spawn, framed round-trip, teardown idiom"
  gotcha: "the fish spike read stdout ITSELF (one-shot). The DRIVER reads STDERR for ready + hands stdout to
           shell.lua; the spike reads stdout directly (it stands in for shell.lua). Mirror that split."

# The caller (completion routing — already Complete; do NOT modify, just understand the consumer)
- file: lua/pi-bridge/completion.lua
  why: "do_shell_fetch → shell.complete_current → shell.request → ensure → driver.start. The response cb runs in
        LIBUV FAST context — your driver must do NO vim.api.* in its callbacks (only luv + state writes); the
        menu hop is vim.schedule'd by the consumer. Already handled; don't ADD vim.api calls."
  pattern: "fast-context-safe driver callbacks (luv only); consumer schedules the UI"
  gotcha: "complete_current reads the buffer + strips bangs + computes byte offsets BEFORE calling shell.request —
           your driver never touches the buffer (same invariant as fish.lua/zsh.lua)."

# Acceptance (already Complete; bash path ALREADY supported)
- file: lua/pi-bridge/shell/accept.lua
  why: "M.quote(word, \"bash\") → POSIX single-quote with the '\"'\"'\"' idiom for embedded quotes (P2.M2.T4.S3,
        Complete). bash's quoting path is ALREADY implemented + tested. bash.lua does NOT touch the buffer."
  pattern: "basename(\"/bin/bash\")==\"bash\" → needs_quote_posix → single-quote; \\\" $ \\` are literal inside (free)"
  gotcha: "bash items are {value}-only (no description, Tier-2 §8); accept.lua only reads item.value — no description key needed."

# PRD source-of-truth
- url: in-repo PRD.md §17.6.3 (bash — Tier 2 best-effort), §17.5.1 (Framing protocol), §17.5.2 (daemon), §17.4 (prefer)
  why: "the design intent + the Tier-2 limitations + the 'files/dirs always work' floor. §17.5.1 defines the wire
        frame (__PIREQ__\\t{json}\\n / __PIRESP_START__\\n{single-object}\\n__PIRESP_END__\\n). §17.4.3's mismatch
        notice points bash users at zsh/fish when available."
  critical: "§17.6.3's sketch is INTENT, not authority: its COMP_CWORD loop is buggy (research §3) + it omits the
            cword==0 command-name branch (research §4) + it uses python3 for JSON escape (research §2's pure-bash
            escape replaces it). Treat research/bash_driver_findings.md as the authority; the PRD sketch as intent."

# Test fake pattern — the real bash.lua MUST match this exact interface
- file: tests/shell_complete_current_spec.lua
  why: "inject_fake_driver (L67) defines the contract the real bash.lua must satisfy: drv.start=function(opts,cb)
        cb(nil, {is_closing=...}, stdin, stdout). Your real start() must hand REAL luv handles of the same shape."
  pattern: "package.loaded['pi-bridge.shell.bash'] = {start=..., cd=...}; cb(err,proc,stdin,stdout)"
  gotcha: "existing specs set package.loaded['pi-bridge.shell.bash']=nil in cleanup (mirror fish/zsh specs). Your
           live-driver spec must do the SAME so a stale real module doesn't leak into shell.lua's unit tests."

# bash docs (the three mechanisms the daemon script depends on)
- url: https://www.gnu.org/software/bash/manual/html_node/Programmable-Completion-Builtins.html
  why: "compgen (-f files, -d dirs, -abck command classes, -A action, -- prefix) + complete (-F function, -p print
        the registration). The two builtins __pi_complete dispatches between."
  critical: "`complete -p cmd` prints the registration line (e.g. `complete -o default -F _git git`); parse the -F fn.
            If nothing prints (no compspec, exit 1) → the §5 compgen -f -d / compgen -abck fallback."
- url: https://www.gnu.org/software/bash/manual/html_node/Programmable-Completion.html
  why: "COMP_LINE (full line), COMP_POINT (cursor index, = ${#COMP_LINE} at end-of-line), COMP_WORDS (array),
        COMP_CWORD (index of the word at cursor), COMPREPLY (the result array the -F fn populates)."
  critical: "COMP_POINT semantics: the §3 truncated-prefix computation makes cur correct at ANY cursor position
            (mid-word, end-of-word, trailing-space). The PRD sketch's accumulation loop is wrong for trailing-space."
```

### Current Codebase tree (relevant slice)

```bash
lua/pi-bridge/
├── shell.lua              # COMPLETE (P2.M1.T2 + P2.M2.T3). The daemon manager + driver caller.
├── completion.lua         # COMPLETE. do_shell_fetch→complete_current→shell.request.
├── shell/accept.lua       # COMPLETE (P2.M2.T4.S3). M.quote(word, "bash") → POSIX single-quote (bash path ALREADY supported).
├── shell/fish.lua         # COMPLETE (P2.M2.T4.S1). THE TEMPLATE — copy its start()/cd()/parse() shape (plain pipes, one tmp, real cd).
├── shell/zsh.lua          # COMPLETE (P2.M3.T5.S1). 2nd driver; copy its [Mode A] header + parse + test SHAPE (NOT the pty/advisory-cd body).
└── (shell/bash.lua MISSING) # ← THIS TASK adds it (3rd driver under lua/pi-bridge/shell/).
tests/
├── shell_fish_spike.lua        # COMPLETE — the spike PATTERN to copy (structure, gating, teardown).
├── shell_zsh_spike.lua         # COMPLETE — the most recent spike (header/run convention + SENTINEL parse).
├── shell_fish_driver_spec.lua  # COMPLETE — the spec PATTERN (offline contract + LIVE gated case).
├── shell_zsh_driver_spec.lua   # COMPLETE — the most recent spec (after_each package.loaded cleanup + bogus-shell no-leak).
├── shell_ensure_spec.lua       # COMPLETE — uses FAKE drivers (the contract source).
└── minimal_init.lua            # plenary bootstrap for spec files.
```

### Desired Codebase tree with files to be added

```bash
lua/pi-bridge/shell/
└── bash.lua               # NEW (S2). Exports M.start(opts,on_ready), M.cd(path), M.parse(raw).
                           # Embeds the bash DAEMON_SCRIPT as a Lua long-string; writes it to a temp
                           # file at start(); spawns `bash <tmp>` (non-interactive); reads STDERR for ready.
tests/
├── shell_bash_spike.lua        # NEW (S2, Task 1, GATE). Plenary-FREE, LIVE (bash universal — no skip).
│                                # Standalone bash <script> round-trip: "ls /tm" → /tmp (works with no bash-completion).
├── shell_bash_driver_smoke.lua  # NEW (S2, Task 4). Plenary-FREE, LIVE. Spawns the real driver, sends 3
│                                # sequential requests (persistence) + tests REAL cd (cwd changes).
└── shell_bash_driver_spec.lua   # NEW (S2, Task 5). Plenary. Offline contract cases (start/cd/parse signature,
                                # never-throws, on_ready arity, bogus-shell no-leak, parse()) + LIVE cases (ls /tm→/tmp, gi→git).
```

### Known Gotchas of our codebase & Library Quirks

```bash
# CRITICAL (architecture, research §1): bash is a PLAIN-PIPES driver — like fish, UNLIKE zsh. bash's `compgen`
#   + `complete -F fn` dispatch are ordinary builtins callable NON-interactively over plain stdin/stdout pipes.
#   NO TTY, NO PTY, NO outer/inner split. → bash.lua ≈ fish.lua (one process, one temp file, stderr-ready-
#   signal, REAL cd). The ONLY difference from fish is the spawn args + the DAEMON_SCRIPT contents.

# CRITICAL (research §3 — THE FIX): the PRD §17.6.3 COMP_CWORD accumulation loop is BUGGY for trailing-space
#   inputs. `read -ra COMP_WORDS <<< "$line"` STRIPS trailing whitespace, so `ls ` collapses to ("ls") and
#   cword=0 → completing `ls` AGAIN instead of the argument. THE FIX (LIVE-VALIDATED, research §3b):
#       prefix="${line:0:point}"; trailing_ws=0; [[ "$prefix" =~ [[:space:]]$ ]] && trailing_ws=1
#       read -ra COMP_WORDS <<< "$prefix"; (( ${#COMP_WORDS[@]}==0 )) && COMP_WORDS+=("")  # empty-line guard
#       (( trailing_ws )) && COMP_WORDS+=("")          # cursor in trailing ws → new empty word → cur=""
#       COMP_CWORD=$(( ${#COMP_WORDS[@]} - 1 ))
#   Use this VERBATIM. The PRD sketch's `cum += len+1; cum>=point` loop is WRONG — do not copy it.

# CRITICAL (research §2 — NO python3): the PRD §17.6.3 sketch JSON-escapes via `python3 -c '...'`. python3 is
#   NOT guaranteed on the user's box. Use the PURE-BASH parameter-substitution escape (mirrors zsh.lua's
#   OUTER_SCRIPT __pi_json_str; bash + zsh share the ${var//from/to} syntax):
#       __pi_json_str() { local s="$1"; s="${s//\\/\\\\}"; s="${s//\"/\\\"}";
#                          s="${s//$'\n'/\\n}"; s="${s//$'\r'/\\r}"; s="${s//$'\t'/\\t}"; printf '"%s"' "$s"; }
#   Backslash FIRST. LIVE-VALIDATED for space/quote/slash/tab/$/backtick.

# CRITICAL (response shape — shell.lua _feed contract, inherited from fish.lua): the daemon MUST emit ONE
#   single-object JSON between sentinels, NOT per-line NDJSON:
#       __PIRESP_START__\n{"items":[{"value":"/tmp"}],"prefix":""}\n__PIRESP_END__\n
#   shell.lua _feed does pcall(vim.json.decode, payload) on the WHOLE body; NDJSON → decode throws →
#   parse_failures++ (§17.12 threshold=5 → daemon disabled). Mirror fish.lua's single-object build.

# CRITICAL (luv): you CANNOT read_start the SAME pipe twice. shell.lua wires stdout:read_start AFTER
#   on_ready (shell.lua L422). So the driver must NOT read_start stdout. Emit __PIREADY__\n to STDERR
#   and read_start the STDERR pipe in start() — stdout stays pristine for shell.lua. (identical to fish.lua)

# GOTCHA (research §4 — command-name completion): when COMP_CWORD==0 (completing the FIRST word / command name),
#   `complete -p "$cmd"` returns nothing (partial command names have no compspec). The correct branch is
#   `compgen -abck -A function -- "$cur"` (aliases/builtins/commands/keywords/functions). WITHOUT this branch
#   the PRD sketch would fall through to `compgen -f -d` (files) for a command name — wrong. LIVE-VALIDATED.

# GOTCHA (research §5 — no bash-completion → degrade): bash-completion is OPTIONAL. On this box it is NOT
#   installed → `complete -p git`/`ls` return nothing. The daemon MUST fall back to `compgen -f -d -- "$cur"`
#   (files+dirs — ALWAYS works) for cword>0 when no compspec exists. This is the §17.6.3 "files/dirs always
#   work" floor + the Tier-2 contract. Source bash-completion best-effort but NEVER depend on it.

# GOTCHA (research §7 — spawn form): use `bash <daemon_tmp>` (script as positional arg, NON-interactive).
#   Do NOT use `bash --rcfile X -i`: --rcfile only applies to interactive shells (forcing -i), and -i runs a
#   line editor on the piped stdin (noise + interference). `bash <script>` does NOT source ~/.bashrc
#   (non-interactive) — CONSISTENT with prefer:"pi" (pi's /bin/bash -c doesn't either). Source bash-completion
#   EXPLICITLY in the script (the 4 canonical paths, [ -r ]-guarded).

# GOTCHA (research §6 — REAL cd): bash's cd(path) is REAL (not advisory like zsh v1). The daemon is a plain
#   script loop; nothing constrains `builtin cd`. The __PICD__ branch does `builtin cd "$path"` and subsequent
#   completions use the new cwd. Mirror fish.lua's cd() verbatim. The smoke asserts cwd CHANGES (unlike zsh's
#   "no-throw" assert).

# GOTCHA (research §8 — NO descriptions): compgen/COMPREPLY are bare words (bash's completion protocol has no
#   description channel). bash items are {value}-only (no description key). Tier-2 quality; surfaced in
#   :checkhealth (P2.M3.T6.S2) + the §17.4.3 mismatch notice recommends zsh/fish when richer completion exists.

# GOTCHA (luv): process_kill("sigkill") does NOT close the uv_process_t (is_closing stays false even after
#   on_exit). proc:close() is REQUIRED or the handle LEAKS (shell.lua F3 comment). Every PRE-on_ready failure
#   path must proc:close() after process_kill. Close order: stderr read_stop→close, proc process_kill→close,
#   stdin close, stdout close (mirror shell.lua close_handles L705 + fish.lua fail()). os.remove the temp file.

# GOTCHA (research §9 — .line/.cursor extraction): pure-bash parameter substitution extracts .line + .cursor
#   (crude; mirrors fish/zsh). KNOWN LIMITATION: a command line with a literal " breaks extraction → line=""
#   → compgen -abck returns all commands (graceful degrade, not a crash). v1 accepts this (all 3 sibling drivers
#   share it). A true JSON parse needs jq/python3 — out of scope.

# GOTCHA (research §10 — fragility + subshell wrap): wrap the per-request completion dispatch in a SUBSHELL
#   `( ... ) 2>/dev/null` so a buggy compspec function cannot abort the request loop. trap '' PIPE so a closed
#   stdout doesn't SIGPIPE-kill the daemon. The daemon MUST emit __PIRESP_END__ even on error/empty (so shell.lua
#   _feed never hangs → the §17.12 parse-failure-disable doesn't fire from a bash quirk).

# GOTCHA (test isolation): existing shell_*_spec/smoke files set package.loaded["pi-bridge.shell.<basename>"]=nil
#   in cleanup. Your new bash spec/smoke MUST do the same (for "bash") so the REAL module doesn't leak into those tests.
```

## Implementation Blueprint

### Data models and structure

No persistent data models. The driver is a stateless-ish module with a small per-spawn
closure (the temp-file path, the stderr-ready buffer, the startup timer, the proc/pipes) —
structurally identical to fish.lua. The DAEMON SCRIPT's wire types (fixed by shell.lua
`_feed` / PRD §17.5.1):

```jsonc
// Request (shell.lua writes this to bash's stdin):
"__PIREQ__\t{\"line\":\"ls /tm\",\"cursor\":6,\"after\":\"\"}\n"
// Response (bash emits this on its stdout, shell.lua _feed decodes). NOTE: bash items are
// {value}-ONLY (no description — Tier-2, research §8). prefix is advisory (overridden client-side):
"__PIRESP_START__\n{\"items\":[{\"value\":\"/tmp\"}],\"prefix\":\"\"}\n__PIRESP_END__\n"
// Readiness (bash emits this on its STDERR once, after best-effort bash-completion sourcing):
"__PIREADY__\n"
// cd (REAL for bash — research §6):
"__PICD__\t/some/path\n"
```

### The bash daemon script (the embedded long-string — DRAFT, validate verbatim in the SPIKE)

```bash
# === pi-bridge bash completion daemon — Tier 2 best-effort (PRD §17.6.3 / §17.5.1) ===
# Spawned by Lua as: `bash <this-file>`. NON-interactive script mode (NO -i; research §7).
# Best-effort sources bash-completion (system compspecs); NEVER depends on it (research §5).
# Reads framed __PIREQ__ lines from stdin; emits ONE single-object JSON between sentinels.
# Emits __PIREADY__ to stderr once at startup. REAL __PICD__ cd (research §6).

trap '' PIPE                    # a closed stdout must not SIGPIPE-kill us (research §10)

# (0) Best-effort source bash-completion (the system _git/_ls compspecs). Each path [ -r ]-guarded;
#     if NONE exist (no bash-completion, e.g. this box) → no compspecs register → §5 fallback governs.
for _bc in /usr/share/bash-completion/bash_completion \
           /usr/local/share/bash-completion/bash_completion \
           /etc/bash_completion /usr/local/etc/bash_completion ; do
    [ -r "$_bc" ] && { . "$_bc" || true; break; }
done
unset _bc

# Pure-bash JSON string escape (python3-free; mirrors zsh.lua OUTER_SCRIPT; research §2).
# Escapes \, ", \n, \r, \t (backslash FIRST). Outputs the double-quoted JSON string.
__pi_json_str() {
    local s="$1"
    s="${s//\\/\\\\}"; s="${s//\"/\\\"}"; s="${s//$'\n'/\\n}"; s="${s//$'\r'/\\r}"; s="${s//$'\t'/\\t}"
    printf '"%s"' "$s"
}

# The COMP_* + compgen/complete -F dispatch (research §3/§4/§5). Sets COMP_LINE/COMP_POINT/COMP_WORDS/
# COMP_CWORD via the LIVE-VALIDATED trailing-whitespace-aware computation (NOT the PRD sketch's buggy loop),
# then dispatches: compspec -F fn → call it; cword==0 → compgen -abck (command names); else compgen -f -d.
__pi_complete() {
    local line="$1" point="$2"
    COMP_LINE="$line"; COMP_POINT="$point"
    # THE §3 FIX: truncate at point, detect trailing whitespace, append empty word so cur="" for `ls `.
    local prefix="${line:0:point}"
    local trailing_ws=0
    [[ "$prefix" =~ [[:space:]]$ ]] && trailing_ws=1
    COMP_WORDS=()
    read -ra COMP_WORDS <<< "$prefix"
    (( ${#COMP_WORDS[@]} == 0 )) && COMP_WORDS+=("")        # empty line → one empty word (guards cword=-1)
    (( trailing_ws )) && COMP_WORDS+=("")                   # cursor in trailing ws → new empty word
    COMP_CWORD=$(( ${#COMP_WORDS[@]} - 1 ))
    local cur="${COMP_WORDS[COMP_CWORD]}"
    local cmd="${COMP_WORDS[0]}"
    COMPREPLY=()
    if (( COMP_CWORD == 0 )); then
        # completing the COMMAND name itself (research §4): commands/aliases/builtins/keywords/functions.
        COMPREPLY=( $(compgen -abck -A function -- "$cur" 2>/dev/null) )
    else
        # cword>0: look for the command's registered compspec (research §5). `complete -p` prints the
        # registration line; parse the -F function. If found, call it (it populates COMPREPLY).
        local spec
        spec=$(complete -p "$cmd" 2>/dev/null) || spec=""
        if [[ "$spec" == *-F\ * ]]; then
            local fn; fn=$(printf '%s' "$spec" | sed -n 's/.*-F[[:space:]]\{1,\}\([^[:space:]]*\).*/\1/p')
            if [ -n "$fn" ] && type "$fn" >/dev/null 2>&1; then
                "$fn" "$cmd" "$cur" "${COMP_WORDS[COMP_CWORD-1]}" 2>/dev/null || true
            fi
        fi
        # if the -F fn produced nothing (or no compspec existed) → files+dirs fallback (ALWAYS works).
        if [ ${#COMPREPLY[@]} -eq 0 ]; then
            COMPREPLY=( $(compgen -f -d -- "$cur" 2>/dev/null) )
        fi
    fi
}

# Handle ONE __PIREQ__ line (argv[1]). Extracts .line/.cursor, dispatches, builds single-object JSON.
__pi_handle() {
    local line_in="$1"
    case "$line_in" in
        (__PICD__*)
            local p="${line_in#__PICD__	}"      # strip "__PICD__\t" (literal tab)
            builtin cd "$p" 2>/dev/null           # REAL cd (research §6); silent on failure (advisory-ish)
            return
            ;;
        (__PIREQ__*)
            local payload="${line_in#__PIREQ__	}"   # strip "__PIREQ__\t" (literal tab)
            local line="${payload#*\"line\":\"}"; line="${line%%\"*}"   # crude .line (research §9)
            local cursor="${payload#*\"cursor\":}"; cursor="${cursor%%[!0-9]*}"
            cursor="${cursor:-0}"
            echo __PIRESP_START__
            (
                __pi_complete "$line" "$cursor"
                local _items="" _first=1 w
                for w in "${COMPREPLY[@]}"; do
                    [ -z "$w" ] && continue
                    local _it="{\"value\":$(__pi_json_str "$w")}"     # bash: {value} ONLY (no description, §8)
                    if ((_first)); then _items="$_it"; _first=0; else _items="${_items},${_it}"; fi
                done
                printf '{"items":[%s],"prefix":""}\n' "$_items"
            ) 2>/dev/null
            echo __PIRESP_END__
            ;;
    esac
}

# Announce readiness on STDERR (fd 2) — the Lua start() reads stderr for this marker (research §7).
printf '__PIREADY__\n' >&2

# Persistent request loop (the spike does ONE; production loops for the session).
while IFS= read -r req; do
    __pi_handle "$req"
done
```

> ⚠ The bash DAEMON_SCRIPT above is a **LIVE-VALIDATED draft** — every mechanic (JSON escape,
> COMP_CWORD fix, compgen dispatch, command-name branch, file/dir fallback, REAL cd) is proven
> against bash 5.3.15 in `research/bash_driver_findings.md`. The SPIKE (Task 1) MUST run this
> end-to-end and FIX any version-sensitive bit (the `complete -p` parsing across bash versions;
> `compgen -A function` availability). The SPIKE is the source of truth; adjust `bash.lua`'s
> `DAEMON_SCRIPT` to match the proven spike script verbatim.

### Implementation Tasks (ordered by dependencies)

```yaml
Task 1: CREATE tests/shell_bash_spike.lua — the GATE (validate the plain-pipe round-trip BEFORE the driver)
  - IMPLEMENT: a standalone plenary-free proof that the `bash <script>` round-trip yields /tmp for "ls /tm".
    Copy tests/shell_fish_spike.lua's structure + tests/shell_zsh_spike.lua's header/run convention.
  - STEPS:
    1. (GATE optional — bash is universal, but mirror the siblings for shape): if vim.fn.executable("bash")==0
       → print "SPIKE_SKIP: bash not on PATH" + return (exit 0). (Will essentially never trigger on Linux.)
    2. Write the DAEMON_SCRIPT above to /tmp (os.tmpname). Use the §3-fixed __pi_complete (NOT the PRD sketch).
    3. uv.spawn("bash", {args={daemon_path}, stdio={stdin,stdout,stderr}}, noop_on_exit).
    4. read_start STDOUT; send ONE __PIREQ__\t{"line":"ls /tm","cursor":6,"after":""}\n; parse between
       __PIRESP_START__/__PIRESP_END__ (vim.json.decode the body); assert items contain "/tmp".
    5. BONUS assert (the §3 fix): send __PIREQ__\t{"line":"ls ","cursor":3,...} → assert items are the cwd's
       files/dirs (NOT command-name completion of "ls") — proves the trailing-whitespace fix.
    6. teardown: process_kill + close all 3 handles (spike idiom). vim.wait with a hard timeout (AGENTS.md).
  - RUN: `timeout 60 nvim --headless --clean -u NORC -c 'set rtp+=.' +"luafile tests/shell_bash_spike.lua" +qa`
    (AGENTS.md HARD RULE: FILE run via :luafile — NEVER heredoc-to-nvim-stdin).
  - CRITICAL: this is the GATE. If /tmp doesn't appear, iterate on the DAEMON_SCRIPT (the §3 computation, the
    `complete -p` parse, the compgen flags). The PROVEN spike script becomes bash.lua's DAEMON_SCRIPT verbatim.
  - GOTCHA: the spike reads STDOUT directly (it stands in for shell.lua). The DRIVER will read STDERR for
    __PIREADY__ and hand stdout to shell.lua — the spike does NOT need the ready signal (it just writes the
    request + waits for the response, giving bash a moment to source). Mirror fish/zsh spike's read logic.

Task 2: CREATE lua/pi-bridge/shell/bash.lua — module skeleton + the DAEMON_SCRIPT long-string
  - IMPLEMENT: local M = {}; DAEMON_SCRIPT as a Lua [[ ]] long-string (copy the PROVEN spike script —
    Task 1's output — verbatim); return M at the bottom.
  - FOLLOW pattern: lua/pi-bridge/shell/fish.lua's structure (the [Mode A] header, module-local M, the
    DAEMON_SCRIPT constant, local uv = vim.uv, the module-local last_stdin).
  - NAMING: module-local `M`; the script helpers are __pi_-prefixed (avoids colliding with bash internals).
  - PLACEMENT: lua/pi-bridge/shell/bash.lua (the basename MUST be `bash` — shell.lua's pick_driver does
    require("pi-bridge.shell."..basename); basename("/usr/bin/bash")=="bash").
  - GOTCHA: do NOT require("pi-bridge") at module top (handshake async; lazy-require inside functions only
    if needed — bash.lua likely needs NO pi-bridge require; it only uses vim.uv, like fish.lua/zsh.lua).

Task 3: IMPLEMENT M.start(opts, on_ready) in bash.lua
  - SIGNATURE: M.start(opts, on_ready) where opts={shell,cwd,startup_timeout_ms}; on_ready is
    function(err, proc, stdin, stdout). COPY fish.lua's start() verbatim, changing ONLY:
      (a) spawn args: { daemon_tmp } (the script as a positional arg; NO -i; research §7).
      (b) write ONE temp file (like fish; NOT two like zsh); os.remove it on every terminal path.
  - STEPS (each pcall'd / never-throws — copy fish.lua's done()/fail()/resolved-flag discipline):
    1. guard on_ready type (if not function, noop).
    2. write DAEMON_SCRIPT to one temp file. pcall; on fail → on_ready("script write failed",...).
    3. create 3 pipes: stdin/stdout/stderr = uv.new_pipe(false).
    4. uv.spawn(opts.shell or "bash", {args={daemon_tmp}, stdio={stdin,stdout,stderr},
       cwd=(opts.cwd or nil)}, on_exit). pcall; on spawn_err → fail(path) → on_ready(err,nil,nil,nil).
    5. arm startup timer: uv.new_timer(); :start(opts.startup_timeout_ms or 5000, 0, timeout_cb) → fail.
       (bash cold-start is FAST vs zsh — only the best-effort bash-completion sourcing; 5000ms is ample.)
    6. read_start STDERR for __PIREADY__: accumulate into ready_buf; if ready_buf:find("__PIREADY__\n",1,true)
       then stderr:read_stop() + timer:stop()+close() + os.remove(the temp) + cache last_stdin +
       on_ready(nil, proc, stdin, stdout). EOF on stderr before ready → startup-failure path (bash crashed
       during sourcing → on_exit → fail).
  - CRITICAL: hand stdout to on_ready UNTOUCHED (no read_start on stdout — shell.lua owns it).
  - CRITICAL: the on_exit cb — if on_ready already called (success), noop (shell.lua's stdout EOF → _reset
    handles it); if NOT yet called, treat as startup failure. Track with local `resolved=false` closed over
    by on_exit + the ready cb + the timer cb (copy fish.lua exactly).
  - GOTCHA: proc:close() REQUIRED after process_kill (F3 leak). Failure-path close order: stderr read_stop→close,
    proc process_kill→close, stdin close, stdout close (mirror fish.lua fail()). os.remove the temp file.

Task 4: IMPLEMENT M.cd(path) in bash.lua
  - SIGNATURE: M.cd(path) — REAL re-cd over the framed channel. COPY fish.lua's cd() verbatim.
  - bash semantics (research §6): REAL. The daemon's __PICD__ branch does `builtin cd "$path"`; subsequent
    path completions are relative to the new cwd. (This is a quality ADVANTAGE over zsh v1's advisory cd.)
  - GOTCHA: cd writes via last_stdin (cached by start(); ONE daemon/session). pcall + is_closing-guard
    every use. A dead/closing pipe → silent noop (cd is best-effort; never an error).

Task 5: IMPLEMENT M.parse(raw) in bash.lua
  - SIGNATURE: M.parse(raw) → { value:string }[] (bare words; NO description key — Tier-2, research §8).
  - COPY fish.lua's/zsh.lua's parse() shape: split raw on [^\r\n]+; each line → {value=line} (no tab-split —
    bash/compgen emits bare words; a line IS a value). Drop empty lines. Pure Lua + never-throws + dependency-free
    (no vim.*/require) → fixture-testable offline (§17.15). NOT called by shell.lua _feed (the daemon pre-builds
    single-object JSON; M.parse is the testable reference of the same spec).

Task 6: CREATE tests/shell_bash_driver_smoke.lua (plenary-FREE, LIVE — bash universal, no skip)
  - IMPLEMENT: standalone smoke (mirror tests/shell_fish_driver_smoke.lua structure).
  - STEPS:
    1. (optional gate): if vim.fn.executable("bash")==0 → print "SMOKE_SKIP" + return. (Never triggers on Linux.)
    2. require("pi-bridge.shell.bash").start({shell="bash",cwd=vim.fn.getcwd(),startup_timeout_ms=5000}, cb).
    3. cb(nil,proc,stdin,stdout): wire stdout:read_start into a sentinel parser (find
       __PIRESP_START__\n..__PIRESP_END__\n, vim.json.decode the body — copy the fish smoke's parser).
    4. send 3 SEQUENTIAL __PIREQ__ frames (ls /tm, gi, ls ) — each after the prior resolves (persistence proof).
       Assert: "ls /tm"→/tmp; "gi"→git (command-name completion); "ls "→cwd entries (the §3 fix).
    5. test REAL cd: write __PICD__\t<vimpld> then a "ls " request — assert the entries CHANGED (cwd moved;
       unlike zsh v1's "no-throw" assert, bash's cd is real — assert the cwd actually changed).
    6. teardown: process_kill + close all handles. Set package.loaded["pi-bridge.shell.bash"]=nil.
  - RUN: `timeout 60 nvim --headless --clean -u NORC -c 'set rtp+=.' +"luafile tests/shell_bash_driver_smoke.lua" +qa`
  - GOTCHA: the driver reads STDERR for __PIREADY__ itself (Task 3 step 6); the smoke must NOT also read stderr.

Task 7: CREATE tests/shell_bash_driver_spec.lua (plenary, offline + LIVE — bash universal)
  - IMPLEMENT: plenary/busted spec (mirror tests/shell_zsh_driver_spec.lua structure + the
    after_each package.loaded["pi-bridge.shell.bash"]=nil cleanup).
  - CASES:
    1. offline: M.start, M.cd, M.parse are functions; require loads without error.
    2. offline: M.start({}, cb) with a non-function cb does NOT throw (never-throws contract).
    3. offline: M.start({shell="/nonexistent/bash"}, cb) → cb(err, nil,nil,nil); no leaked handles
       (uv.walk handle-count before/after assert, mirror shell_zsh_driver_spec.lua).
    4. offline: M.parse parses bare-word lines into {value} (no description); never throws + {} on bad input.
    5. LIVE (unconditional — bash universal): M.start real spawn → cb(nil,proc,stdin,stdout) within timeout;
       send "ls /tm" → decoded items contain "/tmp"; send "gi" → contain "git"; send "ls " → cwd entries (§3 fix).
       Set package.loaded[...]=nil in after_each.
  - RUN: `timeout 90 nvim --headless --clean -u tests/minimal_init.lua -c 'lua require("plenary.busted").run("tests/shell_bash_driver_spec.lua")'`
  - GOTCHA: the LIVE case must vim.wait for on_ready (async — the ready marker arrives on stderr). bash cold-start
    is fast (only bash-completion sourcing); a modest timeout (e.g. 3000ms) is ample.

Task 8: (NO shell.lua / completion.lua / extension changes)
  - VERIFY: shell.lua's pick_driver already does require("pi-bridge.shell.bash") + validates .start.
    completion.lua's do_shell_fetch already calls shell.complete_current → shell.request → ensure →
    driver.start. shell/accept.lua's M.quote(word,"bash") already returns the POSIX single-quote form
    (P2.M2.T4.S3). The bridge descriptor's `shell` field (P2.M1.T1) already feeds resolve_shell →
    pick_driver selects bash when the resolved shell basename is "bash" (the prefer:"pi" DEFAULT).
    So S2 is PURELY additive: one new module + spike + smoke + spec. Do NOT edit any existing file.
    (S1/zsh already proved this additive-only invariant.)
```

### Implementation Patterns & Key Details

```lua
-- PATTERN: bash.lua's start() is fish.lua's start() with different spawn args. Copy the
--   done()/fail()/resolved-flag closure discipline VERBATIM from fish.lua. The only edits are:
--   (a) spawn args { daemon_tmp } (one positional arg, no -i); (b) write + remove ONE temp file;
--   (c) the DAEMON_SCRIPT constant. The read_start(STDERR, __PIREADY__) + handoff-stdout-pristine
--   + failure-close-order are IDENTICAL. bash.lua is structurally CLOSER to fish.lua than to zsh.lua
--   (plain pipes, one temp, real cd — NOT a pty/outer-inner split + advisory cd).

-- PATTERN: the DAEMON_SCRIPT is a Lua [[ ]] long-string so NONE of its \n/\t/\\ are interpreted by Lua —
--   they are LITERAL bash source (fish.lua/zsh.lua do the same). The bash script's OWN escapes
--   (e.g. ${s//\\/\\\\}) are bash parameter substitutions.

-- CRITICAL: the response MUST be ONE single-object JSON (shell.lua _feed constraint). The daemon
--   builds it via __pi_json_str (mirror fish.lua/zsh.lua). Do NOT emit per-line NDJSON. bash items are
--   {value}-ONLY (no description key — Tier-2, research §8).

-- CRITICAL: the __pi_complete COMP_* computation uses the §3 truncated-prefix + trailing-whitespace fix
--   (NOT the PRD §17.6.3 accumulation loop, which is buggy for `ls `). LIVE-VALIDATED — copy verbatim.

-- CRITICAL: the cword==0 branch (compgen -abck for command-name completion) is REQUIRED (research §4);
--   omitting it makes first-word completion fall through to compgen -f -d (files) — wrong.

-- PATTERN: wrap the per-request dispatch in a SUBSHELL `( ... ) 2>/dev/null` + `trap '' PIPE` (research §10)
--   so a buggy compspec function / a closed stdout cannot abort the request loop. __PIRESP_END__ ALWAYS emits.
```

### Integration Points

```yaml
DRIVER SELECTION (no change — already works):
  - shell.lua M.pick_driver(basename) → require("pi-bridge.shell.bash") when basename=="bash".
    Selected automatically when the resolved execution shell is bash (the prefer:"pi" DEFAULT —
    bridge descriptor.shell / $SHELL / the shellPath setting → resolve_shell → pick_driver).

ACCEPTANCE (no change — already works):
  - lua/pi-bridge/shell/accept.lua M.quote(word, "bash") → POSIX single-quote with the
    '"'"'"' idiom for embedded quotes (P2.M2.T4.S3, Complete). bash's quoting path is ALREADY
    implemented + tested. bash.lua does NOT touch the buffer (accept.lua does).

CONFIG (forward contract — P2.M3.T6.S1, not this task):
  - setup({ shell = { drivers = { bash = true } } }) enables/disables; bash=true is the default.
    bash is OPT-OUT in the PRD (§17.6.3 "drivers.bash = false") — the only driver with an explicit
    opt-out (its fragility is highest). Do NOT add config parsing here.

TEARDOWN (no change):
  - ftplugin VimLeavePre/ExitPre → shell.teardown() (P2.M3.T6.S3) → close_handles() kills bash (SIGKILL).
    bash has no child (unlike zsh's inner pty) — a single kill is sufficient.

HEALTH (forward contract — P2.M3.T6.S2, not this task):
  - :checkhealth pi-bridge will report the resolved bash version + driver health + Tier-2 quality row
    (no descriptions) + last error. bash.lua need only exist + load; the health section reads shell.lua state.
```

## Validation Loop

### Level 1: Syntax & Style (Immediate Feedback)

```bash
# After creating bash.lua — selene + stylua (the repo's Lua lint/format; follow the existing
# lua/pi-bridge/*.lua style: tabs, double-quoted strings, the [Mode A] header comment convention).
# Run from the repo root:
selene lua/pi-bridge/shell/bash.lua
stylua --check lua/pi-bridge/shell/bash.lua
# Quick load check (AGENTS.md: one-liner via -c 'lua ...' is fine; NO heredoc-to-stdin):
timeout 30 nvim --headless --clean -u NORC -c 'set rtp+=.' -c 'lua local m=require("pi-bridge.shell.bash"); print(type(m.start), type(m.cd), type(m.parse))' -c 'qa'
# Expected: function function function printed, exit 0.
```

### Level 2: The SPIKE (the GATE — run BEFORE writing bash.lua, and again after)

```bash
# The standalone plain-pipe round-trip proof. MUST yield /tmp for "ls /tm".
# AGENTS.md: this is a FILE run via :luafile — NEVER heredoc-to-nvim-stdin.
timeout 60 nvim --headless --clean -u NORC -c 'set rtp+=.' +"luafile tests/shell_bash_spike.lua" +qa
echo "exit=$?"   # 0 = SPIKE_PASS (or SPIKE_SKIP if bash absent — essentially never on Linux);
                # 1 = GATE FAILED — iterate the DAEMON_SCRIPT (the §3 computation, complete -p parse, compgen flags)
# If SPIKE fails: the DAEMON_SCRIPT needs fixing. Fix in the spike FIRST, then port the proven script
# into bash.lua verbatim. (Risk is LOW vs zsh — plain pipes, no pty; the §3 computation is pre-validated.)
```

### Level 3: Unit / Component Tests (plenary + smoke)

```bash
# The plenary-FREE smoke (LIVE bash, persistence + REAL cd + the §3 fix):
timeout 60 nvim --headless --clean -u NORC -c 'set rtp+=.' +"luafile tests/shell_bash_driver_smoke.lua" +qa
# The plenary spec (offline contract + LIVE cases — runs UNCONDITIONALLY; bash universal):
timeout 90 nvim --headless --clean -u tests/minimal_init.lua -c 'lua require("plenary.busted").run("tests/shell_bash_driver_spec.lua")'
# Regression: ensure the new module doesn't break shell.lua's OWN (fake-driver) tests:
timeout 90 nvim --headless --clean -u tests/minimal_init.lua -c 'lua require("plenary.busted").run("tests/shell_ensure_spec.lua")'
# Expected: all green. bash 5.3.15 IS present in this env → the LIVE cases run (not skipped).
```

### Level 4: Integration (the daemon manager + completion routing end-to-end)

```bash
# The REAL end-to-end: shell.lua ensure/request/_feed driving the REAL bash.lua driver.
# Reuses the existing shell.lua pipeline — no new harness. Write a tiny driver-level integration
# smoke that calls shell.lua directly (like the fish/zsh driver's integration smoke). Example outline:
cat > /tmp/bash_e2e.lua <<'LUA'           # heredoc to a FILE is fine (AGENTS.md); to nvim stdin is NOT
local shell = require("pi-bridge.shell")
shell.reset()
local got = nil
-- force the bash path (resolve_shell("bash") → /bin/bash; or hardcode via pick_driver)
shell.request("ls /tm", 6, "", function(err, items, prefix)
  got = { err=err, n=(items and #items or 0) }
  if items then
    for _, it in ipairs(items) do
      if it.value == "/tmp" then got.found = true end
    end
  end
end)
vim.wait(5000, function() return got ~= nil end, 20)
local msg = got.err and ("E2E_ERR="..got.err) or ("E2E_"..(got.found and "PASS:/tmp found" or "MISS").." items="..got.n)
io.stdout:write(msg.."\n")
shell.teardown()
LUA
timeout 60 nvim --headless --clean -u NORC -c 'set rtp+=.' +"luafile /tmp/bash_e2e.lua" +qa
echo "exit=$?"
# Expected: E2E_PASS:/tmp found. (Proves bash.lua integrates with the ALREADY-LANDED shell.lua.)
```

### Level 5: Creative & Domain-Specific Validation

```bash
# Persistence + REAL cd (the two things the spike did NOT fully prove):
#   the smoke (Task 6) sends 3 sequential requests through ONE spawned daemon — if the daemon died
#   after request 1, requests 2-3 would hang/timeout. Persistence = 3 sequential decodes.
#   cd: write __PICD__\t<other_dir> then a "ls " request — assert the entries CHANGED (bash cd is REAL,
#   unlike zsh v1's advisory no-op — assert the cwd actually moved, not just "no throw").
#
# The §3 fix (the highest-value assertion): "ls " (point=3, trailing space) → cur="" → cwd file/dir
#   completion (NOT command-name completion of "ls"). Assert the response contains a cwd file/dir,
#   NOT `ls`/`lsof`/etc. This is the regression guard for the LIVE-VALIDATED COMP_CWORD fix.
#
# No-bash-completion degrade (this box): bash-completion is NOT installed here → `complete -p git`
# returns nothing → "git ad" falls back to compgen -f -d (files/dirs). Assert NO crash + a valid
# (possibly-empty or file) result — the §5 "files/dirs always work" floor holds.
#   On a box WITH bash-completion: "git ad" → "add" (the _git compspec fires). CI runners with
#   bash-completion installed get this for free; the degrade path is proven locally (this box).
#
# Subshell isolation: define a throwaway compspec that always fails (complete -F _broken cmd; _broken()
#   { return 1; }) and request "cmd x" → assert __PIRESP_END__ still emits + no daemon crash (research §10).
```

## Final Validation Checklist

### Technical Validation

- [ ] `tests/shell_bash_spike.lua` passes (SPIKE_PASS: /tmp for "ls /tm") — the GATE.
- [ ] All Level 1-4 validations completed successfully.
- [ ] `require("pi-bridge.shell.bash")` loads; `M.start`/`M.cd`/`M.parse` are functions (Level 1 one-liner).
- [ ] selene + stylua clean on `lua/pi-bridge/shell/bash.lua`.
- [ ] shell.lua's fake-driver tests still green (no leak via package.loaded).

### Feature Validation

- [ ] `M.start` calls `on_ready(nil, proc, stdin, stdout)` with live handles within startup_timeout_ms.
- [ ] End-to-end: "ls /tm" → /tmp in decoded items (LIVE bash; runs unconditionally).
- [ ] Command-name completion: "gi" → "git" (the §4 cword==0 branch).
- [ ] §3 fix: "ls " → cur="" → cwd file/dir completion (NOT command completion of "ls").
- [ ] Persistence: ≥3 sequential requests through ONE daemon decode successfully.
- [ ] REAL cd: `__PICD__\t<dir>` then a request → cwd entries CHANGE (assert the move, not just "no throw").
- [ ] Spawn error / binary-missing / startup-timeout → on_ready(err,nil,nil,nil), no leaked handles,
      never throws (the §17.12 degrade path then disables the daemon gracefully).
- [ ] No-bash-completion degrade: works (this box) — files/dirs always complete; no crash.

### Code Quality Validation

- [ ] Follows fish.lua's structure/conventions (the [Mode A] header, module-local M + uv + last_stdin,
      the done()/fail()/resolved-flag closure discipline, the failure-close order).
- [ ] File placement: lua/pi-bridge/shell/bash.lua (basename "bash" for pick_driver).
- [ ] The DAEMON_SCRIPT uses the §3 COMP_CWORD fix (NOT the PRD §17.6.3 buggy accumulation loop).
- [ ] The DAEMON_SCRIPT uses the §2 pure-bash JSON escape (NO python3 dependency).
- [ ] bash items are {value}-only (no description key — Tier-2 documented limitation).
- [ ] Per-request dispatch wrapped in a subshell + `trap '' PIPE` (research §10 fragility guard).

### Documentation & Deployment

- [ ] The [Mode A] header documents: plain-pipes (≈ fish), REAL cd, the §3 fix, the python3-free escape,
      the no-descriptions Tier-2 limitation, the no-~/.bashrc-by-design stance.
- [ ] No new environment variables (bash-completion paths are hardcoded in the DAEMON_SCRIPT, [ -r ]-guarded).
- [ ] Forward-docs (P2.M3.T6.S4 doc/pi-bridge-shell.txt) will cover the Tier-2 quality row + the §17.4.3
      mismatch notice (bash users pointed at zsh/fish when available); bash.lua need only exist + load.

---

## Anti-Patterns to Avoid

- ❌ Don't use the PRD §17.6.3 `COMP_CWORD` accumulation loop — it's BUGGY for trailing-space (`ls `).
      Use the §3 truncated-prefix + trailing-whitespace detection (LIVE-VALIDATED).
- ❌ Don't use `python3` (or `jq`) for JSON escaping — not guaranteed installed. Use the pure-bash
      parameter-substitution escape (§2).
- ❌ Don't use `bash -i` / `bash --rcfile X -i` — interactive mode runs a line editor on piped stdin
      (noise + interference). Use `bash <script>` (non-interactive; research §7).
- ❌ Don't source `~/.bashrc` — inconsistent with `prefer:"pi"` (pi's `/bin/bash -c` doesn't either);
      completing a .bashrc-only alias would suggest a command that FAILS at execution. Source bash-completion
      (system definitions) best-effort ONLY.
- ❌ Don't treat bash's cd as advisory (that's zsh v1's limitation, not bash's). bash's cd is REAL —
      assert the cwd changes in the smoke.
- ❌ Don't emit per-line NDJSON — shell.lua `_feed` decodes ONE object between sentinels (NDJSON → throw
      → parse_failures → daemon disabled). Build ONE single-object JSON.
- ❌ Don't read_start stdout in the driver — shell.lua owns it post-on_ready. Emit `__PIREADY__` to STDERR.
- ❌ Don't leak the uv_process_t — `process_kill` does NOT close it; `proc:close()` is REQUIRED (F3 leak).
- ❌ Don't let a buggy compspec function abort the request loop — wrap the dispatch in a subshell + `trap '' PIPE`.
- ❌ Don't add descriptions to bash items — compgen/COMPREPLY are bare words (Tier-2 hard limitation).