# Research Notes — P2.M5.T16.S27 (Neovim `commandsChanged` notification handler)

The THIRD protocol consumer of the S24 transport (after S25 handshake, S26 request).
Extends the single `dispatch(msg)` in `plugin/lua/pi-editor/bridge.lua` with ONE branch
that routes the server→client `commandsChanged` **notification** to a registered handler.
Sibling of S26 (`request`/`pending`); the cache-invalidation *behavior* that consumes this
handler is a LATER task — **P3.M10.T26.S41** ("Clear caches and re-query on commandsChanged").

> S27 ships the **MECHANISM** (notification dispatch + a public `on_notification` registration
> API). S41 ships the **BEHAVIOR** (the cache-clearing handler completion.lua registers via it).

---

## §1 — The wire form of `commandsChanged` (the input S27 consumes)

Authoritative source: the COMPLETED server-side notification task **S17**
(`extension/tests/commands-changed-notification.test.ts`, plus `connection.ts` +
`protocol.ts`). S27 must consume EXACTLY what S17 emits.

From `extension/connection.ts` `sendNotification()` + `broadcastNotification()`:

```jsonc
{"jsonrpc":"2.0","method":"commandsChanged"}
```

CRITICAL properties (verified by the S17 REAL test, `commands-changed-notification.test.ts`):

1. **No `id` field.** `assert.ok(!("id" in parsed), "notification must have NO id")`.
   → JSON-RPC 2.0 NOTIFICATION semantics (see §3). The client MUST NOT send any reply.
2. **No `params` field.** `CommandsChangedParams = Record<string, never>` (empty) and the
   server OMITS empty params on the wire:
   `assert.ok(!("params" in parsed), "empty params are OMITTED on the wire (cleaner)")`.
   → After `vim.json.decode`, **`msg.params == nil`** (the key is absent, not `vim.NIL`).
   S27's handler is invoked with `msg.params`; for `commandsChanged` that is `nil`.
3. **Only sent to HANDSHAKEN peers.** `broadcastNotification` filters on
   `state.handshakeComplete` (PRD §12). → The client will only ever receive
   `commandsChanged` AFTER its own `hello` succeeded (i.e. after `dispatch` is live and
   `pi.bridge == bridge`). A pre-handshake `commandsChanged` never reaches the client.
4. **Never carries the token.** `assert.ok(!JSON.stringify(broadcast).includes(REAL_TOKEN))`.
   → Security is trivially satisfied (empty params); document for discipline (PRD §12).

`protocol.ts` confirms `commandsChanged` is the ONLY `NotificationMethod`
(`Exclude`-d from `RequestMethod`; omitted from `BridgeResultMap`). So in v1 there is
exactly one notification method — but S27's dispatch is designed GENERIC (a `method → handler`
registry) so future notifications need no new plumbing.

---

## §2 — The dispatch seam + branch ordering (where S27 plugs in)

`bridge.lua`'s `dispatch(msg)` (the SINGLETON `on_event` S25 passes to `connect()` —
GOTCHA 10) already has a literal placeholder comment. Current state (verified by reading
the file):

```lua
dispatch = function(msg)
  if handshake_state and handshake_state.pending and msg and msg.id == "h1" then
    resolve_handshake(msg, nil)   -- (1) S25 handshake response  — STAYS FIRST
    return
  end
  if msg and type(msg.id) == "string" then         -- (2) S26 request response
    if pending[msg.id] then
      resolve_request(msg.id, nil, msg)
      return
    end
    -- stale / late / duplicate / stray -> silently dropped
  end
  -- S27 EXTENSION POINT: notifications (commandsChanged) go here.   ← THIS TASK
end
```

**Branch ordering analysis (why the notification branch goes LAST and is safe):**

| Incoming msg shape | branch (1) `id=="h1"` | branch (2) `type(id)=="string"` | branch (3) S27 notification |
|---|---|---|---|
| handshake resp `{id:"h1",result}` | ✅ caught | — | — |
| request resp `{id:"3",result}` | no | ✅ `pending["3"]` → resolve | — |
| stray resp `{id:"zzz",result}` | no | ✅ `pending["zzz"]`=nil → dropped | no (`type(id)~="string"` false) |
| **notification `{method:"commandsChanged"}`** | no (`id` absent) | **no** (`type(msg.id)~="string"` true ONLY if id is a string; here id is `nil`) | ✅ caught |
| malformed `{method,id:null}` | no | `type(id)=="string"` false → skip | branch-3 guard `type(id)~="string"` TRUE + `type(method)=="string"` TRUE → routed to handler (harmless; no real server sends this in v1) |

**The S27 branch** (fills the placeholder):

```lua
-- S27: a NOTIFICATION (method present, no string id). Dispatch to a registered handler
-- (schedule_wrap'd at registration so it is safe to call from this luv read_start cb — GOTCHA 5).
if msg and type(msg.method) == "string" and type(msg.id) ~= "string" then
  local h = notification_handlers[msg.method]
  if h then h(msg.params) end     -- no registered handler -> silently dropped (PRD §11)
  return
end
```

Guards:
- `type(msg.method) == "string"` — a RESPONSE carries no `method` (JSON-RPC §4), so this
  cleanly separates notifications from responses. Also drops a fully malformed `{}`.
- `type(msg.id) ~= "string"` — belt-and-suspenders: a message with method + string id is
  a server "request" (NOT in v1 — the bridge's `RequestMethod` is C→S only); it must NOT be
  mis-routed to the notification handler. It falls through here and is silently dropped
  (branch 2 already didn't match it because `pending[id]` is nil).

No early `return` is strictly required (dispatch is the last branch), but `return` makes the
"notification handled" intent explicit and defends against a future branch added below.

---

## §3 — External authority: JSON-RPC 2.0 notification semantics

- **Spec:** https://www.jsonrpc.org/specification#notification —
  *"A Notification is a Request object without an `id` member. The Server MUST NOT reply to
  a Notification, including those that are within a batch request."*
  → S27 MUST NOT write any response to a `commandsChanged` (there is no `M.send` in the
  notification branch). The server (S17) likewise never expects one.
- **§4 request_object** — id is String|Number|NULL; only messages WITHOUT an id key are
  notifications. S27 distinguishes via `type(msg.id) ~= "string"` (absent → `nil` → not a
  string), matching the spec's "without an `id` member".
- S26's research already established the JSON-RPC §6 ordering / correlation guarantees for
  *responses*; notifications are fire-and-forget (no correlation, no id) and may be sent at
  any time — including BETWEEN two responses. S27 must therefore not assume a notification
  arrives at a "safe" moment (it can interleave with an in-flight `getSuggestions`). Because
  the handler is `schedule_wrap`'d, it never blocks the response-correlation path.

---

## §4 — External authority: `vim.schedule_wrap` / luv "fast context" (GOTCHA 5)

The dispatch runs **inline from the libuv `read_start` callback** (via `jsonlreader.feed →
on_event → dispatch`). That is libuv/fast context where **`vim.api.*` throws `E5560:
… must not be called in a lua loop callback`**.

- Neovim `:help lua-loop-callbacks` / API docs (https://neovim.io/doc/user/api/): use
  `vim.in_fast_event()` to detect; wrap API-touching work in `vim.schedule` /
  `vim.schedule_wrap`.
- neovim/neovim#21052, #31199, #20048 + the r/neovim thread all confirm: `E5560` is fixed
  by `vim.schedule_wrap(fn)`, which defers `fn` to the next nvim main-loop pass.
- Production precedent in nvim itself: `vim/lsp/rpc.lua` stores `schedule_wrap(cb)` in its
  request table and invokes it from the `read_start` callback — EXACTLY the pattern S26 used
  for `pending[id].cb`, and the pattern S27 reuses for `notification_handlers[method]`.

**Implication:** S27 stores the handler as `vim.schedule_wrap(handler)` at REGISTRATION time
(in `M.on_notification`, which runs on the nvim main loop when downstream code calls it —
e.g. S41's completion.lua). The dispatch then calls `notification_handlers[method](params)`
safely from luv context. The user's handler body (which will touch buffers / menus in S41)
is deferred to the safe loop. Never call the raw user handler from dispatch.

---

## §5 — The API design (`on_notification` registry)

S26 established the module-level-map + exactly-once-via-delete pattern for requests.
S27 mirrors it for notifications — except notifications have NO id and NO result, so there
is no "resolve" / timeout / cancel. The registry is simply `method → handler`.

```lua
--- Notification handlers keyed by method (string). Each value is the user handler wrapped
--- in vim.schedule_wrap at registration (GOTCHA 5). Cleared wholesale by close() (hygiene).
---@type table<string, function>
local notification_handlers = {}
```

Public registration API (the surface S41 — and any future notification consumer — calls):

```lua
--- Register (or replace / remove) a handler for a server→client NOTIFICATION method.
--- `handler(params)` is invoked from the next nvim main-loop pass (schedule_wrap'd) when the
--- server sends `{jsonrpc:"2.0",method:<method>}` (no id). Pass `nil` to remove. Never throws.
---@param method  string   Notification method name (PRD §5.4: "commandsChanged" in v1).
---@param handler fun(params:any?)|nil  Called with msg.params (nil for commandsChanged — empty params omitted on the wire).
function M.on_notification(method, handler)
  if type(method) ~= "string" or method == "" then return end
  if handler == nil then notification_handlers[method] = nil; return end -- remove
  if type(handler) ~= "function" then return end
  notification_handlers[method] = vim.schedule_wrap(handler)  -- last-wins; safe from luv
end
```

Design notes:
- **Last-wins re-registration** (matches S26's idempotent map semantics). Registering twice
  for the same method replaces the handler; no leak of the prior closure.
- **`nil` removes.** Mirrors the "set / clear" idiom; lets S41 detach on teardown if needed.
- **Never throws.** Bad args (non-string method, non-function handler) are silently dropped
  (the never-throws contract S24/S25/S26 all keep).
- **No return value** needed — notifications have no id to return. (Contrast `request` which
  returns the id so the caller can `cancel`.)
- **schedule_wrap at store time** (not at dispatch) — matches S26's `pending[id].cb` and
  avoids re-wrapping on every notification.

**Downstream contract (for S41):**
```lua
require("pi-editor").bridge.on_notification("commandsChanged", function(_params)
  -- clear the cached command list; the next getSuggestions/getCommands re-queries pi.
  cached_commands = nil
end)
```
`params` is `nil` for `commandsChanged` (empty params omitted on the wire — §1.2). S41's
handler ignores it; the API passes whatever the server sent so future notifications with
params work unchanged.

---

## §6 — `close()` hygiene (clear the registry)

S26 extended `M.close()` to drain `pending` + reset `next_id`. S27 adds ONE line: clear the
notification-handler registry so a stale handler does not fire across reconnects.

```lua
-- inside M.close(), alongside the existing pending drain + next_id reset:
notification_handlers = {}   -- clear so a stale handler does not leak across reconnects
```

- `notification_handlers` is a module-level local read as an **upvalue** by `dispatch`.
  Reassigning it (like `state = {...}` in `connect()`) updates the upvalue — dispatch then
  sees the empty table. (Same mechanism as the existing `state` reassignment; verified.)
- This is hygiene, not correctness-critical: the only caller that registers a handler (S41's
  completion.lua) registers it after each successful handshake, so a stale entry is
  immediately overwritten anyway. Clearing in `close()` is defense-in-depth + matches S26's
  "no leak across editor open/close cycles" (PRD §6.7) discipline.
- The drained/registered handlers are user closures — closing them does NOT call them (there
  is nothing to "resolve", unlike request cbs). We just drop the references.

NOTE: `close()` already clears `M.server_info` and drains `pending`; S27's registry clear is
placed in the SAME state-wipe region. `handshake_state` is still NOT cleared here (owned by
`resolve_handshake` via the `pending` bool — see the existing comment).

---

## §7 — Does NOT interfere with request correlation (the interleaving guarantee)

A `commandsChanged` can arrive while a `getSuggestions` is in flight (the server may broadcast
between the request and its response). The branch ordering (§2) guarantees correctness:

1. The response (`{id:"3",result}`) has NO `method` → never enters the S27 branch.
2. The notification (`{method:"commandsChanged"}`) has NO string `id` → never enters the S26
   `pending[msg.id]` branch.
3. Both run in O(1) (a hash lookup + a schedule_wrap'd call). The notification handler is
   deferred to the next nvim loop pass; it does NOT block the response-correlation path.

So a spec case that fires a `getSuggestions`, has the server send `commandsChanged`, THEN
reply to the `getSuggestions`, must see BOTH the notification handler fire AND the request cb
resolve with its own result. (Covered by test case §8 #8.)

---

## §8 — Test matrix (mirror `bridge_request_spec.lua`'s `with_request_server` HOF)

Reuse `bridge_request_spec.lua`'s `with_request_server` + `with_handshaken_server` helpers
verbatim (they already do hello + a mode-keyed server). Add a server mode `"notify"` that,
after handshake, writes a `commandsChanged` notification line (no id, no params):

```lua
-- in the server's request-decoder, OUTSIDE the hello branch:
if opts.mode == "notify" then
  -- after the handshake reply, push a commandsChanged notification (no id, no params)
  if srv_conn and not srv_conn:is_closing() then
    srv_conn:write('{"jsonrpc":"2.0","method":"commandsChanged"}\n')
  end
  return
end
```

(Write the raw JSON line — the server OMITS empty params (§1.2), so the literal must NOT
include `"params"`. This also makes the test assert the exact wire form the client consumes.)

Cases (every Success Criterion → an `it`):

1. **Surface** — `bridge.on_notification` exists and is a function.
2. **Handler invoked** — register a handler; server sends `commandsChanged`; handler fires
   with `params == nil` (empty params omitted on the wire).
3. **schedule_wrap'd / safe** — the handler does a `vim.api`-ish write (e.g. sets a buffer
   var) WITHOUT throwing `E5560` (indirect proof it ran on the nvim loop, not luv).
4. **Exact wire form** — the client does NOT reply (no request line is sent back to the
   server after a notification). Assert the server's request-decoder saw only `hello`.
5. **Last-wins re-registration** — register handler A, then handler B; notification fires B
   only (A is replaced; not leaked).
6. **nil removes** — register a handler, `on_notification(method, nil)`, send notification;
   handler does NOT fire (and no throw).
7. **No handler → silent drop** — send `commandsChanged` with no handler registered; no throw,
   no cb (PRD §11 silent-degrade).
8. **Interleaving** — fire a `getSuggestions` request; server sends `commandsChanged` THEN
   the `getSuggestions` response; BOTH the notification handler fires AND the request cb
   resolves with its own result (the two dispatch paths do not interfere — §7).
9. **close() clears the registry** — register handler, handshake, `close()`, re-handshake
   WITHOUT re-registering, send notification; the OLD handler does NOT fire (stale across
   reconnects). [Hygiene proof.]
10. **Never throws on bad args** — `on_notification(nil, fn)`, `on_notification("", fn)`,
    `on_notification("commandsChanged", 123)` (non-function) — all no-throw no-ops.
11. **Defensive: method + string id not mis-routed** — server sends
    `{"jsonrpc":"2.0","method":"commandsChanged","id":"9","result":{"ok":true}}` (a "request"
    shape the client never expects in v1); the notification handler does NOT fire and no
    response is sent (the `type(msg.id)~="string"` guard — §2).
12. **Generic registry** — a synthetic method `"x/anything"` routes to ITS own handler
    (forward-compat; commandsChanged is the only real one today).
13. **REGRESSION** — `bridge_handshake_spec.lua`, `bridge_request_spec.lua`, `bridge_spec.lua`,
    `jsonlreader_spec.lua`, `smoke.lua` all pass UNCHANGED (dispatch only GAINED a branch;
    `on_notification` is ADDED, no public-signature change).

GOTCHAs for the spec (inherit from bridge_request_spec.lua):
- Do NOT name a spec-local table `pending` (shadows busted's skip fn). Use `got`/`fired`.
- `reset_module()` (close + nil `pi.bridge`) in `before_each`/`after_each` AND inside the HOF.
- `vim.wait(budget, predicate, 5)` — the 5ms poll is load-bearing for deterministic async.
- The server's notification line is written RAW (`'{"jsonrpc":"2.0","method":"commandsChanged"}\n'`)
  to assert the exact no-params wire form (the server OMITS empty params — §1.2).

---

## §9 — Validation commands (verified against this repo's harness)

```bash
# Level 1 — load-check (a syntax error breaks the WHOLE plugin):
cd plugin && nvim --headless --clean -u NORC \
  -c 'luafile lua/pi-editor/bridge.lua' -c 'luafile lua/pi-editor/init.lua' -c 'qa' ; echo "load=$?"

# Level 2 — the NEW spec (the gate):
cd plugin && nvim --headless --clean -u tests/minimal_init.lua \
  -c 'lua require("plenary.busted").run("tests/bridge_notify_spec.lua")' -c 'qa' ; echo "notify=$?"

# Level 2 — REGRESSION siblings (dispatch only gained a branch):
cd plugin && nvim --headless --clean -u tests/minimal_init.lua \
  -c 'lua require("plenary.busted").run("tests/bridge_request_spec.lua")' -c 'qa' ; echo "request=$?"
cd plugin && nvim --headless --clean -u tests/minimal_init.lua \
  -c 'lua require("plenary.busted").run("tests/bridge_handshake_spec.lua")' -c 'qa' ; echo "handshake=$?"
cd plugin && nvim --headless --clean -u tests/minimal_init.lua \
  -c 'lua require("plenary.busted").run("tests/bridge_spec.lua")' -c 'qa' ; echo "bridge=$?"
cd plugin && nvim --headless --clean -u tests/minimal_init.lua \
  -c 'lua require("plenary.busted").run("tests/jsonlreader_spec.lua")' -c 'qa' ; echo "jsonlreader=$?"

# Level 2 — zero-dep smoke (dormant-session invariant — pi.bridge still nil pre-handshake):
cd plugin && nvim --headless --clean -u NORC +"luafile tests/smoke.lua" +qa ; echo "smoke=$?"
```

plenary path verified: `/home/dustin/.local/share/nvim/lazy/plenary.nvim` (from S26 research +
`minimal_init.lua`). Neovim 0.12 verified for `vim.uv` + `vim.json` + `vim.schedule_wrap`
(all built-in). No new runtime deps.