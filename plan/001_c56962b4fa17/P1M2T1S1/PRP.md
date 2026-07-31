---
name: "P1.M2.T3.S5 — startBridge(): create Unix socket server, generate token, chmod 0o600"
description: |
  ADD to `extension/pi-editor-bridge.ts` a `startBridge(ctx: ExtensionContext)`
  function that (a) calls a new minimal `stopBridge()` first for idempotency,
  (b) generates a 32-hex-char token via `randomUUID().replace(/-/g,"").slice(0,32)`,
  (c) computes `socketPath = join(tmpdir(), "pi-editor-bridge-" + randomUUID() + ".sock")`,
  (d) creates the server with `createServer(onConnection)` and binds it with
  `server.listen(socketPath)`, (e) `chmodSync(socketPath, 0o600)` on non-Windows
  (best-effort, try/catch-wrapped). The three results are stored in module-level
  `let server/socketPath/token` (observed by tests via new getters, mirroring the
  existing `getProvider()` pattern). `onConnection` is a deliberate no-op
  placeholder (S8 wires it). Deliverable ALSO: a `__deps` test seam
  (`{createServer, chmodSync}` defaulting to the real builtins) — REQUIRED because
  `node:net`'s ESM namespace is frozen so `mock.method(net,"createServer")` throws
  (verified) — and a `node:test`+jiti suite `extension/tests/bridge-lifecycle.test.ts`
  with BOTH a mocked test (honors the item MOCKING requirement: override
  `__deps.createServer`, assert `listen` called with the generated path + chmod
  `0o600` + 32-hex token) AND a real integration test (assert actual `listening`,
  on-disk `0o600` perms, socket unlink on stop, idempotent restart). NARROW: NO
  env-var write (S16), NO session_start/session_shutdown wiring (deferred to S6),
  NO JSONL framing (S7), NO onConnection logic (S8), NO handshake (S9), NO
  protocol.ts import, NO tsconfig change. stopBridge is introduced HERE (minimal:
  close+unlink+reset 3 vars, NO env clear) because startBridge's idempotency
  contract REQUIRES it; flag for S6 to reuse rather than recreate.
---

## Goal

**Feature Goal**: Add the Unix-domain-socket server bootstrap to the
pi-editor-bridge extension so that, when `startBridge(ctx)` is called (on
`session_start`), pi (a) closes any prior server/socket idempotently, (b) mints a
fresh 32-hex-char session token, (c) binds a fresh `pi-editor-bridge-<uuid>.sock`
under `os.tmpdir()`, and (d) chmod's that socket to `0o600`. The server, socket
path, and token live in module-level state (read by the future S16 env-var
advertisement and S8 connection handler). This is the first half of the M2
"Socket server lifecycle" (T3) — the start half; the stop half (S6) and the
lifecycle wiring into `session_start`/`session_shutdown` follow.

**Deliverable** (all changes in `extension/`):
1. **MODIFY** `extension/pi-editor-bridge.ts` — add (no removals, no handler-body
   edits):
   - Node-builtin imports: `createServer`, `type Server`, `type Socket` from
     `node:net`; `randomUUID` from `node:crypto`; `chmodSync`, `rmSync` from
     `node:fs`; `tmpdir` from `node:os`; `join` from `node:path`.
   - Module-level state: `let server: Server | undefined; let socketPath: string |
     undefined; let token: string | undefined;`.
   - `export const __deps = { createServer, chmodSync };` (test seam — see Why).
   - `function onConnection(_sock: Socket): void {}` (no-op placeholder; TODOs for S8/S9).
   - `export function startBridge(ctx: ExtensionContext): void` — the full
     bootstrap (stopBridge-first idempotency → token → socketPath →
     createServer+listen → chmod 0o600 non-Windows).
   - `export function stopBridge(): void` — minimal idempotent teardown (close +
     unlink(force) + reset 3 vars; **no** env-var clear — nothing written yet).
   - `export function getServer()/getSocketPath()/getToken()` — test/internal
     accessors (mirror the existing `getProvider()`).
   - Mode-A JSDoc on `startBridge` (socket lifecycle, token generation, permission
     model) and on every new export (item DOCS requirement).
2. **CREATE** `extension/tests/bridge-lifecycle.test.ts` — `node:test` + jiti
   suite (imports from `../pi-editor-bridge.ts`): mocked test (override
   `__deps.createServer`/`chmodSync`, assert `listen` arg + chmod `0o600` + token
   format), real integration test (assert `listening` + on-disk `0o600` + unlink +
   idempotent restart), stopBridge no-op/reset test.
3. **NO CHANGE** to `extension/tsconfig.json` (`pi-editor-bridge.ts` already in
   `include`; new test covered by the `tests/**/*.ts` glob) — this keeps S5
   conflict-free with the in-parallel P1.M1.T2.S1 task (which appends
   `"protocol.ts"` to `include`).

**Success Definition**:
- `tsc --noEmit -p extension/tsconfig.json` → exit 0, no output (node-builtin
  imports resolve under the current `"types": []` + `moduleResolution: "Bundler"`).
- `node --import <pi>/node_modules/jiti/lib/jiti-register.mjs extension/tests/bridge-lifecycle.test.ts`
  → exit 0, `fail` 0, `pass` ≥ 3.
- `pi --no-extensions -e ./extension/pi-editor-bridge.ts --print "ok"` → exit 0,
  no error lines (S5 adds functions but the factory still never calls them in
  print mode; mode guard short-circuits — regression guard).
- Existing tests still green: `extension/tests/{mode-guard,provider-capture}.test.ts`.
- A real `0o600` Unix socket is bound under `os.tmpdir()` while the server runs,
  and unlinked after `stopBridge()`.

## User Persona (if applicable)

**Target User**: The bridge-extension author + every downstream M2 task. This is
developer infrastructure: the socket lifecycle bootstrap that S8 (connection
handling), S9 (handshake), S11–S14 (RPC handlers), and S16 (env advertisement)
build on.

**Use Case**: On each `session_start`, pi calls `startBridge(ctx)` (wiring lands
in S6). startBridge mints a token + binds the socket so a Neovim `$EDITOR`
process can `vim.uv.new_pipe():connect(socketPath)` and present the token in
`hello`. The token + path are later JSON-serialized to
`process.env.PI_NVIM_BRIDGE` (S16) for the editor to discover.

**Pain Points Addressed**: Without an idempotent startBridge, repeated
`session_start` events (reload/new/resume/fork) would leak servers + socket
files. Without the `0o600` chmod, any local user could `connect()` the socket
(the token still stops them, but 0o600 is the documented defense-in-depth).

## Why

- **The socket is the transport (PRD §5.1).** Every completion request flows over
  this Unix domain socket as strict JSONL. startBridge is what brings it into
  existence for the session.
- **The token is the real auth boundary (PRD §12).** 32 random hex chars
  delivered via `process.env` (process-local, not on disk), validated in `hello`
  (S9). startBridge is where the token is minted. `0o600` on the socket is
  defense-in-depth on top of it.
- **Idempotency is non-negotiable under pi's lifecycle churn.** pi fires
  `session_start` on startup AND on reload/new/resume/fork (PRD §6.2), and
  `session_shutdown` reasons include session replacement, not only quit. Per the
  pi extension docs ("Long-lived resources and shutdown"), background resources
  (sockets) MUST start in `session_start` (never the factory body) and be closed
  idempotently on `session_shutdown`. startBridge's "stopBridge-first" makes
  repeated starts safe.
- **A `__deps` seam is REQUIRED to honor the item MOCKING contract.** Empirically,
  `node:net`'s ESM namespace is frozen — `mock.method(net, "createServer")`
  throws `Cannot redefine property: createServer`. A small mutable `{createServer,
  chmodSync}` object (defaulting to the real builtins) is the clean, standard way
  to make `createServer` mockable AND lets tests assert chmod is called with
  exactly `0o600`. Production behavior is unchanged (the seam delegates to the
  real builtins by default).
- **stopBridge is introduced here as a hard dependency.** startBridge's contract
  requires calling `stopBridge()` first. Rather than ship an untestable startBridge
  that references a not-yet-existing stopBridge, S5 includes the minimal working
  stopBridge (close+unlink+reset; NO env clear — S5 writes no env var). This also
  front-runs the core of plan task S6; the PRP flags it so S6 reuses it.

## What

New code in `extension/pi-editor-bridge.ts` (additive): node-builtin imports,
module-level `server`/`socketPath`/`token` state, the `__deps` test seam, a no-op
`onConnection` placeholder, `startBridge(ctx)`, a minimal `stopBridge()`, three
getter accessors, and Mode-A JSDoc throughout. Plus a `node:test`+jiti suite
covering the mocked path, a real integration path, idempotency, and stopBridge
reset. NO edits to the existing `session_start`/`session_shutdown` handler bodies
(wiring is deferred — see Context §"session_start wiring is DEFERRED").

### Success Criteria

- [ ] `extension/pi-editor-bridge.ts` exports `startBridge(ctx: ExtensionContext): void`,
      `stopBridge(): void`, `getServer()`, `getSocketPath()`, `getToken()`, and
      `const __deps` — and keeps the existing `captureProvider`/`getProvider` +
      default-export factory byte-for-byte intact (no handler-body edits).
- [ ] `startBridge` calls `stopBridge()` FIRST (idempotency), then sets
      `token = randomUUID().replace(/-/g, "").slice(0, 32)`,
      `socketPath = join(tmpdir(), "pi-editor-bridge-" + randomUUID() + ".sock")`,
      `server = __deps.createServer(onConnection)`, `server.listen(socketPath)`,
      and on non-Windows `__deps.chmodSync(socketPath, 0o600)` (try/catch-wrapped).
- [ ] `token` is exactly 32 lowercase hex chars (assert `/^[0-9a-f]{32}$/`).
- [ ] `socketPath` matches `/^<tmpdir>\/pi-editor-bridge-[0-9a-f-]{36}\.sock$/`
      (i.e. ends with `pi-editor-bridge-<uuid>.sock`).
- [ ] `chmod` runs ONLY on non-Windows (`process.platform !== "win32"`) and is
      best-effort (wrapped in try/catch; a chmod failure does not throw out of
      startBridge).
- [ ] `stopBridge()` is idempotent and safe when nothing is running: `server?.close()`
      guarded, `rmSync(socketPath, { force: true })` guarded, then resets
      `server`/`socketPath`/`token` to `undefined`. It does NOT clear
      `process.env.PI_NVIM_BRIDGE` (S5 writes none — that is S16).
- [ ] `__deps = { createServer, chmodSync }` defaults to the real node builtins;
      overriding `__deps.createServer`/`__deps.chmodSync` in tests is observable
      (plain mutable object).
- [ ] Mode-A JSDoc on `startBridge` explicitly documents the **socket lifecycle**,
      **token generation** (32 hex, real auth boundary, never log), and
      **permission model** (0o600 defense-in-depth, non-Windows, best-effort).
- [ ] `onConnection(_sock)` is a no-op with TODOs for S8 (JSONL reader+dispatcher)
      and S9 (handshake gate).
- [ ] `extension/tests/bridge-lifecycle.test.ts` passes: mocked test asserts
      `listen` called with a path matching the pattern + `chmodSync` called with
      `0o600` + token is 32 hex; real test asserts `server.listening`, on-disk
      `statSync(path).mode & 0o777 === 0o600`, socket unlinked after stop;
      idempotency test asserts a second start closes+unlinks the first.
- [ ] `tsc --noEmit -p extension/tsconfig.json` → exit 0, no output.
- [ ] `pi --no-extensions -e ./extension/pi-editor-bridge.ts --print "ok"` →
      exit 0, no error lines (regression guard).
- [ ] NO env-var write (S16), NO session_start/session_shutdown wiring (S6), NO
      JSONL/framing code (S7), NO onConnection logic (S8), NO protocol.ts import,
      NO tsconfig change.

## All Needed Context

### Context Completeness Check

_Pass test_: An agent who has never seen this repo, given this PRP (which embeds
the exact import lines, the full transcription-ready `startBridge`/`stopBridge`/
getter/`__deps` skeletons, the complete test file, the verified validation
commands, and every empirically-confirmed gotcha), can (1) add the code block to
`pi-editor-bridge.ts`, (2) create the test file, and (3) run the three validation
commands to green — with every symbol name, file path, and gotcha listed here.

### Documentation & References

```yaml
# MUST READ — the authoritative server-lifecycle skeleton (transcribe startBridge/stopBridge from this)
- docfile: PRD.md
  why: §6.4 is the reference implementation for startBridge/stopBridge; §5.1 names the socket path + 0o600; §12 is the security model
  section: "§6.4 (token = randomUUID().replace(/-/g,'').slice(0,32); socketPath = join(tmpdir(),'pi-editor-bridge-'+randomUUID()+'.sock'); server.listen(path); chmod(path,0o600) non-Windows); §5.1 (Unix socket, 0o600, token is real auth boundary); §12 (0600 perms + 32-byte token handshake; token via process.env; never log token); §6.2 (session_start/session_shutdown churn → idempotent start/stop)"
  critical: |
    S5 DEVIATES from §6.4 in exactly THREE deliberate, documented ways:
      (1) startBridge signature is SINGLE-ARG `startBridge(ctx)` (item contract
          INPUT), not `startBridge(ctx, cwd)` — cwd is derived from ctx inside S16.
      (2) chmod is try/catch-wrapped (best-effort) so a chmod hiccup cannot crash
          session_start; 0o600 is defense-in-depth, token is the real boundary.
      (3) stopBridge OMITS `delete process.env[BRIDGE_ENV]` because S5 writes NO
          env var — S16 adds both the write (startBridge) and the delete (stopBridge).
    Everything else matches §6.4 verbatim.

# MUST READ — the pi extension lifecycle rule that shapes WHERE startBridge runs
- file: /home/dustin/.local/lib/node_modules/@earendil-works/pi-coding-agent/docs/extensions.md
  why: "Long-lived resources and shutdown" — background resources (sockets) MUST start in session_start, NOT the factory body; idempotent session_shutdown cleanup
  section: '"Long-lived resources and shutdown" → "Do not start background resources such as processes, sockets, file watchers, or timers from the factory. Defer background resource startup until session_start … Register an idempotent session_shutdown handler to close any session-scoped resources you start."'
  critical: |
    This is WHY startBridge is a function called from session_start (not run in
    the factory body). S5 only DEFINES startBridge; the actual session_start CALL
    is wired in S6 (see "session_start wiring is DEFERRED" below).

# MUST READ — the existing file S5 modifies (the post-S3 baseline)
- file: extension/pi-editor-bridge.ts
  why: S5 ADDS to this file. It already has `import type { ExtensionContext }` (reused for startBridge's param), `let liveProvider` + `getProvider()` (the getter pattern to mirror), `captureProvider`, and the default-export factory with the TUI mode guard. S5 must NOT edit the factory's session_start/session_shutdown handler bodies.
  section: "imports (top), `let liveProvider` + `getProvider()` (the getter-accessor precedent), `captureProvider`, `export default function (pi)` (session_start TUI guard + TODO line `// TODO(M2): startBridge(ctx, ctx.cwd)` — DO NOT flip this to a call in S5)"
  critical: |
    Insert the new code as a contiguous block AFTER `getProvider()` and BEFORE
    `export default function (pi)`. Leave the factory + handlers byte-for-byte
    unchanged. The TODO comment `startBridge(ctx, ctx.cwd)` is left stale on
    purpose (single-arg signature); the wiring task (S6) corrects it.

# MUST READ — node-builtin type declarations (confirm Server/Socket/createServer types)
- file: /home/dustin/.local/lib/node_modules/@earendil-works/pi-coding-agent/node_modules/@types/node/net.d.ts
  why: confirms `createServer`, `class Server extends EventEmitter` (net.d.ts:587), and `Socket` are importable from "node:net" — type-checks under the current tsconfig (verified)
  section: "createServer(connectionListener?) : Server; class Server extends EventEmitter { listen(path, cb?): Server; close(cb?): Server; listening: boolean; }"
  critical: |
    VERIFIED: `import { createServer, type Server, type Socket } from "node:net"`
    passes `tsc --noEmit` under `"types": []` + `moduleResolution: "Bundler"`
    (module declarations are NOT excluded by the `types` option). NO tsconfig
    change needed for node imports.

# SUPPORTING — pre-researched architecture (project-local)
- docfile: plan/001_c56962b4fa17/architecture/external_deps.md
  why: §5 enumerates the exact node builtins used (net/crypto/fs/os/path); §4 confirms the extension factory/event pattern
  section: "§5 Node.js Builtins Used (createServer, randomUUID, chmodSync/rmSync, tmpdir, join); §4 pi Extension API (session_start/session_shutdown)"
- docfile: plan/001_c56962b4fa17/architecture/research-pi-extension-api.md
  why: §1 confirms ctx.cwd + ctx.mode; "Background resources / sockets guidance" re-states the session_start-not-factory rule; Residual Risk #4 (session_shutdown reasons include session replacement → idempotent cleanup)
  section: "§1 ExtensionContext (cwd, mode); Background resources guidance; Residual Risks #3 (factory must not open sockets) + #4 (idempotent session_shutdown)"

# SUPPORTING — the previous task's PRP (in-parallel; S5 must not collide with it)
- docfile: plan/001_c56962b4fa17/P1M1T2S1/PRP.md
  why: P1.M1.T2.S1 creates extension/protocol.ts (types-only) and appends "protocol.ts" to tsconfig include. S5 does NOT touch protocol.ts or tsconfig → zero conflict. S5's onConnection placeholder does not import protocol types (S8 will).
  section: "Deliverable (creates protocol.ts + edits tsconfig include only; does NOT touch pi-editor-bridge.ts)"
  critical: |
    S5 and S1 run in parallel. The ONLY shared resource they could both touch is
    extension/tsconfig.json. S5 does NOT edit tsconfig (pi-editor-bridge.ts is
    already in include; the new test is covered by tests/**/*.ts). → No collision.

# SUPPORTING — local research notes for S5 (every claim re-verified empirically)
- docfile: plan/001_c56962b4fa17/P1M2T1S1/research/notes.md
  why: the frozen-namespace finding (→ __deps seam), the jiti-no-live-binding finding (→ getters), verified validation commands, scope decisions, cross-task interface notes
```

### Current Codebase tree (post P1.M1.T1.S1–S3; S1/S2 protocol.ts may land in parallel)

```bash
extension/
├── pi-editor-bridge.ts   # (S1+S2+S3) imports pi types; liveProvider + getProvider() + captureProvider(); default-export factory with session_start (TUI guard + log + captureProvider; TODO(M2): startBridge) + session_shutdown (no-op); JSDoc header
├── tsconfig.json         # (S1+S2) dev-only; paths map pi-coding-agent + pi-tui; include = ["pi-editor-bridge.ts","tests/**/*.ts"]  (S1 may append "protocol.ts" in parallel — S5 does not touch this)
└── tests/
    ├── provider-capture.test.ts   # (S2) node:test — captureProvider/getProvider (shared module singleton; sequential)
    └── mode-guard.test.ts         # (S3) node:test — session_start TUI guard (invokes the handler directly)
# (plan/ holds planning artifacts only — no other source code)
```

### Desired Codebase tree with files to be added/modified

```bash
extension/
├── pi-editor-bridge.ts            # (MODIFY — additive) += node-builtin imports, server/socketPath/token state, __deps seam, onConnection placeholder, startBridge(), stopBridge(), getServer()/getSocketPath()/getToken(), Mode-A JSDoc. Handlers UNCHANGED.
├── tsconfig.json                  # (UNCHANGED — S5 does not touch tsconfig; zero conflict with in-parallel S1)
└── tests/
    ├── provider-capture.test.ts   # (UNCHANGED — S2)
    ├── mode-guard.test.ts         # (UNCHANGED — S3)
    └── bridge-lifecycle.test.ts   # (CREATE) node:test + jiti — mocked startBridge (via __deps), real integration (listening + 0o600 + unlink), idempotency, stopBridge reset
```

**File responsibilities**
- `extension/pi-editor-bridge.ts` — gains the socket-server bootstrap. The
  `startBridge`/`stopBridge` pair is the idempotent lifecycle core; `__deps` is
  the mock seam; getters expose state to tests (and later to S16 for the env
  descriptor). Co-located with `liveProvider`/`getProvider` so future RPC handlers
  (S8/S11–S14) reach both the server and the provider without cross-module cycles.
- `extension/tests/bridge-lifecycle.test.ts` — proves startBridge mints the token,
  binds a real `0o600` socket, is idempotent across repeated starts, and that
  stopBridge unlinks + resets. Mocked half satisfies the item MOCKING contract
  (verify `listen` arg + chmod `0o600`); integration half proves real behavior.

### Known Gotchas of our codebase & Library Quirks

```typescript
// CRITICAL: node:net's ESM namespace is FROZEN. `mock.method(net, "createServer")`
//   throws "Cannot redefine property: createServer" (verified, Node 26). You
//   CANNOT mock node:net via its namespace. The item MOCKING contract ("mock
//   net.createServer") is satisfied by the `__deps` plain-object seam: tests do
//   `__deps.createServer = fakeFn` (plain object → assignment allowed). Do NOT
//   try `mock.method(net, ...)` — it will throw.

// CRITICAL: jiti does NOT implement ESM live-binding reassignment across modules.
//   `export let server` mutated inside the module is NOT observed by a test that
//   imported `server` (verified — the test keeps seeing the initial value).
//   => Expose module state to tests via GETTER FUNCTIONS (getServer/getSocketPath/
//   getToken), exactly like the existing getProvider(). Do NOT use `export let`.

// CRITICAL: chmod MUST run AFTER server.listen(socketPath), never before. The
//   Unix-domain socket file is created synchronously by listen() (libuv binds
//   before returning — verified: statSync right after listen sees the file), so
//   chmodSync(socketPath, 0o600) immediately after listen succeeds. Reversing the
//   order → ENOENT.

// CRITICAL: startBridge MUST call stopBridge() FIRST (idempotency). session_start
//   fires repeatedly (reload/new/resume/fork). Without stop-first, a second
//   startBridge leaks the first server + socket file. stopBridge is therefore
//   introduced in THIS task (S5) even though plan-task S6 nominally owns it — S6
//   should REUSE this stopBridge, not recreate it.

// CRITICAL: S5's stopBridge must NOT `delete process.env.PI_NVIM_BRIDGE`. S5
//   writes no env var (S16 does). Adding the delete now would be dead code that
//   misleads; S16 adds BOTH the write (startBridge) and the delete (stopBridge).

// CRITICAL: chmod is non-Windows-only (`process.platform !== "win32"`). Wrap in
//   try/catch (best-effort) so a transient chmod failure cannot throw out of
//   startBridge and crash session_start. Rationale: 0o600 is defense-in-depth;
//   the token is the real auth boundary (PRD §12). The mock test still observes
//   the call (the seam records it before the try).

// CRITICAL: do NOT flip the `// TODO(M2): startBridge(ctx, ctx.cwd)` comment in
//   the session_start handler into a real call in S5. The existing mode-guard.test.ts
//   (S3) invokes that handler directly in TUI mode; wiring startBridge there would
//   trigger a real net.createServer + listen + chmod during that unit test. The
//   wiring lands in S6 (with session_shutdown) atomically. S5 tests startBridge by
//   calling it directly.

// CRITICAL: do NOT edit extension/tsconfig.json in S5. pi-editor-bridge.ts is
//   already in `include` and the new test is covered by `tests/**/*.ts`. Editing
//   tsconfig would risk colliding with the in-parallel P1.M1.T2.S1 task (which
//   appends "protocol.ts" to include). node-builtin imports type-check fine under
//   the current config (verified).

// CRITICAL (test cast): when overriding __deps.createServer with a fake, cast
//   through `unknown`: `(() => fakeServer) as unknown as typeof __deps.createServer`.
//   A direct cast FAILS tsc (TS2352) because the minimal fake object is missing
//   the real `net.Server` members (address/getConnections/ref/unref/listening/…).
//   The chmod override cast is fine as-is (params are contravariant: accepting
//   `unknown` is assignable to accepting `PathLike`/`Mode`).

// STYLE: TABS for indentation (match pi-editor-bridge.ts + pi examples). Mode-A
//   JSDoc on startBridge (socket lifecycle / token generation / permission model)
//   and on every new export (item DOCS requirement). Never log the token (§12).

// SCOPE: NO env-var write (S16), NO session_start/session_shutdown wiring (S6),
//   NO JSONL framing (S7), NO onConnection logic (S8), NO handshake (S9), NO
//   protocol.ts import, NO tsconfig change. onConnection is a no-op placeholder.
```

## Implementation Blueprint

### Data models and structure

No new types (protocol.ts, in-parallel S1, owns the wire types). S5 uses:
- `Server`, `Socket` from `node:net` (type imports only).
- Module-level singleton state: `let server: Server | undefined`, `let socketPath:
  string | undefined`, `let token: string | undefined`.
- The `__deps` seam object: `{ createServer: typeof createServer; chmodSync:
  typeof chmodSync }`.

### Implementation Tasks (ordered by dependencies)

```yaml
Task 1: MODIFY extension/pi-editor-bridge.ts — ADD node-builtin imports
  - APPEND to the existing import block (top of file):
      import { createServer, type Server, type Socket } from "node:net";
      import { randomUUID } from "node:crypto";
      import { chmodSync, rmSync } from "node:fs";
      import { tmpdir } from "node:os";
      import { join } from "node:path";
  - VERIFY (after Task 5): `tsc --noEmit -p extension/tsconfig.json` exit 0 —
      these resolve under "types":[] + Bundler moduleResolution (verified).
  - DO NOT remove or reorder the existing `import type { AutocompleteProvider }`
      / pi-coding-agent imports.

Task 2: MODIFY extension/pi-editor-bridge.ts — ADD module state + __deps seam
  - INSERT a contiguous block AFTER the existing `getProvider()` function and
      BEFORE `export default function (pi: ExtensionAPI)`.
  - ADD: `let server: Server | undefined;` `let socketPath: string | undefined;`
      `let token: string | undefined;`
  - ADD: `export const __deps = { createServer, chmodSync };` with JSDoc noting
      the frozen-namespace rationale (see Implementation Patterns).
  - NAMING: module-level `let` (private — NOT exported; tests read via getters).

Task 3: MODIFY extension/pi-editor-bridge.ts — ADD onConnection placeholder + startBridge + stopBridge + getters
  - TRANSCRIBE the functions from "Implementation Patterns & Key Details" below
      verbatim (onConnection no-op; startBridge with stop-first idempotency →
      token → socketPath → createServer+listen → chmod 0o600; minimal stopBridge;
      getServer/getSocketPath/getToken).
  - ADD Mode-A JSDoc to EACH (item DOCS requirement): startBridge must document
      socket lifecycle / token generation / permission model explicitly.
  - NAMING: `startBridge`, `stopBridge`, `onConnection`, `getServer`,
      `getSocketPath`, `getToken`, `__deps` — all `export`ed EXCEPT `onConnection`
      (internal) and the three state `let`s (private).
  - PRESERVE: the existing `captureProvider`, `getProvider`, `liveProvider`, and
      the entire default-export factory (handlers) — UNCHANGED.

Task 4: CREATE extension/tests/bridge-lifecycle.test.ts
  - IMPLEMENT: node:test + node:assert/strict suite (transcribe from
      "Implementation Patterns & Key Details" test skeleton).
  - IMPORTS: `import { test } from "node:test"; import assert from
      "node:assert/strict"; import { once } from "node:events"; import { statSync,
      existsSync } from "node:fs"; import { startBridge, stopBridge, getServer,
      getSocketPath, getToken, __deps } from "../pi-editor-bridge.ts"; import type
      { ExtensionContext } from "@earendil-works/pi-coding-agent";`
  - TESTS: (1) mocked startBridge via __deps override; (2) real integration
      (listening + 0o600 + token + unlink); (3) idempotent restart; (4) stopBridge
      no-op + reset. Each test calls stopBridge() in a finally to avoid leaking
      sockets in /tmp.
  - CONCURRENCY: default SEQUENTIAL (shared module singleton); do NOT enable
      concurrency. Document this in a top-of-file comment (mirror
      provider-capture.test.ts).
  - PLACEMENT: extension/tests/ (alongside S2/S3 tests).

Task 5: VALIDATE — run the three commands; fix until all green
  - RUN (Level 1): `tsc --noEmit -p extension/tsconfig.json` (expect exit 0)
  - RUN (Level 2): `node --import /home/dustin/.local/lib/node_modules/@earendil-works/pi-coding-agent/node_modules/jiti/lib/jiti-register.mjs extension/tests/bridge-lifecycle.test.ts` (expect exit 0, fail 0, pass ≥ 3)
  - RUN (Level 3 regression): `pi --no-extensions -e ./extension/pi-editor-bridge.ts --print "ok" 2>&1 | grep -iE "error|cannot|fail|throw|TypeError"` (expect NO match)
  - RUN (Level 3 regression): re-run mode-guard + provider-capture tests → still pass.
```

### Implementation Patterns & Key Details

```typescript
// ============================================================================
// INSERT THIS ENTIRE BLOCK INTO extension/pi-editor-bridge.ts
// AFTER the existing getProvider() function and BEFORE `export default function`.
// (ExtensionContext is already imported at the top of the file — reuse it.)
// ============================================================================

// ---- node builtins (PRD §6.7: no npm runtime deps; Node core only) ---------
import { createServer, type Server, type Socket } from "node:net";
import { randomUUID } from "node:crypto";
import { chmodSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

// ---- bridge session state (module-level singletons) -----------------------
/**
 * The listening Unix-domain-socket server. Populated by {@link startBridge},
 * cleared by {@link stopBridge}. `undefined` while the bridge is stopped.
 */
let server: Server | undefined;

/**
 * Absolute path of the bound socket
 * (`<tmpdir>/pi-editor-bridge-<uuid>.sock`). Populated by {@link startBridge},
 * cleared by {@link stopBridge}. The future S16 advertisement JSON-serializes
 * this into `process.env.PI_NVIM_BRIDGE.path`.
 */
let socketPath: string | undefined;

/**
 * The 32-hex-char session auth token (the REAL auth boundary — PRD §12).
 * Populated by {@link startBridge}, cleared by {@link stopBridge}. NEVER log this.
 * The future S16 advertisement carries it in `process.env.PI_NVIM_BRIDGE.token`.
 */
let token: string | undefined;

/**
 * Test seam for the two node builtins `startBridge` invokes.
 *
 * `node:net`'s ESM namespace is FROZEN — `mock.method(net, "createServer")`
 * throws `Cannot redefine property: createServer` (verified on Node 26) — so the
 * bridge's "mock `net.createServer`" testability requirement is met by overriding
 * these PLAIN-OBJECT properties instead (assignment to a plain object is allowed).
 * In production both default to the real builtins, so behavior is identical to
 * calling `net.createServer` / `fs.chmodSync` directly.
 */
export const __deps = {
	createServer,
	chmodSync,
};

/**
 * Per-connection listener. PLACEHOLDER for now (S5): it intentionally does
 * nothing so the server can be built and tested in isolation. S8 will attach the
 * JSONL line reader + RPC dispatcher here; S9 will reject any method before a
 * valid `hello` handshake.
 */
function onConnection(_sock: Socket): void {
	// TODO(S8): attach the JSONL line reader (mirror pi modes/rpc/jsonl.js) and
	//           dispatch requests via the protocol.ts types.
	// TODO(S9): enforce the token handshake — reject every method before `hello`.
}

/**
 * Start (or restart) the pi-editor-bridge Unix-domain-socket RPC server.
 *
 * SOCKET LIFECYCLE
 *   Intended to be called on every `session_start` (startup / reload / new /
 *   resume / fork — PRD §6.2). It first invokes {@link stopBridge} — idempotent —
 *   so a reload/re-resume closes the previous server and unlinks the previous
 *   socket before binding a fresh one, never leaking resources across the
 *   session churn. The matching teardown is {@link stopBridge} on
 *   `session_shutdown`. Per the pi extension docs ("Long-lived resources and
 *   shutdown"), background resources (sockets) MUST start in `session_start`, NOT
 *   the factory body (the factory may run in invocations that never start a
 *   session). [NOTE: the session_start CALL is wired in a later task (S6);
 *   startBridge is itself defined and unit-tested here.]
 *
 * TOKEN GENERATION
 *   `token = randomUUID().replace(/-/g, "").slice(0, 32)` — exactly 32 lowercase
 *   hex chars (128 bits of entropy). This token is the REAL authentication
 *   boundary (PRD §12): the editor must present it in the `hello` handshake
 *   before the server answers any method. It is delivered via `process.env` in
 *   S16 (process-local, never on disk). NEVER log it.
 *
 * PERMISSION MODEL
 *   `socketPath = join(tmpdir(), "pi-editor-bridge-" + randomUUID() + ".sock")`.
 *   After `server.listen(socketPath)` the socket file is chmod'd to `0o600`
 *   (non-Windows only). `0o600` is DEFENSE-IN-DEPTH (PRD §5.1 / §12) — even with
 *   it, the token is what actually authorizes a connection. The chmod is wrapped
 *   in a try/catch so a transient failure cannot crash `session_start`; the
 *   server still comes up and the token still gates access. (The socket file is
 *   created synchronously by `listen()` — libuv binds before returning — so
 *   chmod immediately after listen does not race.)
 *
 * @param ctx `ExtensionContext` from `session_start`. `ctx.cwd` is RESERVED for
 *   the S16 `BridgeDescriptor` (`process.env.PI_NVIM_BRIDGE.cwd`); S5 derives
 *   the socket path from `os.tmpdir()`, not cwd, so `ctx` is not dereferenced
 *   here yet.
 *
 * SIDE EFFECTS: populates module-level {@link server} / {@link socketPath} /
 *   {@link token}; binds a Unix socket under `os.tmpdir()`.
 */
export function startBridge(ctx: ExtensionContext): void {
	void ctx; // reserved for the S16 BridgeDescriptor (PRD §6.4 cwd field).

	stopBridge(); // idempotent — close any prior server/socket first.

	token = randomUUID().replace(/-/g, "").slice(0, 32);
	socketPath = join(tmpdir(), `pi-editor-bridge-${randomUUID()}.sock`);

	server = __deps.createServer(onConnection);
	server.listen(socketPath);

	if (process.platform !== "win32") {
		try {
			__deps.chmodSync(socketPath, 0o600);
		} catch {
			// Best-effort: 0o600 is defense-in-depth; the token is the real auth
			// boundary (PRD §12). Do not let a chmod hiccup crash session_start.
		}
	}
}

/**
 * Idempotently stop the bridge server: close the listening socket, unlink the
 * socket file, and clear module state. Safe to call when nothing is running (all
 * operations are guarded). Returns silently on any error so reload/new/resume/
 * fork churn (PRD §6.2) never throws out of a lifecycle handler.
 *
 * NOTE (S5): this does NOT clear `process.env.PI_NVIM_BRIDGE` because S5 writes
 * no env var. When S16 adds the advertisement WRITE to {@link startBridge}, it
 * will also add `delete process.env.PI_NVIM_BRIDGE` here.
 */
export function stopBridge(): void {
	try {
		server?.close();
	} catch {}
	try {
		if (socketPath) rmSync(socketPath, { force: true });
	} catch {}
	server = undefined;
	socketPath = undefined;
	token = undefined;
}

/** Test/internal accessor for the live bridge server (`undefined` while stopped). */
export function getServer(): Server | undefined {
	return server;
}

/** Test/internal accessor for the bound socket path (`undefined` while stopped). */
export function getSocketPath(): string | undefined {
	return socketPath;
}

/**
 * Test/internal accessor for the session auth token (`undefined` while stopped).
 * NEVER log this value (PRD §12).
 */
export function getToken(): string | undefined {
	return token;
}
```

```typescript
// ============================================================================
// CREATE extension/tests/bridge-lifecycle.test.ts  (node:test + jiti)
// ============================================================================
import { test } from "node:test";
import assert from "node:assert/strict";
import { once } from "node:events";
import { statSync, existsSync } from "node:fs";
import type { ExtensionContext } from "@earendil-works/pi-coding-agent";
import {
	startBridge,
	stopBridge,
	getServer,
	getSocketPath,
	getToken,
	__deps,
} from "../pi-editor-bridge.ts";

// NOTE: server/socketPath/token are MODULE-LEVEL SINGLETONS shared across these
// tests. node:test runs top-level tests SEQUENTIALLY in definition order by
// default — do NOT enable concurrency. Each test calls stopBridge() in a finally
// so no real socket is leaked under os.tmpdir().

// Minimal ctx stub. startBridge accepts ctx per its contract but does not
// dereference ctx.cwd in S5 (reserved for S16) — so the stub can be minimal.
function makeCtx(): ExtensionContext {
	return { cwd: process.cwd(), mode: "tui" } as unknown as ExtensionContext;
}

// Wait for the real server to actually be listening (listen() binds the fd
// synchronously but emits 'listening' on the next tick).
async function waitForListening(): Promise<void> {
	const srv = getServer();
	if (srv) await once(srv, "listening");
}

// ---------------------------------------------------------------------------
// TEST 1 — MOCKED startBridge (honors the item MOCKING contract). Overrides
// __deps.createServer / __deps.chmodSync (the frozen node:net namespace CANNOT be
// mocked directly — `mock.method(net,'createServer')` throws). Asserts listen is
// called with the generated path AND chmod is called with exactly 0o600.
// ---------------------------------------------------------------------------
test("startBridge: createServer + listen(generated path) + chmod 0o600 + 32-hex token (mocked)", () => {
	const origCreate = __deps.createServer;
	const origChmod = __deps.chmodSync;
	let listenArg: unknown;
	let chmodArgs: unknown;
	const fakeServer = {
		listen(p: unknown) {
			listenArg = p;
			return this;
		},
		close() {},
		on() {},
		once() {},
	};
	// Plain-object overrides (no frozen-namespace issue). The createServer cast
	// MUST go through `unknown` — the fake object lacks the real Server class's
	// members (address/getConnections/ref/unref/…), so a direct cast fails tsc
	// (TS2352). The chmod cast is fine (contravariant params: unknown is wider).
	__deps.createServer = (() => fakeServer) as unknown as typeof __deps.createServer;
	__deps.chmodSync = ((p: unknown, m: unknown) => {
		chmodArgs = [p, m];
	}) as typeof __deps.chmodSync;
	try {
		startBridge(makeCtx());

		assert.equal(getServer(), fakeServer, "module server === fake server");
		assert.equal(
			typeof listenArg,
			"string",
			"server.listen must be called with the generated socket path",
		);
		assert.match(
			String(listenArg),
			/pi-editor-bridge-[0-9a-f-]{36}\.sock$/,
			"socket path matches <tmpdir>/pi-editor-bridge-<uuid>.sock",
		);
		assert.equal(getSocketPath(), listenArg, "module socketPath === listen arg");
		assert.deepEqual(
			chmodArgs,
			[listenArg, 0o600],
			"chmodSync called with (socketPath, 0o600)",
		);
		assert.match(
			getToken()!,
			/^[0-9a-f]{32}$/,
			"token is exactly 32 lowercase hex chars",
		);
	} finally {
		stopBridge(); // closes fake (no-op) + rmSync(force) the fake path (no-op)
		__deps.createServer = origCreate;
		__deps.chmodSync = origChmod;
	}
});

// ---------------------------------------------------------------------------
// TEST 2 — REAL integration. Binds an actual 0o600 Unix socket under tmpdir and
// verifies on-disk perms, listening state, token, and that stopBridge unlinks it.
// ---------------------------------------------------------------------------
test("startBridge: binds a real 0o600 Unix socket; stopBridge unlinks + resets", async () => {
	startBridge(makeCtx());
	await waitForListening();

	const srv = getServer()!;
	const sp = getSocketPath()!;
	assert.equal(srv.listening, true, "server is listening");
	const st = statSync(sp);
	assert.equal(st.mode & 0o777, 0o600, "socket file perms must be 0600");
	assert.match(getToken()!, /^[0-9a-f]{32}$/, "token is 32 hex chars");

	stopBridge();

	assert.equal(getServer(), undefined, "server cleared after stop");
	assert.equal(getSocketPath(), undefined, "socketPath cleared after stop");
	assert.equal(getToken(), undefined, "token cleared after stop");
	assert.equal(existsSync(sp), false, "socket file unlinked after stop");
});

// ---------------------------------------------------------------------------
// TEST 3 — idempotency. startBridge calls stopBridge() first, so a second start
// closes+unlinks the first server/socket before binding a fresh one.
// ---------------------------------------------------------------------------
test("startBridge is idempotent: second start closes + unlinks the first", async () => {
	startBridge(makeCtx());
	const s1 = getServer()!;
	const sp1 = getSocketPath()!;
	await once(s1, "listening");

	startBridge(makeCtx()); // internally calls stopBridge() first
	const s2 = getServer()!;
	const sp2 = getSocketPath()!;
	await once(s2, "listening");

	assert.notEqual(s1, s2, "a NEW server instance is created");
	assert.notEqual(sp1, sp2, "a NEW socket path is generated");
	assert.equal(s1.listening, false, "first server was closed by stopBridge");
	assert.equal(existsSync(sp1), false, "first socket file was unlinked");
	assert.equal(s2.listening, true, "second server is listening");

	stopBridge();
});

// ---------------------------------------------------------------------------
// TEST 4 — stopBridge is a safe no-op when idle and fully resets after a start.
// ---------------------------------------------------------------------------
test("stopBridge is a safe no-op when idle and resets state after a start", () => {
	// idle: must not throw, leaves everything undefined
	assert.doesNotThrow(() => stopBridge());
	assert.equal(getServer(), undefined);
	assert.equal(getSocketPath(), undefined);
	assert.equal(getToken(), undefined);

	startBridge(makeCtx());
	assert.ok(getServer() && getSocketPath() && getToken(), "state populated");
	const sp = getSocketPath()!;

	stopBridge();
	assert.equal(getServer(), undefined, "server cleared");
	assert.equal(getSocketPath(), undefined, "socketPath cleared");
	assert.equal(getToken(), undefined, "token cleared");
	assert.equal(existsSync(sp), false, "socket unlinked");
});
```

### Integration Points

```yaml
NO external integration points for S5.
  - No env-var write, no session_start/session_shutdown wiring, no protocol import,
    no tsconfig change, no package manifest. startBridge/stopBridge are defined
    and unit-tested via direct invocation; they have no side effects until called.
INTERNAL consumers (later tasks — they read S5's state/getters, not new wiring):
  - S6 (stopBridge lifecycle): REUSE the stopBridge introduced here; wire it into
        session_shutdown; wire startBridge into session_start (flip the TODO).
  - S8 (onConnection): replace the no-op placeholder with the JSONL reader + RPC
        dispatcher (imports protocol.ts + getProvider()).
  - S16 (env advertisement): JSON.stringify a BridgeDescriptor to
        process.env.PI_NVIM_BRIDGE using getSocketPath()/getToken() + ctx.cwd +
        process.pid; add `delete process.env.PI_NVIM_BRIDGE` to stopBridge.
SESSION-LEVEL SIDE EFFECTS (only when startBridge is actually called — deferred wiring):
  - FILESYSTEM: creates `<tmpdir>/pi-editor-bridge-<uuid>.sock` (mode 0o600 on
        non-Windows); removed by stopBridge.
  - PROCESS: opens a listening Unix-domain-socket fd; closed by stopBridge.
```

## Validation Loop

### Level 1: Syntax & Style (Immediate Feedback)

```bash
# Type-check the whole extension (including the modified pi-editor-bridge.ts).
# node:* imports resolve under "types":[] + Bundler moduleResolution (verified).
tsc --noEmit -p extension/tsconfig.json
# Expected: exit 0, no output. If errors, READ them — a "Cannot find module
# 'node:net'" would mean @types/node vanished (it hasn't); a chmod/order error
# means the code diverged from the skeleton.
```

### Level 2: Unit Tests (Component Validation)

```bash
# The S5 test suite (jiti loads the .ts directly — no build step).
node --import /home/dustin/.local/lib/node_modules/@earendil-works/pi-coding-agent/node_modules/jiti/lib/jiti-register.mjs \
  extension/tests/bridge-lifecycle.test.ts
# Expected: exit 0, fail 0, pass >= 3 (4 tests). A benign DEP0205 deprecation
# warning from jiti may print — ignore it.

# Regression: existing suites must still pass (S5 only ADDED to pi-editor-bridge.ts).
node --import /home/dustin/.local/lib/node_modules/@earendil-works/pi-coding-agent/node_modules/jiti/lib/jiti-register.mjs \
  extension/tests/mode-guard.test.ts
node --import /home/dustin/.local/lib/node_modules/@earendil-works/pi-coding-agent/node_modules/jiti/lib/jiti-register.mjs \
  extension/tests/provider-capture.test.ts
# Expected: each exit 0, fail 0.
```

### Level 3: Integration Testing (System Validation)

```bash
# Regression guard: the extension still loads under pi and the factory still
# runs cleanly in print mode. S5 adds functions but the factory still does NOT
# call them (and print mode short-circuits at the TUI guard anyway), so this
# must behave exactly as before.
pi --no-extensions -e ./extension/pi-editor-bridge.ts --print "ok" 2>&1 | tee /tmp/s5-regression.out
echo "exit=${PIPESTATUS[0]}"   # Expected: 0
grep -iE "error|cannot|fail|throw|TypeError" /tmp/s5-regression.out && echo "REGRESSION: error lines found" || echo "OK: no error lines"

# (Manual smoke, optional) prove a real socket really binds + accepts a connection:
#   node --import <jiti-register> -e '
#     import("./extension/pi-editor-bridge.ts").then(async ({startBridge,stopBridge,getSocketPath}) => {
#       startBridge({cwd:process.cwd(),mode:"tui"});
#       await new Promise(r=>setTimeout(r,50));
#       console.log("socket:", getSocketPath());
#       stopBridge();
#     });'
# Expected: prints a /tmp/.../pi-editor-bridge-<uuid>.sock path and exits 0.
```

### Level 4: Creative & Domain-Specific Validation

```bash
# Verify the real socket perms from TEST 2 hold against the actual OS (defense-in-
# depth check beyond the in-test statSync). After running bridge-lifecycle.test.ts
# in a debug loop that leaves a socket up, inspect it:
#   ls -l "$(getconf DARWIN_USER_TEMP_DIR 2>/dev/null || echo /tmp)"/pi-editor-bridge-*.sock 2>/dev/null
# Expected (when a server is up): srw------- owner-only (mode 0600). The in-test
# Level-2 assertion already proves this; this is an extra-confirmation option.
```

## Final Validation Checklist

### Technical Validation

- [ ] Level 1: `tsc --noEmit -p extension/tsconfig.json` → exit 0, no output.
- [ ] Level 2: `bridge-lifecycle.test.ts` → exit 0, fail 0, pass ≥ 3.
- [ ] Level 2 regression: `mode-guard.test.ts` + `provider-capture.test.ts` → still pass.
- [ ] Level 3: `pi --no-extensions -e ./extension/pi-editor-bridge.ts --print "ok"` → exit 0, no error lines.

### Feature Validation

- [ ] `startBridge` calls `stopBridge()` FIRST, then mints token + socketPath + server + listen + chmod.
- [ ] `token` is 32 lowercase hex chars; `socketPath` ends with `pi-editor-bridge-<uuid>.sock`.
- [ ] chmod is non-Windows-only and best-effort (try/catch); a real run leaves `0o600` on disk.
- [ ] `stopBridge` is idempotent (safe when idle) and resets `server`/`socketPath`/`token`; unlinks the socket.
- [ ] `__deps` seam defaults to real builtins and is overridable in tests (frozen-namespace workaround).
- [ ] Repeated `startBridge` (idempotency) closes + unlinks the prior server/socket.
- [ ] No env-var write, no session_start/session_shutdown wiring, no JSONL/onConnection logic, no protocol.ts import, no tsconfig change.

### Code Quality Validation

- [ ] New code is ADDITIVE to `pi-editor-bridge.ts`; existing `captureProvider`/`getProvider`/`liveProvider`/factory are byte-for-byte unchanged.
- [ ] Mode-A JSDoc on `startBridge` (socket lifecycle / token generation / permission model) and on every new export.
- [ ] TABS for indentation; matches the rest of the file.
- [ ] Getters (not `export let`) expose state — jiti live-binding reassignment is unreliable (verified).
- [ ] Token is never logged.

### Documentation & Deployment

- [ ] startBridge JSDoc explains the deferred session_start wiring (S6) and the reserved `ctx.cwd` (S16).
- [ ] stopBridge JSDoc notes the omitted env-var clear (added by S16) so S6/S16 authors see the contract.
- [ ] No new environment variables introduced in S5.

---

## Anti-Patterns to Avoid

- ❌ Don't try `mock.method(net, "createServer", …)` — the `node:net` namespace is frozen; it throws. Use the `__deps` seam.
- ❌ Don't expose state via `export let server` — jiti doesn't propagate the reassignment to importers (verified). Use getter functions (like `getProvider()`).
- ❌ Don't chmod before `server.listen(socketPath)` — the socket file doesn't exist yet → ENOENT. listen THEN chmod.
- ❌ Don't skip the `stopBridge()` call at the top of `startBridge` — reload/new/resume/fork would leak servers + sockets.
- ❌ Don't `delete process.env.PI_NVIM_BRIDGE` in S5's stopBridge — nothing writes it yet (S16 owns both the write and the delete).
- ❌ Don't wire `startBridge` into the `session_start` handler in S5 — it would make mode-guard.test.ts bind a real socket mid-unit-test. Defer the wiring to S6.
- ❌ Don't edit `extension/tsconfig.json` — `pi-editor-bridge.ts` is already included and the new test is glob-covered; editing it risks colliding with the in-parallel S1 task.
- ❌ Don't dereference `ctx.cwd` in S5 — it is reserved for the S16 descriptor; the socket path uses `os.tmpdir()`.
- ❌ Don't let chmod throw out of startBridge — wrap it (best-effort; the token is the real boundary).
- ❌ Don't introduce npm dependencies — PRD §6.7 is Node-builtin-only for the extension.
