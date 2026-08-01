# zsh capture-completion driver — research findings (P2.M3.T5.S1)

Source-of-truth: **Valodim/zsh-capture-completion** `capture.zsh` (137 lines, fetched
`https://raw.githubusercontent.com/Valodim/zsh-capture-completion/master/capture.zsh`).
This is the canonical technique the PRD §17.6.2 references ("used by fzf's zsh completion
and `Valodim/zsh-capture-completion`"). Every non-obvious fact below is from that file or
LIVE-VERIFIED against zsh 5.9.2 on this machine (`/usr/bin/zsh`).

## §1 — THE BIG ONE: zsh completion REQUIRES a PTY (unlike fish)

Unlike fish (plain pipes work — `complete -C` is a non-zle builtin), zsh completion is
driven by **zle widgets** (`complete-word`, bound to Tab). zle only activates on a TTY.
There is NO non-interactive compsys entrypoint usable over plain stdin pipes. Valodim
proves this by design:

```zsh
zmodload zsh/zpty || { echo 'error: missing module zsh/zpty' >&2; exit 1 }
zpty z zsh -f -i          # spawn an INNER zsh inside a pseudo-terminal named "z"
zpty -w z source $1       # write into the pty ("source <init script>")
zpty -r z line            # read from the pty
zpty -w z "$*"$'\t'       # "type" the command + a Tab to trigger complete-word
zpty -d z                 # delete the pty on exit
```

**Implication for the Lua driver:** `vim.uv` (luv) has NO PTY/openpty API. So the driver
CANNOT give a zsh a pty the way it gives fish a pipe. The architecture that fits the
existing `start(opts,on_ready)` contract (already satisfied by fish.lua) is:

```
nvim  ──plain pipes──►  OUTER zsh (one process; a script with a `while read` loop)
                          │  zmodload zsh/zpty
                          │  zpty z zsh -f -i      ◄── INNER completion zsh (in a pty)
                          │  zpty -w / zpty -r      (pty is INTERNAL to the outer zsh;
                          │                          invisible to nvim/luv — plain pipes)
                          ▼
                       stdin/stdout/stderr are the OUTER zsh's pipes → luv sees a normal
                       subprocess, exactly like fish.lua. The pty complexity lives in the
                       OUTER zsh's DAEMON_SCRIPT, NOT in Lua.
```

So **zsh.lua ≈ fish.lua** (same `start(opts,on_ready)`/`cd(path)`, same stderr-ready-signal,
same temp-file + spawn + handle-cleanup discipline). The ONLY difference is the spawn args
(`zsh -f <tmp>` instead of `fish -i --init-command=...`) and the DAEMON_SCRIPT contents
(zsh with an embedded pty instead of fish with a read loop). **All complexity is in the
zsh script, not Lua.** This is the single most important finding.

## §2 — The canonical `compadd` override (the capture hook)

Valodim redefines the `compadd` builtin inside the INNER zsh so every completion candidate
flows through a function that echoes `value + description`. Verbatim (key parts):

```zsh
compadd () {
    # -O/-A/-D are array-storage forms (used by _describe etc.) — delegate, don't capture.
    if [[ ${@[1,(i)(-|--)]} == *-(O|A|D)\ * ]]; then
        builtin compadd "$@"; return $?
    fi
    typeset -a __hits __dscr __tmp
    # -d <array> carries descriptions (the _describe / `compadd -d` convention).
    if (( $@[(I)-d] )); then
        __tmp=${@[$[${@[(i)-d]}+1]]}
        if [[ $__tmp == \(* ]]; then eval "__dscr=$__tmp"
        else __dscr=( "${(@P)__tmp}" ); fi
    fi
    # Let zsh do the matching/filtering by injecting -A/-D (arrays). THIS is the magic:
    builtin compadd -A __hits -D __dscr "$@"
    setopt localoptions norcexpandparam extendedglob
    # parse prefixes/suffixes (-P/-p/-S/-s) + detect -f dir-suffix.
    typeset -A apre hpre hsuf asuf
    zparseopts -E P:=apre p:=hpre S:=asuf s:=hsuf
    integer dirsuf=0
    if [[ -z $hsuf && "${${@//-default-/}% -# *}" == *-[[:alnum:]]#f* ]]; then dirsuf=1; fi
    [[ -n $__hits ]] || return
    local dsuf dscr
    for i in {1..$#__hits}; do
        (( dirsuf )) && [[ -d $__hits[$i] ]] && dsuf=/ || dsuf=
        (( $#__dscr >= $i )) && dscr=" -- ${${__dscr[$i]}##$__hits[$i] #}" || dscr=
        echo -E - $IPREFIX$apre$hpre$__hits[$i]$dsuf$hsuf$asuf$dscr
    done
}
```

Key facts:
- `builtin compadd -A __hits -D __dscr "$@"` makes zsh do ALL the prefix-matching/pattern-
  filtering, returning the surviving `__hits` + their `__dscr`. We then echo each as
  `word[-- description]` (Valodim's ` -- ` separator) or `word` (no desc). The directory
  suffix (`/`) is appended when `-f` was in effect and the hit is a dir.
- Descriptions come from the `-d` argument (populated by `_describe` / the completion
  functions). This is how `git ch` → `checkout -- Checkout and switch branches`.
- The override must DELEGATE the `-O/-A/-D` array-storage calls (used internally by
  `_describe`/`_values`) or compsys breaks.

## §3 — The inner-init script (zstyles + keybindings + delimiters)

Valodim's sourced init block (adapted; the persistent-daemon version drops the `exit`):

```zsh
PROMPT=                                       # no prompt → less noise (sentinel-isolated anyway)
autoload compinit
compinit -d ~/.zcompdump_capture              # SEPARATE dump — never corrupt the user's ~/.zcompdump
bindkey '^M' undefined                        # Enter → no-op (NEVER execute a command the user typed)
bindkey '^J' undefined
bindkey '^I' complete-word                    # Tab → the widget that drives compsys (→ our compadd)
zstyle ':completion:*' list-grouped false
zstyle ':completion:*' insert-tab false
zstyle ':completion:*' list-separator ''      # no list separator → less stripping
zmodload zsh/zutil                            # for zparseopts in the compadd override
# per-request delimiters (Valodim's compprefuncs/comppostfuncs):
null-line () { echo -E - $'\0' }              # emit a NUL before+after the completion list
compprefuncs=( null-line )
comppostfuncs=( null-line )                   # DROP the `exit` Valodim had — keep the inner alive
# … the compadd override from §2 …
echo ok                                       # readiness signal (read by the outer zsh)
```

For OUR daemon: replace `echo ok` with the inner emitting a distinct readiness marker the
OUTER zsh detects on its pty read, then the OUTER emits `__PIREADY__` to its STDERR (the
Lua `start()` reads stderr — stdout stays pristine for shell.lua, exactly like fish.lua §7).

## §4 — `-f` (no rc) + dedicated compdump = the proven default

Valodim uses `zsh -f -i` (skip `/etc/zshenv`/`~/.zshenv`/`~/.zshrc`) + `compinit -d
~/.zcompdump_capture`. Implications:
- ✅ System completion DEFINITIONS (`_git`, `_docker`, … autoloaded from the system fpath
  `/usr/share/zsh/.../functions`) ARE available → `git ch` → checkout/cherry/cherry-pick
  WITH descriptions works out of the box.
- ❌ User ALIASES/functions added in `~/.zshrc` are NOT loaded (e.g. `g=git`). This is
  CONSISTENT with the PRD §17.4 `prefer:"pi"` correctness stance: pi executes `!` commands
  in bash by default (no zsh aliases either), so completing a zsh-only alias would suggest
  a command that FAILS at execution. `-f` avoids that footgun by default.
- The dedicated dump (`-d ~/.zcompdump_pi_bridge`, or `$TMPDIR`-scoped) avoids corrupting
  the user's interactive `~/.zcompdump`. `compinit -C` (use cached dump if present, skip
  rebuild) speeds the 2nd+ cold start; `-u` skips the insecure-dir check (we control cwd).

**Optional enhancement (NOT v1 default):** source the user's `~/.zshrc` to unlock aliases
— controlled by a future `config.shell.zsh.source_rc` flag, validated in the spike. Risk:
rc side-effects (slow plugins, prompts that write to stdout) can corrupt the pty stream;
the sentinel framing isolates it but the cold-start latency grows. Default = `-f` (reliable).

## §5 — Driving the inner per-request (the fiddly part — SPIKE-mandated)

Valodim's one-shot: `zpty -w z "$*"$'\t'` — types the command + Tab. For a PERSISTENT
inner zsh the line editor has LEFTOVER text after each completion, so the outer must
CLEAR the line before typing. Approach (validate in the spike):

```zsh
# OUTER request handler (per __PIREQ__):
zpty -w z $'\025'                        # Ctrl-U (unix-line-discard) — kill the current line
zpty -w z "$cmd"$'\t'                    # type the new command + Tab
# then read the pty until the POST null-marker, collecting compadd output between nulls
```

Pitfalls (PRD §17.6.2 "most fragile driver"; validate each in the spike):
- `^U` binding: `unix-line-discard` is the zle default but may be rebound by the user's
  config — but we use `-f` (no user config), so the default holds. STILL verify.
- The typed command is ECHOED by the inner's pty → it appears in `zpty -r` output. The NUL
  delimiters (compprefuncs/comppostfuncs) bound the REAL completion output; everything
  before the first NUL / after the last NUL is discarded. Parse between NULs only.
- `zpty -r` returns pty output including CR/LF. Strip `\r` (Valodim reads linewise +
  `setopt rcquotes`; we can `line="${line//$'\r'/}"`). The NUL (`\0`) survives.
- zsh 5.9 vs older: the `compadd -A/-D` array-injection + `zparseopts` behavior is stable
  back to ~5.0; the risk is the zle keybinding defaults + pty echo. The spike MUST run on
  the installed zsh (5.9.2 here) and the driver should report the zsh version in
  `:checkhealth` (P2.M3.T6).

## §6 — The response shape (shell.lua `_feed` contract — NON-NEGOTIABLE)

shell.lua `_feed` (L525, already landed) does `pcall(vim.json.decode, payload)` on the
WHOLE body between `__PIRESP_START__\n` and `__PIRESP_END__\n`, expecting ONE object
`{ "items": [ {"value":..,"description"?} ], "prefix": "" }`. The zsh DAEMON_SCRIPT MUST
emit that exact single-object JSON (NOT per-line NDJSON — NDJSON throws → parse_failure
→ §17.12 daemon-disable after N failures). Mirror fish.lua's `__pi_json_str` manual-escape
helper (zsh has no builtin JSON encoder; build it with `${param//\\/\\\\}` substitutions).

The OUTER zsh collects the INNER compadd's `word\tdesc` (or `word -- desc`) lines and
builds the items JSON array, then wraps in `__PIRESP_START__\n{...}\n__PIRESP_END__\n`.

## §7 — The `cd(path)` problem (zsh-specific)

The INNER zsh's cwd matters for path completions. But Valodim binds Enter→`undefined`
(never execute), so we cannot `zpty -w z "cd $dir"$'\n'`. Options:
- (A) Bind a dedicated control char (e.g. `\x02` Ctrl-B) in the inner to a widget that does
      `builtin cd -- "${(z)BUFFER}"` and clears the line; outer sends
      `zpty -w z $'\002'"$dir"$'\002'`. Fiddly but self-contained.
- (B) **Mark cd as advisory/no-op for v1 zsh** (document it): the inner keeps the spawn cwd
      (shell.lua passes `opts.cwd` → outer sets the inner's initial cwd via the spawn, OR
      via `zpty z zsh -f -i` with `cd` baked into the inner-init). Path completions are
      relative to that; a mid-session cwd change re-spawns. Simplest, most robust.

**Recommendation:** v1 uses (B) (cd is advisory / spawn-cwd-baked; document as a known
zsh limitation vs fish's clean cd). (A) is a future enhancement. The `M.cd(path)` method
still EXISTS (the contract requires it) but is a documented best-effort no-op for zsh.
Validate the choice in the spike.

## §8 — Spawning the outer zsh (Lua-side — mirrors fish.lua)

`M.start(opts, on_ready)`:
1. write the OUTER DAEMON_SCRIPT (the zsh with zpty + read loop) + the INNER init script to
   TWO temp files (outer.zsh, inner.zsh) — OR one file that writes the inner to a temp +
   sources it. (One file is cleaner: the outer script writes the inner-init to
   `mktemp`-style, but zsh can do `printf '%s' "$INNER" >| $tmp` from an embedded heredoc.
   Simplest: Lua writes BOTH files.)
2. `uv.new_pipe(false)` ×3 (stdin/stdout/stderr).
3. `uv.spawn(opts.shell or "zsh", { args={"-f", outer_tmp}, stdio=..., cwd=opts.cwd }, on_exit)`.
   `-f` skips zshenv/zshrc (the OUTER is a non-interactive script; it needs only `zsh/zpty`
   + the read loop — no zle). Pass the inner-init path via an ENV VAR (e.g.
   `PI_ZSH_INIT=<inner_tmp>`) the outer script reads, OR as a 2nd positional arg
   (`args={"-f", outer_tmp, inner_tmp}` → outer does `inner="$1"`).
4. arm `startup_timeout_ms` (default 5000) cold-start timer — the SLOW part is the INNER's
   `compinit` (100ms–1s+), NOT the outer spawn. The `__PIREADY__` stderr marker (emitted by
   the OUTER after the inner signals compinit-done) gates `on_ready`.
5. read_start STDERR for `__PIREADY__\n` → ready → `on_ready(nil, proc, stdin, stdout)`,
   handing stdout PRISTINE (shell.lua owns it). EOF-before-ready → startup failure.
6. failure paths: kill proc + close 3 pipes + rm BOTH temp files + `on_ready(err,nil,nil,nil)`.
   `proc:close()` REQUIRED after `process_kill` (F3 leak, same as fish.lua).

This is structurally IDENTICAL to fish.lua's `start()` — only the spawn args + the temp
file(s) differ. Copy fish.lua's `done`/`fail`/`resolved` closure discipline verbatim.

## §9 — zsh/zpty availability (sanity)

`zsh/zpty` is a STANDARD zsh module shipped with zsh (not a plugin). On zsh 5.9.2 it loads
cleanly: `zsh -fc 'zmodload zsh/zpty && echo ok'` → `ok`. If `zmodload zsh/zpty` fails on a
stripped/odd build, the outer script exits non-zero → `on_exit` fires pre-ready → startup
failure → `on_ready(err)` → `state.failed` → degrade notice (the existing §17.12 path).
No special handling beyond the existing failure discipline.

## §10 — Test plan (mirrors the fish driver)

`tests/shell_zsh_driver_spec.lua` (plenary) + `tests/shell_zsh_driver_smoke.lua` (plenary-free):
- offline: `M.start`/`M.cd` are functions; `require` loads clean; never-throws on bad
  opts/non-fn cb; bogus shell → `on_ready(err,nil,nil,nil)` + no leaked handles
  (`uv.walk` count assert, mirror `shell_fish_driver_spec.lua`).
- LIVE (gated on `vim.fn.executable("zsh")`, skip-exit-0 if absent — PRD §17.15):
  `start` → `on_ready(nil,proc,stdin,stdout)` within timeout; send
  `__PIREQ__\t{"line":"git ch","cursor":6,"after":""}\n`; assert decoded `items` contain
  `checkout` + `cherry` (the compsys `_git` definitions — present on every system zsh).
  Persistence: 3 sequential requests through ONE daemon.
- A pure-Lua `M.parse(raw)` (mirror fish.lua's) that parses the INNER compadd's
  `word<TAB>desc` / `word -- desc` raw lines for OFFLINE fixture tests (no live zsh needed).
- `after_each`: `package.loaded["pi-bridge.shell.zsh"]=nil` (isolation — don't leak into
  shell.lua's fake-driver tests; mirror the fish spec convention).
- SPIKE gate (P2.M3.T5.S1, before zsh.lua): `tests/shell_zsh_spike.lua` — standalone proof
  that the OUTER+INNER pty round-trip yields `checkout`/`cherry` for `git ch`. GATE for
  writing zsh.lua. (Mirrors `tests/shell_fish_spike.lua`.)

## §11 — Confidence / risk summary

- HIGH confidence on the architecture (outer-zsh + zsh/zpty is the proven Valodim model;
  fits the existing `start(opts,on_ready)` contract unchanged).
- MEDIUM confidence on the exact pty-driving incantation (clear-line, null-delimiter parse,
  compinit-dump caching) — these are zsh-version-sensitive and MUST be nailed by the spike
  (Task 1). The PRD explicitly flags this as "the most fragile driver."
- LOW risk to the rest of the system: the driver is PURELY additive (one new module + tests,
  like fish.lua was). shell.lua/completion.lua/extension are untouched. If zsh capture proves
  unfixable on a given zsh build, the §17.12 degrade path (parse_failures → state.failed →
  notice) already handles it gracefully — worst case zsh users get no completion, never a crash.