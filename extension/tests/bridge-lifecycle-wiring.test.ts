import { test } from "node:test";
import assert from "node:assert/strict";
import { statSync, existsSync } from "node:fs";
import { once } from "node:events";
import type {
	ExtensionAPI,
	ExtensionContext,
	SessionStartEvent,
	SessionShutdownEvent,
} from "@earendil-works/pi-coding-agent";
import bridgeFactory, {
	getServer,
	getSocketPath,
	getToken,
	stopBridge,
} from "../pi-editor-bridge.ts";

type StartHandler = (event: SessionStartEvent, ctx: ExtensionContext) => void;
type ShutdownHandler = (event: SessionShutdownEvent) => void;

// Run the factory with a fake pi that records BOTH session_start and session_shutdown handlers.
function captureHandlers(): { startHandler: StartHandler; shutdownHandler: ShutdownHandler } {
	let startHandler: StartHandler | undefined;
	let shutdownHandler: ShutdownHandler | undefined;
	const fakePi = {
		on(event: string, h: StartHandler | ShutdownHandler) {
			if (event === "session_start") startHandler = h as StartHandler;
			if (event === "session_shutdown") shutdownHandler = h as ShutdownHandler;
		},
	} as unknown as ExtensionAPI;

	bridgeFactory(fakePi);

	assert.ok(typeof startHandler === "function", "factory must register a session_start handler");
	assert.ok(typeof shutdownHandler === "function", "factory must register a session_shutdown handler");
	return { startHandler: startHandler!, shutdownHandler: shutdownHandler! };
}

// Minimal ctx: .mode (for the TUI guard) + .ui.addAutocompleteProvider (for captureProvider).
function makeCtx(mode: ExtensionContext["mode"]): ExtensionContext {
	return {
		mode,
		ui: { addAutocompleteProvider: () => {} },
	} as unknown as ExtensionContext;
}

const STARTUP = { reason: "startup" } as SessionStartEvent;

// ============================================================================
// TEST A — FULL LIFECYCLE (tui): session_start binds a listening 0o600 socket;
// session_shutdown tears it down (server closed, socket unlinked, state cleared).
// ============================================================================
test("session_start(tui) binds a listening 0o600 server; session_shutdown tears it down", async () => {
	const { startHandler, shutdownHandler } = captureHandlers();
	startHandler(STARTUP, makeCtx("tui"));
	const srv = getServer();
	const path = getSocketPath();
	assert.ok(srv, "getServer() populated after session_start(tui)");
	assert.ok(path, "getSocketPath() populated after session_start(tui)");
	assert.match(getToken() ?? "", /^[0-9a-f]{32}$/, "token must be 32 lowercase hex chars");

	await once(srv!, "listening"); // listen() is async; wait for the bind.
	assert.equal(srv!.listening, true, "server must be listening after 'listening'");
	assert.equal(statSync(path!).mode & 0o777, 0o600, "socket file mode must be exactly 0o600");

	shutdownHandler({} as SessionShutdownEvent); // the title deliverable: stopBridge() fires here
	assert.equal(getServer(), undefined, "getServer() cleared after session_shutdown");
	assert.equal(getSocketPath(), undefined, "getSocketPath() cleared after session_shutdown");
	assert.equal(getToken(), undefined, "getToken() cleared after session_shutdown");
	assert.equal(existsSync(path), false, "socket file must be unlinked after session_shutdown");
});

// ============================================================================
// TEST B — TUI GUARD (non-tui): the guard at the handler top returns BEFORE
// startBridge, so NO server is created in rpc/json/print mode (S3 behavior preserved).
// ============================================================================
test("session_start(non-tui) creates NO server — TUI guard intact (S3 regression)", () => {
	const { startHandler } = captureHandlers();
	for (const mode of ["rpc", "json", "print"] as const) {
		assert.doesNotThrow(() => startHandler(STARTUP, makeCtx(mode)));
		assert.equal(getServer(), undefined, `no server must exist after session_start(${mode})`);
	}
	stopBridge(); // idempotent tail cleanup (no-op here, but defensive)
});

// ============================================================================
// TEST C — ERROR HANDLER: a synthetic server 'error' does NOT throw (the handler catches
// it) and triggers stopBridge (getServer cleared, socket unlinked). Proves the deferred
// S6 handler works + never crashes pi.
// ============================================================================
test("server 'error' event is handled (no crash) and triggers stopBridge", async () => {
	const { startHandler } = captureHandlers();
	startHandler(STARTUP, makeCtx("tui"));
	const srv = getServer();
	const path = getSocketPath();
	assert.ok(srv && path);
	await once(srv!, "listening");

	// With the handler attached by S6, emitting 'error' MUST NOT throw (Node would otherwise
	// crash) and MUST trigger stopBridge (getServer cleared, socket unlinked).
	assert.doesNotThrow(
		() => srv!.emit("error", new Error("synthetic EADDRINUSE")),
		"emitting 'error' with a handler attached must not throw",
	);
	assert.equal(getServer(), undefined, "getServer() cleared by the error handler's stopBridge()");
	assert.equal(existsSync(path!), false, "socket file unlinked by the error handler's stopBridge()");

	// Let the async server.close() (queued by stopBridge) settle, then a final idempotent cleanup.
	await new Promise((r) => setTimeout(r, 30));
	stopBridge();
});
