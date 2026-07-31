name: "P1.M3.T9.S17 — Broadcast `commandsChanged` S→C notification on `session_start` when the server is running"
description: "pi-editor-bridge extension (TS). Implement the ONE server→client NOTIFICATION in PRD §5.4 (`commandsChanged`, empty params, no result) and wire it to fire on every `session_start` (PRD §6.2). This requires introducing the bridge's FIRST connection registry — a module-level `Map<Socket, ConnectionState>` in `connection.ts`, populated in `onConnection`, removed on socket `close` — because today `connection.ts` tracks ONLY the per-method `handlers` Map and `onConnection` creates a fresh per-socket `ConnectionState` local to its closure (nothing enumerates connected sockets). On that registry, add (1) `broadcastNotification(method, params?)` which iterates ONLY handshaken connections (`state.handshakeComplete` — PRD §12: never push server notifications to an unauthenticated peer; the Neovim client only processes notifications after its own `hello`) and calls the EXISTING per-socket `sendNotification(sock, method, params)` primitive; and (2) `closeAllConnections()` which `sock.end()`s every tracked socket and clears the map — REQUIRED because Node's `net.Server.close()` only stops accepting NEW connections and KEEPS existing ones (verified: scout Q2 residual risk), so without this `stopBridge` orphans any editor socket open during a `/reload`. Wire `closeAllConnections()` into `stopBridge()` (after `server?.close()`) so teardown is complete; wire the emit into the END of `session_start` (after `startBridge` + provider re-capture + all handler registrations) as `if (getServer()) __deps.broadcastNotification(\"commandsChanged\");`. Route the emit through the EXISTING `__deps` seam (extend it with `broadcastNotification`) so the wiring test can assert the emit WITHOUT a live connection in the registry — necessary because `startBridge`'s internal `stopBridge()`→`closeAllConnections()` CLEARS the registry before the emit, making the emit's on-socket effect structurally unobservable. `protocol.ts` is UNCHANGED (`CommandsChangedParams = Record<string, never>`, `NotificationMethod = \"commandsChanged\"`, `TypedNotification` all already defined in §C/§D). New `commands-changed-notification.test.ts` (UNIT/WIRING/REAL three layers). node:test + jiti (NOT vitest). Downstream consumers: P2.M5.T16.S27 (Neovim notification handler) + P3.M10.T26.S41 (Neovim cache invalidation). HONEST PROPERTY: in the current 'tear-down-on-reload' architecture (session_shutdown fully drains + stopBridge runs BEFORE session_start — verified scout Q1), the registry is EMPTY at every realistic session_start (to type /reload the TUI must be active ⇒ no external editor open), so the broadcast is structurally quiescent in v1; it is correctly wired and activates the moment a future change lets a connection survive a session boundary. This is a documented property, not a bug."

---

## Goal

**Feature Goal**: Give the bridge the ability to **push a `commandsChanged`
server→client notification to every authenticated (handshaken) connected editor**,
and fire it on every `session_start` so a `/reload` (or `new`/`resume`/`fork`) that
rebuilt the autocomplete provider tells connected clients to invalidate their
command cache and re-query. This completes the PRD §5.4 protocol surface —
`commandsChanged` is the only S→C notification in the methods table, and it is the
only method that had NO server-side implementation until now.

**Deliverable**:
1. `extension/connection.ts` — ADD:
   - A module-level connection registry: `const connections = new Map<Socket, ConnectionState>();` (placed near the existing `handlers` Map).
   - In `onConnection`: `connections.set(sock, state);` right after `const state: ConnectionState = { handshakeComplete: false };`.
   - In `onConnection`'s `sock.on("close", …)` handler: `connections.delete(sock);` (idempotent; `close` fires after `error` too, so one delete covers both paths — mirrors the existing `detach()`-on-close idempotency).
   - `export function broadcastNotification(method: string, params?: unknown): void` — iterate `connections`, filter `state.handshakeComplete`, call the EXISTING `sendNotification(sock, method, params)`.
   - `export function closeAllConnections(): void` — snapshot keys, `sock.end()` each (try/catch), `connections.clear()`.
   - Three test seams (mirror the `__resetHandlersForTest`/`__hasHandlerForTest` idiom): `__resetConnectionsForTest()`, `__getActiveConnectionCountForTest(): number`, `__getConnectionStateForTest(sock): ConnectionState | undefined`.
2. `extension/pi-editor-bridge.ts` — ADD:
   - `broadcastNotification, closeAllConnections` to the existing `import { … } from "./connection.ts";` block.
   - Extend `__deps` (type + initializer) with `broadcastNotification: typeof broadcastNotification`.
   - In `stopBridge()`: call `closeAllConnections();` immediately after the `server?.close()` try/catch block (full teardown: server listener + every accepted socket).
   - In `session_start`, as the LAST statement (after the S14 `getCommands` registration + the `(S14 DONE)` comment): `if (getServer()) __deps.broadcastNotification("commandsChanged");`
   - Update the file-top STATUS block + the `(S14 DONE)` comment to note S17.
3. `extension/tests/commands-changed-notification.test.ts` (NEW) — three layers: UNIT (registry lifecycle + broadcast filtering + closeAllConnections), WIRING (session_start emits via `__deps` spy + a fake-pi that records handlers; stopBridge clears the registry), REAL (one Unix-socket pair: a handshaken client receives the broadcast; closeAllConnections/stopBridge closes a live client).

**Success Definition**:
- `broadcastNotification("commandsChanged")` writes EXACTLY one
  `{"jsonrpc":"2.0","method":"commandsChanged"}` line (no `id`) to every
  handshaken connected socket and ZERO lines to non-handshaken sockets.
- `session_start` (tui) calls `__deps.broadcastNotification("commandsChanged")`
  after `startBridge`; `session_start` (non-tui) does NOT (TUI guard returns first).
- `stopBridge()` empties the connection registry and `end()`s every tracked socket.
- A real handshaken client connected over a Unix socket receives the broadcast; a
  `stopBridge()`/`closeAllConnections()` closes a live client (it observes `close`).
- `tsc --noEmit -p extension/tsconfig.json` exits 0; the new suite passes; **all 13
  existing extension suites stay green** (the registry is additive; `closeAllConnections`
  in `stopBridge` is a no-op when the registry is empty, which is the case in every
  existing lifecycle test).

## User Persona

**Target User**: The `pi-bridge.nvim` Neovim plugin (P2.M5 / P3.M10) — the bridge's
only client. (Indirectly: the human editing a pi prompt in their `$EDITOR`.)

**Use Case**: while an external Neovim editor is open editing a pi prompt, the user
runs `/reload` (or `/new`, `/resume`, `/fork`) in the pi TUI — but realistically the
TUI must be active to type `/reload`, so the external editor is closed first.
`commandsChanged` is the signal that, when a connection DOES survive a session
boundary (today: never in practice; future: if the server stops tearing down on
reload), tells the editor: "the command surface changed (new prompt template /
extension command / skill was registered) — drop your cached command list and
re-query via `getCommands`/`getSuggestions`."

**User Journey**: (future, when connections survive reload) editor open → user
`/reload`s in pi TUI → pi rebuilds the provider → bridge broadcasts
`commandsChanged` → Neovim plugin (P3.M10.T26.S41) clears its command cache → next
completion query reflects the new commands — no editor restart needed.

**Pain Points Addressed**: (1) the §5.4 protocol surface was incomplete (no S→C
notification existed); (2) there was no mechanism for the server to push to all
clients (only per-socket `sendNotification`); (3) `stopBridge` leaked accepted
sockets across reload (Node `server.close()` keeps them) — now force-closed.

## Why

- **Completes PRD §5.4.** With S9–S14 shipping every C→S request method, the ONE
  remaining method (`commandsChanged`, S→C notification) had no server-side
  implementation. S17 lands it + the broadcast primitive it needs.
- **Unblocks the Neovim-side consumers.** P2.M5.T16.S27 (notification handler) and
  P3.M10.T26.S41 (cache invalidation) both DEPEND on the server being ABLE to emit
  this notification. S17 is the server half of that contract.
- **Closes a real teardown gap.** Introducing the connection registry makes the
  pre-existing `server.close()`-doesn't-close-sockets behavior (scout Q2) a concrete,
  fixable leak. `closeAllConnections()` in `stopBridge()` is the responsible way to
  ship a connection registry (and is a no-op in every realistic scenario — see §11).

### What this is NOT
- NOT a change to the server lifecycle (reload still tears the server down — that's
  S5/S6, COMPLETE). S17 does NOT make connections survive reload; it ships the
  broadcast MECHANISM + emit, and documents that the mechanism is quiescent until a
  future lifecycle change activates it (PRD §15 future enhancement).
- NOT a new transport, framing, or handshake — those are S5–S10 (complete).
- NOT a new wire type — `CommandsChangedParams`/`NotificationMethod`/`TypedNotification`
  already exist in `protocol.ts` §C/§D (S4).
- NOT error-code refinement — that's S15 (complete). The broadcast path has no
  domain-error surface (it writes best-effort; dead sockets are handled by the
  existing `onConnection` `'error'` handler).

## What

### User-visible behavior (wire)

`commandsChanged` is a JSON-RPC 2.0 **NOTIFICATION** (no `id`, no reply expected).
It is dispatched OUTSIDE `handleLine`'s request/notification input path — the SERVER
pushes it; the client never requests it. It carries empty params (omitted on the wire):

```jsonc
// S→C (broadcast to every handshaken connection)
{"jsonrpc":"2.0","method":"commandsChanged"}
```

A non-handshaken connection receives NOTHING (PRD §12 handshake boundary).

### When it fires

On EVERY `session_start` (any reason: `startup`/`reload`/`new`/`resume`/`fork`),
as the LAST step — after `startBridge`, provider re-capture, and all handler
registrations — guarded by `if (getServer())`. (Rationale in §11 + research §6.6.)

### Success Criteria

- [ ] `broadcastNotification("commandsChanged")` writes exactly one `{"jsonrpc":"2.0","method":"commandsChanged"}` line to each handshaken connected socket, zero to non-handshaken.
- [ ] The notification envelope has NO `id` (it is a notification, not a request).
- [ ] `session_start` (tui) calls `__deps.broadcastNotification("commandsChanged")` after `startBridge`; non-tui does NOT.
- [ ] `stopBridge()` calls `closeAllConnections()` → empties the registry + `end()`s every tracked socket.
- [ ] `onConnection` registers the socket; `close` removes it (no registry leak across the many editor open/close cycles one session sees — PRD §6.7).
- [ ] A real handshaken Unix-socket client receives the broadcast; `closeAllConnections()`/`stopBridge()` closes a live client.
- [ ] The token value never appears in any broadcast line (PRD §12 — `commandsChanged` has empty params, so trivially clean; assert it anyway).
- [ ] `tsc --noEmit -p extension/tsconfig.json` ⇒ exit 0, no output.
- [ ] New `commands-changed-notification.test.ts` ⇒ `ℹ fail 0`.
- [ ] All 13 existing extension suites stay green (incl. `connection.test.ts` 16 tests, `bridge-lifecycle*`, `mode-guard`).

## All Needed Context

### Context Completeness Check

_Passes "No Prior Knowledge":_ the implementer needs only this PRP + the four cited
files (`connection.ts`, `pi-editor-bridge.ts`, `protocol.ts`, one existing test for
the helper pattern) + the verified build/test commands. Every pattern (`__deps`
seam, module-level state + getters, `onConnection` lifecycle, `sendNotification`,
`__reset*ForTest` discipline, the fakeSocket/fake-pi test helpers) is reproduced or
cited with exact line references.

### Documentation & References

```yaml
# MUST READ — PRD sections that define this task
- url: PRD.md §5.4 (methods table — the commandsChanged S→C row: "{}` *(notification)*"),
        §6.2 (Events used — session_start row: "emit commandsChanged if already running"),
        §11 (Reload during an open editor — "emit commandsChanged"; failure modes),
        §12 (Security — "reject any method before a valid hello"; never log the token)
  why: "§5.4 is the authoritative wire contract (notification, empty params, no result); §6.2 is the emit trigger; §11 is the realistic reload scenario + silent-degrade contract; §12 is the handshake-boundary + no-token-leak discipline"
  critical: "§6.2 'if already running' does NOT map cleanly to the tear-down-on-reload lifecycle (session_shutdown fully drains BEFORE session_start) — see §11/research §6.6 for the implemented reading (emit after (re)start, guarded by getServer())"

# MUST READ — the dispatch loop + ConnectionState + sendNotification (the file S17 edits most)
- file: extension/connection.ts
  why: "the connection-handling module S17 extends: the `handlers` Map is the ONLY module-level state today; `onConnection` creates a per-socket `ConnectionState` LOCAL to its closure (not registered anywhere); `sendNotification(sock, method, params?)` is the per-socket S→C push primitive (connection.test.ts test 3 already exercises it for 'commandsChanged'); the `sock.on('close')` handler is where registry removal goes (close fires after error too)"
  pattern: "module-level `const x = new Map<…>()` near `handlers`; `__resetHandlersForTest()`/`__hasHandlerForTest()` is the test-seam idiom to mirror for `__resetConnectionsForTest`/`__getActiveConnectionCountForTest`/`__getConnectionStateForTest`"
  gotcha: "connection.ts is owned by S8/S10 — BOTH COMPLETE — so the additive registry/broadcast/closeAll edit is safe (same justification S14 used to add `closeAfterResponse` to ConnectionState). Do NOT import pi-editor-bridge.ts here (it would create an import cycle — connection.ts is imported BY pi-editor-bridge.ts)."

# MUST READ — the lifecycle + __deps + stopBridge/startBridge/session_start (the other file S17 edits)
- file: extension/pi-editor-bridge.ts
  why: "`stopBridge()` (the symmetric teardown — S17 adds closeAllConnections after server?.close()); `startBridge()` (calls stopBridge FIRST — so the registry is cleared before the session_start emit runs — this is WHY the wiring test needs the __deps spy); the `session_start` block (where the emit goes — after the S14 getCommands registration + the `(S14 DONE)` comment); `__deps` (the mutable testability seam — extend it with broadcastNotification); the connection.ts import block (add broadcastNotification, closeAllConnections)"
  pattern: "`__deps: { createServer; chmodSync } = { createServer, chmodSync }` — extend the type + initializer with `broadcastNotification: typeof broadcastNotification`; session_start calls `__deps.broadcastNotification(...)` (NOT the bare import) so tests can override"
  gotcha: "jiti does NOT implement cross-module live-binding reassignment of `export let` — state is read via GETTERS. `broadcastNotification`/`closeAllConnections` are FUNCTIONS (stable bindings) so direct import is fine; but the EMIT call site must go through `__deps.broadcastNotification` (a property on a mutable object) so the wiring test can swap it. getServer() after startBridge is always defined (the `if (getServer())` guard is belt-and-suspenders)."

# MUST READ — wire types (ALL already defined; protocol.ts needs NO change)
- file: extension/protocol.ts
  why: "§C defines `CommandsChangedParams = Record<string, never>`; §D defines `NotificationMethod = \"commandsChanged\"`, `TypedNotification`, and OMITS commandsChanged from `BridgeResultMap` (notifications have no result). S17 CONSUMES these — NO edit."
  pattern: "the notification carries empty params; on the wire they are OMITTED (sendNotification drops `params` when undefined) → `{\"jsonrpc\":\"2.0\",\"method\":\"commandsChanged\"}` — a valid JSON-RPC notification."

# MUST READ — the test conventions (node:test + jiti, NOT vitest; three layers; fakeSocket helper)
- file: extension/tests/connection.test.ts
  why: "the canonical test file for connection.ts: shows fakeSocket()/parseResponses()/readFirstResponse() (LOCAL per-file helpers — COPY them), the REAL Unix-socket integration pattern (createServer+connect+once('listening')), the `__resetHandlersForTest()` in every `finally`, and test 3 which already asserts `sendNotification(sock, 'commandsChanged', {})` writes a no-id notification"
  pattern: "import { test } from 'node:test'; import assert from 'node:assert/strict'; import { EventEmitter, once } from 'node:events'; import { createServer, connect, type Socket } from 'node:net'; … fakeSocket() returns {sock, writes, state:{ended}} where end() emits 'close'"
  gotcha: "node:test runs tests SEQUENTIALLY and BOTH registries (`handlers`, `connections`) are MODULE-LEVEL — EVERY test MUST call __resetHandlersForTest() AND __resetConnectionsForTest() in finally. jiti prints a benign DeprecationWarning on Node 26 stderr — judge by exit code + the ℹ pass/ℹ fail summary."

# PRIOR RESEARCH (full details + the scout findings)
- docfile: plan/001_c56962b4fa17/P1M3T9S17/research/notes.md
  why: "the verified findings: §2 (NO registry exists today), §3 (session_shutdown drains BEFORE session_start — runner.ts:784-810, agent-session.ts:2583/2601), §4 (CRITICAL: server.close() does NOT close existing sockets — the orphan gap closeAllConnections closes), §5 (no pi broadcast precedent — bridge invents its own registry), §6 (design decisions: Map not Set, handshake filter, end() not destroy(), __deps spy rationale), §7 (test conventions), §8 (files touched)"
  section: "§3 (lifecycle ordering citations), §4 (the Node gotcha), §6.5/§6.6 (the __deps spy + 'if already running' interpretation — READ BEFORE questioning why the wiring test spies)"
```

### Current Codebase tree (run `tree` in the root of the project)

```bash
cd /home/dustin/projects/pi-nvim-bridge && find extension -name '*.ts' | sort
# extension/
#   pi-editor-bridge.ts   # default factory + handlers (S9-S14) + lifecycle (THIS TASK: +broadcast emit, +closeAllConnections in stopBridge, +__deps.broadcastNotification)
#   protocol.ts           # TYPE-ONLY wire contract (UNCHANGED — CommandsChangedParams etc. already in §C/§D)
#   connection.ts         # dispatch loop + ConnectionState + sendNotification (THIS TASK: +connections Map, +broadcastNotification, +closeAllConnections, +3 test seams)
#   jsonl-reader.ts       # JSONL framing (UNCHANGED)
#   tests/
#     provider-capture.test.ts            # S2
#     mode-guard.test.ts                  # S3
#     protocol.test.ts                    # S4
#     bridge-lifecycle.test.ts            # S5
#     bridge-lifecycle-wiring.test.ts     # S6
#     jsonl-reader.test.ts                # S7
#     connection.test.ts                  # S8/S10 (16 tests — MUST stay green; helper source)
#     hello-handler.test.ts               # S9
#     handshake-gate.test.ts              # S10
#     get-suggestions-handler.test.ts     # S11
#     apply-completion-handler.test.ts    # S12
#     should-trigger-file-completion-handler.test.ts  # S13
#     ping-bye-getcommands-handler.test.ts            # S14
#     error-wrapping.test.ts                          # S15
#     bridge-env.test.ts                              # S16
#     (commands-changed-notification.test.ts)         # S17 — NEW this task
#   tsconfig.json
```

### Desired Codebase tree with files to be added/modified

```bash
extension/
  connection.ts   # MODIFY — add `connections` Map, populate in onConnection, remove on close,
                  #           broadcastNotification, closeAllConnections, 3 test seams
  pi-editor-bridge.ts   # MODIFY — import broadcast+closeAll, extend __deps, closeAll in stopBridge,
                        #           emit in session_start, STATUS/comment updates
  tests/
    commands-changed-notification.test.ts   # NEW — UNIT/WIRING/REAL
# protocol.ts — UNCHANGED (CommandsChangedParams/NotificationMethod/TypedNotification already in §C/§D)
# tsconfig.json — UNCHANGED (tests/**/*.ts glob auto-includes the new test)
```

### Known Gotchas of our codebase & Library Quirks

```typescript
// CRITICAL: handlers do NOT receive the socket (MethodHandler = (params, state) => …).
// So broadcast CANNOT be a handler — it is a module-level function in connection.ts
// that iterates the registry and calls the EXISTING sendNotification(sock, …). This is
// the S→C push analog of the S14 bye/closeAfterResponse pattern, but simpler (no
// handler indirection — the server initiates the push).

// CRITICAL: Node's net.Server.close() "Stops the server from accepting new connections
// and KEEPS existing connections" (verified — scout Q2). So stopBridge()'s server?.close()
// does NOT close editor sockets already accepted. On /reload those sockets would ORPHAN
// (still connected, untracked, validating against the NEW token → -32600). closeAllConnections()
// in stopBridge() is the fix. (In the realistic /reload case the registry is empty — to type
// /reload the TUI must be active ⇒ no editor open — so this is a no-op in practice, but it
// is the responsible way to ship a connection registry.)

// CRITICAL: jiti does NOT implement cross-module live-binding reassignment of `export let`.
// State (token/socketPath/cwd/...) is read via GETTERS. broadcastNotification/closeAllConnections
// are FUNCTIONS (stable bindings) so a direct import works for CALLING them. BUT the session_start
// EMIT must go through `__deps.broadcastNotification` (a property on the MUTABLE __deps object)
// so the wiring test can swap it — because startBridge's internal stopBridge→closeAllConnections
// CLEARS the registry before the emit, the emit's on-socket effect is structurally unobservable,
// so the test must SPY on the call rather than observe a notification on a socket.

// CRITICAL: BOTH `handlers` and the NEW `connections` are MODULE-LEVEL Maps. node:test runs
// sequentially and they persist across tests. EVERY test MUST call __resetHandlersForTest()
// AND __resetConnectionsForTest() in finally, or later tests see stale state. (Existing suites
// already do __resetHandlersForTest; the new suite adds __resetConnectionsForTest.)

// GOTCHA: the handshake filter. broadcastNotification must iterate ONLY `state.handshakeComplete`
// connections (PRD §12: never push to an unauthenticated peer). This is why the registry is a
// Map<Socket, ConnectionState> (not a bare Set<Socket>) — it needs the state alongside the socket.
// A non-handshaken socket in the registry (connected but no hello yet) receives NOTHING.

// GOTCHA: iterate a SNAPSHOT in closeAllConnections (`[...connections.keys()]`), NOT the live
// map — sock.end() can synchronously trigger 'close' → connections.delete, mutating the map
// under iteration (Map iteration during mutation is well-defined in JS but a snapshot is clearer
// and avoids confusion). Then connections.clear() to guarantee the empty state.

// GOTCHA: use sock.end() (graceful FIN) NOT sock.destroy() (RST) in closeAllConnections —
// matches the existing bye/fatal-close sock.end() pattern; lets in-flight writes flush and
// gives the remote a clean EOF (the Neovim plugin's silent-degrade path, PRD §11).

// GOTCHA: `close` fires on normal disconnect AND after `error` (Node contract). Put
// connections.delete(sock) in the `close` handler ONLY (one place covers both paths), mirroring
// the existing detach()-on-close idempotency. Do NOT also delete in the `error` handler (double-
// delete is harmless but redundant).

// GOTCHA: CommandsChangedParams = Record<string, never>. broadcastNotification is GENERIC
// (method: string, params?: unknown); call it as `__deps.broadcastNotification("commandsChanged")`
// with NO params arg → sendNotification omits `params` → wire form has no params key. That is a
// valid JSON-RPC notification. (Passing {} would emit a `params:{}` key — also valid; omitting
// is cleaner and matches the empty-params intent.)

// CRITICAL (PRD §12): NEVER log or echo the token. commandsChanged has empty params so it
// trivially cannot leak — but include a SECURITY sweep test for discipline (mirror S9-S14).
```

## Implementation Blueprint

### Data models and structure

No new wire types. `CommandsChangedParams`/`NotificationMethod`/`TypedNotification`
already exist in `protocol.ts` §C/§D. The ONLY structural addition is a module-level
registry in `connection.ts`:

```typescript
// extension/connection.ts — the new connection registry (alongside the existing `handlers` Map)
import type { Socket } from "node:net";
// (ConnectionState already exists — S8 defined { handshakeComplete: boolean }; S14 added closeAfterResponse?)

/**
 * The live set of connected, not-yet-closed sockets and their per-connection state.
 * Populated by {@link onConnection}; drained by each socket's `close` handler and by
 * {@link closeAllConnections}. Iterated by {@link broadcastNotification} (handshaken
 * entries only). MODULE-LEVEL (shared across all connections — one bridge, one set).
 */
const connections = new Map<Socket, ConnectionState>();
```

The two new functions + three test seams (all in `connection.ts`):

```typescript
/** Write a JSON-RPC 2.0 NOTIFICATION to every HANDSHAKEN connected socket. Filters on
 *  `state.handshakeComplete` (PRD §12: never push to an unauthenticated peer; the Neovim
 *  client only processes notifications after its own hello). `params` omitted on the wire
 *  when `undefined`. Best-effort: a dead socket's 'error' is already handled by onConnection. */
export function broadcastNotification(method: string, params?: unknown): void {
	for (const [sock, state] of connections) {
		if (state.handshakeComplete) sendNotification(sock, method, params);
	}
}

/** Force-close (graceful `end()`, NOT `destroy()`) every tracked socket and clear the registry.
 *  REQUIRED in stopBridge because Node's net.Server.close() only stops ACCEPTING new connections
 *  — it does NOT close already-accepted sockets (scout Q2). Idempotent (empty registry → no-op).
 *  Iterates a SNAPSHOT so a synchronous 'close'→delete mid-loop cannot mutate the map under us. */
export function closeAllConnections(): void {
	for (const sock of [...connections.keys()]) {
		try { sock.end(); } catch { /* already closing/closed — best-effort */ }
	}
	connections.clear();
}

/** Test seam: clear the registry (module-level — isolate between tests). */
export function __resetConnectionsForTest(): void { connections.clear(); }
/** Test seam: how many sockets are currently tracked? (assertions about registry lifecycle.) */
export function __getActiveConnectionCountForTest(): number { return connections.size; }
/** Test seam: read a socket's stored state (so a UNIT test can flip `handshakeComplete`). */
export function __getConnectionStateForTest(sock: Socket): ConnectionState | undefined {
	return connections.get(sock);
}
```

### Implementation Tasks (ordered by dependencies)

```yaml
Task 1: MODIFY extension/connection.ts — add the connection registry + lifecycle hooks
  - ADD `const connections = new Map<Socket, ConnectionState>();` at module level, placed
          right AFTER the existing `const handlers = new Map<string, MethodHandler>();`
          (line ~125) with the JSDoc above.
  - EDIT onConnection (connection.ts:357): immediately AFTER
          `const state: ConnectionState = { handshakeComplete: false };`, ADD:
            connections.set(sock, state);
  - EDIT onConnection's `sock.on("close", …)` handler (connection.ts ~383): ADD
          `connections.delete(sock);` as the FIRST line inside the close handler (before
          the existing `try { detach(); } catch { … }`). (close fires after error too, so
          this one delete covers both paths — mirrors detach()'s idempotency.)
  - DO NOT touch the `error` handler, handleLine, the handshake gate, or sendNotification.
  - VERIFY: ConnectionState already has `handshakeComplete` (S8) — no type change needed
          for the registry. The broadcast filter reads state.handshakeComplete directly.
  - WHY FIRST: Tasks 2–3 (broadcastNotification/closeAllConnections) iterate this map;
          Task 4 (stopBridge/session_start wiring) depends on both.

Task 2: MODIFY extension/connection.ts — add broadcastNotification + closeAllConnections + test seams
  - ADD `broadcastNotification(method, params?)`, `closeAllConnections()`, and the three
          `__*ForTest` seams (code above) to connection.ts. Place broadcastNotification/
          closeAllConnections near `sendNotification` (the push primitive they build on);
          place the test seams near `__resetHandlersForTest`/`__hasHandlerForTest`.
  - broadcastNotification: `for (const [sock, state] of connections) if (state.handshakeComplete)
          sendNotification(sock, method, params);` — reuses the EXISTING sendNotification.
  - closeAllConnections: snapshot keys (`[...connections.keys()]`), `try { sock.end(); } catch {}`,
          then `connections.clear();`.
  - NAMING: broadcastNotification / closeAllConnections (lowerCamelCase module functions,
          matching sendNotification/sendError/sendResponse). __resetConnectionsForTest /
          __getActiveConnectionCountForTest / __getConnectionStateForTest (the __ForTest
          suffix matching __resetHandlersForTest/__hasHandlerForTest).
  - DEPENDENCIES: Task 1 (the `connections` map).

Task 3: MODIFY extension/pi-editor-bridge.ts — import + extend __deps + wire stopBridge + emit
  - EDIT the connection.ts import block (the existing
          `import { onConnection, registerBridgeHandler, BridgeRpcError, toBridgeRpcError,
          type ConnectionState, type MethodHandler } from "./connection.ts";`):
          ADD `broadcastNotification,` and `closeAllConnections,` to the value imports
          (before `BridgeRpcError`).
  - EDIT `__deps` (the `export const __deps: { createServer; chmodSync } = { createServer,
          chmodSync };` declaration): EXTEND the type with `broadcastNotification: typeof
          broadcastNotification;` and the initializer with `broadcastNotification,`. (The
          imported function is the default — tests override the property.)
  - EDIT stopBridge(): immediately AFTER the `try { server?.close(); } catch { /* idempotent */ }`
          block (and BEFORE the `if (socketPath) { … rmSync … }` block), ADD:
            closeAllConnections(); // full teardown: server listener + every accepted socket (Node server.close() keeps existing sockets)
  - EDIT session_start: as the LAST statement of the session_start handler (AFTER the S14
          `registerBridgeHandler("getCommands", makeGetCommandsHandler({ getProvider }));`
          call and AFTER the `// (S14 DONE). …` comment, but BEFORE the closing `});`),
          ADD:
            // S17: notify any connected, handshaken editor that the command surface changed
            // (provider rebuilt on reload/new/resume/fork) so it can invalidate its cache
            // (P2.M5.T16.S27 handler + P3.M10.T26.S41 cache invalidation). Guarded by
            // getServer() (PRD §6.2 "when server running" — defined after startBridge).
            // Routed through __deps so the wiring test can spy (startBridge's internal
            // stopBridge→closeAllConnections clears the registry before this runs).
            if (getServer()) __deps.broadcastNotification("commandsChanged");
  - UPDATE the `// (S14 DONE). S16 writes …` comment → append a note that S17 emits
          commandsChanged here (and S16 already wrote the descriptor in startBridge).
  - UPDATE the file-top STATUS block: ADD a `STATUS (P1.M3.T9.S17)` note documenting the
          connection registry, broadcastNotification/closeAllConnections, the stopBridge
          closeAll wiring, the session_start emit, and the "structurally quiescent in v1"
          property (research §6.6).
  - DEPENDENCIES: Tasks 1–2.

Task 4: CREATE extension/tests/commands-changed-notification.test.ts (UNIT/WIRING/REAL)
  - COPY the header imports + fakeSocket()/parseResponses()/readFirstResponse() helpers
          VERBATIM from extension/tests/connection.test.ts (they are LOCAL per-file helpers).
  - LAYER 1 — UNIT (registry + broadcast + closeAllConnections, in connection.ts directly):
      - "broadcastNotification: empty registry → no-op, no throw" — call it; assert no throw.
      - "broadcastNotification: handshaken socket receives exactly one no-id notification" —
            onConnection(fakeSock1); __getConnectionStateForTest(fakeSock1).handshakeComplete
            = true; broadcastNotification("commandsChanged"); assert writes.length===1 and
            parsed === {jsonrpc:"2.0", method:"commandsChanged"} (no id key).
      - "broadcastNotification: NON-handshaken socket receives NOTHING (PRD §12)" —
            onConnection(fakeSock2) (handshake stays false); broadcastNotification(...);
            assert writes.length===0.
      - "broadcastNotification: mixed registry → only handshaken sockets notified" —
            register a (handshaken), b (not), c (handshaken); broadcast; assert a,c got 1
            each, b got 0.
      - "onConnection registers; close removes from registry (no leak)" — onConnection(s);
            assert __getActiveConnectionCountForTest()===1; s.emit("close"); assert count===0.
      - "closeAllConnections: ends all tracked sockets + clears registry" — onConnection(a);
            onConnection(b); closeAllConnections(); assert a.state.ended && b.state.ended;
            assert __getActiveConnectionCountForTest()===0.
      - "closeAllConnections: empty registry → no-op, no throw".
      - EVERY UNIT test: finally { __resetConnectionsForTest(); } (and the registry-shared
            ones also __resetHandlersForTest() if they registered any handler — they don't).
  - LAYER 2 — WIRING (session_start emits; stopBridge clears — via the __deps spy + a fake pi):
      - Helper: a tiny fake pi that records handlers:
            function captureHandlers(factory) { const h = {}; factory({ on(e, fn){ h[e]=fn; } });
            return h; }   // default-export the factory: `import factory from "../pi-editor-bridge.ts"`
      - "session_start (tui) calls broadcastNotification('commandsChanged')" — snapshot
            __deps.createServer/chmodSync (fake server: {listen(){return self},close(){},on(){return
            self}}); __setFdAvailableForTest(true); SPY __deps.broadcastNotification (record the
            method arg); const h = captureHandlers(factory); h.session_start({type:"session_start",
            reason:"startup"}, {mode:"tui", ui:{addAutocompleteProvider:()=>{}}, cwd:"/test"});
            assert spy was called with "commandsChanged".
      - "session_start (non-tui) does NOT broadcast (TUI guard returns before)" — same setup,
            reset spy; h.session_start({...}, {mode:"rpc", ...}); assert spy NOT called.
      - "stopBridge clears the connection registry (closeAllConnections wiring)" —
            onConnection(fakeSock); flip handshake; assert count===1; stopBridge() (server is
            undefined → server?.close() no-op; closeAllConnections clears); assert count===0 AND
            fakeSock.state.ended===true.
      - EVERY WIRING test: finally { restore __deps.createServer/chmodSync/broadcastNotification;
            __setFdAvailableForTest(undefined); stopBridge(); __resetConnectionsForTest();
            __resetHandlersForTest(); }.
  - LAYER 3 — REAL (ONE real Unix-socket pair):
      - "REAL: handshaken client receives commandsChanged broadcast over a Unix socket" —
            register a hello handler (stubbed token via makeHelloHandler); createServer((c)=>
            onConnection(c)); listen tmp socket; client connect; send hello → assert HelloResult
            (client is now handshaken + in the registry); broadcastNotification("commandsChanged");
            readNext(client) → assert {jsonrpc:"2.0", method:"commandsChanged"} (no id).
            client.destroy(); server.close() in finally.
      - "REAL: closeAllConnections() (via stopBridge) closes a live client" — connect +
            handshake a client; stopBridge(); await Promise.race([once(client,'close'),
            once(client,'end'), <2s timeout>]) → assert the client observed close.
      - SECURITY test: "commandsChanged broadcast carries NO token/sensitive data" — after a
            broadcast, assert no write line contains the TOKEN string (commandsChanged has empty
            params so this is trivially true; include for discipline, mirroring S9-S14).
      - EVERY REAL test: finally { __resetHandlersForTest(); __resetConnectionsForTest(); }.
  - FOLLOW pattern: extension/tests/connection.test.ts (fakeSocket/parseResponses/
          readFirstResponse, createServer+connect+once('listening'), node:test + assert/strict
          + jiti). NAMING: `commands-changed-notification.test.ts` (kebab, matching the family).

Task 5: VALIDATE (see Validation Loop)
  - tsc --noEmit -p extension/tsconfig.json ⇒ exit 0, no output.
  - node --import "$JITI_REG" extension/tests/commands-changed-notification.test.ts ⇒ ℹ fail 0.
  - ALL 13 existing suites stay green (the registry is additive; closeAllConnections in
          stopBridge is a no-op when the registry is empty — the case in every existing
          lifecycle test; the __deps extension is backward compatible).
```

### Implementation Patterns & Key Details

```typescript
// === PATTERN 1: the connection registry (connection.ts, alongside `handlers`) ===
const connections = new Map<Socket, ConnectionState>();
// … in onConnection:
export function onConnection(sock: Socket): void {
	const state: ConnectionState = { handshakeComplete: false };
	connections.set(sock, state); // S17: track for broadcast/teardown
	const detach = attachJsonlLineReader(sock, (line) => { void handleLine(sock, state, line); });
	sock.on("error", (err: Error) => { /* unchanged: log, detach, destroy */ });
	sock.on("close", () => {
		connections.delete(sock); // S17: idempotent removal (close fires after error too)
		try { detach(); } catch { /* idempotent */ }
	});
}

// === PATTERN 2: broadcast (filter handshaken; reuse sendNotification) ===
export function broadcastNotification(method: string, params?: unknown): void {
	for (const [sock, state] of connections) {
		if (state.handshakeComplete) sendNotification(sock, method, params);
	}
}

// === PATTERN 3: closeAllConnections (snapshot + graceful end + clear) ===
export function closeAllConnections(): void {
	for (const sock of [...connections.keys()]) {
		try { sock.end(); } catch { /* best-effort */ }
	}
	connections.clear();
}

// === PATTERN 4: stopBridge full teardown (pi-editor-bridge.ts) ===
export function stopBridge(): void {
	try { server?.close(); } catch { /* idempotent */ }
	closeAllConnections(); // S17: Node server.close() keeps existing sockets — close them
	if (socketPath) { try { rmSync(socketPath, { force: true }); } catch { /* idempotent */ } }
	server = undefined; socketPath = undefined; token = undefined;
	delete process.env[BRIDGE_ENV];
}

// === PATTERN 5: the session_start emit (pi-editor-bridge.ts, LAST statement) ===
//   (after all registerBridgeHandler calls + the (S14 DONE) comment, before the closing `});`)
// 	if (getServer()) __deps.broadcastNotification("commandsChanged");
//
// __deps extension (the spy point):
// 	export const __deps: {
// 		createServer: typeof createServer;
// 		chmodSync: typeof chmodSync;
// 		broadcastNotification: typeof broadcastNotification; // S17
// 	} = { createServer, chmodSync, broadcastNotification };
```

### Integration Points

```yaml
CONNECTION.TS:
  - add: "module-level `connections = new Map<Socket, ConnectionState>()` (near `handlers`)"
  - add: "`connections.set(sock, state)` in onConnection; `connections.delete(sock)` in the close handler"
  - add: "`broadcastNotification(method, params?)` + `closeAllConnections()` + 3 `__*ForTest` seams"
  - preserve: "handleLine, the handshake gate, sendNotification/sendError/sendResponse, onConnection's error handler — UNCHANGED"

PI-EDITOR-BRIDGE.TS:
  - extend import: "add `broadcastNotification, closeAllConnections` to the `from './connection.ts'` block"
  - extend __deps: "add `broadcastNotification: typeof broadcastNotification` (type + initializer)"
  - modify stopBridge: "add `closeAllConnections();` after the `server?.close()` try/catch"
  - modify session_start: "add `if (getServer()) __deps.broadcastNotification('commandsChanged');` as the LAST statement"
  - update: "STATUS block + the (S14 DONE) comment"

PROTOCOL.TS:
  - none: "CommandsChangedParams / NotificationMethod / TypedNotification ALL already defined in §C/§D. NO CHANGE."

TSCONFIG:
  - none: "the `include: ['tests/**/*.ts']` glob auto-covers the new test. NO CHANGE."

NO OTHER INTEGRATION POINTS:
  - DATABASE: none
  - CONFIG: none (no new settings/env vars — PI_NVIM_BRIDGE is S16's, untouched)
  - ROUTES: none
```

## Validation Loop

### Level 1: Syntax & Type (after the source edits)

```bash
cd /home/dustin/projects/pi-nvim-bridge
npx tsc --noEmit -p extension/tsconfig.json
# Expected: exit 0, NO output.
# (Type reasoning: broadcastNotification/closeAllConnections are plain functions on
# connection.ts. The `connections` Map<Socket, ConnectionState> reuses the existing
# ConnectionState type (S8/S14) — no type change. Extending __deps with
# `broadcastNotification: typeof broadcastNotification` is additive. The session_start
# emit `__deps.broadcastNotification("commandsChanged")` typechecks (string arg).
# getServer() returns Server | undefined; the `if (getServer())` guard narrows. No
# tsconfig change — tests/**/*.ts auto-includes the new test.)
```

### Level 2: Unit / component tests (node:test + jiti — NOT vitest)

```bash
JITI_REG=/home/dustin/.local/lib/node_modules/@earendil-works/pi-coding-agent/node_modules/jiti/lib/jiti-register.mjs

# The NEW commandsChanged suite (UNIT + WIRING + REAL)
node --import "$JITI_REG" extension/tests/commands-changed-notification.test.ts
# Expected: exit 0, `ℹ fail 0`. (jiti prints a benign DeprecationWarning on Node 26
# stderr — judge by exit code + the `ℹ pass`/`ℹ fail` summary, ignore the warning.)

# Regression: connection dispatch (16 tests) — the registry is additive; onConnection
# now set/delete on the map but no existing test asserts connection count, so all 16 pass.
node --import "$JITI_REG" extension/tests/connection.test.ts
# Expected: `ℹ tests 16`, `ℹ pass 16`, `ℹ fail 0`.

# Regression: bridge lifecycle — stopBridge now calls closeAllConnections(), but the
# registry is EMPTY in these tests (they never open a real connection via onConnection),
# so closeAllConnections is a no-op. startBridge/stopBridge assertions unchanged.
node --import "$JITI_REG" extension/tests/bridge-lifecycle.test.ts          # S5
node --import "$JITI_REG" extension/tests/bridge-lifecycle-wiring.test.ts   # S6
# Expected: `ℹ fail 0` each.

# Regression: mode-guard — non-tui session_start returns BEFORE the emit (TUI guard
# is above the emit), so __deps.broadcastNotification is never called in non-tui.
node --import "$JITI_REG" extension/tests/mode-guard.test.ts                # S3
# Expected: `ℹ fail 0`.

# Regression: the env advertisement (S16) + all handler suites (S9-S15) — untouched.
for t in bridge-env hello-handler handshake-gate get-suggestions-handler \
         apply-completion-handler should-trigger-file-completion-handler \
         ping-bye-getcommands-handler error-wrapping provider-capture protocol \
         jsonl-reader; do
  echo "--- $t"
  node --import "$JITI_REG" "extension/tests/$t.test.ts" 2>/dev/null | grep -E "^ℹ (tests|pass|fail)"
done
# Expected: every file `ℹ fail 0`.

# Full extension suite (now 14 files) — no regressions.
for t in extension/tests/*.test.ts; do
  echo "--- $t"
  node --import "$JITI_REG" "$t" 2>/dev/null | grep -E "^ℹ (tests|pass|fail)"
done
# Expected: every file `ℹ fail 0`.
```

### Level 3: Integration (a real socket pair — broadcast reaches a handshaken client)

```bash
# Driven by the REAL tests inside commands-changed-notification.test.ts.
# To eyeball the wire by hand (optional): hello → broadcast → client observes the notification.
JITI_REG=/home/dustin/.local/lib/node_modules/@earendil-works/pi-coding-agent/node_modules/jiti/lib/jiti-register.mjs
node --import "$JITI_REG" -e '
  const { createServer, connect } = require("node:net");
  const { join } = require("node:path"), { tmpdir } = require("node:os"), { randomUUID } = require("node:crypto");
  const { onConnection, registerBridgeHandler, broadcastNotification, __resetHandlersForTest, __resetConnectionsForTest } = await import("./extension/connection.ts");
  const { makeHelloHandler, BRIDGE_VERSION } = await import("./extension/pi-editor-bridge.ts");
  const { serializeJsonLine, attachJsonlLineReader } = await import("./extension/jsonl-reader.ts");
  const TOKEN = "deadbeef".repeat(4);
  registerBridgeHandler("hello", makeHelloHandler({ getToken:()=>TOKEN, getCwd:()=>"/tmp", getFdAvailable:()=>true, version:BRIDGE_VERSION }));
  const sockpath = join(tmpdir(), `s17-${randomUUID()}.sock`);
  const s = createServer(c=>onConnection(c)); s.listen(sockpath);
  s.once("listening", ()=>{
    const cli = connect(sockpath);
    const read = () => new Promise(res=>{ const d=attachJsonlLineReader(cli,l=>{d();res(JSON.parse(l))}); });
    cli.once("connect", async ()=>{
      cli.write(serializeJsonLine({jsonrpc:"2.0",id:"h1",method:"hello",params:{token:TOKEN}}));
      console.log("hello:", JSON.stringify(await read()));
      broadcastNotification("commandsChanged");
      console.log("broadcast:", JSON.stringify(await read()));
      cli.destroy(); s.close();
    });
  });
'
# Expected:
#   hello:     {"jsonrpc":"2.0","id":"h1","result":{"ok":true,"serverVersion":"0.1.0","cwd":"/tmp","fdAvailable":true}}
#   broadcast: {"jsonrpc":"2.0","method":"commandsChanged"}    (no id — it is a notification)
```

### Level 4: Domain-specific validation (correctness invariants)

```bash
# (a) Only HANDSHAKEN connections are notified — asserted in UNIT (mixed registry).
# (b) closeAllConnections force-closes tracked sockets — asserted in UNIT + REAL.
# (c) session_start emits exactly once (tui) / never (non-tui) — asserted in WIRING via the __deps spy.
# (d) The notification envelope has NO id — asserted in UNIT (no "id" key) + REAL.
# (e) No token leaks — asserted in the SECURITY sweep.

# (Optional) prove the registry does NOT leak across a simulated connect/close cycle:
node --import "$JITI_REG" -e '
  const { onConnection, __getActiveConnectionCountForTest, __resetConnectionsForTest } = await import("./extension/connection.ts");
  const { EventEmitter } = require("node:events");
  const fake = () => Object.assign(new EventEmitter(), { write:()=>true, end(){this.emit("close")}, destroy(){this.emit("close")} });
  __resetConnectionsForTest();
  const a = fake(); onConnection(a); console.log("after connect:", __getActiveConnectionCountForTest()); // 1
  a.emit("close"); console.log("after close:", __getActiveConnectionCountForTest());                      // 0
'
# Expected: after connect: 1 ; after close: 0   (registry self-cleans on close)
```

## Final Validation Checklist

### Technical Validation

- [ ] `npx tsc --noEmit -p extension/tsconfig.json` exits 0 (zero output).
- [ ] `node --import "$JITI_REG" extension/tests/commands-changed-notification.test.ts` → `ℹ fail 0`.
- [ ] All 13 existing suites green (incl. `connection.test.ts` 16 tests, `bridge-lifecycle*`, `mode-guard`, `bridge-env`).
- [ ] No `tsconfig.json` edit (the `tests/**/*.ts` glob auto-includes the new test).
- [ ] No `protocol.ts` edit (commandsChanged types already exist).
- [ ] No file other than `extension/connection.ts` + `extension/pi-editor-bridge.ts` (source) + `extension/tests/commands-changed-notification.test.ts` (new) is modified.

### Feature Validation

- [ ] `broadcastNotification("commandsChanged")` writes one no-id notification to each handshaken socket, zero to non-handshaken.
- [ ] `session_start` (tui) calls `__deps.broadcastNotification("commandsChanged")` after `startBridge`; non-tui does NOT.
- [ ] `stopBridge()` calls `closeAllConnections()` → registry empty + every tracked socket `end()`'d.
- [ ] `onConnection` registers; `close` removes (no leak across editor open/close cycles).
- [ ] A real handshaken client receives the broadcast over a Unix socket.
- [ ] The notification envelope has NO `id` (it is a notification).

### Code Quality Validation

- [ ] Registry is a `Map<Socket, ConnectionState>` (so broadcast can filter on `handshakeComplete`).
- [ ] `closeAllConnections` iterates a SNAPSHOT (`[...connections.keys()]`) and uses `end()` (not `destroy()`).
- [ ] `connections.delete(sock)` is in the `close` handler only (idempotent; covers error path too).
- [ ] The emit is routed through `__deps.broadcastNotification` (the spy point); `closeAllConnections` is called directly (tested via its effect — registry cleared).
- [ ] `__resetConnectionsForTest()` is called in EVERY test's `finally` (alongside `__resetHandlersForTest()`).
- [ ] No token / socket path / descriptor value logged or broadcast (PRD §12).
- [ ] STATUS block + the `(S14 DONE)` comment updated to note S17.

### Documentation & Deployment

- [ ] STATUS block documents the "structurally quiescent in v1" property honestly (research §6.6) — so a future reader understands WHY the broadcast rarely reaches anyone today and what future change would activate it.
- [ ] [Mode A] JSDoc on `broadcastNotification` (handshake filter rationale) + `closeAllConnections` (the Node `server.close()` gotcha).
- [ ] (README / `doc/pi-editor.txt` are separate tasks — S18 / P3.M11 — NOT this task.)

---

## Anti-Patterns to Avoid

- ❌ Don't broadcast to NON-handshaken connections — filter on `state.handshakeComplete` (PRD §12; the Neovim client only processes notifications after `hello`). This is why the registry is a `Map<Socket, ConnectionState>`, not a bare `Set<Socket>`.
- ❌ Don't use `sock.destroy()` in `closeAllConnections` — use `sock.end()` (graceful FIN, matches the `bye`/fatal-close pattern; lets writes flush + gives the remote a clean EOF for silent-degrade).
- ❌ Don't iterate the live `connections` map in `closeAllConnections` while calling `sock.end()` (a synchronous `'close'`→`delete` can mutate it) — iterate a snapshot `[...connections.keys()]`, then `clear()`.
- ❌ Don't put `connections.delete(sock)` in BOTH the `error` and `close` handlers — `close` fires after `error` (Node contract), so one `delete` in `close` covers both (mirrors the existing `detach()`-on-close idempotency).
- ❌ Don't call `broadcastNotification` (the bare import) from `session_start` — call `__deps.broadcastNotification(...)` so the wiring test can spy (the registry is empty at emit time because `startBridge`'s internal `stopBridge`→`closeAllConnections` cleared it, so the emit's effect is otherwise unobservable).
- ❌ Don't try to make the broadcast "useful in v1" by NOT tearing the server down on reload — that is a separate architectural change owned by S5/S6 (COMPLETE) and out of scope. S17 ships the mechanism + emit; the quiescence is a documented property (research §6.6), not a bug to "fix" here.
- ❌ Don't skip test cleanup — BOTH `__resetHandlersForTest()` AND `__resetConnectionsForTest()` in every `finally` (both Maps are module-level and persist across tests).
- ❌ Don't add `commandsChanged` to `BridgeResultMap` or register it via `registerBridgeHandler` — it is a NOTIFICATION (S→C), not a request; the server pushes it via `broadcastNotification`, never via `handleLine`. (It is correctly OMITTED from `BridgeResultMap` and is a `NotificationMethod` in `protocol.ts` §D.)
- ❌ Don't log the token (PRD §12) — `commandsChanged` has empty params so it cannot leak, but keep the SECURITY sweep test for discipline.
