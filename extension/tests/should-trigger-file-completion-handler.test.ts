/**
 * should-trigger-file-completion-handler.test.ts — P1.M2.T6.S13
 * `shouldTriggerFileCompletion` handler (unit + dispatch + integration).
 *
 * S13 is the third completion-engine RPC handler and the LEANEST in the M2.T6 family.
 * `makeShouldTriggerFileCompletionHandler` is a deps-injected factory (mirrors S9's
 * `makeHelloHandler` / S11's `makeGetSuggestionsHandler` / S12's
 * `makeApplyCompletionHandler`) that delegates to pi's LIVE
 * `AutocompleteProvider.shouldTriggerFileCompletion` SYNCHRONOUSLY. pi's impl is a pure
 * SYNC function (autocomplete.ts:775-785, verified) — it takes NO options/AbortSignal/
 * force and returns a `boolean` directly (the TUI calls it WITHOUT await —
 * editor.ts:2152-2153). So the S13 handler has NO AbortController, NO supersession, NO
 * timeout, NO closure state — 3 params (lines/cursorLine/cursorCol), a boolean result.
 *
 * THE ONE LOAD-BEARING NUANCE: unlike getSuggestions/applyCompletion (REQUIRED on the
 * interface), shouldTriggerFileCompletion is OPTIONAL (autocomplete.ts:269 has the `?`).
 * The handler MUST use optional chaining `?.` (a direct call throws TypeError on a
 * provider without the method) + nullish coalescing `?? true` (pi's documented default:
 * absent method ⇒ ALLOW file completion). pi's own tests, docs, and examples ALL write
 * `current.shouldTriggerFileCompletion?.(...) ?? true` (byte-identical across 5 sources).
 * The bridge replicates this VERBATIM. The OPTIONAL-method ⇒ true test (#3) is the
 * single most important correctness guarantee beyond S12's pattern.
 *
 * `node:test` + `assert/strict` + jiti (NOT vitest — S11 research §5). Three layers:
 *  1. UNIT (factory directly with a stub provider; fresh ConnectionState): true/false
 *     passthrough, the OPTIONAL-method ⇒ true default (a provider WITHOUT the method),
 *     exact-arg threading, sync return, param validation, provider-not-captured.
 *  2. DISPATCH (registerBridgeHandler + fakeSocket + handleLine, `{ handshakeComplete:
 *     true }` so the S10 gate opens): valid true → success, valid false → success,
 *     OPTIONAL-method → true (dispatch path), invalid params → -32602, pre-handshake →
 *     -32600 (regression: the gate fires before the handler).
 *  3. REAL integration (ONE real Unix-socket pair; hello + shouldTriggerFileCompletion
 *     registered): hello ⇒ HelloResult, shouldTriggerFileCompletion("/set") ⇒ false,
 *     shouldTriggerFileCompletion("hello") ⇒ true.
 *
 * NOTE: `fakeSocket`/`parseResponses`/`readFirstResponse` are copied VERBATIM from
 * get-suggestions-handler.test.ts / apply-completion-handler.test.ts (they are LOCAL
 * per-file helpers, NOT exported — connection.test.ts / hello-handler.test.ts /
 * handshake-gate.test.ts each re-declare them identically).
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
} from "../connection.ts";
import {
	makeShouldTriggerFileCompletionHandler,
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

// === STUB PROVIDERS ============================================================
// Minimal objects satisfying the AutocompleteProvider shape. The provider signature
// is: shouldTriggerFileCompletion?(lines, cursorLine, cursorCol) => boolean (SYNC,
// OPTIONAL); getSuggestions(...) => Promise<Suggestions|null> (unused by S13);
// applyCompletion(...) => { lines, cursorLine, cursorCol } (unused by S13).

/** Recorded last call shape (so tests assert what the handler threaded to the provider). */
type RecordedCall = {
	lines: string[];
	cursorLine: number;
	cursorCol: number;
};

/**
 * A stub provider that IMPLEMENTS shouldTriggerFileCompletion, RECORDS the last call
 * (lines/cursorLine/cursorCol), and returns a fixed `value`. Use {@link getLastCall}
 * to assert the handler threaded all three args untouched. getSuggestions/
 * applyCompletion are unused by S13 (present only to satisfy the interface type).
 */
function makeRecordingProvider(value: boolean): {
	provider: AutocompleteProvider;
	getLastCall: () => RecordedCall | undefined;
} {
	let lastCall: RecordedCall | undefined;
	const provider: AutocompleteProvider = {
		getSuggestions: async () => null, // unused by S13; present for interface satisfaction
		applyCompletion: (lines, cursorLine, cursorCol) => ({
			lines,
			cursorLine,
			cursorCol,
		}), // unused by S13; present for interface satisfaction
		shouldTriggerFileCompletion: (
			lines: string[],
			cursorLine: number,
			cursorCol: number,
		) => {
			lastCall = { lines, cursorLine, cursorCol };
			return value;
		},
	};
	return { provider, getLastCall: () => lastCall };
}

/**
 * A stub provider that OMITS shouldTriggerFileCompletion entirely (the OPTIONAL-method
 * case). The handler's `?.` must short-circuit to `undefined`, and the `?? true` default
 * must yield `true`. A provider with the key set to `undefined` is DIFFERENT ("present
 * but undefined"); the cleanest test OMITS the key. getSuggestions/applyCompletion are
 * present only to satisfy the interface type.
 */
function makeProviderWithoutMethod(): AutocompleteProvider {
	return {
		getSuggestions: async () => null,
		applyCompletion: (lines, cursorLine, cursorCol) => ({
			lines,
			cursorLine,
			cursorCol,
		}),
		// NOTE: shouldTriggerFileCompletion deliberately OMITTED — the `?.` must handle this.
	};
}

// === 1. UNIT (makeShouldTriggerFileCompletionHandler directly — stub provider) =

test("UNIT: true passthrough — provider implements the method and returns true", () => {
	const { provider } = makeRecordingProvider(true);
	const handler = makeShouldTriggerFileCompletionHandler({ getProvider: () => provider });
	const got = handler(
		{ lines: ["hello wor"], cursorLine: 0, cursorCol: 9 },
		{ handshakeComplete: true },
	);
	assert.equal(got, true);
});

test("UNIT: false passthrough — provider returns false (the realistic \"/set\" case)", () => {
	const { provider } = makeRecordingProvider(false);
	const handler = makeShouldTriggerFileCompletionHandler({ getProvider: () => provider });
	const got = handler(
		{ lines: ["/set"], cursorLine: 0, cursorCol: 4 },
		{ handshakeComplete: true },
	);
	assert.equal(got, false);
});

test("UNIT: OPTIONAL-method ⇒ true default (THE KEY S13 TEST) — provider WITHOUT the method returns true", () => {
	// The handler's `?.` short-circuits to undefined; the `?? true` default yields true.
	// This is pi's documented contract: absent method ⇒ ALLOW file completion.
	const provider = makeProviderWithoutMethod();
	const handler = makeShouldTriggerFileCompletionHandler({ getProvider: () => provider });
	const got = handler(
		{ lines: ["anything"], cursorLine: 0, cursorCol: 8 },
		{ handshakeComplete: true },
	);
	assert.equal(got, true);
});

test("UNIT: exact-arg threading — all THREE params forwarded to the provider UNTOUCHED", () => {
	const { provider, getLastCall } = makeRecordingProvider(true);
	const handler = makeShouldTriggerFileCompletionHandler({ getProvider: () => provider });
	const lines = ["/set"];
	const r = handler(
		{ lines, cursorLine: 0, cursorCol: 4 },
		{ handshakeComplete: true },
	);
	assert.equal(r, true);
	// The provider received EXACTLY what the client sent — byte-for-byte.
	assert.deepEqual(getLastCall(), {
		lines: ["/set"],
		cursorLine: 0,
		cursorCol: 4,
	});
});

test("UNIT: sync return — the handler returns a boolean directly (no Promise wrap)", () => {
	const { provider } = makeRecordingProvider(true);
	const handler = makeShouldTriggerFileCompletionHandler({ getProvider: () => provider });
	const r = handler(
		{ lines: ["hello"], cursorLine: 0, cursorCol: 5 },
		{ handshakeComplete: true },
	);
	// A SYNC return: the handler yields a primitive boolean, not a Promise of it.
	// `typeof === "boolean"` proves it is a primitive (a Promise would be "object").
	assert.equal(r, true);
	assert.equal(typeof r, "boolean", "the return type is a primitive boolean (sync)");
});

// === 1b. UNIT — PARAM VALIDATION (BridgeRpcError -32602) ======================

test("UNIT: malformed params throw BridgeRpcError(-32602, \"invalid params: …\")", () => {
	const { provider } = makeRecordingProvider(true);
	const handler = makeShouldTriggerFileCompletionHandler({ getProvider: () => provider });
	const state = { handshakeComplete: true };

	const cases: Array<{ name: string; params: unknown }> = [
		{ name: "null", params: null },
		{ name: "not an object (string)", params: "hello" },
		{ name: "not an object (number)", params: 42 },
		{
			name: "lines not an array",
			params: { lines: "notarray", cursorLine: 0, cursorCol: 0 },
		},
		{
			name: "lines array with a non-string element",
			params: { lines: ["ok", 42], cursorLine: 0, cursorCol: 0 },
		},
		{
			name: "cursorLine a float",
			params: { lines: [""], cursorLine: 1.5, cursorCol: 0 },
		},
		{
			name: "cursorLine negative",
			params: { lines: [""], cursorLine: -1, cursorCol: 0 },
		},
		{
			name: "cursorLine a string",
			params: { lines: [""], cursorLine: "0", cursorCol: 0 },
		},
		{
			name: "cursorCol a float",
			params: { lines: [""], cursorLine: 0, cursorCol: 2.5 },
		},
		{
			name: "cursorCol negative",
			params: { lines: [""], cursorLine: 0, cursorCol: -3 },
		},
		{
			name: "cursorCol a string",
			params: { lines: [""], cursorLine: 0, cursorCol: "0" },
		},
		{
			name: "missing lines",
			params: { cursorLine: 0, cursorCol: 0 },
		},
		{
			name: "missing cursorLine",
			params: { lines: [""], cursorCol: 0 },
		},
	];

	for (const c of cases) {
		assert.throws(
			() => handler(c.params, state),
			(err: unknown) => {
				assert.ok(
					err instanceof BridgeRpcError,
					`[${c.name}] must throw BridgeRpcError, got ${(err as { constructor?: { name?: string } })?.constructor?.name}`,
				);
				const e = err as BridgeRpcError;
				assert.equal(e.code, -32602, `[${c.name}] code must be -32602`);
				assert.ok(
					e.message.startsWith("invalid params:"),
					`[${c.name}] message must start "invalid params:" (got "${e.message}")`,
				);
				return true;
			},
			`[${c.name}] expected a throw`,
		);
	}
});

test("UNIT: param validation happens BEFORE the provider is called (provider NOT touched)", () => {
	const { provider, getLastCall } = makeRecordingProvider(true);
	const handler = makeShouldTriggerFileCompletionHandler({ getProvider: () => provider });
	const state = { handshakeComplete: true };

	assert.throws(
		() => handler({ lines: "bad", cursorLine: 0, cursorCol: 0 }, state),
		(err: unknown) => err instanceof BridgeRpcError && (err as BridgeRpcError).code === -32602,
	);
	assert.equal(
		getLastCall(),
		undefined,
		"the provider's shouldTriggerFileCompletion must NOT run on a -32602 path",
	);
});

test("UNIT: provider-not-captured → throws BridgeRpcError(-32603, \"completion provider unavailable: …\")", () => {
	const handler = makeShouldTriggerFileCompletionHandler({
		getProvider: () => {
			throw new Error("not captured");
		},
	});
	const state = { handshakeComplete: true };
	// S15 wraps deps.getProvider() throwing into BridgeRpcError(-32603) at the handler edge
	// via toBridgeRpcError(e, "completion provider unavailable"). (The plain-Error stub stays;
	// the assertion changes — now a typed BridgeRpcError, not a raw Error to the safety net.)
	assert.throws(
		() =>
			handler(
				{ lines: ["/set"], cursorLine: 0, cursorCol: 4 },
				state,
			),
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

// === 2. DISPATCH (registerBridgeHandler + fakeSocket + handleLine) ============

test("DISPATCH: valid true (post-handshake) → success envelope {id,result:true}", async () => {
	registerBridgeHandler(
		"shouldTriggerFileCompletion",
		makeShouldTriggerFileCompletionHandler({
			getProvider: () => makeRecordingProvider(true).provider,
		}),
	);
	try {
		const { sock, writes } = fakeSocket();
		await handleLine(
			sock,
			{ handshakeComplete: true },
			JSON.stringify({
				jsonrpc: "2.0",
				id: "s1",
				method: "shouldTriggerFileCompletion",
				params: { lines: ["hello wor"], cursorLine: 0, cursorCol: 9 },
			}),
		);
		assert.deepEqual(parseResponses(writes), [
			{ jsonrpc: "2.0", id: "s1", result: true },
		]);
	} finally {
		__resetHandlersForTest();
	}
});

test("DISPATCH: valid false (post-handshake) → success envelope {id,result:false}", async () => {
	registerBridgeHandler(
		"shouldTriggerFileCompletion",
		makeShouldTriggerFileCompletionHandler({
			getProvider: () => makeRecordingProvider(false).provider,
		}),
	);
	try {
		const { sock, writes } = fakeSocket();
		await handleLine(
			sock,
			{ handshakeComplete: true },
			JSON.stringify({
				jsonrpc: "2.0",
				id: "s2",
				method: "shouldTriggerFileCompletion",
				params: { lines: ["/set"], cursorLine: 0, cursorCol: 4 },
			}),
		);
		assert.deepEqual(parseResponses(writes), [
			{ jsonrpc: "2.0", id: "s2", result: false },
		]);
	} finally {
		__resetHandlersForTest();
	}
});

test("DISPATCH: OPTIONAL-method ⇒ true (the dispatch path locks `?.` + `?? true`)", async () => {
	registerBridgeHandler(
		"shouldTriggerFileCompletion",
		makeShouldTriggerFileCompletionHandler({
			getProvider: () => makeProviderWithoutMethod(),
		}),
	);
	try {
		const { sock, writes } = fakeSocket();
		await handleLine(
			sock,
			{ handshakeComplete: true },
			JSON.stringify({
				jsonrpc: "2.0",
				id: "s3",
				method: "shouldTriggerFileCompletion",
				params: { lines: ["anything"], cursorLine: 0, cursorCol: 8 },
			}),
		);
		assert.deepEqual(parseResponses(writes), [
			{ jsonrpc: "2.0", id: "s3", result: true },
		]);
	} finally {
		__resetHandlersForTest();
	}
});

test("DISPATCH: invalid params → exactly one -32602 \"invalid params: …\" response", async () => {
	const { provider, getLastCall } = makeRecordingProvider(true);
	registerBridgeHandler(
		"shouldTriggerFileCompletion",
		makeShouldTriggerFileCompletionHandler({ getProvider: () => provider }),
	);
	try {
		const { sock, writes } = fakeSocket();
		await handleLine(
			sock,
			{ handshakeComplete: true },
			JSON.stringify({
				jsonrpc: "2.0",
				id: "s4",
				method: "shouldTriggerFileCompletion",
				params: { lines: "notarray", cursorLine: 0, cursorCol: 0 },
			}),
		);
		assert.equal(writes.length, 1, "exactly ONE response line");
		const r = parseResponses(writes)[0] as {
			id: string;
			error: { code: number; message: string };
		};
		assert.equal(r.id, "s4");
		assert.equal(r.error.code, -32602);
		assert.ok(r.error.message.startsWith("invalid params:"));
		assert.equal(getLastCall(), undefined, "the provider must NOT be called on invalid params");
	} finally {
		__resetHandlersForTest();
	}
});

test("DISPATCH: pre-handshake shouldTriggerFileCompletion → -32600 (S10 gate still wins; provider NOT called)", async () => {
	const { provider, getLastCall } = makeRecordingProvider(true);
	registerBridgeHandler(
		"shouldTriggerFileCompletion",
		makeShouldTriggerFileCompletionHandler({ getProvider: () => provider }),
	);
	try {
		const { sock, writes } = fakeSocket();
		await handleLine(
			sock,
			{ handshakeComplete: false },
			JSON.stringify({
				jsonrpc: "2.0",
				id: "s5",
				method: "shouldTriggerFileCompletion",
				params: { lines: ["hello"], cursorLine: 0, cursorCol: 5 },
			}),
		);
		assert.equal(writes.length, 1, "exactly ONE response line");
		const r = parseResponses(writes)[0] as {
			id: string;
			error: { code: number; message: string };
		};
		assert.equal(r.id, "s5");
		assert.equal(r.error.code, -32600, "the gate must fire before the handler");
		assert.equal(r.error.message, "handshake required: send hello first");
		assert.equal(
			getLastCall(),
			undefined,
			"the provider's shouldTriggerFileCompletion must NOT run pre-handshake",
		);
	} finally {
		__resetHandlersForTest();
	}
});

// === 3. REAL integration (ONE real Unix-socket pair; hello + shouldTriggerFileCompletion) ===

test("REAL: hello → shouldTriggerFileCompletion(\"/set\") ⇒ false; shouldTriggerFileCompletion(\"hello\") ⇒ true", async () => {
	registerBridgeHandler(
		"hello",
		makeHelloHandler({
			getToken: () => TOKEN,
			getCwd: () => "/tmp",
			getFdAvailable: () => true,
			version: BRIDGE_VERSION,
		}),
	);
	// A realistic mirror of pi's gate (autocomplete.ts:775): return false iff the text
	// before the cursor starts with "/" and has no space (a bare slash command like
	// "/set"); else true. This makes the wire round-trip illustrative.
	const stub: AutocompleteProvider = {
		getSuggestions: async () => null,
		applyCompletion: (lines, cl, cc) => ({ lines, cursorLine: cl, cursorCol: cc }),
		shouldTriggerFileCompletion: (lines, cl, cc) => {
			const before = (lines[cl] ?? "").slice(0, cc);
			return !(before.trim().startsWith("/") && !before.trim().includes(" "));
		},
	};
	registerBridgeHandler(
		"shouldTriggerFileCompletion",
		makeShouldTriggerFileCompletionHandler({ getProvider: () => stub }),
	);

	const sockpath = join(tmpdir(), `pi-editor-stfc-${randomUUID()}.sock`);
	const server = createServer((c) => onConnection(c));
	server.listen(sockpath);
	await once(server, "listening");
	try {
		const client = connect(sockpath);
		await once(client, "connect");

		// (1) hello (correct token) ⇒ HelloResult (gate opens)
		const rH = readFirstResponse(client);
		client.write(
			serializeJsonLine({ jsonrpc: "2.0", id: "h1", method: "hello", params: { token: TOKEN } }),
		);
		const hello = (await rH) as {
			id?: string;
			result?: { ok: boolean; serverVersion: string; cwd: string; fdAvailable: boolean };
		};
		assert.deepEqual(hello.result, {
			ok: true,
			serverVersion: BRIDGE_VERSION,
			cwd: "/tmp",
			fdAvailable: true,
		});

		// (2) shouldTriggerFileCompletion("/set") ⇒ false (bare slash command)
		const r1 = readFirstResponse(client);
		client.write(
			serializeJsonLine({
				jsonrpc: "2.0",
				id: "s1",
				method: "shouldTriggerFileCompletion",
				params: { lines: ["/set"], cursorLine: 0, cursorCol: 4 },
			}),
		);
		const got1 = (await r1) as { id: string; result: boolean };
		assert.equal(got1.id, "s1");
		assert.equal(got1.result, false);

		// (3) shouldTriggerFileCompletion("hello") ⇒ true (normal text)
		const r2 = readFirstResponse(client);
		client.write(
			serializeJsonLine({
				jsonrpc: "2.0",
				id: "s2",
				method: "shouldTriggerFileCompletion",
				params: { lines: ["hello"], cursorLine: 0, cursorCol: 5 },
			}),
		);
		const got2 = (await r2) as { id: string; result: boolean };
		assert.equal(got2.id, "s2");
		assert.equal(got2.result, true);

		client.destroy();
	} finally {
		__resetHandlersForTest();
		server.close();
	}
});

// === 4. TOKEN-NEVER-LEAKED sweep (PRD §12) =====================================

test("SECURITY: the TOKEN value never appears in any shouldTriggerFileCompletion response (PRD §12)", async () => {
	const { provider } = makeRecordingProvider(true);
	registerBridgeHandler(
		"shouldTriggerFileCompletion",
		makeShouldTriggerFileCompletionHandler({ getProvider: () => provider }),
	);
	try {
		const { sock, writes } = fakeSocket();
		await handleLine(
			sock,
			{ handshakeComplete: true },
			JSON.stringify({
				jsonrpc: "2.0",
				id: "s1",
				method: "shouldTriggerFileCompletion",
				params: { lines: ["hello"], cursorLine: 0, cursorCol: 5 },
			}),
		);
		for (const w of writes) {
			assert.ok(
				!w.includes(TOKEN),
				`token must not leak into a shouldTriggerFileCompletion response: ${w}`,
			);
		}
	} finally {
		__resetHandlersForTest();
	}
});
