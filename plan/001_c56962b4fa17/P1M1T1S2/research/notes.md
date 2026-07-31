# Research Notes — P1.M1.T1.S2 (Provider capture via pass-through addAutocompleteProvider factory)

Scope: NARROW. Add a **pass-through** `addAutocompleteProvider` factory that
**captures a reference** to pi's live autocomplete chain with **zero behavior
change**, expose it via `getProvider()`, and wire the capture into the
`session_start` handler created by S1. TUI-mode guard = S3 (separate). Socket
server = M2; env advertisement = S16; commandsChanged = S17. **Do not implement
those here.**

S1 (the immediately-preceding task) produces `extension/pi-editor-bridge.ts`
(default-export factory + `session_start`/`session_shutdown` handlers + a dev-only
`extension/tsconfig.json`). S2 **modifies** that file and its tsconfig, and adds
one test file. See `../P1M1T1S1/PRP.md` for the exact S1 baseline.

---

## 1. The public hook — VERIFIED against installed dist

Pi: `@earendil-works/pi-coding-agent@0.80.10` at
`/home/dustin/.local/lib/node_modules/@earendil-works/pi-coding-agent`.

### `addAutocompleteProvider` mechanics (interactive mode)
`dist/modes/interactive/interactive-mode.js`:
- **L1673–1674** (inside the `ExtensionUIContext.addAutocompleteProvider` impl):
  ```js
  this.autocompleteProviderWrappers.push(factory);
  this.setupAutocompleteProvider();   // rebuilds the WHOLE chain immediately
  ```
  → pushing a factory **immediately re-runs every factory in order**. Our
  pass-through factory is invoked synchronously with the current chain as `current`
  and its return value becomes the new provider. (Source refs: research-pi-autocomplete.md
  §"`addAutocompleteProvider` on the UI context" → interactive-mode.ts:2143-2146.)
- **L415–~425** `setupAutocompleteProvider()`: starts from
  `createBaseAutocompleteProvider()` (a `CombinedAutocompleteProvider`) and folds
  each wrapper: `provider = wrapProvider(provider)`. So the factory's `current`
  arg is **at minimum** the `CombinedAutocompleteProvider` (slash cmds, templates,
  extension cmds, skill cmds, `@`/path/`fd` logic).
- **L1507** (session reset): `this.autocompleteProviderWrappers = [];` followed by
  `this.setupAutocompleteProvider();` (L1509). → **Wrappers are CLEARED on session
  reset.** Re-registering on every `session_start` is therefore REQUIRED, not
  optional. (Source ref: interactive-mode.ts:1952.)

### `addAutocompleteProvider` is a NO-OP in RPC mode
`dist/modes/rpc/rpc-mode.js` **L193–195**:
```js
addAutocompleteProvider() {
    // Autocomplete provider composition is not supported in RPC mode
},
```
→ Calling it in non-TUI modes is **safe (does not throw)** but captures nothing.
This is exactly why **S3** adds the `ctx.mode === "tui"` guard; S2 calls it
unconditionally and leaves a TODO for S3. (Source ref: rpc-mode.ts:271-273.)

### Print mode: `ctx.ui.addAutocompleteProvider` is present & callable
Probe `pi --no-extensions -e ext.ts --print "ok"` with an extension that calls
`ctx.ui.addAutocompleteProvider(...)` in `session_start` fired successfully with
**no error** (`[S2-PROBE] session_start fired; addAutocompleteProvider called`).
→ S2's unconditional capture call is safe in every mode; capture simply has no
effect outside TUI. (Guard = S3.)

---

## 2. Type surface — VERIFIED

### `AutocompleteProvider` must come from `@earendil-works/pi-tui`
- `dist/core/extensions/types.d.ts:12` imports it FROM pi-tui:
  `import type { AutocompleteItem, AutocompleteProvider, ... } from "@earendil-works/pi-tui";`
- `dist/index.d.ts` re-exports `AutocompleteProviderFactory` but **NOT**
  `AutocompleteProvider` itself (grep of the big `export type { ... }` list shows
  `AutocompleteProviderFactory` only). → **Cannot import `AutocompleteProvider`
  from `@earendil-works/pi-coding-agent`; MUST use `@earendil-works/pi-tui`.**
  This matches the item description and the canonical example
  (`examples/extensions/github-issue-autocomplete.ts`):
  ```ts
  import { type AutocompleteProvider, ... } from "@earendil-works/pi-tui";
  ```

### pi-tui install location — CRITICAL GOTCHA
`@earendil-works/pi-tui` is **NOT** a top-level global install. It is **nested**:
`/home/dustin/.local/lib/node_modules/@earendil-works/pi-coding-agent/node_modules/@earendil-works/pi-tui`
(`package.json` `{main:"dist/index.js", types:"./dist/index.d.ts", exports:"none"}`).
- **Runtime (jiti):** `import type` is erased → never resolved at runtime → the
  extension loads with zero node_modules at the top level. (Confirmed by probe.)
- **tsc:** the S1 dev tsconfig `paths` map must add an entry for pi-tui pointing
  at the **nested** dist index. Verified working:
  ```jsonc
  "@earendil-works/pi-tui": [
    "/home/dustin/.local/lib/node_modules/@earendil-works/pi-coding-agent/node_modules/@earendil-works/pi-tui/dist/index.d.ts"
  ]
  ```
  (With this, `tsc --noEmit -p extension/tsconfig.json` → exit 0 on a probe that
  imports both packages. Without the nested path, `tsc` reports
  `TS2307: Cannot find module '@earendil-works/pi-tui'`.)

### `AutocompleteProviderFactory` shape
`dist/core/extensions/types.d.ts:61`:
`export type AutocompleteProviderFactory = (current: AutocompleteProvider) => AutocompleteProvider;`
→ our pass-through factory is `(current) => { liveProvider = current; return current; }`.
Return type = the same `AutocompleteProvider` we received. **Zero behavior change.**

---

## 3. Canonical reference example
`examples/extensions/github-issue-autocomplete.ts` (full file read):
- `import { type AutocompleteItem, type AutocompleteProvider, type AutocompleteSuggestions, fuzzyFilter } from "@earendil-works/pi-tui";`
- `export default function (pi: ExtensionAPI): void { pi.on("session_start", async (_event, ctx) => { ... ctx.ui.addAutocompleteProvider((current) => createIssueAutocompleteProvider(current, getIssues)); }); }`
- Pattern for the factory: receive `current`, return a provider (the example
  WRAPS; we PASS-THROUGH — return `current` unchanged). The example **uses tabs**
  for indentation and prefixes unused params with `_`. Match both.

---

## 4. Named exports alongside `export default` — SAFE
pi's loader (`loader.ts:485-498`) does `await factory(api)` on the **default**
export only. Extra **named** exports (`captureProvider`, `getProvider`) are
harmless ES-module members that pi ignores but tests can import. **Verified:** a
probe extension with `export function getProvider()` next to `export default`
loaded via `pi -e` and fired `session_start` with no error.

---

## 5. Test runner — VERIFIED, zero new npm deps
No TS test framework exists yet (S1 deferred it). S2's contract **requires** a
test that mocks `ctx.ui.addAutocompleteProvider`, so S2 establishes the pattern.

- **Runner:** Node's built-in `node:test` + `node:assert/strict` (Node 26 on
  PATH; built-in, zero deps). Aligns with PRD §6.7 "No npm runtime dependencies".
- **TS loader:** jiti v2.7.0 (nested at
  `…/pi-coding-agent/node_modules/jiti`) exposes a module-register hook at
  `lib/jiti-register.mjs`. Run a `.ts` test with:
  ```bash
  node --import /home/dustin/.local/lib/node_modules/@earendil-works/pi-coding-agent/node_modules/jiti/lib/jiti-register.mjs \
       extension/tests/provider-capture.test.ts
  ```
  **Verified end-to-end:** a `node:test` TS file ran ✔ 2/2 pass, exit 0.
  (Caveat: jiti v2.7.0 on Node 26 prints a harmless
  `DeprecationWarning: module.register() is deprecated` to stderr — ignore; check
  exit code + `pass`/`fail` counts, not stderr cleanliness.)
- This establishes the reusable TS test pattern for later tasks (M2 RPC handlers,
  etc.).

### Test-isolation note (module singleton state)
`liveProvider` is a module-level `let`. Within one test-file process, state
persists across tests in definition order (node:test runs sequentially by
default). Therefore the **"`getProvider()` throws before capture"** assertion
MUST be the FIRST test in the file (before any `captureProvider()` call). Do NOT
enable test concurrency for this file.

---

## 6. What `current` actually is (informs JSDoc + future RPC handlers)
At first registration, `current` = the base `CombinedAutocompleteProvider`
(slash commands + prompt templates + extension commands + skill commands + cwd +
`fd` path; owns all `@`/path/`fd` logic — see research-pi-autocomplete.md §1).
If other extensions registered wrappers BEFORE ours, `current` is their already-
wrapped chain. Either way, capturing `current` gives the bridge **everything**
the TUI's editor sees. Future RPC handlers (S11–S14) call
`getProvider().getSuggestions/applyCompletion/shouldTriggerFileCompletion`
directly — no need to re-implement completion.

---

## 7. Residual risks / gotchas for S2
1. **Re-registration on every `session_start` is MANDATORY** (wrappers cleared at
   session reset, interactive-mode.js:1507). The capture MUST live inside the
   `session_start` handler, not the factory body.
2. **`AutocompleteProvider` is import-from-pi-tui-only** (not re-exported by
   pi-coding-agent). Using the wrong source = `TS2307` / `Element implicitly any`.
3. **tsc `paths` must point pi-tui at the NESTED node_modules** (top-level path
   does not exist). This is the single most likely S2 failure if missed.
4. **Pass-through must return `current` unchanged** — do NOT construct a wrapper
   object (that would be a behavior change and belong to a different design).
   The contract is explicitly "zero behavior change".
5. **`getProvider()` throws (does not return undefined)** before capture — RPC
   handlers (later) rely on this to fail loud, not silent.
6. Keep capture call **unconditional** in S2 (no `ctx.mode` guard) — that is S3.
   Leave a TODO comment marking the S3 guard insertion point.
