# Research Notes — P1.M1.T1.S2 (Sync README.md install section for omp host path)

Scope: NARROW documentation edit. Update `README.md`'s **Installation** section
to document the **oh-my-pi (`omp`) host install path** alongside the existing
`pi` path, plus a one-line "runs under either host with zero code change" note
and a Prerequisites tweak. **Do NOT touch the Neovim plugin install
instructions** (host-agnostic — keys only on `PI_NVIM_BRIDGE`). No code, no
tests, no mocking.

This task is **the documentation half** of omp host compat. The CODE half is
already done (`system_context.md`: *"Change A (omp host compat): Code-complete.
The dual-detection mode gate `isInteractiveSession(ctx)` … already accepts
`ctx.mode === "tui"` OR `ctx.hasUI === true`. Residual work is documentation
only."*). The preceding task **S1** verifies those 5 code invariants; **S2
consumes S1's verified claims as its INPUT** (the basis that the bridge runs
unchanged under omp) and lands the docs.

---

## 1. The omp CLI surface — VERIFIED EMPIRICALLY (this is the docs' source of truth)

`omp` (oh-my-pi, `@oh-my-pi/pi-coding-agent`, Bun runtime) is installed on this
machine: **`omp/17.1.3`** at `/home/dustin/.cache/.bun/bin/omp`. Every command
this task will document was run and produced the cited output — the docs are not
speculative.

### `omp plugin` subcommand surface (from `omp plugin --help`)
```
USAGE:  $ omp plugin [ACTION] [TARGETS...] [FLAGS]
ACTION: install|uninstall|list|link|doctor|features|config|enable|disable|marketplace|discover|upgrade
TARGETS: Packages, paths, or plugin names
FLAGS:  --json, --fix, --force, --dry-run, -l/--local, --scope=<user|project>, ...
```
→ `install`, `list`, `doctor` are all real actions. Usage form is
`omp plugin <action> <target>` (space-separated, NOT `omp install <pkg>` like
pi). This is the **key syntactic difference** from pi the README must capture.

### The three commands to document — each verified:
| Command (EXACT) | Verified output | PRD source |
|---|---|---|
| `omp plugin install npm:pi-nvim-bridge` | `omp plugin install npm:pi-nvim-bridge --dry-run` → `[dry-run] Would install npm:pi-nvim-bridge` | §10.2 |
| `omp plugin list` | `● pi-nvim-bridge@0.1.0` (listed under "npm Plugins:") | §10.2 |
| `omp plugin doctor` | `✔ plugin:pi-nvim-bridge: v0.1.0 - Bridge pi's autocomplete engine...` and `Summary: 6 ok, 0 warnings, 0 errors` | §6.8 / §10.2 |

- **Target syntax is `npm:pi-nvim-bridge`** (the `npm:` registry prefix), matching
  pi's convention AND the existing README's `pi install npm:pi-nvim-bridge`.
- `omp plugin doctor` literally prints `✔ plugin:pi-nvim-bridge` and ends with
  `0 errors` → the PRD's "should report it healthy" is exactly what happens.

### Why this works (the manifest fallback) — VERIFIED
- `package.json` ships `"pi": { "extensions": ["./extension/pi-nvim-bridge.ts"] }`
  (and NO `"omp"` key — by design).
- omp reads `(pkg.omp ?? pkg.pi).extensions` (PRD §6.8). With no `omp` key, the
  `??` falls through to `pkg.pi` → discovers our extension **unchanged**.
- Empirical proof: `omp plugin list` already shows `● pi-nvim-bridge@0.1.0` and
  `omp plugin doctor` reports it healthy — **the bridge is already installed and
  recognized under omp on this machine.** The omp plugins dir is
  `/home/dustin/.omp/plugins` (matches PRD §6.8 "config/plugin dir ~/.omp/plugins/").

This is the single strongest piece of evidence for the README's claim that the
extension "runs under either host with zero code change."

---

## 2. Why the bridge needs zero code change under omp (the docs' rationale)

From `architecture/research-extension-side.md §2c` (L1119-1138) + `system_context.md`:
- **Mode gate** (`isInteractiveSession`, `extension/pi-nvim-bridge.ts:1134-1138`):
  `ctx.mode === "tui" || (ctx as ExtensionContext & { hasUI?: boolean }).hasUI === true`.
  omp removed `ctx.mode` and exposes `ctx.hasUI`; the dual-detection accepts BOTH.
  (S1 claim A verifies this.) The `session_start` guard at L1167 runs before
  `captureProvider` (L1172) + `startBridge` (L173). (S1 claim B.)
- **Type-only imports**: every `@earendil-works/*` import is `import type` (S1
  claim E). omp lacks `@earendil-works/*` at runtime (ships `@oh-my-pi/*`); jiti
  + Bun erase type-only imports at load → no resolution of a package omp lacks.
- **Runtime**: the extension uses only Node builtins (`net`, `crypto`, `fs`,
  `os`, `path`), all implemented by Bun; `process.env` writes propagate to the
  spawned `$EDITOR` under both Node and Bun. (S1 claim C — host-agnostic descriptor.)

→ The README one-liner is accurate: *"The extension runs under either host (pi
or omp) with zero code change."*

---

## 3. Current README state — the exact edit site

`README.md` (14 KB, fully read). Relevant sections + their CURRENT content:

### `## Prerequisites` (currently pi-ONLY — needs the omp one-liner)
```
- **pi** with extension support.
- **Neovim ≥ 0.11** (0.12 verified) ...
- **`fd`** *(optional)* ...
- The companion **`pi-bridge.nvim`** plugin ...
```
PRD §10.1 says this line should read: *"**pi** (with extension support) — or the
**oh-my-pi** fork (`omp`); the extension runs under either host (see §6.8)."*
→ Minimal coherence edit: amend the first bullet. (Out of strict "install
section" scope but required for consistency — a reader seeing omp in Installation
but only pi in Prerequisites would be confused. PRD §10.1 mandates it.)

### `## Installation` (currently pi-ONLY — the PRIMARY edit target)
```
## Installation

```bash
# Preferred: install from git
pi install npm:pi-nvim-bridge

# Or from a local clone
git clone https://github.com/dabstractor/pi-nvim-bridge
cd pi-nvim-bridge
pi install .
```

Verify:

```bash
pi list          # should show "pi-nvim-bridge"
```

> ⚠️ **Multi-file package — no single-file drop-in.** ...
```
→ This is where the omp subsection + the "either host" note go. The existing
`pi install` block and the `⚠️ Multi-file package` warning are KEPT (the warning
applies equally to omp). The `pi install .` (local clone) variant is pi-specific
and stays under the pi path.

### `## Installation` → "Companion plugin" block — DO NOT TOUCH
The lazy.nvim / runtimepath / `:help pi-bridge` instructions are **host-agnostic**
(activation gates on `PI_NVIM_BRIDGE`, not on pi-vs-omp). The contract explicitly
forbids changing them. Leave verbatim.

### Other README sections
- `## Configuration ($EDITOR)`, `## How it works`, `## PI_NVIM_BRIDGE`, etc. are
  all host-agnostic and OUT OF SCOPE. The `node_modules`/typecheck/test commands
  under `## Development` reference pi's bundled jiti — that's a dev-machine detail,
  not a host claim; do not touch.

---

## 4. Scope boundaries (do NOT cross)
- **In:** `README.md` `## Prerequisites` (one bullet amended) + `## Installation`
  (omp subsection + one-line note inserted). The "either host / zero code change"
  claim is the only new prose.
- **Out:** the Neovim plugin install instructions (host-agnostic); any code;
  any tests; `doc/pi-bridge.txt`; `package.json` manifest; the `## Configuration`
  / `## How it works` / `## Development` sections.
- **Defer:** the shell-completion feature blurb lands later in **P2.M4.T7.S1**
  (README augmentation). Do NOT add shell-completion content here. This task is
  ONLY the omp install-path documentation (Mode B rides here per the delta PRD).

---

## 5. Validation approach for a doc change
There is no markdown-lint or doc-compile gate in this repo (`package.json` has
only `typecheck` for TS; Lua tests run under nvim). So validation is:
1. **Grep presence gate** — the new omp commands + note are present; the existing
   pi path + companion-plugin block are intact.
2. **Empirical command accuracy** — already verified (§1 above); the implementer
   can re-run `omp plugin list` / `omp plugin doctor` to confirm the documented
   output. (Cite this PRP's evidence so the implementer need not re-derive.)
3. **No-broken-anchors** — the README has no formal ToC; the only internal link
   is `[Installation](#installation)` in Prerequisites. The new subsection headings
   must not collide with existing ones.
4. **Render sanity** — optional `mdformat`/GitHub preview; not required (no config).

---

## 6. Gotchas
- omp's CLI is `omp plugin install <target>` (space-separated action+target), NOT
  `omp install <target>` (pi's shape). Getting this wrong in the README = broken
  docs. **Verified exact form above.**
- Keep the target prefix as `npm:` (matches the existing `pi install npm:...`
  line and the verified dry-run). Do not invent `git:`/`omp:` prefixes for omp.
- The `⚠️ Multi-file package` warning applies to omp TOO (omp also can't drop in
  a single file). Do NOT move it under only the pi subsection — keep it shared, or
  note it covers both hosts.
- omp plugins dir `~/.omp/plugins/` ≠ pi's `~/.pi/agent/extensions/`. The README
  doesn't currently mention either dir; no need to add dir paths (keep it to the
  CLI commands, which is what users actually run). The `omp plugin doctor` output
  surfaces the dir if a user is curious.
- Do NOT add an `"omp"` key to `package.json` (that's S1's territory and it's
  intentionally absent — the `"pi"` key IS the omp fallback). This task touches
  only README.md.