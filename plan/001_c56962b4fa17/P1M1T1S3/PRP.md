---
name: "P1.M1.T1.S3 — TUI mode guard — no-op when ctx.mode !== 'tui'"
description: |
  Add an `if (ctx.mode !== "tui") return;` early-return guard at the **very
  top** of the `session_start` handler in `extension/pi-editor-bridge.ts` (the
  file S1 created and S2 extended with provider capture). The guard short-circuits
  **all** bridge logic in rpc/json/print modes — no startup log, no provider
  capture, and (forward-looking) no socket/env/commandsChanged once those land
  below it. This is correct because `ctx.ui.addAutocompleteProvider` is a silent
  no-op in RPC mode (`rpc-mode.ts:271-273`) and `openExternalEditor` exists only
  in interactive (TUI) mode — so the bridge has nothing to serve in non-TUI
  modes. Deliverable also includes a Mode-A JSDoc on the guard explaining the RPC
  no-op limitation, a `node:test` suite proving the handler no-ops in rpc/json/
  print and proceeds in tui, and an UPDATED file-level STATUS block + Level-3
  validation gate (the `--print` load test no longer greps for the startup log,
  which the guard now suppresses). This task is NARROW: NO socket (M2), NO env
  write (S16), NO commandsChanged (S17), NO packaging (S18), NO changes to
  `captureProvider`/`getProvider` (S2), NO guard on `session_shutdown`.
---

## Goal

**Feature Goal**: The `session_start` handler in `extension/pi-editor-bridge.ts`
returns immediately when `ctx.mode !== "tui"`, so the bridge performs **zero**
work in rpc/json/print modes. `ctx.mode` is the pi-typed `ExtensionMode`
(`"tui" | "rpc" | "json" | "print"`); the guard is a single
`if (ctx.mode !== "tui") return;` at the top of the handler, supersedes S2's
inline `// TODO(S3)` marker, and is documented with a Mode-A JSDoc. The guard is
the single forward-looking chokepoint: every later `session_start` task (M2
`startBridge`, S16 env advertisement, S17 `commandsChanged`) will land BELOW it
and is thereby auto-protected in non-TUI modes.

**Deliverable** (all under `extension/`):
1. **MODIFY** `extension/pi-editor-bridge.ts` (the S1+S2 file):
   - At the very top of the `session_start` handler body (above the existing
     `console.log` startup line), add the guard
     `if (ctx.mode !== "tui") return;` preceded by a Mode-A JSDoc block comment
     explaining the RPC no-op + TUI-only-`openExternalEditor` rationale.
   - Move the existing startup `console.log(...)` to BELOW the guard (it becomes
     TUI-only; this is intended — "short-circuit all bridge logic").
   - DELETE the S2 `// TODO(S3): guard with ...` comment (the guard now exists).
   - Update the file-level JSDoc STATUS block: S3 done (TUI guard), pending
     M2/S16/S17; note the guard makes the startup log TUI-only.
2. **CREATE** `extension/tests/mode-guard.test.ts` — a `node:test` suite that
   drives the default-export factory with a capturing fake `pi`, retrieves the
   registered `session_start` handler, and asserts it (a) does NOT call
   `ctx.ui.addAutocompleteProvider` for mode `"rpc"`, `"json"`, `"print"`, and
   (b) DOES call it for mode `"tui"`.

**Success Definition**:
- `pi --no-extensions -e ./extension/pi-editor-bridge.ts --print "ok"` loads via
  jiti, fires `session_start` (reason=startup) in **print** mode, the guard
  short-circuits (no startup log line, no error), and pi exits 0 — proven by:
  exit code 0 AND `grep -iE "error|cannot|fail|throw|TypeError"` returns nothing
  AND `grep "pi-editor-bridge: session_start"` returns nothing (log suppressed
  by the guard in print mode).
- `tsc --noEmit -p extension/tsconfig.json` → exit 0, no output (S2's paths
  mapping already resolves every type; S3 adds no imports).
- `node --import <jiti-register.mjs> extension/tests/mode-guard.test.ts` → exit
  0, `fail` 0 (`pass` ≥ 2).
- The guard is literally `if (ctx.mode !== "tui") return;` with a JSDoc above it.

## User Persona (if applicable)

**Target User**: The bridge-extension author / future RPC-handler implementers
(S11–S14). This task is developer infrastructure: it prevents the extension from
doing useless work (and from starting a socket nobody connects to) when pi runs
headlessly (`pi --print`, `pi --mode rpc`, `pi --mode json`).

**Use Case**: A user runs `pi --print "summarize this"` (or an MCP/RPC client
drives `pi --mode rpc`). The extension loads, `session_start` fires with
`ctx.mode === "print"` (or `"rpc"`), the guard returns immediately — no
`addAutocompleteProvider` no-op call, no future socket bind, no env var. Only in
interactive TUI mode (where `openExternalEditor` can actually launch the user's
`$EDITOR`) does the bridge activate.

**Pain Points Addressed**: Without the guard, the extension would (a) call a
no-op `addAutocompleteProvider` in RPC mode (silently capturing nothing —
`liveProvider` stays `undefined`), and (b) once M2 lands, bind a Unix socket and
write `PI_EDITOR_BRIDGE` to `process.env` in modes that never launch an editor.
The guard makes "TUI-only" an explicit, documented, tested invariant.

## Why

- **`addAutocompleteProvider` is a NO-OP in RPC mode** (architecture
  `research-pi-extension-api.md` Residual Risk #1; verified at installed dist
  `dist/modes/rpc/rpc-mode.js:193-195`, source `rpc-mode.ts:271-273`): the method
  body is literally an empty stub with the comment "Autocomplete provider
  composition is not supported in RPC mode". Calling it unconditionally (as S2
  does) is *safe* but *useless* outside TUI — the factory never fires.
- **`openExternalEditor` is TUI-only** (verified: `grep -rl 'openExternalEditor'`
  over `dist/modes` returns ONLY `modes/interactive/{interactive-mode.js,
  components/extension-editor.js}`; there is no `dist/modes/print/` or
  `dist/modes/json/` directory). The external `$EDITOR` is launched exclusively
  from the interactive-mode keybinding `app.editor.external`. The bridge's whole
  purpose (serve completions to that editor) is moot in non-TUI modes.
- **Forward-looking chokepoint** (PRD §6.2 + §11 "No‑session / print mode"):
  later tasks add `startBridge` (M2/S5), `process.env.PI_EDITOR_BRIDGE` (S16),
  and `commandsChanged` (S17) to `session_start`. Placing the single guard at
  the top now means those tasks code BELOW it and inherit non-TUI protection for
  free — no per-task guards, no risk of one task forgetting the guard.
- **PRD §11 explicit requirement**: "*No‑session / print mode. *
  `openExternalEditor` is TUI‑only; the bridge should no‑op when `ctx.mode ~=
  "tui"` (guard in `session_start`)." This task implements exactly that.

## What

`extension/pi-editor-bridge.ts`'s `session_start` handler gains two things at the
very top — a Mode-A JSDoc block comment and the guard line `if (ctx.mode !== "tui") return;`
— and its existing startup `console.log` moves to just below the guard (so it
only fires in TUI mode). The S2 `// TODO(S3)` comment is removed (replaced by the
real guard). A `node:test` suite proves the handler no-ops in rpc/json/print and
proceeds in tui by driving the default-export factory with a capturing fake `pi`.

### Success Criteria

- [ ] The `session_start` handler's first executable statement is
      `if (ctx.mode !== "tui") return;`.
- [ ] A Mode-A JSDoc block comment sits immediately above the guard, explaining
      (1) `addAutocompleteProvider` is a no-op in RPC mode and (2)
      `openExternalEditor` is TUI-only, so non-TUI activation is useless.
- [ ] The S2 `console.log("pi-editor-bridge: session_start ...")` line is BELOW
      the guard (TUI-only); the S2 `// TODO(S3): guard ...` comment is DELETED.
- [ ] `captureProvider(ctx)`, the M2/S16/S17 TODOs, and the `session_shutdown`
      handler are UNCHANGED (guard does not touch them; shutdown stays unguarded).
- [ ] `extension/tests/mode-guard.test.ts` exists and passes: for each of
      `"rpc"`, `"json"`, `"print"` the handler does NOT call
      `ctx.ui.addAutocompleteProvider`; for `"tui"` it DOES.
- [ ] File-level JSDoc STATUS block updated: S3 (TUI guard) done; startup log now
      TUI-only; M2/S16/S17 still pending.
- [ ] `pi --no-extensions -e ./extension/pi-editor-bridge.ts --print "ok"` exits
      0, prints NO startup-log line (guard suppresses it in print mode), and no
      error/cannot/fail/throw/TypeError lines.
- [ ] `tsc --noEmit -p extension/tsconfig.json` exits 0, no output.
- [ ] `node --import <jiti-register> extension/tests/mode-guard.test.ts` exits 0,
      `fail` 0.
- [ ] NO socket / env write / commandsChanged / packaging code added.

## All Needed Context

### Context Completeness Check

_Pass test_: An agent who has never seen this repo, given the S1+S2 baseline
file (supplied as the contract from the preceding task) and this PRP, can (1)
make the three small edits to the TS file using the exact reference shape below,
(2) write the test from the supplied skeleton, and (3) run the three exact
validation commands to green — with every type name, line citation, and gotcha
listed here.

### Documentation & References

```yaml
# MUST READ — the type the guard depends on (installed dist; line-cited)
- file: /home/dustin/.local/lib/node_modules/@earendil-works/pi-coding-agent/dist/core/extensions/types.d.ts
  why: ExtensionMode union + ExtensionContext.mode field, the exact values the guard compares against
  section: "L207: export type ExtensionMode = \"tui\" | \"rpc\" | \"json\" | \"print\";  L211-212: inside ExtensionContext — '/** Current run mode. Use \"tui\" to guard terminal-only UI such as custom components. */ mode: ExtensionMode;'"
  critical: |
    ctx.mode is a string-literal union, NOT an enum. `ctx.mode !== "tui"` is
    exhaustive over {"rpc","json","print"} and type-safe (no import needed).
    pi's own docstring endorses the `=== "tui"` guard pattern.

# MUST READ — proof the guard is needed (RPC no-op)
- file: /home/dustin/.local/lib/node_modules/@earendil-works/pi-coding-agent/dist/modes/rpc/rpc-mode.js
  why: addAutocompleteProvider is a silent no-op in RPC mode (captureProvider would do nothing)
  section: "L193-195: addAutocompleteProvider() { /* Autocomplete provider composition is not supported in RPC mode */ } (source: modes/rpc/rpc-mode.ts:271-273)"

# MUST READ — proof the bridge's purpose is TUI-only
- url: file:///home/dustin/.local/lib/node_modules/@earendil-works/pi-coding-agent/dist/modes/interactive/interactive-mode.js
  why: openExternalEditor (the $EDITOR launch the bridge serves) lives ONLY under modes/interactive; it never runs in rpc/json/print
  section: "L3093: async openExternalEditor() { ... } ; L2031: this.defaultEditor.onAction(\"app.editor.external\", () => this.openExternalEditor())"
  critical: |
    Verified: `grep -rl 'openExternalEditor|app.editor.external' dist/modes`
    returns ONLY modes/interactive/{interactive-mode.js, components/extension-editor.js}.
    There is NO dist/modes/print/ and NO dist/modes/json/ directory. => The
    external editor is launched exclusively in TUI mode, so bridging completions
    to it is meaningful ONLY in TUI mode.

# MUST READ — the baseline file S3 edits (the S2-completed extension entry point)
- docfile: plan/001_c56962b4fa17/P1M1T1S2/PRP.md
  why: defines the EXACT post-S2 shape of extension/pi-editor-bridge.ts (imports, liveProvider, captureProvider, getProvider, session_start handler with the console.log + the // TODO(S3) marker, session_shutdown no-op) and the tsconfig paths S3 inherits unchanged
  section: "Implementation Patterns & Key Details (the S2 reference file shape) + Validation (Level 1 tsconfig)"
  critical: |
    S3 EDITS S2's file in place: insert guard+JSDoc at the TOP of session_start,
    move the console.log below the guard, delete the // TODO(S3) line. Do NOT
    rewrite S2's structure; modify it. Match S2's TAB indentation + import-type
    discipline.

# SUPPORTING — pre-researched architecture (project-local)
- docfile: plan/001_c56962b4fa17/architecture/research-pi-extension-api.md
  why: ExtensionMode/ctx.mode type surface, ctx.hasUI semantics, and "addAutocompleteProvider is a no-op in RPC mode" (Residual Risk #1)
  section: "§1 ExtensionContext.mode (ExtensionMode = tui|rpc|json|print; ctx.hasUI true only in tui+rpc); Residual Risks #1 (RPC no-op), #3 (no sockets in factory)"

# SUPPORTING — local research notes for S3 (this task)
- docfile: plan/001_c56962b4fa17/P1M1T1S3/research/notes.md
  why: every claim above re-verified against the installed dist with exact citations; guard-placement decision (contract "top" supersedes S2 TODO "before capture"); validation-gate-update rationale; test approach
```

### Current Codebase tree (assumes S1+S2 completed — the baseline for S3)

```bash
extension/
├── pi-editor-bridge.ts   # (S1+S2) default-export factory + session_start (log + // TODO(S3) + captureProvider) + session_shutdown (no-op) + captureProvider/getProvider/liveProvider + JSDoc header
├── tsconfig.json         # (S1+S2) dev-only; paths map @earendil-works/pi-coding-agent AND @earendil-works/pi-tui (nested)
└── tests/
    └── provider-capture.test.ts   # (S2) node:test suite for captureProvider/getProvider
# (plan/ holds planning artifacts only — no other source code)
```

### Desired Codebase tree with files to be added/modified

```bash
extension/
├── pi-editor-bridge.ts            # (MODIFY, from S1+S2) +guard+JSDoc at top of session_start; log moved below guard; // TODO(S3) removed; STATUS block updated
├── tsconfig.json                  # (UNCHANGED — S2's paths mapping already covers every type S3 uses)
└── tests/
    ├── provider-capture.test.ts   # (UNCHANGED — S2 owns it)
    └── mode-guard.test.ts         # (CREATE) node:test suite proving session_start no-ops in rpc/json/print, proceeds in tui
```

**File responsibilities**
- `extension/pi-editor-bridge.ts` — still the single-file pi extension entry
  point. The new guard is the TUI-only activation gate for the entire bridge; it
  is the chokepoint under which M2/S16/S17 will add their code.
- `extension/tests/mode-guard.test.ts` — extends the zero-dependency TS test
  pattern (`node:test` + jiti register) established by S2, this time exercising
  the default-export factory → `pi.on` registration → handler invocation path
  (rather than calling an exported function directly, because the guard lives
  inside the handler).

### Known Gotchas of our codebase & Library Quirks

```typescript
// CRITICAL: the guard MUST be the FIRST executable statement in session_start —
//   BEFORE the S2 console.log. The item contract says "At the top of the
//   session_start handler ... to short-circuit ALL bridge logic." The S2 inline
//   // TODO(S3) hinted at a position just before captureProvider (below the log);
//   the S3 CONTRACT supersedes that hint. => place the guard at the very top,
//   move the log below it, and delete the // TODO(S3) line.

// CRITICAL: this changes the Level-3 validation behavior. S1/S2 grepped --print
//   output for the startup log line. In --print mode ctx.mode === "print", so
//   after S3 the guard returns BEFORE the log => the line is absent. This is
//   CORRECT and intended. Update Level 3 to assert: exit 0 + NO error lines +
//   startup-log line ABSENT in print mode. The guard's real behavior (skip
//   capture in non-TUI) is proven by mode-guard.test.ts, not by --print.

// CRITICAL: do NOT guard session_shutdown. Shutdown must remain callable in all
//   modes — it is a no-op now and will host idempotent stopBridge() (S6/S15)
//   later. A guard there would prevent cleanup if a future task ever started
//   something in the factory body (forbidden by pi docs, but defense-in-depth).

// CRITICAL: the guard is forward-looking. Later tasks (M2 startBridge, S16 env,
//   S17 commandsChanged) add their code BELOW the guard and inherit non-TUI
//   protection automatically. Do NOT add per-task guards later — the single
//   top-of-session_start guard is the design. Document this in the JSDoc.

// STYLE: TABS for indentation (match S1/S2 + pi's examples). Use `import type`
//   for ALL type imports (erased at runtime => loads w/ zero deps).

// TEST: mode-guard.test.ts drives the DEFAULT EXPORT (the factory), not an
//   exported function, because the guard lives inside the session_start handler
//   registered by the factory. Build a capturing fake pi whose .on(event, h)
//   saves the session_start handler, then invoke it with synthetic ctx objects.
//   The liveProvider module singleton is set by the tui-mode test case, but this
//   file asserts only on addAutocompleteProvider call counts — no contamination.
```

## Implementation Blueprint

### Data models and structure

No new data structures. S3 adds one `if` statement and one JSDoc to an existing
handler. It uses the already-defined `ExtensionMode` union from pi-coding-agent
(re-exported via `ExtensionContext.mode`); no import change is needed because
`ctx.mode` is already typed by the existing `ctx: ExtensionContext` parameter.

### Implementation Tasks (ordered by dependencies)

```yaml
Task 1: MODIFY extension/pi-editor-bridge.ts  (the file S1+S2 produced)
  - LOCATE the session_start handler registered in the default-export factory.
      It currently (post-S2) looks like:
          pi.on("session_start", (event: SessionStartEvent, ctx: ExtensionContext) => {
              console.log(`pi-editor-bridge: session_start (reason=${event.reason}, mode=${ctx.mode})`);
              // TODO(S3): guard with `if (ctx.mode !== "tui") return;` before capturing.
              captureProvider(ctx);
              // TODO(M2): startBridge(ctx, ctx.cwd);   TODO(S16): advertise via process.env.PI_EDITOR_BRIDGE
          });
  - INSERT, as the FIRST thing inside the handler body (before console.log):
      a Mode-A JSDoc block comment (see Implementation Patterns for exact text)
      followed immediately by:  if (ctx.mode !== "tui") return;
  - MOVE the existing console.log(...) line to just BELOW the new guard (it is
      now TUI-only). Keep its body byte-for-byte identical.
  - DELETE the line:  // TODO(S3): guard with `if (ctx.mode !== "tui") return;` before capturing.
      (the guard now exists; leaving the TODO would be a lie).
  - LEAVE UNTOUCHED: captureProvider(ctx);, the // TODO(M2)/TODO(S16) line, and
      the entire session_shutdown handler. Do NOT add a guard to session_shutdown.
  - UPDATE the file-level JSDoc STATUS block: mark S3 (TUI mode guard) done;
      note the startup log is now TUI-only (suppressed in --print/--rpc/--json);
      M2 (socket), S16 (env), S17 (commandsChanged) still pending.
  - FOLLOW: TAB indentation, `import type` discipline (no new imports needed).
  - NAMING: guard is literally `if (ctx.mode !== "tui") return;` (exact, per
      item contract — use `!== "tui"`, not `=== "tui"` with inverted body).

Task 2: CREATE extension/tests/mode-guard.test.ts
  - IMPLEMENT: node:test suite using `node:test` + `node:assert/strict`.
  - IMPORT: `import { test } from "node:test"; import assert from "node:assert/strict";`
      `import type { ExtensionAPI, ExtensionContext, SessionStartEvent } from "@earendil-works/pi-coding-agent";`
      `import bridgeFactory from "../pi-editor-bridge.ts";`  (DEFAULT import = the factory)
  - HELPER captureSessionStartHandler(): build a fake `pi` whose `.on(event, h)`
      saves the handler for `event === "session_start"` (ignore others), call
      `bridgeFactory(fakePi)`, assert the handler was registered, return it.
  - TEST 1 ("no-ops in non-TUI modes"): for each mode in ["rpc","json","print"],
      build a ctx whose ui.addAutocompleteProvider sets a `called` flag, invoke
      the handler with a SessionStartEvent {reason:"startup"}, assert called===false.
  - TEST 2 ("proceeds in TUI mode"): build a ctx with mode "tui" whose
      ui.addAutocompleteProvider sets a `called` flag, invoke the handler, assert
      called===true.
  - NAMING: `test("session_start no-ops (does not call addAutocompleteProvider) in rpc/json/print modes", ...)` etc.
  - PLACEMENT: extension/tests/ (the dir S2 created).
  - NO CONCURRENCY: rely on default sequential execution (not required for these
      assertions, but match the project test convention).

Task 3: VALIDATE — run the three validation commands; fix until all green
  - RUN (Level 1): `tsc --noEmit -p extension/tsconfig.json` (expect exit 0, no output)
  - RUN (Level 2): `node --import <jiti-register.mjs> extension/tests/mode-guard.test.ts` (expect exit 0, fail 0)
  - RUN (Level 3, UPDATED): `pi --no-extensions -e ./extension/pi-editor-bridge.ts --print "ok"` —
      expect exit 0, NO startup-log line (guard suppresses it in print mode), and
      no error/cannot/fail/throw/TypeError lines.
```

### Implementation Patterns & Key Details

```typescript
// === extension/pi-editor-bridge.ts — the ONLY structural change S3 makes ===
// (Show only the NEW session_start handler body; everything else in the S1+S2
//  file — imports, liveProvider, captureProvider, getProvider, session_shutdown,
//  the default-export factory wrapper — stays byte-for-byte identical.)

export default function (pi: ExtensionAPI): void {
	pi.on("session_start", (event: SessionStartEvent, ctx: ExtensionContext) => {
		/**
		 * TUI-only activation gate for the entire bridge.
		 *
		 * The external `$EDITOR` (the process this bridge serves completions to)
		 * is launched EXCLUSIVELY by pi's interactive (TUI) mode via the
		 * `app.editor.external` keybinding — `openExternalEditor()` exists only
		 * under `modes/interactive/` and is never invoked in rpc/json/print
		 * modes. In RPC mode, `ctx.ui.addAutocompleteProvider` is additionally a
		 * documented NO-OP (rpc-mode.ts:271-273: "Autocomplete provider
		 * composition is not supported in RPC mode"), so capturing the provider
		 * would silently capture nothing.
		 *
		 * Short-circuiting here means the bridge performs zero work headlessly:
		 * no provider capture, and (once added below) no socket bind, no env-var
		 * advertisement, no commandsChanged emit. All future session_start logic
		 * MUST be placed BELOW this guard so it inherits non-TUI protection.
		 */
		if (ctx.mode !== "tui") return;

		console.log(
			`pi-editor-bridge: session_start (reason=${event.reason}, mode=${ctx.mode})`,
		);
		captureProvider(ctx);
		// TODO(M2): startBridge(ctx, ctx.cwd);   TODO(S16): advertise via process.env.PI_EDITOR_BRIDGE
	});

	pi.on("session_shutdown", (_event: SessionShutdownEvent) => {
		// No-op placeholder. Socket close + unlink + env clear land in S6/S15.
		// NOTE: intentionally UNGUARDED — shutdown must stay callable in all modes.
	});
}
```

```typescript
// === extension/tests/mode-guard.test.ts (CREATE — node:test + jiti) ===
import { test } from "node:test";
import assert from "node:assert/strict";
import type {
	ExtensionAPI,
	ExtensionContext,
	SessionStartEvent,
} from "@earendil-works/pi-coding-agent";
import bridgeFactory from "../pi-editor-bridge.ts";

// Type alias for the session_start handler signature (pi registers
// ExtensionHandler<SessionStartEvent> = (event, ctx) => void | ...).
type SessionStartHandler = (
	event: SessionStartEvent,
	ctx: ExtensionContext,
) => void;

// Run the factory with a fake `pi` that records the session_start handler.
function captureSessionStartHandler(): SessionStartHandler {
	let handler: SessionStartHandler | undefined;
	const fakePi = {
		on(event: string, h: SessionStartHandler) {
			if (event === "session_start") handler = h;
			// session_shutdown and any other registrations are ignored by this test.
		},
	} as unknown as ExtensionAPI;

	bridgeFactory(fakePi);

	assert.ok(
		typeof handler === "function",
		"default-export factory must register a session_start handler",
	);
	return handler!;
}

// Build a minimal ctx carrying only what the handler reads: .mode and .ui.
function makeCtx(
	mode: ExtensionContext["mode"],
	onAddAutocompleteProvider: () => void,
): ExtensionContext {
	return {
		mode,
		ui: { addAutocompleteProvider: onAddAutocompleteProvider },
	} as unknown as ExtensionContext;
}

const STARTUP_EVENT = { reason: "startup" } as SessionStartEvent;

test("session_start no-ops (does not call addAutocompleteProvider) in rpc/json/print modes", () => {
	const handler = captureSessionStartHandler();
	for (const mode of ["rpc", "json", "print"] as const) {
		let called = false;
		handler(STARTUP_EVENT, makeCtx(mode, () => { called = true; }));
		assert.equal(
			called,
			false,
			`addAutocompleteProvider must NOT be called in ${mode} mode (guard should short-circuit)`,
		);
	}
});

test("session_start proceeds (calls addAutocompleteProvider) in tui mode", () => {
	const handler = captureSessionStartHandler();
	let called = false;
	handler(STARTUP_EVENT, makeCtx("tui", () => { called = true; }));
	assert.equal(
		called,
		true,
		"addAutocompleteProvider MUST be called in tui mode (happy path through the handler)",
	);
});
```

### Integration Points

```yaml
NO external integration points for S3.
  - No database, config file, routes, env writes, sockets, or package manifest.
  - The ONLY runtime consumer is pi itself; the guard runs at the top of the
    session_start handler pi invokes on every session start/reload/new/resume/fork.
INTERNAL consumers (later tasks, NOT this one — they code BELOW the guard):
  - M2/S5 startBridge(ctx, ctx.cwd)   — Unix socket server; protected by the guard.
  - S16  process.env.PI_EDITOR_BRIDGE  — env advertisement; protected by the guard.
  - S17  commandsChanged notification  — S→C broadcast; protected by the guard.
DOCUMENTATION coupling:
  - Updates S1/S2's Level-3 validation gate (startup log no longer appears in
    --print mode). The mode-guard.test.ts unit suite is the new authoritative
    proof of guard behavior.
```

## Validation Loop

### Level 1: Syntax & Style (Immediate Feedback)

```bash
# Type-check the extension + tests in isolation. S3 adds NO imports and NO new
# types, so the S2 tsconfig paths mapping already resolves everything. This gate
# catches a typo in the guard (e.g. comparing against an undefined variable).
tsc --noEmit -p extension/tsconfig.json
# Expected: exit 0, NO output.

# Indentation sanity (S1/S2 + pi examples use TABS):
grep -nP '^    ' extension/pi-editor-bridge.ts && echo "WARN: found space-indent lines" || echo "indent OK (tabs)"

# Confirm the guard is present and is the first executable statement of the
# session_start handler (extract the handler body, show its first non-comment line):
awk '/pi\.on\("session_start"/{f=1} f&&/=>\s*\{/{b=1;next} b&&/\)/{print; if(/if \(ctx.mode !== "tui"\) return;/){print "PASS: guard is first statement"} else {print "FAIL: guard missing or not first"} ; exit}' extension/pi-editor-bridge.ts
# (If the awk one-liner is fiddly, just open the file and eyeball: the first
#  executable line after the JSDoc inside the session_start arrow body MUST be
#  `if (ctx.mode !== "tui") return;`.)

# Confirm the S2 TODO marker is gone (guard replaced it):
grep -n 'TODO(S3)' extension/pi-editor-bridge.ts \
  && echo "FAIL: stale TODO(S3) marker still present" \
  || echo "PASS: TODO(S3) marker removed"
```

### Level 2: Unit Tests (Component Validation) — THE CONTRACT GATE

```bash
# Zero-dependency TS test runner: Node's built-in node:test, with jiti as the TS
# loader (jiti v2.7.0 nested under pi-coding-agent; borrow its register hook).
JITI_REG=/home/dustin/.local/lib/node_modules/@earendil-works/pi-coding-agent/node_modules/jiti/lib/jiti-register.mjs
node --import "$JITI_REG" extension/tests/mode-guard.test.ts
# Expected: exit 0; final summary shows `pass 2` (or more) and `fail 0`.
# NOTE: jiti v2.7.0 on Node 26 prints a harmless DeprecationWarning
#   ("module.register() is deprecated") to STDERR — IGNORE it; judge by exit code
#   and the `pass`/`fail` lines, not stderr cleanliness.

# Re-run S2's suite too, to prove S3 didn't regress provider capture:
node --import "$JITI_REG" extension/tests/provider-capture.test.ts
# Expected: exit 0, fail 0 (S2's pass count unchanged).
```

### Level 3: Integration Testing (System Validation) — THE RUNTIME GATE (UPDATED)

```bash
# Load the extension through the REAL pi runtime via jiti in --print mode.
# --print runs with ctx.mode === "print", so AFTER S3 the guard short-circuits:
# the startup log line is SUPPRESSED and captureProvider does NOT run. This proves
# the file loads cleanly and the guard doesn't throw. (The guard's real behavior
# is proven by mode-guard.test.ts in Level 2; here we only prove clean load.)
pi --no-extensions -e ./extension/pi-editor-bridge.ts --print "ok" 2>&1 | tee /tmp/pi-editor-bridge-s3.log

# PASS condition 1: pi exited 0 (the `ok` print succeeded through the session).
echo "exit=$? (check the pipeline's real status separately if needed)"
pi --no-extensions -e ./extension/pi-editor-bridge.ts --print "ok" >/dev/null 2>&1; echo "pi exit=$?"

# PASS condition 2: NO errors during load/handler invocation.
grep -iE "error|cannot|fail|throw|unhandled|is not a function|TypeError" /tmp/pi-editor-bridge-s3.log \
  && echo "FAIL: error present" || echo "PASS: no errors"

# PASS condition 3 (THE S3-SPECIFIC ONE): the startup log is ABSENT in print mode.
#   (Contrast with S1/S2, where this line WAS present. Its absence proves the guard
#   fired before the console.log.)
grep -c "pi-editor-bridge: session_start (reason=startup" /tmp/pi-editor-bridge-s3.log | grep -q '^0$' \
  && echo "PASS: startup log suppressed in print mode (guard works)" \
  || echo "FAIL: startup log appeared in print mode — guard missing or below the log"
# Expected: all three PASS conditions hold; pi prints "ok" output and exits 0.
```

### Level 4: Creative & Domain-Specific Validation

```bash
# Confirm the factory still exports cleanly and the guard didn't break the default
# export shape pi consumes:
node --import /home/dustin/.local/lib/node_modules/@earendil-works/pi-coding-agent/node_modules/jiti/lib/jiti-register.mjs \
  -e 'import("./extension/pi-editor-bridge.ts").then(m => { console.log("has default:", typeof m.default === "function"); console.log("has captureProvider:", typeof m.captureProvider === "function"); console.log("has getProvider:", typeof m.getProvider === "function"); })'
# Expected: default is a function; captureProvider/getProvider still present (S2 intact).

# Confirm zero new runtime npm deps (S3 adds no value imports):
grep -nE '^import [^{]' extension/pi-editor-bridge.ts \
  && echo "FAIL: found a value import — should be type-only" \
  || echo "PASS: only import type present (loads with zero node_modules at top level)"

# Sanity: the global-load path still works (simulates end-user install):
mkdir -p ~/.pi/agent/extensions
cp extension/pi-editor-bridge.ts ~/.pi/agent/extensions/pi-editor-bridge.ts
pi --print "ok" 2>&1 | grep -E "error|cannot|fail" && echo "FAIL" || echo "PASS: global-load OK"
rm -f ~/.pi/agent/extensions/pi-editor-bridge.ts   # clean up (don't leave installed during dev)
```

## Final Validation Checklist

### Technical Validation

- [ ] Level 1: `tsc --noEmit -p extension/tsconfig.json` → exit 0, no output.
- [ ] Level 2 (CONTRACT GATE): `node --import <jiti-register> extension/tests/mode-guard.test.ts`
      → exit 0, `fail` 0 (`pass` ≥ 2); S2's `provider-capture.test.ts` still green.
- [ ] Level 3 (RUNTIME GATE, UPDATED): `pi --no-extensions -e ./extension/pi-editor-bridge.ts --print "ok"`
      exits 0 with NO error lines AND the startup-log line is ABSENT in print mode.
- [ ] Level 4: default export is a function; S2's `captureProvider`/`getProvider` still present; only `import type`.

### Feature Validation

- [ ] The session_start handler's first executable statement is `if (ctx.mode !== "tui") return;`.
- [ ] A Mode-A JSDoc block comment sits immediately above the guard, citing the RPC
      no-op (`rpc-mode.ts:271-273`) and TUI-only `openExternalEditor`.
- [ ] The S2 startup `console.log` is BELOW the guard (TUI-only); the `// TODO(S3)`
      marker is DELETED.
- [ ] `captureProvider(ctx)` call, the `// TODO(M2)`/`// TODO(S16)` line, and the
      entire `session_shutdown` handler are UNCHANGED; session_shutdown is UNGUARDED.
- [ ] Test asserts: handler does NOT call `addAutocompleteProvider` for rpc/json/print;
      DOES call it for tui.
- [ ] NO socket / env write / commandsChanged / packaging code added.

### Code Quality Validation

- [ ] Edits applied ON TOP of the S1+S2 file (not a rewrite); S1+S2 structure preserved.
- [ ] TAB indentation; `import type` discipline maintained; no new imports.
- [ ] Guard uses `!== "tui"` (per contract), not an inverted `=== "tui"` body.
- [ ] JSDoc notes that all future session_start logic MUST go below the guard.
- [ ] File-level STATUS block updated (S3 done; log now TUI-only; M2/S16/S17 pending).

### Documentation & Deployment

- [ ] Mode-A JSDoc on the guard explains the "why" (RPC no-op + TUI-only editor).
- [ ] File-level JSDoc STATUS block reflects S3 completion + the validation-behavior change.
- [ ] No new env vars WRITTEN (the JSDoc continues to merely document the future `PI_EDITOR_BRIDGE`).

---

## Anti-Patterns to Avoid

- ❌ Don't place the guard BELOW the `console.log` (S2's TODO hinted there). The S3
  contract is explicit: "At the TOP of the session_start handler ... short-circuit
  ALL bridge logic." The log is bridge logic → it goes below the guard.
- ❌ Don't grep the `--print` load output for the startup log (S1/S2 did). After S3 the
  guard suppresses that line in print mode; the correct Level-3 assertion is its ABSENCE.
- ❌ Don't invert the guard into `if (ctx.mode === "tui") { ...big block... }` — use the
  contract's early-return form `if (ctx.mode !== "tui") return;` so later tasks simply
  append code below it without re-indenting a growing block.
- ❌ Don't add a guard to `session_shutdown`. Shutdown stays callable in all modes (it's
  a no-op now; idempotent cleanup later). Guarding it would risk leaking resources.
- ❌ Don't add per-task TUI guards later (in M2/S16/S17). The single top-of-session_start
  guard is the design; later code goes BELOW it and is auto-protected.
- ❌ Don't change `captureProvider`, `getProvider`, `liveProvider`, the imports, or the
  tsconfig `paths` — those are S2's, and S3 doesn't need them. S3 is a 3-line edit + a test.
- ❌ Don't add socket/env/commandsChanged/packaging code — those are M2/S16/S17/S18.
- ❌ Don't make the test depend on `getProvider()` or the `liveProvider` singleton — assert
  only on `addAutocompleteProvider` call counts, so the test is robust to module-state order.
