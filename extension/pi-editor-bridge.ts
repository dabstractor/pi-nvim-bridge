/**
 * pi-editor-bridge — bridges pi's autocomplete engine to an external $EDITOR
 * (e.g. Neovim) by running a JSONL-over-Unix-domain-socket RPC server for the
 * session lifetime.
 *
 * Transport:  Unix domain socket, strict JSONL framing (LF-delimited records).
 * Env var:    process.env.PI_EDITOR_BRIDGE  (JSON BridgeDescriptor: { transport,
 *             path, token, pid, cwd, fdAvailable, serverVersion }) — written in
 *             startBridge (S16) and deleted in stopBridge.
 *
 * STATUS (P1.M3.T9.S17): `commandsChanged` S→C notification — DONE. `connection.ts`
 *   got the bridge's FIRST connection registry (`Map<Socket, ConnectionState>`),
 *   populated in `onConnection`, removed on socket `close`. On that registry:
 *   `broadcastNotification(method, params?)` iterates ONLY handshaken connections
 *   (`state.handshakeComplete` — PRD §12: never push to an unauthenticated peer) and
 *   calls the existing per-socket `sendNotification`; `closeAllConnections()`
 *   `sock.end()`s every tracked socket and clears the map — REQUIRED because Node's
 *   `net.Server.close()` only stops accepting NEW connections and KEEPS existing ones
 *   (verified, scout Q2), so without it `stopBridge` would orphan any editor socket
 *   open during a `/reload`. `stopBridge()` now calls `closeAllConnections()` after
 *   `server?.close()` (full teardown: server listener + every accepted socket — a
 *   no-op when the registry is empty, which is the case in every existing lifecycle
 *   test). `session_start` emits `__deps.broadcastNotification("commandsChanged")`
 *   as its LAST statement (after startBridge + provider re-capture + all handler
 *   registrations), guarded by `if (getServer())`. The emit routes through the
 *   `__deps` seam (extended with `broadcastNotification`) so the wiring test can spy.
 *   HONEST PROPERTY: in the current tear-down-on-reload architecture (session_shutdown
 *   fully drains BEFORE session_start), the registry is EMPTY at every realistic
 *   session_start, so the broadcast is structurally quiescent in v1 — it is correctly
 *   wired and activates the moment a future change lets a connection survive a
 *   session boundary (PRD §15 future enhancement). This completes PRD §5.4
 *   (`commandsChanged` was the only method with NO server-side implementation).
 *   `protocol.ts` UNCHANGED (CommandsChangedParams/NotificationMethod/TypedNotification
 *   all already defined in §C/§D). Downstream: P2.M5.T16.S27 (Neovim notification
 *   handler) + P3.M10.T26.S41 (Neovim cache invalidation).
 *
 * STATUS (P1.M2.T7.S15): domain-error wrapping for the 4 provider-dependent
 *   handlers — DONE. `getSuggestions` / `applyCompletion` /
 *   `shouldTriggerFileCompletion` / `getCommands` now wrap BOTH `deps.getProvider()`
 *   (context "completion provider unavailable") and the provider method call
 *   (context "<methodName> failed") in `try/catch` blocks that re-throw via the shared
 *   `toBridgeRpcError(e, context)` converter (added to `connection.ts`). A thrown plain
 *   `Error` becomes `BridgeRpcError(-32603, "<context>: <msg>")` — so `handleLine`'s
 *   `-32603` catch becomes a genuine LAST-RESORT safety net (only unexpected
 *   programming bugs), not the path real domain failures take. `BridgeRpcError`
 *   instances pass through unchanged (so `-32602` params validation + `hello`'s
 *   `-32600` bad token keep their intentional codes). `narrow*Params()` stays BEFORE
 *   the provider block so `-32602` flows untouched. `getSuggestions` preserves its
 *   `finally { clearTimeout(timer) }` on all paths. `hello` / `ping` / `bye` are
 *   INHERENTLY SAFE and are NOT wrapped: their only throw is the intentional
 *   `BridgeRpcError`, their injected getters (`getPid`/`getCwd`/`getFdAvailable`/
 *   `getToken`) are pure non-throwing functions, and `bye` just sets a flag — the
 *   `handleLine` safety net still covers any impossible-in-practice throw from them.
 *   `getProvider()` ITSELF still throws a plain `Error` (the HANDLER wraps it; the
 *   `provider-capture.test.ts` contract stays intact). `-32603` (not `-320xx`) is used
 *   for ALL domain failures: the Neovim client never branches on the code (PRD §11
 *   silent-degrade), so a single interoperable code with a descriptive message beats
 *   inventing a `-320xx` taxonomy no client acts on (research/
 *   jsonrpc-error-best-practices.md §2; `-320xx` is a documented future refinement,
 *   PRD §15).
 *
 * STATUS (P1.M2.T6.S14): `ping` / `bye` / `getCommands` handlers registered (DONE).
 *   - session_start now registers the FULL M2.T6 handler family: `hello` (S9),
 *     `getSuggestions` (S11), `applyCompletion` (S12), `shouldTriggerFileCompletion`
 *     (S13), AND the final three: `ping` / `bye` / `getCommands` (S14). This
 *     completes T6 (RPC method handlers). ping/bye are SYNC; getCommands is ASYNC.
 *     `bye` uses the `closeAfterResponse` flag (approach (a)): it sets
 *     `state.closeAfterResponse = true` and returns `{ok:true}`; `handleLine`'s
 *     success branch then calls `sock.end()` AFTER flushing the ack (mirroring the
 *     existing fatal-close pattern) — so the server participates in the graceful
 *     disconnect (PRD §5.4). `getCommands` derives its list from
 *     `provider.getSuggestions(["/"],0,1)` on the captured provider (covers builtins
 *     + templates + extensions + skills); `argumentHint` is unrecoverable (pi bakes
 *     it into description as "hint — desc") and left `undefined` (documented
 *     limitation). `connection.ts` got the additive `closeAfterResponse?: boolean`
 *     field + a 3-line success-branch close check (backward compatible — no existing
 *     handler sets the flag). `protocol.ts` UNCHANGED (all wire types pre-existed in
 *     §C). `getPid()` (`process.pid`) is added for ping + S16's reuse. Domain-error
 *     wrapping remains S15's TODO. (UPDATE: S15 is DONE — see the S15 error-wrapping
 *     note in the file header and `extension/tests/error-wrapping.test.ts`.)
 *
 * STATUS (P1.M1.T1.S3): TUI mode guard added.
 *   - session_start: guarded by `if (ctx.mode !== "tui") return;` at the very
 *     top, so the bridge performs ZERO work in rpc/json/print modes. The
 *     startup log AND provider capture therefore run ONLY in tui mode (the log
 *     is intentionally TUI-only — it is suppressed in --print/--rpc/--json).
 *     (Socket server = M2, env advertisement = S16, commandsChanged = S17.)
 *   - session_shutdown: no-op placeholder. (Socket teardown/cleanup = S6/S15.)
 *
 * STATUS (P1.M2.T6.S13): `shouldTriggerFileCompletion` handler registered (DONE).
 *   - session_start now registers `hello` (S9), `getSuggestions` (S11),
 *     `applyCompletion` (S12), AND `shouldTriggerFileCompletion` (S13) after
 *     startBridge + provider capture. The S13 handler is a deps-injected factory
 *     (`makeShouldTriggerFileCompletionHandler`) that delegates to pi's LIVE
 *     AutocompleteProvider.shouldTriggerFileCompletion SYNCHRONOUSLY (pi's impl is a
 *     pure SYNC function — autocomplete.ts:775-785, verified; the TUI calls it WITHOUT
 *     await — editor.ts:2152-2153). It has NO AbortController, NO supersession, NO
 *     timeout, NO closure state — plain delegation. The MethodHandler union
 *     (`Promise<unknown> | unknown`) accommodates the sync return; handleLine's `await`
 *     is a no-op on a non-Promise. The method is OPTIONAL on the interface
 *     (autocomplete.ts:269 has the `?`), so the handler uses optional chaining `?.` +
 *     nullish coalescing `?? true` (pi's documented default: absent method ⇒ ALLOW
 *     file completion) — byte-identical to pi's own tests/docs/examples. ping/bye/
 *     getCommands (S14) and domain-error wrapping (S15) remain TODO. (UPDATE: S14
 *     and S15 are DONE — see their STATUS blocks below; domain-error wrapping is
 *     covered by `toBridgeRpcError` + `extension/tests/error-wrapping.test.ts`.)
 *     `connection.ts` and `protocol.ts` UNCHANGED.
 *
 * STATUS (P1.M2.T6.S12): `applyCompletion` handler registered (DONE).
 *   - session_start now registers `hello` (S9), `getSuggestions` (S11), AND
 *     `applyCompletion` (S12) after startBridge + provider capture. The S12 handler is
 *     a deps-injected factory (`makeApplyCompletionHandler`) that delegates to pi's live
 *     AutocompleteProvider.applyCompletion SYNCHRONOUSLY (pi's impl is a pure SYNC
 *     function — autocomplete.ts:256-271, verified). It has NO AbortController, NO
 *     supersession, NO timeout, NO closure state — plain delegation. The MethodHandler
 *     union (`Promise<unknown> | unknown`) accommodates the sync return; handleLine's
 *     `await` is a no-op on a non-Promise. shouldTriggerFileCompletion (S13),
 *     ping/bye/getCommands (S14), and domain-error wrapping (S15) remain TODO. (UPDATE:
 *     S14 and S15 are DONE — see their STATUS blocks below; domain-error wrapping is
 *     covered by `toBridgeRpcError` + `extension/tests/error-wrapping.test.ts`.)
 *     `connection.ts` and `protocol.ts` UNCHANGED.
 *
 * STATUS (P1.M2.T6.S11): `getSuggestions` handler registered (DONE).
 *   - session_start now registers `hello` (S9) AND `getSuggestions` (S11) after
 *     startBridge + provider capture. The S11 handler is a deps-injected factory
 *     (`makeGetSuggestionsHandler`) that delegates to pi's live
 *     AutocompleteProvider, threading a FRESH AbortSignal + strict-boolean `force`,
 *     with closure-scoped supersession (pendingAbort?.abort()) and a per-request
 *     timeout (GET_SUGGESTIONS_TIMEOUT_MS=1500). `connection.ts` and `protocol.ts`
 *     UNCHANGED.
 *
 * Loaded by pi via jiti (TypeScript works without compilation). Install at
 * ~/.pi/agent/extensions/pi-editor-bridge.ts or load with `pi -e ./path.ts`.
 */
import type { AutocompleteProvider, AutocompleteItem } from "@earendil-works/pi-tui";
import type {
	ExtensionAPI,
	ExtensionContext,
	SessionStartEvent,
	SessionShutdownEvent,
} from "@earendil-works/pi-coding-agent";
import { createServer, type Server } from "node:net";
import { randomUUID } from "node:crypto";
import { chmodSync, rmSync, existsSync, statSync } from "node:fs";
import { tmpdir, homedir } from "node:os";
import { join, delimiter } from "node:path";
import {
	onConnection,
	registerBridgeHandler,
	BridgeRpcError,
	toBridgeRpcError,
	broadcastNotification,
	closeAllConnections,
	type ConnectionState,
	type MethodHandler,
} from "./connection.ts";
import type {
	HelloParams,
	HelloResult,
	PingParams,
	PingResult,
	ByeParams,
	ByeResult,
	GetCommandsParams,
	GetCommandsResult,
	CommandInfo,
	GetSuggestionsParams,
	GetSuggestionsResult,
	ApplyCompletionParams,
	ApplyCompletionResult,
	ShouldTriggerFileCompletionParams,
	ShouldTriggerFileCompletionResult,
	BridgeDescriptor,
} from "./protocol.ts";

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
	broadcastNotification: typeof broadcastNotification;
} = {
	createServer,
	chmodSync,
	broadcastNotification,
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
 * Bridge protocol version. PRD §6.4 hardcodes "0.1.0". Reused by the S16
 * `PI_EDITOR_BRIDGE` descriptor (`serverVersion`) and by {@link makeHelloHandler}.
 */
export const BRIDGE_VERSION = "0.1.0";

/**
 * The `process.env` key pi's spawned `$EDITOR` (Neovim) reads to discover the
 * bridge socket path + token on startup (PRD §2.1 / §7.1). Written (as a
 * single-line JSON {@link BridgeDescriptor}) at the end of {@link startBridge};
 * deleted by {@link stopBridge}. Exported so tests reference the NAME (not a
 * hardcoded string) and a future rename is one-line.
 */
export const BRIDGE_ENV = "PI_EDITOR_BRIDGE";

/**
 * Per-`getSuggestions` server-side abort timeout (PRD §5.5 / §6.5). Aborts a runaway
 * `fd` because pi's provider has NO internal timeout (research §1.1) — the CALLER
 * owns cancellation via the `AbortSignal`. Injectable for tests via
 * {@link makeGetSuggestionsHandler}'s `timeoutMs` dep.
 */
export const GET_SUGGESTIONS_TIMEOUT_MS = 1500;

/**
 * The standard Neovim env var the spawned `$EDITOR` (Neovim) reads to pick its config
 * dir (replaces the `nvim` segment in every `stdpath()` path — see `:help $NVIM_APPNAME`).
 * Exported so tests + the manual-alternative docs reference the NAME (not a hardcoded
 * string) and a future rename is one-line.
 */
export const NVIM_APPNAME_ENV = "NVIM_APPNAME";

/**
 * The opt-in env var THIS extension reads for the minimal-config optimization
 * (PRD §10.4). Absent ⇒ feature OFF (zero behavior change). Set to `""` / `"1"` /
 * `"true"` / `"yes"` / `"on"` (case-insensitive) ⇒ use {@link DEFAULT_NVIM_APPNAME}.
 * Any other non-empty string ⇒ that literal appname. Exported for the same reasons
 * as {@link BRIDGE_ENV}.
 */
export const NVIM_APPNAME_OPTIN_ENV = "PI_EDITOR_NVIM_APPNAME";

/**
 * Default appname when the opt-in is a truthy sentinel (PRD §10.4: "pi-editor").
 * The user maintains a tiny `~/.config/pi-editor/` that loads only `pi-editor.nvim`.
 */
export const DEFAULT_NVIM_APPNAME = "pi-editor";

/** The session's cwd (stored from `ctx.cwd` on `session_start`). Read via
 *  {@link getCwd}; used by {@link makeHelloHandler} for `HelloResult.cwd` and (later)
 *  by S16's `PI_EDITOR_BRIDGE` descriptor. */
let cwd: string | undefined;
/** @returns the pi process PID (S14's `ping` result + S16's BridgeDescriptor both use this). */
export function getPid(): number {
	return process.pid;
}
/** @returns the session cwd captured on the last `session_start`, or `undefined`. */
export function getCwd(): string | undefined {
	return cwd;
}
/** Test seam: set the module `cwd`. */
export function __setCwdForTest(v: string | undefined): void {
	cwd = v;
}

/** Cached `fd`/`fdfind` availability (resolved ONCE per process via
 *  {@link resolveFdAvailable}). Read via {@link getFdAvailable}; used by
 *  {@link makeHelloHandler} for `HelloResult.fdAvailable` and (later) by S16. */
let fdAvailableCache: boolean | undefined;
/**
 * @returns whether `fd`/`fdfind` is resolvable (pi agent bin dir first, then `PATH`).
 *  Cached on first call (one-time per process). Mirrors pi's `getToolPath("fd")`
 *  WITHOUT importing pi internals (`getToolPath`/`ensureTool` are not public exports —
 *  research §4). Test seam: {@link __setFdAvailableForTest}.
 */
export function getFdAvailable(): boolean {
	if (fdAvailableCache === undefined) fdAvailableCache = resolveFdAvailable();
	return fdAvailableCache;
}
/** Test seam: override the cached fd-availability (pass `undefined` to reset). */
export function __setFdAvailableForTest(v: boolean | undefined): void {
	fdAvailableCache = v;
}
/**
 * Self-contained fd resolver (mirrors pi `getToolPath("fd")` lookup order, research §4):
 *  1. pi agent bin dir — `config.js`: `getBinDir() = join(getAgentDir(), "bin")`;
 *     `tools-manager` downloads `fd` there. `getAgentDir` honors `$PI_CODING_AGENT_DIR`,
 *     then `XDG_DATA_HOME ?? ~/.local/share` (POSIX) / `%APPDATA%/pi` (Windows).
 *  2. `process.env.PATH` scan for an executable `fd` (+ `fdfind` on Linux).
 */
function resolveFdAvailable(): boolean {
	const isWin = process.platform === "win32";
	const names = process.platform === "linux" ? ["fd", "fdfind"] : ["fd"];
	const ext = isWin ? ".exe" : "";
	const agentDir =
		process.env.PI_CODING_AGENT_DIR ??
		(isWin
			? join(process.env.APPDATA ?? join(homedir(), "AppData", "Roaming"), "pi")
			: join(process.env.XDG_DATA_HOME ?? join(homedir(), ".local", "share"), "pi"));
	for (const n of names) {
		if (isExecutableFile(join(agentDir, "bin", n + ext))) return true;
	}
	for (const dir of (process.env.PATH ?? "").split(delimiter)) {
		if (!dir) continue;
		for (const n of names) {
			if (isExecutableFile(join(dir, n + ext))) return true;
		}
	}
	return false;
}
/** True iff `p` exists and has any execute bit (POSIX) / exists (Windows). Swallows fs errors. */
function isExecutableFile(p: string): boolean {
	try {
		if (!existsSync(p)) return false;
		if (process.platform === "win32") return true;
		return (statSync(p).mode & 0o111) !== 0;
	} catch {
		return false;
	}
}

/**
 * SAVE/RESTORE state for {@link NVIM_APPNAME_ENV} (GOTCHA #1). `nvimAppnameApplied` is
 * true iff the bridge currently has an override active; `nvimAppnameBaseline` is the
 * user's pre-bridge value (string) or `undefined` (the user had none). Both are mutated
 * ONLY by {@link applyNvimAppname} / {@link restoreNvimAppname}. Exposed to tests via
 * {@link __resetNvimAppnameStateForTest} (NOT re-exported as `let` — jiti does not
 * live-bind `export let` reassignment; GOTCHA #5).
 */
let nvimAppnameApplied = false;
let nvimAppnameBaseline: string | undefined;

/**
 * Pure resolver for the opt-in. Reads {@link NVIM_APPNAME_OPTIN_ENV} and returns:
 *  - `undefined`          → opt-in OFF (`applyNvimAppname` does nothing) — the default.
 *  - {@link DEFAULT_NVIM_APPNAME} (`"pi-editor"`) → empty / `1` / `true` / `yes` / `on`.
 *  - `<literal>`          → any other non-empty string (custom appname).
 *
 * PURE — no caching: it re-reads `process.env` each call (the opt-in can be changed
 * between sessions, and it is called at most once per `startBridge`). Exported so the
 * value table is unit-testable without `startBridge`. See research §1.3 for the table.
 */
export function resolveNvimAppname(): string | undefined {
	const raw = process.env[NVIM_APPNAME_OPTIN_ENV];
	if (raw === undefined) return undefined; // opt-in OFF (default — GOTCHA #2)
	const trimmed = raw.trim();
	if (trimmed === "" || /^(1|true|yes|on)$/i.test(trimmed)) {
		return DEFAULT_NVIM_APPNAME;
	}
	return trimmed; // custom appname literal
}

/**
 * Apply the {@link NVIM_APPNAME_ENV} opt-in (if enabled) by capturing the current
 * baseline and overriding it with the resolved appname. NO-OP when the opt-in is off
 * (GOTCHA #2 — guarantees byte-identical behavior to today when
 * {@link NVIM_APPNAME_OPTIN_ENV} is unset). Called at the END of `startBridge`, AFTER
 * the `PI_EDITOR_BRIDGE` descriptor write.
 *
 * CAPTURE ORDER (GOTCHA #3): `startBridge`'s first line is `stopBridge()`, which calls
 * {@link restoreNvimAppname} (writing the baseline back / deleting the override). So by
 * the time this reads `process.env[NVIM_APPNAME_ENV]`, any prior bridge override is
 * already gone and the value is the genuine environment baseline. Two `startBridge`
 * calls therefore capture the SAME baseline both times (verified — research §3). Do
 * NOT move the capture above `stopBridge` or you'll re-capture the bridge's own prior
 * override.
 */
function applyNvimAppname(): void {
	const appname = resolveNvimAppname();
	if (appname === undefined) return; // opt-in OFF → touch nothing
	// startBridge's first line is stopBridge() → restoreNvimAppname(), so any prior
	// override is already gone and THIS reads the genuine environment baseline (GOTCHA #3).
	nvimAppnameBaseline = process.env[NVIM_APPNAME_ENV];
	process.env[NVIM_APPNAME_ENV] = appname; // string only (GOTCHA #4)
	nvimAppnameApplied = true;
}

/**
 * Restore the {@link NVIM_APPNAME_ENV} baseline captured by {@link applyNvimAppname}.
 * NO-OP when no override is active (safe to call unconditionally — the common
 * opt-in-OFF case). Writes the baseline back, or DELETES the var if the baseline was
 * `undefined` (GOTCHA #1 — NEVER clobber a pre-existing user value; a plain
 * `delete process.env.NVIM_APPNAME` would PERMANENTLY CLOBBER a user's global like
 * `NVIM_APPNAME=work` for the rest of the pi process). Called from `stopBridge`.
 */
function restoreNvimAppname(): void {
	if (!nvimAppnameApplied) return; // safe no-op when opt-in was off / nothing applied
	if (nvimAppnameBaseline === undefined) {
		delete process.env[NVIM_APPNAME_ENV]; // user had none → leave it absent
	} else {
		process.env[NVIM_APPNAME_ENV] = nvimAppnameBaseline; // RESTORE the user's value
	}
	nvimAppnameApplied = false;
	nvimAppnameBaseline = undefined;
}

/** Test seam: zero the apply/restore state (parallels {@link __setFdAvailableForTest}). */
export function __resetNvimAppnameStateForTest(): void {
	nvimAppnameApplied = false;
	nvimAppnameBaseline = undefined;
}

/**
 * Tear down the bridge server: close the server, unlink the socket file, reset state.
 * IDEMPOTENT — safe to call when already stopped (all guards swallow no-op failures).
 *
 * STATUS (P1.M2.T3.S5): ships the server/socket/state teardown half. **P1.M2.T3.S6
 * REUSES this function (wired into session_shutdown).** S5 calls stopBridge() as the
 * first line of startBridge() for idempotent re-entry; S6 also calls it from the
 * `server.on("error")` handler in startBridge (double-close is a safe no-op — verified).
 * S16 added the `delete process.env[BRIDGE_ENV]` line below (the symmetric teardown of
 * the advertisement written at the end of startBridge).
 */
export function stopBridge(): void {
	try {
		server?.close(); // no-op if undefined or already closing; never throw
	} catch {
		/* idempotent */
	}
	closeAllConnections(); // S17: Node server.close() keeps existing sockets — close them too
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
	delete process.env[BRIDGE_ENV]; // symmetric: clears the advertisement (no-op if absent)
	restoreNvimAppname(); // restore the user's pre-bridge NVIM_APPNAME baseline (no-op if not applied — GOTCHA #1)
}

/**
 * Start the bridge socket server: generate a fresh token, bind a unique Unix-domain
 * socket under `os.tmpdir()`, and set restrictive `0o600` perms. IDEMPOTENT — calls
 * {@link stopBridge} first so repeated `session_start` events (reload/new/resume/fork,
 * PRD §6.2) never leak a server or orphan a socket file.
 *
 * STATUS (P1.M2.T3.S5): server-start runtime. OUT OF SCOPE here (landed by later tasks):
 *  - process.env.PI_EDITOR_BRIDGE advertisement ........ DONE in P1.M3.T8.S16 (writes
 *    the BridgeDescriptor as the LAST line of this function, reading socketPath/token/
 *    process.pid/ctx.cwd/getFdAvailable()/BRIDGE_VERSION).
 *  - wiring startBridge into the session_start handler .. DONE in P1.M2.T3.S6 (S5 left
 *    it unwired so the existing mode-guard.test.ts (S3) wouldn't fire a real listen/chmod
 *    during a unit test; S6 lands both wirings atomically + cleans up in the guard test).
 *  - server.on('error', ...) handler .................... DONE in P1.M2.T3.S6. An unhandled
 *    'error' event (e.g. EADDRINUSE) THROWS and would crash pi (Node EventEmitter contract
 *    — verified); the handler logs + stopBridge()'s and does NOT rethrow.
 *
 * @param ctx its `.cwd` is read for the S16 `PI_EDITOR_BRIDGE` descriptor (the module
 *   `cwd` is set in `session_start` AFTER this returns — GOTCHA #3 — so `ctx.cwd` is the
 *   source of truth here). The socket path itself comes from `os.tmpdir()`.
 */
export function startBridge(ctx: ExtensionContext): void {
	stopBridge(); // idempotent teardown of any prior server (reload/new/resume/fork re-entry)

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
	/**
	 * [Mode A] Advertise the bridge to the spawned $EDITOR via process.env.
	 *
	 * DISCOVERY: pi spawns the external editor with `spawn(editor, [tmpFile], {
	 * stdio:"inherit", shell: process.platform==="win32" })` and NO `env:` option
	 * (interactive-mode.ts:3811-3816), so the child Neovim INHERITS pi's process.env.
	 * Writing PI_EDITOR_BRIDGE here (on session_start, before any Ctrl+G launch) makes
	 * it visible to the spawned Neovim as `vim.env.PI_EDITOR_BRIDGE`. The plugin's
	 * VimEnter gate vim.json.decode's it to find the socket path + token; absent/
	 * unparseable → the plugin stays dormant (PRD §7.1). This write is THE discovery
	 * that makes the two-component design work (PRD §2.1). CRITICALITY: without it the
	 * plugin never activates and the bridge is unreachable. The descriptor is a flat
	 * JSON object → JSON.stringify emits a single line (no "\n") — the safe env value.
	 */
	process.env[BRIDGE_ENV] = JSON.stringify({
		transport: "unix",
		path: socketPath, // module-level let — guaranteed set above
		token, // module-level let — guaranteed set above
		pid: process.pid,
		cwd: ctx.cwd, // read DIRECTLY (module `cwd` is set in session_start AFTER startBridge)
		fdAvailable: getFdAvailable(), // REAL resolver — consistent with hello/ping (GOTCHA #2)
		serverVersion: BRIDGE_VERSION, // "0.1.0" — NOT "0.0.1" (GOTCHA #1)
	} satisfies BridgeDescriptor); // compile-time guard against the `version` typo
	/**
	 * [Mode A] Optional NVIM_APPNAME opt-in — minimal-config optimization (PRD §10.4).
	 *
	 * When the user sets {@link NVIM_APPNAME_OPTIN_ENV} (`""` / `"1"` / `"true"` /
	 * `"yes"` / `"on"` ⇒ default `"pi-editor"`; any other non-empty string ⇒ that
	 * appname), override `process.env[NVIM_APPNAME_ENV]` so the pi-spawned `$EDITOR`
	 * (Neovim) boots with a tiny dedicated config (`~/.config/<appname>/`) instead of
	 * the user's full `~/.config/nvim/` — dramatically faster editor startup.
	 *
	 * DISCOVERY: same `process.env`-inheritance seam as `PI_EDITOR_BRIDGE` above — pi
	 * spawns the editor with `stdio:"inherit"` and no `env:` override (interactive-mode.ts),
	 * so the child Neovim sees this value. SAVE/RESTORE: unlike `PI_EDITOR_BRIDGE`
	 * (which pi owns and `stopBridge` plainly `delete`s), `NVIM_APPNAME` is a STANDARD
	 * Neovim var the user may already export globally (e.g. `NVIM_APPNAME=work`); we
	 * capture the baseline in `applyNvimAppname()` and `restoreNvimAppname()` (called
	 * from `stopBridge`) writes it back — we NEVER clobber a pre-existing user value
	 * (GOTCHA #1). OFF by default: `resolveNvimAppname()` returns `undefined` when the
	 * opt-in var is unset ⇒ this is a pure no-op (GOTCHA #2). Placement inside
	 * `startBridge` (not a separate `session_start` hook) inherits the TUI guard
	 * (GOTCHA #8); capture runs AFTER `startBridge`'s first-line `stopBridge` so the
	 * baseline is the genuine environment (GOTCHA #3).
	 */
	applyNvimAppname();
}

/**
 * Build the `hello` JSON-RPC handler (PRD §5.3 / §5.4). PURE factory — deps are
 * injected so the unit tests can exercise every branch without touching module
 * state. `pi-editor-bridge.ts` registers it via
 * `registerBridgeHandler("hello", makeHelloHandler({ getToken, getCwd, getFdAvailable, version: BRIDGE_VERSION }))`
 * on every `session_start` (AFTER `startBridge`, so the token exists).
 *
 * Behavior:
 *  - token match ⇒ set `state.handshakeComplete = true` (S10 gates every other
 *    method on this) and return `HelloResult` (handleLine wraps it as a success).
 *  - any mismatch / missing / wrong-type token / no expected token set (stopped
 *    bridge) ⇒ throw `BridgeRpcError(-32600, "bad token", { fatal: true })`.
 *    `handleLine` maps it to the `-32600` error response AND a graceful `sock.end()`
 *    (PRD §5.3 "then close"). The message is the literal `"bad token"` — NEVER the
 *    token value (PRD §12). `===` is fine: local process secret, timing attacks
 *    out of scope (research §9).
 *
 * `client`/`clientVersion` params are accepted and ignored.
 */
export function makeHelloHandler(deps: {
	getToken: () => string | undefined;
	getCwd: () => string | undefined;
	getFdAvailable: () => boolean;
	version: string;
}): MethodHandler {
	return (params: unknown, state: ConnectionState): HelloResult => {
		const expected = deps.getToken();
		const p = (params ?? null) as Partial<HelloParams> | null;
		const received =
			p && typeof p === "object" && typeof p.token === "string" ? p.token : undefined;
		// No expected token (bridge stopped), empty, or any mismatch ⇒ bad token.
		// NEVER include token values in the message (PRD §12).
		if (typeof expected !== "string" || expected.length === 0 || received !== expected) {
			throw new BridgeRpcError(-32600, "bad token", { fatal: true });
		}
		state.handshakeComplete = true; // S10 gates every other method on this.
		return {
			ok: true,
			serverVersion: deps.version,
			cwd: deps.getCwd() ?? "",
			fdAvailable: deps.getFdAvailable(),
		};
	};
}

/**
 * Build the `ping` JSON-RPC handler (PRD §5.4). PURE factory — deps injected so
 * unit tests stub pid/cwd/fdAvailable/version. SYNC (mirrors `makeHelloHandler`'s
 * shape but WITHOUT the token branch).
 *
 * Liveness/diagnostics handler returning `PingResult` — i.e. `HelloResult` + a
 * `pid` field. It is `makeHelloHandler` minus token validation: the S10 handshake
 * gate (`handleLine`'s `method !== "hello" && !state.handshakeComplete`) ALREADY
 * guarantees `state.handshakeComplete === true` before any non-hello method runs,
 * so `ping` NEVER sees an unauthenticated caller and needs NO `getToken` dep.
 *
 * EMPTY params (`PingParams = Record<string, never>`) are IGNORED — consistent
 * with `hello` ignoring `client`/`clientVersion`. NO params validator (there is
 * nothing to narrow; pure rejection of an empty-params method is pointless).
 *
 * The MethodHandler union (`Promise<unknown> | unknown`) accommodates the SYNC
 * return; handleLine's `await` is a no-op on a non-Promise.
 *
 * Consumer: P3.M10.T27.S42 (`:checkhealth pi-editor` opens a connection, handshakes,
 * then sends `ping` to confirm liveness + read server identity/capabilities).
 */
export function makePingHandler(deps: {
	getPid: () => number;
	getCwd: () => string | undefined;
	getFdAvailable: () => boolean;
	version: string;
}): MethodHandler {
	return (_params: unknown, _state: ConnectionState): PingResult => ({
		ok: true,
		pid: deps.getPid(),
		cwd: deps.getCwd() ?? "", // defensive fallback (mirrors hello's getCwd() ?? "")
		fdAvailable: deps.getFdAvailable(),
		serverVersion: deps.version,
	});
}

/**
 * Build the `bye` JSON-RPC handler (PRD §5.4 — "graceful disconnect"). PURE factory
 * (no deps). SYNC.
 *
 * Returns `ByeResult = { ok: true }` AND requests a server-side half-close by
 * setting `state.closeAfterResponse = true`. `handleLine`'s success branch checks
 * that flag AFTER `sendResponse` flushes the ack and calls `sock.end()` (mirroring
 * the existing fatal-close pattern). This makes the server PARTICIPATE in the close
 * (the faithful reading of PRD §5.4's "graceful disconnect"); the client observes
 * `close`/`end` instead of lingering on TCP keepalive.
 *
 * Handlers do NOT receive the socket (the `MethodHandler` signature is
 * `(params, state)`), so `bye` cannot call `sock.end()` directly — the
 * `ConnectionState` flag is the minimal, backward-compatible mechanism (optional;
 * falsy ⇒ no close ⇒ all existing handlers/tests unaffected).
 *
 * REJECTED alternative: throw `BridgeRpcError({ fatal: true })` to close — that
 * returns an ERROR envelope, violating the `ByeResult = { ok: true }` SUCCESS
 * contract. The flag returns success THEN closes.
 *
 * Consumer: P2.M9.T23.S38 (Neovim `VimLeavePre`/`ExitPre` autocmd sends `bye` so
 * the server can ack + half-close cleanly before the socket tears down).
 */
export function makeByeHandler(): MethodHandler {
	return (_params: unknown, state: ConnectionState): ByeResult => {
		state.closeAfterResponse = true; // approach (a): ack THEN half-close
		return { ok: true };
	};
}

/**
 * Narrow a raw `unknown` JSON-RPC `params` into {@link GetSuggestionsParams}, throwing
 * `BridgeRpcError(-32602, "invalid params: …")` on any malformed shape.
 *
 * `-32602` is the reserved JSON-RPC "invalid params" code (protocol.ts §A). This
 * matches S9's precedent (hello throws `BridgeRpcError(-32600)` for a bad token):
 * handler-level INPUT VALIDATION throws typed errors here; provider RUNTIME throws
 * are wrapped by S15 into `BridgeRpcError(-32603)` at the handler edge (context
 * "getSuggestions failed").
 *
 * Rules: `params` is a non-null object; `lines` is an Array of strings;
 * `cursorLine`/`cursorCol` are non-negative integers; `force` is undefined or boolean.
 * Returns a `force` of type `boolean | undefined` (callers thread it as `=== true`).
 */
function narrowGetSuggestionsParams(params: unknown): GetSuggestionsParams {
	const p = params as Partial<GetSuggestionsParams> | null;
	if (!p || typeof p !== "object") {
		throw new BridgeRpcError(-32602, "invalid params: expected an object");
	}
	const { lines, cursorLine, cursorCol, force } = p;
	if (!Array.isArray(lines) || !lines.every((l) => typeof l === "string")) {
		throw new BridgeRpcError(-32602, "invalid params: lines must be string[]");
	}
	if (
		typeof cursorLine !== "number" ||
		!Number.isInteger(cursorLine) ||
		cursorLine < 0
	) {
		throw new BridgeRpcError(-32602, "invalid params: cursorLine must be a non-negative integer");
	}
	if (
		typeof cursorCol !== "number" ||
		!Number.isInteger(cursorCol) ||
		cursorCol < 0
	) {
		throw new BridgeRpcError(-32602, "invalid params: cursorCol must be a non-negative integer");
	}
	if (force !== undefined && typeof force !== "boolean") {
		throw new BridgeRpcError(-32602, "invalid params: force must be boolean");
	}
	return { lines, cursorLine, cursorCol, force };
}

/**
 * Build the `getSuggestions` JSON-RPC handler (PRD §5.4 / §6.5). PURE factory — deps
 * injected so unit tests stub the provider + timeout. Delegates to pi's LIVE
 * {@link AutocompleteProvider}, threading a FRESH `AbortSignal` + the boolean `force`.
 *
 * SUPERSESSION: a single closure-scoped `pendingAbort` slot is shared across all calls
 * of this (one-per-session) handler instance. Each call aborts the previous in-flight
 * controller (so `fd` is SIGKILL'd — research §1.1) before arming its own. Because pi's
 * provider RESOLVES (never rejects) on abort (research §1.2), the superseded call
 * shortly resolves to its abort result and its `handleLine` sends `{id_prior,result}`
 * NATURALLY — the client ignores stale ids (PRD §5.5). S11 does NOT suppress that
 * response (`handleLine` is fire-and-forget per line and ALWAYS replies once).
 *
 * TIMEOUT: `setTimeout(timeoutMs, () => ac.abort())` aborts a runaway `fd` (pi has no
 * internal timeout — research §1.1). `clearTimeout(timer)` runs in `finally` so the
 * timer never leaks past completion.
 *
 * ERRORS: malformed params throw `BridgeRpcError(-32602)` (S9 precedent; -32602 = the
 * reserved "invalid params" code). S15 wraps `deps.getProvider()` throwing (provider
 * not captured) and any provider RUNTIME throw into `BridgeRpcError(-32603, "<context>:
 * <msg>")` via {@link toBridgeRpcError} at the handler edge, so the safety net is
 * last-resort. The contexts are "completion provider unavailable" (getProvider) and
 * "getSuggestions failed" (the provider call).
 *
 * @param deps.getProvider  returns the live provider (throws plain `Error` if not
 *   captured yet → S15 wraps to `-32603` "completion provider unavailable: ...").
 * @param deps.timeoutMs    per-request abort timeout (defaults to
 *   {@link GET_SUGGESTIONS_TIMEOUT_MS}; inject a short value in tests).
 */
export function makeGetSuggestionsHandler(deps: {
	getProvider: () => AutocompleteProvider;
	timeoutMs?: number;
}): MethodHandler {
	const timeoutMs = deps.timeoutMs ?? GET_SUGGESTIONS_TIMEOUT_MS;
	let pendingAbort: AbortController | undefined;
	return async (
		_params: unknown,
		_state: ConnectionState,
	): Promise<GetSuggestionsResult> => {
		const params = narrowGetSuggestionsParams(_params);
		let provider: AutocompleteProvider;
		try {
			provider = deps.getProvider(); // wrapped by S15: toBridgeRpcError(e, "completion provider unavailable") → -32603
		} catch (e) {
			throw toBridgeRpcError(e, "completion provider unavailable");
		}
		const ac = new AbortController();
		pendingAbort?.abort(); // supersede any in-flight call (SIGKILLs its fd)
		pendingAbort = ac;
		const timer: ReturnType<typeof setTimeout> = setTimeout(() => {
			if (!ac.signal.aborted) ac.abort();
		}, timeoutMs);
		try {
			try {
				return await provider.getSuggestions(
					params.lines,
					params.cursorLine,
					params.cursorCol,
					{ signal: ac.signal, force: params.force === true },
				);
			} catch (e) {
				throw toBridgeRpcError(e, "getSuggestions failed");
			}
		} finally {
			clearTimeout(timer);
		}
	};
}

/**
 * Narrow a raw `unknown` JSON-RPC `params` into {@link ApplyCompletionParams}, throwing
 * `BridgeRpcError(-32602, "invalid params: …")` on any malformed shape.
 *
 * Mirrors {@link narrowGetSuggestionsParams} + adds `item`/`prefix` validation.
 * `-32602` is the reserved JSON-RPC "invalid params" code (protocol.ts §A). This
 * matches S9/S11 precedent: handler-level INPUT VALIDATION throws typed errors here;
 * provider RUNTIME throws are wrapped by S15 into `BridgeRpcError(-32603)` at the
 * handler edge (context "applyCompletion failed").
 *
 * Rules: `params` is a non-null object; `lines` is an Array of strings;
 * `cursorLine`/`cursorCol` are non-negative integers; `item` is a non-null object with
 * `value:string` + `label:string` (`description` is OPTIONAL — AutocompleteItem marks
 * it `?`); `prefix` is a string.
 */
function narrowApplyCompletionParams(params: unknown): ApplyCompletionParams {
	const p = params as Partial<ApplyCompletionParams> | null;
	if (!p || typeof p !== "object") {
		throw new BridgeRpcError(-32602, "invalid params: expected an object");
	}
	const { lines, cursorLine, cursorCol, item, prefix } = p;
	if (!Array.isArray(lines) || !lines.every((l) => typeof l === "string")) {
		throw new BridgeRpcError(-32602, "invalid params: lines must be string[]");
	}
	if (
		typeof cursorLine !== "number" ||
		!Number.isInteger(cursorLine) ||
		cursorLine < 0
	) {
		throw new BridgeRpcError(-32602, "invalid params: cursorLine must be a non-negative integer");
	}
	if (
		typeof cursorCol !== "number" ||
		!Number.isInteger(cursorCol) ||
		cursorCol < 0
	) {
		throw new BridgeRpcError(-32602, "invalid params: cursorCol must be a non-negative integer");
	}
	// item: non-null object with value:string + label:string (description optional).
	if (!item || typeof item !== "object") {
		throw new BridgeRpcError(-32602, "invalid params: item must be an object");
	}
	const it = item as Partial<AutocompleteItem>;
	if (typeof it.value !== "string" || typeof it.label !== "string") {
		throw new BridgeRpcError(
			-32602,
			"invalid params: item.value and item.label must be strings",
		);
	}
	if (typeof prefix !== "string") {
		throw new BridgeRpcError(-32602, "invalid params: prefix must be a string");
	}
	return { lines, cursorLine, cursorCol, item: it as AutocompleteItem, prefix };
}

/**
 * Build the `applyCompletion` JSON-RPC handler (PRD §5.4 / §6.5). PURE factory — dep
 * injected so unit tests stub the provider. Delegates to pi's LIVE {@link
 * AutocompleteProvider.applyCompletion} SYNCHRONOUSLY.
 *
 * SYNC, NO TIMING/RESOURCE CONCERNS: unlike getSuggestions (S11), applyCompletion is a
 * pure SYNC function (pi autocomplete.ts:256-271 — verified). It takes NO options/
 * AbortSignal/force and returns the new {lines,cursorLine,cursorCol} directly. The TUI
 * calls it WITHOUT await (editor.ts:669/690/2257). So this handler has NO AbortController,
 * NO supersession (no `pendingAbort`), NO timeout, NO closure state — it is plain
 * delegation. The MethodHandler union (`Promise<unknown> | unknown`) accommodates a sync
 * return; handleLine's `await` is a no-op on a non-Promise.
 *
 * INSERTION IS PI'S JOB: pi's impl computes every insertion edge case (slash `/cmd `
 * trailing space, `@file` trailing space for files / none for dirs, quote handling,
 * cursor repositioning). This handler forwards (…,item,prefix) VERBATIM and returns
 * pi's result UNCHANGED — the bridge never reimplements insertion (PRD §4 step 5).
 *
 * ERRORS: malformed params throw `BridgeRpcError(-32602)` (S9/S11 precedent; -32602 =
 * reserved "invalid params"). S15 wraps `deps.getProvider()` throwing (provider not
 * captured) and any provider RUNTIME throw into `BridgeRpcError(-32603, "<context>:
 * <msg>")` via {@link toBridgeRpcError} at the handler edge (contexts "completion
 * provider unavailable" and "applyCompletion failed"); the safety net is last-resort.
 */
export function makeApplyCompletionHandler(deps: {
	getProvider: () => AutocompleteProvider;
}): MethodHandler {
	return (
		_params: unknown,
		_state: ConnectionState,
	): ApplyCompletionResult => {
		const params = narrowApplyCompletionParams(_params);
		let provider: AutocompleteProvider;
		try {
			provider = deps.getProvider(); // wrapped by S15: toBridgeRpcError(e, "completion provider unavailable") → -32603
		} catch (e) {
			throw toBridgeRpcError(e, "completion provider unavailable");
		}
		// SYNC delegation — return pi's full new buffer + cursor VERBATIM.
		try {
			return provider.applyCompletion(
				params.lines,
				params.cursorLine,
				params.cursorCol,
				params.item,
				params.prefix,
			);
		} catch (e) {
			throw toBridgeRpcError(e, "applyCompletion failed");
		}
	};
}

/**
 * Narrow a raw `unknown` JSON-RPC `params` into {@link ShouldTriggerFileCompletionParams},
 * throwing `BridgeRpcError(-32602, "invalid params: …")` on any malformed shape.
 *
 * Mirrors {@link narrowGetSuggestionsParams} but with ONLY `lines`/`cursorLine`/
 * `cursorCol` (no `force`, no `item`/`prefix`). `-32602` is the reserved JSON-RPC
 * "invalid params" code (protocol.ts §A). This matches S9/S11/S12 precedent:
 * handler-level INPUT VALIDATION throws typed errors here; provider RUNTIME throws
 * are wrapped by S15 into `BridgeRpcError(-32603)` at the handler edge (context
 * "shouldTriggerFileCompletion failed").
 *
 * Rules: `params` is a non-null object; `lines` is an Array of strings;
 * `cursorLine`/`cursorCol` are non-negative integers.
 */
function narrowShouldTriggerFileCompletionParams(
	params: unknown,
): ShouldTriggerFileCompletionParams {
	const p = params as Partial<ShouldTriggerFileCompletionParams> | null;
	if (!p || typeof p !== "object") {
		throw new BridgeRpcError(-32602, "invalid params: expected an object");
	}
	const { lines, cursorLine, cursorCol } = p;
	if (!Array.isArray(lines) || !lines.every((l) => typeof l === "string")) {
		throw new BridgeRpcError(-32602, "invalid params: lines must be string[]");
	}
	if (
		typeof cursorLine !== "number" ||
		!Number.isInteger(cursorLine) ||
		cursorLine < 0
	) {
		throw new BridgeRpcError(-32602, "invalid params: cursorLine must be a non-negative integer");
	}
	if (
		typeof cursorCol !== "number" ||
		!Number.isInteger(cursorCol) ||
		cursorCol < 0
	) {
		throw new BridgeRpcError(-32602, "invalid params: cursorCol must be a non-negative integer");
	}
	return { lines, cursorLine, cursorCol };
}

/**
 * Build the `shouldTriggerFileCompletion` JSON-RPC handler (PRD §5.4 / §6.5). PURE
 * factory — dep injected so unit tests stub the provider. Delegates to pi's LIVE {@link
 * AutocompleteProvider.shouldTriggerFileCompletion} SYNCHRONOUSLY.
 *
 * SYNC, NO TIMING/RESOURCE CONCERNS: unlike getSuggestions (S11), shouldTriggerFileCompletion
 * is a pure SYNC function (pi autocomplete.ts:775-785 — verified). It takes NO options/
 * AbortSignal and returns a `boolean` directly. The TUI calls it WITHOUT await
 * (editor.ts:2152-2153). So this handler has NO AbortController, NO supersession (no
 * `pendingAbort`), NO timeout, NO closure state — it is plain delegation. The
 * MethodHandler union (`Promise<unknown> | unknown`) accommodates a sync return;
 * handleLine's `await` is a no-op on a non-Promise.
 *
 * OPTIONAL METHOD + `true` DEFAULT: UNLIKE getSuggestions/applyCompletion (required),
 * shouldTriggerFileCompletion is marked OPTIONAL on AutocompleteProvider
 * (autocomplete.ts:269 has the `?`). The handler MUST use optional chaining `?.` (a
 * direct call throws TypeError on a provider without the method) and nullish coalescing
 * `?? true` (pi's documented default: absent method ⇒ ALLOW file completion). pi's own
 * tests, docs, and examples ALL write `current.shouldTriggerFileCompletion?.(...) ?? true`
 * (byte-identical across 5 sources). The bridge replicates this VERBATIM.
 *
 * GATE IS PI'S JOB: pi's impl returns `false` while the user types a bare slash command
 * (e.g. `/set` before any space) and `true` otherwise (PRD §11). This handler forwards
 * (lines,cursorLine,cursorCol) and returns pi's boolean UNCHANGED — the bridge never
 * reimplements the gate.
 *
 * ERRORS: malformed params throw `BridgeRpcError(-32602)` (S9/S11/S12 precedent;
 * -32602 = reserved "invalid params"). `deps.getProvider()` throwing (provider not
 * captured) and any provider RUNTIME throw into `BridgeRpcError(-32603, "<context>:
 * <msg>")` via {@link toBridgeRpcError} at the handler edge (contexts "completion
 * provider unavailable" and "shouldTriggerFileCompletion failed"); the safety net is
 * last-resort.
 */
export function makeShouldTriggerFileCompletionHandler(deps: {
	getProvider: () => AutocompleteProvider;
}): MethodHandler {
	return (
		_params: unknown,
		_state: ConnectionState,
	): ShouldTriggerFileCompletionResult => {
		const params = narrowShouldTriggerFileCompletionParams(_params);
		let provider: AutocompleteProvider;
		try {
			provider = deps.getProvider(); // wrapped by S15: toBridgeRpcError(e, "completion provider unavailable") → -32603
		} catch (e) {
			throw toBridgeRpcError(e, "completion provider unavailable");
		}
		// SYNC delegation via `?.` (method is OPTIONAL) + `?? true` (pi's documented default).
		// Return pi's boolean VERBATIM. Wrap the whole expression so a throw from the
		// optional method is caught (S15).
		try {
			return (
				provider.shouldTriggerFileCompletion?.(
					params.lines,
					params.cursorLine,
					params.cursorCol,
				) ?? true
			);
		} catch (e) {
			throw toBridgeRpcError(e, "shouldTriggerFileCompletion failed");
		}
	};
}

/**
 * Build the `getCommands` JSON-RPC handler (PRD §5.4 — OPTIONAL docs-menu method).
 * PURE factory — dep injected so unit tests stub the provider. ASYNC (mirrors
 * S11/S12/S13's `getProvider` dep + `makeGetSuggestionsHandler`'s async shape).
 *
 * DATA SOURCE: the handler calls
 * `provider.getSuggestions(["/"], 0, 1, { signal, force: false })` on the
 * ALREADY-CAPTURERED live provider and maps each `AutocompleteItem{value,label,
 * description?}` → `CommandInfo{name, description?}`. This covers EVERY command
 * category (builtins + prompt templates + extension commands + skill commands) via
 * pi's `CombinedAutocompleteProvider` — the `/` branch in `autocomplete.ts:118-165`
 * is SYNC + in-memory (textBeforeCursor="/", no `@file`, no `fd`), and `fuzzyFilter`
 * with an empty prefix returns ALL items.
 *
 * WHY NOT `pi.getCommands()` / hardcoding: `pi.getCommands()` (ExtensionAPI) OMITS
 * the ~23 `BUILTIN_SLASH_COMMANDS`, and `BUILTIN_SLASH_COMMANDS` is NOT publicly
 * exported (not in index.ts) — so hardcoding would drift. The captured provider's
 * `getSuggestions(["/"])` is the ONLY source that covers the full surface.
 *
 * `argumentHint` is UNRECOVERABLE from this path: pi BAKES it into the description
 * string as `"hint — desc"`, and `AutocompleteItem` has no `argumentHint` field.
 * Splitting the description on `" — "` is unsafe (descriptions legitimately contain
 * ` — `). So `argumentHint` is left `undefined` (protocol.ts marks it optional) —
 * a documented limitation.
 *
 * TIMING: a fresh `AbortController` satisfies the `{signal, force}` signature only.
 * The `/` branch is SYNC + in-memory (NO `fd` runaway risk, unlike S11's
 * `getSuggestions`), so abort is a no-op and NO timeout / NO supersession is needed.
 *
 * EMPTY params (`GetCommandsParams = Record<string, never>`) are IGNORED — NO
 * params validator (nothing to narrow; hello's precedent is to ignore unknown params).
 *
 * ERRORS: S15 wraps `deps.getProvider()` throwing (provider not captured) and any
 * provider RUNTIME throw into `BridgeRpcError(-32603, "<context>: <msg>")` via
 * {@link toBridgeRpcError} at the handler edge (contexts "completion provider
 * unavailable" and "getSuggestions failed" — getCommands reuses getSuggestions); the
 * safety net is last-resort. A `null`/empty provider result yields `{commands: []}`.
 */
export function makeGetCommandsHandler(deps: {
	getProvider: () => AutocompleteProvider;
}): MethodHandler {
	return async (
		_params: unknown,
		_state: ConnectionState,
	): Promise<GetCommandsResult> => {
		let provider: AutocompleteProvider;
		try {
			provider = deps.getProvider(); // wrapped by S15: toBridgeRpcError(e, "completion provider unavailable") → -32603
		} catch (e) {
			throw toBridgeRpcError(e, "completion provider unavailable");
		}
		const ac = new AbortController(); // signature requires {signal}; the "/" branch is sync ⇒ no-op
		let result: Awaited<ReturnType<AutocompleteProvider["getSuggestions"]>>;
		try {
			result = await provider.getSuggestions(["/"], 0, 1, {
				signal: ac.signal,
				force: false,
			});
		} catch (e) {
			// getCommands reuses getSuggestions under the hood, so the method context is
			// "getSuggestions failed" (S15).
			throw toBridgeRpcError(e, "getSuggestions failed");
		}
		if (!result) return { commands: [] };
		// Map AutocompleteItem → CommandInfo. `name = item.value` (no leading slash);
		// `description` forwarded when present. `argumentHint` intentionally omitted
		// (unrecoverable — pi bakes it into description as "hint — desc").
		const commands: CommandInfo[] = result.items.map((item) => ({
			name: item.value,
			...(item.description ? { description: item.description } : {}),
		}));
		return { commands };
	};
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
		cwd = ctx.cwd; // HelloResult.cwd (S9) + the S16 descriptor.
		// Register `hello` AFTER startBridge so the token exists. Idempotent (Map.set) —
		// safe across reload/new/resume/fork re-entry (research §6). S9 only SETS the
		// handshake flag; S10 adds the gate that blocks every non-hello method until it's set.
		registerBridgeHandler(
			"hello",
			makeHelloHandler({ getToken, getCwd, getFdAvailable, version: BRIDGE_VERSION }),
		);
		// S11: register `getSuggestions` AFTER `hello` (so the provider is captured and the
		// token exists) and AFTER startBridge. The handler delegates to pi's live
		// AutocompleteProvider with a FRESH AbortSignal per call (supersession + per-request
		// timeout). Idempotent (Map.set) — one handler instance (and its closure-scoped
		// `pendingAbort`) per session, safe across reload/new/resume/fork (research §3/§6).
		registerBridgeHandler(
			"getSuggestions",
			makeGetSuggestionsHandler({ getProvider }), // timeoutMs defaults to GET_SUGGESTIONS_TIMEOUT_MS
		);
		// S12: register `applyCompletion` AFTER `getSuggestions` (so the provider is captured
		// and the token exists) and AFTER startBridge. The handler delegates to pi's live
		// AutocompleteProvider.applyCompletion SYNCHRONOUSLY (pi's impl is a pure SYNC
		// function — autocomplete.ts:256-271, verified). It has NO AbortController, NO
		// supersession, NO timeout, NO closure state — plain delegation. Idempotent
		// (Map.set) — safe across reload/new/resume/fork (research §3/§6).
		registerBridgeHandler(
			"applyCompletion",
			makeApplyCompletionHandler({ getProvider }),
		);
		// S13: register `shouldTriggerFileCompletion` AFTER `applyCompletion` (so the provider is
		// captured and the token exists) and AFTER startBridge. The handler delegates to pi's live
		// AutocompleteProvider.shouldTriggerFileCompletion SYNCHRONOUSLY via `?.` + `?? true` (the
		// method is OPTIONAL on the interface; `?? true` is pi's documented default — absent method
		// ⇒ ALLOW file completion). It has NO AbortController, NO supersession, NO timeout, NO
		// closure state — plain delegation. Idempotent (Map.set) — safe across
		// reload/new/resume/fork (research §3/§6).
		registerBridgeHandler(
			"shouldTriggerFileCompletion",
			makeShouldTriggerFileCompletionHandler({ getProvider }),
		);
		// S14: register `ping` / `bye` / `getCommands` AFTER `shouldTriggerFileCompletion`
		// (so the provider is captured and the token exists) and AFTER startBridge.
		// `ping` (SYNC): liveness/diagnostics handler returning PingResult (HelloResult +
		// pid); NO token dep (the S10 gate already guarantees handshakeComplete===true).
		// `bye` (SYNC): graceful-disconnect ack returning {ok:true} AND setting
		// state.closeAfterResponse so handleLine half-closes after flushing the ack
		// (approach (a); mirrors the fatal-close pattern). `getCommands` (ASYNC):
		// derives the full command list from provider.getSuggestions(["/"],0,1) on the
		// captured provider (covers builtins + templates + extensions + skills);
		// argumentHint is unrecoverable and left undefined (documented limitation).
		// All three are idempotent (Map.set) — safe across reload/new/resume/fork.
		registerBridgeHandler(
			"ping",
			makePingHandler({ getPid, getCwd, getFdAvailable, version: BRIDGE_VERSION }),
		);
		registerBridgeHandler("bye", makeByeHandler());
		registerBridgeHandler(
			"getCommands",
			makeGetCommandsHandler({ getProvider }),
		);
		// (S14 DONE). S16 writes the BridgeDescriptor to process.env.PI_EDITOR_BRIDGE
		// at the end of startBridge above (the discovery the Neovim plugin reads).
		//
		// S17: broadcast `commandsChanged` (S→C notification) to every connected,
		// handshaken editor so it can invalidate its command cache (the provider was
		// just rebuilt on this reload/new/resume/fork). Downstream consumers:
		// P2.M5.T16.S27 (Neovim notification handler) + P3.M10.T26.S41 (cache
		// invalidation). Guarded by `getServer()` (PRD §6.2 "when server running" —
		// defined after startBridge). Routed through `__deps.broadcastNotification`
		// (NOT the bare import) so the wiring test can spy — startBridge's internal
		// stopBridge→closeAllConnections clears the registry before this runs, so the
		// emit's on-socket effect is structurally unobservable (documented property:
		// the registry is EMPTY at every realistic session_start — to type `/reload`
		// the TUI must be active ⇒ no external editor open — research §6.6).
		if (getServer()) __deps.broadcastNotification("commandsChanged");
	});

	pi.on("session_shutdown", (_event: SessionShutdownEvent) => {
		stopBridge(); // idempotent teardown: close server, unlink socket, clear state, delete env var.
	});
}
