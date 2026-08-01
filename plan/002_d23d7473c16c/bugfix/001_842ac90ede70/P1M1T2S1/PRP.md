---
name: "P1.M1.T2.S1 — Issue 1: gate the §17.4.3 mismatch notice on prefer=='pi'"
description: |
  Surgical Lua fix in `lua/pi-bridge/shell.lua`. Wrap the ENTIRE existing
  `pcall(function() ... M.mismatch_target(resolved, vim.env.SHELL) ... end)`
  notice block inside `M.ensure()` (the §17.4.3 one-time "pi runs commands in
  bash; ... set pi's shellPath to <your shell>" WARN notice) in
  `if (cfg.prefer or "pi") == "pi" then ... end`, so the notice fires ONLY under
  `prefer=="pi"` (or nil/default). `M.mismatch_target` STAYS PURE + prefer-free
  (no change to the helper or its doc-comment). Under `prefer="bash"`
  (resolved=/bin/bash, source="default") or `prefer="/abs/path/to/bash"`
  (resolved=path, source="config"), the notice NO LONGER fires even when `$SHELL`
  is zsh/fish — the user deliberately chose bash, so advising them to "set
  shellPath to zsh" was misleading AND inert. The existing `shell-active` and
  `shell-degrade` notices are UNAFFECTED (they sit OUTSIDE this gate). Mode A:
  update the notice block's inline comment to document the `prefer=="pi"` gate.
  Add 3 plenary cases to `tests/shell_notices_spec.lua` (reuse the existing
  before_each/after_each + fake_bridge + inject_for + stub_executable harness):
  (a) prefer="bash" → no mismatch; (b) prefer="/bin/bash" (explicit path) → no
  mismatch; (c) REGRESSION prefer="pi" → mismatch STILL fires. NO user-facing or
  config-surface change. Issue 1 ONLY — do not touch Issues 2/3/4/5/6.
---

## Goal

**Feature Goal**: The §17.4.3 "switch to your native shell" mismatch notice in
`M.ensure()` fires **only under `prefer == "pi"`** (the default), matching PRD
§17.4.3's scope (*"`prefer:"pi"` resolves a shell poorer than `$SHELL`"*) and
the user docs (`doc/pi-bridge-shell.txt:111-114`). A user who **explicitly** sets
`prefer = "bash"` (or `prefer = "/bin/bash"`) — deliberately choosing bash
completion — no longer gets the misleading "set pi's `shellPath` to
/usr/bin/zsh" notice (advice that is inert under `prefer="bash"`, which forces
bash regardless of `shellPath`).

**Deliverable**:
1. `lua/pi-bridge/shell.lua` — wrap the existing §17.4.3 notice `pcall` block in
   `if (cfg.prefer or "pi") == "pi" then ... end` (one `if`/`end` pair + one TAB
   re-indent of the unchanged pcall body). Update the 4-line comment above it to
   document the gate + the §17.4.3 scope rationale. `cfg` is already in scope 9
   lines above (no new read).
2. `tests/shell_notices_spec.lua` — append 3 `it(...)` cases (suppress under
   `"bash"`, suppress under `"/bin/bash"`, regression-still-fires under `"pi"`)
   to the existing `describe(...)`, reusing the file's existing harness verbatim.

**Success Definition**:
- With `prefer="bash"` and `$SHELL=/bin/zsh` (zsh on PATH) and a healthy bash
  daemon spawn, `notify.did_notify("shell-mismatch")` is **FALSE**.
- With `prefer="/bin/bash"` (explicit path) and the same `$SHELL`, the mismatch
  notice is **FALSE**.
- With `prefer="pi"` (explicit) + descriptor.shell="/bin/bash" + `$SHELL=/bin/zsh`,
  the mismatch notice **STILL fires** (regression — the existing behavior is
  preserved for the scoped case).
- In all three cases the `shell-active` notice fires normally (the gate is
  SCOPED to the mismatch notice only — `shell-active`/`shell-degrade` sit
  outside it and are untouched).
- `tests/shell_notices_spec.lua` (all cases incl. 3 new), `shell_ensure_spec.lua`,
  `shell_spec.lua`, `shell_notices_smoke.lua` all PASS. `M.mismatch_target` and
  its doc-comment are UNCHANGED.

## User Persona (if applicable)

**Target User**: `pi-bridge.nvim` users who explicitly configure
`require("pi-bridge").setup({ shell = { prefer = "bash" } })` (or an explicit
bash path) — typically because they want bash-completion semantics or their pi
runs commands in bash — and whose login `$SHELL` is zsh/fish.

**Use Case**: A zsh user sets `prefer = "bash"` to align nvim shell-completion
with pi's bash execution. On the first `!`/`!!` activation, the daemon spawns
bash; today a misleading WARN fires ("set pi's `shellPath` to /usr/bin/zsh").
After this fix, no notice fires — the user already chose bash deliberately.

**Pain Points Addressed**: (1) Misleading advice (telling a `prefer="bash"` user
to "set shellPath to zsh"); (2) inert advice (under `prefer="bash"`, `shellPath`
is ignored — bash is forced). Both contradict PRD §17.4.3's scope and the
help docs.

## Why

- **PRD §17.4.3 scope fidelity**: the notice is scoped to *"`prefer:"pi"` resolves
  a shell poorer than `$SHELL`"*. `M.mismatch_target` is PURE (checks only
  `basename(resolved)=="bash"` + `$SHELL`∈{zsh,fish}) and has NO prefer awareness,
  so under `prefer="bash"` (`resolve_shell` returns `/bin/bash` directly, bypassing
  the descriptor) the condition fires whenever `$SHELL` is zsh/fish — outside the
  §17.4.3 scope. Gating at the call site restores the scope.
- **Correctness of advice**: under `prefer="bash"`, the advice "set `shellPath`
  to /usr/bin/zsh" is **inert** — `prefer="bash"` forces bash regardless of
  `shellPath`. Telling the user to do something that has no effect is a UX bug.
- **Helper stays pure (by design)**: `mismatch_target`'s own doc-comment
  (shell.lua:210-214) says "do NOT double-gate — it risks drifting from
  resolve_shell", meaning don't add a `prefer` PARAMETER to the helper. This fix
  respects that: the gate is at the CALL SITE, not inside the helper. The helper
  remains directly unit-testable + deterministic (the existing case (12) pure-unit
  cases are untouched).
- **Cheap & safe**: one `if`/`end` pair + a comment + a TAB re-indent. `cfg` is
  already in scope (shell.lua:390). The `or "pi"` default preserves every
  existing test where `prefer` is unset (the whole `shell_notices_spec.lua` suite
  sets no `prefer`). Zero API/config/user-facing/doc-surface change (Mode A).
- **Parallel-safe**: the in-flight Issue-5 task (P1.M1.T1.S1) edits DISJOINT code
  regions in the same file (`descriptor_shell()` + `resolve_shell`'s `"pi"`
  branch) — see All Needed Context. No merge conflict, no behavioral dependency.

## What

A one-`if`-wrap source change + comment update in `M.ensure()` + 3 plenary test
cases. The inner `pcall(function() ... end)` body is re-indented one TAB but
otherwise **byte-for-byte identical** (no logic change inside it). The gate is
literally `if (cfg.prefer or "pi") == "pi" then`.

### Success Criteria

- [ ] The §17.4.3 notice `pcall` block in `M.ensure()` is wrapped in
      `if (cfg.prefer or "pi") == "pi" then ... end` (the `pcall` body unchanged).
- [ ] The 4-line comment above the block is updated to state: fires ONLY under
      `prefer=="pi"` (the §17.4.3 scope); explicit `prefer="bash"`/path
      deliberately chose bash; `shell-active`/`shell-degrade` are OUTSIDE the gate.
- [ ] `M.mismatch_target` (shell.lua:222-228) AND its doc-comment are UNCHANGED
      (stays pure + prefer-free).
- [ ] The `shell-active` notice block (step 8b) and the `shell-degrade` notice
      blocks (steps 5/8a/8c) are UNCHANGED (outside the gate).
- [ ] New case (a): `prefer="bash"` + `$SHELL=/bin/zsh` + bash driver injected +
      `stub_executable({"zsh"})` → `notify.did_notify("shell-mismatch")` is FALSE,
      AND `shell-active` is TRUE (scope guard).
- [ ] New case (b): `prefer="/bin/bash"` (explicit path) + same `$SHELL` →
      mismatch FALSE, `shell-active` TRUE.
- [ ] New case (c) REGRESSION: `prefer="pi"` (explicit) + descriptor.shell
      ="/bin/bash" + `$SHELL=/bin/zsh` → mismatch STILL fires (TRUE).
- [ ] Existing case (2) ("mismatch notice fires", prefer unset → nil→pi default)
      still PASSES unchanged (the `or "pi"` default opens the gate).
- [ ] `tests/shell_notices_spec.lua` (all cases) + `shell_ensure_spec.lua` +
      `shell_spec.lua` + `shell_notices_smoke.lua` all PASS.
- [ ] NO user-facing/config/doc-surface change (Mode A — internal comment only).
- [ ] NO Issue 2/3/4/6 code touched (separate tasks).

## All Needed Context

### Context Completeness Check

_Pass test_: An agent who has never seen this repo can apply the one `edit`
(oldText→newText given verbatim below), append the 3 test cases (skeletons given
verbatim), run the listed nvim commands, and see green — without any other
context. The edit target is quoted with its exact current surrounding lines so
the match is unambiguous; the test cases reuse the file's existing helpers
(`fake_bridge`, `inject_for`, `stub_executable`, `wait_notify`,
`before_each`/`after_each`) which are summarized inline.

### Documentation & References

```yaml
# MUST READ — the fix design (verbatim code + the "gate at call site, keep helper pure" rationale)
- docfile: plan/002_d23d7473c16c/bugfix/001_842ac90ede70/architecture/shell_resolution_notice.md
  why: §"Issue 1 Fix" gives the exact gate expression `(cfg.prefer or "pi") == "pi"` + proves mismatch_target stays pure + confirms T1/T2 parallel-safety
  section: "## Issue 1 Fix: Gate Notice on prefer=='pi'"
  critical: |
    The helper's OWN doc-comment (shell.lua:210-214 "do NOT double-gate") is about NOT
    adding a prefer PARAMETER to mismatch_target. This fix respects that: the gate is at
    the CALL SITE in ensure(), NOT inside the helper. Keep mismatch_target pure.

# MUST READ — the file being edited (exact current content quoted in Implementation Patterns below)
- file: lua/pi-bridge/shell.lua
  why: the notice block to wrap (shell.lua:395-410); `cfg` already in scope (390); `resolved` (393); mismatch_target stays pure (222-228)
  pattern: "grep -nE '§17.4.3 one-time mismatch notice|pcall\\(function\\(\\)' lua/pi-bridge/shell.lua  → locate the block (match by CONTENT, not line number)"
  gotcha: |
    Line numbers in the contract (384-396) have DRIFTED — the block is at 395-410 today.
    Always match the edit by the verbatim quoted content. `cfg` is already declared 9 lines
    above the block (no new local needed).

# MUST READ — the test home + harness (copy verbatim; no new harness code)
- file: tests/shell_notices_spec.lua
  why: defines fake_bridge / make_fake_driver / inject_for / stub_executable / wait_notify + before_each/after_each that already save+restore pi.config.shell (lines 99,117); the existing case (2) "mismatch notice fires" is the sibling + the implicit-default regression proof
  pattern: "describe('pi-bridge.shell notices ...'); set pi.config.shell = { prefer = 'bash' } per-case (auto-restored by after_each); inject_for('/bin/bash') for the bash driver; stub_executable({'zsh'}) for the PATH check"
  gotcha: |
    Under prefer='bash', resolve_shell returns '/bin/bash' DIRECTLY (bypasses the
    descriptor), so pi.bridge's shell is NOT what determines resolved. But pick_driver
    STILL looks up the driver by basename(resolved)='bash' → you MUST inject_for('/bin/bash')
    or the no-driver path fires shell-degrade (muddying the scope assertion). The harness
    purges package.loaded['pi-bridge.shell.bash'] in before_each/after_each.

# MUST READ — the PRD issue (the bug contract)
- docfile: plan/002_d23d7473c16c/bugfix/001_842ac90ede70/prd_snapshot.md
  why: §h3.0 Issue 1 — exact expected/actual/steps + the "gate on prefer=='pi' in ensure()" suggested fix + the user-doc citation (doc/pi-bridge-shell.txt:111-114)
  section: "### Issue 1: prefer = 'bash' ... wrongly fires the §17.4.3 mismatch notice"

# MUST READ — test conventions (plenary runner + the nvim-stdin HARD RULE)
- docfile: plan/002_d23d7473c16c/bugfix/001_842ac90ede70/architecture/test_conventions.md
  why: the exact plenary runner command; the save/restore harness; the PATH-gate stub; the ⛔ HARD RULE (never heredoc→nvim stdin)
  section: "## Test Harness (plenary); ### PATH-gate Stub; ## ⛔ HARD RULE"

# MUST READ — the parallel-task PRP (proves disjoint edit regions → no conflict)
- docfile: plan/002_d23d7473c16c/bugfix/001_842ac90ede70/P1M1T1S1/PRP.md
  why: Issue 5 edits descriptor_shell() (shell.lua:143-156) + resolve_shell's "pi" branch (186-188) + its doc-comment — DISJOINT from this task's notice block (395-410). Confirms zero merge conflict + zero behavioral dependency (ensure captures only resolve_shell's 1st return; this gate keys on cfg.prefer, not source).
  section: "## Implementation Tasks (Task 1/2/3 edit sites) + ## Integration Points"
  critical: |
    Issue 5 + Issue 1 touch DIFFERENT functions in the same file (grep-confirmed: 143,
    179, 222, 395). Both can land in either order. Do NOT also implement Issue 5's
    descriptor_shell/resolve_shell changes here — stay within the notice block.

# SUPPORTING — resolve_shell's branch table (proves the gate semantics for each prefer value)
- docfile: plan/002_d23d7473c16c/bugfix/001_842ac90ede70/P1M1T2S1/research/notes.md
  why: §1 the gate-semantics table (nil→open, "pi"→open, "bash"→closed, "/bin/bash"→closed, "shell"→closed-harmless); §3 why closing under "shell" is harmless; §6 the verbatim 3 test cases + assertion discipline; §7 verified validation commands
```

### Current Codebase tree

```bash
$ ls -1 lua/pi-bridge/shell.lua tests/shell_notices_spec.lua tests/shell_notices_smoke.lua tests/shell_ensure_spec.lua tests/shell_spec.lua
lua/pi-bridge/shell.lua              # <- EDIT target (the §17.4.3 notice block in M.ensure)
tests/shell_ensure_spec.lua          # sibling (regression sweep, unchanged)
tests/shell_notices_smoke.lua        # sibling smoke (regression sweep, unchanged)
tests/shell_notices_spec.lua         # <- ADD 3 `it(...)` cases here (reuse existing harness)
tests/shell_spec.lua                 # sibling (resolve_shell unit cases, unchanged)
```

### Desired Codebase tree with files to be added

```bash
lua/pi-bridge/shell.lua          # (MODIFY) wrap notice pcall in `if (cfg.prefer or "pi") == "pi" then`; update comment — NO new file
tests/shell_notices_spec.lua     # (MODIFY) append 3 `it(...)` cases (2c/2d/2e) to the existing describe block
# No new files. No mismatch_target change. No health.lua / bridge.lua / driver change.
```

### Known Gotchas of our codebase & Library Quirks

```lua
-- CRITICAL: the `or "pi"` default in the gate is MANDATORY. The entire existing
--   shell_notices_spec.lua suite sets NO prefer (it relies on the nil→pi default).
--   Dropping `or "pi"` (i.e. `if cfg.prefer == "pi"`) would CLOSE the gate when
--   prefer is nil → every existing mismatch case would regress to no-fire. Use
--   the contract's exact expression: `if (cfg.prefer or "pi") == "pi" then`.

-- CRITICAL: wrap the ENTIRE pcall(function() ... end), NOT just the inner
--   require("pi-bridge.notify").once(...) call. The pcall also wraps the
--   mismatch_target call + the vim.fn.executable pcall — all three must be gated
--   together (calling mismatch_target under prefer="bash" is harmless since it's
--   pure, but gating the whole block is cleaner + matches the contract's "Wrap
--   the ENTIRE existing pcall(...) notice block").

-- CRITICAL: do NOT modify M.mismatch_target (shell.lua:222-228) or its
--   doc-comment. The helper stays PURE + prefer-free. The gate is at the CALL
--   SITE in ensure(). (Its doc-comment's "do NOT double-gate" line is about not
--   adding a prefer PARAMETER to the helper — this fix respects that.)

-- CRITICAL: do NOT touch the shell-active notice (step 8b) or the shell-degrade
--   notices (steps 5/8a/8c). They are OUTSIDE the new gate. The contract:
--   "The existing shell-active and shell-degrade notices are UNAFFECTED."

-- GOTCHA: match the edit by CONTENT, not line number. The contract said
--   "shell.lua:384-396" but the block is at 395-410 today (the file evolved).
--   The oldText below is the verbatim current block; the edit tool matches it
--   uniquely.

-- GOTCHA: under prefer="bash", resolve_shell returns "/bin/bash" DIRECTLY
--   (bypasses pi.bridge/descriptor). So in the test, pi.bridge's shell value
--   does NOT set `resolved` — but pick_driver("/bin/bash") STILL looks up
--   package.loaded["pi-bridge.shell.bash"]. You MUST inject_for("/bin/bash") in
--   the suppress cases, or the no-driver path fires shell-degrade (muddying the
--   "only mismatch is suppressed" assertion).

-- GOTCHA (AGENTS.md HARD RULE): NEVER pipe a heredoc into nvim stdin (it HANGS).
--   Write any throwaway check to a real .lua file (/tmp/*.lua or tests/*.lua),
--   then `:luafile` it. ALWAYS wrap nvim in `timeout`.

-- GOTCHA: in the suppress test cases, assert wait_notify("shell-mismatch") is
--   FALSE. wait_notify returns vim.wait's boolean — FALSE after 200ms if the
--   predicate never became true (i.e. the notice never registered). Do NOT
--   shorten the wait for suppress cases (a too-short wait could falsely report
--   false before a real fire registers). 200ms matches the existing harness.

-- GOTCHA: do NOT name a spec-local table `pending` (shadows plenary's skip fn).
```

## Implementation Blueprint

### Data models and structure

Not applicable — no data models change. `cfg.prefer` is already read by `ensure()`
(step 3, shell.lua:390) and passed to `resolve_shell` (step 4, 393). This fix adds
one boolean gate reusing that existing local.

### Implementation Tasks (ordered by dependencies)

```yaml
Task 1: EDIT lua/pi-bridge/shell.lua — wrap the §17.4.3 notice block in a prefer=="pi" gate
  - LOCATE the block by CONTENT (the 4-line comment starting
      "-- §17.4.3 one-time mismatch notice: prefer:\"pi\" resolved bash while $SHELL is a richer"
      followed by the `pcall(function() local richer = M.mismatch_target(...) ... end)`).
    It sits in M.ensure() between `state.shell = resolved` (step 4) and
    `state.driver = M.pick_driver(resolved)` (step 5).
  - REPLACE the 4-line comment + the bare `pcall(...)` with:
      (a) an UPDATED comment (5-6 lines) stating the prefer=="pi" gate + the §17.4.3
          scope + that shell-active/shell-degrade are outside the gate;
      (b) `if (cfg.prefer or "pi") == "pi" then`;
      (c) the ORIGINAL pcall body, re-indented ONE extra TAB (byte-for-byte identical logic);
      (d) `end`.
  - The exact oldText→newText is in "Implementation Patterns & Key Details" below.
  - DO NOT: touch M.mismatch_target, its doc-comment, the shell-active block, any
    shell-degrade block, descriptor_shell, resolve_shell, or any other notice/task.
  - DO NOT: change the message string, the notify category ("shell-mismatch"), the
    log level (WARN), or the vim.fn.executable PATH check. Only the wrapping gate + comment.
  - CRITICAL: the gate expression is EXACTLY `if (cfg.prefer or "pi") == "pi" then`
    (the `or "pi"` default is mandatory — see Gotchas).
  - NAMING: no new names (reuses existing `cfg` local from step 3).
  - INDENTATION: TABs (match the file). The re-indented pcall body gains ONE leading TAB.

Task 2: EDIT tests/shell_notices_spec.lua — append 3 cases (2c/2d/2e) to the describe block
  - LOCATE the existing `describe("pi-bridge.shell notices (P2.M2.T3.S4)", function() ... end)`
    block. INSERT the 3 new `it(...)` cases right AFTER the existing case (2b) ("mismatch
    message names the richer shell...") and BEFORE case (3) ("mismatch does NOT fire when the
    richer shell is absent from PATH"). (Placement is not load-bearing — anywhere inside the
    describe works — but grouping with the other mismatch cases aids readability.)
  - CASE (2c) "ISSUE-1: prefer='bash' does NOT fire the mismatch notice (user chose bash)":
      set pi.config.shell = { prefer = "bash" }; inject_for("/bin/bash");
      pi.bridge = fake_bridge("/bin/bash"); vim.env.SHELL = "/bin/zsh";
      local restore_exec = stub_executable({ "zsh" }); shell.ensure(function() end);
      assert.is_false(wait_notify("shell-mismatch"));
      assert.is_false(notify.did_notify("shell-mismatch"));
      assert.is_true(notify.did_notify("shell-active"), "scope guard: active still fires");
      assert.is_false(notify.did_notify("shell-degrade")); restore_exec()
  - CASE (2d) "ISSUE-1: prefer='/bin/bash' (explicit path) does NOT fire the mismatch notice":
      same as (2c) but pi.config.shell = { prefer = "/bin/bash" }; same assertions.
  - CASE (2e) "ISSUE-1 regression: prefer='pi' (explicit) STILL fires the mismatch notice":
      pi.config.shell = { prefer = "pi" }; inject_for("/bin/bash");
      pi.bridge = fake_bridge("/bin/bash"); vim.env.SHELL = "/bin/zsh";
      restore_exec = stub_executable({ "zsh" }); shell.ensure(function() end);
      assert.is_true(wait_notify("shell-mismatch"));
      assert.is_true(notify.did_notify("shell-mismatch")); restore_exec()
  - REUSE the file's existing helpers verbatim (fake_bridge, inject_for, stub_executable,
    wait_notify) + before_each/after_each (which already save/restore pi.config.shell at
    lines 99/117 + purge package.loaded["pi-bridge.shell.bash"]). NO new harness code.
  - The exact case bodies are in "Implementation Patterns & Key Details" below.

Task 3: VALIDATE — run the gates (Validation Loop); all must be green.
```

### Implementation Patterns & Key Details

```lua
-- === lua/pi-bridge/shell.lua — the ONLY source edit (Task 1) ===
-- Apply via the edit tool with this EXACT oldText→newText (content-matched, not line#).

-- OLD (the verbatim current block — shell.lua:395-410 today):
	-- §17.4.3 one-time mismatch notice: prefer:"pi" resolved bash while $SHELL is a richer
	-- zsh/fish on PATH. PURE condition (M.mismatch_target) + the PATH check
	-- (vim.fn.executable, pcall'd). notify.once dedups to once-per-session. Fires here ONLY
	-- on the first spawn (steps 4-8 run once per session — subsequent ensures hit the proc cache).
	pcall(function()
		local richer = M.mismatch_target(resolved, vim.env.SHELL)
		if richer then
			local ok, ex = pcall(vim.fn.executable, richer)
			if ok and ex == 1 then
				require("pi-bridge.notify").once("shell-mismatch", vim.log.levels.WARN,
					"pi-bridge: pi runs commands in bash; using bash completion to match. For your native "
					.. richer .. " completions, set pi's shellPath to " .. (vim.env.SHELL or richer)
					.. " (then completion and execution both use it). :help pi-bridge-shell")
			end
		end
	end)

-- NEW (wrap in the prefer=="pi" gate + update the comment; pcall body re-indented ONE TAB, logic identical):
	-- §17.4.3 one-time mismatch notice: fires ONLY under prefer=="pi" (the §17.4.3 scope —
	-- explicit prefer="bash"/"/abs/path" deliberately chose bash, so advising "set shellPath
	-- to your native zsh" would be misleading AND is inert under prefer="bash", which forces
	-- bash regardless of shellPath). Under prefer=="pi" (or nil/default): resolved bash while
	-- $SHELL is a richer zsh/fish on PATH. PURE condition (M.mismatch_target, prefer-free) +
	-- the PATH check (vim.fn.executable, pcall'd). notify.once dedups to once-per-session.
	-- The shell-active + shell-degrade notices are OUTSIDE this gate (they always run).
	-- Fires only on the first spawn (steps 4-8 run once per session — proc cache thereafter).
	if (cfg.prefer or "pi") == "pi" then
		pcall(function()
			local richer = M.mismatch_target(resolved, vim.env.SHELL)
			if richer then
				local ok, ex = pcall(vim.fn.executable, richer)
				if ok and ex == 1 then
					require("pi-bridge.notify").once("shell-mismatch", vim.log.levels.WARN,
						"pi-bridge: pi runs commands in bash; using bash completion to match. For your native "
						.. richer .. " completions, set pi's shellPath to " .. (vim.env.SHELL or richer)
						.. " (then completion and execution both use it). :help pi-bridge-shell")
				end
			end
		end)
	end
```

```lua
-- === tests/shell_notices_spec.lua — append AFTER case (2b) + BEFORE case (3) (Task 2) ===
-- Reuses the file's existing helpers (fake_bridge / inject_for / stub_executable /
-- wait_notify) + before_each/after_each (which already restore pi.config.shell).

	-- (2c) ISSUE-1: prefer="bash" + resolved=/bin/bash + $SHELL=/bin/zsh → NO mismatch
	it("ISSUE-1: prefer='bash' does NOT fire the mismatch notice (user chose bash)", function()
		pi.config.shell = { prefer = "bash" }
		inject_for("/bin/bash")           -- REQUIRED: pick_driver("/bin/bash") looks up .shell.bash
		pi.bridge = fake_bridge("/bin/bash")
		vim.env.SHELL = "/bin/zsh"
		local restore_exec = stub_executable({ "zsh" })
		shell.ensure(function() end)
		assert.is_false(wait_notify("shell-mismatch"), "mismatch MUST NOT fire under prefer='bash'")
		assert.is_false(notify.did_notify("shell-mismatch"))
		-- SCOPE guard: the gate suppresses ONLY the mismatch notice — active still fires
		assert.is_true(notify.did_notify("shell-active"), "shell-active still fires (gate is scoped)")
		assert.is_false(notify.did_notify("shell-degrade"), "no degrade (healthy bash spawn)")
		restore_exec()
	end)

	-- (2d) ISSUE-1: prefer="/bin/bash" (explicit path) + $SHELL=/bin/zsh → NO mismatch
	it("ISSUE-1: prefer='/bin/bash' (explicit path) does NOT fire the mismatch notice", function()
		pi.config.shell = { prefer = "/bin/bash" }
		inject_for("/bin/bash")
		pi.bridge = fake_bridge("/bin/bash")
		vim.env.SHELL = "/bin/zsh"
		local restore_exec = stub_executable({ "zsh" })
		shell.ensure(function() end)
		assert.is_false(wait_notify("shell-mismatch"), "mismatch MUST NOT fire under explicit prefer='/bin/bash'")
		assert.is_false(notify.did_notify("shell-mismatch"))
		assert.is_true(notify.did_notify("shell-active"), "scope guard: active still fires")
		restore_exec()
	end)

	-- (2e) ISSUE-1 REGRESSION: prefer="pi" (explicit) + descriptor bash + $SHELL=/bin/zsh → STILL fires
	it("ISSUE-1 regression: prefer='pi' (explicit) STILL fires the mismatch notice", function()
		pi.config.shell = { prefer = "pi" }
		inject_for("/bin/bash")
		pi.bridge = fake_bridge("/bin/bash")
		vim.env.SHELL = "/bin/zsh"
		local restore_exec = stub_executable({ "zsh" })
		shell.ensure(function() end)
		assert.is_true(wait_notify("shell-mismatch"), "mismatch MUST fire under prefer='pi' (regression)")
		assert.is_true(notify.did_notify("shell-mismatch"))
		restore_exec()
	end)
```

```lua
-- === Why the existing case (2) ("mismatch notice fires", prefer UNSET) still passes ===
-- Case (2) never sets pi.config.shell. ensure() reads cfg = (pi.config and pi.config.shell)
-- or {}. With prefer unset, cfg.prefer == nil. The gate: (cfg.prefer or "pi") == "pi" →
-- ("pi") == "pi" → TRUE → gate OPEN → the notice fires exactly as before. The `or "pi"`
-- default is what preserves every existing prefer-unset case. (Case (2e) makes the
-- prefer=="pi" path EXPLICIT, but (2) covers the implicit-nil path — both must pass.)
```

### Integration Points

```yaml
NO integration points to add. This is a call-site boolean gate reusing an existing local.
  - cfg (shell.lua:390) is already in scope 9 lines above the block — no new read.
  - resolved (shell.lua:393) is already in scope — no new read.
  - M.mismatch_target is UNCHANGED (pure, prefer-free).
  - The shell-active + shell-degrade notice blocks are UNCHANGED (outside the gate).
  - No config, no env var, no API surface, no descriptor schema, no doc-surface change.
PARALLEL TASK (Issue 5 / P1.M1.T1.S1 — running NOW):
  - Issue 5 edits descriptor_shell() (shell.lua:143-156) + resolve_shell's "pi" branch
    (186-188) + its doc-comment. DISJOINT from this task's notice block (395-410).
    grep -nE confirms the four functions are far apart (143, 179, 222, 395). Zero overlap.
  - Zero behavioral dependency: Issue 5 changes resolve_shell's 2nd return (source);
    ensure() captures ONLY the 1st return (resolved path). This gate keys on cfg.prefer,
    NOT on source. Either task can land first; merge is conflict-free.
DOWNSTREAM (NOT this task):
  - Issue 2 (P1.M1.T3.S1) adds a SEPARATE "shell-consistency" notice block (a NEW
    condition: prefer=="pi" AND source=="$SHELL" AND basename($SHELL)∈{zsh,fish}).
    It does NOT modify THIS notice block. Do NOT implement it here.
```

## Validation Loop

### Level 1: Syntax & Style (Immediate Feedback)

```bash
# Parse check (luac if available; else the plenary load in L2 covers parse). NEVER heredoc→nvim stdin.
luac -p lua/pi-bridge/shell.lua 2>/dev/null && echo "parse OK" || echo "luac unavailable (skip — L2 covers parse)"
# Expected: parse OK (or skip if luac absent).

# Confirm the gate landed (content grep, NOT line number):
grep -nE 'if \(cfg\.prefer or "pi"\) == "pi" then' lua/pi-bridge/shell.lua
# Expected: exactly 1 hit, inside M.ensure().

# Confirm mismatch_target is UNCHANGED (still pure, still 1 hit, no prefer param):
grep -nE 'function M\.mismatch_target' lua/pi-bridge/shell.lua
# Expected: 1 hit (unchanged).

# Confirm the shell-active + shell-degrade notices are untouched (still present):
grep -cE 'once\("shell-active"|once\("shell-degrade"' lua/pi-bridge/shell.lua
# Expected: >= 4 (active once + degrade 3x: no-driver / spawn-err / driver-threw / EOF / parse-threshold).
```

### Level 2: Unit Tests (the gate — the spec with the 3 new cases)

```bash
# Primary: the notices spec (home of the 3 new cases + all existing notice cases).
timeout 90 nvim --headless --clean -u tests/minimal_init.lua \
  -c 'lua require("plenary.busted").run("tests/shell_notices_spec.lua")'
# Expected: all `it` PASS, incl. (2c) suppress-bash, (2d) suppress-path, (2e) regression-pi,
#   AND every existing case ((1) active, (2)/(2b) mismatch fires + message, (3) no-PATH,
#   (4) self-gate, (5)-(9) degrade paths, (10) dedup, (11) suppression, (12) pure-unit,
#   (13) never-throws, (14) exposes). `fail 0`.

# The smoke matrix (plenary-free; exercises the full ensure path incl. the gate).
timeout 60 nvim --headless --clean -u NORC -c 'set rtp+=.' +"luafile tests/shell_notices_smoke.lua" +qa; echo "exit=$?"
# Expected: prints SMOKE_PASS, exit=0.
```

### Level 3: Regression Sweep (ensure + resolve_shell — must be unaffected)

```bash
# shell_ensure_spec.lua — the ensure() lifecycle spec (the gate is inside ensure; re-confirm no regression).
timeout 90 nvim --headless --clean -u tests/minimal_init.lua \
  -c 'lua require("plenary.busted").run("tests/shell_ensure_spec.lua")'
# Expected: all PASS (the gate does not touch cache/failed/driver-spawn paths).

# shell_spec.lua — resolve_shell + mismatch_target pure unit cases (must be unchanged).
timeout 90 nvim --headless --clean -u tests/minimal_init.lua \
  -c 'lua require("plenary.busted").run("tests/shell_spec.lua")'
# Expected: all PASS (mismatch_target is pure + unchanged; resolve_shell branches untouched).

# health_spec.lua — the consumer of resolve_shell's source (Issue 5's concern; this task
# doesn't touch source, but cheap to re-confirm green).
timeout 90 nvim --headless --clean -u tests/minimal_init.lua \
  -c 'lua require("plenary.busted").run("tests/health_spec.lua")'
# Expected: all PASS.
```

### Level 4: Manual / Adversarial (the exact bug repro — prefer="bash")

```bash
# Reproduce the EXACT Issue-1 scenario live: prefer="bash", $SHELL=/bin/zsh, fake bash daemon.
# Assert the mismatch notice does NOT fire (and active does). Heredoc→FILE is fine; nvim stdin is NOT.
cat > /tmp/issue1_check.lua <<'LUA'
local pi = require("pi-bridge")
if pi.config == nil then pi.setup({}) end
pi.config.shell = { prefer = "bash" }
local shell = require("pi-bridge.shell")
local notify = require("pi-bridge.notify")
-- inject a fake bash driver so pick_driver("/bin/bash") succeeds (avoids the degrade path)
package.loaded["pi-bridge.shell.bash"] = {
  start = function(_opts, cb)
    cb(nil,
      { is_closing = function() return false end },
      { read_start = function() end, close = function() end, is_closing = function() return false end },
      { write = function() end, close = function() end, is_closing = function() return false end })
  end,
}
pi.bridge = { get_shell_info = function() return { shell = "/bin/bash" } end, server_info = {} }
vim.env.SHELL = "/bin/zsh"
notify.reset(); shell.reset()
shell.ensure(function() end)
vim.wait(150, function() return false end, 5)  -- flush any scheduled notify
print("mismatch_fired=" .. tostring(notify.did_notify("shell-mismatch")))
print("active_fired=" .. tostring(notify.did_notify("shell-active")))
assert(notify.did_notify("shell-mismatch") == false, "BUG: mismatch fired under prefer='bash'")
assert(notify.did_notify("shell-active") == true, "scope guard failed: active should fire")
print("ISSUE1_OK")
LUA
timeout 60 nvim --headless --clean -u NORC -c 'set rtp+=.' +"luafile /tmp/issue1_check.lua" +qa; echo "exit=$?"
# Expected: prints `mismatch_fired=false` + `active_fired=true` + `ISSUE1_OK`, exit=0.

# Also re-run the regression direction (prefer="pi" STILL fires) live:
cat > /tmp/issue1_regression.lua <<'LUA'
local pi = require("pi-bridge")
if pi.config == nil then pi.setup({}) end
pi.config.shell = { prefer = "pi" }
local shell = require("pi-bridge.shell")
local notify = require("pi-bridge.notify")
package.loaded["pi-bridge.shell.bash"] = {
  start = function(_opts, cb)
    cb(nil, { is_closing = function() return false end },
      { read_start = function() end, close = function() end, is_closing = function() return false end },
      { write = function() end, close = function() end, is_closing = function() return false end })
  end,
}
pi.bridge = { get_shell_info = function() return { shell = "/bin/bash" } end, server_info = {} }
vim.env.SHELL = "/bin/zsh"
notify.reset(); shell.reset()
shell.ensure(function() end)
vim.wait(150, function() return notify.did_notify("shell-mismatch") end, 5)
print("mismatch_fired=" .. tostring(notify.did_notify("shell-mismatch")))
assert(notify.did_notify("shell-mismatch") == true, "REGRESSION: mismatch must fire under prefer='pi'")
print("ISSUE1_REGRESSION_OK")
LUA
timeout 60 nvim --headless --clean -u NORC -c 'set rtp+=.' +"luafile /tmp/issue1_regression.lua" +qa; echo "exit=$?"
# Expected: prints `mismatch_fired=true` + `ISSUE1_REGRESSION_OK`, exit=0.
```

## Final Validation Checklist

### Technical Validation

- [ ] Level 1: `grep -nE 'if \(cfg\.prefer or "pi"\) == "pi" then'` → 1 hit; mismatch_target
      unchanged (1 hit); shell-active/shell-degrade notices still present (≥4).
- [ ] Level 2: `tests/shell_notices_spec.lua` PASS (incl. 3 new cases 2c/2d/2e + all existing).
- [ ] Level 2: `tests/shell_notices_smoke.lua` PASS (exit=0, SMOKE_PASS).
- [ ] Level 3: `tests/shell_ensure_spec.lua` + `tests/shell_spec.lua` + `tests/health_spec.lua` PASS.
- [ ] Level 4: `/tmp/issue1_check.lua` prints `mismatch_fired=false` + `ISSUE1_OK`;
      `/tmp/issue1_regression.lua` prints `mismatch_fired=true` + `ISSUE1_REGRESSION_OK`.

### Feature Validation

- [ ] `prefer="bash"` + `$SHELL=/bin/zsh` → mismatch notice does NOT fire; shell-active DOES.
- [ ] `prefer="/bin/bash"` (explicit path) + `$SHELL=/bin/zsh` → mismatch does NOT fire.
- [ ] `prefer="pi"` (explicit) + descriptor.shell="/bin/bash" + `$SHELL=/bin/zsh` → mismatch
      STILL fires (regression preserved).
- [ ] `prefer` unset (nil→pi default) → mismatch still fires (existing case (2) green).
- [ ] `M.mismatch_target` + its doc-comment are UNCHANGED (pure, prefer-free).
- [ ] shell-active + shell-degrade notices are UNCHANGED (outside the gate).

### Code Quality Validation

- [ ] The `or "pi"` default is present in the gate (NOT `cfg.prefer == "pi"`).
- [ ] The ENTIRE pcall block is wrapped (not just the inner notify call).
- [ ] The pcall body is byte-for-byte identical (only re-indented one TAB).
- [ ] Edits are the SMALLEST possible (one `if`/`end` + comment + 3 test cases); no refactors.
- [ ] Comment updated to Mode A (documents the gate + the §17.4.3 scope + that active/degrade
      are outside the gate).
- [ ] Indentation matches the file (TABs); no new patterns introduced.
- [ ] No new files, no API/config/env-var/doc-surface change.

### Documentation & Deployment

- [ ] The notice block's inline comment states the `prefer=="pi"` gate + rationale (Mode A).
- [ ] No user-facing doc change required (the user docs at `doc/pi-bridge-shell.txt:111-114`
      already describe the correct scope; this fix makes the code match them).
- [ ] No `README.md` / `doc/pi-bridge.txt` change (internal comment only — Mode A).

---

## Anti-Patterns to Avoid

- ❌ Don't drop the `or "pi"` default — `if cfg.prefer == "pi"` would CLOSE the gate when
      prefer is nil, regressing EVERY existing prefer-unset test (the whole notices suite).
      Use the contract's exact `if (cfg.prefer or "pi") == "pi" then`.
- ❌ Don't modify `M.mismatch_target` or its doc-comment — it stays PURE + prefer-free. The
      gate is at the CALL SITE in `ensure()`. (Its "do NOT double-gate" line is about not
      adding a prefer PARAMETER to the helper — this fix respects that.)
- ❌ Don't gate only the inner `require("pi-bridge.notify").once(...)` — wrap the ENTIRE
      `pcall(function() ... end)` block (the mismatch_target call + the executable pcall +
      the notify are one unit).
- ❌ Don't touch the shell-active notice (step 8b) or any shell-degrade notice (steps 5/8a/
      8c) — they are OUTSIDE this gate. The contract: "shell-active and shell-degrade
      notices are UNAFFECTED."
- ❌ Don't match the edit by line number — the contract said "384-396" but it's at 395-410
      today. Match by the verbatim quoted content (the `edit` tool's oldText).
- ❌ Don't widen into Issue 2 (the `shell-consistency` footgun notice), Issue 3/4/5/6 —
      those are separate tasks. Issue 5 is running in parallel on DISJOINT lines; Issue 2
      adds a NEW notice block, it doesn't modify this one.
- ❌ Don't pipe a heredoc into `nvim` stdin (AGENTS.md HARD RULE — hangs). Write check Lua
      to a real `.lua` file (`/tmp/*.lua` or `tests/*.lua`), then `:luafile` it, wrapped in `timeout`.
- ❌ Don't skip the Level-4 repros "because it's a one-line gate" — the live prefer="bash"
      repro is what the bug-hunt used to FIND this issue; re-running it is the proof of fix.
- ❌ Don't add a new harness in the test — reuse `fake_bridge` / `inject_for` /
      `stub_executable` / `wait_notify` + the existing `before_each`/`after_each` (which
      already save/restore `pi.config.shell` at lines 99/117).
- ❌ Don't forget `inject_for("/bin/bash")` in the suppress cases — under `prefer="bash"`,
      `pick_driver("/bin/bash")` looks up `pi-bridge.shell.bash`; without the injection the
      no-driver path fires `shell-degrade`, muddying the "only mismatch is suppressed" scope assertion.