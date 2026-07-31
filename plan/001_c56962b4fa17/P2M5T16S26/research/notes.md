# Research Notes — P2.M5.T16.S26 (`request(method, params, cb)` RPC layer, Lua client)

> Scope: AFTER the S25 handshake publishes `pi.bridge`, add the GENERIC JSON-RPC request
> layer to `bridge.lua`: a `request(method, params, on_result)` that auto-assigns monotonic
> string ids, correlates each response by id via a `pending` map, drops stale/late/duplicate/
> stray responses, fires a per-request luv timeout, and resolves every outstanding callback on
> `close()`. Plus a `cancel(id)` helper for local supersession. This is the SECOND protocol
> consumer of the S24 transport (after the S25 handshake) and the SEAM S30+ (completion) calls.

These notes consolidate three deep-dive research runs (jsonrpc-correlation, luv-timers,
plenary-async-testing). The full subagent outputs are preserved alongside; this file is the
authoritative quick-reference for the PRP.

## 0. The authoritative contracts (READ FIRST)

| Concern | File (repo-relative) | Why it's authoritative |
|---|---|---|
| Transport + the dispatch SEAM (DONE, S24/S25) | `plugin/lua/pi-editor/bridge.lua` | `connect/send/close/on_exit/is_connected` + `handshake()`. Its `dispatch(msg)` (~L237-244) has the literal `-- S26 EXTENSION POINT: if pending[msg.id] then ... end` comment AFTER the `id=="h1"` handshake branch. The handshake branch MUST stay first (so handshake responses are never mis-routed to `pending`). |
| The server that echoes ids (DONE, S8) | `extension/connection.ts` `handleLine` | Request branch: `const reqId = id as string; … sendResponse(sock, reqId, result)` — **the server echoes the client's string `id` verbatim**. A request ALWAYS gets exactly one response (success `result` OR `error`); a handler throw → `-32603`. So correlation-by-id is sound. |
| Server supersession (DONE, S11) | `extension/pi-editor-bridge.ts` `makeGetSuggestionsHandler` + `extension/tests/get-suggestions-handler.test.ts` | The server keeps ONE in-flight `AbortController` per connection; a NEWER `getSuggestions` request ABORTS the prior. **So sending the newer request IS the cancel — there is NO separate `cancel` method.** (protocol.ts `BridgeMethod` has no `cancel`.) |
| Wire types (DONE, S4) | `extension/protocol.ts` | `JsonRpcResponse = {result?}|{error:{code,message}}`. `id` is `string`. `commandsChanged` is the only notification (no id). Request methods: hello/ping/getSuggestions/applyCompletion/shouldTriggerFileCompletion/getCommands/bye. |
| Timing / cancellation | PRD §5.5 | Client applies a per-RPC timeout (`config.rpc_timeout_ms` default 2000) + supersession (ignore stale id). "increment id, ignore any response whose id is not the latest." |
| The `request()` sketch | PRD §7.3 | "expose `request(method, params, cb)` that auto-assigns monotonic ids and drops responses whose id is not the current pending id." **SEE §b BELOW: implement as TWO layers** (transport pending-map + caller latest-id guard). |
| Config knob | `plugin/lua/pi-editor/init.lua` | `rpc_timeout_ms` (default 2000). S26 reads the SAME knob the handshake reads. |
| Lua test pattern | `plugin/tests/bridge_spec.lua`, `plugin/tests/bridge_handshake_spec.lua` | `with_server`/`with_hello_server` HOF: unique socket path, real luv server, decode via jsonlreader, echo responses by id, `vim.wait(budget, predicate, 5)`. |

## 1. Design decision: a `pending` MAP at the transport layer; supersession belongs to the CALLER

**Verdict (validated against JSON-RPC §6 + LSP + this project's method table):** the transport
keeps `pending[id] = {cb, timer}` — a MAP supporting MULTIPLE concurrent outstanding requests.
Supersession (latest-only) is the CALLER's concern (completion.lua S30+ tracks its latest id).

**Why a single "current pending id" at the transport layer is a latent bug:** the bridge has
multiple C→S request methods the client genuinely AWAITS — `applyCompletion` (returns the new
buffer+cursor), `shouldTriggerFileCompletion` (returns bool), `getCommands` (S27),
`ping`/`bye`. If a transport rule "only resolve the response whose id == the latest id" held,
firing `getSuggestions(id 5)` then `applyCompletion(id 6)` then `getSuggestions(id 7)` would
**DROP the legitimate applyCompletion response (id 6)** because 6 ≠ 7 — corrupting the accept
flow. The transport has no business deciding which method is "superseded"; that is domain
knowledge only the caller has.

**Correct layering:**
1. **Transport (`bridge.request`)** — method-agnostic: `pending[id]`, resolve exactly the entry
   whose id matches `msg.id`, clear it, drop unmatched/late/duplicate ids. Per-request timeout.
   `close()` drains all. This makes out-of-order + concurrent requests safe (JSON-RPC §6).
2. **Caller (`completion.lua`, S30+)** — owns supersession: track `latest_suggest_id`; in the
   cb, `if id ~= latest_suggest_id then return end`. This is PRD §5.5's "ignore any response
   whose id is not the latest." The caller MAY call `bridge.cancel(old_id)` to retire a
   superseded request immediately (free the entry + stop its timer) instead of letting its cb
   fire-and-be-ignored.

> PRD §7.3 fuses transport + caller with "drops responses whose id is not the current pending
> id." Implement as the two layers above. The "stale drop" in THIS task's title = the transport
> property that a response for an id NO LONGER in `pending` (already resolved / timed out /
> cancelled / connection reset) is silently dropped.

## 2. JSON-RPC correlation — authoritative references (all live-verified)

- **JSON-RPC 2.0 spec — https://www.jsonrpc.org/specification**
  - `#request_object` §4: `id` MUST be String|Number|NULL; **NULL discouraged** (reserved for
    responses with an unknown id); **Numbers SHOULD NOT contain fractional parts** (binary
    fraction drift). → Our monotonic-int→string ids (`"1","2",…`) are the safest choice.
  - `#notification` §4.1: a request WITHOUT an `id` is a notification → server MUST NOT reply.
    (Our `cancel` is local; no wire notification in v1.)
  - `#response_object` §5: "the response id MUST be the same as the request id" — the
    server-echoes-id contract we correlate on. "If there was an error in detecting the id it
    MUST be Null." → guard `type(msg.id)=="string"` (a server `id:null` on a malformed request
    must not index `pending[nil]` — a Lua error).
  - `#batch` §6: "The Server MAY process [a batch] in any order… Responses MAY be returned in
    any order… The Client SHOULD match contexts based on the **id member**." → out-of-order
    responses are SPEC-GUARANTEED safe; our `pending[msg.id]` lookup is the blessed mechanism.
- **LSP spec 3.17 — https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/**
  - `#request-notification-and-response-ordering`: "the server may decide to use a parallel
    execution strategy and may wish to return responses in a different order than the requests
    were received." → second authority for out-of-order safety.
  - `#cancellation-support-arrow_right-arrow_left`: `$/cancelRequest` + `-32800
    RequestCancelled`; "a cancelled request must still return a response" — **invariant we
    honor**: every outstanding request is resolved exactly once (by response/timeout/close/cancel).
- **`vscode-jsonrpc` — https://github.com/microsoft/vscode-languageserver-node/tree/main/jsonrpc**
  the reference id-keyed client: keeps a map of outstanding handlers keyed by id; an unmatched
  response is logged-and-dropped. Exactly our `pending` map + stale-drop design.

## 3. luv timer lifecycle (the load-bearing gotchas — LIVE-VERIFIED)

- **`:close()` IS REQUIRED to free the libuv handle. `:stop()` alone is NOT enough.** A
  `repeat=0` one-shot auto-STOPS after firing but is NOT closed; the `uv_timer_t` userdata +
  handle persist until `:close()`. Neovim's own `:help vim.uv` example comments
  `timer:close()  -- Always close handles to avoid leaks.`
- **`:close()` on an already-closing handle THROWS.** Guard with `timer:is_closing()`
  (returns true while closing OR once closed). The idempotent safe pair:
  ```lua
  if timer and not timer:is_closing() then timer:stop() end   -- harmless if inactive
  if timer and not timer:is_closing() then timer:close() end  -- frees the handle
  ```
  (Mirror `vim/lsp/client.lua:1428` + `diffview/debounce.lua try_close`.)
- **Timers MUST be `uv.new_timer`, NEVER `vim.defer_fn`, in resolvers** — resolvers run inline
  from the libuv loop (the `read_start` cb / the timer cb); `vim.api.*` throws `E5560` there
  (`:help lua-loop-callbacks`). `vim.schedule_wrap` is the escape hatch.
- **Store `schedule_wrap(cb)` in the pending map** — mirrors `vim/lsp/rpc.lua:324`
  (`self.message_callbacks[message_id] = schedule_wrap(callback)`). Then BOTH the timer-fire
  path AND the `pipe:read_start` response path can invoke the stored callback safely without
  each remembering to schedule. The user's cb (completion.lua) always runs on the safe nvim loop.
- **Leak under rapid churn:** every timer you create you MUST close (response, cancel, timeout
  fire, OR connection close). A debounce-heavy completion client creating a timer per keystroke
  that only `:stop()`s leaks `uv_timer_t` handles. Our `cancel(old_id)` on supersession retires
  the previous timer immediately.
- **Drain on close:** iterate a SNAPSHOT of ids (`for _,id in ipairs(snapshot) do … pending[id]=nil`)
  and stop+close each timer; never delete-during-`pairs` (legal in LuaJIT but snapshot is clearer).

## 4. The `result: null` nuance (LIVE-VERIFIED on Neovim 0.12.4)

`getSuggestions` legitimately returns `null` (no matches). Distinguishing a SUCCESS null from a
MALFORMED response (no `result`, no `error`) matters:

```lua
-- LIVE-VERIFIED:
vim.json.decode('{"id":"1","result":null}')  --> {id="1", result = vim.NIL}   -- rawget -> vim.NIL
vim.json.decode('{"id":"1"}')                 --> {id="1"}                      -- rawget -> nil
vim.NIL ~= nil  --> true      -- so rawget(msg,"result") ~= nil distinguishes present-null from absent
```

So the resolver discriminates: `has_error = type(msg.error)=="table"`; `has_result =
rawget(msg,"result") ~= nil`. Normalize `vim.NIL → nil` before handing `result` to the cb:
```lua
local result = msg.result
if result == vim.NIL then result = nil end   -- getSuggestions null result = nil (no matches)
```
This makes `on_result(nil, nil)` mean "success, no result" (getSuggestions empty) — distinct from
`on_result("malformed response", nil)` for a response with neither result nor error.

## 5. Test strategy (mirrors `bridge_spec.lua` / `bridge_handshake_spec.lua`)

A `bridge_request_spec.lua` with a `with_request_server(opts, spec)` HOF (unique socket path,
real luv server, mode-keyed behavior: `"echo"` reply `{id,result}` by id; `"slow"` never reply;
`"error"` reply `{id,error:{code}}`; `"null"` reply `{id,result:null}`; `"stale"` reply to an
OLD id only after a newer request; `"dup"` reply twice). Drive with `vim.wait(budget, predicate, 5)`.

Cases (each a Success Criterion):
1. exposes `request` + `cancel`.
2. auto-id monotonic + unique + distinct from `"h1"` (numeric strings only).
3. correlation: request → response → `cb(nil, result)`; the wire envelope is exact.
4. out-of-order: fire r1, r2; server replies r2 then r1; each cb gets its OWN result.
5. concurrent: getSuggestions + applyCompletion outstanding; both resolved independently.
6. error response → `cb(err mentioning the code)`.
7. null result → `cb(nil, nil)` (getSuggestions empty).
8. stale drop: shrink `rpc_timeout_ms` to ~40ms; response arrives AFTER timeout → cb fires
   ONCE (timeout); the late response does NOT re-fire cb.
9. duplicate response → cb fires ONCE (entry deleted after first).
10. stray/unknown-id response → dropped (no cb, no throw).
11. per-request timeout (slow server) → `cb(err with "timeout")`.
12. `cancel(id)`: fire request, cancel it → `cb("cancelled")`; a late response does NOT re-fire.
13. `close()` drains pending: fire N requests, `close()` → each `cb("connection closed")`;
    timers closed; `next_id` reset to 0.
14. request before connect / after close → `cb("not connected")`, returns nil.
15. never-throws on bad args (non-function cb, nil method).
16. regression: handshake STILL routes `id=="h1"` first (a handshake then a request).

Gotchas:
- **Shrink `rpc_timeout_ms` per timeout case** (40ms) and restore after (or `after_each`).
  Budget `vim.wait` at ≥ 2×timeout + 100ms (e.g. 500ms for a 40ms timeout).
- **`before_each`/`after_each` call `reset_module()`** (close + nil `pi.bridge`); S26's
  `close()` draining pending + resetting `next_id` makes a fresh case start at id "1".
- **Do NOT name a spec-local table `pending`** — it shadows plenary.busted's global `pending`
  (the test-skip function). Use `pending_reqs` or just observe behavior.
- Exit code is the CI gate: `0cq` pass / `1cq` ≥1 assert fail / `2cq` load error.

## 6. Out of scope (explicitly deferred — do NOT implement here)

- **Completion triggers / accept / Tab** (the CALLER that uses `request` + latest-id guard) → S30/S32/S33.
- **`commandsChanged` notification handling** (cache invalidation) → S27 / S41.
- **A wire `cancel` notification** → not needed (server self-supersedes getSuggestions); local
  `cancel(id)` only. Add a wire notification only if a future task proves the server needs it.
- **The one-time `vim.notify` on failure** (UX) → S39 (PRD §11).
- **`bye` on graceful exit** (autosave + disconnect) → S38.
- **coords.lua** (byte↔UTF-16) → S28/S29 (`request` carries no cursor coordinates itself).

## 7. External URLs (quick index)

- JSON-RPC 2.0: https://www.jsonrpc.org/specification (`#request_object`, `#response_object`, `#batch`, `#notification`)
- LSP 3.17: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/
  (`#request-notification-and-response-ordering`, `#cancellation-support-arrow_right-arrow_left`)
- vscode-jsonrpc (reference client): https://github.com/microsoft/vscode-languageserver-node/tree/main/jsonrpc
- luv docs (timers): https://github.com/luvit/luv/blob/master/docs.md (uv_timer_t + uv_handle_t: close/is_closing)
- Neovim lua.txt: https://neovim.io/doc/user/lua.html (`#vim.wait()`, `#vim.uv`, `#vim.schedule_wrap()`, `*E5560*`)
- plenary.busted: https://github.com/nvim-lua/plenary.nvim/blob/master/lua/plenary/busted.lua