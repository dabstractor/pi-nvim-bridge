# PRP — P2.M9.T23.S38: Autosave on VimLeavePre/ExitPre + bridge teardown (send bye, close)

**Work item**: P2.M9.T23.S38 — "VimLeavePre/ExitPre — autosave if modified, send bye,
close connection" (1 point, module P2.M9 "Autosave & Exit Handling").

**Scope**: Implement the **body** of `M.on_exit(buf)` in
`plugin/lua/pi-editor/bridge.lua`. Today it is a stub that only calls `M.close()`
(see the `GOTCHA 12` comment + the `luacheck: ignore buf` annotation). The wiring
(buffer-local `VimLeavePre`/`ExitPre` autocmds that dispatch
`require("pi-editor.bridge").on_exit(buf)`) is **already COMPLETE** in
`plugin/ftplugin/pi-prompt.lua` (task S22) — do **not** modify the ftplugin.

---

## Goal

**Feature Goal**: When the pi-spawned Neovim editor is about to exit, the pi-prompt
buffer's edits are durably written back to the pi temp file (so pi reads the user's
latest prompt after the editor quits), AND the bridge connection is torn down
gracefully (best-effort `bye` JSON-RPC, then socket close) — all without ever
throwing or blocking exit, and safe to fire twice (once per registered event).

**Deliverable**: The single function `M.on_exit(buf)` in `bridge.lua`, upgraded from
the close-only stub to do three idempotent steps in order: **(1)** autosave-if-modified
→ **(2)** best-effort `bye` → **(3)** `M.close()`. Plus a `autosave_if_modified(buf)`
local helper. Plus a plenary spec + a smoke test exercising the new behavior.

**Success Definition**:
- `:q!` (force-quit) on a modified pi-prompt buffer writes the buffer's text to the
  pi temp file (verified: file bytes == buffer content, UTF-8, `\n`-delimited, single
  trailing newline — the exact format pi's
  `fs.readFileSync(tmpFile,"utf-8").replace(/\n$/,"")` consumes).
- A connected bridge sends exactly one `bye` JSON-RPC request (`{jsonrpc:"2.0",
  id:<n>, method:"bye", params:{}}`) on the wire during exit, then closes.
- `on_exit(buf)` never throws and is safe when: never connected, called twice
  (ExitPre then VimLeavePre — see Gotcha A), given an invalid/unloaded/unnamed
  buffer, or called with the bridge already closed.
- The pre-existing `bridge_spec.lua` / `bridge_smoke.lua` cases for `on_exit` still
  pass unchanged (no-op-when-never-connected holds because the autosave guard skips
  unnamed/unmodified buffers).

---

## Why

- **PRD §11 (the load-bearing reason):** "pi reads the file only after the editor
  exits with status 0. The plugin **MUST** autosave the buffer on VimLeavePre/ExitPre
  when modified … Without this a user who types and quits with `:q` silently loses
  their prompt." This is the single highest-impact correctness fix in the M9 module.
- **PRD §5.4 / §7.6:** graceful `bye` (`C→S {} → {ok:true}`, server then half-closes)
  is the documented teardown; `VimLeavePre`/`ExitPre` is where it is sent.
- Closes the S22 forward contract: the ftplugin documents
  `require("pi-editor.bridge").on_exit(buf)` as "autosave-if-modified + send bye +
  close". Until S38 lands, exit does NOT save the user's prompt — a real data-loss bug.

---

## What

**User-visible behavior**: the user edits their prompt in the pi-spawned Neovim,
then quits however they like (`:wq`, `:q`, `:q!`, `:x`, `:qa`). On exit the temp
file always reflects their latest edits, and pi picks up those edits. No
"Save changes?" confusion, no lost text on `:q!`.

**Technical requirements**:
1. `on_exit(buf)` is the **sole** function modified. Its signature is unchanged
   (`on_exit(buf)` — `buf` is an integer buffer handle, now actually USED).
2. Autosave uses `vim.fn.writefile(vim.fn.getbufline(buf, 1, "$"), name)` (NOT
   `:write`) — see Implementation Blueprint for the rationale.
3. `bye` is fire-and-forget via the existing `M.request(method, params, cb)` — do
   NOT await the ack (the loop is tearing down; awaiting is unreliable and pointless
  here).
4. Idempotent and throw-free on every path.

### Success Criteria

- [ ] `on_exit(buf)` writes a modified, named, loaded buffer's text to its file and
      clears `vim.bo[buf].modified`.
- [ ] `on_exit(buf)` skips the write for: invalid buf, unloaded buf, unmodified buf,
      unnamed (`name == ""`) buf — each without error.
- [ ] `on_exit(buf)` sends one `bye` request on the wire when `M.is_connected()`,
      and sends nothing when not connected.
- [ ] `on_exit(buf)` is a safe no-op when never connected (preserves
      `bridge_spec.lua:159`).
- [ ] Calling `on_exit(buf)` twice in a row (the real ExitPre→VimLeavePre double-fire)
      writes the file once, sends `bye` once, and never throws.
- [ ] `on_exit(buf)` never throws (all three steps pcall-guarded).
- [ ] New plenary spec `plugin/tests/bridge_on_exit_spec.lua` passes.
- [ ] New smoke test additions (or dedicated `on_exit_smoke.lua`) pass via the
      plenary-free runner.
- [ ] Existing `bridge_spec.lua` + `bridge_smoke.lua` still pass unchanged.

---

## All Needed Context

### Context Completeness Check

An implementer who knows nothing about this codebase can implement S38 from this PRP
+ the two files it names (`bridge.lua`, `ftplugin/pi-prompt.lua`) + the established
test patterns (`bridge_request_spec.lua`). The `bye` wire contract, the autosave
primitive, the double-fire idempotency requirement, and the exact test runners are all
specified below with citations.

### Documentation & References

```yaml
# MUST READ — the PRD sections that govern this task (already merged into PRD.md)
- url: PRD.md §7.6 (Buffer-local setup) — "ExitPre, VimLeavePre, BufWriteCmd → autosave if modified (§11) and close the bridge connection."
  why: defines the on_exit responsibilities (autosave + close) and the events that fire it
  critical: BufWritePre is intentionally NOT overridden by the ftplugin — the default `:w` already works for manual saves; S38 only adds the EXIT autosave path
- url: PRD.md §11 (Edge Cases) — "Forgotten save → lost prompt" + "autosave_on_exit = true by default"
  why: the data-loss bug this task fixes; the exact must-autosave-on-VimLeavePre/ExitPre requirement
  critical: pi reads the temp file ONLY after the editor exits status 0, trimming ONE trailing newline → our write must produce UTF-8 + \n-delimited + exactly one trailing \n
- url: PRD.md §5.4 (IPC Methods table) — `bye` C→S `{}` → `{ok:true}` (graceful disconnect)
  why: the exact wire shape on_exit must emit
  critical: the server ACKs then half-closes (extension sets `closeAfterResponse`); we do NOT wait for the ack

# The extension-side bye handler (the server our on_exit talks to) — read to confirm the wire contract
- file: extension/pi-editor-bridge.ts
  why: `makeByeHandler()` returns `{ok:true}` AND sets `state.closeAfterResponse=true`; registered via `registerBridgeHandler("bye", makeByeHandler())`
  pattern: SYNC handler, ignores params, ack-then-half-close (approach (a))
  gotcha: the consumer comment at the factory literally names this task — "Consumer: P2.M9.T23.S38 (Neovim VimLeavePre/ExitPre autocmd sends bye …)"
- file: extension/tests/ping-bye-getcommands-handler.test.ts
  why: the REAL integration test proving `bye` → `{ok:true}` + client observes the server half-close over a Unix socket
  pattern: the exact request envelope `{jsonrpc:"2.0",id:"b1",method:"bye",params:{}}` and the `{ok:true}` result

# The file you MUST edit
- file: plugin/lua/pi-editor/bridge.lua
  why: home of `M.on_exit(buf)` (currently a close-only stub) + `M.send`/`M.request`/`M.close`/`M.is_connected` (the primitives on_exit composes)
  pattern: read the [Mode A] header GOTCHAs 2/3/6/7/11/12 — they explain why send-then-close is safe and why close() is idempotent
  gotcha: GOTCHA 12 — "on_exit WILL be called in every pi-prompt session even though connect() is not yet wired … must no-op safely when never connected". S38 preserves this (autosave guard + is_connected gate + idempotent close).

# The wiring you must NOT touch (already COMPLETE, task S22) — read it to understand WHEN/HOW on_exit is called
- file: plugin/ftplugin/pi-prompt.lua
  why: registers the buffer-local `VimLeavePre` + `ExitPre` autocmds (gated on `config.autosave_on_exit ~= false`) that `dispatch("pi-editor.bridge","on_exit",buf)`
  pattern: both events are registered → on_exit fires TWICE on a normal exit (see Gotcha A)
  gotcha: the autocmd registration is gated on autosave_on_exit; default true. Do not duplicate or re-gate inside on_exit.

# The config on_exit reads
- file: plugin/lua/pi-editor/init.lua
  why: `M.defaults.autosave_on_exit = true` (S21) — the gate the ftplugin checks. on_exit itself does NOT re-read it (the ftplugin already gated the autocmd); it always autosaves-when-called.

# Test patterns to mirror EXACTLY
- file: plugin/tests/bridge_request_spec.lua
  why: the canonical pattern for "spin a real luv Unix-socket server, do the hello handshake, observe a client request on the wire". S38's bye-on-the-wire test copies this harness.
  pattern: `with_request_server(opts, spec)` — adds a `mode` (e.g. `"record_bye"`) that captures the bye request; `descriptor(path)` builder; `reset_module()` between cases; the server replies to `hello` with a valid HelloResult.
  gotcha: do NOT name a spec-local table `pending` (shadows plenary.busted's skip function) — the file warns about this.

# Neovim / luv runtime facts (verified in research/, with :help tags + URLs)
- docfile: plan/001_c56962b4fa17/P2M9T23S38/research/nvim-exit-autosave.md
  section: "Q1 VimLeavePre vs ExitPre" + "Q3 Best-practice API" + "Q6 Common pitfalls"
  why: ExitPre fires BEFORE VimLeavePre (both fire on normal exit → on_exit runs twice → MUST be idempotent); writefile is deterministic UTF-8+\n; never use vim.schedule in an exit handler
- docfile: plan/001_c56962b4fa17/P2M9T23S38/research/luv-write-close-graceful-disconnect.md
  section: "Q5 Pattern A (synchronous write-then-close) for VimLeavePre" + "Q6 bye is courtesy, not required"
  why: for a ~60-byte bye on a Unix socket, pipe:write completes write(2) synchronously inside the call, so send-then-close delivers the bytes; the write cb may fire with ECANCELED (tolerate); the loop may not iterate again, so never await/defer
```

### Current Codebase tree (relevant slice)

```bash
plugin/
  lua/pi-editor/
    bridge.lua        # EDIT — M.on_exit(buf) body + new local autosave_if_modified(buf)
    init.lua          # read — M.defaults.autosave_on_exit (the ftplugin's gate)
  ftplugin/
    pi-prompt.lua     # READ-ONLY — already dispatches on_exit on VimLeavePre/ExitPre (S22)
  tests/
    bridge.lua specs  # ADD bridge_on_exit_spec.lua; keep bridge_spec.lua / bridge_smoke.lua green
extension/
  pi-editor-bridge.ts # READ-ONLY — makeByeHandler (the server side of our bye)
plan/001_c56962b4fa17/P2M9T23S38/research/
  nvim-exit-autosave.md                  # ExitPre/VimLeavePre + autosave primitives
  luv-write-close-graceful-disconnect.md # send-then-close flush semantics
```

### Desired Codebase tree with files to be added/edited

```bash
plugin/lua/pi-editor/bridge.lua            # MODIFY M.on_exit (≈ +25 lines) + add autosave_if_modified local
plugin/tests/bridge_on_exit_spec.lua       # CREATE — plenary spec (Level 2 gate)
plugin/tests/bridge_smoke.lua              # OPTIONAL EXTEND — add a CASE 4 autosave check, OR
plugin/tests/on_exit_smoke.lua             #   CREATE a dedicated plenary-free smoke (Level 1 gate)
```

### Known Gotchas of our codebase & Library Quirks

```lua
-- GOTCHA A (CRITICAL — drives the whole design): the ftplugin registers BOTH
-- "VimLeavePre" AND "ExitPre" for on_exit. On a normal exit ExitPre fires FIRST,
-- then VimLeavePre — so on_exit runs TWICE. Therefore on_exit MUST be idempotent:
--   * autosave: vim.bo[buf].modified is cleared on the first write → 2nd call no-ops.
--   * bye: M.is_connected() is false after the first M.close() → 2nd call skips bye.
--   * close: guarded by state.closed (GOTCHA 2 in bridge.lua) → 2nd call is a no-op.
-- (Do NOT try to "fix" this by changing the ftplugin — it is COMPLETE, owned by S22.
--  Embrace the double-fire; the three guards above make it free.)

-- GOTCHA B (autosave primitive): use vim.fn.writefile(vim.fn.getbufline(buf,1,"$"), name)
-- NOT :write / nvim_buf_call(vim.cmd write). Reasons:
--   1. DETERMINISTIC wire format: writefile emits UTF-8 + \n between lines + ONE trailing
--      \n — the EXACT bytes pi's readFileSync(tmp).replace(/\n$/,"") expects, independent
--      of the user's 'fileformat'/'fileencoding' (which :write honors and could be CRLF/latin1).
--   2. NO user autocmds: :write runs BufWritePre/BufWritePost → a formatter (conform.nvim,
--      prettier, etc.) could MUTATE the user's prompt text on the way out. writefile is raw.
--   3. writefile does NOT clear 'modified' → set vim.bo[buf].modified=false manually after.
--      (:write clears it for you, but the determinism/autocmd wins outweigh that convenience.)

-- GOTCHA C (bye is best-effort + fire-and-forget): call M.request("bye", {}, function() end)
-- then IMMEDIATELY M.close(). Do NOT await the {ok:true} ack:
--   * During VimLeavePre the nvim/luv loop may not iterate again → a deferred wait never resolves.
--   * The ~60-byte bye completes write(2) synchronously inside pipe:write (kernel buffer >> 60B),
--     so the bytes are already in the kernel before M.close() runs; close cannot lose them.
--   * The server handles a clean client EOF (read_cb data==nil → flush → on_close) even if bye
--     is dropped, so bye is courtesy, not correctness. (research/luv-… §Q6.)
-- The empty cb ignores the ack; M.close() drains the pending entry firing cb("connection closed")
-- — harmless (no-op cb). The bye RESPONSE, if it beats close(), resolves the entry; if not, close
-- drains it; either way the empty cb swallows it.

-- GOTCHA D (send-callback ECANCELED is safe): M.send's write callback routes a non-nil werr to
-- M.close()+on_close. After our explicit M.close(), state.on_close is nil'd and M.close() is
-- idempotent → the late ECANCELED cb is a silent no-op. Do not add special handling for it.

-- GOTCHA E (never vim.schedule / vim.defer_fn in on_exit): deferred work does not run during
-- process teardown. Do the file write + send + close SYNCHRONOUSLY, each pcall-wrapped.

-- GOTCHA F (buf guards): check vim.api.nvim_buf_is_valid(buf) AND nvim_buf_is_loaded(buf) AND
-- vim.bo[buf].modified AND vim.api.nvim_buf_get_name(buf) ~= "" BEFORE writefile. Unnamed/scratch
-- buffers return "" → writefile("","") would be wrong; skip them. This guard also keeps the
-- existing "on_exit(0) no-op when never connected" test green (the test's buf 0 is unnamed/empty).

-- GOTCHA G (autosave is independent of connection state): autosave runs whether or not the bridge
-- connected. bye+close are the only connection-dependent steps. (A pi-prompt buffer exists even
-- if the handshake failed — the filetype was set before handshake — so on_exit still fires and
-- MUST still save the user's prompt.)

-- GOTCHA H (the autosave_on_exit gate is upstream): the ftplugin only registers the exit autocmds
-- when config.autosave_on_exit ~= false. So on_exit is only CALLED when autosave is enabled. Do
-- NOT re-check the config inside on_exit. (If a user sets autosave_on_exit=false, on_exit is not
-- called at all — bye+close rely on process-exit FD closure + the server's EOF path. That is the
-- documented S22 behavior; out of scope for S38.)
```

---

## Implementation Blueprint

### Data models and structure

No new data models. `on_exit(buf)` consumes the existing `pi-editor.BridgeDescriptor`
(implicitly, via `M.is_connected`) and the existing `M.request`/`M.close` machinery.
The only new symbol is a file-local helper `autosave_if_modified(buf)`.

### Implementation Tasks (ordered by dependencies)

```yaml
Task 1: ADD file-local helper `autosave_if_modified(buf)` to plugin/lua/pi-editor/bridge.lua
  - PLACE: near the other file-local forward declarations (resolve_handshake / resolve_request / dispatch block), OR just above M.on_exit. Keep it a module-local (NOT on M) — it is pure nvim-API work, not bridge state.
  - IMPLEMENT (exact body — copy this):
      local function autosave_if_modified(buf)
        if type(buf) ~= "number" then return end
        if not vim.api.nvim_buf_is_valid(buf) then return end
        if not vim.api.nvim_buf_is_loaded(buf) then return end   -- content resident?
        if not vim.bo[buf].modified then return end              -- nothing to save
        local name = vim.api.nvim_buf_get_name(buf)
        if name == "" then return end                            -- unnamed/scratch -> skip (GOTCHA F)
        -- writefile: UTF-8 + \n-delimited + single trailing \n (pi's exact wire format; GOTCHA B).
        -- NO user autocmds (no formatter risk on prompt text).
        vim.fn.writefile(vim.fn.getbufline(buf, 1, "$"), name)
        vim.bo[buf].modified = false                             -- writefile does NOT clear it (GOTCHA B.3)
      end
  - NAMING: snake_case local (matches the file's other locals: read_cb is local; resolve_* are locals).
  - NO pcall INSIDE the helper's body — the CALLER (on_exit) pcalls it (one pcall per step; research §Q6.1).

Task 2: REWRITE M.on_exit(buf) in plugin/lua/pi-editor/bridge.lua
  - FIND: the current stub `function M.on_exit(buf) -- luacheck: ignore buf ... M.close() end` (≈ line 746).
  - REPLACE its BODY with the three-step sequence (keep the existing doc-comment block, UPDATE it to describe the new behavior + cite PRD §7.6/§11/§5.4 + the GOTCHAs above; drop the `luacheck: ignore buf` since buf is now used):
      function M.on_exit(buf)
        -- (1) autosave — independent of connection (PRD §11; GOTCHA G). Never throw (GOTCHA E).
        pcall(autosave_if_modified, buf)
        -- (2) best-effort graceful bye — fire-and-forget, ONLY if connected (PRD §5.4; GOTCHA C).
        if M.is_connected() then
          pcall(M.request, "bye", {}, function(_err, _result) end)  -- empty cb ignores the ack/drain
        end
        -- (3) teardown — idempotent (GOTCHA 2 in the header; safe across the ExitPre+VimLeavePre double-fire, GOTCHA A).
        M.close()
      end
  - PRESERVE: the function name, signature (`buf`), and that it is on `M` (the ftplugin dispatches `require("pi-editor.bridge").on_exit`).
  - DO NOT: re-check config.autosave_on_exit (GOTCHA H); await the bye ack; use vim.schedule.

Task 3: CREATE plugin/tests/bridge_on_exit_spec.lua (plenary/busted — the Level 2 gate)
  - FOLLOW pattern: plugin/tests/bridge_request_spec.lua (the `with_request_server(opts, spec)` harness + `descriptor(path)` + `reset_module()`). Copy the harness verbatim, add a new mode.
  - ADD a server mode `"record_bye"` (or reuse `echo`): capture every non-hello request the server sees; assert the captured request is `{jsonrpc="2.0", id=<string>, method="bye", params={}}`.
  - CASES (each `it`):
      a) "autosave: writes a modified named loaded buffer to its file (UTF-8 + \\n + trailing \\n) and clears modified"
         — create a real temp file (os.tmpname() or /tmp/pi-s38-<rand>.pi.md), set buf name, nvim_buf_set_lines, mark modified, require bridge (NOT connected), on_exit(buf), assert file content == lines joined with \n + trailing \n, assert vim.bo[buf].modified == false.
      b) "autosave: skips an unmodified buffer (file untouched)"
      c) "autosave: skips an unnamed buffer (no error, no file written)"
      d) "autosave: skips an invalid buf handle (no error)"
      e) "bye: when connected, sends exactly one bye request on the wire then closes" — use with_request_server({mode="record_bye"}); handshake first (so M.is_connected() is true); on_exit(buf); assert the server saw the bye request; assert bridge.is_connected() == false.
      f) "bye: when NOT connected, sends nothing and close is a no-op" — on_exit(buf) without connecting; assert no throw, is_connected false.
      g) "idempotent across double-fire (ExitPre then VimLeavePre)" — connect + handshake, then call on_exit(buf) TWICE; assert: file written once (or twice-harmless), exactly ONE bye seen on the wire, second call is a clean no-op, no throw.
      h) "never throws: on_exit(0) when never connected is a safe no-op" — preserves the bridge_spec.lua:159 guarantee.
  - NAMING: `describe("bridge.on_exit (S38)", ...)`. test fns `test_<scenario>` style is not required — plenary `it("…")` prose is the repo convention.
  - CLEANUP: os.remove the temp files in a `finally`/`after_each`; call reset_module() in `before_each` (mirror bridge_request_spec.lua).
  - PLACEMENT: plugin/tests/ (alongside the other bridge_*_spec.lua files).

Task 4: ADD a plenary-free smoke check (Level 1 gate)
  - OPTION A (preferred — extends an existing file): add a "CASE 4: on_exit autosave" block to plugin/tests/bridge_smoke.lua mirroring CASE 3's `do ... check(...) end` style. Create a temp file, load it into a buffer, modify, on_exit(buf), read the file back, assert equality, cleanup.
  - OPTION B: CREATE plugin/tests/on_exit_smoke.lua (standalone, `+luafile` runner) if keeping bridge_smoke.lua focused on transport is cleaner.
  - RUNNER (from plugin/, per AGENTS.md): `timeout 60 nvim --headless --clean -u NORC +"luafile tests/bridge_smoke.lua" +qa` (Option A) or the new file (Option B).
```

### Implementation Patterns & Key Details

```lua
-- The COMPLETE on_exit + helper (the entire diff is this block):

-- (place among the other file-local forward declarations, e.g. just below `local dispatch`)
--- Best-effort autosave of `buf` to its named file when modified. Pure nvim-API (no bridge
--- state). NEVER throws — the caller (on_exit) pcalls it. Uses writefile+getbufline for a
--- deterministic UTF-8 + \n + single-trailing-\n write that matches pi's temp-file wire
--- format (PRD §11) WITHOUT running user BufWritePre/Post autocmds (no formatter risk on
--- prompt text). Clears 'modified' manually (writefile does not). Skips invalid / unloaded /
--- unmodified / unnamed buffers. (research/nvim-exit-autosave.md §Q3/Q4/Q6.)
---@param buf integer Buffer handle (0 = current; non-number/invalid/unloaded -> no-op).
local function autosave_if_modified(buf)
  if type(buf) ~= "number" then return end
  if not vim.api.nvim_buf_is_valid(buf) then return end
  if not vim.api.nvim_buf_is_loaded(buf) then return end
  if not vim.bo[buf].modified then return end
  local name = vim.api.nvim_buf_get_name(buf)
  if name == "" then return end
  vim.fn.writefile(vim.fn.getbufline(buf, 1, "$"), name)
  vim.bo[buf].modified = false
end

-- (replace the existing M.on_exit stub body)
--- VimLeavePre / ExitPre handler — fulfills the S22 ftplugin forward contract
--- (`require("pi-editor.bridge").on_exit(buf)`). Three idempotent steps, each pcall-guarded
--- so exit is NEVER blocked or aborted (research §Q6.1; never vim.schedule — GOTCHA E):
---   (1) autosave buf to its file if modified (PRD §11 — prevents the lost-prompt bug;
---       independent of connection state, GOTCHA G).
---   (2) best-effort graceful `bye` JSON-RPC, fire-and-forget, ONLY when connected (PRD §5.4;
---       GOTCHA C — do NOT await; the ~60B bye flushes synchronously, the server handles EOF).
---   (3) M.close() — idempotent transport teardown (GOTCHA 2).
--- Safe across the ExitPre→VimLeavePre double-fire (GOTCHA A): autosave is gated on
--- 'modified' (cleared in step 1), bye on is_connected() (false after step 3), close on
--- state.closed. Safe when never connected (GOTCHA 12 — autosave guard + is_connected gate).
---@param buf integer The pi-prompt buffer handle (from the ftplugin dispatch).
function M.on_exit(buf)
  pcall(autosave_if_modified, buf)
  if M.is_connected() then
    pcall(M.request, "bye", {}, function(_err, _result) end)
  end
  M.close()
end
```

### Integration Points

```yaml
FTPLUGIN (READ-ONLY — already wired by S22):
  - plugin/ftplugin/pi-prompt.lua registers buffer-local {VimLeavePre, ExitPre} autocmds
    (gated on config.autosave_on_exit ~= false) → dispatch("pi-editor.bridge","on_exit",buf).
  - S38 changes NOTHING here. Verify with: grep -n "on_exit" plugin/ftplugin/pi-prompt.lua
    (expect the dispatch in the VimLeavePre/ExitPre loop).

CONFIG (READ-ONLY — S21):
  - plugin/lua/pi-editor/init.lua M.defaults.autosave_on_exit = true. on_exit does NOT read it.

WIRE (server side — READ-ONLY, P1.M2.T6.S14 COMPLETE):
  - extension/pi-editor-bridge.ts makeByeHandler() → {ok:true} + closeAfterResponse. Our bye
    request envelope: {jsonrpc:"2.0", id:<tostring(n)>, method:"bye", params:{}} (id assigned
    by M.request's monotonic counter; NEVER "h1").

NO DATABASE / NO ROUTES / NO NEW CONFIG KEYS.
```

---

## Validation Loop

> Run all commands from the `plugin/` directory. Wrap every nvim invocation in `timeout`
> (AGENTS.md). **NEVER pipe a heredoc into nvim's stdin** (AGENTS.md ⛔ HARD RULE) — write
> test snippets to a real `.lua` file and run with `+"luafile <path>"`.

### Level 1: Syntax & Smoke (Immediate Feedback)

```bash
# (a) Load bridge.lua in isolation — catches syntax errors / bad edits.
timeout 60 nvim --headless --clean -u NORC -c 'set rtp+=.' \
  -c 'lua require("pi-editor.bridge"); print("bridge loaded")' -c 'qa'
echo "exit=$?"   # expect 0

# (b) Plenary-free smoke (Option A: the new CASE 4 in bridge_smoke.lua; Option B: on_exit_smoke.lua).
cd plugin && timeout 60 nvim --headless --clean -u NORC +"luafile tests/bridge_smoke.lua" +qa
echo "exit=$?"   # expect 0; any "N check(s) failed" on stderr = failure
# (If Option B:) cd plugin && timeout 60 nvim --headless --clean -u NORC +"luafile tests/on_exit_smoke.lua" +qa
```

### Level 2: Unit / Component Tests (plenary)

```bash
cd plugin

# The NEW spec (the primary gate for S38).
timeout 90 nvim --headless --clean -u tests/minimal_init.lua \
  -c 'lua require("plenary.busted").run("tests/bridge_on_exit_spec.lua")'
echo "exit=$?"   # expect 0

# REGRESSION — the existing bridge specs must still pass (esp. on_exit no-op-when-not-connected).
timeout 90 nvim --headless --clean -u tests/minimal_init.lua \
  -c 'lua require("plenary.busted").run("tests/bridge_spec.lua")'
timeout 90 nvim --headless --clean -u tests/minimal_init.lua \
  -c 'lua require("plenary.busted").run("tests/bridge_request_spec.lua")'
echo "exit=$?"   # expect 0 for all three

# Lint/format (IF the repo has selene/stylua configured — check for selene.yml / stylua.toml).
# selene --config selene.yml plugin/lua/pi-editor/bridge.lua
# stylua --check plugin/lua/pi-editor/bridge.lua
```

### Level 3: Integration (real server ↔ real client)

The plenary spec's "bye on the wire" case IS the integration proof (real luv Unix socket +
real handshake + real on_exit). If an additional end-to-end check is desired, run the
extension's bye integration test to re-confirm the server half (already green, P1 COMPLETE):

```bash
# From repo root — the extension's REAL Unix-socket bye round-trip (server side of our client).
timeout 90 npx tsx --test extension/tests/ping-bye-getcommands-handler.test.ts
echo "exit=$?"   # expect 0 (confirms the server still acks bye + half-closes)
```

### Level 4: Creative / Domain-Specific Validation

```bash
# Manual end-to-end (optional, human-driven): with the bridge extension installed + nvim as
# $EDITOR, in a real pi session, open the editor (Ctrl+G), type a prompt, `:q!`, and confirm
# pi submits the typed text (not the pre-edit text). This is the PRD §11 data-loss scenario.
# (Not automatable from this PRP — it needs a live pi TUI. The Level 2 spec covers the logic.)
```

---

## Final Validation Checklist

### Technical Validation

- [ ] Level 1 smoke passes (`bridge_smoke.lua` or `on_exit_smoke.lua`, exit 0).
- [ ] Level 2: `bridge_on_exit_spec.lua` passes (exit 0).
- [ ] Level 2 regression: `bridge_spec.lua` + `bridge_request_spec.lua` still pass (exit 0).
- [ ] Level 3: `extension/tests/ping-bye-getcommands-handler.test.ts` still passes (exit 0).
- [ ] No new lint errors if selene/stylua is configured.

### Feature Validation

- [ ] Modified named loaded buffer → file written (UTF-8 + `\n` + single trailing `\n`), `modified` cleared.
- [ ] Unmodified / unnamed / invalid / unloaded buffer → no write, no error.
- [ ] Connected → exactly one `bye` request on the wire, then closed.
- [ ] Not connected → no `bye`, close is a no-op, no throw.
- [ ] Double-fire (ExitPre + VimLeavePre) → autosave once, `bye` once, close idempotent, no throw.
- [ ] `on_exit(0)` when never connected is still a safe no-op (existing guarantee preserved).
- [ ] PRD §11 lost-prompt scenario resolved (the temp file reflects the latest edits on exit).

### Code Quality Validation

- [ ] `on_exit` is throw-free (each of the 3 steps pcall-guarded; no `vim.schedule`).
- [ ] `autosave_if_modified` is a file-local, pure nvim-API helper (no bridge-state coupling).
- [ ] No new patterns introduced — reuses `M.request` / `M.close` / `M.is_connected` verbatim.
- [ ] Doc-comments cite PRD §5.4/§7.6/§11 + the GOTCHAs (A–H) for the next reader.
- [ ] The ftplugin (`pi-prompt.lua`) and `init.lua` are UNCHANGED (S22/S21 boundaries respected).

### Documentation & Deployment

- [ ] `M.on_exit` doc-comment updated to describe autosave + bye + close (the stub comment is stale).
- [ ] The `luacheck: ignore buf` annotation is removed (buf is now used).
- [ ] No new env vars / config keys / settings (autosave_on_exit already exists, default true).

---

## Anti-Patterns to Avoid

- ❌ Don't `await`/block on the `bye` ack — the loop is tearing down (GOTCHA C/E).
- ❌ Don't use `:write` / `nvim_buf_call(vim.cmd "write")` for autosave — formatter side
  effects + fileformat/fileencoding non-determinism (GOTCHA B). Use `writefile(getbufline())`.
- ❌ Don't use `vim.schedule` / `vim.defer_fn` inside `on_exit` — deferred work doesn't run
  during teardown (GOTCHA E).
- ❌ Don't try to make `on_exit` fire only once (e.g. a "did_exit" flag) to "fix" the
  double-fire — the three guards (modified / is_connected / state.closed) already make the
  second call a free no-op; adding a flag is extra state for no benefit (GOTCHA A).
- ❌ Don't re-check `config.autosave_on_exit` inside `on_exit` — the ftplugin already gated
  the autocmd (GOTCHA H).
- ❌ Don't modify `plugin/ftplugin/pi-prompt.lua` or `plugin/lua/pi-editor/init.lua` — both
  are COMPLETE (S22/S21). S38 edits ONLY `bridge.lua` (+ tests).
- ❌ Don't reimplement the `bye` envelope or id by hand — use `M.request("bye", {}, cb)`
  (assigns the monotonic id, tracks the pending entry, drains cleanly on close).
- ❌ Don't catch-all `pcall(function() ... end)` wrapping the WHOLE on_exit body in one pcall —
  use THREE separate pcalls (one per step) so a failure in autosave still allows bye+close,
  and a failure in bye still allows close (research §Q6.1).

---

## Confidence Score

**9/10** for one-pass implementation success.

Rationale: this is a small, surgical change to ONE function (+ one local helper) in a file
whose entire transport/RPC layer is already COMPLETE and battle-tested (P1 + P2.M4–M8). The
`bye` wire contract is fully implemented and integration-tested on the server side; the
client just emits it. The autosave primitive is a 6-line nvim-API helper with a deterministic
spec. The only subtlety (double-fire idempotency) is handled by guards that already exist or
are trivially added. The −1 is for the residual uncertainty flagged in
`research/nvim-exit-autosave.md §Gaps` (exact ExitPre/VimLeavePre ordering verbatim + `:cq`
firing) — but the design does not DEPEND on that ordering (it's safe under double-fire
regardless), so even if the verbatim differs, the implementation holds.