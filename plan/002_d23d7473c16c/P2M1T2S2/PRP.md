# PRP — P2.M1.T2.S2: shell.lua module state + resolve_shell + pick_driver + session_cwd

> **Plan mapping:** task `P2.M1.T2.S2` ("shell.lua module state + resolve_shell(prefer) + pick_driver(basename)
> + session_cwd()"). Second subtask of **P2.M1.T2** ("shell.lua daemon manager + fish spike") within the
> **Shell Completion for !/!! Bash Mode** epic (PRD §17). This is the **state + resolution layer** of
> `shell.lua`: it creates the module, declares the gen-guard supersession state (mirrors `completion.lua`),
> and implements the three PURE resolution helpers the spawn layer (S3) + request layer (S4) will call.
> **NO spawn yet** — S3 owns `ensure(on_ready)`; this task has zero `vim.uv.spawn` calls.
>
> **Sibling context:** P2.M1.T2.S1 (fish spike) runs in parallel and proves the live framed seam; it does NOT
> create `shell.lua`. P2.M1.T1.S4 (descriptor shell fields) is the **input contract** — it exports
> `bridge.get_shell_info()` which `resolve_shell` consumes. P2.M3.T6.S1 (`init.lua` `shell={}` config block) is
> NOT yet done — this task defaults `config.shell → {prefer="pi"}` when absent and NEVER throws on nil config.

---

## Goal

**Feature Goal**: Create `lua/pi-bridge/shell.lua` — the §17 completion-daemon manager's **state + resolution
foundation**. It owns a module-level `state` table (the gen-guard supersession scaffolding that MIRRORS
`completion.lua`'s two-layer design), a `[Mode A]` docstring header explaining the daemon lifecycle + framed
protocol + gen-guard + fresh-read invariants, and three PURE, never-throws helpers: `M.resolve_shell(prefer)`
(PRD §17.4 fallback chain → `(shell_path, source)`), `M.pick_driver(resolved_shell)` (basename → driver module
or nil-degrade, §17.4.2), and `M.session_cwd()` (fresh `server_info.cwd`/`descriptor.cwd` read). Plus
`M.reset()` (the state-clear seam S6's `teardown()` will extend). No subprocess is spawned in this task.

**Deliverable** (ONE new source file + 2 new test files — nothing else is touched):
- **`lua/pi-bridge/shell.lua`** — the module: `[Mode A]` header + `state` + `M.resolve_shell` +
  `M.pick_driver` + `M.session_cwd` + `M.reset`. ~120-170 lines. Zero `vim.uv.spawn`; zero `vim.notify`.
- **`tests/shell_smoke.lua`** — plenary-FREE smoke (mirrors `tests/notify_smoke.lua`): exercises the
  `resolve_shell` fallback matrix + `pick_driver` selection (with a fake driver injected into `package.loaded`)
  + `session_cwd` source priority. Prints `SMOKE_PASS`; `+\"luafile\" +qa`.
- **`tests/shell_spec.lua`** — plenary/busted spec (mirrors `tests/notify_spec.lua`): the same matrix as
  focused `it(...)` cases with field-by-field asserts + before/after_each save/restore.

**Success Definition**:
- `require("pi-bridge.shell")` loads and exposes `resolve_shell`, `pick_driver`, `session_cwd`, `reset` as
  functions (all never-throw on bad/nil args).
- `resolve_shell("pi")` returns the descriptor shell when `bridge.get_shell_info()` advertises one; else falls
  `→ $SHELL → /bin/bash`; `resolve_shell("shell")` → `$SHELL` or `/bin/bash`; `resolve_shell("bash")` →
  `/bin/bash`; an explicit path → itself. Each returns a `(shell, source)` pair with `source ∈ {"pi","$SHELL",
  "default","config"}`.
- `pick_driver("/usr/bin/fish")` returns the driver module when `pi-bridge.shell.fish` is loadable + has a
  `.start` function; returns `nil` for an unknown shell OR a user-disabled driver
  (`config.shell.drivers.<basename> == false`).
- `session_cwd()` returns `server_info.cwd` when present, else `descriptor.cwd`, else `nil`.
- `shell_smoke` prints `SMOKE_PASS` (exit 0); `shell_spec` is green (all cases pass, 0 fail/error).
- `completion_spec`, `bridge_handshake_spec`, `init_spec` stay green (S2 is purely additive — one new file).
- NO file under `extension/`, `doc/`, `ftplugin/`, `plugin/`, `completion.lua`, `bridge.lua`, `init.lua`, or
  `README.md` is modified. NO `shell/fish.lua` / `shell/zsh.lua` / `shell/bash.lua` is created (P2.M2/P2.M3).
  NO subprocess is spawned (S3).

## User Persona (if applicable)

**Target User**: the implementer of **P2.M1.T2.S3** (`ensure(on_ready)` — spawn via `vim.uv.spawn`) and
**P2.M1.T2.S4** (`request(line,cursor,after,cb)` — framed protocol + gen-guard bump). S3 calls
`M.resolve_shell(cfg.prefer)` + `M.pick_driver(resolved)` + `M.session_cwd()` to set up the spawn, then writes
`state.shell`/`state.driver`/`state.proc`. S4 bumps `state.gen` + sets `state.pending_cb`. Secondary consumer:
`:checkhealth pi-bridge` (P2.M3.T6.S2) reports `resolve_shell`'s `(shell, source)` + the resolved driver.

**Use Case**: at first `!` activation, `ensure()` needs ONE resolved shell (consistent with what pi EXECUTES),
its driver module (to call `.start`), and the session cwd (to pass to the driver so path completions match).
This task centralizes that resolution in three pure, tested, never-throws helpers.

**Pain Points Addressed**: without S2, S3's `ensure()` would inline shell resolution + driver lookup + cwd
reading + the gen-guard state in one tangled spawn function — untestable (a spawn can't be unit-tested without
a real shell) and duplicating §17.4's fallback logic. S2 separates the PURE resolution (trivially unit-testable
with injected fakes) from the IMPURE spawn (S3, integration-tested).

## Why

- **It is the explicit §17.16 step-22 foundation.** PRD §17.16 orders Phase 6: *(21) Spike → ✔ → (22)
  `shell.lua` daemon manager: resolution, spawn/teardown, framed protocol, gen-guard supersession*. S2 is the
  **resolution + state** half of step 22; S3-S6 are spawn/request/feed/teardown. Building spawn before
  resolution inverts the dependency (spawn CALLS resolution).
- **Mirrors a proven, exhaustive-tested convention.** `completion.lua` (the module this one is specified to
  "MIRROR" in PRD §17.5.2) already proves: (a) the `state = {...}` + `M.reset()` ownership shape, (b) the
  gen-guard supersession (`state.gen` monotonic int captured in the cb closure), (c) the "read bridge FRESH at
  call time" idiom, (d) the `[Mode A]` header documenting every invariant. S2 copies all four verbatim,
  adapted to the shell domain.
- **Consumes the S4 descriptor contract cleanly, ZERO file conflict.** S4 (P2.M1.T1.S4) owns `bridge.lua`'s
  `get_shell_info()`. S2 OWNS `shell.lua` (new) + its 2 tests. No overlap with any sibling: S1 owns the spike
  (`tests/shell_fish_spike.lua`); S3 owns `ensure`; S4 owns `request`; the drivers are P2.M2/P2.M3.
- **Pure functions = cheap, exhaustive tests.** `resolve_shell`/`pick_driver`/`session_cwd` have no subprocess,
  no timers, no sockets → they're tested with injected fakes (the `notify_spec`/`completion_spec` idiom),
  giving full §17.4 fallback-chain coverage WITHOUT a real shell. The live-subprocess risk was already retired
  by S1's spike; S2 doesn't re-prove it.

## What

**User-visible behavior**: none at runtime (no caller wires `shell.lua` into the plugin yet — that is
completion routing, P2.M2.T3). The observable artifact is the module's API + the test verdicts:

```bash
$ timeout 60 nvim --headless --clean -u NORC -c 'set rtp+=.' +"luafile tests/shell_smoke.lua" +qa
SMOKE_PASS
$ echo "exit=$?"
exit=0
```

**Technical requirements** (all in `lua/pi-bridge/shell.lua` unless noted):
- **`[Mode A]` docstring header** (mirror `completion.lua`'s L1-120 header style): explain (a) ROLE — the
  §17.5 persistent completion-daemon manager's RESOLUTION + STATE layer (does NOT spawn in S2; does NOT render
  `menu.lua`; does NOT accept `shell/accept.lua`); (b) DAEMON LIFECYCLE — a persistent child of nvim for the
  session lifetime (the fzf-tab / zsh-capture-completion pattern; per-keystroke spawn is a non-starter because
  rc+completion-library load costs 100ms-1s+); (c) FRAMED PROTOCOL — `__PIREQ__\t{json}` →
  `__PIRESP_START__\n{json}\n__PIRESP_END__\n` over the daemon's stdin/stdout, sentinels isolate prompt noise,
  daemon MUST emit `__PIRESP_END__` even on error/empty; (d) GEN-GUARD SUPERSESSION — mirrors
  `completion.lua`'s two-layer design (a monotonic `state.gen` captured in the response cb; a newer `request()`
  bumps gen → late stale response dropped at the guard); (e) FRESH READS — config + descriptor + bridge are
  read INSIDE each function (`require("pi-bridge")` lazy), never cached at module load (async handshake + test
  mocks); (f) SCOPE FENCE — S2 implements state + resolve_shell + pick_driver + session_cwd + reset ONLY;
  ensure/request/_feed/teardown are S3-S6 (forward-contract seams declared in `state`, not yet implemented).
- **`local state = {...}`** — EXACTLY the contract literal:
  `{ proc=nil, stdin=nil, stdout=nil, rx_buf="", gen=0, inflight=false, shell=nil, driver=nil, cwd=nil,
  pending_cb=nil, failed=false }`. Add a `---@class pi-bridge.ShellState` + per-field `---@field` annotations
  (mirror completion.lua's `pi-bridge.CompletionState`). Document each field's owner-task (proc/stdin/stdout
  = S3; rx_buf = S5; gen/inflight/pending_cb = S4; shell/driver = S3 via resolve/pick; cwd = session_cwd;
  failed = S3/§17.12 permanent-fail flag for health §17.15).
- **`M.resolve_shell(prefer)`** — PRD §17.4 fallback chain. Returns `(shell_path:string, source:string)`.
  `source ∈ {"pi","$SHELL","default","config"}` (first three match `descriptor.shellSource`'s union; `"config"`
  is the local label for an explicit-path `prefer`). Takes `prefer` as a PARAMETER (does not read config — the
  caller `ensure()` does; keeps it pure + unit-testable). Defaults `prefer or "pi"`. See Blueprint §resolve_shell.
- **`M.pick_driver(resolved_shell)`** (exported; deviation from skeleton's `local` — see Design Decision §1):
  `basename = resolved_shell:gsub(".*/","")` → if `config.shell.drivers[basename] == false` return nil
  (user-disabled → degrade, §17.4.2) → else `pcall(require, "pi-bridge.shell."..basename)` → return the module
  iff `type(drv.start)=="function"`, else nil (unknown shell → degrade, §17.6.4).
- **`M.session_cwd()`** — fresh read: `bridge.server_info.cwd` (live, post-handshake) → `descriptor.cwd`
  (env-var blob) → `nil`. Defensive type-checks; never throws.
- **`M.reset()`** — restore `state` to its initial literal (mirror `completion.lua`'s `M.reset()`). The
  forward-contract teardown seam (S6 `teardown()` prepends `uv.process_kill`+`pipe:close` THEN calls reset()).

### Success Criteria

- [ ] `lua/pi-bridge/shell.lua` exists with the `[Mode A]` header + `state` + `M.resolve_shell` +
      `M.pick_driver` + `M.session_cwd` + `M.reset`; exposes exactly those 4 functions on `M`.
- [ ] `resolve_shell` implements the full §17.4 matrix (pi/shell/bash/explicit-path + the pi fallback chain)
      and returns a `(shell, source)` pair; never throws on `nil`/`""`/non-string `prefer`.
- [ ] `pick_driver` returns the driver module for a loadable `pi-bridge.shell.<base>` with `.start`; returns
      `nil` for an unknown shell AND for a `config.shell.drivers.<base>==false` driver; never throws.
- [ ] `session_cwd` prefers `server_info.cwd`, falls back to `descriptor.cwd`, else `nil`; never throws.
- [ ] `shell_smoke` prints `SMOKE_PASS` (exit 0); `shell_spec` green (all cases pass, 0 fail/0 error).
- [ ] `completion_spec`, `bridge_handshake_spec`, `init_spec`, `notify_spec` stay green (additive change).
- [ ] NO edit to `extension/*`, `doc/*`, `ftplugin/*`, `plugin/*`, `completion.lua`, `bridge.lua`, `init.lua`,
      `notify.lua`, or `README.md`. NO `shell/*.lua` driver created. NO `vim.uv.spawn` / `vim.notify` in S2.

## All Needed Context

### Context Completeness Check

_Passes "No Prior Knowledge":_ an implementer who has never seen this repo gets (a) the verbatim reference
implementation of `shell.lua` (all 5 functions + the header + state), (b) the exact `get_shell_info()` /
`descriptor` / `config` INPUT contracts (with the field shapes + nil-vs-"" distinction), (c) the module to
mirror (`completion.lua` — its header/state/reset/gen-guard/fresh-read patterns, with line anchors), (d) the
two test files to mirror (`notify_smoke.lua` + `notify_spec.lua`) with the exact fake-bridge/fake-driver
injection recipes, (e) the validation commands (verified shape), and (f) the scope fence (what NOT to build).
The one genuine judgment call (drivers-disabled check: `pick_driver` vs `resolve_shell`) is decided in favor of
`pick_driver` with rationale in Design Decision §2 + Anti-Patterns.

### Documentation & References

```yaml
# MUST READ — the spec (reproduced in this PRP's <selected_prd_content>)
- docfile: PRD.md
  why: "§17.4 gives the prefer-contract table + the fallback chain (descriptor.shell → $SHELL → /bin/bash). §17.4.2 gives driver selection (basename → module; user-disable via config.shell.drivers.<base>=false). §17.5.2 gives the shell.lua reference skeleton (the state table + pick_driver + the gen-guard mirror note). §17.11 gives the config block shape (not yet in init.lua — P2.M3.T6.S1; S2 defaults it)."
  section: "h3.33 (§17.4 + §17.4.1), h4.1 (§17.4.2), h3.34 (§17.5 + §17.5.2 skeleton), h4.4 (§17.5.2 skeleton), h3.40 (§17.11 config)"
  critical: "The fallback chain is EXACTLY: prefer=='pi' → descriptor.shell (else fall through) → $SHELL → /bin/bash. descriptor.shell is accessed via bridge.get_shell_info() (S4) which returns nil (NOT '') when unresolved — the nil MUST engage the fallback (a '' would be a bogus path). source strings align with descriptor.shellSource union 'pi'|'$SHELL'|'default' + a local 'config' for explicit-path prefer."

# MUST READ — the module to MIRROR (PRD §17.5.2 says shell.lua "MIRRORS completion.lua's two-layer design")
- file: lua/pi-bridge/completion.lua
  why: "(1) L1-120 [Mode A] header (the docstring style + invariant-documentation pattern to copy). (2) L248-265 the pi-bridge.CompletionState class + `local state = {...}` literal (the state-ownership shape). (3) L454-468 the gen-guard (state.gen bump+capture+guard — shell.lua's state.gen/pending_cb are the scaffolding for this, implemented in S4). (4) L602-611 M.reset() (the cleanup seam to mirror). (5) the 'Read bridge FRESH at call time' header note (the lazy-require idiom)."
  pattern: "`local state = { ... }` singleton + `---@class`/`---@field` annotations + `M.reset()` restoring initial + `require(\"pi-bridge\")` INSIDE functions (not at module top)."
  gotcha: "completion.lua's state has `inflight_id` (a bridge.request STRING id); shell.lua's state has `inflight` (a BOOLEAN) + `pending_cb` (the gen-guarded cb) per the §17.5.2 skeleton. Do NOT copy inflight_id. shell.lua has no bridge.cancel (no cancel wire method for the daemon — it's a local subprocess)."

# MUST READ — the INPUT contract (produced by P2.M1.T1.S4; its PRP is a contract)
- file: plan/002_d23d7473c16c/P2M1T1S4/PRP.md
  why: "defines `bridge.get_shell_info() -> {shell, shellSource, shellPath} | nil` (fresh table; server_info→descriptor→nil priority; never throws). resolve_shell consumes `si.shell`. ALSO documents the `pick_str` defensive extractor + the nil-not-'' advisory contract."
  critical: "get_shell_info() returns nil when NEITHER server_info nor descriptor is populated. `si.shell` is nil (NOT '') when unresolved. shell.lua MUST treat nil as 'run the fallback chain'. Bridge may be nil pre-handshake → guard `if br and type(br.get_shell_info)=='function'`."

# MUST READ — the descriptor shape (init.lua; the OTHER input)
- file: lua/pi-bridge/init.lua
  why: "L98-110 the pi-bridge.BridgeDescriptor class (cwd is REQUIRED string; shell/shellSource/shellPath are OPTIONAL §17.10 fields). L141 M.descriptor set by activate() from the PI_NVIM_BRIDGE env var. L36-60 M.config (nil until setup(); the shell={} block is P2.M3.T6.S1 — NOT yet present)."
  pattern: "`require(\"pi-bridge\").descriptor` is the parsed env-var blob; `.cwd` is the session cwd shell.lua's session_cwd() falls back to."
  gotcha: "M.config may be nil (user never called setup(), or this is a minimal test init). shell.lua MUST default config.shell → {prefer='pi'} and NEVER index a nil config. resolve_shell takes `prefer` as a PARAM (doesn't read config); pick_driver reads `(pi.config and pi.config.shell and pi.config.shell.drivers)` defensively."

# MUST READ — the smoke + spec convention files to MIRROR (test shape + injection idiom)
- file: tests/notify_smoke.lua
  why: "the plenary-FREE `check`/`fails`/`SMOKE_PASS` footer + the `+\"luafile\" +qa` run header + the rtp-append bootstrap. shell_smoke.lua is the same shape pointed at shell.lua's pure functions."
  pattern: "header doc-comment with the run command; `local fails=0; local function check(cond,msg)...`; exercise the API; footer `if fails>0 then stderr; vim.cmd('cquit 1') end; io.stdout:write('SMOKE_PASS\\n')`."
- file: tests/notify_spec.lua
  why: "the plenary/busted `describe`/`it`/`before_each`/`after_each` shape + the save/restore-global idiom (vim.notify swap). shell_spec.lua mirrors it (swap vim.env.SHELL + inject pi.bridge/pi.descriptor/package.loaded in before_each, restore in after_each)."
- file: tests/completion_spec.lua
  why: "L18 `if pi.config==nil then pi.setup({}) end` (self-sufficient bootstrap); L79-101 the `reset()` that nils `pi.bridge` + the `pi.bridge = fake` injection idiom. shell_spec copies BOTH."

# MUST READ — local research notes (verified facts + design decisions + the verbatim reference logic)
- docfile: plan/002_d23d7473c16c/P2M1T2S2/research/notes.md
  why: "§1 the INPUT contracts (get_shell_info/descriptor/config/SHELL). §2 the completion.lua patterns to mirror (state/gen-guard/reset/fresh-read, with line anchors). §3 pick_driver (skeleton + drivers-disabled + the export decision). §4 resolve_shell (the §17.4 table + source strings + reference logic). §5 session_cwd (reference logic). §6 the 7 locked design decisions. §7 the scope fence. §8 the test strategy + injection recipes. §9 the 10 gotchas."

# SUPPORTING — architecture research (confirms the §17.4 chain + the §17.5.2 skeleton + the gen-guard mirror)
- docfile: plan/002_d23d7473c16c/architecture/research-prd-section-17.md
  why: "§17.4 (L78-88) the prefer table + fallback chain. §17.4.2 (L103-105) driver selection + user-disable. §17.5.2 (L131-160) the shell.lua reference skeleton (the state literal + pick_driver + the gen-guard mirror note). Confirms source strings + the 'one in-flight request at a time' invariant."
  section: "§17.4, §17.4.2, §17.5.2"
- docfile: plan/002_d23d7473c16c/architecture/research-plugin-side.md
  why: "§'The gen-guard supersession pattern' (L99-106) — the load-bearing correctness seam shell.lua's state.gen/pending_cb scaffold. §'do_refresh' (L86-99) — the 'read bridge FRESH at call time' idiom. Confirms the mirror."
```

### Current Codebase tree (relevant slice)

```bash
lua/pi-bridge/
├── completion.lua     # READ-ONLY — the module to MIRROR (state/gen-guard/reset/fresh-read/header style)
├── bridge.lua         # READ-ONLY — exports M.get_shell_info() (S4) + M.server_info.cwd (consumed by session_cwd)
├── init.lua           # READ-ONLY — M.descriptor (cwd + optional shell*) + M.config (nil until setup())
├── notify.lua         # READ-ONLY — the dedup mechanism S2 references in its header (does NOT call in S2)
└── (shell.lua)        # DOES NOT EXIST YET — ← this task CREATES it
lua/pi-bridge/shell/   # DOES NOT EXIST YET — P2.M2.T4 (fish) / P2.M3.T5 (zsh/bash) create the drivers;
                       #   pick_driver pcall-requires them → nil (degrade) until then. Tests inject fakes.
tests/
├── notify_smoke.lua   # READ-ONLY — the smoke convention to MIRROR
├── notify_spec.lua    # READ-ONLY — the spec convention to MIRROR
├── completion_spec.lua# READ-ONLY — the pi.bridge=fake + self-sufficient-setup injection idiom (L18, L79-101)
└── (shell_smoke.lua, shell_spec.lua)   # ← this task CREATES both
```

### Desired Codebase tree with files to be added

```bash
lua/pi-bridge/shell.lua        # NEW — the module (state + resolve_shell + pick_driver + session_cwd + reset). ~120-170 lines.
tests/shell_smoke.lua          # NEW — plenary-FREE smoke (the resolve/pick/cwd matrix). Prints SMOKE_PASS.
tests/shell_spec.lua           # NEW — plenary/busted spec (the same matrix as it(...) cases).
# (NO other file is created or modified.)
```

### Known Gotchas of our codebase & Library Quirks

```lua
-- CRITICAL (AGENTS.md HARD RULE): run tests via `+"luafile tests/shell_smoke.lua" +qa` (a FILE on disk).
-- NEVER pipe a heredoc into nvim's stdin (`nvim ... +"luafile /dev/stdin" +qa <<EOF` HANGS the session —
-- ~10 killed sessions in this repo). Wrap every nvim in `timeout` (a hung headless nvim blocks the turn).

-- GOTCHA #1 — LAZY `require("pi-bridge")` INSIDE functions, NEVER at module top.
-- The handshake is ASYNC; at first-require `pi.bridge` is still nil; tests swap in a fake bridge AFTER
-- require. Caching breaks both. Also avoids a circular-load hazard (init.lua does not require shell.lua at
-- top). Mirrors completion.lua's header note + bridge.lua's lazy require at L333/L559. (research §9 G1.)

-- GOTCHA #2 — `config` / `config.shell` may be NIL (the shell={} block is P2.M3.T6.S1, NOT yet present).
-- Defensive reads: `(pi.config and pi.config.shell) or {}`. resolve_shell takes `prefer` as a PARAM (so it
-- never reads config); pick_driver reads `(pi.config and pi.config.shell and pi.config.shell.drivers)`. NEVER
-- index a nil config. (research §9 G2.)

-- GOTCHA #3 — `bridge` may be NIL pre-handshake. Guard `if br and type(br.get_shell_info)=="function"`.
-- Fall back to `pi.descriptor.shell` (resolve) / `pi.descriptor.cwd` (session_cwd) directly. (research §9 G3.)

-- GOTCHA #4 — `string.gsub` returns 2 VALUES (str, count).
-- `local base = s:gsub(".*/","")` adjusts to 1 (the string) — SAFE in assignment. But NEVER use a bare
-- `:gsub(...)` as a function arg or concat operand (Lua would pass 2 values). Assign to a local FIRST, then
-- concat — exactly as the §17.5.2 skeleton does. (research §9 G4.)

-- GOTCHA #5 — TAB indentation throughout (verified completion.lua/bridge.lua/init.lua). Match tabs on every
-- new line. The state literal + all function bodies use tabs.

-- GOTCHA #6 — no lua linter/formatter (no luacheck/selene/stylua/.luarc at root). The ONLY "type" surface is
-- the luaemmy `---@class`/`---@field` annotations (lua-language-server, NOT runtime-enforced). Validation =
-- the smoke + spec. There is no `ruff`/`mypy`/`stylua --check` equivalent. (research §9 G6.)

-- GOTCHA #7 — `M.pick_driver` is EXPORTED (deviation from the §17.5.2 skeleton's `local`).
-- The contract's MOCKING requires "Test ... pick_driver selection." A `local` is unreachable from tests.
-- completion.lua exports ALL testable units on M (is_attachment_context, compute_debounce). Exporting
-- pick_driver matches the repo's testing idiom. (research §6.1 / §9 G9.)

-- GOTCHA #8 — pick_driver's require path is `pi-bridge.shell.<basename>` (dotted → lua/pi-bridge/shell/<base>.lua).
-- That dir/file does NOT exist in S2 → pcall returns false → nil (degrade). Tests inject
-- `package.loaded["pi-bridge.shell.fish"] = { start = function() end }` to exercise the present-driver path
-- (require checks package.loaded FIRST). Remove with `package.loaded[...] = nil` in after_each. (research §9 G8.)

-- GOTCHA #9 — resolve_shell is PURE (no config read, no state mutation). `prefer` is a param.
-- This makes it directly unit-testable AND keeps §17.4 resolution decoupled from config-wiring (ensure() in
-- S3 reads config.shell.prefer and passes it). Do NOT make resolve_shell read config. (research §6.6 / §9 G10.)

-- GOTCHA #10 — `source` return aligns with descriptor.shellSource union ("pi"|"$SHELL"|"default") + "config".
-- "pi" = from descriptor.shell; "$SHELL" = from vim.env.SHELL; "default" = the /bin/bash fallback; "config" =
-- explicit-path prefer (local-only label; the union has no "explicit" member — documented). (research §4b.)

-- GOTCHA #11 — the drivers-disabled check belongs in pick_driver, NOT resolve_shell.
-- §17.4.2 is about DRIVER selection (disabling = no completion = degrade); pick_driver IS driver selection.
-- resolve_shell stays a pure §17.4 shell resolution (the shell is what pi EXECUTES — you can't change it by
-- disabling a driver). The item bullet lists it under resolve_shell, but correct layering puts it in
-- pick_driver. Honor: `cfg[base] == false` → nil. (research §6.2 / Design Decision §2.)

-- GOTCHA #12 — S2 has ZERO vim.uv.spawn + ZERO vim.notify.
-- ensure() (spawn) is S3; the §17.4.3/§17.9/§17.6.4 notices are P2.M2.T3.S4. shell.lua in S2 references
-- notify.lua + the daemon lifecycle in its HEADER only (documentation), but calls neither. (research §7.)
```

## Implementation Blueprint

### Design Decisions (READ FIRST)

**1. `M.pick_driver` is exported (not `local` as in the §17.5.2 skeleton).** The contract's MOCKING requires
"Test ... pick_driver selection." A `local` is unreachable from tests. `completion.lua` exports all testable
units on `M` (`M.is_attachment_context`, `M.compute_debounce`). Promoting `pick_driver` to `M.pick_driver`
matches the repo's testing idiom and costs nothing (it's still the only caller's helper; S3's `ensure()` calls
`M.pick_driver` or the local — either works, but the export enables the spec). Documented deviation.

**2. The drivers-disabled check lives in `pick_driver`, not `resolve_shell`.** PRD §17.4.2 ("The user may
disable a driver explicitly: `setup({ shell = { drivers = { bash = false } } })`") is about DRIVER selection —
disabling a driver means NO completion (degrade to a plain buffer), NOT a different shell. The shell is what
pi EXECUTES; you cannot change it by disabling a completion driver. `pick_driver` IS driver selection, so the
check belongs there. `resolve_shell` stays a pure §17.4 resolution. The item-description bullet lists the check
under `resolve_shell`, but placing it in `pick_driver` honors the intent (drivers ARE checked) at the correct
layer. See Anti-Patterns. (`resolve_shell` returning a different shell when its driver is disabled would VIOLATE
the §17.4 consistency contract — completion would use a different shell than execution.)

**3. `M.reset()` is included** (mirrors `completion.lua` L602). It's the forward-contract teardown seam (S6
`teardown()` prepends `uv.process_kill`+`pipe:close` then calls `reset()`) + test hygiene. The S2 functions are
pure (don't mutate `state`), so `reset()` isn't strictly required for S2 correctness, but state-ownership
implies a reset seam and the mirrored module (`completion.lua`) has one. Low cost, consistent, forward-looking.

**4. `state.failed` + `state.pending_cb` are declared** (contract state literal). Purpose (forward-contract):
`failed=true` is set by S3's `ensure()` on permanent spawn failure (§17.12) so it doesn't retry endlessly + the
health check (§17.15) reports it; `pending_cb` is the gen-guarded cb S4's `request()` assigns. S2 only
initializes them (`false` / `nil`) + documents the seam. This is scaffolding the skeleton's `request()` will use.

**5. `resolve_shell(prefer)` takes `prefer` as a PARAMETER** (does not read config). Keeps it pure + directly
unit-testable (pass prefer, assert output). The caller `ensure()` (S3) reads `config.shell.prefer` and passes
it. This is the `coords.lua`/`notify.lua` pure-function idiom.

### Data models and structure

```lua
---@class pi-bridge.ShellState   -- (luaemmy annotations; NOT runtime-enforced — there is no lua linter)
---@field proc        userdata?  luv process handle (S3 ensure). nil until spawn succeeds.
---@field stdin       userdata?  luv pipe → daemon stdin (S3). nil until spawn.
---@field stdout      userdata?  luv pipe ← daemon stdout (S3). nil until spawn.
---@field rx_buf      string     accumulating stdout buffer (S5 _feed slices sentinel pairs). "" when idle.
---@field gen         integer    Monotonic supersession guard (mirrors completion.lua; bumped in S4 request()).
---@field inflight    boolean    True iff a framed request is awaiting __PIRESP_END__ (S4).
---@field shell       string?    The resolved shell path (set by S3 ensure via resolve_shell).
---@field driver      table?     The resolved driver module (set by S3 ensure via pick_driver; has .start).
---@field cwd         string?    The session cwd at spawn (set by S3 ensure via session_cwd).
---@field pending_cb  fun(items:table?, prefix:string?)?  The gen-guarded response cb (set by S4 request()).
---@field failed      boolean    True after a permanent spawn failure (S3/§17.12) — ensure() won't retry; health (§17.15) reports it.
---@type pi-bridge.ShellState
local state = {
	proc = nil, stdin = nil, stdout = nil, rx_buf = "",
	gen = 0, inflight = false, shell = nil, driver = nil,
	cwd = nil, pending_cb = nil, failed = false,
}
```
No other runtime types. `M.resolve_shell` returns `(string, string)`; `M.pick_driver` returns `table|nil`;
`M.session_cwd` returns `string|nil`.

### Implementation Tasks (ordered by dependencies)

```yaml
Task 1: CREATE lua/pi-bridge/shell.lua — [Mode A] header + state + reset
  - WRITE the [Mode A] docstring header (mirror completion.lua L1-120 style): ROLE (the §17.5 daemon manager's
    RESOLUTION + STATE layer; does NOT spawn in S2, does NOT render menu.lua, does NOT accept shell/accept.lua);
    DAEMON LIFECYCLE (persistent child of nvim for the session; rc+completion load costs 100ms-1s+ → per-keystroke
    spawn is a non-starter; the fzf-tab/zsh-capture-completion pattern); FRAMED PROTOCOL
    (__PIREQ__\t{json} → __PIRESP_START__\n{json}\n__PIRESP_END__\n; sentinels isolate prompt noise; daemon MUST
    emit __PIRESP_END__ even on error/empty); GEN-GUARD SUPERSESSION (mirrors completion.lua's two-layer design;
    monotonic state.gen captured in the cb; a newer request() bumps gen → stale dropped; one in-flight at a time);
    FRESH READS (require("pi-bridge") INSIDE functions; async handshake + test mocks); SCOPE FENCE (S2 = state +
    resolve_shell + pick_driver + session_cwd + reset ONLY; ensure/request/_feed/teardown = S3-S6).
  - DECLARE `local M = {}`, `local uv = vim.uv` (forward-contract; unused in S2 but matches the §17.5.2 skeleton
    + S3 uses it — keep it so S3's diff is minimal; OR omit if you prefer no-unused-locals; the skeleton has it).
  - DECLARE the `pi-bridge.ShellState` class + the `local state = {...}` literal (EXACTLY the contract fields;
    see Data models above). TAB indentation.
  - DECLARE a `local function dbg(msg) ... end` stub (mirror completion.lua L235; a vim.schedule_wrap'd
    vim.notify or a no-op — forward-contract for S4/S5 tracing). Keep minimal.
  - DO NOT: add vim.uv.spawn / vim.notify / require("pi-bridge.notify") at module top (S2 calls neither). Do NOT
    create shell/*.lua. Do NOT edit any other file.

Task 2: APPEND lua/pi-bridge/shell.lua — the FRESH-read helpers (local descriptor_shell) + M.resolve_shell
  - DEFINE `local function descriptor_shell()` (the §17.4 "pi" first hop; FRESH read; nil when unresolved):
    `local pi = require("pi-bridge")` → `local br = pi.bridge` → if `br and type(br.get_shell_info)=="function"`
    then `local si = br.get_shell_info()` → if `type(si)=="table" and type(si.shell)=="string" and si.shell~="" `
    return `si.shell` → else fall to `pi.descriptor` → if `type(desc)=="table" and type(desc.shell)=="string"
    and desc.shell~="" ` return `desc.shell` → else `nil`. See Reference implementation block A.
  - DEFINE `function M.resolve_shell(prefer)` (the §17.4 fallback chain; returns (shell, source)):
    `prefer = prefer or "pi"` → if `type(prefer)=="string" and prefer~="" and prefer~="pi" and prefer~="shell"
    and prefer~="bash"` then `return prefer, "config"` (explicit path, §17.4 "/abs/path" row) → if `prefer=="pi"`
    then `local ds = descriptor_shell(); if ds then return ds, "pi" end` (fall through) → if `prefer=="pi" or
    prefer=="shell"` then `local env = vim.env.SHELL; if type(env)=="string" and env~="" then return env,
    "$SHELL" end; return "/bin/bash", "default"` → if `prefer=="bash"` then `return "/bin/bash", "default"` →
    fallback `return "/bin/bash", "default"`. See block B.
  - DO NOT: read config inside resolve_shell (prefer is a param — GOTCHA #9). Do NOT mutate state (pure).

Task 3: APPEND lua/pi-bridge/shell.lua — M.pick_driver (basename → driver module; exported)
  - DEFINE `function M.pick_driver(resolved_shell)`:
    `if type(resolved_shell)~="string" or resolved_shell=="" then return nil end` → `local base =
    resolved_shell:gsub(".*/", "")` (basename; assignment adjusts gsub's 2 returns to 1 — GOTCHA #4) →
    `if base=="" then return nil end` → user-disabled check: `local pi = require("pi-bridge"); local drv_cfg =
    (pi.config and pi.config.shell and pi.config.shell.drivers) or nil; if type(drv_cfg)=="table" and
    drv_cfg[base]==false then return nil end` (§17.4.2) → `local ok, drv = pcall(require,
    "pi-bridge.shell."..base)` → `if ok and type(drv)=="table" and type(drv.start)=="function" then return drv
    end` → `return nil` (unknown / no .start → degrade, §17.6.4). See block C.
  - DO NOT: put the drivers-disabled check in resolve_shell (Design Decision §2). Do NOT validate the path
    exists (S3's driver.start handles missing-binary errors). Do NOT keep `local` (exported — GOTCHA #7).

Task 4: APPEND lua/pi-bridge/shell.lua — M.session_cwd + M.reset + return M
  - DEFINE `function M.session_cwd()` (fresh cwd read): `local pi = require("pi-bridge"); local br = pi.bridge`
    → if `br and type(br.server_info)=="table" and type(br.server_info.cwd)=="string" and
    br.server_info.cwd~=""` return `br.server_info.cwd` → else `local desc = pi.descriptor; if type(desc)=="table"
    and type(desc.cwd)=="string" and desc.cwd~=""` return `desc.cwd` → else `nil`. See block D.
  - DEFINE `function M.reset()` (restore state to its initial literal; mirror completion.lua M.reset): set
    every field back: `state.proc=nil; state.stdin=nil; state.stdout=nil; state.rx_buf=""; state.gen=0;
    state.inflight=false; state.shell=nil; state.driver=nil; state.cwd=nil; state.pending_cb=nil; state.failed=
    false`. Add a one-line doc note: "S6 teardown() prepends uv.process_kill+pipe:close THEN calls reset()."
    See block E.
  - END the file with `return M`.
  - DO NOT: add kill/close logic to reset (that's S6 teardown — reset is state-clear ONLY). Do NOT call
    bridge.cancel (shell.lua has no cancel wire — the daemon is a local subprocess).

Task 5: CREATE tests/shell_smoke.lua — plenary-FREE smoke (mirror notify_smoke.lua)
  - WRITE the header doc-comment with the run command: `timeout 60 nvim --headless --clean -u NORC -c 'set rtp+=.'
    +"luafile tests/shell_smoke.lua" +qa`. Note the AGENTS.md HARD RULE (file on disk; never heredoc-to-stdin).
  - BOOTSTRAP: `local me = debug.getinfo(1,"S").source:sub(2); local root = vim.fn.fnamemodify(me, ":h:h");
    vim.opt.runtimepath:append(root)`; `local pi = require("pi-bridge"); if pi.config==nil then pi.setup({}) end`.
  - DEFINE `local fails=0; local function check(cond,msg) if not cond then io.stderr:write("FAIL: "..msg.."\n");
    fails=fails+1 end end`.
  - CASES (each a check): see Validation Loop §Level-2-smoke for the full matrix (resolve_shell pi/shell/bash/
    explicit/nil + the pi fallback chain; pick_driver present/disabled/unknown; session_cwd priority; never-throws).
    Use a `local function fake_bridge(shell)` returning `{get_shell_info=function() return shell and {shell=shell}
    or nil end, server_info = ...}`. Inject `pi.bridge = fake_bridge(...)` + `pi.descriptor = {...}` per case;
    restore `pi.bridge=nil; pi.descriptor=nil` between cases. Stub `vim.env.SHELL` (save orig; set/nil; restore).
    Inject `package.loaded["pi-bridge.shell.fish"]={start=function()end}` for the present-driver case; nil it after.
  - FOOTER: `if fails>0 then io.stderr:write(fails.." check(s) failed\n"); vim.cmd("cquit 1") end;
    io.stdout:write("SMOKE_PASS\n")`.
  - DO NOT: spawn any subprocess (S2 is pure). Do NOT depend on a real shell binary. Do NOT test ensure/request.

Task 6: CREATE tests/shell_spec.lua — plenary/busted spec (mirror notify_spec.lua)
  - WRITE the header doc-comment with the run command (minimal_init + plenary.busted.run).
  - BOOTSTRAP: `local pi = require("pi-bridge"); if pi.config==nil then pi.setup({}) end`; `local shell =
    require("pi-bridge.shell")`.
  - before_each: save `orig_shell = vim.env.SHELL`, `orig_bridge = pi.bridge`, `orig_desc = pi.descriptor`,
    `orig_drivers = ...`; nil `pi.bridge`, `pi.descriptor`. after_each: restore all + `package.loaded
    ["pi-bridge.shell.fish"]=nil` + `shell.reset()`.
  - CASES: the same matrix as the smoke, as `it(...)` with `assert.are.equals`/`assert.is_nil`/`assert.is_same`.
    Group under `describe("pi-bridge.shell resolve_shell (P2.M1.T2.S2)", ...)`, `describe("...pick_driver...")`,
    `describe("...session_cwd...")`, `describe("...reset + never-throws...")`. ~14-18 cases.
  - DO NOT: spawn subprocess. Do NOT test ensure/request/_feed/teardown (S3-S6). Do NOT use spec-local `pending`
    (shadows plenary's skip fn — research-plugin-side.md §9).
```

### Reference implementation

```lua
-- === Block A: the descriptor_shell helper (shell.lua, before M.resolve_shell) ===
--- §17.4 "pi" first hop (FRESH read): the resolved execution shell pi advertises. Returns the shell path
--- or `nil` when unresolved (older bridge / pre-handshake). Prefers `bridge.get_shell_info()` (which merges
--- server_info→descriptor, P2.M1.T1.S4) then falls back to `pi.descriptor.shell` directly (covers the
--- bridge==nil pre-handshake window). LAZY require (async handshake + test mocks; mirrors completion.lua).
---@return string|nil
local function descriptor_shell()
	local pi = require("pi-bridge")
	local br = pi.bridge
	if br and type(br.get_shell_info) == "function" then
		local si = br.get_shell_info()
		if type(si) == "table" and type(si.shell) == "string" and si.shell ~= "" then
			return si.shell
		end
	end
	local desc = pi.descriptor
	if type(desc) == "table" and type(desc.shell) == "string" and desc.shell ~= "" then
		return desc.shell
	end
	return nil
end
```

```lua
-- === Block B: M.resolve_shell (the §17.4 fallback chain) ===
--- Resolve ONE shell for the session per PRD §17.4. Takes `prefer` as a PARAMETER (the caller `ensure()` in
--- S3 reads `config.shell.prefer` and passes it — keeping this PURE + directly unit-testable). Returns
--- `(shell_path, source)`:
---   prefer=="pi"    → descriptor.shell ("pi") else fall through → $SHELL ("$SHELL") → /bin/bash ("default")
---   prefer=="shell" → $SHELL ("$SHELL") else /bin/bash ("default")
---   prefer=="bash"  → /bin/bash ("default")
---   prefer=<path>   → that path ("config")           (§17.4 "/abs/path" row)
--- `source` aligns with descriptor.shellSource's union ("pi"|"$SHELL"|"default") + a local "config" label
--- for explicit-path prefer (used by the §17.4.3 notice / health check / dbg). NEVER throws (defensive
--- type-checks; nil/""/non-string prefer → the safe "/bin/bash","default" default). Does NOT mutate state.
---@param prefer string? "pi" (default) | "shell" | "bash" | "/abs/path"
---@return string shell_path
---@return string source
function M.resolve_shell(prefer)
	prefer = prefer or "pi"
	-- explicit path (NOT one of the three keywords) → verbatim (§17.4 "/abs/path" row)
	if type(prefer) == "string" and prefer ~= ""
		and prefer ~= "pi" and prefer ~= "shell" and prefer ~= "bash" then
		return prefer, "config"
	end
	if prefer == "pi" then
		local ds = descriptor_shell()
		if ds then return ds, "pi" end            -- descriptor.shell (always consistent w/ execution)
		-- descriptor omitted shell → fall through to $SHELL → /bin/bash
	end
	if prefer == "pi" or prefer == "shell" then
		local env = vim.env.SHELL
		if type(env) == "string" and env ~= "" then return env, "$SHELL" end
		return "/bin/bash", "default"
	end
	if prefer == "bash" then
		return "/bin/bash", "default"
	end
	return "/bin/bash", "default"                 -- unknown/non-string prefer → safe default
end
```

```lua
-- === Block C: M.pick_driver (basename → driver module; EXPORTED for testability) ===
--- Select the per-shell driver module (PRD §17.4.2) by the resolved shell's BASENAME: `"/bin/zsh"`→
--- `pi-bridge.shell.zsh`, `"/usr/bin/fish"`→`pi-bridge.shell.fish`. Returns the module iff it is loadable
--- AND exposes a `.start` function (the `start(opts, on_ready)` seam, §17.6); else `nil` (unknown shell →
--- silent no-op degrade, §17.6.4). A user-disabled driver (`config.shell.drivers.<basename> == false`)
--- ALSO returns nil — disabling a driver means NO completion (degrade to a plain buffer), NOT a different
--- shell (the shell is what pi EXECUTES; you cannot change it by disabling a completion driver). NEVER throws.
---@param resolved_shell string? The resolved shell path (from M.resolve_shell).
---@return table|nil drv The driver module (has `.start`), or nil to degrade.
function M.pick_driver(resolved_shell)
	if type(resolved_shell) ~= "string" or resolved_shell == "" then return nil end
	local base = resolved_shell:gsub(".*/", "")    -- basename ("/bin/zsh"→"zsh"); gsub returns 2, assignment→1
	if base == "" then return nil end
	-- user-disabled driver? (§17.4.2: setup({ shell = { drivers = { bash = false } } }))
	local pi = require("pi-bridge")
	local drv_cfg = (pi.config and pi.config.shell and pi.config.shell.drivers) or nil
	if type(drv_cfg) == "table" and drv_cfg[base] == false then return nil end
	local ok, drv = pcall(require, "pi-bridge.shell." .. base)
	if ok and type(drv) == "table" and type(drv.start) == "function" then return drv end
	return nil                                     -- unknown shell / no .start → degrade (§17.6.4)
end
```

```lua
-- === Block D: M.session_cwd (fresh cwd read) ===
--- The session cwd for the daemon (PRD §17.5.2 "cwd tracking"). FRESH read: `bridge.server_info.cwd` (live,
--- post-handshake) → `pi.descriptor.cwd` (the PI_NVIM_BRIDGE env-var blob, available from activate()) → nil.
--- Drivers use this as the spawn cwd (S3 ensure passes it to driver.start); a driver may re-`cd` over the
--- framed channel if it changed since spawn. `nil` is acceptable (a driver may default to the daemon's own
--- cwd). NEVER throws (defensive reads). LAZY require (async handshake + test mocks).
---@return string|nil
function M.session_cwd()
	local pi = require("pi-bridge")
	local br = pi.bridge
	if br and type(br.server_info) == "table"
		and type(br.server_info.cwd) == "string" and br.server_info.cwd ~= "" then
		return br.server_info.cwd
	end
	local desc = pi.descriptor
	if type(desc) == "table" and type(desc.cwd) == "string" and desc.cwd ~= "" then
		return desc.cwd
	end
	return nil
end
```

```lua
-- === Block E: M.reset + return M (the state-clear seam) ===
--- Restore `state` to its initial literal (mirrors completion.lua's M.reset). The forward-contract TEARDOWN
--- seam: S6's `teardown()` prepends `uv.process_kill(proc, "sigkill")` + `:close()` on each pipe, THEN calls
--- reset(). Also used by tests for state isolation. shell.lua has NO bridge.cancel (the daemon is a local
--- subprocess — there is no cancel wire method). NEVER throws (plain table assignments).
function M.reset()
	state.proc        = nil
	state.stdin       = nil
	state.stdout      = nil
	state.rx_buf      = ""
	state.gen         = 0
	state.inflight    = false
	state.shell       = nil
	state.driver      = nil
	state.cwd         = nil
	state.pending_cb  = nil
	state.failed      = false
end

return M
```

### Integration Points

```yaml
MODULE STATE (lua/pi-bridge/shell.lua — NEW, additive):
  - pi-bridge.ShellState class + `local state = {...}` literal (the gen-guard scaffolding; S4 bumps gen).
  - public API: M.resolve_shell / M.pick_driver / M.session_cwd / M.reset (4 exports).

NO EDITS to any existing file:
  - lua/pi-bridge/* are READ-ONLY (completion.lua = the mirror; bridge.lua = get_shell_info source;
    init.lua = descriptor/config source; notify.lua = referenced in the header, NOT called in S2).
  - extension/* (S1/S2/S3 of P2.M1.T1), doc/* (P2.M3.T6.S4 / P2.M4.T7), ftplugin/* (S22 + P2.M3.T6.S3
    teardown wiring), plugin/* (the shim) — all UNTOUCHED.
  - NO shell/*.lua driver created (P2.M2.T4 / P2.M3.T5). NO new config key, RPC method, env var, or helpdoc.

FORWARD CONTRACTS (do NOT implement in S2; just expose the seams + document them):
  - M.ensure(on_ready)            → S3: spawn via vim.uv.spawn; calls resolve_shell + pick_driver + session_cwd.
  - M.request(line,cursor,after,cb) → S4: framed protocol; bumps state.gen + sets state.pending_cb (gen-guard).
  - M._feed(chunk)                → S5: rx_buf sentinel slicing + JSON decode + AutocompleteItem normalize.
  - M.teardown()                  → S6: uv.process_kill SIGKILL + pipe:close ×3 + reset().
  - state.failed                  → set true by S3 ensure() on permanent spawn failure (§17.12); health §17.15.
  - state.pending_cb              → set by S4 request() (the gen-guarded response cb).
```

## Validation Loop

> Run from the repo root (`/home/dustin/projects/pi-nvim-bridge`). ALWAYS wrap nvim in `timeout`
> (AGENTS.md HARD RULE). No lua linter exists (GOTCHA #6) — the smoke + spec ARE the gate. S2 has ZERO
> subprocess (no ensure/spawn) → no live-shell gate (the fish seam is S1's job, already gated).

### Level 1: Syntax (the file parses; the symbols exist)

```bash
# 1a. Confirm the 4 exports + the state literal are present in source:
grep -n "function M.resolve_shell\|function M.pick_driver\|function M.session_cwd\|function M.reset" lua/pi-bridge/shell.lua   # expect 4
grep -n "failed = false" lua/pi-bridge/shell.lua              # expect 1 (the state literal)
grep -n "pending_cb = nil" lua/pi-bridge/shell.lua            # expect 1 (the state literal)
# 1b. Byte-compile the module (catches a syntax error / unbalanced block fast, no subprocess):
timeout 30 nvim --headless --clean -u NORC \
  -c 'lua assert(loadfile("lua/pi-bridge/shell.lua"))' -c 'qa' && echo "PARSE_OK exit=$?"
# Expected: PARSE_OK exit=0. If loadfile returns nil + err, READ it: likely a tab/space mix, an unbalanced
#   `end`/`function`, or a typo in the state literal / a helper. (The `local base = s:gsub(...)` is fine —
#   assignment adjusts gsub's 2 returns to 1; do NOT wrap it in extra parens.)
```

### Level 2-smoke: the plenary-FREE smoke (the full resolve/pick/cwd matrix)

```bash
# 2a. THE gate — run the smoke (prints SMOKE_PASS + exit 0):
timeout 60 nvim --headless --clean -u NORC -c 'set rtp+=.' +"luafile tests/shell_smoke.lua" +qa
echo "exit=$?"
# Expected: SMOKE_PASS, exit=0.
# The smoke MUST cover (mirror these `check(...)` cases — see Task 5):
#   resolve_shell("pi") + fake_bridge.shell="/bin/zsh"          → ("/bin/zsh", "pi")
#   resolve_shell("pi") + no descriptor shell + SHELL="/bin/zsh" → ("/bin/zsh", "$SHELL")
#   resolve_shell("pi") + no descriptor shell + SHELL=nil        → ("/bin/bash", "default")
#   resolve_shell("shell") + SHELL="/bin/zsh"                    → ("/bin/zsh", "$SHELL")
#   resolve_shell("shell") + SHELL=nil                           → ("/bin/bash", "default")
#   resolve_shell("bash")                                        → ("/bin/bash", "default")
#   resolve_shell("/usr/bin/fish")                               → ("/usr/bin/fish", "config")
#   resolve_shell(nil) (defaults to "pi")                        → follows the pi chain
#   pick_driver("/usr/bin/fish") + package.loaded[...fish]={start=fn} → returns the fake
#   pick_driver("/bin/unknownshell")                             → nil (no module)
#   pick_driver("/bin/bash") + config.shell.drivers.bash=false   → nil (disabled)
#   pick_driver(nil) / pick_driver("")                           → nil (never throws)
#   session_cwd() + bridge.server_info.cwd="/srv"                → "/srv"
#   session_cwd() + no server_info + descriptor.cwd="/desc"      → "/desc"
#   session_cwd() + neither                                      → nil
#   never-throws: resolve_shell(123), resolve_shell(""), pick_driver(123), session_cwd() w/ nil everything
# If a check FAILS: re-read the FAIL line; the most common causes are (i) forgetting the `si.shell ~= ""`
#   guard in descriptor_shell, (ii) putting the drivers check in resolve_shell instead of pick_driver,
#   (iii) caching pi/pi.bridge at module top (breaks the per-case injection), (iv) a bare `:gsub` used as
#   an arg (passes 2 values — assign to a local first).
```

### Level 2-spec: the plenary/busted spec (the same matrix, asserted)

```bash
# 2b. THE spec gate — run shell_spec (expect all pass, 0 fail, 0 error):
timeout 90 nvim --headless --clean -u tests/minimal_init.lua \
  -c 'lua require("plenary.busted").run("tests/shell_spec.lua")' 2>&1 | tail -8
echo "exit=${PIPESTATUS[0]}"
# Expected: "Success: <N>", "Failed : 0", "Errors : 0", exit 0. (~14-18 cases.)
# If a case fails: re-read its body vs the smoke case it mirrors — the assertion shapes must match
#   (assert.are.equals on shell + source; assert.is_nil / assert.is_truthy on pick_driver; assert.are.equals
#   on session_cwd). Verify before_each nils pi.bridge/pi.descriptor AND after_each restores them + calls
#   shell.reset() + nils package.loaded["pi-bridge.shell.fish"].
```

### Level 3: Regression (the additive change breaks nothing)

```bash
# 3a. The suites that read the files S2 touches (none — S2 is additive) stay green:
timeout 90 nvim --headless --clean -u tests/minimal_init.lua \
  -c 'lua require("plenary.busted").run("tests/completion_spec.lua")' 2>&1 | grep -E 'Success:|Failed :|Errors :' | tr '\n' ' '; echo "(completion_spec)"
timeout 90 nvim --headless --clean -u tests/minimal_init.lua \
  -c 'lua require("plenary.busted").run("tests/bridge_handshake_spec.lua")' 2>&1 | grep -E 'Success:|Failed :|Errors :' | tr '\n' ' '; echo "(bridge_handshake_spec)"
timeout 60 nvim --headless --clean -u tests/minimal_init.lua \
  -c 'lua require("plenary.busted").run("tests/init_spec.lua")' 2>&1 | grep -E 'Success:|Failed :|Errors :' | tr '\n' ' '; echo "(init_spec)"
timeout 60 nvim --headless --clean -u NORC -c 'set rtp+=.' +"luafile tests/notify_smoke.lua" +qa 2>&1 | tail -1; echo "(notify_smoke)"
# Expected: completion_spec green; bridge_handshake_spec 15/0/0; init_spec 14/0/0; notify_smoke SMOKE_PASS.
# (S2 adds shell.lua + 2 tests; it edits NOTHING — these can only fail if you accidentally modified a sibling.)

# 3b. Isolation — confirm ONLY the 3 new files exist (no sibling touched):
git status --porcelain
# Expected: exactly `?? lua/pi-bridge/shell.lua`, `?? tests/shell_smoke.lua`, `?? tests/shell_spec.lua`.
```

### Level 4: (none — no MCP/Docker/Playwright/web/subprocess surface; S2 is pure lua)

## Final Validation Checklist

### Technical Validation

- [ ] Level 1a: the 4 `function M.*` exports + `failed = false` + `pending_cb = nil` are present (6 greps).
- [ ] Level 1b: `lua/pi-bridge/shell.lua` byte-compiles (`PARSE_OK exit=0`).
- [ ] Level 2a: `tests/shell_smoke.lua` prints `SMOKE_PASS` + `exit=0` (full resolve/pick/cwd matrix).
- [ ] Level 2b: `tests/shell_spec.lua` green (all cases pass, 0 fail, 0 error).
- [ ] Level 3a: `completion_spec`, `bridge_handshake_spec` (15/0/0), `init_spec` (14/0/0), `notify_smoke` green.
- [ ] Level 3b: `git status --porcelain` shows ONLY the 3 new files (no sibling modified).

### Feature Validation

- [ ] `resolve_shell` implements the full §17.4 matrix (pi/shell/bash/explicit-path + the pi fallback chain)
      and returns a `(shell, source)` pair with `source ∈ {"pi","$SHELL","default","config"}`.
- [ ] `resolve_shell` never throws on `nil`/`""`/`123` `prefer` (→ safe `/bin/bash`,`default`).
- [ ] `pick_driver` returns the driver module for a loadable `pi-bridge.shell.<base>` with `.start`; returns
      `nil` for an unknown shell AND for a `config.shell.drivers.<base>==false` driver; never throws.
- [ ] `session_cwd` prefers `server_info.cwd`, falls back to `descriptor.cwd`, else `nil`; never throws.
- [ ] `reset()` restores `state` to its initial literal (all 11 fields).
- [ ] The `[Mode A]` header documents: daemon lifecycle, framed protocol, gen-guard supersession (mirrors
      completion.lua), fresh reads, and the S2 scope fence.

### Code Quality Validation

- [ ] TAB indentation throughout (match completion.lua/bridge.lua/init.lua).
- [ ] `require("pi-bridge")` is LAZY (inside functions), NOT at module top (GOTCHA #1).
- [ ] No `vim.uv.spawn` / `vim.notify` / `require("pi-bridge.notify")` call in S2 (header references only).
- [ ] The drivers-disabled check is in `pick_driver`, not `resolve_shell` (Design Decision §2).
- [ ] `pick_driver` is exported `M.pick_driver` (not `local` — GOTCHA #7).
- [ ] `resolve_shell` is pure (takes `prefer` as a param; reads no config; mutates no state — GOTCHA #9).
- [ ] No edit to `extension/*`, `doc/*`, `ftplugin/*`, `plugin/*`, `completion.lua`, `bridge.lua`, `init.lua`,
      `notify.lua`, or `README.md`. No `shell/*.lua` created.

### Documentation & Deployment

- [ ] [Mode A] the docstring header + the `pi-bridge.ShellState` `---@field` annotations + the per-function
      JSDoc blocks document: the daemon lifecycle, the framed protocol, the gen-guard supersession, the fresh-
      read invariant, the §17.4 fallback chain + source strings, the §17.4.2 driver-selection + disable
      semantics, and the forward-contract seams (ensure/request/_feed/teardown/failed/pending_cb).
- [ ] No README / `doc/pi-bridge.txt` / `doc/pi-bridge-shell.txt` / `extension/README.md` change (Mode-B task
      P2.M4.T7 + vimdoc task P2.M3.T6.S4 own those; S2 is pre-doc).
- [ ] Inline comments cite PRD §17.4 / §17.4.2 / §17.5.2 so a future reader knows WHY each piece exists.

---

## Anti-Patterns to Avoid

- ❌ **Don't read `config`/`bridge`/`descriptor` at module top.** Require `("pi-bridge")` LAZILY INSIDE each
  function (GOTCHA #1). The handshake is async (pi.bridge is nil at first-require) and tests swap in fakes
  after require — caching breaks both. Mirrors completion.lua's header note + bridge.lua L333/L559.
- ❌ **Don't index a nil `config`.** The `shell={}` config block is P2.M3.T6.S1 (NOT yet present); `M.config`
  is nil until `setup()`. Defensive reads: `(pi.config and pi.config.shell) or {}`. `resolve_shell` takes
  `prefer` as a param precisely so it never reads config (GOTCHA #2/#9).
- ❌ **Don't put the drivers-disabled check in `resolve_shell`.** §17.4.2 is DRIVER selection; `pick_driver` IS
  driver selection. `resolve_shell` returning a DIFFERENT shell when its driver is disabled would VIOLATE the
  §17.4 consistency contract (completion would use a different shell than execution). Put the check in
  `pick_driver` (Design Decision §2). `cfg[base] == false` → nil; `nil`/`true`/absent → proceed to require.
- ❌ **Don't keep `pick_driver` as a `local`.** The contract's MOCKING requires testing it. Export
  `M.pick_driver` (GOTCHA #7). completion.lua exports all testable units on M.
- ❌ **Don't use a bare `s:gsub(".*/","")` as a function arg or concat operand.** `string.gsub` returns 2
  values (str, count); a bare use passes both. Assign to a local first (`local base = s:gsub(...)` — assignment
  adjusts to 1), THEN concat. Exactly as the §17.5.2 skeleton does (GOTCHA #4).
- ❌ **Don't treat a `""` shell as "resolved".** `bridge.get_shell_info()` returns `nil` (NOT `""`) when
  unresolved — the nil MUST engage the fallback chain. Guard `si.shell ~= ""` defensively anyway (a malformed
  server is conceivable). A `""` would be a bogus path that short-circuits §17.4 (mirrors S4's GOTCHA #1).
- ❌ **Don't add `vim.uv.spawn` / `vim.notify` / a notice in S2.** `ensure()` (spawn) is S3; the §17.4.3/§17.9/
  §17.6.4 notices are P2.M2.T3.S4. S2 is the PURE resolution + state layer — header references only (GOTCHA #12).
- ❌ **Don't add kill/close logic to `reset()`.** `reset()` is state-clear ONLY. S6's `teardown()` prepends
  `uv.process_kill`+`pipe:close` THEN calls `reset()`. shell.lua has NO `bridge.cancel` (the daemon is a local
  subprocess — there is no cancel wire method; do NOT mirror completion.lua's `b.cancel(state.inflight_id)`).
- ❌ **Don't create `shell/fish.lua` / `shell/zsh.lua` / `shell/bash.lua`.** Those are P2.M2.T4 / P2.M3.T5.
  `pick_driver` pcall-requires them → nil (degrade) until they land. Tests inject fakes into `package.loaded`
  to exercise the present-driver path.
- ❌ **Don't spawn a subprocess in the tests.** S2 tests are PURE (inject fake bridge/descriptor + stub
  `vim.env.SHELL` + inject fake driver into `package.loaded`). The live fish seam was already proven by S1's
  spike; S2 doesn't re-prove it.
- ❌ **Don't heredoc lua into nvim's stdin** (AGENTS.md HARD RULE — it hangs the session). Write the smoke to
  `tests/shell_smoke.lua` and run `+"luafile tests/shell_smoke.lua" +qa` (as shown). Wrap every nvim in `timeout`.