# Research Notes — getSuggestions handler (AbortController + supersession)

> **Path note:** The orchestrator assigned this work item the artifact path
> `P1M2T4S1/`, but its title, contract, and PRD selectors (`h3.14` = §6.5 request
> handling, `h3.8` = §5.4 methods, `h3.9` = §5.5 timing, `h3.3` = §2.2 engine)
> unambiguously identify it as the **getSuggestions RPC handler** — task
> **P1.M2.T6.S11** ("getSuggestions handler with AbortController + supersession")
> in the plan tree. The PRP content is for THAT handler; only the on-disk folder
> label differs. Implementer: ignore the folder label, build the getSuggestions
> handler described in the PRP.
>
> This research runs **in parallel with P1.M2.T3.S5** (`startBridge`). S5's PRP is
> treated as a contract (it lands first). This handler is additive to the
> post-S5 `extension/pi-editor-bridge.ts`.

## 1. The governing abort behavior of pi's provider (LOAD-BEARING)

**Finding (verified from source):** pi's `CombinedAutocompleteProvider.getSuggestions`
**RESOLVES with `null` on abort — it does NOT throw an `AbortError`.**

Source: `packages/tui/src/autocomplete.ts` (compiled mirror read at
`.../pi-tui/dist/autocomplete.js`). The `@`-prefix path shells out to `fd` via
`walkDirectoryWithFd(baseDir, fdPath, query, 100, signal)`:

- `walkDirectoryWithFd` (autocomplete.js ~L100): if `signal.aborted` → `resolve([])`
  immediately; otherwise `signal.addEventListener("abort", onAbort, {once:true})`
  where `onAbort` does `child.kill("SIGKILL")`. On `close`, if `signal.aborted ||
  code!==0 || !stdout` → `finish([])`. So abort → SIGKILL fd → `close` → `resolve([])`.
- `getFuzzyFileSuggestions` (autocomplete.js ~L577): guard
  `if (!this.fdPath || options.signal.aborted) return [];`; after the walk,
  `if (options.signal.aborted) return [];`; the whole fn is wrapped in
  `try { … } catch { return []; }`.
- `getSuggestions` (the public method): for `@`-prefix,
  `const suggestions = await getFuzzyFileSuggestions(...); if (suggestions.length===0)
  return null;`. So abort → `[]` → **returns `null`**.
- **Path completion** (`getFileSuggestions`) uses synchronous `readdirSync` and
  **never consults the signal** — it completes regardless of abort (fast, sync).
- **Slash-command** completion is also synchronous (`fuzzyFilter`) — ignores signal.

**Implication for the handler design:** aborting the controller cannot be detected
by catching a thrown error. The superseded/timeout request simply **resolves** (to
`null` for `@`/fd, or to a normal result for sync path/slash). Therefore:
- The handler's `try/catch` around `provider.getSuggestions` will almost never see an
  `AbortError` thrown. It catches *provider-internal* throws only.
- After `await`, if `ac.signal.aborted` is true, the result is semantically "stale /
  timed out" → the clean client-facing value is `null` (matches provider behavior).
- A superseded request still resolves (null) → the dispatcher still sends a response
  for that `id` → **the client drops it by `id`** (PRD §5.5). This is the
  authority on supersession: server-side abort is a *resource optimization*
  (kills fd), client-side `id` check is the *correctness* mechanism.

## 2. Globals type-check under the extension tsconfig (empirically verified)

The extension `tsconfig.json` has **no `lib` field** and `"types": []`. With no
`lib`, TypeScript defaults to the target's lib set which **includes `lib.dom.d.ts`**
(unless lib is explicitly restricted). `lib.dom` provides:
`AbortController`, `AbortSignal`, `setTimeout`, `clearTimeout`, `console`, `Error`,
`Promise`, and `ReturnType<typeof setTimeout>` resolves to `number` (DOM).

Probe (mirroring the real `compilerOptions` exactly, no `lib`):
```ts
const ac = new AbortController();
const sig: AbortSignal = ac.signal;
const t = setTimeout(() => ac.abort(), 1500);
clearTimeout(t);
```
→ `tsc --noEmit` **exit 0** under `target ES2022 / module ESNext / moduleResolution
Bundler / strict / skipLibCheck / types:[]` (no `lib` field). And the REAL
`extension/tsconfig.json` baseline (post-S4) also compiles **exit 0**.

**Implication:** the handler needs **NO new runtime imports** for the timeout/abort
machinery — `setTimeout`/`clearTimeout`/`AbortController` are all globals via
`lib.dom`. The only new import is **type-only** from `./protocol.ts`
(`GetSuggestionsParams`, `GetSuggestionsResult`, `JsonRpcError`). Contrast: if the
tsconfig had `"lib": ["ES2022"]` (no DOM), these would all be `TS2304 Cannot find
name` and we'd need `import { setTimeout } from "node:timers"` — but it does NOT,
so globals are fine.

**node:* resolution** (for S5's `type Socket` reuse): the real baseline `tsc` passes,
confirming `import { createServer, type Server, type Socket } from "node:net"`
resolves under `moduleResolution: Bundler` + `types:[]` (S5's verified claim).
So `Socket` is in scope for the `ConnectionContext.socket` field once S5 lands.

## 3. How to inject a fake provider in tests (the captureProvider idiom)

`getProvider()` returns the module singleton `liveProvider`, assigned inside the
pass-through factory registered by `captureProvider(ctx)`:
```ts
export function captureProvider(ctx): void {
  ctx.ui.addAutocompleteProvider((current) => { liveProvider = current; return current; });
}
```
pi calls the factory synchronously with the live chain. In a test, a fake
`ctx.ui.addAutocompleteProvider` that **invokes** the factory with the desired fake
provider sets `liveProvider` to it (proven by `extension/tests/provider-capture.test.ts`:
```ts
captureProvider({ ui: { addAutocompleteProvider: (f) => f(provider) } } as ExtensionContext);
// getProvider() === provider
```
**There is NO `resetProvider` export** — to observe the "not captured" state, the
test must run BEFORE any install (node:test runs top-level `test(...)` sequentially
in definition order; module singleton is shared across tests in one process). Same
caveat provider-capture.test.ts already documents. Each test FILE is a separate
`node` process → `liveProvider` starts `undefined` per file.

## 4. JSON-RPC 2.0 + supersession authority (PRD is governing)

- **JSON-RPC 2.0 §5:** for every Request with an `id`, the Server MUST reply with
  exactly one Response (success OR error). Notifications (no `id`) get none.
- **PRD §5.5 (governing):** "The server creates an `AbortController` per
  `getSuggestions` request and aborts it if the client sends a newer request …
  The client should simply supersede stale requests: when a new keystroke arrives,
  increment `id`, ignore any response whose `id` is not the latest." → the server
  **does respond** to every request (incl. superseded), the **client drops stale
  by id**. No `-32800 RequestCancelled` error is needed (and none is in protocol.ts);
  a superseded request resolves `null` and that null response is harmlessly dropped.
- **PRD §6.7 (governing):** "Never throws from handlers (wrap in try/catch, return
  JSON-RPC `error`)" and "Never blocks pi's event loop synchronously (all
  `getSuggestions` are awaited)". → handler must **catch + return a structured
  result/error**, not throw. Drives the `HandlerOutcome<T>` discriminated return.
- **PRD §6.5 (reference skeleton):** `requireProvider(); const ac = new
  AbortController(); pendingAbort?.abort(); pendingAbort = ac; const t =
  setTimeout(()=>ac.abort(),1500); try { return await
  liveProvider!.getSuggestions(lines,cursorLine,cursorCol,{signal:ac.signal,
  force:!!force}); } finally { clearTimeout(t); }`. `pendingAbort` is **module-level**.
  The skeleton has NO `connCtx` param; the item contract ADDS `handleGetSuggestions(params,
  connCtx)` — thread `connCtx` for handler-contract uniformity / future per-connection
  use, dereference nothing from it today.

## 5. AbortController / setTimeout mechanics (no gotchas for this design)

- `AbortController.abort()` is **idempotent** — calling twice is a no-op
  (MDN: "If the signal's aborted flag is set, return.").
- `signal.aborted` is a stable boolean; reading it after the await is safe.
- `signal.addEventListener("abort", cb, {once:true})` auto-removes after firing;
  pi already uses `{once:true}`. If the listener is added AFTER abort, it still
  fires (on next microtask) — not relevant here (provider adds it pre-call).
- `const t = setTimeout(()=>ac.abort(), ms); … finally { clearTimeout(t); }` is safe:
  - If the await resolves BEFORE `ms`: `finally` clears `t` → no late abort. ✔
  - If `ms` elapses during the await: timer fires → `ac.abort()` → provider resolves
    null → `finally` runs `clearTimeout` on an already-fired timer (no-op). ✔
  - The timer is "ref'd" (keeps the event loop alive), but the `finally` ALWAYS
    clears it on every path, so there is NO leak / no dangling timer. (No `.unref()`
    needed; keeping it simple matches the PRD skeleton.)
- **Do NOT clear `pendingAbort` in `finally`.** A newer request may have already
  reassigned `pendingAbort` to ITS controller; clearing unconditionally would drop
  the newer request's controller. `pendingAbort` simply always points at the latest
  controller; older ones are GC'd once their owning handler call stack unwinds.

## 6. Single-client assumption → module-level supersession is correct

PRD §5.5 + §6.5 treat `pendingAbort` as a single module-level slot. This is valid
because the bridge serves **one editor per pi session** (the `$EDITOR` pi launches).
Multiple editor open/close cycles are *separate connections*, but only one is
completing at a time; cross-connection supersession (a new connection aborting an
old connection's in-flight request) is benign: the old request resolves null, the
old client (already closed) never reads it. No per-connection supersession map is
required for v1. (If a future multi-editor scenario arises, hoist `pendingAbort`
into `ConnectionContext` — out of scope here.)

## 7. Testability seams chosen (and why)

- **Provider** — injectable via `captureProvider({ui:{addAutocompleteProvider:f=>f(fake)}})`
  (existing idiom; no new seam). The fake MUST mirror the real provider's
  abort→null behavior: resolve `null` when `signal.aborted`, so the supersession
  test observes realistic resolution.
- **Timeout duration** — `export const __handlerDeps = { timeoutMs: 1500 }` (mutable
  plain object, mirrors S5's `__deps` philosophy; jiti-safe because it's a plain
  object's *property*, not `export let`). Tests lower it to ~10ms so the
  1500ms-timeout-aborts-runaway-provider path is fast and deterministic WITHOUT
  fake timers (node:test has none built in). Production is byte-identical
  (`__handlerDeps.timeoutMs` reads `1500`). Single new seam; production cost zero.

## 8. Validation commands (verified working in this repo)

- Type gate: `tsc --noEmit -p extension/tsconfig.json` → exit 0 (baseline passes).
- Test runner: `node --import <pi>/node_modules/jiti/lib/jiti-register.mjs
  extension/tests/handler-getsuggestions.test.ts` → expect `fail 0`.
  (jiti prints a benign DEP0205 deprecation on stderr — judge by exit code + pass/fail.)
- Regression: re-run provider-capture/mode-guard/protocol/bridge-lifecycle suites
  (each a separate process) → all `fail 0`.
- Indentation: TABS (match existing extension files + pi examples).
