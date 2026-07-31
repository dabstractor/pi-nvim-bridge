/**
 * hello-handler.test.ts — P1.M2.T5.S9 `hello` handshake (unit + dispatch + integration).
 *
 * `node:test` + `assert/strict` + jiti (NOT vitest — research §7). Three layers:
 *  1. UNIT: `makeHelloHandler` directly with stubbed deps + a fresh ConnectionState —
 *     every branch (good/bad/missing/undefined-token, cwd fallback, client fields ignored).
 *  2. DISPATCH round-trip: `handleLine` + a fake socket with `hello` registered —
 *     success ⇒ HelloResult envelope + handshakeComplete; bad token ⇒ -32600 + sock.end().
 *  3. REAL integration: ONE real Unix-socket pair (createServer + connect) — valid hello
 *     ⇒ HelloResult; bad hello (separate connection) ⇒ -32600 then the server closes
 *     (client observes 'close'/'end').
 */
import { test } from "node:test";
import assert from "node:assert/strict";
import { EventEmitter, once } from "node:events";
import { createServer, connect, type Socket } from "node:net";
import { randomUUID } from "node:crypto";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
	BridgeRpcError,
	handleLine,
	registerBridgeHandler,
	__resetHandlersForTest,
	type ConnectionState,
} from "../connection.ts";
import {
	makeHelloHandler,
	BRIDGE_VERSION,
} from "../pi-nvim-bridge.ts";
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

// === 1. UNIT (makeHelloHandler directly — no module state) =====================

test("makeHelloHandler: good token → returns HelloResult + flips handshakeComplete", () => {
	const state: ConnectionState = { handshakeComplete: false };
	const handler = makeHelloHandler({
		getToken: () => TOKEN,
		getCwd: () => "/tmp/proj",
		getFdAvailable: () => true,
		getShellInfo: () => undefined,
		version: BRIDGE_VERSION,
	});
	const result = handler({ token: TOKEN }, state);
	assert.deepEqual(result, {
		ok: true,
		serverVersion: BRIDGE_VERSION,
		cwd: "/tmp/proj",
		fdAvailable: true,
	});
	assert.equal(state.handshakeComplete, true, "must flip handshakeComplete to true");
});

test("makeHelloHandler: client/clientVersion params are ignored (accepted)", () => {
	const state: ConnectionState = { handshakeComplete: false };
	const handler = makeHelloHandler({
		getToken: () => TOKEN,
		getCwd: () => "/tmp",
		getFdAvailable: () => false,
		getShellInfo: () => undefined,
		version: BRIDGE_VERSION,
	});
	// Both extra fields present — must still succeed and be ignored.
	const result = handler(
		{ token: TOKEN, client: "nvim", clientVersion: "0.10.0" },
		state,
	) as HelloResultShape;
	assert.equal(result.ok, true);
	assert.equal(state.handshakeComplete, true);
});

test("makeHelloHandler: bad token → throws BridgeRpcError(-32600, fatal:true)", () => {
	const state: ConnectionState = { handshakeComplete: false };
	const handler = makeHelloHandler({
		getToken: () => TOKEN,
		getCwd: () => "/tmp",
		getFdAvailable: () => true,
		getShellInfo: () => undefined,
		version: BRIDGE_VERSION,
	});
	assert.throws(
		() => handler({ token: "wrong" }, state),
		(err) => {
			assert.ok(err instanceof BridgeRpcError, "must be a BridgeRpcError");
			assert.equal(err.code, -32600);
			assert.equal(err.message, "bad token");
			assert.equal(err.fatal, true);
			return true;
		},
	);
	assert.equal(state.handshakeComplete, false, "must NOT flip handshakeComplete on failure");
});

test("makeHelloHandler: missing token param → bad token", () => {
	const state: ConnectionState = { handshakeComplete: false };
	const handler = makeHelloHandler({
		getToken: () => TOKEN,
		getCwd: () => "/tmp",
		getFdAvailable: () => true,
		getShellInfo: () => undefined,
		version: BRIDGE_VERSION,
	});
	assert.throws(
		() => handler({}, state),
		(err) => err instanceof BridgeRpcError && err.code === -32600 && err.fatal === true,
	);
});

test("makeHelloHandler: wrong-type token (number) → bad token", () => {
	const state: ConnectionState = { handshakeComplete: false };
	const handler = makeHelloHandler({
		getToken: () => TOKEN,
		getCwd: () => "/tmp",
		getFdAvailable: () => true,
		getShellInfo: () => undefined,
		version: BRIDGE_VERSION,
	});
	// The wire param type is `unknown`; a numeric token is malformed on the wire.
	assert.throws(
		() => handler({ token: 12345 }, state),
		(err) => err instanceof BridgeRpcError && err.code === -32600,
	);
});

test("makeHelloHandler: null params → bad token", () => {
	const state: ConnectionState = { handshakeComplete: false };
	const handler = makeHelloHandler({
		getToken: () => TOKEN,
		getCwd: () => "/tmp",
		getFdAvailable: () => true,
		getShellInfo: () => undefined,
		version: BRIDGE_VERSION,
	});
	assert.throws(
		() => handler(null, state),
		(err) => err instanceof BridgeRpcError && err.code === -32600,
	);
});

test("makeHelloHandler: getToken()===undefined (stopped bridge) → bad token", () => {
	const state: ConnectionState = { handshakeComplete: false };
	const handler = makeHelloHandler({
		getToken: () => undefined,
		getCwd: () => "/tmp",
		getFdAvailable: () => true,
		getShellInfo: () => undefined,
		version: BRIDGE_VERSION,
	});
	// Even a client that "knows" the (now-cleared) token must be rejected.
	assert.throws(
		() => handler({ token: TOKEN }, state),
		(err) => err instanceof BridgeRpcError && err.code === -32600 && err.fatal === true,
	);
	assert.equal(state.handshakeComplete, false);
});

test("makeHelloHandler: getCwd()===undefined → result.cwd==='' (defensive fallback)", () => {
	const state: ConnectionState = { handshakeComplete: false };
	const handler = makeHelloHandler({
		getToken: () => TOKEN,
		getCwd: () => undefined,
		getFdAvailable: () => true,
		getShellInfo: () => undefined,
		version: BRIDGE_VERSION,
	});
	const result = handler({ token: TOKEN }, state) as HelloResultShape;
	assert.equal(result.cwd, "", "missing cwd must serialize as empty string");
	assert.equal(result.ok, true);
});

test("makeHelloHandler: getShellInfo stub → result carries shell/shellSource/shellPath", () => {
	const state: ConnectionState = { handshakeComplete: false };
	const handler = makeHelloHandler({
		getToken: () => TOKEN,
		getCwd: () => "/tmp",
		getFdAvailable: () => true,
		getShellInfo: () => ({ shell: "/bin/zsh", shellSource: "pi", shellPath: "/bin/zsh" }),
		version: BRIDGE_VERSION,
	});
	const result = handler({ token: TOKEN }, state) as HelloResultShape;
	assert.equal(result.shell, "/bin/zsh");
	assert.equal(result.shellSource, "pi");
	assert.equal(result.shellPath, "/bin/zsh");
	assert.equal(state.handshakeComplete, true);
});

test("makeHelloHandler: getShellInfo()=>undefined → shell fields ABSENT (advisory, §17.10)", () => {
	const state: ConnectionState = { handshakeComplete: false };
	const handler = makeHelloHandler({
		getToken: () => TOKEN,
		getCwd: () => "/tmp",
		getFdAvailable: () => true,
		getShellInfo: () => undefined,
		version: BRIDGE_VERSION,
	});
	const result = handler({ token: TOKEN }, state) as Record<string, unknown>;
	assert.equal("shell" in result, false, "shell key must be ABSENT when getShellInfo returns undefined");
	assert.equal("shellSource" in result, false);
	assert.equal("shellPath" in result, false);
	assert.equal(result.ok, true);
});

test("makeHelloHandler: token value NEVER appears in the thrown message (PRD §12)", () => {
	const handler = makeHelloHandler({
		getToken: () => TOKEN,
		getCwd: () => "/tmp",
		getFdAvailable: () => true,
		getShellInfo: () => undefined,
		version: BRIDGE_VERSION,
	});
	try {
		handler({ token: "someWrongValue" }, { handshakeComplete: false });
		assert.fail("expected throw");
	} catch (err) {
		assert.ok(err instanceof Error);
		assert.equal(err.message, "bad token");
		assert.ok(
			!err.message.includes(TOKEN) && !err.message.includes("someWrongValue"),
			"token values must never leak into the message",
		);
	}
});

// === 2. DISPATCH round-trip (handleLine + fakeSocket, hello registered) =========

test("dispatch: valid hello JSONL → success envelope + handshakeComplete", async () => {
	registerBridgeHandler(
		"hello",
		makeHelloHandler({
			getToken: () => TOKEN,
			getCwd: () => "/tmp/proj",
			getFdAvailable: () => true,
			getShellInfo: () => undefined,
			version: BRIDGE_VERSION,
		}),
	);
	try {
		const { sock, writes, state } = fakeSocket();
		const connState: ConnectionState = { handshakeComplete: false };
		await handleLine(
			sock,
			connState,
			JSON.stringify({ jsonrpc: "2.0", id: "h1", method: "hello", params: { token: TOKEN } }),
		);
		assert.deepEqual(parseResponses(writes), [
			{
				jsonrpc: "2.0",
				id: "h1",
				result: {
					ok: true,
					serverVersion: BRIDGE_VERSION,
					cwd: "/tmp/proj",
					fdAvailable: true,
				},
			},
		]);
		assert.equal(connState.handshakeComplete, true);
		assert.equal(state.ended, false, "success path must NOT close the socket");
	} finally {
		__resetHandlersForTest();
	}
});

test("dispatch: bad-token hello → -32600 envelope + sock.end()", async () => {
	registerBridgeHandler(
		"hello",
		makeHelloHandler({
			getToken: () => TOKEN,
			getCwd: () => "/tmp",
			getFdAvailable: () => true,
			getShellInfo: () => undefined,
			version: BRIDGE_VERSION,
		}),
	);
	try {
		const { sock, writes, state } = fakeSocket();
		const connState: ConnectionState = { handshakeComplete: false };
		await handleLine(
			sock,
			connState,
			JSON.stringify({ jsonrpc: "2.0", id: "h1", method: "hello", params: { token: "x" } }),
		);
		const r = parseResponses(writes)[0] as {
			id: string;
			error: { code: number; message: string };
		};
		assert.equal(r.id, "h1");
		assert.equal(r.error.code, -32600);
		assert.equal(r.error.message, "bad token");
		assert.equal(state.ended, true, "fatal bad-token must close the socket");
		assert.equal(connState.handshakeComplete, false);
		assert.equal(writes.length, 1, "exactly ONE response line before close");
	} finally {
		__resetHandlersForTest();
	}
});

// === 3. REAL integration (ONE real Unix socket pair) ===========================

test("REAL: hello success + bad-token→disconnect over a real Unix socket", async () => {
	const sockpath = join(tmpdir(), `pi-bridge-hello-${randomUUID()}.sock`);
	const server = createServer((c) => onConnectionReal(c));
	// Register a handler with a FIXED token + stubbed deps (no module state needed).
	registerBridgeHandler(
		"hello",
		makeHelloHandler({
			getToken: () => TOKEN,
			getCwd: () => "/tmp",
			getFdAvailable: () => true,
			getShellInfo: () => undefined,
			version: BRIDGE_VERSION,
		}),
	);
	server.listen(sockpath);
	await once(server, "listening");
	try {
		// (a) Client A: valid hello ⇒ HelloResult.
		const clientA = connect(sockpath);
		await once(clientA, "connect");
		const aResponse = readFirstResponse(clientA);
		clientA.write(
			serializeJsonLine({ jsonrpc: "2.0", id: "h1", method: "hello", params: { token: TOKEN } }),
		);
		const rA = (await aResponse) as HelloResultShape;
		assert.equal(rA.id ?? "h1", "h1");
		assert.equal(rA.jsonrpc ?? "2.0", "2.0");
		assert.deepEqual(rA.result, {
			ok: true,
			serverVersion: BRIDGE_VERSION,
			cwd: "/tmp",
			fdAvailable: true,
		});
		clientA.destroy();

		// (b) Client B (separate connection): bad hello ⇒ -32600 then the server closes.
		const clientB = connect(sockpath);
		await once(clientB, "connect");
		const bFirstLine = readFirstResponse(clientB);
		clientB.write(
			serializeJsonLine({
				jsonrpc: "2.0",
				id: "h2",
				method: "hello",
				params: { token: "nope" },
			}),
		);
		const rB = (await bFirstLine) as {
			jsonrpc: string;
			id: string;
			error: { code: number; message: string };
		};
		assert.equal(rB.jsonrpc, "2.0");
		assert.equal(rB.id, "h2");
		assert.equal(rB.error.code, -32600);
		assert.equal(rB.error.message, "bad token");

		// The server must close this connection (client observes close/end). Race both
		// with a short timeout so a failure is loud rather than hanging the suite.
		await Promise.race([
			once(clientB, "close"),
			once(clientB, "end"),
			new Promise((_, reject) =>
				setTimeout(() => reject(new Error("client B never got EOF after bad token")), 2000),
			),
		]);
	} finally {
		__resetHandlersForTest();
		server.close();
	}
});

// Helper: resolve the first complete JSONL line the client socket receives.
function readFirstResponse(client: Socket): Promise<Record<string, unknown>> {
	return new Promise((resolve) => {
		const detach = attachJsonlLineReader(client, (line) => {
			detach();
			resolve(JSON.parse(line));
		});
	});
}

// Helper used by the REAL test: a minimal onConnection that wires handleLine. Re-importing
// the real onConnection would also work, but inlining keeps the integration test explicit.
import { onConnection as onConnectionReal } from "../connection.ts";

// Minimal structural type for asserting the success-result shape without importing it.
type HelloResultShape = {
	jsonrpc?: string;
	id?: string;
	result?: { ok: true; serverVersion: string; cwd: string; fdAvailable: boolean };
	ok?: true;
	serverVersion?: string;
	cwd?: string;
	fdAvailable?: boolean;
	shell?: string; // §17.10 (S3) — advisory shell mirror
	shellSource?: string; // §17.10 (S3)
	shellPath?: string; // §17.10 (S3)
};
