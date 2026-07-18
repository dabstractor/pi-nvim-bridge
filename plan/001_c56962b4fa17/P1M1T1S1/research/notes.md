# Research Notes — P1.M1.T1.S1 (Extension default factory + lifecycle)

Scope: NARROW foundational skeleton. Create `extension/pi-editor-bridge.ts`
with a default-export factory that registers `session_start` (logs) and
`session_shutdown` (no-op) handlers + a JSDoc header. **Nothing else.** Provider
capture = S2; TUI guard = S3; socket server = M2; env var = S16;
commandsChanged = S17; packaging = S18.

## Verified type surface (from installed dist)

Package: `@earendil-works/pi-coding-agent@0.80.10` at
`/home/dustin/.local/lib/node_modules/@earendil-works/pi-coding-agent`

`dist/core/extensions/types.d.ts`:
- L835: `export type ExtensionHandler<E, R = undefined> = (event: E, ctx: ExtensionContext) => Promise<R | void> | R | void;`
- L842: `on(event: "session_start", handler: ExtensionHandler<SessionStartEvent>): void;`
- L848: `on(event: "session_shutdown", handler: ExtensionHandler<SessionShutdownEvent>): void;`
- L405-411: `SessionStartEvent { type: "session_start"; reason: "startup"|"reload"|"new"|"resume"|"fork"; previousSessionFile?: string; }`
- L457-462: `SessionShutdownEvent { type: "session_shutdown"; reason: "quit"|"reload"|"new"|"resume"|"fork"; targetSessionFile?: string; }`
- L207: `ExtensionMode = "tui" | "rpc" | "json" | "print";`
- L208-216: `ExtensionContext { ui: ExtensionUIContext; mode: ExtensionMode; hasUI: boolean; cwd: string; ... }`

`dist/index.d.ts` re-exports all of: `ExtensionAPI, ExtensionContext,
ExtensionHandler, ExtensionMode, SessionStartEvent, SessionShutdownEvent`
(confirmed via grep). So a single import line suffices:
`import type { ExtensionAPI, ExtensionContext, SessionStartEvent, SessionShutdownEvent } from "@earendil-works/pi-coding-agent";`

## Verified: import is type-only & erased at runtime
`import type { ... }` produces zero runtime require/import → the file loads via
jiti with NO node_modules present. Only the `pi.on(...)` calls execute at
runtime. Confirms PRD §6.7 "no npm runtime dependencies".

## Verified: factory contract
`(pi: ExtensionAPI) => void | Promise<void>`. S1 only registers handlers
(`pi.on(...)`), so NO async needed and NO background resources started in
factory body — satisfies the pi docs "do not start background resources from
the factory" rule trivially (loader.ts:485-498 `await factory(api)`).

## Verified: canonical reference patterns
- `/home/dustin/.local/lib/node_modules/@earendil-works/pi-coding-agent/examples/extensions/auto-commit-on-exit.ts`
  → `session_shutdown` handler; default `export default function (pi: ExtensionAPI) {...}`; uses **tabs** for indentation.
- `.../examples/extensions/github-issue-autocomplete.ts`
  → `pi.on("session_start", async (_event, ctx) => {...})`; default export
  `export default function (pi: ExtensionAPI): void {...}`; uses tabs.
- Both: `import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";`
- Convention: name unused params with leading underscore (`_event`, `_e`).

## Verified: VALIDATION COMMAND #1 — real pi load (DEFINITIVE)
`pi` is at `/home/dustin/.local/bin/pi` v0.80.10. Flags confirmed via `pi --help`:
`--no-extensions` (`-ne`), `--extension` (`-e <path>`), `--print` (`-p`), `--mode`.
Probe `/tmp/pi-ext-probe/probe.ts` loaded via:
```
pi --no-extensions -e /tmp/pi-ext-probe/probe.ts --print "say ok"
```
Result (2>&1): `[PROBE] session_start fired reason=startup mode=print` then
`[PROBE] session_shutdown fired reason=quit`. CONCLUSION: `--print` mode fires
BOTH `session_start` (reason=startup) and `session_shutdown` (reason=quit), and
`console.error`/`console.log` output is visible on stderr/stdout. This is the
definitive "pi can load without errors" gate. (ctx.mode is "print" in this mode;
TUI guard logic comes in S3.)

## Verified: VALIDATION COMMAND #2 — tsc type check (paths mapping)
`tsc` 5.9.3 available. NODE_PATH does NOT help tsc resolution (require.resolve
probe failed). WORKING approach = a dev-only `tsconfig.json` with `paths`
mapping to the global dist `.d.ts`:
```jsonc
{
  "compilerOptions": {
    "target": "ES2022","module":"ESNext","moduleResolution":"Bundler",
    "strict": true,"noEmit": true,"skipLibCheck": true,"types": [],
    "baseUrl": ".",
    "paths": {
      "@earendil-works/pi-coding-agent": ["/home/dustin/.local/lib/node_modules/@earendil-works/pi-coding-agent/dist/index.d.ts"]
    }
  },
  "include": ["pi-editor-bridge.ts"]
}
```
Probe: `tsc --noEmit -p tsconfig.json` → exit 0. NOTE: a dev tsconfig does NOT
conflict with S18 (package.json + README packaging); it is separate dev
tooling. If team prefers not to add a tsconfig yet, the pi-load gate (#1) alone
suffices for S1 since types are erased at runtime.

## JSDoc header (Mode A) — required fields
Purpose / env var name (`PI_EDITOR_BRIDGE`) / socket transport (Unix domain
socket, JSONL framing). Mark file as lifecycle-skeleton stage (S1).

## Gotchas
- Indentation = TABS (match examples). Use `import type` (not `import`).
- Handler params: work item requires explicit `(event: SessionStartEvent, ctx:
  ExtensionContext)`. TS infers from overloaded `on()` but explicit annotation
  satisfies the contract & aids future edits.
- `console.log` in interactive TUI mode can corrupt terminal rendering; pi idiom
  is `ctx.ui.notify(msg, "info")` (used in examples). For the S1 skeleton,
  `console.log` is acceptable (validated in print mode); flag the TUI caveat.
- session_shutdown handler is a no-op now; future S6 (`stopBridge`)/S15 will
  add close/unlink/clear-env. Keep a TODO comment referencing that.
