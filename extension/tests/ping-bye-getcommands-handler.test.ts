/**
 * ping-bye-getcommands-handler.test.ts — P1.M2.T6.S14
 * `ping` / `bye` / `getCommands` handlers (unit + dispatch + integration).
 *
 * S14 lands the FINAL three JSON-RPC method handlers from PRD §5.4, completing the
 * M2.T6 handler family alongside S9(hello)/S11(getSuggestions)/S12(applyCompletion)/
 * S13(shouldTriggerFileCompletion). The three factories mirror the existing deps-
 * injected pattern:
 *
 *  - `makePingHandler({getPid,getCwd,getFdAvailable,version})` — SYNC liveness/
 *    diagnostics handler returning `PingResult` (HelloResult + a `pid` field). It is
 *    `makeHelloHandler` MINUS the token branch (the S10 handshake gate in
 *    connection.ts already guarantees `state.handshakeComplete===true` before any
 *    non-hello method runs, so ping NEVER sees an unauthenticated caller).
 *  - `makeByeHandler()` — SYNC graceful-disconnect ack returning `{ok:true}` AND
 *    requesting a server-side half-close via the NEW `state.closeAfterResponse` flag
 *    (approach (a); the only connection.ts change in S14). `handleLine`'s success
 *    branch checks that flag AFTER `sendResponse` flushes the ack and calls
 *    `sock.end()` (mirroring the existing fatal-close pattern).
 *  - `makeGetCommandsHandler({getProvider})` — ASYNC optional docs-menu method. It
 *    derives the command list from `provider.getSuggestions(["/"],0,1)` on the
 *    captured provider (covers builtins + templates + extensions + skills) and maps
 *    each `AutocompleteItem{value,label,description?}` → `CommandInfo{name,
 *    description?}`. `argumentHint` is unrecoverable and left `undefined`.
 *
 * `node:test` + `assert/strict` + jiti (NOT vitest — S11 research §5). Three layers:
 *  1. UNIT (factory directly with stub deps; fresh ConnectionState): ping field
 *     exactness + sync return + dep threading; bye ack + flag set + sync return;
 *     getCommands field mapping + description-omitted + null/empty → [] + async
 *     return + exact provider call + provider-not-captured.
 *  2. DISPATCH (registerBridgeHandler + fakeSocket + handleLine, `{ handshakeComplete:
 *     true }` for the gated happy paths; pre-handshake ⇒ -32600 regression): ping
 *     success + NOT-close; bye success + close-via-flag; getCommands success; empty-
 *     params ignored; pre-handshake gate.
 *  3. REAL integration (ONE real Unix-socket pair; hello + ping + bye + getCommands
 *     registered): hello ⇒ HelloResult; ping ⇒ pid===process.pid; getCommands ⇒
 *     mapped commands; bye ⇒ {ok:true} + client observes the server half-close.
 *
 * NOTE: `fakeSocket`/`parseResponses`/`readFirstResponse` are copied VERBATIM from
 * should-trigger-file-completion-handler.test.ts / get-suggestions-handler.test.ts /
 * apply-completion-handler.test.ts (they are LOCAL per-file helpers, NOT exported —
 * every S9–S13 suite re-declares them identically).
 */
import { test } from "node:test";
import assert from "node:assert/strict";
import { EventEmitter, once } from "node:events";
import { createServer, connect, type Socket } from "node:net";
import { randomUUID } from "node:crypto";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { AutocompleteProvider } from "@earendil-works/pi-tui";
import {
	BridgeRpcError,
	handleLine,
	onConnection,
	registerBridgeHandler,
	__resetHandlersForTest,
	type ConnectionState,
} from "../connection.ts";
import {
	makePingHandler,
	makeByeHandler,
	makeGetCommandsHandler,
	makeHelloHandler,
	BRIDGE_VERSION,
} from "../pi-editor-bridge.ts";
import { attachJsonlLineReader, serializeJsonLine } from "../jsonl-reader.ts";

const TOKEN = "deadbeefdeadbeefdeadbeefdeadbeef";

/** Fake socket for the dispatch round-trip: write capture + end() recording + close emit. */
function fakeSocket(): {
	sock: Socket;
	writes: string[];
	state: { ended: boolean };
} {
	const writes: string[] = [];
	const state = { ended: false };
	const sock = Object.assign(new EventEmitter(), {
		write(s: string) {
			writes.push(s);
			return true;
		},
		end() {
			state.ended = true;
			(this as unknown as EventEmitter).emit("close");
		},
		destroy() {
			(this as unknown as EventEmitter).emit("close");
		},
	}) as unknown as Socket;
	return { sock, writes, state };
}

function parseResponses(writes: string[]): unknown[] {
	return writes.map((w) => JSON.parse(w.trim()));
}

// Helper: resolve the first complete JSONL line the client socket receives.
function readFirstResponse(client: Socket): Promise<Record<string, unknown>> {
	return new Promise((resolve) => {
		const detach = attachJsonlLineReader(client, (line) => {
			detach();
			resolve(JSON.parse(line));
		});
	});
}

// === STUB PROVIDERS / DEPS =====================================================

/** Recorded last call shape for the getCommands handler's provider call. */
type GetSuggestionsRecordedCall = {
	lines: string[];
	cursorLine: number;
	cursorCol: number;
	signal: AbortSignal;
	force: boolean;
};

/**
 * A stub provider that RECORDS the last `getSuggestions` call (lines/cursor/opts) and
 * returns a fixed `result`. Use {@link getLastCall} to assert the handler threaded
 * `(["/"], 0, 1, {signal:[AbortSignal], force:false})` untouched.
 * applyCompletion/shouldTriggerFileCompletion are present only to satisfy the
 * AutocompleteProvider interface type (unused by getCommands).
 */
function makeRecordingProvider(result: {
	items: { value: string; label: string; description?: string }[];
	prefix: string;
} | null): {
	provider: AutocompleteProvider;
	getLastCall: () => GetSuggestionsRecordedCall | undefined;
} {
	let lastCall: GetSuggestionsRecordedCall | undefined;
	const provider: AutocompleteProvider = {
		getSuggestions: async (
			lines: string[],
			cursorLine: number,
			cursorCol: number,
			opts: { signal: AbortSignal; force?: boolean },
		) => {
			lastCall = {
				lines,
				cursorLine,
				cursorCol,
				signal: opts.signal,
				force: opts.force === true,
			};
			return result;
		},
		applyCompletion: (lines, cursorLine, cursorCol) => ({
			lines,
			cursorLine,
			cursorCol,
		}), // unused by getCommands; present for interface satisfaction
		shouldTriggerFileCompletion: () => true, // unused by getCommands; present for interface satisfaction
	};
	return { provider, getLastCall: () => lastCall };
}

/** A minimal stub provider returning a fixed slash-command-style result. */
function makeStubProvider(items: { value: string; label: string; description?: string }[]): AutocompleteProvider {
	return {
		getSuggestions: async () => ({ items, prefix: "/" }),
		applyCompletion: (lines, cursorLine, cursorCol) => ({ lines, cursorLine, cursorCol }),
		shouldTriggerFileCompletion: () => true,
	};
}

/** A recording dep-set for ping (records each getter's call). */
function makeRecordingDeps(opts: {
	pid: number;
	cwd?: string;
	fdAvailable: boolean;
	version: string;
}) {
	const calls = { getPid: 0, getCwd: 0, getFdAvailable: 0 };
	return {
		deps: {
			getPid: () => {
				calls.getPid++;
				return opts.pid;
			},
			getCwd: () => {
				calls.getCwd++;
				return opts.cwd;
			},
			getFdAvailable: () => {
				calls.getFdAvailable++;
				return opts.fdAvailable;
			},
			version: opts.version,
		},
		calls,
	};
}

// =============================================================================
// 1. UNIT — ping
// =============================================================================

test("UNIT ping: happy path → returns PingResult with exact pid/cwd/fdAvailable/serverVersion", () => {
	const handler = makePingHandler({
		getPid: () => 4242,
		getCwd: () => "/tmp/proj",
		getFdAvailable: () => true,
		version: BRIDGE_VERSION,
	});
	const got = handler({}, { handshakeComplete: true });
	assert.deepEqual(got, {
		ok: true,
		pid: 4242,
		cwd: "/tmp/proj",
		fdAvailable: true,
		serverVersion: BRIDGE_VERSION,
	});
});

test("UNIT ping: getCwd()===undefined → result.cwd===\"\" (defensive fallback, mirrors hello)", () => {
	const handler = makePingHandler({
		getPid: () => 1,
		getCwd: () => undefined,
		getFdAvailable: () => false,
		version: "0.1.0",
	});
	const got = handler({}, { handshakeComplete: true }) as { cwd: string };
	assert.equal(got.cwd, "", "cwd must fall back to empty string when undefined");
});

test("UNIT ping: sync return → result is a plain object (NOT a Promise)", () => {
	const handler = makePingHandler({
		getPid: () => 7,
		getCwd: () => "/x",
		getFdAvailable: () => true,
		version: BRIDGE_VERSION,
	});
	const r = handler({}, { handshakeComplete: true });
	assert.equal(r instanceof Promise, false, "ping handler must return sync, not a Promise");
});

test("UNIT ping: exact deps threading → getPid/getCwd/getFdAvailable each called once", () => {
	const { deps, calls } = makeRecordingDeps({
		pid: 999,
		cwd: "/home/u/proj",
		fdAvailable: true,
		version: BRIDGE_VERSION,
	});
	const handler = makePingHandler(deps);
	const got = handler({}, { handshakeComplete: true }) as {
		pid: number;
		cwd: string;
		fdAvailable: boolean;
		serverVersion: string;
	};
	assert.equal(got.pid, 999);
	assert.equal(got.cwd, "/home/u/proj");
	assert.equal(got.fdAvailable, true);
	assert.equal(got.serverVersion, BRIDGE_VERSION);
	assert.equal(calls.getPid, 1);
	assert.equal(calls.getCwd, 1);
	assert.equal(calls.getFdAvailable, 1);
});

// =============================================================================
// 1. UNIT — bye
// =============================================================================

test("UNIT bye: returns {ok:true} AND sets state.closeAfterResponse === true", () => {
	const handler = makeByeHandler();
	const state: ConnectionState = { handshakeComplete: true };
	const got = handler({}, state);
	assert.deepEqual(got, { ok: true });
	assert.equal(state.closeAfterResponse, true, "bye must set closeAfterResponse for a graceful close");
});

test("UNIT bye: sync return → result is a plain object (NOT a Promise)", () => {
	const handler = makeByeHandler();
	const r = handler({}, { handshakeComplete: true });
	assert.equal(r instanceof Promise, false, "bye handler must return sync, not a Promise");
});

// =============================================================================
// 1. UNIT — getCommands
// =============================================================================

test("UNIT getCommands: happy path → maps items to CommandInfo (name/description forwarded)", async () => {
	const { provider } = makeRecordingProvider({
		items: [
			{ value: "model", label: "model", description: "Select model" },
			{ value: "compact", label: "compact" },
		],
		prefix: "/",
	});
	const handler = makeGetCommandsHandler({ getProvider: () => provider });
	const got = await handler({}, { handshakeComplete: true });
	assert.deepEqual(got, {
		commands: [
			{ name: "model", description: "Select model" },
			{ name: "compact" }, // NO description key when item.description is absent
		],
	});
});

test("UNIT getCommands: argumentHint is ABSENT (documented limitation)", async () => {
	const { provider } = makeRecordingProvider({
		items: [{ value: "model", label: "model", description: "<p> — Select model" }],
		prefix: "/",
	});
	const handler = makeGetCommandsHandler({ getProvider: () => provider });
	const got = (await handler({}, { handshakeComplete: true })) as {
		commands: { name: string; description?: string; argumentHint?: string }[];
	};
	assert.equal(got.commands[0].argumentHint, undefined, "argumentHint must be absent");
	assert.ok(!("argumentHint" in got.commands[0]), "argumentHint key must not be present at all");
});

test("UNIT getCommands: null result → {commands:[]}", async () => {
	const { provider } = makeRecordingProvider(null);
	const handler = makeGetCommandsHandler({ getProvider: () => provider });
	const got = await handler({}, { handshakeComplete: true });
	assert.deepEqual(got, { commands: [] });
});

test("UNIT getCommands: empty items → {commands:[]}", async () => {
	const { provider } = makeRecordingProvider({ items: [], prefix: "/" });
	const handler = makeGetCommandsHandler({ getProvider: () => provider });
	const got = await handler({}, { handshakeComplete: true });
	assert.deepEqual(got, { commands: [] });
});

test("UNIT getCommands: async return → result instanceof Promise", () => {
	const { provider } = makeRecordingProvider({ items: [], prefix: "/" });
	const handler = makeGetCommandsHandler({ getProvider: () => provider });
	const r = handler({}, { handshakeComplete: true });
	assert.equal(r instanceof Promise, true, "getCommands handler must return a Promise");
});

test("UNIT getCommands: exact provider call → getSuggestions([\"/\"],0,1,{signal,force:false})", async () => {
	const { provider, getLastCall } = makeRecordingProvider({ items: [], prefix: "/" });
	const handler = makeGetCommandsHandler({ getProvider: () => provider });
	await handler({}, { handshakeComplete: true });
	const call = getLastCall();
	assert.ok(call, "provider.getSuggestions must have been called");
	assert.deepEqual(call!.lines, ["/"]);
	assert.equal(call!.cursorLine, 0);
	assert.equal(call!.cursorCol, 1);
	assert.equal(call!.force, false, "force must be false");
	assert.ok(call!.signal instanceof AbortSignal, "signal must be an AbortSignal");
	assert.equal(call!.signal.aborted, false, "the fresh AbortController must NOT be aborted (no-op)");
});

test("UNIT getCommands: provider-not-captured → throws BridgeRpcError(-32603, \"completion provider unavailable: …\")", async () => {
	const handler = makeGetCommandsHandler({
		getProvider: () => {
			throw new Error("not captured");
		},
	});
	// S15 wraps deps.getProvider() throwing into BridgeRpcError(-32603) at the handler edge
	// via toBridgeRpcError(e, "completion provider unavailable"). (The plain-Error stub stays;
	// the assertion changes — now a typed BridgeRpcError, not a raw Error to the safety net.)
	await assert.rejects(
		async () => handler({}, { handshakeComplete: true }),
		(err: unknown) => {
			assert.ok(err instanceof BridgeRpcError, "S15: must be a BridgeRpcError now");
			assert.equal((err as BridgeRpcError).code, -32603);
			assert.ok(
				(err as BridgeRpcError).message.startsWith("completion provider unavailable:"),
				`got "${(err as BridgeRpcError).message}"`,
			);
			return true;
		},
	);
});

// =============================================================================
// 2. DISPATCH — ping
// =============================================================================

test("DISPATCH ping: valid (post-handshake) → success envelope; socket NOT closed", async () => {
	registerBridgeHandler(
		"ping",
		makePingHandler({
			getPid: () => 4242,
			getCwd: () => "/tmp/proj",
			getFdAvailable: () => true,
			version: BRIDGE_VERSION,
		}),
	);
	try {
		const { sock, writes, state } = fakeSocket();
		await handleLine(
			sock,
			{ handshakeComplete: true },
			JSON.stringify({ jsonrpc: "2.0", id: "p1", method: "ping", params: {} }),
		);
		assert.deepEqual(parseResponses(writes), [
			{
				jsonrpc: "2.0",
				id: "p1",
				result: {
					ok: true,
					pid: 4242,
					cwd: "/tmp/proj",
					fdAvailable: true,
					serverVersion: BRIDGE_VERSION,
				},
			},
		]);
		assert.equal(state.ended, false, "ping must NOT close the socket");
	} finally {
		__resetHandlersForTest();
	}
});

test("DISPATCH ping: pre-handshake → -32600 \"handshake required\" (S10 gate)", async () => {
	registerBridgeHandler(
		"ping",
		makePingHandler({
			getPid: () => 1,
			getCwd: () => "/x",
			getFdAvailable: () => true,
			version: BRIDGE_VERSION,
		}),
	);
	try {
		const { sock, writes } = fakeSocket();
		await handleLine(
			sock,
			{ handshakeComplete: false },
			JSON.stringify({ jsonrpc: "2.0", id: "p1", method: "ping", params: {} }),
		);
		assert.equal(writes.length, 1, "exactly ONE response line");
		const r = parseResponses(writes)[0] as {
			id: string;
			error: { code: number; message: string };
		};
		assert.equal(r.id, "p1");
		assert.equal(r.error.code, -32600);
		assert.equal(r.error.message, "handshake required: send hello first");
	} finally {
		__resetHandlersForTest();
	}
});

test("DISPATCH ping: empty-params method ignores unknown params (no -32602)", async () => {
	registerBridgeHandler(
		"ping",
		makePingHandler({
			getPid: () => 7,
			getCwd: () => "/x",
			getFdAvailable: () => true,
			version: BRIDGE_VERSION,
		}),
	);
	try {
		const { sock, writes } = fakeSocket();
		// Send {foo:"bar"} — ping ignores params entirely (no validator); must succeed.
		await handleLine(
			sock,
			{ handshakeComplete: true },
			JSON.stringify({ jsonrpc: "2.0", id: "p1", method: "ping", params: { foo: "bar" } }),
		);
		const r = parseResponses(writes)[0] as { id: string; result?: unknown; error?: unknown };
		assert.equal(r.id, "p1");
		assert.ok(r.result, "ping must succeed (params ignored), NOT -32602");
		assert.equal(r.error, undefined);
	} finally {
		__resetHandlersForTest();
	}
});

// =============================================================================
// 2. DISPATCH — bye
// =============================================================================

test("DISPATCH bye: valid (post-handshake) → {ok:true} AND state.ended === true (closeAfterResponse)", async () => {
	registerBridgeHandler("bye", makeByeHandler());
	try {
		const { sock, writes, state } = fakeSocket();
		await handleLine(
			sock,
			{ handshakeComplete: true },
			JSON.stringify({ jsonrpc: "2.0", id: "b1", method: "bye", params: {} }),
		);
		assert.deepEqual(parseResponses(writes), [
			{ jsonrpc: "2.0", id: "b1", result: { ok: true } },
		]);
		assert.equal(state.ended, true, "bye must trigger sock.end() via closeAfterResponse");
	} finally {
		__resetHandlersForTest();
	}
});

test("DISPATCH bye: pre-handshake → -32600 (gate)", async () => {
	registerBridgeHandler("bye", makeByeHandler());
	try {
		const { sock, writes } = fakeSocket();
		await handleLine(
			sock,
			{ handshakeComplete: false },
			JSON.stringify({ jsonrpc: "2.0", id: "b1", method: "bye", params: {} }),
		);
		assert.equal(writes.length, 1, "exactly ONE response line");
		const r = parseResponses(writes)[0] as {
			id: string;
			error: { code: number; message: string };
		};
		assert.equal(r.id, "b1");
		assert.equal(r.error.code, -32600);
		assert.equal(r.error.message, "handshake required: send hello first");
	} finally {
		__resetHandlersForTest();
	}
});

test("DISPATCH bye: empty-params method ignores unknown params (no -32602)", async () => {
	registerBridgeHandler("bye", makeByeHandler());
	try {
		const { sock, writes } = fakeSocket();
		await handleLine(
			sock,
			{ handshakeComplete: true },
			JSON.stringify({ jsonrpc: "2.0", id: "b1", method: "bye", params: { foo: "bar" } }),
		);
		const r = parseResponses(writes)[0] as { id: string; result?: unknown; error?: unknown };
		assert.equal(r.id, "b1");
		assert.deepEqual(r.result, { ok: true });
		assert.equal(r.error, undefined);
	} finally {
		__resetHandlersForTest();
	}
});

// =============================================================================
// 2. DISPATCH — getCommands
// =============================================================================

test("DISPATCH getCommands: valid (post-handshake) → {commands:[…]} success envelope", async () => {
	const provider = makeStubProvider([
		{ value: "model", label: "model", description: "<p> — Select model" },
		{ value: "compact", label: "compact", description: "Manually compact the session context" },
	]);
	registerBridgeHandler("getCommands", makeGetCommandsHandler({ getProvider: () => provider }));
	try {
		const { sock, writes } = fakeSocket();
		await handleLine(
			sock,
			{ handshakeComplete: true },
			JSON.stringify({ jsonrpc: "2.0", id: "g1", method: "getCommands", params: {} }),
		);
		assert.deepEqual(parseResponses(writes), [
			{
				jsonrpc: "2.0",
				id: "g1",
				result: {
					commands: [
						{ name: "model", description: "<p> — Select model" },
						{ name: "compact", description: "Manually compact the session context" },
					],
				},
			},
		]);
	} finally {
		__resetHandlersForTest();
	}
});

test("DISPATCH getCommands: pre-handshake → -32600 (gate)", async () => {
	const provider = makeStubProvider([]);
	registerBridgeHandler("getCommands", makeGetCommandsHandler({ getProvider: () => provider }));
	try {
		const { sock, writes } = fakeSocket();
		await handleLine(
			sock,
			{ handshakeComplete: false },
			JSON.stringify({ jsonrpc: "2.0", id: "g1", method: "getCommands", params: {} }),
		);
		assert.equal(writes.length, 1, "exactly ONE response line");
		const r = parseResponses(writes)[0] as {
			id: string;
			error: { code: number; message: string };
		};
		assert.equal(r.id, "g1");
		assert.equal(r.error.code, -32600);
		assert.equal(r.error.message, "handshake required: send hello first");
	} finally {
		__resetHandlersForTest();
	}
});

test("DISPATCH getCommands: empty-params method ignores unknown params (no -32602)", async () => {
	const provider = makeStubProvider([]);
	registerBridgeHandler("getCommands", makeGetCommandsHandler({ getProvider: () => provider }));
	try {
		const { sock, writes } = fakeSocket();
		await handleLine(
			sock,
			{ handshakeComplete: true },
			JSON.stringify({ jsonrpc: "2.0", id: "g1", method: "getCommands", params: { foo: "bar" } }),
		);
		const r = parseResponses(writes)[0] as { id: string; result?: unknown; error?: unknown };
		assert.equal(r.id, "g1");
		assert.deepEqual(r.result, { commands: [] });
		assert.equal(r.error, undefined);
	} finally {
		__resetHandlersForTest();
	}
});

test("DISPATCH getCommands: provider-not-captured → -32603 (S15 wrapped: handler throws BridgeRpcError, not the safety-net else-branch)", async () => {
	registerBridgeHandler(
		"getCommands",
		makeGetCommandsHandler({
			getProvider: () => {
				throw new Error("not captured");
			},
		}),
	);
	try {
		const { sock, writes } = fakeSocket();
		await handleLine(
			sock,
			{ handshakeComplete: true },
			JSON.stringify({ jsonrpc: "2.0", id: "g1", method: "getCommands", params: {} }),
		);
		assert.equal(writes.length, 1, "exactly ONE response line");
		const r = parseResponses(writes)[0] as {
			id: string;
			error: { code: number; message: string };
		};
		assert.equal(r.id, "g1");
		assert.equal(r.error.code, -32603);
		// S15: the handler now throws BridgeRpcError(-32603, "completion provider unavailable: …")
		// itself; handleLine routes it to the same -32603 code but with the handler's clean,
		// context-prefixed message (NOT the safety-net's "internal error: …" else-branch).
		assert.ok(
			r.error.message.startsWith("completion provider unavailable:"),
			`got "${r.error.message}"`,
		);
	} finally {
		__resetHandlersForTest();
	}
});

// =============================================================================
// 3. REAL integration (ONE real Unix-socket pair; hello + ping + bye + getCommands)
// =============================================================================

test("REAL: hello → ping → getCommands → bye(client observes close) over a real Unix socket", async () => {
	registerBridgeHandler(
		"hello",
		makeHelloHandler({
			getToken: () => TOKEN,
			getCwd: () => "/tmp",
			getFdAvailable: () => true,
			version: BRIDGE_VERSION,
		}),
	);
	registerBridgeHandler(
		"ping",
		makePingHandler({
			// use the real process.pid so we assert the wiring end-to-end
			getPid: () => process.pid,
			getCwd: () => "/tmp",
			getFdAvailable: () => true,
			version: BRIDGE_VERSION,
		}),
	);
	registerBridgeHandler("bye", makeByeHandler());
	const stub = makeStubProvider([
		{ value: "model", label: "model", description: "<provider/model> — Select model (opens selector UI)" },
		{ value: "compact", label: "compact", description: "Manually compact the session context" },
	]);
	registerBridgeHandler("getCommands", makeGetCommandsHandler({ getProvider: () => stub }));

	const sockpath = join(tmpdir(), `pi-editor-pbgc-${randomUUID()}.sock`);
	const server = createServer((c) => onConnection(c));
	server.listen(sockpath);
	await once(server, "listening");
	let client: Socket | undefined;
	try {
		client = connect(sockpath);
		await once(client, "connect");

		// (1) hello (correct token) ⇒ HelloResult (gate opens)
		const rH = readFirstResponse(client);
		client.write(
			serializeJsonLine({ jsonrpc: "2.0", id: "h1", method: "hello", params: { token: TOKEN } }),
		);
		const hello = (await rH) as {
			id?: string;
			result?: { ok: boolean; serverVersion: string };
		};
		assert.equal(hello.result?.ok, true);
		assert.equal(hello.result?.serverVersion, BRIDGE_VERSION);

		// (2) ping ⇒ pid === process.pid, serverVersion === BRIDGE_VERSION
		const rP = readFirstResponse(client);
		client.write(serializeJsonLine({ jsonrpc: "2.0", id: "p1", method: "ping", params: {} }));
		const ping = (await rP) as {
			id: string;
			result: { ok: boolean; pid: number; cwd: string; fdAvailable: boolean; serverVersion: string };
		};
		assert.equal(ping.id, "p1");
		assert.equal(ping.result.ok, true);
		assert.equal(ping.result.pid, process.pid, "ping.pid must equal process.pid");
		assert.equal(ping.result.serverVersion, BRIDGE_VERSION);
		assert.equal(ping.result.cwd, "/tmp");
		assert.equal(ping.result.fdAvailable, true);

		// (3) getCommands ⇒ mapped CommandInfo[]
		const rG = readFirstResponse(client);
		client.write(serializeJsonLine({ jsonrpc: "2.0", id: "g1", method: "getCommands", params: {} }));
		const gc = (await rG) as {
			id: string;
			result: { commands: { name: string; description?: string }[] };
		};
		assert.equal(gc.id, "g1");
		assert.deepEqual(gc.result.commands, [
			{ name: "model", description: "<provider/model> — Select model (opens selector UI)" },
			{ name: "compact", description: "Manually compact the session context" },
		]);

		// (4) bye ⇒ {ok:true}, then the client observes the server's half-close
		const rB = readFirstResponse(client);
		client.write(serializeJsonLine({ jsonrpc: "2.0", id: "b1", method: "bye", params: {} }));
		const bye = (await rB) as { id: string; result: { ok: boolean } };
		assert.equal(bye.id, "b1");
		assert.deepEqual(bye.result, { ok: true });

		// The server half-closes after the bye ack (approach (a)). Observe 'close' or
		// 'end' within a 2s timeout — otherwise fail.
		const closed = await Promise.race([
			once(client, "close").then(() => true),
			once(client, "end").then(() => true),
			new Promise<boolean>((resolve) => setTimeout(() => resolve(false), 2000)),
		]);
		assert.equal(closed, true, "client must observe the server half-close after bye");
	} finally {
		__resetHandlersForTest();
		client?.destroy();
		server.close();
	}
});

// =============================================================================
// 4. TOKEN-NEVER-LEAKED sweep (PRD §12)
// =============================================================================

test("SECURITY: the TOKEN value never appears in any ping/bye/getCommands response (PRD §12)", async () => {
	registerBridgeHandler(
		"ping",
		makePingHandler({
			getPid: () => 1,
			getCwd: () => "/tmp",
			getFdAvailable: () => true,
			version: BRIDGE_VERSION,
		}),
	);
	registerBridgeHandler("bye", makeByeHandler());
	const provider = makeStubProvider([{ value: "model", label: "model", description: "Select model" }]);
	registerBridgeHandler("getCommands", makeGetCommandsHandler({ getProvider: () => provider }));
	try {
		const cases = [
			{ id: "p1", method: "ping", params: {} },
			{ id: "b1", method: "bye", params: {} },
			{ id: "g1", method: "getCommands", params: {} },
		];
		for (const c of cases) {
			const { sock, writes } = fakeSocket();
			await handleLine(
				sock,
				{ handshakeComplete: true },
				JSON.stringify({ jsonrpc: "2.0", id: c.id, method: c.method, params: c.params }),
			);
			for (const w of writes) {
				assert.ok(
					!w.includes(TOKEN),
					`token must not leak into a ${c.method} response: ${w}`,
				);
			}
		}
	} finally {
		__resetHandlersForTest();
	}
});
