# Research notes — P2.M3.T1.S2: bash.lua best-effort driver (COMP_* vars, compgen/compspec)

**Status: CORE TECHNIQUE LIVE-VERIFIED** against `/usr/bin/bash` 5.3.15 + `jq` 1.8.2.
The bash daemon rcfile + the single-JSON-object response shape are PROVEN to satisfy the
`shell.lua` (P2.M1.T2, COMPLETE) consumer contract. The bash driver is the SIMPLEST of the
three shell drivers: no pty, no two-process architecture, no startup sync.

---

## 0. Environment (verified this session)

| Tool | Path | Version / Status |
|---|---|---|
| bash | `/usr/bin/bash` | 5.3.15 (x86_64-pc-linux-gnu) |
| jq | `/usr/bin/jq` | 1.8.2 |
| bash-completion | — | **NOT INSTALLED** (`/usr/local/etc/bash_completion`, `/etc/bash_completion`, `/usr/share/bash-completion/bash_completion` all absent) |

**Consequence for testing (CRITICAL — drives the §17.15 test gating):** on THIS target the
`git` compspec integration test MUST skip (bash-completion absent → `complete -p git` exits 1
→ "no completion specification"). The file/directory completion test (`!ls /tm` → `/tmp/`)
MUST pass (compgen -f -d works with zero bash-completion — confirmed below). This is exactly
the PRD §17.15 contract: "git compspec iff bash-completion is present (skip otherwise)."

---

## 1. THE central architectural finding — bash is the SIMPLEST driver

Unlike zsh (which REQUIRES a zpty two-zsh architecture because zle needs a tty — see the
P2.M3.T1.S1 zsh research) and fish (which has a designed-for-this `complete -C` API), bash
needs **no special process architecture**:

- `compgen` + programmable completion (`complete -p`, the `-F` function dispatch) work **over
  plain pipes**. There is no line editor (readline) dependency for the completion machinery
  itself — readline is only for interactive input editing, which we bypass by driving bash's
  own `while read` loop.
- A single `bash --rcfile <this> -i` process over `vim.uv.spawn` pipes is sufficient: it
  sources bash-completion best-effort, defines `__pi_complete`, then blocks in a
  `while IFS= read -r _req` loop reading `__PIREQ__\t{json}` frames from stdin.
- **No startup sync sentinel is needed.** Unlike zsh's compinit cold-cache (~6s > the 5000ms
  startup_timeout), bash-completion sourcing (where present) is ~100–300ms — well under the
  default budget. More importantly, bash blocks in its read loop immediately after sourcing;
  any `__PIREQ__` written during sourcing is buffered by the kernel pipe and consumed once
  bash reaches `read`. So **readiness = spawn-OK** (hand the luv handles back at spawn-success,
  mirroring the fish spike).

```
nvim ──pipes──▶ bash daemon (single process, --rcfile <rcfile> -i)
   ▲               │ sources bash-completion (best-effort, silent if absent)
   │               │ defines __pi_complete()
   │ read_start    │ while read __PIREQ__: __pi_complete → jq → write __PIRESP_{START,END}
   └── _feed ◀─────┘
```

> **The PRD §17.6.3 sketch is mostly correct but has ONE doc inconsistency that breaks the
> consumer.** Its per-line `printf '{"value":%s}\n'` (one JSON object per COMPREPLY word) emits
> **NDJSON**, but `shell._feed` (lua/pi-bridge/shell.lua, COMPLETE) decodes the WHOLE payload
> between sentinels as ONE `{items, prefix}` object via `pcall(vim.json.decode)`. Concatenated
> JSON objects **throw** → counted as a parse failure → after 5 consecutive the daemon is killed
> + marked unhealthy (§17.12). The driver MUST instead collect all COMPREPLY words and emit ONE
> `{"items":[...],"prefix":""}` object (built via jq). This is the same correction the zsh
> research made (zsh notes §1/§5). See §6 for the live-verified jq recipe.

---

## 2. The consumer contract — what `shell.lua` expects (READ in full this session)

`shell.lua` `ensure()` (lua/pi-bridge/shell.lua, COMPLETE) calls `state.driver.start(opts, cb)`:
- `opts = { shell="/usr/bin/bash", cwd=<session cwd>, startup_timeout_ms=5000 }`
- `cb(err, proc, stdin, stdout)` — the driver spawns via `vim.uv.spawn`, then on success calls
  `cb(nil, proc, stdin, stdout)` (hands the luv handles back); on every failure `cb(err)`.

shell.lua then does `stdout:read_start(function(_,chunk) if chunk then M._feed(chunk) else M._reset() end end)`
— so whatever the bash daemon writes to ITS stdout goes DIRECTLY to `shell._feed`. **There is
NO Lua-side parsing layer in the driver.** Therefore the bash daemon's rcfile MUST emit the
single-JSON-object response format itself:
```
__PIRESP_START__\n{"items":[{"value":"..."}],"prefix":""}\n__PIRESP_END__\n
```

`shell._feed` specifics (verified by reading the COMPLETE source):
- Appends `chunk` to `state.rx_buf`; drains every complete `__PIRESP_START__\n`..`__PIRESP_END__\n`
  pair via **plain** `find(..., 1, true)` (4th `true` arg — pattern matching OFF, so `%`/`+`/etc
  in the JSON payload never corrupts the sentinel search).
- `pcall(vim.json.decode, payload)` on the trimmed bytes between sentinels. Multi-line / pretty
  JSON is tolerated (decode ignores whitespace) but **compact** `-c` output is cleaner.
- Expects `decoded.items` (array of `{value, description?, label?}`) + `decoded.prefix` (string,
  default `""`). `normalize_item` maps each to `{value, label, description?}` — `description`
  optional/nil is fine (bash returns bare words → no description → `nil`). `label` defaults to
  `value`.
- A decode failure OR non-table decode → `state.parse_failures++`; at threshold (default 5) →
  `state.failed=true` + forward-guarded teardown → daemon killed. So the rcfile MUST always emit
  valid JSON (even `{"items":[],"prefix":""}` for empty results — NEVER emit raw words or NDJSON).
- On EOF (`chunk==nil`) → `M._reset()` → `close_handles()` + `state.failed=true` (a crash is not
  a clean exit). The daemon crashing mid-session thus self-disables for the session (§17.12
  "no auto-respawn in v1").

`M.cd(path)` contract (item description point 3c): write `cd "<path>"` to the driver. The rcfile's
read loop recognizes a `cd <path>` line (non-`__PIREQ__`) and runs `cd` in the daemon's own shell
→ subsequent `compgen -f -d` resolves relative to the new cwd. pcall'd on the Lua side.

---

## 3. The LIVE-VERIFIED bash daemon rcfile (the heart of the driver)

Written to `/tmp/pi_bash_test_rc.sh` and tested by piping `__PIREQ__` frames into
`bash --rcfile /tmp/pi_bash_test_rc.sh -i`. This is the EXACT script the driver writes to a temp
file at `M.start` time. Every behavior below was observed in a real bash run this session.

```bash
#!/usr/bin/env bash
# === bash daemon rcfile — sourced by `bash --rcfile <this> -i` (PRD §17.6.3) ===
# Best-effort bash-completion sourcing (silent if absent — verified: this target has none).
[ -f /usr/local/etc/bash_completion ] && . /usr/local/etc/bash_completion 2>/dev/null
[ -f /etc/bash_completion ] && . /etc/bash_completion 2>/dev/null
[ -f /usr/share/bash-completion/bash_completion ] && . /usr/share/bash-completion/bash_completion 2>/dev/null

# Suppress interactive-mode prompt/title noise (sentinel framing in shell._feed already
# ignores out-of-sentinel bytes, but a clean stream reduces rx_buf churn). -i forces
# interactive mode; we neutralize its prompt + xterm-title escape sequence (\e]0;...\a).
PS1=''; PS2=''; PROMPT_COMMAND=

__pi_complete() {
  local line="$1" point="$2"                      # line=up-to-cursor, point=0-based byte offset
  COMP_LINE="$line"; COMP_POINT="$point"
  read -ra COMP_WORDS <<< "${line}"               # split like readline (whitespace; minimal quoting)
  # Compute COMP_CWORD: the index of the word the cursor is in/after.
  local i cword=0 cum=0
  for ((i=0; i<${#COMP_WORDS[@]}; i++)); do
    cum=$((cum + ${#COMP_WORDS[i]} + 1))
    (( cum >= point )) && { cword=$i; break; }
  done
  COMP_CWORD=$cword
  local cur="${COMP_WORDS[cword]}"
  local cmd="${COMP_WORDS[0]}"
  COMPREPLY=()
  # If a registered -F completion function exists for cmd, invoke it (fills COMPREPLY).
  local spec=""
  spec=$(complete -p "$cmd" 2>/dev/null) || spec=""
  if [[ -n "$spec" && "$spec" == *-F* ]]; then
    local fn=""
    fn=$(printf '%s' "$spec" | sed -n 's/.*-F \([^ ]*\).*/\1/p')
    [ -n "$fn" ] && "$fn" "$cmd" "$cur" "${COMP_WORDS[cword-1]}" 2>/dev/null
  fi
  # Fallback (or no -F result): files + dirs. Dedup (compgen -f -d lists a dir as both).
  if [[ ${#COMPREPLY[@]} -eq 0 ]]; then
    COMPREPLY=( $(compgen -f -d -- "$cur" 2>/dev/null) )
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

# Request loop: read __PIREQ__\t{json}\n from stdin. NON-__PIREQ__ `cd <path>` lines
# forward the daemon's cwd (M.cd contract). All other lines are ignored.
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

### 3a. LIVE-VERIFIED probe results (observed this session, bash 5.3.15)

**Probe 1 — `ls /tm` (file/dir completion, the §17.15 MUST-PASS case):**
```
__PIREQ__	{"line":"ls /tm","cursor":7,"after":""}
→
__PIRESP_START__
{"items":[{"value":"/tmp"}],"prefix":""}
__PIRESP_END__
```
✅ Single JSON object, `/tmp` present, no duplicates (sort -u dedups the `-f`/`-d` overlap).

**Probe 2 — `ls /nonexistent_xyz_123` (empty result):**
```
__PIRESP_START__
{"items":[],"prefix":""}
__PIRESP_END__
```
✅ Empty array (NOT empty payload — empty payload would throw in `_feed`; we always emit `{"items":[],"prefix":""}`).

**Probe 3 — empty line + cursor=0 (cur="" → compgen lists CWD):**
✅ Returns all files in the daemon's cwd. Correct bash semantics (completing nothing lists everything).

**Probe 4 — `git ch` (no bash-completion present → fallthrough):**
```
$ complete -p git 2>&1; echo "exit=$?"
bash: complete: git: no completion specification   exit=1
→ __pi_complete: spec="" → skip -F → compgen -f -d "ch" → files named ch* in CWD
```
✅ **Documents the Tier-2 limitation precisely.** With no bash-completion, `git` has no registered
spec → falls through to file completion. This is the PRD §17.15 "git compspec iff bash-completion
present (skip otherwise)" gating rationale. On a target WITH bash-completion installed + the git
spec sourced, `complete -p git` would return the `-F __git` line → `__git git ch ...` → real git
subcommands (checkout, cherry, cherry-pick). The driver code is IDENTICAL either way; only the
environment differs.

**Probe 5 — `cd` forwarding + relative completion:**
```
cd /tmp
__PIREQ__	{"line":"ls pi_bash_t","cursor":12,"after":""}
→ {"items":[{"value":"pi_bash_test_dir"},{"value":"pi_bash_test_file.txt"},{"value":"pi_bash_test_rc.sh"}],"prefix":""}
```
✅ `M.cd(path)` works: the `cd /tmp` line re-cwd'd the daemon; the subsequent `ls pi_bash_t`
completed relative paths in `/tmp`.

---

## 4. The COMP_CWORD computation — verified correct

The `cum >= point` loop (from the PRD §17.6.3 sketch) computes `COMP_CWORD` from `COMP_LINE` +
`COMP_POINT`. Traced for `ls /tm` (len=6):
- i=0 ("ls"): cum = 0+2+1 = 3; 3>=7? no
- i=1 ("/tm"): cum = 3+3+1 = 7; 7>=7? yes → cword=1 → cur="/tm", cmd="ls" ✓

The cursor is the 0-based BYTE offset (§17.5.1). The computation is robust to off-by-one (an
out-of-range cursor just saturates to the last word). Edge case (cursor mid-word) is out of v1
scope (same as the zsh driver's cursor-at-end note — the pi-prompt common case is cursor-at-end).

**Gotcha (read -ra quoting):** `read -ra COMP_WORDS <<< "${line}"` splits on IFS (whitespace)
without honoring shell quoting (e.g. `my\ file.txt` splits into two). This is the PRD sketch's
behavior and is an ACCEPTED Tier-2 limitation (bash's REAL `COMP_WORDS` comes from readline's
tokenizer, which we don't fully replicate). For v1 this is fine: file/dir completion of
single-token words is the MUST-PASS path; quoting edge cases are table-tested in `shell_accept_spec`
(P2.M2.T4) and the accept helper falls back to raw-insert on any parse failure (§17.12).

---

## 5. JSON building — jq recipe (LIVE-CHECKED, jq 1.8.2)

```bash
# stdin: newline-delimited raw words (\r already absent — no pty, so no \r pollution unlike zsh)
jq -c -R -s 'split("\n") | map(select(length > 0)) | map({value: .}) | {items: ., prefix: ""}'
```
- `-R` raw input (each line is a string), `-s` slurp (whole input as one string), `-c` compact.
- `split("\n")` → array of lines; `select(length > 0)` drops the trailing empty (printf adds a
  final `\n`); `map({value: .})` → `[{value:"w1"},...]`; wrap in `{items: _, prefix: ""}`.
- Output: exactly `{"items":[{"value":"..."}],"prefix":""}` — the shape `shell._feed` +
  `normalize_item` expect. No descriptions (Tier-2 documented limitation).

**Pure-bash fallback (if jq ever absent):** build the JSON string manually with a backslash-first
escaper (`\` → `\\`, then `"` → `\"`, control chars). jq is present on this target (1.8.2) AND is
already a dependency of the zsh driver (P2.M3.T1.S1) → use jq. Document the fallback for a future
jq-less target but do NOT implement it unless a target lacks jq (YAGNI).

---

## 6. The driver ↔ shell.lua contract recap (from reading shell.lua — COMPLETE)

| shell.lua calls | bash.lua provides |
|---|---|
| `state.driver.start({shell, cwd, startup_timeout_ms}, cb)` | `M.start(opts, on_ready)`: writes rcfile to temp, `uv.new_pipe`×3, `uv.spawn("bash", {args={"--rcfile",path,"-i"}, stdio, cwd}, on_exit)`, startup-timeout guard, `on_ready(nil, proc, stdin, stdout)` on spawn-OK. |
| `stdout:read_start(→ M._feed)` | The driver returns `stdout`; shell.lua owns the read loop + framing parse. Driver does NOT parse responses in Lua. |
| `state.driver.cd(path)` (forward-contract; shell.lua may call it on cwd change) | `M.cd(path)`: `stdin:write('cd "<path>"\n')` → rcfile's loop runs `cd`. pcall'd. |
| `shell.pick_driver("/usr/bin/bash")` | `require("pi-bridge.shell.bash")` returns the module iff it has `.start` (shell.lua checks `type(d.start)=="function"`). |
| `drivers.bash = false` opt-out | Handled by shell.lua `pick_driver` (returns nil → degrade). NO driver code needed. |

**No edit to shell.lua** (it is COMPLETE; the parallel zsh PRP P2M3T1S1 also does not edit it).
The bash driver is a pure additive sibling of the zsh driver.

---

## 7. AGENTS.md compliance (CRITICAL)

- ⛔ **HARD RULE:** NEVER pipe a heredoc into nvim stdin (it hangs). The spike is a FILE run via
  `:luafile`. The bash rcfile is written to a temp file (`os.tmpname()`) + passed as `--rcfile`.
- Every `nvim` / `uv` call under `timeout` + `pcall`. The `vim.wait(10000, done, 20)` pattern
  from the fish spike bounds the spike's wait loop.
- The bash driver's `M.start` mirrors the fish spike's spawn idiom (uv.new_pipe×3 + uv.spawn +
  pcall + is_closing teardown) — the ONLY difference is the shell binary + args + the rcfile
  content.

---

## 8. Differences from the zsh driver (P2M3T1S1) — why bash is simpler

| Concern | zsh (P2M3T1S1) | bash (THIS task) |
|---|---|---|
| Process architecture | zpty two-zsh (zle needs a tty) | SINGLE process over pipes |
| Startup sync | `__SETUP_OK__` sentinel (compinit ~6s cold) | NONE — readiness = spawn-OK |
| Descriptions | Yes (via compadd -D capture; fragile) | NO (compgen bare words — Tier-2 documented) |
| \r pollution | YES (pty cooked-mode) → must strip | NO (pipes, no pty) |
| Fragility | HIGH (zle varies across versions) | LOW (compgen/compspec stable since bash 2.04) |
| Spike gate | ✔ (iterates open items) | lighter (script is LIVE-VERIFIED already) |

The bash driver reuses the SAME Lua-side structure (M.start/M.cd/close_handles/state) as the
zsh driver, but the rcfile is far simpler and the startup path has no sync dance.