---
name: "P1.M1.T2.S1 — Define JSON-RPC envelope, method, and bridge descriptor types"
description: |
  CREATE `extension/protocol.ts` — a **types-only** TypeScript module that is the
  single source of truth for the pi-editor-bridge IPC wire contract (PRD §5).
  It exports: (a) the three raw JSON-RPC 2.0 envelopes
  (`JsonRpcRequest`/`JsonRpcResponse`/`JsonRpcNotification`) with `string` `id`,
  `method: string`, `params?: unknown`, and error `{ code: number; message: string }`;
  (b) `BridgeDescriptor` (`{ transport:"unix"; path; token; pid; cwd; fdAvailable;
  serverVersion }`) JSON-serialized later to `process.env.PI_NVIM_BRIDGE`; (c) a
  `BridgeMethod` name union + named params/result interfaces for all 8 §5.4 methods
  (`hello`, `ping`, `getSuggestions`, `applyCompletion`,
  `shouldTriggerFileCompletion`, `getCommands`, `commandsChanged`, `bye`) matching
  the table EXACTLY; (d) mapped-type dispatch layer (`BridgeParams<M>` /
  `BridgeResult<M>` + `TypedRequest/Response/Notification`) that gives the IPC
  layer "full type safety"; (e) a lean bridge-local `CommandInfo` type (NOT from
  pi — `CommandInfo` does not exist there; closest is `SlashCommandInfo` which
  leaks internal `sourceInfo`); and (f) type-only re-exports of
  `AutocompleteItem` + `AutocompleteSuggestions` from `@earendil-works/pi-tui`.
  Deliverable ALSO: add `"protocol.ts"` to `extension/tsconfig.json` `include`
  (one-line, additive — safe vs. the in-parallel S3 task which does not touch
  tsconfig), and a `node:test` suite (`extension/tests/protocol.test.ts`) that
  proves the module loads via jiti with zero runtime deps AND exercises every
  type. This task is NARROW: NO socket server (M2), NO env-var write (S16), NO
  wiring of `protocol.ts` into `pi-editor-bridge.ts`, NO runtime values in
  protocol.ts (types-only), NO framing reader (S7).
---

## Goal

**Feature Goal**: A self-contained, types-only `extension/protocol.ts` that is
the authoritative wire contract for the entire pi-editor-bridge IPC layer, so
that every later task — the M2 socket server (`onConnection`/dispatcher S8,
handshake S9, RPC handlers S11–S14), the S16 `PI_NVIM_BRIDGE` env-var
advertisement, and the S15 JSON-RPC error wrapping — imports these exact types
instead of re-deriving shapes. The module provides the three raw JSON-RPC 2.0
envelopes (the parse targets for a JSONL line), a `BridgeDescriptor` for the env
advertisement, a `BridgeMethod` union + per-method params/result types matching
PRD §5.4 verbatim, and a mapped-type dispatch layer (`BridgeParams<M>` /
`BridgeResult<M>` / `TypedRequest` / `TypedResponse` / `TypedNotification`) that
narrows the raw envelopes into method-safe shapes. Verifiable by (a) `tsc
--noEmit` clean over `extension/` (including `protocol.ts`), (b) a `node:test`
suite proving the module imports under jiti with zero runtime deps, and (c)
compile-time + runtime assertions exercising every exported type.

**Deliverable** (all under `extension/`):
1. **CREATE** `extension/protocol.ts` — types-only module exporting:
   - `JsonRpcError` = `{ code: number; message: string }`.
   - `JsonRpcRequest` (raw) = `{ jsonrpc: "2.0"; id: string; method: string; params?: unknown }`.
   - `JsonRpcResponse` (raw) = `{ jsonrpc: "2.0"; id: string; result?: unknown } | { jsonrpc: "2.0"; id: string; error: JsonRpcError }`.
   - `JsonRpcNotification` (raw) = `{ jsonrpc: "2.0"; method: string; params?: unknown }`.
   - `JsonRpcMessage` = `JsonRpcRequest | JsonRpcResponse | JsonRpcNotification` (umbrella for "any parsed line").
   - `BridgeTransport` = `"unix"` (v1 literal).
   - `BridgeDescriptor` = `{ transport: "unix"; path: string; token: string; pid: number; cwd: string; fdAvailable: boolean; serverVersion: string }`.
   - Per-method params/result interfaces: `HelloParams/Result`, `PingParams/Result`, `GetSuggestionsParams/Result`, `ApplyCompletionParams/Result`, `ShouldTriggerFileCompletionParams/Result`, `GetCommandsParams/Result`, `CommandsChangedParams`, `ByeParams/Result`.
   - `CommandInfo` = `{ name: string; description?: string; argumentHint?: string }` (bridge-local; see Why).
   - `BridgeMethod` (8-member string-literal union), `RequestMethod` (C→S, 7 members), `NotificationMethod` (`"commandsChanged"`).
   - `BridgeParamsMap` + `BridgeResultMap` interfaces, `BridgeParams<M>` + `BridgeResult<M>` aliases, and `TypedRequest<M>` / `TypedResponse<M>` / `TypedNotification<M>` narrowed envelopes.
   - `export { type AutocompleteItem, type AutocompleteSuggestions } from "@earendil-works/pi-tui";` (type-only re-export).
   - Mode-A JSDoc on EVERY exported type explaining its wire-format role (item DOCS requirement).
2. **MODIFY** `extension/tsconfig.json` — add `"protocol.ts"` to the `include`
   array (so `tsc --noEmit` checks it standalone). No other change. (The S2-added
   `paths` for `@earendil-works/pi-tui` already resolves the re-export.)
3. **CREATE** `extension/tests/protocol.test.ts` — a `node:test` suite that (a)
   dynamically imports `../protocol.ts` via jiti and asserts it loads without
   throwing (proves zero runtime deps), and (b) declares sample objects typed
   against every envelope + every per-method type + the mapped types (validated
   by `tsc`) and asserts representative field values at runtime.

**Success Definition**:
- `tsc --noEmit -p extension/tsconfig.json` → exit 0, no output (proves the
  pi-tui re-export resolves via the existing `paths`, every type is internally
  consistent, and the mapped types narrow correctly).
- `node --import <jiti-register.mjs> extension/tests/protocol.test.ts` → exit 0,
  `fail` 0, `pass` ≥ 2.
- `pi --no-extensions -e ./extension/pi-editor-bridge.ts --print "ok"` still
  exits 0 with no error lines (S1 does NOT touch the extension entry point, so
  the existing extension must load exactly as before — regression guard).
- `protocol.ts` contains NO value exports (only `interface`/`type`/type-only
  re-exports) — verified by grep, and by the fact that the module namespace is
  empty at runtime.

## User Persona (if applicable)

**Target User**: The bridge-extension author + every downstream IPC implementer
(M2 socket/RPC tasks S5–S15, S16 env advertisement, and the Lua client side via
JSON). This task is developer infrastructure: a shared types module.

**Use Case**: When the M2 `onConnection` handler (S8) reads a JSONL line and
parses it, it narrows `JsonRpcMessage` → `JsonRpcRequest`, switches on
`method`, then narrows `params` via `BridgeParams<typeof method>` and returns a
`BridgeResult<typeof method>` — all type-checked against THIS module. The S16
task builds a `BridgeDescriptor` literal and `JSON.stringify`s it to
`process.env.PI_NVIM_BRIDGE`. Without a single source of truth, each task
re-derives the wire shapes and drifts.

**Pain Points Addressed**: PRD §5 specifies the protocol prose + a table; without
a typed module, the M2 handlers would hand-roll `any`-typed params and the
descriptor would be an ad-hoc object literal. A typed `protocol.ts` makes the
contract compile-time-enforced and gives the Lua side a stable JSON shape to
`vim.json.decode`.

## Why

- **Single source of truth for a transport-agnostic contract (PRD §5).** The
  protocol is consumed by two independent codebases (the TS extension + the Lua
  plugin) and across ~10 future tasks. Centralizing the envelopes + method
  shapes in one types-only module prevents drift and lets every task import
  exact types.
- **`CommandInfo` does NOT exist in pi — we must define it.** Verified:
  `grep -rn "CommandInfo"` over `dist/` + nested pi-tui (minus `.map`) returns
  only `SlashCommandInfo` (`slash-commands.d.ts:3`), `getCommands():
  SlashCommandInfo[]` (`types.d.ts:923`), and `GetCommandsHandler = () =>
  SlashCommandInfo[]` (`types.d.ts:1107`). `SlashCommandInfo` carries `source:
  SlashCommandSource; sourceInfo: SourceInfo` (internal file paths) — unsuitable
  for the wire. The bridge's optional `getCommands` "richer docs menus" feature
  (PRD §5.4) needs a LEAN `{ name; description?; argumentHint? }` mirroring the
  user-facing slice of pi-tui's `SlashCommand`/`BuiltinSlashCommand`. S1 defines
  that local `CommandInfo`; S14 maps pi's `SlashCommandInfo[]` DOWN to it.
- **Re-export convenience (item contract INPUT).** pi's `AutocompleteItem` /
  `AutocompleteSuggestions` live in `@earendil-works/pi-tui`
  (`autocomplete.d.ts:99-119`, re-exported at `index.d.ts:1`). Re-exporting them
  from `protocol.ts` means RPC handlers import completion types + protocol types
  from ONE place.
- **Foundation for M2's typed dispatcher.** The mapped-type layer
  (`BridgeParams<M>` / `BridgeResult<M>`) lets S8's dispatcher be written as a
  generic switch whose branches are type-safe per method — the "full type safety
  for the IPC layer" the item OUTPUT requires.
- **JSON-RPC 2.0 for future-proofing (PRD §5.3).** The envelopes are standard
  JSON-RPC 2.0 (string `id` per PRD §5); pinning `jsonrpc: "2.0"` as a literal
  type makes a malformed version a compile error in any sample object.

## What

A new `extension/protocol.ts` containing ONLY TypeScript types (interfaces, type
aliases, and one type-only re-export) plus Mode-A JSDoc. No runtime values, no
framing code, no socket code. The `extension/tsconfig.json` `include` gains one
entry. A `node:test` suite proves loadability + exercises the types.

### Success Criteria

- [ ] `extension/protocol.ts` exists and exports EXACTLY the types listed in the
      Goal (raw envelopes, descriptor, per-method params/results, `CommandInfo`,
      method unions, mapped types, typed envelopes) plus the type-only
      re-export of `AutocompleteItem` + `AutocompleteSuggestions`.
- [ ] The three raw envelopes match the item contract (a)(b)(c) byte-for-byte:
      `jsonrpc: "2.0"` LITERAL, `id: string`, `method: string`, `params?:
      unknown`, error `{ code: number; message: string }` (NO `data` field).
- [ ] `BridgeDescriptor` matches item contract (d) exactly: `{ transport:
      "unix"; path: string; token: string; pid: number; cwd: string;
      fdAvailable: boolean; serverVersion: string }`.
- [ ] Per-method params/result types match PRD §5.4 table EXACTLY (field names,
      optionality, types): `hello`/`ping`/`bye` results use literal `ok: true`;
      `getSuggestions` result is `AutocompleteSuggestions | null`;
      `applyCompletion` result is `{ lines; cursorLine; cursorCol }`;
      `shouldTriggerFileCompletion` result is `boolean`; `getCommands` result is
      `{ commands: CommandInfo[] }`; empty params use `Record<string, never>`.
- [ ] `CommandInfo` is defined as `{ name: string; description?: string;
      argumentHint?: string }` with JSDoc noting it is bridge-local (not from
      pi) and excludes `sourceInfo`/`handler` deliberately.
- [ ] `BridgeMethod` is the 8-member union; `RequestMethod` excludes
      `commandsChanged`; `NotificationMethod` is `"commandsChanged"`.
      `BridgeResultMap` OMITS `commandsChanged` (no result). Mapped aliases
      `BridgeParams<M>` / `BridgeResult<M>` and typed envelopes
      `TypedRequest`/`TypedResponse`/`TypedNotification` compile and narrow.
- [ ] `protocol.ts` re-exports `type AutocompleteItem, type AutocompleteSuggestions`
      from `@earendil-works/pi-tui` (type-only).
- [ ] `protocol.ts` has NO value exports (only `interface`/`type` + type-only
      re-export) — `grep -nE 'export (const|let|var|function|class|enum|default)'
      protocol.ts` returns nothing.
- [ ] Mode-A JSDoc on EVERY exported type explaining its wire-format role.
- [ ] `extension/tsconfig.json` `include` contains `"protocol.ts"` (alongside
      the existing `"pi-editor-bridge.ts"` and `"tests/**/*.ts"`); no other
      tsconfig change.
- [ ] `extension/tests/protocol.test.ts` exists and passes: dynamically imports
      `../protocol.ts` without throwing; declares sample objects typed against
      every envelope + per-method type + mapped types; asserts field values.
- [ ] `tsc --noEmit -p extension/tsconfig.json` → exit 0, no output.
- [ ] `node --import <jiti-register> extension/tests/protocol.test.ts` → exit 0,
      `fail` 0.
- [ ] `pi --no-extensions -e ./extension/pi-editor-bridge.ts --print "ok"` exits
      0 with no error lines (regression guard — S1 does not touch the entry point).
- [ ] NO socket server / env write / framing reader / wiring into
      `pi-editor-bridge.ts` added (those are M2 / S16 / S7).

## All Needed Context

### Context Completeness Check

_Pass test_: An agent who has never seen this repo, given this PRP (which
embeds the EXACT type definitions, the verified file:line citations, the tsconfig
diff, and the test skeleton), can (1) create `protocol.ts` by transcribing the
types, (2) make the one-line tsconfig edit, (3) write the test from the supplied
skeleton, and (4) run the three validation commands to green — with every type
name, import source, line citation, and gotcha listed here.

### Documentation & References

```yaml
# MUST READ — the authoritative type sources (installed dist; line-cited)
- file: /home/dustin/.local/lib/node_modules/@earendil-works/pi-coding-agent/node_modules/@earendil-works/pi-tui/dist/autocomplete.d.ts
  why: exact AutocompleteItem / AutocompleteSuggestions / AutocompleteProvider shapes to re-export + to type getSuggestions/applyCompletion params/results
  section: "L99-102 AutocompleteItem { value; label; description? }; L116-119 AutocompleteSuggestions { items: AutocompleteItem[]; prefix: string }; L121-144 AutocompleteProvider (applyCompletion returns { lines; cursorLine; cursorCol })"
  critical: |
    AutocompleteItem/Suggestions are EXPORTED from pi-tui (index.d.ts:1 re-exports
    them as types). Re-export them TYPE-ONLY from protocol.ts:
      export { type AutocompleteItem, type AutocompleteSuggestions } from "@earendil-works/pi-tui";
    The applyCompletion RESULT { lines; cursorLine; cursorCol } is NOT a named
    export — define ApplyCompletionResult locally as that object type.

- file: /home/dustin/.local/lib/node_modules/@earendil-works/pi-coding-agent/node_modules/@earendil-works/pi-tui/dist/index.d.ts
  why: confirms the exact re-export line available (what symbols pi-tui exposes)
  section: "L1: export { type AutocompleteItem, type AutocompleteProvider, type AutocompleteSuggestions, CombinedAutocompleteProvider, type SlashCommand } from \"./autocomplete.ts\";"

# MUST READ — proof CommandInfo does NOT exist + what the closest pi types are
- file: /home/dustin/.local/lib/node_modules/@earendil-works/pi-coding-agent/dist/core/extensions/types.d.ts
  why: shows getCommands() returns SlashCommandInfo[] (L923) and there is NO CommandInfo; SlashCommandInfo (slash-commands.d.ts:3) has source/sourceInfo we must NOT ship
  section: "L824 RegisteredCommand { name; sourceInfo; description?; getArgumentCompletions?; handler }; L923 getCommands(): SlashCommandInfo[]; L1107 GetCommandsHandler = () => SlashCommandInfo[]"
  critical: |
    Verified `grep -rn CommandInfo` (minus .map) over dist + nested pi-tui returns
    ONLY SlashCommandInfo / getCommands(): SlashCommandInfo[] / GetCommandsHandler.
    => CommandInfo is BRIDGE-LOCAL. Define { name; description?; argumentHint? }
    (the user-facing slice of BuiltinSlashCommand/SlashCommand). Do NOT import
    SlashCommandInfo into protocol.ts — it leaks sourceInfo (internal paths) and
    a handler; the wire shape must be plain JSON.

# MUST READ — ExtensionContext.cwd source for the descriptor (runtime value; type is just string)
- file: /home/dustin/.local/lib/node_modules/@earendil-works/pi-coding-agent/dist/core/extensions/types.d.ts
  why: confirms ctx.cwd: string is available for BridgeDescriptor.cwd (S16 computes it; S1 only declares the type)
  section: "L216 (inside ExtensionContext): cwd: string;"

# MUST READ — pi VERSION export (candidate serverVersion value; S1 only declares the type field)
- file: /home/dustin/.local/lib/node_modules/@earendil-works/pi-coding-agent/dist/config.d.ts
  why: export declare const VERSION: string (pkg.version || "0.0.0") — a valid serverVersion source for S16/M2; S1's descriptor field is just `serverVersion: string`
  section: "L69: export declare const VERSION: string;"

# MUST READ — pi's OWN JSONL framing (the MIRROR reference for §5.2; S1 cites it in JSDoc, S7 implements the reader)
- file: /home/dustin/.local/lib/node_modules/@earendil-works/pi-coding-agent/dist/modes/rpc/jsonl.js
  why: PRD §5.2 says "Mirror pi RPC's framing rules"; this IS that reference (LF-only split, strip trailing \r, do NOT use readline)
  section: "serializeJsonLine = `${JSON.stringify(value)}\\n`; attachJsonlLineReader buffers with StringDecoder('utf8'), splits on buffer.indexOf('\\n') only, strips one trailing \\r, explicitly avoids Node readline (which splits on U+2028/U+2029)"
  critical: |
    S1 is TYPES-ONLY — it implements NO framing. Cite this file in the module
    JSDoc so S7 (JSONL line reader) has the authoritative mirror. Do not import
    it (runtime .js; not needed for types).

# MUST READ — the PRD protocol section (the spec this module encodes)
- docfile: PRD.md
  why: §5.1-5.5 (transport, framing, handshake, methods table, timing) + §6.4 (BridgeDescriptor reference) + §8 (coordinate semantics)
  section: "§5.3 (envelopes + handshake), §5.4 (methods table — transcribe EXACTLY), §5.5 (AbortController/timing — relevant to getSuggestions force param), §6.4 (descriptor fields incl serverVersion '0.1.0'), §8 (cursorLine 0-indexed, cursorCol 0-indexed UTF-16)"
  critical: |
    The §5.4 table is the contract for per-method params/results — match field
    names, optionality (force?, client?, clientVersion?, description?), and types
    byte-for-byte. §5.3 error example uses code -32600 "bad token" (JSON-RPC
    Invalid Request) — document standard codes in JSDoc but do NOT add a runtime
    const map (S9/S15's job).

# MUST READ — the immediately-preceding task's PRP (the post-S3 baseline this task starts from)
- docfile: plan/001_c56962b4fa17/P1M1T1S3/PRP.md
  why: defines the post-S3 shape of extension/pi-editor-bridge.ts (TUI guard + captureProvider) and the tsconfig S1 inherits — S1 must NOT conflict with it
  section: "Implementation Patterns & Key Details (post-S3 session_start handler) + the tsconfig (paths already map pi-tui)"
  critical: |
    S1 runs IN PARALLEL with S3. S1 does NOT edit pi-editor-bridge.ts. The ONLY
    shared file S1 touches is extension/tsconfig.json, and ONLY by appending
    "protocol.ts" to include — an additive change that cannot conflict with S3
    (S3 does not touch tsconfig). Re-verify the include line before editing in
    case S3 already merged.

# SUPPORTING — pre-researched architecture (project-local)
- docfile: plan/001_c56962b4fa17/architecture/research-pi-autocomplete.md
  why: file:line-verified AutocompleteItem/Suggestions/Provider shapes + CombinedAutocompleteProvider; fdAvailable source (ensureTool('fd'))
  section: "§1 autocomplete engine types (L99-144), fdPath via ensureTool('fd')"
- docfile: plan/001_c56962b4fa17/architecture/external_deps.md
  why: §1.1 documents UTF-16 cursorCol semantics (pi cursorCol = 0-indexed UTF-16) referenced in JSDoc; §4 confirms the extension factory pattern
  section: "§1.1 str_utfindex/str_byteindex UTF-16 conversion; §4 pi extension API factory"

# SUPPORTING — local research notes for S1 (this task) — every claim re-verified against the installed dist
- docfile: plan/001_c56962b4fa17/P1M1T2S1/research/notes.md
  why: exact type transcriptions, the CommandInfo-absence proof, the two-layer (raw+narrowed) envelope design rationale, mapped-type design, test strategy, validation commands
```

### Current Codebase tree (assumes S1+S2+S3 completed — the baseline for this task)

```bash
extension/
├── pi-editor-bridge.ts   # (S1+S2+S3) default-export factory + session_start (TUI guard + log + captureProvider) + session_shutdown (no-op) + captureProvider/getProvider/liveProvider + JSDoc header
├── tsconfig.json         # (S1+S2) dev-only; paths map @earendil-works/pi-coding-agent AND @earendil-works/pi-tui (nested); include = ["pi-editor-bridge.ts","tests/**/*.ts"]
└── tests/
    ├── provider-capture.test.ts   # (S2) node:test suite for captureProvider/getProvider
    └── mode-guard.test.ts         # (S3) node:test suite for the TUI guard
# (plan/ holds planning artifacts only — no other source code)
```

### Desired Codebase tree with files to be added/modified

```bash
extension/
├── pi-editor-bridge.ts            # (UNCHANGED — S1 does NOT touch the entry point)
├── protocol.ts                    # (CREATE) types-only IPC wire-contract module
├── tsconfig.json                  # (MODIFY) include += "protocol.ts"  (one line, additive)
└── tests/
    ├── provider-capture.test.ts   # (UNCHANGED — S2)
    ├── mode-guard.test.ts         # (UNCHANGED — S3)
    └── protocol.test.ts           # (CREATE) node:test: dynamic-import load + per-type sample objects
```

**File responsibilities**
- `extension/protocol.ts` — the single source of truth for the IPC wire shapes.
  Types-only: consumed (later) by M2's socket server/dispatcher, S16's env
  advertisement, S15's error wrapping, and (via JSON) the Lua client. Standalone:
  imports nothing at runtime (all `import type` + a type-only re-export), so it
  loads via jiti with zero node_modules at the repo top level.
- `extension/tsconfig.json` — gains `"protocol.ts"` in `include` so `tsc
  --noEmit` checks the new module standalone (the test import would pull it in
  anyway, but explicit listing matches the S1/S2 convention for source files).
- `extension/tests/protocol.test.ts` — proves (a) the module loads under jiti
  with zero deps (critical runtime invariant) and (b) every type is usable +
  internally consistent (compile-time gate via `tsc`, with a few runtime
  `assert`s for signal).

### Known Gotchas of our codebase & Library Quirks

```typescript
// CRITICAL: protocol.ts must be TYPES-ONLY. NO value exports (no const/let/var/
//   function/class/enum/default). All exports are `interface`/`type`/type-only
//   re-export. Reason: (1) the module must load via jiti with ZERO node_modules
//   at the repo top level (PRD §6.7) — `import type` is erased at runtime; (2)
//   a const error-code map would be useful but is S9/S15's job, not S1's. Verify
//   with: grep -nE 'export (const|let|var|function|class|enum|default)' protocol.ts
//   (must return nothing).

// CRITICAL: the re-export is TYPE-ONLY and uses the `export { type X }` form:
//     export { type AutocompleteItem, type AutocompleteSuggestions } from "@earendil-works/pi-tui";
//   Do NOT use `export * from` (pulls CombinedAutocompleteProvider, a runtime
//   class, into the module → breaks zero-deps). Do NOT re-export AutocompleteProvider
//   here (pi-editor-bridge.ts already imports it directly from pi-tui; re-exporting
//   would be redundant scope). Re-export ONLY the two the contract names.

// CRITICAL: `jsonrpc: "2.0"` is a STRING LITERAL type, not `string`. Same for
//   `transport: "unix"` and the `ok: true` literal on hello/ping/bye results.
//   These literals make malformed sample objects a compile error. Do not relax
//   them to `string`/`boolean`.

// CRITICAL: `id` is `string` ONLY (PRD §5: "string id"). Do NOT widen to
//   `string | number | null` (vanilla JSON-RPC permits those, but pi-editor-bridge
//   restricts to string — keep it narrow so the wire stays predictable).

// CRITICAL: the raw envelopes use `method: string` and `params?: unknown`
//   (NOT the narrowed BridgeMethod/params). The raw envelopes are the PARSE
//   TARGETS for a JSONL line (you don't know the method until you read it).
//   Method-based narrowing is the SEPARATE Typed* layer (TypedRequest etc.),
//   which takes a generic <M>. Do not collapse the two layers — both are needed:
//   raw for parsing, typed for dispatch.

// CRITICAL: empty params `{}` → use `Record<string, never>` (the correct TS
//   "empty object" type). Do NOT use `{}` (means "any non-nullish value" —
//   unsafe) and do NOT use an empty `interface X {}` (lint-discouraged). An
//   object literal `{}` IS assignable to Record<string, never>.

// CRITICAL: `commandsChanged` is a NOTIFICATION (S→C, no id, no result). It
//   must appear in BridgeMethod, NotificationMethod, and BridgeParamsMap, but
//   must be OMITTED from BridgeResultMap and RequestMethod. Including it in
//   BridgeResultMap would force a fake result type.

// CRITICAL: `CommandInfo` is bridge-LOCAL. Do NOT import SlashCommandInfo from
//   pi-coding-agent into protocol.ts (it carries sourceInfo = internal file
//   paths + is not plain-JSON-safe). Define CommandInfo = { name; description?;
//   argumentHint? }. JSDoc must state: bridge-local, maps FROM pi's
//   SlashCommandInfo[]/BuiltinSlashCommand[] in S14 by stripping sourceInfo/handler.

// STYLE: TABS for indentation (match pi-editor-bridge.ts + pi examples). Mode-A
//   JSDoc on EVERY exported type (item DOCS requirement) explaining its
//   wire-format role (what it represents on the wire, who sends/receives it).

// SCOPE: do NOT wire protocol.ts into pi-editor-bridge.ts (M2 does that), do NOT
//   add socket/env/framing code, do NOT add runtime values, do NOT change the
//   tsconfig `paths` (S2 already mapped pi-tui). The ONLY tsconfig change is
//   appending "protocol.ts" to `include`.

// TEST: protocol.test.ts must (a) `await import("../protocol.ts")` and assert it
//   resolves (the module namespace may be EMPTY at runtime since all exports are
//   types — assert "did not throw", not "export X defined"); and (b) declare
//   sample objects typed against every envelope + per-method type + mapped types
//   (these are COMPILE-TIME checks enforced by `tsc --noEmit`; add a few
//   `assert.equal` calls on field values for runtime signal). Dynamic import
//   (not static) is preferred so the load test is explicit and isolated.
```

## Implementation Blueprint

### Data models and structure

This task IS the data-model definition. Every type lives in
`extension/protocol.ts`. The complete, transcription-ready type definitions are
in **Implementation Patterns & Key Details** below — copy them verbatim, then
add Mode-A JSDoc to each.

### Implementation Tasks (ordered by dependencies)

```yaml
Task 1: CREATE extension/protocol.ts  (types-only module)
  - TRANSCRIBE the types from "Implementation Patterns & Key Details" below
      verbatim (envelopes, descriptor, per-method params/results, CommandInfo,
      method unions, mapped types, typed envelopes, type-only re-export).
  - ADD a file-level JSDoc header explaining: this is the single source of truth
      for the IPC wire contract (PRD §5); types-only (loads with zero deps);
      raw envelopes are parse targets, Typed* envelopes are for narrowed
      dispatch; framing is LF-only JSONL mirroring pi's modes/rpc/jsonl.js
      (implemented in S7, NOT here); two codebases consume this (TS extension +
      Lua plugin via JSON).
  - ADD a Mode-A JSDoc to EVERY exported type explaining its wire-format role
      (who sends it, what it carries, examples where helpful). Cite PRD §5.x.
  - IMPORTS: only `import type` if needed (none required — all types are local
      or come via the type-only re-export `export { type ... } from`). Do NOT
      add `import type { AutocompleteItem } from "@earendil-works/pi-tui"` AND
      a re-export — use the re-export form alone (it makes the symbol available
      to importers without a separate import line in this file). If you reference
      AutocompleteItem/Suggestions in the per-method interfaces (GetSuggestionsResult,
      ApplyCompletionParams), they are in scope via the re-export.
  - NAMING: interfaces PascalCase (JsonRpcRequest, HelloParams, BridgeDescriptor,
      CommandInfo). Method-name union members are the EXACT PRD §5.4 strings
      ("shouldTriggerFileCompletion", "getCommands", "commandsChanged").
  - INDENTATION: TABS (match pi-editor-bridge.ts + examples).
  - PLACEMENT: extension/protocol.ts (per item contract).
  - VERIFY no value exports: grep -nE 'export (const|let|var|function|class|enum|default)' extension/protocol.ts → empty.

Task 2: MODIFY extension/tsconfig.json  (add protocol.ts to include)
  - EDIT the `include` array from ["pi-editor-bridge.ts", "tests/**/*.ts"]
      to ["pi-editor-bridge.ts", "protocol.ts", "tests/**/*.ts"].
  - DO NOT: change compilerOptions, paths, target, module, strict, noEmit, or
      anything else. This is a ONE-LINE additive edit.
  - JUSTIFICATION: makes `tsc --noEmit` check protocol.ts standalone (the test
      import would pull it in anyway, but explicit listing matches S1/S2
      convention and lets you type-check protocol.ts before the test exists).
  - CONFLICT CHECK: re-read the current include line before editing (S3 may have
      merged first). S3 does NOT touch tsconfig, so the only change should be
      appending "protocol.ts"; but verify and merge cleanly.

Task 3: CREATE extension/tests/protocol.test.ts  (node:test + jiti)
  - IMPLEMENT: node:test suite using `node:test` + `node:assert/strict`.
  - IMPORTS:
      import { test } from "node:test";
      import assert from "node:assert/strict";
      import type { ...all the protocol types... } from "../protocol.ts";
  - TEST 1 ("loads via jiti with zero runtime deps"):
      const mod = await import("../protocol.ts");  // dynamic import — must not throw
      assert.equal(typeof mod, "object");          // namespace exists (may be empty)
      // The module is types-only, so mod may have NO own keys — that's correct.
      // The assertion is purely "did not throw + is a module object".
  - TEST 2 ("every envelope and per-method type is structurally sound"):
      declare const sample objects (see skeleton) typed against:
        - JsonRpcRequest / JsonRpcResponse (both success+error arms) / JsonRpcNotification / JsonRpcMessage
        - BridgeDescriptor
        - HelloParams, HelloResult, PingResult, GetSuggestionsParams, GetSuggestionsResult,
          ApplyCompletionParams, ApplyCompletionResult, ShouldTriggerFileCompletionResult,
          CommandInfo, GetCommandsResult, ByeResult
        - TypedRequest<"getSuggestions">, BridgeParams<"hello">, BridgeResult<"ping">, etc.
      For a representative subset, assert.equal on a field value (runtime signal).
      These declarations are primarily COMPILE-TIME checks (validated by tsc in
      Level 1); the asserts give a runtime heartbeat.
  - NAMING: test("protocol.ts loads via jiti with zero runtime deps", ...) etc.
  - PLACEMENT: extension/tests/ (alongside S2/S3 tests).
  - NO CONCURRENCY: default sequential execution.

Task 4: VALIDATE — run the three validation commands; fix until all green
  - RUN (Level 1): `tsc --noEmit -p extension/tsconfig.json` (expect exit 0, no output)
  - RUN (Level 2): `node --import <jiti-register.mjs> extension/tests/protocol.test.ts` (expect exit 0, fail 0)
  - RUN (Level 3): `pi --no-extensions -e ./extension/pi-editor-bridge.ts --print "ok" 2>&1 | grep -iE "error|cannot|fail|throw|TypeError"` (expect NO match — regression guard)
```

### Implementation Patterns & Key Details

```typescript
// === extension/protocol.ts — COMPLETE, transcription-ready (add JSDoc to each) ===
//
// File-level JSDoc (write this):
//   protocol.ts — single source of truth for the pi-editor-bridge IPC wire
//   contract (PRD §5). TYPES-ONLY: every export is an interface/type alias or a
//   type-only re-export, so this module loads via jiti with ZERO node_modules at
//   the repo top level (no value imports). Two layers:
//     1. RAW envelopes (JsonRpcRequest/Response/Notification) — the parse
//        targets for one JSONL line; `method: string`, `params?: unknown`.
//     2. TYPED envelopes (TypedRequest/Response/Notification + BridgeParams<M>/
//        BridgeResult<M>) — narrowed per-method shapes for type-safe dispatch.
//   Framing is LF-only JSONL mirroring pi's modes/rpc/jsonl.js (implemented in
//   S7, not here). Consumed by the TS extension (M2/S9/S11-S15/S16) and, via
//   JSON, by the Lua client (P2.M5).

// ---- Type-only re-export of pi's completion types (INPUT requirement) ----
// AutocompleteItem / AutocompleteSuggestions are defined in
// @earendil-works/pi-tui (autocomplete.ts:99-119) and re-exported at its
// index.ts:1. Re-export TYPE-ONLY so RPC handlers import completion + protocol
// types from one place. Do NOT re-export AutocompleteProvider (out of scope) and
// do NOT `export *` (would pull the CombinedAutocompleteProvider runtime class).
export { type AutocompleteItem, type AutocompleteSuggestions } from "@earendil-works/pi-tui";

// ============================================================================
// 1. RAW JSON-RPC 2.0 ENVELOPES  (item contract (a)(b)(c) — exact shapes)
//    The parse target for a single JSONL line. `jsonrpc` is the literal "2.0";
//    `id` is `string` (PRD §5 restricts to string, not vanilla number/null).
// ============================================================================

/** JSON-RPC 2.0 error object (success responses carry none). No `data` field
 *  (PRD §5.3 + item contract keep it minimal). Standard codes: -32700 parse,
 *  -32600 invalid request (PRD §5.3 uses this for "bad token"), -32601 method
 *  not found, -32602 invalid params, -32603 internal error. See
 *  https://www.jsonrpc.org/specification#error_object. (S9/S15 may add a runtime
 *  const map of these codes; this module is types-only.) */
export interface JsonRpcError {
	code: number;
	message: string;
}

/** Raw JSON-RPC 2.0 request — C→S or S→C, carries a string `id` expecting a
 *  reply. `params?: unknown` (absent-or-any); narrow via TypedRequest after
 *  switching on `method`. Wire: `{"jsonrpc":"2.0","id":"h1","method":"hello","params":{...}}`. */
export interface JsonRpcRequest {
	jsonrpc: "2.0";
	id: string;
	method: string;
	params?: unknown;
}

/** Raw JSON-RPC 2.0 response — success carries `result`, failure carries
 *  `error`. Exactly one of result/error is present. Wire success:
 *  `{"jsonrpc":"2.0","id":"h1","result":{...}}`; error:
 *  `{"jsonrpc":"2.0","id":"h1","error":{"code":-32600,"message":"bad token"}}`. */
export type JsonRpcResponse =
	| { jsonrpc: "2.0"; id: string; result?: unknown }
	| { jsonrpc: "2.0"; id: string; error: JsonRpcError };

/** Raw JSON-RPC 2.0 notification — fire-and-forget, NO `id`, NO reply. Used for
 *  S→C `commandsChanged`. Wire: `{"jsonrpc":"2.0","method":"commandsChanged","params":{}}`. */
export interface JsonRpcNotification {
	jsonrpc: "2.0";
	method: string;
	params?: unknown;
}

/** Any parsed JSONL line (request OR response OR notification). The reader
 *  (S7/S8) narrows this: has `id` + `method` → request; has `id` + (`result` |
 *  `error`) → response; has `method` + no `id` → notification. */
export type JsonRpcMessage = JsonRpcRequest | JsonRpcResponse | JsonRpcNotification;

// ============================================================================
// 2. BRIDGE DESCRIPTOR  (item contract (d) — exact fields)
//    JSON.stringify'd to process.env.PI_NVIM_BRIDGE in S16; vim.json.decode'd
//    by the Lua client (PRD §7.1). MUST be plain JSON (no functions/undefined).
// ============================================================================

/** v1 transport is Unix domain socket only. PRD §5.1 names a future TCP
 *  loopback variant (`"transport":"tcp","host":"127.0.0.1","port":…`); when
 *  added, make BridgeDescriptor a discriminated union on this field. */
export type BridgeTransport = "unix";

/** Connection descriptor advertised via process.env.PI_NVIM_BRIDGE (S16).
 *  Fields: path = socket path (`${tmpdir}/pi-editor-bridge-${uuid}.sock`, S5);
 *  token = the REAL auth boundary (PRD §5.1, §12 — socket perms 0o600 are
 *  defense-in-depth; the token is what the client must present in `hello`);
 *  pid = process.pid; cwd = ctx.cwd (ExtensionContext.cwd, types.d.ts:216);
 *  fdAvailable = whether the `fd` tool resolved (ensureTool('fd'));
 *  serverVersion = bridge/pi version string (PRD §6.4 uses "0.1.0"; pi exports
 *  VERSION in config.ts). */
export interface BridgeDescriptor {
	transport: "unix";
	path: string;
	token: string;
	pid: number;
	cwd: string;
	fdAvailable: boolean;
	serverVersion: string;
}

// ============================================================================
// 3. PER-METHOD PARAMS/RESULTS  (item contract (e) — match PRD §5.4 EXACTLY)
//    cursorLine = 0-indexed line; cursorCol = 0-indexed UTF-16 code-unit offset
//    (PRD §8; external_deps.md §1.1). Empty params use Record<string, never>.
// ============================================================================

// --- hello (C→S handshake, PRD §5.3) ---
export interface HelloParams {
	token: string;
	client?: string;
	clientVersion?: string;
}
export interface HelloResult {
	ok: true;
	serverVersion: string;
	cwd: string;
	fdAvailable: boolean;
}

// --- ping (C→S liveness, PRD §5.4) ---
export type PingParams = Record<string, never>;
export interface PingResult {
	ok: true;
	pid: number;
	cwd: string;
	fdAvailable: boolean;
	serverVersion: string;
}

// --- getSuggestions (C→S, delegates to AutocompleteProvider.getSuggestions) ---
export interface GetSuggestionsParams {
	lines: string[];
	cursorLine: number;
	cursorCol: number;
	force?: boolean;
}
/** null when the provider has no suggestions. AutocompleteSuggestions is
 *  re-exported above from @earendil-works/pi-tui. */
export type GetSuggestionsResult = AutocompleteSuggestions | null;

// --- applyCompletion (C→S, delegates to AutocompleteProvider.applyCompletion) ---
export interface ApplyCompletionParams {
	lines: string[];
	cursorLine: number;
	cursorCol: number;
	item: AutocompleteItem;
	prefix: string;
}
export interface ApplyCompletionResult {
	lines: string[];
	cursorLine: number;
	cursorCol: number;
}

// --- shouldTriggerFileCompletion (C→S; provider field is optional in pi) ---
export interface ShouldTriggerFileCompletionParams {
	lines: string[];
	cursorLine: number;
	cursorCol: number;
}
export type ShouldTriggerFileCompletionResult = boolean;

// --- getCommands (C→S, OPTIONAL "richer docs menus", PRD §5.4) ---
export type GetCommandsParams = Record<string, never>;
/**
 * Bridge-LOCAL command descriptor for the optional getCommands "richer docs
 * menus" feature (PRD §5.4). NOT imported from pi: `CommandInfo` does not exist
 * there (verified), and the closest type, `SlashCommandInfo` (pi-coding-agent
 * slash-commands.ts), carries `source`/`sourceInfo` (internal file paths) and
 * `getArgumentCompletions`/`handler` — none plain-JSON-safe or relevant to a
 * docs menu. This type mirrors the USER-FACING slice of pi-tui's `SlashCommand`
 * / `BuiltinSlashCommand` (`{ name; description?; argumentHint? }`). The S14
 * handler maps pi's `SlashCommandInfo[]`/`BuiltinSlashCommand[]` DOWN to this
 * by stripping sourceInfo/handler.
 */
export interface CommandInfo {
	name: string;
	description?: string;
	argumentHint?: string;
}
export interface GetCommandsResult {
	commands: CommandInfo[];
}

// --- commandsChanged (S→C NOTIFICATION — no id, no result, PRD §5.4) ---
export type CommandsChangedParams = Record<string, never>;

// --- bye (C→S graceful disconnect, PRD §5.4) ---
export type ByeParams = Record<string, never>;
export interface ByeResult {
	ok: true;
}

// ============================================================================
// 4. METHOD UNION + MAPPED TYPES  (the "full type safety" dispatch layer)
//    Raw envelopes have `method: string`; these narrow to per-method shapes.
// ============================================================================

/** All 8 method names (PRD §5.4). String literals — match EXACTLY. */
export type BridgeMethod =
	| "hello"
	| "ping"
	| "getSuggestions"
	| "applyCompletion"
	| "shouldTriggerFileCompletion"
	| "getCommands"
	| "commandsChanged"
	| "bye";

/** C→S request methods (carry an `id`, expect a result). Excludes
 *  `commandsChanged` (the only S→C notification). */
export type RequestMethod = Exclude<BridgeMethod, "commandsChanged">;

/** S→C notification methods (no `id`, no result). */
export type NotificationMethod = "commandsChanged";

/** Maps each method name → its params type. Used by BridgeParams<M>. */
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

/** Maps each REQUEST method name → its result type. `commandsChanged` is
 *  intentionally OMITTED (notifications have no result). */
export interface BridgeResultMap {
	hello: HelloResult;
	ping: PingResult;
	getSuggestions: GetSuggestionsResult;
	applyCompletion: ApplyCompletionResult;
	shouldTriggerFileCompletion: ShouldTriggerFileCompletionResult;
	getCommands: GetCommandsResult;
	bye: ByeResult;
}

/** Params type for a given method. e.g. BridgeParams<"getSuggestions">. */
export type BridgeParams<M extends BridgeMethod> = BridgeParamsMap[M];

/** Result type for a given REQUEST method. e.g. BridgeResult<"ping">.
 *  Only valid for RequestMethod (commandsChanged has no result). */
export type BridgeResult<M extends RequestMethod> = BridgeResultMap[M];

// ============================================================================
// 5. TYPED ENVELOPES  (narrowed, per-method — for the M2 dispatcher)
//    Parse a line as JsonRpcMessage → narrow to JsonRpcRequest → switch on
//    `method as RequestMethod` → cast params as BridgeParams<typeof method> →
//    return BridgeResult<typeof method>. These types make that flow safe.
// ============================================================================

/** Narrowed request: method is M, params is BridgeParams<M>. */
export interface TypedRequest<M extends RequestMethod = RequestMethod> {
	jsonrpc: "2.0";
	id: string;
	method: M;
	params: BridgeParams<M>;
}

/** Narrowed response: success result is BridgeResult<M>, OR an error. */
export type TypedResponse<M extends RequestMethod = RequestMethod> =
	| { jsonrpc: "2.0"; id: string; result: BridgeResult<M> }
	| { jsonrpc: "2.0"; id: string; error: JsonRpcError };

/** Narrowed notification: method is M, params is BridgeParams<M>. */
export interface TypedNotification<M extends NotificationMethod = NotificationMethod> {
	jsonrpc: "2.0";
	method: M;
	params: BridgeParams<M>;
}
```

```jsonc
// === extension/tsconfig.json — the ONLY change: append "protocol.ts" to include ===
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
	JsonRpcRequest,
	JsonRpcResponse,
	JsonRpcNotification,
	JsonRpcMessage,
	JsonRpcError,
	BridgeDescriptor,
	HelloParams,
	HelloResult,
	PingResult,
	GetSuggestionsParams,
	GetSuggestionsResult,
	ApplyCompletionParams,
	ApplyCompletionResult,
	ShouldTriggerFileCompletionParams,
	ShouldTriggerFileCompletionResult,
	CommandInfo,
	GetCommandsResult,
	CommandsChangedParams,
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

// ---------------------------------------------------------------------------
// TEST 1 — the module loads via jiti with ZERO runtime deps. All exports are
// types (interfaces/type aliases + a type-only re-export), so the runtime module
// namespace may be EMPTY. The invariant is "did not throw + is a module object".
// (A value import of pi-tui, or an accidental `export const`, would make this
// throw "Cannot find module" at the repo top level — catching exactly that.)
// ---------------------------------------------------------------------------
test("protocol.ts loads via jiti with zero runtime deps (all exports are types)", async () => {
	const mod = await import("../protocol.ts");
	assert.equal(typeof mod, "object", "dynamic import must return a module object");
	// mod may legitimately have zero own keys (all exports erased at runtime).
});

// ---------------------------------------------------------------------------
// TEST 2 — every envelope + per-method type + mapped type is structurally sound.
// These declarations are validated by `tsc --noEmit` (Level 1 gate). A few
// assert.equal calls give runtime signal that the sample objects are well-formed.
// ---------------------------------------------------------------------------
test("raw JSON-RPC envelopes accept canonical wire shapes", () => {
	const req: JsonRpcRequest = {
		jsonrpc: "2.0",
		id: "h1",
		method: "hello",
		params: { token: "t" },
	};
	const okRes: JsonRpcResponse = {
		jsonrpc: "2.0",
		id: "h1",
		result: { ok: true, serverVersion: "0.1.0", cwd: "/", fdAvailable: true },
	};
	const errRes: JsonRpcResponse = {
		jsonrpc: "2.0",
		id: "h1",
		error: { code: -32600, message: "bad token" },
	};
	const notif: JsonRpcNotification = {
		jsonrpc: "2.0",
		method: "commandsChanged",
		params: {},
	};
	const anyLine: JsonRpcMessage = req;

	assert.equal(req.jsonrpc, "2.0");
	assert.equal((errRes as { error: JsonRpcError }).error.code, -32600);
	assert.equal(notif.method, "commandsChanged");
	assert.equal(anyLine.id, "h1");
});

test("BridgeDescriptor carries all seven v1 fields with unix transport", () => {
	const desc: BridgeDescriptor = {
		transport: "unix",
		path: "/tmp/pi-editor-bridge-x.sock",
		token: "deadbeef",
		pid: 12345,
		cwd: "/home/user/proj",
		fdAvailable: true,
		serverVersion: "0.1.0",
	};
	assert.equal(desc.transport, "unix");
	assert.equal(desc.pid, 12345);
	assert.equal(desc.fdAvailable, true);
});

test("per-method params/results match PRD §5.4 shapes", () => {
	const hello: HelloParams = { token: "t", client: "pi-bridge.nvim", clientVersion: "1.0" };
	const helloRes: HelloResult = { ok: true, serverVersion: "0.1.0", cwd: "/", fdAvailable: false };
	const pingRes: PingResult = { ok: true, pid: 1, cwd: "/", fdAvailable: true, serverVersion: "0.1.0" };
	const gs: GetSuggestionsParams = { lines: ["@/sr"], cursorLine: 0, cursorCol: 4, force: true };
	const gsRes: GetSuggestionsResult = { items: [{ value: "@/src/a.ts", label: "a.ts" }], prefix: "@/src" };
	const gsNull: GetSuggestionsResult = null;
	const ac: ApplyCompletionParams = {
		lines: ["@/sr"],
		cursorLine: 0,
		cursorCol: 4,
		item: { value: "@/src/a.ts", label: "a.ts" },
		prefix: "@/sr",
	};
	const acRes: ApplyCompletionResult = { lines: ["@/src/a.ts"], cursorLine: 0, cursorCol: 10 };
	const stfc: ShouldTriggerFileCompletionParams = { lines: ["x"], cursorLine: 0, cursorCol: 1 };
	const stfcRes: ShouldTriggerFileCompletionResult = true;
	const cmd: CommandInfo = { name: "model", description: "Select model", argumentHint: "<provider/model>" };
	const gcRes: GetCommandsResult = { commands: [cmd] };
	const cc: CommandsChangedParams = {};
	const byeRes: ByeResult = { ok: true };

	// runtime heartbeat — proves the literals/options resolved as expected
	assert.equal(helloRes.ok, true);
	assert.equal(gsRes?.items.length, 1);
	assert.equal(gsNull, null);
	assert.equal(acRes.cursorCol, 10);
	assert.equal(stfcRes, true);
	assert.equal(gcRes.commands[0]?.name, "model");
	assert.equal(byeRes.ok, true);
	// touch the unused-typed locals so tsc --noUnusedLocals (if ever enabled) stays happy;
	// also proves assignability of the param types:
	void [hello, pingRes, gs, ac, stfc, cc];
});

test("method unions + mapped types narrow correctly", () => {
	// RequestMethod excludes commandsChanged; NotificationMethod is commandsChanged.
	const reqMethods: RequestMethod[] = [
		"hello", "ping", "getSuggestions", "applyCompletion",
		"shouldTriggerFileCompletion", "getCommands", "bye",
	];
	const notifMethods: NotificationMethod[] = ["commandsChanged"];
	assert.equal(reqMethods.length, 7);
	assert.equal(notifMethods.length, 1);

	// BridgeParams<M> / BridgeResult<M> resolve to the right shapes:
	const helloParams: BridgeParams<"hello"> = { token: "t" };
	const helloResult: BridgeResult<"hello"> = { ok: true, serverVersion: "0", cwd: "/", fdAvailable: true };
	const ccParams: BridgeParams<"commandsChanged"> = {};
	const pingResult: BridgeResult<"ping"> = { ok: true, pid: 1, cwd: "/", fdAvailable: true, serverVersion: "0" };

	// Typed* envelopes:
	const tReq: TypedRequest<"getSuggestions"> = {
		jsonrpc: "2.0", id: "1", method: "getSuggestions",
		params: { lines: [""], cursorLine: 0, cursorCol: 0 },
	};
	const tRes: TypedResponse<"ping"> = {
		jsonrpc: "2.0", id: "1",
		result: { ok: true, pid: 1, cwd: "/", fdAvailable: true, serverVersion: "0" },
	};
	const tErr: TypedResponse<"hello"> = {
		jsonrpc: "2.0", id: "1", error: { code: -32600, message: "bad token" },
	};
	const tNotif: TypedNotification<"commandsChanged"> = {
		jsonrpc: "2.0", method: "commandsChanged", params: {},
	};

	assert.equal(helloParams.token, "t");
	assert.equal(helloResult.fdAvailable, true);
	assert.equal(ccParams && Object.keys(ccParams).length, 0);
	assert.equal(pingResult.pid, 1);
	assert.equal(tReq.method, "getSuggestions");
	assert.equal((tRes as { result: { pid: number } }).result.pid, 1);
	assert.equal((tErr as { error: JsonRpcError }).error.code, -32600);
	assert.equal(tNotif.method, "commandsChanged");

	// Full BridgeMethod union is 8 members.
	const allMethods: BridgeMethod[] = [...reqMethods, ...notifMethods];
	assert.equal(allMethods.length, 8);
});
```

### Integration Points

```yaml
NO external integration points for S1.
  - No database, config file, routes, env writes, sockets, or package manifest.
  - protocol.ts is a standalone types module; at runtime it has NO side effects
    and NO value exports (loads with zero node_modules at the repo top level).
INTERNAL consumers (later tasks, NOT this one — they import FROM protocol.ts):
  - M2/S8 onConnection dispatcher  — narrows JsonRpcMessage → JsonRpcRequest →
        switch(method) → BridgeParams<typeof method> → BridgeResult<typeof method>.
  - S9  hello handshake             — HelloParams/HelloResult; JsonRpcError code -32600.
  - S11 getSuggestions handler      — GetSuggestionsParams/Result (force param + AbortController per §5.5).
  - S12 applyCompletion handler     — ApplyCompletionParams/Result.
  - S13 shouldTriggerFileCompletion — ShouldTriggerFileCompletionParams/Result.
  - S14 ping/bye/getCommands        — PingResult, ByeResult, GetCommandsResult (maps pi SlashCommandInfo[] → CommandInfo[]).
  - S15 error wrapping              — JsonRpcError + standard codes.
  - S16 PI_NVIM_BRIDGE env        — BridgeDescriptor (JSON.stringify'd).
  - S17 commandsChanged broadcast   — TypedNotification<"commandsChanged">.
  - Lua client (P2.M5)              — consumes the JSON shapes (no TS import; the
        wire is the contract). coords.lua (S28/S29) implements the UTF-16 cursorCol semantics documented in JSDoc.
DOCUMENTATION coupling:
  - The module JSDoc cites PRD §5.x for every type and pi's modes/rpc/jsonl.js
    as the framing mirror for S7.
```

## Validation Loop

### Level 1: Syntax & Style (Immediate Feedback)

```bash
# Type-check the extension + tests. With "protocol.ts" added to include, this
# checks protocol.ts standalone AND via the test import. Catches: a wrong
# re-export form, a non-literal jsonrpc, a mistyped method name, a mapped-type
# that doesn't narrow, a stray value export.
tsc --noEmit -p extension/tsconfig.json
# Expected: exit 0, NO output.
#   TS2305 "has no exported member 'AutocompleteItem'" → you used `export *` or
#     imported from the wrong place; use the type-only re-export form.
#   TS2344/TS2558 on BridgeParams/BridgeResult → a method name typo or
#     commandsChanged left in BridgeResultMap.
#   TS2322 on a sample object → a literal type (jsonrpc:"2.0", ok:true,
#     transport:"unix") was widened to string/boolean somewhere.

# Indentation sanity (S1/S2/S3 + pi examples use TABS):
grep -nP '^    ' extension/protocol.ts && echo "WARN: found space-indent lines" || echo "indent OK (tabs)"

# CRITICAL invariant: protocol.ts has NO value exports (types-only).
grep -nE 'export (const|let|var|function|class|enum|default)' extension/protocol.ts \
  && echo "FAIL: found a value export — protocol.ts must be types-only" \
  || echo "PASS: types-only (no value exports)"

# Confirm the re-export is type-only (the `type` modifier on each name):
grep -nE 'export \{[^}]*\} from "@earendil-works/pi-tui"' extension/protocol.ts \
  | grep -q 'type AutocompleteItem' \
  && echo "PASS: AutocompleteItem re-export present" \
  || echo "FAIL: AutocompleteItem re-export missing or not type-modified"
```

### Level 2: Unit Tests (Component Validation) — THE CONTRACT GATE

```bash
# Zero-dependency TS test runner: Node's built-in node:test, with jiti as the TS
# loader (jiti v2.7.0 nested under pi-coding-agent; borrow its register hook —
# same path S2/S3 use).
JITI_REG=/home/dustin/.local/lib/node_modules/@earendil-works/pi-coding-agent/node_modules/jiti/lib/jiti-register.mjs
node --import "$JITI_REG" extension/tests/protocol.test.ts
# Expected: exit 0; final summary shows `pass 4` (or more) and `fail 0`.
# NOTE: jiti v2.7.0 on Node 26 prints a harmless DeprecationWarning
#   ("module.register() is deprecated") to STDERR — IGNORE it; judge by exit code
#   and the `pass`/`fail` lines, not stderr cleanliness.
#   "Cannot find module '@earendil-works/pi-tui'" at runtime → a value import/
#     export crept in (should be impossible if the grep in Level 1 passed, but
#     the dynamic-import test will surface it).

# Re-run S2 + S3 suites to prove S1 didn't regress them (S1 only added files):
node --import "$JITI_REG" extension/tests/provider-capture.test.ts   # expect exit 0, fail 0
node --import "$JITI_REG" extension/tests/mode-guard.test.ts         # expect exit 0, fail 0
```

### Level 3: Integration Testing (System Validation) — THE REGRESSION GATE

```bash
# S1 does NOT touch pi-editor-bridge.ts, so the extension must load EXACTLY as
# before. This gate proves no accidental edit to the entry point / tsconfig
# `paths` broke the runtime load. (protocol.ts is NOT wired in yet — that's M2.)
pi --no-extensions -e ./extension/pi-editor-bridge.ts --print "ok" 2>&1 | tee /tmp/pi-editor-bridge-s1t2.log

# PASS 1: pi exited 0.
pi --no-extensions -e ./extension/pi-editor-bridge.ts --print "ok" >/dev/null 2>&1; echo "pi exit=$?"

# PASS 2: NO errors during load/handler invocation.
grep -iE "error|cannot|fail|throw|unhandled|is not a function|TypeError" /tmp/pi-editor-bridge-s1t2.log \
  && echo "FAIL: error present" || echo "PASS: no errors"
# Expected: pi prints "ok" output and exits 0; no errors.
```

### Level 4: Creative & Domain-Specific Validation

```bash
# Confirm protocol.ts is importable in isolation (simulates M2 importing it from
# the future socket-server module) and yields an empty/typed-only namespace:
node --import /home/dustin/.local/lib/node_modules/@earendil-works/pi-coding-agent/node_modules/jiti/lib/jiti-register.mjs \
  -e 'import("./extension/protocol.ts").then(m => { console.log("keys:", Object.keys(m).sort().join(",") || "(none — types-only)"); console.log("default:", typeof m.default); })'
# Expected: keys = "(none — types-only)" (or just the re-exported types are
#   erased, so empty); default = "undefined" (no default export). This proves
#   the module loads with zero runtime deps.

# Confirm the tsconfig now includes protocol.ts (and ONLY that line changed):
grep -n '"include"' -A2 extension/tsconfig.json
# Expected: an include array containing "pi-editor-bridge.ts", "protocol.ts", "tests/**/*.ts".

# Sanity: the global-load path still works for the EXTENSION (protocol.ts is not
# loaded by pi yet; this just confirms the entry point is unaffected):
mkdir -p ~/.pi/agent/extensions
cp extension/pi-editor-bridge.ts ~/.pi/agent/extensions/pi-editor-bridge.ts
pi --print "ok" 2>&1 | grep -E "error|cannot|fail" && echo "FAIL" || echo "PASS: global-load OK"
rm -f ~/.pi/agent/extensions/pi-editor-bridge.ts   # clean up (don't leave installed during dev)
```

## Final Validation Checklist

### Technical Validation

- [ ] Level 1: `tsc --noEmit -p extension/tsconfig.json` → exit 0, no output.
- [ ] Level 2 (CONTRACT GATE): `node --import <jiti-register> extension/tests/protocol.test.ts`
      → exit 0, `fail` 0 (`pass` ≥ 4); S2's `provider-capture.test.ts` and S3's
      `mode-guard.test.ts` still green.
- [ ] Level 3 (REGRESSION GATE): `pi --no-extensions -e ./extension/pi-editor-bridge.ts --print "ok"`
      exits 0 with NO error lines (S1 did not touch the entry point).
- [ ] Level 4: `import("./extension/protocol.ts")` yields a types-only namespace
      (no runtime keys, no default); tsconfig `include` contains `"protocol.ts"`.

### Feature Validation

- [ ] `extension/protocol.ts` exports the raw envelopes `JsonRpcRequest` /
      `JsonRpcResponse` / `JsonRpcNotification` (+ `JsonRpcMessage`, `JsonRpcError`)
      matching item contract (a)(b)(c) exactly (`jsonrpc: "2.0"` literal, `id:
      string`, `method: string`, `params?: unknown`, error `{ code; message }`).
- [ ] `BridgeDescriptor` matches item contract (d) exactly (7 fields,
      `transport: "unix"` literal).
- [ ] Per-method params/result interfaces match PRD §5.4 verbatim (all 8 methods);
      `ok` is literal `true` on hello/ping/bye; empty params are
      `Record<string, never>`; getSuggestions result is `AutocompleteSuggestions | null`.
- [ ] `CommandInfo` is bridge-local `{ name; description?; argumentHint? }` with
      JSDoc noting it is NOT from pi and excludes `sourceInfo`/`handler`.
- [ ] `BridgeMethod` (8), `RequestMethod` (7), `NotificationMethod` (1);
      `BridgeParamsMap` (8), `BridgeResultMap` (7 — no commandsChanged);
      `BridgeParams<M>` / `BridgeResult<M>` / `TypedRequest` / `TypedResponse` /
      `TypedNotification` all compile and narrow.
- [ ] `protocol.ts` re-exports `type AutocompleteItem, type AutocompleteSuggestions`
      from `@earendil-works/pi-tui` (type-only).
- [ ] `protocol.ts` has NO value exports (types-only — grep proves it).
- [ ] Mode-A JSDoc on EVERY exported type explaining its wire-format role.
- [ ] NO socket / env write / framing reader / wiring into pi-editor-bridge.ts.

### Code Quality Validation

- [ ] TAB indentation; `import type` discipline; type-only re-export form
      (`export { type X, type Y } from "..."`).
- [ ] Literal types (`"2.0"`, `"unix"`, `true`) NOT widened to `string`/`boolean`.
- [ ] Mapped types are interfaces (extensible) and the aliases are generic with
      `extends BridgeMethod`/`RequestMethod` bounds.
- [ ] `commandsChanged` correctly OMITTED from `BridgeResultMap` and `RequestMethod`.
- [ ] tsconfig change is the minimal one-line `include` addition; no other change.

### Documentation & Deployment

- [ ] File-level JSDoc explains the two-layer (raw + typed) design + the LF-only
      JSONL framing mirror (cites pi's modes/rpc/jsonl.js for S7).
- [ ] Mode-A JSDoc on each type cites the relevant PRD §5.x and (for CommandInfo)
      the absence-of-CommandInfo-in-pi rationale.
- [ ] No new env vars WRITTEN (BridgeDescriptor is only TYPED here; S16 writes it).

---

## Anti-Patterns to Avoid

- ❌ Don't add value exports (const/let/var/function/class/enum/default) to
      protocol.ts — it MUST be types-only to load via jiti with zero node_modules.
      A const error-code map is tempting but belongs to S9/S15.
- ❌ Don't use `export * from "@earendil-works/pi-tui"` — it pulls the
      `CombinedAutocompleteProvider` runtime class (breaks zero-deps). Use the
      explicit type-only re-export of exactly the two named types.
- ❌ Don't widen `jsonrpc: "2.0"`, `transport: "unix"`, or `ok: true` to
      `string`/`boolean`. The literals are the point — they make malformed wire a
      compile error.
- ❌ Don't widen `id` to `string | number | null` (vanilla JSON-RPC). PRD §5
      restricts to string; keep it narrow.
- ❌ Don't collapse the raw and typed envelope layers. Raw envelopes
      (`method: string`, `params?: unknown`) are the PARSE targets; Typed*
      envelopes are for narrowed dispatch. Both are needed.
- ❌ Don't use `{}` for empty params — use `Record<string, never>` (the correct
      "empty object" type; `{}` means "any non-nullish").
- ❌ Don't include `commandsChanged` in `BridgeResultMap` or `RequestMethod` —
      it's a notification with no result and no id.
- ❌ Don't import `SlashCommandInfo` from pi-coding-agent into protocol.ts — it
      leaks internal `sourceInfo` paths and is not plain-JSON-safe. Define a lean
      local `CommandInfo`.
- ❌ Don't wire protocol.ts into pi-editor-bridge.ts, add socket/env/framing code,
      or change tsconfig `paths` — those are M2 / S16 / S7 (and S2 already set
      the pi-tui path). The ONLY tsconfig edit is appending `"protocol.ts"` to
      `include`.
- ❌ Don't add `package.json`, `README.md`, or any npm dependency — `node:test`
      is built in and jiti is borrowed from pi-coding-agent's nested node_modules.
      Packaging is S18.
- ❌ Don't edit `pi-editor-bridge.ts` — S1 is purely additive (new protocol.ts +
      new test + one-line tsconfig include). The Level-3 gate exists precisely to
      catch an accidental entry-point edit.
