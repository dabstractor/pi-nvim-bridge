# PRP — P1.M2.T6.S2: zsh.lua & bash.lua empty-cmd + quote graceful-degrade guard (Issue 6)

name: "P1.M2.T6.S2 — Graceful-degrade guard in zsh.lua OUTER_SCRIPT + bash.lua DAEMON_SCRIPT"
description: >
  Issue 6 (PRD §17.6.x / §17.15), the zsh/bash half of P1.M2.T6. A `!`/`!!` command line that is
  EMPTY, or contains a literal `"`, makes the zsh and bash completion daemons FLOOD the floating
  menu with every command (or every file) on the system — 100s–1000s of items. This PRP adds the
  SAME graceful-degrade guard the completed fish driver (S1) already ships, adapted to each
  shell's script syntax: detect the malformed extracted command BEFORE the completion engine is
  invoked and emit a clean `{"items":[],"prefix":""}` instead. The guard covers BOTH failure
  modes (empty cmd AND odd-count trailing backslash), because a literal `"` extracts to a
  DANGLING BACKSLASH in zsh/bash too (NOT empty) — an empty-only guard would miss the Issue 6
  headline repro. zsh.lua + bash.lua drivers' `M.parse`/`M.start`/`M.cd` + shell.lua consumer
  are UNCHANGED. fish.lua (S1) is done and untouched.

---

## Goal

**Feature Goal**: When a `!`/`!!` shell line extracts to a `cmd` that is EMPTY or ends with an
**unescaped (odd-count) trailing backslash** — both of which today flood the menu (empty → all
commands/files; a literal `"` → `cmd = "git \"` dangling backslash) — the **zsh** and **bash**
completion daemons emit a clean `{"items":[],"prefix":""}` response instead of invoking the
completion engine, so the user sees "no completions" (graceful degrade) and the daemon stays
responsive. This mirrors the already-shipped fish.lua (S1) guard, in each shell's native syntax.

**Deliverable**:
1. A graceful-degrade guard in the **zsh** `OUTER_SCRIPT` (`lua/pi-bridge/shell/zsh.lua`) inside
   the `(__PIREQ__*)` `case` branch — after the `.line` extraction (`local cmd=...`), wrapping
   the pty-send + capture body so an empty/odd-backslash `cmd` yields `_items=""` → empty JSON.
2. A graceful-degrade guard in the **bash** `DAEMON_SCRIPT` (`lua/pi-bridge/shell/bash.lua`)
   inside `__pi_handle`'s `(__PIREQ__*)` `case` branch — after the `.line`/`.cursor` extraction
   (`local line=...`/`local cursor=...`), wrapping the completion subshell so a malformed `line`
   emits the empty JSON instead of calling `compgen`/`complete -F`.
3. Both guards use the SAME parity test: `malformed = (cmd empty) OR (trailing-backslash count
   is odd)`, computed via the native `${cmd##*[^\\]}` parameter expansion + `(( ${#_tail} % 2 ))`
   (NO chop-loop helper — zsh/bash do not have fish's word-splitting landmine).
4. Updated `KNOWN LIMITATION` header doc-comments in BOTH `zsh.lua` and `bash.lua` reflecting the
   new graceful-empty behavior (no longer "returns all commands").
5. New LIVE cases in `tests/shell_zsh_driver_spec.lua` + `tests/shell_bash_driver_spec.lua`
   (and a smoke check in each `_smoke.lua`) proving: empty line → 0 items; quote-line
   (`git "feature`) → 0 items AND the daemon stays responsive on a follow-up normal request;
   a normal completion still returns real items (no over-suppression).

**Success Definition**: Typing `!git "feature`<Tab> or `!`<Tab> (empty) on a zsh OR bash daemon
no longer floods the menu with hundreds of items; the menu stays empty and the VERY NEXT normal
keystroke (`!git ch`<Tab>) completes instantly from the SAME daemon. All existing + new tests
pass; no handle leak; `M.parse` untouched in both files.

## User Persona

**Target User**: A pi editor user driving `!`/`!!` Bash-Mode shell completion via the zsh or bash
Tier-1/2 driver who types a command containing a literal `"` (e.g. `!git commit -m "wip`<Tab>,
`!echo "feat`<Tab>) or hits Tab on a bare `!`.

**Use Case**: Mid-typing a quoted argument, Tab should either complete sensibly or show nothing
— not flood the floating menu with every command/file on the box.

**Pain Points Addressed**: (1) The all-commands/all-files flood (Issue 6's documented symptom for
zsh/bash); (2) parity with the fish driver (S1) so the three drivers degrade identically.

## Why

- **PRD fidelity**: §17.6.2/§17.6.3 + both driver headers already document this as a KNOWN
  LIMITATION of the crude `.line` parameter-substitution extraction (a true JSON-string parse is
  infeasible in pure zsh/bash without `jq`/`python3`). Issue 6's stated goal is *"converts a
  confusing flood into a clean no-results"*.
- **The documented "guard empty-cmd" fix is necessary but NOT sufficient — same as fish**: the
  headline repro `git "feature` extracts to `cmd = "git \"` (a DANGLING backslash, NOT empty) in
  BOTH zsh and bash (the `%%\"*` longest-suffix strip stops at the escaped quote's backslash).
  So an empty-only guard would still flood/garbage on the Issue 6 headline case. The guard MUST
  also catch the odd-trailing-backslash case (parity check) — exactly as the completed fish S1
  guard does. See research §1 for the byte-level trace.
- **Cross-driver consistency**: fish (S1) already guards both modes. Shipping the same guard in
  zsh/bash makes the three drivers behave identically on the edge (and the bash header already
  notes "fish/zsh share it").
- **Low risk / localized**: a pure-addition guard inside each script's SOURCE string; no change
  to `M.parse`, `M.start`, `M.cd`, shell.lua, or the wire protocol. The consumer already handles
  an empty items array (shell.lua `_feed`: `raw_items = ... or {}`).

## What

### User-visible / behavioral
- A `!`/`!!` line that is empty, or contains a literal `"`, yields an EMPTY completion menu (no
  items) on the zsh AND bash drivers — never a flood.
- Each daemon stays responsive after these inputs; the next normal request completes from the
  same daemon (no respawn).
- Normal completions are UNCHANGED: zsh `!git ch` → checkout/cherry; bash `!ls /tm` → /tmp,
  `!gi` → git, `!ls ` → cwd entries.
- A line legitimately ending in an EVEN number of backslashes (e.g. `!echo \\`, a valid escaped
  backslash) is still passed to the completion engine (no false-positive suppression).

### Success Criteria
- [ ] zsh `OUTER_SCRIPT`: when `cmd` is empty OR has an odd trailing-backslash count, the pty-send
      (`zpty -w z ...`) + capture loop is SKIPPED and `printf '{"items":[%s],"prefix":""\n' ""` is
      emitted (0 items); otherwise the existing capture runs unchanged.
- [ ] bash `DAEMON_SCRIPT`: when `line` is empty OR has an odd trailing-backslash count, the
      completion subshell is SKIPPED and `{"items":[],"prefix":""}` is emitted; otherwise the
      existing `__pi_complete` + compgen/complete -F runs unchanged.
- [ ] The guard fires for the extracted `cmd`/`line` of every quote-containing line tested:
      `git "feature` (cmd `git \`), `"echo` (cmd `\`), `git commit -m "wip` (cmd `git commit -m \`).
- [ ] The guard does NOT fire for `git ch`/`ls /tm`/`gi` (0 trailing BS) or `echo \\` (2 BS, even).
- [ ] zsh LIVE: a quote-frame leaves the daemon responsive — a follow-up normal frame returns
      real items (checkout). bash LIVE: same (the daemon completes a follow-up `ls /tm` → /tmp).
- [ ] Both `KNOWN LIMITATION` header comments are updated (graceful empty, not flood).
- [ ] All existing zsh/bash tests pass; no uv handle leak; `M.parse` untouched in both files.

## All Needed Context

### Context Completeness Check
_"If someone knew nothing about this codebase, would they have everything needed to implement this successfully?"_
Yes — the exact per-shell source locations, the exact (reasoned + to-be-empirically-verified)
guard code, the variable-name divergence (zsh `cmd` vs bash `line`), the `;;`-inside-`if` trap
and the structure that avoids it, the proven end-to-end matrix, and the verified validation
commands are all below + in research/.

### Documentation & References

```yaml
# The canonical bug description this fixes
- docfile: plan/002_d23d7473c16c/bugfix/001_842ac90ede70/prd_snapshot.md
  section: "Issue 6 — Command lines containing a literal \" produce an all-commands flood"
  why: |
    States the goal: a literal `"` (or empty line) → graceful EMPTY result, not a flood. The
    suggested fix ("emit empty when cmd is empty") is NECESSARY but NOT SUFFICIENT — a literal
    `"` extracts to a trailing-backslash cmd (NOT empty) in zsh/bash too. See research §1.
  critical: |
    The headline repro is `git "feature`, which extracts to `cmd = "git \"` (trailing backslash)
    in BOTH zsh and bash. An empty-only guard does NOT fix the headline repro. The guard here
    MUST also catch the odd-trailing-backslash case (parity check).

# THE SIBLING REFERENCE — the completed fish guard (S1). Read it + its research note first.
- file: lua/pi-bridge/shell/fish.lua
  why: |
    The already-shipped fish guard (commit 47fec6e). Its `__pi_handle` graceful-degrade block
    (empty OR odd trailing-backslash → `{"items":[],"prefix":""}`) is the EXACT behavior to
    replicate in zsh/bash, translated to each shell's syntax. fish needed a `__pi_trailing_bs`
    chop-loop helper because of fish's quoting; zsh/bash do NOT (use native `${cmd##*[^\\]}`).
  pattern: "Mirror the fish guard's INTENT + the START/empty-JSON/END emission shape verbatim."
- docfile: plan/002_d23d7473c16c/bugfix/001_842ac90ede70/P1M2T6S1/research/fish_quote_flood_panic_findings.md
  why: "The parity reasoning + the 'empty-only is not enough' proof (§2/§3). Same logic applies."

# FILE 1 TO MODIFY — zsh driver. Read the WHOLE OUTER_SCRIPT before editing.
- file: lua/pi-bridge/shell/zsh.lua
  why: |
    The zsh driver. `OUTER_SCRIPT` (a Lua `[=[ ... ]=]` long-string) is spawned as
    `zsh -f <outer_tmp> <inner_tmp>`. The `(__PIREQ__*)` `case` branch (inside the final
    `while IFS= read -r req; do case ... esac; done` loop) extracts `.line` into `cmd` then
    sends `zpty -w z $'\003'$'\025'"$cmd"$'\t'` + captures between PISTART/PIEND sentinels +
    `printf '{"items":[%s],"prefix":""\n' "$_items"`.
  pattern: |
    Place the guard AFTER `local cmd="${${payload#*\"line\":\"}%%\"*}"` and BEFORE
    `echo __PIRESP_START__`. Wrap the pty-send + capture in `if [[ -n "$cmd" ]] && (( ${#_tail} % 2 == 0 )); then ... fi`
    so a malformed `cmd` leaves `_items=""` and the existing final printf emits empty. The
    `_tail="${cmd##*[^\\]}"` parity extraction goes right after the `cmd` extraction.
  gotcha: |
    `OUTER_SCRIPT` is a Lua `[=[ ... ]=]` long-string (level-1 brackets — the INNER_SCRIPT uses
    the SAME level-1 brackets; they do NOT nest, they are SEPARATE strings). NONE of its `\n`/`\t`/`\\`
    are interpreted by Lua — they are LITERAL zsh source. Do NOT Lua-escape the zsh escapes. The
    OUTER is top-level (NOT a function) → you CANNOT `return` out of it; use the `if/then/else/fi`
    wrap (a `;;` placed inside an `if` inside a `case` branch is a syntax error — see research §4).
  critical: |
    The extracted-command variable is named `cmd` in zsh (NOT `line`). Reference `$cmd`.

# FILE 2 TO MODIFY — bash driver. Read the WHOLE DAEMON_SCRIPT before editing.
- file: lua/pi-bridge/shell/bash.lua
  why: |
    The bash driver. `DAEMON_SCRIPT` (a Lua `[=[ ... ]=]` long-string — level-1 brackets REQUIRED
    because bash's `[[:space:]]` regex contains `]]`) is spawned as `bash <tmp>`. `__pi_handle`'s
    `(__PIREQ__*)` `case` branch extracts `.line` into `line` + `.cursor`, then emits
    `__PIRESP_START__`, runs completion in a subshell `( __pi_complete ...; printf ... ) 2>/dev/null`,
    then emits `__PIRESP_END__`.
  pattern: |
    Place the guard AFTER `local cursor="${cursor:-0}"` and BEFORE `echo __PIRESP_START__`. Wrap
    the completion subshell in `else`: `if [[ -z "$line" || (( ${#_tail} % 2 )) ]]; then printf '{"items":[],"prefix":""}\n'; else ( ...subshell... ) fi`.
    The `_tail="${line##*[^\\]}"` parity extraction goes right after the `cursor` extraction.
  gotcha: |
    The extracted-command variable is named `line` in bash (the raw input frame is `line_in`).
    Reference `$line`, NOT `$cmd`. bash `read -ra` uses `-r` (raw) so a trailing-backslash `line`
    already degrades to ~empty naturally (research §2) — the guard is still added for consistency
    + to catch the genuine empty-line FLOOD + to be robust against a future compspec that explodes.
  critical: |
    `__pi_handle` is a FUNCTION → `return` IS valid in bash (unlike zsh's top-level OUTER). But
    for uniformity + minimal diff, prefer the `if/then/else/fi` wrap (no `return`, no `;;`-in-`if`).

# The consumer (NO CHANGE — confirms an empty items array is handled)
- file: lua/pi-bridge/shell.lua
  why: |
    M._feed decodes the daemon's single-object JSON; `raw_items = (type(decoded.items) == "table")
    and decoded.items or {}` (~L668). An empty `items` → `normalize_item` produces nothing → the
    menu shows empty / closes. So emitting `{"items":[],"prefix":""}` is a clean degrade.
  critical: Confirm this by reading it, but DO NOT modify shell.lua (out of scope; already correct).

# THE TEST files to extend
- file: tests/shell_zsh_driver_spec.lua
  why: |
    plenary spec for the REAL zsh driver. Has an offline-contract `describe` + a
    `describe("LIVE driver (gated on zsh on PATH)")` (pending-skipped when `zsh` absent — PRD §17.15).
    The LIVE "git ch → checkout" case spawns the real daemon, wires stdout, sends a hand-written
    frame, decodes. Uses INLINE spawn/teardown per `it` + `startup_timeout_ms=8000` (zsh compinit slow).
  pattern: |
    Add LIVE `it`s mirroring that case: (a) empty-line frame → assert decoded.items == {}; (b)
    quote-frame `git "feature` → assert == {} THEN a follow-up `git ch` frame on the SAME daemon →
    assert `checkout` present (proves responsiveness). Build frames with a `make_frame(line,cursor,after)`
    helper (vim.json.encode) — byte-identical to shell.lua M.request; a hand-written frame CANNOT
    represent the embedded `"` correctly.
- file: tests/shell_bash_driver_spec.lua
  why: |
    plenary spec for the REAL bash driver. LIVE block runs UNCONDITIONALLY ("bash universal on
    Linux"). INLINE spawn/teardown + `startup_timeout_ms=5000`. Existing cases: `ls /tm` → /tmp,
    `gi` → git, `ls ` → cwd entries.
  pattern: |
    Add LIVE `it`s: (a) empty-line → 0 items; (b) quote-frame `git "feature` → 0 items THEN a
    follow-up `ls /tm` → assert `/tmp` present (proves responsiveness). Same `make_frame` helper.
- file: tests/shell_zsh_driver_smoke.lua
- file: tests/shell_bash_driver_smoke.lua
  why: |
    plenary-FREE smoke (file-based; run via +"luafile ..."). Same LIVE-gated shape + `check(c,msg)`.
    Add a graceful-degrade + responsiveness check (empty → 0 items; quote → 0 items; follow-up
    normal → real item) mirroring the fish S1 smoke addition.
  gotcha: |
    ⛔ AGENTS.md HARD RULE: run via +"luafile tests/<file>_smoke.lua" +qa. NEVER heredoc to nvim
    stdin (it hangs the session). Every nvim call bounded by `timeout`.

# This task's research note (READ IT — the per-shell failure modes + the parity-check matrix)
- docfile: plan/002_d23d7473c16c/bugfix/001_842ac90ede70/P1M2T6S2/research/zsh_bash_quote_flood_findings.md
  section: "§1 extraction trace" + "§2 failure mode per shell" + "§3 the parity check"
  why: |
    The byte-level trace proving `git "feature` → `cmd = "git \"` (dangling backslash, NOT empty)
    in BOTH shells; why an empty-only guard fails the headline repro; the `${cmd##*[^\\]}` +
    `(( ${#_tail} % 2 ))` parity idiom (with a 6-row verification matrix); the `;;`-inside-`if` trap.
```

### Current Codebase tree (relevant slice)

```bash
lua/pi-bridge/shell/
  zsh.lua             # MODIFIED — OUTER_SCRIPT: add the graceful-degrade guard (wrap pty-send +
                      #            capture in if/then/fi on cmd parity); update the KNOWN
                      #            LIMITATION header comment. (M.parse/start/cd UNCHANGED)
  bash.lua            # MODIFIED — DAEMON_SCRIPT: add the graceful-degrade guard (wrap completion
                      #            subshell in if/then/else/fi on line parity); update the KNOWN
                      #            LIMITATION header comment. (M.parse/start/cd UNCHANGED)
tests/
  shell_zsh_driver_spec.lua   # MODIFIED — add LIVE graceful-degrade + responsiveness cases
  shell_bash_driver_spec.lua  # MODIFIED — add LIVE graceful-degrade + responsiveness cases
  shell_zsh_driver_smoke.lua  # MODIFIED — add a plenary-free graceful-degrade smoke check
  shell_bash_driver_smoke.lua # MODIFIED — add a plenary-free graceful-degrade smoke check
```

### Known Gotchas of our codebase & Library Quirks

```bash
# CRITICAL: the PRD's "guard empty-cmd" is NECESSARY but NOT SUFFICIENT (same as fish). The
#   headline repro `git "feature` extracts to `cmd = "git \"` (a TRAILING BACKSLASH, NOT empty)
#   in BOTH zsh and bash — the `%%\"*` longest-suffix strip stops at the escaped quote's `\`.
#   An empty-only guard leaves the flood/garbage for the headline case. The guard MUST also
#   catch the odd-trailing-backslash case (parity check).

# CRITICAL (variable-name divergence): the extracted command is `cmd` in zsh.lua OUTER_SCRIPT
#   but `line` in bash.lua DAEMON_SCRIPT (the raw frame is `line_in`). Reference the RIGHT name
#   in each file or the guard silently tests the wrong value.

# GOTCHA: detect trailing-backslash PARITY, not mere presence. `echo \\` (two backslashes) is a
#   VALID escaped backslash (must NOT be suppressed). Only an ODD trailing count is malformed.
#   The idiom: `_tail="${cmd##*[^\\]}"` (the trailing backslash run) + `(( ${#_tail} % 2 ))`
#   (true when odd). NO chop-loop helper needed (unlike fish) — zsh/bash `${var##pat}` does not
#   word-split the value the way an UNquoted fish `$cmd` does.

# CRITICAL (the `;;`-inside-`if` trap): do NOT place `;;` inside an `if ... fi` that lives in a
#   `case` branch — it leaves the `if` unterminated (syntax error). And do NOT `return` out of
#   the zsh OUTER (it is top-level, not a function). Instead WRAP the completion body in
#   `if malformed; then <empty JSON>; else <existing body>; fi` so START/JSON/END are still
#   emitted exactly once. (bash `__pi_handle` IS a function so `return` would work there too,
#   but use the same if/else wrap for uniformity + minimal diff.)

# GOTCHA: the scripts are Lua `[=[ ... ]=]` long-strings — their content is LITERAL zsh/bash
#   source. Write `[^\\]` exactly (the `\\` is passed verbatim to the shell, which reads it as
#   an escaped backslash = matches literal `\`). Do NOT write `[^\]` (unclosed) or `[^\\\\]`.

# GOTCHA: the guard is inside each shell's SOURCE string → NOT offline-testable (unlike M.parse,
#   the pure-Lua parser). Tests MUST be gated on the shell on PATH (zsh: pending-skip when absent;
#   bash: runs unconditionally but still defensive-checks `executable`). The offline Level-1 load
#   gate catches only LUA-syntax regressions (a bad `[=[ ]=]` bracket), not shell-syntax errors.

# CRITICAL (AGENTS.md HARD RULE): write every lua test SNIPPET to a real FILE (tests/* or /tmp/*.lua)
#   then run via +"luafile <path>" +qa. NEVER pipe a heredoc into nvim stdin (it hangs forever).
#   Every nvim invocation gets a bounded `timeout`.
```

## Implementation Blueprint

### Data models and structure

No new data models. The fix is entirely inside each driver's embedded shell-source string (a Lua
long-string). Each adds one local (`_tail`) + an `if/then/else/fi` guard that wraps the existing
completion body. No Lua-side state, no new config key, no shell.lua change, no `M.parse` change.

### Implementation Tasks (ordered by dependencies)

```yaml
Task 1: MODIFY lua/pi-bridge/shell/zsh.lua — add the graceful-degrade guard in OUTER_SCRIPT
  - FIND: in OUTER_SCRIPT, the final `while IFS= read -r req; do case "$req" in ... esac; done`
          loop, and inside it the `(__PIREQ__*)` branch. Today it is:
              (__PIREQ__*)
                  local payload="${req#__PIREQ__	}"
                  local cmd="${${payload#*\"line\":\"}%%\"*}"
                  echo __PIRESP_START__
                  zpty -w z $'\003'$'\025'"$cmd"$'\t'
                  local _items="" _first=1 _cap=0 _drained=0 _tries=0
                  while (( _tries++ < 1000 )); do
                      ... existing capture body ...
                  done
                  printf '{"items":[%s],"prefix":""}\n' "$_items"
                  echo __PIRESP_END__
                  ;;
  - RESTRUCTURE into (wrap the pty-send + capture in the parity guard; reuse the final printf
          with `_items=""` for the empty case — MINIMAL diff, no duplicated echo, no `;;`-in-`if`):
              (__PIREQ__*)
                  local payload="${req#__PIREQ__	}"
                  local cmd="${${payload#*\"line\":\"}%%\"*}"
                  # === GRACEFUL-DEGRADE GUARD (Issue 6 / PRD §17.6.x) ===
                  # The crude `.line` extraction cannot parse a JSON-escaped `\"`, so a line
                  # containing a literal `"` leaves a DANGLING backslash at the end of `cmd`
                  # (e.g. `git "feature` → `git \`). And an EMPTY line → Tab on an empty ZLE
                  # line floods EVERY command. Skip the pty completion on a malformed `cmd`
                  # (empty OR odd-count trailing backslash; an EVEN run like `echo \\` is a
                  # valid escaped backslash, kept) so `_items` stays "" → a clean empty result.
                  local _tail="${cmd##*[^\\]}"
                  echo __PIRESP_START__
                  local _items=""
                  if [[ -n "$cmd" ]] && (( ${#_tail} % 2 == 0 )); then
                      local _first=1 _cap=0 _drained=0 _tries=0
                      zpty -w z $'\003'$'\025'"$cmd"$'\t'
                      while (( _tries++ < 1000 )); do
                          ... existing capture body, UNCHANGED ...
                      done
                  fi
                  printf '{"items":[%s],"prefix":""}\n' "$_items"
                  echo __PIRESP_END__
                  ;;
  - PRESERVE: the existing capture body verbatim (only its leading `local _first=1 ...` +
          `zpty -w z ...` + the `while` loop get indented into the `if`); the `__PICD*) ;;`
          branch; INNER_SCRIPT; M.parse; M.start; M.cd; everything outside OUTER_SCRIPT.
  - DO NOT: add a `return` (OUTER is top-level, not a function) or a bare `;;` inside the `if`.

Task 2: MODIFY lua/pi-bridge/shell/bash.lua — add the graceful-degrade guard in DAEMON_SCRIPT
  - FIND: in DAEMON_SCRIPT, the `__pi_handle()` function and its `(__PIREQ__*)` case branch:
              (__PIREQ__*)
                  local payload="${line_in#__PIREQ__	}"
                  local line="${payload#*\"line\":\"}"; line="${line%%\"*}"
                  local cursor="${payload#*\"cursor\":}"; cursor="${cursor%%[!0-9]*}"
                  cursor="${cursor:-0}"
                  echo __PIRESP_START__
                  (
                      __pi_complete "$line" "$cursor"
                      local _items="" _first=1 w
                      for w in "${COMPREPLY[@]}"; do
                          [ -z "$w" ] && continue
                          local _it="{\"value\":$(__pi_json_str "$w")}"
                      if ((_first)); then _items="$_it"; _first=0; else _items="${_items},${_it}"; fi
                      done
                      printf '{"items":[%s],"prefix":""}\n' "$_items"
                  ) 2>/dev/null
                  echo __PIRESP_END__
                  ;;
  - RESTRUCTURE into (wrap the subshell in `else`; the malformed branch printf's empty):
              (__PIREQ__*)
                  local payload="${line_in#__PIREQ__	}"
                  local line="${payload#*\"line\":\"}"; line="${line%%\"*}"
                  local cursor="${payload#*\"cursor\":}"; cursor="${cursor%%[!0-9]*}"
                  cursor="${cursor:-0}"
                  # === GRACEFUL-DEGRADE GUARD (Issue 6 / PRD §17.6.x) ===
                  # The crude `.line` extraction cannot parse a JSON-escaped `\"`, so a line
                  # containing a literal `"` leaves a DANGLING backslash at the end of `line`
                  # (e.g. `git "feature` → `git \`). And an EMPTY line → `compgen -abck -- ""`
                  # floods EVERY command. Emit a clean empty result for a malformed `line`
                  # (empty OR odd-count trailing backslash; an EVEN run like `echo \\` is a
                  # valid escaped backslash, kept) instead of invoking compgen/complete -F.
                  local _tail="${line##*[^\\]}"
                  echo __PIRESP_START__
                  if [[ -z "$line" ]] || (( ${#_tail} % 2 )); then
                      printf '{"items":[],"prefix":""}\n'
                  else
                      (
                          __pi_complete "$line" "$cursor"
                          local _items="" _first=1 w
                          for w in "${COMPREPLY[@]}"; do
                              [ -z "$w" ] && continue
                              local _it="{\"value\":$(__pi_json_str "$w")}"
                          if ((_first)); then _items="$_it"; _first=0; else _items="${_items},${_it}"; fi
                          done
                          printf '{"items":[%s],"prefix":""}\n' "$_items"
                      ) 2>/dev/null
                  fi
                  echo __PIRESP_END__
                  ;;
  - PRESERVE: the `(__PICD__*)` branch (REAL cd — do not touch); `__pi_complete`; `__pi_json_str`;
          the bash-completion sourcing loop; M.parse; M.start; M.cd; everything outside the
          `(__PIREQ__*)` branch. NOTE bash's variable is `line` (NOT `cmd`).

Task 3: MODIFY lua/pi-bridge/shell/zsh.lua — update the KNOWN LIMITATION header doc-comment
  - FIND: the header bullet currently reads (inside the `KNOWN LIMITATIONS (documented; v1
          accepts ...)` block):
        --      - A command line containing a literal `"` breaks the OUTER's crude `.line`
        --        extraction → cmd resolves empty → an empty/all-commands result (graceful
        --        degrade, not a crash). A true JSON-string parse is infeasible in zsh; v1 accepts this edge.
  - REPLACE with (accurate to the NEW behavior):
        --      - GRACEFUL DEGRADE (Issue 6): a command line containing a literal `"` (or an
        --        empty line) breaks the OUTER's crude `.line` extraction (`git "feature` → cmd
        --        `git \`, a DANGLING backslash). The `(__PIREQ__*)` branch now GUARDS `cmd`
        --        BEFORE the pty completion: an empty `cmd` (→ all-commands FLOOD) or one ending
        --        in an ODD run of backslashes (the dangling-`\` case) emits a clean EMPTY
        --        `{"items":[],"prefix":""}` instead. An EVEN run (`echo \\`) is a valid escaped
        --        backslash, kept. A true JSON-string parse is infeasible in zsh; the guard
        --        converts the edge into a graceful no-results.
  - DO NOT change the other KNOWN LIMITATIONS bullets (`-f` skips ~/.zshrc; cd advisory) — still accurate.

Task 4: MODIFY lua/pi-bridge/shell/bash.lua — update the KNOWN LIMITATION header doc-comment
  - FIND: the header bullet currently reads (inside the DIVERGENCE FROM PRD §17.6.3 SKETCH block):
        --    KNOWN LIMITATION: a command line containing a literal `"` breaks the crude `.line`
        --      extraction → line resolves empty → `compgen -abck` returns all commands (graceful
        --      degrade, not a crash; research §9). A true JSON-string parse is infeasible in pure
        --      bash without `jq`/`python3`; v1 accepts this edge (fish/zsh share it).
  - REPLACE with (accurate to the NEW behavior):
        --    GRACEFUL DEGRADE (Issue 6): a command line containing a literal `"` (or an empty
        --      line) breaks the crude `.line` extraction (`git "feature` → `line` `git \`, a
        --      DANGLING backslash — NOT empty). `__pi_handle`'s `(__PIREQ__*)` branch now GUARDS
        --      `line` BEFORE the completion subshell: an empty `line` (→ `compgen -abck -- ""`
        --      FLOOD) or one ending in an ODD run of backslashes (the dangling-`\` case) emits a
        --      clean EMPTY `{"items":[],"prefix":""}` instead. An EVEN run (`echo \\`) is a valid
        --      escaped backslash, kept. A true JSON-string parse is infeasible in pure bash
        --      without `jq`/`python3`; the guard converts the edge into a graceful no-results.
  - DO NOT change the other DIVERGENCE bullets (pure-bash JSON; single-object; §3 COMP_CWORD;
          cword==0 compgen -abck) — still accurate.

Task 5: MODIFY tests/shell_zsh_driver_spec.lua — add LIVE graceful-degrade + responsiveness cases
  - FIND: the `describe("LIVE driver (gated on zsh on PATH)")` block + its existing
          "start → on_ready + 'git ch' → checkout" `it` (INLINE spawn/teardown idiom).
  - ADD a `make_frame(line, cursor, after)` file-local helper (vim.json.encode; byte-identical
          to shell.lua M.request step 6 — the fish S1 spec introduced the SAME helper). Then add
          (optionally refactor the existing `it`s to a shared `spawn_daemon`/`teardown_daemon`,
          mirroring the fish S1 spec — NOT required, but reduces duplication):
      (a) "empty line → empty items (no flood)": spawn; wire stdout (rx_buf + try_parse);
          write `make_frame("", 0, "")`; vim.wait decoded; assert `#decoded.items == 0` (NOT
          hundreds). teardown.
      (b) "quote-line → empty items AND daemon stays responsive (no flood)": spawn; wire stdout
          with a rx_buf loop that drains EVERY START/END pair (a chunk may carry both frames —
          copy the fish S1 spec's drain loop). write `make_frame('git "feature', 11, "")` →
          assert `#r_quote == 0`. THEN write `make_frame("git ch", 6, "")` on the SAME daemon →
          assert `checkout` IS present (proves the daemon stayed responsive; if the quote had
          wedged the pty, the follow-up hangs → timeout → nil → assert fails). teardown.
  - KEEP `after_each` (`package.loaded["pi-bridge.shell.zsh"]=nil`). Keep `startup_timeout_ms=8000`.

Task 6: MODIFY tests/shell_bash_driver_spec.lua — add LIVE graceful-degrade + responsiveness cases
  - FIND: the `describe("LIVE driver (bash universal on Linux — runs UNCONDITIONALLY)")` block +
          its existing `it`s (`ls /tm` → /tmp; `gi` → git; `ls ` → cwd). INLINE spawn/teardown.
  - ADD the same `make_frame` helper. Add:
      (a) "empty line → empty items (no flood)": `make_frame("", 0, "")` → assert `#items == 0`.
      (b) "quote-line → empty items AND daemon stays responsive": `make_frame('git "feature', 11, "")`
          → `#r_quote == 0`; THEN `make_frame("ls /tm", 6, "")` → assert `/tmp` present (proves
          responsiveness). Same rx_buf drain loop as (5b).
  - KEEP `after_each` (`package.loaded["pi-bridge.shell.bash"]=nil`). bash runs UNCONDITIONALLY.

Task 7: MODIFY tests/shell_zsh_driver_smoke.lua + tests/shell_bash_driver_smoke.lua — graceful-degrade smoke
  - FIND: each file's sequential-request section + the existing `request(line,cursor,after,cb)` +
          `check(c,msg)` idiom (and the LIVE-gate `SMOKE_SKIP` when the shell is absent).
  - ADD a section after the existing requests: send an empty-line frame → `check(#items == 0)`;
          send a quote-frame `make_frame('git "feature', 11, "")` → `check(#items == 0)`; THEN send
          a normal frame (zsh: `"git ch"`; bash: `"ls /tm"`) → assert a real item present
          (zsh: `checkout`; bash: `/tmp`). Build frames via vim.json.encode.
  - ⛔ Run via +"luafile tests/<file>_smoke.lua" +qa (AGENTS.md HARD RULE).
```

### Implementation Patterns & Key Details

```lua
-- PATTERN: build a request frame byte-for-byte like shell.lua M.request (avoids hand-escaping
-- the embedded quote in the spec/smoke). SAME encoding M.request step (6) uses (L878-886):
local function make_frame(line, cursor, after)
    local l_str = vim.json.encode(line)        -- 'git "feature' -> '"git \\"feature"'
    local a_str = vim.json.encode(after or "")
    local payload = string.format("{\"line\":%s,\"cursor\":%d,\"after\":%s}", l_str, cursor, a_str)
    return string.format("__PIREQ__\t%s\n", payload)
end
-- then: stdin:write(make_frame('git "feature', 11, ""))
-- This guarantees the frame the test sends is IDENTICAL to what a real keystroke produces.

-- PATTERN: the zsh parity guard (the whole deliverable for Task 1; copy into OUTER_SCRIPT at the
-- (__PIREQ__*) branch). NOTE: this is zsh source inside a Lua [=[ ]=] string; `[^\\]` is passed
-- verbatim to zsh (which reads `\\` as an escaped backslash). The extracted-command var is `cmd`.
#   local _tail="${cmd##*[^\\]}"        # trailing backslash run (whole string if all-backslash)
#   echo __PIRESP_START__
#   local _items=""
#   if [[ -n "$cmd" ]] && (( ${#_tail} % 2 == 0 )); then
#       <existing zpty -w z ... + while-capture, UNCHANGED>
#   fi
#   printf '{"items":[%s],"prefix":""}\n' "$_items"     # _items=="": clean EMPTY body
#   echo __PIRESP_END__

-- PATTERN: the bash parity guard (Task 2; copy into __pi_handle's (__PIREQ__*) branch). The
-- extracted-command var is `line` (NOT cmd). bash runs completion in a subshell (research §10).
#   local _tail="${line##*[^\\]}"
#   echo __PIRESP_START__
#   if [[ -z "$line" ]] || (( ${#_tail} % 2 )); then
#       printf '{"items":[],"prefix":""}\n'
#   else
#       ( <existing __pi_complete + COMPREPLY for-loop + printf JSON, UNCHANGED> ) 2>/dev/null
#   fi
#   echo __PIRESP_END__

-- CRITICAL reasoning (cite in the code comment): the `.line` parameter substitution
#   `${payload#*\"line\":\"}` ... `%%\"*` strips up to the FIRST `"` after the value opens. For a
#   value containing `\"`, that first `"` is the ESCAPED one (right after a `\`), so the capture
#   stops there, leaving a dangling `\` at the end of `cmd`/`line`. An EVEN run (`echo \\`) is a
#   properly-escaped backslash → safe → NOT suppressed. Odd run = dangling → suppressed. Empty
#   `cmd`/`line` → the completion engine with a "" prefix floods → suppressed.

-- PATTERN: the LIVE spec case shape (mirror the existing cases): spawn driver.start({...},
#   on_ready) → vim.wait ready → wire stdout read_start (rx_buf + a drain loop that decodes EVERY
#   START/END pair) → stdin:write(make_frame(...)) → vim.wait decoded → assert → teardown
#   (kill+close handles). For the responsiveness case, send TWO frames on the SAME daemon; the
#   rx_buf drain loop must decode BOTH in arrival order (copy the fish S1 spec's drain loop).

-- GOTCHA: zsh `${cmd##*[^\\]}` and bash `${line##*[^\\]}` — VERIFY live against the §3 matrix in
--   research (zsh 5.9 / bash 5.3). `*[^\\]` uses only basic glob features (no extendedglob /
--   extglob needed). If a shell version surprises you, fall back to a `case`/regex parity test,
--   but the parameter expansion is expected to work unchanged.
```

### Integration Points

```yaml
OUTER_SCRIPT (lua/pi-bridge/shell/zsh.lua):
  - add: parity guard wrapping the pty-send + capture in the (__PIREQ__*) case branch (cmd parity)
  - update: the KNOWN LIMITATION header doc-comment (flood → graceful empty)

DAEMON_SCRIPT (lua/pi-bridge/shell/bash.lua):
  - add: parity guard wrapping the completion subshell in __pi_handle's (__PIREQ__*) branch (line parity)
  - update: the KNOWN LIMITATION header doc-comment (flood → graceful empty)

CALL GRAPH (no new edges):
  - The guard is PURELY local to each (__PIREQ__*) branch (a `${var##...}` + arithmetic test).
    No new function, no new helper (unlike fish's __pi_trailing_bs).
  - The wire protocol is UNCHANGED: both still emit __PIRESP_START__ / single-object JSON /
    __PIRESP_END__ (the EXACT shape shell.lua _feed already decodes; the empty case reuses the
    existing printf with _items="" or a literal {"items":[],"prefix":""}).

CONSUMER (lua/pi-bridge/shell.lua): NO CHANGE. _feed + normalize_item already turn an empty items
  array into "no menu items". (Confirm by reading shell.lua:~668; do not edit it.)

DOCUMENTATION: in-file header comments only (the two KNOWN LIMITATION bullets). P1.M2.T7.S1 owns
  the README/doc/pi-bridge-shell.txt changeset sweep — do NOT edit those here (or keep any touch to
  a single "literal `"` / empty line degrades to an empty result" sentence).

CONFIG: none (§17.11 defines no toggle; the guard is unconditional — it only fires on
  already-broken inputs, so there is no behavior change for valid completions).
```

## Validation Loop

> ⛔ AGENTS.md HARD RULE: write every lua snippet to a real FILE then run via
> `+"luafile <path>" +qa`. NEVER pipe a heredoc into nvim stdin (it hangs). Every nvim
> invocation is bounded by `timeout`. Run commands from the repo root.

### Level 1: Syntax & Style (Immediate Feedback)

```bash
# No luacheck/stylua/selene config — the headless load IS the syntax gate.
# (a) Compile-check BOTH modified drivers load cleanly (catches a Lua syntax error + a bad
#     [=[ ]=] long-string bracket mismatch). NB: this checks the LUA, not the shell source
#     inside the string — a zsh/bash-syntax error only surfaces at runtime (Level 2).
timeout 30 nvim --headless --clean -u NORC -c 'set rtp+=.' \
  -c 'lua require("pi-bridge.shell.zsh"); require("pi-bridge.shell.bash")' -c 'qa' \
  && echo "OK zsh.lua + bash.lua load" || echo "FAIL load"

# (b) Sanity: M.parse/start/cd still exported in BOTH (the load gate).
timeout 30 nvim --headless --clean -u NORC -c 'set rtp+=.' \
  -c 'lua local z=require("pi-bridge.shell.zsh"); local b=require("pi-bridge.shell.bash"); assert(type(z.parse)=="function" and type(z.start)=="function" and type(z.cd)=="function"); assert(type(b.parse)=="function" and type(b.start)=="function" and type(b.cd)=="function")' -c 'qa'
echo "exit=$?"

# Expected: "OK ... load" + exit 0. A non-zero exit = a Lua syntax error (most likely a
# misplaced [=[ ]=] bracket from re-indenting the body into the if/else) — fix before Level 2.
```

### Level 2: Unit Tests (Component Validation)

```bash
# The PRIMARY gates — the LIVE zsh + bash driver specs (incl. the NEW graceful-degrade +
# responsiveness cases). zsh is pending-skip if absent (PRD §17.15); bash runs unconditionally.
timeout 90 nvim --headless --clean -u tests/minimal_init.lua \
  -c 'lua require("plenary.busted").run("tests/shell_zsh_driver_spec.lua")'
echo "zsh_spec exit=$?"

timeout 90 nvim --headless --clean -u tests/minimal_init.lua \
  -c 'lua require("plenary.busted").run("tests/shell_bash_driver_spec.lua")'
echo "bash_spec exit=$?"

# The plenary-FREE smokes (file-based; same surface).
timeout 60 nvim --headless --clean -u NORC +"luafile tests/shell_zsh_driver_smoke.lua" +qa
echo "zsh_smoke exit=$?"   # SMOKE_PASS (or SMOKE_SKIP if no zsh) + exit 0
timeout 60 nvim --headless --clean -u NORC +"luafile tests/shell_bash_driver_smoke.lua" +qa
echo "bash_smoke exit=$?"  # SMOKE_PASS + exit 0

# Regression: M.parse is UNCHANGED — the pure-Lua parser specs must stay green.
timeout 90 nvim --headless --clean -u tests/minimal_init.lua \
  -c 'lua require("plenary.busted").run("tests/shell_zsh_spec.lua")'   # if present
timeout 90 nvim --headless --clean -u tests/minimal_init.lua \
  -c 'lua require("plenary.busted").run("tests/shell_spec.lua")'

# Expected: all PASS / exit 0. If a LIVE case fails, READ the plenary output — a hang/timeout on
# the "responsiveness" follow-up means the daemon wedged on the malformed input. Do NOT weaken
# the assertion; fix the guard (most likely a wrong variable name — zsh `cmd` vs bash `line` — or
# the parity test is inverted; the empty/quote case should yield 0 items, NOT hundreds).
```

### Level 3: Integration Testing (System Validation)

```bash
# Full shell test surface (catches a regression in start/ensure/_feed/teardown from the script
# edits, and confirms no uv handle leak was introduced). bash is the strongest gate (universal).
timeout 90 nvim --headless --clean -u tests/minimal_init.lua \
  -c 'lua require("plenary.busted").run("tests/shell_feed_spec.lua")'
timeout 90 nvim --headless --clean -u tests/minimal_init.lua \
  -c 'lua require("plenary.busted").run("tests/shell_complete_current_spec.lua")'
timeout 60 nvim --headless --clean -u NORC +"luafile tests/shell_smoke.lua" +qa
timeout 60 nvim --headless --clean -u NORC +"luafile tests/shell_complete_current_smoke.lua" +qa

# Expected: all PASS. No hangs (every command has a bounded timeout per AGENTS.md).
```

### Level 4: Creative & Domain-Specific Validation

```bash
# The definitive end-to-end proof: drive the REAL zsh AND bash drivers with the failure matrix
# + a responsiveness follow-up through ONE daemon each, asserting each response. Write to a FILE
# (AGENTS.md HARD RULE). bash always runs; zsh SKIPs cleanly if absent.

cat > /tmp/pi_zshbash_guard_e2e.lua <<'LUA'
-- Drives the REAL zsh + bash drivers with the graceful-degrade matrix + a responsiveness
-- follow-up. Mirrors the spec wire/decode idiom. bash runs unconditionally; zsh SKIPs if absent.
local uv = vim.uv
local fails = 0
local function check(c, m) if not c then io.stderr:write("FAIL: "..m.."\n"); fails = fails + 1 end end

local function mkframe(line, cur)
  return string.format('__PIREQ__\t{"line":%s,"cursor":%d,"after":""}', vim.json.encode(line), cur)
end

local function run_driver(label, modname, opts)
  local drv = require(modname)
  local proc, stdin, stdout, rx, resolver = "", nil
  local function try_parse()
    local s = rx:find("__PIRESP_START__\n", 1, true); if not s then return end
    local ps = s + #"__PIRESP_START__\n"
    local e = rx:find("__PIRESP_END__\n", ps, true); if not e then return end
    local body = rx:sub(ps, e - 1); rx = rx:sub(e + #"__PIRESP_END__\n")
    local ok, d = pcall(vim.json.decode, body)
    if ok and type(d) == "table" then local r = resolver; resolver = nil; if r then r(d.items or {}) end end
  end
  local ready, started = false, false
  drv.start(opts, function(err, p, si, so)
    if err then ready = true; check(false, label.." start err="..tostring(err)); return end
    proc, stdin, stdout = p, si, so
    pcall(function() stdout:read_start(function(_, data)
      if not data then return end; rx = rx .. data
      while rx:find("__PIRESP_START__\n", 1, true) do
        local s = rx:find("__PIRESP_START__\n", 1, true); local ps = s + #"__PIRESP_START__\n"
        local e = rx:find("__PIRESP_END__\n", ps, true); if not e then break end
        try_parse()
      end
    end) end)
    ready = true
  end)
  vim.wait(opts.startup_timeout_ms + 3000, function() return ready end, 20)
  if not proc then io.stdout:write(label..": SKIP (no daemon)\n"); return end
  started = true

  -- (1) normal STILL works (no over-suppression)  (2) quote → EMPTY  (3) empty → EMPTY  (4) responsive follow-up
  local r1, r2, r3, r4
  local function send(line, cur, cb) resolver = cb; pcall(function() stdin:write(mkframe(line, cur).."\n") end) end
  local normal_cmd, normal_cur, normal_want = opts.normal_cmd, opts.normal_cur, opts.normal_want
  send(normal_cmd, normal_cur, function(it)
    r1 = it
    send('git "feature', 11, function(it2) r2 = it2;
      send("", 0, function(it3) r3 = it3;
        send(normal_cmd, normal_cur, function(it4) r4 = it4 end) end) end) end)
  vim.wait(12000, function() return r4 ~= nil end, 20)

  check(r1 ~= nil, label.." r1 ("..normal_cmd..") never resolved")
  if r1 then local has=false; for _,it in ipairs(r1) do if it.value==normal_want then has=true end end; check(has, label.." r1 missing `"..normal_want.."` (guard over-suppressed!)") end
  check(r2 ~= nil, label.." r2 (quote) never resolved")
  if r2 then check(#r2 == 0, label.." r2 should be EMPTY, got "..#r2.." (flood!)") end
  check(r3 ~= nil, label.." r3 (empty) never resolved")
  if r3 then check(#r3 == 0, label.." r3 should be EMPTY, got "..#r3.." (flood!)") end
  check(r4 ~= nil, label.." r4 (follow-up) never resolved — daemon wedged on a malformed input")
  if r4 then local has=false; for _,it in ipairs(r4) do if it.value==normal_want then has=true end end; check(has, label.." r4 missing `"..normal_want.."` (daemon did NOT stay responsive)") end

  pcall(function() if proc and not proc:is_closing() then uv.process_kill(proc, "sigkill") end end)
  pcall(function() if proc and not proc:is_closing() then proc:close() end end)
  pcall(function() if stdin and not stdin:is_closing() then stdin:close() end end)
  pcall(function() if stdout and not stdout:is_closing() then stdout:read_stop(); stdout:close() end end)
  package.loaded[modname] = nil
  io.stdout:write(label..": DONE (started="..tostring(started)..")\n")
end

run_driver("bash", "pi-bridge.shell.bash",
  { shell="bash", cwd=vim.fn.getcwd(), startup_timeout_ms=5000, normal_cmd="ls /tm", normal_cur=6, normal_want="/tmp" })
if vim.fn.executable("zsh") == 1 then
  run_driver("zsh", "pi-bridge.shell.zsh",
    { shell="zsh", cwd=vim.fn.getcwd(), startup_timeout_ms=8000, normal_cmd="git ch", normal_cur=6, normal_want="checkout" })
else
  io.stdout:write("zsh: SKIP (no zsh on PATH)\n")
end

if fails > 0 then io.stderr:write(fails.." check(s) FAILED\n"); vim.cmd("cquit 1") end
io.stdout:write("E2E_PASS: zsh/bash graceful-degrade + responsiveness verified\n")
LUA
timeout 90 nvim --headless --clean -u NORC -c 'set rtp+=.' +"luafile /tmp/pi_zshbash_guard_e2e.lua" +qa
echo "exit=$?"
# Expected: bash DONE + zsh DONE (or SKIP) + E2E_PASS + exit 0. Decisive: r2/r3 EMPTY + r4 has the
# normal item (proves flood-fix + daemon responsiveness in ONE run, for BOTH shells).

# Optional: a quick empirical check of the `${var##*[^\\]}` parity idiom in pure zsh/bash
# (confirms the §3 matrix before trusting the in-script guard):
printf 'local s="git \\\\\\"; local t="${s##*[^\\\\]}"; echo "tail=<$t> len=${#t} odd=$(( ${#t} %% 2 ))"\n' | bash
printf 's="git \\\\\\"; print "tail=<${s##*[^\\\\]}> odd=$(( ${#${s##*[^\\\\]}} %% 2 ))"\n' | zsh
# Expect: tail=<\> len=1 odd=1  (bash)   /   tail=<\> odd=1  (zsh)   — confirms odd-trailing-BS detection.
```

## Final Validation Checklist

### Technical Validation
- [ ] Level 1: `zsh.lua` + `bash.lua` load headless (the `require` + export-assert commands print OK / exit 0).
- [ ] Level 2: `tests/shell_zsh_driver_spec.lua` PASS (incl. NEW graceful-degrade + responsiveness cases).
- [ ] Level 2: `tests/shell_bash_driver_spec.lua` PASS (incl. NEW graceful-degrade + responsiveness cases).
- [ ] Level 2: both `_smoke.lua` print `SMOKE_PASS` + exit 0 (zsh `SMOKE_SKIP` if absent).
- [ ] Level 2: `shell_spec.lua` / parser specs PASS (M.parse regression — UNCHANGED in both files).
- [ ] Level 3: `shell_feed_spec` / `shell_complete_current_spec` / `shell_smoke` PASS (no regression).
- [ ] Level 4: `/tmp/pi_zshbash_guard_e2e.lua` prints `E2E_PASS` (r2/r3 empty + r4 has the normal item, both shells).
- [ ] No `uv_timer_t` / handle leak (the existing no-leak cases still pass; the guard adds none).

### Feature Validation
- [ ] zsh: empty line → 0 items (was all-commands flood); bash: empty line → 0 items (was all-commands/files flood).
- [ ] zsh + bash: quote-line (`git "feature`) → 0 items AND the daemon completes a follow-up normal request.
- [ ] zsh + bash: normal completions still return real items (`git ch`→checkout; `ls /tm`→/tmp) — no over-suppression.
- [ ] zsh + bash: `echo \\` (even backslashes) → still passed to the completion engine (no false-positive suppression).
- [ ] Both `KNOWN LIMITATION` header doc-comments reflect the new graceful-empty behavior.

### Code Quality Validation
- [ ] The guard mirrors each file's never-throws + defensive discipline (pure-addition; no new throw path).
- [ ] zsh uses `${cmd##*[^\\]}` + `(( ${#_tail} % 2 == 0 ))` (the if-wraps-the-normal-path form); bash uses
      `${line##*[^\\]}` + `(( ${#_tail} % 2 ))` (the if-wraps-the-malformed-path form) — parity semantics identical.
- [ ] The correct variable name is used in each file (zsh `cmd`; bash `line`).
- [ ] The `if/then/else/fi` structure avoids the `;;`-inside-`if` trap (no `return` in zsh's top-level OUTER).
- [ ] No change to `M.parse` / `M.start` / `M.cd` / shell.lua / the wire protocol / INNER_SCRIPT / bash completion body.
- [ ] Comments cite Issue 6 + the flood mode + the parity reasoning (empty AND odd-trailing-backslash).

### Documentation & Deployment
- [ ] Code is self-documenting (each guard block explains the dangling-backslash extraction + parity invariant inline).
- [ ] No new env var / config key (§17.11 defines none; the guard is unconditional + behavior-preserving for valid input).
- [ ] (P1.M2.T7.S1 owns the README/doc sweep — keep this task to zsh.lua + bash.lua + the tests + the in-file comments.)

---

## Anti-Patterns to Avoid

- ❌ Do NOT implement an empty-ONLY guard ("if cmd/line == \"\" emit empty"). That fixes the empty-line
  flood but NOT the Issue 6 headline repro — `git "feature` extracts to `cmd = "git \"` (NOT empty) in
  BOTH zsh and bash. The guard MUST also catch the odd-trailing-backslash case (parity check).
- ❌ Do NOT detect "ends with a backslash" with a mere presence check — `echo \\` (two backslashes) is a
  VALID escaped backslash and must NOT be suppressed. Check the trailing-backslash PARITY (odd).
- ❌ Do NOT reference the wrong variable: the extracted command is `cmd` in zsh.lua and `line` in bash.lua.
  Testing `$cmd` in bash (or `$line` in zsh) silently tests an empty/wrong value → the guard never fires.
- ❌ Do NOT place a `;;` inside an `if ... fi` inside a `case` branch (syntax error), and do NOT `return`
  out of zsh's top-level OUTER_SCRIPT (not a function). Use the `if/then/else/fi` wrap so START/JSON/END
  are emitted exactly once per request.
- ❌ Do NOT port fish's `__pi_trailing_bs` chop-loop helper — zsh/bash `${var##pattern}` does NOT word-split
  the value the way an UNquoted fish `$cmd` does. Use the native `${cmd##*[^\\]}` + `${#}` + `% 2`.
- ❌ Do NOT Lua-escape the shell escapes inside the `[=[ ]=]` long-strings — their content is LITERAL
  zsh/bash source. Write `[^\\]` exactly (the `\\` is passed verbatim; the shell reads it as an escaped
  backslash). Do NOT write `[^\]` (unclosed) or `[^\\\\]` (doubly-escaped).
- ❌ Do NOT touch `M.parse` (the pure-Lua parser), `M.start`, `M.cd`, INNER_SCRIPT, the bash completion
  body, or shell.lua — all are correct + out of scope. fish.lua is already done (S1) — do not touch it.
- ❌ Do NOT hand-escape the embedded `"` in test frames — build them with `vim.json.encode` (the same
  encoding shell.lua M.request uses) so the test frame is byte-identical to a real keystroke.
- ❌ Do NOT weaken a test assertion to make it pass; if the "responsiveness" follow-up hangs/times out, or
  the empty/quote case yields hundreds of items, the guard didn't fire — fix the guard (re-check the
  variable name + the parity test polarity), don't relax the check.
- ❌ Do NOT pipe a heredoc into `nvim` stdin (AGENTS.md HARD RULE — it hangs the session). Write lua to a
  FILE, run via `+"luafile <path>" +qa`, always bounded by `timeout`.

---

**Confidence Score: 9/10** — the fix is a pure-addition guard inside two shell-source strings, with the
exact per-shell placement + the reasoned (and Level-4-verifiable) parity idiom, the variable-name
divergence spelled out, the `;;`-inside-`if` trap avoided by construction, the byte-level extraction
trace (proving the literal-`"` → dangling-backslash case), and a definitive end-to-end Level-4 script
that exercises BOTH shells in one run. The one residual uncertainty: the `${cmd##*[^\\]}` + `(( ${#_tail} % 2 ))`
parity idiom is reasoned-correct but should be empirically confirmed against live zsh 5.9 / bash 5.3
(the Level-4 e2e + the optional pure-shell one-liner both gate it; if a shell version surprises, fall
back to a `case`/regex parity test). zsh coverage depends on `zsh` being installed (the e2e SKIPs cleanly
otherwise; bash always runs, and the offline Level-1 load gate catches Lua-syntax regressions regardless).