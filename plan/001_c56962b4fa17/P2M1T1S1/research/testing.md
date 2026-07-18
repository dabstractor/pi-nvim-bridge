# Research: Testing a standalone Neovim Lua plugin `setup()` (dependency-free headless + plenary.nvim)

> Scope: `pi-editor` plugin. Plugin root is the repo **subdirectory** `plugin/`
> (i.e. `plugin/lua/pi-editor/init.lua`). Neovim 0.12.4; plenary.nvim installed at
> `/home/dustin/.local/share/nvim/lazy/plenary.nvim`.
>
> **Provenance note.** All claims below were verified by reading the **actually
> installed** source in this environment — Neovim's own help docs under
> `/usr/share/nvim/runtime/doc/` and the plenary.nvim tree under
> `/home/dustin/.local/share/nvim/lazy/plenary.nvim`. GitHub URLs are the canonical
> upstream locations of those same files. I could read source but had **no shell
> tool** to execute `nvim`; the commands are verified against source behaviour,
> not by a live run (see Residual risks).

---

## Summary

You can smoke-test `setup()` with **zero dependencies** using
`nvim --headless --clean -u NORC`, appending the plugin dir to `runtimepath`,
`require`-ing it, and exiting non-zero via `vim.cmd('cquit 1')`. For a real test
suite, use **plenary.nvim**: a `tests/` dir of `*_spec.lua` files driven by
`require('plenary.busted').run(...)` (or `:PlenaryBustedFile`) with a
`minimal_init.lua` that puts **both** the plugin dir and plenary on `runtimepath`.
The **critical** thing this monorepo gets wrong by default: because the plugin
lives at `plugin/`, the entry on `runtimepath` must be the **`plugin/` directory
itself** (so `lua/pi-editor/init.lua` is found) — not the repo root.

---

## 1. Headless, dependency-free test of `setup()`

### Recommendation
Use `nvim --headless --clean -u NORC` so no user config or user plugins load, then
manually put the plugin on `runtimepath` and drive `setup()` from a `:lua <<EOF`
heredoc. Guard each check with an explicit `vim.cmd('cquit 1')` (equivalently
`os.exit(1)`) so a failed assertion **guarantees** a non-zero exit code — do **not**
rely on a raw Lua `assert()` throw alone, since a `-c` command error is not a
reliable exit code.

### Why these flags (verified from `:help`)
- `--headless` — "Start without UI, and do not wait for `nvim_ui_attach` … useful
  for scripting (tests)". (`:help --headless`)
- `-u NORC` — skips the user config ("nvim -u NORC can be used to skip these
  initializations without reading a file") but **keeps** plugin/syntax loading.
  (`:help -u`)
- `--clean` — "Mimics a fresh install … **Excludes user directories from
  'runtimepath'**; loads builtin plugins, unlike `-u NONE`". This guarantees your
  test sees a pristine `runtimepath` (only `$VIMRUNTIME`) so the only plugin on
  the path is the one you append. (`:help --clean`)
- `:lua <<EOF` (heredoc) — "Executes Lua script from within Vimscript"
  (`:help :lua-heredoc`).
- `:cquit` — quit Nvim with an exit code. plenary itself relies on this exact
  mechanism: `vim.cmd "0cq"` (pass), `vim.cmd "1cq"` (assertion failures),
  `vim.cmd "2cq"` (load/error). So `vim.cmd('cquit 1')` (alias `1cq`) is proven in
  this environment. (`:help cquit`; verified in `lua/plenary/busted.lua`)

### Self-contained bash (heredoc → `:lua <<EOF`, exits non-zero on failure)
```bash
#!/usr/bin/env bash
set -euo pipefail
# The plugin root is the repo SUBDIRECTORY plugin/ (it contains lua/pi-editor/).
PLUGIN_ROOT="/home/dustin/projects/pi-nvim-bridge/plugin"

nvim --headless --clean -u NORC -c "lua <<EOF
vim.opt.runtimepath:append('$PLUGIN_ROOT')   -- so require('pi-editor') resolves

local function check(cond, msg)
  if not cond then
    io.stderr:write('FAIL: ' .. msg .. '\\n')
    vim.cmd('cquit 1')   -- non-zero exit; plenary uses the equivalent '1cq'
  end
end

local ok, mod = pcall(require, 'pi-editor')
check(ok, 'require(\\'pi-editor\\') failed: ' .. tostring(mod))
local pi = ok and mod or nil

check(type(pi.setup) == 'function', 'pi-editor.setup is not a function')

pi.setup({})
check(type(pi.config) == 'table', 'config is not a table after setup({})')

-- remember defaults, then apply an override and confirm it lands in M.config
local override = { debug = true, label = 'x' }
pi.setup(vim.deepcopy(override))
check(pi.config.debug == true, 'override.debug not applied to M.config')
check(pi.config.label == 'x',    'override.label not applied to M.config')

io.stdout:write('PASS: pi-editor setup smoke test\\n')
vim.cmd('qa!')           -- clean exit 0
EOF"
echo "exit=$?"           # 0 = pass, 1 = a check failed
```

> Fallback if `vim.opt.runtimepath:append` ever fails to refresh `package.path`
> (rare; `:help lua-module-load` says setting `'runtimepath'` triggers an update):
> append directly —
> `package.path = package.path .. ';' .. '$PLUGIN_ROOT/lua/?.lua;' .. '$PLUGIN_ROOT/lua/?/init.lua'`.

**Sources**
- Neovim `:help --headless`, `:help -u`, `:help --clean`, `:help load-plugins` — <https://neovim.io/doc/user/starting.html>
- Neovim `:help :lua-heredoc`, `:help lua-commands` — <https://neovim.io/doc/user/lua.html>
- Neovim `:help cquit` — <https://neovim.io/doc/user/quickfix.html>
- Exit-code proof `0cq`/`1cq`/`2cq` — installed `lua/plenary/busted.lua` (function `mod.run`)

---

## 2. plenary.nvim test harness for a standalone plugin

### Recommendation (layout)
```
plugin/
  lua/pi-editor/init.lua          # the module under test
  tests/
    minimal_init.lua              # puts plugin + plenary on runtimepath
    init_spec.lua                 # *_spec.lua files are discovered/run
```
`*_spec.lua` is mandatory: plenary's file finder runs
`find <dir> -type f -name '*_spec.lua'` (verified in `test_harness._find_files_to_run`).

### `plugin/tests/minimal_init.lua` (exact contents)
```lua
-- Minimal init for plenary tests of pi-editor.
-- Run from the plugin/ dir (the repo subdir that contains lua/).
local plugin_root = "/home/dustin/projects/pi-nvim-bridge/plugin"
local plenary     = "/home/dustin/.local/share/nvim/lazy/plenary.nvim"

-- runtimepath MUST include the plugin/ dir itself (see §5), plus plenary:
vim.opt.runtimepath:prepend(plenary)
vim.opt.runtimepath:append(plugin_root)

-- Under --noplugin/--clean, plugin/ scripts are NOT auto-sourced, so define the
-- :PlenaryBustedFile command ourselves (matches plenary's own scripts/minimal.vim):
vim.cmd("runtime plugin/plenary.vim")
```
(For a relocatable version replace the two literals with
`debug.getinfo(1, "S").source:sub(2)` math. Note: `$MYVIMRC` is **unset** when
launched with `-u <file>`, so do not rely on it — `:help -u`.)

### Exact run command

**Primary — in-process (most robust for a monorepo subdir; full `runtimepath`
control via `minimal_init.lua`):**
```bash
cd /home/dustin/projects/pi-nvim-bridge/plugin
nvim --headless --clean \
  -u tests/minimal_init.lua \
  -c 'lua require("plenary.busted").run("tests/init_spec.lua")'
# exit 0 = pass, 1 = a test failed, 2 = load/runtime error
```
Why this is the safe choice: `require("plenary.busted")` resolves purely from
`runtimepath`'s `lua/` dirs (no need for the `:PlenaryBustedFile` user command),
and `busted.run(file)` `loadfile`s the spec in-process, so `require('pi-editor')`
uses the `runtimepath` you set in `minimal_init.lua` — independent of shell CWD.
Exit codes come from the same `0cq`/`1cq`/`2cq` logic as §1.

**Standard alternative — `:PlenaryBustedFile` (matches the conventional recipe):**
```bash
cd /home/dustin/projects/pi-nvim-bridge/plugin
nvim --headless --noplugin \
  -u tests/minimal_init.lua \
  -c 'PlenaryBustedFile tests/init_spec.lua'
```
⚠️ Two non-obvious requirements for this form, both verified in
`lua/plenary/test_harness.lua`:
1. `:PlenaryBustedFile` must be defined → `minimal_init.lua` must run
   `runtime plugin/plenary.vim` (step 12 auto-sourcing is skipped under
   `--noplugin`/`--clean`). That's why the file above includes it.
2. `PlenaryBustedFile → test_file → test_paths` **spawns a child `nvim` job**
   whose `runtimepath` is set to **`set rtp+=. , <plenary_dir>`** — i.e. the
   **current working directory**. So you **must run from the `plugin/` dir** so
   that `.` = `plugin/` and `./lua/pi-editor/init.lua` is found. (The child does
   *not* re-use your `minimal_init.lua`, because `PlenaryBustedFile` is called
   with no `minimal_init` option.)

### Real upstream reference
plenary's own `Makefile` runs its suite with exactly this pattern:
```make
test:
	nvim --headless --noplugin -u scripts/minimal.vim \
	  -c "PlenaryBustedDirectory tests/plenary/ {minimal_init = 'tests/minimal_init.vim', sequential = true}"
```
and `scripts/minimal.vim` / `tests/minimal_init.vim` are simply:
```vim
set rtp+=.
runtime plugin/plenary.vim
```
Verified verbatim in the installed tree.

**Sources**
- Installed: `lua/plenary/test_harness.lua` (`test_file`, `test_paths`,
  `_find_files_to_run`), `plugin/plenary.vim` (`:PlenaryBustedFile` definition),
  `Makefile`, `scripts/minimal.vim`, `tests/minimal_init.vim`
- Upstream: <https://github.com/nvim-lua/plenary.nvim/blob/master/lua/plenary/test_harness.lua>
- Upstream: <https://github.com/nvim-lua/plenary.nvim/blob/master/plugin/plenary.vim>
- Upstream: <https://github.com/nvim-lua/plenary.nvim/blob/master/Makefile>
- Upstream: <https://github.com/nvim-lua/plenary.nvim/blob/master/scripts/minimal.vim>

---

## 3. The `plenary.busted` / `PlenaryBustedFile` API

`require("plenary.busted")` installs these **globals** the moment it is loaded
(verified in `lua/plenary/busted.lua`, module top-level):

| Global | Purpose |
|---|---|
| `describe(desc, fn)` | group; errors captured into `results.errs` |
| `it(desc, fn)` | a test case; failures go to `results.fail` (→ exit 1) |
| `before_each(fn)` / `after_each(fn)` | run around every `it` in scope |
| `pending(desc, fn)` | skipped test |
| `assert` | **rebound to `require("luassert")`** (Luassert 1.8.0, bundled in
  plenary at `lua/luassert/`) |

Assertions come from luassert. Verified semantics in installed
`lua/luassert/assertions.lua`:
- `assert.are.same(a, b)` — **deep** comparison (`util.deepcompare`) for tables;
  use this for `M.config`. (`assert.same` is equivalent.)
- `assert.are.equals(a, b)` — **shallow** `==` comparison. (`assert.equals` is
  equivalent.)
- Also available: `assert.is_true`/`assert.True`, `assert.is_false`,
  `assert.truthy`, `assert.falsy`, `assert.has_error(fn, err)`,
  `assert.matches`, `assert.near`, `assert.unique`.
- `are`/`is`/`has`/`is_not` are just modifier namespaces (chainable,
  e.g. `assert.are_not.same`).

Exit codes (from `busted.run`): **0** = all pass, **1** = one or more `it` failed,
**2** = file failed to `loadfile` or an `errs`-level error.

### Minimal `plugin/tests/init_spec.lua`
```lua
describe("pi-editor.setup", function()
  local pi

  before_each(function()
    package.loaded["pi-editor"] = nil      -- force re-require between cases
    pi = require("pi-editor")
  end)

  it("exposes a setup() function", function()
    assert.are.equal("function", type(pi.setup))
  end)

  it("sets M.config to a table after setup({})", function()
    pi.setup({})
    assert.are.equal("table", type(pi.config))
  end)

  it("merges user options into M.config", function()
    pi.setup({ debug = true, label = "x" })
    assert.are.same({ debug = true, label = "x" }, pi.config) -- deep compare
    assert.equals(true, pi.config.debug)                      -- shallow compare
  end)
end)
```

**Sources**
- Installed: `lua/plenary/busted.lua` (`describe`/`it`/`before_each`/`after_each`/
  `pending`, `assert = require "luassert"`, exit codes `0cq`/`1cq`/`2cq`)
- Installed: `lua/luassert/assertions.lua` (`same` = deep, `equals` = `==`),
  `lua/luassert/init.lua` (Luassert 1.8.0)
- Upstream: <https://github.com/nvim-lua/plenary.nvim/blob/master/lua/plenary/busted.lua>

---

## 4. CI pattern (GitHub Actions, stable + nightly)

### Recommendation
Mirror what gitsigns.nvim / telescope.nvim do: a matrix over `stable` + `nightly`
Neovim (using `rhysd/action-setup-vim` or `JohnnyMorganz/stylua`-style setup
actions), `actions/checkout`, install OS deps if the plugin needs them, then run
the plenary suite **headless**. Key points that make CI reliable:
- Run plenary **headless** so the exit code propagates (`0` pass / `1` fail).
- `cd` into the plugin root (or pass an absolute spec path) so `runtimepath`/CWD
  resolution is deterministic (see §2 and §5).
- Treat the job as failing when `nvim ... -c '...' ; echo $?` is non-zero.

### Canonical reference workflows (the standard plenary-on-GHA pattern)
- gitsigns.nvim CI — <https://github.com/lewis6991/gitsigns.nvim/blob/main/.github/workflows/ci.yml>
  (matrix on Neovim versions; runs `make test`, which launches plenary headless
  with `test/minimal_init.lua`). Its test bootstrap —
  <https://github.com/lewis6991/gitsigns.nvim/blob/main/Makefile> and
  <https://github.com/lewis6991/gitsigns.nvim/blob/main/test/minimal_init.lua>.
- telescope.nvim CI — <https://github.com/nvim-telescope/telescope.nvim/blob/master/.github/workflows/ci.yml>
  (matrix stable/nightly; headless plenary run).

### Minimal `.github/workflows/test.yml` for `pi-editor`
```yaml
name: test
on: [push, pull_request]
jobs:
  test:
    runs-on: ubuntu-latest
    strategy:
      fail-fast: false
      matrix:
        nvim: [stable, nightly]
    steps:
      - uses: actions/checkout@v4
      - uses: rhysd/action-setup-vim@v1
        with:
          neovim: true
          version: ${{ matrix.nvim }}
      - name: Clone plenary.nvim
        run: |
          git clone --depth 1 https://github.com/nvim-lua/plenary.nvim \
            ~/.local/share/nvim/lazy/plenary.nvim
      - name: Run plenary tests (headless)
        working-directory: plugin          # plugin/ is the runtimepath root (§5)
        run: |
          nvim --headless --clean \
            -u tests/minimal_init.lua \
            -c 'lua require("plenary.busted").run("tests/init_spec.lua")'
          # busted.run exits 0/1/2 via cquit; non-zero fails the step.
```
(Exact workflow YAML above is the standard shape, adapted from gitsigns/telescope;
the plenary **mechanics** it relies on are verified locally in §2–§3.)

**Sources**
- gitsigns: <https://github.com/lewis6991/gitsigns.nvim/blob/main/.github/workflows/ci.yml>,
  <https://github.com/lewis6991/gitsigns.nvim/blob/main/test/minimal_init.lua>
- telescope: <https://github.com/nvim-telescope/telescope.nvim/blob/master/.github/workflows/ci.yml>

---

## 5. CRITICAL GOTCHA — `runtimepath` must point at `plugin/`, not the repo root

### Confirmed behaviour (`:help lua-module-load`, verified in `lua.txt`)
> "Modules are searched for under the directories specified in **'runtimepath'** …
> For a module `foo.bar`, each directory is searched for **`lua/foo/bar.lua`**, then
> **`lua/foo/bar/init.lua`**."

The worked example in the docs: if `'runtimepath'` is `foo,bar`, then
`require('mod')` searches, first-wins:
```
foo/lua/mod.lua
foo/lua/mod/init.lua
bar/lua/mod.lua
bar/lua/mod/init.lua
```
So `require('X')` resolves by looking for **`<each-rtp-entry>/lua/X.lua`** and
**`<each-rtp-entry>/lua/X/init.lua`**. (`:help lua-require` / `:help runtimepath`
describe the same mechanism; the current docs tag this section `lua-module-load`.)

### Applied to this repo (plugin lives at `plugin/`)
```
/home/dustin/projects/pi-nvim-bridge/         <- repo root
└── plugin/                                   <- THIS must be on runtimepath
    └── lua/
        └── pi-editor/
            └── init.lua                      <- require('pi-editor') must find this
```

- ✅ **Correct:** `runtimepath` contains `/home/dustin/projects/pi-nvim-bridge/plugin`
  → Nvim searches `…/plugin/lua/pi-editor.lua` (no) then
  `…/plugin/lua/pi-editor/init.lua` (**yes**) → `require('pi-editor')` resolves.
- ❌ **Wrong:** `runtimepath` contains `/home/dustin/projects/pi-nvim-bridge`
  (repo root) → Nvim searches `…/pi-nvim-bridge/lua/pi-editor/init.lua`
  (**does not exist**) → `module 'pi-editor' not found`.

So in **every** place you set the path you must use the `plugin/` directory:
- Dependency-free (§1): `vim.opt.runtimepath:append("/…/pi-nvim-bridge/plugin")`
- plenary `minimal_init.lua` (§2): `vim.opt.runtimepath:append("/…/pi-nvim-bridge/plugin")`
- `:PlenaryBustedFile` subprocess (§2): the harness runs `set rtp+=.` — so
  **`cd plugin/`** first, making `.` the correct `plugin/` entry.

### Severity
**Blocker if ignored.** Every other piece (heredoc, plenary, CI) is correct in
isolation, but if `runtimepath` points one level too high (the repo root) *or* the
`cd` lands in the repo root, `require('pi-editor')` fails with
`module 'pi-editor' not found` and **every** test errors before running.

**Sources**
- Neovim `:help lua-module-load` (`:help lua-require`), `:help runtimepath` —
  <https://neovim.io/doc/user/lua.html>
- Subprocess `set rtp+=.` — installed `lua/plenary/test_harness.lua` (`test_paths`)

---

## Gaps / next steps
- I had **no shell tool** in this subagent, so the exact commands were verified by
  reading installed source (Neovim docs + plenary) rather than by a live
  `nvim` run. First thing to do when wiring this up: run the §1 heredoc once
  `plugin/lua/pi-editor/init.lua` exists and confirm `exit=0`.
- The plugin module `plugin/lua/pi-editor/init.lua` does **not yet exist** (this is
  the bootstrap task), so `M.config`'s exact shape (defaults table, deep-merge vs
  overwrite) is assumed; adapt the override assertion in §3 to the real `setup()`
  merge semantics.
- Exact `.github/workflows/ci.yml` YAML for gitsigns/telescope was referenced by
  canonical URL but not byte-verified here; the plenary **mechanics** the CI
  depends on were verified locally.

---

## Sources
- Kept: Neovim `starting.txt` (`--headless`, `-u`, `--clean`, `load-plugins`) — <https://neovim.io/doc/user/starting.html> — defines the headless/clean startup contract
- Kept: Neovim `lua.txt` (`lua-module-load`, `:lua-heredoc`) — <https://neovim.io/doc/user/lua.html> — proves `runtimepath`/`lua/` resolution (§5) and the heredoc syntax (§1)
- Kept: plenary `lua/plenary/busted.lua` — <https://github.com/nvim-lua/plenary.nvim/blob/master/lua/plenary/busted.lua> — the actual `describe`/`it`/`before_each`/exit-code implementation (§3)
- Kept: plenary `lua/plenary/test_harness.lua` — <https://github.com/nvim-lua/plenary.nvim/blob/master/lua/plenary/test_harness.lua> — proves `PlenaryBustedFile` spawns a child with `set rtp+=.` (§2, §5)
- Kept: plenary `plugin/plenary.vim`, `Makefile`, `scripts/minimal.vim` — upstream master — real minimal-init + run-command template (§2)
- Kept: plenary `lua/luassert/assertions.lua` (Luassert 1.8.0) — `same` (deep) vs `equals` (`==`) semantics (§3)
- Kept: gitsigns.nvim / telescope.nvim CI — canonical GitHub Actions plenary matrix (§4)
- Dropped: general Neovim-testing blog posts / StackOverflow — secondary; superseded by the primary Neovim docs and plenary source above.
