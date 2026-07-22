/**
 * handshake-gate.test.ts — P1.M2.T5.S10 handshake gate (dispatch + integration).
 *
 * The S10 gate (one guard in `handleLine`, placed before the notification/request
 * split) rejects every method except `"hello"` until `ConnectionState.handshakeComplete`
 * is true (flipped by S9's hello handler on a correct token). PRD §12: "The bridge
 * must reject any method before a valid `hello`."
 *
 * `node:test` + `assert/strict` + jiti (NOT vitest — research §7). Two layers:
 *  1. DISPATCH (fakeSocket + handleLine directly): REQUEST / NOTIFICATION / hello-exempt
 *     / post-handshake no-op / gate-before-registry, plus a token-never-leaked sweep.
 *  2. REAL integration (ONE real Unix-socket pair): pre-handshake ping ⇒ -32600, then
 *     hello ⇒ HelloResult, then ping again ⇒ now dispatches (still unregistered ⇒ -32601).
 *
 * NOTE: `fakeSocket`/`parseResponses`/`readFirstResponse` are copied verbatim from
 * connection.test.ts (they are LOCAL helpers, not exported — S9's hello-handler.test.ts
 * did the same).
 */
import { test } from "node:test";
import assert from "node:assert/strict";
import { EventEmitter, once } from "node:events";
import { createServer, connect, type Socket } from "node:net";
import { randomUUID } from "node:crypto";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
	handleLine,
	onConnection,
	registerBridgeHandler,
	__resetHandlersForTest,
	type ConnectionState,
} from "../connection.ts";
import { makeHelloHandler, BRIDGE_VERSION } from "../pi-nvim-bridge.ts";
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

// === 1. DISPATCH (fakeSocket + handleLine) =====================================

test("gate: pre-handshake REQUEST (non-hello) ⇒ one -32600, handler NOT called, socket stays open", async () => {
	let called = false;
	registerBridgeHandler("ping", () => {
		called = true;
		return { ok: true };
	});
	try {
		const { sock, writes, state } = fakeSocket();
		await handleLine(sock, { handshakeComplete: false }, JSON.stringify({
			jsonrpc: "2.0", id: "p1", method: "ping", params: {},
		}));
		assert.deepEqual(parseResponses(writes), [{
			jsonrpc: "2.0",
			id: "p1",
			error: { code: -32600, message: "handshake required: send hello first" },
		}]);
		assert.equal(called, false, "handler must NOT run pre-handshake");
		assert.equal(state.ended, false, "gate is non-fatal — socket stays open");
	} finally {
		__resetHandlersForTest();
	}
});

test("gate: pre-handshake NOTIFICATION ⇒ no response, handler NOT called", async () => {
	let called = false;
	registerBridgeHandler("something", () => {
		called = true;
	});
	try {
		const { sock, writes } = fakeSocket();
		await handleLine(sock, { handshakeComplete: false }, JSON.stringify({
			jsonrpc: "2.0", method: "something", params: {},
		}));
		assert.equal(writes.length, 0, "notifications get no response (JSON-RPC 2.0)");
		assert.equal(called, false, "notification handler must NOT run pre-handshake");
	} finally {
		__resetHandlersForTest();
	}
});

test("gate: `hello` is EXEMPT pre-handshake (routes to handler, flips the flag)", async () => {
	registerBridgeHandler(
		"hello",
		makeHelloHandler({
			getToken: () => TOKEN,
			getCwd: () => "/tmp",
			getFdAvailable: () => true,
			version: BRIDGE_VERSION,
		}),
	);
	try {
		const { sock, writes } = fakeSocket();
		const connState: ConnectionState = { handshakeComplete: false };
		await handleLine(
			sock,
			connState,
			JSON.stringify({ jsonrpc: "2.0", id: "h1", method: "hello", params: { token: TOKEN } }),
		);
		const r = parseResponses(writes)[0] as {
			id: string;
			result: { ok: boolean; serverVersion: string; cwd: string; fdAvailable: boolean };
		};
		assert.equal(r.id, "h1");
		assert.deepEqual(r.result, {
			ok: true, serverVersion: BRIDGE_VERSION, cwd: "/tmp", fdAvailable: true,
		});
		assert.equal(connState.handshakeComplete, true, "hello must still flip the flag (gate exempts it)");
	} finally {
		__resetHandlersForTest();
	}
});

test("gate: POST-handshake no-op (registered method dispatches normally)", async () => {
	registerBridgeHandler("ping", () => ({ ok: true }));
	try {
		const { sock, writes } = fakeSocket();
		await handleLine(sock, { handshakeComplete: true }, JSON.stringify({
			jsonrpc: "2.0", id: "p2", method: "ping",
		}));
		assert.deepEqual(parseResponses(writes), [{ jsonrpc: "2.0", id: "p2", result: { ok: true } }]);
	} finally {
		__resetHandlersForTest();
	}
});

test("gate: fires BEFORE registry lookup — unregistered method pre-handshake ⇒ -32600 (NOT -32601)", async () => {
	const { sock, writes } = fakeSocket();
	await handleLine(sock, { handshakeComplete: false }, JSON.stringify({
		jsonrpc: "2.0", id: "x1", method: "nope",
	}));
	const r = parseResponses(writes)[0] as { id: string; error: { code: number; message: string } };
	assert.equal(r.id, "x1");
	assert.equal(r.error.code, -32600, "must be handshake (-32600), not method-not-found (-32601)");
	assert.equal(r.error.message, "handshake required: send hello first");
});

// === 2. REAL integration (ONE real Unix-socket pair) ===========================

test("REAL: pre-handshake ping ⇒ -32600, then hello ⇒ HelloResult, then ping ⇒ -32601 (dispatch)", async () => {
	registerBridgeHandler(
		"hello",
		makeHelloHandler({
			getToken: () => TOKEN,
			getCwd: () => "/tmp",
			getFdAvailable: () => true,
			version: BRIDGE_VERSION,
		}),
	);
	const sockpath = join(tmpdir(), `pi-bridge-gate-${randomUUID()}.sock`);
	const server = createServer((c) => onConnection(c));
	server.listen(sockpath);
	await once(server, "listening");
	try {
		const client = connect(sockpath);
		await once(client, "connect");

		// (1) ping BEFORE hello ⇒ -32600 (gate closed)
		const preHello = readFirstResponse(client);
		client.write(serializeJsonLine({ jsonrpc: "2.0", id: "p0", method: "ping" }));
		const r0 = (await preHello) as { id: string; error: { code: number; message: string } };
		assert.equal(r0.id, "p0");
		assert.equal(r0.error.code, -32600);
		assert.equal(r0.error.message, "handshake required: send hello first");

		// (2) hello (correct token) ⇒ HelloResult (gate opens)
		const helloResp = readFirstResponse(client);
		client.write(serializeJsonLine({ jsonrpc: "2.0", id: "h1", method: "hello", params: { token: TOKEN } }));
		const rH = (await helloResp) as {
			id: string;
			result: { ok: boolean; serverVersion: string; cwd: string; fdAvailable: boolean };
		};
		assert.equal(rH.id, "h1");
		assert.deepEqual(rH.result, {
			ok: true, serverVersion: BRIDGE_VERSION, cwd: "/tmp", fdAvailable: true,
		});

		// (3) ping AFTER hello ⇒ now dispatches (still unregistered ⇒ -32601)
		const postHello = readFirstResponse(client);
		client.write(serializeJsonLine({ jsonrpc: "2.0", id: "p1", method: "ping" }));
		const r1 = (await postHello) as { id: string; error: { code: number } };
		assert.equal(r1.id, "p1");
		assert.equal(r1.error.code, -32601);

		client.destroy();
	} finally {
		__resetHandlersForTest();
		server.close();
	}
});

// === 3. TOKEN-NEVER-LEAKED sweep (PRD §12) =====================================

test("gate: the TOKEN value never appears in any written response (PRD §12)", async () => {
	// Run the dispatch scenarios that produce writes and assert none contain the token.
	// The gate message is the fixed literal "handshake required: send hello first"; the
	// token is never read by the gate. Belt-and-suspenders: assert structurally.
	registerBridgeHandler("ping", () => ({ ok: true }));
	try {
		const collected: string[] = [];

		const s1 = fakeSocket();
		await handleLine(s1.sock, { handshakeComplete: false }, JSON.stringify({
			jsonrpc: "2.0", id: "a", method: "ping",
		}));
		collected.push(...s1.writes);

		const s2 = fakeSocket();
		await handleLine(s2.sock, { handshakeComplete: false }, JSON.stringify({
			jsonrpc: "2.0", id: "b", method: "nope",
		}));
		collected.push(...s2.writes);

		for (const w of collected) {
			assert.ok(!w.includes(TOKEN), `token must not leak into response: ${w}`);
		}
	} finally {
		__resetHandlersForTest();
	}
});
