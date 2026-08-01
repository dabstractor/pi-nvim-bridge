# PRP — P2.M3.T1.S2: `bash.lua` best-effort driver (COMP_* vars, compgen/compspec, bash-completion sourcing)

**Parent:** P2.M3.T5 (shell/zsh.lua + shell/bash.lua + unknown-shell degrade) — *this item
maps to plan-tree node `P2.M3.T5.S2` ("bash.lua best-effort driver — COMP_* vars,
compgen/compspec, bash-completion sourcing", 1 pt); the orchestrator assigned the path `P2M3T1S2`.*
**Component:** B (`pi-bridge.nvim`) — new module `lua/pi-bridge/shell/bash.lua` + spike.
**PRD anchor:** §17.6.3 *bash — Tier 2 (best-effort)* (supported by §17.5, §17.12, §17.15).
**Size:** 1 pt — **the SIMPLEST of the three shell drivers** (no pty, no two-process
architecture, no startup sync). The rcfile is already LIVE-VERIFIED in
`research/notes.md`; this PRP is primarily the Lua-side `M.start`/`M.cd`/`close_handles`
shell around it.
**Sibling context:** `lua/pi-bridge/shell.lua` (the daemon manager, P2.M1.T2) is COMPLETE and
consumes this driver via `pick_driver` → `require("pi-bridge.shell.bash").start`. The zsh driver
(`shell/zsh.lua`, P2.M3.T1.S1) is being implemented IN PARALLEL and shares the same
`start(opts,cb)`/`cd(path)` contract; do NOT build the zsh driver here — build only `bash.lua`.
The fish driver (`shell/fish.lua`, P2.M2.T4) is PLANNED with the same contract.

---

## Goal

**Feature Goal:** Deliver the Tier-2 bash completion driver — a `lua/pi-bridge/shell/bash.lua`
module that `shell.lua`'s `pick_driver` loads for a resolved `/bin/bash`/`/usr/bin/bash` shell.
The driver spawns a **single** persistent `bash --rcfile <rcfile> -i` over `vim.uv.spawn` pipes,
sources bash-completion best-effort, and invokes the registered `-F` completion function for the
command word if present (else `compgen -f -d` for files+dirs), speaking the framed
`__PIREQ__`/`__PIRESP_{START,END}` protocol that `shell.lua`'s `_feed` already parses. A folded-in
**spike** (`tests/shell_bash_spike.lua`) validates the full round-trip against the installed bash
(5.3.15). Because bash completion works over plain pipes (unlike zsh's zle which needs a tty),
this driver needs NO pty and NO two-process architecture — it is structurally simpler than the
zsh driver.

**Deliverable:**
1. `lua/pi-bridge/shell/bash.lua` — exports `M.start(opts, on_ready)` (spawns `bash --rcfile
   <temp> -i` over `vim.uv.spawn` pipes, writes the LIVE-VERIFIED rcfile to a temp file, installs
   the startup-timeout guard, hands `(proc, stdin, stdout)` back to `shell.lua` on spawn-OK) and
   `M.cd(path)` (best-effort cwd sync via `cd "<path>"` frame). pcall'd, never-throws.
2. `tests/shell_bash_spike.lua` — standalone (plenary-FREE) end-to-end proof: spawn bash, send
   `ls /tm`, assert `/tmp` present in the decoded JSON. **Gated on `vim.fn.executable("bash")`**
   (skip→exit 0 if absent; PRD §17.15). Asserts the file/dir path (MUST-PASS everywhere) + a
   git-compspec assertion **iff bash-completion is detected** (skip otherwise — see Context §3).
3. `[Mode A]` docstring on `bash.lua` explaining Tier-2 status, the bare-words limitation (no
   descriptions), the bash-completion dependency, and the opt-out via `drivers.bash = false`.

**Success Definition:**
- `tests/shell_bash_spike.lua` prints `SPIKE_PASS` (exit 0) on a bash-present box: spawns a real
  bash, completes `ls /tm`, and `/tmp` appears in the parsed JSON. The git-compspec assertion
  (checkout/cherry) runs **iff** bash-completion is installed; else it is skipped (NOT failed).
  (On a bash-less box: `SPIKE_SKIP`, exit 0.)
- `require("pi-bridge.shell.bash").start` is loadable + exposes `.start` (so
  `shell.pick_driver("/usr/bin/bash")` returns the module, not nil).
- The driver hands `(proc, stdin, stdout)` back to `shell.lua`'s `ensure()` cb on success and
  `(err)` on every failure (binary missing / spawn error / startup timeout), never throws.
- The response frame is a SINGLE JSON object `{"items":[...],"prefix":""}` (NOT per-line NDJSON —
  that fails `shell._feed`'s `vim.json.decode`; see Context §1).
- `M.cd(path)` writes `cd "<path>"` without throwing.

---

## User Persona

**Target User:** A pi user whose resolved execution shell is bash (`$SHELL=/bin/bash` or pi's
`shellPath=bash`, the most common default) and who types `!`/`!!` bash-mode lines in the Neovim
external editor.

**Use Case:** The user types `!ls /tm` and presses Tab; pi-bridge routes the `!` line to the shell
daemon (`completion.lua` §17.7 gate, P2.M2.T3) → `shell.request` → this driver → the menu shows
`/tmp` (and any other `/tm*` entries), just like bash Tab-completion would.

**Pain Points Addressed:** Without this driver a bash user gets no `!`-line completion (unknown-shell
degrade, §17.6.4). bash is the default shell on most Linux distros — supporting it (even at Tier 2,
bare words) covers the largest user base. File/dir completion always works; command-specific
completions (git, etc.) work iff bash-completion is installed.

---

## Why

- **Business value:** bash is the default shell on the overwhelming majority of Linux systems.
  Even at Tier 2 (bare words, no descriptions), this driver gives those users real
  file/directory completion and — where bash-completion is installed — command-specific
  completions (git subcommands, etc.).
- **Integration:** Pure additive — a new module consumed by the EXISTING `shell.lua` daemon manager
  (no changes to `shell.lua`). The zsh driver (P2.M3.T1.S1) and fish driver (P2.M2.T4) share the
  contract; this driver is their bash sibling. The drivers are independent modules — building one
  does not require the others.
- **Why it's Tier 2 (not Tier 1):** `compgen` returns **bare words, no descriptions** (documented,
  §17.6.3). A bare `bash -c` does NOT source the user's completion library; the driver must
  best-effort source bash-completion. Quality depends entirely on whether bash-completion is
  installed + the per-command spec is sourced. Files/dirs always work (via `compgen -f -d`).

---

## What

### User-visible behavior
Once `shell.lua` routes a `!` line here (via P2.M2.T3, PLANNED), the user gets bash-native
completions in the existing menu (bare words, no descriptions). **This task alone does not render
completions** — it provides the driver the later routing consumes. (The spike proves the driver
works in isolation.)

### Technical requirements
1. **Module:** `lua/pi-bridge/shell/bash.lua`, local `M = {}`, `local uv = vim.uv`, module-local
   `state = { proc, stdin, stdout, script_path, startup_timer }`.
2. **`M.start(opts, on_ready)`** where `opts = { shell, cwd, startup_timeout_ms }` (passed by
   `shell.lua` ensure) and `on_ready(err, proc, stdin, stdout)` is shell.lua's cb. The driver:
   (a) writes the LIVE-VERIFIED bash daemon rcfile (Context §3 / research/notes.md §3) to a temp
   file (`os.tmpname()`); (b) `uv.new_pipe(false)` × 3 (stdin/stdout/stderr); (c)
   `uv.spawn(opts.shell or "bash", { args = { "--rcfile", path, "-i" }, stdio = {stdin,stdout,stderr},
   cwd = opts.cwd }, on_exit)`; (d) on spawn success calls `on_ready(nil, handle, stdin, stdout)`
   (readiness = spawn-OK — bash blocks in its `while read` loop immediately; no sync sentinel
   needed); on failure `on_ready(err)`. pcall every uv call.
3. **`M.cd(path)`** writes `cd "<path>"\n` to `state.stdin` (the rcfile's read loop recognizes a
   `cd <path>` line and runs `cd` in the daemon's own shell → subsequent `compgen -f -d` resolves
   relative to the new cwd). pcall'd.
4. **Response format:** the rcfile emits
   `__PIRESP_START__\n{"items":[{"value":"..."}],"prefix":""}\n__PIRESP_END__\n` per request — a
   SINGLE JSON object (built via `jq -c`, available 1.8.2 on target), NOT per-line NDJSON (which
   fails `shell._feed`).
5. **Spike:** `tests/shell_bash_spike.lua` (plenary-FREE, mirrors `tests/shell_fish_spike.lua`)
   gated on `vim.fn.executable("bash")`.
6. **Docstring** `[Mode A]` header on `bash.lua`.

### Success Criteria
- [ ] Spike prints `SPIKE_PASS` (bash present) / `SPIKE_SKIP` (absent), exit 0 either way.
- [ ] `bash.lua` exports `.start` + `.cd`; `shell.pick_driver("/usr/bin/bash")` returns it.
- [ ] `M.start` calls `on_ready(nil, proc, stdin, stdout)` on success; `(err)` on failure.
- [ ] Response is a single `{"items":[...],"prefix":""}` object (NOT per-line NDJSON).
- [ ] `!ls /tm` → `/tmp` in the decoded JSON (spike, the §17.15 MUST-PASS path).
- [ ] Never throws (pcall'd uv); honors `opts.startup_timeout_ms`; handles binary-missing.

---

## All Needed Context

### Context Completeness Check
A reader who knows nothing of this repo can implement this from: this PRP + the LIVE-VERIFIED
research notes at `plan/002_d23d7473c16c/P2M3T1S2/research/notes.md` (read it FIRST — it has the
exact rcfile, the probe transcripts, and the §17.6.3 sketch correction) + the fish spike
(`tests/shell_fish_spike.lua`, the proven luv-side pattern) + `lua/pi-bridge/shell.lua` (the
consumer contract). No pi-internal knowledge beyond §17 is needed. The bash driver is SIMPLER
than the zsh driver (no pty, no sync) — if you can read the fish spike, you can build this.

### Documentation & References

```yaml
# MUST READ — the LIVE-VERIFIED research for THIS task (the rcfile + probe transcripts + the §17.6.3 correction)
- file: plan/002_d23d7473c16c/P2M3T1S2/research/notes.md
  why: the exact rcfile (copy verbatim into the Lua module-local string), the jq recipe, the
       COMP_CWORD computation trace, the 5 probe results (ls /tm, empty, git-fallthrough, cd), and
       the §17.6.3-sketch NDJSON correction (emit ONE JSON object, not per-line).
  critical: |
    The PRD §17.6.3 sketch emits per-line `printf '{"value":%s}\n'` (NDJSON). shell._feed decodes
    the WHOLE payload as ONE object via vim.json.decode → NDJSON THROWS → parse_failure → after 5
    the daemon is killed (§17.12). The rcfile MUST build ONE {"items":[...],"prefix":""} object
    via jq. The rcfile in research/notes.md §3 is LIVE-VERIFIED to produce exactly this shape.

# MUST READ — the consumer contract (COMPLETE; defines the driver's exact API)
- file: lua/pi-bridge/shell.lua
  why: ensure() calls `state.driver.start(opts, cb)` with opts={shell,cwd,startup_timeout_ms}
       and cb(err,proc,stdin,stdout). stdout is read_start'd into shell._feed. _feed decodes the
       payload as ONE JSON object (NDJSON/TSV throws → parse failure → daemon killed).
  pattern: the driver hands the luv handles back; shell.lua owns the read loop + framing parse.
  gotcha: |
    The driver does NOT parse responses in Lua + does NOT own the read loop. shell.lua stores
    ONLY proc/stdin/stdout (NOT stderr) — the driver OWNS stderr. To prevent the stderr pipe
    buffer (64KB) from filling + blocking the daemon over a long session, the rcfile MUST
    `exec 2>/dev/null` early (silences all post-rcfile stderr). Verified non-breaking.

# MUST READ — the proven luv-side spawn pattern (mirror it for bash)
- file: tests/shell_fish_spike.lua
  why: the EXACT uv.new_pipe×3 + uv.spawn + stdout:read_start + sentinel-parse + vim.wait(10000)
       + pcall-everything + is_closing teardown idiom the bash spike must copy. The ONLY
       difference is the shell binary/args (`bash --rcfile <temp> -i`) + the rcfile content.
  pattern: check()/fails()/SPIKE_PASS-or-SPIKE_SKIP footer; gated on vim.fn.executable.

# MUST READ — the zsh sibling PRP (P2M3T1S1) — for the shared contract + the close_handles idiom
- file: plan/002_d23d7473c16c/P2M3T1S1/PRP.md
  why: the zsh driver shares M.start(opts,on_ready)/M.cd(path)/close_handles/state structure.
       The bash driver is the SAME Lua skeleton with a SIMPLER rcfile + NO startup sync. Read the
       zsh PRP's "Implementation Patterns & Key Details" for the close_handles + M.start template
       (it is the canonical one; bash reuses it verbatim minus the zpty/timer-sync dance).
  critical: bash does NOT need the zpty two-zsh architecture, the __SETUP_OK__ sync sentinel, or
    the compinit cold-cache mitigations. Readiness = spawn-OK (hand handles back immediately).

# bash manual (citations)
- url: https://www.gnu.org/software/bash/manual/html_node/Programmable-Completion.html
  why: §8.7 — COMP_LINE/COMP_POINT/COMP_WORDS/COMP_CWORD semantics + the complete/compgen builtins.
  critical: compgen returns bare words (no descriptions) — this is the Tier-2 limitation (documented).
- url: https://www.gnu.org/software/bash/manual/html_node/Programmable-Completion-Builtins.html
  why: `complete -p` lists registered compspecs (exit 1 + "no completion specification" if none);
       `-F function` dispatches to a function that fills COMPREPLY.

# bash-completion project
- url: https://github.com/scop/bash-completion
  why: the canonical bash-completion library. The rcfile sources `/usr/local/etc/bash_completion`,
       `/etc/bash_completion`, `/usr/share/bash-completion/bash_completion` (best-effort, all 3 —
       locations vary by distro). Where installed, it registers `-F __git_main` (etc.) for common
       commands, giving real subcommand completion.

# PRD sections (read-only reference)
- url: PRD.md §17.6.3 "bash — Tier 2 (best-effort)"
  why: the intent + the sketch. The sketch's per-line JSON is a doc inconsistency the rcfile
       corrects (emit ONE object via jq — research/notes.md §1/§6).
- url: PRD.md §17.5.1 (framing) + §17.5.2 (daemon lifecycle) + §17.12 (failure modes) + §17.15 (tests)
  why: the wire format + the parse-failure→unhealthy→disable path + the test-gating contract
       ("git compspec iff bash-completion present, skip otherwise").
```

### Current codebase tree (relevant slice)

```bash
pi-nvim-bridge/
├── lua/pi-bridge/
│   ├── shell.lua              # COMPLETE (P2.M1.T2) — the consumer; DO NOT EDIT here
│   └── shell/                 # ← CREATE this dir (if absent); add bash.lua (this task)
│       └── zsh.lua            # ← sibling (P2.M3.T1.S1, in parallel); same contract — DO NOT EDIT
└── tests/
    ├── shell_fish_spike.lua   # the proven spike PATTERN to mirror (read-only)
    ├── shell_bash_spike.lua   # ← CREATE (the folded-in spike; ✔ gate)
    ├── minimal_init.lua       # plenary harness (read-only)
    └── shell_smoke.lua        # read-only (the shell.lua smoke)
```

### Desired codebase tree with files added

```bash
lua/pi-bridge/shell/bash.lua   # NEW — the bash best-effort driver (M.start + M.cd)
tests/shell_bash_spike.lua     # NEW — standalone spike (plenary-FREE); the ✔ gate
```

### Known Gotchas of our codebase & Library Quirks

```bash
# CRITICAL (RESPONSE FORMAT): shell._feed does `pcall(vim.json.decode, payload)` on the WHOLE
# payload between sentinels — it expects ONE {"items":[...],"prefix":""} object. The PRD §17.6.3
# sketch's per-line `printf '{"value":%s}\n'` is NDJSON → decode THROWS → parse_failure → after 5
# the daemon is killed (§17.12). The rcfile MUST build the single JSON object via jq. (LIVE-VERIFIED.)

# CRITICAL (STDERR PIPE DRAIN): shell.lua stores ONLY proc/stdin/stdout (NOT stderr) — the driver
# OWNS the stderr pipe. If bash writes >64KB to it over a long session, the daemon BLOCKS on the
# next stderr write. FIX: the rcfile does `exec 2>/dev/null` early → all post-rcfile stderr is
# silent → the pipe never fills. (The startup "no job control" warnings, ~100 bytes, are emitted
# BEFORE the rcfile runs and are harmless — never fill 64KB.) LIVE-VERIFIED non-breaking.

# GOTCHA (COMPREPLY DUPLICATES): `compgen -f -d -- "$cur"` lists a directory as BOTH a file (-f)
# and a dir (-d) → duplicate entries. FIX: pipe COMPREPLY through `sort -u` before jq. (LIVE-VERIFIED.)

# GOTCHA (bash-completion ABSENT on this target): /usr/local/etc/bash_completion, /etc/bash_completion,
# AND /usr/share/bash-completion/bash_completion are ALL MISSING here. So `complete -p git` exits 1
# ("no completion specification") → git has NO -F spec → __pi_complete falls through to compgen -f -d.
# This is the PRD §17.15 "git compspec iff bash-completion present (skip otherwise)" gating rationale.
# The spike's git assertion MUST be gated on bash-completion presence (detect via sourcing test),
# NOT hardcoded. File/dir completion (ls /tm → /tmp) is the MUST-PASS, always-works path.

# GOTCHA (PROMPT NOISE in -i mode): `bash --rcfile X -i` runs interactive mode, emitting the xterm
# title escape (\e]0;...\a) + a PS1 prompt to stdout on each "command" (our read loop). Sentinel
# framing in shell._feed ignores out-of-sentinel bytes, but to keep rx_buf clean the rcfile sets
# `PS1=''; PS2=''; PROMPT_COMMAND=`. (LIVE-VERIFIED: no noise leaks into the parsed payload.)

# GOTCHA (read -ra QUOTING): `read -ra COMP_WORDS <<< "${line}"` splits on whitespace WITHOUT
# honoring shell quoting (e.g. `my\ file.txt` → two words). This is the PRD sketch's behavior + an
# ACCEPTED Tier-2 limitation. File/dir completion of single-token words is the MUST-PASS path;
# quoting edge cases are table-tested in shell_accept_spec (P2.M2.T4) + accept.lua falls back to
# raw-insert on parse failure (§17.12). Do NOT try to replicate readline's tokenizer in bash.

# GOTCHA (jq dependency): the rcfile uses `jq -c -R -s` to build the JSON object. jq 1.8.2 is on
# this target AND is already a dependency of the zsh driver (P2M3T1S1). Document a pure-bash
# escaper fallback in the docstring for a future jq-less target, but do NOT implement it (YAGNI).

# LIBRARY QUIRK: AGENTS.md ⛔ HARD RULE — the Lua spike is a FILE run via +"luafile" +qa, NEVER a
# heredoc into nvim stdin (hangs). The rcfile is written to a temp file (os.tmpname()) + passed as
# --rcfile. Wrap every nvim invocation in `timeout` (e.g. timeout 60).
```

---

## Implementation Blueprint

### Data models and structure
No data model — the driver is a stateful module with module-local
`state = { proc, stdin, stdout, script_path, startup_timer }` (mirrors `bridge.lua`'s handle
ownership + the zsh driver's `state`). It hands the luv handles to `shell.lua` on success; it does
NOT own the read loop (shell.lua's `_feed` does). The only structured artifact is the response JSON
`{"items":[...],"prefix":""}`, built by the rcfile via jq (not Lua).

### The bash daemon rcfile (the heart of the driver — LIVE-VERIFIED; write to a temp file)

This is the EXACT script the driver writes to a temp file at `M.start` time. It is LIVE-VERIFIED
(research/notes.md §3 — all 5 probes pass). Copy it verbatim into a module-local Lua string
(`[[ ... ]]`); escape any `]]` (none present).

```bash
#!/usr/bin/env bash
# === bash daemon rcfile — sourced by `bash --rcfile <this> -i` (PRD §17.6.3) ===
exec 2>/dev/null   # silence all post-rcfile stderr (driver owns the stderr pipe; prevents buffer-fill block)

# Best-effort bash-completion sourcing (silent if absent — verified: this target has none).
[ -f /usr/local/etc/bash_completion ] && . /usr/local/etc/bash_completion 2>/dev/null
[ -f /etc/bash_completion ] && . /etc/bash_completion 2>/dev/null
[ -f /usr/share/bash-completion/bash_completion ] && . /usr/share/bash-completion/bash_completion 2>/dev/null

# Suppress interactive-mode prompt/title noise (sentinel framing in shell._feed already
# ignores out-of-sentinel bytes, but a clean stream reduces rx_buf churn).
PS1=''; PS2=''; PROMPT_COMMAND=

__pi_complete() {
  local line="$1" point="$2"                      # line=up-to-cursor, point=0-based byte offset
  COMP_LINE="$line"; COMP_POINT="$point"
  read -ra COMP_WORDS <<< "${line}"               # split like readline (whitespace; minimal quoting)
  local i cword=0 cum=0
  for ((i=0; i<${#COMP_WORDS[@]}; i++)); do
    cum=$((cum + ${#COMP_WORDS[i]} + 1))
    (( cum >= point )) && { cword=$i; break; }
  done
  COMP_CWORD=$cword
  local cur="${COMP_WORDS[cword]}"
  local cmd="${COMP_WORDS[0]}"
  COMPREPLY=()
  local spec=""
  spec=$(complete -p "$cmd" 2>/dev/null) || spec=""
  if [[ -n "$spec" && "$spec" == *-F* ]]; then
    local fn=""
    fn=$(printf '%s' "$spec" | sed -n 's/.*-F \([^ ]*\).*/\1/p')
    [ -n "$fn" ] && "$fn" "$cmd" "$cur" "${COMP_WORDS[cword-1]}" 2>/dev/null
  fi
  if [[ ${#COMPREPLY[@]} -eq 0 ]]; then
    COMPREPLY=( $(compgen -f -d -- "$cur" 2>/dev/null) )   # default: files+dirs (deduped below)
  fi
  # Build ONE JSON object via jq (shell._feed decodes the WHOLE payload — NDJSON throws).
  if [[ ${#COMPREPLY[@]} -eq 0 ]]; then
    printf '{"items":[],"prefix":""}\n'
  else
    local w
    for w in "${COMPREPLY[@]}"; do printf '%s\n' "$w"; done | sort -u | \
      jq -c -R -s 'split("\n") | map(select(length > 0)) | map({value: .}) | {items: ., prefix: ""}'
  fi
}

# Request loop: read __PIREQ__\t{json}\n from stdin. NON-__PIREQ__ `cd <path>` lines forward the
# daemon's cwd (M.cd contract). All other lines are ignored.
while IFS= read -r _req; do
  case "$_req" in
    __PIREQ__*) ;;
    cd\ *) cd "${_req#cd }" 2>/dev/null; continue ;;
    *) continue ;;
  esac
  _body="${_req#__PIREQ__$'\t'}"
  _line=$(printf '%s' "$_body" | jq -r '.line // ""' 2>/dev/null)
  _cursor=$(printf '%s' "$_body" | jq -r '.cursor // 0' 2>/dev/null)
  _cursor=${_cursor:-0}
  echo "__PIRESP_START__"
  __pi_complete "$_line" "$_cursor"
  echo "__PIRESP_END__"
done
```

> **Why `exec 2>/dev/null`:** shell.lua stores ONLY proc/stdin/stdout; the driver owns the stderr
> pipe. Without this redirect, a long-lived daemon that emits >64KB of stderr (errors, warnings)
> would block on the next stderr write (kernel pipe buffer full). The redirect silences all
> post-rcfile stderr → the pipe never fills. The startup "no job control in this shell" warning
> (~100 bytes, emitted BEFORE the rcfile runs) is harmless. LIVE-VERIFIED: does not break stdout
> or the read loop.

### Implementation Tasks (ordered by dependencies)

```yaml
Task 1: CREATE tests/shell_bash_spike.lua  (the folded-in SPIKE — do this FIRST; it is the ✔ gate)
  - MIRROR: tests/shell_fish_spike.lua (the proven luv pattern: uv.new_pipe×3, uv.spawn,
    stdout:read_start, sentinel find/parse, vim.wait(10000,done,20), pcall everything,
    is_closing teardown, check()/fails()/ SPIKE_PASS|SPIKE_SKIP footer).
  - DIFFERENCE from fish: (a) shell = opts.shell or vim.fn.exepath("bash") or "bash";
    (b) args = { "--rcfile", script_path, "-i" }; (c) the startup script is the bash daemon
    rcfile (Implementation Blueprint above), written to os.tmpname(); (d) the response payload
    is a SINGLE JSON object (vim.json.decode it, not a per-line parse).
  - GATE 1 (MUST-PASS, always): send __PIREQ__\t{"line":"ls /tm","cursor":7,"after":""}\n,
    read until __PIRESP_END__, decode, assert words["/tmp"] is truthy. Print SPIKE_PASS on this alone.
  - GATE 2 (CONDITIONAL — git compspec iff bash-completion present): detect bash-completion by
    checking whether `complete -p git` succeeds in the spawned bash (send a probe frame OR check
    file existence of the 3 completion paths). IFF present: send __PIREQ__\t{"line":"git ch",...},
    assert checkout/cherry present. IFF absent: print "git-compspec: SKIPPED (bash-completion
    absent)" and DO NOT fail. (This target has NO bash-completion → Gate 2 skips here.)
  - GATING: if vim.fn.executable("bash")==0 → print SPIKE_SKIP, return (exit 0).
  - RUN: `timeout 60 nvim --headless --clean -u NORC +"luafile tests/shell_bash_spike.lua" +qa; echo exit=$?`
  - NAMING/PLACEMENT: tests/shell_bash_spike.lua (sibling of shell_fish_spike.lua).

Task 2: CREATE lua/pi-bridge/shell/bash.lua  (the driver module)
  - IMPLEMENT: module-local `local M = {}`, `local uv = vim.uv`, `local state = { proc=nil,
    stdin=nil, stdout=nil, script_path=nil, startup_timer=nil }`, module-local string
    `BASH_DAEMON_SCRIPT` = the rcfile (Implementation Blueprint above, verbatim).
  - IMPLEMENT M.start(opts, on_ready):
      * opts = { shell=<path>, cwd=<path?>, startup_timeout_ms=<num> } (from shell.lua ensure).
      * guard on_ready type (default no-op); never-throws.
      * write BASH_DAEMON_SCRIPT to a temp file (os.tmpname(); io.open w; f:write; f:close).
        Keep path in state.script_path. On io failure → on_ready(tostring(err)).
      * uv.new_pipe(false) ×3 (stdin/stdout/stderr); pcall each.
      * uv.spawn(opts.shell or "bash", { args={"--rcfile", script_path, "-i"},
        stdio={stdin,stdout,stderr}, cwd=opts.cwd }, on_exit_cb). pcall.
      * on spawn-OK: arm a one-shot uv.new_timer() for opts.startup_timeout_ms (default 5000)
        → on fire call on_ready("startup timeout") + close_handles (idempotent). The timer is
        CANCELLED once on_ready is delivered. NOTE: the daemon emits NOTHING on success — it
        blocks in its `while read` loop immediately; readiness is implicit in spawn-OK (NO sync
        sentinel needed, unlike zsh). So call on_ready(nil, handle, stdin, stdout) right after
        spawn-OK (+ cancel the timer). Document this (the key simplification vs zsh).
      * on spawn-FAIL / uv error: on_ready(tostring(err)) + close_handles().
  - IMPLEMENT M.cd(path):
      * pcall(function() if state.stdin and not state.stdin:is_closing() then
          state.stdin:write('cd "'..tostring(path):gsub('"','\\"')..'"\n') end end)
      * (the rcfile's read loop recognizes `cd <path>` lines and runs cd in the daemon's shell.)
  - IMPLEMENT local close_handles() (idempotent, is_closing-guarded, pcall'd — mirrors
    shell.lua's close_handles + the zsh driver's): read_stop+close stdout, process_kill+close
    proc (process_kill does NOT close — the F3 leak fix), close stdin + stderr, stop+close
    startup_timer, os.remove(script_path). NEVER throws. NOTE: stderr is owned by the DRIVER
    (shell.lua never stores it) — close_handles MUST close it too.
  - DOCSTRING [Mode A] header: Tier-2 status; the bare-words limitation (compgen returns no
    descriptions — documented); the bash-completion dependency (best-effort sourcing; quality
    depends on install); the opt-out via drivers.bash=false (handled by shell.lua pick_driver);
    the single-JSON-object requirement (jq-built, NOT per-line NDJSON); the exec 2>/dev/null
    pipe-drain rationale; pointer to research/notes.md.
  - FOLLOW pattern: lua/pi-bridge/bridge.lua (handle ownership + close_handles idiom) +
    shell.lua's own close_handles; tests/shell_fish_spike.lua (the spawn idiom); the zsh PRP's
    "Implementation Patterns & Key Details" (the M.start/M.cd/close_handles template — bash
    reuses it verbatim MINUS the zpty/timer-sync dance).
  - NAMING: M.start(opts,on_ready), M.cd(path); snake_case locals.
  - PLACEMENT: lua/pi-bridge/shell/bash.lua.

Task 3: CREATE tests/shell_bash_spec.lua  (plenary spec — PRD §17.15 "shell_bash_spec")
  - IMPLEMENT: spin up the driver (or the daemon directly), send `ls /tm`, assert /tmp appears;
    assert a command with a registered compspec (git) yields subcommands IFF bash-completion
    present (skip otherwise). Gated on vim.fn.executable("bash") (pending/skip if absent).
  - MIRROR: tests/shell_spec.lua / shell_request_spec.lua (plenary via tests/minimal_init.lua).
  - COVERAGE: happy path (ls /tm → /tmp); empty result (nonsense path → items=={}); teardown
    leaves no leaked handles; git subcommands iff bash-completion (conditional skip).
  - PLACEMENT: tests/shell_bash_spec.lua.
  - NOTE: this can be a thin wrapper around the spike's assertions. If time-boxed, the SPIKE
    (Task 1) + a loadability assertion (`require("pi-bridge.shell.bash").start` is a function)
    is the minimum; the full spec is the PRD §17.15 target.

Task 4: VERIFY shell.lua integration (NO edit to shell.lua — just confirm pick_driver loads it)
  - RUN (one-liner, AGENTS.md-compliant):
      timeout 30 nvim --headless --clean -u NORC -c 'set rtp+=.' \
        -c 'lua local s=require("pi-bridge.shell"); local d=s.pick_driver("/usr/bin/bash"); print(type(d), type(d and d.start))' -c 'qa'
  - EXPECT: `function function` (the module + its .start are found). If `nil nil`, the module
    path or the `.start` export is wrong.
```

### Implementation Patterns & Key Details

```lua
-- M.start — the spawn+delegate pattern (mirrors bridge.lua M.connect + fish spike + zsh driver,
--           but SIMPLER: no zpty, no __SETUP_OK__ sync — readiness = spawn-OK):
function M.start(opts, on_ready)
    if type(on_ready) ~= "function" then on_ready = function() end end
    opts = opts or {}
    local shell = opts.shell or "bash"
    -- (1) write the LIVE-VERIFIED rcfile to a temp file (NEVER inline via -c with a heredoc)
    local path = os.tmpname()
    local f, err = io.open(path, "w")
    if not f then return on_ready(tostring(err)) end
    f:write(BASH_DAEMON_SCRIPT)        -- the string from the Implementation Blueprint
    f:close()
    state.script_path = path
    -- (2) pipes + spawn (pcall every uv call — fish spike GOTCHA G2)
    local stdin, stdout, stderr = uv.new_pipe(false), uv.new_pipe(false), uv.new_pipe(false)
    local handle, spawn_err
    local ok = pcall(function()
        handle, spawn_err = uv.spawn(shell, {
            args = { "--rcfile", path, "-i" },
            stdio = { stdin, stdout, stderr },
            cwd = opts.cwd,         -- nil is acceptable (uv defaults)
        }, function(code)            -- on_exit: child died → shell.lua's read_start sees EOF → _reset
            -- nothing to do here: shell.lua owns the read loop + _reset (the EOF path).
        end)
    end)
    if not ok or not handle then
        os.remove(path); return on_ready(tostring(spawn_err or "spawn failed"))
    end
    state.proc, state.stdin, state.stdout = handle, stdin, stdout
    -- (3) startup-timeout guard (bash sources bash-completion ~100-300ms where present; instant
    --     where absent — well under default 5000). Honor opts.startup_timeout_ms. NOTE: NO sync
    --     sentinel is needed (unlike zsh) — bash blocks in its `while read` loop immediately;
    --     readiness is implicit in spawn-OK.
    local ms = opts.startup_timeout_ms or 5000
    state.startup_timer = uv.new_timer()
    state.startup_timer:start(ms, 0, function()
        close_handles()
        on_ready("startup timeout")
    end)
    -- (4) ready: hand the handles back. shell.lua will stdout:read_start into _feed.
    --     Cancel the timer (success path).
    pcall(function() if state.startup_timer and not state.startup_timer:is_closing()
        then state.startup_timer:stop(); state.startup_timer:close() end end)
    on_ready(nil, handle, stdin, stdout)
end

-- close_handles — idempotent, never-throws (mirrors shell.lua close_handles + bridge.lua M.close).
-- NOTE: stderr is owned by the DRIVER (shell.lua never stores it) — close it here too.
local function close_handles()
    if state.startup_timer and not state.startup_timer:is_closing() then
        pcall(function() state.startup_timer:stop() end)
        pcall(function() state.startup_timer:close() end)
    end
    if state.stdout and not state.stdout:is_closing() then
        pcall(function() state.stdout:read_stop() end)
        pcall(function() state.stdout:close() end)
    end
    if state.proc and not state.proc:is_closing() then
        pcall(uv.process_kill, state.proc, "sigkill")
        pcall(function() state.proc:close() end)   -- process_kill does NOT close (F3 leak fix)
    end
    if state.stdin and not state.stdin:is_closing() then
        pcall(function() state.stdin:close() end)
    end
    -- stderr: the DRIVER owns it (shell.lua stores only proc/stdin/stdout). Close it.
    -- (Keep a stderr ref in state — add `stderr` to the state table — OR close it via the local
    --  upvalue. Simplest: store it in state.stderr alongside the others.)
    if state.stderr and not state.stderr:is_closing() then
        pcall(function() state.stderr:close() end)
    end
    if state.script_path then pcall(os.remove, state.script_path); state.script_path = nil end
end

-- M.cd — best-effort cwd sync (the rcfile's read loop recognizes `cd <path>` lines):
function M.cd(path)
    pcall(function()
        if state.stdin and not state.stdin:is_closing() then
            state.stdin:write('cd "' .. tostring(path):gsub('"', '\\"') .. '"\n')
        end
    end)
end
```

> **State table note:** add `stderr = nil` to the `state` literal (the zsh driver's state may not
> have it; bash's close_handles needs it). Store `state.stderr = stderr` in M.start alongside
> proc/stdin/stdout. This is the ONE structural difference from the zsh driver's state.

### Integration Points

```yaml
CONSUMER (NO edit — shell.lua is COMPLETE):
  - shell.lua ensure() calls `state.driver.start(opts, cb)` → this driver's M.start.
  - shell.lua does `stdout:read_start(... M._feed ...)` on the stdout this driver returns.
  - shell.lua _feed decodes the single-JSON-object payload this driver's rcfile emits.
  - Confirm: `require("pi-bridge.shell").pick_driver("/usr/bin/bash")` returns this module.

CONFIG (forward-contract — NOT this task; P2.M3.T6.S1 adds config.shell):
  - startup_timeout_ms: passed THROUGH by shell.lua (default 5000). The driver honors it.
  - drivers.bash = false: handled by shell.lua pick_driver (returns nil → degrade). No driver work.

FILES:
  - NEW: lua/pi-bridge/shell/bash.lua
  - NEW: tests/shell_bash_spike.lua
  - NEW (optional/min): tests/shell_bash_spec.lua
  - DO NOT EDIT: lua/pi-bridge/shell.lua, lua/pi-bridge/shell/zsh.lua (sibling, in parallel),
    completion.lua, PRD.md, plan/*, tasks.json.
```

---

## Validation Loop

### Level 1: Syntax & Style (Immediate Feedback)
```bash
# This repo has NO linter/mypy. Validation = load the module headless + run the spike/spec.
# (Mirrors every other lua module in this repo — see research/notes.md + zsh PRP.)
timeout 30 nvim --headless --clean -u NORC -c 'set rtp+=.' \
  -c 'lua local m=require("pi-bridge.shell.bash"); assert(type(m.start)=="function"); assert(type(m.cd)=="function"); print("LOAD_OK")' \
  -c 'qa'; echo "exit=$?"
# Expected: LOAD_OK, exit 0.
```

### Level 2: The SPIKE (the folded-in ✔ gate — run FIRST and confirm green)
```bash
# AGENTS.md-compliant: file-based :luafile, timeout-bounded.
timeout 60 nvim --headless --clean -u NORC +"luafile tests/shell_bash_spike.lua" +qa
echo "exit=$?"   # 0 = SPIKE_PASS (or SPIKE_SKIP if bash absent); 1 = gate FAILED → debug
# Expected stdout tail (bash-present box): SPIKE_PASS: ... /tmp present [+ git-compspec: PASSED|SKIPPED]
```
If Gate 1 (ls /tm → /tmp) fails, debug the rcfile directly (NO nvim needed — pure bash):
```bash
printf '__PIREQ__\t{"line":"ls /tm","cursor":7,"after":""}\n' | bash --rcfile /tmp/<rcfile> -i 2>/dev/null
# Expect: __PIRESP_START__ \n {"items":[{"value":"/tmp"}],"prefix":""} \n __PIRESP_END__
```
The rcfile in the Implementation Blueprint is LIVE-VERIFIED — if the standalone bash run is clean
but the spike fails, the bug is in the Lua-side spawn/read/decode (mirror the fish spike exactly).

### Level 3: shell.lua Integration (system validation)
```bash
# Confirm pick_driver loads the module + .start (NO edit to shell.lua):
timeout 30 nvim --headless --clean -u NORC -c 'set rtp+=.' \
  -c 'lua local s=require("pi-bridge.shell"); local d=s.pick_driver("/usr/bin/bash"); print(type(d), d and type(d.start))' \
  -c 'qa'; echo "exit=$?"
# Expected: `function function`, exit 0.
```

### Level 4: Plenary spec (PRD §17.15 target; gated on bash)
```bash
timeout 90 nvim --headless --clean -u tests/minimal_init.lua \
  -c 'lua require("plenary.busted").run("tests/shell_bash_spec.lua")'
echo "exit=$?"
# If bash absent on the runner: the spec MUST pending/skip (never fail CI — PRD §17.15).
# bash is present on essentially every Linux runner → this always runs here.
```

---

## Final Validation Checklist

### Technical Validation
- [ ] Level 1 load: `LOAD_OK`, exit 0.
- [ ] Level 2 spike: `SPIKE_PASS` (bash present) / `SPIKE_SKIP` (absent), exit 0.
- [ ] Level 2 Gate 1: `ls /tm` → `/tmp` present (MUST-PASS, always).
- [ ] Level 2 Gate 2: git compspec assertion runs iff bash-completion present; skips otherwise (this target: SKIPPED).
- [ ] Level 3 integration: `pick_driver("/usr/bin/bash")` → `function function`.
- [ ] Level 4 spec (if written): green on a bash box; skip on a bash-less box.

### Feature Validation
- [ ] `ls /tm` → `/tmp` in the decoded JSON (spike Gate 1).
- [ ] Empty result (`ls /nonexistent`) → `{"items":[],"prefix":""}` (not empty payload).
- [ ] Response is a single `{"items":[...],"prefix":""}` object (NOT per-line NDJSON).
- [ ] `M.start` calls `on_ready(nil, proc, stdin, stdout)` on success; `(err)` on every failure.
- [ ] `M.cd(path)` writes `cd "<path>"` without throwing.
- [ ] Never throws (pcall'd uv); honors `opts.startup_timeout_ms`; handles binary-missing.
- [ ] No leaked uv handles (startup_timer + stdin/stdout/stderr pipes + proc all closed on teardown).

### Code Quality Validation
- [ ] Follows `bridge.lua`/`shell.lua` close_handles idiom (is_closing-guarded, pcall'd, idempotent).
- [ ] `stderr` handle closed by the driver's close_handles (shell.lua doesn't store it).
- [ ] rcfile uses `exec 2>/dev/null` (pipe-drain safety) + `sort -u` (dedup) + `jq -c` (single object).
- [ ] `[Mode A]` docstring explains Tier-2 status, bare-words limitation, bash-completion dependency, opt-out.
- [ ] File placement: `lua/pi-bridge/shell/bash.lua` + `tests/shell_bash_spike.lua`.
- [ ] AGENTS.md ⛔ HARD RULE honored (file-based `:luafile`; `timeout` on every nvim call).

### Documentation & Deployment
- [ ] Docstring documents the jq dependency (+ pure-bash fallback note for jq-less targets).
- [ ] Docstring documents the `read -ra` quoting limitation (Tier-2 accepted; accept.lua handles edge cases).
- [ ] Pointer to `research/notes.md` for the full rcfile + probe transcripts.

---

## Anti-Patterns to Avoid

- ❌ **Don't emit per-line `{"value":...}` (NDJSON) between sentinels** — `shell._feed`'s
  `vim.json.decode` throws → parse failures → daemon killed. Emit ONE `{"items":[...],"prefix":""}`
  object via jq. (The PRD §17.6.3 sketch's per-line printf is a doc inconsistency — corrected here.)
- ❌ **Don't skip `exec 2>/dev/null` in the rcfile** — the driver owns the stderr pipe (shell.lua
  doesn't store it); without the redirect, >64KB of stderr over a long session blocks the daemon.
- ❌ **Don't skip `sort -u`** — `compgen -f -d` lists a directory as both a file and a dir →
  duplicate menu entries.
- ❌ **Don't add a startup-sync sentinel** — bash blocks in its `while read` loop immediately (no
  compinit cold-cache like zsh). Readiness = spawn-OK. Adding a `__SETUP_OK__` dance is needless
  complexity + a false-failure source.
- ❌ **Don't try to replicate readline's tokenizer** (quoting-aware COMP_WORDS) — `read -ra` is
  the PRD sketch's behavior + an accepted Tier-2 limitation. accept.lua handles quoting edge cases.
- ❌ **Don't hardcode `/usr/bin/bash`** — use `opts.shell or "bash"` (shell.lua's resolve_shell may
  return `/bin/bash`, `/usr/bin/bash`, or a config path).
- ❌ **Don't hardcode the git-compspec assertion as MUST-PASS** — gate it on bash-completion
  presence (this target has NONE; `complete -p git` exits 1). File completion is the only universal gate.
- ❌ **Don't edit `shell.lua`, `shell/zsh.lua` (sibling, in parallel), `completion.lua`, `PRD.md`,
  `plan/*`, or `tasks.json`.**
- ❌ **Don't pipe a heredoc into nvim stdin** (AGENTS.md ⛔ HARD RULE) — write the spike to a file,
  run `:luafile`.

---

## Confidence Score & Notes

**Confidence: 9/10 for one-pass success** — the CORE technique is LIVE-VERIFIED (the rcfile was
run verbatim against bash 5.3.15 + jq 1.8.2 this session; all 5 probes pass: `ls /tm` → `/tmp`,
empty → `{"items":[]}`, empty-line → CWD listing, `git ch` (no bash-completion) → fallthrough,
`cd` forwarding → relative completion). The consumer contract (`shell.lua`) is COMPLETE and read
in full. The luv-side spawn pattern is proven (fish spike). The ONLY structural work is the
Lua-side `M.start`/`M.cd`/`close_handles` shell around the rcfile — which is a strict subset of
the zsh driver's skeleton (no zpty, no sync dance). The 1-point residual risk is the stderr-pipe
drain detail (handled by `exec 2>/dev/null` — verified non-breaking) + the git-compspec test
gating (handled by conditional skip). If bash-completion is absent on a target (as here), the
driver degrades to file/dir completion (still Tier-2-usable) — no architectural rework.