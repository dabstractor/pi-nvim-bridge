---
name: "P2.M5.T15.S25 — hello handshake (Lua bridge client)"
description: >
  After the S24 transport connects, the pi-editor.nvim bridge client must complete the
  JSON-RPC `hello` handshake: send the descriptor token to pi's bridge server, validate the
  success/error response, extract server identity (`serverVersion`/`cwd`/`fdAvailable`), set
  `require("pi-editor").bridge` on success, and wire connect+handshake into the VimEnter
  activation flow — degrading silently to a plain markdown buffer on any failure (PRD §11).
  This is the first PROTOCOL consumer of the S24 transport; it introduces the single
  `on_event` dispatcher that S26 (`request`/correlation) and S27 (`commandsChanged`) extend.
---

# Goal

**Feature Goal**: Implement the authenticated `hello` handshake (PRD §5.3 / §5.4) on the
Neovim side of the bridge: once the S24 Unix-socket transport reports `on_ready(nil)`, the
client sends exactly one `hello` request carrying the descriptor `token`, validates the
server's success-or-`-32600` response, and extracts the server-info triple. On success it
publishes the bridge module as `require("pi-editor").bridge` (the placeholder S24 left
`nil`); on any failure it closes and degrades silently. The handshake is wired into the
existing `VimEnter` activation flow so a pi-launched Neovim gets completion-ready with zero
user configuration, while every ordinary (non-pi) Neovim session stays 100% dormant.

**Deliverable**:
1. A new public `handshake(desc, on_result)` function + minimal internal dispatcher added to
   `plugin/lua/pi-editor/bridge.lua` (the S24 transport module — extended, NOT replaced).
2. New module state: `M.server_info`, `M.version`, and a `handshake_state` race-guard.
3. A one-call wiring in `plugin/lua/pi-editor/init.lua` `activate()` (pcall-wrapped).
4. A plenary/busted spec `plugin/tests/bridge_handshake_spec.lua` (real luv socket server).
5. A dormant-session assertion in `plugin/tests/smoke.lua` (`pi.bridge` stays `nil`).

**Success Definition**:
- A pi-launched Neovim, after `VimEnter`, has `require("pi-editor").bridge ~= nil` and
  `M.server_info == {serverVersion, cwd, fdAvailable}` matching the bridge server's `hello` result.
- A bad/missing token, a malformed response, a silent server close, a connect failure, or a
  handshake timeout each leave `pi.bridge == nil`, close the transport, and never throw / never block startup.
- `on_result` is invoked **exactly once** for every handshake (race-safe across response/timeout/close).
- The existing `bridge_spec.lua` (S24) and `jsonlreader_spec.lua` (S23) still pass unchanged.

## User Persona

**Target User**: A developer running pi who hits `Ctrl+G` (the `app.editor.external`
keybinding) to edit the current prompt in Neovim. Secondary: a plugin author wiring a
blink.cmp / nvim-cmp source that calls `require("pi-editor").bridge.request(...)` (PRD §7.7).

**Use Case**: The moment pi spawns `$EDITOR=nvim` on the temp prompt file, the plugin must
quietly authenticate to pi's live autocomplete bridge so subsequent keystrokes can fetch
`/commands`, `@files`, and path completions. The user never sees the handshake — only its
result (a working completion menu, or, on failure, an ordinary markdown buffer).

**User Journey**: pi `Ctrl+G` → `openExternalEditor()` spawns `nvim <tmpfile>` (inherits
`PI_EDITOR_BRIDGE`) → Neovim `VimEnter` → `init.lua activate()` reads descriptor →
`bridge.handshake(desc, …)` → `connect` → `on_ready` → `send hello` → server validates token
→ success response → `pi.bridge` set, `M.server_info` populated → ftplugin keymaps live →
user types, completion flows. On any handshake failure: buffer is plain markdown, no crash.

**Pain Points Addressed**: Without a handshake there is NO auth boundary (PRD §12 — the token
is the real security boundary) and no way to know the server is actually pi's bridge (vs a
stale socket). The handshake is the gate that makes the rest of the plugin safe to wire.

## Why

- **Security gate (PRD §12):** the `hello` token proves the editor is the process pi spawned
  (the token rides `process.env`, process-local, never on disk). No handshake = no auth.
- **Capability discovery:** `hello`'s result carries `fdAvailable` (drives whether `@file`
  fuzzy search will work — PRD §11) and `cwd` (the session root completion uses).
- **Enables every downstream task:** S26 (`request`), S27 (`commandsChanged`), S30+ (completion
  triggers), S32/S33 (accept/Tab), S38 (`bye`/autosave) ALL assume an authenticated, ready
  bridge. This task is the prerequisite that flips `pi.bridge` from `nil` to live.
- **Unblocks the S24 transport:** `bridge.lua` ships connect/send/close as a TESTED but
  UNWIRED module (S24 notes L185: "dead code until S25"). S25 is its first real consumer.

## What

User-visible: nothing directly (the handshake is silent). The observable effect is that
`require("pi-editor").bridge` becomes non-`nil` after `VimEnter` in a pi session, enabling
completion; in every other case the plugin is inert.

Technical requirements:
- Send the `hello` JSON-RPC request (envelope + framing below) exactly once, inside the S24
  `on_ready(nil)` callback.
- Correlate the response by the literal `id == "h1"`.
- Distinguish success (`result.ok == true`) from failure (`error` object, malformed result,
  or no response within `config.rpc_timeout_ms`).
- Extract `{serverVersion, cwd, fdAvailable}` defensively (per-field type guards).
- Resolve the handshake caller callback `on_result(err, info)` **exactly once**.
- Set `require("pi-editor").bridge = <bridge module>` ONLY on success.
- Wire `handshake()` into `init.lua activate()` behind a `pcall` (never break activation).

### Success Criteria

- [ ] `bridge.handshake(desc, cb)` sends `{"jsonrpc":"2.0","id":"h1","method":"hello","params":{"token":desc.token,"client":"pi-editor.nvim","clientVersion":"0.1.0"}}` (LF-terminated) once the transport connects.
- [ ] On a success response (`result.ok == true`): `on_result(nil, {serverVersion,cwd,fdAvailable})` is called; `require("pi-editor").bridge` is set to the bridge module; `M.server_info` holds the extracted triple.
- [ ] On an `error` response (e.g. `code == -32600` "bad token"): transport is closed; `pi.bridge` stays `nil`; `on_result(<err>)` is called exactly once.
- [ ] On malformed-but-`id=="h1"` response (no `result`/`error`): treated as failure (above).
- [ ] On silent server close / connect failure (`ENOENT`/`ECONNREFUSED`)/handshake timeout: `on_result(<err>)`; `pi.bridge` stays `nil`; never throws.
- [ ] `on_result` fires EXACTLY ONCE across the response/timeout/close races.
- [ ] `bridge.handshake` NEVER throws — invalid descriptor (`nil`/missing `token`) calls `on_result("invalid descriptor")` and touches no socket.
- [ ] `init.lua activate()` calls `handshake` inside a `pcall`; activation still returns the descriptor and sets filetype even if the bridge module is absent/broken.
- [ ] In a dormant session (no `PI_EDITOR_BRIDGE` env var), `require("pi-editor").bridge` remains `nil` (the `smoke.lua` assertion still holds).
- [ ] `bridge_spec.lua` (S24) and `jsonlreader_spec.lua` (S23) pass UNCHANGED.
- [ ] New `bridge_handshake_spec.lua` passes all cases in §Validation Loop → Level 2.

## All Needed Context

### Context Completeness Check

> "If someone knew nothing about this codebase, would they have everything needed to implement this successfully?"

Yes — this PRP names every authoritative file (with line refs), quotes the exact wire
envelopes (success AND failure), specifies the Lua/luv race-safety rules, and gives the
copy-pasteable test-server pattern. The implementer needs only Neovim + `vim.uv`/`vim.json`
knowledge (both built in) and the repo paths below.

### Documentation & References

```yaml
# MUST READ — the contracts this task consumes (all DONE, read before editing)
- file: plugin/lua/pi-editor/bridge.lua
  why: The S24 transport to extend. connect(path,on_ready,on_event,on_close)+send(obj)+close().
    Its top-of-file [Mode A] header is the S24→S25 FORWARD CONTRACT: "S25 sends hello in
    on_ready; S25 validates hello in on_event; the require('pi-editor').bridge placeholder
    S25 sets after handshake." Re-read GOTCHA 6 (send() gated on state.connected — set true
    INSIDE the connect cb, so hello at the top of on_ready is legal), GOTCHA 2 (double-close
    safe — close() is idempotent via state.closed), GOTCHA 5 (NO vim.api from luv cbs), GOTCHA
    10 (singleton — one on_event per session), GOTCHA 11 (wire form = encode(obj).."\n").
  pattern: module-level `state` table + setmetatable-free functions; pcall-wrap luv calls;
    route every teardown path through M.close(); clear callback refs in close().
  gotcha: connect()'s PUBLIC SIGNATURE MUST NOT CHANGE — handshake() is an ADDED CALLER that
    passes its own internal on_event (the dispatcher). The existing bridge_spec calls connect
    directly with its own on_event; keep that working.

- file: extension/pi-editor-bridge.ts
  why: The SERVER hello handler (makeHelloHandler, ~L500). Defines the EXACT success/error the
    Lua client must consume. Token match ⇒ {ok:true,serverVersion,cwd,fdAvailable} + flips
    handshakeComplete; any mismatch/missing/stopped ⇒ throw BridgeRpcError(-32600,"bad token",
    {fatal:true}). Message is the LITERAL "bad token" — token value NEVER in it (PRD §12).
  pattern: defensive cwd fallback (getCwd() ?? "") — the client must mirror this.
  gotcha: serverVersion is BRIDGE_VERSION ("0.1.0", hardcoded); the plugin sends the same as
    clientVersion for symmetry (informational; server ignores it).

- file: extension/connection.ts
  why: handleLine() (the server dispatcher). Request branch: handler returns ⇒ sendResponse;
    handler throws BridgeRpcError(fatal:true) ⇒ sendError(code) THEN sock.end() (graceful FIN).
    So a bad-token failure = client sees the -32600 line THEN EOF. The Lua client must treat
    the ERROR LINE as the verdict (do not wait for the close).
  gotcha: the close after a fatal error is GRACEFUL (end()/FIN, not RST) — the error line is
    always delivered before EOF (S24 read_cb flushes on EOF).

- file: extension/protocol.ts
  why: The wire TYPES. HelloParams{token,client?,clientVersion?}; HelloResult{ok:true,
    serverVersion,cwd,fdAvailable}; JsonRpcResponse = {result?}|{error:{code,message}}. id is
    string (PRD §5.3). Use these field names EXACTLY (the server keys on them).

- file: extension/tests/hello-handler.test.ts
  why: The server contract test — the precise envelopes + the "bad token ⇒ -32600 then close"
    sequence the Lua client interoperates with. Mirror its assertions in the Lua spec.

- file: plugin/lua/pi-editor/init.lua
  why: activate() owns M.descriptor (path+token) and is the once-per-session seam to wire the
    handshake. M.bridge is the placeholder to set (typed table|nil; doc says "Populated by
    bridge.lua after a successful connect + handshake"). M.descriptor has cwd as a fallback.
  pattern: setup() self-call if config nil; pcall-safe; NEVER throws/NEVER notifies in activate.
  gotcha: preserve activate()'s "NEVER throws / NEVER notifies" contract — wrap the handshake
    call in pcall; the one-time vim.notify on failure is task S39, NOT this task.

- file: plugin/tests/bridge_spec.lua
  why: The plenary/busted test PATTERN to mirror — its with_server(spec) helper spins a REAL
    luv unix-socket server (unique path), decodes client requests via the S23 jsonlreader, and
    echoes JSONL responses. S25's spec extends this: the server implements hello semantics.
  pattern: vim.wait(timeout_ms, predicate_fn, interval_ms) to drive async assertions; unique
    socket path per test; stop() closes server+conn and calls bridge.close().

- file: plugin/tests/minimal_init.lua
  why: The plenary harness bootstrap. Prepends plenary + appends the plugin root to runtimepath.
    plenary is at /home/dustin/.local/share/nvim/lazy/plenary.nvim (verified).

- file: plugin/tests/smoke.lua
  why: The zero-dependency smoke runner. Asserts pi.bridge == nil pre-handshake in a dormant
    session — ADD an assertion that confirms handshake() does NOT set it without the env var.

- docfile: plan/001_c56962b4fa17/P2M5T15S24/research/notes.md
  why: The S24 design notes — §"connect signature" (path ONLY; token is S25's), the on_ready/
    on_event/on_close forward contracts (L149-155), and "WIRING connect() into the activation
    flow (ftplugin/activate) — S25" (L175). Confirms this task owns BOTH the handshake AND the
    activation wiring.
  section: lines 142-185 (the S24→S25 boundary).

- url: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#base-protocol
  why: JSON-RPC-over-newline framing reference (Content-Length is NOT used here — this is bare
    JSONL, one object per \n). Confirms the id-correlation + request/response model this handshake uses.
  critical: do NOT add Content-Length headers — the bridge is strict-JSONL (PRD §5.2; S23 jsonlreader
    splits on "\n" only).

- url: https://github.com/luvit/luv/blob/master/docs.md
  why: luv API for uv.new_timer / timer:start / :stop / :close (the handshake timeout) and
    uv.new_pipe / :connect / :read_start / :write (already used by S24). Built into Neovim as vim.uv.
  critical: timers are one-shot with repeat=0; :close() them in the resolve path or they leak
    across the many editor open/close cycles one session sees (PRD §6.7).
```

### Current Codebase tree (plugin subtree — the edit surface)

```bash
plugin/
  lua/pi-editor/
    init.lua          # setup(), defaults, activate() (S21) — WIRING target (this task)
    bridge.lua        # S24 transport: connect/send/close/on_exit/is_connected — EXTEND (this task)
    jsonlreader.lua   # S23 (DONE) — feeds decoded tables to on_event
  plugin/pi-editor.lua   # VimEnter shim (S20) — UNCHANGED
  ftplugin/pi-prompt.lua # S22 — UNCHANGED (its bridge.on_exit forward contract is already S24)
  tests/
    minimal_init.lua    # plenary bootstrap — UNCHANGED
    smoke.lua           # zero-dep smoke — ADD dormant-session assertion (this task)
    bridge_spec.lua     # S24 spec — UNCHANGED (regression)
    jsonlreader_spec.lua# S23 spec — UNCHANGED (regression)
    bridge_handshake_spec.lua  # NEW (this task) — the Level-2 gate
```

### Desired Codebase tree with files to be added/modified

```bash
plugin/lua/pi-editor/bridge.lua        # MODIFY — add handshake(), dispatch(), resolve fn, server_info, version, handshake_state
plugin/lua/pi-editor/init.lua          # MODIFY — activate() pcall-calls bridge.handshake after M.descriptor=desc
plugin/tests/bridge_handshake_spec.lua # CREATE — plenary spec (real socket server; success/bad-token/timeout/close/race/invalid)
plugin/tests/smoke.lua                 # MODIFY — assert pi.bridge==nil in dormant session (handshake never ran)
```

### Known Gotchas of our codebase & Library Quirks

```lua
-- CRITICAL: bridge.lua is a SINGLETON transport (S24 GOTCHA 10): one pipe, ONE on_event per
-- session. S25 must own the on_event the jsonlreader feeds — because S26/S27 will LATER extend
-- that SAME dispatch. Add ONE module-level `dispatch(msg)` function; handshake() passes it as
-- connect()'s on_event. Do NOT make handshake instance-based.

-- CRITICAL: connect()'s PUBLIC SIGNATURE IS UNCHANGED (path, on_ready, on_event, on_close).
-- handshake() is an ADDED CALLER of connect() that passes its OWN internal on_event. The
-- existing bridge_spec.lua calls connect() directly with its own on_event — it MUST keep passing.

-- CRITICAL: send() is GATED on state.connected (S24 GOTCHA 6), which is set true INSIDE the
-- connect cb, JUST BEFORE on_ready(nil) fires. So calling M.send(hello) at the TOP of the
-- on_ready cb is legal. Sending BEFORE on_ready is a silent byte-drop (returns false).

-- CRITICAL: a bad-token failure arrives as the -32600 ERROR LINE (via on_event) THEN EOF (via
-- on_close). Treat the ERROR LINE as the verdict; the close is cleanup. S24's read_cb flushes
-- the jsonlreader on EOF, so a trailing error line (no final \n) is still delivered first.

-- CRITICAL: M.close() is IDEMPOTENT (S24 GOTCHA 2: shadow state.closed flag + pcall). Calling
-- it from the error-response path AND again from the EOF on_close path is SAFE — the second is a no-op.

-- CRITICAL: use a LUV TIMER (uv.new_timer), NOT vim.defer_fn, for the handshake timeout —
-- bridge.lua is pure vim.uv (S24 GOTCHA 5: no vim.api / nvim-loop calls from luv callbacks).
-- resolve() must :stop()+:close() the timer or it leaks across editor open/close cycles.

-- CRITICAL: NEVER put the token value in any error string / notify / log (PRD §12). The server's
-- message is the literal "bad token"; the client must likewise never echo desc.token.

-- CRITICAL: on_result must fire EXACTLY ONCE. Guard with handshake_state.pending (bool): the
-- FIRST of {response, timeout, close} that sees pending==true flips it false and resolves; the
-- others no-op. Single-threaded nvim/luv loop ⇒ this is a sequenced-event guard, not a lock.

-- GOTCHA: server is defensive (getCwd() ?? ""). The CLIENT must mirror — extract with per-field
-- type guards: serverVersion/cwd default to "", fdAvailable defaults to false unless literally
-- true, cwd falls back to desc.cwd (always present from the env descriptor).

-- GOTCHA: setting pi.bridge = M sets the MODULE table as the placeholder value (downstream calls
-- require("pi-editor").bridge.request(...) per PRD §7.7). Do NOT set it to a sub-table.
```

## Implementation Blueprint

### Data models and structure (Lua tables — no ORM/pydantic; this is a Neovim plugin)

```lua
-- ── Added to bridge.lua (module-level singleton state, all cleared in close()) ───────

--- Plugin version sent as hello's clientVersion (informational; server ignores it).
--- Mirrors package.json "version" + extension BRIDGE_VERSION ("0.1.0").
M.version = "0.1.0"

--- Server identity extracted from a successful hello result. nil until handshake succeeds,
--- nil again after close(). Read by downstream: completion uses .cwd (S30+), :checkhealth
--- uses all three (S42). Defensive: every field is type-checked on extraction.
---@class pi-editor.ServerInfo
---@field serverVersion string Bridge server version (default "" if absent/malformed).
---@field cwd string Session cwd (falls back to descriptor.cwd).
---@field fdAvailable boolean True only if result.fdAvailable == true.
---@type pi-editor.ServerInfo|nil
M.server_info = nil

--- In-flight handshake race-guard. Set by handshake(); cleared (pending=false) by the FIRST
--- resolver (response / timeout / close). Holds the caller callback + the luv timer so any
--- resolver can finalize exactly once and stop the timer.
---@class pi-editor.HandshakeState
---@field desc pi-editor.BridgeDescriptor The descriptor (has .path + .token).
---@field on_result fun(err:string?, info:pi-editor.ServerInfo?) Caller callback (exactly once).
---@field pending boolean False once any resolver has fired.
---@field timer userdata? luv timer for the handshake timeout (nil if not armed).
---@type pi-editor.HandshakeState|nil
local handshake_state = nil
```

### Implementation Tasks (ordered by dependencies)

```yaml
Task 1: ADD module state to plugin/lua/pi-editor/bridge.lua
  - ADD: `M.version = "0.1.0"` (top-level, near `local M = {}`).
  - ADD: `M.server_info = nil` (documented class pi-editor.ServerInfo — see Blueprint).
  - ADD: `local handshake_state = nil` (documented class pi-editor.HandshakeState).
  - CLEAR in M.close(): set `M.server_info = nil` and `handshake_state = nil` ALONGSIDE the
    existing state wipe (so a stale resolve cannot touch a re-used module across reconnect).
  - FOLLOW pattern: the existing `state = {...}` singleton + the `closed` shadow flag.
  - NAMING: snake_case for fields/locals; `M.` prefix for public; `local` for internal.
  - DEPENDENCIES: none (pure additions; no behavior change yet).
  - PLACEMENT: bridge.lua — state block right after `local state = {...}` / before `read_cb`.

Task 2: ADD the internal single-message dispatcher `dispatch(msg)` to bridge.lua
  - IMPLEMENT: a module-level `local function dispatch(msg)` that bridge.handshake passes as
    connect()'s `on_event`. Logic:
      if handshake_state and handshake_state.pending and msg.id == "h1" then
        resolve_handshake(msg)   -- validate + extract + callback + stop timer (Task 3)
      end
      -- ELSE: no-op today. DOCUMENTED S26 EXTENSION POINT: S26 adds `pending[msg.id]`
      -- lookup + supersession here; S27 adds a `msg.method=="commandsChanged"` branch.
  - GOTCHA: runs INLINE from the luv read_start cb (via jsonlreader.feed) — do NO vim.api
    work here (S24 GOTCHA 5). resolve_handshake does only Lua writes + M.send/M.close (luv-safe).
  - GOTCHA: check `msg.id == "h1"` with the LUA STRING "h1" (vim.json.decode yields strings).
  - DEPENDENCIES: Task 1 (handshake_state), Task 3 (resolve_handshake).

Task 3: ADD the resolver `resolve_handshake(msg_or_nil, err_or_nil)` to bridge.lua
  - IMPLEMENT: `local function resolve_handshake(msg, err)` — the SINGLE exit point. Guard:
      if not handshake_state or not handshake_state.pending then return end
      handshake_state.pending = false
      (stop+close handshake_state.timer if present)
      local cb, desc = handshake_state.on_result, handshake_state.desc
    Then branch on why:
      (a) TIMEOUT/CLOSE path (msg==nil, err~=nil): M.close(); cb(err or "connection closed
          during handshake"); (pi.bridge stays nil; M.server_info stays nil).
      (b) RESPONSE path (msg~=nil):
          if type(msg)=="table" and type(msg.result)=="table" and msg.result.ok == true then
            -- SUCCESS: defensive extract, set placeholders, cb(nil, info)
            local r = msg.result
            local info = {
              serverVersion = (type(r.serverVersion)=="string") and r.serverVersion or "",
              cwd           = (type(r.cwd)=="string") and r.cwd or (desc.cwd or ""),
              fdAvailable   = (r.fdAvailable == true),
            }
            M.server_info = info
            require("pi-editor").bridge = M   -- the placeholder S24 left nil
            cb(nil, info)
          else
            -- FAILURE: error object OR malformed result. Close + cb(err).
            local emsg
            if type(msg.error)=="table" then
              emsg = "handshake rejected"
              if type(msg.error.code)=="number" then emsg = emsg .. " (" .. msg.error.code .. ")" end
              -- NEVER include msg.error.message if it could echo a token; "bad token" is safe
              -- but keep it generic to avoid leaking any future server-side detail.
            else emsg = "handshake failed: malformed response" end
            M.close()
            cb(emsg)
          end
    - GOTCHA: require("pi-editor") inside resolve (lazy) — avoids an import cycle at module load.
    - GOTCHA: setting require("pi-editor").bridge = M is a pure Lua table write — safe in luv cb.
    - DEPENDENCIES: Task 1.

Task 4: ADD `M.handshake(desc, on_result)` to bridge.lua
  - IMPLEMENT: the public entry. Signature: handshake(desc, on_result) where
      desc: pi-editor.BridgeDescriptor (has .path, .token, .cwd)
      on_result: fun(err:string?, info:pi-editor.ServerInfo?) — called EXACTLY ONCE.
    Body:
      -- (a) validate descriptor UP FRONT — never touch luv on a bad descriptor
      if type(desc) ~= "table" or type(desc.path) ~= "string" or type(desc.token) ~= "string"
         or desc.token == "" then
        -- schedule the cb off the luv path? NO — caller is activate() (API context); call directly.
        on_result("invalid descriptor") return
      end
      -- (b) idempotent: tear down any prior handshake/connection first
      M.close()  -- clears handshake_state + server_info (Task 1)
      -- (c) arm the race-guard
      handshake_state = { desc = desc, on_result = on_result, pending = true, timer = nil }
      -- (d) arm the timeout (luv timer — NOT vim.defer_fn; see Gotchas)
      local timeout_ms = (require("pi-editor").config or require("pi-editor").defaults).rpc_timeout_ms or 2000
      local timer = uv.new_timer()
      handshake_state.timer = timer
      timer:start(timeout_ms, 0, vim.schedule_wrap(function()   -- schedule_wrap: timer cb -> nvim loop (safe; resolve is lua-only anyway)
        resolve_handshake(nil, "handshake timeout")
      end))
      -- (e) connect with the internal dispatcher as on_event
      M.connect(desc.path,
        function(connerr)  -- on_ready
          if connerr then resolve_handshake(nil, connerr) return end   -- ENOENT/ECONNREFUSED/EACCES
          -- transport connected (state.connected==true per S24): send hello
          M.send({ jsonrpc = "2.0", id = "h1", method = "hello",
            params = { token = desc.token, client = "pi-editor.nvim", clientVersion = M.version } })
        end,
        dispatch,  -- on_event (the Task 2 dispatcher)
        function(reason) resolve_handshake(nil, reason) end  -- on_close (silent server close / transport error)
      )
    - GOTCHA: wrap the timer:start / M.connect calls in pcall? M.connect already pcall-wraps its
      own luv calls (S24). uv.new_timer / timer:start can throw on programming error — wrap the
      whole body's luv touch in a pcall that routes throws to on_result (mirror S24's discipline).
    - GOTCHA: M.close() at step (b) sets handshake_state=nil, so re-arm at (c) is clean.
    - GOTCHA: on_result is called from on_ready(on connerr) / on_event / on_close / timer — all
      guarded by handshake_state.pending so exactly-once holds.
    - DEPENDENCIES: Tasks 1-3.

Task 5: WIRE handshake into plugin/lua/pi-editor/init.lua activate()
  - FIND: the `M.descriptor = desc` line (and the filetype set) in activate().
  - ADD (AFTER M.descriptor = desc, BEFORE or AFTER the filetype set — order is immaterial since
    handshake is async and the ftplugin does not need the connection):
      -- S25: connect + hello handshake (async). pcall so a bridge bug can NEVER break
      -- activation (the buffer still works as plain markdown). Silent on failure — the
      -- one-time vim.notify is task S39's job, NOT this task.
      pcall(function()
        local ok, br = pcall(require, "pi-editor.bridge")
        if ok and type(br.handshake) == "function" then
          br.handshake(desc, function(_err, _info) end)  -- no-op cb: bridge.lua sets pi.bridge internally
        end
      end)
  - PRESERVE: activate()'s "NEVER throws / NEVER notifies" contract (the outer pcall + the
    inner pcall(require) guarantee it). Do NOT add a vim.notify here.
  - GOTCHA: activate() runs in the VimEnter cb (API context) — calling handshake() (which calls
    uv.new_pipe etc.) is fine; luv is API-safe to call from the main loop.
  - DEPENDENCIES: Task 4.

Task 6: CREATE plugin/tests/bridge_handshake_spec.lua (plenary/busted — the Level-2 gate)
  - IMPLEMENT: a `with_hello_server(spec, opts)` helper that spins a REAL luv unix-socket
    server (unique path), decodes client requests via require("pi-editor.jsonlreader"), and
    behaves per opts.mode:
        "success"    — on hello with params.token==opts.token: reply HelloResult; keep open.
        "bad_token"  — on any hello: reply {id,err:{code:-32600,message:"bad token"}} THEN close.
        "malformed"  — on hello: reply {id:"h1"} (no result/error) THEN keep open.
        "silent"     — accept then close immediately (no reply).
        "slow"       — accept, never reply (for the timeout case).
    - Cases (mirror research/notes.md §7 — at minimum: success, bad_token, malformed, silent,
      connect-failure ENOENT, timeout, exactly-once race, invalid descriptor, never-throws).
    - FOLLOW pattern: plugin/tests/bridge_spec.lua's with_server() + vim.wait(250, predicate, 5).
    - NAMING: describe("pi-editor.bridge handshake", …); it("…", with_hello_server(function(path, …, stop) … end)).
    - COVERAGE: every Success Criterion checkbox above has a matching `it`.
    - PLACEMENT: plugin/tests/ (alongside bridge_spec.lua).
    - GOTCHA: reset module state between cases — call bridge.close() in each stop() AND in a
      before_each/after_each (handshake_state / server_info / pi.bridge must not leak across tests).
      Set require("pi-editor").bridge = nil in cleanup if a prior success case populated it.
    - DEPENDENCIES: Tasks 1-5.

Task 7: MODIFY plugin/tests/smoke.lua — dormant-session assertion
  - ADD (near the existing `pi.bridge == nil` check): assert that WITHOUT the PI_EDITOR_BRIDGE
    env var, calling activate() (or just not calling handshake) leaves pi.bridge == nil. This
    guards against S25 accidentally setting pi.bridge in a non-pi session.
  - FOLLOW pattern: the existing `check(cond, msg)` + cquit-on-fail.
  - PRESERVE: all existing smoke assertions.
  - DEPENDENCIES: Task 5.
```

### Implementation Patterns & Key Details

```lua
-- === The handshake envelope (EXACT — sent inside on_ready) =========================
-- The id is the LITERAL "h1" (PRD §5.3 example; server echoes it; client correlates on it).
M.send({
  jsonrpc   = "2.0",
  id        = "h1",
  method    = "hello",
  params    = { token = desc.token, client = "pi-editor.nvim", clientVersion = M.version },
})
-- M.send frames this as vim.json.encode(obj) .. "\n" (S24 GOTCHA 11).

-- === The resolver: the SINGLE exit point (race-safe) ===============================
local function resolve_handshake(msg, err)
  if not handshake_state or not handshake_state.pending then return end  -- EXACTLY ONCE guard
  handshake_state.pending = false
  if handshake_state.timer then
    pcall(function() handshake_state.timer:stop() end)
    pcall(function() handshake_state.timer:close() end)
  end
  local cb, desc = handshake_state.on_result, handshake_state.desc

  if msg == nil then                                   -- (a) TIMEOUT or CLOSE path
    M.close()                                          -- idempotent (S24 GOTCHA 2)
    cb(err or "connection closed during handshake")
    return
  end

  if type(msg) == "table" and type(msg.result) == "table" and msg.result.ok == true then
    local r = msg.result                               -- (b) SUCCESS — defensive extract
    local info = {
      serverVersion = (type(r.serverVersion) == "string") and r.serverVersion or "",
      cwd           = (type(r.cwd) == "string") and r.cwd or (desc.cwd or ""),
      fdAvailable   = (r.fdAvailable == true),
    }
    M.server_info = info
    require("pi-editor").bridge = M                    -- publish (pure Lua write; luv-safe)
    cb(nil, info)
  else                                                 -- (c) FAILURE — error obj or malformed
    local emsg = "handshake failed"
    if type(msg.error) == "table" and type(msg.error.code) == "number" then
      emsg = "handshake rejected (" .. msg.error.code .. ")"   -- NEVER the token; code is safe
    elseif type(msg.error) == "table" then
      emsg = "handshake rejected"
    elseif type(msg) ~= "table" or msg.id ~= "h1" then
      emsg = "handshake failed: malformed response"
    end
    M.close()
    cb(emsg)
  end
end

-- === The dispatcher: the single on_event (S26/S27 extension point) =================
local function dispatch(msg)
  if handshake_state and handshake_state.pending and msg and msg.id == "h1" then
    resolve_handshake(msg, nil)
    return
  end
  -- S26 EXTENSION POINT: add `if pending[msg.id] then ... end` here.
  -- S27 EXTENSION POINT: add `if msg.method == "commandsChanged" then ... end` here.
end

-- === The public entry =============================================================
function M.handshake(desc, on_result)
  -- (1) validate UP FRONT — never touch luv on a bad descriptor (never-throws contract)
  if type(desc) ~= "table" or type(desc.path) ~= "string" or type(desc.token) ~= "string"
     or desc.token == "" or type(on_result) ~= "function" then
    on_result("invalid descriptor")
    return
  end
  -- (2) pcall the luv setup so a programming error degrades via on_result (S24 discipline)
  local ok, setup_err = pcall(function()
    M.close()  -- idempotent; clears any prior handshake_state/server_info
    handshake_state = { desc = desc, on_result = on_result, pending = true, timer = nil }
    local cfg = require("pi-editor")
    local timeout_ms = ((cfg.config or cfg.defaults or {}).rpc_timeout_ms) or 2000
    local timer = uv.new_timer()
    handshake_state.timer = timer
    timer:start(timeout_ms, 0, vim.schedule_wrap(function()
      resolve_handshake(nil, "handshake timeout")
    end))
    M.connect(desc.path,
      function(connerr)
        if connerr then resolve_handshake(nil, connerr); return end   -- ENOENT/ECONNREFUSED/EACCES
        M.send({ jsonrpc = "2.0", id = "h1", method = "hello",
          params = { token = desc.token, client = "pi-editor.nvim", clientVersion = M.version } })
      end,
      dispatch,
      function(reason) resolve_handshake(nil, reason) end)
  end)
  if not ok then
    M.close()
    on_result("handshake setup error: " .. tostring(setup_err))
  end
end
```

### Integration Points

```yaml
MODULE STATE (bridge.lua):
  - add: "M.version = '0.1.0'"           # informational clientVersion (mirrors package.json + BRIDGE_VERSION)
  - add: "M.server_info = nil"           # populated only on a successful hello
  - add: "local handshake_state = nil"   # the exactly-once race-guard
  - clear in M.close(): "M.server_info = nil; handshake_state = nil"  # alongside existing state wipe

PUBLIC API (bridge.lua):
  - add: "M.handshake(desc, on_result)"  # the first protocol consumer of the S24 transport

ACTIVATION (init.lua):
  - modify: "activate()" — pcall(bridge.handshake, desc, noop_cb) after M.descriptor = desc
  - preserve: "NEVER throws / NEVER notifies" contract (notify is S39)

PLUGIN SURFACE (for downstream — PRD §7.7):
  - require("pi-editor").bridge  # nil until handshake success; then the bridge module
                                 # (blink/cmp sources + user code call .request/.send on it)

CONFIG (already exists — S19):
  - read: "config.rpc_timeout_ms" (default 2000)  # the handshake timeout; no new option needed

NO NEW DEPENDENCIES:
  - only vim.uv (luv) + vim.json + the S23 jsonlreader — all built into Neovim 0.10+ (0.12 verified)
```

## Validation Loop

### Level 1: Syntax & Style (Immediate Feedback)

```bash
# Lua is interpreted at load — a syntax error breaks the WHOLE plugin. Load-check every edit.
cd plugin && nvim --headless --clean -u NORC \
  -c 'luafile lua/pi-editor/bridge.lua' \
  -c 'luafile lua/pi-editor/init.lua' \
  -c 'qa' ; echo "load-exit=$?"   # expect 0

# luacheck (if installed — the repo currently has NO selene/stylua config; PRD §9.2 lists them
# as optional/future). If luacheck is available, run it for unused-var / globals hygiene:
luacheck lua/pi-editor/bridge.lua lua/pi-editor/init.lua --std luajit 2>/dev/null || true

#stylua (optional formatting — no config yet; skip unless the repo adopts stylua.toml):
#stylua --check lua/pi-editor/bridge.lua lua/pi-editor/init.lua tests/bridge_handshake_spec.lua 2>/dev/null || true
# Expected: load-exit 0; lint clean (or skipped). If load fails, READ the nvim stderr and fix.
```

### Level 2: Unit Tests (Component Validation — the formal gate)

```bash
# The NEW handshake spec (real luv socket server; every Success Criterion case):
cd plugin && nvim --headless --clean -u tests/minimal_init.lua \
  -c 'lua require("plenary.busted").run("tests/bridge_handshake_spec.lua")' \
  -c 'qa' ; echo "handshake-exit=$?"
# Expected: Success N / Failed 0 / Errors 0.

# REGRESSION — the S24 transport spec MUST still pass (connect()'s signature is unchanged):
cd plugin && nvim --headless --clean -u tests/minimal_init.lua \
  -c 'lua require("plenary.busted").run("tests/bridge_spec.lua")' \
  -c 'qa' ; echo "bridge-exit=$?"   # expect Success 11 / Failed 0

# REGRESSION — the S23 jsonlreader spec (unchanged):
cd plugin && nvim --headless --clean -u tests/minimal_init.lua \
  -c 'lua require("plenary.busted").run("tests/jsonlreader_spec.lua")' \
  -c 'qa' ; echo "jsonlreader-exit=$?"

# The zero-dependency smoke (dormant-session + setup() invariants):
cd plugin && nvim --headless --clean -u NORC +"luafile tests/smoke.lua" +qa ; echo "smoke-exit=$?"
# Expected: stdout "SMOKE_PASS", exit 0.
```

### Level 3: Integration Testing (System Validation)

```bash
# End-to-end: a REAL bridge server (the DONE extension) + a headless nvim handshake.
# 1. Start pi with the bridge extension in RPC/print mode so the socket server is up and the
#    PI_EDITOR_BRIDGE env var is set in pi's process. (Manual / scripted — see extension README.)
# 2. From that pi process's env, launch headless nvim on a temp pi-editor file and assert the
#    handshake completed:
TMP=$(mktemp --suffix=.pi.md); echo "hello world" > "$TMP"
PI_EDITOR_BRIDGE='<descriptor-from-pi>' nvim --headless --clean -u plugin/tests/minimal_init.lua \
  +"luafile plugin/plugin/pi-editor.lua" \
  -c 'lua vim.defer_fn(function()
        local pi=require(\"pi-editor\")
        assert(pi.bridge ~= nil, \"handshake did not set pi.bridge\")
        assert(pi.bridge.server_info ~= nil, \"server_info missing\")
        print(\"E2E_OK \" .. tostring(pi.bridge.server_info.serverVersion))
        vim.cmd(\"qa\")
      end, 500)' \
  "$TMP" ; echo "e2e-exit=$?"
# Expected: stdout "E2E_OK 0.1.0", exit 0. (The 500ms defer lets the async handshake complete.)

# NEGATIVE e2e — a deliberately WRONG token must leave pi.bridge nil and NOT crash:
PI_EDITOR_BRIDGE='{"transport":"unix","path":"/tmp/<real-socket>","token":"WRONG","pid":1,"cwd":"/tmp","fdAvailable":false,"serverVersion":"0.1.0"}' \
  nvim --headless --clean -u plugin/tests/minimal_init.lua +"luafile plugin/plugin/pi-editor.lua" \
  -c 'lua vim.defer_fn(function()
        local pi=require(\"pi-editor\")
        assert(pi.bridge == nil, \"bad-token handshake must NOT set pi.bridge\")
        print(\"NEG_OK\"); vim.cmd(\"qa\")
      end, 500)' ; echo "neg-exit=$?"
# Expected: "NEG_OK", exit 0.
```

### Level 4: Creative & Domain-Specific Validation

```bash
# Race-safety stress: hammer handshake() repeatedly against a slow server; assert on_result
# fires EXACTLY ONCE per call (never 0, never 2). Drive via a small plenary case that counts
# callbacks. (Covered by bridge_handshake_spec.lua case "on_result fires exactly once".)

# :checkhealth stub (the FULL health module is S42; here just confirm bridge.server_info is
# populated after a successful handshake so S42 can read it):
nvim --headless --clean -u plugin/tests/minimal_init.lua \
  -c 'lua require("plenary.busted").run("tests/bridge_handshake_spec.lua")' -c 'qa'

# (selene + stylua CI — OPTIONAL; the repo has no config yet. If adopted later, add a
# .github/workflows per PRD §9.2. Not blocking for this task.)
```

## Final Validation Checklist

### Technical Validation
- [ ] Level 1 load-check: both edited `.lua` files load with exit 0.
- [ ] Level 2: `bridge_handshake_spec.lua` → Success N / Failed 0 / Errors 0.
- [ ] Level 2 REGRESSION: `bridge_spec.lua` → Success 11 / Failed 0 (unchanged).
- [ ] Level 2 REGRESSION: `jsonlreader_spec.lua` → all green (unchanged).
- [ ] Level 2: `smoke.lua` → `SMOKE_PASS`, exit 0 (incl. the new dormant-session assertion).

### Feature Validation
- [ ] Every Success Criterion checkbox in §What is covered by a spec case.
- [ ] E2E (Level 3): real bridge server → `pi.bridge ~= nil` + `server_info.serverVersion == "0.1.0"`.
- [ ] Negative E2E (Level 3): wrong token → `pi.bridge == nil`, no crash.
- [ ] Bad token / malformed / silent-close / connect-failure / timeout each leave `pi.bridge == nil`.
- [ ] `on_result` fires EXACTLY ONCE in every case (incl. the response+timeout race).
- [ ] No exception escapes `handshake()` or `activate()` (both pcall-guarded).

### Code Quality Validation
- [ ] `connect()` public signature UNCHANGED (handshake is an added caller, not a refactor).
- [ ] bridge.lua stays pure `vim.uv` + `vim.json` + jsonlreader (no new runtime deps; no `vim.api` from luv cbs).
- [ ] The dispatcher has a documented S26/S27 extension point (single `on_event`, not a fork).
- [ ] The token value NEVER appears in any error string / notify / log (PRD §12).
- [ ] Module state (`handshake_state`, `M.server_info`) is cleared in `M.close()` (no leak across reconnects).
- [ ] Field naming matches the repo (`snake_case`, `M.` public, `local` internal; matches jsonlreader/bridge style).

### Documentation & Deployment
- [ ] bridge.lua gains a `[Mode A]`-style header update noting S25 adds handshake + the S26/S27 dispatch seam.
- [ ] init.lua `activate()` docstring updated: notes it now kicks off the (pcall'd, silent) handshake.
- [ ] No new env vars / config options introduced (reuses `rpc_timeout_ms`).

---

## Anti-Patterns to Avoid

- ❌ Don't reimplement the transport — `handshake()` CALLS the S24 `connect()`/`send()`/`close()`. Duplicating pipe logic forks the singleton and breaks S26.
- ❌ Don't change `connect()`'s signature — the S24 spec and its regression tests depend on it. handshake() passes its OWN on_event.
- ❌ Don't use `vim.defer_fn` for the timeout — bridge.lua is pure `vim.uv` (S24 GOTCHA 5). Use `uv.new_timer`.
- ❌ Don't resolve `on_result` more than once — the `handshake_state.pending` guard is load-bearing; every resolver (response/timeout/close) checks-and-clears it first.
- ❌ Don't set `pi.bridge` before validating `result.ok == true` — a malformed/error response must leave it `nil`.
- ❌ Don't put the token value in any message — the server says literal "bad token"; the client must never echo `desc.token`.
- ❌ Don't add `vim.notify` on failure here — that is task S39 (PRD §11). S25 degrades silently.
- ❌ Don't build the generic `pending` map / `request()` — that is S26. S25 adds only the dispatch SEAM (one function, one `id=="h1"` branch) S26 extends.
- ❌ Don't `vim.schedule` the resolve path's pure-Lua writes — they're luv-safe (table assignment + M.send/M.close). (Timer cb uses `vim.schedule_wrap` only because timer cbs are a separate luv callback category; it's belt-and-suspenders.)
- ❌ Don't catch-all `pcall` around `resolve_handshake` internals and swallow — if resolve throws, that's a bug to surface; the exactly-once guard + defensive extraction should make it throw-free by construction.

---

## Confidence Score: 9/10

**Why 9, not 10:** every contract is pinned to a DONE, tested source file (server hello
handler, S24 transport, wire types, the plenary test pattern). The design is the lowest-risk
extension of the existing module (added function + added caller of connect(); no signature
change; singleton dispatcher structured for S26). The one residual uncertainty is the
exactly-once race across the luv timer cb vs the read_start cb vs on_close — mitigated by the
`handshake_state.pending` flag (sequenced-event guard on a single-threaded loop) and an
explicit spec case that asserts the count. If the E2E (Level 3) reveals a timing flake, the
fix is mechanical (the guard already centralizes it).

**Implementer's fastest path:** read `research/notes.md` §1-3 (the wire exchange + the
race-safety rule), then implement Tasks 1-4 by pasting the Blueprint code into bridge.lua,
then Task 5 (3-line pcall in activate), then Task 6 (copy `bridge_spec.lua`'s `with_server`
and add the `opts.mode` server behaviors). Run the Level-2 gates.