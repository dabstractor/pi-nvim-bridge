name: "P1.M2.T6.S11 — getSuggestions handler (AbortController + per-request timeout + supersession)"
description: "pi-editor-bridge extension (TS). Register the `getSuggestions` JSON-RPC handler as a dependency-injected factory (`makeGetSuggestionsHandler`) that delegates to pi's live AutocompleteProvider: create a fresh AbortController per call, supersede any in-flight call (abort the previous controller so fd gets SIGKILL'd), arm a per-request timeout (1500 ms, injectable for tests) that aborts runaway fd, thread `signal`+`force` through to the provider, and narrow params (throw `BridgeRpcError(-32602)` on malformed input). The built-in provider NEVER rejects on abort — it resolves to null — so supersession frees fd resources while every request still gets its own RPC response. No change to connection.ts (its `-32603` safety net + BridgeRpcError handling already cover handler throws) or protocol.ts (GetSuggestionsParams/Result already defined). New `get-suggestions-handler.test.ts` (UNIT/DISPATCH/REAL three layers). node:test + jiti (NOT vitest)."

---

## Goal

**Feature Goal**: Land the first *completion-engine* RPC handler. When an
authenticated Neovim client sends a `getSuggestions` request, the bridge
delegates to pi's **live** `AutocompleteProvider` (captured in S2) exactly as
pi's own TUI editor does — passing a fresh `AbortSignal` and the `force` flag —
so the external editor gets byte-for-byte-identical `/command`, `skill:`,
template, argument, `@file`, and path completions. Because the bridge serves a
socket (one provider shared across open/close cycles, and the caller
fire-and-forgets each request line), the handler MUST (a) **supersede** any
in-flight call by aborting the previous `AbortController` (so a slow `fd` gets
`SIGKILL`'d instead of churning), and (b) enforce a **per-request timeout**
(1500 ms) that aborts a runaway `fd`, since pi's provider contains no timeout of
its own and expects the *caller* to abort via the signal.

**Deliverable**:
1. `extension/pi-editor-bridge.ts` — ADD:
   - `GET_SUGGESTIONS_TIMEOUT_MS = 1500` named constant (PRD §5.5/§6.5).
   - `makeGetSuggestionsHandler(deps: { getProvider; timeoutMs? })` factory
     (mirrors the `makeHelloHandler` deps-injection pattern from S9) returning a
     `MethodHandler`. Closure holds a single `pendingAbort` supersession slot
     and the resolved `timeoutMs`.
   - A private `narrowGetSuggestionsParams(params)` helper that validates
     `lines:string[]`, `cursorLine`/`cursorCol` (non-negative integers),
     `force?` (boolean) and throws `BridgeRpcError(-32602, …)` on any
     malformed shape (matches S9's precedent of throwing `BridgeRpcError` for
     handler-level input validation; `-32602` is the reserved "invalid params").
   - One new `registerBridgeHandler("getSuggestions", makeGetSuggestionsHandler({ getProvider }))`
     line in the `session_start` handler, immediately AFTER the existing
     `registerBridgeHandler("hello", …)` call.
   - Extend the existing `import type { HelloParams, HelloResult }` from
     `./protocol.ts` to also import `GetSuggestionsParams, GetSuggestionsResult`.
2. `extension/tests/get-suggestions-handler.test.ts` (NEW) — three layers:
   UNIT (factory directly with a stub provider, incl. signal/force threading,
   supersession, timeout, param validation, provider-not-captured), DISPATCH
   (registerBridgeHandler + `fakeSocket` + `handleLine`, `{ handshakeComplete: true }`
   for the gated happy path), and ONE REAL Unix-socket integration test
   (hello → getSuggestions → result over a real socket).

**Success Definition**: With the bridge running and a client authenticated via
`hello`, a `getSuggestions` request returns exactly the items the live provider
produces; a second `getSuggestions` sent while the first is in-flight aborts the
first's signal (the first still resolves and gets its own response — the client
ignores stale ids per PRD §5.5); a request whose provider call exceeds 1500 ms
is aborted by the timer and resolves to the provider's abort result; malformed
params yield `-32602`. `tsc --noEmit` is clean; the new suite passes; **all 9
existing extension suites stay green** (S2–S10); `connection.ts` and
`protocol.ts` are UNCHANGED.

---

## User Persona

**Target User**: The `pi-editor.nvim` Neovim plugin (P2.M5) — the bridge's only
client. (Indirectly: the human editing a pi prompt in their `$EDITOR`.)

**Use Case**: As the user types in the pi prompt buffer, the plugin debounces
each change and sends a `getSuggestions` request with the current buffer lines +
cursor (0-indexed line, UTF-16 col per PRD §8). Each keystroke supersedes the
prior request (new `id`); the plugin renders only the latest response. Tab with
no menu sends `getSuggestions` with `force:true` (mirrors pi's Tab /
`shouldTriggerFileCompletion` path).

**Pain Points Addressed**: The external editor gets pi's *actual* completion
results (not a reimplementation), with `fd`-driven `@file` fuzzy search, while
the bridge ensures a fast typist doesn't pile up overlapping `fd` processes
(supersession SIGKILLs the stale one) and a hung `fd` can't hang the editor
(per-request timeout). The provider resolves — never rejects — on abort, so
supersession is safe: each request still answers.

---

## Why

- **First engine-delegating handler**: S9 (hello) only authenticated; S10 only
  gated. S11 is the first handler that actually *drives pi's completion
  engine*. S12 (applyCompletion) / S13 (shouldTriggerFileCompletion) follow the
  exact same factory+delegate shape S11 establishes.
- **Resource safety (the AbortController point)**: pi's `@file` path spawns an
  `fd` child per call. Without supersession, a fast typist opens many concurrent
  `fd` processes; without a timeout, a hung `fd` (huge repo, slow disk) hangs
  the editor indefinitely (the provider has NO internal timeout — verified).
  The bridge owns both guards because the provider delegates that responsibility
  to the caller.
- **Byte-identical behavior**: by handing the SAME `{signal, force}` to the live
  provider that pi's TUI editor does, insertion/triggers match the TUI exactly —
  the Neovim side never reimplements `@`/path/`/command` logic (PRD §4 step 5).
- **Mirrors the client's model (P2.M5)**: the Neovim client does id-correlation
  supersession (S26: "drop responses whose id is not the current pending id").
  S11 is the server-side counterpart: abort the stale provider call so the stale
  *response* (when it arrives) carries the cheap, aborted (null) result, not a
  full expensive `fd` result for a prefix the user already moved past.

---

## What

### User-visible behavior (wire)

| Client sends (post-`hello`) | Server action & response |
|---|---|
| `getSuggestions {lines:[...], cursorLine, cursorCol}` (valid) | Delegate to `liveProvider.getSuggestions(lines, cursorLine, cursorCol, {signal:<fresh>, force:false})`. Reply `{jsonrpc,id,result: <AutocompleteSuggestions\|null>}`. |
| `getSuggestions {..., force:true}` | Same, but `force:true` is threaded (Tab/force-file path). |
| 2nd `getSuggestions` arrives while 1st in-flight | **Abort the 1st's AbortController** (→ `fd` SIGKILL → 1st resolves to its abort result, usually `null`). 1st STILL gets its own response (`{id1,result}`); 2nd gets `{id2,result}`. Client ignores `id1`. |
| `getSuggestions` whose provider call > 1500 ms | Timer aborts the controller (same path as supersession) → call resolves to the provider's abort result → response sent. Never hangs. |
| malformed params (lines not string[], cursorLine not a non-negative integer, force not boolean) | `BridgeRpcError(-32602, "invalid params: …")` → `handleLine` maps to `{"id","error":{"code":-32602,"message":"invalid params: …"}}`. |
| `getSuggestions` before `hello` | (Unchanged — S10 gate) `-32600 "handshake required: send hello first"`. |
| `getSuggestions` when provider not yet captured | `getProvider()` throws plain `Error` → `handleLine` `-32603` safety net. (S15 may later refine to a specific code; S11 leaves the safety net — it keeps pi safe.) |
| handler/await throws any other Error | `handleLine` `-32603` safety net (unchanged). |

### Success Criteria

- [ ] `getSuggestions` (valid, post-handshake) returns the live provider's
      result verbatim (`{jsonrpc,id,result:{items,prefix}}` or `{result:null}`).
- [ ] `force` is threaded exactly as a boolean to the provider
      (`force:true` when sent; `false` when omitted/`false`).
- [ ] The provider receives a **fresh, non-aborted `AbortSignal`** on each call.
- [ ] Supersession: a 2nd in-flight request aborts the 1st's signal (assert
      `firstSignal.aborted === true` after the 2nd is dispatched); both requests
      still resolve and both get responses.
- [ ] Timeout: a provider that resolves only on abort resolves to its abort
      result after `timeoutMs` (tested with a short injected `timeoutMs`).
- [ ] The timeout is **cleared** in `finally` (no leaked timer past completion).
- [ ] Malformed params ⇒ exactly one `-32602 "invalid params: …"` response with
      the request id.
- [ ] Pre-handshake `getSuggestions` ⇒ still `-32600` (S10 gate, unchanged).
- [ ] Provider-not-captured ⇒ `-32603` (safety net; S11 does not wrap it).
- [ ] `tsc --noEmit -p extension/tsconfig.json` ⇒ exit 0, no output.
- [ ] New `get-suggestions-handler.test.ts` passes (`ℹ fail 0`); every other
      `extension/tests/*.test.ts` ⇒ `ℹ fail 0` (no S2–S10 regressions).
- [ ] `extension/connection.ts` and `extension/protocol.ts` are UNCHANGED
      (diff-clean — verify with `git diff --stat extension/connection.ts extension/protocol.ts` ⇒ empty).

---

## All Needed Context

### Context Completeness Check

_"If someone knew nothing about this codebase, would they have everything needed
to implement this successfully?"_ — Yes. This PRP gives the exact factory shape
(pinned to PRD §6.5's skeleton), the exact closure-scoped supersession slot, the
exact param-narrowing rules + `-32602` codes, the exact registration site
(after the existing `hello` `registerBridgeHandler`), the verified fact that the
provider *resolves* on abort (so supersession needs no response-suppression), the
exact verbatim test helpers to copy (`fakeSocket`/`parseResponses`/`readFirstResponse`),
the exact three-layer test shape proven by the 3 sibling suites, and the
verified test commands. No guessing.

### Documentation & References

```yaml
# MUST READ — the governing spec
- url: PRD §6.5 (Request handling skeleton) + §5.5 (Timing & cancellation) + §5.4 (methods table)
  why: "§6.5 is the AUTHORITATIVE getSuggestions skeleton (AbortController + pendingAbort?.abort() supersession + setTimeout(1500) + finally clearTimeout). §5.5 mandates the 1500 ms server timeout (abort runaway fd) and the client-side id-supersession contract (client ignores stale ids — which is WHY the server can safely send each request its own response after aborting). §5.4 defines getSuggestions params/result."
  critical: "PRD §6.5 is a near-verbatim implementation spec. The ONLY deviations this PRP makes are (1) encapsulating pendingAbort + timeoutMs inside a deps-injected FACTORY (matching S9's makeHelloHandler) instead of module-level handlers, and (2) adding params narrowing with BridgeRpcError(-32602). Both are consistent with established S9 pattern; neither changes wire behavior."

# MUST READ — the file this task edits (READ BEFORE EDITING)
- file: extension/pi-editor-bridge.ts
  why: "The home of makeHelloHandler (the factory pattern to mirror), getProvider() (the deps.getProvider the factory receives), BRIDGE_VERSION/startBridge/stopBridge (lifecycle context), and the session_start handler where registration is ADDED. Its makeHelloHandler JSDoc + BridgeRpcError usage IS the precedent for S11's param validation throwing BridgeRpcError(-32602)."
  pattern: "makeHelloHandler(deps:{getToken,getCwd,getFdAvailable,version}) => MethodHandler — a PURE factory, deps are getter closures so tests stub them. The factory returns (params, state) => result|throws. S11 mirrors this: makeGetSuggestionsHandler(deps:{getProvider,timeoutMs?}) => async (params,state) => result."
  gotcha: "Imports: AutocompleteProvider ALREADY imported from @earendil-works/pi-tui. BridgeRpcError/MethodHandler/ConnectionState ALREADY imported from ./connection.ts. ADD GetSuggestionsParams/GetSuggestionsResult to the existing `import type { HelloParams, HelloResult } from \"./protocol.ts\"`. Register the handler AFTER the existing `registerBridgeHandler(\"hello\", …)` (so provider capture + token both exist)."

- file: extension/connection.ts
  why: "CONFIRMS S11 needs NO change here. MethodHandler is already `(params,state)=>Promise<unknown>|unknown` (async OK). handleLine's REQUEST branch already does `const result = await handler(params,state); sendResponse(sock,reqId,result)` and already maps a thrown BridgeRpcError → `{id,error:{code,message}}` and any other throw → `-32603`. The S10 handshake gate already blocks getSuggestions pre-hello."
  pattern: "handleLine is fire-and-forget per line (`void handleLine(...)`), so two concurrent getSuggestions requests run two concurrent handleLine invocations — each gets its OWN response. This is the structural reason supersession does NOT need to suppress the stale response: aborting the prior controller makes the prior provider call RESOLVE (cheap), and its handleLine then sends {id_prior, result:null} naturally."
  gotcha: "DO NOT EDIT connection.ts. The -32603 safety net + BridgeRpcError handling already cover every throw path S11 can produce. registerBridgeHandler is MODULE-LEVEL (shared across connections) — so pendingAbort closure-scoped supersession is effectively global (one getSuggestions handler instance per session). That's intended (PRD §5.3 'one robust connection' bar; two editors sharing one provider/fd pool aborting each other's stale search is acceptable)."

- file: extension/protocol.ts
  why: "CONSUME the already-defined GetSuggestionsParams {lines:string[]; cursorLine:number; cursorCol:number; force?:boolean} and GetSuggestionsResult = AutocompleteSuggestions | null (§C). CONFIRMS cursorLine is 0-indexed, cursorCol is a 0-indexed UTF-16 offset (conversion lives in the Lua coords module P2.M6 — the bridge passes numbers through untouched)."
  gotcha: "protocol.ts is TYPES-ONLY (zero runtime exports). S11 adds NO type to protocol.ts. Re-export of AutocompleteItem/AutocompleteSuggestions from pi-tui already exists — the wire shape stays byte-identical to pi's engine."

- file: extension/tests/handshake-gate.test.ts
  why: "the NEWEST, cleanest sibling suite — model the new test file's imports block + helpers + REAL-socket shape on it. It shows: combined `{ EventEmitter, once }`, explicit .ts import extensions, the registerBridgeHandler+__resetHandlersForTest-in-finally hygiene, and the hello-first REAL-socket template."
  pattern: "Imports: from ../connection.ts (handleLine, onConnection, registerBridgeHandler, __resetHandlersForTest, type ConnectionState) + from ../pi-editor-bridge.ts (makeHelloHandler, BRIDGE_VERSION) + from ../jsonl-reader.ts (attachJsonlLineReader, serializeJsonLine). COPY fakeSocket()/parseResponses()/readFirstResponse() VERBATIM (they are LOCAL per-file, not exported — connection.test.ts, hello-handler.test.ts, handshake-gate.test.ts each re-declare them identically)."
  gotcha: "readFirstResponse(client) MUST be called BEFORE client.write(...) (attach the one-shot reader first, then write, then await). Repeat per response in the REAL test. Dispatch tests pass `{ handshakeComplete: true }` so the S10 gate lets getSuggestions through."

# Prior plan context (READ for rationale; do NOT copy code blindly)
- docfile: plan/001_c56962b4fa17/P1M2T6S11/research/notes.md
  section: "§1.2 (provider RESOLVES on abort — the key fact), §2 (PRD §6.5 skeleton), §3 (closure-scoped pendingAbort decision), §4 (S11 vs S15 boundary)"
  why: "the WHY behind every non-obvious choice — esp. WHY supersession does not suppress the stale response (RPC correctness + provider resolves on abort), WHY timeoutMs is deps-injected (testability without a module seam), and WHY param validation throws -32602 in S11 (S9 precedent) but provider-not-captured is left to the -32603 net (S15 owns domain-error wrapping)."
- docfile: plan/001_c56962b4fa17/P1M2T6S11/research/pi-autocomplete-source.md
  section: "§1.1 (signal wiring — SIGKILL on abort), §1.2 (resolve-not-reject), §1.3 (editor.ts supersession for reference)"
  why: "verifies, against pi source with line numbers, that aborting the AbortController SIGKILLs fd and resolves to null — the mechanism that makes the bridge's supersession+timeout both cheap and correct."
```

### Current Codebase tree

```bash
extension/
├── pi-editor-bridge.ts     # S1/S3/S5/S6/S9: lifecycle, captureProvider/getProvider, start/stopBridge, makeHelloHandler, getToken/getCwd/getFdAvailable/BRIDGE_VERSION  ← EDIT (add makeGetSuggestionsHandler + GET_SUGGESTIONS_TIMEOUT_MS + narrowGetSuggestionsParams + 1 registration line)
├── protocol.ts             # S4: ALL wire types (TYPES-ONLY) — incl. GetSuggestionsParams/GetSuggestionsResult (§C, already defined)  ← UNCHANGED (consume only)
├── jsonl-reader.ts         # S7: attachJsonlLineReader, serializeJsonLine
├── connection.ts           # S8/S9/S10: ConnectionState, registerBridgeHandler, send*, BridgeRpcError, handleLine (gate), onConnection  ← UNCHANGED
├── tsconfig.json
└── tests/
    ├── provider-capture.test.ts        # S2
    ├── mode-guard.test.ts              # S3
    ├── protocol.test.ts                # S4
    ├── bridge-lifecycle.test.ts        # S5/S6
    ├── bridge-lifecycle-wiring.test.ts # S6
    ├── jsonl-reader.test.ts            # S7
    ├── connection.test.ts              # S8/S9/S10 (16 tests)
    ├── hello-handler.test.ts           # S9  (factory-pattern precedent)
    └── handshake-gate.test.ts          # S10 (cleanest imports/REAL template)
```

### Desired Codebase tree (files this task touches)

```bash
extension/
├── pi-editor-bridge.ts                          # MODIFY: + factory + const + narrowing helper + 1 registration line + import add
└── tests/
    └── get-suggestions-handler.test.ts          # CREATE: UNIT (factory) + DISPATCH (gate-open) + ONE REAL (hello→getSuggestions)
```

### Known Gotchas of our codebase & Library Quirks

```ts
// CRITICAL: pi's provider RESOLVES on abort, it does NOT reject. So when S11
//   supersedes (pendingAbort?.abort()), the prior in-flight getSuggestions call
//   resolves to its abort result (usually null) shortly — fd is SIGKILL'd. The
//   prior handleLine then sends {id_prior, result:null} NATURALLY. S11 must NOT
//   try to suppress that response: handleLine is fire-and-forget per line and
//   ALWAYS sends one response per REQUEST. The CLIENT ignores stale ids (PRD §5.5).
//   (research §1.2 — verified against autocomplete.ts:118-220.)

// CRITICAL: supersession slot is CLOSURE-SCOPED inside the factory, NOT a module-
//   level `handlers` object like PRD §6.5's sketch. Reason: makeGetSuggestionsHandler
//   is called ONCE per session (registered once) → one closure → one pendingAbort
//   shared across all calls = correct global supersession. registerBridgeHandler's
//   registry is module-level (shared across connections), so the handler instance
//   (and its closure) is shared too. This matches S9's makeHelloHandler philosophy.
//   (research §3.)

// CRITICAL: NO timeout exists anywhere in pi's provider or interactive-mode
//   (verified). The provider EXPECTS the caller to abort via signal. S11's
//   setTimeout(timeoutMs, () => ac.abort()) is therefore MANDATORY, not optional —
//   without it a hung fd hangs the editor. clearTimeout in finally prevents a
//   leaked timer past normal completion. (PRD §5.5; research §1.1.)

// CRITICAL: thread `force` as a strict boolean. The provider gates the `/command`
//   branch on `!options.force` and `extractPathPrefix(force)` for the Tab path.
//   Pass `force: p.force === true` (never undefined) so the provider's branching
//   is identical to pi's TUI (`!!force` per PRD §6.5). (research §1.3.)

// CONVENTION: throw BridgeRpcError(-32602, "invalid params: …") for malformed
//   params. -32602 is the reserved JSON-RPC "invalid params" code (protocol.ts §A).
//   This matches S9's precedent (hello throws BridgeRpcError(-32600) for bad token).
//   handleLine maps a thrown BridgeRpcError → {id,error:{code,message}}.
//   DO NOT wrap provider-not-captured / provider-runtime-throws here — that is S15's
//   lane ("wrap ALL handlers' domain errors into proper codes"). For S11 let those
//   fall to handleLine's -32603 safety net (keeps pi safe; S15 refines the codes).
//   (research §4.)

// CONVENTION: node:test + jiti (NOT vitest). TAB indentation. Test seams named
//   __xForTest. registerBridgeHandler + __resetHandlersForTest() in EVERY finally
//   (node:test runs sequentially; module registry persists across tests). Model the
//   new test file's imports + helpers on handshake-gate.test.ts (cleanest/current).
//   COPY fakeSocket()/parseResponses()/readFirstResponse() VERBATIM (they are LOCAL
//   per-file — NOT exported from connection.test.ts). (research §5.)

// GOTCHA: setTimeout/clearTimeout ARE typed globals in this project (used in
//   bridge-lifecycle-wiring.test.ts:109 and hello-handler.test.ts:349, both
//   type-check clean under tsc despite tsconfig `types:[]`). A bare
//   `const timer = setTimeout(...)` + `clearTimeout(timer)` works. If paranoid,
//   type as `ReturnType<typeof setTimeout>` (the editor.ts proven idiom).

// GOTCHA: to test the timeout deterministically, INJECT a short timeoutMs via deps
//   (makeGetSuggestionsHandler({ getProvider, timeoutMs: 30 })) — do NOT use a real
//   1500 ms wait or fake-timer machinery. Production registration passes only
//   { getProvider } and gets the GET_SUGGESTIONS_TIMEOUT_MS default.
```

---

## Implementation Blueprint

### Data models and structure

**No new wire types. No new runtime exports beyond the factory + const.** S11
consumes:
- `GetSuggestionsParams { lines: string[]; cursorLine: number; cursorCol: number; force?: boolean }`
  and `GetSuggestionsResult = AutocompleteSuggestions | null` (protocol.ts §C,
  already defined).
- `MethodHandler` (connection.ts) — `(params: unknown, state: ConnectionState) =>
  Promise<unknown> | unknown`; S11 returns an async handler.
- `BridgeRpcError` (connection.ts) — thrown for `-32602` param errors.
- `getProvider()` (pi-editor-bridge.ts, S2) — the dep closure the factory
  receives; throws a plain `Error` when not yet captured (→ `-32603`).
- `AutocompleteProvider` (pi-tui) — the live chain's `getSuggestions` signature
  is `{ signal: AbortSignal; force?: boolean }` (signal ALWAYS required;
  research §1).

S11 adds two module-level exports to `pi-editor-bridge.ts`:
- `export const GET_SUGGESTIONS_TIMEOUT_MS = 1500;`
- `export function makeGetSuggestionsHandler(deps: { getProvider: () => AutocompleteProvider; timeoutMs?: number }): MethodHandler;`
and one non-exported helper `narrowGetSuggestionsParams(params: unknown): GetSuggestionsParams`.

### Implementation Tasks (ordered by dependencies)

```yaml
Task 1: MODIFY extension/pi-editor-bridge.ts — add the factory, const, narrowing helper, registration, and import
  - ADD import: extend `import type { HelloParams, HelloResult } from "./protocol.ts"`
    → `import type { HelloParams, HelloResult, GetSuggestionsParams, GetSuggestionsResult } from "./protocol.ts";`
  - ADD: `export const GET_SUGGESTIONS_TIMEOUT_MS = 1500;` (PRD §5.5/§6.5) near BRIDGE_VERSION.
  - ADD (non-exported) `narrowGetSuggestionsParams(params: unknown): GetSuggestionsParams`
    that validates shape and throws `BridgeRpcError(-32602, "invalid params: …")`
    (code below). Rules: params is a non-null object; `lines` is an Array whose
    every element is `typeof === "string"`; `cursorLine`/`cursorCol` are
    `Number.isInteger(x) && x >= 0`; `force` is `undefined` OR `typeof === "boolean"`.
  - ADD: `export function makeGetSuggestionsHandler(deps: { getProvider: () =>
    AutocompleteProvider; timeoutMs?: number }): MethodHandler` (code below).
    Closure holds `let pendingAbort: AbortController | undefined;` and
    `const timeoutMs = deps.timeoutMs ?? GET_SUGGESTIONS_TIMEOUT_MS;`. Body:
    narrow → getProvider (throws if uncaptured) → new AbortController →
    pendingAbort?.abort() (supersede) → pendingAbort = ac → setTimeout(timeoutMs,
    () => ac.abort()) → try { return await provider.getSuggestions(...) with
    {signal:ac.signal, force: p.force === true} } finally { clearTimeout(timer) }.
  - ADD registration: in the `session_start` handler, IMMEDIATELY AFTER the
    existing `registerBridgeHandler("hello", makeHelloHandler({...}))` call, add
    `registerBridgeHandler("getSuggestions", makeGetSuggestionsHandler({ getProvider }));`.
  - UPDATE the session_start STATUS/inline comment to note S11 is DONE (keep the
    repo convention of accurate cross-task roadmap comments — see how S8/S9/S10
    comments cross-reference task status).
  - DO NOT touch: captureProvider/getProvider bodies, startBridge/stopBridge,
    makeHelloHandler, resolveFdAvailable, the session_shutdown handler, or
    anything in connection.ts / protocol.ts.

Task 2: CREATE extension/tests/get-suggestions-handler.test.ts — UNIT/DISPATCH/REAL
  - IMPORTS: model on handshake-gate.test.ts verbatim, PLUS from ../pi-editor-bridge.ts:
    `makeGetSuggestionsHandler, makeHelloHandler, BRIDGE_VERSION, GET_SUGGESTIONS_TIMEOUT_MS`,
    and `GetSuggestionsParams/GetSuggestionsResult` TYPE imports from ../protocol.ts
    if needed for stub typing. Need `BridgeRpcError` from ../connection.ts too.
  - COPY fakeSocket()/parseResponses()/readFirstResponse() VERBATIM from
    handshake-gate.test.ts (they are local helpers, not exported).
  - MODULE-LEVEL: a `makeStubProvider({ ...overrides })` helper returning a plain
    object satisfying the `AutocompleteProvider` shape (getSuggestions + applyCompletion
    + shouldTriggerFileCompletion). The default getSuggestions returns null and
    records the last `{lines, cursorLine, cursorCol, signal, force}` it received
    onto a captured `lastCall` object. A `pendingOnAbort` variant returns a
    Promise that resolves ONLY when `signal` aborts (to deterministically test
    supersession + timeout).
  - UNIT tests (call the factory directly; fresh `ConnectionState` per test;
    short `timeoutMs: 30` where timing matters):
    1. HAPPY PATH: stub returns `{items:[{value:"/model",label:"model"}],prefix:"/m"}`
       → handler returns it verbatim.
    2. NULL: stub returns null → handler returns null.
    3. FORCE THREADING: stub records opts.force; call with `force:true` → recorded
       `=== true`; call with force omitted → recorded `=== false`; call with
       `force:false` → recorded `=== false`.
    4. SIGNAL THREADING (fresh, non-aborted): stub records opts.signal; after the
       call, `lastCall.signal.aborted === false` and the signal is an AbortSignal.
    5. SUPERSESSION: use the `pendingOnAbort` stub. Fire handler twice WITHOUT
       awaiting (const p1 = handler(...); const p2 = handler(...)). Immediately
       after p2 is invoked, assert `lastCall1.signal.aborted === true` (the 1st
       signal was aborted by the 2nd's pendingAbort?.abort()). Then await both;
       p1 resolves to null (its signal aborted → stub resolved null); p2 resolves
       to null via its own timeout (timeoutMs:30). (Verify both promises settle,
       never reject.)
    6. TIMEOUT: `pendingOnAbort` stub + `timeoutMs: 30`. `await handler({...},state)`
       → resolves to null (stub resolved on the timer-driven abort). Assert ~no
       manual abort was triggered (the timer did it). Also assert no unhandled
       rejection.
    7. TIMEOUT CLEARED: after a normal (stub-resolves-immediately) call completes,
       the timer is cleared — assert indirectly by completing many calls in a loop
       without leak (or assert the handler resolves promptly and the process exits
       cleanly; a leaked 1500ms timer would keep node:test alive — use the short
       timeoutMs so this is observable).
    8. PARAM VALIDATION: invalid params throw `BridgeRpcError` with code -32602:
       lines not an array; lines array with a non-string; cursorLine a float /
       negative / non-number; cursorCol same; force a string (non-boolean). Assert
       `err instanceof BridgeRpcError && err.code === -32602`.
    9. PROVIDER NOT CAPTURED: `getProvider: () => { throw new Error("not captured"); }`
       → handler throws that plain Error (NOT a BridgeRpcError). (Confirms S11
       leaves this to the -32603 safety net; S15 refines.)
  - DISPATCH tests (registerBridgeHandler + fakeSocket + handleLine; pass
    `{ handshakeComplete: true }` so the S10 gate opens; `__resetHandlersForTest`
    in finally):
    10. VALID → SUCCESS: register getSuggestions handler (stub returns
        {items,prefix}); `await handleLine(sock, {handshakeComplete:true},
        JSON.stringify({jsonrpc:"2.0",id:"g1",method:"getSuggestions",params:
        {lines:["/m"],cursorLine:0,cursorCol:2}}))`; assert parseResponses(writes)
        === [{jsonrpc:"2.0",id:"g1",result:{items:[...],prefix:"/m"}}].
    11. INVALID PARAMS → -32602: params `{lines:"notarray",cursorLine:0,cursorCol:0}`
        → exactly one response, code -32602, message starts "invalid params:".
    12. PRE-HANDSHAKE → -32600 (regression, gate still wins): same valid request
        but `{handshakeComplete:false}` → `-32600 "handshake required: send hello
        first"` AND the provider's getSuggestions is NOT called (stub records
        nothing). Locks that the gate fires before the handler.
  - REAL integration (ONE real Unix-socket pair; register hello + getSuggestions):
    13. Register `hello` (makeHelloHandler, fixed TOKEN) AND `getSuggestions`
        (makeGetSuggestionsHandler({ getProvider: () => stubProvider })) where
        stubProvider.getSuggestions returns `{items:[{value:"/model",label:"model",
        description:"..."}],prefix:"/m"}` when `lines[cursorLine].startsWith("/m")`.
        createServer((c)=>onConnection(c)) → listen(unique tmp sockpath) → connect →
        (1) hello (correct token) ⇒ HelloResult; (2) getSuggestions {lines:["/m"],
        cursorLine:0,cursorCol:2} ⇒ {id,result:{items:[...],prefix:"/m"}}; (3)
        getSuggestions {lines:["zzz"],cursorLine:0,cursorCol:3} ⇒ {id,result:null}.
        Use readFirstResponse(client) BEFORE each client.write(serializeJsonLine(...)).
        __resetHandlersForTest(); server.close(); in finally.

Task 3: VALIDATE (see Validation Loop) — tsc clean; new + all existing suites green;
  connection.ts & protocol.ts diff-clean.
```

### Implementation Patterns & Key Details

```ts
// === Task 1: extension/pi-editor-bridge.ts — the factory + const + narrowing + registration ===

// (1a) extend the existing protocol import (one line edit):
import type {
	HelloParams,
	HelloResult,
	GetSuggestionsParams,
	GetSuggestionsResult,
} from "./protocol.ts";

// (1b) the timeout constant (near BRIDGE_VERSION):
/** Per-`getSuggestions` server-side abort timeout (PRD §5.5). Aborts a runaway
 *  `fd` since pi's provider has NO internal timeout (research §1.1) — the caller
 *  owns cancellation. Injectable for tests via {@link makeGetSuggestionsHandler}'s
 *  `timeoutMs` dep. */
export const GET_SUGGESTIONS_TIMEOUT_MS = 1500;

// (1c) the params narrowing helper (non-exported):
function narrowGetSuggestionsParams(params: unknown): GetSuggestionsParams {
	const p = params as Partial<GetSuggestionsParams> | null;
	if (!p || typeof p !== "object") {
		throw new BridgeRpcError(-32602, "invalid params: expected an object");
	}
	const { lines, cursorLine, cursorCol, force } = p;
	if (!Array.isArray(lines) || !lines.every((l) => typeof l === "string")) {
		throw new BridgeRpcError(-32602, "invalid params: lines must be string[]");
	}
	if (typeof cursorLine !== "number" || !Number.isInteger(cursorLine) || cursorLine < 0) {
		throw new BridgeRpcError(-32602, "invalid params: cursorLine must be a non-negative integer");
	}
	if (typeof cursorCol !== "number" || !Number.isInteger(cursorCol) || cursorCol < 0) {
		throw new BridgeRpcError(-32602, "invalid params: cursorCol must be a non-negative integer");
	}
	if (force !== undefined && typeof force !== "boolean") {
		throw new BridgeRpcError(-32602, "invalid params: force must be boolean");
	}
	return { lines, cursorLine, cursorCol, force };
}

// (1d) the factory (mirrors makeHelloHandler's deps-injection shape):
/**
 * Build the `getSuggestions` JSON-RPC handler (PRD §5.4 / §6.5). PURE factory —
 * deps injected so unit tests stub the provider + timeout. Delegates to pi's LIVE
 * provider, threading a FRESH AbortSignal + the boolean `force`.
 *
 * SUPERSESSION: a single closure-scoped `pendingAbort` slot is shared across all
 * calls of this (one-per-session) handler instance. Each call aborts the previous
 * in-flight controller (so `fd` is SIGKILL'd) before arming its own. Because pi's
 * provider RESOLVES (never rejects) on abort, the superseded call shortly resolves
 * to its abort result and its `handleLine` sends `{id_prior,result}` NATURALLY —
 * the client ignores stale ids (PRD §5.5). S11 does NOT suppress that response.
 *
 * TIMEOUT: `setTimeout(timeoutMs, () => ac.abort())` aborts a runaway `fd` (pi has
 * no internal timeout — research §1.1). `clearTimeout` in `finally`.
 *
 * ERRORS: malformed params throw `BridgeRpcError(-32602)` (S9 precedent;
 * -32602 = reserved "invalid params"). Provider-not-captured (`deps.getProvider()`
 * throws) and any provider RUNTIME throw propagate to `handleLine`'s `-32603`
 * safety net — S15 later wraps those into proper codes. S11 keeps them flowing.
 */
export function makeGetSuggestionsHandler(deps: {
	getProvider: () => AutocompleteProvider;
	timeoutMs?: number;
}): MethodHandler {
	const timeoutMs = deps.timeoutMs ?? GET_SUGGESTIONS_TIMEOUT_MS;
	let pendingAbort: AbortController | undefined;
	return async (_params: unknown, _state: ConnectionState): Promise<GetSuggestionsResult> => {
		const params = narrowGetSuggestionsParams(_params);
		const provider = deps.getProvider(); // throws plain Error if not captured → -32603 (S15 refines)
		const ac = new AbortController();
		pendingAbort?.abort(); // supersede any in-flight call (SIGKILLs its fd)
		pendingAbort = ac;
		const timer: ReturnType<typeof setTimeout> = setTimeout(() => {
			if (!ac.signal.aborted) ac.abort();
		}, timeoutMs);
		try {
			return await provider.getSuggestions(params.lines, params.cursorLine, params.cursorCol, {
				signal: ac.signal,
				force: params.force === true,
			});
		} finally {
			clearTimeout(timer);
		}
	};
}

// (1e) registration in session_start — add ONE line after the existing hello registration:
		registerBridgeHandler(
			"hello",
			makeHelloHandler({ getToken, getCwd, getFdAvailable, version: BRIDGE_VERSION }),
		);
		registerBridgeHandler(
			"getSuggestions",
			makeGetSuggestionsHandler({ getProvider }), // timeoutMs defaults to GET_SUGGESTIONS_TIMEOUT_MS
		);
		// TODO(S12): register "applyCompletion"; (S13): "shouldTriggerFileCompletion"; (S14): ping/bye/getCommands.

// === Task 2: get-suggestions-handler.test.ts — key stub shapes ===

// A stub provider that records the call and returns a fixed result (or null).
function makeRecordingProvider(result: AutocompleteSuggestions | null) {
	let lastCall: { lines: string[]; cursorLine: number; cursorCol: number; signal: AbortSignal; force: boolean } | undefined;
	const provider = {
		getSuggestions: async (
			lines: string[], cursorLine: number, cursorCol: number,
			opts: { signal: AbortSignal; force?: boolean },
		) => {
			lastCall = { lines, cursorLine, cursorCol, signal: opts.signal, force: opts.force === true };
			return result;
		},
		applyCompletion: (lines: string[]) => ({ lines, cursorLine: 0, cursorCol: 0 }),
		shouldTriggerFileCompletion: () => true,
	};
	return { provider, getLastCall: () => lastCall };
}

// A stub that resolves ONLY when its signal aborts (for supersession/timeout tests).
function makeAbortResolvingProvider() {
	const provider = {
		getSuggestions: (
			_lines: string[], _cl: number, _cc: number,
			opts: { signal: AbortSignal; force?: boolean },
		) => new Promise<null>((resolve) => {
			if (opts.signal.aborted) return resolve(null);
			opts.signal.addEventListener("abort", () => resolve(null), { once: true });
		}),
		applyCompletion: (lines: string[]) => ({ lines, cursorLine: 0, cursorCol: 0 }),
		shouldTriggerFileCompletion: () => true,
	};
	return provider;
}

// UNIT test 5 (supersession) — the core assertion:
const { provider } = makeAbortResolvingProvider();
const handler = makeGetSuggestionsHandler({ getProvider: () => provider, timeoutMs: 30 });
const state = { handshakeComplete: true };
const signals: AbortSignal[] = [];
const wrap = (p: ReturnType<typeof handler>) => { /* capture */ return p; };
// To capture each call's signal, wrap the provider to push opts.signal:
//   (use a recording variant that also resolves-on-abort)
const p1 = handler({ lines: ["/m"], cursorLine: 0, cursorCol: 2 }, state);
const p2 = handler({ lines: ["/mo"], cursorLine: 0, cursorCol: 3 }, state);
// after p2 starts, the FIRST call's signal MUST be aborted:
assert.equal(firstSignal.aborted, true, "2nd request must abort the 1st's signal");
assert.equal(secondSignal.aborted, false, "2nd request's own signal starts non-aborted");
const [r1, r2] = await Promise.all([p1, p2]);
assert.equal(r1, null); // 1st aborted → provider resolved null
assert.equal(r2, null); // 2nd aborted via its own 30ms timeout → resolved null

// DISPATCH test 10 (valid → success):
registerBridgeHandler("getSuggestions", makeGetSuggestionsHandler({ getProvider: () => makeRecordingProvider({ items: [{ value: "/model", label: "model" }], prefix: "/m" }).provider }));
try {
	const { sock, writes } = fakeSocket();
	await handleLine(sock, { handshakeComplete: true }, JSON.stringify({
		jsonrpc: "2.0", id: "g1", method: "getSuggestions",
		params: { lines: ["/m"], cursorLine: 0, cursorCol: 2 },
	}));
	assert.deepEqual(parseResponses(writes), [{
		jsonrpc: "2.0", id: "g1",
		result: { items: [{ value: "/model", label: "model" }], prefix: "/m" },
	}]);
} finally { __resetHandlersForTest(); }

// REAL test 13 (hello → getSuggestions → result over a real socket):
registerBridgeHandler("hello", makeHelloHandler({ getToken: () => TOKEN, getCwd: () => "/tmp", getFdAvailable: () => true, version: BRIDGE_VERSION }));
registerBridgeHandler("getSuggestions", makeGetSuggestionsHandler({ getProvider: () => stub }));
const sockpath = join(tmpdir(), `pi-editor-gs-${randomUUID()}.sock`);
const server = createServer((c) => onConnection(c));
server.listen(sockpath);
await once(server, "listening");
try {
	const client = connect(sockpath);
	await once(client, "connect");
	const rH = readFirstResponse(client);
	client.write(serializeJsonLine({ jsonrpc: "2.0", id: "h1", method: "hello", params: { token: TOKEN } }));
	await rH; // HelloResult
	const rG = readFirstResponse(client);
	client.write(serializeJsonLine({ jsonrpc: "2.0", id: "g1", method: "getSuggestions", params: { lines: ["/m"], cursorLine: 0, cursorCol: 2 } }));
	const got = (await rG) as { id: string; result: { items: unknown[]; prefix: string } };
	assert.equal(got.id, "g1");
	assert.deepEqual(got.result, { items: [{ value: "/model", label: "model" }], prefix: "/m" });
	client.destroy();
} finally { __resetHandlersForTest(); server.close(); }
```

### Integration Points

```yaml
SESSION LIFECYCLE (pi-editor-bridge.ts):
  - session_start: captureProvider (S2) → startBridge (S5) → cwd = ctx.cwd →
    register hello (S9) → **register getSuggestions (S11, NEW)** → [S12+ …].
    All BELOW the `if (ctx.mode !== "tui") return;` guard (inherited protection).
  - session_shutdown: stopBridge (unchanged). No getSuggestions-specific teardown
    (the handler holds no socket/fs resource; its pendingAbort/timer are
    request-scoped and self-clearing via finally). A session_shutdown mid-flight
    just leaves the in-flight provider call to resolve on its own timeout/abort —
    harmless (the socket is gone; the response write becomes a no-op on a closed
    socket, caught by connection.ts's sock.on("error")).

CONNECTION DISPATCH (connection.ts): UNCHANGED. handleLine's REQUEST branch
  already `await`s the handler and sends `{id,result}`; a thrown BridgeRpcError
  → `{id,error:{code,message}}`; any other throw → `-32603`. The S10 gate already
  blocks getSuggestions pre-hello. S11 is PURELY a new handler registration.

PROTOCOL (protocol.ts): CONSUMED, not modified. GetSuggestionsParams/Result are
  already defined (§C); AutocompleteItem/AutocompleteSuggestions are re-exported
  from pi-tui (byte-identical wire shape).

DOWNSTREAM:
  - S12 (applyCompletion) + S13 (shouldTriggerFileCompletion) will reuse this
    EXACT factory shape (sync providers — no AbortController needed for them, but
    they can still take { getProvider }). S14 (ping/bye/getCommands) are simpler.
  - S15 (domain-error wrapping): wraps the provider-not-captured + provider-
    runtime-throw paths S11 currently leaves to the -32603 net. Designing S11's
    factory with `deps.getProvider` callable separately (not inlined) makes the
    S15 refinement a one-line wrap.
  - P2.M5 (Neovim client): the client's id-correlation supersession (S26) is the
    COUNTERPART to S11's server-side AbortController supersession. Both must agree
    that each request gets a response (client ignores stale ids; server aborts
    stale provider calls).
```

---

## Validation Loop

### Level 1: Syntax & Type (after the source edit)

```bash
cd /home/dustin/projects/pi-nvim-bridge
tsc --noEmit -p extension/tsconfig.json
# Expected: exit 0, NO output. (TS 5.9.3, Node v26.4.0 — verified baseline. setTimeout/
# clearTimeout are typed globals here — used in 2 existing test files that type-check clean.)
```

### Level 2: Unit / component tests (node:test + jiti — NOT vitest)

```bash
JITI_REG=/home/dustin/.local/lib/node_modules/@earendil-works/pi-coding-agent/node_modules/jiti/lib/jiti-register.mjs

# The NEW getSuggestions suite (UNIT + DISPATCH + ONE REAL)
node --import "$JITI_REG" extension/tests/get-suggestions-handler.test.ts
# Expected: exit 0, `ℹ fail 0`. (jiti prints a benign DeprecationWarning on Node 26
# stderr — judge by exit code + the `ℹ pass`/`ℹ fail` summary, ignore the warning.)

# Regression: the gate still wins pre-handshake (handshake-gate suite)
node --import "$JITI_REG" extension/tests/handshake-gate.test.ts
# Expected: exit 0, `ℹ fail 0`.

# Regression: hello handler (unchanged; getSuggestions registration is additive)
node --import "$JITI_REG" extension/tests/hello-handler.test.ts
# Expected: exit 0, `ℹ fail 0`.

# Regression: connection dispatch (16 tests) — getSuggestions dispatch is via the
# SAME handleLine; no dispatch code changed.
node --import "$JITI_REG" extension/tests/connection.test.ts
# Expected: `ℹ tests 16`, `ℹ pass 16`, `ℹ fail 0`.

# Full extension suite (no S2–S10 regressions)
for t in extension/tests/*.test.ts; do
  echo "--- $t"
  node --import "$JITI_REG" "$t" 2>/dev/null | grep -E "^ℹ (tests|pass|fail)"
done
# Expected: every file `ℹ fail 0`.
```

### Level 3: Integration (a real socket pair — getSuggestions end-to-end)

```bash
# Driven by the real-socket test #13 inside get-suggestions-handler.test.ts. To
# eyeball the wire by hand (optional): hello → getSuggestions("/m") → result.
JITI_REG=/home/dustin/.local/lib/node_modules/@earendil-works/pi-coding-agent/node_modules/jiti/lib/jiti-register.mjs
node --import "$JITI_REG" -e '
  const { createServer, connect } = require("node:net");
  const { join } = require("node:path"), { tmpdir } = require("node:os"), { randomUUID } = require("node:crypto");
  const { onConnection, registerBridgeHandler } = await import("./extension/connection.ts");
  const { makeHelloHandler, makeGetSuggestionsHandler, BRIDGE_VERSION } = await import("./extension/pi-editor-bridge.ts");
  const { serializeJsonLine, attachJsonlLineReader } = await import("./extension/jsonl-reader.ts");
  const TOKEN = "deadbeef".repeat(4);
  const stub = { getSuggestions: async (l, cl, cc) => l[cl]?.startsWith("/m") ? { items:[{value:"/model",label:"model"}], prefix:"/m" } : null, applyCompletion:(l)=>({lines:l,cursorLine:0,cursorCol:0}), shouldTriggerFileCompletion:()=>true };
  registerBridgeHandler("hello", makeHelloHandler({ getToken:()=>TOKEN, getCwd:()=>"/tmp", getFdAvailable:()=>true, version:BRIDGE_VERSION }));
  registerBridgeHandler("getSuggestions", makeGetSuggestionsHandler({ getProvider:()=>stub }));
  const sockpath = join(tmpdir(), `gs-${randomUUID()}.sock`);
  const s = createServer(c=>onConnection(c)); s.listen(sockpath);
  s.once("listening", ()=>{
    const cli = connect(sockpath);
    const read = () => new Promise(res=>{ const d=attachJsonlLineReader(cli,l=>{d();res(JSON.parse(l))}); });
    cli.once("connect", async ()=>{
      cli.write(serializeJsonLine({jsonrpc:"2.0",id:"h1",method:"hello",params:{token:TOKEN}}));
      console.log("hello:", JSON.stringify(await read()));
      cli.write(serializeJsonLine({jsonrpc:"2.0",id:"g1",method:"getSuggestions",params:{lines:["/m"],cursorLine:0,cursorCol:2}}));
      console.log("/m:", JSON.stringify(await read()));
      cli.write(serializeJsonLine({jsonrpc:"2.0",id:"g2",method:"getSuggestions",params:{lines:["zzz"],cursorLine:0,cursorCol:3}}));
      console.log("zzz:", JSON.stringify(await read()));
      cli.destroy(); s.close();
    });
  });
'
# Expected:
#   hello: {"jsonrpc":"2.0","id":"h1","result":{"ok":true,"serverVersion":"0.1.0","cwd":"/tmp","fdAvailable":true}}
#   /m:   {"jsonrpc":"2.0","id":"g1","result":{"items":[{"value":"/model","label":"model"}],"prefix":"/m"}}
#   zzz:  {"jsonrpc":"2.0","id":"g2","result":null}
```

### Level 4: Domain-specific validation (supersession + timeout invariants)

```bash
# (a) Supersession aborts the prior signal — asserted in UNIT test #5
#     (firstSignal.aborted === true immediately after the 2nd call is dispatched).
# (b) Timeout fires for a never-resolving provider — asserted in UNIT test #6
#     (handler resolves to null after the short injected timeoutMs; no hang).
# (c) No leaked timer keeps the process alive — the loop in UNIT test #7 +
#     `server.close()`/`client.destroy()` in REAL test #13 let node:test exit
#     promptly. If a 1500 ms timer leaked, the suite would visibly stall ~1.5s
#     per call. (Use short timeoutMs in timing tests to make this observable.)
# (d) Param validation never reaches the provider — asserted in DISPATCH test #11
#     (the recording stub's getLastCall() stays undefined on a -32602 path).
# (e) Token value never appears in any getSuggestions response/stderr (PRD §12) —
#     the getSuggestions result carries only completion items; grep the run:
JITI_REG=/home/dustin/.local/lib/node_modules/@earendil-works/pi-coding-agent/node_modules/jiti/lib/jiti-register.mjs
SECRET="deadbeefdeadbeefdeadbeefdeadbeef"
node --import "$JITI_REG" extension/tests/get-suggestions-handler.test.ts 2>&1 | grep -c "$SECRET" || true
# Expected: 0 in RESULT payloads (the token only appears in the hello request the
# test itself sends, never in a getSuggestions response — assert specifically that
# no line where method/result co-occurs contains the secret; the simple grep above
# is a coarse sanity check; the dedicated assertion lives in the test.)
```

---

## Final Validation Checklist

### Technical Validation
- [ ] `tsc --noEmit -p extension/tsconfig.json` ⇒ exit 0, no output.
- [ ] `node --import "$JITI_REG" extension/tests/get-suggestions-handler.test.ts` ⇒ exit 0, `ℹ fail 0`.
- [ ] `node --import "$JITI_REG" extension/tests/handshake-gate.test.ts` ⇒ `ℹ fail 0` (gate still wins pre-handshake).
- [ ] `node --import "$JITI_REG" extension/tests/hello-handler.test.ts` ⇒ `ℹ fail 0` (additive registration).
- [ ] `node --import "$JITI_REG" extension/tests/connection.test.ts` ⇒ `ℹ tests 16`, `ℹ fail 0`.
- [ ] Every `extension/tests/*.test.ts` ⇒ `ℹ fail 0` (no S2–S10 regressions).

### Feature Validation
- [ ] Valid post-handshake `getSuggestions` ⇒ live provider's result verbatim (`{items,prefix}` or `null`).
- [ ] `force` threaded as a strict boolean (`true` when sent; `false` when omitted/`false`).
- [ ] Provider receives a fresh, non-aborted `AbortSignal` on each call.
- [ ] Supersession: a 2nd in-flight request aborts the 1st's signal; both resolve and both get responses.
- [ ] Timeout: a never-resolving provider resolves to its abort result after `timeoutMs`; no hang.
- [ ] Timer cleared in `finally` (no leaked timer past normal completion).
- [ ] Malformed params ⇒ exactly one `-32602 "invalid params: …"` with the request id.
- [ ] Pre-handshake `getSuggestions` ⇒ still `-32600` (S10 gate; provider NOT called).
- [ ] Provider-not-captured ⇒ `-32603` (safety net; not wrapped by S11).
- [ ] Token value never present in any `getSuggestions` response (PRD §12).

### Code Quality
- [ ] Factory mirrors `makeHelloHandler` (deps-injection; pure factory returning a `MethodHandler`).
- [ ] `pendingAbort` is closure-scoped (one per registered instance); `timeoutMs` deps-injected with `GET_SUGGESTIONS_TIMEOUT_MS` default.
- [ ] `force` threaded as `params.force === true` (strict boolean, matches PRD §6.5 `!!force`).
- [ ] Params narrowing throws `BridgeRpcError(-32602)` (S9 precedent; reserved code).
- [ ] Provider-not-captured / provider-runtime-throws left to the `-32603` safety net (NOT wrapped — S15's lane).
- [ ] `setTimeout`/`clearTimeout` in `finally`; `ReturnType<typeof setTimeout>` typing (proven idiom).
- [ ] Registration added AFTER the existing `hello` registration; BELOW the TUI-mode guard.
- [ ] TAB indentation, `node:test` + `assert/strict` + jiti (NOT vitest); `fakeSocket`/`parseResponses`/`readFirstResponse` copied verbatim; `__resetHandlersForTest()` in EVERY finally.
- [ ] session_start STATUS/roadmap comment updated to mark S11 done (repo convention of accurate cross-task comments).

### Scope Discipline (did NOT bleed into other tasks)
- [ ] `extension/connection.ts` UNCHANGED (verify: `git diff --stat extension/connection.ts` ⇒ empty).
- [ ] `extension/protocol.ts` UNCHANGED (verify: `git diff --stat extension/protocol.ts` ⇒ empty).
- [ ] No S12 (applyCompletion) / S13 (shouldTriggerFileCompletion) / S14 (ping/bye/getCommands) registrations.
- [ ] No S15 domain-error wrapping of provider-not-captured / provider-runtime-throws into specific codes (left to the -32603 net).
- [ ] No S16 `process.env.PI_EDITOR_BRIDGE` write / no S17 `commandsChanged`.
- [ ] No client-side supersession/debounce (that is P2.M5/S26 — the server only aborts + responds; the client ignores stale ids).

---

## Anti-Patterns to Avoid

- ❌ Don't suppress the stale (superseded) request's response. `handleLine` is fire-and-forget per line and ALWAYS sends one response per REQUEST. The provider RESOLVES on abort, so the stale call answers cheaply with `null`/its-abort-result; the client ignores stale ids. Trying to track "current id" server-side to skip a write fights the dispatcher and can hang the client's RPC timeout.
- ❌ Don't omit the per-request timeout. pi's provider has NO internal timeout (verified) — a hung `fd` would hang the editor. The `setTimeout(timeoutMs, () => ac.abort())` is mandatory, not optional.
- ❌ Don't leak the timer. Always `clearTimeout(timer)` in `finally` — even on the success path — or node:test can stall ~1.5s per call and a runaway loop leaks timers.
- ❌ Don't thread `force` as `params.force` (could be `undefined`). The provider gates branches on `!options.force` and `extractPathPrefix(force)`; pass `params.force === true` so it's always a strict boolean (matches PRD §6.5 `!!force`).
- ❌ Don't wrap provider-not-captured / provider-runtime-throws into a specific code here. That is S15's explicit lane ("wrap ALL handlers' domain errors into proper codes"). S11 leaves them to `handleLine`'s `-32603` safety net — it keeps pi safe, and the factory's separate `deps.getProvider()` call makes the S15 wrap a one-liner later.
- ❌ Don't put `pendingAbort` at module scope as a `let`. Encapsulate it in the factory closure (mirrors `makeHelloHandler`). One registered handler instance ⇒ one closure ⇒ correct global supersession, and no test-cross-contamination between factory recreations.
- ❌ Don't use a real 1500 ms wait (or fake timers) to test the timeout. Inject `timeoutMs: 30` via the deps and assert the never-resolving stub resolves to null promptly.
- ❌ Don't edit `connection.ts` or `protocol.ts`. The dispatch, error mapping, and handshake gate already cover S11; the wire types are already defined. Verify with `git diff --stat`.
- ❌ Don't register `getSuggestions` before `hello`, before `startBridge`, or above the `ctx.mode !== "tui"` guard. It needs the captured provider + token and must be TUI-only.
- ❌ Don't use vitest or a non-`node:test` runner; don't forget `__resetHandlersForTest()` in every `finally`.

---

## Confidence Score: 9/10

**Why 9, not 10**: the design is pinned by PRD §6.5's near-verbatim skeleton and
by verified pi-source facts (provider RESOLVES on abort — research §1.2 — so
supersession needs no response suppression; SIGKILL on abort frees `fd`; no
provider-internal timeout makes the bridge timer mandatory). It reuses S9's
factory + `BridgeRpcError` precedent and S10's gate, adds NO change to
`connection.ts`/`protocol.ts`, and matches the proven three-layer test shape of
the 3 sibling suites (verbatim helpers copied). The factory's deps-injected
`timeoutMs` makes the timeout testable without fake timers. Residual risks: (a)
the exact supersession-test timing (firing two async handlers without awaiting
and asserting the first signal aborted before either settles) — mitigated by the
abort-resolving stub that never rejects and the short `timeoutMs`; (b) confirming
`setTimeout`/`clearTimeout` type-check under `types:[]` — mitigated by precedent
(2 existing test files use them and pass `tsc`). Both are validation-gate
catchable, not design-level.
