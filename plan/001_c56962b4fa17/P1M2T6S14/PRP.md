name: "P1.M2.T6.S14 — ping, bye & getCommands handlers (diagnostics liveness, graceful disconnect ack, and best-effort command list via the captured provider)"
description: "pi-editor-bridge extension (TS). Register the final three JSON-RPC handlers from PRD §5.4 as deps-injected factories in `pi-editor-bridge.ts`, completing the M2.T6 handler family alongside S9(hello)/S11(getSuggestions)/S12(applyCompletion)/S13(shouldTriggerFileCompletion). (1) `ping` (SYNC): a liveness/diagnostics handler returning `PingResult = {ok:true, pid, cwd, fdAvailable, serverVersion}` — i.e. `HelloResult` + a new `pid` field. It is structurally `makeHelloHandler` minus token validation (the S10 handshake gate in connection.ts:234 already guarantees `state.handshakeComplete===true` before any non-hello method runs, so ping NEVER sees an unauthenticated caller and needs NO `getToken` dep). Deps: `{getPid, getCwd, getFdAvailable, version}` where `getPid: () => number` is NEW (`process.pid`). Empty params (`PingParams = Record<string, never>`) are IGNORED — consistent with hello ignoring client/clientVersion; add NO params validator (pure rejection of an empty-params method is pointless). (2) `bye` (SYNC): graceful-disconnect ack returning `ByeResult = {ok:true}` AND requesting a server-side half-close. The CURRENT `connection.ts` can only close on the ERROR path (`BridgeRpcError.fatal`); the success path (`sendResponse` then return) never closes and handlers don't receive `sock`. RECOMMENDED: extend `ConnectionState` with an OPTIONAL `closeAfterResponse?: boolean` flag (backward compatible — falsy ⇒ no close ⇒ all 5 existing handlers + 16 connection tests unaffected) and add a 3-line check after `sendResponse` in `handleLine`'s success branch that calls `sock.end()` (try/catch wrapped, mirroring the existing fatal-close pattern at connection.ts:276-285). The bye handler sets `state.closeAfterResponse = true` and returns `{ok:true}`. S8/S10 (connection.ts owners) are COMPLETE, so this additive edit is safe; it is ORTHOGONAL to S15's error-wrapping (S15 edits the `catch` branch, this adds to the `try` branch). Reject the alternative of throwing `BridgeRpcError({fatal:true})` — that returns an ERROR envelope, violating the `ByeResult` success contract. Document the zero-connection.ts-edit fallback (client closes after ack, PRD §4 step 6) as acceptable-but-minimal. (3) `getCommands` (ASYNC, OPTIONAL): returns `GetCommandsResult = {commands: CommandInfo[]}` where `CommandInfo = {name, description?, argumentHint?}`. DATA SOURCE DECISION: `pi.getCommands()` exists on ExtensionAPI (types.ts:1311) but OMITS the ~23 BUILTIN_SLASH_COMMANDS and `BUILTIN_SLASH_COMMANDS` is NOT publicly exported (not in index.ts) — so hardcoding would drift. BEST PATH: call `provider.getSuggestions([\"/\"], 0, 1, {signal, force:false})` on the ALREADY-CAPTURED live provider (same `getProvider()` dep as S11/S12/S13). The `/` branch in autocomplete.ts:118-165 is SYNC + in-memory (textBeforeCursor=\"/\", no @file, no fd), and fuzzyFilter with empty prefix returns ALL items (builtins + templates + extensions + skills). Map each `AutocompleteItem{value,label,description?}` → `CommandInfo{name=item.value, description=item.description?}`; `argumentHint` is UNRECOVERABLE (pi bakes it into the description string as 'hint — desc'; AutocompleteItem has no argumentHint field) so it is left undefined — acceptable since protocol.ts marks it optional. A fresh `AbortController` satisfies the getSuggestions signature only (the `/` branch is sync ⇒ no timeout, no supersession). Ignore empty params (`GetCommandsParams = Record<string, never>`). No change to protocol.ts (Ping/Bye/GetCommands/CommandInfo types already defined in §C). New `ping-bye-getcommands-handler.test.ts` (UNIT/DISPATCH/REAL three layers). node:test + jiti (NOT vitest). Downstream consumers: ping → P3.M10.T27.S42 (:checkhealth pi-editor liveness); bye → P2.M9.T23.S38 (Neovim VimLeavePre/ExitPre sends bye); getCommands → OPTIONAL docs-menu UX (PRD §15 future)."

---

## Goal

**Feature Goal**: Land the final three JSON-RPC method handlers from PRD §5.4,
completing the M2.T6 handler family (`ping`, `bye`, `getCommands`). Once
registered, an authenticated Neovim client can (a) **probe bridge liveness** and
read server identity/capabilities via `ping` (used by `:checkhealth pi-editor` in
P3.M10.T27.S42); (b) send a **`bye`** ack on `VimLeavePre`/`ExitPre` and have the
server flush `{ok:true}` then gracefully half-close the connection (PRD §5.4
"graceful disconnect"; consumer P2.M9.T23.S38); and (c) optionally fetch a
**best-effort command list** (`getCommands`) for richer docs/help menus (PRD §15
future enhancement). All three delegate to no new state — they reuse the live
provider (`getProvider()`) and module getters (`getCwd`/`getFdAvailable`/`BRIDGE_VERSION`)
already established by S9–S13, plus one trivially-new `getPid` (`process.pid`).

**Deliverable**:
1. `extension/pi-editor-bridge.ts` — ADD:
   - `makePingHandler(deps: { getPid; getCwd; getFdAvailable; version })` — SYNC
     factory returning a `MethodHandler`. The handler returns `PingResult`
     (`HelloResult` + `pid`) directly (NOT `async`/NOT a Promise), mirroring
     `makeHelloHandler`'s sync shape but WITHOUT the token branch.
   - `makeByeHandler()` — SYNC factory (no deps). The handler sets
     `state.closeAfterResponse = true` and returns `{ ok: true }`.
   - `makeGetCommandsHandler(deps: { getProvider })` — ASYNC factory (mirrors the
     S11/S12/S13 `getProvider` dep). The handler calls
     `provider.getSuggestions(["/"], 0, 1, { signal: ac.signal, force: false })`
     and maps `AutocompleteItem[]` → `CommandInfo[]` (`name = item.value`,
     `description = item.description?`; `argumentHint` left undefined).
   - A module-level `getPid()` getter (`() => process.pid`) OR inline
     `getPid: () => process.pid` in the `ping` registration call (see Task 2).
   - Three new `registerBridgeHandler(...)` calls in the `session_start`
     handler, immediately AFTER the existing S13
     `shouldTriggerFileCompletion` registration and BEFORE the `TODO(S14)`
     comment.
   - Extend the existing `import type { ... } from "./protocol.ts"` to ALSO
     import `PingParams, PingResult, ByeParams, ByeResult, GetCommandsParams,
     GetCommandsResult, CommandInfo`.
   - Update the `TODO(S14)` comment → mark S14 DONE (keep S16 TODO).
   - Update the file-top STATUS block: add a `STATUS (P1.M2.T6.S14)` note.
2. `extension/connection.ts` — (approach (a) ONLY) ADD an OPTIONAL
   `closeAfterResponse?: boolean` field to `ConnectionState` (backward
   compatible) and a 3-line check in `handleLine`'s success branch (after
   `sendResponse`) that calls `sock.end()` when the flag is set (try/catch
   wrapped, mirroring the `BridgeRpcError.fatal` close pattern). NO other change.
3. `extension/tests/ping-bye-getcommands-handler.test.ts` (NEW) — three layers
   per the S11/S12/S13 convention: UNIT (factory directly + stub deps + fresh
   `ConnectionState`), DISPATCH (`registerBridgeHandler` + `fakeSocket` +
   `handleLine`, `{ handshakeComplete: true }` for the gated happy path;
   pre-handshake ⇒ `-32600` regression for ping/getCommands; bye ⇒ `{ok:true}`
   + `state.ended === true` via the `closeAfterResponse` flag), and ONE REAL
   Unix-socket integration test (hello → ping → bye → client observes close, and
   hello → getCommands over a real socket with a stub provider).

**Success Definition**: With the bridge running and a client authenticated via
`hello`:
- `ping` returns `{jsonrpc,id,result:{ok:true,pid:<num>,cwd,fdAvailable,serverVersion}}`
  — `pid` equals `process.pid`, `serverVersion` equals `BRIDGE_VERSION`
  (`"0.1.0"`), `cwd`/`fdAvailable` match the module getters.
- `bye` returns `{jsonrpc,id,result:{ok:true}}` and the server then half-closes
  the connection (the client observes `end`/`close`).
- `getCommands` returns `{jsonrpc,id,result:{commands:[{name,description?},…}}`
  derived from the live provider's `/`-prefix suggestions (all command
  categories); an empty/`null` provider result yields `{commands:[]}`.
- Pre-handshake `ping`/`getCommands`/`bye` ⇒ `-32600` "handshake required"
  (S10 gate, unchanged). Provider-not-captured in `getCommands` ⇒ `-32603`
  (safety net; S15 refines). The token value never appears in any response
  (PRD §12).
- `tsc --noEmit -p extension/tsconfig.json` is clean; the new suite passes;
  **all 12 existing extension suites stay green** (S2–S13); the 16-test
  `connection.test.ts` stays green (the `closeAfterResponse` change is backward
  compatible — no existing handler sets the flag).

---

## User Persona

**Target User**: The `pi-bridge.nvim` Neovim plugin (P2.M5 / P2.M7 / P2.M9) — the
bridge's only client. (Indirectly: the human editing a pi prompt in their
`$EDITOR`, plus a future `:checkhealth pi-editor` user.)

**Use Case**:
- *ping* — `:checkhealth pi-editor` (P3.M10.T27.S42) opens a connection, handshakes,
  and sends `ping` to confirm the bridge process is alive and to read its
  version/cwd/fd-availability for diagnostics.
- *bye* — when the user finishes editing and quits the pi-launched Neovim
  (`:wq`/`:q`), the plugin's `VimLeavePre`/`ExitPre` autocmd (P2.M9.T23.S38)
  sends `bye` so the server can ack and half-close cleanly before the socket
  tears down.
- *getCommands* — (optional) a richer help/docs menu (PRD §15 "Hover docs")
  fetches the full command list to show `name`/`description` for each slash,
  skill, template, and extension command.

**User Journey**: (ping) open Neovim as `$EDITOR` → plugin activates on
`PI_NVIM_BRIDGE` → `hello` (token) → `ping` → diagnostics render. (bye) user
quits → `VimLeavePre` autosaves → `bye` → server acks `{ok:true}` + half-closes
→ Neovim exits → pi reads the temp file back. (getCommands) a `:PiCommands`
helper issues `getCommands` → renders a floating list.

**Pain Points Addressed**: (1) no diagnostic surface to tell if the bridge is
actually wired up (ping fills this); (2) unclean teardown left to TCP keepalive
to discover (bye gives an explicit, prompt close); (3) no enumeration of the
command surface for help UX (getCommands provides it best-effort).

---

## Why

- **Completes the PRD §5.4 methods table.** With S9–S13 already shipping
  `hello`/`getSuggestions`/`applyCompletion`/`shouldTriggerFileCompletion`, the
  three remaining methods (`ping`/`bye`/`getCommands`) are the last items in
  T6 ("RPC method handlers"). Landing them unblocks P3.M10.T27.S42
  (`:checkhealth`) and P2.M9.T23.S38 (autosave+bye teardown).
- **Diagnosability.** `ping` gives `:checkhealth` a cheap, side-effect-free
  liveness + version probe — essential because the bridge runs as a background
  socket server inside pi's process and is otherwise invisible.
- **Clean teardown.** PRD §5.4 calls `bye` a "graceful disconnect". Without a
  server-side close, a client that sends `bye` then hangs would linger until the
  next EOF. Approach (a) makes the server proactively half-close after acking,
  matching the PRD's intent and hardening the lifecycle.
- **Help UX (optional).** `getCommands` enables a docs menu over the FULL
  command surface (builtins + templates + extensions + skills) without the
  bridge hardcoding pi's command list (which would drift).

### What this is NOT
- NOT a re-implementation of pi's completion logic — `getCommands` *reuses* the
  already-captured live provider.
- NOT a new transport, framing, or handshake — those are S5–S10 (complete).
- NOT the `commandsChanged` S→C notification — that is S17 (P1.M3.T9).
- NOT error-code refinement for domain errors — that is S15 (P1.M2.T7). S14
  keeps provider/`getProvider()` runtime throws flowing to `handleLine`'s
  `-32603` safety net.

---

## What

### User-visible behavior (wire)

All three are JSON-RPC 2.0 REQUESTS (they carry a string `id` and expect a
result). They are dispatched through `handleLine` branch (D) REQUEST and are
gated by the S10 handshake check (a pre-handshake request gets `-32600`
"handshake required").

```jsonc
// ping — C→S
{"jsonrpc":"2.0","id":"p1","method":"ping","params":{}}
// ping — S→C (pid = process.pid; serverVersion = "0.1.0")
{"jsonrpc":"2.0","id":"p1","result":{"ok":true,"pid":12345,"cwd":"/home/u/proj","fdAvailable":true,"serverVersion":"0.1.0"}}

// bye — C→S
{"jsonrpc":"2.0","id":"b1","method":"bye","params":{}}
// bye — S→C, THEN the server half-closes (sock.end())
{"jsonrpc":"2.0","id":"b1","result":{"ok":true}}

// getCommands — C→S
{"jsonrpc":"2.0","id":"g1","method":"getCommands","params":{}}
// getCommands — S→C (commands derived from provider.getSuggestions(["/"],0,1))
{"jsonrpc":"2.0","id":"g1","result":{"commands":[{"name":"model","description":"<provider/model> — Select model (opens selector UI)"},{"name":"compact","description":"Manually compact the session context"}, …]}}
```

Pre-handshake (no valid `hello` first):
```jsonc
{"jsonrpc":"2.0","id":"p1","method":"ping","params":{}}
{"jsonrpc":"2.0","id":"p1","error":{"code":-32600,"message":"handshake required: send hello first"}}
```

### Success Criteria

- [ ] `ping` returns `PingResult` with `pid === process.pid`, `serverVersion === BRIDGE_VERSION`, `cwd === getCwd() ?? ""`, `fdAvailable === getFdAvailable()`.
- [ ] `bye` returns `{ok:true}` AND triggers a server-side `sock.end()` (the `closeAfterResponse` path); the connection then closes.
- [ ] `getCommands` returns `{commands: CommandInfo[]}` derived from `provider.getSuggestions(["/"],0,1)`; each `CommandInfo.name` is the command name (no leading slash); `description` is forwarded when present; `argumentHint` is absent (undefined) — documented limitation.
- [ ] A `null`/empty provider `getSuggestions` result yields `{commands:[]}`.
- [ ] `ping`/`bye`/`getCommands` are SYNC where the contract is sync (ping/bye) and ASYNC where it is async (getCommands), per the S9–S13 precedent.
- [ ] Pre-handshake `ping`/`getCommands`/`bye` ⇒ `-32600` "handshake required" (S10 gate unchanged).
- [ ] Provider-not-captured in `getCommands` ⇒ `-32603` (safety net; S15 refines later).
- [ ] The token value never appears in any ping/bye/getCommands response (PRD §12).
- [ ] `tsc --noEmit -p extension/tsconfig.json` ⇒ exit 0, no output.
- [ ] New `ping-bye-getcommands-handler.test.ts` ⇒ `ℹ fail 0`.
- [ ] All 12 existing extension suites stay green; the 16-test `connection.test.ts` stays at `ℹ pass 16`.

---

## All Needed Context

### Context Completeness Check

_Before writing this PRP, validate: "If someone knew nothing about this codebase, would they have everything needed to implement this successfully?"_

✅ YES. This PRP references the exact handler factories to mirror (`makeHelloHandler`,
`makeGetSuggestionsHandler`), the exact wire types (`PingParams`/`PingResult`/
`ByeParams`/`ByeResult`/`GetCommandsParams`/`GetCommandsResult`/`CommandInfo` — all
already in `protocol.ts` §C), the exact data-source decision for `getCommands`
(`getSuggestions(["/"],0,1)` on the captured provider), the exact minimal
`connection.ts` diff for `bye`'s graceful close, and the exact test invocation
(`node --import "$JITI_REG" …` + `tsc --noEmit`). The implementer needs no prior pi
or bridge knowledge beyond reading the cited files.

### Documentation & References

```yaml
# MUST READ — PRD sections that define this task
- url: PRD.md §5.3 (handshake/envelopes), §5.4 (methods table — ping/bye/getCommands rows), §4 step 6 (teardown model), §11 (failure modes), §12 (security — token never logged)
  why: "§5.4 is the authoritative wire contract; §4 step 6 confirms the CLIENT owns socket close on VimLeavePre (so bye's server-side close is defense-in-depth, not the only path); §12 mandates the token never leaks"
  critical: "bye is labeled 'graceful disconnect' in §5.4 — approach (a) makes the server participate in the close, which is the faithful reading"

# MUST READ — the existing handler factories to mirror (deps-injection + MethodHandler shape)
- file: extension/pi-editor-bridge.ts
  why: "makeHelloHandler (deps: {getToken,getCwd,getFdAvailable,version}) is the template for makePingHandler (drop getToken, add getPid); makeGetSuggestionsHandler/ makeApplyCompletionHandler/ makeShouldTriggerFileCompletionHandler are the {getProvider}-dep template for makeGetCommandsHandler; the session_start block shows where the three new registerBridgeHandler calls go (after S13, before the TODO(S14) comment)"
  pattern: "deps-injected factory returning a MethodHandler; SYNC handler returns the result object directly (NOT a Promise); the MethodHandler union (Promise<unknown> | unknown) accommodates sync; ASYNC handler uses `async` + `await`"
  gotcha: "jiti does NOT implement cross-module live-binding reassignment of `export let` — state (token/socketPath/cwd/fdAvailableCache) is read via GETTERS (getToken/getCwd/getSocketPath/getFdAvailable), not imported bindings. getProvider() throws a plain Error if not captured → that propagates to handleLine's -32603 safety net (S15 refines)."

# MUST READ — the dispatch loop + ConnectionState (only edit IF taking bye approach (a))
- file: extension/connection.ts
  why: "handleLine's success branch (after sendResponse) currently never closes; the only close is BridgeRpcError.fatal on the ERROR path. approach (a) adds an optional closeAfterResponse flag + a 3-line check. The S10 handshake gate (method !== 'hello' && !state.handshakeComplete) guarantees ping/bye/getCommands only run post-handshake."
  pattern: "BridgeRpcError({fatal:true}) close pattern at the catch branch (connection.ts:274-285): sendError THEN try { sock.end() } catch {}. Mirror it verbatim for the success-branch close (try/catch wrapped)."
  gotcha: "connection.ts is owned by S8/S10 — but BOTH ARE COMPLETE, so this additive, backward-compatible edit is safe. S15 (error-wrapping, Planned) edits the CATCH branch; approach (a) edits the TRY branch — logically orthogonal, small merge surface. Do NOT add closeAfterResponse handling to the NOTIFICATION branch (bye is a REQUEST, dispatched via branch D)."

# MUST READ — wire types (ALL already defined; protocol.ts needs NO change)
- file: extension/protocol.ts
  why: "§C defines PingParams (Record<string,never>), PingResult ({ok:true,pid,cwd,fdAvailable,serverVersion}), ByeParams (Record<string,never>), ByeResult ({ok:true}), GetCommandsParams (Record<string,never>), GetCommandsResult ({commands:CommandInfo[]}), CommandInfo ({name,description?,argumentHint?}). §D includes all three in BridgeMethod/RequestMethod/BridgeParamsMap/BridgeResultMap. Import them into pi-editor-bridge.ts."
  pattern: "empty params use Record<string,never> (the correct TS empty-object type; {} is unsafe). result `ok` is the literal `true`."

# MUST READ — the test conventions (node:test + jiti, NOT vitest; three layers; fakeSocket helper)
- file: extension/tests/should-trigger-file-completion-handler.test.ts
  why: "the canonical S9–S13 test file: shows fakeSocket()/parseResponses()/readFirstResponse() copied VERBATIM (LOCAL per-file helpers), the UNIT/DISPATCH/REAL structure, __resetHandlersForTest() in every finally, the TOKEN-never-leaked SECURITY test, and the makeRecordingProvider stub pattern"
  pattern: "import { test } from 'node:test'; import assert from 'node:assert/strict'; import { EventEmitter, once } from 'node:events'; import { createServer, connect, type Socket } from 'node:net'; … fakeSocket() returns {sock, writes, state:{ended}} where end() emits 'close'"
  gotcha: "node:test runs tests SEQUENTIALLY and the handler registry is MODULE-LEVEL — EVERY test MUST call __resetHandlersForTest() in finally or later tests see stale handlers. jiti prints a benign DeprecationWarning on Node 26 stderr — judge by exit code + the ℹ pass/ℹ fail summary."

# DATA SOURCE for getCommands — verified against the pi monorepo
- file: ~/projects/pi/packages/coding-agent/src/core/extensions/types.ts:1311
  why: "getCommands(): SlashCommandInfo[] exists on ExtensionAPI — but its impl (agent-session.ts:2312-2334) returns ONLY extension commands + prompt templates + skills; it OMITS the ~23 BUILTIN_SLASH_COMMANDS. SlashCommandInfo has NO argumentHint field."
  critical: "pi.getCommands() is INSUFFICIENT for a full command list. Use provider.getSuggestions(['/'],0,1) instead."
- file: ~/projects/pi/packages/coding-agent/src/core/slash-commands.ts:19-44
  why: "BUILTIN_SLASH_COMMANDS is the 23-entry builtin list — but it is NOT exported from packages/coding-agent/src/index.ts (grep = zero). Hardcoding it in the bridge would DRIFT as pi evolves."
  critical: "do NOT hardcode the builtin list. getSuggestions(['/']) already includes them via CombinedAutocompleteProvider."
- file: ~/projects/pi/packages/tui/src/autocomplete.ts:118-165
  why: "the slash-command branch: textBeforeCursor='/' ⇒ startsWith('/') true, spaceIndex===-1 true, prefix='' ⇒ fuzzyFilter returns ALL items (fuzzy.ts:81-83). pi BAKES argumentHint into description as 'hint — desc' (autocomplete.ts:~140-150). AutocompleteItem = {value,label,description?} — NO argumentHint field."
  critical: "the '/' branch is SYNC + in-memory (NO fd, NO @file) ⇒ getCommands needs NO timeout and NO supersession (unlike S11's fd risk). argumentHint is UNRECOVERABLE from the provider path — leave it undefined (protocol.ts marks it optional)."
- file: ~/projects/pi/packages/coding-agent/src/modes/interactive/interactive-mode.ts:538-620
  why: "createBaseAutocompleteProvider builds the live provider from builtins + templates + extensionCommands + skillCommandList — so getSuggestions(['/']) covers EVERY command category."

# PRIOR RESEARCH (full details + code snippets)
- docfile: plan/001_c56962b4fa17/P1M2T6S14/research/notes.md
  why: "the verified scout findings for all three handlers — exact deps, the bye approach-(a) diff, the getCommands data-source ranking (Option A getSuggestions > Option B pi.getCommands > hardcode), field mappings, downstream consumers"
  section: "§1 ping, §2 bye, §3 getCommands, §4 test conventions, §5 files touched"
```

### Current Codebase tree (run `tree` in the root of the project)

```bash
cd /home/dustin/projects/pi-nvim-bridge && find . -path ./.git -prune -o -path ./node_modules -prune -o -type f -name '*.ts' -print | sort
# extension/
#   pi-editor-bridge.ts        # default factory + handlers (S9-S13) + lifecycle (THIS TASK: +ping/+bye/+getCommands)
#   protocol.ts                # TYPE-ONLY wire contract (UNCHANGED by S14)
#   connection.ts              # dispatch loop + ConnectionState (THIS TASK: +closeAfterResponse flag [approach (a)])
#   jsonl-reader.ts            # JSONL framing (UNCHANGED)
#   tests/
#     provider-capture.test.ts            # S2
#     mode-guard.test.ts                  # S3
#     protocol.test.ts                    # S4
#     bridge-lifecycle.test.ts            # S5
#     bridge-lifecycle-wiring.test.ts     # S6
#     jsonl-reader.test.ts                # S7
#     connection.test.ts                  # S8/S10 (16 tests — MUST stay green)
#     hello-handler.test.ts               # S9
#     handshake-gate.test.ts              # S10
#     get-suggestions-handler.test.ts     # S11
#     apply-completion-handler.test.ts    # S12
#     should-trigger-file-completion-handler.test.ts  # S13
#     (ping-bye-getcommands-handler.test.ts)          # S14 — NEW this task
#   tsconfig.json
```

### Desired Codebase tree with files to be added and responsibility of file

```bash
extension/
  pi-editor-bridge.ts     # MODIFY — add makePingHandler/makeByeHandler/makeGetCommandsHandler,
                          #           getPid, 3 registerBridgeHandler calls, import types, STATUS note
  connection.ts           # MODIFY (approach (a)) — add optional closeAfterResponse? to ConnectionState
                          #                     + 3-line success-branch sock.end() check in handleLine
  tests/
    ping-bye-getcommands-handler.test.ts   # NEW — UNIT/DISPATCH/REAL for ping, bye, getCommands
# protocol.ts — UNCHANGED (all needed types already defined in §C)
```

### Known Gotchas of our codebase & Library Quirks

```typescript
// CRITICAL: handlers do NOT receive the socket. The MethodHandler signature is
//   (params: unknown, state: ConnectionState) => Promise<unknown> | unknown
// So bye CANNOT call sock.end() directly. The ONLY existing close path is
// BridgeRpcError({fatal:true}) on the ERROR branch. approach (a) adds a success-
// branch close via the ConnectionState flag. Do NOT change the handler signature.

// CRITICAL: jiti (pi's TS loader) does NOT implement cross-module live-binding
// reassignment of `export let`. Module state (token, socketPath, cwd,
// fdAvailableCache, liveProvider) is read via GETTERS only — getToken(),
// getSocketPath(), getCwd(), getFdAvailable(), getProvider(). A consumer that
// imported a `let` binding would keep seeing the initial value forever. So
// deps-inject the GETTER (e.g. { getCwd, getFdAvailable }), not the value.

// CRITICAL: the handler registry (connection.ts `handlers` Map) is MODULE-LEVEL.
// node:test runs tests SEQUENTIALLY and the registry persists across tests.
// EVERY test MUST call __resetHandlersForTest() in finally, or later tests see
// stale handlers from earlier ones. (Existing S9-S13 suites all do this.)

// CRITICAL: process.pid is a plain number stable per process — but inject it as
// getPid: () => number (NOT a captured value) for testability symmetry with the
// other getters, so a unit test can assert pid wiring without monkeypatching
// process.pid. (version: string is injected as a plain value already — either
// style is acceptable; prefer the getter for pid since tests assert exactness.)

// GOTCHA: getP pings/getCommands/bye take EMPTY params (Record<string, never>).
// Do NOT add a params validator that rejects {foo:"bar"} — there is nothing to
// narrow, and hello's precedent is to IGNORE unknown params (client/clientVersion).
// Pure rejection of an empty-params method is pointless and adds a code path.

// GOTCHA: getSuggestions is typed Promise even though its "/" branch is SYNC.
// makeGetCommandsHandler MUST be `async` and `await` the call (handleLine's
// `await handler(...)` is a no-op on a non-Promise, but the handler itself must
// return a Promise here). Pass a fresh AbortController — the signature REQUIRES
// {signal, force}; the "/" branch ignores it (sync, in-memory), so abort is a
// no-op and NO timeout is needed (unlike S11's fd runaway risk).

// GOTCHA: the "/" branch BAKES argumentHint into the description string
// ("hint — desc"). AutocompleteItem has NO argumentHint field. Do NOT try to
// split description on " — " to recover it — descriptions legitimately contain
// " — ". Leave CommandInfo.argumentHint undefined (protocol.ts marks it optional).

// GOTCHA: ByeParams/GetCommandsParams/PingParams are Record<string, never>.
// When the handler ignores _params, PREFIX it with _ (eslint/TS unused-arg
// convention used throughout this codebase — see makeHelloHandler's ignored
// fields). Do NOT reference params.

// GOTCHA: the closeAfterResponse flag MUST be checked ONLY in the success
// branch of handleLine (branch D REQUEST). bye is a REQUEST (has ByeResult in
// BridgeResultMap + is in RequestMethod). Do NOT add it to the notification
// branch — that's out of scope and bye never takes that path.

// CRITICAL (PRD §12): NEVER log or echo the token, the socket path, or the full
// BridgeDescriptor in any response or error message. The ping/bye/getCommands
// results carry pid/cwd/serverVersion (safe) — never the token. The existing
// hello-handler test pattern includes a "SECURITY: TOKEN never appears" sweep;
// replicate it for the new suite.
```

---

## Implementation Blueprint

### Data models and structure

No new data models. All wire types already exist in `extension/protocol.ts` §C:
`PingParams`/`PingResult`, `ByeParams`/`ByeResult`, `GetCommandsParams`/
`GetCommandsResult`, `CommandInfo`. The only structural addition is an OPTIONAL
field on `connection.ts`'s `ConnectionState` (approach (a)):

```typescript
// extension/connection.ts — ConnectionState (approach (a) ONLY)
export interface ConnectionState {
	handshakeComplete: boolean;
	/** Set by a handler (e.g. `bye`) to request a graceful `sock.end()` AFTER
	 *  the success response is flushed. Optional + backward compatible
	 *  (falsy ⇒ no close). Added by S14. */
	closeAfterResponse?: boolean;
}
```

The three handler factory signatures (deps-injected, mirroring S9–S13):

```typescript
// extension/pi-editor-bridge.ts
export function makePingHandler(deps: {
	getPid: () => number;
	getCwd: () => string | undefined;
	getFdAvailable: () => boolean;
	version: string;
}): MethodHandler;

export function makeByeHandler(): MethodHandler;
//   (no deps — bye just acks + sets the close flag)

export function makeGetCommandsHandler(deps: {
	getProvider: () => AutocompleteProvider;
}): MethodHandler;
```

### Implementation Tasks (ordered by dependencies)

```yaml
Task 1: MODIFY extension/connection.ts — add the closeAfterResponse graceful-close path (approach (a))
  - EDIT ConnectionState (after handshakeComplete): add `closeAfterResponse?: boolean;`
    with the doc comment above.
  - EDIT handleLine's success branch (the `(D) REQUEST` try block): immediately
    AFTER `sendResponse(sock, reqId, result);` and BEFORE the `} catch`, add:
      if (state.closeAfterResponse) {
        try { sock.end(); } catch { /* already closing/closed — best-effort */ }
      }
  - MIRROR the existing fatal-close pattern at connection.ts:276-285 EXACTLY
    (the try/catch + sock.end() + best-effort comment). This is the SAME
    mechanism, just on the success branch.
  - DO NOT touch the notification branch, the catch branch, the handshake gate,
    or onConnection. DO NOT change any other handler's behavior.
  - VERIFY backward compat: no existing handler sets closeAfterResponse, so
    every existing test (incl. connection.test.ts 16 tests + hello-handler's
    "success path must NOT close the socket" assertion) stays green.
  - WHY BEFORE THE HANDLERS: bye's handler sets state.closeAfterResponse; the
    dispatch loop must honor it. (If you skip approach (a) and take the minimal
    fallback (c), SKIP this task entirely — bye then just returns {ok:true}.)

Task 2: MODIFY extension/pi-editor-bridge.ts — add getPid + the three handler factories
  - ADD a module-level getter (near getCwd/getFdAvailable):
      /** @returns the pi process PID (S16's BridgeDescriptor also uses this). */
      export function getPid(): number { return process.pid; }
    (Or, if you prefer not to add a module export, inline `getPid: () => process.pid`
     in the ping registration call in Task 4. A named getter is preferred for
     symmetry with getCwd/getFdAvailable and for S16's reuse.)
  - ADD `makePingHandler(deps)` (place it right after makeHelloHandler — it is
    hello's sibling). SYNC. Body:
      return (_params: unknown, _state: ConnectionState): PingResult => ({
        ok: true,
        pid: deps.getPid(),
        cwd: deps.getCwd() ?? "",
        fdAvailable: deps.getFdAvailable(),
        serverVersion: deps.version,
      });
    NO token validation. NO params validation. Field ORDER matches PingResult
    (ok, pid, cwd, fdAvailable, serverVersion) — matches PRD §5.4 + protocol.ts.
  - ADD `makeByeHandler()` (place it after makePingHandler). SYNC. Body:
      return (_params: unknown, state: ConnectionState): ByeResult => {
        state.closeAfterResponse = true; // approach (a): ack THEN half-close
        return { ok: true };
      };
    (Fallback (c) body if you skipped Task 1: `return () => ({ ok: true });`.)
  - ADD `makeGetCommandsHandler(deps)` (place it after makeShouldTriggerFileCompletionHandler
    — it is the {getProvider}-dep family sibling). ASYNC. Body:
      return async (_params: unknown, _state: ConnectionState): Promise<GetCommandsResult> => {
        const provider = deps.getProvider(); // throws plain Error if not captured → -32603 (S15 refines)
        const ac = new AbortController();   // signature requires {signal}; the "/" branch is sync ⇒ no-op
        const result = await provider.getSuggestions(["/"], 0, 1, { signal: ac.signal, force: false });
        if (!result) return { commands: [] };
        return {
          commands: result.items.map((item) => ({
            name: item.value,
            ...(item.description ? { description: item.description } : {}),
          })),
        };
      };
    NO params validation (GetCommandsParams is empty). argumentHint intentionally
    omitted (unrecoverable). A null provider result → {commands:[]}.
  - EXTEND the protocol.ts type import to ALSO bring in:
      PingParams, PingResult, ByeParams, ByeResult, GetCommandsParams, GetCommandsResult, CommandInfo
    (PingParams/ByeParams/GetCommandsParams are imported for completeness/typing
     even though the handlers ignore them — keep the import block tidy.)
  - FOLLOW pattern: every factory is a PURE deps-injected function returning a
    MethodHandler, exactly like makeHelloHandler/makeGetSuggestionsHandler.
  - NAMING: makePingHandler/makeByeHandler/makeGetCommandsHandler (CamelCase
    factories, matching the existing family).

Task 3: MODIFY extension/pi-editor-bridge.ts — register the three handlers in session_start
  - FIND the session_start block. Immediately AFTER the existing S13
    `registerBridgeHandler("shouldTriggerFileCompletion", makeShouldTriggerFileCompletionHandler({ getProvider }));`
    call and BEFORE the `// (S13 DONE). TODO(S14): ping/bye/getCommands.` comment,
    ADD (order: ping, bye, getCommands):
      registerBridgeHandler("ping", makePingHandler({
        getPid, getCwd, getFdAvailable, version: BRIDGE_VERSION,
      }));
      registerBridgeHandler("bye", makeByeHandler());
      registerBridgeHandler("getCommands", makeGetCommandsHandler({ getProvider }));
  - Idempotent (Map.set) — safe across reload/new/resume/fork re-entry (same as S9-S13).
  - UPDATE the TODO comment: `// (S14 DONE). TODO(S16): advertise via process.env.PI_NVIM_BRIDGE ...`
  - UPDATE the file-top STATUS block: add a `STATUS (P1.M2.T6.S14)` note documenting
    that ping/bye/getCommands are now registered, that bye uses the
    closeAfterResponse flag (approach (a)), and that getCommands derives its list
    from provider.getSuggestions(["/"],0,1) (argumentHint unrecoverable — documented).

Task 4: CREATE extension/tests/ping-bye-getcommands-handler.test.ts (UNIT/DISPATCH/REAL)
  - COPY the header imports + fakeSocket()/parseResponses()/readFirstResponse() helpers
    VERBATIM from extension/tests/should-trigger-file-completion-handler.test.ts
    (they are LOCAL per-file helpers, NOT exported — every S9-S13 suite re-declares them).
  - LAYER 1 — UNIT (factory directly + stub deps + fresh ConnectionState):
      ping:
        - happy path → returns PingResult with pid from getPid, cwd from getCwd,
          fdAvailable from getFdAvailable, serverVersion from version. deepEqual the
          full object.
        - getCwd()===undefined → result.cwd==="" (defensive fallback, mirrors hello).
        - sync return → result is a plain object (NOT a Promise); assert
          `result instanceof Promise === false`.
        - exact deps threading → assert deps.getPid/getCwd/getFdAvailable were each
          called once with the stubbed values (use a recording stub).
      bye:
        - returns {ok:true} AND sets state.closeAfterResponse === true.
        - sync return → plain object, not a Promise.
      getCommands:
        - happy path → stub provider.getSuggestions(["/"],0,1,{signal,force:false})
          returns {items:[{value:"model",label:"model",description:"Select model"},{value:"compact",label:"compact"}], prefix:"/"};
          assert result.commands deepEquals [{name:"model",description:"Select model"},{name:"compact"}].
        - description omitted when item.description is absent/empty (compact above → no description key).
        - null result → {commands:[]}; empty items → {commands:[]}.
        - async return → result `instanceof Promise === true`.
        - exact provider call → recording stub asserts getSuggestions was called with
          (["/"], 0, 1) and {signal:[AbortSignal], force:false} (assert force===false
          and signal is an AbortSignal via `signal instanceof AbortSignal`).
        - provider-not-captured → getProvider throws plain Error "not captured" →
          assert it rethrows as a plain Error (NOT BridgeRpcError; -32603 safety net,
          S15 refines). (Mirror S12/S13's provider-not-captured test.)
  - LAYER 2 — DISPATCH (registerBridgeHandler + fakeSocket + handleLine,
    { handshakeComplete: true } for the gated happy paths; pre-handshake regression):
      ping:
        - valid ping → success envelope {id,result:{ok:true,pid,...}}. Assert
          result.pid/serverVersion/cwd/fdAvailable match the stubbed deps. Assert
          state.ended === false (ping must NOT close the socket).
        - pre-handshake ping → exactly ONE -32600 "handshake required: send hello
          first" response (regression: the S10 gate fires before the handler).
      bye:
        - valid bye → success envelope {id,result:{ok:true}} AND state.ended === true
          (approach (a): the closeAfterResponse flag triggered sock.end()).
        - pre-handshake bye → -32600 (gate). (Do NOT assert state.ended here.)
      getCommands:
        - valid → success envelope {id,result:{commands:[…]}} with the stub items.
        - pre-handshake → -32600 (gate).
  - LAYER 3 — REAL integration (ONE real Unix-socket pair):
      - register hello (stubbed getToken/getCwd/getFdAvailable/version) + ping +
        bye + getCommands (stub provider returning the model/compact items).
      - createServer((c) => onConnection(c)); listen on a tmp socket path.
      - client connects; send hello → assert HelloResult (gate opens).
      - send ping → assert result.pid === process.pid, serverVersion === BRIDGE_VERSION.
      - send getCommands → assert result.commands deepEquals the mapped stub items.
      - send bye → assert result {ok:true}; then `await Promise.race([once(client,'close'),
        once(client,'end'), <2s timeout>])` to confirm the server half-closed (approach (a)).
        (client.destroy() in finally; server.close() in finally.)
      - NOTE: register hello with a FIXED token (e.g. "deadbeef".repeat(4)) and the
        same stub deps used across S9-S13 REAL tests, for consistency.
  - SECURITY test: replicate the "SECURITY: TOKEN never appears in any
    ping/bye/getCommands response (PRD §12)" sweep — run a dispatch round-trip for
    each method and assert no write line contains the TOKEN.
  - EVERY test wraps its body in try { … } finally { __resetHandlersForTest(); }.
  - FOLLOW pattern: extension/tests/should-trigger-file-completion-handler.test.ts
    (three layers, fakeSocket, parseResponses, readFirstResponse, node:test +
    assert/strict + jiti). NAMING: `ping-bye-getcommands-handler.test.ts` (kebab,
    matching the family).

Task 5: VALIDATE (see Validation Loop)
  - tsc --noEmit -p extension/tsconfig.json ⇒ exit 0, no output.
  - node --import "$JITI_REG" extension/tests/ping-bye-getcommands-handler.test.ts ⇒ ℹ fail 0.
  - ALL 12 existing suites stay green (incl. connection.test.ts 16 tests +
    hello-handler's "success path must NOT close the socket" — unaffected since
    no existing handler sets closeAfterResponse).
```

### Implementation Patterns & Key Details

```typescript
// === PATTERN 1: deps-injected SYNC factory (ping — mirror makeHelloHandler) ===
// makeHelloHandler is the template; ping drops getToken, adds getPid.
export function makePingHandler(deps: {
	getPid: () => number;
	getCwd: () => string | undefined;
	getFdAvailable: () => boolean;
	version: string;
}): MethodHandler {
	// SYNC: returns the object directly (NOT a Promise). handleLine's `await` is a no-op.
	// NO token check — the S10 gate (connection.ts:234) guarantees post-handshake.
	// NO params validation — PingParams is empty; ignore _params (hello ignores client/clientVersion).
	return (_params: unknown, _state: ConnectionState): PingResult => ({
		ok: true,
		pid: deps.getPid(),
		cwd: deps.getCwd() ?? "", // defensive fallback (mirrors hello's getCwd() ?? "")
		fdAvailable: deps.getFdAvailable(),
		serverVersion: deps.version,
	});
}

// === PATTERN 2: bye — graceful disconnect via the closeAfterResponse flag ===
export function makeByeHandler(): MethodHandler {
	// SYNC. Sets the flag that handleLine's success branch checks (approach (a)).
	// The ack {ok:true} is flushed by sendResponse BEFORE sock.end() runs.
	return (_params: unknown, state: ConnectionState): ByeResult => {
		state.closeAfterResponse = true;
		return { ok: true };
	};
}
// ── connection.ts success branch (Task 1) that honors the flag ──
// 	try {
// 		const result = await handler(params, state);
// 		sendResponse(sock, reqId, result);
// 		if (state.closeAfterResponse) {            // ← S14 bye opt-in
// 			try { sock.end(); } catch { /* best-effort */ }
// 		}
// 	} catch (handlerError) { … existing -32603/BridgeRpcError handling … }
//
// FALLBACK (c) — if you skipped Task 1 (no connection.ts edit), bye is simply:
//   export function makeByeHandler(): MethodHandler {
//     return (): ByeResult => ({ ok: true }); // client closes after ack (PRD §4 step 6)
//   }

// === PATTERN 3: deps-injected ASYNC factory (getCommands — mirror S11/S12/S13) ===
export function makeGetCommandsHandler(deps: {
	getProvider: () => AutocompleteProvider;
}): MethodHandler {
	// ASYNC: getSuggestions is typed Promise (the "/" branch is sync internally,
	// but the method signature is async). A fresh AbortController satisfies the
	// {signal, force} options; abort is a no-op (no fd, no timeout needed).
	return async (_params: unknown, _state: ConnectionState): Promise<GetCommandsResult> => {
		const provider = deps.getProvider(); // plain Error if not captured → -32603 (S15 refines)
		const ac = new AbortController();
		const result = await provider.getSuggestions(["/"], 0, 1, {
			signal: ac.signal,
			force: false,
		});
		if (!result) return { commands: [] };
		// Map AutocompleteItem → CommandInfo. argumentHint is UNRECOVERABLE (pi bakes
		// it into description as "hint — desc"); leave it undefined (protocol marks it `?`).
		return {
			commands: result.items.map((item) => ({
				name: item.value,
				...(item.description ? { description: item.description } : {}),
			})),
		};
	};
}

// === PATTERN 4: registration in session_start (after S13, before TODO(S14)) ===
// 	registerBridgeHandler("ping", makePingHandler({
// 		getPid, getCwd, getFdAvailable, version: BRIDGE_VERSION,
// 	}));
// 	registerBridgeHandler("bye", makeByeHandler());
// 	registerBridgeHandler("getCommands", makeGetCommandsHandler({ getProvider }));
// Idempotent (Map.set) — safe across reload/new/resume/fork (same as S9-S13).
```

### Integration Points

```yaml
CONNECTION.TS (approach (a) ONLY):
  - modify: "ConnectionState — add optional `closeAfterResponse?: boolean` field"
  - modify: "handleLine success branch — add 3-line `if (state.closeAfterResponse) { try { sock.end(); } catch {} }` after sendResponse"
  - preserve: "the catch branch (S15's lane), the notification branch, the handshake gate, onConnection — UNCHANGED"

PI-EDITOR-BRIDGE.TS:
  - add: "getPid() getter (module-level, near getCwd/getFdAvailable) — reused by S16's BridgeDescriptor"
  - add: "makePingHandler / makeByeHandler / makeGetCommandsHandler factories"
  - add: "3 registerBridgeHandler calls in session_start (after S13, before TODO(S14))"
  - extend: "the `import type { … } from './protocol.ts'` block (+Ping/Bye/GetCommands/CommandInfo types)"
  - update: "STATUS block + TODO(S14)→DONE comment"

PROTOCOL.TS:
  - none: "PingParams/PingResult, ByeParams/ByeResult, GetCommandsParams/GetCommandsResult, CommandInfo ALL already defined in §C; BridgeMethod/RequestMethod/BridgeParamsMap/BridgeResultMap all include them in §D. NO CHANGE."

ENV (S16's lane — NOT this task):
  - note: "S16 will read getPid()/getCwd()/getFdAvailable()/getSocketPath()/getToken()/BRIDGE_VERSION to build the PI_NVIM_BRIDGE descriptor. S14 only ADDS getPid() (which S16 reuses); S14 writes NO env var."
```

---

## Validation Loop

### Level 1: Syntax & Type (after the source edits)

```bash
cd /home/dustin/projects/pi-nvim-bridge
tsc --noEmit -p extension/tsconfig.json
# Expected: exit 0, NO output.
# (Type reasoning: PingResult/ByeResult/GetCommandsResult/CommandInfo are all imported
# from protocol.ts. makePingHandler/makeByeHandler return PingResult/ByeResult directly
# (sync) — satisfies MethodHandler's `Promise<unknown> | unknown` union (the `unknown`
# arm). makeGetCommandsHandler is `async` returning Promise<GetCommandsResult> —
# satisfies the `Promise<unknown>` arm. The closeAfterResponse?: boolean on
# ConnectionState is backward compatible. AbortController + AbortSignal are lib dom/es2022
# globals — already used by S11's makeGetSuggestionsHandler, so no tsconfig change.)
```

### Level 2: Unit / component tests (node:test + jiti — NOT vitest)

```bash
JITI_REG=/home/dustin/.local/lib/node_modules/@earendil-works/pi-coding-agent/node_modules/jiti/lib/jiti-register.mjs

# The NEW ping/bye/getCommands suite (UNIT + DISPATCH + REAL)
node --import "$JITI_REG" extension/tests/ping-bye-getcommands-handler.test.ts
# Expected: exit 0, `ℹ fail 0`. (jiti prints a benign DeprecationWarning on Node 26
# stderr — judge by exit code + the `ℹ pass`/`ℹ fail` summary, ignore the warning.)

# Regression: connection dispatch (16 tests) — the closeAfterResponse change is
# backward compatible (no existing handler sets the flag).
node --import "$JITI_REG" extension/tests/connection.test.ts
# Expected: `ℹ tests 16`, `ℹ pass 16`, `ℹ fail 0`.

# Regression: hello handler — its "success path must NOT close the socket"
# (state.ended === false) assertion must STILL pass (hello doesn't set the flag).
node --import "$JITI_REG" extension/tests/hello-handler.test.ts
# Expected: `ℹ fail 0`.

# Regression: the gate still wins pre-handshake for the new methods.
node --import "$JITI_REG" extension/tests/handshake-gate.test.ts
# Expected: `ℹ fail 0`.

# Regression: getSuggestions/applyCompletion/shouldTriggerFileCompletion (additive
# registration alongside the new handlers — no behavior change).
node --import "$JITI_REG" extension/tests/get-suggestions-handler.test.ts
node --import "$JITI_REG" extension/tests/apply-completion-handler.test.ts
node --import "$JITI_REG" extension/tests/should-trigger-file-completion-handler.test.ts
# Expected: `ℹ fail 0` each.

# Full extension suite (no S2–S13 regressions — now 13 files)
for t in extension/tests/*.test.ts; do
  echo "--- $t"
  node --import "$JITI_REG" "$t" 2>/dev/null | grep -E "^ℹ (tests|pass|fail)"
done
# Expected: every file `ℹ fail 0`.
```

### Level 3: Integration (a real socket pair — ping/getCommands/bye end-to-end)

```bash
# Driven by the REAL tests inside ping-bye-getcommands-handler.test.ts.
# To eyeball the wire by hand (optional): hello → ping → getCommands → bye(+close).
JITI_REG=/home/dustin/.local/lib/node_modules/@earendil-works/pi-coding-agent/node_modules/jiti/lib/jiti-register.mjs
node --import "$JITI_REG" -e '
  const { createServer, connect } = require("node:net");
  const { join } = require("node:path"), { tmpdir } = require("node:os"), { randomUUID } = require("node:crypto");
  const { onConnection, registerBridgeHandler } = await import("./extension/connection.ts");
  const { makeHelloHandler, makePingHandler, makeByeHandler, makeGetCommandsHandler, getPid, getCwd, getFdAvailable, BRIDGE_VERSION } = await import("./extension/pi-editor-bridge.ts");
  const { serializeJsonLine, attachJsonlLineReader } = await import("./extension/jsonl-reader.ts");
  const TOKEN = "deadbeef".repeat(4);
  const stub = { getSuggestions: async () => ({ items: [{ value: "model", label: "model", description: "<provider/model> — Select model (opens selector UI)" }, { value: "compact", label: "compact", description: "Manually compact the session context" }], prefix: "/" }), applyCompletion: (lines, cl, cc) => ({ lines, cursorLine: cl, cursorCol: cc }), shouldTriggerFileCompletion: () => true };
  registerBridgeHandler("hello", makeHelloHandler({ getToken:()=>TOKEN, getCwd, getFdAvailable, version:BRIDGE_VERSION }));
  registerBridgeHandler("ping", makePingHandler({ getPid, getCwd, getFdAvailable, version:BRIDGE_VERSION }));
  registerBridgeHandler("bye", makeByeHandler());
  registerBridgeHandler("getCommands", makeGetCommandsHandler({ getProvider: () => stub }));
  const sockpath = join(tmpdir(), `s14-${randomUUID()}.sock`);
  const s = createServer(c=>onConnection(c)); s.listen(sockpath);
  s.once("listening", ()=>{
    const cli = connect(sockpath);
    const read = () => new Promise(res=>{ const d=attachJsonlLineReader(cli,l=>{d();res(JSON.parse(l))}); });
    cli.once("connect", async ()=>{
      cli.write(serializeJsonLine({jsonrpc:"2.0",id:"h1",method:"hello",params:{token:TOKEN}}));
      console.log("hello:", JSON.stringify(await read()));
      cli.write(serializeJsonLine({jsonrpc:"2.0",id:"p1",method:"ping",params:{}}));
      console.log("ping:", JSON.stringify(await read()));
      cli.write(serializeJsonLine({jsonrpc:"2.0",id:"g1",method:"getCommands",params:{}}));
      console.log("getCommands:", JSON.stringify(await read()));
      cli.write(serializeJsonLine({jsonrpc:"2.0",id:"b1",method:"bye",params:{}}));
      console.log("bye:", JSON.stringify(await read()));
      await new Promise(r=>cli.once("close",r)); console.log("client observed close ✓");
      s.close();
    });
  });
'
# Expected:
#   hello:       {"jsonrpc":"2.0","id":"h1","result":{"ok":true,"serverVersion":"0.1.0","cwd":"<getCwd()>","fdAvailable":<bool>}}
#   ping:        {"jsonrpc":"2.0","id":"p1","result":{"ok":true,"pid":<process.pid>,"cwd":"<getCwd()>","fdAvailable":<bool>,"serverVersion":"0.1.0"}}
#   getCommands: {"jsonrpc":"2.0","id":"g1","result":{"commands":[{"name":"model","description":"<provider/model> — Select model (opens selector UI)"},{"name":"compact","description":"Manually compact the session context"}]}}
#   bye:         {"jsonrpc":"2.0","id":"b1","result":{"ok":true}}
#   client observed close ✓     (approach (a): server half-closed after the bye ack)
```

### Level 4: Domain-specific validation (correctness invariants)

```bash
# (a) ping fields exact — asserted in UNIT (deepEqual PingResult) + REAL (pid===process.pid).
# (b) bye closes the socket on the success path — asserted in DISPATCH (state.ended===true)
#     + REAL (client observes close). This is THE S14-specific guarantee for the
#     closeAfterResponse mechanism.
# (c) getCommands derives from getSuggestions(["/"],0,1) — asserted in UNIT (recording
#     stub asserts the exact call args: lines==["/"], cursorLine==0, cursorCol==1,
#     force===false, signal instanceof AbortSignal) + the field mapping (name/description).
# (d) argumentHint is absent — asserted in UNIT (the mapped CommandInfo objects have NO
#     argumentHint key — deepEqual against {name,description?} only).
# (e) empty-params methods ignore _params — asserted by sending ping/bye/getCommands with
#     {foo:"bar"} and still getting success (no -32602). (Add this to the DISPATCH layer.)
# (f) Token value never appears in any ping/bye/getCommands response/stderr (PRD §12):
JITI_REG=/home/dustin/.local/lib/node_modules/@earendil-works/pi-coding-agent/node_modules/jiti/lib/jiti-register.mjs
node --import "$JITI_REG" extension/tests/ping-bye-getcommands-handler.test.ts 2>&1 | grep -c "deadbeefdeadbeefdeadbeefdeadbeef" || true
# Expected: 0 in RESULT payloads (the token appears only in the hello REQUEST the test
# sends, never in a ping/bye/getCommands response — the dedicated SECURITY test asserts
# this precisely per-method).
```

---

## Final Validation Checklist

### Technical Validation
- [ ] `tsc --noEmit -p extension/tsconfig.json` ⇒ exit 0, no output.
- [ ] `node --import "$JITI_REG" extension/tests/ping-bye-getcommands-handler.test.ts` ⇒ exit 0, `ℹ fail 0`.
- [ ] `node --import "$JITI_REG" extension/tests/connection.test.ts` ⇒ `ℹ tests 16`, `ℹ pass 16`, `ℹ fail 0` (closeAfterResponse is backward compatible).
- [ ] `node --import "$JITI_REG" extension/tests/hello-handler.test.ts` ⇒ `ℹ fail 0` (success-path "must NOT close" assertion still holds — hello doesn't set the flag).
- [ ] `node --import "$JITI_REG" extension/tests/handshake-gate.test.ts` ⇒ `ℹ fail 0` (gate still wins pre-handshake for ping/bye/getCommands).
- [ ] `node --import "$JITI_REG" extension/tests/get-suggestions-handler.test.ts` ⇒ `ℹ fail 0` (additive registration).
- [ ] `node --import "$JITI_REG" extension/tests/apply-completion-handler.test.ts` ⇒ `ℹ fail 0` (additive registration).
- [ ] `node --import "$JITI_REG" extension/tests/should-trigger-file-completion-handler.test.ts` ⇒ `ℹ fail 0` (additive registration).
- [ ] Full `for t in extension/tests/*.test.ts` loop ⇒ every file `ℹ fail 0` (13 files now).

### Feature Validation
- [ ] `ping` returns `PingResult` with `pid === process.pid`, `serverVersion === BRIDGE_VERSION` (`"0.1.0"`), `cwd === getCwd() ?? ""`, `fdAvailable === getFdAvailable()`.
- [ ] `bye` returns `{ok:true}` AND the server half-closes (DISPATCH `state.ended === true`; REAL client observes `close`/`end`).
- [ ] `getCommands` returns `{commands:[{name,description?},…]}` derived from `provider.getSuggestions(["/"],0,1)`; `argumentHint` is absent (undefined).
- [ ] A `null`/empty provider `getSuggestions` result yields `{commands:[]}`.
- [ ] Pre-handshake `ping`/`bye`/`getCommands` ⇒ `-32600` "handshake required" (S10 gate).
- [ ] Provider-not-captured in `getCommands` ⇒ `-32603` (safety net; S15 refines).
- [ ] Empty-params methods (`ping`/`bye`/`getCommands` sent with `{foo:"bar"}`) ⇒ success (no `-32602`; params ignored).
- [ ] Token value never appears in any ping/bye/getCommands response (PRD §12 — SECURITY test green).

### Code Quality Validation
- [ ] `makePingHandler`/`makeByeHandler` are SYNC (return the object directly, NOT a Promise); `makeGetCommandsHandler` is ASYNC (`async`/`await`).
- [ ] All three are deps-injected factories mirroring `makeHelloHandler`/`makeGetSuggestionsHandler`.
- [ ] `closeAfterResponse` is OPTIONAL on `ConnectionState` (backward compatible); the success-branch check mirrors the existing fatal-close `sock.end()` pattern (try/catch).
- [ ] TAB indentation, `node:test` + `assert/strict` + jiti (NOT vitest); `fakeSocket`/`parseResponses`/`readFirstResponse` copied verbatim; `__resetHandlersForTest()` in EVERY finally.
- [ ] STATUS block + TODO(S14) comment updated; protocol.ts import block extended with the new types.
- [ ] No new npm dependencies (Node builtins only: `net`/`crypto`/`fs`/`os`/`path` already imported; `process.pid`/`AbortController` are globals).

### Documentation & Deployment
- [ ] The file-top STATUS note documents: bye uses approach (a) (closeAfterResponse); getCommands derives from `getSuggestions(["/"],0,1)` with `argumentHint` unrecoverable (documented limitation).
- [ ] No new env vars written by S14 (S16 owns `PI_NVIM_BRIDGE`); `getPid()` is added for S16's reuse.
- [ ] Logs (if any) print only safe fields (pid/cwd/serverVersion) — NEVER the token.

---

## Anti-Patterns to Avoid

- ❌ Don't validate empty params (`PingParams`/`ByeParams`/`GetCommandsParams` are `Record<string, never>`). There's nothing to narrow; hello's precedent is to IGNORE unknown params. A validator would be pure rejection with no value.
- ❌ Don't have `makeByeHandler` throw `BridgeRpcError({fatal:true})` to close — that returns an ERROR envelope, violating the `ByeResult = {ok:true}` success contract. Use the `closeAfterResponse` flag (approach (a)) instead.
- ❌ Don't change the `MethodHandler` signature to pass `sock` to handlers — that's a cross-cutting change affecting all 8 handlers. The `ConnectionState` flag is the minimal, backward-compatible mechanism.
- ❌ Don't hardcode `BUILTIN_SLASH_COMMANDS` in the bridge for `getCommands` — it's not publicly exported and would DRIFT as pi evolves. Use `provider.getSuggestions(["/"],0,1)`.
- ❌ Don't use `pi.getCommands()` (ExtensionAPI) as the `getCommands` data source — it OMITS the ~23 builtin commands. Use the captured provider.
- ❌ Don't try to recover `argumentHint` by splitting the description on `" — "` — descriptions legitimately contain ` — `. Leave it undefined.
- ❌ Don't add a timeout/supersession to `getCommands`'s `getSuggestions` call — the `/` branch is SYNC + in-memory (no `fd` runaway risk, unlike S11). A fresh `AbortController` satisfies the signature only.
- ❌ Don't add `closeAfterResponse` handling to the notification branch of `handleLine` — `bye` is a REQUEST (dispatched via branch D), not a notification.
- ❌ Don't forget `__resetHandlersForTest()` in EVERY test's `finally` — the handler registry is module-level and persists across `node:test`'s sequential run.
- ❌ Don't log/echo the token anywhere (PRD §12) — `ping`/`bye`/`getCommands` results carry pid/cwd/serverVersion only.
