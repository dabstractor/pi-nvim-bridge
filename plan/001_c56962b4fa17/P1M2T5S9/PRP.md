name: "P1.M2.T5.S9 — hello handshake (validate token → success | -32600 + close)"
description: "pi-editor-bridge extension (TS). Register the `hello` JSON-RPC handler: validate the client token against the bridge secret, reply `HelloResult` on match (and flip `ConnectionState.handshakeComplete`), or reply `-32600 \"bad token\"` and gracefully close the socket on mismatch. Introduces the typed `BridgeRpcError` escape hatch that S15 later builds on. node:test + jiti (NOT vitest)."

---

## Goal

**Feature Goal**: The pi-editor-bridge socket server implements the `hello`
handshake (PRD §5.3): the first thing a Neovim client sends after connecting is
`{"jsonrpc":"2.0","id":"h1","method":"hello","params":{"token":"…",…}}`. The
server validates `params.token` against its own secret (`getToken()`). On a
match it replies `{"jsonrpc":"2.0","id":"h1","result":{"ok":true,"serverVersion":…,"cwd":…,"fdAvailable":…}}`
and marks the connection authenticated. On a mismatch it replies
`{"jsonrpc":"2.0","id":"h1","error":{"code":-32600,"message":"bad token"}}` and
**closes that connection**. This is the auth boundary for the whole bridge
(PRD §12).

**Deliverable**:
1. `extension/connection.ts` — a typed `BridgeRpcError` class + a one-block
   refinement of `handleLine`'s request-catch so a thrown `BridgeRpcError`
   becomes a spec-correct error response (and, when `fatal`, a graceful
   `sock.end()`). This is the MINIMAL, justified change that lets `hello`
   express "send -32600 then close".
2. `extension/pi-editor-bridge.ts` — `BRIDGE_VERSION`, a stored `cwd`
   (`getCwd()`), a self-contained cached `getFdAvailable()`, a pure
   `makeHelloHandler(deps)` factory, and `hello` registration wired into the
   TUI-guarded `session_start` handler.
3. `extension/tests/hello-handler.test.ts` (NEW) + additions to
   `extension/tests/connection.test.ts` — `node:test` + jiti.

**Success Definition**: With the bridge running, a client that sends the correct
token receives a `HelloResult` and can proceed; a client that sends a wrong
token receives exactly one `-32600 "bad token"` line and then an EOF. `tsc
--noEmit` is clean; the new suites pass; **all 13 existing connection tests
still pass** (the `BridgeRpcError` refinement is backward-compatible — a plain
`Error` throw still maps to `-32603`).

---

## User Persona

**Target User**: The `pi-bridge.nvim` Neovim plugin (P2.M5) — the bridge's only
client. (Indirectly: the human editing a pi prompt in their `$EDITOR`.)

**Use Case**: On `VimEnter`, after reading `PI_NVIM_BRIDGE`, the plugin opens
a socket connection and immediately sends `hello` with the token. Until `hello`
succeeds it sends nothing else.

**Pain Points Addressed**: Without an auth handshake, any local process could
connect to the socket and drive pi's completion engine / read the cwd. The
token (delivered process-locally via `process.env`, PRD §12) plus this handshake
is the boundary; "bad token → close" prevents brute-force chatter.

---

## Why

- **Security gate (PRD §12)**: the Unix socket lives in `os.tmpdir()`; the
  32-hex token is the real auth boundary. `hello` is where it is enforced.
- **Unblocks P2.M5**: the Neovim `bridge.lua` handshake (S25) is the mirror of
  this task — it cannot be built/tested until the server speaks `hello`.
- **Foundation for S10/S15**: S9 sets `ConnectionState.handshakeComplete`
  (which S10 gates every other method on) and introduces `BridgeRpcError`
  (which S15 uses to wrap every handler's domain errors into proper codes).
- **Reuse for S16/S17**: `BRIDGE_VERSION`, `getCwd()`, `getFdAvailable()` are
  introduced here and reused by the `PI_NVIM_BRIDGE` descriptor (S16).

---

## What

### User-visible behavior (wire)

Per PRD §5.3, the server MUST, for the first `{method:"hello"}` request on a
connection:

| Case | Server reply | Side effect |
|---|---|---|
| `params.token` === server token | `{jsonrpc,id,result:HelloResult}` | `state.handshakeComplete = true` |
| `params.token` ≠ server token / missing / wrong type / no expected token set | `{jsonrpc,id,error:{code:-32600,message:"bad token"}}` | graceful `sock.end()` (flush error → FIN) |

`HelloResult = { ok:true, serverVersion:BRIDGE_VERSION, cwd:getCwd(), fdAvailable:getFdAvailable() }`
(types already declared in `protocol.ts` — consume, don't redeclare).

### Success Criteria

- [ ] A correct-token `hello` → exactly one success envelope + `handshakeComplete===true`.
- [ ] A wrong/missing/untyped-token `hello` → exactly one `-32600 "bad token"` envelope, then the socket closes (client sees EOF). The token value is NEVER in any response/log.
- [ ] `hello` works when `client`/`clientVersion` params are present (ignored) or absent.
- [ ] `fdAvailable` reflects whether `fd`/`fdfind` is resolvable (pi bin dir or PATH).
- [ ] `BridgeRpcError(code,msg)` (non-fatal) → that code, socket stays open; plain `Error` throw → `-32603` (regression-safe).
- [ ] Re-registering `hello` on each `session_start` (reload/new/resume/fork) is safe (idempotent `Map.set`); a stopped bridge (`getToken()===undefined`) rejects `hello` as bad token.
- [ ] `tsc --noEmit -p extension/tsconfig.json` ⇒ exit 0, no output.
- [ ] New suites pass; existing 13 connection tests still pass.

---

## All Needed Context

### Context Completeness Check

_"If someone knew nothing about this codebase, would they have everything needed
to implement this successfully?"_ — Yes. The dispatch skeleton, registry,
response writers, per-connection state, and ALL protocol types already exist
(S8/S4). This PRP specifies the ONE minimal `connection.ts` enhancement, the
exact handler factory, the exact wiring point, the fd-availability resolver, and
the exact test commands. No guessing.

### Documentation & References

```yaml
# MUST READ — the governing spec
- url: PRD §5.3 (Connection lifecycle & handshake) + §5.4 (hello row) + §12 (Security)
  why: "defines the exact hello request/result/error envelopes, the -32600 'bad token' code, and 'then close'; token never logged"
  critical: "success result fields are {ok:true,serverVersion,cwd,fdAvailable}; failure is -32600 + socket close (NOT a -32603)"

# MUST READ — the files this task builds on (READ BEFORE EDITING)
- file: extension/connection.ts
  why: "S8 dispatch skeleton — registerBridgeHandler, ConnectionState.handshakeComplete, sendError/sendResponse, handleLine (the catch you refine), onConnection"
  pattern: "MethodHandler = (params,state)=>unknown; module-level handler Map; response writers; never-throws-from-the-loop"
  gotcha: "MethodHandler has NO sock/id — that's WHY BridgeRpcError is needed for the -32600+close path (research §2). connection.ts must NOT import pi-editor-bridge.ts (import cycle — research §6 of S8)."

- file: extension/protocol.ts
  why: "HelloParams / HelloResult are ALREADY declared here (§C) + mapped in BridgeParamsMap/BridgeResultMap (§D). CONSUME them — do NOT redeclare."
  pattern: "ok is the literal true; empty-ish results use the mapped types; JsonRpcError = {code,message} (no data field)"
  gotcha: "protocol.ts is TYPES-ONLY (zero runtime exports) — so BridgeRpcError (a runtime class) goes in connection.ts, NOT here."

- file: extension/pi-editor-bridge.ts
  why: "getToken() (the secret), startBridge/stopBridge (lifecycle), session_start handler (the wiring point), __deps seam convention, the existing getter idiom (getProvider/getSocketPath/getToken) — mirror it for getCwd"
  pattern: "module `let` state exposed via getters (jiti does NOT live-bind `export let` — research §1.2 of S5); TUI guard at the top of session_start; startBridge(ctx) currently does `void ctx`"
  gotcha: "ctx.cwd is reserved-comment in startBridge but HelloResult.cwd is required NOW — store it (set `cwd = ctx.cwd` in session_start). Register hello AFTER startBridge so the token exists."

- file: extension/tests/connection.test.ts
  why: "the EXACT node:test+assert/strict+jiti pattern: fakeSocket() helper, registerBridgeHandler+__resetHandlersForTest in try/finally, ONE real Unix-socket-pair integration test (test 13)"
  pattern: "fakeSocket = EventEmitter + write(captures lines) + destroy(emit close); parseResponses(); readFirstResponse(client)"
  gotcha: "DO NOT use vitest. fakeSocket currently lacks end() — ADD it (record + emit close) so the fatal-close path is assertable. Adding a 3rd return key is backward-compatible with the 13 existing destructures."

# Reference — pi internals (for CONFIDENCE / mirroring, NOT to import)
- file: <pi>/dist/utils/tools-manager.js  (getToolPath / ensureTool)
  why: "the fd-resolution logic to MIRROR for getFdAvailable (pi bin dir first, then PATH; fd + fdfind on Linux)"
  critical: "getToolPath/ensureTool are NOT exported from @earendil-works/pi-coding-agent (grep index.d.ts ⇒ 0 hits) — a deep import is fragile; REIMPLEMENT self-contained instead (research §4)."
- file: <pi>/dist/modes/rpc/rpc-mode.js  (handleInputLine ~L582)
  why: "pi's OWN dispatch uses a generic try/catch → single error() helper (NO typed RPC errors). BridgeRpcError is a bridge-specific REFINEMENT — still spec-correct JSON-RPC 2.0."
- file: <pi>/dist/core/extensions/types.d.ts  (ExtensionContext.cwd)
  why: "confirms ctx.cwd:string is available on the context handed to session_start"
- file: <pi>/dist/config.js  (getBinDir = join(getAgentDir(),"bin"); getAgentDir honors $PI_CODING_AGENT_DIR / XDG_DATA_HOME)
  why: "the exact location to check for a pi-downloaded fd in getFdAvailable"

# Prior plan context (READ for rationale; do NOT copy code blindly)
- docfile: plan/001_c56962b4fa17/P1M2T5S9/research/notes.md
  section: "§2 (the design problem + Option B decision), §4 (fdAvailable), §7 (test convention)"
  why: "the why behind every non-obvious choice in this PRP"
```

`<pi>` = `/home/dustin/.local/lib/node_modules/@earendil-works/pi-coding-agent`.

### Current Codebase tree

```bash
extension/
├── pi-editor-bridge.ts     # S1/S3/S5/S6: lifecycle, provider capture, start/stopBridge, getToken/getSocketPath/getServer
├── protocol.ts             # S4: ALL wire types incl. HelloParams/HelloResult (TYPES-ONLY)
├── jsonl-reader.ts         # S7: attachJsonlLineReader, serializeJsonLine
├── connection.ts           # S8: ConnectionState, registerBridgeHandler, send*, handleLine, onConnection  ← EDIT (add BridgeRpcError + refine catch)
├── tsconfig.json
└── tests/
    ├── provider-capture.test.ts   # S2
    ├── mode-guard.test.ts         # S3
    ├── protocol.test.ts           # S4
    ├── bridge-lifecycle.test.ts   # S5/S6 (uses __deps seam, getToken)
    ├── bridge-lifecycle-wiring.test.ts  # S6 (session_start↔startBridge wiring)
    ├── jsonl-reader.test.ts       # S7
    └── connection.test.ts         # S8 (13 tests)  ← EDIT (add BridgeRpcError-mapping tests; extend fakeSocket)
```

### Desired Codebase tree (files this task touches)

```bash
extension/
├── connection.ts                       # MODIFY: + BridgeRpcError class; refine handleLine request-catch (instanceof → code; fatal → sock.end())
├── pi-editor-bridge.ts                 # MODIFY: + BRIDGE_VERSION, cwd+getCwd, getFdAvailable(+resolver+seam), makeHelloHandler, register "hello" in session_start
└── tests/
    ├── connection.test.ts              # MODIFY: extend fakeSocket with end(); +3 BridgeRpcError-mapping tests
    └── hello-handler.test.ts           # CREATE: node:test+jiti — makeHelloHandler unit (good/bad/missing/undefined-token, cwd fallback, client fields ignored); dispatch round-trip; ONE real Unix-socket integration (success + bad-token→disconnect)
```

### Known Gotchas of our codebase & Library Quirks

```ts
// CRITICAL: MethodHandler = (params, state) => unknown has NO sock/id.
//   The hello FAILURE path (-32600 + close) CANNOT be expressed by returning a
//   value (handleLine would send a SUCCESS response). It MUST throw. But S8's
//   catch maps every throw to -32603. => introduce BridgeRpcError(code,msg,{fatal})
//   and map it in the catch. (research §2 — zero-change was proven impossible.)

// CRITICAL: connection.ts must NOT import pi-editor-bridge.ts (import cycle
//   breaks jiti's ESM load — S8 research §2). The handler is registered FROM
//   pi-editor-bridge.ts (one-directional import). BridgeRpcError lives in
//   connection.ts so the handler can import it without a cycle.

// CRITICAL: jiti does NOT live-bind `export let` across modules (S5 research
//   §1.2). Expose mutable state via GETTERS (mirror existing getToken/getProvider).
//   => getCwd() reads the module `let cwd` each call.

// CRITICAL: protocol.ts is TYPES-ONLY ("zero runtime exports"). BridgeRpcError
//   is a runtime class => it goes in connection.ts, NOT protocol.ts.

// GOTCHA: sock.end() (graceful, flushes the queued -32600 write THEN FIN) is
//   correct for "reply then close" (PRD §5.3). sock.destroy() can DROP the
//   queued write. Wrap end() in try/catch (throws if already closing).

// GOTCHA: getToolPath/ensureTool are NOT public exports of pi. Do NOT deep-import
//   them (fragile). getFdAvailable() is a SELF-CONTAINED mirror (research §4).

// GOTCHA: the existing connection.test.ts "handler THROWS → -32603" test throws
//   a PLAIN Error. Under the new `instanceof BridgeRpcError` branch it falls
//   through to -32603 => that test stays GREEN. Do not change its expectation.

// GOTCHA: existing -32600/-32700 cases in handleLine are sent DIRECTLY (not via
//   throw) and must NOT close. Only BridgeRpcError.fatal closes. => fatal is
//   opt-in (default false); only hello uses fatal:true.

// GOTCHA: never log/echo the token (PRD §12). The error message is the literal
//   "bad token" — NOT the received or expected value.

// CONVENTION: node:test + jiti (NOT vitest). TAB indentation. Test seams named
//   __xForTest. Re-register on every session_start is safe (Map.set idempotent).
```

---

## Implementation Blueprint

### Data models and structure

No new wire types — `HelloParams`, `HelloResult`, `JsonRpcError` already exist in
`protocol.ts`. The one NEW runtime construct is the error class:

```ts
// extension/connection.ts (NEW — runtime export)
export interface BridgeRpcErrorOptions { fatal?: boolean; }

/**
 * Typed JSON-RPC error a handler THROWS to request a SPECIFIC error code (and,
 * optionally, to close the connection after replying). handleLine maps it →
 * {jsonrpc,id,error:{code,message}} and, when fatal, graceful sock.end().
 * Any OTHER thrown value falls through to the last-resort -32603 (S8 safety net).
 *
 * Codes are the JSON-RPC 2.0 reserved range: -32700 parse, -32600 invalid
 * request / bad token (PRD §5.3), -32601 method not found, -32602 invalid
 * params, -32603 internal error.
 *
 * STATUS (P1.M2.T5.S9): foundation S15 ("wrap handlers' domain errors into
 * proper codes") builds on. S9's hello is the first caller
 * (bad token → BridgeRpcError(-32600,"bad token",{fatal:true})).
 */
export class BridgeRpcError extends Error {
	readonly code: number;
	readonly fatal: boolean;
	constructor(code: number, message: string, options?: BridgeRpcErrorOptions) {
		super(message);
		this.name = "BridgeRpcError";
		this.code = code;
		this.fatal = options?.fatal ?? false;
	}
}
```

Bridge runtime state added to `pi-editor-bridge.ts` (all exposed via getters /
test seams, mirroring the existing `getToken`/`getProvider` idiom):

```ts
export const BRIDGE_VERSION = "0.1.0";          // PRD §6.4 hardcode; reused by S16
let cwd: string | undefined;                     // = ctx.cwd on session_start
export function getCwd(): string | undefined { return cwd; }
export function __setCwdForTest(v: string | undefined): void { cwd = v; }

let fdAvailableCache: boolean | undefined;       // cached once per process
export function getFdAvailable(): boolean { … resolveFdAvailable() … }
export function __setFdAvailableForTest(v: boolean | undefined): void { fdAvailableCache = v; }
```

### Implementation Tasks (ordered by dependencies)

```yaml
Task 1: MODIFY extension/connection.ts — add BridgeRpcError + refine handleLine
  - ADD: `export interface BridgeRpcErrorOptions { fatal?: boolean }` and
    `export class BridgeRpcError extends Error` (code below) — place near the
    JsonRpcError import / response-writer helpers (runtime exports belong here;
    protocol.ts is types-only).
  - REFININE: the REQUEST-branch catch in `handleLine` (the only behavioral
    change to connection.ts). Replace the single `sendError(-32603)` with an
    `if (handlerError instanceof BridgeRpcError) { sendError(code,msg); if(fatal) try{sock.end()}catch{} } else { sendError(-32603) }`.
  - DO NOT touch: the parse-catch (-32700), the envelope-narrow (-32600), the
    notification branch, onConnection, or the MethodHandler signature.
  - VERIFY: the existing `registerBridgeHandler("boom",()=>{throw new Error})`
    test still maps to -32603 (plain Error ⇒ else branch).

Task 2: MODIFY extension/pi-editor-bridge.ts — bridge state for the hello result
  - IMPORTS: extend the existing node:fs/node:os/node:path imports
    (+ existsSync, statSync; + homedir; + delimiter). Add
    `import { onConnection, registerBridgeHandler, BridgeRpcError } from "./connection.ts";`
    and `import type { ConnectionState, MethodHandler } from "./connection.ts";`
    and `import type { HelloParams, HelloResult } from "./protocol.ts";`.
  - ADD: `export const BRIDGE_VERSION = "0.1.0";`
  - ADD: `let cwd`, `getCwd()`, `__setCwdForTest()` (mirror getToken idiom).
  - ADD: `getFdAvailable()` (+ cached `fdAvailableCache`) + `__setFdAvailableForTest()`
    + private `resolveFdAvailable()` + `isExecutableFile()` (self-contained fd
    resolver — code below).
  - PLACEMENT: group these with the existing getToken/getSocketPath/getServer getters.

Task 3: MODIFY extension/pi-editor-bridge.ts — the hello handler factory + wiring
  - ADD: `export function makeHelloHandler(deps:{getToken,getCwd,getFdAvailable,version}): MethodHandler`
    (PURE factory — deps injected for testability). Body narrows params to
    HelloParams, compares token with `===`, throws BridgeRpcError(-32600,"bad
    token",{fatal:true}) on any mismatch/missing/no-expected, else sets
    state.handshakeComplete=true and returns HelloResult (code below).
  - WIRE: in the default-export `session_start` handler, BELOW the TUI guard and
    AFTER `startBridge(ctx)` (so the token exists), add:
      `cwd = ctx.cwd;`
      `registerBridgeHandler("hello", makeHelloHandler({ getToken, getCwd, getFdAvailable, version: BRIDGE_VERSION }));`
  - DO NOT: add the S10 handshake GATE (S9 only SETS the flag); write
    process.env.PI_NVIM_BRIDGE (S16); register other methods (S11–S14).

Task 4: MODIFY extension/tests/connection.test.ts — BridgeRpcError mapping
  - EXTEND fakeSocket(): add `end()` (record into a `state.ended` bool + emit
    "close"); return `{ sock, writes, state }` (3rd key is additive — existing
    `const { sock, writes } = fakeSocket()` destructures stay valid).
  - ADD 3 tests (node:test): (a) handler throws `new BridgeRpcError(-32601,"nope")`
    → -32601 response, `state.ended===false`; (b) handler throws
    `new BridgeRpcError(-32600,"bad token",{fatal:true})` → -32600 response AND
    `state.ended===true`; (c) REGRESSION: handler throws plain `new Error("x")`
    → -32603, `state.ended===false`.
  - FOLLOW: existing try/finally + `__resetHandlersForTest()` pattern.

Task 5: CREATE extension/tests/hello-handler.test.ts — handler logic + integration
  - IMPORT: `import { test } from "node:test"; import assert from "node:assert/strict";`
    `import { makeHelloHandler, BRIDGE_VERSION } from "../pi-editor-bridge.ts";`
    `import { BridgeRpcError, handleLine, registerBridgeHandler, __resetHandlersForTest } from "../connection.ts";`
    + `createServer, connect, once` from node:net/events, `tmpdir/randomUUID/join` for the real test.
  - UNIT (makeHelloHandler directly — no module state): good token ⇒ returns
    HelloResult + flips a fresh `ConnectionState.handshakeComplete` to true;
    `client`/`clientVersion` present ⇒ ignored; bad token / missing / wrong-type
    token ⇒ throws BridgeRpcError(code===-32600, fatal===true); getToken()⇒
    undefined ⇒ same throw; getCwd()⇒undefined ⇒ result.cwd==="".
  - DISPATCH round-trip (handleLine + fakeSocket, hello registered): valid hello
    JSONL line ⇒ `{jsonrpc,id,result:HelloResult}` + handshakeComplete; bad-token
    line ⇒ `{jsonrpc,id,error:{-32600}}` + socket ended.
  - REAL integration (ONE test, mirrors connection.test.ts test 13): createServer
    with onConnection; register hello with a FIXED token via makeHelloHandler
    (deps stubbed: getToken⇒const, getCwd⇒"/tmp", getFdAvailable⇒true,
    version⇒BRIDGE_VERSION); client A sends valid hello ⇒ HelloResult; client B
    (separate connection) sends bad hello ⇒ -32600 then the server closes (await
    client 'close'/'end'). __resetHandlersForTest() in finally.

Task 6: VALIDATE (see Validation Loop) — tsc clean; new + existing suites green.
```

### Implementation Patterns & Key Details

```ts
// === extension/connection.ts: Task 1 — the handleLine REQUEST-catch refinement ===
// (replace the existing single-sendError catch in the REQUEST branch ONLY)
	try {
		const result = await handler(params, state);
		sendResponse(sock, reqId, result);
	} catch (handlerError) {
		if (handlerError instanceof BridgeRpcError) {
			// S9: handler requested a SPECIFIC code (and maybe a close).
			sendError(sock, reqId, handlerError.code, handlerError.message);
			if (handlerError.fatal) {
				// "reply then close" (PRD §5.3): end() flushes the queued error write
				// then half-closes (FIN); the existing 'close' handler detaches the reader.
				try {
					sock.end();
				} catch {
					/* already closing/closed — best-effort */
				}
			}
		} else {
			// S8 last-resort safety net: unknown throw → -32603 (never hang the client).
			sendError(
				sock,
				reqId,
				-32603,
				`internal error: ${handlerError instanceof Error ? handlerError.message : String(handlerError)}`,
			);
		}
	}

// === extension/pi-editor-bridge.ts: Task 2 — self-contained fd resolver ===
// (mirrors pi getToolPath("fd") WITHOUT importing pi internals — research §4)
let fdAvailableCache: boolean | undefined;
export function getFdAvailable(): boolean {
	if (fdAvailableCache === undefined) fdAvailableCache = resolveFdAvailable();
	return fdAvailableCache;
}
export function __setFdAvailableForTest(v: boolean | undefined): void {
	fdAvailableCache = v;
}
function resolveFdAvailable(): boolean {
	const isWin = process.platform === "win32";
	const names = process.platform === "linux" ? ["fd", "fdfind"] : ["fd"];
	const ext = isWin ? ".exe" : "";
	// 1) pi agent bin dir — config.js: getBinDir() = join(getAgentDir(), "bin");
	//    tools-manager downloads fd there. getAgentDir honors $PI_CODING_AGENT_DIR.
	const agentDir =
		process.env.PI_CODING_AGENT_DIR ??
		(isWin
			? join(process.env.APPDATA ?? join(homedir(), "AppData", "Roaming"), "pi")
			: join(process.env.XDG_DATA_HOME ?? join(homedir(), ".local", "share"), "pi"));
	for (const n of names) {
		if (isExecutableFile(join(agentDir, "bin", n + ext))) return true;
	}
	// 2) PATH scan.
	for (const dir of (process.env.PATH ?? "").split(delimiter)) {
		if (!dir) continue;
		for (const n of names) {
			if (isExecutableFile(join(dir, n + ext))) return true;
		}
	}
	return false;
}
function isExecutableFile(p: string): boolean {
	try {
		if (!existsSync(p)) return false;
		if (process.platform === "win32") return true;
		return (statSync(p).mode & 0o111) !== 0; // any execute bit
	} catch {
		return false;
	}
}

// === extension/pi-editor-bridge.ts: Task 3 — the hello handler factory ===
export function makeHelloHandler(deps: {
	getToken: () => string | undefined;
	getCwd: () => string | undefined;
	getFdAvailable: () => boolean;
	version: string;
}): MethodHandler {
	return (params: unknown, state: ConnectionState): HelloResult => {
		const expected = deps.getToken();
		const p = (params ?? null) as Partial<HelloParams> | null;
		const received =
			p && typeof p === "object" && typeof p.token === "string" ? p.token : undefined;
		// No expected token (bridge stopped), empty, or any mismatch ⇒ bad token.
		// `===` is fine: local process secret, timing attacks out of scope (research §9).
		// NEVER include token values in the message (PRD §12).
		if (typeof expected !== "string" || expected.length === 0 || received !== expected) {
			throw new BridgeRpcError(-32600, "bad token", { fatal: true });
		}
		state.handshakeComplete = true; // S10 gates every other method on this.
		return {
			ok: true,
			serverVersion: deps.version,
			cwd: deps.getCwd() ?? "",
			fdAvailable: deps.getFdAvailable(),
		};
	};
}

// === extension/pi-editor-bridge.ts: Task 3 — session_start wiring ===
// (inside `pi.on("session_start", …)`, BELOW the `if (ctx.mode !== "tui") return;`
//  guard and AFTER `startBridge(ctx);`)
		cwd = ctx.cwd; // HelloResult.cwd (S9) + the S16 descriptor
		registerBridgeHandler(
			"hello",
			makeHelloHandler({ getToken, getCwd, getFdAvailable, version: BRIDGE_VERSION }),
		);

// === extension/tests/connection.test.ts: Task 4 — extend fakeSocket (additive) ===
function fakeSocket() {
	const writes: string[] = [];
	const state = { ended: false };
	const sock = Object.assign(new EventEmitter(), {
		write(s: string) {
			writes.push(s);
			return true;
		},
		end() {
			state.ended = true;
			(this as unknown as EventEmitter).emit("close");
		},
		destroy() {
			(this as unknown as EventEmitter).emit("close");
		},
	}) as unknown as Socket;
	return { sock, writes, state };
}
// existing `const { sock, writes } = fakeSocket();` calls keep working (ignore state).
```

### Integration Points

```yaml
SESSION LIFECYCLE (pi-editor-bridge.ts default export):
  - session_start (tui only): captureProvider → startBridge → store cwd → register "hello".
    Re-entry on reload/new/resume/fork is safe (startBridge idempotent; Map.set idempotent).
  - session_shutdown: stopBridge() (unchanged). The hello handler stays registered
    but getToken()⇒undefined ⇒ any hello ⇒ bad token (correct for a stopped bridge).
    (No handler reset needed; no env-var clear — that's S16.)

CONNECTION DISPATCH (connection.ts handleLine):
  - hello arrives as a REQUEST (client always sends id "h1", PRD §5.3) ⇒ dispatches
    to the registered handler ⇒ success result OR thrown BridgeRpcError(fatal) ⇒
    -32600 + sock.end(). No change to notification/parse/narrow paths.

PROTOCOL (protocol.ts): CONSUMED, not modified. HelloParams/HelloResult/JsonRpcError
  already declared (S4). BridgeRpcError is a runtime escape hatch in connection.ts.

DOWNSTREAM REUSE:
  - BRIDGE_VERSION / getCwd() / getFdAvailable() are reused by S16 (PI_NVIM_BRIDGE descriptor).
  - BridgeRpcError is reused by S15 (wrap domain-handler errors into proper codes).
  - ConnectionState.handshakeComplete (set true here) is read by S10 (the gate).
```

---

## Validation Loop

### Level 1: Syntax & Type (after each source edit)

```bash
cd /home/dustin/projects/pi-nvim-bridge
tsc --noEmit -p extension/tsconfig.json
# Expected: exit 0, NO output. (TS 5.9.3, Node v26.4.0 — verified.)
```

### Level 2: Unit / component tests (node:test + jiti — NOT vitest)

```bash
JITI_REG=/home/dustin/.local/lib/node_modules/@earendil-works/pi-coding-agent/node_modules/jiti/lib/jiti-register.mjs

# The NEW suite (handler logic + dispatch round-trip + real socket integration)
node --import "$JITI_REG" extension/tests/hello-handler.test.ts
# Expected: exit 0, `ℹ fail 0`. (jiti prints a benign DeprecationWarning on Node 26
# stderr — judge by exit code + the `ℹ pass`/`ℹ fail` summary, ignore the warning.)

# The REFINED dispatch (BridgeRpcError mapping) + REGRESSION that all 13 S8 tests pass
node --import "$JITI_REG" extension/tests/connection.test.ts
# Expected: exit 0, `ℹ pass 16` (13 existing + 3 new), `ℹ fail 0`.

# Full extension suite (no regressions across S2–S9)
for t in extension/tests/*.test.ts; do
  echo "--- $t"
  node --import "$JITI_REG" "$t" 2>/dev/null | grep -E "^ℹ (tests|pass|fail)"
done
# Expected: every file `ℹ fail 0`.
```

### Level 3: Integration (a real socket pair, end-to-end handshake)

```bash
# Driven by the real-socket test inside hello-handler.test.ts (Task 5). To eyeball
# the wire by hand (optional sanity check):
JITI_REG=/home/dustin/.local/lib/node_modules/@earendil-works/pi-coding-agent/node_modules/jiti/lib/jiti-register.mjs
node --import "$JITI_REG" -e '
  import("node:net").then(async ({ createServer }) => {
    import("./extension/connection.ts").then(async ({ onConnection, registerBridgeHandler }) => {
      import("./extension/pi-editor-bridge.ts").then(({ makeHelloHandler, BRIDGE_VERSION }) => {
        const { join } = require("node:path"), { tmpdir } = require("node:os"),
              { randomUUID } = require("node:crypto");
        const sock = join(tmpdir(), `hb-${randomUUID()}.sock`);
        const TOKEN = "deadbeef".repeat(4);
        registerBridgeHandler("hello", makeHelloHandler({
          getToken:()=>TOKEN, getCwd:()=>"/tmp", getFdAvailable:()=>true, version:BRIDGE_VERSION }));
        const s = createServer(c=>onConnection(c)); s.listen(sock);
        s.on("listening", async ()=>{
          const cli = require("node:net").connect(sock);
          cli.on("connect",()=>{
            cli.write(JSON.stringify({jsonrpc:"2.0",id:"h1",method:"hello",params:{token:TOKEN}})+"\n");
          });
          cli.on("data",d=>{ console.log("client got:", d.toString().trim()); s.close(); process.exit(0); });
        });
      });
    });
  });
'
# Expected: client got: {"jsonrpc":"2.0","id":"h1","result":{"ok":true,"serverVersion":"0.1.0","cwd":"/tmp","fdAvailable":true}}
```

### Level 4: Domain-specific validation (auth-boundary invariants)

```bash
# (a) Bad token ⇒ exactly ONE -32600 line, then EOF (asserted in hello-handler.test.ts
#     real-socket test: bad-token client receives the error then a 'close'/'end').
# (b) Token never appears in any response or stderr — grep the test run output:
JITI_REG=/home/dustin/.local/lib/node_modules/@earendil-works/pi-coding-agent/node_modules/jiti/lib/jiti-register.mjs
SECRET="deadbeefdeadbeefdeadbeefdeadbeef"
node --import "$JITI_REG" extension/tests/hello-handler.test.ts 2>&1 | grep -c "$SECRET" || true
# Expected: 0 (the token is a test-local constant; the PRODUCTION secret is randomUUID-
# derived and must never be logged — PRD §12. The handler message is the literal "bad token".)
```

---

## Final Validation Checklist

### Technical Validation
- [ ] `tsc --noEmit -p extension/tsconfig.json` ⇒ exit 0, no output.
- [ ] `node --import "$JITI_REG" extension/tests/hello-handler.test.ts` ⇒ exit 0, `ℹ fail 0`.
- [ ] `node --import "$JITI_REG" extension/tests/connection.test.ts` ⇒ `ℹ fail 0` (13 existing + 3 new).
- [ ] Every `extension/tests/*.test.ts` ⇒ `ℹ fail 0` (no S2–S8 regressions).

### Feature Validation
- [ ] Correct-token `hello` ⇒ one success envelope + `handshakeComplete===true`.
- [ ] Wrong/missing/untyped-token `hello` ⇒ one `-32600 "bad token"` envelope, then socket closes.
- [ ] `getToken()===undefined` (stopped bridge) ⇒ `hello` ⇒ bad token (no crash).
- [ ] `client`/`clientVersion` params ignored; `getCwd()===undefined` ⇒ `result.cwd===""`.
- [ ] `fdAvailable` true when `fd`/`fdfind` resolvable (verified: `fd` at `/home/dustin/.cargo/bin/fd`).
- [ ] `BridgeRpcError(code,msg)` non-fatal ⇒ that code, socket open; plain `Error` ⇒ `-32603` (regression-safe).
- [ ] Token value never present in any response or stderr.

### Code Quality
- [ ] Handler registered FROM `pi-editor-bridge.ts`; `connection.ts` still does NOT import it (no cycle).
- [ ] Mutable state via getters (jiti live-binding gotcha respected); test seams follow `__xForTest` convention.
- [ ] `BridgeRpcError` lives in `connection.ts` (runtime); `protocol.ts` stays types-only.
- [ ] `MethodHandler` signature unchanged (existing tests/registrations intact).
- [ ] `hello` registered AFTER `startBridge` in the TUI-guarded `session_start`; idempotent on re-entry.
- [ ] TAB indentation, `node:test`+`assert/strict`+jiti (NOT vitest), reuse `fakeSocket`/`__resetHandlersForTest`.

### Scope Discipline (did NOT bleed into other tasks)
- [ ] No S10 handshake GATE added (S9 only sets the flag).
- [ ] No `process.env.PI_NVIM_BRIDGE` write (S16) / no `commandsChanged` (S17) / no getSuggestions… (S11–S14).

---

## Anti-Patterns to Avoid

- ❌ Don't change the `MethodHandler` signature to pass `sock`/`id` — it breaks the 13 existing test registrations and is unnecessary (`BridgeRpcError`+`fatal` is the clean way).
- ❌ Don't deep-import pi's `getToolPath`/`ensureTool` — they aren't public exports; reimplement the lookup self-containedly.
- ❌ Don't `sock.destroy()` for the fatal close — it can drop the queued `-32600` write; use graceful `sock.end()`.
- ❌ Don't make every `-32600`/`-32700` close the socket — only `BridgeRpcError.fatal` closes (hello bad-token). The parse/narrow `-32600`s stay non-fatal.
- ❌ Don't add the S10 method gate, S15 domain-error wrapping, or S16 env advertisement in this task.
- ❌ Don't log/echo the token; the error message is the literal `"bad token"`.
- ❌ Don't redeclare `HelloParams`/`HelloResult`/`JsonRpcError` — consume them from `protocol.ts`.
- ❌ Don't use vitest or a non-`node:test` runner.

---

## Confidence Score: 9/10

**Why 9, not 10**: the design (typed `BridgeRpcError` + minimal `handleLine`
refinement + injected-deps factory) is forced by the existing architecture
(proven: zero-change is impossible for "error+close"), backward-compatible with
all 13 existing tests, and every referenced file/type/command is verified
present and executable. The one residual risk is the exact assertion shape of
the real-socket bad-token-disconnect test (client observing `close` vs `end`
event ordering across Node/libuv) — mitigated by asserting on the error envelope
first and then awaiting either `'close'` or `'end'` with a short timeout.
