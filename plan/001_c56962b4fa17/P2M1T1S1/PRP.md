# PRP — P2.M1.T1.S1: `init.lua` with `setup()` and default config options

> **Plan mapping:** this is task `P2.M4.T11.S19` ("init.lua with setup() and default
> config options"). It is the **first** task of **P2** (`pi-bridge.nvim` Plugin Core,
> Neovim side, Lua). The `plugin/` directory does **not exist yet** — this task
> **bootstraps** the entire Neovim plugin tree.

---

## Goal

**Feature Goal**: Create the entry module `lua/pi-editor/init.lua` for the
`pi-bridge.nvim` plugin. It exposes `M.setup(opts)` that deep-merges a user options
table over documented defaults (using `vim.tbl_deep_extend`), stores the resolved
config on `M.config`, and exposes the documented-but-initially-nil `M.bridge`
placeholder. `require("pi-editor").setup({})` must run without error in a stock
Neovim 0.10+ (verified on 0.12.4) with **zero** external Lua dependencies.

**Deliverable** (4 files — all NEW; the `plugin/` tree is created here):
- `plugin/lua/pi-editor/init.lua` — the module: LuaCATS-typed `Config` classes,
  `M.defaults`, `M.config`, `M.bridge`, `M.setup(opts)`, `return M`.
- `plugin/tests/smoke.lua` — plenary-FREE standalone smoke test (the Level-1 gate;
  sources via `:luafile` because heredocs do NOT work in `-c`/`+` args — GOTCHA #10).
- `plugin/tests/minimal_init.lua` — plenary test harness bootstrap (puts the
  `plugin/` dir + plenary on `runtimepath`).
- `plugin/tests/init_spec.lua` — plenary/busted spec (the formal Level-2 gate)
  covering defaults, empty setup, scalar override, `false`-overrides-`true`,
  nested-dict deep merge, non-mutation of defaults, re-setup, `bridge == nil`.

**Success Definition**:
- `require("pi-editor").setup({})` returns the merged config table and sets
  `M.config`; no error in a `--clean -u NORC` Neovim.
- `M.config` after `setup({})` deep-equals `M.defaults`.
- After `setup({ debounce_ms = 50, autosave_on_exit = false, menu = { max_height = 40 } })`:
  `config.debounce_ms == 50`, `config.autosave_on_exit == false` (default `true`
  overridden), `config.menu == { max_height = 40, border = "rounded" }` (sibling
  default preserved), and `M.defaults` is **unchanged** (not mutated).
- `M.bridge == nil` (documented placeholder for PRD §7.7).
- `nvim --headless --clean -u NORC` smoke test prints `PASS` / exit 0.
- plenary spec `tests/init_spec.lua` exits 0 (all `it` blocks pass).

## Why

- **Foundation for the whole P2 plugin.** Every later module (`bridge.lua`,
  `completion.lua`, `menu.lua`, `coords.lua`, `health.lua`, the optional
  `blink_source.lua`/`cmp_source.lua`) reads its resolved config from
  `require("pi-editor").config`. Without this module there is nothing to build on.
- **Faithful to pi's UX contract (PRD §10.5 / §7.5).** The defaults
  (`menu={max_height=12,border="rounded"}`, `debounce_ms=25`, `rpc_timeout_ms=2000`,
  `autosave_on_exit=true`, `engine="builtin"`) are the tuned values that make the
  built-in completion menu feel like pi's own provider. Getting them typed and
  merged correctly here means later tasks can rely on them.
- **Pre-positions the discovery seam.** `M.bridge` is the handle that the
  optional completion-engine sources and user code use to issue RPCs (PRD §7.7).
  Declaring it now (as a typed `nil` placeholder) locks the public surface so
  `bridge.lua` (task S24) just has to *populate* it.
- **Integrates with the (parallel) extension work.** The bridge extension writes
  `process.env.PI_NVIM_BRIDGE` (task P1.M3.T8.S16, its PRP is a hard contract).
  The Neovim-side *reader* of that env var is the activation gate (task S21) —
  NOT this task. This task only owns the config table that S21 will read
  `config.env_var or "PI_NVIM_BRIDGE"` from.

## What

User-visible behavior: none directly at runtime (this is a config module). The
user-visible contract is the documented `setup()` API:

```lua
require("pi-editor").setup({
  menu = { max_height = 20, border = "double" },
  debounce_ms = 40,
  rpc_timeout_ms = 3000,
  autosave_on_exit = false, -- disable writing the pi temp file on exit
  engine = "builtin",       -- "builtin" | "blink" | "cmp"
  -- env_var = "PI_NVIM_BRIDGE", -- optional override of the discovery env var
})
```

Technical requirements:
- A module table `M` returned from `lua/pi-editor/init.lua`.
- `M.defaults` — the immutable default options (PRD §10.5 exact values).
- `M.config` — `nil` until `setup()`; the merged result afterwards.
- `M.bridge` — `nil` placeholder (populated by `bridge.lua` later).
- `M.setup(opts)` — `opts = opts or {}`; `M.config = vim.tbl_deep_extend("force", M.defaults, opts)`; return `M.config`.
- [Mode A] LuaCATS (`---@class`/`---@field`/`---@param`/`---@return`) docstrings so
  `lua-language-server` and `:help` hover show the option docs (PRD docs Mode A =
  changeset-level inline docs).

### Success Criteria

- [ ] `require("pi-editor").setup({})` does not error and returns a table.
- [ ] `M.config` deep-equals `M.defaults` after `setup({})`.
- [ ] Scalar overrides land in `M.config`; un-overridden defaults preserved.
- [ ] `autosave_on_exit = false` (a user `false`) **does** override default `true`
      (proves `"force"` semantics, not truthiness-based).
- [ ] Nested `menu = { … }` deep-merges key-by-key (sibling defaults preserved).
- [ ] `M.defaults` is **not mutated** by `setup()` with overrides.
- [ ] `M.bridge == nil` after setup.
- [ ] `setup()` returns the merged config (same table reference as `M.config`).
- [ ] `setup(nil)` does not error (the `opts = opts or {}` guard).
- [ ] Re-calling `setup()` re-merges and overwrites `M.config` cleanly.
- [ ] `nvim --headless --clean -u NORC` smoke test passes (exit 0).
- [ ] `tests/init_spec.lua` passes under plenary (exit 0).
- [ ] [Mode A] LuaCATS annotations present on `setup()` and both `Config` classes.

## All Needed Context

### Context Completeness Check

_Passes "No Prior Knowledge":_ an implementer who has never seen this repo needs
only this PRP + the verified research notes under `research/` + the exact commands
below. Every API (`vim.tbl_deep_extend`, `vim.opt.runtimepath`, plenary's
`require("plenary.busted").run`) is cited with a source URL and a runnable command.
The plugin-root-vs-repo-root `runtimepath` gotcha (the #1 cause of
`module 'pi-editor' not found`) is spelled out in §Known Gotchas and embedded in
every validation command.

### Documentation & References

```yaml
# MUST READ — primary contract sources (already in <selected_prd_content> + research/)

- url: https://neovim.io/doc/user/lua.html  # :help vim.tbl_deep_extend
  why: "Defines the merge used in setup(): 'force' = rightmost table wins at leaves;
        only dict tables merge recursively; list tables are OPAQUE; returns a NEW
        table (does not mutate inputs); errors if any table arg is nil."
  critical: "'force' is VALUE-based, not truthiness-based — a user 'false' DOES
             override a default 'true'. Must do 'opts = opts or {}' first or it throws."

- url: https://github.com/neovim/neovim/issues/23654
  why: "Confirms list/array tables are replaced wholesale (not element-merged)."
  critical: "Not a problem here ('menu' is a dict), but matters for any future
             array option — it would be fully replaced, not appended."

- url: https://github.com/LuaLS/lua-language-server/wiki/Annotations
  why: "Authoritative syntax for @---@class / @---@field / @---@param / @---@return /
        @---@type annotations used in the [Mode A] docstrings."
  critical: "Use '---@field name Type? desc' for optional fields (the '?' suffix).
             A forward type like 'pi-editor.Bridge' must NOT be used yet (bridge.lua
             does not exist) — use 'table|nil' for M.bridge in this task."

- file: plan/001_c56962b4fa17/P2M1T1S1/research/setup-pattern.md
  why: "Verified canonical setup() structure, tbl_deep_extend force/keep semantics,
        false-overrides-true proof, non-mutation guarantee, and the full LuaCATS
        annotation set (pi-editor.MenuConfig / pi-editor.Config classes)."

- file: plan/001_c56962b4fa17/P2M1T1S1/research/testing.md
  why: "VERIFIED (against installed nvim 0.12.4 docs + plenary source) commands for
        headless smoke testing AND the plenary harness. Contains the CRITICAL
        runtimepath gotcha: runtimepath must point at the 'plugin/' SUBDIRECTORY,
        NOT the repo root, or require('pi-editor') fails."

- file: plan/001_c56962b4fa17/architecture/external_deps.md
  why: "§1.1 confirms Neovim 0.12 APIs (vim.uv, vim.json, vim.api) used by LATER
        modules; §6 confirms plenary.nvim + selene/stylua as the plugin test/lint
        stack. This task touches none of those APIs — it is pure Lua tables — but
        the version floor (Neovim 0.10+) and the module path 'lua/pi-editor/' are
        pinned here."

- file: plan/001_c56962b4fa17/P1M3T8S16/PRP.md
  why: "The PARALLEL extension task that WRITES process.env.PI_NVIM_BRIDGE (a
        single-line JSON BridgeDescriptor). This plugin's activation gate (task S21,
        NOT this task) will READ that env var. Reading the S16 PRP confirms the
        field is 'serverVersion'/'0.1.0' and the env var name is 'PI_NVIM_BRIDGE'
        — which is why M.config.env_var defaults (conceptually) to that string."
  pattern: "Contract: process.env.PI_NVIM_BRIDGE is set on session_start, deleted
            on session_shutdown; descriptor is single-line JSON."

- docfile: plan/001_c56962b4fa17/prd_snapshot.md
  section: "§7.2 (module layout), §7.5 (menu.lua), §7.7 (bridge exposure), §10.5 (default setup() options)"
  why: "These four PRD sections ARE the source of truth for this task's option set
        and the M.bridge exposure requirement (reproduced verbatim in <selected_prd_content>)."
```

### Current Codebase tree (relevant slice)

```bash
pi-nvim-bridge/                  # repo root
├── extension/                   # P1 — pi-editor-bridge (TypeScript) — COMPLETE except P1.M3
│   ├── pi-editor-bridge.ts
│   ├── protocol.ts              # defines BridgeDescriptor (the env-var payload)
│   ├── connection.ts, jsonl-reader.ts
│   └── tests/*.test.ts          # node:test + jiti
├── PRD.md
└── plan/001_c56962b4fa17/
    ├── architecture/{external_deps,system_context,research-*}.md
    └── P2M1T1S1/{PRP.md, research/{setup-pattern,testing}.md}
# NOTE: there is NO plugin/ directory yet — this task creates it.
# NOTE: stylua, selene, luarocks are NOT installed (nvim 0.12.4 + plenary.nvim ARE).
```

### Desired Codebase tree with files to be added

```bash
plugin/                          # <-- Neovim plugin root (added to runtimepath as THIS dir)
├── lua/
│   └── pi-editor/
│       └── init.lua             # NEW — setup() + M.defaults + M.config + M.bridge  [THE deliverable]
└── tests/
    ├── smoke.lua                # NEW — plenary-FREE smoke test (Level-1 gate; :luafile-sourced)
    ├── minimal_init.lua         # NEW — plenary harness bootstrap (runtimepath setup)
    └── init_spec.lua            # NEW — plenary/busted spec for setup() (Level-2 gate)
```

> **Why `plugin/` and not the repo root?** The repo is a monorepo hosting BOTH the
> TypeScript extension (`extension/`) and the Neovim plugin (`plugin/`). The
> `plugin/` directory is what a user installs / symlinks onto `runtimepath`
> (PRD §9.2 calls this root `pi-bridge.nvim/`). Everything under `plugin/` mirrors
> a normal standalone plugin repo (`lua/`, `plugin/`, `ftplugin/`, `doc/`). Later
> tasks add `plugin/plugin/pi-editor.lua` (S20 VimEnter shim),
> `plugin/ftplugin/pi-prompt.lua` (S22), `plugin/lua/pi-editor/bridge.lua` (S24),
> etc.

### Known Gotchas of our codebase & Library Quirks

```lua
-- GOTCHA #1 — runtimepath MUST point at the plugin/ SUBDIRECTORY, not the repo root.
-- require('pi-editor') searches <each-rtp-entry>/lua/pi-editor.lua then /lua/pi-editor/init.lua
-- (:help lua-module-load). If runtimepath = repo root, nvim looks for
-- .../pi-nvim-bridge/lua/pi-editor/init.lua (DOES NOT EXIST) → 'module not found'.
-- CORRECT: runtimepath = .../pi-nvim-bridge/plugin → finds .../plugin/lua/pi-editor/init.lua.

-- GOTCHA #2 — vim.tbl_deep_extend ERRORS if any table arg is nil.
-- 'opts = opts or {}' is MANDATORY before the call, or setup(nil) / setup() throws.

-- GOTCHA #3 — 'force' is VALUE-based, not truthiness-based.
-- A user's autosave_on_exit = false DOES override the default true. (Good — that's
-- the whole point of a boolean option. But it also means you cannot 'unset' an
-- option by passing false; omit it instead.)

-- GOTCHA #4 — list/array tables are OPAQUE (replaced wholesale, NOT element-merged).
-- (neovim/neovim#23654.) Harmless here because 'menu' is a dict — but if a future
-- option is an array, deep_extend will REPLACE it, not append. Use merge accordingly.

-- GOTCHA #5 — vim.tbl_deep_extend does NOT mutate its arguments; it returns a NEW table.
-- So M.defaults stays pristine. (Still asserted in the spec to pin this.)

-- GOTCHA #6 — do NOT forward-reference pi-editor.Bridge as M.bridge's type.
-- bridge.lua does not exist yet (task S24). A '---@type pi-editor.Bridge' annotation
-- would be an UNRESOLVED type → lua_ls warning. Use 'table|nil' now; S24 will tighten it.

-- GOTCHA #7 — a Lua literal { key = nil } is identical to omitting the key.
-- So setup({ engine = nil }) keeps the default 'builtin' (the nil key is absent from
-- the table). This is correct/desired; just don't rely on nil to 'mean something'.

-- GOTCHA #8 — stylua & selene are NOT installed in this env.
-- Do NOT make the PRP's hard validation gate depend on them. The PRIMARY gates are:
--   (a) nvim --headless smoke test, (b) plenary spec. Both run with no extra install.
-- (Optional: 'cargo install stylua' + 'cargo install selene' if you want lint/format.)

-- GOTCHA #9 — scope guard. This task is ONLY init.lua + its tests. Do NOT create:
--   plugin/plugin/pi-editor.lua (that is S20 — the VimEnter shim),
--   plugin/ftplugin/pi-prompt.lua (S22),
--   plugin/lua/pi-editor/bridge.lua (S24),
--   and do NOT add a VimEnter autocmd inside init.lua (the gate is S21).
-- setup() is PURELY config: merge + store + return. Keeping it side-effect-free is
-- what makes it unit-testable in isolation here.

-- GOTCHA #10 — a ':lua <<HEREDOC' does NOT work inside -c / + command-line args.
-- Verified on nvim 0.12.4: `nvim ... +"lua <<LUA ... LUA"` -> E5107 'unexpected symbol
-- near <'. (The <<HEREDOC syntax only works in a sourced file / interactive typing.)
-- For multi-statement validation from the CLI, either (a) write a script and use
-- `:luafile path.lua`, or (b) pass a single -c/+ arg with semicolon-separated
-- statements. That is why plugin/tests/smoke.lua exists and is sourced via :luafile.
```

## Implementation Blueprint

### Data models and structure (LuaCATS — the [Mode A] docs)

Define these `---@class` types at the top of `init.lua` (before `local M`). They are
the single source of truth for the option shape and give `lua-language-server` hover
docs + completion. (Verified syntax: LuaLS Annotations wiki.)

```lua
---@class pi-editor.MenuConfig
---@field max_height integer Maximum visible rows in the floating completion popup.
---@field border ("none"|"single"|"double"|"rounded"|"solid"|"shadow"|string[]) Border style (nvim_open_win 'border').

---@class pi-editor.Config
---@field menu pi-editor.MenuConfig Floating-menu appearance (PRD §7.5).
---@field debounce_ms integer Ms to debounce before re-querying the bridge after a text change.
---@field rpc_timeout_ms integer Ms before a pending RPC is considered stale (supersession / cancellation).
---@field autosave_on_exit boolean Write the pi temp file on VimLeavePre if modified (PRD §7.6, §11).
---@field engine ("builtin"|"blink"|"cmp") Which completion UI engine to drive (default "builtin").
---@field env_var? string Override the bridge-descriptor env var (default "PI_NVIM_BRIDGE"; PRD §7.1).
```

> `env_var` is optional (`?`) and is **deliberately NOT in `M.defaults`** — it has no
> useful default *value* to merge (the activation gate reads it as
> `M.config.env_var or "PI_NVIM_BRIDGE"`). Keeping it out of `defaults` keeps the
> defaults table to exactly the 5 PRD §10.5 options.

### Implementation Tasks (ordered by dependencies)

```yaml
Task 1: CREATE plugin/lua/pi-editor/init.lua
  - CREATE the directory tree plugin/lua/pi-editor/ (first Lua file in the repo).
  - CONTENT: a module table `local M = {}`; the two @---@class blocks above; then:
      M.defaults = { menu = { max_height = 12, border = "rounded" },
                     debounce_ms = 25, rpc_timeout_ms = 2000,
                     autosave_on_exit = true, engine = "builtin" }   -- PRD §10.5 EXACT
      M.config = nil        ---@type pi-editor.Config|nil  (documented)
      M.bridge = nil        ---@type table|nil  (documented placeholder, PRD §7.7; GOTCHA #6)
      function M.setup(opts)
        opts = opts or {}   -- GOTCHA #2
        M.config = vim.tbl_deep_extend("force", M.defaults, opts)
        return M.config
      end
      return M
  - DOCS MODE A: @---@param opts? pi-editor.Config + @---@return pi-editor.Config on
        setup(); @---@type pi-editor.Config on M.defaults; field docstrings on both classes.
  - NAMING: module table `M`; exported fields `defaults`, `config`, `bridge`, `setup`.
  - PLACEMENT: plugin/lua/pi-editor/init.lua (so require("pi-editor") resolves).
  - DO NOT add: any autocmd, any vim.api call, any require of other pi-editor modules,
        any env-var reading. setup() is side-effect-free (GOTCHA #9).

Task 2: CREATE plugin/tests/minimal_init.lua  (plenary harness bootstrap)
  - CONTENT (exact — see Implementation Patterns below): compute plugin_root from this
        file's own path via debug.getinfo + fnamemodify ":p" then ":h:h"; read plenary
        path from $PLENARY_PATH env var with the verified local fallback; prepend
        plenary, append plugin_root to runtimepath; `vim.cmd("runtime plugin/plenary.vim")`.
  - WHY: makes BOTH run styles work headlessly (in-process .run() AND :PlenaryBustedFile).
  - PLACEMENT: plugin/tests/minimal_init.lua.

Task 3: CREATE plugin/tests/init_spec.lua  (plenary/busted spec)
  - CONTENT: a `describe("pi-editor.setup", ...)` block; `before_each` does
        `package.loaded["pi-editor"] = nil` then `require`. Cover ALL Success Criteria:
        (1) exposes setup function; (2) defaults have the spec values; (3) config nil
        before setup; (4) setup({}) → config deep-equals defaults; (5) setup(nil) no
        error; (6) scalar overrides win + siblings preserved; (7) false overrides true;
        (8) nested menu deep-merges BOTH directions; (9) defaults NOT mutated;
        (10) re-setup re-merges; (11) M.bridge == nil; (12) setup returns merged config.
  - ASSERTIONS: assert.are.same (DEEP, for tables/config), assert.are.equals (shallow,
        for scalars / type() strings), assert.is_nil / assert.is_not_nil / assert.is_false,
        assert.has_no.errors (for setup(nil)). (Verified luassert semantics in research/testing.md §3.)
  - PLACEMENT: plugin/tests/init_spec.lua.
  - DEPENDENCIES: Task 1 (the module) + Task 2 (the harness).

Task 4: CREATE plugin/tests/smoke.lua  (plenary-FREE fast smoke test — the Level-1 gate)
  - CONTENT (see Implementation Patterns): a standalone script that appends plugin_root
        (computed from its own path via debug.getinfo + fnamemodify ':p'/':h:h') to
        runtimepath, runs ~20 check(cond,msg) assertions covering every Success
        Criterion, and calls vim.cmd('cquit 1') on any failure so the process exits
        non-zero (a raw `assert` throw in -c/+ does NOT propagate a non-zero exit).
  - WHY: instant, dependency-free feedback (no plenary, no runtimepath juggling on the
        CLI). init_spec.lua remains the formal plenary suite.
  - GOTCHA: do NOT inline this as a `:lua <<HEREDOC` in a -c/+ arg — nvim rejects that
        with E5107 (GOTCHA #10). Source it via `:luafile`.
  - PLACEMENT: plugin/tests/smoke.lua.
  - DEPENDENCIES: Task 1 (the module).
```

### Implementation Patterns & Key Details

```lua
-- === plugin/lua/pi-editor/init.lua — COMPLETE reference implementation ===
-- (The implementer may ship this verbatim; it satisfies every Success Criterion.)

--- pi-bridge.nvim — entry module.
--
-- Call |setup()| once from your config to apply options:
-- >
--   require("pi-editor").setup({})
-- <
-- The plugin stays dormant unless pi spawned this Neovim with the
-- PI_NVIM_BRIDGE env var set (PRD §7.1; the activation gate lives in
-- plugin/pi-editor.lua, added by a later task). setup() itself is side-effect-free:
-- it only merges options into |M.config|.
--
-- All other modules read their resolved config from `require("pi-editor").config`.

---@class pi-editor.MenuConfig
---@field max_height integer Maximum visible rows in the floating completion popup.
---@field border ("none"|"single"|"double"|"rounded"|"solid"|"shadow"|string[]) Border style (nvim_open_win 'border').

---@class pi-editor.Config
---@field menu pi-editor.MenuConfig Floating-menu appearance (PRD §7.5).
---@field debounce_ms integer Ms to debounce before re-querying the bridge after a change.
---@field rpc_timeout_ms integer Ms before a pending RPC is considered stale (supersession).
---@field autosave_on_exit boolean Write the pi temp file on VimLeavePre if modified (PRD §7.6, §11).
---@field engine ("builtin"|"blink"|"cmp") Which completion UI engine to drive.
---@field env_var? string Override the bridge-descriptor env var (default "PI_NVIM_BRIDGE"; PRD §7.1).

local M = {}

--- Default options (PRD §10.5). Exported so :checkhealth / tests can read the
--- shipped values. Never mutated by setup() — vim.tbl_deep_extend returns a new table.
---@type pi-editor.Config
M.defaults = {
  menu = {
    max_height = 12,
    border = "rounded",
  },
  debounce_ms = 25,
  rpc_timeout_ms = 2000,
  autosave_on_exit = true,
  engine = "builtin",
}

--- Resolved configuration. `nil` until |setup()|; a `pi-editor.Config` afterwards.
---@type pi-editor.Config|nil
M.config = nil

--- Bridge client. Populated by `bridge.lua` after a successful connect + handshake;
--- `nil` before that and in dormant sessions (no PI_NVIM_BRIDGE env var). External
--- code (blink/cmp sources, user code) reads `require("pi-editor").bridge` to issue
--- RPCs (PRD §7.7). Typed `table|nil` until bridge.lua ships a concrete type.
---@type table|nil
M.bridge = nil

--- Apply user options over the defaults and store the merged result in |M.config|.
---
--- Call once from your init config:
--- >
---   require("pi-editor").setup({
---     menu = { max_height = 20 },
---     debounce_ms = 40,
---     autosave_on_exit = false,
---   })
--- <
--- Re-calling setup() re-merges and overwrites M.config (safe to re-source).
---
---@param opts? pi-editor.Config User-provided options (empty table or nil OK).
---@return pi-editor.Config The resolved, merged config (also stored as M.config).
function M.setup(opts)
  opts = opts or {}
  M.config = vim.tbl_deep_extend("force", M.defaults, opts)
  return M.config
end

return M
```

```lua
-- === plugin/tests/minimal_init.lua — plenary harness bootstrap ===
-- Run (from the plugin/ directory, OR pass absolute spec path — see Validation):
--   nvim --headless --clean -u tests/minimal_init.lua \
--     -c 'lua require("plenary.busted").run("tests/init_spec.lua")'
local me = debug.getinfo(1, "S").source:sub(2)            -- .../plugin/tests/minimal_init.lua
me = vim.fn.fnamemodify(me, ":p")                          -- absolute (GOTCHA: relative-path safety)
local plugin_root = vim.fn.fnamemodify(me, ":h:h")         -- .../plugin   (runtimepath entry — GOTCHA #1)
local plenary = os.getenv("PLENARY_PATH")
  or "/home/dustin/.local/share/nvim/lazy/plenary.nvim"    -- verified install location

vim.opt.runtimepath:prepend(plenary)                       -- so require("plenary.busted") resolves
vim.opt.runtimepath:append(plugin_root)                    -- so require("pi-editor") resolves
-- Make :PlenaryBustedFile available too (harmless for the .run() form; needed for the cmd form).
vim.cmd("runtime plugin/plenary.vim")
```

```lua
-- === plugin/tests/init_spec.lua — the spec (covers every Success Criterion) ===
describe("pi-editor.setup", function()
  local pi

  before_each(function()
    package.loaded["pi-editor"] = nil   -- force a fresh module per test
    pi = require("pi-editor")
  end)

  it("exposes a module table with setup()", function()
    assert.are.equals("table", type(pi))
    assert.are.equals("function", type(pi.setup))
  end)

  it("ships the exact PRD §10.5 defaults", function()
    assert.are.same({ max_height = 12, border = "rounded" }, pi.defaults.menu)
    assert.are.equals(25, pi.defaults.debounce_ms)
    assert.are.equals(2000, pi.defaults.rpc_timeout_ms)
    assert.is_true(pi.defaults.autosave_on_exit)
    assert.are.equals("builtin", pi.defaults.engine)
  end)

  it("config is nil before setup()", function()
    assert.is_nil(pi.config)
  end)

  it("setup({}) stores defaults verbatim in config", function()
    pi.setup({})
    assert.is_not_nil(pi.config)
    assert.are.same(pi.defaults, pi.config)
  end)

  it("setup(nil) does not error (the opts-or-{} guard)", function()
    assert.has_no.errors(function() pi.setup(nil) end)
    assert.are.same(pi.defaults, pi.config)
  end)

  it("scalar overrides win and un-overridden defaults are preserved", function()
    pi.setup({ debounce_ms = 99, rpc_timeout_ms = 5000, engine = "blink" })
    assert.are.equals(99, pi.config.debounce_ms)
    assert.are.equals(5000, pi.config.rpc_timeout_ms)
    assert.are.equals("blink", pi.config.engine)
    assert.is_true(pi.config.autosave_on_exit)             -- default preserved
    assert.are.same({ max_height = 12, border = "rounded" }, pi.config.menu) -- default preserved
  end)

  it("a user 'false' overrides a default 'true' (autosave_on_exit)", function()
    pi.setup({ autosave_on_exit = false })
    assert.is_false(pi.config.autosave_on_exit)
  end)

  it("nested menu deep-merges: override one key, keep the sibling", function()
    pi.setup({ menu = { max_height = 40 } })
    assert.are.equals(40, pi.config.menu.max_height)
    assert.are.equals("rounded", pi.config.menu.border)    -- default sibling preserved
  end)

  it("nested menu deep-merges: override the other key too", function()
    pi.setup({ menu = { border = "none" } })
    assert.are.equals("none", pi.config.menu.border)
    assert.are.equals(12, pi.config.menu.max_height)       -- default sibling preserved
  end)

  it("does NOT mutate M.defaults after a setup with overrides", function()
    pi.setup({ debounce_ms = 1, menu = { max_height = 99 } })
    assert.are.equals(25, pi.defaults.debounce_ms)
    assert.are.equals(12, pi.defaults.menu.max_height)
    assert.are.equals("rounded", pi.defaults.menu.border)
  end)

  it("re-calling setup() re-merges and overwrites config", function()
    pi.setup({ debounce_ms = 10 })
    assert.are.equals(10, pi.config.debounce_ms)
    pi.setup({ debounce_ms = 70 })
    assert.are.equals(70, pi.config.debounce_ms)
    assert.are.equals(25, pi.defaults.debounce_ms)         -- defaults still pristine
  end)

  it("exposes M.bridge as a nil placeholder (PRD §7.7)", function()
    pi.setup({})
    assert.is_nil(pi.bridge)
  end)

  it("setup() returns the merged config (same ref as M.config)", function()
    local cfg = pi.setup({ debounce_ms = 33 })
    assert.are.equals(33, cfg.debounce_ms)
    assert.are.equals(cfg, pi.config)                      -- shallow: same table object
  end)
end)
```

```lua
-- === plugin/tests/smoke.lua — standalone (plenary-FREE) smoke test for setup() ===
-- Run from the REPO ROOT:
--   nvim --headless --clean -u NORC +"luafile plugin/tests/smoke.lua" +qa ; echo exit=$?
-- Exits 0 on pass, 1 on any check failure (via cquit). Zero dependencies.
-- (The plenary suite tests/init_spec.lua is the formal Level-2 gate; this is fast feedback.)
local me = debug.getinfo(1, "S").source:sub(2)
me = vim.fn.fnamemodify(me, ":p")                  -- absolute path of THIS file
local plugin_root = vim.fn.fnamemodify(me, ":h:h") -- .../plugin  (rtp entry — GOTCHA #1)
vim.opt.runtimepath:append(plugin_root)

local fails = 0
local function check(cond, msg)
  if not cond then io.stderr:write("FAIL: " .. msg .. "\n"); fails = fails + 1 end
end

local ok, pi = pcall(require, "pi-editor")
check(ok, "require('pi-editor') failed: " .. tostring(pi))
pi = ok and pi or {}

check(type(pi.setup) == "function", "setup is not a function")
check(pi.defaults.debounce_ms == 25, "default debounce_ms")
check(pi.defaults.rpc_timeout_ms == 2000, "default rpc_timeout_ms")
check(pi.defaults.autosave_on_exit == true, "default autosave_on_exit")
check(pi.defaults.engine == "builtin", "default engine")
check(pi.defaults.menu.max_height == 12, "default menu.max_height")
check(pi.defaults.menu.border == "rounded", "default menu.border")
check(pi.config == nil, "config should be nil before setup")

pi.setup({})
check(pi.config ~= nil, "config nil after setup({})")
check(pi.config.debounce_ms == 25, "config.debounce_ms after empty setup")
check(pi.config.autosave_on_exit == true, "config.autosave_on_exit after empty setup")
check(pi.config.menu.border == "rounded", "config.menu.border after empty setup")

pi.setup({ debounce_ms = 50, autosave_on_exit = false, menu = { max_height = 40 } })
check(pi.config.debounce_ms == 50, "scalar override debounce_ms")
check(pi.config.autosave_on_exit == false, "false-overrides-true (autosave)")
check(pi.config.menu.max_height == 40, "nested override menu.max_height")
check(pi.config.menu.border == "rounded", "nested default menu.border preserved")
check(pi.defaults.debounce_ms == 25, "defaults.debounce_ms was MUTATED")
check(pi.defaults.menu.max_height == 12, "defaults.menu.max_height was MUTATED")
check(pi.bridge == nil, "bridge is not the nil placeholder")

local cfg = pi.setup({ rpc_timeout_ms = 9000 })
check(cfg.rpc_timeout_ms == 9000, "setup return value")
check(cfg == pi.config, "setup did not return the same table as M.config")

if fails > 0 then
  io.stderr:write(fails .. " check(s) failed\n")
  vim.cmd("cquit 1")
end
io.stdout:write("PASS: pi-editor setup smoke\n")
```

### Integration Points

```yaml
RUNTIMEPATH (Neovim):
  - the plugin/ subdirectory is the runtimepath entry (NOT the repo root) — GOTCHA #1.
    Users add it via packer/lazy/vim.opt.rtp, or symlink plugin/ as ~/.local/share/.../pi-bridge.nvim.
  - this task only CREATES plugin/lua/pi-editor/init.lua; it does not register anything.

MODULE SURFACE (public API, locked by this task):
  - require("pi-editor").setup(opts)   -> pi-editor.Config  (THE entry point)
  - require("pi-editor").config        -> pi-editor.Config|nil
  - require("pi-editor").defaults      -> pi-editor.Config   (immutable reference)
  - require("pi-editor").bridge        -> table|nil          (placeholder; S24 populates it)

FORWARD CONTRACTS (do NOT implement here — just don't break them):
  - S21 (activation gate) reads M.config.env_var or "PI_NVIM_BRIDGE", and other config
    fields (debounce_ms, rpc_timeout_ms, engine). Keep all field names EXACTLY as above.
  - S24 (bridge.lua) does `require("pi-editor").bridge = <client instance>`.
  - S42 (health.lua) reads M.config + M.defaults for diagnostics.

NO DATABASE / NO NETWORK / NO CONFIG FILES / NO AUTOCMDS in this task.
```

## Validation Loop

> **Run all commands from the REPO ROOT** (`/home/dustin/projects/pi-nvim-bridge`).
> The plugin root is `$(pwd)/plugin`. Commands are verified-correct against the
> installed Neovim 0.12.4 + plenary.nvim (see `research/testing.md`).

### Level 1: Syntax & Load (Immediate Feedback — dependency-free, no plenary)

```bash
# 1a. Smoke test via the deliverable plugin/tests/smoke.lua (plenary-FREE fast feedback).
#     The script sets its own runtimepath + uses cquit(1) on failure (reliable exit code).
#     Run from the REPO ROOT. NOTE: you CANNOT use a ':lua <<HEREDOC' inside -c/+ args
#     on this nvim (E5107) — that's why smoke.lua is a file sourced via :luafile (GOTCHA #10).
nvim --headless --clean -u NORC +"luafile plugin/tests/smoke.lua" +qa
echo "exit=$?   # 0 = pass (prints 'PASS: pi-editor setup smoke'), 1 = a check failed"
```

```bash
# 1b. (Optional, only if installed) Lua lint/format. NOT a hard gate (GOTCHA #8).
command -v selene >/dev/null && selene -q plugin/lua || echo "selene not installed (skipped; optional)"
command -v stylua >/dev/null && stylua --check plugin || echo "stylua not installed (skipped; optional)"
# To install (optional): cargo install stylua && cargo install selene
```

### Level 2: Unit Tests (plenary spec)

```bash
# 2a. In-process plenary run (MOST ROBUST — full runtimepath control via minimal_init.lua).
#     Exit codes: 0 = all pass, 1 = an 'it' failed, 2 = load/error.
cd plugin
nvim --headless --clean -u tests/minimal_init.lua \
  -c 'lua require("plenary.busted").run("tests/init_spec.lua")'
echo "exit=$?"
cd ..
# Expected: exit=0. The spec prints per-test results; 14 'it' blocks should pass.

# 2b. Alternative — :PlenaryBustedFile (the conventional form). MUST run from plugin/
#     because the harness subprocess does `set rtp+=.` (CWD = plugin/ → require works).
cd plugin
nvim --headless --noplugin -u tests/minimal_init.lua \
  -c 'PlenaryBustedFile tests/init_spec.lua'
echo "exit=$?"
cd ..
# Expected: exit=0. (If this errors with 'module not found', you are NOT in plugin/ —
# the subprocess rtp is CWD. Use 2a instead, which is CWD-independent.)
```

### Level 3: Integration (runtimepath + real require)

```bash
# 3a. Prove require("pi-editor") resolves ONLY when runtimepath = plugin/ (GOTCHA #1).
PLUGIN_ROOT="$(pwd)/plugin"
echo "-- runtimepath = plugin/ (CORRECT) --"
nvim --headless --clean -u NORC +"lua vim.opt.runtimepath:append('$PLUGIN_ROOT')" \
  +'lua print("found:", require("pi-editor").engine ~= nil)' +qa 2>&1 | tail -1
# Expected: found: true   (well — prints 'found: true' or similar; the require succeeds)

echo "-- runtimepath = repo root (WRONG) --"
nvim --headless --clean -u NORC +"lua vim.opt.runtimepath:append('$(pwd)')" \
  +'lua local ok=_G.pcall(require,"pi-editor"); print("require ok:", ok)' +qa 2>&1 | tail -1
# Expected: require ok: false   (proves the plugin/ subdir is the required entry)

# 3b. A realistic user-config simulation: rtp + setup() in a -u NORC session.
nvim --headless --clean -u NORC +"lua vim.opt.runtimepath:append('$PLUGIN_ROOT')" \
  +'lua require("pi-editor").setup({ menu = { border = "double" } })' \
  +'lua print("engine:", require("pi-editor").config.engine, "border:", require("pi-editor").config.menu.border)' \
  +qa 2>&1 | tail -1
# Expected: engine: builtin border: double
```

### Level 4: Creative & Domain-Specific Validation

```bash
# 4a. Prove defaults stay pristine across a full module reload (non-mutation + idempotency).
#     Two -c/+ args: the first sets runtimepath, the second is a single lua chunk with
#     semicolon-separated statements (NO heredoc — GOTCHA #10; NO control flow needed).
PLUGIN_ROOT="$(pwd)/plugin"
nvim --headless --clean -u NORC \
  +"lua vim.opt.runtimepath:append('$PLUGIN_ROOT')" \
  +'lua local p=require("pi-editor"); p.setup({debounce_ms=1}); package.loaded["pi-editor"]=nil; local p2=require("pi-editor"); io.stdout:write("defaults.debounce_ms="..p2.defaults.debounce_ms.." config="..tostring(p2.config).."\n")' \
  +qa 2>&1 | tail -1
# Expected: defaults.debounce_ms=25 config=nil
# (defaults=25 proves the earlier setup({debounce_ms=1}) did NOT poison the module's
#  defaults table across a re-require; config=nil proves a fresh require starts clean.)
```

## Final Validation Checklist

### Technical Validation

- [ ] Level 1 smoke test prints `PASS: pi-editor setup smoke` and `exit=0`.
- [ ] Level 2 plenary spec `tests/init_spec.lua` exits 0 (13 `it` blocks pass).
- [ ] Level 3a: require succeeds with rtp=`plugin/` and FAILS with rtp=repo-root.
- [ ] Level 4 re-require test confirms defaults are pristine across module reload.
- [ ] (Optional) selene/stylua clean IF installed (NOT a hard gate — GOTCHA #8).

### Feature Validation

- [ ] `require("pi-editor").setup({})` returns the merged config; `M.config` set.
- [ ] `M.config` deep-equals `M.defaults` after `setup({})`.
- [ ] Scalar overrides land; un-overridden defaults preserved.
- [ ] `autosave_on_exit = false` overrides default `true` (Success Criterion #4).
- [ ] Nested `menu` deep-merges in both key directions; `M.defaults` never mutated.
- [ ] `M.bridge == nil`; `setup(nil)` does not error; re-`setup()` re-merges.
- [ ] `setup()` returns the merged config (same ref as `M.config`).
- [ ] [Mode A] LuaCATS annotations on `setup()` + `pi-editor.Config` + `pi-editor.MenuConfig`.

### Code Quality Validation

- [ ] `setup()` is side-effect-free (no autocmds, no vim.api, no other requires) — GOTCHA #9.
- [ ] Public field names are EXACTLY `setup`/`config`/`defaults`/`bridge` (forward contracts).
- [ ] Defaults are EXACTLY the PRD §10.5 values (`menu={max_height=12,border="rounded"}`,
      `debounce_ms=25`, `rpc_timeout_ms=2000`, `autosave_on_exit=true`, `engine="builtin"`).
- [ ] `M.bridge` typed `table|nil` (NOT a forward `pi-editor.Bridge` reference — GOTCHA #6).
- [ ] `plugin/` is the runtimepath root; `lua/pi-editor/init.lua` is the module path.

### Documentation & Deployment

- [ ] [Mode A] LuaCATS docstrings present (the docs deliverable for this task).
- [ ] No new env vars, no config files, no runtime side effects introduced.
- [ ] (README / `doc/pi-editor.txt` are separate tasks — S43/S44, NOT this task.)

---

## Anti-Patterns to Avoid

- ❌ Don't point `runtimepath` at the repo root — it must be the `plugin/` SUBDIRECTORY
  (GOTCHA #1) or `require("pi-editor")` fails with "module not found".
- ❌ Don't call `vim.tbl_deep_extend` before `opts = opts or {}` — a `nil` arg throws.
- ❌ Don't reimplement "merge" by hand or use `vim.tbl_extend` (shallow!) — use
  `vim.tbl_deep_extend("force", defaults, opts)` so nested `menu` merges key-by-key.
- ❌ Don't add a VimEnter autocmd / activation gate / bridge require inside `init.lua` —
  those are tasks S20/S21/S24. setup() is PURELY config (GOTCHA #9).
- ❌ Don't forward-reference `pi-editor.Bridge` as `M.bridge`'s type — `bridge.lua`
  doesn't exist yet; use `table|nil` (GOTCHA #6).
- ❌ Don't mutate `M.defaults` (it won't happen via `tbl_deep_extend`, but don't write
  code that does) — tests pin it as pristine.
- ❌ Don't put `env_var` in `M.defaults` — it's an optional override; the activation
  gate (S21) reads `M.config.env_var or "PI_NVIM_BRIDGE"`.
- ❌ Don't make validation depend on stylua/selene — they're not installed here. The
  headless smoke test + plenary spec are the hard gates (GOTCHA #8).
- ❌ Don't skip the `setup(nil)` / re-`setup()` / non-mutation test cases — those pin
  the behaviors future tasks (and users reloading their config) depend on.
