---
name: "P2.M5.T16.S27 — Notification handler for commandsChanged (Neovim client)"
description: >
  Add the THIRD protocol consumer to the pi-editor.nvim bridge client
  (`plugin/lua/pi-editor/bridge.lua`): a notification dispatch branch + a public
  `on_notification(method, handler)` registration API so a server→client `commandsChanged`
  notification (JSON-RPC 2.0: a message with `method` and NO `id`) routes to a handler the
  caller registered. This EXTENDS the existing single `dispatch(msg)` (the S25 handshake
  `id=="h1"` branch + the S26 `pending[msg.id]` request-response branch) with ONE branch at
  the literal `-- S27 EXTENSION POINT` placeholder. Handlers are stored
  `vim.schedule_wrap`'d (the dispatch runs inline from the luv `read_start` callback —
  GOTCHA 5; raw `vim.api.*` throws `E5560` there). The cache-invalidation BEHAVIOR that
  consumes this API is a LATER task (P3.M10.T26.S41 "Clear caches and re-query on
  commandsChanged"); S27 ships only the MECHANISM. No public-signature change to
  `connect()`/`send()`/`handshake()`/`request()` — `on_notification` is ADDED, and the
  dispatcher gains one branch. `protocol.ts` is UNCHANGED (`commandsChanged` is already the
  only `NotificationMethod`; empty params already omitted on the wire by the S17 server).
---

# Goal

**Feature Goal**: Complete the client half of the bridge's ONE server→client notification
(`commandsChanged`, PRD §5.4). Extend `bridge.lua`'s singleton `dispatch(msg)` with a
notification branch: when a decoded JSON-RPC message has a string `method` and NO string
`id` (JSON-RPC §4 "Notification"), look up a registered handler by method and invoke it
(safely, on the next nvim loop pass). Expose `M.on_notification(method, handler)` so
downstream code (S41 cache invalidation; future notification consumers) can register/replace/
remove a handler without touching the transport. The wire input is EXACTLY
`{"jsonrpc":"2.0","method":"commandsChanged"}` — no `id`, no `params` (the S17 server omits
empty params) — and the client MUST NOT reply (JSON-RPC: a notification expects no response).

**Deliverable**:
1. New module state in `plugin/lua/pi-editor/bridge.lua`: a `notification_handlers` map
   (`method → schedule_wrap'd handler`), documented as a `pi-editor.NotificationHandler` pattern.
2. A public `M.on_notification(method, handler)` registration API (last-wins; `nil` removes;
   never throws; validates args).
3. An EXTENDED `dispatch(msg)` (ONE added branch at the existing `-- S27 EXTENSION POINT`
   placeholder, AFTER the S25 handshake branch and the S26 request-response branch).
4. A `M.close()` extension that clears the registry (no stale handler across reconnects).
5. A `[Mode A]` header note documenting S27 (the notification seam + the `on_notification` API
   + the close() clear).
6. A plenary/busted spec `plugin/tests/bridge_notify_spec.lua` (real luv socket server;
   reuses the `with_request_server`/`with_handshaken_server` HOF from S26's spec).

**Success Definition**:
- A registered handler is invoked (on the next nvim loop pass) when the server sends a
  `commandsChanged` notification, with `params == nil` (empty params omitted on the wire).
- The client sends NO response to a notification (JSON-RPC §4 "MUST NOT reply") — the server's
  request-decoder sees only `hello`.
- The handler runs safely from luv fast context (schedule_wrap'd; a handler that touches
  `vim.api.*` does NOT throw `E5560`).
- A notification does NOT interfere with an in-flight request: a `getSuggestions` outstanding,
  the server sends `commandsChanged`, then replies — BOTH the handler fires AND the request cb
  resolves with its own result (independent dispatch paths).
- Last-wins re-registration replaces the handler (no leak); `on_notification(method, nil)`
  removes it; a notification with no registered handler is SILENTLY DROPPED (no throw — PRD §11).
- `close()` clears the registry (a stale handler does not fire across reconnects).
- `on_notification()` NEVER throws on bad args (non-string method, non-function handler).
- A message with `method` AND a string `id` (a server "request" shape not sent in v1) is NOT
  mis-routed to the notification handler (dropped by the `type(msg.id)~="string"` guard).
- The S24 transport, S23 jsonlreader, S25 handshake, S26 request, and `smoke.lua` specs all
  pass UNCHANGED (`dispatch` only gains a branch; `on_notification` is ADDED).

## User Persona

**Target User**: The downstream completion module (`plugin/lua/pi-editor/completion.lua`,
S30+) and, specifically, the P3.M10.T26.S41 cache-invalidation behavior. S41 registers a
handler via `require("pi-editor").bridge.on_notification("commandsChanged", function(_params)
clear_command_cache() end)` once the handshake publishes `pi.bridge`. Secondary: any future
notification consumer (the `method → handler` registry is generic; `commandsChanged` is the
only notification today).

**Use Case**: pi rebuilds its autocomplete provider on `session_start {reason:"reload"}` (and
`new`/`resume`/`fork`) and — per the DONE S17 server task — broadcasts `commandsChanged` to
every handshaken connected editor. The Neovim plugin must receive that signal and (in S41)
drop its cached command list so the next `getSuggestions`/`getCommands` reflects the new
provider. S27 provides the dispatch + registration primitive S41 keys on; it ships no
behavior itself.

**User Journey**: handshake ok → `pi.bridge` live → S41 registers a `commandsChanged` handler
→ user triggers a pi provider rebuild (e.g. `/reload`) → server broadcasts
`{"jsonrpc":"2.0","method":"commandsChanged"}` → `dispatch` → notification branch →
`notification_handlers["commandsChanged"](params)` → (deferred to next nvim loop pass) S41
clears its cache → next keystroke's `getSuggestions` re-queries pi.

**Pain Points Addressed**: Without `on_notification`, a notification would fall off the end of
`dispatch` and be silently dropped forever — S41 would have no clean seam to receive the
signal (it would have to monkeypatch `dispatch` or poll `getCommands`). A single, tested,
generic notification registry (mirroring S26's `pending` map) is the foundation every
notification consumer keys on.

## Why

- **The dispatch seam already exists (S26).** `bridge.lua:dispatch(msg)` ends with the literal
  comment `-- S27 EXTENSION POINT: notifications (commandsChanged) go here.` right after the
  `pending[msg.id]` request-response branch. S27 fills that one branch — no refactor, no new module.
- **Completes the protocol surface.** `commandsChanged` is the only `NotificationMethod` in
  `protocol.ts` (§D). The server half is DONE (S17 — `broadcastNotification`). Until S27, the
  client silently drops it. This task closes the loop end-to-end (the S17 REAL test proves the
  server emits the exact line S27 consumes).
- **Foundation for S41 (cache invalidation).** S41 ("Clear caches and re-query on
  commandsChanged") is the BEHAVIOR; S27 is the MECHANISM. Splitting them keeps each task
  small and independently testable — S27's spec needs no completion/menu code, and S41's spec
  needs no transport/dispatch changes.
- **Correctness over convenience.** A naive "notifications always arrive at a safe moment"
  assumption is wrong: the server may broadcast BETWEEN a `getSuggestions` request and its
  response (§7 of the research). Because the handler is `schedule_wrap`'d and the branch
  ordering separates notifications (no id) from responses (id), the two dispatch paths are
  fully independent — verified by an interleaving spec case.
- **Resource/safety hygiene.** Handlers are user closures stored in a module-level map;
  `close()` clears it (defense-in-depth, matching S26's "no leak across editor open/close
  cycles" — PRD §6.7) so a stale handler cannot fire across reconnects even though S41
  re-registers after each handshake.

## What

User-visible: nothing directly (this is a library layer beneath completion). The observable
effect is that `require("pi-editor").bridge` gains an `on_notification` method once the S25
handshake publishes it; a dormant session (no `PI_EDITOR_BRIDGE`) still has `pi.bridge == nil`
and never touches this code.

Technical requirements:
- `dispatch(msg)`: AFTER the `id=="h1"` handshake branch and AFTER the `type(msg.id)=="string"`
  request-response branch, add: if `msg` is a table with a string `method` and NO string `id`
  (a JSON-RPC notification), look up `notification_handlers[msg.method]`; if present, call it
  with `msg.params` (nil for `commandsChanged`); else silently drop. NEVER `M.send` a reply.
- `M.on_notification(method, handler)`: validate `method` is a non-empty string and `handler`
  is a function (never throws); store `vim.schedule_wrap(handler)` under `method` (last-wins);
  `handler == nil` removes the entry.
- `M.close()`: clear `notification_handlers = {}` alongside the existing `pending` drain +
  `next_id` reset + `server_info` clear.
- The handler is stored `schedule_wrap`'d at REGISTRATION time (so dispatch — which runs inline
  from the luv `read_start` callback — can call it safely; the user's `vim.api.*` work is
  deferred to the next nvim loop pass — GOTCHA 5).

### Success Criteria

- [ ] `bridge.on_notification` exists and is a function.
- [ ] `on_notification("commandsChanged", handler)` registers a handler; a subsequent
      `commandsChanged` notification invokes it with `params == nil` (empty params omitted on the wire).
- [ ] The handler runs on the next nvim loop pass (schedule_wrap'd) — a handler body that calls
      `vim.api.*` does NOT throw `E5560` (verified by an indirect spec case).
- [ ] The client sends NO response to a notification — the server's request-decoder sees only
      `hello` (JSON-RPC §4 "MUST NOT reply").
- [ ] The exact input the branch consumes is `{"jsonrpc":"2.0","method":"commandsChanged"}`
      (no `id`, no `params`) — the spec writes the raw line to assert the wire form.
- [ ] Last-wins re-registration: registering handler B for a method that already had handler A
      causes ONLY B to fire (A is replaced, not leaked).
- [ ] `on_notification(method, nil)` removes the handler; a subsequent notification is dropped
      with no throw.
- [ ] A notification with NO registered handler is SILENTLY DROPPED (no throw, no cb — PRD §11).
- [ ] Interleaving: a `getSuggestions` request outstanding; server sends `commandsChanged` THEN
      the `getSuggestions` response; BOTH the handler fires AND the request cb resolves with its
      own result (independent dispatch paths).
- [ ] `close()` clears the registry: after close + re-handshake WITHOUT re-registering, the OLD
      handler does NOT fire (no leak across reconnects).
- [ ] `on_notification()` NEVER throws on bad args (non-string method, empty method,
      non-function handler).
- [ ] A message with `method` AND a string `id` (a server "request" shape not sent in v1) is NOT
      mis-routed to the notification handler (dropped by the `type(msg.id)~="string"` guard).
- [ ] The notification branch is GENERIC: a synthetic method routes to ITS own handler
      (forward-compat; `commandsChanged` is the only real one today).
- [ ] REGRESSION: `bridge_handshake_spec.lua` (S25), `bridge_request_spec.lua` (S26),
      `bridge_spec.lua` (S24), `jsonlreader_spec.lua` (S23), and `smoke.lua` all pass UNCHANGED.

## All Needed Context

### Context Completeness Check

> "If someone knew nothing about this codebase, would they have everything needed to implement this successfully?"

Yes — this PRP quotes the exact wire input (`{"jsonrpc":"2.0","method":"commandsChanged"}`,
verified against the DONE S17 server test), pins the dispatch seam to the literal `-- S27
EXTENSION POINT` comment with the surrounding code, specifies the `schedule_wrap`/luv-fast-context
rule (LIVE-VERIFIED against Neovim 0.12 + nvim's own `vim/lsp/rpc.lua`), gives the
copy-pasteable `on_notification`/dispatch/close code, and hands off the real-socket test pattern
(reuse S26's `with_request_server`/`with_handshaken_server`). The implementer needs only Neovim +
`vim.uv`/`vim.json`/`vim.schedule_wrap` knowledge (all built-in) and the paths below.

### Documentation & References

```yaml
# MUST READ — the contracts this task consumes / extends (all DONE, read before editing)
- file: plugin/lua/pi-editor/bridge.lua
  why: The module to EXTEND (not replace). Holds the S24 transport (connect/send/close/on_exit/
    is_connected, GOTCHAs 1-12) + the S25 handshake (handshake/resolve_handshake/dispatch +
    handshake_state/M.server_info) + the S26 request layer (request/cancel/resolve_request/pending/
    next_id). The dispatch SEAM is at the END of `dispatch = function(msg)`: after the `id=="h1"`
    handshake branch and the `type(msg.id)=="string"` + `pending[msg.id]` request-response branch,
    there is the literal comment `-- S27 EXTENSION POINT: notifications (commandsChanged) go here.`
    S27 adds ONE branch there. M.close() (~L453-481) is the clear target (alongside the S26 pending
    drain + next_id reset).
  pattern: module-level singleton state (a `local` table read as an upvalue by `dispatch`); the
    exactly-once pattern S26 used for `pending[id]` (delete-on-resolve) — S27 needs no "resolve"
    (notifications have no id/result), just a `method → handler` registry cleared in close().
  gotcha: connect()/send()/handshake()/request()/cancel() PUBLIC SIGNATURES MUST NOT CHANGE —
    on_notification is ADDED. GOTCHA 5 (NO vim.api from luv cbs → store schedule_wrap(handler)).
    GOTCHA 10 (SINGLETON — one on_event per session; the notification branch shares dispatch with
    handshake + request). GOTCHA 2 (double-close safe; close() is idempotent).

- file: extension/connection.ts
  why: handleLine() proves the server distinguishes NOTIFICATIONS (no string id → NEVER writes a
    response) from REQUESTS (string id → always writes a response). So the client MUST NOT send a
    reply to `commandsChanged` (JSON-RPC §4). Also: broadcastNotification() filters on
    state.handshakeComplete (PRD §12) → the client only ever receives `commandsChanged` AFTER its
    own `hello` succeeded (dispatch is live; pi.bridge == bridge).
  gotcha: a notification has NO `id`; the client dispatch must distinguish it from a response
    (which HAS a string id) — use `type(msg.id) ~= "string"` as the notification guard.

- file: extension/protocol.ts
  why: The wire TYPES. `commandsChanged` is the ONLY NotificationMethod (§D: `Exclude`-d from
    RequestMethod; omitted from BridgeResultMap). CommandsChangedParams = Record<string, never>
    (empty). So on the wire it is `{"jsonrpc":"2.0","method":"commandsChanged"}` — NO params key
    (the S17 server omits empty params). After vim.json.decode, `msg.params == nil` (absent).
  gotcha: a message with BOTH `method` AND a string `id` is a REQUEST (not a notification). The
    bridge's RequestMethod is C→S only in v1 (the server never sends a request to the client), so
    such a message is malformed-from-the-client's-POV and must be DROPPED, not routed to the handler.
    The `type(msg.id) ~= "string"` guard defends this.

- file: extension/tests/commands-changed-notification.test.ts
  why: The server contract — the EXACT line the client receives. Its REAL test asserts:
    `parsed.jsonrpc == "2.0"`, `parsed.method == "commandsChanged"`, `!("id" in parsed)`
    (notification has no id), `!("params" in parsed)` (empty params OMITTED on the wire), and the
    line does NOT contain the token (security). Mirror these exact properties in the Lua spec's
    raw notification line.
  gotcha: write the server's notification line as the RAW string
    `'{"jsonrpc":"2.0","method":"commandsChanged"}\n'` in the Lua spec — do NOT build it with
    `vim.json.encode({params={}})` (that would emit `"params":{}`, which the real server does NOT).

- file: plugin/tests/bridge_request_spec.lua
  why: The CLOSEST sibling spec (the S26 gate) + the test PATTERN to reuse. Its `with_request_server(
    opts, spec)` + `with_handshaken_server(server_opts, spec)` HOFs spin a REAL luv unix-socket
    server (unique path), do `hello`, and decode client writes via the S23 jsonlreader. Add a server
    mode `"notify"` that writes a `commandsChanged` line after handshake. Its `reset_module()` (close
    + nil pi.bridge) is the reset pattern — S27's close() clearing the registry makes it sufficient.
  pattern: vim.wait(budget, predicate_fn, 5) — the 5ms poll is load-bearing; unique socket path per
    case; stop() closes server+conn and calls bridge.close().
  gotcha: do NOT name a spec-local table `pending` (shadows plenary.busted's global skip fn). Use
    `got`/`fired`/`results` locals to observe behavior.

- file: plugin/tests/bridge_handshake_spec.lua
  why: The S25 gate — confirms `dispatch` routes `id=="h1"` first. S27's regression run proves the
    notification branch (added LAST) does not swallow handshake responses (notifications have no id,
    so they never match the `id=="h1"` guard).

- file: plugin/lua/pi-editor/init.lua
  why: `M.bridge` is the placeholder S25 sets to the bridge module on handshake success; on_notification
    lives ON that module so `require("pi-editor").bridge.on_notification(...)` works (the contract S41
    / blink-cmp / nvim-cmp sources call — PRD §7.7). `config` holds `rpc_timeout_ms` (S27 does NOT
    read it — notifications have no timeout; but it is the shared config object).
  gotcha: NO change to init.lua in this task — on_notification is called by completion (S41), not
    wired into activate().

- file: plugin/tests/minimal_init.lua
  why: The plenary harness bootstrap (prepends plenary + appends plugin root). plenary at
    /home/dustin/.local/share/nvim/lazy/plenary.nvim (verified by S26 research).

- docfile: plan/001_c56962b4fa17/P2M5T16S27/research/notes.md
  why: Consolidated deep-dive: the exact wire form (§1, verified against S17), the dispatch seam +
    branch-ordering truth table (§2), JSON-RPC notification authority (§3), the schedule_wrap/luv
    fast-context rule (§4), the on_notification API design (§5), close() hygiene (§6), the
    interleaving guarantee (§7), and the 13-case test matrix (§8).
  section: §1 (wire form), §2 (dispatch ordering), §4 (schedule_wrap), §5 (API design), §8 (test matrix).

- docfile: plan/001_c56962b4fa17/P2M5T16S26/PRP.md
  why: The sibling PRP that established the S26 request layer. Its two-layer design
    (transport `pending` MAP + caller supersession) and the exactly-once-via-delete + schedule_wrap
    conventions are the patterns S27 mirrors for notifications. Read its "Known Gotchas" +
    "Anti-Patterns" sections (especially the schedule_wrap-from-luv and the singleton-dispatch rules).
  section: "Known Gotchas of our codebase & Library Quirks", "Implementation Patterns & Key Details".

- url: https://www.jsonrpc.org/specification#notification
  why: The authority for notification semantics: "A Notification is a Request object without an `id`
    member. The Server MUST NOT reply to a Notification." → the client MUST NOT `M.send` a response to
    `commandsChanged`, and the dispatch must distinguish notifications (no id) from responses (id).
  critical: the client never replies to a notification; `M.send` appears NOWHERE in the S27 branch.

- url: https://www.jsonrpc.org/specification#request_object
  why: §4 — id is String|Number|NULL; a message WITHOUT an `id` key is a notification. S27 distinguishes
    via `type(msg.id) ~= "string"` (an absent key decodes to `nil`, which is not a string). Also: a
    message with BOTH `method` and a string `id` is a REQUEST (the bridge's are C→S only in v1) — must
    NOT be routed to the notification handler.
  critical: the `type(msg.id) ~= "string"` guard is load-bearing — it prevents a (v1-impossible but
    defensive) server "request" from firing a notification handler.

- url: https://neovim.io/doc/user/api/ (search: lua-loop-callbacks / vim.in_fast_event)
  why: luv `read_start` callbacks run in "fast"/libuv context where `vim.api.*` throws `E5560: … must
    not be called in a lua loop callback`. `dispatch` runs INLINE from read_start (via jsonlreader.feed
    → on_event) → the handler MUST be invoked via `vim.schedule_wrap` (deferred to the next nvim
    main-loop pass). Confirmed by neovim/neovim#21052/#31199 and production precedent in
    `/usr/share/nvim/runtime/lua/vim/lsp/rpc.lua` (stores schedule_wrap(cb) for the same reason).
  critical: store `vim.schedule_wrap(handler)` at REGISTRATION time (in on_notification, which runs on
    the nvim main loop) — NOT at dispatch time (the user closure is fixed once registered).
```

### Current Codebase tree (the plugin edit surface)

```bash
plugin/
  lua/pi-editor/
    init.lua          # setup()/defaults/activate() (S21) — M.bridge placeholder. UNCHANGED.
    bridge.lua        # S24 transport + S25 handshake + S26 request — EXTEND (this task):
                      #   +notification_handlers map, +M.on_notification, +dispatch notification branch,
                      #   +close() registry clear, +[Mode A] header note.
    jsonlreader.lua   # S23 (DONE) — feeds decoded tables to on_event. UNCHANGED.
  plugin/pi-editor.lua   # VimEnter shim (S20) — UNCHANGED.
  ftplugin/pi-prompt.lua # S22 — UNCHANGED.
  tests/
    minimal_init.lua       # plenary bootstrap — UNCHANGED.
    smoke.lua              # zero-dep smoke — UNCHANGED (pi.bridge==nil pre-handshake still holds).
    bridge_spec.lua        # S24 spec — UNCHANGED (regression).
    jsonlreader_spec.lua   # S23 spec — UNCHANGED (regression).
    bridge_handshake_spec.lua  # S25 spec — UNCHANGED (regression).
    bridge_request_spec.lua    # S26 spec — UNCHANGED (regression); REUSE its HOFs.
    bridge_notify_spec.lua     # NEW (this task) — the Level-2 gate.
```

### Desired Codebase tree with files to be added/modified

```bash
plugin/lua/pi-editor/bridge.lua      # MODIFY — +notification_handlers map + M.on_notification + dispatch
                                     #   notification branch + close() registry clear + [Mode A] header note
plugin/tests/bridge_notify_spec.lua  # CREATE — plenary spec (real socket server; 13 cases per Success Criteria)
```

### Known Gotchas of our codebase & Library Quirks

```lua
-- CRITICAL: bridge.lua is a SINGLETON transport (S24 GOTCHA 10): one pipe, ONE on_event per session.
-- S25 owns dispatch(msg) and passes it as connect()'s on_event. S26 added the request-response branch;
-- S27 adds the NOTIFICATION branch as the LAST branch in the SAME dispatch — do NOT fork dispatch into a
-- per-notification closure. The three branches are mutually exclusive by wire shape (see research §2):
--   (1) handshake resp: id == "h1" (string)
--   (2) request resp:   type(id) == "string" (correlate via pending[id])
--   (3) notification:   type(method) == "string" AND type(id) ~= "string"

-- CRITICAL: store vim.schedule_wrap(handler) at REGISTRATION time (in M.on_notification). dispatch runs
-- INLINE from the luv read_start callback (via jsonlreader.feed → on_event → dispatch) — that is libuv
-- "fast" context where vim.api.* throws E5560 (:help lua-loop-callbacks). schedule_wrap defers the user's
-- handler body to the next nvim main-loop pass. Mirrors S26 (pending[id].cb = schedule_wrap(on_result))
-- and nvim's own vim/lsp/rpc.lua.

-- CRITICAL: NEVER call M.send in the notification branch. JSON-RPC §4: "The Server MUST NOT reply to a
-- Notification" — and the CLIENT must not reply to a server notification either (it has no id; there is
-- nothing to correlate a response to). A stray M.send would produce an unsolicited message the server's
-- handleLine would parse as a request/notification from the client (harmless but pointless, and could
-- hit -32601 if the method is unknown). The notification branch only READS dispatch state + invokes a
-- schedule_wrap'd handler.

-- CRITICAL: the notification guard is `type(msg.method) == "string" and type(msg.id) ~= "string"`.
-- - `type(msg.method) == "string"` separates notifications from RESPONSES (a JSON-RPC response carries
--   NO `method` field — only id + result/error). So responses never enter this branch.
-- - `type(msg.id) ~= "string"` defends a (v1-impossible) server "request" (method + string id) from
--   being mis-routed to the handler. It also gracefully handles id:null (decodes to nil, not a string).
-- Order matters: branch (2) already consumed string-id messages, so by the time we reach (3) id is
-- non-string (or absent) for any well-formed notification.

-- CRITICAL: `msg.params` is `nil` for `commandsChanged`. The S17 server OMITS empty params on the wire
-- (protocol.ts CommandsChangedParams = Record<string, never>; verified by the S17 REAL test:
-- `assert.ok(!("params" in parsed))`). After vim.json.decode, an ABSENT key is `nil` (NOT vim.NIL —
-- vim.NIL is only for an EXPLICIT JSON `null`). So the handler receives `params == nil`. Do NOT assert
-- `params == {}` in the spec; assert `params == nil`. (Future notifications WITH params would decode to
-- a table; the API passes msg.params through unchanged.)

-- CRITICAL: close() clears the registry by REASSIGNMENT: `notification_handlers = {}`. The registry is
-- a module-level `local` read as an UPVALUE by dispatch — reassigning it updates the upvalue (exactly how
-- `state = {...}` works in connect()). dispatch then sees the empty table. Do NOT mutate field-by-field
-- (pointless churn); a single reassignment is correct and matches the codebase's pattern.

-- CRITICAL: on_notification NEVER throws. Bad args (non-string method, empty method, non-function handler,
-- nil method) are silently dropped (the never-throws contract S24/S25/S26 keep). A `handler == nil` is
-- the documented REMOVE path (set the entry to nil). Validate UP FRONT, before any schedule_wrap.

-- CRITICAL: last-wins re-registration. Registering handler B for a method that already had handler A
-- REPLACES A (a Lua table set — no array of handlers, no multi-cast in v1). The prior closure is GC'd.
-- Do NOT append; do NOT call both. (If multi-cast is ever needed, it is a future enhancement — PRD §15.)

-- GOTCHA: the [Mode A] header has a dedicated S27 note block (like the S25/S26 blocks). Document: the
-- notification seam, the on_notification API (last-wins / nil-removes / never-throws / schedule_wrap'd),
-- the dispatch branch ordering (handshake → request → notification), and the close() registry clear.

-- GOTCHA: in the SPEC, write the server's notification line as the RAW string
--   '{"jsonrpc":"2.0","method":"commandsChanged"}\n'
-- to assert the EXACT wire form (no id, no params). Do NOT build it with vim.json.encode({params={}})
-- (that would emit "params":{}, which the real S17 server does NOT). This makes the test assert what
-- production actually sends.

-- GOTCHA: do NOT name a spec-local table `pending` in bridge_notify_spec.lua — it shadows
-- plenary.busted's global `pending` (the test-SKIP function). Observe behavior into `fired`/`got` locals.

-- GOTCHA: reuse bridge_request_spec.lua's with_request_server + with_handshaken_server HOFs verbatim
-- (copy them into the new spec file, or require the spec — simplest is to copy the helpers since specs
-- are standalone files run by plenary). Add a server mode "notify" to the request-decoder.
```

## Implementation Blueprint

### Data models and structure (Lua tables — no ORM/pydantic; this is a Neovim plugin)

```lua
-- ── Added to bridge.lua (module-level singleton state, cleared in close()) ───────

--- Notification handlers keyed by method (string). Each value is the user handler wrapped in
--- `vim.schedule_wrap` at registration (GOTCHA 5 — dispatch runs inline from the luv `read_start`
--- callback; raw `vim.api.*` throws `E5560` there). Last-wins re-registration (a Lua table set);
--- `on_notification(method, nil)` removes an entry. Cleared wholesale by `close()` (hygiene:
--- a stale handler must not fire across reconnects — PRD §6.7). S27 is the MECHANISM; the
--- cache-invalidation BEHAVIOR is S41 (`require("pi-editor").bridge.on_notification(
--- "commandsChanged", function(_params) ... end)`).
---@type table<string, function>
local notification_handlers = {}
```

### Implementation Tasks (ordered by dependencies)

```yaml
Task 1: ADD the notification-handler registry to plugin/lua/pi-editor/bridge.lua
  - ADD: `local notification_handlers = {}` (documented per the Blueprint above).
  - PLACEMENT: right after the S26 `local pending = {}` block (they are sibling transport maps —
    keep the protocol state together, before the S25/S26 forward declarations).
  - FOLLOW pattern: S26's `local pending = {}` + its documented class.
  - CLEAR in M.close(): `notification_handlers = {}` (see Task 4).
  - DEPENDENCIES: none (pure addition; no behavior change yet).
  - NAMING: snake_case; `local` for internal (notification_handlers); `M.` for public.

Task 2: EXTEND `dispatch(msg)` with the notification branch (the S27 SEAM)
  - FIND: the existing `dispatch = function(msg)` — the handshake branch, the `type(msg.id)=="string"`
    + `pending[msg.id]` request-response branch, and the literal `-- S27 EXTENSION POINT` comment at
    the end.
  - REPLACE the `-- S27 EXTENSION POINT: notifications (commandsChanged) go here.` comment with:
      -- S27: a NOTIFICATION (method present, no string id — JSON-RPC §4). Dispatch to a registered
      -- handler (schedule_wrap'd at registration so it is safe to call from this luv read_start cb —
      -- GOTCHA 5). NEVER reply (JSON-RPC: a notification expects no response). An unknown method or
      -- a missing handler is silently dropped (PRD §11).
      if msg and type(msg.method) == "string" and type(msg.id) ~= "string" then
        local h = notification_handlers[msg.method]
        if h then h(msg.params) end   -- h is schedule_wrap'd -> next nvim loop pass (safe)
        return
      end
  - PRESERVE: the handshake branch stays FIRST; the request-response branch stays SECOND (mutually
    exclusive with notifications by wire shape — see research §2 truth table; but order defends
    against future changes).
  - GOTCHA: the `type(msg.id) ~= "string"` guard is load-bearing — it prevents a (v1-impossible)
    server "request" (method + string id) from firing a notification handler, and it handles id:null.
  - GOTCHA: NO `M.send` here (JSON-RPC §4 — never reply to a notification).
  - DEPENDENCIES: Task 1.

Task 3: ADD `M.on_notification(method, handler)` to bridge.lua
  - IMPLEMENT: the public registration API (the surface S41 / future consumers call).
      --- Register (or replace / remove) a handler for a server→client NOTIFICATION method.
      --- `handler(params)` is invoked (on the next nvim main-loop pass) when the server sends a
      --- notification `{jsonrpc:"2.0",method:<method>}` (no id). Pass `nil` to remove. Never throws.
      ---@param method string Notification method name (PRD §5.4: "commandsChanged" in v1).
      ---@param handler fun(params:any?)|nil Called with msg.params (nil for commandsChanged — empty params omitted on the wire).
      function M.on_notification(method, handler)
        if type(method) ~= "string" or method == "" then return end   -- bad method -> no-op
        if handler == nil then
          notification_handlers[method] = nil                          -- remove
          return
        end
        if type(handler) ~= "function" then return end                 -- non-function -> no-op
        notification_handlers[method] = vim.schedule_wrap(handler)     -- last-wins; safe from luv
      end
  - GOTCHA: validate UP FRONT (never throws); wrap with schedule_wrap at STORE time (the user closure
    is fixed once registered; dispatch calls the wrapped form).
  - GOTCHA: last-wins (a Lua table SET replaces the prior handler — no multi-cast in v1).
  - DEPENDENCIES: Task 1.
  - PLACEMENT: right after M.cancel (the S26 public surface) / before M.close — keep the public API
    grouped (request/cancel/on_notification).

Task 4: EXTEND `M.close()` to clear the notification-handler registry
  - FIND: the existing M.close() — the shadow state.closed flag + pipe close + the S26 pending drain
    + `next_id = 0` + state clear + `M.server_info = nil`.
  - ADD (in the SAME state-wipe region, near `M.server_info = nil`):
      -- S27: clear the notification-handler registry (hygiene — a stale handler must not fire across
      -- reconnects). notification_handlers is a module-level local read as an upvalue by dispatch;
      -- reassigning it (like state = {...} in connect()) updates the upvalue, so dispatch sees the
      -- empty table. The only caller (S41 completion.lua) re-registers after each handshake, so this
      -- is defense-in-depth + the "no leak across editor open/close cycles" discipline (PRD §6.7).
      notification_handlers = {}
  - PRESERVE: the existing close() body. Do NOT clear handshake_state (the existing comment explains
    why — resolve_handshake owns it via the pending bool).
  - GOTCHA: reassignment (not field-by-field mutation) is the correct way to reset a module-level
    local upvalue. The drained handlers are user closures — clearing does NOT call them (unlike the
    S26 pending cbs, notifications have nothing to "resolve").
  - DEPENDENCIES: Tasks 1-3.

Task 5: UPDATE the `[Mode A]` header in bridge.lua with an S27 note block
  - ADD (after the existing `[Mode A] S26 EXTENSION` block):
      -- [Mode A] S27 EXTENSION — the notification dispatch (the THIRD protocol consumer):
      --  * S27 adds ONE branch to `dispatch(msg)` at the literal `-- S27 EXTENSION POINT` placeholder
      --    (AFTER the S25 handshake branch + the S26 request-response branch): if a decoded msg has a
      --    string `method` and NO string `id` (JSON-RPC §4 notification), look up
      --    `notification_handlers[method]` and invoke it (schedule_wrap'd). NEVER reply (JSON-RPC: a
      --    notification expects no response). Unknown method / missing handler -> silently dropped.
      --  * S27 adds `M.on_notification(method, handler)` — the registration API S41 (cache
      --    invalidation) + future consumers call. Last-wins; `nil` removes; never throws; handler
      --    stored `vim.schedule_wrap`'d (GOTCHA 5 — dispatch runs inline from the luv read_start cb).
      --  * M.close() clears `notification_handlers` (hygiene — no stale handler across reconnects).
      --  * The three dispatch branches are mutually exclusive by wire shape: handshake resp has
      --    id=="h1"; request resp has a string id (no method); notification has method + no string id.
      --  * commandsChanged is the ONLY NotificationMethod in v1 (protocol.ts §D). Its params are
      --    EMPTY and OMITTED on the wire (S17) -> the handler receives `params == nil`.
  - DEPENDENCIES: Tasks 1-4.

Task 6: CREATE plugin/tests/bridge_notify_spec.lua (plenary/busted — the Level-2 gate)
  - IMPLEMENT: reuse `bridge_request_spec.lua`'s `with_request_server(opts, spec)` +
    `with_handshaken_server(server_opts, spec)` HOFs (copy them — specs are standalone files). Add a
    server mode `"notify"` that writes a `commandsChanged` notification line AFTER the handshake reply:
      -- in the server's request-decoder, AFTER the hello branch:
      if opts.mode == "notify" then
        -- push a commandsChanged notification (no id, no params — the EXACT wire form the S17 server emits)
        if srv_conn and not srv_conn:is_closing() then
          srv_conn:write('{"jsonrpc":"2.0","method":"commandsChanged"}\n')
        end
        return
      end
    - Also support a server-driven raw-write path (mirror bridge_request_spec's `server_send` helper)
      so a test can send the notification at a chosen moment (for the interleaving case).
    - Cases (mirror research/notes.md §8 — every Success Criterion checkbox):
        (1)  expose on_notification as a function.
        (2)  handler invoked on commandsChanged; params == nil (empty params omitted on the wire).
        (3)  schedule_wrap'd / safe — handler body calls a vim.api op (e.g. vim.api.nvim_buf_set_var on
             a scratch buffer) WITHOUT throwing E5560 (indirect proof it ran on the nvim loop).
        (4)  client sends NO response — the server's request-decoder saw only `hello` (JSON-RPC §4).
        (5)  last-wins re-registration — register A then B; only B fires (A replaced, not leaked).
        (6)  on_notification(method, nil) removes — subsequent notification dropped, no throw.
        (7)  no handler registered — notification silently dropped, no throw (PRD §11).
        (8)  interleaving — fire getSuggestions; server sends commandsChanged THEN the getSuggestions
             response; BOTH the handler fires AND the request cb resolves with its own result.
        (9)  close() clears the registry — register, handshake, close(), re-handshake WITHOUT
             re-registering, send notification; the OLD handler does NOT fire (no leak).
        (10) never-throws on bad args (non-string method, empty method, non-function handler, nil method).
        (11) defensive — server sends {method:"commandsChanged", id:"9", result:{ok:true}} (a "request"
             shape); the handler does NOT fire and no response is sent (the type(msg.id)~="string" guard).
        (12) generic registry — a synthetic method "x/synthetic" routes to ITS own handler.
        (13) REGRESSION smoke — bridge.handshake + bridge.request still route correctly with the
             notification branch present (a handshake → a request → all resolve; the new branch did not
             swallow anything).
    - FOLLOW pattern: plugin/tests/bridge_request_spec.lua's with_request_server + reset_module +
      vim.wait(budget, predicate, 5).
    - NAMING: describe("pi-editor.bridge on_notification", …); it("…", with_handshaken_server({mode=…}, …)).
    - COVERAGE: every Success Criterion checkbox has a matching `it`.
    - PLACEMENT: plugin/tests/ (alongside bridge_request_spec.lua).
    - GOTCHA: reset_module() (close + nil pi.bridge) in before_each/after_each AND inside the HOF.
      S27's close() clearing notification_handlers makes it sufficient.
    - GOTCHA: write the notification line RAW ('{"jsonrpc":"2.0","method":"commandsChanged"}\n') to
      assert the exact no-params wire form.
    - GOTCHA: do NOT name a spec-local table `pending` (shadows busted's global skip fn).
    - DEPENDENCIES: Tasks 1-5.
```

### Implementation Patterns & Key Details

```lua
-- === The dispatch branch (S27 fills the placeholder at the END of dispatch) ===========
-- Place AFTER the handshake branch (id=="h1") and the request-response branch
-- (type(msg.id)=="string" && pending[msg.id]). The three branches are mutually exclusive.
      -- S27: a NOTIFICATION (method present, no string id — JSON-RPC §4). Dispatch to a registered
      -- handler (schedule_wrap'd at registration so it is safe to call from this luv read_start cb —
      -- GOTCHA 5). NEVER reply (JSON-RPC: a notification expects no response). An unknown method or
      -- a missing handler is silently dropped (PRD §11).
      if msg and type(msg.method) == "string" and type(msg.id) ~= "string" then
        local h = notification_handlers[msg.method]
        if h then h(msg.params) end   -- h is schedule_wrap'd -> next nvim loop pass (safe)
        return
      end

-- === The public on_notification() entry ===============================================
function M.on_notification(method, handler)
  if type(method) ~= "string" or method == "" then return end   -- bad method -> no-op (never throws)
  if handler == nil then
    notification_handlers[method] = nil                          -- remove
    return
  end
  if type(handler) ~= "function" then return end                 -- non-function -> no-op
  notification_handlers[method] = vim.schedule_wrap(handler)     -- last-wins; safe from luv (GOTCHA 5)
end

-- === close() registry clear (added to the existing M.close(), near M.server_info=nil) =
  -- (S27) clear the notification-handler registry (hygiene — a stale handler must not fire across
  -- reconnects). notification_handlers is a module-level local read as an upvalue by dispatch;
  -- reassigning it (like state = {...} in connect()) updates the upvalue. The drained handlers are
  -- user closures — clearing does NOT call them (unlike the S26 pending cbs, notifications have
  -- nothing to "resolve"). PRD §6.7: no leak across editor open/close cycles.
  notification_handlers = {}
```

### Integration Points

```yaml
MODULE STATE (bridge.lua):
  - add: "local notification_handlers = {}"   # method → schedule_wrap'd handler; cleared in close()

DISPATCH SEAM (bridge.lua):
  - extend: "dispatch(msg)" — add the notification branch at the `-- S27 EXTENSION POINT` placeholder
            (AFTER the handshake branch + the request-response branch)

PUBLIC API (bridge.lua):
  - add: "M.on_notification(method, handler)"  # register/replace/remove a notification handler (S41 calls it)

TEARDOWN (bridge.lua):
  - extend: "M.close()" — clear `notification_handlers = {}` (alongside the S26 pending drain + server_info=nil)
  - preserve: handshake_state is NOT cleared here (resolve_handshake owns it; see existing comment)

ACTIVATION (init.lua):
  - NO CHANGE — on_notification is called by completion (S41), not activate(). The handshake (S25)
    already publishes `require("pi-editor").bridge = M`, so `bridge.on_notification` is live post-handshake.

PLUGIN SURFACE (for downstream — PRD §7.7):
  - require("pi-editor").bridge.on_notification(method, handler)  # S41 cache-invalidation registers here

CONFIG (already exists — S19):
  - NO NEW OPTION — notifications have no timeout / debounce at this layer (they are fire-and-forget;
    S41 may add its own debounce around the cache clear, but that is S41's concern, not the transport's).

NO NEW DEPENDENCIES:
  - only vim.uv (luv) + vim.json + vim.schedule_wrap + the S23 jsonlreader — all built into Neovim 0.10+ (0.12 verified)
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
luacheck lua/pi-editor/bridge.lua --std luajit 2>/dev/null || true

#stylua (optional formatting — no config yet; skip unless the repo adopts stylua.toml):
#stylua --check lua/pi-editor/bridge.lua tests/bridge_notify_spec.lua 2>/dev/null || true
# Expected: load-exit 0; lint clean (or skipped). If load fails, READ the nvim stderr and fix.
```

### Level 2: Unit Tests (Component Validation — the formal gate)

```bash
# The NEW notification spec (real luv socket server; every Success Criterion case):
cd plugin && nvim --headless --clean -u tests/minimal_init.lua \
  -c 'lua require("plenary.busted").run("tests/bridge_notify_spec.lua")' \
  -c 'qa' ; echo "notify-exit=$?"
# Expected: Success N / Failed 0 / Errors 0. (Exit 0 = pass; 1 = ≥1 assert fail; 2 = load error.)

# REGRESSION — the S26 request spec MUST still pass (dispatch only GAINED a branch):
cd plugin && nvim --headless --clean -u tests/minimal_init.lua \
  -c 'lua require("plenary.busted").run("tests/bridge_request_spec.lua")' \
  -c 'qa' ; echo "request-exit=$?"   # expect all green

# REGRESSION — the S25 handshake spec (handshake routes id=="h1" FIRST; notifications never match):
cd plugin && nvim --headless --clean -u tests/minimal_init.lua \
  -c 'lua require("plenary.busted").run("tests/bridge_handshake_spec.lua")' \
  -c 'qa' ; echo "handshake-exit=$?"   # expect all green

# REGRESSION — the S24 transport spec (connect()/send()/close() signatures unchanged):
cd plugin && nvim --headless --clean -u tests/minimal_init.lua \
  -c 'lua require("plenary.busted").run("tests/bridge_spec.lua")' \
  -c 'qa' ; echo "bridge-exit=$?"   # expect Success 11 / Failed 0

# REGRESSION — the S23 jsonlreader spec (unchanged):
cd plugin && nvim --headless --clean -u tests/minimal_init.lua \
  -c 'lua require("plenary.busted").run("tests/jsonlreader_spec.lua")' \
  -c 'qa' ; echo "jsonlreader-exit=$?"

# The zero-dependency smoke (dormant-session + setup() invariants — pi.bridge still nil pre-handshake):
cd plugin && nvim --headless --clean -u NORC +"luafile tests/smoke.lua" +qa ; echo "smoke-exit=$?"
# Expected: stdout "SMOKE_PASS", exit 0.
```

### Level 3: Integration Testing (System Validation)

```bash
# End-to-end: a REAL bridge server (the DONE S17 extension) broadcasts commandsChanged; a headless
# nvim with a registered handler observes it. (The server emits on session_start; in v1 the broadcast
# is structurally quiescent — see S17's HONEST PROPERTY — so this e2e is best validated by forcing a
# broadcast via a tiny Node client that connects, handshakes, then calls broadcastNotification, OR by
# the plenary spec's real-socket "notify" mode which is the deterministic equivalent. The plenary
# Level-2 spec IS the e2e proof for the client half; this block documents the manual cross-check.)

# 1. From a shell, start the bridge extension's server standalone (or via pi in tui mode) so the socket
#    is up and PI_EDITOR_BRIDGE is set in pi's process env.
# 2. Launch headless nvim from that env, register a handler, and assert it fires:
TMP=$(mktemp --suffix=.pi.md); echo "hello world" > "$TMP"
PI_EDITOR_BRIDGE='<descriptor-from-pi>' nvim --headless --clean -u plugin/tests/minimal_init.lua \
  +"luafile plugin/plugin/pi-editor.lua" \
  -c 'lua vim.defer_fn(function()
        local pi=require("pi-editor")
        assert(pi.bridge ~= nil, "handshake did not set pi.bridge")
        assert(type(pi.bridge.on_notification)=="function", "on_notification missing")
        pi.bridge.on_notification("commandsChanged", function(_params)
          print("E2E_NOTIFY fired; params=" .. tostring(_params))
          vim.cmd("qa")
        end)
        -- (The server must broadcast commandsChanged to observe this. In v1 it is quiescent on
        --  session_start; trigger a /reload from the pi TUI — but the TUI must be active, so the
        --  external editor is closed first. This is the documented S17 limitation. The plenary
        --  spec is the deterministic proof for the client dispatch.)
      end, 500)' \
  "$TMP" ; echo "e2e-exit=$?"
# Expected (when a broadcast is forced): stdout "E2E_NOTIFY fired; params=nil", exit 0.

# NEGATIVE e2e — on_notification before the handshake (pi.bridge still nil) must not crash:
PI_EDITOR_BRIDGE='' nvim --headless --clean -u plugin/tests/minimal_init.lua +"luafile plugin/plugin/pi-editor.lua" \
  -c 'lua vim.defer_fn(function()
        local pi=require("pi-editor")
        assert(pi.bridge == nil, "no-env bridge must be nil")
        print("NEG_OK"); vim.cmd("qa")
      end, 200)' ; echo "neg-exit=$?"
# Expected: "NEG_OK", exit 0.
```

### Level 4: Creative & Domain-Specific Validation

```bash
# Interleaving stress (covered deterministically by bridge_notify_spec.lua case #8): fire many
# getSuggestions rapidly while the server emits commandsChanged between each; assert each request cb
# resolves EXACTLY ONCE with its OWN result AND the notification handler fires once per broadcast (no
# cross-interference). The plenary case is the gate; this is the rationale.

# Handler-leak check: after a test that registers N handlers and fires N notifications, confirm no
# stale handler fires after a close()+reconnect WITHOUT re-registration (case #9). The close()
# registry clear + last-wins re-registration guarantee this. A leaked handler would observe a
# notification meant for a fresh session — observable as a spurious cb in case #9.

# :checkhealth stub (the FULL health module is S42; here just confirm bridge.on_notification is
# callable after a successful handshake so S42 can note it):
nvim --headless --clean -u plugin/tests/minimal_init.lua \
  -c 'lua require("plenary.busted").run("tests/bridge_notify_spec.lua")' -c 'qa'

# (selene + stylua CI — OPTIONAL; the repo has no config yet. If adopted later, add a
# .github/workflows per PRD §9.2. Not blocking for this task.)
```

## Final Validation Checklist

### Technical Validation
- [ ] Level 1 load-check: `bridge.lua` loads with exit 0 (no syntax error in the new registry/dispatch-branch/on_notification/close-clear code).
- [ ] Level 2: `bridge_notify_spec.lua` → Success N / Failed 0 / Errors 0 (exit 0).
- [ ] Level 2 REGRESSION: `bridge_request_spec.lua` → all green (dispatch only gained a branch; request correlation unaffected).
- [ ] Level 2 REGRESSION: `bridge_handshake_spec.lua` → all green (handshake routes `id=="h1"` first; notifications never match).
- [ ] Level 2 REGRESSION: `bridge_spec.lua` → Success 11 / Failed 0 (connect()/send()/close() unchanged).
- [ ] Level 2 REGRESSION: `jsonlreader_spec.lua` → all green (unchanged).
- [ ] Level 2: `smoke.lua` → `SMOKE_PASS`, exit 0 (pi.bridge still nil pre-handshake; on_notification never runs dormant).

### Feature Validation
- [ ] Every Success Criterion checkbox in §What is covered by a spec case.
- [ ] A registered handler fires on `commandsChanged` with `params == nil` (empty params omitted on the wire).
- [ ] The handler is `schedule_wrap`'d — a body that calls `vim.api.*` does NOT throw `E5560`.
- [ ] The client sends NO response to a notification (JSON-RPC §4) — the server saw only `hello`.
- [ ] A `commandsChanged` interleaved with an in-flight `getSuggestions` does not corrupt either path.
- [ ] `close()` clears the registry (no stale handler across reconnects).
- [ ] `on_notification()` never throws on bad args; last-wins; nil removes; missing handler = silent drop.

### Code Quality Validation
- [ ] `connect()`/`send()`/`handshake()`/`request()`/`cancel()` public signatures UNCHANGED (on_notification is ADDED).
- [ ] bridge.lua stays pure `vim.uv` + `vim.json` + `vim.schedule_wrap` + jsonlreader (no new runtime deps; no `vim.api` from luv cbs).
- [ ] The dispatcher has ONE added branch (the S27 notification seam; no further extension point remains).
- [ ] Module state (`notification_handlers`) is cleared in `M.close()` (no leak across reconnects; no stale-handler reuse).
- [ ] The token value NEVER appears anywhere (commandsChanged has empty params — trivially satisfied; document for discipline per PRD §12).
- [ ] Field naming matches the repo (`snake_case`, `M.` public, `local` internal; matches bridge/handshake/request style).

### Documentation & Deployment
- [ ] bridge.lua `[Mode A]` header gains an S27 note: the notification seam + `on_notification` API + the dispatch branch ordering + the close() clear.
- [ ] No new env vars / config options introduced (notifications need none at the transport layer).
- [ ] The downstream contract is documented: `require("pi-editor").bridge.on_notification("commandsChanged", fn)` is what S41 (cache invalidation) calls.

---

## Anti-Patterns to Avoid

- ❌ Don't fork `dispatch()` into a per-notification closure — it's a SINGLETON on_event (S24 GOTCHA 10). Add ONE branch as the LAST branch in the existing dispatch.
- ❌ Don't put the notification branch BEFORE the handshake branch or the request-response branch. Order is handshake → request → notification (mutually exclusive by wire shape, but order defends against future changes and keeps the truth table in research §2 honest).
- ❌ Don't call `M.send` in the notification branch — JSON-RPC §4: "The Server MUST NOT reply to a Notification." The client likewise sends nothing. A stray `M.send` would produce an unsolicited client message the server would parse as a request/notification (pointless; possibly -32601).
- ❌ Don't call the user's raw handler from `dispatch` — `dispatch` runs inline from the luv `read_start` callback (libuv "fast" context); `vim.api.*` throws `E5560` there. Store `vim.schedule_wrap(handler)` at registration time (mirrors S26's `pending[id].cb` and nvim's `vim/lsp/rpc.lua`).
- ❌ Don't omit the `type(msg.id) ~= "string"` guard — a message with `method` AND a string `id` is a REQUEST (the bridge's are C→S only in v1), NOT a notification. Without the guard, a (v1-impossible but defensive) server "request" would mis-fire a notification handler. The guard also handles `id:null` (decodes to nil).
- ❌ Don't assert `params == {}` in the spec — `commandsChanged` has EMPTY params and the S17 server OMITS them on the wire, so `msg.params` is `nil` (absent), NOT an empty table and NOT `vim.NIL`. Assert `params == nil`.
- ❌ Don't build the notification line in the spec with `vim.json.encode({params={}})` — that emits `"params":{}`, which the real server does NOT. Write the RAW string `'{"jsonrpc":"2.0","method":"commandsChanged"}\n'` to assert the exact wire form.
- ❌ Don't implement multi-cast (calling all registered handlers for a method) — last-wins (a Lua table set) is the v1 contract. Registering twice replaces; the prior closure is GC'd. Multi-cast is a future enhancement (PRD §15).
- ❌ Don't mutate `notification_handlers` field-by-field in `close()` — reassign `notification_handlers = {}` (it's a module-level local read as an upvalue by dispatch; reassignment updates the upvalue, exactly like `state = {...}` in `connect()`).
- ❌ Don't leave a stale handler across reconnects — `close()` MUST clear the registry (PRD §6.7: no leak across editor open/close cycles). Even though S41 re-registers after each handshake, the clear is defense-in-depth.
- ❌ Don't name a spec-local table `pending` in the test file — it shadows plenary.busted's global `pending` (the test-skip function). Observe behavior into `fired`/`got` locals instead.
- ❌ Don't add behavior (cache clearing, menu refresh) in THIS task — that is S41's job (P3.M10.T26.S41). S27 ships ONLY the mechanism (dispatch + on_notification + close() clear).

---

## Confidence Score: 9/10

**Why 9, not 10:** every contract is pinned to a DONE, tested source file — the S26 request layer
(the exact dispatch seam + the `schedule_wrap`/close() patterns to mirror), the S17 server notification
(the exact wire input `{"jsonrpc":"2.0","method":"commandsChanged"}`, verified by its REAL test), and
`protocol.ts` (`commandsChanged` is the only `NotificationMethod`; empty params). The design is the
lowest-risk extension of the existing module: one added dispatch branch (filling a literal placeholder),
one added public function (`on_notification`), and one line in `close()`. The `schedule_wrap`-from-luv
rule and the notification-vs-response distinction are LIVE-VERIFIED (Neovim 0.12 + JSON-RPC spec + nvim's
own `vim/lsp/rpc.lua`). The one residual uncertainty is cosmetic: whether to reuse `bridge_request_spec.lua`'s
HOFs by `require`-ing the spec or by copying the helpers (plenary specs are standalone files, so copying
is the path of least resistance — a mechanical test-authoring detail, not a design risk). The interleaving
case (#8) is the only behavioral subtlety, and the branch-ordering truth table (research §2) proves it is
correct by construction.

**Implementer's fastest path:** read `research/notes.md` §1-2 (the wire form + the dispatch ordering
truth table) and §5 (the `on_notification` API), then implement Tasks 1-5 by pasting the Blueprint code
into `bridge.lua` (the registry, the dispatch branch replacing the placeholder comment, `on_notification`,
the `close()` clear, the header note), then Task 6 (copy `bridge_request_spec.lua`'s
`with_request_server`/`with_handshaken_server`, add the `"notify"` mode that writes the RAW notification
line, and author the 13 cases). Run the Level-2 gates (the new spec + the 4 regressions + smoke).
Confirm the spec writes the notification line RAW (no `"params"`) so it matches the S17 server's wire form.