# S15 Research Notes — Wrap all handlers in try/catch with JSON-RPC error responses

> Consolidated design notes for P1.M2.T7.S15. Authoritative cross-references:
> `research/pi-rpc-error-pattern.md` (how pi's RPC engine does it) and
> `research/jsonrpc-error-best-practices.md` (external spec/interop guidance).

## 1. What S15 actually is (precise scope)

T7 = "Cancellation, timeout & error wrapping". Cancellation + timeout already shipped in
S11 (`makeGetSuggestionsHandler`'s `pendingAbort` supersession + `GET_SUGGESTIONS_TIMEOUT_MS`).
**S15 is the "error wrapping" remainder**, scoped to 1 point: ensure every handler converts
its domain errors into proper JSON-RPC codes via `BridgeRpcError` *before* they reach
`handleLine`'s generic `-32603` last-resort safety net.

## 2. Current state (verified by reading connection.ts + pi-editor-bridge.ts)

- `handleLine` (connection.ts ~L188-310) ALREADY has the two-try/catch dispatch (parse →
  `-32700`; handler-call → `instanceof BridgeRpcError ? code : -32603`). This is the
  **last-resort safety net** and STAYS UNCHANGED.
- `BridgeRpcError` (connection.ts:55) is the typed mechanism (code + optional `fatal`).
- Params validation (`-32602`) ALREADY throws `BridgeRpcError` in the `narrow*Params` helpers
  (get-suggestions L540, apply L640, should-trigger L735). These are ALREADY proper → no change.
- `hello` ALREADY throws `BridgeRpcError(-32600, "bad token", {fatal:true})`. No change.
- **The gap (S15's lane):** the 4 provider-dependent handlers call `deps.getProvider()`
  (pi-editor-bridge.ts:573/678/770/827) which throws a PLAIN `Error("…not captured…")`, and
  call provider methods (L581/680/774/829) that may throw. Today those plain throws fall to
  the safety net's `else` → `-32603 "internal error: <raw msg>"`. S15 wraps them into
  `BridgeRpcError(-32603)` with clean, context-prefixed messages AT THE HANDLER EDGE.

## 3. Design decision (confirmed by both research briefs)

**Per-handler explicit try/catch + a shared `toBridgeRpcError(err, context)` converter.**
- pi's RPC engine (rpc-mode.ts `handleInputLine` L758-793) uses ONE generic catch-all that
  flattens every throw to `error:<msg>` — it has NO codes, NO typed-error class, and is NOT
  JSON-RPC 2.0. The bridge ALREADY diverges to real JSON-RPC 2.0 + `BridgeRpcError`. So S15
  must NOT mirror pi literally; it builds on the bridge's own machinery. (See
  `pi-rpc-error-pattern.md` §7-8.)
- The mature LSP/MCP pattern (`vscode-jsonrpc`, MCP TS SDK): await handler in try/catch at
  dispatch, map known/domain errors to specific codes, sanitize client message, keep a
  top-level catch-all. Exactly the two-layer model the bridge has. (See
  `jsonrpc-error-best-practices.md` §3, §5.)

**Converter shape** (additive export in connection.ts, near `BridgeRpcError`):
```ts
export function toBridgeRpcError(err: unknown, context: string): BridgeRpcError {
  if (err instanceof BridgeRpcError) return err;        // pass-through (-32602, -32600 keep their code)
  const detail = err instanceof Error ? err.message : String(err);
  return new BridgeRpcError(-32603, `${context}: ${detail}`);
}
```

## 4. Error-code choice: `-32603` (not `-320xx`)

Research verdict (`jsonrpc-error-best-practices.md` §2): default to `-32603 Internal error`
for unexpected handler failures; reserve `-32000..-32099` ONLY for *known, distinguished*
modes a client branches on. The Neovim client treats ALL completion errors as silent-degrade
(PRD §11) — it never branches on the code. So a single `-32603` with a descriptive,
context-prefixed message is the interoperable choice. `-320xx` for provider-not-captured is
documented as a future refinement (PRD §15) but NOT introduced now (no client behavior
depends on it; avoids taxonomy sprawl). **All 5 existing `-32603` code assertions stay
green** (provider-not-captured DISPATCH test still sees -32603, just via the handler's
BridgeRpcError instead of the safety net's else-branch).

## 5. Which handlers get wrapped

| Handler | Has domain errors? | S15 action |
|---|---|---|
| `hello` (L401) | NO — only the intentional `-32600` throw; getToken/getCwd/getFdAvailable are pure | Documented inherently safe; NO wrap |
| `ping` (L448) | NO — getPid/getCwd/getFdAvailable are pure non-throwing getters | Documented inherently safe; NO wrap |
| `bye` (L486) | NO — sets a flag, returns {ok:true} | Documented inherently safe; NO wrap |
| `getSuggestions` (L562) | YES — getProvider + provider.getSuggestions | WRAP (2 try/catch) |
| `applyCompletion` (L670) | YES — getProvider + provider.applyCompletion | WRAP (2 try/catch) |
| `shouldTriggerFileCompletion` (L762) | YES — getProvider + provider.shouldTriggerFileCompletion?.() | WRAP (2 try/catch) |
| `getCommands` (L820) | YES — getProvider + provider.getSuggestions(["/"]) | WRAP (2 try/catch) |

"Wrap ALL handlers" is satisfied: the 4 that CAN fail with domain errors get explicit
wrapping; the other 3 are inherently safe AND still covered by the safety net.

## 6. Test impact (verified by grep)

FLIP (UNIT, 4 files — plain-Error expectation → BridgeRpcError(-32603)):
- `get-suggestions-handler.test.ts:376`
- `apply-completion-handler.test.ts:325`
- `should-trigger-file-completion-handler.test.ts:319`
- `ping-bye-getcommands-handler.test.ts:351` (getCommands)

COMMENT/TIGHTEN (DISPATCH, code stays -32603):
- `ping-bye-getcommands-handler.test.ts:608` (getCommands provider-not-captured — safety net
  → now handler-wrapped; update comment, optionally assert message prefix)

UNCHANGED:
- `connection.test.ts` safety-net tests (use GENERIC throws, orthogonal to handler wrapping)
- `provider-capture.test.ts:29` (`getProvider()` STILL throws plain Error — the HANDLER wraps
  it; this test asserts getProvider itself, not the handler)

NEW (`error-wrapping.test.ts`):
- `toBridgeRpcError` unit tests (pass-through / wraps Error / wraps non-Error / -32603 / context prefix)
- provider-method-THROWS → BridgeRpcError(-32603) for ALL 4 handlers (NEW coverage — today
  no test asserts provider-method-throw wrapping because S11-S14 didn't wrap it)
- DISPATCH-level: provider-not-captured → exactly one `-32603` with the wrapped message prefix
- SECURITY: token value never appears in any wrapped error message/stderr (PRD §12)

## 7. Message-context strings (per handler)

- getProvider throws → `"completion provider unavailable"` (all 4 handlers)
- provider.getSuggestions throws → `"getSuggestions failed"` (getSuggestions + getCommands)
- provider.applyCompletion throws → `"applyCompletion failed"`
- provider.shouldTriggerFileCompletion?.() throws → `"shouldTriggerFileCompletion failed"`

Resulting wire message e.g. `"completion provider unavailable: pi-editor-bridge: autocomplete
provider not captured yet (await session_start)"`. Informative, no stack, no token.
