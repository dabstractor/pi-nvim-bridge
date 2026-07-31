---
name: "P1.M2.T7.S15 — Wrap all handlers in try/catch with JSON-RPC error responses (dispatch error-boundary)"
description: |
  Create the bridge's **RPC dispatch + error-boundary engine** as a NEW single
  file `extension/dispatch.ts` (plus a one-line `include` edit to
  `extension/tsconfig.json` and a NEW `node:test`+jiti suite
  `extension/tests/dispatch.test.ts`). The module exports a
  **`wrapHandler(step)` higher-order function** that wraps any async dispatch
  step `(req: JsonRpcRequest) => Promise<JsonRpcResponse>` in a `try/catch` so it
  can NEVER throw to its caller: on a caught sync-throw OR async rejection it
  returns `{ jsonrpc: "2.0", id: req.id, error: { code: -32603, message } }`,
  and because it `await`s the step, a rejection becomes a *resolved* value
  (handled) — never an unhandled-rejection that Node 15+ would use to terminate
  pi (PRD §6.7 "Never throws from handlers"). It is a **defense-in-depth safety
  NET around the handlers' OWN `HandlerOutcome` self-wrap** (S11–S14 already
  return `{ok:false,error}` instead of throwing) — NOT a replacement for it; it
  catches the things a handler *forgot* to self-wrap plus truly unexpected
  dispatcher/envelope-logic throws. The module ALSO ships the dispatch logic that
  APPLIES the wrapper: `buildDispatcher(handlers, ctx)` (method lookup → invoke →
  envelope, with `-32601` method-not-found) and `dispatch(handlers, ctx)` =
  `wrapHandler(buildDispatcher(...))`; plus the DRY response builders
  `successResponse`/`errorResponse`/`toResponse`, the `messageOf(err)` robust
  error→string helper (the generalization of S11's module-private `toRpcError`
  body — both S11 and S12 forward-ref "S15 generalizes toRpcError"), a structural
  `RpcOutcome<T>` type (identical shape to S11's `HandlerOutcome<T>` so TS
  structural typing makes the real type assignable with NO cross-module import),
  and the JSON-RPC error-code constants. The 1500 ms timeout from S11 (per the
  item contract) is handled STRUCTURALLY: S11's handler `await`s the provider and
  `clearTimeout`s in `finally`, and `dispatch`/`wrapHandler` `await` the handler —
  every layer awaits, so the abort path resolves a clean `{ok:true,result:null}`
  (pi's provider resolves null on abort, does NOT throw — S11 research §1) and any
  stray rejection is caught; there is no dangling unawaited promise. This task is
  NARROW and PURELY ADDITIVE: it does NOT edit `extension/pi-editor-bridge.ts`
  (the `onConnection(_sock)` placeholder + its `// TODO(S8)` comment stay
  byte-for-byte intact — S8 imports `dispatch` there and wires it), does NOT edit
  `extension/protocol.ts` (type-only consumer of the existing S4 types), does NOT
  implement handlers (S11–S14), handshake (S9/S10), or the reader/parse/write
  connection wiring (S8), does NOT add `dispatch.ts` to any import anywhere yet
  (dead code until S8 consumes it — by design, so the error boundary is
  unit-tested in isolation before wiring), does NOT touch `compilerOptions`
  (the ONLY tsconfig change is appending `"dispatch.ts"` to the existing `include`
  array — the exact one-line additive edit S4 made for `protocol.ts` and S7 made
  for `jsonl-reader.ts`), and does NOT introduce a `Promise.race` or its own
  timeout (the 1500 ms timeout lives in S11's handler; S15 only `await`s). (Path
  note: orchestrator placed artifacts under `P1M2T5S1/`; the item is task
  **P1.M2.T7.S15** in the plan tree — the error-boundary / global-try-catch. Build
  the feature; ignore the folder label.)
---

## Goal

**Feature Goal**: Land the bridge's **dispatch error boundary** so that, no matter
what an RPC handler (S11–S14) or the dispatcher's own envelope logic does — sync
throw, async reject, runaway timeout, forgotten self-wrap — the dispatch loop
ALWAYS receives a well-formed `JsonRpcResponse` and NEVER propagates a throw or an
unhandled promise rejection to the socket-write call site (or to pi's event loop).
This is the PRD §6.7 guarantee *"Never throws from handlers (wrap in try/catch,
return JSON-RPC error)"* made structural and enforceable: a single tested
`wrapHandler` HOF converts every failure into a JSON-RPC `error` envelope
(`{code:-32603, message}`), and a `dispatch()` that applies it turns a handler
registry + request into a guaranteed-settled wire response.

**Deliverable** (all under `extension/`):
1. **CREATE** `extension/dispatch.ts` — a ~120-line module exporting: the
   JSON-RPC error-code constants (`RPC_PARSE_ERROR=-32700`, …,
   `RPC_INTERNAL_ERROR=-32603`); `messageOf(err)`; `successResponse`/
   `errorResponse`/`toResponse` builders; the `RpcOutcome<T>` structural type +
   `RpcHandler<C>`/`HandlerRegistry<C>` types; `wrapHandler(step)` (the title-named
   HOF); `buildDispatcher(handlers, ctx)`; and `dispatch(handlers, ctx)`. Node
   builtins + `./protocol.ts` types ONLY — honors PRD §6.7 "no npm runtime
   dependencies". Mode-A JSDoc on every export with a `STATUS (P1.M2.T7.S15)`
   marker + forward refs (S8 dispatcher consumer, S11–S14 handlers, S9/S10
   handshake).
2. **MODIFY** `extension/tsconfig.json` — append `"dispatch.ts"` to the existing
   `include` array (the ONLY change; `compilerOptions` byte-identical).
3. **CREATE** `extension/tests/dispatch.test.ts` — a `node:test`+jiti suite
   (matching the S2/S3/S4/S5/S7/S11 test conventions) with ~17 tests exercising
   `wrapHandler` (success passthrough, sync throw, async reject, reject-after-delay
   + no-unhandled-rejection, non-Error throw, HOF identity), `dispatch`
   (method-not-found, ok-outcome→success, error-outcome→error, handler-throw→net,
   handler-reject-after-delay, ctx threading), and the builders/helpers/messageOf/
   constants — all with mock steps/handlers, NO real socket/provider.

**Success Definition**:
- `tsc --noEmit -p extension/tsconfig.json` → exit 0, **no output** (the
  `./protocol.ts` type-only import + the generics + the `catch` narrow + the
  `dispatch`/`buildDispatcher` higher-order typing all type-check under the
  UNCHANGED `compilerOptions` — empirically verified; see research §2 + Gotchas).
- `node --import <pi>/node_modules/jiti/lib/jiti-register.mjs extension/tests/dispatch.test.ts`
  → exit 0, `ℹ fail 0` (all ~17 tests pass; the reject-after-delay test proves the
  `await` is load-bearing AND that no `'unhandledRejection'` fires; the non-Error
  throw proves the strict-mode `catch(err: unknown)` narrow via `messageOf`).
- All pre-existing suites still green (regression): `provider-capture.test.ts`
  (S2), `mode-guard.test.ts` (S3), `protocol.test.ts` (S4),
  `bridge-lifecycle.test.ts` (S5), `bridge-lifecycle-wiring.test.ts` (S6),
  `jsonl-reader.test.ts` (S7), and — once merged — the S11/S12 handler suites.
  S15 is purely additive (1 new module + 1 new test + 1-line `include` edit;
  touches nothing they read).
- Regression: `pi --no-extensions -e ./extension/pi-editor-bridge.ts --print "ok"`
  exits 0 with no error lines (the new module is not imported by the entry point
  yet, so the load path is unchanged — proves S15 didn't disturb the extension).
- The `onConnection(_sock)` placeholder in `pi-editor-bridge.ts` is byte-for-byte
  UNCHANGED (its `// TODO(S8)` comment intact — S8 imports `dispatch` here).

## User Persona (if applicable)

**Target User**: The bridge-extension author and the downstream implementer of
**S8** (`onConnection` — the consumer of `dispatch`). This task is the
error-boundary backbone S8's dispatch loop hangs off.

**Use Case**: When S8 implements `onConnection(sock)`, it will (per the S7 reader
+S8 wiring) parse each JSONL line into a `JsonRpcRequest`, then write:
`const respond = dispatch(handlers, connCtx); sock.write(serializeJsonLine(await respond(req)));`
— and it can do so with NO surrounding `try/catch`, because `dispatch`/`wrapHandler`
GUARANTEE `respond(req)` resolves to a `JsonRpcResponse` and never rejects. Until
S15 lands, S8 has no error boundary and would have to hand-roll a try/catch around
every handler call (and would still risk an unhandled rejection on the async
timeout path).

**Pain Points Addressed**:
- Without an error boundary, a handler that *forgot* to self-wrap (returning a
  `HandlerOutcome` on every path) — or a genuine bug in dispatcher/envelope logic
  — would throw out of the dispatch loop, crash the connection's `data` handler,
  and (because the extension runs inside pi's `session_start`) potentially crash
  pi. PRD §6.7 explicitly forbids this.
- Without the inner `await`, a rejection from an async handler (including the S11
  timeout path if a wrapped provider ever throws on abort) would become the
  returned promise's REJECTION — an unhandled rejection that Node 15+ uses to
  TERMINATE the process. `wrapHandler`'s `return await step(req)` makes the catch
  fire inside the HOF so the returned promise always RESOLVES.
- Without a shared `messageOf` / `errorResponse`, every handler re-implements the
  `unknown`→string narrow and the envelope shape; S11/S12 already forward-ref
  "S15 generalizes toRpcError". This task lands that shared helper.

## Why

- **The structural guarantee behind PRD §6.7.** "Never throws from handlers" is
  enforceable at the dispatch boundary: a single `wrapHandler` wrapping the
  dispatch step means NO code path — handler bug, envelope-logic bug, provider
  edge case, forgotten self-wrap — can escape as a throw or an unhandled
  rejection. The handlers' own `HandlerOutcome` self-wrap (S11–S14) is the FIRST
  line of defense (clean, method-prefixed errors); `wrapHandler` is the SECOND
  (defense-in-depth catch-all).
- **Unhandled rejections kill pi.** Since Node 15, an unhandled promise rejection
  terminates the process by default. The bridge runs inside pi's `session_start`;
  a single un-awaited rejection from a slow/aborted `getSuggestions` could crash
  the user's pi session. `wrapHandler`'s `await` is the load-bearing line that
  converts every rejection into a resolved `JsonRpcResponse`.
- **The timeout contract is satisfied structurally, not tactically.** The item
  requires that "the 1500 ms timeout from S11 properly aborts and returns a clean
  result (not an unhandled rejection)." Because S11's handler `await`s the
  provider and `clearTimeout`s in `finally`, and `dispatch`/`wrapHandler` `await`
  the handler, the abort path resolves a clean `{ok:true,result:null}` (pi's
  provider resolves null on abort) and any stray rejection is caught — no
  dangling promise. S15 needs NO `Promise.race` of its own.
- **Isolated unit-testability.** A separate module fed by mock dispatch steps and
  mock handlers is the cleanest way to prove the never-throw / no-unhandled-
  rejection contract directly, with no socket/server/provider/lifecycle state.
- **Zero-dependency, one-line-config increment.** The module uses only
  `./protocol.ts` types + globals (`Error`/`String`) — honoring PRD §6.7. The
  only config change is one line in `include` (the established S4/S7 pattern). It
  introduces no runtime state and is dead code until S8 imports it.

## What

One new module, one one-line `include` edit, one new test file. No new module
state, no edit to `pi-editor-bridge.ts` or `protocol.ts`, no `compilerOptions`
change, no wiring into any socket (S8 does that).

### Success Criteria

- [ ] `extension/dispatch.ts` EXISTS and exports `wrapHandler`, `buildDispatcher`,
      `dispatch`, `successResponse`, `errorResponse`, `toResponse`, `messageOf`,
      `RpcOutcome`, `RpcHandler`, `HandlerRegistry`, `DispatchStep`, and the
      error-code constants (`RPC_INTERNAL_ERROR=-32603`, `RPC_METHOD_NOT_FOUND=-32601`,
      `RPC_PARSE_ERROR=-32700`, `RPC_INVALID_REQUEST=-32600`, `RPC_INVALID_PARAMS=-32602`).
- [ ] `wrapHandler(step)` returns a NEW async function `(req) => Promise<JsonRpcResponse>`
      whose body is `try { return await step(req); } catch (err) { return
      errorResponse(req.id, RPC_INTERNAL_ERROR, messageOf(err)); }`. The `await`
      is load-bearing (see Gotchas): without it a rejection would escape.
- [ ] On any caught error (sync throw OR async reject), `wrapHandler` returns
      `{ jsonrpc:"2.0", id: req.id, error: { code:-32603, message } }` where
      `message = err instanceof Error ? err.message : String(err)` (the
      `messageOf` narrow — required because TS `strict` ⇒ `catch` binds `unknown`).
- [ ] `wrapHandler`'s returned promise ALWAYS RESOLVES (success envelope OR error
      envelope) — it NEVER rejects, even when `step` rejects after a `setTimeout`
      (the timeout simulation). No `'unhandledRejection'` event fires.
- [ ] `dispatch(handlers, ctx)` returns `(req) => Promise<JsonRpcResponse>` =
      `wrapHandler(buildDispatcher(handlers, ctx))`. `buildDispatcher` looks up
      `handlers[req.method]`; if absent returns `errorResponse(req.id,
      RPC_METHOD_NOT_FOUND, "method not found: <method>")`; otherwise `await`s the
      handler with `req.params ?? {}` and `ctx`, then `toResponse(req.id, outcome)`.
- [ ] `toResponse(id, outcome)` maps `{ok:true,result}` → `{jsonrpc,id,result}`
      and `{ok:false,error}` → `{jsonrpc,id,error}` (success omits `error`;
      error omits `result` — matching `protocol.ts`'s `JsonRpcResponse` union).
- [ ] `RpcOutcome<T>` is `{ok:true;result:T} | {ok:false;error:JsonRpcError}` —
      STRUCTURALLY IDENTICAL to S11's `HandlerOutcome<T>` so a real
      `HandlerOutcome<T>` is assignable with NO cross-module import.
- [ ] The module imports ONLY from `./protocol.ts` (type-only) + uses globals
      (`Error`, `String`) — NO npm deps, NO import from `pi-editor-bridge.ts`
      (PRD §6.7; avoids coupling to S11's not-yet-merged types).
- [ ] `extension/tsconfig.json` `include` contains `"dispatch.ts"` (the ONLY
      change; `compilerOptions` byte-identical).
- [ ] `extension/pi-editor-bridge.ts` is UNCHANGED — the `onConnection(_sock)`
      placeholder + its `// TODO(S8)` comment are byte-for-byte intact.
- [ ] `extension/protocol.ts` is UNCHANGED.
- [ ] `extension/tests/dispatch.test.ts` EXISTS, uses `node:test` +
      `node:assert/strict` (NOT vitest), and asserts at minimum: wrapHandler
      success-passthrough; sync-throw → -32603 (resolves not rejects); async-reject
      → -32603; reject-after-setTimeout → -32603 AND no `'unhandledRejection'`;
      non-Error throw → `messageOf` fallback; HOF returns a new function; dispatch
      method-not-found → -32601; ok-outcome → success envelope; error-outcome →
      error envelope; handler-throw → -32603; handler-reject-after-delay → -32603;
      ctx threaded through; builders produce exact shapes; `messageOf` Error/string/
      number/null; constants equal spec values.
- [ ] `tsc --noEmit -p extension/tsconfig.json` → exit 0, no output.
- [ ] `node --import <jiti-register> extension/tests/dispatch.test.ts` → exit 0,
      `ℹ fail 0`.
- [ ] All pre-existing suites still report `ℹ fail 0` (regression).
- [ ] `pi --no-extensions -e ./extension/pi-editor-bridge.ts --print "ok"` exits
      0 with no error lines.

## All Needed Context

### Context Completeness Check

_Pass test_: An agent who has never seen this repo, given the current
`extension/protocol.ts` (post-S4), `extension/tsconfig.json`, and this PRP, can
(1) create `dispatch.ts` verbatim from the pinned reference body below (every
type, signature, and line of logic is reproduced — no guessing), (2) make the
one-line `include` edit, (3) write the test from the supplied skeleton, and (4)
run the exact validation commands to green — with every load-bearing claim (the
strict-mode `catch(err: unknown)` narrow, why `return await` not `return`, why
the rejection is "handled", why `RpcOutcome` is structural not imported, the
`-32603`/`-32601` codes) cited and reasoned in `research/notes.md`.

### Documentation & References

```yaml
# MUST READ — the authoritative task analysis FOR THIS EXACT TASK
- docfile: plan/001_c56962b4fa17/P1M2T5S1/research/notes.md
  why: the authoritative task analysis: §1 the S11/S12 handler contract (handlers ALREADY self-wrap into HandlerOutcome; S15 is a SAFETY NET not a replacement; S11/S12 forward-ref "S15 generalizes toRpcError"; the 1500ms timeout resolves null not throws); §3 wrapHandler design + the strict-mode catch(err:unknown) gotcha (messageOf) + why `return await` not `return`; §4 the timeout/unhandled-rejection story (Node 15 kills on unhandled rejection; await = handled; abort resolves null); §5 the file-placement decision (new dispatch.ts, protocol.ts-only dep); §6 the dispatch design + the contravariance note for S8; §7 the test plan; §8 scope guard.
  section: "all sections (§1 contract + §3 strict-mode catch + §4 unhandled-rejection are the three make-or-break claims)"
  critical: |
    §3 + §4 are essential: (a) under TS strict, `catch (err)` binds `unknown`, so
    `error.message` is a TS18046 COMPILE ERROR — you MUST narrow via
    `err instanceof Error ? err.message : String(err)` (the `messageOf` helper);
    (b) the inner `return await step(req)` (not `return step(req)`) is what makes
    the catch fire inside the HOF so the returned promise always resolves —
    without it a rejection escapes and (Node 15+) kills pi.

# MUST READ — the types dispatch.ts consumes (type-only import source)
- file: extension/protocol.ts
  why: the type-only module S15 imports JsonRpcRequest/JsonRpcResponse/JsonRpcError from. §A defines JsonRpcRequest{jsonrpc,id,method,params?}, JsonRpcResponse = | {jsonrpc,id,result?} | {jsonrpc,id,error} (discriminated; success omits error, error omits result), JsonRpcError{code,message} (NO data field), and the spec error-code comment (-32700/-32600/-32601/-32602/-32603). dispatch.ts builds/expects EXACTLY these shapes.
  section: "§A (JsonRpcRequest, JsonRpcResponse union, JsonRpcError + the error-code comment)"
  critical: |
    S15 imports ONLY types from protocol.ts (`import type {...} from "./protocol.ts"`) —
    protocol.ts is type-only (zero runtime exports; protocol.test.ts confirms it
    loads as an empty namespace). DO NOT add a value import. DO NOT edit protocol.ts.
    Match the JsonRpcResponse branches EXACTLY (success has result, NO error; error
    has error, NO result) — your builders must not emit both keys.

# MUST READ — the handler↔dispatcher contract S15 sits on top of (treat as merged)
- docfile: plan/001_c56962b4fa17/P1M2T4S1/PRP.md
  why: S11 defines the HandlerOutcome<T> = {ok:true,result}|{ok:false,error} discriminated return EVERY handler (S11–S14) produces, the ConnectionContext baseline, the module-private toRpcError(err,code) (hardcoded "getSuggestions failed:" prefix), the __handlerDeps timeout seam, the pendingAbort supersession slot, and handleGetSuggestions. S11 says verbatim "S15 adds a global try/catch as a safety NET for truly unexpected handler bugs, NOT a replacement" and "S15 may generalize [toRpcError] across handlers later." S15's RpcOutcome<T> is STRUCTURALLY IDENTICAL to HandlerOutcome<T> so the real type is assignable with no import; S15's messageOf IS the toRpcError generalization.
  section: "the HandlerOutcome<T> definition + toRpcError body + the S15 forward-refs"
  critical: |
    Do NOT re-implement the handlers or their supersession/timeout — S15 only wraps
    the dispatch step. The 1500ms timeout + AbortController live in S11's handler;
    S11's research §1 proves the provider RESOLVES null on abort (does not throw), so
    the timeout path yields a clean {ok:true,result:null} outcome that toResponse
    envelopes as a success — wrapHandler never sees it. S15 introduces NO Promise.race
    and NO timeout of its own.

# MUST READ — the framing module S8 uses to WRITE the response S15 produces
- docfile: plan/001_c56962b4fa17/P1M2T4S7/PRP.md
  why: S7's serializeJsonLine(value) is the serializer S8 uses to write the JsonRpcResponse that dispatch/wrapHandler produce: `sock.write(serializeJsonLine(await respond(req)))`. Confirms the S7→S8→S15 wiring order and that S15's output (a JsonRpcResponse) is exactly what serializeJsonLine expects.
  section: "serializeJsonLine + the S8 consumer note"
  critical: |
    dispatch.ts does NOT import jsonl-reader.ts (it returns a JsonRpcResponse object;
    S8 does the serialize+write). But the SHAPES must agree: dispatch returns a
    JsonRpcResponse (protocol.ts), which serializeJsonLine JSON.stringifies. Keep
    dispatch.ts free of any socket/serialize concern.

# MUST READ — the live baseline S15 builds alongside (and must NOT touch)
- file: extension/pi-editor-bridge.ts
  why: the live post-S7 source. S15 does NOT edit it, but MUST leave the `onConnection(_sock)` placeholder + its `// TODO(S8): wire the JSONL reader + RPC dispatcher onto _sock` comment byte-for-byte intact (that is the S8 import site for THIS module: `import { dispatch } from "./dispatch.ts"`). Re-grep before finishing to confirm S15 changed nothing here.
  section: "the `function onConnection(_sock: Socket): void { /* TODO(S8) … */ }` placeholder + its JSDoc"

# SUPPORTING — house test conventions (S15's test follows these exactly)
- file: extension/tests/protocol.test.ts
  why: the canonical node:test+jiti+`import type` test pattern in THIS repo: `import { test } from "node:test"`, `import assert from "node:assert/strict"`, top-level `test(...)` (no describe), declared-inside-test-body consts (no noUnusedLocals). S15's test mirrors this style + adds async tests (await of wrapHandler/dispatch results).
  section: "whole file — import style, top-level test(), assertion patterns"

- file: extension/tests/jsonl-reader.test.ts
  why: the most recent sibling test (S7). Shows the async-test idiom (await Promise / await stream 'end') + the detach/listener-count assertions that are the closest house analogue to S15's "no unhandledRejection" + "HOF returns a new function" assertions. Same jiti register hook path.
  section: "the async test(...) bodies + listener/event assertions"

# SUPPORTING — the prior PRP that established the one-line include edit pattern
- docfile: plan/001_c56962b4fa17/P1M2T4S7/research/notes.md
  why: §7 records that S7's ONLY tsconfig change was appending "jsonl-reader.ts" to include (no compilerOptions edit). S15 makes the IDENTICAL one-line additive edit for "dispatch.ts". Confirms the established, safe pattern. (S4 made the same edit for protocol.ts.)
  section: "§7 (the one-line additive include edit; compilerOptions UNCHANGED)"

# SUPPORTING — PRD requirements + scope context
- docfile: PRD.md
  why: §6.7 Requirements checklist ("Never throws from handlers (wrap in try/catch, return JSON-RPC error)", "Never blocks pi's event loop synchronously (all getSuggestions are awaited)"); §5.3 (JSON-RPC envelopes + the -32600 "bad token" handshake error — S9 owns handshake; S15 owns the -32603 catch-all); §5.5 (Timing & cancellation — the 1500ms timeout + supersession that S11 implements and S15 structurally supports via await); §11 (Edge cases — "pi process dies while editor open": the socket closes; an error boundary that never throws keeps the connection's data handler from crashing on a half-delivered request).
  section: "§6.7 (the governing never-throw + never-block reqs), §5.3 (envelopes/error codes), §5.5 (timeout — S11 implements, S15 awaits), §11 (process-death edge)"
  critical: |
    §6.7 is the spec S15's wrapHandler satisfies directly. §5.5 is the timeout
    authority — S11 implements the timeout; S15's contribution is that it `await`s
    so the timeout's resolution/rejection is always consumed (never an unhandled
    rejection). Do not duplicate the timeout in S15.

# SUPPORTING — JSON-RPC 2.0 spec (error object + codes + response rules)
- url: https://www.jsonrpc.org/specification#error_object
  why: confirms the Error object shape {code:number, message:string, data?} (data OPTIONAL — S15 omits it, matching protocol.ts's JsonRpcError); the reserved range -32768..-32000; the standard codes S15 exports as constants (-32700 parse, -32600 invalid request, -32601 method not found, -32602 invalid params, -32603 internal error); and -32000..-32099 server-error (implementation-defined — NOT used by S15).
  section: "§5.1 Error object (code/message/data?); §5.1.1 error-code table"
  critical: |
    -32603 (internal error) is the code S15's wrapHandler uses for EVERY caught
    error (per the item contract). -32601 (method not found) is the code
    buildDispatcher uses for an unknown method. Do NOT invent codes outside the
    reserved range. data is OMITTED (protocol.ts's JsonRpcError has no data field).

- url: https://www.jsonrpc.org/specification#response_object
  why: confirms a Request with `id` MUST get exactly one Response (success OR error, never both, never none); Notifications (no id) get NO response. S15's dispatch/wrapHandler produce exactly one JsonRpcResponse per id'd request — S8 is responsible for only calling dispatch for id'd requests (notifications/commandsChanged are S→C, never dispatched).
  section: "§5 Response object (exactly one response per request id)"

# SUPPORTING — Node unhandled-rejection behavior (why the await is load-bearing)
- url: https://nodejs.org/api/process.html#event-unhandledrejection
  why: confirms that since Node 15 the default `--unhandled-rejections=throw` mode EMITS 'unhandledRejection' and then TERMINATES THE PROCESS with a non-zero exit code. A `try { await step } catch {}` converts a rejection into a resolved value, so the promise is "handled" and 'unhandledRejection' never fires. This is precisely why wrapHandler MUST `return await step(req)` (inner await) rather than `return step(req)`.
  section: "'unhandledRejection' event + the Node 15 default-throw behavior"
  critical: |
    The reject-after-delay test MUST attach `process.once("unhandledRejection", ...)`
    as a tripwire and assert it does NOT fire within the test window — that is the
    empirical proof the await made the rejection "handled". Remove the listener in
    `finally` so it can't poison sibling tests.

# SUPPORTING — TS strict ⇒ catch binds unknown (why messageOf narrows)
- url: https://www.typescriptlang.org/tsconfig#useUnknownInCatchVariables
  why: confirms `strict: true` implies `useUnknownInCatchVariables` (TS 4.4+), so `catch (err)` types `err` as `unknown`. Reading `err.message` directly is TS18046. The fix is `err instanceof Error ? err.message : String(err)` — exactly S15's `messageOf`. (Equivalently, a binding-less `catch {}` when the value is unused.)
  section: "useUnknownInCatchVariables (strict ⇒ catch (err) is unknown)"
  critical: |
    The item contract says `message: error.message`, but under TS strict that literal
    is a COMPILE ERROR. Use `messageOf(err)` (the narrow). The non-Error-throw test
    (throw a string / object) proves the `String(err)` fallback is load-bearing.

# SUPPORTING — AbortController idempotency (S11 context; S15 only awaits)
- url: https://developer.mozilla.org/en-US/docs/Web/API/AbortController/abort
  why: confirms AbortController.abort() is idempotent ("if aborted flag is set, return"). S11 relies on this (supersession + timeout both abort); S15 does NOT call abort — it only `await`s the handler whose internal signal may abort. Cited for completeness so the implementer understands the timeout never produces a stuck promise: the handler settles (resolves null on abort) and wrapHandler returns.
  section: "Return value: none; idempotent"
```

### Current Codebase tree (post-S7 baseline — S15 ADDS 1 module + 1 test, edits 1 include line)

```bash
extension/
├── pi-editor-bridge.ts            # (S1+S2+S3+S5+S6) default-export factory: session_start (TUI guard + log + captureProvider + startBridge) + session_shutdown (stopBridge); captureProvider/getProvider/liveProvider; startBridge/stopBridge/getServer/getSocketPath/getToken/__deps/onConnection-PLACEHOLDER. [S11–S14 will ADD handlers here later] S15 does NOT touch this file.
├── protocol.ts                    # (S4) type-only JSON-RPC contract. S15 imports TYPES from it (no edit).
├── jsonl-reader.ts                # (S7) serializeJsonLine + attachJsonlLineReader. S15 does NOT touch it (S8 wires serialize in onConnection).
├── tsconfig.json                  # (S1+S2+S4+S5+S7) include=["pi-editor-bridge.ts","protocol.ts","jsonl-reader.ts","tests/**/*.ts"]; NO lib field (→ DOM defaults → globals type-check); strict:true. S15 appends "dispatch.ts" to include (the ONLY edit; compilerOptions UNCHANGED).
└── tests/
    ├── provider-capture.test.ts   # (S2) S15 does NOT touch (regression).
    ├── mode-guard.test.ts         # (S3) S15 does NOT touch (regression).
    ├── protocol.test.ts           # (S4) S15 does NOT touch (regression).
    ├── bridge-lifecycle.test.ts   # (S5) S15 does NOT touch (regression).
    ├── bridge-lifecycle-wiring.test.ts # (S6) S15 does NOT touch (regression).
    └── jsonl-reader.test.ts       # (S7) S15 does NOT touch (regression).
# plan/ holds planning artifacts only — no other source code
```

### Desired Codebase tree with files to be added/modified

```bash
extension/
├── pi-editor-bridge.ts            # (UNCHANGED — onConnection placeholder + its // TODO(S8) comment intact; S8 will import dispatch here)
├── protocol.ts                    # (UNCHANGED — S4)
├── jsonl-reader.ts                # (UNCHANGED — S7)
├── dispatch.ts                    # (CREATE) the RPC dispatch + error-boundary engine: wrapHandler(step) HOF + buildDispatcher/dispatch + successResponse/errorResponse/toResponse + messageOf + RpcOutcome/RpcHandler/HandlerRegistry/DispatchStep types + error-code constants. ./protocol.ts types only.
├── tsconfig.json                  # (MODIFY) append "dispatch.ts" to include → ["pi-editor-bridge.ts","protocol.ts","jsonl-reader.ts","dispatch.ts","tests/**/*.ts"]. compilerOptions UNCHANGED.
└── tests/
    ├── provider-capture.test.ts   # (UNCHANGED — S2 regression)
    ├── mode-guard.test.ts         # (UNCHANGED — S3 regression)
    ├── protocol.test.ts           # (UNCHANGED — S4 regression)
    ├── bridge-lifecycle.test.ts   # (UNCHANGED — S5 regression)
    ├── bridge-lifecycle-wiring.test.ts # (UNCHANGED — S6 regression)
    ├── jsonl-reader.test.ts       # (UNCHANGED — S7 regression)
    └── dispatch.test.ts           # (CREATE) node:test+jiti: wrapHandler (success/sync-throw/async-reject/reject-after-delay+no-unhandledRejection/non-Error/HOF-identity) + dispatch (method-not-found/ok-outcome/error-outcome/handler-throw/handler-reject-after-delay/ctx-thread) + builders/messageOf/constants.
```

**File responsibilities**
- `extension/dispatch.ts` — the RPC dispatch + error-boundary layer. Pure functions,
  no module state, no socket/server/provider dependency. `wrapHandler` is the
  never-throw error boundary; `dispatch`/`buildDispatcher` apply it to a handler
  registry; the builders/messageOf/constants are the shared DRY helpers. S8 imports
  `dispatch` (and may import `wrapHandler`/builders if it builds its own step).
- `extension/tests/dispatch.test.ts` — the contract gate for S15: proves the
  never-throw / no-unhandled-rejection guarantee (the load-bearing `await`), the
  strict-mode `catch` narrow (`messageOf`), the `-32603`/`-32601` codes, and the
  handler↔dispatch outcome flow — all with mock steps/handlers, no real socket.

### Known Gotchas of our codebase & Library Quirks

```typescript
// CRITICAL (verified, research §3; TS strict ⇒ useUnknownInCatchVariables): under
//   `strict: true`, `catch (err)` binds `err` as `unknown`, NOT `Error`. The item
//   contract literally says `message: error.message`, but reading `.message` off
//   `unknown` is TS18046 (a COMPILE ERROR). You MUST narrow:
//     messageOf(err) = err instanceof Error ? err.message : String(err)
//   Use `messageOf(err)` in the catch. The non-Error-throw test (throw a string,
//   throw an object) proves the `String(err)` fallback is load-bearing.

// CRITICAL (verified, research §3/§4): wrapHandler MUST `return await step(req)`,
//   NOT `return step(req)`. Without the inner `await`, a rejection from `step`
//   propagates as the RETURNED promise's rejection — i.e. wrapHandler's own
//   returned promise would reject, defeating the error boundary AND triggering
//   Node 15+'s default unhandled-rejection=throw process termination. The inner
//   `await` makes the catch fire INSIDE wrapHandler so the returned promise always
//   RESOLVES (success OR error envelope). This is the single most important line.

// CRITICAL (verified, research §4; Node 15+): an UNHANDLED promise rejection
//   terminates the process by default. The bridge runs inside pi's session_start,
//   so an un-awaited rejection from a slow/aborted getSuggestions would CRASH pi.
//   wrapHandler's await is the structural fix: the rejection is chained + caught →
//   resolved value → "handled" → no 'unhandledRejection'. The reject-after-delay
//   test attaches process.once("unhandledRejection", fail) as a tripwire to PROVE
//   none fires (remove it in finally).

// CRITICAL (research §1; S11 contract): handlers ALREADY self-wrap — they return a
//   HandlerOutcome<T> = {ok:true,result}|{ok:false,error} and (per S11/S12 PRPs)
//   "NEVER throw". wrapHandler is a SAFETY NET for the rare case a handler forgets
//   to self-wrap or a genuine bug throws in dispatcher/envelope logic. Do NOT make
//   wrapHandler the primary error path — the handlers' own {ok:false,error} is.
//   S11/S12 forward-ref "S15 generalizes toRpcError" — messageOf IS that
//   generalization (method-agnostic; the handlers keep their method-prefixed msgs).

// CRITICAL (research §1.4; S11 research §1): the 1500ms timeout from S11 normally
//   RESOLVES NULL, it does NOT throw — pi's CombinedAutocompleteProvider SIGKILLs
//   fd → [] → null on abort. So the timeout path yields a clean {ok:true,result:null}
//   outcome → toResponse → success envelope; wrapHandler never sees it. S15
//   introduces NO Promise.race and NO timeout of its own. S15's only timeout-related
//   job is to `await` so any stray rejection is consumed. If you add a race/timeout
//   to dispatch.ts you have LEFT SCOPE.

// GOTCHA (research §6): RpcOutcome<T> is STRUCTURALLY IDENTICAL to S11's
//   HandlerOutcome<T> ({ok:true,result:T}|{ok:false,error:JsonRpcError}). TS is
//   structural, so a real HandlerOutcome<T> is assignable to RpcOutcome<T> with NO
//   cross-module import. This is WHY dispatch.ts can compile standalone TODAY
//   (protocol.ts-only dep) without waiting for S11 to merge. Do NOT import
//   HandlerOutcome/ConnectionContext from pi-editor-bridge.ts.

// GOTCHA (research §6; S8 integration, documented for the implementer): the
//   HandlerRegistry expects handlers (params: unknown, ctx) => Promise<RpcOutcome>.
//   S11's typed handler is (params: GetSuggestionsParams, ctx: ConnectionContext).
//   Under strictFunctionTypes, a handler expecting SPECIFIC params is NOT directly
//   assignable to a slot expecting unknown params (contravariance). S8 adapts at
//   the registry site: `getSuggestions: (p, ctx) => handleGetSuggestions(p as
//   GetSuggestionsParams, ctx)`. Param narrowing is S8's job, NOT S15's — S15's lane
//   is the error boundary. (S15's tests use handlers that already accept unknown.)

// GOTCHA: JsonRpcResponse (protocol.ts §A) is a DISCRIMINATED UNION — success has
//   `result` and NO `error`; error has `error` and NO `result`. successResponse/
//   errorResponse/toResponse must emit EXACTLY one branch (never both keys, never
//   neither). `result?: unknown` is optional on the success branch — omitting it is
//   legal but buildDispatcher always has a result, so include it.

// GOTCHA: dispatch/wrapHandler assume `req` is a valid id'd JsonRpcRequest (req.id
//   is a string). S8 is responsible for JSON.parse (→ -32700 on parse failure,
//   which is S8/S15-adjacent but NOT this task: S8 owns parse) and for only calling
//   dispatch on id'd REQUESTS (notifications have no id → no response; commandsChanged
//   is S→C). wrapHandler uses req.id verbatim. Do not add id-presence validation to
//   dispatch.ts — that is S8's parse/envelope gate.

// GOTCHA (jiti): `import type {...} from "./protocol.ts"` is fully erased at runtime
//   (protocol.ts is type-only). dispatch.ts has ZERO runtime imports from protocol.ts.
//   It compiles + loads as a module whose only runtime values are the exported
//   functions/constants. Confirmed by protocol.test.ts (protocol.ts loads as an empty
//   namespace).

// GOTCHA: node:test's default reporter prints `ℹ pass N` / `ℹ fail N` (NOT TAP
//   `ok`/`not ok`). Judge the test by exit code 0 + `ℹ fail 0`. jiti prints a benign
//   `DeprecationWarning: module.register() is deprecated` on Node 26 stderr — IGNORE.

// GOTCHA: S15 writes NOTHING to process.env and changes NO behavior in
//   pi-editor-bridge.ts. The new module is dead code (not imported anywhere) until
//   S8. That is BY DESIGN — it lets the error boundary be unit-tested in complete
//   isolation before wiring (same as S7's jsonl-reader).

// STYLE: TABS for indentation (match the existing pi-editor-bridge.ts / protocol.ts /
//   jsonl-reader.ts / every test file + pi's own modules). `import type` for ALL
//   type-only imports. Mode-A JSDoc on every export with a `STATUS (P1.M2.T7.S15)`
//   marker + forward refs (S8 consumer, S11–S14 handlers, S9/S10 handshake).
```

## Implementation Blueprint

### Data models and structure

S15 introduces **no new wire types** (those live in `protocol.ts`, S4). Its "data
model" is the **dispatch/error-boundary contract**:

- `DispatchStep` — `(req: JsonRpcRequest) => Promise<JsonRpcResponse> | JsonRpcResponse`.
  The unit of work wrapHandler wraps. S8 builds one per connection (or uses
  `buildDispatcher`).
- `RpcOutcome<T>` (structural) — `{ok:true;result:T} | {ok:false;error:JsonRpcError}`.
  Identical to S11's `HandlerOutcome<T>`; what the handlers return and what
  `toResponse` envelopes.
- `RpcHandler<C>` — `(params: unknown, ctx: C) => Promise<RpcOutcome> | RpcOutcome`.
  The registry slot type. `params: unknown` (handler narrows); `<C>` lets S8
  instantiate with `ConnectionContext`.
- `HandlerRegistry<C>` — `Readonly<Record<string, RpcHandler<C>>>`.
- Error-code constants — `RPC_PARSE_ERROR=-32700`, `RPC_INVALID_REQUEST=-32600`,
  `RPC_METHOD_NOT_FOUND=-32601`, `RPC_INVALID_PARAMS=-32602`, `RPC_INTERNAL_ERROR=-32603`.
- No module-level mutable state. All exports are pure (wrapping a step / building a
  dispatcher from args). Two sockets each get their own `respond = dispatch(handlers,
  ctx)` closure — no shared singleton (unlike the server in `pi-editor-bridge.ts`).

### Implementation Tasks (ordered by dependencies)

```yaml
Task 1: CREATE extension/dispatch.ts (the dispatch + error-boundary engine)
  - CREATE the file with the exact reference body in Implementation Patterns below.
  - IMPORT (type-only, ./protocol.ts ONLY):
        import type { JsonRpcError, JsonRpcRequest, JsonRpcResponse } from "./protocol.ts";
  - EXPORT error-code constants: RPC_PARSE_ERROR=-32700, RPC_INVALID_REQUEST=-32600,
      RPC_METHOD_NOT_FOUND=-32601, RPC_INVALID_PARAMS=-32602, RPC_INTERNAL_ERROR=-32603.
  - EXPORT `messageOf(err: unknown): string` → `err instanceof Error ? err.message : String(err)`.
  - EXPORT `successResponse(id, result): JsonRpcResponse` → {jsonrpc:"2.0", id, result}.
  - EXPORT `errorResponse(id, code, message): JsonRpcResponse` → {jsonrpc:"2.0", id, error:{code,message}}.
  - EXPORT `toResponse(id, outcome: RpcOutcome): JsonRpcResponse` → outcome.ok ? successResponse : errorResponse.
  - EXPORT `RpcOutcome<T>` type, `RpcHandler<C>` type, `HandlerRegistry<C>` type, `DispatchStep` type.
  - EXPORT `wrapHandler(step: DispatchStep): (req: JsonRpcRequest) => Promise<JsonRpcResponse>`
      — body: `return async (req) => { try { return await step(req); } catch (err) {
      return errorResponse(req.id, RPC_INTERNAL_ERROR, messageOf(err)); } };`.
  - EXPORT `buildDispatcher<C>(handlers, ctx): DispatchStep` — body: `return async (req)
      => { const handler = handlers[req.method]; if (!handler) return errorResponse(req.id,
      RPC_METHOD_NOT_FOUND, \`method not found: ${String(req.method)}\`); const outcome =
      await handler(req.params ?? {}, ctx); return toResponse(req.id, outcome); };`.
  - EXPORT `dispatch<C>(handlers, ctx): (req) => Promise<JsonRpcResponse>` → `return wrapHandler(buildDispatcher(handlers, ctx));`.
  - JSDOC: file-level block citing PRD §6.7 + §5.3 + §5.5 + the S11 HandlerOutcome
      contract + the safety-NET-not-replacement framing; per-export Mode-A blocks
      with a STATUS (P1.M2.T7.S15) marker + forward ref ("S8 imports dispatch into
      onConnection"). wrapHandler's JSDoc MUST explain the error-boundary contract
      (never throws; await = handled; -32603) — the item's [Mode A] DOCS requirement.
  - NAMING: wrapHandler / dispatch / buildDispatcher / toResponse / successResponse /
      errorResponse / messageOf / RpcOutcome / RpcHandler / HandlerRegistry / DispatchStep
      / RPC_* — EXACT (camelCase fn/var, PascalCase type, SCREAMING_SNAKE constants).
  - FOLLOW: TAB indentation; `import type` for protocol.ts; match the JSDoc density of
      protocol.ts / jsonl-reader.ts / pi-editor-bridge.ts.
  - DO NOT: import from pi-editor-bridge.ts (structural RpcOutcome, no coupling); import
      jsonl-reader.ts (S8 serializes); add module state; use Promise.race or a timeout;
      validate params (S8/handlers); read process.env; touch the socket.

Task 2: MODIFY extension/tsconfig.json — append "dispatch.ts" to include
  - CHANGE the include array from:
        "include": ["pi-editor-bridge.ts", "protocol.ts", "jsonl-reader.ts", "tests/**/*.ts"]
    to:
        "include": ["pi-editor-bridge.ts", "protocol.ts", "jsonl-reader.ts", "dispatch.ts", "tests/**/*.ts"]
  - WHY: tsc only type-checks files matched by include (or imported by them). dispatch.ts
      is not imported anywhere yet (S8 does that), so it MUST be in include to be checked.
      This is the IDENTICAL one-line additive edit S4 made for protocol.ts and S7 made
      for jsonl-reader.ts (research §5).
  - DO NOT: touch compilerOptions (the globals/strict mode + the node:* transitive
      resolution depend on it staying EXACTLY as-is); edit paths; reorder entries.

Task 3: CREATE extension/tests/dispatch.test.ts (node:test + jiti)
  - IMPORT: `import { test } from "node:test"; import assert from "node:assert/strict";`
      `import { wrapHandler, dispatch, buildDispatcher, successResponse, errorResponse,
      toResponse, messageOf, RPC_INTERNAL_ERROR, RPC_METHOD_NOT_FOUND } from "../dispatch.ts";`
      `import type { JsonRpcRequest } from "../protocol.ts";`
  - HELPERS: `mkReq(method="ping", params={}): JsonRpcRequest` → {jsonrpc:"2.0",
      id:"1", method, params}; `mkReqId(id, method, params)` variant for id control.
      A `withUnhandledRejectionTrap(fn)` helper that attaches
      `process.once("unhandledRejection", (r)=>{ fail("unhandled rejection: "+r); })`,
      runs `fn`, and removes the listener in finally — used by the reject-after-delay
      tests to PROVE no unhandled rejection fires.
  - TEST GROUP A — wrapHandler (the core):
    A1 (success passthrough): step returns successResponse("1",{x:1}); wrapped returns
        it verbatim (deep-equal). Returned promise RESOLVES.
    A2 (sync throw): step = () => { throw new Error("boom-sync"); }; wrapped →
        {jsonrpc:"2.0",id:"1",error:{code:-32603,message:"boom-sync"}}; RESOLVES not rejects.
    A3 (async reject): step = async () => { throw new Error("boom-async"); }; wrapped →
        -32603 "boom-async"; RESOLVES not rejects.
    A4 (reject-after-delay + NO unhandledRejection): step = () => new Promise((_,rej)=>
        setTimeout(()=>rej(new Error("timeout-boom")), 20)); inside
        withUnhandledRejectionTrap, await wrapped(req) → -32603 "timeout-boom" AND the
        trap never fired. (Proves `return await` is load-bearing + Node won't kill.)
    A5 (non-Error throw — messageOf fallback): step = () => { throw "string-err"; };
        wrapped → message === "string-err". Also `throw {custom:1}` → message ===
        "[object Object]" (String({custom:1})). Proves the strict-mode narrow.
    A6 (HOF identity): `typeof wrapHandler(step) === "function"` AND
        `wrapHandler(step) !== step` (returns a NEW function).
  - TEST GROUP B — dispatch / buildDispatcher (apply-the-wrapper):
    B1 (method-not-found): dispatch({}, mkReq("nope")) → {jsonrpc,id,error:{code:-32601,
        message:/method not found: nope/}}.
    B2 (ok-outcome → success envelope): handler returns {ok:true,result:{a:1}}; dispatch →
        {jsonrpc:"2.0",id:"1",result:{a:1}} (NO error key).
    B3 (error-outcome → error envelope): handler returns {ok:false,error:{code:-32602,
        message:"bad params"}}; dispatch → {jsonrpc:"2.0",id:"1",error:{code:-32602,...}}.
    B4 (handler throw → net): handler = () => { throw new Error("h-throw"); }; dispatch →
        -32603 "h-throw" (wrapHandler caught it). RESOLVES.
    B5 (handler reject-after-delay → net, no unhandledRejection): handler returns a promise
        rejecting after setTimeout(20); inside withUnhandledRejectionTrap, dispatch → -32603
        AND trap never fired.
    B6 (ctx threaded through): handler records its ctx arg; dispatch(handlers, ctxObj);
        assert the handler received ctxObj unchanged (proves ctx threading, generic <C>).
    B7 (params passed through): handler records params; dispatch with req.params={x:9};
        assert handler got {x:9}; also req with NO params key → handler got {} (the ?? {} default).
  - TEST GROUP C — builders / helpers / constants:
    C1 successResponse("2",{r:1}) deep-equals {jsonrpc:"2.0",id:"2",result:{r:1}}; has NO
        "error" key (Object.keys length 3).
    C2 errorResponse("2",-32603,"m") deep-equals {jsonrpc:"2.0",id:"2",error:{code:-32603,
        message:"m"}}; has NO "result" key.
    C3 toResponse("1",{ok:true,result:1}) → success branch; toResponse("1",{ok:false,
        error:{code:-32601,message:"x"}}) → error branch.
    C4 messageOf(new Error("e"))==="e"; messageOf("str")==="str"; messageOf(42)==="42";
        messageOf(null)==="null"; messageOf(undefined)==="undefined".
    C5 constants: RPC_INTERNAL_ERROR===-32603; RPC_METHOD_NOT_FOUND===-32601;
        RPC_PARSE_ERROR===-32700; RPC_INVALID_REQUEST===-32600; RPC_INVALID_PARAMS===-32602.
  - SHARED-STATE NOTE: the module under test is PURE (no module state), so test order is
      irrelevant; keep top-level test(...) sequential (house default) — do NOT enable
      concurrency. The withUnhandledRejectionTrap helper removes its listener in finally
      so traps never leak across tests.
  - FOLLOW: TAB indentation; reuse the jiti register hook path from S2/S3/S4/S5/S7.
  - NAMING: descriptive test("…") titles; no describe.
  - PLACEMENT: extension/tests/dispatch.test.ts (matches tests/**/*.ts → NO other tsconfig edit).

Task 4: VALIDATE — run the validation commands; fix until all green
  - RUN (Level 1): `tsc --noEmit -p extension/tsconfig.json` (expect exit 0, no output)
  - RUN (Level 2): `node --import "$JITI_REG" extension/tests/dispatch.test.ts`
      (expect exit 0, ℹ fail 0 — ignore the benign jiti DEP0205 deprecation on stderr)
  - RUN (Level 2 regression): re-run provider-capture / mode-guard / protocol /
      bridge-lifecycle / bridge-lifecycle-wiring / jsonl-reader — expect each ℹ fail 0
  - RUN (Level 3): `pi --no-extensions -e ./extension/pi-editor-bridge.ts --print "ok"`
      exits 0 with no error lines (the new module isn't imported by the entry point yet)
  - RUN (sanity): grep-confirm pi-editor-bridge.ts is UNCHANGED at the onConnection
      placeholder; grep-confirm tsconfig compilerOptions UNCHANGED.
```

### Implementation Patterns & Key Details

```typescript
// === extension/dispatch.ts (CREATE) — the RPC dispatch + error-boundary engine.
//     Pure functions, no module state, ./protocol.ts types ONLY. Node builtins/globals
//     only (PRD §6.7 "no npm runtime dependencies"). Dead code until S8 imports it. ===

/**
 * dispatch.ts — the RPC dispatch + error-boundary engine for the pi-editor-bridge.
 *
 * Guarantees PRD §6.7 ("Never throws from handlers (wrap in try/catch, return
 * JSON-RPC error)") STRUCTURALLY: a {@link wrapHandler} higher-order function
 * wraps the dispatch step so it can NEVER throw to its caller — any sync throw or
 * async rejection becomes a JSON-RPC `error` envelope `{code:-32603, message}`.
 * Because it `await`s the step, a rejection becomes a *resolved* value (handled),
 * never an unhandled-rejection that Node 15+ would use to terminate pi.
 *
 * Defense-in-depth, NOT a replacement: the handlers (S11–S14) ALREADY self-wrap —
 * they return a `HandlerOutcome` (`{ok:true,result}|{ok:false,error}`) on every
 * path instead of throwing. wrapHandler is the SECOND line of defense, catching
 * the things a handler forgot to self-wrap plus truly unexpected dispatcher /
 * envelope-logic throws. (S11/S12 PRPs: "S15 adds a global try/catch as a safety
 * NET for truly unexpected handler bugs, NOT a replacement.")
 *
 * The 1500 ms getSuggestions timeout (PRD §5.5, S11) is handled STRUCTURALLY here:
 * S11's handler `await`s the provider and `clearTimeout`s in `finally`, and
 * `dispatch`/`wrapHandler` `await` the handler — every layer awaits, so the abort
 * path resolves a clean `{ok:true,result:null}` (pi's provider resolves null on
 * abort, S11 research §1) and any stray rejection is caught. This module introduces
 * NO `Promise.race` and NO timeout of its own.
 *
 * STATUS (P1.M2.T7.S15): the error-boundary + dispatch engine. S8 imports
 * `dispatch` into `onConnection` (after S7's reader parses a `JsonRpcRequest`):
 *   const respond = dispatch(handlers, connCtx);
 *   sock.write(serializeJsonLine(await respond(req)));   // NEVER throws
 * S11–S14 provide the handlers (returning HandlerOutcome); S9/S10 gate dispatch
 * on the hello handshake BEFORE calling `respond`. Until S8 wires it, this module
 * is dead code (unit-tested in isolation).
 *
 * Node builtins/globals only (PRD §6.7). No module state. Depends ONLY on
 * ./protocol.ts (type-only).
 */
import type {
	JsonRpcError,
	JsonRpcRequest,
	JsonRpcResponse,
} from "./protocol.ts";

/* ==========================================================================
 * §A — JSON-RPC 2.0 error codes (spec; protocol.ts §A documents these). Exported
 *      as constants so callers (wrapHandler=-32603, buildDispatcher=-32601) and
 *      future handlers (S11–S14 use -32603 in their own outcomes) reference them
 *      by name, not magic numbers. -32000..-32099 (server-error) is NOT used.
 * ========================================================================== */
export const RPC_PARSE_ERROR = -32700;
export const RPC_INVALID_REQUEST = -32600;
export const RPC_METHOD_NOT_FOUND = -32601;
export const RPC_INVALID_PARAMS = -32602;
export const RPC_INTERNAL_ERROR = -32603;

/* ==========================================================================
 * §B — The handler↔dispatcher outcome contract. RpcOutcome<T> is STRUCTURALLY
 *      IDENTICAL to the HandlerOutcome<T> defined in pi-editor-bridge.ts (S11):
 *      TS structural typing means a real HandlerOutcome<T> is assignable here
 *      with NO cross-module import (so this module compiles standalone today).
 *      RpcHandler<C> takes `params: unknown` (the handler narrows its own params)
 *      and a generic context <C> (S8 instantiates with ConnectionContext).
 * ========================================================================== */

/** A handler outcome — success carries the typed result, failure carries a JSON-RPC
 *  error. Structurally identical to S11's HandlerOutcome<T> (no cross-module import). */
export type RpcOutcome<T = unknown> =
	| { ok: true; result: T }
	| { ok: false; error: JsonRpcError };

/** A registered RPC method handler. `params: unknown` — the handler validates/narrows
 *  its own params; `ctx` is threaded opaquely (generic <C>). Returns an RpcOutcome
 *  (self-wrapped: never throws — PRD §6.7 first line of defense). */
export type RpcHandler<C = unknown> = (
	params: unknown,
	ctx: C,
) => Promise<RpcOutcome> | RpcOutcome;

/** Method-name → handler map. S8 builds this; `dispatch` consumes it. */
export type HandlerRegistry<C = unknown> = Readonly<Record<string, RpcHandler<C>>>;

/** The unit of work wrapHandler wraps: turn one request into one wire response. */
export type DispatchStep = (
	req: JsonRpcRequest,
) => Promise<JsonRpcResponse> | JsonRpcResponse;

/* ==========================================================================
 * §C — Shared DRY helpers. messageOf generalizes S11's module-private toRpcError
 *      body (`err instanceof Error ? err.message : String(err)`) to a method-agnostic
 *      helper (S11/S12 forward-ref "S15 generalizes toRpcError"). The handlers keep
 *      their method-prefixed messages for their OWN outcomes; wrapHandler's catch-all
 *      uses this (no prefix).
 * ========================================================================== */

/** Map a caught `unknown` to a string. REQUIRED because TS `strict` ⇒ `catch`
 *  binds `unknown` (useUnknownInCatchVariables), so `err.message` is a TS18046
 *  compile error without this narrow. Non-Error throws fall back to `String(err)`. */
export function messageOf(err: unknown): string {
	return err instanceof Error ? err.message : String(err);
}

/** Build a success response: `{jsonrpc:"2.0", id, result}` (NO `error` key). */
export function successResponse(id: string, result: unknown): JsonRpcResponse {
	return { jsonrpc: "2.0", id, result };
}

/** Build an error response: `{jsonrpc:"2.0", id, error:{code, message}}` (NO `result` key). */
export function errorResponse(
	id: string,
	code: number,
	message: string,
): JsonRpcResponse {
	return { jsonrpc: "2.0", id, error: { code, message } };
}

/** Envelope a handler's RpcOutcome into a wire JsonRpcResponse (DRY for S8/buildDispatcher). */
export function toResponse(id: string, outcome: RpcOutcome): JsonRpcResponse {
	return outcome.ok
		? successResponse(id, outcome.result)
		: errorResponse(id, outcome.error.code, outcome.error.message);
}

/* ==========================================================================
 * §D — wrapHandler: the error-boundary higher-order function (the deliverable).
 *
 *      CONTRACT: the returned function NEVER throws and NEVER rejects — it always
 *      RESOLVES to a JsonRpcResponse (success passthrough OR -32603 error envelope).
 *      This is the structural enforcement of PRD §6.7 "Never throws from handlers".
 *
 *      The inner `return await step(req)` (NOT `return step(req)`) is load-bearing:
 *      the `await` makes the catch fire INSIDE this HOF, so a rejection from `step`
 *      becomes a RESOLVED error-envelope value rather than the returned promise's
 *      rejection. Without it, an async rejection would escape as an unhandled
 *      rejection (Node 15+ terminates the process on those). See research §3/§4.
 * ========================================================================== */

/**
 * Wrap a dispatch step so it can NEVER throw to its caller. Any sync throw or async
 * rejection from `step` is caught and returned as a JSON-RPC `error` envelope
 * `{jsonrpc:"2.0", id: req.id, error: {code:-32603, message: messageOf(err)}}`.
 * The returned function always RESOLVES (never rejects).
 *
 * Error-boundary contract (PRD §6.7):
 *  - On success: the step's `JsonRpcResponse` is returned verbatim.
 *  - On any throw/reject: a `-32603` (internal error) envelope is returned.
 *    `messageOf(err)` narrows `unknown`→`string` (strict-mode `catch`), falling back
 *    to `String(err)` for non-Error throws.
 *  - Never blocks the event loop synchronously: the step is `await`ed (so an async
 *    handler's `getSuggestions` is awaited end-to-end — PRD §6.7 "all getSuggestions
 *    are awaited").
 *  - Never produces an unhandled rejection: the inner `await` chains the rejection
 *    into this HOF's catch, so it is "handled" (Node 15+ would otherwise terminate
 *    pi on an unhandled rejection). This is what makes the S11 1500 ms timeout
 *    "abort cleanly, not as an unhandled rejection" — even if a wrapped provider
 *    threw on abort, wrapHandler would catch it.
 *
 * Defense-in-depth: the handlers (S11–S14) already self-wrap into HandlerOutcome
 * and never throw. wrapHandler is the SAFETY NET for a forgotten self-wrap or a
 * genuine dispatcher/envelope-logic bug — NOT a replacement for self-wrapping.
 *
 * STATUS (P1.M2.T7.S15): the title-named deliverable. S8 wraps its per-connection
 * dispatch step (or uses `dispatch`, which wraps `buildDispatcher`).
 *
 * @param step a function turning one request into one wire response (may throw/reject).
 * @returns a function with the SAME signature that never throws/rejects.
 */
export function wrapHandler(
	step: DispatchStep,
): (req: JsonRpcRequest) => Promise<JsonRpcResponse> {
	return async (req) => {
		try {
			// CRITICAL: `await` (not bare `return step(req)`) — makes the catch fire
			// inside this HOF so a rejection becomes a RESOLVED error envelope, never
			// an unhandled rejection (Node 15+ kills on those).
			return await step(req);
		} catch (err) {
			// err is `unknown` under TS strict (useUnknownInCatchVariables) — messageOf
			// narrows it. -32603 = internal error (JSON-RPC 2.0 spec).
			return errorResponse(req.id, RPC_INTERNAL_ERROR, messageOf(err));
		}
	};
}

/* ==========================================================================
 * §E — buildDispatcher + dispatch: APPLY the wrapper in the dispatch logic.
 *      buildDispatcher turns a handler registry + ctx into a DispatchStep (method
 *      lookup → invoke → envelope; -32601 on unknown method). dispatch wraps that
 *      step with wrapHandler, so the whole thing never throws. S8 calls
 *      `dispatch(handlers, connCtx)` once per connection and `await respond(req)`.
 * ========================================================================== */

/**
 * Build the per-request dispatch step from a handler registry + connection context.
 * For each request: look up the handler by `req.method`; if absent, return a
 * `-32601` (method not found) envelope; otherwise `await` the handler with
 * `req.params ?? {}` and `ctx`, then envelope its RpcOutcome via {@link toResponse}.
 *
 * This step MAY throw (a handler that forgot to self-wrap, or a dispatcher bug) —
 * that is why {@link dispatch} wraps it with {@link wrapHandler}. Auth/handshake
 * gating (S9/S10) is the CALLER's concern, applied BEFORE calling the returned step.
 *
 * STATUS (P1.M2.T7.S15): the dispatch logic. `dispatch` wraps it; S8 may also wrap
 * a custom step with wrapHandler directly if it needs a different registry shape.
 */
export function buildDispatcher<C>(
	handlers: HandlerRegistry<C>,
	ctx: C,
): DispatchStep {
	return async (req) => {
		const handler = handlers[req.method];
		if (!handler) {
			return errorResponse(
				req.id,
				RPC_METHOD_NOT_FOUND,
				`method not found: ${String(req.method)}`,
			);
		}
		const outcome = await handler(req.params ?? {}, ctx);
		return toResponse(req.id, outcome);
	};
}

/**
 * Build a never-throwing request responder: `dispatch(handlers, ctx)` returns
 * `(req) => Promise<JsonRpcResponse>` = `wrapHandler(buildDispatcher(handlers, ctx))`.
 * S8 usage:
 *   const respond = dispatch(handlers, connCtx);          // once per connection
 *   const response = await respond(req);                  // NEVER throws
 *   sock.write(serializeJsonLine(response));              // S7's serializer
 *
 * STATUS (P1.M2.T7.S15): the convenience that APPLIES wrapHandler in the dispatch
 * logic (the item's "apply this wrapper in the dispatch logic" requirement).
 */
export function dispatch<C>(
	handlers: HandlerRegistry<C>,
	ctx: C,
): (req: JsonRpcRequest) => Promise<JsonRpcResponse> {
	return wrapHandler(buildDispatcher(handlers, ctx));
}
```

```typescript
// === extension/tests/dispatch.test.ts (CREATE — node:test + jiti; NOT vitest) ===
import { test } from "node:test";
import assert from "node:assert/strict";
import {
	wrapHandler,
	buildDispatcher,
	dispatch,
	successResponse,
	errorResponse,
	toResponse,
	messageOf,
	RPC_INTERNAL_ERROR,
	RPC_METHOD_NOT_FOUND,
	RPC_PARSE_ERROR,
	RPC_INVALID_REQUEST,
	RPC_INVALID_PARAMS,
} from "../dispatch.ts";
import type { JsonRpcRequest, JsonRpcResponse } from "../protocol.ts";

// --- helpers ---
function mkReq(method = "ping", params: unknown = {}): JsonRpcRequest {
	return { jsonrpc: "2.0", id: "1", method, params };
}

// Run `fn` with a one-shot 'unhandledRejection' tripwire that FAILS the test if any
// rejection escapes. Removes the listener in finally so it can't poison siblings.
// (Proves wrapHandler's `await` made every rejection "handled".)
async function withUnhandledRejectionTrap<T>(fn: () => Promise<T>): Promise<T> {
	let tripped = false;
	const onUr = (reason: unknown) => {
		tripped = true;
		assert.fail(`unhandledRejection fired (should be handled): ${String(reason)}`);
	};
	process.once("unhandledRejection", onUr);
	try {
		const out = await fn();
		// let the microtask queue + a timer tick drain so a late rejection would surface
		await new Promise((r) => setTimeout(r, 30));
		assert.equal(tripped, false, "no unhandledRejection should have fired");
		return out;
	} finally {
		process.off("unhandledRejection", onUr);
	}
}

// ============================================================================
// GROUP A — wrapHandler (the core deliverable)
// ============================================================================
test("wrapHandler: success response passes through verbatim", async () => {
	const step = () => Promise.resolve(successResponse("1", { x: 1 }));
	const wrapped = wrapHandler(step);
	const out = await wrapped(mkReq());
	assert.deepEqual(out, { jsonrpc: "2.0", id: "1", result: { x: 1 } });
});

test("wrapHandler: synchronous throw → -32603 envelope (resolves, not rejects)", async () => {
	const step = (): JsonRpcResponse => {
		throw new Error("boom-sync");
	};
	const wrapped = wrapHandler(step);
	const out = await wrapped(mkReq()); // resolves (does not reject)
	assert.deepEqual(out, {
		jsonrpc: "2.0",
		id: "1",
		error: { code: RPC_INTERNAL_ERROR, message: "boom-sync" },
	});
});

test("wrapHandler: async reject → -32603 envelope (resolves, not rejects)", async () => {
	const step = async (): Promise<JsonRpcResponse> => {
		throw new Error("boom-async");
	};
	const wrapped = wrapHandler(step);
	const out = await wrapped(mkReq());
	assert.deepEqual(out, {
		jsonrpc: "2.0",
		id: "1",
		error: { code: RPC_INTERNAL_ERROR, message: "boom-async" },
	});
});

test("wrapHandler: reject-after-delay → -32603 AND no unhandledRejection (await is load-bearing)", async () => {
	const step = () =>
		new Promise<JsonRpcResponse>((_resolve, reject) =>
			setTimeout(() => reject(new Error("timeout-boom")), 20),
		);
	const wrapped = wrapHandler(step);
	const out = await withUnhandledRejectionTrap(() => wrapped(mkReq()));
	assert.deepEqual(out, {
		jsonrpc: "2.0",
		id: "1",
		error: { code: RPC_INTERNAL_ERROR, message: "timeout-boom" },
	});
});

test("wrapHandler: non-Error throw → messageOf fallback (strict-mode catch narrow)", async () => {
	const strStep = (): JsonRpcResponse => {
		throw "string-err";
	};
	const objStep = (): JsonRpcResponse => {
		throw { custom: 1 };
	};
	const a = await wrapHandler(strStep)(mkReq());
	assert.equal((a as { error: { message: string } }).error.message, "string-err");
	const b = await wrapHandler(objStep)(mkReq());
	assert.equal((b as { error: { message: string } }).error.message, "[object Object]");
});

test("wrapHandler: returns a NEW function (HOF identity)", () => {
	const step = () => Promise.resolve(successResponse("1", 0));
	const wrapped = wrapHandler(step);
	assert.equal(typeof wrapped, "function");
	assert.notEqual(wrapped, step);
});

// ============================================================================
// GROUP B — dispatch / buildDispatcher (apply-the-wrapper)
// ============================================================================
test("dispatch: method-not-found → -32601", async () => {
	const respond = dispatch({}, undefined);
	const out = await respond(mkReq("nope"));
	assert.equal((out as { error: { code: number } }).error.code, RPC_METHOD_NOT_FOUND);
	assert.match(
		(out as { error: { message: string } }).error.message,
		/method not found: nope/,
	);
});

test("dispatch: ok-outcome → success envelope (no error key)", async () => {
	const handlers = {
		ping: () => Promise.resolve({ ok: true as const, result: { pong: 1 } }),
	};
	const out = await dispatch(handlers, undefined)(mkReq("ping"));
	assert.deepEqual(out, { jsonrpc: "2.0", id: "1", result: { pong: 1 } });
	assert.equal("error" in out, false, "success envelope must NOT have an error key");
});

test("dispatch: error-outcome → error envelope passthrough", async () => {
	const handlers = {
		ping: () =>
			Promise.resolve({
				ok: false as const,
				error: { code: RPC_INVALID_PARAMS, message: "bad params" },
			}),
	};
	const out = await dispatch(handlers, undefined)(mkReq("ping"));
	assert.deepEqual(out, {
		jsonrpc: "2.0",
		id: "1",
		error: { code: RPC_INVALID_PARAMS, message: "bad params" },
	});
});

test("dispatch: handler throw → wrapHandler catches → -32603", async () => {
	const handlers = {
		ping: () => {
			throw new Error("h-throw");
		},
	};
	const out = await dispatch(handlers, undefined)(mkReq("ping"));
	assert.deepEqual(out, {
		jsonrpc: "2.0",
		id: "1",
		error: { code: RPC_INTERNAL_ERROR, message: "h-throw" },
	});
});

test("dispatch: handler reject-after-delay → -32603, no unhandledRejection", async () => {
	const handlers = {
		ping: () =>
			new Promise<{ ok: true; result: number }>((_res, rej) =>
				setTimeout(() => rej(new Error("late")), 20),
			),
	};
	const out = await withUnhandledRejectionTrap(() =>
		dispatch(handlers, undefined)(mkReq("ping")),
	);
	assert.equal((out as { error: { code: number } }).error.code, RPC_INTERNAL_ERROR);
});

test("dispatch: ctx is threaded through to the handler unchanged", async () => {
	let received: unknown = "unset";
	const ctxObj = { marker: 42 };
	const handlers = {
		ping: (_p: unknown, ctx: unknown) => {
			received = ctx;
			return Promise.resolve({ ok: true as const, result: 1 });
		},
	};
	await dispatch(handlers, ctxObj)(mkReq("ping"));
	assert.equal(received, ctxObj);
});

test("dispatch: params passed through; missing params → {}", async () => {
	let receivedParams: unknown = "unset";
	const handlers = {
		ping: (p: unknown) => {
			receivedParams = p;
			return Promise.resolve({ ok: true as const, result: 1 });
		},
	};
	await dispatch(handlers, undefined)(mkReq("ping", { x: 9 }));
	assert.deepEqual(receivedParams, { x: 9 });
	// missing params key → default {}
	const reqNoParams = { jsonrpc: "2.0" as const, id: "1", method: "ping" };
	await dispatch(handlers, undefined)(reqNoParams);
	assert.deepEqual(receivedParams, {});
});

// ============================================================================
// GROUP C — builders / helpers / constants
// ============================================================================
test("successResponse: exact shape, no error key", () => {
	const r = successResponse("2", { r: 1 });
	assert.deepEqual(r, { jsonrpc: "2.0", id: "2", result: { r: 1 } });
	assert.deepEqual(Object.keys(r).sort(), ["id", "jsonrpc", "result"]);
});

test("errorResponse: exact shape, no result key", () => {
	const r = errorResponse("2", RPC_INTERNAL_ERROR, "m");
	assert.deepEqual(r, { jsonrpc: "2.0", id: "2", error: { code: RPC_INTERNAL_ERROR, message: "m" } });
	assert.deepEqual(Object.keys(r).sort(), ["error", "id", "jsonrpc"]);
});

test("toResponse: both branches", () => {
	const ok = toResponse("1", { ok: true, result: 7 });
	assert.deepEqual(ok, { jsonrpc: "2.0", id: "1", result: 7 });
	const err = toResponse("1", { ok: false, error: { code: RPC_METHOD_NOT_FOUND, message: "x" } });
	assert.deepEqual(err, { jsonrpc: "2.0", id: "1", error: { code: RPC_METHOD_NOT_FOUND, message: "x" } });
});

test("messageOf: Error/string/number/null/undefined", () => {
	assert.equal(messageOf(new Error("e")), "e");
	assert.equal(messageOf("str"), "str");
	assert.equal(messageOf(42), "42");
	assert.equal(messageOf(null), "null");
	assert.equal(messageOf(undefined), "undefined");
});

test("error-code constants equal the JSON-RPC spec values", () => {
	assert.equal(RPC_PARSE_ERROR, -32700);
	assert.equal(RPC_INVALID_REQUEST, -32600);
	assert.equal(RPC_METHOD_NOT_FOUND, -32601);
	assert.equal(RPC_INVALID_PARAMS, -32602);
	assert.equal(RPC_INTERNAL_ERROR, -32603);
});
```

### Integration Points

```yaml
NO external integration points for S15 (the module is pure functions; not wired anywhere yet).
  - No process.env write; no socket bind; no DB/config; no import added to any other file.
INTERNAL seam (the export S8 will consume — NOT wired in S15):
  - dispatch(handlers, ctx) → (req) => Promise<JsonRpcResponse>   → S8's onConnection:
        const respond = dispatch(handlers, connCtx);              // once per connection
        sock.write(serializeJsonLine(await respond(req)));        // S7 serializer; NEVER throws
  - wrapHandler(step)                                             → S8 may wrap a CUSTOM step directly
    if it needs a different registry/lookup shape (e.g. handshake interleaved).
  - successResponse/errorResponse/toResponse/messageOf            → handlers (S11–S14) may reuse
    messageOf for their own toRpcError generalization; S8 may reuse the builders.
NO tsconfig compilerOptions change:
  - The ONLY tsconfig edit is appending "dispatch.ts" to the include array (Task 2).
  - dispatch.ts uses only ./protocol.ts types + globals (Error/String); these resolve
    under the UNCHANGED compilerOptions (no lib field → DOM defaults → globals; verified
    by S11 research §2 and the green baseline). Do NOT add typeRoots/types/lib.
NO change to pi-editor-bridge.ts, protocol.ts, or jsonl-reader.ts:
  - The onConnection placeholder + its // TODO(S8) comment stay byte-for-byte intact
    (S8 imports dispatch there). protocol.ts/jsonl-reader.ts are untouched.
HANDSHAKE GATING (S9/S10 — NOT S15):
  - dispatch does NOT check connCtx.handshakeDone. S9/S10 gate dispatch at the S8 call
    site: if (!connCtx.handshakeDone && req.method !== "hello") return errorResponse
    (-32600 bad token) WITHOUT calling dispatch. S15's lane is the error boundary only.
PARAM NARROWING (S8 — NOT S15):
  - buildDispatcher passes req.params (unknown) to handlers verbatim. S8 adapts typed
    handlers at the registry site: getSuggestions: (p, ctx) => handleGetSuggestions(p
    as GetSuggestionsParams, ctx). S15 does not validate params.
```

## Validation Loop

### Level 1: Syntax & Style (Immediate Feedback) — THE TYPE GATE

```bash
# Type-check dispatch.ts + protocol.ts + pi-editor-bridge.ts + jsonl-reader.ts + all tests
# via the paths-mapped dev tsconfig. Load-bearing checks for S15: the type-only
# ./protocol.ts import resolves; the generics (RpcOutcome<T>, dispatch<C>) type-check;
# the catch-narrow (messageOf(err: unknown)) compiles under strict; the higher-order
# return type (req) => Promise<JsonRpcResponse> compiles; the discriminated-union
# builders (success/error) satisfy JsonRpcResponse. Failures are usually: reading
# err.message directly (TS18046 — use messageOf), a missing export, or an accidental
# compilerOptions edit.
tsc --noEmit -p extension/tsconfig.json
# Expected: exit 0, NO output.

# Indentation sanity (house style = TABS, like every existing extension file):
grep -nP '^    ' extension/dispatch.ts extension/tests/dispatch.test.ts \
  && echo "WARN: space-indent lines found" || echo "indent OK (tabs)"

# Confirm the ONLY tsconfig change is the include line (compilerOptions byte-identical):
grep -nE '"(types|typeRoots|lib|paths)"' extension/tsconfig.json \
  && echo "WARN: did S15 accidentally edit compilerOptions? (it should NOT)" \
  || echo "PASS: no compilerOptions keys present (S15 only edited include)"

# Confirm dispatch.ts is in include and pi-editor-bridge.ts is UNCHANGED:
grep -n '"dispatch.ts"' extension/tsconfig.json && echo "include OK"
grep -n 'TODO(S8): wire the JSONL reader' extension/pi-editor-bridge.ts \
  && echo "PASS: onConnection placeholder intact (S15 did not touch pi-editor-bridge.ts)" \
  || echo "FAIL: onConnection // TODO(S8) comment missing — S15 must not edit that file"
```

### Level 2: Unit Tests (Component Validation)

```bash
JITI_REG=/home/dustin/.local/lib/node_modules/@earendil-works/pi-coding-agent/node_modules/jiti/lib/jiti-register.mjs

# Run the new dispatch suite. Expected: exit 0, `ℹ fail 0` (the reject-after-delay test
# proves the `await` is load-bearing AND no unhandledRejection fires; the non-Error
# throw proves the strict-mode catch narrow).
node --import "$JITI_REG" extension/tests/dispatch.test.ts
# (jiti prints a benign DeprecationWarning on Node 26 stderr — judge by exit code + ℹ fail.)

# Full regression: every pre-existing suite still green (S15 is purely additive: it
# touches nothing these read). Expected: each prints `ℹ fail 0`.
for f in provider-capture mode-guard protocol bridge-lifecycle bridge-lifecycle-wiring jsonl-reader; do
  echo "--- $f ---"
  node --import "$JITI_REG" extension/tests/$f.test.ts
done
# (Once S11/S12 handler suites are merged, re-run handler-getsuggestions.test.ts +
#  the S12 suite too — S15 is additive to them as well.)
```

### Level 3: Integration Testing (System Validation)

```bash
# S15 ships NO wiring (dead code until S8), so the integration check is a regression
# that the extension still loads + runs in pi without the new module disturbing it.
pi --no-extensions -e ./extension/pi-editor-bridge.ts --print "ok"
# Expected: exits 0, prints "ok", NO error lines on stderr. The new dispatch.ts is not
# imported by the entry point yet, so the load path is unchanged — proves S15 is inert.

# (When S8 later wires `dispatch` into onConnection, the REAL integration test is:
#    launch pi in TUI mode → $EDITOR opens → a getSuggestions round-trip returns a
#    JsonRpcResponse even if the provider throws. That is S8's integration gate, NOT
#    S15's — S15's contract is the unit-testable never-throw guarantee proven in Level 2.)
```

### Level 4: Creative & Domain-Specific Validation

```bash
# S15 has no UI/DB/perf surface to exercise. The domain-specific validation is the
# UNHANDLED-REJECTION guarantee, which the Level 2 reject-after-delay test proves
# empirically (process.once("unhandledRejection") tripwire never fires). To re-confirm
# in isolation that an UNWRAPPED async reject WOULD crash (negative control), run:
node --input-type=module -e "
  process.once('unhandledRejection', () => { console.error('REJECTED (expected for negative control)'); });
  // bare reject with no handler → Node 15+ would terminate IF --unhandled-rejections=throw
  Promise.reject(new Error('neg'));
  setTimeout(() => console.log('survived 50ms'), 50);
"
# Then confirm the WRAPPED path (via the Level 2 suite) does NOT trip the handler —
# that contrast is the proof the await makes the rejection "handled".
```

## Final Validation Checklist

### Technical Validation

- [ ] All validation levels completed successfully
- [ ] `tsc --noEmit -p extension/tsconfig.json` → exit 0, no output
- [ ] `node --import "$JITI_REG" extension/tests/dispatch.test.ts` → exit 0, `ℹ fail 0`
- [ ] All pre-existing suites still `ℹ fail 0` (provider-capture, mode-guard, protocol,
      bridge-lifecycle, bridge-lifecycle-wiring, jsonl-reader)
- [ ] `pi --no-extensions -e ./extension/pi-editor-bridge.ts --print "ok"` exits 0, no errors
- [ ] `extension/tsconfig.json` `include` contains `"dispatch.ts"`; `compilerOptions` UNCHANGED

### Feature Validation

- [ ] `wrapHandler(step)` exists and on any sync-throw OR async-reject returns
      `{jsonrpc:"2.0", id, error:{code:-32603, message}}` and RESOLVES (never rejects)
- [ ] The reject-after-delay test proves NO `'unhandledRejection'` fires (await is load-bearing)
- [ ] Non-Error throws produce `messageOf` fallback (`String(err)`) — strict-mode catch narrow
- [ ] `dispatch(handlers, ctx)` applies wrapHandler; method-not-found → -32601; ok-outcome →
      success envelope; error-outcome → error envelope; handler-throw → -32603
- [ ] The 1500 ms timeout contract is satisfied structurally (no Promise.race/timeout in S15;
      the await chain consumes any rejection — verified by the reject-after-delay test)
- [ ] No handler ever throws to the caller (the item's OUTPUT contract)
- [ ] All success criteria from "What" section met

### Code Quality Validation

- [ ] Follows existing codebase patterns (node:test+jiti, TABS, `import type`, Mode-A JSDoc
      with STATUS markers) — matches S7's jsonl-reader.ts module style
- [ ] File placement matches desired codebase tree (new `extension/dispatch.ts`)
- [ ] Anti-patterns avoided (see below): no Promise.race, no `return step(req)` without await,
      no `err.message` off unknown, no cross-module import of HandlerOutcome, no compilerOptions edit
- [ ] Dependencies properly managed (./protocol.ts type-only; no npm deps; no import from
      pi-editor-bridge.ts)
- [ ] Configuration change properly integrated (one-line `include` edit only)

### Documentation & Deployment

- [ ] Mode-A JSDoc on `wrapHandler` explains the error-boundary contract (the item's DOCS req)
- [ ] Every export has a STATUS (P1.M2.T7.S15) marker + forward refs (S8/S11–S14/S9–S10)
- [ ] No new environment variables (S15 writes none)

---

## Anti-Patterns to Avoid

- ❌ Don't `return step(req)` (bare) in wrapHandler — you MUST `return await step(req)` so the
  catch fires inside the HOF. Without the await, a rejection escapes as the returned promise's
  rejection (unhandled → Node kills pi).
- ❌ Don't read `err.message` directly in a `catch` — under TS strict `err` is `unknown` (TS18046).
  Use `messageOf(err)` (the `instanceof Error` narrow + `String(err)` fallback).
- ❌ Don't make wrapHandler the PRIMARY error path — the handlers (S11–S14) self-wrap into
  HandlerOutcome; wrapHandler is a defense-in-depth SAFETY NET (S11/S12 are explicit on this).
- ❌ Don't add a `Promise.race` or a timeout to dispatch.ts — the 1500 ms timeout lives in S11's
  handler; S15 only `await`s. Adding one leaves scope.
- ❌ Don't import `HandlerOutcome`/`ConnectionContext` from pi-editor-bridge.ts — use the structural
  `RpcOutcome<T>` (identical shape; assignable with no import). Keeps dispatch.ts standalone.
- ❌ Don't emit both `result` and `error` on a response (JsonRpcResponse is a discriminated union).
  successResponse omits error; errorResponse omits result.
- ❌ Don't validate params or check the handshake in dispatch.ts — param narrowing is S8's job;
  handshake gating is S9/S10's job. S15's lane is the error boundary.
- ❌ Don't edit `compilerOptions` in tsconfig — only append `"dispatch.ts"` to `include`. A
  typeRoots/types/lib change can break the globals/transitive resolution (S7 research §3).
- ❌ Don't catch all exceptions silently and swallow — wrapHandler RETURNS the error as a JSON-RPC
  envelope (the message surfaces to the client), it never swallows.
