name: "P1.M2.T6.S12 — applyCompletion handler (synchronous delegation to pi's live provider)"
description: "pi-editor-bridge extension (TS). Register the `applyCompletion` JSON-RPC handler as a dependency-injected factory (`makeApplyCompletionHandler`) that SYNCHRONOUSLY delegates to pi's live AutocompleteProvider.applyCompletion — a pure function of (lines, cursorLine, cursorCol, item, prefix) → {lines, cursorLine, cursorCol}. Unlike getSuggestions (S11), this handler is SYNC, needs NO AbortController, NO supersession, NO timeout, NO `force` — pi's applyCompletion takes no options/signal and never blocks the event loop (verified: autocomplete.ts:256-271 interface is sync; editor.ts:669/690/2257 call it WITHOUT await). Narrow params to `BridgeRpcError(-32602)` on malformed shape (lines:string[], non-negative-integer cursorLine/cursorCol, item:{value:string,label:string}, prefix:string — matches S11/S9 precedent). Provider-not-captured + runtime throws propagate to handleLine's `-32603` safety net (S15 refines). No change to connection.ts (its `-32603` net + BridgeRpcError handling + sync-return support already cover this) or protocol.ts (ApplyCompletionParams/ApplyCompletionResult already defined in §C). New `apply-completion-handler.test.ts` (UNIT/DISPATCH/REAL three layers). node:test + jiti (NOT vitest)."

---

## Goal

**Feature Goal**: Land the second completion-engine RPC handler. When an
authenticated Neovim client accepts a completion item in the prompt buffer, it
sends `applyCompletion(lines, cursorLine, cursorCol, item, prefix)`; the bridge
**synchronously** delegates to pi's **live** `AutocompleteProvider.applyCompletion`
— exactly as pi's own TUI editor does (editor.ts:669/690/2257, all sync, no
`await`) — and returns pi's `{lines, cursorLine, cursorCol}` (the new FULL buffer
+ cursor) verbatim. Because pi's `applyCompletion` computes ALL insertion edge
cases (slash-command trailing space `/cmd `, `@file` trailing space for files /
none for dirs, quote handling, cursor repositioning), the bridge **forwards
(…,item,prefix) and returns pi's result unchanged** — insertion behavior is
byte-for-byte identical to the TUI (PRD §4 step 5, §7.4). The bridge NEVER
reimplements insertion logic.

**Deliverable**:
1. `extension/pi-editor-bridge.ts` — ADD:
   - `makeApplyCompletionHandler(deps: { getProvider })` factory (mirrors the
     `makeHelloHandler`/`makeGetSuggestionsHandler` deps-injection pattern from
     S9/S11) returning a `MethodHandler`. **The handler is SYNC** — it returns
     the result object directly (NOT `async`/NOT a Promise), faithfully mirroring
     pi's own sync contract. There is NO closure state (no `pendingAbort`, no
     `timeoutMs`) — `applyCompletion` has no supersession/timing concerns.
   - A private `narrowApplyCompletionParams(params)` helper that validates
     `lines:string[]`, `cursorLine`/`cursorCol` (non-negative integers),
     `item` (object with `value:string` + `label:string`, `description?`
     optional), `prefix` (string), and throws `BridgeRpcError(-32602, …)` on any
     malformed shape (matches S9/S11 precedent; `-32602` = reserved "invalid params").
   - One new `registerBridgeHandler("applyCompletion", makeApplyCompletionHandler({ getProvider }))`
     line in the `session_start` handler, immediately AFTER the existing
     `getSuggestions` `registerBridgeHandler` call.
   - Extend the existing `import type { HelloParams, HelloResult, GetSuggestionsParams, GetSuggestionsResult }`
     from `./protocol.ts` to ALSO import `ApplyCompletionParams, ApplyCompletionResult`.
   - Update the existing `TODO(S12)` comment (replace the applyCompletion entry;
     keep S13/S14/S16 TODOs).
2. `extension/tests/apply-completion-handler.test.ts` (NEW) — three layers:
   UNIT (factory directly with a stub provider: happy path, exact-arg threading,
   sync return, optional-description passthrough, param validation, provider-not-
   captured), DISPATCH (registerBridgeHandler + `fakeSocket` + `handleLine`,
   `{ handshakeComplete: true }` for the gated happy path), and ONE REAL Unix-socket
   integration test (hello → applyCompletion → result over a real socket).

**Success Definition**: With the bridge running and a client authenticated via
`hello`, an `applyCompletion` request returns EXACTLY the `{lines, cursorLine,
cursorCol}` the live provider produces — the wire carries pi's computed new buffer
+ cursor, so the Neovim client (P2.M7.T19.S32) need only `nvim_buf_set_lines(0,
0, -1, false, result.lines)` + reposition the cursor. Malformed params yield
`-32602`. Pre-handshake yields `-32600` (S10 gate, unchanged). Provider-not-captured
yields `-32603` (safety net; S15 refines). `tsc --noEmit` is clean; the new suite
passes; **all 10 existing extension suites stay green** (S2–S11); `connection.ts`
and `protocol.ts` are UNCHANGED.

---

## User Persona

**Target User**: The `pi-editor.nvim` Neovim plugin (P2.M5 / P2.M7) — the bridge's
only client. (Indirectly: the human editing a pi prompt in their `$EDITOR`.)

**Use Case**: The user has a completion menu open (populated by a prior
`getSuggestions` response) and presses `<Tab>`/`<C-Y>`/`<CR>` to accept an item.
The Neovim client captures the current buffer `lines` + cursor (0-indexed line,
UTF-16 col per PRD §8), the accepted `AutocompleteItem` (from the menu), and the
`prefix` (from the `getSuggestions` response it stored — pi's own prefix), then
sends `applyCompletion`. The bridge forwards to pi's live provider, which returns
the new full buffer + cursor; the client replaces the buffer and positions the
cursor (PRD §7.4 accept flow).

**Pain Points Addressed**: The external editor gets pi's *actual* insertion
behavior (trailing spaces, directory-vs-file, quote handling, `/cmd ` spacing) —
NOT a fragile reimplementation. Because pi's `applyCompletion` returns the entire
new line array + final cursor, the plugin never has to compute insertion offsets
or guess at edge cases.

---

## Why

- **Second engine-delegating handler; completes the accept half of completion.**
  S11 (getSuggestions) is the *offer* half; S12 is the *accept* half. Together they
  make the bridge a complete completion conduit — the Neovim menu is populated by
  S11 and accepting an item is delegated via S12. Both delegate to pi's SAME live
  provider, so offer+accept are guaranteed consistent (the prefix S11 returns is
  the prefix S12 consumes).
- **Byte-identical insertion, zero reimplementation.** pi's `applyCompletion`
  centralizes every insertion rule (slash commands, `@file`, quotes, cursor).
  Delegating means the bridge carries NONE of that logic — it forwards and returns
  verbatim (PRD §4 step 5). This is the single biggest correctness guarantee of
  the whole design.
- **Structurally the SIMPLEST engine handler.** Unlike getSuggestions (async, fd,
  AbortController, supersession, timeout, force), applyCompletion is a **pure
  synchronous** function (verified §1.1). S12 therefore has NO timing/resource
  concerns — no fd to SIGKILL, no timeout to arm, no in-flight call to supersede.
  The factory is the leanest in the M2.T6 family: a single `{ getProvider }` dep.
- **Mirrors the client's model (P2.M7.T19.S32).** The Neovim accept flow is
  `applyCompletion` RPC → replace buffer → set cursor. S12 is the server-side
  counterpart that hands back exactly what the client applies.

---

## What

### User-visible behavior (wire)

| Client sends (post-`hello`) | Server action & response |
|---|---|
| `applyCompletion {lines:[...], cursorLine, cursorCol, item:{value,label}, prefix}` (valid) | **Synchronously** delegate to `liveProvider.applyCompletion(lines, cursorLine, cursorCol, item, prefix)`. Reply `{jsonrpc,id,result:{lines,cursorLine,cursorCol}}` — pi's new full buffer + cursor. |
| `applyCompletion {..., item:{value,label,description}}` | Same — `description` passes through (AutocompleteItem.description is optional); pi ignores it for insertion but the shape is legal. |
| malformed params (lines not string[]; cursorLine/cursorCol not non-negative integer; item missing `value`/`label` or wrong-typed; item not an object; prefix not a string) | `BridgeRpcError(-32602, "invalid params: …")` → `handleLine` maps to `{"id","error":{"code":-32602,"message":"invalid params: …"}}`. The provider is NOT called. |
| `applyCompletion` before `hello` | (Unchanged — S10 gate) `-32600 "handshake required: send hello first"`. |
| `applyCompletion` when provider not yet captured | `getProvider()` throws plain `Error` → `handleLine` `-32603` safety net. (S15 may later refine to a specific code; S12 leaves the safety net — it keeps pi safe.) |
| provider's `applyCompletion` throws (e.g. a misbehaving wrapper) | `handleLine` `-32603` safety net (unchanged). |

### Success Criteria

- [ ] `applyCompletion` (valid, post-handshake) returns the live provider's result
      verbatim (`{jsonrpc,id,result:{lines,cursorLine,cursorCol}}`).
- [ ] All five params (`lines`, `cursorLine`, `cursorCol`, `item`, `prefix`) are
      forwarded to the provider **untouched** (the provider receives exactly what
      the client sent).
- [ ] The handler is **synchronous** — it returns the result object directly (NOT
      wrapped in a Promise); `MethodHandler`'s `Promise<unknown> | unknown` union
      accommodates this and `handleLine`'s `await` is a no-op on a non-Promise.
- [ ] An `item` with NO `description` is accepted (description is optional).
- [ ] Malformed params ⇒ exactly one `-32602 "invalid params: …"` response with the
      request id; the provider is NOT called.
- [ ] Pre-handshake `applyCompletion` ⇒ still `-32600` (S10 gate, unchanged).
- [ ] Provider-not-captured ⇒ `-32603` (safety net; S12 does not wrap it).
- [ ] `tsc --noEmit -p extension/tsconfig.json` ⇒ exit 0, no output.
- [ ] New `apply-completion-handler.test.ts` passes (`ℹ fail 0`); every other
      `extension/tests/*.test.ts` ⇒ `ℹ fail 0` (no S2–S11 regressions).
- [ ] `extension/connection.ts` and `extension/protocol.ts` are UNCHANGED
      (verify: `git diff --stat extension/connection.ts extension/protocol.ts` ⇒ empty).

---

## All Needed Context

### Context Completeness Check

_"If someone knew nothing about this codebase, would they have everything needed
to implement this successfully?"_ — Yes. This PRP pins the exact factory shape
(from PRD §6.5's skeleton, which has NO AbortController/timeout for applyCompletion),
the exact sync contract (verified against pi source: interface + impl + 3 TUI call
sites), the exact param-narrowing rules + `-32602` codes, the exact registration
site (after the existing `getSuggestions` `registerBridgeHandler`), the verbatim
test helpers to copy (`fakeSocket`/`parseResponses`/`readFirstResponse`), the exact
three-layer test shape proven by 3 sibling suites, and the verified test commands.
No guessing.

### Documentation & References

```yaml
# MUST READ — the governing spec
- url: PRD §6.5 (Request handling skeleton) + §5.4 (methods table) + §7.4 (completion.lua accept flow)
  why: "§6.5 is the AUTHORITATIVE applyCompletion skeleton — and CRUCIALLY it is the SYNC one: `applyCompletion({...}) { requireProvider(); return liveProvider!.applyCompletion(lines, cursorLine, cursorCol, item, prefix); }` — NO async, NO AbortController, NO setTimeout, NO pendingAbort (contrast the getSuggestions skeleton directly above it which HAS all of those). §5.4 defines applyCompletion params/result. §7.4 documents the Neovim accept flow that consumes the result (replace buffer + set cursor)."
  critical: "PRD §6.5's applyCompletion skeleton is a near-verbatim implementation spec. The ONLY deviation this PRP makes is encapsulating it in a deps-injected FACTORY (matching S9/S11) instead of a module-level handler, and adding params narrowing with BridgeRpcError(-32602). Do NOT copy the getSuggestions skeleton's AbortController/timeout/supersession into applyCompletion — applyCompletion does not need them (verified: pi's applyCompletion is sync)."

# MUST READ — the file this task edits (READ BEFORE EDITING)
- file: extension/pi-editor-bridge.ts
  why: "The home of makeGetSuggestionsHandler (the factory pattern to mirror), getProvider() (the deps.getProvider the factory receives), narrowGetSuggestionsParams (the narrowing helper to mirror), BRIDGE_VERSION/startBridge/stopBridge (lifecycle context), and the session_start handler where registration is ADDED. Its makeGetSuggestionsHandler JSDoc + narrowGetSuggestionsParams code IS the precedent for S12."
  pattern: "makeGetSuggestionsHandler(deps:{getProvider,timeoutMs?}) => MethodHandler — a PURE factory, deps are getter closures so tests stub them. S12 is the LEANER sibling: makeApplyCompletionHandler(deps:{getProvider}) — ONLY getProvider (no timeoutMs, no AbortController, no closure state). The factory returns a SYNC handler `(params,state) => ApplyCompletionResult` (NOT async)."
  gotcha: "Imports: AutocompleteProvider ALREADY imported from @earendil-works/pi-tui. BridgeRpcError/MethodHandler/ConnectionState ALREADY imported from ./connection.ts. ADD ApplyCompletionParams/ApplyCompletionResult to the existing `import type { HelloParams, HelloResult, GetSuggestionsParams, GetSuggestionsResult } from \"./protocol.ts\"`. Register the handler AFTER the existing `getSuggestions` `registerBridgeHandler` call (provider capture + token both already exist by then)."

- file: extension/connection.ts
  why: "CONFIRMS S12 needs NO change here. MethodHandler is already `(params,state) => Promise<unknown> | unknown` — a SYNC return (plain object) is legal. handleLine's REQUEST branch already does `const result = await handler(params,state); sendResponse(sock,reqId,result)` — `await` on a non-Promise resolves to that object immediately, so a sync handler works unchanged. It already maps a thrown BridgeRpcError → `{id,error:{code,message}}` and any other throw → `-32603`. The S10 handshake gate already blocks applyCompletion pre-hello."
  pattern: "handleLine is fire-and-forget per line. applyCompletion being sync means it completes within one microtask — no in-flight concerns, no resource to clean up. This is the structural reason S12 has NO supersession (unlike getSuggestions): a sync call cannot be 'in-flight' alongside another."
  gotcha: "DO NOT EDIT connection.ts. The -32603 safety net + BridgeRpcError handling already cover every throw path S12 can produce. registerBridgeHandler is MODULE-LEVEL (shared across connections) — one applyCompletion handler instance per session (pure delegation, no shared mutable state)."

- file: extension/protocol.ts
  why: "CONSUME the already-defined ApplyCompletionParams {lines:string[]; cursorLine:number; cursorCol:number; item:AutocompleteItem; prefix:string} and ApplyCompletionResult {lines:string[]; cursorLine:number; cursorCol:number} (§C, already defined). CONFIRMS cursorLine is 0-indexed, cursorCol is a 0-indexed UTF-16 offset (conversion lives in the Lua coords module P2.M6 — the bridge passes numbers through untouched)."
  gotcha: "protocol.ts is TYPES-ONLY (zero runtime exports). S12 adds NO type to protocol.ts. ApplyCompletionResult is a plain interface (NOT a union like GetSuggestionsResult) — applyCompletion always returns a concrete {lines,cursor} object, never null."

- file: extension/tests/get-suggestions-handler.test.ts
  why: "the CLOSEST, cleanest sibling suite — model the new test file's imports block + helpers + REAL-socket shape on it (it is the newest and most representative: it exercises an engine-delegating handler end-to-end). It shows: combined `{ EventEmitter, once }`, explicit .ts import extensions, the registerBridgeHandler+__resetHandlersForTest-in-finally hygiene, AutocompleteItem/AutocompleteProvider type imports from @earendil-works/pi-tui, and the hello-first REAL-socket template."
  pattern: "Imports: from ../connection.ts (handleLine, onConnection, registerBridgeHandler, __resetHandlersForTest, BridgeRpcError, type ConnectionState) + from ../pi-editor-bridge.ts (makeHelloHandler, makeApplyCompletionHandler, BRIDGE_VERSION) + from ../jsonl-reader.ts (attachJsonlLineReader, serializeJsonLine) + type imports from @earendil-works/pi-tui. COPY fakeSocket()/parseResponses()/readFirstResponse() VERBATIM (they are LOCAL per-file, not exported — connection.test.ts, hello-handler.test.ts, handshake-gate.test.ts, get-suggestions-handler.test.ts each re-declare them identically)."
  gotcha: "readFirstResponse(client) MUST be called BEFORE client.write(...) (attach the one-shot reader first, then write, then await). Repeat per response in the REAL test. Dispatch tests pass `{ handshakeComplete: true }` so the S10 gate lets applyCompletion through."

# Prior plan context (READ for rationale; do NOT copy code blindly)
- docfile: plan/001_c56962b4fa17/P1M2T6S12/research/notes.md
  section: "§1.1 (SYNC contract — the defining difference from S11), §1.2 (insertion lives in pi), §3 (S12 vs S11 table — what S12 does NOT need), §5 (param validation rules)"
  why: "the WHY behind every non-obvious choice — esp. WHY S12 has NO AbortController/timeout/supersession (pi's applyCompletion is sync and takes no signal — verified at autocomplete.ts:256-271), WHY the handler is SYNC (faithfully mirrors pi's own contract + MethodHandler accommodates sync), and WHY item.description is optional in validation (AutocompleteItem.description is `?`)."
- docfile: plan/001_c56962b4fa17/P1M2T6S11/research/notes.md
  section: "§4 (S11 vs S15 error-wrapping boundary — IDENTICAL for S12), §5 (test conventions — IDENTICAL for S12), §6 (integration points)"
  why: "establishes the S15 error-wrapping boundary (S12 leaves provider-not-captured + runtime throws to the -32603 net, same as S11) and the verbatim test conventions S12 reuses."
```

### Current Codebase tree

```bash
extension/
├── pi-editor-bridge.ts     # S1/S3/S5/S6/S9/S11: lifecycle, captureProvider/getProvider, start/stopBridge, makeHelloHandler, narrowGetSuggestionsParams, makeGetSuggestionsHandler + GET_SUGGESTIONS_TIMEOUT_MS, getToken/getCwd/getFdAvailable/BRIDGE_VERSION  ← EDIT (add makeApplyCompletionHandler + narrowApplyCompletionParams + 1 registration line + import add)
├── protocol.ts             # S4: ALL wire types (TYPES-ONLY) — incl. ApplyCompletionParams/ApplyCompletionResult (§C, already defined)  ← UNCHANGED (consume only)
├── jsonl-reader.ts         # S7: attachJsonlLineReader, serializeJsonLine
├── connection.ts           # S8/S9/S10/S11: ConnectionState, registerBridgeHandler, send*, BridgeRpcError, handleLine (gate + -32603 net), onConnection  ← UNCHANGED
├── tsconfig.json
└── tests/
    ├── provider-capture.test.ts            # S2
    ├── mode-guard.test.ts                  # S3
    ├── protocol.test.ts                    # S4
    ├── bridge-lifecycle.test.ts            # S5/S6
    ├── bridge-lifecycle-wiring.test.ts     # S6
    ├── jsonl-reader.test.ts                # S7
    ├── connection.test.ts                  # S8/S9/S10 (16 tests)
    ├── hello-handler.test.ts               # S9  (factory-pattern precedent)
    ├── handshake-gate.test.ts              # S10
    └── get-suggestions-handler.test.ts     # S11 (closest engine-delegating sibling — model on this)
```

### Desired Codebase tree (files this task touches)

```bash
extension/
├── pi-editor-bridge.ts                          # MODIFY: + factory + narrowing helper + 1 registration line + import add + TODO comment update
└── tests/
    └── apply-completion-handler.test.ts         # CREATE: UNIT (factory) + DISPATCH (gate-open) + ONE REAL (hello→applyCompletion)
```

### Known Gotchas of our codebase & Library Quirks

```ts
// CRITICAL: pi's applyCompletion is SYNCHRONOUS (autocomplete.ts:256-271 interface,
//   autocomplete.ts:375+ impl). It takes NO options/AbortSignal/force and returns
//   {lines,cursorLine,cursorCol} DIRECTLY (not a Promise). The TUI calls it WITHOUT
//   await (editor.ts:669/690/2257). S12's handler MUST be sync to faithfully mirror
//   this — do NOT wrap in async/await, do NOT add AbortController, do NOT add a
//   timeout, do NOT add supersession. Those belong to getSuggestions (S11) ONLY.
//   (research §1.1, §3.)

// CRITICAL: handleLine does `const result = await handler(params,state)`. `await` on
//   a plain object (non-Promise) resolves to that object immediately — a SYNC handler
//   return works UNCHANGED. MethodHandler = `(params,state) => Promise<unknown> | unknown`
//   explicitly allows sync. So returning the result object directly is correct & typed.
//   (research §4; connection.ts MethodHandler.)

// CRITICAL: applyCompletion returns the FULL new buffer (lines:string[]) + new cursor.
//   The caller REPLACES the entire line array. The bridge returns pi's result VERBATIM
//   — it MUST NOT mutate, filter, or 'fix' the lines/cursor. (PRD §7.4, research §1.2.)

// CRITICAL: insertion logic lives ENTIRELY in pi (slash `/cmd ` trailing space, `@file`
//   trailing space for files / none for dirs, quote handling, cursor repositioning).
//   The bridge forwards (…,item,prefix) and returns pi's result. NEVER reimplement
//   insertion. `prefix` is opaque to the bridge (it's whatever the client stored from
//   its getSuggestions response). (PRD §4 step 5, §7.4; research §1.2.)

// CONVENTION: throw BridgeRpcError(-32602, "invalid params: …") for malformed params.
//   -32602 is the reserved JSON-RPC "invalid params" code (protocol.ts §A). This
//   matches S9/S11 precedent (hello throws -32600; getSuggestions throws -32602).
//   handleLine maps a thrown BridgeRpcError → {id,error:{code,message}}.
//   item validation: require value:string + label:string; description is OPTIONAL
//   (AutocompleteItem.description is `?`). (research §2, §5.)
//   DO NOT wrap provider-not-captured / provider-runtime-throws here — that is S15's
//   lane. For S12 let those fall to handleLine's -32603 safety net (keeps pi safe).
//   (research §5; identical boundary to S11.)

// CONVENTION: node:test + jiti (NOT vitest). TAB indentation. Test seams named
//   __xForTest. registerBridgeHandler + __resetHandlersForTest() in EVERY finally
//   (node:test runs sequentially; module registry persists across tests). Model the
//   new test file's imports + helpers on get-suggestions-handler.test.ts (closest
//   sibling). COPY fakeSocket()/parseResponses()/readFirstResponse() VERBATIM (they
//   are LOCAL per-file — NOT exported). (research §6; S11 research §5.)

// GOTCHA: NO setTimeout/clearTimeout used in S12 (no timeout) — so the "typed globals"
//   concern from S11 is irrelevant here. The handler closure holds NO mutable state,
//   so there is nothing to reset/leak. A loop of applyCompletion calls completes
//   promptly with no timers keeping the process alive.

// GOTCHA: to test that the handler is SYNC, assert the return is NOT a Promise
//   (`assert.equal(r instanceof Promise, false)` is too strict — TS `Promise<unknown>
//   | unknown` doesn't forbid it; instead assert the return equals the stub's fixed
//   return value by deepEqual, and separately note sync via the factory's lack of
//   `async`). The functional guarantee (correct result forwarded) is what matters;
//   sync-ness is enforced by the source not using `async`.
```

---

## Implementation Blueprint

### Data models and structure

**No new wire types. No new runtime exports beyond the factory. No new constants.**
S12 consumes:
- `ApplyCompletionParams { lines: string[]; cursorLine: number; cursorCol: number; item: AutocompleteItem; prefix: string }`
  and `ApplyCompletionResult { lines: string[]; cursorLine: number; cursorCol: number }`
  (protocol.ts §C, already defined).
- `AutocompleteItem { value: string; label: string; description?: string }`
  (re-exported from pi-tui via protocol.ts; `description` optional).
- `MethodHandler` (connection.ts) — `(params: unknown, state: ConnectionState) =>
  Promise<unknown> | unknown`; S12 returns a SYNC handler (plain object).
- `BridgeRpcError` (connection.ts) — thrown for `-32602` param errors.
- `getProvider()` (pi-editor-bridge.ts, S2) — the dep closure the factory receives;
  throws a plain `Error` when not yet captured (→ `-32603`).
- `AutocompleteProvider` (pi-tui) — the live chain's `applyCompletion` signature is
  `(lines, cursorLine, cursorCol, item, prefix) => {lines, cursorLine, cursorCol}`
  (SYNC; research §1).

S12 adds ONE module-level export to `pi-editor-bridge.ts`:
- `export function makeApplyCompletionHandler(deps: { getProvider: () => AutocompleteProvider }): MethodHandler;`
and one non-exported helper `narrowApplyCompletionParams(params: unknown): ApplyCompletionParams`.
(No new const — applyCompletion has no timeout.)

### Implementation Tasks (ordered by dependencies)

```yaml
Task 1: MODIFY extension/pi-editor-bridge.ts — add the factory, narrowing helper, registration, and import
  - ADD import: extend the existing
    `import type { HelloParams, HelloResult, GetSuggestionsParams, GetSuggestionsResult } from "./protocol.ts"`
    → also import `ApplyCompletionParams, ApplyCompletionResult`.
  - ADD (non-exported) `narrowApplyCompletionParams(params: unknown): ApplyCompletionParams`
    that validates shape and throws `BridgeRpcError(-32602, "invalid params: …")`
    (code below). Rules: params is a non-null object; `lines` is an Array whose every
    element is `typeof === "string"`; `cursorLine`/`cursorCol` are
    `Number.isInteger(x) && x >= 0`; `item` is a non-null object with `value:string`
    AND `label:string` (description optional — NOT required); `prefix` is a string.
  - ADD: `export function makeApplyCompletionHandler(deps: { getProvider: () =>
    AutocompleteProvider }): MethodHandler` (code below). The handler is SYNC — it
    returns the provider's result object directly (NO `async`, NO AbortController,
    NO timeout, NO closure state). Body: narrow → getProvider (throws if uncaptured)
    → `return provider.applyCompletion(params.lines, params.cursorLine,
    params.cursorCol, params.item, params.prefix)`.
  - ADD registration: in the `session_start` handler, IMMEDIATELY AFTER the
    existing `registerBridgeHandler("getSuggestions", makeGetSuggestionsHandler({...}))`
    call, add `registerBridgeHandler("applyCompletion", makeApplyCompletionHandler({ getProvider }));`.
  - UPDATE the existing `// TODO(S12): register "applyCompletion"; …` comment to
    mark S12 DONE (keep S13/S14/S16 TODOs).
  - UPDATE the file-top STATUS block: add a `STATUS (P1.M2.T6.S12)` note (applyCompletion
    handler registered; sync delegation; no AbortController/timeout; applyCompletion/
    shouldTriggerFileCompletion S13 / ping+bye+getCommands S14 / domain-error wrapping
    S15 remain TODO).
  - DO NOT touch: captureProvider/getProvider bodies, startBridge/stopBridge,
    makeHelloHandler/makeGetSuggestionsHandler, narrowGetSuggestionsParams,
    resolveFdAvailable, the session_shutdown handler, or anything in connection.ts /
    protocol.ts.

Task 2: CREATE extension/tests/apply-completion-handler.test.ts — UNIT/DISPATCH/REAL
  - IMPORTS: model on get-suggestions-handler.test.ts verbatim, PLUS from
    ../pi-editor-bridge.ts: `makeApplyCompletionHandler, makeHelloHandler,
    BRIDGE_VERSION`. Type imports: `AutocompleteItem, AutocompleteProvider` from
    @earendil-works/pi-tui; `ApplyCompletionParams, ApplyCompletionResult` from
    ../protocol.ts IF needed for stub typing. Need `BridgeRpcError` from
    ../connection.ts too.
  - COPY fakeSocket()/parseResponses()/readFirstResponse() VERBATIM from
    get-suggestions-handler.test.ts (they are local helpers, not exported).
  - MODULE-LEVEL: a `makeStubProvider({ ...overrides })` helper returning a plain
    object satisfying `AutocompleteProvider`. The default `applyCompletion` records
    the last `{lines, cursorLine, cursorCol, item, prefix}` it received onto a
    captured `lastCall` object and returns a fixed result
    `{lines:[...], cursorLine, cursorCol}`. Default `getSuggestions` returns null
    (unused; present only to satisfy the interface type). Default
    `shouldTriggerFileCompletion` returns true (unused). Also expose a
    `getLastCall()` accessor.
  - UNIT tests (call the factory directly; fresh `ConnectionState` per test):
    1. HAPPY PATH: stub.applyCompletion returns `{lines:["/model "],cursorLine:0,
       cursorCol:7}` → handler returns it verbatim (deepEqual).
    2. EXACT-ARG THREADING: stub records args; call with lines:["/m"], cursorLine:0,
       cursorCol:2, item:{value:"model",label:"model"}, prefix:"/m" → recorded call
       has ALL FIVE args untouched (deepEqual on the captured {lines,cursorLine,
       cursorCol,item,prefix}).
    3. OPTIONAL-DESCRIPTION PASSTHROUGH: item:{value:"x.ts",label:"x.ts",
       description:"src/x.ts"}, prefix:"@x" → accepted (no throw); forwarded to
       provider with description intact (assert captured item.description ===
       "src/x.ts").
    4. SYNC RETURN: the handler returns the stub's result object directly — assert
       deepEqual(handler(params,state), stubResult) (a sync return; await is a no-op).
       (Optional belt-and-suspenders: confirm the factory does not return an `async`
       function by checking the source uses no `async` keyword — enforced by code
       review, not a runtime assertion.)
    5. PARAM VALIDATION: each invalid shape throws `BridgeRpcError` with code -32602:
       params not an object; lines not an array; lines array with a non-string;
       cursorLine a float / negative / non-number; cursorCol same; item missing
       `value`; item missing `label`; item.value not a string; item not an object;
       prefix not a string (e.g. a number). Assert `err instanceof BridgeRpcError &&
       err.code === -32602` for each. Also assert the provider was NOT called
       (getLastCall() === undefined) on at least one invalid case — proving
       validation short-circuits before delegation.
    6. PROVIDER NOT CAPTURED: `getProvider: () => { throw new Error("not captured"); }`
       → handler throws that plain Error (NOT a BridgeRpcError). (Confirms S12
       leaves this to the -32603 safety net; S15 refines. Mirrors S11's identical
       test.)
  - DISPATCH tests (registerBridgeHandler + fakeSocket + handleLine; pass
    `{ handshakeComplete: true }` so the S10 gate opens; `__resetHandlersForTest`
    in finally):
    7. VALID → SUCCESS: register applyCompletion handler (stub returns
        {lines:["/model "],cursorLine:0,cursorCol:7}); `await handleLine(sock,
        {handshakeComplete:true}, JSON.stringify({jsonrpc:"2.0",id:"a1",
        method:"applyCompletion",params:{lines:["/m"],cursorLine:0,cursorCol:2,
        item:{value:"model",label:"model"},prefix:"/m"}}))`; assert
        parseResponses(writes) === [{jsonrpc:"2.0",id:"a1",result:{lines:["/model "],
        cursorLine:0,cursorCol:7}}].
    8. INVALID PARAMS → -32602: params `{lines:"notarray",cursorLine:0,cursorCol:0,
        item:{value:"x",label:"x"},prefix:"/"}` → exactly one response, code -32602,
        message starts "invalid params:"; provider NOT called.
    9. PRE-HANDSHAKE → -32600 (regression, gate still wins): same valid request
        but `{handshakeComplete:false}` → `-32600 "handshake required: send hello
        first"` AND the provider's applyCompletion is NOT called (getLastCall()
        stays undefined). Locks that the gate fires before the handler.
  - REAL integration (ONE real Unix-socket pair; register hello + applyCompletion):
    10. Register `hello` (makeHelloHandler, fixed TOKEN) AND `applyCompletion`
        (makeApplyCompletionHandler({ getProvider: () => stubProvider })) where
        stubProvider.applyCompletion mimics pi's slash-command insertion: given
        lines,cursorLine,cursorCol,item,prefix with prefix starting "/", returns
        {lines:[`${beforePrefix}/${item.value} ${afterCursor}`],cursorLine,
        cursorCol: beforePrefix.length + item.value.length + 2} (a realistic
        mirror so the wire round-trip is illustrative). createServer((c)=>
        onConnection(c)) → listen(unique tmp sockpath) → connect → (1) hello
        (correct token) ⇒ HelloResult; (2) applyCompletion {lines:["/m"],
        cursorLine:0,cursorCol:2,item:{value:"model",label:"model"},prefix:"/m"}
        ⇒ {id,result:{lines:["/model "],cursorLine:0,cursorCol:7}}. Use
        readFirstResponse(client) BEFORE each client.write(serializeJsonLine(...)).
        __resetHandlersForTest(); server.close(); in finally.

Task 3: VALIDATE (see Validation Loop) — tsc clean; new + all existing suites green;
  connection.ts & protocol.ts diff-clean.
```

### Implementation Patterns & Key Details

```ts
// === Task 1: extension/pi-editor-bridge.ts — the factory + narrowing + registration ===

// (1a) extend the existing protocol import (one line edit):
import type {
	HelloParams,
	HelloResult,
	GetSuggestionsParams,
	GetSuggestionsResult,
	ApplyCompletionParams,
	ApplyCompletionResult,
} from "./protocol.ts";

// (1b) the params narrowing helper (non-exported). Mirrors narrowGetSuggestionsParams
//      + adds item/prefix validation:
function narrowApplyCompletionParams(params: unknown): ApplyCompletionParams {
	const p = params as Partial<ApplyCompletionParams> | null;
	if (!p || typeof p !== "object") {
		throw new BridgeRpcError(-32602, "invalid params: expected an object");
	}
	const { lines, cursorLine, cursorCol, item, prefix } = p;
	if (!Array.isArray(lines) || !lines.every((l) => typeof l === "string")) {
		throw new BridgeRpcError(-32602, "invalid params: lines must be string[]");
	}
	if (
		typeof cursorLine !== "number" ||
		!Number.isInteger(cursorLine) ||
		cursorLine < 0
	) {
		throw new BridgeRpcError(-32602, "invalid params: cursorLine must be a non-negative integer");
	}
	if (
		typeof cursorCol !== "number" ||
		!Number.isInteger(cursorCol) ||
		cursorCol < 0
	) {
		throw new BridgeRpcError(-32602, "invalid params: cursorCol must be a non-negative integer");
	}
	// item: non-null object with value:string + label:string (description optional).
	if (!item || typeof item !== "object") {
		throw new BridgeRpcError(-32602, "invalid params: item must be an object");
	}
	const it = item as Partial<AutocompleteItem>;
	if (typeof it.value !== "string" || typeof it.label !== "string") {
		throw new BridgeRpcError(-32602, "invalid params: item.value and item.label must be strings");
	}
	if (typeof prefix !== "string") {
		throw new BridgeRpcError(-32602, "invalid params: prefix must be a string");
	}
	return { lines, cursorLine, cursorCol, item: it as AutocompleteItem, prefix };
}

// (1c) the factory (LEANER than makeGetSuggestionsHandler — only { getProvider }):
/**
 * Build the `applyCompletion` JSON-RPC handler (PRD §5.4 / §6.5). PURE factory — dep
 * injected so unit tests stub the provider. Delegates to pi's LIVE {@link
 * AutocompleteProvider.applyCompletion} SYNCHRONOUSLY.
 *
 * SYNC, NO TIMING/RESOURCE CONCERNS: unlike getSuggestions (S11), applyCompletion is a
 * pure SYNC function (pi autocomplete.ts:256-271 — verified). It takes NO options/
 * AbortSignal/force and returns the new {lines,cursorLine,cursorCol} directly. The TUI
 * calls it WITHOUT await (editor.ts:669/690/2257). So this handler has NO AbortController,
 * NO supersession (no `pendingAbort`), NO timeout, NO closure state — it is plain
 * delegation. The MethodHandler union (`Promise<unknown> | unknown`) accommodates a sync
 * return; handleLine's `await` is a no-op on a non-Promise.
 *
 * INSERTION IS PI'S JOB: pi's impl computes every insertion edge case (slash `/cmd `
 * trailing space, `@file` trailing space for files / none for dirs, quote handling,
 * cursor repositioning). This handler forwards (…,item,prefix) VERBATIM and returns
 * pi's result UNCHANGED — the bridge never reimplements insertion (PRD §4 step 5).
 *
 * ERRORS: malformed params throw `BridgeRpcError(-32602)` (S9/S11 precedent; -32602 =
 * reserved "invalid params"). `deps.getProvider()` throwing (provider not captured) and
 * any provider RUNTIME throw propagate to `handleLine`'s `-32603` safety net — S15
 * later wraps those. S12 keeps them flowing (keeps pi safe).
 */
export function makeApplyCompletionHandler(deps: {
	getProvider: () => AutocompleteProvider;
}): MethodHandler {
	return (
		_params: unknown,
		_state: ConnectionState,
	): ApplyCompletionResult => {
		const params = narrowApplyCompletionParams(_params);
		const provider = deps.getProvider(); // throws plain Error if not captured → -32603 (S15 refines)
		// SYNC delegation — return pi's full new buffer + cursor VERBATIM.
		return provider.applyCompletion(
			params.lines,
			params.cursorLine,
			params.cursorCol,
			params.item,
			params.prefix,
		);
	};
}

// (1d) registration in session_start — add ONE line after the existing getSuggestions registration:
		registerBridgeHandler(
			"getSuggestions",
			makeGetSuggestionsHandler({ getProvider }),
		);
		registerBridgeHandler(
			"applyCompletion",
			makeApplyCompletionHandler({ getProvider }),
		);
		// TODO(S13): register "shouldTriggerFileCompletion"; (S14): ping/bye/getCommands.
		// TODO(S16): advertise via process.env.PI_EDITOR_BRIDGE (env write is S16's job).

// === Task 2: apply-completion-handler.test.ts — key stub shapes ===

// A stub provider that records the applyCompletion call and returns a fixed result.
function makeRecordingProvider(result: ApplyCompletionResult) {
	let lastCall:
		| {
				lines: string[];
				cursorLine: number;
				cursorCol: number;
				item: AutocompleteItem;
				prefix: string;
		  }
		| undefined;
	const provider: AutocompleteProvider = {
		getSuggestions: async () => null, // unused by S12; present for interface satisfaction
		applyCompletion: (lines, cursorLine, cursorCol, item, prefix) => {
			lastCall = { lines, cursorLine, cursorCol, item, prefix };
			return result;
		},
		shouldTriggerFileCompletion: () => true,
	};
	return { provider, getLastCall: () => lastCall };
}

// UNIT test 2 (exact-arg threading):
const { provider, getLastCall } = makeRecordingProvider({ lines: ["/model "], cursorLine: 0, cursorCol: 7 });
const handler = makeApplyCompletionHandler({ getProvider: () => provider });
const item = { value: "model", label: "model" };
const r = handler({ lines: ["/m"], cursorLine: 0, cursorCol: 2, item, prefix: "/m" }, { handshakeComplete: true });
assert.deepEqual(r, { lines: ["/model "], cursorLine: 0, cursorCol: 7 });
assert.deepEqual(getLastCall(), { lines: ["/m"], cursorLine: 0, cursorCol: 2, item, prefix: "/m" });

// UNIT test 5 (param validation short-circuits BEFORE delegation):
const { provider: rec, getLastCall: recLast } = makeRecordingProvider({ lines: [], cursorLine: 0, cursorCol: 0 });
const h = makeApplyCompletionHandler({ getProvider: () => rec });
assert.throws(
	() => h({ lines: "notarray", cursorLine: 0, cursorCol: 0, item: { value: "x", label: "x" }, prefix: "/" }, { handshakeComplete: true }),
	(err) => err instanceof BridgeRpcError && err.code === -32602,
);
assert.equal(recLast(), undefined, "provider must NOT be called on invalid params");

// DISPATCH test 7 (valid → success):
registerBridgeHandler("applyCompletion", makeApplyCompletionHandler({
	getProvider: () => makeRecordingProvider({ lines: ["/model "], cursorLine: 0, cursorCol: 7 }).provider,
}));
try {
	const { sock, writes } = fakeSocket();
	await handleLine(sock, { handshakeComplete: true }, JSON.stringify({
		jsonrpc: "2.0", id: "a1", method: "applyCompletion",
		params: { lines: ["/m"], cursorLine: 0, cursorCol: 2, item: { value: "model", label: "model" }, prefix: "/m" },
	}));
	assert.deepEqual(parseResponses(writes), [{
		jsonrpc: "2.0", id: "a1",
		result: { lines: ["/model "], cursorLine: 0, cursorCol: 7 },
	}]);
} finally { __resetHandlersForTest(); }

// REAL test 10 (hello → applyCompletion → result over a real socket):
registerBridgeHandler("hello", makeHelloHandler({ getToken: () => TOKEN, getCwd: () => "/tmp", getFdAvailable: () => true, version: BRIDGE_VERSION }));
const stub: AutocompleteProvider = {
	getSuggestions: async () => null,
	// realistic slash-command insertion mirror (illustrative; pi's real impl is the source of truth)
	applyCompletion: (lines, cl, cc, item, prefix) => {
		const line = lines[cl] ?? "";
		const before = line.slice(0, cc - prefix.length);
		const after = line.slice(cc);
		const newLine = `${before}/${item.value} ${after}`;
		const newLines = [...lines]; newLines[cl] = newLine;
		return { lines: newLines, cursorLine: cl, cursorCol: before.length + item.value.length + 2 };
	},
	shouldTriggerFileCompletion: () => true,
};
registerBridgeHandler("applyCompletion", makeApplyCompletionHandler({ getProvider: () => stub }));
const sockpath = join(tmpdir(), `pi-editor-ac-${randomUUID()}.sock`);
const server = createServer((c) => onConnection(c));
server.listen(sockpath);
await once(server, "listening");
try {
	const client = connect(sockpath);
	await once(client, "connect");
	const rH = readFirstResponse(client);
	client.write(serializeJsonLine({ jsonrpc: "2.0", id: "h1", method: "hello", params: { token: TOKEN } }));
	await rH; // HelloResult
	const rA = readFirstResponse(client);
	client.write(serializeJsonLine({ jsonrpc: "2.0", id: "a1", method: "applyCompletion", params: { lines: ["/m"], cursorLine: 0, cursorCol: 2, item: { value: "model", label: "model" }, prefix: "/m" } }));
	const got = (await rA) as { id: string; result: { lines: string[]; cursorLine: number; cursorCol: number } };
	assert.equal(got.id, "a1");
	assert.deepEqual(got.result, { lines: ["/model "], cursorLine: 0, cursorCol: 7 });
	client.destroy();
} finally { __resetHandlersForTest(); server.close(); }
```

### Integration Points

```yaml
SESSION LIFECYCLE (pi-editor-bridge.ts):
  - session_start: captureProvider (S2) → startBridge (S5) → cwd = ctx.cwd →
    register hello (S9) → register getSuggestions (S11) → **register applyCompletion
    (S12, NEW)** → [S13+ …]. All BELOW the `if (ctx.mode !== "tui") return;` guard
    (inherited protection).
  - session_shutdown: stopBridge (unchanged). No applyCompletion-specific teardown
    (the handler holds no socket/fs/timer resource — it is pure stateless delegation).
    A session_shutdown mid-call is impossible (the call is synchronous and completes
    within handleLine's microtask).

CONNECTION DISPATCH (connection.ts): UNCHANGED. handleLine's REQUEST branch already
  `await`s the handler (a no-op on a sync return) and sends `{id,result}`; a thrown
  BridgeRpcError → `{id,error:{code,message}}`; any other throw → `-32603`. The S10
  gate already blocks applyCompletion pre-hello. S12 is PURELY a new handler
  registration.

PROTOCOL (protocol.ts): CONSUMED, not modified. ApplyCompletionParams/Result are
  already defined (§C); AutocompleteItem is re-exported from pi-tui (byte-identical
  wire shape).

DOWNSTREAM:
  - S13 (shouldTriggerFileCompletion) will reuse this lean factory shape (sync
    delegation; `{ getProvider }` only; returns a boolean). S14 (ping/bye/getCommands)
    are simpler still.
  - S15 (domain-error wrapping): wraps the provider-not-captured + provider-runtime-
    throw paths S12 currently leaves to the -32603 net. Designing S12's factory with
    `deps.getProvider` callable separately (not inlined) makes the S15 refinement a
    one-line wrap.
  - P2.M7.T19.S32 (Neovim accept flow): the client sends applyCompletion and applies
    the result via `nvim_buf_set_lines(0, 0, -1, false, result.lines)` + cursor
    reposition (PRD §7.4). S12 is the server counterpart that returns exactly that.
```

---

## Validation Loop

### Level 1: Syntax & Type (after the source edit)

```bash
cd /home/dustin/projects/pi-nvim-bridge
tsc --noEmit -p extension/tsconfig.json
# Expected: exit 0, NO output. (TS 5.9.3 baseline — verified clean pre-write. No setTimeout/
# AbortController used in S12, so no typed-global concerns. AutocompleteProvider.applyCompletion
# is sync in pi-tui's types, so returning its result directly satisfies MethodHandler's
# `Promise<unknown> | unknown` union.)
```

### Level 2: Unit / component tests (node:test + jiti — NOT vitest)

```bash
JITI_REG=/home/dustin/.local/lib/node_modules/@earendil-works/pi-coding-agent/node_modules/jiti/lib/jiti-register.mjs

# The NEW applyCompletion suite (UNIT + DISPATCH + ONE REAL)
node --import "$JITI_REG" extension/tests/apply-completion-handler.test.ts
# Expected: exit 0, `ℹ fail 0`. (jiti prints a benign DeprecationWarning on Node 26
# stderr — judge by exit code + the `ℹ pass`/`ℹ fail` summary, ignore the warning.)

# Regression: the gate still wins pre-handshake (handshake-gate suite)
node --import "$JITI_REG" extension/tests/handshake-gate.test.ts
# Expected: exit 0, `ℹ fail 0`.

# Regression: getSuggestions handler (unchanged; applyCompletion registration is additive)
node --import "$JITI_REG" extension/tests/get-suggestions-handler.test.ts
# Expected: exit 0, `ℹ tests 15`, `ℹ pass 15`, `ℹ fail 0`.

# Regression: hello handler (unchanged; additive registration)
node --import "$JITI_REG" extension/tests/hello-handler.test.ts
# Expected: exit 0, `ℹ fail 0`.

# Regression: connection dispatch (16 tests) — applyCompletion dispatch is via the
# SAME handleLine; no dispatch code changed.
node --import "$JITI_REG" extension/tests/connection.test.ts
# Expected: `ℹ tests 16`, `ℹ pass 16`, `ℹ fail 0`.

# Full extension suite (no S2–S11 regressions)
for t in extension/tests/*.test.ts; do
  echo "--- $t"
  node --import "$JITI_REG" "$t" 2>/dev/null | grep -E "^ℹ (tests|pass|fail)"
done
# Expected: every file `ℹ fail 0`.
```

### Level 3: Integration (a real socket pair — applyCompletion end-to-end)

```bash
# Driven by the real-socket test #10 inside apply-completion-handler.test.ts. To
# eyeball the wire by hand (optional): hello → applyCompletion("/m") → result.
JITI_REG=/home/dustin/.local/lib/node_modules/@earendil-works/pi-coding-agent/node_modules/jiti/lib/jiti-register.mjs
node --import "$JITI_REG" -e '
  const { createServer, connect } = require("node:net");
  const { join } = require("node:path"), { tmpdir } = require("node:os"), { randomUUID } = require("node:crypto");
  const { onConnection, registerBridgeHandler } = await import("./extension/connection.ts");
  const { makeHelloHandler, makeApplyCompletionHandler, BRIDGE_VERSION } = await import("./extension/pi-editor-bridge.ts");
  const { serializeJsonLine, attachJsonlLineReader } = await import("./extension/jsonl-reader.ts");
  const TOKEN = "deadbeef".repeat(4);
  const stub = { getSuggestions: async () => null, applyCompletion: (lines, cl, cc, item, prefix) => { const line = lines[cl] ?? ""; const before = line.slice(0, cc - prefix.length); const after = line.slice(cc); const ns = [...lines]; ns[cl] = `${before}/${item.value} ${after}`; return { lines: ns, cursorLine: cl, cursorCol: before.length + item.value.length + 2 }; }, shouldTriggerFileCompletion: () => true };
  registerBridgeHandler("hello", makeHelloHandler({ getToken:()=>TOKEN, getCwd:()=>"/tmp", getFdAvailable:()=>true, version:BRIDGE_VERSION }));
  registerBridgeHandler("applyCompletion", makeApplyCompletionHandler({ getProvider:()=>stub }));
  const sockpath = join(tmpdir(), `ac-${randomUUID()}.sock`);
  const s = createServer(c=>onConnection(c)); s.listen(sockpath);
  s.once("listening", ()=>{
    const cli = connect(sockpath);
    const read = () => new Promise(res=>{ const d=attachJsonlLineReader(cli,l=>{d();res(JSON.parse(l))}); });
    cli.once("connect", async ()=>{
      cli.write(serializeJsonLine({jsonrpc:"2.0",id:"h1",method:"hello",params:{token:TOKEN}}));
      console.log("hello:", JSON.stringify(await read()));
      cli.write(serializeJsonLine({jsonrpc:"2.0",id:"a1",method:"applyCompletion",params:{lines:["/m"],cursorLine:0,cursorCol:2,item:{value:"model",label:"model"},prefix:"/m"}}));
      console.log("/m+model:", JSON.stringify(await read()));
      cli.destroy(); s.close();
    });
  });
'
# Expected:
#   hello:     {"jsonrpc":"2.0","id":"h1","result":{"ok":true,"serverVersion":"0.1.0","cwd":"/tmp","fdAvailable":true}}
#   /m+model:  {"jsonrpc":"2.0","id":"a1","result":{"lines":["/model "],"cursorLine":0,"cursorCol":7}}
```

### Level 4: Domain-specific validation (correctness invariants)

```bash
# (a) Params forwarded UNTOUCHED — asserted in UNIT test #2 (deepEqual on captured
#     {lines,cursorLine,cursorCol,item,prefix}).
# (b) Result returned VERBATIM (full buffer + cursor) — asserted in UNIT test #1 +
#     DISPATCH test #7 + REAL test #10 (deepEqual on result).
# (c) Param validation short-circuits BEFORE delegation — asserted in UNIT test #5
#     (getLastCall() === undefined on an invalid-params path).
# (d) item.description OPTIONAL — asserted in UNIT test #3 (an item without
#     description is accepted and forwarded; an item WITH description is forwarded
#     with description intact).
# (e) Token value never appears in any applyCompletion response/stderr (PRD §12) —
#     the applyCompletion result carries only lines/cursor; grep the run:
JITI_REG=/home/dustin/.local/lib/node_modules/@earendil-works/pi-coding-agent/node_modules/jiti/lib/jiti-register.mjs
SECRET="deadbeefdeadbeefdeadbeefdeadbeef"
node --import "$JITI_REG" extension/tests/apply-completion-handler.test.ts 2>&1 | grep -c "$SECRET" || true
# Expected: 0 in RESULT payloads (the token only appears in the hello request the
# test itself sends, never in an applyCompletion response — assert specifically that
# no line where method:"applyCompletion"/result co-occurs contains the secret; the
# simple grep above is a coarse sanity check; the dedicated assertion lives in the test.)
```

---

## Final Validation Checklist

### Technical Validation
- [ ] `tsc --noEmit -p extension/tsconfig.json` ⇒ exit 0, no output.
- [ ] `node --import "$JITI_REG" extension/tests/apply-completion-handler.test.ts` ⇒ exit 0, `ℹ fail 0`.
- [ ] `node --import "$JITI_REG" extension/tests/handshake-gate.test.ts` ⇒ `ℹ fail 0` (gate still wins pre-handshake).
- [ ] `node --import "$JITI_REG" extension/tests/get-suggestions-handler.test.ts` ⇒ `ℹ tests 15`, `ℹ fail 0` (additive registration).
- [ ] `node --import "$JITI_REG" extension/tests/hello-handler.test.ts` ⇒ `ℹ fail 0` (additive registration).
- [ ] `node --import "$JITI_REG" extension/tests/connection.test.ts` ⇒ `ℹ tests 16`, `ℹ fail 0`.
- [ ] Every `extension/tests/*.test.ts` ⇒ `ℹ fail 0` (no S2–S11 regressions).

### Feature Validation
- [ ] Valid post-handshake `applyCompletion` ⇒ live provider's result verbatim (`{lines,cursorLine,cursorCol}`).
- [ ] All five params (`lines`, `cursorLine`, `cursorCol`, `item`, `prefix`) forwarded to the provider untouched.
- [ ] Handler is SYNCHRONOUS (returns the result object directly; no `async`/AbortController/timeout).
- [ ] `item` with NO `description` accepted (description optional); `item` WITH `description` forwarded intact.
- [ ] Malformed params ⇒ exactly one `-32602 "invalid params: …"` with the request id; provider NOT called.
- [ ] Pre-handshake `applyCompletion` ⇒ still `-32600` (S10 gate; provider NOT called).
- [ ] Provider-not-captured ⇒ `-32603` (safety net; not wrapped by S12).
- [ ] Token value never present in any `applyCompletion` response (PRD §12).

### Code Quality
- [ ] Factory mirrors `makeGetSuggestionsHandler`/`makeHelloHandler` (deps-injection; pure factory returning a `MethodHandler`) but is LEANER — only `{ getProvider }` dep.
- [ ] Handler is SYNC (no `async`, no AbortController, no `pendingAbort`, no `setTimeout`/`clearTimeout`, no `timeoutMs`).
- [ ] Params narrowing throws `BridgeRpcError(-32602)` (S9/S11 precedent; reserved code); `item` validation requires `value`+`label` (strings) and accepts optional `description`.
- [ ] Provider-not-captured / provider-runtime-throws left to the `-32603` safety net (NOT wrapped — S15's lane).
- [ ] Result returned VERBATIM (the bridge never mutates/filters pi's new buffer + cursor).
- [ ] Registration added AFTER the existing `getSuggestions` registration; BELOW the TUI-mode guard.
- [ ] TAB indentation, `node:test` + `assert/strict` + jiti (NOT vitest); `fakeSocket`/`parseResponses`/`readFirstResponse` copied verbatim; `__resetHandlersForTest()` in EVERY finally.
- [ ] File-top STATUS block + the `TODO(S12)` comment updated to mark S12 done (repo convention of accurate cross-task comments).

### Scope Discipline (did NOT bleed into other tasks)
- [ ] `extension/connection.ts` UNCHANGED (verify: `git diff --stat extension/connection.ts` ⇒ empty).
- [ ] `extension/protocol.ts` UNCHANGED (verify: `git diff --stat extension/protocol.ts` ⇒ empty).
- [ ] No S13 (shouldTriggerFileCompletion) / S14 (ping/bye/getCommands) registrations.
- [ ] No domain-error wrapping added (that is S15's lane) — provider-not-captured + runtime throws flow to the `-32603` net.

---

## Anti-Patterns to Avoid

- ❌ **Don't copy S11's AbortController/timeout/supersession into applyCompletion.**
  pi's `applyCompletion` is SYNC and takes no signal (verified). Adding an
  AbortController/timeout/pendingAbort would be dead code that misrepresents the
  contract. S12 is the LEAN handler.
- ❌ **Don't reimplement insertion logic** (trailing spaces, quotes, cursor math).
  Forward `(…,item,prefix)` and return pi's result verbatim — pi owns insertion.
- ❌ **Don't make the handler `async`.** It returns a plain object; `MethodHandler`'s
  union allows sync and `handleLine`'s `await` is a no-op on a non-Promise. `async`
  would falsely imply in-flight resource management exists.
- ❌ **Don't mutate pi's result.** Return it exactly as the provider returns it — the
  client replaces its ENTIRE buffer with `result.lines`.
- ❌ **Don't require `item.description`.** It's optional on `AutocompleteItem`; validate
  only `value` + `label`.
- ❌ **Don't wrap provider-not-captured / runtime throws into a specific code here.**
  That's S15's lane; S12 lets them flow to the `-32603` safety net (keeps pi safe).
- ❌ **Don't skip validation because "it should work".** Params are `unknown` from the
  wire — narrow defensively with `-32602` (S9/S11 precedent).
- ❌ **Don't catch all exceptions broadly.** Throw the specific `BridgeRpcError(-32602)`
  for param errors; let everything else propagate to `handleLine`'s typed nets.
