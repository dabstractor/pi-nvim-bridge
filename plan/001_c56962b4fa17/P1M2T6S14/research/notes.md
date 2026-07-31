# S14 Research Notes — `ping`, `bye`, `getCommands` handlers

Source of truth for the PRP. Verified against `~/projects/pi` (pi monorepo) + the local
`extension/` tree. Three handlers; two are trivial (`ping`, `bye`), one needs a data
source decision (`getCommands`).

## §1. `ping` — liveness + server info (near-identical to `hello`)

### §1.1 Wire contract (PRD §5.4 + protocol.ts §C)
- Params: `PingParams = Record<string, never>` (empty).
- Result: `PingResult = { ok: true; pid: number; cwd: string; fdAvailable: boolean; serverVersion: string }`.
- `ping` result = `HelloResult` + `pid`. Field-for-field identical otherwise.

### §1.2 NO token validation
`ping` is a REQUEST (in `RequestMethod`, has `PingResult`). It is dispatched via `handleLine`
branch (D) REQUEST. The S10 handshake gate (`connection.ts:234`:
`if (method !== "hello" && !state.handshakeComplete)`) fires BEFORE registry lookup, so an
unauthenticated `ping` is rejected with `-32600` "handshake required" and never reaches the
handler. ⇒ `makePingHandler` needs NO `getToken` dep.

### §1.3 Deps (deps-injected factory, mirrors `makeHelloHandler`)
| Dep | Existing? | Source |
|---|---|---|
| `getCwd` | ✅ | `pi-editor-bridge.ts` `getCwd()` → `string\|undefined` (use `?? ""`) |
| `getFdAvailable` | ✅ | `pi-editor-bridge.ts` `getFdAvailable()` → `boolean` |
| `version` | ✅ | `BRIDGE_VERSION` (`"0.1.0"`) |
| `getPid` | ❌ NEW | `() => process.pid` (PRD §4 step 2 `"pid":12345`; S16 descriptor also uses `process.pid`) |

Inject `getPid: () => number` for testability symmetry with the other getters. SYNC return.

### §1.4 Params handling — IGNORE (no validator)
`PingParams` is empty ⇒ nothing to narrow. Consistent with `makeHelloHandler` (which silently
ignores `client`/`clientVersion` and any extra fields), `ping` should ignore `_params` entirely.
Do NOT add a `narrowPingParams` that rejects `{foo:"bar"}` — pure rejection with no value.

## §2. `bye` — graceful disconnect ack

### §2.1 Current `handleLine` CANNOT close on the success path
`connection.ts:67-70` — `MethodHandler` signature has NO `sock`:
```ts
export type MethodHandler = (params: unknown, state: ConnectionState) => Promise<unknown> | unknown;
```
`connection.ts:266-269` — success path; after `sendResponse(sock, reqId, result)` it returns
WITHOUT closing:
```ts
	try {
		const result = await handler(params, state);
		sendResponse(sock, reqId, result);
	} catch (handlerError) {
```
Closing only happens on the ERROR path, gated on `BridgeRpcError.fatal`
(`connection.ts:274-285`). `ConnectionState` today is only `{ handshakeComplete: boolean }`.

### §2.2 Three approaches
- **(a) Add `closeAfterResponse?: boolean` to `ConnectionState`** (RECOMMENDED). bye sets
  `state.closeAfterResponse = true`, returns `{ok:true}`; `handleLine` checks the flag after
  `sendResponse` and calls `sock.end()` (try/catch, mirroring the fatal-close pattern at
  `connection.ts:276-285`). Backward compatible (optional field ⇒ falsy ⇒ no close ⇒ all 5
  existing handlers + 16 connection tests unaffected). S8/S10 are COMPLETE, so editing
  `connection.ts` is safe. Orthogonal to S15 (S15 edits the `catch`/error branch; (a) adds to
  the `try`/success branch — small merge surface).
- **(b) bye throws `BridgeRpcError({fatal:true})`** — REJECTED. Returns an ERROR envelope
  `{jsonrpc,id,error}`, NOT `ByeResult = {ok:true}`. Violates the success contract + PRD §5.4.
- **(c) bye returns `{ok:true}`; CLIENT closes after ack** — acceptable MINIMAL alternative.
  PRD §4 step 6: "Neovim closes the socket on `VimLeavePre`. pi closes + unlinks the socket on
  `session_shutdown`." Nothing in §4/§5/§6/§11 REQUIRES the server to close on `bye`. Zero
  `connection.ts` change. Less robust (a client that sends bye then hangs lingers until next
  EOF), but PRD-sufficient.

### §2.3 Recommendation
**PRIMARY: approach (a)** — delivers genuine "graceful disconnect" (server half-closes after
acking), robust against misbehaving clients, backward compatible, owned files (S8/S10)
complete. **(c) documented as the minimal alternative.** **(b) rejected.**

### §2.4 Exact minimal diff for (a)
Edit 1 — `connection.ts` `ConnectionState` (add optional field):
```ts
export interface ConnectionState {
	handshakeComplete: boolean;
	/** Set by a handler (e.g. `bye`) to request a graceful `sock.end()` AFTER the
	 *  success response is flushed. Optional + backward compatible (falsy ⇒ no close). */
	closeAfterResponse?: boolean;
}
```
Edit 2 — `connection.ts` `handleLine` success branch (after `sendResponse`):
```ts
	const result = await handler(params, state);
	sendResponse(sock, reqId, result);
	if (state.closeAfterResponse) {   // S14 `bye` opt-in: ack THEN half-close
		try { sock.end(); } catch { /* already closing/closed — best-effort */ }
	}
```
bye handler (in `pi-editor-bridge.ts`):
```ts
export function makeByeHandler(): MethodHandler {
	return (_params, state): ByeResult => {
		state.closeAfterResponse = true;
		return { ok: true };
	};
}
```

## §3. `getCommands` — data-source decision (the ONE non-trivial handler)

### §3.1 `pi.getCommands()` EXISTS on `ExtensionAPI` — but is INSUFFICIENT
`~/projects/pi/packages/coding-agent/src/core/extensions/types.ts:1311`:
```ts
/** Get available slash commands in the current session. */
getCommands(): SlashCommandInfo[];
```
Impl (`agent-session.ts:2312-2334`) returns extension commands + prompt templates + skills
mapped to `SlashCommandInfo{name, description?, source, sourceInfo}`.
**CRITICAL GAP: it OMITS `BUILTIN_SLASH_COMMANDS`** (~23 builtins: `/model`, `/compact`,
`/reload`, `/quit`, …). Also `SlashCommandInfo` has NO `argumentHint` field.

### §3.2 `BUILTIN_SLASH_COMMANDS` is NOT publicly exported
`slash-commands.ts:14-18`:
```ts
export interface BuiltinSlashCommand { name: string; description: string; argumentHint?: string; }
```
`slash-commands.ts:19-44` — the const array (23 entries; only `model` + `login` have
`argumentHint`). `grep` of `packages/coding-agent/src/index.ts` for
`BUILTIN_SLASH_COMMANDS`/`BuiltinSlashCommand` = ZERO matches. An extension CANNOT import it.
Hardcoding the 23 entries in the bridge would DRIFT as pi evolves. NOT recommended.

### §3.3 BEST PATH: `getSuggestions(["/"], 0, 1)` on the CAPTURED live provider ✅
The bridge already captures the live provider via the pass-through factory
(`getProvider()` in `pi-editor-bridge.ts:112-120` — same dep S11/S12/S13 use). The captured
provider IS a `CombinedAutocompleteProvider` built in `interactive-mode.ts:538-620`
(`createBaseAutocompleteProvider`) from builtins + templates + extensions + skills.

Calling `provider.getSuggestions(["/"], 0, 1, {signal, force:false})` hits the slash branch
(`autocomplete.ts:118-165`): `textBeforeCursor = "/"`, `startsWith("/")` true, `spaceIndex===-1`
true, `prefix = ""`. `fuzzyFilter` with empty query returns ALL items (`fuzzy.ts:81-83`).
⇒ Returns `{items: AutocompleteItem[], prefix:"/"}` covering EVERY command category.

Field mapping (AutocompleteItem → CommandInfo):
```
item.value      → name            (command name WITHOUT leading slash)
item.description → description?    (pi BAKES argumentHint in as "hint — desc" — NOT separable)
argumentHint    → undefined       (NOT recoverable from AutocompleteItem; protocol marks it `?`)
```

### §3.4 `argumentHint` is UNRECOVERABLE via the provider path
`AutocompleteItem` (`autocomplete.ts:64-68`) = `{value, label, description?}` — no
`argumentHint`. pi's slash branch bakes the hint into `description`:
`hint ? (desc ? \`${hint} — ${desc}\` : hint) : desc`. Trying to split on `" — "` is fragile
(descriptions legitimately contain ` — `). ⇒ `argumentHint` stays `undefined` via this path.
This is ACCEPTABLE — `protocol.ts` marks `CommandInfo.argumentHint` optional. The combined
`description` still carries the hint text for display.

### §3.5 Handler shape (ASYNC — getSuggestions is typed Promise)
```ts
export function makeGetCommandsHandler(deps: { getProvider: () => AutocompleteProvider }): MethodHandler {
	return async (_params, _state): Promise<GetCommandsResult> => {
		const provider = deps.getProvider(); // throws plain Error if not captured → -32603 (S15 refines)
		const ac = new AbortController();    // required by signature; the "/" branch is SYNC so abort is a no-op
		const result = await provider.getSuggestions(["/"], 0, 1, { signal: ac.signal, force: false });
		if (!result) return { commands: [] };
		return {
			commands: result.items.map((item) => ({
				name: item.value,
				...(item.description ? { description: item.description } : {}),
			})),
		};
	};
}
```
- The `/` branch is guaranteed SYNC + in-memory (NO `fd`, NO @file path) ⇒ resolves
  essentially immediately; NO timeout needed (unlike S11's `fd` risk). A fresh
  `AbortController` satisfies the signature only.
- `getCommands` is OPTIONAL (PRD §5.4 marks it "for richer docs menus"). Returning a
  best-effort list (no argumentHint) is fine.
- Ignore `_params` (GetCommandsParams = empty) — same as ping/bye/hello.

## §4. Test conventions (verified — node:test + jiti, NOT vitest)
- Runner: `JITI_REG=/home/dustin/.local/lib/node_modules/@earendil-works/pi-coding-agent/node_modules/jiti/lib/jiti-register.mjs`
  then `node --import "$JITI_REG" extension/tests/<file>.test.ts`.
- Type check: `tsc --noEmit -p extension/tsconfig.json`.
- Three layers per handler suite: UNIT (factory directly + stub deps + fresh
  `ConnectionState`), DISPATCH (`registerBridgeHandler` + `fakeSocket` + `handleLine`),
  REAL (ONE real Unix-socket pair; `createServer`+`connect`; `hello` first to open the gate).
- `fakeSocket()`/`parseResponses()`/`readFirstResponse` copied VERBATIM from the S11/S12/S13
  suites (LOCAL per-file helpers, NOT exported).
- `__resetHandlersForTest()` in EVERY test's `finally`.
- TOKEN never leaks (PRD §12) — a dedicated "SECURITY" test grep-sweeps responses.

## §5. Files this task touches
- `extension/pi-editor-bridge.ts` — ADD `makePingHandler`, `makeByeHandler`,
  `makeGetCommandsHandler`; register all three in `session_start` (after S13); add a
  `getPid` getter (or inline `() => process.pid` in the registration); extend the protocol.ts
  type import; update STATUS block + TODOs.
- `extension/connection.ts` — (approach (a) ONLY) add optional `closeAfterResponse?: boolean`
  to `ConnectionState` + the success-branch `sock.end()` check. Backward compatible.
- `extension/tests/ping-bye-getcommands-handler.test.ts` (NEW) — UNIT/DISPATCH/REAL.
- `extension/protocol.ts` — UNCHANGED (`PingParams/PingResult`, `ByeParams/ByeResult`,
  `GetCommandsParams/GetCommandsResult`, `CommandInfo` all already defined in §C).

## §6. Downstream consumers
- `ping`: P3.M10.T27.S42 (`:checkhealth pi-editor`) — liveness + version diagnostics.
- `bye`: P2.M9.T23.S38 (Neovim `VimLeavePre`/`ExitPre` sends bye before closing).
- `getCommands`: OPTIONAL docs-menu UX (PRD §15 "Hover docs" future enhancement); no v1
  P2 consumer is gated on it, but it rounds out the §5.4 methods table.
