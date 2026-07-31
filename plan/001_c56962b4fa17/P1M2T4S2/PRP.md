---
name: "P1.M2.T6.S12 — applyCompletion handler (synchronous delegation)"
description: |
  Implement the `applyCompletion` JSON-RPC method handler inside the existing single
  extension file `extension/pi-editor-bridge.ts` (NO new module, NO tsconfig change).
  Specifically ADD: a single **synchronous** `handleApplyCompletion(params, connCtx)`
  function that (1) delegates to pi's live captured autocomplete provider via
  `getProvider().applyCompletion(params.lines, params.cursorLine, params.cursorCol,
  params.item, params.prefix)` — forwarding all five fields VERBATIM and in order — and
  (2) returns the provider's `{ lines, cursorLine, cursorCol }` result wrapped in a
  `HandlerOutcome<ApplyCompletionResult>`. The handler is a **plain (non-async) function**:
  pi's `AutocompleteProvider.applyCompletion` is synchronous (verified in the compiled
  `pi-tui/dist/autocomplete.js`), so S12 uses NO async/await, NO AbortController, NO
  supersession (`pendingAbort`), and NO timeout — unlike its async sibling
  `handleGetSuggestions` (S11). It MUST NEVER throw (PRD §6.7 "Never throws from
  handlers"): a SINGLE try/catch wraps both `getProvider()` and
  `provider.applyCompletion(...)`, mapping any throw (provider-not-captured OR provider
  threw) to `{ ok:false, error:{ code:-32603, message:"applyCompletion failed: <msg>" } }`.
  Success returns `{ ok:true, result }` — the provider's result forwarded **by reference**
  (NO cloning/transformation; the dispatcher envelopes it verbatim). S12 REUSES two types
  introduced by the parallel S11 task (treated as a merged contract): `ConnectionContext`
  (same module — no import) and `HandlerOutcome<T>` (same module — no import). S12 does
  NOT reuse S11's `toRpcError` (its message is hardcoded "getSuggestions failed" — wrong
  prefix for this method); it inlines the `JsonRpcError` instead, and S15 will later
  generalize the per-handler error helper. S12 ships ONE self-contained, independently-
  testable sync handler + its test file. It does NOT touch `protocol.ts` (type-only
  import only), does NOT wire the handler into any dispatcher/onConnection (S8 territory),
  does NOT implement handshake gating (S9/S10), does NOT add the global try/catch safety
  net (S15), and does NOT implement the sibling handlers S11/S13/S14. (Path note:
  orchestrator placed artifacts under `P1M2T4S2/`; the item is task **P1.M2.T6.S12** in
  the plan tree — applyCompletion handler. Build the handler; ignore the folder label.)
---

## Goal

**Feature Goal**: Land the bridge's `applyCompletion` RPC handler so that, when the
(future, S8) dispatcher calls `handleApplyCompletion(params, connCtx)`, it delegates to
pi's live captured autocomplete provider (`getProvider()`, dependency P1.M1.T1.S2) and
returns the provider's transformed buffer + cursor — **synchronously**, with all five
request fields forwarded verbatim and in order — wrapped in a `HandlerOutcome`
(success result OR JSON-RPC error) that the dispatcher envelopes verbatim. `applyCompletion`
is the "accept" half of the completion flow: when the Neovim user accepts a menu item,
the plugin sends the selected `AutocompleteItem` + `prefix` and expects back the NEW full
buffer + cursor that pi computes (byte-identical to pi's own TUI, so cursor placement on
slash commands / `@`-attachments / paths / quoted prefixes matches pi exactly).

**Deliverable** (all under `extension/`):
1. **MODIFY** `extension/pi-editor-bridge.ts` — ADD (1) the names `ApplyCompletionParams`
   and `ApplyCompletionResult` to the type-only import from `./protocol.ts` (the import
   S11 creates; keep ONE import line); and (2) `export function handleApplyCompletion(params:
   ApplyCompletionParams, connCtx: ConnectionContext): HandlerOutcome<ApplyCompletionResult>`
   placed adjacent to S11's `handleGetSuggestions` (in the handler section after
   `getProvider()`, before the `export default function (pi: ExtensionAPI): void {` factory).
   The handler carries Mode-A JSDoc with a `STATUS (P1.M2.T6.S12)` marker + forward
   references (S8 dispatcher, S9/S10 handshake, S13 sibling, S15 global try/catch). The
   **default-export factory, `captureProvider`/`getProvider`/`liveProvider`, the S5/S6
   bridge-server section, the S11 getSuggestions handler + its `ConnectionContext`/
   `HandlerOutcome`/`toRpcError`/`__handlerDeps`/`pendingAbort`, and `protocol.ts` are all
   UNCHANGED.**
2. **CREATE** `extension/tests/handler-applycompletion.test.ts` — a `node:test`+jiti suite
   (matching the S2/S3/S4/S5/S11 test conventions) with 3 tests exercising the handler
   directly via a fake provider injected through `captureProvider`, with NO
   socket/dispatcher/handshake involvement (those are unimplemented sibling tasks).

**Success Definition**:
- `tsc --noEmit -p extension/tsconfig.json` → exit 0, **no output** (the type-only
  `protocol.ts` import additions, the `ConnectionContext`/`HandlerOutcome` references —
  already in module scope from S11 — and the `Error`/`String` globals all type-check under
  the current tsconfig with NO tsconfig edit — empirically verified, research §6).
- `node --import <pi>/node_modules/jiti/lib/jiti-register.mjs
  extension/tests/handler-applycompletion.test.ts` → exit 0, `fail 0` (`pass 3`):
  not-captured error; happy-path (identity result + 5-arg passthrough + sync-ness);
  provider-throws → error.
- Pre-existing suites still green: `provider-capture.test.ts` (S2), `mode-guard.test.ts`
  (S3), `protocol.test.ts` (S4), `bridge-lifecycle.test.ts` (S5), `bridge-lifecycle-wiring.test.ts`
  (S6) — S12 is purely additive to `pi-editor-bridge.ts` and adds one test file.
- Regression: `pi --no-extensions -e ./extension/pi-editor-bridge.ts --print "ok"` exits 0
  with no error lines AND the startup log is still ABSENT in print mode (S3 guard intact —
  S12 does NOT touch the default-export factory).

## User Persona (if applicable)

**Target User**: The bridge-extension author and the later RPC-layer implementers
(S8 onConnection/dispatcher, S9/S10 handshake, S13 shouldTriggerFileCompletion sibling,
S14 ping/bye/getCommands, S15 global error wrapper). This handler is the canonical
**synchronous** handler sibling — S13 (shouldTriggerFileCompletion) and parts of S14 follow
this exact (non-async, single-try/catch, inline-error) shape.

**Use Case**: When S8's dispatcher parses an `applyCompletion` request and narrows its
params via `protocol.ts`, it calls `handleApplyCompletion(params, connCtx)`, reads the
returned `HandlerOutcome`, and writes `{jsonrpc:"2.0", id, result}` or
`{jsonrpc:"2.0", id, error}` to the socket. (No `await` needed at the dispatch site —
the handler is sync — though the dispatcher may `await` it harmlessly since a plain object
is not a thenable.) On the plugin side, the Neovim accept flow (P2.M7.T19.S32) sends the
selected item, receives the new buffer + cursor, and replaces the buffer + sets the cursor
to get byte-identical behavior with pi's TUI.

**Pain Points Addressed**:
- Without delegating `applyCompletion` to pi's provider, the plugin would have to
  re-implement pi's cursor math (slash-command `/${value} ` +2; `@`-attachment directory
  vs file trailing-space logic; quoted-prefix quote-stripping; raw-path cursor offset) —
  guaranteeing drift from pi's TUI. Delegating means the bridge's accept behavior is
  BYTE-IDENTICAL to pi's, for free, forever.
- Without never-throw + `HandlerOutcome`, a provider throw (or a "not captured" throw
  before `session_start`) would crash the dispatcher / kill the connection (PRD §6.7).

## Why

- **The "accept" half of completion, delegated for byte-identical behavior.** pi's
  `CombinedAutocompleteProvider.applyCompletion` owns all the cursor-placement logic for
  the four completion shapes (slash-command name, `@`-attachment, slash-command argument,
  raw path) including directory-vs-file trailing-space and quoted-prefix handling
  (research §3, compiled `pi-tui/dist/autocomplete.js:262-330`). The bridge MUST delegate
  to it (not reimplement) so the external editor's accept behavior never drifts from pi's
  TUI. This handler is that delegation's RPC entry point.
- **Synchronous by design — simpler and correct.** `applyCompletion` is a pure, fast,
  synchronous transform (string slicing + array spread; no I/O, no `fd`). There is nothing
  to cancel, supersede, or time out. A plain function (no `async`/`await`, no
  `AbortController`, no `pendingAbort`, no timeout) is the correct, minimal
  implementation. Contrast S11 (getSuggestions), which is async and shells out to `fd` and
  therefore needs supersession + a 1500 ms runaway-`fd` timeout. S12 deliberately does NOT
  copy that machinery.
- **Establishes the synchronous-handler sibling pattern.** S11 set the async-handler
  pattern (`HandlerOutcome` + `ConnectionContext` + supersession). S12 sets the
  sync-handler pattern (same `HandlerOutcome` + `ConnectionContext`, single try/catch,
  inline error). S13 (shouldTriggerFileCompletion) and parts of S14 follow S12's shape.
- **Single-file, zero-dep, zero-config increment.** Co-located with `getProvider()` (the
  handler's only hard dependency) and with S11's sibling handler; requires NO tsconfig edit
  (the file is already in `include`; the new test matches the existing `tests/**/*.ts`
  glob); uses only globals (`Error`/`String`) + a type-only `protocol.ts` import —
  honoring PRD §6.7's "Node builtins only, no npm runtime dependencies".

## What

Additive code inside `extension/pi-editor-bridge.ts` + one new test file. No new module, no
tsconfig change, no `protocol.ts` touch (type-only import addition), no
dispatcher/handshake wiring, no default-export change. The handler is exercised **only by
direct invocation** in tests.

### Success Criteria

- [ ] `handleApplyCompletion(params: ApplyCompletionParams, connCtx: ConnectionContext):
      HandlerOutcome<ApplyCompletionResult>` exists and is exported. It is a **plain
      (non-async) function** — signature has NO `async`, return type is `HandlerOutcome<...>`
      (NOT `Promise<HandlerOutcome<...>>`).
- [ ] It calls `getProvider()` then `provider.applyCompletion(params.lines,
      params.cursorLine, params.cursorCol, params.item, params.prefix)` — all five fields
      forwarded VERBATIM and in order (research §3; matches pi's interface + the three
      editor.ts call sites).
- [ ] Success returns `{ ok: true, result }` where `result` is the provider's return value
      forwarded **by reference** (NO `.map`/spread/clone — the dispatcher envelopes it
      verbatim; the happy-path test asserts REFERENCE EQUALITY).
- [ ] Any throw (from `getProvider()` — "not captured" — OR from `provider.applyCompletion`)
      is caught and mapped to `{ ok:false, error:{ code:-32603, message:
      "applyCompletion failed: <err.message-or-String(err)>" } }`. The handler NEVER throws
      on any input (PRD §6.7).
- [ ] It does NOT use `async`/`await`, `AbortController`, `pendingAbort`, `setTimeout`, or
      `__handlerDeps` (those belong to the async getSuggestions handler; S12 has nothing to
      cancel/time out).
- [ ] It REUSES `ConnectionContext` and `HandlerOutcome<T>` from S11 (same module — no
      import); it does `void connCtx;` (threaded for contract uniformity; not dereferenced
      today).
- [ ] It does NOT define or call `toRpcError` (S11 owns it with a "getSuggestions failed"
      prefix — wrong for this method); it inlines the `JsonRpcError` object instead.
- [ ] `ApplyCompletionParams` and `ApplyCompletionResult` are imported TYPE-ONLY from
      `./protocol.ts` (merged into the single existing type-only import line S11 created).
- [ ] Mode-A JSDoc on the handler notes: synchronous delegation; all-five-fields verbatim;
      never-throw single try/catch; inline-error rationale (S15 generalizes); the
      `STATUS (P1.M2.T6.S12)` marker; forward refs (S8/S9/S13/S15).
- [ ] `tsc --noEmit -p extension/tsconfig.json` → exit 0, no output.
- [ ] `extension/tests/handler-applycompletion.test.ts` → 3 tests pass (`fail 0`).
- [ ] S2/S3/S4/S5/S6 suites still pass; `pi --print "ok"` regression exits 0.

## All Needed Context

### Context Completeness Check

_Pass test_: An agent who has never seen this repo, given the post-S6
`extension/pi-editor-bridge.ts` (treat S11's additions as merged: `ConnectionContext`,
`HandlerOutcome<T>`, `toRpcError`, `__handlerDeps`, `pendingAbort`, `handleGetSuggestions`),
`extension/protocol.ts` (post-S4), `extension/tsconfig.json`, and this PRP, can (1) add the
two type names to the protocol.ts import and paste the handler body verbatim from the
reference below (every type, signature, and the exact inline-error shape is pinned), (2)
write the 3-test file from the supplied skeleton, (3) run the four validation commands to
green — with the synchronous-nature of pi's `applyCompletion`, the globals' type-check
under `types:[]`, the `captureProvider` injection idiom, the do-NOT-reuse-toRpcError rule,
and the by-reference result-forwarding contract all cited and empirically verified in the
research notes.

### Documentation & References

```yaml
# MUST READ — the component spec (S12 implements §6.5 applyCompletion verbatim + honors §6.7)
- docfile: PRD.md
  why: §6.5 Request handling reference skeleton — the applyCompletion entry is `requireProvider(); return liveProvider!.applyCompletion(lines, cursorLine, cursorCol, item, prefix);` (SYNC, no try/catch in the skeleton). §6.7 Requirements checklist ("Never throws from handlers (wrap in try/catch, return JSON-RPC error)") — S12 ADDS the try/catch + HandlerOutcome wrapper the skeleton omits. §5.4 Methods — applyCompletion params {lines,cursorLine,cursorCol,item,prefix} → {lines,cursorLine,cursorCol}. §2.2 The autocomplete engine — AutocompleteProvider.applyCompletion(lines,cursorLine,cursorCol,item,prefix): {lines,cursorLine,cursorCol} (NOT Promise) — the provider the handler delegates to.
  section: "§6.5 (applyCompletion skeleton — implement the delegation verbatim + add connCtx + try/catch + HandlerOutcome), §6.7 (never-throw req), §5.4 (method signature + result), §2.2 (provider interface — note applyCompletion is SYNC)"
  critical: |
    §6.5's applyCompletion skeleton is SYNCHRONOUS (no async/await) and has NO try/catch and
    NO connCtx param. The item contract refines it: name the fn handleApplyCompletion(params,
    connCtx), wrap in a single try/catch, and return a HandlerOutcome (so it never throws,
    satisfying §6.7 explicitly). The DELEGATION itself is byte-identical to §6.5; only the
    wrapper + naming differ. CRITICAL: do NOT copy getSuggestions' async/AbortController/
    supersession/timeout machinery — applyCompletion needs NONE of it (research §1).

# MUST READ — the pre-researched, empirically-verified analysis FOR THIS EXACT TASK
- docfile: plan/001_c56962b4fa17/P1M2T4S2/research/notes.md
  why: the authoritative task analysis. §1 (LOAD-BEARING) applyCompletion is SYNCHRONOUS (compiled pi-tui/dist/autocomplete.js:262 — no async, returns plain object) → S12 is a plain non-async function, NO AbortController/supersession/timeout. §2 the provider returns a NEW array (spread [...lines]), does NOT mutate input → handler forwards result BY REFERENCE (identity). §3 prefix/item semantics (4 completion shapes) — context only, handler delegates verbatim. §4 REUSE ConnectionContext+HandlerOutcome from S11; DO NOT reuse toRpcError (wrong prefix) — inline the error; S15 generalizes. §5 single try/catch is correct (no supersession state to protect, unlike S11's two-phase). §6 globals (Error/String) type-check under types:[] via lib.dom (NO new runtime imports — only type-only protocol.ts import additions). §7 test conventions (jiti path, captureProvider idiom, FIRST-test-not-captured ordering, TABS). §8 verified validation commands.
  section: "all sections (§1 sync-nature and §4 do-NOT-reuse-toRpcError are the two make-or-break claims)"
  critical: |
    §1 is the single most load-bearing insight: this handler is SYNC. Getting this wrong (adding
    async/await or AbortController) is the #1 failure mode — it compiles fine but is needlessly
    complex AND would force the dispatcher into an await it does not need. §4 prevents a subtle
    bug: reusing S11's toRpcError would produce error messages prefixed "getSuggestions failed:"
    for an applyCompletion failure — wrong and misleading. Inline the error instead.

# MUST READ — the JSON-RPC types the handler consumes/produces (type-only import source)
- file: extension/protocol.ts
  why: the type-only module S12 imports ApplyCompletionParams/ApplyCompletionResult from. §C defines ApplyCompletionParams{lines,cursorLine,cursorCol,item,prefix} and ApplyCompletionResult{lines,cursorLine,cursorCol} (a real interface, NOT a union — success is always a full buffer+cursor). §A defines JsonRpcError{code,message} (S12 inlines an object structurally equal to it; code -32603 = internal error). item:AutocompleteItem and the result re-export pi-tui's types. §D's BridgeResultMap.applyCompletion = ApplyCompletionResult (the dispatcher's typed envelope uses this).
  section: "§A (JsonRpcError + error-code comment: -32603 internal error), §C (ApplyCompletionParams, ApplyCompletionResult)"
  critical: |
    S12 imports ONLY types from protocol.ts (import type {...} from "./protocol.ts") — protocol.ts
    is type-only (zero runtime exports; protocol.test.ts confirms it loads as an empty namespace).
    DO NOT add a value import. DO NOT edit protocol.ts (it is the S4 contract; S12 is type-only
    consumer). Merge the two new names into the SINGLE existing import line S11 created.

# MUST READ — the contract S12 builds on (S11 lands concurrently; treats as already-merged)
- docfile: plan/001_c56962b4fa17/P1M2T4S1/PRP.md
  why: S11 ADDS (after getProvider()) ConnectionContext interface, HandlerOutcome<T> generic, toRpcError(err,code) module-private helper (HARDCODED "getSuggestions failed" prefix), __handlerDeps timeout seam, pendingAbort supersession slot, and the async handleGetSuggestions(params,connCtx). S12 is ADDITIVE to that post-S11 file: it REUSES ConnectionContext + HandlerOutcome (same module — no import needed; they are in module scope), places handleApplyCompletion ADJACENT to handleGetSuggestions (sibling handlers grouped), and does NOT touch toRpcError/__handlerDeps/pendingAbort/handleGetSuggestions. S11's PRP explicitly states "S12/S13/S14 reuse [HandlerOutcome/ConnectionContext]" and "S15 may generalize [toRpcError] across handlers later" — both justify S12's design.
  section: "the ConnectionContext/HandlerOutcome/toRpcError definitions + the placement note (handler section after getProvider, before the default export)"
  critical: |
    ConnectionContext and HandlerOutcome are in the SAME module as S12 → S12 references them with
    NO import. toRpcError is module-PRIVATE to S11 → S12 CANNOT import it (and must NOT redefine
    it — would collide). S12 inlines its JsonRpcError. This is the cleanest parallel-merge-safe
    design; S15 DRYs it.

# MUST READ — the baseline S12 builds on (defines getProvider, the handler's only hard dependency)
- docfile: plan/001_c56962b4fa17/P1M1T1S3/PRP.md
  why: defines getProvider()/liveProvider (the singleton the handler reads). getProvider() THROWS "pi-editor-bridge: autocomplete provider not captured yet (await session_start)" when liveProvider is undefined — S12's single try/catch catches exactly that throw and surfaces it inside "applyCompletion failed: ...".
  section: "getProvider() implementation (throws /not captured/) + liveProvider singleton"
  critical: |
    S12's "not captured" path is just: try { provider = getProvider(); ...applyCompletion... }
    catch { return error }. getProvider already exists (S1/S2); S12 does NOT modify it. The throw
    message is fixed ("...not captured yet (await session_start)"); S12's inline error surfaces it.

# SUPPORTING — house test conventions (S12's test follows these exactly)
- file: extension/tests/provider-capture.test.ts
  why: the canonical node:test+jiti test pattern in THIS repo AND the exact fake-provider injection idiom S12 reuses: captureProvider({ui:{addAutocompleteProvider: f=>f(fakeProvider)}}) sets the module singleton liveProvider to fakeProvider. Also documents the shared-module-state sequential-test caveat (the "not captured" test must run FIRST, before any install) that S12 inherits.
  section: "makeFakeProvider helper; the runCapture({ui:{addAutocompleteProvider:...}}) injection; the FIRST-test-sees-undefined ordering caveat"

- file: extension/tests/mode-guard.test.ts
  why: confirms node:test top-level `test(...)` (no describe), `import assert from "node:assert/strict"`, jiti register-hook path, fake-ctx `{} as ExtensionContext` construction, TAB indentation.
  section: "whole file — import style, fakeCtx construction, sequential shared-state note"

# SUPPORTING — the sync-nature + prefix-semantics verification (the §1/§3 findings, primary-sourced)
- file: /home/dustin/.local/lib/node_modules/@earendil-works/pi-coding-agent/node_modules/@earendil-works/pi-tui/dist/autocomplete.js
  why: confirms applyCompletion (L262) is a plain SYNC method (no async/await) returning {lines:newLines,cursorLine,cursorCol} on every branch, where newLines = [...lines] (spread — NEW array, no input mutation). Branches on prefix: slash-command (startsWith "/" + beforePrefix.trim()===""), @-attachment (startsWith "@"), slash-arg (textBeforeCursor has "/" + " "), else raw path. → the handler delegates verbatim and forwards the result by reference.
  section: "applyCompletion (L262-330) — sync, spread-new-array, 4 prefix branches"
  critical: |
    This is WHY the handler is sync and WHY the happy-path test asserts identity (reference
    equality). The compiled .js is the shipped behavior the handler must mirror in its fake
    provider for tests (the fake returns {lines:[...lines], cursorLine, cursorCol} and records
    args).

- url: https://www.jsonrpc.org/specification#response_object
  why: confirms a Request with `id` MUST get exactly one Response (success OR error). S12 always returns a HandlerOutcome (one of the two branches), so the dispatcher always emits exactly one response per applyCompletion request id.
  section: "§5 Response object (exactly one response per request id); §5.1 Error object code/message"
```

### Current Codebase tree (post-S6 + treat-S11-merged baseline — S12 ADDS to pi-editor-bridge.ts + 1 test)

```bash
extension/
├── pi-editor-bridge.ts   # (S1+S2+S3+S5+S6, + S11 treated merged) default-export factory; session_start (TUI guard + log + captureProvider + startBridge) + session_shutdown (stopBridge); captureProvider/getProvider/liveProvider; [S5/S6] node:net import (incl type Socket); __deps; server/socketPath/token + getters; onConnection placeholder; startBridge/stopBridge (incl server.on('error')). [S11] ConnectionContext/HandlerOutcome/toRpcError/__handlerDeps/pendingAbort/handleGetSuggestions. S12 ADDS handleApplyCompletion adjacent to handleGetSuggestions (NOT a new file) + 2 names to the protocol.ts type-only import.
├── protocol.ts           # (S4) type-only JSON-RPC contract. S12 imports TYPES from it (no edit).
├── tsconfig.json         # (S1+S2+S4+S5) include covers pi-editor-bridge.ts/protocol.ts/tests/**/*.ts; NO lib field (→ DOM defaults → Error/String globals type-check). S12 does NOT edit.
└── tests/
    ├── provider-capture.test.ts          # (S2) — S12 reuses its fake-provider injection idiom
    ├── mode-guard.test.ts                # (S3)
    ├── protocol.test.ts                  # (S4)
    ├── bridge-lifecycle.test.ts          # (S5)
    ├── bridge-lifecycle-wiring.test.ts   # (S6)
    └── handler-getsuggestions.test.ts    # (S11 — parallel; will coexist)
# plan/ holds planning artifacts only — no other source code
```

### Desired Codebase tree with files to be added/modified

```bash
extension/
├── pi-editor-bridge.ts   # (MODIFY) ADD: ApplyCompletionParams/ApplyCompletionResult to the ./protocol.ts type-only import (one line); handleApplyCompletion (sync, single try/catch, inline error) adjacent to handleGetSuggestions. Default-export factory + captureProvider/getProvider/liveProvider + S5/S6 server section + S11 handler section UNCHANGED.
├── protocol.ts           # (UNCHANGED — S4; S12 is type-only consumer)
├── tsconfig.json         # (UNCHANGED)
└── tests/
    ├── provider-capture.test.ts          # (UNCHANGED — S2)
    ├── mode-guard.test.ts                # (UNCHANGED — S3)
    ├── protocol.test.ts                  # (UNCHANGED — S4)
    ├── bridge-lifecycle.test.ts          # (UNCHANGED — S5)
    ├── bridge-lifecycle-wiring.test.ts   # (UNCHANGED — S6)
    ├── handler-getsuggestions.test.ts    # (UNCHANGED — S11)
    └── handler-applycompletion.test.ts   # (CREATE) node:test+jiti: 3 tests (not-captured; happy-path identity + 5-arg passthrough + sync-ness; provider-throws→error) via fake provider injected through captureProvider.
```

**File responsibilities**
- `extension/pi-editor-bridge.ts` — gains the **synchronous** `applyCompletion` RPC handler
  runtime. It is the canonical sync-handler sibling: same `HandlerOutcome`/`ConnectionContext`
  contract as S11, but plain (non-async), single try/catch, inline error (no
  supersession/timeout machinery). The dispatcher (S8) calls it without `await`.
- `extension/tests/handler-applycompletion.test.ts` — the contract gate for S12: proves
  synchronous delegation, all-five-field verbatim passthrough, by-reference result
  forwarding (identity), never-throw on getProvider-throws and provider-throws, and the
  sync-ness contract (returns a plain object, not a thenable).

### Known Gotchas of our codebase & Library Quirks

```typescript
// CRITICAL (verified, research §1): pi's AutocompleteProvider.applyCompletion is SYNCHRONOUS —
//   it returns { lines, cursorLine, cursorCol } (NOT a Promise). Confirmed in the compiled
//   pi-tui/dist/autocomplete.js:262 (no async/await; plain object literal return on every branch)
//   AND in the interface (autocomplete.ts:128-137). CONSEQUENCE: S12's handleApplyCompletion is a
//   PLAIN (non-async) function returning HandlerOutcome<ApplyCompletionResult> (NOT
//   Promise<HandlerOutcome<...>>). Do NOT add async/await, AbortController, pendingAbort, or a
//   timeout — those belong ONLY to the async getSuggestions handler (S11). Adding them compiles
//   fine but is needlessly complex AND wrong (there is nothing to cancel or time out on a sync call).

// CRITICAL (PRD §6.7): "Never throws from handlers." The handler MUST catch every path. A SINGLE
//   try/catch wrapping BOTH getProvider() AND provider.applyCompletion(...) is correct and
//   sufficient (unlike S11, S12 has NO supersession state to protect, so no two-phase catch is
//   needed — research §5). Both failure modes map to the same {ok:false,error:{code:-32603,...}}.

// CRITICAL (research §4): DO NOT reuse S11's toRpcError — its message is HARDCODED
//   "getSuggestions failed: ...", which is WRONG for applyCompletion. S12 inlines its JsonRpcError
//   with prefix "applyCompletion failed: ...". S11's PRP itself says "S15 may generalize [toRpcError]
//   across handlers later" — so per-handler inline errors are the intended interim shape. S12 MUST
//   NOT define its own toRpcError either (would collide with S11's module-private one → redeclaration).

// CRITICAL (research §2): pi's applyCompletion returns a NEW array (newLines = [...lines]) and does
//   NOT mutate the caller's lines. The handler MUST forward the provider's result object BY REFERENCE
//   (identity) — NO .map/spread/clone. The dispatcher envelopes `result` verbatim. The happy-path
//   test asserts REFERENCE EQUALITY (assert.equal(outcome.result, sentinelResult)).

// CRITICAL (arg order): forward all five fields VERBATIM and in the interface order —
//   provider.applyCompletion(params.lines, params.cursorLine, params.cursorCol, params.item,
//   params.prefix). Do NOT reorder, do NOT wrap in an options object (getSuggestions uses
//   {signal,force}; applyCompletion does NOT — it takes 5 positional args). Matches pi's interface
//   (autocomplete.ts:128-137) and all three editor.ts call sites (research-pi-autocomplete.md §4).

// GOTCHA (jiti / parallel merge): S12 reuses ConnectionContext + HandlerOutcome from S11, which
//   live in the SAME module (pi-editor-bridge.ts) → NO import for them (module scope). S12 ADDS
//   ApplyCompletionParams + ApplyCompletionResult to the SINGLE existing type-only import line S11
//   created (`import type {...} from "./protocol.ts"`). If merging and the line already has
//   GetSuggestionsParams/GetSuggestionsResult/JsonRpcError, ADD the two new names to it — keep ONE
//   import statement from ./protocol.ts (tsc accepts the merge either way).

// GOTCHA (test isolation): liveProvider is a module singleton shared across tests in ONE process.
//   node:test runs top-level tests SEQUENTIALLY in definition order (do NOT enable concurrency).
//   The "not captured" test MUST be the FIRST test (before any captureProvider install), exactly
//   like provider-capture.test.ts / handler-getsuggestions.test.ts. Each test FILE is a separate
//   node process → liveProvider starts undefined per file.

// GOTCHA: the fake provider in tests MUST record ALL FIVE args (lines, cursorLine, cursorCol, item,
//   prefix) on applyCompletion so the happy-path test can assert verbatim passthrough. It should
//   also return a SENTINEL object (not a freshly-built one each call) so the identity assertion is
//   meaningful. See the makeFakeProvider skeleton in Implementation Patterns.

// GOTCHA: `void connCtx;` — the handler accepts connCtx for handler-contract uniformity (S8/S9 pass
//   it to every handler) but does NOT dereference it today. tsconfig has no noUnusedParameters, so
//   `void connCtx;` is a clarity marker, not a compile requirement. (Same idiom as S11's handler.)

// GOTCHA: the inline error object `{ code: -32603, message: ... }` is structurally typed as
//   JsonRpcError by the HandlerOutcome<T> generic's error branch — NO explicit JsonRpcError import
//   is needed in S12 (S11 imports it; S12 does not reference the type name, just constructs a
//   structurally-compatible literal).

// STYLE: TABS for indentation (match the existing pi-editor-bridge.ts + pi examples + all existing
//   tests). `import type` for ALL type-only imports. Mode-A JSDoc on the new export with a
//   `STATUS (P1.M2.T6.S12)` marker + forward refs (S8/S9/S13/S15).
```

## Implementation Blueprint

### Data models and structure

S12 adds no new **wire** types (those live in `protocol.ts`, S4) and no new **handler-contract**
types (those were introduced by S11: `ConnectionContext`, `HandlerOutcome<T>`). Its "data
model" is **one synchronous handler function** that consumes `ApplyCompletionParams` and
produces `HandlerOutcome<ApplyCompletionResult>`:

- **Inputs** (type-only import from `./protocol.ts`):
  - `ApplyCompletionParams` — `{ lines: string[]; cursorLine: number; cursorCol: number;
    item: AutocompleteItem; prefix: string }` (protocol.ts §C). All five fields forwarded to
    the provider verbatim.
  - `ApplyCompletionResult` — `{ lines: string[]; cursorLine: number; cursorCol: number }`
    (protocol.ts §C; a real interface, always a full buffer+cursor on success).
- **Reused contract types** (S11, same module — no import):
  - `ConnectionContext` — `{ readonly socket: Socket; handshakeDone: boolean }`. Threaded
    to the handler; not dereferenced today.
  - `HandlerOutcome<T>` — `{ ok: true; result: T } | { ok: false; error: JsonRpcError }`.
    The handler's return type; the dispatcher envelopes whichever branch it gets.
- **Inline error shape** — `{ code: -32603, message: "applyCompletion failed: <msg>" }`,
  structurally `JsonRpcError`. NOT routed through S11's `toRpcError` (wrong prefix).

### Implementation Tasks (ordered by dependencies)

```yaml
Task 1: MODIFY extension/pi-editor-bridge.ts — ADD the two type names to the protocol import
  - LOCATE the type-only import from ./protocol.ts. If S11 has landed, it reads:
        import type { GetSuggestionsParams, GetSuggestionsResult, JsonRpcError } from "./protocol.ts";
    (If S11 has NOT landed yet, CREATE:) import type { ... } from "./protocol.ts";
  - ADD `ApplyCompletionParams` and `ApplyCompletionResult` to that import (keep ONE import
      statement from ./protocol.ts — do NOT create a duplicate `import ... from "./protocol.ts"`).
  - NOTE: protocol.ts is TYPE-ONLY (zero runtime exports); `import type` adds nothing at
      runtime. Both names are exported from protocol.ts §C. S12 does NOT need `JsonRpcError`
      as a named import (it inlines a structurally-compatible literal; the HandlerOutcome<T>
      generic constrains the error field).
  - DO NOT: add a value import from protocol.ts; edit protocol.ts; re-import AutocompleteItem
      (it rides along inside ApplyCompletionParams.item; not referenced by name in S12).

Task 2: MODIFY extension/pi-editor-bridge.ts — ADD handleApplyCompletion (the ONLY new code)
  - PRECONDITION (verify, do NOT create): S11 added `ConnectionContext` + `HandlerOutcome<T>`
      to module scope (after getProvider(), before the default export). If they are somehow
      absent, STOP — S11 is a hard dependency (this PRP assumes it merged). Do NOT redefine
      them here (would collide with S11).
  - PLACE: ADJACENT to S11's handleGetSuggestions (sibling handlers grouped) — either
      immediately after handleGetSuggestions or immediately before it, within the handler
      section that sits after getProvider() and before
      `export default function (pi: ExtensionAPI): void {`.
  - ADD (Mode-A JSDoc + STATUS marker; see Implementation Patterns for the exact body):
      export function handleApplyCompletion(params: ApplyCompletionParams, connCtx:
      ConnectionContext): HandlerOutcome<ApplyCompletionResult> — a PLAIN (non-async)
      function. Body: `void connCtx;`; then a SINGLE try/catch:
        try { const provider = getProvider(); const result = provider.applyCompletion(
        params.lines, params.cursorLine, params.cursorCol, params.item, params.prefix);
        return { ok: true, result }; } catch (err) { const message = err instanceof Error
        ? err.message : String(err); return { ok: false, error: { code: -32603, message:
        `applyCompletion failed: ${message}` } }; }
  - FOLLOW: TAB indentation; match the JSDoc density/STATUS style of S11's handleGetSuggestions.
  - NAMING: handleApplyCompletion — exact (camelCase fn; matches handleGetSuggestions sibling).
  - DO NOT: make the function async; add await/AbortController/pendingAbort/setTimeout; reuse or
      redefine toRpcError; alter captureProvider/getProvider/liveProvider; alter the default-
      export factory; touch the S5/S6 server section; edit protocol.ts; wire the handler into
      onConnection/dispatcher (S8); add handshake gating (S9/S10); add the global try/catch
      (S15); implement S11/S13/S14.

Task 3: CREATE extension/tests/handler-applycompletion.test.ts (node:test + jiti)
  - IMPORT: `import { test } from "node:test"; import assert from "node:assert/strict";`
      `import type { AutocompleteProvider } from "@earendil-works/pi-tui";`
      `import type { ExtensionContext } from "@earendil-works/pi-coding-agent";`
      `import { captureProvider, handleApplyCompletion } from "../pi-editor-bridge.ts";`
      `import type { ApplyCompletionParams, ApplyCompletionResult, ConnectionContext,
      HandlerOutcome } from "../pi-editor-bridge.ts";` — NOTE ApplyCompletionParams/
      ApplyCompletionResult are re-exported transitively? NO — they live in protocol.ts.
      Import them from "../protocol.ts" (type-only). ConnectionContext/HandlerOutcome from
      "../pi-editor-bridge.ts" (S11 exports them).
  - HELPERS: `installProvider(p)` = captureProvider({ui:{addAutocompleteProvider:f=>f(p)}} as
      ExtensionContext) — sets the module singleton liveProvider to p. `makeFakeProvider(opts:
      {result?, throwErr?})` returns an AutocompleteProvider & {lastCall?} whose
      applyCompletion records ALL FIVE args into lastCall, throws throwErr if set, else returns
      opts.result (a SENTINEL captured once, so identity is testable). getSuggestions stubs to
      async ()=>null; shouldTriggerFileCompletion stubs to ()=>true. `fakeConnCtx =
      { socket: {} as ConnectionContext["socket"], handshakeDone: true } as ConnectionContext`.
  - TEST 1 (FIRST — not captured): with NO provider installed, build an ApplyCompletionParams
      (e.g. {lines:["/mo"],cursorLine:0,cursorCol:3,item:{value:"/model",label:"/model"},
      prefix:"/mo"}) and call handleApplyCompletion(params, fakeConnCtx); assert
      outcome.ok===false, error.code===-32603, error.message matches /not captured/ (substring
      of getProvider's throw). (liveProvider is undefined at the start of this fresh process.)
  - TEST 2 (happy path + 5-arg passthrough + identity + sync-ness): build a SENTINEL result
      `const sentinel: ApplyCompletionResult = { lines: ["/model "], cursorLine: 0, cursorCol: 7 };`;
      install a provider returning sentinel; build params with DISTINCT values for every field
      (lines:["/mo"], cursorLine:0, cursorCol:3, item:{value:"/model",label:"/model",
      description:"switch model"}, prefix:"/mo"); call `const outcome =
      handleApplyCompletion(params, fakeConnCtx);` (NO await — it is sync); assert
      outcome.ok===true AND outcome.result===sentinel (REFERENCE EQUALITY — verbatim forwarding);
      assert provider.lastCall deep-equals {lines:params.lines, cursorLine:0, cursorCol:3,
      item:params.item, prefix:"/mo"} (all five fields forwarded verbatim + in order); assert
      sync-ness: `assert.equal("then" in outcome, false, "handler must be synchronous (not a thenable)")`.
  - TEST 3 (provider throws → error): install a provider whose applyCompletion throws
      `new Error("boom")`; call handleApplyCompletion with any valid params; assert
      outcome.ok===false, error.code===-32603, error.message matches /^applyCompletion failed: boom$/.
  - SHARED-STATE CAVEAT: module singleton → tests run SEQUENTIALLY (node:test default; do NOT
      enable concurrency); TEST 1 (not-captured) is FIRST. Each real test installs its own provider.
  - FOLLOW: TAB indentation; reuse the SAME jiti register hook path as S2/S3/S4/S5/S11 tests.
  - NAMING: descriptive `test("...", ...)` titles; no `describe`.
  - PLACEMENT: extension/tests/handler-applycompletion.test.ts (matches tests/**/*.ts → NO tsconfig edit).

Task 4: VALIDATE — run the validation commands; fix until all green
  - RUN (Level 1): `tsc --noEmit -p extension/tsconfig.json` (expect exit 0, no output)
  - RUN (Level 2): `node --import <jiti-register> extension/tests/handler-applycompletion.test.ts`
      (expect exit 0, fail 0, pass 3; ignore the benign jiti DEP0205 deprecation on stderr)
  - RUN (Level 2 regression): re-run provider-capture.test.ts + mode-guard.test.ts +
      protocol.test.ts + bridge-lifecycle.test.ts + bridge-lifecycle-wiring.test.ts +
      handler-getsuggestions.test.ts — expect each fail 0
  - RUN (Level 3): `pi --no-extensions -e ./extension/pi-editor-bridge.ts --print "ok"` exits 0
      with NO error lines AND the startup-log line ABSENT in print mode (S3 intact)
```

### Implementation Patterns & Key Details

```typescript
// === extension/pi-editor-bridge.ts — Task 1: MERGE these two names into the SINGLE existing
//     type-only import from ./protocol.ts (the line S11 created). If S11's line is:
//         import type { GetSuggestionsParams, GetSuggestionsResult, JsonRpcError } from "./protocol.ts";
//     it BECOMES (add the two names — order within the braces is not significant):
import type {
	ApplyCompletionParams,
	ApplyCompletionResult,
	GetSuggestionsParams,
	GetSuggestionsResult,
	JsonRpcError,
} from "./protocol.ts";
// (If S11 has not landed when you implement, create the import with at least ApplyCompletionParams
//  + ApplyCompletionResult; the merger reconciles. Keep ONE statement from ./protocol.ts.)

// === extension/pi-editor-bridge.ts — Task 2: ADD this function ADJACENT to S11's
//     handleGetSuggestions (after it, within the handler section after getProvider(), before the
//     default-export factory). ConnectionContext + HandlerOutcome are already in module scope
//     (S11) — NO import for them. ===

/**
 * Handle an `applyCompletion` JSON-RPC request: delegate to pi's live autocomplete
 * provider's `applyCompletion` and return the transformed buffer + cursor it computes.
 *
 * SYNCHRONOUS BY DESIGN: pi's `AutocompleteProvider.applyCompletion` is a plain synchronous
 * method — it returns `{ lines, cursorLine, cursorCol }` (NOT a Promise; verified in the
 * compiled `pi-tui/dist/autocomplete.js`). So this handler is a **plain (non-async)
 * function**: it uses NO async/await, NO AbortController, NO supersession (`pendingAbort`),
 * and NO timeout. Contrast {@link handleGetSuggestions}, which is async (it shells out to
 * `fd` and needs per-request cancellation + supersession + a 1500 ms runaway-`fd` timeout).
 * `applyCompletion` is a pure, fast, synchronous transform — there is nothing to cancel or
 * time out.
 *
 * DELEGATION: all five request fields are forwarded to the provider VERBATIM and in order —
 * `provider.applyCompletion(params.lines, params.cursorLine, params.cursorCol, params.item,
 * params.prefix)` — matching pi's interface (`autocomplete.ts`) and all three of pi's own
 * editor call sites. The provider owns ALL cursor-placement logic (slash-command `/${value} `
 * +2; `@`-attachment directory-vs-file trailing-space; quoted-prefix quote-stripping; raw-path
 * cursor offset), so the external editor's accept behavior is BYTE-IDENTICAL to pi's TUI.
 *
 * NEVER THROWS (PRD §6.7): a SINGLE try/catch wraps both `getProvider()` and
 * `provider.applyCompletion(...)`. Any throw — "provider not captured" (before `session_start`)
 * OR a genuine provider error — is mapped to `{ ok:false, error:{code:-32603, message:\
 * "applyCompletion failed: <msg>"} }`. The dispatcher (S8) envelopes whichever branch it gets
 * into a `JsonRpcResponse`. (S15 adds a global try/catch as a safety NET for truly unexpected
 * bugs, not a replacement for self-wrapping.)
 *
 * ERROR HELPER: this handler inlines its `JsonRpcError` rather than reusing getSuggestions'
 * `toRpcError` (whose message is hardcoded "getSuggestions failed:" — the wrong prefix here).
 * S15 will generalize the per-handler error helper into a shared one; until then each handler
 * owns its prefix.
 *
 * @param params `{ lines, cursorLine, cursorCol, item, prefix }` (PRD §5.4). `cursorCol` is a
 *   0-indexed UTF-16 offset (PRD §8); the handler does not interpret coordinates — it forwards
 *   them verbatim.
 * @param connCtx the connection context (S8/S9); threaded for handler-contract uniformity —
 *   NOT dereferenced today (signaled with `void connCtx`).
 * @returns success → `{ok:true, result:{lines,cursorLine,cursorCol}}` (the provider's result,
 *   forwarded by reference); failure → `{ok:false, error:{code:-32603, message}}`.
 *
 * STATUS (P1.M2.T6.S12): the applyCompletion handler. S8 wires it into the dispatcher (it may
 * call it WITHOUT await — it is sync); S9/S10 gate it behind the hello handshake; S15 wraps
 * the dispatch loop in a safety-net try/catch; S13 (shouldTriggerFileCompletion) follows this
 * same synchronous single-try/catch shape.
 */
export function handleApplyCompletion(
	params: ApplyCompletionParams,
	connCtx: ConnectionContext,
): HandlerOutcome<ApplyCompletionResult> {
	void connCtx; // threaded for handler-contract uniformity; not dereferenced today

	// SINGLE try/catch — S12 has NO supersession state to protect (unlike S11, which split
	// getProvider() into its own catch to avoid touching pendingAbort). Both failure modes
	// (not-captured + provider-threw) map to the same {ok:false, error:{-32603, ...}}.
	try {
		const provider = getProvider();
		// Forward all five fields VERBATIM and in order. NO options object (contrast
		// getSuggestions' {signal,force}); applyCompletion takes 5 positional args.
		const result = provider.applyCompletion(
			params.lines,
			params.cursorLine,
			params.cursorCol,
			params.item,
			params.prefix,
		);
		// Forward BY REFERENCE (identity) — the provider returns a NEW array (spread [...lines]),
		// so no cloning is needed; the dispatcher envelopes `result` verbatim.
		return { ok: true, result };
	} catch (err) {
		const message = err instanceof Error ? err.message : String(err);
		return {
			ok: false,
			error: { code: -32603, message: `applyCompletion failed: ${message}` },
		};
	}
}
```

```typescript
// === extension/tests/handler-applycompletion.test.ts (CREATE — node:test + jiti) ===
import { test } from "node:test";
import assert from "node:assert/strict";
import type { AutocompleteProvider } from "@earendil-works/pi-tui";
import type { ExtensionContext } from "@earendil-works/pi-coding-agent";
import {
	captureProvider,
	handleApplyCompletion,
} from "../pi-editor-bridge.ts";
import type { ConnectionContext, HandlerOutcome } from "../pi-editor-bridge.ts";
import type { ApplyCompletionParams, ApplyCompletionResult } from "../protocol.ts";

// Inject a fake provider into the module singleton (liveProvider) via the EXACT
// captureProvider idiom from provider-capture.test.ts: the fake addAutocompleteProvider
// INVOKES the pass-through factory with our provider, which assigns liveProvider = provider.
function installProvider(p: AutocompleteProvider): void {
	captureProvider({
		ui: {
			addAutocompleteProvider: (
				f: (c: AutocompleteProvider) => AutocompleteProvider,
			) => f(p),
		},
	} as unknown as ExtensionContext);
}

// Fake provider whose applyCompletion records ALL FIVE args (for passthrough assertions) and
// returns a SENTINEL result (captured once, so identity is testable) or throws. getSuggestions
// /shouldTriggerFileCompletion are stubs — S12 does not call them.
function makeFakeProvider(opts: {
	result?: ApplyCompletionResult;
	throwErr?: Error;
}): AutocompleteProvider & {
	lastCall?: {
		lines: string[];
		cursorLine: number;
		cursorCol: number;
		item: ApplyCompletionParams["item"];
		prefix: string;
	};
} {
	const provider: AutocompleteProvider & {
		lastCall?: {
			lines: string[];
			cursorLine: number;
			cursorCol: number;
			item: ApplyCompletionParams["item"];
			prefix: string;
		};
	} = {
		lastCall: undefined,
		async getSuggestions() {
			return null;
		},
		applyCompletion(lines, cursorLine, cursorCol, item, prefix) {
			provider.lastCall = { lines, cursorLine, cursorCol, item, prefix };
			if (opts.throwErr) throw opts.throwErr;
			return opts.result ?? { lines: [...lines], cursorLine, cursorCol };
		},
		shouldTriggerFileCompletion() {
			return true;
		},
	};
	return provider;
}

const fakeConnCtx = {
	socket: {} as ConnectionContext["socket"],
	handshakeDone: true,
} as ConnectionContext;

// A representative request payload (slash-command shape). DISTINCT values per field so the
// passthrough assertion is meaningful.
const sampleParams: ApplyCompletionParams = {
	lines: ["/mo"],
	cursorLine: 0,
	cursorCol: 3,
	item: { value: "/model", label: "/model", description: "switch model" },
	prefix: "/mo",
};

// ============================================================================
// TEST 1 (FIRST — must run before any installProvider, while liveProvider is undefined,
//          exactly like provider-capture.test.ts / handler-getsuggestions.test.ts).
// ============================================================================
test("handleApplyCompletion returns a -32603 error when the provider is not captured", () => {
	const outcome = handleApplyCompletion(sampleParams, fakeConnCtx);
	assert.equal(outcome.ok, false);
	if (!outcome.ok) {
		assert.equal(outcome.error.code, -32603);
		assert.match(outcome.error.message, /not captured/); // from getProvider()'s throw
	}
});

// ============================================================================
// TEST 2 — happy path: delegates, forwards all 5 fields verbatim + in order, returns the
//          provider's result BY REFERENCE (identity), and is SYNCHRONOUS (not a thenable).
// ============================================================================
test("handleApplyCompletion delegates to the provider, forwards all fields verbatim, and returns the result by reference (sync)", () => {
	// SENTINEL captured ONCE so reference equality is meaningful.
	const sentinel: ApplyCompletionResult = { lines: ["/model "], cursorLine: 0, cursorCol: 7 };
	const provider = makeFakeProvider({ result: sentinel });
	installProvider(provider);

	const outcome = handleApplyCompletion(sampleParams, fakeConnCtx);

	// Success + verbatim (identity) result forwarding — no clone/transform.
	assert.equal(outcome.ok, true);
	if (outcome.ok) assert.equal(outcome.result, sentinel);

	// All five fields forwarded verbatim and in order.
	assert.deepEqual(provider.lastCall, {
		lines: sampleParams.lines,
		cursorLine: sampleParams.cursorLine,
		cursorCol: sampleParams.cursorCol,
		item: sampleParams.item,
		prefix: sampleParams.prefix,
	});

	// Synchronous contract: the handler returns a plain object, NOT a thenable.
	assert.equal(
		"then" in outcome,
		false,
		"handleApplyCompletion must be synchronous (return a plain object, not a Promise)",
	);
});

// ============================================================================
// TEST 3 — provider throws: never-throw, correct error code + method-scoped message.
// ============================================================================
test("handleApplyCompletion never throws — a provider throw becomes a -32603 'applyCompletion failed' error", () => {
	const provider = makeFakeProvider({ throwErr: new Error("boom") });
	installProvider(provider);

	const outcome = handleApplyCompletion(sampleParams, fakeConnCtx);

	assert.equal(outcome.ok, false);
	if (!outcome.ok) {
		assert.equal(outcome.error.code, -32603);
		assert.match(outcome.error.message, /^applyCompletion failed: boom$/);
	}
});
```

### Integration Points

```yaml
MODULE STATE (read-only consumer):
  - consume: "getProvider() / liveProvider (P1.M1.T1.S2) — the handler's only hard dependency.
      getProvider() throws if not captured; the handler's try/catch surfaces that as -32603."

SHARED CONTRACT TYPES (reuse from S11 — same module, NO import):
  - reuse: "ConnectionContext { readonly socket: Socket; handshakeDone: boolean } — threaded
      to the handler, not dereferenced today (void connCtx)."
  - reuse: "HandlerOutcome<T> = { ok:true; result:T } | { ok:false; error:JsonRpcError } — the
      handler's return type; the dispatcher envelopes whichever branch it gets."

TYPE IMPORTS (additive to S11's existing import):
  - add to: "the single `import type {...} from \"./protocol.ts\"` line (S11 created it)"
  - names: "ApplyCompletionParams, ApplyCompletionResult (protocol.ts §C)"

NO INTEGRATION IN S12 (all belong to unimplemented sibling tasks):
  - NOT wired: "into onConnection/dispatcher — that is S8 (P1.M2.T4.S8)."
  - NOT gated: "behind the hello handshake — that is S9/S10 (P1.M2.T5)."
  - NOT wrapped: "by the global dispatch try/catch safety net — that is S15 (P1.M2.T7.S15)."
  - NOT implemented: "S11 getSuggestions (parallel), S13 shouldTriggerFileCompletion, S14 ping/bye/getCommands."
```

## Validation Loop

### Level 1: Syntax & Style (Immediate Feedback)

```bash
# Run after editing pi-editor-bridge.ts — fix before proceeding.
# Type gate (the project's only static check — there is no ruff/eslint/biome here).
tsc --noEmit -p extension/tsconfig.json
# Expected: exit 0, NO output. If errors exist, READ them and fix before proceeding.
# (The type-only protocol.ts import additions, the ConnectionContext/HandlerOutcome module-
#  scope references, and the Error/String globals all type-check under types:[] via lib.dom.)
```

### Level 2: Unit Tests (Component Validation)

```bash
# The new handler's suite — exact jiti register path (verified present):
node --import /home/dustin/.local/lib/node_modules/@earendil-works/pi-coding-agent/node_modules/jiti/lib/jiti-register.mjs \
  extension/tests/handler-applycompletion.test.ts
# Expected: exit 0, `# pass 3`, `# fail 0`. Ignore the benign jiti DEP0205 deprecation on stderr
# (judge by exit code + pass/fail counts).

# Regression — re-run every existing suite (each is a separate node process):
for f in provider-capture mode-guard protocol bridge-lifecycle bridge-lifecycle-wiring handler-getsuggestions; do
  node --import /home/dustin/.local/lib/node_modules/@earendil-works/pi-coding-agent/node_modules/jiti/lib/jiti-register.mjs \
    extension/tests/$f.test.ts && echo "$f: OK"
done
# Expected: each prints `# fail 0` and `$f: OK`. S12 is purely additive; none should regress.
```

### Level 3: Integration Testing (System Validation)

```bash
# Smoke-load the extension in pi's real loader (jiti) in print mode (no TUI). Proves the file
# still parses/loads end-to-end AND the S3 TUI guard is intact (startup log absent in print mode).
pi --no-extensions -e ./extension/pi-editor-bridge.ts --print "ok"
# Expected: exits 0, prints "ok", NO error lines, AND the line
# "pi-editor-bridge: session_start (...)" is ABSENT (the TUI guard suppresses it in print mode).

# (No socket/handshake integration yet — those are S8/S9. The handler is exercised only via
#  direct invocation in the Level 2 unit tests, which is sufficient for S12's contract.)
```

### Level 4: Creative & Domain-Specific Validation

```bash
# (Not applicable for S12 — there is no live socket/dispatcher to drive an end-to-end
#  applyCompletion round-trip until S8/S9 land. The handler's contract is fully covered by
#  the Level 2 unit tests: synchronous delegation, 5-field verbatim passthrough, by-reference
#  result forwarding, never-throw on both failure modes. An integration test that sends a real
#  applyCompletion request over the socket belongs to a later milestone once S8/S9 ship.)
```

## Final Validation Checklist

### Technical Validation

- [ ] Level 1 passed: `tsc --noEmit -p extension/tsconfig.json` → exit 0, no output.
- [ ] Level 2 passed: `handler-applycompletion.test.ts` → `# pass 3`, `# fail 0`.
- [ ] Level 2 regression passed: all 6 existing suites re-run `# fail 0`.
- [ ] Level 3 passed: `pi --no-extensions -e ./extension/pi-editor-bridge.ts --print "ok"` → exit 0, startup log absent.

### Feature Validation

- [ ] All success criteria from "What" section met.
- [ ] `handleApplyCompletion` is a **plain (non-async) function** returning `HandlerOutcome<ApplyCompletionResult>` (NOT `Promise<...>`).
- [ ] All five request fields forwarded verbatim + in order (happy-path test asserts deepEqual of lastCall).
- [ ] Result forwarded by reference (identity) — happy-path test asserts `outcome.result === sentinel`.
- [ ] Never throws: both "not captured" and "provider throws" paths return `{ok:false, error:{-32603, "applyCompletion failed: ..."}}`.
- [ ] Does NOT use async/await/AbortController/pendingAbort/setTimeout/__handlerDeps (sync delegation only).
- [ ] Does NOT reuse or redefine `toRpcError` (inlines its JsonRpcError with the correct "applyCompletion failed" prefix).

### Code Quality Validation

- [ ] Follows existing codebase patterns and naming conventions (matches S11's handleGetSuggestions sibling shape; `handle*` naming; `void connCtx` idiom).
- [ ] File placement matches the desired codebase tree (handler adjacent to handleGetSuggestions; test in `extension/tests/`).
- [ ] Anti-patterns avoided (no async-when-sync, no result cloning, no toRpcError reuse, no duplicate import line).
- [ ] Dependencies properly managed: reuses S11's ConnectionContext/HandlerOutcome (module scope, no import); type-only protocol.ts import additions only.
- [ ] No tsconfig edit (the new test matches the existing `tests/**/*.ts` glob).

### Documentation & Deployment

- [ ] Mode-A JSDoc on `handleApplyCompletion` explains: synchronous-by-design rationale, 5-field verbatim delegation, never-throw single try/catch, inline-error rationale (S15 generalizes), `STATUS (P1.M2.T6.S12)` marker + forward refs (S8/S9/S13/S15).
- [ ] No new environment variables (S12 adds none).

---

## Anti-Patterns to Avoid

- ❌ **Don't make the handler async.** `applyCompletion` is synchronous (verified in compiled pi-tui). Adding `async`/`await` compiles fine but is needlessly complex AND wrong (nothing to await). The signature MUST be `function handleApplyCompletion(...): HandlerOutcome<...>` — NOT `async function` / `Promise<HandlerOutcome<...>>`.
- ❌ **Don't copy getSuggestions' AbortController/supersession/timeout machinery.** Those exist ONLY because `getSuggestions` shells out to `fd` (async, slow, needs cancellation). `applyCompletion` is a pure sync transform — it has nothing to cancel or time out. Copying `pendingAbort`/`__handlerDeps`/`setTimeout` here is cargo-cult complexity.
- ❌ **Don't reuse S11's `toRpcError`.** Its message is hardcoded "getSuggestions failed:" — wrong prefix for applyCompletion. Inline the `JsonRpcError` with "applyCompletion failed:" instead. (And don't redefine a second `toRpcError` — it would collide with S11's module-private one.)
- ❌ **Don't clone or transform the provider's result.** The provider returns a NEW array already (spread `[...lines]`); forward its return object BY REFERENCE. The dispatcher envelopes `result` verbatim.
- ❌ **Don't reorder or repackage the five args.** Forward them as 5 positional args in interface order — `applyCompletion(lines, cursorLine, cursorCol, item, prefix)` — NOT an options object (getSuggestions uses `{signal,force}`; applyCompletion does NOT).
- ❌ **Don't skip the try/catch because "the provider shouldn't throw".** PRD §6.7 mandates never-throw; `getProvider()` itself throws before `session_start`. The single try/catch is non-optional.
- ❌ **Don't create a new pattern when the sibling exists.** Mirror S11's `handleGetSuggestions` JSDoc density, `void connCtx` idiom, `STATUS (...)` marker, and Mode-A doc style — the two handlers are siblings and should read as such.
