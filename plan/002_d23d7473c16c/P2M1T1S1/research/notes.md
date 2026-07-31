# Research notes — P2.M1.T1.S1 (shell fields on BridgeDescriptor/HelloResult/PingResult)

> Scope: a **type-only** change to `extension/protocol.ts` — add three OPTIONAL
> fields (`shell?`, `shellSource?`, `shellPath?`) to `BridgeDescriptor`,
> `HelloResult`, `PingResult`; update the §B header comment + §C per-type
> comments ([Mode A]). Plus compile-time test assertions in
> `extension/tests/protocol.test.ts`. NO runtime change, NO descriptor population
> (that is S2/S3).

## 1. Exact current state (verified by reading the file)

`extension/protocol.ts` (264 lines). All targets verified by `grep -n`:

| Target | Lines | Current content (excerpt) |
|---|---|---|
| §B header comment | L74–82 | `… MUST be a plain JSON object (all fields required, JSON-serializable). …` |
| `BridgeDescriptor` | L83–91 | 7 fields: `transport`/`path`/`token`/`pid`/`cwd`/`fdAvailable`/`serverVersion` |
| §C HelloResult comment | L106 | `` `hello` (C→S) success result: server identity + capabilities. `` |
| `HelloResult` | L107–112 | 4 fields: `ok`/`serverVersion`/`cwd`/`fdAvailable` |
| §C PingResult comment | L116 | `` `ping` (C→S) result: liveness + server info. `` |
| `PingResult` | L117–123 | 5 fields: `ok`/`pid`/`cwd`/`fdAvailable`/`serverVersion` |

> The contract's line refs (83-91 / 107-112 / 117-123 / "L73-82 header") match the
> file EXACTLY. The "L570" satisfies-guard ref is slightly stale — the actual guard
> is at `extension/pi-nvim-bridge.ts:578` (`} satisfies BridgeDescriptor);`).

## 2. Why OPTIONAL fields are 100% back-compatible (proven, not assumed)

Adding `field?: T` to an interface does NOT require existing consumers to supply
the field. Verified consumers that OMIT the new fields and therefore still compile:

- **`pi-nvim-bridge.ts:578`** — `JSON.stringify({ …7 fields… } satisfies
  BridgeDescriptor)`. Still satisfies (shell fields optional). **No edit needed here.**
- **`pi-nvim-bridge.ts:629`** `makeHelloHandler` returns `HelloResult` built from
  `{ ok, serverVersion, cwd, fdAvailable }` — still valid (4 fields, shell optional).
- **`pi-nvim-bridge.ts:676`** `makePingHandler` returns `PingResult` built from
  `{ ok, pid, cwd, fdAvailable, serverVersion }` — still valid.
- **`tests/protocol.test.ts`** — `const desc: BridgeDescriptor = {…7…}`,
  `const helloRes: HelloResult = {…4…}`, `const pingRes: PingResult = {…5…}`. All
  still type-check.

So: ZERO runtime change. The descriptor on the wire is UNCHANGED after this task
(startBridge still writes 7 fields until S2 populates shell). This task only widens
the TYPE to PERMIT shell fields.

## 3. Field semantics (PRD §17.10.1 / research-prd-section-17.md)

```ts
shell?: string;                               // "/bin/zsh" — resolved execution shell binary
shellSource?: "pi" | "$SHELL" | "default";    // how `shell` was derived
shellPath?: string;                           // raw shellPath setting, if the user set one
```

`shellSource` values:
- `"pi"`      — derived from the user's `shellPath` (mirrored via `PI_NVIM_SHELL`
  env var, since `settingsManager`/`getShellConfig` are NOT on `ExtensionContext`).
- `"$SHELL"`  — extension fell back to `process.env.SHELL`.
- `"default"` — pi's `getShellConfig` default on Unix: `/bin/bash`.

> `$SHELL` (with the `$`) is a valid TS string-literal type member of the union.
> No quoting escape needed.

**Advisory / honesty note (PRD §17.10.2):** these fields are ADVISORY — the plugin
works correctly even if they are absent (it falls back to `$SHELL`). This is the
one place §17 reaches past pi's public extension API (the extension replicates
`getShellConfig`'s ~10-line resolution). The §B/§C comments MUST state this so a
future reader doesn't assume `shell` is authoritative.

## 4. Why mirror into HelloResult + PingResult (not just BridgeDescriptor)

PRD §17.10.1: *"The hello result mirrors these (it already carries
cwd/fdAvailable)."* The plugin reads shell info from TWO places:
1. The **descriptor** (`process.env.PI_NVIM_BRIDGE`, pre-handshake, at VimEnter) —
   lets the plugin pick a driver BEFORE connecting.
2. The **hello**/**ping** result (post-handshake, live) — a fresher/canonical value
   and the one `:checkhealth` reports.

PingResult is `HelloResult + pid`, so it mirrors too. Keeping descriptor / hello /
ping in sync on shell fields mirrors the EXISTING pattern for `cwd`/`fdAvailable`/
`serverVersion` (the 001 plan's "three sources agree" rationale). S3 wires the
hello/ping handlers; S4 extracts them on the lua side into `M.server_info`.

## 5. Forward contracts (do NOT implement in S1 — just don't break them)

- **S2** — adds `resolveShell()` + populates the descriptor literal at L578 with
  `shell`/`shellSource`/`shellPath`. Needs these types to EXIST + accept the fields.
- **S3** — adds shell fields to `makeHelloHandler`/`makePingHandler` return values
  (deps-injection of a `getShell` getter). Needs `HelloResult`/`PingResult` to
  permit the fields.
- **S4** — `lua/pi-bridge/bridge.lua` `M.server_info` extracts `shell`/`shellSource`
  from the descriptor + hello result. Needs the TS types to be the wire contract.

## 6. Validation (verified commands — baseline green BEFORE the change)

```bash
# Type-check gate (THE gate for a type-only change):
npx tsc --noEmit -p extension/tsconfig.json            # baseline: exit 0

# Test runner (node:test + jiti, no compile):
JITI_REG=/home/dustin/.local/lib/node_modules/@earendil-works/pi-coding-agent/node_modules/jiti/lib/jiti-register.mjs
node --import "$JITI_REG" extension/tests/protocol.test.ts   # baseline: 2 pass / 0 fail

# Regression (optional fields must NOT break the handler/satisfies consumers):
node --import "$JITI_REG" extension/tests/hello-handler.test.ts
node --import "$JITI_REG" extension/tests/ping-bye-getcommands-handler.test.ts
node --import "$JITI_REG" extension/tests/bridge-env.test.ts
```

`extension/tsconfig.json`: `strict: true`, `exactOptionalPropertyTypes` NOT set
(so `field?: T` is the standard optional — no `T | undefined` quirk). `include`
auto-covers `protocol.ts` + `tests/**/*.ts` → NO tsconfig edit for the test additions.

## 7. tsconfig / style notes

- Indentation in `protocol.ts` is **TABS** (verified — every `interface` body uses
  `\t`). Match tabs in the new field lines (NOT spaces).
- Inline field comments use `// …` trailing the field (see the PRD §17.10.1 sample).
- The §B/§C block comments are `/* … */` with `*`-prefixed continuation lines + a
  boxed `===…` header — match that style when amending.