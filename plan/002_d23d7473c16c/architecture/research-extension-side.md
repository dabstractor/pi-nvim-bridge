# Extension-Side Research — Shell Completion Delta PRD

Scout findings for the pi-nvim-bridge **TypeScript extension** side. All line
numbers verified against the working tree at `/home/dustin/projects/pi-nvim-bridge`.

## TL;DR — critical facts for the PRD author

1. **`BridgeDescriptor` lives in `extension/protocol.ts:83-91`** — 7 fields, ALL
   required (no optionals today). Adding `shell?` / `shellSource?` / `shellPath?`
   is a backward-compatible additive change at the type level.
2. **The descriptor is serialized in exactly ONE place**: `startBridge()` at
   `extension/pi-nvim-bridge.ts:570-578`, guarded by `satisfies BridgeDescriptor`.
   This is the single edit site for populating the new fields.
3. **`hello`/`ping` result builders are NOT in `connection.ts`** — they are
   handler factories in `pi-nvim-bridge.ts` (`makeHelloHandler` L623,
   `makePingHandler` L670). `connection.ts` only does generic `sendResponse`.
4. **`HelloResult`/`PingResult` do NOT currently carry shell fields** — if the
   client needs shell info at handshake, these result types must ALSO be extended.
5. **`import type` is used for ALL `@earendil-works/*` imports** (L135, L137-142) —
   critical for omp/Bun compat. Any new pi-tui imports must follow this pattern.
6. **No `resolveShell()` or any shell-resolution logic exists** — net-new code.
   There IS an existing resolver to mirror: `resolveFdAvailable()` (L390+) +
   `getFdAvailable()` cached getter (L358) + `__setFdAvailableForTest` seam (L386).
7. **`import type { ... BridgeDescriptor } from "./protocol.ts"`** is already in
   place in `pi-nvim-bridge.ts` (L158-166) — the type is already imported.

---

## 1. `BridgeDescriptor` type — `extension/protocol.ts`

### Current definition (lines 83-91)

```ts
// extension/protocol.ts
export interface BridgeDescriptor {
	transport: "unix";
	path: string;
	token: string;
	pid: number;
	cwd: string;
	fdAvailable: boolean;
	serverVersion: string;
}
```

- **All 7 fields are REQUIRED.** No optional fields exist today.
- Header comment block §B (lines 73-82) documents field value sources and notes
  "all fields required, JSON-serializable" and "`transport:"unix"` is a v1 literal."
- The PRD's 3 new optional fields (`shell?`, `shellSource?`, `shellPath?`) fit
  cleanly as additive optionals. The header comment's "all fields required" claim
  will need a small amendment if strict doc-accuracy matters.

### Related result types that may need shell fields

```ts
// extension/protocol.ts:107-112
export interface HelloResult {
	ok: true;
	serverVersion: string;
	cwd: string;
	fdAvailable: boolean;
}

// extension/protocol.ts:117-123
export interface PingResult {
	ok: true;
	pid: number;
	cwd: string;
	fdAvailable: boolean;
	serverVersion: string;
}
```

> **Decision point for the PRD:** `BridgeDescriptor` is the env-var discovery
> blob (read by the Neovim VimEnter gate at launch). `HelloResult`/`PingResult`
> are live-RPC identity responses. If the client needs shell info in a live RPC
> (e.g. for `:checkhealth` or post-launch re-query), these types must carry it
> too. Today they do NOT mirror all descriptor fields (e.g. `path`/`token` are
> descriptor-only by design; `pid` is ping-only).

---

## 2. `extension/pi-nvim-bridge.ts` — key sites

### 2a. Imports — `import type` used everywhere (lines 135-166)

```ts
// L135
import type { AutocompleteProvider, AutocompleteItem } from "@earendil-works/pi-tui";
// L137-142
import type {
	ExtensionAPI,
	ExtensionContext,
	SessionStartEvent,
	SessionShutdownEvent,
} from "@earendil-works/pi-coding-agent";
...
// L158-166 — protocol imports (BridgeDescriptor already imported)
import type {
	HelloParams,
	HelloResult,
	PingParams,
	PingResult,
	...
	BridgeDescriptor,
} from "./protocol.ts";
```

**Confirmed:** every `@earendil-works/*` import is `import type` (erased at
runtime → zero jiti/Bun runtime cost). Any new `@earendil-works/pi-tui` type
imports for shell types MUST use `import type`. Runtime values (none expected)
would need a separate value import.

### 2b. `startBridge(ctx)` — the ONE descriptor write site (lines 526-593)

Function declared at **L526**. The descriptor is serialized at **L570-578**:

```ts
// extension/pi-nvim-bridge.ts:570-578
process.env[BRIDGE_ENV] = JSON.stringify({
	transport: "unix",
	path: socketPath, // module-level let — guaranteed set above
	token, // module-level let — guaranteed set above
	pid: process.pid,
	cwd: ctx.cwd, // read DIRECTLY (module `cwd` is set in session_start AFTER startBridge)
	fdAvailable: getFdAvailable(), // REAL resolver — consistent with hello/ping (GOTCHA #2)
	serverVersion: BRIDGE_VERSION, // "0.1.0" — NOT "0.0.1" (GOTCHA #1)
} satisfies BridgeDescriptor); // compile-time guard against the `version` typo
```

**Key constraints for adding shell fields here:**
- `ctx.cwd` is read DIRECTLY (not the module `cwd` getter) — a documented
  GOTCHA (#3): the module `cwd` is set in `session_start` AFTER `startBridge`
  returns. Same caveat applies if `ctx` carries a shell hint.
- The object literal is guarded by `satisfies BridgeDescriptor`, so new optional
  fields will typecheck ONLY if added to the `BridgeDescriptor` interface first.
- This runs on EVERY `session_start` (reload/new/resume/fork) — `startBridge`
  idempotently calls `stopBridge()` first (L527).

### 2c. `isInteractiveSession(ctx)` — exact implementation (lines 1119-1138)

```ts
// extension/pi-nvim-bridge.ts:1119-1138 (JSDoc above) — implementation 1134-1138
function isInteractiveSession(ctx: ExtensionContext): boolean {
	return (
		ctx.mode === "tui" ||
		(ctx as ExtensionContext & { hasUI?: boolean }).hasUI === true
	);
}
```

Handles the pi (`ctx.mode === "tui"`) vs oh-my-pi/`omp` (`ctx.hasUI`) host fork.
**This is the gate the shell-completion feature should inherit** — any new
shell resolution should run only inside the interactive branch (or at minimum
not in print/rpc/json modes), since the `$EDITOR` is launched only in TUI mode.

### 2d. `session_start` handler + guard (lines 1141-1252)

- Handler registered at **L1142**: `pi.on("session_start", (event, ctx) => { ... })`.
- **Guard at L1167**: `if (!isInteractiveSession(ctx)) return;`
- Order inside the guard (relevant sequence):
  - L1172 `captureProvider(ctx)`
  - L1173 `startBridge(ctx)` ← descriptor written here
  - L1174 `cwd = ctx.cwd`
  - L1176-1231 register all 7 RPC handlers (`hello`, `getSuggestions`,
    `applyCompletion`, `shouldTriggerFileCompletion`, `ping`, `bye`,
    `getCommands`)
  - L1248 `if (getServer()) __deps.broadcastNotification("commandsChanged")`

> Any shell-resolution that depends on `ctx` should be invoked either inside
> `startBridge` (where the descriptor is built) or just before it, both of which
> are already behind the `isInteractiveSession` gate.

### 2e. Existing resolver pattern to mirror — `resolveFdAvailable` / `getFdAvailable`

The shell feature should mirror the **fd-availability** precedent exactly:

```ts
// extension/pi-nvim-bridge.ts — module-level cache + getter + test seam
let fdAvailableCache: boolean | undefined;          // L355ish
export function getFdAvailable(): boolean {          // L358
	if (fdAvailableCache === undefined) fdAvailableCache = resolveFdAvailable();
	return fdAvailableCache;
}
export function __setFdAvailableForTest(v: boolean | undefined): void {  // L386
	fdAvailableCache = v;
}
function resolveFdAvailable(): boolean { ... }       // L390+ (agent bin dir → PATH scan)
```

`resolveFdAvailable()` (L390+) checks: (1) pi agent bin dir via
`PI_CODING_AGENT_DIR` / `XDG_DATA_HOME` / `~/.local/share`, then (2) a
`process.env.PATH` scan for an executable. A `resolveShell()` would likely mirror
this two-tier lookup (pi bin dir first, then PATH, then `$SHELL`/default).

### 2f. `hello` / `ping` handler factories (the ACTUAL result builders)

> **Note:** The PRD task said connection.ts builds these — it does NOT.
> The result objects are built inline in these factories in pi-nvim-bridge.ts.
> `connection.ts` is transport-only (see §3 below).

**`makeHelloHandler` (L623-649)** — deps-injected factory:

```ts
// extension/pi-nvim-bridge.ts:623-649
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
		if (typeof expected !== "string" || expected.length === 0 || received !== expected) {
			throw new BridgeRpcError(-32600, "bad token", { fatal: true });
		}
		state.handshakeComplete = true;
		return {
			ok: true,
			serverVersion: deps.version,
			cwd: deps.getCwd() ?? "",
			fdAvailable: deps.getFdAvailable(),
		};
	};
}
```

**`makePingHandler` (L670-686)** — `HelloResult` + `pid`, no token validation:

```ts
// extension/pi-nvim-bridge.ts:670-686
export function makePingHandler(deps: {
	getPid: () => number;
	getCwd: () => string | undefined;
	getFdAvailable: () => boolean;
	version: string;
}): MethodHandler {
	return (_params: unknown, _state: ConnectionState): PingResult => ({
		ok: true,
		pid: deps.getPid(),
		cwd: deps.getCwd() ?? "",
		fdAvailable: deps.getFdAvailable(),
		serverVersion: deps.version,
	});
}
```

> If shell fields are added to `HelloResult`/`PingResult`, BOTH factories need a
> new injected dep (e.g. `getShell: () => ShellInfo | undefined`), mirroring
> `getFdAvailable`. The registration sites (L1180 for hello, L1225 for ping)
> pass deps explicitly.

---

## 3. `extension/connection.ts` — transport-only (471 lines)

**No descriptor/result building happens here.** connection.ts is the JSON-RPC
transport/dispatch layer. Relevant exports:

- `MethodHandler` type (L111): `(params: unknown, state: ConnectionState) => Promise<unknown> | unknown`
- `registerBridgeHandler(method, fn)` (L152) — the `Map<string, MethodHandler>`
  registry handlers are added to.
- `sendResponse(sock, id, result)` (L159) — generic serializer; takes whatever
  the handler returns. **No field knowledge.**
- `handleLine(sock, state, line)` (L288) — the dispatcher: parses JSONL, looks
  up handler, `await handler(params, state)`, then `sendResponse` or `sendError`.
- `ConnectionState` interface (L93): `{ handshakeComplete: boolean; closeAfterResponse?: boolean }`.
- `onConnection(sock)` (L439) — `createServer` callback; per-socket state + reader wiring.

The handshake gate (L334-346) rejects every method except `hello` until
`state.handshakeComplete`. This means `ping` (and any new shell-query method)
can ONLY run post-handshake.

> **Implication:** if the shell delta adds a new RPC method (rather than just
> descriptor fields), it must be registered via `registerBridgeHandler` in
> `session_start` and will inherit the handshake gate automatically.

---

## 4. `package.json` — manifest

The pi extension manifest key (lines 28-32):

```json
"pi": {
	"extensions": ["./extension/pi-nvim-bridge.ts"]
}
```

Single entry point. The extension is loaded via jiti (TS works without
compilation). `peerDependencies` declare `@earendil-works/pi-coding-agent` and
`@earendil-works/pi-tui` (both `"*"`). tsconfig.json (extension/tsconfig.json)
maps these to installed `.d.ts` paths for typecheck-only (`noEmit: true`).

---

## 5. Tests — `extension/tests/` (17 files)

### Framework & runner

- **`node:test`** + **`node:assert/strict`** + **jiti** register (NOT vitest, NOT plenary).
- Run via: `node --import jiti-register extension/tests/*.test.ts` (see package.json `test` script comment).
- Existing test files (all `*.test.ts`):
  `apply-completion-handler`, `bridge-env`, `bridge-lifecycle-wiring`,
  `bridge-lifecycle`, `commands-changed-notification`, `connection`,
  `error-wrapping`, `get-suggestions-handler`, `handshake-gate`,
  `hello-handler`, `jsonl-reader`, `mode-guard`, `nvim-appname`,
  `ping-bye-getcommands-handler`, `protocol`, `provider-capture`,
  `should-trigger-file-completion-handler`.

### Patterns (from `hello-handler.test.ts`)

1. **Deps-injection factories** — handlers are tested via `makeHelloHandler({...stubs})`
   with pure stub deps, NO module state. This is THE pattern a new shell-related
   factory should follow.
2. **Three test layers:**
   - UNIT: call the factory directly with a hand-built `ConnectionState` (`{ handshakeComplete: false }`).
   - DISPATCH: `handleLine` + a `fakeSocket()` (EventEmitter + Object.assign
     with `write`/`end`/`destroy` capture).
   - REAL integration: one real Unix-socket pair (`createServer` + `connect`),
     `attachJsonlLineReader` to parse responses, with `Promise.race` + timeout
     to avoid hangs.
3. **Cleanup:** `__resetHandlersForTest()` in `finally` blocks (handler registry
   is module-global — must reset between tests).
4. **Fake socket helper:**
   ```ts
   function fakeSocket() {
     const writes: string[] = [];
     const state = { ended: false };
     const sock = Object.assign(new EventEmitter(), {
       write(s: string) { writes.push(s); return true; },
       end() { state.ended = true; this.emit("close"); },
       destroy() { this.emit("close"); },
     }) as unknown as Socket;
     return { sock, writes, state };
   }
   ```
5. **Imports:** direct relative imports (`../connection.ts`, `../pi-nvim-bridge.ts`,
   `../jsonl-reader.ts`). Types imported from `../connection.ts` (`ConnectionState`).
6. **`bridge-env.test.ts`** is the most relevant existing test for a descriptor
   change — it asserts the `PI_NVIM_BRIDGE` env blob's exact shape. A shell-field
   addition will need its expectations updated there.

---

## Files Retrieved (exact paths + line ranges)

1. `extension/protocol.ts` (L73-123) — `BridgeDescriptor` (L83-91), `HelloResult`
   (L107-112), `PingResult` (L117-123). The 3 type edit sites.
2. `extension/pi-nvim-bridge.ts` (L135-166) — all `import type` usage including
   `BridgeDescriptor` already imported.
3. `extension/pi-nvim-bridge.ts` (L526-593) — `startBridge()` incl. the descriptor
   write at L570-578 (`satisfies BridgeDescriptor`).
4. `extension/pi-nvim-bridge.ts` (L319-440) — `getFdAvailable`/`resolveFdAvailable`
   resolver+cache+test-seam pattern to mirror for `resolveShell`.
5. `extension/pi-nvim-bridge.ts` (L605-686) — `makeHelloHandler` + `makePingHandler`
   (the actual result builders).
6. `extension/pi-nvim-bridge.ts` (L1119-1252) — `isInteractiveSession` (L1134-1138)
   + `session_start` handler (L1142) + guard (L1167) + handler registrations.
7. `extension/connection.ts` (L37-471) — transport layer; `sendResponse` (L159),
   `handleLine` (L288), handshake gate (L334-346). No descriptor/result building.
8. `extension/tsconfig.json` — `noEmit`, `moduleResolution: Bundler`,
   `@earendil-works/*` path mappings to `.d.ts`.
9. `package.json` (L28-32) — `"pi": { "extensions": [...] }` manifest.
10. `extension/tests/hello-handler.test.ts` (full) — canonical test pattern
    (node:test, deps-injection, fakeSocket, 3 layers).

## Start Here

**`extension/protocol.ts:83-91`** — extend `BridgeDescriptor` with the 3 optional
fields first. This unblocks the `satisfies BridgeDescriptor` guard in `startBridge`
(`pi-nvim-bridge.ts:570-578`), which is the single population site. Then decide
whether `HelloResult`/`PingResult` (same file, L107/L117) also need shell fields
for live-RPC exposure.

## Open Questions / Risks

- **Where does the client consume shell info?** If only at launch (Neovim
  VimEnter gate reads `PI_NVIM_BRIDGE`), only `BridgeDescriptor` + `startBridge`
  need changes. If at `:checkhealth`/post-launch, `HelloResult`/`PingResult` +
  the two handler factories need deps added too.
- **Shell source resolution** is net-new — mirror `resolveFdAvailable`'s cache +
  getter + `__set*ForTest` seam. Must decide lookup order: pi bin dir → PATH →
  `$SHELL` → OS default.
- **The "all fields required" comment** at `protocol.ts:76` is now stale once
  optionals are added — minor doc fix.
- **omp host compat:** `ctx.mode`/`ctx.hasUI` divergence (L1119-1133 JSDoc) —
  any shell resolution reading `ctx` must tolerate both shapes, like
  `isInteractiveSession` does.