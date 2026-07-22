---
name: "P2.M9.T23.S38 (PRP path P2M6T1S1) — VimLeavePre/ExitPre: autosave if modified, send bye, close connection (+ BufWriteCmd)"
description: |
  **IMPLEMENT the autosave-on-exit + bye-teardown BODY** for `pi-bridge.nvim` (logical id
  **S38** / P2.M9.T23.S38; PRP output dir `P2M6T1S1`). The (DONE, S22) ftplugin already WIRES
  `VimLeavePre`+`ExitPre` → `dispatch("pi-editor.bridge","on_exit",buf)` (gated on
  `config.autosave_on_exit ~= false`, default TRUE). S24's `plugin/lua/pi-editor/bridge.lua`
  (LANDED in parallel) already ships a **STUB `M.on_exit(buf)`** whose body is just `M.close()`
  (transport teardown only — its comment: "autosave is S38's job"). S38 OWNS: (1) **EXTEND that
  stub** to (a) write the pi temp file when the buffer is modified — the CRITICAL PRD §11 edge
  case ("pi reads the file only after the editor exits with status 0; without autosave a user
  who types and quits with `:q` SILENTLY LOSES their prompt"), and (b) send a `bye` JSON-RPC
  notification BEFORE the close (PRD §5.4 graceful disconnect); (2) ADD a `save_buffer` helper
  + a `BufWriteCmd` handler (`M.on_write`) so explicit `:w` persists the temp file (PRD §7.6
  lists BufWriteCmd in the autosave group — S22 wired only the exit events, NOT BufWriteCmd, so
  S38 ADDS that autocmd to the ftplugin, additive + non-breaking).
  S24's REAL seam names (USE THESE — do NOT invent notify/disconnect): `M.send(obj)` writes a
  JSON-RPC envelope (`vim.json.encode(obj).."\n"`→`pipe:write`; already gated on
  `state.connected`/`state.closed`; returns bool); `M.close()` idempotent teardown (shadow
  `state.closed` flag set FIRST); `M.is_connected()` = `state.connected and not state.closed`.
  To send bye fire-and-forget: `M.send({jsonrpc="2.0",method="bye",params={}})` (NO `id` ⇒ a
  JSON-RPC notification; the client is exiting and must not await a response — the server
  cleans up on EOF, see Context §"bye-as-notification").
  DELIVERABLES: (1) MODIFY `bridge.lua`: extend `M.on_exit`, add `save_buffer` + `M.on_write`;
  (2) MODIFY `ftplugin/pi-prompt.lua`: add the BufWriteCmd autocmd; (3) NEW `tests/on_exit_spec.lua`
  (plenary/busted mocking matrix); (4) NEW `tests/on_exit_smoke.lua` (Level-1 headless smoke).
  NARROW scope guard — S38 does NOT: open a socket (S24 DONE), handshake (S25), correlate RPC by
  `id` (S26), handle `commandsChanged` (S27), or implement completion (S30+). S38 only SAVES the
  buffer + sends bye + ensures the close S24 already wrote happens AFTER both.
  STATUS (planning): every Neovim behavior is LIVE-VERIFIED green on nvim 0.12.4 — see
  `research/notes.md` §4. S24's bridge.lua (connect/send/close/on_exit-stub/is_connected) was
  READ VERBATIM — the seam names below are its real API, not assumptions.
---

## Goal

**Feature Goal**: Ship the autosave-on-exit + graceful-bridge-teardown behavior that turns a
pi-launched Neovim session into a lossless prompt editor. When the user quits (`:q`/`:wq`/`:qa`
or any exit path), the plugin (1) writes the edited buffer back to pi's temp file iff it is
modified (so pi — which reads the file only after the editor exits with status 0, PRD §2.1/§11
— never silently loses the typed prompt), and (2) sends a `bye` notification before closing the
socket so the bridge server releases the connection cleanly (PRD §5.4). A `BufWriteCmd` handler
makes an explicit `:w` persist the same temp file. None of this ever throws (exit must never
abort) and the teardown degrades gracefully when the bridge is not connected (PRD §11).

**Deliverable** (4 files — 2 MODIFY + 2 NEW):
- **MODIFY** `plugin/lua/pi-editor/bridge.lua` (S24 LANDED — extend, do NOT rewrite):
  - **EXTEND** the existing `M.on_exit(buf)` stub (currently `M.close()` only) to FIRST do the
    save + bye, THEN call `M.close()` (S24's existing teardown). Whole body `pcall`'d.
  - **ADD** `local function save_buffer(buf)` — `vim.fn.writefile(nvim_buf_get_lines(buf,0,-1,false),
    nvim_buf_get_name(buf))` then `vim.bo[buf].modified=false`; pcall'd; returns `bool`. The
    SINGLE write primitive shared by on_exit + on_write (writefile, NOT `:write`, so on_exit
    doesn't route THROUGH the BufWriteCmd it also enables — no coupling/recursion).
  - **ADD** `M.on_write(buf)` — the **BufWriteCmd** handler: `return save_buffer(buf)` (truthy ⇒
    the ftplugin's `dispatch` marks `:w` handled).
  - [Mode A] LuaCATS docstrings + a prominent `WARNING:` block on the lost-prompt risk (§11).
- **MODIFY** `plugin/ftplugin/pi-prompt.lua` — ADD a buffer-local `BufWriteCmd` autocmd inside
  the existing `if config.autosave_on_exit ~= false then` block (alongside the VimLeavePre/
  ExitPre loop) that dispatches to `bridge.on_write(buf)` and falls back to
  `pcall(vim.cmd,"noautocmd write")` when the module/handler is unavailable. Additive,
  non-breaking (the existing `ftplugin_spec.lua` does not assert BufWriteCmd absence).
- **NEW** `plugin/tests/on_exit_spec.lua` — plenary/busted spec (Level-2 gate): the full mocking
  matrix (modified×connected×config). Mocks the seams by overriding `M.send`/`M.close`/`M.is_connected`.
- **NEW** `plugin/tests/on_exit_smoke.lua` — plenary-FREE headless smoke (Level-1 gate;
  `:luafile`-sourced, prints `SMOKE_PASS` / exit 0).

> Reuses `plugin/tests/minimal_init.lua` (S19) unchanged. NO change to `init.lua`, the S20 shim,
> S21's gate, S22's keymaps/completion-autocmds (only the autosave BLOCK gains one autocmd),
> S24's `connect`/`send`/`close`/`is_connected` (reused as-is), or any completion/coords/menu module.

**Success Definition** (every assertion is LIVE-VERIFIED — see `research/notes.md` §4 + Validation):
- **Modified + connected → full teardown**: a real scratch buffer named to a temp path, edited
  (modified=true), `is_connected()==true`: `on_exit` writes the file (content on disk == buffer),
  clears `modified`, calls `M.send({jsonrpc="2.0",method="bye",params={}})` EXACTLY ONCE, calls
  `M.close()` EXACTLY ONCE, and returns normally (no throw).
- **Unmodified + connected**: file NOT rewritten (sentinel unchanged); bye + close STILL fire
  (teardown is independent of the save — releasing the server connection is always correct).
- **Modified + DISCONNECTED**: file written (autosave is local, needs no bridge); `M.send` NOT
  called; `M.close()` STILL called once (close is idempotent + harmless when never connected —
  S24 guarantees it; and on_exit must ALWAYS tear down).
- **`autosave_on_exit=false` + modified + connected**: file NOT written (save gated off); bye +
  close STILL fire (teardown ungated). [Documented intent — see Context §"Gating intent".]
- **No-throw guarantee**: make `M.send` throw → `on_exit` still returns normally (pcall) and STILL
  calls `M.close()` (close is OUTSIDE the pcall'd save/bye block — or in its own pcall; see impl).
- **`on_write` writes + clears modified**: a real scratch buffer named to a temp path, edited,
  then `on_write(buf)` (or the BufWriteCmd path via `:w`) → file content == buffer, `modified=false`,
  returns `true`.
- **BufWriteCmd wiring**: a `pi-prompt` buffer (filetype set) has a `BufWriteCmd` autocmd in the
  `"pi-editor"` group by default; `:w` persists the file. Absent when `autosave_on_exit=false`
  (default `:w` still works in that case).
- **Non-regression**: `init_spec` (S19), `shim_spec` (S20), `activate_spec` (S21),
  `ftplugin_spec` (S22), `jsonlreader_spec` (S23), `bridge_spec` (S24) all still pass unchanged.
- Smoke prints `SMOKE_PASS` / exit 0; `on_exit_spec.lua` exits 0.
- [Mode A] header + per-method LuaCATS docstrings + the `WARNING:` lost-prompt block present.

## User Persona (if applicable)

**Target User**: A pi user who opens the external editor (`Ctrl+G`) to draft a long/rich prompt
and quits with `:q` (or `:wq`, or closes the terminal). They never see this code; they
experience it as "my prompt is always there when I return to pi" and "pi doesn't hang on a
dead socket after the editor closes."

**Use Case**: The prompt-editor lifecycle's FINAL step. S21 (gate) → S22 (buffer setup) → S24-S27
(live completion over the socket) → … → **S38 (persist + tear down)**. Without S38 the plugin is a
completion toy that DROPS the user's text on quit (the §11 "lost prompt" failure mode).

**Pain Points Addressed**:
1. **Silent data loss** (PRD §11, the headline edge case): `:q` with an unsaved buffer → pi reads
   the OLD temp file → the prompt is gone, with no error. S38's `save_buffer`-on-exit closes this.
2. **Rough exit paths** (`<C-c>`/kill): VimLeavePre is the LAST reliable hook before nvim
   terminates; autosaving there (pcall'd) survives better than relying on the user to `:w`.
3. **Server resource leak**: without bye+close, the bridge socket lingers until the OS reaps it.
4. **`:w` reliability**: the BufWriteCmd handler guarantees `:w` lands on the temp file pi reads.

## Why

- **PRD §11 is a MUST, not a should.** "The plugin MUST autosave the buffer on VimLeavePre/ExitPre
  when modified … Without this a user who types and quits with `:q` silently loses their prompt."
  This is the single highest-stakes correctness requirement in the spec — a bug here is
  indistinguishable from data loss. S38 makes it true.
- **Completes the lifecycle S24 stubbed.** S24 shipped `on_exit(buf)` as a transport-only stub
  (`M.close()`), explicitly deferring "autosave is S38's job". S38 fills that deferral — and the
  one autocmd (BufWriteCmd) S22 deferred — with ZERO churn to S24's connect/send/close.
- **Symmetric with the extension's `bye`.** The (DONE, S14) server `bye` handler exists *so that*
  an exiting client can disconnect gracefully. S38 is the client half (PRD §5.4).
- **Defensive by construction.** The save is synchronous `writefile` (reliable, no async race);
  bye is best-effort before close (if the in-flight write is aborted by close, the server still
  cleans up on EOF — see Context §"bye-as-notification"); exit never aborts (pcall).

## What

User-visible behavior:
- Type a prompt, press `:q`<CR> → the prompt is persisted to pi's temp file; pi reads it.
- Type a prompt, press `:w`<CR> → the temp file is updated immediately (the BufWriteCmd path);
  the buffer's modified flag clears.
- Quit in any way → the bridge socket is closed (server releases the connection); no hang.
- If the bridge was never connected (dormant session) → exit just saves (when modified) and
  finishes; bye is skipped, close is a harmless no-op (S24's `close()` guards `state.closed`).

Technical requirements (exact, LIVE-VERIFIED; seam names READ from S24's bridge.lua):
- `bridge.lua` `M.on_exit(buf)` is EXTENDED: `pcall`'d save (if modified + autosave-on) →
  `pcall`'d `M.send({jsonrpc="2.0",method="bye",params={}})` (if `M.is_connected()`) → `M.close()`.
- `save_buffer(buf)`: `vim.fn.writefile` + `vim.bo[buf].modified=false` (NOT `:write` — avoids
  BufWriteCmd coupling; the CONTRACT's `vim.cmd("write")`/`nvim_buf_call(buf,function()
  vim.cmd("silent! write") end)` are verified-equivalent alternatives, documented in-code).
- `M.on_write(buf)` returns `save_buffer(buf)` (truthy ⇒ dispatch handled).
- The ftplugin gains one buffer-local `BufWriteCmd` autocmd (additive, in the autosave block).
- `on_exit` reads config via `require("pi-editor").config or require("pi-editor").defaults`.
- Everything pcall'd; [Mode A] docstrings + the `WARNING:` lost-prompt block.

### Success Criteria
- [ ] `on_exit` saves a modified buffer to disk (file content == buffer) and clears `modified`.
- [ ] `on_exit` does NOT save an unmodified buffer (file untouched).
- [ ] `on_exit` does NOT save when `autosave_on_exit=false` (config gate).
- [ ] `on_exit` calls `M.send({jsonrpc="2.0",method="bye",params={}})` then `M.close()` when connected.
- [ ] `on_exit` skips `M.send` when `M.is_connected()==false` but STILL calls `M.close()` once.
- [ ] bye+close fire on exit even when `autosave_on_exit=false` (teardown ungated).
- [ ] `on_exit` NEVER throws (a throwing `M.send` is swallowed; `M.close()` still runs).
- [ ] `on_write(buf)` writes the temp file + clears `modified`; returns truthy (`true`).
- [ ] ftplugin: a `pi-prompt` buffer has a `BufWriteCmd` autocmd in `"pi-editor"` by default.
- [ ] ftplugin: `:w` on a `pi-prompt` buffer persists the file (BufWriteCmd path) when autosave on.
- [ ] ftplugin: `BufWriteCmd` absent when `autosave_on_exit=false` (default `:w` still works).
- [ ] S24's `connect`/`send`/`close`/`is_connected` are REUSED, not duplicated or renamed.
- [ ] Non-regression: all prior specs (incl. S24 `bridge_spec`) pass unchanged.
- [ ] [Mode A] docstrings + the `WARNING:` lost-prompt block present.

## All Needed Context

### Context Completeness Check
_Passes "No Prior Knowledge":_ an implementer needs only this PRP + `research/notes.md` + the
verified commands. S24's `bridge.lua` was READ VERBATIM — the seam names (`send`/`close`/
`is_connected`/`state.connected`/`state.closed`) and the existing `on_exit` STUB are quoted
below, not assumed. Every Neovim behavior (BufWriteCmd non-recursion, writefile-in-BufWriteCmd,
VimLeavePre headless firing + `silent! write`, `nvim_exec_autocmds` simulation) is LIVE-VERIFIED.
The three subtleties that make or break this task — (1) `save_buffer` uses `writefile` so on_exit
doesn't route THROUGH the BufWriteCmd it also enables; (2) `bye` is a NOTIFICATION (no id) because
the client is exiting; (3) the bye-vs-close race (best-effort bye; autosave is the synchronous
load-bearing part) — are all explained with citations.

### Documentation & References
```yaml
# MUST READ — PRD (read-only; the source of truth for behavior)
- url: "PRD.md §11 (heading:h2.11) — Edge Cases: 'Forgotten save → lost prompt'"
  why: "THE requirement. 'pi reads the file only after the editor exits with status 0. The
        plugin MUST autosave the buffer on VimLeavePre/ExitPre when modified (and on a
        BufWriteCmd that maps :w). Without this a user who types and quits with :q silently
        loses their prompt.' autosave_on_exit defaults true."
  critical: "Copy this WARNING verbatim into the on_exit docstring (CONTRACT DOCS requirement)."
- url: "PRD.md §7.6 (heading:h3.22) — Buffer-local setup (ftplugin/pi-prompt.lua)"
  why: "Lists the autocmd group: 'ExitPre, VimLeavePre, BufWriteCmd → autosave if modified (§11)
        and close the bridge connection. BufWritePre → no-op normal write (the temp file is
        writable).' S22 wired VimLeavePre/ExitPre; S38 adds BufWriteCmd."
  critical: "BufWriteCmd is grouped WITH the exit events — gate it on the same autosave flag."
- url: "PRD.md §5.4 (heading:h3.8) — Methods table"
  why: "bye | C→S | {} | {ok:true} *(graceful disconnect)*. Confirms bye is the teardown signal."
- url: "PRD.md §10.5 (heading:h3.30) — Default setup() options"
  why: "autosave_on_exit = true (default). Engine/menu/debounce are unrelated to S38."
- url: "PRD.md §2.1 (heading:h3.2) — Editor launch"
  why: "pi writes a temp file, spawns $EDITOR on it, reads it back ONLY on exit-status 0
        (trimming one trailing newline). This is WHY autosave-on-exit is load-bearing."

# MUST READ — codebase (the files S38 touches + the seams it consumes, READ VERBATIM)
- file: "plugin/lua/pi-editor/bridge.lua   (S24 LANDED — the file S38 EXTENDS)"
  why: "Contains the EXACT seams S38 reuses. READ THESE SIGNATURES (do not invent notify/disconnect):"
  pattern: |
    function M.send(obj)           -- write a JSON-RPC envelope; vim.json.encode(obj).."\n" -> pipe:write.
      if not state.connected or state.closed then return false end   -- ALREADY gated (GOTCHA 6)
      ... pipe:write(data, function(werr) if werr then ...M.close()... end end) ...  -- async; cb routes EPIPE
      return ok  -- bool: true if queued, false if dropped
    end
    function M.close()             -- idempotent teardown: sets state.closed=true FIRST (GOTCHA 2),
      if state.closed then return end   ... pipe:close() (pcall'd) ... clears state.* ...
    end
    function M.on_exit(buf)        -- S24 STUB (line ~226): body is JUST `M.close()`. Comment:
      M.close()                    --   "autosave is S38's job, dispatched separately". S38 EXTENDS it.
    end
    function M.is_connected() return state.connected and not state.closed end  -- read-only accessor
  critical: "send() is ASYNC (pipe:write + cb). Calling M.close() immediately after M.send(bye)
    can ABORT the in-flight write (libuv uv_close cancels pending writes). This is ACCEPTABLE:
    bye is best-effort; the server cleans up on EOF when the pipe closes (see bye-as-notification).
    The AUTOSAVE (writefile) is SYNCHRONOUS and unaffected — it is the load-bearing part."
- file: "plugin/ftplugin/pi-prompt.lua   (S22 DONE — S38 EDITS)"
  why: "The buffer-setup script. Contains the `dispatch()` helper (truthy return = handled), the
        `map_dispatch`/`feedkey` helpers, the `pi-editor` augroup (clear=false, shared with S20),
        and the EXACT autosave block (`if config.autosave_on_exit ~= false then ... VimLeavePre/
        ExitPre loop ...`) S38 edits to add the BufWriteCmd autocmd."
  pattern: "buffer-local autocmd: `vim.api.nvim_create_autocmd(ev,{group=group,buffer=buf,desc=...,
            callback=function() dispatch(MOD,FN,buf) end})`. The completion autocmds are the template."
  gotcha: "augroup SHARED with S20's VimEnter — create with clear=false (already done). The autosave
           block is gated `if config.autosave_on_exit ~= false`; S38's BufWriteCmd goes INSIDE it."
- file: "plugin/lua/pi-editor/init.lua   (S19 DONE)"
  why: "M.defaults (autosave_on_exit=true), M.config (set by setup(); self-set by activate()).
        on_exit reads `require('pi-editor').config`. Nil-safe: `(pi.config or pi.defaults) or {}`."
- file: "plugin/tests/bridge_spec.lua   (S24 spec — non-regression + the mock PATTERN to mirror)"
  why: "S24's plenary/busted spec. Shows how bridge.lua is loaded + how send/close are exercised.
        Mirror its before_each/module-reset structure for on_exit_spec.lua. S38 must not break it."
- file: "plugin/tests/ftplugin_spec.lua   (S22 spec — non-regression + autocmd-assert PATTERN)"
  why: "Mirror its `fresh_prompt_buf()` + `nvim_get_autocmds({buffer=b,group='pi-editor'})` asserts
        for the BufWriteCmd wiring cases. It does NOT assert BufWriteCmd absence, so adding the
        autocmd is non-breaking (but ADD a case asserting BufWriteCmd present-by-default)."
- file: "plugin/tests/minimal_init.lua   (S19 — plenary harness; reused UNCHANGED)"
- file: "extension/connection.ts (handleLine, lines ~269-380)   (DONE — server-side bye dispatch)"
  why: "Proves a bye NOTIFICATION (no id) calls the handler but does NOT trigger closeAfterResponse
        (request-only); the CLIENT closing its pipe sends EOF → the connection's 'close' handler
        detaches the reader + removes the socket. So send(bye-notification) + close() is clean."

# Research (this PRP's own notes — LIVE-VERIFIED)
- docfile: "plan/001_c56962b4fa17/P2M6T1S1/research/notes.md"
  why: "Codebase analysis + bye protocol trace + 4 LIVE-VERIFIED Neovim behaviors + S24 seam
        names (read verbatim) + locked design + test matrix."
  section: "§2 (seams, READ from bridge.lua), §4 (verified), §5 (design), §6 (test matrix)."
```

### Current Codebase tree (run `tree -L 3 plugin`)
```bash
plugin
├── ftplugin
│   └── pi-prompt.lua          # S22 (DONE) — S38 EDITS (add BufWriteCmd autocmd)
├── lua
│   └── pi-editor
│       ├── init.lua           # S19 (DONE) — config + activate(); S38 READS .config
│       └── bridge.lua         # S24 (LANDED) — connect/send/close/on_exit-STUB/is_connected; S38 EXTENDS
├── plugin
│   └── pi-editor.lua          # S20 (DONE) — VimEnter shim; untouched
└── tests
    ├── minimal_init.lua       # S19 (DONE) — plenary harness; reused unchanged
    ├── init_spec.lua          # S19 spec (non-regression)
    ├── shim_spec.lua          # S20 spec (non-regression)
    ├── activate_spec.lua      # S21 spec (non-regression)
    ├── ftplugin_spec.lua      # S22 spec (non-regression) + PATTERN to mirror
    ├── jsonlreader_spec.lua   # S23 spec (non-regression)
    ├── bridge_spec.lua        # S24 spec (non-regression) + mock PATTERN to mirror
    └── smoke.lua              # S19 generic smoke (Level-1 helper pattern)
```

### Desired Codebase tree with files to be added/modified
```bash
plugin
├── ftplugin
│   └── pi-prompt.lua          # MODIFY: +1 buffer-local BufWriteCmd autocmd (autosave block)
├── lua
│   └── pi-editor
│       ├── init.lua           # untouched
│       └── bridge.lua         # MODIFY: EXTEND M.on_exit (+save+bye before close); ADD save_buffer, M.on_write
└── tests
    ├── on_exit_smoke.lua      # NEW — Level-1 headless smoke (prints SMOKE_PASS)
    └── on_exit_spec.lua       # NEW — Level-2 plenary/busted spec (mocking matrix)
```

### Known Gotchas of our codebase & Library Quirks
```lua
-- CRITICAL (PRD §11): without autosave-on-exit, `:q` SILENTLY LOSES the user's prompt. This is
--   the #1 correctness requirement. on_exit MUST save-before-exit when modified. Document the
--   WARNING verbatim in the docstring.

-- GOTCHA 1 (BufWriteCmd recursion — LIVE-VERIFIED): a BufWriteCmd callback that calls
--   vim.cmd("write") does NOT recurse (nvim's event-recursion guard: fired exactly once,
--   file written, modified cleared). `:noautocmd write` is the explicit form. BUT save_buffer
--   uses vim.fn.writefile instead so on_exit stays DECOUPLED from on_write — no double-write.

-- GOTCHA 2 (writefile + modified — LIVE-VERIFIED): inside a BufWriteCmd, `vim.fn.writefile(
--   getbufline(buf,1,"$"), path)` then `vim.bo[buf].modified=false` writes the file and clears
--   the flag. nvim does NOT auto-clear modified for a custom handler — you MUST set it.

-- GOTCHA 3 (VimLeavePre headless — LIVE-VERIFIED): `nvim_exec_autocmds("VimLeavePre",{})`
--   fires registered VimLeavePre autocmds headlessly; `vim.cmd("silent! write")` works inside.
--   So tests SIMULATE exit by registering the autocmd (or relying on the ftplugin) + exec'ing it.

-- GOTCHA 4 (augroup shared): the "pi-editor" augroup is SHARED with S20's VimEnter autocmd.
--   Always create with `clear=false` (already done in the ftplugin). S38's BufWriteCmd autocmd
--   is buffer-local + in this group — it does NOT touch the VimEnter autocmd.

-- GOTCHA 5 (dispatch truthy contract): the ftplugin's `dispatch(mod,fn,buf)` returns true ONLY
--   if fn returned truthy. So M.on_write(buf) MUST return `true` (save_buffer's bool) for the
--   ftplugin to mark `:w` "handled" (and skip the noautocmd-write fallback).

-- GOTCHA 6 (config nil-safety): on_exit reads `require("pi-editor").config`. If config is nil
--   (edge), fall back to `.defaults` then `{}`.

-- GOTCHA 7 (bye is a NOTIFICATION, not a request-and-await — S24 send is ASYNC): during
--   VimLeavePre the client is EXITING. Send `M.send({jsonrpc="2.0",method="bye",params={}})`
--   (NO id field ⇒ notification) fire-and-forget, then close. send() is async (pipe:write+cb);
--   calling M.close() right after MAY abort the in-flight bye write (libuv cancels pending
--   writes on close). ACCEPTABLE: bye is best-effort; the server cleans up on EOF when the pipe
--   closes (connection.ts 'close' handler). The AUTOSAVE (writefile) is synchronous + reliable.
--   Do NOT register a bye response callback (would never fire / would block exit).

-- GOTCHA 8 (close ordering — bye BEFORE close): send(bye) must come BEFORE M.close() (close
--   tears down the pipe). close() is idempotent (S24 guards state.closed) — calling it when
--   never connected is a harmless no-op, so on_exit ALWAYS closes.

-- GOTCHA 9 (autosave_on_exit gating — intent): the SAVE is gated on autosave_on_exit; bye+close
--   are NOT (releasing the server connection is always correct on exit). See Context §"Gating".

-- GOTCHA 10 (reuse S24 seams — do NOT rename): bridge.lua already has send/close/is_connected.
--   S38 CALLS them; it does NOT add notify/disconnect duplicates. Extend the existing on_exit
--   stub; do NOT delete S24's transport teardown.
```

## Implementation Blueprint

### Data models and structure
No new data models. S38 adds module-local `save_buffer(buf)` and `M.on_write(buf)`, and EXTENDS
the existing `M.on_exit(buf)`. State it reads: the buffer's `modified` flag + name, and S24's
`state`/seams. No new tables.

### Implementation Tasks (ordered by dependencies)

```yaml
Task 1: EXTEND M.on_exit + ADD save_buffer + M.on_write in plugin/lua/pi-editor/bridge.lua
  - The file EXISTS (S24). APPEND save_buffer + M.on_write; REPLACE the on_exit STUB body
    (currently `M.close()`) with the extended version. Do NOT touch connect/send/close/is_connected.
  - IMPLEMENT module-local `save_buffer(buf)` (place it ABOVE on_exit, after S24's close()):
      local function save_buffer(buf)
        local path = vim.api.nvim_buf_get_name(buf)
        if not path or path == "" then return false end           -- no file to write to
        local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
        local ok = pcall(vim.fn.writefile, lines, path)
        if ok then vim.bo[buf].modified = false end
        return ok
      end
    (writefile — deterministic, decouples from BufWriteCmd; see GOTCHA 1.)
  - IMPLEMENT `M.on_write(buf)` (BufWriteCmd handler): `return save_buffer(buf)`.
  - REPLACE `M.on_exit(buf)` body (S24's stub) with:
      function M.on_exit(buf)
        pcall(function()
          local pi = require("pi-editor")
          local cfg = (pi and (pi.config or pi.defaults)) or {}
          if cfg.autosave_on_exit ~= false and vim.bo[buf].modified then
            save_buffer(buf)
          end
          if M.is_connected() then
            pcall(M.send, { jsonrpc = "2.0", method = "bye", params = {} })  -- GOTCHA 7/8
          end
        end)
        M.close()   -- S24's teardown; ALWAYS run (idempotent; harmless if never connected)
      end
    (bye inside the pcall so a throwing send can't skip... actually close must STILL run even if
     send throws — so close is OUTSIDE the pcall, OR wrap bye in its own pcall. The structure
     above puts save+bye in ONE pcall, close AFTER — so close runs even if save/bye throw. ✓)
  - DOCSTRINGS: [Mode A] LuaCATS on save_buffer/on_write/on_exit. Put a multi-line `-- WARNING:`
    block atop on_exit quoting PRD §11 ("a user who types and quits with :q silently loses their
    prompt"). Note the bye-as-notification + best-effort-close-race choice (GOTCHA 7) in the docstring.
  - FOLLOW pattern: S24's bridge.lua `local M = {}` + `---@param`/`---@return` LuaCATS style.
  - NAMING: keep `on_exit`/`on_write` (the names S22's ftplugin + S24 already use); `save_buffer`.

Task 2: ADD the BufWriteCmd autocmd to plugin/ftplugin/pi-prompt.lua
  - EDIT the existing `if config.autosave_on_exit ~= false then` block (where VimLeavePre/ExitPre
    are registered). AFTER the exit-events `for` loop, ADD:
      vim.api.nvim_create_autocmd("BufWriteCmd", {
        group = group,
        buffer = buf,
        desc = "pi-editor: explicit write to the pi temp file (:w)",
        callback = function()
          if not dispatch("pi-editor.bridge", "on_write", buf) then
            pcall(vim.cmd, "noautocmd write")   -- fallback: default write, no BufWriteCmd recursion
          end
        end,
      })
  - WHY inside the autosave block: PRD §7.6 groups BufWriteCmd with the exit events. When
    autosave_on_exit=false, the default `:w` still works (no BufWriteCmd registered). Comment the
    `noautocmd write` fallback (preserves :w if bridge.lua/on_write ever unavailable).
  - PRESERVE: every existing ftplugin element (options, keymaps, completion autocmds, exit
    autocmds, augroup clear=false, the idempotent nvim_clear_autocmds line).
  - NAMING: desc prefixed "pi-editor:" (the ftplugin convention).
  - NO new helpers; reuse the existing `dispatch` + `group` + `buf` locals.

Task 3: CREATE plugin/tests/on_exit_spec.lua (Level-2 plenary/busted)
  - IMPLEMENT the mocking matrix (override M.send/M.close/M.is_connected before calling on_exit):
      * modified + connected        → save(write) + send(bye) once + close() once, no throw
      * unmodified + connected      → NO write; send(bye)+close STILL fire
      * modified + disconnected     → save(write); send NOT called; close STILL called once
      * autosave_on_exit=false+mod+conn → NO write; send(bye)+close STILL fire
      * no-throw: M.send raises     → on_exit returns normally; close STILL runs (outside pcall)
  - VERIFY the SAVE against a REAL temp file (os.tmpname()): scratch buffer, nvim_buf_set_name to
    the temp path, set lines, set modified=true, call on_exit, readfile the path, assert content
    == buffer lines and modified==false. (Only a real disk read proves "the prompt was saved.")
  - VERIFY bye via a spy: `local bye=0; M.send=function(obj) if obj and obj.method=="bye" then
    bye=bye+1 end return true end`; assert bye==1 (connected) / 0 (disconnected).
  - VERIFY close via a spy: `local dc=0; M.close=function() dc=dc+1 end`; assert dc==1 always.
  - CONTROL is_connected: `M.is_connected=function() return CONN end` (toggle CONN per case).
    NOTE: overriding M.close means S24's real close won't run in the unit test — that's intended
    (we're testing on_exit's ORCHESTRATION, not S24's close, which S24's own spec covers).
  - COVER on_write directly: scratch buffer named to a temp path, edited → on_write(buf) writes
    the file (readfile assert), clears modified, returns true.
  - FOLLOW pattern: plugin/tests/bridge_spec.lua (S24) + ftplugin_spec.lua (before_each resets
    package.loaded; describe/it/busted asserts). Reuse minimal_init.lua (S19) unchanged.
  - NAMING: describe("pi-editor bridge on_exit/on_write"); it("…") per case.
  - PLACEMENT: plugin/tests/on_exit_spec.lua.

Task 4: CREATE plugin/tests/on_exit_smoke.lua (Level-1 headless smoke)
  - plenary-FREE `:luafile` smoke (pattern: plugin/tests/smoke.lua / bridge_smoke.lua): require
    the bridge module, make a scratch buffer named to os.tmpname(), set modified, mock the seams,
    call on_exit, assert the file was written + modified cleared + send(bye)+close called, print
    "SMOKE_PASS". `nvim --headless --clean -u NORC +"luafile .../on_exit_smoke.lua" +qa`.
  - This proves the module loads + the extended on_exit works with ZERO plenary (S19 GOTCHA #10).
```

### Implementation Patterns & Key Details
```lua
-- ===== plugin/lua/pi-editor/bridge.lua (S38 — EXTEND the S24 module) =====
-- Place save_buffer ABOVE on_exit (after S24's close()). on_write near on_exit.

-- The single write primitive. writefile (not :write) so on_exit doesn't route THROUGH a
-- BufWriteCmd it also (via the ftplugin) enables — keeps on_exit/on_write decoupled + unit-testable.
--- Persist the buffer to its file (the pi temp file) and clear the modified flag.
--- No-op + returns false if the buffer has no name. Never throws (writefile is pcall'd).
---@param buf integer Buffer handle (the pi-prompt buffer).
---@return boolean ok true iff the file was written and modified cleared.
local function save_buffer(buf)
  local path = vim.api.nvim_buf_get_name(buf)
  if not path or path == "" then return false end
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local ok = pcall(vim.fn.writefile, lines, path)
  if ok then vim.bo[buf].modified = false end
  return ok
end

-- BufWriteCmd handler (registered by ftplugin/pi-prompt.lua). Explicit :w → persist temp file.
---@param buf integer Buffer handle.
---@return boolean ok truthy ⇒ the ftplugin's `dispatch` marks `:w` handled (skips fallback).
function M.on_write(buf)
  return save_buffer(buf)
end

-- VimLeavePre / ExitPre handler (wired by S22's ftplugin; body EXTENDED by S38 over S24's
-- close-only stub). Does THREE things, in order, NEVER throwing:
--   1. SAVE the buffer to its file when modified (gated on autosave_on_exit; default true).
--   2. SEND a `bye` notification (fire-and-forget; no id) when connected.
--   3. CLOSE the transport (S24's M.close — idempotent; always runs).
--
-- WARNING — LOST PROMPT (PRD §11, verbatim intent): "pi reads the file only after the editor
--   exits with status 0. The plugin MUST autosave the buffer on VimLeavePre/ExitPre when
--   modified. Without this a user who types and quits with :q SILENTLY LOSES their prompt."
--   Step 1 is what prevents that. autosave_on_exit defaults to TRUE.
--
-- The save (writefile) is SYNCHRONOUS and reliable. The bye send is ASYNC (S24 send → pipe:write
-- + cb) and BEST-EFFORT: calling M.close() right after may abort the in-flight write (libuv
-- cancels pending writes on close). That is ACCEPTABLE — the server cleans up on EOF when the
-- pipe closes (extension/connection.ts 'close' handler detaches the reader). bye is courtesy, not
-- a correctness requirement; the autosave is the load-bearing part. Never await a bye response
-- (the client is exiting). See research/notes.md §3 (bye protocol) + §4 (verified).
---@param buf integer The pi-prompt buffer (passed by the ftplugin's dispatch).
function M.on_exit(buf)
  pcall(function()
    local pi = require("pi-editor")
    local cfg = (pi and (pi.config or pi.defaults)) or {}
    if cfg.autosave_on_exit ~= false and vim.bo[buf].modified then
      save_buffer(buf)
    end
    if M.is_connected() then
      pcall(M.send, { jsonrpc = "2.0", method = "bye", params = {} })
    end
  end)
  M.close()   -- ALWAYS: idempotent teardown (S24). Outside the pcall so a throwing save/bye
              -- cannot skip it. Harmless no-op if never connected (S24 guards state.closed).
end
```

```lua
-- ===== plugin/ftplugin/pi-prompt.lua (S38 edit — INSIDE the autosave block) =====
if config.autosave_on_exit ~= false then
  for _, ev in ipairs({ "VimLeavePre", "ExitPre" }) do
    vim.api.nvim_create_autocmd(ev, {
      group = group, buffer = buf,
      desc = "pi-editor: autosave + bridge teardown on " .. ev,
      callback = function() dispatch("pi-editor.bridge", "on_exit", buf) end,
    })
  end

  -- [S38] BufWriteCmd (PRD §7.6): make explicit `:w` persist the pi temp file. Dispatches to
  -- bridge.on_write (writefile + clear modified); if the bridge module or handler is unavailable,
  -- fall back to the default write (`noautocmd` prevents re-triggering this BufWriteCmd —
  -- LIVE-VERIFIED non-recursive). Gated with the exit events (PRD §7.6 groups them); when
  -- autosave is off the default `:w` still works (no BufWriteCmd registered).
  vim.api.nvim_create_autocmd("BufWriteCmd", {
    group = group, buffer = buf,
    desc = "pi-editor: explicit write to the pi temp file (:w)",
    callback = function()
      if not dispatch("pi-editor.bridge", "on_write", buf) then
        pcall(vim.cmd, "noautocmd write")
      end
    end,
  })
end
```

### Integration Points
```yaml
AUTOCMDS (ftplugin, buffer-local, "pi-editor" group):
  - ADD: BufWriteCmd { buffer=buf } → dispatch("pi-editor.bridge","on_write",buf) [+ noautocmd write fallback]
    (inside the existing `if config.autosave_on_exit ~= false` block, after the VimLeavePre/ExitPre loop)
  - PRESERVE: VimLeavePre/ExitPre (S22), InsertEnter/TextChangedI/CursorMovedI (S22), VimEnter (S20)

MODULE (lua/pi-editor/bridge.lua):
  - EXTEND: M.on_exit (S24 stub → save+bye+close)
  - ADD: save_buffer (local), M.on_write
  - REUSE (S24, unchanged): M.connect, M.send, M.close, M.is_connected, state.{connected,closed}

CONFIG (init.lua — READ ONLY by S38):
  - read: require("pi-editor").config.autosave_on_exit  (default true via M.defaults)
  - nil-safe: `(pi.config or pi.defaults) or {}`

NO: database / routes / migrations / new env vars / package.json changes. Pure Lua + autocmds.
```

## Validation Loop

### Level 1: Syntax & Style (Immediate Feedback)
```bash
# From the repo root. Lua has no project linter configured — use luacheck if available, else
# rely on nvim's parser (the smoke + spec loads surface syntax errors).
luacheck plugin/lua/pi-editor/bridge.lua plugin/ftplugin/pi-prompt.lua --no-config 2>/dev/null \
  || echo "(luacheck not installed — relying on nvim parser via smoke/spec below)"

# Headless parse check (loads the module — catches syntax/require errors immediately):
nvim --headless --clean -u NORC \
  -c "set rtp+=$(pwd)/plugin" \
  -c "lua require('pi-editor.bridge')" +qa && echo "BRIDGE_LOADS_OK"
# Expected: BRIDGE_LOADS_OK. Fix any error before proceeding.
```

### Level 2: Unit Tests (Component Validation)
```bash
# Level-1 smoke (plenary-FREE; fastest signal):
cd plugin && nvim --headless --clean -u NORC +"luafile tests/on_exit_smoke.lua" +qa
# Expected: prints SMOKE_PASS, exit 0.

# Level-2 plenary/busted spec (the full mocking matrix):
cd plugin && nvim --headless --clean -u tests/minimal_init.lua \
  -c 'lua require("plenary.busted").run("tests/on_exit_spec.lua")'
# Expected: exit 0, all `it` blocks green (modified/unmodified × connected/disconnected ×
# config gate × no-throw × on_write writes-and-clears).

# BufWriteCmd wiring — RE-RUN ftplugin_spec (add a case asserting BufWriteCmd present by default
# + absent when autosave_on_exit=false):
cd plugin && nvim --headless --clean -u tests/minimal_init.lua \
  -c 'lua require("plenary.busted").run("tests/ftplugin_spec.lua")'
# Expected: exit 0.

# S24 bridge_spec must STILL pass (S38 extended on_exit without breaking send/close):
cd plugin && nvim --headless --clean -u tests/minimal_init.lua \
  -c 'lua require("plenary.busted").run("tests/bridge_spec.lua")'
# Expected: exit 0. (If this breaks, S38 clobbered S24's seams — fix it.)
```

### Level 3: Integration Testing (System Validation)
```bash
# A) Prove the REAL exit path saves the prompt (end-to-end, no plenary):
cat > /tmp/s38_exit_e2e.lua <<'LUA'
  require("pi-editor").setup({})
  local M = require("pi-editor.bridge")
  -- spy on the seams (do NOT call the real socket): override send/close/is_connected.
  local bye, dc = 0, 0
  M.is_connected = function() return true end
  M.send = function(obj) if obj and obj.method == "bye" then bye = bye + 1 end return true end
  M.close = function() dc = dc + 1 end
  -- a real temp-file buffer (as pi would open it)
  local tmp = os.tmpname(); vim.fn.writefile({"old prompt"}, tmp)
  vim.cmd("edit " .. vim.fn.fnameescape(tmp))
  local b = vim.api.nvim_get_current_buf()
  vim.bo[b].filetype = "pi-prompt"               -- sources the ftplugin (registers autocmds)
  vim.api.nvim_buf_set_lines(b, 0, -1, false, {"edited prompt"})
  -- simulate exit (VimLeavePre, wired by S22 to dispatch bridge.on_exit)
  vim.api.nvim_exec_autocmds("VimLeavePre", { buffer = b })
  assert(vim.fn.readfile(tmp)[1] == "edited prompt", "PROMPT NOT SAVED")
  assert(bye == 1, "bye not sent"); assert(dc == 1, "close not called")
  assert(vim.bo[b].modified == false, "modified not cleared")
  vim.fn.delete(tmp); print("EXIT_E2E_PASS")
LUA
cd plugin && nvim --headless --clean -u NORC \
  -c "set rtp+=$(pwd)" -c "luafile /tmp/s38_exit_e2e.lua" +qa
# Expected: EXIT_E2E_PASS.

# B) Prove :w (BufWriteCmd) persists the file:
cat > /tmp/s38_writecmd_e2e.lua <<'LUA'
  require("pi-editor").setup({})
  local tmp = os.tmpname(); vim.fn.writefile({"x"}, tmp)
  vim.cmd("edit " .. vim.fn.fnameescape(tmp))
  local b = vim.api.nvim_get_current_buf()
  vim.bo[b].filetype = "pi-prompt"               -- registers BufWriteCmd (autosave default on)
  vim.api.nvim_buf_set_lines(b, 0, -1, false, {"hello from :w"})
  vim.cmd("write")                               -- triggers BufWriteCmd → bridge.on_write
  assert(vim.fn.readfile(tmp)[1] == "hello from :w", ":w DID NOT PERSIST")
  assert(vim.bo[b].modified == false, "modified not cleared by :w")
  vim.fn.delete(tmp); print("WRITECMD_E2E_PASS")
LUA
cd plugin && nvim --headless --clean -u NORC \
  -c "set rtp+=$(pwd)" -c "luafile /tmp/s38_writecmd_e2e.lua" +qa
# Expected: WRITECMD_E2E_PASS.

# C) Non-regression: every prior spec still green.
cd plugin && for s in init shim activate ftplugin jsonlreader bridge; do
  nvim --headless --clean -u tests/minimal_init.lua \
    -c "lua require('plenary.busted').run('tests/${s}_spec.lua')" || echo "REGRESSION: $s"
done
# Expected: no REGRESSION lines.
```

### Level 4: Creative & Domain-Specific Validation
```bash
# The "lost prompt" adversarial test — the WHOLE POINT of S38 (PRD §11). Simulate a careless
# user: edit, then `:q`-style exit (NO explicit :w). Assert the prompt survived on disk.
cat > /tmp/s38_lostprompt.lua <<'LUA'
  require("pi-editor").setup({})                  -- autosave_on_exit = true (default)
  local M = require("pi-editor.bridge")
  M.is_connected = function() return false end    -- even with NO bridge, autosave must work
  M.send = function() return false end            -- (no-op spy)
  M.close = function() end                        -- (no-op spy)
  local tmp = os.tmpname(); vim.fn.writefile({""}, tmp)
  vim.cmd("edit " .. vim.fn.fnameescape(tmp))
  local b = vim.api.nvim_get_current_buf()
  vim.bo[b].filetype = "pi-prompt"
  vim.api.nvim_buf_set_lines(b, 0, -1, false, {"a very important prompt the user forgot to save"})
  -- user just quits (VimLeavePre is the last hook):
  vim.api.nvim_exec_autocmds("VimLeavePre", { buffer = b })
  local got = table.concat(vim.fn.readfile(tmp), "\n")
  assert(got:find("very important prompt"), "LOST PROMPT — §11 regression!")
  vim.fn.delete(tmp); print("LOSTPROMPT_GUARDED")
LUA
cd plugin && nvim --headless --clean -u NORC \
  -c "set rtp+=$(pwd)" -c "luafile /tmp/s38_lostprompt.lua" +qa
# Expected: LOSTPROMPT_GUARDED. (If this ever fails, S38 is broken — this is the headline test.)

# (Optional) Real socket round-trip: if S25-S27 have landed, spin up the extension's bridge
# server, connect, open a pi-prompt buffer, edit, :qa, and confirm the server logged a `bye`
# notification + saw the socket close. Gated on S25-S27 existing — skip if not (the unit matrix
# covers the logic). The bye write may race with close (GOTCHA 7) — that's expected/acceptable.
```

## Final Validation Checklist

### Technical Validation
- [ ] Level 1: `BRIDGE_LOADS_OK`; luacheck clean (or n/a).
- [ ] Level 2: `on_exit_smoke.lua` prints SMOKE_PASS / exit 0.
- [ ] Level 2: `on_exit_spec.lua` exits 0 (full mocking matrix).
- [ ] Level 2: `ftplugin_spec.lua` exits 0 (incl. the NEW BufWriteCmd presence/absence case).
- [ ] Level 2: `bridge_spec.lua` (S24) STILL exits 0 (no seam clobbering).
- [ ] Level 3: `EXIT_E2E_PASS` + `WRITECMD_E2E_PASS`.
- [ ] Level 3: no `REGRESSION:` lines from the prior-spec loop.
- [ ] Level 4: `LOSTPROMPT_GUARDED` (the §11 adversarial test).

### Feature Validation
- [ ] Modified buffer is saved to disk on exit; `modified` cleared. (file content == buffer)
- [ ] Unmodified buffer is NOT rewritten on exit.
- [ ] `autosave_on_exit=false` disables the save (but NOT bye+close).
- [ ] `M.send({jsonrpc="2.0",method="bye",params={}})` called once when connected; `M.close()` once.
- [ ] `M.send` NOT called when disconnected; `M.close()` STILL called once.
- [ ] `on_exit` never throws (a raising `M.send` is swallowed; `M.close()` still runs).
- [ ] `:w` (BufWriteCmd) persists the temp file + clears modified.
- [ ] BufWriteCmd autocmd present by default; absent when `autosave_on_exit=false`.

### Code Quality Validation
- [ ] Follows existing patterns: `local M={}` module, LuaCATS docstrings, `dispatch` truthy
      contract, buffer-local autocmds in the shared `pi-editor` group (`clear=false`).
- [ ] REUSES S24's send/close/is_connected (no notify/disconnect duplicates); EXTENDS on_exit.
- [ ] File placement matches the desired tree (bridge.lua modified; on_exit_spec/smoke in tests/).
- [ ] Anti-patterns avoided: no `:write` inside save_buffer (writefile); no blocking on bye;
      no ungated throws; no clobbering of S24's bridge.lua seams.
- [ ] `save_buffer` is the single write primitive (DRY) shared by on_exit + on_write.

### Documentation & Deployment
- [ ] [Mode A] LuaCATS docstrings on save_buffer/on_write/on_exit.
- [ ] The `WARNING:` lost-prompt block (PRD §11 verbatim intent) atop `on_exit`.
- [ ] Comment explaining the bye-as-notification choice + the best-effort-close-race + the
      noautocmd-write fallback.

---

## Anti-Patterns to Avoid
- ❌ Don't invent `M.notify`/`M.disconnect` — bridge.lua (S24) already has `M.send`/`M.close`/
  `M.is_connected`. CALL those. To send bye: `M.send({jsonrpc="2.0",method="bye",params={}})`.
- ❌ Don't DELETE or rewrite S24's `on_exit` transport teardown — EXTEND it (save+bye THEN the
  existing `M.close()`). S24's `bridge_spec.lua` must still pass.
- ❌ Don't call `vim.cmd("write")` inside `save_buffer` — it routes THROUGH a registered
  BufWriteCmd (on_write), coupling the handlers. Use `vim.fn.writefile` (LIVE-VERIFIED).
- ❌ Don't send `bye` as a request-and-await during `VimLeavePre` — the client is exiting. Send a
  fire-and-forget notification (no `id`) then close. (And accept the bye-vs-close race; the
  autosave is the synchronous load-bearing part — GOTCHA 7.)
- ❌ Don't put `M.close()` INSIDE the save/bye pcall such that a throwing send could skip it —
  close is the teardown and must ALWAYS run (put it AFTER the pcall, or in its own pcall).
- ❌ Don't forget `vim.bo[buf].modified=false` after a BufWriteCmd write — nvim does NOT
  auto-clear it for a custom handler (LIVE-VERIFIED).
- ❌ Don't gate bye+close on `autosave_on_exit` — only the SAVE is user-configurable; the
  server connection must always be released on exit.
- ❌ Don't create the `pi-editor` augroup with `clear=true` in the ftplugin edit — it's shared
  with S20's VimEnter autocmd (S22 already uses `clear=false`; preserve it).
- ❌ Don't add a `BufWritePre` autocmd — S22 intentionally omits it ("the temp file is writable,
  so the default :w works"); PRD §7.6 wants `BufWriteCmd`, not BufWritePre.