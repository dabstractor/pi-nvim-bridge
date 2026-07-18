---
name: "P2.M4.T13.S22 — ftplugin/pi-prompt.lua: buffer-local options, keymaps & autocmds"
description: |
  **CREATE `plugin/ftplugin/pi-prompt.lua`** — the buffer-setup script auto-sourced on the
  `FileType` event that S21's `activate()` fires by setting `vim.bo[buf].filetype = "pi-prompt"`.
  It is the handshake target S21 deliberately deferred ("Setting the filetype is this gate's
  ONLY buffer mutation; it is the handshake to S22"). This task owns the WHOLE buffer-local
  surface of a pi prompt: (a) the editing **options** (`formatoptions` minus `t`, `textwidth=0`,
  window `wrap=true`, `spell=false`), (b) the insert-mode **keymaps** (`<Tab>` trigger/accept,
  `<S-Tab>`/`<C-P>` prev, `<C-N>` next, `<C-E>` dismiss, `<CR>` newline-or-accept), and (c) the
  buffer-local **autocmds** (InsertEnter/TextChangedI/CursorMovedI → completion refresh;
  VimLeavePre/ExitPre → autosave+teardown).
  CENTRAL CONSTRAINT: `completion.lua` (S30+) and the autosave logic (S38) DO NOT EXIST yet.
  So every keymap/autocmd callback is a **no-op-safe forward contract** — a lazy-require
  `dispatch()` helper that `pcall`s `require("pi-editor.completion")` / `require("pi-editor.bridge")`
  and silently returns when the module (or function) is absent. The pi-prompt buffer therefore
  behaves as a normal markdown buffer TODAY and goes live the moment S30/S38 ship — with NO
  ftplugin edit (the contract is just module+function names, established here). Keys whose
  default must survive the placeholder phase (`<CR>` newline, `<Tab>` indent) **fall through to
  the default** via `nvim_feedkeys(keys, "n", false)` when the module signals "not handled".
  STATUS (planning): every API (`vim.bo[buf].formatoptions`, `vim.keymap.set` `buffer=`,
  `nvim_create_autocmd` `buffer=`/`group=`, `nvim_clear_autocmds` buffer-scoped, the augroup
  `clear=false` preservation of S20's VimEnter autocmd, the dispatch no-op safety, ftplugin
  auto-sourcing under `--clean`) is LIVE-VERIFIED against Neovim 0.12.4 — see `research/notes.md`.
  NARROW scope guard — this task does NOT: implement completion.lua/**S30+** (refresh/on_tab/
  on_enter/on_next/on_prev/on_dismiss are wired-to placeholders), implement autosave/**S38**
  (`bridge.on_exit` is a wired-to placeholder), build bridge.lua/**S24** (it will PROVIDE
  `on_exit`), build menu.lua/**S34+**, coords.lua/**S28**, or health.lua/**S42**. S22 only
  W I R E S the buffer-local surface; the behavior lives in those later modules.
---

## Goal

**Feature Goal**: Create `plugin/ftplugin/pi-prompt.lua` — the buffer-setup script that turns the
pi temp-file buffer into a properly-configured pi prompt: correct editing options, the completion
keymap set, and the completion/autosave autocmds. It is auto-sourced on `FileType` (the event
S21's `activate()` fires by setting `vim.bo[buf].filetype = "pi-prompt"` — LIVE-VERIFIED to source
the ftplugin both under `--clean -u NORC` and via the real `activate()` path). Because the modules
the keymaps/autocmds delegate to (`completion.lua`, the bridge's autosave) are not built yet, the
ftplugin wires them as **no-op-safe forward contracts** so it is correct & testable today and goes
live unchanged when those modules land.

**Deliverable** (3 files — 1 NEW source + 2 NEW tests; NO modification to existing modules):
- `plugin/ftplugin/pi-prompt.lua` — **CREATE**: the auto-sourced buffer-setup script. Sets the 4
  options, registers the 6 insert-mode buffer-local keymaps, and registers the buffer-local
  autocmds (3 completion triggers + 2 exit/autosave). All callbacks dispatch into future modules
  via a lazy-require helper. [Mode A] docstrings throughout.
- `plugin/tests/ftplugin_smoke.lua` — NEW, plenary-FREE standalone smoke test (Level-1 gate;
  `:luafile`-sourced — inherited S19 GOTCHA #10 / S21 GOTCHA I).
- `plugin/tests/ftplugin_spec.lua` — NEW, plenary/busted spec (Level-2 gate).

> Reuses the existing `plugin/tests/minimal_init.lua` (S19) unchanged — it already puts `plugin/`
> on `runtimepath` and plenary on rtp. NO change to `init.lua` / the S20 shim / S21 (additive).

**Success Definition** (every assertion is LIVE-VERIFIED green — see `research/notes.md` + Validation):
- **Auto-sourcing**: setting `vim.bo[buf].filetype = "pi-prompt"` (S21's exact mutation) sources
  this ftplugin for that buffer (verified under `--clean` and via real `activate()`).
- **Options**: on the pi-prompt buffer — `formatoptions` has no `t` flag, `textwidth == 0`,
  `wrap == true`, `spell == false`.
- **Keymaps**: the 6 buffer-local insert keymaps (`<Tab>`, `<S-Tab>`, `<C-N>`, `<C-P>`, `<C-E>`,
  `<CR>`) are registered on the pi-prompt buffer (queryable via `nvim_buf_get_keymap(buf,"i")`),
  each with a `desc` starting `"pi-editor:"`.
- **Autocmds**: `InsertEnter`, `TextChangedI`, `CursorMovedI` are registered buffer-local in the
  `"pi-editor"` group; `VimLeavePre` + `ExitPre` are registered buffer-local when
  `config.autosave_on_exit ~= false` (default → registered).
- **No-op-safe today**: firing `TextChangedI`/`InsertEnter` (with `completion.lua` absent) does NOT
  throw (`pcall(nvim_exec_autocmds, ...)` ok=true). Calling a keymap rhs path with the module
  absent falls through to the default (no throw).
- **Cross-buffer safety**: a sibling buffer's options/keymaps/autocmds are UNTOUCHED; S20's
  `VimEnter` autocmd in the `"pi-editor"` group is PRESERVED (the ftplugin uses `clear=false` +
  buffer-scoped `nvim_clear_autocmds`).
- **Idempotent**: re-sourcing (e.g. `:doautocmd FileType`) does NOT stack duplicate autocmds.
- `nvim --headless --clean -u NORC` smoke prints `SMOKE_PASS` / exit 0.
- plenary `tests/ftplugin_spec.lua` exits 0.
- **Non-regression**: S19 `init_spec.lua` (13), S20 `shim_spec.lua` (6), S21 `activate_spec.lua`
  (9) still pass unchanged (S22 touches NO existing file).

## User Persona (if applicable)

**Target User**: The `pi-editor.nvim` plugin author and the downstream implementers of **S30+**
(completion.lua), **S38** (autosave), **S24** (bridge.lua), **S42** (health). The ftplugin is the
buffer-side contract surface that wires the UI to those modules. End users experience it only
indirectly (correct editing feel + working completion keys once S30 ships).

**Use Case**: Completes the activation chain S20 (trigger) → S21 (gate sets filetype) → **S22
(ftplugin configures the buffer)**. After S22, a pi-launched `nvim` has a pi-prompt buffer with the
right options and the completion key/autocmd wiring in place — ready for S24/S30 to plug behavior
into the named module functions. De-risks "does the filetype→ftplugin handshake source correctly,
and can we wire forward contracts safely without breaking normal editing?" before any socket or
completion logic lands.

**Pain Points Addressed**: Without the ftplugin, the pi-prompt buffer is a plain unconfigured
buffer — wrong wrap/spell/formatoptions for prompt editing, no completion keys, and nowhere for the
future completion/autosave hooks to attach. Getting the option quirks (the `formatoptions:remove`
gotcha), the augroup cross-buffer safety, and the forward-contract dispatch locked NOW (with tests)
means S30 just implements `completion.refresh/on_tab/...` and S38 implements `bridge.on_exit` —
neither re-derives the wiring.

## Why

- **The filetype handshake target.** PRD §7.1 + S21's gate: `activate()` sets
  `vim.bo[buf].filetype = "pi-prompt"`, which fires `FileType` and auto-sources
  `ftplugin/pi-prompt.lua`. S21 deliberately set ONLY the filetype ("the handshake to S22"); this
  task IS S22 — the response. The handshake is LIVE-VERIFIED end-to-end (real `activate()` →
  filetype → ftplugin sources).
- **Faithful to PRD §7.6.** The ftplugin owns exactly the buffer-local surface the PRD fixes:
  options (`formatoptions-=t`, `textwidth=0`, `wrap`, `spell=false`), the keymap set
  (`<Tab>`/`<S-Tab>`/`<C-N>`/`<C-P>`/`<C-E>`/`<CR>`), and the autocmds (InsertEnter/TextChangedI/
  CursorMovedI refresh; ExitPre/VimLeavePre autosave). PRD §7.4 note: in the external editor there
  is **no Enter-to-submit** (quitting submits), so `<CR>` inserts a newline — documented here.
- **Wires forward without blocking.** `completion.lua`/autosave are later tasks. The lazy-require
  `dispatch()` pattern (pcall `require` + `type(fn)=="function"` + pcall call) makes every callback
  a silent no-op until those modules exist, then live — zero churn when they ship. This is the same
  "establish the contract now, implement later" seam S21 used for `M.descriptor`.
- **Cross-buffer & cross-event safe.** The ftplugin runs per-buffer inside a SHARED `"pi-editor"`
  augroup (S20 created it for VimEnter). Using `clear=false` + buffer-scoped
  `nvim_clear_autocmds` (LIVE-VERIFIED) means S22 never wipes S20's VimEnter autocmd or a sibling
  buffer's autocmds — the documented cross-buffer leak gotcha (`:help nvim_create_augroup()`).
- **Integrates with the (complete) foundation.** Builds on S19's `init.lua` (DONE — `M.config`/
  `M.defaults`), S20's shim (DONE), S21's gate (DONE). Touches none of them (additive).

## What

User-visible behavior: in an ordinary (non-pi) nvim session, nothing (the env var is unset → S21's
gate stays dormant → filetype is never `pi-prompt` → this ftplugin never sources). In a pi-launched
session, the user sees a prompt buffer with wrap on, spell-check off, no auto-wrapping, and the
completion keys wired (functional once S30 ships; until then the keys fall through to their normal
defaults so editing still works). The user-visible contract is "it feels like a normal markdown
buffer, plus completion keys once available."

Technical requirements (the ftplugin body — exact, LIVE-VERIFIED):
- `local pi_ok, pi = pcall(require, "pi-editor")` then `local config = (pi_ok and (pi.config or pi.defaults)) or {}`
  — read resolved config safely (no throw if `pi-editor` somehow absent or `config` nil). Used to
  gate the autosave autocmd.
- `local buf = vim.api.nvim_get_current_buf()` — the matched pi-prompt buffer (ftplugin runs with
  the matched buffer as current; `:help filetype-plugins`).
- `local win = vim.api.nvim_get_current_win()` — for the window-local options.
- **Options**:
  - `vim.bo[buf].formatoptions = (vim.bo[buf].formatoptions or ""):gsub("t", "")` — the `:remove`
    gotcha (GOTCHA A); string approach, captured-buf-scoped.
  - `vim.bo[buf].textwidth = 0`.
  - `vim.wo[win].wrap = true`.
  - `vim.wo[win].spell = false`.
- **Keymaps** (buffer-local, mode `"i"`, dispatch + feedkey fall-through — see Implementation
  Patterns): `<Tab>`→`completion.on_tab`; `<S-Tab>`→`completion.on_prev`; `<C-N>`→`completion.on_next`;
  `<C-P>`→`completion.on_prev`; `<C-E>`→`completion.on_dismiss`; `<CR>`→`completion.on_enter`.
- **Autocmds** (buffer-local, group `"pi-editor"` created with `clear=false`, idempotent via
  buffer-scoped `nvim_clear_autocmds` — GOTCHA C): `InsertEnter`/`TextChangedI`/`CursorMovedI` →
  `completion.refresh(buf)` (fire-and-forget); `VimLeavePre`+`ExitPre` → `bridge.on_exit(buf)`
  (registered only when `config.autosave_on_exit ~= false`).
- **BufWritePre**: NOT overridden — the temp file is writable, so the default `:w` works (PRD §7.6
  "no-op normal write" = let default proceed). Documented; no autocmd registered.
- [Mode A] LuaCATS + a header comment block documenting each keymap's purpose and the pi-specific
  `<CR>`-inserts-newline behavior (no Enter-to-submit in the external editor — PRD §7.4).

### Success Criteria

- [ ] Setting `vim.bo[buf].filetype = "pi-prompt"` sources this ftplugin (verified end-to-end via
      real `activate()`).
- [ ] **Options** on the pi-prompt buffer: `formatoptions` has no `t`; `textwidth == 0`;
      `wrap == true`; `spell == false`.
- [ ] **Keymaps**: 6 buffer-local insert keymaps registered (`nvim_buf_get_keymap(buf,"i")`), each
      `desc` starts `"pi-editor:"`.
- [ ] **Completion autocmds**: `InsertEnter`/`TextChangedI`/`CursorMovedI` registered buffer-local
      in group `"pi-editor"` (`nvim_get_autocmds({buffer=buf, group="pi-editor"})`).
- [ ] **Autosave autocmds**: `VimLeavePre` + `ExitPre` registered buffer-local when
      `config.autosave_on_exit ~= false` (default true); NOT registered when set `false`.
- [ ] **No-op-safe today**: firing `TextChangedI`/`InsertEnter` (completion.lua absent) does not
      throw (`pcall(nvim_exec_autocmds,...)` ok=true).
- [ ] **Cross-buffer safety**: a sibling buffer's keymaps/autocmds untouched; S20's `VimEnter`
      autocmd in group `"pi-editor"` preserved (count unchanged after ftplugin sources).
- [ ] **Idempotent**: `:doautocmd FileType` (re-source) does not stack duplicate autocmds.
- [ ] **Other windows/buffers unaffected**: options set only on the pi-prompt buffer's window.
- [ ] `nvim --headless --clean -u NORC` smoke prints `SMOKE_PASS` / exit 0.
- [ ] `tests/ftplugin_spec.lua` passes under plenary (exit 0).
- [ ] **Non-regression**: `init_spec.lua` + `shim_spec.lua` + `activate_spec.lua` still pass.
- [ ] [Mode A] header comment + per-keymap/per-autocmd docstrings present; `<CR>` newline behavior
      documented.

## All Needed Context

### Context Completeness Check

_Passes "No Prior Knowledge":_ an implementer who has never seen this repo needs only this PRP +
`research/notes.md` + the verified commands below. Every API (`vim.bo[buf].formatoptions`,
`vim.keymap.set` `buffer=`, `nvim_create_autocmd` `buffer=`/`group=`, `nvim_clear_autocmds`
buffer-scoped, `nvim_feedkeys` `'n'`, `nvim_buf_get_keymap`) is cited with a `:help` source AND a
**LIVE-VERIFIED** runnable result (see `research/notes.md` §2–§7). The two subtleties that make or
break this task — (1) `vim.bo[buf].formatoptions:remove("t")` THROWS (it returns a string, not an
opt object; use the gsub form), and (2) creating the shared `"pi-editor"` augroup with `clear=true`
inside a per-buffer ftplugin would WIPE S20's VimEnter autocmd (use `clear=false` + buffer-scoped
clear) — are spelled out in §Known Gotchas and embedded in the reference implementation.

### Documentation & References

```yaml
# MUST READ — primary contract sources

- url: https://neovim.io/doc/user/filetype/#filetype-plugins
  why: "ftplugin/<ft>.lua is auto-sourced on FileType; sets buffer-local options/mappings scoped
        to the matched buffer. The ftplugin runs with the matched buffer as CURRENT, so
        nvim_get_current_buf() is the pi-prompt buffer (no <abuf>/<afile> expansion needed)."
  critical: "LIVE-VERIFIED (research/notes.md §3): setting vim.bo[buf].filetype='pi-prompt' sources
             ftplugin/pi-prompt.lua even under --clean -u NORC (0.12 ships filetype plugin loading
             ON). Also verified via the REAL init.lua activate() path (Level-3 integration)."

- url: https://neovim.io/doc/user/autocmd/#FileType
  why: "The event S21 fires (by setting filetype); S22 attaches via the ftplugin convention."

- url: https://neovim.io/doc/user/lua/#vim.bo
  why: "vim.bo[buf].opt gets/sets buffer-scoped options (like :setlocal) and returns the RAW value."
  critical: "GOTCHA A (LIVE-VERIFIED): vim.bo[buf].formatoptions is a plain STRING ('croqlt'), NOT
             an Option object — .remove() is a nil method and THROWS. Use the gsub form
             `vim.bo[buf].formatoptions = (vim.bo[buf].formatoptions or ''):gsub('t','')`, OR
             vim.opt_local.formatoptions:remove('t') (opt object, current-buffer scoped). We use the
             gsub form for captured-buf consistency."

- url: https://neovim.io/doc/user/lua/#vim.opt_local
  why: "The opt-object accessor (has :remove/:append); alternative to the gsub form. Current-buffer
        scoped — fine at ftplugin-load (current buf == pi-prompt buf)."

- url: https://neovim.io/doc/user/options.html#'formatoptions'
  why: "Flag 't' = auto-wrap text using textwidth (fo-table/fo-t). Removing 't' stops insert-time
        auto-wrapping. Default formatoptions is 'tcqj' (t ON)."
  critical: "Belt-and-suspenders with textwidth=0: removing 't' stops auto-wrap regardless of tw;
             tw=0 neutralizes the width threshold. Both make intent explicit & robust."

- url: https://neovim.io/doc/user/lua/#vim.keymap.set()
  why: "vim.keymap.set(mode, lhs, rhs, { buffer=buf }) creates a buffer-local mapping (0=current).
        Auto-cleaned on :bdelete/:bwipeout (:help map-buffer). Query via nvim_buf_get_keymap."
  critical: "LIVE-VERIFIED: nvim_buf_get_keymap(buf,'i') returns [{lhs='<Tab>', desc='...'}, ...];
             buffer-local maps with the same lhs OVERWRITE (idempotent on re-source)."

- url: https://neovim.io/doc/user/api/#nvim_create_autocmd()
  why: "nvim_create_autocmd(ev, { group=g, buffer=buf, callback=fn }) — buffer-local autocmd
        (:help autocmd-buflocal). Auto-cleaned on buffer wipe."

- url: https://neovim.io/doc/user/api/#nvim_create_augroup()
  why: "nvim_create_augroup(name, {clear=...}) — clear defaults to TRUE and wipes the WHOLE group."
  critical: "GOTCHA C (LIVE-VERIFIED): the ftplugin runs PER-BUFFER but the 'pi-editor' group is
             SHARED (S20's VimEnter autocmd lives in it). Creating it with clear=true here would
             WIPE S20's VimEnter autocmd. MUST use clear=false. Per-buffer idempotency is via
             nvim_clear_autocmds({buffer=buf, group='pi-editor'}) — buffer-SCOPED, leaves siblings
             intact (verified: after 2 sources count=2; clearing buf1 leaves buf2's autocmd)."

- url: https://neovim.io/doc/user/api/#nvim_clear_autocmds()
  why: "nvim_clear_autocmds({buffer=buf, group=name}) — the idempotent, cross-buffer-safe clear."

- url: https://neovim.io/doc/user/builtin/#feedkeys()
  why: "nvim_feedkeys(keys, 'n', false) feeds keys with the 'n' (not-remappable) flag — the fed
        <CR>/<Tab> inserts literally WITHOUT re-entering the buffer-local mapping (no recursion)."
  critical: "Used for the fall-through: when dispatch() returns 'not handled' (module absent or
             module signals fall-through), feedkey(lhs) preserves the key's default (CR inserts a
             newline, Tab indents). This keeps the pi-prompt buffer a normal markdown buffer until
             completion.lua (S30+) ships. (The 'n' no-remap property is documented; our headless
             insert-mode verification harness was flaky on feedkeys timing, but the property is
             standard and used by lazy.nvim / many plugins.)"

- url: https://neovim.io/doc/user/lua/#require()
  why: "The lazy-require forward-contract idiom: pcall(require, 'mod') so a keymap/autocmd installs
        safely even though the target module isn't built yet."

- url: https://neovim.io/doc/user/lua/#vim.wo
  why: "vim.wo[win].wrap / .spell — window-local options. wrap & spell are NOT buffer-scoped, so
        they persist when switching buffers in the same window."
  critical: "GOTCHA (accepted): the window-local leak. PRD §7.1/§7.6 explicitly sets them this way
             and the pi editor is a single-purpose nvim instance (one buffer/window), so the leak is
             acceptable & matches the spec. No per-buffer re-application in v1."

- file: plan/001_c56962b4fa17/P2M4T13S22/research/notes.md
  why: "LIVE-VERIFIED proof (nvim 0.12.4) of every API above: the formatoptions:remove throw, the
        gsub/opt alternatives, ftplugin auto-sourcing (--clean + real activate()), keymap/autocmd
        registration+query, the augroup clear=false preservation of S20's VimEnter autocmd, the
        buffer-scoped clear idempotency, and the dispatch no-op safety. Full transcripts included."

- file: plugin/lua/pi-editor/init.lua
  why: "S19+S21 module (DONE). Confirms M.config (nil until setup), M.defaults (the shipped values:
        autosave_on_exit=true), and that activate() sets filetype='pi-prompt' (the handshake this
        ftplugin consumes). Read config = pi.config or pi.defaults, safely."

- file: plugin/plugin/pi-editor.lua
  why: "S20 shim (DONE). Confirms it creates augroup 'pi-editor' with clear=true ONCE at startup and
        registers the fire-once VimEnter autocmd — the autocmd this ftplugin MUST NOT wipe
        (GOTCHA C)."

- file: plan/001_c56962b4fa17/P2M4T12S21/PRP.md
  why: "The predecessor gate. Its FORWARD CONTRACTS: 'S22 (ftplugin/pi-prompt.lua): auto-sourced on
        the FileType event this gate fires. It owns buffer options/keymaps/autocmds. S21's ONLY
        contribution to S22 is setting filetype.' This task fulfills that contract."

- file: plan/001_c56962b4fa17/architecture/external_deps.md
  why: "§1.6 documents the buffer-local autocmd pattern (buffer=bufnr); confirms plenary is the Lua
        test framework; §4 confirms the pi extension sets PI_EDITOR_BRIDGE (the env var S21 reads)."

- docfile: plan/001_c56962b4fa17/prd_snapshot.md
  section: "§7.1 (filetype handshake), §7.6 (buffer-local setup: options/keymaps/autocmds), §7.4 (<CR>
        inserts newline — no Enter-to-submit), §11 (autosave-on-quit MUST)"
  why: "These PRD sections ARE the source of truth for this task's buffer surface (reproduced in
        <selected_prd_content>)."
```

### Current Codebase tree (relevant slice)

```bash
pi-nvim-bridge/                  # repo root (monorepo: extension/ + plugin/)
├── extension/                   # P1 — pi-editor-bridge (TypeScript) — COMPLETE
│   ├── pi-editor-bridge.ts      # writes process.env.PI_EDITOR_BRIDGE in startBridge()
│   └── protocol.ts              # BridgeDescriptor type
├── plugin/                      # <-- Neovim plugin root (the runtimepath entry)
│   ├── lua/pi-editor/init.lua   # S19+S21 (DONE) — setup/defaults/config/bridge/descriptor/activate()
│   ├── plugin/pi-editor.lua     # S20 (DONE) — VimEnter shim; creates augroup "pi-editor"; calls activate()
│   └── tests/
│       ├── minimal_init.lua     # S19 (DONE) — plenary harness; puts plugin/ on rtp (REUSED unchanged)
│       ├── init_spec.lua        # S19 (DONE) — setup() spec (must STILL pass — S22 touches nothing)
│       ├── smoke.lua            # S19 (DONE)
│       ├── shim_spec.lua        # S20 (DONE) — shim spec (must STILL pass)
│       ├── shim_smoke.lua       # S20 (DONE)
│       ├── activate_smoke.lua   # S21 (DONE)
│       └── activate_spec.lua    # S21 (DONE) — activate gate spec (must STILL pass)
├── PRD.md  README.md  package.json
└── plan/001_c56962b4fa17/
    ├── architecture/{external_deps,system_context}.md
    ├── P2M4T11S19/{PRP.md, research/}     # S19 (predecessor, DONE)
    ├── P2M4T11S20/{PRP.md, research/}     # S20 (predecessor, DONE)
    ├── P2M4T12S21/{PRP.md, research/}     # S21 (predecessor, DONE — sets filetype)
    └── P2M4T13S22/{PRP.md, research/notes.md}   # THIS task
# NOTE: plugin/ftplugin/ does NOT exist yet — this task CREATES it.
# NOTE: lua/pi-editor/completion.lua (S30+), bridge.lua (S24), menu.lua (S34+), coords.lua (S28),
#       health.lua (S42) do NOT exist yet — the ftplugin wires them as no-op-safe forward contracts.
# NOTE: stylua, selene are NOT installed (nvim 0.12.4 + plenary.nvim ARE).
```

### Desired Codebase tree with files to be added/modified

```bash
plugin/                          # runtimepath entry (unchanged)
├── ftplugin/
│   └── pi-prompt.lua            # NEW — auto-sourced on FileType pi-prompt; options+keymaps+autocmds
└── tests/
    ├── minimal_init.lua         # (S19, REUSED unchanged)
    ├── ftplugin_smoke.lua       # NEW — plenary-FREE smoke test (Level-1 gate; :luafile-sourced)
    └── ftplugin_spec.lua        # NEW — plenary/busted spec (Level-2 gate)
```

> **Why CREATE (not MODIFY)?** The ftplugin is a NEW auto-sourced script (there is no existing
> `ftplugin/` dir). It consumes `init.lua`'s public surface (`require("pi-editor").config/defaults`)
> read-only and attaches to the filetype S21 sets. No existing file changes → guaranteed
> non-regression of S19/S20/S21 suites.

### Known Gotchas of our codebase & Library Quirks

```lua
-- GOTCHA A — vim.bo[buf].formatoptions:remove("t") THROWS. The contract literally says this; it is
--   WRONG. vim.bo[buf].<opt> returns the RAW value; formatoptions is a flag-string ('croqlt'), NOT
--   an Option object, so :remove() is a nil method and calling it errors
--   ("attempt to call method 'remove' (a nil value)"). LIVE-VERIFIED (research/notes.md §2).
--   FIX: vim.bo[buf].formatoptions = (vim.bo[buf].formatoptions or ""):gsub("t", "")
--   (captured-buf-scoped, deterministic). Alternative: vim.opt_local.formatoptions:remove("t")
--   (opt object, current-buffer scoped — also fine at ftplugin-load). We use the gsub form.

-- GOTCHA B — the ftplugin must be NO-OP-SAFE against absent modules. completion.lua (S30+) and the
--   bridge's autosave (S38) DO NOT EXIST when S22 ships. If a keymap/autocmd rhs did
--   `require("pi-editor.completion")` at CALL time without a pcall, the FIRST keystroke/edit would
--   THROW (module not found) and escape the keymap/autocmd. FIX: every callback goes through
--   dispatch(modname, fnname, buf) which pcall(requires), type-checks the fn, and pcall(calls) —
--   returning false (silent) when absent. LIVE-VERIFIED (research/notes.md §6): absent module ->
--   dispatch returns false, no throw; present module -> fn runs.

-- GOTCHA C — NEVER create the shared "pi-editor" augroup with clear=true inside the ftplugin.
--   S20's shim created augroup "pi-editor" ONCE at startup (clear=true) and registered the fire-once
--   VimEnter autocmd in it. The ftplugin runs PER-BUFFER (each filetype set). If it calls
--   nvim_create_augroup("pi-editor", {clear=true}), it WIPES the whole group — including S20's
--   VimEnter autocmd and any OTHER buffer's pi-editor autocmds. LIVE-VERIFIED (research/notes.md §5).
--   FIX: nvim_create_augroup("pi-editor", {clear=false}) + per-buffer idempotency via
--   nvim_clear_autocmds({buffer=buf, group="pi-editor"}) (buffer-SCOPED: leaves siblings intact).

-- GOTCHA D — keys with an essential default must FALL THROUGH when the module is absent.
--   <CR> must still insert a newline and <Tab> still indent until completion.lua ships. A no-op rhs
--   would BREAK text entry in the placeholder phase. FIX: each keymap rhs dispatches; if dispatch
--   returns false (not handled), nvim_feedkeys(replace_termcodes(lhs,...), "n", false) feeds the
--   original key with the 'n' (noremap) flag so it inserts literally WITHOUT recursing into the
--   buffer map (:help feedkeys()). Uniform policy across all 6 keys. Autocmds (refresh/autosave)
--   are fire-and-forget — no default to preserve, so no fall-through needed.

-- GOTCHA E — window-local options (wrap/spell) are NOT buffer-scoped; they LEAK across buffers in
--   the same window. PRD §7.1/§7.6 sets them this way and the pi editor is single-purpose, so this
--   is ACCEPTED for v1. Document it; do not add per-buffer re-application (out of scope).

-- GOTCHA F — config may be nil (user never called setup()). The ftplugin reads config via
--   pcall(require,"pi-editor") then config = pi.config or pi.defaults or {}. Reading pi.config.env
--   on a nil config would throw; the `or pi.defaults or {}` chain is load-bearing.

-- GOTCHA G — <CR> inserts a NEWLINE; it does NOT submit. PRD §7.4: in the external editor there is
--   no Enter-to-submit (pi reads the file only after the editor EXITS, PRD §2.1). So <CR> always
--   inserts a newline unless the completion menu is open (then accept+newline, owned by S32).
--   Document prominently in the header comment + the <CR> keymap desc.

-- GOTCHA H — for validation, set runtimepath via --cmd (step 3) and fire FileType by setting
--   filetype (or via real activate()), NOT a + arg. The ftplugin auto-sources on filetype set, but
--   rtp must be on the path BEFORE the filetype is set. (Inherited from S20 GOTCHA #3 / S21 GOTCHA C.)

-- GOTCHA I — a ':lua <<HEREDOC' does NOT work inside -c/+ command-line args (inherited S19 GOTCHA
--   #10). For multi-statement validation from the CLI, write a file and :luafile it (that is why
--   ftplugin_smoke.lua exists). Judge pass/fail by our markers (SMOKE_PASS, the Success:/Failed:
--   plenary line), not nvim's benign 'E216: No such group or event: filetypedetect BufRead'
--   (--clean filetype init artifact; exit stays 0 — S19 GOTCHA #11).
```

## Implementation Blueprint

### Data models and structure

No new data models. The ftplugin reads the existing `pi-editor.Config` (S19) read-only. It
ESTABLISHES two forward-contract module APIs (not implemented here — wired via `dispatch`):

```lua
-- FORWARD CONTRACT A — require("pi-editor.completion")  (implemented by S30+):
--   refresh(buf)            -- InsertEnter/TextChangedI/CursorMovedI; fire-and-forget (no return).
--   on_tab(buf)   -> truthy -- <Tab>: trigger/accept (S33); truthy == handled, else fall through.
--   on_enter(buf) -> truthy -- <CR>: accept if menu open else newline (S32); truthy == handled.
--   on_next(buf)  -> truthy -- <C-N>: next item (S36); truthy == handled.
--   on_prev(buf)  -> truthy -- <S-Tab>/<C-P>: prev item (S36); truthy == handled.
--   on_dismiss(buf)->truthy -- <C-E>: dismiss menu (S37); truthy == handled.

-- FORWARD CONTRACT B — require("pi-editor.bridge")  (connection: S24; on_exit body: S38):
--   on_exit(buf)            -- VimLeavePre/ExitPre: autosave-if-modified + send bye + close socket.
```

The `truthy == handled` contract is the seam: `dispatch` returns `true` only if the module exists
AND its function returned truthy; otherwise the keymap falls through to its default (GOTCHA D).

### Implementation Tasks (ordered by dependencies)

```yaml
Task 1: CREATE plugin/ftplugin/pi-prompt.lua  (THE deliverable — options + keymaps + autocmds)
  - HEADER: a [Mode A] comment block documenting: auto-sourced on FileType pi-prompt (the S21
        handshake); the pi-specific behavior (<CR> newline, no Enter-to-submit — PRD §7.4); the
        forward-contract dispatch (callbacks are no-op-safe until completion.lua/bridge ship); the
        scope boundary (does NOT implement completion/autosave — only wires them).
  - READ config safely: pcall(require,"pi-editor"); config = pi.config or pi.defaults or {}.
  - CAPTURE buf = nvim_get_current_buf(); win = nvim_get_current_win().
  - OPTIONS (4): formatoptions gsub-remove 't' (GOTCHA A); textwidth=0; wo[win].wrap=true;
        wo[win].spell=false.
  - DISPATCH HELPERS (local fns): dispatch(mod,fn,buf)->bool; feedkey(k); map_dispatch(buf,mode,
        lhs,mod,fn) (see Implementation Patterns).
  - KEYMAPS (6, mode "i", buffer-local via map_dispatch): <Tab>->on_tab; <S-Tab>->on_prev;
        <C-N>->on_next; <C-P>->on_prev; <C-E>->on_dismiss; <CR>->on_enter.
  - AUTOCMDS: nvim_create_augroup("pi-editor",{clear=false}) (GOTCHA C);
        nvim_clear_autocmds({buffer=buf,group="pi-editor"}) (idempotent, buffer-scoped);
        InsertEnter/TextChangedI/CursorMovedI -> dispatch("pi-editor.completion","refresh",buf);
        (if config.autosave_on_exit ~= false) VimLeavePre+ExitPre ->
        dispatch("pi-editor.bridge","on_exit",buf).
  - DO NOT register BufWritePre (default :w works; temp file is writable — PRD §7.6 "no-op normal
        write" = let default proceed). Document the decision in the header.
  - DO NOT require any not-yet-existing module at LOAD time (only inside dispatch, pcall'd).
  - DO NOT modify init.lua / the shim / S21 (additive only — §Non-regression).
  - PLACEMENT: plugin/ftplugin/pi-prompt.lua.

Task 2: CREATE plugin/tests/ftplugin_smoke.lua  (plenary-FREE fast smoke — the Level-1 gate)
  - CONTENT (see Implementation Patterns): standalone script. Computes plugin_root from its own path,
        appends to runtimepath, creates a fresh buffer, sets filetype='pi-prompt' (triggers the
        ftplugin), and asserts: formatoptions has no 't'; textwidth==0; wrap==true; spell==false;
        6 keymaps present (nvim_buf_get_keymap 'i') with 'pi-editor:' desc; the 3 completion
        autocmds + 2 exit autocmds present (nvim_get_autocmds buffer+group); firing TextChangedI
        with completion.lua ABSENT does not throw (pcall ok); a SIBLING buffer is untouched; S20's
        VimEnter autocmd still present. Uses cquit(1) on failure.
  - WHY: instant, dependency-free feedback. ftplugin_spec.lua is the formal suite.
  - GOTCHA: source via :luafile, NOT a :lua <<HEREDOC in a -c/+ arg (GOTCHA I).
  - PLACEMENT: plugin/tests/ftplugin_smoke.lua.
  - DEPENDENCIES: Task 1.

Task 3: CREATE plugin/tests/ftplugin_spec.lua  (plenary/busted spec — the Level-2 gate)
  - CONTENT (see Implementation Patterns): a describe("pi-editor ftplugin/pi-prompt", ...). before_each:
        package.loaded["pi-editor"]=nil; require fresh; make a fresh scratch buffer the current;
        (clear any pi-editor autocmds from prior tests). Cover ALL Success Criteria as `it` blocks:
        (1) filetype set -> ftplugin sources (option applied); (2) formatoptions no 't'; (3)
        textwidth 0; (4) wrap true; (5) spell false; (6) 6 keymaps registered w/ 'pi-editor:' desc;
        (7) completion autocmds present (InsertEnter/TextChangedI/CursorMovedI); (8) autosave
        autocmds present by default (VimLeavePre/ExitPre); (9) autosave_on_exit=false -> exit
        autocmds NOT registered; (10) firing TextChangedI with completion absent -> no throw; (11)
        sibling buffer unaffected; (12) re-source idempotent (no stacking); (13) S20 VimEnter
        autocmd preserved.
  - ASSERTIONS: assert.are.equals / assert.is_true / assert.is_not_nil / assert.has_no.errors as
        appropriate. For no-throw: `local ok=pcall(vim.api.nvim_exec_autocmds,'TextChangedI',
        {buffer=buf}); assert.is_true(ok)`.
  - PLACEMENT: plugin/tests/ftplugin_spec.lua.
  - DEPENDENCIES: Task 1 + the S19 harness (plugin/tests/minimal_init.lua).
```

### Implementation Patterns & Key Details

```lua
-- === plugin/ftplugin/pi-prompt.lua — the FULL reference implementation (LIVE-VERIFIED APIs) ===
-- Auto-sourced on the FileType event S21's activate() fires (vim.bo[buf].filetype = "pi-prompt").
-- [Mode A] header: scope, forward contracts, the <CR>-newline behavior.

--- pi-prompt buffer setup. Auto-sourced on |FileType| `pi-prompt` (set by
--- `require("pi-editor").activate()` — S21). Configures the pi temp-file buffer for prompt
--- editing and wires the completion keymaps + the completion/autosave autocmds.
---
--- FORWARD CONTRACTS (callbacks are NO-OP-SAFE until the target modules ship):
---   require("pi-editor.completion").refresh/on_tab/on_enter/on_next/on_prev/on_dismiss  (S30+)
---   require("pi-editor.bridge").on_exit                                               (S24 conn / S38 body)
--- A callback dispatches via pcall(require, ...); if the module/function is absent it silently
--- no-ops (autocmds) or falls through to the key's default (keymaps, via feedkeys 'n'). So this
--- buffer behaves as a normal markdown buffer TODAY and goes live when those modules land.
---
--- pi-specific: <CR> inserts a NEWLINE (there is no Enter-to-submit in the external editor —
--- pi reads the file only after the editor EXITS; PRD §2.1/§7.4). <CR> accepts only when the
--- completion menu is open (owned by completion.on_enter / S32).

-- Read resolved config safely (config may be nil if the user never called setup()).
local pi_ok, pi = pcall(require, "pi-editor")
local config = (pi_ok and pi and (pi.config or pi.defaults)) or {}

local buf = vim.api.nvim_get_current_buf()   -- the matched pi-prompt buffer (ftplugin runs current==matched)
local win = vim.api.nvim_get_current_win()

-- ── Options (PRD §7.6) ──────────────────────────────────────────────────────────
-- GOTCHA A: vim.bo[buf].formatoptions is a plain STRING (no :remove). Use gsub (captured-buf).
vim.bo[buf].formatoptions = (vim.bo[buf].formatoptions or ""):gsub("t", "")  -- stop insert-time auto-wrap
vim.bo[buf].textwidth = 0                                                    -- disable wrap width threshold
vim.wo[win].wrap = true                                                      -- window-local (GOTCHA E: accepted leak)
vim.wo[win].spell = false                                                    -- window-local

-- ── Forward-contract dispatch (GOTCHA B: no-op-safe against absent modules) ─────
-- Returns true ONLY if the module exists AND its function returned truthy ("handled").
local function dispatch(modname, fnname, b)
  local ok, mod = pcall(require, modname)
  if not ok or type(mod) ~= "table" then return false end
  local fn = mod[fnname]
  if type(fn) ~= "function" then return false end
  local pok, handled = pcall(fn, b)
  return pok and handled == true
end

-- Feed a key literally, WITHOUT re-entering any mapping (feedkeys 'n' = not-remappable).
local function feedkey(k)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(k, true, true, true), "n", false)
end

-- Buffer-local keymap: dispatch to a forward-contract fn; if not handled, fall through to the
-- key's default (GOTCHA D — keeps <CR>/<Tab>/... usable while completion.lua is absent).
local function map_dispatch(mode, lhs, modname, fnname)
  vim.keymap.set(mode, lhs, function()
    if not dispatch(modname, fnname, buf) then feedkey(lhs) end
  end, { buffer = buf, desc = "pi-editor: " .. fnname })
end

-- ── Keymaps (insert-mode, buffer-local; PRD §7.6) ──────────────────────────────
map_dispatch("i", "<Tab>",   "pi-editor.completion", "on_tab")     -- trigger / accept (S33)
map_dispatch("i", "<S-Tab>", "pi-editor.completion", "on_prev")    -- prev item (S36)
map_dispatch("i", "<C-N>",   "pi-editor.completion", "on_next")    -- next item (S36)
map_dispatch("i", "<C-P>",   "pi-editor.completion", "on_prev")    -- prev item (S36)
map_dispatch("i", "<C-E>",   "pi-editor.completion", "on_dismiss") -- dismiss menu (S37)
map_dispatch("i", "<CR>",    "pi-editor.completion", "on_enter")   -- accept-or-newline (S32)

-- ── Autocmds (buffer-local, shared "pi-editor" group; GOTCHA C: clear=false) ────
local group = vim.api.nvim_create_augroup("pi-editor", { clear = false })
-- Idempotent on re-source: clear THIS buffer's pi-editor autocmds only (buffer-scoped).
vim.api.nvim_clear_autocmds({ buffer = buf, group = "pi-editor" })

-- Completion refresh triggers (fire-and-forget; no default to preserve).
for _, ev in ipairs({ "InsertEnter", "TextChangedI", "CursorMovedI" }) do
  vim.api.nvim_create_autocmd(ev, {
    group = group, buffer = buf,
    callback = function() dispatch("pi-editor.completion", "refresh", buf) end,
  })
end

-- Autosave + bridge teardown on exit (gated on config; default true). Body is S38; wiring is here.
if config.autosave_on_exit ~= false then
  for _, ev in ipairs({ "VimLeavePre", "ExitPre" }) do
    vim.api.nvim_create_autocmd(ev, {
      group = group, buffer = buf,
      callback = function() dispatch("pi-editor.bridge", "on_exit", buf) end,
    })
  end
end

-- BufWritePre: intentionally NOT overridden — the temp file is writable, so default :w works
-- (PRD §7.6 "no-op normal write" = let the default proceed).
```

```lua
-- === plugin/tests/ftplugin_smoke.lua — standalone (plenary-FREE) smoke test ===
-- Run from the REPO ROOT:
--   nvim --headless --clean -u NORC +"luafile plugin/tests/ftplugin_smoke.lua" +qa ; echo exit=$?
local me = debug.getinfo(1, "S").source:sub(2)
me = vim.fn.fnamemodify(me, ":p")
local plugin_root = vim.fn.fnamemodify(me, ":h:h")           -- .../plugin (rtp entry)
vim.opt.runtimepath:append(plugin_root)

local fails = 0
local function check(cond, msg) if not cond then io.stderr:write("FAIL: " .. msg .. "\n"); fails = fails + 1 end end

-- fresh scratch buffer as the current, then set filetype (triggers the ftplugin)
local buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_set_current_buf(buf)
vim.bo[buf].formatoptions = "tcqj"   -- deterministic baseline (t present)
vim.bo[buf].textwidth = 80
vim.bo[0].filetype = "pi-prompt"     -- -> sources ftplugin/pi-prompt.lua

check(not string.find(vim.bo[buf].formatoptions or "", "t"), "formatoptions should have no 't'")
check(vim.bo[buf].textwidth == 0, "textwidth should be 0")
check(vim.wo[0].wrap == true, "wrap should be true")
check(vim.wo[0].spell == false, "spell should be false")

-- keymaps
local kms = {}
for _, m in ipairs(vim.api.nvim_buf_get_keymap(buf, "i")) do kms[m.lhs] = m.desc end
for _, k in ipairs({ "<Tab>", "<S-Tab>", "<C-N>", "<C-P>", "<C-E>", "<CR>" }) do
  check(type(kms[k]) == "string" and kms[k]:find("^pi-editor:"), "keymap " .. k .. " missing/bad desc")
end

-- autocmds (buffer-scoped, in the pi-editor group)
local acs = {}
local okac, list = pcall(vim.api.nvim_get_autocmds, { buffer = buf, group = "pi-editor" })
check(okac, "get_autocmds ok")
if okac then for _, a in ipairs(list) do acs[a.event] = true end end
for _, ev in ipairs({ "InsertEnter", "TextChangedI", "CursorMovedI", "VimLeavePre", "ExitPre" }) do
  check(acs[ev] == true, "autocmd " .. ev .. " missing")
end

-- no-op-safe: fire TextChangedI with completion.lua ABSENT -> no throw
local okfire = pcall(vim.api.nvim_exec_autocmds, "TextChangedI", { buffer = buf })
check(okfire, "TextChangedI should not throw with completion absent")

-- S20's VimEnter autocmd in the shared group is preserved (GOTCHA C)
local ve = vim.api.nvim_get_autocmds({ event = "VimEnter", group = "pi-editor" })
check(#ve >= 1, "S20 VimEnter autocmd should still exist (clear=false)")

if fails > 0 then io.stderr:write(fails .. " check(s) failed\n"); vim.cmd("cquit 1") end
io.stdout:write("SMOKE_PASS\n")
```

```lua
-- === plugin/tests/ftplugin_spec.lua — the spec (covers every Success Criterion) ===
describe("pi-editor ftplugin/pi-prompt", function()
  local function fresh_prompt_buf()
    local b = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(b)
    vim.bo[b].formatoptions = "tcqj"; vim.bo[b].textwidth = 80
    vim.bo[b].filetype = "pi-prompt"          -- sources the ftplugin
    return b
  end

  it("is auto-sourced on filetype=pi-prompt (textwidth applied)", function()
    local b = fresh_prompt_buf()
    assert.are.equals(0, vim.bo[b].textwidth)
  end)

  it("removes the 't' flag from formatoptions", function()
    local b = fresh_prompt_buf()
    assert.is_false(string.find(vim.bo[b].formatoptions or "", "t") ~= nil)
  end)

  it("sets wrap=true, spell=false", function()
    local _ = fresh_prompt_buf()
    assert.is_true(vim.wo[0].wrap)
    assert.is_false(vim.wo[0].spell)
  end)

  it("registers the 6 insert keymaps with 'pi-editor:' desc", function()
    local b = fresh_prompt_buf()
    local kms = {}
    for _, m in ipairs(vim.api.nvim_buf_get_keymap(b, "i")) do kms[m.lhs] = m.desc end
    for _, k in ipairs({ "<Tab>", "<S-Tab>", "<C-N>", "<C-P>", "<C-E>", "<CR>" }) do
      assert.is_truthy(kms[k], "missing keymap " .. k)
      assert.is_truthy(kms[k]:find("^pi-editor:"), "bad desc for " .. k)
    end
  end)

  it("registers completion autocmds (InsertEnter/TextChangedI/CursorMovedI)", function()
    local b = fresh_prompt_buf()
    local evs = {}
    for _, a in ipairs(vim.api.nvim_get_autocmds({ buffer = b, group = "pi-editor" })) do evs[a.event] = true end
    for _, ev in ipairs({ "InsertEnter", "TextChangedI", "CursorMovedI" }) do
      assert.is_true(evs[ev], "missing autocmd " .. ev)
    end
  end)

  it("registers VimLeavePre/ExitPre autosave autocmds by default", function()
    local b = fresh_prompt_buf()
    local evs = {}
    for _, a in ipairs(vim.api.nvim_get_autocmds({ buffer = b, group = "pi-editor" })) do evs[a.event] = true end
    assert.is_true(evs["VimLeavePre"]); assert.is_true(evs["ExitPre"])
  end)

  it("skips exit autocmds when autosave_on_exit=false", function()
    package.loaded["pi-editor"] = nil
    local pi = require("pi-editor"); pi.setup({ autosave_on_exit = false })
    local b = fresh_prompt_buf()
    local evs = {}
    for _, a in ipairs(vim.api.nvim_get_autocmds({ buffer = b, group = "pi-editor" })) do evs[a.event] = true end
    assert.is_nil(evs["VimLeavePre"]); assert.is_nil(evs["ExitPre"])
  end)

  it("does not throw when firing completion autocmds with completion.lua absent", function()
    local b = fresh_prompt_buf()
    assert.has_no.errors(function()
      vim.api.nvim_exec_autocmds("TextChangedI", { buffer = b })
      vim.api.nvim_exec_autocmds("InsertEnter", { buffer = b })
    end)
  end)

  it("does not touch a sibling buffer", function()
    local b1 = fresh_prompt_buf()
    local b2 = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(b2)
    assert.are_not_equals("pi-prompt", vim.bo[b2].filetype)
    local n = 0
    for _ in ipairs(vim.api.nvim_buf_get_keymap(b2, "i")) do n = n + 1 end
    assert.are.equals(0, n)   -- sibling has no pi-editor keymaps
    _ = b1
  end)

  it("is idempotent on re-source (no duplicate autocmds)", function()
    local b = fresh_prompt_buf()
    local function cnt() local n = 0
      for _ in ipairs(vim.api.nvim_get_autocmds({ buffer = b, group = "pi-editor" })) do n = n + 1 end return n end
    local before = cnt()
    vim.bo[b].filetype = ""       -- reset
    vim.bo[b].filetype = "pi-prompt"  -- re-source
    assert.are.equals(before, cnt())
  end)

  it("preserves S20's VimEnter autocmd in the shared group", function()
    fresh_prompt_buf()
    local ve = vim.api.nvim_get_autocmds({ event = "VimEnter", group = "pi-editor" })
    assert.is_true(#ve >= 1)
  end)
end)
```

### Integration Points

```yaml
AUTO-SOURCING (the handshake — S21 → S22):
  - S21's activate() does `vim.bo[buf].filetype = "pi-prompt"` -> fires FileType -> this ftplugin
    sources for that buffer. LIVE-VERIFIED under --clean and via real activate() (research/notes.md §3).

MODULE SURFACE CONSUMED (read-only):
  - require("pi-editor").config / .defaults   (S19/S21) — read for autosave_on_exit gating.

FORWARD CONTRACTS ESTABLISHED (do NOT implement here — only wire via dispatch):
  - require("pi-editor.completion"): refresh(buf); on_tab/on_enter/on_next/on_prev/on_dismiss(buf)->truthy.
        Implemented by S30+ (completion flow + menu). The `truthy==handled` return drives the
        keymap fall-through (GOTCHA D); refresh has no return contract (fire-and-forget).
  - require("pi-editor.bridge"): on_exit(buf). Connection by S24; body (autosave-if-modified +
        send bye + close socket) by S38. Wired only when config.autosave_on_exit ~= false.

AUGROUP (cohesion — reused, NOT re-cleared globally):
  - "pi-editor" (same name S20 used for VimEnter; S24 will reuse it too). Created here with
    clear=FALSE (GOTCHA C); per-buffer idempotency via nvim_clear_autocmds({buffer=buf, group=...}).

NO DATABASE / NO NETWORK / NO CONFIG FILES / NO EXISTING-FILE EDITS. The ONLY side effects are:
  buffer-local option/keymap/autocmd attachment on the pi-prompt buffer (auto-cleaned on buffer
  wipe). No socket, no RPC, no file I/O (autosave is S38's job).
```

## Validation Loop

> **Run all commands from the REPO ROOT** (`/home/dustin/projects/pi-nvim-bridge`).
> The plugin root is `$(pwd)/plugin`. **Every API the ftplugin uses is LIVE-VERIFIED** on the
> installed Neovim 0.12.4 + plenary.nvim (see `research/notes.md`). NOTE: `nvim --headless --clean
> -u NORC` prints a benign `Error in .../syntax/syntax.vim: E216: No such group or event:
> filetypedetect BufRead` (an nvim filetype/syntax init artifact, NOT from our code; exit stays 0).
> Judge pass/fail by our markers (`SMOKE_PASS`, the `Success:/Failed:` plenary line) and `$?`,
> not that warning (S19 GOTCHA #11).

### Level 1: Syntax & Load (Immediate Feedback — dependency-free, no plenary)

```bash
# 1a. Smoke test via the deliverable plugin/tests/ftplugin_smoke.lua (plenary-FREE fast feedback).
#     Creates a scratch buffer, sets filetype=pi-prompt (sources the ftplugin), asserts the options,
#     keymaps, autocmds, no-throw-on-fire, sibling-isolation, and S20-VimEnter-preservation.
#     NO :lua <<HEREDOC (GOTCHA I). Run from the REPO ROOT.
nvim --headless --clean -u NORC +"luafile plugin/tests/ftplugin_smoke.lua" +qa
echo "exit=$?   # 0 = pass (prints 'SMOKE_PASS'), 1 = a check failed"
```

```bash
# 1b. (Optional, only if installed) Lua lint/format. NOT a hard gate (inherited S19 GOTCHA #8).
command -v selene >/dev/null && selene -q plugin/ftplugin plugin/tests || echo "selene not installed (skipped; optional)"
command -v stylua >/dev/null && stylua --check plugin/ftplugin plugin/tests || echo "stylua not installed (skipped; optional)"
```

### Level 2: Unit Tests (plenary spec)

```bash
# 2a. In-process plenary run (reuses the S19 minimal_init.lua — puts plugin/ on rtp + plenary on rtp).
cd plugin
nvim --headless --clean -u tests/minimal_init.lua \
  -c 'lua require("plenary.busted").run("tests/ftplugin_spec.lua")'
echo "exit=$?   # 0 = all pass (13 it blocks)"
cd ..
```

```bash
# 2b. NON-REGRESSION — the S19 + S20 + S21 suites MUST still pass (S22 touches NO existing file).
cd plugin
for s in init_spec shim_spec activate_spec; do
  nvim --headless --clean -u tests/minimal_init.lua -c "lua require('plenary.busted').run('tests/$s.lua')"
  echo "$s exit=$?"
done
cd ..
# Expected: init_spec=0 (13), shim_spec=0 (6), activate_spec=0 (9).
```

### Level 3: Integration (real activate() → real ftplugin, end-to-end)

```bash
# 3a. The REAL handshake: load the real plugin on rtp via --cmd (GOTCHA H), set PI_EDITOR_BRIDGE,
#     fire VimEnter (runs S20 shim -> S21 activate() -> filetype=pi-prompt -> S22 ftplugin sources),
#     then verify the ftplugin's effect on the buffer.
PLUGIN_ROOT="$(pwd)/plugin"
nvim --headless --clean -u NORC --cmd "let &runtimepath=&runtimepath.',$PLUGIN_ROOT'" \
  +"lua vim.env.PI_EDITOR_BRIDGE='{\"transport\":\"unix\",\"path\":\"/tmp/real.sock\",\"token\":\"sekret\",\"pid\":99,\"cwd\":\"/proj\",\"fdAvailable\":true,\"serverVersion\":\"0.1.0\"}'" \
  +"lua vim.api.nvim_exec_autocmds('VimEnter', {})" \
  +"lua local b=vim.api.nvim_get_current_buf(); print('HANDSHAKE ft='..vim.bo[b].filetype..' tw='..tostring(vim.bo[b].textwidth)..' fo=['..(vim.bo[b].formatoptions or '')..'] wrap='..tostring(vim.wo[0].wrap)..' spell='..tostring(vim.wo[0].spell))" \
  +qa 2>&1 | grep -v 'E216\|filetypedetect'
# Expected: HANDSHAKE ft=pi-prompt tw=0 fo=[](no t) wrap=true spell=false
#   (LIVE-VERIFIED: real activate() -> ftplugin sources — research/notes.md §3.)

# 3b. The keymap wiring is present after the real handshake.
nvim --headless --clean -u NORC --cmd "let &runtimepath=&runtimepath.',$PLUGIN_ROOT'" \
  +"lua vim.env.PI_EDITOR_BRIDGE='{\"transport\":\"unix\",\"path\":\"/tmp/x.sock\",\"token\":\"t\",\"pid\":1,\"cwd\":\"/p\",\"fdAvailable\":true,\"serverVersion\":\"0.1.0\"}'" \
  +"lua vim.api.nvim_exec_autocmds('VimEnter', {})" \
  +"lua local b=vim.api.nvim_get_current_buf(); local n=0; for _,m in ipairs(vim.api.nvim_buf_get_keymap(b,'i')) do if (m.desc or ''):find('^pi-editor:') then n=n+1 end end; print('KEYMAPS count='..n)" \
  +qa 2>&1 | grep -v 'E216\|filetypedetect'
# Expected: KEYMAPS count=6

# 3c. No-op safety through the real handshake: fire TextChangedI (completion.lua absent) -> no throw.
nvim --headless --clean -u NORC --cmd "let &runtimepath=&runtimepath.',$PLUGIN_ROOT'" \
  +"lua vim.env.PI_EDITOR_BRIDGE='{\"transport\":\"unix\",\"path\":\"/tmp/x.sock\",\"token\":\"t\",\"pid\":1,\"cwd\":\"/p\",\"fdAvailable\":true,\"serverVersion\":\"0.1.0\"}'" \
  +"lua vim.api.nvim_exec_autocmds('VimEnter', {})" \
  +"lua local b=vim.api.nvim_get_current_buf(); local ok=pcall(vim.api.nvim_exec_autocmds,'TextChangedI',{buffer=b}); print('NOOP ok='..tostring(ok))" \
  +qa 2>&1 | grep -v 'E216\|filetypedetect'
# Expected: NOOP ok=true   (completion.lua absent -> dispatch no-ops, no throw)
```

### Level 4: Creative & Domain-Specific Validation

```bash
# 4a. Cross-buffer safety (GOTCHA C): after the ftplugin sources for buf1, a sibling buf2 has NO
#     pi-editor keymaps/autocmds, AND S20's VimEnter autocmd is still in the shared group.
PLUGIN_ROOT="$(pwd)/plugin"
nvim --headless --clean -u NORC --cmd "let &runtimepath=&runtimepath.',$PLUGIN_ROOT'" \
  +"lua vim.api.nvim_exec_autocmds('VimEnter', {})" \
  +"lua local b1=vim.api.nvim_get_current_buf(); vim.bo[b1].filetype='pi-prompt'; local b2=vim.api.nvim_create_buf(false,true); vim.api.nvim_set_current_buf(b2); local n=0; for _ in ipairs(vim.api.nvim_buf_get_keymap(b2,'i')) do n=n+1 end; local ve=#vim.api.nvim_get_autocmds({event='VimEnter',group='pi-editor'}); print('SIBLING keymaps='..n..' (expect 0)  VimEnter_kept='..ve..' (expect >=1)')" \
  +qa 2>&1 | grep '^SIBLING'
# Expected: SIBLING keymaps=0  VimEnter_kept>=1

# 4b. Idempotency: re-setting filetype (re-source) does not stack duplicates.
PLUGIN_ROOT="$(pwd)/plugin"
nvim --headless --clean -u NORC --cmd "let &runtimepath=&runtimepath.',$PLUGIN_ROOT'" \
  +"lua local b=vim.api.nvim_get_current_buf(); vim.bo[b].filetype='pi-prompt'; local function cnt() local n=0 for _ in ipairs(vim.api.nvim_get_autocmds({buffer=b,group='pi-editor'})) do n=n+1 end return n end; local a=cnt(); vim.bo[b].filetype=''; vim.bo[b].filetype='pi-prompt'; print('IDEMPOTENT before='..a..' after='..cnt())" \
  +qa 2>&1 | grep '^IDEMPOTENT'
# Expected: before == after

# 4c. autosave_on_exit=false gate: with that option, VimLeavePre/ExitPre are NOT registered.
PLUGIN_ROOT="$(pwd)/plugin"
nvim --headless --clean -u NORC --cmd "let &runtimepath=&runtimepath.',$PLUGIN_ROOT'" \
  +"lua require('pi-editor').setup({autosave_on_exit=false}); local b=vim.api.nvim_get_current_buf(); vim.bo[b].filetype='pi-prompt'; local evs={}; for _,a in ipairs(vim.api.nvim_get_autocmds({buffer=b,group='pi-editor'})) do evs[a.event]=true end; print('GATE VimLeavePre='..tostring(evs['VimLeavePre']==true)..' ExitPre='..tostring(evs['ExitPre']==true))" \
  +qa 2>&1 | grep '^GATE'
# Expected: GATE VimLeavePre=false ExitPre=false
```

## Final Validation Checklist

### Technical Validation

- [ ] Level 1 smoke prints `SMOKE_PASS` and `exit=0`.
- [ ] Level 2a plenary `tests/ftplugin_spec.lua` exits 0 (13 `it` blocks pass).
- [ ] Level 2b **non-regression**: `init_spec.lua` (13), `shim_spec.lua` (6), `activate_spec.lua` (9) exit 0.
- [ ] Level 3a handshake: real activate() → `ft=pi-prompt tw=0 fo(no t) wrap=true spell=false`.
- [ ] Level 3b handshake: 6 `pi-editor:` keymaps present after real activate().
- [ ] Level 3c: firing `TextChangedI` (completion absent) → `NOOP ok=true`.
- [ ] Level 4a: sibling buffer keymaps=0; S20 VimEnter autocmd preserved (>=1).
- [ ] Level 4b: re-source idempotent (before == after).
- [ ] Level 4c: `autosave_on_exit=false` → VimLeavePre/ExitPre not registered.
- [ ] (Optional) selene/stylua clean IF installed (NOT a hard gate — S19 GOTCHA #8).

### Feature Validation

- [ ] filetype=pi-prompt sources this ftplugin — Success (auto-sourcing).
- [ ] formatoptions has no `t`; textwidth==0; wrap==true; spell==false — Success (options).
- [ ] 6 insert keymaps registered with `pi-editor:` desc — Success (keymaps).
- [ ] InsertEnter/TextChangedI/CursorMovedI registered buffer-local — Success (completion autocmds).
- [ ] VimLeavePre/ExitPre registered by default; skipped when `autosave_on_exit=false` — Success.
- [ ] completion autocmds do not throw with completion.lua absent — Success (no-op-safe).
- [ ] sibling buffer untouched; S20 VimEnter autocmd preserved — Success (cross-buffer safe).
- [ ] re-source does not stack duplicates — Success (idempotent).
- [ ] [Mode A] header + per-keymap/per-autocmd docstrings present; `<CR>`-newline documented.

### Code Quality Validation

- [ ] Uses the gsub form for formatoptions (NOT `:remove` — GOTCHA A).
- [ ] Creates the `pi-editor` augroup with `clear=false` (NOT `true` — GOTCHA C).
- [ ] Uses buffer-scoped `nvim_clear_autocmds({buffer=buf, group=...})` for idempotency.
- [ ] Every keymap/autocmd callback goes through `dispatch` (pcall require + type-check + pcall) — GOTCHA B.
- [ ] Keymaps fall through to default via `feedkeys("n")` when not handled — GOTCHA D.
- [ ] Reads config safely (`pi.config or pi.defaults or {}`) — GOTCHA F.
- [ ] Additive ONLY: no existing file modified (init.lua / shim / S21 unchanged).

### Documentation & Deployment

- [ ] [Mode A] header documents auto-sourcing, forward contracts, the `<CR>`-newline behavior, and
      the scope boundary (wires completion/autosave; does NOT implement them).
- [ ] No new env vars, no config files, no socket, no RPC (only buffer-local attachments).
- [ ] Forward contracts (`completion.refresh/on_tab/...`, `bridge.on_exit`) stated for S30+/S24/S38.
- [ ] (README / `doc/pi-editor.txt` are separate tasks — S43/S44, NOT this task.)

---

## Anti-Patterns to Avoid

- ❌ Don't call `vim.bo[buf].formatoptions:remove("t")` — it THROWS (string has no `:remove`). Use
  the gsub form (or `vim.opt_local.formatoptions:remove("t")`). (GOTCHA A — LIVE-VERIFIED.)
- ❌ Don't `require("pi-editor.completion")` (or bridge) at load/call time without a pcall — the
  module doesn't exist yet; the first keystroke/edit would throw. Route every callback through
  `dispatch` (pcall require + type-check + pcall call). (GOTCHA B — LIVE-VERIFIED.)
- ❌ Don't `nvim_create_augroup("pi-editor", {clear=true})` inside the ftplugin — it WIPES S20's
  VimEnter autocmd and sibling buffers' autocmds. Use `clear=false` + buffer-scoped
  `nvim_clear_autocmds`. (GOTCHA C — LIVE-VERIFIED.)
- ❌ Don't make `<CR>`/`<Tab>`/etc. pure no-ops while completion.lua is absent — that breaks text
  entry in the placeholder phase. Fall through to the default via `feedkeys("n")`. (GOTCHA D.)
- ❌ Don't set `wrap`/`spell` and assume they're buffer-scoped — they're WINDOW-local and leak
  across buffers in the same window. Accepted for v1 (single-purpose pi editor); document it. (GOTCHA E.)
- ❌ Don't read `pi.config.<x>` without guarding nil `config` — the user may not have called
  `setup()`. Use `pi.config or pi.defaults or {}`. (GOTCHA F.)
- ❌ Don't make `<CR>` submit the prompt — there is no Enter-to-submit in the external editor (pi
  reads the file on editor EXIT). `<CR>` inserts a newline (or accepts if menu open). (GOTCHA G.)
- ❌ Don't override `BufWritePre` — the temp file is writable; default `:w` works (PRD §7.6 "no-op
  normal write"). Registering a no-op BufWritePre is pointless and risks breaking `:w`.
- ❌ Don't implement completion (S30+) or autosave (S38) here — S22 only WIRES them. Implementing
  them crosses task scope and re-does later work.
- ❌ Don't set runtimepath in a `+` arg for the end-to-end handshake test — use `--cmd` so the
  plugin is on rtp before filetype is set (GOTCHA H). And don't use `:lua <<HEREDOC` in `-c`/`+`
  args — write a file and `:luafile` it (GOTCHA I).
- ❌ Don't modify `init.lua` / the shim / S21 — S22 is additive; the S19/S20/S21 suites must pass
  verbatim (Non-regression).
- ❌ Don't make validation depend on stylua/selene — they aren't installed. The headless smoke +
  plenary spec + the Level-3/4 nvim checks are the hard gates (S19 GOTCHA #8).