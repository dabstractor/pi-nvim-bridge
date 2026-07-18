# Research Notes — P1.M2.T3.S5: startBridge()

**Item**: `startBridge()` — create Unix socket server, generate token, chmod 0o600.
**Plan path**: `plan/001_c56962b4fa17/P1M2T3S5/`.

> **Primary research source**: the orchestrator pre-researched this EXACT task and
> placed artifacts under the sibling dir `plan/001_c56962b4fa17/P1M2T1S1/research/notes.md`
> (the research itself notes "plan task **P1.M2.T3.S5**; orchestrator placed artifacts
> under P1M2T1S1"). That file is the authoritative task analysis. This file
> (a) consolidates its load-bearing decisions for discoverability at the canonical path,
> and (b) records an **independent re-verification** of the 3 most load-bearing empirical
> claims, run fresh against this machine on 2026-07-18.

## 1. Independent re-verification (2026-07-18, Node v26.4.0, pi 0.80.10)

A throwaway probe (`/tmp/s5-probe.mjs`) confirmed every claim the PRP depends on:

| Claim | Result |
|---|---|
| **Token format** `randomUUID().replace(/-/g,"").slice(0,32)` → 32 lowercase hex | ✅ `9cc78cb1cd9b4a4799b08b5d8798d0be`, len 32, matches `/^[0-9a-f]{32}$/` |
| **chmod-after-listen is safe** — socket FILE created synchronously by `listen()`; `statSync(path).mode & 0o777 === 0o600` | ✅ exists=true, mode=600 (octal), `==0o600` true |
| **`server.listening === true`** after `await once(srv,"listening")` | ✅ |
| **close + rmSync** unlinks file + flips listening false | ✅ exists=false, listening=false after `srv.close()` + `rmSync({force:true})` |
| **`node:net` namespace is FROZEN** — `Object.defineProperty(net,"createServer",...)` throws | ✅ `TypeError: Cannot redefine property: createServer` |

**Implication confirmed**: direct `node:net` mocking is impossible → the `__deps` mutable
plain-object seam is mandatory (production calls `__deps.createServer`, byte-identical to
the real builtin; tests override the plain-object property).

## 2. Exact @types/node line citations (re-confirmed via grep)

All under `/home/dustin/.local/lib/node_modules/@earendil-works/pi-coding-agent/node_modules/@types/node/`:

- `net.d.ts:587` — `class Server extends EventEmitter`
- `net.d.ts:635-636` — `listen(path: string, backlog?, listeningListener?)` / `listen(path, listeningListener?)`
  (the Unix-domain/IPC overload S5 uses)
- `net.d.ts:709` — `listening` boolean getter ("Indicates whether or not the server is listening")
- `crypto.d.ts:3572` — `function randomUUID(options?): UUID`
- `fs.d.ts:824` — `function chmodSync(path, mode): void`
- `fs.d.ts:1681` — `function rmSync(path, options?): void`
- `fs.d.ts:3554` — `function existsSync(path): boolean`

## 3. Verified validation commands

```bash
# Type gate
tsc --noEmit -p extension/tsconfig.json          # → exit 0 (binary: /home/dustin/.local/bin/tsc)

# Unit test (jiti register path CONFIRMED to exist, 172 bytes)
JITI_REG=/home/dustin/.local/lib/node_modules/@earendil-works/pi-coding-agent/node_modules/jiti/lib/jiti-register.mjs
node --import "$JITI_REG" extension/tests/bridge-lifecycle.test.ts   # → exit 0, fail 0
# (benign DEP0205 "module.register() is deprecated" on stderr — IGNORE)

# Regression
pi --no-extensions -e ./extension/pi-editor-bridge.ts --print "ok"    # → exit 0
```

## 4. Baseline state confirmed (post-S4, pre-S5)

- `extension/tsconfig.json` `include = ["pi-editor-bridge.ts","protocol.ts","tests/**/*.ts"]`
  → **the new test matches `tests/**/*.ts`; NO tsconfig edit needed.**
- `extension/pi-editor-bridge.ts:24` already imports `ExtensionContext` → **no new
  @earendil-works/* import for startBridge's signature.**
- `extension/pi-editor-bridge.ts:101` still has `// TODO(M2): startBridge(ctx, ctx.cwd);`
  → **the call site is UNWIRED; S5 must keep it unwired (wiring = S6).**
- `P1M2T3S5/research/` existed but was empty → this file is the first artifact here.

## 5. Consolidated design decisions (from P1M2T1S1/research/notes.md, §2)

1. **Co-locate** startBridge/stopBridge **inside** `extension/pi-editor-bridge.ts`
   (NOT a new `server.ts` module). Avoids a future circular import with `getProvider()`
   (later M2 handlers need BOTH the server AND the captured provider); zero tsconfig change.
2. **Ship a minimal working `stopBridge()` in S5** — `startBridge` calls it first for
   idempotency (reload/new/resume/fork re-entry), so it's a hard dependency. This
   completes the *core* of sibling task **S6**; S6 REUSES it (adds session_shutdown
   wiring + the env-clear once S16 lands). **OMIT** `delete process.env.PI_EDITOR_BRIDGE`
   in S5 (S5 writes no env var).
3. **Do NOT wire** startBridge into `session_start` in S5 — the existing
   `mode-guard.test.ts` (S3) invokes that handler directly in tui mode; wiring now would
   fire a real `net.createServer`+`listen`+`chmod` during a unit test. S6 lands both
   wirings atomically.
4. **`ctx` accepted but `ctx.cwd` NOT dereferenced** in S5 (reserved for the S16
   `BridgeDescriptor`). Derive the socket path from `os.tmpdir()`. Signal with `void ctx;`.
5. **`onConnection(_sock)` no-op placeholder** — S8 (reader+dispatcher) / S9 (handshake)
   territory. No `protocol.ts` import in S5.
6. **`__deps` seam** (`{createServer, chmodSync}`) for mocking (frozen namespace).
7. **Getters** (`getServer/getSocketPath/getToken`) over `export let` (jiti live-binding bug).

## 6. Cross-task interface notes (for sibling PRPs)

- **P1.M2.T3.S6 (stopBridge):** REUSE the stopBridge S5 ships (do NOT recreate it). S6
  adds: wire it into `session_shutdown`; (after S16) add `delete process.env.PI_EDITOR_BRIDGE`;
  wire `startBridge(ctx)` into the `session_start` handler at the L101 TODO call site; and
  add `server.on('error', ...)` so an async listen failure (EADDRINUSE) doesn't crash pi
  (S5's tests use unique UUID paths so this isn't exercised in S5).
- **P1.M2.T4.S8 (onConnection):** replace the no-op body with the JSONL reader + RPC
  dispatcher (imports `protocol.ts` + `getProvider()`).
- **P1.M2.T5.S9 (handshake):** validate `hello` token against `getToken()`.
- **P1.M3.T8.S16 (env advertisement):** extend `startBridge` to write the
  `BridgeDescriptor` (read `getSocketPath()`/`getToken()`/`ctx.cwd`/`process.pid` +
  resolve `fd` for `fdAvailable`) to `process.env.PI_EDITOR_BRIDGE`; extend `stopBridge`
  with `delete process.env.PI_EDITOR_BRIDGE`.
