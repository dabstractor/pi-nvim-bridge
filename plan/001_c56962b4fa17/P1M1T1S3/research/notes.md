# P1.M1.T1.S3 — Research Notes (TUI mode guard)

Task: add `if (ctx.mode !== "tui") return;` at the top of the `session_start`
handler so the bridge no-ops entirely in rpc/json/print modes. 0.5 pts.

All claims below re-verified against the INSTALLED dist at
`/home/dustin/.local/lib/node_modules/@earendil-works/pi-coding-agent` (v0.80.10).

## 1. The type surface — `ctx.mode`

`dist/core/extensions/types.d.ts:207`:
```ts
export type ExtensionMode = "tui" | "rpc" | "json" | "print";
```
`dist/core/extensions/types.d.ts:211-212` (inside `ExtensionContext`):
```ts
/** Current run mode. Use "tui" to guard terminal-only UI such as custom components. */
mode: ExtensionMode;
```
=> `ctx.mode` is exactly `"tui" | "rpc" | "json" | "print"`. The pi type system
itself documents guarding with `=== "tui"`. The guard `ctx.mode !== "tui"`
catches rpc/json/print in one comparison. No enum to import; it's a string-
literal union so `!== "tui"` is exhaustive and type-safe.

## 2. WHY the guard is needed — two TUI-only mechanisms

### 2a. `addAutocompleteProvider` is a NO-OP in RPC mode
`dist/modes/rpc/rpc-mode.js:193-195` (source: `modes/rpc/rpc-mode.ts:271-273`):
```js
addAutocompleteProvider() {
    // Autocomplete provider composition is not supported in RPC mode
},
```
So the S2 `captureProvider(ctx)` call (which calls
`ctx.ui.addAutocompleteProvider(...)`) is a SILENT NO-OP in RPC mode — it never
fires the factory, `liveProvider` stays `undefined`, and `getProvider()` would
throw later. Capture only actually works in TUI mode
(`dist/modes/interactive/interactive-mode.js`: push + setupAutocompleteProvider).
print/json modes have no `ExtensionUIContext` autocomplete impl at all.

### 2b. `openExternalEditor` is TUI-only
`grep -rl 'openExternalEditor\|app.editor.external' dist/modes` returns ONLY:
- `dist/modes/interactive/components/extension-editor.js` (the `ExtensionEditorComponent`)
- `dist/modes/interactive/interactive-mode.js` (main editor `app.editor.external` action)

There is NO `dist/modes/print/` and NO `dist/modes/json/` directory at all — those
modes are pure code paths, not UI-bearing. The external $EDITOR is therefore
launched EXCLUSIVELY in interactive (TUI) mode. The bridge's entire purpose
(serve completions to the external $EDITOR) is moot in rpc/json/print.

CONCLUSION: in non-TUI modes the bridge would (a) capture nothing useful, (b)
have no editor to serve. The guard at the top of `session_start` is correct and
forward-looking: all future session_start work (M2 socket `startBridge`, S16 env
advertisement, S17 commandsChanged) lands BELOW the guard and is auto-protected.

## 3. The baseline file S3 starts from (S2 applied — treated as a contract)

S2 (implemented in parallel) leaves `extension/pi-editor-bridge.ts` as
(superset of S1):
```ts
import type { AutocompleteProvider } from "@earendil-works/pi-tui";
import type { ExtensionAPI, ExtensionContext, SessionStartEvent, SessionShutdownEvent } from "@earendil-works/pi-coding-agent";

let liveProvider: AutocompleteProvider | undefined;

export function captureProvider(ctx: ExtensionContext): void { /* pass-through factory */ }
export function getProvider(): AutocompleteProvider { /* throws if !liveProvider */ }

export default function (pi: ExtensionAPI): void {
    pi.on("session_start", (event: SessionStartEvent, ctx: ExtensionContext) => {
        console.log(`pi-editor-bridge: session_start (reason=${event.reason}, mode=${ctx.mode})`);
        // TODO(S3): guard with `if (ctx.mode !== "tui") return;` before capturing.
        captureProvider(ctx);
        // TODO(M2): startBridge(ctx, ctx.cwd);   TODO(S16): advertise via process.env.PI_NVIM_BRIDGE
    });
    pi.on("session_shutdown", (_event: SessionShutdownEvent) => { /* no-op placeholder */ });
}
```
S2 also created `extension/tests/provider-capture.test.ts` and added the pi-tui
`paths` entry to `extension/tsconfig.json`.

## 4. The guard placement decision (resolves S2-TODO vs S3-contract tension)

- S2's inline TODO places the guard hint RIGHT BEFORE `captureProvider` (i.e.
  BELOW the startup `console.log`).
- S3's item CONTRACT says: "At the TOP of the session_start handler, add
  `if (ctx.mode !== "tui") return;` to short-circuit ALL bridge logic. This
  prevents registering a useless provider capture factory and starting a socket
  server..."

The contract ("top" + "ALL bridge logic") is authoritative for S3. => The guard
goes at the VERY TOP of the handler body (before the `console.log`). The startup
log therefore becomes TUI-only (it does not fire in --print/--rpc/--json).

VALIDATION IMPACT (must be reflected in S3's gates): S1/S2's Level-3 gate greps
`--print` output for the startup log line. After S3 that line is suppressed in
print mode (guard short-circuits). S3 MUST update Level 3 to assert exit 0 +
NO error lines (proves clean load) rather than grep for the log. The guard's
actual behavior (skip capture in non-TUI) is proven by the unit test instead.

## 5. Test approach (reuses S2's node:test + jiti pattern)

The guard lives INSIDE the `session_start` handler, which is only reachable via
the default-export factory → `pi.on("session_start", h)`. So the test:
1. Invokes `default(pi)` with a capturing fake `pi` whose `.on(event, h)` saves
   the session_start handler.
2. Calls the saved handler with `ctx.mode` = "rpc", "json", "print" and asserts
   `ctx.ui.addAutocompleteProvider` is NOT called (no-op).
3. Calls it with `ctx.mode = "tui"` and asserts `addAutocompleteProvider` IS
   called (happy path through the handler).

This is a different cut than S2's direct `captureProvider`/`getProvider` unit
test — it exercises factory → registration → handler invocation. Isolated
process (separate `node` run), so the `liveProvider` singleton never crosses
into provider-capture.test.ts. TUI-mode case sets `liveProvider` but this file
makes no `getProvider()` assertion, so no contamination.

## 6. Toolchain confirmation
- `pi` CLI: `/home/dustin/.local/bin/pi`, v0.80.10. `pi --no-extensions -e
  ./extension/pi-editor-bridge.ts --print "ok"` works for the runtime gate.
- jiti v2.7.0 register hook:
  `/home/dustin/.local/lib/node_modules/@earendil-works/pi-coding-agent/node_modules/jiti/lib/jiti-register.mjs`
  (present). node:test is built into Node — zero deps.
- `tsc --noEmit -p extension/tsconfig.json` resolves all types via the S2 paths
  mapping (pi-coding-agent + nested pi-tui). No new paths entry needed for S3.

## 7. Out of scope (guard against scope creep)
- No socket (M2/S5/S6), no env write (S16), no commandsChanged (S17), no
  packaging (S18). Those land BELOW the guard in later tasks.
- Do NOT add guards to `session_shutdown` — shutdown must stay callable in all
  modes (it's a no-op now; later S6 stopBridge is idempotent + safe to call).
- Do NOT change `captureProvider`/`getProvider` (S2 owns them).
- Do NOT touch tsconfig paths (S2 owns them).
