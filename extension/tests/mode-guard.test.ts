import { test } from "node:test";
import assert from "node:assert/strict";
import type {
	ExtensionAPI,
	ExtensionContext,
	SessionStartEvent,
} from "@earendil-works/pi-coding-agent";
import bridgeFactory from "../pi-editor-bridge.ts";

// Type alias for the session_start handler signature (pi registers
// ExtensionHandler<SessionStartEvent> = (event, ctx) => void | ...).
type SessionStartHandler = (
	event: SessionStartEvent,
	ctx: ExtensionContext,
) => void;

// Run the factory with a fake `pi` that records the session_start handler.
function captureSessionStartHandler(): SessionStartHandler {
	let handler: SessionStartHandler | undefined;
	const fakePi = {
		on(event: string, h: SessionStartHandler) {
			if (event === "session_start") handler = h;
			// session_shutdown and any other registrations are ignored by this test.
		},
	} as unknown as ExtensionAPI;

	bridgeFactory(fakePi);

	assert.ok(
		typeof handler === "function",
		"default-export factory must register a session_start handler",
	);
	return handler!;
}

// Build a minimal ctx carrying only what the handler reads: .mode and .ui.
function makeCtx(
	mode: ExtensionContext["mode"],
	onAddAutocompleteProvider: () => void,
): ExtensionContext {
	return {
		mode,
		ui: { addAutocompleteProvider: onAddAutocompleteProvider },
	} as unknown as ExtensionContext;
}

const STARTUP_EVENT = { reason: "startup" } as SessionStartEvent;

test("session_start no-ops (does not call addAutocompleteProvider) in rpc/json/print modes", () => {
	const handler = captureSessionStartHandler();
	for (const mode of ["rpc", "json", "print"] as const) {
		let called = false;
		handler(STARTUP_EVENT, makeCtx(mode, () => {
			called = true;
		}));
		assert.equal(
			called,
			false,
			`addAutocompleteProvider must NOT be called in ${mode} mode (guard should short-circuit)`,
		);
	}
});

test("session_start proceeds (calls addAutocompleteProvider) in tui mode", () => {
	const handler = captureSessionStartHandler();
	let called = false;
	handler(STARTUP_EVENT, makeCtx("tui", () => {
		called = true;
	}));
	assert.equal(
		called,
		true,
		"addAutocompleteProvider MUST be called in tui mode (happy path through the handler)",
	);
});
