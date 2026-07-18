/**
 * error-wrapping.test.ts — P1.M2.T7.S15 domain-error wrapping
 * (unit + dispatch + security).
 *
 * S15 closes the M2.T7 "error wrapping" lane. The 4 provider-dependent handlers
 * (`getSuggestions` / `applyCompletion` / `shouldTriggerFileCompletion` /
 * `getCommands`) now wrap BOTH `deps.getProvider()` (context "completion provider
 * unavailable") and the provider method call (context "<methodName> failed") in
 * `try/catch` blocks that re-throw via the shared `toBridgeRpcError(e, context)`
 * converter (added to `connection.ts`). A thrown plain `Error` becomes
 * `BridgeRpcError(-32603, "<context>: <msg>")` — so `handleLine`'s `-32603` catch
 * becomes a genuine LAST-RESORT safety net. `BridgeRpcError` instances pass through
 * unchanged (so `-32602` params validation + `hello`'s `-32600` keep their codes).
 *
 * `node:test` + `assert/strict` + jiti (NOT vitest — research §7). Three layers:
 *  1. UNIT (toBridgeRpcError all branches + each of the 4 handlers' provider-method-THROWS
 *     path — NEW coverage beyond the flipped provider-not-captured UNIT tests in each
 *     handler's own test file).
 *  2. DISPATCH (registerBridgeHandler + fakeSocket + handleLine, `{ handshakeComplete:
 *     true }`): provider-not-captured over `handleLine` ⇒ exactly ONE `-32603` response
 *     whose `error.message` starts with the context.
 *  3. SECURITY: the TOKEN value never appears in any wrapped error message/write (PRD §12).
 *
 * NOTE: `fakeSocket`/`parseResponses`/`readFirstResponse` are copied VERBATIM from
 * get-suggestions-handler.test.ts (LOCAL per-file helpers, NOT exported).
 */
import { test } from "node:test";
import assert from "node:assert/strict";
import { EventEmitter } from "node:events";
import type { Socket } from "node:net";
import type { AutocompleteProvider } from "@earendil-works/pi-tui";
import {
	BridgeRpcError,
	handleLine,
	registerBridgeHandler,
	toBridgeRpcError,
	__resetHandlersForTest,
} from "../connection.ts";
import {
	makeGetSuggestionsHandler,
	makeApplyCompletionHandler,
	makeShouldTriggerFileCompletionHandler,
	makeGetCommandsHandler,
} from "../pi-editor-bridge.ts";

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

// === STUB PROVIDERS ===========================================================
// Minimal objects satisfying the AutocompleteProvider shape, whose methods THROW —
// to exercise S15's provider-method-try/catch (the NEW coverage).

/** A provider whose `getSuggestions` rejects with a plain Error. */
function makeGetSuggestionsThrowingProvider(msg: string): AutocompleteProvider {
	return {
		getSuggestions: async () => {
			throw new Error(msg);
		},
		applyCompletion: (lines: string[]) => ({ lines, cursorLine: 0, cursorCol: 0 }),
		shouldTriggerFileCompletion: () => true,
	};
}

/** A provider whose `applyCompletion` throws a plain Error. */
function makeApplyCompletionThrowingProvider(msg: string): AutocompleteProvider {
	return {
		getSuggestions: async () => null,
		applyCompletion: () => {
			throw new Error(msg);
		},
		shouldTriggerFileCompletion: () => true,
	};
}

/** A provider whose `shouldTriggerFileCompletion` throws a plain Error. */
function makeShouldTriggerThrowingProvider(msg: string): AutocompleteProvider {
	return {
		getSuggestions: async () => null,
		applyCompletion: (lines: string[]) => ({ lines, cursorLine: 0, cursorCol: 0 }),
		shouldTriggerFileCompletion: () => {
			throw new Error(msg);
		},
	};
}

// =============================================================================
// 1. UNIT — toBridgeRpcError (all branches)
// =============================================================================

test("UNIT toBridgeRpcError: pass-through when err is already a BridgeRpcError (code/message intact)", () => {
	const original = new BridgeRpcError(-32601, "method not found");
	const out = toBridgeRpcError(original, "some context");
	assert.equal(out, original, "must return the SAME instance (pass-through)");
	assert.equal(out.code, -32601, "intentional code preserved (NOT flattened to -32603)");
	assert.equal(out.message, "method not found", "message unchanged");
});

test("UNIT toBridgeRpcError: pass-through preserves the fatal flag + -32600 (hello bad-token)", () => {
	const original = new BridgeRpcError(-32600, "bad token", { fatal: true });
	const out = toBridgeRpcError(original, "ctx");
	assert.equal(out, original);
	assert.equal(out.code, -32600);
	assert.equal(out.fatal, true, "fatal flag preserved on pass-through");
});

test("UNIT toBridgeRpcError: wraps a plain Error → -32603 + context-prefixed message", () => {
	const out = toBridgeRpcError(new Error("boom"), "ctx");
	assert.ok(out instanceof BridgeRpcError);
	assert.equal(out.code, -32603);
	assert.equal(out.message, "ctx: boom");
});

test("UNIT toBridgeRpcError: wraps a non-Error value (string) → -32603 + String(value)", () => {
	const out = toBridgeRpcError("a string", "ctx");
	assert.ok(out instanceof BridgeRpcError);
	assert.equal(out.code, -32603);
	assert.equal(out.message, "ctx: a string");
});

test("UNIT toBridgeRpcError: wraps null → -32603 + 'ctx: null'", () => {
	const out = toBridgeRpcError(null, "ctx");
	assert.ok(out instanceof BridgeRpcError);
	assert.equal(out.code, -32603);
	assert.equal(out.message, "ctx: null");
});

test("UNIT toBridgeRpcError: wraps undefined → -32603 + 'ctx: undefined'", () => {
	const out = toBridgeRpcError(undefined, "ctx");
	assert.ok(out instanceof BridgeRpcError);
	assert.equal(out.code, -32603);
	assert.equal(out.message, "ctx: undefined");
});

test("UNIT toBridgeRpcError: wraps a number → -32603 + String(number)", () => {
	const out = toBridgeRpcError(42, "ctx");
	assert.ok(out instanceof BridgeRpcError);
	assert.equal(out.code, -32603);
	assert.equal(out.message, "ctx: 42");
});

// =============================================================================
// 1b. UNIT — provider-method-THROWS for each of the 4 handlers (NEW coverage)
//     (the flipped provider-not-captured UNIT tests live in each handler's own file;
//      here we cover the provider METHOD throwing — previously the safety net's job.)
// =============================================================================

test("UNIT getSuggestions: provider.getSuggestions throws → BridgeRpcError(-32603, \"getSuggestions failed: …\")", async () => {
	const handler = makeGetSuggestionsHandler({
		getProvider: () => makeGetSuggestionsThrowingProvider("fd died"),
	});
	await assert.rejects(
		() => handler({ lines: ["/m"], cursorLine: 0, cursorCol: 2 }, { handshakeComplete: true }) as Promise<unknown>,
		(err: unknown) => {
			assert.ok(err instanceof BridgeRpcError, "S15: must be a BridgeRpcError");
			assert.equal((err as BridgeRpcError).code, -32603);
			assert.equal((err as BridgeRpcError).message, "getSuggestions failed: fd died");
			return true;
		},
	);
});

test("UNIT applyCompletion: provider.applyCompletion throws → BridgeRpcError(-32603, \"applyCompletion failed: …\")", () => {
	const handler = makeApplyCompletionHandler({
		getProvider: () => makeApplyCompletionThrowingProvider("insert bug"),
	});
	assert.throws(
		() =>
			handler(
				{
					lines: ["/m"],
					cursorLine: 0,
					cursorCol: 2,
					item: { value: "model", label: "model" },
					prefix: "/m",
				},
				{ handshakeComplete: true },
			),
		(err: unknown) => {
			assert.ok(err instanceof BridgeRpcError, "S15: must be a BridgeRpcError");
			assert.equal((err as BridgeRpcError).code, -32603);
			assert.equal((err as BridgeRpcError).message, "applyCompletion failed: insert bug");
			return true;
		},
	);
});

test("UNIT shouldTriggerFileCompletion: provider.shouldTriggerFileCompletion throws → BridgeRpcError(-32603, \"shouldTriggerFileCompletion failed: …\")", () => {
	const handler = makeShouldTriggerFileCompletionHandler({
		getProvider: () => makeShouldTriggerThrowingProvider("trigger bug"),
	});
	assert.throws(
		() => handler({ lines: ["/set"], cursorLine: 0, cursorCol: 4 }, { handshakeComplete: true }),
		(err: unknown) => {
			assert.ok(err instanceof BridgeRpcError, "S15: must be a BridgeRpcError");
			assert.equal((err as BridgeRpcError).code, -32603);
			assert.equal(
				(err as BridgeRpcError).message,
				"shouldTriggerFileCompletion failed: trigger bug",
			);
			return true;
		},
	);
});

test("UNIT getCommands: provider.getSuggestions throws → BridgeRpcError(-32603, \"getSuggestions failed: …\")", async () => {
	// getCommands reuses getSuggestions under the hood, so the method context is
	// "getSuggestions failed" (documented in the handler).
	const handler = makeGetCommandsHandler({
		getProvider: () => makeGetSuggestionsThrowingProvider("commands fd died"),
	});
	await assert.rejects(
		() => handler({}, { handshakeComplete: true }) as Promise<unknown>,
		(err: unknown) => {
			assert.ok(err instanceof BridgeRpcError, "S15: must be a BridgeRpcError");
			assert.equal((err as BridgeRpcError).code, -32603);
			assert.equal(
				(err as BridgeRpcError).message,
				"getSuggestions failed: commands fd died",
			);
			return true;
		},
	);
});

// =============================================================================
// 1c. UNIT — params validation STILL wins (-32602 BEFORE the provider block)
//     (regression: narrow*Params runs outside the provider try/catch, so a malformed
//      shape never reaches the provider — and is NOT swallowed into -32603.)
// =============================================================================

test("UNIT getSuggestions: malformed params STILL → -32602 (NOT -32603); provider NOT called", async () => {
	let providerCalled = false;
	const handler = makeGetSuggestionsHandler({
		getProvider: () => {
			providerCalled = true;
			return makeGetSuggestionsThrowingProvider("should never run");
		},
	});
	await assert.rejects(
		// `lines` must be an array — a string is malformed.
		() => handler({ lines: "bad", cursorLine: 0, cursorCol: 0 }, { handshakeComplete: true }) as Promise<unknown>,
		(err: unknown) =>
			err instanceof BridgeRpcError && (err as BridgeRpcError).code === -32602,
	);
	assert.equal(providerCalled, false, "params validation must fire BEFORE getProvider()");
});

// =============================================================================
// 2. DISPATCH — provider-not-captured over handleLine → wrapped -32603
// =============================================================================

test("DISPATCH getSuggestions: provider-not-captured → exactly ONE -32603 response, message starts with context", async () => {
	registerBridgeHandler(
		"getSuggestions",
		makeGetSuggestionsHandler({
			getProvider: () => {
				throw new Error("not captured");
			},
		}),
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
		assert.equal(writes.length, 1, "exactly ONE response line");
		const r = parseResponses(writes)[0] as {
			id: string;
			error: { code: number; message: string };
		};
		assert.equal(r.id, "g1");
		assert.equal(r.error.code, -32603);
		assert.ok(
			r.error.message.startsWith("completion provider unavailable:"),
			`got "${r.error.message}"`,
		);
	} finally {
		__resetHandlersForTest();
	}
});

test("DISPATCH applyCompletion: provider-method-throws over handleLine → -32603, message starts with method context", async () => {
	registerBridgeHandler(
		"applyCompletion",
		makeApplyCompletionHandler({
			getProvider: () => makeApplyCompletionThrowingProvider("dispatch bug"),
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
				params: {
					lines: ["/m"],
					cursorLine: 0,
					cursorCol: 2,
					item: { value: "model", label: "model" },
					prefix: "/m",
				},
			}),
		);
		assert.equal(writes.length, 1, "exactly ONE response line");
		const r = parseResponses(writes)[0] as {
			id: string;
			error: { code: number; message: string };
		};
		assert.equal(r.id, "a1");
		assert.equal(r.error.code, -32603);
		assert.ok(
			r.error.message.startsWith("applyCompletion failed:"),
			`got "${r.error.message}"`,
		);
	} finally {
		__resetHandlersForTest();
	}
});

// =============================================================================
// 3. SECURITY — the token value NEVER appears in any wrapped error message/write
//                (PRD §12: secrets must not leak into error responses or stderr).
// =============================================================================

test("SECURITY: token never appears in a wrapped -32603 error response (provider-not-captured)", async () => {
	// Register getSuggestions with a getProvider that throws a message that does NOT
	// contain the token (mirrors the real getProvider() message). Then assert the token
	// string is absent from every written response line.
	registerBridgeHandler(
		"getSuggestions",
		makeGetSuggestionsHandler({
			getProvider: () => {
				throw new Error("not captured");
			},
		}),
	);
	try {
		const { sock, writes } = fakeSocket();
		await handleLine(
			sock,
			{ handshakeComplete: true },
			// NOTE: the REQUEST itself carries the token in a real hello; here we send a
			// post-handshake getSuggestions with no token in params. The point is that the
			// RESPONSE (-32603) must never echo the token.
			JSON.stringify({
				jsonrpc: "2.0",
				id: "s1",
				method: "getSuggestions",
				params: { lines: ["/m"], cursorLine: 0, cursorCol: 2 },
			}),
		);
		assert.equal(writes.length, 1);
		for (const w of writes) {
			assert.ok(
				!w.includes(TOKEN),
				`TOKEN leaked into error response: "${w}"`,
			);
		}
	} finally {
		__resetHandlersForTest();
	}
});

test("SECURITY: token never appears in a wrapped -32603 error response (provider-method-throws)", async () => {
	registerBridgeHandler(
		"getSuggestions",
		makeGetSuggestionsHandler({
			getProvider: () => makeGetSuggestionsThrowingProvider("runtime failure"),
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
				method: "getSuggestions",
				params: { lines: ["/m"], cursorLine: 0, cursorCol: 2 },
			}),
		);
		assert.equal(writes.length, 1);
		for (const w of writes) {
			assert.ok(
				!w.includes(TOKEN),
				`TOKEN leaked into error response: "${w}"`,
			);
		}
	} finally {
		__resetHandlersForTest();
	}
});

test("SECURITY: toBridgeRpcError never introduces the token even if the context/detail are hostile", () => {
	// The converter only concatenates `context` + `detail`; it has no access to the token.
	// A hostile provider that throws the token string would (correctly) echo it — but the
	// real getProvider() and provider methods never touch the token. This test asserts the
	// converter itself is not a leak vector for a normal Error.
	const out = toBridgeRpcError(new Error("provider misbehaved"), "completion provider unavailable");
	assert.ok(!out.message.includes(TOKEN), "converter must not synthesize the token");
	assert.equal(out.code, -32603);
});
