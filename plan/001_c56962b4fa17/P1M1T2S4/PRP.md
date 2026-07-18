---
name: "P1.M1.T2.S4 — Define JSON-RPC envelope, method, and bridge descriptor types"
description: |
  Create `extension/protocol.ts`: a **type-only** TypeScript module that encodes the
  entire JSON-RPC 2.0 wire contract between the `pi-editor-bridge` extension and the
  `pi-editor.nvim` plugin. It exports (a) the three raw JSON-RPC parse envelopes
  (Request/Response/Notification) with `jsonrpc:"2.0"` literal + `id:string`; (b) the
  `BridgeDescriptor` type (the `process.env.PI_EDITOR_BRIDGE` JSON shape, unix-only);
  (c) per-method params/result interfaces matching PRD §5.4 **exactly**, including a
  lean bridge-local `CommandInfo` for the optional `getCommands` docs menu; and (d) a
  mapped/narrowed dispatch layer (`BridgeMethod`, `BridgeParamsMap`, `BridgeResultMap`,
  `BridgeParams<M>`, `BridgeResult<M>`, `TypedRequest/Response/Notification`) that
  delivers "full type safety for the IPC layer" (item OUTPUT #4). It also re-exports
  `AutocompleteItem` + `AutocompleteSuggestions` from `@earendil-works/pi-tui` so the
  wire types are byte-identical to pi's engine. S4 additionally (e) adds `"protocol.ts"`
  to `extension/tsconfig.json`'s `include`, and (f) ships a `node:test`+jiti suite
  (`extension/tests/protocol.test.ts`) split into a runtime load test (proves the
  type-only module loads with zero deps) + compile-time type tests (validated by
  `tsc --noEmit`, the Level-1 gate). This task is NARROW: NO changes to
  `pi-editor-bridge.ts` (wiring is M2), NO socket (M2), NO env write (S16), NO
  runtime values (types only — error-code map is S9/S15), NO framing implementation
  (S7), NO `package.json`/README (S18).
---

## Goal

**Feature Goal**: A single new file — `extension/protocol.ts` — that is a
**pure-types** module (zero runtime exports, zero runtime deps, all `import type`)
encoding the complete IPC contract so that every later server/handler task (M2 socket
server, S8 connection dispatch, S9 handshake, S11–S14 method handlers, S16 env
advertisement) imports typed envelopes from one canonical source. The types must match
PRD §5.3/§5.4 **verbatim** and re-use pi's own `AutocompleteItem`/`AutocompleteSuggestions`
so the wire format cannot drift from pi's autocomplete engine.

**Deliverable** (all under `extension/`):
1. **CREATE** `extension/protocol.ts` exporting (see Implementation Patterns for the
   exact reference body):
   - Raw envelopes: `JsonRpcError`, `JsonRpcRequest`, `JsonRpcResponse` (discriminated
     union: success-with-`result` | error-with-`error`), `JsonRpcNotification`.
   - `BridgeDescriptor` (7 fields, `transport: "unix"` literal).
   - Per-method params/results for all 8 methods (PRD §5.4 table):
     `HelloParams/HelloResult`, `PingParams/PingResult`,
     `GetSuggestionsParams/GetSuggestionsResult`, `ApplyCompletionParams/ApplyCompletionResult`,
     `ShouldTriggerFileCompletionParams/ShouldTriggerFileCompletionResult`,
     `GetCommandsParams/GetCommandsResult` (+ `CommandInfo`), `CommandsChangedParams`,
     `ByeParams/ByeResult`.
   - Mapped dispatch layer: `BridgeMethod`, `RequestMethod`, `NotificationMethod`,
     `BridgeParamsMap`, `BridgeResultMap` (commandsChanged OMITTED), `BridgeParams<M>`,
     `BridgeResult<M>`, `TypedRequest<M>`, `TypedResponse<M>`, `TypedNotification<M>`.
   - Re-export: `export { type AutocompleteItem, type AutocompleteSuggestions } from "@earendil-works/pi-tui";`
   - Mode-A JSDoc on each exported type explaining its wire role; a file-level header
     citing PRD §5 and the `dist/modes/rpc/jsonl.js` framing contract (the authoritative
     mirror S7 will implement).
2. **MODIFY** `extension/tsconfig.json`: change `"include"` from
   `["pi-editor-bridge.ts", "tests/**/*.ts"]` to
   `["pi-editor-bridge.ts", "protocol.ts", "tests/**/*.ts"]`. (One-line, additive. The
   `paths` mapping already resolves both `@earendil-works/pi-coding-agent` and
   `@earendil-works/pi-tui` — no `paths` change needed.)
3. **CREATE** `extension/tests/protocol.test.ts` — a `node:test`+jiti suite with:
   (i) a runtime load test (`await import("../protocol.ts")` resolves without throwing,
   proving type-only + zero-deps), and (ii) a compile-time type test (declared inside a
   test body) that constructs an instance of EVERY envelope + per-method param/result +
   mapped type, validated by `tsc --noEmit` (Level 1); a few also feed `assert.equal`
   for runtime signal.

**Success Definition**:
- `tsc --noEmit -p extension/tsconfig.json` → exit 0, **no output** (every type in
  `protocol.ts` + the type-test declarations compile cleanly; `paths` resolves pi-tui).
- `node --import <jiti-register.mjs> extension/tests/protocol.test.ts` → exit 0,
  `fail 0` (load test passes; type-test runtime asserts pass).
- `protocol.ts` has **zero value imports / zero runtime exports** — a standalone jiti
  import yields an empty module namespace (proves "loads with zero node_modules" per
  PRD §6.7).
- `pi --no-extensions -e ./extension/pi-editor-bridge.ts --print "ok"` still exits 0
  with no error lines (S4 did not regress the entry point; protocol.ts is not wired
  into it yet).

## User Persona (if applicable)

**Target User**: The bridge-extension author and every later implementer of the M2/M3
tasks (socket server, connection dispatch, handshake, RPC handlers, env advertisement).
This task is developer infrastructure: it defines the single source of truth for the
wire format so handlers can be written against typed envelopes instead of hand-rolled
`any`/`unknown` shapes.

**Use Case**: When S9 implements the `hello` handshake, it imports
`HelloParams`/`HelloResult` and `JsonRpcError`; when S11 implements
`getSuggestions`, it imports `GetSuggestionsParams`/`GetSuggestionsResult`; when S16
writes the env var, it `JSON.stringify`s a value of type `BridgeDescriptor`. All of
them get compile-time guarantees that the shapes match PRD §5 — and match pi's own
autocomplete types via the re-export.

**Pain Points Addressed**: Without a shared protocol module, each handler re-declares
its own param shape (drift risk), and the JSON-RPC version field / id type / error
shape become per-call conventions. Centralizing the contract (with literals like
`jsonrpc:"2.0"`, `ok: true`, `transport: "unix"`) makes "this is a valid wire message"
a compile-time invariant.

## Why

- **Single source of truth for the wire format** (PRD §5.3 envelopes, §5.4 methods
  table, §6.4 descriptor). Every later server task (M2) reads these types; the
  Neovim side mirrors them in Lua. Getting them right once, here, prevents an entire
  class of "client/server disagree on a field name" bugs.
- **Byte-identical to pi's engine** (item OUTPUT #4): re-exporting
  `AutocompleteItem`/`AutocompleteSuggestions` from `@earendil-works/pi-tui` (instead
  of redeclaring them) means `GetSuggestionsResult` CANNOT drift from the
  `AutocompleteProvider.getSuggestions` return type the handlers delegate to.
- **De-risks the type-resolution path early**: confirms the dev `tsconfig.json` `paths`
  mapping resolves the nested `@earendil-works/pi-tui` declarations (already used by
  S2's `AutocompleteProvider` import — S4 adds a second `import type` from the same
  package, reusing the resolved path).
- **Foundation, no behavior**: a type-only module changes nothing at runtime, so it is
  the safest possible first step of the IPC milestone (P1.M1.T2) and can land in
  parallel with the TUI-guard task without merge risk.

## What

A new file `extension/protocol.ts` containing only `interface`/`type` declarations +
one type-only re-export, plus a one-line `tsconfig.json` `include` edit and a
`node:test`+jiti test file. No runtime values, no sockets, no env writes, no changes to
`pi-editor-bridge.ts`.

### Success Criteria

- [ ] `extension/protocol.ts` exists and exports every type listed in Deliverable #1
      with the exact names/shapes in Implementation Patterns.
- [ ] Every type import is `import type`; the module's ONLY `export ... from` is the
      type-only re-export of `AutocompleteItem` + `AutocompleteSuggestions`.
- [ ] `jsonrpc` is the literal `"2.0"`; `id` is `string`; `JsonRpcError` is
      `{ code: number; message: string }` (no `data`); raw envelopes use `unknown` for
      `params?`/`result?`.
- [ ] `ok` is the literal `true` on `HelloResult`/`PingResult`/`ByeResult`.
- [ ] Empty params/results (`PingParams`, `GetCommandsParams`, `CommandsChangedParams`,
      `ByeParams`) are `Record<string, never>`.
- [ ] `BridgeDescriptor` has fields `transport:"unix" | path | token | pid | cwd |
      fdAvailable | serverVersion` (all required; no `version` field).
- [ ] `CommandInfo` is `{ name: string; description?: string; argumentHint?: string }`
      (bridge-local; JSDoc says so and excludes pi-internal fields).
- [ ] `BridgeMethod` lists all 8 methods; `RequestMethod = Exclude<BridgeMethod,
      "commandsChanged">`; `NotificationMethod = "commandsChanged"`.
- [ ] `BridgeResultMap` omits `commandsChanged`; `BridgeParamsMap` includes it.
- [ ] `extension/tsconfig.json` `include` includes `"protocol.ts"` (paths unchanged).
- [ ] `extension/tests/protocol.test.ts` passes: runtime load test + type-shape test.
- [ ] `tsc --noEmit -p extension/tsconfig.json` → exit 0, no output.
- [ ] `protocol.ts` is NOT imported by `pi-editor-bridge.ts` (wiring = M2).
- [ ] NO socket / env write / framing impl / runtime const / packaging added.

## All Needed Context

### Context Completeness Check

_Pass test_: An agent who has never seen this repo, given the existing
`extension/pi-editor-bridge.ts` (post-S3) + `extension/tsconfig.json` (supplied as the
baseline) and this PRP, can (1) write `protocol.ts` verbatim from the reference body
below (every type name, literal, and field is pinned), (2) make the one-line tsconfig
edit, (3) write the test from the supplied skeleton, and (4) run the three exact
validation commands to green — with every type's source-of-truth citation listed here.

### Documentation & References

```yaml
# MUST READ — the wire protocol spec (this PRP ships the types for it)
- docfile: PRD.md
  why: §5 IPC Protocol — transport, framing, handshake, methods table, timing; §6.4 descriptor skeleton; §8 coordinate/encoding contract
  section: "§5.3 (handshake envelopes + -32600 bad-token), §5.4 (methods table — the EXACT params/result for all 8 methods), §6.4 (BridgeDescriptor reference skeleton hardcodes serverVersion:\"0.1.0\"), §8 (cursorCol = UTF-16 offset — semantics belong to coords.lua, type is just number)"
  critical: |
    §5.4 table is the authoritative field list. Note §4 shows "version":"0.0.1" in a
    descriptor example but §6.4 + the S4 item contract canonicalize the field name to
    serverVersion — S4 uses serverVersion.

# MUST READ — the types S4 re-uses verbatim (installed dist; line-cited)
- file: /home/dustin/.local/lib/node_modules/@earendil-works/pi-coding-agent/node_modules/@earendil-works/pi-tui/dist/index.d.ts
  why: confirms AutocompleteItem + AutocompleteSuggestions are exported (re-export source)
  section: "L1: export { type AutocompleteItem, type AutocompleteProvider, type AutocompleteSuggestions, ... } from \"./autocomplete.ts\""
- file: /home/dustin/.local/lib/node_modules/@earendil-works/pi-coding-agent/node_modules/@earendil-works/pi-tui/dist/autocomplete.d.ts
  why: exact field shapes S4 re-uses
  section: "L1 AutocompleteItem={value,label,description?}; L13 AutocompleteSuggestions={items,prefix}; L24-28 applyCompletion returns {lines,cursorLine,cursorCol}; L29 shouldTriggerFileCompletion? optional"
  critical: |
    These are RE-EXPORTED, not redeclared — GetSuggestionsResult/AutocompleteSuggestions and
    ApplyCompletionParams.item/AutocompleteItem stay byte-identical to pi's engine.

# MUST READ — BridgeDescriptor field sources (installed dist)
- file: /home/dustin/.local/lib/node_modules/@earendil-works/pi-coding-agent/dist/core/extensions/types.d.ts
  why: ctx.cwd (descriptor.cwd) + ctx.mode; proof CommandInfo does NOT exist in pi (use bridge-local lean type)
  section: "L207 ExtensionMode; L211-216 ExtensionContext { cwd: string } (descriptor.cwd source). grep -rn CommandInfo over dist/ returns ONLY SlashCommandInfo/getCommands():SlashCommandInfo[] (types.d.ts:923) — NO CommandInfo."

# MUST READ — the framing contract S4's JSDoc cites (authoritative mirror for S7)
- url: file:///home/dustin/.local/lib/node_modules/@earendil-works/pi-coding-agent/dist/modes/rpc/jsonl.js
  why: pi's own JSONL framing; S4 is types-only (implements nothing) but documents the contract
  section: "L8 serializeJsonLine = JSON.stringify(v)+\\n; L22 strip trailing \\r (endsWith(\"\\r\")?slice(0,-1):line); L27 split on \\n only (buffer.indexOf(\"\\n\")); L14 explicitly does NOT use Node readline (splits on U+2028/U+2029)"
  critical: |
    S4 does NOT implement framing (that's S7). The protocol.ts file-header JSDoc cites this
    file so S7 has the authoritative mirror reference in one place.

# MUST READ — the authoritative pre-researched spec (project-local)
- docfile: plan/001_c56962b4fa17/P1M1T2S1/research/notes.md
  why: the exhaustive analysis of EVERY type's exact shape, the two-layer (raw + mapped) design, CommandInfo decision, re-export mechanics, test strategy — every claim file:line verified
  section: "§1 raw envelopes; §2 BridgeDescriptor fields; §3 per-method params/results; §4 CommandInfo (bridge-local); §5 method union + mapped types; §7 re-export + tsconfig; §8 test strategy"
  critical: |
    This is the single most important reference. The PRP's reference body implements it
    verbatim. (Dir note: P1M1T2S1 is the SAME work item as P1.M1.T2.S4 — the research
    itself says "P1.M1.T2.S4 in the global subtask sequence; dir = P1M1T2S1".)

# SUPPORTING — direct re-verification of the above on THIS machine
- docfile: plan/001_c56962b4fa17/P1M1T2S4/research/notes.md
  why: live confirmations of pi-tui exports, ExtensionContext.cwd/mode, jsonl.js framing, tsconfig include state, tool versions, validation commands
  section: "§0 environment; §1-2 type re-verification; §4 tsconfig current include; §7 validation commands (known-good)"

# SUPPORTING — architecture context (project-local)
- docfile: plan/001_c56962b4fa17/architecture/research-pi-autocomplete.md
  why: confirms AutocompleteItem/AutocompleteSuggestions/AutocompleteProvider signatures + applyCompletion return shape (autocomplete.ts line-cited against the monorepo source)
  section: "§1 (type/interface definitions, lines 99-144); §1 applyCompletion return {lines,cursorLine,cursorCol}"
- docfile: plan/001_c56962b4fa17/architecture/external_deps.md
  why: JSONL write convention (encode + \"\\n\") + node builtins inventory (used by M2, not S4)
  section: "L98 write data (JSONL: encode + \"\\n\"); L250-253 node:net/node:crypto/node:os"

# SUPPORTING — JSON-RPC 2.0 spec (for the error-code JSDoc; S4 ships NO runtime code map)
- url: https://www.jsonrpc.org/specification#error_object
  why: canonical error object + pre-defined error codes S4 documents in JSDoc (S9/S15 may add a runtime const map)
  section: "error object {code,message,data?} (S4 omits data); code list: -32700 parse, -32600 invalid request, -32601 method not found, -32602 invalid params, -32603 internal error"

# MUST READ — the baseline S4 builds on
- docfile: plan/001_c56962b4fa17/P1M1T1S3/PRP.md
  why: defines the post-S3 shape of extension/pi-editor-bridge.ts (which S4 does NOT touch) + the dev tsconfig S4 only edits the include of
  section: "Implementation Patterns (S3 session_start handler) + Validation (tsconfig paths already map pi-coding-agent AND pi-tui)"
  critical: |
    S4 EDITS tsconfig.json (add protocol.ts to include) but does NOT touch
    pi-editor-bridge.ts. Match S2/S3 TAB indentation + import-type discipline.
```

### Current Codebase tree (post-S3 baseline — S4 adds one file + edits tsconfig)

```bash
extension/
├── pi-editor-bridge.ts            # (S1+S2+S3) default-export factory; session_start (TUI guard + log + captureProvider) + session_shutdown (no-op); captureProvider/getProvider/liveProvider; JSDoc header. S4 does NOT touch this.
├── tsconfig.json                  # (S1+S2) dev-only; paths map BOTH pi-coding-agent AND pi-tui; include=["pi-editor-bridge.ts","tests/**/*.ts"]
└── tests/
    ├── provider-capture.test.ts   # (S2) node:test suite for captureProvider/getProvider
    └── mode-guard.test.ts         # (S3) node:test suite for the TUI guard
# plan/ holds planning artifacts only — no other source code
```

### Desired Codebase tree with files to be added/modified

```bash
extension/
├── pi-editor-bridge.ts            # (UNCHANGED — wiring is M2)
├── protocol.ts                    # (CREATE) type-only JSON-RPC + BridgeDescriptor + per-method + mapped-dispatch module; re-exports pi-tui autocomplete types
├── tsconfig.json                  # (MODIFY) include += "protocol.ts"  (paths unchanged)
└── tests/
    ├── provider-capture.test.ts   # (UNCHANGED — S2)
    ├── mode-guard.test.ts         # (UNCHANGED — S3)
    └── protocol.test.ts           # (CREATE) node:test+jiti: runtime load test + compile-time type tests
```

**File responsibilities**
- `extension/protocol.ts` — the canonical IPC contract. Type-only (no runtime exports).
  Consumed by M2's socket server / connection dispatch (S8), handshake (S9), method
  handlers (S11–S14), and env advertisement (S16). The Lua side mirrors these shapes.
- `extension/tsconfig.json` — dev tooling; S4's only change is adding `"protocol.ts"`
  to `include` so `tsc --noEmit` type-checks it (Level 1 gate).
- `extension/tests/protocol.test.ts` — extends the zero-dependency TS test pattern
  (`node:test` + jiti register, established by S2/S3). Split into a runtime load test
  (the critical runtime invariant: type-only module loads with zero deps) + a
  compile-time type test (every envelope/type exercised; validated by tsc).

### Known Gotchas of our codebase & Library Quirks

```typescript
// CRITICAL: protocol.ts must be TYPE-ONLY. No const objects, no enums, no runtime
//   functions. A JSON-RPC error-code const map (e.g. {PARSE:-32700,...}) would be
//   convenient but is S9/S15's job — keep S4 types-only so the module loads with
//   zero node_modules and the "runtime load" test has a clean assertion.

// CRITICAL: re-export, don't redeclare, AutocompleteItem/AutocompleteSuggestions.
//   `export { type AutocompleteItem, type AutocompleteSuggestions } from "@earendil-works/pi-tui";`
//   AND a local `import type { ... } from "@earendil-works/pi-tui"` for use inside
//   GetSuggestionsResult / ApplyCompletionParams. Both type-only → erased at runtime.

// CRITICAL: jsonrpc is the LITERAL "2.0" (not string). id is string (PRD §5 restricts
//   to string — do NOT widen to string|number|null). error is {code,message} with NO
//   data field. Use `unknown` (not `any`) for params?/result? so consumers MUST narrow.

// CRITICAL: ok is the LITERAL true on HelloResult/PingResult/ByeResult (the PRD wire
//   examples always show "ok":true). Typing ok:true makes "success requires ok=true"
//   a compile-time invariant.

// CRITICAL: empty {} params/results must be Record<string, never> — NOT the unsafe {}
//   type (which means "any non-nullish"). An object literal {} IS assignable to
//   Record<string, never>; stray keys are rejected at the type level.

// GOTCHA: descriptor field name is serverVersion (item contract + §6.4 hardcode
//   "0.1.0"), NOT version. PRD §4's example shows "version":"0.0.1" — that is a doc
//   inconsistency; the component spec (§6.4) and the S4 item contract win. Use serverVersion.

// GOTCHA: CommandInfo does NOT exist in pi (grep returns only SlashCommandInfo).
//   Define a LEAN bridge-local CommandInfo = {name;description?;argumentHint?} that
//   mirrors the user-facing slice of BuiltinSlashCommand/SlashCommand, INTENTIONALLY
//   excluding sourceInfo (internal file paths), handler, and getArgumentCompletions
//   (callables). JSDoc must state "bridge-local, NOT re-exported from pi".

// GOTCHA: commandsChanged has NO result — it is a server→client notification. So:
//   - OMIT it from BridgeResultMap (the result map stays honest).
//   - INCLUDE it in BridgeParamsMap + NotificationMethod + TypedNotification only.
//   - RequestMethod = Exclude<BridgeMethod, "commandsChanged">.

// GOTCHA: tsconfig has strict:true but NOT noUnusedLocals/noUnusedParameters. The
//   compile-time type-test consts are declared INSIDE test bodies (cleaner + robust
//   against a future tsconfig tightening); a few feed assert.equal for runtime signal.

// STYLE: TABS for indentation (match pi-editor-bridge.ts + pi's examples). `import
//   type` for ALL imports. PascalCase interfaces/type aliases; method names as
//   string-literal union members match PRD §5.4 EXACTLY (shouldTriggerFileCompletion,
//   getCommands, commandsChanged — full camelCase, not abbreviated).
```

## Implementation Blueprint

### Data models and structure

This task's "data models" ARE the protocol types themselves. The full reference set is
given in **Implementation Patterns & Key Details** below — there is no other runtime
data. Every type is either an `interface` (envelopes, params/results, descriptor,
CommandInfo, the two `*Map` interfaces) or a `type` alias (the raw response union, the
method-name union, `BridgeParams<M>`, `BridgeResult<M>`, the narrowed envelopes, the
empty-params `Record<string, never>` aliases).

### Implementation Tasks (ordered by dependencies)

```yaml
Task 1: CREATE extension/protocol.ts  (type-only module)
  - HEADER: Mode-A JSDoc file header: purpose (IPC contract for pi-editor-bridge ↔
      pi-editor.nvim), transport (Unix socket + strict JSONL), the PRD §5 reference,
      and a one-line citation of dist/modes/rpc/jsonl.js as the authoritative framing
      contract mirror (implemented by S7, not here). Note STATUS: types-only; wiring
      lands in M2/S16.
  - IMPORT: `import type { AutocompleteItem, AutocompleteSuggestions } from "@earendil-works/pi-tui";`
      (local use in GetSuggestionsResult / ApplyCompletionParams).
  - RE-EXPORT: `export { type AutocompleteItem, type AutocompleteSuggestions } from "@earendil-works/pi-tui";`
      (item contract: "Re-export ... for convenience").
  - DECLARE (each with a Mode-A JSDoc explaining its wire role — see Implementation
      Patterns for exact text):
      §A raw envelopes: JsonRpcError; JsonRpcRequest; JsonRpcResponse (union);
        JsonRpcNotification.
      §B BridgeDescriptor (7 fields, transport:"unix" literal).
      §C per-method (PRD §5.4 order): HelloParams/HelloResult; PingParams/PingResult;
        GetSuggestionsParams/GetSuggestionsResult; ApplyCompletionParams/ApplyCompletionResult;
        ShouldTriggerFileCompletionParams/ShouldTriggerFileCompletionResult;
        GetCommandsParams/CommandInfo/GetCommandsResult; CommandsChangedParams;
        ByeParams/ByeResult.
      §D dispatch layer: BridgeMethod (8 members); RequestMethod; NotificationMethod;
        BridgeParamsMap (8 entries); BridgeResultMap (7 entries — NO commandsChanged);
        BridgeParams<M>; BridgeResult<M>; TypedRequest<M>; TypedResponse<M>;
        TypedNotification<M>.
  - FOLLOW: TAB indentation; `import type` only; literal types where specified
      ("2.0", true, "unix"); unknown for params?/result?; Record<string,never> for empty.
  - NAMING: exact names from Implementation Patterns (PascalCase interfaces/type aliases;
    method union members are the exact PRD §5.4 method strings).
  - PLACEMENT: extension/protocol.ts.
  - DO NOT: add any const/enum/function/value import; implement framing; touch
      pi-editor-bridge.ts; write process.env; add package.json/README.

Task 2: MODIFY extension/tsconfig.json  (one-line additive edit)
  - CHANGE the "include" array from
      ["pi-editor-bridge.ts", "tests/**/*.ts"]
    to
      ["pi-editor-bridge.ts", "protocol.ts", "tests/**/*.ts"]
  - LEAVE UNCHANGED: every compilerOption (target/module/moduleResolution/strict/noEmit/
      allowImportingTsExtensions/skipLibCheck/types/baseUrl/paths). The paths mapping
      already resolves BOTH pi-coding-agent and pi-tui — S4 needs NO new path.
  - RISK: this edit is additive and safe vs. S3's prior state (S3 did not edit tsconfig).

Task 3: CREATE extension/tests/protocol.test.ts  (node:test + jiti)
  - IMPORT: `import { test } from "node:test"; import assert from "node:assert/strict";`
      `import type { ...all protocol.ts types... } from "../protocol.ts";`
  - TEST 1 (runtime load): `await import("../protocol.ts")` resolves via jiti WITHOUT
      throwing; assert the namespace is an object (type-only module => empty runtime
      namespace). This proves zero-deps + type-only (PRD §6.7).
  - TEST 2 (compile-time type shapes, declared INSIDE the test body so they're not
      module-level unused locals): construct an instance of EVERY envelope + per-method
      param/result + mapped type (raw Request/Response-ok/Response-err/Notification,
      BridgeDescriptor, every *Params/*Result, CommandInfo, BridgeMethod/
      RequestMethod/NotificationMethod values, BridgeParams<"getSuggestions">,
      BridgeResult<"hello">, TypedRequest<"ping">, TypedResponse<"ping">,
      TypedNotification). A handful feed assert.equal (error code, descriptor
      transport literal, ok literal) for runtime signal. These compile-correctness
      checks are enforced by `tsc --noEmit` (Level 1).
  - FOLLOW: TAB indentation; `import type` for all type imports; reuse the SAME jiti
      register hook path as S2/S3 tests.
  - NAMING: descriptive test names ("protocol.ts imports cleanly via jiti ...",
      "wire type shapes compile and round-trip ...").
  - PLACEMENT: extension/tests/protocol.test.ts.
  - NO CONCURRENCY: rely on default sequential node:test execution.

Task 4: VALIDATE — run the three validation commands; fix until all green
  - RUN (Level 1): `tsc --noEmit -p extension/tsconfig.json` (expect exit 0, no output)
  - RUN (Level 2): `node --import <jiti-register.mjs> extension/tests/protocol.test.ts`
      (expect exit 0, fail 0)
  - RUN (Level 3, regression): `pi --no-extensions -e ./extension/pi-editor-bridge.ts
      --print "ok"` — expect exit 0, no error/cannot/fail/throw/TypeError lines
      (protocol.ts is NOT wired in yet; this proves S4 didn't break the entry point).
```

### Implementation Patterns & Key Details

```typescript
// === extension/protocol.ts (CREATE — type-only; implement VERBATIM) ===
/**
 * protocol.ts — the JSON-RPC 2.0 IPC contract between the pi-editor-bridge
 * extension (server, pi side) and the pi-editor.nvim plugin (client, Neovim side).
 *
 * Transport: Unix domain socket. Framing: strict JSONL — exactly one JSON object per
 * line, delimited by `\n` only (strip an optional trailing `\r`; do NOT use readers
 * that split on U+2028/U+2029). The authoritative framing mirror is pi's own
 * `dist/modes/rpc/jsonl.js` (serializeJsonLine = `${JSON.stringify(v)}\n`; split on
 * `buffer.indexOf("\n")`; never Node readline) — IMPLEMENTED by the JSONL reader task
 * (S7), not here. This module is TYPES-ONLY.
 *
 * Wire references: PRD §5 (IPC Protocol) — §5.3 envelopes + handshake, §5.4 methods
 * table, §5.5 timing. PRD §6.4 BridgeDescriptor skeleton (serverVersion hardcode
 * "0.1.0"). PRD §8 coordinate/encoding contract (cursorCol = UTF-16 offset; the
 * numeric type is `number` here; the conversion lives in the Lua coords module).
 *
 * STATUS (P1.M1.T2.S4): types-only. Wiring into the extension (socket server, env
 * advertisement) lands in M2 / S16. Re-exports pi-tui's autocomplete types so the wire
 * format stays byte-identical to pi's engine.
 *
 * Loaded via jiti (TS works without compilation). Type-only => zero runtime exports.
 */
import type {
	AutocompleteItem,
	AutocompleteSuggestions,
} from "@earendil-works/pi-tui";

/** Re-export pi's autocomplete wire types so consumers import them from one place. */
export {
	type AutocompleteItem,
	type AutocompleteSuggestions,
} from "@earendil-works/pi-tui";

/* ==========================================================================
 * §A — Raw JSON-RPC 2.0 envelopes (the shape a JSONL line parses into BEFORE
 *      method-based narrowing). jsonrpc is the literal "2.0" (compile-time version
 *      check); id is string (PRD §5 restricts to string — not number/null); params?/
 *      result? are `unknown` to force consumers to narrow.
 *      JSON-RPC 2.0 spec error codes (for later runtime code, S9/S15): -32700 parse,
 *      -32600 invalid request, -32601 method not found, -32602 invalid params,
 *      -32603 internal error. PRD §5.3 uses -32600 "bad token" for handshake failure.
 * ========================================================================== */

/** Error object carried inside an error response (NO `data` field — keep minimal). */
export interface JsonRpcError {
	code: number;
	message: string;
}

/** Client→Server request envelope. */
export interface JsonRpcRequest {
	jsonrpc: "2.0";
	id: string;
	method: string;
	params?: unknown;
}

/**
 * Server→Client response envelope — a discriminated union: success carries `result`,
 * failure carries `error`. Exactly one of `result`/`error` is present on the wire.
 */
export type JsonRpcResponse =
	| { jsonrpc: "2.0"; id: string; result?: unknown }
	| { jsonrpc: "2.0"; id: string; error: JsonRpcError };

/** Notification envelope (S→C or C→S); carries NO id and expects NO reply. */
export interface JsonRpcNotification {
	jsonrpc: "2.0";
	method: string;
	params?: unknown;
}

/* ==========================================================================
 * §B — BridgeDescriptor: JSON-serialized to process.env.PI_EDITOR_BRIDGE (S16) and
 *      vim.json.decode'd by the Neovim activation gate (PRD §7.1). MUST be a plain
 *      JSON object (all fields required, JSON-serializable). `transport:"unix"` is a
 *      v1 literal; PRD §5.1 names a future TCP variant — extend as a discriminated
 *      union on `transport` when that lands.
 *      Field value sources: path=socketPath; token=randomUUID-derived (the REAL auth
 *      boundary, PRD §12); pid=process.pid; cwd=ctx.cwd; fdAvailable=fd resolved;
 *      serverVersion=bridge version string (PRD §6.4 hardcodes "0.1.0").
 * ========================================================================== */
export interface BridgeDescriptor {
	transport: "unix";
	path: string;
	token: string;
	pid: number;
	cwd: string;
	fdAvailable: boolean;
	serverVersion: string;
}

/* ==========================================================================
 * §C — Per-method params/result types. Field names/types match PRD §5.4 EXACTLY.
 *      `ok` is the literal `true` on success results. Empty `{}` params/results use
 *      Record<string, never> (the correct TS "empty object"; `{}` is unsafe).
 *      AutocompleteItem/AutocompleteSuggestions come from pi-tui (re-exported above).
 * ========================================================================== */

/** `hello` (C→S): client proves it has the token from process.env. */
export interface HelloParams {
	token: string;
	client?: string;
	clientVersion?: string;
}
/** `hello` (C→S) success result: server identity + capabilities. */
export interface HelloResult {
	ok: true;
	serverVersion: string;
	cwd: string;
	fdAvailable: boolean;
}

/** `ping` (C→S): empty params. */
export type PingParams = Record<string, never>;
/** `ping` (C→S) result: liveness + server info. */
export interface PingResult {
	ok: true;
	pid: number;
	cwd: string;
	fdAvailable: boolean;
	serverVersion: string;
}

/**
 * `getSuggestions` (C→S). cursorLine is 0-indexed; cursorCol is a 0-indexed UTF-16
 * code-unit offset into lines[cursorLine] (PRD §8). `force` forces file completion
 * (mirrors pi's Tab / shouldTriggerFileCompletion path).
 */
export interface GetSuggestionsParams {
	lines: string[];
	cursorLine: number;
	cursorCol: number;
	force?: boolean;
}
/** `getSuggestions` result: pi's suggestions, or null if none. */
export type GetSuggestionsResult = AutocompleteSuggestions | null;

/** `applyCompletion` (C→S): delegate insertion to pi for byte-identical behavior. */
export interface ApplyCompletionParams {
	lines: string[];
	cursorLine: number;
	cursorCol: number;
	item: AutocompleteItem;
	prefix: string;
}
/** `applyCompletion` result: the NEW full buffer + cursor (pi computes insertion). */
export interface ApplyCompletionResult {
	lines: string[];
	cursorLine: number;
	cursorCol: number;
}

/** `shouldTriggerFileCompletion` (C→S). */
export interface ShouldTriggerFileCompletionParams {
	lines: string[];
	cursorLine: number;
	cursorCol: number;
}
/** `shouldTriggerFileCompletion` result. */
export type ShouldTriggerFileCompletionResult = boolean;

/** `getCommands` (C→S, OPTIONAL — richer docs menus): empty params. */
export type GetCommandsParams = Record<string, never>;
/**
 * Bridge-LOCAL command descriptor for the optional `getCommands` docs menu. NOT
 * re-exported from pi (pi has no `CommandInfo` — only SlashCommandInfo, which leaks
 * internal `sourceInfo` paths). This mirrors the user-facing slice of pi's
 * BuiltinSlashCommand/SlashCommand, INTENTIONALLY EXCLUDING sourceInfo,
 * handler, and getArgumentCompletions (callables). The S14 handler maps pi's
 * SlashCommandInfo[]/BuiltinSlashCommand[] DOWN to this lean wire shape.
 */
export interface CommandInfo {
	name: string;
	description?: string;
	argumentHint?: string;
}
/** `getCommands` result. */
export interface GetCommandsResult {
	commands: CommandInfo[];
}

/** `commandsChanged` (S→C NOTIFICATION): empty params, NO result. */
export type CommandsChangedParams = Record<string, never>;

/** `bye` (C→S): empty params. */
export type ByeParams = Record<string, never>;
/** `bye` result: graceful disconnect ack. */
export interface ByeResult {
	ok: true;
}

/* ==========================================================================
 * §D — Method-name union + mapped types (the typed dispatch layer). The raw
 *      envelopes (§A) carry method:string/params?:unknown; this layer narrows them
 *      per-method so M2's dispatcher (S8) and handshake (S9) get compile-time
 *      param/result checking. commandsChanged is a notification: it has params but
 *      NO result, so it is OMITTED from BridgeResultMap and lives only in
 *      BridgeParamsMap + NotificationMethod + TypedNotification.
 * ========================================================================== */

/** All 8 method names (PRD §5.4), exact strings. */
export type BridgeMethod =
	| "hello"
	| "ping"
	| "getSuggestions"
	| "applyCompletion"
	| "shouldTriggerFileCompletion"
	| "getCommands"
	| "commandsChanged"
	| "bye";

/** C→S requests: carry an id and expect a result (everything except the notification). */
export type RequestMethod = Exclude<BridgeMethod, "commandsChanged">;
/** S→C notifications: no id, no result. */
export type NotificationMethod = "commandsChanged";

/** Maps each method to its params type. */
export interface BridgeParamsMap {
	hello: HelloParams;
	ping: PingParams;
	getSuggestions: GetSuggestionsParams;
	applyCompletion: ApplyCompletionParams;
	shouldTriggerFileCompletion: ShouldTriggerFileCompletionParams;
	getCommands: GetCommandsParams;
	commandsChanged: CommandsChangedParams;
	bye: ByeParams;
}

/** Maps each REQUEST method to its result type. commandsChanged OMITTED (no result). */
export interface BridgeResultMap {
	hello: HelloResult;
	ping: PingResult;
	getSuggestions: GetSuggestionsResult;
	applyCompletion: ApplyCompletionResult;
	shouldTriggerFileCompletion: ShouldTriggerFileCompletionResult;
	getCommands: GetCommandsResult;
	bye: ByeResult;
}

/** Params type for a given method. */
export type BridgeParams<M extends BridgeMethod> = BridgeParamsMap[M];
/** Result type for a given REQUEST method. */
export type BridgeResult<M extends RequestMethod> = BridgeResultMap[M];

/** Narrowed C→S request (typed method + typed params). */
export interface TypedRequest<M extends RequestMethod = RequestMethod> {
	jsonrpc: "2.0";
	id: string;
	method: M;
	params: BridgeParams<M>;
}

/** Narrowed S→C response (typed result OR error). */
export type TypedResponse<M extends RequestMethod = RequestMethod> =
	| { jsonrpc: "2.0"; id: string; result: BridgeResult<M> }
	| { jsonrpc: "2.0"; id: string; error: JsonRpcError };

/** Narrowed notification (typed method + typed params; no id, no result). */
export interface TypedNotification<M extends NotificationMethod = NotificationMethod> {
	jsonrpc: "2.0";
	method: M;
	params: BridgeParams<M>;
}
```

```jsonc
// === extension/tsconfig.json — the ONE-LINE edit (include += "protocol.ts") ===
// (Everything else — target, module, moduleResolution, strict, noEmit,
//  allowImportingTsExtensions, skipLibCheck, types, baseUrl, paths — UNCHANGED.)
{
  "compilerOptions": {
    "target": "ES2022",
    "module": "ESNext",
    "moduleResolution": "Bundler",
    "strict": true,
    "noEmit": true,
    "allowImportingTsExtensions": true,
    "skipLibCheck": true,
    "types": [],
    "baseUrl": ".",
    "paths": {
      "@earendil-works/pi-coding-agent": [
        "/home/dustin/.local/lib/node_modules/@earendil-works/pi-coding-agent/dist/index.d.ts"
      ],
      "@earendil-works/pi-tui": [
        "/home/dustin/.local/lib/node_modules/@earendil-works/pi-coding-agent/node_modules/@earendil-works/pi-tui/dist/index.d.ts"
      ]
    }
  },
  "include": ["pi-editor-bridge.ts", "protocol.ts", "tests/**/*.ts"]
}
```

```typescript
// === extension/tests/protocol.test.ts (CREATE — node:test + jiti) ===
import { test } from "node:test";
import assert from "node:assert/strict";
import type {
	JsonRpcError,
	JsonRpcRequest,
	JsonRpcResponse,
	JsonRpcNotification,
	BridgeDescriptor,
	HelloParams,
	HelloResult,
	PingParams,
	PingResult,
	GetSuggestionsParams,
	GetSuggestionsResult,
	ApplyCompletionParams,
	ApplyCompletionResult,
	ShouldTriggerFileCompletionParams,
	ShouldTriggerFileCompletionResult,
	GetCommandsParams,
	GetCommandsResult,
	CommandInfo,
	CommandsChangedParams,
	ByeParams,
	ByeResult,
	BridgeMethod,
	RequestMethod,
	NotificationMethod,
	BridgeParams,
	BridgeResult,
	TypedRequest,
	TypedResponse,
	TypedNotification,
} from "../protocol.ts";

// Re-export check: the two pi-tui types must be reachable through protocol.ts too.
import type {
	AutocompleteItem,
	AutocompleteSuggestions,
} from "../protocol.ts";

// ============================================================================
// TEST 1 — runtime load. protocol.ts is TYPE-ONLY (no runtime exports), so the
// critical runtime invariant is "imports via jiti with zero deps" (PRD §6.7). The
// module namespace is an empty object at runtime; assert it loaded (non-null obj).
// ============================================================================
test("protocol.ts imports cleanly via jiti (type-only module, zero runtime deps)", async () => {
	const mod = await import("../protocol.ts");
	assert.equal(typeof mod, "object", "module namespace must be an object");
	assert.notEqual(mod, null, "module must load (not null)");
});

// ============================================================================
// TEST 2 — compile-time type shapes. These declarations are validated by
// `tsc --noEmit` (Level 1). Declared INSIDE the test body (not module-level) so they
// are not unused locals. A few feed assert.equal for runtime signal.
// ============================================================================
test("wire type shapes compile and round-trip key literals", () => {
	// --- §A raw envelopes ---
	const req: JsonRpcRequest = {
		jsonrpc: "2.0",
		id: "1",
		method: "hello",
		params: {},
	};
	const resOk: JsonRpcResponse = { jsonrpc: "2.0", id: "1", result: { ok: true } };
	const err: JsonRpcError = { code: -32600, message: "bad token" };
	const resErr: JsonRpcResponse = { jsonrpc: "2.0", id: "1", error: err };
	const notif: JsonRpcNotification = {
		jsonrpc: "2.0",
		method: "commandsChanged",
		params: {},
	};
	assert.equal(req.jsonrpc, "2.0");
	assert.equal(err.code, -32600);

	// --- §B descriptor ---
	const desc: BridgeDescriptor = {
		transport: "unix",
		path: "/tmp/pi-editor-bridge-x.sock",
		token: "deadbeef",
		pid: 4242,
		cwd: "/home/u/proj",
		fdAvailable: true,
		serverVersion: "0.1.0",
	};
	assert.equal(desc.transport, "unix");

	// --- §C per-method params/results ---
	const hello: HelloParams = {
		token: "deadbeef",
		client: "pi-editor.nvim",
		clientVersion: "0.1.0",
	};
	const helloRes: HelloResult = {
		ok: true,
		serverVersion: "0.1.0",
		cwd: "/home/u/proj",
		fdAvailable: true,
	};
	const ping: PingParams = {};
	const pingRes: PingResult = {
		ok: true,
		pid: 4242,
		cwd: "/home/u/proj",
		fdAvailable: true,
		serverVersion: "0.1.0",
	};
	const gsParams: GetSuggestionsParams = {
		lines: ["/mo"],
		cursorLine: 0,
		cursorCol: 3,
		force: false,
	};
	const gsRes: GetSuggestionsResult = {
		items: [{ value: "/model", label: "/model", description: "Switch model" }],
		prefix: "/mo",
	};
	const gsNull: GetSuggestionsResult = null;
	const acParams: ApplyCompletionParams = {
		lines: ["/mo"],
		cursorLine: 0,
		cursorCol: 3,
		item: { value: "/model", label: "/model" },
		prefix: "/mo",
	};
	const acRes: ApplyCompletionResult = {
		lines: ["/model "],
		cursorLine: 0,
		cursorCol: 7,
	};
	const stParams: ShouldTriggerFileCompletionParams = {
		lines: ["/set"],
		cursorLine: 0,
		cursorCol: 4,
	};
	const stRes: ShouldTriggerFileCompletionResult = false;
	const gcParams: GetCommandsParams = {};
	const ci: CommandInfo = {
		name: "/model",
		description: "Switch model",
		argumentHint: "<provider/id>",
	};
	const gcRes: GetCommandsResult = { commands: [ci] };
	const ccParams: CommandsChangedParams = {};
	const byeParams: ByeParams = {};
	const byeRes: ByeResult = { ok: true };
	assert.equal(byeRes.ok, true);

	// --- re-exported pi-tui types are usable through protocol.ts ---
	const item: AutocompleteItem = { value: "@/a.ts", label: "a.ts" };
	const sugg: AutocompleteSuggestions = { items: [item], prefix: "@/a" };
	assert.equal(sugg.items.length, 1);

	// --- §D method union + mapped types ---
	const m: BridgeMethod = "getSuggestions";
	const rm: RequestMethod = "bye"; // commandsChanged is NOT a request method
	const nm: NotificationMethod = "commandsChanged";
	const bp: BridgeParams<"getSuggestions"> = {
		lines: [],
		cursorLine: 0,
		cursorCol: 0,
	};
	const br: BridgeResult<"hello"> = {
		ok: true,
		serverVersion: "0.1.0",
		cwd: "/",
		fdAvailable: true,
	};

	// --- narrowed envelopes ---
	const treq: TypedRequest<"ping"> = {
		jsonrpc: "2.0",
		id: "2",
		method: "ping",
		params: {},
	};
	const tres: TypedResponse<"ping"> = {
		jsonrpc: "2.0",
		id: "2",
		result: {
			ok: true,
			pid: 1,
			cwd: "/",
			fdAvailable: true,
			serverVersion: "0.1.0",
		},
	};
	const tnotif: TypedNotification = {
		jsonrpc: "2.0",
		method: "commandsChanged",
		params: {},
	};
	assert.equal(treq.method, "ping");
});
```

### Integration Points

```yaml
NO external integration points for S4 (it is a pure type module + dev tsconfig edit).
  - No database, config file, routes, env writes, sockets, or package manifest.
  - The module has NO runtime consumers yet — pi-editor-bridge.ts does NOT import it.
INTERNAL consumers (later tasks, NOT this one):
  - M2/S8 onConnection dispatcher      — narrows incoming lines via TypedRequest/TypedNotification.
  - S9 hello handshake                 — HelloParams/HelloResult/JsonRpcError(code:-32600).
  - S11 getSuggestions handler         — GetSuggestionsParams/GetSuggestionsResult.
  - S12 applyCompletion handler        — ApplyCompletionParams/ApplyCompletionResult.
  - S13 shouldTriggerFileCompletion    — ShouldTrigger* params/result.
  - S14 ping/bye/getCommands handlers  — Ping*/Bye*/GetCommands*/CommandInfo.
  - S16 env advertisement              — JSON.stringify(value: BridgeDescriptor).
  - S17 commandsChanged notification   — TypedNotification<"commandsChanged">.
TSCONFIG coupling:
  - S4 adds "protocol.ts" to extension/tsconfig.json `include` so `tsc --noEmit`
    (Level 1 gate) type-checks it. compilerOptions + paths UNCHANGED.
```

## Validation Loop

### Level 1: Syntax & Style (Immediate Feedback) — THE TYPE GATE

```bash
# Type-check protocol.ts + pi-editor-bridge.ts + tests via the paths-mapped dev
# tsconfig. This is the authoritative gate for a types-only task: every envelope,
# per-method type, and mapped-type declaration (incl. the test's type-shape consts)
# must compile. Failures are almost always: a misspelled type name, a missing
# type-only import, a non-literal where a literal was required, or a stray key in a
# Record<string,never>.
tsc --noEmit -p extension/tsconfig.json
# Expected: exit 0, NO output.

# Indentation sanity (S1/S2/S3 + pi examples use TABS):
grep -nP '^    ' extension/protocol.ts && echo "WARN: space-indent lines found" || echo "indent OK (tabs)"

# Confirm protocol.ts is type-only: no value imports, no runtime exports.
grep -nE '^import [^{]|^import .+ from' extension/protocol.ts | grep -v 'import type' \
  && echo "FAIL: found a value (non-type) import" \
  || echo "PASS: only import type present"
grep -nE '^export (const|let|var|function|class|enum|default)' extension/protocol.ts \
  && echo "FAIL: found a runtime export (should be types/re-export only)" \
  || echo "PASS: no runtime exports (types + type-only re-export only)"

# Confirm the re-export exists and targets pi-tui:
grep -n 'export { type AutocompleteItem, type AutocompleteSuggestions } from "@earendil-works/pi-tui"' extension/protocol.ts \
  && echo "PASS: pi-tui re-export present" \
  || echo "FAIL: missing pi-tui re-export"
```

### Level 2: Unit Tests (Component Validation) — THE CONTRACT GATE

```bash
# Zero-dependency TS test runner: Node's built-in node:test, with jiti as the TS
# loader (jiti v2.7.0 nested under pi-coding-agent; borrow its register hook —
# SAME path S2/S3 use).
JITI_REG=/home/dustin/.local/lib/node_modules/@earendil-works/pi-coding-agent/node_modules/jiti/lib/jiti-register.mjs
node --import "$JITI_REG" extension/tests/protocol.test.ts
# Expected: exit 0; final summary shows `pass 2` (or more) and `fail 0`.
# NOTE: jiti v2.7.0 on Node 26 prints a harmless DeprecationWarning
#   ("module.register() is deprecated") to STDERR — IGNORE it; judge by exit code
#   and the `pass`/`fail` lines, not stderr cleanliness.

# Re-run S2 + S3 suites to prove S4 didn't regress them (S4 only ADDS files + edits
# tsconfig include, so these should be unaffected):
node --import "$JITI_REG" extension/tests/provider-capture.test.ts   # S2 — expect fail 0
node --import "$JITI_REG" extension/tests/mode-guard.test.ts         # S3 — expect fail 0
```

### Level 3: Integration Testing (System Validation) — THE REGRESSION GATE

```bash
# protocol.ts is NOT wired into pi-editor-bridge.ts (wiring = M2), so loading the
# extension entry point does NOT exercise protocol.ts. This run therefore proves
# S4 did not REGRESS the entry point: the file still loads via jiti, the S3 TUI
# guard still suppresses the startup log in --print mode, and pi exits 0.
pi --no-extensions -e ./extension/pi-editor-bridge.ts --print "ok" 2>&1 | tee /tmp/pi-editor-bridge-s4.log

# PASS condition 1: pi exited 0.
pi --no-extensions -e ./extension/pi-editor-bridge.ts --print "ok" >/dev/null 2>&1; echo "pi exit=$?"

# PASS condition 2: NO errors during load/handler invocation.
grep -iE "error|cannot|fail|throw|unhandled|is not a function|TypeError" /tmp/pi-editor-bridge-s4.log \
  && echo "FAIL: error present" || echo "PASS: no errors"

# PASS condition 3: the startup log is still ABSENT in print mode (S3 guard intact;
# S4 must not have touched pi-editor-bridge.ts).
grep -c "pi-editor-bridge: session_start (reason=startup" /tmp/pi-editor-bridge-s4.log | grep -q '^0$' \
  && echo "PASS: startup log suppressed in print mode (S3 guard intact)" \
  || echo "FAIL: startup log appeared — S4 may have touched pi-editor-bridge.ts"
# Expected: all three PASS; pi prints "ok" output and exits 0.
```

### Level 4: Creative & Domain-Specific Validation

```bash
# Confirm the module is importable standalone via jiti with NO node_modules at the
# repo top level (the critical runtime invariant — type-only => zero deps):
node --import /home/dustin/.local/lib/node_modules/@earendil-works/pi-coding-agent/node_modules/jiti/lib/jiti-register.mjs \
  -e 'import("./extension/protocol.ts").then(m => { console.log("loaded:", typeof m === "object" && m !== null); console.log("runtime keys:", Object.keys(m).length, "(expect 0 — type-only)"); })'
# Expected: loaded: true ; runtime keys: 0 (type-only module has no runtime exports).

# Cross-check the wire shapes against the JSON-RPC 2.0 spec convention: error must be
# {code,message} with no data field, and -32600 is the handshake "bad token" code.
grep -nE 'code: -32600|interface JsonRpcError' extension/protocol.ts   # doc/JSDoc reference only
grep -c 'data' extension/protocol.ts | grep -qE '^0$' \
  && echo "PASS: no 'data' field anywhere (error is {code,message} only)" \
  || echo "WARN: 'data' substring present (check it's not an error.data field)"

# Confirm the global-load path still works (simulates end-user install of the entry
# point; protocol.ts is not installed separately yet, but the entry point must load):
mkdir -p ~/.pi/agent/extensions
cp extension/pi-editor-bridge.ts ~/.pi/agent/extensions/pi-editor-bridge.ts
pi --print "ok" 2>&1 | grep -E "error|cannot|fail" && echo "FAIL" || echo "PASS: global-load OK"
rm -f ~/.pi/agent/extensions/pi-editor-bridge.ts   # clean up (don't leave installed during dev)
```

## Final Validation Checklist

### Technical Validation

- [ ] Level 1 (TYPE GATE): `tsc --noEmit -p extension/tsconfig.json` → exit 0, no output.
- [ ] Level 2 (CONTRACT GATE): `node --import <jiti-register> extension/tests/protocol.test.ts`
      → exit 0, `fail 0` (`pass` ≥ 2); S2 + S3 suites still green.
- [ ] Level 3 (REGRESSION GATE): `pi --no-extensions -e ./extension/pi-editor-bridge.ts --print "ok"`
      exits 0 with NO error lines AND the startup-log line ABSENT in print mode (S3 intact).
- [ ] Level 4: standalone jiti import loads with 0 runtime keys (type-only); error has no `data` field.

### Feature Validation

- [ ] `extension/protocol.ts` exports every type in Deliverable #1 with exact names/shapes.
- [ ] `jsonrpc` literal `"2.0"`; `id: string`; `JsonRpcError = {code:number; message:string}` (no `data`);
      raw `params?`/`result?` are `unknown`.
- [ ] `ok: true` literal on `HelloResult`/`PingResult`/`ByeResult`.
- [ ] Empty params/results are `Record<string, never>` (PingParams, GetCommandsParams,
      CommandsChangedParams, ByeParams).
- [ ] `BridgeDescriptor` has 7 fields incl. `transport:"unix"` and `serverVersion` (no `version`).
- [ ] `CommandInfo = {name; description?; argumentHint?}`; JSDoc states bridge-local, excludes
      pi-internal fields.
- [ ] `BridgeMethod` = 8 members; `RequestMethod` excludes `commandsChanged`; `NotificationMethod`
      = `"commandsChanged"`; `BridgeResultMap` omits `commandsChanged`.
- [ ] pi-tui `AutocompleteItem` + `AutocompleteSuggestions` re-exported (used locally too).
- [ ] `extension/tsconfig.json` `include` contains `"protocol.ts"` (paths unchanged).
- [ ] `pi-editor-bridge.ts` is UNCHANGED (wiring = M2).

### Code Quality Validation

- [ ] Type-only module: no value imports, no runtime exports (types + one type-only re-export).
- [ ] TAB indentation; `import type` for every import (matches S1/S2/S3 + pi examples).
- [ ] Mode-A JSDoc on each exported type explaining its wire role; file header cites PRD §5 + jsonl.js.
- [ ] Method-union members use exact PRD §5.4 strings (full camelCase: `shouldTriggerFileCompletion`,
      `getCommands`, `commandsChanged`).
- [ ] Test type-shape consts declared inside test bodies (not module-level unused locals).

### Documentation & Deployment

- [ ] File-level JSDoc cites PRD §5 (wire spec) + `dist/modes/rpc/jsonl.js` (framing mirror for S7).
- [ ] JSDoc notes the `transport:"unix"` discriminated-union extension point (future TCP).
- [ ] JSDoc on `cursorCol` documents it is a UTF-16 offset (conversion lives in Lua coords, S28/S29).
- [ ] No new env vars WRITTEN (S4 only types the future `BridgeDescriptor`).
- [ ] No package.json/README added (packaging = S18).

---

## Anti-Patterns to Avoid

- ❌ Don't redeclare `AutocompleteItem`/`AutocompleteSuggestions` — RE-EXPORT them from
  `@earendil-works/pi-tui` (and import locally for use). Redclaring risks drift from pi's engine.
- ❌ Don't make `jsonrpc` a plain `string`, `id` a `string|number|null`, or add a `data` field to
  `JsonRpcError`. PRD §5 pins these; literals give compile-time guarantees.
- ❌ Don't type `ok` as `boolean` — it must be the literal `true` so "success requires ok=true" is
  enforced at compile time.
- ❌ Don't use `{}` for empty params/results — it means "any non-nullish". Use `Record<string, never>`.
- ❌ Don't name the descriptor version field `version` — use `serverVersion` (item contract + §6.4);
  PRD §4's `"version"` is a doc inconsistency.
- ❌ Don't add `commandsChanged` to `BridgeResultMap` — it's a notification with no result. It belongs
  only in `BridgeParamsMap` + `NotificationMethod` + `TypedNotification`.
- ❌ Don't add any runtime const/enum/function (e.g. an error-code map). S4 is types-only; the code
  map is S9/S15's job. A type-only module loads with zero deps (PRD §6.7).
- ❌ Don't import `CommandInfo` from pi — it doesn't exist there (only `SlashCommandInfo`, which leaks
  internal paths). Define the lean bridge-local shape.
- ❌ Don't implement JSONL framing, a socket server, an env-var write, or a `package.json`. Those are
  S7 / M2 / S16 / S18 respectively. S4 is the type contract ONLY.
- ❌ Don't touch `pi-editor-bridge.ts` — wiring the protocol types into the extension is M2. S4 leaves
  the entry point (incl. the S3 guard + S2 capture) byte-for-byte unchanged.
- ❌ Don't edit the tsconfig `paths` — it already maps `@earendil-works/pi-tui` (added by S2). S4's only
  tsconfig change is adding `"protocol.ts"` to `include`.
- ❌ Don't widen `params?`/`result?` to `any` on the raw envelopes — use `unknown` so consumers must narrow.
