# Research Notes — P1.M2.T3.S5 (dir P1M2T1S1): startBridge()

Item title: **`startBridge()` — create Unix socket server, generate token, chmod 0o600.**
(This is plan task **P1.M2.T3.S5**; the orchestrator placed artifacts under
`plan/001_c56962b4fa17/P1M2T1S1/`. The directory name differs from the task id but
the output paths in the assignment are authoritative.)

All claims below were **empirically verified** against the installed toolchain
(Node v26.4.0, pi 0.80.10, jiti via pi-coding-agent, tsc at `/home/dustin/.local/bin/tsc`)
and the current repo state (`extension/pi-editor-bridge.ts` post P1.M1.T1.S1–S3).

---

## 1. Empirical findings (the load-bearing ones)

### 1.1 `node:net` ESM namespace is FROZEN — direct mocking is impossible
`mock.method(net, "createServer", fn)` throws:
```
TypeError: Cannot redefine property: createServer
    at defineProperty (<anonymous>)
    at MockTracker.method (node:internal/test_runner/mock/mock:547:5)
```
The builtin module namespace object is non-configurable. **Implication:** the
item contract's MOCKING requirement ("mock `net.createServer`") CANNOT be met by
mocking the `node:net` namespace. The standard, clean resolution is a **deps
seam**: a mutable plain object that defaults to the real builtins and that tests
override. See `__deps` design in §3.

### 1.2 jiti does NOT implement ESM live-binding reassignment (cross-module)
A producer `export let server` mutated via `setServer("x")` is **not** observed
by a consumer that imported `server` — the consumer keeps seeing the initial
`undefined`. Verified under the pi-bundled jiti register:
```
node --import <pi>/node_modules/jiti/lib/jiti-register.mjs consumer.test.ts
  → AssertionError: expected undefined to equal 'srv1'
```
**Implication:** expose module state to tests via **getter functions** (exactly
like the existing `getProvider()` in `pi-editor-bridge.ts`), NOT `export let`.

### 1.3 `node:*` imports type-check under the current tsconfig (`"types": []`)
Probe file importing `createServer/Server/Socket` from `node:net`, `randomUUID`
from `node:crypto`, `chmodSync/rmSync` from `node:fs`, `tmpdir` from `node:os`,
`join` from `node:path` → `tsc --noEmit -p extension/tsconfig.json` exits 0.
Reason: `moduleResolution: "Bundler"` resolves the `declare module "node:net"`
declarations shipped by `@types/node`
(`/home/dustin/.local/lib/node_modules/@earendil-works/pi-coding-agent/node_modules/@types/node/net.d.ts`);
the `"types": []` option only restricts *ambient/global* @types inclusion, not
explicit module imports. `net.Server` is `class Server extends EventEmitter`
(net.d.ts:587). **Implication: NO tsconfig change is required for S5's node imports.**

### 1.4 Real chmod-after-listen works; socket file exists synchronously
`const srv = net.createServer(()=>{}); srv.listen(path); chmodSync(path, 0o600);`
then `statSync(path).mode & 0o777 === 0o600` — verified. The Unix-domain socket
file is created synchronously by `listen()` (libuv binds before returning), so
`chmodSync` immediately after `listen()` does not race/ENOENT. Matches PRD §6.4
skeleton (listen then bare chmod). S5 wraps chmod in try/catch for robustness
(0o600 is defense-in-depth; token is the real auth boundary — §12), so a chmod
hiccup cannot crash session_start.

### 1.5 Token format verified
`randomUUID().replace(/-/g, "").slice(0, 32)` → exactly 32 lowercase hex chars,
no dashes. Matches PRD §12 ("32-byte random") + the item contract (b). Assertable
as `/^[0-9a-f]{32}$/`.

### 1.6 Verified validation commands
- **tsc:** `tsc --noEmit -p extension/tsconfig.json` → exit 0 on current extension.
- **unit tests:** `node --import /home/dustin/.local/lib/node_modules/@earendil-works/pi-coding-agent/node_modules/jiti/lib/jiti-register.mjs extension/tests/<file>.test.ts` → existing mode-guard/provider-capture tests pass (exit 0, fail 0). Note a benign `DEP0205` deprecation warning prints (jiti uses `module.register()`); ignore.
- **regression guard:** `pi --no-extensions -e ./extension/pi-editor-bridge.ts --print "ok"` → exit 0.

---

## 2. Scope / boundary decisions (with rationale)

### 2.1 Co-locate startBridge/stopBridge in `extension/pi-editor-bridge.ts` (NOT a new file)
Chose to ADD the functions into the existing single extension file (where
`liveProvider`/`getProvider`/`captureProvider` + the default-export factory
already live) rather than create `extension/bridge-server.ts`. Reasons:
- **Avoids future circular deps.** Later M2 handlers (S8 onConnection→S11–S14
  getSuggestions/applyCompletion/…) need BOTH the socket server AND pi's
  captured provider (`getProvider()`). Co-locating startBridge with getProvider
  keeps both in one module → no bridge-server↔pi-editor-bridge import tangle.
- **Zero tsconfig change.** `pi-editor-bridge.ts` is already in `include`; the
  test lands under the existing `tests/**/*.ts` glob. S5 therefore touches
  tsconfig NOT AT ALL → **zero conflict** with the in-parallel P1.M1.T2.S1 task
  (which appends `"protocol.ts"` to `include`).
- Matches PRD §6.4–6.6 (one module: state + startBridge/stopBridge + handlers +
  default export) and §6.7's single-file-installable intent.

### 2.2 stopBridge MUST be introduced in S5 (not deferred to S6) — it is a hard dependency
The item contract LOGIC (a) says startBridge **calls `stopBridge()` first for
idempotency**. `session_start` fires repeatedly (reload/new/resume/fork — PRD
§6.2), so without an idempotent stop, calling startBridge twice leaks a server +
a socket file. S5 therefore ships a **minimal, working `stopBridge()`**:
- `server?.close()` (guarded), `rmSync(socketPath, { force:true })` (guarded),
  reset the three module vars (`server/socketPath/token`) to `undefined`.
- **OMIT** the `delete process.env.PI_EDITOR_BRIDGE` line from PRD §6.4's
  stopBridge: S5 writes NO env var (that is S16), so there is nothing to clear.
  S16 will add the env WRITE to startBridge and the env DELETE to stopBridge.
- This minimal stopBridge already satisfies the core of plan task
  **P1.M2.T3.S6** ("close server, unlink socket, clear state, idempotent"); the
  PRP flags this so S6 does not blindly recreate it (S6 should reuse + add
  session_shutdown WIRING + the env-clear once S16 lands).

### 2.3 session_start/session_shutdown WIRING is DEFERRED (out of S5 scope)
S5 creates + tests startBridge/stopBridge via **direct invocation**. It does NOT
flip the `// TODO(M2): startBridge(...)` comment into a real call in the
session_start handler. Reason: the existing **mode-guard.test.ts** (S3) invokes
the session_start handler directly in TUI mode with a fake ctx; wiring
startBridge there would trigger a REAL `net.createServer` + `listen` + chmod
during that unit test (side effects + leaked socket). The 1-line wiring belongs
with the session_shutdown wiring (S6) to land the lifecycle atomically; flagged
for the orchestrator. The item OUTPUT ("server/socketPath/token populated, server
listening") is satisfied by tests that call startBridge directly — no wiring
required for that.

### 2.4 `ctx` is accepted but `ctx.cwd` is NOT dereferenced in S5
Per item contract INPUT, `startBridge(ctx: ExtensionContext)`. S5 derives the
socket path from `os.tmpdir()` (item contract (c)), NOT cwd. `ctx.cwd` is
reserved for the S16 `BridgeDescriptor` (env var). The param is accepted to match
the contract signature and forward-compat the S16 descriptor; it is intentionally
not dereferenced (signaled in code with `void ctx;` + JSDoc). tsc strict does not
flag this (no `noUnusedParameters`).

### 2.5 `onConnection` is a deliberate no-op placeholder
Item contract LOGIC (d): "The onConnection callback is a placeholder for now."
S5 defines `function onConnection(_sock: Socket): void {}` with TODOs pointing at
S8 (JSONL reader + dispatcher) and S9 (handshake gate). This keeps S5 independent
of protocol.ts (in-parallel S1) and the framing/handshake tasks.

---

## 3. Design: the `__deps` test seam

```ts
import { createServer, type Server, type Socket } from "node:net";
import { chmodSync, rmSync } from "node:fs";
export const __deps = { createServer, chmodSync };   // mutable plain object
```
- Defaults to the REAL builtins → production behavior is byte-identical to
  calling `net.createServer` / `fs.chmodSync` directly.
- Tests do `const orig = __deps.createServer; __deps.createServer = fake; try {...} finally { __deps.createServer = orig; }` (plain object → assignment allowed; no frozen-namespace problem).
- Honors the contract's "mock net.createServer" intent AND lets the mock test
  additionally assert chmod is called with exactly `0o600` (which a real test
  verifies on-disk instead). Both styles are included in the test plan.

---

## 4. Test plan (node:test + jiti; matches existing test conventions)

File: `extension/tests/bridge-lifecycle.test.ts`. Imports from `../pi-editor-bridge.ts`.
Module singleton state is shared → tests run **sequentially** (node:test default
for top-level tests); each test calls `stopBridge()` in a `finally`. Do NOT enable
concurrency. (Same shared-state caveat as provider-capture.test.ts.)

1. **Mocked unit test (honors contract MOCKING).** Override `__deps.createServer`
   → fake server whose `listen(arg)` records its arg; override `__deps.chmodSync`
   → recorder. Call `startBridge(ctx)`. Assert: `listen` called with a string
   matching `/pi-editor-bridge-[0-9a-f-]+\.sock$/`; `chmodSync` called with
   `(thatPath, 0o600)`; `getToken()` matches `/^[0-9a-f]{32}$/`; `getServer()` is
   the fake; `getSocketPath()` === the listen arg. Restore in finally.
2. **Real integration test.** Real builtins. Call `startBridge`; `await
   events.once(getServer()!, "listening")`; `statSync(getSocketPath()).mode &
   0o777 === 0o600`; `getServer()!.listening === true`; token 32-hex. `stopBridge`
   → `getServer()` undefined, socket file unlinked (`existsSync === false`).
3. **Idempotency.** `startBridge` twice; first server closed (`listening===false`)
   + first socket unlinked; second yields a new server + new path. Cleanup.
4. **stopBridge safe-no-op + reset.** `stopBridge()` when idle does not throw and
   leaves all three getters undefined; after a real start, `stopBridge` clears
   state and unlinks the socket.

---

## 5. Cross-task interface notes (for the orchestrator / sibling PRPs)

- **P1.M1.T2.S1 (protocol.ts, IN PARALLEL):** S5 does NOT touch protocol.ts or
  tsconfig → no conflict. S5's onConnection placeholder does not import protocol
  types yet (S8 will).
- **P1.M2.T3.S6 (stopBridge):** S5 introduces a minimal working stopBridge (see
  §2.2). S6 should REUSE it (verify it exists), wire it into `session_shutdown`,
  and (once S16 lands) add the env-var clear — NOT recreate the function.
- **P1.M2.T3.S5 wiring gap:** startBridge is NOT wired into `session_start` in S5
  (see §2.3). Recommend S6 land both wirings (start in session_start, stop in
  session_shutdown) atomically, OR a dedicated integration step.
- **P1.M3.T8.S16 (env advertisement):** will (a) add the `process.env.PI_EDITOR_BRIDGE`
  JSON write to startBridge (using `getSocketPath()/getToken()` + `ctx.cwd` +
  `process.pid`), and (b) add `delete process.env.PI_EDITOR_BRIDGE` to stopBridge.
  S5's startBridge already reserves `ctx` for this.
- **P1.M2.T4.S8 (onConnection):** will replace the no-op placeholder with the
  JSONL reader + RPC dispatcher (imports protocol.ts + getProvider).
