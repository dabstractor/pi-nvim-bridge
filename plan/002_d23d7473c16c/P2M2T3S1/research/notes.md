# Research notes — P2.M2.T3.S1 (`completion_context` → `"shell"` gate)

## Task (verbatim)
> Add 'shell' return value to completion_context() before slash/path checks.

PRD §17.7 gives the exact code. This is the **routing gate only** — the branch that
actually calls `shell.lua` is **S2**; `shell.complete_current` is **S3**.

## Current shape of `completion_context` (lua/pi-bridge/completion.lua:363-401)
- `local function completion_context(lines, cursorLine, cursorCol)` — **NOT exported**.
- Returns `"slash" | "path" | nil`.
- Called ONLY by `do_refresh` (line 437: `local ctx = completion_context(lines, row - 1, byte_col)`).
  - `do_refresh`: `if not ctx then … close + return end` then proceeds to the bridge path with
    `force = (ctx == "path")`.
- `on_tab` (Tab handler, lines ~760-800) does **NOT** call `completion_context` — it computes
  its own `is_slash_ctx` inline (`pi.cursorLine == 0 and trimmed:sub(1,1) == "/"`).
  → S1 touches NEITHER `do_refresh` NOR `on_tab`; S2 owns both branches.

## Export precedent
- `M.is_attachment_context = function(text_before_cursor)` (line 297) — a PURE helper
  exported for direct unit testing.
- `tests/completion_spec.lua:1016` has `describe("is_attachment_context (direct unit cases)", …)`.
- → S1 should export `M.completion_context = completion_context` (alias) and add a sibling
  `describe("completion_context — shell/bash-mode gate (§17.7)", …)` direct-unit block.
  `compute_debounce` is local by contrast, but it has no standalone unit block; the gate
  DOES need one (the return value IS the deliverable).

## The exact edit (PRD §17.7)
At the TOP of `completion_context`'s body, before the existing `local line = …` block:
```lua
-- §17.7 NEW: bash mode is line 1 starting with "!". Checked FIRST so it wins over
-- slash/path. Catches BOTH "!" and "!!" (bang-count strip happens later in shell.lua S3).
local line1 = (type(lines) == "table") and (lines[1] or "") or ""
if cursorLine == 0 and line1:sub(1, 1) == "!" then return "shell" end
```
Plus: update docstring bullet list + `@return` to include `"shell"`.

## Why placement & checks are exactly this
- **First line only** (`cursorLine == 0`): pi's bash mode triggers on the submitted prompt's
  first character (PRD §17.1, §17.7; pi `interactive-mode.ts:2757` `text.startsWith("!")` on
  the whole prompt). Multi-line/continued commands are §17.17 future.
- **Whole `line1`, not `token`**: a `!git ch` line has trailing token `ch` (a word) → without
  this check it returns nil (no completion). The gate must look at line 1's first CHAR.
- **`!` vs `!!`**: `sub(1,1)=="!"` matches both; routing is identical; the double-bang strip
  is `shell.lua`'s job (S3), not the gate's.
- **Before slash/path**: a `!@x` or `!./p` line is a SHELL command, not a pi attachment/path —
  shell must win. (Also the slash check keys off `token:sub(1,1)=="/"`, which a `!` line never
  hits, so ordering is also about clarity + the `!@`/`!./` precedence.)

## Intermediate-state behavior (S1 shipped, S2 not yet) — IMPORTANT
With S1 alone, a `!` line in `do_refresh`:
1. `completion_context` → `"shell"` (truthy) → does NOT take the `if not ctx` close-branch.
2. Proceeds to bridge path, `force = (ctx == "path")` = **false**.
3. Issues `getSuggestions` RPC for the `!` line.
4. pi's `CombinedAutocompleteProvider` returns **null** for `!` lines (PRD §17.1: "does
   nothing for `!` lines") → cb normalizes null→`{items={},prefix=""}` → `on_results(buf,{ },"")`
   → menu closes.
   - EDGE: a `! ./foo` line's `.`-token MAY make pi return path completions in the gap (minor
     UX wart, not a crash). **S2 routes `!` lines to `shell.lua` instead and removes the RPC.**
- => S1 is **inert re: actual shell completion** and emits a wasted round-trip on `!` keystrokes
  until S2 lands. This is the cost of the atomic task split and is EXPECTED. S1's own validation
  is the direct unit test of the return value (no daemon, no bridge).

## No existing-test collision
`grep '!|bang|shell|bash' tests/completion_spec.lua tests/completion_smoke.lua` → no `!`-prefixed
"plain typing" case exists. S1 reclassifies no existing fixture. (Regression guard: add a
non-bang line-1 case asserting unchanged slash/path/nil.)

## Validation commands (AGENTS.md-safe; NEVER heredoc→nvim stdin)
- Plenary (the gate): `timeout 90 nvim --headless --clean -u tests/minimal_init.lua -c 'lua require("plenary.busted").run("tests/completion_spec.lua")'`
- Smoke (optional, plenary-free): `timeout 60 nvim --headless --clean -u NORC +"luafile tests/completion_smoke.lua" +qa`

## Out of scope (S2-S5)
- S2: `do_refresh` + `force_fetch`/`on_tab` shell branch (route `ctx=="shell"` → `shell.*`).
- S3: `shell.complete_current(buf, cb)` (read buf, strip bangs, byte offsets, call `shell.request`).
- S4: mismatch notice (§17.4.3), first-run hint (§17.9), degrade notify.
- S5: menu `visual_cue` for shell context (`$` gutter).