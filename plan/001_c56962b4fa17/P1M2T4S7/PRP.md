---
name: "P1.M2.T4.S7 — JSONL line reader: buffer partial lines, split on \\n only, strip \\r"
description: |
  Create the bridge's **JSONL framing** module as a NEW single file
  `extension/jsonl-reader.ts` (plus a one-line `include` edit to
  `extension/tsconfig.json` and a NEW `node:test`+jiti suite
  `extension/tests/jsonl-reader.test.ts`). The module is a **faithful,
  byte-for-byte LOGIC mirror** of pi's own authoritative framing module
  `packages/coding-agent/src/modes/rpc/jsonl.ts` (designated the mirror by
  PRD §16 and by the existing `extension/protocol.ts` JSDoc, which states the
  reader is "IMPLEMENTED by the JSONL reader task (S7)"). It exports two
  functions: (1) **`attachJsonlLineReader(stream: Readable, onLine: (line:
  string) => void): () => void`** — the title-named reader that attaches a
  `\n`-only JSONL line reader to a Node `Readable` (a `net.Socket` IS a
  `Readable`, so S8 wires it with one call): it uses a `StringDecoder("utf8")`
  so a multi-byte UTF-8 char split across two `Buffer` chunks is reassembled
  (not corrupted to U+FFFD), buffers incomplete lines in a `let buffer = ""`,
  drains ALL complete lines per chunk via a `while` loop over
  `buffer.indexOf("\n")` (splits on LF **only** — deliberately NOT Node
  `readline`, which also splits on U+2028/U+2029 that are valid INSIDE JSON
  strings), strips ONE optional trailing `\r` per line (tolerates CRLF), flushes
  a trailing line with no final `\n` on the stream `'end'` event, and returns a
  **detach** function that removes its `data`/`end` listeners; and (2)
  **`serializeJsonLine(value: unknown): string`** — the faithful companion
  serializer (`` `${JSON.stringify(value)}\n` ``) that S8 will use to write
  JSON-RPC responses as strict LF-terminated records. The reader EMITS RAW
  `string` lines only — it does NOT `JSON.parse`, narrow envelopes, dispatch, or
  touch the socket's `error`/`close` lifecycle (all of that is S8's "connection
  handling" half of parent task P1.M2.T4, plus S9/S15 for handshake/error
  wrapping). The test suite (~8 tests, node:test + jiti, the house convention —
  NOT vitest like pi's own jsonl test) feeds data via the built-in
  `Readable.from([Buffer.from(...)])` and asserts: serialize is LF-terminated +
  preserves U+2028/U+2029 + round-trips through `JSON.parse`; reader handles
  single-line, multi-line-in-one-chunk, partial-line-split-across-chunks, CRLF
  (`\r` stripped), final-line-without-trailing-LF (flush on end),
  U+2028/U+2029-preserved-inside-payload (not split), a multi-byte UTF-8 char
  split across two Buffer chunks (proves the `StringDecoder` is load-bearing),
  empty input (no emits), and the detach function stops further emissions +
  removes listeners. This task is NARROW and PURELY ADDITIVE: it does **NOT**
  modify `extension/pi-editor-bridge.ts` (the `onConnection(_sock)` placeholder's
  `// TODO(S8): wire the JSONL reader + RPC dispatcher onto _sock` comment stays
  byte-for-byte intact — S8 imports this module and wires it), does **NOT**
  modify `extension/protocol.ts`, does **NOT** add `jsonl-reader.ts` to any
  import anywhere yet (it is dead code until S8 consumes it — by design, so the
  reader is unit-tested in isolation before wiring), does **NOT** touch any
  `compilerOptions` (the ONLY tsconfig change is appending `"jsonl-reader.ts"`
  to the existing `include` array — the exact one-line additive edit S4 made for
  `protocol.ts`; `node:stream`/`node:string_decoder`/`Buffer` resolve
  transitively via the program-wide `@types/node` pulled in by
  `pi-editor-bridge.ts`'s `@earendil-works/pi-coding-agent` import — empirically
  verified, see research §3), and does **NOT** implement the Lua-side
  `jsonlreader.lua` (that is P2.M5.T14.S23, a separate component).
---

## Goal

**Feature Goal**: Land the bridge's **JSONL framing** layer as an isolated,
unit-tested module so that the sibling task **S8** (`onConnection` handler) can,
in one line, attach a strict-LF-delimited line reader to each incoming
`net.Socket` and serialize JSON-RPC responses back — with framing that is
byte-for-byte identical to pi's own RPC engine (the PRD mandates this: PRD §5.2
"split on `\n`, strip an optional trailing `\r`, do NOT use readers that split
on U+2028/U+2029"; PRD §16 names `dist/modes/rpc/jsonl.js` as "the authoritative
framing mirror"). Concretely: a reader that **never corrupts multi-byte text at
chunk boundaries** (via `StringDecoder`), **never mis-splits on Unicode line/para
separators inside JSON strings** (LF-only `indexOf("\n")`, never Node readline),
**tolerates CRLF clients**, **flushes a trailing line lacking a final LF**, and
**cleans up its listeners on detach** so S8 can avoid socket listener leaks.

**Deliverable** (all under `extension/`):
1. **CREATE** `extension/jsonl-reader.ts` — a ~40-line module exporting
   `attachJsonlLineReader(stream: Readable, onLine): () => void` (the reader) and
   `serializeJsonLine(value: unknown): string` (the serializer companion). Logic
   is a verbatim mirror of pi's `packages/coding-agent/src/modes/rpc/jsonl.ts`;
   Mode-A JSDoc with a `STATUS (P1.M2.T4.S7)` marker + the mirror citation. Node
   builtins only (`node:stream` type-only, `node:string_decoder` value) — honors
   PRD §6.7's "no npm runtime dependencies".
2. **MODIFY** `extension/tsconfig.json` — append `"jsonl-reader.ts"` to the
   existing `include` array (the ONLY change; no `compilerOptions` edit).
3. **CREATE** `extension/tests/jsonl-reader.test.ts` — a `node:test`+jiti suite
   (matching the S2/S3/S4/S5/S6 test conventions) with ~8 tests feeding data via
   `Readable.from([Buffer.from(...)])`.

**Success Definition**:
- `tsc --noEmit -p extension/tsconfig.json` → exit 0, **no output** (the new
  module's `node:stream`/`node:string_decoder` imports + the `Buffer` global
  resolve transitively under the UNCHANGED `compilerOptions` — empirically
  verified; see research §3 + the Gotchas).
- `node --import <pi>/node_modules/jiti/lib/jiti-register.mjs extension/tests/jsonl-reader.test.ts`
  → exit 0, `ℹ fail 0` (all ~8 tests pass; the multibyte-split test proves the
  `StringDecoder` is load-bearing, and the U+2028/U+2029 test proves LF-only
  splitting).
- All 5 pre-existing suites still green (regression): `provider-capture.test.ts`
  (S2), `mode-guard.test.ts` (S3), `protocol.test.ts` (S4),
  `bridge-lifecycle.test.ts` (S5), `bridge-lifecycle-wiring.test.ts` (S6) — S7
  is purely additive (1 new module + 1 new test + 1-line `include` edit; touches
  nothing they read).
- Regression: `pi --no-extensions -e ./extension/pi-editor-bridge.ts --print "ok"`
  exits 0 with no error lines (the new module is not imported by the entry point
  yet, so the load path is unchanged — proves S7 didn't disturb the extension).
- The `onConnection(_sock)` placeholder in `pi-editor-bridge.ts` is byte-for-byte
  UNCHANGED (its `// TODO(S8)` comment intact — S7 builds the reader; S8 wires it).

## User Persona (if applicable)

**Target User**: The bridge-extension author and the downstream implementer of
**S8** (`onConnection` handler — the consumer of this module). This task is the
framing foundation S8's connection handling hangs off.

**Use Case**: When S8 implements `onConnection(sock)`, it will write
`const detach = attachJsonlLineReader(sock, (line) => { const msg = JSON.parse(line); dispatch(sock, msg); });`
and later, to send a response, `sock.write(serializeJsonLine(response))`. Until
S7 lands, S8 has no reader to attach and no serializer to write with — the
socket connection is a raw byte stream with no framing.

**Pain Points Addressed**:
- Without a `StringDecoder`, a multi-byte UTF-8 char split across two socket
  `data` chunks (e.g. `€` = `E2 82 AC` arriving as `[E2 82]` then `[AC]`) would
  be converted to a U+FFFD replacement char, corrupting the JSON and breaking
  the protocol for any non-ASCII prompt (CJK, emoji, accented letters).
- Without LF-only splitting (i.e. if one naively used Node `readline` or a
  `/\r?\n/` regex), a JSON string payload containing U+2028/U+2029 (which
  `JSON.stringify` does NOT escape) would be split mid-value — a silent,
  hard-to-debug framing corruption. pi's reader deliberately avoids readline for
  exactly this reason; S7 mirrors that decision.
- Without buffering, a single JSON-RPC request delivered across two `data`
  events would be unparseable. The reader's `let buffer` + drain loop handles it.
- Without a detach function, every connection would leak two listeners on close,
  and a `sock.on("error")` in S8 couldn't cleanly tear the reader down.

## Why

- **The framing foundation of the whole IPC protocol.** Every byte the Neovim
  plugin and the bridge exchange is a strict JSONL record (PRD §5.2). The reader
  (S7) + connection wiring (S8) are the two halves of parent task P1.M2.T4
  "JSONL framing & connection handling". S7 is the framing half; S8 is the
  connection half. Neither the handshake (S9) nor any RPC handler (S11–S14) can
  fire until a complete line is parsed off the socket — which is S7's job.
- **Faithfulness to pi is a hard requirement, not a nicety.** PRD §1 promises
  completion "byte-for-byte identical to pi's TUI" and PRD §5.2 mandates pi's
  exact framing rules. pi's own `modes/rpc/jsonl.ts` is the battle-tested,
  shipped implementation of those rules; mirroring it verbatim (rather than
  reinventing) eliminates an entire class of framing bugs and makes the "mirror"
  claim in `protocol.ts`'s JSDoc literally true.
- **Isolated unit-testability is mandated by the PRD.** PRD §14 explicitly says
  "Unit-test the JSONL framing (partial chunks, multi-line, `\r\n`)". A separate
  module fed by `Readable.from([...])` is the cleanest way to satisfy that — the
  framing logic is exercised directly, with no socket/server/lifecycle state in
  the way.
- **Zero-dependency, near-zero-config increment.** The module uses only Node
  builtins (`node:stream`, `node:string_decoder`) — honoring PRD §6.7's "no npm
  runtime dependencies". The only config change is one line in `include` (the
  established S4 pattern). It introduces no new runtime state and is dead code
  until S8 imports it, so it cannot regress any existing behavior.

## What

One new module, one one-line `include` edit, one new test file. No new module
state, no edit to `pi-editor-bridge.ts` or `protocol.ts`, no `compilerOptions`
change, no wiring into any socket (S8 does that).

### Success Criteria

- [ ] `extension/jsonl-reader.ts` EXISTS and exports `attachJsonlLineReader` and
      `serializeJsonLine` with the EXACT signatures above (the reader takes a
      `Readable` — so a `net.Socket` can be passed with no cast).
- [ ] `attachJsonlLineReader` logic is a verbatim mirror of pi's
      `modes/rpc/jsonl.ts`: `StringDecoder("utf8")`; `let buffer = ""`;
      `onData` drains via `while(true){ indexOf("\n"); slice; slice }`;
      `emitLine` strips one trailing `\r` (`line.endsWith("\r") ? slice(0,-1) :
      line`); `onEnd` does `buffer += decoder.end()` then flushes a non-empty
      remainder; returns a `detach` that does `stream.off("data", onData)` +
      `stream.off("end", onEnd)`.
- [ ] `serializeJsonLine` returns `` `${JSON.stringify(value)}\n` `` (LF
      terminator; `JSON.stringify` does NOT escape U+2028/U+2029 — that is the
      reason the reader must be LF-only).
- [ ] The module imports ONLY Node builtins (`node:stream` type-only `Readable`;
      `node:string_decoder` value `StringDecoder`) — NO npm deps (PRD §6.7).
- [ ] `extension/tsconfig.json` `include` contains `"jsonl-reader.ts"` (the ONLY
      change; `compilerOptions` byte-identical).
- [ ] `extension/pi-editor-bridge.ts` is UNCHANGED — the `onConnection(_sock)`
      placeholder + its `// TODO(S8)` comment are byte-for-byte intact.
- [ ] `extension/protocol.ts` is UNCHANGED.
- [ ] `extension/tests/jsonl-reader.test.ts` EXISTS, uses `node:test` +
      `node:assert/strict` + `Readable.from([Buffer.from(...)])` (NOT vitest),
      and asserts at minimum: serialize (LF-terminated, U+2028/U+2029 preserved,
      `JSON.parse` round-trip); single complete line; multi-line in one chunk;
      partial line split across chunks; CRLF (`\r` stripped); final line without
      trailing LF (flush on end); U+2028/U+2029 preserved inside payload; a
      multi-byte UTF-8 char split across two Buffer chunks (StringDecoder
      reassembles); detach stops further emissions.
- [ ] `tsc --noEmit -p extension/tsconfig.json` → exit 0, no output.
- [ ] `node --import <jiti-register> extension/tests/jsonl-reader.test.ts` →
      exit 0, `ℹ fail 0`.
- [ ] All 5 pre-existing suites still report `ℹ fail 0` (regression).
- [ ] `pi --no-extensions -e ./extension/pi-editor-bridge.ts --print "ok"` exits
      0 with no error lines.

## All Needed Context

### Context Completeness Check

_Pass test_: An agent who has never seen this repo, given the current
`extension/pi-editor-bridge.ts` (post-S6), `extension/protocol.ts` (post-S4),
`extension/tsconfig.json`, and this PRP, can (1) create `jsonl-reader.ts` verbatim
from the pinned reference body below (every import, signature, and line of logic
is reproduced from pi's authoritative source — no guessing), (2) make the
one-line `include` edit, (3) write the test from the supplied skeleton, and (4)
run the exact validation commands to green — with every load-bearing claim (the
transitive `node:*` resolution mechanism, `Socket extends Readable`,
`StringDecoder` semantics, why LF-only not readline, why the serializer is in
scope) cited and empirically verified in `research/notes.md`.

### Documentation & References

```yaml
# MUST READ — the authoritative framing source S7 mirrors VERBATIM (the PRD designates this)
- file: /home/dustin/projects/pi/packages/coding-agent/src/modes/rpc/jsonl.ts
  why: this IS the implementation S7 copies. attachJsonlLineReader(stream, onLine): detach + serializeJsonLine(value). StringDecoder("utf8"); buffer=""; LF-only indexOf("\n") drain loop; strip one trailing \r; onEnd flushes remainder; detach removes listeners. The module JSDoc explains WHY not readline (U+2028/U+2029 valid inside JSON strings).
  pattern: "verbatim copy of both functions; preserve every line (StringDecoder, the while-loop, the \r strip, the end-flush, the detach)"
  critical: |
    Copy the LOGIC byte-for-byte. Do NOT "improve" it (e.g. do not switch to
    readline, do not add a /\r?\n/ regex, do not skip StringDecoder, do not drop
    the end-flush). Each element exists to satisfy a PRD §5.2 framing rule or to
    prevent a verified corruption mode (see Gotchas).

# MUST READ — pi's own test for this module (the authoritative test-case set)
- file: /home/dustin/projects/pi/packages/coding-agent/test/rpc-jsonl.test.ts
  why: defines the canonical assertions: serialize preserves U+2028/U+2029; reader splits on LF only; handles CRLF; emits final line without trailing LF. S7's test mirrors these (in node:test, not vitest) + adds multibyte-split + detach + empty-input (bridge-specific completeness).
  pattern: "Readable.from([Buffer.from(...)]) + await stream 'end' + assert emitted lines[]"
  critical: |
    pi's test uses vitest; S7's test MUST use node:test + node:assert/strict (the
    house convention — see mode-guard.test.ts / protocol.test.ts). Same feeding
    technique (Readable.from), different runner + assertion lib.

# MUST READ — the pre-researched, empirically-verified analysis FOR THIS EXACT TASK
- docfile: plan/001_c56962b4fa17/P1M2T4S7/research/notes.md
  why: the authoritative task analysis: §1 reproduces pi's jsonl.ts verbatim + explains why each line is load-bearing; §2 locks the stream-attach API decision (vs a feed API) with rationale; §3 is the DEFINITIVE node:* type-resolution probe (the one non-obvious gotcha — node:* resolves via the PROGRAM-WIDE transitive @types/node from pi-editor-bridge.ts's pi-coding-agent import, NOT via local node_modules; a tsc --traceResolution + a green compile probe both confirm jsonl.ts type-checks when added to include); §4 confirms Socket extends Readable; §5 confirms StringDecoder API; §6 verifies all 6 runtime test cases end-to-end on Node 26.4.0; §7 is the one-line include edit; §8 is the node:test convention; §9 is the scope.
  section: "§1 (verbatim source), §2 (API decision), §3 (node:* resolution — read this before touching tsconfig), §6 (verified runtime cases), §9 (scope)"
  critical: |
    §3 is essential: do NOT add typeRoots/types:["node"]/lib to tsconfig — a
    typeRoots override that omits the pi-coding-agent tree BREAKS the working
    transitive resolution (verified by a failed probe). The ONLY tsconfig change
    is appending "jsonl-reader.ts" to include. compilerOptions stays untouched.

# MUST READ — @types/node declarations S7 imports (installed dist; line-verified)
- file: /home/dustin/.local/lib/node_modules/@earendil-works/pi-coding-agent/node_modules/@types/node/net.d.ts
  why: confirms net.Socket extends stream.Duplex (which extends Readable) — L90 `class Socket extends stream.Duplex` — so attachJsonlLineReader(sock: Readable, …) accepts a Socket with no cast (this is why the stream-attach API is correct for S8's onConnection(sock: Socket)).
  section: "L90 `class Socket extends stream.Duplex`"

- file: /home/dustin/.local/lib/node_modules/@earendil-works/pi-coding-agent/node_modules/@types/node/string_decoder.d.ts
  why: confirms the StringDecoder API S7 uses: constructor `new StringDecoder(encoding?: string)` (default utf8); `write(buffer): string` (returns complete chars, buffers a partial trailing multi-byte seq); `end(buffer?): string` (flushes buffered bytes). pi's usage (write per Buffer chunk; end on stream end) matches exactly.
  section: "L42 `class StringDecoder`; write(); end()"

# MUST READ — the baseline S7 builds alongside (and must NOT touch)
- docfile: plan/001_c56962b4fa17/P1M1T2S4/PRP.md
  why: defines the post-S4 shape of extension/protocol.ts (the TYPES-ONLY JSON-RPC contract whose JSDoc explicitly says "the authoritative framing mirror is pi's own dist/modes/rpc/jsonl.js ... IMPLEMENTED by the JSONL reader task (S7), not here. This module is TYPES-ONLY"). S7 fulfills that promise. protocol.ts is UNCHANGED by S7.
  section: "Goal + the module-level JSDoc citing jsonl.js as the S7 mirror"
  critical: |
    protocol.ts's JSDoc is the contractual hook that says S7 implements the
    framing mirror. Read it to confirm the reader emits raw `string` lines (NOT
    narrowed envelopes) — protocol.ts's job is the TYPES; jsonl-reader.ts's job
    is the FRAMING; S8's job is JSON.parse + envelope narrowing + dispatch.

- file: extension/pi-editor-bridge.ts
  why: the live post-S6 source. S7 does NOT edit it, but MUST leave the `onConnection(_sock)` placeholder + its `// TODO(S8): wire the JSONL reader + RPC dispatcher onto _sock` comment byte-for-byte intact (that is the S8 import site for THIS module). Re-grep before finishing to confirm S7 changed nothing here.
  section: "the `function onConnection(_sock: Socket): void { /* TODO(S8) … */ }` placeholder + its JSDoc"

# SUPPORTING — house test conventions (S7's test follows these exactly)
- file: extension/tests/protocol.test.ts
  why: the canonical node:test+jiti+`import type` test pattern in THIS repo: `import { test } from "node:test"`, `import assert from "node:assert/strict"`, top-level `test(...)` (no describe), declared-inside-test-body consts (no noUnusedLocals). S7's test mirrors this style.
  section: "whole file — import style, top-level test(), assertion patterns"

- file: extension/tests/bridge-lifecycle.test.ts
  why: shows the Readable/Buffer/event-driven assertion idiom is already house-compatible (it uses `once` from node:events + async tests). S7's test uses `Readable.from` + `await` of the stream 'end' — same async-test flavor.
  section: "the async test(...) bodies using node:events"

# SUPPORTING — the prior PRP that established the one-line include edit pattern
- docfile: plan/001_c56962b4fa17/P1M1T2S4/research/notes.md
  why: §4 records that S4's ONLY tsconfig change was appending "protocol.ts" to include (no compilerOptions edit). S7 makes the IDENTICAL one-line additive edit for "jsonl-reader.ts". Confirms the established, safe pattern.
  section: "§4 (tsconfig current state + the one-line additive include edit)"

# SUPPORTING — PRD framing + scope context
- docfile: PRD.md
  why: §5.2 (Framing: newline-delimited JSON, split on \n only, strip optional trailing \r, do NOT use readers that split on U+2028/U+2029, both sides buffer partial lines and decode on \n); §5.3 (JSON-RPC envelopes — S7 emits the raw line that S8 then JSON.parses into these); §9.1 (extension file layout); §14 (Testing Strategy: "Unit-test the JSONL framing (partial chunks, multi-line, \r\n)"); §16 (Reference: "RPC framing reference — packages/coding-agent/docs/rpc.md (JSONL / \n-only rules)" + the protocol.ts-cited mirror).
  section: "§5.2 (framing rules — the governing spec), §14 (testing), §16 (mirror reference), §9.1 (file layout)"
  critical: |
    §5.2 is the spec S7's logic satisfies line-for-line. §14 is the test
    contract (partial chunks, multi-line, \r\n) — S7's test covers exactly these
    plus multibyte + detach for completeness.

# SUPPORTING — Node stream docs (Readable.from semantics only; types come from @types/node)
- url: https://nodejs.org/api/stream.html#streamreadfromiterable-options
  why: confirms `Readable.from([Buffer.from(...)])` emits the buffer as a single 'data' chunk then emits 'end' (auto-end) — the exact feeding technique pi's own test and S7's test use. Also confirms Readable is the base class Duplex/Socket extend.
  section: "`stream.Readable.from(iterable[, options])` — 'from an array containing a buffer ... emits the values in the array ... then end'"
  critical: |
    To feed MULTIPLE chunks (partial-line + multibyte-split tests), pass an ARRAY
    of Buffers: `Readable.from([buf1, buf2])` emits two 'data' events then 'end'.
    To assert the lines, collect them in onLine and `await` the 'end' event.
```

### Current Codebase tree (post-S6 baseline — S7 ADDS 1 module + 1 test, edits 1 include line)

```bash
extension/
├── pi-editor-bridge.ts            # (S1+S2+S3+S5+S6) default-export factory: session_start (TUI guard + log + captureProvider + startBridge) + session_shutdown (stopBridge); captureProvider/getProvider/liveProvider; startBridge/stopBridge/getServer/getSocketPath/getToken/__deps/onConnection-PLACEHOLDER. S7 does NOT touch this file.
├── protocol.ts                    # (S4) type-only JSON-RPC contract; JSDoc cites pi's jsonl.js as the mirror S7 implements. S7 does NOT touch it.
├── tsconfig.json                  # (S1+S2+S4) include=["pi-editor-bridge.ts","protocol.ts","tests/**/*.ts"]; paths map BOTH pi-coding-agent AND pi-tui. S7 appends "jsonl-reader.ts" to include (the ONLY edit; compilerOptions UNCHANGED).
└── tests/
    ├── provider-capture.test.ts   # (S2) S7 does NOT touch (regression).
    ├── mode-guard.test.ts         # (S3) S7 does NOT touch (regression).
    ├── protocol.test.ts           # (S4) S7 does NOT touch (regression).
    ├── bridge-lifecycle.test.ts   # (S5) S7 does NOT touch (regression).
    └── bridge-lifecycle-wiring.test.ts  # (S6) S7 does NOT touch (regression).
# plan/ holds planning artifacts only — no other source code
```

### Desired Codebase tree with files to be added/modified

```bash
extension/
├── pi-editor-bridge.ts            # (UNCHANGED — onConnection placeholder + its // TODO(S8) comment intact; S8 will import jsonl-reader.ts here)
├── protocol.ts                    # (UNCHANGED — S4)
├── jsonl-reader.ts                # (CREATE) the JSONL framing mirror: attachJsonlLineReader(stream, onLine): detach + serializeJsonLine(value). Node builtins only.
├── tsconfig.json                  # (MODIFY) append "jsonl-reader.ts" to include → ["pi-editor-bridge.ts","protocol.ts","jsonl-reader.ts","tests/**/*.ts"]. compilerOptions UNCHANGED.
└── tests/
    ├── provider-capture.test.ts   # (UNCHANGED — S2 regression)
    ├── mode-guard.test.ts         # (UNCHANGED — S3 regression)
    ├── protocol.test.ts           # (UNCHANGED — S4 regression)
    ├── bridge-lifecycle.test.ts   # (UNCHANGED — S5 regression)
    ├── bridge-lifecycle-wiring.test.ts  # (UNCHANGED — S6 regression)
    └── jsonl-reader.test.ts       # (CREATE) node:test+jiti: serialize + single/multi/partial/CRLF/no-trailing-LF/U+2028/U+2029/multibyte-split/empty/detach.
```

**File responsibilities**
- `extension/jsonl-reader.ts` — the JSONL framing layer. Pure functions, no module
  state, no socket/server dependency. `attachJsonlLineReader` adapts any `Readable`
  (including `net.Socket`) into a stream of complete, `\r`-stripped, LF-delimited
  lines; `serializeJsonLine` produces a strict LF-terminated record. S8 imports both.
- `extension/tests/jsonl-reader.test.ts` — the contract gate for S7: proves the
  framing rules (LF-only, `\r` strip, partial buffering, end-flush) and the two
  corruption-prevention mechanisms (StringDecoder for multibyte; LF-only-not-readline
  for U+2028/U+2029), fed by `Readable.from` with no real socket.

### Known Gotchas of our codebase & Library Quirks

```typescript
// CRITICAL (verified, research §3): `node:*` modules resolve via the PROGRAM-WIDE
//   transitive @types/node, NOT via a local node_modules walk. The mechanism:
//   pi-editor-bridge.ts (always in include) imports @earendil-works/pi-coding-agent
//   (paths → dist/index.d.ts), which references @types/node; once @types/node is in
//   the program, its `declare module "node:stream"`, `declare module "node:string_decoder"`,
//   and the global `Buffer` are available to EVERY file. tsc --traceResolution reports
//   node:* as "not resolved" (classic file resolution) but the ambient declarations
//   satisfy the import in a later step. A green compile probe (jsonl.ts alongside the
//   real pi-editor-bridge.ts) CONFIRMS this.
//   RESOLUTION: the ONLY tsconfig change is appending "jsonl-reader.ts" to include.
//   Do NOT add typeRoots / types:["node"] / a lib field — a typeRoots override that
//   omits the pi-coding-agent tree BREAKS the working transitive resolution (a probe
//   with an explicit typeRoots FAILED with TS2307/TS2591). Leave compilerOptions alone.

// CRITICAL (verified, research §6): WITHOUT StringDecoder, slicing a Buffer → string
//   at a multi-byte char boundary produces U+FFFD and corrupts the JSON. Example: "€"
//   = 0xE2 0x82 0xAC; delivered as [E2 82] then [AC], a naive `buffer += chunk.toString()`
//   yields "\uFFFD" at the split. StringDecoder.write() holds back the incomplete byte
//   and returns only complete chars; StringDecoder.end() flushes. pi's reader uses it;
//   S7 mirrors it VERBATIM. The test MUST include a multibyte-split case to prove this
//   is load-bearing (otherwise a future "simplification" could silently remove it).

// CRITICAL (verified, PRD §5.2 + pi's module JSDoc): do NOT use Node `readline` and do
//   NOT split on /\r?\n/ or any Unicode-aware line splitter. Readline splits on U+2028
//   (LINE SEPARATOR) and U+2029 (PARAGRAPH SEPARATOR), which are valid INSIDE JSON
//   strings and which JSON.stringify does NOT escape — so they appear literally in
//   payloads and MUST survive intact. Split on `\n` ONLY via buffer.indexOf("\n"). The
//   test MUST include a U+2028/U+2029-inside-payload case to prove LF-only splitting.

// CRITICAL (pi's module, by design): the reader emits RAW string lines — it does NOT
//   JSON.parse, narrow to JsonRpcRequest/Response/Notification, or dispatch. That is
//   S8's job (JSON.parse + protocol.ts envelope narrowing) and S15's job (error-wrap
//   a JSON.parse throw into a JSON-RPC -32700). S7's onLine hands S8 a clean `string`;
//   S8 decides what to do with it. Do NOT add JSON.parse to the reader.

// GOTCHA (verified, @types/node net.d.ts L90): net.Socket extends stream.Duplex extends
//   Readable. So attachJsonlLineReader(sock: Readable, …) accepts a Socket with no cast.
//   This is WHY the stream-attach API (not a feed API) is the right choice — S8 wires
//   the reader in one call: `attachJsonlLineReader(sock, handleLine)`. (research §2/§4)

// GOTCHA: attaching a 'data' listener switches a Readable into flowing mode. For a
//   net.Socket that is the desired behavior (data flows as it arrives). pi's reader
//   relies on this; S7 mirrors it. No `pause`/`resume` handling is needed.

// GOTCHA: the reader attaches 'data' AND 'end' but NOT 'error'/'close'. Those are
//   CONNECTION-lifecycle concerns (S8). S7's detach fn removes only the reader's own
//   'data'/'end' listeners; S8 separately attaches sock.on("error")/sock.on("close")
//   and calls detach() from them. Do NOT add error/close handling to the reader.

// GOTCHA: the detach function MUST use the SAME function references passed to .on()
//   when calling .off() (Node EventEmitter identity). pi's closure-captured onData/onEnd
//   references make this work. Do NOT inline the handlers or .off() will silently no-op.

// GOTCHA: `Readable.from([buf1, buf2])` emits TWO 'data' events (one per array element)
//   then 'end'. To test partial-line buffering and multibyte-split, pass an ARRAY of
//   Buffers. To test a single chunk, pass a one-element array. Do NOT concatenate the
//   test's buffers into one string and expect multiple emits — that defeats the test.

// GOTCHA: node:test's default reporter prints `ℹ pass N` / `ℹ fail N` (NOT TAP `ok`/
//   `not ok`). Judge the test by exit code 0 + `ℹ fail 0`. jiti prints a benign
//   `DeprecationWarning: module.register() is deprecated` on Node 26 stderr — IGNORE.

// GOTCHA: S7 writes NOTHING to process.env and changes NO behavior in pi-editor-bridge.ts.
//   The new module is dead code (not imported anywhere) until S8. That is BY DESIGN —
//   it lets the framing logic be unit-tested in complete isolation before wiring.

// STYLE: TABS for indentation (match the existing pi-editor-bridge.ts / protocol.ts /
//   every test file + pi's own jsonl.ts). `import type` for the Readable type-only
//   import; `import { StringDecoder }` (value) separately. Mode-A JSDoc on every export
//   with a `STATUS (P1.M2.T4.S7)` marker + the pi mirror citation.
```

## Implementation Blueprint

### Data models and structure

S7 introduces **no new data types** and **no module state**. `protocol.ts` (S4)
already owns the wire types; `jsonl-reader.ts` deals only in raw `string` lines
and `unknown` payloads. Its "data model" is two **pure functions** plus the
reader's **closure-captured per-stream locals** (`decoder`, `buffer`) — all
instance-local to a single `attachJsonlLineReader` call, so two sockets each get
their own independent reader with no shared state (no module singleton, unlike
the server in `pi-editor-bridge.ts`).

### Implementation Tasks (ordered by dependencies)

```yaml
Task 1: CREATE extension/jsonl-reader.ts (the framing mirror)
  - CREATE the file with the exact reference body in Implementation Patterns below.
  - IMPORTS (Node builtins ONLY — PRD §6.7 "no npm runtime deps"):
        import type { Readable } from "node:stream";
        import { StringDecoder } from "node:string_decoder";
  - EXPORT `serializeJsonLine(value: unknown): string` → `` `${JSON.stringify(value)}\n` ``.
  - EXPORT `attachJsonlLineReader(stream: Readable, onLine: (line: string) => void): () => void`
      — verbatim logic mirror of pi's modes/rpc/jsonl.ts: new StringDecoder("utf8");
      let buffer=""; emitLine strips one trailing \r; onData appends string-or-decoder.write
      and drains via while(true){indexOf("\n");slice;slice}; onEnd flushes decoder.end() +
      non-empty remainder; attaches stream.on("data",onData) + stream.on("end",onEnd);
      returns () => { stream.off("data",onData); stream.off("end",onEnd); }.
  - JSDOC: file-level block citing PRD §5.2 + §16 and pi's modes/rpc/jsonl.ts as the
      verbatim mirror; per-export Mode-A blocks with a STATUS (P1.M2.T4.S7) marker +
      forward ref ("S8 imports attachJsonlLineReader(sock, ...) into onConnection").
  - NAMING: attachJsonlLineReader / serializeJsonLine — EXACT (match pi's exports so the
      "mirror" claim is literal; S8's import reads naturally).
  - FOLLOW: TAB indentation; `import type` for Readable; match the JSDoc density of
      protocol.ts / pi-editor-bridge.ts.
  - DO NOT: JSON.parse or narrow envelopes (S8); attach 'error'/'close' (S8); add module
      state; import anything from protocol.ts or pi-editor-bridge.ts; use readline or a
      regex splitter; drop the StringDecoder / the end-flush / the \r strip / the detach.

Task 2: MODIFY extension/tsconfig.json — append "jsonl-reader.ts" to include
  - CHANGE the include array from:
        "include": ["pi-editor-bridge.ts", "protocol.ts", "tests/**/*.ts"]
    to:
        "include": ["pi-editor-bridge.ts", "protocol.ts", "jsonl-reader.ts", "tests/**/*.ts"]
  - WHY: tsc only type-checks files matched by include (or imported by them). jsonl-reader.ts
      is not imported anywhere yet (S8 does that), so it MUST be in include to be checked.
      This is the IDENTICAL one-line additive edit S4 made for protocol.ts (research §7).
  - DO NOT: touch compilerOptions (the node:* transitive resolution in §3/§research-§3
      depends on compilerOptions staying EXACTLY as-is; a typeRoots/types/lib change can
      BREAK it — verified by a failed probe); edit paths (jsonl-reader.ts is a relative
      import, not a scoped package); reorder the existing entries.

Task 3: CREATE extension/tests/jsonl-reader.test.ts (node:test + jiti)
  - IMPORT: `import { test } from "node:test"; import assert from "node:assert/strict";`
      `import { Readable } from "node:stream";`
      `import { attachJsonlLineReader, serializeJsonLine } from "../jsonl-reader.ts";`
  - HELPER feed(chunks: Array<string | Buffer>): Promise<string[]> — creates
      `Readable.from(chunks)`, attaches the reader pushing to an array, awaits the
      stream 'end', returns the collected lines. (Centralizes the Readable.from +
      await-end idiom so each test is a 2-liner.)
  - TEST 1 (serialize): serializeJsonLine({text:"a\u2028b\u2029c"}) endsWith "\n";
      contains the literal U+2028/U+2029 (NOT escaped); JSON.parse(trimmed) deep-equals
      {text:"a\u2028b\u2029c"}.
  - TEST 2 (single complete line): feed([Buffer.from('{"a":1}\n')]) → ['{"a":1}'].
  - TEST 3 (multi-line one chunk): feed([Buffer.from('{"a":1}\n{"b":2}\n')]) →
      ['{"a":1}','{"b":2}'] (proves the while-drain loop).
  - TEST 4 (partial line split across chunks): feed([Buffer.from('{"x":"'),Buffer.from('val"}\n')])
      → ['{"x":"val"}'] (proves buffering).
  - TEST 5 (CRLF — strip \r): feed([Buffer.from('{"a":1}\r\n{"b":2}\r\n')]) →
      ['{"a":1}','{"b":2}'] (proves the \r strip; NO \r in output).
  - TEST 6 (final line without trailing LF — flush on end): feed([Buffer.from('{"final":true}')])
      → ['{"final":true}'] (proves onEnd flush).
  - TEST 7 (U+2028/U+2029 preserved inside payload — LF-only split): construct a payload
      containing U+2028 and U+2029, serialize+feed, assert the single emitted line
      JSON.parses back to the exact object with U+2028/U+2029 intact (proves NOT readline).
  - TEST 8 (multibyte UTF-8 split across Buffer chunks — StringDecoder reassembles):
      euro = Buffer.from('{"e":"€"}\n'); mid = floor(len/2); feed([euro.slice(0,mid),
      euro.slice(mid)]) → ['{"e":"€"}'] (proves StringDecoder is load-bearing).
  - TEST 9 (empty input): feed([]) → [] (no emits; no throw).
  - TEST 10 (detach stops emissions + removes listeners): create a Readable that emits
      incrementally (e.g. a PassThrough or a manually-controlled Readable); attach the
      reader; call detach(); push more data; assert no further onLine calls AND
      stream.listenerCount("data")===0 (proves cleanup). (If a manual Readable is fiddly,
      a simpler variant: attach to Readable.from(['{"a":1}\n','{"b":2}\n']), call detach()
      immediately, and assert onLine was never called for the 2nd line — acceptable proof
      that detach removes the listener before the 2nd chunk flows.)
  - SHARED-STATE NOTE: the module under test is PURE (no module state), so test order is
      irrelevant; still keep top-level test(...) sequential (house default) — do NOT enable
      concurrency.
  - FOLLOW: TAB indentation; reuse the jiti register hook path from S2/S3/S4/S5/S6.
  - NAMING: descriptive test("…") titles; no describe.
  - PLACEMENT: extension/tests/jsonl-reader.test.ts (matches tests/**/*.ts → NO other tsconfig edit).

Task 4: VALIDATE — run the validation commands; fix until all green
  - RUN (Level 1): `tsc --noEmit -p extension/tsconfig.json` (expect exit 0, no output)
  - RUN (Level 2): `node --import "$JITI_REG" extension/tests/jsonl-reader.test.ts`
      (expect exit 0, ℹ fail 0 — ignore the benign jiti DEP0205 deprecation on stderr)
  - RUN (Level 2 regression): re-run provider-capture / mode-guard / protocol /
      bridge-lifecycle / bridge-lifecycle-wiring — expect each ℹ fail 0
  - RUN (Level 3): `pi --no-extensions -e ./extension/pi-editor-bridge.ts --print "ok"`
      exits 0 with no error lines (the new module isn't imported by the entry point yet)
  - RUN (sanity): grep-confirm pi-editor-bridge.ts is UNCHANGED at the onConnection
      placeholder; grep-confirm tsconfig compilerOptions UNCHANGED.
```

### Implementation Patterns & Key Details

```typescript
// === extension/jsonl-reader.ts (CREATE) — VERBATIM LOGIC MIRROR of pi's
//     packages/coding-agent/src/modes/rpc/jsonl.ts (the PRD §16 + protocol.ts-JSDoc
//     designated authoritative framing mirror). Copy the LOGIC byte-for-byte; the only
//     additions are the bridge-local JSDoc + STATUS markers. Node builtins only. ===

/**
 * jsonl-reader.ts — strict JSONL framing for the pi-editor-bridge IPC socket.
 *
 * This module is a VERBATIM LOGIC MIRROR of pi's own authoritative framing module
 * `packages/coding-agent/src/modes/rpc/jsonl.ts` (compiled: `dist/modes/rpc/jsonl.js`),
 * designated the framing mirror by PRD §16 ("RPC framing reference") and by the
 * `extension/protocol.ts` module-level JSDoc ("the authoritative framing mirror is
 * pi's own dist/modes/rpc/jsonl.js ... IMPLEMENTED by the JSONL reader task (S7)").
 *
 * Framing rules (PRD §5.2): exactly one JSON object per line, delimited by `\n` ONLY.
 * An optional trailing `\r` is stripped (CRLF tolerance). Do NOT use readers that split
 * on U+2028 / U+2029 — those are valid INSIDE JSON strings (JSON.stringify does not
 * escape them) and would corrupt payloads. Both sides must buffer partial lines and
 * decode on `\n`.
 *
 * STATUS (P1.M2.T4.S7): framing half of parent task P1.M2.T4 ("JSONL framing &
 * connection handling"). The reader is built + unit-tested HERE; the connection
 * half (attach to a net.Socket, JSON.parse, narrow envelopes, dispatch, write
 * responses, handle socket error/close) is S8. This module is dead code (imported
 * nowhere) until S8 — by design, so the framing logic is tested in isolation.
 *
 * Node builtins only (PRD §6.7 "no npm runtime dependencies"). No module state.
 */

import type { Readable } from "node:stream";
import { StringDecoder } from "node:string_decoder";

/**
 * Serialize a single strict JSONL record: `${JSON.stringify(value)}\n`.
 *
 * `JSON.stringify` does NOT escape U+2028 / U+2029 — they appear literally in the
 * payload, which is precisely WHY the reader must split on `\n` only (see
 * {@link attachJsonlLineReader}). The trailing `\n` is the record terminator.
 *
 * S8 uses this to write JSON-RPC responses: `sock.write(serializeJsonLine(response))`.
 *
 * STATUS (P1.M2.T4.S7): faithful companion to the reader (shipped together because the
 * PRD §16 mirror file ships both, and because framing — not connection-handling — is
 * S7's lane; S8 consumes it).
 */
export function serializeJsonLine(value: unknown): string {
	return `${JSON.stringify(value)}\n`;
}

/**
 * Attach an LF-only JSONL line reader to a `Readable` stream (a `net.Socket` IS a
 * `Readable` — `Socket extends Duplex extends Readable` — so S8 passes the socket
 * directly: `attachJsonlLineReader(sock, handleLine)`).
 *
 * For each COMPLETE line (terminated by `\n`), `onLine` is invoked with the line as a
 * raw `string`, with a single optional trailing `\r` stripped. Incomplete trailing
 * data is buffered across `data` events; a final line lacking a trailing `\n` is
 * emitted when the stream emits `'end'`. The returned function detaches the reader
 * (removes its `data`/`end` listeners) — call it on socket close/error to avoid a
 * listener leak.
 *
 * This intentionally does NOT use Node `readline`. Readline splits on additional
 * Unicode separators (U+2028 / U+2029) that are valid inside JSON strings and
 * therefore does not implement strict JSONL framing. A `StringDecoder` reassembles
 * multi-byte UTF-8 characters split across two `Buffer` chunks (e.g. `€` = E2 82 AC
 * delivered as `[E2 82]` then `[AC]`) — without it the split would yield U+FFFD and
 * corrupt the JSON.
 *
 * The reader emits RAW `string` lines only. It does NOT `JSON.parse`, narrow to
 * JsonRpcRequest/Response/Notification, or dispatch — that is S8's job (with S15
 * error-wrapping a `JSON.parse` throw into a JSON-RPC -32700).
 *
 * STATUS (P1.M2.T4.S7): the title-named deliverable. Mirrors pi's
 * `attachJsonlLineReader` in `modes/rpc/jsonl.ts` byte-for-byte.
 *
 * @param stream any Readable (a net.Socket in S8's onConnection).
 * @param onLine called once per complete, `\r`-stripped line.
 * @returns a detach function that removes the reader's `data`/`end` listeners.
 */
export function attachJsonlLineReader(
	stream: Readable,
	onLine: (line: string) => void,
): () => void {
	const decoder = new StringDecoder("utf8");
	let buffer = "";

	const emitLine = (line: string) => {
		onLine(line.endsWith("\r") ? line.slice(0, -1) : line);
	};

	const onData = (chunk: string | Buffer) => {
		buffer += typeof chunk === "string" ? chunk : decoder.write(chunk);

		// Drain ALL complete lines in this chunk (a chunk may carry several records).
		while (true) {
			const newlineIndex = buffer.indexOf("\n"); // LF ONLY — never readline / regex.
			if (newlineIndex === -1) {
				return; // incomplete trailing line stays buffered for the next chunk
			}
			emitLine(buffer.slice(0, newlineIndex));
			buffer = buffer.slice(newlineIndex + 1); // advance past the consumed "\n"
		}
	};

	const onEnd = () => {
		buffer += decoder.end(); // flush any multi-byte bytes StringDecoder held back
		if (buffer.length > 0) {
			emitLine(buffer); // a final line without a trailing "\n"
			buffer = "";
		}
	};

	stream.on("data", onData);
	stream.on("end", onEnd);

	// Detach: remove THIS reader's listeners (identity-equal closures). S8 calls this
	// from sock.on("error")/sock.on("close"). Does NOT touch other listeners.
	return () => {
		stream.off("data", onData);
		stream.off("end", onEnd);
	};
}
```

```typescript
// === extension/tests/jsonl-reader.test.ts (CREATE — node:test + jiti; NOT vitest) ===
import { test } from "node:test";
import assert from "node:assert/strict";
import { Readable } from "node:stream";
import { attachJsonlLineReader, serializeJsonLine } from "../jsonl-reader.ts";

// Feed `chunks` through a fresh Readable, collect complete lines, resolve on 'end'.
// Readable.from([b1, b2]) emits one 'data' per element then 'end' (auto-end).
async function feed(chunks: Array<string | Buffer>): Promise<string[]> {
	const lines: string[] = [];
	const stream = Readable.from(chunks);
	attachJsonlLineReader(stream, (line) => lines.push(line));
	await new Promise<void>((resolve) => stream.on("end", resolve));
	return lines;
}

test("serializeJsonLine: LF-terminated, preserves U+2028/U+2029, JSON.parse round-trips", () => {
	const line = serializeJsonLine({ text: "a\u2028b\u2029c" });
	assert.equal(line.endsWith("\n"), true, "record must be LF-terminated");
	assert.ok(line.includes("a\u2028b\u2029c"), "U+2028/U+2029 must appear literally (unescaped)");
	assert.deepEqual(JSON.parse(line.trim()), { text: "a\u2028b\u2029c" });
});

test("reader: single complete line", async () => {
	assert.deepEqual(await feed([Buffer.from('{"a":1}\n')]), ['{"a":1}']);
});

test("reader: multiple lines in one chunk (drain loop)", async () => {
	assert.deepEqual(
		await feed([Buffer.from('{"a":1}\n{"b":2}\n')]),
		['{"a":1}', '{"b":2}'],
	);
});

test("reader: partial line split across chunks (buffering)", async () => {
	assert.deepEqual(
		await feed([Buffer.from('{"x":"'), Buffer.from('val"}\n')]),
		['{"x":"val"}'],
	);
});

test("reader: CRLF-delimited input — trailing \\r stripped", async () => {
	const lines = await feed([Buffer.from('{"a":1}\r\n{"b":2}\r\n')]);
	assert.deepEqual(lines, ['{"a":1}', '{"b":2}']);
	assert.ok(lines.every((l) => !l.endsWith("\r")), "no emitted line may end with \\r");
});

test("reader: final line without trailing LF is flushed on 'end'", async () => {
	assert.deepEqual(await feed([Buffer.from('{"final":true}')]), ['{"final":true}']);
});

test("reader: U+2028/U+2029 inside payload are preserved (LF-only split, not readline)", async () => {
	const obj = { text: "a\u2028b\u2029c" };
	const lines = await feed([Buffer.from(serializeJsonLine(obj))]);
	assert.equal(lines.length, 1, "U+2028/U+2029 must NOT split the record");
	assert.deepEqual(JSON.parse(lines[0]), obj);
});

test("reader: a multi-byte UTF-8 char split across Buffer chunks is reassembled (StringDecoder)", async () => {
	// "€" = 0xE2 0x82 0xAC (3 bytes). Split it mid-char across two chunks.
	const record = Buffer.from('{"e":"€"}\n');
	const mid = Math.floor(record.length / 2);
	const lines = await feed([record.slice(0, mid), record.slice(mid)]);
	assert.deepEqual(lines, ['{"e":"€"}'], "no U+FFFD — StringDecoder reassembled the char");
	assert.deepEqual(JSON.parse(lines[0]), { e: "€" });
});

test("reader: empty input emits no lines and does not throw", async () => {
	assert.deepEqual(await feed([]), []);
});

test("reader: detach removes listeners and stops further emissions", async () => {
	// Two records in one stream; detach AFTER the first line is emitted. Because
	// Readable.from drains synchronously on read, we use a manually-pushed stream
	// so we can detach between chunks.
	const lines: string[] = [];
	const stream = new Readable({ read() {} });
	const detach = attachJsonlLineReader(stream, (line) => lines.push(line));
	stream.push('{"a":1}\n');
	// Allow the data listener to drain the first chunk (next tick).
	await new Promise((r) => setImmediate(r));
	detach();
	stream.push('{"b":2}\n'); // after detach, this must NOT produce a line
	await new Promise((r) => setImmediate(r));
	stream.push(null); // end
	await new Promise((r) => setImmediate(r));
	assert.deepEqual(lines, ['{"a":1}'], "no line emitted after detach");
	assert.equal(stream.listenerCount("data"), 0, "detach removed the data listener");
	assert.equal(stream.listenerCount("end"), 0, "detach removed the end listener");
});
```

### Integration Points

```yaml
NO external integration points for S7 (the module is pure functions; not wired anywhere yet).
  - No process.env write; no socket bind; no DB/config; no import added to any other file.
INTERNAL seam (the export S8 will consume — NOT wired in S7):
  - attachJsonlLineReader(stream, onLine): detach  → S8's onConnection(sock) calls this
    to frame incoming socket bytes; S8's sock.on("error")/sock.on("close") call the
    returned detach to clean up.
  - serializeJsonLine(value): string                → S8 writes responses via
    `sock.write(serializeJsonLine(response))`.
NO tsconfig compilerOptions change:
  - The ONLY tsconfig edit is appending "jsonl-reader.ts" to the include array (Task 2).
  - node:stream / node:string_decoder / Buffer resolve via the PROGRAM-WIDE transitive
    @types/node (pulled in by pi-editor-bridge.ts's pi-coding-agent import) — empirically
    verified (research §3). Do NOT add typeRoots/types/lib (a typeRoots override BREAKS it).
NO change to pi-editor-bridge.ts or protocol.ts:
  - The onConnection placeholder + its // TODO(S8) comment stay byte-for-byte intact
    (S8 imports jsonl-reader.ts there). protocol.ts is untouched.
```

## Validation Loop

### Level 1: Syntax & Style (Immediate Feedback) — THE TYPE GATE

```bash
# Type-check jsonl-reader.ts + protocol.ts + pi-editor-bridge.ts + all tests via the
# paths-mapped dev tsconfig. Load-bearing checks for S7: the `import type { Readable }
# from "node:stream"` + `import { StringDecoder } from "node:string_decoder"` resolve
# (transitively, research §3); the `Buffer` global is in scope; the detach return type
# `() => void` type-checks; the test's Readable.from / stream.on / listenerCount calls
# compile. Failures are usually: a typo in the node:* import, a missing export, or an
# accidental compilerOptions edit that broke the transitive node:* resolution.
tsc --noEmit -p extension/tsconfig.json
# Expected: exit 0, NO output.

# Indentation sanity (house style = TABS, like every existing extension file + pi's jsonl.ts):
grep -nP '^    ' extension/jsonl-reader.ts extension/tests/jsonl-reader.test.ts \
  && echo "WARN: space-indent lines found" || echo "indent OK (tabs)"

# Confirm the ONLY tsconfig change is the include line (compilerOptions byte-identical):
grep -nE '"(types|typeRoots|lib|paths)"' extension/tsconfig.json \
  && echo "WARN: did S7 accidentally edit compilerOptions? (it should NOT)" \
  || echo "PASS: no compilerOptions keys present (S7 only edited include)"

# Confirm jsonl-reader.ts is in include and pi-editor-bridge.ts is UNCHANGED:
grep -n '"jsonl-reader.ts"' extension/tsconfig.json && echo "include OK"
grep -n 'TODO(S8): wire the JSONL reader' extension/pi-editor-bridge.ts \
  && echo "PASS: onConnection placeholder intact (S7 did not touch pi-editor-bridge.ts)" \
  || echo "FAIL: onConnection // TODO(S8) comment missing — S7 must not edit that file"
```

### Level 2: Unit Tests (Component Validation)

```bash
JITI_REG=/home/dustin/.local/lib/node_modules/@earendil-works/pi-coding-agent/node_modules/jiti/lib/jiti-register.mjs

# Run the new framing suite. Expected: exit 0, `ℹ fail 0` (the multibyte-split test
# proves StringDecoder is load-bearing; the U+2028/U+2029 test proves LF-only splitting).
node --import "$JITI_REG" extension/tests/jsonl-reader.test.ts
# (jiti prints a benign DeprecationWarning on Node 26 stderr — judge by exit code + ℹ fail.)

# Full regression: every pre-existing suite still green (S7 is purely additive: it
# touches nothing these read). Expected: each prints `ℹ fail 0`.
for t in provider-capture mode-guard protocol bridge-lifecycle bridge-lifecycle-wiring; do
  echo "--- $t ---"
  node --import "$JITI_REG" "extension/tests/$t.test.ts" 2>/dev/null | grep -E "^ℹ (pass|fail)"
done
```

### Level 3: Integration Testing (System Validation)

```bash
# Regression: the extension still loads cleanly under pi. jsonl-reader.ts is NOT imported
# by the entry point yet (S8 does that), so this proves S7's new module + include edit
# did not disturb the load path. Expected: exits 0, prints "ok", NO error lines.
pi --no-extensions -e ./extension/pi-editor-bridge.ts --print "ok" 2>&1 | tee /tmp/s7-pi.log
grep -iE "error|cannot|fail|throw|TypeError" /tmp/s7-pi.log && echo FAIL || echo PASS

# (Optional, manual) End-to-end framing smoke: feed a real socket pair through the reader
# to confirm it frames net.Socket data exactly like the unit tests frame Readable.from.
# Not required for S7's contract (the unit tests are authoritative for framing), but useful
# confidence that S8's one-line wiring will work:
#   node -e 'const net=require("net");const s=net.createServer(c=>{require("./extension/jsonl-reader.ts")});'
# (Skip if the Level 2 suite is green — the framing logic is transport-agnostic.)
```

### Level 4: Creative & Domain-Specific Validation

```bash
# (S7 has no domain-specific / performance / security validation beyond Levels 1–3.
#  The framing correctness IS the domain contract — fully covered by the Level 2 suite.)
# Documentation cross-check: confirm protocol.ts's JSDoc promise ("the authoritative framing
# mirror is pi's own dist/modes/rpc/jsonl.js ... IMPLEMENTED by the JSONL reader task (S7)")
# is now fulfilled by diffing the new module's logic against pi's source:
diff <(sed 's/[[:space:]]*$//' /home/dustin/projects/pi/packages/coding-agent/src/modes/rpc/jsonl.ts | grep -vE '^\s*(//|/\*|\*|import type)' ) \
     <(sed 's/[[:space:]]*$//' extension/jsonl-reader.ts | grep -vE '^\s*(//|/\*|\*)') \
  && echo "LOGIC MIRROR OK (only comments/JSDoc differ from pi's source)" \
  || echo "WARN: logic differs from pi's mirror — review the diff"
# Expected: only JSDoc/comments differ; the executable statements match pi verbatim.
```

## Final Validation Checklist

### Technical Validation

- [ ] `tsc --noEmit -p extension/tsconfig.json` → exit 0, no output.
- [ ] `node --import "$JITI_REG" extension/tests/jsonl-reader.test.ts` → exit 0, `ℹ fail 0`.
- [ ] All 5 pre-existing suites report `ℹ fail 0` (regression).
- [ ] `pi --no-extensions -e ./extension/pi-editor-bridge.ts --print "ok"` exits 0, no error lines.

### Feature Validation

- [ ] `serializeJsonLine` is LF-terminated, preserves U+2028/U+2029, round-trips through `JSON.parse`.
- [ ] `attachJsonlLineReader` handles: single line, multi-line-one-chunk, partial-across-chunks,
      CRLF (`\r` stripped), final-line-no-trailing-LF (end flush), U+2028/U+2029-preserved,
      multibyte-split (StringDecoder), empty input, and detach (no further emits + listeners removed).
- [ ] The reader emits RAW `string` lines (no `JSON.parse` / dispatch / envelope narrowing — S8's job).
- [ ] The reader does NOT attach `error`/`close` (connection-lifecycle = S8); detach removes only `data`/`end`.

### Code Quality Validation

- [ ] Logic is a verbatim mirror of pi's `modes/rpc/jsonl.ts` (Level 4 diff confirms only comments differ).
- [ ] Node builtins only (`node:stream`, `node:string_decoder`) — no npm deps (PRD §6.7).
- [ ] TAB indentation; `import type` for `Readable`; Mode-A JSDoc with `STATUS (P1.M2.T4.S7)` markers.
- [ ] The ONLY tsconfig change is appending `"jsonl-reader.ts"` to `include`; `compilerOptions` UNCHANGED.
- [ ] `pi-editor-bridge.ts` and `protocol.ts` are byte-for-byte UNCHANGED.

### Documentation & Deployment

- [ ] Module JSDoc cites PRD §5.2 + §16 and pi's `modes/rpc/jsonl.ts` as the verbatim mirror.
- [ ] The `onConnection` placeholder's `// TODO(S8)` comment is intact (the S8 import site).
- [ ] No new environment variables, no config, no process.env writes.

---

## Anti-Patterns to Avoid

- ❌ **Don't "improve" pi's reader.** No readline, no `/\r?\n/` regex, no dropping the
  `StringDecoder`, no skipping the `onEnd` flush, no removing the `\r` strip, no inlining
  the handlers (breaks `.off()` identity). Each element satisfies a PRD §5.2 rule or
  prevents a verified corruption mode. Copy it verbatim.
- ❌ **Don't edit `compilerOptions` in tsconfig.** The transitive `node:*` resolution
  (research §3) depends on `compilerOptions` being EXACTLY as-is. A `typeRoots`/`types`/
  `lib` change can BREAK `node:stream`/`node:string_decoder`/`Buffer` resolution
  (verified by a failed probe). The ONLY edit is appending `"jsonl-reader.ts"` to `include`.
- ❌ **Don't wire the reader into the socket in S7.** `onConnection` wiring, `JSON.parse`,
  envelope narrowing, dispatch, and per-socket `error`/`close` handling are ALL S8's job
  (the "connection handling" half of parent task P1.M2.T4). S7 ships an isolated, tested
  module; S8 imports it. Editing `pi-editor-bridge.ts` = scope violation.
- ❌ **Don't add `JSON.parse` to the reader.** The reader emits raw `string` lines. Parsing
  + narrowing + dispatch is S8; error-wrapping a parse throw is S15 (-32700).
- ❌ **Don't use vitest.** pi's own `rpc-jsonl.test.ts` uses vitest, but the bridge
  extension's house convention is `node:test` + `node:assert/strict` + jiti (verified across
  all 5 existing suites). Use `Readable.from([...])` to feed data and `await` the stream
  `'end'`.
- ❌ **Don't concatenate the test's buffers into one string.** To test partial-line buffering
  and multibyte-split, pass an ARRAY of Buffers to `Readable.from` — each element is a
  separate `data` event. Concatenating defeats the test.
- ❌ **Don't add module state.** The reader's `decoder`/`buffer` are closure-captured
  per-`attachJsonlLineReader`-call locals, so two sockets get independent readers with no
  shared singleton (unlike the server in `pi-editor-bridge.ts`). No module-level `let`.
- ❌ **Don't skip the detach return.** S8 needs it to clean up on socket close/error.
  Omitting it leaks two listeners per connection and gives S8 no teardown path.
