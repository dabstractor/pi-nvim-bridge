# Delta PRD — omp Host Compat + Shell Completion for `!`/`!!` Bash Mode

> Delta between session 001 (`delta_from.txt = 1`) and the current PRD snapshot.
> Two distinct changes are layered onto the already-complete P1–P4 bridge (extension +
> plugin). This delta PRD scopes **only** the new/modified requirements.

---

## 0. Diff analysis (what actually changed)

### Change A — Host compatibility (oh-my-pi / `omp`) — **CODE-COMPLETE; docs only**

Scattered additive edits across the PRD: §2.1 ("Host compat" note), §6.2 ("TUI-only
gate is host-aware"), §6.6 (default export uses `isInteractiveSession(ctx)`), §6.8
(**new** "Host compatibility — pi and oh-my-pi" section with a divergence table),
§10.1 (prerequisites mention the omp fork), §10.2 (install shows `omp plugin …`
commands).

**Critical finding — the code is already implemented.** The previous session shipped
the dual-detection mode gate:

- `extension/pi-nvim-bridge.ts` already defines `isInteractiveSession(ctx)` ≈ L1118–1138:
  `ctx.mode === "tui" || (ctx as ExtensionContext & { hasUI?: boolean }).hasUI === true`.
- `session_start` already calls it as the first guard (≈ L1155:
  `if (!isInteractiveSession(ctx)) return;`).
- The descriptor (`startBridge` ≈ L570–578) is host-agnostic; `package.json` ships the
  `"pi": { "extensions": [...] }` manifest key that omp discovers via its
  `(pkg.omp ?? pkg.pi).extensions` fallback. The plugin side keys only on the
  `PI_NVIM_BRIDGE` env var, which propagates under both Node (pi) and Bun (omp).

**Residual work = documentation only** (README install instructions for the omp host).
No code task. This is a **tiny** delta.

### Change B — Shell Completion for `!`/`!!` Bash Mode (PRD §17) — **NEW SUBSYSTEM**

A large additive subsystem: a new goal + 3 non-goals (§1), the §3 architecture diagram
gains `shell.lua`, §9 file layout gains `lua/pi-bridge/shell*` + `doc/pi-bridge-shell.txt`
+ `tests/shell/`, §11 gains ~7 shell edge cases, §12 gains a shell-daemon security
bullet, §13 gains **Phase 6** (steps 21–29), §14 gains 6 shell spec files, §15 gains
shell future enhancements, and the **entire §17** (~600 lines, 18 subsections) is new.

**Component A (the extension) changes by exactly one descriptor field-set**
(`shell`/`shellSource`/`shellPath`, all optional). **Everything else is plugin-side.**

#### Verified grounding (pi repo at `~/projects/pi`, all §17.18 claims confirmed)

| Claim | Verified at |
|---|---|
| `getShellConfig()` defaults `/bin/bash` on Unix, honors `customShellPath` | `utils/shell.ts:67` (default path `:110–111`) |
| `shellPath` setting → `getShellPath()` → `executeBash` → `createLocalBashOperations({ shellPath })` | `settings-manager.ts:98,879`; `agent-session.ts:2712–2728` |
| `isBashMode` = `text.trimStart().startsWith("!")` | `interactive-mode.ts:2583` |
| `!`/`!!` keybinding hints | `interactive-mode.ts:745–746` |
| `handleBashCommand` | `interactive-mode.ts:5893` |
| `settingsManager`/`getShellConfig` **not** on `ExtensionContext` | confirmed — extension must replicate resolution |

Shell binaries on the dev machine: `fish`, `zsh`, `bash` all on `PATH` (test gating).

#### Existing surfaces this delta extends (do NOT re-implement)

- `lua/pi-bridge/completion.lua` — `completion_context(lines, cursorLine, cursorCol)`
  returns `"slash"`/`"path"`/`nil` (≈ L375). Needs a new `"shell"` return value placed
  **before** the slash/path checks. `do_refresh` (L406) and `force_fetch` (L508) need a
  shell branch. Supersession uses a `state.gen` gen-guard to mirror.
- `lua/pi-bridge/menu.lua` — **reused unchanged**. Shell items normalize to the same
  `AutocompleteItem { value, label, description? }` shape the menu already renders.
- `lua/pi-bridge/notify.lua` — **reused** for the dedup'd one-shot `prefer:"pi"`
  mismatch notice, first-run hint, and degrade notify.
- `lua/pi-bridge/init.lua` — `M.config`/`setup()` needs a `shell = {…}` config block.
- `lua/pi-bridge/bridge.lua` — `M.server_info` (≈ L188) + the descriptor type need to
  expose `shell`/`shellSource`/`shellPath`.
- `extension/protocol.ts` — `BridgeDescriptor` (≈ L82) needs 3 optional fields.
- `extension/pi-nvim-bridge.ts` — `startBridge` descriptor write (≈ L570) needs shell
  fields; add a `resolveShell()` replicating `getShellConfig`.
- `extension/connection.ts` — the `hello`/`ping` result builders mirror the fields.
- `ftplugin/pi-prompt.lua` — `VimLeavePre` teardown must also tear down the daemon.
- `lua/pi-bridge/health.lua` — `:checkhealth` gains a shell section.

#### What does NOT exist yet

`lua/pi-bridge/shell.lua`, `lua/pi-bridge/shell/{fish,zsh,bash,accept}.lua`,
`doc/pi-bridge-shell.txt`, `tests/shell/*`, the descriptor shell fields, and the
`completion_context` `"shell"` routing.

### Sizing

- **Change A (omp):** code-complete → 1 tiny doc/verify task, folded into Phase D1.
- **Change B (shell):** large new subsystem → full Phase D2 with 3 milestones mirroring
  §17.16's dependency chain (descriptor+daemon → routing+fish+accept → zsh+bash+docs).

---

## Phase D1 — Host compat (omp): verify + sync install docs

> The code already implements omp support (see Change A). This phase only **verifies**
> the implementation matches the (now-expanded) PRD and syncs the user-facing install
> docs. No production code change is expected; if verification finds a gap, fix it
> minimally.

### Milestone D1.M1 — omp compat verification & install docs

**Task D1.T1 — Verify omp dual-detection + document omp install**
- **Verify** `isInteractiveSession(ctx)` accepts `ctx.mode === "tui"` **or**
  `ctx.hasUI === true` (extension/pi-nvim-bridge.ts ≈ L1118–1138), and that `session_start`
  guards on it (≈ L1155). This dual detection is **the** fix that enables omp; without it
  omp's `ctx.mode === undefined` makes the gate bail every start and `PI_NVIM_BRIDGE` is
  never advertised.
- **Verify** the manifest ships `"pi": { "extensions": [...] }` (omp's
  `(pkg.omp ?? pkg.pi).extensions` fallback discovers it unchanged) and that all
  `@earendil-works/*` imports are `import type`-only (Bun/jiti erase them — no runtime
  resolution of a package omp lacks).
- **Verify** the plugin side needs no host change (keys only on `PI_NVIM_BRIDGE`).
- **Doc (Mode A):** confirm the §6.8 divergence table is reflected in the existing
  JSDoc on `isInteractiveSession` (update the comment if drift is found).
- **Doc (Mode B — rides here):** update top-level `README.md` install section to add the
  omp host path (`omp plugin install npm:pi-nvim-bridge`, `omp plugin list`,
  `omp plugin doctor`), and a one-line note that the extension runs under either host.

---

## Phase D2 — Shell Completion for `!`/`!!` Bash Mode

> Additive subsystem of Component B, per PRD §17. Reuses the existing menu, activation
> gate, debounce/supersession, and `VimLeavePre` teardown. Adds one Lua module tree
  (`lua/pi-bridge/shell*`) plus a single enriched descriptor field-set on Component A.
> **Component A changes by exactly one descriptor field-set** (all optional, back-compat).

### Architectural invariants (govern all of D2)

1. **Daemon is a child of the nvim process** (`vim.uv.spawn`), **not** of pi. It never
   touches the bridge socket — §12 token boundary is unaffected.
2. **Shell path uses byte offsets, not UTF-16** (contrast §8's pi-path). No `coords.lua`
   conversion. Accept uses `nvim_buf_set_text` (range edit), **not**
   `nvim_buf_set_lines` (whole-buffer rewrite).
3. **Supersession mirrors `completion.lua`** — a monotonic `state.gen` captured in the
   response callback; a newer `request()` bumps `gen`; a late response for a stale
   keystroke is dropped at the guard.
4. **Never blocks, never throws** — every `vim.uv` call and decode is `pcall`'d; a
   daemon error degrades to "no completion this keystroke".
5. **`prefer:"pi"` is the default** — completion shell defaults to pi's resolved
   execution shell so completions and execution always agree (§17.2). An unconfigured
   zsh user gets *bash* completion until they set `shellPath`; a one-time notice makes
   the richer shell recoverable.
6. **`complete -C` / capture-widget / `compgen` never run inside nvim's stdin** — they
   run in the spawned shell subprocess over `vim.uv` pipes. (Repo AGENTS.md's
   heredoc-into-nvim-stdin prohibition is about nvim, not about spawning shells.)

### Milestone D2.M1 — Descriptor shell fields + daemon manager + spike

First vertical slice: the descriptor advertises the resolved shell, and `shell.lua` can
resolve → spawn → do a framed round-trip in isolation (proven with fish, printed to
`:messages`). No plugin integration yet.

**Task D2.T1 — Bridge descriptor `shell`/`shellSource`/`shellPath`**
- **Extension (`extension/protocol.ts`):** add three **optional** fields to
  `BridgeDescriptor`: `shell?: string`, `shellSource?: "pi" | "$SHELL" | "default"`,
  `shellPath?: string`. All optional → back-compat with older clients (the plugin falls
  back to `$SHELL`).
- **Extension (`extension/pi-nvim-bridge.ts`):** add `resolveShell()` replicating
  `getShellConfig`'s resolution (it **cannot** read `settingsManager`/`getShellConfig` —
  not on `ExtensionContext`): `process.env.PI_NVIM_SHELL` → `"pi"`; else
  `process.env.SHELL` → `"$SHELL"`; else `/bin/bash` → `"default"`. Populate the three
  fields in the `startBridge` descriptor write (≈ L570). Mirror them in the `hello`/
  `ping` results (`extension/connection.ts` builders).
  - *Mode A docs:* JSDoc on `resolveShell()` and the descriptor fields, citing §17.10.2's
    honesty note (advisory-only; falls back to `$SHELL`).
- **Plugin (`lua/pi-bridge/bridge.lua`):** extract `shell`/`shellSource`/`shellPath`
  into `M.server_info` (defensive type-check, mirroring the existing `cwd`/`fdAvailable`
  extraction at ≈ L329–333) and add them to the descriptor type. Expose for `shell.lua`.
- *Tests:* extension unit test for `resolveShell()` covering the 3 sources; plugin test
  that `server_info` carries the fields after a synthetic `hello`.

**Task D2.T2 — `shell.lua` daemon manager + fish spike**
- **`lua/pi-bridge/shell.lua`** (PRD §17.5.2 skeleton): module-level `state`
  (`proc/stdin/stdout/rx_buf/gen/inflight/shell/driver/cwd`); `resolve_shell(prefer)`
  (§17.4 `prefer` contract, default `"pi"`; fallback chain
  `descriptor.shell → $SHELL → /bin/bash`); `pick_driver(basename)` →
  `require("pi-bridge.shell.<base>")` or nil (degrade); `ensure(on_ready)` spawn via
  `vim.uv.spawn`; `request(line, cursor, after, cb)` framed `__PIREQ__\t{json}\n`;
  `_feed(chunk)` buffering + sentinel slicing (`__PIRESP_START__`/`__PIRESP_END__`) +
  `vim.json.decode` (pcall'd) + normalize to `AutocompleteItem[]`; `teardown()`
  (`uv.process_kill` SIGKILL, close pipes, reset). Reads config + descriptor **fresh at
  call time**.
- **Spike (§17.16 step 21):** a ~30-line invocation inside a real pi-prompt buffer that
  spawns `fish -i`, sends `complete -C "git ch"` framed, parses `word⇥desc`, and prints
  to `:messages`. ✔ Gate → proceed. (Write the spike to a file, never pipe into nvim
  stdin — repo AGENTS.md.)
- **`session_cwd()`** reads `descriptor.cwd`; if it changed since spawn, the driver
  re-`cd`s (each driver exposes `cd(path)` over the framed channel).
- *Mode A docs:* Lua docstring header explaining the daemon lifecycle, framed protocol,
  and gen-guard supersession (mirrors `completion.lua`'s two-layer design).

### Milestone D2.M2 — Plugin integration: routing + fish driver + accept

Second vertical slice: `!` lines now complete end-to-end through the menu (fish), and
items can be accepted.

**Task D2.T3 — `completion.lua` routing + `shell.complete_current` + notices**
- **`completion_context` (≈ L375):** add a `"shell"` return value **before** the existing
  slash/path checks — `if cursorLine == 0 and line1:sub(1,1) == "!" then return "shell"
  end` (mirrors pi's `text.trimStart().startsWith("!")`). `!` vs `!!` is irrelevant to
  routing (both → `"shell"`); the bangs are stripped by `shell.lua` (2 if `!!`, else 1).
  Existing `"slash"`/`"path"`/`nil` returns **unchanged** (regression guard).
- **`do_refresh` (L406) + `force_fetch` (L508):** add one branch each — when
  `ctx == "shell"`, call `require("pi-bridge.shell").complete_current(buf, cb)` instead
  of `bridge.request("getSuggestions", …)`. Same gen-guard supersession as the bridge
  path. Shell-context debounce is **0 ms** (daemon warm after first use). The Tab
  (`force_fetch`) path forces an immediate fetch in shell context.
- **`shell.complete_current(buf, cb)`:** read buffer + cursor, strip the bangs, compute
  `line`/`cursor`/`after` (**byte** offsets — no UTF-16), call `shell.request(…)`.
- **Notices (reuse `notify.lua` dedup):** (a) the §17.4.3 one-time educational notice
  when `prefer:"pi"` resolves bash but `$SHELL` is zsh/fish on `PATH`; (b) the §17.9
  first-run hint "Shell completion active (`<shell>`)"; (c) the degrade notify when the
  daemon fails (suppressed if the daemon already failed).
- *Mode A docs:* docstring on the `"shell"` branch explaining line-1-only scoping and
  why the slash/path paths are untouched.
- *Tests:* `shell_routing_spec.lua` — `"shell"` iff line 1 starts with `!`/`!!`;
  existing values unchanged.

**Task D2.T4 — `shell/fish.lua` driver + `shell/accept.lua`**
- **`shell/fish.lua`** (Tier 1, §17.6.1): the daemon startup script (written to a temp
  file, sourced via `fish -i`) that binds `__pi_handle` to read `__PIREQ__` lines, run
  `complete -C`, and emit `word⇥desc` between `__PIRESP_START__`/`__PIRESP_END__` (using
  `string escape --style=json` for safe JSON). Export `start(opts, on_ready)` +
  `cd(path)`. **Parsing (Lua):** split each response line on the first `\t`; left =
  `value`/`label`, right = `description`; map to `AutocompleteItem`. The `prefix` is
  derived client-side (last whitespace-delimited token of `line[1..cursor]`).
- **`shell/accept.lua`** (§17.8): **local word-replacement, NOT pi's `applyCompletion`**
  (shell candidates are plain words). (1) compute the current shell word (quote-aware
  splitter, `\`-continuations out of scope); (2) quote per the resolved shell (fish:
  double-quote paths with spaces; bash/zsh: single-quote unless it contains a single
  quote, then the `'…'"'"'…'` idiom); (3) **replace** bytes `[word_start+1 .. cursor]`
  via `nvim_buf_set_text(buf, row, start_col, row, end_col, {text})` (range edit — does
  **not** fire `TextChangedI`, so no re-entrancy); (4) position cursor after the text,
  stay in Insert mode; (5) re-trigger fetch only if the candidate ends in `/` (dir),
  else close the menu.
- *Mode A docs:* docstrings on the fish script (why `fish --noconfig` is **wrong** here
  — we want the user's config) and on `accept.lua`'s quoting rules per shell.
- *Tests:* `shell_fish_spec.lua` (golden parsing of `complete -C` output: normal
  `word⇥desc`, description-less, empty, multiline, literal-tab; live-fish integration
  gated on `fish`); `shell_accept_spec.lua` (quoting table: spaces, `$`, backtick,
  single/double quote, combined; assert inserted byte range + cursor).

### Milestone D2.M3 — Remaining drivers + health + docs + tests

**Task D2.T5 — `shell/zsh.lua` + `shell/bash.lua` + unknown-shell degrade**
- **`shell/zsh.lua`** (Tier 1, §17.6.2): persistent interactive `zsh -f -i`, `autoload
  compinit && compinit -u`, a bound zle widget `__pi_capture` that redefines `compadd`
  to collect `word⇥desc` into stdout, driven by setting `BUFFER`/`CURSOR` per request.
  **Most fragile driver** — the spike ( folded into this task) must validate against the
  installed zsh; `:checkhealth` reports the detected version.
- **`shell/bash.lua`** (Tier 2, §17.6.3): `bash --rcfile <this> -i` sourcing
  bash-completion best-effort; `__pi_complete` sets `COMP_LINE`/`COMP_POINT`/
  `COMP_WORDS`/`COMP_CWORD`, invokes the registered `-F` completion fn if present, else
  `compgen -f -d`. **Bare words, no descriptions** (documented limitation). Opt-out via
  `drivers.bash = false`.
- **Unknown-shell degrade (§17.6.4):** basename ∉ {fish,zsh,bash} → nil driver →
  `shell.request` short-circuits to `cb("no driver")` → empty items → menu closes + one
  dedup'd `vim.notify`.
- *Mode A docs:* per-driver docstrings stating the tier and limitations.
- *Tests:* `shell_zsh_spec.lua` (headless `zsh -f -i`, `git ch` → checkout/cherry,
  gated on `zsh`); `shell_bash_spec.lua` (`compgen` file completion; per-command
  compspec iff bash-completion present — skip otherwise); `shell_daemon_spec.lua`
  (spawn→N requests→teardown with no leaked `uv` handles; cold-start-timeout;
  EOF→unhealthy; N consecutive parse failures→disabled).

**Task D2.T6 — `:checkhealth` shell section + `doc/pi-bridge-shell.txt` + config**
- **`lua/pi-bridge/health.lua`:** add a shell section reporting resolved shell, source,
  driver detected, daemon health, last error; live-spawn each available shell's driver
  for a 1-shot smoke.
- **`lua/pi-bridge/init.lua`:** add the `shell = {…}` config block to `M.defaults`
  (§17.11): `enabled`, `prefer="pi"`, `drivers={fish,zsh,bash}`, `warm_on_enter=false`,
  `timeout_ms=1500`, `startup_timeout_ms=5000`, `visual_cue="gutter"`, `debounce_ms=0`.
- **`ftplugin/pi-prompt.lua`:** ensure `VimLeavePre`/`ExitPre` teardown also calls
  `shell.teardown()` alongside the existing bridge-client close.
- **`doc/pi-bridge-shell.txt`** (new vimdoc, `:help pi-bridge-shell`): overview, the
  `prefer` contract + mismatch notice, the `shell = {}` option table, per-driver tiers
  + limitations, the trust model (daemon sources user rc — same as pi's `!`), and the
  degrade behavior. Add the `pi-bridge-shell` tag to `doc/tags`.
- **CI gating:** fish/zsh live tests run only where those shells exist; mark
  shell-dependent tests `pending`/`skip` when absent (never fail CI for a missing
  optional shell).

### Mode B — changeset-level documentation sync (final, depends on D1 + D2)

This delta has cross-cutting doc implications that only make sense once the whole change
is in place. The breakdown agent should turn this into a final Task depending on all
above:

- **Top-level `README.md`:** add the omp install path (D1) and a shell-completion
  feature blurb + the `shell = {}` config pointer + a "how it works (daemon drives the
  user's real shell)" note; update the features list and the architecture diagram's nvim
  box to mention `shell.lua`.
- **`doc/pi-bridge.txt`:** cross-link to `pi-bridge-shell.txt` from the configuration /
  features sections; add the `!`/`!!` completion behavior to the keymaps/behavior table.
- **`extension/README.md`:** note the new optional descriptor fields and the
  `PI_NVIM_SHELL` mirror env var.

---

## Testing guardrails (repo-specific)

- **Never pipe a heredoc / stdin into `nvim`** (repo AGENTS.md HARD RULE). All nvim-driven
  tests write Lua to a file then `+"luafile <path>" +qa` (or run via plenary
  `minimal_init.lua`). The shell daemon is spawned with `vim.uv.spawn` (pipes), **not**
  piped into nvim stdin.
- **Wrap risky commands in `timeout`** (e.g. `timeout 90 nvim …`, `timeout 30 fish -c …`).
- Shell-dependent tests **skip** (never fail) when the binary is absent.

---

## Out of scope for this delta (deferred — PRD §15/§17.17 "future")

Upstream `ctx.getShellConfig()`; nu/elvish drivers; multi-line/`\`-continued commands;
piped-command completion; routing `@file` through the shell daemon; daemon respawn on
EOF. These are documented as future enhancements only — do **not** create tasks.