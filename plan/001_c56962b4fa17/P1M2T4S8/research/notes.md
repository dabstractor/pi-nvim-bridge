# Research Notes — onConnection handler (P1.M2.T4.S8)

> Work item **P1.M2.T4.S8** — "onConnection handler — accept, wire reader,
> dispatch, write responses". Parent task **P1.M2.T4 = "JSONL framing &
> connection handling"** has two halves: **S7** = framing (DONE →
> `extension/jsonl-reader.ts`) and **S8** = connection handling (THIS task).
> This is the **TypeScript / pi-extension side** (the Lua `bridge.lua` client is
> P2.M5 — separate component).

The governing spec is PRD §5 (IPC Protocol) — §5.3 envelopes/handshake, §5.4
methods table, §5.5 timing/cancellation — and §6.5 (request-handling skeleton).
This research locks the module layout, the dispatch pattern, the task boundary
(S8 vs S9/S10/S11–S14/S15), and the test design. Verified live 2025-07-18.

---

## 0. Environment (verified live — identical to S7)

| Tool | Path / version | Note |
|---|---|---|
| `tsc` | 5.9.3 | type gate (Level 1) |
| `node` | v26.4.0 | runs node:test (Level 2) |
| jiti register | `…/pi-coding-agent/node_modules/jiti/lib/jiti-register.mjs` | house TS loader (all existing suites) |
| @types/node | `…/pi-coding-agent/node_modules/@types/node` | `net.Socket`/`EventEmitter`/`Buffer` types |

`tsconfig.json` include today (post-S7): `["pi-editor-bridge.ts", "protocol.ts",
"jsonl-reader.ts", "tests/**/*.ts"]`. S8 appends `"connection.ts"` (the
IDENTICAL one-line additive edit S4/S7 made; NO `compilerOptions` change — the
transitive `node:*` resolution proven in S7's research §3 still holds).

---

## 1. The S8 contract — what ships, what's deferred

**S8 ships (the title-named deliverable):** the "connection handling" half of
P1.M2.T4 — for each accepted `net.Socket`, (a) attach the S7 JSONL reader, (b)
parse each line + narrow to a JSON-RPC envelope, (c) dispatch to a per-method
handler registry, (d) write JSON-RPC responses/notifications back via
`serializeJsonLine`, and (e) own the socket `error`/`close` lifecycle (detach
reader, no crash). The registry starts **EMPTY** in S8 — S9–S14 populate it.

**S8 does NOT do (later tasks):**
- **S9** `hello` handshake — token validation (the success/error+close reply).
- **S10** reject every method before a valid `hello`.
- **S11–S14** the method handlers themselves (getSuggestions /
  applyCompletion / shouldTriggerFileCompletion / ping+bye+getCommands).
- **S15** formal per-handler try/catch → canonical JSON-RPC error codes.

**The split with S15 (resolved):** S8 owns the **dispatch loop's** error safety
net — a `JSON.parse` throw → `-32700` parse error; a registered-handler throw →
`-32603` internal error (so a request never hangs waiting for a response that
never comes, and an unhandled-rejection never crashes pi). S15 then audits each
handler (S11–S14) to catch its **own domain errors** into proper JSON-RPC error
responses *before* they reach S8's safety net. Non-overlapping: S8 = framing +
dispatch-layer error wrapping; S15 = per-handler-domain-error wrapping. This is
verified necessary: without the loop-level try/catch, a malformed line or a
throwing handler is an unhandled async rejection → violates PRD §6.7 "never
throws from handlers".

---

## 2. Module decision: NEW `extension/connection.ts` (NOT inline)

**Decision: create `extension/connection.ts`** (sibling to `jsonl-reader.ts`),
and `pi-editor-bridge.ts` IMPORTS `onConnection` from it. Rationale:
1. **Mirrors the S7 precedent exactly.** S7 split framing into a separate,
   independently-testable module (`jsonl-reader.ts`); S8 splits connection
   handling the same way. The two halves of P1.M2.T4 become two sibling modules.
2. **Independently unit-testable** (PRD §14 spirit). The dispatch logic
   (parse → narrow → route → write) is exercised directly with a fake socket,
   with no `net.Server`/session-state in the way.
3. **No import cycle.** `connection.ts` imports ONLY `jsonl-reader.ts`
   (values: `attachJsonlLineReader`, `serializeJsonLine`) + `protocol.ts`
   (type-only: the JSON-RPC envelopes). It does NOT import `pi-editor-bridge.ts`,
   so `pi-editor-bridge.ts` → `connection.ts` is one-directional. (Handlers
   S9–S14, registered from `pi-editor-bridge.ts`, close over `getToken()` /
   `getProvider()` *in that module* — see §5 — so `connection.ts` never needs to
   reach back.)
4. **Clean extension points** for S9–S14: a module-level handler `Map` +
   `registerBridgeHandler(method, fn)`, and a per-connection `ConnectionState`
   (`handshakeComplete: false`) that S9 sets true and S10 gates on.

`pi-editor-bridge.ts` change is MINIMAL: delete the local `function
onConnection(_sock)` placeholder, add `import { onConnection } from
"./connection.ts"`, and the existing `__deps.createServer((sock) =>
onConnection(sock))` line now calls the imported function. (S5's test still
passes — it mocks `createServer` and only asserts the listen arg / chmod / token;
it never invokes the connection callback.) The now-unused `type Socket` import in
`pi-editor-bridge.ts` is removed (`noUnusedLocals` is OFF so it wouldn't error,
but cleanliness).

---

## 3. pi's authoritative dispatch pattern (mirrored from rpc-mode.ts)

pi's RPC engine is **stdin-driven** (`rpc-mode.ts:784` does
`attachJsonlLineReader(process.stdin, …)`), NOT a `net.createServer` socket
server — so S8's **socket** connection handling has no direct pi mirror. But
pi's **parse → dispatch → write → error** PATTERN (`rpc-mode.ts:724–800`) is the
authoritative shape S8 mirrors:

```ts
// pi's handleInputLine (rpc-mode.ts:724) — the shape S8's handleLine mirrors
const handleInputLine = async (line: string) => {
  let parsed: unknown;
  try { parsed = JSON.parse(line); }             // (A) parse try/catch
  catch (parseError) { output(error(undefined, "parse", …)); return; }  // → -32700
  // … pi-specific extension_ui_response narrowing …
  const command = parsed as RpcCommand;
  try {
    const response = await handleCommand(command);  // (B) dispatch to handler
    if (response) output(response);                  // (C) write success
  } catch (commandError) {                           // (D) handler-throw → error resp
    output(error(command.id, command.type, …));
  }
};
// Wiring (rpc-mode.ts:784): fire-and-forget async — `void handleInputLine(line)`
```

**S8 mirrors this** for the bridge: (A) `JSON.parse` in its own try/catch →
`-32700`; (B) dispatch to `handlers.get(method)`; (C) success → write
`{jsonrpc,id,result}`; (D) handler throw OR unknown method → write error. Two
differences from pi: (1) **id-based correlation** — pi keys by `command.type`;
the bridge keys by the JSON-RPC `method` string AND only writes a response when
the message has an `id` (requests); **notifications** (no `id`) get NO response
(JSON-RPC 2.0); (2) **fire-and-forget** — `void handleLine(sock, state, line)`
with the loop-level catch as the safety net (S8), per-handler catch as S15.

---

## 4. JSON-RPC 2.0 envelope narrowing (from protocol.ts S4)

`protocol.ts` already defines (post-S4) the raw envelopes S8 narrows into:
- `JsonRpcRequest` = `{ jsonrpc:"2.0"; id:string; method:string; params?:unknown }`
- `JsonRpcResponse` = success `{jsonrpc,id,result?}` | error `{jsonrpc,id,error:{code,message}}`
- `JsonRpcNotification` = `{ jsonrpc:"2.0"; method:string; params?:unknown }` (NO id)
- Error codes (per spec, cited in protocol.ts §A): `-32700` parse, `-32600`
  invalid request, `-32601` method not found, `-32602` invalid params, `-32603`
  internal error. PRD §5.3 uses `-32600` "bad token" for S9's handshake failure.

**S8 narrowing rules** (the load-bearing, error-prone part):
1. `typeof parsed !== "object" || parsed === null || !("method" in parsed)` →
   not a request/notification → if it has no usable `id`, emit `-32600` invalid
   request with `id: null` (JSON-RPC: a response is always sent for a malformed
   request when an id can be inferred; otherwise id is null). S8 keeps this
   conservative: invalid envelope → `-32600` with the parsed `id` if it's a
   string, else `id: null`.
2. `"id" in parsed && typeof parsed.id === "string"` → **request** → dispatch,
   ALWAYS write a response (success result OR error).
3. no string `id` → **notification** → dispatch (call handler if registered),
   write NO response (JSON-RPC 2.0: notifications expect no reply).
4. unknown method: request → `-32601` method not found; notification → silently
   no-op (no handler, no response — matching JSON-RPC notification semantics).

**id type:** PRD §5.3 / protocol.ts restrict bridge `id` to `string` (not
number/null). S8 narrows accordingly: a numeric/null `id` is treated as a
malformed request (`-32600`) for robustness — the Neovim client (P2.M5) only
ever sends string ids.

---

## 5. Handler registry + per-connection state design

```ts
// connection.ts — module-level (shared across all connections; handlers don't vary per conn)
export interface ConnectionState { handshakeComplete: boolean; }   // S9 sets true; S10 gates on it
export type MethodHandler = (params: unknown, state: ConnectionState) => Promise<unknown> | unknown;

const handlers = new Map<string, MethodHandler>();
export function registerBridgeHandler(method: string, fn: MethodHandler): void { handlers.set(method, fn); }
// test seams (registry isolation): reset + snapshot — matching the __deps idiom's spirit
export function __resetHandlersForTest(): void { handlers.clear(); }
export function __hasHandlerForTest(method: string): boolean { return handlers.has(method); }
```

- **Per-connection state** (`ConnectionState`) is created fresh inside each
  `onConnection(sock)` call (closure-captured) — two sockets get two independent
  states; no module-level connection registry (v1 supports one robustly; multiple
  is best-effort per PRD §5.3 "at least one concurrent connection").
- **Handlers are registered from `pi-editor-bridge.ts`** (S9–S14), NOT from
  `connection.ts` — so each handler closure references `getToken()` /
  `getProvider()` (same module) without `connection.ts` importing
  `pi-editor-bridge.ts`. Registration site (module-init vs `session_start` after
  `startBridge`) is left to S9; both are safe (`Map.set` is idempotent; getters
  read live state so `/reload` re-registration captures the new provider).
- **S8 ships an EMPTY registry.** The only dispatch behaviors S8 exercises:
  unknown-method request → `-32601`; unknown notification → silent; a
  test-registered handler → dispatched + response written.

---

## 6. Socket write / error / close semantics (the lifecycle half)

- **Write:** `sock.write(serializeJsonLine(envelope))` returns a boolean
  (false = internal buffer full → wait for `'drain'`). Bridge responses are tiny
  (autocomplete items); backpressure is a non-issue for v1 → S8 calls `.write`
  and ignores the return. Documented as a v1 simplification (PRD §15 future).
  Mirror: pi waits for stdout backpressure, but stdout ≠ socket; the bridge's
  payloads are small and frequent-aborted (S11's AbortController), so skip.
- **`error` event is FATAL if unhandled** — a `net.Socket` emitting `'error'`
  with no listener THROWS and crashes the process (Node EventEmitter contract —
  same as the `net.Server` 'error' S6 handled). S8 MUST attach
  `sock.on("error", …)`: log (NOT the token — PRD §12), `detach()` the reader,
  `sock.destroy()`. Never rethrow.
- **`close` event** fires on normal disconnect AND after `'error'`. S8 attaches
  `sock.on("close", …)` → `detach()` (idempotent; `EventEmitter.off` is a safe
  no-op if already removed) so no listener leaks across the connection churn
  that PRD §6.7/§11 foresee (many editor open/close cycles per session).
- **`detach()`** is the S7 reader's returned cleanup fn — removes ONLY the
  reader's own `data`/`end` listeners; S8's own `error`/`close` listeners are
  removed by `sock.destroy()`/close itself.

---

## 7. Test design (node:test + jiti — house convention; NOT vitest)

Mirror `bridge-lifecycle.test.ts`'s **mocked-unit + real-integration** split. A
**fake socket** = `Object.assign(new EventEmitter(), { write(s:string){writes.push(s);return true;} })`
covers `write` + `error`/`close` without a real `net.Server`. ONE real Unix
socket-pair test proves end-to-end framing.

**Suite (~9 tests):**
1. `sendResponse(sock,id,result)` → writes `{"jsonrpc":"2.0","id":…,"result":…}\n` (LF-terminated).
2. `sendError(sock,id,code,msg)` → writes `{"jsonrpc":"2.0","id":…,"error":{"code":…,"message":…}}\n`.
3. `sendNotification(sock,method,params)` → writes `{"jsonrpc":"2.0","method":…,"params":…}\n` (NO id).
4. `handleLine` + registered handler: register a fake handler, feed a request line, assert handler called with `params`, assert success response written.
5. `handleLine` method-not-found: request for unregistered method → `-32601` response.
6. `handleLine` notification (no id): unregistered notification → NO response written.
7. `handleLine` registered notification handler: handler called, NO response.
8. `handleLine` malformed JSON (`"not json"`) → `-32700` parse error response, NO throw.
9. `handleLine` registered handler THROWS → `-32603` internal error response, NO throw (S8 safety net; S15 formalizes per-handler).
10. `handleLine` non-object / invalid envelope (`42`, `{}`) → `-32600` invalid request (id null), no crash.
11. `onConnection` socket `'error'` → reader detached, NO throw (EventEmitter fake).
12. `onConnection` socket `'close'` → reader detached, no listener leak.
13. **REAL integration**: `net.createServer(c => onConnection(c)).listen(sockpath)` + `net.connect`; client `write(serializeJsonLine(request))`; assert client reads the `-32601` response (registry empty); then register a handler, repeat, assert success response.

Each test calls `__resetHandlersForTest()` in a `try/finally` (registry is
module-level). `node:test` runs top-level `test(...)` sequentially (house default).

**Real-socket helper** (one-off, in the test file): wrap the connect→write→read
into an `async function roundTrip(reqLines, handlerSetup?)` returning the parsed
responses the client received (collect via `attachJsonlLineReader` on the client
socket). Mirrors `bridge-lifecycle`'s `await once(server,"listening")` +
`net.connect` idiom.

---

## 8. Validation commands (verified working in this repo)

```bash
# Level 1 — type-check. connection.ts imports node:net (Socket type), node:events
#   (type-only via EventEmitter), jsonl-reader.ts, protocol.ts — all resolve via the
#   unchanged transitive @types/node (S7 research §3). Expected: exit 0, NO output.
tsc --noEmit -p extension/tsconfig.json

# Level 2 — node:test via jiti. Expected: exit 0, ℹ fail 0.
JITI_REG=/home/dustin/.local/lib/node_modules/@earendil-works/pi-coding-agent/node_modules/jiti/lib/jiti-register.mjs
node --import "$JITI_REG" extension/tests/connection.test.ts

# Level 2 regression — all 6 prior suites still green (S8 ADDS 1 module + 1 test +
#   1 include line + a minimal pi-editor-bridge.ts edit; nothing they read changes).
for t in provider-capture mode-guard protocol bridge-lifecycle bridge-lifecycle-wiring jsonl-reader; do
  echo "--- $t ---"; node --import "$JITI_REG" "extension/tests/$t.test.ts" 2>/dev/null | grep -E "^ℹ (pass|fail)"
done

# Level 3 — regression: extension still loads cleanly under pi (connection.ts IS now
#   imported by the entry point, so this proves S8's wiring didn't break the load path).
pi --no-extensions -e ./extension/pi-editor-bridge.ts --print "ok" 2>&1 \
  | grep -iE "error|cannot|fail|throw|TypeError" && echo FAIL || echo PASS
```

---

## 9. Scope summary

**S8 ships:** NEW `extension/connection.ts` (onConnection + handleLine +
sendResponse/sendError/sendNotification + ConnectionState + MethodHandler +
handler registry + registerBridgeHandler + test seams); MODIFY
`extension/tsconfig.json` (append `"connection.ts"` to include); MODIFY
`extension/pi-editor-bridge.ts` (import + delete placeholder + drop unused
`type Socket`); NEW `extension/tests/connection.test.ts` (~9–13 tests).

**S8 does NOT ship:** hello handshake (S9), handshake gate (S10), method
handlers (S11–S14), per-handler error wrapping (S15), env advertisement (S16),
commandsChanged (S17), the Lua client (P2.M5). The registry is empty; S9–S14
fill it.
