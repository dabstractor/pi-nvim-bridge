# Research Notes — P2.M2.T3.S1 (completion_context "shell" return value)

> Task: add a `"shell"` return value to the LOCAL `completion_context()` in
> `lua/pi-bridge/completion.lua` (currently returns `"slash" | "path" | nil`), placed
> BEFORE the existing slash/path logic. Export `M._completion_context` as a test seam.

## §0 — Task boundary fence (what S1 owns vs siblings)

- **S1 OWNS (this task):** (a) the `"shell"` early-return at the TOP of `completion_context`;
  (b) the `@return` + comment-block annotation update; (c) the `M._completion_context`
  test-seam export. NOTHING ELSE.
- **S1 does NOT own:** the `do_refresh` / `force_fetch` `"shell"` branch
  (→ **P2.M2.T3.S2**); `shell.complete_current` (→ **P2.M2.T3.S3**); the menu visual_cue
  (→ **P2.M2.T3.S5**); notices (→ **P2.M2.T3.S4**); the drivers (→ **P2.M2.T4** / **P2.M3.T5**).
- **S1 does NOT touch:** `do_refresh`, `force_fetch`, `_route_or_accept`, `M.refresh`,
  `M.reset`, `M.accept`, `on_*`, `compute_debounce`, `is_attachment_context`, the module
  header, `state`, or ANY other function. It is a SURGICAL additive edit to ONE function +
  ONE export line.

## §1 — The exact current code (the INPUT contract)

`lua/pi-bridge/completion.lua` lines 363-401 (verified verbatim this session):

```lua
-- completion_context(lines, cursorLine, cursorCol) — the CLIENT-SIDE completion gate.
-- Returns "slash" | "path" | nil. Mirrors the user's intent: completion should fire ONLY
--   • "slash" — line 1 (cursorLine 0) begins with "/"  (commands / skills / prompts + their args)
--   • "path"  — the trailing token before the cursor begins with "@", "#", ".", "~/", or "/"
--               (file/path/attachment; "@" always — pi's @file mention)
-- Plain typing (words, spaces, bare quotes) returns nil → do_refresh skips the request +
-- closes any open menu. Byte-correct on UTF-8 (trigger chars are ASCII).
---@param lines      string[] Buffer lines (raw UTF-8, as `nvim_buf_get_lines` returns).
---@param cursorLine integer 0-based line index.
---@param cursorCol  integer 0-based BYTE column.
---@return string|nil "slash" | "path" | nil
local function completion_context(lines, cursorLine, cursorCol)
  local line = (type(lines) == "table") and (lines[cursorLine + 1] or "") or ""
  local before = line:sub(1, cursorCol)                 -- 0-based byte col → bytes [1..cursorCol]
  local token = before:match("[%S]+$") or ""            -- trailing non-whitespace run
  local token_start = #before - #token                  -- 0-based byte column where `token` begins
  ... (slash / path / nil branches unchanged) ...
end
```

**The only caller** (verified via grep): `do_refresh` at line 437 —
`local ctx = completion_context(lines, row - 1, byte_col)`. `force_fetch` does NOT call
`completion_context` (it routes via `on_tab`'s own slash/file logic). So the `"shell"`
value is consumed ONLY by `do_refresh`'s `if not ctx` gate — see §3 (transitional behavior).

## §2 — The test-seam convention (M._ underscore-prefix)

`menu.lua` lines 670-676 EXPOSE module-locals on `M` for unit testing:
```lua
M._compute_width   = compute_width
M._compute_height  = compute_height
M._compute_geometry= compute_geometry
M._state           = state
M._column_metrics  = column_metrics
M._truncate        = _truncate
```
The header (menu.lua L181/L234) calls this "the M._compute_* / coords' fns test-seam
convention." `completion_spec.lua` ALREADY uses it: `menu._state.selected` (L of the on_next
test). And `completion.is_attachment_context` is exported + unit-tested DIRECTLY (the
exact analog — a pure function tested without a buffer/bridge). **S1 exports
`M._completion_context = completion_context`** following this established convention.
This is cleaner than the "test through do_refresh" alternative (which needs a fake bridge +
buffer + cursor + vim.wait — the full S30 harness — for a 2-line pure function).

## §3 — Transitional behavior (S1 → S2 window) — DOCUMENTED, not a bug

After S1 but BEFORE S2 lands, `do_refresh` sees `ctx == "shell"` (a TRUTHY string):
- `if not ctx` → FALSE → does NOT bail → proceeds to issue `getSuggestions(force=false)`
  (because `force = (ctx == "path")` → false).

**This is a temporary no-op path, not a regression:**
- pi's provider returns EMPTY/null for a `!` line (PRD §17.1: "CombinedAutocompleteProvider
  does nothing for `!` lines"). So the menu shows nothing.
- NO existing test uses a `!` line (verified: completion_spec.lua uses `/mod`, `@app`,
  `/mo`, `@sr`, `@"my dir`, etc. — none start with `!`). So the full suite stays green.
- The WORST case is one wasted RPC returning empty during the (short) S1→S2 window.

**S2 closes it** by adding `if ctx == "shell" then require("pi-bridge.shell").complete_current(...); return end`
BEFORE the getSuggestions path (PRD §17.7 h3.36). S1 must NOT add a do_refresh guard
(S1's scope is the return value ONLY; S2 owns the branch). S1's tests assert ONLY the
`completion_context` return value (the stable contract) — NOT the transitional do_refresh
behavior (a throwaway test S2 would delete).

**REGRESSION GUARD (the real invariant):** existing slash/path/nil returns are UNCHANGED
for lines that do NOT start with `!`. The shell early-return fires ONLY when `cursorLine==0`
AND `lines[1]` starts with `!`. Every other input flows through the existing branches
verbatim. The S1 tests prove this (cases 6-8, 14 below).

## §4 — The pi source reference (why line-1-only, why `!` AND `!!`)

- PRD §17.7 (h3.36): "pi's bash mode triggers on the submitted prompt's first character.
  Completion is therefore scoped to the first line. (`!` vs `!!`: irrelevant to completion —
  both route to `"shell"`; the bangs are stripped by `shell.lua` before querying.)"
- pi source: `interactive-mode.ts:2583` — `text.trimStart().startsWith("!")` (the
  isBashMode trigger). Our `cursorLine == 0 and line1:sub(1,1) == "!"` mirrors the
  "submitted prompt's first character" semantic (line 1 = the submitted prompt's first
  line). `trimStart` is N/A — the plugin reads the raw buffer line; a leading-space `!`
  line is not a real prompt (pi never produces one; the user types `!` as the very first
  char). `!!` (no-context bash) also starts with `!` → both route to "shell"; the bang
  COUNT (1 vs 2) is shell.lua's stripping concern (§17.6), NOT routing.
- PRD §17.17 (out of scope v1): multi-line/continued commands. So the check is line-1-only.

## §5 — Byte-correctness of `line1:sub(1,1) == "!"`

Lua `string.sub` is BYTE-indexed. `!` is ASCII 0x21 (1 byte). So `line1:sub(1,1)` returns
exactly the first byte; for a `!`-prefixed line that is `"!"`; for a multibyte-first line
(e.g. `日本語`) it is 0xE6 (the lead byte of 日) ≠ `"!"`. **Safe.** The existing
`completion_context` is already byte-correct (trigger chars are ASCII) — this matches.
Case 13 (`!日`) below proves it: sub(1,1) = "!" regardless of the multibyte tail.

## §6 — Test cases for M._completion_context (the Level-2 spec matrix)

Direct calls with synthetic `{lines, cursorLine, cursorCol}` (NO buffer, NO bridge):

| #  | lines                 | cursorLine | cursorCol | expect   | why                                          |
|----|-----------------------|------------|-----------|----------|----------------------------------------------|
| 1  | `{"!ls"}`             | 0          | 3         | "shell"  | single-bang line 1                           |
| 2  | `{"!!ls"}`            | 0          | 4         | "shell"  | double-bang → also "shell" (count irrelevant)|
| 3  | `{"!"}`               | 0          | 1         | "shell"  | bare bang                                    |
| 4  | `{"!ls -la"}`         | 0          | 7         | "shell"  | bang + args (whole line is a shell command)  |
| 5  | `{"!/usr/bin/foo"}`   | 0          | 13        | "shell"  | bang + path-like → "shell" (NOT "path")      |
| 6  | `{"echo hi"}`         | 0          | 7         | nil      | no bang → plain (regression)                 |
| 7  | `{"/model"}`          | 0          | 6         | "slash"  | regression: slash unchanged                  |
| 8  | `{"@app"}`            | 0          | 4         | "path"   | regression: @-path unchanged                 |
| 9  | `{"./x"}`             | 0          | 3         | "path"   | regression: ./-path unchanged                |
| 10 | `{"!ls"}`             | 1          | 3         | nil      | cursor on LINE 2 → not line-1 → not shell    |
| 11 | `{"!ls", "more"}`     | 1          | 4         | nil      | multi-line, cursor line 2                    |
| 12 | `{}`                  | 0          | 0         | nil      | empty lines table → defensive (line1="")     |
| 13 | `nil` (no table)      | 0          | 0         | nil      | nil lines → type-guard (line1="")            |
| 14 | `{"!日"}`             | 0          | 4         | "shell"  | multibyte tail; sub(1,1)="!" (byte-safe)     |
| 15 | `{"  !ls"}`           | 0          | 5         | nil*     | leading-space — NOT a real prompt (see note) |

(*) Case 15: `line1:sub(1,1)` is a SPACE, not `!` → not shell → falls through → token `!ls`
→ nil. This matches pi: a leading-space prompt is never produced by the TUI (the user's `!`
is the first char). If a future need arises for `trimStart`, that is an S-later refinement;
v1 is byte-1-only (PRD §17.7 verbatim snippet).

## §7 — References (verified this session)

- `lua/pi-bridge/completion.lua:363-401` — the function to edit (verbatim in §1).
- `lua/pi-bridge/menu.lua:670-676` — the `M._*` test-seam convention.
- `tests/completion_spec.lua:1006-1052` — the `is_attachment_context` direct-unit-test
  describe block (the EXACT pattern S1's spec mirrors).
- `tests/completion_smoke.lua:1-40` — the plenary-free smoke format (`check`/`fails`/`SMOKE_PASS`).
- `lua/pi-bridge/completion.lua:437` — the ONLY caller of `completion_context` (do_refresh).
- PRD §17.7 (h3.36) — the verbatim Lua snippet + the line-1-only / `!`+`!!` rationale.
- PRD §17.1 (h3.30) — scope (single-line `!`/`!!`; out-of-scope: multi-line).
- AGENTS.md — the HARD RULE (write test to a FILE; never heredoc→nvim stdin; wrap in `timeout`).