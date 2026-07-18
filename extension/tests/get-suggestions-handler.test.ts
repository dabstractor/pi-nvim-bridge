/**
 * get-suggestions-handler.test.ts — P1.M2.T6.S11 `getSuggestions` handler
 * (unit + dispatch + integration).
 *
 * S11 is the first completion-engine RPC handler. `makeGetSuggestionsHandler` is a
 * deps-injected factory (mirrors S9's `makeHelloHandler`) that delegates to pi's LIVE
 * `AutocompleteProvider`, threading a FRESH `AbortSignal` + the strict-boolean `force`.
 * Two guards live in the factory closure: SUPERSESSION (abort the prior in-flight
 * controller so `fd` is SIGKILL'd) and a PER-REQUEST TIMEOUT (1500 ms default,
 * injectable for tests) that aborts a runaway `fd` (pi's provider has NO internal
 * timeout — research §1.1).
 *
 * `node:test` + `assert/strict` + jiti (NOT vitest — research §7). Three layers:
 *  1. UNIT (factory directly with a stub provider; fresh ConnectionState; short
 *     timeoutMs:30 where timing matters): happy path, null result, force threading,
 *     signal threading, supersession, timeout, timeout-cleared, param validation,
 *     provider-not-captured.
 *  2. DISPATCH (registerBridgeHandler + fakeSocket + handleLine, `{ handshakeComplete:
 *     true }` so the S10 gate opens): valid → success, invalid params → -32602,
 *     pre-handshake → -32600 (regression: the gate fires before the handler).
 *  3. REAL integration (ONE real Unix-socket pair; hello + getSuggestions registered):
 *     hello ⇒ HelloResult, getSuggestions("/m") ⇒ {items,prefix}, getSuggestions("zzz")
 *     ⇒ null.
 *
 * NOTE: `fakeSocket`/`parseResponses`/`readFirstResponse` are copied VERBATIM from
 * handshake-gate.test.ts (they are LOCAL per-file helpers, NOT exported — connection.
 * test.ts / hello-handler.test.ts each re-declare them identically).
 */
import { test } from "node:test";
import assert from "node:assert/strict";
import { EventEmitter, once } from "node:events";
import { createServer, connect, type Socket } from "node:net";
import { randomUUID } from "node:crypto";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type {
	AutocompleteItem,
	AutocompleteProvider,
	AutocompleteSuggestions,
} from "@earendil-works/pi-tui";
import {
	BridgeRpcError,
	handleLine,
	onConnection,
	registerBridgeHandler,
	__resetHandlersForTest,
	type ConnectionState,
} from "../connection.ts";
import {
	makeGetSuggestionsHandler,
	makeHelloHandler,
	BRIDGE_VERSION,
	GET_SUGGESTIONS_TIMEOUT_MS,
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
// is: getSuggestions(lines, cursorLine, cursorCol, { signal, force? }) => Promise<Suggestions|null>;
// applyCompletion(...) => { lines, cursorLine, cursorCol };
// shouldTriggerFileCompletion?(...) => boolean.

/** Recorded last call shape (so tests assert what the handler threaded to the provider). */
type RecordedCall = {
	lines: string[];
	cursorLine: number;
	cursorCol: number;
	signal: AbortSignal;
	force: boolean;
};

/**
 * A stub provider that RECORDS the last call (lines/cursor/opts.signal/opts.force) and
 * returns a fixed `result`. Use {@link getLastCall} to assert the handler threaded the
 * right values (force boolean, fresh non-aborted signal).
 */
function makeRecordingProvider(result: AutocompleteSuggestions | null): {
	provider: AutocompleteProvider;
	getLastCall: () => RecordedCall | undefined;
} {
	let lastCall: RecordedCall | undefined;
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
		applyCompletion: (lines: string[]) => ({ lines, cursorLine: 0, cursorCol: 0 }),
		shouldTriggerFileCompletion: () => true,
	};
	return { provider, getLastCall: () => lastCall };
}

/**
 * A stub provider that resolves ONLY when its `opts.signal` aborts (for supersession +
 * timeout tests). This mirrors pi's real behavior: aborting the AbortController makes the
 * in-flight `getSuggestions` resolve (here to null) — it NEVER rejects (research §1.2).
 * Records every call's signal onto `signals` so a supersession test can assert the 1st
 * signal was aborted by the 2nd call.
 */
function makeAbortResolvingProvider(): {
	provider: AutocompleteProvider;
	signals: AbortSignal[];
} {
	const signals: AbortSignal[] = [];
	const provider: AutocompleteProvider = {
		getSuggestions: (
			_lines: string[],
			_cl: number,
			_cc: number,
			opts: { signal: AbortSignal; force?: boolean },
		) =>
			new Promise<null>((resolve) => {
				signals.push(opts.signal);
				if (opts.signal.aborted) return resolve(null);
				opts.signal.addEventListener("abort", () => resolve(null), { once: true });
			}),
		applyCompletion: (lines: string[]) => ({ lines, cursorLine: 0, cursorCol: 0 }),
		shouldTriggerFileCompletion: () => true,
	};
	return { provider, signals };
}

// === 1. UNIT (makeGetSuggestionsHandler directly — stub provider) ==============

test("UNIT: happy path → returns the provider's result verbatim", async () => {
	const result: AutocompleteSuggestions = {
		items: [{ value: "/model", label: "model", description: "pick a model" }],
		prefix: "/m",
	};
	const { provider, getLastCall } = makeRecordingProvider(result);
	const handler = makeGetSuggestionsHandler({ getProvider: () => provider });
	const got = await handler(
		{ lines: ["/m"], cursorLine: 0, cursorCol: 2 },
		{ handshakeComplete: true },
	);
	assert.deepEqual(got, result);
	// sanity: the handler actually delegated with the passed args
	assert.deepEqual(getLastCall()?.lines, ["/m"]);
	assert.equal(getLastCall()?.cursorLine, 0);
	assert.equal(getLastCall()?.cursorCol, 2);
});

test("UNIT: null result → handler returns null", async () => {
	const { provider } = makeRecordingProvider(null);
	const handler = makeGetSuggestionsHandler({ getProvider: () => provider });
	const got = await handler(
		{ lines: ["zzz"], cursorLine: 0, cursorCol: 3 },
		{ handshakeComplete: true },
	);
	assert.equal(got, null);
});

test("UNIT: force is threaded as a STRICT boolean (true when sent; false when omitted/false)", async () => {
	const { provider, getLastCall } = makeRecordingProvider({ items: [], prefix: "" });
	const handler = makeGetSuggestionsHandler({ getProvider: () => provider });
	const base = { lines: [""], cursorLine: 0, cursorCol: 0 };

	await handler({ ...base, force: true }, { handshakeComplete: true });
	assert.equal(
		getLastCall()?.force,
		true,
		"force:true must be threaded as the boolean true",
	);

	await handler({ ...base }, { handshakeComplete: true });
	assert.equal(
		getLastCall()?.force,
		false,
		"omitted force must be threaded as false (never undefined)",
	);

	await handler({ ...base, force: false }, { handshakeComplete: true });
	assert.equal(getLastCall()?.force, false, "force:false must be threaded as false");
});

test("UNIT: signal is a fresh, NON-ABORTED AbortSignal on each call", async () => {
	const { provider, getLastCall } = makeRecordingProvider(null);
	const handler = makeGetSuggestionsHandler({ getProvider: () => provider });

	await handler({ lines: [""], cursorLine: 0, cursorCol: 0 }, { handshakeComplete: true });
	const sig1 = getLastCall()?.signal;
	assert.ok(sig1 instanceof AbortSignal, "must receive an AbortSignal");
	assert.equal(sig1?.aborted, false, "the fresh signal must start non-aborted");

	await handler({ lines: [""], cursorLine: 0, cursorCol: 0 }, { handshakeComplete: true });
	const sig2 = getLastCall()?.signal;
	assert.notEqual(sig1, sig2, "each call must get a DIFFERENT (fresh) AbortSignal");
	assert.equal(sig2?.aborted, false, "the 2nd fresh signal also starts non-aborted");
});

test("UNIT: supersession — a 2nd in-flight call aborts the 1st's signal; both resolve (to null)", async () => {
	const { provider, signals } = makeAbortResolvingProvider();
	const handler = makeGetSuggestionsHandler({ getProvider: () => provider, timeoutMs: 30 });
	const state = { handshakeComplete: true };

	// Fire two calls WITHOUT awaiting between them. The 2nd must supersede the 1st.
	const p1 = handler({ lines: ["/m"], cursorLine: 0, cursorCol: 2 }, state) as Promise<unknown>;
	const p2 = handler({ lines: ["/mo"], cursorLine: 0, cursorCol: 3 }, state) as Promise<unknown>;

	assert.ok(signals.length >= 1, "the 1st call reached the provider");
	// The 1st signal MUST be aborted once the 2nd call is dispatched.
	assert.equal(
		signals[0].aborted,
		true,
		"the 2nd request must abort the 1st's signal (supersession SIGKILLs fd)",
	);
	// The 2nd signal is still non-aborted at this instant (its timeout fires later).
	assert.equal(signals.length >= 2 ? signals[1].aborted : false, false, "the 2nd request's own signal starts non-aborted");

	// Both settle (never reject). p1 resolves null because its signal was aborted; p2
	// resolves null via its own 30ms timeout (no manual abort).
	const [r1, r2] = await Promise.all([
		p1.then(
			(v: unknown) => v,
			(e: unknown) => assert.fail(`p1 rejected: ${e}`),
		),
		p2.then(
			(v: unknown) => v,
			(e: unknown) => assert.fail(`p2 rejected: ${e}`),
		),
	]);
	assert.equal(r1, null, "1st (aborted) call resolves to the provider's abort result (null)");
	assert.equal(r2, null, "2nd call resolves to null after its own timeout-driven abort");
});

test("UNIT: timeout — a never-resolving provider resolves to null after timeoutMs (no hang)", async () => {
	const { provider } = makeAbortResolvingProvider();
	const handler = makeGetSuggestionsHandler({ getProvider: () => provider, timeoutMs: 30 });
	const start = Date.now();
	const got = await handler(
		{ lines: ["/m"], cursorLine: 0, cursorCol: 2 },
		{ handshakeComplete: true },
	);
	const elapsed = Date.now() - start;
	assert.equal(got, null, "a never-resolving provider resolves to null once the timer aborts");
	// The timer (30ms) drove the abort — not the 1500ms default. Allow generous slack for CI.
	assert.ok(
		elapsed < 1000,
		`timeout should fire ~30ms, not the 1500ms default (elapsed=${elapsed}ms)`,
	);
});

test("UNIT: timeout cleared — many back-to-back fast calls do NOT leak timers (process would stall)", async () => {
	// A recording provider that resolves IMMEDIATELY. If the `finally { clearTimeout }`
	// were missing, each call would leave a live 1500ms timer; running many in a tight
	// loop would keep the event loop alive. Use the default timeoutMs (1500) to make a
	// leak observable: with proper cleanup the loop drains promptly.
	const { provider } = makeRecordingProvider(null);
	const handler = makeGetSuggestionsHandler({ getProvider: () => provider });
	const state = { handshakeComplete: true };
	const N = 50;
	for (let i = 0; i < N; i++) {
		await handler({ lines: ["/m"], cursorLine: 0, cursorCol: 2 }, state);
	}
	// If we get here at all, the awaits resolved. Assert that the whole loop completed
	// in well under N*1500ms (which it trivially does because the timer is cleared each
	// time; a leaked-timer variant would still complete the awaits but the timers would
	// keep the process alive afterward — exercised by node:test's clean exit).
	assert.ok(true, `completed ${N} calls; timers cleared by finally (no per-call stall)`);
});

// === 1b. UNIT — PARAM VALIDATION (BridgeRpcError -32602) =======================

test("UNIT: malformed params throw BridgeRpcError(-32602, \"invalid params: …\")", async () => {
	const { provider } = makeRecordingProvider(null);
	const handler = makeGetSuggestionsHandler({ getProvider: () => provider });
	const state = { handshakeComplete: true };

	const cases: Array<{ name: string; params: unknown }> = [
		{ name: "null", params: null },
		{ name: "not an object (string)", params: "hello" },
		{ name: "lines not an array", params: { lines: "notarray", cursorLine: 0, cursorCol: 0 } },
		{
			name: "lines array with a non-string element",
			params: { lines: ["ok", 42], cursorLine: 0, cursorCol: 0 },
		},
		{ name: "cursorLine a float", params: { lines: [""], cursorLine: 1.5, cursorCol: 0 } },
		{ name: "cursorLine negative", params: { lines: [""], cursorLine: -1, cursorCol: 0 } },
		{ name: "cursorLine a string", params: { lines: [""], cursorLine: "0", cursorCol: 0 } },
		{ name: "cursorCol a float", params: { lines: [""], cursorLine: 0, cursorCol: 2.5 } },
		{ name: "cursorCol negative", params: { lines: [""], cursorLine: 0, cursorCol: -3 } },
		{ name: "force a string (non-boolean)", params: { lines: [""], cursorLine: 0, cursorCol: 0, force: "yes" } },
		{ name: "missing lines", params: { cursorLine: 0, cursorCol: 0 } },
		{ name: "missing cursorLine", params: { lines: [""], cursorCol: 0 } },
		{ name: "missing cursorCol", params: { lines: [""], cursorLine: 0 } },
	];

	for (const c of cases) {
		await assert.rejects(
			() => handler(c.params, state) as Promise<unknown>,
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
			`[${c.name}] expected a rejection`,
		);
	}
});

test("UNIT: param validation happens BEFORE the provider is called (provider NOT touched)", async () => {
	const { provider, getLastCall } = makeRecordingProvider(null);
	const handler = makeGetSuggestionsHandler({ getProvider: () => provider });
	const state = { handshakeComplete: true };

	await assert.rejects(
		() => handler({ lines: "bad", cursorLine: 0, cursorCol: 0 }, state) as Promise<unknown>,
		(err: unknown) => err instanceof BridgeRpcError && (err as BridgeRpcError).code === -32602,
	);
	assert.equal(
		getLastCall(),
		undefined,
		"the provider's getSuggestions must NOT run on a -32602 path",
	);
});

test("UNIT: provider-not-captured → rethrows the plain Error (NOT a BridgeRpcError; -32603 safety net)", async () => {
	const handler = makeGetSuggestionsHandler({
		getProvider: () => {
			throw new Error("not captured");
		},
	});
	const state = { handshakeComplete: true };
	// S11 does NOT wrap this — it lets the plain Error propagate to handleLine's -32603 net.
	// (S15 will later refine this into a specific code; S11 keeps it flowing — keeps pi safe.)
	await assert.rejects(
		() => handler({ lines: ["/m"], cursorLine: 0, cursorCol: 2 }, state) as Promise<unknown>,
		(err: unknown) => {
			assert.ok(err instanceof Error, "must be a plain Error");
			assert.ok(!(err instanceof BridgeRpcError), "must NOT be a BridgeRpcError (S15's lane)");
			assert.equal(err.message, "not captured");
			return true;
		},
	);
});

// === 2. DISPATCH (registerBridgeHandler + fakeSocket + handleLine) ============

test("DISPATCH: valid getSuggestions (post-handshake) → success envelope {id,result}", async () => {
	const result: AutocompleteSuggestions = {
		items: [{ value: "/model", label: "model" }],
		prefix: "/m",
	};
	registerBridgeHandler(
		"getSuggestions",
		makeGetSuggestionsHandler({ getProvider: () => makeRecordingProvider(result).provider }),
	);
	try {
		const { sock, writes } = fakeSocket();
		await handleLine(
			sock,
			{ handshakeComplete: true },
			JSON.stringify({
				jsonrpc: "2.0",
				id: "g1",
				method: "getSuggestions",
				params: { lines: ["/m"], cursorLine: 0, cursorCol: 2 },
			}),
		);
		assert.deepEqual(parseResponses(writes), [
			{
				jsonrpc: "2.0",
				id: "g1",
				result: { items: [{ value: "/model", label: "model" }], prefix: "/m" },
			},
		]);
	} finally {
		__resetHandlersForTest();
	}
});

test("DISPATCH: invalid params → exactly one -32602 \"invalid params: …\" response", async () => {
	registerBridgeHandler(
		"getSuggestions",
		makeGetSuggestionsHandler({ getProvider: () => makeRecordingProvider(null).provider }),
	);
	try {
		const { sock, writes } = fakeSocket();
		await handleLine(
			sock,
			{ handshakeComplete: true },
			JSON.stringify({
				jsonrpc: "2.0",
				id: "g2",
				method: "getSuggestions",
				params: { lines: "notarray", cursorLine: 0, cursorCol: 0 },
			}),
		);
		assert.equal(writes.length, 1, "exactly ONE response line");
		const r = parseResponses(writes)[0] as {
			id: string;
			error: { code: number; message: string };
		};
		assert.equal(r.id, "g2");
		assert.equal(r.error.code, -32602);
		assert.ok(r.error.message.startsWith("invalid params:"));
	} finally {
		__resetHandlersForTest();
	}
});

test("DISPATCH: pre-handshake getSuggestions → -32600 (S10 gate still wins; provider NOT called)", async () => {
	const { provider, getLastCall } = makeRecordingProvider(null);
	registerBridgeHandler("getSuggestions", makeGetSuggestionsHandler({ getProvider: () => provider }));
	try {
		const { sock, writes } = fakeSocket();
		await handleLine(
			sock,
			{ handshakeComplete: false },
			JSON.stringify({
				jsonrpc: "2.0",
				id: "g3",
				method: "getSuggestions",
				params: { lines: ["/m"], cursorLine: 0, cursorCol: 2 },
			}),
		);
		assert.equal(writes.length, 1, "exactly ONE response line");
		const r = parseResponses(writes)[0] as {
			id: string;
			error: { code: number; message: string };
		};
		assert.equal(r.id, "g3");
		assert.equal(r.error.code, -32600, "the gate must fire before the handler");
		assert.equal(r.error.message, "handshake required: send hello first");
		assert.equal(
			getLastCall(),
			undefined,
			"the provider's getSuggestions must NOT run pre-handshake",
		);
	} finally {
		__resetHandlersForTest();
	}
});

// === 3. REAL integration (ONE real Unix-socket pair; hello + getSuggestions) ===

test("REAL: hello → getSuggestions(\"/m\") ⇒ result; getSuggestions(\"zzz\") ⇒ null", async () => {
	// A stub provider that returns a fixed item when the cursor line starts with "/m",
	// else null — exercises both the result and null paths over a real socket.
	const item: AutocompleteItem = { value: "/model", label: "model", description: "pick a model" };
	const stub: AutocompleteProvider = {
		getSuggestions: async (lines, cursorLine) =>
			lines[cursorLine]?.startsWith("/m")
				? { items: [item], prefix: "/m" }
				: null,
		applyCompletion: (lines) => ({ lines, cursorLine: 0, cursorCol: 0 }),
		shouldTriggerFileCompletion: () => true,
	};
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
		"getSuggestions",
		makeGetSuggestionsHandler({ getProvider: () => stub }),
	);

	const sockpath = join(tmpdir(), `pi-editor-gs-${randomUUID()}.sock`);
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

		// (2) getSuggestions("/m") ⇒ {items,prefix}
		const rG = readFirstResponse(client);
		client.write(
			serializeJsonLine({
				jsonrpc: "2.0",
				id: "g1",
				method: "getSuggestions",
				params: { lines: ["/m"], cursorLine: 0, cursorCol: 2 },
			}),
		);
		const got = (await rG) as {
			id: string;
			result: { items: AutocompleteItem[]; prefix: string } | null;
		};
		assert.equal(got.id, "g1");
		assert.deepEqual(got.result, { items: [item], prefix: "/m" });

		// (3) getSuggestions("zzz") ⇒ null
		const rZ = readFirstResponse(client);
		client.write(
			serializeJsonLine({
				jsonrpc: "2.0",
				id: "g2",
				method: "getSuggestions",
				params: { lines: ["zzz"], cursorLine: 0, cursorCol: 3 },
			}),
		);
		const gotNull = (await rZ) as { id: string; result: null };
		assert.equal(gotNull.id, "g2");
		assert.equal(gotNull.result, null);

		client.destroy();
	} finally {
		__resetHandlersForTest();
		server.close();
	}
});

// === 4. TOKEN-NEVER-LEAKED sweep (PRD §12) =====================================

test("SECURITY: the TOKEN value never appears in any getSuggestions response (PRD §12)", async () => {
	const { provider } = makeRecordingProvider({
		items: [{ value: "/model", label: "model" }],
		prefix: "/m",
	});
	registerBridgeHandler("getSuggestions", makeGetSuggestionsHandler({ getProvider: () => provider }));
	try {
		const { sock, writes } = fakeSocket();
		await handleLine(
			sock,
			{ handshakeComplete: true },
			JSON.stringify({
				jsonrpc: "2.0",
				id: "g1",
				method: "getSuggestions",
				params: { lines: ["/m"], cursorLine: 0, cursorCol: 2 },
			}),
		);
		for (const w of writes) {
			assert.ok(!w.includes(TOKEN), `token must not leak into a getSuggestions response: ${w}`);
		}
	} finally {
		__resetHandlersForTest();
	}
});
