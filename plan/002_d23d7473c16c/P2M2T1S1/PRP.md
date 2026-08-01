# PRP — P2.M2.T3.S1: Add `'shell'` return value to `completion_context()` before slash/path checks

> **Plan mapping:** task `P2.M2.T3.S1` ("Add 'shell' return value to completion_context() before slash/path checks").
> First subtask of **P2.M2.T3** ("completion.lua routing + shell.complete_current + notices") within the **Shell
> Completion for !/!! Bash Mode** epic (PRD §17). This is the **ROUTING-GATE layer** of `completion_context`:
> it adds a `"shell"` early-return at the very TOP of the LOCAL function (BEFORE the existing token/slash/path
> branches) so a `!`/`!!` (bash-mode) line routes to shell completion instead of falling through to `nil`.
> It is the SMALLEST possible slice — ONE early-return + ONE annotation update + ONE test-seam export — and
> NOTHING else.
>
> **Critical scope fact:** S1 adds the return value ONLY. The `do_refresh`/`force_fetch` `"shell"` BRANCH (the
> `require("pi-bridge.shell").complete_current(...)` call) is **P2.M2.T3.S2** — a SEPARATE, sibling task. S1 does
> NOT touch `do_refresh`, `force_fetch`, `_route_or_accept`, `compute_debounce`, `is_attachment_context`,
> `M.refresh`/`reset`/`accept`/`on_*`, the module header, `state`, or ANY other function. The shell check is
> placed FIRST (before the slash/path logic) so a `!` line never reaches the slash/path branches — this is the
> exact ordering the PRD §17.7 snippet mandates. Export `M._completion_context` as a test seam so the LOCAL
> function is directly unit-testable (the established `menu._state` / `menu._compute_*` /
> `completion.is_attachment_context` convention).
>
> **Why FIRST (before slash/path):** a `!` line is a SHELL command in its entirety (PRD §17.1). If the slash/path
> logic ran first, `!ls @file` would mis-route to `"path"` (the `@file` token) — WRONG (the `@file` is a shell
> argument, not a pi attachment). The early-return guarantees the WHOLE `!` line is "shell", exactly mirroring
> pi's `text.trimStart().startsWith("!")` (`interactive-mode.ts:2583`), which fires before pi's own slash/path
> provider arms.
>
> **Transitional window (S1 → S2) — documented, NOT a bug:** after S1 lands but before S2, `do_refresh` sees
> `ctx == "shell"` (truthy) → does NOT bail at `if not ctx` → issues `getSuggestions(force=false)`. pi's provider
> returns EMPTY for `!` lines (PRD §17.1) so the menu shows nothing — a harmless no-op RPC. NO existing test uses
> a `!` line (verified), so the suite stays green. S2 closes the window by adding the `if ctx == "shell" then …complete_current… return end`
> branch. S1's tests assert ONLY the `completion_context` return value (the stable contract) — NOT the transitional
> do_refresh behavior (a throwaway test S2 would delete). (research §3.)

---

## Goal

**Feature Goal**: Extend the LOCAL `completion_context(lines, cursorLine, cursorCol)` in `lua/pi-bridge/completion.lua`
to return `"shell"` when **line 1** (the submitted prompt's first line) begins with `"!"` — the bash-mode trigger
(`!` = run bash; `!!` = run bash, no context). The check is placed as the **very first** statement inside the
function (BEFORE the existing slash/path/nil branches), mirroring pi's `text.trimStart().startsWith("!")`
(`interactive-mode.ts:2583`). Both single-bang (`!`) and double-bang (`!!`) route to `"shell"` — the bang-count
distinction is `shell.lua`'s stripping concern (PRD §17.6), NOT routing. Existing `"slash"`/`"path"`/`nil`
behavior for every input that does NOT start with `!` is **UNCHANGED** (regression guard). Also export the LOCAL
function as `M._completion_context` for direct unit testing (the established `M._*` test-seam convention).

**Deliverable** (ONE source file EDITED + 1 new smoke file + 1 describe block added to an existing spec — nothing
else touched):
- **`lua/pi-bridge/completion.lua`** — THREE surgical edits to the `completion_context` function (lines 363-401):
  (a) **ADD** the shell early-return (2 lines + a [Mode A] docstring) as the FIRST statements inside the function
  body, before `local line = (type(lines) == "table") and (lines[cursorLine + 1] or "") or ""`; (b) **UPDATE** the
  `---@return` annotation from `"slash" | "path" | nil` to `"slash" | "path" | "shell" | nil`; (c) **UPDATE** the
  comment-block header above the function to list `"shell"` (one bullet). PLUS **ADD** one export line
  `M._completion_context = completion_context` near the other public-API exports. ZERO edits to any other function,
  the module header, `state`, or `do_refresh`/`force_fetch`.
- **`tests/completion_context_shell_smoke.lua`** — NEW plenary-free smoke (mirror `tests/completion_smoke.lua`
  header + the `coords_smoke.lua` `check`/`fails`/`cquit`/`SMOKE_PASS` footer): exercises the
  `M._completion_context` matrix directly (no buffer, no bridge) — the 15 cases in research §6. Prints `SMOKE_PASS`;
  exit 0.
- **`tests/completion_spec.lua`** — EDIT (additive): ONE new `describe("completion_context: shell routing",
  function() … end)` block (mirror the existing `"is_attachment_context (direct unit cases)"` describe block at
  the top of the S40 section) with `it(...)` cases for the same matrix. Plenary/busted.

**Success Definition**:
- `require("pi-bridge.completion")._completion_context` is a function (the test seam). Calling it with
  `{ "!ls" }, 0, 3` returns `"shell"`; `{ "!!ls" }, 0, 4` returns `"shell"`; `{ "!" }, 0, 1` returns `"shell"`.
- Line-1-only scoping: `{ "!ls" }, 1, 3` (cursor on line 2) returns `nil` (NOT `"shell"`).
- Regression guard: `{ "/model" }, 0, 6` → `"slash"`; `{ "@app" }, 0, 4` → `"path"`; `{ "echo hi" }, 0, 7` → `nil`;
  `{ "./x" }, 0, 3` → `"path"` — ALL unchanged from pre-S1 behavior.
- Defensive: `{}` (empty lines) and `nil` (non-table lines) → `nil` (the `type(lines)=="table"` guard holds; no throw).
- Byte-correct: `{ "!日" }, 0, 4` → `"shell"` (`!` is ASCII byte 1; the multibyte tail does not skew `sub(1,1)`).
- `tests/completion_context_shell_smoke.lua` prints `SMOKE_PASS` (exit 0); the new `completion_spec.lua` describe
  block is green (0 fail, 0 error).
- The FULL existing suite stays green: `completion_spec` (S30/S32/S33/S36/S37/S40/S41), `completion_smoke`,
  `completion_accept_smoke`, `completion_tab_smoke`, `menu_*`, `bridge_*`, `init_spec`, `coords_*`, `shell_*`
  (no existing test uses a `!` line → nothing regresses).
- `do_refresh` is UNCHANGED (S2 owns its `"shell"` branch). The `@return` annotation + comment block list
  `"shell"`. NO edit to `extension/*`, `doc/*`, `ftplugin/*`, `plugin/*`, `shell.lua`, `bridge.lua`, `init.lua`,
  `menu.lua`, `notify.lua`, or `README.md`.

## User Persona (if applicable)

**Target User**: the implementer of **P2.M2.T3.S2** ("Add shell branch to do_refresh + force_fetch"). That task
adds `if ctx == "shell" then require("pi-bridge.shell").complete_current(buf, cb); return end` to `do_refresh` and
`force_fetch` — it RELIES on S1's `completion_context` returning `"shell"` for a `!` line. Secondary consumer:
**P2.M2.T3.S5** (menu visual_cue reads `ctx == "shell"` for the `$` gutter prefix — PRD §17.9). Tertiary:
**P2.M2.T3.S4** (notices — the first-run hint fires when a `!` line is detected, which S1's return value enables).

**Use Case**: a user opens pi's external editor and types `!ls<Tab>` (or `!!docker ps`). Today (pre-S1),
`completion_context` returns `nil` for the `!` line → no completion of any kind (PRD §17.1). After S1+S2 land,
the `!` line routes to `"shell"` → the user's shell's own completion engine (fish/zsh/bash) produces candidates
in the existing menu. **S1 alone** produces the routing signal (the return value); S2 wires it to the daemon.

**Pain Points Addressed**: without S1, there is NO completion for shell commands in the external editor — the
single largest gap vs pi's TUI bash mode (PRD §17.1: "there is no completion of any kind for shell commands
today"). S1 is the first brick: it makes `completion_context` AWARE of bash mode. The full feature (candidates
in the menu) requires S2-S5; S1 is the unblocking prerequisite.

## Why

- **It is the explicit §17.7 step-1 routing primitive.** PRD §17.7 (h3.36): *"`completion_context()` gains a
  `"shell"` return value. The check is precise and unambiguous (it mirrors pi's own
  `text.trimStart().startsWith('!')`): `local line1 = (lines or {})[1] or ""; if cursorLine == 0 and
  line1:sub(1,1) == '!' then return 'shell' end`."* S1 implements this verbatim. The §17.16 Phase-6 plan sequences
  routing (this task) before the do_refresh branch (S2) before `complete_current` (S3).
- **Ordering BEFORE slash/path is a hard correctness requirement, not a style choice.** If the existing
  slash/path logic ran first, `!ls @file` would return `"path"` (the trailing `@file` token matches the `@`
  attachment trigger) — WRONG: the `@file` is an argument to `ls`, not a pi attachment mention. The early-return
  guarantees the WHOLE `!` line is `"shell"`, matching pi's own precedence (bash-mode detection fires before
  autocomplete arming). The PRD snippet places the check "NEW (before the existing slash/path checks)" — S1 honors
  that placement exactly. (research §4.)
- **Line-1-only scoping is pi-faithful.** PRD §17.7: "pi's bash mode triggers on the submitted prompt's first
  character. Completion is therefore scoped to the first line." The `cursorLine == 0` guard enforces this.
  Multi-line/continued commands are explicitly out of scope v1 (§17.17). (research §4.)
- **`!` vs `!!` routing is intentionally identical.** PRD §17.7: "`!` vs `!!`: irrelevant to completion — both
  route to `"shell"`; the bangs are stripped by `shell.lua` before querying." S1's check (`sub(1,1) == "!"`)
  matches BOTH (both start with `!`). The bang-count stripping is `shell.lua`'s job (§17.6, → P2.M2.T3.S3) — S1
  does NOT strip, count, or care. (research §4.)
- **The test seam (`M._completion_context`) follows a codified repo convention.** `menu.lua` exposes
  `M._state`, `M._compute_width`, `M._compute_geometry`, `M._column_metrics`, `M._truncate` (lines 670-676) —
  its header (L181/L234) names this "the M._compute_* / coords' fns test-seam convention." `completion.lua`
  ALREADY exports + unit-tests `M.is_attachment_context` DIRECTLY (the exact analog — a pure function tested
  without a buffer/bridge). S1 exports `M._completion_context` the same way. This is cleaner than "test through
  do_refresh" (which needs a fake bridge + buffer + cursor + `vim.wait` — the full S30 harness — for a 2-line
  pure function). (research §2.)
- **S1 is a prerequisite that unblocks 4 sibling tasks.** S2 (do_refresh branch), S3 (complete_current),
  S4 (notices), S5 (visual_cue) ALL branch on `ctx == "shell"`. Without S1's return value, none can be built or
  tested in isolation. S1 is the smallest possible unblocking slice. (research §0.)

## What

**User-visible behavior**: none at runtime yet (no caller wires the `"shell"` value into shell completion — that
is S2's `do_refresh` branch). The observable artifact is the function's return value + the test verdicts:

```bash
$ timeout 60 nvim --headless --clean -u NORC +"luafile tests/completion_context_shell_smoke.lua" +qa
SMOKE_PASS
$ echo "exit=$?"
exit=0
```

**Technical requirements** (all in `lua/pi-bridge/completion.lua` unless noted):
- **The shell early-return** (NEW; the FIRST statements inside `completion_context`, before the existing
  `local line = …` line). Exact logic (PRD §17.7 verbatim shape):
  ```lua
  -- SHELL (bash mode): line 1 (cursorLine 0) beginning with "!" is a shell command — pi's
  -- bash mode (interactive-mode.ts:2583: text.trimStart().startsWith("!")). Scoped to line 1
  -- ONLY (pi triggers on the submitted prompt's first char; multi-line continued commands are
  -- future — §17.17). Both "!" (run bash) and "!!" (run bash, no context) route to "shell";
  -- the bang-count distinction is shell.lua's stripping concern (§17.6), NOT routing. This
  -- check runs FIRST so a "!ls @file" line is a whole shell command (NOT a pi @-attachment).
  local line1 = (type(lines) == "table") and (lines[1] or "") or ""
  if cursorLine == 0 and line1:sub(1, 1) == "!" then return "shell" end
  ```
  - `type(lines) == "table"` guard: a non-table `lines` (nil/number/string) → `line1 = ""` → `sub(1,1)` is `""`
    ≠ `"!"` → not shell → falls through to the existing (also type-guarded) slash/path logic. **Never throws.**
  - `lines[1] or ""`: a 1-indexed Lua array (as `nvim_buf_get_lines` returns); an empty/short table → `""` →
    not shell. Matches the existing `lines[cursorLine + 1] or ""` idiom (1-based).
  - `line1:sub(1, 1)`: BYTE slice. `!` is ASCII 0x21 (1 byte) → exactly `"!"` for a bang-prefixed line; a
    multibyte-first line yields its lead byte (≠ `"!"`). **Byte-correct** (research §5).
- **The `@return` annotation** (UPDATE): `---@return string|nil "slash" | "path" | nil` →
  `---@return string|nil "slash" | "path" | "shell" | nil`.
- **The comment-block header** (UPDATE, the 4-line `--` block directly above the function): add a bullet
  `• "shell" — line 1 (cursorLine 0) begins with "!"  (pi bash mode: run bash / run bash no-context)` and change
  the opening line `-- Returns "slash" | "path" | nil.` → `-- Returns "slash" | "path" | "shell" | nil.`
- **The test-seam export** (ADD): `M._completion_context = completion_context` — placed in the public-API
  exports region (near `M.is_attachment_context` / `M.on_results` / the other `M.` assignments). The `_` prefix
  signals "internal/test-only" (the `menu._state` convention).
- **NEVER throws; NO nvim API; NO state mutation; NO bridge/daemon call.** `completion_context` is a PURE
  function (the existing header says so). S1's addition is pure too. The smoke/spec call it with synthetic
  `{lines, cursorLine, cursorCol}` — NO buffer, NO bridge, NO autocmd.

### Success Criteria

- [ ] `lua/pi-bridge/completion.lua` exposes `M._completion_context` as a function (the test seam).
- [ ] `M._completion_context({ "!ls" }, 0, 3)` → `"shell"`; `({ "!!ls" }, 0, 4)` → `"shell"`; `({ "!" }, 0, 1)` → `"shell"`.
- [ ] Line-1-only: `({ "!ls" }, 1, 3)` (cursorLine 1) → `nil` (NOT `"shell"`); `({ "!ls", "x" }, 1, 1)` → `nil`.
- [ ] Regression guard: `({ "/model" }, 0, 6)` → `"slash"`; `({ "@app" }, 0, 4)` → `"path"`; `({ "./x" }, 0, 3)` → `"path"`; `({ "echo hi" }, 0, 7)` → `nil` — ALL unchanged.
- [ ] Defensive: `({}, 0, 0)` → `nil`; `(nil, 0, 0)` → `nil`; `("notatable", 0, 0)` → `nil` (type-guard; no throw).
- [ ] Byte-correct: `({ "!日" }, 0, 4)` → `"shell"` (ASCII `!` is byte 1; multibyte tail does not skew `sub(1,1)`).
- [ ] The shell early-return is the FIRST statement inside `completion_context` (BEFORE the `local line = …` token
      analysis) — verified by reading the function top.
- [ ] The `@return` annotation lists `"slash" | "path" | "shell" | nil`; the comment-block header lists `"shell"`.
- [ ] `tests/completion_context_shell_smoke.lua` prints `SMOKE_PASS` (exit 0).
- [ ] The new `completion_spec.lua` `describe("completion_context: shell routing", …)` block is green.
- [ ] The FULL existing suite stays green (`completion_spec`, `completion_smoke`, `completion_accept_smoke`,
      `completion_tab_smoke`, `menu_*`, `bridge_*`, `init_spec`, `coords_*`, `shell_*`).
- [ ] NO edit to `do_refresh`, `force_fetch`, `_route_or_accept`, `compute_debounce`, `is_attachment_context`,
      `M.refresh`/`reset`/`accept`/`on_*`, the module header, `state`, OR any file under `extension/`, `doc/`,
      `ftplugin/`, `plugin/`, `shell.lua`, `bridge.lua`, `init.lua`, `menu.lua`, `notify.lua`, `README.md`.

## All Needed Context

### Context Completeness Check

_Passes "No Prior Knowledge":_ an implementer who has never seen this repo gets (a) the verbatim current
`completion_context` source (lines 363-401, reproduced in research §1) — the EXACT function to edit, with the
EXACT insertion point (before `local line = …`), the EXACT `@return` line to change, and the EXACT comment-block
header to update; (b) the verbatim PRD §17.7 snippet (the exact 2-line check + the line-1-only / `!`+`!!`
rationale) and PRD §17.1 (scope: single-line, bash-mode); (c) the canonical in-repo reference for the `M._*`
test-seam convention (`menu.lua:670-676` + its header naming the convention) AND the direct analog already in
`completion.lua` (`M.is_attachment_context`, exported + unit-tested in `completion_spec.lua:1006-1052` — the
EXACT describe-block pattern S1's spec mirrors); (d) the EXACT test matrix (15 cases, research §6) with the
rationale for each; (e) the two test files to mirror (`completion_smoke.lua` for the plenary-free smoke format;
the `is_attachment_context` describe block for the spec); (f) the locked design decisions (early-return FIRST;
line-1-only; `!`+`!!` identical; byte-safe `sub(1,1)`; type-guard `lines`; export `M._completion_context`; pure
function; the transitional S1→S2 window is documented not fixed); (g) the scope fence (NOT: do_refresh, force_fetch,
complete_current, shell.lua, drivers, notices, visual_cue). The genuine judgment calls (ordering before
slash/path; the test seam vs do_refresh testing; the transitional behavior; leading-space `!` lines) are decided
in Design Decisions + Anti-Patterns.

### Documentation & References

```yaml
# MUST READ — the verbatim spec (the routing snippet + the rationale)
- docfile: PRD.md
  why: "§17.7 (h3.36) gives the EXACT Lua snippet S1 implements: 'local line1 = (lines or {})[1] or \"\"; if cursorLine == 0 and line1:sub(1,1) == \"!\" then return \"shell\" end' placed 'NEW (before the existing slash/path checks)'. §17.7 also gives the WHY: 'pi bash mode triggers on the submitted prompt's first character → scoped to line 1' and '!' vs '!!' irrelevant to routing (both shell; bangs stripped by shell.lua §17.6). §17.1 (h3.30) gives the SCOPE: single-line !/!! commands; out-of-scope v1 = multi-line/continued (§17.17)."
  section: "h3.36 (§17.7 routing), h3.30 (§17.1 motivation & scope)"
  critical: "the snippet uses (lines or {})[1] — S1 uses the equivalent (type(lines)=='table') and (lines[1] or '') idiom ALREADY in this file (completion_context line 376 + compute_debounce). The placement MUST be the FIRST statement in the function body (before 'local line = …'). Do NOT strip/count bangs — that is shell.lua's job (§17.6, P2.M2.T3.S3)."

# MUST READ — the file to edit (the EXACT current function)
- file: lua/pi-bridge/completion.lua
  why: "lines 363-401: the function S1 edits. The comment-block header (364-369), the @param/@return annotations (370-374), the function body (375-401). The insertion point is the FIRST line of the body (line 376: 'local line = (type(lines) == \"table\") …'). The @return (line 374). The ONLY caller is do_refresh line 437 ('local ctx = completion_context(lines, row - 1, byte_col)') — UNCHANGED by S1. The M._completion_context export goes near M.is_attachment_context (line ~260) / the other M. assignments."
  pattern: "the existing type-guard idiom '(type(lines) == \"table\") and (lines[N] or \"\") or \"\"' — S1 REUSES it for line1 (consistency; the PRD snippet's (lines or {})[1] is the same semantic)."
  gotcha: "the function is LOCAL (line 375: 'local function completion_context'). S1 ADDS 'M._completion_context = completion_context' to expose it for testing. Do NOT change 'local function' to 'function M.completion_context' (that would be a public API change + break the 'internal' signal). The _ prefix is the test-seam convention (menu._state)."

# MUST READ — the test-seam convention (how to export a local for unit testing)
- file: lua/pi-bridge/menu.lua
  why: "lines 670-676: M._compute_width / M._compute_height / M._compute_geometry / M._state / M._column_metrics / M._truncate — the codified 'M._compute_* / coords' fns test-seam convention' (named in menu.lua header L181/L234). The _ prefix = 'internal/test-only; do not depend on in config'. completion_spec.lua ALREADY uses it (menu._state.selected). S1's M._completion_context follows this EXACT pattern."
  pattern: "declare as 'local function foo(…)' THEN 'M._foo = foo' in the exports region. Never 'function M._foo(…)' (the local is needed because do_refresh calls it unqualified)."

# MUST READ — the direct analog (a pure completion.lua fn already exported + unit-tested)
- file: tests/completion_spec.lua
  why: "lines 1006-1052: the 'describe(\"S40: trigger-aware debounce …\", function() … describe(\"is_attachment_context (direct unit cases)\", function() … end) end)' block. is_attachment_context is a PURE fn exported as M.is_attachment_context + tested with DIRECT calls (completion.is_attachment_context(\"@src/comp\") → true). S1's 'describe(\"completion_context: shell routing\", …)' block mirrors this EXACT pattern (direct M._completion_context(...) calls, no buffer/bridge)."
  pattern: "describe(…) → it(label, function() assert.are.equals(\"shell\", completion._completion_context({\"!ls\"}, 0, 3)) end). before_each/after_each use the file's existing reset() (harmless for a pure fn)."

# MUST READ — the plenary-free smoke format (the Level-1+2 gate)
- file: tests/completion_smoke.lua
  why: "lines 1-40: the standalone smoke header (run command comment), the runtimepath bootstrap (debug.getinfo → plugin_root → vim.opt.runtimepath:append), the check/fails/cquit helpers + the SMOKE_PASS footer. S1's completion_context_shell_smoke.lua is a SIMPLER version (no fake server, no bridge — just require + direct calls + check/fails)."
  pattern: "require('pi-bridge.completion'); local ctx = completion._completion_context; check(ctx({'!ls'},0,3)=='shell', …); … ; if fails>0 then cquit(1) end; print('SMOKE_PASS')."

# SUPPORTING — the architecture research (confirms the snippet + scope)
- docfile: plan/002_d23d7473c16c/architecture/research-prd-section-17.md
  why: "§17.7 (the routing snippet + line-1-only / !+!! rationale), §17.1 (scope: single-line), §17.17 (out-of-scope: multi-line). Confirms S1 is the routing primitive S2/S3 consume."
  section: "§17.7, §17.1, §17.17"

# SUPPORTING — local research notes (verified facts + the 15-case matrix + the transitional-window analysis)
- docfile: plan/002_d23d7473c16c/P2M2T1S1/research/notes.md
  why: "§0 the task fence (S1 vs S2/S3/S4/S5). §1 the verbatim current code (the INPUT contract). §2 the M._ test-seam convention (menu.lua:670-676 + is_attachment_context). §3 the transitional S1→S2 window (documented, not a bug; no existing test uses a ! line). §4 the pi source reference (interactive-mode.ts:2583; line-1-only; !+!! identical). §5 byte-correctness of sub(1,1). §6 the 15-case test matrix. §7 references."
```

### Current Codebase tree (relevant slice)

```bash
lua/pi-bridge/
├── completion.lua     # ← S1 EDITS: the completion_context function (lines 363-401) + adds M._completion_context export.
├── menu.lua           # READ-ONLY — M._state / M._compute_* (the test-seam convention reference, lines 670-676).
├── bridge.lua         # READ-ONLY (unrelated; S1 has no bridge surface).
├── init.lua           # READ-ONLY (unrelated; S1 has no config surface).
├── shell.lua          # READ-ONLY (does NOT exist in S1's scope — S2/S3 wire completion_context's 'shell' value to it).
└── (coords.lua, notify.lua, jsonlreader.lua)  # READ-ONLY (unrelated).
tests/
├── completion_spec.lua          # EDIT — ADD one describe block ('completion_context: shell routing').
├── completion_smoke.lua         # READ-ONLY — the smoke format to mirror.
├── completion_accept_smoke.lua  # READ-ONLY (S32; unaffected).
├── completion_tab_smoke.lua     # READ-ONLY (S33; unaffected).
└── completion_context_shell_smoke.lua  # ← S1 CREATES (plenary-free smoke).
```

### Desired Codebase tree with files to be added/edited

```bash
lua/pi-bridge/completion.lua                       # EDIT — 3 surgical edits to completion_context (early-return +
                                                   #   @return + comment-block) + 1 export line (M._completion_context).
tests/completion_context_shell_smoke.lua           # NEW — plenary-free smoke (the 15-case direct-call matrix).
tests/completion_spec.lua                          # EDIT — ADD one describe block (the same matrix as it(...) cases).
# (NO other file is created or modified.)
```

### Known Gotchas of our codebase & Library Quirks

```lua
-- CRITICAL (AGENTS.md HARD RULE): run tests via `+"luafile tests/completion_context_shell_smoke.lua" +qa`
-- (a FILE on disk). NEVER pipe a heredoc into nvim's stdin (`nvim ... +"luafile /dev/stdin" +qa <<EOF`
-- HANGS the session — ~10 killed sessions in this repo). Wrap every nvim in `timeout` (a hung headless
-- nvim blocks the turn).

-- GOTCHA #1 — the shell check MUST be the FIRST statement inside completion_context (BEFORE `local line = …`).
-- If it runs AFTER the token analysis, `!ls @file` would mis-return "path" (the @file token). The early-return
-- guarantees the WHOLE ! line is "shell" (pi-faithful: bash-mode detection fires before autocomplete arming).
-- PRD §17.7 places it "NEW (before the existing slash/path checks)". (research §4.)

-- GOTCHA #2 — line-1-ONLY. The guard is `cursorLine == 0` (pi 0-based line 1). A ! on line 2+ is NOT shell
-- (it's a shell argument or plain text). Multi-line/continued commands are out of scope v1 (§17.17). Do NOT
-- scan all lines for a leading ! — ONLY lines[1]. (research §4.)

-- GOTCHA #3 — `!` vs `!!` BOTH route to "shell". The check is `line1:sub(1,1) == "!"` — matches BOTH (both
-- start with !). Do NOT count/strip bangs — that is shell.lua's job (§17.6, P2.M2.T3.S3). S1 is routing-only.
-- (research §4.)

-- GOTCHA #4 — BYTE-correct sub(1,1). Lua string.sub is byte-indexed. `!` is ASCII 0x21 (1 byte). sub(1,1)
-- returns exactly the first byte. A multibyte-first line (日…) yields its lead byte (≠ "!"). Safe. The existing
-- completion_context is already byte-correct (trigger chars are ASCII). (research §5.)

-- GOTCHA #5 — type-guard `lines`. Use `(type(lines) == "table") and (lines[1] or "") or ""` (the idiom ALREADY
-- in completion_context line 376 + compute_debounce). A nil/non-table `lines` → line1 = "" → sub(1,1) = "" ≠
-- "!" → not shell → falls through. NEVER throws. Do NOT assume lines is a table (the smoke tests nil/empty cases).

-- GOTCHA #6 — the function is LOCAL (`local function completion_context`). S1 ADDS `M._completion_context =
-- completion_context` in the exports region. Do NOT change `local function` → `function M.completion_context`
-- (a public-API change + breaks the 'internal' signal; do_refresh calls it UNQUALIFIED as `completion_context`).

-- GOTCHA #7 — the test seam is `M._completion_context` (underscore prefix = internal/test-only, the menu._state
-- convention). The existing exported pure fn `M.is_attachment_context` has NO underscore because it is a PUBLIC
-- API (other plugins may read it). completion_context is NOT public API → the _ prefix. (research §2.)

-- GOTCHA #8 — TAB indentation throughout (match completion.lua — every line uses tabs, not spaces). The new
-- early-return lines, the @return update, and the export line ALL use tabs.

-- GOTCHA #9 — no lua linter/formatter (no luacheck/selene/stylua/.luarc). The ONLY "type" surface is the luaemmy
-- @param/@return annotations (lua-language-server, NOT runtime-enforced). Validation = the smoke + spec.

-- GOTCHA #10 — the @return annotation MUST be updated (line 374): `"slash" | "path" | nil` →
-- `"slash" | "path" | "shell" | nil`. AND the comment-block header (lines 365-366): add the "shell" bullet +
-- change the `-- Returns …` line. BOTH (the annotation is for the LSP; the comment block is for humans).

-- GOTCHA #11 — TRANSITIONAL WINDOW: after S1, before S2, do_refresh sees ctx=="shell" (truthy) → does NOT bail
-- at `if not ctx` → issues getSuggestions(force=false). pi returns empty for ! lines → harmless no-op. NO existing
-- test uses a ! line → suite stays green. Do NOT add a do_refresh guard in S1 (S2 owns the branch). Do NOT write
-- a do_refresh test for the "shell" value (it would assert transitional behavior S2 changes — a throwaway). S1's
-- tests assert ONLY the completion_context return value. (research §3.)
```

## Implementation Blueprint

### Design Decisions (READ FIRST)

**1. The shell early-return is the FIRST statement inside the function (BEFORE `local line = …`).** This is the
single most important decision. If the existing token/slash/path logic ran first, `!ls @file` would return
`"path"` (the `@file` token matches the `@` attachment trigger) — WRONG: the `@file` is a shell argument, not a
pi attachment. The early-return guarantees the WHOLE `!` line is `"shell"`, matching pi's own precedence
(bash-mode detection fires before autocomplete arming; `interactive-mode.ts:2583`). PRD §17.7 places the check
"NEW (before the existing slash/path checks)" — verbatim. S1 honors that. (research §4.)

**2. Line-1-only (`cursorLine == 0`).** PRD §17.7: "pi's bash mode triggers on the submitted prompt's first
character → scoped to line 1." The `cursorLine == 0` guard enforces this. A `!` on line 2+ is NOT shell (it's a
shell argument or plain text). Multi-line/continued commands are out of scope v1 (§17.17). Do NOT scan all lines.
(research §4.)

**3. `!` and `!!` route identically to `"shell"`.** The check `line1:sub(1,1) == "!"` matches both (both start
with `!`). The bang-count (1 vs 2) distinction is `shell.lua`'s stripping concern (§17.6, → P2.M2.T3.S3) — NOT
routing. S1 does NOT strip, count, or care. (research §4.)

**4. Byte-safe `line1:sub(1,1)`.** Lua `string.sub` is byte-indexed; `!` is ASCII 0x21 (1 byte). `sub(1,1)`
returns exactly the first byte. A `!`-prefixed line → `"!"`; a multibyte-first line → its lead byte (≠ `"!"`).
Safe. The existing `completion_context` is already byte-correct. (research §5.)

**5. Type-guard `lines` with the EXISTING idiom.** Use `(type(lines) == "table") and (lines[1] or "") or ""`
— the EXACT idiom already at `completion_context` line 376 and `compute_debounce`. A nil/non-table `lines` →
`line1 = ""` → `sub(1,1) = ""` ≠ `"!"` → not shell → falls through (never throws). Do NOT use the PRD snippet's
`(lines or {})[1]` verbatim — it would crash on a non-table `lines` (`(lines or {})` returns the non-table as-is
if truthy, then `[1]` on a string/number throws). The repo's `type(lines)=="table"` idiom is strictly safer.
(research §1/§5.)

**6. Export `M._completion_context` (test seam), NOT `M.completion_context`.** The function is LOCAL
(`do_refresh` calls it unqualified). S1 ADDS `M._completion_context = completion_context` in the exports region.
The `_` prefix signals "internal/test-only" (the `menu._state` / `menu._compute_*` convention, menu.lua:670-676).
Do NOT change `local function` → `function M.completion_context` (a public-API change + breaks the 'internal'
signal). This is cleaner than "test through do_refresh" (which needs a fake bridge + buffer + cursor + `vim.wait`
for a 2-line pure function). (research §2.)

**7. Update BOTH the `@return` annotation AND the comment-block header.** The `@return` (line 374) is for the
LSP (`lua-language-server` reads luaemmy annotations); the comment block (lines 365-369) is for humans. BOTH must
list `"shell"`. A reader (human or agent) seeing only one updated would miss the new value.

**8. NEVER throws; PURE function; NO nvim API / state / bridge.** `completion_context` is pure (the existing
header says so). S1's addition is pure too — `type()`, `and/or`, `:sub()`, `==`. No `vim.api.*`, no `state.*`, no
`require`. The smoke/spec call it with synthetic `{lines, cursorLine, cursorCol}`. This is why it is directly
unit-testable (like `is_attachment_context`).

**9. The transitional S1→S2 window is DOCUMENTED, not fixed.** After S1, `do_refresh` sees `ctx=="shell"` (truthy)
→ issues `getSuggestions(force=false)` → pi returns empty (harmless). S2 closes it (`if ctx == "shell" then
complete_current(...); return end`). S1 does NOT add a do_refresh guard (out of scope; S2 owns the branch). S1's
tests assert ONLY the return value (NOT the transitional do_refresh behavior — a throwaway test S2 would delete).
NO existing test uses a `!` line → suite stays green. (research §3.)

### Data models and structure

S1 does NOT introduce new runtime types. The only NEW contract surface is the **`"shell"` return value** +
the **`M._completion_context` test seam**:

```lua
--- completion_context(lines, cursorLine, cursorCol) — the CLIENT-SIDE completion gate.
--- Returns "slash" | "path" | "shell" | nil. … (the "shell" bullet added to the comment block).
---@param lines      string[] Buffer lines (raw UTF-8, as `nvim_buf_get_lines` returns).
---@param cursorLine integer 0-based line index.
---@param cursorCol  integer 0-based BYTE column.
---@return string|nil "slash" | "path" | "shell" | nil
local function completion_context(lines, cursorLine, cursorCol)
  -- SHELL (bash mode): line 1 (cursorLine 0) beginning with "!" … ([Mode A] docstring).
  local line1 = (type(lines) == "table") and (lines[1] or "") or ""
  if cursorLine == 0 and line1:sub(1, 1) == "!" then return "shell" end
  local line = (type(lines) == "table") and (lines[cursorLine + 1] or "") or ""   -- UNCHANGED
  … (existing slash/path/nil branches UNCHANGED) …
end
```

```lua
-- The test seam (in the exports region, near M.is_attachment_context / M.on_results).
-- Exposes the LOCAL completion_context for direct unit testing (the menu._state / menu._compute_* convention).
M._completion_context = completion_context
```

### Implementation Tasks (ordered by dependencies)

```yaml
Task 1: READ the current function + the conventions
  - READ lua/pi-bridge/completion.lua lines 363-401: the comment-block header (365-369), the @param/@return
    annotations (370-374), the function body (375-401). Confirm the insertion point is the FIRST line of the
    body (376: `local line = (type(lines) == "table") …`). Confirm the @return (374). Confirm the ONLY caller is
    do_refresh (437) — UNCHANGED by S1.
  - READ lua/pi-bridge/menu.lua lines 670-676 + header L181/L234: the M._* test-seam convention (M._state /
    M._compute_* / M._truncate). Confirm the `_` prefix = internal/test-only.
  - READ tests/completion_spec.lua lines 1006-1052: the `is_attachment_context (direct unit cases)` describe
    block — the EXACT pattern S1's spec block mirrors (direct M._completion_context(...) calls).
  - READ tests/completion_smoke.lua lines 1-40: the plenary-free smoke header + runtimepath bootstrap +
    check/fails/cquit/SMOKE_PASS footer.
  - READ plan/002_d23d7473c16c/P2M2T1S1/research/notes.md §1/§2/§6: the verbatim current code + the test-seam
    convention + the 15-case matrix.

Task 2: EDIT lua/pi-bridge/completion.lua — the shell early-return (3 surgical edits)
  - EDIT (a) the comment-block header: change `-- Returns "slash" | "path" | nil.` →
    `-- Returns "slash" | "path" | "shell" | nil.` AND add a bullet after the "path" bullet:
    `--   • "shell" — line 1 (cursorLine 0) begins with "!"  (pi bash mode: run bash / run bash no-context)`.
  - EDIT (b) the @return annotation: `---@return string|nil "slash" | "path" | nil` →
    `---@return string|nil "slash" | "path" | "shell" | nil`.
  - EDIT (c) the function body: as the FIRST statement (BEFORE `local line = …`), ADD the [Mode A] docstring +
    the 2-line check (see Design Decisions §1-§5 + the Data Models block above). Use the repo's
    `(type(lines) == "table") and (lines[1] or "") or ""` idiom (NOT the PRD snippet's `(lines or {})[1]` —
    GOTCHA #5). TAB indentation.
  - VERIFY (read the edited function): the shell check is FIRST; the existing slash/path/nil branches are
    UNCHANGED below it; no other line moved.

Task 3: EDIT lua/pi-bridge/completion.lua — the test-seam export
  - ADD `M._completion_context = completion_context` in the exports region (near `M.is_attachment_context` /
    `M.on_results` / the other `M.` assignments — NOT inside a function). TAB indentation. A one-line comment
    above it noting it is the test seam (the menu._state convention).
  - VERIFY: `require("pi-bridge.completion")._completion_context` is a function (one-liner nvim -c 'lua …').

Task 4: CREATE tests/completion_context_shell_smoke.lua (plenary-free smoke)
  - MIRROR tests/completion_smoke.lua lines 1-40 (header comment with the run command; the runtimepath
    bootstrap: `local me = debug.getinfo(1, "S").source:sub(2); me = vim.fn.fnamemodify(me, ":p"); local
    plugin_root = vim.fn.fnamemodify(me, ":h:h"); vim.opt.runtimepath:append(plugin_root)`; the `fails`/`check`
    helpers + the `if fails > 0 then vim.cmd("cquit 1") end; print("SMOKE_PASS")` footer).
  - BODY: `local completion = require("pi-bridge.completion"); local ctx = completion._completion_context` then
    the 15 `check(...)` cases from research §6 (the matrix). Each: `check(ctx({...}, CL, CC) == EXPECT, "label")`.
    Include the regression cases (slash/path/nil unchanged) + the defensive cases (empty/nil lines) + the
    multibyte case (`{"!日"}`).
  - PRINT `SMOKE_PASS`; exit 0. NO plenary, NO buffer, NO bridge (pure direct calls).

Task 5: EDIT tests/completion_spec.lua — ADD the describe block
  - ADD a `describe("completion_context: shell routing", function() … end)` block (place it near the existing
    `is_attachment_context` describe block at the top of the S40 section, OR as a sibling top-level describe —
    either is fine; match the file's indentation/structure).
  - BODY: `it(...)` cases mirroring the 15-case matrix (research §6). Each asserts the return value via
    `completion._completion_context({...}, CL, CC)`. Group: shell-true cases (1-5, 14); regression cases (6-9);
    line-1-only cases (10-11); defensive cases (12-13). Use `assert.are.equals("shell", …)` / `assert.is_nil(…)`.
  - The file's existing `before_each(reset)` / `after_each(reset)` are harmless for a pure fn (they clear the
    bridge/menu state, which ctx does not touch). Do NOT add a new reset.
  - VERIFY: `timeout 90 nvim --headless --clean -u tests/minimal_init.lua -c 'lua require("plenary.busted").run("tests/completion_spec.lua")'`
    → 0 fail, 0 error (the new block + ALL existing blocks green).

Task 6: RUN the full validation suite (Level 1-3)
  - Level 1 (smoke): `timeout 60 nvim --headless --clean -u NORC +"luafile tests/completion_context_shell_smoke.lua" +qa` → SMOKE_PASS, exit 0.
  - Level 2 (spec): `timeout 90 nvim --headless --clean -u tests/minimal_init.lua -c 'lua require("plenary.busted").run("tests/completion_spec.lua")'` → green.
  - Level 3 (regression — the sibling completion smokes + a broad spec sweep):
    `timeout 60 nvim --headless --clean -u NORC +"luafile tests/completion_smoke.lua" +qa` → SMOKE_PASS;
    `timeout 60 nvim --headless --clean -u NORC +"luafile tests/completion_tab_smoke.lua" +qa` → SMOKE_PASS;
    `timeout 90 nvim --headless --clean -u tests/minimal_init.lua -c 'lua require("plenary.busted").run("tests/completion_tab_smoke.lua")'` (if it is a spec) OR the existing spec sweep.
  - All green → S1 complete. (The shell_* tests are UNAFFECTED — S1 does not touch shell.lua.)
```

### Implementation Patterns & Key Details

```lua
-- THE shell early-return (the FIRST statement inside completion_context). [Mode A] docstring explains
-- line-1-only scoping + why it runs before slash/path. Uses the repo's type-guard idiom (NOT the PRD's
-- (lines or {})[1] — which throws on a non-table lines).
local line1 = (type(lines) == "table") and (lines[1] or "") or ""
if cursorLine == 0 and line1:sub(1, 1) == "!" then return "shell" end
-- … existing `local line = …` / token / slash / path / nil branches UNCHANGED below …
```

```lua
-- THE test seam (in the exports region). The `_` prefix = internal/test-only (menu._state convention).
-- Exposes the LOCAL completion_context for direct unit testing (no buffer/bridge needed).
M._completion_context = completion_context
```

```lua
-- A spec case (mirror the is_attachment_context direct-unit pattern):
it("!ls at cursorLine 0 → shell", function()
  assert.are.equals("shell", completion._completion_context({ "!ls" }, 0, 3))
end)
it("!!ls (double bang) → shell (count irrelevant)", function()
  assert.are.equals("shell", completion._completion_context({ "!!ls" }, 0, 4))
end)
it("/model unchanged → slash (regression)", function()
  assert.are.equals("slash", completion._completion_context({ "/model" }, 0, 6))
end)
it("!ls at cursorLine 1 → nil (line-1-only)", function()
  assert.is_nil(completion._completion_context({ "!ls" }, 1, 3))
end)
```

### Integration Points

```yaml
SOURCE (lua/pi-bridge/completion.lua):
  - edit: "completion_context function (lines 363-401) — add the shell early-return as the FIRST body statement"
  - edit: "@return annotation (line 374) — add 'shell'"
  - edit: "comment-block header (lines 365-369) — add the 'shell' bullet + update the Returns line"
  - add: "M._completion_context = completion_context (exports region, near M.is_attachment_context)"

TESTS:
  - new: "tests/completion_context_shell_smoke.lua (plenary-free; the 15-case matrix)"
  - edit: "tests/completion_spec.lua — ADD describe('completion_context: shell routing', …) block"

NO INTEGRATION POINTS in: do_refresh, force_fetch, _route_or_accept, shell.lua, bridge.lua, init.lua,
  menu.lua, ftplugin, plugin, extension, doc, README. (S2 wires completion_context's 'shell' value into
  do_refresh; S3 builds complete_current; S5 the visual_cue. S1 is the routing primitive ONLY.)
```

## Validation Loop

### Level 1: Syntax & Style (Immediate Feedback)

```bash
# No lua linter/formatter in this repo (no luacheck/selene/stylua/.luarc — GOTCHA #9). The ONLY static surface
# is the luaemmy @return annotation (lua-language-server, NOT runtime-enforced). Verify the edit loaded cleanly:
timeout 30 nvim --headless --clean -u NORC -c 'set rtp+=.' \
  -c 'lua local M = require("pi-bridge.completion"); assert(type(M._completion_context)=="function", "seam missing"); print("OK")' \
  -c 'qa'
echo "exit=$?"   # 0 = the module loads + the seam exists (no syntax error)
```

### Level 2: Unit Tests (Component Validation)

```bash
# The plenary-free smoke (the 15-case direct-call matrix) — run AFTER creating the smoke file:
timeout 60 nvim --headless --clean -u NORC +"luafile tests/completion_context_shell_smoke.lua" +qa
echo "exit=$?"   # 0 = pass (prints 'SMOKE_PASS'), 1 = a check failed (read FAIL lines)

# The plenary/busted spec (the same matrix as it(...) cases) — run AFTER editing completion_spec.lua:
timeout 90 nvim --headless --clean -u tests/minimal_init.lua \
  -c 'lua require("plenary.busted").run("tests/completion_spec.lua")'
echo "exit=$?"   # 0 = all green (the new block + every existing block)

# Expected: All cases pass. If failing, READ the assertion message (which case + the got vs expected) and fix.
```

### Level 3: Regression (Sibling completion smokes + broad sweep)

```bash
# The existing completion smokes (UNAFFECTED by S1 — no ! line is used; proves the slash/path/nil paths
# are untouched + the do_refresh/force_fetch flows still work):
timeout 60 nvim --headless --clean -u NORC +"luafile tests/completion_smoke.lua" +qa
echo "smoke=$?"
timeout 60 nvim --headless --clean -u NORC +"luafile tests/completion_accept_smoke.lua" +qa
echo "accept_smoke=$?"
timeout 60 nvim --headless --clean -u NORC +"luafile tests/completion_tab_smoke.lua" +qa
echo "tab_smoke=$?"

# A broad spec sweep (the modules S1 touches + neighbors):
for spec in completion menu bridge init coords; do
  timeout 90 nvim --headless --clean -u tests/minimal_init.lua \
    -c "lua require('plenary.busted').run('tests/${spec}_spec.lua')" || echo "FAIL: ${spec}_spec"
done

# Expected: every smoke prints SMOKE_PASS; every spec is green (0 fail, 0 error). If any fails, it is a
# regression from S1's edit — READ the failure + revert/fix the offending change. (shell_* are UNAFFECTED.)
```

### Level 4: Creative & Domain-Specific Validation

```bash
# (S1 is a pure-function return-value change with NO runtime integration — there is no daemon, no socket, no
# buffer-mutation path to exercise. The Level-2 matrix IS the domain validation: the 15 cases cover shell-true,
# regression (slash/path/nil unchanged), line-1-only, defensive (empty/nil lines), + byte-correctness. No
# additional creative gate is meaningful until S2 wires the value into do_refresh.)
#
# OPTIONAL sanity (a real-buffer do_refresh smoke proving the transitional no-op is harmless):
#   - set a buffer to {"!ls"} + cursor {1,3} + a fake bridge + completion.refresh(buf) + vim.wait
#   - assert exactly 1 getSuggestions request issues with force=false (the transitional behavior S2 will change)
#   - resolve it with {items={}, prefix=""} → menu stays closed (pi returns empty for ! lines)
#   This is OPTIONAL + asserts TRANSITIONAL behavior — do NOT add it to the committed suite (S2 would delete it).
#   The committed Level-4 gate is the matrix in Level 2.
```

## Final Validation Checklist

### Technical Validation

- [ ] All 3 validation levels completed successfully.
- [ ] `tests/completion_context_shell_smoke.lua` prints `SMOKE_PASS` (exit 0).
- [ ] `tests/completion_spec.lua` green (0 fail, 0 error) — the new block + all existing blocks.
- [ ] `completion_smoke` / `completion_accept_smoke` / `completion_tab_smoke` still print `SMOKE_PASS`.
- [ ] The broad spec sweep (`completion`/`menu`/`bridge`/`init`/`coords`) is green.
- [ ] `require("pi-bridge.completion")._completion_context` is a function (Level-1 load check).

### Feature Validation

- [ ] `M._completion_context({ "!ls" }, 0, 3)` → `"shell"`; `({ "!!ls" }, 0, 4)` → `"shell"`; `({ "!" }, 0, 1)` → `"shell"`.
- [ ] Line-1-only: `({ "!ls" }, 1, 3)` → `nil`; `({ "!ls", "x" }, 1, 1)` → `nil`.
- [ ] Regression: `({ "/model" }, 0, 6)` → `"slash"`; `({ "@app" }, 0, 4)` → `"path"`; `({ "./x" }, 0, 3)` → `"path"`; `({ "echo hi" }, 0, 7)` → `nil`.
- [ ] Defensive: `({}, 0, 0)` → `nil`; `(nil, 0, 0)` → `nil` (type-guard; no throw).
- [ ] Byte-correct: `({ "!日" }, 0, 4)` → `"shell"`.
- [ ] The shell early-return is the FIRST body statement (before `local line = …`) — read-verified.
- [ ] `@return` annotation + comment-block header BOTH list `"shell"`.
- [ ] No throw on ANY input (pure function; type-guarded).

### Code Quality Validation

- [ ] Follows existing codebase patterns (the `type(lines)=="table" and (lines[N] or "") or ""` idiom; the `M._*` test seam).
- [ ] File placement matches the desired tree (1 edit to completion.lua; 1 new smoke; 1 describe block added to completion_spec.lua).
- [ ] Anti-patterns avoided (no PRD `(lines or {})[1]` on a non-table; no bang stripping/counting; no do_refresh edit; no public-API rename).
- [ ] TAB indentation throughout (match completion.lua).
- [ ] The [Mode A] docstring on the shell branch explains line-1-only scoping + why slash/path are untouched.

### Documentation & Deployment

- [ ] The `@return` annotation is updated (LSP-visible).
- [ ] The comment-block header lists `"shell"` with a bullet (human-visible).
- [ ] The [Mode A] docstring on the shell branch documents the pi reference (`interactive-mode.ts:2583`) + the line-1-only rationale.
- [ ] NO new env vars, NO config changes, NO README/doc changes (S1 is internal routing; docs are P2.M4 / P2.M3.T6.S4).

---

## Anti-Patterns to Avoid

- ❌ **Don't place the shell check AFTER the slash/path logic.** `!ls @file` would mis-return `"path"`. It MUST be
  the FIRST body statement (PRD §17.7 "before the existing slash/path checks"). (GOTCHA #1.)
- ❌ **Don't scan ALL lines for a leading `!`.** Line-1-only (`cursorLine == 0`). Multi-line is out of scope v1.
  (GOTCHA #2.)
- ❌ **Don't strip/count bangs.** Both `!` and `!!` route to `"shell"`. Stripping is `shell.lua`'s job (§17.6, S3).
  (GOTCHA #3.)
- ❌ **Don't use the PRD snippet's `(lines or {})[1]` verbatim.** It throws on a non-table `lines` (`(lines or {})`
  returns the truthy non-table, then `[1]` throws). Use the repo's `(type(lines)=="table") and (lines[1] or "") or ""`.
  (GOTCHA #5.)
- ❌ **Don't change `local function completion_context` → `function M.completion_context`.** That is a public-API
  change + breaks the 'internal' signal + do_refresh calls it unqualified. ADD `M._completion_context = …` instead.
  (GOTCHA #6.)
- ❌ **Don't edit `do_refresh` / `force_fetch` to handle `"shell"`.** That is S2's job (a sibling task). S1 adds the
  return value ONLY. Adding a do_refresh guard now would collide with S2's branch. (GOTCHA #11.)
- ❌ **Don't write a do_refresh test for the `"shell"` value.** It would assert the transitional (S2-changed)
  behavior — a throwaway test. S1 tests the return value ONLY (the stable contract). (GOTCHA #11.)
- ❌ **Don't skip the regression cases.** The slash/path/nil matrix (cases 6-9) IS the regression guard — without
  them, a misplaced edit could silently break `/model` or `@app` routing.
- ❌ **Don't pipe a heredoc into nvim stdin.** Write the smoke to a FILE then `+"luafile …" +qa` (AGENTS.md HARD
  RULE). Wrap every nvim in `timeout`.
- ❌ **Don't use spaces for indentation.** TABs throughout (match completion.lua).

---

**Confidence Score: 9/10** for one-pass implementation success. The change is a 2-line early-return + an
annotation update + a test-seam export in a single well-understood pure function, with a verbatim PRD snippet, a
15-case test matrix, and an established test-seam convention to follow. The -1 is for the transitional S1→S2
window (if S2 lands much later, a `!` line issues a no-op getSuggestions — harmless but worth the implementer's
awareness; GOTCHA #11 documents it).