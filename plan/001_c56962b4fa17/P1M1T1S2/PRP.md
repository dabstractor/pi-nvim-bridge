---
name: "P1.M1.T1.S2 — Provider capture via pass-through addAutocompleteProvider factory"
description: |
  Add a **pass-through** `addAutocompleteProvider` factory to
  `extension/pi-editor-bridge.ts` that **captures a reference** to pi's live
  autocomplete chain (at minimum the `CombinedAutocompleteProvider`) with
  **ZERO behavior change**, expose the captured provider through an exported
  `getProvider()` accessor, and wire the capture into the `session_start`
  handler created by S1. Re-registration on every `session_start` is MANDATORY
  (pi clears the wrapper list on session reset). Deliverable also includes the
  contract-required unit test that mocks `ctx.ui.addAutocompleteProvider` and a
  dev `tsconfig.json` `paths` update so `tsc` can resolve `@earendil-works/pi-tui`.
  This task is NARROW: NO TUI-mode guard (S3), NO socket server (M2), NO env-var
  advertisement (S16), NO commandsChanged (S17), NO packaging (S18).
---

## Goal

**Feature Goal**: A module-level captured reference to pi's live
`AutocompleteProvider`, populated on every `session_start` via a pass-through
factory passed to `ctx.ui.addAutocompleteProvider`, and retrievable through an
exported `getProvider()` — with **zero observable behavior change** to pi's
completion (the factory returns `current` unchanged). Verifiable by (a) real `pi`
load that fires `session_start` and calls our factory, (b) `tsc --noEmit` clean,
and (c) a `node:test` suite asserting the pass-through + capture + throw-on-empty
contract.

**Deliverable** (all under `extension/`):
1. **MODIFY** `extension/pi-editor-bridge.ts` (the file S1 created) to add:
   - `import type { AutocompleteProvider } from "@earendil-works/pi-tui";`
   - module-level `let liveProvider: AutocompleteProvider | undefined;`
   - `export function captureProvider(ctx: ExtensionContext): void` — calls
     `ctx.ui.addAutocompleteProvider((current) => { liveProvider = current; return current; })`.
   - `export function getProvider(): AutocompleteProvider` — returns
     `liveProvider` or throws if undefined.
   - a call to `captureProvider(ctx)` inside the existing `session_start`
     handler (after the S1 startup log), with a TODO comment marking the S3
     `ctx.mode === "tui"` guard insertion point.
   - Mode-A JSDoc on `captureProvider()` (and a short one on `getProvider()`).
   - Update the file-level JSDoc STATUS line to reflect S2 completion.
2. **MODIFY** `extension/tsconfig.json` (S1's dev-only config) to add a `paths`
   entry for `@earendil-works/pi-tui` pointing at the **nested** dist index
   (S1 only mapped `@earendil-works/pi-coding-agent`).
3. **CREATE** `extension/tests/provider-capture.test.ts` — a `node:test` suite
   mocking `ctx.ui.addAutocompleteProvider` to assert the factory is called with
   the live provider, returns it unchanged, captures it, and that `getProvider()`
   throws before capture.

**Success Definition**:
- `pi --no-extensions -e ./extension/pi-editor-bridge.ts --print "ok"` loads the
  file via jiti, fires `session_start`, calls our pass-through factory, and
  exits 0 with no `error|cannot|fail|throw|TypeError` in the output.
- `tsc --noEmit -p extension/tsconfig.json` → exit 0, no output (proves the
  pi-tui type import resolves).
- `node --import <jiti-register.mjs> extension/tests/provider-capture.test.ts`
  → exit 0, `pass` ≥ 3, `fail` 0.
- The factory returns `current` unchanged (assertion in test) — **zero behavior
  change** to completion.

## User Persona (if applicable)

**Target User**: The bridge-extension author / future RPC-handler implementers
(S11–S14). This task is developer infrastructure, not end-user-facing.

**Use Case**: Later RPC handlers (`getSuggestions`, `applyCompletion`,
`shouldTriggerFileCompletion`) call `getProvider()` to reach pi's completion
engine (slash commands, prompt templates, extension commands, skill commands,
`@file`/path/`fd` logic) without re-implementing any of it.

**Pain Points Addressed**: pi exposes no public getter for the live
`AutocompleteProvider`; the only clean public seam is
`ctx.ui.addAutocompleteProvider(factory)`, whose factory receives the live chain
as `current`. A pass-through factory captures that reference with no behavior
change — this task establishes that capture.

## Why

- **The single clean public seam** (PRD §2.3 / §6.3): `addAutocompleteProvider`
  is the only documented way to obtain the live `AutocompleteProvider`. A
  pass-through factory that returns `current` unchanged is the minimal, safe
  capture — it changes nothing about pi's completion.
- **Foundation for all of Component A's RPC methods** (PRD §6.5): every handler
  in M2.T6 (S11–S14) delegates to `getProvider()`. Without a reliable capture
  wired into `session_start`, those handlers have nothing to call.
- **Re-registration correctness** (PRD §6.3 note; verified at
  `interactive-mode.js:1507`): pi **clears the wrapper list on session reset**,
  so the capture MUST run on every `session_start`, not once in the factory body.
  This task gets that lifecycle right so reload/new/resume/fork all re-capture.

## What

`extension/pi-editor-bridge.ts` gains three things at module scope — a typed
`liveProvider` variable, a `captureProvider(ctx)` function, and a `getProvider()`
accessor — and its existing `session_start` handler gains one line:
`captureProvider(ctx);`. The factory passed to `addAutocompleteProvider` is
literally `(current) => { liveProvider = current; return current; }`. No wrapper
object is constructed; completion behavior is untouched. A `node:test` suite
proves the contract with a faithful mock of pi's `addAutocompleteProvider`
(which calls the factory synchronously with the current chain and keeps the
return value).

### Success Criteria

- [ ] `extension/pi-editor-bridge.ts` imports `AutocompleteProvider` **type-only
      from `@earendil-works/pi-tui`** (not from pi-coding-agent).
- [ ] Module-level `let liveProvider: AutocompleteProvider | undefined;`.
- [ ] `export function captureProvider(ctx: ExtensionContext): void` calls
      `ctx.ui.addAutocompleteProvider((current) => { liveProvider = current; return current; })`.
- [ ] `export function getProvider(): AutocompleteProvider` returns `liveProvider`
      or throws a clear Error if undefined.
- [ ] The `session_start` handler (from S1) calls `captureProvider(ctx)`, with a
      `// S3:` TODO marking the future `ctx.mode === "tui"` guard insertion point.
- [ ] JSDoc on `captureProvider()` (Mode A) explains the pass-through technique
      and the mandatory re-registration on `session_start`.
- [ ] `extension/tsconfig.json` adds a `paths` entry for
      `@earendil-works/pi-tui` → the **nested** dist index.d.ts.
- [ ] `extension/tests/provider-capture.test.ts` exists and passes.
- [ ] `pi --no-extensions -e ./extension/pi-editor-bridge.ts --print "ok"` exits 0,
      no errors.
- [ ] `tsc --noEmit -p extension/tsconfig.json` exits 0, no output.
- [ ] `node --import <jiti-register> extension/tests/provider-capture.test.ts`
      exits 0 with `fail` 0.
- [ ] NO TUI guard / socket / env write / commandsChanged / packaging code added
      (those are S3/M2/S16/S17/S18).

## All Needed Context

### Context Completeness Check

_Pass test_: An agent who has never seen this repo, given the S1 baseline file
(supplied as the contract from the preceding task) and this PRP, can (1) make the
five edits to the TS file using the exact reference shape below, (2) add one
`paths` line to the tsconfig using the verified nested path, (3) write the test
from the supplied skeleton, and (4) run the three exact validation commands to
green — with every type name, import source, line citation, and gotcha listed
here.

### Documentation & References

```yaml
# MUST READ — the type sources of truth (installed dist; line-cited)
- file: /home/dustin/.local/lib/node_modules/@earendil-works/pi-coding-agent/dist/core/extensions/types.d.ts
  why: exact AutocompleteProviderFactory + addAutocompleteProvider + ExtensionContext shapes
  section: "L12 (imports AutocompleteProvider from pi-tui), L61 (AutocompleteProviderFactory = (current) => AutocompleteProvider), L136 (addAutocompleteProvider(factory): void on ExtensionUIContext)"
  critical: |
    AutocompleteProvider is imported by pi-coding-agent FROM @earendil-works/pi-tui
    (L12) and is NOT re-exported by pi-coding-agent's index (only
    AutocompleteProviderFactory is). => MUST `import type { AutocompleteProvider }
    from "@earendil-works/pi-tui"`.

- file: /home/dustin/.local/lib/node_modules/@earendil-works/pi-coding-agent/node_modules/@earendil-works/pi-tui/dist/index.d.ts
  why: confirms AutocompleteProvider (and AutocompleteItem/Suggestions/CombinedAutocompleteProvider) are exported from pi-tui
  section: "L1: export { type AutocompleteItem, type AutocompleteProvider, type AutocompleteSuggestions, CombinedAutocompleteProvider, ... } from \"./autocomplete.ts\";"
  critical: |
    pi-tui is NOT a top-level global install — it is NESTED under
    pi-coding-agent/node_modules. The dev tsconfig `paths` MUST point at this
    nested dist index.d.ts, or tsc reports TS2307.

# MUST READ — pi runtime mechanics (installed dist; line-cited)
- file: /home/dustin/.local/lib/node_modules/@earendil-works/pi-coding-agent/dist/modes/interactive/interactive-mode.js
  why: proves addAutocompleteProvider = push + immediate setupAutocompleteProvider (rebuild whole chain); wrappers cleared on session reset
  section: "L1673-1674 (push factory then setupAutocompleteProvider()), L415-~425 (setupAutocompleteProvider folds wrappers over base CombinedAutocompleteProvider), L1507-1509 (session reset: wrappers=[] then setupAutocompleteProvider())"
  critical: |
    (1) Our factory is invoked SYNCHRONOUSLY with the current chain as `current`
        the instant addAutocompleteProvider is called. (2) Wrappers are CLEARED on
        session reset => capture MUST run on every session_start.

- file: /home/dustin/.local/lib/node_modules/@earendil-works/pi-coding-agent/dist/modes/rpc/rpc-mode.js
  why: proves addAutocompleteProvider is a NO-OP in RPC mode (so calling it unconditionally is safe; the ctx.mode guard is S3's concern)
  section: "L193-195: addAutocompleteProvider() { /* Autocomplete provider composition is not supported in RPC mode */ }"

# MUST READ — the canonical reference example (copy its structure; the WRAP part is OUT OF SCOPE — we PASS-THROUGH)
- file: /home/dustin/.local/lib/node_modules/@earendil-works/pi-coding-agent/examples/extensions/github-issue-autocomplete.ts
  why: shows the exact import line from @earendil-works/pi-tui, the `pi.on("session_start", (_event, ctx) => { ctx.ui.addAutocompleteProvider((current) => ...) })` shape, and TAB indentation
  pattern: "import { type AutocompleteProvider, ... } from \"@earendil-works/pi-tui\";  +  ctx.ui.addAutocompleteProvider((current) => { ...; return current; })"
  gotcha: |
    The example WRAPS current (returns a new provider object). S2 does the OPPOSITE
    and returns `current` UNCHANGED (pass-through, zero behavior change). Copy the
    IMPORT + pi.on/session_start SHAPE only.

# MUST READ — the immediately-preceding task's PRP (the S1 baseline this task modifies)
- docfile: plan/001_c56962b4fa17/P1M1T1S1/PRP.md
  why: defines the exact `extension/pi-editor-bridge.ts` and `extension/tsconfig.json` S2 starts from
  section: "Implementation Patterns & Key Details (the S1 reference file shape) + Validation (the S1 tsconfig)"
  critical: |
    S2 EDITS S1's file in place (adds import + liveProvider + captureProvider +
    getProvider + one call in session_start). Do NOT rewrite S1's structure; modify it.
    Match S1's TAB indentation and `import type` discipline.

# SUPPORTING — pre-researched architecture (project-local)
- docfile: plan/001_c56962b4fa17/architecture/research-pi-autocomplete.md
  why: file:line-verified facts about addAutocompleteProvider, setupAutocompleteProvider, the session-reset clear, and what `current` contains (CombinedAutocompleteProvider)
  section: "§1 (autocomplete engine types), §2 (interactive-mode: addAutocompleteProvider L2143-2146, session-reset clear L1952, setupAutocompleteProvider L624-639)"
- docfile: plan/001_c56962b4fa17/architecture/research-pi-extension-api.md
  why: type surface + lifecycle + "addAutocompleteProvider is a no-op in RPC mode" (Residual Risk #1)
  section: "§1 ExtensionUIContext.addAutocompleteProvider; Residual Risks #1 (RPC no-op) and #3 (no sockets in factory)"

# SUPPORTING — local research notes for S2 (this task)
- docfile: plan/001_c56962b4fa17/P1M1T1S2/research/notes.md
  why: every claim above re-verified against the installed dist with exact citations; test-runner approach (node:test + jiti-register) proven end-to-end
```

### Current Codebase tree (assumes S1 completed — the baseline for S2)

```bash
extension/
├── pi-editor-bridge.ts   # (from S1) default-export factory + session_start (logs) + session_shutdown (no-op) + JSDoc header
└── tsconfig.json         # (from S1) dev-only; paths maps ONLY @earendil-works/pi-coding-agent today
# (plan/ holds planning artifacts only — no other source code)
```

### Desired Codebase tree with files to be added/modified

```bash
extension/
├── pi-editor-bridge.ts            # (MODIFY, from S1) +liveProvider +captureProvider +getProvider +1 call in session_start
├── tsconfig.json                  # (MODIFY, from S1) +paths entry for @earendil-works/pi-tui (nested)
└── tests/
    └── provider-capture.test.ts   # (CREATE) node:test suite mocking ctx.ui.addAutocompleteProvider
```

**File responsibilities**
- `extension/pi-editor-bridge.ts` — still the single-file pi extension entry point
  (default export = factory). Adds the provider-capture seam used by all later
  RPC handlers. Named exports `captureProvider` / `getProvider` are ignored by
  pi's loader (which only consumes the default export) but importable by tests
  and by sibling code in this same module.
- `extension/tsconfig.json` — dev-only type-check config (never consumed by pi at
  runtime). Adds the pi-tui `paths` entry so `tsc --noEmit` resolves the
  `AutocompleteProvider` type.
- `extension/tests/provider-capture.test.ts` — establishes the zero-dependency TS
  test pattern (`node:test` + jiti register) reused by later tasks (M2 RPC
  handler tests, etc.).

### Known Gotchas of our codebase & Library Quirks

```typescript
// CRITICAL: AutocompleteProvider is NOT re-exported by @earendil-works/pi-coding-agent.
//   It is imported there FROM @earendil-works/pi-tui (types.d.ts:12). You MUST:
//     import type { AutocompleteProvider } from "@earendil-works/pi-tui";
//   (matches the canonical example github-issue-autocomplete.ts). Importing it from
//   pi-coding-agent yields TS2305/TS2307.

// CRITICAL: @earendil-works/pi-tui is NOT a top-level global install. It lives at:
//   /home/dustin/.local/lib/node_modules/@earendil-works/pi-coding-agent/node_modules/@earendil-works/pi-tui
//   => the dev tsconfig `paths` MUST map "@earendil-works/pi-tui" to that NESTED
//      dist/index.d.ts, or tsc fails with TS2307. (Runtime is fine: `import type`
//      is erased, so jiti never resolves it.)

// CRITICAL: capture MUST run on EVERY session_start. pi clears the wrapper list on
//   session reset (interactive-mode.js:1507), so a one-time registration in the
//   factory body would silently stop capturing after the first reload/new/resume/fork.
//   => call captureProvider(ctx) INSIDE the session_start handler, not in the factory.

// CRITICAL: the factory must be a TRUE pass-through — return `current` UNCHANGED.
//   Do NOT construct/return a wrapper provider object (that changes behavior and is
//   a different design). The whole point is zero behavior change.

// STYLE: TABS for indentation (match S1 + pi's examples). Unused params prefixed `_`.
//   Use `import type` for ALL type imports (erased at runtime => loads w/ zero deps).

// SCOPE: do NOT add a ctx.mode === "tui" guard (that's S3 — leave a TODO), socket
//   creation (M2), process.env writes (S16), commandsChanged (S17), package.json/
//   README (S18). addAutocompleteProvider is a no-op in RPC mode (rpc-mode.js:193)
//   and is callable-but-inert in print/json mode, so an unconditional call in S2 is
//   SAFE; the guard is purely for clarity/efficiency and lands in S3.

// TEST: `liveProvider` is module-level singleton state. Within one node:test file
//   the state persists across tests IN DEFINITION ORDER (sequential by default).
//   => the "getProvider() throws before capture" assertion MUST be the FIRST test.
//   Do NOT enable test concurrency for this file.
```

## Implementation Blueprint

### Data models and structure

No new data structures. S2 adds one module-level variable and two thin functions
over the `AutocompleteProvider` type already defined by pi-tui:

```typescript
import type { AutocompleteProvider } from "@earendil-works/pi-tui";

// Module-level captured reference to pi's live autocomplete chain. Undefined
// until the first session_start fires and the pass-through factory runs.
let liveProvider: AutocompleteProvider | undefined;
```

### Implementation Tasks (ordered by dependencies)

```yaml
Task 1: MODIFY extension/pi-editor-bridge.ts  (the file S1 created)
  - ADD import: `import type { AutocompleteProvider } from "@earendil-works/pi-tui";`
      (place it directly ABOVE the existing `import type { ExtensionAPI, ExtensionContext, ... } from "@earendil-works/pi-coding-agent";`
      line from S1 — two separate import statements, both type-only.)
  - ADD module-level (after the imports, BEFORE `export default`):
      `let liveProvider: AutocompleteProvider | undefined;`
  - ADD `export function captureProvider(ctx: ExtensionContext): void { ... }`
      with a Mode-A JSDoc. Body: `ctx.ui.addAutocompleteProvider((current) => { liveProvider = current; return current; });`
      (the factory literal must be EXACTLY: capture current, return current — pass-through.)
  - ADD `export function getProvider(): AutocompleteProvider { ... }` with a short JSDoc.
      Body: `if (!liveProvider) { throw new Error("pi-editor-bridge: autocomplete provider not captured yet (await session_start)"); } return liveProvider;`
  - MODIFY the existing S1 `session_start` handler: after the S1 `console.log(...)`
      line, ADD one line: `captureProvider(ctx);`
      and add a TODO comment line immediately above it: `// TODO(S3): guard with `if (ctx.mode !== "tui") return;` before capture.`
  - UPDATE the file-level JSDoc STATUS block: change "lifecycle scaffolding only" →
      note provider capture is implemented (S2), socket/env/commandsChanged still pending (M2/S16/S17).
  - DO NOT: add a ctx.mode guard (S3), createServer (M2), process.env writes (S16),
      commandsChanged (S17), or touch the session_shutdown handler.
  - FOLLOW pattern: examples/extensions/github-issue-autocomplete.ts (import-from-pi-tui +
      pi.on("session_start") + addAutocompleteProvider call shape). PASS-THROUGH, do not WRAP.
  - NAMING: `captureProvider`, `getProvider`, `liveProvider` (exact, per item contract + PRD §6.3).
  - INDENTATION: TABS (match S1 + examples).

Task 2: MODIFY extension/tsconfig.json  (S1's dev-only config)
  - ADD to compilerOptions.paths (alongside the existing @earendil-works/pi-coding-agent entry):
      "@earendil-works/pi-tui": ["/home/dustin/.local/lib/node_modules/@earendil-works/pi-coding-agent/node_modules/@earendil-works/pi-tui/dist/index.d.ts"]
  - DO NOT: change target/module/strict/noEmit/include; do NOT add package.json.
  - JUSTIFICATION: lets `tsc --noEmit` resolve the AutocompleteProvider type import.

Task 3: CREATE extension/tests/provider-capture.test.ts
  - IMPLEMENT: node:test suite (3 tests) using `node:test` + `node:assert/strict`.
  - TEST 1 (FIRST — relies on undefined initial state): `getProvider()` throws /not captured/.
  - TEST 2: `captureProvider(ctx)` calls `ctx.ui.addAutocompleteProvider` with a function;
      that function, given a base provider, returns it UNCHANGED and `getProvider()` then === base.
      Mock MUST faithfully simulate pi: call `factory(baseProvider)` synchronously inside the
      mock and capture its return value (because interactive-mode does push+setup immediately).
  - TEST 3: re-capture reassigns liveProvider (proves re-registration on each session_start is safe).
  - IMPORT: `import { captureProvider, getProvider } from "../pi-editor-bridge.ts";`
      + type-only `import type { AutocompleteProvider } from "@earendil-works/pi-tui";`
      + type-only `import type { ExtensionContext } from "@earendil-works/pi-coding-agent";`
  - NAMING: `test("getProvider() throws when no provider captured yet", ...)`, etc.
  - COVERAGE: pass-through identity, capture identity, throw-before-capture, re-capture.
  - PLACEMENT: extension/tests/ (new dir).
  - NO CONCURRENCY: rely on sequential definition order for Test 1's precondition.

Task 4: VALIDATE — run the three validation commands; fix until all green
  - RUN (Level 3 gate): `pi --no-extensions -e ./extension/pi-editor-bridge.ts --print "ok" 2>&1 | grep -iE "error|cannot|fail|throw|TypeError"` (expect NO match)
  - RUN (Level 1): `tsc --noEmit -p extension/tsconfig.json` (expect exit 0, no output)
  - RUN (Level 2): `node --import <jiti-register.mjs> extension/tests/provider-capture.test.ts` (expect exit 0, fail 0)
```

### Implementation Patterns & Key Details

```typescript
// === extension/pi-editor-bridge.ts — the S2 additions (apply on top of the S1 file) ===
// (Show only the NEW/MODIFIED parts; the rest of the S1 file — imports block, the
//  session_shutdown no-op handler, the default-export factory wrapper — stays as-is.)

import type { AutocompleteProvider } from "@earendil-works/pi-tui";
import type {
	ExtensionAPI,
	ExtensionContext,
	SessionStartEvent,
	SessionShutdownEvent,
} from "@earendil-works/pi-coding-agent";

/**
 * Captured reference to pi's live autocomplete provider chain.
 * Populated by the pass-through factory in {@link captureProvider} on every
 * `session_start`. `undefined` until then; read via {@link getProvider}.
 */
let liveProvider: AutocompleteProvider | undefined;

/**
 * Capture a reference to pi's live `AutocompleteProvider` WITHOUT changing
 * completion behavior.
 *
 * Technique: register a **pass-through** factory with
 * `ctx.ui.addAutocompleteProvider`. pi calls that factory synchronously with
 * the current provider chain as `current` (at minimum the
 * `CombinedAutocompleteProvider`: slash commands, prompt templates, extension
 * commands, skill commands, and `@file`/path/`fd` logic). We stash `current`
 * into {@link liveProvider} and return it **unchanged** — zero behavior change.
 *
 * MUST be called on every `session_start`, because pi clears the autocomplete-
 * wrapper list on session reset (reload/new/resume/fork) and re-applies all
 * factories from scratch via `setupAutocompleteProvider()`. Registering once in
 * the factory body would silently stop capturing after the first reset.
 *
 * (In non-TUI modes `addAutocompleteProvider` is a safe no-op; the explicit
 * `ctx.mode === "tui"` guard is added in S3.)
 */
export function captureProvider(ctx: ExtensionContext): void {
	ctx.ui.addAutocompleteProvider((current) => {
		liveProvider = current;
		return current; // pass-through — zero behavior change
	});
}

/**
 * Return the live autocomplete provider captured on the last `session_start`.
 * Throws if called before the first capture (e.g. before `session_start` fires).
 * RPC handlers (S11–S14) use this to delegate to pi's completion engine.
 */
export function getProvider(): AutocompleteProvider {
	if (!liveProvider) {
		throw new Error(
			"pi-editor-bridge: autocomplete provider not captured yet (await session_start)",
		);
	}
	return liveProvider;
}

export default function (pi: ExtensionAPI): void {
	pi.on("session_start", (event: SessionStartEvent, ctx: ExtensionContext) => {
		console.log(
			`pi-editor-bridge: session_start (reason=${event.reason}, mode=${ctx.mode})`,
		);
		// TODO(S3): guard with `if (ctx.mode !== "tui") return;` before capturing.
		captureProvider(ctx);
		// TODO(M2): startBridge(ctx, ctx.cwd);   TODO(S16): advertise via process.env.PI_NVIM_BRIDGE
	});

	pi.on("session_shutdown", (_event: SessionShutdownEvent) => {
		// No-op placeholder. TODO(S6/S15): stopBridge() + clear env.
	});
}
```

```jsonc
// === extension/tsconfig.json — the ONLY line S2 adds (one paths entry) ===
{
	"compilerOptions": {
		"target": "ES2022",
		"module": "ESNext",
		"moduleResolution": "Bundler",
		"strict": true,
		"noEmit": true,
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
	"include": ["pi-editor-bridge.ts", "tests/**/*.ts"]
}
```

```typescript
// === extension/tests/provider-capture.test.ts (CREATE — node:test + jiti) ===
import { test } from "node:test";
import assert from "node:assert/strict";
import type { AutocompleteProvider } from "@earendil-works/pi-tui";
import type { ExtensionContext } from "@earendil-works/pi-coding-agent";
import { captureProvider, getProvider } from "../pi-editor-bridge.ts";

// Build a sentinel object satisfying the AutocompleteProvider shape. Methods are
// stubs — the pass-through test only checks IDENTITY, never calls them.
function makeFakeProvider(): AutocompleteProvider {
	return {
		triggerCharacters: ["@", "#"],
		async getSuggestions() {
			return { items: [], prefix: "" };
		},
		applyCompletion(lines, cursorLine, cursorCol) {
			return { lines, cursorLine, cursorCol };
		},
		shouldTriggerFileCompletion() {
			return true;
		},
	};
}

// NOTE: `liveProvider` is module-level singleton state shared across these tests.
// node:test runs top-level tests sequentially in DEFINITION ORDER by default, so
// this FIRST test observes the pre-capture (undefined) state. Do not reorder / do
// not enable concurrency.
test("getProvider() throws before any provider is captured", () => {
	assert.throws(() => getProvider(), /not captured/);
});

test("captureProvider registers a pass-through factory: returns current UNCHANGED and captures it", () => {
	const base = makeFakeProvider();
	let piCalledFactoryWith: unknown;
	let piUsedResult: unknown;

	// Faithfully simulate pi's ExtensionUIContext.addAutocompleteProvider
	// (interactive-mode.js:1673-1674): it calls the factory SYNCHRONOUSLY with the
	// current chain and keeps the returned provider as the new chain.
	const fakeCtx = {
		ui: {
			addAutocompleteProvider(factory: (c: AutocompleteProvider) => AutocompleteProvider) {
				piCalledFactoryWith = base;
				piUsedResult = factory(base);
			},
		},
	} as unknown as ExtensionContext;

	captureProvider(fakeCtx);

	// pi handed our factory the live chain...
	assert.equal(piCalledFactoryWith, base);
	// ...and the factory returned it UNCHANGED (pass-through, zero behavior change)...
	assert.equal(piUsedResult, base);
	// ...and the reference was captured for later RPC handlers.
	assert.equal(getProvider(), base);
});

test("re-capture (e.g. a new session_start) reassigns the captured provider", () => {
	const runCapture = (provider: AutocompleteProvider) => {
		captureProvider({
			ui: { addAutocompleteProvider: (f) => void f(provider) },
		} as unknown as ExtensionContext);
	};
	const first = makeFakeProvider();
	const second = makeFakeProvider();
	runCapture(first);
	assert.equal(getProvider(), first);
	runCapture(second);
	assert.equal(getProvider(), second);
});
```

### Integration Points

```yaml
NO external integration points for S2.
  - No database, config file, routes, env writes, sockets, or package manifest.
  - The ONLY runtime consumer is pi itself, which loads the file via jiti and
    invokes the default export; pi then calls our pass-through factory during
    setupAutocompleteProvider() on each session_start.
INTERNAL consumers (later tasks, NOT this one):
  - getProvider() ← RPC handlers getSuggestions/applyCompletion/shouldTriggerFileCompletion (S11-S13)
  - captureProvider(ctx) ← already wired into session_start by THIS task; S3 wraps it in a ctx.mode === "tui" guard.
FUTURE (NOT this task): startBridge (M2/S5), stopBridge (S6), env advertisement (S16), commandsChanged (S17).
```

## Validation Loop

### Level 1: Syntax & Style (Immediate Feedback)

```bash
# Type-check the extension + tests in isolation (types resolve via paths mapping,
# now including pi-tui at its NESTED node_modules location). This is the gate that
# catches a wrong AutocompleteProvider import source or a missing pi-tui paths entry.
tsc --noEmit -p extension/tsconfig.json
# Expected: exit 0, NO output. If TS2307 "@earendil-works/pi-tui" appears, the
#   tsconfig paths entry is missing or points at the (non-existent) top-level path.
# If TS2305 "has no exported member 'AutocompleteProvider'" appears, you imported
#   it from pi-coding-agent instead of pi-tui — fix the import source.

# Indentation sanity (S1 + pi examples use TABS):
grep -nP '^    ' extension/pi-editor-bridge.ts && echo "WARN: found space-indent lines" || echo "indent OK (tabs)"

# Confirm type-only imports (S2 must NOT add a value import of pi-tui — it has no
# runtime resolution from this repo's top level):
grep -nE '^import \{[^}]*AutocompleteProvider' extension/pi-editor-bridge.ts \
  && echo "FAIL: value import of AutocompleteProvider — must be 'import type'" \
  || echo "PASS: AutocompleteProvider is import type (erased at runtime)"
```

### Level 2: Unit Tests (Component Validation) — THE CONTRACT GATE

```bash
# Zero-dependency TS test runner: Node's built-in node:test, with jiti as the TS
# loader (jiti v2.7.0 is nested under pi-coding-agent; borrow its register hook).
JITI_REG=/home/dustin/.local/lib/node_modules/@earendil-works/pi-coding-agent/node_modules/jiti/lib/jiti-register.mjs
node --import "$JITI_REG" extension/tests/provider-capture.test.ts
# Expected: exit 0; final summary shows `pass 3` (or more) and `fail 0`.
# NOTE: jiti v2.7.0 on Node 26 prints a harmless DeprecationWarning
#   ("module.register() is deprecated") to STDERR — IGNORE it; judge by exit code
#   and the `pass`/`fail` lines, not stderr cleanliness.
# If "Cannot find module '../pi-editor-bridge.ts'" appears, run from the repo root
#   (the relative import resolves from the test file, but cwd should be repo root).
```

### Level 3: Integration Testing (System Validation) — THE RUNTIME GATE

```bash
# Load the extension through the REAL pi runtime via jiti. --print mode fires
# session_start (reason=startup) AND session_shutdown (reason=quit). Our
# captureProvider runs in session_start; addAutocompleteProvider is callable in
# print mode (inert there, but must NOT throw). This proves the file loads and
# the capture call is wired without errors.
pi --no-extensions -e ./extension/pi-editor-bridge.ts --print "ok" 2>&1 | tee /tmp/pi-editor-bridge-s2.log

# Startup log fired?
grep -E "pi-editor-bridge: session_start \(reason=startup" /tmp/pi-editor-bridge-s2.log \
  && echo "PASS: session_start fired" || echo "FAIL: startup log missing"

# No load/runtime errors (addAutocompleteProvider must not throw in print mode)?
grep -iE "error|cannot|fail|throw|unhandled|is not a function|TypeError" /tmp/pi-editor-bridge-s2.log \
  && echo "FAIL: error present" || echo "PASS: no errors"
# Expected: startup log present, no errors, pi exits 0.
```

### Level 4: Creative & Domain-Specific Validation

```bash
# Confirm named exports alongside `export default` do not break pi loading
# (pi consumes only the default export; named exports are for tests):
node --import /home/dustin/.local/lib/node_modules/@earendil-works/pi-coding-agent/node_modules/jiti/lib/jiti-register.mjs \
  -e 'import("./extension/pi-editor-bridge.ts").then(m => { console.log("exports:", Object.keys(m).sort().join(",")); console.log("has default:", typeof m.default === "function"); console.log("has captureProvider:", typeof m.captureProvider === "function"); console.log("has getProvider:", typeof m.getProvider === "function"); })'
# Expected: exports include "captureProvider","default","getProvider"; default is a function.

# Confirm zero new runtime npm deps: only `import type` (erased) + node builtins.
grep -nE '^import [^{]' extension/pi-editor-bridge.ts \
  && echo "FAIL: found a value import — S2 should be type-only" \
  || echo "PASS: only import type present (loads with zero node_modules at top level)"

# Sanity: the global-load path still works (simulates end-user install):
mkdir -p ~/.pi/agent/extensions
cp extension/pi-editor-bridge.ts ~/.pi/agent/extensions/pi-editor-bridge.ts
pi --print "ok" 2>&1 | grep -E "pi-editor-bridge: session_start" && echo "PASS: global-load OK" || echo "FAIL"
rm -f ~/.pi/agent/extensions/pi-editor-bridge.ts   # clean up (don't leave installed during dev)
```

## Final Validation Checklist

### Technical Validation

- [ ] Level 1: `tsc --noEmit -p extension/tsconfig.json` → exit 0, no output.
- [ ] Level 2 (CONTRACT GATE): `node --import <jiti-register> extension/tests/provider-capture.test.ts`
      → exit 0, `fail` 0 (`pass` ≥ 3).
- [ ] Level 3 (RUNTIME GATE): `pi --no-extensions -e ./extension/pi-editor-bridge.ts --print "ok"`
      prints the startup log and exits 0 with no error/cannot/fail/throw/TypeError lines.
- [ ] Level 4: named exports (`captureProvider`, `getProvider`) present alongside default; loads from
      `~/.pi/agent/extensions/`; only `import type` (no value imports).

### Feature Validation

- [ ] `extension/pi-editor-bridge.ts` imports `AutocompleteProvider` **type-only from `@earendil-works/pi-tui`**.
- [ ] Module-level `let liveProvider: AutocompleteProvider | undefined;`.
- [ ] `captureProvider(ctx)` registers the exact pass-through factory
      `(current) => { liveProvider = current; return current; }`.
- [ ] `getProvider()` returns `liveProvider` or throws a clear Error when undefined.
- [ ] `session_start` handler calls `captureProvider(ctx)` (after the S1 log); a `// S3:` TODO marks
      the future `ctx.mode === "tui"` guard.
- [ ] JSDoc on `captureProvider()` explains the pass-through technique + mandatory re-registration.
- [ ] Test asserts: factory receives the live provider, returns it UNCHANGED, captures it; `getProvider()`
      throws before capture; re-capture reassigns.
- [ ] NO TUI guard / socket / env write / commandsChanged / packaging code present.

### Code Quality Validation

- [ ] Edits are applied ON TOP of the S1 file (not a rewrite); S1 structure preserved.
- [ ] TAB indentation; unused params prefixed `_`; `import type` discipline maintained.
- [ ] Named exports do not interfere with pi's default-export consumption (Level 4 proves it).
- [ ] Single pass-through factory — no wrapper object constructed (zero behavior change).
- [ ] `tsconfig.json` change is the minimal one `paths` entry; no other compiler options changed.

### Documentation & Deployment

- [ ] `captureProvider()` JSDoc (Mode A) documents the technique + the session-reset re-registration rationale.
- [ ] File-level JSDoc STATUS block updated to reflect S2 done (capture) + pending (M2/S16/S17).
- [ ] TODO comments reference downstream tasks (S3 guard, M2 startBridge, S16 env, S6/S15 shutdown).
- [ ] No new env vars WRITTEN (the JSDoc continues to merely document the future `PI_NVIM_BRIDGE`).

---

## Anti-Patterns to Avoid

- ❌ Don't WRAP `current` (return a new provider object) — that changes behavior. S2 is a TRUE
  pass-through: return `current` UNCHANGED. (Wrapping is github-issue-autocomplete's job, not ours.)
- ❌ Don't import `AutocompleteProvider` from `@earendil-works/pi-coding-agent` — it isn't re-exported
  there. Use `@earendil-works/pi-tui` (matches the canonical example + item contract).
- ❌ Don't point the tsconfig `paths` for pi-tui at a top-level global path — it doesn't exist; pi-tui is
  NESTED under `pi-coding-agent/node_modules`. (This is the #1 likely S2 failure.)
- ❌ Don't register the capture once in the factory body — pi clears wrappers on session reset; capture
  MUST run on every `session_start`.
- ❌ Don't add the `ctx.mode === "tui"` guard, socket, env write, or commandsChanged here — those are
  S3 / M2 / S16 / S17. Leave TODO markers, not implementations.
- ❌ Don't make `captureProvider`/`getProvider` async or return Promises — the capture is synchronous
  (pi calls the factory synchronously) and `getProvider()` is a plain accessor.
- ❌ Don't reorder the test file or enable concurrency — Test 1 ("throws before capture") depends on
  `liveProvider` being undefined, which only holds before any `captureProvider()` call in the same process.
- ❌ Don't add `package.json`, `README.md`, or any npm dependency — `node:test` is built in and jiti is
  borrowed from pi-coding-agent's nested node_modules. Packaging is S18.
- ❌ Don't use a value `import` for any pi type — `import type` only (erased at runtime → loads with zero
  node_modules at the repo top level, satisfying PRD §6.7).
