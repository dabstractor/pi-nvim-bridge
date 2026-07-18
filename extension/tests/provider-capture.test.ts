import { test } from "node:test";
import assert from "node:assert/strict";
import type { AutocompleteProvider } from "@earendil-works/pi-tui";
import type { ExtensionContext } from "@earendil-works/pi-coding-agent";
import { captureProvider, getProvider } from "../pi-editor-bridge.ts";

// Build a sentinel object satisfying the AutocompleteProvider shape. Methods are
// stubs — the pass-through test only checks IDENTITY, never calls them.
function makeFakeProvider(): AutocompleteProvider {
	return {
		triggerCharacters: ["@", "#"],
		async getSuggestions() {
			return { items: [], prefix: "" };
		},
		applyCompletion(lines, cursorLine, cursorCol) {
			return { lines, cursorLine, cursorCol };
		},
		shouldTriggerFileCompletion() {
			return true;
		},
	};
}

// NOTE: `liveProvider` is module-level singleton state shared across these tests.
// node:test runs top-level tests sequentially in DEFINITION ORDER by default, so
// this FIRST test observes the pre-capture (undefined) state. Do not reorder / do
// not enable concurrency.
test("getProvider() throws before any provider is captured", () => {
	assert.throws(() => getProvider(), /not captured/);
});

test("captureProvider registers a pass-through factory: returns current UNCHANGED and captures it", () => {
	const base = makeFakeProvider();
	let piCalledFactoryWith: unknown;
	let piUsedResult: unknown;

	// Faithfully simulate pi's ExtensionUIContext.addAutocompleteProvider
	// (interactive-mode.js:1673-1674): it calls the factory SYNCHRONOUSLY with the
	// current chain and keeps the returned provider as the new chain.
	const fakeCtx = {
		ui: {
			addAutocompleteProvider(
				factory: (c: AutocompleteProvider) => AutocompleteProvider,
			) {
				piCalledFactoryWith = base;
				piUsedResult = factory(base);
			},
		},
	} as unknown as ExtensionContext;

	captureProvider(fakeCtx);

	// pi handed our factory the live chain...
	assert.equal(piCalledFactoryWith, base);
	// ...and the factory returned it UNCHANGED (pass-through, zero behavior change)...
	assert.equal(piUsedResult, base);
	// ...and the reference was captured for later RPC handlers.
	assert.equal(getProvider(), base);
});

test("re-capture (e.g. a new session_start) reassigns the captured provider", () => {
	const runCapture = (provider: AutocompleteProvider) => {
		captureProvider({
			ui: {
				addAutocompleteProvider: (f: (c: AutocompleteProvider) => AutocompleteProvider) =>
					void f(provider),
			},
		} as unknown as ExtensionContext);
	};
	const first = makeFakeProvider();
	const second = makeFakeProvider();
	runCapture(first);
	assert.equal(getProvider(), first);
	runCapture(second);
	assert.equal(getProvider(), second);
});
