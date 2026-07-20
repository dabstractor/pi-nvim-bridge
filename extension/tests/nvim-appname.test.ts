/**
 * nvim-appname.test.ts — S47: asserts the optional `NVIM_APPNAME` minimal-config
 * opt-in (`PI_EDITOR_NVIM_APPNAME`) resolves correctly, applies/ restores cleanly
 * through `startBridge`/`stopBridge`, is OFF by default (a no-op that never touches
 * `process.env.NVIM_APPNAME`), never clobbers a pre-existing user value, is idempotent
 * across two `startBridge` calls, and is gated to TUI mode only.
 *
 * PATTERN: mirrors S16's `bridge-env.test.ts` verbatim — its `makeFakeServer()` /
 * `mockDeps()` helper (snapshot+restore `__deps.createServer`/`chmodSync` via the fake
 * server) and the `captureHandlers()` / `fakePi` pattern for the factory-wiring
 * (TUI vs non-tui) test. Because `process.env` is SHARED across tests in one process
 * (GOTCHA #6), EVERY test tears down in a `finally`: restore `__deps`, reset the fd
 * cache (`__setFdAvailableForTest(undefined)`), `__resetNvimAppnameStateForTest()`,
 * delete BOTH `process.env.NVIM_APPNAME` AND `process.env.PI_EDITOR_NVIM_APPNAME`, and
 * `stopBridge()`.
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
	resolveNvimAppname,
	__deps,
	__setFdAvailableForTest,
	__resetNvimAppnameStateForTest,
	NVIM_APPNAME_ENV,
	NVIM_APPNAME_OPTIN_ENV,
	DEFAULT_NVIM_APPNAME,
} from "../pi-editor-bridge.ts";
import bridgeFactory from "../pi-editor-bridge.ts";

type StartHandler = (event: SessionStartEvent, ctx: ExtensionContext) => void;
type ShutdownHandler = (event: SessionShutdownEvent) => void;

// Build a fake server for the mocked tests: records the listen() arg, returns itself
// (matches `listen(): this`), and provides close()/on() no-ops so stopBridge() inside
// startBridge's first line is safe (mirrors S5/S16's fakeServer shape).
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
// TEST 1 — PURE resolver value table (no startBridge). unset → undefined;
// "" → "pi-editor"; "1"/"TRUE"/"yes"/"On" → "pi-editor"; "pi-fast" → "pi-fast";
// "  pi-editor  " (whitespace) → "pi-editor" (trim). Set/restore the opt-in env in
// a finally (process.env is shared across tests — GOTCHA #6).
// ============================================================================
test("resolveNvimAppname() value table: unset→undefined, sentinels→default, literal→literal, trimmed", () => {
	try {
		// unset ⇒ OFF
		delete process.env[NVIM_APPNAME_OPTIN_ENV];
		assert.equal(resolveNvimAppname(), undefined, "unset ⇒ undefined (OFF)");

		// empty / truthy sentinels ⇒ DEFAULT_NVIM_APPNAME ("pi-editor")
		for (const v of ["", "1", "TRUE", "yes", "On"]) {
			process.env[NVIM_APPNAME_OPTIN_ENV] = v;
			assert.equal(
				resolveNvimAppname(),
				DEFAULT_NVIM_APPNAME,
				`sentinel ${JSON.stringify(v)} ⇒ default "pi-editor"`,
			);
		}

		// any other non-empty string ⇒ that literal appname
		process.env[NVIM_APPNAME_OPTIN_ENV] = "pi-fast";
		assert.equal(resolveNvimAppname(), "pi-fast", "custom literal ⇒ that literal");

		// whitespace is trimmed (so "  pi-editor  " ⇒ "pi-editor", NOT a custom literal)
		process.env[NVIM_APPNAME_OPTIN_ENV] = "  pi-editor  ";
		assert.equal(
			resolveNvimAppname(),
			DEFAULT_NVIM_APPNAME,
			"trimmed whitespace ⇒ default (not a custom literal)",
		);

		// whitespace around a custom literal is trimmed too
		process.env[NVIM_APPNAME_OPTIN_ENV] = "  pi-fast  ";
		assert.equal(resolveNvimAppname(), "pi-fast", "custom literal trimmed");
	} finally {
		delete process.env[NVIM_APPNAME_OPTIN_ENV];
		__resetNvimAppnameStateForTest();
		delete process.env[NVIM_APPNAME_ENV];
	}
});

// ============================================================================
// TEST 2 — apply lifecycle (opt-in ON, default appname): PI_EDITOR_NVIM_APPNAME=1;
// startBridge ⇒ process.env.NVIM_APPNAME === "pi-editor".
// ============================================================================
test("startBridge applies the default NVIM_APPNAME when opt-in is a truthy sentinel", () => {
	const mock = mockDeps();
	__setFdAvailableForTest(true);
	process.env[NVIM_APPNAME_OPTIN_ENV] = "1";
	try {
		startBridge({ cwd: "/test/proj" } as ExtensionContext);
		assert.equal(
			process.env[NVIM_APPNAME_ENV],
			DEFAULT_NVIM_APPNAME,
			'opt-in=1 ⇒ NVIM_APPNAME === "pi-editor" after startBridge',
		);
	} finally {
		__setFdAvailableForTest(undefined);
		__resetNvimAppnameStateForTest();
		delete process.env[NVIM_APPNAME_ENV];
		delete process.env[NVIM_APPNAME_OPTIN_ENV];
		mock.restore();
		stopBridge();
	}
});

// ============================================================================
// TEST 3 — apply lifecycle (custom appname): PI_EDITOR_NVIM_APPNAME=pi-fast;
// startBridge ⇒ process.env.NVIM_APPNAME === "pi-fast".
// ============================================================================
test("startBridge applies a custom NVIM_APPNAME when the opt-in is a literal", () => {
	const mock = mockDeps();
	__setFdAvailableForTest(true);
	process.env[NVIM_APPNAME_OPTIN_ENV] = "pi-fast";
	try {
		startBridge({ cwd: "/test/proj" } as ExtensionContext);
		assert.equal(
			process.env[NVIM_APPNAME_ENV],
			"pi-fast",
			'opt-in=pi-fast ⇒ NVIM_APPNAME === "pi-fast" after startBridge',
		);
	} finally {
		__setFdAvailableForTest(undefined);
		__resetNvimAppnameStateForTest();
		delete process.env[NVIM_APPNAME_ENV];
		delete process.env[NVIM_APPNAME_OPTIN_ENV];
		mock.restore();
		stopBridge();
	}
});

// ============================================================================
// TEST 4 — opt-in OFF is a no-op: leave PI_EDITOR_NVIM_APPNAME unset; startBridge ⇒
// NVIM_APPNAME stays undefined (never touched). ALSO re-asserts the S16 contract still
// holds (PI_EDITOR_BRIDGE parses, 7 keys, serverVersion "0.1.0") — proves no regression.
// ============================================================================
test("opt-in OFF (unset) ⇒ startBridge never touches NVIM_APPNAME; S16 descriptor contract intact", () => {
	const mock = mockDeps();
	__setFdAvailableForTest(true);
	delete process.env[NVIM_APPNAME_OPTIN_ENV];
	delete process.env[NVIM_APPNAME_ENV]; // ensure a clean baseline
	try {
		startBridge({ cwd: "/test/proj" } as ExtensionContext);
		assert.equal(
			process.env[NVIM_APPNAME_ENV],
			undefined,
			"opt-in OFF ⇒ NVIM_APPNAME never written",
		);

		// S16 regression: the descriptor contract is byte-identical to today.
		const raw = process.env.PI_EDITOR_BRIDGE;
		assert.equal(typeof raw, "string", "PI_EDITOR_BRIDGE still set");
		const desc = JSON.parse(raw!);
		assert.equal(desc.serverVersion, "0.1.0");
		assert.equal(Object.keys(desc).length, 7, "descriptor stays EXACTLY 7 keys");
	} finally {
		__setFdAvailableForTest(undefined);
		__resetNvimAppnameStateForTest();
		delete process.env[NVIM_APPNAME_ENV];
		delete process.env[NVIM_APPNAME_OPTIN_ENV];
		mock.restore();
		stopBridge();
	}
});

// ============================================================================
// TEST 5 — restore after stopBridge (NO pre-existing baseline): opt-in=1; startBridge ⇒
// "pi-editor"; stopBridge ⇒ undefined (was undefined before).
// ============================================================================
test("stopBridge restores NVIM_APPNAME to undefined when the user had none", () => {
	const mock = mockDeps();
	__setFdAvailableForTest(true);
	delete process.env[NVIM_APPNAME_ENV]; // no pre-existing user value
	process.env[NVIM_APPNAME_OPTIN_ENV] = "1";
	try {
		startBridge({ cwd: "/test/proj" } as ExtensionContext);
		assert.equal(process.env[NVIM_APPNAME_ENV], DEFAULT_NVIM_APPNAME);

		stopBridge();
		assert.equal(
			process.env[NVIM_APPNAME_ENV],
			undefined,
			"stopBridge deletes the override (baseline was undefined)",
		);
	} finally {
		__setFdAvailableForTest(undefined);
		__resetNvimAppnameStateForTest();
		delete process.env[NVIM_APPNAME_ENV];
		delete process.env[NVIM_APPNAME_OPTIN_ENV];
		mock.restore();
		stopBridge();
	}
});

// ============================================================================
// TEST 6 — THE key correctness invariant: a pre-existing user NVIM_APPNAME is RESTORED
// after stopBridge (never clobbered/deleted — GOTCHA #1).
// ============================================================================
test("a pre-existing user NVIM_APPNAME is RESTORED after stopBridge (never clobbered)", () => {
	const mock = mockDeps();
	__setFdAvailableForTest(true);
	process.env[NVIM_APPNAME_ENV] = "work"; // user's global profile
	process.env[NVIM_APPNAME_OPTIN_ENV] = "1"; // opt in to the bridge override
	try {
		startBridge({ cwd: "/test/proj" } as ExtensionContext);
		assert.equal(
			process.env[NVIM_APPNAME_ENV],
			DEFAULT_NVIM_APPNAME,
			"override active during session",
		);

		stopBridge();
		assert.equal(
			process.env[NVIM_APPNAME_ENV],
			"work",
			"user baseline RESTORED — NOT deleted/clobbered (GOTCHA #1)",
		);
	} finally {
		__setFdAvailableForTest(undefined);
		__resetNvimAppnameStateForTest();
		delete process.env[NVIM_APPNAME_ENV];
		delete process.env[NVIM_APPNAME_OPTIN_ENV];
		mock.restore();
		stopBridge();
	}
});

// ============================================================================
// TEST 7 — IDEMPOTENT across two startBridge calls (GOTCHA #3): opt-in=1; pre-set
// NVIM_APPNAME="work"; startBridge ⇒ "pi-editor"; startBridge again (internal
// stopBridge restores to "work", then re-applies) ⇒ "pi-editor"; stopBridge ⇒ "work".
// Proves the baseline capture on the 2nd apply reads the genuine environment, not the
// bridge's own prior override.
// ============================================================================
test("idempotent across two startBridge calls: 2nd apply captures the genuine baseline (GOTCHA #3)", () => {
	const mock = mockDeps();
	__setFdAvailableForTest(true);
	process.env[NVIM_APPNAME_ENV] = "work";
	process.env[NVIM_APPNAME_OPTIN_ENV] = "1";
	try {
		const ctx = { cwd: "/test/proj" } as ExtensionContext;

		startBridge(ctx);
		assert.equal(process.env[NVIM_APPNAME_ENV], DEFAULT_NVIM_APPNAME, "1st apply overrides");

		startBridge(ctx); // internal stopBridge restores "work", then re-applies
		assert.equal(
			process.env[NVIM_APPNAME_ENV],
			DEFAULT_NVIM_APPNAME,
			"2nd apply overrides again (baseline capture read the genuine env, not the prior override)",
		);

		stopBridge();
		assert.equal(
			process.env[NVIM_APPNAME_ENV],
			"work",
			"after final stopBridge, user baseline restored",
		);
	} finally {
		__setFdAvailableForTest(undefined);
		__resetNvimAppnameStateForTest();
		delete process.env[NVIM_APPNAME_ENV];
		delete process.env[NVIM_APPNAME_OPTIN_ENV];
		mock.restore();
		stopBridge();
	}
});

// ============================================================================
// TEST 8 — FACTORY WIRING (TUI guard — GOTCHA #8): reuse bridge-env TEST 4's
// captureHandlers(). session_start(tui) ⇒ NVIM_APPNAME === "pi-editor";
// session_shutdown ⇒ undefined; for each non-tui mode ("rpc"/"json"/"print")
// session_start ⇒ NVIM_APPNAME stays undefined (TUI guard intact).
// ============================================================================
test("factory wiring: session_start(tui) applies, session_shutdown restores, non-tui never applies", () => {
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
	process.env[NVIM_APPNAME_OPTIN_ENV] = "1";
	delete process.env[NVIM_APPNAME_ENV]; // clean baseline
	try {
		const { startHandler, shutdownHandler } = captureHandlers();
		const STARTUP = { reason: "startup" } as SessionStartEvent;

		// tui: session_start applies the override; session_shutdown restores it.
		startHandler(
			STARTUP,
			{
				mode: "tui",
				ui: { addAutocompleteProvider: () => {} },
				cwd: "/test/proj",
			} as unknown as ExtensionContext,
		);
		assert.equal(
			process.env[NVIM_APPNAME_ENV],
			DEFAULT_NVIM_APPNAME,
			"session_start(tui) applies NVIM_APPNAME override",
		);

		shutdownHandler({} as SessionShutdownEvent);
		assert.equal(
			process.env[NVIM_APPNAME_ENV],
			undefined,
			"session_shutdown restores NVIM_APPNAME (baseline was undefined)",
		);

		// non-tui: session_start returns before startBridge (TUI guard) → never applies.
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
				process.env[NVIM_APPNAME_ENV],
				undefined,
				`NVIM_APPNAME NOT set after session_start(${mode}) — TUI guard intact (GOTCHA #8)`,
			);
		}
	} finally {
		__setFdAvailableForTest(undefined);
		__resetNvimAppnameStateForTest();
		delete process.env[NVIM_APPNAME_ENV];
		delete process.env[NVIM_APPNAME_OPTIN_ENV];
		mock.restore();
		stopBridge();
	}
});