/**
 * pi-editor-bridge — bridges pi's autocomplete engine to an external $EDITOR
 * (e.g. Neovim) by running a JSONL-over-Unix-domain-socket RPC server for the
 * session lifetime.
 *
 * Transport:  Unix domain socket, strict JSONL framing (LF-delimited records).
 * Env var:    process.env.PI_EDITOR_BRIDGE  (JSON BridgeDescriptor: { transport,
 *             path, token, pid, cwd, ... }) — written in a later task (S16).
 *
 * STATUS (P1.M1.T1.S1): lifecycle scaffolding only.
 *   - session_start: logs a startup message. (Provider capture = S2, socket
 *     server = M2, env advertisement = S16.)
 *   - session_shutdown: no-op placeholder. (Socket teardown/cleanup = S6/S15.)
 *
 * Loaded by pi via jiti (TypeScript works without compilation). Install at
 * ~/.pi/agent/extensions/pi-editor-bridge.ts or load with `pi -e ./path.ts`.
 */
import type {
	ExtensionAPI,
	ExtensionContext,
	SessionStartEvent,
	SessionShutdownEvent,
} from "@earendil-works/pi-coding-agent";

export default function (pi: ExtensionAPI): void {
	pi.on("session_start", (event: SessionStartEvent, ctx: ExtensionContext) => {
		// Skeleton: just log. Real startup (capture provider, open socket, set env)
		// is added in S2 / M2 / S16. console.log is fine in --print/--rpc; a later
		// task will prefer ctx.ui.notify when ctx.hasUI (TUI mode).
		console.log(
			`pi-editor-bridge: session_start (reason=${event.reason}, mode=${ctx.mode})`,
		);
	});

	pi.on("session_shutdown", (_event: SessionShutdownEvent) => {
		// No-op placeholder. Socket close + unlink + env clear land in S6/S15.
	});
}
