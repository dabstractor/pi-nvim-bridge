# Research Notes — P1.M1.T2.S4 (Define JSON-RPC envelope, method, and bridge descriptor types)

> Work item **P1.M1.T2.S4** — "Define JSON-RPC envelope, method, and bridge
> descriptor types". This directory (`P1M1T2S4`) holds the PRP for the global
> subtask **P1.M1.T2.S4**.
>
> **Companion/primary research**: an extensive pre-existing analysis lives at
> `plan/001_c56962b4fa17/P1M1T2S1/research/notes.md` (that research itself notes:
> "P1.M1.T2.S4 in the global subtask sequence; dir = P1M1T2S1"). The P1M1T2S1
> notes fully specify every type's exact shape, the test strategy, and the
> validation commands — read them as the authoritative spec.
>
> **This file** records the DIRECT re-verification of the critical claims the PRP
> depends on, run against the **installed pi dist** on the current machine
> (2025-07-18), so the PRP's file:line citations are confirmed live and the
> validation commands are known-good.

---

## 0. Environment (verified live)

| Tool | Path / version | Note |
|---|---|---|
| `pi`  | `/home/dustin/.local/bin/pi` | global install |
| `tsc` | `/home/dustin/.local/bin/tsc` → **5.9.3** | type-check gate (Level 1) |
| `node`| `/usr/bin/node` → **v26.4.0** | runs node:test (Level 2) |
| jiti register hook | `/home/dustin/.local/lib/node_modules/@earendil-works/pi-coding-agent/node_modules/jiti/lib/jiti-register.mjs` | EXISTS — used by S2/S3 tests, reused by S4 |
| pi pkg | `@earendil-works/pi-coding-agent` (0.80.10) at `/home/dustin/.local/lib/node_modules/@earendil-works/pi-coding-agent` | type source |

> jiti v2.7.0 on Node 26 prints a harmless `DeprecationWarning: module.register()
> is deprecated` to STDERR — IGNORE it; judge tests by exit code + `pass`/`fail`.

---

## 1. pi-tui autocomplete types — re-verified (the wire-reuse core)

**`node_modules/@earendil-works/pi-tui/dist/index.d.ts:1`** re-exports all three:
```ts
export { type AutocompleteItem, type AutocompleteProvider, type AutocompleteSuggestions, CombinedAutocompleteProvider, type SlashCommand, } from "./autocomplete.ts";
```

**`autocomplete.d.ts`** field shapes (line numbers from grep):
- `AutocompleteItem` (L1): `{ value: string; label: string; description?: string }`
- `AutocompleteSuggestions` (L13): `{ items: AutocompleteItem[]; prefix: string }`
- `applyCompletion` return (L24-28): `{ lines: string[]; cursorLine: number; cursorCol: number }`
- `shouldTriggerFileCompletion?` (L29): `(lines, cursorLine, cursorCol) => boolean` — **optional** (`?`)
- `getSuggestions` (L17-23): `(lines, cursorLine, cursorCol, { signal, force? }) => Promise<AutocompleteSuggestions | null>`

**Implication for S4**: `protocol.ts` must `import type { AutocompleteItem, AutocompleteSuggestions }` for local use in `GetSuggestionsResult` / `ApplyCompletionParams`, AND `export { type AutocompleteItem, type AutocompleteSuggestions } from "@earendil-works/pi-tui"` for the re-export the item contract requires. Both are type-only → erased at runtime → zero deps. ✅ matches P1M1T2S1 §7.

---

## 2. ExtensionContext.cwd / .mode — re-verified (BridgeDescriptor field sources)

**`dist/core/extensions/types.d.ts:207-216`**:
```ts
export type ExtensionMode = "tui" | "rpc" | "json" | "print";
export interface ExtensionContext {
    ui: ExtensionUIContext;
    /** Current run mode. Use "tui" to guard terminal-only UI such as custom components. */
    mode: ExtensionMode;
    /** Whether dialog-capable UI is available (true in TUI and RPC modes) */
    hasUI: boolean;
    /** Current working directory */
    cwd: string;
    ...
}
```
→ `BridgeDescriptor.cwd: string` (from `ctx.cwd`), `BridgeDescriptor.pid: number` (from `process.pid`). ✅

---

## 3. JSONL framing contract — re-verified (the mirror S4's JSDoc cites for S7)

**`dist/modes/rpc/jsonl.js`** EXISTS. Key mechanics (from grep):
```
L1:  import { StringDecoder } from "node:string_decoder";
L6:   * U+2028 and U+2029. Clients must split records on `\n` only.
L8:  export function serializeJsonLine(value) { ... `${JSON.stringify(value)}\n` }
L14:  * This intentionally does not use Node readline. Readline splits on additional
L19:    const decoder = new StringDecoder("utf8");
L22:      onLine(line.endsWith("\r") ? line.slice(0, -1) : line);
L27:        const newlineIndex = buffer.indexOf("\n");
```
→ S4 is **TYPES-ONLY** (implements no framing); the module JSDoc cites this file so S7
(JSONL line reader) has the authoritative mirror reference. ✅ matches P1M1T2S1 §6.

---

## 4. tsconfig current state — re-verified (the one-line additive edit)

**`extension/tsconfig.json:21`** (current):
```jsonc
"include": ["pi-editor-bridge.ts", "tests/**/*.ts"]
```
- `paths` ALREADY maps BOTH `@earendil-works/pi-coding-agent` (→ `dist/index.d.ts`)
  AND `@earendil-works/pi-tui` (→ nested `node_modules/.../pi-tui/dist/index.d.ts`).
- **S4's only tsconfig change**: add `"protocol.ts"` to `include` →
  `["pi-editor-bridge.ts", "protocol.ts", "tests/**/*.ts"]`. No `paths` change needed. ✅
- Confirmed: `strict: true` is set; `noUnusedLocals`/`noUnusedParameters` are NOT set
  → the compile-time type-test consts (declared inside test bodies) will not trip
  unused-local errors. ✅

---

## 5. .gitignore — re-verified (no plan/PRD/task additions)

`.gitignore` ignores `node_modules/`, `dist/`, `.env*`, `.pi-subagents/`, etc. It does
NOT ignore `plan/`, `PRD.md`, or task files — and per the FORBIDDEN OPERATIONS rules,
S4 must never add them. ✅ No `.gitignore` change is part of S4.

---

## 6. Scope boundary (what S4 does NOT touch) — confirmed from codebase state

Current `extension/pi-editor-bridge.ts` (post-S3) is NOT modified by S4:
- it has the `if (ctx.mode !== "tui") return;` guard, the TUI-only `console.log`,
  `captureProvider(ctx)`, the `// TODO(M2)` / `// TODO(S16)` markers, and the no-op
  `session_shutdown`. S4 leaves ALL of that alone.
- Wiring `protocol.ts` into the extension (M2 socket server / S16 env write) is
  explicitly OUT OF SCOPE for S4 — S4 ships the **types** only.

No `CommandInfo` type exists anywhere in pi (`grep -rn "CommandInfo"` over `dist/`
+ nested pi-tui returns only `SlashCommandInfo`/`getCommands(): SlashCommandInfo[]`).
→ S4 must define a **lean bridge-local** `CommandInfo = { name; description?; argumentHint? }`
(mirrors the user-facing slice of `BuiltinSlashCommand`/`SlashCommand`, intentionally
EXCLUDING `sourceInfo`/`handler`/`getArgumentCompletions`). ✅ matches P1M1T2S1 §4.

---

## 7. Validation commands (verified working — identical to P1M1T2S1 §10)

```bash
# Level 1 — type-check (covers protocol.ts once added to include)
tsc --noEmit -p extension/tsconfig.json          # expect exit 0, no output

# Level 2 — node:test via jiti (same register hook S2/S3 use)
JITI_REG=/home/dustin/.local/lib/node_modules/@earendil-works/pi-coding-agent/node_modules/jiti/lib/jiti-register.mjs
node --import "$JITI_REG" extension/tests/protocol.test.ts   # expect exit 0, fail 0

# Level 3 — regression: pi-editor-bridge.ts still loads cleanly (protocol.ts
#   is NOT wired in yet, so this proves S4 didn't break the entry point; the
#   S3 guard suppresses the startup log in --print mode)
pi --no-extensions -e ./extension/pi-editor-bridge.ts --print "ok" 2>&1 | \
  grep -iE "error|cannot|fail|throw|TypeError" && echo FAIL || echo PASS
```

---

## 8. Design decisions carried into the PRP (from P1M1T2S1 §1-5, confirmed)

1. **`jsonrpc: "2.0"`** as a string **literal** (compile-time version check), not `string`.
2. **`id: string`** only (PRD §5 restricts to string; not `string|number|null`).
3. **`error: { code: number; message: string }`** — named `JsonRpcError`, NO `data` field.
4. **`params?: unknown` / `result?: unknown`** on raw envelopes → `unknown` forces narrowing.
5. **`ok: true`** literal on hello/ping/bye success results (compile-time invariant).
6. **Empty `{}` params/results** → `Record<string, never>` (the correct TS "empty object").
7. **`transport: "unix"`** literal; JSDoc notes the discriminated-union TCP extension point.
8. **`serverVersion: string`** is the canonical descriptor field name (item contract + §6.4
   reference skeleton hardcode `"0.1.0"`); PRD §4's `"version":"0.0.1"` is a doc
   inconsistency — S4 uses `serverVersion` per the component spec + item contract.
9. **Two-layer types**: raw parse envelopes (contract a/b/c) + mapped/narrowed dispatch
   layer (`BridgeMethod`, `BridgeParamsMap`, `BridgeResultMap`, `BridgeParams<M>`,
   `BridgeResult<M>`, `TypedRequest/Response/Notification`) for OUTPUT #4 "full type
   safety". `commandsChanged` is OMITTED from `BridgeResultMap` (no result) and lives
   only in `BridgeParamsMap` + the `TypedNotification` path.
10. **Type-only module**: no runtime consts/enums (an error-code map is S9/S15's job).
