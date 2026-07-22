/**
 * bridge-env.test.ts — S16: asserts `process.env.PI_NVIM_BRIDGE` carries a valid
 * single-line JSON `BridgeDescriptor` after `startBridge`, is deleted by `stopBridge`,
 * is freshly rewritten on repeated `startBridge`, and that the factory's session_start
 * (tui) / session_shutdown / non-tui guard all honor that contract.
 *
 * PATTERN: mirrors S5's `bridge-lifecycle.test.ts` (mocked exact-shape via the
 * `__deps` seam) + S6's `bridge-lifecycle-wiring.test.ts` (`captureHandlers()` /
 * factory lifecycle). Because `process.env` is SHARED across tests in one process
 * (GOTCHA #6), every test tears down in a `finally` (restore `__deps`, reset the fd
 * cache via `__setFdAvailableForTest(undefined)`, and `stopBridge()` to delete the env).
 */
import { test } from "node:test";
import assert from "node:assert/strict";
import type {
	ExtensionAPI,
	ExtensionContext,
	SessionStartEvent,
	SessionShutdownEvent,
} from "@earendil-works/pi-coding-agent";
import {
	startBridge,
	stopBridge,
	getSocketPath,
	getToken,
	BRIDGE_ENV,
	__deps,
	__setFdAvailableForTest,
} from "../pi-nvim-bridge.ts";
import bridgeFactory from "../pi-nvim-bridge.ts";

type StartHandler = (event: SessionStartEvent, ctx: ExtensionContext) => void;
type ShutdownHandler = (event: SessionShutdownEvent) => void;

// Build a fake server for the mocked tests: records the listen() arg, returns itself
// (matches `listen(): this`), and provides close()/on() no-ops so stopBridge() inside
// startBridge's first line is safe (mirrors S5's fakeServer shape).
function makeFakeServer() {
	return {
		listening: false,
		listen(arg: string) {
			return arg; // record+return not needed here; just satisfy the contract
		},
		close() {
			/* no-op */
		},
		on() {
			/* no-op */
		},
	};
}

// Install the __deps mocks (createServer + chmodSync) and return restore handles.
function mockDeps() {
	const realCreateServer = __deps.createServer;
	const realChmodSync = __deps.chmodSync;
	const fakeServer = makeFakeServer();
	__deps.createServer = (() => fakeServer) as unknown as typeof realCreateServer;
	__deps.chmodSync = (() => {}) as unknown as typeof realChmodSync;
	return {
		fakeServer,
		restore() {
			__deps.createServer = realCreateServer;
			__deps.chmodSync = realChmodSync;
		},
	};
}

// ============================================================================
// TEST 1 — MOCKED, EXACT DESCRIPTOR SHAPE: after startBridge, process.env.PI_NVIM_BRIDGE
// is a single-line JSON string parsing to an object with EXACTLY 7 keys and the expected
// values (transport/path/token/pid/cwd/fdAvailable/serverVersion).
// ============================================================================
test("startBridge writes a valid single-line BridgeDescriptor to process.env.PI_NVIM_BRIDGE", () => {
	const mock = mockDeps();
	__setFdAvailableForTest(true); // deterministic fd value (GOTCHA #2/#6)
	try {
		const fakeCtx = { cwd: "/test/proj" } as ExtensionContext; // WITH cwd (GOTCHA #3)
		startBridge(fakeCtx);

		const raw = process.env[BRIDGE_ENV];
		assert.equal(typeof raw, "string", "env must be set");
		assert.ok(!raw!.includes("\n"), "descriptor must be a single line (no \\n)");

		const desc = JSON.parse(raw!);
		assert.equal(desc.transport, "unix");
		assert.equal(desc.path, getSocketPath(), "path === live socket path");
		assert.equal(desc.token, getToken(), "token === live token");
		assert.equal(desc.pid, process.pid);
		assert.equal(desc.cwd, "/test/proj");
		assert.equal(desc.fdAvailable, true, "fdAvailable === real getFdAvailable() value");
		assert.equal(desc.serverVersion, "0.1.0", "serverVersion is '0.1.0' (NOT version/0.0.1)");
		assert.equal(Object.keys(desc).length, 7, "exactly 7 keys — no stray `version`");
	} finally {
		__setFdAvailableForTest(undefined); // reset fd cache (GOTCHA #6)
		mock.restore();
		stopBridge(); // deletes the env var
	}
});

// ============================================================================
// TEST 2 — stopBridge DELETES the env var: after startBridge → stopBridge the env is
// undefined. ALSO: stopBridge when the env was never set is a safe no-op (delete on
// absent never throws).
// ============================================================================
test("stopBridge deletes process.env.PI_NVIM_BRIDGE (and is a safe no-op when never set)", () => {
	// Pre-condition: safe no-op when nothing was ever set.
	assert.equal(process.env[BRIDGE_ENV], undefined, "env must start unset");
	assert.doesNotThrow(() => stopBridge(), "stopBridge must not throw when env is absent");

	const mock = mockDeps();
	__setFdAvailableForTest(false); // deterministic; also exercises the false branch
	try {
		startBridge({ cwd: "/test/proj" } as ExtensionContext);
		assert.equal(typeof process.env[BRIDGE_ENV], "string", "env set after startBridge");

		stopBridge();
		assert.equal(process.env[BRIDGE_ENV], undefined, "env deleted after stopBridge");
	} finally {
		__setFdAvailableForTest(undefined);
		mock.restore();
		stopBridge();
	}
});

// ============================================================================
// TEST 3 — IDEMPOTENT RE-WRITE: startBridge twice (the 2nd call's internal stopBridge
// closes #1). After the 2nd, the descriptor's path/token match the 2nd getSocketPath()/
// getToken() (NOT the 1st). Each startBridge writes a FRESH descriptor.
// ============================================================================
test("startBridge is idempotent: each call writes a FRESH descriptor (2nd overwrites 1st)", () => {
	const mock = mockDeps();
	__setFdAvailableForTest(true);
	try {
		const ctx = { cwd: "/test/proj" } as ExtensionContext;

		startBridge(ctx);
		const firstRaw = process.env[BRIDGE_ENV];
		const firstPath = getSocketPath();
		const firstToken = getToken();
		assert.equal(typeof firstRaw, "string", "env set after 1st startBridge");

		startBridge(ctx); // internal stopBridge closes #1, then binds a fresh socket+token

		const secondRaw = process.env[BRIDGE_ENV];
		assert.equal(typeof secondRaw, "string", "env set after 2nd startBridge");
		assert.notEqual(secondRaw, firstRaw, "2nd descriptor string differs from 1st");

		const desc = JSON.parse(secondRaw!);
		assert.equal(desc.path, getSocketPath(), "descriptor path === 2nd socket path");
		assert.equal(desc.token, getToken(), "descriptor token === 2nd token");
		assert.notEqual(desc.path, firstPath, "2nd socket path differs from 1st");
		assert.notEqual(desc.token, firstToken, "2nd token differs from 1st");
		assert.equal(desc.serverVersion, "0.1.0");
		assert.equal(Object.keys(desc).length, 7);
	} finally {
		__setFdAvailableForTest(undefined);
		mock.restore();
		stopBridge();
	}
});

// ============================================================================
// TEST 4 — FACTORY WIRING (full lifecycle): reuse S6's captureHandlers() pattern.
// session_start(tui) sets the env (parses with cwd==="/test/proj"); session_shutdown
// deletes it; for each non-tui mode session_start does NOT set it (TUI guard intact).
// ============================================================================
test("factory wiring: session_start(tui) sets env, session_shutdown deletes, non-tui never sets", () => {
	function captureHandlers() {
		let startHandler: StartHandler | undefined;
		let shutdownHandler: ShutdownHandler | undefined;
		const fakePi = {
			on(event: string, h: StartHandler | ShutdownHandler) {
				if (event === "session_start") startHandler = h as StartHandler;
				if (event === "session_shutdown") shutdownHandler = h as ShutdownHandler;
			},
		} as unknown as ExtensionAPI;
		bridgeFactory(fakePi);
		assert.ok(typeof startHandler === "function");
		assert.ok(typeof shutdownHandler === "function");
		return { startHandler: startHandler!, shutdownHandler: shutdownHandler! };
	}

	const mock = mockDeps();
	__setFdAvailableForTest(true);
	try {
		const { startHandler, shutdownHandler } = captureHandlers();
		const STARTUP = { reason: "startup" } as SessionStartEvent;

		// tui: session_start sets the env; session_shutdown deletes it.
		startHandler(
			STARTUP,
			{
				mode: "tui",
				ui: { addAutocompleteProvider: () => {} },
				cwd: "/test/proj",
			} as unknown as ExtensionContext,
		);
		const raw = process.env[BRIDGE_ENV];
		assert.equal(typeof raw, "string", "env set after session_start(tui)");
		const desc = JSON.parse(raw!);
		assert.equal(desc.cwd, "/test/proj", "descriptor cwd === ctx.cwd");
		assert.equal(desc.serverVersion, "0.1.0");

		shutdownHandler({} as SessionShutdownEvent);
		assert.equal(
			process.env[BRIDGE_ENV],
			undefined,
			"env deleted after session_shutdown",
		);

		// non-tui: session_start returns before startBridge → env never set.
		for (const mode of ["rpc", "json", "print"] as const) {
			startHandler(
				STARTUP,
				{
					mode,
					ui: { addAutocompleteProvider: () => {} },
					cwd: "/test/proj",
				} as unknown as ExtensionContext,
			);
			assert.equal(
				process.env[BRIDGE_ENV],
				undefined,
				`env NOT set after session_start(${mode}) — TUI guard intact`,
			);
		}
	} finally {
		__setFdAvailableForTest(undefined);
		mock.restore();
		stopBridge();
	}
});
