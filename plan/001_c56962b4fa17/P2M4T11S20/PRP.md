---
name: "P2.M4.T11.S20 — plugin/plugin/pi-editor.lua VimEnter auto-activation shim"
description: |
  **Create the startup auto-source shim** for `pi-bridge.nvim` at
  `plugin/plugin/pi-editor.lua`. Neovim auto-sources `plugin/*.lua` at startup step 12
  (`:help load-plugins`), strictly **before** the `VimEnter` event fires at step 19
  (`:help VimEnter`) — so the shim can register a `VimEnter` autocmd that is guaranteed
  live in time. The autocmd is created in an idempotent augroup `pi-editor`
  (`clear = true` so re-sourcing never stacks duplicates), `once = true` (fire exactly
  once per session), and its callback calls `require("pi-editor").activate()`.
  The shim is **dormant-safe** in every ordinary nvim session: it must not error when
  `activate` is absent (this task ships BEFORE S21 implements `activate()`), and it
  performs NONE of the activation work itself (no env-var read, no `setup()`, no
  bridge require — those are S21/S19/S24 respectively).
  STATUS (planning): every validation command in this PRP was LIVE-VERIFIED against the
  installed Neovim 0.12.4 (+ plenary.nvim) — see `research/notes.md` transcript.
  NARROW scope guard — this task does NOT: implement `activate()` (**S21**), read or
  parse `PI_NVIM_BRIDGE` (**S21**), create `ftplugin/pi-prompt.lua` (**S22**),
  `bridge.lua` (**S24**), or `health.lua` (**S42**), and it does NOT call `setup()`
  (that is the user's config per PRD §10.3).
---

## Goal

**Feature Goal**: Create `plugin/plugin/pi-editor.lua` — the VimEnter auto-activation
shim. It is auto-sourced by Neovim at startup (before `VimEnter`) whenever the
`plugin/` directory is on `runtimepath` (the `lazy = false` install path, PRD §10.3).
It registers exactly **one** `VimEnter` autocmd in an idempotent `pi-editor` augroup,
fired **once**, whose callback calls `require("pi-editor").activate()`. It must be
safe to ship **before** `activate()` exists (guarded so it degrades silently), and
must be a harmless no-op in every ordinary (non-pi) nvim session.

**Deliverable** (3 files — all NEW; `plugin/plugin/` directory is created here):
- `plugin/plugin/pi-editor.lua` — the shim: idempotent augroup + fire-once VimEnter
  autocmd + guarded `activate()` call; [Mode A] LuaCATS doc-comment header.
- `plugin/tests/shim_smoke.lua` — plenary-FREE standalone smoke test (the Level-1 gate;
  sourced via `:luafile` because heredocs do NOT work in `-c`/`+` args — reusing the
  S19 GOTCHA #10).
- `plugin/tests/shim_spec.lua` — plenary/busted spec (the formal Level-2 gate).

> Reuses the existing `plugin/tests/minimal_init.lua` from **S19** (it already puts
> `plugin/` on `runtimepath` and plenary on rtp — no change needed).

**Success Definition** (every assertion below is LIVE-VERIFIED to pass — see Validation):
- The shim auto-sources at startup when `plugin/` is on rtp: after startup there is
  **exactly 1** `VimEnter` autocmd in group `pi-editor`, with `once == true`,
  `group_name == "pi-editor"`, and `type(callback) == "function"`.
- With a mock `activate` injected, firing `VimEnter` calls it **exactly once**; firing
  `VimEnter` a second time does **not** call it again (proves `once = true`).
- With **no** `activate` present (the interim state before S21 ships), firing
  `VimEnter` does not error and the process exits 0 (proves dormant-safe).
- Re-sourcing the shim (`runtime plugin/pi-editor.lua`, e.g. `:source %` or a plugin
  manager reload) leaves **exactly 1** autocmd (proves `clear = true` idempotency).
- The shim performs **no** activation work itself (it does not read `PI_NVIM_BRIDGE`,
  does not call `setup()`, does not require `bridge.lua`) — verified by code inspection
  + the "no env var, no mock" session sourcing cleanly with no pi-editor errors.
- `nvim --headless --clean -u NORC` smoke test prints `SMOKE_PASS` / exit 0.
- plenary spec `tests/shim_spec.lua` exits 0 (all `it` blocks pass).

## User Persona (if applicable)

**Target User**: The `pi-bridge.nvim` plugin author and the downstream implementer of
**S21** (the `activate()` function / env-var gate). This is developer plumbing, not
end-user-facing.

**Use Case**: Establishes the single startup entry point that triggers activation. Once
S21 lands `M.activate()`, the shim is what calls it on `VimEnter` — wiring the
auto-sourced `plugin/*.lua` (runtimepath) to the Lua module (`lua/pi-editor/`).
De-risks "does Neovim auto-source our shim before VimEnter, and does it survive a
broken/missing activate?" before any real socket/completion logic lands.

**Pain Points Addressed**: Without this shim there is nothing to call `activate()` on
`VimEnter`; getting the augroup/once/clear semantics and the interim guard locked NOW
(with tests) means S21 just has to *populate* `M.activate` and it will be invoked
exactly once per session, idempotently, with no crash if shipped out of order.

## Why

- **The startup entry point for the whole plugin.** PRD §7.1 says activation happens
  on `VimEnter` (once). PRD §9.2 / §10.3 place this file at `plugin/pi-editor.lua`
  (runtimepath-relative) and mandate `lazy = false` so it is sourced at startup rather
  than deferred. This shim IS that entry point.
- **Faithful to pi's dormancy contract (PRD §7.1, §11).** The plugin "stays dormant in
  normal nvim use and activates only when pi launches the editor." The *decision* to
  activate lives in `activate()` / S21 (it reads `PI_NVIM_BRIDGE`); this shim only
  *triggers* `activate()` on `VimEnter`. Keeping that boundary clean (shim = trigger,
  activate = gate) is why S20 and S21 don't overlap.
- **Ships safely out of order.** Because the orchestrator implements S20 before S21,
  the shim MUST tolerate a missing `activate`. A guarded call keeps every ordinary
  nvim session (and the interim build) crash-free — and the same guard is the
  mock-injection seam the tests use to prove "called exactly once".
- **Integrates with the (complete) foundation.** The shim calls into the module created
  in **S19** (`plugin/lua/pi-editor/init.lua` — DONE), which already exposes
  `setup`/`defaults`/`config`/`bridge`. It does not touch the (complete, P1) TypeScript
  bridge extension.

## What

User-visible behavior: none directly at runtime in ordinary sessions (the shim's
autocmd registers, then `activate` either doesn't exist yet or returns early because
`PI_NVIM_BRIDGE` is unset). The user-visible contract is structural: install the
plugin with `lazy = false`, and on the next pi-launched editor session the
`VimEnter` → `activate()` wiring is in place.

Technical requirements:
- File at runtimepath-relative path **`plugin/pi-editor.lua`** (on disk:
  `plugin/plugin/pi-editor.lua` from the repo root, because the repo's `plugin/`
  subdir is the runtimepath entry — see GOTCHA #1).
- A `pi-editor` augroup created with **`clear = true`** (idempotent re-source).
- One `VimEnter` autocmd in that group with **`once = true`** and a `callback`.
- The callback: `pcall(require, "pi-editor")`; if ok and `type(pi.activate) ==
  "function"` then `pi.activate()` (interim/dormant-safe; S21 populates `activate`).
- [Mode A] LuaCATS doc-comment header explaining auto-source timing, the `once`/`clear`
  semantics, the dormancy contract, and the `lazy = false` requirement.

### Success Criteria

- [ ] With `plugin/` on rtp, startup leaves **exactly 1** `VimEnter` autocmd in group
      `pi-editor` (no duplicates without re-source).
- [ ] That autocmd has `once == true`, `group_name == "pi-editor"`,
      `type(callback) == "function"`.
- [ ] Injected mock `activate` is called **exactly once** when `VimEnter` fires once.
- [ ] Mock `activate` is still called **exactly once** when `VimEnter` fires twice
      (proves `once = true` — no double activation).
- [ ] Firing `VimEnter` with **no** `activate` does **not** error (interim safety) and
      the process exits 0.
- [ ] `runtime plugin/pi-editor.lua` twice leaves **exactly 1** autocmd (proves
      `clear = true` idempotency — safe for `:source %` / plugin-manager reload).
- [ ] The shim does **not** read `PI_NVIM_BRIDGE`, call `setup()`, or `require` any
      module other than `pi-editor` (boundary vs S21/S19/S24 — code inspection).
- [ ] `nvim --headless --clean -u NORC` smoke test prints `SMOKE_PASS` and exits 0.
- [ ] `tests/shim_spec.lua` passes under plenary (exit 0).
- [ ] [Mode A] LuaCATS doc-comment header present and accurate.

## All Needed Context

### Context Completeness Check

_Passes "No Prior Knowledge":_ an implementer who has never seen this repo needs only
this PRP + `research/notes.md` + the verified commands below. Every API
(`nvim_create_augroup`, `nvim_create_autocmd`, `nvim_get_autocmds`,
`nvim_exec_autocmds`, `:runtime`) is cited with a `:help` source and a
**LIVE-VERIFIED** runnable command (see `research/notes.md` transcript). The
plugin-root-vs-repo-root runtimepath gotcha (the #1 cause of "tests get sourced at startup / shim misbehaves" — Neovim sources <rtp>/plugin/**/*.lua RECURSIVELY) is
spelled out in §Known Gotchas and embedded in every validation command. The
"`activate()` doesn't exist yet" interim trap (the #1 cause of "shim crashes on
VimEnter") is spelled out too.

### Documentation & References

```yaml
# MUST READ — primary contract sources

- url: https://neovim.io/doc/user/starting.html#load-plugins
  why: "Startup step 12: Neovim auto-sources ALL plugin/*.vim AND plugin/*.lua files on
        runtimepath, in alphabetical order. This is WHY a plugin/*.lua shim runs at all,
        and WHY it runs BEFORE step-19 VimEnter."
  critical: "A real builtin example is /usr/share/nvim/runtime/plugin/editorconfig.lua
             (.lua auto-sourcing is real and used by Neovim itself). LIVE-VERIFIED:
             with plugin/ on rtp via --cmd, the shim's source-time marker is set and
             exactly 1 autocmd is registered before any + arg runs."

- url: https://neovim.io/doc/user/autocmd.html#VimEnter
  why: "Startup step 19: VimEnter fires LAST, after loading vimrc + all -c/+ args. So an
        autocmd registered at step 12 is guaranteed live before step 19."
  critical: "+qa / -c run at step 17 and can quit BEFORE step 19 — so VimEnter looks
             'not to fire' when a trailing +qa is used. In tests, fire it manually with
             nvim_exec_autocmds('VimEnter', {}) from a + arg (step 17, post auto-source)."

- url: https://neovim.io/doc/user/api.html#nvim_create_autocmd()
  why: "nvim_create_autocmd({event}, { group=, once=, callback= }). once=true runs the
        callback once then removes it. callback is a Lua function."
  critical: "once=true is what guarantees 'called exactly once' even if VimEnter is
             fired twice. LIVE-VERIFIED (activate_calls=1 after 2 exec_autocmds)."

- url: https://neovim.io/doc/user/api.html#nvim_create_augroup()
  why: "nvim_create_augroup(name, { clear = true }) wipes prior autocmds in the group on
        each call — the idiomatic idempotent-re-source pattern."
  critical: "MUST use clear=true, else :source % / plugin-manager reload STACKS duplicate
             VimEnter autocmds (activate called 2x, 3x, ...). LIVE-VERIFIED: re-source
             twice → still 1 autocmd with clear=true."

- url: https://neovim.io/doc/user/api.html#nvim_get_autocmds()
  why: "nvim_get_autocmds({ event=, group= }) returns a list whose elements expose
        event/group/group_name/id/once/pattern/callback — the assertable surface for tests."
  critical: "Assert #list==1, a[1].once==true, a[1].group_name=='pi-editor'. The callback
             field is a function reference (type()=='function')."

- url: https://neovim.io/doc/user/api.html#nvim_exec_autocmds()
  why: "nvim_exec_autocmds('VimEnter', {}) runs all VimEnter autocmds on demand — THE
        headless-test primitive for 'fire VimEnter and assert'."
  critical: "Call it from a + arg (step 17, AFTER step-12 auto-source), NOT from --cmd
             (step 3, before auto-source — the autocmd isn't registered yet). Gotcha #4."

- url: https://neovim.io/doc/user/repeat.html#:runtime
  why: ":runtime plugin/pi-editor.lua sources the first match on runtimepath — used in
        tests to force a re-source for the idempotency check."
  critical: "Deterministic even under --clean (which has a doc tension re: plugin loading)."

- url: https://lazy.folke.io/spec/spec.nvim#lazy
  why: "lazy = false means 'load the plugin during startup' — i.e. plugin/*.lua is sourced
        at startup, not deferred. PRD §10.3 mandates this so the shim is live before VimEnter."
  critical: "If a user sets lazy=true (defers loading), the shim may source AFTER VimEnter
             and activation is skipped. Document lazy=false as REQUIRED in the shim header."

- file: plan/001_c56962b4fa17/P2M4T11S20/research/notes.md
  why: "LIVE-VERIFIED proof (nvim 0.12.4, this env) that every validation command in this
        PRP runs green, AND proof of the 5 core behaviours (auto-source, once, clear,
        interim-safe, dormant). Includes the full verification transcript."

- file: plan/001_c56962b4fa17/P2M1T1S2/research/neovim-startup-and-vimenter.md
  why: "The canonical background research for THIS task: step ordering, once/clear proofs,
        nvim_get_autocmds shape, headless test shape, exit-code/pipe gotchas. Every claim
        in it is empirically verified; this PRP's research/notes.md re-confirms them live."

- file: plugin/lua/pi-editor/init.lua
  why: "The S19 module the shim calls into. Confirms the public surface is
        setup/defaults/config/bridge and that there is NO activate() field yet (hence the
        guard). Confirms field names S21 will rely on are already locked."

- file: plugin/tests/minimal_init.lua
  why: "The S19 plenary harness bootstrap — already puts plugin/ on rtp and plenary on rtp.
        Reused unchanged for shim_spec.lua (no edit needed)."

- docfile: plan/001_c56962b4fa17/prd_snapshot.md
  section: "§7.1 (activation gate), §7.2 (module layout — plugin/pi-editor.lua), §10.3 (lazy=false install), §11 (dormant/silent degradation)"
  why: "These four PRD sections ARE the source of truth for this task's placement, timing,
        and dormancy contract (reproduced in <selected_prd_content>)."
```

### Current Codebase tree (relevant slice)

```bash
pi-nvim-bridge/                  # repo root (monorepo: extension/ + plugin/)
├── extension/                   # P1 — pi-editor-bridge (TypeScript) — COMPLETE
├── plugin/                      # <-- Neovim plugin root (the runtimepath entry)
│   ├── lua/pi-editor/init.lua   # S19 (DONE) — setup/defaults/config/bridge; NO activate() yet
│   └── tests/
│       ├── minimal_init.lua     # S19 (DONE) — plenary harness; puts plugin/ on rtp (REUSED)
│       ├── init_spec.lua        # S19 (DONE) — setup() spec
│       └── smoke.lua            # S19 (DONE) — setup() smoke
├── PRD.md  README.md  package.json
└── plan/001_c56962b4fa17/
    ├── architecture/{external_deps,system_context}.md
    ├── P2M1T1S2/research/neovim-startup-and-vimenter.md   # background for THIS task
    ├── P2M4T11S19/{PRP.md, research/live-verification.md} # S19 (predecessor, DONE)
    └── P2M4T11S20/{PRP.md, research/notes.md}             # THIS task
# NOTE: there is NO plugin/plugin/ directory yet — this task CREATES it.
# NOTE: stylua, selene are NOT installed (nvim 0.12.4 + plenary.nvim ARE).
```

### Desired Codebase tree with files to be added

```bash
plugin/                          # runtimepath entry (unchanged)
├── lua/pi-editor/init.lua       # (S19, unchanged)
├── plugin/
│   └── pi-editor.lua            # NEW — the VimEnter auto-activation shim  [THE deliverable]
└── tests/
    ├── minimal_init.lua         # (S19, REUSED unchanged)
    ├── shim_smoke.lua           # NEW — plenary-FREE smoke test (Level-1 gate; :luafile-sourced)
    └── shim_spec.lua            # NEW — plenary/busted spec (Level-2 gate)
```

> **Why `plugin/plugin/pi-editor.lua`?** The runtimepath entry is the repo's
> `plugin/` subdir (GOTCHA #1). Neovim auto-sources `<rtp>/plugin/*.lua` at startup
> (`:help load-plugins`). So the runtimepath-relative path is `plugin/pi-editor.lua`,
> which on disk (from the repo root) is `plugin/plugin/pi-editor.lua`. This mirrors
> a normal standalone plugin repo layout (PRD §9.2).

### Known Gotchas of our codebase & Library Quirks

```lua
-- GOTCHA #1 — runtimepath MUST point at the plugin/ SUBDIRECTORY, not the repo root.
-- Neovim auto-sources <rtp>/plugin/**/*.lua RECURSIVELY (:help load-plugins — verified on
--   0.12.4: it descends into EVERY subdir under <rtp>/plugin/). With rtp = repo root that
--   means <repo>/plugin/**/*.lua is swept — which includes <repo>/plugin/tests/*.lua!
--   So a repo-root rtp sources init_spec.lua / smoke.lua at STARTUP → they error
--   (`attempt to call global 'describe'` — busted is nil without plenary) and pollute
--   every session. It ALSO sources <repo>/plugin/lua/pi-editor/init.lua as a plugin
--   script (wrong). CORRECT: rtp = .../pi-nvim-bridge/plugin → then <rtp>/plugin/**/*.lua
--   is JUST plugin/plugin/pi-editor.lua (tests/ and lua/ are NOT under a plugin/ subdir,
--   so they are untouched), and require resolves via <rtp>/lua/pi-editor/init.lua.
-- LIVE-VERIFIED (3/3 runs each): repo-root rtp → sources tests/init_spec.lua (describe
--   error) every time; plugin/ rtp → clean startup, no test files sourced.

-- GOTCHA #2 — activate() does NOT exist yet (S21 implements it; this task ships first).
-- An UNCONDITIONAL `require("pi-editor").activate()` throws 'attempt to call a nil value'
-- on every VimEnter until S21 lands → breaks dormant sessions + makes S20 un-testable.
-- FIX: guard with `if ok and type(pi.activate) == "function" then pi.activate() end`.
-- The SAME guard is the mock-injection seam for tests (inject require("pi-editor").activate).
-- LIVE-VERIFIED: no-activate → 'survived=yes', exit 0 (research/notes.md TEST 3).

-- GOTCHA #3 — fire VimEnter from a + arg (step 17), NEVER from --cmd (step 3).
-- --cmd runs at step 3, BEFORE step-12 auto-source, so the autocmd isn't registered yet.
-- A --cmd nvim_exec_autocmds("VimEnter",{}) fires NOTHING (first verification hit this).
-- + / -c run at step 17 (post auto-source) → correct place to fire/inject/assert.

-- GOTCHA #4 — a trailing +qa (step 17) quits BEFORE VimEnter (step 19) fires.
-- So VimEnter callbacks look "not to run" in headless runs that end with +qa. In tests,
-- do NOT rely on the natural VimEnter; fire it manually with
-- nvim_exec_autocmds("VimEnter", {}) from a + arg, THEN assert, THEN +qa.

-- GOTCHA #5 — MUST use clear=true on the augroup, or re-sourcing stacks duplicates.
-- :source % / plugin-manager reload without clear=true → 2, 3, ... VimEnter autocmds →
-- activate called multiple times. clear=true wipes + re-adds on each source → exactly 1.
-- LIVE-VERIFIED: runtime twice → after_resource_count=1 (research/notes.md TEST 4).

-- GOTCHA #6 — once=true removes the autocmd AFTER it fires once.
-- So in tests, each sub-test that fires VimEnter consumes the autocmd; re-source
-- (vim.cmd("runtime plugin/pi-editor.lua")) in before_each to restore a fresh one.
-- This is also why once=true is the right guarantee for "called exactly once".

-- GOTCHA #7 — pcall(require, ...) shares the SAME module table as the test's mock.
-- require caches in package.loaded. A test doing require("pi-editor").activate = mock
-- mutates the SAME table the shim's pcall(require, "pi-editor") returns → mock IS invoked.
-- LIVE-VERIFIED (activate_calls=1 with an injected mock).

-- GOTCHA #8 — do NOT pcall the activate() call itself; only pcall the require.
-- pcall(require) → load safety (broken/missing module degrades silently — dormant).
-- Direct pi.activate() call → genuine activate() BUGS surface for debugging (don't hide them).
-- S21/S39 own activate()'s internal resilience (silent degrade / one-time notify).
-- This split is deliberate; document it in the shim header.

-- GOTCHA #9 — a ':lua <<HEREDOC' does NOT work inside -c/+ command-line args.
-- (Inherited from S19 GOTCHA #10; same nvim 0.12.4 E5107 behaviour.) For multi-statement
-- validation, write a file and source it via :luafile. That's why shim_smoke.lua exists.

-- GOTCHA #10 — scope guard. This task is ONLY plugin/pi-editor.lua + its tests. Do NOT:
--   read PI_NVIM_BRIDGE (S21), implement activate() (S21), call setup() (user config),
--   create ftplugin/pi-prompt.lua (S22), bridge.lua (S24), health.lua (S42).
--   The shim's ONLY job: auto-source → register one idempotent fire-once VimEnter autocmd
--   → call activate() (guarded). Keeping it that narrow is what makes it independently
--   shippable + unit-testable here.

-- GOTCHA #11 — a benign 'syntax.vim E216 filetypedetect BufRead' warning appears under
-- `nvim --headless --clean -u NORC`. It is an nvim-internal filetype/syntax init artifact,
-- NOT from our shim, and does NOT change the exit code (still 0). Ignore it; judge
-- pass/fail by our own markers (count=, activate_calls=, SMOKE_PASS) and $?.
```

## Implementation Blueprint

### Data models and structure

No data models (no tables/classes/fields). The shim is a sourced script. The only
"structure" is the [Mode A] LuaCATS doc-comment header (file-level documentation) +
two local bindings (`group`, the autocmd opts). See the reference implementation below.

### Implementation Tasks (ordered by dependencies)

```yaml
Task 1: CREATE plugin/plugin/pi-editor.lua  (THE shim — the deliverable)
  - CREATE the directory plugin/plugin/ (first file under it).
  - CONTENT: a [Mode A] file-level doc-comment header (auto-source timing, once/clear,
        dormancy, lazy=false requirement, interim-safe guard explanation); then:
      local group = vim.api.nvim_create_augroup("pi-editor", { clear = true })
      vim.api.nvim_create_autocmd("VimEnter", {
        group = group, once = true,
        callback = function()
          local ok, pi = pcall(require, "pi-editor")
          if ok and type(pi.activate) == "function" then pi.activate() end
        end,
      })
  - DOCS MODE A: a file-level `---` doc comment (LuaCATS file doc) above the code.
  - NAMING: augroup "pi-editor" (matches the convention used by every later module's
        buffer-local autocmds — S22/S24 will use the same group name for cohesion).
  - PLACEMENT: plugin/plugin/pi-editor.lua (runtimepath-relative: plugin/pi-editor.lua).
  - DO NOT add: any env-var read, any setup() call, any require other than "pi-editor",
        any buffer/filetype logic. (GOTCHA #10.)
  - DO NOT remove the guard — it is load-bearing for interim safety + testing (GOTCHA #2).

Task 2: CREATE plugin/tests/shim_smoke.lua  (plenary-FREE fast smoke — the Level-1 gate)
  - CONTENT (see Implementation Patterns): a standalone script that sets its own
        runtimepath (append the plugin/ root computed from its own path via debug.getinfo
        + fnamemodify ':p'/':h:h'), then runs check(cond,msg) assertions covering every
        Success Criterion, and calls vim.cmd('cquit 1') on any failure so the process
        exits non-zero. It MUST re-source the shim between sub-tests that consume the
        once-autocmd (vim.cmd("runtime plugin/pi-editor.lua")) and inject/clear a mock
        activate as needed.
  - WHY: instant, dependency-free feedback (no plenary). shim_spec.lua is the formal suite.
  - GOTCHA: source via :luafile, NOT a :lua <<HEREDOC in a -c/+ arg (GOTCHA #9).
  - PLACEMENT: plugin/tests/shim_smoke.lua.
  - DEPENDENCIES: Task 1 (the shim) + the S19 module (plugin/lua/pi-editor/init.lua).

Task 3: CREATE plugin/tests/shim_spec.lua  (plenary/busted spec — the Level-2 gate)
  - CONTENT (see Implementation Patterns): a describe("pi-editor VimEnter shim", …)
        block. before_each: reset package.loaded["pi-editor"], require it fresh, re-source
        the shim (restore a fresh once-autocmd), zero a call counter global. Cover ALL
        Success Criteria: (1) exactly-1 autocmd with once=true/group=pi-editor/fn callback;
        (2) mock activate called once on one VimEnter; (3) still once on two VimEnters;
        (4) no error + counter 0 when activate absent; (5) idempotent re-source → 1 autocmd;
        (6) shim contains the structural tokens (VimEnter autocmd, once=true, clear=true)
        and does NOT read the environment (vim.env / os.getenv) — asserted via robust
        literal source-text checks. (No-setup-call / no-bridge-require are code-inspection
        checklist items — see Implementation Patterns & Final Validation Checklist.)
  - ASSERTIONS: assert.are.equals (scalars/strings/type()), assert.is_true/is_false,
        assert.has_no.errors (for the no-activate fire), assert.are.same where needed.
  - PLACEMENT: plugin/tests/shim_spec.lua.
  - DEPENDENCIES: Task 1 (the shim) + the S19 harness (plugin/tests/minimal_init.lua).
```

### Implementation Patterns & Key Details

```lua
-- === plugin/plugin/pi-editor.lua — COMPLETE reference implementation ===
-- (The implementer may ship this verbatim; it satisfies every Success Criterion and is
--  LIVE-VERIFIED to pass the smoke + plenary gates.)

--- pi-bridge.nvim — VimEnter auto-activation shim.
---
--- This file is auto-sourced by Neovim at startup step 12 (`:help load-plugins`): every
--- `plugin/*.lua` on `runtimepath` is sourced, in alphabetical order, strictly BEFORE
--- the `VimEnter` event fires at step 19 (`:help VimEnter`). So the autocmd registered
--- below is guaranteed live before `VimEnter`.
---
--- It registers exactly ONE `VimEnter` autocmd in the `pi-editor` augroup:
---   - `clear = true`  — re-sourcing (e.g. `:source %` or a plugin-manager reload) wipes
---                       and re-adds, so autocmds never stack duplicates.
---   - `once = true`   — the callback runs exactly once per session, then is removed.
---
--- The callback calls `require("pi-editor").activate()` (implemented by a later task,
--- S21). The plugin stays DORMANT in every ordinary nvim session: `activate()` itself
--- returns early unless pi spawned this editor with `PI_NVIM_BRIDGE` set (PRD §7.1,
--- §11). The guard below also keeps this shim crash-free while `activate` is absent
--- (interim build / broken install) — it degrades silently instead of throwing.
---
--- IMPORTANT (install): the user's plugin manager MUST use `lazy = false` (PRD §10.3) so
--- this file is sourced at startup rather than deferred past `VimEnter`. With lazy=true
--- the shim may source after VimEnter and activation is skipped.
---
--- Scope: this shim ONLY triggers activation. It does NOT read `PI_NVIM_BRIDGE`, call
--- `setup()`, or `require` any module other than `pi-editor` (those belong to S21 / the
--- user's config / S24 respectively).
local group = vim.api.nvim_create_augroup("pi-editor", { clear = true })

vim.api.nvim_create_autocmd("VimEnter", {
  group = group,
  once = true,
  callback = function()
    -- pcall(require) for load safety: a broken/missing module degrades silently (dormant).
    -- We do NOT pcall activate() itself: genuine activate() bugs should surface for
    -- debugging (activate / S21+S39 own their internal resilience).
    local ok, pi = pcall(require, "pi-editor")
    if ok and type(pi.activate) == "function" then
      pi.activate()
    end
  end,
})
```

```lua
-- === plugin/tests/shim_smoke.lua — standalone (plenary-FREE) smoke test for the shim ===
-- Run from the REPO ROOT:
--   nvim --headless --clean -u NORC +"luafile plugin/tests/shim_smoke.lua" +qa ; echo exit=$?
-- Exits 0 on pass (prints SMOKE_PASS), 1 on any check failure (via cquit). Zero deps.
-- NOTE: this file is sourced at step 17 (+), AFTER step-12 auto-source of plugin/pi-editor.lua
-- (provided plugin/ is on runtimepath — set below). Do NOT move the runtimepath set into
-- the shim or into a --cmd (GOTCHA #1/#3).
local me = debug.getinfo(1, "S").source:sub(2)
me = vim.fn.fnamemodify(me, ":p")                  -- absolute path of THIS file
local plugin_root = vim.fn.fnamemodify(me, ":h:h") -- .../plugin  (rtp entry — GOTCHA #1)
vim.opt.runtimepath:append(plugin_root)

-- Force a (re)source of the shim now that plugin/ is on rtp, so this file is self-contained
-- and does not depend on having been auto-sourced in this --clean session.
vim.cmd("runtime plugin/pi-editor.lua")

local fails = 0
local function check(cond, msg)
  if not cond then io.stderr:write("FAIL: " .. msg .. "\n"); fails = fails + 1 end
end

-- helpers
local function autovims()
  return vim.api.nvim_get_autocmds({ event = "VimEnter", group = "pi-editor" })
end
local function resource() vim.cmd("runtime plugin/pi-editor.lua") end

-- CHECK 1: exactly 1 VimEnter autocmd, once=true, group=pi-editor, callback is a fn.
local a = autovims()
check(#a == 1, "expected exactly 1 VimEnter autocmd, got " .. #a)
if a[1] then
  check(a[1].once == true, "autocmd.once should be true")
  check(a[1].group_name == "pi-editor", "group_name should be 'pi-editor', got " .. tostring(a[1].group_name))
  check(type(a[1].callback) == "function", "callback should be a function")
end

-- CHECK 2: mock activate injected → called EXACTLY ONCE on one VimEnter fire.
resource()                                               -- fresh once-autocmd
package.loaded["pi-editor"] = nil; local pi = require("pi-editor")
vim.g.pi_calls = 0
pi.activate = function() vim.g.pi_calls = vim.g.pi_calls + 1 end
vim.api.nvim_exec_autocmds("VimEnter", {})               -- step-17 manual fire (GOTCHA #3/#4)
check(vim.g.pi_calls == 1, "mock activate should be called exactly once (got " .. tostring(vim.g.pi_calls) .. ")")

-- CHECK 3: fire VimEnter a SECOND time → still 1 (once=true).
vim.api.nvim_exec_autocmds("VimEnter", {})
check(vim.g.pi_calls == 1, "once=true should prevent a second call (got " .. tostring(vim.g.pi_calls) .. ")")
pi.activate = nil                                        -- clean up the mock

-- CHECK 4: NO activate present → firing VimEnter does NOT error (interim/dormant-safe).
resource()                                               -- fresh once-autocmd
package.loaded["pi-editor"] = nil; require("pi-editor")  -- fresh module, activate == nil
local ok, err = pcall(vim.api.nvim_exec_autocmds, "VimEnter", {})
check(ok, "firing VimEnter with no activate should not error: " .. tostring(err))
check(vim.g.pi_calls == 1, "no-activate fire should not have called the (removed) mock")

-- CHECK 5: idempotent re-source → still exactly 1 autocmd (clear=true, GOTCHA #5).
resource(); resource()                                   -- source 2 extra times
check(#autovims() == 1, "re-source should not stack duplicates (got " .. #autovims() .. ")")

-- CHECK 6 (structural + no env-read): assert the core tokens are present AND the shim
-- does NOT read the environment. We use only ROBUST literals: the doc-comment header
-- mentions "PI_NVIM_BRIDGE"/"setup()" by name to explain they are NOT used here, so a
-- naive "does NOT contain those words" search would FALSE-POSITIVE on the comment.
-- Instead we assert no env access (vim.env / os.getenv) + presence of the structural
-- tokens. (No-setup-call / no-bridge-require are code-inspection checklist items.)
local src = table.concat(vim.fn.readfile(plugin_root .. "/plugin/pi-editor.lua"), "\n")
check(src:find('nvim_create_autocmd("VimEnter"', 1, true) ~= nil, "shim must register a VimEnter autocmd")
check(src:find("once = true", 1, true) ~= nil, "shim must set once = true")
check(src:find("clear = true", 1, true) ~= nil, "shim must set clear = true")
check(src:find("vim.env", 1, true) == nil, "shim must NOT read the env (PI_NVIM_BRIDGE is S21's job)")
check(src:find("getenv", 1, true) == nil, "shim must NOT call os.getenv (S21's job)")

if fails > 0 then
  io.stderr:write(fails .. " check(s) failed\n")
  vim.cmd("cquit 1")
end
io.stdout:write("SMOKE_PASS\n")
```

```lua
-- === plugin/tests/shim_spec.lua — the spec (covers every Success Criterion) ===
-- Run (from the plugin/ directory):
--   nvim --headless --clean -u tests/minimal_init.lua \
--     -c 'lua require("plenary.busted").run("tests/shim_spec.lua")'
describe("pi-editor VimEnter shim", function()
  local plugin_root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
  local shim_rel = "plugin/pi-editor.lua"            -- runtimepath-relative

  before_each(function()
    -- fresh module each test (activate is nil on a fresh require)
    package.loaded["pi-editor"] = nil
    require("pi-editor")
    -- fresh once-autocmd each test (clear=true wipes + re-adds — GOTCHA #5/#6)
    vim.cmd("runtime " .. shim_rel)
    vim.g.pi_calls = 0
  end)

  local function vims()
    return vim.api.nvim_get_autocmds({ event = "VimEnter", group = "pi-editor" })
  end

  it("registers exactly one fire-once VimEnter autocmd in the pi-editor group", function()
    local a = vims()
    assert.are.equals(1, #a)
    assert.is_true(a[1].once)
    assert.are.equals("pi-editor", a[1].group_name)
    assert.are.equals("function", type(a[1].callback))
  end)

  it("calls activate() exactly once when VimEnter fires once", function()
    require("pi-editor").activate = function() vim.g.pi_calls = vim.g.pi_calls + 1 end
    vim.api.nvim_exec_autocmds("VimEnter", {})
    assert.are.equals(1, vim.g.pi_calls)
  end)

  it("does not call activate twice when VimEnter fires twice (once=true)", function()
    require("pi-editor").activate = function() vim.g.pi_calls = vim.g.pi_calls + 1 end
    vim.api.nvim_exec_autocmds("VimEnter", {})
    vim.api.nvim_exec_autocmds("VimEnter", {})
    assert.are.equals(1, vim.g.pi_calls)
  end)

  it("degrades silently when activate is absent (no error, stays dormant)", function()
    -- activate is nil on the fresh require from before_each
    assert.has_no.errors(function()
      vim.api.nvim_exec_autocmds("VimEnter", {})
    end)
    assert.are.equals(0, vim.g.pi_calls)
  end)

  it("is idempotent under re-source (clear=true prevents duplicate autocmds)", function()
    vim.cmd("runtime " .. shim_rel)
    vim.cmd("runtime " .. shim_rel)
    assert.are.equals(1, #vims())
  end)

  it("contains the required structural tokens and does not read the environment", function()
    -- Robust literals only. The doc-comment header mentions "PI_NVIM_BRIDGE"/"setup()"
    -- by name to explain they are NOT used here, so a naive "does NOT contain those words"
    -- search would FALSE-POSITIVE on the comment. Instead: assert no env access
    -- (vim.env / os.getenv) + presence of the structural tokens. (No-setup-call /
    -- no-bridge-require are code-inspection checklist items — see Final Validation Checklist.)
    local src = table.concat(vim.fn.readfile(plugin_root .. "/plugin/pi-editor.lua"), "\n")
    assert.is_true(src:find('nvim_create_autocmd("VimEnter"', 1, true) ~= nil)
    assert.is_true(src:find("once = true", 1, true) ~= nil)
    assert.is_true(src:find("clear = true", 1, true) ~= nil)
    assert.is_nil(src:find("vim.env", 1, true))   -- no env read (PI_NVIM_BRIDGE is S21)
    assert.is_nil(src:find("getenv", 1, true))    -- no os.getenv (S21)
  end)
end)
```

### Integration Points

```yaml
RUNTIMEPATH (Neovim):
  - the plugin/ subdirectory is the runtimepath entry (NOT the repo root) — GOTCHA #1.
    This task adds <rtp>/plugin/pi-editor.lua (disk: plugin/plugin/pi-editor.lua), which
    Neovim auto-sources at startup step 12.

AUGROUP NAMING (cohesion):
  - the augroup is named "pi-editor" (same name S22/S24 will reuse for their buffer-local
    autocmds). This task only CREATES + registers into it; later tasks may add more
    autocmds to the same group — clear=true is only invoked by THIS shim's re-source.

PUBLIC SURFACE (no change):
  - this task adds NO new module field. It calls the EXISTING require("pi-editor") and
    the (future, S21) .activate field. No change to init.lua (S19) is required.

FORWARD CONTRACTS (do NOT implement here — just don't break them):
  - S21 adds M.activate() to init.lua and implements the PI_NVIM_BRIDGE read + gate.
    The shim's guard `type(pi.activate) == "function"` becomes a no-op until S21 ships,
    then transparently starts invoking the real activate() — NO shim change needed.
  - S22 (ftplugin/pi-prompt.lua) and S24 (bridge.lua) are NOT referenced by this shim.

NO DATABASE / NO NETWORK / NO CONFIG FILES / NO ENV-VAR READS in this task.
```

## Validation Loop

> **Run all commands from the REPO ROOT** (`/home/dustin/projects/pi-nvim-bridge`).
> The plugin root is `$(pwd)/plugin`. **Every command below is LIVE-VERIFIED green**
> on the installed Neovim 0.12.4 + plenary.nvim (see `research/notes.md` transcript).
> NOTE: `nvim --headless --clean -u NORC` prints a benign
> `Error in .../syntax/syntax.vim: E216: No such group or event: filetypedetect BufRead`
> (an nvim filetype/syntax init artifact, NOT from our shim; exit code stays 0). Judge
> pass/fail by our markers (`count=`, `activate_calls=`, `SMOKE_PASS`) and `$?`, not by
> that warning (GOTCHA #11).

### Level 1: Syntax & Load (Immediate Feedback — dependency-free, no plenary)

```bash
# 1a. Smoke test via the deliverable plugin/tests/shim_smoke.lua (plenary-FREE fast feedback).
#     The script sets its own runtimepath, force-sources the shim, and uses cquit(1) on
#     failure (reliable exit code). Run from the REPO ROOT. NO :lua <<HEREDOC (GOTCHA #9).
nvim --headless --clean -u NORC +"luafile plugin/tests/shim_smoke.lua" +qa
echo "exit=$?   # 0 = pass (prints 'SMOKE_PASS'), 1 = a check failed"
# LIVE-VERIFIED (research/notes.md): prints SMOKE_PASS, exit=0.
```

```bash
# 1b. (Optional, only if installed) Lua lint/format. NOT a hard gate (inherited GOTCHA).
command -v selene >/dev/null && selene -q plugin/plugin || echo "selene not installed (skipped; optional)"
command -v stylua >/dev/null && stylua --check plugin/plugin || echo "stylua not installed (skipped; optional)"
```

### Level 2: Unit Tests (plenary spec)

```bash
# 2a. In-process plenary run (reuses the S19 minimal_init.lua — it already puts plugin/
#     on rtp and plenary on rtp). Exit codes: 0 = all pass, 1 = an 'it' failed, 2 = load.
cd plugin
nvim --headless --clean -u tests/minimal_init.lua \
  -c 'lua require("plenary.busted").run("tests/shim_spec.lua")'
echo "exit=$?"
cd ..
# Expected: exit=0, prints "Success: 6  Failed: 0  Errors: 0" (6 'it' blocks).
```

### Level 3: Integration (auto-source timing + dormant behaviour, end-to-end)

```bash
# 3a. Prove the shim is auto-sourced at startup BEFORE VimEnter, registering exactly 1
#     once-autocmd, when plugin/ is on runtimepath via --cmd (step 3). (TEST 1 pattern.)
PLUGIN_ROOT="$(pwd)/plugin"
nvim --headless --clean -u NORC --cmd "let &runtimepath = '$PLUGIN_ROOT'" \
  +"lua local a=vim.api.nvim_get_autocmds({event='VimEnter',group='pi-editor'}); print('count='..#a..' once='..tostring(a[1].once)..' group='..tostring(a[1].group_name))" +qa 2>&1 | grep '^count='
# Expected: count=1 once=true group=pi-editor

# 3b. Prove the runtimepath gotcha (the REAL, DETERMINISTIC breakage): with repo-root rtp,
#     Neovim's recursive <rtp>/plugin/**/*.lua sourcing sweeps in plugin/tests/*.lua at
#     startup → init_spec.lua errors (`describe` is nil without plenary). With the correct
#     rtp ($PLUGIN_ROOT) the tests/ dir is NOT under a plugin/ subdir, so it is untouched.
ERR=$(nvim --headless --clean -u NORC --cmd "let &runtimepath = '$(pwd)'" +qa 2>&1 >/dev/null)
if echo "$ERR" | grep -q 'init_spec.lua'; then echo "repo-root rtp -> sources tests at startup (BROKEN)"; else echo "UNEXPECTED: repo-root rtp did not source tests"; fi
ERR=$(nvim --headless --clean -u NORC --cmd "let &runtimepath = '$PLUGIN_ROOT'" +qa 2>&1 >/dev/null)
if echo "$ERR" | grep -q 'init_spec.lua'; then echo "UNEXPECTED: plugin/ rtp sourced tests"; else echo "plugin/ rtp -> clean (tests not sourced)"; fi
# Expected: repo-root rtp -> 'sources tests at startup (BROKEN)'; plugin/ rtp -> 'clean'.

# 3c. End-to-end wiring: the shim's VimEnter callback actually invokes `activate`.
#     Inject a mock activate at step 17 (+, AFTER step-12 auto-source), fire VimEnter via
#     exec_autocmds, and assert the side effect. (Auto-source-before-VimEnter is proven
#     in 3a + research/notes.md TEST 1; this proves the callback → activate wiring.)
OUT=$(mktemp)
nvim --headless --clean -u NORC --cmd "let &runtimepath = '$PLUGIN_ROOT'" \
  +"lua vim.g.pi_out='$OUT'; require('pi-editor').activate = function() vim.fn.writefile({'ACTIVATED'}, vim.g.pi_out) end" \
  +"lua vim.api.nvim_exec_autocmds('VimEnter', {})" +qa 2>&1 >/dev/null
cat "$OUT" 2>/dev/null; rm -f "$OUT"
echo "   ^ Expected: ACTIVATED  (the shim's VimEnter callback invoked the mock activate)"
```

### Level 4: Creative & Domain-Specific Validation

```bash
# 4a. Dormancy / no-spam: in a session with NO PI_NVIM_BRIDGE and NO mock activate,
#     the shim sources + its VimEnter fires and produces NO pi-editor error (interim-safe).
PLUGIN_ROOT="$(pwd)/plugin"
nvim --headless --clean -u NORC --cmd "let &runtimepath = '$PLUGIN_ROOT'" \
  +"lua vim.api.nvim_exec_autocmds('VimEnter', {})" \
  +"lua print('dormant_ok=yes')" +qa 2>&1 | grep -E '^(dormant_ok|Error.*pi%-editor)' || true
# Expected: 'dormant_ok=yes' and NO line matching 'Error...pi-editor' (only the benign
#           syntax.vim warning may appear, which is unrelated — GOTCHA #11).

# 4b. Idempotency under repeated re-source (simulates :source % / plugin-manager reload).
nvim --headless --clean -u NORC --cmd "let &runtimepath = '$PLUGIN_ROOT'" \
  --cmd 'runtime plugin/pi-editor.lua' \
  --cmd 'runtime plugin/pi-editor.lua' \
  --cmd 'runtime plugin/pi-editor.lua' \
  +"lua print('after_3_resources='..#vim.api.nvim_get_autocmds({event='VimEnter',group='pi-editor'}))" +qa 2>&1 | grep '^after_3'
# Expected: after_3_resources=1  (clear=true prevents stacking)
```

## Final Validation Checklist

### Technical Validation

- [ ] Level 1 smoke test prints `SMOKE_PASS` and `exit=0`.
- [ ] Level 2 plenary spec `tests/shim_spec.lua` exits 0 (6 `it` blocks pass).
- [ ] Level 3a: auto-source registers `count=1 once=true group=pi-editor`.
- [ ] Level 3b: repo-root rtp → 'sources tests at startup (BROKEN)'; plugin/ rtp → 'clean'
      (proves GOTCHA #1 — recursive plugin sourcing sweeps tests/ unless rtp is the plugin/ subdir).
- [ ] Level 3c: end-to-end mock-activate wiring prints `ACTIVATED`.
- [ ] Level 4a: dormant session — no pi-editor error; `dormant_ok=yes`.
- [ ] Level 4b: 3× re-source → `after_3_resources=1`.
- [ ] (Optional) selene/stylua clean IF installed (NOT a hard gate).

### Feature Validation

- [ ] Exactly 1 `VimEnter` autocmd in group `pi-editor` after startup (no dupes).
- [ ] Autocmd has `once == true`, `group_name == "pi-editor"`, function `callback`.
- [ ] Mock `activate` called **exactly once** on a single VimEnter fire.
- [ ] Mock `activate` still **exactly once** after two VimEnter fires (`once = true`).
- [ ] No-activate fire does not error; process exit 0 (interim/dormant-safe — Success #5).
- [ ] Re-source leaves exactly 1 autocmd (`clear = true` idempotency).
- [ ] [Mode A] LuaCATS file-level doc-comment header present and accurate.

### Code Quality Validation

- [ ] Shim is within scope: registers autocmd + calls `activate()` only — no env-var read
      (asserted: no `vim.env`/`getenv` in source), no `setup()`, no `require` other than
      `pi-editor` (setup/bridge are code-inspection checklist items — GOTCHA #10).
- [ ] Uses `pcall(require, "pi-editor")` + `type(pi.activate) == "function"` guard
      (GOTCHA #2/#7/#8 — load-safe + absence-safe + mock-seam; documented split).
- [ ] Augroup `pi-editor` created with `clear = true`; autocmd with `once = true`.
- [ ] File at `plugin/plugin/pi-editor.lua` (runtimepath-relative `plugin/pi-editor.lua`).
- [ ] Reuses the S19 `tests/minimal_init.lua` unchanged (no duplicate harness).

### Documentation & Deployment

- [ ] [Mode A] doc-comment header documents auto-source timing, `once`/`clear`, dormancy,
      the `lazy = false` requirement, and the interim-safe guard rationale.
- [ ] No new env vars, no config files, no runtime side effects beyond the autocmd.
- [ ] (README / `doc/pi-editor.txt` are separate tasks — S43/S44, NOT this task.)

---

## Anti-Patterns to Avoid

- ❌ Don't point `runtimepath` at the repo root — it MUST be the `plugin/` SUBDIRECTORY.
  Neovim sources `<rtp>/plugin/**/*.lua` RECURSIVELY, so a repo-root rtp sweeps in
  `plugin/tests/*.lua` at startup (they error: `describe` is nil without plenary) AND sources
  the `lua/` module as a plugin script. Use `plugin/` as rtp so only `plugin/plugin/pi-editor.lua`
  is sourced and `tests/`+`lua/` stay untouched (GOTCHA #1; LIVE-VERIFIED 3/3: repo-root rtp
  → sources tests/init_spec.lua every time; plugin/ rtp → clean).
- ❌ Don't call `require("pi-editor").activate()` unconditionally — `activate` doesn't exist
  until S21; that throws on every VimEnter. Guard with `type(...) == "function"` (GOTCHA #2).
- ❌ Don't fire `VimEnter` from `--cmd` (step 3) — the autocmd isn't registered until
  step 12. Fire it from `+`/`-c` (step 17), or via `nvim_exec_autocmds` inside a `+` luafile.
- ❌ Don't omit `clear = true` on the augroup — re-sourcing stacks duplicate VimEnter
  autocmds and `activate` gets called 2×, 3×, … (GOTCHA #5).
- ❌ Don't omit `once = true` — without it, any path that fires VimEnter more than once
  would call `activate` repeatedly (GOTCHA #6).
- ❌ Don't `pcall` the `activate()` call itself — only `pcall` the `require`. Hiding
  genuine `activate` bugs makes them undebuggable; `activate`/S21+S39 own their resilience.
- ❌ Don't read `PI_NVIM_BRIDGE`, call `setup()`, or `require` bridge/health/etc. from the
  shim — those are S21 / user config / S24 / S42 (GOTCHA #10). The no-env-read rule is
  asserted by the tests (`vim.env`/`getenv` literals); setup/bridge are code-inspection items.
- ❌ Don't make validation depend on stylua/selene — they aren't installed here. The
  headless smoke test + plenary spec are the hard gates.
- ❌ Don't rely on a trailing `+qa` to "let VimEnter fire" — it quits at step 17, before
  step-19 VimEnter. Fire `VimEnter` manually (`nvim_exec_autocmds`) in tests, or quit from
  inside the callback (`cq`) (GOTCHA #4).
- ❌ Don't confuse the benign `syntax.vim E216` warning (a `--clean -u NORC` artifact,
  exit 0) with a shim failure — judge by our markers and `$?` (GOTCHA #11).
