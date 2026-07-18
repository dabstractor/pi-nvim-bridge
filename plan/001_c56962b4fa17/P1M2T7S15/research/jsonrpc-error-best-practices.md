# Research: JSON-RPC 2.0 Handler Error-Wrapping Best Practices

> **Scope:** Informing the design of a TypeScript extension that wraps **every** RPC method
> handler in error handling that returns a **proper JSON-RPC 2.0 error response** instead of
> propagating exceptions or producing malformed responses. Specific cases to cover:
> (a) handlers that delegate to a possibly-unavailable dependency (e.g. a provider/service that
> was never captured) and (b) handlers that delegate to an engine/runtime that may throw.
>
> **Sourcing caveat (read first):** The `web_search` / `fetch_content` research tools were **not
> available** in this run (the runtime reported them as unloaded), so the URLs below could not be
> live-fetched. They point at the canonical, stable specification locations and are accurate to the
> published specs as of training knowledge. Treat the exact fragment anchors as "navigate to the
> section named" rather than guaranteed-deep links; re-verify before pasting into public docs.

---

## Summary

JSON-RPC 2.0 defines five reserved error codes (`-32700`, `-32600`, `-32601`, `-32602`, `-32603`)
plus an implementation-defined **Server error** range `-32000..-32099`. The mature, well-attested
pattern (used by Microsoft's `vscode-jsonrpc` for LSP and the MCP TypeScript SDK) is: **await each
handler inside a try/catch at the dispatch layer**, map known/domain errors to specific codes,
sanitize the message sent to the client (no stacks, no internal paths), log full detail server-side,
**and** keep a top-level catch-all so an escaping exception never crashes the transport or returns a
non-conformant response. For an unexpected handler failure (engine throw, missing dependency), use
**`-32603 Internal error`** with a generic message by default; reserve **`-32000..-32099`** for
*known, distinguished* server/domain failure modes you actually want to branch on (e.g.
"dependency unavailable", "not initialized").

---

## 1. Official JSON-RPC 2.0 Error Codes (authoritative table)

Source: the JSON-RPC 2.0 specification, "Error object" section —
<https://www.jsonrpc.org/specification#error_object>. The spec defines a structured `error` object
of shape `{ code: number; message: string; data?: any }` where `code` is an integer.

The spec reserves two ranges:
- **Predefined errors:** `-32768` to `-32000` (of which only five concrete codes are defined; the
  gaps are "reserved for future use").
- **Implementation-defined server errors:** `-32000` to `-32099` inclusive (reserved for the
  implementation/server to define its own error codes).
- Everything else (`-32767 .. -32000` outside the predefined set, and the positive/other ranges)
  is "available for application defined errors."

| Code             | Message            | Spec-defined meaning (verbatim intent)                                                                                                            | Who emits it                                                |
|------------------|--------------------|---------------------------------------------------------------------------------------------------------------------------------------------------|-------------------------------------------------------------|
| `-32700`         | Parse error        | "Invalid JSON was received by the server. An error occurred on the server while parsing the JSON text."                                            | Transport/parser — before any handler runs.                 |
| `-32600`         | Invalid Request    | "The JSON sent is not a valid Request object." (well-formed JSON but not a conformant request, e.g. wrong `jsonrpc` version, missing `method`.)   | Request validator — before dispatch.                        |
| `-32601`         | Method not found   | "The method does not exist / is not available."                                                                                                   | Dispatcher, when no handler is registered for `method`.     |
| `-32602`         | Invalid params     | "Invalid method parameter(s)." (right method, wrong/missing/ill-typed args.)                                                                       | The handler (param validation) or a validation layer.       |
| `-32603`         | Internal error     | "Internal JSON-RPC error." — the generic catch-all for a server-side fault that has no more specific code.                                         | The handler/dispatcher catch-all.                           |
| `-32000..-32099` | Server error       | Reserved for **implementation-defined** server errors. The server defines the specific meaning of each code in this range (data is up to you).      | The handler, for distinguished domain failure modes.        |

Key invariants from the spec:
- `code` **MUST** be an integer; `message` **MUST** be a string.
- On error the response object is `{ jsonrpc: "2.0", id, error: {...} }` and **MUST NOT** contain a
  `result` member — a response has exactly one of `result` or `error`
  (<https://www.jsonrpc.org/specification#response_object>).
- Notifications (`id` absent) get **no response at all**, error or otherwise
  (<https://www.jsonrpc.org/specification#notification>).

---

## 2. `-32603` vs `-320xx`: which one for internal/domain handler failures?

**Recommendation:** default to **`-32603 Internal error`** for *unexpected* handler failures, and
use **`-32000..-32099`** only for *expected, distinguished* domain failure modes you intend for
clients (or your own logging) to react to differently.

Justification, grounded in how the two flagship JSON-RPC families behave:

**Language Server Protocol (LSP)** —
<https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#errorCodes>
- LSP reuses the five JSON-RPC predefined codes verbatim, including `-32603 InternalError` as the
  generic handler fault code.
- LSP carves specific codes out of the server-error range for **named, well-known** states, e.g.
  `-32002 ServerNotInitialized` and `-32001 UnknownErrorCode`, and explicitly states the
  `-32000..-32099` block is "reserved for server defined errors."
- LSP also reserves its **own** `-32800..-32899` band for protocol-level conditions such as
  `-32800 RequestCancelled` and `-32801 ContentModified`.
- Net: LSP uses `-32603` as the generic internal fault and a `-32xxx` code **only** when there is a
  specific, named protocol condition to signal — exactly the "default generic, promote only when it
  carries meaning" discipline.

**Model Context Protocol (MCP)** —
<https://spec.modelcontextprotocol.io/specification/2025-06-18/basic/errors/> (also
<https://modelcontextprotocol.io/specification/server/errors>)
- MCP adopts the five JSON-RPC predefined codes (`-32700`…`-32603`) and additionally states that
  implementations should reserve/use the `-32000..-32099` range for implementation-defined server
  errors, mirroring JSON-RPC.
- MCP is explicit that **invalid parameters from the client** map to `-32602 InvalidParams`
  (parameter problems are the client's fault, not an internal failure), reserving server-side codes
  for server-side problems.

**Decision rule for your extension:**
- Engine/runtime throws an *unexpected* exception, or a dependency that should have been present is
  missing → **`-32603 Internal error`**, generic sanitized message. This is the safe, spec-blessed
  catch-all; it tells the client "the server failed, retry or report" without inventing taxonomy.
- You *intentionally* want to distinguish, e.g., "dependency unavailable / not initialized" from a
  crash → assign a **single, documented** `-32000` (e.g. `-32000 "Server unavailable"`) or
  `-32002`-style code. Don't spray dozens of `-320xx` codes you'll never act on; each custom code
  must justify its existence by enabling distinct client behavior.

Why not always `-320xx`? Inventing a custom code for "the engine threw" buys nothing over `-32603`
— the client cannot meaningfully branch on it — and it scatters your taxonomy. `-32603` is the
interoperable, expected choice for "generic internal fault." Reserve `-320xx` for *named* states.

---

## 3. Wrapping ASYNC handlers (Promise rejection → JSON-RPC error)

**A single `await` inside a try/catch at the dispatch layer is sufficient and is the dominant
pattern.** Awaiting a rejecting promise turns the rejection into a synchronous `throw` caught by
the surrounding `try`, and the *consumed* rejection does **not** become an unhandled rejection.
You do **not** need an additional `.catch()` *if* you reliably `await` every handler.

Where `.catch()` / explicit guards still matter:
- If the dispatcher supports **fire-and-forget** or stores the promise without awaiting (it
  shouldn't for request/response), then you must attach a `.catch()` to avoid an
  `unhandledRejection`.
- If a handler can be **synchronous** (throw before returning a promise), the same try/catch still
  catches it — keep one try/catch that `await`s the call; it covers both sync throws and async
  rejections.

This matches Microsoft's `vscode-jsonrpc` (the LSP transport implementation,
<https://github.com/microsoft/vscode-languageserver-node/tree/main/jsonrpc>): message handlers are
invoked and `await`ed within an error-handling wrapper that converts thrown errors (sync or from a
rejected promise) into a `ResponseError` carrying the JSON-RPC code, with a top-level safety net in
the connection's message loop. The MCP TypeScript SDK
(<https://github.com/modelcontextprotocol/typescript-sdk>) follows the same shape: registered
request handlers are awaited inside a try/catch that maps thrown values to JSON-RPC errors.

**Recommended TypeScript sketch (dispatch + top-level safety net):**

```ts
// ---- 1. Error taxonomy ---------------------------------------------------

/** A typed domain error that already knows its JSON-RPC code + *sanitized* message. */
export class RpcServerError extends Error {
  constructor(
    readonly code: number,          // -32603, or a -32000..-32099 code you define
    readonly publicMessage: string, // safe to send to the client (no stacks/paths)
    cause?: unknown,
  ) {
    super(publicMessage, { cause });
    this.name = "RpcServerError";
  }
}

const DEFAULT_ERROR: RpcError = { code: -32603, message: "Internal error" };

// Map *any* thrown value to a client-safe JSON-RPC error object.
function toRpcError(err: unknown): RpcError {
  // Known, intentional domain errors: trust the code + message.
  if (err instanceof RpcServerError) {
    return { code: err.code, message: err.publicMessage };
  }
  // Client-side problems surfaced from validation helpers:
  if (err instanceof InvalidParamsError) {
    return { code: -32602, message: "Invalid params", data: err.details };
  }
  // Anything else is an internal fault: log full detail server-side,
  // return a generic message to the client (see §4 sanitization).
  log.error("Unhandled handler failure", { err }); // full stack stays server-side
  return { ...DEFAULT_ERROR };
}

// ---- 2. Per-handler dispatch (await inside try/catch) --------------------

async function dispatch(req: JsonRpcRequest, ctx: Ctx): Promise<JsonRpcResponse> {
  const handler = handlers.get(req.method);
  if (!handler) {
    return errorResponse(req.id, { code: -32601, message: "Method not found" });
  }
  // ONE try/catch around the awaited call covers BOTH sync throws AND
  // rejected promises. No separate .catch() needed.
  try {
    const result = await handler(req.params, ctx);
    return successResponse(req.id, result);
  } catch (err) {
    return errorResponse(req.id, toRpcError(err));
  }
}

// ---- 3. Top-level safety net (defense in depth, §5) ----------------------

async function handleMessage(raw: string, ctx: Ctx): Promise<string | null> {
  // Parse error (malformed JSON) -> -32700. Caught by the same net.
  let parsed: unknown;
  try {
    parsed = JSON.parse(raw);
  } catch {
    return JSON.stringify(errorResponse(null, { code: -32700, message: "Parse error" }));
  }

  // Notifications have no `id` -> respond with nothing, per spec.
  if (isNotification(parsed)) {
    void dispatchOrDropNotification(parsed); // still guarded by a .catch()
    return null;
  }

  // The per-handler try/catch inside dispatch handles handler faults;
  // this outer catch is the safety net for anything that escapes
  // (serialization, a bug in the dispatcher itself, etc.).
  try {
    const resp = await dispatch(parsed as JsonRpcRequest, ctx);
    return JSON.stringify(resp);
  } catch (err) {
    log.error("Top-level catch-all hit (unexpected)", { err });
    const id = (parsed as { id?: JsonRpcId })?.id ?? null;
    return JSON.stringify(errorResponse(id, { ...DEFAULT_ERROR }));
  }
}
```

Concrete application to your two cases, inside a handler:

```ts
handlers.set("engine/run", async (params, ctx) => {
  // (a) Possibly-unavailable dependency: "provider not captured."
  if (!ctx.provider) {
    // Distinguished, named domain state -> a -320xx code is justified here.
    throw new RpcServerError(-32000, "Service unavailable");
  }
  // (b) Delegated engine call that may throw.
  try {
    return await ctx.engine.run(params);
  } catch (err) {
    // Unexpected runtime fault. Don't invent taxonomy; let toRpcError()
    // collapse it to a sanitized -32603 Internal error.
    throw err;
  }
});
```

---

## 4. Error message hygiene: sanitize before sending

**Best practice: return generic, sanitized messages to clients; log full detail server-side.**
Do **not** put raw stack traces, internal file paths, hostnames, SQL, or implementation type names
into the wire `message`. These leak architecture (dependency names, library versions, filesystem
layout) and are a recognized information-disclosure risk.

How the flagship specs treat it:
- The JSON-RPC spec leaves `message` free-form but defines `data` as the optional place for
  *additional* detail (<https://www.jsonrpc.org/specification#error_object>). In practice, `data`
  should also be scrubbed — it is sent to the client.
- LSP defines `ResponseError` as `{ code; message; data? }`
  (<https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#responseMessage>);
  production servers keep `message` short and human-readable (e.g. `"Internal error"`,
  `"Method not found"`) and avoid leaking internals.
- MCP likewise keeps client-facing error strings concise and reserves verbose diagnostics for
  server logs; it never expects raw server stacks on the wire.

Concretely:
- For `-32601 Method not found`: `message: "Method not found"` (optionally echo the method name —
  the client already sent it, so it's not a leak).
- For `-32602 Invalid params`: `message: "Invalid params"` with `data` listing which fields failed
  (this is helpful and low-risk, since it echoes client input).
- For `-32603 Internal error` / any unexpected fault: `message: "Internal error"`. **Never** the
  raw `err.message` (which may be `"Cannot read properties of undefined (reading 'foo')"` revealing
  internal structure). Log the real error + stack on the server.

If you ever need a correlation between client and server logs, put an **opaque** id in `data`
(e.g. `data: { traceId: "…" }`) — useful, not leaky.

---

## 5. Defense in depth: per-handler wrap **and** top-level safety net

**Yes — production JSON-RPC servers do both, and your extension should too.** The two layers have
distinct jobs:

1. **Per-handler / dispatch try/catch** — the *intentional* error boundary. It awaits the handler,
   catches rejections, and maps each error to the *most specific* appropriate code (`-32602`,
   `-32601`, a `-320xx` domain code, or `-32603`). This is where domain knowledge lives.
2. **Top-level catch-all** — the *unintentional* error boundary. It catches anything that escaped
   layer 1 (a bug in the dispatcher, JSON serialization throwing, an error thrown before a handler
   even exists) and guarantees the transport never crashes and never emits a non-conformant
   response. It returns a generic `-32603` and logs loudly, because hitting it means a real bug.

Why both? The per-handler layer can only wrap code it actually calls; if *it* or the framing/parse
step throws, only the top-level net keeps the process alive and the response spec-conformant. The
top-level net is intentionally dumb (generic `-32603`) because by definition you didn't expect to
reach it, so you have no trustworthy domain mapping to apply.

**Cited examples of this layered pattern:**
- **`vscode-jsonrpc` (Microsoft, the LSP transport)** —
  <https://github.com/microsoft/vscode-languageserver-node/tree/main/jsonrpc>. The connection's
  message loop is guarded by a top-level handler that logs and swallows to keep the process alive,
  while individual request handlers are invoked inside an error wrapper that converts thrown
  `ResponseError`s (carrying the JSON-RPC code) into error responses. This is the canonical
  "per-handler mapping + top-level net" implementation in the ecosystem.
- **MCP TypeScript SDK** —
  <https://github.com/modelcontextprotocol/typescript-sdk>. The `Server` invokes registered
  request/notification handlers awaited within try/catch; thrown errors are normalized to JSON-RPC
  error responses, with the SDK's transport loop providing the outer guard.
- **`jayson` (Node JSON-RPC server)** — <https://github.com/tedeh/jayson>. Method callbacks receive
  an error-first nodeback; the dispatcher wraps execution so a thrown handler error becomes an
  error response rather than crashing the server.

---

## 6. Direct recommendation for the two target cases

Your handlers delegate to (a) a **possibly-unavailable dependency** ("provider not captured") and
(b) an **engine/runtime that may throw**. "Proper" codes + messages:

| Situation                                            | Recommended code                | Wire `message` (sanitized)               | Rationale                                                                                       |
|------------------------------------------------------|---------------------------------|-------------------------------------------|------------------------------------------------------------------------------------------------|
| Dependency/provider genuinely absent (not captured) | `-32000` (Server error) **or** `-32603` | `"Service unavailable"` / `"Internal error"` | A known, named degraded-state condition — a `-320xx` code is justified **iff** you branch on it; otherwise `-32603`. |
| Engine/runtime throws an *unexpected* exception      | `-32603` Internal error         | `"Internal error"`                        | Generic, interoperable catch-all; no reason to invent a `-320xx` for an unmodeled fault.        |
| Engine throws a *known, modeled* domain error        | a chosen `-32000..-32099` code  | short domain string                       | Only when the client should behave differently (e.g. retry vs. abort).                         |
| Handler receives bad/missing params (client fault)   | `-32602` Invalid params         | `"Invalid params"` + `data` with field hints | Parameters are the client's responsibility — not an internal/server failure.                    |
| No handler registered for `method`                   | `-32601` Method not found       | `"Method not found"`                      | Dispatcher-level, before the handler.                                                          |
| Malformed JSON on the wire                           | `-32700` Parse error            | `"Parse error"`                           | Parser-level, before dispatch.                                                                 |
| Anything escapes both layers (should not happen)     | `-32603` Internal error         | `"Internal error"`                        | Top-level safety net keeps transport alive + response conformant.                              |

**Implementation posture (one-liner):** wrap every awaited handler in a try/catch at the dispatch
layer; map known domain errors to specific codes; collapse everything else into a sanitized
`-32603`; keep a top-level catch-all; log full detail server-side; never put stacks/paths in the
wire message.

---

## Sources

Kept (canonical / authoritative):
- **JSON-RPC 2.0 Specification — Error object** — <https://www.jsonrpc.org/specification#error_object>
  — defines the code table and the `-32000..-32099` server-error reservation; the authoritative
  source for questions 1 and 4.
- **JSON-RPC 2.0 Specification — Response object / Notification** —
  <https://www.jsonrpc.org/specification#response_object>,
  <https://www.jsonrpc.org/specification#notification> — response shape invariants and the
  "notifications get no response" rule.
- **LSP Specification 3.17 — Error codes** —
  <https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#errorCodes>
  — shows LSP reusing `-32603` as the generic internal fault and reserving `-32000..-32099` for
  *named* server-defined states (`ServerNotInitialized` `-32002`, `UnknownErrorCode` `-32001`),
  plus the LSP-owned `-32800..-32899` band (`RequestCancelled`, `ContentModified`). Directly
  answers question 2.
- **LSP Specification 3.17 — Response message (`ResponseError` shape)** —
  <https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#responseMessage>
  — `{ code; message; data? }` shape informing message hygiene (question 4).
- **MCP Specification — Errors** —
  <https://spec.modelcontextprotocol.io/specification/2025-06-18/basic/errors/> — MCP adopts the
  five JSON-RPC codes, routes client param faults to `-32602`, and points to `-32000..-32099` for
  implementation-defined server errors. Supports questions 2 and 4.
- **`vscode-jsonrpc` (Microsoft)** —
  <https://github.com/microsoft/vscode-languageserver-node/tree/main/jsonrpc> — canonical LSP
  transport implementation; demonstrates per-handler `ResponseError` mapping plus a guarded message
  loop (questions 3 and 5).
- **MCP TypeScript SDK** — <https://github.com/modelcontextprotocol/typescript-sdk> — awaited
  request handlers wrapped in try/catch normalizing to JSON-RPC errors; outer transport guard
  (questions 3 and 5).
- **`jayson` (Node JSON-RPC server)** — <https://github.com/tedeh/jayson> — error-first handler
  dispatch that converts thrown handler errors into error responses (question 5).

Dropped:
- Generic "what is JSON-RPC" tutorials / SEO explainer pages — superseded by the primary spec.
- Unofficial blog posts restating the code table without added design guidance — redundant.

---

## Gaps

- **Live verification not possible.** `web_search` / `fetch_content` were unavailable in this run,
  so the exact fragment anchors and the precise text of the MCP errors section could not be
  confirmed by fetching. The *substance* (code numbers, ranges, and the LSP/MCP conventions) is
  stable and well-established, but **before publishing any of these URLs or copying exact spec
  wording, re-fetch** the canonical pages to confirm anchors (MCP's spec site in particular has
  moved version-segmented paths over time).
- **Exact MCP-specific numeric codes** beyond the standard five were kept deliberately general to
  avoid stating codes that may differ by MCP spec version; verify against the current MCP spec
  page if you plan to emit MCP-specific `-320xx` values.
- **No measurement of real-world client behavior** (e.g., how the Pi/nvim client treats `-32603`
  vs `-32000`) — that's a client-side question outside this research and should be checked against
  the consuming client's docs.
- Suggested next steps: (1) fetch the four spec URLs above to lock the anchors; (2) read
  `vscode-jsonrpc`'s connection.ts to mirror its exact top-level guard naming; (3) confirm the
  consuming client's handling of the chosen codes.
