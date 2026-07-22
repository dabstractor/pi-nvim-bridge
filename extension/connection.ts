/**
 * connection.ts — the connection-handling half of the pi-nvim-bridge IPC server.
 *
 * Sibling of {@link "./jsonl-reader.ts"} (which owns the FRAMING half of parent task
 * P1.M2.T4). For each accepted `net.Socket`, this module wires S7's line reader,
 * parses each line into a JSON-RPC 2.0 envelope, dispatches to a per-method handler
 * registry, writes responses/notifications back via `serializeJsonLine`, and owns the
 * socket `error`/`close` lifecycle (never crash pi, never leak a listener).
 *
 * Dispatch PATTERN mirrors pi's own RPC engine (`packages/coding-agent/src/modes/rpc/
 * rpc-mode.ts` `handleInputLine`, ~L724–800): a `JSON.parse` try/catch → error response
 * on a malformed line; a handler-call try/catch → error response on a throw; always
 * write a response for a REQUEST, never for a NOTIFICATION (JSON-RPC 2.0).
 *
 * STATUS (P1.M2.T4.S8): the connection-handling deliverable. The handler registry is
 * EMPTY here — S9 registers `hello`, S10 adds the handshake gate (reject every method
 * before a valid hello, using `ConnectionState.handshakeComplete`), S11–S14 register
 * getSuggestions/applyCompletion/shouldTriggerFileCompletion/ping+bye+getCommands, and
 * S15 wraps each handler's domain errors into proper JSON-RPC codes. S8 is the
 * dispatch skeleton those tasks hang handlers off — it does NOT implement any handler.
 *
 * PRD refs: §5.3 (envelopes/handshake), §5.4 (methods table — S8 dispatches by these
 * names), §6.5 (handler skeleton — the AbortController/supersession there is S11, not
 * S8), §6.7 ("never throws from handlers", "survives multiple editor open/close cycles"),
 * §11 (pi dies while editor open → socket EOF → close handler detaches cleanly), §12
 * (never log the token — the sock.on("error") log MUST NOT include it).
 *
 * Node builtins only (PRD §6.7). One piece of module state: the handler registry.
 */

import type { Socket } from "node:net";
import { attachJsonlLineReader, serializeJsonLine } from "./jsonl-reader.ts";
import type { JsonRpcError } from "./protocol.ts";

/** Options for {@link BridgeRpcError}. `fatal` opts in to a graceful `sock.end()`
 *  after the error response is flushed (only `hello`'s bad-token path uses `fatal:true`). */
export interface BridgeRpcErrorOptions {
	fatal?: boolean;
}

/**
 * Typed JSON-RPC error a handler THROWS to request a SPECIFIC error code (and,
 * optionally, to close the connection after replying). {@link handleLine} maps it →
 * `{jsonrpc,id,error:{code,message}}` and, when `fatal`, graceful `sock.end()`.
 * Any OTHER thrown value falls through to the last-resort `-32603` (S8 safety net).
 *
 * Codes are the JSON-RPC 2.0 reserved range: -32700 parse, -32600 invalid
 * request / bad token (PRD §5.3), -32601 method not found, -32602 invalid
 * params, -32603 internal error.
 *
 * STATUS (P1.M2.T5.S9): foundation S15 ("wrap handlers' domain errors into
 * proper codes") builds on. S9's `hello` is the first caller
 * (bad token → `BridgeRpcError(-32600, "bad token", { fatal: true })`).
 */
export class BridgeRpcError extends Error {
	readonly code: number;
	readonly fatal: boolean;
	constructor(code: number, message: string, options?: BridgeRpcErrorOptions) {
		super(message);
		this.name = "BridgeRpcError";
		this.code = code;
		this.fatal = options?.fatal ?? false;
	}
}

/**
 * Convert any thrown value into a {@link BridgeRpcError} for a handler's domain-error path.
 * Pass-through if `err` is already a BridgeRpcError (so params-validation `-32602` and
 * `hello`'s `-32600` keep their intentional codes); otherwise wrap into `-32603` (JSON-RPC
 * "internal error") with a sanitized, context-prefixed message.
 *
 * STATUS (P1.M2.T7.S15): shared converter the 4 provider-dependent handlers
 * (`getSuggestions` / `applyCompletion` / `shouldTriggerFileCompletion` / `getCommands`)
 * use to wrap their domain errors (provider-not-captured, provider-runtime-throw) into
 * proper JSON-RPC codes BEFORE they reach {@link handleLine}'s `-32603` last-resort
 * safety net — so the safety net becomes truly last-resort. `-32603` is the JSON-RPC
 * "internal error" code; the `-32000..-32099` server range is reserved for *distinguished*
 * modes clients branch on (`research/jsonrpc-error-best-practices.md` §2) — the Neovim
 * client treats ALL completion errors as silent-degrade (PRD §11), so a single
 * interoperable `-32603` with a descriptive message beats inventing a `-320xx` taxonomy
 * no client acts on. The message NEVER contains the token (the token lives in a separate
 * module-level secret; the SECURITY sweep stays green).
 */
export function toBridgeRpcError(err: unknown, context: string): BridgeRpcError {
	if (err instanceof BridgeRpcError) return err;
	const detail = err instanceof Error ? err.message : String(err);
	return new BridgeRpcError(-32603, `${context}: ${detail}`);
}

/** Per-connection state. S8 creates it fresh (`handshakeComplete:false`) inside each
 *  {@link onConnection} call; two sockets get two independent states. S9 sets
 *  `handshakeComplete=true` on a valid `hello`; S10 gates every non-hello method on it. */
export interface ConnectionState {
	handshakeComplete: boolean;
	/** Set by a handler (e.g. `bye`) to request a graceful `sock.end()` AFTER
	 *  the success response is flushed. Optional + backward compatible
	 *  (falsy ⇒ no close ⇒ all existing handlers/tests unaffected). Added by S14. */
	closeAfterResponse?: boolean;
}

/**
 * A per-method RPC handler. Receives the (still-`unknown`) `params` — each handler
 * narrows further (e.g. `hello` narrows to `HelloParams`, `getSuggestions` to
 * `GetSuggestionsParams`) — and the connection {@link ConnectionState} (so `hello`
 * can flip `handshakeComplete`). Returns the success `result` (written as
 * `{jsonrpc,id,result}`) or THROWS (S8's loop catch writes `-32603`; S15 makes each
 * handler catch its OWN domain errors into proper codes BEFORE throwing).
 *
 * Async to support `getSuggestions` (S11), which awaits pi's live provider.
 */
export type MethodHandler = (
	params: unknown,
	state: ConnectionState,
) => Promise<unknown> | unknown;

/**
 * The per-method handler registry. MODULE-LEVEL (shared across all connections —
 * handlers don't vary per connection). EMPTY in S8; S9–S14 populate it via
 * {@link registerBridgeHandler}.
 *
 * Registered FROM `pi-nvim-bridge.ts` (S9–S14), NOT here — so each handler closure
 * references `getToken()`/`getProvider()` in THAT module and `connection.ts` never
 * imports `pi-nvim-bridge.ts` (no import cycle — research §2).
 */
const handlers = new Map<string, MethodHandler>();

/**
 * The live set of connected, not-yet-closed sockets and their per-connection state.
 * Populated by {@link onConnection}; drained by each socket's `close` handler and by
 * {@link closeAllConnections}. Iterated by {@link broadcastNotification} (handshaken
 * entries only). MODULE-LEVEL (shared across all connections — one bridge, one set).
 *
 * STATUS (P1.M3.T9.S17): the connection registry introduced so the server can PUSH an
 * S→C notification (`commandsChanged`) to every authenticated peer and fully tear down
 * every accepted socket on `stopBridge` (Node's `net.Server.close()` only stops
 * accepting NEW connections — it KEEPS existing ones; see {@link closeAllConnections}).
 * It is a `Map<Socket, ConnectionState>` (NOT a bare `Set<Socket>`) because the
 * broadcast filter needs `state.handshakeComplete` alongside the socket (PRD §12:
 * never push to an unauthenticated peer).
 */
const connections = new Map<Socket, ConnectionState>();

/**
 * Register (or replace) the handler for a JSON-RPC method name. Idempotent
 * (`Map.set`). S9 registers `"hello"`; S11–S14 register the rest. Re-registering on
 * each `session_start` (reload/new/resume/fork) is safe — the handler closures read
 * live state via `getToken()`/`getProvider()` getters, so they always see the current
 * provider/token.
 *
 * STATUS (P1.M2.T4.S8): the extension point S9–S14 call. S8 registers NOTHING.
 */
export function registerBridgeHandler(method: string, fn: MethodHandler): void {
	handlers.set(method, fn);
}

/** Write a JSON-RPC 2.0 success response (`{jsonrpc:"2.0",id,result}`), LF-terminated.
 *  Uses S7's `serializeJsonLine` + `sock.write`. Ignores the write return (backpressure
 *  is a documented v1 non-issue — bridge responses are tiny; PRD §15 future). */
export function sendResponse(sock: Socket, id: string, result: unknown): boolean {
	return sock.write(serializeJsonLine({ jsonrpc: "2.0", id, result }));
}

/** Write a JSON-RPC 2.0 error response. `id` is `string|null`: `null` when no id was
 *  inferable (parse failure, invalid envelope). Used by S9 for the `-32600` "bad token"
 *  handshake error (PRD §5.3). */
export function sendError(
	sock: Socket,
	id: string | null,
	code: number,
	message: string,
): boolean {
	const error: JsonRpcError = { code, message };
	return sock.write(serializeJsonLine({ jsonrpc: "2.0", id, error }));
}

/** Write a JSON-RPC 2.0 NOTIFICATION (no `id`, no reply expected). S17's
 *  `commandsChanged` (S→C) uses this. `params` omitted from the wire when `undefined`. */
export function sendNotification(
	sock: Socket,
	method: string,
	params?: unknown,
): boolean {
	const envelope: Record<string, unknown> = { jsonrpc: "2.0", method };
	if (params !== undefined) envelope.params = params;
	return sock.write(serializeJsonLine(envelope));
}

/**
 * Write a JSON-RPC 2.0 NOTIFICATION to every HANDSHAKEN connected socket. Filters on
 * `state.handshakeComplete` (PRD §12: never push to an unauthenticated peer; the Neovim
 * client only processes notifications AFTER its own `hello`). Reuses the per-socket
 * {@link sendNotification} primitive. `params` omitted on the wire when `undefined`.
 *
 * Best-effort: a dead socket's `'error'` is already handled by {@link onConnection}'s
 * error handler — this function does not double-handle it.
 *
 * STATUS (P1.M3.T9.S17): the server→client PUSH primitive `session_start` calls as
 * `broadcastNotification("commandsChanged")` after every (re)start so connected
 * editors can invalidate their command cache (downstream consumers P2.M5.T16.S27 /
 * P3.M10.T26.S41). HONEST PROPERTY: in the current tear-down-on-reload architecture
 * the registry is EMPTY at every realistic session_start (to type `/reload` the TUI
 * must be active ⇒ no external editor open), so the broadcast is structurally
 * quiescent in v1 — it is correctly wired and activates the moment a future change
 * lets a connection survive a session boundary (PRD §15 future enhancement).
 */
export function broadcastNotification(method: string, params?: unknown): void {
	for (const [sock, state] of connections) {
		if (state.handshakeComplete) sendNotification(sock, method, params);
	}
}

/**
 * Force-close (graceful `end()`, NOT `destroy()`) every tracked socket and clear the
 * registry. Iterates a SNAPSHOT (`[...connections.keys()]`) so a synchronous
 * `'close'`→`delete` mid-loop cannot mutate the map under us, then `connections.clear()`
 * guarantees the empty state. Idempotent (empty registry → no-op).
 *
 * REQUIRED in {@link stopBridge} (pi-nvim-bridge.ts) because Node's
 * `net.Server.close()` only stops ACCEPTING new connections — it does NOT close
 * already-accepted sockets (verified, scout Q2). Without this, `stopBridge` would
 * orphan any editor socket open during a `/reload` (still connected, untracked,
 * validating against the NEW token → -32600).
 *
 * Uses `sock.end()` (graceful FIN) — NOT `sock.destroy()` (RST) — to match the
 * existing `bye`/fatal-close `sock.end()` pattern; lets in-flight writes flush and
 * gives the remote a clean EOF (the Neovim plugin's silent-degrade path, PRD §11).
 *
 * STATUS (P1.M3.T9.S17): the teardown half of the registry. A no-op in every
 * realistic scenario (the registry is empty on reload — see {@link broadcastNotification}).
 */
export function closeAllConnections(): void {
	for (const sock of [...connections.keys()]) {
		try {
			sock.end();
		} catch {
			/* already closing/closed — best-effort */
		}
	}
	connections.clear();
}

/** Test seam: clear the registry (module-level — isolate between tests). */
export function __resetHandlersForTest(): void {
	handlers.clear();
}
/** Test seam: does a handler exist for `method`? (assertions about dispatch routing.) */
export function __hasHandlerForTest(method: string): boolean {
	return handlers.has(method);
}
/** Test seam: clear the connection registry (module-level — isolate between tests). */
export function __resetConnectionsForTest(): void {
	connections.clear();
}
/** Test seam: how many sockets are currently tracked? (assertions about registry lifecycle.) */
export function __getActiveConnectionCountForTest(): number {
	return connections.size;
}
/** Test seam: read a socket's stored state (so a UNIT test can flip `handshakeComplete`). */
export function __getConnectionStateForTest(sock: Socket): ConnectionState | undefined {
	return connections.get(sock);
}

/**
 * Parse + narrow + dispatch a single (complete, `\r`-stripped) JSONL line. Mirrors
 * pi's `handleInputLine` PATTERN: separate try/catch for the parse vs the handler call;
 * ALWAYS write a response for a REQUEST; NEVER for a NOTIFICATION (JSON-RPC 2.0).
 *
 * Narrowing (research §4): a line that is not a non-null object, OR lacks `method`,
 * is an INVALID request → `-32600` (id = the parsed `id` if it's a string, else null).
 * A line with a string `id` is a REQUEST → dispatch (registered handler → result
 * response on return / `-32603` on throw; unregistered → `-32601`). A line with NO
 * string `id` is a NOTIFICATION → call the handler if registered, write NO response.
 *
 * The bridge RESTRICTS `id` to `string` (PRD §5.3); a numeric/null `id` is treated as
 * malformed (`-32600`).
 *
 * ASYNC and fire-and-forget from the reader's `onLine` (`void handleLine(...)`). The
 * loop-level try/catches convert EVERY throw into an error RESPONSE — never an unhandled
 * rejection (which would crash pi, violating PRD §6.7). S15 makes each handler catch its
 * OWN domain errors before they reach the `-32603` safety net.
 *
 * STATUS (P1.M2.T4.S8): the dispatch unit. S9 added `hello` via registerBridgeHandler
 * (no change here); S10 added the handshake gate (a single guard placed BEFORE the
 * notification/request split — see inline) that rejects every method except `hello`
 * until `state.handshakeComplete` is true (flipped by S9's hello handler on a correct
 * token). The registry is EMPTY in S8.
 */
export async function handleLine(
	sock: Socket,
	state: ConnectionState,
	line: string,
): Promise<void> {
	// (A) PARSE — try/catch → -32700. (pi mirror: try { JSON.parse } catch { output parse error }.)
	let parsed: unknown;
	try {
		parsed = JSON.parse(line);
	} catch (parseError) {
		sendError(
			sock,
			null,
			-32700,
			`parse error: ${parseError instanceof Error ? parseError.message : String(parseError)}`,
		);
		return;
	}

	// (B) NARROW — must be a non-null object with a string `method` (research §4).
	const idField = (parsed as { id?: unknown } | null)?.id;
	const id: string | null = typeof idField === "string" ? idField : null;
	const isRequest = typeof idField === "string";

	if (
		typeof parsed !== "object" ||
		parsed === null ||
		!("method" in parsed) ||
		typeof (parsed as { method: unknown }).method !== "string"
	) {
		sendError(sock, id, -32600, "invalid request: not a JSON-RPC 2.0 request/notification");
		return;
	}

	const method = (parsed as { method: string }).method;
	const params = (parsed as { params?: unknown }).params; // unknown — each handler narrows.
	const handler = handlers.get(method);

	// `id` discipline (research §4): the bridge RESTRICTS id to string (PRD §5.3). A message
	// with an `id` key whose value is NOT a string (number/null/object/…) is INVALID → -32600.
	// A message with NO `id` key at all is a NOTIFICATION (no response). A string `id` is a REQUEST.
	if ("id" in (parsed as object) && typeof idField !== "string") {
		sendError(sock, null, -32600, "invalid request: id must be a string");
		return;
	}

	// S10 handshake gate (PRD §12): reject every method except "hello" until S9's hello
	// handler flips `state.handshakeComplete` on a correct token. Placed BEFORE the
	// notification/request split so it defends BOTH branches (the registry is
	// module-level — a pre-handshake notification must not reach a registered handler
	// either). NON-FATAL: consistent with the parse (-32700) and envelope-narrow (-32600)
	// paths here, which call sendError directly and do NOT close; only bad-token hello
	// closes (S9, via BridgeRpcError fatal). The token is the real boundary (PRD §12);
	// an unauthenticated peer can never flip this flag, so it is permanently locked out
	// of results regardless. The gate fires BEFORE registry lookup, so an UNREGISTERED
	// method sent pre-handshake returns -32600 (NOT -32601).
	if (method !== "hello" && !state.handshakeComplete) {
		if (isRequest) {
			sendError(sock, id as string, -32600, "handshake required: send hello first");
		}
		// Notification (no string id): JSON-RPC 2.0 forbids a response. Drop silently.
		return;
	}

	// (C) NOTIFICATION (no string id) — call handler if registered, NEVER write a response.
	if (!isRequest) {
		if (handler) {
			try {
				await handler(params, state);
			} catch (handlerError) {
				// Notifications have no id → no response. Log (NEVER the token — PRD §12); do not throw.
				console.error(
					`pi-nvim-bridge: notification "${method}" handler threw: ${
						handlerError instanceof Error ? handlerError.message : String(handlerError)
					}`,
				);
			}
		}
		return;
	}

	// (D) REQUEST — registered → result on return / -32603 on throw; unregistered → -32601.
	// `id` is a non-null string here (isRequest ⇒ typeof idField === "string").
	const reqId = id as string;
	if (!handler) {
		sendError(sock, reqId, -32601, `method not found: ${method}`);
		return;
	}
	try {
		const result = await handler(params, state);
		sendResponse(sock, reqId, result);
		// S14: a handler (e.g. `bye`) may request a graceful half-close AFTER the
		// success response is flushed. Mirrors the fatal-close `sock.end()` pattern
		// in the catch branch (PRD §5.3 "reply then close"). try/catch-wrapped,
		// best-effort — the socket may already be closing/closed. REQUEST branch
		// only (bye is a REQUEST, NOT a notification).
		if (state.closeAfterResponse) {
			try {
				sock.end();
			} catch {
				/* already closing/closed — best-effort */
			}
		}
	} catch (handlerError) {
		// S9: a handler may throw a typed BridgeRpcError to request a SPECIFIC error
		// code (and, when fatal, a graceful close after the error is flushed). Only the
		// `hello` bad-token path uses fatal:true (PRD §5.3 "then close"). S15 will throw
		// non-fatal BridgeRpcErrors broadly (wrap domain errors into proper codes).
		if (handlerError instanceof BridgeRpcError) {
			sendError(sock, reqId, handlerError.code, handlerError.message);
			if (handlerError.fatal) {
				// "reply then close" (PRD §5.3): end() flushes the queued error write then
				// half-closes (FIN); the existing 'close' handler detaches the reader.
				try {
					sock.end();
				} catch {
					/* already closing/closed — best-effort */
				}
			}
		} else {
			// S8's safety net: a request must ALWAYS get a response (never hang the
			// client's RPC timeout). S15 makes each handler catch its OWN domain errors
			// into proper codes BEFORE throwing, so this is the last-resort -32603.
			sendError(
				sock,
				reqId,
				-32603,
				`internal error: ${handlerError instanceof Error ? handlerError.message : String(handlerError)}`,
			);
		}
	}
}

/**
 * The `net.Server` connection callback `startBridge` passes to `createServer`. For each
 * accepted socket: create a fresh {@link ConnectionState}, wire S7's line reader (each
 * complete line → `void handleLine(sock, state, line)`), and own the socket lifecycle:
 *
 *  - `sock.on("error", …)` — an UNHANDLED socket `'error'` (ECONNRESET, EPIPE,
 *    client-killed) THROWS and crashes pi (Node EventEmitter contract — same as the
 *    `net.Server` 'error' S6 handled). Log the Error.message (NEVER the token /
 *    BridgeDescriptor — PRD §12), `detach()` the reader, `sock.destroy()`. NEVER rethrow.
 *  - `sock.on("close", …)` — fires on normal disconnect AND after `'error'`. `detach()`
 *    (idempotent) so no `data`/`end` listener leaks across the many editor open/close
 *    cycles one session sees (PRD §6.7).
 *
 * STATUS (P1.M2.T4.S8): the entry point `pi-nvim-bridge.ts`'s `startBridge` wires into
 * `__deps.createServer((sock) => onConnection(sock))`. State starts `handshakeComplete:false`;
 * S9's hello handler flips it true; S10's gate reads it. S8 creates the state but does NOT
 * gate (S10) or validate (S9).
 */
export function onConnection(sock: Socket): void {
	const state: ConnectionState = { handshakeComplete: false };
	connections.set(sock, state); // S17: track for broadcast/teardown

	const detach = attachJsonlLineReader(sock, (line) => {
		void handleLine(sock, state, line); // fire-and-forget; loop-level catches → responses, never rejections.
	});

	sock.on("error", (err: Error) => {
		// CRITICAL: no listener here = process crash. Log message ONLY (never the token — PRD §12).
		console.error(`pi-nvim-bridge: socket error: ${err?.message ?? err}`);
		try {
			detach();
		} catch {
			/* idempotent best-effort */
		}
		try {
			sock.destroy();
		} catch {
			/* already destroyed */
		}
	});

	sock.on("close", () => {
		connections.delete(sock); // S17: idempotent removal (close fires after error too)
		try {
			detach(); // idempotent — removes the reader's data/end listeners only.
		} catch {
			/* idempotent best-effort */
		}
	});
}
