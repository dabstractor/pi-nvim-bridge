---
name: "P1.M2.T4.S8 — onConnection handler: accept, wire JSONL reader, parse + dispatch, write responses"
description: |
  Land the **connection-handling** half of parent task **P1.M2.T4 ("JSONL framing
  & connection handling")** as a NEW self-contained module
  `extension/connection.ts` (the sibling of S7's `extension/jsonl-reader.ts`,
  which owns the *framing* half). For each `net.Socket` the bridge server
  accepts, this module: (1) **wires** S7's `attachJsonlLineReader(sock,
  onLine)` so incoming bytes are framed into complete LF-delimited lines; (2)
  for each line, **parses** it with `JSON.parse` (try/catch → JSON-RPC `-32700`
  parse error on a malformed line) and **narrows** it to a JSON-RPC 2.0 envelope
  (request = has a string `id`; notification = no `id`) using the types in S4's
  `extension/protocol.ts`; (3) **dispatches** to a module-level per-method
  handler registry (`Map<string, MethodHandler>` + `registerBridgeHandler`) —
  registered handler → success result response (`{jsonrpc,id,result}`) or, on a
  handler throw, a `-32603` internal-error response (the dispatch-layer safety
  net so a request never hangs and pi never crashes an unhandled rejection);
  unregistered request → `-32601` method-not-found; unregistered notification →
  silent no-op (no response — JSON-RPC notification semantics); (4) **writes**
  responses/notifications back via S7's `serializeJsonLine` + `sock.write`; (5)
  owns the per-socket `error`/`close` lifecycle — `sock.on("error")` logs (NEVER
  the token — PRD §12) + detaches the reader + `sock.destroy()` (an unhandled
  socket `'error'` THROWS and crashes pi — same Node EventEmitter contract S6
  handled for the `net.Server`); `sock.on("close")` detaches the reader
  idempotently so no listener leaks across the many editor open/close cycles one
  session sees (PRD §6.7). The module ships a per-connection `ConnectionState`
  (`{ handshakeComplete: boolean }`) that **S9 sets true** on a valid `hello` and
  **S10 gates every non-hello method on**; S8 creates it fresh per connection
  (`handshakeComplete:false`) but does NOT yet gate (S10's job) and does NOT yet
  implement `hello`/token validation (S9's job). The handler registry starts
  **EMPTY** in S8 — **S9** registers `hello`, **S11–S14** register
  getSuggestions/applyCompletion/shouldTriggerFileCompletion/ping+bye+getCommands,
  **S15** formalizes per-handler try/catch into canonical JSON-RPC error codes;
  S8 is the plumbable dispatch skeleton those tasks hang handlers off. The module
  imports ONLY `./jsonl-reader.ts` (values) + `./protocol.ts` (types-only) — it
  does NOT import `pi-editor-bridge.ts`, so `pi-editor-bridge.ts → connection.ts`
  is one-directional and there is no import cycle; handlers are registered FROM
  `pi-editor-bridge.ts` (S9–S14) where they close over `getToken()`/
  `getProvider()` in the same module. The change to `pi-editor-bridge.ts` is
  MINIMAL: delete the local `function onConnection(_sock): void` S5/S7 left as a
  placeholder, add `import { onConnection } from "./connection.ts"`, so the
  existing `__deps.createServer((sock) => onConnection(sock))` line now calls the
  imported function (S5's test still passes — it mocks `createServer` and only
  asserts the listen arg/chmod/token, never invoking the connection callback);
  and drop the now-unused `type Socket` from the `node:net` import. The test
  suite (~9–13 tests, `node:test`+jiti — the house convention, NOT vitest) uses a
  fake socket (`Object.assign(new EventEmitter(), {write(s){writes.push(s);return
  true;}})`) for the mocked dispatch/response/error-close unit tests, plus ONE
  real Unix-socket-pair integration test (`net.createServer(c =>
  onConnection(c)).listen(sockpath)` + `net.connect`; client writes a request,
  reads the response) proving end-to-end framing. This task is NARROW and
  ADDITIVE: it does NOT implement `hello`/token (S9), the handshake gate (S10),
  any method handler (S11–S14), per-handler error wrapping (S15), env
  advertisement (S16), commandsChanged (S17), or the Lua `bridge.lua` client
  (P2.M5).
---

## Goal

**Feature Goal**: Land the bridge's **connection-handling** layer so that every
`net.Socket` pi's bridge server accepts is transformed from a raw byte stream
into a live JSON-RPC 2.0 dispatch loop: bytes → S7 lines → parsed JSON-RPC
envelopes → routed to (a placeholder-empty) handler registry → JSON-RPC
responses/notifications written back, with the socket's `error`/`close` lifecycle
owned so a malformed line, a throwing handler, a dead socket, or a disconnect
**never crashes pi** and **never leaks a listener**. This is the second half of
parent task P1.M2.T4 — S7 (DONE) built the *framing* (`jsonl-reader.ts`); S8
(THIS) builds the *connection handling* (`connection.ts`). With both halves done,
**S9–S14 only need to `registerBridgeHandler(method, fn)`** to turn the bridge
into a functioning autocomplete RPC server — no more framing/dispatch/lifecycle
work for them.

**Deliverable** (all under `extension/`):
1. **CREATE** `extension/connection.ts` — a self-contained module exporting
   `onConnection(sock: Socket): void` (the entry point `pi-editor-bridge.ts`
   wires into `createServer`), `handleLine(sock, state, line): Promise<void>`
   (the parse → narrow → dispatch → write unit), `sendResponse` /
   `sendError` / `sendNotification` (response writers via S7's
   `serializeJsonLine`), `registerBridgeHandler(method, fn)` + the
   `MethodHandler` type (the extension point S9–S14 use), `ConnectionState`
   (the per-connection state S9/S10 consume), and `__resetHandlersForTest` /
   `__hasHandlerForTest` test seams (registry isolation). Imports ONLY
   `./jsonl-reader.ts` (values) + `./protocol.ts` (type-only) — NO
   `pi-editor-bridge.ts` import (avoids cycles). Mode-A JSDoc with
   `STATUS (P1.M2.T4.S8)` markers + the S7-mirror + S9–S14 forward-refs.
2. **MODIFY** `extension/tsconfig.json` — append `"connection.ts"` to the
   existing `include` array (the ONLY change; `compilerOptions` byte-identical —
   the transitive `node:*` resolution proven in S7's research §3 still holds).
3. **MODIFY** `extension/pi-editor-bridge.ts` — (a) add
   `import { onConnection } from "./connection.ts"`; (b) delete the local
   `function onConnection(_sock: Socket): void { /* TODO(S8) … */ }` placeholder
   S5/S7 left; (c) the existing `__deps.createServer((sock) => onConnection(sock))`
   line inside `startBridge` now resolves to the IMPORTED `onConnection`
   unchanged; (d) drop the now-unused `type Socket` from
   `import { createServer, type Server, type Socket } from "node:net"` →
   `import { createServer, type Server } from "node:net"`.
4. **CREATE** `extension/tests/connection.test.ts` — a `node:test`+jiti suite
   matching the S2/S3/S4/S5/S6/S7 conventions: ~9–13 tests using a fake
   `EventEmitter`-based socket for dispatch/response/error-close unit tests +
   ONE real Unix-socket-pair integration test.

**Success Definition**:
- `tsc --noEmit -p extension/tsconfig.json` → exit 0, **no output** (the new
  module's `node:net`/`node:events`/`Buffer` resolve transitively under the
  UNCHANGED `compilerOptions` — same mechanism S7 verified).
- `node --import <pi>/node_modules/jiti/lib/jiti-register.mjs extension/tests/connection.test.ts`
  → exit 0, `ℹ fail 0` (the method-not-found, parse-error, handler-throw, and
  socket-error tests prove S8 never crashes pi and never hangs a request).
- All 6 pre-existing suites still green (regression): `provider-capture.test.ts`
  (S2), `mode-guard.test.ts` (S3), `protocol.test.ts` (S4),
  `bridge-lifecycle.test.ts` (S5), `bridge-lifecycle-wiring.test.ts` (S6),
  `jsonl-reader.test.ts` (S7) — S8 is additive (1 new module + 1 new test +
  1-line `include` edit + a minimal `pi-editor-bridge.ts` wiring edit that S5's
  test is robust to).
- **Regression that S8's wiring is live:** `pi --no-extensions -e
  ./extension/pi-editor-bridge.ts --print "ok"` exits 0 with no error lines.
  (Unlike S7 — whose module was dead code until S8 — `connection.ts` IS now
  imported by the entry point, so this run proves S8's import + placeholder
  deletion didn't break the load path.)
- The `// TODO(S8): wire the JSONL reader + RPC dispatcher` comment in
  `pi-editor-bridge.ts` is GONE (replaced by the import); the `onConnection`
  name now resolves to `connection.ts`'s export.

## User Persona (if applicable)

**Target User**: The bridge-extension author and the downstream implementers of
**S9** (`hello` handshake), **S10** (handshake gate), and **S11–S14** (the RPC
method handlers). This task is the dispatch skeleton all of them hang off.

**Use Case**: When S9 implements the `hello` handshake, it writes ONE line:
`registerBridgeHandler("hello", async (params, state) => { if (params.token !==
getToken()) throw new RpcError(-32600,"bad token"); state.handshakeComplete =
true; return {ok:true, serverVersion:…, cwd:…, fdAvailable:…}; });` — and S8's
`handleLine` already parses the incoming `{"jsonrpc":"2.0","id":"h1","method":
"hello","params":{…}}` line, calls it, and writes the `result` response back.
When S10 adds the handshake gate, it writes ONE guard inside `handleLine`'s
dispatch (or a wrapper): `if (!state.handshakeComplete && method !== "hello")
return sendError(sock, id, -32600, "handshake required")`. S8 has built the
state + registry + dispatch + writers so none of S9–S14 re-implements framing,
parsing, response envelopes, or socket lifecycle.

**Pain Points Addressed**:
- Without S8, the `onConnection(sock)` placeholder accepts a connection and then
  SILENTLY drops every byte (the S5/S7 placeholder is a no-op body) — there is no
  path from "bytes on the socket" to "a handler runs". S9–S14 cannot be built
  until that path exists.
- Without a parse try/catch, a malformed line (a half-written client, a
  `\r`-only line, a test typo) throws inside `JSON.parse` → an unhandled async
  rejection → pi crashes (violates PRD §6.7 "never throws from handlers"). S8's
  `-32700` parse-error response makes malformed input a logged no-op.
- Without the dispatch-layer handler-throw catch, a handler that throws (and
  until S15 some will) leaves a request HANGING — the client (P2.M5's
  `bridge.lua`) waits for its RPC timeout with no response. S8's `-32603` safety
  net always writes a response.
- Without `sock.on("error")`, a socket `'error'` (client killed, ECONNRESET,
  broken pipe) THROWS and crashes pi (Node EventEmitter contract). S8 handles
  it like S6 handled the server's `'error'`.
- Without `sock.on("close")` + `detach()`, every connection leaks two listeners
  (`data`/`end`) on the socket; across one pi session's many editor open/close
  cycles (PRD §6.7 "survives multiple editor open/close cycles") this is a slow
  EventEmitter MaxListenersExceededWarning / leak.

## Why

- **The dispatch foundation of the whole IPC protocol.** Every byte S7 frames
  and every envelope S4 types only becomes useful once S8 turns a line into a
  dispatched handler call + a written response. S7 (framing) + S8 (connection
  handling) are the two halves of P1.M2.T4; until S8 lands, the bridge accepts
  connections but does nothing with them. After S8, S9–S14 are pure
  handler-registration tasks.
- **Robustness is a hard PRD requirement, not a nicety.** PRD §6.7 ("never
  throws from handlers", "survives multiple editor open/close cycles", "never
  blocks pi's event loop synchronously") and §11 ("pi process dies while editor
  open → socket closes; plugin detects EOF") both demand that malformed input,
  throwing handlers, and dead/disconnecting sockets NEVER crash pi and NEVER
  leak. S8's parse try/catch, handler-throw safety net, and `error`/`close`
  lifecycle handlers are what make that true for the connection layer.
- **Faithfulness to pi's dispatch pattern.** PRD §1 promises completion
  "byte-for-byte identical to pi's TUI", and the bridge is meant to feel like
  pi's own RPC engine. pi's `rpc-mode.ts` (`handleInputLine`, lines 724–800)
  parses with a try/catch, dispatches with a try/catch, and writes the error on
  throw — S8 mirrors that exact shape (see research §3), so the bridge's
  request/error semantics match pi's rather than being reinvented.
- **Zero-dependency, near-zero-config increment.** The module uses only Node
  builtins (`node:net` type-only via the passed-in `Socket`, `node:events` for
  the test fake) + the two sibling modules — honoring PRD §6.7's "no npm runtime
  dependencies". The only config change is one line in `include` (the
  established S4/S7 pattern). It introduces one new piece of module state (the
  handler registry) which is dead-but-testable until S9 registers the first
  handler, so it cannot regress any existing behavior.

## What

One new module, one one-line `include` edit, a minimal `pi-editor-bridge.ts`
wiring edit, one new test file. No new process.env writes, no new env var, no
socket bind (that's S5), no env advertisement (S16), no handler implementations
(S9–S14).

### Success Criteria

- [ ] `extension/connection.ts` EXISTS and exports `onConnection`,
      `handleLine`, `sendResponse`, `sendError`, `sendNotification`,
      `registerBridgeHandler`, `MethodHandler`, `ConnectionState`,
      `__resetHandlersForTest`, `__hasHandlerForTest` with the EXACT signatures
      below.
- [ ] `onConnection(sock)` attaches S7's `attachJsonlLineReader(sock, line =>
      handleLine(sock, state, line))`, creates a fresh `ConnectionState`
      (`handshakeComplete:false`), and attaches `sock.on("error", …)` (log +
      detach + `sock.destroy()`, NO rethrow) + `sock.on("close", …)` (detach).
- [ ] `handleLine` parses with try/catch (`-32700` on throw), narrows the
      envelope (request = string `id`; notification = no string `id`; invalid →
      `-32600`), dispatches to `handlers.get(method)`, writes a `result`
      response for a registered request handler's return, a `-32603` response for
      a registered handler's throw, a `-32601` response for an unregistered
      request, and NOTHING for a notification (registered or not).
- [ ] `sendResponse`/`sendError`/`sendNotification` produce strict LF-terminated
      JSON-RPC 2.0 envelopes via `serializeJsonLine` + `sock.write`.
- [ ] The handler registry is module-level, starts EMPTY, and is populated only
      via `registerBridgeHandler` (S8 registers NONE — S9–S14 do).
- [ ] `connection.ts` imports ONLY `./jsonl-reader.ts` (values) + `./protocol.ts`
      (type-only) — NO `pi-editor-bridge.ts` import (verified: no import cycle).
- [ ] `extension/tsconfig.json` `include` contains `"connection.ts"` (the ONLY
      change; `compilerOptions` byte-identical).
- [ ] `extension/pi-editor-bridge.ts` imports `onConnection` from
      `./connection.ts`, the local placeholder + its `// TODO(S8)` comment are
      DELETED, the `__deps.createServer((sock) => onConnection(sock))` line is
      UNCHANGED, and the now-unused `type Socket` import is dropped.
- [ ] `extension/tests/connection.test.ts` EXISTS, uses `node:test` +
      `node:assert/strict` + a fake `EventEmitter` socket (NOT vitest), and
      asserts at minimum: response-writer envelope shapes; registered-handler
      success response; method-not-found (`-32601`); notification (no response);
      parse-error (`-32700`, no throw); handler-throw (`-32603`, no throw);
      invalid-envelope (`-32600`); socket `error` detaches + no throw; socket
      `close` detaches; ONE real Unix-socket-pair end-to-end round-trip.
- [ ] `tsc --noEmit -p extension/tsconfig.json` → exit 0, no output.
- [ ] `node --import "$JITI_REG" extension/tests/connection.test.ts` → exit 0,
      `ℹ fail 0`.
- [ ] All 6 pre-existing suites report `ℹ fail 0` (regression).
- [ ] `pi --no-extensions -e ./extension/pi-editor-bridge.ts --print "ok"`
      exits 0 with no error lines.

## All Needed Context

### Context Completeness Check

_Pass test_: An agent who has never seen this repo, given the current
`extension/pi-editor-bridge.ts` (post-S6), `extension/jsonl-reader.ts` (post-S7),
`extension/protocol.ts` (post-S4), `extension/tsconfig.json`, and this PRP, can
(1) create `connection.ts` from the pinned reference body below (every import,
signature, and line of dispatch logic is reproduced — no guessing), (2) make the
one-line `include` edit + the minimal `pi-editor-bridge.ts` wiring edit, (3)
write the test from the supplied skeletons (fake-socket unit tests + real-socket
integration test), and (4) run the exact validation commands to green — with
every load-bearing claim (the parse/narrow/dispatch rules, JSON-RPC error codes,
why `sock.on("error")` is FATAL, the registry/state split, the no-cycle import
discipline, S8 vs S9/S10/S11–S14/S15 boundaries) cited and verified in
`research/notes.md`.

### Documentation & References

```yaml
# MUST READ — the sibling framing module S8 consumes (post-S7, the live source)
- file: extension/jsonl-reader.ts
  why: S8 imports BOTH exports. attachJsonlLineReader(stream, onLine): detach
    frames sock bytes into complete LF-delimited \r-stripped string lines — S8
    wires it inside onConnection. serializeJsonLine(value): string (=
    `${JSON.stringify(value)}\n`) is the LF-terminator S8's sendResponse/
    sendError/sendNotification use to write envelopes. The reader emits RAW
    string lines (no JSON.parse / narrowing / dispatch — ALL of that is S8).
  pattern: "attachJsonlLineReader(sock, (line) => handleLine(sock, state, line)) →
    returns a detach() to call from sock.on('error')/sock.on('close')"
  critical: |
    The reader attaches 'data' AND 'end' ONLY — it does NOT attach 'error'/'close'.
    Those are S8's job (connection lifecycle). The detach fn removes ONLY the
    reader's own data/end listeners (EventEmitter identity); S8 calls it from its
    own sock.on('error')/sock.on('close') handlers.

# MUST READ — the JSON-RPC 2.0 type contract S8 narrows into (post-S4)
- file: extension/protocol.ts
  why: provides the EXACT envelope shapes + error codes S8 emits. §A: JsonRpcRequest
    {jsonrpc:"2.0", id:string, method:string, params?:unknown}; JsonRpcResponse =
    {jsonrpc,id,result?} | {jsonrpc,id,error:{code,message}}; JsonRpcNotification
    {jsonrpc:"2.0", method:string, params?:unknown} (NO id). Error codes: -32700
    parse, -32600 invalid request, -32601 method not found, -32603 internal error
    (PRD §5.3 uses -32600 "bad token" for S9's handshake failure). S8 imports
    these TYPE-ONLY (no runtime values — protocol.ts is types-only).
  section: "§A (raw envelopes) + the error-code comment block"
  critical: |
    Bridge id is RESTRICTED TO string (PRD §5.3 — not number/null). S8 narrows
    accordingly: a numeric/null/missing id → NOT a request (treat as malformed →
    -32600 invalid request with id:null). A present string id → request (always
    write a response). No string id → notification (never write a response).

# MUST READ — the pre-researched, empirically-verified analysis FOR THIS EXACT TASK
- docfile: plan/001_c56962b4fa17/P1M2T4S8/research/notes.md
  why: the authoritative task analysis. §1 locks the S8↔S9/S10/S11–S14/S15 boundary
    (incl. the resolved S15 split: S8 = dispatch-loop error safety net; S15 =
    per-handler domain-error wrapping). §2 justifies the NEW connection.ts module
    (vs inline) + the no-cycle import discipline. §3 reproduces pi's rpc-mode
    handleInputLine dispatch pattern (the shape S8 mirrors). §4 spells out the
    JSON-RPC narrowing rules. §5 is the registry + ConnectionState design. §6 is
    socket write/error/close semantics (why sock.on('error') is FATAL). §7 is the
    test design. §8 is the verified validation commands. §9 is the scope summary.
  section: "§1 (boundary), §3 (pi dispatch mirror), §4 (narrowing rules), §6 (socket lifecycle), §7 (tests)"
  critical: |
    §1's S15 split is essential: S8's dispatch loop MUST try/catch both JSON.parse
    (-32700) AND the handler call (-32603) so malformed input and throwing
    handlers never become unhandled rejections that crash pi. S15 then ensures
    each handler catches its OWN domain errors. Do NOT push all error handling to
    S15 — S8 would ship a crashable dispatch loop.

# MUST READ — pi's authoritative dispatch pattern (the shape S8 mirrors)
- file: /home/dustin/projects/pi/packages/coding-agent/src/modes/rpc/rpc-mode.ts
  why: defines the canonical parse→dispatch→write→error shape S8 mirrors:
    handleInputLine = async (line) => { try { parsed = JSON.parse(line); } catch
    { output(error(undefined,"parse",…)); return; } try { const r = await
    handleCommand(parsed); if (r) output(r); } catch (e) { output(error(id, …,
    e)); } }; wired as a fire-and-forget `void handleInputLine(line)`. pi is
    stdin-driven (NOT a socket server) so S8's socket handling has no direct
    mirror — but this PATTERN is authoritative.
  section: "handleInputLine (~L724–800) + attachJsonlLineReader wiring (~L784)"
  critical: |
    Mirror the SHAPE: separate try/catch for parse vs handler-call; fire-and-forget
    the async line handler (void handleLine(...)); ALWAYS write an error response
    on throw (never leave a request hanging). DIFFER from pi in two ways: (1) the
    bridge keys dispatch by JSON-RPC `method` AND only responds to messages with a
    string `id` (requests) — notifications (no id) get NO response; (2) pi keys by
    command.type; the bridge uses the JSON-RPC envelope.

# MUST READ — the baseline S8 edits (the onConnection import/delete site)
- file: extension/pi-editor-bridge.ts
  why: the live post-S6 source. S8 EDITS it (minimal): add `import { onConnection }
    from "./connection.ts"`; delete the local `function onConnection(_sock: Socket):
    void { // TODO(S8): wire the JSONL reader + RPC dispatcher onto _sock; ...
    }` placeholder; the `__deps.createServer((sock) => onConnection(sock))` line
    inside startBridge is UNCHANGED (now resolves to the import); drop the unused
    `type Socket` from `import { createServer, type Server, type Socket } from
    "node:net"`.
  section: "the onConnection placeholder + JSDoc (delete) + the import line + the
    createServer line in startBridge (keep) + the node:net import (drop type Socket)"
  critical: |
    Do NOT touch startBridge/stopBridge/getServer/getSocketPath/getToken/getProvider/
    captureProvider/liveProvider/__deps — S8 only (a) adds the import, (b) deletes
    the placeholder, (c) drops the now-unused type Socket. S5's bridge-lifecycle
    test mocks __deps.createServer and asserts only listen-arg/chmod/token — it
    never invokes the connection callback, so changing onConnection from a local
    fn to an import is invisible to it. (Re-run it to confirm.)

# SUPPORTING — house test conventions (S8's test follows these exactly)
- file: extension/tests/bridge-lifecycle.test.ts
  why: the canonical MOCKED-UNIT + REAL-INTEGRATION test pattern in THIS repo. S8's
    test mirrors the split: a fake/mock object for the fast unit assertions +
    ONE real `net.createServer`+`net.connect` integration assertion. Also shows the
    `once` from `node:events` + `await` async-test idiom + the `try/finally` state
    restoration S8's test reuses (for `__resetHandlersForTest`).
  section: "TEST 1 (mocked via __deps) + TEST 2 (real net.createServer integration)"

- file: extension/tests/jsonl-reader.test.ts
  why: the most recent suite (S7) — shows the EXACT node:test+assert/strict+jiti
    style, the `import … from "../<mod>.ts"` relative import, TAB indentation,
    and a `feed(...)`/helper idiom. S8's test mirrors this style (with a fake
    socket helper + a real-socket round-trip helper).
  section: "imports + the feed() helper + the detach test (EventEmitter/listenerCount idiom)"

# SUPPORTING — the prior PRP that established the one-line include edit pattern
- docfile: plan/001_c56962b4fa17/P1M2T4S7/research/notes.md
  why: §3 is the DEFINITIVE node:* type-resolution probe (the mechanism connection.ts
    relies on: node:net/node:events/Buffer resolve via the PROGRAM-WIDE transitive
    @types/node pulled in by pi-editor-bridge.ts's pi-coding-agent import — NOT via
    local node_modules). §7 confirms the one-line include edit is the established
    safe pattern. connection.ts extends the claim to node:net (Socket type) +
    node:events (test fake) — same mechanism.
  section: "§3 (node:* resolution — read before touching tsconfig), §7 (the include edit)"
  critical: |
    Do NOT add typeRoots/types:["node"]/lib to tsconfig — a typeRoots override that
    omits the pi-coding-agent tree BREAKS the working transitive resolution
    (verified by a failed probe in S7 research §3). The ONLY tsconfig change is
    appending "connection.ts" to include. compilerOptions stays untouched.

# SUPPORTING — PRD IPC + lifecycle + security context
- docfile: PRD.md
  why: §5.3 (envelopes + handshake: requests carry id+method; notifications carry
    no id and expect no reply; JSON-RPC error code -32600 "bad token" for S9);
    §5.4 (methods table — S8 dispatches by these names; S8 registers NONE);
    §6.5 (request-handling skeleton — getSuggestions AbortController/supersession
    is S11, NOT S8; S8 just routes the call); §6.7 (extension requirements:
    "never throws from handlers", "never blocks the event loop synchronously",
    "survives multiple editor open/close cycles" — S8's error/close lifecycle
    handlers make these true); §12 (Security: never log the token — S8's
    sock.on('error') log MUST NOT include the descriptor/token); §11 (pi dies
    while editor open → socket EOF → S8's close handler detaches cleanly).
  section: "§5.3 (envelopes/handshake), §5.4 (methods), §6.5 (handler skeleton —
    NOT S8's scope), §6.7 (never throws / survives churn), §12 (never log token),
    §11 (socket EOF on pi death)"

# SUPPORTING — Node net.Socket + EventEmitter semantics
- url: https://nodejs.org/api/net.html#event-error
  why: confirms an unhandled 'error' event on a net.Socket (ECONNRESET, EPIPE,
    client-killed) THROWS and crashes the process (Node EventEmitter contract) —
    the same contract S6 handled for the net.Server. S8 MUST attach
    sock.on("error", …) (log + detach + destroy, NO rethrow) on EVERY accepted
    socket.
  section: "Event: 'error' (<Error>) — 'Emitted when an error occurs. The 'close'
    event will be called directly following this event.'"
  critical: |
    A socket that emits 'error' with no listener crashes pi. S8 attaches the
    listener unconditionally in onConnection (before any data flows). sock.destroy()
    inside the handler ensures cleanup; 'close' fires right after and also detaches
    (idempotent). Never rethrow from the handler.

- url: https://nodejs.org/api/net.html#socketwrite
  why: confirms socket.write(data, encoding?, cb?) returns a boolean (false =
    internal buffer full → wait for 'drain'). S8 calls write and ignores the
    return (bridge responses are tiny autocomplete items; backpressure is a
    documented v1 non-issue — PRD §15 future). Mirrors pi's reader simplicity.
  section: "socket.write(data[, encoding][, callback]) → boolean"
```

### Current Codebase tree (post-S7 baseline — S8 ADDS 1 module + 1 test, edits 1 include line + minimal pi-editor-bridge.ts wiring)

```bash
extension/
├── pi-editor-bridge.ts            # (S1+S2+S3+S5+S6) default-export factory: session_start (TUI guard + log + captureProvider + startBridge) + session_shutdown (stopBridge); captureProvider/getProvider/liveProvider; startBridge/stopBridge/getServer/getSocketPath/getToken/__deps/onConnection-PLACEHOLDER. S8 EDITS THIS FILE minimally (import onConnection from ./connection.ts; delete the local placeholder; drop unused type Socket).
├── protocol.ts                    # (S4) type-only JSON-RPC contract — S8 imports its envelopes TYPE-ONLY. UNCHANGED.
├── jsonl-reader.ts                # (S7) the framing mirror: attachJsonlLineReader + serializeJsonLine — S8 IMPORTS BOTH. UNCHANGED.
├── tsconfig.json                  # (S1+S2+S4+S7) include=["pi-editor-bridge.ts","protocol.ts","jsonl-reader.ts","tests/**/*.ts"]; paths map BOTH pi-coding-agent AND pi-tui. S8 appends "connection.ts" to include (the ONLY edit; compilerOptions UNCHANGED).
└── tests/
    ├── provider-capture.test.ts   # (S2) S8 does NOT touch (regression).
    ├── mode-guard.test.ts         # (S3) S8 does NOT touch (regression).
    ├── protocol.test.ts           # (S4) S8 does NOT touch (regression).
    ├── bridge-lifecycle.test.ts   # (S5) S8 does NOT touch (regression) — it mocks __deps.createServer so the import swap is invisible to it. RE-RUN to confirm.
    ├── bridge-lifecycle-wiring.test.ts  # (S6) S8 does NOT touch (regression).
    └── jsonl-reader.test.ts       # (S7) S8 does NOT touch (regression).
# plan/ holds planning artifacts only — no other source code
```

### Desired Codebase tree with files to be added/modified

```bash
extension/
├── pi-editor-bridge.ts            # (MODIFY) +`import { onConnection } from "./connection.ts"`; DELETE the local onConnection placeholder + its // TODO(S8) comment; `__deps.createServer((sock) => onConnection(sock))` UNCHANGED; drop unused `type Socket` from the node:net import.
├── protocol.ts                    # (UNCHANGED — S4) envelopes S8 narrows into.
├── jsonl-reader.ts                # (UNCHANGED — S7) framing S8 consumes.
├── connection.ts                  # (CREATE) the connection-handling half of P1.M2.T4: onConnection + handleLine + sendResponse/sendError/sendNotification + MethodHandler + registerBridgeHandler + ConnectionState + __test seams. Imports jsonl-reader.ts (values) + protocol.ts (types) only — NO pi-editor-bridge.ts import.
├── tsconfig.json                  # (MODIFY) append "connection.ts" to include → ["pi-editor-bridge.ts","protocol.ts","jsonl-reader.ts","connection.ts","tests/**/*.ts"]. compilerOptions UNCHANGED.
└── tests/
    ├── provider-capture.test.ts   # (UNCHANGED — S2 regression)
    ├── mode-guard.test.ts         # (UNCHANGED — S3 regression)
    ├── protocol.test.ts           # (UNCHANGED — S4 regression)
    ├── bridge-lifecycle.test.ts   # (UNCHANGED — S5 regression; re-run to confirm the import swap is invisible)
    ├── bridge-lifecycle-wiring.test.ts  # (UNCHANGED — S6 regression)
    ├── jsonl-reader.test.ts       # (UNCHANGED — S7 regression)
    └── connection.test.ts         # (CREATE) node:test+jiti: response-writer envelopes; registered-handler success; method-not-found (-32601); notification (no response); parse-error (-32700, no throw); handler-throw (-32603, no throw); invalid-envelope (-32600); socket error detaches + no throw; socket close detaches; ONE real Unix-socket-pair round-trip.
```

**File responsibilities**
- `extension/connection.ts` — the connection-handling layer. Owns: per-connection
  state (`ConnectionState`), the handler registry (`Map<string, MethodHandler>` +
  `registerBridgeHandler`), the dispatch loop (`handleLine`: parse → narrow →
  route → write, with the `-32700`/`-32603` safety net), the response writers
  (`sendResponse`/`sendError`/`sendNotification`), the `onConnection(sock)` entry
  point (wire reader + error/close lifecycle), and the test seams. Pure
  composition over `jsonl-reader.ts` + `protocol.ts`; no socket/server
  *creation* (that's `pi-editor-bridge.ts`'s `startBridge`), no env writes, no
  handler implementations (S9–S14).
- `extension/tests/connection.test.ts` — the contract gate for S8: proves the
  dispatch never crashes pi (parse-error, handler-throw, invalid-envelope, socket
  `error`), never hangs a request (every request gets a response), respects
  JSON-RPC notification semantics (notifications get no response), and that the
  end-to-end framing works through a real Unix socket pair.

### Known Gotchas of our codebase & Library Quirks

```typescript
// CRITICAL (verified, research §1 + Node docs): an UNHANDLED 'error' event on a
//   net.Socket THROWS and crashes pi (Node EventEmitter contract — same as the
//   net.Server 'error' S6 handled). S8 attaches sock.on("error", …) UNCONDITIONALLY
//   in onConnection, BEFORE any data flows: log the Error.message (NEVER the token
//   or the BridgeDescriptor — PRD §12), detach() the reader, sock.destroy(). NEVER
//   rethrow. 'close' fires right after 'error'; S8's sock.on("close", …) also calls
//   detach() (idempotent — EventEmitter.off is a safe no-op if already removed).

// CRITICAL (research §1, the S8↔S15 split): S8's handleLine MUST try/catch BOTH
//   JSON.parse (→ -32700 parse error response) AND the registered-handler call
//   (→ -32603 internal error response). WITHOUT the loop-level catches: a malformed
//   line → unhandled JSON.parse rejection → crash; a throwing handler → unhandled
//   rejection → crash AND the request hangs (client waits for its RPC timeout with
//   no reply). S15's job is then to make each handler catch its OWN domain errors
//   BEFORE they reach S8's safety net (so error codes are domain-correct). Do NOT
//   defer all error handling to S15 — S8 would ship a crashable dispatch loop.

// CRITICAL (research §4 + protocol.ts §A): JSON-RPC request = has a STRING id;
//   notification = NO string id. The bridge RESTRICTS id to string (PRD §5.3 — not
//   number/null). Narrowing rules: (a) parsed is not a non-null object OR lacks
//   "method" → invalid envelope → -32600 invalid request (id = the parsed id if
//   it's a string, else null); (b) string id present → REQUEST → always write a
//   response (result on success, -32601/-32603 on miss/throw); (c) no string id →
//   NOTIFICATION → call handler if registered, write NO response (JSON-RPC 2.0:
//   notifications expect no reply).

// CRITICAL (research §2): connection.ts must NOT import pi-editor-bridge.ts. The
//   bridge → connection.ts is one-directional. Handlers (S9–S14) are registered
//   FROM pi-editor-bridge.ts (where getToken()/getProvider() live) via
//   registerBridgeHandler, so each handler closure references those getters in the
//   SAME module — connection.ts never reaches back. A cycle here would break
//   jiti's ESM load. (Verified: connection.ts's only imports are ./jsonl-reader.ts
//   + ./protocol.ts — both safe, no back-edge.)

// GOTCHA (verified, S7 research §3): node:net (Socket type) + node:events
//   (EventEmitter) + Buffer resolve via the PROGRAM-WIDE transitive @types/node
//   (pulled in by pi-editor-bridge.ts's pi-coding-agent import), NOT via a local
//   node_modules walk. tsc --traceResolution reports node:* as "not resolved"
//   (classic resolution) but the ambient declarations satisfy the import. RESOLUTION:
//   the ONLY tsconfig change is appending "connection.ts" to include. Do NOT add
//   typeRoots/types:["node"]/lib — a typeRoots override BREAKS the working
//   transitive resolution (verified by a failed probe in S7 research §3).

// GOTCHA: attachJsonlLineReader attaches 'data'/'end' and SWITCHES the socket into
//   flowing mode (data flows as it arrives) — that is the desired behavior for a
//   net.Socket. No pause/resume needed. (S7 research §2/§4.)

// GOTCHA: the detach fn S7 returns uses the SAME function references passed to
//   .on() (EventEmitter identity) when calling .off(). S7's closure-captured
//   onData/onEnd make this work. S8 calls detach() from sock.on("error")/
//   sock.on("close") — it removes ONLY the reader's data/end listeners, NOT S8's
//   own error/close listeners (those go away with the socket on destroy/close).

// GOTCHA: socket.write returns false when the internal buffer is full (wait for
//   'drain'). S8 calls write and IGNORES the return — bridge responses are tiny
//   autocomplete items; backpressure is a documented v1 non-issue (PRD §15
//   future). Do NOT add drain handling for v1.

// GOTCHA: the handler registry is MODULE-LEVEL state (shared across all
//   connections; handlers don't vary per connection). The per-connection STATE
//   (handshakeComplete) is created FRESH inside each onConnection call. Tests
//   MUST call __resetHandlersForTest() in a try/finally to isolate the registry
//   (else one test's registered handler leaks into another). Mirror the
//   bridge-lifecycle.test.ts try/finally state-restoration idiom.

// GOTCHA: handleLine is ASYNC (handlers can be async — getSuggestions is, per
//   S11). S8 calls it fire-and-forget: the reader's onLine does
//   `void handleLine(sock, state, line)` — the loop-level try/catch inside
//   handleLine converts every throw into an error RESPONSE, never an unhandled
//   rejection. (Mirrors pi's `void handleInputLine(line)` at rpc-mode.ts:786.)

// GOTCHA: S5's bridge-lifecycle.test.ts mocks __deps.createServer with a fake
//   server and asserts ONLY the listen-arg/chmod/token — it never invokes the
//   connection callback. So swapping onConnection from a local fn to an IMPORT
//   is invisible to it. (Still: re-run S5's test to confirm — it's in the
//   regression loop.)

// GOTCHA: pi's rpc-mode is stdin-driven (NOT a socket server), so S8's socket
//   handling (createServer connection callback, sock.on error/close, multiple
//   connections) has NO direct pi mirror. S8 mirrors pi's PARSE→DISPATCH→WRITE→ERROR
//   PATTERN (rpc-mode.ts handleInputLine ~L724–800), not its transport. The
//   socket lifecycle is standard Node net.Socket usage (research §6).

// STYLE: TABS for indentation (match every existing extension file + pi's source).
//   `import type` for the protocol.ts type-only imports (JsonRpcRequest etc. are
//   interfaces — type-only); value imports from jsonl-reader.ts. Mode-A JSDoc on
//   every export with a `STATUS (P1.M2.T4.S8)` marker + the S7-consumes / S9–S14
//   forward-refs.
```

## Implementation Blueprint

### Data models and structure

S8 introduces TWO small pieces of module state + a few pure-ish functions. No
wire types are added (those live in `protocol.ts` S4); S8 narrows raw
`unknown` JSON into S4's existing envelopes.

```typescript
// === connection.ts data model ===

/** Per-connection state. S8 creates it fresh (handshakeComplete:false) inside
 *  each onConnection(sock) call; two sockets get two independent states.
 *  S9 sets handshakeComplete=true on a valid hello; S10 gates every non-hello
 *  method on it. S8 creates it but does NOT gate (S10) or validate (S9). */
export interface ConnectionState {
	handshakeComplete: boolean;
}

/** A per-method RPC handler. Receives the narrowed `params` (unknown — each
 *  handler narrows further, e.g. hello narrows to HelloParams) + the connection
 *  state (so hello can flip handshakeComplete). Returns the result (success →
 *  written as {jsonrpc,id,result}) or THROWS (→ S8's loop catch writes
 *  {jsonrpc,id,error:{-32603}}; S15 makes each handler catch its own domain
 *  errors into proper codes BEFORE throwing). Async to support getSuggestions. */
export type MethodHandler = (
	params: unknown,
	state: ConnectionState,
) => Promise<unknown> | unknown;

// MODULE STATE (shared across all connections; handlers don't vary per conn):
const handlers = new Map<string, MethodHandler>(); // EMPTY in S8 — S9–S14 fill it.
```

The `ConnectionState` lives in the `onConnection` closure (per-connection); the
`handlers` Map is module-level (per-process). This mirrors the existing
`pi-editor-bridge.ts` split (per-process `liveProvider`/`server` singletons vs
per-connection work), and means S8's only module-level state is the registry —
no server, no token (those stay in `pi-editor-bridge.ts`).

### Implementation Tasks (ordered by dependencies)

```yaml
Task 1: CREATE extension/connection.ts (the connection-handling module)
  - CREATE the file with the exact reference body in Implementation Patterns below.
  - IMPORTS (NO pi-editor-bridge.ts — avoids the cycle; research §2):
        import type { Socket } from "node:net";   // type-only (the createServer callback arg type)
        import { attachJsonlLineReader, serializeJsonLine } from "./jsonl-reader.ts";   // S7 values
        import type { JsonRpcError } from "./protocol.ts";   // S4 type-only (no runtime values)
    (node:events is NOT imported — it's only used in the TEST as the fake-socket base.)
  - EXPORT `ConnectionState` (interface) + `MethodHandler` (type) — see Data models.
  - EXPORT `sendResponse(sock: Socket, id: string, result: unknown): boolean` →
        sock.write(serializeJsonLine({jsonrpc:"2.0", id, result})).
  - EXPORT `sendError(sock: Socket, id: string | null, code: number, message: string): boolean` →
        sock.write(serializeJsonLine({jsonrpc:"2.0", id, error:{code,message} as JsonRpcError})).
        (id is string|null: null for parse/invalid-envelope errors where no id was inferable.)
  - EXPORT `sendNotification(sock: Socket, method: string, params?: unknown): boolean` →
        sock.write(serializeJsonLine({jsonrpc:"2.0", method, ...(params!==undefined && {params})})).
        (NO id — JSON-RPC notification. S17's commandsChanged uses this S→C.)
  - EXPORT `registerBridgeHandler(method: string, fn: MethodHandler): void` → handlers.set(method, fn).
  - EXPORT `handleLine(sock: Socket, state: ConnectionState, line: string): Promise<void>` →
        the parse→narrow→dispatch→write unit (research §3/§4). try/catch JSON.parse
        (-32700 on throw); narrow envelope (invalid → -32600; request → dispatch +
        always respond; notification → dispatch, no response); dispatch via
        handlers.get(method) (registered → result response on return / -32603 on throw;
        unregistered request → -32601; unregistered notification → silent). Fire-and-forget
        from the reader's onLine.
  - EXPORT `onConnection(sock: Socket): void` →
        const state: ConnectionState = { handshakeComplete: false };
        const detach = attachJsonlLineReader(sock, (line) => { void handleLine(sock, state, line); });
        sock.on("error", (err) => { console.error(`pi-editor-bridge: socket error: ${err?.message ?? err}`); detach(); try { sock.destroy(); } catch {} });
        sock.on("close", () => detach());
  - EXPORT test seams `__resetHandlersForTest(): void` (handlers.clear()) +
        `__hasHandlerForTest(method: string): boolean` (handlers.has(method)).
  - JSDOC: file-level block citing PRD §5.3/§5.4/§6.7/§12 + the S7 sibling + pi's
      rpc-mode handleInputLine as the dispatch PATTERN mirror; per-export Mode-A
      blocks with a STATUS (P1.M2.T4.S8) marker + forward refs ("S9 registers hello
      via registerBridgeHandler; S10 gates on state.handshakeComplete; S11–S14 add
      method handlers; S15 wraps each handler's domain errors").
  - NAMING: onConnection / handleLine / sendResponse / sendError / sendNotification /
      registerBridgeHandler / ConnectionState / MethodHandler — EXACT (S9–S14 import
      these names; the PRD §6.5 skeleton uses send*/handler names).
  - FOLLOW: TAB indentation; `import type` for Socket + JsonRpcError; match the JSDoc
      density of jsonl-reader.ts / protocol.ts.
  - DO NOT: import pi-editor-bridge.ts (cycle); implement hello/token (S9); add the
      handshake gate (S10); implement any method handler (S11–S14); write to
      process.env (S16); register any handler (registry stays EMPTY); handle
      backpressure/drain (v1 non-issue); rethrow from sock.on("error").

Task 2: MODIFY extension/tsconfig.json — append "connection.ts" to include
  - CHANGE the include array from:
        "include": ["pi-editor-bridge.ts", "protocol.ts", "jsonl-reader.ts", "tests/**/*.ts"]
    to:
        "include": ["pi-editor-bridge.ts", "protocol.ts", "jsonl-reader.ts", "connection.ts", "tests/**/*.ts"]
  - WHY: tsc only type-checks files matched by include (or imported by them). connection.ts
      IS imported by pi-editor-bridge.ts (Task 3), so it'd be pulled in transitively — BUT
      the S4/S7 convention is to list every first-party module explicitly in include so a
      `tsc -p` of JUST the include set is self-contained even if an import is temporarily
      removed during refactor. Same one-line additive edit S4/S7 made.
  - DO NOT: touch compilerOptions (the node:* transitive resolution in S7 research §3
      depends on compilerOptions being EXACTLY as-is — a typeRoots/types/lib change can
      BREAK node:net/node:events/Buffer resolution, verified by a failed probe); edit
      paths; reorder the existing entries.

Task 3: MODIFY extension/pi-editor-bridge.ts — wire the imported onConnection
  - EDIT 1 (import): after the existing `import { join } from "node:path";` line, ADD:
        import { onConnection } from "./connection.ts";
    (Place it with the other relative imports; there are none yet, so add it after the
     node:* imports block. Use the .ts extension — `allowImportingTsExtensions:true` +
     jiti resolve it, matching the test imports `from "../jsonl-reader.ts"`.)
  - EDIT 2 (delete placeholder): DELETE the entire local `function onConnection(_sock:
     Socket): void { ... }` block AND its preceding JSDoc comment (the one with the
     `STATUS (P1.M2.T3.S5)` marker + the `// TODO(S8): wire the JSONL reader + RPC
     dispatcher onto _sock` lines). The IMPORTED onConnection now provides it.
  - EDIT 3 (the createServer line is UNCHANGED): the existing line
        server = __deps.createServer((sock) => onConnection(sock));
     inside startBridge now resolves `onConnection` to the IMPORT. Leave it byte-for-byte.
  - EDIT 4 (drop unused type Socket): change
        import { createServer, type Server, type Socket } from "node:net";
     to
        import { createServer, type Server } from "node:net";
     (Socket was ONLY used by the now-deleted local onConnection signature. noUnusedLocals
      is OFF so it wouldn't error, but cleanliness — and S7's anti-pattern "don't leave
      dead imports". Verify with a grep that Socket appears nowhere else in the file.)
  - WHY: S8's deliverable is the connection handling; pi-editor-bridge.ts owns the
      server LIFECYCLE (start/stop) and delegates per-connection handling to connection.ts.
      The minimal edit keeps startBridge/stopBridge/getServer/getSocketPath/getToken/
      getProvider/captureProvider/__deps untouched.
  - DO NOT: touch any other function/variable in pi-editor-bridge.ts; change the
      createServer callback shape; add a handler registration here (S9 does that).

Task 4: CREATE extension/tests/connection.test.ts (node:test + jiti)
  - IMPORT: `import { test } from "node:test"; import assert from "node:assert/strict";`
      `import { EventEmitter } from "node:events";`
      `import { net } from "node:net";` ... actually `import { createServer, connect } from "node:net";`
      `import { once } from "node:events";`
      `import { onConnection, handleLine, sendResponse, sendError, sendNotification,
        registerBridgeHandler, __resetHandlersForTest, __hasHandlerForTest } from "../connection.ts";`
      `import { attachJsonlLineReader, serializeJsonLine } from "../jsonl-reader.ts";`
  - HELPER fakeSocket(): returns { sock, writes } where sock = Object.assign(new
      EventEmitter(), { write(s:string){writes.push(s); return true;}, destroy(){this.emit("close");} }).
      (EventEmitter gives .on/.emit/.listenerCount for error/close tests; write captures
      every serialized response for assertion.)
  - HELPER parseResponses(writes): JSON.parse each LF-terminated line → array (for asserting
      the exact envelopes sendResponse/sendError/sendNotification produce).
  - TEST 1 (sendResponse shape): sendResponse(fakeSock,"h1",{ok:true}) → writes exactly
      ['{"jsonrpc":"2.0","id":"h1","result":{"ok":true}}\n']; parsed deep-equals the envelope.
  - TEST 2 (sendError shape): sendError(fakeSock,"r2",-32601,"method not found") → writes
      ['{"jsonrpc":"2.0","id":"r2","error":{"code":-32601,"message":"method not found"}}\n'].
  - TEST 3 (sendNotification shape — NO id): sendNotification(fakeSock,"commandsChanged",{})
      → writes a line that parses to {jsonrpc:"2.0",method:"commandsChanged",params:{}} with
      NO `id` key (assert !("id" in parsed)).
  - TEST 4 (registered handler → success response): registerBridgeHandler("echo", p=>p);
      const {sock,writes}=fakeSocket(); await handleLine(sock,{handshakeComplete:true},
      JSON.stringify({jsonrpc:"2.0",id:"e1",method:"echo",params:{x:1}})); assert writes
      parses to {jsonrpc:"2.0",id:"e1",result:{x:1}}; __resetHandlersForTest() in finally.
  - TEST 5 (method not found → -32601): const {sock,writes}=fakeSocket(); await
      handleLine(sock,{handshakeComplete:true},JSON.stringify({jsonrpc:"2.0",id:"m1",
      method:"nope"})); assert parses to {id:"m1",error:{code:-32601,message:...}}.
  - TEST 6 (unregistered NOTIFICATION → NO response): await handleLine(sock,...,
      JSON.stringify({jsonrpc:"2.0",method:"nope",params:{}})); assert writes.length===0.
  - TEST 7 (registered notification handler called, NO response): registerBridgeHandler
      ("changed", ()=>{ called=true; }); await handleLine(...,{jsonrpc:"2.0",method:"changed"});
      assert called===true AND writes.length===0; reset in finally.
  - TEST 8 (malformed JSON → -32700, NO throw): await handleLine(sock,...,"this is not json");
      assert writes parses to {jsonrpc:"2.0",id:null,error:{code:-32700,...}}; no throw escapes
      (await resolves).
  - TEST 9 (registered handler THROWS → -32603, NO throw): registerBridgeHandler("boom",
      ()=>{throw new Error("kaboom");}); await handleLine(...,{...,id:"b1",method:"boom"});
      assert writes parses to {id:"b1",error:{code:-32603,...}}; reset in finally.
  - TEST 10 (invalid envelope → -32600): for each malformed [42, '"str"', {}, {jsonrpc:"2.0"},
      {jsonrpc:"2.0",method:"x",id:123}] → await handleLine → assert an error response
      (code -32600, id null where no string id) and no throw.
  - TEST 11 (onConnection socket 'error' → reader detached, NO throw): const {sock}=fakeSocket();
      onConnection(sock as any); // wires reader + handlers
      assert.doesNotThrow(() => sock.emit("error", new Error("ECONNRESET"))); // handler logs+detach+destroy, no throw
      assert.equal(sock.listenerCount("data"),0, "reader's data listener removed after error→detach");
  - TEST 12 (onConnection socket 'close' → reader detached): const {sock}=fakeSocket();
      onConnection(sock as any); const dataCount=sock.listenerCount("data"); sock.emit("close");
      assert.equal(sock.listenerCount("data"),0, "close detaches the reader");
  - TEST 13 (REAL integration — Unix socket pair round-trip): createServer(c=>onConnection(c))
      .listen(sockpath); await once(server,"listening"); const client=connect(sockpath);
      await once(client,"connect"); // registry is EMPTY → expect -32601
      client.write(serializeJsonLine({jsonrpc:"2.0",id:"r1",method:"ping"}));
      // collect client-side responses via attachJsonlLineReader
      const got=await firstResponse(client); assert.deepEqual(got,{jsonrpc:"2.0",id:"r1",
      error:{code:-32601,message:/not found/i}}); // now register a handler, repeat, expect success
      registerBridgeHandler("ping", ()=>({ok:true})); client.write(serializeJsonLine({jsonrpc:"2.0",
      id:"r2",method:"ping"})); const got2=await firstResponse(client);
      assert.deepEqual(got2,{jsonrpc:"2.0",id:"r2",result:{ok:true}}); cleanup: server.close();
      client.destroy(); __resetHandlersForTest().
  - SHARED-STATE NOTE: the registry is MODULE-LEVEL — every test that registers a handler
      MUST __resetHandlersForTest() in a finally. Keep top-level test(...) sequential (house default).
  - FOLLOW: TAB indentation; reuse the jiti register hook path from S2/S3/S4/S5/S6/S7.
  - NAMING: descriptive test("…") titles; no describe.
  - PLACEMENT: extension/tests/connection.test.ts (matches tests/**/*.ts → NO other tsconfig edit).

Task 5: VALIDATE — run the validation commands; fix until all green
  - RUN (Level 1): `tsc --noEmit -p extension/tsconfig.json` (expect exit 0, no output)
  - RUN (Level 2): `node --import "$JITI_REG" extension/tests/connection.test.ts`
      (expect exit 0, ℹ fail 0 — ignore the benign jiti DEP0205 deprecation on stderr)
  - RUN (Level 2 regression): re-run provider-capture / mode-guard / protocol /
      bridge-lifecycle / bridge-lifecycle-wiring / jsonl-reader — expect each ℹ fail 0
  - RUN (Level 3): `pi --no-extensions -e ./extension/pi-editor-bridge.ts --print "ok"`
      exits 0 with no error lines (connection.ts IS now imported by the entry point, so
      this proves S8's import + placeholder deletion didn't break the load path)
  - RUN (sanity): grep-confirm the // TODO(S8) comment is GONE from pi-editor-bridge.ts;
      grep-confirm onConnection is imported from ./connection.ts; grep-confirm tsconfig
      compilerOptions UNCHANGED; grep-confirm connection.ts does NOT import pi-editor-bridge.ts.
```

### Implementation Patterns & Key Details

```typescript
// === extension/connection.ts (CREATE) — the connection-handling half of P1.M2.T4.
//     Imports ONLY ./jsonl-reader.ts (values) + ./protocol.ts (types). No pi-editor-bridge.ts
//     (avoids a cycle — handlers are registered FROM pi-editor-bridge.ts by S9–S14).
//     Mirrors pi's rpc-mode handleInputLine PATTERN (parse try/catch → dispatch → write →
//     error on throw), adapted to JSON-RPC 2.0 over a net.Socket. Node builtins only. ===

/**
 * connection.ts — the connection-handling half of the pi-editor-bridge IPC server.
 *
 * Sibling of {@link "./jsonl-reader.ts"} (which owns the FRAMING half of parent task
 * P1.M2.T4). For each accepted `net.Socket`, this module wires S7's line reader,
 * parses each line into a JSON-RPC 2.0 envelope, dispatches to a per-method handler
 * registry, writes responses/notifications back via `serializeJsonLine`, and owns the
 * socket `error`/`close` lifecycle (never crash pi, never leak a listener).
 *
 * Dispatch PATTERN mirrors pi's own RPC engine (`packages/coding-agent/src/modes/rpc/
 * rpc-mode.ts` `handleInputLine`, ~L724–800): a `JSON.parse` try/catch → error response
 * on a malformed line; a handler-call try/catch → error response on a throw; always
 * write a response for a REQUEST, never for a NOTIFICATION (JSON-RPC 2.0).
 *
 * STATUS (P1.M2.T4.S8): the connection-handling deliverable. The handler registry is
 * EMPTY here — S9 registers `hello`, S10 adds the handshake gate (reject every method
 * before a valid hello, using `ConnectionState.handshakeComplete`), S11–S14 register
 * getSuggestions/applyCompletion/shouldTriggerFileCompletion/ping+bye+getCommands, and
 * S15 wraps each handler's domain errors into proper JSON-RPC codes. S8 is the
 * dispatch skeleton those tasks hang handlers off — it does NOT implement any handler.
 *
 * PRD refs: §5.3 (envelopes/handshake), §5.4 (methods table — S8 dispatches by these
 * names), §6.5 (handler skeleton — the AbortController/supersession there is S11, not
 * S8), §6.7 ("never throws from handlers", "survives multiple editor open/close cycles"),
 * §11 (pi dies while editor open → socket EOF → close handler detaches cleanly), §12
 * (never log the token — the sock.on("error") log MUST NOT include it).
 *
 * Node builtins only (PRD §6.7). One piece of module state: the handler registry.
 */

import type { Socket } from "node:net";
import { attachJsonlLineReader, serializeJsonLine } from "./jsonl-reader.ts";
import type { JsonRpcError } from "./protocol.ts";

/** Per-connection state. S8 creates it fresh (`handshakeComplete:false`) inside each
 *  {@link onConnection} call; two sockets get two independent states. S9 sets
 *  `handshakeComplete=true` on a valid `hello`; S10 gates every non-hello method on it. */
export interface ConnectionState {
	handshakeComplete: boolean;
}

/**
 * A per-method RPC handler. Receives the (still-`unknown`) `params` — each handler
 * narrows further (e.g. `hello` narrows to `HelloParams`, `getSuggestions` to
 * `GetSuggestionsParams`) — and the connection {@link ConnectionState} (so `hello`
 * can flip `handshakeComplete`). Returns the success `result` (written as
 * `{jsonrpc,id,result}`) or THROWS (S8's loop catch writes `-32603`; S15 makes each
 * handler catch its OWN domain errors into proper codes BEFORE throwing).
 *
 * Async to support `getSuggestions` (S11), which awaits pi's live provider.
 */
export type MethodHandler = (
	params: unknown,
	state: ConnectionState,
) => Promise<unknown> | unknown;

/**
 * The per-method handler registry. MODULE-LEVEL (shared across all connections —
 * handlers don't vary per connection). EMPTY in S8; S9–S14 populate it via
 * {@link registerBridgeHandler}.
 *
 * Registered FROM `pi-editor-bridge.ts` (S9–S14), NOT here — so each handler closure
 * references `getToken()`/`getProvider()` in THAT module and `connection.ts` never
 * imports `pi-editor-bridge.ts` (no import cycle — research §2).
 */
const handlers = new Map<string, MethodHandler>();

/**
 * Register (or replace) the handler for a JSON-RPC method name. Idempotent
 * (`Map.set`). S9 registers `"hello"`; S11–S14 register the rest. Re-registering on
 * each `session_start` (reload/new/resume/fork) is safe — the handler closures read
 * live state via `getToken()`/`getProvider()` getters, so they always see the current
 * provider/token.
 *
 * STATUS (P1.M2.T4.S8): the extension point S9–S14 call. S8 registers NOTHING.
 */
export function registerBridgeHandler(method: string, fn: MethodHandler): void {
	handlers.set(method, fn);
}

/** Write a JSON-RPC 2.0 success response (`{jsonrpc:"2.0",id,result}`), LF-terminated.
 *  Uses S7's `serializeJsonLine` + `sock.write`. Ignores the write return (backpressure
 *  is a documented v1 non-issue — bridge responses are tiny; PRD §15 future). */
export function sendResponse(sock: Socket, id: string, result: unknown): boolean {
	return sock.write(serializeJsonLine({ jsonrpc: "2.0", id, result }));
}

/** Write a JSON-RPC 2.0 error response. `id` is `string|null`: `null` when no id was
 *  inferable (parse failure, invalid envelope). Used by S9 for the `-32600` "bad token"
 *  handshake error (PRD §5.3). */
export function sendError(
	sock: Socket,
	id: string | null,
	code: number,
	message: string,
): boolean {
	const error: JsonRpcError = { code, message };
	return sock.write(serializeJsonLine({ jsonrpc: "2.0", id, error }));
}

/** Write a JSON-RPC 2.0 NOTIFICATION (no `id`, no reply expected). S17's
 *  `commandsChanged` (S→C) uses this. `params` omitted from the wire when `undefined`. */
export function sendNotification(
	sock: Socket,
	method: string,
	params?: unknown,
): boolean {
	const envelope: Record<string, unknown> = { jsonrpc: "2.0", method };
	if (params !== undefined) envelope.params = params;
	return sock.write(serializeJsonLine(envelope));
}

/** Test seam: clear the registry (module-level — isolate between tests). */
export function __resetHandlersForTest(): void {
	handlers.clear();
}
/** Test seam: does a handler exist for `method`? (assertions about dispatch routing.) */
export function __hasHandlerForTest(method: string): boolean {
	return handlers.has(method);
}

/**
 * Parse + narrow + dispatch a single (complete, `\r`-stripped) JSONL line. Mirrors
 * pi's `handleInputLine` PATTERN: separate try/catch for the parse vs the handler call;
 * ALWAYS write a response for a REQUEST; NEVER for a NOTIFICATION (JSON-RPC 2.0).
 *
 * Narrowing (research §4): a line that is not a non-null object, OR lacks `method`,
 * is an INVALID request → `-32600` (id = the parsed `id` if it's a string, else null).
 * A line with a string `id` is a REQUEST → dispatch (registered handler → result
 * response on return / `-32603` on throw; unregistered → `-32601`). A line with NO
 * string `id` is a NOTIFICATION → call the handler if registered, write NO response.
 *
 * The bridge RESTRICTS `id` to `string` (PRD §5.3); a numeric/null `id` is treated as
 * malformed (`-32600`).
 *
 * ASYNC and fire-and-forget from the reader's `onLine` (`void handleLine(...)`). The
 * loop-level try/catches convert EVERY throw into an error RESPONSE — never an unhandled
 * rejection (which would crash pi, violating PRD §6.7). S15 makes each handler catch its
 * OWN domain errors before they reach the `-32603` safety net.
 *
 * STATUS (P1.M2.T4.S8): the dispatch unit. S9 adds `hello` via registerBridgeHandler
 * (no change here); S10 adds a `if (!state.handshakeComplete && method !== "hello")`
 * gate (one guard inside the request branch, or a wrapper). The registry is EMPTY in S8.
 */
export async function handleLine(
	sock: Socket,
	state: ConnectionState,
	line: string,
): Promise<void> {
	// (A) PARSE — try/catch → -32700. (pi mirror: try { JSON.parse } catch { output parse error }.)
	let parsed: unknown;
	try {
		parsed = JSON.parse(line);
	} catch (parseError) {
		sendError(
			sock,
			null,
			-32700,
			`parse error: ${parseError instanceof Error ? parseError.message : String(parseError)}`,
		);
		return;
	}

	// (B) NARROW — must be a non-null object with a string `method` (research §4).
	const idField = (parsed as { id?: unknown } | null)?.id;
	const id: string | null = typeof idField === "string" ? idField : null;
	const isRequest = typeof idField === "string";

	if (
		typeof parsed !== "object" ||
		parsed === null ||
		!("method" in parsed) ||
		typeof (parsed as { method: unknown }).method !== "string"
	) {
		sendError(sock, id, -32600, "invalid request: not a JSON-RPC 2.0 request/notification");
		return;
	}

	const method = (parsed as { method: string }).method;
	const params = (parsed as { params?: unknown }).params; // unknown — each handler narrows.
	const handler = handlers.get(method);

	// (C) NOTIFICATION (no string id) — call handler if registered, NEVER write a response.
	if (!isRequest) {
		if (handler) {
			try {
				await handler(params, state);
			} catch (handlerError) {
				// Notifications have no id → no response. Log (NEVER the token — PRD §12); do not throw.
				console.error(
					`pi-editor-bridge: notification "${method}" handler threw: ${
						handlerError instanceof Error ? handlerError.message : String(handlerError)
					}`,
				);
			}
		}
		return;
	}

	// (D) REQUEST — registered → result on return / -32603 on throw; unregistered → -32601.
	if (!handler) {
		sendError(sock, id, -32601, `method not found: ${method}`);
		return;
	}
	try {
		const result = await handler(params, state);
		sendResponse(sock, id, result);
	} catch (handlerError) {
		// S8's safety net: a request must ALWAYS get a response (never hang the client's
		// RPC timeout). S15 makes each handler catch its OWN domain errors into proper
		// codes BEFORE throwing, so this is the last-resort -32603.
		sendError(
			sock,
			id,
			-32603,
			`internal error: ${handlerError instanceof Error ? handlerError.message : String(handlerError)}`,
		);
	}
}

/**
 * The `net.Server` connection callback `startBridge` passes to `createServer`. For each
 * accepted socket: create a fresh {@link ConnectionState}, wire S7's line reader (each
 * complete line → `void handleLine(sock, state, line)`), and own the socket lifecycle:
 *
 *  - `sock.on("error", …)` — an UNHANDLED socket `'error'` (ECONNRESET, EPIPE,
 *    client-killed) THROWS and crashes pi (Node EventEmitter contract — same as the
 *    `net.Server` 'error' S6 handled). Log the Error.message (NEVER the token / the
 *    BridgeDescriptor — PRD §12), `detach()` the reader, `sock.destroy()`. NEVER rethrow.
 *  - `sock.on("close", …)` — fires on normal disconnect AND after `'error'`. `detach()`
 *    (idempotent) so no `data`/`end` listener leaks across the many editor open/close
 *    cycles one session sees (PRD §6.7).
 *
 * STATUS (P1.M2.T4.S8): the entry point `pi-editor-bridge.ts`'s `startBridge` wires into
 * `__deps.createServer((sock) => onConnection(sock))`. State starts `handshakeComplete:false`;
 * S9's hello handler flips it true; S10's gate reads it. S8 creates the state but does NOT
 * gate (S10) or validate (S9).
 */
export function onConnection(sock: Socket): void {
	const state: ConnectionState = { handshakeComplete: false };

	const detach = attachJsonlLineReader(sock, (line) => {
		void handleLine(sock, state, line); // fire-and-forget; loop-level catches → responses, never rejections.
	});

	sock.on("error", (err: Error) => {
		// CRITICAL: no listener here = process crash. Log message ONLY (never the token — PRD §12).
		console.error(`pi-editor-bridge: socket error: ${err?.message ?? err}`);
		try {
			detach();
		} catch {
			/* idempotent best-effort */
		}
		try {
			sock.destroy();
		} catch {
			/* already destroyed */
		}
	});

	sock.on("close", () => {
		try {
			detach(); // idempotent — removes the reader's data/end listeners only.
		} catch {
			/* idempotent best-effort */
		}
	});
}
```

```typescript
// === extension/tests/connection.test.ts (CREATE — node:test + jiti; NOT vitest) ===
import { test } from "node:test";
import assert from "node:assert/strict";
import { EventEmitter } from "node:events";
import { once } from "node:events";
import { createServer, connect, type Socket } from "node:net";
import { randomUUID } from "node:crypto";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
	onConnection,
	handleLine,
	sendResponse,
	sendError,
	sendNotification,
	registerBridgeHandler,
	__resetHandlersForTest,
} from "../connection.ts";
import { attachJsonlLineReader, serializeJsonLine } from "../jsonl-reader.ts";

// A fake socket: EventEmitter (for .on/.emit/.listenerCount) + a write() that captures
// every serialized line. .destroy() emits 'close' (the real net.Socket does too).
function fakeSocket(): { sock: Socket; writes: string[] } {
	const writes: string[] = [];
	const sock = Object.assign(new EventEmitter(), {
		write(s: string) {
			writes.push(s);
			return true;
		},
		destroy() {
			(this as EventEmitter).emit("close");
		},
	}) as unknown as Socket;
	return { sock, writes };
}
function parseResponses(writes: string[]): unknown[] {
	return writes.map((w) => JSON.parse(w.trim()));
}

// (TESTS 1–3: response-writer envelopes) -----------------------------------------
test("sendResponse: writes a success envelope, LF-terminated", () => {
	const { sock, writes } = fakeSocket();
	sendResponse(sock, "h1", { ok: true });
	assert.equal(writes.length, 1);
	assert.ok(writes[0].endsWith("\n"), "must be LF-terminated");
	assert.deepEqual(parseResponses(writes), [{ jsonrpc: "2.0", id: "h1", result: { ok: true } }]);
});

test("sendError: writes an error envelope with code+message", () => {
	const { sock, writes } = fakeSocket();
	sendError(sock, "r2", -32601, "method not found");
	assert.deepEqual(parseResponses(writes), [
		{ jsonrpc: "2.0", id: "r2", error: { code: -32601, message: "method not found" } },
	]);
});

test("sendNotification: writes a notification with NO id", () => {
	const { sock, writes } = fakeSocket();
	sendNotification(sock, "commandsChanged", {});
	const parsed = parseResponses(writes)[0] as Record<string, unknown>;
	assert.equal(parsed.jsonrpc, "2.0");
	assert.equal(parsed.method, "commandsChanged");
	assert.ok(!("id" in parsed), "notification must have no id");
});

// (TESTS 4–7: dispatch routing) --------------------------------------------------
test("handleLine: registered handler's return → success response", async () => {
	registerBridgeHandler("echo", (p) => p);
	try {
		const { sock, writes } = fakeSocket();
		await handleLine(sock, { handshakeComplete: true }, JSON.stringify({
			jsonrpc: "2.0", id: "e1", method: "echo", params: { x: 1 },
		}));
		assert.deepEqual(parseResponses(writes), [{ jsonrpc: "2.0", id: "e1", result: { x: 1 } }]);
	} finally {
		__resetHandlersForTest();
	}
});

test("handleLine: unregistered REQUEST → -32601 method not found", async () => {
	const { sock, writes } = fakeSocket();
	await handleLine(sock, { handshakeComplete: true }, JSON.stringify({
		jsonrpc: "2.0", id: "m1", method: "nope",
	}));
	const r = parseResponses(writes)[0] as { id: string; error: { code: number } };
	assert.equal(r.id, "m1");
	assert.equal(r.error.code, -32601);
});

test("handleLine: unregistered NOTIFICATION → no response", async () => {
	const { sock, writes } = fakeSocket();
	await handleLine(sock, { handshakeComplete: true }, JSON.stringify({
		jsonrpc: "2.0", method: "nope", params: {},
	}));
	assert.equal(writes.length, 0, "notifications expect no reply");
});

test("handleLine: registered notification handler is called, no response", async () => {
	let called = false;
	registerBridgeHandler("changed", () => {
		called = true;
	});
	try {
		const { sock, writes } = fakeSocket();
		await handleLine(sock, { handshakeComplete: true }, JSON.stringify({
			jsonrpc: "2.0", method: "changed",
		}));
		assert.equal(called, true);
		assert.equal(writes.length, 0);
	} finally {
		__resetHandlersForTest();
	}
});

// (TESTS 8–10: robustness — never crash, never hang) ----------------------------
test("handleLine: malformed JSON → -32700 parse error, no throw", async () => {
	const { sock, writes } = fakeSocket();
	await assert.doesNotReject(async () => {
		await handleLine(sock, { handshakeComplete: true }, "this is not json");
	});
	const r = parseResponses(writes)[0] as { id: unknown; error: { code: number } };
	assert.equal(r.id, null, "parse error response id is null");
	assert.equal(r.error.code, -32700);
});

test("handleLine: registered handler THROWS → -32603, no throw (S8 safety net)", async () => {
	registerBridgeHandler("boom", () => {
		throw new Error("kaboom");
	});
	try {
		const { sock, writes } = fakeSocket();
		await assert.doesNotReject(async () => {
			await handleLine(sock, { handshakeComplete: true }, JSON.stringify({
				jsonrpc: "2.0", id: "b1", method: "boom",
			}));
		});
		const r = parseResponses(writes)[0] as { id: string; error: { code: number } };
		assert.equal(r.id, "b1");
		assert.equal(r.error.code, -32603);
	} finally {
		__resetHandlersForTest();
	}
});

test("handleLine: invalid envelopes (non-object, no method, bad id) → -32600, no throw", async () => {
	const cases = ["42", '"str"', "{}", '{"jsonrpc":"2.0"}', '{"jsonrpc":"2.0","method":"x","id":123}'];
	for (const line of cases) {
		const { sock, writes } = fakeSocket();
		await assert.doesNotReject(async () => {
			await handleLine(sock, { handshakeComplete: true }, line);
		});
		const r = parseResponses(writes)[0] as { error: { code: number } };
		assert.equal(r.error.code, -32600, `expected -32600 for input: ${line}`);
	}
});

// (TESTS 11–12: onConnection socket lifecycle) -----------------------------------
test("onConnection: socket 'error' detaches the reader and does not throw", () => {
	const { sock } = fakeSocket();
	onConnection(sock); // wires reader + error/close handlers
	assert.ok(sock.listenerCount("data") > 0, "reader attached a data listener");
	assert.doesNotThrow(() => sock.emit("error", new Error("ECONNRESET")));
	assert.equal(sock.listenerCount("data"), 0, "reader detached after error");
});

test("onConnection: socket 'close' detaches the reader (no leak)", () => {
	const { sock } = fakeSocket();
	onConnection(sock);
	assert.ok(sock.listenerCount("data") > 0);
	sock.emit("close");
	assert.equal(sock.listenerCount("data"), 0, "close detaches the reader");
});

// (TEST 13: REAL integration — a real Unix socket pair end-to-end) ----------------
test("REAL: end-to-end JSONL round-trip over a Unix socket (method-not-found then success)", async () => {
	const sockpath = join(tmpdir(), `pi-editor-conn-test-${randomUUID()}.sock`);
	const server = createServer((c) => onConnection(c));
	server.listen(sockpath);
	await once(server, "listening");
	try {
		const client = connect(sockpath);
		await once(client, "connect");

		// collect client-side responses (registry is EMPTY → expect -32601)
		const firstResponse = readFirstResponse(client);
		client.write(serializeJsonLine({ jsonrpc: "2.0", id: "r1", method: "ping" }));
		assert.deepEqual(await firstResponse, {
			jsonrpc: "2.0", id: "r1", error: { code: -32601, message: /not found/i } as never,
		});

		// register a handler; expect success
		registerBridgeHandler("ping", () => ({ ok: true }));
		const secondResponse = readFirstResponse(client);
		client.write(serializeJsonLine({ jsonrpc: "2.0", id: "r2", method: "ping" }));
		assert.deepEqual(await secondResponse, { jsonrpc: "2.0", id: "r2", result: { ok: true } });

		client.destroy();
	} finally {
		__resetHandlersForTest();
		server.close();
	}
});

// Helper: resolve the first complete JSONL line the client socket receives.
function readFirstResponse(client: Socket): Promise<Record<string, unknown>> {
	return new Promise((resolve) => {
		const detach = attachJsonlLineReader(client, (line) => {
			detach();
			resolve(JSON.parse(line));
		});
	});
});
```

### Integration Points

```yaml
NO external integration points change for S8 beyond wiring onConnection into the existing server.
INTERNAL seams (the exports S9–S14 consume — connection.ts is the dispatch foundation):
  - registerBridgeHandler(method, fn)            → S9 registers "hello"; S11 registers
    "getSuggestions"; S12 "applyCompletion"; S13 "shouldTriggerFileCompletion"; S14
    "ping"/"bye"/"getCommands". Each handler closes over getToken()/getProvider() in
    pi-editor-bridge.ts (registered FROM there, so no connection.ts → pi-editor-bridge.ts import).
  - ConnectionState { handshakeComplete }        → S9's hello handler sets it true;
    S10's gate reads it (`if (!state.handshakeComplete && method !== "hello") ...`).
  - sendError(sock, id, -32600, "bad token")     → S9's handshake-failure path (PRD §5.3).
  - sendNotification(sock, "commandsChanged")    → S17's S→C broadcast on provider rebuild.
  - handleLine(sock, state, line)                → S10 may add ONE guard inside the request
    branch (or wrap dispatch); S8 leaves the request branch open (no gate yet).
  - onConnection(sock)                           → pi-editor-bridge.ts's startBridge passes it
    to __deps.createServer (UNCHANGED line).
NO process.env write; no socket bind (that's startBridge in S5); no DB/config.
NO tsconfig compilerOptions change:
  - The ONLY tsconfig edit is appending "connection.ts" to the include array (Task 2).
  - node:net (Socket type) / node:events (test fake) / Buffer resolve via the PROGRAM-WIDE
    transitive @types/node (S7 research §3). Do NOT add typeRoots/types/lib.
NO protocol.ts / jsonl-reader.ts change:
  - connection.ts narrows into S4's envelopes and consumes S7's reader/serializer. Both UNCHANGED.
MINIMAL pi-editor-bridge.ts change (Task 3): import + delete placeholder + drop unused type Socket.
  - Everything else (startBridge/stopBridge/getServer/getSocketPath/getToken/getProvider/
    captureProvider/liveProvider/__deps) is UNCHANGED. S5's test is robust to the import swap.
```

## Validation Loop

### Level 1: Syntax & Style (Immediate Feedback) — THE TYPE GATE

```bash
# Type-check connection.ts + jsonl-reader.ts + protocol.ts + pi-editor-bridge.ts + all tests
# via the paths-mapped dev tsconfig. Load-bearing checks for S8: the `import type { Socket }
# from "node:net"` resolves (transitively, S7 research §3); the JsonRpcError type-only import
# from protocol.ts resolves; handleLine's await of `handler(params, state)` type-checks;
# onConnection's createServer wiring compiles; the test's EventEmitter/net imports resolve.
# Failures are usually: a typo in an import, a missing export, or an accidental
# compilerOptions edit that broke the transitive node:* resolution.
tsc --noEmit -p extension/tsconfig.json
# Expected: exit 0, NO output.

# Indentation sanity (house style = TABS, like every existing extension file):
grep -nP '^    ' extension/connection.ts extension/tests/connection.test.ts \
  && echo "WARN: space-indent lines found" || echo "indent OK (tabs)"

# Confirm the ONLY tsconfig change is the include line (compilerOptions byte-identical):
grep -nE '"(types|typeRoots|lib|paths)"' extension/tsconfig.json \
  && echo "WARN: did S8 accidentally edit compilerOptions? (it should NOT)" \
  || echo "PASS: no compilerOptions keys present (S8 only edited include)"

# Confirm connection.ts is in include; onConnection is imported + the placeholder is GONE;
# connection.ts does NOT import pi-editor-bridge.ts (no cycle):
grep -n '"connection.ts"' extension/tsconfig.json && echo "include OK"
grep -n 'import { onConnection } from "./connection.ts"' extension/pi-editor-bridge.ts \
  && echo "PASS: onConnection imported from connection.ts" || echo "FAIL: import missing"
grep -n 'TODO(S8): wire the JSONL reader' extension/pi-editor-bridge.ts \
  && echo "FAIL: S8 placeholder comment still present (S8 must delete it)" \
  || echo "PASS: S8 placeholder deleted"
grep -n 'from "./pi-editor-bridge' extension/connection.ts \
  && echo "FAIL: connection.ts imports pi-editor-bridge.ts (import CYCLE — remove it)" \
  || echo "PASS: no cycle (connection.ts does not import pi-editor-bridge.ts)"
```

### Level 2: Unit Tests (Component Validation)

```bash
JITI_REG=/home/dustin/.local/lib/node_modules/@earendil-works/pi-coding-agent/node_modules/jiti/lib/jiti-register.mjs

# Run the new connection suite. Expected: exit 0, `ℹ fail 0` (the parse-error, handler-throw,
# invalid-envelope, and socket-error tests prove S8 never crashes pi and never hangs a request;
# the real-socket test proves end-to-end framing).
node --import "$JITI_REG" extension/tests/connection.test.ts
# (jiti prints a benign DeprecationWarning on Node 26 stderr — judge by exit code + ℹ fail.)

# Full regression: every pre-existing suite still green (S8 is additive: 1 new module + 1 new
# test + 1-line include edit + minimal pi-editor-bridge.ts wiring; the only thing that changed
# for them is onConnection is now imported — S5's test mocks createServer so it's invisible).
# Expected: each prints `ℹ fail 0`.
for t in provider-capture mode-guard protocol bridge-lifecycle bridge-lifecycle-wiring jsonl-reader; do
  echo "--- $t ---"
  node --import "$JITI_REG" "extension/tests/$t.test.ts" 2>/dev/null | grep -E "^ℹ (pass|fail)"
done
```

### Level 3: Integration Testing (System Validation)

```bash
# Regression: the extension still loads cleanly under pi. UNLIKE S7 (whose module was dead code
# until S8 imported it), connection.ts IS now imported by the entry point — so this proves S8's
# import + placeholder deletion + the createServer wiring didn't break the load path.
# Expected: exits 0, prints "ok", NO error lines.
pi --no-extensions -e ./extension/pi-editor-bridge.ts --print "ok" 2>&1 | tee /tmp/s8-pi.log
grep -iE "error|cannot|fail|throw|TypeError" /tmp/s8-pi.log && echo FAIL || echo PASS

# (Optional, manual) End-to-end socket smoke: spin up startBridge, connect a client, send a
# JSON-RPC request, observe the -32601 response (registry is empty until S9). Confirms S8's
# onConnection is reached through the REAL startBridge server (the Level 2 real-socket test
# already does this against createServer directly; this variant goes through startBridge):
#   JITI_REG=…; node --import "$JITI_REG" -e '
#     const {startBridge,getSocketPath,stopBridge}=await import("./extension/pi-editor-bridge.ts");
#     const net=await import("node:net"); const {}=await import("./extension/connection.ts");
#     startBridge({} /*ctx*/); const c=net.connect(getSocketPath());
#     c.on("connect",()=>c.write(JSON.stringify({jsonrpc:"2.0",id:"x",method:"ping"})+"\n"));
#     c.on("data",d=>{console.log(String(d)); stopBridge(); process.exit(0);});
#   '
# (Skip if Level 2 is green — the real-socket test is authoritative for the connection wiring.)
```

### Level 4: Creative & Domain-Specific Validation

```bash
# (S8's domain contract IS the dispatch correctness — fully covered by the Level 2 suite.
#  No performance / security validation beyond Levels 1–3 for a 1-point dispatch task.)
# Dispatch-pattern cross-check: confirm handleLine mirrors pi's rpc-mode handleInputLine SHAPE
# (separate try/catch for parse vs handler-call; always-respond-for-request; error-on-throw):
diff <(echo 'parse try/catch -> error response; narrow; dispatch try/catch -> result|error response; notification -> no response') \
     <(grep -oE 'try \{|catch \(|sendError|sendResponse|return;' extension/connection.ts | sort -u | tr '\n' ' ') \
  >/dev/null 2>&1 && echo "SHAPE OK (parse-catch + handler-catch + sendError/sendResponse present)" \
  || echo "WARN: review handleLine against pi's handleInputLine pattern"
# Expected: the structural elements (two try/catches, sendError, sendResponse, the notification
# no-response return) are all present in connection.ts.

# Security cross-check (PRD §12): the sock.on("error") log line MUST NOT include the token or
# the BridgeDescriptor. Confirm the handler logs only the Error message:
grep -nA2 'sock.on("error"' extension/connection.ts | grep -iE 'token|descriptor|PI_NVIM_BRIDGE' \
  && echo "FAIL: token/descriptor leaked into the error log (PRD §12 violation)" \
  || echo "PASS: error log emits only the Error message (PRD §12 honored)"
```

## Final Validation Checklist

### Technical Validation

- [ ] `tsc --noEmit -p extension/tsconfig.json` → exit 0, no output.
- [ ] `node --import "$JITI_REG" extension/tests/connection.test.ts` → exit 0, `ℹ fail 0`.
- [ ] All 6 pre-existing suites report `ℹ fail 0` (regression).
- [ ] `pi --no-extensions -e ./extension/pi-editor-bridge.ts --print "ok"` exits 0, no error lines.

### Feature Validation

- [ ] `sendResponse`/`sendError`/`sendNotification` produce strict LF-terminated JSON-RPC 2.0
      envelopes; the notification has NO `id`.
- [ ] `handleLine` handles: registered-handler success response; method-not-found (`-32601`);
      unregistered notification (no response); registered notification (handler called, no
      response); malformed JSON (`-32700`, no throw); handler throw (`-32603`, no throw);
      invalid envelope (`-32600`, no throw).
- [ ] `onConnection` wires S7's reader; creates a fresh `ConnectionState` (handshakeComplete:
      false); attaches `sock.on("error")` (log + detach + destroy, no throw, no token leak) and
      `sock.on("close")` (detach).
- [ ] The handler registry starts EMPTY; S8 registers NONE (S9–S14 do).
- [ ] A real Unix socket pair round-trips a request → response end-to-end (Level 2 TEST 13).

### Code Quality Validation

- [ ] `connection.ts` imports ONLY `./jsonl-reader.ts` (values) + `./protocol.ts` (types) — NO
      `pi-editor-bridge.ts` import (no cycle — Level 1 grep confirms).
- [ ] Node builtins only (`node:net` type-only via the passed-in Socket; `node:events` in the
      test fake) — no npm deps (PRD §6.7).
- [ ] TAB indentation; `import type` for `Socket` + `JsonRpcError`; Mode-A JSDoc with
      `STATUS (P1.M2.T4.S8)` markers + the S7-sibling + S9–S14 forward-refs.
- [ ] The ONLY tsconfig change is appending `"connection.ts"` to `include`;
      `compilerOptions` UNCHANGED.
- [ ] `pi-editor-bridge.ts` change is minimal: import added, local placeholder + `// TODO(S8)`
      deleted, `createServer` line UNCHANGED, unused `type Socket` dropped.
- [ ] `protocol.ts` and `jsonl-reader.ts` are byte-for-byte UNCHANGED.

### Documentation & Deployment

- [ ] Module JSDoc cites PRD §5.3/§5.4/§6.7/§12 + pi's `rpc-mode handleInputLine` as the
      dispatch PATTERN mirror + the S7 sibling as the framing half.
- [ ] Every export has a `STATUS (P1.M2.T4.S8)` marker + a forward ref (S9 hello / S10 gate /
      S11–S14 handlers / S15 per-handler errors / S17 commandsChanged notification).
- [ ] No new environment variables, no config, no process.env writes, no socket bind.

---

## Anti-Patterns to Avoid

- ❌ **Don't defer ALL error handling to S15.** S8's dispatch loop MUST try/catch BOTH
  `JSON.parse` (`-32700`) AND the registered-handler call (`-32603`). Without them: a malformed
  line or a throwing handler is an unhandled async rejection → pi crashes (violates PRD §6.7
  "never throws from handlers"), AND a request hangs (the client waits for its RPC timeout with
  no reply). S15's job is to make each handler catch its OWN domain errors into proper codes
  BEFORE they reach S8's safety net — non-overlapping. (research §1.)
- ❌ **Don't import `pi-editor-bridge.ts` from `connection.ts`.** That creates a cycle
  (`pi-editor-bridge.ts` imports `onConnection` from `connection.ts`). Handlers are registered
  FROM `pi-editor-bridge.ts` (S9–S14), where they close over `getToken()`/`getProvider()` in the
  SAME module — so `connection.ts` never reaches back. A cycle breaks jiti's ESM load. (research §2.)
- ❌ **Don't skip `sock.on("error", …)`.** An unhandled socket `'error'` (ECONNRESET, EPIPE,
  client-killed) THROWS and crashes pi (Node EventEmitter contract — same as the `net.Server`
  'error' S6 handled). Attach it UNCONDITIONALLY in `onConnection`, BEFORE any data flows. Log
  the Error.message ONLY (NEVER the token / descriptor — PRD §12); `detach()`; `sock.destroy()`;
  NEVER rethrow. (research §6.)
- ❌ **Don't respond to a notification.** JSON-RPC 2.0: a message with no `id` is a notification
  and expects NO reply. `handleLine` must call the handler (if registered) and write nothing.
  Responding to a notification hangs nothing on the wire but pollutes the socket and violates
  the protocol the Neovim client (P2.M5) relies on. (research §4.)
- ❌ **Don't treat a numeric/null `id` as a request.** The bridge RESTRICTS `id` to `string`
  (PRD §5.3). Narrow accordingly: only a present string `id` makes a message a request; anything
  else with a `method` is a notification; anything without a string `method` is a `-32600`
  invalid request. (research §4.)
- ❌ **Don't register a handler in S8.** S8 ships an EMPTY registry — S9 registers `hello`,
  S11–S14 register the rest. Registering one now (e.g. a `ping` stub) would duplicate S14's work
  and blur the task boundary. The dispatch is exercised via the `__resetHandlersForTest` test
  seams that register throwaway handlers inside `try/finally`.
- ❌ **Don't implement the `hello` handshake or the handshake gate.** Token validation is S9;
  the `if (!state.handshakeComplete && method !== "hello")` gate is S10. S8 creates the
  `ConnectionState` (`handshakeComplete:false`) so S9/S10 have it, but leaves the request branch
  open. Implementing either now is scope creep into S9/S10.
- ❌ **Don't edit `compilerOptions` in tsconfig.** The transitive `node:*` resolution
  (S7 research §3) depends on `compilerOptions` being EXACTLY as-is. A `typeRoots`/`types`/`lib`
  change can BREAK `node:net`/`node:events`/`Buffer` resolution (verified by a failed probe). The
  ONLY edit is appending `"connection.ts"` to `include`.
- ❌ **Don't use vitest.** The bridge extension's house convention is `node:test` +
  `node:assert/strict` + jiti (verified across all 6 existing suites). Use a fake
  `EventEmitter`-based socket for the unit tests + ONE real `net.createServer`+`net.connect`
  integration test (mirroring `bridge-lifecycle.test.ts`'s mocked+real split).
- ❌ **Don't touch `startBridge`/`stopBridge`/the getters/`__deps` in `pi-editor-bridge.ts`.**
  S8's only edits there are: add the `onConnection` import, delete the local placeholder, drop the
  unused `type Socket`. The `__deps.createServer((sock) => onConnection(sock))` line is UNCHANGED
  (now resolves to the import). S5's test mocks `createServer` and is robust to the swap.
- ❌ **Don't leak the registry across tests.** It's MODULE-LEVEL state. Every test that calls
  `registerBridgeHandler` MUST `__resetHandlersForTest()` in a `finally` (mirror
  `bridge-lifecycle.test.ts`'s `try/finally` state restoration). Without it, one test's handler
  leaks into the next and tests become order-dependent.
