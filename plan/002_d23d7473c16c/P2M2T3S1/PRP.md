# PRP — P2.M2.T3.S1: `completion_context()` `"shell"` gate

**Parent:** P2.M2.T3 (completion.lua routing + shell.complete_current + notices)
**Component:** B (`pi-bridge.nvim`) — `lua/pi-bridge/completion.lua`
**PRD anchor:** §17.7 *Routing in the plugin (`completion.lua` extension)* (supported by §17.1, §17.2)
**Size:** 0.5 pts — a focused **gate-only** change.

---

## Goal

**Feature Goal:** Make `completion_context()` return a new `"shell"` value **iff** the pi-prompt buffer's first line begins with `!` (pi's bash mode: `!` = run bash, `!!` = run bash without context), so downstream routing (S2) can send `!`/`!!` lines to the shell-completion daemon instead of pi's autocomplete provider.

**Deliverable:** One edited function in `lua/pi-bridge/completion.lua` (`completion_context`):
- A new **first** check returning `"shell"` for a line-1 `!` prefix (PRD §17.7, verbatim code below).
- Updated docstring comment block + `@return` annotation to include `"shell"`.
- The function **exported** as `M.completion_context` (pure-helper export pattern) for direct unit testing.
- A new `describe(...)` direct-unit-case block in `tests/completion_spec.lua` covering the gate.

**Success Definition:**
- `completion.completion_context({"!git ch"}, 0, 4)` → `"shell"`; `({"!!ls"}, 0, 3)` → `"shell"`.
- A `!` on **line 2** does **not** return `"shell"` (line-1-only; unchanged behavior).
- Non-bang line-1 inputs (`/model`, `@src`, `hello world`, `./p`, `~/x`) return the **same** value they return today (`"slash"`/`"path"`/`"slash"`/`"path"`/`"path"`/`nil`) — **regression guard**.
- `nil`/empty `lines` does not throw and does not return `"shell"`.
- `tests/completion_spec.lua` passes (no existing fixture regresses); the full plenary suite for the file is green.

---

## User Persona

**Target User:** A pi user editing a prompt in the Neovim external editor (`Ctrl+G`) who types a `!`/`!!` line to run a shell command.

**Use Case:** The user types `!git ch` and (once S2–S5 land) gets their real shell's completions (`checkout`, `cherry`, …). **S1 alone** does not yet render shell completions — it only establishes the routing signal those later tasks consume. S1 is the prerequisite gate.

**Pain Points Addressed:** Today a `!` line yields `"path"` or `nil` (a bare word like `ch` → `nil`), so no completion of any kind fires for shell commands (PRD §17.1). S1 introduces the categorization that lets S2 close that gap.

---

## Why

- **Business value:** First half of the shell-completion routing seam (PRD §17). Without a `"shell"` context value, `do_refresh`/`on_tab` have nothing to branch on.
- **Integration with existing features:** Additive — a new return value + a precedence-first check. No existing slash/path/plain-typing behavior changes (regression-tested).
- **Problems this solves, for whom:** Establishes the client-side categorization of bash-mode lines so the plugin can later delegate them to the user's shell completion engine (the thing pi's own provider does not provide, §17.1).

---

## What

### User-visible behavior
**None yet in S1.** S1 only changes an internal function's return value + adds a unit-tested export. Visible shell completion arrives in S2–S5. Document this explicitly so the implementer does not over-build.

### Technical requirements
1. `completion_context(lines, cursorLine, cursorCol)` returns `"shell"` **iff** `cursorLine == 0` **and** `lines[1]`'s first character is `"!"`.
2. The check is the **first** thing the function does — before the existing `local line`/`before`/`token` computation and before the slash/path checks (precedence: a `!@x` / `!./p` line is a shell command, not a pi attachment/path).
3. The check matches **both** `!` and `!!` (`line1:sub(1,1) == "!"`). Bang-count stripping is **not** this task's job (that is `shell.lua` in S3).
4. Line-1-only (`cursorLine == 0`) — mirrors pi's bash-mode detection on the submitted prompt's first character (§17.1, §17.7). Multi-line/continued commands are future (§17.17).
5. Nil/empty-`lines` defensive (the existing function already nil-guards; the new check must not throw on `lines == nil`).
6. Exported as `M.completion_context` for direct unit testing (mirrors `M.is_attachment_context`).

### Success Criteria
- [ ] New `"shell"` return path implemented exactly as PRD §17.7.
- [ ] Docstring + `@return` updated to list `"shell"`.
- [ ] `M.completion_context` exported; direct unit cases added to `tests/completion_spec.lua`.
- [ ] `tests/completion_spec.lua` green; no existing fixture regresses.
- [ ] No edits to `do_refresh`, `force_fetch`, `on_tab`, `shell.lua`, `menu.lua`, notices, or `ftplugin` (those are S2–S5).

---

## All Needed Context

### Context Completeness Check
A reader who knows nothing of this repo can implement S1 from: this PRP + the two file regions cited (`completion.lua:363-401` and `completion_spec.lua:~1016`) + PRD §17.7 (quoted inline below). No pi-internal or daemon knowledge is required — S1 touches only a pure Lua helper.

### Documentation & References

```yaml
# MUST READ — the spec that defines this exact change (verbatim code + rationale)
- url: PRD.md §17.7 "Routing in the plugin (completion.lua extension)"
  why: gives the EXACT 2-line check + explains line-1-only and ! vs !! equivalence
  critical: |
    the check goes BEFORE the slash/path checks; it inspects line1's first CHAR (not the
    trailing token — a `!git ch` line's trailing token `ch` is a bare word → nil without this
    check). Quote:
      local line1 = (lines or {})[1] or ""
      if cursorLine == 0 and line1:sub(1,1) == "!" then return "shell" end
- url: PRD.md §17.1 "Motivation & scope"
  why: establishes that pi's CombinedAutocompleteProvider does NOTHING for `!` lines today
  critical: justifies WHY a new context value is needed (no existing completion path covers `!`)
- url: PRD.md §17.2 "The shell mismatch — the central design constraint"
  why: explains `!` vs `!!` are both bash mode; routing is identical for both
  critical: the gate must NOT branch on bang-count (S3 strips it later)

# Codebase files to follow EXACTLY
- file: lua/pi-bridge/completion.lua
  why: the file being edited; lines 363-401 are the function + its docstring
  pattern: |
    local function completion_context(lines, cursorLine, cursorCol)
      local line = (type(lines) == "table") and (lines[cursorLine + 1] or "") or ""
      ... (slash check at (1), path checks at (2)/(3)) ...
    end
  gotcha: |
    `cursorLine` is the pi 0-based line index (the function is CALLED with `row - 1` from
    nvim's 1-based row at completion.lua:437). `lines` is the raw UTF-8 array from
    nvim_buf_get_lines. The new check reads `lines[1]` (Lua 1-based = line 1).
- file: lua/pi-bridge/completion.lua
  why: export precedent — `M.is_attachment_context = function(text_before_cursor)` at line ~297
  pattern: a PURE helper exported onto the module table for direct unit testing
  gotcha: keep the existing `local function completion_context` and ADD `M.completion_context = completion_context` (alias) — minimal diff; do not rewrite the function signature
- file: tests/completion_spec.lua
  why: where the new direct-unit `describe(...)` block goes (sibling of the
        `describe("is_attachment_context (direct unit cases)", …)` block at line ~1016)
  pattern: |
    describe("completion_context — shell/bash-mode gate (§17.7)", function()
      it("! line 1 → shell", function()
        assert.are.equals("shell", completion.completion_context({"!git ch"}, 0, 4))
      end)
      ... (see Implementation Tasks Task 3 for the full case list) ...
    end)
  gotcha: completion_spec.lua is a PLENARY spec run via tests/minimal_init.lua (NOT a smoke).

# Internal architecture (read-only context; NOT edited by S1)
- file: lua/pi-bridge/shell.lua
  why: confirms S1's gate is the SOLE input to the later routing — `M.request(line,cursor,after,cb)`
        exists; `complete_current(buf,cb)` is forward-GUARDED as the S3 consumer
  pattern: shell.lua's `request` takes BYTE offsets (§17.14) — irrelevant to S1's gate, but
           confirms the gate need not do any offset math (S3 does)
  gotcha: DO NOT call shell.lua from S1 — it is not wired into completion.lua until S2/S3
- file: lua/pi-bridge/completion.lua  (do_refresh ~line 406-484; on_tab ~line 760-800)
  why: the TWO callers whose branching S1 does NOT touch (S2 owns both)
  pattern: |
    do_refresh: `local ctx = completion_context(...)`; `if not ctx then close+return end`;
                then bridge path with `force = (ctx == "path")`.
    on_tab: does NOT call completion_context (computes is_slash_ctx inline).
  gotcha: |
    INTERMEDIATE STATE (S1 shipped, S2 not): a `!` line now returns "shell" (truthy) →
    do_refresh skips the close-branch and issues ONE getSuggestions RPC; pi returns null →
    menu closes. (A `! ./foo` line may briefly show pi path completions in the gap.) This is
    EXPECTED and harmless — S2 routes `!` lines to shell.lua and removes the RPC. Do NOT add a
    do_refresh short-circuit in S1 (that is S2's scope).
```

### Current codebase tree (relevant slice)

```bash
pi-nvim-bridge/
├── lua/pi-bridge/
│   ├── completion.lua     # ← EDIT (completion_context gate + export)
│   └── shell.lua          # already complete (P2.M1.T2); NOT edited by S1
├── tests/
│   ├── completion_spec.lua   # ← EDIT (add direct-unit describe block)
│   ├── minimal_init.lua      # plenary harness bootstrap (read-only)
│   └── completion_smoke.lua  # optional plenary-free smoke (read-only)
└── PRD.md  (§17.1, §17.2, §17.7 — read-only reference)
```

### Desired codebase tree with files changed

```bash
lua/pi-bridge/completion.lua      # MODIFIED — completion_context: +"shell" gate (first check) + export
tests/completion_spec.lua         # MODIFIED — +describe("completion_context — shell/bash-mode gate (§17.7)")
```

### Known Gotchas of our codebase & Library Quirks

```lua
-- CRITICAL: AGENTS.md ⛔ HARD RULE — NEVER pipe a heredoc / stdin into nvim (it HANGS).
-- Write any ad-hoc test snippet to a .lua FILE, then run  +"luafile <file>" +qa .
-- Always wrap nvim invocations in `timeout` (e.g. `timeout 90 nvim …`).

-- CRITICAL: `cursorLine` here is the pi 0-based index (caller passes `row - 1`).
-- `lines[1]` is Lua 1-based = the buffer's first line. The gate checks the FIRST CHARACTER
-- of the FIRST line — do NOT confuse this with the trailing-token checks below it.

-- GOTCHA: keep the existing `local function completion_context` declaration; ADD the alias
-- `M.completion_context = completion_context`. Do not convert to `M.completion_context = function`
-- (that needlessly churns the diff and the existing local is referenced by do_refresh via the
-- upvalue — keep it).

-- GOTCHA: the new check must be defensive against `lines == nil` / `lines[1] == nil`.
-- Pattern it on the existing nil-guard: `(type(lines) == "table") and (lines[1] or "") or ""`.

-- LIBRARY QUIRK (luajit/nvim string): `s:sub(1,1)` on an empty string returns "" (not nil),
-- and `"" == "!"` is false — safe. No need for an explicit empty-string branch beyond the guard.
```

---

## Implementation Blueprint

### Data models and structure
N/A — S1 adds no data model. It adds one string-literal return value (`"shell"`) to an existing pure function and exports it.

### Implementation Tasks (ordered by dependencies)

```yaml
Task 1: EDIT lua/pi-bridge/completion.lua — add the "shell" gate (FIRST check)
  - LOCATE: `local function completion_context(lines, cursorLine, cursorCol)` (~line 375)
  - INSERT immediately inside the function body, BEFORE the existing `local line = …` line:
      -- §17.7: bash mode is line 1 starting with "!". Checked FIRST so it wins over
      -- slash/path. Catches BOTH "!" and "!!" (bang-count strip is shell.lua's job, S3).
      local line1 = (type(lines) == "table") and (lines[1] or "") or ""
      if cursorLine == 0 and line1:sub(1, 1) == "!" then return "shell" end
  - DO NOT touch any other line of the function body (the slash checks at (1)/(2) and path
    checks at (3) stay byte-identical).
  - NAMING: local `line1` (distinct from the existing `line` = current line).
  - DEPENDENCIES: none.

Task 2: EDIT lua/pi-bridge/completion.lua — update docstring + export
  - UPDATE the docstring comment block above the function (lines ~364-371):
      • the "Returns" line: `"slash" | "path" | nil`  →  `"slash" | "path" | "shell" | nil`
      • add a bullet:  `• "shell" — line 1 (cursorLine 0) begins with "!" (pi bash mode; covers both "!" and "!!"). Routed to the shell-completion daemon by S2.`
  - UPDATE the `---@return` annotation: `"slash" | "path" | nil`  →  `"slash" | "path" | "shell" | nil`
  - EXPORT: add `M.completion_context = completion_context` on the line immediately AFTER the
    `end` that closes the function (mirror where pure helpers are surfaced; keep the existing
    `local function` so do_refresh's upvalue reference is unchanged).
  - FOLLOW pattern: `M.is_attachment_context` export at ~line 297 (pure helper → module table).
  - DEPENDENCIES: Task 1.

Task 3: EDIT tests/completion_spec.lua — add a direct-unit describe block
  - LOCATE: the existing `describe("is_attachment_context (direct unit cases)", …)` block
    (~line 1016). Add a SIBLING describe immediately after it (same nesting level).
  - NAMING: `describe("completion_context — shell/bash-mode gate (§17.7)", function() … end)`
  - REQUIRE at top of file is already present: `local completion = require("pi-bridge.completion")`
    (line 14) — reference `completion.completion_context` (the new export).
  - IMPLEMENT these `it(...)` cases (assertions via `assert.are.equals` / `assert.is_nil`):
      1. "single-bang line 1 → shell": completion_context({"!git ch"}, 0, 4) == "shell"
      2. "double-bang line 1 → shell": completion_context({"!!ls /tmp"}, 0, 3) == "shell"
         (cursor anywhere on line 1; bang-count does not affect routing)
      3. "cursor mid-word on ! line 1 → shell": completion_context({"!git ch"}, 0, 2) == "shell"
         (the gate inspects line1[1], NOT the trailing token)
      4. "empty ! line 1 → shell": completion_context({"!"}, 0, 1) == "shell"
      5. "bang on line 2 → NOT shell (line-1-only)":
            completion_context({"echo hi", "!git ch"}, 1, 4) → NOT "shell" (assert the returned
            value is one of nil/"slash"/"path"; a bare word "!git ch" on line 2 → nil)
      6. REGRESSION GUARD — non-bang line 1 unchanged:
            - completion_context({"/model"}, 0, 6) == "slash"
            - completion_context({"/model ant"}, 0, 9) == "slash"   (arg completion)
            - completion_context({"@src/comp"}, 0, 5) == "path"
            - completion_context({"hello world"}, 0, 5) == nil
            - completion_context({"./p"}, 0, 2) == "path"
            - completion_context({"~/x"}, 0, 3) == "path"
      7. NIL-SAFETY: completion_context(nil, 0, 0) → NOT "shell" (must not throw; assert via
            pcall + that result ~= "shell")
  - PLACEMENT: in tests/completion_spec.lua alongside the other direct-unit describes.
  - DEPENDENCIES: Tasks 1-2 (the export must exist).

Task 4: VERIFY — run the gates (no file changes)
  - RUN: the plenary command in Validation Loop → Level 2 for tests/completion_spec.lua.
  - EXPECT: all green (new cases + the full existing suite). If an existing case fails, it is
    almost certainly a fixture that used a `!`-prefixed line as "plain typing" — UPDATE that
    fixture's expectation (none found in research, but verify). Do NOT weaken the new gate.
```

### Implementation Patterns & Key Details

```lua
-- === The gate (Task 1+2): minimal, precedence-first, nil-safe ===
-- (insert as the FIRST statements inside completion_context's body)
local line1 = (type(lines) == "table") and (lines[1] or "") or ""
if cursorLine == 0 and line1:sub(1, 1) == "!" then return "shell" end

-- (after the function's `end`, add the export — Task 2)
M.completion_context = completion_context

-- === Why this is EXACTLY the §17.7 spec (and not more) ===
-- * line1, not the trailing `token`: a "!git ch" line's trailing token is "ch" (bare word)
--   → returns nil today. The gate must look at line 1's first character.
-- * cursorLine == 0 (pi 0-based = first line): pi's bash mode is the submitted prompt's first
--   char; completion is scoped to line 1 (§17.1/§17.7).
-- * sub(1,1) == "!": matches BOTH "!" and "!!"; routing is identical (§17.2). The double-bang
--   strip happens in shell.lua (S3), NOT here.
-- * FIRST: a "!@x" or "!./p" line is a SHELL command, not a pi attachment/path — shell wins.
```

### Integration Points

```yaml
ROUTING (NOT changed by S1 — documented for boundary clarity):
  - do_refresh (completion.lua ~line 437): `local ctx = completion_context(...)`; today treats
    any truthy ctx as "ask pi". S1 makes a "!" line truthy ("shell") → in the S1→S2 gap this
    issues one wasted getSuggestions RPC (pi returns null → menu closes). S2 adds the real
    `if ctx == "shell" then … shell path … end` branch and removes the RPC.
  - on_tab (completion.lua ~line 760): does NOT consult completion_context today; S2 extends it.
  - DO NOT add these branches in S1 — they are S2's deliverable.

EXPORTS:
  - add to: lua/pi-bridge/completion.lua module table
  - pattern: "M.completion_context = completion_context" (pure-helper export, is_attachment_context style)

CONFIG:
  - none (S1 introduces no config knob; shell.* config is S3/S6).
```

---

## Validation Loop

### Level 1: Syntax & Style (Immediate Feedback)

```bash
# From the repo root. luacheck/selene if configured; otherwise rely on nvim load + stylua.
# 1) Confirm the edited module LOADS with no Lua syntax/parse error (write to a FILE —
#    NEVER heredoc→nvim stdin, per AGENTS.md ⛔ HARD RULE):
cat > /tmp/s1_loadcheck.lua <<'LUA'
local ok, m = pcall(require, "pi-bridge.completion")
assert(ok, "require failed: " .. tostring(m))
assert(type(m.completion_context) == "function", "M.completion_context not exported")
-- spot-check the gate + a regression case
assert(m.completion_context({"!git ch"}, 0, 4) == "shell", "single-bang gate")
assert(m.completion_context({"/model"}, 0, 6) == "slash", "slash regression")
assert(m.completion_context({"hi"}, 0, 2) == nil, "plain-typing regression")
print("S1_LOAD_OK")
LUA
timeout 30 nvim --headless --clean -u NORC -c 'set rtp+=.' +"luafile /tmp/s1_loadcheck.lua" +qa
echo "exit=$?   # 0 = pass (prints S1_LOAD_OK)"

# 2) stylua formatting check (if the repo uses it — matches CI in PRD §14):
#    stylua --check lua/pi-bridge/completion.lua tests/completion_spec.lua
```

### Level 2: Unit Tests (Component Validation) — THE GATE

```bash
# The plenary suite for the edited file. This is S1's primary validation gate.
timeout 90 nvim --headless --clean -u tests/minimal_init.lua \
  -c 'lua require("plenary.busted").run("tests/completion_spec.lua")'
echo "exit=$?   # 0 = all green (new shell-gate cases + existing suite)"

# (Optional, fast feedback) plenary-free smoke — unchanged by S1, but confirms no load regression:
timeout 60 nvim --headless --clean -u NORC +"luafile tests/completion_smoke.lua" +qa
echo "exit=$?"
```

### Level 3: Integration Testing (System Validation)
N/A for S1. The gate has no runtime/integration surface of its own — `do_refresh` integration with the shell daemon is **S2/S3**. The Level-2 unit cases ARE the proof that `completion_context` categorizes `!` lines correctly. (Per AGENTS.md: the plenary spec + file-based smoke cover the end-to-end surface; do NOT invent a stdin-based nvim E2E.)

### Level 4: Creative & Domain-Specific Validation
N/A for S1 (no UI, no daemon, no health-check, no docs to ship — those are S4/S5/S6).

---

## Final Validation Checklist

### Technical Validation
- [ ] Level 1 load-check prints `S1_LOAD_OK`, exit 0.
- [ ] `tests/completion_spec.lua` plenary run exits 0 (new `describe` block + full existing suite).
- [ ] `tests/completion_smoke.lua` (optional) still exits 0 (no load regression).
- [ ] No nvim command in this PRP pipes a heredoc into nvim stdin (AGENTS.md ⛔ HARD RULE); every nvim invocation is wrapped in `timeout`.

### Feature Validation
- [ ] `!` and `!!` on line 1 → `"shell"` (cases 1-4).
- [ ] `!` on line 2 → not `"shell"` (case 5; line-1-only).
- [ ] Non-bang line-1 inputs unchanged (case 6 regression guard).
- [ ] `nil`/empty `lines` does not throw and does not return `"shell"` (case 7).
- [ ] `M.completion_context` exported and is the same function `do_refresh` calls.

### Code Quality Validation
- [ ] Minimal diff: only the gate (Task 1), docstring/`@return`/export (Task 2), and tests (Task 3).
- [ ] No edits to `do_refresh`, `force_fetch`, `on_tab`, `shell.lua`, `menu.lua`, `ftplugin`, notices, or health.
- [ ] Follows existing conventions: `M.<name>` export for pure helpers; `assert.are.equals`/`assert.is_nil` in plenary.
- [ ] Comments reference PRD §17.7 (the codebase's "document every refinement over PRD/docs" + section-anchor convention).

### Documentation & Deployment
- [ ] Code is self-documenting (the `-- §17.7` comment explains the precedence + `!`/`!!` equivalence).
- [ ] No new env vars, config, or install steps (S1 adds none).

---

## Anti-Patterns to Avoid

- ❌ **Do not implement the routing in S1.** Adding a `do_refresh`/`on_tab` shell branch is **S2**. S1 is the gate only. (The S1→S2 intermediate state emits one wasted RPC on `!` lines — that is expected and removed by S2; do not "fix" it here.)
- ❌ **Do not call `shell.lua` from S1.** It is not wired into `completion.lua` until S2/S3; calling it now couples the gate to an unbuilt path.
- ❌ **Do not strip the bangs in the gate.** `!` vs `!!` routing is identical; the count-strip is `shell.lua`'s job (S3). The gate matches `sub(1,1) == "!"`.
- ❌ **Do not check the trailing `token` instead of `line1`.** A `!git ch` line's trailing token is a bare word → nil; the gate must inspect line 1's first character.
- ❌ **Do not convert `completion_context` to `M.completion_context = function(...)`.** Keep the existing `local function` (do_refresh references it via upvalue) and add an alias export — minimal, faithful diff.
- ❌ **Do not skip the regression-guard cases.** Slash/path/plain-typing inputs MUST return their current values; a careless edit to the function body (e.g., reordering checks) could silently reclassify them.
- ❌ **Do not pipe a heredoc into `nvim` stdin** (AGENTS.md ⛔ HARD RULE — it hangs the session). Write test snippets to a `.lua` file and run with `+"luafile <file>" +qa`. Never run a bare nvim without `timeout`.

---

## Confidence Score

**9/10** for one-pass success. The change is a 2-line gate with verbatim code supplied by PRD §17.7, a clear export precedent (`is_attachment_context`), a clear test precedent (direct-unit `describe` block), no existing-test collisions (verified by grep), and well-defined scope boundaries (S2–S5 own the rest). The only residual risk is an implementer over-building into S2's territory — the Anti-Patterns + Success Criteria fence that off.