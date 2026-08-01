# bash best-effort completion driver — research findings (P2.M3.T5.S2)

Source-of-truth: **PRD §17.6.3** (bash — Tier 2 best-effort sketch) + the canonical
programmatic-bash-completion technique popularized by **Brian Beffa (brbsix)**,
"Accessing tab-completion programmatically in Bash"
(`https://brbsix.github.io/2015/11/29/accessing-tab-completion-programmatically-in-bash/`).
Every non-obvious fact below is **LIVE-VERIFIED against bash 5.3.15** on this machine
(`/usr/bin/bash`), on a box with **NO `bash-completion` package installed** (the common
degrade case — see §5).

This box's environment is the worst realistic case for bash completion:
- `bash` 5.3.15 (system default on Arch).
- **no `bash-completion`** → `complete -p git` / `complete -p ls` return NOTHING (no
  compspecs registered). Only the builtin fallbacks (`compgen -f -d` for files/dirs,
  `compgen -abck` for command names) are available.

## §1 — bash is a PLAIN-PIPES driver (like fish; UNLIKE zsh)

The single most important finding: **bash completion does NOT require a TTY.** Unlike
zsh (whose completion is driven by zle widgets that need a real terminal — see the zsh
research's §1), bash's `compgen` and the completion FUNCTION dispatch (`complete -F fn`)
are ordinary builtins callable non-interactively over plain stdin/stdout pipes.

Consequence for the Lua driver:

```
nvim  ──plain pipes──►  bash (ONE process; a script with a `while read` loop)
                         │  source bash-completion (best-effort, §7)
                         │  while IFS= read -r req; do __pi_handle "$req"; done
                         ▼
                       stdin/stdout/stderr are bash's pipes → luv sees a normal subprocess,
                       EXACTLY like fish.lua. NO pty, NO outer/inner split (unlike zsh.lua).
```

So **bash.lua ≈ fish.lua** (same `start(opts,on_ready)`/`cd(path)`, same stderr-ready-signal,
same temp-file + spawn + handle-cleanup discipline). The ONLY difference from fish is the
spawn args (`bash <tmp>` instead of `fish -i --init-command=...`) and the DAEMON_SCRIPT
contents (bash with the COMP_*/compgen dispatch instead of fish's `complete -C`). This is
structurally **simpler than zsh** (one process, one temp file, real cd — see §6).

## §2 — The pure-bash JSON escape (NO `python3` dependency — the PRD sketch was wrong)

PRD §17.6.3's sketch JSON-escapes candidate words via:

```bash
$(printf '%s' "$w" | python3 -c 'import json,sys;print(json.dumps(sys.stdin.read()))')
```

This is **unacceptable**: `python3` is NOT guaranteed on the user's box, and spawning a
python subprocess per candidate is slow + fragile. The correct approach is the **pure-bash
parameter-substitution escape** (the SAME technique zsh.lua's `OUTER_SCRIPT` uses via
`${s//\\/\\\\}`; bash and zsh share this `${var//from/to}` substitution syntax).

LIVE-VERIFIED against bash 5.3.15 — the function + its output for every edge case:

```bash
__pi_json_str() {
    local s="$1"
    s="${s//\\/\\\\}"; s="${s//\"/\\\"}"; s="${s//$'\n'/\\n}"; s="${s//$'\r'/\\r}"; s="${s//$'\t'/\\t}"
    printf '"%s"' "$s"
}
```

```
space:  "my file.txt"
quote:  "a\"b"
slash:  "a\\b"
tab:    "a\tb"
$/btick: "a$b`c"
```

**Backslash MUST be escaped FIRST** (before re-escaping the `\` it introduces) — the exact
order fish.lua/zsh.lua use. `$`, backtick, `<`, `>`, etc. are LITERAL inside the
double-quoted JSON string and need no escaping (JSON only requires `\`, `"`, and the
control chars). This is the **critical correctness fix** over the PRD sketch.

## §3 — THE BIG ONE: the PRD §17.6.3 `COMP_CWORD` loop is BUGGY (LIVE-VERIFIED + fixed)

PRD §17.6.3's sketch computes `COMP_CWORD` by accumulating word lengths:

```bash
read -ra COMP_WORDS <<< "$line"           # ← strips trailing whitespace!
local i cword=0 cum=0
for ((i=0;i<${#COMP_WORDS[@]};i++)); do
  cum=$((cum+${#COMP_WORDS[i]}+1)); (( cum>=point )) && { cword=$i; break; }
done
```

**The bug (LIVE-VERIFIED):** `read -ra COMP_WORDS <<< "$line"` **strips trailing
whitespace**. So `ls ` (a command + trailing space, meaning "start completing the
ARGUMENT") collapses to `COMP_WORDS=("ls")`, and the loop sets `cword=0`, `cur="ls"` —
completing the command `ls` AGAIN instead of the argument the user just started. Any line
with a trailing space is broken. This is the dominant real-world case (user types `ls <Tab>`).

**The fix (LIVE-VERIFIED — the proven approach below passes every case in §3b):**
truncate the line at `point`, detect trailing whitespace on that prefix, and append an
explicit empty word so `cur=""` for a trailing-space cursor:

```bash
__pi_words() {
    local prefix="${line:0:point}"
    local trailing_ws=0
    [[ "$prefix" =~ [[:space:]]$ ]] && trailing_ws=1
    COMP_WORDS=()
    read -ra COMP_WORDS <<< "$prefix"
    (( ${#COMP_WORDS[@]} == 0 )) && COMP_WORDS+=("")   # empty line → one empty word (guards -1)
    (( trailing_ws )) && COMP_WORDS+=("")              # cursor in trailing ws → new empty word
    COMP_CWORD=$(( ${#COMP_WORDS[@]} - 1 ))
    cur="${COMP_WORDS[COMP_CWORD]}"
    cmd="${COMP_WORDS[0]}"
}
```

### §3b — LIVE-VERIFIED results (every case correct)

```
line="ls /tm" point=6 → cmd=ls  cur=/tm cword=1 trailing_ws=0   ✓ (arg completion)
line="gi"     point=2 → cmd=gi  cur=gi  cword=0 trailing_ws=0   ✓ (command completion)
line="ls "    point=3 → cmd=ls  cur=''  cword=1 trailing_ws=1   ✓ (FIXED — empty arg word)
line="git ad" point=6 → cmd=git cur=ad  cword=1 trailing_ws=0   ✓
line="ls  /tm" point=7 → cmd=ls cur=/tm cword=1 trailing_ws=0   ✓ (double space ok)
line=""       point=0 → cmd=''  cur=''  cword=0 trailing_ws=0   ✓ (empty-line guard)
line="x"      point=1 → cmd=x   cur=x   cword=0 trailing_ws=0   ✓
```

The PRP's daemon script MUST use THIS fixed computation (NOT the PRD sketch's accumulation
loop). Document as a "LIVE-VALIDATED refinement over PRD §17.6.3".

## §4 — Command-name completion (cword==0 → `compgen -abck`, NOT a compspec)

When `COMP_CWORD == 0` the user is completing the COMMAND name itself (the first word).
Bash completion does this via a special path: there is no compspec for a partial command
name, so `complete -p "$cmd"` returns nothing. The correct fallback is `compgen` with the
command-class actions:

```bash
COMPREPLY=( $(compgen -abck -A function -- "$cur" 2>/dev/null) )
```

`-a` aliases, `-b` builtins, `-c` commands (from PATH), `-k` shell keywords, `-A function`
shell functions. LIVE-VERIFIED: `compgen -abck -A function -- "gi"` on this box yields
`git`, `gitk`, `git-filter-repo`, … (50 hits) — exactly what bash offers at `gi<Tab>` in a
real shell.

**This is a refinement over the PRD sketch**, which had no cword==0 branch and would have
fallen through to `compgen -f -d` (files/dirs) for a command name — wrong. The cword==0
branch makes first-word completion correct.

## §5 — No `bash-completion` → graceful degrade to `compgen -f -d` (LIVE-VERIFIED)

`bash-completion` (the package that registers `_git`, `_ls`, etc. via `complete -F`) is
OPTIONAL. On this box it is NOT installed → `complete -p git` / `complete -p ls` return
nothing (exit 1). The driver MUST degrade gracefully: when no compspec is registered for
`$cmd`, fall back to file/dir completion:

```bash
COMPREPLY=( $(compgen -f -d -- "$cur" 2>/dev/null) )
```

LIVE-VERIFIED: `compgen -f -d -- "/tm"` → `/tmp` (file/dir completion ALWAYS works, even
with zero completion infrastructure). This is the §17.6.3 "Files/dirs always work" guarantee
and the floor of the Tier-2 experience. **The daemon script must source bash-completion
best-effort (§7) but NEVER depend on it** — the file/dir fallback is the contract.

## §6 — bash can do REAL `cd` (unlike zsh v1 — it's a plain script loop)

Unlike zsh (whose inner Enter is bound to a noop widget for safety, making `cd` advisory —
see zsh research §7), the bash daemon is a plain non-interactive script with a
`while IFS= read -r req` loop. Nothing constrains it from executing `builtin cd` in
response to a `__PICD__\t<path>\n` frame. So **bash's `cd(path)` is REAL** (like fish), not
advisory (like zsh v1): a `__PICD__` frame does `builtin cd "$path"` and subsequent path
completions are relative to the new cwd.

This is a genuine quality advantage of the bash driver over the zsh driver for v1 (real
cwd tracking). The driver's `M.cd(path)` mirrors fish.lua's verbatim (write `__PICD__\t<path>\n`
via `last_stdin`); the daemon script's `__PICD__` branch does a real `builtin cd`.

## §7 — Spawning + sourcing bash-completion (the `bash <script>` form)

**Spawn form:** `bash <daemon_tmp>` (the daemon script as a positional arg). This runs bash
in NON-INTERACTIVE script mode. Key facts:
- A non-interactive bash script does **NOT** source `~/.bashrc` (only interactive
  non-login shells do). This is CONSISTENT with PRD §17.4 `prefer:"pi"` — pi itself runs
  `!`/`!!` commands via `/bin/bash -c` (non-interactive), so user aliases/functions from
  `~/.bashrc` are NOT available at execution either. Completing a `.bashrc`-only alias
  would suggest a command that FAILS. So **do NOT source `~/.bashrc`** (documented known
  limitation, mirrors zsh's `-f` stance).
- The daemon script's FIRST lines source the `bash-completion` package **best-effort**
  (the system completion definitions: `_git`, `_ls`, etc.) via the canonical paths:

  ```bash
  for _bc in /usr/share/bash-completion/bash_completion \
             /usr/local/share/bash-completion/bash_completion \
             /etc/bash_completion /usr/local/etc/bash_completion ; do
      [ -r "$_bc" ] && { . "$_bc"; break; }
  done
  unset _bc
  ```

  `bash_completion` is the package's main file (defines `complete -F` registrations
  system-wide). Sourcing it registers the compspecs; if NONE of the paths exist (this box),
  no compspecs register and the §5 file/dir fallback governs. `bash-completion` MUST be
  optional — wrap each `. "$_bc"` in `[ -r ]` (readable) and `|| true`.
- `bash <script>` non-interactive: no prompt noise, no line-editor interference — cleaner
  than fish's `-i`. Sentinel framing isolates any residual output anyway.

**`-i` is NOT needed** (and is actively worse): `bash --rcfile X` only sources the rcfile
for interactive shells, forcing `-i`, which then tries to run a line editor on the piped
stdin. The `<script>` form sidesteps all of this. (fish needed `-i` because `--init-command`
is fish-specific; bash has no equivalent constraint.)

## §8 — NO descriptions (the defining Tier-2 limitation)

`compgen` returns **bare words, no descriptions** — this is a hard bash limitation, not an
implementation choice. The completion FUNCTIONS (`_git`, etc.) populate `COMPREPLY` with
strings only; bash's completion protocol has no description channel (unlike fish's
`complete -C word⇥desc` or zsh's `compadd -d`). So **bash driver items are `{value}` only**
(no `description` key). PRD §17.6.3 states this explicitly ("compgen returns bare words, no
descriptions") and §17.4.3's mismatch notice recommends zsh/fish when available. Document
prominently + surface in `:checkhealth` (Tier-2 quality row, P2.M3.T6.S2).

## §9 — The `.line` / `.cursor` extraction (crude-but-robust, mirrors zsh/fish)

The request frame is `__PIREQ__\t{"line":"git ch","cursor":6,"after":""}\n`. Extracting
`.line` + `.cursor` via a real JSON parser is infeasible in pure bash. The proven approach
(mirrors zsh.lua's OUTER + fish.lua's crude regex) is bash parameter substitution:

```bash
local payload="${req#__PIREQ__	}"                       # strip "__PIREQ__\t" (literal tab)
local cmd="${${...}#...}"                                # (zsh syntax — bash uses:)
local line="${payload#*\"line\":\"}"; line="${line%%\"*}"
local cursor="${payload#*\"cursor\":}"; cursor="${cursor%%[!0-9]*}"
cursor="${cursor:-0}"
```

KNOWN LIMITATION (documented, same as fish/zsh): a command line containing a literal `"`
breaks `.line` extraction → `line` resolves empty → `compgen -abck` returns all commands (a
graceful degrade, NOT a crash — the gen-guard + empty-menu consumer handle it). A true
JSON-string parse is infeasible in pure bash without `jq`/`python3`; v1 accepts this edge
(the three sibling drivers all share it).

## §10 — Fragility + the N-consecutive-parse-failures disable (§17.12)

bash completion is documented as Tier-2 / fragile across versions (§17.6.3, §17.12). The
daemon script MUST emit `__PIRESP_END__` even on error/empty (so shell.lua `_feed` never
hangs waiting for a missing sentinel → the §17.12 parse-failure-disable doesn't fire from a
bash quirk). The daemon wraps its per-request work in a subshell + `trap` so a failing
completion FUNCTION cannot abort the request loop:

```bash
__pi_handle() {
    # ... extract line/cursor ...
    echo __PIRESP_START__
    (
        # run completion dispatch in a subshell so a buggy compspec fn can't kill us
        __pi_complete "$line" "$cursor"
        for w in "${COMPREPLY[@]}"; do ... printf ...; done
    ) 2>/dev/null
    echo __PIRESP_END__
}
trap '' PIPE                                # SIGPIPE from a closed stdout shouldn't kill us
```

If the response STILL fails to decode (N consecutive times), shell.lua `_feed`'s
`state.parse_failures` threshold (default 5) marks `state.failed=true` and the §17.12
degrade path disables the daemon for the session. bash.lua inherits this safety net from
shell.lua — no driver-level retry/respawn (v1, §17.17).

## §11 — Test plan (mirrors fish/zsh; CI gating on `bash` — universal)

`bash` is present on essentially every CI Linux runner (unlike fish/zsh, which need
gating). So bash LIVE tests run UNCONDITIONALLY (no `pending`/skip), which is stronger
coverage than fish/zsh. The three test files mirror the zsh/fish siblings:

- `tests/shell_bash_spike.lua` — plenary-FREE GATE: spawn `bash <tmp>`, send one
  `__PIREQ__\t{"line":"ls /tm",...}\n`, parse between sentinels, assert `/tmp` appears
  (works on THIS box — no bash-completion needed). The proven script → `bash.lua`'s
  `DAEMON_SCRIPT` verbatim.
- `tests/shell_bash_driver_smoke.lua` — persistence (3 sequential requests through ONE
  daemon) + real cd (write `__PICD__\t<vimpld>` then a request, assert no crash + cwd
  changed — cd is REAL for bash, unlike zsh v1).
- `tests/shell_bash_driver_spec.lua` — offline contract (start/cd signature, never-throws,
  bogus-shell no-leak) + LIVE case (`ls /tm` → `/tmp`; `gi` → `git`).

Risk: LOW vs zsh. The architecture is fish-simple (plain pipes); the only bash-specific
complexity is the COMP_* computation (§3, LIVE-VALIDATED + fixed). No PTY, no outer/inner
split, no version-sensitive zle widget. The spike should pass first try on bash 5.x.