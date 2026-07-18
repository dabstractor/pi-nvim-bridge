# S11 Research Notes — getSuggestions handler (AbortController + supersession)

Source of truth for the PRP. Two scout passes: pi internals + test conventions.

## §1. pi's AutocompleteProvider.getSuggestions — exact contract

`packages/tui/src/autocomplete.ts:241-271`:
```ts
getSuggestions(
  lines: string[],
  cursorLine: number,
  cursorCol: number,
  options: { signal: AbortSignal; force?: boolean },   // signal ALWAYS present & required; force optional
): Promise<AutocompleteSuggestions | null>;
```

### §1.1 How the provider uses `signal` (CombinedAutocompleteProvider)
- **Only the `@`-prefix fuzzy path is async/signal-aware.** It calls
  `getFuzzyFileSuggestions(query, {signal})` → `walkDirectoryWithFd(..., signal)`.
- `walkDirectoryWithFd` (autocomplete.ts:118-220) wires the signal THREE ways:
  1. entry check: `if (signal.aborted) resolve([]);`
  2. `signal.addEventListener("abort", () => child.kill("SIGKILL"))` — **abortion SIGKILLs the fd child.**
  3. `child.on("close", ...)`: `if (signal.aborted || code !== 0 || !stdout) finish([])`.
- **The sync paths (`/command` via `fuzzyFilter`, and `getFileSuggestions`/`readdirSync`) NEVER check `signal.aborted`** — they run to completion regardless. Fast, but uncancellable.
- **There is NO timeout anywhere in the provider or interactive-mode.** The provider expects the CALLER to abort via signal. This is exactly why PRD §5.5/§6.5 mandates a per-request timeout on the BRIDGE.

### §1.2 Abort → resolve, never reject
**The built-in provider NEVER throws on abort — it RESOLVES.** Aborted `@` path → `getFuzzyFileSuggestions` returns `[]` → `getSuggestions` returns `null`. So:
- When the bridge supersedes (aborts a prior in-flight controller), the prior call resolves to `null` shortly (fd SIGKILL'd) → its `handleLine` sends `{id, result: null}`. The CLIENT ignores stale ids (PRD §5.5). **Both requests get responses; this is correct RPC behavior.**
- A misbehaving extension wrapper COULD throw on abort (editor.ts awaits bare — would break ITS chain). The bridge must NOT assume the live chain throws; but it also must not crash if it does → S15 / the `-32603` safety net in `handleLine` covers it.

### §1.3 editor.ts supersession (the TUI's own model — for reference)
Three layered mechanisms (`packages/tui/src/components/editor.ts:2147-2290`):
1. `requestAutocomplete` → `cancelAutocompleteRequest()`: `autocompleteStartToken++`, clear debounce timer, `autocompleteAbort?.abort()` (aborts the PREVIOUS controller).
2. Serialized task chain `autocompleteRequestTask` (never two in-flight in the TUI).
3. Post-await staleness gate `isAutocompleteRequestCurrent`.
- Debounce const `ATTACHMENT_AUTOCOMPLETE_DEBOUNCE_MS = 20`; `force`/explicitTab ⇒ debounce 0 (immediate).
- The bridge does NOT replicate the TUI's serialized task chain or snapshot gate — the BRIDGE delegates supersession to (a) AbortController abort of the pending provider call + (b) per-request id correlation on the client side (PRD §5.5). Each server request is independent and gets its own response. This is the RPC-appropriate mirror.

## §2. PRD §6.5 reference skeleton (the authoritative shape)
```ts
const handlers = {
  async getSuggestions({ lines, cursorLine, cursorCol, force }) {
    requireProvider();
    const ac = new AbortController();
    pendingAbort?.abort();           // supersede any in-flight call
    pendingAbort = ac;
    const t = setTimeout(() => ac.abort(), 1500);
    try {
      return await liveProvider!.getSuggestions(lines, cursorLine, cursorCol,
        { signal: ac.signal, force: !!force });
    } finally { clearTimeout(t); }
  },
  ...
};
```
- 1500 ms per-request timeout (PRD §5.5) aborts runaway `fd`.
- `pendingAbort` is a SINGLE shared reference across all getSuggestions calls (supersession is global to the one registered handler).

## §3. Where S11's state lives (design decision)
- The handler is a FACTORY `makeGetSuggestionsHandler(deps)` mirroring `makeHelloHandler`.
- `pendingAbort` is a **closure variable INSIDE the factory** (encapsulated; shared across all calls of that one instance). There is exactly one getSuggestions handler registered per session, so closure-scoped supersession is correct. (Cross-connection supersession is acceptable — PRD §5.3 bar is "one robust connection"; two editors sharing one provider/fd pool, aborting each other's stale search, is fine and arguably correct.)
- `timeoutMs` is injected via deps with default 1500 → **testable without a module-level test seam** (matches the makeHelloHandler deps-injection philosophy, and the `version` injection precedent).

## §4. Task boundary: S11 vs S15 (error wrapping)
- **S9 (hello) established the precedent**: handlers DO throw `BridgeRpcError(code,msg)` for input validation (hello throws -32600 on bad token). So **S11 throwing `BridgeRpcError(-32602)` for malformed params is in-scope and on-pattern** (-32602 = reserved "invalid params").
- **S15** ("wrap ALL handlers' domain errors into proper codes") owns catching the provider's RUNTIME throws (e.g. a misbehaving wrapper) and the provider-not-captured state, wrapping them into codes. For S11:
  - `deps.getProvider()` (the module `getProvider`) throws a plain `Error` when not captured → propagates → `handleLine` `-32603` safety net. S15 may later refine to a specific code. **S11 does NOT need to wrap this** (keep S11 focused on AbortController/supersession; the -32603 net keeps pi safe).
  - Provider throwing during the await → same `-32603` net. S15 refines.
- Net: S11 = AbortController + supersession + timeout + param validation (-32602) + signal/force threading. NOT provider-error wrapping.

## §5. Test conventions (verbatim — see test-conventions.md)
- Runner: `node:test` + `jiti` (NOT vitest). Command:
  `node --import /home/dustin/.local/lib/node_modules/@earendil-works/pi-coding-agent/node_modules/jiti/lib/jiti-register.mjs extension/tests/<file>.test.ts`
- `node:test` runs SEQUENTIALLY; module registry persists → `__resetHandlersForTest()` in every `finally`.
- Helpers copied VERBATIM per file: `fakeSocket()`, `parseResponses(writes)`, `readFirstResponse(client)`. (Defined locally in connection.test.ts; copied into hello-handler.test.ts and handshake-gate.test.ts.)
- Imports block modeled on handshake-gate.test.ts (cleanest/current): combined `{ EventEmitter, once }`, explicit `.ts` import extensions.
- Three layers per handler suite: UNIT (call factory with stubbed deps + fresh ConnectionState) / DISPATCH (registerBridgeHandler + fakeSocket + handleLine, `{handshakeComplete:true}` for gated happy paths) / REAL (exactly ONE real Unix-socket pair: registerBridgeHandler hello + getSuggestions → createServer((c)=>onConnection(c)) → listen → connect → readFirstResponse BEFORE write → await).
- REAL write uses `serializeJsonLine(...)`; DISPATCH passes `JSON.stringify(...)` as handleLine's `line`.
- `setTimeout`/`clearTimeout` ARE typed globals here (used in bridge-lifecycle-wiring.test.ts:109 + hello-handler.test.ts:349, both type-check clean under `tsc`). No special typing needed; `ReturnType<typeof setTimeout>` is the proven idiom (editor.ts) if paranoid.

## §6. Integration points (verified against current code)
- `extension/pi-editor-bridge.ts` session_start currently registers `hello` after `startBridge(ctx)`. **ADD** the getSuggestions registration immediately after the hello `registerBridgeHandler` call: `registerBridgeHandler("getSuggestions", makeGetSuggestionsHandler({ getProvider }));`
- Imports to ADD in pi-editor-bridge.ts: `GetSuggestionsParams, GetSuggestionsResult` from `./protocol.ts` (extend the existing `import type { HelloParams, HelloResult } from "./protocol.ts"`). `AutocompleteProvider` already imported from `@earendil-works/pi-tui`. `BridgeRpcError` already imported from `./connection.ts`.
- `extension/connection.ts` is UNCHANGED (MethodHandler is already `Promise<unknown> | unknown`; handleLine already awaits + sends response; the -32603 safety net + BridgeRpcError handling already cover handler throws). S11 adds NO change to connection.ts.
- `extension/protocol.ts` is UNCHANGED (GetSuggestionsParams/GetSuggestionsResult already defined in §C). S11 CONSUMES them.
