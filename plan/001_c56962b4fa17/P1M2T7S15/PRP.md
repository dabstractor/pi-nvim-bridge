name: "P1.M2.T7.S15 — Wrap all RPC handlers in try/catch that convert domain errors to proper JSON-RPC error responses (a shared toBridgeRpcError converter + explicit per-handler wrapping), closing the M2.T7 'error wrapping' lane"
description: "pi-editor-bridge extension (TS). The bridge ALREADY has a two-layer dispatch: `handleLine` (connection.ts ~L188-310) does parse→`-32700` and handler-call→`instanceof BridgeRpcError ? code : -32603` (the last-resort SAFETY NET). Params validation ALREADY throws `BridgeRpcError(-32602)` in the `narrow*Params` helpers (get-suggestions L540, apply L640, should-trigger L735); `hello` ALREADY throws `BridgeRpcError(-32600,\"bad token\",{fatal:true})`. The GAP (S15's lane): the 4 PROVIDER-DEPENDENT handlers call `deps.getProvider()` (pi-editor-bridge.ts:573/678/770/827) which throws a PLAIN `Error(\"…not captured…\")`, and call provider methods (L581/680/774/829) that may throw — today those plain throws fall to the safety net's `else` → `-32603 \"internal error: <raw msg>\"`. S15 wraps them into `BridgeRpcError(-32603)` with clean context-prefixed messages AT THE HANDLER EDGE so the safety net becomes truly last-resort. (1) ADD a shared converter `toBridgeRpcError(err, context)` to connection.ts (ADDITIVE export near `BridgeRpcError` L55 — pass-through if `err instanceof BridgeRpcError`, else `new BridgeRpcError(-32603, \\`${context}: ${detail}\\`)` where `detail = err instanceof Error ? err.message : String(err)`). Backward compatible: pure new export, ZERO change to BridgeRpcError/sendError/sendResponse/handleLine/ConnectionState/registerBridgeHandler — all 16 connection.test.ts tests + all handler tests stay green at the CODE level. (2) WRAP the 4 provider-dependent handlers in pi-editor-bridge.ts with TWO try/catch blocks each: one around `deps.getProvider()` (context=\"completion provider unavailable\") and one around the provider method call (context=\"<methodName> failed\"); the `narrow*Params` call STAYS OUTSIDE/BEFORE the provider try/catch so `-32602` flows untouched. getSuggestions keeps its `finally{clearTimeout(timer)}`. hello/ping/bye are INHERENTLY SAFE (their only throw is the intentional BridgeRpcError; getPid/getCwd/getFdAvailable/getToken are pure non-throwing getters; bye sets a flag) — documented as such, NOT wrapped (the safety net still covers them). (3) CODE CHOICE: `-32603` for ALL domain failures (provider-unavailable + provider-throw), NOT `-32000..-32099`. Justified by research (`research/jsonrpc-error-best-practices.md` §2): the Neovim client treats ALL completion errors as silent-degrade (PRD §11) — it never BRANCHES on the code, so a single interoperable `-32603` with a descriptive message beats inventing `-320xx` taxonomy no client acts on. `-320xx` is documented as a future refinement (PRD §15). CONSEQUENCE: all 5 existing `-32603` code assertions stay green (the DISPATCH getCommands provider-not-captured test still sees -32603, now via the handler's BridgeRpcError instead of the safety net's else-branch). (4) pi's OWN RPC engine does NOT inform the structure: rpc-mode.ts `handleInputLine` (L758-793) is ONE generic catch-all that flattens every throw to `error:<msg>` — NO codes, NO typed-error class, NOT JSON-RPC 2.0 (`research/pi-rpc-error-pattern.md`). The bridge ALREADY diverges to real JSON-RPC 2.0 + BridgeRpcError, so S15 builds on the bridge's machinery, NOT pi's. (5) Tests: FLIP 4 existing UNIT provider-not-captured tests (get-suggestions-handler.test.ts:376, apply-completion-handler.test.ts:325, should-trigger-file-completion-handler.test.ts:319, ping-bye-getcommands-handler.test.ts:351) from \"rethrows PLAIN Error (NOT BridgeRpcError)\" → \"throws BridgeRpcError(-32603), code===-32603, message starts with context\"; UPDATE the DISPATCH getCommands test (ping-bye:608) comment/message-tighten (code stays -32603); ADD new `error-wrapping.test.ts` (toBridgeRpcError unit tests + provider-method-THROWS→BridgeRpcError(-32603) for ALL 4 handlers [NEW coverage] + DISPATCH-level wrapped -32603 + SECURITY token-never-leaks sweep). provider-capture.test.ts:29 UNCHANGED (getProvider() STILL throws plain Error — the HANDLER wraps it). connection.test.ts safety-net tests UNCHANGED (generic throws, orthogonal). node:test + jiti (NOT vitest), three layers (UNIT/DISPATCH/REAL)."
---

## Goal

**Feature Goal**: Complete the M2.T7 "error wrapping" lane by making every RPC handler that
*can* fail with a domain error catch it **at the handler edge** and convert it into a proper
JSON-RPC error response (`BridgeRpcError(-32603, <clean message>)`), so that
`handleLine`'s existing `-32603` catch-all becomes a genuine **last-resort** safety net
(only for unexpected programming bugs) rather than the path that real domain failures take.

Concretely: the 4 **provider-dependent** handlers — `getSuggestions`, `applyCompletion`,
`shouldTriggerFileCompletion`, `getCommands` — today let `deps.getProvider()` (throws a plain
`Error` when the provider isn't captured) and the live `AutocompleteProvider` method calls
(throw on runtime failure) propagate as **plain** `Error`s into the safety net. After S15
each wraps those calls in `try/catch` and re-throws a `BridgeRpcError` carrying `-32603`
plus a context-prefixed, debuggable message (e.g. `"completion provider unavailable: …"`,
`"getSuggestions failed: …"`). A single shared converter `toBridgeRpcError(err, context)`
keeps this DRY and consistent. Handlers that cannot fail with domain errors (`hello`,
`ping`, `bye` — their only throw is an intentional `BridgeRpcError`, and their injected
getters are pure non-throwing functions) are documented as inherently safe and are NOT
modified; the safety net still covers any impossible-in-practice throw from them.

**Deliverable**:
1. `extension/connection.ts` — ADD an exported `toBridgeRpcError(err: unknown, context: string): BridgeRpcError`
   converter immediately after the `BridgeRpcError` class definition (~L55). Pure new
   export; **no change** to `BridgeRpcError`, `sendError`, `sendResponse`, `sendNotification`,
   `registerBridgeHandler`, `ConnectionState`, `MethodHandler`, `handleLine`, or
   `onConnection`. (Additive + backward compatible — same posture as S14's
   `closeAfterResponse` field.)
2. `extension/pi-editor-bridge.ts` — in each of the 4 provider-dependent handler factories
   (`makeGetSuggestionsHandler` L562, `makeApplyCompletionHandler` L670,
   `makeShouldTriggerFileCompletionHandler` L762, `makeGetCommandsHandler` L820), wrap the
   `deps.getProvider()` call and the provider method call in two `try/catch` blocks that
   `throw toBridgeRpcError(e, "<context>")`. Keep `narrow*Params` BEFORE the provider block
   so `-32602` flows untouched. `getSuggestions` retains its `finally { clearTimeout(timer) }`.
   Import `toBridgeRpcError` from `./connection.ts`. `hello`/`ping`/`bye` unchanged (documented
   safe). Update the file-top STATUS block + the per-handler `// throws plain Error … →
   -32603 (S15 refines)` comments (4 occurrences: L573/678/770/827) to mark S15 DONE.
3. `extension/tests/error-wrapping.test.ts` (NEW) — UNIT: `toBridgeRpcError` (pass-through of
   `BridgeRpcError`, wraps plain `Error` → `-32603` + context prefix, wraps non-Error value);
   for EACH of the 4 provider handlers: provider-method-THROWS → `BridgeRpcError(-32603,
   "<context>: <msg>")` (NEW coverage); DISPATCH: provider-not-captured over `handleLine` →
   exactly one `-32603` response whose `message` starts with the context; SECURITY: the token
   value never appears in any wrapped error message/stderr (PRD §12).
4. UPDATE 4 existing UNIT tests in place (flip plain-Error → `BridgeRpcError(-32603)`):
   `get-suggestions-handler.test.ts:376`, `apply-completion-handler.test.ts:325`,
   `should-trigger-file-completion-handler.test.ts:319`, `ping-bye-getcommands-handler.test.ts:351`.
5. UPDATE 1 existing DISPATCH test in place (`ping-bye-getcommands-handler.test.ts:608`):
   comment + (optionally) tighten the message-prefix assertion; the `-32603` code assertion
   is unchanged.

**Success Definition**: With the bridge running and a client authenticated via `hello`:
- A `getSuggestions`/`applyCompletion`/`shouldTriggerFileCompletion`/`getCommands` call whose
  provider is **not captured** returns
  `{jsonrpc,id,error:{code:-32603,message:"completion provider unavailable: …"}}` — a
  `BridgeRpcError` thrown BY THE HANDLER (not the safety net's `else` branch).
- A call whose provider METHOD throws returns
  `{jsonrpc,id,error:{code:-32603,message:"<methodName> failed: <provider msg>"}}`.
- Malformed params STILL return `-32602 "invalid params: …"` (unchanged — `narrow*Params`
  runs before the provider block). `hello` bad-token STILL returns `-32600` + closes
  (unchanged). Pre-handshake STILL returns `-32600 "handshake required"` (unchanged — the
  S10 gate fires before the handler).
- The safety net's generic-throw tests (`connection.test.ts:133/195`) STILL pass
  unchanged — they use a handler that throws a raw `Error`, exercising the genuine
  last-resort path.
- The token value never appears in any error response (PRD §12) — asserted by the new
  SECURITY sweep.
- `tsc --noEmit -p extension/tsconfig.json` is clean; the new suite passes; **ALL 13 existing
  extension suites stay green** (S2–S14); the 16-test `connection.test.ts` stays green.

---

## User Persona

**Target User**: The `pi-editor.nvim` Neovim plugin (P2.M5 / P2.M7) — the bridge's only
client. (Indirectly: the human editing a pi prompt in their `$EDITOR`, plus a future
`:checkhealth pi-editor` user reading diagnostics.)

**Use Case**: When the bridge is running but the autocomplete provider has not yet been
captured (e.g. a `session_start` race, a non-TUI mode slip, or a `/reload` mid-flight), OR
when pi's live provider itself throws (e.g. `fd` binary misbehaves, an internal pi error),
the Neovim client must receive a **well-formed JSON-RPC error response** (not a hung socket,
not a crash, not a malformed envelope) so it can degrade silently to a normal buffer (PRD §11)
and so `:checkhealth pi-editor` (P3.M10.T27.S42) can surface a clean, debuggable message.

**User Journey**: user opens Neovim as `$EDITOR` → plugin activates on `PI_EDITOR_BRIDGE` →
`hello` (token) → `getSuggestions` while provider still warming up → server returns
`-32603 "completion provider unavailable: …"` → plugin logs once + degrades silently → user
keeps typing in a normal buffer. No crash, no hang, no leaked secret.

**Pain Points Addressed**: (a) today a provider-not-captured or provider-throw produces a
`-32603` via the generic safety net with a raw internal message — functional but unstructured;
S15 makes the handler the explicit, documented owner of its error contract. (b) Defense in
depth: even a future handler bug that lets a raw throw escape still hits the safety net.

---

## Why

- **PRD §6.7 ("never throws from handlers")** — handlers must never crash pi. The safety net
  already guarantees a response on the dispatch path; S15 makes the *handlers themselves*
  robust and self-documenting about their failure modes, so the safety net is a true
  last-resort rather than the primary error path.
- **Completes M2.T7** — T7 = "Cancellation, timeout & error wrapping". Cancellation + timeout
  shipped in S11 (`pendingAbort` supersession + `GET_SUGGESTIONS_TIMEOUT_MS`). S15 is the
  final subtask; once it lands, M2 (JSONL Socket Server & RPC Engine) is feature-complete
  pending only the env-advertisement (S16/S17) and packaging (S18) siblings in M3.
- **Enables clean diagnostics** — `:checkhealth pi-editor` (P3.M10.T27.S42) and the Neovim
  client's `vim.notify` (P3.M10.T24.S39) get structured, prefixed messages
  (`"completion provider unavailable: …"`) instead of raw internal strings, improving
  debuggability without leaking secrets.
- **No behavior change for the happy path or for already-proper errors** — `-32602` (params),
  `-32600` (bad token / handshake), `-32601` (method not found), and the success path are
  untouched. Only the previously-unstructured `-32603` domain failures become structured.

---

## What

**User-visible behavior**: Identical for every success case. For failure cases the client
receives the SAME codes it does today (`-32603` for provider/domain failures), but the
`message` is now a clean, context-prefixed string and the error is produced by the handler
(via `BridgeRpcError`) rather than the safety net's `else` branch.

### Success Criteria

- [ ] `toBridgeRpcError(new Error("x"), "ctx")` returns `BridgeRpcError` with `code === -32603`
      and `message === "ctx: x"`; `toBridgeRpcError(new BridgeRpcError(-32601,"y"), "ctx")`
      returns the SAME `BridgeRpcError` unchanged (pass-through, code/message intact).
- [ ] Each of the 4 provider handlers, when `deps.getProvider()` throws, throws
      `BridgeRpcError(-32603)` whose message starts with `"completion provider unavailable:"`.
- [ ] Each of the 4 provider handlers, when the provider METHOD throws, throws
      `BridgeRpcError(-32603)` whose message starts with the method context
      (`"getSuggestions failed:"` / `"applyCompletion failed:"` /
      `"shouldTriggerFileCompletion failed:"` / `"getSuggestions failed:"` for getCommands).
- [ ] Malformed params STILL throw `BridgeRpcError(-32602, "invalid params: …")` and the
      provider is NOT called (params validation precedes the provider block).
- [ ] `hello`/`ping`/`bye` are unchanged (no new wrapping; documented inherently safe).
- [ ] `connection.ts` exports `toBridgeRpcError`; `handleLine`/`BridgeRpcError`/`sendError`/
      `ConnectionState`/`registerBridgeHandler` are byte-identical to S14.
- [ ] `getProvider()` (pi-editor-bridge.ts) STILL throws a plain `Error` (the HANDLER wraps
      it) — `provider-capture.test.ts:29` stays green unchanged.
- [ ] Token value never appears in any wrapped error message (SECURITY sweep).
- [ ] `tsc --noEmit -p extension/tsconfig.json` ⇒ exit 0; all 14 extension test files ⇒
      `ℹ fail 0` (13 existing + 1 new).

---

## All Needed Context

### Context Completeness Check

_Before writing this PRP, validated: "If someone knew nothing about this codebase, would they
have everything needed to implement this successfully?"_ — **YES**. This PRP cites exact file
paths, exact line numbers for every edit site, the exact converter shape, the exact
message-context strings per handler, the exact tests to flip/update/add, the exact validation
commands, and the rationale for the `-32603`-vs-`-320xx` code choice. The two research briefs
(`research/pi-rpc-error-pattern.md`, `research/jsonrpc-error-best-practices.md`) are
cross-referenced for the design justification.

### Documentation & References

```yaml
# MUST READ — the two-layer dispatch model S15 builds on (handleLine's safety net STAYS)
- file: extension/connection.ts
  why: "The handler-call try/catch in handleLine (~L188-310) is the -32603 LAST-RESORT
        safety net. It ALREADY does `instanceof BridgeRpcError ? code : -32603`. S15 ADDS
        toBridgeRpcError (near BridgeRpcError L55) and does NOT touch handleLine. Read the
        BridgeRpcError class (L55-66), sendError (L126), the request-branch catch (~L298-318)
        to understand how a thrown BridgeRpcError becomes a wire error response."
  pattern: "two-layer: handler maps domain errors to BridgeRpcError(code,msg); handleLine's
            catch routes BridgeRpcError→its code, else→-32603."
  gotcha: "S8/S10 OWN connection.ts and it is COMPLETE. S15's edit is PURELY ADDITIVE (one new
           exported function). Do NOT modify handleLine, BridgeRpcError, ConnectionState,
           sendError, or the existing catch logic — S14 already showed the additive-export
           posture is safe (closeAfterResponse field). Re-running the 16 connection.test.ts
           tests after the edit is the regression gate."

# MUST READ — the 4 handler factories S15 wraps (exact provider-call line numbers)
- file: extension/pi-editor-bridge.ts
  why: "makeGetSuggestionsHandler (L562, provider call L573+L581),
        makeApplyCompletionHandler (L670, L678+L680),
        makeShouldTriggerFileCompletionHandler (L762, L770+L774),
        makeGetCommandsHandler (L820, L827+L829). Each has the `// throws plain Error … →
        -32603 (S15 refines)` comment at the getProvider() call. S15 replaces each with a
        try/catch. hello(L401)/ping(L448)/bye(L486) are NOT modified."
  pattern: "deps-injected factory → returns MethodHandler. narrow*Params() is called FIRST
            (throws BridgeRpcError(-32602)); THEN deps.getProvider(); THEN provider.method().
            S15 wraps the latter two in try/catch, keeping narrow* OUTSIDE."
  gotcha: "getSuggestions has a `finally { clearTimeout(timer) }` — the provider-method
           try/catch MUST keep that finally (wrap the `await provider.getSuggestions(...)` in
           try/catch that lives INSIDE the existing try/finally, or restructure so clearTimeout
           still always runs). shouldTriggerFileCompletion uses `?.()` optional chaining + `??
           true` — wrap the whole expression. getCommands uses `await provider.getSuggestions(
           [\"/\"],0,1,...)` — wrap the await."

# MUST READ — how pi's OWN RPC engine does it (and why NOT to copy it)
- docfile: plan/001_c56962b4fa17/P1M2T7S15/research/pi-rpc-error-pattern.md
  why: "pi's rpc-mode.ts handleInputLine (L758-793) is ONE generic catch-all that flattens
        every throw to error:<msg> — NO JSON-RPC codes, NO typed-error class, NOT JSON-RPC 2.0.
        The bridge ALREADY diverges to real JSON-RPC 2.0 + BridgeRpcError. S15 builds on the
        bridge's machinery, NOT pi's. Confirms the per-handler-wrapping recommendation (§7-8)."
  section: "§7 (reusable/mirrorable), §8 (recommendation)"

# MUST READ — JSON-RPC 2.0 code choice justification (-32603 vs -320xx)
- docfile: plan/001_c56962b4fa17/P1M2T7S15/research/jsonrpc-error-best-practices.md
  why: "§1 = authoritative code table (-32700/-32600/-32601/-32602/-32603 + -32000..-32099
        server range). §2 = the -32603-vs-320xx decision: default to -32603 for unexpected
        handler failures; reserve -320xx for distinguished modes clients branch on. §3 =
        async wrapping (single `await` in try/catch suffices — handleLine already awaits).
        §4 = message hygiene (no stacks; sanitize). §5 = defense-in-depth (per-handler wrap
        + top-level net = the bridge's existing model)."
  section: "§2 (-32603 vs -320xx), §3 (async), §4 (sanitization)"

- url: https://www.jsonrpc.org/specification#error_object
  why: "Authoritative JSON-RPC 2.0 error object + reserved code ranges. -32603 = 'Internal
        error'; -32000..-32099 = 'implementation-defined server errors'."
  critical: "A response has exactly one of result/error; error.code MUST be an integer;
             error.message MUST be a string. The bridge's sendError already satisfies this."

# MUST READ — the test conventions (node:test + jiti, NOT vitest; three layers; fakeSocket)
- file: extension/tests/get-suggestions-handler.test.ts
  why: "THE reference test file. Shows fakeSocket()/parseResponses()/readFirstResponse()
        helpers (copied VERBATIM per-file, NOT exported), the makeRecordingProvider stub
        pattern, the UNIT/DISPATCH/REAL three-layer structure, the __resetHandlersForTest()
        in finally discipline, and the EXISTING provider-not-captured UNIT test at L376 that
        S15 FLIPS. Mirror its style for the new error-wrapping.test.ts."
  pattern: "test('UNIT: …', async () => { handler = makeXHandler({getProvider:()=>{throw…}});
            await assert.rejects(()=>handler(params,state), err=>{…; return true}) })"
  gotcha: "node:test runs SEQUENTIALLY; the handler registry is MODULE-LEVEL — EVERY test
           MUST call __resetHandlersForTest() in finally or later tests see stale handlers.
           jiti prints a benign DeprecationWarning on Node 26 stderr — judge by exit code +
           the ℹ pass/ℹ fail summary."

# DESIGN CONSOLIDATION (read this for the full picture)
- docfile: plan/001_c56962b4fa17/P1M2T7S15/research/notes.md
  why: "Consolidates scope, current state, design decision, code choice, per-handler action
        table, test impact, and the message-context strings. The fastest path to full context."
```

### Current Codebase tree (run `tree extension -L 2`)

```bash
extension
├── connection.ts        # handleLine dispatch + BridgeRpcError + (NEW) toBridgeRpcError
├── jsonl-reader.ts      # JSONL framing (S7) — UNCHANGED by S15
├── pi-editor-bridge.ts  # 7 handler factories + lifecycle — 4 wrapped, 3 untouched
├── protocol.ts          # types-only (S4) — UNCHANGED by S15
├── tsconfig.json        # ES2022/strict, types:[] — UNCHANGED by S15
└── tests/
    ├── apply-completion-handler.test.ts          # UPDATE L325 (flip provider-not-captured UNIT)
    ├── bridge-lifecycle.test.ts                  # UNCHANGED
    ├── bridge-lifecycle-wiring.test.ts           # UNCHANGED
    ├── connection.test.ts                        # UNCHANGED (safety-net tests use generic throws)
    ├── error-wrapping.test.ts                    # NEW (toBridgeRpcError + provider-throw wrapping + DISPATCH + SECURITY)
    ├── get-suggestions-handler.test.ts           # UPDATE L376 (flip provider-not-captured UNIT)
    ├── handshake-gate.test.ts                    # UNCHANGED
    ├── hello-handler.test.ts                     # UNCHANGED
    ├── jsonl-reader.test.ts                      # UNCHANGED
    ├── mode-guard.test.ts                        # UNCHANGED
    ├── ping-bye-getcommands-handler.test.ts      # UPDATE L351 (flip) + L608 (comment/tighten)
    ├── protocol.test.ts                          # UNCHANGED
    ├── provider-capture.test.ts                  # UNCHANGED (getProvider() still throws plain Error)
    └── should-trigger-file-completion-handler.test.ts  # UPDATE L319 (flip)
```

### Desired Codebase tree with files to be added/modified

```bash
extension/connection.ts                 # + toBridgeRpcError(err, context) export (additive)
extension/pi-editor-bridge.ts           # wrap 4 handlers; import toBridgeRpcError; STATUS update
extension/tests/error-wrapping.test.ts  # NEW
# (4 test files get surgical in-place updates — see Implementation Tasks)
```

### Known Gotchas of our codebase & Library Quirks

```typescript
// CRITICAL: connection.ts is OWNED by S8/S10 and COMPLETE. S15's connection.ts edit is PURELY
// ADDITIVE (one new exported function, toBridgeRpcError). Do NOT touch handleLine, BridgeRpcError,
// sendError, sendResponse, sendNotification, registerBridgeHandler, ConnectionState, MethodHandler,
// or onConnection. The 16 connection.test.ts tests are the regression gate (they MUST stay green).

// CRITICAL: narrow*Params() (get-suggestions L540, apply L640, should-trigger L735) ALREADY throw
// BridgeRpcError(-32602). S15 MUST keep the narrow* call BEFORE/outside the provider try/catch so
// -32602 flows untouched. Do NOT move it inside toBridgeRpcError's reach (it'd still pass through
// correctly, but keeping it outside is cleaner and matches the existing structure).

// CRITICAL: getSuggestions has `finally { clearTimeout(timer) }` (L583-585). The provider-method
// try/catch MUST preserve that finally — clearTimeout must run on BOTH success AND throw. Put the
// try/catch for provider.getSuggestions INSIDE the existing try/finally, i.e.:
//   try { try { return await provider.getSuggestions(...) } catch(e){ throw toBridgeRpcError(e,"getSuggestions failed") } }
//   finally { clearTimeout(timer) }
// OR restructure as one try/finally whose body has the inner try/catch. Either preserves the timer.

// CRITICAL: shouldTriggerFileCompletion uses provider.shouldTriggerFileCompletion?.(…) ?? true
// (optional chaining — the method is OPTIONAL on the interface, L774). Wrap the WHOLE expression
// in the try/catch so a throw from the optional method is caught; the `?? true` default stays.

// CRITICAL: getProvider() (pi-editor-bridge.ts:336) STILL throws a PLAIN Error after S15. The
// HANDLER wraps it via toBridgeRpcError. provider-capture.test.ts:29 asserts getProvider() itself
// throws /not captured/ — that test stays GREEN unchanged. Do NOT change getProvider().

// CRITICAL: jiti (pi's TS loader) does NOT implement cross-module live-binding reassignment of
// `export let` — but toBridgeRpcError is a plain `export function` (no state), so no issue. The
// existing getters (getToken/getProvider/getCwd/…) idiom is unaffected.

// GOTCHA: the handler registry is MODULE-LEVEL — every test MUST __resetHandlersForTest() in finally.
// GOTCHA: node:test runs sequentially; jiti prints a benign DeprecationWarning on Node 26 — judge by exit code.
// GOTCHA: never include the token/descriptor in any error message (PRD §12). Provider/getProvider
//         messages never touch the token, but assert this in the new SECURITY sweep.
```

---

## Implementation Blueprint

### Data models and structure

No new data models. S15 reuses the existing `BridgeRpcError` class (connection.ts:55) and
adds one pure converter function. The JSON-RPC wire types (`JsonRpcError`, `sendError`) are
unchanged. The single new symbol:

```typescript
// connection.ts — ADD (after the BridgeRpcError class, ~L66)
/**
 * Convert any thrown value into a BridgeRpcError for a handler's domain-error path.
 * Pass-through if `err` is already a BridgeRpcError (so params-validation -32602 and
 * hello's -32600 keep their intentional codes); otherwise wrap into -32603 (internal error)
 * with a sanitized, context-prefixed message.
 *
 * STATUS (P1.M2.T7.S15): shared converter the 4 provider-dependent handlers use to wrap
 * their domain errors (provider-not-captured, provider-runtime-throw) into proper JSON-RPC
 * codes BEFORE they reach handleLine's -32603 last-resort safety net. -32603 is the JSON-RPC
 * "internal error" code; the -32000..-32099 server range is reserved for *distinguished*
 * modes clients branch on (research/jsonrpc-error-best-practices §2) — the Neovim client
 * treats ALL completion errors as silent-degrade (PRD §11), so a single -32603 with a
 * descriptive message is the interoperable choice. The message NEVER contains the token
 * (token lives in a separate module-level secret; SECURITY sweep stays green).
 */
export function toBridgeRpcError(err: unknown, context: string): BridgeRpcError {
	if (err instanceof BridgeRpcError) return err;
	const detail = err instanceof Error ? err.message : String(err);
	return new BridgeRpcError(-32603, `${context}: ${detail}`);
}
```

### Implementation Tasks (ordered by dependencies)

```yaml
Task 1: ADD toBridgeRpcError converter to connection.ts (additive, no behavior change)
  - FILE: extension/connection.ts
  - PLACE: immediately AFTER the BridgeRpcError class definition (ends ~L66), BEFORE the
    ConnectionState interface. One new `export function toBridgeRpcError(err: unknown,
    context: string): BridgeRpcError { … }` (see Data models section for exact body).
  - SEMANTICS: pass-through if `err instanceof BridgeRpcError`; else `new BridgeRpcError(
    -32603, \`${context}: ${detail}\`)` where detail = err.message (Error) or String(err).
  - PRESERVE: BridgeRpcError, sendError, sendResponse, sendNotification,
    registerBridgeHandler, __resetHandlersForTest, __hasHandlerForTest, ConnectionState,
    MethodHandler, handleLine, onConnection — ALL byte-identical.
  - VERIFY (after): tsc --noEmit -p extension/tsconfig.json ⇒ exit 0; the 16-test
    connection.test.ts ⇒ ℹ fail 0 (additive export, no behavior change).

Task 2: WRAP makeGetSuggestionsHandler (pi-editor-bridge.ts L562)
  - FILE: extension/pi-editor-bridge.ts
  - ADD import: `toBridgeRpcError` to the existing `import { onConnection,
    registerBridgeHandler, BridgeRpcError, type ConnectionState, type MethodHandler } from
    "./connection.ts";` (top of file, ~L36).
  - EDIT the returned async handler (~L571-586):
      * KEEP `const params = narrowGetSuggestionsParams(_params);` as the FIRST line (before
        any try/catch) so -32602 flows untouched.
      * WRAP `const provider = deps.getProvider();` (L573) in try/catch →
        `throw toBridgeRpcError(e, "completion provider unavailable");`
      * WRAP `return await provider.getSuggestions(...)` (L581) in an INNER try/catch →
        `throw toBridgeRpcError(e, "getSuggestions failed");` — keeping the OUTER
        `finally { clearTimeout(timer); }` intact (clearTimeout runs on success + throw).
  - UPDATE the L573 comment `// throws plain Error if not captured → -32603 (S15 refines)`
    → `// wrapped by S15: toBridgeRpcError(e, "completion provider unavailable") → -32603`.
  - NAMING: context strings EXACTLY "completion provider unavailable" and "getSuggestions
    failed" (these are asserted in tests + the DISPATCH/SECURITY sweeps).

Task 3: WRAP makeApplyCompletionHandler (pi-editor-bridge.ts L670)
  - EDIT the returned sync handler (~L676-686):
      * KEEP `const params = narrowApplyCompletionParams(_params);` FIRST (-32602 untouched).
      * WRAP `const provider = deps.getProvider();` (L678) → toBridgeRpcError(e,
        "completion provider unavailable").
      * WRAP `return provider.applyCompletion(...)` (L680) → toBridgeRpcError(e,
        "applyCompletion failed").
  - CONTEXT STRINGS: "completion provider unavailable", "applyCompletion failed".

Task 4: WRAP makeShouldTriggerFileCompletionHandler (pi-editor-bridge.ts L762)
  - EDIT the returned sync handler (~L768-778):
      * KEEP `const params = narrowShouldTriggerFileCompletionParams(_params);` FIRST.
      * WRAP `const provider = deps.getProvider();` (L770) → "completion provider unavailable".
      * WRAP the ENTIRE `provider.shouldTriggerFileCompletion?.(...) ?? true` expression
        (L774) in try/catch → toBridgeRpcError(e, "shouldTriggerFileCompletion failed").
        (Preserve the `?.()` optional chaining + `?? true` default INSIDE the try.)
  - CONTEXT STRINGS: "completion provider unavailable", "shouldTriggerFileCompletion failed".

Task 5: WRAP makeGetCommandsHandler (pi-editor-bridge.ts L820)
  - EDIT the returned async handler (~L824-842):
      * getCommands has NO narrow* (empty params ignored) — go straight to the provider.
      * WRAP `const provider = deps.getProvider();` (L827) → "completion provider unavailable".
      * WRAP `const result = await provider.getSuggestions(["/"], 0, 1, {...})` (L829) →
        toBridgeRpcError(e, "getSuggestions failed"). (getCommands reuses getSuggestions
        under the hood, so the method context is "getSuggestions failed" — document why.)
      * The downstream `if (!result) return { commands: [] };` + mapping stay AFTER the
        try/catch (they operate on a successful result; a null result is not an error).
  - CONTEXT STRINGS: "completion provider unavailable", "getSuggestions failed".

Task 6: DOCUMENT hello/ping/bye as inherently safe (no code change required)
  - In the file-top STATUS block, add a `STATUS (P1.M2.T7.S15)` note stating: the 4
    provider-dependent handlers now wrap domain errors via toBridgeRpcError(-32603);
    hello/ping/bye are inherently safe (their only throw is the intentional BridgeRpcError;
    getPid/getCwd/getFdAvailable/getToken are pure non-throwing getters; bye sets a flag) and
    are NOT wrapped — the handleLine safety net still covers any impossible-in-practice throw.
  - This is a DOC-ONLY task (no functional change) — it records WHY those 3 handlers are
    exempt so a future reader doesn't "fix" them.

Task 7: CREATE extension/tests/error-wrapping.test.ts (NEW — three layers)
  - IMPLEMENT (UNIT): toBridgeRpcError —
      (a) pass-through: toBridgeRpcError(new BridgeRpcError(-32601,"y"), "ctx") returns the
          SAME instance, code -32601, message "y";
      (b) wraps Error: toBridgeRpcError(new Error("boom"), "ctx") → code -32603, message
          "ctx: boom";
      (c) wraps non-Error: toBridgeRpcError("a string", "ctx") → code -32603, message
          "ctx: a string";
      (d) wraps null/undefined: toBridgeRpcError(null, "ctx") → code -32603, message
          "ctx: null".
  - IMPLEMENT (UNIT, provider-method-THROWS — NEW coverage): for EACH of the 4 handlers,
    inject a provider whose method throws (getSuggestions/applyCompletion/
    shouldTriggerFileCompletion/getCommands) and assert the handler throws
    BridgeRpcError(-32603) with message starting the method context. Use stub providers
    modeled on get-suggestions-handler.test.ts's makeRecordingProvider (e.g.
    `getSuggestions: async () => { throw new Error("fd died"); }`).
      * getSuggestions: provider.getSuggestions throws → "getSuggestions failed: fd died".
      * applyCompletion: provider.applyCompletion throws → "applyCompletion failed: …".
      * shouldTriggerFileCompletion: provider.shouldTriggerFileCompletion throws →
        "shouldTriggerFileCompletion failed: …".
      * getCommands: provider.getSuggestions throws → "getSuggestions failed: …".
  - IMPLEMENT (DISPATCH): register the wrapped getSuggestions (or getCommands) handler +
    fakeSocket + handleLine, handshakeComplete:true, provider NOT captured → assert exactly
    ONE -32603 response whose error.message startsWith "completion provider unavailable:".
  - IMPLEMENT (SECURITY): run the provider-not-captured + provider-throw paths and assert
    the TOKEN string never appears in any write/stderr (PRD §12). (Register hello with a
    fixed TOKEN; send getSuggestions with a throwing getProvider; grep writes for TOKEN.)
  - FOLLOW pattern: get-suggestions-handler.test.ts (fakeSocket/parseResponses/
    readFirstResponse copied VERBATIM; makeRecordingProvider stub; __resetHandlersForTest
    in EVERY finally).
  - NAMING: error-wrapping.test.ts (kebab, matches house style).
  - COVERAGE: toBridgeRpcError all branches + 4 handlers provider-throw + DISPATCH wrapped
    -32603 + SECURITY token-sweep.

Task 8: UPDATE 4 existing UNIT provider-not-captured tests (flip expectation)
  - get-suggestions-handler.test.ts:376 — change from "rethrows the plain Error (NOT a
    BridgeRpcError; -32603 safety net)" to "throws BridgeRpcError(-32603) with message
    starting 'completion provider unavailable:'". assert.rejects → assert err instanceof
    BridgeRpcError, err.code === -32603, err.message startsWith context. Update the
    inline comment "(S15 will later refine…)" → "(S15 wrapped: …)".
  - apply-completion-handler.test.ts:325 — same flip ("completion provider unavailable:").
  - should-trigger-file-completion-handler.test.ts:319 — same flip.
  - ping-bye-getcommands-handler.test.ts:351 (getCommands UNIT) — same flip.
  - NOTE: the stub getProvider in each is `() => { throw new Error("not captured"); }` —
    KEEP that; the assertion changes (now BridgeRpcError(-32603)), the stub stays.

Task 9: UPDATE 1 existing DISPATCH getCommands test (comment + optional tighten)
  - ping-bye-getcommands-handler.test.ts:608 ("provider-not-captured → -32603 (safety net;
    S15 refines)") — the -32603 CODE assertion is UNCHANGED (handler now throws
    BridgeRpcError(-32603) → handleLine routes it to the same code). UPDATE the comment to
    "(S15 wrapped: handler throws BridgeRpcError(-32603), not the safety-net else-branch)"
    and OPTIONALLY add `assert.ok(r.error.message.startsWith("completion provider
    unavailable:"))`. Keep the existing assertions green.

Task 10: VALIDATE (see Validation Loop)
  - tsc --noEmit -p extension/tsconfig.json ⇒ exit 0, no output.
  - Full suite: every extension/tests/*.test.ts ⇒ ℹ fail 0.
  - SECURITY sweep token-count ⇒ 0.
```

### Implementation Patterns & Key Details

```typescript
// PATTERN: the shared converter (connection.ts). Pass-through preserves intentional codes
// (-32602 params, -32600 token); everything else → -32603 internal error (JSON-RPC reserved).
export function toBridgeRpcError(err: unknown, context: string): BridgeRpcError {
	if (err instanceof BridgeRpcError) return err; // intentional codes keep their code/message
	const detail = err instanceof Error ? err.message : String(err);
	return new BridgeRpcError(-32603, `${context}: ${detail}`); // internal error, context-prefixed
}

// PATTERN: provider-dependent handler wrapping (getSuggestions — the async + timer case).
// narrow*Params STAYS FIRST (outside try) so -32602 is untouched. Two try/catch: getProvider,
// then the provider call. The OUTER try/finally keeps clearTimeout(timer) unconditional.
return async (_params: unknown, _state: ConnectionState): Promise<GetSuggestionsResult> => {
	const params = narrowGetSuggestionsParams(_params); // BridgeRpcError(-32602) — flows untouched
	let provider: AutocompleteProvider;
	try {
		provider = deps.getProvider(); // plain Error if not captured
	} catch (e) {
		throw toBridgeRpcError(e, "completion provider unavailable");
	}
	const ac = new AbortController();
	pendingAbort?.abort(); // supersession (S11) — unchanged
	pendingAbort = ac;
	const timer: ReturnType<typeof setTimeout> = setTimeout(() => {
		if (!ac.signal.aborted) ac.abort();
	}, timeoutMs);
	try {
		try {
			return await provider.getSuggestions(
				params.lines, params.cursorLine, params.cursorCol,
				{ signal: ac.signal, force: params.force === true },
			);
		} catch (e) {
			throw toBridgeRpcError(e, "getSuggestions failed");
		}
	} finally {
		clearTimeout(timer); // ALWAYS runs (success + throw)
	}
};

// PATTERN: sync handler wrapping (applyCompletion). Two try/catch, no timer.
return (_params: unknown, _state: ConnectionState): ApplyCompletionResult => {
	const params = narrowApplyCompletionParams(_params); // -32602 untouched
	let provider: AutocompleteProvider;
	try {
		provider = deps.getProvider();
	} catch (e) {
		throw toBridgeRpcError(e, "completion provider unavailable");
	}
	try {
		return provider.applyCompletion(
			params.lines, params.cursorLine, params.cursorCol, params.item, params.prefix,
		);
	} catch (e) {
		throw toBridgeRpcError(e, "applyCompletion failed");
	}
};

// PATTERN: optional-method handler (shouldTriggerFileCompletion). Wrap the WHOLE `?.() ??
// true` expression so a throw from the optional method is caught; the default stays inside.
return (_params: unknown, _state: ConnectionState): ShouldTriggerFileCompletionResult => {
	const params = narrowShouldTriggerFileCompletionParams(_params);
	let provider: AutocompleteProvider;
	try {
		provider = deps.getProvider();
	} catch (e) {
		throw toBridgeRpcError(e, "completion provider unavailable");
	}
	try {
		return (
			provider.shouldTriggerFileCompletion?.(
				params.lines, params.cursorLine, params.cursorCol,
			) ?? true // pi's documented default: absent method ⇒ ALLOW file completion
		);
	} catch (e) {
		throw toBridgeRpcError(e, "shouldTriggerFileCompletion failed");
	}
};

// PATTERN: the flipped UNIT test (4 files). Stub stays; assertion changes.
test("UNIT: provider-not-captured → throws BridgeRpcError(-32603, \"completion provider unavailable: …\")", async () => {
	const handler = makeGetSuggestionsHandler({
		getProvider: () => { throw new Error("not captured"); },
	});
	await assert.rejects(
		() => handler({ lines: ["/m"], cursorLine: 0, cursorCol: 2 }, { handshakeComplete: true }),
		(err: unknown) => {
			assert.ok(err instanceof BridgeRpcError, "S15: must be a BridgeRpcError now");
			assert.equal((err as BridgeRpcError).code, -32603);
			assert.ok(
				(err as BridgeRpcError).message.startsWith("completion provider unavailable:"),
				`got "${(err as BridgeRpcError).message}"`,
			);
			return true;
		},
	);
});

// GOTCHA: handleLine's catch ALREADY does `instanceof BridgeRpcError ? code : -32603`. So a
// handler that throws BridgeRpcError(-32603) produces the SAME wire code (-32603) the safety
// net's else-branch would have — but via the handler's intentional path + clean message. The
// DISPATCH getCommands test (ping-bye:608) therefore keeps its -32603 assertion; only the
// comment/message changes.
```

### Integration Points

```yaml
CONNECTION.TS (S8/S10-owned, COMPLETE):
  - ADD: `export function toBridgeRpcError(err, context)` (~after BridgeRpcError class, L66).
  - NO CHANGE to: handleLine, BridgeRpcError, sendError, sendResponse, sendNotification,
    registerBridgeHandler, ConnectionState, MethodHandler, onConnection.
  - regression gate: `node --import "$JITI_REG" extension/tests/connection.test.ts` ⇒ 16/16.

PI-EDITOR-BRIDGE.TS (S9-S14-owned handlers):
  - IMPORT: add `toBridgeRpcError` to the connection.ts import (L36).
  - WRAP: 4 handlers (getSuggestions/applyCompletion/shouldTriggerFileCompletion/getCommands).
  - NO CHANGE to: hello/ping/bye, getProvider(), narrow*Params(), lifecycle, __deps, getters.
  - regression gate: the 4 handler test files + provider-capture.test.ts ⇒ all green.

PROTOCOL.TS: UNCHANGED (no new wire types; toBridgeRpcError produces existing JsonRpcError
  shape via the existing BridgeRpcError → sendError path).

DOWNSTREAM (no API change for consumers): P3.M10.T24.S39 (silent degrade) + P3.M10.T27.S42
  (:checkhealth) read the SAME -32603 code they would today; they now get a cleaner message.
```

---

## Validation Loop

### Level 1: Syntax & Type (after the source edits)

```bash
cd /home/dustin/projects/pi-nvim-bridge
tsc --noEmit -p extension/tsconfig.json
# Expected: exit 0, NO output.
# (Type reasoning: toBridgeRpcError(err: unknown, context: string): BridgeRpcError — `err
# instanceof BridgeRpcError` narrows; `err instanceof Error` narrows detail; the template
# literal `${context}: ${detail}` is string. The wrapped handlers: `let provider:
# AutocompleteProvider` then assignment in try — TS knows it's assigned before use because
# the catch `throw`s (definite assignment on all non-throwing paths). getSuggestions inner
# try/catch inside try/finally is legal. AbortController/AbortSignal already used by S11.)
```

### Level 2: Unit / component tests (node:test + jiti — NOT vitest)

```bash
JITI_REG=/home/dustin/.local/lib/node_modules/@earendil-works/pi-coding-agent/node_modules/jiti/lib/jiti-register.mjs

# The NEW S15 suite (toBridgeRpcError + 4-handler provider-throw wrapping + DISPATCH + SECURITY)
node --import "$JITI_REG" extension/tests/error-wrapping.test.ts
# Expected: exit 0, `ℹ fail 0`. (jiti prints a benign DeprecationWarning on Node 26 stderr —
# judge by exit code + the ℹ pass/ℹ fail summary, ignore the warning.)

# The 4 FLIPPED UNIT tests (provider-not-captured now BridgeRpcError(-32603))
node --import "$JITI_REG" extension/tests/get-suggestions-handler.test.ts
node --import "$JITI_REG" extension/tests/apply-completion-handler.test.ts
node --import "$JITI_REG" extension/tests/should-trigger-file-completion-handler.test.ts
node --import "$JITI_REG" extension/tests/ping-bye-getcommands-handler.test.ts
# Expected: ℹ fail 0 each (test COUNTS unchanged — only assertions flipped).

# Regression: connection.ts safety net (16 tests) — additive export, no behavior change.
node --import "$JITI_REG" extension/tests/connection.test.ts
# Expected: ℹ tests 16, ℹ pass 16, ℹ fail 0.

# Regression: getProvider() STILL throws plain Error (handler wraps it).
node --import "$JITI_REG" extension/tests/provider-capture.test.ts
# Expected: ℹ fail 0.

# Full extension suite (now 14 files — no S2–S14 regressions)
for t in extension/tests/*.test.ts; do
  echo "--- $(basename "$t")"
  node --import "$JITI_REG" "$t" 2>/dev/null | grep -E "^ℹ (tests|pass|fail)"
done
# Expected: every file ℹ fail 0.
```

### Level 3: Integration (a real socket pair — wrapped -32603 end-to-end)

```bash
# Hand-eyeball the wire: hello → getSuggestions(provider-not-captured) ⇒ wrapped -32603.
JITI_REG=/home/dustin/.local/lib/node_modules/@earendil-works/pi-coding-agent/node_modules/jiti/lib/jiti-register.mjs
node --import "$JITI_REG" -e '
  const { createServer, connect } = require("node:net");
  const { join } = require("node:path"), { tmpdir } = require("node:os"), { randomUUID } = require("node:crypto");
  const { onConnection, registerBridgeHandler } = await import("./extension/connection.ts");
  const { makeHelloHandler, makeGetSuggestionsHandler, getCwd, getFdAvailable, BRIDGE_VERSION } = await import("./extension/pi-editor-bridge.ts");
  const { serializeJsonLine, attachJsonlLineReader } = await import("./extension/jsonl-reader.ts");
  const TOKEN = "deadbeef".repeat(4);
  registerBridgeHandler("hello", makeHelloHandler({ getToken:()=>TOKEN, getCwd, getFdAvailable, version:BRIDGE_VERSION }));
  // provider NOT captured: getProvider throws → handler wraps → -32603 "completion provider unavailable: …"
  registerBridgeHandler("getSuggestions", makeGetSuggestionsHandler({ getProvider: () => { throw new Error("not captured"); } }));
  const sockpath = join(tmpdir(), `s15-${randomUUID()}.sock`);
  const s = createServer(c=>onConnection(c)); s.listen(sockpath);
  s.once("listening", ()=>{
    const cli = connect(sockpath);
    const read = () => new Promise(res=>{ const d=attachJsonlLineReader(cli,l=>{d();res(JSON.parse(l))}); });
    cli.once("connect", async ()=>{
      cli.write(serializeJsonLine({jsonrpc:"2.0",id:"h1",method:"hello",params:{token:TOKEN}}));
      console.log("hello:", JSON.stringify(await read()));
      cli.write(serializeJsonLine({jsonrpc:"2.0",id:"g1",method:"getSuggestions",params:{lines:["/m"],cursorLine:0,cursorCol:2}}));
      console.log("getSuggestions (provider not captured):", JSON.stringify(await read()));
      s.close();
    });
  });
'
# Expected:
#   hello:       {"jsonrpc":"2.0","id":"h1","result":{"ok":true,"serverVersion":"0.1.0","cwd":"…","fdAvailable":…}}
#   getSuggestions (provider not captured): {"jsonrpc":"2.0","id":"g1","error":{"code":-32603,"message":"completion provider unavailable: pi-editor-bridge: autocomplete provider not captured yet (await session_start)"}}
```

### Level 4: Domain-specific validation (correctness invariants)

```bash
# (a) toBridgeRpcError pass-through: a BridgeRpcError(-32601) keeps code -32601 (NOT -32603).
#     Asserted in UNIT (error-wrapping.test.ts).
# (b) params validation STILL wins: malformed params → -32602 (NOT -32603), provider NOT
#     called. Re-asserted by the existing param-validation UNIT tests in each handler file
#     (they stay green — narrow* runs before the provider block).
# (c) provider-method-THROWS → -32603 with the METHOD context (getSuggestions failed /
#     applyCompletion failed / shouldTriggerFileCompletion failed). NEW coverage in
#     error-wrapping.test.ts.
# (d) hello/ping/bye UNCHANGED — re-run their test files (hello-handler.test.ts,
#     ping-bye-getcommands-handler.test.ts) ⇒ green (no wrapping added to them).
# (e) safety net STILL works for a GENERIC throw — connection.test.ts:133/195 (a handler
#     that throws `new Error("kaboom")` with NO wrapping) ⇒ -32603 unchanged.
# (f) SECURITY — token never appears in any wrapped error message/stderr (PRD §12):
JITI_REG=/home/dustin/.local/lib/node_modules/@earendil-works/pi-coding-agent/node_modules/jiti/lib/jiti-register.mjs
node --import "$JITI_REG" extension/tests/error-wrapping.test.ts 2>&1 | grep -c "deadbeefdeadbeefdeadbeefdeadbeef" || true
# Expected: 0 in RESULT/error payloads (the token appears only in the hello REQUEST the test
# sends, never in a -32603 wrapped error response — the dedicated SECURITY test asserts this).
```

---

## Final Validation Checklist

### Technical Validation
- [ ] `tsc --noEmit -p extension/tsconfig.json` ⇒ exit 0, no output.
- [ ] `node --import "$JITI_REG" extension/tests/error-wrapping.test.ts` ⇒ exit 0, `ℹ fail 0`.
- [ ] Full suite: every `extension/tests/*.test.ts` ⇒ `ℹ fail 0` (14 files).
- [ ] `connection.test.ts` ⇒ `ℹ tests 16`, `ℹ pass 16`, `ℹ fail 0` (additive export, no regression).
- [ ] `provider-capture.test.ts` ⇒ `ℹ fail 0` (getProvider() still throws plain Error).

### Feature Validation
- [ ] Provider-not-captured (4 handlers) ⇒ `BridgeRpcError(-32603)` message starts with
      `"completion provider unavailable:"` (UNIT flipped + new error-wrapping DISPATCH).
- [ ] Provider-method-throws (4 handlers) ⇒ `BridgeRpcError(-32603)` message starts with the
      method context (NEW coverage in error-wrapping.test.ts).
- [ ] Malformed params STILL ⇒ `-32602 "invalid params: …"`, provider NOT called (unchanged).
- [ ] hello/ping/bye UNCHANGED (inherently safe; not wrapped).
- [ ] handleLine safety net STILL catches a generic raw throw (connection.test.ts:133/195).
- [ ] Token value never appears in any wrapped error message (SECURITY sweep ⇒ 0).

### Code Quality Validation
- [ ] `toBridgeRpcError` is the ONLY new symbol; connection.ts is otherwise byte-identical.
- [ ] The 4 wrapped handlers keep `narrow*Params` FIRST (before the provider try/catch).
- [ ] getSuggestions preserves `finally { clearTimeout(timer) }` on all paths.
- [ ] shouldTriggerFileCompletion keeps `?.()` + `?? true` inside its try/catch.
- [ ] Context strings match EXACTLY: "completion provider unavailable",
      "getSuggestions failed", "applyCompletion failed", "shouldTriggerFileCompletion failed".
- [ ] TAB indentation; `node:test` + `assert/strict` + jiti (NOT vitest); fakeSocket/
      parseResponses/readFirstResponse copied verbatim; `__resetHandlersForTest()` in EVERY finally.

### Documentation
- [ ] File-top STATUS block has a `STATUS (P1.M2.T7.S15)` note.
- [ ] The 4 `// throws plain Error … → -32603 (S15 refines)` comments updated to reflect S15 DONE.
- [ ] hello/ping/bye exemption documented (why they're inherently safe).

---

## Anti-Patterns to Avoid

- ❌ Don't modify `handleLine`, `BridgeRpcError`, `sendError`, `ConnectionState`, or any
  existing connection.ts symbol beyond adding `toBridgeRpcError`. connection.ts is
  S8/S10-owned and COMPLETE — the edit is purely additive.
- ❌ Don't change `getProvider()` to throw a `BridgeRpcError`. The HANDLER wraps it; the
  `getProvider()` plain-Error contract (provider-capture.test.ts:29) stays intact.
- ❌ Don't move `narrow*Params` inside the provider try/catch — keep it FIRST so `-32602`
  flows untouched (moving it inside still works via pass-through, but muddies the structure).
- ❌ Don't drop getSuggestions's `finally { clearTimeout(timer) }` when adding the inner
  try/catch — the timer MUST clear on both success and throw.
- ❌ Don't invent `-32000..-32099` codes for provider-not-captured/provider-throw. The Neovim
  client never branches on the code (PRD §11 silent-degrade); `-32603` is the interoperable
  choice. `-320xx` is a documented future refinement, not a v1 requirement.
- ❌ Don't wrap hello/ping/bye in no-op try/catch "for uniformity" — they have no domain
  errors (their getters are pure non-throwing; their only throw is the intentional
  BridgeRpcError). Document them as inherently safe instead.
- ❌ Don't catch and SWALLOW errors (returning a fake success). Every caught domain error
  MUST re-throw via `toBridgeRpcError` so the client gets a real `-32603` response.
- ❌ Don't include the token/descriptor in any error message (PRD §12). The SECURITY sweep
  is the gate.

---

## Confidence Score: 9/10

**Why high confidence**: S15 is a small (1-point), well-bounded, additive change. The
two-layer dispatch model (handler → `BridgeRpcError` → `handleLine` routes by code) ALREADY
exists and is battle-tested by 16 connection.test.ts + 4 handler suites. The exact edit
sites (4 handlers, exact line numbers), exact converter shape, exact message-context strings,
exact tests to flip/update/add, and exact validation commands are all specified. Both research
briefs independently confirm the design (per-handler wrapping + shared converter, keep the
safety net, `-32603` not `-320xx`). The `-32603` code is UNCHANGED on the wire, so no
downstream consumer (P3.M10.T24.S39, P3.M10.T27.S42) needs adjustment.

**Why not 10/10**: Line numbers will drift slightly if S14's edits landed differently than
expected (verify with `grep -n "deps.getProvider()" extension/pi-editor-bridge.ts`); the
implementer must re-anchor to the 4 `// throws plain Error … → -32603 (S15 refines)` comments.
The getSuggestions try/catch-inside-try/finally structure is the one spot requiring care
(clearTimeout must stay unconditional).
