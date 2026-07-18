# PRP — P2.M1.T1.S2: `plugin/pi-editor.lua` VimEnter auto-activation shim

> **Plan mapping:** task `P2.M4.T11.S20` ("plugin/pi-editor.lua VimEnter
> auto-activation shim"). It is the **second** task of P2 (`pi-editor.nvim`
> Plugin Core) and the **second** of milestone P2.M4.T11. It **depends on** the
> parallel task **S19** (`init.lua` with `setup()`/`config`/`defaults`/`bridge`)
> whose PRP is treated as a hard contract, and it **forwards** the
> `require("pi-editor").activate()` contract to task **S21** (the activation
> gate). This task creates the **wiring** only; the dormant/gate *logic* is S21.

---

## Goal

**Feature Goal**: Create the VimEnter auto-activation shim
`plugin/plugin/pi-editor.lua`. This file is **auto-sourced by Neovim at startup**
(step 12, `:help load-plugins`) and registers **exactly one** fire-once
`VimEnter` autocmd (in a `pi-editor` augroup, `clear=true` for idempotency) whose
callback calls `require("pi-editor").activate()`. Sourcing the file must be
cheap (register one autocmd — no work, no env-var reads, no `activate()` call at
source time). The plugin stays **dormant** (a runtime no-op) in ordinary nvim
sessions — that dormancy is delivered by `activate()` itself (task S21), which
returns early when `PI_EDITOR_BRIDGE` is unset.

**Deliverable** (3 files — all NEW; S19 creates the `plugin/` tree + `lua/pi-editor/init.lua` + `tests/{smoke,minimal_init,init_spec}.lua`):
- `plugin/plugin/pi-editor.lua` — the shim: a `pi-editor` augroup + one
  `VimEnter` autocmd (`once=true`) whose callback is
  `function() require("pi-editor").activate() end`. ~12 lines + [Mode A] docstring.
- `plugin/tests/shim_smoke.lua` — **plenary-FREE** standalone smoke test (the
  Level-1 gate). Sources via `:runtime`, injects a mock `activate`, fires
  `VimEnter` with `nvim_exec_autocmds`, asserts count/once/idempotency/defer.
  Uses `cquit 1` on failure (reliable exit code).
- `plugin/tests/shim_spec.lua` — plenary/busted spec (the Level-2 gate) covering
  the same behaviors via `describe`/`it`. Runs on the **S19** `minimal_init.lua`
  harness (reused, NOT modified).

**Success Definition**:
- `plugin/plugin/pi-editor.lua` sources without error and registers **exactly 1**
  `VimEnter` autocmd in group `pi-editor` with `once == true`.
- Re-sourcing the file (idempotency) still yields exactly **1** autocmd (the
  augroup `clear=true` guarantee).
- The callback is **deferred** — `activate()` is NOT called at source time.
- When `VimEnter` fires (manually, via `nvim_exec_autocmds("VimEnter",{})`),
  `require("pi-editor").activate()` is invoked **exactly once** (mock-injected);
  a second fire does NOT invoke it again (`once=true`).
- `nvim --headless --clean -u NORC … +"luafile plugin/tests/shim_smoke.lua" +qa`
  prints `PASS: pi-editor VimEnter shim smoke` and exits **0**.
- plenary `tests/shim_spec.lua` exits **0** (all `it` blocks pass).

## Why

- **Closes the activation seam.** PRD §7.1 says the plugin activates "On
  `VimEnter` (once)". This task is the literal embodiment of that trigger: a
  `plugin/*.lua` file that Neovim sources at startup and that wires `VimEnter`
  → `activate()`. Without it there is no entry point for the whole plugin.
- **Works with ANY plugin manager (or none).** Because activation is gated on the
  `PI_EDITOR_BRIDGE` env var (set only when pi spawns `$EDITOR`), the shim must
  run on **every** nvim startup — so it cannot be deferred behind a lazy event.
  A `plugin/*.lua` file sourced at startup (with `lazy=false`, PRD §10.3) is the
  only construct guaranteed to run *before* `VimEnter` regardless of whether the
  user uses lazy.nvim, packer, vim.pack, or nothing. (A `lazy=true` plugin would
  NOT source its `plugin/` file until triggered, **missing VimEnter entirely**.)
- **Clean task boundary.** S20 owns *only* the trigger wiring; S21 owns the
  *gate logic* (read env var, dormant vs activate). This keeps each task small,
  independently testable (via a mocked `activate`), and faithful to the PRD's
  per-step decomposition.
- **Integrates with the parallel extension work.** The bridge extension writes
  `process.env.PI_EDITOR_BRIDGE` (P1.M3.T8.S16, hard contract) before spawning
  `$EDITOR`; the Neovim child **inherits** that env var (Node `spawn` default).
  This shim ensures `activate()` runs on `VimEnter` — exactly when that env var
  is guaranteed present — so the chain `extension → env var → VimEnter shim →
  activate() → bridge client` is unbroken.

## What

User-visible behavior: **none directly at runtime in S20 alone** (the callback
targets `activate()`, implemented in S21). The user-visible *contract* is:

- The plugin is installed with `lazy = false` (PRD §10.3) so this file is sourced
  at startup.
- On every `VimEnter`, `require("pi-editor").activate()` is called **once**.
- In ordinary nvim sessions (S21 complete), `activate()` returns immediately
  (dormant) because `PI_EDITOR_BRIDGE` is unset — so the plugin is invisible.

Technical requirements:
- File at **`plugin/plugin/pi-editor.lua`** (the repo's plugin root is the
  **`plugin/`** subdirectory; PRD §9.2's `plugin/pi-editor.lua` is relative to
  that root — see S19's GOTCHA #1).
- Create augroup `pi-editor` with `clear = true`; register a **single** autocmd:
  `event = "VimEnter"`, `group = <id>`, `once = true`, `callback = function()
  require("pi-editor").activate() end`.
- **No** env-var reading, **no** `vim.api` buffer/window calls, **no** require of
  other pi-editor submodules, **no** error-handling/pcall here (silent
  degradation is task **S39**, P3.M10.T24 — do NOT pre-empt it). The shim is
  pure wiring.
- [Mode A] docstring at the top explaining: (a) auto-sourced at startup before
  VimEnter, (b) fire-once, (c) dormant unless pi spawned this nvim
  (`activate()`/S21 decides), (d) why `lazy=false` is required.

### Success Criteria

- [ ] `plugin/plugin/pi-editor.lua` exists and sources without error via
      `:runtime plugin/pi-editor.lua`.
- [ ] After sourcing, `nvim_get_autocmds({event="VimEnter", group="pi-editor"})`
      returns **exactly 1** autocmd.
- [ ] That autocmd has `once == true` and `group_name == "pi-editor"`.
- [ ] Sourcing the file **twice** still yields exactly 1 autocmd (idempotent).
- [ ] `activate()` is **not** called at source time (deferred to VimEnter).
- [ ] Firing `VimEnter` (via `nvim_exec_autocmds`) calls a mock-injected
      `activate()` **exactly once**; a second fire does not call it again.
- [ ] The shim contains **no** env-var read, **no** pcall, **no** buffer/window
      API calls (pure wiring — S21/S39 own the rest).
- [ ] Level-1 smoke prints `PASS: pi-editor VimEnter shim smoke`, exit 0.
- [ ] Level-2 plenary `tests/shim_spec.lua` exits 0.
- [ ] [Mode A] docstring present and explains auto-activation + dormant behavior.

## All Needed Context

### Context Completeness Check

_Passes "No Prior Knowledge":_ an implementer who has never seen this repo needs
only this PRP + the verified empirical research under `research/` + the exact
commands below. Every Neovim API (`nvim_create_augroup`, `nvim_create_autocmd`,
`nvim_get_autocmds`, `nvim_exec_autocmds`) and every startup-timing claim
(plugin auto-source step 12 < `--cmd` step 3 < `-c`/`+` step 17 < VimEnter step
19) was **verified by live `nvim --headless` runs** on this machine (0.12.4) and
cross-checked against the installed help at `/usr/share/nvim/runtime/doc/`. The
single most important non-obvious fact — that `+qa` quits at step 17 *before*
VimEnter fires at step 19, so VimEnter must be triggered manually in tests via
`nvim_exec_autocmds` — is spelled out in §Known Gotchas and embedded in every
validation command.

### Documentation & References

```yaml
# MUST READ — primary contract sources

- url: https://neovim.io/doc/user/starting.html#load-plugins
  why: "Step 12 of startup: Neovim auto-sources plugin/*.vim AND plugin/*.lua
        from every 'runtimepath' entry, BEFORE the VimEnter event (step 19). This
        is WHY a plugin/*.lua shim is the correct construct for a must-run-before-
        VimEnter activation hook."
  critical: "Both .vim AND .lua are auto-sourced (verified: a builtin
             /usr/share/nvim/runtime/plugin/editorconfig.lua relies on this).
             Auto-source happens ONCE at step 12; adding a dir to runtimepath
             AFTER startup (via -c) is TOO LATE — use --cmd (step 3) or :runtime."

- url: https://neovim.io/doc/user/autocmd.html#VimEnter
  why: "VimEnter fires at step 19, AFTER all -c/+ commands (step 17). So a
        trailing +qa quits before VimEnter fires — VimEnter callbacks appear
        'not to run' in naive headless tests."
  critical: "To test VimEnter headlessly you MUST either (a) fire it manually
             with nvim_exec_autocmds('VimEnter',{}), or (b) quit from INSIDE the
             callback. A trailing +qa alone never lets VimEnter fire."

- url: https://neovim.io/doc/user/api.html#nvim_create_autocmd()
  why: "nvim_create_autocmd(event, { group=, once=, callback= }). once=true =>
        autocmd runs once then is auto-removed (:help autocmd-once). group= makes
        it manageable + idempotent across re-sources."
  critical: "once=true is VERIFIED to prevent a second fire (callback count stays
             1 after two nvim_exec_autocmds calls)."

- url: https://neovim.io/doc/user/api.html#nvim_create_augroup()
  why: "nvim_create_augroup(name, {clear=true}) wipes prior autocmds in the group
        then you add yours. Re-sourcing the file => group cleared + re-added =>
        still exactly 1 autocmd (idempotent). WITHOUT a group, re-sourcing STACKS
        duplicates (verified: 2 sources => duplicate autocmds)."
  critical: "clear=true is the idempotency primitive. Always pair group + clear=true
             in a plugin/*.lua shim that may be re-sourced during dev."

- url: https://neovim.io/doc/user/api.html#nvim_get_autocmds()
  why: "Query registered autocmds for assertions. nvim_get_autocmds({event='VimEnter',
        group='pi-editor'}) returns a list of tables with keys: buflocal, callback,
        command, event, group, group_name, id, once, pattern."
  critical: "a[1].once and a[1].group_name ARE present and assertable (verified).
             ERRORS if the group does not exist yet — so call it AFTER sourcing."

- url: https://neovim.io/doc/user/api.html#nvim_exec_autocmds()
  why: "nvim_exec_autocmds('VimEnter', {}) manually fires all VimEnter autocmds.
        THE headless-test primitive for VimEnter (since +qa quits before step 19)."
  critical: "Respects once=true: a second call does not re-run a once-autocmd."

- url: https://neovim.io/doc/user/repeat.html#:runtime
  why: ":runtime plugin/pi-editor.lua sources the first <rtp>/plugin/pi-editor.lua.
        Used in tests to (re)source the shim deterministically, independent of
        whether step-12 auto-sourcing happened."
  critical: "Requires the plugin root on runtimepath. Idempotent when paired with
             augroup clear=true (safe to call whether or not auto-source ran)."

- url: https://lazy.folke.io/spec/spec.nvim#lazy
  why: "lazy=false means the plugin is loaded at startup (plugin/*.lua IS sourced,
        not deferred). lazy=true would skip sourcing until a trigger event — which
        would MISS VimEnter entirely."
  critical: "PRD §10.3 pins lazy=false for exactly this reason. The shim assumes
             startup sourcing; a lazy=true config breaks activation silently."

- file: plan/001_c56962b4fa17/P2M1T1S2/research/neovim-startup-and-vimenter.md
  why: "The VERIFIED empirical research for this task: every claim above has a
        runnable nvim --headless proof + observed output + doc quote. Contains the
        recommended shim implementation and the recommended headless-test approach."

- file: plan/001_c56962b4fa17/P2M1T1S1/PRP.md   # the S19 CONTRACT (parallel)
  why: "S19 creates plugin/lua/pi-editor/init.lua exposing M.setup/M.config/
        M.defaults/M.bridge. This task's shim calls require('pi-editor').activate()
        — a field S19 does NOT define (it is added by S21). S19 also creates
        plugin/tests/{smoke,minimal_init,init_spec}.lua; this task ADDS
        plugin/tests/{shim_smoke,shim_spec}.lua and REUSES minimal_init.lua."
  pattern: "Contract: require('pi-editor') returns a table; you may set .activate on
            it (mock injection for tests). The plugin root is the plugin/ subdir."

- docfile: plan/001_c56962b4fa17/prd_snapshot.md
  section: "§7.1 (activation gate), §7.2 (module layout: 'plugin/pi-editor.lua
            VimEnter auto-activation shim'), §9.2 (file layout), §10.3 (lazy=false)"
  why: "These four PRD sections ARE the source of truth for this task (reproduced
        in <selected_prd_content>). §7.1's 'On VimEnter (once)' is THIS shim's
        trigger; the env-var read inside it is activate()'s body (S21)."
```

### Current Codebase tree (relevant slice)

```bash
pi-nvim-bridge/                     # repo root (monorepo)
├── extension/                      # P1 — pi-editor-bridge (TypeScript) — COMPLETE except P1.M3
├── PRD.md
└── plan/001_c56962b4fa17/
    ├── architecture/{external_deps,system_context,research-*}.md
    └── P2M1T1S2/{PRP.md, research/neovim-startup-and-vimenter.md}
# S19 (parallel) creates: plugin/lua/pi-editor/init.lua + plugin/tests/{smoke,minimal_init,init_spec}.lua
# THIS task (S20) adds:   plugin/plugin/pi-editor.lua + plugin/tests/{shim_smoke,shim_spec}.lua
# NOTE: nvim 0.12.4 + plenary.nvim INSTALLED; stylua/selene/luarocks NOT installed.
```

### Desired Codebase tree with files to be added

```bash
plugin/                             # <-- Neovim plugin root (the runtimepath entry)
├── lua/pi-editor/
│   └── init.lua                    # (S19) setup()/config/defaults/bridge  — CONTRACT, not touched here
├── plugin/
│   └── pi-editor.lua               # NEW [S20] — VimEnter auto-activation shim  [THE deliverable]
└── tests/
    ├── smoke.lua                   # (S19) setup() smoke       — not touched
    ├── minimal_init.lua            # (S19) plenary harness     — REUSED (puts plugin/ on rtp)
    ├── init_spec.lua               # (S19) setup() spec        — not touched
    ├── shim_smoke.lua              # NEW [S20] — plenary-FREE shim smoke (Level-1 gate)
    └── shim_spec.lua               # NEW [S20] — plenary shim spec (Level-2 gate)
```

> **Why `plugin/plugin/pi-editor.lua` (double `plugin/`)?** The repo is a
> monorepo: the Neovim plugin lives in the **`plugin/`** subdirectory (this is
> the runtimepath entry — S19 GOTCHA #1). Within that plugin root, Neovim's
> convention is a **`plugin/`** folder for auto-sourced startup files. PRD §7.2
> and §9.2 list `plugin/pi-editor.lua` relative to the plugin root
> (`pi-editor.nvim/`), which maps to `plugin/plugin/pi-editor.lua` in this repo.
> This is the path S19's PRP explicitly reserves ("Later tasks add
> `plugin/plugin/pi-editor.lua` (S20)").

### Known Gotchas of our codebase & Library Quirks

```lua
-- GOTCHA #1 (THE big one) — +qa quits BEFORE VimEnter fires.
-- Startup order (:help starting): --cmd (step 3) < load-plugins/auto-source
-- plugin/*.lua (step 12) < -c/+ commands (step 17) < VimEnter (step 19).
-- So `nvim ... +"luafile test.lua" +qa` runs the luafile at step 17 and quits
-- BEFORE VimEnter (step 19) ever fires. Naive VimEnter tests therefore see the
-- callback "not run". FIX: in tests, fire VimEnter manually with
-- `vim.api.nvim_exec_autocmds("VimEnter", {})` (it runs synchronously, in-process),
-- THEN assert. (Equivalently, quit from INSIDE a real VimEnter callback — but the
-- exec_autocmds form is far easier to assert on.)

-- GOTCHA #2 — auto-source happens ONCE at step 12, using runtimepath as it is
-- at step 12. So: set rtp via `--cmd` (step 3, before step 12) for auto-source to
-- pick up the plugin; setting rtp via `-c` (step 17, after step 12) is TOO LATE
-- for auto-source (use `:runtime plugin/pi-editor.lua` to force-load instead).

-- GOTCHA #3 — `cquit 1` propagates exit 1 RELIABLY (verified with and without a
-- trailing +qa). BUT a shell PIPE captures the LAST command's exit:
--   `nvim … +qa | tail -1; echo $?`   → 0  (tail's exit, NOT nvim's!)  ❌
-- FIX: check `$?` immediately after nvim (redirect output to a file), or use
-- `${PIPESTATUS[0]}`. The smoke.lua calls `cquit 1` itself, so just check `$?`
-- right after the nvim invocation.

-- GOTCHA #4 — nvim_get_autocmds({group="pi-editor"}) ERRORS if the group does
-- not exist yet. Always SOURCE the shim first, THEN query. (In tests, wrap the
-- "absence" check in pcall if you need to assert "not registered before sourcing".)

-- GOTCHA #5 — augroup clear=true is the idempotency primitive. WITHOUT a group,
-- re-sourcing the shim STACKS duplicate VimEnter autocmds (verified). WITH
-- `group + clear=true`, N sources => exactly 1 autocmd. Always use the group.

-- GOTCHA #6 — the nil-activate() window is SAFE. Between S20 and S21,
-- require("pi-editor").activate is nil (S19's module doesn't define it). If a
-- REAL VimEnter fired now, the callback would error. BUT in every test/run path
-- here, VimEnter never auto-fires: the smoke/plenary runs quit at step 17
-- (via cquit/+qa) BEFORE step 19. The spec injects a mock activate BEFORE firing
-- VimEnter manually. S21 (the immediate next task) ships the real activate().
-- DO NOT add a pcall/guard to "fix" this — silent degradation is task S39.

-- GOTCHA #7 — runtimepath MUST be the plugin/ SUBDIRECTORY, not the repo root
-- (S19 GOTCHA #1). :runtime plugin/pi-editor.lua searches <each-rtp>/plugin/
-- pi-editor.lua; with rtp=.../plugin it finds .../plugin/plugin/pi-editor.lua.
-- With rtp=repo-root it would look for .../pi-nvim-bridge/plugin/pi-editor.lua
-- (DOES NOT EXIST) → silently sources nothing.

-- GOTCHA #8 — stylua & selene are NOT installed. Do NOT make the hard gate
-- depend on them. The PRIMARY gates are: (a) the headless smoke (exit 0), (b)
-- the plenary shim_spec (exit 0).

-- GOTCHA #9 — scope guard. This task is ONLY the shim + its tests. Do NOT:
--   read PI_EDITOR_BRIDGE or any env var (that is the S21 gate / activate() body),
--   implement activate() (S21),
--   add pcall/notify/"silent degradation" (S39),
--   create ftplugin/pi-prompt.lua (S22) or bridge.lua (S24),
--   modify S19's init.lua / smoke.lua / minimal_init.lua / init_spec.lua.
```

## Implementation Blueprint

### Implementation Tasks (ordered by dependencies)

```yaml
Task 1: CREATE plugin/plugin/pi-editor.lua   (THE deliverable)
  - CREATE directory plugin/plugin/ (first file in this repo's plugin/plugin/).
  - CONTENT (~12 lines): see "Reference implementation" below —
        local group = vim.api.nvim_create_augroup("pi-editor", { clear = true })
        vim.api.nvim_create_autocmd("VimEnter", {
          group = group, once = true,
          callback = function() require("pi-editor").activate() end,
        })
  - DOCS MODE A: a top docstring (---) explaining:
      (a) auto-sourced at startup (:help load-plugins) BEFORE VimEnter;
      (b) registers a fire-once VimEnter autocmd -> require("pi-editor").activate();
      (c) DORMANT in ordinary nvim: activate() (S21) returns early unless
          PI_EDITOR_BRIDGE is set (PRD §7.1);
      (d) requires lazy=false (PRD §10.3) so this file is sourced at startup,
          not deferred by a plugin manager.
  - NAMING: augroup "pi-editor"; the file's own name pi-editor.lua.
  - PLACEMENT: plugin/plugin/pi-editor.lua (GOTCHA #7 / S19 GOTCHA #1).
  - DO NOT add: any env-var read, any pcall, any vim.api buffer/window call, any
        require of other pi-editor submodules, any call to activate() at source
        time. Pure wiring (GOTCHA #9).

Task 2: CREATE plugin/tests/shim_smoke.lua   (plenary-FREE Level-1 gate)
  - CONTENT (see "Reference implementation"): a standalone script that:
      * computes plugin_root from its own path (debug.getinfo + fnamemodify
        ":p"/":h:h") and appends it to runtimepath (GOTCHA #7);
      * pcall-clears any prior "pi-editor" augroup for a clean slate;
      * `vim.cmd("runtime plugin/pi-editor.lua")` to source the shim (GOTCHA #2);
      * asserts: exactly 1 VimEnter autocmd in group "pi-editor"; once==true;
        group_name=="pi-editor";
      * re-sources and asserts STILL 1 autocmd (idempotency, GOTCHA #5);
      * injects a mock require("pi-editor").activate (counting closure), asserts
        it is NOT called at source time (deferred);
      * fires `vim.api.nvim_exec_autocmds("VimEnter", {})` TWICE, asserts the mock
        ran EXACTLY once (once=true, GOTCHA #1);
      * on any failure writes to stderr + `vim.cmd("cquit 1")` (reliable exit,
        GOTCHA #3); on success writes "PASS: pi-editor VimEnter shim smoke".
  - WHY: instant, dependency-free feedback (no plenary, no rtp juggling on the CLI).
  - PLACEMENT: plugin/tests/shim_smoke.lua.
  - DEPENDENCIES: Task 1 (the shim) + the S19 module (require("pi-editor")).
  - GOTCHA: do NOT inline as a `:lua <<HEREDOC` in -c/+ (E5107 on 0.12.4 — S19
        GOTCHA #10). Source via :luafile.

Task 3: CREATE plugin/tests/shim_spec.lua   (plenary/busted Level-2 gate)
  - CONTENT (see "Reference implementation"): a `describe("plugin/pi-editor.lua
        (VimEnter shim)", …)` block. before_each: pcall-delete the "pi-editor"
        augroup, reset package.loaded["pi-editor"], re-require. `it` blocks cover
        EVERY Success Criterion:
        (1) sources without error;
        (2) registers exactly 1 VimEnter autocmd in group "pi-editor";
        (3) once == true;
        (4) group_name == "pi-editor";
        (5) idempotent — source twice => still 1 autocmd;
        (6) activate() NOT called at source-time (deferred);
        (7) firing VimEnter (nvim_exec_autocmds) calls a mock activate() exactly once;
        (8) a second fire does NOT call it again (once=true).
  - Each `it` does `vim.cmd("runtime plugin/pi-editor.lua")` first (deterministic
        source; works whether or not step-12 auto-source happened).
  - ASSERTIONS: assert.are.equals (scalars/counts), assert.is_true (once),
        assert.has_no.errors (sourcing). (Verified luassert semantics in S19
        research/testing.md §3.)
  - PLACEMENT: plugin/tests/shim_spec.lua.
  - DEPENDENCIES: Task 1 (shim) + S19's minimal_init.lua (rtp harness) + the S19
        module. Runs via the SAME `require("plenary.busted").run(...)` form S19
        uses (in-process; CWD-independent).
```

### Reference implementation

```lua
-- === plugin/plugin/pi-editor.lua — THE deliverable (verbatim-OK reference) ===
--- pi-editor.nvim — VimEnter auto-activation shim.
--
-- This file is auto-sourced by Neovim at startup (:help load-plugins, startup
-- step 12), which runs strictly BEFORE the |VimEnter| event (step 19). It
-- therefore always registers its autocmd in time. It does ONE thing: wire
-- |VimEnter| to |require("pi-editor").activate()|.
--
-- Dormant by design. In every ordinary nvim session `activate()` (implemented by
-- a later task, PRD §7.1) returns immediately because the `PI_EDITOR_BRIDGE` env
-- var is unset — pi only sets it when it spawns `$EDITOR`. So this shim is an
-- invisible no-op outside of a pi-spawned edit.
--
-- Requires `lazy = false` (PRD §10.3): a lazy-loaded plugin would NOT source this
-- file at startup and would miss |VimEnter| entirely. The augroup + `clear=true`
-- makes re-sourcing (dev `:source %`, plugin-manager reload) idempotent — no
-- stacked duplicate autocmds.

local group = vim.api.nvim_create_augroup("pi-editor", { clear = true })

vim.api.nvim_create_autocmd("VimEnter", {
  group = group,
  once = true,
  callback = function()
    require("pi-editor").activate()
  end,
})
```

```lua
-- === plugin/tests/shim_smoke.lua — plenary-FREE Level-1 smoke test ===
-- Run from the REPO ROOT:
--   nvim --headless --clean -u NORC +"luafile plugin/tests/shim_smoke.lua" +qa ; echo "exit=$?"
-- Exits 0 on pass (prints "PASS: …"), 1 on any check failure (via cquit).
-- NOTE: do NOT pipe through tail/grep before checking $? (GOTCHA #3).
local me = debug.getinfo(1, "S").source:sub(2)
me = vim.fn.fnamemodify(me, ":p")                  -- absolute path of THIS file
local plugin_root = vim.fn.fnamemodify(me, ":h:h") -- .../plugin  (rtp entry — GOTCHA #7)
vim.opt.runtimepath:append(plugin_root)

local fails = 0
local function check(cond, msg)
  if not cond then io.stderr:write("FAIL: " .. msg .. "\n"); fails = fails + 1 end
end

-- Clean slate: drop any prior pi-editor augroup (pcall: may not exist yet).
pcall(vim.api.nvim_del_augroup_by_name, "pi-editor")

-- (1) Source the shim (the thing under test). Idempotent via augroup clear=true.
vim.cmd("runtime plugin/pi-editor.lua")

-- (2) Exactly one VimEnter autocmd, once=true, in group "pi-editor".
local a = vim.api.nvim_get_autocmds({ event = "VimEnter", group = "pi-editor" })
check(#a == 1, "expected exactly 1 VimEnter autocmd, got " .. #a)
check(a[1].once == true, "autocmd.once is not true")
check(a[1].group_name == "pi-editor", "wrong group_name: " .. tostring(a[1].group_name))

-- (3) Idempotent: re-source => still exactly 1 autocmd (GOTCHA #5).
vim.cmd("runtime plugin/pi-editor.lua")
local a2 = vim.api.nvim_get_autocmds({ event = "VimEnter", group = "pi-editor" })
check(#a2 == 1, "re-source created duplicates: " .. #a2 .. " autocmds")

-- (4) activate() NOT called at source-time (deferred to VimEnter).
local pi = require("pi-editor")
local calls = 0
pi.activate = function() calls = calls + 1 end   -- mock (real activate() is S21)
check(calls == 0, "activate() was called at source-time (must be deferred)")

-- (5) Firing VimEnter calls activate() EXACTLY once (GOTCHA #1: manual fire).
vim.api.nvim_exec_autocmds("VimEnter", {})
check(calls == 1, "activate() called " .. calls .. "x after 1 fire, expected 1")
vim.api.nvim_exec_autocmds("VimEnter", {})
check(calls == 1, "once=true violated: activate() called again (" .. calls .. "x)")

if fails > 0 then
  io.stderr:write(fails .. " check(s) failed\n")
  vim.cmd("cquit 1")
end
io.stdout:write("PASS: pi-editor VimEnter shim smoke\n")
```

```lua
-- === plugin/tests/shim_spec.lua — plenary/busted Level-2 spec ===
describe("plugin/pi-editor.lua (VimEnter shim)", function()
  local pi

  before_each(function()
    pcall(vim.api.nvim_del_augroup_by_name, "pi-editor") -- clean slate per test
    package.loaded["pi-editor"] = nil
    pi = require("pi-editor")
  end)

  it("sources without error", function()
    assert.has_no.errors(function()
      vim.cmd("runtime plugin/pi-editor.lua")
    end)
  end)

  it("registers exactly one VimEnter autocmd in the 'pi-editor' group", function()
    vim.cmd("runtime plugin/pi-editor.lua")
    local a = vim.api.nvim_get_autocmds({ event = "VimEnter", group = "pi-editor" })
    assert.are.equals(1, #a)
  end)

  it("registers the autocmd with once = true", function()
    vim.cmd("runtime plugin/pi-editor.lua")
    local a = vim.api.nvim_get_autocmds({ event = "VimEnter", group = "pi-editor" })
    assert.is_true(a[1].once)
  end)

  it("registers under group_name == 'pi-editor'", function()
    vim.cmd("runtime plugin/pi-editor.lua")
    local a = vim.api.nvim_get_autocmds({ event = "VimEnter", group = "pi-editor" })
    assert.are.equals("pi-editor", a[1].group_name)
  end)

  it("is idempotent: sourcing twice yields exactly one autocmd", function()
    vim.cmd("runtime plugin/pi-editor.lua")
    vim.cmd("runtime plugin/pi-editor.lua")
    local a = vim.api.nvim_get_autocmds({ event = "VimEnter", group = "pi-editor" })
    assert.are.equals(1, #a)
  end)

  it("does NOT call activate() at source-time (deferred to VimEnter)", function()
    local calls = 0
    pi.activate = function() calls = calls + 1 end
    vim.cmd("runtime plugin/pi-editor.lua")
    assert.are.equals(0, calls)
  end)

  it("calls activate() exactly once when VimEnter fires", function()
    local calls = 0
    pi.activate = function() calls = calls + 1 end
    vim.cmd("runtime plugin/pi-editor.lua")
    vim.api.nvim_exec_autocmds("VimEnter", {})
    assert.are.equals(1, calls)
  end)

  it("respects once=true: a second VimEnter fire does not re-call activate()", function()
    local calls = 0
    pi.activate = function() calls = calls + 1 end
    vim.cmd("runtime plugin/pi-editor.lua")
    vim.api.nvim_exec_autocmds("VimEnter", {})
    vim.api.nvim_exec_autocmds("VimEnter", {})
    assert.are.equals(1, calls)
  end)
end)
```

### Integration Points

```yaml
RUNTIMEPATH (Neovim):
  - the plugin/ subdirectory is the runtimepath entry (NOT the repo root) — GOTCHA #7.
    Users add it via lazy.nvim/packer/vim.pack, or symlink plugin/ as
    ~/.local/share/.../pi-editor.nvim. With lazy.nvim: lazy=false (PRD §10.3).

STARTUP (what this task adds to the startup flow):
  - step 3 (--cmd / lazy.nvim rtp setup): plugin/ is on runtimepath.
  - step 12 (load-plugins): Neovim auto-sources plugin/plugin/pi-editor.lua →
    the augroup + VimEnter autocmd are registered. NO work is done here (no env
    read, no activate() call — pure registration).
  - step 19 (VimEnter): the autocmd fires once → require("pi-editor").activate().

MODULE SURFACE (this task CONSUMES, does not define):
  - require("pi-editor").activate   — CALLED by the callback. NOT defined by S19;
    added by S21. nil until S21; tests inject a mock. (GOTCHA #6.)

FORWARD CONTRACTS (do NOT implement here — just don't break them):
  - S21 implements M.activate() (reads PI_EDITOR_BRIDGE, dormant vs activate).
    Keep the callback EXACTLY `require("pi-editor").activate()` (no args) so S21's
    signature `function M.activate()` matches.
  - S39 (silent degradation) may later wrap the callback in pcall/notify. Do NOT
    pre-empt it here.

NO DATABASE / NO NETWORK / NO CONFIG FILES / NO ENV-VAR READS in this task.
```

## Validation Loop

> **Run all commands from the REPO ROOT** (`/home/dustin/projects/pi-nvim-bridge`).
> The plugin root is `$(pwd)/plugin`. nvim 0.12.4 + plenary.nvim are installed.
> Every command below was derived from VERIFIED empirical runs (see
> `research/neovim-startup-and-vimenter.md`).

### Level 1: Syntax & Load (dependency-free, no plenary)

```bash
# 1a. The shim smoke test (THE Level-1 gate). Sources the shim, injects a mock
#     activate, fires VimEnter via nvim_exec_autocmds, asserts count/once/
#     idempotency/defer. Uses cquit(1) on failure (reliable exit code).
#     CRITICAL (GOTCHA #3): do NOT pipe through tail/grep before checking $?.
nvim --headless --clean -u NORC +"luafile plugin/tests/shim_smoke.lua" +qa
echo "exit=$?   # 0 = pass (prints 'PASS: pi-editor VimEnter shim smoke'), 1 = a check failed"
```

```bash
# 1b. (Optional, only if installed) Lua lint/format. NOT a hard gate (GOTCHA #8).
command -v selene >/dev/null && selene -q plugin/plugin plugin/tests/shim_smoke.lua plugin/tests/shim_spec.lua || echo "selene not installed (skipped; optional)"
command -v stylua >/dev/null && stylua --check plugin || echo "stylua not installed (skipped; optional)"
```

### Level 2: Unit Tests (plenary spec — reuses S19's minimal_init.lua)

```bash
# 2a. In-process plenary run (MOST ROBUST — full runtimepath control via the S19
#     minimal_init.lua; CWD-independent). Exit: 0=all pass, 1=an it failed, 2=load err.
cd plugin
nvim --headless --clean -u tests/minimal_init.lua \
  -c 'lua require("plenary.busted").run("tests/shim_spec.lua")'
echo "exit=$?"
cd ..
# Expected: exit=0. The spec prints per-test results; 8 'it' blocks should pass.

# 2b. Run BOTH S19 + S20 specs together (proves no regression / coexistence):
cd plugin
nvim --headless --clean -u tests/minimal_init.lua \
  -c 'lua require("plenary.busted").run("tests/init_spec.lua")' \
  -c 'lua require("plenary.busted").run("tests/shim_spec.lua")'
echo "exit=$?"
cd ..
# Expected: exit=0 (both suites green).
```

### Level 3: Integration (real auto-source + real VimEnter path)

```bash
# 3a. Prove the shim is AUTO-SOURCED at startup when plugin/ is on runtimepath
#     via --cmd (step 3 → auto-source at step 12). After startup the pi-editor
#     augroup + its VimEnter autocmd must already exist (we query at step 17).
PLUGIN_ROOT="$(pwd)/plugin"
nvim --headless --clean -u NORC \
  --cmd "let &runtimepath = '$PLUGIN_ROOT'" \
  +'lua local a=vim.api.nvim_get_autocmds({event="VimEnter",group="pi-editor"}); io.stdout:write("autosourced_autocmds="..#a.."\n")' \
  +qa
echo "exit=$?   # expect: autosourced_autocmds=1"
# (If this prints 0, the shim was NOT auto-sourced — check rtp points at plugin/,
#  not the repo root: GOTCHA #7.)

# 3b. Prove a REAL VimEnter (fired naturally, not via exec_autocmds) invokes
#     activate(): quit FROM INSIDE the VimEnter callback so step 19 is reached
#     (GOTCHA #1). We observe a side-effect file written by a mock activate.
OUT="$(mktemp)"
nvim --headless --clean -u NORC \
  --cmd "let &runtimepath = '$PLUGIN_ROOT'" \
  --cmd "let g:pi_out = '$OUT'" \
  --cmd 'lua vim.g.pi_out = vim.g.pi_out; require("pi-editor").activate = function() vim.fn.writefile({"VimEnter->activate fired"}, vim.g.pi_out) end' \
  --cmd 'autocmd VimEnter * cq 0'   -- reach step 19, then quit 0
echo "exit=$?"
echo "observed: $(cat "$OUT" 2>/dev/null || echo EMPTY)"
rm -f "$OUT"
# Expected: exit=0, file contains "VimEnter->activate fired".
# NOTE: this also proves the S19 module is resolvable at VimEnter time and that
#       injecting .activate on the module table is seen by the shim's callback.
```

### Level 4: Creative & Domain-Specific Validation

```bash
# 4a. Idempotency under repeated re-source (simulates `:source %` during dev or a
#     plugin-manager reload). Source the shim 5 times; assert STILL exactly 1 autocmd.
PLUGIN_ROOT="$(pwd)/plugin"
nvim --headless --clean -u NORC \
  --cmd "let &runtimepath = '$PLUGIN_ROOT'" \
  --cmd 'runtime plugin/pi-editor.lua' \
  --cmd 'runtime plugin/pi-editor.lua' \
  --cmd 'runtime plugin/pi-editor.lua' \
  --cmd 'runtime plugin/pi-editor.lua' \
  --cmd 'runtime plugin/pi-editor.lua' \
  +'lua io.stdout:write("after_5_sources="..#vim.api.nvim_get_autocmds({event="VimEnter",group="pi-editor"}).."\n")' \
  +qa
echo "exit=$?   # expect: after_5_sources=1"

# 4b. Prove the callback dispatches to the CURRENT module table (mock seen after
#     a fresh require): inject mock, fire, assert; then replace mock, fire (once
#     already consumed — must NOT re-fire), assert unchanged.
PLUGIN_ROOT="$(pwd)/plugin"
nvim --headless --clean -u NORC \
  --cmd "let &runtimepath = '$PLUGIN_ROOT'" \
  +'lua local pi=require("pi-editor"); local n=0; pi.activate=function() n=n+1 end; vim.api.nvim_exec_autocmds("VimEnter",{}); pi.activate=function() n=n+100 end; vim.api.nvim_exec_autocmds("VimEnter",{}); io.stdout:write("n="..n.."\n")' \
  +qa
echo "exit=$?   # expect: n=1  (once=true: 2nd fire did NOT call the replacement mock)"
```

## Final Validation Checklist

### Technical Validation

- [ ] Level 1 smoke prints `PASS: pi-editor VimEnter shim smoke` and `exit=0`.
- [ ] Level 2 plenary `tests/shim_spec.lua` exits 0 (8 `it` blocks pass).
- [ ] Level 2b: both `init_spec.lua` (S19) and `shim_spec.lua` (S20) pass together.
- [ ] Level 3a: auto-source at startup yields `autosourced_autocmds=1`.
- [ ] Level 3b: a natural VimEnter fires `activate()` (observed via side-effect file).
- [ ] Level 4a: 5× re-source still yields exactly 1 autocmd (idempotency).
- [ ] Level 4b: `once=true` prevents a second fire (n=1).
- [ ] (Optional) selene/stylua clean IF installed (NOT a hard gate — GOTCHA #8).

### Feature Validation

- [ ] `plugin/plugin/pi-editor.lua` sources without error.
- [ ] Exactly **1** `VimEnter` autocmd in group `pi-editor`; `once == true`;
      `group_name == "pi-editor"`.
- [ ] Re-sourcing is idempotent (still 1 autocmd).
- [ ] `activate()` is **not** called at source time (deferred to VimEnter).
- [ ] Firing `VimEnter` calls a mock `activate()` exactly once; 2nd fire no-op.
- [ ] The shim contains **no** env-var read / pcall / buffer-window API (pure wiring).
- [ ] [Mode A] docstring explains auto-activation + dormant behavior + lazy=false.

### Code Quality Validation

- [ ] Callback is EXACTLY `require("pi-editor").activate()` (no args) so S21's
      `function M.activate()` signature matches (forward contract).
- [ ] Augroup name is `"pi-editor"`; file is `plugin/plugin/pi-editor.lua`.
- [ ] No modification to S19's `init.lua` / `smoke.lua` / `minimal_init.lua` /
      `init_spec.lua` (this task only ADDS files).
- [ ] No pre-emption of S21 (activate body) or S39 (silent degradation / pcall).

### Documentation & Deployment

- [ ] [Mode A] docstring present (the docs deliverable for this task).
- [ ] No new env vars, no config files introduced by the shim itself.
- [ ] (README / `doc/pi-editor.txt` are separate tasks — S43/S44, NOT this task.)

---

## Anti-Patterns to Avoid

- ❌ Don't read `PI_EDITOR_BRIDGE` (or any env var) in the shim — that is the S21
  `activate()` gate body. The shim is pure wiring.
- ❌ Don't add a `pcall`/`notify`/"silent degradation" wrapper around the callback
  — that is task S39. Keep the callback a direct `require("pi-editor").activate()`.
- ❌ Don't implement `activate()` here — that is S21. Test it with a mock.
- ❌ Don't omit the augroup or `clear=true` — without them, re-sourcing STACKS
  duplicate VimEnter autocmds (verified; GOTCHA #5).
- ❌ Don't rely on a trailing `+qa` to "let VimEnter fire" in tests — `+qa` quits
  at step 17, BEFORE VimEnter (step 19). Fire VimEnter with
  `nvim_exec_autocmds("VimEnter", {})` (GOTCHA #1).
- ❌ Don't pipe nvim output through `tail`/`grep` before checking `$?` — that
  captures the pipe command's exit, not nvim's (GOTCHA #3).
- ❌ Don't put the file at `plugin/pi-editor.lua` (repo-root-relative) — it must be
  `plugin/plugin/pi-editor.lua` (the `plugin/` subdir is the runtimepath root;
  GOTCHA #7 / S19 GOTCHA #1).
- ❌ Don't point runtimepath at the repo root for tests — it must be the `plugin/`
  SUBDIRECTORY or `:runtime plugin/pi-editor.lua` finds nothing.
- ❌ Don't make validation depend on stylua/selene — they're not installed. The
  headless smoke + plenary spec are the hard gates (GOTCHA #8).
- ❌ Don't modify S19's files — this task only ADDS `plugin/plugin/pi-editor.lua`
  and `plugin/tests/{shim_smoke,shim_spec}.lua`.
