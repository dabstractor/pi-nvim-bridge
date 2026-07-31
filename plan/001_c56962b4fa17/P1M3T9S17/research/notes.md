# S17 Research Notes — `commandsChanged` S→C notification on `session_start`

Source of truth for the PRP. Verified against `~/projects/pi` (pi monorepo) + the local
`extension/` tree via a scout pass (artifacts/outputs/c5b0ea67/context.md).

## §1. The task (PRD §5.4, §6.2, §11)

`commandsChanged` is the ONE server→client NOTIFICATION in PRD §5.4 (`S→C`, empty params,
no result). PRD §6.2 wires it: on `session_start` (any reason) the bridge must
"(Re)capture provider, (re)start server, refresh env var, **emit commandsChanged if
already running**." PRD §11 ("Reload during an open editor") adds: "re-capture the
provider and re-advertise ... and emit `commandsChanged`. The open editor's existing
connection stays valid."

The wire type ALREADY EXISTS in `protocol.ts`:
- `CommandsChangedParams = Record<string, never>` (§C)
- `NotificationMethod = "commandsChanged"` (§D)
- `TypedNotification` (§D)
- It is OMITTED from `BridgeResultMap` (notifications have no result). So `protocol.ts`
  needs NO change.

`sendNotification(sock, method, params?)` ALREADY EXISTS in `connection.ts` (the per-socket
S→C push primitive; connection.test.ts test 3 already exercises it for "commandsChanged").
S17 adds the BROADCAST loop + the registry it iterates.

## §2. The gap: NO connection registry exists today (scout Q2 — CONFIRMED)

`connection.ts` has exactly ONE module-level value: `const handlers = new Map<string,
MethodHandler>();` (the per-method handler registry). `onConnection(sock)` (connection.ts)
creates a FRESH `ConnectionState { handshakeComplete: false }` **local to the closure** and
wires the line reader + `sock.on("error")`/`sock.on("close")`. It does NOT register the
socket anywhere. When the socket closes, the state + socket become unreachable (GC'd) —
nothing is removed because nothing was added.

`pi-editor-bridge.ts` module-level state: `liveProvider`, `server`, `socketPath`, `token`,
`cwd`, `fdAvailableCache` — NONE track individual sockets. `server` is the `net.Server`
(a listener), NOT a collection of its accepted sockets.

`sendNotification(sock, …)` writes to ONE sock argument — it is NOT a broadcast. **S17
must introduce the registry it loops over.**

## §3. pi session lifecycle ordering (scout Q1 — CONFIRMED, the key external fact)

On `/reload` (and `new`/`resume`/`fork`): `session_shutdown{reason:X}` fires and **is fully
drained (handlers awaited)** BEFORE `session_start{reason:X}` fires. Citations:
- `runner.ts:784-810` — `emit` loop: `for (const handler of handlers) await handler(event, ctx);`
  (one extension at a time, one handler at a time, strictly sequential + awaited).
- `runner.ts:187-202` — `emitSessionShutdownEvent`: `await extensionRunner.emit(event);`
- `agent-session.ts:2577-2601` (`reload()`): line 2583
  `await emitSessionShutdownEvent(…, {reason:"reload"})` THEN line 2601
  `await this._extension_runner.emit({type:"session_start", reason:"reload"});`.
- `agent-session-runtime.ts:186-202` (`teardownCurrent`): line 188
  `await emitSessionShutdownEvent(…, {reason})` then `createRuntime({sessionStartEvent:
  {reason}})` emits `session_start` from `bindExtensions` (`agent-session.ts:2230`).
- Tests codify it: `agent-session-runtime-events.test.ts:142/154/241` assert exact
  `session_shutdown` then `session_start` sequences for new/resume/fork.

**Bridge consequence:** the bridge wires `stopBridge()` into `session_shutdown` and
`startBridge()` into `session_start`. Because shutdown fully drains before start, on
`/reload` the OLD server is torn down (`server.close()`, `server=undefined`, token unset,
socketPath unlinked) in a clean synchronous gap BEFORE the NEW `startBridge` runs.

## §4. CRITICAL Node gotcha: `server.close()` does NOT close existing sockets

`net.Server.close()` "Stops the server from accepting new connections and keeps existing
connections" (Node docs; scout Q2 residual risk). So on `/reload`:
1. `session_shutdown` → `stopBridge()`: `server.close()` (existing editor sockets STAY
   OPEN), `server=undefined`, `token=undefined`, socketPath unlinked.
2. `session_start` → `startBridge()`: brand-new `net.Server`, new socketPath, new token.

The OLD editor sockets (if any editor was open during reload) are now **orphaned**: still
connected, untracked (no registry), and any request they send validates against the NEW
token → `-32600 "bad token"` + `sock.end()`. **There is currently no way for the bridge to
proactively notify or close those old sockets.** This is the gap the new connection
registry + `closeAllConnections()` closes.

**Realistic reload scenario (no editor open):** to type `/reload` the TUI must be ACTIVE,
which means NO external editor is open (the editor launches with the TUI stopped). So at
every realistic `session_shutdown` the connection registry is EMPTY. `closeAllConnections()`
is therefore a no-op in practice — but it is correct, defensive, and prevents the registry
from ever leaking. It is SAFE to include.

## §5. No pi precedent for multi-client broadcast (scout Q3 — CONFIRMED)

pi's RPC mode is a **single-client, stdio** protocol (one process ↔ one client over
stdin/stdout). There is NO `Set`/`Map` of connected clients, NO `clients.forEach`, NO
"broadcast a notification to all" pattern anywhere in `packages/coding-agent/src/modes/rpc/`
or the extension examples (`rpc-mode.ts:59-61` funnels every outbound message through one
`output()` sink to raw stdout; `pendingExtensionRequests` is request-id correlation, not
connection tracking). **There is no pi convention to mirror.** The bridge invents its own
minimal registry.

## §6. Design decisions

### §6.1 Registry shape — `Map<Socket, ConnectionState>` (NOT a bare `Set<Socket>`)
- `broadcastNotification` filters on `state.handshakeComplete` (PRD §12 handshake boundary:
  never push server notifications to an unauthenticated peer — defense-in-depth; the Neovim
  client only processes notifications AFTER its own hello succeeds, so this is consistent
  with client-side expectations). Filtering requires the state alongside the socket ⇒ a Map.
- Populated in `onConnection` (we have both `sock` and `state` there); removed in the
  `sock.on("close")` handler (`close` fires after `error` too, so one `delete` covers both
  paths — mirrors the existing `detach()`-on-close idempotency).

### §6.2 `broadcastNotification(method, params?)` — iterates handshaken connections
Loops `connections`, `if (state.handshakeComplete) sendNotification(sock, method, params)`.
`params` omitted (undefined) for `commandsChanged` → wire form
`{"jsonrpc":"2.0","method":"commandsChanged"}` (valid JSON-RPC; matches the empty
`CommandsChangedParams`). No throw on write failure — `sendNotification`'s `sock.write` is
best-effort and a dead socket's `'error'` is already handled by `onConnection`.

### §6.3 `closeAllConnections()` — force-close every tracked socket + clear the map
`for (const sock of [...connections.keys()]) try { sock.end(); } catch {}; connections.clear();`
- `end()` (graceful half-close, FIN) NOT `destroy()` (RST) — matches the existing
  `bye`/`fatal-close` `sock.end()` pattern. Lets any in-flight response flush; the remote
  observes a clean EOF (the Neovim plugin's silent-degrade path, PRD §11).
- Iterates a SNAPSHOT (`[...keys()]`) so a `sock.end()` that synchronously triggers `'close'`
  (and thus `connections.delete`) mid-loop cannot mutate the map under iteration.
- Idempotent (empty registry → no-op).

### §6.4 `closeAllConnections()` is called from `stopBridge()`
This is what makes `stopBridge` fully tear down (server listener + every accepted socket),
closing the §4 orphan gap. Placed right after `server?.close()` (logical grouping: stop
accepting, then close accepted). Because the realistic reload registry is empty (§4), this
is a no-op in practice — but it is the responsible way to ship a connection registry.

### §6.5 The emit — `__deps.broadcastNotification("commandsChanged")` at the END of session_start
- Placed AFTER `startBridge` + provider re-capture + all handler registrations: the
  notification means "commands changed, re-query," so the handlers must be ready to serve
  the re-query and the provider must be the new one.
- Guarded by `if (getServer())` — honors PRD §6.2 "when server running" / "if already
  running." After `startBridge`, `getServer()` is defined, so the guard passes; it is
  defensive belt-and-suspenders (covers the theoretical case where `startBridge`'s async
  `'error'` handler ran `stopBridge` mid-flight).
- **Routed through the `__deps` seam** (extend `__deps` with `broadcastNotification`) for
  testability: the wiring test asserts the emit WITHOUT a live connection in the registry —
  which is necessary because `startBridge`'s internal `stopBridge()`→`closeAllConnections()`
  CLEARS the registry before the emit runs, so the emit's effect (a notification on a socket)
  is structurally unobservable. `__deps` already exists (frozen-`node:net` workaround);
  extending it with one more outbound capability is the codebase-consistent spy point.

### §6.6 Interpretation of "emit if already running" (PRD §6.2)
The phrase does NOT map cleanly to the implemented lifecycle: `session_shutdown` ALWAYS
tears the server down before `session_start` (§3), so at the start of `session_start` the
server is never "already running" from the PRIOR session. The implemented reading: **emit
after the server is (re)started this `session_start`, guarded by `getServer()` being
defined.** On the very first `startup` the registry is empty (no editor open yet) ⇒ the emit
is a harmless no-op; on `reload`/`new`/`resume`/`fork` the registry is likewise empty in the
realistic case (§4) ⇒ no-op. **The mechanism is correctly wired and complete; in the current
"tear-down-on-reload" architecture it is structurally quiescent.** It activates the moment a
future change lets a connection survive a session boundary (then the broadcast "just works"
to tell the surviving editor to invalidate its command cache — the P2.M5.T16.S27 /
P3.M10.T26.S41 consumers). This is an honest property, not a bug; document it.

## §7. Test conventions (verified — node:test + jiti, NOT vitest)
- Runner: `JITI_REG=/home/dustin/.local/lib/node_modules/@earendil-works/pi-coding-agent/node_modules/jiti/lib/jiti-register.mjs`
  then `node --import "$JITI_REG" extension/tests/<file>.test.ts`.
- Type check: `tsc --noEmit -p extension/tsconfig.json`.
- `fakeSocket()`/`parseResponses()`/`readFirstResponse` are LOCAL per-file helpers (copied
  verbatim from connection.test.ts / the S13 suite) — NOT exported.
- THREE layers: UNIT (registry + broadcast + closeAllConnections directly), WIRING
  (session_start emits via `__deps` spy + a fake-pi that records handlers; stopBridge clears
  the registry), REAL (one Unix-socket pair: handshaken client receives the broadcast;
  closeAllConnections/stopBridge closes a live client).
- `__resetHandlersForTest()` AND a NEW `__resetConnectionsForTest()` in EVERY test's
  `finally` — BOTH registries (`handlers`, `connections`) are module-level and persist
  across tests in one process.
- `__getConnectionStateForTest(sock)` seam — lets a UNIT test flip
  `handshakeComplete` on a socket registered via `onConnection` (the state is otherwise
  encapsulated in `onConnection`'s closure).
- TOKEN never leaks (PRD §12) — a SECURITY test grep-sweeps broadcast writes (commandsChanged
  has empty params, so trivially clean, but include for discipline).

## §8. Files this task touches
- `extension/connection.ts` — ADD the `connections` Map (module-level, near `handlers`);
  `connections.set` in `onConnection`; `connections.delete` in the `close` handler;
  `broadcastNotification`; `closeAllConnections`; test seams
  (`__resetConnectionsForTest`, `__getActiveConnectionCountForTest`,
  `__getConnectionStateForTest`).
- `extension/pi-editor-bridge.ts` — IMPORT `broadcastNotification, closeAllConnections`
  from connection.ts; EXTEND `__deps` with `broadcastNotification`; CALL `closeAllConnections()`
  in `stopBridge` (after `server?.close()`); EMIT
  `if (getServer()) __deps.broadcastNotification("commandsChanged");` at the END of
  `session_start` (after the S14 `getCommands` registration + the `(S14 DONE)` comment);
  update the STATUS block + comment.
- `extension/tests/commands-changed-notification.test.ts` (NEW) — UNIT/WIRING/REAL.
- `extension/protocol.ts` — UNCHANGED (`CommandsChangedParams`, `NotificationMethod`,
  `TypedNotification` all already defined in §C/§D).
- `extension/tsconfig.json` — UNCHANGED (`include: ["tests/**/*.ts"]` auto-covers the new test).

## §9. Downstream consumers
- `P2.M5.T16.S27` — Neovim `bridge.lua` notification handler for `commandsChanged` (S→C).
- `P3.M10.T26.S41` — Neovim cache invalidation: on `commandsChanged`, clear the cached
  command list + re-query (`getCommands`/`getSuggestions`) so a `/reload` that added a
  prompt template / extension command / skill is reflected without restarting the editor.
- Together they make the broadcast useful once a connection survives a session boundary.
