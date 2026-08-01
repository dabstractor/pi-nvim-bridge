# Research — P1.M2.T6.S1: fish.lua empty-cmd + quote graceful-degrade guard (Issue 6)

Empirical findings from driving the REAL `fish` (4.x) DAEMON_SCRIPT `__pi_handle` end-to-end.
All repros were run via `fish -c 'source <funcs>; while read -l line; __pi_handle $line; end'`
feeding real `__PIREQ__\t{"line":<json>,...}` frames identical to what `shell.lua M.request`
writes (`vim.json.encode`-escaped line values). Scripts used: `/tmp/fish_*.fish`.

## 1. The two failure modes (BEFORE the fix)

Issue 6's headline ("a literal `"` floods all commands") is **under-stated for fish**. There are
TWO distinct catastrophic modes, both rooted in the simple `"line":"([^"]*)"` regex (which can't
parse JSON-escaped `\"`):

### Mode A — EMPTY cmd → FLOOD (the documented Issue 6)
- Trigger: a line whose JSON value extracts to `cmd == ""`. Reachable when the line is empty
  (bare `!`) OR when the regex match yields no group.
- `complete -C ""` returns **EVERY** completion on the system: **5456 items** on this box.
- Daemon SURVIVES (exit 0) but the consumer menu is flooded.

### Mode B — TRAILING-BACKSLASH cmd → PANIC + DAEMON DEATH (UNDOCUMENTED, worse)
- Trigger: any line containing a literal `"`. JSON encodes `"` as `\"`; the simple regex's
  `[^"]*` stops at the FIRST `"` (the escaped one), leaving the backslash dangling at the end
  of `cmd`. Examples (regex-extracted `cmd`, LIVE-verified):
  - `git "feature`  → cmd = `git \`   (1 trailing backslash)
  - `"echo`         → cmd = `\`      (1 trailing backslash)
  - `git commit -m "wip` → cmd = `git commit -m \` (1 trailing backslash)
- `complete -C "git \"` (a commandline ending in an UNescaped backslash) **PANICS fish**:
  ```
  thread 'main' panicked at src/builtins/complete.rs:547:22:
  Unescaping commandline to complete failed     exit = 101
  ```
- A builtin panic **aborts the whole fish process**. In the real persistent daemon this KILLS
  the daemon → the next request finds a dead stdout → `shell._reset` → re-spawn. Symptom for the
  user: ~1.5s hang (the per-request `cfg.timeout_ms`=1500) + a daemon respawn PER quote keystroke.

### Why the PRD's suggested fix alone ("guard empty-cmd") is NECESSARY but NOT SUFFICIENT for fish
- It fixes Mode A (the flood). ✅
- It does NOT fix Mode B (the panic): a `git "feature` line extracts to `cmd = "git \"` (NOT
  empty), so an empty-only guard lets `complete -C "git \"` still run → still panics. The Issue 6
  headline repro (`git "feature`) would STILL fail (worse: daemon death instead of flood).

## 2. The precise "malformed" signal

A `cmd` is unsafe to pass to `complete -C` iff:
- it is EMPTY (Mode A), OR
- it ends with an **ODD** number of trailing backslashes (Mode B — an unescaped dangling `\`).
  - `git \`        → 1 trailing BS → odd → PANIC risk
  - `\`           → 1 trailing BS → odd → PANIC risk
  - `echo \\`     → 2 trailing BS → even → VALID (escaped backslash, no panic)
  - `git ch`      → 0 trailing BS → even → valid

So the guard must check the trailing-backslash **PARITY**, not mere presence (a naive
"ends with `\`" check would false-positive on the valid `echo \\`).

## 3. fish quoting landmines (the IMPLEMENTATION gotcha)

Detecting "trailing backslash" in fish is FULL of quoting traps. Approaches that FAIL or are
fragile (LIVE-verified):
- `string match -r '\\+$' -- $cmd` with **unquoted** `$cmd` → fish word-splits on the space in
  `git \` → wrong result (returned NOTHING in my trace; the guard never fired → panic still hit).
- `'\\'` in fish **single** quotes = TWO literal backslashes (single quotes are fully literal;
  there is no `\` escape) — wrong for "one backslash".
- `"\"` in fish **double** quotes = an UNCLOSED string (the `\"` is an escaped quote, needs a
  closing `"`). Wrong.
- Nested single quotes inside a `(...)` command-substitution inside a `"..."` string → parse error.

The ROBUST, regex-free idiom that WORKS (LIVE-verified — see `/tmp/fish_detect2.fish`):
```fish
# a single backslash literal in fish is "\\" (double-quoted). Count trailing backslashes by
# chopping the last char in a loop — no regex, no quoting ambiguity.
function __pi_trailing_bs
    set -l c "$argv"
    set -l n 0
    while test (string length -- "$c") -gt 0
        set -l last (string sub --start=-1 -- "$c")
        if test "$last" = "\\"
            set n (math $n + 1)
            set c (string sub --length=(math (string length -- "$c") - 1) -- "$c")
        else
            break
        end
    end
    echo $n
end
```
`test "$last" = "\\"` is the correct single-backslash comparison (double-quoted `\\` = one `\`).

## 4. The fix is PROVEN end-to-end

Integrated the guard (empty-OR-odd-trailing-backslash → `emit_empty` + return, BEFORE
`complete -C`) and re-ran the full matrix through ONE daemon (see `/tmp/fish_final_guard.fish`):

| case              | line                  | BEFORE          | AFTER        |
|-------------------|-----------------------|-----------------|--------------|
| NORMAL            | `git ch`              | 3 items         | 3 items      |
| EMPTY_LINE        | ``                    | 5456 (FLOOD)    | 0 (empty)    |
| QUOTE_MID         | `git "feature`        | PANIC exit 101  | 0 (empty)    |
| QUOTE_LEAD        | `"echo`               | PANIC exit 101  | 0 (empty)    |
| QUOTE_WIP         | `git commit -m "wip`  | (panic)         | 0 (empty)    |
| DOUBLE_BS_VALID   | `echo \\`             | n/a             | 0 (no false+)|

Persistence: 5 sequential requests (incl. 2 malformed mid-stream) through ONE guarded daemon →
**5 responses, daemon survives** (BEFORE: the 2nd malformed request killed it).

## 5. Consumer-side parity (no change needed)

`shell.lua M._feed` / `normalize_item` already handle an empty `items` array correctly
(`raw_items = decoded.items or {}` → empty → menu shows nothing / closes). So emitting
`{"items":[],"prefix":""}` is a clean graceful-degrade on the consumer side — NO shell.lua change.

## 6. Test surface

- The guard lives in `DAEMON_SCRIPT` (fish source inside a Lua `[[ ]]` long-string) → NOT
  offline-testable (unlike `M.parse`, which is pure Lua). Must be gated on `fish` on PATH,
  matching the existing `tests/shell_fish_driver_spec.lua` LIVE block convention.
- New LIVE cases to add: (a) empty-line frame → 0 items; (b) quote-frame `git "feature` → 0
  items AND the daemon survives a FOLLOW-UP normal request (proves no panic/death); (c) regression:
  `git ch` still → checkout (guard doesn't over-suppress).
- `M.parse` (shell_fish_spec.lua) is UNCHANGED — do not touch it.

## 7. Scope boundary (P1.M2.T6.S2 owns zsh + bash)

This task is **fish.lua ONLY**. zsh.lua + bash.lua get the SAME semantic guard in P1.M2.T6.S2.
Note: zsh/bash quote-cases reportedly FLOOD (not panic) per the PRD (their `complete`/`compgen`
don't abort the process on a dangling backslash), so their empty-cmd guard is the primary fix
there — but S2 should still empirically verify the quote case for each. Do NOT modify zsh/bash here.