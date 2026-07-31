# P1.M2.T5.S9 — `hello` handshake: research notes

> Scope: server side (pi-editor-bridge TS extension). Register the `hello`
> JSON-RPC method handler: validate the client token, reply success
> (`HelloResult`) or `-32600 "bad token"` **then close** the connection
> (PRD §5.3, §12). S10 (separate task) gates every non-hello method on
> `state.handshakeComplete`; S9 only *sets* that flag on success.

## 1. What already exists (build on, don't redo)

`extension/connection.ts` (S8, Complete) ships the WHOLE dispatch skeleton:
- `ConnectionState { handshakeComplete: boolean }` — created `false` per
  connection in `onConnection`. **S9 sets it `true` on a valid hello.**
- `registerBridgeHandler(method, fn)` — MODULE-LEVEL registry; the extension
  point S9 calls. S8 comment: *"Registered FROM pi-editor-bridge.ts (S9–S14),
  NOT here — each handler closure references getToken()/getProvider(). …
  connection.ts never imports pi-editor-bridge.ts (no import cycle)."*
- `sendResponse/sendError/sendNotification(sock, …)` — response writers.
- `handleLine(sock, state, line)` — already does: JSON.parse try/catch →
  `-32700`; envelope-narrow → `-32600`; `id:string` ⇒ REQUEST (dispatch →
  result on return / `-32603` on throw; unregistered → `-32601`); no `id` ⇒
  NOTIFICATION (no response).
- `MethodHandler = (params: unknown, state: ConnectionState) => unknown|Promise<unknown>`.

`extension/protocol.ts` (S4, Complete) has ALL handshake types already:
`HelloParams { token; client?; clientVersion? }`, `HelloResult { ok:true;
serverVersion; cwd; fdAvailable }`, plus the mapped `BridgeParamsMap`/
`BridgeResultMap`. **S9 consumes these — do NOT redeclare.**

`extension/pi-editor-bridge.ts` (S1/S3/S5/S6, Complete):
- `getToken(): string|undefined` — the 32-hex secret (real auth boundary, PRD §12),
  set in `startBridge`. **hello validates against this.**
- `startBridge(ctx)` does `void ctx` (ctx.cwd reserved for S16) — **S9 must
  store `ctx.cwd`** because `HelloResult.cwd` is required now.
- session_start handler: TUI-guarded → `captureProvider(ctx); startBridge(ctx);`

`extension/jsonl-reader.ts` (S7): `attachJsonlLineReader`, `serializeJsonLine`.

## 2. THE design problem (and the minimal fix)

The `hello` SUCCESS path is trivial: narrow params → compare token → on match
set `state.handshakeComplete = true` and return `HelloResult` (handleLine wraps
it in `{jsonrpc,id,result}`). The PROBLEM is the FAILURE path:

- `MethodHandler` only receives `(params, state)` — **no `sock`, no `id`** — so
  it cannot write the `-32600` line itself, and it cannot close the socket.
- Returning normally ⇒ handleLine writes a *success* response (wrong).
- The only way to signal "failure" out of a handler is to THROW — but S8's
  catch maps every throw to `-32603 internal error` (PRD §5.3 requires `-32600`).
- "then close" additionally needs socket access.

Zero-change-to-connection.ts is therefore IMPOSSIBLE for "error + close".
Evaluated options:

| Option | Verdict |
|---|---|
| (A) Change `MethodHandler` to `(ctx{sock,id,state}, params)`; hello calls sendError+end | ❌ Breaks every existing `registerBridgeHandler("x",(p)=>p)` in connection.test.ts (signature change); fiddly double-response avoidance. |
| (B) **Typed `BridgeRpcError(code,msg,{fatal})`; handleLine maps it → sendError(code,msg) + graceful `sock.end()` on fatal** | ✅ Signature UNCHANGED (all 13 existing tests stay green); minimal; forward-compatible (S15 domain handlers throw `BridgeRpcError` w/o fatal); close centralized in dispatcher. |
| (C) Special-case `method==="hello"` inside handleLine | ❌ Couples dispatcher to one method name; ugly. |

**Decision: Option B.** S9 introduces `BridgeRpcError` as the *foundation* S15
("wrap handlers in try/catch w/ JSON-RPC error codes") builds on. This is the
documented seam: S8's catch is explicitly the "last-resort -32603" safety net,
and S15 was always going to refine handler→code mapping. S9 just lands the
mechanism + the one handler that needs it.

`BridgeRpcError` placement: **connection.ts** (it already has runtime exports;
protocol.ts is documented "types-only, zero runtime exports"). Optional
`fatal:boolean` defaults false — ONLY hello uses `fatal:true` (PRD §5.3).
Existing `-32600`/`-32700` cases in handleLine are sent directly (not via
throw) and must NOT close → the `fatal` flag is what scopes the close.

## 3. Why `sock.end()` (not `destroy()`) for the fatal close

"Reply then close" (PRD §5.3) ⇒ the `-32600` line must reach the client before
EOF. `sock.end()` flushes the queued `sendError` write THEN sends FIN
(half-close) — exactly right. `sock.destroy()` can drop the queued write.
Wrap in try/catch (end on an already-closing socket throws). After end, the
existing `sock.on("close")` fires → reader `detach()` (no listener leak).

## 4. `fdAvailable` — must be self-contained (pi's helpers are NOT public)

`HelloResult.fdAvailable` is required. PRD §11: *"`fd` not installed … bridge
reports `fdAvailable` in `hello`."* PRD §6.4 placeholder: `fdAvailable: !!fdPathAvailable()`.

pi resolves fd via `ensureTool("fd")`/`getToolPath("fd")` in
`dist/utils/tools-manager.js` (checks pi's agent bin dir FIRST, then PATH, for
`fd` and — on Linux — `fdfind`). BUT: **`getToolPath`/`ensureTool` are NOT
exported from `@earendil-works/pi-coding-agent`** (grep `dist/index.d.ts` +
`dist/core/extensions/` ⇒ zero hits). A deep internal import
(`…/dist/utils/tools-manager.js`) would resolve *at runtime inside pi's
process* but is fragile (pi could refactor). ⇒ **Self-contained resolver that
mirrors pi's lookup order** (no internal deps):

1. pi agent bin dir: `$PI_CODING_AGENT_DIR ?? ${XDG_DATA_HOME||~/.local/share}/pi`
   (Linux/mac), `%APPDATA%/pi` (win); look for `bin/fd` (+`fdfind` on Linux).
2. `process.env.PATH` scan for executable `fd`/`fdfind`.
3. Cache the boolean (one-time per process); expose `__setFdAvailableForTest`.

Verified on this box: `fd` present at `/home/dustin/.cargo/bin/fd`. pi's agent
bin dir = `~/.local/share/pi/bin` (config.js: `getBinDir() = join(getAgentDir(),"bin")`;
tools-manager `TOOLS_DIR = getBinDir()`).

## 5. `cwd` — store from `ctx.cwd`

`ExtensionContext.cwd: string` confirmed (`dist/core/extensions/types.d.ts` L216+).
session_start already has `ctx`. Add module `let cwd; getCwd(); __setCwdForTest`.
`HelloResult.cwd = getCwd() ?? ""` (defensive — "" if somehow unset).

## 6. Testability: inject deps into the handler factory

`makeHelloHandler(deps:{getToken,getCwd,getFdAvailable,version}): MethodHandler`
— PURE factory; tests call it with fake deps + a real `ConnectionState` and
assert (a) good token ⇒ returns `HelloResult` + flips `handshakeComplete`,
(b) bad/missing token ⇒ throws `BridgeRpcError(-32600,"bad token",{fatal:true})`.
`pi-editor-bridge.ts` registers `makeHelloHandler({getToken,getCwd,getFdAvailable,version:BRIDGE_VERSION})`
in session_start (AFTER startBridge so the token exists). Placing the factory
in `pi-editor-bridge.ts` matches "handlers registered FROM that module" and the
existing convention (bridge-lifecycle.test.ts already imports from it). No
import cycle: pi-editor-bridge.ts → connection.ts (one direction).

`BRIDGE_VERSION = "0.1.0"` (PRD §6.4 hardcode). S16 reuses it for the descriptor.

## 7. Test convention (verified — DO NOT use vitest)

```
JITI_REG=/home/dustin/.local/lib/node_modules/@earendil-works/pi-coding-agent/node_modules/jiti/lib/jiti-register.mjs
node --import "$JITI_REG" extension/tests/<suite>.test.ts   # exit 0, ℹ fail 0
tsc --noEmit -p extension/tsconfig.json                      # exit 0, no output
```
`import { test } from "node:test"; import assert from "node:assert/strict";`.
Reuse the `fakeSocket()` helper from connection.test.ts (EventEmitter + write
capture + destroy→emit close) — **add an `end()` that records the call + emits
close** so the fatal-close path is assertable. One REAL Unix-socket integration
test (createServer + connect, like connection.test.ts test 13) for hello
success + bad-token-disconnect.

Backward-compat check: existing connection.test.ts "handler THROWS → -32603"
throws a PLAIN `Error` ⇒ under the new `instanceof BridgeRpcError` branch it
falls through to `-32603`. ✅ All 13 existing tests stay green. Confirmed by
re-run: `node --import "$JITI_REG" extension/tests/connection.test.ts` ⇒ 13 pass.

## 8. pi's own RPC precedent (for confidence, not to mirror)

`dist/modes/rpc/rpc-mode.js handleInputLine` (~L582): JSON.parse try/catch →
error response; handler try/catch → generic error response (single `error()`
helper, no per-code typed errors). So pi does NOT use typed RPC errors — the
`BridgeRpcError` mechanism is a bridge-specific refinement (still spec-correct
JSON-RPC 2.0: codes -32600/-32603 are standard reserved-range codes).

## 9. Security note (timing-safe compare NOT required here)

Threat model (PRD §12): another LOCAL process impersonating the editor on the
same Unix socket. The token is a 32-byte random secret delivered via
process-local `process.env` (never on disk, never logged). A local attacker
cannot observe string-compare timing of a same-machine, single-shot RPC
meaningfully; `===` is acceptable. (Optional v1.1 hardening: wrap in
`crypto.timingSafeEqual` after a length guard — mention, don't require.) Never
log/echo the token (PRD §12) — the `-32600` message is the literal `"bad token"`,
NOT the received/expected values.

## 10. Out of scope (other tasks — do NOT implement)

- S10: the `if (!state.handshakeComplete && method!=="hello")` gate. S9 only
  SETS the flag; S10 reads it. (Until S10 lands, pre-hello methods are still
  dispatched per S8 — fine, S9 doesn't change that.)
- S11–S14: getSuggestions/applyCompletion/shouldTriggerFileCompletion/ping/bye/getCommands.
- S15: making domain handlers catch their OWN errors into `BridgeRpcError`.
  S9 lands the class + handleLine mapping; S15 uses it broadly.
- S16: writing `process.env.PI_NVIM_BRIDGE` (reuses `BRIDGE_VERSION`/`getCwd`/`getFdAvailable`).
- S17: `commandsChanged` notification.
