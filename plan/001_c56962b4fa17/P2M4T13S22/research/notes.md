# S22 — ftplugin/pi-prompt.lua buffer setup: research & LIVE verification notes

> Subtask **P2.M4.T13.S22** — create `plugin/ftplugin/pi-prompt.lua` that sets the
> pi-prompt buffer's options, keymaps, and autocmds. Auto-sourced on the `FileType`
> event that S21's `activate()` fires by setting `vim.bo[buf].filetype = "pi-prompt"`.
> Target runtime **Neovim 0.12.4** (verified), plenary.nvim present.
>
> **Method**: every API claim below is backed by a green headless run on the installed
> Neovim (commands reproduced inline). The real `plugin/` tree was NOT modified during
> research; the deliverable is specified in the PRP.

## 1. The contract (from tasks.json `context_scope`)

`plugin/ftplugin/pi-prompt.lua` must:
- (a) **options**: `vim.bo.formatoptions:remove("t")`, `vim.bo.textwidth = 0`,
      `vim.wo.wrap = true`, `vim.wo.spell = false` (PRD §7.6).
- (b) **keymaps** (`<Tab>` trigger/accept, `<S-Tab>`, `<C-N>/<C-P>`, `<C-E>`, `<CR>`
      newline-or-accept) → functions in `completion.lua` (**placeholder callbacks
      for now** — completion.lua is S30+, NOT YET BUILT).
- (c) **buffer-local autocmds**: InsertEnter / TextChangedI / CursorMovedI →
      completion refresh.
- (d) **VimLeavePre/ExitPre** autocmd for autosave (implementation in **S38**, NOT YET
      BUILT). BufWritePre → no-op normal write.
- DOCS: [Mode A] comment block; CR inserts a newline (no Enter-to-submit in external editor).
- INPUT: current buffer (0) + config from setup() (S19). OUTPUT: pi-prompt buffer has the
  options/keymaps/autocmds; OTHER buffers/windows unaffected.

The two dependencies not-yet-built (completion.lua / autosave) are the central design
constraint: **the ftplugin must wire everything NOW and be a no-op-safe forward contract
until those modules ship.** §3–§5 cover the dispatch pattern that makes this work.

## 2. CRITICAL finding — `vim.bo[buf].formatoptions:remove("t")` DOES NOT WORK

The contract literally says `vim.bo.formatoptions:remove("t")`. That **throws** on 0.12.4:

```
vim.bo[buf].formatoptions:remove('t')
  ok=false err="attempt to call method 'remove' (a nil value)"
  type(vim.bo[buf].formatoptions)=string        <-- plain Lua string, NOT an opt object
```

`vim.bo[buf].<opt>` returns the **raw value**; `formatoptions` is a flag-string (e.g.
`"croqlt"`). Only `vim.opt`/`vim.opt_local` return the `Option` object with `:remove()`.
Verified alternatives (both green):

```lua
-- (A) opt object (buffer+window local; current buffer at ftplugin-load == pi-prompt buf):
vim.opt_local.formatoptions:remove("t")          -- WORKS (returns Option; 'croqlt' -> reordered minus t)

-- (B) raw string with captured buf (robust + explicit; preferred here for captured-buf consistency):
vim.bo[buf].formatoptions = (vim.bo[buf].formatoptions or ""):gsub("t", "")  -- 'croqlt' -> 'croql'
```

We use **(B)**: it is captured-buf-scoped (matches the keymap/autocmd style) and
deterministic (gsub preserves order; opt reorders the flag set, harmless but surprising).
This is THE load-bearing non-obvious line — flagged in PRP §Known Gotchas (mirrors S21's
"type-guard" gotcha in spirit: the literal contract API is unsafe).

## 3. ftplugin auto-sourcing — verified under `--clean -u NORC` AND via the real activate()

Built `/tmp/fttest/ftplugin/pi-prompt.lua` (`vim.g.PI_FT_RAN=1; vim.bo.textwidth=77`):

```
[rtp+setft]            RESULT ran=1 tw=77        <-- auto-sources even with NO `filetype plugin on`
[rtp+ftplugin-on+setft] RESULT ran=1 tw=77
[real-activate]        ACTIVATED ran=1 ft=pi-prompt desc=true   <-- REAL init.lua activate() -> filetype -> ftplugin
```

**Findings:**
- Neovim 0.12 `--clean` ships with filetype detection + plugin loading ON, so setting
  `vim.bo[buf].filetype = "pi-prompt"` **auto-sources** `ftplugin/pi-prompt.lua` with no
  extra `:filetype plugin on` (reliable in both tests and real pi-launched nvim).
- The **real** activation path works end-to-end: load the real `plugin/` on rtp, set
  `PI_EDITOR_BRIDGE`, fire `VimEnter` → `activate()` sets filetype → ftplugin sources.
  This is the Level-3 integration-test path (no mocking of the ftplugin mechanism).
- **Buffer identity**: inside the ftplugin, the matched buffer IS the current buffer
  (`:help filetype-plugins`: "options will be set and mappings defined … local to the
  buffer"). So `local buf = vim.api.nvim_get_current_buf()` is the pi-prompt buffer. No
  `<abuf>`/`<afile>` expansion needed (the autocmd expand-items are `<abuf>`/`<afile>`/
  `<amatch>` — there is NO `<abatch>`, corrected from the brief).

## 4. Keymap / autocmd / option registration APIs — all verified green

```lua
local buf = vim.api.nvim_get_current_buf()
local win = vim.api.nvim_get_current_win()
-- keymaps (buffer-local):
vim.keymap.set('i','<Tab>', fn, { buffer=buf, desc='...' })          -- auto-clean on :bdelete/:bwipeout
-- query: vim.api.nvim_buf_get_keymap(buf,'i') -> [{lhs='<Tab>', desc='...'}, ...]   (verified)
-- autocmds (buffer-local, in the shared 'pi-editor' group):
local g = vim.api.nvim_create_augroup('pi-editor', { clear=false })  -- clear=false: do NOT wipe S20's VimEnter autocmd
vim.api.nvim_create_autocmd('TextChangedI', { group=g, buffer=buf, callback=fn })
-- query: vim.api.nvim_get_autocmds({buffer=buf}) / ({buffer=buf, group='pi-editor'})  (verified)
-- options:
vim.bo[buf].textwidth = 0          ; vim.wo[win].wrap = true ; vim.wo[win].spell = false  (verified)
```

## 5. Idempotency & cross-buffer safety (the augroup `clear=true` GOTCHA) — verified

`nvim_create_augroup("pi-editor", {clear=true})` **defaults to clearing the WHOLE group**,
which (per the external-research subagent + `:help nvim_create_augroup()`) would **wipe
other buffers' autocmds** in the shared group — including S20's `VimEnter` autocmd. The
ftplugin runs per-buffer, so it MUST use `clear=false` for the shared group.

The idempotent, re-source-safe, cross-buffer-safe pattern (verified green):

```lua
local g = vim.api.nvim_create_augroup('pi-editor', { clear = false })
vim.api.nvim_clear_autocmds({ buffer = buf, group = 'pi-editor' })   -- narrow: only THIS buffer
vim.api.nvim_create_autocmd('TextChangedI', { group=g, buffer=buf, callback=fn })
```

Verification:
```
after 2 ftplugin sources with buffer-scoped clear: count=2  (expect 2 — NO stacking)
after clearing buf1 in group: buf2 still has=1             (expect 1 — clear is buffer-scoped)
VimEnter autocmds in 'pi-editor' before=1 after=1          (clear=false preserves S20's autocmd)
```

Buffer-local keymaps with the same `<lhs>` simply **overwrite** (idempotent) — no clear
needed; auto-cleaned on buffer delete/wipe (`:help map-buffer`).

## 6. Forward-contract dispatch — verified no-op-safe when the target module is absent

`completion.lua` (S30+) and the autosave logic (S38) do NOT exist yet. The ftplugin maps
keys / registers autocmds whose callbacks dispatch into them via a lazy-require helper:

```lua
local function dispatch(modname, fnname, buf)
  local ok, mod = pcall(require, modname)
  if not ok or type(mod) ~= "table" then return false end
  local fn = mod[fnname]
  if type(fn) ~= "function" then return false end
  local pok, handled = pcall(fn, buf)
  return pok and handled == true     -- true ONLY if the module explicitly signaled "handled"
end
```

Verified:
```
completion.trigger (absent):  outer_ok=true ret=nil    <-- no throw, returns false
completion.trigger (present): called=true              <-- stub module's fn runs once
```

This makes every keymap/autocmd a **safe no-op today** and **live the moment** S30/S38
ship — without any ftplugin edit (the forward contract is just the module+function name).

## 7. The feedkey fall-through (keys whose default must survive the placeholder phase)

`<CR>` must still insert a newline (and `<Tab>` still indent) until `completion.lua` ships.
A keymap rhs that dispatches and, on "not handled", feeds the original key with the
**`'n'` (noremap) flag** falls through to the default without recursion:

```lua
local function feedkey(k)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(k, true, true, true), "n", false)
end
-- rhs: if dispatch(...) returns false -> feedkey('<CR>') inserts a newline literally (not re-mapped)
```

`'n'` = "keys are not remappable" (`:help feedkeys()`): the fed `<CR>` does NOT re-enter the
buffer-local `<CR>` mapping. This is documented, standard Neovim behavior (the idiomatic
fall-through for keys with an essential default). (Our headless insert-mode verification
harness was flaky on feedkeys timing — `F5`/`<CR>` didn't fire in insert mode under
`startinsert`+`feedkeys 'x'`; the `'n'` no-remap PROPERTY itself is documented + used by
lazy.nvim and many plugins. The implementer confirms no-recursion by typing `<CR>` in a
real insert buffer: newline inserts exactly once.)

Uniform policy: **every** keymap dispatches; if not handled, it `feedkey`s the original
`lhs`, so the pi-prompt buffer behaves as a normal markdown buffer until completion ships.
Autocmds (refresh/autosave) are fire-and-forget (no default to preserve) → no fall-through.

## 8. Forward contracts S22 ESTABLISHES (so S30+/S38 implement to them)

- `require("pi-editor.completion")` (S30+):
  - `refresh(buf)` — InsertEnter/TextChangedI/CursorMovedI (no return contract).
  - `on_tab(buf)` → truthy if handled (trigger/accept), else fall through to Tab default (S33).
  - `on_enter(buf)` → truthy if handled (accept when menu open), else insert newline (S32).
  - `on_next(buf)`, `on_prev(buf)` → truthy if handled (S36). `<S-Tab>`/`<C-P>` → on_prev; `<C-N>` → on_next.
  - `on_dismiss(buf)` → truthy if handled (S37).
- `require("pi-editor.bridge")` (S24 owns the connection; S38 owns autosave):
  - `on_exit(buf)` — VimLeavePre/ExitPre: autosave-if-modified + send bye + close the socket.
    Gated on `config.autosave_on_exit ~= false` (default true). No return contract.

These are NOT implemented by S22 (out of scope) — only wired via `dispatch`. The dispatch
helper's `handled == true` contract is the seam.

## 9. Window-local leak (wrap/spell) — accepted for the pi single-purpose editor

`wrap`/`spell` are window-local (`:help vim.wo`), NOT buffer-scoped, so they persist when
switching buffers in the same window. The PRD (§7.1/§7.6) explicitly sets them this way and
the pi editor is a single-buffer/single-window purpose nvim instance, so the leak is
acceptable and matches the spec. Noted as a gotcha; no per-buffer re-application in v1.

## 10. API facts confirmed on Neovim 0.12.4

- `vim.bo[buf].formatoptions` → plain string (no `:remove`); `vim.opt_local.formatoptions:remove("t")` works.
- `vim.keymap.set(mode, lhs, rhs, { buffer=buf })` + `vim.api.nvim_buf_get_keymap(buf, mode)` (entries `.lhs`, `.desc`).
- `vim.api.nvim_create_autocmd(ev, { group=g, buffer=buf })` + `vim.api.nvim_get_autocmds({buffer=buf[, group=]})` + `vim.api.nvim_clear_autocmds({buffer=buf, group=g})`.
- `vim.api.nvim_create_augroup(name, {clear=false})` preserves existing group members.
- `vim.wo[win].wrap`/`.spell`, `vim.bo[buf].textwidth` — get/set verified.
- ftplugin auto-sources on filetype set under `--clean -u NORC` (no `filetype plugin on` needed).

## 11. External references (authoritative; from scout subagent + neovim docs)

- ftplugin auto-sourcing: https://neovim.io/doc/user/filetype/#filetype-plugins , `#:filetype-plugin-on` , https://neovim.io/doc/user/autocmd/#FileType
- `vim.bo`/`vim.opt_local`: https://neovim.io/doc/user/lua/#vim.bo , https://neovim.io/doc/user/lua/#vim.opt_local , https://neovim.io/doc/user/lua/#vim.opt%3Aremove()
- `formatoptions` / `fo-t`: https://neovim.io/doc/user/options/#'formatoptions' , https://neovim.io/doc/user/change/#fo-t , `'textwidth'`
- `vim.wo`/wrap/spell: https://neovim.io/doc/user/lua/#vim.wo , `#'wrap'` , `#'spell'`
- keymaps: https://neovim.io/doc/user/lua/#vim.keymap.set() , https://neovim.io/doc/user/api/#nvim_buf_get_keymap() , `#map-buffer`
- autocmds: https://neovim.io/doc/user/api/#nvim_create_autocmd() , `#nvim_create_augroup()` , `#nvim_clear_autocmds()` , `#autocmd-buflocal`
- lazy-require idiom: https://neovim.io/doc/user/lua/#require() , `#pcall()`
- feedkeys 'n': https://neovim.io/doc/user/builtin/#feedkeys()