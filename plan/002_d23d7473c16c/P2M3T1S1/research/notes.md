# Research notes — P2.M3.T1.S1: zsh capture-completion driver (zle widget, compinit, compadd)

**Status: CORE TECHNIQUE LIVE-VERIFIED** against `/usr/bin/zsh` (zsh 5.9.2) + `jq` 1.8.2.
The zpty-based capture architecture + Valodim's `compadd -A/-D` capture trick are PROVEN to
yield real git completions (`git ch` → `checkout`, `cherry`, `cherry-pick`, `checkout-index`,
`check-attr`). Three concrete gotchas (`\r` pty pollution, description-capture, compinit cold
cache) are documented below for the implementer + the folded-in spike to nail.

---

## 0. Environment (verified this session)

| Tool | Path | Version |
|---|---|---|
| zsh | `/usr/bin/zsh` | 5.9.2 (x86_64-pc-linux-gnu) |
| jq | `/usr/bin/jq` | 1.8.2 |

- `compinit` loads cleanly under `zsh -f -i`.
- `jq 1.8.2` is available → the driver MAY use `jq -R -s` for JSON building (the robust path).
  A pure-zsh escaper fallback is documented §6 if a future target lacks jq.

---

## 1. THE central architectural finding — zpty is REQUIRED (two-zsh architecture)

**Problem:** `shell.lua`'s `ensure()` (P2.M1.T2.S3, COMPLETE) spawns the driver via
`vim.uv.spawn` with `uv.new_pipe(false)` pipes. **Pipes are NOT a tty.** zsh's line editor
(zle) — and therefore ALL completion widgets (`zle complete-word`, `_main_complete`) —
**require "shell input is attached to a terminal"** (zsh manual §21.1). With piped stdio,
zle is NEVER activated, so the PRD §17.6.2 sketch (`zle -N __pi_capture` + `zle complete-word`
driven directly from the pipe-fed daemon) **CANNOT work**.

**DIRECT PROBE (this session):** spawning a non-interactive `zsh -f` and calling
`_main_complete` directly (with manually-set BUFFER/CURSOR/WORDS + a redefined compadd)
produced **zero output** — the completion engine aborted because it was not in a zle/widget
context. Confirmed: no zpty ⇒ no completion.

**Solution (Valodim/zsh-capture-completion's technique):** the nvim-spawned daemon zsh
(zsh-A, over pipes) loads `zmodload zsh/zpty` and spawns a SECOND zsh (zsh-B) INSIDE a
pseudo-terminal: `zpty CAP zsh -f -i`. The pty gives zsh-B a real terminal fd ⇒ zle works ⇒
completion works. zsh-A drives zsh-B via `zpty -w CAP <text>` / reads via `zpty -r CAP`.
zsh-A reads `__PIREQ__\t{json}` requests from ITS stdin (the nvim pipe), drives zsh-B, captures
zsh-B's completion output, builds a single JSON object, and writes
`__PIRESP_START__\n{json}\n__PIRESP_END__\n` to ITS stdout (→ nvim's `shell._feed`).

```
nvim ──pipes──▶ zsh-A (daemon) ──zpty──▶ zsh-B (completion, real tty, zle active)
   ▲                  │                            │ compinit + compadd-capture hook
   │                  │ read __PIREQ__              │ bindkey '^I' complete-word
   └── _feed ◀── write __PIRESP_{START,END} ◀── jq-build JSON ◀── read pty (null-byte framed)
```

**zsh manual citations (HIGH confidence):**
- zle tty requirement: https://zsh.sourceforge.io/Doc/Release/Zsh-Line-Editor.html (§21.1)
- zpty module: https://zsh.sourceforge.io/Doc/Release/Zsh-Modules.html#The-zsh_002fzpty-Module

> **The PRD §17.6.2 sketch is a SIMPLIFICATION.** Its `zle complete-word` + `compadd()` redefinition
> directly in the daemon is NOT achievable over pipes. The driver MUST use the zpty two-zsh
> architecture. This is the single most important correction the implementer must internalize.

---

## 2. The canonical technique — Valodim/zsh-capture-completion (FETCHED VERBATIM)

Source fetched live (HTTP 200): `https://raw.githubusercontent.com/Valodim/zsh-capture-completion/master/capture.zsh`

### 2a. Spawn + one-shot setup sourcing
```zsh
zmodload zsh/zpty || { echo 'error: missing module zsh/zpty' >&2; exit 1 }
zpty z zsh -f -i                         # spawn child in a pty (real tty → zle works)
# source the WHOLE setup in ONE shot via process-substitution (NOT line-by-line zpty -w,
# which mangles multiline code: bracketed-paste, `#` not a comment interactively, lost tabs):
() {
    zpty -w z source $1
    repeat 4; do zpty -r z line; [[ $line == ok* ]] && return; done   # sync on "ok"
    echo 'error initializing.' >&2; exit 2
} =( <<< '...setup body ending with `echo ok`...' )
```
**Gotcha (verified by my first failed probe):** feeding multiline setup line-by-line into the
interactive loop BREAKS it. ALWAYS source from a process-substitution file `=(<<<'...')` or a
real temp file. The spike proved line-by-line feeding produces `zsh: unknown file attribute: i`
on `#` comments and loses `$'\t'` literals.

### 2b. The compadd capture trick (Valodim VERBATIM) — uses builtin `-A`/`-D`
```zsh
# inside the child setup, AFTER compinit:
compadd () {
    typeset -a __hits __dscr __tmp
    # parse -d (descriptions) — -d takes an ARRAY NAME, deref via ${(P)}
    if (( $@[(I)-d] )); then
        __tmp=${@[$[${@[(i)-d]}+1]]}
        if [[ $__tmp == \(* ]]; then eval "__dscr=$__tmp"
        else __dscr=( "${(@P)__tmp}" ); fi
    fi
    # THE TRICK: builtin compadd with -A (prefix array) -D (matches array) captures WITHOUT
    # inserting into the buffer. We never call real compadd → no menu, no buffer mutation.
    builtin compadd -A __hits -D __dscr "$@"
    setopt localoptions norcexpandparam extendedglob
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
**LIVE-VERIFIED (this session):** this yields `checkout`, `cherry`, `cherry-pick`,
`checkout-index`, `check-attr` for `git ch`. The `-A`/`-D` capture (no real insertion) is the
key — it means the child's buffer is NOT mutated, so the daemon can clear+retype per request.

### 2c. Drive + sentinel sync (Valodim VERBATIM)
```zsh
# child setup also sets:
PROMPT=                                     # NO prompt (minimize pty noise)
bindkey '^M' undefined; bindkey '^J' undefined   # never execute typed text
bindkey '^I' complete-word                       # TAB triggers completion
null-line() { echo -E - $'\0' }              # emit a NUL byte
compprefuncs=( null-line )                   # NUL BEFORE completion output
comppostfuncs=( null-line exit )             # NUL AFTER (Valodim EXITS — one-shot tool!)
zstyle ':completion:*' list-grouped false
zstyle ':completion:*' insert-tab false
zstyle ':completion:*' list-separator ''

# driver: type the command + a TAB; the TAB triggers complete-word; our compadd captures;
# compprefuncs/comppostfuncs bracket the output with NUL bytes:
zpty -w z "$*"$'\t'                          # type cmdline + TAB
# read + toggle between the two NUL bytes:
integer tog=0
while zpty -r z; do :; done | while IFS= read -r line; do
    if [[ $line == *$'\0\r' ]]; then (( tog++ )) && return 0 || continue; fi
    (( tog )) && echo -E - $line
done
```

**Persistent-daemon adaptation (NOT in Valodim — the spike must validate):** Valodim is
one-shot (`comppostfuncs=( null-line exit )`). For a persistent daemon:
- Drop `exit` from `comppostfuncs` → `comppostfuncs=( null-line )` (child stays alive).
- Between requests, RESET the child's zle state + clear the typed line: send Ctrl-C (`\x03`)
  then Ctrl-U (`\x15`) BEFORE typing the next command. (My probe sent both; request-2 still
  needs iteration — see §4 OPEN ITEM.)
- The closing NUL byte (from `null-line` in comppostfuncs) still fires ⇒ the driver's
  read-loop toggle still terminates correctly.

---

## 3. LIVE-VERIFIED probe results (this session)

### Probe A (non-zpty, direct `_main_complete`) → FAILED (zero output)
Confirmed `_main_complete` cannot run without a zle/widget context ⇒ zpty strictly required.

### Probe B (zpty + Valodim compadd, request 1) → PASSED
```
=== REQ1: git ch ===
checkout
cherry-pick
checkout-index
cherry
```
✅ Core capture works. The `-A`/`-D` trick yields real git subcommand completions.

### Probe C (descriptions + jq) → PARTIAL (see §4 OPEN ITEMS)
Words captured; **descriptions came through EMPTY** in my run; pty output polluted with `\r`.

---

## 4. OPEN ITEMS for the folded-in spike (the implementer MUST resolve these)

### O1 — `\r` pty pollution (HIGH — must strip)
The pty's cooked-mode line discipline converts every `\n` → `\r\n`. Captured lines arrive as
`checkout\r`, and spurious `\r` / `\r\r` lines appear. Live JSON output:
```json
{ "value": "\r", "description": "" },
{ "value": "checkout\r", "description": "" }
```
**Fix:** the driver MUST strip trailing `\r` from every captured line + drop empty/whitespace-only
lines BEFORE building JSON. (Valodim's toggle checks `*$'\0\r'` precisely because the NUL is
followed by `\r`.) Apply in the jq pipeline or a zsh `tr -d '\r'`/parameter-strip step.

### O2 — description capture (HIGH — the `-d` handling)
Descriptions came through EMPTY in probe C despite the `${(@P)}` deref. The research brief
flagged that the PRD §17.6.2 sketch has 3 bugs (treats `-d` arg as inline string). Two paths
to try in the spike:
1. **Valodim's exact code** (§2b) — relies on `builtin compadd -D __dscr` to populate the
   description array. May need git's `_describe` to actually pass `-d`.
2. **The `zparseopts` correction** (research brief §2) — strips ALL options cleanly with
   `zparseopts -A opts -D -E -- d: J: V: ...` then derefs `${(@P)opts[-d]}`. More robust.
The spike MUST confirm `git ch` yields `checkout -- Checkout and switch to a branch` (or the
equivalent description) before declaring the driver done. If descriptions prove unattainable
for some completion families, ship WORDS-only (still Tier-1-usable) + document.

### O3 — compinit cold-cache latency (MEDIUM — startup_timeout)
`compinit -u` (cold, no dump) took **~6.4 s** in probe C — exceeds the default
`startup_timeout_ms=5000`. Mitigations:
- Use `compinit -C` (use cached dump, skip security check) — still ~6s on a truly cold cache
  but fast on warm. OR `compinit -d ~/.zcompdump_pi_capture` to pin a dump.
- The driver's `start()` MUST honor `opts.startup_timeout_ms` (passed THROUGH by shell.lua
  ensure, default 5000) and call `on_ready("startup timeout")` if the `__SETUP_OK__` sync
  doesn't arrive in time. Recommend the daemon's own internal timer ≥ the passed budget.
- **Setup-sync MUST accumulate** (read into a growing buffer, check for sentinel) — a
  non-accumulating read loop MISSES the `__SETUP_OK__` marker when compinit is slow (verified:
  my first sync attempt failed for exactly this reason).

### O4 — persistence (request 2 in the same child) (HIGH — must prove)
Probe B proved request 1; request 2 (`git re`) did not yield rebase/reset in my iteration.
The persistent daemon MUST handle ≥3 sequential requests (PRD §17.15 `shell_daemon_spec`:
"spawn → 3 sequential requests → teardown"). The spike MUST validate this. Likely fixes:
- Send Ctrl-C (`\x03`) + Ctrl-U (`\x15`) before each request to reset zle + clear the line.
- Ensure no menu/list is left open (the `-A`/`-D` capture adds no matches ⇒ should be clean,
  but verify; a stray list-selection mode swallows the next TAB).

### O5 — cursor-at-end assumption (LOW — document for v1)
Valodim's `zpty -w z "$cmd"$'\t'` TYPES the command, placing the cursor at END. The request's
`cursor` byte offset is therefore only honored when it equals `#line` (the common pi-prompt
case — user completes the last word). Mid-line cursor completion is OUT OF SCOPE for v1
(PRD §17.1: multi-line/continued is out of scope; mid-word cursor is rarer still). DOCUMENT.
A future enhancement could set BUFFER/CURSOR explicitly via a widget reading the request from
a temp file (research brief §3 Approach A).

---

## 5. The driver ↔ shell.lua contract (from reading lua/pi-bridge/shell.lua — COMPLETE)

`shell.lua` `ensure()` calls `state.driver.start(opts, cb)` where:
- `opts = { shell="/usr/bin/zsh", cwd=<session cwd>, startup_timeout_ms=5000 }`
- `cb(err, proc, stdin, stdout)` — the driver spawns via `vim.uv.spawn`, then on success calls
  `cb(nil, proc, stdin, stdout)` (hands the luv handles back); on failure `cb(err)`.

shell.lua then does `stdout:read_start(... M._feed ...)` — so whatever zsh-A writes to ITS
stdout goes DIRECTLY to `shell._feed`. **There is NO Lua-side parsing layer in the driver.**
Therefore zsh-A's startup script MUST emit the single-JSON-object response format itself:
```
__PIRESP_START__\n{"items":[{"value":"checkout","description":"..."}],"prefix":""}\n__PIRESP_END__\n
```
**CRITICAL:** `shell._feed` decodes the payload as ONE JSON object via `pcall(vim.json.decode)`.
NDJSON / per-line TSV / `word\tdesc` lines **THROW** → counted as a parse failure → after 5
consecutive, the daemon is killed + marked unhealthy (§17.12). So zsh-A MUST build the JSON
(via `jq -R -s`, §6) — it CANNOT emit raw `word\tdesc` lines between the sentinels.

`M.cd(path)` contract: write `cd "<path>"` to the driver (item description point 3c). For zsh,
`M.cd(path)` writes `cd "<path>"\n` to stdin → zsh-A should forward `zpty -w CAP "cd ..."` to
zsh-B AND `cd` itself. (Implement pcall'd; cwd tracking is best-effort.)

---

## 6. JSON building — jq recipe (LIVE-CHECKED, jq 1.8.2)

zsh-A collects the captured `word -- desc` lines (after `\r` strip), then pipes through jq:
```bash
# stdin: newline-delimited "word -- desc" (or bare "word") lines, \r already stripped
jq -R -s '
  split("\n") | map(select(length > 0))
  | map(capture("^(?<value>[^ ]+)( -- (?<description>.*))?$")
        // { value: ., description: "" })
  | { items: map({value, description}), prefix: "" }
'
```
Outputs exactly `{"items":[{"value":"...","description":"..."}],"prefix":""}` — the shape
`shell._feed` + `normalize_item` expect. `prefix` is read by shell._feed from `decoded.prefix`
(default `""`); the consumer `complete_current` may re-derive it from the buffer.

**Pure-zsh fallback (if jq ever absent):** manual escaper (backslash first, then `"`, `\n`,
`\r`, `\t`) + string concat into `{"items":[...],"prefix":""}`. See research brief §8. jq is
present on this target → use jq.

---

## 7. Reference invocation the PRP ships (the spike target)

The implementer writes `tests/shell_zsh_spike.lua` (mirrors `tests/shell_fish_spike.lua`):
spawns `zsh -f` over `vim.uv.spawn` pipes, feeds ONE `__PIREQ__\t{"line":"git ch","cursor":6,"after":""}\n`,
reads stdout until `__PIRESP_END__`, `vim.json.decode`s the payload, asserts `checkout`+`cherry`
present. GATE: proceed iff both appear (else iterate the zsh-side script per §4). Gated on
`vim.fn.executable("zsh")` (skip-exit-0 if absent — PRD §17.15). The zsh-side script is the
artifact of §1–§6 above. Run: `timeout 60 nvim --headless --clean -u NORC +"luafile tests/shell_zsh_spike.lua" +qa`.

---

## 8. AGENTS.md compliance
- NEVER pipe a heredoc into nvim stdin. The spike is a FILE run via `:luafile`. The zsh-side
  script is written to a temp file (`os.tmpname()` or `io.tmpfile`) + sourced, NEVER fed
  line-by-line to nvim. (Line-by-line feeding into zsh's interactive loop ALSO breaks — §2a.)
- Every `nvim`/`uv` call under `timeout` + `pcall`. The `vim.wait(10000, done, 20)` pattern
  from the fish spike bounds the spike's wait loop.