---
name: "P1.M2.T3.S5 — startBridge(): create Unix socket server, generate token, chmod 0o600"
description: |
  Implement the bridge's socket-server **start** path inside the existing single
  extension file `extension/pi-editor-bridge.ts` (NO new module, NO tsconfig change).
  Specifically, ADD: (1) a `startBridge(ctx: ExtensionContext)` function that
  `stopBridge()`'s first for idempotency, then generates a 32-hex-char random
  **token** (`randomUUID().replace(/-/g,"").slice(0,32)`), derives a unique
  **socket path** under `os.tmpdir()`, creates a `net.Server` via `node:net`'s
  `createServer`, calls `server.listen(socketPath)`, and sets restrictive
  `0o600` perms via `fs.chmodSync` (best-effort, wrapped in try/catch — the token
  is the real auth boundary, PRD §12); (2) a minimal, working, idempotent
  `stopBridge()` (`server?.close()` + `rmSync(socketPath,{force:true})` + reset
  module state) — introduced here because `startBridge` calls it for idempotency
  (it formally completes the core of the sibling task **P1.M2.T3.S6**; S6 will
  REUSE it, add the `session_shutdown` wiring, and the env-clear once S16 lands);
  (3) an `onConnection(_sock)` **no-op placeholder** (S8/S9 territory); (4) a
  `__deps` mutable plain-object test seam (`{createServer, chmodSync}` defaulting
  to the real builtins) because the `node:net` ESM namespace is **frozen** and
  cannot be mocked directly; (5) three **getter functions** `getServer()` /
  `getSocketPath()` / `getToken()` because jiti does **not** implement
  cross-module live-binding reassignment of `export let` (verified) — getters are
  the only way tests can observe the module's `server/socketPath/token` state.
  Also CREATE `extension/tests/bridge-lifecycle.test.ts` — a `node:test`+jiti
  suite with 4 tests: mocked (asserts `createServer`+`chmodSync(_,0o600)` invoked,
  token is `/^[0-9a-f]{32}$/`, getters populated), real integration (binds,
  `await events.once(server,"listening")`, `statSync(path).mode & 0o777 === 0o600`,
  `server.listening===true`, then `stopBridge` unlinks + clears), idempotency
  (second `startBridge` closes server #1 + unlinks its socket, yields a NEW
  server+path), and `stopBridge`-idle-no-op. This task is NARROW: it does **NOT**
  wire `startBridge` into the `session_start` handler (deferred to S6 — wiring now
  would fire a REAL `net.createServer`+`listen`+`chmod` inside the existing
  `mode-guard.test.ts`, leaking a socket; S6 lands both wirings atomically), does
  **NOT** write `process.env.PI_NVIM_BRIDGE` (that is **P1.M3.T8.S16** — S5
  builds the server+token but advertises nothing), does **NOT** dereference
  `ctx.cwd` (reserved for the S16 `BridgeDescriptor`; S5 derives the socket path
  from `os.tmpdir()` per the item contract), does **NOT** touch `protocol.ts`, and
  does **NOT** implement the JSONL reader / handshake / RPC handlers (S7/S8/S9/S11–S15).
---

## Goal

**Feature Goal**: Land the bridge's socket-server **lifecycle start** so that, when
invoked directly, `startBridge(ctx)` produces a **listening** `net.Server` bound to a
unique Unix-domain-socket file under `os.tmpdir()` with on-disk permissions `0o600`,
backed by a freshly-generated 32-hex-char secret **token**, with all three pieces of
state (`server`, `socketPath`, `token`) observable via getters and fully reset by an
idempotent `stopBridge()`. This is the foundation every later M2 task builds on:
S8's `onConnection` (replacing the placeholder) needs `getServer()`; S9's handshake
needs `getToken()`; S16's env advertisement needs `getSocketPath()` + `getToken()` +
`ctx.cwd`. Crucially the start/stop must be **idempotent** so the repeated
`session_start` events pi fires (reload/new/resume/fork — PRD §6.2) never leak a
server or orphan a socket file.

**Deliverable** (all under `extension/`):
1. **MODIFY** `extension/pi-editor-bridge.ts` — ADD the bridge-server section
   (after the existing `getProvider` export, BEFORE the unchanged default-export
   factory): `node:*` value imports; the `__deps` test seam; module state
   (`server/socketPath/token`); getters `getServer/getSocketPath/getToken`; the
   `onConnection` no-op placeholder; `stopBridge`; `startBridge`. Each addition
   carries Mode-A JSDoc with a `STATUS (P1.M2.T3.S5)` marker and forward
   references (S6 wiring, S8 onConnection, S16 env). The **default-export factory
   is UNCHANGED** — its `// TODO(M2): startBridge(...)` comment stays exactly as
   is (wiring is S6).
2. **CREATE** `extension/tests/bridge-lifecycle.test.ts` — a `node:test`+jiti
   suite (matching the S2/S3/S4 test conventions) with 4 tests exercising the
   code directly via the getters + the `__deps` seam. No `session_start`/`session_shutdown`
   handler invocation (that would need wiring S5 deliberately omits).

**Success Definition**:
- `tsc --noEmit -p extension/tsconfig.json` → exit 0, **no output** (the `node:*`
  value imports + the `__deps`/getter/server code type-check under the current
  tsconfig with NO tsconfig edit — verified).
- `node --import <pi>/node_modules/jiti/lib/jiti-register.mjs extension/tests/bridge-lifecycle.test.ts`
  → exit 0, `fail 0` (all 4 tests pass; the real-integration test asserts an
  on-disk socket mode of exactly `0o600` and a 32-hex token).
- Pre-existing suites still green: `provider-capture.test.ts` (S2),
  `mode-guard.test.ts` (S3), `protocol.test.ts` (S4) — S5 is purely additive to
  `pi-editor-bridge.ts` and adds one test file; it touches nothing they read.
- Regression: `pi --no-extensions -e ./extension/pi-editor-bridge.ts --print "ok"`
  exits 0 with no error lines AND the startup log is still ABSENT in print mode
  (S3 guard intact — S5 does NOT touch the default-export factory).
- No socket leak / no orphaned socket file left in `os.tmpdir()` after the test
  run (every test calls `stopBridge()` in `finally`).

## User Persona (if applicable)

**Target User**: The bridge-extension author and every later M2/M3 implementer
(S6 stopBridge-wiring + session_shutdown, S7/S8 connection handling, S9
handshake, S11–S14 RPC handlers, S16 env advertisement). This task is the
runtime backbone those tasks hang off.

**Use Case**: When S8 implements `onConnection`, it replaces the placeholder
inside the server already created by `startBridge`, reached via `getServer()`.
When S9 validates the `hello` token, it compares against `getToken()`. When S16
serializes the `BridgeDescriptor` to `process.env.PI_NVIM_BRIDGE`, it reads
`getSocketPath()` + `getToken()` + `ctx.cwd` + `process.pid`. None of that exists
until `startBridge` is real and observable.

**Pain Points Addressed**:
- Without an idempotent start/stop, the repeated `session_start` events pi fires
  on every reload/new/resume/fork would each `listen()` a new server on a new
  path and leak the previous one (server fd + socket file). `startBridge()` calls
  `stopBridge()` first to make re-entry safe.
- Without a mockable seam, the frozen `node:net` namespace (verified — see Gotchas)
  makes unit-testing the "createServer is called / chmod is 0o600" contract
  impossible. The `__deps` seam fixes that without changing production behavior.
- Without getters, jiti's lack of cross-module `export let` live-binding (verified)
  would make the server state invisible to tests.

## Why

- **Foundation of the whole M2 milestone.** The JSONL reader (S7), connection
  dispatcher (S8), handshake (S9), and RPC handlers (S11–S14) all attach to the
  server `startBridge` creates. S5 makes that server real, listening, and
  testable in isolation.
- **Idempotency is a hard correctness requirement, not a nicety.** pi fires
  `session_start` on startup **and** on reload/new/resume/fork (PRD §6.2). A
  non-idempotent start would leak one server + one socket file per reset. The
  `stopBridge()`-first design (the PRD §6.4 reference skeleton calls `stopBridge()`
  as its first line) guarantees exactly one live server per session.
- **Token + 0o600 = the local security model (PRD §12).** The 32-hex token is the
  real auth boundary (delivered to the editor only via `process.env` in S16, then
  echoed back in the `hello` handshake in S9); `0o600` perms are defense-in-depth
  on the socket file. S5 stands both up.
- **Single-file, zero-dep, zero-config increment.** Co-locating with
  `getProvider()` avoids a future circular-import tangle (later handlers need BOTH
  the server AND pi's captured provider), requires NO tsconfig edit (the file is
  already in `include`; the test matches the existing `tests/**/*.ts` glob), and
  introduces only Node builtins (`net`/`crypto`/`fs`/`os`/`path`) — honoring PRD
  §6.7's "no npm runtime dependencies" requirement.

## What

Additive code inside `extension/pi-editor-bridge.ts` + one new test file. No new
module, no tsconfig change, no `protocol.ts` touch, no env write, no
session-handling wiring. The server is exercised **only by direct invocation**
in tests.

### Success Criteria

- [ ] `startBridge(ctx: ExtensionContext)` exists and, on call, leaves
      `getServer()` as a `net.Server`, `getSocketPath()` as a string matching
      `/pi-editor-bridge-[0-9a-f-]+\.sock$/` under `os.tmpdir()`, and
      `getToken()` as a string matching `/^[0-9a-f]{32}$/`.
- [ ] `startBridge` calls `stopBridge()` **first** (idempotent re-entry).
- [ ] After a real `startBridge`, `await events.once(server,"listening")` resolves
      and `statSync(socketPath).mode & 0o777 === 0o600` (on-disk perms verified).
- [ ] `chmodSync` is wrapped in try/catch (a chmod hiccup must NOT crash
      `session_start`); the `process.platform !== "win32"` guard skips it on Windows.
- [ ] `stopBridge()` is idempotent: safe no-op when idle (does not throw), and
      after a real start it `close()`s the server, `rmSync(socketPath,{force:true})`s
      the file, and resets all three state vars to `undefined` (getters return `undefined`).
- [ ] Calling `startBridge` twice closes server #1, unlinks its socket, and yields a
      NEW server + NEW path (no leak).
- [ ] `onConnection(_sock: Socket)` is a no-op placeholder with TODOs pointing at
      S8 (reader+dispatcher) and S9 (handshake).
- [ ] `__deps = { createServer, chmodSync }` is an exported mutable plain object
      defaulting to the real builtins; production behavior is byte-identical to
      calling them directly.
- [ ] State is exposed ONLY via getters (`getServer/getSocketPath/getToken`); there
      is NO `export let`.
- [ ] `ctx` is accepted (matches the contract signature) but `ctx.cwd` is NOT
      dereferenced in S5 (reserved for S16; signaled in code with `void ctx;`).
- [ ] The default-export factory is UNCHANGED — the `// TODO(M2): startBridge(...)`
      comment at the current line 101 is byte-for-byte intact (wiring = S6).
- [ ] NO `process.env.PI_NVIM_BRIDGE` write anywhere (that is S16).
- [ ] NO import of `protocol.ts` (the `onConnection` placeholder doesn't need it yet).
- [ ] `tsc --noEmit -p extension/tsconfig.json` → exit 0, no output.
- [ ] `extension/tests/bridge-lifecycle.test.ts` → 4 tests pass (`fail 0`).
- [ ] S2/S3/S4 suites still pass; `pi --print "ok"` regression exits 0.

## All Needed Context

### Context Completeness Check

_Pass test_: An agent who has never seen this repo, given the current
`extension/pi-editor-bridge.ts` (post-S3), `extension/protocol.ts` (post-S4),
`extension/tsconfig.json`, and this PRP, can (1) add the bridge-server section
verbatim from the reference body below (every import, signature, and the exact
`__deps`/getter/`startBridge`/`stopBridge` shape is pinned), (2) write the test
from the supplied skeleton, (3) run the four exact validation commands to green —
with every Node-builtin line number and every design decision (why getters not
`export let`, why `__deps`, why chmod-after-listen is safe, why no wiring, why
no env) cited and empirically verified here.

### Documentation & References

```yaml
# MUST READ — the component spec (S5 implements §6.4 startBridge + the §6.4 stopBridge tail)
- docfile: PRD.md
  why: §6.4 Server lifecycle reference skeleton (startBridge: stopBridge()-first, randomUUID token, tmpdir socket, createServer, listen, chmod 0o600); §6.5 Request handling (the onConnection placeholder is where S8 lands); §6.6 default export (calls startBridge — S6 wires it); §6.7 requirements (no npm deps, idempotent start/stop, survives multiple editor open/close); §12 Security (0o600 perms + token is the real auth boundary); §5.1 transport (socket path format + 0600 perms); §2.1 (editor inherits process.env — the reason S16 advertises via env)
  section: "§6.4 (startBridge/stopBridge skeleton), §6.5 (handler shape — onConnection), §6.6 (default export), §6.7 (req checklist: no npm deps, idempotent, multiple cycles), §12 (0o600 + token), §5.1 (socket path + perms), §2.1 (env inheritance — why S16 advertises via env, not S5)"
  critical: |
    §6.4's stopBridge() body includes a `delete process.env[BRIDGE_ENV]` line. S5 OMITS that
    line (S5 writes NO env var — S16 does, and adds the matching delete). S5 ships only the
    server/socket/state teardown half of stopBridge. S6 will REUSE this stopBridge (verify it
    exists) rather than recreate it.

# MUST READ — the pre-researched, empirically-verified analysis FOR THIS EXACT TASK
- docfile: plan/001_c56962b4fa17/P1M2T1S1/research/notes.md
  why: the authoritative task analysis: every load-bearing claim (frozen node:net namespace → __deps; jiti no export-let live-binding → getters; chmod-after-listen safe; token 32-hex; node:* imports type-check with no tsconfig change) was empirically verified on this machine; the §2 scope decisions (co-locate in pi-editor-bridge.ts; stopBridge MUST ship in S5; wiring DEFERRED to S6; ctx.cwd NOT dereferenced; onConnection placeholder); the §3 __deps design; the §4 4-test plan. (Dir note: P1M2T1S1 is the SAME work item as P1.M2.T3.S5 — the research itself notes "plan task P1.M2.T3.S5; orchestrator placed artifacts under P1M2T1S1".)
  section: "§1 empirical findings (1.1 frozen namespace, 1.2 jiti live-binding, 1.3 node:* type-check, 1.4 chmod-after-listen, 1.5 token format, 1.6 validation cmds); §2 scope decisions; §3 __deps design; §4 test plan; §5 cross-task notes"
  critical: |
    This is the single most important reference. The PRP's reference body implements it
    verbatim. Every "why" in this PRP traces to a numbered §-claim there.

# MUST READ — the @types/node declarations S5 imports (installed dist; line-verified)
- file: /home/dustin/.local/lib/node_modules/@earendil-works/pi-coding-agent/node_modules/@types/node/net.d.ts
  why: confirms createServer, the Server class, the listen(path) Unix/IPC overload, and the `listening` getter
  section: "L587 `class Server extends EventEmitter`; L635-636 `listen(path: string, backlog?, listeningListener?)` + `listen(path, listeningListener?)` (the Unix-domain/IPC overload S5 uses); L709 `listening` boolean getter ('Indicates whether or not the server is listening'); createServer(connectionListener?: (socket: Socket) => void): Server (search 'createServer' — exported)"
  critical: |
    `server.listen(socketPath)` is ASYNC ('listening' emits later) but libuv creates the
    socket FILE synchronously before listen() returns — verified on-disk, so chmodSync
    immediately after listen() does not ENOENT. Do NOT await listen in startBridge (it would
    force the fn async and complicate the idempotent call site); await the 'listening' event
    in the test instead.

- file: /home/dustin/.local/lib/node_modules/@earendil-works/pi-coding-agent/node_modules/@types/node/crypto.d.ts
  why: confirms randomUUID signature
  section: "L3572 `function randomUUID(options?: RandomUUIDOptions): UUID`"

- file: /home/dustin/.local/lib/node_modules/@earendil-works/pi-coding-agent/node_modules/@types/node/fs.d.ts
  why: confirms chmodSync / rmSync / existsSync signatures
  section: "L824 `function chmodSync(path: PathLike, mode: Mode): void`; L1681 `function rmSync(path: PathLike, options?: RmOptions): void`; L3554 `function existsSync(path: PathLike): boolean`"

# MUST READ — the baseline S5 builds on
- docfile: plan/001_c56962b4fa17/P1M1T1S3/PRP.md
  why: defines the post-S3 shape of extension/pi-editor-bridge.ts (liveProvider/getProvider/captureProvider + the TUI-guarded session_start + no-op session_shutdown + the unwired `// TODO(M2): startBridge(...)` comment at the call site). S5 ADDS to this file without touching the existing exports or the default-export factory.
  section: "Goal + Implementation Patterns (S3 session_start handler shape) + the TODO(M2) call site"
  critical: |
    S5 inserts the bridge-server section AFTER `getProvider()` and BEFORE the default export.
    It must NOT alter captureProvider/getProvider/liveProvider, the session_start handler
    (TUI guard + log + captureProvider call), or the session_shutdown no-op. TAB indentation
    + import-type discipline already established here are the house style — match them.

# SUPPORTING — house test conventions (S5's test follows these exactly)
- file: extension/tests/mode-guard.test.ts
  why: the canonical node:test+jiti test pattern in THIS repo: `import { test } from "node:test"`, `import assert from "node:assert/strict"`, import the unit-under-test via `from "../pi-editor-bridge.ts"`, fake-ctx construction, sequential-by-default shared-state note.
  section: "whole file — import style, fakePi/fakeCtx helpers, `test(...)` top-level (no describe), shared-state sequential caveat"

# SUPPORTING — provider-capture test (same module-state/getter pattern S5 reuses)
- file: extension/tests/provider-capture.test.ts
  why: proves the getter-over-export-let pattern is ALREADY the house idiom (`getProvider()` reads module singleton state; tests assert against it). S5's getServer/getSocketPath/getToken follow the exact same shape.
  section: "makeFakeProvider helper; `getProvider()` identity assertions; re-capture test (proves module singleton reassignment works through a getter)"

# SUPPORTING — architecture context (project-local)
- docfile: plan/001_c56962b4fa17/architecture/external_deps.md
  why: confirms the node builtin inventory S5 uses + the (future) luv socket-client mirror on the Neovim side
  section: "§5 Node builtins (net/crypto/fs/os/path); §1.4 luv Unix-socket client (the bridge's future counterpart, P2.M5)"

# SUPPORTING — Node net docs (read semantics / events only — types come from @types/node above)
- url: https://nodejs.org/api/net.html#serverlistenpath-backlog-callback
  why: confirms listen(path) is the IPC/Unix-domain overload, that 'listening' emits on success, and that an unhandled 'error' event (e.g. EADDRINUSE) THROWS and would crash the process.
  section: "`server.listen(path[, backlog][, callback])` (IPC servers); Event: 'listening'; Event: 'error' ('Emitted when an error occurs... if not listened for, the process will crash')"
  critical: |
    For S5 the server is invoked only from tests (controlled tmpdir, unique UUID path → no
    EADDRINUSE), so an explicit 'error' handler is NOT required to pass S5's tests. But it is
    a REAL production hazard once S6 wires startBridge into session_start. S5's JSDoc flags
    this for S6: "wire a server.on('error', ...) handler when wiring into session_start, or an
    async listen failure will crash pi." Do NOT add the handler in S5 (out of scope; tests
    don't exercise failure).

# SUPPORTING — JSON-RPC 2.0 (NOT used by S5 runtime, but the token is consumed by S9's handshake)
- url: https://www.jsonrpc.org/specification#error_object
  why: context only — S5 generates the token S9 will validate against in `hello` (PRD §5.3 returns error code -32600 "bad token" on mismatch). S5 does not implement handshake.
```

### Current Codebase tree (post-S4 baseline — S5 ADDS to pi-editor-bridge.ts + 1 test)

```bash
extension/
├── pi-editor-bridge.ts            # (S1+S2+S3) default-export factory; session_start (TUI guard + log + captureProvider) + session_shutdown (no-op); captureProvider/getProvider/liveProvider; UNWIRED `// TODO(M2): startBridge(...)` at L101. S5 ADDS the bridge-server section here (NOT a new file).
├── protocol.ts                    # (S4) type-only JSON-RPC contract. S5 does NOT touch / import it.
├── tsconfig.json                  # (S1+S2+S4) include=["pi-editor-bridge.ts","protocol.ts","tests/**/*.ts"]; paths map BOTH pi-coding-agent AND pi-tui. S5 does NOT edit (new test matches tests/**/*.ts; node:* imports type-check under current compilerOptions — verified).
└── tests/
    ├── provider-capture.test.ts   # (S2) node:test suite for captureProvider/getProvider
    ├── mode-guard.test.ts         # (S3) node:test suite for the TUI guard
    └── protocol.test.ts           # (S4) node:test+jiti suite for protocol.ts
# plan/ holds planning artifacts only — no other source code
```

### Desired Codebase tree with files to be added/modified

```bash
extension/
├── pi-editor-bridge.ts            # (MODIFY) ADD: node:* value imports; __deps seam; module state (server/socketPath/token); getters getServer/getSocketPath/getToken; onConnection placeholder; stopBridge; startBridge. Default-export factory UNCHANGED.
├── protocol.ts                    # (UNCHANGED — S4)
├── tsconfig.json                  # (UNCHANGED — include already covers the new test)
└── tests/
    ├── provider-capture.test.ts   # (UNCHANGED — S2)
    ├── mode-guard.test.ts         # (UNCHANGED — S3)
    ├── protocol.test.ts           # (UNCHANGED — S4)
    └── bridge-lifecycle.test.ts   # (CREATE) node:test+jiti: mocked createServer+chmod(0o600)+token; real bind+0o600 mode+listening+stopBridge unlink; idempotent double-start; stopBridge idle no-op.
```

**File responsibilities**
- `extension/pi-editor-bridge.ts` — gains the socket-server start/stop runtime. The
  new `__deps` seam is the test surface; the getters are the cross-task seam (S8/S9/S16
  read state through them). `startBridge`/`stopBridge` are exported (S6 will wire them
  into the lifecycle; S16 will extend `startBridge` with the env write).
- `extension/tests/bridge-lifecycle.test.ts` — the contract gate for S5: proves
  createServer+chmod(0o600)+token on the mocked path, and a real 0o600 on-disk socket +
  clean teardown + idempotency on the real path.

### Known Gotchas of our codebase & Library Quirks

```typescript
// CRITICAL (verified): the `node:net` ESM module namespace is FROZEN. `mock.method(net,
//   "createServer", fn)` / `Object.defineProperty(net, "createServer", ...)` throws
//   TypeError "Cannot redefine property: createServer". You CANNOT mock node:net directly.
//   RESOLUTION: a mutable plain-object `__deps = { createServer, chmodSync }` (exported)
//   that defaults to the real builtins. Production calls __deps.createServer (byte-identical
//   to net.createServer). Tests do `__deps.createServer = fake; try {...} finally { restore }`.
//   Plain object → property assignment is allowed; no frozen-namespace problem. (research §1.1)

// CRITICAL (verified): jiti (pi's TS loader) does NOT implement cross-module live-binding
//   reassignment. A producer `export let server` mutated by `setServer("x")` is NOT observed
//   by a consumer that imported `server` (consumer keeps seeing the initial `undefined`).
//   RESOLUTION: expose state ONLY through getter functions (getServer/getSocketPath/getToken),
//   exactly like the EXISTING getProvider() idiom in this file. NEVER `export let`. (research §1.2)

// CRITICAL (verified): chmod-after-listen is SAFE. libuv creates the Unix-domain socket FILE
//   synchronously inside listen() (before it returns), so `chmodSync(socketPath, 0o600)`
//   immediately after `server.listen(socketPath)` does NOT ENOENT; the on-disk mode is exactly
//   0o600. Do NOT chmod-before-listen (path doesn't exist yet → ENOENT). (research §1.4)
//   Still wrap chmodSync in try/catch: 0o600 is defense-in-depth; the token is the real auth
//   boundary (PRD §12), so a chmod hiccup must never crash session_start.

// CRITICAL (verified): node:* value imports (createServer/randomUUID/chmodSync/rmSync/tmpdir/join)
//   type-check under the CURRENT tsconfig (`"types": []`) with NO edit. Reason: moduleResolution
//   "Bundler" resolves the `declare module "node:net"` shipped by @types/node; "types":[] only
//   restricts AMBIENT/global @types inclusion, not explicit module imports. DO NOT add @types/node
//   to "types" and DO NOT add new paths. (research §1.3)

// GOTCHA: listen() is ASYNC ('listening' emits later) but returns synchronously. S5's
//   startBridge is a SYNC void fn (so the idempotent call site + the default-export wiring
//   in S6 stay simple). Tests that need to assert `server.listening===true` / on-disk mode
//   `await events.once(server, "listening")` BEFORE asserting. Do NOT make startBridge async.

// GOTCHA: an unhandled 'error' event on a net.Server THROWS and crashes the process. In S5's
//   tests the path is a unique UUID under tmpdir → no EADDRINUSE → no 'error', so no handler is
//   needed to pass S5. But once S6 wires startBridge into session_start, an async listen failure
//   WOULD crash pi. S5's JSDoc flags this for S6: wire `server.on('error', ...)` when wiring.
//   Do NOT add the handler in S5 (out of scope; no test exercises it).

// GOTCHA: S5 writes NO process.env.PI_NVIM_BRIDGE. The §6.4 reference startBridge skeleton
//   includes `process.env[BRIDGE_ENV] = JSON.stringify(...)` and the matching stopBridge
//   `delete process.env[BRIDGE_ENV]`. S5 OMITS BOTH (env advertisement is P1.M3.T8.S16). S5's
//   startBridge builds server+token+path; S16 extends startBridge to also write the descriptor
//   (using getSocketPath()/getToken()/ctx.cwd/process.pid) and extends stopBridge to delete it.

// GOTCHA: ctx.cwd is NOT dereferenced in S5. The §6.4 skeleton takes startBridge(ctx, cwd);
//   S5 takes startBridge(ctx) only (research §2.4) and signals the unused param with `void ctx;`
//   + JSDoc. ctx.cwd is reserved for the S16 BridgeDescriptor. S5 derives the socket path from
//   os.tmpdir() per the item contract. (tsconfig has no noUnusedParameters → `void ctx;` is a
//   belt-and-suspenders clarity marker, not a compile requirement.)

// GOTCHA: do NOT wire startBridge into the session_start handler in S5. The existing
//   mode-guard.test.ts (S3) invokes the session_start handler directly in tui mode with a fake
//   ctx; wiring startBridge there would fire a REAL net.createServer + listen + chmod during that
//   unit test (side effects + leaked socket + chmod on tmpdir). The 1-line wiring belongs with
//   the session_shutdown wiring in S6, landed atomically. S5's success criteria are satisfied by
//   tests that call startBridge DIRECTLY.

// STYLE: TABS for indentation (match the existing pi-editor-bridge.ts + pi examples). `import
//   type` for all type-only imports; node:* VALUE imports are separate statements (or use the
//   inline `type` modifier, e.g. `import { createServer, type Server, type Socket } from "node:net";`).
//   Mode-A JSDoc on every new export with a `STATUS (P1.M2.T3.S5)` marker + forward refs.
```

## Implementation Blueprint

### Data models and structure

S5 has no new data *types* (the protocol types live in `protocol.ts`, S4). Its
"data model" is **module-level runtime state** plus a **test seam**:

- `server: Server | undefined` — the live `net.Server` (or `undefined` when stopped).
- `socketPath: string | undefined` — the bound socket file path (`${tmpdir()}/pi-editor-bridge-${randomUUID()}.sock`).
- `token: string | undefined` — the 32-hex-char secret.
- `__deps: { createServer: typeof createServer; chmodSync: typeof chmodSync }` —
  exported mutable seam; defaults to real builtins.
- Getters `getServer()`/`getSocketPath()`/`getToken()` — the only sanctioned read path
  (jiti-safe; matches `getProvider()`).

All four module vars are `let` (module-private, mutated only by start/stop) and read
only via the getters. There is exactly ONE live server per module instance (singleton),
mirroring the `liveProvider` singleton already in this file.

### Implementation Tasks (ordered by dependencies)

```yaml
Task 1: MODIFY extension/pi-editor-bridge.ts — ADD node:* value imports
  - ADD (near the top, after the existing `import type {...} from "@earendil-works/pi-tui"`
      and `import type {...} from "@earendil-works/pi-coding-agent"` blocks):
        import { createServer, type Server, type Socket } from "node:net";
        import { randomUUID } from "node:crypto";
        import { chmodSync, rmSync } from "node:fs";
        import { tmpdir } from "node:os";
        import { join } from "node:path";
  - NOTE: `ExtensionContext` is ALREADY imported (L24) — reuse it for startBridge's param;
    do NOT re-import. `Server`/`Socket` use the inline `type` modifier (modern TS, no
    separate import block needed).
  - FOLLOW: TAB indentation; keep the existing two `import type` blocks above these.
  - DO NOT: import anything from protocol.ts (the onConnection placeholder doesn't need
    it yet); add a value import from @earendil-works/* (the bridge is builtins-only here).

Task 2: MODIFY extension/pi-editor-bridge.ts — ADD the bridge-server section
  - PLACE: AFTER the existing `getProvider()` function export, BEFORE the
      `export default function (pi: ExtensionAPI): void {` factory. (Keeps provider
      capture + server runtime together — later handlers need BOTH, avoiding a circular
      import with a separate server module; research §2.1.)
  - ADD (each with a Mode-A JSDoc + STATUS marker; see Implementation Patterns for the
      exact reference body):
      (a) `export const __deps = { createServer, chmodSync };` — typed mutable seam.
      (b) module state: `let server: Server | undefined; let socketPath: string | undefined;
          let token: string | undefined;`
      (c) getters: `export function getServer(): Server | undefined` (and getSocketPath,
          getToken) returning the matching var.
      (d) `function onConnection(_sock: Socket): void { /* TODO(S8): JSONL reader+dispatcher; TODO(S9): handshake gate */ }`
          — no-op placeholder.
      (e) `export function stopBridge(): void` — `server?.close()` (guarded),
          `rmSync(socketPath,{force:true})` (guarded), reset all three vars. NO env delete
          (S16's job). JSDoc notes it is called by startBridge for idempotency AND completes
          the core of sibling task S6.
      (f) `export function startBridge(ctx: ExtensionContext): void` — `stopBridge()` first;
          `void ctx;` (cwd reserved for S16); `token = randomUUID().replace(/-/g,"").slice(0,32);`;
          `socketPath = join(tmpdir(), \`pi-editor-bridge-${randomUUID()}.sock\`);`;
          `server = __deps.createServer((sock)=>onConnection(sock));`;
          `server.listen(socketPath);`; `if (process.platform!=="win32") try { __deps.chmodSync(socketPath,0o600); } catch {}`;
          JSDoc notes NO env write (S16), NO wiring (S6), and the S6 'error'-handler heads-up.
  - FOLLOW: TAB indentation; match the JSDoc density/STATUS style of the existing
      captureProvider/getProvider (file-level + per-export Mode-A doc).
  - NAMING: startBridge / stopBridge / getServer / getSocketPath / getToken / onConnection
      / __deps — exact (the getters match the getProvider idiom; __deps double-underscore
      signals "test seam, not public API").
  - DO NOT: alter captureProvider/getProvider/liveProvider; alter the default-export
      factory (the L101 `// TODO(M2): startBridge(...)` comment stays intact); write
      process.env; dereference ctx.cwd; import protocol.ts; add an async signature; add a
      server 'error' handler (deferred to S6 — flag in JSDoc).

Task 3: CREATE extension/tests/bridge-lifecycle.test.ts (node:test + jiti)
  - IMPORT: `import { test } from "node:test"; import assert from "node:assert/strict";`
      `import { statSync, existsSync } from "node:fs"; import { once } from "node:events";`
      `import type { ExtensionContext } from "@earendil-works/pi-coding-agent";`
      `import { startBridge, stopBridge, getServer, getSocketPath, getToken, __deps }
         from "../pi-editor-bridge.ts";`
  - TEST 1 (mocked — honors the createServer/chmod contract without real sockets):
      stash real builtins; override `__deps.createServer` → fake server whose
      `listen(arg)` records arg + returns itself, with a `close()` no-op; override
      `__deps.chmodSync` → recorder `{path,mode}`; call `startBridge(ctx)`; assert
      listen-arg matches `/pi-editor-bridge-[0-9a-f-]+\.sock$/`, chmodCall.mode===0o600,
      chmodCall.path===listenArg, `getToken()` matches `/^[0-9a-f]{32}$/`,
      `getSocketPath()`===listenArg, `getServer()` truthy. Restore + stopBridge in finally.
  - TEST 2 (real integration): real builtins; `startBridge(ctx)`; `const srv=getServer()`;
      assert srv truthy; `await once(srv!,"listening")`; `const path=getSocketPath()`;
      assert path truthy, `srv!.listening===true`; `statSync(path!).mode & 0o777 === 0o600`;
      `stopBridge()`; assert getters all undefined, `existsSync(path)===false`.
  - TEST 3 (idempotency): `startBridge` twice; capture first server+path; assert second
      `getServer()`!==first, `getSocketPath()`!==first, `existsSync(firstPath)===false`;
      `await once(getServer()!,"listening")`; `stopBridge()`.
  - TEST 4 (stopBridge idle no-op + reset): `assert.doesNotThrow(()=>stopBridge())`;
      assert all three getters undefined.
  - SHARED-STATE CAVEAT: module singleton state → tests run SEQUENTIALLY (node:test
      default for top-level tests — do NOT enable concurrency; same caveat as
      provider-capture.test.ts). Each real test cleans up with stopBridge() in a try/finally
      or at its end. The fake ctx is `{} as ExtensionContext` (startBridge does not read it).
  - FOLLOW: TAB indentation; reuse the SAME jiti register hook path as S2/S3/S4 tests.
  - NAMING: descriptive `test("...", ...)` titles; no `describe`.
  - PLACEMENT: extension/tests/bridge-lifecycle.test.ts (matches the existing tests/**/*.ts glob → NO tsconfig edit).

Task 4: VALIDATE — run the four validation commands; fix until all green
  - RUN (Level 1): `tsc --noEmit -p extension/tsconfig.json` (expect exit 0, no output)
  - RUN (Level 2): `node --import <jiti-register> extension/tests/bridge-lifecycle.test.ts`
      (expect exit 0, fail 0 — ignore the benign jiti DEP0205 deprecation on stderr)
  - RUN (Level 2 regression): re-run provider-capture.test.ts + mode-guard.test.ts +
      protocol.test.ts — expect each fail 0
  - RUN (Level 3): `pi --no-extensions -e ./extension/pi-editor-bridge.ts --print "ok"`
      exits 0 with NO error lines AND the startup-log line ABSENT in print mode (S3 intact)
```

### Implementation Patterns & Key Details

```typescript
// === extension/pi-editor-bridge.ts — ADD these imports near the top (after the two
//     existing `import type {...}` blocks; ExtensionContext is ALREADY imported at L24) ===
import { createServer, type Server, type Socket } from "node:net";
import { randomUUID } from "node:crypto";
import { chmodSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

// === extension/pi-editor-bridge.ts — ADD the bridge-server section AFTER getProvider(),
//     BEFORE the `export default function (pi: ExtensionAPI): void {` factory. ===

/**
 * Mutable dependency seam for the bridge's socket server, defaulting to the REAL Node
 * builtins so production behavior is byte-identical to calling `net.createServer` /
 * `fs.chmodSync` directly.
 *
 * WHY A SEAM (not direct calls or module mocking): the `node:net` ESM module namespace
 * is FROZEN — `mock.method(net,"createServer",fn)` / `Object.defineProperty` throws
 * `TypeError: Cannot redefine property: createServer` (verified on Node 26.4.0). A plain
 * mutable object is the clean way to honor the S5 test contract ("mock createServer +
 * assert chmod is called with 0o600") without fighting the frozen namespace. Tests do
 * `const real = __deps.createServer; __deps.createServer = fake; try {...} finally
 * { __deps.createServer = real; }` (research §1.1, §3).
 *
 * STATUS (P1.M2.T3.S5): server-start seam. Later handlers do NOT go through __deps
 * (only createServer + chmodSync are seam'd, because only those have a test contract in S5).
 */
export const __deps: {
	createServer: typeof createServer;
	chmodSync: typeof chmodSync;
} = {
	createServer,
	chmodSync,
};

/** The live bridge socket server, or `undefined` when stopped. Module singleton. */
let server: Server | undefined;
/** The bound Unix-domain socket file path, or `undefined` when stopped. */
let socketPath: string | undefined;
/** The 32-hex-char secret token (the real auth boundary, PRD §12), or `undefined` when stopped. */
let token: string | undefined;

/** @returns the live bridge server (S8 wires onConnection onto it), or `undefined`. */
export function getServer(): Server | undefined {
	return server;
}
/** @returns the bound socket path (S16 reads this for the BridgeDescriptor), or `undefined`. */
export function getSocketPath(): string | undefined {
	return socketPath;
}
/** @returns the secret token (S9's hello handshake validates against this), or `undefined`. */
export function getToken(): string | undefined {
	return token;
}
// NOTE: state is exposed ONLY via getters. jiti (pi's TS loader) does NOT implement
// cross-module live-binding reassignment of `export let` — a consumer that imported a
// `let` would keep seeing the initial value forever (verified, research §1.2). Getters
// read the current value on each call. This mirrors the EXISTING getProvider() idiom.

/**
 * Per-connection handler. NO-OP PLACEHOLDER in S5.
 *
 * STATUS (P1.M2.T3.S5): placeholder. S8 replaces the body with the JSONL line reader
 * (buffer partials, split on `\n` only, strip `\r`) + the RPC dispatcher (id correlation,
 * JSON-RPC envelope handling — imports protocol.ts). S9 adds the handshake gate (reject
 * every method before a valid `hello`; -32600 "bad token" on mismatch). S11–S14 add the
 * method handlers (getSuggestions/applyCompletion/shouldTriggerFileCompletion/ping/bye/
 * getCommands), delegating to getProvider(). Until then, connections are accepted but
 * receive no responses.
 */
function onConnection(_sock: Socket): void {
	// TODO(S8): wire the JSONL reader + RPC dispatcher onto _sock.
	// TODO(S9): gate every method behind a valid hello handshake (token == getToken()).
}

/**
 * Tear down the bridge server: close the server, unlink the socket file, reset state.
 * IDEMPOTENT — safe to call when already stopped (all guards swallow no-op failures).
 *
 * STATUS (P1.M2.T3.S5): ships the server/socket/state teardown half. This is also the
 * core of sibling task **P1.M2.T3.S6** ("close server, unlink socket, clear state,
 * idempotent") — S6 should REUSE this function (verify it exists), wire it into
 * `session_shutdown`, and (once S16 lands) add the `delete process.env.PI_NVIM_BRIDGE`
 * line. S5 does NOT delete the env var because S5 writes NONE (env advertisement is S16).
 * S5 calls stopBridge() as the first line of startBridge() for idempotent re-entry.
 */
export function stopBridge(): void {
	try {
		server?.close(); // no-op if undefined or already closing; never throw
	} catch {
		/* idempotent */
	}
	if (socketPath) {
		try {
			rmSync(socketPath, { force: true }); // force:true → no ENOENT if already gone
		} catch {
			/* idempotent */
		}
	}
	server = undefined;
	socketPath = undefined;
	token = undefined;
	// NOTE: `delete process.env.PI_NVIM_BRIDGE` is intentionally OMITTED here — S5 writes
	// no env var. S16 adds the WRITE to startBridge and the matching DELETE here.
}

/**
 * Start the bridge socket server: generate a fresh token, bind a unique Unix-domain
 * socket under `os.tmpdir()`, and set restrictive `0o600` perms. IDEMPOTENT — calls
 * {@link stopBridge} first so repeated `session_start` events (reload/new/resume/fork,
 * PRD §6.2) never leak a server or orphan a socket file.
 *
 * STATUS (P1.M2.T3.S5): server-start runtime. OUT OF SCOPE here (landed by later tasks):
 *  - process.env.PI_NVIM_BRIDGE advertisement ........ P1.M3.T8.S16 (will call
 *    getSocketPath()/getToken()/ctx.cwd/process.pid here to build the BridgeDescriptor).
 *  - wiring startBridge into the session_start handler .. P1.M2.T3.S6 (the L101
 *    `// TODO(M2): startBridge(...)` call site). NOT wired in S5 so the existing
 *    mode-guard.test.ts (S3) doesn't fire a real listen/chmod during a unit test.
 *  - server.on('error', ...) handler .................... S6, when wiring. An unhandled
 *    'error' event (e.g. EADDRINUSE) THROWS and would crash pi; S5's tests use unique
 *    UUID paths under tmpdir so no 'error' arises, but the production wiring MUST add one.
 *
 * @param ctx accepted to match the contract signature and forward-compat the S16
 *   descriptor; `ctx.cwd` is NOT dereferenced in S5 (the socket path comes from
 *   `os.tmpdir()` per the item contract). Signaled with `void ctx;`.
 */
export function startBridge(ctx: ExtensionContext): void {
	stopBridge(); // idempotent teardown of any prior server (reload/new/resume/fork re-entry)
	void ctx; // ctx.cwd is reserved for the S16 BridgeDescriptor; S5 derives path from tmpdir().

	token = randomUUID().replace(/-/g, "").slice(0, 32); // 32 lowercase hex chars (PRD §12)
	socketPath = join(tmpdir(), `pi-editor-bridge-${randomUUID()}.sock`);
	server = __deps.createServer((sock) => onConnection(sock));
	server.listen(socketPath);
	// Restrictive perms (PRD §5.1/§12). libuv creates the socket FILE synchronously inside
	// listen() (verified on-disk), so chmodSync here does NOT ENOENT and yields mode 0o600.
	// Wrapped in try/catch: 0o600 is defense-in-depth; the token is the real auth boundary,
	// so a chmod hiccup must never crash session_start. Skipped on Windows (no Unix perms).
	if (process.platform !== "win32") {
		try {
			__deps.chmodSync(socketPath, 0o600);
		} catch {
			/* best-effort; do not crash */
		}
	}
	// NOTE: NO process.env.PI_NVIM_BRIDGE write here — that is P1.M3.T8.S16.
}
```

```typescript
// === extension/tests/bridge-lifecycle.test.ts (CREATE — node:test + jiti) ===
import { test } from "node:test";
import assert from "node:assert/strict";
import { statSync, existsSync } from "node:fs";
import { once } from "node:events";
import type { ExtensionContext } from "@earendil-works/pi-coding-agent";
import {
	startBridge,
	stopBridge,
	getServer,
	getSocketPath,
	getToken,
	__deps,
} from "../pi-editor-bridge.ts";

// startBridge does NOT dereference ctx in S5, so a bare cast is sufficient.
const fakeCtx = {} as ExtensionContext;

// The __deps seam defaults to the real builtins; snapshot them so mock overrides restore
// cleanly. (Plain-object property assignment is allowed — the node:net namespace is NOT
// involved, which is the whole point of the seam.)
const realCreateServer = __deps.createServer;
const realChmodSync = __deps.chmodSync;

// ============================================================================
// TEST 1 — MOCKED: honors the createServer + chmodSync(_,0o600) contract WITHOUT
// touching the filesystem / network (the frozen node:net namespace forbids direct
// mocking; the __deps seam is the sanctioned override point). Proves the wire shape.
// ============================================================================
test("startBridge (mocked): createServer + chmodSync(_,0o600) invoked, token 32-hex, getters populated", () => {
	let listenArg: string | undefined;
	let chmodCall: { path: string; mode: number } | undefined;

	// Fake server: record the listen() arg, return itself (matches `listen(): this`),
	// provide a close() no-op so stopBridge() inside startBridge's first line is safe.
	const fakeServer = {
		listening: false,
		listen(arg: string) {
			listenArg = arg;
			return fakeServer;
		},
		close() {
			/* no-op */
		},
	};
	__deps.createServer = (() => fakeServer) as unknown as typeof realCreateServer;
	__deps.chmodSync = ((path: string, mode: number) => {
		chmodCall = { path, mode };
	}) as unknown as typeof realChmodSync;

	try {
		startBridge(fakeCtx);

		// socket path shape (unique, under tmpdir, .sock extension)
		assert.match(
			listenArg ?? "",
			/pi-editor-bridge-[0-9a-f-]+\.sock$/,
			"listen() must be called with a unique pi-editor-bridge-*.sock path",
		);
		// chmod called with EXACTLY the listen path and 0o600
		assert.ok(chmodCall, "chmodSync must be invoked");
		assert.equal(chmodCall!.mode, 0o600, "chmodSync mode must be 0o600");
		assert.equal(chmodCall!.path, listenArg, "chmodSync path must equal the listen path");
		// token is exactly 32 lowercase hex chars (PRD §12)
		assert.match(
			getToken() ?? "",
			/^[0-9a-f]{32}$/,
			"token must be 32 lowercase hex chars",
		);
		// getters populated + consistent
		assert.equal(getSocketPath(), listenArg, "getSocketPath() === listen arg");
		assert.equal(getServer(), fakeServer, "getServer() === the created server");
	} finally {
		__deps.createServer = realCreateServer;
		__deps.chmodSync = realChmodSync;
		stopBridge(); // reset module singleton state for the next test
	}
});

// ============================================================================
// TEST 2 — REAL INTEGRATION: actual net.createServer + listen + chmod. Asserts the
// on-disk socket file mode is EXACTLY 0o600 and the server is listening, then that
// stopBridge unlinks the file + clears state.
// ============================================================================
test("startBridge (real): socket binds, on-disk mode 0o600, server.listening; stopBridge unlinks + clears", async () => {
	startBridge(fakeCtx);
	const srv = getServer();
	const path = getSocketPath();
	assert.ok(srv, "getServer() must be populated after startBridge");
	assert.ok(path, "getSocketPath() must be populated after startBridge");

	await once(srv!, "listening"); // listen() is async; wait for the bind to complete
	assert.equal(srv!.listening, true, "server must be listening after 'listening' event");

	// The load-bearing security assertion: 0o600 on disk (verified safe because libuv
	// creates the socket file synchronously inside listen()).
	const mode = statSync(path!).mode & 0o777;
	assert.equal(mode, 0o600, "socket file mode must be exactly 0o600");

	stopBridge();
	assert.equal(getServer(), undefined, "getServer() cleared after stopBridge");
	assert.equal(getSocketPath(), undefined, "getSocketPath() cleared after stopBridge");
	assert.equal(getToken(), undefined, "getToken() cleared after stopBridge");
	assert.equal(existsSync(path), false, "socket file must be unlinked after stopBridge");
});

// ============================================================================
// TEST 3 — IDEMPOTENCY: calling startBridge twice must close server #1, unlink its
// socket, and yield a NEW server + NEW path (no leak across repeated session_start).
// ============================================================================
test("startBridge is idempotent: second call closes server #1, unlinks its socket, yields a new server+path", async () => {
	startBridge(fakeCtx);
	const first = getServer();
	const firstPath = getSocketPath();
	assert.ok(first && firstPath);
	await once(first!, "listening");

	startBridge(fakeCtx); // restart — stopBridge() runs first inside

	assert.notEqual(getServer(), first, "second startBridge must yield a NEW server");
	assert.notEqual(getSocketPath(), firstPath, "second startBridge must yield a NEW path");
	assert.equal(
		existsSync(firstPath!),
		false,
		"first socket file must be unlinked by the stopBridge() inside the second startBridge",
	);

	await once(getServer()!, "listening");
	assert.equal(getServer()!.listening, true, "second server must be listening");
	stopBridge();
});

// ============================================================================
// TEST 4 — stopBridge idle no-op + reset: safe to call when nothing is running, and
// it leaves all getters undefined.
// ============================================================================
test("stopBridge is a safe no-op when idle and resets all state", () => {
	assert.doesNotThrow(() => stopBridge(), "stopBridge must not throw when idle");
	assert.equal(getServer(), undefined);
	assert.equal(getSocketPath(), undefined);
	assert.equal(getToken(), undefined);
});
```

### Integration Points

```yaml
NO external integration points for S5 (server is invoked only by tests; nothing is wired yet).
  - No process.env write (S16), no session_start/session_shutdown wiring (S6), no DB/config.
INTERNAL seams (the exports later tasks consume — NOT wired in S5):
  - getServer()      → S8 attaches the onConnection reader/dispatcher to the live server.
  - getToken()       → S9 hello handshake compares the client token against this.
  - getSocketPath()  → S16 BridgeDescriptor.path (JSON.stringify to process.env.PI_NVIM_BRIDGE).
  - startBridge(ctx) → S6 wires it into the session_start handler (the L101 TODO call site).
  - stopBridge()     → S6 wires it into session_shutdown; S16 adds the env-clear line.
  - __deps           → S5 tests only (production is byte-identical to direct builtin calls).
NO tsconfig change:
  - The new test matches the existing `tests/**/*.ts` glob (already in include).
  - node:* value imports type-check under the current compilerOptions (verified — research §1.3).
  - ExtensionContext is already imported (L24); no new @earendil-works/* import.
```

## Validation Loop

### Level 1: Syntax & Style (Immediate Feedback) — THE TYPE GATE

```bash
# Type-check pi-editor-bridge.ts (now with the node:* imports + __deps/server code) +
# protocol.ts + all tests via the paths-mapped dev tsconfig. This is the authoritative
# gate for S5: the node:* value imports must resolve, __deps must be properly typed, the
# getters must return Server|string|undefined, and the test's fake-server casts must
# compile. Failures are usually: a missing node:* import, a wrong type for __deps, or a
# getter return type that doesn't match the module var.
tsc --noEmit -p extension/tsconfig.json
# Expected: exit 0, NO output.

# Indentation sanity (S1/S2/S3/S4 + pi examples use TABS):
grep -nP '^    ' extension/pi-editor-bridge.ts extension/tests/bridge-lifecycle.test.ts \
  && echo "WARN: space-indent lines found" || echo "indent OK (tabs)"

# Confirm NO process.env write was added in S5 (env advertisement is S16):
grep -nE 'process\.env\.(PI_NVIM_BRIDGE|BRIDGE_ENV)' extension/pi-editor-bridge.ts \
  && echo "FAIL: S5 wrote/quoted the env var (out of scope — S16)" \
  || echo "PASS: no PI_NVIM_BRIDGE env write in S5"

# Confirm the default-export factory is UNCHANGED (the L101 TODO call site intact):
grep -n 'TODO(M2): startBridge' extension/pi-editor-bridge.ts \
  && echo "PASS: startBridge NOT wired into session_start (wiring deferred to S6)" \
  || echo "FAIL: the TODO call site is gone — did S5 wire startBridge? (should be S6)"

# Confirm NO protocol.ts import leaked in (the onConnection placeholder doesn't need it):
grep -nE 'from "\./protocol' extension/pi-editor-bridge.ts \
  && echo "FAIL: S5 imported protocol.ts (premature)" || echo "PASS: no protocol.ts import"

# Confirm state is exposed via getters, NOT export let:
grep -nE '^export let ' extension/pi-editor-bridge.ts \
  && echo "FAIL: found an 'export let' (jiti-unsafe — use getters)" \
  || echo "PASS: no 'export let' (getters only)"
```

### Level 2: Unit Tests (Component Validation) — THE CONTRACT GATE

```bash
# Zero-dependency TS test runner: Node's built-in node:test, with jiti as the TS
# loader (jiti nested under pi-coding-agent; borrow its register hook — SAME path
# S2/S3/S4 use).
JITI_REG=/home/dustin/.local/lib/node_modules/@earendil-works/pi-coding-agent/node_modules/jiti/lib/jiti-register.mjs
node --import "$JITI_REG" extension/tests/bridge-lifecycle.test.ts
# Expected: exit 0; final summary shows `pass 4` and `fail 0`.
# NOTE: jiti on Node 26 prints a harmless DEP0205 DeprecationWarning
#   ("module.register() is deprecated") to STDERR — IGNORE it; judge by exit code
#   and the `pass`/`fail` lines, not stderr cleanliness.

# Re-run S2 + S3 + S4 suites to prove S5 didn't regress them (S5 only ADDS code to
# pi-editor-bridge.ts and adds one test file; these should be unaffected):
node --import "$JITI_REG" extension/tests/provider-capture.test.ts   # S2 — expect fail 0
node --import "$JITI_REG" extension/tests/mode-guard.test.ts         # S3 — expect fail 0
node --import "$JITI_REG" extension/tests/protocol.test.ts           # S4 — expect fail 0
```

### Level 3: Integration Testing (System Validation) — THE REGRESSION GATE

```bash
# startBridge is NOT wired into the session_start handler in S5 (the L101 TODO is intact),
# so loading the extension entry point does NOT create a socket. This run therefore proves
# S5 did not REGRESS the entry point: the file still loads via jiti, the S3 TUI guard still
# suppresses the startup log in --print mode, and pi exits 0.
pi --no-extensions -e ./extension/pi-editor-bridge.ts --print "ok" 2>&1 | tee /tmp/pi-editor-bridge-s5.log

# PASS condition 1: pi exited 0.
pi --no-extensions -e ./extension/pi-editor-bridge.ts --print "ok" >/dev/null 2>&1; echo "pi exit=$?"

# PASS condition 2: NO errors during load/handler invocation.
grep -iE "error|cannot|fail|throw|unhandled|is not a function|TypeError|EADDRINUSE" /tmp/pi-editor-bridge-s5.log \
  && echo "FAIL: error present" || echo "PASS: no errors"

# PASS condition 3: the startup log is still ABSENT in print mode (S3 guard intact; S5 must
# not have touched the default-export factory / session_start handler).
grep -c "pi-editor-bridge: session_start (reason=startup" /tmp/pi-editor-bridge-s5.log | grep -q '^0$' \
  && echo "PASS: startup log suppressed in print mode (S3 guard intact)" \
  || echo "FAIL: startup log appeared — S5 may have touched the session_start handler"
# Expected: all three PASS; pi prints "ok" output and exits 0.
```

### Level 4: Creative & Domain-Specific Validation

```bash
# Confirm NO socket file leaked into tmpdir across the test run (every test cleans up via
# stopBridge()). Run before+after snapshots of pi-editor-bridge-*.sock:
ls -1 "${TMPDIR:-/tmp}"/pi-editor-bridge-*.sock 2>/dev/null | wc -l   # before: 0 (or note baseline)
node --import /home/dustin/.local/lib/node_modules/@earendil-works/pi-coding-agent/node_modules/jiti/lib/jiti-register.mjs \
  extension/tests/bridge-lifecycle.test.ts >/dev/null 2>&1
ls -1 "${TMPDIR:-/tmp}"/pi-editor-bridge-*.sock 2>/dev/null | wc -l   # after: must equal the before count (0 net leak)
# Expected: identical counts (no orphaned socket files).

# Cross-check the token entropy claim with a quick histogram (each call must be unique +
# 32-hex). Borrow the real startBridge via a throwaway probe:
node --import /home/dustin/.local/lib/node_modules/@earendil-works/pi-coding-agent/node_modules/jiti/lib/jiti-register.mjs \
  -e 'import("./extension/pi-editor-bridge.ts").then(({ startBridge, stopBridge, getToken }) => { const seen = new Set(); for (let i=0;i<50;i++){ startBridge({}); const t = getToken(); if (!/^[0-9a-f]{32}$/.test(t)) throw new Error("bad token: "+t); if (seen.has(t)) throw new Error("DUPLICATE token"); seen.add(t); stopBridge(); } console.log("PASS: 50/50 unique 32-hex tokens"); });'
# Expected: PASS: 50/50 unique 32-hex tokens.

# Confirm the module is importable standalone via jiti with NO node_modules at the repo top
# level (the critical runtime invariant — builtins-only, zero npm deps per PRD §6.7):
node --import /home/dustin/.local/lib/node_modules/@earendil-works/pi-coding-agent/node_modules/jiti/lib/jiti-register.mjs \
  -e 'import("./extension/pi-editor-bridge.ts").then(m => { console.log("exports include:", ["startBridge","stopBridge","getServer","getSocketPath","getToken","__deps","captureProvider","getProvider"].filter(k => typeof m[k]==="function"||(k==="__deps"&&m[k])).join(", ")); });'
# Expected: all 8 names present (startBridge/stopBridge/getServer/getSocketPath/getToken/__deps/captureProvider/getProvider).
```

## Final Validation Checklist

### Technical Validation

- [ ] Level 1 (TYPE GATE): `tsc --noEmit -p extension/tsconfig.json` → exit 0, no output.
- [ ] Level 2 (CONTRACT GATE): `node --import <jiti-register> extension/tests/bridge-lifecycle.test.ts`
      → exit 0, `fail 0` (`pass 4`); S2 + S3 + S4 suites still green.
- [ ] Level 3 (REGRESSION GATE): `pi --no-extensions -e ./extension/pi-editor-bridge.ts --print "ok"`
      exits 0 with NO error lines AND the startup-log line ABSENT in print mode (S3 intact).
- [ ] Level 4: no socket leak in tmpdir across the test run; 50/50 unique 32-hex tokens;
      all 8 expected exports present on standalone import.

### Feature Validation

- [ ] `startBridge(ctx)` exists; `getServer()`/`getSocketPath()`/`getToken()` populated after a call.
- [ ] `getToken()` matches `/^[0-9a-f]{32}$/`; `getSocketPath()` matches
      `/pi-editor-bridge-[0-9a-f-]+\.sock$/` under `os.tmpdir()`.
- [ ] `startBridge` calls `stopBridge()` first (idempotent re-entry); a second `startBridge`
      closes server #1, unlinks its socket, yields a new server+path.
- [ ] Real `startBridge` → after `'listening'`, on-disk `statSync(path).mode & 0o777 === 0o600`
      and `server.listening === true`; `stopBridge()` → file unlinked, getters undefined.
- [ ] `chmodSync` is try/catch-wrapped + `process.platform !== "win32"`-guarded.
- [ ] `stopBridge()` is a safe no-op when idle.
- [ ] `onConnection(_sock)` is a no-op placeholder with S8/S9 TODOs.
- [ ] `__deps = { createServer, chmodSync }` exported + mutable; mocked test overrides it.
- [ ] `ctx` accepted but `ctx.cwd` NOT dereferenced (`void ctx;`); NO `process.env` write;
      default-export factory UNCHANGED (L101 TODO intact); NO `protocol.ts` import.

### Code Quality Validation

- [ ] Follows existing codebase patterns (getters over `export let` like `getProvider()`;
      node:test+jiti test conventions like mode-guard/provider-capture; TAB indentation;
      `import type` discipline; Mode-A JSDoc with STATUS markers).
- [ ] File placement matches the desired codebase tree (additions inside
      `pi-editor-bridge.ts`; new test under `extension/tests/`).
- [ ] Anti-patterns avoided (no frozen-namespace mocking; no `export let`; no chmod-before-
      listen; no env write in S5; no premature session_start wiring; no protocol.ts import).
- [ ] Dependencies: Node builtins only (`net`/`crypto`/`fs`/`os`/`path`); zero npm runtime
      deps (PRD §6.7); no tsconfig change.

### Documentation & Deployment

- [ ] Every new export has Mode-A JSDoc explaining its role + STATUS marker + forward refs
      (S6 wiring, S8 onConnection, S9 handshake, S16 env advertisement).
- [ ] The stopBridge↔S6 and startBridge↔S16/S6 cross-task relationships are documented in
      JSDoc so sibling-task implementers don't blindly recreate or double-implement.
- [ ] No new env vars introduced (env advertisement is S16, documented as deferred).

---

## Anti-Patterns to Avoid

- ❌ Don't mock `node:net` directly — the namespace is frozen (TypeError). Use the `__deps` seam.
- ❌ Don't expose server state via `export let` — jiti doesn't live-bind it cross-module.
      Use getters (`getServer/getSocketPath/getToken`), matching `getProvider()`.
- ❌ Don't chmod BEFORE `listen()` (path doesn't exist → ENOENT). chmod-after-listen is safe
      (libuv creates the file synchronously inside listen()).
- ❌ Don't make `startBridge` async — keep it sync void so the idempotent call site and the
      S6 wiring stay simple; await `'listening'` in tests only.
- ❌ Don't write `process.env.PI_NVIM_BRIDGE` in S5 (env advertisement is S16). Build the
      server+token+path; S16 extends startBridge to also advertise.
- ❌ Don't wire `startBridge` into the `session_start` handler in S5 (S6's job — wiring now
      would fire a real listen/chmod inside `mode-guard.test.ts`).
- ❌ Don't dereference `ctx.cwd` in S5 (reserved for the S16 `BridgeDescriptor`); derive the
      socket path from `os.tmpdir()`.
- ❌ Don't add a `server.on('error', ...)` handler in S5 (out of scope; flag it in JSDoc for
      S6 — S5's tests use unique UUID paths so no 'error' arises).
- ❌ Don't touch `protocol.ts` / tsconfig / the default-export factory / captureProvider /
      getProvider — S5 is purely additive in one file + one test.
- ❌ Don't swallow chmod failures silently without the try/catch (a chmod hiccup must not
      crash session_start) — but DO swallow them (0o600 is defense-in-depth; token is real).
- ❌ Don't recreate `stopBridge` in S6 — S5 ships it; S6 REUSES it and adds the env-clear.
