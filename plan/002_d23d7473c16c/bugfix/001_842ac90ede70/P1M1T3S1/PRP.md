---
name: "P1.M1.T3.S1 — Issue 2: detect & warn on the prefer:'pi' default-case consistency footgun + document PI_NVIM_SHELL"
description: |
  Lua + docs change in `lua/pi-bridge/shell.lua` + `tests/shell_notices_spec.lua` +
  `doc/pi-bridge-shell.txt`. Adds a SECOND, DISTINCT one-time notice (`shell-consistency`,
  WARN, dedup'd per session) for the configuration the §17.4.3 mismatch notice structurally
  CANNOT catch: under the DEFAULT config (`prefer="pi"`, `$SHELL` is zsh/fish,
  `PI_NVIM_SHELL` unset), the bridge descriptor fell back to `$SHELL` (so `resolve_shell`'s
  2nd return `source == "$SHELL"` per the LANDED T1.S1/Issue-5 work), completions run in
  zsh/fish, but pi still EXECUTES `!`/`!!` in bash → inconsistent (the zsh-alias `g=git` →
  `g: command not found` under bash footgun). The §17.4.3 mismatch notice misses this
  because its condition is `basename(resolved)=="bash"` — but here resolved is zsh.
  This task: (1) in `M.ensure()` capture BOTH return values of `resolve_shell`
  (`local resolved, source = ...`) and add a NEW pcall'd + PATH-checked detection block
  (`(cfg.prefer or "pi")=="pi" AND source=="$SHELL" AND basename($SHELL)∈{zsh,fish} AND
  on-PATH`) emitting `notify.once("shell-consistency", WARN, msg)` with the opt-in fix
  (`PI_NVIM_SHELL=<SHELL>`); (2) extend `fake_bridge` with an optional `shell_source` param
  + add 3 plenary cases (fire / no-false-positive-source-pi / no-false-positive-prefer-shell);
  (3) [Mode A] update `doc/pi-bridge-shell.txt` §3 'THE MISMATCH' with a new subsection
  documenting the default-case gap + `PI_NVIM_SHELL` opt-in fix + the ctx.getShellConfig()
  forward contract. Issue 2 ONLY — do not touch Issues 1/3/4/6 (separate tasks). Builds on
  T1.S1 (LANDED — source is accurate) and T2.S1 (in-flight — wraps the mismatch block;
  DISJOINT regions, zero conflict).
---

## Goal

**Feature Goal**: A default zsh/fish user (`$SHELL=/bin/zsh`, no `PI_NVIM_SHELL`, default
`prefer="pi"`) gets ONE `vim.notify` WARN on first daemon spawn explaining that their
completions (zsh, from the `$SHELL` fallback) may NOT match pi's execution shell (bash),
with the one-setting opt-in fix (`export PI_NVIM_SHELL=/bin/zsh`). This closes the
correctness/UX gap surfaced by the bug hunt (PRD §h3.1 Issue 2): the headline
`prefer:"pi"` "always consistent" guarantee is silently violated in the single most common
configuration, and the §17.4.3 safety-net notice is dead code there.

**Deliverable**:
1. `lua/pi-bridge/shell.lua` — (a) change line 393 `local resolved = M.resolve_shell(...)`
   → `local resolved, source = M.resolve_shell(...)` and update the step-(4) comment; (b)
   insert a NEW pcall'd `shell-consistency` detection block in `M.ensure()`, AFTER the
   (T2.S1-wrapped) §17.4.3 mismatch block and BEFORE `pick_driver`, keyed on
   `(cfg.prefer or "pi")=="pi" and source=="$SHELL"`.
2. `tests/shell_notices_spec.lua` — extend `fake_bridge` with an optional `shell_source`
   2nd param (backward-compatible); append 3 `it(...)` cases (2f/2g/2h) reusing the file's
   existing harness verbatim.
3. `doc/pi-bridge-shell.txt` — insert a new "THE DEFAULT-CASE CONSISTENCY GAP" subsection
   in §3 (between "THE MISMATCH" and "THE FIX (pick one)") documenting the footgun, the
   `PI_NVIM_SHELL` opt-in fix, and the `ctx.getShellConfig()` (PRD §17.17) forward contract.

**Success Definition**:
- `prefer="pi"` (or nil/default) + `get_shell_info` returns `{shell="/bin/zsh", shellSource="$SHELL"}`
  + `$SHELL=/bin/zsh` + zsh on PATH → `notify.did_notify("shell-consistency")` is **TRUE**
  (and the message names zsh + bash + `PI_NVIM_SHELL=/bin/zsh`); `shell-mismatch` is **FALSE**
  (distinct condition: resolved=zsh≠bash); `shell-active` is TRUE (healthy spawn).
- `prefer="pi"` + `get_shell_info` returns `{shell="/bin/zsh", shellSource="pi"}` (user set
  `PI_NVIM_SHELL`) → `shell-consistency` is **FALSE** (no false positive — source≠$SHELL).
- `prefer="shell"` + `$SHELL=/bin/zsh` (source=="$SHELL") → `shell-consistency` is **FALSE**
  (the `prefer=="pi"` gate excludes an explicit `prefer="shell"` — the user chose `$SHELL`,
  consistency is their responsibility).
- `prefer` unset (nil→pi default) + descriptor with NO shellSource → source resolves to "pi"
  (T1.S1's `or "pi"` fallback) → `shell-consistency` does NOT fire (no regression; every
  existing prefer-unset case stays green).
- `M.resolve_shell`, `M.mismatch_target`, `M.pick_driver` are UNCHANGED. The §17.4.3
  `shell-mismatch` notice is UNCHANGED. The `shell-active` + `shell-degrade` notices are
  UNCHANGED. The full notice spec + smoke + regression sweep PASS.
- `doc/pi-bridge-shell.txt` §3 explains the default-case gap + `PI_NVIM_SHELL` fix.

## User Persona (if applicable)

**Target User**: A `pi-bridge.nvim` user whose login `$SHELL` is zsh or fish and who has
NOT exported `PI_NVIM_SHELL` nor set pi's `shellPath` — i.e. the overwhelming default. pi
runs their `!`/`!!` commands in bash; the bridge (unable to read pi's shell per PRD §17.10.2)
advertises `$SHELL` as the completion shell.

**Use Case**: On the first `!`/`!!` activation, the daemon spawns zsh; today NOTHING warns
the user that a zsh-only completion (e.g. the alias `g`→`git`) will fail as
`g: command not found` when pi executes the line in bash. After this fix, ONE WARN fires
pointing them at `export PI_NVIM_SHELL=/bin/zsh` (or pi's `shellPath`).

**Pain Points Addressed**: (1) Silent inconsistency — the headline `prefer:"pi"` "always
consistent" claim is violated with no signal; (2) undiscoverable fix — the `PI_NVIM_SHELL`
opt-in was undocumented in `pi-bridge-shell.txt`; (3) the §17.4.3 notice is dead code in
the default case (its condition needs resolved==bash, but the footgun is resolved==zsh).

## Why

- **PRD §17.2/§17.4 fidelity**: `prefer:"pi"` is framed as the *correctness-preserving*
  default ("completions and execution always agree"). In the `$SHELL`-fallback case that is
  silently FALSE. Detecting + documenting it is the pragmatic mitigation while the upstream
  API gap (§17.10.2) persists.
- **Distinct from Issue 1**: Issue 1 (T2.S1) GATES the §17.4.3 `shell-mismatch` notice on
  `prefer=="pi"`. Issue 2 (this task) adds a DIFFERENT, COMPLEMENTARY condition
  (`prefer=="pi" AND source=="$SHELL"` — the descriptor fell back) with a DIFFERENT notice
  category (`shell-consistency`) so the two never conflate in the dedup set. They are
  mutually exclusive in practice: mismatch needs `resolved==bash`; consistency needs
  `resolved==zsh/fish` (from `$SHELL`).
- **Upstream-constrained, doc-forward**: the real fix (advertise pi's actual execution
  shell) needs `ctx.getShellConfig()` (PRD §17.17), not yet on `ExtensionContext` (§17.10.2).
  `PI_NVIM_SHELL` is the documented manual workaround; the doc's forward-contract note tells
  the user it will become automatic.
- **Cheap & safe**: one new local (`source`) + one new pcall'd block reusing the exact
  mismatch-block idiom (basename + executable + notify.once). `resolve_shell` is unchanged
  (T1.S1 already returns source). `cfg` + `resolved` are already in scope.
- **Parallel-safe**: T1.S1 (LANDED) provides the accurate `source`; T2.S1 (in-flight) wraps
  the mismatch block on DISJOINT lines (395-410) and does NOT touch line 393, the step-4
  comment, `pick_driver`, or `fake_bridge`. Zero merge conflict either order.

## What

A 3-part change (shell.lua code + tests + docs). The detection block is a NEW, separately-
scoped notice — it does NOT modify the §17.4.3 mismatch block (T2.S1 owns that). It captures
the 2nd return value of `resolve_shell` (which T1.S1 made accurate) at the single call site
inside `ensure()` and keys on `source == "$SHELL"`.

### Success Criteria

- [ ] Line 393 reads `local resolved, source = M.resolve_shell(cfg.prefer or "pi")` (2nd
      return captured); step-(4) comment no longer claims "source is unused by ensure".
- [ ] A NEW pcall'd block sits in `M.ensure()` AFTER the §17.4.3 mismatch block's closing
      `end` and BEFORE `-- (5) Pick the driver`, gated on
      `(cfg.prefer or "pi") == "pi" and source == "$SHELL"`.
- [ ] The block computes `env_base = basename(vim.env.SHELL or "")`, fires only when
      `env_base == "zsh" or env_base == "fish"`, pcalls `vim.fn.executable(env_base)`, and
      on PATH (`ex == 1`) calls `notify.once("shell-consistency", vim.log.levels.WARN, msg)`.
- [ ] The message names the completion shell (`env_base`), warns pi may execute in bash,
      and gives `PI_NVIM_SHELL=<vim.env.SHELL>` (or pi's shellPath) + `:help pi-bridge-shell`.
- [ ] The notice category is EXACTLY `"shell-consistency"` (distinct from `"shell-mismatch"`).
- [ ] `fake_bridge(shell_path, shell_source)` accepts an OPTIONAL 2nd param; existing 1-arg
      callers are unaffected (shellSource=nil → source resolves to "pi" via T1.S1's `or "pi"`).
- [ ] New case (2f): `prefer="pi"` + `{shell="/bin/zsh", shellSource="$SHELL"}` + `$SHELL=/bin/zsh`
      + zsh on PATH → `shell-consistency` TRUE; `shell-mismatch` FALSE; `shell-active` TRUE;
      message contains `zsh`, `bash`, `PI_NVIM_SHELL=/bin/zsh`, level WARN, title "pi-bridge".
- [ ] New case (2g): `prefer="pi"` + `{shell="/bin/zsh", shellSource="pi"}` → `shell-consistency`
      FALSE (no false positive); `shell-active` TRUE.
- [ ] New case (2h): `prefer="shell"` + `$SHELL=/bin/zsh` → `shell-consistency` FALSE
      (the `prefer=="pi"` gate excludes explicit `prefer="shell"`); `shell-active` TRUE.
- [ ] `doc/pi-bridge-shell.txt` §3 has a new subsection (between "THE MISMATCH" and "THE FIX")
      documenting the default-case gap + `PI_NVIM_SHELL` opt-in + the `ctx.getShellConfig()`
      forward contract.
- [ ] `tests/shell_notices_spec.lua` (all cases incl. 3 new) + `shell_notices_smoke.lua` +
      `shell_ensure_spec.lua` + `shell_spec.lua` + `health_spec.lua` + `shell_smoke.lua` PASS.
- [ ] `M.resolve_shell` / `M.mismatch_target` / `M.pick_driver` UNCHANGED; the §17.4.3
      `shell-mismatch` block UNCHANGED; `shell-active` / `shell-degrade` notices UNCHANGED.
- [ ] NO Issue 1/3/4/6 code touched (separate tasks). NO config/env-var/API-surface change.

## All Needed Context

### Context Completeness Check

_Pass test_: An agent who has never seen this repo can apply the 3 edits (verbatim
oldText→newText given below for shell.lua + fake_bridge + the doc; the 3 test cases given
verbatim), run the listed `nvim` commands, and see green — without any other context. The
shell.lua edit targets are quoted with their exact current surrounding lines (post-T1.S1,
pre-T2.S1-applied is fine since the regions are disjoint); the test cases reuse the file's
existing helpers (`fake_bridge`, `inject_for`, `stub_executable`, `wait_notify`,
`before_each`/`after_each`) which are summarized inline.

### Documentation & References

```yaml
# MUST READ — the fix design (verbatim code + the "distinct category" + "requires T1" rationale)
- docfile: plan/002_d23d7473c16c/bugfix/001_842ac90ede70/architecture/shell_resolution_notice.md
  why: §"Issue 2 Fix: Detect & Warn on prefer:'pi' Consistency Footgun" gives the EXACT gate
       `(cfg.prefer or "pi") == "pi" and source == "$SHELL"` + the EXACT notify.once call +
       proves it is COMPLEMENTARY to (not a duplicate of) Issue 1's mismatch_target + confirms
       it REQUIRES T1 (source accurate) which is now LANDED.
  section: "## Issue 2 Fix: Detect & Warn on prefer:'pi' Consistency Footgun"
  critical: |
    The notice category MUST be "shell-consistency" (NOT "shell-mismatch"). The two conditions
    are mutually exclusive in practice (mismatch: resolved==bash; consistency: resolved==zsh/fish
    from $SHELL). Do NOT reuse the mismatch category or the dedup set conflates them.

# MUST READ — the file being edited (exact current content quoted in Implementation Patterns)
- file: lua/pi-bridge/shell.lua
  why: line 393 (the resolve_shell call to extend); the step-(4) comment (392); the mismatch
       block end (~410, post-T2.S1); pick_driver comment (411); basename() module-local helper
       (86-89, already used by mismatch_target/pick_driver); ensure() flow.
  pattern: "grep -nE 'local resolved = M\\.resolve_shell|Pick the driver \\(§17\\.4\\.2\\)' lua/pi-bridge/shell.lua"
  gotcha: |
    Match edits by CONTENT not line number — T2.S1 (in-flight) wraps the mismatch pcall in an
    if/end which shifts line numbers by +2 around 395-410. The insertion point is "after the
    mismatch block's closing `end`, before `-- (5) Pick the driver`" — locate by CONTENT.
    `cfg` (390) + `resolved` (393) are already in scope; `basename` is module-local (86).

# MUST READ — the test home + harness (copy verbatim; only fake_bridge gains an optional param)
- file: tests/shell_notices_spec.lua
  why: defines fake_bridge / make_fake_driver / inject_for / stub_executable / wait_notify +
       before_each/after_each that already save+restore pi.config.shell (99,117), pi.bridge,
       pi.descriptor, vim.env.SHELL, vim.fn.executable + purge package.loaded[.shell.*]. Case
       (2b) is the message-spy (Style B) precedent for (2f); case (2) is the boolean precedent.
  pattern: "describe('pi-bridge.shell notices ...'); set pi.config.shell = { prefer = ... } per-case; inject_for('/bin/zsh') for the driver; stub_executable({'zsh'}) for the PATH check"
  gotcha: |
    MUST inject_for('/bin/zsh') in all 3 new cases — pick_driver('/bin/zsh') looks up
    package.loaded['pi-bridge.shell.zsh']; without it the no-driver path fires shell-degrade,
    muddying the 'active fires, no degrade' scope assertion. The harness purges .shell.zsh in
    before_each/after_each. Do NOT name a spec-local table `pending` (shadows plenary skip fn).

# MUST READ — the doc being edited (§3 structure + exact insertion point)
- file: doc/pi-bridge-shell.txt
  why: §3 "The shell mismatch + prefer" (lines 74-119); "THE MISMATCH ~" (80); "THE FIX (pick
       one) ~" (89); insert the new subsection BETWEEN them (after the THE MISMATCH paragraph,
       before THE FIX). help-file formatting: tabs for section indentation, ~ marks subsections.
  pattern: "grep -nE 'THE MISMATCH ~|THE FIX .pick one. ~' doc/pi-bridge-shell.txt"
  gotcha: |
    The doc uses TAB indentation + the `~` subsection marker. Keep column width ~78
    (vim:tw=78 footer). Do NOT add a new *tag* (would need a CONTENTS index entry) — plain
    prose subsections need no tag. Stay within §3 (74-119); lines 200 (§5 config table) +
    367 (§10 FAQ) make the same default-consistency claim but are OUT OF SCOPE (contract).

# MUST READ — test conventions (plenary runner + the nvim-stdin HARD RULE + fake_bridge extension)
- docfile: plan/002_d23d7473c16c/bugfix/001_842ac90ede70/architecture/test_conventions.md
  why: the exact plenary runner command; the Style-A (boolean) + Style-B (message spy) notice
       assertion patterns; the PATH-gate stub; the fake_bridge Issue-5 extension documented as
       `return { shell = shell_path, shellSource = shell_source or "pi" }`; the ⛔ HARD RULE.
  section: "## Test Harness (plenary); ### Fake Bridge; ### Notice Assertion; ## ⛔ HARD RULE"

# MUST READ — the PRD issue (the bug contract)
- docfile: plan/002_d23d7473c16c/bugfix/001_842ac90ede70/prd_snapshot.md
  why: §h3.1 Issue 2 — exact expected/actual/steps + the "Detect & warn on the real footgun"
       + "Document the default explicitly" + "Upstream ctx.getShellConfig()" mitigations.
  section: "### Issue 2: The headline prefer = 'pi' guarantee ... is not honored ..."

# MUST READ — the prerequisite PRPs (T1.S1 LANDED, T2.S1 in-flight) for interface contracts
- docfile: plan/002_d23d7473c16c/bugfix/001_842ac90ede70/P1M1T1S1/PRP.md
  why: T1.S1 (COMPLETE) made descriptor_shell() return (path, source) + resolve_shell propagate
       it → `source` is now ACCURATE ("$SHELL" on fallback). This task CONSUMES that output.
  section: "## Goal; ## What (Success Criteria)"
- docfile: plan/002_d23d7473c16c/bugfix/001_842ac90ede70/P1M1T2S1/PRP.md
  why: T2.S1 (in-flight) wraps the §17.4.3 mismatch pcall in `if (cfg.prefer or "pi")=="pi"`.
       DISJOINT from this task (it edits 395-410; this edits 393 + inserts after 410). It does
       NOT touch fake_bridge (its PRP: "reuse existing helpers verbatim") → no test-file conflict.
  section: "## Implementation Tasks; ## Integration Points (parallel-safety)"

# SUPPORTING — the extension's resolveShell (proves PI_NVIM_SHELL is read FIRST → shellSource="pi")
- docfile: plan/002_d23d7473c16c/bugfix/001_842ac90ede70/architecture/shell_resolution_notice.md
  why: §"The Extension Side" — resolveShell() reads PI_NVIM_SHELL FIRST (returns shellSource:"pi"),
       else $SHELL (shellSource:"$SHELL"). This is WHY setting PI_NVIM_SHELL=/bin/zsh makes the
       descriptor advertise source="pi" → this task's `source=="$SHELL"` check goes FALSE → no
       notice (the documented fix). Confirms §17.10.2 (getShellConfig NOT on ExtensionContext).
  section: "## The Extension Side (pi-nvim-bridge.ts)"

# SUPPORTING — this task's full research (source-flow table, parallel-safety matrix, doc content)
- docfile: plan/002_d23d7473c16c/bugfix/001_842ac90ede70/P1M1T3S1/research/notes.md
  why: §3 the source-flow-per-prefer table (proves each test case's gate result); §5 fake_bridge
       extension; §6 the 3 test cases; §7 the doc content; §10 the parallel-safety matrix.
```

### Current Codebase tree

```bash
$ ls -1 lua/pi-bridge/shell.lua lua/pi-bridge/notify.lua tests/shell_notices_spec.lua tests/shell_notices_smoke.lua tests/shell_ensure_spec.lua tests/shell_spec.lua tests/shell_smoke.lua doc/pi-bridge-shell.txt
doc/pi-bridge-shell.txt             # <- EDIT §3 (insert the footgun subsection)
lua/pi-bridge/notify.lua            # once/did_notify/reset API (unchanged)
lua/pi-bridge/shell.lua             # <- EDIT line 393 + insert the shell-consistency block in M.ensure
tests/shell_ensure_spec.lua         # sibling (regression sweep, unchanged)
tests/shell_notices_smoke.lua       # sibling smoke (regression sweep, unchanged)
tests/shell_notices_spec.lua        # <- EDIT fake_bridge + append 3 cases (2f/2g/2h)
tests/shell_smoke.lua               # sibling (resolve_shell matrix, unchanged)
tests/shell_spec.lua                # sibling (resolve_shell unit cases, unchanged)
```

### Desired Codebase tree with files to be added

```bash
lua/pi-bridge/shell.lua          # (MODIFY) capture `source` at line 393 + insert the
                                 #          shell-consistency detection block before pick_driver
tests/shell_notices_spec.lua     # (MODIFY) fake_bridge gains optional shell_source; +3 cases
doc/pi-bridge-shell.txt          # (MODIFY) §3: new "DEFAULT-CASE CONSISTENCY GAP" subsection
# No new files. No resolve_shell/mismatch_target/pick_driver change. No health.lua change.
```

### Known Gotchas of our codebase & Library Quirks

```lua
-- CRITICAL: BOTH gate conditions are required — `(cfg.prefer or "pi")=="pi" AND source=="$SHELL"`.
--   Dropping the prefer half (testing only `source=="$SHELL"`) would FALSELY fire under
--   prefer="shell" (where source IS "$SHELL" but the user deliberately chose $SHELL). Case
--   (2h) exists to prove the prefer half is mandatory. Dropping the source half would also
--   fire under prefer="pi" with a PI_NVIM_SHELL-set descriptor (source="pi") — case (2g).

-- CRITICAL: the `or "pi"` default in the prefer half is MANDATORY. The whole notices suite
--   sets no prefer for the existing cases (nil→pi default). `(cfg.prefer or "pi")=="pi"`
--   keeps the gate OPEN for nil. Use the contract's exact expression.

-- CRITICAL: the notice category is EXACTLY "shell-consistency" — NOT "shell-mismatch". They
--   share a dedup set (notify.lua's `seen` table); reusing "shell-mismatch" would make the
--   consistency notice dedup-suppress whenever the mismatch notice already fired (and vice
--   versa), conflating two distinct conditions. grep-confirmed: "shell-consistency" is fresh.

-- CRITICAL: `source` is NEVER nil from resolve_shell after T1.S1 (every branch returns a
--   label: "pi"|"$SHELL"|"default"|"config"). So `source == "$SHELL"` is safe even without
--   a nil-guard. (If T1.S1 had NOT landed, source would be hard-coded "pi" and this gate
--   would never match — that is WHY this task depends on T1.S1, which is COMPLETE.)

-- GOTCHA: match the shell.lua edits by CONTENT, not line number. T2.S1 (in-flight) wraps the
--   mismatch pcall in `if...then...end`, shifting lines ~395-410 by +2. The line-393 edit
--   (`local resolved = M.resolve_shell(...)`) is ABOVE T2.S1's region (unshifted); the new
--   block inserts AFTER T2.S1's closing `end` (locate by the `-- (5) Pick the driver` comment).

-- GOTCHA: the new block uses `basename(...)` — the MODULE-LOCAL helper at shell.lua:86-89
--   (NOT vim.fn.fnamemodify). It is already in scope in ensure() (mismatch_target/pick_driver
--   use it). nil/non-string → "?"; so guard with `== "zsh" or == "fish"` (the "?" never matches).

-- GOTCHA: MUST inject_for("/bin/zsh") in all 3 new test cases. pick_driver("/bin/zsh") looks
--   up package.loaded["pi-bridge.shell.zsh"]; without it the no-driver path fires
--   shell-degrade (state.failed=true), muddying the "active fires, no degrade" scope assertion.
--   The consistency notice itself fires BEFORE pick_driver (so it registers regardless), but a
--   clean spawn makes the case's scope assertions unambiguous.

-- GOTCHA: extending fake_bridge with an OPTIONAL 2nd param is backward-compatible — existing
--   1-arg callers get shellSource=nil → descriptor_shell returns (path, nil) → resolve_shell
--   returns (path, `nil or "pi"`) = (path, "pi"). Identical to the pre-T1.S1 invariant. Do NOT
--   default shell_source to "pi" inside fake_bridge (leave it nil) — the test must control it.

-- GOTCHA (AGENTS.md HARD RULE): NEVER pipe a heredoc into nvim stdin (it HANGS). Write any
--   throwaway check to a real .lua file (/tmp/*.lua or tests/*.lua), then `:luafile` it.
--   ALWAYS wrap nvim in `timeout`.

-- GOTCHA: the toast message is vim.schedule'd; did_notify() is set synchronously by notify.once
--   BEFORE the schedule. For a boolean assertion, wait_notify(category) (vim.wait 200ms) covers
--   the dedup-set write. For a message-content assertion (Style B), set the vim.notify spy
--   BEFORE calling ensure() and wait for the message substring (mirrors existing case 2b).

-- GOTCHA: doc/pi-bridge-shell.txt is a Vim help file — TAB indentation, `~` subsection marker,
--   ~78 col width (footer `vim:tw=78:ts=8`). Match the existing §3 subsection style. Do NOT add
--   a new *tag* (would require a CONTENTS index entry at lines 12-21). Plain prose is fine.
```

## Implementation Blueprint

### Data models and structure

Not applicable — no data models change. `source` is a new local in `ensure()` capturing the
2nd return of `resolve_shell` (which T1.S1 already returns). `cfg.prefer` is already read
(step 3, shell.lua:390). The notice reuses the existing `notify.once(category, level, msg)`
API with a fresh category string.

### Implementation Tasks (ordered by dependencies)

```yaml
Task 1: EDIT lua/pi-bridge/shell.lua — capture `source` + insert the shell-consistency block
  - PART A (line 393): change
        local resolved = M.resolve_shell(cfg.prefer or "pi")
    to
        local resolved, source = M.resolve_shell(cfg.prefer or "pi")
    AND update the step-(4) comment ABOVE it (currently ends "source is unused by ensure
    (health §17.15 reports it).") to state source now feeds the §17 consistency-footgun
    detection below (health still also reports it).
  - PART B (insert): AFTER the §17.4.3 mismatch block's closing `end` (post-T2.S1 wrap) and
    BEFORE the `-- (5) Pick the driver (§17.4.2)...` comment, insert the NEW pcall'd
    shell-consistency block. Gate: `if (cfg.prefer or "pi") == "pi" and source == "$SHELL" then`.
    Body: `env_base = basename(vim.env.SHELL or "")`; `if env_base == "zsh" or env_base == "fish"`;
    `pcall(function() local ok, ex = pcall(vim.fn.executable, env_base); if ok and ex == 1 then
    require("pi-bridge.notify").once("shell-consistency", vim.log.levels.WARN, MSG) end end)`.
    The exact oldText→newText is in "Implementation Patterns & Key Details" below.
  - DO NOT: touch M.resolve_shell, M.mismatch_target, M.pick_driver, descriptor_shell, the
    §17.4.3 mismatch block (T2.S1 owns it), the shell-active block, any shell-degrade block,
    or any other notice/task.
  - DO NOT: change the message of any existing notice, or reuse the "shell-mismatch" category.
  - CRITICAL: the gate is EXACTLY `if (cfg.prefer or "pi") == "pi" and source == "$SHELL" then`
    (both halves; the `or "pi"` default). The category is EXACTLY `"shell-consistency"`.
  - NAMING: one new local `source` (line 393) + one new local `env_base` (inside the block).
  - INDENTATION: TABs (match the file). The new block sits at the same indent level as the
    mismatch block's wrapping `if` (one TAB, inside ensure()).

Task 2: EDIT tests/shell_notices_spec.lua — extend fake_bridge + append 3 cases (2f/2g/2h)
  - PART A (fake_bridge): change the signature `local function fake_bridge(shell_path)` to
    `local function fake_bridge(shell_path, shell_source)` and the get_shell_info return from
    `return { shell = shell_path }` to `return { shell = shell_path, shellSource = shell_source }`.
    (Backward-compatible: existing 1-arg callers pass nil → source resolves to "pi" via T1.S1.)
  - PART B (3 cases): append AFTER the last mismatch case (T2.S1 adds (2c/2d/2e) after (2b);
    insert (2f/2g/2h) after T2.S1's (2e), before case (3)) OR at any point inside the describe
    block — placement is not load-bearing, but grouping with the other mismatch/consistency
    cases aids readability.
    - (2f) = contract (a): prefer="pi" + fake_bridge("/bin/zsh", "$SHELL") + $SHELL=/bin/zsh +
      stub_executable({"zsh"}) + inject_for("/bin/zsh") → did_notify("shell-consistency") TRUE;
      shell-mismatch FALSE; shell-active TRUE. PLUS Style-B message spy (mirror case 2b):
      assert msg contains "zsh" + "bash" + "PI_NVIM_SHELL=/bin/zsh", level WARN, title "pi-bridge".
    - (2g) = contract (b): prefer="pi" + fake_bridge("/bin/zsh", "pi") + $SHELL=/bin/zsh +
      stub_executable({"zsh"}) + inject_for("/bin/zsh") → did_notify("shell-consistency") FALSE;
      shell-active TRUE.
    - (2h) = contract (c): prefer="shell" + fake_bridge("/bin/zsh") (irrelevant — prefer="shell"
      bypasses descriptor) + $SHELL=/bin/zsh + stub_executable({"zsh"}) + inject_for("/bin/zsh")
      → did_notify("shell-consistency") FALSE (prefer gate); shell-active TRUE.
  - REUSE the file's existing helpers verbatim (the now-extended fake_bridge, inject_for,
    stub_executable, wait_notify) + before_each/after_each. NO new harness code.
  - The exact case bodies are in "Implementation Patterns & Key Details" below.

Task 3: EDIT doc/pi-bridge-shell.txt — insert the §3 "DEFAULT-CASE CONSISTENCY GAP" subsection
  - LOCATE the §3 "THE MISMATCH ~" paragraph block (ends "...fewer completions than a native
    zsh/fish setup.") and the next subsection header "THE FIX (pick one) ~". INSERT the new
    subsection BETWEEN them (Mode A: prose, no new *tag*).
  - CONTENT (3 paragraphs + 1 code block): (a) the footgun (DEFAULT config: completions=$SHELL,
    exec=bash; the §17.10.2 reason — no getShellConfig on ExtensionContext); (b) the
    PI_NVIM_SHELL opt-in fix (read FIRST by the bridge → source="pi" → consistent again) with a
    `export PI_NVIM_SHELL=/bin/zsh` code block; (c) the forward-contract note (ctx.getShellConfig
    PRD §17.17 closes it upstream). Match help-file style (TAB indent, `~` marker, ~78 cols).
  - The exact insert text is in "Implementation Patterns & Key Details" below.

Task 4: VALIDATE — run the gates (Validation Loop); all must be green.
```

### Implementation Patterns & Key Details

```lua
-- === lua/pi-bridge/shell.lua — Task 1 ===
-- Apply via the edit tool. PART A: the step-(4) comment + line 393 (content-matched).
-- OLD (verbatim current — shell.lua ~392-394):
	-- (4) Resolve ONE shell (§17.4; consistent with what pi EXECUTES). source is unused by
	--     ensure (health §17.15 reports it).
	local resolved = M.resolve_shell(cfg.prefer or "pi")
	state.shell = resolved
-- NEW:
	-- (4) Resolve ONE shell (§17.4; consistent with what pi EXECUTES). `source` (2nd return,
	--     accurate since Issue 5 / T1.S1) feeds the §17 default-case consistency-footgun
	--     detection in step 4b (health §17.15 ALSO reports it).
	local resolved, source = M.resolve_shell(cfg.prefer or "pi")
	state.shell = resolved
```

```lua
-- === lua/pi-bridge/shell.lua — Task 1 PART B ===
-- INSERT the new block AFTER the §17.4.3 mismatch block's closing `end` (post-T2.S1 wrap)
-- and BEFORE the `-- (5) Pick the driver (§17.4.2)...` comment.
-- NOTE: T2.S1 wraps the mismatch pcall in `if (cfg.prefer or "pi") == "pi" then ... end`.
-- This task's block is a SEPARATE if/end AFTER that one. Locate the insertion point by the
-- `-- (5) Pick the driver` comment (content match).
-- The OLD text to anchor on (the comment + the pick_driver line):
	-- (5) Pick the driver (§17.4.2). No driver → permanent degrade (§17.6.4): set failed so
	--     the next ensure short-circuits (do NOT retry resolve→pick per keystroke).
	state.driver = M.pick_driver(resolved)
-- NEW (prepend the consistency block BEFORE the (5) comment):
	-- §17 default-case consistency footgun (Issue 2): under prefer=="pi", when the descriptor
	-- fell back to $SHELL (source=="$SHELL" — the extension could not read pi's shellPath per
	-- §17.10.2, so $SHELL is the best available signal) AND $SHELL is zsh/fish, the COMPLETION
	-- shell (zsh/fish) may NOT match pi's EXECUTION shell (bash). This is the ONE default config
	-- where prefer=="pi" is not yet the correctness-preserving default it is meant to be. The
	-- §17.4.3 "shell-mismatch" notice above CANNOT catch it (that needs resolved==bash; here
	-- resolved==zsh/fish). notify.once with a DISTINCT "shell-consistency" category so the dedup
	-- set does NOT conflate the two. pcall'd + PATH-checked (mirrors the mismatch block). First
	-- spawn only (steps 4-8 run once per session — proc cache thereafter).
	if (cfg.prefer or "pi") == "pi" and source == "$SHELL" then
		local env_base = basename(vim.env.SHELL or "")
		if env_base == "zsh" or env_base == "fish" then
			pcall(function()
				local ok, ex = pcall(vim.fn.executable, env_base)
				if ok and ex == 1 then
					require("pi-bridge.notify").once("shell-consistency", vim.log.levels.WARN,
						"pi-bridge: completions use " .. env_base
						.. " (from $SHELL) but pi may execute commands in bash. "
						.. "For guaranteed consistency set PI_NVIM_SHELL=" .. (vim.env.SHELL or env_base)
						.. " (or pi's shellPath). :help pi-bridge-shell")
				end
			end)
		end
	end
	-- (5) Pick the driver (§17.4.2). No driver → permanent degrade (§17.6.4): set failed so
	--     the next ensure short-circuits (do NOT retry resolve→pick per keystroke).
	state.driver = M.pick_driver(resolved)
```

```lua
-- === tests/shell_notices_spec.lua — Task 2 PART A (fake_bridge extension) ===
-- OLD (verbatim current):
local function fake_bridge(shell_path)
	return {
		get_shell_info = function()
			if shell_path == nil then return nil end
			return { shell = shell_path }
		end,
		server_info = {},
	}
end
-- NEW (add OPTIONAL shell_source 2nd param):
local function fake_bridge(shell_path, shell_source)
	return {
		get_shell_info = function()
			if shell_path == nil then return nil end
			return { shell = shell_path, shellSource = shell_source }
		end,
		server_info = {},
	}
end
```

```lua
-- === tests/shell_notices_spec.lua — Task 2 PART B (3 cases, append inside the describe) ===
-- Reuses the (now-extended) fake_bridge + inject_for + stub_executable + wait_notify +
-- before_each/after_each. Insert after the last mismatch case (T2.S1's (2e)) + before (3).

	-- (2f) ISSUE-2: prefer="pi" + descriptor fell back to $SHELL (zsh) → shell-consistency fires
	it("ISSUE-2: prefer='pi' + $SHELL fallback (source='$SHELL') fires shell-consistency notice", function()
		local calls = {}
		local orig_vnotify = vim.notify
		vim.notify = function(msg, level, opts)
			calls[#calls + 1] = { msg = msg, level = level, opts = opts }
		end
		pi.config.shell = { prefer = "pi" }
		inject_for("/bin/zsh")                          -- pick_driver("/bin/zsh") needs .shell.zsh
		pi.bridge = fake_bridge("/bin/zsh", "$SHELL")   -- descriptor fell back to $SHELL
		vim.env.SHELL = "/bin/zsh"
		local restore_exec = stub_executable({ "zsh" })
		shell.ensure(function() end)
		-- flush the scheduled consistency toast
		vim.wait(200, function()
			for _, c in ipairs(calls) do
				if c.msg and c.msg:find("completions use zsh") then return true end
			end
			return false
		end, 5)
		vim.notify = orig_vnotify
		restore_exec()
		assert.is_true(notify.did_notify("shell-consistency"), "shell-consistency fired (the footgun)")
		-- distinct from mismatch: resolved is zsh (not bash) → mismatch structurally false
		assert.is_false(notify.did_notify("shell-mismatch"), "mismatch is a DIFFERENT condition (resolved!=bash)")
		-- healthy zsh spawn → active fires, no degrade
		assert.is_true(notify.did_notify("shell-active"), "scope guard: active still fires")
		assert.is_false(notify.did_notify("shell-degrade"), "no degrade (healthy spawn)")
		-- message content (the opt-in fix + the warning)
		local found
		for _, c in ipairs(calls) do
			if c.msg and c.msg:find("completions use zsh") then found = c; break end
		end
		assert.is_truthy(found, "consistency toast fired")
		assert.is_truthy(found.msg:find("zsh"), "message names the completion shell")
		assert.is_truthy(found.msg:find("bash"), "message warns pi may execute in bash")
		assert.is_truthy(found.msg:find("PI_NVIM_SHELL=/bin/zsh"), "message gives the PI_NVIM_SHELL=<SHELL> fix")
		assert.are.equals(vim.log.levels.WARN, found.level)
		assert.are.equals("pi-bridge", found.opts.title)
	end)

	-- (2g) ISSUE-2 no false positive: prefer="pi" + real pi source (source="pi", PI_NVIM_SHELL set)
	it("ISSUE-2: prefer='pi' + real pi source (source='pi') does NOT fire shell-consistency", function()
		pi.config.shell = { prefer = "pi" }
		inject_for("/bin/zsh")
		pi.bridge = fake_bridge("/bin/zsh", "pi")        -- user set PI_NVIM_SHELL=/bin/zsh
		vim.env.SHELL = "/bin/zsh"
		local restore_exec = stub_executable({ "zsh" })
		shell.ensure(function() end)
		assert.is_false(wait_notify("shell-consistency"), "no false positive (source='pi' → consistent)")
		assert.is_false(notify.did_notify("shell-consistency"))
		assert.is_true(notify.did_notify("shell-active"), "scope guard: active still fires")
		assert.is_false(notify.did_notify("shell-degrade"))
		restore_exec()
	end)

	-- (2h) ISSUE-2 no false positive: prefer="shell" + source="$SHELL" (user explicitly chose $SHELL)
	it("ISSUE-2: prefer='shell' + source='$SHELL' does NOT fire shell-consistency (user chose $SHELL)", function()
		pi.config.shell = { prefer = "shell" }
		inject_for("/bin/zsh")
		pi.bridge = fake_bridge("/bin/zsh")              -- irrelevant: prefer="shell" bypasses descriptor
		vim.env.SHELL = "/bin/zsh"
		local restore_exec = stub_executable({ "zsh" })
		shell.ensure(function() end)
		assert.is_false(wait_notify("shell-consistency"), "no notice (the prefer=='pi' gate excludes prefer='shell')")
		assert.is_false(notify.did_notify("shell-consistency"))
		assert.is_true(notify.did_notify("shell-active"), "scope guard: active still fires")
		restore_exec()
	end)
```

```lua
-- === Why existing prefer-UNSET cases stay green ===
-- Case (1) (fish==$SHELL) + (2)/(2b) (bash resolved) + (4) (zsh==$SHELL) never set prefer.
-- ensure reads cfg=(pi.config.shell) or {}. With prefer unset, cfg.prefer==nil. The gate:
--   (cfg.prefer or "pi")=="pi" → ("pi")=="pi" → TRUE.  The source half: these cases use the
--   UN-extended fake_bridge(shell_path) (1 arg) → shellSource=nil → descriptor_shell returns
--   (path, nil) → resolve_shell returns (path, `nil or "pi"`) = (path, "pi"). So source=="pi",
--   NOT "$SHELL" → the consistency gate's 2nd half is FALSE → NO fire. Identical to pre-change.
-- (Only case (2f), which explicitly passes shell_source="$SHELL", trips the gate.)
```

```help
-- === doc/pi-bridge-shell.txt — Task 3 (insert between "THE MISMATCH" para and "THE FIX") ===
-- Anchor: the "THE FIX (pick one) ~" header. Prepend the new subsection BEFORE it.
-- OLD anchor (the header line):
THE FIX (pick one) ~
-- NEW (prepend the footgun subsection, then keep THE FIX):
THE DEFAULT-CASE CONSISTENCY GAP (non-bash $SHELL) ~
The paragraph above says the plugin completes "using pi's execution shell — bash — which is
always consistent with execution." That holds ONLY when the bridge can read pi's execution
shell. It cannot today: there is no public API on the bridge `ExtensionContext` to read pi's
`shellPath`/`getShellConfig` (PRD §17.10.2). So under the DEFAULT config — `prefer = "pi"`,
`$SHELL` is zsh or fish, and `PI_NVIM_SHELL` is NOT exported — the bridge falls back to
advertising `$SHELL` as the completion shell. Completion then uses zsh/fish while pi still
EXECUTES `!`/`!!` in bash. They MAY NOT be consistent: a zsh-only alias (e.g. `g=git`) can be
offered as a completion, then fail as `g: command not found` when pi runs the line in bash.
This is the one configuration where `prefer = "pi"` is not yet the correctness-preserving
default it is meant to be. The first time the daemon spawns in this configuration the plugin
emits ONE `vim.notify` (deduplicated per session) warning you and pointing here.

THE OPT-IN FIX: `PI_NVIM_SHELL` ~
Export `PI_NVIM_SHELL` to tell the bridge which shell pi actually executes `!`/`!!` in. It is
read by the bridge's shell resolver BEFORE `$SHELL`: >

    export PI_NVIM_SHELL=/bin/zsh     " if pi runs ! in zsh (e.g. shellPath set)

With `PI_NVIM_SHELL` set to your shell, `prefer = "pi"` resolves to that shell for BOTH
completion and execution — consistent again. (Equivalently, set pi's own `shellPath`; the two
are the same fix from different sides.) Reopen the editor after changing either.

NOTE (forward contract) ~
This gap is fundamental to PRD §17.10.2 and is expected to close upstream: once pi exposes
`ctx.getShellConfig()` (PRD §17.17), the bridge will advertise pi's REAL execution shell
automatically and `prefer = "pi"` will be correct by default — with no `PI_NVIM_SHELL` needed.
Until that API lands, exporting `PI_NVIM_SHELL` is the documented workaround.

THE FIX (pick one) ~
```

### Integration Points

```yaml
NO new integration points. This reuses existing locals + the existing notify API.
  - cfg (shell.lua:390) is already in scope — no new read.
  - resolved (shell.lua:393) is already in scope; `source` is the new 2nd-return capture.
  - basename() (shell.lua:86-89) is module-local, already used by mismatch_target/pick_driver.
  - notify.once / did_notify / reset are UNCHANGED (a fresh category string is the only new arg).
  - No config key, no env-var handling (PI_NVIM_SHELL is read by the EXTENSION, not the plugin),
    no API surface, no descriptor schema change.
PREREQUISITE (COMPLETE):
  - T1.S1 / Issue 5: descriptor_shell() returns (path, source) + resolve_shell propagates it
    (shell.lua:149,154,188 — LANDED). This task CONSUMES `source`; without T1 the gate would
    never match (source was hard-coded "pi"). CONFIRMED landed by reading the source.
PARALLEL TASK (Issue 1 / P1.M1.T2.S1 — IN-FLIGHT):
  - T2.S1 wraps the §17.4.3 mismatch pcall in `if (cfg.prefer or "pi")=="pi" then...end`
    (shell.lua ~395-410) + appends 3 cases (2c/2d/2e) after (2b). DISJOINT from this task:
      * shell.lua: T2.S1 edits 395-410; T3.S1 edits 393 + inserts after 410's `end`. No overlap.
      * tests: T2.S1 does NOT touch fake_bridge (its PRP: "reuse verbatim"); T3.S1 extends it.
        Both append `it(...)` blocks (independent; plenary runs all). Insert T3.S1's cases after
        T2.S1's (2e) to avoid textual adjacency; order-independent either way.
  - Zero behavioral dependency: T2.S1 keys on cfg.prefer; T3.S1 keys on source. Either lands first.
DOWNSTREAM (NOT this task):
  - Issues 3/4/6 (P1.M2) edit different functions/files. Issue 5 (T1.S1) is DONE. No conflict.
```

## Validation Loop

### Level 1: Syntax & Style (Immediate Feedback)

```bash
# Parse check (luac if available; else the plenary load in L2 covers parse). NEVER heredoc→nvim stdin.
luac -p lua/pi-bridge/shell.lua 2>/dev/null && echo "parse OK" || echo "luac unavailable (skip — L2 covers parse)"

# Confirm the line-393 change landed (content grep, NOT line number):
grep -nE 'local resolved, source = M\.resolve_shell' lua/pi-bridge/shell.lua
# Expected: exactly 1 hit, inside M.ensure().

# Confirm the shell-consistency block landed with BOTH gate halves + the fresh category:
grep -nE 'and source == "\$SHELL" then' lua/pi-bridge/shell.lua
grep -cE 'once\("shell-consistency"' lua/pi-bridge/shell.lua
# Expected: 1 hit each. (If the `and source == "$SHELL"` is missing, the prefer-only gate is a bug.)

# Confirm resolve_shell / mismatch_target / pick_driver are UNCHANGED (still 1 hit each):
grep -nE 'function M\.resolve_shell|function M\.mismatch_target|function M\.pick_driver' lua/pi-bridge/shell.lua
# Expected: 3 hits (unchanged).

# Confirm the shell-mismatch notice is untouched (T2.S1's gate, not this task's):
grep -cE 'once\("shell-mismatch"' lua/pi-bridge/shell.lua
# Expected: 1 (unchanged).

# Confirm fake_bridge gained the optional param + the 3 new cases:
grep -nE 'function fake_bridge\(shell_path, shell_source\)' tests/shell_notices_spec.lua
grep -cE 'ISSUE-2' tests/shell_notices_spec.lua
# Expected: 1 hit (signature) + >= 3 (cases 2f/2g/2h).

# Confirm the doc subsection landed:
grep -nE 'DEFAULT-CASE CONSISTENCY GAP|PI_NVIM_SHELL|ctx\.getShellConfig' doc/pi-bridge-shell.txt
# Expected: >= 3 hits (the subsection header + the fix + the forward-contract note).
```

### Level 2: Unit Tests (the new cases — the spec with 2f/2g/2h)

```bash
# Primary: the notices spec (home of the 3 new cases + all existing notice cases).
timeout 90 nvim --headless --clean -u tests/minimal_init.lua \
  -c 'lua require("plenary.busted").run("tests/shell_notices_spec.lua")'
# Expected: all `it` PASS, incl. (2f) fire + message, (2g) no-false-positive-source-pi,
#   (2h) no-false-positive-prefer-shell, AND every existing case ((1) active, (2)/(2b)/(2c-2e)
#   mismatch, (3) no-PATH, (4) self-gate, (5)-(9) degrade paths, (10) dedup, (11) suppression,
#   (12) pure-unit, (13) never-throws, (14) exposes). `fail 0`.
# NOTE: if T2.S1 has also landed, its (2c/2d/2e) must ALSO pass (they are independent of this task).

# The smoke matrix (plenary-free; exercises the full ensure path incl. the new block).
timeout 60 nvim --headless --clean -u NORC -c 'set rtp+=.' +"luafile tests/shell_notices_smoke.lua" +qa; echo "exit=$?"
# Expected: prints SMOKE_PASS, exit=0.
```

### Level 3: Regression Sweep (resolve_shell / ensure / health — must be unaffected)

```bash
# shell_ensure_spec.lua — the ensure() lifecycle spec (the new block is inside ensure).
timeout 90 nvim --headless --clean -u tests/minimal_init.lua \
  -c 'lua require("plenary.busted").run("tests/shell_ensure_spec.lua")'
# Expected: all PASS (the block does not touch cache/failed/driver-spawn paths).

# shell_spec.lua — resolve_shell + mismatch_target pure unit cases (must be unchanged).
timeout 90 nvim --headless --clean -u tests/minimal_init.lua \
  -c 'lua require("plenary.busted").run("tests/shell_spec.lua")'
# Expected: all PASS (resolve_shell is unchanged; the 2nd-return capture is at the CALL SITE only).

# shell_smoke.lua — the resolve_shell fallback matrix (consumes the 2nd return; unaffected).
timeout 60 nvim --headless --clean -u NORC -c 'set rtp+=.' +"luafile tests/shell_smoke.lua" +qa; echo "exit=$?"
# Expected: SMOKE_PASS, exit=0.

# health_spec.lua — the consumer of resolve_shell's source (must stay green).
timeout 90 nvim --headless --clean -u tests/minimal_init.lua \
  -c 'lua require("plenary.busted").run("tests/health_spec.lua")'
# Expected: all PASS (health reads source independently; this task adds a notice, doesn't change source).
```

### Level 4: Manual / Adversarial (the exact bug repro — default zsh footgun)

```bash
# Reproduce the EXACT Issue-2 scenario live: prefer="pi" (default), $SHELL=/bin/zsh, descriptor
# fell back to $SHELL (shellSource="$SHELL"), PI_NVIM_SHELL unset. Assert shell-consistency fires
# (and mismatch does NOT, and active does). Heredoc→FILE is fine; nvim stdin is NOT.
cat > /tmp/issue2_check.lua <<'LUA'
local pi = require("pi-bridge")
if pi.config == nil then pi.setup({}) end
pi.config.shell = { prefer = "pi" }
local shell = require("pi-bridge.shell")
local notify = require("pi-bridge.notify")
-- inject a fake zsh driver so pick_driver("/bin/zsh") succeeds (avoids the degrade path)
package.loaded["pi-bridge.shell.zsh"] = {
  start = function(_opts, cb)
    cb(nil, { is_closing = function() return false end },
      { read_start = function() end, close = function() end, is_closing = function() return false end },
      { write = function() end, close = function() end, is_closing = function() return false end })
  end,
}
-- descriptor fell back to $SHELL (no PI_NVIM_SHELL): shellSource="$SHELL"
pi.bridge = { get_shell_info = function() return { shell = "/bin/zsh", shellSource = "$SHELL" } end, server_info = {} }
vim.env.SHELL = "/bin/zsh"
notify.reset(); shell.reset()
shell.ensure(function() end)
vim.wait(200, function() return notify.did_notify("shell-consistency") end, 5)
print("consistency_fired=" .. tostring(notify.did_notify("shell-consistency")))
print("mismatch_fired=" .. tostring(notify.did_notify("shell-mismatch")))
print("active_fired=" .. tostring(notify.did_notify("shell-active")))
assert(notify.did_notify("shell-consistency") == true, "BUG: shell-consistency did NOT fire (the footgun)")
assert(notify.did_notify("shell-mismatch") == false, "mismatch must NOT fire (resolved=zsh, not bash)")
assert(notify.did_notify("shell-active") == true, "scope guard failed: active should fire")
print("ISSUE2_OK")
LUA
timeout 60 nvim --headless --clean -u NORC -c 'set rtp+=.' +"luafile /tmp/issue2_check.lua" +qa; echo "exit=$?"
# Expected: prints `consistency_fired=true` + `mismatch_fired=false` + `active_fired=true` + ISSUE2_OK, exit=0.

# Also re-run the NO-FALSE-POSITIVE direction (PI_NVIM_SHELL set → source="pi" → no notice):
cat > /tmp/issue2_noop.lua <<'LUA'
local pi = require("pi-bridge")
if pi.config == nil then pi.setup({}) end
pi.config.shell = { prefer = "pi" }
local shell = require("pi-bridge.shell")
local notify = require("pi-bridge.notify")
package.loaded["pi-bridge.shell.zsh"] = {
  start = function(_opts, cb)
    cb(nil, { is_closing = function() return false end },
      { read_start = function() end, close = function() end, is_closing = function() return false end },
      { write = function() end, close = function() end, is_closing = function() return false end })
  end,
}
-- user set PI_NVIM_SHELL → descriptor advertises source="pi"
pi.bridge = { get_shell_info = function() return { shell = "/bin/zsh", shellSource = "pi" } end, server_info = {} }
vim.env.SHELL = "/bin/zsh"
notify.reset(); shell.reset()
shell.ensure(function() end)
vim.wait(150, function() return false end, 5)  -- flush any scheduled notify
print("consistency_fired=" .. tostring(notify.did_notify("shell-consistency")))
assert(notify.did_notify("shell-consistency") == false, "BUG: false positive (source='pi' should not fire)")
print("ISSUE2_NOOP_OK")
LUA
timeout 60 nvim --headless --clean -u NORC -c 'set rtp+=.' +"luafile /tmp/issue2_noop.lua" +qa; echo "exit=$?"
# Expected: prints `consistency_fired=false` + ISSUE2_NOOP_OK, exit=0.
```

## Final Validation Checklist

### Technical Validation

- [ ] Level 1: `grep 'local resolved, source = M\.resolve_shell'` → 1 hit; `grep 'and source == "\$SHELL" then'`
      → 1 hit; `once("shell-consistency"` → 1; `once("shell-mismatch"` → 1 (unchanged);
      resolve_shell/mismatch_target/pick_driver → 3 hits (unchanged); fake_bridge signature → 1;
      doc subsection → >= 3 hits.
- [ ] Level 2: `tests/shell_notices_spec.lua` PASS (incl. 3 new cases 2f/2g/2h + all existing).
- [ ] Level 2: `tests/shell_notices_smoke.lua` PASS (exit=0, SMOKE_PASS).
- [ ] Level 3: `tests/shell_ensure_spec.lua` + `tests/shell_spec.lua` + `tests/shell_smoke.lua` +
      `tests/health_spec.lua` PASS.
- [ ] Level 4: `/tmp/issue2_check.lua` prints `consistency_fired=true` + `mismatch_fired=false` +
      `ISSUE2_OK`; `/tmp/issue2_noop.lua` prints `consistency_fired=false` + `ISSUE2_NOOP_OK`.

### Feature Validation

- [ ] `prefer="pi"` + descriptor `$SHELL`-fallback (source="$SHELL") + `$SHELL=/bin/zsh` + on PATH →
      `shell-consistency` fires; `shell-mismatch` does NOT; `shell-active` does.
- [ ] `prefer="pi"` + descriptor source="pi" (PI_NVIM_SHELL set) → `shell-consistency` does NOT fire.
- [ ] `prefer="shell"` + source="$SHELL" → `shell-consistency` does NOT fire (the prefer=="pi" gate).
- [ ] `prefer` unset + descriptor with no shellSource → source resolves to "pi" → no fire (regression).
- [ ] The `shell-consistency` message names the shell, warns about bash, gives `PI_NVIM_SHELL=<SHELL>`.
- [ ] `M.resolve_shell` / `M.mismatch_target` / `M.pick_driver` UNCHANGED.
- [ ] The §17.4.3 `shell-mismatch` notice block UNCHANGED; `shell-active` / `shell-degrade` UNCHANGED.
- [ ] `doc/pi-bridge-shell.txt` §3 documents the footgun + `PI_NVIM_SHELL` + the forward contract.

### Code Quality Validation

- [ ] The gate is EXACTLY `(cfg.prefer or "pi") == "pi" and source == "$SHELL"` (both halves; `or "pi"`).
- [ ] The notice category is EXACTLY `"shell-consistency"` (NOT `"shell-mismatch"`).
- [ ] The new block is a SEPARATE `if`/`end` AFTER the mismatch block's `end` (not nested in it).
- [ ] The block reuses the mismatch-block idiom (pcall + pcall executable + notify.once); no new pattern.
- [ ] `fake_bridge` extension is backward-compatible (optional 2nd param; existing 1-arg callers unaffected).
- [ ] The 3 test cases reuse the existing harness (no new helpers); each `inject_for("/bin/zsh")`.
- [ ] Edits are the SMALLEST possible (1 line change + 1 new block + fake_bridge 2-word change + 3 cases
      + 1 doc subsection); no refactors.
- [ ] Indentation matches the files (TABs in Lua; TAB + `~` in the help file); no new patterns.
- [ ] No new files, no config/env-var/API-surface change (PI_NVIM_SHELL is extension-side, pre-existing).

### Documentation & Deployment

- [ ] The step-(4) comment in shell.lua documents that `source` now feeds the consistency detection.
- [ ] The new block's comment explains WHY it is distinct from the §17.4.3 mismatch notice.
- [ ] `doc/pi-bridge-shell.txt` §3 new subsection explains the default-case gap + the §17.10.2 reason.
- [ ] The doc documents `PI_NVIM_SHELL` (the opt-in fix) + the `ctx.getShellConfig()` forward contract.
- [ ] No `README.md` / `doc/pi-bridge.txt` change REQUIRED (the §3 treatment is authoritative; the
      extension's PI_NVIM_SHELL handling is unchanged code). A README cross-ref is OPTIONAL polish.

---

## Anti-Patterns to Avoid

- ❌ Don't drop either gate half. `(cfg.prefer or "pi")=="pi"` alone fires under prefer="shell"
      (case 2h catches it). `source=="$SHELL"` alone fires under prefer="pi" + PI_NVIM_SHELL-set
      (case 2g catches it). Use the contract's exact `and`-joined gate.
- ❌ Don't drop the `or "pi"` default — `cfg.prefer == "pi"` closes the gate when prefer is nil,
      and EVERY existing prefer-unset case relies on the nil→pi default. (T2.S1's gate uses the
      same `or "pi"`; mirror it.)
- ❌ Don't reuse the `"shell-mismatch"` category — `notify.once` dedups by category in one shared
      `seen` set; reuse would make whichever notice fired first suppress the other. Use the EXACT
      new string `"shell-consistency"`.
- ❌ Don't modify `M.resolve_shell` / `M.mismatch_target` / `M.pick_driver` — the 2nd-return
      capture is at the CALL SITE (line 393) only. resolve_shell already returns source (T1.S1).
      mismatch_target stays pure + prefer-free (T2.S1's rule; this task respects it).
- ❌ Don't nest the new block inside the §17.4.3 mismatch `if`/`end` — they are SEPARATE
      conditions. Insert a NEW `if`/`end` AFTER the mismatch block's `end`, BEFORE pick_driver.
- ❌ Don't touch the §17.4.3 mismatch block (T2.S1 owns it — it's IN-FLIGHT), the shell-active
      block, or any shell-degrade block. This task ADDS one new block; it does not edit existing ones.
- ❌ Don't default `shell_source` to `"pi"` inside `fake_bridge` — leave it `nil` so the existing
      1-arg callers get source="pi" via resolve_shell's `or "pi"` (identical to pre-change). The
      TEST controls shell_source explicitly per case.
- ❌ Don't forget `inject_for("/bin/zsh")` in the 3 new cases — without it pick_driver("/bin/zsh")
      finds no driver → state.failed=true → shell-degrade fires, muddying the "active fires, no
      degrade" scope assertion.
- ❌ Don't match edits by line number — T2.S1 (in-flight) shifts ~395-410 by +2. Match by the
      verbatim content anchors (`local resolved = M.resolve_shell`, `-- (5) Pick the driver`).
- ❌ Don't widen scope to doc lines 200 (§5 config table) / 367 (§10 FAQ) — they make the same
      default-consistency claim but the contract scopes the doc edit to §3 (74-119). The §3
      subsection is the authoritative treatment; leave 200/367 as-is to avoid undocumented sprawl.
- ❌ Don't widen into Issue 1 (the mismatch gate — T2.S1), Issue 3/4/6 — separate tasks.
- ❌ Don't pipe a heredoc into `nvim` stdin (AGENTS.md HARD RULE — hangs). Write check Lua to a
      real `.lua` file (`/tmp/*.lua` or `tests/*.lua`), then `:luafile` it, wrapped in `timeout`.
- ❌ Don't skip the Level-4 repros — the live default-zsh repro is what the bug-hunt used to FIND
      Issue 2; re-running it (consistency_fired=true) is the proof of fix.