---
name: "P2.M4.T12.S21 — VimEnter activation gate (parse env var, validate, activate or stay dormant)"
description: |
  **Implement `M.activate()`** in the existing `plugin/lua/pi-editor/init.lua` (created by
  S19). This is the plugin's **activation gate**: the single place that decides whether
  pi-editor does anything in a given Neovim session. On `VimEnter` the auto-sourced shim
  (S20, COMPLETE) calls `require("pi-editor").activate()`. `activate()` reads the bridge
  descriptor from `vim.env[M.config.env_var or "PI_NVIM_BRIDGE"]`, validates it, and —
  ONLY on a valid Unix-transport descriptor — (e) stores it on a new `M.descriptor` field
  and (f) marks the current buffer's filetype as `"pi-prompt"` (the handshake that will
  trigger S22's `ftplugin/pi-prompt.lua` when that ships). Every other case (env var
  absent, malformed JSON, valid-JSON-but-not-an-object, `transport ~= "unix"`) is
  **DORMANT**: `activate()` returns `nil` and the plugin does nothing. It NEVER throws
  and NEVER notifies (the optional one-time `vim.notify` on hard failure is task S39).
  It is **dormant-by-design** (PRD §7.1, §11): in every ordinary (non-pi) nvim session
  the env var is unset, so the plugin is an inert no-op.
  STATUS (planning): the activate() logic (6 branches), the smoke-test invocation form,
  the plenary invocation form (9/9 `it`), AND the end-to-end S20-shim → S21-activate
  wiring were all LIVE-VERIFIED against Neovim 0.12.4 + plenary via a scratch mirror of
  the real source tree — see `research/notes.md`. The real `plugin/` tree was not modified
  (research only).
  NARROW scope guard — this task does NOT: connect to the bridge socket (**S24**
  `bridge.lua` reads `M.descriptor.path` + `.token`), set buffer options/keymaps/autocmds
  (**S22** `ftplugin/pi-prompt.lua`, auto-sourced when this sets filetype), layer the
  one-time failure `vim.notify` (**S39**), implement `coords.lua`/**S28**, `menu.lua`/**S34**,
  or `health.lua`/**S42**. Setting the filetype is this gate's ONLY buffer mutation.
---

## Goal

**Feature Goal**: Add the VimEnter **activation gate** to `pi-bridge.nvim` by implementing
`M.activate()` (plus a typed `M.descriptor` field) in the existing
`plugin/lua/pi-editor/init.lua`. `activate()` is the sole decision point that turns the
plugin from dormant to active: it reads + JSON-validates the `PI_NVIM_BRIDGE` env var
that pi's bridge extension writes (`extension/pi-editor-bridge.ts:startBridge`,
P1.M3.T8.S16 — DONE), and on a valid Unix descriptor it stores it and flags the current
buffer as a pi prompt. The auto-sourced shim (S20 — DONE) already calls
`require("pi-editor").activate()` from a fire-once `VimEnter` autocmd; this task makes that
call actually do the gate work.

**Deliverable** (3 files — 1 MODIFY of the S19 module, 2 NEW tests):
- `plugin/lua/pi-editor/init.lua` — **MODIFY**: insert (before the final `return M` —
  GOTCHA A) a `pi-editor.BridgeDescriptor` LuaCATS class, `M.descriptor` (`nil` placeholder),
  and `M.activate()`. [Mode A] docstrings throughout. NO change to existing
  `setup`/`defaults`/`config`/`bridge` (additive only — §Non-regression).
- `plugin/tests/activate_smoke.lua` — NEW, plenary-FREE standalone smoke test (Level-1
  gate; `:luafile`-sourced — inherited S19 GOTCHA #10).
- `plugin/tests/activate_spec.lua` — NEW, plenary/busted spec (Level-2 gate).

> Reuses the existing `plugin/tests/minimal_init.lua` from **S19** unchanged (it already
> puts `plugin/` on `runtimepath` and plenary on rtp).

**Success Definition** (every assertion below is LIVE-VERIFIED green — see Validation):
- `require("pi-editor").activate` is a function; `M.descriptor` is `nil` before activation.
- **No env var** → `activate()` returns `nil`, `M.descriptor` stays `nil`, the buffer's
  filetype is **untouched** (dormant).
- **Valid Unix descriptor** in the env var → `activate()` returns the descriptor, sets
  `M.descriptor` (with `path`/`token`/`pid`/`cwd`/`fdAvailable`/`serverVersion`), and sets
  the current buffer's filetype to `"pi-prompt"` (proven to fire `FileType` — the S22 seam).
- **Malformed JSON** (`{not json`) → returns `nil`, no throw (`pcall(activate)` ok=true),
  `M.descriptor` nil (silent dormant — NO notify; S39 owns that).
- **Valid JSON but not an object** (`"123"` decodes to a Lua number) → returns `nil`, no
  throw (the `type(desc) == "table"` guard prevents `desc.transport` from throwing).
- **`transport == "tcp"`** → returns `nil`, dormant (v1 is Unix-only).
- **`config.env_var` override** → reads the custom env-var name instead of `PI_NVIM_BRIDGE`.
- **`M.config == nil`** (user never called `setup()`) → `activate()` self-initializes via
  `M.setup({})` and still works (no error).
- End-to-end (Level 3): the REAL S20 shim's `VimEnter` callback runs the REAL `activate()`
  — no env var → dormant; valid env var → filetype set to `pi-prompt` + descriptor stored.
- `nvim --headless --clean -u NORC` smoke test prints `SMOKE_PASS` / exit 0.
- plenary `tests/activate_spec.lua` exits 0 (9 `it` blocks pass).
- **Non-regression**: S19 `tests/init_spec.lua` (13 `it`) and S20 `tests/shim_spec.lua`
  still pass unchanged (additive edit; no behavior change to existing fields).

## User Persona (if applicable)

**Target User**: The `pi-bridge.nvim` plugin author and the downstream implementers of
**S22** (ftplugin), **S24** (bridge.lua), **S28** (coords), **S30+** (completion), **S39**
(failure notify), **S42** (health). This is the activation seam, not end-user-facing.

**Use Case**: Wires the (complete) S20 VimEnter shim to the (complete, P1) bridge
extension's env-var advertisement. Once S21 lands, a pi-launched `nvim` whose env carries
`PI_NVIM_BRIDGE` activates and flags its buffer as a pi prompt; every other nvim session
stays inert. De-risks "does the env var survive the spawn, and can we validate it safely
without ever crashing VimEnter?" before any socket/completion logic (M5+) lands.

**Pain Points Addressed**: Without this gate there is nothing to (a) decide activation,
(b) hand the descriptor to the future bridge client, or (c) flag the buffer so S22's
ftplugin will run. Getting the parse/validate/dormant logic + the non-obvious
`type(desc)=="table"` guard locked NOW (with tests) means S22 just ships a ftplugin file
and S24 just reads `M.descriptor` — neither re-derives the gate.

## Why

- **The sole activation decision point.** PRD §7.1 fixes the gate on `VimEnter`: read the
  env var, `vim.json.decode` it, require `transport == "unix"`, else do nothing. The S20
  shim already triggers `activate()` on `VimEnter`; this task *populates* `activate()` with
  exactly that gate logic. Keeping the decision in one function (not scattered across the
  shim + module) is why S20 (trigger) and S21 (gate) are cleanly separated.
- **Faithful to pi's dormancy contract (PRD §7.1, §11).** "The plugin is dormant in normal
  nvim use and activates only when pi launches the editor." The env var is that signal: it
  is process-local, set only by the pi bridge extension in the spawned `$EDITOR` child
  (PRD §2.1 — the child inherits `process.env`). Any absence/invalidity ⇒ dormant, silently.
- **Hands the descriptor to the bridge client.** PRD §7.3: `bridge.lua` (S24) needs the
  socket `path` + `token` (the auth boundary, PRD §12) to connect. This gate parses the
  descriptor ONCE and stores it on `M.descriptor` so S24 reads `require("pi-editor").descriptor`
  — no re-parsing, single source of truth.
- **Flags the buffer for the ftplugin.** PRD §7.1: "Set the buffer up as a pi prompt buffer:
  `vim.bo[buf].filetype = 'pi-prompt'`". Setting the filetype fires `FileType` (LIVE-VERIFIED),
  which auto-sources `runtime/ftplugin/pi-prompt.lua` (S22) — so this gate's single buffer
  mutation IS the handshake to all buffer-local setup. S21 owns the trigger; S22 owns the
  response.
- **Integrates with the (complete) foundation.** Builds on S19's `init.lua` (DONE —
  `setup`/`defaults`/`config`/`bridge`) and S20's shim (DONE — fire-once VimEnter autocmd
  calling `activate()`). Consumes P1's env-var advertisement (DONE). Touches none of the P1
  TypeScript.

## What

User-visible behavior: none directly in ordinary sessions (the env var is unset, so
`activate()` returns immediately on VimEnter and nothing happens). In a pi-launched session,
the user sees the buffer flagged as `pi-prompt` (visible via `:set ft?` and, once S22 lands,
its options/keymaps). The user-visible contract is the documented dormancy guarantee.

Technical requirements (the `activate()` body — exact, LIVE-VERIFIED):
- Insert in `init.lua` **before** `return M` (GOTCHA A). Additive only.
- `M.descriptor = nil` with `---@type pi-editor.BridgeDescriptor|nil` + a `---@class
  pi-editor.BridgeDescriptor` (7 fields mirroring `extension/protocol.ts`).
- `function M.activate()`:
  1. `if M.config == nil then M.setup({}) end` (self-init — GOTCHA D; `M.config` may be nil
     if the user never called `setup()`, e.g. the future NVIM_APPNAME minimal config S47).
  2. `local env_name = M.config.env_var or "PI_NVIM_BRIDGE"` (S19 forward contract).
  3. `local raw = vim.env[env_name]`
  4. `if raw == nil then return nil end` — dormant (GOTCHA: `vim.env[unset]` returns nil).
  5. `local ok, desc = pcall(vim.json.decode, raw)` — decode **THROWS** on bad JSON (GOTCHA B).
  6. `if not ok or type(desc) ~= "table" then return nil end` — the `type` check is
     load-bearing: `decode("123")`→number, `decode("true")`→bool; indexing would throw.
  7. `if desc.transport ~= "unix" then return nil end` — v1 is Unix-only.
  8. `M.descriptor = desc` — store for S24 (path+token) / S30+ (cwd).
  9. `local buf = vim.api.nvim_get_current_buf(); vim.bo[buf].filetype = "pi-prompt"` — the
     handshake to S22 (fires `FileType`; LIVE-VERIFIED).
  10. `return desc`.
- [Mode A] LuaCATS: `---@return pi-editor.BridgeDescriptor|nil desc`; file/function docstrings
  explaining dormant-by-design, never-throws/never-notifies, and the scope boundary (does
  NOT connect bridge / does NOT set buffer options).

### Success Criteria

- [ ] `require("pi-editor").activate` is a function; `M.descriptor` is `nil` before activation.
- [ ] **No env var** → returns `nil`; `M.descriptor` stays `nil`; filetype **untouched**.
- [ ] **Valid Unix descriptor** → returns the descriptor; `M.descriptor` populated
      (`path`/`token`/`pid`/`cwd`/`fdAvailable`/`serverVersion`); filetype set to `"pi-prompt"`.
- [ ] **Malformed JSON** (`{not json`) → returns `nil`; `pcall(activate)` ok=true (no throw);
      `M.descriptor` nil; **no notify** (silent — S39 owns notify).
- [ ] **Valid-JSON-but-not-object** (`"123"`) → returns `nil`; no throw (the `type` guard).
- [ ] **`transport == "tcp"`** → returns `nil` (dormant; v1 Unix-only).
- [ ] **`config.env_var` override** → reads the custom env-var name.
- [ ] **`M.config == nil`** at call time → self-inits via `setup({})`; no error.
- [ ] `activate()` is internally safe (never throws) — the S20 shim calls it WITHOUT pcall.
- [ ] End-to-end (Level 3): real shim `VimEnter` → real `activate()`: no-env dormant / valid-env
      sets filetype=`pi-prompt` + stores descriptor.
- [ ] `nvim --headless --clean -u NORC` smoke prints `SMOKE_PASS` / exit 0.
- [ ] `tests/activate_spec.lua` passes under plenary (exit 0; 9 `it` blocks).
- [ ] **Non-regression**: S19 `tests/init_spec.lua` + S20 `tests/shim_spec.lua` still pass.
- [ ] [Mode A] LuaCATS class + docstrings present and accurate (dormant-by-design explained).

## All Needed Context

### Context Completeness Check

_Passes "No Prior Knowledge":_ an implementer who has never seen this repo needs only this
PRP + `research/notes.md` + the verified commands below. Every API (`vim.json.decode`,
`vim.env[NAME]`, `vim.bo[buf].filetype`, `vim.api.nvim_get_current_buf`) is cited with a
`:help` source AND a **LIVE-VERIFIED** runnable result (see `research/notes.md`). The two
subtleties that make or break this task — (1) `decode("123")` returns a number so a
`type(desc)=="table"` guard is mandatory before `desc.transport`, and (2) the new code must
be inserted **before** `return M` — are spelled out in §Known Gotchas and embedded in the
reference implementation. The `--cmd`-vs-`+` runtimepath timing trap (essential for the
Level-3 end-to-end command) is spelled out too.

### Documentation & References

```yaml
# MUST READ — primary contract sources

- url: https://neovim.io/doc/user/lua.html#vim.json
  why: "vim.json.decode(str) — parses JSON. THROWS on invalid JSON (must pcall). Returns a
        Lua value: object→table, array→table, number→number, true/false→bool, string→string,
        null→vim.NIL (the `luanil` option maps null→nil instead; NOT needed here — the
        descriptor has no null fields)."
  critical: "decode('123') SUCCEEDS and returns a NUMBER. decode('true')→bool. Indexing a
             non-table throws ('attempt to index a number value'). So after pcall you MUST
             check `type(desc) == 'table'` before any `desc.<field>` access — this is THE
             load-bearing line of the whole gate. LIVE-VERIFIED (research/notes.md §3)."

- url: https://neovim.io/doc/user/options.html#'filetype'
  why: "Setting vim.bo[buf].filetype = 'pi-prompt' sets the option AND fires the FileType
        event (with <amatch>='pi-prompt'). This is how S21 hands off to S22's ftplugin."
  critical: "LIVE-VERIFIED: assigning filetype fires FileType exactly once. S22's
             ftplugin/pi-prompt.lua is auto-sourced on that event (needs `:filetype plugin on`,
             on by default in real user configs — S22's concern, not S21's)."

- url: https://neovim.io/doc/user/autocmd.html#FileType
  why: "The event S21's filetype assignment fires; S22 attaches to it (via the ftplugin
        convention, not a manual autocmd)."

- url: https://neovim.io/doc/user/lua.html#vim.env
  why: "vim.env.NAME reads an env var; returns nil for unset (no error); assignable +
        clearable (vim.env.NAME = nil clears). This is how activate() reads PI_NVIM_BRIDGE
        and how tests inject/clear it."
  critical: "LIVE-VERIFIED: vim.env.UNSET == nil (nil, not error). So `if raw == nil` is the
             correct dormancy guard."

- url: https://neovim.io/doc/user/api.html#nvim_get_current_buf()
  why: "Returns the current buffer's number — the buffer nvim opened on the pi temp file at
        VimEnter. S21 sets filetype on THIS buffer (PRD §11: v1 activates the VimEnter buffer)."

- file: plan/001_c56962b4fa17/P2M4T12S21/research/notes.md
  why: "LIVE-VERIFIED proof (nvim 0.12.4, this env) that the activate() logic (6 branches),
        the smoke + plenary invocation forms (9/9 it), AND the end-to-end S20-shim → S21
        wiring all run green. Includes the full verification transcript + the 8 gotchas."

- file: plugin/lua/pi-editor/init.lua
  why: "The S19 module being MODIFIED. Confirms the public surface (setup/defaults/config/
        bridge) and that M.config may be nil until setup() (hence activate()'s self-init).
        NOTE: ends with `return M` — new code MUST go before it (GOTCHA A)."

- file: plugin/plugin/pi-editor.lua
  why: "The COMPLETE S20 shim that calls activate(). Confirms it pcalls the `require` but
        NOT activate() itself (GOTCHA E — activate must be throw-free), and that it does
        NOT read the env var (that is THIS task's job)."

- file: extension/protocol.ts
  why: "The authoritative BridgeDescriptor shape (TS). The Lua @---@class below mirrors it
        field-for-field so S24's reads (.path/.token) are type-checked and the wire format
        stays identical to the extension's advertisement."

- file: extension/pi-editor-bridge.ts
  why: "The COMPLETE extension that WRITES process.env.PI_NVIM_BRIDGE in startBridge().
        Confirms the env-var name and single-line-JSON shape that activate() parses."

- file: plan/001_c56962b4fa17/architecture/system_context.md
  why: "Confirms the env var is the sufficient+precise signal (two temp-file patterns exist,
        but the env var is set for BOTH); addAutocompleteProvider is TUI-only (bridge guards
        ctx.mode); the child inherits process.env (PRD §2.1)."

- file: plan/001_c56962b4fa17/P2M4T11S20/PRP.md
  why: "The predecessor (the shim). Its FORWARD CONTRACTS section states 'S21 adds
        M.activate() to init.lua and implements the PI_NVIM_BRIDGE read + gate' — this
        task fulfills that contract. Also the source of the runtimepath/--cmd timing gotcha."

- file: plan/001_c56962b4fa17/P2M4T11S19/PRP.md
  why: "The S19 module's spec. Confirms `M.config.env_var or 'PI_NVIM_BRIDGE'` is the
        intended read (env_var is optional, NOT in defaults) and that setup() is
        side-effect-free — activate() reuses it for self-init."

- docfile: plan/001_c56962b4fa17/prd_snapshot.md
  section: "§7.1 (activation gate — the exact read/validate/filetype sequence), §11 (dormant/silent degradation), §12 (token is the auth boundary)"
  why: "These PRD sections ARE the source of truth for this task's gate logic and dormancy
        contract (reproduced in <selected_prd_content>)."
```

### Current Codebase tree (relevant slice)

```bash
pi-nvim-bridge/                  # repo root (monorepo: extension/ + plugin/)
├── extension/                   # P1 — pi-editor-bridge (TypeScript) — COMPLETE
│   ├── pi-editor-bridge.ts      # writes process.env.PI_NVIM_BRIDGE in startBridge()
│   └── protocol.ts              # BridgeDescriptor type (the env-var payload) — MIRROR this
├── plugin/                      # <-- Neovim plugin root (the runtimepath entry)
│   ├── lua/pi-editor/init.lua   # S19 (DONE) — MODIFY HERE: add M.descriptor + M.activate()
│   ├── plugin/pi-editor.lua     # S20 (DONE) — the VimEnter shim; calls activate() (unchanged)
│   └── tests/
│       ├── minimal_init.lua     # S19 (DONE) — plenary harness; puts plugin/ on rtp (REUSED)
│       ├── init_spec.lua        # S19 (DONE) — setup() spec (must STILL pass — additive edit)
│       ├── smoke.lua            # S19 (DONE) — setup() smoke
│       ├── shim_spec.lua        # S20 (DONE) — shim spec (must STILL pass — shim unchanged)
│       └── shim_smoke.lua       # S20 (DONE) — shim smoke
├── PRD.md  README.md  package.json
└── plan/001_c56962b4fa17/
    ├── architecture/{system_context,external_deps}.md
    ├── P2M4T11S19/{PRP.md, research/live-verification.md}   # S19 (predecessor, DONE)
    ├── P2M4T11S20/{PRP.md, research/notes.md}               # S20 (predecessor, DONE)
    └── P2M4T12S21/{PRP.md, research/notes.md}               # THIS task
# NOTE: plugin/lua/pi-editor/init.lua ALREADY EXISTS (S19) — this task MODIFIES it (additive).
# NOTE: ftplugin/pi-prompt.lua (S22) and bridge.lua (S24) do NOT exist yet — this task
#       establishes the M.descriptor contract they will consume.
# NOTE: stylua, selene are NOT installed (nvim 0.12.4 + plenary.nvim ARE).
```

### Desired Codebase tree with files to be added/modified

```bash
plugin/                          # runtimepath entry (unchanged)
├── lua/pi-editor/
│   └── init.lua                 # MODIFY (S19) — insert M.descriptor + M.activate() before `return M`
└── tests/
    ├── minimal_init.lua         # (S19, REUSED unchanged)
    ├── activate_smoke.lua       # NEW — plenary-FREE smoke test (Level-1 gate; :luafile-sourced)
    └── activate_spec.lua        # NEW — plenary/busted spec (Level-2 gate; 9 it blocks)
```

> **Why MODIFY (not CREATE) `init.lua`?** S19 already created the module with
> `setup`/`defaults`/`config`/`bridge`/`return M`. S21 is purely additive: it adds one
> LuaCATS class, one `nil` field (`M.descriptor`), and one function (`M.activate`). The
> S20 shim already calls `require("pi-editor").activate()`, so `M.activate` MUST live on
> the module's returned table. Keeping it in `init.lua` (per tasks.json) preserves the
> single-module entry point every downstream task requires from.

### Known Gotchas of our codebase & Library Quirks

```lua
-- GOTCHA A — insert the new code BEFORE `return M`, NEVER after it.
-- The S19 module ends with `return M`. Lua requires `return` to be the FINAL statement
--   of a chunk (only `end`/EOF may follow). Appending `M.descriptor = ...` / `function M.activate()`
--   AFTER `return M` is a SYNTAX ERROR: "'<eof>' expected near 'M'" (E5113). LIVE-VERIFIED:
--   appending after return M fails to load; inserting before it loads cleanly (135-line file).
--   FIX: locate the final `return M`, splice the new block in just above it.

-- GOTCHA B — pcall(vim.json.decode) success does NOT mean you got a table.
-- decode('{"a":1}') -> table.  decode('123') -> NUMBER.  decode('true') -> boolean.
--   decode('"x"') -> string.  decode('[]') -> table.  decode('null') -> vim.NIL.
-- Indexing a number/boolean with `.transport` THROWS ("attempt to index a number value").
-- So the guard MUST be `if not ok or type(desc) ~= "table" then return nil end` — the
--   `type` check is what saves you when an adversary/garbage env var is valid-JSON-but-a-scalar.
-- LIVE-VERIFIED (research/notes.md §3, case 4): "123" -> pcall ok=true, type=number; without
--   the guard, desc.transport throws; WITH it, returns nil (dormant) cleanly. THIS IS THE
--   LOAD-BEARING LINE OF THE WHOLE GATE.

-- GOTCHA C — for the Level-3 end-to-end VimEnter test, set runtimepath via --cmd (step 3),
--   NOT via a + arg (step 17).
-- The S20 shim is auto-sourced at startup step 12 (`:help load-plugins`), which scans
--   runtimepath. If rtp is set in a + arg (step 17), it is ALREADY step 17 — the shim was
--   never sourced, so its VimEnter autocmd does not exist, and firing VimEnter is a no-op.
-- LIVE-VERIFIED: +arg rtp → VimEnter fires nothing (filetype stays empty even with env set);
--   --cmd rtp → shim sources at step 12 → VimEnter runs activate() → filetype=pi-prompt.
--   (Inherited from S20 GOTCHA #3; essential for THIS task's Level-3 command.)

-- GOTCHA D — M.config may be nil when activate() is called.
-- The S20 shim does NOT call setup() (that's the user's config). In a normal session the
--   user's init runs setup() before VimEnter — but robustly, M.config can be nil (e.g. the
--   future NVIM_APPNAME minimal config S47, or a user who installed but didn't configure).
--   Reading M.config.env_var on a nil M.config THROWS. FIX: guard at the top:
--   `if M.config == nil then M.setup({}) end` (applies documented defaults; idempotent).
-- LIVE-VERIFIED (research/notes.md §3, case: config nil): self-init works, no error.

-- GOTCHA E — activate() must NEVER throw; the shim does NOT pcall it.
-- The S20 shim does `local ok, pi = pcall(require, "pi-editor"); if ok and type(pi.activate)
--   == "function" then pi.activate() end`. The require is pcalled; activate() is NOT. So a
--   throw inside activate() propagates out of the VimEnter autocmd callback (noisy; can abort
--   other VimEnter handlers). Every failure path MUST `return nil` cleanly. The pcall(decode)
--   + the type() guards + the nil-checks make the body safe by construction; do NOT add any
--   un-pcalled call that could throw (e.g. never index `desc` before the type check).
--   (S20 PRP GOTCHA #8 documents this deliberate split.)

-- GOTCHA F — dormancy is SILENT in S21. Do NOT vim.notify on failure here.
-- PRD §11: "degrade silently ... optionally with a single vim.notify the first time."
--   The dedicated one-time-notify is task S39 ("Graceful failure — degrade to normal buffer
--   with single notify"). S20 PRP: "activate / S21+S39 own activate()'s internal resilience
--   (silent degrade / one-time notify)." So S21's baseline is SILENT (return nil); S39 layers
--   the notify later. Adding a notify now would double-notify once S39 ships.

-- GOTCHA G — setting filetype is the ONLY buffer mutation; do not over-reach.
-- Scope (tasks.json steps g/h): trigger ftplugin = via S22; initiate bridge = placeholder,
--   wired in M5 (S24). So activate() does NOT: set buffer options/keymaps (S22's ftplugin),
--   connect a socket (S24 bridge.lua reads M.descriptor.path+.token), require bridge.lua,
--   start completion (S30+), or read the buffer filename. Setting filetype=pi-prompt is the
--   WHOLE buffer-side job — it is the handshake that makes S22's ftplugin run later.

-- GOTCHA H — do NOT match the temp-file filename; the env var is sufficient + precise.
-- architecture/system_context.md notes TWO temp-file patterns (pi-editor-<ts>.pi.md and
--   pi-extension-editor-<ts>.md). tasks.json: "env var alone is sufficient and precise."
--   Do NOT add a buffer-name regex (`pi-editor-%d+%.pi%.md$`) as a secondary gate — the env
--   var is set for BOTH code paths, so it is the only signal needed. (PRD §7.1 mentions the
--   filename match as a possible SECONDARY signal, but it is optional and not required.)

-- GOTCHA I — a ':lua <<HEREDOC' does NOT work inside -c/+ command-line args.
-- (Inherited from S19 GOTCHA #10 / S20 GOTCHA #9; same nvim 0.12.4 E5107 behaviour.) For
--   multi-statement validation from the CLI, write a file and `:luafile` it. That is why
--   activate_smoke.lua exists (and why the spec is a plenary file, not an inline -c chunk).

-- GOTCHA J — clearing an env var in a test: `vim.env.NAME = nil` (NOT os.setenv).
-- LIVE-VERIFIED: `vim.env.PI_NVIM_BRIDGE = nil` makes the next `vim.env[NAME]` read return
--   nil. Use this in before_each to guarantee a clean dormant baseline. (Setting it:
--   `vim.env.NAME = '<json>'.`)
```

## Implementation Blueprint

### Data models and structure (LuaCATS — the [Mode A] docs)

Add this `---@class` (mirrors `extension/protocol.ts` `BridgeDescriptor` field-for-field) and
the `M.descriptor` placeholder. Both go ABOVE `M.activate()` and BEFORE `return M`:

```lua
--- Bridge descriptor parsed from the env var by |activate()|. `nil` until activation
--- succeeds. Downstream modules read it: bridge.lua (S24) uses `.path` + `.token` to
--- connect; completion (S30+) uses `.cwd`. Mirrors the extension's BridgeDescriptor
--- (extension/protocol.ts); all fields are present & non-null when transport=="unix".
---@class pi-editor.BridgeDescriptor
---@field transport "unix" Transport type (v1 literal "unix"; PRD §5.1 names a future "tcp").
---@field path string Unix domain socket path (${tmpdir}/pi-editor-bridge-<uuid>.sock).
---@field token string Random 32-byte hex secret — the REAL auth boundary (PRD §5.3, §12).
---@field pid integer pi's process id.
---@field cwd string pi session working directory (ctx.cwd).
---@field fdAvailable boolean Whether the `fd` binary resolved (controls @file fuzzy search).
---@field serverVersion string Bridge server version string (PRD §6.4 hardcodes "0.1.0").
```

> Mirror the TS `BridgeDescriptor` EXACTLY (same field names, same types). S24 will read
> `.path`/`.token` via `require("pi-editor").descriptor.path` and get lua-language-server
> completion/checking from this class. Do NOT add fields the extension does not write.

### Implementation Tasks (ordered by dependencies)

```yaml
Task 1: MODIFY plugin/lua/pi-editor/init.lua  (add M.descriptor + M.activate() — THE deliverable)
  - LOCATE the final `return M` in the existing S19 module.
  - INSERT (immediately BEFORE `return M`, never after — GOTCHA A):
      (1) the pi-editor.BridgeDescriptor @---@class block (above),
      (2) `---@type pi-editor.BridgeDescriptor|nil` then `M.descriptor = nil`,
      (3) `function M.activate() … end` (see Implementation Patterns).
  - DOCS MODE A: a function docstring on activate() explaining: dormant-by-design; the
        4 dormancy paths (no env / bad JSON / non-object JSON / non-unix); never-throws &
        never-notifies (S39 owns notify); the scope boundary (does NOT connect bridge S24,
        does NOT set buffer opts S22; filetype is the ONLY buffer mutation — the S22 handshake);
        the @---@return pi-editor.BridgeDescriptor|nil desc.
  - DO NOT touch setup/defaults/config/bridge (additive only — §Non-regression).
  - DO NOT require any other pi-editor module (bridge.lua/coords.lua/… do not exist yet).
  - DO NOT add a filename regex (GOTCHA H) or a vim.notify (GOTCHA F).
  - PLACEMENT: plugin/lua/pi-editor/init.lua (the module the S20 shim already calls into).

Task 2: CREATE plugin/tests/activate_smoke.lua  (plenary-FREE fast smoke — the Level-1 gate)
  - CONTENT (see Implementation Patterns): a standalone script that computes plugin_root from
        its own path (debug.getinfo + fnamemodify ':p'/':h:h'), appends it to runtimepath,
        requires "pi-editor", and runs check(cond,msg) assertions covering: activate is a fn;
        descriptor nil pre-activate; no-env→dormant+filetype-untouched; valid→activates+
        descriptor+filetype=pi-prompt. Calls vim.cmd('cquit 1') on any failure (reliable exit).
  - ENV handling: set `vim.env.PI_NVIM_BRIDGE = nil` before the dormant check; set it to a
        valid JSON string before the activate check. `vim.bo[0].filetype = ""` to assert
        "untouched" deterministically.
  - WHY: instant, dependency-free feedback (no plenary). activate_spec.lua is the formal suite.
  - GOTCHA: source via :luafile, NOT a :lua <<HEREDOC in a -c/+ arg (GOTCHA I).
  - PLACEMENT: plugin/tests/activate_smoke.lua.
  - DEPENDENCIES: Task 1 (the modified init.lua).

Task 3: CREATE plugin/tests/activate_spec.lua  (plenary/busted spec — the Level-2 gate)
  - CONTENT (see Implementation Patterns): a describe("pi-editor.activate gate", …) block.
        before_each: `package.loaded["pi-editor"] = nil`; require fresh; `vim.env.PI_NVIM_BRIDGE
        = nil`; `pi.descriptor = nil`; `vim.bo[0].filetype = ""` (clean dormant baseline each test).
        Cover ALL Success Criteria as `it` blocks: (1) activate is a fn; (2) descriptor nil
        pre-activate; (3) no-env→dormant+filetype-untouched; (4) valid unix→activates+descriptor
        fields+filetype=pi-prompt; (5) malformed JSON→dormant+pcall-ok (no throw); (6)
        valid-JSON-number "123"→dormant via type guard + pcall-ok; (7) transport=tcp→dormant;
        (8) config.env_var override; (9) M.config nil→self-init. (9 it blocks.)
  - ASSERTIONS: assert.are.equals (scalars/strings/type()), assert.is_nil/is_not_nil/is_true,
        assert.has_no.errors NOT used for the pcall cases — wrap the throwing-risk calls in
        `pcall(pi.activate)` and assert `ok` is true AND result is nil (proves no-throw + dormant).
  - PLACEMENT: plugin/tests/activate_spec.lua.
  - DEPENDENCIES: Task 1 (the modified init.lua) + the S19 harness (plugin/tests/minimal_init.lua).
```

### Implementation Patterns & Key Details

```lua
-- === plugin/lua/pi-editor/init.lua — the S21 ADDITION (splice in before the final `return M`) ===
-- (LIVE-VERIFIED to pass the smoke + plenary + end-to-end gates. The implementer may ship
--  this verbatim — it satisfies every Success Criterion. It is ADDITIVE: it does not alter
--  setup/defaults/config/bridge.)

-- ===========================================================================
-- S21 — VimEnter activation gate (PRD §7.1, §11). Called once by the auto-sourced
-- shim (plugin/pi-editor.lua) on VimEnter. DORMANT BY DESIGN: returns nil unless pi
-- spawned this editor with the bridge descriptor env var set AND valid. NEVER throws
-- and NEVER notifies (the one-time notify on hard failure is task S39's job). The shim
-- calls this WITHOUT a pcall, so internal safety is load-bearing (GOTCHA E).
-- ===========================================================================

--- Bridge descriptor parsed from the env var by |activate()|. `nil` until activation
--- succeeds. Downstream modules read it: bridge.lua (S24) uses `.path` + `.token` to
--- connect; completion (S30+) uses `.cwd`. Mirrors the extension's BridgeDescriptor
--- (extension/protocol.ts); all fields are present & non-null when transport=="unix".
---@class pi-editor.BridgeDescriptor
---@field transport "unix" Transport type (v1 literal "unix"; PRD §5.1 names a future "tcp").
---@field path string Unix domain socket path (${tmpdir}/pi-editor-bridge-<uuid>.sock).
---@field token string Random 32-byte hex secret — the REAL auth boundary (PRD §5.3, §12).
---@field pid integer pi's process id.
---@field cwd string pi session working directory (ctx.cwd).
---@field fdAvailable boolean Whether the `fd` binary resolved (controls @file fuzzy search).
---@field serverVersion string Bridge server version string (PRD §6.4 hardcodes "0.1.0").

--- The parsed bridge descriptor once |activate()| succeeds; `nil` in every dormant session
--- and before the first successful activation. Read by downstream modules (see class doc).
---@type pi-editor.BridgeDescriptor|nil
M.descriptor = nil

--- Activate pi-editor for this session — the VimEnter entry point.
---
--- Called once per session by the auto-sourced shim (`plugin/pi-editor.lua`). Reads the
--- bridge descriptor from the env var named by |pi-editor.Config.env_var| (default
--- "PI_NVIM_BRIDGE"), validates it, and — ONLY on success — stores it on |descriptor|
--- and marks the current buffer as a pi prompt (`vim.bo.filetype = "pi-prompt"`).
---
--- DORMANT BY DESIGN (PRD §7.1, §11): in every ordinary (non-pi) nvim session the env var
--- is unset, so this returns nil immediately and the plugin does nothing. A descriptor that
--- is malformed JSON, valid JSON but not a JSON object (e.g. a bare `123`/`true`/`"s"`), or
--- has `transport ~= "unix"` is ALSO treated as dormant. This function NEVER throws and
--- NEVER notifies (the optional one-time `vim.notify` on hard failure is task S39's job).
---
--- Scope (what this gate does NOT do): it does NOT connect to the bridge (that is
--- `bridge.lua` / S24, which reads this |descriptor|) and it does NOT set buffer options or
--- keymaps (that is `ftplugin/pi-prompt.lua` / S22, auto-sourced when this sets filetype).
--- Setting the filetype is this gate's ONLY buffer mutation; it is the handshake to S22.
---
---@return pi-editor.BridgeDescriptor|nil desc The parsed descriptor on success; nil if dormant.
function M.activate()
  -- Self-sufficient if the user's config never called setup() (e.g. the NVIM_APPNAME minimal
  -- config, S47). setup({}) applies the documented defaults and sets M.config. (GOTCHA D)
  if M.config == nil then M.setup({}) end
  local env_name = M.config.env_var or "PI_NVIM_BRIDGE"
  local raw = vim.env[env_name]
  if raw == nil then return nil end                       -- (b) no env var -> dormant
  local ok, desc = pcall(vim.json.decode, raw)            -- (c) decode (THROWS -> pcall)
  if not ok or type(desc) ~= "table" then return nil end  -- malformed / non-object -> dormant (GOTCHA B)
  if desc.transport ~= "unix" then return nil end         -- (d) wrong transport -> dormant
  M.descriptor = desc                                     -- (e) store for S24/S30+
  local buf = vim.api.nvim_get_current_buf()
  vim.bo[buf].filetype = "pi-prompt"                      -- (f) activate -> fires FileType (S22 seam)
  return desc                                             -- (g)/(h) are S22/S24's job (see doc)
end
```

```lua
-- === plugin/tests/activate_smoke.lua — standalone (plenary-FREE) smoke test for activate() ===
-- Run from the REPO ROOT:
--   nvim --headless --clean -u NORC +"luafile plugin/tests/activate_smoke.lua" +qa ; echo exit=$?
-- Exits 0 on pass (prints SMOKE_PASS), 1 on any check failure (via cquit). Zero deps.
local me = debug.getinfo(1, "S").source:sub(2)
me = vim.fn.fnamemodify(me, ":p")                  -- absolute path of THIS file
local plugin_root = vim.fn.fnamemodify(me, ":h:h") -- .../plugin  (rtp entry — S19 GOTCHA #1)
vim.opt.runtimepath:append(plugin_root)

local fails = 0
local function check(cond, msg)
  if not cond then io.stderr:write("FAIL: " .. msg .. "\n"); fails = fails + 1 end
end

local ok, pi = pcall(require, "pi-editor")
check(ok, "require('pi-editor') failed: " .. tostring(pi))
pi = ok and pi or {}

check(type(pi.activate) == "function", "activate is not a function")
check(pi.descriptor == nil, "descriptor should be nil before activate")

-- Dormant: no env var.
vim.env.PI_NVIM_BRIDGE = nil
vim.bo[0].filetype = ""
check(pi.activate() == nil, "no env var -> activate should return nil")
check(pi.descriptor == nil, "no env var -> descriptor should stay nil")
check(vim.bo[0].filetype == "", "no env var -> filetype should be untouched")

-- Activate: valid Unix descriptor.
vim.env.PI_NVIM_BRIDGE =
  '{"transport":"unix","path":"/tmp/x.sock","token":"t","pid":2,"cwd":"/p","fdAvailable":false,"serverVersion":"0.1.0"}'
local d = pi.activate()
check(d ~= nil, "valid descriptor -> activate should return non-nil")
check(pi.descriptor ~= nil and pi.descriptor.path == "/x.sock", "descriptor.path should be stored")
check(vim.bo[0].filetype == "pi-prompt", "valid descriptor -> filetype should be pi-prompt")

if fails > 0 then
  io.stderr:write(fails .. " check(s) failed\n")
  vim.cmd("cquit 1")
end
io.stdout:write("SMOKE_PASS\n")
```

```lua
-- === plugin/tests/activate_spec.lua — the spec (covers every Success Criterion) ===
-- Run (from the plugin/ directory):
--   nvim --headless --clean -u tests/minimal_init.lua \
--     -c 'lua require("plenary.busted").run("tests/activate_spec.lua")'
describe("pi-editor.activate gate", function()
  local pi

  before_each(function()
    package.loaded["pi-editor"] = nil   -- fresh module per test
    pi = require("pi-editor")
    vim.env.PI_NVIM_BRIDGE = nil      -- clean dormant baseline
    pi.descriptor = nil
    vim.bo[0].filetype = ""             -- deterministic "untouched" assertion
  end)

  local function valid_desc()
    return '{"transport":"unix","path":"/tmp/a.sock","token":"t","pid":1,"cwd":"/p",'
      .. '"fdAvailable":true,"serverVersion":"0.1.0"}'
  end

  it("exposes activate as a function", function()
    assert.are.equals("function", type(pi.activate))
  end)

  it("descriptor is nil before activation", function()
    assert.is_nil(pi.descriptor)
  end)

  it("no env var -> dormant (nil return, descriptor nil, filetype untouched)", function()
    local r = pi.activate()
    assert.is_nil(r)
    assert.is_nil(pi.descriptor)
    assert.are.equals("", vim.bo[0].filetype)
  end)

  it("valid unix descriptor -> activates (descriptor fields set, filetype=pi-prompt)", function()
    vim.env.PI_NVIM_BRIDGE = valid_desc()
    local r = pi.activate()
    assert.is_not_nil(r)
    assert.are.equals("/tmp/a.sock", pi.descriptor.path)
    assert.are.equals("unix", pi.descriptor.transport)
    assert.are.equals("t", pi.descriptor.token)
    assert.are.equals("pi-prompt", vim.bo[0].filetype)
  end)

  it("malformed JSON -> dormant, no throw (pcall ok)", function()
    vim.env.PI_NVIM_BRIDGE = "{not json"
    local ok, r = pcall(pi.activate)
    assert.is_true(ok)          -- proves activate did not throw
    assert.is_nil(r)
    assert.is_nil(pi.descriptor)
  end)

  it("valid-JSON-number (123) -> dormant via the type guard, no throw", function()
    vim.env.PI_NVIM_BRIDGE = "123"
    local ok, r = pcall(pi.activate)
    assert.is_true(ok)          -- the type() guard prevented desc.transport from throwing
    assert.is_nil(r)
    assert.is_nil(pi.descriptor)
  end)

  it("transport=tcp -> dormant (v1 is Unix-only)", function()
    vim.env.PI_NVIM_BRIDGE = '{"transport":"tcp","path":"x","token":"t"}'
    local r = pi.activate()
    assert.is_nil(r)
    assert.is_nil(pi.descriptor)
  end)

  it("config.env_var override reads the custom env-var name", function()
    pi.setup({ env_var = "MY_BRIDGE" })
    vim.env.MY_BRIDGE = '{"transport":"unix","path":"/c.sock","token":"z"}'
    local r = pi.activate()
    assert.is_not_nil(r)
    assert.are.equals("/c.sock", pi.descriptor.path)
  end)

  it("self-initializes config when setup() was not called (no error)", function()
    pi.config = nil             -- simulate user never calling setup()
    vim.env.PI_NVIM_BRIDGE = valid_desc()
    local r = pi.activate()
    assert.is_not_nil(r)
    assert.is_not_nil(pi.config)          -- setup({}) ran inside activate()
    assert.are.equals("pi-prompt", vim.bo[0].filetype)
  end)
end)
```

### Integration Points

```yaml
MODULE SURFACE (public API — what this task ADDS to the existing module):
  - require("pi-editor").activate()        -> pi-editor.BridgeDescriptor|nil  (THE gate)
  - require("pi-editor").descriptor        -> pi-editor.BridgeDescriptor|nil  (parsed on success)
  # UNCHANGED by this task: setup, defaults, config, bridge (additive edit — §Non-regression).

CALLER (already wired — S20, COMPLETE):
  - plugin/plugin/pi-editor.lua VimEnter autocmd does:
      local ok, pi = pcall(require, "pi-editor")
      if ok and type(pi.activate) == "function" then pi.activate() end
    # S21 makes `pi.activate` exist (type == "function") so the guard starts invoking it.
    # No change to the shim is required.

FORWARD CONTRACTS (do NOT implement here — just don't break them):
  - S22 (ftplugin/pi-prompt.lua): auto-sourced on the FileType event this gate fires. It owns
        buffer options/keymaps/autocmds. S21's ONLY contribution to S22 is setting filetype.
  - S24 (bridge.lua): reads require("pi-editor").descriptor.path + .token to connect() +
        handshake. Established here; do not rename `M.descriptor`.
  - S30+ (completion): reads require("pi-editor").descriptor.cwd.
  - S39 (failure notify): wraps/extends activate()'s resilience with a one-time vim.notify.
        S21 stays SILENT so S39 can layer the notify without double-notifying.
  - S42 (health.lua): reads M.config + M.defaults + (now) M.descriptor for diagnostics.

AUGROUP (cohesion):
  - this task creates NO autocmds (the S20 shim owns the VimEnter autocmd). The "pi-editor"
    augroup convention is used by S22/S24's buffer-local autocmds later.

NO DATABASE / NO NETWORK / NO CONFIG FILES. The ONLY side effects are: storing M.descriptor
  (a Lua table) and setting vim.bo[buf].filetype. No socket, no RPC, no file I/O.
```

## Validation Loop

> **Run all commands from the REPO ROOT** (`/home/dustin/projects/pi-nvim-bridge`).
> The plugin root is `$(pwd)/plugin`. **Every command's FORM + the underlying activate()
> logic is LIVE-VERIFIED green** on the installed Neovim 0.12.4 + plenary.nvim (see
> `research/notes.md` — verified via a scratch mirror of the real source tree; the real
> `plugin/` tree was not modified during planning). NOTE: `nvim --headless --clean -u NORC`
> prints a benign `Error in .../syntax/syntax.vim: E216: No such group or event:
> filetypedetect BufRead` (an nvim filetype/syntax init artifact, NOT from our code; exit
> code stays 0). Judge pass/fail by our markers (`SMOKE_PASS`, the `Success:/Failed:`
> plenary line, `filetype=[…]`, `descriptor=…`) and `$?`, not that warning (S19 GOTCHA #11).

### Level 1: Syntax & Load (Immediate Feedback — dependency-free, no plenary)

```bash
# 1a. Smoke test via the deliverable plugin/tests/activate_smoke.lua (plenary-FREE fast feedback).
#     The script sets its own runtimepath, exercises the dormant + activate paths, and uses
#     cquit(1) on failure (reliable exit code). Run from the REPO ROOT. NO :lua <<HEREDOC (GOTCHA I).
nvim --headless --clean -u NORC +"luafile plugin/tests/activate_smoke.lua" +qa
echo "exit=$?   # 0 = pass (prints 'SMOKE_PASS'), 1 = a check failed"
# LIVE-VERIFIED (research/notes.md §4): prints SMOKE_PASS, exit=0.
```

```bash
# 1b. (Optional, only if installed) Lua lint/format. NOT a hard gate (inherited S19 GOTCHA #8).
command -v selene >/dev/null && selene -q plugin/lua || echo "selene not installed (skipped; optional)"
command -v stylua >/dev/null && stylua --check plugin/lua || echo "stylua not installed (skipped; optional)"
```

### Level 2: Unit Tests (plenary spec)

```bash
# 2a. In-process plenary run (reuses the S19 minimal_init.lua — it already puts plugin/ on
#     rtp and plenary on rtp). Exit codes: 0 = all pass, 1 = an 'it' failed, 2 = load/error.
cd plugin
nvim --headless --clean -u tests/minimal_init.lua \
  -c 'lua require("plenary.busted").run("tests/activate_spec.lua")'
echo "exit=$?"
cd ..
# LIVE-VERIFIED (research/notes.md §4): exit=0, prints "Success: 9  Failed: 0  Errors: 0".
```

```bash
# 2b. NON-REGRESSION — the S19 + S20 suites MUST still pass (S21 is additive; it must not
#     alter setup/defaults/config/bridge or the shim). Re-run both predecessor specs.
cd plugin
nvim --headless --clean -u tests/minimal_init.lua -c 'lua require("plenary.busted").run("tests/init_spec.lua")'
echo "init_spec exit=$?   # expect 0 (13 it blocks — S19 setup)"
nvim --headless --clean -u tests/minimal_init.lua -c 'lua require("plenary.busted").run("tests/shim_spec.lua")'
echo "shim_spec exit=$?   # expect 0 (6 it blocks — S20 shim; unchanged by S21)"
cd ..
```

### Level 3: Integration (real shim → real activate, end-to-end)

```bash
# 3a. End-to-end wiring: the REAL S20 shim's VimEnter autocmd runs the REAL activate().
#     CRITICAL (GOTCHA C): set runtimepath via --cmd (step 3) so the shim auto-sources at
#     step 12 — a + arg (step 17) is too late and VimEnter fires nothing.
PLUGIN_ROOT="$(pwd)/plugin"
echo "--- (a) NO env var: VimEnter -> dormant, no error, filetype untouched ---"
nvim --headless --clean -u NORC --cmd "lua vim.opt.runtimepath:append('$PLUGIN_ROOT')" \
  +"lua vim.bo[0].filetype=''" \
  +"lua vim.api.nvim_exec_autocmds('VimEnter', {})" \
  +"lua print('dormant: filetype=['..vim.bo[0].filetype..'] descriptor='..tostring(require('pi-editor').descriptor))" \
  +qa 2>&1 | grep -v 'E216\|filetypedetect'
# Expected: dormant: filetype=[] descriptor=nil

echo "--- (b) VALID env var: VimEnter -> activate runs -> filetype=pi-prompt + descriptor stored ---"
nvim --headless --clean -u NORC --cmd "lua vim.opt.runtimepath:append('$PLUGIN_ROOT')" \
  +"lua vim.env.PI_NVIM_BRIDGE='{\"transport\":\"unix\",\"path\":\"/tmp/real.sock\",\"token\":\"sekret\",\"pid\":99,\"cwd\":\"/proj\",\"fdAvailable\":true,\"serverVersion\":\"0.1.0\"}'" \
  +"lua vim.api.nvim_exec_autocmds('VimEnter', {})" \
  +"lua local d=require('pi-editor').descriptor; print('activated: filetype=['..vim.bo[0].filetype..'] path='..tostring(d and d.path)..' token='..tostring(d and d.token))" \
  +qa 2>&1 | grep -v 'E216\|filetypedetect'
# Expected: activated: filetype=[pi-prompt] path=/tmp/real.sock token=sekret
# LIVE-VERIFIED (research/notes.md §5): both (a) and (b) print exactly the expected lines.
```

```bash
# 3b. The filetype → FileType seam (S21's contract to S22). Prove setting filetype fires the
#     FileType event (so S22's future ftplugin WILL be auto-sourced on it). Pure API check.
nvim --headless --clean -u NORC +"lua
  vim.g.fired = 0
  vim.api.nvim_create_autocmd('FileType', { pattern='pi-prompt',
    callback = function() vim.g.fired = vim.g.fired + 1 end })
  vim.bo[0].filetype = 'pi-prompt'
  print('FileType fired count='..tostring(vim.g.fired))
" +qa 2>&1 | grep -v 'E216\|filetypedetect'
# Expected: FileType fired count=1   (LIVE-VERIFIED research/notes.md §6)
```

### Level 4: Creative & Domain-Specific Validation

```bash
# 4a. The load-bearing type-guard gotcha (GOTCHA B): a valid-JSON-but-NUMBER env var must be
#     dormant WITHOUT throwing. If the guard were missing, desc.transport would throw. Prove
#     activate() returns nil and the process exits 0.
PLUGIN_ROOT="$(pwd)/plugin"
nvim --headless --clean -u NORC --cmd "lua vim.opt.runtimepath:append('$PLUGIN_ROOT')" \
  +"lua vim.env.PI_NVIM_BRIDGE='123'" \
  +"lua local ok,r=pcall(require('pi-editor').activate); io.stdout:write('number-env: ok='..tostring(ok)..' r='..tostring(r)..'\n')" \
  +qa 2>&1 | grep '^number-env:'
echo "   ^ Expected: number-env: ok=true r=nil   (the type() guard saved desc.transport)"
# LIVE-VERIFIED (research/notes.md §3 case 4).

# 4b. Dormancy / no-spam: a session with the plugin on rtp but NO env var fires VimEnter and
#     produces NO pi-editor error and NO notify (S21 is silent — S39 owns notify).
nvim --headless --clean -u NORC --cmd "lua vim.opt.runtimepath:append('$PLUGIN_ROOT')" \
  +"lua vim.api.nvim_exec_autocmds('VimEnter', {})" \
  +"lua print('dormant_ok=yes')" +qa 2>&1 | grep -E '^(dormant_ok|Error.*pi%-editor|notify)' || true
# Expected: 'dormant_ok=yes' and NO 'Error...pi-editor' / 'notify' line.

# 4c. Malformed env var is dormant SILENTLY (no throw escapes the VimEnter callback).
nvim --headless --clean -u NORC --cmd "lua vim.opt.runtimepath:append('$PLUGIN_ROOT')" \
  +"lua vim.env.PI_NVIM_BRIDGE='{broken'" \
  +"lua vim.bo[0].filetype=''" \
  +"lua local ok=pcall(vim.api.nvim_exec_autocmds,'VimEnter',{}); print('malformed: ok='..tostring(ok)..' ft=['..vim.bo[0].filetype..']')" \
  +qa 2>&1 | grep '^malformed:'
# Expected: malformed: ok=true ft=[]   (LIVE-VERIFIED research/notes.md §5 case c).
```

## Final Validation Checklist

### Technical Validation

- [ ] Level 1 smoke test prints `SMOKE_PASS` and `exit=0`.
- [ ] Level 2a plenary spec `tests/activate_spec.lua` exits 0 (9 `it` blocks pass).
- [ ] Level 2b **non-regression**: `init_spec.lua` (13) and `shim_spec.lua` (6) still exit 0.
- [ ] Level 3a (a): no env var → `filetype=[] descriptor=nil`.
- [ ] Level 3a (b): valid env var → `filetype=[pi-prompt] path=/tmp/real.sock token=sekret`.
- [ ] Level 3b: setting filetype fires `FileType` (`count=1`) — the S21→S22 seam.
- [ ] Level 4a: number env var → `ok=true r=nil` (the `type()` guard holds).
- [ ] Level 4b: dormant session — no pi-editor error, no notify.
- [ ] Level 4c: malformed env var → `ok=true ft=[]` (silent dormant, no throw).
- [ ] (Optional) selene/stylua clean IF installed (NOT a hard gate — S19 GOTCHA #8).

### Feature Validation

- [ ] `activate` is a function; `M.descriptor` is `nil` before activation.
- [ ] No env var → dormant (nil return, descriptor nil, filetype untouched) — Success #2.
- [ ] Valid Unix descriptor → activates (descriptor fields set, filetype=`pi-prompt`) — Success #3.
- [ ] Malformed JSON → dormant, no throw, no notify — Success #4.
- [ ] Valid-JSON-number (`"123"`) → dormant via the `type()` guard, no throw — Success #5.
- [ ] `transport == "tcp"` → dormant — Success #6.
- [ ] `config.env_var` override reads the custom env-var name — Success #7.
- [ ] `M.config == nil` → self-inits via `setup({})`, no error — Success #8.
- [ ] `activate()` is internally safe (never throws) — Success #9.
- [ ] [Mode A] LuaCATS `pi-editor.BridgeDescriptor` class + `activate()` docstring present.

### Code Quality Validation

- [ ] The new code is inserted **before** `return M` (GOTCHA A — appending breaks the module).
- [ ] The `type(desc) == "table"` guard is present right after the pcall (GOTCHA B — load-bearing).
- [ ] `activate()` self-inits config (`if M.config == nil then M.setup({}) end`) — GOTCHA D.
- [ ] `activate()` never throws (shim does not pcall it) and never notifies (S39 owns that) — GOTCHA E/F.
- [ ] Additive ONLY: `setup`/`defaults`/`config`/`bridge` unchanged (S19/S20 suites still pass).
- [ ] Scope held: no bridge connect, no buffer opts/keymaps, no filename regex (GOTCHA G/H).
- [ ] `M.descriptor` field name is exactly `descriptor` (forward contract for S24/S30+).
- [ ] LuaCATS class mirrors `extension/protocol.ts` `BridgeDescriptor` field-for-field.

### Documentation & Deployment

- [ ] [Mode A] docstring explains dormant-by-design, the 4 dormancy paths, never-throws/
      never-notifies, and the scope boundary (does NOT connect bridge / does NOT set opts).
- [ ] No new env vars introduced (this READS `PI_NVIM_BRIDGE`, set by the P1 extension).
- [ ] No config files, no socket, no RPC (the only side effects are storing a table + filetype).
- [ ] (README / `doc/pi-editor.txt` are separate tasks — S43/S44, NOT this task.)

---

## Anti-Patterns to Avoid

- ❌ Don't append the new code AFTER `return M` — Lua requires `return` last; splice in
  **before** it or the module fails to load (`'<eof>' expected near 'M'`, E5113) (GOTCHA A).
- ❌ Don't drop the `type(desc) == "table"` guard. `pcall(vim.json.decode, "123")` SUCCEEDS
  and returns a number; `desc.transport` then throws. The type check is what makes the gate
  crash-proof against a scalar env var (GOTCHA B — LIVE-VERIFIED).
- ❌ Don't read `M.config.env_var` without ensuring `M.config` is non-nil — if the user never
  called `setup()`, indexing nil throws. Self-init with `M.setup({})` (GOTCHA D).
- ❌ Don't let `activate()` throw on any path. The S20 shim calls it WITHOUT a pcall; a throw
  propagates out of the VimEnter autocmd and can abort sibling handlers. Every failure →
  `return nil` (GOTCHA E).
- ❌ Don't `vim.notify` on failure in S21 — the one-time notify is task S39's job; adding it
  now double-notifies later (GOTCHA F).
- ❌ Don't over-reach: don't connect the bridge (S24), don't set buffer options/keymaps (S22),
  don't start completion (S30+), don't `require` any not-yet-existing module. Setting the
  filetype is the ONLY buffer mutation (GOTCHA G).
- ❌ Don't add a temp-file-name regex as a secondary gate — the env var is sufficient and
  precise for BOTH pi editor code paths (GOTCHA H; tasks.json confirms).
- ❌ Don't set `runtimepath` in a `+` arg for the end-to-end VimEnter test — the shim auto-
  sources at step 12, before step-17 `+` args; use `--cmd` (step 3) so the shim sources and
  its VimEnter autocmd exists (GOTCHA C — LIVE-VERIFIED).
- ❌ Don't mutate `setup`/`defaults`/`config`/`bridge` — S21 is additive; the S19/S20 suites
  must still pass verbatim (Non-regression).
- ❌ Don't make validation depend on stylua/selene — they aren't installed here. The headless
  smoke + plenary spec + the Level-3 end-to-end are the hard gates (S19 GOTCHA #8).
- ❌ Don't rely on a trailing `+qa` to "let VimEnter fire" — it quits at step 17, before
  step-19 VimEnter. Fire `VimEnter` manually (`nvim_exec_autocmds`) in tests (S20 GOTCHA #4).
