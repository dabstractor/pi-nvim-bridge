# P1.M2.T5.S10 — Reject any method before a valid handshake: research notes

> Scope: server side (pi-editor-bridge TS extension). Add a gate to
> `handleLine` in `extension/connection.ts` that rejects EVERY JSON-RPC method
> except `"hello"` until `ConnectionState.handshakeComplete` is `true` (flipped
> by S9's hello handler on a correct token). PRD §12: *"The bridge must reject
> any method before a valid `hello`."* This is the auth-ordering half of the
> handshake task (S9 set the flag; S10 reads it).

## 1. What the governing spec says

- **PRD §12 (Security)**: "The bridge must reject any method before a valid `hello`."
- **PRD §5.3 (Connection lifecycle & handshake)**: "The bridge must reject any
  method before a valid `hello`." Handshake flow: client sends `hello` FIRST;
  after a successful handshake, "normal request/response RPC proceeds". On a
  bad token → `-32600 "bad token"` **then close** (that close is S9's job, via
  `BridgeRpcError({fatal:true})`).
- **PRD §5.4 methods table**: every C→S method is a REQUEST (carries `id`,
  expects a result): `hello`, `ping`, `getSuggestions`, `applyCompletion`,
  `shouldTriggerFileCompletion`, `getCommands`, `bye`. The only NOTIFICATION is
  `commandsChanged`, and it is **S→C only** (server→client) — so a *client*
  sends NO notifications in v1. Still, the gate must defensively handle a
  pre-handshake notification (an unauthenticated peer shouldn't trigger any
  handler side effect).
- **S9 research notes §10**: "S10: the `if (!state.handshakeComplete &&
  method!==`"hello\"`)` gate. S9 only SETS the flag; S10 reads it."
- **connection.ts inline guidance** (the S8 author pre-wrote the S10 hint in
  TWO comments):
  - `handleLine` STATUS block: *"S10 adds a `if (!state.handshakeComplete &&
    method !== `"hello\"`)` gate (one guard inside the request branch, or a
    wrapper)."*
  - `ConnectionState` JSDoc: *"S9 sets `handshakeComplete=true` on a valid
    `hello`; S10 gates every non-hello method on it."*

So the design is already pinned by the codebase's own roadmap comments. This
task is the *implementation* of a gate the surrounding code was explicitly
written to receive.

## 2. Existing infrastructure S10 builds on (all verified present)

`extension/connection.ts` (S8 + S9, Complete):

- `ConnectionState { handshakeComplete: boolean }` — created `false` per
  connection in `onConnection`. S9's hello handler sets it `true` on a good
  token. **S10 reads it.**
- `handleLine(sock, state, line)` — the dispatch unit. Current structure
  (verified by reading the file end-to-end):
  1. **(A) PARSE** `JSON.parse` try/catch → `-32700` (id `null`) on failure.
  2. **(B) NARROW** — must be a non-null object with a string `method`. Extracts
     `idField`, `id: string|null` (= `idField` iff string), `isRequest`
     (= typeof idField === "string"), `method`, `params`, `handler`. Non-object /
     no-method → `-32600` (id = parsed id if string, else null).
  3. **id discipline** — if `"id" in parsed` but idField not a string →
     `-32600` "id must be a string" (id null).
  4. **(C) NOTIFICATION** (`!isRequest`) — call `handler(params,state)` if
     registered (try/catch → log, NEVER the token; no response); else no-op.
  5. **(D) REQUEST** — `const reqId = id as string`; if `!handler` → `-32601`
     "method not found"; else `await handler(...)` → `sendResponse` on return /
     `BridgeRpcError`→its code (+ `sock.end()` if `fatal`) / plain throw→`-32603`.
- `sendError(sock, id: string|null, code, message)` — response writer; the
  existing `-32700`/`-32600` cases in `handleLine` call it **directly** (NOT via
  throw) and do **NOT** close.
- `BridgeRpcError(code, message, { fatal })` (S9) — runtime class in
  connection.ts; `fatal:true` ⇒ handleLine sends the error THEN `sock.end()`.
  **Only hello's bad-token path uses `fatal:true`.**

`extension/protocol.ts` (S4): reserves the JSON-RPC 2.0 codes in a comment —
"`-32700` parse, `-32600` invalid request, `-32601` method not found, `-32602`
invalid params, `-32603` internal error. PRD §5.3 uses `-32600 "bad token"` for
handshake failure." → **`-32600` is the reserved code for handshake/auth
failures.**

`extension/pi-editor-bridge.ts` (S9): `makeHelloHandler` sets
`state.handshakeComplete = true` only on a correct token; registers `"hello"`
in the TUI-guarded `session_start` (after `startBridge`). `getToken()` ⇒
`undefined` after `stopBridge` ⇒ any `hello` ⇒ bad token (so a stopped bridge
never flips the flag).

## 3. THE design decision: where the gate goes + what it does

### Placement: before the notification/request split (one guard, both branches)

The gate must protect BOTH branches, because the registry is MODULE-LEVEL
(shared across connections): once S11 registers `getSuggestions`, an
unauthenticated peer sending a `getSuggestions` *NOTIFICATION* (no `id`) would
otherwise reach the handler in branch (C) and run pi's completion engine
(possibly spawning `fd`) without auth. So the gate cannot live inside the
request branch alone.

**Insert the gate after the id-discipline check (step 3) and BEFORE branch (C)
the notification branch.** At that point `method`, `isRequest`, and `id` are all
defined, and every malformed-envelope/parse case has already returned. One
guard + one conditional covers both branches:

```ts
// S10 handshake gate (PRD §12): reject every method except "hello" until S9's
// hello handler flips state.handshakeComplete on a correct token.
if (method !== "hello" && !state.handshakeComplete) {
    if (isRequest) {
        // -32600 = JSON-RPC 2.0 "Invalid Request"; the reserved code for
        // handshake/auth failures (protocol.ts comment; S9 bad-token path).
        sendError(sock, id as string, -32600, "handshake required: send hello first");
    }
    // NOTIFICATION (no string id): JSON-RPC 2.0 forbids a response. Drop it
    // silently — but DO NOT call the handler, so an unauthenticated peer can't
    // trigger any handler side effect (e.g. a registered notification handler).
    return;
}
```

Why `id as string` is safe: `isRequest === (typeof idField === "string")`, and
`id = idField` in that case. The cast just narrows for `sendError`'s signature.

### Error code: `-32600` (NOT -32601, NOT a custom code)

- `-32600` Invalid Request is the JSON-RPC 2.0 reserved code already used by
  S9 for the bad-token handshake failure and documented in `protocol.ts` as the
  handshake/auth code.
- `-32601` "method not found" is WRONG — the method *is* registered (e.g.
  `ping` once S14 lands); the rejection is about *ordering/auth*, not
  registration. Using -32600 keeps the client's error-handling simple:
  "anything -32600 on connect ⇒ I didn't handshake correctly."
- A custom code is unnecessary and would deviate from spec.

### Message text: `"handshake required: send hello first"`

- Actionable (tells the client dev exactly what to do), token-free (PRD §12 —
  NEVER log the token), stable (assertable in tests).
- Style matches existing handleLine messages ("invalid request: …",
  "method not found: …", "parse error: …").

### Fatal / close? **NO — non-fatal** (sendError + return, no `sock.end()`)

This is the most important design call. Arguments:

| Factor | Verdict |
|---|---|
| PRD §12 says "reject", not "close". §5.3 mandates close ONLY for bad-token hello. | → don't close |
| Consistency: every OTHER `-32600`/`-32700` path in `handleLine` (parse error, invalid envelope, bad id) calls `sendError` directly and does NOT close. Only `BridgeRpcError({fatal:true})` (S9 hello bad-token) closes. | → don't close (be consistent) |
| Security: the token is the REAL boundary (PRD §12). A peer without the token can never pass `hello`, so it can never flip the flag, so EVERY method it sends is rejected forever. Not closing costs nothing security-wise — the peer is fully locked out of results either way. | → don't close |
| Robustness: a well-behaved client MUST wait for the `hello` RESULT before sending anything else (synchronous request/response RPC). So a method before the hello result is a genuine client bug; but closing on it would be over-aggressive and make client-development flakier. | → don't close |
| The gate is in `handleLine`, not a handler — it can't use `BridgeRpcError.fatal` anyway (that's handler→catch→code). It would need an explicit `sock.end()`. Adding a close here would diverge from the established "direct sendError paths don't close" pattern. | → don't close |

**Decision: non-fatal.** `sendError(-32600)` + `return`. No close. This is the
minimal, consistent, spec-literal reading of "reject".

(If future hardening wants to drop abusive peers, an explicit `sock.end()` is a
one-line addition — but it is NOT required by the PRD and is out of scope for a
0.5-point task. Note it as a documented non-decision.)

### Notifications before handshake: drop silently, no handler call

- JSON-RPC 2.0: a notification (no `id`) gets NO response. So for a
  pre-handshake notification we can only drop it.
- CRITICAL: we must NOT fall through to branch (C) and invoke a registered
  notification handler — that would let an unauthenticated peer trigger side
  effects. The unified placement (before the split) guarantees this: the gate
  `return`s before branch (C) is reached.
- In v1 no legitimate client sends a notification (all C→S methods are
  requests), so this is purely defensive — but cheap and correct.

## 4. The ONE existing test that changes behavior (MUST update)

Ran the baseline (Node 26.4.0, jiti, `node:test`):

```
$ node --import "$JITI_REG" extension/tests/connection.test.ts
ℹ tests 16
ℹ pass 16
ℹ fail 0
$ tsc --noEmit -p extension/tsconfig.json   # exit 0
```

`connection.test.ts` has 16 tests (13 S8 + 3 S9). ALL `handleLine` dispatch
tests call `handleLine` with `{ handshakeComplete: true }` (lines 77, 88, 98,
111, 125, 139, 159, 180, 203, 220) — **the S8 author pre-set the flag precisely
so the S10 gate wouldn't break them.** They stay green untouched. ✔

**The one test that breaks is the REAL integration test (test 13, ~lines
250–270):** it uses `onConnection` (which creates a FRESH
`handshakeComplete:false` state) and sends `ping` as the FIRST message with NO
prior `hello`, expecting `-32601` "method not found" (registry empty). Under
the S10 gate that `ping` is now rejected with **`-32600` "handshake required:
send hello first"** BEFORE the registry is even consulted. So its assertion
`r1.error.code === -32601` fails.

**Fix (preserves the test's intent — method-not-found + success round trip —
while making the sequence handshake-valid):** register a `"hello"` handler (via
`makeHelloHandler` with a fixed token + stubbed deps) BEFORE the client
connects, then have the client send `hello` (correct token) FIRST, observe the
`HelloResult`, and only THEN send `ping` (unregistered ⇒ `-32601`), then
register `ping`, send it again ⇒ success. This keeps both `-32601` and success
assertions and adds a real handshake to the integration test.

Alternatively (simpler, less faithful): update test 13's first-message
expectation from `-32601` to `-32600` (documenting the gate). The PRP
recommends the hello-first variant because it keeps the test exercising the
full intended dispatch path AND validates the handshake→gate interaction
end-to-end. Either is acceptable; the hello-first variant is strictly better
coverage.

`hello-handler.test.ts`: its dispatch tests pass `handshakeComplete:false` for
`hello` (which is EXEMPT from the gate) and its REAL test sends `hello`
directly (exempt). → **stays green untouched.** ✔

## 5. New tests to add (gate-focused suite)

Create `extension/tests/handshake-gate.test.ts` (mirrors the one-suite-per-
subtask convention: S7→jsonl-reader, S8→connection, S9→hello-handler, S10→
handshake-gate). `node:test` + `assert/strict` + jiti (NOT vitest — S9 research
§7). Reuse the `fakeSocket()` helper (copy it — it already has `end()` from S9).

**Dispatch (fakeSocket + `handleLine` directly, registry controlled):**
1. REQUEST before handshake (`{handshakeComplete:false}`, method `ping`,
   registered handler) → exactly one `-32600 "handshake required: send hello
   first"` response; the registered handler is NEVER called; socket NOT ended
   (non-fatal).
2. NOTIFICATION before handshake (`{handshakeComplete:false}`, no `id`,
   registered handler) → NO response (`writes.length===0`); handler NEVER
   called.
3. `hello` before handshake is EXEMPT → routes to the registered hello handler
   (does not hit the gate); matches S9 behavior (success on good token /
   `-32600`+close on bad token).
4. After handshake (`{handshakeComplete:true}`) the gate is a no-op → a
   registered `ping` returns its result (regression that the gate doesn't
   over-block).
5. Gate runs BEFORE registry lookup → even an UNREGISTERED method before
   handshake yields `-32600` (not `-32601`). (Locks in the placement.)

**REAL integration (one real Unix-socket pair, `createServer`+`onConnection`):**
6. Client sends `ping` first (no hello) → `-32600`; then sends `hello` (correct
   token) → `HelloResult`; then `ping` again → now dispatches (unregistered ⇒
   `-32601`, or success if registered). Asserts the gate opens after a real
   handshake over a real socket. `__resetHandlersForTest()` in finally.

Plus: token NEVER appears in any gate response/log (grep assertion, PRD §12).

## 6. Test convention (verified — copy S9/S8 exactly)

```
JITI_REG=/home/dustin/.local/lib/node_modules/@earendil-works/pi-coding-agent/node_modules/jiti/lib/jiti-register.mjs
node --import "$JITI_REG" extension/tests/handshake-gate.test.ts   # exit 0, ℹ fail 0
tsc --noEmit -p extension/tsconfig.json                            # exit 0, no output
```
- `import { test } from "node:test"; import assert from "node:assert/strict";`
- `fakeSocket()` from connection.test.ts (EventEmitter + write capture +
  `end()` records + emits close). Reuse verbatim.
- `registerBridgeHandler` + `__resetHandlersForTest()` in try/finally.
- jiti prints a benign DeprecationWarning on Node 26 stderr — judge by exit
  code + `ℹ pass`/`ℹ fail` summary, ignore the warning.
- TAB indentation (matches the repo; `tsc`/formatting is by hand, no eslint).

## 7. Why this is genuinely small (0.5 points) — and what keeps it that way

- ONE behavioral edit to `handleLine` (~6 lines: the `if` + conditional
  `sendError` + `return`).
- No new types (consumes `ConnectionState`, `sendError` — both exist).
- No new runtime exports from `connection.ts` (the gate is internal logic).
- No change to `MethodHandler`, `onConnection`, `protocol.ts`,
  `pi-editor-bridge.ts`, or any handler.
- Tests: one NEW focused suite + a one-block update to connection.test.ts test
  13. Everything else stays green by construction (the `handshakeComplete:true`
  pre-set).

The only "thinking" risk was the fatal-vs-non-fatal call and the notification
handling — both resolved in §3 above with explicit reasoning.

## 8. Out of scope (other tasks — do NOT implement)

- S11–S14: registering getSuggestions/applyCompletion/
  shouldTriggerFileCompletion/ping/bye/getCommands. (The gate is
  method-agnostic — it doesn't need to know which methods exist.)
- S15: wrapping each handler's OWN domain errors into `BridgeRpcError` codes.
  (The gate uses `sendError` directly; it doesn't throw.)
- S16: `process.env.PI_NVIM_BRIDGE` advertisement.
- S17: `commandsChanged` S→C notification.
- "Reject by CLOSING": explicitly NOT doing this (§3). If wanted later, it's a
  one-line `try { sock.end() } catch {}` addition — but the PRD doesn't require
  it and it diverges from the established handleLine -32600 pattern.
- Timing-safe token compare: S9 research §9 already scoped this as an optional
  v1.1 hardening, not required here (the gate doesn't even look at the token).
