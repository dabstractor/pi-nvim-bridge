import { test } from "node:test";
import assert from "node:assert/strict";
import { statSync, existsSync } from "node:fs";
import { once } from "node:events";
import type { ExtensionContext } from "@earendil-works/pi-coding-agent";
import {
	startBridge,
	stopBridge,
	getServer,
	getSocketPath,
	getToken,
	__deps,
} from "../pi-nvim-bridge.ts";

// startBridge does NOT dereference ctx in S5, so a bare cast is sufficient.
const fakeCtx = {} as ExtensionContext;

// The __deps seam defaults to the real builtins; snapshot them so mock overrides restore
// cleanly. (Plain-object property assignment is allowed — the node:net namespace is NOT
// involved, which is the whole point of the seam.)
const realCreateServer = __deps.createServer;
const realChmodSync = __deps.chmodSync;

// ============================================================================
// TEST 1 — MOCKED: honors the createServer + chmodSync(_,0o600) contract WITHOUT
// touching the filesystem / network (the frozen node:net namespace forbids direct
// mocking; the __deps seam is the sanctioned override point). Proves the wire shape.
// ============================================================================
test("startBridge (mocked): createServer + chmodSync(_,0o600) invoked, token 32-hex, getters populated", () => {
	let listenArg: string | undefined;
	let chmodCall: { path: string; mode: number } | undefined;

	// Fake server: record the listen() arg, return itself (matches `listen(): this`),
	// provide a close() no-op so stopBridge() inside startBridge's first line is safe.
	const fakeServer = {
		listening: false,
		listen(arg: string) {
			listenArg = arg;
			return fakeServer;
		},
		close() {
			/* no-op */
		},
		on(_event: string, _handler: (err: Error) => void) {
			return fakeServer; // S6: startBridge attaches server.on("error", …); no-op in the mock.
		},
	};
	__deps.createServer = (() => fakeServer) as unknown as typeof realCreateServer;
	__deps.chmodSync = ((path: string, mode: number) => {
		chmodCall = { path, mode };
	}) as unknown as typeof realChmodSync;

	try {
		startBridge(fakeCtx);

		// socket path shape (unique, under tmpdir, .sock extension)
		assert.match(
			listenArg ?? "",
			/pi-nvim-bridge-[0-9a-f-]+\.sock$/,
			"listen() must be called with a unique pi-nvim-bridge-*.sock path",
		);
		// chmod called with EXACTLY the listen path and 0o600
		assert.ok(chmodCall, "chmodSync must be invoked");
		assert.equal(chmodCall!.mode, 0o600, "chmodSync mode must be 0o600");
		assert.equal(chmodCall!.path, listenArg, "chmodSync path must equal the listen path");
		// token is exactly 32 lowercase hex chars (PRD §12)
		assert.match(
			getToken() ?? "",
			/^[0-9a-f]{32}$/,
			"token must be 32 lowercase hex chars",
		);
		// getters populated + consistent
		assert.equal(getSocketPath(), listenArg, "getSocketPath() === listen arg");
		assert.equal(getServer(), fakeServer, "getServer() === the created server");
	} finally {
		__deps.createServer = realCreateServer;
		__deps.chmodSync = realChmodSync;
		stopBridge(); // reset module singleton state for the next test
	}
});

// ============================================================================
// TEST 2 — REAL INTEGRATION: actual net.createServer + listen + chmod. Asserts the
// on-disk socket file mode is EXACTLY 0o600 and the server is listening, then that
// stopBridge unlinks the file + clears state.
// ============================================================================
test("startBridge (real): socket binds, on-disk mode 0o600, server.listening; stopBridge unlinks + clears", async () => {
	startBridge(fakeCtx);
	const srv = getServer();
	const path = getSocketPath();
	assert.ok(srv, "getServer() must be populated after startBridge");
	assert.ok(path, "getSocketPath() must be populated after startBridge");

	await once(srv!, "listening"); // listen() is async; wait for the bind to complete
	assert.equal(srv!.listening, true, "server must be listening after 'listening' event");

	// The load-bearing security assertion: 0o600 on disk (verified safe because libuv
	// creates the socket file synchronously inside listen()).
	const mode = statSync(path!).mode & 0o777;
	assert.equal(mode, 0o600, "socket file mode must be exactly 0o600");

	stopBridge();
	assert.equal(getServer(), undefined, "getServer() cleared after stopBridge");
	assert.equal(getSocketPath(), undefined, "getSocketPath() cleared after stopBridge");
	assert.equal(getToken(), undefined, "getToken() cleared after stopBridge");
	assert.equal(existsSync(path), false, "socket file must be unlinked after stopBridge");
});

// ============================================================================
// TEST 3 — IDEMPOTENCY: calling startBridge twice must close server #1, unlink its
// socket, and yield a NEW server + NEW path (no leak across repeated session_start).
// ============================================================================
test("startBridge is idempotent: second call closes server #1, unlinks its socket, yields a new server+path", async () => {
	startBridge(fakeCtx);
	const first = getServer();
	const firstPath = getSocketPath();
	assert.ok(first && firstPath);
	await once(first!, "listening");

	startBridge(fakeCtx); // restart — stopBridge() runs first inside

	assert.notEqual(getServer(), first, "second startBridge must yield a NEW server");
	assert.notEqual(getSocketPath(), firstPath, "second startBridge must yield a NEW path");
	assert.equal(
		existsSync(firstPath!),
		false,
		"first socket file must be unlinked by the stopBridge() inside the second startBridge",
	);

	await once(getServer()!, "listening");
	assert.equal(getServer()!.listening, true, "second server must be listening");
	stopBridge();
});

// ============================================================================
// TEST 4 — stopBridge idle no-op + reset: safe to call when nothing is running, and
// it leaves all getters undefined.
// ============================================================================
test("stopBridge is a safe no-op when idle and resets all state", () => {
	assert.doesNotThrow(() => stopBridge(), "stopBridge must not throw when idle");
	assert.equal(getServer(), undefined);
	assert.equal(getSocketPath(), undefined);
	assert.equal(getToken(), undefined);
});
