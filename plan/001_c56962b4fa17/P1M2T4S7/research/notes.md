# Research Notes — JSONL line reader (P1.M2.T4.S7)

> Work item **P1.M2.T4.S7** — "JSONL line reader — buffer partial lines, split on
> `\n` only, strip `\r`". Parent task P1.M2.T4 = "JSONL framing & connection
> handling" (S7 = framing; sibling S8 = connection handling). This is the
> **TypeScript / pi-extension side** of the bridge (NOT the Lua `jsonlreader.lua`,
> which is P2.M5.T14.S23).
>
> The PRD §16 + `extension/protocol.ts` JSDoc designate pi's own
> `packages/coding-agent/src/modes/rpc/jsonl.ts` as the **authoritative framing
> mirror** that S7 "implements". This research confirms that file's exact source,
> re-verifies every load-bearing claim on the current machine (2025-07-18), and
> locks the design decisions for the PRP.

---

## 0. Environment (verified live)

| Tool | Path / version | Note |
|---|---|---|
| `pi`  | `/home/dustin/.local/bin/pi` | global install |
| `tsc` | `/home/dustin/.local/bin/tsc` → **5.9.3** | type-check gate (Level 1) |
| `node`| `/usr/bin/node` → **v26.4.0** | runs node:test (Level 2) |
| jiti register hook | `/home/dustin/.local/lib/node_modules/@earendil-works/pi-coding-agent/node_modules/jiti/lib/jiti-register.mjs` | EXISTS — used by all existing extension tests; reused by S7 |
| @types/node | `/home/dustin/.local/lib/node_modules/@earendil-works/pi-coding-agent/node_modules/@types/node` | the Node type source (Stream/StringDecoder/Buffer) |

> jiti v2.7.0 on Node 26 prints a harmless `DeprecationWarning: module.register() is
> deprecated` to STDERR — IGNORE it; judge tests by exit code + `ℹ pass`/`ℹ fail`.

---

## 1. pi's authoritative JSONL source — read VERBATIM (the mirror)

`~/projects/pi/packages/coding-agent/src/modes/rpc/jsonl.ts` (compiled mirror at
`.../pi-coding-agent/dist/modes/rpc/jsonl.js`):

```ts
import type { Readable } from "node:stream";
import { StringDecoder } from "node:string_decoder";

export function serializeJsonLine(value: unknown): string {
	return `${JSON.stringify(value)}\n`;
}

export function attachJsonlLineReader(stream: Readable, onLine: (line: string) => void): () => void {
	const decoder = new StringDecoder("utf8");
	let buffer = "";
	const emitLine = (line: string) => {
		onLine(line.endsWith("\r") ? line.slice(0, -1) : line);
	};
	const onData = (chunk: string | Buffer) => {
		buffer += typeof chunk === "string" ? chunk : decoder.write(chunk);
		while (true) {
			const newlineIndex = buffer.indexOf("\n");
			if (newlineIndex === -1) return;
			emitLine(buffer.slice(0, newlineIndex));
			buffer = buffer.slice(newlineIndex + 1);
		}
	};
	const onEnd = () => {
		buffer += decoder.end();
		if (buffer.length > 0) { emitLine(buffer); buffer = ""; }
	};
	stream.on("data", onData);
	stream.on("end", onEnd);
	return () => {
		stream.off("data", onData);
		stream.off("end", onEnd);
	};
}
```

**Why each line is load-bearing** (the PRP must preserve ALL of this):
- `StringDecoder("utf8")` — a multi-byte UTF-8 char can be SPLIT across two `Buffer`
  chunks (e.g. `€` = `E2 82 AC` delivered as `[E2 82]` then `[AC]`). `decoder.write()`
  holds back the incomplete trailing byte and returns only complete chars;
  `decoder.end()` flushes. WITHOUT it, slicing a `Buffer` → string at a chunk boundary
  would produce U+FFFD replacement chars and corrupt the JSON. (Verified runtime §6.)
- `buffer.indexOf("\n")` — split on LF **only**. NOT `split(/\r?\n/)`, NOT Node
  `readline` (readline ALSO splits on U+2028 LINE SEPARATOR and U+2029 PARAGRAPH
  SEPARATOR, which are valid INSIDE JSON strings — the comment block says so
  explicitly). U+2028/U+2029 are 3-byte UTF-8 sequences; JSON.stringify does NOT
  escape them, so they appear literally in the payload and MUST survive intact.
- `line.endsWith("\r") ? line.slice(0, -1) : line` — strip ONE optional trailing CR
  (tolerate CRLF `\r\n` from Windows/CRLF clients). Only the trailing `\r` of the
  current line; never `\r` mid-payload.
- `while(true) { indexOf; slice; slice }` — drain ALL complete lines in one chunk
  (multi-line chunk `{"a":1}\n{"b":2}\n` → 2 emits). `slice(newlineIndex + 1)`
  advances past the consumed `\n`; leftover (no `\n`) stays buffered for the next chunk.
- `onEnd` flushes a final line WITHOUT a trailing `\n` (`{"final":true}` with no LF)
  then clears `buffer`. Pairs with `decoder.end()` for any held-back bytes.
- returns a **detach** `() => { stream.off("data"); stream.off("end"); }` so the caller
  (S8) can clean up on socket close/error and avoid a listener leak / use-after-close.

pi's own test (`packages/coding-agent/test/rpc-jsonl.test.ts`, vitest) covers:
serialize preserves U+2028/U+2029; split-on-LF-only; CRLF; final-line-without-LF. S7's
test mirrors these (in node:test, the house convention) + adds multibyte-split +
detach + empty-input.

---

## 2. API decision: MIRROR pi's stream-attach API verbatim (not a feed API)

Two candidate APIs:
- **(A) Stream-attach** (pi's): `attachJsonlLineReader(stream: Readable, onLine): () => void`.
  The reader attaches `stream.on("data")`/`stream.on("end")` itself; returns a detach fn.
- **(B) Feed/object** (like the Lua `jsonlreader:feed(chunk)`): a stateful object with
  `.feed(chunk)`/`.end()` that the caller drives.

**Decision: (A), verbatim.** Reasons:
1. **PRD §16 + protocol.ts JSDoc name pi's jsonl.ts as "the authoritative framing
   mirror" that S7 "implements"** — copying the exact API maximizes faithfulness and
   makes the "mirror" claim literally true.
2. `net.Socket` IS a `Readable` (`Socket extends stream.Duplex extends Readable` —
   verified @types/node net.d.ts L90), so S8 wires the reader with ONE call:
   `const detach = attachJsonlLineReader(sock, handleLine)`. No adapter needed.
3. S8 separately attaches `sock.on("error")`/`sock.on("close")` for connection
   lifecycle — those are CONNECTION-handling concerns (S8), cleanly separable from
   FRAMING (S7). The detach fn lets S8 tear the reader down on close.
4. Testability is identical: `Readable.from([Buffer.from(...)])` (built into
   `node:stream`) feeds chunks then emits `'end'` — same technique pi's own test uses.

A feed API would be more "decoupled" but would DIVERGE from the designated mirror for
no concrete benefit (the socket is always a Readable). Diverging also risks subtle
behavior drift from pi's battle-tested implementation. Mirror wins.

---

## 3. node:* type resolution — DEFINITIVE probe (the one non-obvious gotcha)

**Symptom (red herring):** the extension `tsconfig.json` has `"types": []` and NO
local `node_modules`. A naive probe in an isolated /tmp dir FAILS to resolve
`node:stream` / `node:string_decoder` / `Buffer` (`TS2307`/`TS2591`).

**Real mechanism (verified via `tsc --traceResolution`):**
- For `node:`-prefixed imports, classic module resolution reports "not resolved" (no
  `node_modules` walk finds a file) — that is EXPECTED and harmless.
- The types come from the **program-wide ambient `@types/node`**, which enters the
  program TRANSITIVELY because `pi-editor-bridge.ts` (always in `include`) imports
  `@earendil-works/pi-coding-agent` (paths → `dist/index.d.ts`), which references
  `@types/node`. Once @types/node is in the program, its `declare module "node:net"`,
  `declare module "node:stream"`, `declare module "node:string_decoder"`, and the
  global `Buffer` declaration are available to EVERY file in the program.

**DEFINITIVE PROOF (run):** a tsconfig mirroring the real extension (`types:[]`,
same `paths`) that includes BOTH the real `pi-editor-bridge.ts` AND a `jsonl.ts` with
`node:stream`/`node:string_decoder`/`Buffer` → **`tsc --noEmit` EXIT 0.** (The S5
PRP made the equivalent claim for `node:net`/`crypto`/`fs`/`os`/`path`; S7 extends it
to `node:stream`/`node:string_decoder` and the `Buffer` global — same mechanism.)

**Implication for the PRP:** S7's ONLY tsconfig change is adding `"jsonl-reader.ts"`
to the `include` array (exact one-line additive edit S4 made for `protocol.ts`). NO
`typeRoots`, NO `types:["node"]`, NO `lib` field — those would either be redundant or
BREAK the working transitive resolution (a `typeRoots` override that doesn't include
the pi-coding-agent tree would actually stop `node:*` resolving — verified by a failed
probe). Leave the compilerOptions UNTOUCHED.

---

## 4. `net.Socket` is a `Readable` (S8 will pass it directly)

`@types/node/net.d.ts:90`: `class Socket extends stream.Duplex`. `Duplex extends
Readable`. Therefore `attachJsonlLineReader(sock: Readable, …)` accepts a `Socket`
with no cast. S8's `onConnection(sock: Socket)` can call it directly. (No code change
in S7 for this — it just means the `(A)` API is correct as-is.)

---

## 5. `StringDecoder` API — verified from @types/node

`@types/node/string_decoder.d.ts`:
- `class StringDecoder` constructor: `new StringDecoder(encoding?: string)` (default
  utf8). pi passes `"utf8"` explicitly.
- `write(buffer: ...): string` — returns complete chars; buffers an incomplete
  trailing multi-byte sequence.
- `end(buffer?): string` — flushes any buffered bytes (returns them, or `""`).
pi's usage (`decoder.write(chunk)` per Buffer chunk; `decoder.end()` on stream end)
matches this exactly. S7 copies it verbatim.

---

## 6. Runtime behavior — ALL 6 test cases verified end-to-end

A faithful re-implementation of pi's reader was exercised via `Readable.from([...])`
on Node 26.4.0:

| Case | Input chunks | Emitted lines | Result |
|---|---|---|---|
| multi-line (one chunk) | `'{"a":1}\n{"b":2}\n'` | `["{"a":1}","{"b":2}"]` | ✅ drain loop |
| CRLF | `'{"a":1}\r\n{"b":2}\r\n'` | `["{"a":1}","{"b":2}"]` | ✅ `\r` stripped |
| partial line | `'{"x":"'` then `'val"}\n'` | `["{"x":"val"}"]` | ✅ buffered |
| no trailing LF | `'{"final":true}'` | `["{"final":true}"]` | ✅ flush on end |
| U+2028/U+2029 preserved | `serializeJsonLine({t:"a\u2028b\u2029c"})` | parses to `"a\u2028b\u2029c"` | ✅ not split |
| multibyte split (`€`=E2 82 AC) | `[E2 82]` then `[AC]` (mid-char) | `["{"e":"€"}"]` | ✅ StringDecoder reassembles |

All pass → the verbatim pi mirror is correct and the test design is sound.

---

## 7. tsconfig change = one-line `include` add (mirrors S4)

Current `extension/tsconfig.json`:
```jsonc
"include": ["pi-editor-bridge.ts", "protocol.ts", "tests/**/*.ts"]
```
S7 changes it to:
```jsonc
"include": ["pi-editor-bridge.ts", "protocol.ts", "jsonl-reader.ts", "tests/**/*.ts"]
```
- Same one-line additive edit S4 made when adding `protocol.ts`.
- New test `tests/jsonl-reader.test.ts` already matches `tests/**/*.ts` → no other edit.
- NO `compilerOptions` change (§3 — transitive `node:*` resolution keeps working).
- NO `paths` change (`jsonl-reader.ts` is a relative import, not a scoped package).

---

## 8. Test framework = `node:test` + jiti (house convention — NOT vitest)

pi's own `rpc-jsonl.test.ts` uses **vitest**, but the bridge extension's house
convention (verified across provider-capture/mode-guard/protocol/bridge-lifecycle/
bridge-lifecycle-wiring suites) is **`node:test` + jiti** with `node:assert/strict`.
S7's test MUST follow the house convention:
```ts
import { test } from "node:test";
import assert from "node:assert/strict";
import { Readable } from "node:stream";
import { attachJsonlLineReader, serializeJsonLine } from "../jsonl-reader.ts";
```
Feed data via `Readable.from([Buffer.from(...)])` and `await` the stream's `'end'`
(Readle.from auto-ends). node:test runs top-level `test(...)` sequentially (the module
under test is stateless — a pure function — so concurrency wouldn't matter anyway, but
keep sequential for house consistency).

Baseline confirmed green (2025-07-18): every existing `extension/tests/*.test.ts`
reports `ℹ fail 0` (protocol.test.ts → `pass 2 fail 0`).

---

## 9. Scope decisions (what S7 ships vs. defers)

**S7 ships (the title-named deliverable + its faithful companion):**
- NEW `extension/jsonl-reader.ts` exporting `attachJsonlLineReader` (the reader) AND
  `serializeJsonLine` (the serializer). Rationale for including the serializer even
  though the item title names only the reader:
  1. The parent task P1.M2.T4 is "**JSONL framing** & connection handling" —
     `serializeJsonLine` is FRAMING (pure line serialization), squarely in S7's lane;
     the CONNECTION handling (attach to socket, dispatch, build response envelopes,
     write) is S8.
  2. The PRD §16 mirror file ships BOTH functions in one module — mirroring it whole
     (vs. a half-mirror) is the faithful choice and avoids S8 reinventing the
     serializer.
  3. It is 1 line (`\`${JSON.stringify(value)}\n\``); near-zero cost.
  The reader remains the load-bearing, title-named deliverable; the serializer is a
  faithful companion the PRP marks explicitly.
- One-line `include` edit in `extension/tsconfig.json` (§7).
- NEW `extension/tests/jsonl-reader.test.ts` — node:test + jiti, ~8 tests (§1 + §6).

**S7 does NOT touch / defer to later tasks:**
- `extension/pi-editor-bridge.ts` — UNCHANGED. The `onConnection(_sock)` placeholder's
  `// TODO(S8): wire the JSONL reader + RPC dispatcher onto _sock` stays as-is; S8
  imports `attachJsonlLineReader` from the new module and wires it. S7 builds the
  reader; S8 consumes it.
- `extension/protocol.ts` — UNCHANGED. The reader emits raw `string` lines; JSON.parse
  + envelope narrowing + dispatch is S8/S15.
- Per-socket `'error'`/`'close'` handling — S8 (connection handling).
- `commandsChanged`, handshake, RPC method handlers — S9/S11–S15.

**File-name decision:** `jsonl-reader.ts` (descriptive; matches the item title "JSONL
line reader" and the S8 TODO "wire the JSONL reader"). The LOGIC mirrors pi's
`modes/rpc/jsonl.ts` byte-for-byte (noted in the module JSDoc); faithfulness is in the
logic, not the filename. (Alternative `jsonl.ts` was considered for exact filename
parity, but `jsonl-reader.ts` is more discoverable next to `protocol.ts` and reads
naturally at the S8 import site.)

---

## 10. Validation commands (verified working in this repo)

```bash
# Level 1 — type-check (covers the NEW jsonl-reader.ts once added to include +
#   protocol.ts + pi-editor-bridge.ts + all tests). node:stream/node:string_decoder
#   + Buffer resolve transitively (§3). Expected: exit 0, NO output.
tsc --noEmit -p extension/tsconfig.json

# Level 2 — node:test via jiti (house convention §8). Expected: exit 0, ℹ fail 0.
JITI_REG=/home/dustin/.local/lib/node_modules/@earendil-works/pi-coding-agent/node_modules/jiti/lib/jiti-register.mjs
node --import "$JITI_REG" extension/tests/jsonl-reader.test.ts

# Level 2 regression — every existing suite still green (S7 is purely additive: 1 new
#   module + 1 new test + 1-line include edit; it touches nothing they read).
for t in extension/tests/{provider-capture,mode-guard,protocol,bridge-lifecycle,bridge-lifecycle-wiring}.test.ts; do
  node --import "$JITI_REG" "$t" 2>/dev/null | grep -E "^ℹ (pass|fail)"
done

# Level 3 — regression: the extension still loads cleanly under pi (protocol.ts /
#   pi-editor-bridge.ts unchanged; jsonl-reader.ts is not imported by the entry point
#   yet, so this proves S7 didn't break the load path).
pi --no-extensions -e ./extension/pi-editor-bridge.ts --print "ok" 2>&1 \
  | grep -iE "error|cannot|fail|throw|TypeError" && echo FAIL || echo PASS

# Indentation sanity (house style = TABS, like every existing extension file):
grep -nP '^    ' extension/jsonl-reader.ts extension/tests/jsonl-reader.test.ts \
  && echo "WARN: space-indent lines found" || echo "indent OK (tabs)"
```

---

## 11. Design decisions carried into the PRP (summary)

1. **Separate module** `extension/jsonl-reader.ts` (not inline in pi-editor-bridge.ts):
   independently unit-testable (PRD §14 mandates framing unit tests); clean S8 import;
   mirrors pi's own modular `modes/rpc/jsonl.ts`.
2. **Verbatim logic mirror** of pi's `attachJsonlLineReader` (StringDecoder, LF-only
   split, `\r` strip, end-flush, detach fn) — the PRD-designated authoritative mirror.
3. **Stream-attach API** (not feed API) — `attachJsonlLineReader(stream, onLine): () =>
   void`; `net.Socket` is a `Readable` so S8 wires it in one call.
4. **Serializer companion** `serializeJsonLine` shipped alongside (framing, not
   connection-handling; faithful whole-module mirror; S8 will use it to write responses).
5. **node:test + jiti** test framework (house convention), feeding `Readable.from([...])`.
6. **One-line `include` edit** to tsconfig (exact S4 pattern); NO compilerOptions change.
7. **Scope discipline**: S7 builds+tests the reader only; onConnection wiring, JSON.parse,
   dispatch, per-socket lifecycle = S8+.
