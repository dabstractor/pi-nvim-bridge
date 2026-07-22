# Research Notes — P1.M2.T3.S6: stopBridge() lifecycle wiring

**Item**: `stopBridge()` — close server, unlink socket, clear state, idempotent.
**Plan path**: `plan/001_c56962b4fa17/P1M2T3S6/`.

> **Headline finding**: `stopBridge()` ALREADY EXISTS and is fully implemented by the
> sibling task **P1.M2.T3.S5** (S5 shipped it as a hard dependency — `startBridge` calls
> `stopBridge()` first for idempotent re-entry). S6's actual deliverable is therefore
> NOT "implement stopBridge" (that would be a redundant no-op); it is the **lifecycle
> WIRING** that makes the server actually start/stop with the pi session, plus the
> **defensive `server.on('error')` handler** that S5 explicitly deferred to S6. The
> authoritative enumeration of S6's scope comes from the S5 author's own cross-task notes
> (quoted in §1 below) — it names ALL of: reuse stopBridge, wire it into
> `session_shutdown`, wire `startBridge(ctx)` into `session_start` at the L101 TODO call
> site, and add `server.on('error')`.

## 1. Authoritative scope — quoted from the S5 author's cross-task notes

`plan/001_c56962b4fa17/P1M2T3S5/research/notes.md` §6 (verbatim):

> **P1.M2.T3.S6 (stopBridge):** REUSE the stopBridge S5 ships (do NOT recreate it). S6
> adds: wire it into `session_shutdown`; (after S16) add `delete process.env.PI_NVIM_BRIDGE`;
> wire `startBridge(ctx)` into the `session_start` handler at the L101 TODO call site; and
> add `server.on('error', ...)` so an async listen failure (EADDRINUSE) doesn't crash pi
> (S5's tests use unique UUID paths so this isn't exercised in S5).

Corroborated in `extension/pi-editor-bridge.ts` JSDoc (written by S5):

- `stopBridge()` STATUS line: *"ships the server/socket/state teardown half. This is also
  the core of sibling task **P1.M2.T3.S6** ... S6 should REUSE this function (verify it
  exists), wire it into `session_shutdown`, and (once S16 lands) add the
  `delete process.env.PI_NVIM_BRIDGE` line."*
- `startBridge()` STATUS bullets: *"wiring startBridge into the session_start handler ..
  **P1.M2.T3.S6** (the L101 `// TODO(M2): startBridge(...)` call site). NOT wired in S5
  so the existing mode-guard.test.ts (S3) doesn't fire a real listen/chmod during a unit
  test."* and *"server.on('error', ...) handler .. **S6, when wiring**. An unhandled
  'error' event (e.g. EADDRINUSE) THROWS and would crash pi."*

**Out of scope for S6** (explicitly): writing `process.env.PI_NVIM_BRIDGE` is
**P1.M3.T8.S16**; S6 must NOT add the `delete process.env.PI_NVIM_BRIDGE` line either
(nothing writes the var until S16, so deleting it in S6 would be a dead reference).
`onConnection` / handshake / RPC handlers are S7/S8/S9/S11–S14.

## 2. The existing stopBridge() — REUSE verbatim (post-S5, verified on disk)

`extension/pi-editor-bridge.ts` lines ~160–180 (current file). Already idempotent, already
swallows no-op failures, already resets all three state vars. S6 changes ZERO lines in its
body. The ONLY stopBridge-touching work for S6 is (a) wiring a CALL to it into
`session_shutdown`, and (b) updating its JSDoc STATUS marker to record the wiring landed.

## 3. Independent empirical re-verification (2026-07-18, Node v26.4.0)

The ONE load-bearing NEW claim for S6 (the `server.on('error')` handler) was re-verified
fresh via `/tmp/s6-probe.mjs` (a real `net.Server` + synthetic `srv.emit("error", ...)`):

| Claim | Result |
|---|---|
| `server.emit("error", err)` with **no** listener → **THROWS** (would crash pi per Node's EventEmitter contract) | ✅ `THREW: synthetic EADDRINUSE` |
| `server.emit("error", err)` **with** a listener → handler invoked, **NO throw** | ✅ `NO THROW; handler invoked=true` |
| Calling `srv.close()` a **second** time from inside the error handler → safe no-op (idempotency holds; stopBridge's `server?.close()` won't choke) | ✅ `OK: second close() is a safe no-op` |

**Implications**: (1) the error handler is MANDATORY once startBridge is wired into the
real session_start (an EADDRINUSE/EACCES would otherwise crash pi); (2) the handler can
freely call `stopBridge()` (double-close is safe, matching stopBridge's own idempotency);
(3) the handler must NOT rethrow (PRD §6.7: "never throws from handlers").

## 4. Affected-test inventory (verified by reading each suite)

| Test file | Invokes session_start handler? | Affected by S6 wiring? | Action |
|---|---|---|---|
| `tests/provider-capture.test.ts` (S2) | NO — calls `captureProvider()` directly | no | unchanged |
| `tests/mode-guard.test.ts` (S3) | **YES** — `handler(STARTUP_EVENT, makeCtx("tui", …))` | **YES** — the tui-mode case now fires a real `startBridge` (server + socket + chmod). Non-tui cases unaffected (guard short-circuits before startBridge). | MODIFY: import `stopBridge`, clean up in a `finally` after the tui-mode case |
| `tests/protocol.test.ts` (S4) | NO — types-only (`import type`) | no | unchanged |
| `tests/bridge-lifecycle.test.ts` (S5) | NO — calls `startBridge`/`stopBridge` directly; `TEST 1`'s fake server has only `listen()`/`close()`. | **YES (TEST 1)** — S6 adds `server.on("error", …)` in `startBridge`, so the mocked fake server must grow an `on()` no-op or `startBridge` throws `TypeError: fakeServer.on is not a function`. | MODIFY: add `on() { return fakeServer; }` to the TEST 1 fake server |

So S6 touches **3 existing files** (`pi-editor-bridge.ts` + `mode-guard.test.ts` +
`bridge-lifecycle.test.ts`) and **creates 1 new test** (`bridge-lifecycle-wiring.test.ts`).

## 5. Exact edit locations in `extension/pi-editor-bridge.ts` (grep-verified)

- **L202**: `server = __deps.createServer((sock) => onConnection(sock));`
- **L203**: `server.listen(socketPath);` → **insert `server.on("error", …)` BETWEEN L202 and L203** (attach the listener BEFORE `listen()` so an early bind error is caught; though emit-after-listen is the realistic path, attaching pre-listen is the safe convention).
- **L243**: `// TODO(M2): startBridge(ctx, ctx.cwd);   TODO(S16): advertise via process.env.PI_NVIM_BRIDGE` → **replace** with `startBridge(ctx);` (+ a trailing `// TODO(S16): advertise via process.env.PI_NVIM_BRIDGE`).
- **L246–247**: `pi.on("session_shutdown", (_event: SessionShutdownEvent) => { /* No-op placeholder. TODO(S6/S15): stopBridge() + clear env. */ });` → **replace body** with `stopBridge();` (keep the `_event` param; note env-clear is S16).

## 6. Why wiring is atomic (start + stop together) — scope justification

The item TITLE names only `stopBridge()`. But wiring `stopBridge()` into `session_shutdown`
**alone** (without wiring `startBridge()` into `session_start`) yields a nonsensical
lifecycle: shutdown would tear down a server that was never started (a harmless but
pointless idempotent no-op), and the parent task **P1.M2.T3 "Socket server lifecycle
(start/stop/idempotent)"** would remain incomplete (the server would never actually run in
production). S5 deliberately left the L101 `// TODO(M2): startBridge(...)` call site
intact *specifically for S6* ("S6 lands both wirings atomically" — S5 research §6.3). Hence
S6's coherent, testable deliverable is the **full lifecycle wiring** (start on
session_start + stop on session_shutdown) **plus** the deferred error handler. The
`stopBridge`→`session_shutdown` wiring is the centerpiece (matches the title); the coupled
`startBridge`→`session_start` wiring and the error handler are the atomic completion S5
assigned to S6.

## 7. Validation commands (verified working in S5 research §3 — reused verbatim)

```bash
JITI_REG=/home/dustin/.local/lib/node_modules/@earendil-works/pi-coding-agent/node_modules/jiti/lib/jiti-register.mjs

tsc --noEmit -p extension/tsconfig.json                                     # type gate
node --import "$JITI_REG" extension/tests/bridge-lifecycle-wiring.test.ts   # S6 new suite
node --import "$JITI_REG" extension/tests/mode-guard.test.ts                # S3 (modified)
node --import "$JITI_REG" extension/tests/bridge-lifecycle.test.ts          # S5 (modified)
node --import "$JITI_REG" extension/tests/provider-capture.test.ts          # S2 regression
node --import "$JITI_REG" extension/tests/protocol.test.ts                  # S4 regression
pi --no-extensions -e ./extension/pi-editor-bridge.ts --print "ok"          # load regression (print-mode guard holds → no socket created)
```

The `pi --print` regression is still meaningful post-S6: in print mode the TUI guard
short-circuits BEFORE `startBridge`, so no socket is created, and the run proves the
extension still LOADS and EXITS 0 with the new wiring in place.

## 8. Cross-task notes (for sibling PRPs)

- **P1.M2.T4.S7/S8 (onConnection + JSONL reader):** replaces the no-op `onConnection`
  body; reads the live server via `getServer()` (unchanged by S6). The `server.on('error')`
  handler S6 adds is on the SERVER (listen/bind errors), NOT on individual sockets (S8
  adds per-socket `error`/`close` handling inside `onConnection`).
- **P1.M3.T8.S16 (env advertisement):** extends `startBridge` to WRITE
  `process.env.PI_NVIM_BRIDGE` (using `getSocketPath()`/`getToken()`/`ctx.cwd`/`process.pid`)
  and extends `stopBridge` with `delete process.env.PI_NVIM_BRIDGE`. S6 leaves a
  `// TODO(S16): advertise via process.env.PI_NVIM_BRIDGE` breadcrumb at the session_start
  call site so S16 knows exactly where the write goes.
- **P1.M3.T9.S17 (commandsChanged):** will broadcast on `session_start` when the server is
  already running — S6's wiring makes "server running during session_start" true for
  reload/new/resume/fork, so S17's guard (`if (getServer()) notify`) starts working.
