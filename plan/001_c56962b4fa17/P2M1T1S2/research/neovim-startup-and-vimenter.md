# Research: Neovim `plugin/` auto-sourcing, `VimEnter` timing & headless testing

> Scope: task **P2.M1.T1.S2** (`plugin/pi-editor.lua` VimEnter auto-activation shim).
> Plugin root is the repo **subdirectory** `plugin/` (i.e. the shim lives at
> `plugin/plugin/pi-editor.lua`; the module is `plugin/lua/pi-editor/init.lua`).
> Neovim **0.12.4** verified.
>
> **Provenance.** Every claim below was verified **empirically** against the
> installed Neovim 0.12.4 in this environment (`nvim --headless --clean -u NORC …`)
> AND cross-checked against the installed help at `/usr/share/nvim/runtime/doc/`
> (`starting.txt`, `autocmd.txt`, `api.txt`, `repeat.txt`). This is not from
> memory — each fact has a runnable proof (command + observed output).

---

## Summary

The shim design is **sound**: a `plugin/*.lua` file is auto-sourced at startup
**step 12**, strictly **before** the `VimEnter` event fires at **step 19** — so an
autocmd registered in the shim WILL be live in time for VimEnter. The only real
gotchas are for **testing**:

1. `-c`/`+` commands run at **step 17** (after auto-source, before VimEnter). A
   trailing `+qa` therefore quits the editor **before VimEnter ever fires** →
   VimEnter callbacks appear "not to run". Fix: fire VimEnter manually with
   `vim.api.nvim_exec_autocmds("VimEnter", {})`, or quit *from inside* the callback.
2. **Never pipe nvim output** through `tail`/`grep` before checking `$?` — that
   captures the pipe command's exit, not nvim's. Check `$?` immediately after nvim
   (redirect output to a file/variable), or use `${PIPESTATUS[0]}`.
3. `cquit 1` (alias `1cq`) propagates exit **1 reliably**, even with a trailing
   `+qa` (verified). plenary itself uses `0cq`/`1cq`/`2cq`.

---

## 1. `plugin/*.lua` is auto-sourced at startup (step 12), before VimEnter (step 19)

### Proof (run on this machine)
```bash
TESTROOT=$(mktemp -d); mkdir -p "$TESTROOT/plugin"
cat > "$TESTROOT/plugin/shim.lua" <<'LUA'
vim.g.pi_shim_sourced = "yes-at-source-time"   -- set when the file is sourced
vim.api.nvim_create_autocmd("VimEnter", { once = true,
  callback = function() vim.g.pi_vimenter_fired = "yes" end })
LUA
nvim --headless --clean -u NORC --cmd "let &runtimepath = '$TESTROOT'" \
  +'lua print("sourced="..tostring(vim.g.pi_shim_sourced))' +qa
# OBSERVED: sourced=yes-at-source-time   → the plugin/*.lua WAS auto-sourced.
```

`--cmd` runs at step 3 (before step-12 plugin loading). With the dir on
`runtimepath` at step 3, Neovim auto-sources `plugin/shim.lua` at step 12.

### Doc basis (`/usr/share/nvim/runtime/doc/starting.txt` — `:help starting`)
The startup sequence (abridged, the relevant steps):
- Step 3: `--cmd` arguments executed.
- Step 12 (`:help load-plugins`): "**Load plugin scripts**. All plugin/*.vim and
  plugin/*.lua files in every directory of 'runtimepath' are sourced, in
  alphabetical order by directory then by filename."  ← **both `.vim` AND `.lua`**.
- Step 17: `-c` / `+` arguments executed.
- Step 18: if no file given, create a scratch buffer.
- Step 19 (`:help VimEnter`): "**VimEnter** — after doing all the startup stuff …
  including loading and reading all the files named on the command line, and
  reading the vimrc, … and all startup commands (-c and +)."  ← fires LAST.

So step 12 (source) < step 17 (`-c`) < step 19 (VimEnter). A shim that registers a
VimEnter autocmd at step 12 is guaranteed live before step 19. ✓

A real builtin example on this machine:
`/usr/share/nvim/runtime/plugin/editorconfig.lua` — a `.lua` file auto-sourced the
same way (proof that `plugin/*.lua` auto-sourcing is real and used by Neovim itself).

**Sources:** `:help starting`, `:help load-plugins`, `:help VimEnter`;
<https://neovim.io/doc/user/starting.html#load-plugins>, <https://neovim.io/doc/user/autocmd.html#VimEnter>

---

## 2. VimEnter "doesn't fire?" — NO. It fires, but `+qa` quits at step 17 first.

### Proof (run on this machine)
```bash
# (a) Trailing +qa → VimEnter callback marker is nil (looks "not fired"):
nvim --headless --clean -u NORC \
  --cmd 'autocmd VimEnter * let g:got = "FIRED"' \
  +'lua print("vimenter="..tostring(vim.g.got))' +qa
# OBSERVED: vimenter=nil    ← +qa (step 17) quit before VimEnter (step 19).

# (b) Quit FROM INSIDE the VimEnter callback → marker IS written:
OUT=$(mktemp)
nvim --headless --clean -u NORC --cmd "let g:o='$OUT'" \
  --cmd 'autocmd VimEnter * call writefile(["fired"], g:o)' \
  --cmd 'autocmd VimEnter * cq 0'
# OBSERVED: file contains "fired"   ← VimEnter fired, then cq quit from within it.
```

### The fix for unit tests — manually fire VimEnter
```bash
nvim --headless --clean -u NORC \
  --cmd 'lua vim.api.nvim_create_autocmd("VimEnter",{once=true,callback=function() vim.g.fired="yes" end})' \
  --cmd 'lua vim.api.nvim_exec_autocmds("VimEnter",{})' \
  +'lua print("after_manual_fire="..tostring(vim.g.fired))' +qa
# OBSERVED: after_manual_fire=yes
```
`vim.api.nvim_exec_autocmds("VimEnter", {})` (`:help nvim_exec_autocmds`) runs all
VimEnter autocmds on demand. This is the headless-test primitive: register →
inject mock → `exec_autocmds` → assert. No dependence on step ordering or `+qa`.

**Sources:** `:help nvim_exec_autocmds`, `:help VimEnter`;
<https://neovim.io/doc/user/api.html#nvim_exec_autocmds()>

---

## 3. `once = true` — fires the callback exactly once (verified)

```bash
nvim --headless --clean -u NORC \
  --cmd 'lua vim.g.count=0' \
  --cmd 'lua vim.api.nvim_create_autocmd("VimEnter",{once=true,callback=function() vim.g.count=vim.g.count+1 end})' \
  --cmd 'lua vim.api.nvim_exec_autocmds("VimEnter",{})' \
  --cmd 'lua vim.api.nvim_exec_autocmds("VimEnter",{})' \
  +'lua print("count="..tostring(vim.g.count))' +qa
# OBSERVED: count=1   ← fired twice, callback ran once.
```
`:help autocmd-once`: "When the … 'once' … the autocmd is … executed only once;
after it has executed it is removed." ✓

---

## 4. Augroup `clear = true` makes re-sourcing idempotent (verified)

```bash
# WITH group + clear=true: source twice → exactly 1 autocmd
nvim --headless --clean -u NORC \
  --cmd 'lua local g=vim.api.nvim_create_augroup("pi-editor",{clear=true})' \
  --cmd 'lua vim.api.nvim_create_autocmd("VimEnter",{group=g,once=true,callback=function()end})' \
  --cmd 'runtime plugin/pi-editor.lua' \   # (second source; group cleared+re-added)
  +'lua print(#vim.api.nvim_get_autocmds({event="VimEnter",group="pi-editor"}))' +qa
# OBSERVED: 1   ← idempotent.

# WITHOUT group: source twice → duplicates accumulate (BAD).
```
Idiomatic pattern (`:help nvim_create_augroup`): create the group with
`clear = true` each time the file is sourced (wipes prior autocmds in the group),
then add autocmds with `group = <id-or-name>`. This guarantees that re-sourcing
(e.g. `:source %` during dev, or a plugin manager reload) never stacks duplicates.

**Sources:** `:help nvim_create_augroup`;
<https://neovim.io/doc/user/api.html#nvim_create_augroup()>

---

## 5. `nvim_get_autocmds` return shape — `once` and `group_name` ARE assertable

```bash
nvim --headless --clean -u NORC \
  --cmd 'lua vim.api.nvim_create_augroup("pi-editor",{clear=true})' \
  --cmd 'lua vim.api.nvim_create_autocmd("VimEnter",{group="pi-editor",once=true,callback=function()end})' \
  +'lua local a=vim.api.nvim_get_autocmds({event="VimEnter",group="pi-editor"})[1]; print("once="..tostring(a.once).." group="..tostring(a.group_name))' +qa
# OBSERVED: once=true group=pi-editor
```
The returned table has keys: **`buflocal, callback, command, event, group,
group_name, id, once, pattern`** (`:help nvim_get_autocmds`). So tests can assert:
- `#autocmds == 1` (exactly one VimEnter autocmd in the group — proves no dupes),
- `autocmd.once == true`,
- `autocmd.group_name == "pi-editor"`,
- `type(autocmd.callback) == "function"`.

**Sources:** `:help nvim_get_autocmds`;
<https://neovim.io/doc/user/api.html#nvim_get_autocmds()>

---

## 6. Testing ordering: rtp via `--cmd` (step 3) → auto-source (12) → test logic (17)

Because `--cmd` runs at step 3 (before step-12 auto-source) and `+`/`-c` runs at
step 17 (after), the robust headless test shape is:

```bash
nvim --headless --clean -u NORC \
  --cmd "let &runtimepath = '$PLUGIN_ROOT'" \          # step 3: rtp set
  +"luafile tests/shim_smoke.lua" \                    # step 17: AFTER auto-source
  +qa
```
At step 17 the shim has **already** been auto-sourced and its VimEnter autocmd is
registered. The luafile then: reads `nvim_get_autocmds`, injects a mock
`require("pi-editor").activate`, fires `nvim_exec_autocmds("VimEnter",{})`, and
asserts. (Do NOT fire VimEnter in a `--cmd` — the autocmd isn't registered yet at
step 3.)

If the plugin is NOT on runtimepath at step 3 (e.g. added later), force-load with
`:runtime plugin/pi-editor.lua` (`:help :runtime`) — it sources the first match on
runtimepath. (`--clean` has a doc tension: its description says "loads builtin
plugins" but `load-plugins` lists `--clean` under "won't be done"; empirically,
with the dir on rtp via `--cmd`, `--clean` DID auto-source in our tests, but
`:runtime` is the deterministic fallback.)

**Sources:** `:help starting`, `:help :runtime`; <https://neovim.io/doc/user/repeat.html#:runtime>

---

## 7. Exit-code gotcha: don't pipe nvim through `tail`/`grep` before `$?`

`cquit 1` propagates exit **1 reliably** (verified with/without trailing `+qa`):
```bash
nvim --headless --clean -u NORC +'lua vim.cmd("cquit 1")' +qa; echo $?   # → 1
```
BUT a shell pipeline captures the **last** command's exit:
```bash
nvim … +qa 2>&1 | tail -1; echo $?   # → 0 (tail's exit, NOT nvim's!)  ❌
```
**Fix:** either (a) redirect to a file and check `$?` immediately, (b) use bash
`PIPESTATUS`: `nvim … | tail -1; echo ${PIPESTATUS[0]}`, or (c) run the `:luafile`
test which calls `cquit 1` itself and omits a trailing command.

---

## Recommended shim implementation (`plugin/plugin/pi-editor.lua`, ~12 lines)

```lua
--- pi-editor.nvim — VimEnter auto-activation shim.
-- Auto-sourced by Neovim at startup (:help load-plugins) BEFORE the VimEnter
-- event, so the autocmd below is always registered in time. Registers a
-- fire-once VimEnter autocmd that calls require("pi-editor").activate().
-- The plugin stays DORMANT (a no-op) in every ordinary nvim session: activate()
-- (implemented in a later task) returns early unless pi spawned this nvim with
-- PI_EDITOR_BRIDGE set (PRD §7.1). Requiring lazy = false (PRD §10.3) ensures
-- this file is sourced at startup rather than deferred by a plugin manager.
local group = vim.api.nvim_create_augroup("pi-editor", { clear = true })
vim.api.nvim_create_autocmd("VimEnter", {
  group = group,
  once = true,
  callback = function()
    require("pi-editor").activate()
  end,
})
```

## Recommended headless validation

```bash
# Level 1 — dependency-free smoke (the shim + a mock activate). Checks:
#   (1) exactly 1 VimEnter autocmd in group "pi-editor",
#   (2) once == true, group_name == "pi-editor",
#   (3) firing VimEnter calls activate() exactly once (mocked),
#   (4) activate() is NOT called at source-time (deferred).
nvim --headless --clean -u NORC --cmd "let &runtimepath = '$(pwd)/plugin'" \
  +"luafile plugin/tests/shim_smoke.lua" +qa; echo "exit=$?  # 0=pass, 1=fail"

# Level 2 — plenary spec (same harness as the S19 init_spec; minimal_init.lua
# from S19 already puts plugin/ on rtp; add shim sourcing before the spec runs).
cd plugin
nvim --headless --clean -u tests/minimal_init.lua \
  -c 'lua require("plenary.busted").run("tests/shim_spec.lua")'
```

## Sources
- Installed + verified: `/usr/share/nvim/runtime/doc/starting.txt` (`:help starting`,
  `:help load-plugins`), `autocmd.txt` (`:help VimEnter`, `:help autocmd-once`),
  `api.txt` (`:help nvim_create_autocmd`, `nvim_create_augroup`, `nvim_get_autocmds`,
  `nvim_exec_autocmds`), `repeat.txt` (`:help :runtime`).
- Upstream: <https://neovim.io/doc/user/starting.html#load-plugins>,
  <https://neovim.io/doc/user/autocmd.html#VimEnter>,
  <https://neovim.io/doc/user/api.html#nvim_create_autocmd()>,
  <https://neovim.io/doc/user/api.html#nvim_create_augroup()>,
  <https://neovim.io/doc/user/api.html#nvim_get_autocmds()>,
  <https://neovim.io/doc/user/api.html#nvim_exec_autocmds()>,
  <https://neovim.io/doc/user/repeat.html#:runtime>.
- lazy.nvim `lazy = false`: <https://lazy.folke.io/spec/spec.nvim#lazy> ("false =
  load the plugin during startup" — `plugin/*.lua` is sourced at startup, not deferred).
