name: "P1.M2.T6.S13 — shouldTriggerFileCompletion handler (synchronous delegation to pi's OPTIONAL provider method, default true)"
description: "pi-editor-bridge extension (TS). Register the `shouldTriggerFileCompletion` JSON-RPC handler as a deps-injected factory (`makeShouldTriggerFileCompletionHandler`) that SYNCHRONOUSLY delegates to pi's LIVE AutocompleteProvider.shouldTriggerFileCompletion — an OPTIONAL, synchronous method `(lines, cursorLine, cursorCol) => boolean`. Because the method is OPTIONAL on the interface (autocomplete.ts:269 — the `?`), the handler MUST use optional chaining `?.` + nullish coalescing `?? true` (pi's own canonical pattern, replicated identically in pi tests/docs/examples AND the PRD §6.5 skeleton): `return provider.shouldTriggerFileCompletion?.(lines, cursorLine, cursorCol) ?? true;`. The `?? true` default is semantically meaningful — 'if the provider doesn't decide, ALLOW file completion' — and must NOT be dropped or flipped. Like S12 (applyCompletion), this handler is SYNC, needs NO AbortController, NO supersession, NO timeout, NO closure state. It is the LEANEST handler in the M2.T6 family: params are just {lines, cursorLine, cursorCol} (3 fields — no item/prefix), result is a plain `boolean`. Narrow params to `BridgeRpcError(-32602)` on malformed shape (lines:string[], non-negative-integer cursorLine/cursorCol — matches S11/S12 precedent). Provider-not-captured + runtime throws propagate to handleLine's `-32603` safety net (S15 refines). No change to connection.ts (its `-32603` net + BridgeRpcError + sync-return support already cover this) or protocol.ts (ShouldTriggerFileCompletionParams/ShouldTriggerFileCompletionResult already defined in §C). New `should-trigger-file-completion-handler.test.ts` (UNIT/DISPATCH/REAL three layers). node:test + jiti (NOT vitest). Downstream consumer: P2.M7.T20.S33 (Neovim Tab handler) consults this RPC as the gate before issuing a forced getSuggestions."

---

## Goal

**Feature Goal**: Land the third completion-engine RPC handler. When an
authenticated Neovim client presses `<Tab>` with no completion menu open (the
"force file completion" gesture, PRD §7.4 / §7.6), it first asks the bridge
whether pi would *allow* forced file completion at the current cursor by sending
`shouldTriggerFileCompletion(lines, cursorLine, cursorCol)`. The bridge
**synchronously** delegates to pi's **live** `AutocompleteProvider.shouldTriggerFileCompletion`
and returns pi's `boolean` verbatim — exactly as pi's own TUI editor gates its
`force:true` autocomplete path (`editor.ts:2148-2158`). Because pi's concrete
impl (`autocomplete.ts:775-785`) returns `false` precisely when the user is
typing a bare slash command at line start (e.g. `/set` before any space) and
`true` otherwise, the bridge's Tab behavior becomes byte-identical to the TUI's
(PRD §11 "force file completion on empty line must respect
shouldTriggerFileCompletion"). The bridge NEVER reimplements the gate logic.

**Deliverable**:
1. `extension/pi-editor-bridge.ts` — ADD:
   - `makeShouldTriggerFileCompletionHandler(deps: { getProvider })` factory
     (mirrors the `makeHelloHandler`/`makeApplyCompletionHandler` deps-injection
     pattern from S9/S12) returning a `MethodHandler`. **The handler is SYNC** —
     it returns a `boolean` directly (NOT `async`/NOT a Promise), faithfully
     mirroring pi's own sync contract. There is NO closure state (no
     `pendingAbort`, no `timeoutMs`) — shouldTriggerFileCompletion has no
     supersession/timing concerns. The single load-bearing line is
     `return provider.shouldTriggerFileCompletion?.(params.lines, params.cursorLine, params.cursorCol) ?? true;`
     — the `?.` (method is OPTIONAL on the interface) + `?? true` (pi's
     documented default: absent method ⇒ allow file completion).
   - A private `narrowShouldTriggerFileCompletionParams(params)` helper that
     validates `lines:string[]` and `cursorLine`/`cursorCol` (non-negative
     integers), and throws `BridgeRpcError(-32602, "invalid params: …")` on any
     malformed shape (matches S9/S11/S12 precedent; `-32602` = reserved "invalid
     params").
   - One new `registerBridgeHandler("shouldTriggerFileCompletion", makeShouldTriggerFileCompletionHandler({ getProvider }))`
     line in the `session_start` handler, immediately AFTER the existing
     `applyCompletion` `registerBridgeHandler` call (S12) and BEFORE the
     `TODO(S13)` comment.
   - Extend the existing
     `import type { HelloParams, HelloResult, GetSuggestionsParams, GetSuggestionsResult, ApplyCompletionParams, ApplyCompletionResult }`
     from `./protocol.ts` to ALSO import
     `ShouldTriggerFileCompletionParams, ShouldTriggerFileCompletionResult`.
   - Update the existing `TODO(S13)` comment to mark S13 DONE (keep S14/S16
     TODOs).
   - Update the file-top STATUS block: add a `STATUS (P1.M2.T6.S13)` note.
2. `extension/tests/should-trigger-file-completion-handler.test.ts` (NEW) —
   three layers: UNIT (factory directly with a stub provider: true/false
   passthrough, the **OPTIONAL-method ⇒ true** default via a provider WITHOUT
   the method, exact-arg threading, sync return, param validation,
   provider-not-captured), DISPATCH (registerBridgeHandler + `fakeSocket` +
   `handleLine`, `{ handshakeComplete: true }` for the gated happy path;
   pre-handshake ⇒ `-32600` regression), and ONE REAL Unix-socket integration
   test (hello → shouldTriggerFileCompletion → boolean over a real socket).

**Success Definition**: With the bridge running and a client authenticated via
`hello`, a `shouldTriggerFileCompletion` request returns the live provider's
`boolean` verbatim (`{jsonrpc,id,result:true}` or `…,result:false}`) — and when
the captured provider does NOT implement the optional method, the handler
returns `true` (the documented default). The Neovim client (P2.M7.T20.S33) then
consults this boolean to decide whether to issue a forced `getSuggestions`.
Malformed params yield `-32602`. Pre-handshake yields `-32600` (S10 gate,
unchanged). Provider-not-captured yields `-32603` (safety net; S15 refines).
`tsc --noEmit` is clean; the new suite passes; **all 11 existing extension
suites stay green** (S2–S12); `connection.ts` and `protocol.ts` are UNCHANGED.

---

## User Persona

**Target User**: The `pi-editor.nvim` Neovim plugin (P2.M5 / P2.M7) — the
bridge's only client. (Indirectly: the human editing a pi prompt in their
`$EDITOR`.)

**Use Case**: The user presses `<Tab>` in the prompt buffer with NO completion
menu open, intending to force file/path completion (mirroring pi's TUI Tab
behavior). The Neovim client captures the current buffer `lines` + cursor
(0-indexed line, UTF-16 col per PRD §8) and sends `shouldTriggerFileCompletion`
to the bridge. If the bridge returns `true`, the client issues a forced
`getSuggestions(..., { force: true })` (S11) and shows the file completions; if
`false`, it does nothing (pi is telling it "you're typing a slash command, don't
force files here"). The bridge forwards to pi's live provider, which applies the
exact same gate the TUI uses (`/set` → `false`; `hello wor` → `true`).

**Pain Points Addressed**: The external editor's `<Tab>` respects pi's *actual*
"should I force file completion here?" gate — NOT a fragile reimplementation.
Because pi's gate lives in one place (`autocomplete.ts:775`), delegating means
the bridge carries NONE of that logic and cannot drift from the TUI.

---

## Why

- **Third engine-delegating handler; completes the Tab/force gate.** S11
  (getSuggestions) is the *offer* half; S12 (applyCompletion) is the *accept*
  half; S13 is the *force gate* that Tab consults before offering. Together the
  three make the bridge a complete completion conduit — the Neovim Tab gesture is
  gated exactly as the TUI's is.
- **Byte-identical force-gating, zero reimplementation.** pi's
  `shouldTriggerFileCompletion` is the single source of truth for "don't force
  files while typing `/set`" (PRD §11). Delegating means the bridge carries NONE
  of that logic — it forwards and returns the boolean verbatim.
- **Structurally the LEANEST engine handler.** Unlike getSuggestions (async, fd,
  AbortController, supersession, timeout, force) and even applyCompletion (5
  params + an object result), shouldTriggerFileCompletion has **3 params, a
  boolean result, and no resource concerns** (verified §1). S13 therefore has NO
  timing/resource concerns — no fd to SIGKILL, no timeout to arm, no in-flight
  call to supersede. The factory is the leanest in the M2.T6 family: a single
  `{ getProvider }` dep.
- **The one nuance: an OPTIONAL method with a `true` default.** Unlike
  getSuggestions/applyCompletion (both REQUIRED on the interface),
  `shouldTriggerFileCompletion` is marked OPTIONAL (`autocomplete.ts:269`). The
  handler MUST use `?.` (a direct call throws `TypeError` on a provider without
  the method) and `?? true` (pi's documented default — absent method ⇒ allow
  file completion). pi itself uses this exact `?.` + `?? true` pattern in 5
  places (tests, docs, examples, and the PRD §6.5 skeleton) — the bridge
  replicates it verbatim.
- **Mirrors the client's model (P2.M7.T20.S33).** The Neovim Tab flow is
  `shouldTriggerFileCompletion` RPC → if `true`, forced `getSuggestions`. S13 is
  the server-side counterpart that hands back exactly the boolean the client
  branches on.

---

## What

### User-visible behavior (wire)

| Client sends (post-`hello`) | Server action & response |
|---|---|
| `shouldTriggerFileCompletion {lines:[...], cursorLine, cursorCol}` (valid; provider implements the method) | **Synchronously** delegate to `liveProvider.shouldTriggerFileCompletion(lines, cursorLine, cursorCol)` (a sync method). Reply `{jsonrpc,id,result:<boolean>}` — pi's boolean verbatim. E.g. `/set` at col 4 ⇒ `result:false`; `hello wor` at col 9 ⇒ `result:true`. |
| `shouldTriggerFileCompletion {...}` where the captured provider does NOT implement the optional method (a thin custom wrapper) | Delegate via optional chaining: `provider.shouldTriggerFileCompletion?.(...)` short-circuits to `undefined`; the `?? true` default yields `true`. Reply `{jsonrpc,id,result:true}`. (pi's documented default: absent method ⇒ allow file completion.) |
| malformed params (lines not string[]; cursorLine/cursorCol not non-negative integers; params not an object) | `BridgeRpcError(-32602, "invalid params: …")` → `handleLine` maps to `{"id","error":{"code":-32602,"message":"invalid params: …"}}`. The provider is NOT called. |
| `shouldTriggerFileCompletion` before `hello` | (Unchanged — S10 gate) `-32600 "handshake required: send hello first"`. |
| `shouldTriggerFileCompletion` when provider not yet captured | `getProvider()` throws plain `Error` → `handleLine` `-32603` safety net. (S15 may later refine to a specific code; S13 leaves the safety net — it keeps pi safe.) |
| provider's `shouldTriggerFileCompletion` throws (a misbehaving wrapper) | `handleLine` `-32603` safety net (unchanged). |

### Success Criteria

- [ ] `shouldTriggerFileCompletion` (valid, post-handshake, provider implements
      the method) returns the live provider's boolean verbatim
      (`{jsonrpc,id,result:true}` or `{jsonrpc,id,result:false}`).
- [ ] When the captured provider does NOT implement the optional method, the
      handler returns `true` (the `?? true` default) — proves the `?.` optional
      chaining works and matches pi's documented default.
- [ ] All three params (`lines`, `cursorLine`, `cursorCol`) are forwarded to the
      provider **untouched** (the provider receives exactly what the client sent).
- [ ] The handler is **synchronous** — it returns a `boolean` directly (NOT
      wrapped in a Promise); `MethodHandler`'s `Promise<unknown> | unknown` union
      accommodates this and `handleLine`'s `await` is a no-op on a non-Promise.
- [ ] Malformed params ⇒ exactly one `-32602 "invalid params: …"` response with the
      request id; the provider is NOT called.
- [ ] Pre-handshake `shouldTriggerFileCompletion` ⇒ still `-32600` (S10 gate,
      unchanged).
- [ ] Provider-not-captured ⇒ `-32603` (safety net; S13 does not wrap it).
- [ ] `tsc --noEmit -p extension/tsconfig.json` ⇒ exit 0, no output.
- [ ] New `should-trigger-file-completion-handler.test.ts` passes (`ℹ fail 0`);
      every other `extension/tests/*.test.ts` ⇒ `ℹ fail 0` (no S2–S12 regressions).
- [ ] `extension/connection.ts` and `extension/protocol.ts` are UNCHANGED
      (verify: `git diff --stat extension/connection.ts extension/protocol.ts` ⇒ empty).

---

## All Needed Context

### Context Completeness Check

_"If someone knew nothing about this codebase, would they have everything needed
to implement this successfully?"_ — Yes. This PRP pins the exact factory shape
(from PRD §6.5's skeleton, which is the `?.` + `?? true` one-liner), the exact
sync + optional-method contract (verified against pi source: interface at
autocomplete.ts:269 with the `?`; impl at autocomplete.ts:775 sync; TUI call at
editor.ts:2148-2158), the exact param-narrowing rules + `-32602` codes, the exact
registration site (after the existing `applyCompletion` `registerBridgeHandler`),
the verbatim test helpers to copy (`fakeSocket`/`parseResponses`/`readFirstResponse`),
the exact three-layer test shape proven by 4 sibling suites, and the verified
test commands. No guessing.

### Documentation & References

```yaml
# MUST READ — the governing spec
- url: PRD §6.5 (Request handling skeleton) + §5.4 (methods table) + §11 (shouldTriggerFileCompletion edge case) + §7.4 (completion.lua Tab flow)
  why: "§6.5 is the AUTHORITATIVE shouldTriggerFileCompletion skeleton — and CRUCIALLY it is the SYNC one-liner: `shouldTriggerFileCompletion({ lines, cursorLine, cursorCol }) { requireProvider(); return liveProvider!.shouldTriggerFileCompletion?.(lines, cursorLine, cursorCol) ?? true; }` — NO async, NO AbortController, NO setTimeout, NO pendingAbort. The `?.` + `?? true` is LOAD-BEARING: the method is OPTIONAL on the interface, and the documented default is `true`. §5.4 defines the params (lines/cursorLine/cursorCol) + result (bool). §11 documents the semantics ('force file completion on empty line must respect shouldTriggerFileCompletion'). §7.4 documents the Neovim Tab flow that consumes the result (consult gate → if true, force getSuggestions)."
  critical: "PRD §6.5's shouldTriggerFileCompletion skeleton is a near-verbatim implementation spec. The ONLY deviation this PRP makes is encapsulating it in a deps-injected FACTORY (matching S9/S12) instead of a module-level handler, and adding params narrowing with BridgeRpcError(-32602). Do NOT drop the `?.` (method is OPTIONAL — a direct call throws TypeError on a provider without it) and do NOT drop/flip the `?? true` (it is pi's documented default: absent method ⇒ ALLOW file completion)."

# MUST READ — the file this task edits (READ BEFORE EDITING)
- file: extension/pi-editor-bridge.ts
  why: "The home of makeApplyCompletionHandler (the LEANEST sibling factory to mirror — same `{ getProvider }` dep, same SYNC handler, same narrowXxxParams helper shape), getProvider() (the deps.getProvider the factory receives), narrowApplyCompletionParams (the 3-field params narrowing to mirror — S13 is even simpler: no item/prefix, just lines/cursorLine/cursorCol), BRIDGE_VERSION/startBridge/stopBridge (lifecycle context), and the session_start handler where registration is ADDED. Its makeApplyCompletionHandler JSDoc + narrowApplyCompletionParams code IS the precedent for S13."
  pattern: "makeApplyCompletionHandler(deps:{getProvider}) => MethodHandler — a PURE factory, deps are getter closures so tests stub them. S13 is the IDENTICAL-shape sibling: makeShouldTriggerFileCompletionHandler(deps:{getProvider}) — ONLY getProvider (no timeoutMs, no AbortController, no closure state). The factory returns a SYNC handler `(params,state) => boolean` (NOT async)."
  gotcha: "Imports: AutocompleteProvider ALREADY imported from @earendil-works/pi-tui. BridgeRpcError/MethodHandler/ConnectionState ALREADY imported from ./connection.ts. ADD ShouldTriggerFileCompletionParams/ShouldTriggerFileCompletionResult to the existing `import type { ... } from \"./protocol.ts\"`. Register the handler AFTER the existing `applyCompletion` `registerBridgeHandler` call (provider capture + token both already exist by then)."

- file: extension/connection.ts
  why: "CONFIRMS S13 needs NO change here. MethodHandler is already `(params,state) => Promise<unknown> | unknown` — a SYNC return (a boolean) is legal. handleLine's REQUEST branch already does `const result = await handler(params,state); sendResponse(sock,reqId,result)` — `await` on a non-Promise (a boolean) resolves to that boolean immediately, so a sync handler works unchanged. It already maps a thrown BridgeRpcError → `{id,error:{code,message}}` and any other throw → `-32603`. The S10 handshake gate already blocks shouldTriggerFileCompletion pre-hello."
  pattern: "handleLine is fire-and-forget per line. shouldTriggerFileCompletion being sync means it completes within one microtask — no in-flight concerns, no resource to clean up. This is the structural reason S13 has NO supersession (like S12, unlike S11): a sync call cannot be 'in-flight' alongside another."
  gotcha: "DO NOT EDIT connection.ts. The -32603 safety net + BridgeRpcError handling already cover every throw path S13 can produce. registerBridgeHandler is MODULE-LEVEL (shared across connections) — one shouldTriggerFileCompletion handler instance per session (pure delegation, no shared mutable state)."

- file: extension/protocol.ts
  why: "CONSUME the already-defined ShouldTriggerFileCompletionParams {lines:string[]; cursorLine:number; cursorCol:number} and ShouldTriggerFileCompletionResult = boolean (§C, already defined — the params are IDENTICAL to a 3-field slice of GetSuggestionsParams/ApplyCompletionParams; result is a bare `boolean` type alias). CONFIRMS cursorLine is 0-indexed, cursorCol is a 0-indexed UTF-16 offset (conversion lives in the Lua coords module P2.M6 — the bridge passes numbers through untouched)."
  gotcha: "protocol.ts is TYPES-ONLY (zero runtime exports). S13 adds NO type to protocol.ts. ShouldTriggerFileCompletionResult is a plain `type ... = boolean` — the wire value is a JSON `true`/`false`, never null/undefined/object."

- file: extension/tests/get-suggestions-handler.test.ts
  why: "the CLOSEST, cleanest sibling suite — model the new test file's imports block + helpers + REAL-socket shape on it (it is the most representative engine-delegating sibling: it exercises an engine-delegating handler end-to-end and shows the full three-layer pattern). It shows: combined `{ EventEmitter, once }`, explicit .ts import extensions, the registerBridgeHandler+__resetHandlersForTest-in-finally hygiene, AutocompleteItem/AutocompleteProvider type imports from @earendil-works/pi-tui, and the hello-first REAL-socket template."
  pattern: "Imports: from ../connection.ts (handleLine, onConnection, registerBridgeHandler, __resetHandlersForTest, BridgeRpcError, type ConnectionState) + from ../pi-editor-bridge.ts (makeHelloHandler, makeShouldTriggerFileCompletionHandler, BRIDGE_VERSION) + from ../jsonl-reader.ts (attachJsonlLineReader, serializeJsonLine) + type imports from @earendil-works/pi-tui. COPY fakeSocket()/parseResponses()/readFirstResponse() VERBATIM (they are LOCAL per-file, not exported — connection.test.ts, hello-handler.test.ts, handshake-gate.test.ts, get-suggestions-handler.test.ts, apply-completion-handler.test.ts each re-declare them identically)."
  gotcha: "readFirstResponse(client) MUST be called BEFORE client.write(...) (attach the one-shot reader first, then write, then await). Repeat per response in the REAL test. Dispatch tests pass `{ handshakeComplete: true }` so the S10 gate lets shouldTriggerFileCompletion through."

# Prior plan context (READ for rationale; do NOT copy code blindly)
- docfile: plan/001_c56962b4fa17/P1M2T6S13/research/notes.md
  section: "§1 (the OPTIONAL+SYNC contract + the canonical `?.`+`?? true` pattern with 5 pi sources), §2 (what the concrete impl checks, for realistic test inputs), §3 (TUI call site — force:true path only), §7 (S13 vs S12 comparison table)"
  why: "the WHY behind every non-obvious choice — esp. WHY the method is OPTIONAL and the handler MUST use `?.` (autocomplete.ts:269 has the `?`; a direct call throws TypeError on a provider without it), WHY the default is `true` (pi's own tests/docs/examples all use `?? true` — absent method ⇒ allow file completion), WHY the handler is SYNC (mirrors pi's own contract + MethodHandler accommodates sync), and WHY S13 is even leaner than S12 (3 params + boolean result)."
- docfile: plan/001_c56962b4fa17/P1M2T6S11/research/notes.md
  section: "§4 (S11 vs S15 error-wrapping boundary — IDENTICAL for S13), §5 (test conventions — IDENTICAL for S13)"
  why: "establishes the S15 error-wrapping boundary (S13 leaves provider-not-captured + runtime throws to the -32603 net, same as S11/S12) and the verbatim test conventions S13 reuses."
```

### Current Codebase tree

```bash
extension/
├── pi-editor-bridge.ts     # S1/S3/S5/S6/S9/S11/S12: lifecycle, captureProvider/getProvider, start/stopBridge, makeHelloHandler, narrowGetSuggestionsParams, makeGetSuggestionsHandler + GET_SUGGESTIONS_TIMEOUT_MS, narrowApplyCompletionParams, makeApplyCompletionHandler, getToken/getCwd/getFdAvailable/BRIDGE_VERSION  ← EDIT (add makeShouldTriggerFileCompletionHandler + narrowShouldTriggerFileCompletionParams + 1 registration line + import add)
├── protocol.ts             # S4: ALL wire types (TYPES-ONLY) — incl. ShouldTriggerFileCompletionParams/ShouldTriggerFileCompletionResult (§C, already defined)  ← UNCHANGED (consume only)
├── jsonl-reader.ts         # S7: attachJsonlLineReader, serializeJsonLine
├── connection.ts           # S8/S9/S10/S11/S12: ConnectionState, registerBridgeHandler, send*, BridgeRpcError, handleLine (gate + -32603 net), onConnection  ← UNCHANGED
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
    ├── get-suggestions-handler.test.ts     # S11 (engine-delegating sibling — model on this)
    └── apply-completion-handler.test.ts    # S12 (LEANEST sync sibling — closest structural match for S13)
```

### Desired Codebase tree (files this task touches)

```bash
extension/
├── pi-editor-bridge.ts                                       # MODIFY: + factory + narrowing helper + 1 registration line + import add + TODO comment update + STATUS block
└── tests/
    └── should-trigger-file-completion-handler.test.ts        # CREATE: UNIT (factory) + DISPATCH (gate-open) + ONE REAL (hello→shouldTriggerFileCompletion)
```

### Known Gotchas of our codebase & Library Quirks

```ts
// CRITICAL: pi's shouldTriggerFileCompletion is SYNCHRONOUS (autocomplete.ts:269
//   interface WITH the `?` = OPTIONAL; autocomplete.ts:775-785 impl = sync). It
//   takes NO options/AbortSignal and returns a `boolean` DIRECTLY (not a Promise).
//   The TUI calls it WITHOUT await (editor.ts:2152-2153). S13's handler MUST be
//   sync to faithfully mirror this — do NOT wrap in async/await, do NOT add
//   AbortController, do NOT add a timeout, do NOT add supersession. Those belong
//   to getSuggestions (S11) ONLY. (research §1.2, §7.)

// CRITICAL: the method is OPTIONAL on AutocompleteProvider (autocomplete.ts:269
//   has the `?`). A direct call `provider.shouldTriggerFileCompletion(...)` on a
//   provider WITHOUT the method throws `TypeError: ...is not a function` → would
//   surface as a spurious `-32603 internal error` and break Tab in Neovim. The
//   handler MUST use optional chaining: `provider.shouldTriggerFileCompletion?.(...)`.
//   (research §1.1.) The base CombinedAutocompleteProvider the bridge captures
//   DOES implement it (autocomplete.ts:775), so `?.` is a no-op for the base
//   provider — but a thin custom wrapper registered after the bridge's capture
//   may NOT. `?.` is correct and free.

// CRITICAL: the `?? true` default is SEMANTICALLY MEANINGFUL. pi's own tests,
//   docs, and examples ALL write `return current.shouldTriggerFileCompletion?.(...)
//   ?? true;` (research §1.3 — 5 sources, byte-identical). "If the provider doesn't
//   decide, ALLOW file completion." DO NOT default to `false`. DO NOT drop the
//   `?? true`. DO NOT substitute a plain `??` (syntax error without a right side).
//   The handler replicates this verbatim.

// CRITICAL: handleLine does `const result = await handler(params,state)`. `await`
//   on a non-Promise (a boolean) resolves to that boolean immediately — a SYNC
//   handler return works UNCHANGED. MethodHandler = `(params,state) => Promise<unknown>
//   | unknown` explicitly allows sync. So returning the boolean directly is
//   correct & typed. (research §7; connection.ts MethodHandler.)

// CRITICAL: the bridge returns pi's boolean VERBATIM. It MUST NOT coerce, invert,
//   or 'fix' the value. `false` (typing a bare slash command like `/set`) is
//   passed through as `false`; the Neovim client then skips the forced
//   getSuggestions. (PRD §11; research §2.)

// CONVENTION: throw BridgeRpcError(-32602, "invalid params: …") for malformed
//   params. -32602 is the reserved JSON-RPC "invalid params" code (protocol.ts
//   §A). This matches S9/S11/S12 precedent (hello throws -32600; getSuggestions/
//   applyCompletion throw -32602). handleLine maps a thrown BridgeRpcError →
//   {id,error:{code,message}}. Validation rules: lines is an Array whose every
//   element is typeof === "string"; cursorLine/cursorCol are
//   `Number.isInteger(x) && x >= 0`. (research §5, §6.)
//   DO NOT wrap provider-not-captured / provider-runtime-throws here — that is
//   S15's lane. For S13 let those fall to handleLine's -32603 safety net (keeps
//   pi safe). (research §5; identical boundary to S11/S12.)

// CONVENTION: node:test + jiti (NOT vitest). TAB indentation. Test seams named
//   __xForTest. registerBridgeHandler + __resetHandlersForTest() in EVERY finally
//   (node:test runs sequentially; module registry persists across tests). Model
//   the new test file's imports + helpers on get-suggestions-handler.test.ts
//   (closest sibling). COPY fakeSocket()/parseResponses()/readFirstResponse()
//   VERBATIM (they are LOCAL per-file — NOT exported). (research §6; S11 §5.)

// GOTCHA: NO setTimeout/clearTimeout used in S13 (no timeout) — so the "typed
//   globals" concern from S11 is irrelevant here. The handler closure holds NO
//   mutable state, so there is nothing to reset/leak. A loop of
//   shouldTriggerFileCompletion calls completes promptly with no timers keeping
//   the process alive.

// GOTCHA: to test the OPTIONAL-method ⇒ true default, build a stub provider that
//   OMITS shouldTriggerFileCompletion entirely (do NOT define it as a property).
//   A provider with `shouldTriggerFileCompletion: undefined` is DIFFERENT (it
//   would still be "present but undefined" — `?.` handles both, but the cleanest
//   test omits the key). Use `{ getSuggestions: async () => null, applyCompletion:
//   () => ({...}) }` with NO shouldTriggerFileCompletion key. (research §1.1, §7.)
```

---

## Implementation Blueprint

### Data models and structure

**No new wire types. No new runtime exports beyond the factory. No new constants.**
S13 consumes:
- `ShouldTriggerFileCompletionParams { lines: string[]; cursorLine: number; cursorCol: number }`
  and `ShouldTriggerFileCompletionResult = boolean` (protocol.ts §C, already defined).
- `MethodHandler` (connection.ts) — `(params: unknown, state: ConnectionState) =>
  Promise<unknown> | unknown`; S13 returns a SYNC handler (a boolean).
- `BridgeRpcError` (connection.ts) — thrown for `-32602` param errors.
- `getProvider()` (pi-editor-bridge.ts, S2) — the dep closure the factory receives;
  throws a plain `Error` when not yet captured (→ `-32603`).
- `AutocompleteProvider` (pi-tui) — the live chain's `shouldTriggerFileCompletion`
  signature is OPTIONAL: `shouldTriggerFileCompletion?(lines, cursorLine,
  cursorCol): boolean` (SYNC; research §1).

S13 adds ONE module-level export to `pi-editor-bridge.ts`:
- `export function makeShouldTriggerFileCompletionHandler(deps: { getProvider: () => AutocompleteProvider }): MethodHandler;`
and one non-exported helper `narrowShouldTriggerFileCompletionParams(params: unknown): ShouldTriggerFileCompletionParams`.
(No new const — shouldTriggerFileCompletion has no timeout.)

### Implementation Tasks (ordered by dependencies)

```yaml
Task 1: MODIFY extension/pi-editor-bridge.ts — add the factory, narrowing helper, registration, and import
  - ADD import: extend the existing
    `import type { HelloParams, HelloResult, GetSuggestionsParams, GetSuggestionsResult, ApplyCompletionParams, ApplyCompletionResult } from "./protocol.ts"`
    → also import `ShouldTriggerFileCompletionParams, ShouldTriggerFileCompletionResult`.
  - ADD (non-exported) `narrowShouldTriggerFileCompletionParams(params: unknown): ShouldTriggerFileCompletionParams`
    that validates shape and throws `BridgeRpcError(-32602, "invalid params: …")`
    (code below). Rules: params is a non-null object; `lines` is an Array whose every
    element is `typeof === "string"`; `cursorLine`/`cursorCol` are
    `Number.isInteger(x) && x >= 0`.
  - ADD: `export function makeShouldTriggerFileCompletionHandler(deps: { getProvider:
    () => AutocompleteProvider }): MethodHandler` (code below). The handler is SYNC —
    it returns a `boolean` directly (NO `async`, NO AbortController, NO timeout, NO
    closure state). Body: narrow → getProvider (throws if uncaptured) → `return
    provider.shouldTriggerFileCompletion?.(params.lines, params.cursorLine,
    params.cursorCol) ?? true;` (the `?.` + `?? true` are LOAD-BEARING — see Known
    Gotchas).
  - ADD registration: in the `session_start` handler, IMMEDIATELY AFTER the
    existing `registerBridgeHandler("applyCompletion", makeApplyCompletionHandler({...}))`
    call, add `registerBridgeHandler("shouldTriggerFileCompletion", makeShouldTriggerFileCompletionHandler({ getProvider }));`.
  - UPDATE the existing `// TODO(S13): register "shouldTriggerFileCompletion"; …`
    comment to mark S13 DONE (keep S14/S16 TODOs).
  - UPDATE the file-top STATUS block: add a `STATUS (P1.M2.T6.S13)` note
    (shouldTriggerFileCompletion handler registered; sync delegation via `?.` + `??
    true` because the method is OPTIONAL on the interface; no AbortController/timeout;
    ping+bye+getCommands S14 / domain-error wrapping S15 remain TODO).
  - DO NOT touch: captureProvider/getProvider bodies, startBridge/stopBridge,
    makeHelloHandler/makeGetSuggestionsHandler/makeApplyCompletionHandler,
    narrowGetSuggestionsParams/narrowApplyCompletionParams, resolveFdAvailable, the
    session_shutdown handler, or anything in connection.ts / protocol.ts.

Task 2: CREATE extension/tests/should-trigger-file-completion-handler.test.ts — UNIT/DISPATCH/REAL
  - IMPORTS: model on get-suggestions-handler.test.ts verbatim, PLUS from
    ../pi-editor-bridge.ts: `makeShouldTriggerFileCompletionHandler, makeHelloHandler,
    BRIDGE_VERSION`. Type imports: `AutocompleteProvider` (and `AutocompleteItem`/
    `AutocompleteSuggestions` only if the stub needs them — likely NOT for S13; the
    stub can return null/throw-placeholder for the unused methods) from
    @earendil-works/pi-tui. Need `BridgeRpcError` from ../connection.ts too.
  - COPY fakeSocket()/parseResponses()/readFirstResponse() VERBATIM from
    get-suggestions-handler.test.ts (they are local helpers, not exported).
  - MODULE-LEVEL: a `makeStubProvider({ fileTrigger, ...overrides })` helper
    returning a plain object satisfying `AutocompleteProvider`. Provide THREE
    variants: (a) `withMethod(value:boolean)` — implements shouldTriggerFileCompletion
    returning `value`; records the last {lines,cursorLine,cursorCol} onto a captured
    `lastCall`; (b) `withoutMethod()` — OMITS shouldTriggerFileCompletion entirely
    (the OPTIONAL-method case); (c) default getSuggestions returns null +
    applyCompletion returns a placeholder `{lines:[],cursorLine:0,cursorCol:0}`
    (unused by S13; present only to satisfy the interface type). Expose a
    `getLastCall()` accessor.
  - UNIT tests (call the factory directly; fresh `ConnectionState` per test):
    1. TRUE PASSTHROUGH: stub.withMethod(true) → handler returns `true` (strictEqual).
    2. FALSE PASSTHROUGH: stub.withMethod(false) → handler returns `false`
       (strictEqual). (This is the realistic `/set` case — pi's gate says "don't
       force files here".)
    3. OPTIONAL-METHOD ⇒ TRUE DEFAULT (THE KEY S13 TEST): stub.withoutMethod() →
       handler returns `true` (strictEqual). Proves the `?.` + `?? true` path works
       on a provider that does NOT implement the optional method. This is the single
       most important correctness guarantee beyond S12's pattern.
    4. EXACT-ARG THREADING: stub.withMethod(true) records args; call with
       lines:["/set"], cursorLine:0, cursorCol:4 → recorded call has ALL THREE args
       untouched (deepEqual on the captured {lines,cursorLine,cursorCol}).
    5. SYNC RETURN: the handler returns a boolean directly — `typeof handler(params,
       state) === "boolean"` (a sync return; await would be a no-op). (Enforced by
       the source not using `async`; this assertion documents the contract.)
    6. PARAM VALIDATION: each invalid shape throws `BridgeRpcError` with code -32602:
       params not an object; lines not an array; lines array with a non-string;
       cursorLine a float / negative / non-number; cursorCol same. Assert
       `err instanceof BridgeRpcError && err.code === -32602` for each. Also assert
       the provider was NOT called (getLastCall() === undefined) on at least one
       invalid case — proving validation short-circuits before delegation.
    7. PROVIDER NOT CAPTURED: `getProvider: () => { throw new Error("not captured"); }`
       → handler throws that plain Error (NOT a BridgeRpcError). (Confirms S13
       leaves this to the -32603 safety net; S15 refines. Mirrors S11/S12's
       identical test.)
  - DISPATCH tests (registerBridgeHandler + fakeSocket + handleLine; pass
    `{ handshakeComplete: true }` so the S10 gate opens; `__resetHandlersForTest`
    in finally):
    8. VALID TRUE → SUCCESS: register shouldTriggerFileCompletion handler
       (stub.withMethod(true)); `await handleLine(sock, {handshakeComplete:true},
       JSON.stringify({jsonrpc:"2.0",id:"s1",method:"shouldTriggerFileCompletion",
       params:{lines:["hello wor"],cursorLine:0,cursorCol:9}}))`; assert
       parseResponses(writes) === [{jsonrpc:"2.0",id:"s1",result:true}].
    9. VALID FALSE → SUCCESS: same but params {lines:["/set"],cursorLine:0,
       cursorCol:4} and stub.withMethod(false) → result:false.
    10. OPTIONAL-METHOD → TRUE (dispatch path): register with stub.withoutMethod();
        params any valid triple → result:true. (Locks the `?.`+`?? true` behavior
        through the full dispatch path, not just the UNIT factory.)
    11. INVALID PARAMS → -32602: params `{lines:"notarray",cursorLine:0,cursorCol:0}`
        → exactly one response, code -32602, message starts "invalid params:";
        provider NOT called.
    12. PRE-HANDSHAKE → -32600 (regression, gate still wins): same valid request
        but `{handshakeComplete:false}` → `-32600 "handshake required: send hello
        first"` AND the provider's shouldTriggerFileCompletion is NOT called
        (getLastCall() stays undefined). Locks that the gate fires before the handler.
  - REAL integration (ONE real Unix-socket pair; register hello + shouldTriggerFileCompletion):
    13. Register `hello` (makeHelloHandler, fixed TOKEN) AND
        `shouldTriggerFileCompletion` (makeShouldTriggerFileCompletionHandler({
        getProvider: () => stubProvider })) where stubProvider.shouldTriggerFileCompletion
        mirrors pi's gate (return false when textBeforeCursor starts with "/" and has
        no space; else true — a realistic mirror so the wire round-trip is
        illustrative). createServer((c)=>onConnection(c)) → listen(unique tmp
        sockpath) → connect → (1) hello (correct token) ⇒ HelloResult; (2)
        shouldTriggerFileCompletion {lines:["/set"],cursorLine:0,cursorCol:4} ⇒
        {id,result:false}; (3) shouldTriggerFileCompletion {lines:["hello"],cursorLine:0,
        cursorCol:5} ⇒ {id,result:true}. Use readFirstResponse(client) BEFORE each
        client.write(serializeJsonLine(...)). __resetHandlersForTest(); server.close();
        in finally.

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
	ShouldTriggerFileCompletionParams,
	ShouldTriggerFileCompletionResult,
} from "./protocol.ts";

// (1b) the params narrowing helper (non-exported). Mirrors narrowApplyCompletionParams
//      but with ONLY lines/cursorLine/cursorCol (no item/prefix):
function narrowShouldTriggerFileCompletionParams(
	params: unknown,
): ShouldTriggerFileCompletionParams {
	const p = params as Partial<ShouldTriggerFileCompletionParams> | null;
	if (!p || typeof p !== "object") {
		throw new BridgeRpcError(-32602, "invalid params: expected an object");
	}
	const { lines, cursorLine, cursorCol } = p;
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
	return { lines, cursorLine, cursorCol };
}

// (1c) the factory (IDENTICAL shape to makeApplyCompletionHandler — only { getProvider };
//      result is a boolean; the `?.` + `?? true` are the load-bearing nuances):
/**
 * Build the `shouldTriggerFileCompletion` JSON-RPC handler (PRD §5.4 / §6.5). PURE
 * factory — dep injected so unit tests stub the provider. Delegates to pi's LIVE {@link
 * AutocompleteProvider.shouldTriggerFileCompletion} SYNCHRONOUSLY.
 *
 * SYNC, NO TIMING/RESOURCE CONCERNS: unlike getSuggestions (S11), shouldTriggerFileCompletion
 * is a pure SYNC function (pi autocomplete.ts:775-785 — verified). It takes NO options/
 * AbortSignal and returns a `boolean` directly. The TUI calls it WITHOUT await
 * (editor.ts:2152-2153). So this handler has NO AbortController, NO supersession (no
 * `pendingAbort`), NO timeout, NO closure state — it is plain delegation. The
 * MethodHandler union (`Promise<unknown> | unknown`) accommodates a sync return;
 * handleLine's `await` is a no-op on a non-Promise.
 *
 * OPTIONAL METHOD + `true` DEFAULT: UNLIKE getSuggestions/applyCompletion (required),
 * shouldTriggerFileCompletion is marked OPTIONAL on AutocompleteProvider
 * (autocomplete.ts:269 has the `?`). The handler MUST use optional chaining `?.` (a
 * direct call throws TypeError on a provider without the method) and nullish coalescing
 * `?? true` (pi's documented default: absent method ⇒ ALLOW file completion). pi's own
 * tests, docs, and examples ALL write `current.shouldTriggerFileCompletion?.(...) ?? true`
 * (byte-identical across 5 sources). The bridge replicates this VERBATIM.
 *
 * GATE IS PI'S JOB: pi's impl returns `false` while the user types a bare slash command
 * (e.g. `/set` before any space) and `true` otherwise (PRD §11). This handler forwards
 * (lines,cursorLine,cursorCol) and returns pi's boolean UNCHANGED — the bridge never
 * reimplements the gate.
 *
 * ERRORS: malformed params throw `BridgeRpcError(-32602)` (S9/S11/S12 precedent;
 * -32602 = reserved "invalid params"). `deps.getProvider()` throwing (provider not
 * captured) and any provider RUNTIME throw propagate to `handleLine`'s `-32603` safety
 * net — S15 later wraps those. S13 keeps them flowing (keeps pi safe).
 */
export function makeShouldTriggerFileCompletionHandler(deps: {
	getProvider: () => AutocompleteProvider;
}): MethodHandler {
	return (
		_params: unknown,
		_state: ConnectionState,
	): ShouldTriggerFileCompletionResult => {
		const params = narrowShouldTriggerFileCompletionParams(_params);
		const provider = deps.getProvider(); // throws plain Error if not captured → -32603 (S15 refines)
		// SYNC delegation via `?.` (method is OPTIONAL) + `?? true` (pi's documented default).
		// Return pi's boolean VERBATIM.
		return (
			provider.shouldTriggerFileCompletion?.(
				params.lines,
				params.cursorLine,
				params.cursorCol,
			) ?? true
		);
	};
}

// (1d) registration in session_start — add ONE line after the existing applyCompletion registration:
		registerBridgeHandler(
			"applyCompletion",
			makeApplyCompletionHandler({ getProvider }),
		);
		registerBridgeHandler(
			"shouldTriggerFileCompletion",
			makeShouldTriggerFileCompletionHandler({ getProvider }),
		);
		// TODO(S14): ping/bye/getCommands.
		// TODO(S16): advertise via process.env.PI_EDITOR_BRIDGE (env write is S16's job).

// === Task 2: should-trigger-file-completion-handler.test.ts — key stub shapes ===

// Three stub variants. (a) WITH the method (records args + returns a fixed boolean):
function makeStubProviderWithMethod(returnValue: boolean) {
	let lastCall:
		| { lines: string[]; cursorLine: number; cursorCol: number }
		| undefined;
	const provider: AutocompleteProvider = {
		getSuggestions: async () => null, // unused by S13
		applyCompletion: (lines, cursorLine, cursorCol) => ({ lines, cursorLine, cursorCol }), // unused by S13
		shouldTriggerFileCompletion: (lines, cursorLine, cursorCol) => {
			lastCall = { lines, cursorLine, cursorCol };
			return returnValue;
		},
	};
	return { provider, getLastCall: () => lastCall };
}

// (b) WITHOUT the method (the OPTIONAL-method case — OMIT the key entirely):
function makeStubProviderWithoutMethod(): AutocompleteProvider {
	return {
		getSuggestions: async () => null,
		applyCompletion: (lines, cursorLine, cursorCol) => ({ lines, cursorLine, cursorCol }),
		// NOTE: shouldTriggerFileCompletion deliberately OMITTED — the `?.` must handle this.
	};
}

// UNIT test 1 + 2 + 3 (the three core behaviors):
const withTrue = makeStubProviderWithMethod(true);
assert.equal(
	makeShouldTriggerFileCompletionHandler({ getProvider: () => withTrue.provider })(
		{ lines: ["hello wor"], cursorLine: 0, cursorCol: 9 },
		{ handshakeComplete: true },
	),
	true,
);
const withFalse = makeStubProviderWithMethod(false);
assert.equal(
	makeShouldTriggerFileCompletionHandler({ getProvider: () => withFalse.provider })(
		{ lines: ["/set"], cursorLine: 0, cursorCol: 4 },
		{ handshakeComplete: true },
	),
	false,
);
// THE KEY S13 TEST — OPTIONAL method ⇒ true default:
assert.equal(
	makeShouldTriggerFileCompletionHandler({ getProvider: () => makeStubProviderWithoutMethod() })(
		{ lines: ["anything"], cursorLine: 0, cursorCol: 8 },
		{ handshakeComplete: true },
	),
	true,
);

// UNIT test 6 (param validation short-circuits BEFORE delegation):
const { provider: rec, getLastCall: recLast } = makeStubProviderWithMethod(true);
const h = makeShouldTriggerFileCompletionHandler({ getProvider: () => rec });
assert.throws(
	() => h({ lines: "notarray", cursorLine: 0, cursorCol: 0 }, { handshakeComplete: true }),
	(err) => err instanceof BridgeRpcError && err.code === -32602,
);
assert.equal(recLast(), undefined, "provider must NOT be called on invalid params");

// DISPATCH test 8 (valid true → success):
registerBridgeHandler("shouldTriggerFileCompletion", makeShouldTriggerFileCompletionHandler({
	getProvider: () => makeStubProviderWithMethod(true).provider,
}));
try {
	const { sock, writes } = fakeSocket();
	await handleLine(sock, { handshakeComplete: true }, JSON.stringify({
		jsonrpc: "2.0", id: "s1", method: "shouldTriggerFileCompletion",
		params: { lines: ["hello wor"], cursorLine: 0, cursorCol: 9 },
	}));
	assert.deepEqual(parseResponses(writes), [{ jsonrpc: "2.0", id: "s1", result: true }]);
} finally { __resetHandlersForTest(); }

// REAL test 13 (hello → shouldTriggerFileCompletion → boolean over a real socket):
registerBridgeHandler("hello", makeHelloHandler({ getToken: () => TOKEN, getCwd: () => "/tmp", getFdAvailable: () => true, version: BRIDGE_VERSION }));
// realistic mirror of pi's gate (autocomplete.ts:775): false iff textBeforeCursor starts with "/" and has no space.
const stub: AutocompleteProvider = {
	getSuggestions: async () => null,
	applyCompletion: (lines, cl, cc) => ({ lines, cursorLine: cl, cursorCol: cc }),
	shouldTriggerFileCompletion: (lines, cl, cc) => {
		const before = (lines[cl] ?? "").slice(0, cc);
		return !(before.trim().startsWith("/") && !before.trim().includes(" "));
	},
};
registerBridgeHandler("shouldTriggerFileCompletion", makeShouldTriggerFileCompletionHandler({ getProvider: () => stub }));
const sockpath = join(tmpdir(), `pi-editor-stfc-${randomUUID()}.sock`);
const server = createServer((c) => onConnection(c));
server.listen(sockpath);
await once(server, "listening");
try {
	const client = connect(sockpath);
	await once(client, "connect");
	const rH = readFirstResponse(client);
	client.write(serializeJsonLine({ jsonrpc: "2.0", id: "h1", method: "hello", params: { token: TOKEN } }));
	await rH; // HelloResult
	const r1 = readFirstResponse(client);
	client.write(serializeJsonLine({ jsonrpc: "2.0", id: "s1", method: "shouldTriggerFileCompletion", params: { lines: ["/set"], cursorLine: 0, cursorCol: 4 } }));
	const got1 = (await r1) as { id: string; result: boolean };
	assert.equal(got1.id, "s1"); assert.equal(got1.result, false); // bare slash command ⇒ false
	const r2 = readFirstResponse(client);
	client.write(serializeJsonLine({ jsonrpc: "2.0", id: "s2", method: "shouldTriggerFileCompletion", params: { lines: ["hello"], cursorLine: 0, cursorCol: 5 } }));
	const got2 = (await r2) as { id: string; result: boolean };
	assert.equal(got2.id, "s2"); assert.equal(got2.result, true); // normal text ⇒ true
	client.destroy();
} finally { __resetHandlersForTest(); server.close(); }
```

### Integration Points

```yaml
SESSION LIFECYCLE (pi-editor-bridge.ts):
  - session_start: captureProvider (S2) → startBridge (S5) → cwd = ctx.cwd →
    register hello (S9) → register getSuggestions (S11) → register applyCompletion
    (S12) → **register shouldTriggerFileCompletion (S13, NEW)** → [S14+ …]. All
    BELOW the `if (ctx.mode !== "tui") return;` guard (inherited protection).
  - session_shutdown: stopBridge (unchanged). No shouldTriggerFileCompletion-specific
    teardown (the handler holds no socket/fs/timer resource — it is pure stateless
    delegation). A session_shutdown mid-call is impossible (the call is synchronous
    and completes within handleLine's microtask).

CONNECTION DISPATCH (connection.ts): UNCHANGED. handleLine's REQUEST branch already
  `await`s the handler (a no-op on a sync boolean) and sends `{id,result}`; a thrown
  BridgeRpcError → `{id,error:{code,message}}`; any other throw → `-32603`. The S10
  gate already blocks shouldTriggerFileCompletion pre-hello. S13 is PURELY a new
  handler registration.

PROTOCOL (protocol.ts): CONSUMED, not modified. ShouldTriggerFileCompletionParams/
  Result are already defined (§C); the wire value is a JSON boolean (never null).

DOWNSTREAM:
  - S14 (ping/bye/getCommands) are simpler still (ping/bye are server-info/ack;
    getCommands maps pi's command list to the lean CommandInfo shape — protocol.ts §C).
  - S15 (domain-error wrapping): wraps the provider-not-captured + provider-runtime-
    throw paths S13 currently leaves to the -32603 net. Designing S13's factory with
    `deps.getProvider` callable separately (not inlined) makes the S15 refinement a
    one-line wrap.
  - P2.M7.T20.S33 (Neovim Tab handler): the client sends shouldTriggerFileCompletion
    and, on `true`, issues a forced getSuggestions (S11) (PRD §7.4). S13 is the
    server counterpart that returns exactly the gate boolean the client branches on.
```

---

## Validation Loop

### Level 1: Syntax & Type (after the source edit)

```bash
cd /home/dustin/projects/pi-nvim-bridge
tsc --noEmit -p extension/tsconfig.json
# Expected: exit 0, NO output. (TS 5.9.3 baseline — verified clean pre-write. No setTimeout/
# AbortController used in S13, so no typed-global concerns. AutocompleteProvider.
# shouldTriggerFileCompletion is OPTIONAL + sync in pi-tui's types, so `?.` + returning a
# boolean directly satisfies MethodHandler's `Promise<unknown> | unknown` union. The `?? true`
# is well-typed (boolean | undefined ?? boolean ⇒ boolean).)
```

### Level 2: Unit / component tests (node:test + jiti — NOT vitest)

```bash
JITI_REG=/home/dustin/.local/lib/node_modules/@earendil-works/pi-coding-agent/node_modules/jiti/lib/jiti-register.mjs

# The NEW shouldTriggerFileCompletion suite (UNIT + DISPATCH + ONE REAL)
node --import "$JITI_REG" extension/tests/should-trigger-file-completion-handler.test.ts
# Expected: exit 0, `ℹ fail 0`. (jiti prints a benign DeprecationWarning on Node 26
# stderr — judge by exit code + the `ℹ pass`/`ℹ fail` summary, ignore the warning.)

# Regression: the gate still wins pre-handshake (handshake-gate suite)
node --import "$JITI_REG" extension/tests/handshake-gate.test.ts
# Expected: exit 0, `ℹ fail 0`.

# Regression: getSuggestions + applyCompletion handlers (unchanged; S13 registration is additive)
node --import "$JITI_REG" extension/tests/get-suggestions-handler.test.ts
node --import "$JITI_REG" extension/tests/apply-completion-handler.test.ts
# Expected: exit 0, `ℹ fail 0` each.

# Regression: hello handler (unchanged; additive registration)
node --import "$JITI_REG" extension/tests/hello-handler.test.ts
# Expected: exit 0, `ℹ fail 0`.

# Regression: connection dispatch (16 tests) — shouldTriggerFileCompletion dispatch is via
# the SAME handleLine; no dispatch code changed.
node --import "$JITI_REG" extension/tests/connection.test.ts
# Expected: `ℹ tests 16`, `ℹ pass 16`, `ℹ fail 0`.

# Full extension suite (no S2–S12 regressions — now 12 files)
for t in extension/tests/*.test.ts; do
  echo "--- $t"
  node --import "$JITI_REG" "$t" 2>/dev/null | grep -E "^ℹ (tests|pass|fail)"
done
# Expected: every file `ℹ fail 0`.
```

### Level 3: Integration (a real socket pair — shouldTriggerFileCompletion end-to-end)

```bash
# Driven by the real-socket test #13 inside should-trigger-file-completion-handler.test.ts.
# To eyeball the wire by hand (optional): hello → shouldTriggerFileCompletion("/set") → false;
# shouldTriggerFileCompletion("hello") → true.
JITI_REG=/home/dustin/.local/lib/node_modules/@earendil-works/pi-coding-agent/node_modules/jiti/lib/jiti-register.mjs
node --import "$JITI_REG" -e '
  const { createServer, connect } = require("node:net");
  const { join } = require("node:path"), { tmpdir } = require("node:os"), { randomUUID } = require("node:crypto");
  const { onConnection, registerBridgeHandler } = await import("./extension/connection.ts");
  const { makeHelloHandler, makeShouldTriggerFileCompletionHandler, BRIDGE_VERSION } = await import("./extension/pi-editor-bridge.ts");
  const { serializeJsonLine, attachJsonlLineReader } = await import("./extension/jsonl-reader.ts");
  const TOKEN = "deadbeef".repeat(4);
  const stub = { getSuggestions: async () => null, applyCompletion: (lines, cl, cc) => ({ lines, cursorLine: cl, cursorCol: cc }), shouldTriggerFileCompletion: (lines, cl, cc) => { const before = (lines[cl] ?? "").slice(0, cc); return !(before.trim().startsWith("/") && !before.trim().includes(" ")); } };
  registerBridgeHandler("hello", makeHelloHandler({ getToken:()=>TOKEN, getCwd:()=>"/tmp", getFdAvailable:()=>true, version:BRIDGE_VERSION }));
  registerBridgeHandler("shouldTriggerFileCompletion", makeShouldTriggerFileCompletionHandler({ getProvider:()=>stub }));
  const sockpath = join(tmpdir(), `stfc-${randomUUID()}.sock`);
  const s = createServer(c=>onConnection(c)); s.listen(sockpath);
  s.once("listening", ()=>{
    const cli = connect(sockpath);
    const read = () => new Promise(res=>{ const d=attachJsonlLineReader(cli,l=>{d();res(JSON.parse(l))}); });
    cli.once("connect", async ()=>{
      cli.write(serializeJsonLine({jsonrpc:"2.0",id:"h1",method:"hello",params:{token:TOKEN}}));
      console.log("hello:", JSON.stringify(await read()));
      cli.write(serializeJsonLine({jsonrpc:"2.0",id:"s1",method:"shouldTriggerFileCompletion",params:{lines:["/set"],cursorLine:0,cursorCol:4}}));
      console.log("/set:", JSON.stringify(await read()));
      cli.write(serializeJsonLine({jsonrpc:"2.0",id:"s2",method:"shouldTriggerFileCompletion",params:{lines:["hello"],cursorLine:0,cursorCol:5}}));
      console.log("hello:", JSON.stringify(await read()));
      cli.destroy(); s.close();
    });
  });
'
# Expected:
#   hello:  {"jsonrpc":"2.0","id":"h1","result":{"ok":true,"serverVersion":"0.1.0","cwd":"/tmp","fdAvailable":true}}
#   /set:   {"jsonrpc":"2.0","id":"s1","result":false}
#   hello:  {"jsonrpc":"2.0","id":"s2","result":true}
```

### Level 4: Domain-specific validation (correctness invariants)

```bash
# (a) Params forwarded UNTOUCHED — asserted in UNIT test #4 (deepEqual on captured
#     {lines,cursorLine,cursorCol}).
# (b) Boolean returned VERBATIM — asserted in UNIT tests #1/#2 (true/false strictEqual)
#     + DISPATCH tests #8/#9 + REAL test #13 (result:false for /set, result:true for hello).
# (c) OPTIONAL-method ⇒ true default — asserted in UNIT test #3 + DISPATCH test #10
#     (a provider WITHOUT shouldTriggerFileCompletion returns true). This is THE S13-
#     specific guarantee beyond S12's pattern.
# (d) Param validation short-circuits BEFORE delegation — asserted in UNIT test #6
#     (getLastCall() === undefined on an invalid-params path).
# (e) Token value never appears in any shouldTriggerFileCompletion response/stderr
#     (PRD §12) — the result is a bare boolean; grep the run:
JITI_REG=/home/dustin/.local/lib/node_modules/@earendil-works/pi-coding-agent/node_modules/jiti/lib/jiti-register.mjs
SECRET="deadbeefdeadbeefdeadbeefdeadbeef"
node --import "$JITI_REG" extension/tests/should-trigger-file-completion-handler.test.ts 2>&1 | grep -c "$SECRET" || true
# Expected: 0 in RESULT payloads (the token only appears in the hello request the test
# itself sends, never in a shouldTriggerFileCompletion response — assert specifically that
# no line where method:"shouldTriggerFileCompletion"/result co-occurs contains the secret;
# the simple grep above is a coarse sanity check; the dedicated assertion lives in the test.)
```

---

## Final Validation Checklist

### Technical Validation
- [ ] `tsc --noEmit -p extension/tsconfig.json` ⇒ exit 0, no output.
- [ ] `node --import "$JITI_REG" extension/tests/should-trigger-file-completion-handler.test.ts` ⇒ exit 0, `ℹ fail 0`.
- [ ] `node --import "$JITI_REG" extension/tests/handshake-gate.test.ts` ⇒ `ℹ fail 0` (gate still wins pre-handshake).
- [ ] `node --import "$JITI_REG" extension/tests/get-suggestions-handler.test.ts` ⇒ `ℹ tests 15`, `ℹ fail 0` (additive registration).
- [ ] `node --import "$JITI_REG" extension/tests/apply-completion-handler.test.ts` ⇒ `ℹ fail 0` (additive registration).
- [ ] `node --import "$JITI_REG" extension/tests/hello-handler.test.ts` ⇒ `ℹ fail 0` (additive registration).
- [ ] `node --import "$JITI_REG" extension/tests/connection.test.ts` ⇒ `ℹ tests 16`, `ℹ fail 0`.
- [ ] Every `extension/tests/*.test.ts` ⇒ `ℹ fail 0` (no S2–S12 regressions; now 12 files).

### Feature Validation
- [ ] Valid post-handshake `shouldTriggerFileCompletion` ⇒ live provider's boolean verbatim (`{jsonrpc,id,result:true|false}`).
- [ ] All three params (`lines`, `cursorLine`, `cursorCol`) forwarded to the provider untouched.
- [ ] Handler is SYNCHRONOUS (returns a `boolean` directly; no `async`/AbortController/timeout).
- [ ] **OPTIONAL-method ⇒ `true` default**: a provider WITHOUT `shouldTriggerFileCompletion` returns `true` (the `?.` + `?? true` path — pi's documented default).
- [ ] `false` passthrough works (the realistic `/set` "don't force files" case).
- [ ] Malformed params ⇒ exactly one `-32602 "invalid params: …"` with the request id; provider NOT called.
- [ ] Pre-handshake `shouldTriggerFileCompletion` ⇒ still `-32600` (S10 gate; provider NOT called).
- [ ] Provider-not-captured ⇒ `-32603` (safety net; not wrapped by S13).
- [ ] Token value never present in any `shouldTriggerFileCompletion` response (PRD §12).

### Code Quality
- [ ] Factory mirrors `makeApplyCompletionHandler`/`makeHelloHandler` (deps-injection; pure factory returning a `MethodHandler`) — LEANEST shape: only `{ getProvider }` dep.
- [ ] Handler is SYNC (no `async`, no AbortController, no `pendingAbort`, no `setTimeout`/`clearTimeout`, no `timeoutMs`).
- [ ] **`?.` optional chaining + `?? true` default** used (method is OPTIONAL on the interface; default true is pi's documented contract). A direct call is FORBIDDEN (throws TypeError on a provider without the method).
- [ ] Params narrowing throws `BridgeRpcError(-32602)` (S9/S11/S12 precedent; reserved code); validates `lines:string[]` + non-negative-integer `cursorLine`/`cursorCol`.
- [ ] Provider-not-captured / provider-runtime-throws left to the `-32603` safety net (NOT wrapped — S15's lane).
- [ ] Boolean returned VERBATIM (the bridge never coerces/inverts pi's gate value).
- [ ] Registration added AFTER the existing `applyCompletion` registration; BELOW the TUI-mode guard.
- [ ] TAB indentation, `node:test` + `assert/strict` + jiti (NOT vitest); `fakeSocket`/`parseResponses`/`readFirstResponse` copied verbatim; `__resetHandlersForTest()` in EVERY finally.
- [ ] File-top STATUS block + the `TODO(S13)` comment updated to mark S13 done (repo convention of accurate cross-task comments).

### Scope Discipline (did NOT bleed into other tasks)
- [ ] `extension/connection.ts` UNCHANGED (verify: `git diff --stat extension/connection.ts` ⇒ empty).
- [ ] `extension/protocol.ts` UNCHANGED (verify: `git diff --stat extension/protocol.ts` ⇒ empty).
- [ ] No S14 (ping/bye/getCommands) registrations.
- [ ] No domain-error wrapping added (that is S15's lane) — provider-not-captured + runtime throws flow to the `-32603` net.

---

## Anti-Patterns to Avoid

- ❌ **Don't call `provider.shouldTriggerFileCompletion(...)` directly.** The method is
  OPTIONAL on `AutocompleteProvider` (autocomplete.ts:269 has the `?`). A direct call on
  a provider WITHOUT the method throws `TypeError: ...is not a function` → surfaces as a
  spurious `-32603 internal error` and breaks Tab in Neovim. ALWAYS use `?.`.
- ❌ **Don't drop or flip the `?? true` default.** pi's own tests, docs, and examples ALL
  write `current.shouldTriggerFileCompletion?.(...) ?? true` — "absent method ⇒ ALLOW file
  completion." Defaulting to `false` would silently break Tab-to-force-file for any custom
  wrapper that doesn't implement the method. The `?? true` is pi's documented contract.
- ❌ **Don't copy S11's AbortController/timeout/supersession.** shouldTriggerFileCompletion
  is SYNC and takes no signal (verified). Adding an AbortController/timeout/pendingAbort
  would be dead code that misrepresents the contract. S13 is the LEAN handler (leaner even
  than S12 — 3 params, boolean result).
- ❌ **Don't reimplement the gate logic** (the "/set before space ⇒ false" rule). Forward
  `(lines,cursorLine,cursorCol)` and return pi's boolean verbatim — pi owns the gate
  (autocomplete.ts:775).
- ❌ **Don't make the handler `async`.** It returns a boolean; `MethodHandler`'s union
  allows sync and `handleLine`'s `await` is a no-op on a non-Promise. `async` would
  falsely imply in-flight resource management exists.
- ❌ **Don't coerce/invert the boolean.** Return it exactly as the provider returns it.
  `false` is a legal, meaningful value ("typing a slash command, don't force files").
- ❌ **Don't wrap provider-not-captured / runtime throws into a specific code here.**
  That's S15's lane; S13 lets them flow to the `-32603` safety net (keeps pi safe).
- ❌ **Don't skip validation because "it should work".** Params are `unknown` from the
  wire — narrow defensively with `-32602` (S9/S11/S12 precedent).
- ❌ **Don't catch all exceptions broadly.** Throw the specific `BridgeRpcError(-32602)`
  for param errors; let everything else propagate to `handleLine`'s typed nets.
