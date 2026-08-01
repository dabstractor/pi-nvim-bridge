# PRP — P1.M2.T6.S1: fish.lua empty-cmd + quote graceful-degrade guard (Issue 6)

name: "P1.M2.T6.S1 — Graceful-degrade guard in fish.lua DAEMON_SCRIPT"
description: >
  Issue 6 (PRD §17.6.x / §17.15): a `!`/`!!` command line containing a literal `"` (or an
  empty line) makes fish's `complete -C` either FLOOD the menu with every command on the
  system (empty cmd) or PANIC + KILL the persistent daemon (a dangling trailing backslash).
  This PRP adds a guard in the fish `DAEMON_SCRIPT`'s `__pi_handle` that detects the
  malformed `cmd` BEFORE `complete -C` and emits a clean EMPTY result instead — converting
  two catastrophic failure modes into a graceful "no completions". The fish driver's
  `M.parse` (pure-Lua parser) + shell.lua consumer are UNCHANGED (they already handle an
  empty items array). zsh/bash are a SEPARATE task (P1.M2.T6.S2).

---

## Goal

**Feature Goal**: When a `!`/`!!` shell line extracts to a `cmd` that is EMPTY or ends with an
**unescaped (odd-count) trailing backslash** — both of which today cause a flood (5456+ items)
or a fish **panic that kills the daemon** (`complete.rs:547`) — the fish daemon emits a clean
`{"items":[],"prefix":""}` response instead of calling `complete -C`, so the user sees "no
completions" (graceful degrade) and the persistent daemon survives.

**Deliverable**:
1. A new `__pi_trailing_bs` helper in the fish `DAEMON_SCRIPT` (`lua/pi-bridge/shell/fish.lua`)
   that counts the trailing run of backslashes in `cmd` (regex-free — robust to fish quoting).
2. A graceful-degrade guard block in `__pi_handle` (after `.line` extraction, BEFORE the
   `complete -C "$cmd" | while read` loop) that emits the empty single-object JSON between
   sentinels and `return`s when `cmd` is empty OR has an odd trailing-backslash count.
3. An updated `KNOWN LIMITATION` header doc-comment in `fish.lua` reflecting the new graceful
   behavior (no longer "returns all commands" / crashes — now a clean empty).
4. New LIVE-gated cases in `tests/shell_fish_driver_spec.lua` + a smoke check in
   `tests/shell_fish_driver_smoke.lua` proving: empty line → 0 items; a quote-line
   (`git "feature`) → 0 items AND the daemon survives a follow-up normal request (no panic);
   `git ch` still returns `checkout` (no over-suppression).

**Success Definition**: Typing `!git "feature`<Tab> or `!`<Tab> (empty) no longer floods the
menu with thousands of commands nor hangs ~1.5s while the daemon crashes+respawns; the menu
stays empty and the VERY NEXT normal keystroke (`!git ch`<Tab>) completes instantly from the
SAME surviving daemon. All existing + new tests pass; no handle leak.

## User Persona

**Target User**: A pi editor user driving `!`/`!!` Bash-Mode shell completion (fish Tier-1
driver) who types a command containing a literal `"` — e.g. `!git commit -m "wip`<Tab>,
`!echo "feat`<Tab>, or a `!"`-leading line — or hits Tab on a bare `!`.

**Use Case**: Mid-typing a quoted argument, Tab should either complete sensibly or show
nothing — not flood the floating menu with every command on the box, and not silently hang.

**Pain Points Addressed**: (1) The all-commands flood (Issue 6's documented symptom); (2) the
undocumented fish **panic** that kills the daemon and causes a per-quote-keystroke ~1.5s hang +
respawn (discovered during this research — see research/).

## Why

- **PRD fidelity**: §17.6.1 + the driver header already document this as a KNOWN LIMITATION of
  the crude `"line":"([^"]*)"` regex (a true JSON-string regex is infeasible in fish without a
  JSON parser). Issue 6's stated goal is *"converts a confusing flood into a clean no-results"*.
- **The documented fix is necessary but NOT sufficient for fish**: the PRD suggests "emit empty
  when cmd is empty". Empirically, a quote-line extracts to `cmd = "git \"` (a DANGLING
  backslash, NOT empty), so an empty-only guard leaves the **panic** — the Issue 6 headline
  repro (`git "feature`) would STILL fail (worse: daemon death). This PRP's guard covers BOTH
  failure modes with one parity-aware check.
- **Daemon liveness is the bigger win**: a builtin panic aborts the whole fish process; making
  the daemon survive malformed input means the next keystroke completes instantly (no respawn).
- **Low risk / localized**: a pure-addition guard inside the fish source string; no change to
  `M.parse`, `M.start`, `M.cd`, shell.lua, or the wire protocol. The consumer already handles
  an empty items array.

## What

### User-visible / behavioral
- A `!`/`!!` line that is empty, or contains a literal `"`, yields an EMPTY completion menu
  (no items) — never a flood, never a hang.
- The fish daemon survives these inputs; the next normal request completes from the same daemon.
- Normal completions (`!git ch` → checkout, `!ls /tm` → /tmp paths) are UNCHANGED.
- A line legitimately ending in an EVEN number of backslashes (e.g. `!echo \\`, a valid escaped
  backslash) is still passed to `complete -C` (no false-positive suppression).

### Success Criteria
- [ ] `__pi_handle` emits `{"items":[],"prefix":""}` between `__PIRESP_START__`/`__PIRESP_END__`
      and returns BEFORE `complete -C` when `cmd` is empty OR has an odd trailing-backslash count.
- [ ] The guard fires for the regex-extracted `cmd` of every quote-containing line tested:
      `git "feature` (cmd `git \`), `"echo` (cmd `\`), `git commit -m "wip` (cmd `git commit -m \`).
- [ ] The guard does NOT fire for `git ch` (cmd `git ch`, 0 trailing BS) or `echo \\` (2 trailing BS, even).
- [ ] LIVE: a quote-frame leaves the daemon alive — a follow-up normal frame returns real items.
- [ ] The `KNOWN LIMITATION` header comment is updated (graceful empty, not flood/panic).
- [ ] All existing fish tests pass; no `uv_timer_t` / handle leak; `M.parse` untouched.

## All Needed Context

### Context Completeness Check
_"If someone knew nothing about this codebase, would they have everything needed to implement this successfully?"_
Yes — the exact fish source location, the exact (empirically-verified) guard code, the fish
quoting landmines that make naive detection FAIL, the proven end-to-end matrix, and the verified
validation commands are all below + in research/.

### Documentation & References

```yaml
# The canonical bug description this fixes
- docfile: plan/002_d23d7473c16c/bugfix/001_842ac90ede70/prd_snapshot.md
  section: "Issue 6 — Command lines containing a literal \" produce an all-commands flood"
  why: |
    States the goal: a literal `"` in the line → graceful EMPTY result, not a flood. The
    suggested fix ("emit empty when cmd is empty") is NECESSARY but NOT SUFFICIENT for fish —
    see the research note for the panic Mode B it misses.
  critical: |
    The headline repro is `git "feature`, which on fish extracts to `cmd = "git \"` (trailing
    backslash) and PANICS fish — it does NOT extract to empty. An empty-only guard does not
    fix the headline repro. The guard here MUST also catch the odd-trailing-backslash case.

# THE FILE TO MODIFY — read the WHOLE DAEMON_SCRIPT before editing
- file: lua/pi-bridge/shell/fish.lua
  why: |
    The fish driver. `DAEMON_SCRIPT` (a Lua `[[ ... ]]` long-string) is the fish source sourced
    via `fish -i --init-command="source <tmp>"`. `__pi_handle` is the per-frame handler:
    prefix-strip → `.line` regex extract → `complete -C "$cmd" | while read` → emit JSON.
  pattern: |
    The guard goes AFTER the `set -l m (string match -r '"line":"([^"]*)"' ...)` +
    `if test (count $m) -ge 2; set cmd $m[2]; end` block, and BEFORE the
    `# Run fish's completion engine` comment + the `complete -C "$cmd" | while read -l raw` loop.
    Add the `__pi_trailing_bs` helper as a sibling of `__pi_json_str` (both top-level `function`s).
  gotcha: |
    `DAEMON_SCRIPT` is a Lua `[[ ... ]]` long-string — NONE of its `\n`/`\t`/`\\` are interpreted
    by Lua; they are LITERAL fish source. So a fish `"\\="` (double-quoted two-backslash = one
    backslash) is written EXACTLY as `"\\"` in the Lua source. Do NOT Lua-escape the fish escapes.

# The consumer (NO CHANGE — confirms an empty items array is handled)
- file: lua/pi-bridge/shell.lua
  why: |
    M._feed decodes the daemon's single-object JSON; `raw_items = (type(decoded.items) == "table")
    and decoded.items or {}` (shell.lua:~668). An empty `items` → `normalize_item` produces nothing
    → the menu shows empty / closes. So emitting `{"items":[],"prefix":""}` is a clean degrade.
  critical: Confirm this, but DO NOT modify shell.lua (out of scope; it already handles it).

# The TEST files to extend (LIVE-gated on `fish` — the established pattern)
- file: tests/shell_fish_driver_spec.lua
  why: |
    The plenary spec for the REAL fish driver. Has an offline-contract `describe` + a
    `describe("LIVE driver (gated on fish)")` block (pending-skipped when `fish` absent — PRD §17.15).
    The LIVE "git ch → checkout" case spawns the real daemon, wires stdout, sends a frame, decodes.
  pattern: |
    Mirror that LIVE case to add: (a) an empty-line frame → assert decoded.items == {}; (b) a
    quote-frame `git "feature` → assert decoded.items == {} THEN a follow-up `git ch` frame on the
    SAME daemon → assert `checkout` present (proves no panic / daemon survived). Reuse the file's
    rx_buf/try_parse/teardown idiom. Set package.loaded["pi-bridge.shell.fish"]=nil in after_each.
- file: tests/shell_fish_driver_smoke.lua
  why: |
    The plenary-FREE smoke (file-based; run via +"luafile ..."). Same LIVE-gated shape: SMOKE_SKIP
    if no fish. Adds a `check(c, msg)` assertion for the quote + empty graceful-degrade + survival.
  gotcha: |
    ⛔ AGENTS.md HARD RULE: run via +"luafile tests/shell_fish_driver_smoke.lua" +qa. NEVER heredoc
    to nvim stdin (it hangs the session). Every nvim call bounded by `timeout`.

# The research note (READ IT — the panic discovery + the fish quoting landmines are documented there)
- docfile: plan/002_d23d7473c16c/bugfix/001_842ac90ede70/P1M2T6S1/research/fish_quote_flood_panic_findings.md
  section: "§2 The precise malformed signal" + "§3 fish quoting landmines"
  why: |
    Explains WHY the guard must check trailing-backslash PARITY (not mere presence), and WHY a
    naive `string match -r '\\+$' -- $cmd` FAILS (unquoted $cmd word-splits; the guard silently
    never fires → panic still hits). Gives the regex-free idiom that WORKS.
  critical: |
    A single backslash literal in fish is `"\\"` (double-quoted). In fish SINGLE quotes there is NO
    backslash escape (`'\\'` = two chars). `test "$last" = "\\"` is the correct comparison.
```

### Current Codebase tree (relevant slice)

```bash
lua/pi-bridge/shell/
  fish.lua            # MODIFIED — DAEMON_SCRIPT: add __pi_trailing_bs helper + the guard block;
                      #            update the KNOWN LIMITATION header comment. (M.parse/start/cd UNCHANGED)
tests/
  shell_fish_driver_spec.lua   # MODIFIED — add LIVE graceful-degrade + daemon-survival cases
  shell_fish_driver_smoke.lua  # MODIFIED — add a plenary-free graceful-degrade smoke check
```

### Known Gotchas of our codebase & Library Quirks

```lua
-- CRITICAL: the PRD's "guard empty-cmd" is NECESSARY but NOT SUFFICIENT for fish. A quote-line
--   extracts to a TRAILING-BACKSLASH cmd (e.g. `git "feature` → cmd `git \`), NOT empty. `complete -C "git \"`
--   PANICS fish (complete.rs:547 "Unescaping commandline to complete failed") and KILLS the daemon.
--   The guard MUST also catch the odd-trailing-backslash case, or the Issue 6 headline repro still fails.

-- CRITICAL (fish quoting): a SINGLE backslash literal in fish is "\\" (DOUBLE-quoted). Fish single
--   quotes are FULLY literal — there is NO backslash escape — so '\\' is TWO backslashes, and "\" is
--   an UNCLOSED string (the \" is an escaped quote). The correct comparison is: test "$last" = "\\".

-- GOTCHA: do NOT detect trailing backslashes with `string match -r '\\+$' -- $cmd` where $cmd is
--   UNQUOTED. Fish word-splits an unquoted variable on whitespace; `cmd="git \"` splits into `git` + `\`
--   and the match result is unreliable (in LIVE tracing it returned NOTHING → the guard never fired →
--   the panic still hit). Use the regex-free `__pi_trailing_bs` chop-loop helper (passes "$cmd" QUOTED).

-- GOTCHA: check trailing-backslash PARITY, not mere presence. `echo \\` (two backslashes) is a VALID
--   escaped backslash (no panic) and must NOT be suppressed. Only an ODD trailing count is malformed.
--   (n % 2) == 1 is the malformed test.

-- GOTCHA: DAEMON_SCRIPT is a Lua [[ ... ]] long-string — its content is LITERAL fish source. Do not
--   Lua-escape the fish escapes; write the fish exactly as it must execute.

-- GOTCHA: the guard is inside the fish SOURCE string → NOT offline-testable (unlike M.parse, the pure
--   Lua parser). Tests MUST be gated on `fish` on PATH (pending-skip when absent) — the established
--   convention in tests/shell_fish_driver_spec.lua + _smoke.lua (PRD §17.15 "no live fish → defer").

-- CRITICAL (AGENTS.md HARD RULE): write every lua test SNIPPET to a real FILE (tests/* or /tmp/*.lua)
--   then run via +"luafile <path>" +qa. NEVER pipe a heredoc into nvim stdin (it hangs forever). Every
--   nvim invocation gets a bounded `timeout`.
```

## Implementation Blueprint

### Data models and structure

No new data models. The fix is entirely inside the fish `DAEMON_SCRIPT` source string (a Lua
long-string). It adds one fish helper function (`__pi_trailing_bs`) and one guard block in
`__pi_handle`. No Lua-side state, no new config key, no shell.lua change, no `M.parse` change.

### Implementation Tasks (ordered by dependencies)

```yaml
Task 1: MODIFY lua/pi-bridge/shell/fish.lua — add the __pi_trailing_bs helper to DAEMON_SCRIPT
  - FIND: inside DAEMON_SCRIPT, the `function __pi_json_str ... end` block (the jq-free JSON
          escape helper). Add the new helper as its sibling (both top-level fish functions,
          BEFORE `function __pi_handle`).
  - ADD (verbatim — this is LITERAL fish source inside the [[ ]] long-string; the "\\" is a
          fish single-backslash literal, NOT a Lua escape):
      # Count the trailing run of backslashes in $argv (regex-free; robust to fish quoting —
      # a naive `string match -r '\\+$' -- $cmd` word-splits an UNquoted $cmd and silently
      # returns nothing, so the guard never fires and the panic still hits. Chop the last char
      # in a loop instead). Used by the Issue 6 graceful-degrade guard.
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
  - NAMING: `__pi_trailing_bs` (the `__pi_` prefix mirrors `__pi_json_str` / `__pi_handle`).

Task 2: MODIFY lua/pi-bridge/shell/fish.lua — add the graceful-degrade guard in __pi_handle
  - FIND: in __pi_handle, the `.line` extraction block:
        set -l payload (string replace -r '^__PIREQ__\t' '' -- $line)
        set -l cmd ""
        set -l m (string match -r '"line":"([^"]*)"' -- $payload)
        if test (count $m) -ge 2
            set cmd $m[2]
        end
    and the line immediately after it:
        # Run fish's completion engine (the Tier-1 API). Build the items JSON array.
  - INSERT (between that `end` and the `# Run fish's completion engine` comment):
      # === GRACEFUL-DEGRADE GUARD (Issue 6 / PRD §17.6.x KNOWN LIMITATION) ===
      # The simple `"line":"([^"]*)"` regex cannot parse JSON-escaped `\"`, so a line containing
      # a literal `"` leaves a DANGLING backslash at the end of `cmd` (e.g. `git "feature` →
      # `git \`). Two catastrophic outcomes if we pass such a `cmd` to `complete -C`:
      #   * `complete -C ""`         → returns EVERY command on the system (5000+ item FLOOD).
      #   * `complete -C "git \"`     → PANICS fish (src/builtins/complete.rs:547
      #     "Unescaping commandline to complete failed") and KILLS the persistent daemon (exit 101).
      # Instead emit a clean EMPTY result (graceful degrade — the menu shows nothing) when `cmd`
      # is EMPTY (the flood trigger) OR ends with an ODD run of backslashes (the panic trigger —
      # an unescaped dangling `\`; an EVEN run like `echo \\` is a valid escaped backslash, kept).
      set -l malformed 0
      if test -z "$cmd"
          set malformed 1
      else
          set -l n (__pi_trailing_bs "$cmd")
          if test (math $n % 2) -eq 1
              set malformed 1
          end
      end
      if test $malformed -eq 1
          echo __PIRESP_START__
          printf '{"items":[],"prefix":""}\n'
          echo __PIRESP_END__
          return
      end
  - DO NOT touch: the __PICD__ branch, the payload/cmd extraction, the complete -C loop, the
          JSON item building, the while-read loop, or anything outside DAEMON_SCRIPT.

Task 3: MODIFY lua/pi-bridge/shell/fish.lua — update the KNOWN LIMITATION header doc-comment
  - FIND: the header bullet (inside the big `--[==[` ... `]==]`? NO — fish.lua uses `---` line
          comments at the top). The bullet currently reads:
      --    KNOWN LIMITATION: a command line containing a literal `"` breaks `.line` extraction
      --    → cmd resolves empty → `complete -C ""` returns all commands (graceful degrade, not
      --    a crash; the gen-guard + empty-menu consumer handle it). A true JSON-string regex is
      --    infeasible in fish without a JSON parser; v1 accepts this edge.
  - REPLACE with (accurate to the NEW behavior):
      --    GRACEFUL DEGRADE (Issue 6): a command line containing a literal `"` (or an empty
      --    line) breaks the simple `.line` regex. `__pi_handle` now GUARDS the extracted `cmd`
      --    BEFORE `complete -C`: an empty `cmd` (→ flood) or one ending in an ODD run of
      --    backslashes (→ fish `complete.rs` PANIC + daemon death) emits a clean EMPTY
      --    `{"items":[],"prefix":""}` instead. A true JSON-string regex is infeasible in fish
      --    without a JSON parser; the guard converts the edge into a graceful no-results.
  - DO NOT change any other header bullet (the manual-JSON / single-object / simple-regex
          DIVERGENCE bullets are still accurate).

Task 4: MODIFY tests/shell_fish_driver_spec.lua — add LIVE graceful-degrade + survival cases
  - FIND: the `describe("LIVE driver (gated on fish on PATH)")` block; the existing
          "start → on_ready + 'git ch' → checkout" `it`.
  - ADD (as new `it`s in the SAME LIVE describe, reusing its spawn/wire/decode/teardown idiom;
          each `it` spawns its OWN daemon + tears it down — do NOT share state across `it`s):
      (a) "empty line → empty items (no flood)":
            spawn; wire stdout; send frame '__PIREQ__\t{"line":"","cursor":0,"after":""}';
            decode; assert decoded.items is a table with #items == 0 (NOT thousands). teardown.
      (b) "quote-line → empty items AND daemon survives the NEXT request (no panic)":
            spawn; wire stdout (rx_buf persists across the two frames). Send
            '__PIREQ__\t{"line":"git \"feature","cursor":11,"after":""}' → decode → assert
            #items == 0. THEN (same daemon, same stdout read) send
            '__PIREQ__\t{"line":"git ch","cursor":6,"after":""}' → decode → assert `checkout`
            IS present. (If the quote had panicked, the follow-up would hang → timeout → nil;
             assert it resolved + has checkout.) teardown.
      (c) (optional) "regression: git che → checkout (guard doesn't over-suppress)":
            already covered by the existing case, but a third round-trip adds confidence.
  - QUOTING in the SPEC (Lua): the frame string contains a literal `"` which in a Lua double-
          quoted string must be escaped as `\"`. E.g.:
            '__PIREQ__\t{"line":"git \\"feature","cursor":11,"after":""}'
          (single-quoted Lua string; the `\\"` is Lua `\"` = one quote in the frame... — VERIFY
           the frame byte-for-byte matches what shell.lua M.request emits: the .line VALUE must
           be the JSON-encoding of `git "feature` = `git \"feature`. Easiest: build the frame
           with string.format + vim.json.encode, exactly like shell.lua does, to avoid hand-
           escaping errors — see the Implementation Patterns block below.)
  - KEEP the existing `after_each` (package.loaded["pi-bridge.shell.fish"]=nil).

Task 5: MODIFY tests/shell_fish_driver_smoke.lua — add a plenary-free graceful-degrade check
  - FIND: the file's sequential-request section (run_sequential) + the cd/post-cd checks.
  - ADD a new section after them (reuse request(line,cursor,after,cb) + try_parse + check):
      (a) send an empty-line frame → assert the decoded items count == 0 (check #items == 0).
      (b) send '__PIREQ__\t{"line":"git \\"feature",...}' → assert decoded items count == 0,
          THEN send "git ch" → assert `checkout` present (daemon survived). Use check(c, msg).
  - BUILD the frames with string.format + vim.json.encode (matches shell.lua M.request byte-
          for-byte; avoids hand-escaping the embedded quote). See Implementation Patterns.
  - ⛔ Run via +"luafile tests/shell_fish_driver_smoke.lua" +qa (AGENTS.md HARD RULE).
```

### Implementation Patterns & Key Details

```lua
-- PATTERN: build a request frame byte-for-byte like shell.lua M.request (avoids hand-escaping
-- the embedded quote in the spec/smoke). This is the SAME encoding M.request step (6) uses:
local function make_frame(line, cursor, after)
    local l_str = vim.json.encode(line)        -- 'git "feature' -> '"git \\"feature"'
    local a_str = vim.json.encode(after or "")
    local payload = string.format("{\"line\":%s,\"cursor\":%d,\"after\":%s}", l_str, cursor, a_str)
    return string.format("__PIREQ__\t%s\n", payload)
end
-- then: stdin:write(make_frame('git "feature', 11, ""))
-- This guarantees the frame the test sends is IDENTICAL to what a real keystroke produces.

-- PATTERN: the fish guard helper + block (the whole deliverable, verbatim — copy into the
-- DAEMON_SCRIPT long-string at the points specified in Tasks 1 & 2). NOTE: this is fish source
-- inside a Lua [[ ]] string, so "\\" below is a fish single-backslash literal (NOT a Lua escape).
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
# ... in __pi_handle, after cmd extraction, before `complete -C "$cmd"`:
set -l malformed 0
if test -z "$cmd"
    set malformed 1
else
    set -l n (__pi_trailing_bs "$cmd")
    if test (math $n % 2) -eq 1
        set malformed 1
    end
end
if test $malformed -eq 1
    echo __PIRESP_START__
    printf '{"items":[],"prefix":""}\n'
    echo __PIRESP_END__
    return
end

-- CRITICAL reasoning (cite in the code comment): the simple `"line":"([^"]*)"` regex stops at
--   the FIRST `"` it sees. For a JSON value containing `\"`, that first `"` is the ESCAPED one
--   (right after a `\`), so the capture = everything up to + including that backslash, leaving a
--   dangling `\` at the end of `cmd`. fish's `complete -C` tries to "unescape the commandline"
--   and ABORTS (panic, exit 101) on an unescaped trailing `\`. An EVEN run (`echo \\`) is a
--   properly-escaped backslash → safe → NOT suppressed. Odd run = dangling → suppressed.

-- PATTERN: the LIVE spec case shape (mirror the existing "git ch → checkout" case):
--   spawn fish.start({...}, on_ready) → vim.wait ready → wire stdout read_start (rx_buf + try_parse)
--   → stdin:write(make_frame(...)) → vim.wait decoded → assert → teardown (kill+close handles).
--   For the "survival" case, send TWO frames on the SAME daemon; the rx_buf try_parse loop must
--   decode BOTH (the smoke already drains multiple START/END pairs per chunk — copy that).
```

### Integration Points

```yaml
DAEMON_SCRIPT (lua/pi-bridge/shell/fish.lua):
  - add: `function __pi_trailing_bs ... end`  (sibling of __pi_json_str)
  - add: graceful-degrade guard block in __pi_handle (after .line extraction, before complete -C)
  - update: the KNOWN LIMITATION header doc-comment (flood/panic → graceful empty)

CALL GRAPH (no new edges):
  - __pi_handle → [NEW] __pi_trailing_bs("$cmd")  (fish-local helper; never leaves the daemon)
  - The wire protocol is UNCHANGED: the guard still emits __PIRESP_START__/{"items":[],"prefix":""}/__PIRESP_END__
    (the EXACT shape shell.lua _feed already decodes for an empty result).

CONSUMER (lua/pi-bridge/shell.lua): NO CHANGE. _feed + normalize_item already turn an empty
  items array into "no menu items". (Confirm by reading shell.lua:~668; do not edit it.)

DOCUMENTATION: doc-comment only in fish.lua (the KNOWN LIMITATION bullet). P1.M2.T7.S1 owns the
  README/doc/pi-bridge-shell.txt changeset sweep — do NOT edit those here (or keep any touch to a
  single "literal `"` degrades to an empty result" sentence).

CONFIG: none (§17.11 defines no toggle for this; the guard is unconditional — it only fires on
  already-broken inputs, so there is no behavior change for valid completions).
```

## Validation Loop

> ⛔ AGENTS.md HARD RULE: write every lua snippet to a real FILE then run via
> `+"luafile <path>" +qa`. NEVER pipe a heredoc into nvim stdin (it hangs). Every nvim
> invocation is bounded by `timeout`. Run commands from the repo root.

### Level 1: Syntax & Style (Immediate Feedback)

```bash
# No luacheck/stylua/selene config — the headless load IS the syntax gate.
# (a) Compile-check the modified fish.lua loads cleanly (catches a Lua syntax error + a bad
#     DAEMON_SCRIPT long-string bracket mismatch). NB: this checks the LUA, not the fish source
#     inside the string — a fish-syntax error in DAEMON_SCRIPT only surfaces at runtime (Level 2).
timeout 30 nvim --headless --clean -u NORC -c 'set rtp+=.' -c 'lua require("pi-bridge.shell.fish")' -c 'qa' \
  && echo "OK fish.lua loads" || echo "FAIL fish.lua load"

# (b) Sanity: DAEMON_SCRIPT is still a string + M.parse/start/cd still exported (the load gate).
timeout 30 nvim --headless --clean -u NORC -c 'set rtp+=.' \
  -c 'lua local f=require("pi-bridge.shell.fish"); assert(type(f.parse)=="function"); assert(type(f.start)=="function"); assert(type(f.cd)=="function")' -c 'qa'
echo "exit=$?"

# Expected: "OK fish.lua loads" + exit 0. A non-zero exit = a Lua syntax error — fix before Level 2.
```

### Level 2: Unit Tests (Component Validation)

```bash
# The PRIMARY gate — the LIVE fish driver spec (incl. the NEW graceful-degrade + survival cases).
# Gated on `fish` on PATH (pending-skip otherwise — PRD §17.15).
timeout 90 nvim --headless --clean -u tests/minimal_init.lua \
  -c 'lua require("plenary.busted").run("tests/shell_fish_driver_spec.lua")'
echo "exit=$?"

# The plenary-free smoke (file-based; same surface).
timeout 60 nvim --headless --clean -u NORC +"luafile tests/shell_fish_driver_smoke.lua" +qa
echo "exit=$?"   # expects SMOKE_PASS (or SMOKE_SKIP if no fish) + exit 0

# Regression: M.parse is UNCHANGED — the pure-Lua parser spec must stay green.
timeout 90 nvim --headless --clean -u tests/minimal_init.lua \
  -c 'lua require("plenary.busted").run("tests/shell_fish_spec.lua")'
echo "exit=$?"

# Expected: all PASS / exit 0. If a LIVE case fails, READ the plenary output — a hang/timeout on
# the "survival" follow-up means the panic still killed the daemon (the guard didn't fire). Do NOT
# weaken the assertion; fix the guard (most likely the $cmd was passed UNquoted to __pi_trailing_bs,
# or the "\\" comparison is wrong — see research/ §3).
```

### Level 3: Integration Testing (System Validation)

```bash
# Full fish/shell test surface (catches a regression in start/ensure/_feed/teardown from the
# DAEMON_SCRIPT edit, and confirms no uv handle leak was introduced).
timeout 90 nvim --headless --clean -u tests/minimal_init.lua \
  -c 'lua require("plenary.busted").run("tests/shell_fish_smoke.lua")' 2>/dev/null || true
timeout 60 nvim --headless --clean -u NORC +"luafile tests/shell_fish_smoke.lua" +qa
timeout 60 nvim --headless --clean -u NORC +"luafile tests/shell_smoke.lua" +qa
timeout 90 nvim --headless --clean -u tests/minimal_init.lua \
  -c 'lua require("plenary.busted").run("tests/shell_feed_spec.lua")'
timeout 90 nvim --headless --clean -u tests/minimal_init.lua \
  -c 'lua require("plenary.busted").run("tests/shell_complete_current_spec.lua")'

# Expected: all PASS. No hangs (every command has a bounded timeout per AGENTS.md).
```

### Level 4: Creative & Domain-Specific Validation

```bash
# The definitive end-to-end proof: drive the REAL fish DAEMON_SCRIPT (as the driver sources it)
# with the full failure matrix + a persistence check. Write to a FILE (AGENTS.md HARD RULE).

cat > /tmp/pi_fish_guard_e2e.lua <<'LUA'
-- Spawns the REAL fish driver, sends the failure matrix + a survival follow-up through ONE
-- daemon, asserts each response. Mirrors shell_fish_driver_smoke.lua's wire/decode idiom.
local fish = require("pi-bridge.shell.fish")
local uv = vim.uv
local fails = 0
local function check(c, m) if not c then io.stderr:write("FAIL: "..m.."\n"); fails = fails + 1 end end
if vim.fn.executable("fish") == 0 then io.stdout:write("SKIP: no fish\n"); return end

local proc, stdin, stdout
local rx, resolver = "", nil
local function try_parse()
  local s = rx:find("__PIRESP_START__\n", 1, true); if not s then return end
  local ps = s + #"__PIRESP_START__\n"
  local e = rx:find("__PIRESP_END__\n", ps, true); if not e then return end
  local body = rx:sub(ps, e - 1); rx = rx:sub(e + #"__PIRESP_END__\n")
  local ok, d = pcall(vim.json.decode, body)
  if ok and type(d) == "table" then local r = resolver; resolver = nil; if r then r(d.items or {}) end end
end
local function mkframe(line, cur) return string.format('__PIREQ__\t{"line":%s,"cursor":%d,"after":""}', vim.json.encode(line), cur) end
local function send(line, cur, cb) resolver = cb; pcall(function() stdin:write(mkframe(line, cur).."\n") end) end

local ready = false
fish.start({shell="fish", cwd=vim.fn.getcwd(), startup_timeout_ms=5000}, function(err,p,si,so)
  if err then ready=true; check(false, "start err="..tostring(err)); return end
  proc,stdin,stdout = p,si,so
  pcall(function() stdout:read_start(function(_,data)
    if not data then return end; rx = rx..data
    while rx:find("__PIRESP_START__\n",1,true) and rx:find("__PIRESP_END__\n",(rx:find("__PIRESP_START__\n",1,true) or 1)+1,true) do try_parse() end
  end) end)
  ready = true
end)
vim.wait(8000, function() return ready end, 20)

local r1, r2, r3, r4
send("git ch", 6, function(it) r1 = it; send('git "feature', 11, function(it2) r2 = it2;
  send("", 0, function(it3) r3 = it3; send("git che", 7, function(it4) r4 = it4 end) end) end) end)
vim.wait(10000, function() return r4 ~= nil end, 20)

-- (1) normal STILL works (no over-suppression)
check(r1 ~= nil, "r1 (git ch) never resolved")
if r1 then local has=false; for _,it in ipairs(r1) do if it.value=="checkout" then has=true end end; check(has, "r1 missing checkout (guard over-suppressed!)") end
-- (2) quote-line → EMPTY (no panic, no flood)
check(r2 ~= nil, "r2 (quote-line) never resolved — DAEMON PANICKED+DIED (guard did not fire)")
if r2 then check(#r2 == 0, "r2 should be EMPTY, got "..#r2.." items (flood!)") end
-- (3) empty line → EMPTY (no flood)
check(r3 ~= nil, "r3 (empty) never resolved")
if r3 then check(#r3 == 0, "r3 should be EMPTY, got "..#r3.." items (flood!)") end
-- (4) SURVIVAL: after the malformed r2/r3, the SAME daemon completes git che → checkout
check(r4 ~= nil, "r4 (git che) never resolved — daemon died on a malformed input")
if r4 then local has=false; for _,it in ipairs(r4) do if it.value=="checkout" then has=true end end; check(has, "r4 missing checkout (daemon did NOT survive the quote/empty inputs)") end

pcall(function() if proc and not proc:is_closing() then uv.process_kill(proc,"sigkill") end end)
pcall(function() if proc and not proc:is_closing() then proc:close() end end)
pcall(function() if stdin and not stdin:is_closing() then stdin:close() end end)
pcall(function() if stdout and not stdout:is_closing() then stdout:read_stop(); stdout:close() end end)
package.loaded["pi-bridge.shell.fish"] = nil
if fails > 0 then io.stderr:write(fails.." check(s) FAILED\n"); vim.cmd("cquit 1") end
io.stdout:write("E2E_PASS: graceful-degrade + daemon-survival verified\n")
LUA
timeout 60 nvim --headless --clean -u NORC -c 'set rtp+=.' +"luafile /tmp/pi_fish_guard_e2e.lua" +qa
echo "exit=$?"   # fish present → E2E_PASS + exit 0 ; absent → SKIP (Level 2 gates it regardless)

# Expected (fish present): E2E_PASS + exit 0. The decisive assertion is r2 EMPTY + r4 has checkout
# (proves both the flood-fix and the panic-fix + daemon survival in ONE run).
```

## Final Validation Checklist

### Technical Validation
- [ ] Level 1: `fish.lua` loads headless (the `require` + export-assert commands print OK / exit 0).
- [ ] Level 2: `tests/shell_fish_driver_spec.lua` PASS (incl. the NEW graceful-degrade + survival cases).
- [ ] Level 2: `tests/shell_fish_driver_smoke.lua` prints `SMOKE_PASS` + exit 0 (or `SMOKE_SKIP`, no fish).
- [ ] Level 2: `tests/shell_fish_spec.lua` PASS (M.parse regression — UNCHANGED).
- [ ] Level 3: `shell_fish_smoke` / `shell_smoke` / `shell_feed_spec` / `shell_complete_current_spec` PASS.
- [ ] Level 4: `/tmp/pi_fish_guard_e2e.lua` prints `E2E_PASS` (r2 empty + r4 has checkout).
- [ ] No `uv_timer_t` / handle leak (the existing no-leak cases still pass; the guard adds none).

### Feature Validation
- [ ] Empty line → `{"items":[],"prefix":""}` (0 items; was 5456+ flood).
- [ ] Quote-line (`git "feature`) → 0 items AND daemon survives the next normal request (was panic+death).
- [ ] `git ch` → checkout still present (guard does not over-suppress valid completions).
- [ ] `echo \\` (even backslashes) → still passed to `complete -C` (no false-positive suppression).
- [ ] The KNOWN LIMITATION header doc-comment reflects the new graceful-empty behavior.

### Code Quality Validation
- [ ] The guard mirrors the file's never-throws + defensive discipline (pure-addition; no new throw path).
- [ ] `__pi_trailing_bs` uses the regex-free chop-loop (NOT the fragile `string match -r '\\+$' -- $cmd`).
- [ ] `$cmd` is passed to `__pi_trailing_bs` QUOTED (`"$cmd"`) — no word-splitting.
- [ ] The `"\\="` backslash comparison is a fish single-backslash literal (double-quoted in the source).
- [ ] No change to `M.parse` / `M.start` / `M.cd` / shell.lua / the wire protocol / the complete-C loop.
- [ ] Comments cite Issue 6 + the flood/panic modes + the parity reasoning.

### Documentation & Deployment
- [ ] Code is self-documenting (the guard block explains both failure modes + the parity invariant inline).
- [ ] No new env var / config key (§17.11 defines none; the guard is unconditional + behavior-preserving).
- [ ] (P1.M2.T7.S1 owns the README/doc sweep — keep this task to fish.lua + the tests + the in-file comment.)

---

## Anti-Patterns to Avoid

- ❌ Do NOT implement an empty-ONLY guard ("if cmd == \"\" emit empty"). That fixes the flood but
  NOT the panic — the Issue 6 headline repro (`git "feature`) extracts to `cmd = "git \"` (NOT
  empty) and still panics/kills the daemon. The guard MUST also catch the odd-trailing-backslash case.
- ❌ Do NOT detect "ends with a backslash" with a naive presence check — `echo \\` (two backslashes)
  is a VALID escaped backslash and must NOT be suppressed. Check the trailing-backslash PARITY (odd).
- ❌ Do NOT use `string match -r '\\+$' -- $cmd` with an UNQUOTED `$cmd` — fish word-splits on the
  space in `git \`, the match is unreliable (returned NOTHING in LIVE tracing), the guard never
  fires, and the panic still hits. Use the regex-free `__pi_trailing_bs` chop-loop with `"$cmd"` quoted.
- ❌ Do NOT write `'\\'` expecting one backslash in fish — fish single quotes are fully literal
  (no escape); `'\\'` is TWO backslashes. A single backslash literal is `"\\"` (double-quoted).
- ❌ Do NOT Lua-escape the fish escapes inside `DAEMON_SCRIPT` — it is a `[[ ]]` long-string; its
  content is LITERAL fish source. Write the fish exactly as it must execute.
- ❌ Do NOT touch `M.parse` (the pure-Lua parser) or shell.lua — both are correct + out of scope.
- ❌ Do NOT modify zsh.lua / bash.lua — that is P1.M2.T6.S2 (separate task; their quote-cases
  reportedly flood rather than panic, but S2 must verify each empirically).
- ❌ Do NOT hand-escape the embedded `"` in test frames — build them with `vim.json.encode` (the
  same encoding shell.lua M.request uses) so the test frame is byte-identical to a real keystroke.
- ❌ Do NOT weaken a test assertion to make it pass; if the "survival" follow-up hangs/times out,
  the guard didn't fire — fix the guard (re-read research/ §3), don't relax the check.
- ❌ Do NOT pipe a heredoc into `nvim` stdin (AGENTS.md HARD RULE — it hangs the session). Write
  lua to a FILE, run via `+"luafile <path>" +qa`, always bounded by `timeout`.

---

**Confidence Score: 9/10** — the fix is a pure-addition guard inside one fish source string, with
the exact (empirically-verified) code, the precise failure-mode matrix (flood AND panic), the
fish-quoting landmines (and the idiom that avoids them), and a definitive end-to-end Level-4
script all specified. The one residual uncertainty: the LIVE spec/smoke cases depend on `fish`
being installed on the validation box (the Level-4 e2e SKIPs cleanly otherwise, and the offline
Level-1 load gate still catches Lua-syntax regressions). The guard's fish-side correctness is
already proven via the standalone `/tmp/fish_final_guard.fish` matrix (5/5 cases + persistence).