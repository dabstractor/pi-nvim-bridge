# Research Notes — applyCompletion handler (synchronous delegation)

> **Path note:** The orchestrator assigned this item the artifact path `P1M2T4S2/`,
> but its title ("applyCompletion handler"), contract, and PRD selectors
> (`h3.14` = §6.5 request-handling skeleton, `h3.8` = §5.4 methods, `h3.3` = §2.2
> autocomplete engine) identify it as task **P1.M2.T6.S12** ("applyCompletion
> handler") in the plan tree. Build the applyCompletion handler; ignore the folder label.

This research runs **in parallel with P1.M2.T6.S11** (`getSuggestions` handler,
artifacts under `P1M2T4S1/`). S11's PRP is treated as a CONTRACT: it lands first (or
concurrently into the same file) and introduces `ConnectionContext`, `HandlerOutcome<T>`,
a module-private `toRpcError(err, code)`, the `__handlerDeps` timeout seam, and the
`pendingAbort` supersession slot. S12 (applyCompletion) REUSES `ConnectionContext` and
`HandlerOutcome<T>` and is purely additive to the same `extension/pi-editor-bridge.ts`.

## 1. applyCompletion is SYNCHRONOUS (the load-bearing fact for S12)

**Finding (verified from compiled source):** pi's `AutocompleteProvider.applyCompletion`
is a **plain synchronous method** — it returns `{ lines, cursorLine, cursorCol }`, NOT a
`Promise`. Confirmed at two layers:

- **Interface** (`packages/tui/src/autocomplete.ts:128-137`, mirrored in the architecture
  research `research-pi-autocomplete.md` §1):
  ```ts
  applyCompletion(
      lines: string[], cursorLine: number, cursorCol: number,
      item: AutocompleteItem, prefix: string,
  ): { lines: string[]; cursorLine: number; cursorCol: number };  // NOT Promise<...>
  ```
- **Compiled impl** (`.../pi-tui/dist/autocomplete.js:262`, read in full during this
  research): `applyCompletion(lines, cursorLine, cursorCol, item, prefix) { ... return
  { lines: newLines, cursorLine, cursorCol: ... }; }` — no `async`, no `await`, returns a
  plain object literal on every branch.

**Implication for the handler design:** S12's `handleApplyCompletion` MUST be a **plain
function** returning `HandlerOutcome<ApplyCompletionResult>` (NOT `Promise<HandlerOutcome<...>>`).
It uses:
- **NO** `async`/`await`,
- **NO** `AbortController` (there is nothing to cancel — the call is synchronous),
- **NO** supersession (`pendingAbort`) — that is getSuggestions-specific (a slow async `fd`
  run); a sync call cannot be interrupted and always completes within one tick,
- **NO** timeout — a sync call cannot "run away" (it either returns or throws synchronously).

This is the SINGLE most important difference from S11. The item contract explicitly states
"This is synchronous — no async/await needed" and PRD §6.5's skeleton is sync:
```ts
applyCompletion({ lines, cursorLine, cursorCol, item, prefix }) {
    requireProvider();
    return liveProvider!.applyCompletion(lines, cursorLine, cursorCol, item, prefix);
},
```
S12 wraps that skeleton in a try/catch + `HandlerOutcome` envelope (to satisfy §6.7
"never throws"), but preserves the sync shape.

## 2. applyCompletion returns a NEW array — does NOT mutate input (test-fake design)

The compiled impl (autocomplete.js:262-330) on every branch does:
```js
const newLines = [...lines];   // shallow-copy the array
newLines[cursorLine] = newLine; // replace only the edited line
return { lines: newLines, cursorLine, cursorCol: ... };
```
So the provider NEVER mutates the caller's `lines` array — it returns a fresh array with
one element replaced. **For the test fake provider this means:** returning
`{ lines: [...params.lines], ... }` is faithful; the handler must forward the provider's
result object **by reference (identity)** — it must NOT clone or transform it (the
dispatcher envelopes `result` verbatim). The happy-path test asserts REFERENCE EQUALITY
(`assert.equal(outcome.result, sentinelResult)`).

## 3. prefix + item semantics (context for the test, not the handler)

`applyCompletion` uses `prefix` to classify the completion and compute `beforePrefix`
(`currentLine.slice(0, cursorCol - prefix.length)`) and the new cursor col:
- `prefix.startsWith("/")` + `beforePrefix.trim()===""` + no nested `/` → slash-command
  name (inserts `/${item.value} ` → cursor +2).
- `prefix.startsWith("@")` → file attachment (inserts `item.value` + `" "` unless the
  label ends with `/` → directory, no trailing space).
- `textBeforeCursor` contains `/` + space → slash-command argument completion.
- else → raw file path.

**The handler does NONE of this math** — it delegates verbatim. This knowledge exists only
so the test fake provider is realistic (it can mirror the slash-command shape to prove arg
passthrough) and so the PRP can cite that `prefix`/`item` are forwarded untouched. No
cursor logic lives in S12.

## 4. Reuse S11's contract types; DO NOT reuse its toRpcError

S11 (contract, landing in the same file) introduces, after `getProvider()`:
- `export interface ConnectionContext { readonly socket: Socket; handshakeDone: boolean; }`
- `export type HandlerOutcome<T> = { ok: true; result: T } | { ok: false; error: JsonRpcError };`
- `function toRpcError(err: unknown, code: number): JsonRpcError` — **module-private**, and
  its message is HARDCODED: `` `getSuggestions failed: ${message}` ``. S11's PRP explicitly
  notes "Kept module-private; S15 may generalize it across handlers later."

**S12 decisions:**
- **REUSE** `ConnectionContext` and `HandlerOutcome<T>` — they are S11's shared
  handler↔dispatcher contract (same file → NO import; they are in module scope). The item
  contract and S11 PRP both say "S12/S13/S14 reuse it".
- **DO NOT reuse `toRpcError`** — its "getSuggestions failed" prefix would be a WRONG,
  misleading message for applyCompletion. S12 instead **inlines** its `JsonRpcError`:
  `{ code: -32603, message: \`applyCompletion failed: ${err instanceof Error ? err.message : String(err)}\` }`.
  Rationale: (a) it produces the correct method-scoped message; (b) it does NOT touch
  S11's `toRpcError` (no merge conflict under parallel execution); (c) S11 itself says S15
  will generalize the per-handler error helper — so per-handler inline errors are the
  intended interim shape. S12 MUST NOT define a second `toRpcError` (would collide with
  S11's module-private one → `Duplicate identifier` / redeclaration).

## 5. Single try/catch is correct (no supersession state to protect)

S11 split `getProvider()` into its OWN try/catch BEFORE touching `pendingAbort`, so a
"not captured" failure short-circuits without aborting a valid pending request. S12 has
**no supersession state** to protect (sync handler), so a SINGLE try/catch wrapping both
`getProvider()` and `provider.applyCompletion(...)` is correct, simpler, and equally
sound: both failure modes map to the same `{ ok:false, error:{code:-32603, ...} }`, and
`getProvider()`'s throw message ("...not captured yet (await session_start)") surfaces
verbatim inside "applyCompletion failed: ...". No two-phase catch needed.

## 6. Globals + type-only import type-check under the current tsconfig (verified)

- **`Error`** (`err instanceof Error`), **`String`**, **`console`** are all in `lib.es5` /
  `lib.dom`, which the extension tsconfig includes by default (it has **no `lib` field** +
  `"types":[]` → DOM defaults; this is the SAME verified finding as S11 research §2, which
  confirmed `AbortController`/`setTimeout`/`Error` type-check). So S12 needs **NO new
  runtime import** — only a **type-only** import of `ApplyCompletionParams` and
  `ApplyCompletionResult` from `./protocol.ts` (both are exported from protocol.ts §C and
  are pure types — `protocol.ts` is type-only, zero runtime exports, confirmed by
  `protocol.test.ts`).
- **`ConnectionContext` / `HandlerOutcome`** are in the SAME module (`pi-editor-bridge.ts`,
  added by S11) → NO import for them. S12 references them directly in module scope.
- **Import-statement merge guidance:** S11 creates
  `import type { GetSuggestionsParams, GetSuggestionsResult, JsonRpcError } from "./protocol.ts";`.
  S12 ADDS `ApplyCompletionParams, ApplyCompletionResult` to that SAME statement (keep ONE
  import line from `./protocol.ts`). tsc accepts the merge regardless of which lands first.
  S12 does NOT need `JsonRpcError` as a named import (it inlines the error object; the
  `HandlerOutcome<T>` generic constrains the `error` field structurally).

## 7. Test conventions (verified, reused verbatim from S2/S3/S4/S5 + S11)

- Runner: `node --import /home/dustin/.local/lib/node_modules/@earendil-works/pi-coding-agent/node_modules/jiti/lib/jiti-register.mjs extension/tests/handler-applycompletion.test.ts` (exact register path verified present: `jiti/lib/jiti-register.mjs`). Judge by exit code + pass/fail; jiti prints a benign `DEP0205` deprecation on stderr — ignore it.
- Imports: `import { test } from "node:test";` + `import assert from "node:assert/strict";` (top-level `test(...)`, NO `describe`).
- Fake-ctx cast: `{ ... } as unknown as ExtensionContext`.
- Fake-provider injection via the EXISTING `captureProvider` idiom (no new seam):
  `captureProvider({ ui: { addAutocompleteProvider: (f) => f(fakeProvider) } } as unknown as ExtensionContext)` sets the module singleton `liveProvider` to `fakeProvider` (proven by `provider-capture.test.ts`).
- **Shared module state** (`liveProvider`): node:test runs top-level tests SEQUENTIALLY in definition order (do NOT enable concurrency); the "not captured" test MUST be FIRST (before any install). Each test FILE is a separate `node` process → `liveProvider` starts `undefined` per file.
- Indentation: **TABS** (match existing `pi-editor-bridge.ts` + all existing tests).

## 8. Validation commands (verified working in this repo)

- Type gate: `tsc --noEmit -p extension/tsconfig.json` → exit 0, no output (baseline post-S6
  already passes; S12 is purely additive: one new sync function + one new test file under
  the existing `tests/**/*.ts` glob → NO tsconfig edit).
- New suite: the jiti runner above → expect exit 0, `fail 0`, `pass 3`.
- Regression: re-run `provider-capture.test.ts`, `mode-guard.test.ts`, `protocol.test.ts`,
  `bridge-lifecycle.test.ts`, `bridge-lifecycle-wiring.test.ts` — each a separate process,
  each `fail 0`. S12 touches nothing they depend on.
- Smoke: `pi --no-extensions -e ./extension/pi-editor-bridge.ts --print "ok"` exits 0 with no
  error lines AND the startup log is still ABSENT in print mode (S3 TUI guard intact — S12
  does NOT touch the default-export factory).
