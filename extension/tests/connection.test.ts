import { test } from "node:test";
import assert from "node:assert/strict";
import { EventEmitter } from "node:events";
import { once } from "node:events";
import { createServer, connect, type Socket } from "node:net";
import { randomUUID } from "node:crypto";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
	onConnection,
	handleLine,
	sendResponse,
	sendError,
	sendNotification,
	registerBridgeHandler,
	BridgeRpcError,
	__resetHandlersForTest,
} from "../connection.ts";
import { attachJsonlLineReader, serializeJsonLine } from "../jsonl-reader.ts";

// A fake socket: EventEmitter (for .on/.emit/.listenerCount) + a write() that captures
// every serialized line. .destroy()/.end() emit 'close' (the real net.Socket does too).
// `state` records whether end() was called so the S9 fatal-close path is assertable.
function fakeSocket(): { sock: Socket; writes: string[]; state: { ended: boolean } } {
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

// (TESTS 1–3: response-writer envelopes) -----------------------------------------
test("sendResponse: writes a success envelope, LF-terminated", () => {
	const { sock, writes } = fakeSocket();
	sendResponse(sock, "h1", { ok: true });
	assert.equal(writes.length, 1);
	assert.ok(writes[0].endsWith("\n"), "must be LF-terminated");
	assert.deepEqual(parseResponses(writes), [{ jsonrpc: "2.0", id: "h1", result: { ok: true } }]);
});

test("sendError: writes an error envelope with code+message", () => {
	const { sock, writes } = fakeSocket();
	sendError(sock, "r2", -32601, "method not found");
	assert.deepEqual(parseResponses(writes), [
		{ jsonrpc: "2.0", id: "r2", error: { code: -32601, message: "method not found" } },
	]);
});

test("sendNotification: writes a notification with NO id", () => {
	const { sock, writes } = fakeSocket();
	sendNotification(sock, "commandsChanged", {});
	const parsed = parseResponses(writes)[0] as Record<string, unknown>;
	assert.equal(parsed.jsonrpc, "2.0");
	assert.equal(parsed.method, "commandsChanged");
	assert.ok(!("id" in parsed), "notification must have no id");
});

// (TESTS 4–7: dispatch routing) --------------------------------------------------
test("handleLine: registered handler's return → success response", async () => {
	registerBridgeHandler("echo", (p) => p);
	try {
		const { sock, writes } = fakeSocket();
		await handleLine(sock, { handshakeComplete: true }, JSON.stringify({
			jsonrpc: "2.0", id: "e1", method: "echo", params: { x: 1 },
		}));
		assert.deepEqual(parseResponses(writes), [{ jsonrpc: "2.0", id: "e1", result: { x: 1 } }]);
	} finally {
		__resetHandlersForTest();
	}
});

test("handleLine: unregistered REQUEST → -32601 method not found", async () => {
	const { sock, writes } = fakeSocket();
	await handleLine(sock, { handshakeComplete: true }, JSON.stringify({
		jsonrpc: "2.0", id: "m1", method: "nope",
	}));
	const r = parseResponses(writes)[0] as { id: string; error: { code: number } };
	assert.equal(r.id, "m1");
	assert.equal(r.error.code, -32601);
});

test("handleLine: unregistered NOTIFICATION → no response", async () => {
	const { sock, writes } = fakeSocket();
	await handleLine(sock, { handshakeComplete: true }, JSON.stringify({
		jsonrpc: "2.0", method: "nope", params: {},
	}));
	assert.equal(writes.length, 0, "notifications expect no reply");
});

test("handleLine: registered notification handler is called, no response", async () => {
	let called = false;
	registerBridgeHandler("changed", () => {
		called = true;
	});
	try {
		const { sock, writes } = fakeSocket();
		await handleLine(sock, { handshakeComplete: true }, JSON.stringify({
			jsonrpc: "2.0", method: "changed",
		}));
		assert.equal(called, true);
		assert.equal(writes.length, 0);
	} finally {
		__resetHandlersForTest();
	}
});

// (TESTS 8–10: robustness — never crash, never hang) ----------------------------
test("handleLine: malformed JSON → -32700 parse error, no throw", async () => {
	const { sock, writes } = fakeSocket();
	await assert.doesNotReject(async () => {
		await handleLine(sock, { handshakeComplete: true }, "this is not json");
	});
	const r = parseResponses(writes)[0] as { id: unknown; error: { code: number } };
	assert.equal(r.id, null, "parse error response id is null");
	assert.equal(r.error.code, -32700);
});

test("handleLine: registered handler THROWS → -32603, no throw (S8 safety net)", async () => {
	registerBridgeHandler("boom", () => {
		throw new Error("kaboom");
	});
	try {
		const { sock, writes } = fakeSocket();
		await assert.doesNotReject(async () => {
			await handleLine(sock, { handshakeComplete: true }, JSON.stringify({
				jsonrpc: "2.0", id: "b1", method: "boom",
			}));
		});
		const r = parseResponses(writes)[0] as { id: string; error: { code: number } };
		assert.equal(r.id, "b1");
		assert.equal(r.error.code, -32603);
	} finally {
		__resetHandlersForTest();
	}
});

// (S9: BridgeRpcError mapping — typed errors → their code; fatal → graceful close) ---
test("handleLine: handler throws non-fatal BridgeRpcError(code,msg) → that code, socket stays open", async () => {
	registerBridgeHandler("typed", () => {
		throw new BridgeRpcError(-32601, "nope");
	});
	try {
		const { sock, writes, state } = fakeSocket();
		await assert.doesNotReject(async () => {
			await handleLine(sock, { handshakeComplete: true }, JSON.stringify({
				jsonrpc: "2.0", id: "t1", method: "typed",
			}));
		});
		const r = parseResponses(writes)[0] as { id: string; error: { code: number; message: string } };
		assert.equal(r.id, "t1");
		assert.equal(r.error.code, -32601);
		assert.equal(r.error.message, "nope");
		assert.equal(state.ended, false, "non-fatal BridgeRpcError must NOT close the socket");
	} finally {
		__resetHandlersForTest();
	}
});

test("handleLine: handler throws fatal BridgeRpcError(-32600,...,{fatal:true}) → that code AND sock.end()", async () => {
	registerBridgeHandler("die", () => {
		throw new BridgeRpcError(-32600, "bad token", { fatal: true });
	});
	try {
		const { sock, writes, state } = fakeSocket();
		await assert.doesNotReject(async () => {
			await handleLine(sock, { handshakeComplete: true }, JSON.stringify({
				jsonrpc: "2.0", id: "d1", method: "die",
			}));
		});
		const r = parseResponses(writes)[0] as { id: string; error: { code: number; message: string } };
		assert.equal(r.id, "d1");
		assert.equal(r.error.code, -32600);
		assert.equal(r.error.message, "bad token");
		assert.equal(state.ended, true, "fatal BridgeRpcError must close the socket");
	} finally {
		__resetHandlersForTest();
	}
});

test("handleLine: REGRESSION — plain Error throw still maps to -32603, socket open", async () => {
	// Re-asserts the S8 safety net under the S9 `instanceof BridgeRpcError` branch: a
	// plain Error falls through to the else → -32603, and never closes.
	registerBridgeHandler("plain", () => {
		throw new Error("untyped");
	});
	try {
		const { sock, writes, state } = fakeSocket();
		await assert.doesNotReject(async () => {
			await handleLine(sock, { handshakeComplete: true }, JSON.stringify({
				jsonrpc: "2.0", id: "p1", method: "plain",
			}));
		});
		const r = parseResponses(writes)[0] as { id: string; error: { code: number } };
		assert.equal(r.error.code, -32603);
		assert.equal(state.ended, false);
	} finally {
		__resetHandlersForTest();
	}
});

test("handleLine: invalid envelopes (non-object, no method, bad id) → -32600, no throw", async () => {
	const cases = ["42", '"str"', "{}", '{"jsonrpc":"2.0"}', '{"jsonrpc":"2.0","method":"x","id":123}'];
	for (const line of cases) {
		const { sock, writes } = fakeSocket();
		await assert.doesNotReject(async () => {
			await handleLine(sock, { handshakeComplete: true }, line);
		});
		const r = parseResponses(writes)[0] as { error: { code: number } };
		assert.equal(r.error.code, -32600, `expected -32600 for input: ${line}`);
	}
});

// (TESTS 11–12: onConnection socket lifecycle) -----------------------------------
test("onConnection: socket 'error' detaches the reader and does not throw", () => {
	const { sock } = fakeSocket();
	onConnection(sock); // wires reader + error/close handlers
	assert.ok(sock.listenerCount("data") > 0, "reader attached a data listener");
	assert.doesNotThrow(() => sock.emit("error", new Error("ECONNRESET")));
	assert.equal(sock.listenerCount("data"), 0, "reader detached after error");
});

test("onConnection: socket 'close' detaches the reader (no leak)", () => {
	const { sock } = fakeSocket();
	onConnection(sock);
	assert.ok(sock.listenerCount("data") > 0);
	sock.emit("close");
	assert.equal(sock.listenerCount("data"), 0, "close detaches the reader");
});

// (TEST 13: REAL integration — a real Unix socket pair end-to-end) ----------------
test("REAL: end-to-end JSONL round-trip over a Unix socket (method-not-found then success)", async () => {
	const sockpath = join(tmpdir(), `pi-editor-conn-test-${randomUUID()}.sock`);
	const server = createServer((c) => onConnection(c));
	server.listen(sockpath);
	await once(server, "listening");
	try {
		const client = connect(sockpath);
		await once(client, "connect");

		// collect client-side responses (registry is EMPTY → expect -32601)
		const firstResponse = readFirstResponse(client);
		client.write(serializeJsonLine({ jsonrpc: "2.0", id: "r1", method: "ping" }));
		const r1 = await firstResponse;
		assert.equal(r1.id, "r1");
		assert.equal((r1 as { error: { code: number } }).error.code, -32601);

		// register a handler; expect success
		registerBridgeHandler("ping", () => ({ ok: true }));
		const secondResponse = readFirstResponse(client);
		client.write(serializeJsonLine({ jsonrpc: "2.0", id: "r2", method: "ping" }));
		const r2 = await secondResponse;
		assert.deepEqual(r2, { jsonrpc: "2.0", id: "r2", result: { ok: true } });

		client.destroy();
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
