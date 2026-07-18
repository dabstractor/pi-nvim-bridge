/**
 * pi-editor-bridge — bridges pi's autocomplete engine to an external $EDITOR
 * (e.g. Neovim) by running a JSONL-over-Unix-domain-socket RPC server for the
 * session lifetime.
 *
 * Transport:  Unix domain socket, strict JSONL framing (LF-delimited records).
 * Env var:    process.env.PI_EDITOR_BRIDGE  (JSON BridgeDescriptor: { transport,
 *             path, token, pid, cwd, ... }) — written in a later task (S16).
 *
 * STATUS (P1.M1.T1.S3): TUI mode guard added.
 *   - session_start: guarded by `if (ctx.mode !== "tui") return;` at the very
 *     top, so the bridge performs ZERO work in rpc/json/print modes. The
 *     startup log AND provider capture therefore run ONLY in tui mode (the log
 *     is intentionally TUI-only — it is suppressed in --print/--rpc/--json).
 *     (Socket server = M2, env advertisement = S16, commandsChanged = S17.)
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
import { createServer, type Server } from "node:net";
import { randomUUID } from "node:crypto";
import { chmodSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { onConnection } from "./connection.ts";

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

/**
 * Mutable dependency seam for the bridge's socket server, defaulting to the REAL Node
 * builtins so production behavior is byte-identical to calling `net.createServer` /
 * `fs.chmodSync` directly.
 *
 * WHY A SEAM (not direct calls or module mocking): the `node:net` ESM module namespace
 * is FROZEN — `mock.method(net,"createServer",fn)` / `Object.defineProperty` throws
 * `TypeError: Cannot redefine property: createServer` (verified on Node 26.4.0). A plain
 * mutable object is the clean way to honor the S5 test contract ("mock createServer +
 * assert chmod is called with 0o600") without fighting the frozen namespace. Tests do
 * `const real = __deps.createServer; __deps.createServer = fake; try {...} finally
 * { __deps.createServer = real; }` (research §1.1, §3).
 *
 * STATUS (P1.M2.T3.S5): server-start seam. Later handlers do NOT go through __deps
 * (only createServer + chmodSync are seam'd, because only those have a test contract in S5).
 */
export const __deps: {
	createServer: typeof createServer;
	chmodSync: typeof chmodSync;
} = {
	createServer,
	chmodSync,
};

/** The live bridge socket server, or `undefined` when stopped. Module singleton. */
let server: Server | undefined;
/** The bound Unix-domain socket file path, or `undefined` when stopped. */
let socketPath: string | undefined;
/** The 32-hex-char secret token (the real auth boundary, PRD §12), or `undefined` when stopped. */
let token: string | undefined;

/** @returns the live bridge server (S8 wires onConnection onto it), or `undefined`. */
export function getServer(): Server | undefined {
	return server;
}
/** @returns the bound socket path (S16 reads this for the BridgeDescriptor), or `undefined`. */
export function getSocketPath(): string | undefined {
	return socketPath;
}
/** @returns the secret token (S9's hello handshake validates against this), or `undefined`. */
export function getToken(): string | undefined {
	return token;
}
// NOTE: state is exposed ONLY via getters. jiti (pi's TS loader) does NOT implement
// cross-module live-binding reassignment of `export let` — a consumer that imported a
// `let` would keep seeing the initial value forever (verified, research §1.2). Getters
// read the current value on each call. This mirrors the EXISTING getProvider() idiom.

/**
 * Tear down the bridge server: close the server, unlink the socket file, reset state.
 * IDEMPOTENT — safe to call when already stopped (all guards swallow no-op failures).
 *
 * STATUS (P1.M2.T3.S5): ships the server/socket/state teardown half. **P1.M2.T3.S6
 * REUSES this function (wired into session_shutdown); the env-clear is deferred to S16.**
 * S5 does NOT delete the env var because S5 writes NONE (env advertisement is S16).
 * S5 calls stopBridge() as the first line of startBridge() for idempotent re-entry; S6
 * also calls it from the `server.on("error")` handler in startBridge (double-close is a
 * safe no-op — verified).
 */
export function stopBridge(): void {
	try {
		server?.close(); // no-op if undefined or already closing; never throw
	} catch {
		/* idempotent */
	}
	if (socketPath) {
		try {
			rmSync(socketPath, { force: true }); // force:true → no ENOENT if already gone
		} catch {
			/* idempotent */
		}
	}
	server = undefined;
	socketPath = undefined;
	token = undefined;
	// NOTE: `delete process.env.PI_EDITOR_BRIDGE` is intentionally OMITTED here — S5 writes
	// no env var. S16 adds the WRITE to startBridge and the matching DELETE here.
}

/**
 * Start the bridge socket server: generate a fresh token, bind a unique Unix-domain
 * socket under `os.tmpdir()`, and set restrictive `0o600` perms. IDEMPOTENT — calls
 * {@link stopBridge} first so repeated `session_start` events (reload/new/resume/fork,
 * PRD §6.2) never leak a server or orphan a socket file.
 *
 * STATUS (P1.M2.T3.S5): server-start runtime. OUT OF SCOPE here (landed by later tasks):
 *  - process.env.PI_EDITOR_BRIDGE advertisement ........ P1.M3.T8.S16 (will call
 *    getSocketPath()/getToken()/ctx.cwd/process.pid here to build the BridgeDescriptor).
 *  - wiring startBridge into the session_start handler .. DONE in P1.M2.T3.S6 (S5 left
 *    it unwired so the existing mode-guard.test.ts (S3) wouldn't fire a real listen/chmod
 *    during a unit test; S6 lands both wirings atomically + cleans up in the guard test).
 *  - server.on('error', ...) handler .................... DONE in P1.M2.T3.S6. An unhandled
 *    'error' event (e.g. EADDRINUSE) THROWS and would crash pi (Node EventEmitter contract
 *    — verified); the handler logs + stopBridge()'s and does NOT rethrow.
 *
 * @param ctx accepted to match the contract signature and forward-compat the S16
 *   descriptor; `ctx.cwd` is NOT dereferenced in S5 (the socket path comes from
 *   `os.tmpdir()` per the item contract). Signaled with `void ctx;`.
 */
export function startBridge(ctx: ExtensionContext): void {
	stopBridge(); // idempotent teardown of any prior server (reload/new/resume/fork re-entry)
	void ctx; // ctx.cwd is reserved for the S16 BridgeDescriptor; S5 derives path from tmpdir().

	token = randomUUID().replace(/-/g, "").slice(0, 32); // 32 lowercase hex chars (PRD §12)
	socketPath = join(tmpdir(), `pi-editor-bridge-${randomUUID()}.sock`);
	server = __deps.createServer((sock) => onConnection(sock));
	// Defensive: an unhandled 'error' event (e.g. EADDRINUSE, EACCES binding tmpdir, EMFILE)
	// on a net.Server THROWS and would crash the process (Node EventEmitter contract —
	// verified in P1M2T3S6/research §3). Because startBridge is wired into session_start
	// (P1.M2.T3.S6), such a failure MUST NOT crash pi (PRD §6.7 "never throws from
	// handlers"). Handle it: log the Error (NOT the token/descriptor — PRD §12), then
	// stopBridge so we don't leave a half-bound server or orphaned socket, and do NOT
	// rethrow. Double-close is a safe no-op (verified), so stopBridge()'s own
	// `server?.close()` won't choke when this handler calls it first.
	server.on("error", (err: Error) => {
		console.error(`pi-editor-bridge: socket server error (terminating bridge): ${err}`);
		stopBridge();
	});
	server.listen(socketPath);
	// Restrictive perms (PRD §5.1/§12). libuv creates the socket FILE synchronously inside
	// listen() (verified on-disk), so chmodSync here does NOT ENOENT and yields mode 0o600.
	// Wrapped in try/catch: 0o600 is defense-in-depth; the token is the real auth boundary,
	// so a chmod hiccup must never crash session_start. Skipped on Windows (no Unix perms).
	if (process.platform !== "win32") {
		try {
			__deps.chmodSync(socketPath, 0o600);
		} catch {
			/* best-effort; do not crash */
		}
	}
	// NOTE: NO process.env.PI_EDITOR_BRIDGE write here — that is P1.M3.T8.S16.
}

export default function (pi: ExtensionAPI): void {
	pi.on("session_start", (event: SessionStartEvent, ctx: ExtensionContext) => {
		/**
		 * TUI-only activation gate for the entire bridge.
		 *
		 * The external `$EDITOR` (the process this bridge serves completions to)
		 * is launched EXCLUSIVELY by pi's interactive (TUI) mode via the
		 * `app.editor.external` keybinding — `openExternalEditor()` exists only
		 * under `modes/interactive/` and is never invoked in rpc/json/print
		 * modes. In RPC mode, `ctx.ui.addAutocompleteProvider` is additionally a
		 * documented NO-OP (rpc-mode.ts:271-273: "Autocomplete provider
		 * composition is not supported in RPC mode"), so capturing the provider
		 * would silently capture nothing.
		 *
		 * Short-circuiting here means the bridge performs zero work headlessly:
		 * no provider capture, and (once added below) no socket bind, no env-var
		 * advertisement, no commandsChanged emit. All future session_start logic
		 * MUST be placed BELOW this guard so it inherits non-TUI protection.
		 */
		if (ctx.mode !== "tui") return;

		console.log(
			`pi-editor-bridge: session_start (reason=${event.reason}, mode=${ctx.mode})`,
		);
		captureProvider(ctx);
		startBridge(ctx);
		// TODO(S16): advertise via process.env.PI_EDITOR_BRIDGE (env write is S16's job).
	});

	pi.on("session_shutdown", (_event: SessionShutdownEvent) => {
		stopBridge(); // idempotent teardown: close server, unlink socket, clear state.
		// NOTE: clearing process.env.PI_EDITOR_BRIDGE belongs to S16 (which writes it).
	});
}
