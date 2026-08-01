# Research — zsh.lua & bash.lua quote/empty graceful-degrade guard (Issue 6, S2)

Sibling of `P1M2T6.S1` (fish, complete). This task replicates the fish guard in the zsh and
bash drivers. This note records the per-shell specifics that DIFFER from fish, so the PRP can
give exact code + placement without the implementer re-deriving them.

---

## §1 The extraction mechanism (identical net effect to fish → dangling backslash)

Both drivers extract `.line` via **parameter substitution** (NOT a regex like fish):

**zsh.lua `OUTER_SCRIPT`** (the `(__PIREQ__*)` case branch):
```zsh
local payload="${req#__PIREQ__	}"
local cmd="${${payload#*\"line\":\"}%%\"*}"
```

**bash.lua `DAEMON_SCRIPT`** (the `__pi_handle` function, `(__PIREQ__*)` case branch):
```bash
local payload="${line_in#__PIREQ__	}"
local line="${payload#*\"line\":\"}"; line="${line%%\"*}"
local cursor="${payload#*\"cursor\":}"; cursor="${cursor%%[!0-9]*}"
cursor="${cursor:-0}"
```

NOTE the **variable-name divergence**: zsh stores the extracted command in **`cmd`**; bash
stores it in **`line`** (the raw input frame is `line_in`). The guard must reference the
correct name in each file.

### Trace of the headline repro `git "feature`

The bridge encodes the line with `vim.json.encode` (`lua/pi-bridge/shell.lua` M.request step 6,
L878-886), so a literal `"` becomes `\"` in the payload. Payload sent over the wire:
```
__PIREQ__\t{"line":"git \"feature","cursor":11,"after":""}
```

zsh: `${payload#*\"line\":\"}` strips the shortest prefix matching `*"line":"` → leaves
`git \"feature","cursor":11,"after":""}`. Then `${...%%\"*}` strips the LONGEST suffix
matching `"*` (a `"` followed by anything) → the FIRST `"` in the remainder is the one inside
`\"` → leaves `git \`. So **`cmd = "git \"` (trailing backslash)** — exactly like fish.

bash: identical substitution → **`line = "git \"` (trailing backslash)**.

CONCLUSION: the PRD's "resolves to empty" wording is imprecise for zsh/bash — a literal `"`
resolves to a **dangling trailing backslash**, NOT empty. An **empty-only** guard would NOT
catch the headline repro. The guard MUST also catch the odd-trailing-backslash case (parity
check), exactly as the completed fish S1 guard does. This is the single most important finding.

---

## §2 Failure mode per shell (why the guard matters for each)

### fish (S1, done) — empty → FLOOD; trailing-backslash → PANIC + DAEMON DEATH
`complete -C ""` floods; `complete -C "git \"` panics `complete.rs:547` (exit 101) and KILLS
the persistent daemon. The panic is the headline fish concern.

### zsh — empty → FLOOD; trailing-backslash → garbage (NO daemon panic)
The OUTER sends `zpty -w z $'\003'$'\025'"$cmd"$'\t'` (Ctrl-C, Ctrl-U, type cmd, Tab).
- **empty cmd**: Tab pressed on an EMPTY ZLE line → zsh completes EVERYTHING (all commands) →
  the menu floods with hundreds of items. **This is the real zsh flood trigger.**
- **trailing-backslash cmd** (`git \`): zsh ZLE receives a dangling escape. No panic (zsh is
  robust), but the result is garbage/unpredictable — could still flood or return nonsense.
  Guarding it converts the garbage into a clean empty.
- **daemon survives either way** (no panic in zsh). So zsh's "survival" test is a responsiveness
  regression check, not a panic check.

### bash — empty → FLOOD; trailing-backslash → naturally empty (NO flood, NO crash)
`__pi_complete` sets COMP_*; `read -ra COMP_WORDS <<< "$prefix"` with `-r` (RAW, no backslash
processing). For `git \`: COMP_WORDS=(`git\`), COMP_CWORD=0, cur=`git\` →
`compgen -abck -A function -- "git\"` matches NO command (none contains a backslash) → empty.
So bash's trailing-backslash case **naturally degrades to empty** (no flood).
- **empty line**: `(( ${#COMP_WORDS[@]} == 0 )) && COMP_WORDS+=("")` → COMP_WORDS=("") ,
  COMP_CWORD=0, cur="" → `compgen -abck -- ""` → ALL commands → **FLOOD**. This is bash's real
  flood trigger.
- The subshell `( ... ) 2>/dev/null` already isolates a buggy compspec fn (research §10), so no
  crash. The trailing-backslash guard for bash is DEFENSIVE/CONSISTENCY (bash already degrades
  empty-ish), but adding it matches the fish precedent and is robust against any future compspec
  that might explode on a dangling backslash.

NET: the empty guard is the PRIMARY fix for BOTH zsh and bash (the documented flood). The
trailing-backslash guard is REQUIRED to catch the `git "feature` headline repro in zsh (which
extracts to `git \`, not empty), and is harmless+consistent for bash. **Mirror the fish guard
exactly (empty OR odd trailing-backslash) in both.**

---

## §3 The parity check — NATIVE in zsh/bash (NO chop-loop helper needed)

fish needed a regex-free chop-loop (`__pi_trailing_bs`) because fish word-splits an UNquoted
`$cmd` and `string match -r '\\+$' -- $cmd` silently returned nothing. **zsh/bash do NOT have
this problem** — their parameter expansion `${var##pattern}` operates on the whole value
(without word-splitting the result when assigned to a var) and supports bracket classes.

The trailing-backslash run is extracted in ONE expansion:
```bash
local _tail="${cmd##*[^\\]}"
```
`##` = longest prefix match of pattern `*[^\\]` = (any chars)(one non-backslash). Strips
everything up to & INCLUDING the last non-backslash char → leaves the trailing run of
backslashes (or the whole string if it is all backslashes). Then `${#_tail}` is the count, and
odd-ness is `(( ${#_tail} % 2 ))` (true/non-zero when odd).

### Verification matrix (reasoned — confirm empirically in Level 4)
| cmd (runtime)        | `${cmd##*[^\\]}` | `${#}` | `%2` | malformed? |
|----------------------|------------------|--------|------|------------|
| `""` (empty)         | (−)              | (−)    | (−)  | YES (−z)   |
| `git ch`             | `""`             | 0      | 0    | no         |
| `git \`              | `\`              | 1      | 1    | YES        |
| `echo \\`            | `\\`             | 2      | 0    | no (valid) |
| `\` (all backslash)  | `\`              | 1      | 1    | YES        |
| `ls *`               | `""`             | 0      | 0    | no (`*` literal, non-bs) |

GOTCHA: in the VALUE `cmd`, glob metachars (`*`, `?`, `[`) are LITERAL chars; they are only
special on the PATTERN side of `##`. So `ls *` correctly yields tail `""` (the literal `*` is a
non-backslash matched by `[^\\]`). Confirmed safe.

GOTCHA: write the class as `[^\\]` in the SOURCE (inside the `[=[ ]=]` Lua long-string, `\\` is
passed through verbatim to zsh/bash, which interpret `\\` as an escaped backslash → matches a
literal `\`). Do NOT write `[^\]` (an unclosed escape) or `[^\\\\]` (doubly-escaped).

### No `extendedglob` / `extglob` needed
`*` and `[...]` character classes work in DEFAULT zsh/bash parameter expansion. `##` (longest)
and `%%` (longest from end) are core POSIX-ish features. The implementer should still VERIFY
live (zsh 5.9 / bash 5.3), but no shell option must be set.

---

## §4 Placement + the `;;`-inside-`if` trap

Both drivers' request handling is a `case` branch inside a `while read` loop (bash) or
top-level loop (zsh). Adding a guard that does `return` is safe in BASH (its handler is the
FUNCTION `__pi_handle` → `return` exits cleanly) but NOT in zsh (the OUTER_SCRIPT is top-level,
no function → `return` is invalid).

Cleaner + uniform for BOTH: do NOT short-circuit with `return`/`continue`. Instead **wrap the
completion-emission body in `if malformed / else normal`**, where the malformed branch emits
the empty JSON and the existing final `printf`/`echo __PIRESP_END__` are reused. This:
- avoids the `;;`-inside-`if` syntax error (a `;;` placed inside an `if` inside a `case` branch
  leaves the `if` unterminated in bash/zsh — it is NOT valid);
- keeps `echo __PIRESP_START__` / `echo __PIRESP_END__` emitted exactly once per request;
- reuses the existing single-object JSON `printf` with `_items=""` so the empty body is
  byte-identical to what the daemon already emits for a no-results case.

See the PRP's "Implementation Patterns" for the exact recommended structure per file.

---

## §5 Test conventions (diverge from the fish S1 spec)

- **zsh spec** (`tests/shell_zsh_driver_spec.lua`): LIVE block is `pending`-skipped when
  `zsh` absent (PRD §17.15). Uses INLINE spawn/teardown per `it` (no shared helper — UNLIKE the
  fish S1 spec which refactored to `spawn_daemon`/`teardown_daemon`). `startup_timeout_ms=8000`
  (zsh compinit is slow). Sends hand-written frames today.
- **bash spec** (`tests/shell_bash_driver_spec.lua`): LIVE block runs UNCONDITIONALLY ("bash
  universal on Linux"). Also INLINE spawn/teardown. `startup_timeout_ms=5000`.

For the quote test, the frame CANNOT be hand-written reliably (the embedded `"` needs JSON
escaping). Use a `make_frame(line, cursor, after)` helper built with `vim.json.encode` —
byte-identical to `shell.lua` M.request step 6 (the SAME helper the fish S1 spec introduced).
The implementer may either add the shared `spawn_daemon`/`teardown_daemon`/`make_frame`
helpers (fish S1 precedent, cleaner as the suite grows) OR keep INLINE + add just `make_frame`.
Either is acceptable; the requirement is byte-identical frames for the quote case.

---

## §6 Out of scope / do-not-touch

- `M.parse` (pure-Lua parsers) — UNCHANGED in both files (the guard is inside the SOURCE string,
  not the Lua parser; the parsers already handle empty arrays).
- `M.start` / `M.cd` — UNCHANGED.
- `lua/pi-bridge/shell.lua` (the consumer) — UNCHANGED. `_feed` already turns an empty `items`
  array into "no menu items" (shell.lua:~668 `raw_items = ... or {}`).
- The wire protocol — UNCHANGED (the guard emits the same `__PIRESP_START__` / single-object JSON
  / `__PIRESP_END__` shape).
- `fish.lua` — already done in S1; do not touch.
- README / `doc/pi-bridge-shell.txt` — owned by P1.M2.T7.S1 (the changeset-doc sweep). Keep this
  task to zsh.lua + bash.lua + their tests + in-file header comments.