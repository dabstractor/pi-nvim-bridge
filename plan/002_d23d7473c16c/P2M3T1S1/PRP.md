# PRP — P2.M3.T1.S1: `zsh.lua` capture-completion driver (zle widget, compinit, compadd redefinition)

**Parent:** P2.M3.T5 (shell/zsh.lua + shell/bash.lua + unknown-shell degrade) — *this item
maps to plan-tree node `P2.M3.T5.S1` ("zsh.lua capture-completion driver — zle widget,
compinit, compadd redefinition", 2 pts); the orchestrator assigned the path `P2M3T1S1`.*
**Component:** B (`pi-bridge.nvim`) — new module `lua/pi-bridge/shell/zsh.lua` + spike test.
**PRD anchor:** §17.6.2 *zsh — Tier 1 (capture-completion)* (supported by §17.5, §17.12, §17.15).
**Size:** 2 pts — **the most fragile driver in the shell-completion feature**; a SPIKE is
folded into this task and is the ✔ gate before the module is considered done.
**Sibling context:** `lua/pi-bridge/shell.lua` (the daemon manager, P2.M1.T2) is COMPLETE and
consumes this driver via `pick_driver` → `require("pi-bridge.shell.zsh").start`. The fish
driver (`shell/fish.lua`, P2.M2.T4) is PLANNED and shares the same `start(opts,cb)`/`cd(path)`
contract; do NOT build the fish driver here — build only `zsh.lua`.

---

## Goal

**Feature Goal:** Deliver the Tier-1 zsh completion driver — a `lua/pi-bridge/shell/zsh.lua`
module that `shell.lua`'s `pick_driver` loads for a resolved `/bin/zsh`/`/usr/bin/zsh` shell.
The driver spawns a **persistent** zsh that captures real zsh completions (git subcommands,
file paths, descriptions) via the canonical **zpty + redefined-`compadd` capture** technique
(Valodim/zsh-capture-completion), speaking the framed `__PIREQ__`/`__PIRESP_{START,END}`
protocol that `shell.lua`'s `_feed` already parses. A folded-in **spike**
(`tests/shell_zsh_spike.lua`) validates the exact zle/zpty/compadd incantation against the
installed zsh (5.9.2) — this is the ✔ gate, because the PRD §17.6.2 sketch is a simplification
that does NOT work over pipes (see Context §1).

**Deliverable:**
1. `lua/pi-bridge/shell/zsh.lua` — exports `M.start(opts, on_ready)` (spawns `zsh -f` over
   `vim.uv.spawn` pipes, internally drives a zpty completion child, installs the
   `__PIREQ__`→`__PIRESP_{START,END}` request loop that emits a **single JSON object** between
   sentinels) and `M.cd(path)` (best-effort cwd sync). pcall'd, never-throws.
2. `tests/shell_zsh_spike.lua` — standalone (plenary-FREE) end-to-end proof: spawn zsh, send
   `git ch`, assert `checkout`+`cherry` present. **Gated on `vim.fn.executable("zsh")`**
   (skip→exit 0 if absent; PRD §17.15). This is the SPIKE that iterates the zsh-side script
   until it passes.
3. `[Mode A]` docstring on `zsh.lua` explaining Tier-1 status, the capture technique, the
   fragility note, and the compinit requirement.

**Success Definition:**
- `tests/shell_zsh_spike.lua` prints `SPIKE_PASS` (exit 0) on a zsh-present box: spawns a real
  zsh, completes `git ch`, and `checkout` + `cherry` (or `cherry-pick`) appear in the parsed
  JSON. (On a zsh-less box: `SPIKE_SKIP`, exit 0.)
- `require("pi-bridge.shell.zsh").start` is loadable + exposes `.start` (so
  `shell.pick_driver("/usr/bin/zsh")` returns the module, not nil).
- The driver hands `(proc, stdin, stdout)` back to `shell.lua`'s `ensure()` cb on success and
  `(err)` on every failure (binary missing / rc error / startup timeout), never throws.
- The response frame is a SINGLE JSON object `{"items":[...],"prefix":""}` (NOT per-line TSV —
  that fails `shell._feed`'s `vim.json.decode`; see Context §5).
- `M.cd(path)` writes `cd "<path>"` without throwing.

---

## User Persona

**Target User:** A pi user whose resolved execution shell is zsh (`$SHELL=/bin/zsh` or pi's
`shellPath=zsh`) and who types `!`/`!!` bash-mode lines in the Neovim external editor.

**Use Case:** The user types `!git ch` and presses Tab; pi-bridge routes the `!` line to the
shell daemon (`completion.lua` §17.7 gate, P2.M2.T3) → `shell.request` → this driver → the menu
shows `checkout`, `cherry`, `cherry-pick` with descriptions, just like the zsh REPL would.

**Pain Points Addressed:** zsh has no `compgen`; without this driver a zsh user gets either no
completion (unknown-shell degrade) or bash `compgen` (tier-2, no descriptions, wrong shell).
This driver gives zsh users their REAL zsh completions (Tier 1, with descriptions).

---

## Why

- **Business value:** Completes the Tier-1 shell coverage (fish is the other Tier-1; both give
  rich `word⇥description` completions). zsh is the most common "power user" shell — supporting
  it natively is high-leverage.
- **Integration:** Pure additive — a new module consumed by the EXISTING `shell.lua` daemon
  manager (no changes to `shell.lua`). The fish driver (P2.M2.T4) shares the contract; this
  driver is its zsh sibling.
- **Why the spike is folded in:** PRD §17.6.2 explicitly flags this as "the most fragile
  driver — the exact zle incantation varies subtly across zsh versions." The §17.6.2 sketch is
  a SIMPLIFICATION that does NOT work over uv.spawn pipes (zle needs a tty). The spike retires
  that risk by validating the real technique (zpty) before the module is declared done.

---

## What

### User-visible behavior
Once `shell.lua` routes a `!` line here (via P2.M2.T3, PLANNED), the user gets zsh-native
completions in the existing menu. **This task alone does not render completions** — it provides
the driver the later routing consumes. (The spike proves the driver works in isolation.)

### Technical requirements
1. **Module:** `lua/pi-bridge/shell/zsh.lua`, local `M = {}`, `local uv = vim.uv`.
2. **`M.start(opts, on_ready)`** where `opts = { shell, cwd, startup_timeout_ms }` (passed by
   `shell.lua` ensure) and `on_ready(err, proc, stdin, stdout)` is shell.lua's cb. The driver:
   (a) writes the zsh-side startup script (§Context §3) to a temp file (`os.tmpname()` or
   `io.tmpfile()`); (b) `uv.new_pipe(false)` × 3; (c) `uv.spawn(opts.shell or "zsh", { args =
   { "-f" }, stdio = {stdin,stdout,stderr}, cwd = opts.cwd }, on_exit)` running a daemon script
   that uses `zmodload zsh/zpty` to spawn the completion child; (d) on spawn success calls
   `on_ready(nil, handle, stdin, stdout)`; on failure `on_ready(err)`. pcall every uv call.
3. **`M.cd(path)`** writes `cd "<path>"` to `state.stdin` (forwarded into the pty child by the
   zsh-side script). pcall'd.
4. **Response format:** the zsh-side script emits
   `__PIRESP_START__\n{"items":[{"value":"...","description":"..."}],"prefix":""}\n__PIRESP_END__\n`
   per request — a SINGLE JSON object (built via `jq -R -s`, available on target), NOT per-line
   `word\tdesc` (which fails `shell._feed`).
5. **Spike:** `tests/shell_zsh_spike.lua` (plenary-FREE, mirrors `tests/shell_fish_spike.lua`)
   gated on `vim.fn.executable("zsh")`.
6. **Docstring** `[Mode A]` header on `zsh.lua`.

### Success Criteria
- [ ] Spike prints `SPIKE_PASS` (zsh present) / `SPIKE_SKIP` (absent), exit 0 either way.
- [ ] `zsh.lua` exports `.start` + `.cd`; `shell.pick_driver("/usr/bin/zsh")` returns it.
- [ ] `M.start` calls `on_ready(nil, proc, stdin, stdout)` on success; `(err)` on failure.
- [ ] Response is a single JSON object between sentinels (validated by the spike's decode).
- [ ] Never throws (pcall'd uv); honors `opts.startup_timeout_ms`.

---

## All Needed Context

### Context Completeness Check
A reader who knows nothing of this repo can implement this from: this PRP + the LIVE-VERIFIED
research notes at `plan/002_d23d7473c16c/P2M3T1S1/research/notes.md` (read it FIRST — it has
the exact Valodim source, the probe transcripts, and the 5 open spike items) + the fish spike
(`tests/shell_fish_spike.lua`, the proven luv-side pattern) + `lua/pi-bridge/shell.lua` (the
consumer contract). No pi-internal knowledge beyond §17 is needed.

### Documentation & References

```yaml
# MUST READ — the LIVE-VERIFIED research for THIS task (probe transcripts + Valodim verbatim source)
- file: plan/002_d23d7473c16c/P2M3T1S1/research/notes.md
  why: the canonical technique (zpty two-zsh arch), the compadd -A/-D capture trick (verbatim),
       the jq JSON recipe, the 5 open spike items (\r pollution, description capture, compinit
       cold cache, persistence, cursor-at-end), and the shell.lua contract.
  critical: |
    The PRD §17.6.2 sketch (zle widget driven DIRECTLY over pipes) does NOT work — zle needs a
    tty. The driver MUST use the zpty two-zsh architecture. Read this BEFORE writing any code.

# MUST READ — the consumer contract (COMPLETE; defines the driver's exact API)
- file: lua/pi-bridge/shell.lua
  why: ensure() calls `state.driver.start(opts, cb)` with opts={shell,cwd,startup_timeout_ms}
       and cb(err,proc,stdin,stdout). stdout is read_start'd into shell._feed. _feed decodes
       the payload as ONE JSON object (NDJSON/TSV throws → parse failure → daemon killed).
  pattern: the driver hands the luv handles back; shell.lua owns the read loop + framing parse.
  gotcha: |
    The driver does NOT parse responses in Lua. The zsh-side SCRIPT must emit the single-JSON-object
    frame itself (via jq). Emitting raw `word\tdesc` lines breaks _feed (LIVE-VERIFIED: TSV throws
    vim.json.decode → after 5 fails the daemon is marked unhealthy, §17.12).

# MUST READ — the proven luv-side spawn pattern (mirror it for zsh)
- file: tests/shell_fish_spike.lua
  why: the EXACT uv.new_pipe×3 + uv.spawn + stdout:read_start + sentinel-parse + vim.wait(10000)
       + pcall-everything + is_closing teardown idiom the zsh spike must copy. The ONLY difference
       is the shell-side startup script (fish's `complete -C` vs zsh's zpty+compadd).
  pattern: check()/fails()/SPIKE_PASS-or-SPIKE_SKIP footer; gated on vim.fn.executable.
  gotcha: the fish spike resolves the binary by literal path; zsh spike should use
          `opts.shell or vim.fn.exepath("zsh") or "zsh"`.

# MUST READ — the fish spike's research (proven luv seam + the daemon pattern rationale)
- file: plan/002_d23d7473c16c/P2M1T2S1/research/notes.md
  why: documents WHY sentinel framing handles pty/pipe noise, WHY pcall every uv call, WHY
       vim.wait bounds the loop, and the `=(<<<'...')`/temp-file sourcing pattern. The zsh
       driver's spawn/teardown mirrors fish's exactly; only the shell-side script differs.

# Canonical external technique (fetched + LIVE-VERIFIED this session)
- url: https://raw.githubusercontent.com/Valodim/zsh-capture-completion/master/capture.zsh
  why: the reference implementation. The compadd redefinition (builtin compadd -A __hits -D
       __dscr "$@") + the compprefuncs/comppostfuncs null-byte sentinel pair + the
       zpty -w z "$*"$'\t' drive are quoted VERBATIM in research/notes.md §2.
  critical: Valodim is ONE-SHOT (comppostfuncs includes `exit`). For a PERSISTENT daemon, drop
            `exit` and send Ctrl-C+Ctrl-U between requests (research §2c, §4-O4).

# zsh manual (citations)
- url: https://zsh.sourceforge.io/Doc/Release/Zsh-Line-Editor.html
  why: §21.1 — zle requires "shell input attached to a terminal." PROVES piped stdio (uv.spawn)
       cannot drive zle directly ⇒ zpty is mandatory.
- url: https://zsh.sourceforge.io/Doc/Release/Zsh-Modules.html#The-zsh_002fzpty-Module
  why: zpty -w / -r / -t / -d semantics.
- url: https://zsh.sourceforge.io/Doc/Release/Completion-Widgets.html
  why: compadd flag grammar — -d takes an ARRAY NAME (deref via ${(P)}), -A/-D capture arrays.

# PRD sections (read-only reference; §17.6.2 is the anchor but is a SIMPLIFICATION)
- url: PRD.md §17.6.2 "zsh — Tier 1 (capture-completion)"
  why: the intent + the (simplified) sketch. Treat the sketch as aspirational; the zpty
       architecture in research/notes.md is what actually works.
- url: PRD.md §17.5.1 (framing protocol) + §17.5.2 (daemon lifecycle) + §17.12 (failure modes)
  why: the wire format + the parse-failure→unhealthy→disable path the driver must not trip.
```

### Current codebase tree (relevant slice)

```bash
pi-nvim-bridge/
├── lua/pi-bridge/
│   ├── shell.lua              # COMPLETE (P2.M1.T2) — the consumer; DO NOT EDIT here
│   └── shell/                 # ← CREATE this dir; add zsh.lua (this task)
└── tests/
    ├── shell_fish_spike.lua   # the proven spike PATTERN to mirror (read-only)
    ├── shell_zsh_spike.lua    # ← CREATE (the folded-in spike; ✔ gate)
    ├── minimal_init.lua       # plenary harness (read-only)
    └── shell_smoke.lua        # read-only (the shell.lua smoke)
```

### Desired codebase tree with files added

```bash
lua/pi-bridge/shell/zsh.lua    # NEW — the zsh capture-completion driver (M.start + M.cd)
tests/shell_zsh_spike.lua      # NEW — standalone spike (plenary-FREE); the ✔ gate
```

### Known Gotchas of our codebase & Library Quirks

```lua
-- CRITICAL (ARCHITECTURE): uv.spawn gives PIPES, not a tty. zle REQUIRES a tty (zsh §21.1).
-- The PRD §17.6.2 sketch (zle widget driven over the daemon's own stdin) CANNOT work. The
-- driver MUST use `zmodload zsh/zpty` + `zpty CAP zsh -f -i` (a SECOND zsh in a pty) and
-- drive that child. LIVE-VERIFIED: direct `_main_complete` over pipes → zero output (aborts).

-- CRITICAL (RESPONSE FORMAT): shell._feed does `pcall(vim.json.decode, payload)` on the WHOLE
-- payload between sentinels — it expects ONE {"items":[...],"prefix":""} object. The §17.6.2
-- sketch's per-line `printf '%s\t%s\n'` is NDJSON-ish/TSV → decode THROWS → parse_failure →
-- after 5 the daemon is killed (§17.12). The zsh-side script MUST build the single JSON object
-- (via jq; jq 1.8.2 is on the target) — it must NOT emit raw word⇥desc lines.

-- GOTCHA (\r pollution): the pty's cooked-mode line discipline converts \n→\r\n. Captured lines
-- arrive as `checkout\r` (+ stray `\r`/`\r\r` lines). LIVE-VERIFIED in probe C. The zsh-side
-- script MUST strip trailing \r + drop empty lines before jq (or `tr -d '\r'` in the pipe).

-- GOTCHA (compinit cold cache ~6s): `compinit -u` cold EXCEEDS the default startup_timeout_ms
-- (5000). Use `compinit -C` (cached dump) or pin a dump (`compinit -d ~/.zcompdump_pi_capture`).
-- The driver's start() MUST honor opts.startup_timeout_ms + call on_ready("startup timeout") if
-- the __SETUP_OK__ sync doesn't arrive in time. Sync MUST ACCUMULATE reads (a non-accumulating
-- read loop misses the slow sentinel — verified).

-- GOTCHA (persistence): Valodim is one-shot (comppostfuncs has `exit`). Drop `exit` for a
-- persistent daemon + send Ctrl-C (\x03) then Ctrl-U (\x15) before EACH request to reset zle +
-- clear the typed line. The spike MUST prove ≥2 sequential requests (git ch, then git re).

-- GOTCHA (descriptions): git's `_describe` passes -d as an ARRAY NAME; the PRD sketch treats it
-- as an inline string (3 bugs). Use Valodim's exact code (builtin compadd -D __dscr populates
-- the array) OR the zparseopts -A opts -D -E correction (research/notes.md §4-O2). The spike
-- must confirm `checkout -- <desc>` appears; if unattainable for some families, ship words-only
-- + document (still Tier-1-usable).

-- GOTCHA (cursor-at-end): Valodim TYPES the command (zpty -w z "$cmd"$'\t') → cursor at END.
-- The request's `cursor` offset is honored only when == #line (the common pi-prompt case).
-- Mid-line cursor is OUT OF SCOPE v1 — DOCUMENT. (research §4-O5.)

-- GOTCHA (setup sourcing): NEVER feed the multiline setup line-by-line into zsh's interactive
-- loop (breaks: bracketed-paste, `#` not a comment interactively, lost tabs — verified). Source
-- it in ONE shot from a temp file / process-substitution `=(<<<'...')`.

-- LIBRARY QUIRK: AGENTS.md ⛔ HARD RULE — the Lua spike is a FILE run via +"luafile" +qa, NEVER a
-- heredoc into nvim stdin (hangs). Wrap every nvim invocation in `timeout` (e.g. timeout 60).
```

---

## Implementation Blueprint

### Data models and structure
No data model — the driver is a stateless-ish module with module-local `state = { proc,
stdin, stdout, script_path, startup_timer }` (mirrors `bridge.lua`'s handle ownership). It
hands the luv handles to `shell.lua` on success; it does NOT own the read loop (shell.lua's
`_feed` does). The only structured artifact is the response JSON `{"items":[...],"prefix":""}`,
built by the zsh-side script (not Lua).

### The zsh-side startup script (the heart of the driver — write to a temp file, source it)

This is the artifact the spike iterates. It runs inside the **daemon zsh (zsh-A)** that nvim
spawns over pipes. It (1) loads zpty, (2) spawns the completion child zsh-B in a pty + sources
its setup in one shot, (3) syncs on `__SETUP_OK__`, (4) loops reading `__PIREQ__\t{json}` from
ITS stdin, driving zsh-B, capturing + jq-building the JSON, emitting the framed response.

```zsh
#!/usr/bin/env zsh -f
# === zsh-A daemon script (driven by nvim over pipes) ===
zmodload zsh/zpty || { echo "__PIRESP_START__"; echo '{"items":[],"prefix":""}'; echo "__PIRESP_END__"; exit 1; }

# (2) spawn the completion child in a pty (real tty → zle works)
zpty CAP zsh -f -i

# (2b) the child setup, sourced in ONE shot (process-substitution file; avoids line-by-line mangling)
_child=$(cat <<'ZSHB'
PROMPT=; RPROMPT=
autoload -Uz compinit && compinit -C 2>/dev/null          # -C: cached dump (cold -u is ~6s)
bindkey '^M' undefined; bindkey '^J' undefined            # never execute typed text
bindkey '^I' complete-word                                # TAB triggers completion
null-line() { echo -E - $'\0' }                           # NUL sentinel
compprefuncs=( null-line ); comppostfuncs=( null-line )   # NUL before+after (NO exit: persistent)
zstyle ':completion:*' list-grouped false
zstyle ':completion:*' insert-tab false
zstyle ':completion:*' list-separator ''
zmodload zsh/zutil
# the compadd capture hook (Valodim's -A/-D trick) — see research/notes.md §2b for the FULL
# version with prefix/suffix/dir-suffix handling; this is the minimal core:
compadd() {
    typeset -a __hits __dscr __tmp
    if (( $@[(I)-d] )); then
        __tmp=${@[$[${@[(i)-d]}+1]]}
        if [[ $__tmp == \(* ]]; then eval "__dscr=$__tmp"; else __dscr=( "${(@P)__tmp}" ); fi
    fi
    builtin compadd -A __hits -D __dscr "$@"
    setopt localoptions norcexpandparam extendedglob
    [[ -n $__hits ]] || return
    local dscr
    for i in {1..$#__hits}; do
        (( $__dscr >= $i )) && dscr=" -- ${${__dscr[$i]}##$__hits[$i] #}" || dscr=
        echo -E - $__hits[$i]$dscr
    done
}
echo __SETUP_OK__
ZSHB
)
zpty -w CAP "source =(<<< ${(qq)_child})"

# (3) sync on __SETUP_OK__ (ACCUMULATE reads — compinit cold cache is slow; a non-accumulating
#     read loop misses the sentinel). Bounded by the startup timer the Lua side arms.
local _acc="" _ch="" integer _w=0
while (( _w < 100 )); do
    zpty -r -t CAP _ch 0.1 2>/dev/null && _acc+="$_ch"
    [[ "$_acc" == *__SETUP_OK__* ]] && break
    zpty -t CAP 2>/dev/null || break; _w=$((_w+1))
done
[[ "$_acc" == *__SETUP_OK__* ]] || { print "__PIRESP_START__"; print '{"items":[],"prefix":""}'; print "__PIRESP_END__"; zpty -d CAP; exit 1; }

# (4) request loop: read __PIREQ__\t{json}\n from stdin (the nvim pipe)
while IFS= read -r _req; do
    [[ "$_req" == __PIREQ__* ]] || continue
    # parse line (jq extracts .line; the field the user typed, bangs already stripped by shell.lua)
    _line=$(print -r -- "$_req" | sed 's/^__PIREQ__\t//' | jq -r '.line // empty' 2>/dev/null)
    [[ -n "$_line" ]] || { print "__PIRESP_START__"; print '{"items":[],"prefix":""}'; print "__PIRESP_END__"; continue; }

    # drive the child: reset zle state + clear line, then type command + TAB
    zpty -w CAP $'\x03'             # Ctrl-C: abort any in-progress completion/menu
    zpty -w CAP $'\x15'             # Ctrl-U: kill-whole-line
    zpty -w CAP "$_line"$'\t'       # type command + TAB (triggers complete-word)

    # read until BOTH NUL sentinels seen (compprefuncs + comppostfuncs); accumulate
    local _out="" _c="" integer _n=0
    while (( _n < 300 )); do
        _n=$((_n+1))
        zpty -r -t CAP _c 0.1 2>/dev/null && _out+="$_c"
        local _r="${_out#*$'\0'}"
        [[ "$_r" == *$'\0'* ]] && break
        zpty -t CAP 2>/dev/null || break
    done
    # extract payload between the two NUL bytes; strip \r (pty cooked-mode); drop blanks
    local _rest="${_out#*$'\0'}"; local _payload="${_rest%%$'\0'*}"
    _payload="${_payload//$'\r'/}"

    # build the single JSON object via jq + emit the framed response
    print "__PIRESP_START__"
    print -r -- "$_payload" | jq -R -s '
        split("\n") | map(select(length > 0))
        | map(capture("^(?<value>[^ ]+)( -- (?<description>.*))?$") // {value:., description:""})
        | {items: map({value, description}), prefix:""}
    ' 2>/dev/null || print '{"items":[],"prefix":""}'
    print "__PIRESP_END__"
done

zpty -d CAP 2>/dev/null
```

> **Spike iteration target:** the implementer writes the ABOVE into the temp file the Lua
> driver creates, runs the spike, and iterates §4's open items (O1 \r, O2 descriptions, O4
> persistence) until `git ch` → `checkout`+`cherry` and a 2nd `git re` → `rebase`/`reset`.
> The script above is the LIVE-VERIFIED starting point (probe B passed with its core).

### Implementation Tasks (ordered by dependencies)

```yaml
Task 1: CREATE tests/shell_zsh_spike.lua  (the folded-in SPIKE — do this FIRST; it is the ✔ gate)
  - MIRROR: tests/shell_fish_spike.lua (the proven luv pattern: uv.new_pipe×3, uv.spawn,
    stdout:read_start, sentinel find/parse, vim.wait(10000,done,20), pcall everything,
    is_closing teardown, check()/fails/ SPIKE_PASS|SPIKE_SKIP footer).
  - DIFFERENCE from fish: (a) shell = opts.shell or vim.fn.exepath("zsh") or "zsh";
    (b) the startup script is the zsh-A daemon script (Implementation Blueprint above), written
    to os.tmpname() and passed as `zsh -f /tmp/...` OR sourced; (c) the response payload is a
    SINGLE JSON object (vim.json.decode it, not a per-line parse).
  - GATE: send __PIREQ__\t{"line":"git ch","cursor":6,"after":""}\n, read until __PIRESP_END__,
    decode, assert words["checkout"] and words["cherry"] (or cherry-pick). Print SPIKE_PASS.
  - GATING: if vim.fn.executable("zsh")==0 → print SPIKE_SKIP, return (exit 0).
  - ITERATE: if the gate fails, adjust the zsh-side script per research/notes.md §4 (O1–O4)
    until it passes. The spike IS the validation of the exact incantation.
  - RUN: `timeout 60 nvim --headless --clean -u NORC +"luafile tests/shell_zsh_spike.lua" +qa; echo exit=$?`
  - NAMING/PLACEMENT: tests/shell_zsh_spike.lua (sibling of shell_fish_spike.lua).

Task 2: CREATE lua/pi-bridge/shell/zsh.lua  (the driver module)
  - IMPLEMENT: module-local `local M = {}`, `local uv = vim.uv`, `local state = { proc=nil,
    stdin=nil, stdout=nil, script_path=nil, startup_timer=nil }`.
  - IMPLEMENT M.start(opts, on_ready):
      * opts = { shell=<path>, cwd=<path?>, startup_timeout_ms=<num> } (from shell.lua ensure).
      * guard on_ready type (default no-op); never-throws.
      * write the zsh-A daemon script (Implementation Blueprint) to a temp file
        (os.tmpname(); io.open w; f:write(script); f:close). Keep path in state.script_path.
      * uv.new_pipe(false) ×3 (stdin/stdout/stderr); pcall each.
      * uv.spawn(opts.shell or "zsh", { args={"-f", script_path} (or source via -c),
        stdio={stdin,stdout,stderr}, cwd=opts.cwd }, on_exit_cb). pcall.
      * on spawn-OK: arm a one-shot uv.new_timer() for opts.startup_timeout_ms (default 5000)
        → on fire call on_ready("startup timeout") + close handles (idempotent). The timer is
        CANCELLED once on_ready is delivered (success or fail). NOTE: the daemon emits nothing
        on success — readiness is implicit in spawn-OK (the zsh-A script blocks in its read
        loop; shell.lua's first request drives it). So call on_ready(nil, handle, stdin, stdout)
        shortly after spawn-OK (optionally after a brief liveness check). Document this.
      * on spawn-FAIL / uv error: on_ready(tostring(err)) + close_handles().
  - IMPLEMENT M.cd(path):
      * pcall(function() if state.stdin and not state.stdin:is_closing() then
          state.stdin:write('cd "'..tostring(path):gsub('"','\\"')..'"\n') end end)
      * (the zsh-A script's read loop ignores non-__PIREQ__ lines OR you forward cd into CAP;
        simplest: zsh-A can treat a `cd X` line specially. Document the chosen approach.)
  - IMPLEMENT local close_handles() (idempotent, is_closing-guarded, pcall'd — mirrors
    shell.lua's close_handles): read_stop+close stdout, process_kill+close proc, close stdin,
    stop+close startup_timer, os.remove(script_path). NEVER throws.
  - DOCSTRING [Mode A] header: Tier-1 status; the capture technique (redefined compadd +
    builtin -A/-D); the zpty two-zsh architecture (WHY: zle needs a tty, uv.spawn gives pipes);
    the fragility note (zle varies across versions — validated by the spike against 5.9.2); the
    compinit requirement (-C cached; cold -u is ~6s > default startup_timeout); response is a
    single JSON object (jq-built, NOT per-line TSV); pointer to research/notes.md.
  - FOLLOW pattern: lua/pi-bridge/bridge.lua (handle ownership + close_handles idiom) +
    shell.lua's own close_handles; tests/shell_fish_spike.lua (the spawn idiom).
  - NAMING: M.start(opts,on_ready), M.cd(path); snake_case locals.
  - PLACEMENT: lua/pi-bridge/shell/zsh.lua.

Task 3: CREATE tests/shell_zsh_spec.lua  (plenary spec — PRD §17.15 "shell_zsh_spec")
  - IMPLEMENT: spin up the driver (or the daemon directly), send `git ch`, assert
    checkout/cherry/cherry-pick appear; gated on vim.fn.executable("zsh") (pending/skip if absent).
  - MIRROR: tests/shell_spec.lua / shell_request_spec.lua (plenary via tests/minimal_init.lua).
  - COVERAGE: happy path (git ch → checkout+cherry); empty result (a nonsense command → items=={});
    teardown leaves no leaked handles.
  - PLACEMENT: tests/shell_zsh_spec.lua.
  - NOTE: this can be a thin wrapper around the spike's assertions. If time-boxed, the SPIKE
    (Task 1) + a loadability assertion (`require("pi-bridge.shell.zsh").start` is a function)
    is the minimum; the full spec is the PRD §17.15 target.

Task 4: VERIFY shell.lua integration (NO edit to shell.lua — just confirm pick_driver loads it)
  - RUN (one-liner, AGENTS.md-compliant):
      timeout 30 nvim --headless --clean -u NORC -c 'set rtp+=.' \
        -c 'lua local s=require("pi-bridge.shell"); local d=s.pick_driver("/usr/bin/zsh"); print(type(d), type(d and d.start))' -c 'qa'
  - EXPECT: `function function` (the module + its .start are found). If `nil nil`, the module
    path or the `.start` export is wrong.
```

### Implementation Patterns & Key Details

```lua
-- M.start — the spawn+delegate pattern (mirrors bridge.lua M.connect + fish spike):
function M.start(opts, on_ready)
    if type(on_ready) ~= "function" then on_ready = function() end end
    opts = opts or {}
    local shell = opts.shell or "zsh"
    -- (1) write the zsh-A daemon script to a temp file (NEVER inline via -c with a heredoc)
    local path = os.tmpname()
    local f, err = io.open(path, "w")
    if not f then return on_ready(tostring(err)) end
    f:write(ZSH_DAEMON_SCRIPT)        -- the string from the Implementation Blueprint
    f:close()
    state.script_path = path
    -- (2) pipes + spawn (pcall every uv call — fish spike GOTCHA G2)
    local stdin, stdout, stderr = uv.new_pipe(false), uv.new_pipe(false), uv.new_pipe(false)
    local handle, spawn_err
    local ok = pcall(function()
        handle, spawn_err = uv.spawn(shell, {
            args = { "-f", path }, stdio = { stdin, stdout, stderr },
            cwd = opts.cwd,         -- nil is acceptable (uv defaults)
        }, function(code)            -- on_exit: child died → if not yet ready, fail
            if not state.proc then return end   -- already torn down
            -- EOF-equivalent: shell.lua's read_start will see data==nil → _reset. Nothing to do.
        end)
    end)
    if not ok or not handle then
        os.remove(path); return on_ready(tostring(spawn_err or "spawn failed"))
    end
    state.proc, state.stdin, state.stdout = handle, stdin, stdout
    -- (3) startup-timeout guard (the zsh-A script blocks in its read loop; readiness is
    --     spawn-OK). Honor opts.startup_timeout_ms (default 5000). NOTE: compinit cold cache
    --     is ~6s — if startup_timeout_ms < ~8000 and compinit is cold, prefer compinit -C in
    --     the script (already set) so the sync is fast.
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

-- close_handles — idempotent, never-throws (mirrors shell.lua close_handles + bridge.lua M.close)
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
    if state.script_path then pcall(os.remove, state.script_path); state.script_path = nil end
end

-- M.cd — best-effort cwd sync (the daemon forwards into the pty child):
function M.cd(path)
    pcall(function()
        if state.stdin and not state.stdin:is_closing() then
            state.stdin:write('cd "' .. tostring(path):gsub('"', '\\"') .. '"\n')
        end
    end)
end
```

### Integration Points

```yaml
CONSUMER (NO edit — shell.lua is COMPLETE):
  - shell.lua ensure() calls `state.driver.start(opts, cb)` → this driver's M.start.
  - shell.lua does `stdout:read_start(... M._feed ...)` on the stdout this driver returns.
  - shell.lua _feed decodes the single-JSON-object payload this driver's script emits.
  - Confirm: `require("pi-bridge.shell").pick_driver("/usr/bin/zsh")` returns this module.

CONFIG (forward-contract — NOT this task; P2.M3.T6.S1 adds config.shell):
  - startup_timeout_ms: passed THROUGH by shell.lua (default 5000). The driver honors it.
  - drivers.zsh = false: handled by shell.lua pick_driver (returns nil → degrade). No driver work.

FILES:
  - NEW: lua/pi-bridge/shell/zsh.lua
  - NEW: tests/shell_zsh_spike.lua
  - NEW (optional/min): tests/shell_zsh_spec.lua
  - DO NOT EDIT: lua/pi-bridge/shell.lua, completion.lua, PRD.md, plan/*, tasks.json.
```

---

## Validation Loop

### Level 1: Syntax & Style (Immediate Feedback)
```bash
# This repo has NO linter/mypy. Validation = load the module headless + run the spike/spec.
# (Mirrors every other lua module in this repo — see research/notes.md §8 G6.)
timeout 30 nvim --headless --clean -u NORC -c 'set rtp+=.' \
  -c 'lua local m=require("pi-bridge.shell.zsh"); assert(type(m.start)=="function"); assert(type(m.cd)=="function"); print("LOAD_OK")' \
  -c 'qa'; echo "exit=$?"
# Expected: LOAD_OK, exit 0.
```

### Level 2: The SPIKE (the folded-in ✔ gate — run FIRST and iterate to green)
```bash
# AGENTS.md-compliant: file-based :luafile, timeout-bounded.
timeout 60 nvim --headless --clean -u NORC +"luafile tests/shell_zsh_spike.lua" +qa
echo "exit=$?"   # 0 = SPIKE_PASS (or SPIKE_SKIP if zsh absent); 1 = gate FAILED → iterate §4
# Expected stdout tail (zsh-present box): SPIKE_PASS: ... checkout+cherry present
```
If the gate fails, iterate the zsh-side script per `research/notes.md` §4:
- O1 `\r` pollution → strip `\r` (already in the blueprint script).
- O2 descriptions → try the zparseopts correction; confirm `-- <desc>` appears.
- O4 persistence → confirm Ctrl-C+Ctrl-U reset yields a 2nd request.

### Level 3: shell.lua Integration (system validation)
```bash
# Confirm pick_driver loads the module + .start (NO edit to shell.lua):
timeout 30 nvim --headless --clean -u NORC -c 'set rtp+=.' \
  -c 'lua local s=require("pi-bridge.shell"); local d=s.pick_driver("/usr/bin/zsh"); print(type(d), d and type(d.start))' \
  -c 'qa'; echo "exit=$?"
# Expected: `function function`, exit 0.
```

### Level 4: Plenary spec (PRD §17.15 target; gated on zsh)
```bash
timeout 90 nvim --headless --clean -u tests/minimal_init.lua \
  -c 'lua require("plenary.busted").run("tests/shell_zsh_spec.lua")'
echo "exit=$?"
# If zsh absent on the runner: the spec MUST pending/skip (never fail CI — PRD §17.15).
```

---

## Final Validation Checklist

### Technical Validation
- [ ] Level 1 load: `LOAD_OK`, exit 0.
- [ ] Level 2 spike: `SPIKE_PASS` (zsh present) / `SPIKE_SKIP` (absent), exit 0.
- [ ] Level 3 integration: `pick_driver("/usr/bin/zsh")` → `function function`.
- [ ] Level 4 spec (if written): green on a zsh box; skip on a zsh-less box.

### Feature Validation
- [ ] `git ch` → `checkout` + `cherry` (or `cherry-pick`) in the decoded JSON (spike).
- [ ] Response is a single `{"items":[...],"prefix":""}` object (NOT per-line TSV).
- [ ] `M.start` calls `on_ready(nil, proc, stdin, stdout)` on success; `(err)` on every failure.
- [ ] `M.cd(path)` writes `cd "<path>"` without throwing.
- [ ] Never throws (pcall'd uv); honors `opts.startup_timeout_ms`; handles binary-missing.
- [ ] No leaked uv handles (startup_timer + pipes + proc all closed on teardown paths).

### Code Quality Validation
- [ ] Follows `bridge.lua`/`shell.lua` close_handles idiom (is_closing-guarded, pcall'd, idempotent).
- [ ] `[Mode A]` docstring explains Tier-1 status, capture technique, zpty rationale, fragility, compinit.
- [ ] File placement: `lua/pi-bridge/shell/zsh.lua` + `tests/shell_zsh_spike.lua`.
- [ ] AGENTS.md ⛔ HARD RULE honored (file-based `:luafile`; `timeout` on every nvim call).

### Documentation & Deployment
- [ ] Docstring documents the cursor-at-end limitation (v1 scope) + the compinit cold-cache note.
- [ ] Pointer to `research/notes.md` for the full technique + open items.

---

## Anti-Patterns to Avoid

- ❌ **Don't drive zle directly over uv.spawn pipes** — it has no tty; zle never activates. Use zpty. (LIVE-VERIFIED: direct `_main_complete` → zero output.)
- ❌ **Don't emit per-line `word⇥desc` (NDJSON/TSV) between sentinels** — `shell._feed`'s `vim.json.decode` throws → parse failures → daemon killed. Emit ONE JSON object (jq-built).
- ❌ **Don't feed the multiline setup line-by-line into zsh's interactive loop** — it mangles (bracketed-paste, `#` not a comment, lost tabs). Source from a temp file / `=(<<<'...')` in one shot.
- ❌ **Don't skip the `\r` strip** — the pty cooked-mode pollutes every line with `\r` (LIVE-VERIFIED).
- ❌ **Don't use `comppostfuncs=( null-line exit )`** — that's Valodim's one-shot; a persistent daemon must drop `exit` and reset zle state (Ctrl-C+Ctrl-U) between requests.
- ❌ **Don't skip the spike** — this is the most fragile driver; the §17.6.2 sketch is a simplification. The spike IS the validation.
- ❌ **Don't edit `shell.lua`, `completion.lua`, `PRD.md`, `plan/*`, or `tasks.json`.**
- ❌ **Don't pipe a heredoc into nvim stdin** (AGENTS.md ⛔ HARD RULE) — write the spike to a file, run `:luafile`.
- ❌ **Don't hardcode `/usr/bin/zsh`** — use `opts.shell or vim.fn.exepath("zsh") or "zsh"`.

---

## Confidence Score & Notes

**Confidence: 8/10 for one-pass success** — the CORE technique is LIVE-VERIFIED (zpty +
compadd `-A`/`-D` yields real git completions), the consumer contract (`shell.lua`) is
COMPLETE and read in full, and the luv-side spawn pattern is proven (fish spike). The 2-point
residual risk is in the spike's open items (descriptions O2, persistence O4) — both are
explicitly flagged with concrete fixes, and the spike is the gate that retires them before the
module is declared done. If descriptions prove unattainable for some completion families, the
driver degrades gracefully to words-only (still Tier-1-usable) — no architectural rework.