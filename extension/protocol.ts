/**
 * protocol.ts — the JSON-RPC 2.0 IPC contract between the pi-nvim-bridge
 * extension (server, pi side) and the pi-bridge.nvim plugin (client, Neovim side).
 *
 * Transport: Unix domain socket. Framing: strict JSONL — exactly one JSON object per
 * line, delimited by `\n` only (strip an optional trailing `\r`; do NOT use readers
 * that split on U+2028/U+2029). The authoritative framing mirror is pi's own
 * `dist/modes/rpc/jsonl.js` (serializeJsonLine = `${JSON.stringify(v)}\n`; split on
 * `buffer.indexOf("\n")`; never Node readline) — IMPLEMENTED by the JSONL reader task
 * (S7), not here. This module is TYPES-ONLY.
 *
 * Wire references: PRD §5 (IPC Protocol) — §5.3 envelopes + handshake, §5.4 methods
 * table, §5.5 timing. PRD §6.4 BridgeDescriptor skeleton (serverVersion hardcode
 * "0.1.0"). PRD §8 coordinate/encoding contract (cursorCol = UTF-16 offset; the
 * numeric type is `number` here; the conversion lives in the Lua coords module).
 *
 * STATUS (P1.M1.T2.S4): types-only. Wiring into the extension (socket server, env
 * advertisement) lands in M2 / S16. Re-exports pi-tui's autocomplete types so the wire
 * format stays byte-identical to pi's engine.
 *
 * Loaded via jiti (TS works without compilation). Type-only => zero runtime exports.
 */
import type {
	AutocompleteItem,
	AutocompleteSuggestions,
} from "@earendil-works/pi-tui";

/** Re-export pi's autocomplete wire types so consumers import them from one place. */
export {
	type AutocompleteItem,
	type AutocompleteSuggestions,
} from "@earendil-works/pi-tui";

/* ==========================================================================
 * §A — Raw JSON-RPC 2.0 envelopes (the shape a JSONL line parses into BEFORE
 *      method-based narrowing). jsonrpc is the literal "2.0" (compile-time version
 *      check); id is string (PRD §5 restricts to string — not number/null); params?/
 *      result? are `unknown` to force consumers to narrow.
 *      JSON-RPC 2.0 spec error codes (for later runtime code, S9/S15): -32700 parse,
 *      -32600 invalid request, -32601 method not found, -32602 invalid params,
 *      -32603 internal error. PRD §5.3 uses -32600 "bad token" for handshake failure.
 * ========================================================================== */

/** Error object carried inside an error response (NO `data` field — keep minimal). */
export interface JsonRpcError {
	code: number;
	message: string;
}

/** Client→Server request envelope. */
export interface JsonRpcRequest {
	jsonrpc: "2.0";
	id: string;
	method: string;
	params?: unknown;
}

/**
 * Server→Client response envelope — a discriminated union: success carries `result`,
 * failure carries `error`. Exactly one of `result`/`error` is present on the wire.
 */
export type JsonRpcResponse =
	| { jsonrpc: "2.0"; id: string; result?: unknown }
	| { jsonrpc: "2.0"; id: string; error: JsonRpcError };

/** Notification envelope (S→C or C→S); carries NO id and expects NO reply. */
export interface JsonRpcNotification {
	jsonrpc: "2.0";
	method: string;
	params?: unknown;
}

/* ==========================================================================
 * §B — BridgeDescriptor: JSON-serialized to process.env.PI_NVIM_BRIDGE (S16) and
 *      vim.json.decode'd by the Neovim activation gate (PRD §7.1). MUST be a plain
 *      JSON object (JSON-serializable). The 7 base fields above are required;
 *      the §17.10 shell.* fields are OPTIONAL and ADVISORY — absent on older
 *      builds/clients is fine, the plugin falls back to $SHELL (PRD §17.10.2).
 *      `transport:"unix"` is a v1 literal; PRD §5.1 names a future TCP variant —
 *      extend as a discriminated union on `transport` when that lands.
 *      Field value sources: path=socketPath; token=randomUUID-derived (the REAL auth
 *      boundary, PRD §12); pid=process.pid; cwd=ctx.cwd; fdAvailable=fd resolved;
 *      serverVersion=bridge version string (PRD §6.4 hardcodes "0.1.0").
 * ========================================================================== */
export interface BridgeDescriptor {
	transport: "unix";
	path: string;
	token: string;
	pid: number;
	cwd: string;
	fdAvailable: boolean;
	serverVersion: string;
	// §17.10 (NEW) — OPTIONAL, advisory shell info so the plugin's !/!! completion
	// can match the shell pi executes commands in (prefer:"pi"). Absent on older
	// builds/clients is fine — the plugin falls back to $SHELL (PRD §17.10.2).
	shell?: string; // "/bin/zsh" — resolved execution shell binary
	shellSource?: "pi" | "$SHELL" | "default"; // how `shell` was derived
	shellPath?: string; // raw shellPath setting, if the user set one
}

/* ==========================================================================
 * §C — Per-method params/result types. Field names/types match PRD §5.4 EXACTLY.
 *      `ok` is the literal `true` on success results. Empty `{}` params/results use
 *      Record<string, never> (the correct TS "empty object"; `{}` is unsafe).
 *      AutocompleteItem/AutocompleteSuggestions come from pi-tui (re-exported above).
 * ========================================================================== */

/** `hello` (C→S): client proves it has the token from process.env. */
export interface HelloParams {
	token: string;
	client?: string;
	clientVersion?: string;
}
/** `hello` (C→S) success result: server identity + capabilities. (+ optional
 *  §17.10 advisory shell.* mirror; plugin falls back to $SHELL if absent.) */
export interface HelloResult {
	ok: true;
	serverVersion: string;
	cwd: string;
	fdAvailable: boolean;
	// §17.10 (NEW) — OPTIONAL advisory mirror of BridgeDescriptor.shell* (PRD §17.10.1:
	// "the hello result mirrors these"). Lets the plugin read the resolved shell
	// post-handshake; falls back to $SHELL if absent.
	shell?: string;
	shellSource?: "pi" | "$SHELL" | "default";
	shellPath?: string;
}

/** `ping` (C→S): empty params. */
export type PingParams = Record<string, never>;
/** `ping` (C→S) result: liveness + server info. (+ optional §17.10 advisory
 *  shell.* mirror; plugin falls back to $SHELL if absent.) */
export interface PingResult {
	ok: true;
	pid: number;
	cwd: string;
	fdAvailable: boolean;
	serverVersion: string;
	// §17.10 (NEW) — OPTIONAL advisory mirror of BridgeDescriptor.shell* (PingResult
	// is HelloResult + pid). Same semantics/fallback as HelloResult.
	shell?: string;
	shellSource?: "pi" | "$SHELL" | "default";
	shellPath?: string;
}

/**
 * `getSuggestions` (C→S). cursorLine is 0-indexed; cursorCol is a 0-indexed UTF-16
 * code-unit offset into lines[cursorLine] (PRD §8). `force` forces file completion
 * (mirrors pi's Tab / shouldTriggerFileCompletion path).
 */
export interface GetSuggestionsParams {
	lines: string[];
	cursorLine: number;
	cursorCol: number;
	force?: boolean;
}
/** `getSuggestions` result: pi's suggestions, or null if none. */
export type GetSuggestionsResult = AutocompleteSuggestions | null;

/** `applyCompletion` (C→S): delegate insertion to pi for byte-identical behavior. */
export interface ApplyCompletionParams {
	lines: string[];
	cursorLine: number;
	cursorCol: number;
	item: AutocompleteItem;
	prefix: string;
}
/** `applyCompletion` result: the NEW full buffer + cursor (pi computes insertion). */
export interface ApplyCompletionResult {
	lines: string[];
	cursorLine: number;
	cursorCol: number;
}

/** `shouldTriggerFileCompletion` (C→S). */
export interface ShouldTriggerFileCompletionParams {
	lines: string[];
	cursorLine: number;
	cursorCol: number;
}
/** `shouldTriggerFileCompletion` result. */
export type ShouldTriggerFileCompletionResult = boolean;

/** `getCommands` (C→S, OPTIONAL — richer docs menus): empty params. */
export type GetCommandsParams = Record<string, never>;
/**
 * Bridge-LOCAL command descriptor for the optional `getCommands` docs menu. NOT
 * re-exported from pi (pi has no `CommandInfo` — only SlashCommandInfo, which leaks
 * internal `sourceInfo` paths). This mirrors the user-facing slice of pi's
 * BuiltinSlashCommand/SlashCommand, INTENTIONALLY EXCLUDING sourceInfo,
 * handler, and getArgumentCompletions (callables). The S14 handler maps pi's
 * SlashCommandInfo[]/BuiltinSlashCommand[] DOWN to this lean wire shape.
 */
export interface CommandInfo {
	name: string;
	description?: string;
	argumentHint?: string;
}
/** `getCommands` result. */
export interface GetCommandsResult {
	commands: CommandInfo[];
}

/** `commandsChanged` (S→C NOTIFICATION): empty params, NO result. */
export type CommandsChangedParams = Record<string, never>;

/** `bye` (C→S): empty params. */
export type ByeParams = Record<string, never>;
/** `bye` result: graceful disconnect ack. */
export interface ByeResult {
	ok: true;
}

/* ==========================================================================
 * §D — Method-name union + mapped types (the typed dispatch layer). The raw
 *      envelopes (§A) carry method:string/params?:unknown; this layer narrows them
 *      per-method so M2's dispatcher (S8) and handshake (S9) get compile-time
 *      param/result checking. commandsChanged is a notification: it has params but
 *      NO result, so it is OMITTED from BridgeResultMap and lives only in
 *      BridgeParamsMap + NotificationMethod + TypedNotification.
 * ========================================================================== */

/** All 8 method names (PRD §5.4), exact strings. */
export type BridgeMethod =
	| "hello"
	| "ping"
	| "getSuggestions"
	| "applyCompletion"
	| "shouldTriggerFileCompletion"
	| "getCommands"
	| "commandsChanged"
	| "bye";

/** C→S requests: carry an id and expect a result (everything except the notification). */
export type RequestMethod = Exclude<BridgeMethod, "commandsChanged">;
/** S→C notifications: no id, no result. */
export type NotificationMethod = "commandsChanged";

/** Maps each method to its params type. */
export interface BridgeParamsMap {
	hello: HelloParams;
	ping: PingParams;
	getSuggestions: GetSuggestionsParams;
	applyCompletion: ApplyCompletionParams;
	shouldTriggerFileCompletion: ShouldTriggerFileCompletionParams;
	getCommands: GetCommandsParams;
	commandsChanged: CommandsChangedParams;
	bye: ByeParams;
}

/** Maps each REQUEST method to its result type. commandsChanged OMITTED (no result). */
export interface BridgeResultMap {
	hello: HelloResult;
	ping: PingResult;
	getSuggestions: GetSuggestionsResult;
	applyCompletion: ApplyCompletionResult;
	shouldTriggerFileCompletion: ShouldTriggerFileCompletionResult;
	getCommands: GetCommandsResult;
	bye: ByeResult;
}

/** Params type for a given method. */
export type BridgeParams<M extends BridgeMethod> = BridgeParamsMap[M];
/** Result type for a given REQUEST method. */
export type BridgeResult<M extends RequestMethod> = BridgeResultMap[M];

/** Narrowed C→S request (typed method + typed params). */
export interface TypedRequest<M extends RequestMethod = RequestMethod> {
	jsonrpc: "2.0";
	id: string;
	method: M;
	params: BridgeParams<M>;
}

/** Narrowed S→C response (typed result OR error). */
export type TypedResponse<M extends RequestMethod = RequestMethod> =
	| { jsonrpc: "2.0"; id: string; result: BridgeResult<M> }
	| { jsonrpc: "2.0"; id: string; error: JsonRpcError };

/** Narrowed notification (typed method + typed params; no id, no result). */
export interface TypedNotification<M extends NotificationMethod = NotificationMethod> {
	jsonrpc: "2.0";
	method: M;
	params: BridgeParams<M>;
}
