name: "P1.M2.T5.S10 — Reject any method before a valid handshake (handshake gate)"
description: "pi-editor-bridge extension (TS). Add a one-guard gate to handleLine in extension/connection.ts that rejects every JSON-RPC method except `hello` until ConnectionState.handshakeComplete is true (flipped by S9's hello handler on a correct token). PRD §12. Non-fatal -32600 for requests; silent drop for notifications. Updates the ONE existing real-socket integration test whose no-hello-first sequence the gate changes; adds a focused handshake-gate.test.ts. node:test + jiti (NOT vitest)."

---

## Goal

**Feature Goal**: Complete the auth-ordering half of the bridge handshake. S9
*set* `ConnectionState.handshakeComplete = true` on a correct `hello` token;
**S10 *reads* it**: until it is `true`, `handleLine` must reject every method
except `"hello"`. This enforces PRD §12 — *"The bridge must reject any method
before a valid `hello`"* — so an unauthenticated peer (one that never sent a
valid `hello`) cannot drive pi's completion engine, read the cwd, or trigger any
handler side effect. The gate is method-agnostic: it does not need to know which
methods S11–S14 will register.

**Deliverable**:
1. `extension/connection.ts` — ONE behavioral edit to `handleLine`: a ~6-line
   gate inserted after the id-discipline check and before the notification
   branch. REQUESTs before handshake → `-32600 "handshake required: send hello
   first"` (non-fatal: no socket close, consistent with every other direct
   `sendError` path in `handleLine`). NOTIFICATIONs before handshake → dropped
   silently (no response, and the handler is NOT invoked).
2. `extension/tests/handshake-gate.test.ts` (NEW) — dispatch + one real
   Unix-socket integration test for the gate.
3. `extension/tests/connection.test.ts` — update the ONE real-socket integration
   test (test 13) whose no-`hello`-first `ping` sequence the gate changes from
   `-32601` to `-32600`.

**Success Definition**: With the bridge running, a client that connects and
sends any method other than `hello` as its first message receives a `-32600`
response (and the connection stays open so it can still send a valid `hello`);
once it sends a correct-token `hello`, subsequent methods dispatch normally.
A pre-handshake notification is silently ignored. `tsc --noEmit` is clean; the
new suite passes; **all 16 existing connection tests still pass** (15 untouched
by construction + 1 updated); all other extension suites (S2–S9) stay green.

---

## User Persona

**Target User**: The `pi-bridge.nvim` Neovim plugin (P2.M5) — the bridge's only
client. (Indirectly: the human editing a pi prompt in their `$EDITOR`.)

**Use Case**: On `VimEnter`, after reading `PI_NVIM_BRIDGE`, the plugin opens a
socket connection and sends `hello` FIRST, waiting for the `HelloResult` before
sending anything else (synchronous request/response RPC). The gate is the
server-side enforcement of that ordering.

**Pain Points Addressed**: Defense-in-depth on top of the token (PRD §12). Even
though the 32-hex token is the real auth boundary, the gate guarantees that a
peer which somehow connected (stale socket, same-user process, bug) but has NOT
authenticated cannot invoke `getSuggestions`/`applyCompletion`/etc. — it cannot
drive pi's completion engine, spawn `fd`, or read `cwd` until it proves it holds
the token.

---

## Why

- **Closes the handshake task (PRD §12 / §5.3)**: S9 set the flag; S10 is the
  read-side that makes the flag *mean* something. Without S10, the flag is set
  but never checked — `hello` would be optional and any method would dispatch
  pre-auth.
- **Defense before S11–S14 land**: once `getSuggestions` (S11) and friends are
  registered, the module-level registry is reachable from ANY connection. S10
  ensures only authenticated connections reach those handlers. Landing S10 now
  (before S11) means S11's handlers are born behind the gate.
- **Unblocks/mirrors P2.M5**: the Neovim client's `hello`-first discipline
  (S25) is the counterpart to this server-side gate; both must agree on the
  ordering contract.
- **Consistency**: the gate uses the SAME `-32600` code and the SAME non-fatal
  `sendError` pattern as the existing parse-error (`-32700`) and
  invalid-envelope (`-32600`) paths in `handleLine`. No new error mechanism.

---

## What

### User-visible behavior (wire)

For each incoming JSONL line on a connection where
`state.handshakeComplete === false`:

| Incoming message | Server action |
|---|---|
| `{"jsonrpc":"2.0","method":"hello","id":"h1",...}` | **Exempt** — dispatched to the `hello` handler (S9): good token ⇒ `HelloResult` + flips the flag; bad token ⇒ `-32600 "bad token"` + `sock.end()` (unchanged). |
| Any other **REQUEST** (`id` present, any other method) | Send exactly one `{"jsonrpc":"2.0","id":<id>,"error":{"code":-32600,"message":"handshake required: send hello first"}}`. Connection stays OPEN. The registered handler (if any) is **not** called. |
| Any **NOTIFICATION** (no `id`, any method) | No response (JSON-RPC 2.0 forbids it). The handler (if any) is **not** called. |

Once `state.handshakeComplete === true` (after a correct `hello`), the gate is a
no-op and dispatch proceeds exactly as in S8/S9.

### Success Criteria

- [ ] A REQUEST whose method is not `"hello"`, on a `handshakeComplete:false`
      connection, yields exactly one `-32600 "handshake required: send hello
      first"` response with the request's `id`; the registered handler is NOT
      called; the socket is NOT closed.
- [ ] A NOTIFICATION (no `id`) on a `handshakeComplete:false` connection yields
      no response and the handler is NOT called.
- [ ] `"hello"` is exempt from the gate (still routed to the S9 handler — good
      token ⇒ success + flag flip; bad token ⇒ `-32600`+close).
- [ ] After `handshakeComplete:true`, normal dispatch is unaffected (gate is a
      no-op); e.g. a registered `ping` returns its result.
- [ ] The gate fires BEFORE registry lookup: an UNREGISTERED method sent
      pre-handshake returns `-32600` (NOT `-32601`).
- [ ] The token value NEVER appears in any response or stderr (PRD §12).
- [ ] `tsc --noEmit -p extension/tsconfig.json` ⇒ exit 0, no output.
- [ ] New `handshake-gate.test.ts` passes; `connection.test.ts` passes (test 13
      updated); every other `extension/tests/*.test.ts` ⇒ `ℹ fail 0`.

---

## All Needed Context

### Context Completeness Check

_"If someone knew nothing about this codebase, would they have everything needed
to implement this successfully?"_ — Yes. The dispatch skeleton, per-connection
state, response writers, and the exact gate site are all in `connection.ts` with
inline comments that literally pre-describe this gate. This PRP gives the exact
insertion point, the exact ~6-line code, the one existing test that must change
(and why), and verified test commands. No guessing.

### Documentation & References

```yaml
# MUST READ — the governing spec
- url: PRD §12 (Security) + §5.3 (Connection lifecycle & handshake) + §5.4 (methods table)
  why: "§12 'The bridge must reject any method before a valid hello'; §5.3 handshake ordering + the -32600 'bad token' code (hello's OWN failure path, distinct from this gate); §5.4 shows every C→S method is a REQUEST (carries id) and the only notification (commandsChanged) is S→C — so a client sends NO notifications in v1, but the gate must still defend the notification branch."
  critical: "PRD mandates close ONLY for bad-token hello (S9, via BridgeRpcError fatal). This gate is NON-fatal: 'reject' ≠ 'close'. The token is the real boundary; an unauthenticated peer is fully locked out of results either way."

# MUST READ — the file this task edits (READ BEFORE EDITING)
- file: extension/connection.ts
  why: "handleLine is where the gate goes. Its STATUS comment and the ConnectionState JSDoc BOTH pre-describe S10 ('if (!state.handshakeComplete && method !== hello) gate'). sendError(sock,id,code,msg) is the writer to reuse. ConnectionState.handshakeComplete is the flag S9 sets and S10 reads."
  pattern: "handleLine structure: (A) parse→-32700, (B) narrow→-32600, id-discipline→-32600, (C) notification branch, (D) request branch. The existing -32700/-32600 cases call sendError DIRECTLY and do NOT close — mirror that (non-fatal)."
  gotcha: "INSERT the gate AFTER the id-discipline check (`if (\"id\" in parsed && typeof idField !== \"string\") { sendError(...); return; }`) and BEFORE the `(C) NOTIFICATION` comment — so it covers BOTH branches. `id` (string|null) and `isRequest` (bool) are already defined above; `id as string` is safe when isRequest. Do NOT touch the parse/narrow/notification/request branches themselves."

- file: extension/protocol.ts
  why: "CONFIRMS -32600 is the reserved JSON-RPC 2.0 code for invalid request / handshake-auth failure (its §A comment lists the reserved codes; S9 used -32600 for bad token). CONSUME types; this task adds NO new types."
  gotcha: "protocol.ts is TYPES-ONLY (zero runtime exports). The gate adds no runtime export to protocol.ts (it adds none anywhere — the gate is internal handleLine logic)."

- file: extension/tests/connection.test.ts
  why: "the EXACT fakeSocket() helper to reuse (EventEmitter + write capture + end() records + emits close), the registerBridgeHandler+__resetHandlersForTest-in-try/finally pattern, and the ONE test (test 13 'REAL: end-to-end ...') that MUST be updated because it sends `ping` with NO hello first (expects -32601) — under the gate that becomes -32600."
  pattern: "ALL handleLine dispatch tests already pass { handshakeComplete: true } (lines 77,88,98,111,125,139,159,180,203,220) — the S8 author pre-set the flag precisely so the S10 gate wouldn't break them. ONLY test 13 (uses onConnection → fresh handshakeComplete:false) changes."
  gotcha: "fakeSocket() and parseResponses() are defined locally in connection.test.ts (not exported). For handshake-gate.test.ts, COPY fakeSocket()/parseResponses() verbatim (S9's hello-handler.test.ts did the same)."

- file: extension/tests/hello-handler.test.ts
  why: "the sibling suite (S9) — confirms the per-subtask-suite convention (S7→jsonl-reader, S8→connection, S9→hello-handler, S10→handshake-gate), the REAL Unix-socket integration test shape (createServer+onConnection+connect+once+readFirstResponse), and that `hello` is dispatched fine with handshakeComplete:false (it's exempt)."
  pattern: "makeHelloHandler({getToken,getCwd,getFdAvailable,version}) with stubbed deps for tests; serializeJsonLine/attachJsonlLineReader from jsonl-reader.ts; __resetHandlersForTest() in finally."

# Prior plan context (READ for rationale; do NOT copy code blindly)
- docfile: plan/001_c56962b4fa17/P1M2T5S10/research/notes.md
  section: "§3 (gate placement + the fatal-vs-non-fatal decision), §4 (the ONE test that breaks + fix), §5 (new tests)"
  why: "the why behind every non-obvious choice — esp. WHY non-fatal (consistency + the token is the real boundary) and WHY the gate must cover notifications too (module-level registry + future S11 handler side effects)."
- docfile: plan/001_c56962b4fa17/P1M2T5S9/research/notes.md
  section: "§10 (explicitly defers THIS gate to S10), §7 (test convention — NOT vitest)"
  why: "confirms S9 deliberately did NOT add the gate; S9 only SETS the flag."
```

### Current Codebase tree

```bash
extension/
├── pi-editor-bridge.ts     # S1/S3/S5/S6/S9: lifecycle, provider capture, start/stopBridge, makeHelloHandler, getToken/getCwd/getFdAvailable/BRIDGE_VERSION
├── protocol.ts             # S4: ALL wire types (TYPES-ONLY) — incl. -32600 reserved-code comment
├── jsonl-reader.ts         # S7: attachJsonlLineReader, serializeJsonLine
├── connection.ts           # S8/S9: ConnectionState, registerBridgeHandler, send*, BridgeRpcError, handleLine, onConnection  ← EDIT (add the gate in handleLine)
├── tsconfig.json
└── tests/
    ├── provider-capture.test.ts        # S2
    ├── mode-guard.test.ts              # S3
    ├── protocol.test.ts                # S4
    ├── bridge-lifecycle.test.ts        # S5/S6
    ├── bridge-lifecycle-wiring.test.ts # S6
    ├── jsonl-reader.test.ts            # S7
    ├── connection.test.ts              # S8/S9 (16 tests)  ← EDIT (update test 13 REAL integration)
    └── hello-handler.test.ts           # S9
```

### Desired Codebase tree (files this task touches)

```bash
extension/
├── connection.ts                          # MODIFY: + handshake gate (~6 lines) in handleLine
└── tests/
    ├── connection.test.ts                 # MODIFY: update test 13 (REAL integration) to hello-first sequence
    └── handshake-gate.test.ts             # CREATE: dispatch (request/notification/exempt/post-handshake/before-registry) + ONE real Unix-socket integration + token-never-leaked
```

### Known Gotchas of our codebase & Library Quirks

```ts
// CRITICAL: place the gate AFTER the id-discipline check and BEFORE the
//   `(C) NOTIFICATION` branch — NOT inside the request branch alone. The
//   registry is MODULE-LEVEL (shared across connections); once S11 registers
//   getSuggestions, a pre-handshake NOTIFICATION (no id) would otherwise reach
//   branch (C) and invoke the handler. The unified placement returns before
//   either branch, defending both. (research §3)

// CRITICAL: the gate must fire BEFORE registry lookup. An UNREGISTERED method
//   sent pre-handshake must return -32600 (handshake), NOT -32601 (not found).
//   (Locks in placement + the new test #5.) The current request branch does
//   `if (!handler) { sendError(-32601) }` — the gate's early `return` prevents
//   reaching it.

// CRITICAL: NON-FATAL. Use sendError(-32600) + return. Do NOT call sock.end().
//   Every other direct-sendError path in handleLine (parse -32700, invalid
//   envelope -32600, bad id -32600) does NOT close. ONLY BridgeRpcError with
//   fatal:true (S9 hello bad-token) closes. The gate is in handleLine (not a
//   handler), so it can't use BridgeRpcError.fatal anyway. PRD §12 says
//   "reject", not "close"; §5.3 mandates close only for bad-token hello.
//   (research §3 — full reasoning.)

// GOTCHA: the ONE existing test that changes is connection.test.ts test 13
//   ("REAL: end-to-end JSONL round-trip ..."). It uses onConnection (fresh
//   handshakeComplete:false) and sends `ping` first with NO hello, expecting
//   -32601. Under the gate that becomes -32600. ALL OTHER connection.test.ts
//   dispatch tests pass { handshakeComplete: true } and are unaffected.
//   hello-handler.test.ts sends `hello` (exempt) and is unaffected.

// GOTCHA: fakeSocket()/parseResponses() are LOCAL to connection.test.ts (not
//   exported). COPY them verbatim into handshake-gate.test.ts (S9's
//   hello-handler.test.ts did the same — it's the established pattern).

// CONVENTION: node:test + jiti (NOT vitest). TAB indentation. Test seams named
//   __xForTest. registerBridgeHandler + __resetHandlersForTest() in try/finally.
//   One REAL Unix-socket integration test per suite (createServer+onConnection+
//   connect+once+readFirstResponse helper).

// SECURITY: the message is the literal "handshake required: send hello first" —
//   NEVER the token value (PRD §12). The gate doesn't read the token at all
//   (that's hello's job), so leakage is structurally impossible, but keep the
//   message token-free regardless.
```

---

## Implementation Blueprint

### Data models and structure

**No new types. No new runtime exports.** S10 consumes:
- `ConnectionState { handshakeComplete: boolean }` (connection.ts, S8) — reads
  `handshakeComplete`; never writes it (S9's hello handler owns the write).
- `sendError(sock, id: string|null, code, message)` (connection.ts, S8) — the
  response writer; `id as string` is safe because `isRequest` guarantees a
  string id.

The gate is pure control flow inside `handleLine`.

### Implementation Tasks (ordered by dependencies)

```yaml
Task 1: MODIFY extension/connection.ts — add the handshake gate in handleLine
  - INSERT: a ~6-line gate (code below) in `handleLine`, AFTER the id-discipline
    check (`if ("id" in (parsed as object) && typeof idField !== "string") {
    sendError(...); return; }`) and BEFORE the `// (C) NOTIFICATION` comment.
  - GATE BODY: `if (method !== "hello" && !state.handshakeComplete) { if
    (isRequest) { sendError(sock, id as string, -32600, "handshake required:
    send hello first"); } return; }`
  - DO NOT touch: the parse-catch (-32700), the envelope-narrow (-32600), the
    id-discipline check, the notification branch (C), the request branch (D),
    onConnection, BridgeRpcError, MethodHandler, or any response writer.
  - DO NOT close the socket (non-fatal). DO NOT add sock.end().
  - UPDATE the inline STATUS comment on handleLine to note S10 is now DONE
    (move the "S10 adds ..." note into past tense / mark complete) — keep the
    file's roadmap comments accurate (the repo convention; see how S8/S9
    comments cross-reference task status).

Task 2: MODIFY extension/tests/connection.test.ts — update test 13 (REAL integration)
  - THE PROBLEM: test 13 sends `ping` as the FIRST message (no `hello`) via a
    real socket (`onConnection` ⇒ fresh handshakeComplete:false) and asserts
    `r1.error.code === -32601`. Under the S10 gate the first `ping` now returns
    -32600, so that assertion fails.
  - THE FIX (hello-first sequence — strictly better coverage than just flipping
    the expected code): BEFORE the client connects, register a `"hello"` handler
    via `makeHelloHandler({ getToken: () => TOKEN, getCwd: () => "/tmp",
    getFdAvailable: () => true, version: BRIDGE_VERSION })` (import
    makeHelloHandler + BRIDGE_VERSION from ../pi-editor-bridge.ts, mirroring
    hello-handler.test.ts). Then the client:
      (1) sends `hello` (correct token) ⇒ assert HelloResult;
      (2) sends `ping` (still unregistered) ⇒ assert -32601 (preserves the
          original method-not-found assertion, now post-handshake);
      (3) registerBridgeHandler("ping", () => ({ ok: true }));
      (4) sends `ping` again ⇒ assert success { ok: true } (preserves the
          original success assertion).
    Keep __resetHandlersForTest() in finally. Rename the test if helpful
    ("REAL: end-to-end JSONL round-trip (hello → method-not-found → success)").
  - ALTERNATIVE (acceptable, less faithful): leave the sequence, change the
    first-message expectation from -32601 to -32600. The PRP recommends the
    hello-first variant.
  - DO NOT change any of the 15 other tests — they pass
    { handshakeComplete: true } and are unaffected.

Task 3: CREATE extension/tests/handshake-gate.test.ts — gate-focused suite
  - IMPORTS: `import { test } from "node:test"; import assert from
    "node:assert/strict";` + `EventEmitter, once` from node:events +
    `createServer, connect, type Socket` from node:net + `randomUUID` from
    node:crypto + `tmpdir` from node:os + `join` from node:path + from
    ../connection.ts: `handleLine, registerBridgeHandler, __resetHandlersForTest,
    type ConnectionState` + from ../pi-editor-bridge.ts: `makeHelloHandler,
    BRIDGE_VERSION` + from ../jsonl-reader.ts: `attachJsonlLineReader,
    serializeJsonLine`.
  - COPY fakeSocket()/parseResponses()/readFirstResponse() verbatim from
    connection.test.ts (they are local helpers; S9 did the same).
  - DISPATCH tests (fakeSocket + handleLine directly; registerBridgeHandler +
    __resetHandlersForTest in try/finally):
    1. REQUEST pre-handshake (state {handshakeComplete:false}; register a
       "ping" handler with a `called` flag) → exactly one response, code -32600,
       message "handshake required: send hello first", id == request id,
       `handler called === false`, `state.ended === false` (non-fatal).
    2. NOTIFICATION pre-handshake (no id; register a "something" handler with a
       `called` flag) → `writes.length === 0`, `handler called === false`.
    3. `hello` is EXEMPT pre-handshake: register makeHelloHandler (good token);
       send hello JSONL with handshakeComplete:false → routes to handler →
       HelloResult + handshakeComplete flips true (regression that the gate
       doesn't swallow hello). (hello-handler.test.ts already covers hello
       deeply; this just asserts the gate's exemption.)
    4. POST-handshake no-op: state {handshakeComplete:true}; register "ping"
       () => ({ok:true}); send ping → success result { ok: true } (gate doesn't
       over-block after auth).
    5. GATE BEFORE REGISTRY: state {handshakeComplete:false}; send an
       UNREGISTERED method (e.g. "nope") → -32600 (NOT -32601). Locks placement.
  - REAL integration (ONE real Unix-socket pair; createServer((c)=>onConnection(c))
    + register hello handler with fixed TOKEN):
    6. Client sends `ping` first (no hello) → -32600; then `hello` (correct
       token) → HelloResult; then `ping` again → now dispatches (still
       unregistered ⇒ -32601). Asserts the gate OPENS after a real handshake
       over a real socket. __resetHandlersForTest() in finally.
  - TOKEN-NEVER-LEAKED: after running the dispatch tests, assert no write/stderr
    contains the TOKEN constant (PRD §12). (The gate message is fixed and
    token-free; this is belt-and-suspenders.)

Task 4: VALIDATE (see Validation Loop) — tsc clean; new + all existing suites green.
```

### Implementation Patterns & Key Details

```ts
// === Task 1: extension/connection.ts — the handshake gate in handleLine ===
// INSERT this block AFTER the id-discipline check and BEFORE `// (C) NOTIFICATION`.
// (All referenced names — `method`, `state`, `isRequest`, `id`, `sendError`, `sock`
//  — are already in scope at that point.)
	// S10 handshake gate (PRD §12): reject every method except "hello" until S9's
	// hello handler flips `state.handshakeComplete` on a correct token. Placed
	// BEFORE the notification/request split so it defends BOTH branches (the
	// registry is module-level — a pre-handshake notification must not reach a
	// registered handler either). NON-FATAL: consistent with the parse (-32700)
	// and envelope-narrow (-32600) paths here, which call sendError directly and
	// do NOT close; only bad-token hello closes (S9, via BridgeRpcError fatal).
	// The token is the real boundary (PRD §12); an unauthenticated peer can never
	// flip this flag, so it is permanently locked out of results regardless.
	if (method !== "hello" && !state.handshakeComplete) {
		if (isRequest) {
			sendError(sock, id as string, -32600, "handshake required: send hello first");
		}
		// Notification (no string id): JSON-RPC 2.0 forbids a response. Drop silently.
		return;
	}

// === Task 2: connection.test.ts test 13 — hello-first integration sequence ===
// (Replace the body of the "REAL: end-to-end JSONL round-trip ..." test. Keeps
//  the -32601 + success assertions, now post-handshake, and exercises the gate.)
const TOKEN = "deadbeefdeadbeefdeadbeefdeadbeef";
registerBridgeHandler(
	"hello",
	makeHelloHandler({ getToken: () => TOKEN, getCwd: () => "/tmp", getFdAvailable: () => true, version: BRIDGE_VERSION }),
);
const server = createServer((c) => onConnection(c));
server.listen(sockpath);
await once(server, "listening");
try {
	const client = connect(sockpath);
	await once(client, "connect");

	// (1) hello first ⇒ HelloResult (gate exempt; flips handshakeComplete true)
	const rHello = await readJson(client, serializeJsonLine({
		jsonrpc: "2.0", id: "h1", method: "hello", params: { token: TOKEN },
	}));
	assert.equal(rHello.id, "h1");
	assert.deepEqual(rHello.result, { ok: true, serverVersion: BRIDGE_VERSION, cwd: "/tmp", fdAvailable: true });

	// (2) ping still unregistered ⇒ -32601 (preserves original assertion, now post-auth)
	const r1 = await readJson(client, serializeJsonLine({ jsonrpc: "2.0", id: "r1", method: "ping" }));
	assert.equal(r1.id, "r1");
	assert.equal(r1.error.code, -32601);

	// (3) register ping; (4) success (preserves original success assertion)
	registerBridgeHandler("ping", () => ({ ok: true }));
	const r2 = await readJson(client, serializeJsonLine({ jsonrpc: "2.0", id: "r2", method: "ping" }));
	assert.deepEqual(r2, { jsonrpc: "2.0", id: "r2", result: { ok: true } });

	client.destroy();
} finally {
	__resetHandlersForTest();
	server.close();
}
// readJson helper: write a line, resolve the first JSONL response line (reuse
// the existing readFirstResponse shape: attachJsonlLineReader on the client).

// === Task 3: handshake-gate.test.ts — the five dispatch assertions (shapes) ===
// (1) REQUEST pre-handshake
registerBridgeHandler("ping", () => { called = true; return { ok: true }; });
const { sock, writes, state } = fakeSocket();
await handleLine(sock, { handshakeComplete: false }, JSON.stringify({
	jsonrpc: "2.0", id: "p1", method: "ping", params: {},
}));
assert.deepEqual(parseResponses(writes), [{
	jsonrpc: "2.0", id: "p1", error: { code: -32600, message: "handshake required: send hello first" },
}]);
assert.equal(called, false, "handler must NOT run pre-handshake");
assert.equal(state.ended, false, "gate is non-fatal — socket stays open");

// (2) NOTIFICATION pre-handshake — no response, no handler call
registerBridgeHandler("something", () => { called2 = true; });
const { sock: s2, writes: w2 } = fakeSocket();
await handleLine(s2, { handshakeComplete: false }, JSON.stringify({
	jsonrpc: "2.0", method: "something", params: {},
}));
assert.equal(w2.length, 0, "notifications get no response");
assert.equal(called2, false, "notification handler must NOT run pre-handshake");

// (5) GATE BEFORE REGISTRY — unregistered method pre-handshake ⇒ -32600 not -32601
const { sock: s5, writes: w5 } = fakeSocket();
await handleLine(s5, { handshakeComplete: false }, JSON.stringify({
	jsonrpc: "2.0", id: "x1", method: "nope",
}));
assert.equal((parseResponses(w5)[0] as { error: { code: number } }).error.code, -32600);
```

### Integration Points

```yaml
CONNECTION DISPATCH (connection.ts handleLine):
  - The gate is the FIRST method-aware check, sitting between envelope/id
    validation and the notification/request dispatch. hello is the only method
    exempt; all others require handshakeComplete===true.
  - No change to onConnection (still creates { handshakeComplete: false }).
  - No change to BridgeRpcError / MethodHandler / response writers.

SESSION LIFECYCLE (pi-editor-bridge.ts):
  - UNCHANGED. S9 already registers hello on session_start; S10 adds no
    registration (the gate is in handleLine, not a handler). stopBridge ⇒
    getToken()===undefined ⇒ hello ⇒ bad token ⇒ flag never flips ⇒ gate stays
    shut (correct for a stopped bridge — a client connecting to a torn-down
    server can't auth and can't call anything).

DOWNSTREAM:
  - S11–S14 handlers (getSuggestions etc.) are automatically protected by the
    gate: they cannot be reached until hello succeeds. No per-handler auth code
    needed — the gate is method-agnostic.
  - S15 (domain-error wrapping) is unaffected: the gate uses sendError directly,
    never throws, so it never reaches the BridgeRpcError machinery.

PROTOCOL (protocol.ts): CONSUMED, not modified. -32600 is the already-reserved
  handshake/auth code.
```

---

## Validation Loop

### Level 1: Syntax & Type (after the source edit)

```bash
cd /home/dustin/projects/pi-nvim-bridge
tsc --noEmit -p extension/tsconfig.json
# Expected: exit 0, NO output. (TS 5.9.3, Node v26.4.0 — verified baseline.)
```

### Level 2: Unit / component tests (node:test + jiti — NOT vitest)

```bash
JITI_REG=/home/dustin/.local/lib/node_modules/@earendil-works/pi-coding-agent/node_modules/jiti/lib/jiti-register.mjs

# The NEW gate suite (dispatch + real-socket integration + token-never-leaked)
node --import "$JITI_REG" extension/tests/handshake-gate.test.ts
# Expected: exit 0, `ℹ fail 0`. (jiti prints a benign DeprecationWarning on Node 26
# stderr — judge by exit code + the `ℹ pass`/`ℹ fail` summary, ignore the warning.)

# The UPDATED connection suite (test 13 now hello-first; 15 others unchanged)
node --import "$JITI_REG" extension/tests/connection.test.ts
# Expected: exit 0, `ℹ tests 16`, `ℹ pass 16`, `ℹ fail 0`.

# hello-handler suite (regression — `hello` is gate-exempt; must still pass)
node --import "$JITI_REG" extension/tests/hello-handler.test.ts
# Expected: exit 0, `ℹ fail 0`.

# Full extension suite (no regressions across S2–S10)
for t in extension/tests/*.test.ts; do
  echo "--- $t"
  node --import "$JITI_REG" "$t" 2>/dev/null | grep -E "^ℹ (tests|pass|fail)"
done
# Expected: every file `ℹ fail 0`.
```

### Level 3: Integration (a real socket pair, gate end-to-end)

```bash
# Driven by the real-socket test #6 inside handshake-gate.test.ts. To eyeball the
# wire ordering by hand (optional sanity check): connect, send ping (no hello)
# → -32600; then hello → HelloResult; then ping again → now dispatches.
JITI_REG=/home/dustin/.local/lib/node_modules/@earendil-works/pi-coding-agent/node_modules/jiti/lib/jiti-register.mjs
node --import "$JITI_REG" -e '
  const { createServer, connect } = require("node:net");
  const { join } = require("node:path"), { tmpdir } = require("node:os"), { randomUUID } = require("node:crypto");
  const { onConnection, registerBridgeHandler } = await import("./extension/connection.ts");
  const { makeHelloHandler, BRIDGE_VERSION } = await import("./extension/pi-editor-bridge.ts");
  const { serializeJsonLine, attachJsonlLineReader } = await import("./extension/jsonl-reader.ts");
  const TOKEN = "deadbeef".repeat(4);
  registerBridgeHandler("hello", makeHelloHandler({ getToken:()=>TOKEN, getCwd:()=>"/tmp", getFdAvailable:()=>true, version:BRIDGE_VERSION }));
  const sockpath = join(tmpdir(), `gate-${randomUUID()}.sock`);
  const s = createServer(c=>onConnection(c)); s.listen(sockpath);
  s.once("listening", ()=>{
    const cli = connect(sockpath);
    const read = () => new Promise(res=>{ const d=attachJsonlLineReader(cli,l=>{d();res(JSON.parse(l))}); });
    cli.once("connect", async ()=>{
      cli.write(serializeJsonLine({jsonrpc:"2.0",id:"p0",method:"ping"}));           // pre-handshake
      console.log("pre-hello ping:", JSON.stringify(await read()));
      cli.write(serializeJsonLine({jsonrpc:"2.0",id:"h1",method:"hello",params:{token:TOKEN}}));
      console.log("hello:", JSON.stringify(await read()));
      cli.write(serializeJsonLine({jsonrpc:"2.0",id:"p1",method:"ping"}));           // post-handshake, unregistered
      console.log("post-hello ping:", JSON.stringify(await read()));
      cli.destroy(); s.close();
    });
  });
'
# Expected:
#   pre-hello ping:  {"jsonrpc":"2.0","id":"p0","error":{"code":-32600,"message":"handshake required: send hello first"}}
#   hello:           {"jsonrpc":"2.0","id":"h1","result":{"ok":true,"serverVersion":"0.1.0","cwd":"/tmp","fdAvailable":true}}
#   post-hello ping: {"jsonrpc":"2.0","id":"p1","error":{"code":-32601,"message":"method not found: ping"}}
```

### Level 4: Domain-specific validation (auth-boundary invariants)

```bash
# (a) Non-fatal: a pre-handshake request does NOT close the socket — asserted in
#     handshake-gate.test.ts dispatch test #1 (`state.ended === false`).
# (b) Token never appears in any response/stderr (PRD §12). The gate message is
#     fixed/token-free; grep the test run for the test-local secret:
JITI_REG=/home/dustin/.local/lib/node_modules/@earendil-works/pi-coding-agent/node_modules/jiti/lib/jiti-register.mjs
SECRET="deadbeefdeadbeefdeadbeefdeadbeef"
node --import "$JITI_REG" extension/tests/handshake-gate.test.ts 2>&1 | grep -c "$SECRET" || true
# Expected: 0 (the token is a test-local constant; the PRODUCTION secret is
# randomUUID-derived and must never be logged.)
```

---

## Final Validation Checklist

### Technical Validation
- [ ] `tsc --noEmit -p extension/tsconfig.json` ⇒ exit 0, no output.
- [ ] `node --import "$JITI_REG" extension/tests/handshake-gate.test.ts` ⇒ exit 0, `ℹ fail 0`.
- [ ] `node --import "$JITI_REG" extension/tests/connection.test.ts` ⇒ `ℹ tests 16`, `ℹ pass 16`, `ℹ fail 0` (test 13 updated to hello-first).
- [ ] `node --import "$JITI_REG" extension/tests/hello-handler.test.ts` ⇒ `ℹ fail 0` (hello exempt — regression).
- [ ] Every `extension/tests/*.test.ts` ⇒ `ℹ fail 0` (no S2–S9 regressions).

### Feature Validation
- [ ] Pre-handshake REQUEST (non-hello) ⇒ one `-32600 "handshake required: send hello first"` with the request id; handler NOT called; socket NOT closed.
- [ ] Pre-handshake NOTIFICATION ⇒ no response; handler NOT called.
- [ ] `hello` is gate-exempt (routes to S9 handler; success flips the flag; bad token ⇒ -32600+close, unchanged).
- [ ] Post-handshake, dispatch is unaffected (registered `ping` ⇒ success).
- [ ] Gate fires before registry lookup (unregistered method pre-handshake ⇒ -32600, not -32601).
- [ ] Token value never present in any response or stderr.

### Code Quality
- [ ] Gate placed AFTER id-discipline check, BEFORE the notification branch (covers both branches).
- [ ] NON-FATAL: `sendError(-32600)` + `return`; no `sock.end()` added.
- [ ] No new types / runtime exports / handler registrations / changes to `MethodHandler`, `onConnection`, `protocol.ts`, or `pi-editor-bridge.ts`.
- [ ] handleLine's inline STATUS/roadmap comment updated to mark S10 done (repo convention of accurate cross-task comments).
- [ ] `connection.test.ts` test 13 updated to hello-first (not just a code-swap); the 15 other tests untouched.
- [ ] TAB indentation, `node:test`+`assert/strict`+jiti (NOT vitest); `fakeSocket`/`parseResponses`/`readFirstResponse` copied verbatim; `__resetHandlersForTest()` in finally.

### Scope Discipline (did NOT bleed into other tasks)
- [ ] No S11–S14 handler registrations (the gate is method-agnostic).
- [ ] No S15 domain-error wrapping (the gate uses `sendError` directly, never throws).
- [ ] No S16 `process.env.PI_NVIM_BRIDGE` write / no S17 `commandsChanged`.
- [ ] No "reject by closing" hardening (explicitly deferred — PRD doesn't require it).

---

## Anti-Patterns to Avoid

- ❌ Don't put the gate INSIDE the request branch only — a pre-handshake NOTIFICATION would still reach a registered handler (module-level registry). Place it before the split.
- ❌ Don't make the gate fatal (don't `sock.end()`). Every other direct-`sendError` path in `handleLine` is non-fatal; only bad-token hello closes. PRD says "reject", not "close".
- ❌ Don't use `-32601` (method not found) for the gate — the method may well be registered; the rejection is about auth/ordering, so `-32600` (the reserved handshake/auth code) is correct.
- ❌ Don't look up the registry before the gate — an unregistered method sent pre-handshake must return `-32600`, not `-32601` (the gate's early `return` guarantees this).
- ❌ Don't read the token in the gate (that's hello's job) or include any secret in the message — the message is the fixed literal `"handshake required: send hello first"`.
- ❌ Don't change `MethodHandler`, `ConnectionState`, `onConnection`, `protocol.ts`, or `pi-editor-bridge.ts` — this is a one-block `handleLine` edit + tests.
- ❌ Don't just swap test 13's expected code from -32601 to -32600 and call it done — the hello-first variant is strictly better coverage and preserves the method-not-found + success assertions.
- ❌ Don't use vitest or a non-`node:test` runner.

---

## Confidence Score: 9/10

**Why 9, not 10**: the design is pinned by the codebase's own roadmap comments
(`connection.ts` STATUS block + `ConnectionState` JSDoc both pre-describe this
exact gate) and by S9's research §10 (which explicitly deferred it). It's a
~6-line non-fatal `sendError` in `handleLine`, consistent with the existing
parse/narrow error paths, method-agnostic (independent of S11–S14), and
backward-compatible with 15 of 16 connection tests by construction (the S8 author
pre-set `handshakeComplete:true`). The one residual risk is the exact assertion
shape of the updated real-socket test 13 (event ordering across Node/libuv for
the hello→ping sequence) — mitigated by reusing the proven `readFirstResponse`
helper shape and asserting each step's envelope in sequence.
