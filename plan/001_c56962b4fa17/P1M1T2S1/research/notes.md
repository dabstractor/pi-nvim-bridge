# Research Notes — P1.M1.T2.S1 (Define JSON-RPC envelope, method, and bridge descriptor types)

> Work item: **"Define JSON-RPC envelope, method, and bridge descriptor types"**
> (a.k.a. P1.M1.T2.S4 in the global subtask sequence; dir = `P1M1T2S1`).
> Every claim below was verified by reading the **installed pi dist** at
> `/home/dustin/.local/lib/node_modules/@earendil-works/pi-coding-agent/dist`
> (and the nested pi-tui). No web research was needed — the contract is a
> pi-internal type module fully specified by PRD §5 + the item contract.

---

## 0. Scope & baseline (what exists when S1 begins)

S1 runs in PARALLEL with P1.M1.T1.S3 (TUI mode guard). The post-S3 baseline of
`extension/pi-editor-bridge.ts` is defined by the S3 PRP
(`plan/001_c56962b4fa17/P1M1T1S3/PRP.md`):

- default-export factory registering `session_start` (with `if (ctx.mode !== "tui") return;`
  guard at the very top, then `console.log`, then `captureProvider(ctx)`) and
  `session_shutdown` (no-op).
- named exports `captureProvider(ctx)` + `getProvider()`; module-level `liveProvider`.
- imports (ALL type-only): `AutocompleteProvider` from `@earendil-works/pi-tui`;
  `ExtensionAPI, ExtensionContext, SessionStartEvent, SessionShutdownEvent` from
  `@earendil-works/pi-coding-agent`.
- `extension/tsconfig.json` already maps BOTH
  `@earendil-works/pi-coding-agent` (→ `dist/index.d.ts`) AND
  `@earendil-works/pi-tui` (→ nested `node_modules/.../pi-tui/dist/index.d.ts`).
  `include` currently = `["pi-editor-bridge.ts", "tests/**/*.ts"]`.
- Tests: `extension/tests/provider-capture.test.ts` (S2) +
  `extension/tests/mode-guard.test.ts` (S3). Both run via
  `node --import <jiti-register.mjs> <file>` with `node:test`.

**S1 does NOT touch `pi-editor-bridge.ts`.** It only:
1. CREATEs `extension/protocol.ts` (the type module).
2. adds `"protocol.ts"` to the tsconfig `include` (one-line, additive — safe vs. S3).
3. CREATEs `extension/tests/protocol.test.ts`.

Wiring `protocol.ts` into `pi-editor-bridge.ts` (e.g. the M2 socket server using
these types) is OUT OF SCOPE — that's M2.T3/T4 and S16.

---

## 1. The three raw JSON-RPC envelopes — exact shapes (item contract (a)(b)(c))

The item contract pins the raw "parsed-line" shapes EXACTLY. These are what a
JSONL line parses into BEFORE method-based narrowing:

```ts
JsonRpcRequest     = { jsonrpc: "2.0"; id: string; method: string; params?: unknown }
JsonRpcResponse    = { jsonrpc: "2.0"; id: string; result?: unknown }
                     | { jsonrpc: "2.0"; id: string; error: { code: number; message: string } }
JsonRpcNotification= { jsonrpc: "2.0"; method: string; params?: unknown }
```

- `jsonrpc` is the string LITERAL `"2.0"` (not `string`) — matches PRD §5.3 wire
  examples `{"jsonrpc":"2.0",...}` verbatim and gives a compile-time check that
  the version field is correct.
- `id` is `string` (PRD §5: "JSON-RPC 2.0 envelopes with string `id`"). NOT
  `string | number | null` (JSON-RPC permits number/null, but pi-editor-bridge
  restricts to string per PRD §5 — keep it narrow).
- error is `{ code: number; message: string }` — NO `data` field (PRD §5.3 error
  examples and the item contract both omit `data`). Keep minimal.
- `params?: unknown` on request/notification (absent-or-anything); `result?: unknown`
  on success response. Use `unknown` (not `any`) so consumers MUST narrow.

**JSON-RPC 2.0 spec error codes** (for JSDoc; PRD §5.3 uses `-32600` "bad token"):
- `-32700` Parse error, `-32600` Invalid Request, `-32601` Method not found,
  `-32602` Invalid params, `-32603` Internal error. Spec:
  https://www.jsonrpc.org/specification#error_object
- S1 is TYPES-ONLY: we do NOT export a runtime const of codes (S9/S15 can add
  one). JSDoc just documents the codes + the -32600 handshake convention.

---

## 2. BridgeDescriptor — exact fields (item contract (d))

```ts
BridgeDescriptor = {
  transport: "unix";   // v1 literal; PRD §5.1 TCP variant is future
  path: string;        // socketPath, e.g. ${tmpdir}/pi-editor-bridge-${uuid}.sock
  token: string;       // randomUUID-derived; the REAL auth boundary (PRD §5.1, §12)
  pid: number;         // process.pid of the pi process
  cwd: string;         // ctx.cwd (ExtensionContext.cwd: string — verified types.d.ts:216)
  fdAvailable: boolean;// whether the `fd` tool resolved (research-pi-autocomplete §1: ensureTool("fd"))
  serverVersion: string;// bridge version string (PRD §6.4 reference skeleton hardcodes "0.1.0")
}
```

Verified sources for each field's RUNTIME value (the TYPE just declares the
field; M2/S16 compute the value):
- `ctx.cwd` → `ExtensionContext.cwd: string` (`types.d.ts:216`).
- `process.pid` → Node global.
- `fdAvailable` → `ensureTool("fd")` resolves `fdPath`
  (`research-pi-autocomplete.md` §1: "fdPath comes from ensureTool('fd')").
- `serverVersion` → PRD §6.4 reference skeleton: `serverVersion: "0.1.0"`.
  pi-coding-agent also exports `VERSION` (`config.d.ts:69: export declare const
  VERSION: string` = `pkg.version || "0.0.0"`); either is a valid source. The
  type field is just `string`.
- `transport: "unix"` LITERAL — PRD §5.1 names a future TCP variant
  (`"transport":"tcp","host":"127.0.0.1","port":…`). For v1 the descriptor is
  unix-only; JSDoc notes the discriminated-union extension point for TCP.

`BridgeDescriptor` is JSON-serialized to `process.env.PI_NVIM_BRIDGE` (S16) and
`vim.json.decode`d by the Lua side (PRD §7.1). So it MUST be a plain JSON object
(no functions, no `undefined`-valued optional fields). All fields are required
(strings/number/boolean) — exactly as the contract enumerates.

---

## 3. Per-method params/result types — exact match to PRD §5.4 table (item contract (e))

PRD §5.4 table, transcribed with exact field names/types. "Direction" S→C
notification = no `id`, no result.

| Method | Dir | Params | Result |
|---|---|---|---|
| `hello` | C→S | `{token, client?, clientVersion?}` | `{ok, serverVersion, cwd, fdAvailable}` |
| `ping` | C→S | `{}` | `{ok, pid, cwd, fdAvailable, serverVersion}` |
| `getSuggestions` | C→S | `{lines:string[], cursorLine:int, cursorCol:int, force?:bool}` | `AutocompleteSuggestions \| null` |
| `applyCompletion` | C→S | `{lines, cursorLine, cursorCol, item, prefix}` | `{lines, cursorLine, cursorCol}` |
| `shouldTriggerFileCompletion` | C→S | `{lines, cursorLine, cursorCol}` | `bool` |
| `getCommands` | C→S | `{}` | `{commands: CommandInfo[]}` *(optional)* |
| `commandsChanged` | S→C notif | `{}` | — |
| `bye` | C→S | `{}` | `{ok:true}` |

Derived named interfaces (S1 ships these):

```ts
HelloParams        = { token: string; client?: string; clientVersion?: string }
HelloResult        = { ok: true; serverVersion: string; cwd: string; fdAvailable: boolean }

PingParams         = Record<string, never>           // {} — empty object
PingResult         = { ok: true; pid: number; cwd: string; fdAvailable: boolean; serverVersion: string }

GetSuggestionsParams   = { lines: string[]; cursorLine: number; cursorCol: number; force?: boolean }
GetSuggestionsResult   = AutocompleteSuggestions | null   // re-exported from pi-tui

ApplyCompletionParams  = { lines: string[]; cursorLine: number; cursorCol: number; item: AutocompleteItem; prefix: string }
ApplyCompletionResult  = { lines: string[]; cursorLine: number; cursorCol: number }

ShouldTriggerFileCompletionParams  = { lines: string[]; cursorLine: number; cursorCol: number }
ShouldTriggerFileCompletionResult  = boolean

GetCommandsParams  = Record<string, never>
GetCommandsResult  = { commands: CommandInfo[] }

CommandsChangedParams = Record<string, never>   // notification; NO result type

ByeParams          = Record<string, never>
ByeResult          = { ok: true }
```

Decisions / gotchas:
- **`ok` is the literal `true`** (not `boolean`) on hello/ping/bye success
  results — the PRD wire examples always show `"ok":true`. Typing it as the
  literal `true` makes "ok must be true on success" a compile-time invariant.
- **`cursorLine`/`cursorCol` are `number`.** Semantics: `cursorLine` 0-indexed
  line; `cursorCol` 0-indexed **UTF-16** code-unit offset (PRD §8 Coordinate &
  Encoding Contract; `external_deps.md` §1.1). The TYPE is just `number`; the
  UTF-16 semantics belong to the Lua `coords.lua` (S28/S29) — documented in JSDoc
  so the wire contract is unambiguous.
- **Empty params/result `{}`** → `Record<string, never>` (the correct TS "empty
  object" type; `{}` means "any non-nullish" and is unsafe). An object literal
  `{}` is assignable to `Record<string, never>`. This rejects stray keys at the
  type level.
- **`force?: boolean`** is optional (PRD `force?`).
- **`AutocompleteItem`/`AutocompleteSuggestions`** come from `@earendil-works/pi-tui`
  and are re-exported by THIS module (item contract: "Re-export ... for
  convenience"). Verified pi-tui `index.d.ts:1` exports both as types.

---

## 4. CommandInfo — LOCAL type (does NOT exist in pi)

**Verified absent:** `grep -rn "CommandInfo"` over `dist/` + nested pi-tui (minus
`.map` files) returns ONLY `SlashCommandInfo`, `getCommands(): SlashCommandInfo[]`
(types.d.ts:923), and `GetCommandsHandler = () => SlashCommandInfo[]`
(types.d.ts:1107). There is NO `CommandInfo`.

Closest pi-internal types (all carry internal-only fields unsuitable for the wire):
- `SlashCommandInfo` (`slash-commands.d.ts:3`):
  `{ name; description?; source: SlashCommandSource; sourceInfo: SourceInfo }` —
  `sourceInfo` leaks internal file paths; do NOT ship over the socket.
- `RegisteredCommand` (`types.d.ts:824`): includes `handler` + `getArgumentCompletions`.
- `BuiltinSlashCommand` (`slash-commands.d.ts`): `{ name; description; argumentHint? }`.

**Decision:** define a LEAN bridge-local `CommandInfo` for the OPTIONAL
`getCommands` "richer docs menus" feature (PRD §5.4 marks it *(optional)*):
```ts
CommandInfo = { name: string; description?: string; argumentHint?: string }
```
This mirrors the user-facing slice of `BuiltinSlashCommand` + `SlashCommand`
(pi-tui `autocomplete.d.ts`: `name; description?; argumentHint?`), intentionally
EXCLUDING `sourceInfo` (internal paths) and `handler`/`getArgumentCompletions`
(callables). JSDoc must state: bridge-local, NOT re-exported from pi, intended
for the optional getCommands docs-menu; the S14 handler maps pi's
`SlashCommandInfo[]`/`BuiltinSlashCommand[]` DOWN to this wire shape.

---

## 5. Method-name union + mapped types (the "full type safety" layer)

Item contract (e): "Method name union type and params/result types for each
method." The raw envelopes (§1) have `method: string` / `params?: unknown`. To
deliver OUTPUT #4 ("provides full type safety for the IPC layer"), add a narrow
dispatch layer ON TOP of the raw envelopes via mapped types:

```ts
// All 8 method names
BridgeMethod = "hello" | "ping" | "getSuggestions" | "applyCompletion"
             | "shouldTriggerFileCompletion" | "getCommands" | "commandsChanged" | "bye"

// C→S requests carry an id and expect a result
RequestMethod = Exclude<BridgeMethod, "commandsChanged">
// S→C notifications carry no id, no result
NotificationMethod = "commandsChanged"

// Maps (interface, so consumers can override/extend if needed)
BridgeParamsMap = { hello: HelloParams; ping: PingParams; getSuggestions: GetSuggestionsParams; ... }
BridgeResultMap = { hello: HelloResult; ping: PingResult; getSuggestions: GetSuggestionsResult; ... }
                   // commandsChanged intentionally OMITTED (no result)

BridgeParams<M extends BridgeMethod> = BridgeParamsMap[M]
BridgeResult<M extends RequestMethod> = BridgeResultMap[M]

// Narrowed envelopes (the typed dispatch layer)
TypedRequest<M extends RequestMethod = RequestMethod>      = { jsonrpc:"2.0"; id:string; method:M; params:BridgeParams<M> }
TypedResponse<M extends RequestMethod = RequestMethod>     = { jsonrpc:"2.0"; id:string; result:BridgeResult<M> }
                                                            | { jsonrpc:"2.0"; id:string; error:JsonRpcError }
TypedNotification<M extends NotificationMethod = NotificationMethod> = { jsonrpc:"2.0"; method:M; params:BridgeParams<M> }
```

This two-layer design (raw parse shape + narrowed dispatch shape) is the standard
typed-JSON-RPC pattern and is exactly what M2's `onConnection` dispatcher
(S8) and the handshake (S9) will consume. It is NOT over-engineering: the raw
envelopes are mandated by the contract (a)(b)(c); the mapped types are mandated
by (e) + OUTPUT #4.

`commandsChanged` is OMITTED from `BridgeResultMap` (it has no result) and lives
only in `BridgeParamsMap` + the `TypedNotification` path. This keeps the result
map honest.

---

## 6. JSONL framing (the MIRROR reference — NOT implemented in S1, but cited)

PRD §5.2 says "Mirror pi RPC's framing rules." Verified pi's own framing impl:
`dist/modes/rpc/jsonl.js`:
- `serializeJsonLine(value)` → `${JSON.stringify(value)}\n` (LF-only).
- `attachJsonlLineReader(stream, onLine)`: buffers with `StringDecoder("utf8")`,
  splits on `\n` ONLY (`buffer.indexOf("\n")`), strips a single trailing `\r`
  (`line.endsWith("\r") ? line.slice(0,-1) : line`), explicitly does NOT use
  Node `readline` (which splits on U+2028/U+2029 — invalid inside JSON strings).

S1 is TYPES-ONLY and implements NO framing. But the module JSDoc should cite this
so S7 (JSONL line reader) has the authoritative mirror reference. (S7 implements
the reader; S1 just documents the contract.)

---

## 7. Re-export mechanics + tsconfig

- pi-tui `index.d.ts:1` exports `type AutocompleteItem, type AutocompleteProvider,
  type AutocompleteSuggestions, CombinedAutocompleteProvider, type SlashCommand`.
  → S1 re-exports `type AutocompleteItem` + `type AutocompleteSuggestions`:
  `export { type AutocompleteItem, type AutocompleteSuggestions } from "@earendil-works/pi-tui";`
  (type-only re-export; erased at runtime → zero deps, matches S2's discipline).
- `@earendil-works/pi-tui` resolves via the EXISTING tsconfig `paths` entry
  (added by S2) → nested `node_modules/.../pi-tui/dist/index.d.ts`. **No tsconfig
  `paths` change needed** for S1; only the `include` array must gain `"protocol.ts"`.
- Because ALL exports in `protocol.ts` are types (interfaces/type aliases + a
  type-only re-export), the module has NO runtime exports. At runtime (jiti), the
  module namespace is effectively empty. The runtime test must assert "import
  doesn't throw", NOT "export X is defined".

---

## 8. Test strategy (node:test + jiti, matching S2/S3)

A pure-types module has little runtime behavior, so the test is split:

1. **Runtime load test** — `await import("../protocol.ts")` resolves via jiti
   WITHOUT throwing and WITHOUT needing node_modules resolution at the repo top
   level (proves all imports are `import type` / type-only re-exports). This is
   the critical runtime invariant (PRD §6.7: extension loads with zero deps).
2. **Compile-time type tests** — a set of `const x: T = {...}` / `satisfies`
   declarations exercising EVERY envelope + every per-method param/result type +
   the mapped types (`BridgeParams<"getSuggestions">`, etc.). These are validated
   by `tsc --noEmit -p extension/tsconfig.json` (Level 1 gate). A few also feed
   `assert.equal` on field values so there's runtime signal too.

This mirrors S2/S3's `node:test` + jiti pattern (same JITI_REG path) and gives
both a runtime Level-2 gate (load) and a compile-time Level-1 gate (types).

---

## 9. Conventions to follow (from S1/S2/S3 baseline)

- **TABS** for indentation (match pi-editor-bridge.ts + pi's examples).
- **`import type`** for every type import; type-only `export { type X }` re-exports.
- **JSDoc (Mode A)** on each exported type explaining its wire-format role (item
  contract DOCS requirement).
- **No runtime values** — protocol.ts is types-only (no const objects, no enums).
  A const error-code map would be useful but is S9/S15's job; keep S1 type-only.
- **File placement:** `extension/protocol.ts` (per item contract) +
  `extension/tests/protocol.test.ts`. tsconfig `include` += `"protocol.ts"`.
- **Naming:** interfaces PascalCase; method names as string-literal union members
  match PRD §5.4 exactly (`shouldTriggerFileCompletion`, `getCommands`, etc.).

---

## 10. Validation commands (verified against this repo)

```bash
# Level 1 — type-check (includes protocol.ts once added to include)
tsc --noEmit -p extension/tsconfig.json          # expect exit 0, no output

# Level 2 — node:test via jiti (same register hook S2/S3 use)
JITI_REG=/home/dustin/.local/lib/node_modules/@earendil-works/pi-coding-agent/node_modules/jiti/lib/jiti-register.mjs
node --import "$JITI_REG" extension/tests/protocol.test.ts   # expect exit 0, fail 0

# Level 3 — pi still loads pi-editor-bridge.ts cleanly (protocol.ts not wired yet,
#   so this just confirms S1 didn't regress the extension entry point)
pi --no-extensions -e ./extension/pi-editor-bridge.ts --print "ok" 2>&1 | \
  grep -iE "error|cannot|fail|throw|TypeError" && echo FAIL || echo PASS
```

Note: jiti v2.7.0 on Node 26 prints a harmless DeprecationWarning
("module.register() is deprecated") to STDERR — ignore; judge by exit code + the
`pass`/`fail` summary lines (per S2/S3 PRPs).
