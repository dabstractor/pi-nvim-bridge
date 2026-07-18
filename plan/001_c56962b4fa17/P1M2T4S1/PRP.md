---
name: "P1.M2.T6.S11 — getSuggestions handler with AbortController + supersession"
description: |
  Implement the `getSuggestions` JSON-RPC method handler inside the existing
  single extension file `extension/pi-editor-bridge.ts` (NO new module, NO
  tsconfig change). Specifically ADD: (1) a module-level `pendingAbort:
  AbortController | undefined` supersession slot (PRD §6.5 skeleton); (2) a
  `handleGetSuggestions(params, connCtx)` async function that — (a) calls
  `getProvider()` FIRST (it throws if the provider was never captured, short-
  circuiting BEFORE any supersession state is touched), (b) `pendingAbort?.abort()`
  to supersede any in-flight request, (c) `const ac = new AbortController();
  pendingAbort = ac;`, (d) `const t = setTimeout(() => ac.abort(),
  __handlerDeps.timeoutMs)` (1500ms runaway-`fd` safety net, PRD §5.5), (e)
  `await provider.getSuggestions(params.lines, params.cursorLine, params.cursorCol,
  { signal: ac.signal, force: !!params.force })`, (f) `clearTimeout(t)` in a
  `finally`; (3) a `HandlerOutcome<T>` discriminated return type + a
  `ConnectionContext` baseline interface + a `__handlerDeps = { timeoutMs: 1500 }`
  test seam; (4) Mode-A JSDoc explaining supersession + the fd timeout. The
  handler MUST NEVER throw (PRD §6.7): it returns `{ok:true,result}` on success
  and `{ok:false,error:{code,message}}` on failure, so the future dispatcher (S8)
  just envelopes whichever it gets. CRITICAL behavioral finding (research §1):
  pi's `CombinedAutocompleteProvider.getSuggestions` **RESOLVES `null` on abort**
  (it SIGKILLs `fd` and returns `[]`→`null`); it does NOT throw an `AbortError`.
  Therefore supersession/timeout are detected by checking `ac.signal.aborted`
  AFTER the await and mapping an aborted request to a `null` result (harmless:
  the client drops stale responses by `id`, PRD §5.5) — NOT by catching a thrown
  error. This task is NARROW: it does NOT touch `protocol.ts` (type-only import
  only), does NOT wire the handler into any dispatcher/onConnection (S8 territory),
  does NOT implement handshake gating (S9/S10), does NOT add the global try/catch
  safety net (S15), and does NOT implement the sibling handlers S12/S13/S14. It
  ships ONE self-contained, independently-testable handler + its types + its test
  file. (Path note: orchestrator placed artifacts under `P1M2T4S1/`; the item is
  task **P1.M2.T6.S11** in the plan tree — getSuggestions handler. Build the
  handler; ignore the folder label.)
---

## Goal

**Feature Goal**: Land the bridge's `getSuggestions` RPC handler so that, when
the (future, S8) dispatcher calls `handleGetSuggestions(params, connCtx)`, it
delegates to pi's live captured autocomplete provider (`getProvider()`,
dependency P1.M1.T1.S2) with a **per-request `AbortController`**, enforces
**request supersession** (a newer request aborts the in-flight one via the
module-level `pendingAbort` slot) and a **1500 ms runaway-`fd` timeout**, and
**never throws** — returning a discriminated `HandlerOutcome` (success result OR
JSON-RPC error) that the dispatcher envelopes verbatim. The handler is the core
of the RPC layer: every completion keystroke from the Neovim plugin flows through
it, so its supersession/timeout/never-throw guarantees are the bridge's
responsiveness and safety backbone.

**Deliverable** (all under `extension/`):
1. **MODIFY** `extension/pi-editor-bridge.ts` — ADD (after the existing `getProvider()`
   export, before the default-export factory): a type-only import from `./protocol.ts`;
   the `ConnectionContext` baseline interface; the `HandlerOutcome<T>` generic; the
   `__handlerDeps` test seam; the module-level `pendingAbort` slot; a `toRpcError`
   helper; and `handleGetSuggestions(params, connCtx)`. Each addition carries Mode-A
   JSDoc with a `STATUS (P1.M2.T6.S11)` marker + forward references (S8 dispatcher,
   S9/S10 handshake, S15 global try/catch, S12–S14 sibling handlers). The
   **default-export factory, `captureProvider`/`getProvider`/`liveProvider`, the
   S5 bridge-server section, and `protocol.ts` are all UNCHANGED**.
2. **CREATE** `extension/tests/handler-getsuggestions.test.ts` — a `node:test`+jiti
   suite (matching the S2/S3/S4/S5 test conventions) with 6 tests exercising the
   handler directly via a fake provider injected through `captureProvider`, with NO
   socket/dispatcher/handshake involvement (those are unimplemented sibling tasks).

**Success Definition**:
- `tsc --noEmit -p extension/tsconfig.json` → exit 0, **no output** (the type-only
  `protocol.ts` import, the generics, the `ConnectionContext`/`HandlerOutcome`
  types, and `setTimeout`/`AbortController` globals all type-check under the
  current tsconfig with NO tsconfig edit — empirically verified, research §2).
- `node --import <pi>/node_modules/jiti/lib/jiti-register.mjs
  extension/tests/handler-getsuggestions.test.ts` → exit 0, `fail 0` (`pass 6`):
  not-captured error; happy-path result + `force` passthrough + signal-not-aborted;
  provider-returns-null; supersession (B aborts A, A→null, B→result); 1500 ms
  timeout (via the `__handlerDeps.timeoutMs` seam) → null; provider-throws → error.
- Pre-existing suites still green: `provider-capture.test.ts` (S2),
  `mode-guard.test.ts` (S3), `protocol.test.ts` (S4), `bridge-lifecycle.test.ts`
  (S5) — S11 is purely additive to `pi-editor-bridge.ts` and adds one test file.
- Regression: `pi --no-extensions -e ./extension/pi-editor-bridge.ts --print "ok"`
  exits 0 with no error lines AND the startup log is still ABSENT in print mode
  (S3 guard intact — S11 does NOT touch the default-export factory).

## User Persona (if applicable)

**Target User**: The bridge-extension author and the later RPC-layer implementers
(S8 onConnection/dispatcher, S9/S10 handshake, S12/S13/S14 sibling handlers, S15
global error wrapper). This handler defines the **handler↔dispatcher contract**
(`HandlerOutcome` + `ConnectionContext`) every sibling adopts.

**Use Case**: When S8's dispatcher parses a `getSuggestions` request and narrows
its params via `protocol.ts`, it calls `handleGetSuggestions(params, connCtx)`,
awaits the `HandlerOutcome`, and writes `{jsonrpc:"2.0", id, result}` or
`{jsonrpc:"2.0", id, error}` to the socket. When S12–S14 implement
`applyCompletion`/`shouldTriggerFileCompletion`/`ping`/`bye`/`getCommands`, they
follow this handler's exact shape (reuse `HandlerOutcome`/`ConnectionContext`/
`toRpcError`). S15 wraps the dispatch loop in a safety-net try/catch that catches
any handler that forgot to self-wrap.

**Pain Points Addressed**:
- Without per-request `AbortController` + supersession, a slow `fd` run (large
  repo, cold cache) blocks every later keystroke's completion, and the editor
  shows stale suggestions. The `pendingAbort` slot guarantees only the LATEST
  request's `fd` run is alive; earlier ones are SIGKILLed (research §1).
- Without the 1500 ms timeout, a hung `fd` (NFS stall, broken binary) would hang
  the request forever. The timeout aborts the controller → provider resolves null
  → editor degrades to "no suggestions" (PRD §5.5).
- Without never-throw + `HandlerOutcome`, a provider throw would crash the
  dispatcher / kill the connection (PRD §6.7 "Never throws from handlers").

## Why

- **Heart of the completion data path.** Every completion keystroke the Neovim
  plugin sends becomes a `getSuggestions` request. This handler is the only path
  from the wire to pi's live `AutocompleteProvider`, so its supersession + timeout
  + never-throw guarantees ARE the bridge's UX and safety contract.
- **Supersession is required for responsiveness, not optional.** pi's `@`-file
  completion shells out to `fd` (async, up to ~hundreds of ms on big repos). If
  the user types `@sr` then `@src` in quick succession, two `fd` runs race; without
  supersession the older one's (stale) result could land after the newer one's and
  clobber the menu. Aborting the older controller SIGKILLs its `fd` (frees the
  process) AND lets the client drop the stale response by `id` (PRD §5.5). The
  server-side abort is the *resource* optimization; the client-side `id` check is
  the *correctness* mechanism — both are needed.
- **The 1500 ms timeout is the runaway-`fd` safety net (PRD §5.5).** A hung/stalled
  `fd` would otherwise pin a request forever. The timeout aborts → provider resolves
  null → graceful degradation (no suggestions) instead of a hang.
- **Establishes the handler↔dispatcher contract now, so siblings don't diverge.**
  `HandlerOutcome<T>` + `ConnectionContext` + `toRpcError` are defined here first;
  S8/S9/S12–S15 adopt them rather than each inventing their own shape.
- **Single-file, zero-dep, zero-config increment.** Co-located with `getProvider()`
  (the handler's only hard dependency) avoids a circular import with a separate
  handlers module; requires NO tsconfig edit (the file is already in `include`; the
  new test matches the existing `tests/**/*.ts` glob); uses only globals
  (`AbortController`/`setTimeout`) + a type-only `protocol.ts` import — honoring
  PRD §6.7's "Node builtins only, no npm runtime dependencies".

## What

Additive code inside `extension/pi-editor-bridge.ts` + one new test file. No new
module, no tsconfig change, no `protocol.ts` touch (type-only import), no
dispatcher/handshake wiring, no default-export change. The handler is exercised
**only by direct invocation** in tests.

### Success Criteria

- [ ] `handleGetSuggestions(params: GetSuggestionsParams, connCtx: ConnectionContext):
      Promise<HandlerOutcome<GetSuggestionsResult>>` exists and is exported.
- [ ] It calls `getProvider()` FIRST, in its OWN try/catch, so a "not captured" throw
      short-circuits to `{ok:false, error:{code:-32603, message}}` BEFORE any
      supersession state (`pendingAbort`) is touched.
- [ ] On the happy path it does, in order: `pendingAbort?.abort()` → `ac = new
      AbortController(); pendingAbort = ac;` → `t = setTimeout(() => ac.abort(),
      __handlerDeps.timeoutMs)` → `await provider.getSuggestions(params.lines,
      params.cursorLine, params.cursorCol, { signal: ac.signal, force: !!params.force })`
      → returns `{ok:true, result}` → `finally { clearTimeout(t); }`.
- [ ] If the `await` throws AND `ac.signal.aborted` is true (supersession or timeout),
      it returns `{ok:true, result: null}` (abort is not an error — matches pi's
      provider which resolves null on abort, research §1; the client drops stale
      responses by id, PRD §5.5).
- [ ] If the `await` throws AND `ac.signal.aborted` is false (a genuine provider
      error), it returns `{ok:false, error:{code:-32603, message:"getSuggestions
      failed: <err.message>"}}`.
- [ ] `force` is passed through as `!!params.force` (boolean) into the provider's
      options object (mirrors pi's `runAutocompleteRequest`, PRD §2.2).
- [ ] The handler NEVER throws on any input (PRD §6.7): every path returns a
      `HandlerOutcome`. (The future S15 global try/catch is a defense-in-depth
      safety net for truly unexpected bugs, not a replacement.)
- [ ] `finally` clears the timeout (no late abort / no dangling ref'd timer) and
      does **NOT** clear `pendingAbort` (a newer request may own it — research §5).
- [ ] `pendingAbort` is a module-level `let` (the supersession slot); supersession is
      global (single-editor-per-session assumption, research §6).
- [ ] `__handlerDeps = { timeoutMs: 1500 }` is an exported mutable plain object
      (jiti-safe — a plain object *property*, not `export let`); production reads
      1500; tests lower it. Production behavior is byte-identical to a literal 1500.
- [ ] `ConnectionContext` (`{ socket: Socket; handshakeDone: boolean }`) and
      `HandlerOutcome<T>` are exported interfaces/types; the handler does
      `void connCtx;` (threaded for contract uniformity; not dereferenced today).
- [ ] Mode-A JSDoc on the handler explains supersession, the 1500 ms fd-timeout, the
      abort→null provider behavior, and the do-not-clear-pendingAbort rule.
- [ ] `tsc --noEmit -p extension/tsconfig.json` → exit 0, no output.
- [ ] `extension/tests/handler-getsuggestions.test.ts` → 6 tests pass (`fail 0`).
- [ ] S2/S3/S4/S5 suites still pass; `pi --print "ok"` regression exits 0.

## All Needed Context

### Context Completeness Check

_Pass test_: An agent who has never seen this repo, given the current
`extension/pi-editor-bridge.ts` (post-S5), `extension/protocol.ts` (post-S4),
`extension/tsconfig.json`, and this PRP, can (1) add the handler section verbatim
from the reference body below (every type, signature, and the exact
`pendingAbort`/`__handlerDeps`/`toRpcError`/`handleGetSuggestions` shape is pinned),
(2) write the test from the supplied skeleton, (3) run the four validation commands
to green — with the provider's abort→null behavior, the global-availability of
`setTimeout`/`AbortController` under `types:[]`, the `captureProvider` injection
idiom, and the do-not-clear-`pendingAbort` rule all cited and empirically verified
in the research notes.

### Documentation & References

```yaml
# MUST READ — the component spec (S11 implements §6.5 getSuggestions verbatim + honors §5.5 + §6.7)
- docfile: PRD.md
  why: §6.5 Request handling reference skeleton (the EXACT supersession/timeout/abort shape this handler implements — requireProvider→pendingAbort?.abort()→new AC→setTimeout(1500)→await→finally clearTimeout); §5.5 Timing & cancellation (per-request AbortController, supersession by id, 1500ms fd timeout, the client drops stale responses — the AUTHORITY on supersession); §5.4 Methods (getSuggestions params {lines,cursorLine,cursorCol,force?} → AutocompleteSuggestions|null); §6.7 Requirements checklist ("Never throws from handlers (wrap in try/catch, return JSON-RPC error)", "Never blocks the event loop synchronously (all getSuggestions are awaited)"); §2.2 The autocomplete engine (AutocompleteProvider.getSuggestions(lines,cursorLine,cursorCol,{signal,force}) — the provider the handler delegates to)
  section: "§6.5 (getSuggestions skeleton — implement verbatim + add connCtx + HandlerOutcome), §5.5 (timing/cancellation authority), §5.4 (method signature), §6.7 (never-throw + never-block reqs), §2.2 (provider interface)"
  critical: |
    §6.5's skeleton returns the RAW result and has NO connCtx param. The item contract refines
    it: name the fn handleGetSuggestions(params, connCtx) and return a HandlerOutcome (so it
    never throws, satisfying §6.7 explicitly). The supersession/timeout/abort SEQUENCE is
    byte-identical to §6.5; only the wrapper shape differs. §6.5's `pendingAbort` is MODULE-LEVEL
    (not per-connection) — match that. §6.5 does NOT clear pendingAbort in finally — match that too
    (a newer request may own it). §5.5 is the supersession authority: server aborts (resource opt),
    client drops stale by id (correctness).

# MUST READ — the pre-researched, empirically-verified analysis FOR THIS EXACT TASK
- docfile: plan/001_c56962b4fa17/P1M2T4S1/research/notes.md
  why: the authoritative task analysis: §1 the LOAD-BEARING finding that pi's provider RESOLVES null on abort (does NOT throw AbortError) → shapes the whole handler (detect abort via signal.aborted AFTER await, map to null); §2 globals (AbortController/setTimeout/clearTimeout) type-check under types:[] via lib.dom (NO new runtime imports — only type-only protocol.ts import); §3 the captureProvider fake-provider injection idiom for tests; §4 PRD §5.5/§6.7 authority; §5 AbortController/setTimeout mechanics (abort idempotent, finally clearTimeout safe, do-NOT-clear pendingAbort); §6 single-editor → module-level supersession correct; §7 __handlerDeps.timeoutMs seam rationale; §8 verified validation commands.
  section: "all sections (§1 abort behavior is the single most load-bearing claim)"
  critical: |
    §1 is the make-or-break insight: the handler's try/catch around provider.getSuggestions will
    almost NEVER catch an AbortError (the provider resolves null instead). So supersession/timeout
    are detected by `if (ac.signal.aborted) return {ok:true,result:null}` AFTER the await, NOT by
    catching. Getting this wrong = a superseded request surfacing as a -32603 error (wrong).

# MUST READ — the JSON-RPC types the handler consumes/produces (type-only import source)
- file: extension/protocol.ts
  why: the type-only module S11 imports GetSuggestionsParams/GetSuggestionsResult/JsonRpcError from. §C defines GetSuggestionsParams{lines,cursorLine,cursorCol,force?} and GetSuggestionsResult=AutocompleteSuggestions|null; §A defines JsonRpcError{code,message} and lists the spec error codes (-32603 internal error is the one S11 uses for provider/getProvider failures). Re-exports AutocompleteItem/AutocompleteSuggestions from pi-tui.
  section: "§A (JsonRpcError + error-code comment: -32700/-32600/-32601/-32602/-32603), §C (GetSuggestionsParams, GetSuggestionsResult)"
  critical: |
    S11 imports ONLY types from protocol.ts (import type {...} from "./protocol.ts") — protocol.ts
    is type-only (zero runtime exports; protocol.test.ts confirms it loads as an empty namespace).
    DO NOT add a value import. DO NOT edit protocol.ts (it is the S4 contract; S11 is type-only consumer).

# MUST READ — the baseline S11 builds on (defines getProvider, the handler's only hard dependency)
- docfile: plan/001_c56962b4fa17/P1M1T1S3/PRP.md
  why: defines the post-S3 shape of extension/pi-editor-bridge.ts: captureProvider/getProvider/liveProvider (the singleton the handler reads via getProvider()), the TUI-guarded session_start, and the unwired TODO call site. getProvider() THROWS "pi-editor-bridge: autocomplete provider not captured yet" when liveProvider is undefined — S11's first try/catch handles exactly that throw.
  section: "getProvider() implementation (throws /not captured/) + liveProvider singleton"
  critical: |
    S11's "not captured" path is just: try { provider = getProvider(); } catch { return error }.
    getProvider already exists (S1/S2); S11 does NOT modify it. The throw message is fixed
    ("...not captured yet (await session_start)"); S11's toRpcError surfaces it in the JSON-RPC error.

# MUST READ — the contract S11 builds on (S5 lands first; treats as already-merged)
- docfile: plan/001_c56962b4fa17/P1M2T3S5/PRP.md
  why: S5 ADDS the bridge-server section to pi-editor-bridge.ts (node:net value imports incl. `type Socket`; __deps seam; module state server/socketPath/token; getters; onConnection placeholder; startBridge/stopBridge). S11 is ADDITIVE to that post-S5 file: it relies on S5's `import { ..., type Socket } from "node:net"` for the ConnectionContext.socket field, and places its handler section after getProvider()/near the S5 server section. S11 does NOT depend on S5's runtime (no getServer/onConnection call) — only on the Socket TYPE being in scope.
  section: "the `import { createServer, type Server, type Socket } from "node:net"` line + the placement note (S11's section goes after getProvider, before the default export, independent of the S5 server section)"
  critical: |
    If S5's import line somehow omits `type Socket`, ADD it to that existing import line (do NOT
    create a duplicate `import ... from "node:net"`). S11's ConnectionContext references `Socket`.
    S11 does NOT call getServer()/onConnection()/startBridge() — it is independent of S5's runtime.

# SUPPORTING — house test conventions (S11's test follows these exactly)
- file: extension/tests/provider-capture.test.ts
  why: the canonical node:test+jiti test pattern in THIS repo AND the exact fake-provider injection idiom S11 reuses: captureProvider({ui:{addAutocompleteProvider: f=>f(fakeProvider)}}) sets the module singleton liveProvider to fakeProvider. Also documents the shared-module-state sequential-test caveat (the "not captured" test must run FIRST, before any install) that S11 inherits.
  section: "makeFakeProvider helper; the runCapture({ui:{addAutocompleteProvider:...}}) injection; the FIRST-test-sees-undefined ordering caveat"

- file: extension/tests/mode-guard.test.ts
  why: confirms node:test top-level `test(...)` (no describe), `import assert from "node:assert/strict"`, jiti register-hook path, fake-ctx `{} as ExtensionContext` construction, TAB indentation.
  section: "whole file — import style, fakeCtx construction, sequential shared-state note"

# SUPPORTING — the abort→null behavior verification (the §1 finding, primary-sourced)
- file: /home/dustin/.local/lib/node_modules/@earendil-works/pi-coding-agent/node_modules/@earendil-works/pi-tui/dist/autocomplete.js
  why: confirms walkDirectoryWithFd (L~100) resolve([]) on signal.aborted + SIGKILL on abort listener; getFuzzyFileSuggestions (L~577) returns [] when aborted; getSuggestions returns null when suggestions.length===0. Path completion (getFileSuggestions, readdirSync) ignores the signal entirely. → abort resolves null (for @/fd) or completes normally (sync path/slash); NEVER throws AbortError.
  section: "walkDirectoryWithFd (abort→SIGKILL→resolve([])); getFuzzyFileSuggestions (aborted→[]); getSuggestions (empty→null)"
  critical: |
    This is why the handler checks signal.aborted AFTER await instead of catching AbortError. The
    compiled .js is the shipped behavior the handler must mirror in its fake provider for tests.

# SUPPORTING — pi's own caller (confirms the {signal, force} options object shape + force semantics)
- url: https://nodejs.org/api/globals.html#abortcontroller
  why: AbortController/AbortSignal are Node globals (since v15); abort() is idempotent; signal.aborted is a stable boolean. Confirms NO import needed (global) — and that lib.dom provides the types under types:[] (research §2).
  section: "Class: AbortController; AbortController.abort(); AbortSignal.aborted"

- url: https://www.jsonrpc.org/specification#response_object
  why: confirms a Request with `id` MUST get exactly one Response (success OR error); Notifications (no id) get none. PRD §5.5 governs supersession (server responds, client drops stale by id); S11 does not need a -32800 RequestCancelled error.
  section: "§5 Response object (exactly one response per request id); §5.1 Error object code/message"
```

### Current Codebase tree (post-S5 baseline — S11 ADDS to pi-editor-bridge.ts + 1 test)

```bash
extension/
├── pi-editor-bridge.ts   # (S1+S2+S3+S5) default-export factory; session_start (TUI guard + log + captureProvider) + session_shutdown (no-op); captureProvider/getProvider/liveProvider; [S5] node:net import (incl type Socket); __deps; server/socketPath/token + getters; onConnection placeholder; startBridge/stopBridge. S11 ADDS the handler section here (NOT a new file).
├── protocol.ts           # (S4) type-only JSON-RPC contract. S11 imports TYPES from it (no edit).
├── tsconfig.json         # (S1+S2+S4+S5) include covers pi-editor-bridge.ts/protocol.ts/tests/**/*.ts; NO lib field (→ DOM defaults → setTimeout/AbortController globals type-check). S11 does NOT edit.
└── tests/
    ├── provider-capture.test.ts  # (S2) — S11 reuses its fake-provider injection idiom
    ├── mode-guard.test.ts        # (S3)
    ├── protocol.test.ts          # (S4)
    └── bridge-lifecycle.test.ts  # (S5)
# plan/ holds planning artifacts only — no other source code
```

### Desired Codebase tree with files to be added/modified

```bash
extension/
├── pi-editor-bridge.ts   # (MODIFY) ADD: type-only import from ./protocol.ts; ConnectionContext interface; HandlerOutcome<T> type; __handlerDeps seam; pendingAbort module slot; toRpcError helper; handleGetSuggestions. Default-export factory + captureProvider/getProvider/liveProvider + S5 server section UNCHANGED.
├── protocol.ts           # (UNCHANGED — S4; S11 is type-only consumer)
├── tsconfig.json         # (UNCHANGED)
└── tests/
    ├── provider-capture.test.ts  # (UNCHANGED — S2)
    ├── mode-guard.test.ts        # (UNCHANGED — S3)
    ├── protocol.test.ts          # (UNCHANGED — S4)
    ├── bridge-lifecycle.test.ts  # (UNCHANGED — S5)
    └── handler-getsuggestions.test.ts  # (CREATE) node:test+jiti: 6 tests (not-captured; happy-path+force+signal-not-aborted; returns-null; supersession; timeout→null; provider-throws→error) via fake provider injected through captureProvider.
```

**File responsibilities**
- `extension/pi-editor-bridge.ts` — gains the `getSuggestions` RPC handler runtime +
  the shared handler↔dispatcher contract types (`ConnectionContext`, `HandlerOutcome`,
  `toRpcError`) that S8/S9/S12–S15 adopt. The new `__handlerDeps` seam is the test
  surface; `pendingAbort` is the supersession slot.
- `extension/tests/handler-getsuggestions.test.ts` — the contract gate for S11:
  proves supersession (B aborts A), the 1500 ms timeout aborts a runaway provider
  (via the seam), never-throw on every path, and `force` passthrough — all with a
  fake provider that mirrors the real abort→null behavior.

### Known Gotchas of our codebase & Library Quirks

```typescript
// CRITICAL (verified, research §1): pi's CombinedAutocompleteProvider.getSuggestions RESOLVES
//   null on abort — it does NOT throw AbortError. walkDirectoryWithFd SIGKILLs fd on the abort
//   listener and resolve([]); getFuzzyFileSuggestions returns [] when aborted; getSuggestions
//   returns null when suggestions.length===0. (Path/slash completion is sync readdirSync/fuzzyFilter
//   and ignores the signal — it completes normally even if aborted.)
//   CONSEQUENCE: the handler's try/catch around provider.getSuggestions will almost never catch
//   an AbortError. Detect supersession/timeout by checking `ac.signal.aborted` AFTER the await
//   and map an aborted request to {ok:true, result:null}. Catching alone would wrongly surface
//   a superseded/timeout request as a -32603 error.

// CRITICAL (verified, research §2): setTimeout/clearTimeout/AbortController/AbortSignal/Error/console
//   are GLOBALS that type-check under the current tsconfig (types:[]) because the tsconfig has NO
//   `lib` field → TypeScript defaults to including lib.dom.d.ts, which declares them. (If lib were
//   restricted to ES2022 they'd be TS2304 and you'd need `import {setTimeout} from "node:timers"`,
//   but it is NOT.) So the handler needs NO new runtime import for the timeout/abort machinery —
//   only a TYPE-ONLY import from ./protocol.ts. DO NOT add node:timers / node:async_hooks imports.

// CRITICAL (PRD §6.7): "Never throws from handlers." The handler MUST catch every path and return
//   a HandlerOutcome. Do NOT let getProvider()'s throw or provider.getSuggestions()'s throw escape.
//   (S15's global try/catch is a safety NET for truly unexpected bugs, not a substitute.)

// CRITICAL (PRD §6.5 skeleton + research §5): do NOT clear `pendingAbort` in the finally block.
//   A newer request may have already reassigned pendingAbort to ITS controller; clearing
//   unconditionally would drop the newer request's controller. pendingAbort simply always points
//   at the LATEST controller; older controllers are GC'd once their owning call stack unwinds.

// CRITICAL (ordering): call getProvider() FIRST, in its OWN try/catch, BEFORE pendingAbort?.abort().
//   Rationale: if the provider isn't captured, there's nothing to serve — aborting a valid pending
//   request would waste it. A "not captured" failure must short-circuit without touching supersession
//   state. (This is the item contract step (a) before (b).)

// GOTCHA (jiti): expose mutable test state via a plain-object PROPERTY, NOT `export let`. jiti does
//   not implement cross-module live-binding reassignment of `export let` (verified in S5 research).
//   `export const __handlerDeps = { timeoutMs: 1500 }` is safe — tests mutate __handlerDeps.timeoutMs
//   (a property), which IS observed cross-module. Matches the S5 __deps idiom.

// GOTCHA (test isolation): liveProvider is a module singleton shared across tests in ONE process.
//   node:test runs top-level tests SEQUENTIALLY in definition order (do NOT enable concurrency).
//   The "not captured" test MUST be the FIRST test (before any captureProvider install), exactly
//   like provider-capture.test.ts. Each test FILE is a separate node process → liveProvider starts
//   undefined per file. pendingAbort also persists across tests but is harmless (each call reassigns it).

// GOTCHA: the fake provider in tests MUST mirror the real provider's abort→null behavior (resolve
//   null when signal.aborted), or the supersession/timeout tests will not exercise the real code path.
//   See the makeFakeProvider skeleton in Implementation Patterns.

// GOTCHA: `void connCtx;` — the handler accepts connCtx for handler-contract uniformity (S8/S9 pass
//   it to every handler) but does NOT dereference it today (provider is a module singleton;
//   supersession is module-level; result is returned for the dispatcher to envelope). tsconfig has
//   no noUnusedParameters, so `void connCtx;` is a clarity marker, not a compile requirement.

// GOTCHA: ConnectionContext.socket uses `Socket`, imported by S5 as `import {..., type Socket} from
//   "node:net"`. If that import line omits Socket, ADD `type Socket` to the EXISTING import line —
//   do NOT create a second `import ... from "node:net"` (duplicate-import error).

// STYLE: TABS for indentation (match the existing pi-editor-bridge.ts + pi examples). `import type`
//   for ALL type-only imports (protocol.ts, the inline `type` modifier for Socket is S5's). Mode-A
//   JSDoc on every new export with a `STATUS (P1.M2.T6.S11)` marker + forward refs (S8/S9/S12–S15).
```

## Implementation Blueprint

### Data models and structure

S11 adds no new **wire** types (those live in `protocol.ts`, S4). Its "data model"
is **handler-contract types** + **module-level supersession state** + a **test seam**:

- `ConnectionContext` (exported interface) — the per-connection object S8 creates &
  S9 authenticates, threaded to every handler. Baseline shape: `{ socket: Socket;
  handshakeDone: boolean }`. S9/S10 set `handshakeDone`; S8 may add fields. S11's
  handler does not dereference it.
- `HandlerOutcome<T>` (exported generic type) — `{ ok: true; result: T } | { ok:
  false; error: JsonRpcError }`. The discriminated return every handler produces;
  the dispatcher (S8) envelopes whichever branch it gets into a `JsonRpcResponse`.
- `__handlerDeps` (exported mutable plain object) — `{ timeoutMs: 1500 }`. The test
  seam for the runaway-fd timeout; production reads 1500.
- `pendingAbort` (module-level `let`) — `AbortController | undefined`. The
  supersession slot; always points at the latest request's controller.
- `toRpcError(err, code)` (module-private helper) — maps a thrown `unknown` to a
  `JsonRpcError` (uses `-32603` internal error for getSuggestions failures).

### Implementation Tasks (ordered by dependencies)

```yaml
Task 1: MODIFY extension/pi-editor-bridge.ts — ADD type-only protocol import
  - ADD (near the top, with the existing `import type {...} from "@earendil-works/..."` blocks):
        import type { GetSuggestionsParams, GetSuggestionsResult, JsonRpcError } from "./protocol.ts";
  - NOTE: protocol.ts is TYPE-ONLY (zero runtime exports); `import type` adds nothing at runtime.
      GetSuggestionsParams/GetSuggestionsResult/JsonRpcError are all exported from protocol.ts §A/§C.
  - DO NOT: add a value import from protocol.ts; edit protocol.ts; re-import AutocompleteProvider
      (already imported at the top from @earendil-works/pi-tui — reused for the local provider var).

Task 2: MODIFY extension/pi-editor-bridge.ts — VERIFY/ENSURE `type Socket` is imported
  - S5 adds `import { createServer, type Server, type Socket } from "node:net";`. VERIFY that line
      exists post-S5 and includes `type Socket`. If it omits Socket, ADD `type Socket` to that
      EXISTING import line (do NOT create a second `import ... from "node:net"`).
  - WHY: ConnectionContext.socket (Task 3) references `Socket`. It MUST be in scope.

Task 3: MODIFY extension/pi-editor-bridge.ts — ADD the handler section
  - PLACE: AFTER the existing `getProvider()` function export, BEFORE the
      `export default function (pi: ExtensionAPI): void {` factory. (Co-locates with getProvider,
      the handler's only hard dependency. If S5's bridge-server section is present, this handler
      section may go either before or after it — they are independent; keep handler code grouped.)
  - ADD (each with Mode-A JSDoc + STATUS marker; see Implementation Patterns for the exact body):
      (a) `export interface ConnectionContext { readonly socket: Socket; handshakeDone: boolean; }`
          — baseline; JSDoc notes S8 populates it, S9 sets handshakeDone, S11 does not deref.
      (b) `export type HandlerOutcome<T> = { ok: true; result: T } | { ok: false; error: JsonRpcError };`
          — the discriminated return all handlers adopt; JSDoc notes S8 envelopes it into JsonRpcResponse.
      (c) `export const __handlerDeps: { timeoutMs: number } = { timeoutMs: 1500 };` — test seam;
          JSDoc notes production reads 1500, tests lower it; plain-object property (jiti-safe).
      (d) `let pendingAbort: AbortController | undefined;` — module-level supersession slot.
      (e) `function toRpcError(err: unknown, code: number): JsonRpcError` — maps thrown unknown →
          `{ code, message: \`getSuggestions failed: ${err instanceof Error ? err.message : String(err)}\` }`.
      (f) `export async function handleGetSuggestions(params: GetSuggestionsParams, connCtx:
          ConnectionContext): Promise<HandlerOutcome<GetSuggestionsResult>>` — the handler. Body:
          `void connCtx;`; FIRST try { provider = getProvider(); } catch (err) { return
          {ok:false, error: toRpcError(err, -32603)}; }; then pendingAbort?.abort(); const ac = new
          AbortController(); pendingAbort = ac; const t = setTimeout(() => ac.abort(),
          __handlerDeps.timeoutMs); try { const result = await provider.getSuggestions(params.lines,
          params.cursorLine, params.cursorCol, { signal: ac.signal, force: !!params.force }); return
          { ok: true, result }; } catch (err) { if (ac.signal.aborted) return { ok: true, result: null };
          return { ok: false, error: toRpcError(err, -32603) }; } finally { clearTimeout(t); }
  - FOLLOW: TAB indentation; match the JSDoc density/STATUS style of captureProvider/getProvider.
  - NAMING: handleGetSuggestions / HandlerOutcome / ConnectionContext / __handlerDeps / pendingAbort
      / toRpcError — exact (camelCase fn/var, PascalCase type/interface; __handlerDeps double-
      underscore signals "test seam, not public API"; matches S5's __deps convention).
  - DO NOT: alter captureProvider/getProvider/liveProvider; alter the default-export factory; touch
      the S5 server section; edit protocol.ts; add a server 'error' handler; clear pendingAbort in
      finally; wire the handler into onConnection/dispatcher (S8); add handshake gating (S9/S10);
      add the global try/catch (S15); implement S12/S13/S14.

Task 4: CREATE extension/tests/handler-getsuggestions.test.ts (node:test + jiti)
  - IMPORT: `import { test } from "node:test"; import assert from "node:assert/strict";`
      `import type { AutocompleteProvider, AutocompleteSuggestions } from "@earendil-works/pi-tui";`
      `import type { ExtensionContext } from "@earendil-works/pi-coding-agent";`
      `import { captureProvider, handleGetSuggestions, __handlerDeps, type HandlerOutcome, type
      ConnectionContext } from "../pi-editor-bridge.ts";`
  - HELPERS: `installProvider(p)` = captureProvider({ui:{addAutocompleteProvider:f=>f(p)}} as
      ExtensionContext) — sets the module singleton liveProvider to p. `makeFakeProvider({result?,
      delayMs?, onSignal?, onCall?})` returns an AutocompleteProvider whose getSuggestions mirrors
      the REAL abort→null behavior: records the call (lines/cursorLine/cursorCol/force) +
      onSignal(signal), waits delayMs (if >0) on a Promise that ALSO resolves on signal abort, then
      returns null if signal.aborted else result. `fakeConnCtx = { socket: {} as any,
      handshakeDone: true } as ConnectionContext`. `unwrap<T>(o)` helper narrowing the ok-branch.
  - TEST 1 (FIRST — not captured): with NO provider installed, call handleGetSuggestions; assert
      outcome.ok===false, error.code===-32603, error.message matches /not captured/. (liveProvider
      is undefined at the start of this fresh process — same idiom as provider-capture.test.ts's
      first test.)
  - TEST 2 (happy path): install a provider returning {items:[{value:"/model",label:"/model"}],
      prefix:"/mo"}; call with {lines:["/mo"],cursorLine:0,cursorCol:3,force:true}; assert
      outcome.ok===true, result deep-equals the suggestions; assert the provider received force===true
      (force passthrough); assert the captured signal.aborted===false (timeout was cleared, no late abort).
  - TEST 3 (returns null): install a provider whose getSuggestions returns null; call; assert
      outcome.ok===true, result===null.
  - TEST 4 (supersession): install a provider with delayMs:30 that records each call's signal into
      `signals[]`; `const pA = handleGetSuggestions(A, fakeConnCtx);` then `const pB =
      handleGetSuggestions(B, fakeConnCtx);` SYNCHRONOUSLY assert signals[0].aborted===true (A
      superseded by B) and signals[1].aborted===false (B is live); then `const [oA,oB] = await
      Promise.all([pA,pB]);` assert oA.ok===true && result===null (A aborted→null) and oB.ok===true
      with B's result. (The synchronous assertion works because B's pendingAbort?.abort() runs in B's
      handler prefix BEFORE B's await yields — research §5.)
  - TEST 5 (timeout → null): stash original `__handlerDeps.timeoutMs`; set it to 10; install a
      provider with delayMs:100 returning real suggestions; call; assert outcome.ok===true &&
      result===null (the 10ms timer aborts before the 100ms provider resolves → null); restore
      timeoutMs in finally. (Proves the 1500ms runaway-fd safety net WITHOUT a 1500ms wait.)
  - TEST 6 (provider throws → error, non-abort): install a provider whose getSuggestions throws
      `new Error("boom")` synchronously (delay 0, never aborted); call; assert outcome.ok===false,
      error.code===-32603, error.message matches /boom/.
  - SHARED-STATE CAVEAT: module singleton → tests run SEQUENTIALLY (node:test default; do NOT enable
      concurrency); TEST 1 (not-captured) is FIRST. Each real test installs its own provider.
  - FOLLOW: TAB indentation; reuse the SAME jiti register hook path as S2/S3/S4/S5 tests.
  - NAMING: descriptive `test("...", ...)` titles; no `describe`.
  - PLACEMENT: extension/tests/handler-getsuggestions.test.ts (matches tests/**/*.ts → NO tsconfig edit).

Task 5: VALIDATE — run the validation commands; fix until all green
  - RUN (Level 1): `tsc --noEmit -p extension/tsconfig.json` (expect exit 0, no output)
  - RUN (Level 2): `node --import <jiti-register> extension/tests/handler-getsuggestions.test.ts`
      (expect exit 0, fail 0, pass 6; ignore the benign jiti DEP0205 deprecation on stderr)
  - RUN (Level 2 regression): re-run provider-capture.test.ts + mode-guard.test.ts +
      protocol.test.ts + bridge-lifecycle.test.ts — expect each fail 0
  - RUN (Level 3): `pi --no-extensions -e ./extension/pi-editor-bridge.ts --print "ok"` exits 0
      with NO error lines AND the startup-log line ABSENT in print mode (S3 intact)
```

### Implementation Patterns & Key Details

```typescript
// === extension/pi-editor-bridge.ts — ADD this import near the top (with the existing
//     `import type {...} from "@earendil-works/..."` blocks). TYPE-ONLY (zero runtime). ===
import type {
	GetSuggestionsParams,
	GetSuggestionsResult,
	JsonRpcError,
} from "./protocol.ts";

// === extension/pi-editor-bridge.ts — ADD the handler section AFTER getProvider(),
//     BEFORE the `export default function (pi: ExtensionAPI): void {` factory. ===

/**
 * Per-connection context the future dispatcher (S8) creates and the handshake (S9)
 * authenticates, threaded to every RPC handler for uniformity. Baseline shape;
 * S8/S9 EXTEND this (add client info, etc.). getSuggestions does NOT dereference
 * it today (the provider is a module singleton; supersession is module-level; the
 * result is returned for the dispatcher to envelope) — see `void connCtx` in the handler.
 *
 * STATUS (P1.M2.T6.S11): defines the baseline. S8 populates `socket` + `handshakeDone`;
 * S9/S10 gate dispatch on `handshakeDone`; S17 (commandsChanged) will broadcast over
 * `socket`. Do not redefine — adopt/extend.
 */
export interface ConnectionContext {
	/** The live socket for this connection (future: notifications / write-back). */
	readonly socket: Socket;
	/** True once `hello` handshake succeeded (S9). Handlers may gate on this. */
	handshakeDone: boolean;
}

/**
 * The discriminated outcome every RPC handler returns: success carries the typed
 * `result`; failure carries a JSON-RPC `error`. The dispatcher (S8) envelopes
 * whichever branch it receives into a `JsonRpcResponse` and writes it to the socket.
 *
 * WHY A DISCRIMINATED OUTCOME (not throw): PRD §6.7 requires handlers to NEVER throw
 * ("wrap in try/catch, return JSON-RPC error"). Returning `{ok:false,error}` makes
 * the never-throw contract explicit and type-safe. (S15 adds a global try/catch as a
 * safety NET for truly unexpected handler bugs, not a replacement for self-wrapping.)
 *
 * STATUS (P1.M2.T6.S11): introduced for getSuggestions; S12/S13/S14 reuse it for
 * applyCompletion/shouldTriggerFileCompletion/ping/bye/getCommands.
 */
export type HandlerOutcome<T> =
	| { ok: true; result: T }
	| { ok: false; error: JsonRpcError };

/**
 * Mutable dependency seam for the getSuggestions runaway-`fd` timeout, defaulting to
 * 1500 ms (PRD §5.5) so production behavior is byte-identical to a literal `1500`.
 *
 * WHY A SEAM: node:test has no built-in fake timers, and a real 1500 ms wait per test
 * is too slow. A mutable plain-object PROPERTY (not `export let` — jiti does not
 * live-bind `export let` cross-module, verified in S5 research) lets tests lower it
 * (`__handlerDeps.timeoutMs = 10`) to exercise the timeout-aborts-runaway-provider path
 * fast and deterministically, then restore. Matches the S5 `__deps` idiom.
 *
 * STATUS (P1.M2.T6.S11): getSuggestions-only seam.
 */
export const __handlerDeps: { timeoutMs: number } = {
	timeoutMs: 1500,
};

/**
 * The supersession slot: always points at the LATEST getSuggestions request's
 * AbortController (or undefined when idle). A new request aborts the previous one
 * (`pendingAbort?.abort()`) so only the latest `fd` run stays alive (PRD §5.5/§6.5).
 *
 * MODULE-LEVEL (not per-connection): the bridge serves ONE editor per pi session
 * (the `$EDITOR` pi launches); cross-connection supersession is benign. (If a future
 * multi-editor scenario arises, hoist this into ConnectionContext — out of scope here.)
 */
let pendingAbort: AbortController | undefined;

/**
 * Map a thrown `unknown` to a JSON-RPC error object. Uses code -32603 (internal error)
 * for getSuggestions failures (provider threw / provider not captured). Kept
 * module-private; S15 may generalize it across handlers later.
 */
function toRpcError(err: unknown, code: number): JsonRpcError {
	const message = err instanceof Error ? err.message : String(err);
	return { code, message: `getSuggestions failed: ${message}` };
}

/**
 * Handle a `getSuggestions` JSON-RPC request: delegate to pi's live autocomplete
 * provider with a per-request AbortController, enforcing request SUPERSESSION (a
 * newer request aborts the in-flight one via {@link pendingAbort}) and a 1500 ms
 * runaway-`fd` timeout (PRD §5.5/§6.5). NEVER throws (PRD §6.7): returns a
 * {@link HandlerOutcome} the dispatcher envelopes into a `JsonRpcResponse`.
 *
 * SUPERSESSION: `getProvider()` is called FIRST (in its own try/catch) so a
 * "not captured" failure short-circuits BEFORE any supersession state is touched.
 * Then `pendingAbort?.abort()` supersedes the in-flight request, a fresh controller
 * becomes the new `pendingAbort`, and a 1500 ms timer aborts it if `fd` runs away.
 * `pendingAbort` is intentionally NOT cleared in `finally` — a newer request may own it.
 *
 * ABORT BEHAVIOR (verified, research §1): pi's `CombinedAutocompleteProvider`
 * RESOLVES `null` on abort (it SIGKILLs `fd` → `[]` → `null`) — it does NOT throw an
 * AbortError. So supersession/timeout are detected by checking `ac.signal.aborted`
 * AFTER the await and mapping an aborted request to a `null` result (not an error).
 * The client drops stale responses by `id` (PRD §5.5), so a superseded null is harmless;
 * a TIMEOUT null is the desired graceful degradation (hung `fd` → no suggestions).
 *
 * @param params `{ lines, cursorLine, cursorCol, force? }` (PRD §5.4; cursorCol is a
 *   0-indexed UTF-16 offset, PRD §8). `force` is passed through as `!!force`.
 * @param connCtx the connection context (S8/S9); threaded for handler-contract
 *   uniformity — NOT dereferenced today (signaled with `void connCtx`).
 * @returns success → `{ok:true, result: AutocompleteSuggestions | null}`;
 *   failure → `{ok:false, error:{code:-32603, message}}`.
 *
 * STATUS (P1.M2.T6.S11): the getSuggestions handler. S8 wires it into the dispatcher;
 * S9/S10 gate it behind the hello handshake; S15 wraps the dispatch loop in a safety-net
 * try/catch; S12–S14 add the sibling handlers following this same shape.
 */
export async function handleGetSuggestions(
	params: GetSuggestionsParams,
	connCtx: ConnectionContext,
): Promise<HandlerOutcome<GetSuggestionsResult>> {
	void connCtx; // threaded for handler-contract uniformity; not dereferenced today

	// (a) Resolve the provider FIRST. getProvider() throws if never captured (before
	//     session_start). Catch in its OWN try so a "not captured" failure short-circuits
	//     BEFORE we touch the supersession slot (no point aborting a valid pending request
	//     when there's nothing to serve this one with).
	let provider;
	try {
		provider = getProvider();
	} catch (err) {
		return { ok: false, error: toRpcError(err, -32603) };
	}

	// (b)+(c) Supersede any in-flight request, then install this request's controller as
	//        the new latest. Single-editor-per-session → module-level slot is correct.
	pendingAbort?.abort(); // no-op if undefined; idempotent
	const ac = new AbortController();
	pendingAbort = ac;

	// (d) Runaway-`fd` safety net (PRD §5.5). __handlerDeps.timeoutMs is a test seam
	//     (tests lower it); production reads 1500. Cleared in `finally` (no leak / no
	//     late abort). NOTE: do NOT clear `pendingAbort` in finally (a newer request may own it).
	const t = setTimeout(() => ac.abort(), __handlerDeps.timeoutMs);
	try {
		// (e) Delegate to pi's live provider with this request's signal + force passthrough.
		const result = await provider.getSuggestions(
			params.lines,
			params.cursorLine,
			params.cursorCol,
			{ signal: ac.signal, force: !!params.force },
		);
		return { ok: true, result };
	} catch (err) {
		// The provider normally RESOLVES null on abort (does not throw). But IF a wrapped
		// provider throws on abort, treat it as the null result it semantically is (abort
		// is not an error — the client drops stale responses by id, PRD §5.5; a timeout
		// null is graceful degradation). Only surface a genuine (non-abort) throw as an error.
		if (ac.signal.aborted) {
			return { ok: true, result: null };
		}
		return { ok: false, error: toRpcError(err, -32603) };
	} finally {
		// (f) Always clear the timer (success, abort, or throw). NEVER clear pendingAbort
		//     here — a newer request may have already reassigned it to its own controller.
		clearTimeout(t);
	}
}
```

```typescript
// === extension/tests/handler-getsuggestions.test.ts (CREATE — node:test + jiti) ===
import { test } from "node:test";
import assert from "node:assert/strict";
import type {
	AutocompleteProvider,
	AutocompleteSuggestions,
} from "@earendil-works/pi-tui";
import type { ExtensionContext } from "@earendil-works/pi-coding-agent";
import {
	captureProvider,
	handleGetSuggestions,
	__handlerDeps,
} from "../pi-editor-bridge.ts";
import type { ConnectionContext, HandlerOutcome } from "../pi-editor-bridge.ts";

// Inject a fake provider into the module singleton (liveProvider) via the EXACT
// captureProvider idiom from provider-capture.test.ts: the fake
// addAutocompleteProvider INVOKES the pass-through factory with our provider,
// which assigns liveProvider = provider.
function installProvider(p: AutocompleteProvider): void {
	captureProvider({
		ui: {
			addAutocompleteProvider: (f: (c: AutocompleteProvider) => AutocompleteProvider) =>
				f(p),
		},
	} as unknown as ExtensionContext);
}

// Fake provider that MIRRORS the real abort→null behavior: it resolves null when
// signal.aborted (so supersession/timeout tests exercise the real code path), records
// every call (for force-passthrough / signal assertions), and is configurable.
function makeFakeProvider(opts: {
	result?: AutocompleteSuggestions | null;
	delayMs?: number;
	onSignal?: (sig: AbortSignal) => void;
	throwErr?: Error;
}): AutocompleteProvider & {
	lastCall?: { force?: boolean };
} {
	// Declared first so the methods can write `provider.lastCall` via the closure reference
	// (simpler/safer than Object.defineProperty).
	const provider: AutocompleteProvider & { lastCall?: { force?: boolean } } = {
		lastCall: undefined,
		async getSuggestions(lines, cursorLine, cursorCol, { signal, force }) {
			provider.lastCall = { force };
			opts.onSignal?.(signal);
			if (opts.throwErr) throw opts.throwErr;
			const delay = opts.delayMs ?? 0;
			if (delay > 0) {
				await new Promise<void>((resolve) => {
					const id = setTimeout(resolve, delay);
					signal.addEventListener(
						"abort",
						() => {
							clearTimeout(id);
							resolve();
						},
						{ once: true },
					);
				});
			}
			if (signal.aborted) return null; // mirror CombinedAutocompleteProvider
			return opts.result ?? null;
		},
		applyCompletion(lines, cursorLine, cursorCol) {
			return { lines, cursorLine, cursorCol };
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

// Narrow the ok-branch for assertions (discriminated union).
function unwrap<T>(o: HandlerOutcome<T>): T {
	assert.equal(o.ok, true, "expected ok outcome");
	return (o as { ok: true; result: T }).result;
}

// ============================================================================
// TEST 1 (FIRST — must run before any installProvider, while liveProvider is undefined,
// same shared-state idiom as provider-capture.test.ts): getProvider() throws → error.
// ============================================================================
test("getSuggestions: returns -32603 error when provider not captured", async () => {
	const outcome = await handleGetSuggestions(
		{ lines: ["/mo"], cursorLine: 0, cursorCol: 3, force: false },
		fakeConnCtx,
	);
	assert.equal(outcome.ok, false);
	assert.equal((outcome as { ok: false; error: { code: number } }).error.code, -32603);
	assert.match(
		(outcome as { ok: false; error: { message: string } }).error.message,
		/not captured/,
	);
});

// ============================================================================
// TEST 2 — happy path: returns the provider's suggestions, force passes through, and
// the request's signal is NOT aborted afterward (the 1500ms timer was cleared).
// ============================================================================
test("getSuggestions: happy path returns suggestions, force passes through, signal not aborted", async () => {
	const suggestions: AutocompleteSuggestions = {
		items: [{ value: "/model", label: "/model", description: "Switch model" }],
		prefix: "/mo",
	};
	let capturedSignal: AbortSignal | undefined;
	const provider = makeFakeProvider({
		result: suggestions,
		onSignal: (sig) => {
			capturedSignal = sig;
		},
	});
	installProvider(provider);

	const result = unwrap(
		await handleGetSuggestions(
			{ lines: ["/mo"], cursorLine: 0, cursorCol: 3, force: true },
			fakeConnCtx,
		),
	);
	assert.deepEqual(result, suggestions);
	assert.equal(provider.lastCall?.force, true, "force must pass through as boolean");
	assert.equal(
		capturedSignal?.aborted,
		false,
		"signal must NOT be aborted after a successful fast return (timer cleared)",
	);
});

// ============================================================================
// TEST 3 — provider returns null → outcome {ok:true, result:null}.
// ============================================================================
test("getSuggestions: provider returning null yields a null result", async () => {
	installProvider(makeFakeProvider({ result: null }));
	const result = unwrap(
		await handleGetSuggestions(
			{ lines: ["x"], cursorLine: 0, cursorCol: 1, force: false },
			fakeConnCtx,
		),
	);
	assert.equal(result, null);
});

// ============================================================================
// TEST 4 — supersession: starting request B aborts request A's signal (synchronously,
// in B's handler prefix before B awaits); A resolves null, B resolves its result.
// ============================================================================
test("getSuggestions: a newer request supersedes the in-flight one (aborts its signal)", async () => {
	const signals: AbortSignal[] = [];
	installProvider(
		makeFakeProvider({
			delayMs: 30,
			result: { items: [{ value: "Z", label: "Z" }], prefix: "z" },
			onSignal: (sig) => signals.push(sig),
		}),
	);

	const pA = handleGetSuggestions(
		{ lines: ["a"], cursorLine: 0, cursorCol: 1, force: false },
		fakeConnCtx,
	);
	const pB = handleGetSuggestions(
		{ lines: ["b"], cursorLine: 0, cursorCol: 1, force: false },
		fakeConnCtx,
	);

	// Synchronous assertion: B's pendingAbort?.abort() already ran in B's prefix.
	assert.equal(signals.length, 2, "both requests captured their signals");
	assert.equal(signals[0]?.aborted, true, "request A's signal was aborted by B");
	assert.equal(signals[1]?.aborted, false, "request B's signal is the live one");

	const [oA, oB] = await Promise.all([pA, pB]);
	assert.equal(unwrap(oA), null, "superseded A resolves to null");
	assert.deepEqual(unwrap(oB), { items: [{ value: "Z", label: "Z" }], prefix: "z" });
});

// ============================================================================
// TEST 5 — 1500ms timeout: lower the seam to 10ms; a 100ms provider is aborted → null.
// ============================================================================
test("getSuggestions: runaway-fd timeout aborts the request → null", async () => {
	const original = __handlerDeps.timeoutMs;
	__handlerDeps.timeoutMs = 10;
	try {
		installProvider(
			makeFakeProvider({
				delayMs: 100,
				result: { items: [{ value: "X", label: "X" }], prefix: "x" },
			}),
		);
		const result = unwrap(
			await handleGetSuggestions(
				{ lines: ["x"], cursorLine: 0, cursorCol: 1, force: false },
				fakeConnCtx,
			),
		);
		assert.equal(result, null, "a request whose provider outlasts the timeout resolves null");
	} finally {
		__handlerDeps.timeoutMs = original;
	}
});

// ============================================================================
// TEST 6 — provider throws a genuine (non-abort) error → outcome {ok:false, error:-32603}.
// ============================================================================
test("getSuggestions: a genuine provider throw yields a -32603 error", async () => {
	installProvider(makeFakeProvider({ throwErr: new Error("boom") }));
	const outcome = await handleGetSuggestions(
		{ lines: ["a"], cursorLine: 0, cursorCol: 1, force: false },
		fakeConnCtx,
	);
	assert.equal(outcome.ok, false);
	assert.equal((outcome as { ok: false; error: { code: number } }).error.code, -32603);
	assert.match(
		(outcome as { ok: false; error: { message: string } }).error.message,
		/boom/,
	);
});
```

### Integration Points

```yaml
NO external integration points for S11 (handler is invoked only by tests; nothing is wired yet).
  - No socket/dispatcher wiring (S8), no handshake gating (S9/S10), no env write (S16),
    no DB/config.
INTERNAL seams (the exports later tasks consume — NOT wired in S11):
  - handleGetSuggestions(params, connCtx) → S8 dispatcher calls it, envelopes the HandlerOutcome
      into a JsonRpcResponse, writes it to connCtx.socket.
  - ConnectionContext   → S8 creates it (per connection); S9 sets handshakeDone; S17 broadcasts
      commandsChanged over .socket.
  - HandlerOutcome<T>   → S12/S13/S14 reuse it for applyCompletion/shouldTriggerFileCompletion/
      ping/bye/getCommands.
  - toRpcError(err,code)→ module-private now; S15 may generalize/promote it across handlers.
  - __handlerDeps       → S11 tests only (production reads 1500, byte-identical to a literal).
  - pendingAbort        → module-level; S8/S9 do not touch it (the handler owns supersession).
NO tsconfig change:
  - The new test matches the existing `tests/**/*.ts` glob (already in include).
  - setTimeout/AbortController/clearTimeout are globals via lib.dom (no lib field → DOM default);
    verified type-check under types:[] (research §2).
  - protocol.ts import is type-only (protocol.ts already in include); Socket comes from S5's node:net import.
DISPATCHER CONTRACT (documented for S8 — NOT implemented by S11):
  - S8 does, per request: `const outcome = await handleGetSuggestions(params, connCtx);`
      `const resp = outcome.ok ? {jsonrpc:"2.0", id, result: outcome.result}`
      `                       : {jsonrpc:"2.0", id, error: outcome.error};`
      `connCtx.socket.write(JSON.stringify(resp) + "\n");`
```

## Validation Loop

### Level 1: Syntax & Style (Immediate Feedback) — THE TYPE GATE

```bash
# Type-check pi-editor-bridge.ts (now with the protocol.ts type import + handler section) +
# protocol.ts + all tests via the paths-mapped dev tsconfig. This is the authoritative gate
# for S11: the type-only protocol import must resolve, HandlerOutcome/ConnectionContext must
# be properly typed, the async fn return must narrow to HandlerOutcome<GetSuggestionsResult>,
# and the test's fake-provider casts must compile. Failures are usually: a value import of
# protocol.ts (should be `import type`), a missing Socket in scope, or a wrong outcome shape.
tsc --noEmit -p extension/tsconfig.json
# Expected: exit 0, NO output.

# Indentation sanity (S1–S5 + pi examples use TABS):
grep -nP '^    ' extension/pi-editor-bridge.ts extension/tests/handler-getsuggestions.test.ts \
  && echo "WARN: space-indent lines found" || echo "indent OK (tabs)"

# Confirm the handler never throws on the captured-provider paths (PRD §6.7) — every return is a
# HandlerOutcome literal, and getProvider()/provider.getSuggestions() are inside try/catch:
grep -nE 'return \{ ok: (true|false)' extension/pi-editor-bridge.ts   # expect ≥4 outcomes

# Confirm pendingAbort is NOT cleared in finally (a newer request may own it):
grep -nE 'pendingAbort = undefined|pendingAbort = null' extension/pi-editor-bridge.ts \
  && echo "FAIL: pendingAbort cleared (would drop a newer request's controller)" \
  || echo "PASS: pendingAbort never cleared in finally"

# Confirm clearTimeout is in finally (no late-abort / no dangling timer):
grep -nE 'finally \{' extension/pi-editor-bridge.ts   # visually confirm clearTimeout(t) inside

# Confirm the protocol import is TYPE-ONLY (no runtime coupling):
grep -nE '^import [^t].*from "\./protocol' extension/pi-editor-bridge.ts \
  && echo "FAIL: found a VALUE import of protocol.ts (must be import type)" \
  || echo "PASS: protocol.ts imported type-only"
```

### Level 2: Unit Tests (Component Validation) — THE CONTRACT GATE

```bash
# Zero-dependency TS test runner: Node's built-in node:test, with jiti as the TS
# loader (jiti nested under pi-coding-agent; borrow its register hook — SAME path
# S2/S3/S4/S5 use).
JITI_REG=/home/dustin/.local/lib/node_modules/@earendil-works/pi-coding-agent/node_modules/jiti/lib/jiti-register.mjs
node --import "$JITI_REG" extension/tests/handler-getsuggestions.test.ts
# Expected: exit 0; final summary shows `pass 6` and `fail 0`.
# NOTE: jiti on Node 26 prints a harmless DEP0205 DeprecationWarning
#   ("module.register() is deprecated") to STDERR — IGNORE it; judge by exit code
#   and the `pass`/`fail` lines, not stderr cleanliness.

# Re-run S2 + S3 + S4 + S5 suites to prove S11 didn't regress them (S11 only ADDS code to
# pi-editor-bridge.ts and adds one test file; these should be unaffected):
node --import "$JITI_REG" extension/tests/provider-capture.test.ts    # S2 — expect fail 0
node --import "$JITI_REG" extension/tests/mode-guard.test.ts          # S3 — expect fail 0
node --import "$JITI_REG" extension/tests/protocol.test.ts            # S4 — expect fail 0
node --import "$JITI_REG" extension/tests/bridge-lifecycle.test.ts    # S5 — expect fail 0
```

### Level 3: Integration Testing (System Validation) — THE REGRESSION GATE

```bash
# The handler is NOT wired into any dispatcher in S11 (no onConnection/dispatcher/handshake yet),
# so loading the extension entry point does NOT call handleGetSuggestions. This run proves S11
# did not REGRESS the entry point: the file still loads via jiti, the S3 TUI guard still
# suppresses the startup log in --print mode, and pi exits 0.
pi --no-extensions -e ./extension/pi-editor-bridge.ts --print "ok" 2>&1 | tee /tmp/pi-editor-bridge-s11.log

# PASS condition 1: pi exited 0.
pi --no-extensions -e ./extension/pi-editor-bridge.ts --print "ok" >/dev/null 2>&1; echo "pi exit=$?"

# PASS condition 2: NO errors during load/handler invocation.
grep -iE "error|cannot|fail|throw|unhandled|is not a function|TypeError" /tmp/pi-editor-bridge-s11.log \
  && echo "FAIL: error present" || echo "PASS: no errors"

# PASS condition 3: the startup log is still ABSENT in print mode (S3 guard intact; S11 must
# not have touched the default-export factory / session_start handler).
grep -c "pi-editor-bridge: session_start (reason=startup" /tmp/pi-editor-bridge-s11.log | grep -q '^0$' \
  && echo "PASS: startup log suppressed in print mode (S3 guard intact)" \
  || echo "FAIL: startup log appeared — S11 may have touched the session_start handler"
# Expected: all three PASS; pi prints "ok" output and exits 0.
```

### Level 4: Creative & Domain-Specific Validation

```bash
# Confirm the supersession slot actually holds the LATEST controller after a sequence of calls,
# and that stale controllers are aborted. Borrow the real handler via a throwaway probe:
JITI_REG=/home/dustin/.local/lib/node_modules/@earendil-works/pi-coding-agent/node_modules/jiti/lib/jiti-register.mjs
node --import "$JITI_REG" -e '
import("./extension/pi-editor-bridge.ts").then(async ({ captureProvider, handleGetSuggestions }) => {
  const seen = [];
  captureProvider({ ui: { addAutocompleteProvider: (f) => f({
    async getSuggestions(_l,_cl,_cc,{ signal }) { seen.push(signal.aborted); await new Promise(r => { const id=setTimeout(r,5); signal.addEventListener("abort",()=>{clearTimeout(id);r()},{once:true}); }); return null; },
    applyCompletion(l,cl,c){return{l,cl,c};}, shouldTriggerFileCompletion(){return true;}
  }) } });
  const p1 = handleGetSuggestions({lines:["a"],cursorLine:0,cursorCol:1}, {socket:null,handshakeDone:true});
  const p2 = handleGetSuggestions({lines:["b"],cursorLine:0,cursorCol:1}, {socket:null,handshakeDone:true});
  const p3 = handleGetSuggestions({lines:["c"],cursorLine:0,cursorCol:1}, {socket:null,handshakeDone:true});
  await Promise.all([p1,p2,p3]);
  // seen[0] captured at p1 start (false), then observed aborted later; seen[1] at p2 start (false) then aborted; seen[2] at p3 start (false).
  console.log("captured-at-start abort flags:", seen.join(","), "— first two should become true after supersession");
  console.log("PASS: 3 chained requests did not throw; supersession ran without unhandled rejection");
});
'
# Expected: "PASS: 3 chained requests did not throw; supersession ran without unhandled rejection".

# Confirm the handler is importable standalone via jiti with NO node_modules at the repo top
# level (the critical runtime invariant — builtins/globals only, zero npm deps per PRD §6.7):
node --import "$JITI_REG" -e 'import("./extension/pi-editor-bridge.ts").then(m => {
  const want = ["handleGetSuggestions","__handlerDeps","captureProvider","getProvider"];
  console.log("exports include:", want.filter(k => k in m || typeof m[k]==="function"||k==="__handlerDeps"&&m[k]).join(", "));
});'
# Expected: all 4 names present (handleGetSuggestions/__handlerDeps/captureProvider/getProvider).
```

## Final Validation Checklist

### Technical Validation

- [ ] Level 1 (TYPE GATE): `tsc --noEmit -p extension/tsconfig.json` → exit 0, no output.
- [ ] Level 2 (CONTRACT GATE): `node --import <jiti-register>
      extension/tests/handler-getsuggestions.test.ts` → exit 0, `fail 0` (`pass 6`);
      S2 + S3 + S4 + S5 suites still green.
- [ ] Level 3 (REGRESSION GATE): `pi --no-extensions -e ./extension/pi-editor-bridge.ts --print "ok"`
      exits 0 with NO error lines AND the startup-log line ABSENT in print mode (S3 intact).
- [ ] Level 4: 3-chained-request supersession probe runs with no unhandled rejection; all 4
      expected exports present on standalone import.

### Feature Validation

- [ ] `handleGetSuggestions(params, connCtx)` exists; returns `HandlerOutcome<GetSuggestionsResult>`.
- [ ] Calls `getProvider()` FIRST in its own try/catch; "not captured" → `{ok:false, error:-32603}`.
- [ ] Happy path: `pendingAbort?.abort()` → new AC → `pendingAbort=ac` → `setTimeout(1500)` →
      `await provider.getSuggestions(lines,cursorLine,cursorCol,{signal,force:!!force})` →
      `{ok:true, result}`; `force` passes through as boolean.
- [ ] Supersession: a newer request aborts the in-flight signal (`signals[0].aborted===true`);
      the superseded request resolves `null`; the latest request resolves its result.
- [ ] Timeout: a provider outlasting `__handlerDeps.timeoutMs` is aborted → resolves `null`.
- [ ] Provider throws (non-abort) → `{ok:false, error:{code:-32603, message:/boom/}}`.
- [ ] `finally` clears the timer; does NOT clear `pendingAbort`.
- [ ] Handler NEVER throws on any input (PRD §6.7).

### Code Quality Validation

- [ ] Follows existing codebase patterns (fake-provider injection via captureProvider like
      provider-capture.test.ts; node:test+jiti conventions; TAB indentation; `import type`
      discipline; Mode-A JSDoc with STATUS markers; plain-object test seam like S5's __deps).
- [ ] File placement matches the desired codebase tree (additions inside
      `pi-editor-bridge.ts`; new test under `extension/tests/`).
- [ ] Anti-patterns avoided (no value import of protocol.ts; no clearing of pendingAbort in
      finally; no AbortError-catching-as-error; no `export let`; no dispatcher/handshake wiring;
      no protocol.ts edit; no default-export-factory touch).
- [ ] Dependencies: Node globals only (`AbortController`/`setTimeout`/`clearTimeout`) + a
      type-only `protocol.ts` import; zero npm runtime deps (PRD §6.7); no tsconfig change.

### Documentation & Deployment

- [ ] Every new export has Mode-A JSDoc explaining its role + STATUS marker + forward refs
      (S8 dispatcher, S9/S10 handshake, S12–S14 sibling handlers, S15 global try/catch).
- [ ] The handler JSDoc explains supersession, the 1500 ms fd-timeout, the abort→null provider
      behavior, and the do-not-clear-pendingAbort rule (per item "DOCS" requirement).
- [ ] The dispatcher contract (HandlerOutcome → JsonRpcResponse) is documented for S8.

---

## Anti-Patterns to Avoid

- ❌ Don't detect supersession/timeout by catching an `AbortError` — pi's provider RESOLVES
      `null` on abort (it SIGKILLs fd), it does not throw. Check `ac.signal.aborted` AFTER the
      await and map to `null`; reserve the catch for genuine (non-abort) provider errors.
- ❌ Don't call `getProvider()` AFTER `pendingAbort?.abort()`. A "not captured" failure must
      short-circuit BEFORE touching the supersession slot (no point aborting a valid pending
      request when there's nothing to serve). getProvider FIRST, in its own try/catch.
- ❌ Don't clear `pendingAbort` in `finally`. A newer request may have reassigned it to its own
      controller; clearing unconditionally drops the newer request. `pendingAbort` always points
      at the latest; older controllers are GC'd when their call stack unwinds.
- ❌ Don't `import { setTimeout } from "node:timers"` or import `AbortController` — they are
      globals (type-check under `types:[]` via lib.dom because the tsconfig has no `lib` field,
      verified). A stray value import is unnecessary and muddies the "builtins/globals only" invariant.
- ❌ Don't use a VALUE import of `protocol.ts` — it is type-only; use `import type {...}`. A value
      import adds runtime coupling and is unnecessary.
- ❌ Don't make the handler THROW on any path (PRD §6.7 "Never throws from handlers"). Every path
      returns a `HandlerOutcome`. (S15's global try/catch is a safety NET, not a substitute.)
- ❌ Don't surface a superseded/timeout request as a `-32603` error — abort is not an error; map it
      to `null`. The client drops stale responses by id (PRD §5.5); a timeout null is graceful
      degradation (hung fd → no suggestions).
- ❌ Don't use `export let` for `pendingAbort`-or-seam state (jiti doesn't live-bind `export let`
      cross-module, verified in S5). Module-private `let pendingAbort` + getter-free internal use is
      fine (it's not exported); `__handlerDeps` is a plain-object PROPERTY (jiti-safe).
- ❌ Don't wire the handler into onConnection/dispatcher (S8), add handshake gating (S9/S10), or add
      the global try/catch (S15) — all out of scope. Ship ONE self-contained, independently-testable
      handler + its types + its test.
- ❌ Don't touch `protocol.ts` / tsconfig / the default-export factory / captureProvider / getProvider /
      the S5 server section — S11 is purely additive (one type-only import + one handler section + one test).
- ❌ Don't make the test fake provider ignore the AbortSignal — it MUST mirror the real abort→null
      behavior or the supersession/timeout tests won't exercise the real code path.
- ❌ Don't reorder the test file's TEST 1 ("not captured") below any `installProvider` — module
      singleton state is shared sequentially; the not-captured test must run FIRST (same idiom as
      provider-capture.test.ts). Do NOT enable test concurrency.
