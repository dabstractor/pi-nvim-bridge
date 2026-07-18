# S12 Research Notes — applyCompletion handler

Source of truth for the PRP. Single scout pass: pi `applyCompletion` contract + how
the TUI editor calls it. S12 is structurally SIMPLER than S11 (no AbortController,
no timeout, no supersession) because pi's `applyCompletion` is a pure synchronous
function.

## §1. pi's AutocompleteProvider.applyCompletion — exact contract

`packages/tui/src/autocomplete.ts:256-271` (interface):
```ts
applyCompletion(
  lines: string[],
  cursorLine: number,
  cursorCol: number,
  item: AutocompleteItem,
  prefix: string,
): { lines: string[]; cursorLine: number; cursorCol: number };   // <-- SYNCHRONOUS, no Promise
```

Implementation: `packages/tui/src/autocomplete.ts:375+` (CombinedAutocompleteProvider).

### §1.1 SYNCHRONOUS — the defining difference from S11
- `applyCompletion` is **NOT async** and takes **NO `options`/`AbortSignal`/`force`**.
  It is a pure function of `(lines, cursor, item, prefix) → (new lines, new cursor)`.
- It returns the **FULL new buffer** (`lines: string[]`) + new cursor — the caller
  replaces the entire line array (editor.ts:671 `this.state.lines = result.lines`).
- It is declared **REQUIRED** on the interface (no `?`), unlike
  `shouldTriggerFileCompletion` which is optional. So a typed `AutocompleteProvider`
  always has `applyCompletion`. A sloppy runtime wrapper that omits it →
  `TypeError: ... not a function` → caught by `handleLine`'s `-32603` safety net (S15
  refines). Same lane as getSuggestions provider-not-captured.

### §1.2 Insertion logic lives ENTIRELY in pi (the bridge just forwards)
- pi's impl handles: slash-command (`/cmd ` + trailing space), `@file` (trailing space
  for files, none for dirs), quote handling (quoted prefixes, trailing quotes), cursor
  repositioning. The bridge must NOT reimplement any of this — it forwards `(lines,
  cursor, item, prefix)` and returns pi's result verbatim (PRD §4 step 5, §7.4).
- `prefix` is whatever the client sends back — pi's TUI uses `this.autocompletePrefix`
  (the prefix pi's OWN `getSuggestions` returned). The Neovim client stores the
  `AutocompleteSuggestions.prefix` from its `getSuggestions` response and passes it back
  here. The bridge treats `prefix` as an opaque string.

### §1.3 editor.ts call sites (3) — all IDENTICAL, all sync, all unguarded
- `editor.ts:669` (Tab accept), `editor.ts:690` (confirm/Enter accept),
  `editor.ts:2257` (force+explicitTab single-item auto-accept).
- ALL do `const result = this.autocompleteProvider.applyCompletion(lines, cl, cc,
  selected, prefix)` with NO `await`, NO try/catch, NO null check on result, then
  `this.state.lines = result.lines; this.state.cursorLine = result.cursorLine;
  this.setCursorCol(result.cursorCol)`.
- Implication: pi's contract is that `applyCompletion` never throws in normal use and
  always returns the result object. The bridge nonetheless wraps every handler call in
  try/catch (`handleLine` → `-32603` on any throw), so a wrapper that throws is safe.

## §2. AutocompleteItem shape (protocol.ts re-exports from pi-tui)
```ts
export interface AutocompleteItem {
  value: string;     // REQUIRED
  label: string;     // REQUIRED
  description?: string;  // OPTIONAL
}
```
The `item` param in ApplyCompletionParams is this shape. Param validation MUST accept a
missing `description` (optional) but REQUIRE `value` + `label` as strings.

## §3. S12 vs S11 — what S12 does NOT need
| Concern | S11 (getSuggestions) | S12 (applyCompletion) |
|---|---|---|
| AbortController | YES (fresh per call) | **NO** — sync, no signal |
| Supersession (`pendingAbort`) | YES (abort prior in-flight) | **NO** — sync calls can't be in-flight |
| Per-request timeout | YES (1500 ms; abort runaway fd) | **NO** — sync, no async work to time out |
| `force` flag | YES (threaded to provider) | **NO** — not in the signature |
| `timeoutMs` dep | YES (injected for tests) | **NO** |
| Closure state | YES (`pendingAbort`) | **NO** — pure stateless delegation |
| Handler async? | YES (`async`) | **NO** — SYNC (returns result directly) |

S12's factory is `makeApplyCompletionHandler(deps: { getProvider })` — a SINGLE dep,
matching the shape of the PRD §6.5 skeleton which has NO timeout/supersession for
applyCompletion. Over-engineering S12 with AbortController/timeout would be WRONG.

## §4. MethodHandler accommodates sync — verified
`connection.ts`: `MethodHandler = (params, state) => Promise<unknown> | unknown`.
`handleLine` does `const result = await handler(params, state)` — `await` on a
non-Promise (a plain object) resolves immediately to that object. So a SYNC handler
(returning `{lines,...}` directly) is fully supported with zero dispatch changes.
S12 SHOULD return sync to faithfully mirror pi's own contract (avoid implying async
work exists).

## §5. Param validation rules (throw BridgeRpcError(-32602))
Same -32602 precedent as S11 (S9 established handler-level input validation throws
typed errors; -32602 = reserved "invalid params"). Rules for `ApplyCompletionParams`:
- params is a non-null object.
- `lines`: Array, every element a string.
- `cursorLine`: non-negative integer.
- `cursorCol`: non-negative integer.
- `item`: non-null object with `value: string` AND `label: string` (description optional).
- `prefix`: string.

Provider-not-captured (`getProvider()` throws) + provider runtime throw → propagate to
`handleLine` `-32603` safety net (S15's lane; S12 does NOT wrap — same boundary as S11).

## §6. Test conventions (unchanged from S11 — verified)
- Runner: `node:test` + `jiti` (NOT vitest).
  `node --import /home/dustin/.local/lib/node_modules/@earendil-works/pi-coding-agent/node_modules/jiti/lib/jiti-register.mjs extension/tests/apply-completion-handler.test.ts`
- `node:test` runs SEQUENTIALLY; module registry persists → `__resetHandlersForTest()`
  in every finally.
- COPY `fakeSocket()`/`parseResponses()`/`readFirstResponse()` VERBATIM from
  get-suggestions-handler.test.ts (LOCAL per-file helpers, not exported).
- Three layers: UNIT (factory + stub provider + fresh ConnectionState) / DISPATCH
  (registerBridgeHandler + fakeSocket + handleLine, `{handshakeComplete:true}`) / REAL
  (ONE real Unix-socket pair; hello + applyCompletion).
- Imports block modeled on get-suggestions-handler.test.ts (current sibling).

## §7. Integration points (verified against current code — post-S11)
- `extension/pi-editor-bridge.ts`: ADD `makeApplyCompletionHandler` factory +
  `narrowApplyCompletionParams` helper + extend protocol import to add
  `ApplyCompletionParams, ApplyCompletionResult`. ADD one registration line AFTER the
  existing `getSuggestions` `registerBridgeHandler`. Update the `TODO(S12)` comment.
- `extension/connection.ts`: UNCHANGED (sync return supported; -32603 net + BridgeRpcError
  handling cover all throw paths).
- `extension/protocol.ts`: UNCHANGED (ApplyCompletionParams/ApplyCompletionResult already
  defined in §C). S12 CONSUMES them.

## §8. Baseline confirmed (pre-write)
- `tsc --noEmit -p extension/tsconfig.json` ⇒ clean (exit 0).
- `node --import "$JITI_REG" extension/tests/get-suggestions-handler.test.ts` ⇒ 15/15 pass.
- `setTimeout` typed globals are a non-issue for S12 (no timer used).
