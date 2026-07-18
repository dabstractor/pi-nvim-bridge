/**
 * apply-completion-handler.test.ts — P1.M2.T6.S12 `applyCompletion` handler
 * (unit + dispatch + integration).
 *
 * S12 is the second completion-engine RPC handler. `makeApplyCompletionHandler` is a
 * deps-injected factory (mirrors S9's `makeHelloHandler` / S11's
 * `makeGetSuggestionsHandler`) that delegates to pi's LIVE
 * `AutocompleteProvider.applyCompletion` SYNCHRONOUSLY. pi's impl is a pure SYNC
 * function (autocomplete.ts:256-271, verified) — it takes NO options/AbortSignal/force
 * and returns the new {lines,cursorLine,cursorCol} directly (the TUI calls it WITHOUT
 * await — editor.ts:669/690/2257). So the S12 handler has NO AbortController, NO
 * supersession, NO timeout, NO closure state — it is the LEAN handler in the M2.T6
 * family (research §1.1, §3).
 *
 * `node:test` + `assert/strict` + jiti (NOT vitest — S11 research §5). Three layers:
 *  1. UNIT (factory directly with a stub provider; fresh ConnectionState): happy path,
 *     exact-arg threading, optional-description passthrough, sync return, param
 *     validation, provider-not-captured.
 *  2. DISPATCH (registerBridgeHandler + fakeSocket + handleLine, `{ handshakeComplete:
 *     true }` so the S10 gate opens): valid → success, invalid params → -32602,
 *     pre-handshake → -32600 (regression: the gate fires before the handler).
 *  3. REAL integration (ONE real Unix-socket pair; hello + applyCompletion registered):
 *     hello ⇒ HelloResult, applyCompletion("/m" + item model) ⇒ {lines:["/model "],
 *     cursorLine:0, cursorCol:7}.
 *
 * NOTE: `fakeSocket`/`parseResponses`/`readFirstResponse` are copied VERBATIM from
 * get-suggestions-handler.test.ts (they are LOCAL per-file helpers, NOT exported —
 * connection.test.ts / hello-handler.test.ts / handshake-gate.test.ts each re-declare
 * them identically).
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
	makeApplyCompletionHandler,
	makeHelloHandler,
	BRIDGE_VERSION,
} from "../pi-editor-bridge.ts";
import type { ApplyCompletionResult } from "../protocol.ts";
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
// is: applyCompletion(lines, cursorLine, cursorCol, item, prefix) => { lines, cursorLine,
// cursorCol } (SYNC); getSuggestions(...) => Promise<Suggestions|null> (unused by S12);
// shouldTriggerFileCompletion?(...) => boolean (unused by S12).

/** Recorded last call shape (so tests assert what the handler threaded to the provider). */
type RecordedCall = {
	lines: string[];
	cursorLine: number;
	cursorCol: number;
	item: AutocompleteItem;
	prefix: string;
};

/**
 * A stub provider that RECORDS the last call (lines/cursor/item/prefix) and returns a
 * fixed `result`. Use {@link getLastCall} to assert the handler threaded all five args
 * untouched. getSuggestions/shouldTriggerFileCompletion are unused by S12 (present only
 * to satisfy the interface type).
 */
function makeRecordingProvider(result: ApplyCompletionResult): {
	provider: AutocompleteProvider;
	getLastCall: () => RecordedCall | undefined;
} {
	let lastCall: RecordedCall | undefined;
	const provider: AutocompleteProvider = {
		getSuggestions: async () => null, // unused by S12; present for interface satisfaction
		applyCompletion: (
			lines: string[],
			cursorLine: number,
			cursorCol: number,
			item: AutocompleteItem,
			prefix: string,
		) => {
			lastCall = { lines, cursorLine, cursorCol, item, prefix };
			return result;
		},
		shouldTriggerFileCompletion: () => true,
	};
	return { provider, getLastCall: () => lastCall };
}

// === 1. UNIT (makeApplyCompletionHandler directly — stub provider) =============

test("UNIT: happy path → returns the provider's result verbatim (full buffer + cursor)", () => {
	const result: ApplyCompletionResult = { lines: ["/model "], cursorLine: 0, cursorCol: 7 };
	const { provider } = makeRecordingProvider(result);
	const handler = makeApplyCompletionHandler({ getProvider: () => provider });
	const got = handler(
		{ lines: ["/m"], cursorLine: 0, cursorCol: 2, item: { value: "model", label: "model" }, prefix: "/m" },
		{ handshakeComplete: true },
	);
	assert.deepEqual(got, result);
});

test("UNIT: exact-arg threading — all FIVE params forwarded to the provider UNTOUCHED", () => {
	const { provider, getLastCall } = makeRecordingProvider({
		lines: ["/model "],
		cursorLine: 0,
		cursorCol: 7,
	});
	const handler = makeApplyCompletionHandler({ getProvider: () => provider });
	const item = { value: "model", label: "model" };
	const r = handler(
		{ lines: ["/m"], cursorLine: 0, cursorCol: 2, item, prefix: "/m" },
		{ handshakeComplete: true },
	);
	assert.deepEqual(r, { lines: ["/model "], cursorLine: 0, cursorCol: 7 });
	// The provider received EXACTLY what the client sent — byte-for-byte.
	assert.deepEqual(getLastCall(), {
		lines: ["/m"],
		cursorLine: 0,
		cursorCol: 2,
		item,
		prefix: "/m",
	});
});

test("UNIT: item WITHOUT description is accepted (description is OPTIONAL)", () => {
	const { provider, getLastCall } = makeRecordingProvider({
		lines: ["/model "],
		cursorLine: 0,
		cursorCol: 7,
	});
	const handler = makeApplyCompletionHandler({ getProvider: () => provider });
	// No description — legal (AutocompleteItem.description is `?`).
	const r = handler(
		{ lines: ["/m"], cursorLine: 0, cursorCol: 2, item: { value: "model", label: "model" }, prefix: "/m" },
		{ handshakeComplete: true },
	);
	assert.deepEqual(r, { lines: ["/model "], cursorLine: 0, cursorCol: 7 });
	assert.equal(getLastCall()?.item.description, undefined);
});

test("UNIT: item WITH description is forwarded with description INTACT (pi ignores it; shape is legal)", () => {
	const { provider, getLastCall } = makeRecordingProvider({
		lines: ["@x.ts "],
		cursorLine: 0,
		cursorCol: 6,
	});
	const handler = makeApplyCompletionHandler({ getProvider: () => provider });
	const item: AutocompleteItem = { value: "x.ts", label: "x.ts", description: "src/x.ts" };
	const r = handler(
		{ lines: ["@x"], cursorLine: 0, cursorCol: 2, item, prefix: "@x" },
		{ handshakeComplete: true },
	);
	assert.deepEqual(r, { lines: ["@x.ts "], cursorLine: 0, cursorCol: 6 });
	assert.equal(getLastCall()?.item.description, "src/x.ts");
});

test("UNIT: sync return — the handler returns the stub's result object directly (no Promise wrap)", () => {
	const result: ApplyCompletionResult = { lines: ["/model "], cursorLine: 0, cursorCol: 7 };
	const { provider } = makeRecordingProvider(result);
	const handler = makeApplyCompletionHandler({ getProvider: () => provider });
	const r = handler(
		{ lines: ["/m"], cursorLine: 0, cursorCol: 2, item: { value: "model", label: "model" }, prefix: "/m" },
		{ handshakeComplete: true },
	);
	// A SYNC return: the handler yields the plain object, not a Promise of it.
	assert.deepEqual(r, result);
	assert.equal(
		r instanceof Promise,
		false,
		"the handler returns a plain object (sync), NOT a Promise",
	);
});

// === 1b. UNIT — PARAM VALIDATION (BridgeRpcError -32602) ======================

test("UNIT: malformed params throw BridgeRpcError(-32602, \"invalid params: …\")", () => {
	const { provider } = makeRecordingProvider({ lines: [], cursorLine: 0, cursorCol: 0 });
	const handler = makeApplyCompletionHandler({ getProvider: () => provider });
	const state = { handshakeComplete: true };

	const cases: Array<{ name: string; params: unknown }> = [
		{ name: "null", params: null },
		{ name: "not an object (string)", params: "hello" },
		{
			name: "lines not an array",
			params: { lines: "notarray", cursorLine: 0, cursorCol: 0, item: { value: "x", label: "x" }, prefix: "/" },
		},
		{
			name: "lines array with a non-string element",
			params: { lines: ["ok", 42], cursorLine: 0, cursorCol: 0, item: { value: "x", label: "x" }, prefix: "/" },
		},
		{
			name: "cursorLine a float",
			params: { lines: [""], cursorLine: 1.5, cursorCol: 0, item: { value: "x", label: "x" }, prefix: "/" },
		},
		{
			name: "cursorLine negative",
			params: { lines: [""], cursorLine: -1, cursorCol: 0, item: { value: "x", label: "x" }, prefix: "/" },
		},
		{
			name: "cursorLine a string",
			params: { lines: [""], cursorLine: "0", cursorCol: 0, item: { value: "x", label: "x" }, prefix: "/" },
		},
		{
			name: "cursorCol a float",
			params: { lines: [""], cursorLine: 0, cursorCol: 2.5, item: { value: "x", label: "x" }, prefix: "/" },
		},
		{
			name: "cursorCol negative",
			params: { lines: [""], cursorLine: 0, cursorCol: -3, item: { value: "x", label: "x" }, prefix: "/" },
		},
		{ name: "item missing value", params: { lines: [""], cursorLine: 0, cursorCol: 0, item: { label: "x" }, prefix: "/" } },
		{ name: "item missing label", params: { lines: [""], cursorLine: 0, cursorCol: 0, item: { value: "x" }, prefix: "/" } },
		{
			name: "item.value not a string",
			params: { lines: [""], cursorLine: 0, cursorCol: 0, item: { value: 42, label: "x" }, prefix: "/" },
		},
		{
			name: "item not an object (string)",
			params: { lines: [""], cursorLine: 0, cursorCol: 0, item: "notobj", prefix: "/" },
		},
		{
			name: "prefix not a string (number)",
			params: { lines: [""], cursorLine: 0, cursorCol: 0, item: { value: "x", label: "x" }, prefix: 42 },
		},
		{
			name: "missing lines",
			params: { cursorLine: 0, cursorCol: 0, item: { value: "x", label: "x" }, prefix: "/" },
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
	const { provider, getLastCall } = makeRecordingProvider({
		lines: [],
		cursorLine: 0,
		cursorCol: 0,
	});
	const handler = makeApplyCompletionHandler({ getProvider: () => provider });
	const state = { handshakeComplete: true };

	assert.throws(
		() => handler({ lines: "bad", cursorLine: 0, cursorCol: 0, item: { value: "x", label: "x" }, prefix: "/" }, state),
		(err: unknown) => err instanceof BridgeRpcError && (err as BridgeRpcError).code === -32602,
	);
	assert.equal(
		getLastCall(),
		undefined,
		"the provider's applyCompletion must NOT run on a -32602 path",
	);
});

test("UNIT: provider-not-captured → throws BridgeRpcError(-32603, \"completion provider unavailable: …\")", () => {
	const handler = makeApplyCompletionHandler({
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
				{ lines: ["/m"], cursorLine: 0, cursorCol: 2, item: { value: "model", label: "model" }, prefix: "/m" },
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

test("DISPATCH: valid applyCompletion (post-handshake) → success envelope {id,result}", async () => {
	registerBridgeHandler(
		"applyCompletion",
		makeApplyCompletionHandler({
			getProvider: () =>
				makeRecordingProvider({ lines: ["/model "], cursorLine: 0, cursorCol: 7 }).provider,
		}),
	);
	try {
		const { sock, writes } = fakeSocket();
		await handleLine(
			sock,
			{ handshakeComplete: true },
			JSON.stringify({
				jsonrpc: "2.0",
				id: "a1",
				method: "applyCompletion",
				params: { lines: ["/m"], cursorLine: 0, cursorCol: 2, item: { value: "model", label: "model" }, prefix: "/m" },
			}),
		);
		assert.deepEqual(parseResponses(writes), [
			{
				jsonrpc: "2.0",
				id: "a1",
				result: { lines: ["/model "], cursorLine: 0, cursorCol: 7 },
			},
		]);
	} finally {
		__resetHandlersForTest();
	}
});

test("DISPATCH: invalid params → exactly one -32602 \"invalid params: …\" response", async () => {
	const { provider, getLastCall } = makeRecordingProvider({
		lines: [],
		cursorLine: 0,
		cursorCol: 0,
	});
	registerBridgeHandler("applyCompletion", makeApplyCompletionHandler({ getProvider: () => provider }));
	try {
		const { sock, writes } = fakeSocket();
		await handleLine(
			sock,
			{ handshakeComplete: true },
			JSON.stringify({
				jsonrpc: "2.0",
				id: "a2",
				method: "applyCompletion",
				params: { lines: "notarray", cursorLine: 0, cursorCol: 0, item: { value: "x", label: "x" }, prefix: "/" },
			}),
		);
		assert.equal(writes.length, 1, "exactly ONE response line");
		const r = parseResponses(writes)[0] as {
			id: string;
			error: { code: number; message: string };
		};
		assert.equal(r.id, "a2");
		assert.equal(r.error.code, -32602);
		assert.ok(r.error.message.startsWith("invalid params:"));
		assert.equal(getLastCall(), undefined, "the provider must NOT be called on invalid params");
	} finally {
		__resetHandlersForTest();
	}
});

test("DISPATCH: pre-handshake applyCompletion → -32600 (S10 gate still wins; provider NOT called)", async () => {
	const { provider, getLastCall } = makeRecordingProvider({
		lines: ["/model "],
		cursorLine: 0,
		cursorCol: 7,
	});
	registerBridgeHandler("applyCompletion", makeApplyCompletionHandler({ getProvider: () => provider }));
	try {
		const { sock, writes } = fakeSocket();
		await handleLine(
			sock,
			{ handshakeComplete: false },
			JSON.stringify({
				jsonrpc: "2.0",
				id: "a3",
				method: "applyCompletion",
				params: { lines: ["/m"], cursorLine: 0, cursorCol: 2, item: { value: "model", label: "model" }, prefix: "/m" },
			}),
		);
		assert.equal(writes.length, 1, "exactly ONE response line");
		const r = parseResponses(writes)[0] as {
			id: string;
			error: { code: number; message: string };
		};
		assert.equal(r.id, "a3");
		assert.equal(r.error.code, -32600, "the gate must fire before the handler");
		assert.equal(r.error.message, "handshake required: send hello first");
		assert.equal(
			getLastCall(),
			undefined,
			"the provider's applyCompletion must NOT run pre-handshake",
		);
	} finally {
		__resetHandlersForTest();
	}
});

// === 3. REAL integration (ONE real Unix-socket pair; hello + applyCompletion) ===

test("REAL: hello → applyCompletion(\"/m\" + item model) ⇒ {lines:[\"/model \"],cursorLine:0,cursorCol:7}", async () => {
	// A stub provider whose applyCompletion mimics pi's slash-command insertion: replace the
	// prefix with `/<value> `, reposition the cursor after the trailing space. This is an
	// ILLUSTRATIVE mirror (pi's real impl is the source of truth) — it makes the wire
	// round-trip realistic.
	const stub: AutocompleteProvider = {
		getSuggestions: async () => null,
		applyCompletion: (lines, cl, cc, item, prefix) => {
			const line = lines[cl] ?? "";
			const before = line.slice(0, cc - prefix.length);
			const after = line.slice(cc);
			const newLine = `${before}/${item.value} ${after}`;
			const newLines = [...lines];
			newLines[cl] = newLine;
			return {
				lines: newLines,
				cursorLine: cl,
				cursorCol: before.length + item.value.length + 2,
			};
		},
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
		"applyCompletion",
		makeApplyCompletionHandler({ getProvider: () => stub }),
	);

	const sockpath = join(tmpdir(), `pi-editor-ac-${randomUUID()}.sock`);
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

		// (2) applyCompletion("/m" + item model) ⇒ {lines:["/model "],cursorLine:0,cursorCol:7}
		const rA = readFirstResponse(client);
		client.write(
			serializeJsonLine({
				jsonrpc: "2.0",
				id: "a1",
				method: "applyCompletion",
				params: { lines: ["/m"], cursorLine: 0, cursorCol: 2, item: { value: "model", label: "model" }, prefix: "/m" },
			}),
		);
		const got = (await rA) as {
			id: string;
			result: { lines: string[]; cursorLine: number; cursorCol: number };
		};
		assert.equal(got.id, "a1");
		assert.deepEqual(got.result, { lines: ["/model "], cursorLine: 0, cursorCol: 7 });

		client.destroy();
	} finally {
		__resetHandlersForTest();
		server.close();
	}
});

// === 4. TOKEN-NEVER-LEAKED sweep (PRD §12) =====================================

test("SECURITY: the TOKEN value never appears in any applyCompletion response (PRD §12)", async () => {
	const { provider } = makeRecordingProvider({ lines: ["/model "], cursorLine: 0, cursorCol: 7 });
	registerBridgeHandler("applyCompletion", makeApplyCompletionHandler({ getProvider: () => provider }));
	try {
		const { sock, writes } = fakeSocket();
		await handleLine(
			sock,
			{ handshakeComplete: true },
			JSON.stringify({
				jsonrpc: "2.0",
				id: "a1",
				method: "applyCompletion",
				params: { lines: ["/m"], cursorLine: 0, cursorCol: 2, item: { value: "model", label: "model" }, prefix: "/m" },
			}),
		);
		for (const w of writes) {
			assert.ok(!w.includes(TOKEN), `token must not leak into an applyCompletion response: ${w}`);
		}
	} finally {
		__resetHandlersForTest();
	}
});
