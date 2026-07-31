# S15 Research — How pi's RPC engine wraps handler errors

**Investigated**: `packages/coding-agent/src/modes/rpc/rpc-mode.ts` (`handleInputLine` ~L724–800,
`handleCommand` L385+, `error()`/`success()` helpers L63–76), `rpc-types.ts` (L114–223),
`packages/coding-agent/docs/rpc.md` (Error Handling §L1249–1269). Cross-checked by grepping
the whole `packages/coding-agent/src` for `-3260x`, `RpcError`, `ErrorCode`, `"jsonrpc"`.

## TL;DR

**pi does NOT use JSON-RPC 2.0 and emits ZERO JSON-RPC error codes.** It is a custom
envelope: `{ type:"response", command:<original>, success:false, error:<message> }`. There is
no `code` field, no typed RPC error class, no per-handler wrapping — just **two** try/catches
(one for `JSON.parse`, one catch-all around `await handleCommand`). The bridge already
*diverges* from pi by using real JSON-RPC 2.0 (`{jsonrpc,id,error:{code,message}}`) with the
typed `BridgeRpcError`. So S15 should NOT literally mirror pi's error structure (there is
nothing code-based to mirror); it should build on the bridge's own `BridgeRpcError` + `-32603`
safety net.

---

## 1. The EXACT try/catch structure pi uses

`packages/coding-agent/src/modes/rpc/rpc-mode.ts`, `handleInputLine` — L724–793. Two
independent try/catches, both generic catch-alls:

### (A) Parse try/catch — L742–756

```ts
	let parsed: unknown;
	try {
		parsed = JSON.parse(line);
	} catch (parseError: unknown) {
		output(
			error(
				undefined,
				"parse",
				`Failed to parse command: ${parseError instanceof Error ? parseError.message : String(parseError)}`,
			),
		);
		await waitForRawStdoutBackpressure();
		return;
	}
```

### (B) Handler-call try/catch — L758–793 (the single safety net)

```ts
	const command = parsed as RpcCommand;
	try {
		const response = await handleCommand(command);
		if (response) {
			output(response);
			await waitForRawStdoutBackpressure();
		}
		await checkShutdownRequested();
	} catch (commandError: unknown) {
		output(
			error(
				command.id,
				command.type,
				commandError instanceof Error ? commandError.message : String(commandError),
			),
		);
		await waitForRawStdoutBackpressure();
	}
```

Notes on the structure:
- **One big catch-all around `await handleCommand(...)`** — NOT per-handler. Every command
  (`prompt`, `steer`, `new_session`, `get_state`, … ~30 cases in the switch L386–708) is
  covered by this single catch.
- **Async**: `handleCommand` is `async` and the call is `await`-ed, so a sync throw inside a
  case body and an unhandled promise rejection from an `await`ed session call are caught by
  the **same** catch. Pi does NOT distinguish sync throws from rejections.
- The catch emits `error(command.id, command.type, message)` — it reuses the ORIGINAL
  command's `id` and `type` and just stuffs `Error.message` (or `String(err)`) into `error`.
- **No code conversion.** The handler is free to `throw new Error("anything")`; whatever it
  throws becomes `error: <message>` verbatim. There is no `if (err instanceof RpcError)`
  branch.

## 2. The response helpers pi uses (L63–76)

```ts
	const success = <T extends RpcCommand["type"]>(
		id: string | undefined,
		command: T,
		data?: object | null,
	): RpcResponse => {
		if (data === undefined) {
			return { id, type: "response", command, success: true } as RpcResponse;
		}
		return { id, type: "response", command, success: true, data } as RpcResponse;
	};

	const error = (id: string | undefined, command: string, message: string): RpcResponse => {
		return { id, type: "response", command, success: false, error: message };
	};
```

This is the custom envelope: `{ id?, type:"response", command:<echo>, success:false, error:<string> }`.
The typed union in `rpc-types.ts:114–223` confirms there is no `code` field anywhere — only
`error: string`. The catch-all shape is line 223: `| { id?: string; type:"response"; command:string; success:false; error:string }`.

## 3. Is there a typed RPC error class?

**No.** Grep across `packages/coding-agent/src` for `-3260[0-9]`, `class RpcError`, `ErrorCode`,
`"jsonrpc"` returned **zero matches**. Handlers signal failure by `throw new Error(msg)` (or
by returning `success:false`) and pi flattens everything to `error: msg`. There is no
`instanceof`-checkable typed error and no way for a handler to request a specific category
of failure — the only knobs a handler has are (a) throw a `Error` with some message, or
(b) `return success(...)`/`return error(...)`.

## 4. Parse-error + unknown-command handling (the only "special" cases)

- **Parse error** (L742–756): synthesized response with `command:"parse"` (a sentinel string,
  not a numeric code) and `id:undefined`.
- **Unknown command**: handled *inside* the switch's `default` branch (L685–688), which
  returns a real `error(id, unknownCommand.type, "Unknown command: <type>")` response — it is
  a normal `success:false` response, NOT a separate error class. So unknown-command is a
  domain return, not a thrown error:
  ```ts
	default: {
		const unknownCommand = command as { type: string };
		return error(id, unknownCommand.type, `Unknown command: ${unknownCommand.type}`);
	}
	```

## 5. Documented error contract (docs/rpc.md §Error Handling, L1249–1269)

```json
// failed command
{ "type": "response", "command": "set_model", "success": false, "error": "Model not found: invalid/model" }

// parse error (command is the sentinel "parse")
{ "type": "response", "command": "parse", "success": false, "error": "Failed to parse command: Unexpected token..." }
```

The doc states only: "Failed commands return a response with `success: false`." There is no
documented error-code taxonomy, no typed-error contract, and no "how handlers should signal
failure" section beyond "throw / return success:false". The contract is: **all failures are
flattened to `{success:false, error:<message>}`**; clients key on `success` + the free-text
`error` string.

---

## 6. Summary table

| Question | pi's answer |
|---|---|
| try/catch granularity | **One parse catch + one handler-call catch-all** (not per-handler) |
| Convert throws → specific codes? | **No.** No codes at all. `Error.message` copied verbatim into `error` field |
| Typed RPC error class? | **No.** Plain `Error`; handlers `throw new Error(msg)` or `return error(...)` |
| Sync throws vs async rejections? | **Not distinguished.** `await handleCommand(...)` ⇒ single catch covers both |
| JSON-RPC error codes emitted? | **None.** pi's envelope is custom (`type/command/success/error`), not JSON-RPC 2.0 |
| Per-handler domain wrapping? | **No.** Switch cases either `return success/error` or `throw`; the outer catch is the only safety net |

## 7. What is reusable / mirrorable for the bridge

Only **one** structural pattern transfers: the **two-try/catch split** — a dedicated
parse try/catch → parse error, separate from a handler-call try/catch → error response. The
bridge (`extension/connection.ts` `handleLine`) **already mirrors this**:
- (A) parse try/catch → `sendError(sock, null, -32700, ...)` (L188–198 area)
- (D) request handler-call try/catch → `BridgeRpcError`→its `code`, else `-32603` safety net

There is **nothing else to mirror** — pi has no codes, no typed error, no per-handler
wrapping, and a different wire envelope. The bridge intentionally diverged to real JSON-RPC
2.0 with codes (per PRD §5.3), which is the *right* call and is already in place.

## 8. Recommendation for S15

**Use per-handler explicit try/catch with a shared `toBridgeRpcError(...)` converter — do NOT
mirror pi's exact structure.** Justification:

1. **Pi has nothing to copy.** Pi's "structure" is one catch-all that flattens every throw to
   `error:<msg>`. Mirroring it literally would mean deleting `BridgeRpcError` and the
   `-32603` safety net and just stuffing `Error.message` into one code — which contradicts
   the bridge's own PRD §5.3 (codes `-32700/-32600/-32601/-32602/-32603`) and the typed-error
   machinery S9 already shipped (`BridgeRpcError` + the `instanceof BridgeRpcError` branch in
   `handleLine`).
2. **The bridge's envelope is richer, on purpose.** JSON-RPC 2.0 gives clients a machine-
   readable `code`; pi's clients only get a free-text `error` string. S15's whole point is
   "wrap domain errors into proper codes" — that only makes sense in the bridge's code-based
   world, which pi's code-free world cannot inform.
3. **Keep the two-layer model.** S15 should: at each handler's domain boundary, `catch` the
   known domain error and `throw new BridgeRpcError(<right code>, <msg>)` (a tiny
   `toBridgeRpcError(domainErr) → BridgeRpcError` helper keeps this DRY and consistent). The
   existing outer catch in `handleLine` (request branch) already does the right thing:
   `instanceof BridgeRpcError` → its code; anything else → `-32603` last-resort safety net.
   That safety net **stays** — it is the direct analog of pi's catch-all, just code-aware.
4. **Per-handler wrapping is the *better* fit for the bridge.** The bridge's handlers
   (`getSuggestions`, `applyCompletion`, …) throw *heterogeneous* domain errors (provider
   errors, parse errors of params, missing-token). Each maps to a *different* code
   (`-32602` invalid params, `-32603` internal, etc.). Pi never needed this because pi has
   exactly one failure shape (`success:false`). So the bridge should do domain wrapping at
   the handler edge and let the generic safety net be a true last resort.

**Concrete shape for S15:**
- Add a converter (e.g. `toBridgeRpcError(e: unknown, opts?): BridgeRpcError` or per-domain
  mappers) that each handler wraps its body in.
- Each handler: `try { … } catch (e) { throw toBridgeRpcError(e); }` (or call sites map to a
  specific code when the domain meaning is known, e.g. bad params → `-32602`).
- Leave `handleLine`'s outer request-branch catch **unchanged** — it already routes
  `BridgeRpcError`→code and fallthrough→`-32603`. That outer catch is the bridge's pi-style
  safety net, retained.
- The notification branch (no id) already logs and swallows; S15 may optionally also route
  domain→`BridgeRpcError` there for consistent logging, but no response is ever written
  (JSON-RPC 2.0).

This preserves the one pi pattern worth keeping (parse-catch separate from handler-catch,
plus a last-resort safety net) while using the bridge's own code taxonomy that pi lacks.
