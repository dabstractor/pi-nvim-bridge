import { test } from "node:test";
import assert from "node:assert/strict";
import type {
	JsonRpcError,
	JsonRpcRequest,
	JsonRpcResponse,
	JsonRpcNotification,
	BridgeDescriptor,
	HelloParams,
	HelloResult,
	PingParams,
	PingResult,
	GetSuggestionsParams,
	GetSuggestionsResult,
	ApplyCompletionParams,
	ApplyCompletionResult,
	ShouldTriggerFileCompletionParams,
	ShouldTriggerFileCompletionResult,
	GetCommandsParams,
	GetCommandsResult,
	CommandInfo,
	CommandsChangedParams,
	ByeParams,
	ByeResult,
	BridgeMethod,
	RequestMethod,
	NotificationMethod,
	BridgeParams,
	BridgeResult,
	TypedRequest,
	TypedResponse,
	TypedNotification,
} from "../protocol.ts";

// Re-export check: the two pi-tui types must be reachable through protocol.ts too.
import type {
	AutocompleteItem,
	AutocompleteSuggestions,
} from "../protocol.ts";

// ============================================================================
// TEST 1 — runtime load. protocol.ts is TYPE-ONLY (no runtime exports), so the
// critical runtime invariant is "imports via jiti with zero deps" (PRD §6.7). The
// module namespace is an empty object at runtime; assert it loaded (non-null obj).
// ============================================================================
test("protocol.ts imports cleanly via jiti (type-only module, zero runtime deps)", async () => {
	const mod = await import("../protocol.ts");
	assert.equal(typeof mod, "object", "module namespace must be an object");
	assert.notEqual(mod, null, "module must load (not null)");
});

// ============================================================================
// TEST 2 — compile-time type shapes. These declarations are validated by
// `tsc --noEmit` (Level 1). Declared INSIDE the test body (not module-level) so they
// are not unused locals. A few feed assert.equal for runtime signal.
// ============================================================================
test("wire type shapes compile and round-trip key literals", () => {
	// --- §A raw envelopes ---
	const req: JsonRpcRequest = {
		jsonrpc: "2.0",
		id: "1",
		method: "hello",
		params: {},
	};
	const resOk: JsonRpcResponse = { jsonrpc: "2.0", id: "1", result: { ok: true } };
	const err: JsonRpcError = { code: -32600, message: "bad token" };
	const resErr: JsonRpcResponse = { jsonrpc: "2.0", id: "1", error: err };
	const notif: JsonRpcNotification = {
		jsonrpc: "2.0",
		method: "commandsChanged",
		params: {},
	};
	assert.equal(req.jsonrpc, "2.0");
	assert.equal(err.code, -32600);

	// --- §B descriptor ---
	const desc: BridgeDescriptor = {
		transport: "unix",
		path: "/tmp/pi-nvim-bridge-x.sock",
		token: "deadbeef",
		pid: 4242,
		cwd: "/home/u/proj",
		fdAvailable: true,
		serverVersion: "0.1.0",
	};
	assert.equal(desc.transport, "unix");

	// --- §C per-method params/results ---
	const hello: HelloParams = {
		token: "deadbeef",
		client: "pi-bridge.nvim",
		clientVersion: "0.1.0",
	};
	const helloRes: HelloResult = {
		ok: true,
		serverVersion: "0.1.0",
		cwd: "/home/u/proj",
		fdAvailable: true,
	};
	const ping: PingParams = {};
	const pingRes: PingResult = {
		ok: true,
		pid: 4242,
		cwd: "/home/u/proj",
		fdAvailable: true,
		serverVersion: "0.1.0",
	};

	// --- §17.10 OPTIONAL advisory shell fields (PRD §17.10.1/§7.10.2) ---
	// (a) BridgeDescriptor ACCEPTS the three optional shell fields:
	const descWithShell: BridgeDescriptor = {
		transport: "unix",
		path: "/tmp/x.sock",
		token: "deadbeef",
		pid: 1,
		cwd: "/p",
		fdAvailable: true,
		serverVersion: "0.1.0",
		shell: "/bin/zsh",
		shellSource: "pi",
		shellPath: "/bin/zsh",
	};
	assert.equal(descWithShell.shell, "/bin/zsh");

	// (b) HelloResult ACCEPTS the mirror:
	const helloWithShell: HelloResult = {
		ok: true,
		serverVersion: "0.1.0",
		cwd: "/p",
		fdAvailable: true,
		shell: "/bin/bash",
		shellSource: "default",
	};
	assert.equal(helloWithShell.shellSource, "default");

	// (c) PingResult ACCEPTS the mirror:
	const pingWithShell: PingResult = {
		ok: true,
		pid: 1,
		cwd: "/p",
		fdAvailable: true,
		serverVersion: "0.1.0",
		shell: "/bin/sh",
		shellSource: "$SHELL",
	};
	assert.equal(pingWithShell.shellSource, "$SHELL");

	// (d) shellSource accepts EACH union member (compile-time union exhaustiveness):
	const src: "pi" | "$SHELL" | "default" = "$SHELL";
	const dPi: BridgeDescriptor = { transport: "unix", path: "/", token: "t", pid: 0, cwd: "/", fdAvailable: false, serverVersion: "0", shellSource: "pi" };
	const dEnv: BridgeDescriptor = { transport: "unix", path: "/", token: "t", pid: 0, cwd: "/", fdAvailable: false, serverVersion: "0", shellSource: "$SHELL" };
	const dDef: BridgeDescriptor = { transport: "unix", path: "/", token: "t", pid: 0, cwd: "/", fdAvailable: false, serverVersion: "0", shellSource: "default" };
	assert.equal(src, "$SHELL");
	// NOTE: the existing `desc`/`helloRes`/`pingRes` literals above (WITHOUT shell
	// fields) are the proof that the new fields are OPTIONAL and every existing
	// producer still type-checks (the back-compat guarantee).
	const gsParams: GetSuggestionsParams = {
		lines: ["/mo"],
		cursorLine: 0,
		cursorCol: 3,
		force: false,
	};
	const gsRes: GetSuggestionsResult = {
		items: [{ value: "/model", label: "/model", description: "Switch model" }],
		prefix: "/mo",
	};
	const gsNull: GetSuggestionsResult = null;
	const acParams: ApplyCompletionParams = {
		lines: ["/mo"],
		cursorLine: 0,
		cursorCol: 3,
		item: { value: "/model", label: "/model" },
		prefix: "/mo",
	};
	const acRes: ApplyCompletionResult = {
		lines: ["/model "],
		cursorLine: 0,
		cursorCol: 7,
	};
	const stParams: ShouldTriggerFileCompletionParams = {
		lines: ["/set"],
		cursorLine: 0,
		cursorCol: 4,
	};
	const stRes: ShouldTriggerFileCompletionResult = false;
	const gcParams: GetCommandsParams = {};
	const ci: CommandInfo = {
		name: "/model",
		description: "Switch model",
		argumentHint: "<provider/id>",
	};
	const gcRes: GetCommandsResult = { commands: [ci] };
	const ccParams: CommandsChangedParams = {};
	const byeParams: ByeParams = {};
	const byeRes: ByeResult = { ok: true };
	assert.equal(byeRes.ok, true);

	// --- re-exported pi-tui types are usable through protocol.ts ---
	const item: AutocompleteItem = { value: "@/a.ts", label: "a.ts" };
	const sugg: AutocompleteSuggestions = { items: [item], prefix: "@/a" };
	assert.equal(sugg.items.length, 1);

	// --- §D method union + mapped types ---
	const m: BridgeMethod = "getSuggestions";
	const rm: RequestMethod = "bye"; // commandsChanged is NOT a request method
	const nm: NotificationMethod = "commandsChanged";
	const bp: BridgeParams<"getSuggestions"> = {
		lines: [],
		cursorLine: 0,
		cursorCol: 0,
	};
	const br: BridgeResult<"hello"> = {
		ok: true,
		serverVersion: "0.1.0",
		cwd: "/",
		fdAvailable: true,
	};

	// --- narrowed envelopes ---
	const treq: TypedRequest<"ping"> = {
		jsonrpc: "2.0",
		id: "2",
		method: "ping",
		params: {},
	};
	const tres: TypedResponse<"ping"> = {
		jsonrpc: "2.0",
		id: "2",
		result: {
			ok: true,
			pid: 1,
			cwd: "/",
			fdAvailable: true,
			serverVersion: "0.1.0",
		},
	};
	const tnotif: TypedNotification = {
		jsonrpc: "2.0",
		method: "commandsChanged",
		params: {},
	};
	assert.equal(treq.method, "ping");
});
