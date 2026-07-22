# PRP — P1.M3.T8.S16: Write BridgeDescriptor JSON to `process.env.PI_NVIM_BRIDGE`

## Goal

**Feature Goal**: Make pi's spawned `$EDITOR` (Neovim) discoverable to the
`pi-bridge.nvim` plugin by writing a single-line JSON `BridgeDescriptor` to
`process.env.PI_NVIM_BRIDGE` inside the `pi-editor-bridge` extension's
`startBridge()`, and symmetrically deleting it in `stopBridge()`. This is the
**discovery mechanism** that lets the dormant Neovim plugin find the bridge's Unix
socket + auth token and activate.

**Deliverable**:
- Modify `extension/pi-editor-bridge.ts`:
  - Add `export const BRIDGE_ENV = "PI_NVIM_BRIDGE";`
  - In `startBridge(ctx)` (after `listen` + `chmod`), write
    `process.env[BRIDGE_ENV] = JSON.stringify(<BridgeDescriptor> satisfies BridgeDescriptor)`.
  - In `stopBridge()` (after `token = undefined;`), `delete process.env[BRIDGE_ENV];`.
  - Update the three placeholder NOTE comments (`startBridge`, `stopBridge`,
    `session_shutdown`) that deferred this work to S16.
  - [Mode A] JSDoc on the env write explaining the `process.env` inheritance
    discovery + criticality.
- Create `extension/tests/bridge-env.test.ts` — mocked exact-shape, delete-on-stop,
  idempotent re-write, and full factory-wiring (tui sets / shutdown deletes /
  non-tui never sets) tests.

**Success Definition**:
- `process.env.PI_NVIM_BRIDGE` is a single-line JSON string after `startBridge`,
  parses to an object with EXACTLY 7 keys — `transport:"unix"`, `path` (the live
  socket path), `token` (32-hex), `pid` (`process.pid`), `cwd` (`ctx.cwd`),
  `fdAvailable` (real `getFdAvailable()` value), `serverVersion:"0.1.0"`.
- `process.env.PI_NVIM_BRIDGE === undefined` after `stopBridge`.
- `tsc --noEmit -p extension/tsconfig.json` exits 0; all regression suites
  (`bridge-lifecycle`, `bridge-lifecycle-wiring`, `mode-guard`, `provider-capture`,
  `protocol`) still pass.
- No source code beyond `extension/pi-editor-bridge.ts` is touched; no `tsconfig`
  edit (the `tests/**/*.ts` glob auto-includes the new test).

## Why

- **This is the single public seam that makes the two-component design work** (PRD
  §2.1: *"This is the discovery that makes the whole design work."*). pi spawns the
  external editor with `stdio:"inherit"` and **no `env:` option**, so the child
  Neovim inherits pi's `process.env`. Anything the extension writes to
  `process.env.PI_NVIM_BRIDGE` before the launch is visible to Neovim as
  `vim.env.PI_NVIM_BRIDGE`. The Neovim plugin's `VimEnter` gate decodes it to find
  the socket path + token; without this write, the plugin never activates and the
  bridge is unreachable.
- Closes out `P1.M3` dependency "env advertisement" which the upcoming Neovim-side
  tasks (`P2.M4.T12.S21` activation gate) consume directly. `S17` (commandsChanged)
  and `S18` (packaging) are the only remaining P1.M3 items after this.
- Integrates with already-built pieces: the socket server (`P1.M2.T3`), the token
  (`S5`), and the `hello`/`ping` handlers (`S9`/`S14`) that already return
  `serverVersion`/`fdAvailable`/`cwd` to the client. This task makes the
  **pre-handshake descriptor** carry the same fields so the three sources agree.

## What

User-visible behavior: none directly (this is a pi extension writing a process-local
env var). Indirectly, it is what causes `pi-bridge.nvim` to wake up inside the
launched Neovim and show `/command`, `@file`, and path completion.

Technical requirement: a flat JSON object (the `BridgeDescriptor` type already
declared in `extension/protocol.ts` §B) is `JSON.stringify`'d and assigned to
`process.env.PI_NVIM_BRIDGE` at the end of `startBridge`, and `delete`'d in
`stopBridge`.

### Success Criteria

- [ ] `process.env.PI_NVIM_BRIDGE` set after `startBridge`; deleted after `stopBridge`.
- [ ] Descriptor field is **`serverVersion: "0.1.0"`** (NOT `version`/`"0.0.1"`).
- [ ] Descriptor `fdAvailable` is the **real `getFdAvailable()`** value (consistent
      with `hello`/`ping`), not a hardcoded literal.
- [ ] Descriptor built with `satisfies BridgeDescriptor` (compile-time guard against
      the `version` typo).
- [ ] Descriptor string contains no `\n` (single-line, safe env value).
- [ ] `tsc --noEmit` exits 0; all regression suites green.
- [ ] [Mode A] JSDoc documents the `process.env` inheritance discovery.

## All Needed Context

### Context Completeness Check

_Passes "No Prior Knowledge":_ the implementer needs only this PRP + the two files
named below (`extension/pi-editor-bridge.ts`, `extension/protocol.ts`) + the verified
build/test commands. Every pattern (`__deps` seam, getters, `captureHandlers`/
`makeCtx` wiring) is reproduced or cited with exact line references.

### Documentation & References

```yaml
# MUST READ before editing
- url: PRD §2.1 (editor launch + process.env inheritance) + §4 step 2 + §6.4 (server lifecycle skeleton) + §7.1 (Neovim VimEnter gate)
  file: PRD.md   # (already provided verbatim in this PRP's <selected_prd_content>)
  why: "§6.4 is the literal code skeleton to mirror: `process.env[BRIDGE_ENV] = JSON.stringify({transport,path,token,pid,cwd,fdAvailable,serverVersion})` as the LAST line of startBridge, after listen+chmod; `delete process.env[BRIDGE_ENV]` in stopBridge."
  critical: "§6.4 uses `serverVersion:'0.1.0'` and `fdAvailable: !!fdPathAvailable()`. PRD §4 PROSE uses `version:'0.0.1'` and `fdAvailable:true`. The CODE authorities win — see Gotchas #1/#2."

- file: extension/pi-editor-bridge.ts
  why: "The ONLY source file to modify. Read `startBridge`, `stopBridge`, the getters (`getSocketPath/getToken/getPid/getCwd/getFdAvailable`), `BRIDGE_VERSION`, `__deps`, and the default-export factory's `session_start`/`session_shutdown`."
  pattern: "module-level `let server/socketPath/token/cwd` + getters; `__deps` mutable seam; `startBridge(ctx)` ends with `// NOTE: NO process.env.PI_NVIM_BRIDGE write here — that is P1.M3.T8.S16.` and `void ctx;`; `stopBridge()` ends with the matching OMITTED NOTE; factory `session_start` has `// TODO(S16): advertise via process.env.PI_NVIM_BRIDGE` and `session_shutdown` has `// NOTE: clearing process.env.PI_NVIM_BRIDGE belongs to S16`."
  gotcha: "All THREE NOTE comments must be resolved/updated by this task. `ctx.cwd` is read via `cwd = ctx.cwd;` in session_start AFTER startBridge returns — so inside startBridge use `ctx.cwd` DIRECTLY for the descriptor (the module `cwd` is not yet set there). See Implementation Notes."

- file: extension/protocol.ts
  why: "Defines the authoritative `BridgeDescriptor` type (§B): `{ transport:'unix'; path:string; token:string; pid:number; cwd:string; fdAvailable:boolean; serverVersion:string }`. IMPORT this type (type-only) and build the literal with `satisfies BridgeDescriptor`."
  pattern: "type-only module — importing it has zero runtime cost (verified by protocol.test.ts: the module namespace is an empty object at runtime)."
  gotcha: "The field is `serverVersion`, NOT `version`. The transport literal is `\"unix\"`."

- file: extension/tests/protocol.test.ts
  why: "PINS the exact BridgeDescriptor literal the descriptor must equal: `{transport:'unix', path:'/tmp/pi-editor-bridge-x.sock', token:'deadbeef', pid:4242, cwd:'/home/u/proj', fdAvailable:true, serverVersion:'0.1.0'}`. Confirms field name `serverVersion` + value `'0.1.0'`."

- file: extension/tests/bridge-lifecycle.test.ts
  why: "S5 test suite — the EXACT pattern to mirror for the new mocked exact-shape test: snapshot `__deps.createServer`/`__deps.chmodSync`, build a fakeServer (`listen(arg)` records+returns self, `close()` no-op, `on()` no-op), restore in `finally`. Note its `fakeCtx = {} as ExtensionContext` lacks `cwd` (see Gotchas #3)."

- file: extension/tests/bridge-lifecycle-wiring.test.ts
  why: "S6 test suite — provides the `captureHandlers()` (fake pi that records session_start/session_shutdown handlers) + `makeCtx(mode)` helpers to REUSE for the new factory-wiring test. `makeCtx` currently provides `{mode, ui:{addAutocompleteProvider:()=>{}}}` with NO `cwd` — the new test passes its own ctx with `cwd`."

- docfile: plan/001_c56962b4fa17/P1M3T8S16/research/notes.md
  why: "Full research notes for this task (authoritative; supersedes the stale precursor at P1M3T1S1/research/notes.md). Covers make-or-break decisions, Node process.env semantics, test design, scope guard."
  section: "§2 (fdAvailable MUST use getFdAvailable, not hardcode true — STALE-NOTE CORRECTION); §3 (where/what to write); §7 (test design); §9 (verified validation commands)."

- docfile: plan/001_c56962b4fa17/architecture/system_context.md
  why: "§1 cites interactive-mode.ts:3811-3816 — the editor spawn uses `{stdio:'inherit', shell:process.platform==='win32'}` with NO `env:` option, so the child inherits process.env. This is the factual basis for the [Mode A] JSDoc."
```

### Current Codebase tree (relevant slice)

```bash
extension/
  pi-editor-bridge.ts          # MODIFY: add BRIDGE_ENV, write in startBridge, delete in stopBridge, update NOTEs + JSDoc
  protocol.ts                  # READ-ONLY (consumes BridgeDescriptor type)
  connection.ts                # READ-ONLY (no change)
  jsonl-reader.ts              # READ-ONLY (no change)
  tsconfig.json                # READ-ONLY (no change — tests/**/*.ts auto-includes new test)
  tests/
    bridge-env.test.ts         # CREATE (new suite)
    bridge-lifecycle.test.ts   # READ-ONLY (pattern source; optional cwd one-liner)
    bridge-lifecycle-wiring.test.ts  # READ-ONLY (captureHandlers/makeCtx source)
    protocol.test.ts           # READ-ONLY (pinned descriptor literal)
    mode-guard.test.ts         # READ-ONLY (regression)
    provider-capture.test.ts   # READ-ONLY (regression)
    ... (S7–S15 suites)        # READ-ONLY (regression)
```

### Desired Codebase tree with files to be added/modified

```bash
extension/
  pi-editor-bridge.ts          # MODIFIED (startBridge writes env; stopBridge deletes env; NOTEs resolved; JSDoc added)
  tests/
    bridge-env.test.ts         # NEW — 4 tests: exact-shape / delete-on-stop / idempotent-rewrite / factory-wiring
```

### Known Gotchas of our codebase & Library Quirks

```typescript
// GOTCHA #1 — field is `serverVersion:"0.1.0"`, NOT `version:"0.0.1"`.
// PRD §4 PROSE says `"version":"0.0.1"`; PRD §6.4 CODE skeleton, the BridgeDescriptor
// TYPE (protocol.ts §B), and the pinned protocol.test.ts ALL say `serverVersion:"0.1.0"`.
// The CODE authorities win. GUARD with `satisfies BridgeDescriptor` (import from
// ./protocol.ts) so a `version:` typo is a TS error at the build site.

// GOTCHA #2 — `fdAvailable` MUST be `getFdAvailable()`, NOT hardcoded `true`.
// A precursor research note (P1M3T1S1/research/notes.md §2) argued for hardcoding
// `true` because no fd resolver existed. THAT PREMISE IS NOW FALSE: the current code
// ships a real `getFdAvailable()` resolver (mirrors pi's getToolPath("fd"): pi agent
// bin dir then PATH scan; cached; `__setFdAvailableForTest` seam), ALREADY wired into
// the `hello` (S9) and `ping` (S14) handler results. The descriptor MUST agree with
// those — otherwise the Neovim client sees contradictory fdAvailable values
// (descriptor vs hello vs ping), which breaks :checkhealth diagnostics
// (P3.M10.T27.S42). Use `fdAvailable: getFdAvailable()`.

// GOTCHA #3 — `ctx.cwd` ordering: inside startBridge the module-level `cwd` is NOT
// yet set. session_start does `startBridge(ctx);` THEN `cwd = ctx.cwd;`. So in the
// descriptor use `ctx.cwd` DIRECTLY (this is why startBridge finally stops doing
// `void ctx;`). Do NOT call getCwd() inside startBridge (returns stale/undefined).
// The `cwd = ctx.cwd;` line in session_start STAYS — it feeds getCwd() for hello/ping.

// GOTCHA #4 — JSON.stringify then ASSIGN (order matters). process.env assignment
// coerces to string via toString(), so a raw object becomes "[object Object]" (WRONG).
// `process.env[BRIDGE_ENV] = JSON.stringify(descriptor)`. JSON.stringify of a flat
// object emits NO embedded "\n" → single-line env value (safe; Neovim does
// vim.json.decode on the whole value). `delete process.env[BRIDGE_ENV]` never throws
// and is a no-op if absent (idempotent — safe whether or not startBridge ran).

// GOTCHA #5 — jiti does NOT live-bind `export let` reassignment (verified, S2 §1.2).
// This is why state is exposed via getters (getSocketPath/getToken/...) and why S16
// reads the in-scope module-level `socketPath`/`token` locals directly inside
// startBridge (they are guaranteed-set a few lines above the write site) rather than
// re-exporting them.

// GOTCHA #6 — process.env is SHARED across tests in one process. Every test MUST
// stopBridge() (deletes the env) in a `finally`, restore __deps overrides in a
// `finally`, and __setFdAvailableForTest(undefined) to reset the fd cache. Without
// this, test 1's env value leaks into test 2's "deleted" assertion.

// GOTCHA #7 — NO tsconfig edit. The `include: ["tests/**/*.ts"]` glob auto-includes
// bridge-env.test.ts. (S4/S7/S15 each had to append a file; S16 does NOT.)
// `tsc --noEmit -p extension/tsconfig.json` exits 0 today — keep it that way.
```

## Implementation Blueprint

### Data models and structure

The wire type ALREADY EXISTS in `extension/protocol.ts` §B — S16 CONSUMES it (does
NOT modify it). Reproduced here so the implementer sees the exact target:

```typescript
// extension/protocol.ts (READ-ONLY — already shipped by S4)
export interface BridgeDescriptor {
	transport: "unix";   // v1 literal (PRD §5.1 names a future TCP variant)
	path: string;
	token: string;
	pid: number;
	cwd: string;
	fdAvailable: boolean;
	serverVersion: string;
}
```

The runtime value S16 produces:

```typescript
// Target descriptor (built with `satisfies BridgeDescriptor` for a compile-time guard):
{
	transport: "unix",
	path: socketPath,            // module-level let, set a few lines above
	token,                       // module-level let, set a few lines above
	pid: process.pid,            // also exposed as getPid()
	cwd: ctx.cwd,                // read DIRECTLY from ctx (NOT getCwd() — see GOTCHA #3)
	fdAvailable: getFdAvailable(),// real resolver; consistent with hello/ping (GOTCHA #2)
	serverVersion: BRIDGE_VERSION,// exported const === "0.1.0" (NOT "0.0.1")
} satisfies BridgeDescriptor     // → JSON.stringify → process.env[BRIDGE_ENV]
```

### Implementation Tasks (ordered by dependencies)

```yaml
Task 1: MODIFY extension/pi-editor-bridge.ts — add the BRIDGE_ENV constant + BridgeDescriptor import
  - ADD: `export const BRIDGE_ENV = "PI_NVIM_BRIDGE";` at module level, placed near the
          `server`/`socketPath`/`token` state declarations (alongside the other exported
          constants like BRIDGE_VERSION). Exporting it lets the test reference the NAME
          (not a hardcoded string) and makes a future rename one-line.
  - ADD: `BridgeDescriptor` to the existing `import type { … } from "./protocol.ts";` block
          (the file already imports HelloParams, HelloResult, PingResult, etc. from there).
          Type-only import → zero runtime cost.
  - NAMING: `BRIDGE_ENV` (UPPER_SNAKE matching `BRIDGE_VERSION`, `GET_SUGGESTIONS_TIMEOUT_MS`).
  - PLACEMENT: constants cluster, before the `let server` declaration.

Task 2: MODIFY startBridge(ctx) — write the descriptor AFTER listen+chmod
  - REMOVE the `void ctx;` line (startBridge now dereferences `ctx.cwd`).
  - REMOVE/REPLACE the trailing `// NOTE: NO process.env.PI_NVIM_BRIDGE write here — that is P1.M3.T8.S16.`
    comment with the actual write + its [Mode A] JSDoc (Task 4).
  - ADD (as the LAST statement of startBridge, AFTER the `if (process.platform !== "win32") { … chmod … }` block):
        process.env[BRIDGE_ENV] = JSON.stringify({
            transport: "unix",
            path: socketPath,
            token,
            pid: process.pid,
            cwd: ctx.cwd,
            fdAvailable: getFdAvailable(),
            serverVersion: BRIDGE_VERSION,
        } satisfies BridgeDescriptor);
  - FOLLOW pattern: mirror PRD §6.4 skeleton exactly (the §6.4 write is the final line
          of startBridge). Use the in-scope module locals `socketPath`/`token`
          (guaranteed-set above), NOT the getters (getters are for cross-module
          consumers; inside startBridge the locals are the source of truth).
  - DEPENDENCIES: Task 1 (BRIDGE_ENV + BridgeDescriptor import).
  - PRESERVE: everything above (stopBridge() first-line idempotent teardown, token gen,
          socketPath gen, createServer, server.on("error",…), server.listen, chmod block).

Task 3: MODIFY stopBridge() — delete the env var
  - ADD (AFTER the `token = undefined;` line, REPLACING the trailing NOTE comment
          `// NOTE: delete process.env.PI_NVIM_BRIDGE is intentionally OMITTED here …`):
        delete process.env[BRIDGE_ENV];
  - WHY HERE: matches PRD §6.4 (stopBridge is the symmetric teardown). `delete` never
          throws and is a no-op if absent → safe whether or not startBridge ran
          (idempotent, consistent with the surrounding try/catch idiom — though delete
          itself needs no try/catch).
  - DEPENDENCIES: Task 1 (BRIDGE_ENV).
  - NOTE: session_shutdown's `// NOTE: clearing process.env.PI_NVIM_BRIDGE belongs to S16`
          comment is resolved automatically — session_shutdown calls stopBridge, which now
          deletes the env. Update/trim that comment to avoid a stale reference.

Task 4: ADD [Mode A] JSDoc — process.env inheritance discovery + criticality
  - ADD a JSDoc block immediately above the `process.env[BRIDGE_ENV] = …` write in
          startBridge. It MUST state (one tight paragraph is fine):
        - pi spawns the external editor via spawn() with `stdio:"inherit"` and NO
          `env:` option (interactive-mode.ts:3811-3816), so the child inherits pi's
          process.env. Writing PI_NVIM_BRIDGE on session_start (before any Ctrl+G
          launch) makes it visible to the spawned Neovim as
          `vim.env.PI_NVIM_BRIDGE`.
        - The Neovim plugin's VimEnter gate decodes this descriptor to find the socket
          path + token; absent/unparseable → plugin stays dormant (PRD §7.1).
        - CRITICALITY: this write is THE discovery that makes the two-component design
          work (PRD §2.1). Without it, the plugin never activates and the bridge is
          unreachable. Single-line JSON (no "\n") is the safe env-value contract.
  - DOCS MODE: [Mode A] = changeset-level JSDoc inline with the code (per the
          project's docs convention; this task's contract item #6).

Task 5: CREATE extension/tests/bridge-env.test.ts — 4 tests (node:test + jiti)
  - IMPORTS: `startBridge, stopBridge, getSocketPath, getToken, BRIDGE_ENV, __deps,
          __setFdAvailableForTest` from `../pi-editor-bridge.ts`; default-import the
          factory for the wiring test; types from `@earendil-works/pi-coding-agent`.
  - FOLLOW pattern: S5's `bridge-lifecycle.test.ts` (mocked exact-shape via the
          `__deps` seam) + S6's `bridge-lifecycle-wiring.test.ts` (`captureHandlers()`/
          `makeCtx()` for the factory test). Reuse the fakeServer shape: `{ listen(arg){
          listenArg=arg; return fakeServer; }, close(){}, on(){return fakeServer;} }`.
  - NAMING: `node:test` `test("…")` with descriptive titles; `assert` from
          `node:assert/strict`.
  - TEST 1 (mocked, exact descriptor shape): snapshot `__deps.createServer`/`chmodSync`;
          `__setFdAvailableForTest(true)`; `fakeCtx = { cwd:"/test/proj" } as ExtensionContext`.
          After startBridge: assert env is a string, `JSON.parse(env)` has transport===
          "unix", path===getSocketPath(), token===getToken(), pid===process.pid,
          cwd==="/test/proj", fdAvailable===true, serverVersion==="0.1.0"; raw string has
          no "\n"; EXACTLY 7 keys (Object.keys(parsed).length===7) — proves no stray
          `version` key leaked in. Restore __deps + fd cache + stopBridge in `finally`.
  - TEST 2 (stopBridge deletes): after startBridge, call stopBridge → env === undefined.
          ALSO assert stopBridge when env was never set is a safe no-op (delete on absent).
  - TEST 3 (idempotent re-write): startBridge twice (the 2nd call's internal stopBridge
          closes #1). After the 2nd, parsed path/token === 2nd getSocketPath()/getToken()
          (NOT the 1st). Each startBridge writes a FRESH descriptor.
  - TEST 4 (factory wiring — full lifecycle): reuse S6's `captureHandlers()` pattern;
          pass a ctx WITH cwd (e.g. `{ mode:"tui", ui:{addAutocompleteProvider:()=>{}},
          cwd:"/test/proj" }`). Assert: `session_start(tui)` → env set + parses with
          cwd==="/test/proj"; `session_shutdown` → env deleted (undefined); for each
          non-tui mode in ["rpc","json","print"], `session_start` does NOT set the env
          (TUI guard returns before startBridge — S3 regression preserved).
  - COVERAGE: positive (set/delete/idempotent/wiring) — that is the full surface for a
          3-line code change; no error-path branch exists (JSON.stringify/assignment/delete
          do not throw on these inputs).
  - PLACEMENT: `extension/tests/bridge-env.test.ts` (matches `tests/**/*.ts` glob →
          auto-included by tsconfig, NO tsconfig edit).
  - DEPENDENCIES: Tasks 1–4.

Task 6 (OPTIONAL cleanup, recommended one-liners): make S5/S6 ctxs well-formed
  - In `extension/tests/bridge-lifecycle.test.ts`: change `const fakeCtx = {} as
          ExtensionContext;` → `const fakeCtx = { cwd:"/test" } as ExtensionContext;`.
  - In `extension/tests/bridge-lifecycle-wiring.test.ts`: add `cwd:"/test"` to
          `makeCtx`'s returned object.
  - WHY: after S16, startBridge dereferences ctx.cwd; with cwd undefined, JSON.stringify
          OMITS the cwd key (tests 2/3 bind a real socket). These suites do NOT assert
          the env var (S16's job), so they pass WITHOUT this — but adding cwd makes the
          descriptor well-formed during their real-integration runs. NOT required for green.
```

### Implementation Patterns & Key Details

```typescript
// === startBridge — the env write is the FINAL line, after listen + chmod ===
export function startBridge(ctx: ExtensionContext): void {
	stopBridge(); // idempotent teardown of any prior server (reload/new/resume/fork)
	// (NO `void ctx;` anymore — ctx.cwd is now read below.)

	token = randomUUID().replace(/-/g, "").slice(0, 32);
	socketPath = join(tmpdir(), `pi-editor-bridge-${randomUUID()}.sock`);
	server = __deps.createServer((sock) => onConnection(sock));
	server.on("error", (err: Error) => {
		console.error(`pi-editor-bridge: socket server error (terminating bridge): ${err}`);
		stopBridge();
	});
	server.listen(socketPath);
	if (process.platform !== "win32") {
		try {
			__deps.chmodSync(socketPath, 0o600);
		} catch {
			/* best-effort */
		}
	}

	/**
	 * [Mode A] Advertise the bridge to the spawned $EDITOR via process.env.
	 *
	 * DISCOVERY: pi spawns the external editor with `spawn(editor, [tmpFile], {
	 * stdio:"inherit", shell: process.platform==="win32" })` and NO `env:` option
	 * (interactive-mode.ts:3811-3816), so the child Neovim INHERITS pi's process.env.
	 * Writing PI_NVIM_BRIDGE here (on session_start, before any Ctrl+G launch) makes
	 * it visible to the spawned Neovim as `vim.env.PI_NVIM_BRIDGE`. The plugin's
	 * VimEnter gate vim.json.decode's it to find the socket path + token; absent/
	 * unparseable → the plugin stays dormant (PRD §7.1). This write is THE discovery
	 * that makes the two-component design work (PRD §2.1). CRITICALITY: without it the
	 * plugin never activates and the bridge is unreachable. The descriptor is a flat
	 * JSON object → JSON.stringify emits a single line (no "\n") — the safe env value.
	 */
	process.env[BRIDGE_ENV] = JSON.stringify({
		transport: "unix",
		path: socketPath, // module-level let — guaranteed set above
		token, // module-level let — guaranteed set above
		pid: process.pid,
		cwd: ctx.cwd, // read DIRECTLY (module `cwd` is set in session_start AFTER startBridge)
		fdAvailable: getFdAvailable(), // REAL resolver — consistent with hello/ping (GOTCHA #2)
		serverVersion: BRIDGE_VERSION, // "0.1.0" — NOT "0.0.1" (GOTCHA #1)
	} satisfies BridgeDescriptor); // compile-time guard against the `version` typo
}

// === stopBridge — symmetric teardown ===
export function stopBridge(): void {
	try { server?.close(); } catch { /* idempotent */ }
	if (socketPath) {
		try { rmSync(socketPath, { force: true }); } catch { /* idempotent */ }
	}
	server = undefined;
	socketPath = undefined;
	token = undefined;
	delete process.env[BRIDGE_ENV]; // symmetric: clears the advertisement (no-op if absent)
}
```

```typescript
// === Test pattern (TEST 1) — mirror S5's mocked exact-shape style ===
import { test } from "node:test";
import assert from "node:assert/strict";
import type { ExtensionContext } from "@earendil-works/pi-coding-agent";
import {
	startBridge, stopBridge, getSocketPath, getToken, BRIDGE_ENV, __deps,
	__setFdAvailableForTest,
} from "../pi-editor-bridge.ts";

test("startBridge writes a valid single-line BridgeDescriptor to process.env.PI_NVIM_BRIDGE", () => {
	const realCreateServer = __deps.createServer;
	const realChmodSync = __deps.chmodSync;
	let listenArg: string | undefined;
	const fakeServer = {
		listening: false,
		listen(arg: string) { listenArg = arg; return fakeServer; },
		close() { /* no-op */ },
		on() { return fakeServer; },
	};
	__deps.createServer = (() => fakeServer) as unknown as typeof realCreateServer;
	__deps.chmodSync = (() => {}) as unknown as typeof realChmodSync;
	__setFdAvailableForTest(true); // deterministic fd value (GOTCHA #2/#6)
	try {
		const fakeCtx = { cwd: "/test/proj" } as ExtensionContext; // WITH cwd
		startBridge(fakeCtx);
		const raw = process.env[BRIDGE_ENV];
		assert.equal(typeof raw, "string", "env must be set");
		assert.ok(!raw!.includes("\n"), "descriptor must be a single line");
		const desc = JSON.parse(raw!);
		assert.equal(desc.transport, "unix");
		assert.equal(desc.path, getSocketPath());
		assert.equal(desc.token, getToken());
		assert.equal(desc.pid, process.pid);
		assert.equal(desc.cwd, "/test/proj");
		assert.equal(desc.fdAvailable, true);
		assert.equal(desc.serverVersion, "0.1.0"); // NOT version/0.0.1
		assert.equal(Object.keys(desc).length, 7, "exactly 7 keys — no stray `version`");
	} finally {
		__deps.createServer = realCreateServer;
		__deps.chmodSync = realChmodSync;
		__setFdAvailableForTest(undefined); // reset fd cache (GOTCHA #6)
		stopBridge(); // deletes the env var
	}
});
```

### Integration Points

```yaml
ENVIRONMENT (process.env):
  - add to: "process.env.PI_NVIM_BRIDGE (single-line JSON BridgeDescriptor) — written in startBridge, deleted in stopBridge"
  - pattern: "PRD §6.4 skeleton: process.env[BRIDGE_ENV] = JSON.stringify({...} satisfies BridgeDescriptor)"
  - constant: "export const BRIDGE_ENV = \"PI_NVIM_BRIDGE\"; (module-level, near BRIDGE_VERSION)"

TYPES (type-only import, no runtime cost):
  - add to: "the existing import type { … } from \"./protocol.ts\"; block in pi-editor-bridge.ts"
  - pattern: "add `BridgeDescriptor` to the comma list (alongside HelloParams, HelloResult, PingResult, …)"

NO OTHER INTEGRATION POINTS:
  - DATABASE: none
  - CONFIG: none (no new settings)
  - ROUTES: none
  - TSCONFIG: none (tests/**/*.ts glob auto-includes the new test — GOTCHA #7)
```

## Validation Loop

### Level 1: Syntax & Style (Immediate Feedback)

```bash
# Type-check the extension (VERIFIED: exits 0 today; must stay 0)
npx tsc --noEmit -p extension/tsconfig.json
# Expected: zero output, exit 0. If errors: READ them. The most likely failure is a
# `version`/`serverVersion` typo — `satisfies BridgeDescriptor` turns it into a hard
# TS error at the build site (the intended guard). Fix the field name, do NOT weaken
# the type.

# (No ruff/mypy — this is a TypeScript extension. tsc IS the linter+type-checker.)
```

### Level 2: Unit Tests (Component Validation)

```bash
# The jiti register path (VERIFIED to exist):
JITI_REG=/home/dustin/.local/lib/node_modules/@earendil-works/pi-coding-agent/node_modules/jiti/lib/jiti-register.mjs

# NEW suite — the deliverable
node --import "$JITI_REG" extension/tests/bridge-env.test.ts
# Expected: "ℹ fail 0". (Reporter is node:test, prints "ℹ pass N" / "ℹ fail N" — NOT TAP.)

# Regression suites — must stay green (startBridge/stopBridge signature + ctx usage changed)
node --import "$JITI_REG" extension/tests/bridge-lifecycle.test.ts          # S5
node --import "$JITI_REG" extension/tests/bridge-lifecycle-wiring.test.ts   # S6
node --import "$JITI_REG" extension/tests/mode-guard.test.ts                # S3 (TUI guard intact)
node --import "$JITI_REG" extension/tests/provider-capture.test.ts          # S2
node --import "$JITI_REG" extension/tests/protocol.test.ts                  # S4 (pinned descriptor literal)
# Expected: each prints "ℹ fail 0". If bridge-lifecycle* regress, the cause is the
# ctx.cwd dereference — see Task 6 (optional one-liner) or GOTCHA #3/#6.

# NOTE: jiti prints a benign "module.register() is deprecated" (DEP0205) on stderr — IGNORE.
```

### Level 3: Integration Testing (System Validation)

```bash
# Extension loads cleanly under pi (non-TUI path → guard returns BEFORE startBridge,
# so NO env var is written in --print mode; proves the TUI guard still shields headless use).
pi --no-extensions -e ./extension/pi-editor-bridge.ts --print "ok"
# Expected: exit 0, no error lines, "ok" echoed.

# (A full TUI end-to-end — launch pi, Ctrl+G to open $EDITOR=nvim, assert
# vim.env.PI_NVIM_BRIDGE is set inside nvim — is exercised by the Neovim-side
# activation-gate task P2.M4.T12.S21. S16's job is the WRITE; the READ is the
# plugin's. The factory-wiring test (TEST 4) covers the session_start/session_shutdown
# lifecycle at the unit level.)
```

### Level 4: Creative & Domain-Specific Validation

```bash
# (Optional) prove the descriptor round-trips through a real JSON decoder the way
# Neovim's vim.json.decode will consume it (P2.M4.T12.S21 contract):
node -e '
  const d = { transport:"unix", path:"/tmp/x.sock", token:"a".repeat(32),
              pid:1, cwd:"/p", fdAvailable:true, serverVersion:"0.1.0" };
  const s = JSON.stringify(d);
  console.log("single-line:", !s.includes("\n"));
  console.log("round-trip keys:", Object.keys(JSON.parse(s)).join(","));
'
# Expected: single-line: true ; round-trip keys: transport,path,token,pid,cwd,fdAvailable,serverVersion
```

## Final Validation Checklist

### Technical Validation

- [ ] `npx tsc --noEmit -p extension/tsconfig.json` exits 0 (zero output).
- [ ] `node --import "$JITI_REG" extension/tests/bridge-env.test.ts` → `ℹ fail 0` (4 tests pass).
- [ ] All regression suites green (`bridge-lifecycle`, `bridge-lifecycle-wiring`,
      `mode-guard`, `provider-capture`, `protocol`, and S7–S15 suites).
- [ ] No tsconfig edit made (the `tests/**/*.ts` glob auto-includes the new test).
- [ ] No file other than `extension/pi-editor-bridge.ts` (source) +
      `extension/tests/bridge-env.test.ts` (new) is modified (Task 6's optional
      one-liners excepted, if applied).

### Feature Validation

- [ ] `process.env.PI_NVIM_BRIDGE` set after `startBridge`; deleted after `stopBridge`.
- [ ] Descriptor field is `serverVersion:"0.1.0"` (NOT `version`/`"0.0.1"`) — pinned by
      TEST 1's `Object.keys(desc).length === 7` + `desc.serverVersion === "0.1.0"`.
- [ ] Descriptor `fdAvailable` is the real `getFdAvailable()` value (consistent with
      `hello`/`ping`) — NOT hardcoded `true`.
- [ ] Descriptor built with `satisfies BridgeDescriptor` (compile-time typo guard).
- [ ] Descriptor string is single-line (no `"\n"`).
- [ ] Idempotent: repeated `startBridge` writes a FRESH descriptor each time (TEST 3).
- [ ] Non-TUI sessions never write the env var (TEST 4 — S3 regression preserved).
- [ ] [Mode A] JSDoc documents the process.env inheritance discovery + criticality.

### Code Quality Validation

- [ ] `BRIDGE_ENV` exported + referenced by name in the test (no hardcoded string).
- [ ] The three deferral NOTE comments (`startBridge`, `stopBridge`, `session_shutdown`)
      are resolved/updated (no stale "S16 will add this" references left).
- [ ] Follows existing patterns: `__deps` seam, module-level state + getters, factory
      wiring via `registerBridgeHandler` (untouched here), `satisfies` type-guarding.
- [ ] `ctx.cwd` read directly in startBridge (GOTCHA #3); module `cwd` getter untouched.
- [ ] No token/descriptor value logged anywhere (PRD §12 — token is the auth boundary).

### Documentation & Deployment

- [ ] [Mode A] JSDoc inline with the `process.env[BRIDGE_ENV]` write (Task 4).
- [ ] No new env vars beyond `PI_NVIM_BRIDGE` (scope guard §8).
- [ ] (README/doc/pi-editor.txt are separate tasks — S18/P3.M11 — NOT this task.)

---

## Anti-Patterns to Avoid

- ❌ Don't use `version`/`"0.0.1"` — use `serverVersion`/`"0.1.0"` (the type + pinned
  test + §6.4 skeleton agree; §4 prose is drift). The `satisfies BridgeDescriptor`
  guard makes this a compile error if you get it wrong.
- ❌ Don't hardcode `fdAvailable: true` — use `getFdAvailable()`. The precursor note
  that said hardcode was written before the resolver existed; the resolver now exists
  and is already used by `hello`/`ping`. Hardcoding creates a descriptor that
  contradicts the handshake results.
- ❌ Don't call `getCwd()` inside `startBridge` — the module `cwd` isn't set until
  `session_start` runs `cwd = ctx.cwd;` AFTER startBridge returns. Use `ctx.cwd` directly.
- ❌ Don't assign a raw object to `process.env[BRIDGE_ENV]` — it becomes
  `"[object Object]"`. Always `JSON.stringify` first.
- ❌ Don't edit `tsconfig.json` — the `tests/**/*.ts` glob already covers the new test.
- ❌ Don't modify `protocol.ts`, `connection.ts`, `jsonl-reader.ts`, or any handler —
  S16 only CONSUMES the existing `BridgeDescriptor` type. Scope guard §8.
- ❌ Don't skip test cleanup (`finally { stopBridge(); restore __deps; reset fd cache; }`)
  — process.env leaks across tests in one process (GOTCHA #6).
- ❌ Don't log the token or the full descriptor value (PRD §12).
