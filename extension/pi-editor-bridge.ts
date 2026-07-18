/**
 * pi-editor-bridge — bridges pi's autocomplete engine to an external $EDITOR
 * (e.g. Neovim) by running a JSONL-over-Unix-domain-socket RPC server for the
 * session lifetime.
 *
 * Transport:  Unix domain socket, strict JSONL framing (LF-delimited records).
 * Env var:    process.env.PI_EDITOR_BRIDGE  (JSON BridgeDescriptor: { transport,
 *             path, token, pid, cwd, ... }) — written in a later task (S16).
 *
 * STATUS (P1.M1.T1.S2): provider capture implemented.
 *   - session_start: logs a startup message AND captures pi's live autocomplete
 *     provider via a pass-through factory (getProvider() → captured reference).
 *     (TUI-mode guard = S3, socket server = M2, env advertisement = S16.)
 *   - session_shutdown: no-op placeholder. (Socket teardown/cleanup = S6/S15.)
 *
 * Loaded by pi via jiti (TypeScript works without compilation). Install at
 * ~/.pi/agent/extensions/pi-editor-bridge.ts or load with `pi -e ./path.ts`.
 */
import type { AutocompleteProvider } from "@earendil-works/pi-tui";
import type {
	ExtensionAPI,
	ExtensionContext,
	SessionStartEvent,
	SessionShutdownEvent,
} from "@earendil-works/pi-coding-agent";

/**
 * Captured reference to pi's live autocomplete provider chain.
 * Populated by the pass-through factory in {@link captureProvider} on every
 * `session_start`. `undefined` until then; read via {@link getProvider}.
 */
let liveProvider: AutocompleteProvider | undefined;

/**
 * Capture a reference to pi's live `AutocompleteProvider` WITHOUT changing
 * completion behavior.
 *
 * Technique: register a **pass-through** factory with
 * `ctx.ui.addAutocompleteProvider`. pi calls that factory synchronously with
 * the current provider chain as `current` (at minimum the
 * `CombinedAutocompleteProvider`: slash commands, prompt templates, extension
 * commands, skill commands, and `@file`/path/`fd` logic). We stash `current`
 * into {@link liveProvider} and return it **unchanged** — zero behavior change.
 *
 * MUST be called on every `session_start`, because pi clears the autocomplete-
 * wrapper list on session reset (reload/new/resume/fork) and re-applies all
 * factories from scratch via `setupAutocompleteProvider()`. Registering once in
 * the factory body would silently stop capturing after the first reset.
 *
 * (In non-TUI modes `addAutocompleteProvider` is a safe no-op; the explicit
 * `ctx.mode === "tui"` guard is added in S3.)
 */
export function captureProvider(ctx: ExtensionContext): void {
	ctx.ui.addAutocompleteProvider((current) => {
		liveProvider = current;
		return current; // pass-through — zero behavior change
	});
}

/**
 * Return the live autocomplete provider captured on the last `session_start`.
 * Throws if called before the first capture (e.g. before `session_start` fires).
 * RPC handlers (S11–S14) use this to delegate to pi's completion engine.
 */
export function getProvider(): AutocompleteProvider {
	if (!liveProvider) {
		throw new Error(
			"pi-editor-bridge: autocomplete provider not captured yet (await session_start)",
		);
	}
	return liveProvider;
}

export default function (pi: ExtensionAPI): void {
	pi.on("session_start", (event: SessionStartEvent, ctx: ExtensionContext) => {
		// Skeleton: just log. Real startup (open socket, set env) is added in
		// M2 / S16. console.log is fine in --print/--rpc; a later task will
		// prefer ctx.ui.notify when ctx.hasUI (TUI mode).
		console.log(
			`pi-editor-bridge: session_start (reason=${event.reason}, mode=${ctx.mode})`,
		);
		// TODO(S3): guard with `if (ctx.mode !== "tui") return;` before capturing.
		captureProvider(ctx);
		// TODO(M2): startBridge(ctx, ctx.cwd);   TODO(S16): advertise via process.env.PI_EDITOR_BRIDGE
	});

	pi.on("session_shutdown", (_event: SessionShutdownEvent) => {
		// No-op placeholder. TODO(S6/S15): stopBridge() + clear env.
	});
}
