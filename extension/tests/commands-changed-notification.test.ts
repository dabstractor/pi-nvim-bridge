/**
 * commands-changed-notification.test.ts — P1.M3.T9.S17.
 *
 * Three layers covering the ONE server→client NOTIFICATION in PRD §5.4
 * (`commandsChanged`, empty params, no result) and the bridge's FIRST connection
 * registry that backs it:
 *
 *  LAYER 1 — UNIT (connection.ts directly): the registry lifecycle, the broadcast
 *    handshake filter, and `closeAllConnections` teardown.
 *  LAYER 2 — WIRING (pi-nvim-bridge.ts via the factory + __deps spy): `session_start`
 *    emits `__deps.broadcastNotification("commandsChanged")` AFTER startBridge in tui
 *    mode (and NOT in non-tui); `stopBridge()` clears the registry.
 *  LAYER 3 — REAL (one real Unix-socket pair): a handshaken client receives the
 *    broadcast; `closeAllConnections()`/`stopBridge()` closes a live client.
 *
 * node:test + jiti (NOT vitest). EVERY test calls `__resetConnectionsForTest()` (and
 * `__resetHandlersForTest()` when it registered a handler) in `finally` — both Maps
 * are module-level and persist across tests. fakeSocket()/parseResponses()/
 * readFirstResponse() are LOCAL per-file helpers copied from connection.test.ts.
 */
import { test } from "node:test";
import assert from "node:assert/strict";
import { EventEmitter, once } from "node:events";
import { createServer, connect, type Socket } from "node:net";
import { randomUUID } from "node:crypto";
import { chmodSync as chmodSyncRef } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type {
	ExtensionAPI,
	ExtensionContext,
	SessionStartEvent,
	SessionShutdownEvent,
} from "@earendil-works/pi-coding-agent";
import {
	onConnection,
	broadcastNotification,
	closeAllConnections,
	sendNotification,
	registerBridgeHandler,
	__resetHandlersForTest,
	__resetConnectionsForTest,
	__getActiveConnectionCountForTest,
	__getConnectionStateForTest,
} from "../connection.ts";
import bridgeFactory, {
	__deps,
	stopBridge,
	getServer,
	__setFdAvailableForTest,
	makeHelloHandler,
	BRIDGE_VERSION,
} from "../pi-nvim-bridge.ts";
import { attachJsonlLineReader, serializeJsonLine } from "../jsonl-reader.ts";

// A fake socket: EventEmitter (for .on/.emit/.listenerCount) + a write() that captures
// every serialized line. .destroy()/.end() emit 'close' (the real net.Socket does too).
// `state` records whether end() was called so closeAllConnections' end() is assertable.
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

// ============================================================================
// LAYER 1 — UNIT: the connection registry, broadcastNotification, closeAllConnections
// (exercised against connection.ts directly, via the fakeSocket helper).
// ============================================================================

test("UNIT: broadcastNotification on an EMPTY registry is a no-op (no throw)", () => {
	__resetConnectionsForTest();
	try {
		assert.doesNotThrow(() => broadcastNotification("commandsChanged"));
	} finally {
		__resetConnectionsForTest();
	}
});

test("UNIT: broadcastNotification writes exactly one no-id notification to a HANDSHAKEN socket", () => {
	__resetConnectionsForTest();
	try {
		const { sock, writes } = fakeSocket();
		onConnection(sock);
		// Flip the socket handshaken (the registry stored the state object onConnection created).
		const st = __getConnectionStateForTest(sock);
		assert.ok(st, "onConnection must register the socket in the connections Map");
		st!.handshakeComplete = true;

		broadcastNotification("commandsChanged");

		assert.equal(writes.length, 1, "exactly one notification line written");
		const parsed = parseResponses(writes)[0] as Record<string, unknown>;
		assert.equal(parsed.jsonrpc, "2.0");
		assert.equal(parsed.method, "commandsChanged");
		assert.ok(!("id" in parsed), "notification must have NO id (it is not a request)");
		assert.ok(!("params" in parsed), "empty params are OMITTED on the wire (cleaner)");
	} finally {
		__resetConnectionsForTest();
	}
});

test("UNIT: broadcastNotification writes NOTHING to a NON-handshaken socket (PRD §12)", () => {
	__resetConnectionsForTest();
	try {
		const { sock, writes } = fakeSocket();
		onConnection(sock);
		// handshakeComplete stays false (no hello). Broadcast must be filtered out.
		assert.equal(__getConnectionStateForTest(sock)?.handshakeComplete, false);

		broadcastNotification("commandsChanged");

		assert.equal(writes.length, 0, "non-handshaken socket must receive NO notification");
	} finally {
		__resetConnectionsForTest();
	}
});

test("UNIT: broadcastNotification on a MIXED registry notifies ONLY handshaken sockets", () => {
	__resetConnectionsForTest();
	try {
		const a = fakeSocket(); // handshaken
		const b = fakeSocket(); // NOT handshaken
		const c = fakeSocket(); // handshaken
		onConnection(a.sock);
		onConnection(b.sock);
		onConnection(c.sock);
		__getConnectionStateForTest(a.sock)!.handshakeComplete = true;
		// b stays handshakeComplete:false
		__getConnectionStateForTest(c.sock)!.handshakeComplete = true;

		broadcastNotification("commandsChanged");

		assert.equal(a.writes.length, 1, "handshaken socket a notified");
		assert.equal(b.writes.length, 0, "non-handshaken socket b NOT notified");
		assert.equal(c.writes.length, 1, "handshaken socket c notified");
	} finally {
		__resetConnectionsForTest();
	}
});

test("UNIT: onConnection registers the socket; 'close' removes it (no leak across editor cycles)", () => {
	__resetConnectionsForTest();
	try {
		const { sock } = fakeSocket();
		onConnection(sock);
		assert.equal(__getActiveConnectionCountForTest(), 1, "socket tracked after onConnection");
		sock.emit("close");
		assert.equal(__getActiveConnectionCountForTest(), 0, "socket removed from registry on close");
	} finally {
		__resetConnectionsForTest();
	}
});

test("UNIT: closeAllConnections ends every tracked socket + clears the registry", () => {
	__resetConnectionsForTest();
	try {
		const a = fakeSocket();
		const b = fakeSocket();
		onConnection(a.sock);
		onConnection(b.sock);
		assert.equal(__getActiveConnectionCountForTest(), 2);

		closeAllConnections();

		assert.equal(a.state.ended, true, "socket a.end() called (graceful FIN, not destroy)");
		assert.equal(b.state.ended, true, "socket b.end() called (graceful FIN, not destroy)");
		assert.equal(__getActiveConnectionCountForTest(), 0, "registry cleared");
	} finally {
		__resetConnectionsForTest();
	}
});

test("UNIT: closeAllConnections on an EMPTY registry is a no-op (no throw)", () => {
	__resetConnectionsForTest();
	try {
		assert.doesNotThrow(() => closeAllConnections());
		assert.equal(__getActiveConnectionCountForTest(), 0);
	} finally {
		__resetConnectionsForTest();
	}
});

test("UNIT: SECURITY — sendNotification('commandsChanged') writes NO token/sensitive data", () => {
	// commandsChanged has empty params so it trivially cannot leak. Assert it for discipline
	// (mirrors the S9-S14 security sweep contract, PRD §12).
	const TOKEN = "supersecret-deadbeef-1234";
	const { sock, writes } = fakeSocket();
	sendNotification(sock, "commandsChanged");
	const line = writes.join("");
	assert.ok(!line.includes(TOKEN), "the broadcast line must not contain any secret material");
});

// ============================================================================
// LAYER 2 — WIRING: session_start emits via __deps.broadcastNotification; stopBridge
// clears the registry. Uses a fake pi (records handlers) + a fake createServer (no real
// listen) + a spy on __deps.broadcastNotification.
// ============================================================================

type StartHandler = (event: SessionStartEvent, ctx: ExtensionContext) => void;
type ShutdownHandler = (event: SessionShutdownEvent) => void;

function captureHandlers(factory: typeof bridgeFactory): {
	startHandler: StartHandler;
	shutdownHandler: ShutdownHandler;
} {
	let startHandler: StartHandler | undefined;
	let shutdownHandler: ShutdownHandler | undefined;
	const fakePi = {
		on(event: string, h: StartHandler | ShutdownHandler) {
			if (event === "session_start") startHandler = h as StartHandler;
			if (event === "session_shutdown") shutdownHandler = h as ShutdownHandler;
		},
	} as unknown as ExtensionAPI;
	factory(fakePi);
	assert.ok(typeof startHandler === "function");
	assert.ok(typeof shutdownHandler === "function");
	return { startHandler: startHandler!, shutdownHandler: shutdownHandler! };
}

function makeCtx(mode: ExtensionContext["mode"]): ExtensionContext {
	return {
		mode,
		cwd: "/test",
		ui: { addAutocompleteProvider: () => {} },
	} as unknown as ExtensionContext;
}

// A fake createServer: returns a fake Server whose listen()/close()/on() are no-ops so
// startBridge does NOT bind a real socket (and getServer() returns the fake). The real
// createServer would bind under os.tmpdir() — fine, but a fake keeps the wiring test pure.
function fakeCreateServer() {
	const fakeServer = Object.assign(new EventEmitter(), {
		listen() {
			return this;
		},
		close() {
			return this;
		},
		on() {
			return this;
		},
	});
	const fn = () => fakeServer;
	return { fn, fakeServer };
}

function installFakeServerDeps() {
	const realCreateServer = __deps.createServer;
	const realChmodSync = __deps.chmodSync;
	__deps.createServer = fakeCreateServer().fn as unknown as typeof createServer;
	__deps.chmodSync = (() => {}) as typeof chmodSyncRef;
	return () => {
		__deps.createServer = realCreateServer;
		__deps.chmodSync = realChmodSync;
	};
}
test("WIRING: session_start(tui) calls __deps.broadcastNotification('commandsChanged') after startBridge", () => {
	__resetConnectionsForTest();
	const restoreServer = installFakeServerDeps();
	const realBroadcast = __deps.broadcastNotification;
	let spyMethod: string | undefined;
	__deps.broadcastNotification = ((method: string) => {
		spyMethod = method;
	}) as typeof broadcastNotification;
	try {
		const { startHandler } = captureHandlers(bridgeFactory);
		startHandler({ reason: "startup" } as SessionStartEvent, makeCtx("tui"));
		assert.equal(spyMethod, "commandsChanged", "session_start(tui) must broadcast commandsChanged");
	} finally {
		__deps.broadcastNotification = realBroadcast;
		restoreServer();
		stopBridge();
		__setFdAvailableForTest(undefined);
		__resetConnectionsForTest();
		__resetHandlersForTest();
	}
});

test("WIRING: session_start(non-tui) does NOT broadcast (TUI guard returns before the emit)", () => {
	__resetConnectionsForTest();
	const restoreServer = installFakeServerDeps();
	const realBroadcast = __deps.broadcastNotification;
	let called = 0;
	__deps.broadcastNotification = (() => {
		called++;
	}) as typeof broadcastNotification;
	try {
		const { startHandler } = captureHandlers(bridgeFactory);
		for (const mode of ["rpc", "json", "print"] as const) {
			startHandler({ reason: "startup" } as SessionStartEvent, makeCtx(mode));
		}
		assert.equal(called, 0, "broadcastNotification must NOT be called in non-tui modes");
	} finally {
		__deps.broadcastNotification = realBroadcast;
		restoreServer();
		stopBridge();
		__setFdAvailableForTest(undefined);
		__resetConnectionsForTest();
		__resetHandlersForTest();
	}
});

test("WIRING: stopBridge() clears the connection registry (closeAllConnections wiring)", () => {
	__resetConnectionsForTest();
	const restoreServer = installFakeServerDeps();
	try {
		// Simulate a live connection registered via onConnection (handshaken, so end() matters).
		const { sock, state } = fakeSocket();
		onConnection(sock);
		__getConnectionStateForTest(sock)!.handshakeComplete = true;
		assert.equal(__getActiveConnectionCountForTest(), 1);

		stopBridge();

		assert.equal(
			__getActiveConnectionCountForTest(),
			0,
			"stopBridge must empty the registry (via closeAllConnections)",
		);
		assert.equal(state.ended, true, "stopBridge must end() every tracked socket");
	} finally {
		restoreServer();
		stopBridge();
		__resetConnectionsForTest();
		__resetHandlersForTest();
	}
});

// ============================================================================
// LAYER 3 — REAL: one real Unix-socket pair proves the broadcast reaches a handshaken
// client, and stopBridge/closeAllConnections closes a live client.
// ============================================================================

const REAL_TOKEN = "deadbeefdeadbeefdeadbeefdeadbeef";

test("REAL: a handshaken client receives the commandsChanged broadcast over a Unix socket", async () => {
	__resetHandlersForTest();
	__resetConnectionsForTest();
	// Register a real hello handler so the client can handshake (and become broadcast-eligible).
	registerBridgeHandler(
		"hello",
		makeHelloHandler({
			getToken: () => REAL_TOKEN,
			getCwd: () => "/tmp",
			getFdAvailable: () => true,
			version: BRIDGE_VERSION,
		}),
	);
	const sockpath = join(tmpdir(), `pi-bridge-s17-${randomUUID()}.sock`);
	const server = createServer((c) => onConnection(c));
	server.listen(sockpath);
	await once(server, "listening");
	try {
		const client = connect(sockpath);
		await once(client, "connect");

		// (1) hello first ⇒ HelloResult (the client is now handshaken + in the registry).
		const helloP = readFirstResponse(client);
		client.write(
			serializeJsonLine({
				jsonrpc: "2.0",
				id: "h1",
				method: "hello",
				params: { token: REAL_TOKEN },
			}),
		);
		const rHello = (await helloP) as Record<string, unknown>;
		assert.equal(rHello.id, "h1");

		// (2) server broadcasts commandsChanged ⇒ the client receives a no-id notification.
		const broadcastP = readFirstResponse(client);
		broadcastNotification("commandsChanged");
		const broadcast = (await broadcastP) as Record<string, unknown>;
		assert.equal(broadcast.jsonrpc, "2.0");
		assert.equal(broadcast.method, "commandsChanged");
		assert.ok(!("id" in broadcast), "broadcast must be a notification (no id)");
		assert.ok(
			!JSON.stringify(broadcast).includes(REAL_TOKEN),
			"SECURITY: the broadcast must not carry the token",
		);

		client.destroy();
	} finally {
		__resetHandlersForTest();
		__resetConnectionsForTest();
		server.close();
	}
});

test("REAL: closeAllConnections() (via stopBridge) closes a live client", async () => {
	__resetHandlersForTest();
	__resetConnectionsForTest();
	registerBridgeHandler(
		"hello",
		makeHelloHandler({
			getToken: () => REAL_TOKEN,
			getCwd: () => "/tmp",
			getFdAvailable: () => true,
			version: BRIDGE_VERSION,
		}),
	);
	const sockpath = join(tmpdir(), `pi-bridge-s17-close-${randomUUID()}.sock`);
	const server = createServer((c) => onConnection(c));
	server.listen(sockpath);
	await once(server, "listening");
	try {
		const client = connect(sockpath);
		await once(client, "connect");
		// handshake so the connection is in the registry with handshakeComplete:true.
		const helloP = readFirstResponse(client);
		client.write(
			serializeJsonLine({
				jsonrpc: "2.0",
				id: "h1",
				method: "hello",
				params: { token: REAL_TOKEN },
			}),
		);
		await helloP;

		// closeAllConnections force-ends every tracked socket → the client observes close/end.
		closeAllConnections();

		// Race the close/end events against a 2s timeout (the client MUST observe the close).
		const timeout = new Promise<"timeout">((resolve) => setTimeout(() => resolve("timeout"), 2000));
		const closed = Promise.race([
			once(client, "close").then(() => "closed" as const),
			once(client, "end").then(() => "ended" as const),
			timeout,
		]);
		assert.notEqual(await closed, "timeout", "the client must observe the server-side close");
		client.destroy();
	} finally {
		__resetHandlersForTest();
		__resetConnectionsForTest();
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
