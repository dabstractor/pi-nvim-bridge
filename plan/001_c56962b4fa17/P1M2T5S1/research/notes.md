# Research Notes — P1.M2.T7.S15 (S15) — Wrap all handlers in try/catch with JSON-RPC error responses

> Orchestrator path note: artifacts live under `P1M2T5S1/`; the item is task
> **P1.M2.T7.S15** in the plan tree ("Wrap all handlers in try/catch with
> JSON-RPC error responses"). The folder label is decoupled from the plan id
> (same as P1M2T4S1=S11, P1M2T4S2=S12, P1M2T4S7=S7). Build the feature; ignore
> the folder label.

## §0 — The deliverable in one paragraph

Create an **error-boundary higher-order function `wrapHandler(step)`** (plus the
dispatch engine that applies it) so that **no handler invocation can ever throw
to its caller** (the socket-write loop). Any sync throw OR async rejection from
the dispatch step is caught and turned into a JSON-RPC error envelope
`{ jsonrpc: "2.0", id: req.id, error: { code: -32603, message } }`. Because the
HOF `await`s the step, a rejection becomes a *resolved* value (handled) — never
an unhandled-rejection that Node 15+ would use to terminate the process. It is a
**defense-in-depth safety NET around the handlers' own self-wrap**, NOT a
replacement for it (the S11/S12 PRPs are explicit on this — see §1).

---

## §1 — The S11/S12 handler contract (the make-or-break context)

Read `plan/001_c56962b4fa17/P1M2T4S1/PRP.md` (S11 getSuggestions) and
`P1M2T4S2/PRP.md` (S12 applyCompletion). They establish the handler↔dispatcher
contract S15 sits on top of:

1. **Handlers NEVER throw — they self-wrap.** Every handler (S11–S14) returns a
   discriminated `HandlerOutcome<T>`:
   ```ts
   export type HandlerOutcome<T> =
     | { ok: true;  result: T }
     | { ok: false; error: JsonRpcError };
   ```
   defined in `extension/pi-editor-bridge.ts` (S11 introduces it; S12/S13/S14
   reuse it). On any internal failure the handler itself returns
   `{ok:false,error:{code:-32603,message}}`. So in the *normal* case no error
   ever reaches wrapHandler.

2. **S15 is explicitly scoped as a SAFETY NET, not the primary handler.** Both
   S11 and S12 say verbatim: *"S15 adds a global try/catch as a safety NET for
   truly unexpected handler bugs, NOT a replacement for self-wrapping."* and
   *"the future S15 global try/catch is a defense-in-depth safety net."* So
   wrapHandler's job is to catch the things a handler *forgot* to self-wrap, or
   truly unexpected throws (e.g. a TypeError in dispatcher envelope logic, a
   handler-author bug, a provider edge that throws instead of resolving null).

3. **S15 "generalizes `toRpcError`".** S11's `toRpcError(err, code)` is
   module-private with a HARDCODED `"getSuggestions failed: "` prefix; S12
   inlines its own error object (prefix `"applyCompletion failed: "`). Both
   forward-refs say *"S15 may generalize [toRpcError] across handlers later."*
   → S15's `messageOf(err)` / `errorResponse(id, code, message)` helpers ARE
   that generalization. The handlers keep their method-prefixed messages for
   their OWN outcomes; wrapHandler's error envelope uses a generic
   `messageOf(err)` (no method prefix — it's the catch-all).

4. **The 1500 ms timeout from S11 normally resolves null, it does NOT throw.**
   S11 research §1 (load-bearing): pi's `CombinedAutocompleteProvider`
   RESOLVES `null` on abort — it SIGKILLs `fd` → `[]` → `null`; it does NOT
   throw `AbortError`. So the timeout/supersession path yields a clean
   `{ok:true, result:null}` outcome from the handler — wrapHandler never even
   sees it. **The "ensure the timeout aborts cleanly / no unhandled rejection"
   contract is satisfied structurally**: S11's handler `await`s the provider
   inside a `try/finally` that `clearTimeout`s, and wrapHandler `await`s the
   handler's returned promise. Anything that *does* reject (a wrapped provider
   throwing on abort, or a dispatcher-logic bug) is caught by wrapHandler. There
   is no dangling promise because every layer `await`s (§4).

5. **`AbortController.abort()` is idempotent** (DOM spec: "if aborted flag is
   set, return"). S11 calls `pendingAbort?.abort()` then may abort again on
   timeout — both safe. wrapHandler does not touch abort; it only guarantees the
   promise settles into a response.

---

## §2 — What already exists (verified by direct read)

- **`extension/protocol.ts`** (S4, DONE) — the type-only JSON-RPC contract S15
  imports from. Relevant exports:
  - `JsonRpcRequest { jsonrpc:"2.0"; id:string; method:string; params?:unknown }`
  - `JsonRpcResponse = | {jsonrpc:"2.0"; id:string; result?:unknown}`
                       `| {jsonrpc:"2.0"; id:string; error:JsonRpcError}`
  - `JsonRpcError { code:number; message:string }` — **NO `data` field** (minimal).
  - §A JSDoc lists the spec error codes: `-32700` parse, `-32600` invalid
    request, `-32601` method not found, `-32602` invalid params, `-32603`
    internal error. *"PRD §5.3 uses -32600 'bad token' for handshake failure."*
  - Note `result?: unknown` is OPTIONAL on the success branch (success omits
    `error`; error omits `result`). Builders must match exactly.
- **`extension/pi-editor-bridge.ts`** (S1–S6 DONE; S11–S14 PLANNED) —
  `getProvider()` (throws if not captured), `__deps` seam, getters, the
  `onConnection(_sock)` PLACEHOLDER (`// TODO(S8)`). S15 does NOT edit this file
  (handlers + dispatcher wiring are S11–S14 / S8). The `onConnection` JSDoc:
  *"S8 replaces the body with the JSONL line reader + the RPC dispatcher … S9
  adds the handshake gate … S11–S14 add the method handlers … S15 global error
  wrapper."*
- **`extension/jsonl-reader.ts`** (S7, DONE) — `serializeJsonLine(value)` +
  `attachJsonlLineReader(stream, onLine)`. S8 will write responses via
  `sock.write(serializeJsonLine(response))`. S15 produces the `response`.
- **`extension/tsconfig.json`** — `include: ["pi-editor-bridge.ts","protocol.ts",
  "jsonl-reader.ts","tests/**/*.ts"]`. NO `lib` field → TS includes lib.dom by
  default → `setTimeout`/`AbortController`/`Error`/`console` globals type-check
  (verified by S11 research §2; confirmed green baseline below). `strict:true`.
  S15 appends `"dispatch.ts"` to `include` (the S7 one-line precedent).

### Verified baseline (run during research)
```
tsc --noEmit -p extension/tsconfig.json   → exit 0 (green)
JITI_REG=/home/dustin/.local/lib/node_modules/@earendil-works/pi-coding-agent/node_modules/jiti/lib/jiti-register.mjs
node --import "$JITI_REG" extension/tests/protocol.test.ts   → ℹ fail 0
```

---

## §3 — wrapHandler design + the strict-mode `catch` gotcha (verified)

```ts
export type DispatchStep = (req: JsonRpcRequest) => Promise<JsonRpcResponse> | JsonRpcResponse;

export function wrapHandler(step: DispatchStep): (req: JsonRpcRequest) => Promise<JsonRpcResponse> {
	return async (req) => {
		try {
			return await step(req);   // await => rejection becomes a resolved value (handled)
		} catch (err) {
			return errorResponse(req.id, RPC_INTERNAL_ERROR, messageOf(err));
		}
	};
}
```

**GOTCHA (verified, TS strict ⇒ `useUnknownInCatchVariables`, TS 4.4+):** under
`strict: true`, `catch (err)` types `err` as **`unknown`**, NOT `Error`. So the
contract's literal `error.message` is a **compile error (TS18046)** — you CANNOT
read `.message` off `unknown`. S15 MUST narrow first:
```ts
function messageOf(err: unknown): string {
	return err instanceof Error ? err.message : String(err);
}
```
`messageOf` is S15's generalization of S11's `toRpcError` body
(`err instanceof Error ? err.message : String(err)`) — lifted to a shared,
method-agnostic helper. Tests MUST cover a non-Error throw (string/object) to
prove the fallback (`String(err)`) is load-bearing.

**Why `return await step(req)` and not `return step(req)`:** without the inner
`await`, a rejection from `step` would propagate as the returned promise's
rejection — i.e. wrapHandler's *own* returned promise would reject, defeating
the error boundary. The inner `await` makes the catch fire INSIDE wrapHandler, so
the returned promise always RESOLVES (to a success OR error envelope). This is
the single most important line.

---

## §4 — The timeout / unhandled-rejection story (the §5.5 contract)

Contract: *"ensure the 1500 ms timeout from S11 properly aborts and returns a
clean result (not an unhandled rejection)."*

- **Node 15+ default `--unhandled-rejections=throw`**: an unhandled promise
  rejection **terminates the process** with a non-zero exit code (emits
  `'unhandledRejection'` then exits). For a pi extension wired into
  `session_start`, an unhandled rejection would CRASH pi. PRD §6.7 ("Never throws
  from handlers") exists precisely to prevent this. URL:
  https://nodejs.org/api/process.html#event-unhandledrejection
- **The fix is structural, not tactical:** because wrapHandler `await`s the
  dispatch step, and `buildDispatcher` `await`s the handler, and the handler
  `await`s the provider, every rejection is *chained* and caught — there is no
  dangling unawaited promise. A rejection becomes a resolved `JsonRpcResponse`.
- **Abort path:** S11 races the provider against `setTimeout(() =>
  ac.abort(), 1500)` and clears the timer in `finally`. The provider RESOLVES
  null on abort (§1.4). So the timeout produces a clean `{ok:true,result:null}`
  outcome → `toResponse` → success envelope with `result:null`. wrapHandler
  never sees it. If a wrapped provider *did* throw on abort, S11 maps it to null
  (signal.aborted check); only a *genuine* non-abort throw becomes an error
  outcome. wrapHandler is the net for anything that still escapes — and it always
  settles, so no unhandled rejection.
- **No `Promise.race` leak in S15:** S15 itself does NOT race. The race/timeout
  lives entirely in S11's handler. S15 only `await`s. (If S11's handler were ever
  rewritten to use a raw `Promise.race` with an unawaited losing promise, THAT
  would be an S11 bug to fix — out of S15's scope. S15's contract is "I await
  whatever you give me, and I never throw.")

---

## §5 — File placement decision: NEW module `extension/dispatch.ts`

**Decision: a new standalone module `extension/dispatch.ts`** (NOT inline in
pi-editor-bridge.ts). Rationale:
- `wrapHandler` / `buildDispatcher` / `dispatch` are **PURE functions with NO
  module state, NO provider dependency, NO socket** — the cleanest standalone
  unit, exactly like `extension/jsonl-reader.ts` (S7).
- **Independently unit-testable** without loading provider-capture / server
  lifecycle (test with mock dispatch steps + mock handlers).
- **Minimal coupling:** depends ONLY on `./protocol.ts` (types that EXIST, S4
  DONE). Does NOT import from pi-editor-bridge.ts (avoids coupling to S11's
  not-yet-merged `HandlerOutcome`/`ConnectionContext` and avoids any runtime
  cycle).
- **Matches the S7 precedent** (framing module = jsonl-reader.ts; dispatch +
  error-boundary module = dispatch.ts). S8 (in pi-editor-bridge.ts) imports
  `dispatch` and calls it — a clean one-line seam.

**The tsconfig change:** append `"dispatch.ts"` to the `include` array (the
IDENTICAL one-line additive edit S7 made for `jsonl-reader.ts`; S4 made for
`protocol.ts`). `compilerOptions` UNCHANGED (the `node:*` / globals transitive
resolution under `types:[]` / no-`lib` depends on it staying put — S7 research
§3). dispatch.ts uses only protocol.ts types + globals (`Error`, `String`) →
no new runtime imports.

---

## §6 — The dispatch design (apply-the-wrapper, concretely)

"Apply this wrapper in the dispatch logic" → provide a tested `dispatch()` that
BUILDS the per-request step and WRAPS it with `wrapHandler`:

```ts
// Structural outcome — IDENTICAL shape to pi-editor-bridge.ts's HandlerOutcome<T> (S11).
// TS structural typing: a real HandlerOutcome<T> IS assignable here (no cross-module import).
export type RpcOutcome<T = unknown> =
	| { ok: true;  result: T }
	| { ok: false; error: JsonRpcError };

export type RpcHandler<C = unknown> = (params: unknown, ctx: C) => Promise<RpcOutcome> | RpcOutcome;
export type HandlerRegistry<C = unknown> = Readonly<Record<string, RpcHandler<C>>>;

export function buildDispatcher<C>(handlers: HandlerRegistry<C>, ctx: C): DispatchStep {
	return async (req) => {
		const handler = handlers[req.method];
		if (!handler) return errorResponse(req.id, RPC_METHOD_NOT_FOUND, `method not found: ${String(req.method)}`);
		const outcome = await handler(req.params ?? {}, ctx);
		return toResponse(req.id, outcome);
	};
}

/** dispatch = buildDispatcher + wrapHandler. S8: `const respond = dispatch(handlers, ctx); sock.write(serializeJsonLine(await respond(req)));` */
export function dispatch<C>(handlers: HandlerRegistry<C>, ctx: C): (req: JsonRpcRequest) => Promise<JsonRpcResponse> {
	return wrapHandler(buildDispatcher(handlers, ctx));
}
```

- **Method-not-found → -32601** (JSON-RPC spec). This is "dispatch logic" and
  prevents a `handlers[undefined]` crash. (Auth gating / handshake is S9/S10,
  applied by S8 BEFORE calling dispatch — out of S15 scope.)
- **Generic over context `<C>`:** dispatch threads `ctx` opaquely to handlers.
  No dependency on S11's `ConnectionContext` type (S8 instantiates `<C>` with the
  real `ConnectionContext`).
- **`RpcOutcome` is structural:** identical to S11's `HandlerOutcome<T>`; TS
  structural typing makes them mutually assignable. No cross-module type import
  → dispatch.ts compiles standalone TODAY (no S11 dependency).
- **CONTRAVARIANCE note for S8 (documented, not S15's problem):** the registry
  expects handlers `(params: unknown, ctx) => ...`. S11's typed handler is
  `(params: GetSuggestionsParams, ctx: ConnectionContext) => ...`. Under
  `strictFunctionTypes`, a handler expecting *specific* params is NOT directly
  assignable to a slot expecting `unknown` params. S8 adapts at the
  registry-construction site:
  ```ts
  const handlers: HandlerRegistry<ConnectionContext> = {
    getSuggestions: (p, ctx) => handleGetSuggestions(p as GetSuggestionsParams, ctx),
    // ...
  };
  ```
  Param narrowing/validation is S8's concern (the handlers may also validate).
  S15's lane is the ERROR BOUNDARY, not param validation. (PRD v1 = single
  trusted token-gated client on a Unix socket; strict param schemas are
  non-goals.)

### S8 integration sketch (for the PRP's Integration Points — S8 owns this, S15 enables it)
```ts
// in onConnection (S8), after S7's reader emits a parsed JsonRpcRequest `req`:
const respond = dispatch(handlers, connCtx);          // built once per connection
const response = await respond(req);                   // NEVER throws
sock.write(serializeJsonLine(response));               // S7's serializer
// S9 gates: if (!connCtx.handshakeDone && req.method !== "hello") skip dispatch / return -32600.
```

---

## §7 — Test plan (`extension/tests/dispatch.test.ts`, node:test + jiti)

House conventions (confirmed from `extension/tests/protocol.test.ts`,
`mode-guard.test.ts`, S11 test skeleton): `import { test } from "node:test"`;
`import assert from "node:assert/strict"`; top-level `test(...)` (NO describe);
TABS; sequential shared-state (do NOT enable concurrency); jiti register hook =
`$JITI_REG`.

**wrapHandler (the core):**
1. success passthrough — step returns `{jsonrpc,id,result:{x:1}}` → returned
   verbatim (deep-equal).
2. sync throw → `{jsonrpc,id,error:{code:-32603, message:<err.message>}}`; the
   returned promise RESOLVES (not rejects).
3. async reject (`throw new Error("boom")` inside async step) → -32603 "boom";
   resolves not rejects.
4. **reject-after-delay (timeout simulation)** — step awaits a promise that
   rejects after `setTimeout(_,20)`; assert `await wrapped(req)` RESOLVES to a
   -32603 envelope AND no `'unhandledRejection'` fires (attach a one-shot
   `process.once("unhandledRejection", fail)` for the test window; remove in
   finally). Proves the await is load-bearing.
5. non-Error throw (`throw "string err"`, `throw {custom:1}`) → message is
   `String(err)` (the `messageOf` fallback; proves the strict-mode narrow).
6. returned fn is a NEW function (HOF identity) and `typeof === "function"`.

**dispatch (apply-the-wrapper):**
7. method-not-found → `{jsonrpc,id,error:{code:-32601, message:/method not found/}}`.
8. handler returns `{ok:true,result}` → `{jsonrpc,id,result}` (enveloped).
9. handler returns `{ok:false,error:{code:-32602,message:"bad"}}` →
   `{jsonrpc,id,error:{code:-32602,message:"bad"}}` (passthrough).
10. handler THROWS → wrapHandler catches → `{jsonrpc,id,error:{code:-32603}}`.
11. handler REJECTS after delay (timeout sim) → -32603, resolves, no
    unhandledRejection.
12. ctx is threaded through to the handler unchanged (handler records ctx).

**builders / helpers:**
13. `successResponse(id,result)` → `{jsonrpc:"2.0", id, result}` (NO error key).
14. `errorResponse(id,code,msg)` → `{jsonrpc:"2.0", id, error:{code,message}}`
    (NO result key).
15. `toResponse(id,{ok:true,result})` and `toResponse(id,{ok:false,error})` →
    correct branches.
16. `messageOf(new Error("x"))==="x"`; `messageOf("str")==="str"`;
    `messageOf(42)==="42"`; `messageOf(null)==="null"`.
17. error-code constants equal the spec values (-32700/-32600/-32601/-32602/-32603).

**Regression:** all pre-existing suites (`provider-capture`, `mode-guard`,
`protocol`, `bridge-lifecycle`, `bridge-lifecycle-wiring`, `jsonl-reader`, and
the S11/S12 handler suites once merged) still `ℹ fail 0` — S15 is purely
additive (1 new module + 1 new test + 1-line `include` edit).

---

## §8 — Scope guard (what S15 does NOT do)

- Does NOT edit `pi-editor-bridge.ts` (handlers + onConnection wiring = S11–S14 /
  S8). The `// TODO(S8)` placeholder stays byte-for-byte intact.
- Does NOT edit `protocol.ts` (S4 contract; type-only consumer).
- Does NOT implement handlers (S11–S14), handshake (S9/S10), the onConnection
  reader/parse/write wiring (S8), or `commandsChanged` broadcast (S17).
- Does NOT do param validation/schema enforcement (S8 / handlers' job).
- Does NOT introduce a `Promise.race` or its own timeout — the 1500 ms timeout
  lives in S11's handler; S15 only `await`s.
- Does NOT add npm deps (Node builtins only — PRD §6.7).

---

## §9 — Citations (URLs)

- JSON-RPC 2.0 spec — error object & codes:
  https://www.jsonrpc.org/specification#error_object (codes -32700/-32600/-32601/
  -32602/-32603; reserved -32000..-32099; `data` OPTIONAL) and
  https://www.jsonrpc.org/specification#response_object (id'd Request → exactly
  one Response success-OR-error; Notification → none).
- Node unhandled-rejection behavior (kills process since Node 15):
  https://nodejs.org/api/process.html#event-unhandledrejection
- TS `useUnknownInCatchVariables` (strict ⇒ `catch` binds `unknown`):
  https://www.typescriptlang.org/tsconfig#useUnknownInCatchVariables
- AbortController (global; abort idempotent):
  https://developer.mozilla.org/en-US/docs/Web/API/AbortController/abort
