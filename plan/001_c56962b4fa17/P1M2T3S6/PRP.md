---
name: "P1.M2.T3.S6 — stopBridge(): wire the bridge server lifecycle into pi's session events (start on session_start, stop on session_shutdown) + defensive server error handler"
description: |
  **Wire the bridge socket server into pi's real session lifecycle** inside the existing
  single extension file `extension/pi-editor-bridge.ts` (NO new module, NO tsconfig change).
  Concretely, S6 MODIFIES three things in that file: (1) the `session_start` handler —
  replace the `// TODO(M2): startBridge(ctx, ctx.cwd)` placeholder at L243 with a real
  `startBridge(ctx);` call (the TUI guard at the handler top already protects non-tui
  modes, so this fires the server ONLY in tui mode); (2) the `session_shutdown` handler —
  replace the no-op placeholder at L246–247 with `stopBridge();` (the load-bearing,
  title-named deliverable; `stopBridge()` ALREADY EXISTS — S5 shipped it for idempotent
  re-entry, so S6 REUSES it verbatim and changes ZERO lines in its body); (3) `startBridge`
  — INSERT a `server.on("error", (err) => { console.error(...); stopBridge(); })` handler
  BETWEEN the L202 `server = __deps.createServer(...)` and the L203 `server.listen(...)`,
  because an unhandled `'error'` event on a `net.Server` THROWS and would crash pi (Node
  EventEmitter contract — empirically verified), and S5 explicitly deferred this handler
  to "S6, when wiring". S6 also UPDATES two JSDoc STATUS markers (stopBridge: note
  session_shutdown wiring landed; startBridge: note error handler added + wiring landed)
  and leaves a `// TODO(S16): advertise via process.env.PI_EDITOR_BRIDGE` breadcrumb at the
  session_start call site. S6 then UPDATES two existing test files so the new wiring does
  not break or leak: `tests/mode-guard.test.ts` (S3) — the tui-mode case now fires a REAL
  startBridge, so add `import { stopBridge }` + a `finally { stopBridge(); }` cleanup; and
  `tests/bridge-lifecycle.test.ts` (S5) — TEST 1's mocked fake server must grow a no-op
  `on(_event, _handler) { return fakeServer; }` because S6's `server.on("error", …)` would
  otherwise throw `TypeError: fakeServer.on is not a function`. Finally S6 CREATES
  `tests/bridge-lifecycle-wiring.test.ts` — a `node:test`+jiti suite with 3 tests: (A)
  factory-driven full lifecycle in tui mode (session_start → getServer/listening/socket
  mode 0o600/token 32-hex; session_shutdown → all cleared + socket unlinked); (B) the TUI
  guard still holds (session_start in rpc/json/print creates NO server); (C) the new
  `server.on("error")` handler catches a synthetic `srv.emit("error", …)`, does NOT throw,
  and triggers `stopBridge` (getServer undefined, socket unlinked). This task is NARROW: it
  does **NOT** write or delete `process.env.PI_EDITOR_BRIDGE` (env advertisement is
  **P1.M3.T8.S16** — S6 writes the `// TODO(S16)` breadcrumb only), does **NOT** touch the
  `stopBridge()` BODY (S5 owns it; S6 only calls it), does **NOT** implement
  `onConnection`/JSONL reader/handshake/RPC handlers (S7/S8/S9/S11–S15), does **NOT** add
  per-socket error/close handling (the server-level handler is listen/bind errors only;
  S8 adds per-connection handling), and does **NOT** change `protocol.ts` or `tsconfig.json`.
---

## Goal

**Feature Goal**: Make the bridge socket server **actually run for the lifetime of a pi
session** by wiring `startBridge()` into pi's `session_start` event and `stopBridge()`
into pi's `session_shutdown` event — closing the gap the sibling task S5 deliberately left
open (S5 built `startBridge`/`stopBridge` and proved them idempotent in isolation, but
intentionally kept them UNWIRED so the existing `mode-guard.test.ts` wouldn't fire a real
socket during a unit test). Because an unhandled `'error'` event on a `net.Server` throws
and would crash pi (Node EventEmitter contract — verified), the same task that introduces
the wiring MUST also attach a defensive `server.on("error", …)` handler (S5 explicitly
deferred this to "S6, when wiring"). After S6: in **tui mode** the bridge socket binds on
`session_start` (startup/reload/new/resume/fork) and tears down cleanly on
`session_shutdown` (quit/reload/new/resume/fork); in **rpc/json/print mode** the TUI guard
short-circuits before `startBridge`, so nothing binds; and **a bind/listen failure degrades
to a logged teardown instead of crashing pi**.

**Deliverable** (all under `extension/`):
1. **MODIFY** `extension/pi-editor-bridge.ts` — three surgical edits + two JSDoc marker
   updates + one breadcrumb (see Implementation Tasks for exact line numbers & text):
   - INSERT `server.on("error", …)` between L202 and L203 in `startBridge`.
   - REPLACE the L243 `// TODO(M2): startBridge(ctx, ctx.cwd)` placeholder with
     `startBridge(ctx);` + the S16 breadcrumb comment.
   - REPLACE the L246–247 `session_shutdown` no-op body with `stopBridge();`.
   - UPDATE the `stopBridge`/`startBridge` STATUS JSDoc lines to record S6 landed.
2. **MODIFY** `extension/tests/mode-guard.test.ts` (S3) — add `stopBridge` to the import +
   a `finally { stopBridge(); }` around the tui-mode case (the wiring now fires a real
   server there). Non-tui cases are untouched (guard short-circuits before startBridge).
3. **MODIFY** `extension/tests/bridge-lifecycle.test.ts` (S5) — TEST 1's fake server grows
   a no-op `on()` method (S6's `server.on("error", …)` calls it; without it, the mocked
   test throws `TypeError: fakeServer.on is not a function`).
4. **CREATE** `extension/tests/bridge-lifecycle-wiring.test.ts` — a `node:test`+jiti suite
   (matching S2/S3/S4/S5 conventions) with 3 tests exercising the lifecycle through the
   factory's registered handlers (NOT by calling start/stop directly — that's S5's suite).

**Success Definition**:
- `tsc --noEmit -p extension/tsconfig.json` → exit 0, **no output** (the wiring + error
  handler + the new test type-check under the current tsconfig with NO tsconfig edit).
- The 4 affected/new test files all pass: `bridge-lifecycle-wiring.test.ts` (new, `pass 3`),
  `mode-guard.test.ts` (modified, `fail 0`), `bridge-lifecycle.test.ts` (modified, `fail 0`).
- The 2 untouched suites still pass (regression): `provider-capture.test.ts` (S2),
  `protocol.test.ts` (S4) — `fail 0` each.
- Regression: `pi --no-extensions -e ./extension/pi-editor-bridge.ts --print "ok"` exits 0
  with no error lines AND creates NO socket file in `os.tmpdir()` (the TUI guard
  short-circuits in print mode, so startBridge never runs — proves the wiring is gated and
  the extension still loads cleanly).
- No socket leak / no orphaned `pi-editor-bridge-*.sock` in `os.tmpdir()` after any test
  run (every tui-mode invocation is paired with a `stopBridge()` cleanup).

## User Persona (if applicable)

**Target User**: The bridge-extension author and the downstream implementers of S8
(`onConnection`), S9 (handshake), S11–S14 (RPC handlers), S16 (env advertisement), and S17
(`commandsChanged` broadcast). S6 is the connective tissue that makes every one of those
tasks reachable from a real pi session.

**Use Case**: After S6, running `pi` in a terminal (tui mode) binds the bridge socket on
startup; a Neovim launched as `$EDITOR` (via Ctrl+G) can then (once S16 advertises the env
var + S8/S9 land the protocol) connect to it. Quitting pi (`session_shutdown` reason
`quit`) closes the socket and unlinks the file. Reloading (`/reload`) re-binds a fresh
server without leaking the old one.

**Pain Points Addressed**:
- Without the wiring, the server S5 built is dead code: `getServer()` is always
  `undefined` at runtime, so S8's `onConnection` can never fire and S16 has nothing to
  advertise. S6 is the on-switch.
- Without the `server.on("error")` handler, the first bind/listen hiccup (EACCES on a
  locked-down `TMPDIR`, an `EMFILE` from too many fds, etc.) would crash pi via Node's
  EventEmitter `'error'` contract. S6 makes the bridge degrade gracefully instead.
- Without idempotent re-entry through the wired `session_start`→`startBridge`→(stopBridge
  first), each `/reload`/`/new`/`/resume`/fork would leak a server fd + an orphaned socket
  file. S5's stopBridge-first design — which S6 now actually exercises through the real
  lifecycle — guarantees exactly one live server per session.

## Why

- **Completes the parent task P1.M2.T3 "Socket server lifecycle (start/stop/idempotent)".**
  S5 did the *start* runtime in isolation; S6 does the *wiring* that makes start/stop
  respond to pi's session events and adds the defensive error handler S5 deferred. Until
  S6 lands, P1.M2.T3 is structurally incomplete (the server never runs in production).
- **The item title names `stopBridge()`; the function ALREADY EXISTS.** S5 shipped a
  fully-working, idempotent `stopBridge()` because `startBridge` calls it first for
  idempotent re-entry (it is a hard dependency). S6's title-named deliverable is therefore
  *not* "implement stopBridge" (redundant) but "wire the call to it into `session_shutdown`
  and, atomically, wire `startBridge` into `session_start` + add the deferred error
  handler" — exactly the scope the S5 author enumerated for S6 in
  `P1M2T3S5/research/notes.md` §6. Wiring stop alone (without start) would tear down a
  server that never starts — a pointless no-op — so the two wirings land together.
- **PRD §6.7 requirements checklist** ("survives multiple editor open/close cycles within
  one session; idempotent start/stop; safe across session_start/session_shutdown churn;
  never throws from handlers") is only satisfiable once the lifecycle is wired and the
  error path is handled. S6 is what makes those requirements true at runtime.
- **Zero-dependency, zero-config increment.** All edits are inside the existing single
  file (Node builtins only — `net`/`console.error`/`process` already in scope); the new
  test matches the existing `tests/**/*.ts` glob (no tsconfig change); the error handler
  uses plain `console.error` (no logger dep), honoring PRD §6.7's "no npm runtime deps".

## What

Three surgical code edits + two JSDoc marker updates + one breadcrumb in
`pi-editor-bridge.ts`; two small test updates (`mode-guard.test.ts`, `bridge-lifecycle.test.ts`);
one new test file (`bridge-lifecycle-wiring.test.ts`). No new module, no tsconfig change, no
`protocol.ts` touch, no env-var read or write, no `onConnection`/handshake/handler logic.

### Success Criteria

- [ ] `session_shutdown` handler calls `stopBridge()` (the title deliverable). The
      `stopBridge()` **body is byte-identical to S5's** — S6 only adds the call site.
- [ ] `session_start` handler calls `startBridge(ctx)` AFTER the TUI guard + log +
      `captureProvider(ctx)`, replacing the L243 `// TODO(M2)` placeholder. A trailing
      `// TODO(S16): advertise via process.env.PI_EDITOR_BRIDGE` breadcrumb remains.
- [ ] `startBridge` attaches `server.on("error", (err) => { console.error(...); stopBridge(); })`
      BEFORE `server.listen(...)` (between L202 and L203). The handler does NOT rethrow.
- [ ] In tui mode, invoking the factory's `session_start` handler populates
      `getServer()`/`getSocketPath()`/`getToken()` and leaves a listening socket with
      on-disk mode `0o600`; invoking `session_shutdown` clears all three + unlinks the file.
- [ ] In rpc/json/print mode, invoking `session_start` leaves `getServer()` `undefined`
      (the TUI guard short-circuits before `startBridge` — S3 behavior preserved).
- [ ] Emitting a synthetic `server.emit("error", new Error(...))` does NOT throw and
      results in `getServer() === undefined` (the handler ran `stopBridge`).
- [ ] `mode-guard.test.ts` (S3) imports `stopBridge` and wraps the tui-mode case in
      `try { … } finally { stopBridge(); }`; non-tui cases unchanged.
- [ ] `bridge-lifecycle.test.ts` (S5) TEST 1's fake server has a no-op `on()` returning
      itself; TEST 1 still passes (`pass` includes the mocked createServer/chmod contract).
- [ ] NO `process.env.PI_EDITOR_BRIDGE` read or write anywhere (env is S16; S6 leaves only
      a `// TODO(S16)` comment).
- [ ] NO change to `stopBridge()` body, `captureProvider`/`getProvider`, `onConnection`,
      `__deps`, the getters, `protocol.ts`, or `tsconfig.json`.
- [ ] `tsc --noEmit -p extension/tsconfig.json` → exit 0, no output.
- [ ] `bridge-lifecycle-wiring.test.ts` → 3 tests pass; `mode-guard.test.ts` → `fail 0`;
      `bridge-lifecycle.test.ts` → `fail 0`; `provider-capture.test.ts` + `protocol.test.ts`
      → `fail 0` (regression).
- [ ] `pi --no-extensions -e ./extension/pi-editor-bridge.ts --print "ok"` exits 0, no
      error lines, and leaves NO `pi-editor-bridge-*.sock` in `os.tmpdir()`.

## All Needed Context

### Context Completeness Check

_Pass test_: An agent who has never seen this repo, given the current
`extension/pi-editor-bridge.ts` (post-S5), `extension/protocol.ts` (post-S4),
`extension/tsconfig.json`, the three existing test files, and this PRP, can (1) make the
three exact edits at L202–203 / L243 / L246–247 using the pinned reference text, (2) update
the two test files from the supplied snippets, (3) write the new 3-test suite from the
skeleton, and (4) run the seven exact validation commands to green — with every Node
semantics claim (error-event contract, double-close idempotency, listen-is-async) cited and
empirically verified in `research/notes.md`.

### Documentation & References

```yaml
# MUST READ — the authoritative task analysis for THIS EXACT TASK (S6's scope is enumerated there)
- docfile: plan/001_c56962b4fa17/P1M2T3S5/research/notes.md
  why: §6 "Cross-task notes" enumerates S6's deliverables VERBATIM: "REUSE the stopBridge S5 ships (do NOT recreate it). S6 adds: wire it into session_shutdown; (after S16) add delete process.env.PI_EDITOR_BRIDGE; wire startBridge(ctx) into the session_start handler at the L101 TODO call site; and add server.on('error', ...) so an async listen failure (EADDRINUSE) doesn't crash pi". §1–§5 hold the empirically-verified foundations (frozen node:net namespace → __deps; jiti no export-let live-binding → getters; chmod-after-listen safe; token 32-hex; validation cmds).
  section: "§6 (cross-task notes for S6); §1 (token/chmod/frozen-namespace re-verification); §3 (validation cmds); §5 (design decisions incl. 'S6 lands both wirings atomically')"
  critical: |
    This file is the single source of truth for S6's scope. The PRP implements §6 verbatim.
    S6 does NOT add `delete process.env.PI_EDITOR_BRIDGE` — that is explicitly "(after S16)".

# MUST READ — the sibling PRP that built startBridge/stopBridge (the code S6 wires)
- docfile: plan/001_c56962b4fa17/P1M2T3S5/PRP.md
  why: defines the post-S5 shape of extension/pi-editor-bridge.ts (startBridge/stopBridge/getServer/getSocketPath/getToken/__deps/onConnection-placeholder + the UNWIRED default-export factory). S6's edits are surgical insertions into this exact file. The S5 PRP also pins the exact validation commands and the mode-guard.test.ts coupling rationale ("wiring now would fire a real listen/chmod during a unit test" → S6 must add cleanup).
  section: "Goal; Implementation Patterns (reference startBridge/stopBridge bodies + the default-export factory); Validation Loop (the 7 commands); Anti-Patterns ('Don't recreate stopBridge in S6 — S5 ships it; S6 REUSES it and adds the env-clear')"
  critical: |
    The default-export factory in S5's reference body shows session_start with the
    `// TODO(M2): startBridge(...)` comment and session_shutdown as a no-op — those are the
    EXACT two lines S6 replaces. Cross-reference them line-for-line before editing.

# MUST READ — the current file S6 edits (verify line numbers against THIS, not the S5 PRP)
- file: extension/pi-editor-bridge.ts
  why: the live post-S5 source. S6 edits L202–203 (insert error handler), L243 (wire startBridge), L246–247 (wire stopBridge). Re-grep before editing (line numbers shift if the file changed since this PRP).
  section: "startBridge() (L196–210 region: the `server = __deps.createServer(...)` + `server.listen(...)` lines); the default-export factory (L218–248: session_start TODO call site + session_shutdown no-op); the stopBridge() export (REUSE — do NOT edit its body)"
  critical: |
    stopBridge() ALREADY EXISTS and is idempotent (server?.close() + rmSync(socketPath,{force:true}) + reset 3 vars). S6 changes ZERO lines in its BODY — only adds a CALL to it in session_shutdown, and updates its STATUS JSDoc line. Editing the body = scope violation.

# MUST READ — the empirical re-verification of the error-event contract (the ONE new load-bearing claim)
- docfile: plan/001_c56962b4fa17/P1M2T3S6/research/notes.md
  why: §3 records a fresh Node 26 probe proving: (a) `server.emit("error", err)` with NO listener THROWS; (b) WITH a listener, handler runs and NO throw; (c) calling `srv.close()` twice from inside the handler is a safe no-op (so stopBridge's own `server?.close()` won't choke when the handler calls it). §4 is the affected-test inventory (which suites need updating + why). §5 is the exact edit line numbers. §6 justifies the atomic start+stop wiring scope.
  section: "§3 (error-event re-verification table); §4 (affected-test inventory); §5 (exact edit locations); §6 (scope justification)"
  critical: |
    §4 is essential: it explains WHY mode-guard.test.ts and bridge-lifecycle.test.ts must be
    touched (the former now fires a real server in tui mode; the latter's mocked fake server
    lacks an `on()` method that S6's `server.on("error",…)` requires).

# MUST READ — Node net docs (server 'error' event semantics; listen is async)
- url: https://nodejs.org/api/net.html#event-error
  why: confirms the EventEmitter 'error' contract that makes the handler mandatory: "Emitted when an error occurs. Unlike net.Socket, the 'close' event will not be emitted directly following this event unless server.close() is manually called." And: if an 'error' event has no listener, the process will crash (EventEmitter universal rule). Also confirms `server.listen()` is ASYNC ('listening' emits later) so tests must `await once(server,"listening")` before asserting `listening===true`.
  section: "Class: net.Server → Event: 'error'; server.listen(path[, ...]) (IPC/Unix-domain overload); server.listening (boolean getter)"
  critical: |
    The handler MUST NOT rethrow — PRD §6.7 "never throws from handlers". The handler's job
    is: log (best-effort), then stopBridge() (close + unlink + clear), then return. Do NOT
    re-emit the error or call process.exit. stopBridge() inside the handler is safe because
    double-close is a verified no-op (research §3 claim 3).

# MUST READ — @types/node for the handler's `err` parameter typing
- file: /home/dustin/.local/lib/node_modules/@earendil-works/pi-coding-agent/node_modules/@types/node/net.d.ts
  why: confirms Server extends EventEmitter (so .on('error', cb) type-checks) and the 'error' listener signature is (err: Error) => void.
  section: "L587 `class Server extends EventEmitter`; search 'on(event: \"error\"' / the inherited EventEmitter.on overloads"
  critical: |
    `server.on("error", (err) => {...})` infers `err: Error` (no annotation needed) under
    strict mode. Annotate `(err: Error)` explicitly only if the inline form doesn't infer;
    both compile. The handler returns void (implicit).

# SUPPORTING — the test files S6 modifies + their conventions
- file: extension/tests/mode-guard.test.ts
  why: S3's tui-mode test invokes the session_start handler DIRECTLY with a fake ctx. Once S6 wires startBridge into that handler, the tui case fires a REAL net.createServer+listen+chmod. S6 adds `stopBridge` to the import + a `finally { stopBridge(); }` cleanup so the guard test leaks nothing. The non-tui cases are UNCHANGED (the TUI guard returns before startBridge).
  section: "the `test(\"session_start proceeds ... in tui mode\", …)` block; the `import bridgeFactory from \"../pi-editor-bridge.ts\"` line"
  critical: |
    Do NOT restructure the test's assertions — it still proves the guard (tui proceeds,
    non-tui short-circuits). Only add cleanup. The fake ctx `{mode,ui:{addAutocompleteProvider}}`
    is fine for startBridge too (startBridge does `void ctx` and reads only tmpdir/process.platform).

- file: extension/tests/bridge-lifecycle.test.ts
  why: S5's TEST 1 mocks `__deps.createServer` → a fake server with ONLY `listen()`/`close()`. S6 adds `server.on("error", …)` in startBridge, so the fake server needs a no-op `on()` or startBridge throws `TypeError: fakeServer.on is not a function`. Add `on(_event, _handler) { return fakeServer; }` to the fake server object.
  section: "TEST 1's `const fakeServer = { listening, listen(arg){...}, close(){...} }` literal"
  critical: |
    Return `fakeServer` from `on()` (EventEmitter.on returns `this` for chaining; harmless
    if unused). Tests 2/3/4 use the REAL net.Server (which has `.on`) — they need NO change.

# SUPPORTING — provider-capture.test.ts (S2) & protocol.test.ts (S4): UNCHANGED, regression-only
- file: extension/tests/provider-capture.test.ts
  why: confirms S2 calls captureProvider/getProvider DIRECTLY — it never invokes the factory or the session_start handler, so S6's wiring cannot affect it. Re-run only as a regression.
  section: "whole file (direct captureProvider calls; no factory invocation)"

- file: extension/tests/protocol.test.ts
  why: S4 is types-only (`import type {…}`). S6 does not touch protocol.ts, so this suite is a pure regression canary.
  section: "whole file (type imports + compile-time assertions)"

# SUPPORTING — PRD lifecycle + security context
- docfile: PRD.md
  why: §6.2 (Events used: session_start [startup,reload,new,resume,fork] → (re)capture/start; session_shutdown [quit,reload,new,resume,fork] → close/unlink); §6.6 (default export: startBridge on session_start, stopBridge on session_shutdown); §6.7 (requirements: idempotent start/stop; survives multiple cycles; never throws from handlers); §12 (token is the real auth boundary; never log it — note: S6's error handler logs the Error, NOT the token; do not include getToken()/getSocketPath() in the error message)
  section: "§6.2 (event→action table), §6.6 (default export skeleton), §6.7 (req checklist), §12 (security: token handling)"
  critical: |
    §6.2 is why idempotency matters: reload/new/resume/fork fire BOTH session_start AND
    session_shutdown, so a single reload re-runs the whole lifecycle. startBridge's
    stopBridge-first + stopBridge's idempotency (both S5) handle this; S6 just routes the
    events. §12: the error handler logs the Error object, not the descriptor — never echo
    the token in a log line.
```

### Current Codebase tree (post-S5 baseline — S6 edits pi-editor-bridge.ts + 2 tests, adds 1 test)

```bash
extension/
├── pi-editor-bridge.ts            # (S1+S2+S3+S5) default-export factory: session_start (TUI guard + log + captureProvider + UNWIRED `// TODO(M2): startBridge(...)` @L243) + session_shutdown (no-op @L246-247); captureProvider/getProvider/liveProvider; startBridge/stopBridge/getServer/getSocketPath/getToken/__deps/onConnection-placeholder. S6 EDITS this file (3 surgical edits + JSDoc + breadcrumb).
├── protocol.ts                    # (S4) type-only JSON-RPC contract. S6 does NOT touch it.
├── tsconfig.json                  # (S1+S2+S4) include=["pi-editor-bridge.ts","protocol.ts","tests/**/*.ts"]. S6 does NOT edit (new test matches tests/**/*.ts).
└── tests/
    ├── provider-capture.test.ts   # (S2) tests captureProvider directly. S6 does NOT touch (regression only).
    ├── mode-guard.test.ts         # (S3) invokes session_start handler directly. S6 MODIFIES (add stopBridge import + finally cleanup on the tui case).
    ├── protocol.test.ts           # (S4) types-only. S6 does NOT touch (regression only).
    └── bridge-lifecycle.test.ts   # (S5) tests startBridge/stopBridge directly. S6 MODIFIES (TEST 1 fake server += no-op on()).
# plan/ holds planning artifacts only — no other source code
```

### Desired Codebase tree with files to be added/modified

```bash
extension/
├── pi-editor-bridge.ts            # (MODIFY) 3 edits: insert server.on("error") in startBridge (L202-203); wire startBridge into session_start (L243); wire stopBridge into session_shutdown (L246-247). + 2 JSDoc STATUS marker updates + 1 // TODO(S16) breadcrumb.
├── protocol.ts                    # (UNCHANGED — S4)
├── tsconfig.json                  # (UNCHANGED)
└── tests/
    ├── provider-capture.test.ts   # (UNCHANGED — S2 regression)
    ├── mode-guard.test.ts         # (MODIFY — S3) add `stopBridge` import; wrap tui-mode case in try/finally with stopBridge() cleanup.
    ├── protocol.test.ts           # (UNCHANGED — S4 regression)
    ├── bridge-lifecycle.test.ts   # (MODIFY — S5) TEST 1 fake server += `on(_e,_h){ return fakeServer; }` no-op.
    └── bridge-lifecycle-wiring.test.ts  # (CREATE) node:test+jiti: factory-driven full lifecycle (tui); TUI guard (non-tui); error handler (synthetic emit).
```

**File responsibilities**
- `extension/pi-editor-bridge.ts` — gains the session_start/startBridge and
  session_shutdown/stopBridge wirings + the server error handler. The default-export
  factory finally does what its JSDoc always promised (PRD §6.6). `stopBridge`/`startBridge`
  bodies are UNCHANGED (S5 owns them); S6 only adds call sites + the error listener.
- `extension/tests/mode-guard.test.ts` — keeps proving the TUI guard; now also cleans up
  the real server the tui case creates (so the guard test is leak-free post-wiring).
- `extension/tests/bridge-lifecycle.test.ts` — keeps proving the direct start/stop contract
  (S5); the mocked fake server grows `on()` so S6's `server.on("error",…)` type/run-checks.
- `extension/tests/bridge-lifecycle-wiring.test.ts` — the S6 contract gate: proves the
  factory's registered handlers actually drive a real server lifecycle (start→listening→
  shutdown→cleared) in tui mode, that the TUI guard still suppresses it in non-tui mode,
  and that the error handler degrades instead of crashing.

### Known Gotchas of our codebase & Library Quirks

```typescript
// CRITICAL (verified, research §3): an unhandled 'error' event on a net.Server THROWS and
//   crashes the process (Node EventEmitter universal contract). Once startBridge is wired
//   into session_start, a bind/listen failure (EADDRINUSE/EACCES/EMFILE) WOULD crash pi.
//   RESOLUTION: attach `server.on("error", (err)=>{ console.error(...); stopBridge(); })`
//   BEFORE server.listen(). The handler MUST NOT rethrow (PRD §6.7).

// CRITICAL (verified, research §3): calling srv.close() a SECOND time (e.g. stopBridge's
//   `server?.close()` running after the error handler already called stopBridge→close) is
//   a safe no-op. So the error handler can freely call stopBridge() — idempotency holds.

// CRITICAL (verified, S5 research §1.1): the `node:net` namespace is FROZEN, so the bridge
//   uses the `__deps` plain-object seam for createServer/chmodSync. S6's `server.on(...)`
//   is NOT a builtin call — it's a method on the Server instance returned by
//   __deps.createServer. In production that's a real net.Server (has .on). In S5's mocked
//   TEST 1, __deps.createServer returns a hand-rolled fake with only listen()/close() — so
//   S6 MUST add a no-op on() to that fake or startBridge throws mid-mock. (research §4)

// GOTCHA: listen() is ASYNC ('listening' emits later). Tests asserting server.listening
//   === true must `await once(server, "listening")` FIRST. The error handler is attached
//   BEFORE listen() so it also catches an error emitted during the async bind.

// GOTCHA: the TUI guard at the TOP of the session_start handler (`if (ctx.mode !== "tui")
//   return;`) runs BEFORE startBridge. So in non-tui modes startBridge never executes → no
//   socket, no chmod, no log line (S3 behavior preserved). S6's session_start wiring MUST
//   be placed AFTER captureProvider(ctx) (the existing happy-path tail), so it inherits
//   the guard automatically.

// GOTCHA: the fake ctx in mode-guard.test.ts ({mode,ui:{addAutocompleteProvider}}) is safe
//   for startBridge — startBridge does `void ctx` and reads only os.tmpdir()/process.platform.
//   So wiring startBridge into the handler does NOT break the guard test's assertions; it
//   only creates a real server that needs cleanup (hence the finally{stopBridge()}).

// GOTCHA: S6 writes NO process.env.PI_EDITOR_BRIDGE and adds NO `delete` of it. The env
//   advertisement (write) is P1.M3.T8.S16; the matching delete is "(after S16)". S6 leaves
//   only a `// TODO(S16): advertise via process.env.PI_EDITOR_BRIDGE` breadcrumb at the
//   session_start call site so S16 knows where the write belongs.

// GOTCHA: the server.on("error") handler logs the Error via console.error. Do NOT include
//   getToken()/getSocketPath() in that message — PRD §12: "Never log the token." The Error
//   itself is safe to log (it carries the errno/message, not the descriptor).

// GOTCHA: node:test runs top-level tests SEQUENTIALLY by definition order (do NOT enable
//   concurrency). The bridge module is a single shared singleton; sequential execution is
//   required so tests don't race on getServer()/getSocketPath()/getToken(). Every tui-mode
//   invocation in the new suite pairs with a stopBridge() cleanup (finally or tail).

// STYLE: TABS for indentation (match the existing pi-editor-bridge.ts + S5 test files).
//   `import type` for type-only imports; reuse the inline `type` modifier where useful.
//   Mode-A JSDoc with a STATUS marker + forward refs on every edited export.
```

## Implementation Blueprint

### Data models and structure

S6 introduces **no new data types** and **no new module state**. The data model is
unchanged from S5: the module singletons `server`/`socketPath`/`token` (read only via the
getters) plus `__deps`. S6 only changes **control flow** (which events trigger
start/stop) and adds one **event listener** (server 'error'). The protocol types in
`protocol.ts` are untouched.

### Implementation Tasks (ordered by dependencies)

```yaml
Task 1: MODIFY extension/pi-editor-bridge.ts — INSERT the server 'error' handler in startBridge
  - LOCATE (grep-verify first): the two consecutive lines inside startBridge —
        server = __deps.createServer((sock) => onConnection(sock));   # ~L202
        server.listen(socketPath);                                    # ~L203
  - INSERT (between those two lines, BEFORE server.listen):
        server.on("error", (err: Error) => {
            console.error(`pi-editor-bridge: socket server error (terminating bridge): ${err}`);
            stopBridge();
        });
  - WHY BEFORE listen: the listener must be attached before the async bind so it also
      catches an error emitted during listen(). (Node attaches 'listening'/'error' on the
      next tick; ordering the .on() before .listen() is the safe convention.)
  - WHY (err: Error): explicit annotation (EventEmitter infers it, but be explicit for the
      `strict` tsconfig). Handler returns void (implicit); MUST NOT rethrow (PRD §6.7).
  - FOLLOW: TAB indentation; keep the JSDoc density of the surrounding code.
  - DO NOT: log getToken()/getSocketPath() in the message (PRD §12 — never log the token);
      rethrow; call process.exit; touch __deps (the listener is on the Server instance, not
      a builtin).

Task 2: MODIFY extension/pi-editor-bridge.ts — WIRE startBridge into session_start
  - LOCATE (grep-verify first): inside the default-export factory's `pi.on("session_start", …)`:
        // TODO(M2): startBridge(ctx, ctx.cwd);   TODO(S16): advertise via process.env.PI_EDITOR_BRIDGE   # ~L243
  - REPLACE that single comment line with:
        startBridge(ctx);
        // TODO(S16): advertise via process.env.PI_EDITOR_BRIDGE (env write is S16's job).
  - WHY here (after captureProvider(ctx), inside the post-guard happy path): the TUI guard
      at the handler top (`if (ctx.mode !== "tui") return;`) protects non-tui modes, so
      startBridge fires ONLY in tui mode. Placement after captureProvider matches the PRD
      §6.6 default-export skeleton order.
  - DO NOT: pass ctx.cwd as a 2nd arg (startBridge's signature is startBridge(ctx); S16 will
      read ctx.cwd inside startBridge later); write process.env (S16); move the guard.

Task 3: MODIFY extension/pi-editor-bridge.ts — WIRE stopBridge into session_shutdown (TITLE DELIVERABLE)
  - LOCATE (grep-verify first): inside the default-export factory:
        pi.on("session_shutdown", (_event: SessionShutdownEvent) => {
            // No-op placeholder. TODO(S6/S15): stopBridge() + clear env.   # ~L246-247
        });
  - REPLACE the comment line in the body with:
        stopBridge(); // idempotent teardown: close server, unlink socket, clear state.
        // NOTE: clearing process.env.PI_EDITOR_BRIDGE belongs to S16 (which writes it).
  - WHY: stopBridge() ALREADY EXISTS and is idempotent (S5). S6 only adds the call site.
      `_event` stays (unused param; tsconfig has no noUnusedParameters, but keep it for
      signature fidelity).
  - DO NOT: edit the stopBridge() BODY (S5 owns it; S6 changes zero lines there); add
      `delete process.env.PI_EDITOR_BRIDGE` (S16); remove the _event param.

Task 4: MODIFY extension/pi-editor-bridge.ts — UPDATE the two STATUS JSDoc markers + breadcrumb
  - In stopBridge()'s JSDoc STATUS line: append a note that S6 wired it into session_shutdown
      (env-clear still "(after S16)"). e.g. change "S6 should REUSE this function ... wire it
      into session_shutdown" past-tense: "S6 REUSES this function (wired into session_shutdown
      in P1.M2.T3.S6); the env-clear is deferred to S16."
  - In startBridge()'s JSDoc STATUS bullets: mark the wiring + error handler as DONE in S6
      (remove the "deferred" framing for those two bullets; keep the S16 env bullet deferred).
  - These are documentation-only edits; they carry no behavior. Keep them faithful + concise.
  - DO NOT: rewrite the whole JSDoc blocks; just update the STATUS sentences.

Task 5: MODIFY extension/tests/mode-guard.test.ts — clean up the tui-mode case
  - CHANGE the import line from:
        import bridgeFactory from "../pi-editor-bridge.ts";
    to:
        import bridgeFactory, { stopBridge } from "../pi-editor-bridge.ts";
  - WRAP the tui-mode test body in try/finally:
        test("session_start proceeds (calls addAutocompleteProvider) in tui mode", () => {
            const handler = captureSessionStartHandler();
            let called = false;
            try {
                handler(STARTUP_EVENT, makeCtx("tui", () => { called = true; }));
                assert.equal(called, true, "addAutocompleteProvider MUST be called in tui mode ...");
            } finally {
                // S6 wires startBridge() into session_start, so a tui-mode invocation now
                // creates a REAL socket server. Clean it up so this guard test leaks nothing.
                stopBridge();
            }
        });
  - WHY: the tui handler now fires startBridge (real createServer+listen+chmod). Without
      cleanup the test leaks a server fd + socket file. The non-tui tests are UNCHANGED
      (the TUI guard returns before startBridge, so they never create a server).
  - DO NOT: alter the two non-tui assertions or the helper functions; change what the test
      PROVES (it still proves the guard); enable concurrency.

Task 6: MODIFY extension/tests/bridge-lifecycle.test.ts — fake server gains on()
  - LOCATE TEST 1's fake server literal:
        const fakeServer = {
            listening: false,
            listen(arg: string) { listenArg = arg; return fakeServer; },
            close() { /* no-op */ },
        };
  - ADD a no-op on() method (S6's server.on("error",…) calls it):
        const fakeServer = {
            listening: false,
            listen(arg: string) { listenArg = arg; return fakeServer; },
            close() { /* no-op */ },
            on(_event: string, _handler: (err: Error) => void) { return fakeServer; }, // S6: startBridge attaches server.on("error",…)
        };
  - WHY: without on(), startBridge's new server.on("error",…) throws
      `TypeError: fakeServer.on is not a function` inside the mocked TEST 1. Tests 2/3/4 use
      the REAL net.Server (has .on) — they need NO change.
  - DO NOT: touch TESTS 2/3/4; change the assertion logic; remove the realCreateServer/
      realChmodSync snapshots.

Task 7: CREATE extension/tests/bridge-lifecycle-wiring.test.ts (node:test + jiti)
  - IMPORT: `import { test } from "node:test"; import assert from "node:assert/strict";`
      `import { statSync, existsSync } from "node:fs"; import { once } from "node:events";`
      `import type { ExtensionAPI, ExtensionContext, SessionStartEvent, SessionShutdownEvent } from "@earendil-works/pi-coding-agent";`
      `import bridgeFactory, { getServer, getSocketPath, getToken, stopBridge } from "../pi-editor-bridge.ts";`
  - HELPER captureHandlers(): run bridgeFactory(fakePi) where fakePi.on records BOTH the
      session_start and session_shutdown handlers; assert both are functions; return
      {startHandler, shutdownHandler}. (Mirror mode-guard.test.ts's captureSessionStartHandler,
      extended to also capture session_shutdown.)
  - HELPER makeCtx(mode): returns {mode, ui:{addAutocompleteProvider: ()=>{}}} cast to
      ExtensionContext (startBridge does `void ctx`; the fake ui is enough).
  - TEST A (full lifecycle, tui): captureHandlers(); startHandler({reason:"startup"}, makeCtx("tui"));
      assert getServer()/getSocketPath() truthy, getToken() matches /^[0-9a-f]{32}$/;
      `await once(getServer()!,"listening")`; assert getServer()!.listening===true;
      assert (statSync(getSocketPath()!).mode & 0o777)===0o600;
      shutdownHandler({} as SessionShutdownEvent); assert getServer()===undefined,
      getSocketPath()===undefined, getToken()===undefined, existsSync(path)===false.
  - TEST B (TUI guard, non-tui): for mode in ["rpc","json","print"]:
      startHandler({reason:"startup"} as SessionStartEvent, makeCtx(mode));
      assert getServer()===undefined; (and assert.doesNotThrow around the loop — the guard
      returns before startBridge). Cleanup: stopBridge() at the end (idempotent, harmless).
  - TEST C (error handler): startHandler(tui); const srv=getServer(); await once(srv,"listening");
      const path=getSocketPath(); assert.doesNotThrow(()=>srv!.emit("error", new Error("synthetic EADDRINUSE")));
      assert getServer()===undefined (handler ran stopBridge); assert existsSync(path!)===false;
      `await new Promise(r=>setTimeout(r,30))` (let async close settle); stopBridge() (final idempotent cleanup).
  - SHARED-STATE CAVEAT: module singleton → tests run SEQUENTIALLY (node:test default); do
      NOT enable concurrency. Each tui test cleans up (finally or tail stopBridge()).
  - FOLLOW: TAB indentation; reuse the jiti register hook path from S5. NAMING: descriptive
      test titles; no describe.
  - PLACEMENT: extension/tests/bridge-lifecycle-wiring.test.ts (matches tests/**/*.ts → NO tsconfig edit).

Task 8: VALIDATE — run the seven validation commands; fix until all green
  - RUN (Level 1): `tsc --noEmit -p extension/tsconfig.json` (expect exit 0, no output)
  - RUN (Level 2): `node --import "$JITI_REG" extension/tests/bridge-lifecycle-wiring.test.ts`
      (expect exit 0, fail 0, pass 3 — ignore the benign jiti DEP0205 on stderr)
  - RUN (Level 2): `node --import "$JITI_REG" extension/tests/mode-guard.test.ts` (fail 0)
  - RUN (Level 2): `node --import "$JITI_REG" extension/tests/bridge-lifecycle.test.ts` (fail 0)
  - RUN (Level 2 regression): provider-capture.test.ts + protocol.test.ts (each fail 0)
  - RUN (Level 3): `pi --no-extensions -e ./extension/pi-editor-bridge.ts --print "ok"`
      exits 0, no error lines, and NO pi-editor-bridge-*.sock created in os.tmpdir()
```

### Implementation Patterns & Key Details

```typescript
// === extension/pi-editor-bridge.ts — EDIT 1: the server 'error' handler (insert in startBridge,
//     BETWEEN `server = __deps.createServer((sock) => onConnection(sock));` and `server.listen(socketPath);`) ===
	server = __deps.createServer((sock) => onConnection(sock));
	// Defensive: an unhandled 'error' event (e.g. EADDRINUSE, EACCES binding tmpdir, EMFILE)
	// on a net.Server THROWS and would crash the process (Node EventEmitter contract — verified
	// in P1M2T3S6/research §3). Because startBridge is wired into session_start (S6), such a
	// failure MUST NOT crash pi (PRD §6.7 "never throws from handlers"). Handle it: log the
	// Error (NOT the token/descriptor — PRD §12), then stopBridge so we don't leave a half-bound
	// server or orphaned socket, and do NOT rethrow. Double-close is a safe no-op (verified),
	// so stopBridge()'s own `server?.close()` won't choke when this handler calls it first.
	server.on("error", (err: Error) => {
		console.error(`pi-editor-bridge: socket server error (terminating bridge): ${err}`);
		stopBridge();
	});
	server.listen(socketPath);

// === extension/pi-editor-bridge.ts — EDIT 2: wire startBridge into session_start
//     (inside `pi.on("session_start", (event, ctx) => { ... })`, AFTER captureProvider(ctx)) ===
		captureProvider(ctx);
		startBridge(ctx);
		// TODO(S16): advertise via process.env.PI_EDITOR_BRIDGE (env write is S16's job).

// === extension/pi-editor-bridge.ts — EDIT 3: wire stopBridge into session_shutdown (TITLE DELIVERABLE) ===
	pi.on("session_shutdown", (_event: SessionShutdownEvent) => {
		stopBridge(); // idempotent teardown: close server, unlink socket, clear state.
		// NOTE: clearing process.env.PI_EDITOR_BRIDGE belongs to S16 (which writes it).
	});

// === extension/pi-editor-bridge.ts — EDIT 4 (docs): update the two STATUS markers ===
//   stopBridge() JSDoc STATUS line — change the forward-looking "S6 should REUSE this function
//   ... wire it into session_shutdown" to past-tense: "S6 REUSES this function (P1.M2.T3.S6 wired
//   it into session_shutdown); the env-clear is deferred to S16."
//   startBridge() JSDoc STATUS bullets — mark the session_start wiring + the error handler as
//   DONE in S6; keep the S16 env-advertisement bullet deferred.
```

```typescript
// === extension/tests/mode-guard.test.ts — EDIT: add stopBridge import + finally cleanup ===
import bridgeFactory, { stopBridge } from "../pi-editor-bridge.ts";

// ... (captureSessionStartHandler + makeCtx unchanged) ...

test("session_start proceeds (calls addAutocompleteProvider) in tui mode", () => {
	const handler = captureSessionStartHandler();
	let called = false;
	try {
		handler(STARTUP_EVENT, makeCtx("tui", () => {
			called = true;
		}));
		assert.equal(
			called,
			true,
			"addAutocompleteProvider MUST be called in tui mode (happy path through the handler)",
		);
	} finally {
		// S6 wires startBridge() into the session_start handler, so a tui-mode invocation now
		// creates a REAL socket server (createServer+listen+chmod). Clean it up so this guard
		// test leaks nothing. (Non-tui cases never reach startBridge — the guard returns first.)
		stopBridge();
	}
});
// (the two non-tui tests are UNCHANGED — the guard short-circuits before startBridge.)
```

```typescript
// === extension/tests/bridge-lifecycle.test.ts — EDIT: TEST 1 fake server gains on() ===
	const fakeServer = {
		listening: false,
		listen(arg: string) {
			listenArg = arg;
			return fakeServer;
		},
		close() {
			/* no-op */
		},
		on(_event: string, _handler: (err: Error) => void) {
			return fakeServer; // S6: startBridge attaches server.on("error", …); no-op in the mock.
		},
	};
// (TESTS 2/3/4 use the REAL net.Server, which already has .on — no change.)
```

```typescript
// === extension/tests/bridge-lifecycle-wiring.test.ts (CREATE — node:test + jiti) ===
import { test } from "node:test";
import assert from "node:assert/strict";
import { statSync, existsSync } from "node:fs";
import { once } from "node:events";
import type {
	ExtensionAPI,
	ExtensionContext,
	SessionStartEvent,
	SessionShutdownEvent,
} from "@earendil-works/pi-coding-agent";
import bridgeFactory, {
	getServer,
	getSocketPath,
	getToken,
	stopBridge,
} from "../pi-editor-bridge.ts";

type StartHandler = (event: SessionStartEvent, ctx: ExtensionContext) => void;
type ShutdownHandler = (event: SessionShutdownEvent) => void;

// Run the factory with a fake pi that records BOTH session_start and session_shutdown handlers.
function captureHandlers(): { startHandler: StartHandler; shutdownHandler: ShutdownHandler } {
	let startHandler: StartHandler | undefined;
	let shutdownHandler: ShutdownHandler | undefined;
	const fakePi = {
		on(event: string, h: StartHandler | ShutdownHandler) {
			if (event === "session_start") startHandler = h as StartHandler;
			if (event === "session_shutdown") shutdownHandler = h as ShutdownHandler;
		},
	} as unknown as ExtensionAPI;

	bridgeFactory(fakePi);

	assert.ok(typeof startHandler === "function", "factory must register a session_start handler");
	assert.ok(typeof shutdownHandler === "function", "factory must register a session_shutdown handler");
	return { startHandler: startHandler!, shutdownHandler: shutdownHandler! };
}

// Minimal ctx: .mode (for the TUI guard) + .ui.addAutocompleteProvider (for captureProvider).
function makeCtx(mode: ExtensionContext["mode"]): ExtensionContext {
	return {
		mode,
		ui: { addAutocompleteProvider: () => {} },
	} as unknown as ExtensionContext;
}

const STARTUP = { reason: "startup" } as SessionStartEvent;

// ============================================================================
// TEST A — FULL LIFECYCLE (tui): session_start binds a listening 0o600 socket;
// session_shutdown tears it down (server closed, socket unlinked, state cleared).
// ============================================================================
test("session_start(tui) binds a listening 0o600 server; session_shutdown tears it down", async () => {
	const { startHandler, shutdownHandler } = captureHandlers();
	startHandler(STARTUP, makeCtx("tui"));
	const srv = getServer();
	const path = getSocketPath();
	assert.ok(srv, "getServer() populated after session_start(tui)");
	assert.ok(path, "getSocketPath() populated after session_start(tui)");
	assert.match(getToken() ?? "", /^[0-9a-f]{32}$/, "token must be 32 lowercase hex chars");

	await once(srv!, "listening"); // listen() is async; wait for the bind.
	assert.equal(srv!.listening, true, "server must be listening after 'listening'");
	assert.equal(statSync(path!).mode & 0o777, 0o600, "socket file mode must be exactly 0o600");

	shutdownHandler({} as SessionShutdownEvent); // the title deliverable: stopBridge() fires here
	assert.equal(getServer(), undefined, "getServer() cleared after session_shutdown");
	assert.equal(getSocketPath(), undefined, "getSocketPath() cleared after session_shutdown");
	assert.equal(getToken(), undefined, "getToken() cleared after session_shutdown");
	assert.equal(existsSync(path), false, "socket file must be unlinked after session_shutdown");
});

// ============================================================================
// TEST B — TUI GUARD (non-tui): the guard at the handler top returns BEFORE
// startBridge, so NO server is created in rpc/json/print mode (S3 behavior preserved).
// ============================================================================
test("session_start(non-tui) creates NO server — TUI guard intact (S3 regression)", () => {
	const { startHandler } = captureHandlers();
	for (const mode of ["rpc", "json", "print"] as const) {
		assert.doesNotThrow(() => startHandler(STARTUP, makeCtx(mode)));
		assert.equal(getServer(), undefined, `no server must exist after session_start(${mode})`);
	}
	stopBridge(); // idempotent tail cleanup (no-op here, but defensive)
});

// ============================================================================
// TEST C — ERROR HANDLER: a synthetic server 'error' does NOT throw (the handler catches
// it) and triggers stopBridge (getServer cleared, socket unlinked). Proves the deferred
// S6 handler works + never crashes pi.
// ============================================================================
test("server 'error' event is handled (no crash) and triggers stopBridge", async () => {
	const { startHandler } = captureHandlers();
	startHandler(STARTUP, makeCtx("tui"));
	const srv = getServer();
	const path = getSocketPath();
	assert.ok(srv && path);
	await once(srv!, "listening");

	// With the handler attached by S6, emitting 'error' MUST NOT throw (Node would otherwise
	// crash) and MUST trigger stopBridge (getServer cleared, socket unlinked).
	assert.doesNotThrow(
		() => srv!.emit("error", new Error("synthetic EADDRINUSE")),
		"emitting 'error' with a handler attached must not throw",
	);
	assert.equal(getServer(), undefined, "getServer() cleared by the error handler's stopBridge()");
	assert.equal(existsSync(path!), false, "socket file unlinked by the error handler's stopBridge()");

	// Let the async server.close() (queued by stopBridge) settle, then a final idempotent cleanup.
	await new Promise((r) => setTimeout(r, 30));
	stopBridge();
});
```

### Integration Points

```yaml
NO new external integration points. S6 connects EXISTING internal seams to pi's lifecycle:
  - session_start handler → startBridge(ctx)   (was an unwired TODO; now fires after the TUI guard)
  - session_shutdown handler → stopBridge()     (was a no-op placeholder; now the title deliverable)
  - startBridge → server.on("error", stopBridge) (new defensive listener on the Server instance)
INTERNAL seams (unchanged by S6; consumed by later tasks):
  - getServer()      → S8 attaches the onConnection reader/dispatcher to the live server.
  - getToken()       → S9 hello handshake compares the client token against this.
  - getSocketPath()  → S16 BridgeDescriptor.path (S16 also WRITES process.env.PI_EDITOR_BRIDGE here).
  - startBridge(ctx) → S16 extends it to write the BridgeDescriptor (ctx.cwd dereferenced there).
  - stopBridge()     → S16 extends it with `delete process.env.PI_EDITOR_BRIDGE`.
NO tsconfig change:
  - The new test matches the existing tests/**/*.ts glob (already in include).
  - server.on("error", (err:Error)=>...) type-checks: Server extends EventEmitter (@types/node net.d.ts:587).
  - SessionShutdownEvent is ALREADY imported (L27); no new @earendil-works/* import.
NO process.env change:
  - S6 writes/reads NOTHING in process.env. Only a // TODO(S16) breadcrumb comment is added.
```

## Validation Loop

### Level 1: Syntax & Style (Immediate Feedback) — THE TYPE GATE

```bash
# Type-check the edited pi-editor-bridge.ts + protocol.ts + all tests via the paths-mapped
# dev tsconfig. The load-bearing checks for S6: `server.on("error", (err:Error)=>...)`
# compiles (Server extends EventEmitter); the session_start/session_shutdown handler edits
# keep their (event, ctx)/(event) signatures; the new test's handler captures + casts type-check.
tsc --noEmit -p extension/tsconfig.json
# Expected: exit 0, NO output.

# Indentation sanity (house style is TABS):
grep -nP '^    ' extension/pi-editor-bridge.ts extension/tests/bridge-lifecycle-wiring.test.ts \
  && echo "WARN: space-indent lines found" || echo "indent OK (tabs)"

# Confirm S6 did NOT write/read process.env.PI_EDITOR_BRIDGE (env is S16; S6 leaves only a comment):
grep -nE 'process\.env\.(PI_EDITOR_BRIDGE|BRIDGE_ENV)' extension/pi-editor-bridge.ts \
  && echo "FAIL: S6 touched the env var (out of scope — S16)" \
  || echo "PASS: no PI_EDITOR_BRIDGE env access in code"

# Confirm S6 did NOT change the stopBridge() BODY (S5 owns it; S6 only calls it). The body
# is the `server?.close()` + `rmSync` + 3 resets — grep for it and confirm it's intact:
grep -nE 'server\?\.close\(\)|rmSync\(socketPath' extension/pi-editor-bridge.ts \
  && echo "PASS: stopBridge body intact (S5)" || echo "FAIL: stopBridge body missing"

# Confirm the session_start wiring landed (the L243 TODO is gone, replaced by a real call):
grep -n 'startBridge(ctx)' extension/pi-editor-bridge.ts \
  && echo "PASS: startBridge wired into a handler" || echo "FAIL: startBridge(ctx) call missing"

# Confirm the session_shutdown wiring landed:
grep -nE 'session_shutdown' -A2 extension/pi-editor-bridge.ts | grep -q 'stopBridge()' \
  && echo "PASS: stopBridge wired into session_shutdown" \
  || echo "FAIL: stopBridge not called in session_shutdown"

# Confirm the error handler landed and does NOT rethrow (best-effort grep):
grep -nE 'server\.on\("error"' extension/pi-editor-bridge.ts \
  && echo "PASS: server error handler attached" || echo "FAIL: no server.on('error',…)"
```

### Level 2: Unit Tests (Component Validation) — THE CONTRACT GATE

```bash
# Zero-dep TS runner: Node's built-in node:test, jiti as the TS loader (borrowed from
# pi-coding-agent — SAME path S2/S3/S4/S5 use).
JITI_REG=/home/dustin/.local/lib/node_modules/@earendil-works/pi-coding-agent/node_modules/jiti/lib/jiti-register.mjs

# The S6 new suite (the lifecycle wiring contract):
node --import "$JITI_REG" extension/tests/bridge-lifecycle-wiring.test.ts
# Expected: exit 0; `pass 3` and `fail 0`.

# The two suites S6 MODIFIED (must still pass with the wiring):
node --import "$JITI_REG" extension/tests/mode-guard.test.ts          # S3 (modified) — expect fail 0
node --import "$JITI_REG" extension/tests/bridge-lifecycle.test.ts    # S5 (modified) — expect fail 0

# The two untouched suites (pure regression — S6 changes nothing they read):
node --import "$JITI_REG" extension/tests/provider-capture.test.ts    # S2 — expect fail 0
node --import "$JITI_REG" extension/tests/protocol.test.ts            # S4 — expect fail 0
# NOTE: jiti on Node 26 prints a harmless DEP0205 DeprecationWarning
#   ("module.register() is deprecated") to STDERR — IGNORE it; judge by exit code + pass/fail.
```

### Level 3: Integration Testing (System Validation) — THE REGRESSION GATE

```bash
# In print mode the TUI guard short-circuits BEFORE startBridge, so the wiring does NOT
# create a socket. This run proves: (a) the extension still LOADS via jiti with the new
# wiring in place; (b) no error/throw during handler registration; (c) NO socket file is
# created in os.tmpdir() (the guard holds — print mode never reaches startBridge).
ls -1 "${TMPDIR:-/tmp}"/pi-editor-bridge-*.sock 2>/dev/null | wc -l   # before: note baseline
pi --no-extensions -e ./extension/pi-editor-bridge.ts --print "ok" 2>&1 | tee /tmp/pi-editor-bridge-s6.log

# PASS 1: pi exited 0.
pi --no-extensions -e ./extension/pi-editor-bridge.ts --print "ok" >/dev/null 2>&1; echo "pi exit=$?"

# PASS 2: NO errors during load/handler registration.
grep -iE "error|cannot|fail|throw|unhandled|is not a function|TypeError|EADDRINUSE" /tmp/pi-editor-bridge-s6.log \
  && echo "FAIL: error present" || echo "PASS: no errors"

# PASS 3: NO socket created in print mode (TUI guard held; startBridge never ran).
ls -1 "${TMPDIR:-/tmp}"/pi-editor-bridge-*.sock 2>/dev/null | wc -l   # after: must equal the before count
# Expected: all three PASS; pi prints "ok" and exits 0; socket count unchanged.
```

### Level 4: Creative & Domain-Specific Validation

```bash
# Confirm NO socket leaked into tmpdir across the full S6 test run (every tui invocation
# pairs with a stopBridge() cleanup):
ls -1 "${TMPDIR:-/tmp}"/pi-editor-bridge-*.sock 2>/dev/null | wc -l   # before
JITI_REG=/home/dustin/.local/lib/node_modules/@earendil-works/pi-coding-agent/node_modules/jiti/lib/jiti-register.mjs
for f in bridge-lifecycle-wiring mode-guard bridge-lifecycle provider-capture protocol; do
  node --import "$JITI_REG" "extension/tests/$f.test.ts" >/dev/null 2>&1 || echo "FAIL: $f"
done
ls -1 "${TMPDIR:-/tmp}"/pi-editor-bridge-*.sock 2>/dev/null | wc -l   # after: must equal before (0 net leak)
# Expected: identical counts (no orphaned socket files).

# Confirm the error-handler truly prevents a crash by driving a synthetic error through the
# REAL wired lifecycle (mirrors TEST C, but via a one-shot probe so it's reproducible ad hoc):
node --import "$JITI_REG" -e '
  import("./extension/pi-editor-bridge.ts").then(async ({ default: factory, getServer, getSocketPath }) => {
    let start, stop;
    factory({ on: (ev, h) => { if (ev === "session_start") start = h; if (ev === "session_shutdown") stop = h; } });
    start({ reason: "startup" }, { mode: "tui", ui: { addAutocompleteProvider: () => {} } });
    const srv = getServer(); await new Promise(r => srv.once("listening", r));
    let threw = false;
    try { srv.emit("error", new Error("synthetic")); } catch { threw = true; }
    if (threw) { console.log("FAIL: error crashed the process"); process.exit(1); }
    if (getServer() !== undefined) { console.log("FAIL: stopBridge not triggered"); process.exit(1); }
    console.log("PASS: server error handled (no crash), stopBridge triggered");
  });
'
# Expected: PASS: server error handled (no crash), stopBridge triggered.
```

## Final Validation Checklist

### Technical Validation

- [ ] Level 1 (TYPE GATE): `tsc --noEmit -p extension/tsconfig.json` → exit 0, no output.
- [ ] Level 2 (CONTRACT GATE): `bridge-lifecycle-wiring.test.ts` → `pass 3`, `fail 0`;
      `mode-guard.test.ts` + `bridge-lifecycle.test.ts` → `fail 0`; S2 + S4 → `fail 0`.
- [ ] Level 3 (REGRESSION GATE): `pi --print "ok"` exits 0, no error lines, NO socket in tmpdir.
- [ ] Level 4: no socket leak across the full test run; synthetic-error probe prints PASS.

### Feature Validation

- [ ] `session_shutdown` handler calls `stopBridge()` (title deliverable); the stopBridge
      **body is byte-identical to S5's** (S6 only adds the call site).
- [ ] `session_start` handler calls `startBridge(ctx)` after the TUI guard + captureProvider;
      the L243 `// TODO(M2)` placeholder is gone (replaced by the call + an S16 breadcrumb).
- [ ] `startBridge` attaches `server.on("error", (err)=>{ console.error(...); stopBridge(); })`
      before `server.listen(...)`; the handler does NOT rethrow.
- [ ] tui lifecycle: session_start → getServer/getSocketPath/getToken populated, listening,
      on-disk mode 0o600; session_shutdown → all cleared + socket unlinked.
- [ ] non-tui: session_start leaves getServer() undefined (TUI guard intact — S3 preserved).
- [ ] synthetic `server.emit("error", …)` does NOT throw and clears getServer() (handler ran).
- [ ] NO process.env.PI_EDITOR_BRIDGE read/write (only a `// TODO(S16)` breadcrumb).

### Code Quality Validation

- [ ] Follows existing codebase patterns (TAB indent; `import type` discipline; Mode-A JSDoc
      with STATUS markers; node:test+jiti test conventions; getters over export let — unchanged).
- [ ] File placement matches the desired codebase tree (edits in pi-editor-bridge.ts; test
      updates under extension/tests/; new wiring test under extension/tests/).
- [ ] Anti-patterns avoided (no rethrow in the error handler; no process.env touch; no
      stopBridge body edit; no per-socket handling — that's S8; no tsconfig/protocol.ts change).
- [ ] Dependencies: Node builtins only (net/console/process already in scope); zero npm deps
      (PRD §6.7); no tsconfig change.

### Documentation & Deployment

- [ ] The two STATUS JSDoc markers updated to record S6 landed (stopBridge wired into
      session_shutdown; startBridge error handler + wiring done; S16 env still deferred).
- [ ] The `// TODO(S16)` breadcrumb is present at the session_start call site so S16 knows
      where the env write belongs.
- [ ] No new env vars introduced (env advertisement is S16, documented as deferred).

---

## Anti-Patterns to Avoid

- ❌ Don't edit the `stopBridge()` BODY — S5 owns it and it's already idempotent. S6 only
      adds the CALL site in session_shutdown (+ a JSDoc STATUS update). Editing the body is
      a scope violation and risks regressing S5's verified idempotency.
- ❌ Don't rethrow inside the `server.on("error")` handler — PRD §6.7 "never throws from
      handlers". The handler's job is log + stopBridge + return. An uncaught throw would
      re-crash pi via the same EventEmitter path the handler exists to defuse.
- ❌ Don't read or write `process.env.PI_EDITOR_BRIDGE` in S6 — that's S16. Leave only a
      `// TODO(S16): advertise via process.env.PI_EDITOR_BRIDGE` breadcrumb.
- ❌ Don't add `delete process.env.PI_EDITOR_BRIDGE` to stopBridge in S6 — S16 adds it
      "(after S16)". Nothing writes the var until S16, so deleting it in S6 is a dead ref.
- ❌ Don't attach the `server.on("error")` handler AFTER `server.listen()` — attach it
      BEFORE listen so it also catches an error emitted during the async bind.
- ❌ Don't log the token or socket descriptor in the error handler — PRD §12 "Never log the
      token." Log the `Error` object (its message/errno), never `getToken()`/`getSocketPath()`.
- ❌ Don't forget to update `bridge-lifecycle.test.ts` TEST 1's fake server — S6's
      `server.on("error",…)` calls `.on()` on the mocked fake; without a no-op `on()` the
      mocked test throws `TypeError: fakeServer.on is not a function`.
- ❌ Don't forget to update `mode-guard.test.ts`'s tui case with a `finally { stopBridge(); }`
      — the wiring now fires a REAL server there; without cleanup the guard test leaks a
      server fd + socket file (and can flake under tight fd limits).
- ❌ Don't wire startBridge BEFORE the TUI guard or BEFORE captureProvider — place the call
      at the END of the post-guard happy path so it inherits non-tui protection and matches
      the PRD §6.6 default-export skeleton order.
- ❌ Don't implement `onConnection`/handshake/JSONL reader/RPC handlers — those are
      S7/S8/S9/S11–S15. The `onConnection` no-op placeholder stays as-is. The server-level
      error handler is listen/bind errors only; per-connection error/close is S8.
- ❌ Don't change `protocol.ts`, `tsconfig.json`, `__deps`, the getters, or
      `captureProvider`/`getProvider` — S6 is purely the lifecycle wiring + the defensive
      error listener + their tests.
