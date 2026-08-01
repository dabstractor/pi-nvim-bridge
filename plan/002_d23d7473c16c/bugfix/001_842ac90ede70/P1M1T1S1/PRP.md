---
name: "P1.M1.T1.S1 — Issue 5: expose real descriptor.shellSource via descriptor_shell()/resolve_shell"
description: |
  Surgical Lua fix in `lua/pi-bridge/shell.lua`. Make `descriptor_shell()` return
  `(path, source)` and `resolve_shell` propagate the descriptor's real
  `shellSource` instead of a hard-coded `"pi"`. `health.lua` (the consumer)
  already reads both return values → auto-benefits, no health.lua change. Add a
  plenary case in `tests/shell_spec.lua`. Mode A: fix the now-accurate
  `resolve_shell` doc-comment. Issue 5 ONLY — do not touch Issues 1/2/3/4/6.
---

## Goal

**Feature Goal**: `M.resolve_shell(prefer)` returns an ACCURATE second value
(`source`) matching `descriptor.shellSource` (`"pi"` | `"$SHELL"` | `"default"`)
for the `"pi"` first-hop branch, so `:checkhealth pi-bridge` reports the real
derivation instead of always printing `source: pi`.

**Deliverable**:
1. `lua/pi-bridge/shell.lua` — 4 one-line edits: `descriptor_shell()` returns
   `(path, source)` at both branches; `resolve_shell` captures and propagates
   it with an `or "pi"` fallback.
2. `lua/pi-bridge/shell.lua` — Mode-A doc-comment update on `resolve_shell`.
3. `tests/shell_spec.lua` — new plenary case asserting `shellSource="$SHELL"`
   propagates, plus the existing no-`shellSource` case still returns `"pi"`.

**Success Definition**:
- `shell.resolve_shell("pi")` with a descriptor carrying
  `{shell="/bin/zsh", shellSource="$SHELL"}` returns `("/bin/zsh", "$SHELL")`.
- The same call with a descriptor carrying a shell but NO `shellSource` still
  returns `source == "pi"` (fallback) — **no existing test regresses**.
- `:checkhealth` would now report the real source (consumer auto-benefit; no
  health.lua edit).
- `tests/shell_spec.lua`, `tests/shell_smoke.lua`, `tests/health_spec.lua`,
  `tests/shell_notices_spec.lua` all green.

## User Persona (if applicable)

**Target User**: `pi-bridge.nvim` users running `:checkhealth pi-bridge` to
diagnose shell-completion behavior, and maintainers tracing why completions
came from `$SHELL` vs `pi`.

**Use Case**: A default zsh user (no `PI_NVIM_SHELL`) sees the bridge advertise
`descriptor.shellSource = "$SHELL"`. Today `:checkhealth` misleadingly prints
`source: pi`; after this fix it correctly prints `source: $SHELL`.

**Pain Points Addressed**: The health "source" label lied — it always said `pi`
for the descriptor branch, masking the Issue-2 consistency footgun (completions
from `$SHELL` ≠ pi's bash execution). Accurate source is the prerequisite
signal for Issue 2's detection (P1.M1.T3).

## Why

- **Correctness of diagnostics** (PRD bug-hunt Issue 5): the `source` return is
  consumed by health.lua and is the only signal of how the shell was derived.
  Hard-coding `"pi"` defeats its purpose.
- **Enables Issue 2** (P1.M1.T3.S1): the `prefer:"pi"` consistency-footgun
  detection keys on `source == "$SHELL"`. Without this fix `source` is always
  `"pi"` for the descriptor branch, so Issue 2's check could never fire.
- **Cheap & safe**: `descriptor_shell()` is module-local with exactly ONE caller
  (`resolve_shell`); the consumer (health.lua) already reads both return values.
  Zero API/config/user-facing surface change.

## What

A 4-line source change + doc-comment update + one plenary test case. The
`"pi"` branch of `resolve_shell` stops returning a hard-coded `"pi"` and
instead propagates `descriptor.shellSource`, falling back to `"pi"` only when
the descriptor carries a shell but no `shellSource` (back-compat with older
bridge versions). All other `resolve_shell` branches (`"$SHELL"`, `"default"`,
`"config"`) are untouched.

### Success Criteria

- [ ] `descriptor_shell()` returns `(shell, shellSource)` in BOTH the
      `get_shell_info` branch and the `pi.descriptor` branch.
- [ ] `resolve_shell`'s `"pi"` branch captures `local ds, dsrc = descriptor_shell()`
      and returns `ds, dsrc or "pi"`.
- [ ] The `or "pi"` fallback is present (NOT dropped) — preserves existing tests.
- [ ] No other `resolve_shell` branch changed.
- [ ] `health.lua` is NOT modified (auto-benefit confirmed).
- [ ] New plenary case in `tests/shell_spec.lua` asserts `shellSource="$SHELL"`
      propagates; existing no-`shellSource` case still yields `"pi"`.
- [ ] `tests/shell_spec.lua` + `tests/shell_smoke.lua` + `tests/health_spec.lua`
      + `tests/shell_notices_spec.lua` all PASS.
- [ ] Mode-A: `resolve_shell` doc-comment updated to state the `"pi"` branch now
      propagates `descriptor.shellSource` (with the `or "pi"` fallback).

## All Needed Context

### Context Completeness Check

_Pass test_: An agent who has never seen this repo can apply the 4 exact edits
(oldText→newText given verbatim below), add the one test case, run the listed
nvim commands, and see green — without any other context. Every edit target is
quoted with its current surrounding lines so the match is unambiguous.

### Documentation & References

```yaml
# MUST READ — the fix design (verbatim code + rationale + safety analysis)
- docfile: plan/002_d23d7473c16c/bugfix/001_842ac90ede70/architecture/shell_resolution_notice.md
  why: §"Issue 5 Fix" gives the exact before/after code and proves descriptor_shell has one caller + health.lua auto-benefits
  section: "## Issue 5 Fix: Expose Real shellSource"
  critical: "the `or \"pi\"` fallback is intentional — covers descriptors carrying a shell but no shellSource (older bridges)"

# MUST READ — the file being edited (exact current content quoted in Implementation Patterns below)
- file: lua/pi-bridge/shell.lua
  why: descriptor_shell() L138-156 (returns only path today); resolve_shell pi-branch L175-177 (hard-codes "pi"); doc-comment L157-166
  pattern: "grep -nE 'local function descriptor_shell|local ds = descriptor_shell|return ds, .pi.' lua/pi-bridge/shell.lua"
  gotcha: "line numbers are current as of this PRP; always match by the quoted content, not the line number"

# MUST READ — the consumer (proves NO health.lua change needed)
- file: lua/pi-bridge/health.lua
  why: L254-256 already does `resolved, source = shell_mod.resolve_shell(prefer)` — reads BOTH values, formats source at L260
  pattern: "grep -nE 'resolve_shell|source' lua/pi-bridge/health.lua"

# MUST READ — the test home + harness pattern
- file: tests/shell_spec.lua
  why: `describe('pi-bridge.shell resolve_shell')` at L35; own fake_bridge(shell_path, server_cwd) at L22; before_each/after_each save/restore at L36-52; the existing 'source pi' case at L54-59 is the sibling for the new case
  pattern: "fake_bridge returns {shell=...}; extend to also return shellSource, OR set pi.bridge inline in the new case"

# SUPPORTING — bridge.get_shell_info() return shape + descriptor.shellSource union
- file: lua/pi-bridge/bridge.lua
  why: get_shell_info() L902-915 returns {shell, shellSource, shellPath}; @field shellSource typed ('pi'|'$SHELL'|'default')? at L188
- file: plan/002_d23d7473c16c/bugfix/001_842ac90ede70/architecture/test_conventions.md
  why: plenary runner command, fake_bridge extension pattern, save/restore harness, nvim-stdin HARD RULE
```

### Current Codebase tree

```bash
$ (cd /home/dustin/projects/pi-nvim-bridge && ls -1 lua/pi-bridge/ | head)
bridge.lua
health.lua
shell.lua        # <- EDIT target (descriptor_shell + resolve_shell + doc-comment)
...
$ ls -1 tests/shell_spec.lua tests/shell_smoke.lua tests/health_spec.lua tests/shell_notices_spec.lua
tests/health_spec.lua
tests/shell_notices_spec.lua
tests/shell_smoke.lua
tests/shell_spec.lua        # <- ADD the new case here (resolve_shell describe block)
```

### Desired Codebase tree with files to be added

```bash
lua/pi-bridge/shell.lua     # (MODIFY) 4 lines + doc-comment — NO new file
tests/shell_spec.lua        # (MODIFY) add 1-2 `it(...)` cases in the resolve_shell describe
# No new files. No health.lua change. No TS change (npm run typecheck unaffected).
```

### Known Gotchas of our codebase & Library Quirks

```lua
-- CRITICAL: the `or "pi"` fallback MUST stay. Existing tests set a descriptor
--   shell WITHOUT shellSource and assert source=="pi" (shell_spec.lua:54-59;
--   shell_smoke.lua cases 1 & 4). With the fix, shellSource is nil in those
--   fakes → `dsrc or "pi"` → "pi". Dropping the fallback REGRESSES them.

-- CRITICAL: match edits by CONTENT, not line number — shell.lua is large and
--   line numbers drift. The 4 edit sites are quoted verbatim below.

-- GOTCHA: descriptor_shell() is MODULE-LOCAL (not exported). Its ONLY caller is
--   resolve_shell (grep-confirmed: def shell.lua:138, call shell.lua:176).
--   Changing 1→2 return values is safe; no other consumer exists.

-- GOTCHA: ensure() (the runtime caller of resolve_shell) uses ONLY the first
--   return value (the resolved path). The source is read only by health.lua.
--   So this change is invisible to ensure().

-- GOTCHA (AGENTS.md HARD RULE): NEVER pipe a heredoc into nvim stdin (it HANGS).
--   Run plenary via:  nvim --headless --clean -u tests/minimal_init.lua
--   -c 'lua require("plenary.busted").run("tests/shell_spec.lua")'
--   ALWAYS wrap in `timeout`.

-- GOTCHA: in tests, do NOT name a spec-local table `pending` (shadows plenary's
--   skip fn). Use `got`/`src`/`cb` locals (test_conventions.md).
```

## Implementation Blueprint

### Data models and structure

Not applicable — no data models change. `descriptor.shellSource` is already
typed `("pi"|"$SHELL"|"default")?` (bridge.lua:188, init.lua:135). This fix only
changes which value `resolve_shell` returns as its 2nd return.

### Implementation Tasks (ordered by dependencies)

```yaml
Task 1: EDIT lua/pi-bridge/shell.lua — descriptor_shell() returns (path, source)
  - EDIT (get_shell_info branch):
      OLD:   return si.shell
      NEW:   return si.shell, si.shellSource
  - EDIT (pi.descriptor branch):
      OLD:   return desc.shell
      NEW:   return desc.shell, desc.shellSource
  - KEEP the defensive type-guards (`type(si.shell)=="string" and si.shell ~= ""`) UNCHANGED
  - NOTE: shellSource may be nil (older descriptors) — that is handled by Task 2's `or "pi"`

Task 2: EDIT lua/pi-bridge/shell.lua — resolve_shell propagates source
  - EDIT:
      OLD:   local ds = descriptor_shell()
             if ds then return ds, "pi" end
      NEW:   local ds, dsrc = descriptor_shell()
             if ds then return ds, dsrc or "pi" end
  - CRITICAL: the `or "pi"` fallback is REQUIRED (see Gotchas) — do NOT drop it
  - DO NOT touch any other resolve_shell branch ("$SHELL" / "default" / "config" stays as-is)

Task 3: EDIT lua/pi-bridge/shell.lua — Mode-A doc-comment (resolve_shell, ~L157-166)
  - UPDATE the doc-comment to state: the "pi" branch now PROPAGATES descriptor.shellSource
    (via descriptor_shell's 2nd return) with an `or "pi"` fallback for descriptors that
    carry a shell but no shellSource.
  - The line claiming `source aligns with descriptor.shellSource's union` was previously
    VIOLATED (hard-coded "pi"); it is now ACCURATE — note this in the comment.
  - Also update descriptor_shell()'s `---@return` from `string|nil` to `string|nil, string|nil`
    (it now returns two values).

Task 4: EDIT tests/shell_spec.lua — add source-propagation case(s)
  - ADD (in the `describe("pi-bridge.shell resolve_shell ...")` block, right after the
         existing L54-59 "source 'pi'" case) a case:
      it("prefer=='pi' propagates descriptor.shellSource ('$SHELL') when advertised", function()
        pi.bridge = { get_shell_info = function()
          return { shell = "/bin/zsh", shellSource = "$SHELL" }
        end }
        local s, src = shell.resolve_shell("pi")
        assert.are.equals("/bin/zsh", s)
        assert.are.equals("$SHELL", src)
      end)
  - ADD a descriptor-source case (covers the pi.descriptor fallback branch):
      it("prefer=='pi' propagates pi.descriptor.shellSource when bridge==nil (pre-handshake)", function()
        pi.bridge = nil
        pi.descriptor = { shell = "/bin/zsh", shellSource = "default" }
        local s, src = shell.resolve_shell("pi")
        assert.are.equals("/bin/zsh", s)
        assert.are.equals("default", src)
      end)
  - CONFIRM the existing L54-59 case (fake_bridge with no shellSource) still asserts
    src == "pi" — it now exercises the `or "pi"` fallback. (No edit; it stays green.)
  - FOLLOW the file's existing before_each/after_each save/restore (it already swaps
    pi.bridge + pi.descriptor + pi.config.shell). Do NOT add a parallel harness.

Task 5: VALIDATE — run the gates (Validation Loop); all must be green.
```

### Implementation Patterns & Key Details

```lua
-- === lua/pi-bridge/shell.lua — descriptor_shell() (AFTER Task 1) ===
local function descriptor_shell()
	local pi = require("pi-bridge")
	local br = pi.bridge
	if br and type(br.get_shell_info) == "function" then
		local si = br.get_shell_info()
		if type(si) == "table" and type(si.shell) == "string" and si.shell ~= "" then
			return si.shell, si.shellSource          -- ← +source
		end
	end
	local desc = pi.descriptor
	if type(desc) == "table" and type(desc.shell) == "string" and desc.shell ~= "" then
		return desc.shell, desc.shellSource         -- ← +source
	end
	return nil
end

-- === lua/pi-bridge/shell.lua — resolve_shell "pi" branch (AFTER Task 2) ===
if prefer == "pi" then
	local ds, dsrc = descriptor_shell()              -- ← capture source
	if ds then return ds, dsrc or "pi" end           -- ← propagate, fallback "pi"
	-- descriptor omitted shell → fall through to $SHELL → /bin/bash
end

-- === Why health.lua needs NO change (consumer already reads both values) ===
-- health.lua:254-256:
--   local resolved, source = nil, nil
--   if shell_mod and type(shell_mod.resolve_shell) == "function" then
--     pcall(function() resolved, source = shell_mod.resolve_shell(prefer) end)
-- After Tasks 1-2, `source` is the REAL descriptor.shellSource automatically.
```

### Integration Points

```yaml
NO integration points to add. This is an internal return-arity change.
  - health.lua (the only source-value consumer) is UNCHANGED and auto-benefits.
  - ensure() (the only path-value consumer) is UNCHANGED.
  - No config, no env var, no API surface, no descriptor schema change.
DOWNSTREAM (NOT this task — listed so you do NOT implement it here):
  - Issue 2 (P1.M1.T3.S1) will consume `source == "$SHELL"` from resolve_shell
    for the prefer:"pi" consistency-footgun detection. This fix unblocks it.
```

## Validation Loop

### Level 1: Syntax & Style (Immediate Feedback)

```bash
# luacheck/selene if configured; else a parse check via nvim (NO heredoc to stdin —
# AGENTS.md HARD RULE). Write any throwaway check to a FILE, never /dev/stdin.
luac -p lua/pi-bridge/shell.lua 2>/dev/null && echo "parse OK" || echo "luac unavailable (skip — plenary load in L2 covers parse)"
# Expected: parse OK (or skip if luac absent — the plenary run in Level 2 loads the file for real).

# Confirm the 4 edits landed (content grep, NOT line numbers):
grep -nE 'return si\.shell, si\.shellSource|return desc\.shell, desc\.shellSource|local ds, dsrc = descriptor_shell|return ds, dsrc or .pi.' lua/pi-bridge/shell.lua
# Expected: 4 distinct hits (2 in descriptor_shell, 2 in resolve_shell).
```

### Level 2: Unit Tests (the gate — resolve_shell + consumer)

```bash
# Primary: the resolve_shell spec (home of the new case)
timeout 90 nvim --headless --clean -u tests/minimal_init.lua \
  -c 'lua require("plenary.busted").run("tests/shell_spec.lua")'
# Expected: all `it` PASS, including the 2 new cases AND the existing "source 'pi'" fallback case.

# The smoke matrix (exercises the full fallback chain incl. descriptor w/o shellSource)
timeout 60 nvim --headless --clean -u NORC -c 'set rtp+=.' +"luafile tests/shell_smoke.lua" +qa; echo "exit=$?"
# Expected: prints SMOKE_PASS, exit=0. (cases 1 & 4 assert src=="pi" via the `or "pi"` fallback.)
```

### Level 3: Consumer & Sibling Specs (regression — no behavior change elsewhere)

```bash
# health_spec.lua — the consumer of `source` (must still pass; now reports real source)
timeout 90 nvim --headless --clean -u tests/minimal_init.lua \
  -c 'lua require("plenary.busted").run("tests/health_spec.lua")'

# shell_notices_spec.lua — unaffected by this fix, but cheap to re-confirm
timeout 90 nvim --headless --clean -u tests/minimal_init.lua \
  -c 'lua require("plenary.busted").run("tests/shell_notices_spec.lua")'

# Expected: both PASS. (health_spec may assert the literal "source: pi" in a fixture —
# IF a health_spec case injects a descriptor with shellSource=="$SHELL" and asserts
# "source: pi", THAT assertion is the bug manifest and should be updated to the real
# source. Inspect health_spec first; only change an assertion that contradicts the fix.)
```

### Level 4: Manual / Adversarial (optional, confirms the user-visible fix)

```bash
# Confirm :checkhealth would now show the real source. Drive resolve_shell directly:
cat > /tmp/issue5_check.lua <<'LUA'   -- heredoc to a FILE is fine; to nvim stdin is NOT
local shell = require("pi-bridge.shell")
local pi = require("pi-bridge")
pi.bridge = { get_shell_info = function() return { shell = "/bin/zsh", shellSource = "$SHELL" } end }
local s, src = shell.resolve_shell("pi")
print(("path=%s source=%s"):format(s, src))
assert(src == "$SHELL", "source must propagate descriptor.shellSource")
print("ISSUE5_OK")
LUA
timeout 60 nvim --headless --clean -u NORC -c 'set rtp+=.' +"luafile /tmp/issue5_check.lua" +qa
echo "exit=$?"
# Expected: prints `path=/bin/zsh source=$SHELL` then `ISSUE5_OK`, exit=0.
```

## Final Validation Checklist

### Technical Validation

- [ ] Level 1: 4 edits present (content grep shows all 4 distinct hits); file parses.
- [ ] Level 2: `tests/shell_spec.lua` PASS (incl. 2 new cases + existing "pi" fallback case).
- [ ] Level 2: `tests/shell_smoke.lua` PASS (exit=0, SMOKE_PASS).
- [ ] Level 3: `tests/health_spec.lua` + `tests/shell_notices_spec.lua` PASS.
- [ ] Level 4: `/tmp/issue5_check.lua` prints `source=$SHELL` + `ISSUE5_OK`.

### Feature Validation

- [ ] `resolve_shell("pi")` with `{shell, shellSource="$SHELL"}` → 2nd return `"$SHELL"`.
- [ ] `resolve_shell("pi")` with `{shell}` (no shellSource) → 2nd return `"pi"` (fallback).
- [ ] `resolve_shell("pi")` with `pi.descriptor={shell, shellSource="default"}` → `"default"`.
- [ ] All other `resolve_shell` branches unchanged (`"$SHELL"`/`"default"`/`"config"`).
- [ ] health.lua reports the real source (auto-benefit; no health.lua edit).

### Code Quality Validation

- [ ] `or "pi"` fallback present (NOT dropped) — back-compat with older descriptors.
- [ ] Edits are the SMALLEST possible (4 lines + doc-comment); no refactors.
- [ ] Mode-A doc-comment updated; `descriptor_shell` `---@return` reflects 2 values.
- [ ] Indentation matches the file (TABs); no new patterns introduced.
- [ ] No new files, no API/config/env-var surface change.

### Documentation & Deployment

- [ ] resolve_shell doc-comment states the "pi" branch propagates shellSource (+ fallback).
- [ ] The doc-comment note that `source aligns with descriptor.shellSource` is now accurate.
- [ ] No user-facing doc change required (Mode A — internal comment only).

---

## Anti-Patterns to Avoid

- ❌ Don't drop the `or "pi"` fallback — it preserves existing tests where the
  descriptor/fake-bridge carries a shell but no `shellSource`.
- ❌ Don't edit health.lua, ensure(), or any other consumer — they already read
  both return values / only the path. This is a return-arity change, not a consumer change.
- ❌ Don't touch the other `resolve_shell` branches or any notice/mismatch/footgun
  code — those are Issues 1/2/3/4/6 (separate tasks). Issue 2 DEPENDS on this fix.
- ❌ Don't match edits by line number — match by the quoted content (shell.lua drifts).
- ❌ Don't pipe a heredoc into `nvim` stdin (AGENTS.md HARD RULE — hangs). Write any
  check Lua to a real file (`/tmp/*.lua` or `tests/*.lua`), then `:luafile` it, wrapped in `timeout`.
- ❌ Don't widen this into "also fix the notice" — keep the diff to descriptor_shell +
  resolve_shell + doc-comment + one test. Minimal = reviewable.
- ❌ Don't skip Level 2 "because it's a 4-line change" — the `or "pi"` invariant and the
  existing-fallback cases are exactly what the tests guard.