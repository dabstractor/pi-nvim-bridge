---
name: "P2.M3.T5.S3 — Unknown-shell degrade path: dedicated regression-guard test"
description: |
  A 0.5-point, TEST-ONLY task. The unknown-shell degrade path is already fully
  implemented in `lua/pi-bridge/shell.lua` (`pick_driver`→nil → `ensure` sets
  `state.failed=true`, fires ONE dedup'd `notify.once("shell-degrade",...)`,
  callbacks `"no driver for <shell>"`, and follow-up `ensure` short-circuits
  with `"daemon disabled"`). Its coverage is currently *scattered* across
  `tests/shell_spec.lua`, `tests/shell_ensure_spec.lua`, and
  `tests/shell_notices_spec.lua`. This PRP adds ONE dedicated, self-contained
  test pair — a plenary `*_spec.lua` + a plenary-free `*_smoke.lua` — that
  verifies the *complete* end-to-end degrade contract (nil driver → failed flag →
  short-circuit → single notice → consumer `complete_current` receives `err`)
  as a focused regression guard, mirroring the existing one-task-per-file test
  convention used for every other shell subsystem (fish/zsh/bash drivers, accept,
  feed, request, teardown, notices, complete_current).
---

## Goal

**Feature Goal**: Consolidate the unknown-shell degrade path's verification into
a single dedicated, self-contained test pair (`tests/shell_unknown_shell_spec.lua`
+ `tests/shell_unknown_shell_smoke.lua`) that proves the complete degrade
contract — `pick_driver` returns nil for any unrecognized/absent/disabled shell →
`ensure()` sets `state.failed=true`, fires exactly one dedup'd degrade notice,
reports `"no driver for <shell>"` to its callback, and every subsequent
`ensure()` / `complete_current()` short-circuits with `"daemon disabled"` / an
`err` (no retry storm, no leaked handle, no second notice).

**Deliverable**: Two new test files only (no production code changes):
- `tests/shell_unknown_shell_spec.lua` — plenary/busted Level-2 spec.
- `tests/shell_unknown_shell_smoke.lua` — plenary-free Level-1 smoke (instant,
  no dependencies, exits 0/1 via `cquit`).

**Success Definition**: Both files run green via the repo's documented runners;
they assert EVERY documented behavior of the degrade path in one place; they
introduce zero new production-code edits; and they follow the exact conventions
(header comment block, `fake_bridge`, `make_fake_driver`, save/restore globals,
`pcall`-everywhere, `cquit 1` on failure, `SMOKE_PASS` on success) of the sibling
`shell_*_spec.lua` / `shell_*_smoke.lua` files.

## User Persona (if applicable)

**Target User**: Maintainer of `pi-bridge.nvim` / `pi-nvim-bridge` (the developer
adding shell completion for `!`/`!!` bash mode, PRD §17).

**Use Case**: A future change to `pick_driver`, `ensure`, the `state.failed`
short-circuit, or `notify.once` keys could silently break the unknown-shell
degrade path. A dedicated regression guard catches that in one file at a glance.

**User Journey**: Maintainer edits `shell.lua` → runs the spec + smoke → if the
degrade contract regressed, the test names pinpoint which invariant broke (nil
driver, failed flag, short-circuit message, single-notice dedup, consumer err).

**Pain Points Addressed**: Today the degrade coverage is spread across 3 spec
files; a regression in one invariant can slip because the assertion lives in an
unrelatedly-named file (`shell_notices_spec.lua`, `shell_ensure_spec.lua`).
Consolidation makes the contract legible and the failure messages specific.

## Why

- **Regression safety for the only "silent failure is the contract" path.** The
  unknown-shell degrade path is *required to never throw, never block, never
  retry, and never notify twice* (PRD §17.6.4, §17.12). That is a lot of
  invariants for a path whose correctness is "do nothing." A dedicated test is
  the cheapest way to keep it honest.
- **Closes P2.M3.T5.** P2.M3.T5.S1 (zsh driver) and S2 (bash driver) are done;
  S3 is the unknown/degrade case. A dedicated pair completes the
  "every shell-decision outcome has its own test file" symmetry.
- **No production risk.** Test-only: zero chance of breaking the live bridge or
  plugin. Cheap to add, cheap to maintain.

## What

A dedicated test pair that asserts, for an **unknown shell basename** (e.g.
`/bin/noshell`, `/usr/local/bin/elvish`), a **user-disabled driver**
(`config.shell.drivers.<base> == false`), and the **malformed-input** edges
(nil/`""`/non-string resolved shell):

1. `pick_driver(...)` returns `nil` and never throws.
2. `ensure(on_ready)` calls `on_ready("no driver for <shell>")` exactly once.
3. `ensure` sets `state.failed = true` (observable via the follow-up short-circuit).
4. `ensure` fires `notify.once("shell-degrade", vim.log.levels.WARN, ...)` exactly
   once; a second `ensure` does NOT fire a second notice (dedup).
5. A follow-up `ensure(on_ready)` short-circuits with `on_ready("daemon disabled")`
   WITHOUT re-resolving, re-picking, or re-calling any driver `.start`.
6. The consumer seam `complete_current(buf, cb)` receives an `err` (truthy) and
   `nil`/empty items when the daemon is in the degraded state — proving the
   degrade propagates to the menu (which then never opens).
7. The path never throws on any combination of malformed inputs (nil bridge,
   nil descriptor, nil `on_ready`, nil `pi.config`).

### Success Criteria

- [ ] `tests/shell_unknown_shell_spec.lua` exists, runs green via the plenary runner,
  and asserts every one of the 7 behaviors above as named `it(...)` cases.
- [ ] `tests/shell_unknown_shell_smoke.lua` exists, runs green via the smoke runner,
  prints `SMOKE_PASS`, exits 0; fails print `FAIL: <msg>` to stderr and `cquit 1`.
- [ ] No production file is modified (`lua/**`, `extension/**`, `plugin/**`,
  `ftplugin/**`, `doc/**` all untouched).
- [ ] The test files are self-sufficient: they `require("pi-bridge")` +
  `pi.setup({})` if `pi.config == nil` (mirrors `shell_spec.lua` L18), and
  construct their own `fake_bridge` + `make_fake_driver` (mirrors
  `shell_ensure_spec.lua`) — they do NOT import helpers from another spec.
- [ ] Each spec case restores every global it swaps (`vim.env.SHELL`,
  `pi.bridge`, `pi.descriptor`, `pi.config.shell(.drivers)`,
  `package.loaded["pi-bridge.shell.<base>"]`) in `after_each`, and calls
  `shell.reset()` — no test pollution.

## All Needed Context

### Context Completeness Check

_Pass_: A developer who has never seen this repo can implement both test files
using only: (a) this PRP, (b) the three existing sibling test files it copies
conventions from (paths named below), and (c) the degrade-path implementation in
`shell.lua` (line ranges named below). No inference about pi, luv, or plenary
beyond what those siblings already demonstrate is required.

### Documentation & References

```yaml
# MUST READ — the implementation under test (READ-ONLY: do not modify)
- file: lua/pi-bridge/shell.lua
  why: The degrade path lives here. The test asserts the observable contract of
        three functions + one state field.
  sections:
    - "M.pick_driver (lines ~234-249)": basename → `pcall(require, "pi-bridge.shell.<base>")`;
        returns the module iff it has `.start`; returns nil for unknown basename,
        non-string, "", "?", or a user-disabled driver (`config.shell.drivers.<base>==false`).
    - "M.ensure (lines ~343-440)": the short-circuit chain —
        (1) `if state.proc then cb(nil)` (cached),
        (2) `if state.failed then cb("daemon disabled")`,
        (3) resolve_shell + mismatch notice,
        (4) `state.driver = M.pick_driver(resolved)`; `if not state.driver then
            state.failed=true; notify.once("shell-degrade",WARN,...); cb("no driver for "..resolved)`.
    - "state.failed (field, ~line 119)": set true on permanent failure; cleared by reset().
    - "M.complete_current(buf, cb) (lines ~959+)": calls ensure → request; in the
        degraded state ensure reports err → complete_current forwards (err, nil, "") to cb.
  pattern: The test mirrors the SAME fake_bridge + make_fake_driver shape already
           proven in shell_ensure_spec.lua — it does not invent new fakes.
  gotcha: ensure reads config/bridge/descriptor FRESH inside the function (lazy
          `require("pi-bridge")`), so the test must set `pi.bridge` / `pi.config`
          BEFORE calling ensure, not at module load (mirrors shell.lua header note +
          shell_spec.lua's per-case before_each).

# MUST READ — the conventions to copy verbatim (READ-ONLY: copy their shape, do not import them)
- file: tests/shell_ensure_spec.lua
  why: The closest sibling. Copy its file header, the `fake_bridge(shell_path, server_cwd)`
        helper, the `make_fake_driver()` helper (fake pipes with read_start/write/close/
        read_stop/is_closing + a start that calls cb SYNCHRONOUSLY), the
        orig_*/restore `before_each`/`after_each` save/restore pattern, and the
        `it("no driver (unknown shell) sets failed=true; cb('no driver for '..shell)")`
        assertion idiom (lines ~150-170). The new spec EXPANDS that single case into
        the full 7-invariant matrix.
  pattern: header comment → `local pi = require("pi-bridge")` → `local shell =
           require("pi-bridge.shell")` → `if pi.config == nil then pi.setup({}) end`
           → helper defs → `describe`/`before_each`/`after_each`/`it` → no top-level
           `vim.cmd` (busted drives it).
  gotcha: do NOT name a spec-local table `pending` — it shadows plenary.busted's
          global `pending` (skip) function. Use `got`/`results` locals (see
          shell_spec.lua L15-16 note).

- file: tests/shell_ensure_smoke.lua
  why: The plenary-free template. Copy its bootstrap (debug.getinfo → plugin_root →
        `vim.opt.runtimepath:append`), its `fails`/`check(cond,msg)` helper, its
        `fake_bridge` + `make_fake_driver` (self-contained, no cross-file imports),
        its save/restore `restore()` idiom, and its tail (`if fails>0 then ...cquit 1 end`
        → `io.stdout:write("SMOKE_PASS\n")`).
  pattern: A single linear script: bootstrap → check() each invariant → restore →
           exit code. ZERO plenary, ZERO `describe`.
  gotcha: MUST be runnable via the AGENTS.md-safe invocation:
          `nvim --headless --clean -u NORC -c 'set rtp+=.' +"luafile tests/shell_unknown_shell_smoke.lua" +qa`
          (write the file to disk, then :luafile it — NEVER pipe a heredoc into
          nvim's stdin; that HANGS the session, per repo AGENTS.md ⛔ HARD RULE).

- file: tests/shell_spec.lua
  why: The resolution-layer sibling. Its `pick_driver` describe block (the
        "returns nil for an unknown shell", "returns nil when the module lacks
        .start", "returns nil for a user-disabled driver", "never throws on nil/''/"
        "non-string" cases) is the exact set of nil-driver preconditions the new
        spec re-asserts at the ensure level (proving pick_driver's nil flows
        through to ensure's failed flag).
  pattern: `package.loaded["pi-bridge.shell.fish"] = { start = function() end }`
           to inject a fake driver; set to nil to simulate "no module" (unknown shell).

- file: tests/shell_notices_spec.lua
  why: Proves the degrade NOTICE fires exactly once (`notify.once("shell-degrade",...)`)
        and that the first-run hint is SUPPRESSED on degrade (case "(5) DEGRADE
        no-driver"). The new spec re-asserts the single-notice invariant in its
        own describe block using the same `notify.did_notify("shell-degrade")`
        + a `wait_notify` shim if needed — but prefer the simpler direct
        `require("pi-bridge.notify").once` spy used in shell_notices_spec if present.
  pattern: spy on notify.once via a package.loaded swap or a recorded-calls table.

# REFERENCE — PRD context for WHY the degrade path exists (READ-ONLY)
- docfile: PRD.md  # the merged PRD §17
  section: "§17.6.4 unknown shells — degrade" + "§17.12 Failure modes & degradation"
  why: States the contract the test encodes: unknown basename → `shell/unknown.lua`
       (or nil driver) → `request` short-circuits to `cb("no driver")`; completion.lua
       treats it as a null result (empty items → menu closes); a single vim.notify
       fires once; never blocks, never throws.
  critical: "A basename not in {fish,zsh,bash} → degrade" and "after N consecutive
            parse failures → disabled" are BOTH terminal `state.failed` paths; the
            test must distinguish "no driver" (immediate) from "parse-threshold"
            (already covered by shell_feed_spec — out of scope here).

- url: https://github.com/nvim-lua/plenary.nvim#busted
  why: The plenary.busted API (`describe`/`it`/`before_each`/`after_each`/
        `assert.are.equals`/`assert.is_nil`/`assert.has_no.errors`/`assert.is_truthy`).
  critical: tests run via `require("plenary.busted").run("tests/<spec>.lua")`; a spec
            file is a plain Lua module, NOT executed top-to-bottom by nvim.
```

### Current Codebase tree (relevant slice)

```bash
lua/pi-bridge/
├── shell.lua              # IMPLEMENTATION (read-only for this task): pick_driver,
│                          #   ensure, complete_current, state.failed, reset
├── notify.lua             # notify.once(key, level, msg) + did_notify(key) — the spy seam
├── init.lua               # pi.config, pi.bridge, pi.descriptor, pi.defaults
└── shell/
    ├── fish.lua  zsh.lua  bash.lua   # the 3 recognized drivers (pick_driver finds these)
    └── accept.lua                      # (not exercised by the degrade path)

tests/
├── minimal_init.lua                          # plenary bootstrap (rtp: plenary + repo root)
├── smoke.lua                                 # the canonical smoke shape (check/cquit/SMOKE_PASS)
├── shell_spec.lua            # pick_driver nil cases (RESOLUTION layer) — sibling
├── shell_ensure_spec.lua     # ensure no-driver/failed cases (SPAWN layer) — sibling
├── shell_notices_spec.lua    # degrade-notice dedup (NOTICES layer) — sibling
├── shell_ensure_smoke.lua    # plenary-free spawn-layer smoke — the template
└── (NEW) shell_unknown_shell_spec.lua   # ← this task
    (NEW) shell_unknown_shell_smoke.lua  # ← this task
```

### Desired Codebase tree with files to be added

```bash
tests/
├── shell_unknown_shell_spec.lua    # NEW — plenary/busted Level-2 spec: the full
│                                    #   7-invariant degrade matrix (pick_driver nil →
│                                    #   ensure failed/cb/short-circuit → single notice →
│                                    #   complete_current err). Self-contained: own
│                                    #   fake_bridge + make_fake_driver + save/restore.
└── shell_unknown_shell_smoke.lua   # NEW — plenary-free Level-1 smoke: the same matrix
                                     #   as a linear check() script, exits 0/1. ZERO deps.
# No production files added or modified.
```

### Known Gotchas of our codebase & Library Quirks

```lua
-- CRITICAL: ensure() reads pi.bridge / pi.config / pi.descriptor FRESH inside the
-- function body (lazy require, mirrors completion.lua + bridge.lua). The test MUST
-- set these in before_each (NOT at module load) or the resolve_shell fallback chain
-- will read stale nils. See shell_spec.lua before_each (sets pi.bridge=nil, etc.).

-- CRITICAL: inject a fake driver via package.loaded["pi-bridge.shell.<base>"] = {...}
-- (NOT require). For the UNKNOWN-shell case, ensure NO such package.loaded entry
-- exists (clean it to nil in before_each) so pcall(require,...) fails → nil driver.
-- For the DISABLED-driver case, DO inject a loadable module AND set
-- pi.config.shell.drivers.<base> = false — pick_driver checks the disabled flag
-- BEFORE the require (shell.lua ~L243), so a disabled-but-loadable driver still nils.

-- CRITICAL (AGENTS.md ⛔ HARD RULE): the smoke test is a FILE run via
--   nvim ... +"luafile tests/shell_unknown_shell_smoke.lua" +qa
-- NEVER `nvim ... +"luafile /dev/stdin" +qa <<EOF` — piping a heredoc into nvim's
-- stdin HANGS the session dead. Write the file to disk, then :luafile it.

-- CRITICAL: do NOT name a spec-local table `pending` — it shadows plenary.busted's
-- global skip function. Use `got`/`results` locals (shell_spec.lua L15 note).

-- GOTCHA: ensure's on_ready callback may be invoked from a luv fast-context in real
-- use, but the no-driver path calls it SYNCHRONOUSLY from the Lua call site (no
-- spawn), so the test needs no vim.schedule / vim.wait. Mirror shell_ensure_spec's
-- direct `local got="UNSET"; shell.ensure(function(err) got=err end); assert(...)`.

-- GOTCHA: notify.once dedups on a string key ("shell-degrade"). To assert "fires
-- once", call ensure twice and check notify.once recorded exactly one call for that
-- key. The spy pattern: swap package.loaded["pi-bridge.notify"] with a recorder
-- {once=function(k,l,m) t[k]=(t[k] or 0)+1 end, did_notify=function(k) return (t[k] or 0)>0 end}
-- OR use the real notify.lua + reset it between cases (notify_spec.lua shows the API).

-- GOTCHA: between cases, reset BOTH shell state (shell.reset()) AND notify dedup
-- state (the notify module's internal seen-set) — otherwise the "fires once across
-- two ensure() calls" assertion leaks across tests. shell_notices_spec.lua shows
-- the notify.reset() / re-inject pattern.
```

## Implementation Blueprint

### Data models and structure

None — this is a test-only task. The "models" are the fakes already proven in
`tests/shell_ensure_spec.lua`:

```lua
-- fake_bridge(shell_path, server_cwd) — controls resolve_shell's result.
--   get_shell_info() returns { shell = shell_path } (or nil) → drives pick_driver.
--   server_info.cwd = server_cwd (or {}) → drives session_cwd (nil-safe).
-- make_fake_driver() — a loadable { start=fn, captured={...} } with fake pipes,
--   used ONLY for the "disabled driver" case (module loadable but flag=false) and
--   for proving a follow-up ensure does NOT re-call .start on the degraded path.
-- A notify recorder/spy — wraps notify.once to count calls per key (see gotchas).
```

### Implementation Tasks (ordered by dependencies)

```yaml
Task 1: CREATE tests/shell_unknown_shell_spec.lua  (plenary/busted Level-2 spec)
  - IMPLEMENT: a `describe("pi-bridge.shell unknown-shell degrade (P2.M3.T5.S3)")`
    block with these `it` cases (each named for the invariant it pins):
      1. "pick_driver returns nil for an unknown shell basename (/bin/noshell)"
      2. "pick_driver returns nil for a user-disabled driver (config.drivers.fish=false)"
      3. "pick_driver returns nil when the module lacks .start"
      4. "pick_driver never throws on nil / '' / non-string resolved_shell"
      5. "ensure(no driver) sets state.failed=true + cb('no driver for <shell>')"
      6. "ensure(no driver) fires notify.once('shell-degrade', WARN) EXACTLY ONCE across two calls"
      7. "follow-up ensure short-circuits with cb('daemon disabled'); driver.start NOT re-called"
      8. "complete_current(buf, cb) receives (err truthy, nil items, '') when degraded"
      9. "disabled-driver path: ensure cb('no driver for <shell>'); .start NEVER called"
     10. "never throws on nil bridge / nil descriptor / nil config / nil on_ready"
  - FOLLOW pattern: tests/shell_ensure_spec.lua (header, helpers, save/restore, assert idioms)
  - NAMING: file `tests/shell_unknown_shell_spec.lua`; describe/it strings prefixed
            with the invariant; the P2.M3.T5.S3 task id in the file header comment.
  - DEPENDENCIES: requires `pi-bridge`, `pi-bridge.shell`, `pi-bridge.notify` (all exist).
  - PLACEMENT: tests/ alongside the other shell_*_spec.lua files.
  - COVERAGE: all 7 success-criteria behaviors + the disabled-driver + never-throws edges.

Task 2: CREATE tests/shell_unknown_shell_smoke.lua  (plenary-free Level-1 smoke)
  - IMPLEMENT: the SAME invariant matrix as Task 1, but as a single linear script
    using the `check(cond, msg)` helper (no describe/it). Bootstrap via
    debug.getinfo → runtimepath:append(plugin_root). Inject the fake driver +
    fake bridge inline. Assert: pick_driver nil, ensure cb=="no driver for...",
    failed flag set (via follow-up short-circuit), single notice, complete_current
    err. Restore globals. Print SMOKE_PASS / cquit 1.
  - FOLLOW pattern: tests/shell_ensure_smoke.lua (bootstrap, check helper, fake_bridge,
    make_fake_driver, restore(), tail exit logic).
  - NAMING: file `tests/shell_unknown_shell_smoke.lua`.
  - DEPENDENCIES: ZERO (no plenary; uses only vim.json/vim.uv builtins via the module).
  - PLACEMENT: tests/ alongside the other shell_*_smoke.lua files.
  - GOTCHA: run via +"luafile <file>" +qa (AGENTS.md ⛔ never heredoc→stdin).

# No Task 3+ — there is no production-code change. The implementation in shell.lua
# is already complete and correct (verified by reading it + the 3 existing specs).
```

### Implementation Patterns & Key Details

```lua
-- PATTERN: the no-driver ensure case (the heart of this spec). Mirror
-- shell_ensure_spec.lua lines ~150-170, EXPANDED to assert EVERY observable side effect.
it("ensure(no driver) sets state.failed=true + cb('no driver for <shell>') + ONE notice", function()
	pi.bridge = fake_bridge("/bin/noshell")   -- unknown basename → pick_driver nil
	package.loaded["pi-bridge.shell.noshell"] = nil  -- ensure no module resolves
	local notices = {}                         -- spy on notify.once
	local real_notify = package.loaded["pi-bridge.notify"]
	package.loaded["pi-bridge.notify"] = {
		once = function(key, level, msg) notices[key] = (notices[key] or 0) + 1 end,
		did_notify = function(key) return (notices[key] or 0) > 0 end,
	}
	local got = "UNSET"
	shell.ensure(function(err) got = err end)
	assert.are.equals("no driver for /bin/noshell", got)
	assert.is_true(notices["shell-degrade"] == 1, "degrade notice fires exactly once")
	-- follow-up: short-circuit, NO second notice, NO re-pick
	local got2 = "UNSET"
	shell.ensure(function(err) got2 = err end)
	assert.are.equals("daemon disabled", got2)
	assert.is_true(notices["shell-degrade"] == 1, "second ensure does NOT re-notify")
	package.loaded["pi-bridge.notify"] = real_notify  -- restore (after_each also cleans)
end)

-- PATTERN: complete_current receives err when degraded (the consumer contract).
-- complete_current(buf, cb) reads the buffer + cursor, then calls ensure→request.
-- In the degraded state ensure reports err synchronously → cb(err, nil, "").
it("complete_current receives (err, nil, '') when the daemon is degraded", function()
	pi.bridge = fake_bridge("/bin/noshell")   -- degrade first
	shell.ensure(function() end)               -- sets state.failed=true
	-- provide a fake buffer that looks like a `!` line (complete_current reads it)
	local buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "!git ch" })
	vim.api.nvim_set_current_buf(buf)
	local err, items, prefix = "UNSET", "UNSET", "UNSET"
	shell.complete_current(buf, function(e, it, pf) err, items, prefix = e, it, pf end)
	assert.is_truthy(err, "complete_current must forward the degrade err")
	assert.is_nil(items)
	-- prefix may be "" or nil — assert it is falsy/empty (no fake items leaked)
	assert.is_falsy(prefix)
	vim.api.nvim_buf_delete(buf, { force = true })
end)

-- PATTERN (smoke): the linear check() form.
local function fake_bridge(shell_path) /* ... */ end
local function make_fake_driver() /* ... */ end
-- ... set pi.bridge = fake_bridge("/bin/noshell"); ensure nil module for "noshell" ...
local got = "UNSET"
shell.ensure(function(err) got = err end)
check(got == "no driver for /bin/noshell", "ensure cb for unknown shell (got " .. tostring(got) .. ")")
local got2 = "UNSET"; shell.ensure(function(err) got2 = err end)
check(got2 == "daemon disabled", "follow-up short-circuits via failed (got " .. tostring(got2) .. ")")
```

### Integration Points

```yaml
TEST RUNNERS (no app integration — these are leaf tests):
  - plenary spec:  "nvim --headless --clean -u tests/minimal_init.lua -c 'lua require(\"plenary.busted\").run(\"tests/shell_unknown_shell_spec.lua\")'"
  - plenary-free:  "nvim --headless --clean -u NORC -c 'set rtp+=.' +\"luafile tests/shell_unknown_shell_smoke.lua\" +qa"
  - BOTH must be wrapped in `timeout 90` / `timeout 60` per AGENTS.md (hung-nvim safety net).

NO CHANGES TO:
  - lua/**, extension/**, plugin/**, ftplugin/**, doc/**, package.json, README.md
  - tests/minimal_init.lua (the new spec uses the existing bootstrap unchanged)
  - Any other tests/ file (the new pair is purely additive)
```

## Validation Loop

### Level 1: Syntax & Style (Immediate Feedback)

```bash
# Lua syntax check (instant, no nvim needed) — catches a missing `end`/comma fast.
luac -p tests/shell_unknown_shell_spec.lua   && echo "spec OK"
luac -p tests/shell_unknown_shell_smoke.lua  && echo "smoke OK"
# (luac not installed? `nvim --headless --clean -u NORC -c "luafile <file>" -c "qa"` loads
#  it — a syntax error prints + exits non-zero. Wrap in timeout 30.)

# Repo lint/format conventions (follow the existing shell_*_spec style; selene/stylua
# are the repo's tools — run only if configured):
# stylua --check tests/shell_unknown_shell_spec.lua tests/shell_unknown_shell_smoke.lua
# selene tests/shell_unknown_shell_spec.lua tests/shell_unknown_shell_smoke.lua

# Expected: zero errors. Fix before proceeding to Level 2.
```

### Level 2: The new tests themselves (the deliverable)

```bash
# The plenary spec — the formal Level-2 gate for this task.
timeout 90 nvim --headless --clean -u tests/minimal_init.lua \
  -c 'lua require("plenary.busted").run("tests/shell_unknown_shell_spec.lua")'
echo "spec_exit=$?"   # 0 = all cases pass

# The plenary-free smoke — instant Level-1 feedback, same matrix.
timeout 60 nvim --headless --clean -u NORC -c 'set rtp+=.' \
  +"luafile tests/shell_unknown_shell_smoke.lua" +qa
echo "smoke_exit=$?"   # 0 = SMOKE_PASS

# Expected: both exit 0. If a case fails, its `it` name / `FAIL:` msg names the
# invariant that regressed — read it, fix the TEST (not shell.lua), re-run.
```

### Level 3: Regression — confirm the new pair didn't disturb the siblings

```bash
# Run the THREE existing specs that also touch the degrade path, to prove the new
# pair's notify/reset cleanup doesn't pollute them (and vice versa).
timeout 90 nvim --headless --clean -u tests/minimal_init.lua \
  -c 'lua require("plenary.busted").run("tests/shell_spec.lua")'
timeout 90 nvim --headless --clean -u tests/minimal_init.lua \
  -c 'lua require("plenary.busted").run("tests/shell_ensure_spec.lua")'
timeout 90 nvim --headless --clean -u tests/minimal_init.lua \
  -c 'lua require("plenary.busted").run("tests/shell_notices_spec.lua")'

# Expected: all three still green. (If one regresses, the new spec leaked a global —
# check after_each restores pi.bridge/pi.descriptor/pi.config/package.loaded/notify state.)
```

### Level 4: N/A

No creative/domain-specific validation — this is a pure unit-test addition. Skip.

## Final Validation Checklist

### Technical Validation

- [ ] Level 1: `luac -p` (or headless luafile load) passes on both new files.
- [ ] Level 2: `shell_unknown_shell_spec.lua` runs green via plenary (exit 0).
- [ ] Level 2: `shell_unknown_shell_smoke.lua` prints `SMOKE_PASS` (exit 0).
- [ ] Level 3: `shell_spec.lua`, `shell_ensure_spec.lua`, `shell_notices_spec.lua`
      still green (no test-pollution regression).

### Feature Validation

- [ ] All 7 Success Criteria behaviors are asserted by named `it(...)` cases.
- [ ] The unknown-shell case (`/bin/noshell`, `/usr/local/bin/elvish`) asserts
      `pick_driver`→nil AND `ensure`→`failed=true`+cb+short-circuit+single-notice.
- [ ] The user-disabled-driver case asserts `pick_driver`→nil (flag checked BEFORE
      require) AND `ensure`→`failed=true`+cb+`.start` NEVER called.
- [ ] The consumer seam (`complete_current`) is shown to receive an `err`.
- [ ] The never-throws edges (nil bridge/descriptor/config/on_ready) are covered.

### Code Quality Validation

- [ ] Both files copy the sibling header comment block (task id, what it covers,
      the run command, the AGENTS.md heredoc warning).
- [ ] Both files are SELF-CONTAINED: own `fake_bridge` + `make_fake_driver`, no
      cross-file `require` of another test's helpers.
- [ ] `before_each`/`after_each` (spec) and `restore()` (smoke) reset EVERY
      swapped global + `package.loaded` + `shell.reset()` + notify dedup state.
- [ ] No spec-local table named `pending` (plenary shadow trap).
- [ ] Zero production-code edits (`git status` shows only the two new test files).

### Documentation & Deployment

- [ ] File header comments document the run command + the AGENTS.md ⛔ heredoc rule.
- [ ] No README/doc changes needed (test-only; the feature is already documented
      in `doc/pi-bridge-shell.txt` by P2.M3.T6.S4 — a sibling task, not this one).

---

## Anti-Patterns to Avoid

- ❌ Don't import helpers from `tests/shell_ensure_spec.lua` — specs are independent
  modules; copy the `fake_bridge`/`make_fake_driver` shapes (the sibling files all do).
- ❌ Don't modify `lua/pi-bridge/shell.lua` (or anything under lua/extension/plugin/
  ftplugin/doc) — the implementation is already correct; this is test-only.
- ❌ Don't pipe a heredoc into nvim's stdin to run the smoke (⛔ AGENTS.md HARD RULE —
  it hangs the session). Write the file, then `+"luafile <path>" +qa`.
- ❌ Don't fire a bare `nvim` without `timeout` (AGENTS.md: wrap risky commands).
- ❌ Don't skip `after_each`/`restore()` cleanup — a leaked `pi.bridge` or stale
  `package.loaded["pi-bridge.shell.<base>"]` will flake the sibling specs (Level 3).
- ❌ Don't assert implementation details that aren't contract (e.g. exact line numbers,
  internal local names) — assert OBSERVABLE behavior (cb args, failed-flag effect,
  notice count) so the test survives a refactor of shell.lua.
- ❌ Don't duplicate the parse-threshold (`_feed` N-garbage) degrade path — that's a
  DIFFERENT terminal-failed path already covered by `tests/shell_feed_spec.lua`.
  This task is the *no-driver / unknown-shell* path ONLY.

---

## Confidence Score: 9/10

**Why 9, not 10**: The implementation under test is already verified-green by three
existing specs, so the contract is unambiguous and the fakes are battle-tested. The
−1 is for the one residual unknown: the exact observable shape of `complete_current`'s
callback in the degraded state (`(err, nil, "")` vs `(err, nil, nil)`) — the spec
must assert `err` truthy + `items` nil and treat `prefix` as "falsy/empty" rather
than pinning a precise value, to avoid a brittle assertion against an under-documented
edge. A 60-second read of `shell.lua` `complete_current` (lines ~959+) at
implementation time resolves this definitively.

**One-pass success likelihood**: very high. This is a copy-conventions-then-assert
test task with a fully-working subject; the only failure mode is a brittle
assertion, which the "assert observable behavior, not implementation" guidance
above preemptively steers away from.