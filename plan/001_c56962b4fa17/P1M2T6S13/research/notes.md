# S13 Research Notes — shouldTriggerFileCompletion handler (synchronous, OPTIONAL method)

Source of truth for the PRP. Verified directly against `~/projects/pi` + the local
`extension/` tree. Two scout concerns: (A) pi's exact contract, (B) test conventions.

## §1. pi's AutocompleteProvider.shouldTriggerFileCompletion — exact contract

`packages/tui/src/autocomplete.ts:269` (the INTERFACE — note the `?`):
```ts
shouldTriggerFileCompletion?(lines: string[], cursorLine: number, cursorCol: number): boolean;
```
Three load-bearing facts:

### §1.1 The method is OPTIONAL (`?` on the interface)
Unlike `getSuggestions` (required) and `applyCompletion` (required), `shouldTriggerFileCompletion`
is marked OPTIONAL on `AutocompleteProvider`. A provider (especially a thin custom WRAPPER that
an extension registers AFTER the bridge's capture factory) is NOT required to implement it.
⇒ The handler MUST use optional chaining `?.` and NEVER call it directly. A direct call on a
provider without the method throws `TypeError: ...is not a function`, which would surface as a
spurious `-32603 internal error` and break Tab-to-force-file-completion in Neovim.

### §1.2 The method is SYNCHRONOUS (returns `boolean`, NOT a Promise)
Identical sync contract to `applyCompletion` (S12). Takes NO options/AbortSignal/force. Returns a
plain `boolean`. The TUI's editor calls it WITHOUT await (editor.ts:2152-2153).
⇒ The handler is SYNC, needs NO AbortController, NO supersession, NO timeout, NO closure state.
Leanest possible shape — same structural profile as S12, only the result type differs (boolean vs object).

### §1.3 The canonical "optional + default true" pattern (pi's OWN precedent, 5 sources)
pi itself — in tests, docs, examples, AND the PRD §6.5 skeleton — always writes:
```ts
return current.shouldTriggerFileCompletion?.(lines, cursorLine, cursorCol) ?? true;
```
Sources (all byte-identical):
- `packages/coding-agent/test/interactive-mode-status.test.ts:310` — pi's own UNIT test.
- `packages/coding-agent/test/interactive-mode-status.test.ts:324` — second test variant.
- `packages/coding-agent/docs/extensions.md:2577` — official "autocomplete provider wrapper" docs.
- `packages/coding-agent/docs/extensions.md:2644` — second docs example.
- `packages/coding-agent/examples/extensions/github-issue-autocomplete.ts:125` — shipped example extension.
- PRD §6.5 skeleton (this task's authoritative shape).

The `?? true` default is SEMANTICALLY MEANINGFUL: "if the provider doesn't decide, ALLOW file
completion." The handler MUST replicate this verbatim — the bridge is a faithful delegate, not an
optimizer. DO NOT default to `false`, DO NOT drop the `?? true`, DO NOT substitute `?? ` (syntax error).

## §2. What the concrete impl actually checks (autocomplete.ts:775-785) — for context only
The base `CombinedAutocompleteProvider` (always captured by the bridge) DOES implement it:
```ts
shouldTriggerFileCompletion(lines, cursorLine, cursorCol) {
  const currentLine = lines[cursorLine] || "";
  const textBeforeCursor = currentLine.slice(0, cursorCol);
  // Don't trigger if we're typing a slash command at the start of the line
  if (textBeforeCursor.trim().startsWith("/") && !textBeforeCursor.trim().includes(" ")) {
    return false;
  }
  return true;
}
```
So the rule is: **return `false` while the user is typing a bare slash command** (e.g. `/set`, before
any space), else `true`. This is WHY Tab on `/set<Tab>` does NOT force file completion in pi (PRD §11
"force file completion on empty line must respect shouldTriggerFileCompletion"). The BRIDGE does NOT
reimplement this — it delegates. But knowing the rule lets tests construct realistic inputs:
- `/set` at col 4 → expect `false` (the realistic "don't force" case).
- `hello wor` at col 9 → expect `true`.

## §3. TUI call site (when the TUI actually consults this) — editor.ts:2148-2158
`shouldTriggerFileCompletion` is consulted ONLY on the `force: true` (Tab-triggered file completion)
path — NEVER on ordinary typed-character autocomplete:
```ts
if (options.force) {
  const shouldTrigger =
    !this.autocompleteProvider.shouldTriggerFileCompletion ||
    this.autocompleteProvider.shouldTriggerFileCompletion(lines, cursorLine, cursorCol);
  if (!shouldTrigger) return;   // skip the forced file-completion request
}
```
Note the TUI's `!method || method(...)` is the SAME as `method?.(...) ?? true` for the absence case
(both yield `true` when the method is missing). The RPC handler uses `?.` + `?? true` because it's
the documented extension-author pattern (§1.3) and is strictly equivalent for the base provider.

## §4. Downstream consumer — Neovim Tab handler (P2.M7.T20.S33)
The Neovim plugin's Tab keymap (PRD §7.4 / §7.6): "Tab with no menu open → call
`shouldTriggerFileCompletion`; if true, call `getSuggestions(..., { force: true })`." So the S13 RPC
is the GATE the Lua side consults BEFORE issuing a forced `getSuggestions`. The bridge's job is to
return pi's boolean verbatim so the plugin's Tab behavior matches the TUI's.

## §5. Error boundary — IDENTICAL to S11/S12 (S15 refines later)
- Malformed params (lines not string[]; cursorLine/cursorCol not non-negative integers) ⇒ handler
  throws `BridgeRpcError(-32602, "invalid params: …")`. `-32602` is the reserved JSON-RPC "invalid
  params" code (protocol.ts §A). Validation runs BEFORE delegation (provider NOT called on bad shape).
- `deps.getProvider()` throws a plain `Error` when the provider is not yet captured (pre-session) ⇒
  flows to `handleLine`'s `-32603` safety net. S13 does NOT wrap it (S15's lane).
- A provider whose `shouldTriggerFileCompletion` throws (a misbehaving wrapper) ⇒ `-32603` safety net.
  S13 lets it propagate (keeps pi safe).
This is the SAME boundary S12 drew — research §5 of the S11 notes spells out the full table.

## §6. Test conventions (IDENTICAL to S11/S12 — copy the closest sibling)
- Framework: `node:test` + `assert/strict` + jiti (NOT vitest). TAB indentation. Test seams named
  `__xForTest`. `registerBridgeHandler(...)` + `__resetHandlersForTest()` in EVERY finally (node:test
  runs sequentially; the module-level handler registry persists across tests).
- Model the new file's imports + helpers on `get-suggestions-handler.test.ts` (closest, newest,
  engine-delegating sibling). COPY `fakeSocket()`/`parseResponses()`/`readFirstResponse()` VERBATIM —
  they are LOCAL per-file helpers (not exported); connection.test.ts, hello-handler.test.ts,
  handshake-gate.test.ts, apply-completion-handler.test.ts, get-suggestions-handler.test.ts each
  re-declare them identically.
- Three layers: UNIT (factory directly + stub provider + fresh `ConnectionState`), DISPATCH
  (registerBridgeHandler + fakeSocket + handleLine; pass `{ handshakeComplete: true }` to open the
  S10 gate), ONE REAL (real Unix-socket pair; hello + shouldTriggerFileCompletion registered).

## §7. The handler is LEANER than S12 (no item/prefix); the `?? true` is the only nuance
| Concern | S12 applyCompletion | **S13 shouldTriggerFileCompletion** |
|---|---|---|
| Params | lines, cursorLine, cursorCol, item, prefix | **lines, cursorLine, cursorCol** (3 fields) |
| Result | `{lines, cursorLine, cursorCol}` object | **`boolean`** |
| Method on provider | required | **OPTIONAL** (`?.` + `?? true`) |
| Sync | yes | **yes** |
| AbortController/timeout/supersession | none | **none** |
| Closure state | none | **none** |
| Deps | `{ getProvider }` | **`{ getProvider }`** |

So S13's factory is `makeShouldTriggerFileCompletionHandler(deps: { getProvider })` returning a SYNC
`MethodHandler`. The ONLY S13-specific test cases (beyond S12's param-validation mirror) are:
- (a) provider WITHOUT the method ⇒ returns `true` (the `?? true` default) — proves `?.` works.
- (b) provider WITH the method returning `false` ⇒ returns `false` verbatim.
- (c) provider WITH the method returning `true` ⇒ returns `true` verbatim.

## §8. Registration site (pi-editor-bridge.ts)
Add ONE `registerBridgeHandler("shouldTriggerFileCompletion", makeShouldTriggerFileCompletionHandler({ getProvider }))`
line in the `session_start` handler, immediately AFTER the existing `applyCompletion` registration
(S12) and BEFORE the `TODO(S13)` comment (which gets updated to mark S13 done; keep S14/S16 TODOs).
Add `ShouldTriggerFileCompletionParams, ShouldTriggerFileCompletionResult` to the existing protocol.ts
import block. Update the file-top STATUS block. `connection.ts` and `protocol.ts` are UNCHANGED (both
already support a sync boolean return — `MethodHandler = (...) => Promise<unknown> | unknown`).

## §9. Commands & validation (verified working baseline)
- `tsc --noEmit -p extension/tsconfig.json` ⇒ exit 0 (clean pre-write).
- Test runner: `JITI_REG=/home/dustin/.local/lib/node_modules/@earendil-works/pi-coding-agent/node_modules/jiti/lib/jiti-register.mjs`
  then `node --import "$JITI_REG" extension/tests/<file>.test.ts` ⇒ judge by exit code + `ℹ pass`/`ℹ fail`.
- Current test file count: **11** (apply-completion-handler.test.ts is the newest, S12). S13 adds
  `should-trigger-file-completion-handler.test.ts` → **12**. All sibling suites must stay green.
