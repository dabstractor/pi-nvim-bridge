# Research notes — P2.M1.T1.S4 (Extract shell fields in bridge.lua M.server_info + descriptor type)

> Lua-side extraction of the §17.10 advisory shell fields. Consumes S1 (types) + S2
> (descriptor resolver) + S3 (hello/ping RPC mirror). All line numbers + baselines
> verified LIVE on 2025-07-31 against the current tree.

## 0. What this task is (one paragraph)

S2 put `shell`/`shellSource`/`shellPath` on the `PI_NVIM_BRIDGE` **descriptor** (env var).
S3 mirrored them into the **`hello`/`ping` RPC results** (conditional spread — keys absent
when unresolved). S4 (THIS task) is the **Lua read side**: (a) extend the `ServerInfo` +
`BridgeDescriptor` lua class annotations, (b) defensively extract the three fields into
`M.server_info` at handshake success (result-or-descriptor fallback), (c) export
`M.get_shell_info()` so `shell.lua` (P2.M1.T2) can read one merged view. Pure lua; no
transport/protocol/RPC change; no new wire method.

## 1. Verified current line numbers (the edit anchors)

### `lua/pi-bridge/bridge.lua` (848 lines)
- **ServerInfo class**: L183 `---@class pi-bridge.ServerInfo`; fields L184-186; L187
  `---@type pi-bridge.ServerInfo|nil`; L188 `M.server_info = nil`.
- **Extraction site** (inside `resolve_handshake`, success branch):
  - L326 `local r = msg.result`
  - L327 `local info = {`
  - L328 `serverVersion = (type(r.serverVersion) == "string") and r.serverVersion or "",`
  - L329 `cwd           = (type(r.cwd) == "string") and r.cwd or (desc.cwd or ""),`
  - L330 `fdAvailable   = (r.fdAvailable == true),`
  - L331 `}`
  - L332 `M.server_info = info`
  - (`desc` here = `handshake_state.desc` = the descriptor passed to `M.handshake` = the
    same table init.lua stores as `M.descriptor` at activate() time.)
- **Public API tail**: `M.is_connected()` @ L845-847; `return M` @ L849. ← insertion point
  for `M.get_shell_info()` (after `is_connected`, before `return M`).
- `resolve_handshake` is a forward-declared local (`local resolve_handshake` near L248)
  assigned as `resolve_handshake = function(msg, err) … end` in the "S25" section. ←
  insertion point for the `pick_str` helper (immediately before that assignment).
- `M.close()` clears `M.server_info = nil` @ L788 (reconnect hygiene — unchanged by S4).

### `lua/pi-bridge/init.lua`
- **BridgeDescriptor class**: L98 `---@class pi-bridge.BridgeDescriptor`; fields L99-105;
  L110 `M.descriptor = nil`. The doc comment above (L93-97) ends with: "Mirrors the
  extension's BridgeDescriptor (extension/protocol.ts); all fields are present & non-null
  when transport==\"unix\"." ← this sentence needs the §17.10 optional caveat appended.
- `M.descriptor` is set in `activate()` from the parsed env var (L141 `M.descriptor = desc`).
  Carries whatever the extension put in the blob — incl. the §17.10 fields once S2 ships.

## 2. The contract (from the task description + PRD §17.10)

```
(a) ServerInfo class (bridge.lua L183-187)  += shell, shellSource, shellPath  (all optional)
(b) extraction (L329-333)  info.shell       = result.shell       or descriptor.shell
                            info.shellSource = result.shellSource or descriptor.shellSource
                            info.shellPath   = result.shellPath
(c) BridgeDescriptor class (init.lua L98-108) += shell, shellSource, shellPath (optional)
(d) M.get_shell_info() -> { shell, shellSource, shellPath } | nil
       from M.server_info  (or M.descriptor if server_info is nil)
```

shellSource union is the literal `"pi" | "$SHELL" | "default"` (the `$SHELL` member has a `$`).
All three fields are **ADVISORY + OPTIONAL** (PRD §17.10.1: "absent on older clients is fine
— the plugin falls back to `$SHELL`"). ⇒ on the Lua side they must be **`nil` when unresolved,
NOT `""`** (an empty string is a bogus shell path and would defeat shell.lua's fallback chain).

## 3. Design decisions (the judgment calls — spelled out for the implementer)

### 3a. A `pick_str(a, b)` helper instead of triple-nested ternary
The contract literal `info.shell = result.shell or descriptor.shell` is the direct form. But
the existing extraction type-checks every field (defends a malformed server: `getCwd() ?? ""`
discipline). Mirroring that for 3 fields naïvely yields:
```lua
shell = (type(r.shell)=="string") and r.shell or (type(desc.shell)=="string" and desc.shell or nil),
```
×3 — ugly + copy-paste-prone. Instead define ONCE (local, before `resolve_handshake`):
```lua
local function pick_str(a, b)
  if type(a) == "string" then return a end
  if type(b) == "string" then return b end
end  -- returns nil when neither is a string (advisory field absent)
```
Then `shell = pick_str(r.shell, desc.shell)` ×3. Clean, DRY, self-documenting, never throws.
This is the ONE small new pattern; it is local + trivial + documented. (Inline ternary is
also acceptable but worse; see Anti-Patterns.)

### 3b. Why shell fields are `nil`, not `""` (unlike cwd/serverVersion)
`cwd`/`serverVersion` are REQUIRED result fields → default `""` when malformed (the server's
`getCwd() ?? ""`). `shell*` are OPTIONAL/advisory → must be ABSENT (`nil`) when unresolved so
shell.lua's fallback chain (`descriptor.shell → $SHELL → /bin/bash`, PRD §17.4) engages. A
`""` would be a bogus path that short-circuits the fallback. `pick_str` returns nil by design.

### 3c. `get_shell_info()` source priority: server_info → descriptor → nil
- `M.server_info` (live `hello`/`ping` RPC result, post-handshake) wins — most authoritative.
- Else `require("pi-bridge").descriptor` (the env-var blob, available from `activate()` —
  covers the **pre-handshake window**: shell.lua may resolve the shell at first `!` activation
  BEFORE the async handshake resolves; the descriptor is the only source then).
- Else `nil`.
- **No per-field re-fallback needed**: at extraction time `server_info.shell` is ALREADY the
  merged `pick_str(r.shell, desc.shell)` value (result-or-descriptor). So once server_info is
  set, it carries the best-available merged value; reading it wholesale is correct.
- Returns a **fresh table** (shallow copy) so the caller cannot mutate module state.

### 3d. `require("pi-bridge")` inside bridge.lua is safe (no circular-require hazard)
bridge.lua ALREADY does `require("pi-bridge").bridge = M` (resolve_handshake L333) and
`local cfg = require("pi-bridge")` (M.handshake L559) — both at runtime, after init.lua is
fully loaded. `get_shell_info()` runs post-activate (shell.lua calls it), so the same
`require("pi-bridge")` returns the already-loaded init module table. No issue.

## 4. Test plan (tests/bridge_handshake_spec.lua — the S25 spec; 12 cases today)

Baseline (verified): **12 success / 0 fail / 0 errors**, exit 0.
Command: `timeout 90 nvim --headless --clean -u tests/minimal_init.lua -c 'lua require("plenary.busted").run("tests/bridge_handshake_spec.lua")'`

The `with_hello_server(opts, spec)` helper (L40-) spins a luv server whose "success" mode
replies `{ok, serverVersion, cwd, fdAvailable}`. The `descriptor(path)` helper (L24-) builds a
descriptor with cwd/fdAvailable/serverVersion but NO shell fields.

**Changes:**
1. `descriptor(path, shell_fields?)` — add an OPTIONAL 2nd arg; backward-compatible (existing
   callers pass 1 arg). When `shell_fields` is a table, copy its `shell`/`shellSource`/
   `shellPath` onto the descriptor.
2. `with_hello_server` "success" reply — build the `result` table, then **conditionally** add
   `shell`/`shellSource`/`shellPath` ONLY when `opts` provides them (mirrors S3's
   conditional-spread wire shape: keys absent when unresolved → existing tests that don't pass
   shell get a result without shell keys → their asserts are unaffected).
3. **3 new test cases** (12 → 15):
   - **shell-from-result**: `opts = {shell="/bin/zsh", shellSource="pi", shellPath="/bin/zsh"}`,
     plain `descriptor(path)` → assert `server_info.shell/shellSource/shellPath` carry them.
   - **descriptor-fallback**: plain success reply (no shell in result),
     `descriptor(path, {shell="/bin/fish", shellSource="$SHELL"})` (shellPath OMITTED) →
     assert `server_info.shell=="/bin/fish"`, `.shellSource=="$SHELL"`, `.shellPath==nil`
     (proves optional + the result-or-descriptor merge).
   - **get_shell_info accessor** (no server): set/restore `pi.descriptor` + `bridge.server_info`
     manually; assert (i) both nil → `nil`; (ii) descriptor-only → its values; (iii) server_info
     wins over descriptor; (iv) returned table is a fresh copy (mutating it doesn't touch
     `bridge.server_info.shell`). reset_module() + save/restore `pi.descriptor` for hygiene.

**No breakage of existing 12**: the (a) success test asserts only `serverVersion`/`cwd`/
`fdAvailable` (field-by-field, NOT a deepEqual) → adding `shell=nil` to server_info (default
reply has no shell, default descriptor has no shell) is invisible to it. The (j) close-clears-
server_info test asserts nil-after-close → unaffected.

## 5. Baselines (verified 2025-07-31, BEFORE S4)

| suite | result | cmd |
|---|---|---|
| bridge_handshake_spec (plenary) | 12/0/0 exit 0 | `…-c 'lua require("plenary.busted").run("tests/bridge_handshake_spec.lua")'` |
| bridge_smoke (plenary-free) | SMOKE_PASS exit 0 | `…-u NORC +"luafile tests/bridge_smoke.lua" +qa` |
| init_spec | 14/0/0 | (annotation edit to init.lua is non-functional; regression guard) |
| health_spec | 13/0/0 | (health reads server_info; unaffected by added optional fields) |

No lua linter/formatter config at repo root (no luacheck/selene/stylua/.luarc). The ONLY
"type" surface is the luaemmy `---@class`/`---@field` annotations (consumed by lua-language-
server, not enforced at runtime). So S4's validation = the plenary spec + the smoke.

## 6. What this task does NOT touch (scope fence)

- NO transport/protocol/connection change (S24-S27 own those).
- NO new RPC method (`getShellInfo` is a Lua-side accessor over already-extracted state).
- NO edit to `extension/*` (S1/S2/S3 own the TS side — DONE/Implementing).
- NO edit to `shell.lua` (P2.M1.T2 owns it; S4 only EXPORTS `get_shell_info` for it to consume).
- NO docs beyond the inline `---@field` annotations + their doc comments (Mode-A; the vimdoc
  `doc/pi-bridge-shell.txt` is P2.M3.T6.S4, the README is P2.M4.T7).
- NO change to how `M.server_info` is cleared on `close()` (L788) — shell fields ride along.

## 7. The "No Prior Knowledge" check

An implementer who has never seen this repo gets, from the PRP alone:
- the EXACT before/after for all 4 edits (verbatim blocks),
- the verified line numbers + grep anchors (don't trust them blindly — they're post-S25/2025-07),
- the test-extension recipe (which helper to extend, which 3 cases to add, save/restore hygiene),
- the validation commands (verified to run green at baseline),
- the design rationale (why nil not "", why the helper, why server_info→descriptor priority).