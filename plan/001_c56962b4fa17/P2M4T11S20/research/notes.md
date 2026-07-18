# Research: S20 — `plugin/plugin/pi-editor.lua` VimEnter auto-activation shim

> Scope: **P2.M4.T11.S20** — the startup auto-source shim that registers a
> fire-once `VimEnter` autocmd calling `require("pi-editor").activate()`.
> This task ships **before** S21 (which implements `activate()`), so the shim
> MUST tolerate `activate` being absent (interim + dormant sessions).
>
> Every claim below was **LIVE-VERIFIED** against the installed Neovim **0.12.4**
> in this environment on 2025-01 (see `## Live verification transcript`).
> The canonical background research is the sibling file
> `../../P2M1T1S2/research/neovim-startup-and-vimenter.md` (read in full).

## 1. Startup ordering — why the autocmd is always registered in time

Neovim startup (`:help starting`):
- **Step 3** — `--cmd` args executed.
- **Step 12** (`:help load-plugins`) — **all** `plugin/*.vim` AND `plugin/*.lua`
  files on `runtimepath` are sourced, in alphabetical order. (A real builtin
  example lives at `/usr/share/nvim/runtime/plugin/editorconfig.lua`.)
- **Step 17** — `-c` / `+` args executed.
- **Step 19** (`:help VimEnter`) — fires LAST, after all startup + `-c`/`+`.

So a `plugin/*.lua` shim that registers a VimEnter autocmd at step 12 is
guaranteed live before step 19. **Verified**: with `plugin/` on rtp via `--cmd`,
`sourced=at-source-time` is set and exactly 1 autocmd is registered.

## 2. The runtimepath entry is the `plugin/` SUBDIRECTORY (not the repo root)

`require("pi-editor")` and auto-source both key off `runtimepath`. The repo is a
monorepo (`extension/` + `plugin/`); the **`plugin/` subdir is the runtimepath
entry**. ⇒ the shim's runtimepath-relative path is `plugin/pi-editor.lua`, which on
disk is `plugin/plugin/pi-editor.lua` from the repo root.

**CORRECTION to the S19 framing (LIVE-VERIFIED on 0.12.4):** Neovim sources
`<rtp>/plugin/**/*.lua` **RECURSIVELY** (`:help load-plugins`) — it descends into
*every* subdir under `<rtp>/plugin/`. So with rtp = repo root, `<repo>/plugin/**/*.lua`
is swept, which includes `<repo>/plugin/tests/*.lua` (init_spec.lua / smoke.lua) AND
`<repo>/plugin/lua/pi-editor/init.lua`. The DETERMINISTIC, observable breakage: the test
files get sourced at startup → `init_spec.lua` errors `attempt to call global 'describe'
(a nil value)` (busted isn't loaded outside the plenary harness) on EVERY session start.
The S19-era claim "neither auto-source works with repo-root rtp" is imprecise: the shim
*is* sourced; what breaks is that unrelated test/module files get swept in too. Verified
(3/3 runs each):

```
rtp = <repo-root>:  startup sources plugin/tests/init_spec.lua -> 'describe' error (3/3)
rtp = <repo>/plugin: clean startup, no test files sourced (3/3)
```

FIX: rtp must be the `plugin/` subdir. Then `<rtp>/plugin/**/*.lua` = just
`plugin/plugin/pi-editor.lua` (the tests/ and lua/ dirs are NOT under a `plugin/` subdir,
so they are untouched at startup), and `require("pi-editor")` resolves via
`<rtp>/lua/pi-editor/init.lua`. (Note: `require` uses Neovim's runtimepath lua-module
loader, NOT package.path — package.path stays the stock luajit path regardless of rtp.)

## 3. `once = true` fires the callback exactly once (even under manual re-fire)

`vim.api.nvim_create_autocmd("VimEnter", { once = true, ... })` runs the callback
once then removes itself. **Verified**: injecting a mock `activate` and calling
`nvim_exec_autocmds("VimEnter", {})` TWICE yields `activate_calls = 1`.

## 4. `clear = true` on the augroup makes re-sourcing idempotent

Idiomatic pattern (`:help nvim_create_augroup`): create the group with
`clear = true` each source (wipes prior autocmds in the group), then add with
`group = <name>`. **Verified**: `runtime plugin/pi-editor.lua` twice →
`after_resource_count = 1` (no duplicate stacking). Essential for `:source %`
during dev and plugin-manager reloads.

## 5. `nvim_get_autocmds` return shape — assertable keys

`nvim_get_autocmds({ event = "VimEnter", group = "pi-editor" })` returns a list
whose elements expose `event, group, group_name, id, once, pattern, callback`.
Tests assert `#list == 1`, `a[1].once == true`, `a[1].group_name == "pi-editor"`,
`type(a[1].callback) == "function"`. **Verified**.

## 6. Headless test shape: `--cmd` rtp (step 3) → auto-source (12) → `+` logic (17)

Do NOT fire `VimEnter` from a `--cmd` — it runs at step 3, BEFORE step-12
auto-source, so the autocmd isn't registered yet (the first verification attempt
hit exactly this trap). Correct shape:

```bash
nvim --headless --clean -u NORC --cmd "let &runtimepath = '$PLUGIN_ROOT'" \
  +"luafile plugin/tests/shim_smoke.lua" +qa    # + runs at step 17 (post auto-source)
```

The luafile may then inject a mock `activate` into `require("pi-editor")` and
fire `nvim_exec_autocmds("VimEnter", {})` to assert the callback ran.

## 7. Why the shim must GUARD `activate` (this task ships before S21)

The task's own CONTRACT (`tasks.json`) says: *"The autocmd callback calls
`require("pi-editor").activate()` (to be implemented in S21)."* Since S20 ships
first, an **unconditional** `require("pi-editor").activate()` would throw
`attempt to call a nil value (field 'activate')` on every VimEnter until S21
lands — breaking the "dormant / no-op in ordinary sessions" requirement badly,
and making S20 un-testable in isolation. **Verified** guarded form degrades
silently: with no `activate` present, `survived = yes`, no pi-editor error,
exit 0.

Chosen form (load-safe + absence-safe, but does NOT swallow genuine `activate`
bugs — those surface for debugging; S21/S39 own internal resilience):

```lua
callback = function()
  local ok, pi = pcall(require, "pi-editor")
  if ok and type(pi.activate) == "function" then pi.activate() end
end
```

The `type() == "function"` guard also doubles as the **mock-injection seam** the
tests use: a test sets `require("pi-editor").activate = function() ... end`, and
the shim's `pcall(require, "pi-editor")` returns the SAME cached table, so the
mock is invoked. **Verified**.

## 8. Scope boundary — what this task does NOT do

- Does NOT read `PI_EDITOR_BRIDGE` (that parsing/gating is **S21**).
- Does NOT implement `activate()` (**S21**).
- Does NOT call `setup()` (the user's config does, per PRD §10.3; `activate` /
  S21 handles `M.config == nil`).
- Does NOT create `ftplugin/pi-prompt.lua` (**S22**), `bridge.lua` (**S24**),
  or `health.lua` (**S42**).
- The shim only: (a) auto-sources at startup, (b) registers one fire-once
  VimEnter autocmd in an idempotent augroup, (c) calls `activate()` exactly once
  on VimEnter (guarded for interim/dormant safety).

## 9. Benign `--clean -u NORC` artifact to ignore

`nvim --headless --clean -u NORC …` prints a harmless warning:
`Error in /usr/share/nvim/runtime/syntax/syntax.vim: line 44: E216: No such
group or event: filetypedetect BufRead`. This is an nvim-internal filetype/syntax
init artifact under `--clean -u NORC`, NOT from our shim, and does NOT change the
exit code (still 0). Filter it out of pass/fail judgements; grep for our own
markers (`count=`, `activate_calls=`, `SMOKE_PASS`).

## Live verification transcript (nvim v0.12.4, this env)

```
TEST 1 (auto-source registers 1 once-autocmd):
  count=1 once=true group=pi-editor            ✓
TEST 2 (mock activate, fire VimEnter twice → called once):
  activate_calls=1                              ✓
TEST 3 (no activate → degrade silently):
  survived=yes  (no pi-editor error)            ✓
TEST 4 (idempotent re-source via :runtime):
  after_resource_count=1                        ✓
TEST 5 (dormant source, no env var): no pi-editor errors   ✓
```

All five behaviours hold; the shim design is sound and independently shippable.
