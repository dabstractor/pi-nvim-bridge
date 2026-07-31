# S18 Research Notes — Extension `package.json` manifest + `README.md`

Source of truth for the PRP. Verified against the installed pi dist
(`/home/dustin/.local/lib/node_modules/@earendil-works/pi-coding-agent`), the
local `extension/` tree, and pi's docs (`docs/packages.md`, `docs/extensions.md`).

## §1. The task (PRD §9.1, §10.2, §13 Phase 5 item 20)

S18 closes P1.M3 ("Env Advertisement & Packaging"). S16 (env write) and S17
(commandsChanged) are DONE; S18 is the last P1.M3 item and the last P1 task
before P2 (Neovim plugin) begins. PRD §13 Phase 5 item 20: "Package the extension
as a pi package." PRD §9.1 shows the package layout:

```
pi-editor-bridge/
  package.json   # { "name":"pi-editor-bridge", "main":"./index.ts", "pi":{ "extensions":["./index.ts"] } }
  index.ts / server.ts / protocol.ts / README.md
```

The ACTUAL code evolved past those filenames: entry is `pi-editor-bridge.ts`
(not `index.ts`), plus `connection.ts` + `jsonl-reader.ts` + `protocol.ts`. S18
must NOT rename tested files (churn risk); instead the manifest points at the
existing entry. This is a MANIFEST + DOCS task — **zero source code changes**.

## §2. WHY a package manifest is REQUIRED (not optional)

The extension is now **4 .ts files** (entry `pi-editor-bridge.ts` imports
`./connection.ts`, `./jsonl-reader.ts`, `./protocol.ts` — verified, all relative
`.ts` imports, line 142+). PRD §9.1's "simplest (single file)" install option
(`cp pi-editor-bridge.ts ~/.pi/agent/extensions/`) is **impossible** — a single
copied file would have unresolved relative imports. The extension MUST be
installed as a **pi package directory** so jiti resolves the sibling imports from
a stable root. The manifest (`pi.extensions`) is what tells pi which file is the
entry.

## §3. pi package-root resolution — DEFINITIVE (scout recon, dist source)

Scout verified against `dist/core/package-manager.js` + `dist/core/extensions/loader.js`:

- **Q1 — git install = ROOT ONLY.** `installGit()` (package-manager.js L1498-1522)
  clones to `targetDir`, then reads `join(targetDir, "package.json")` — the CLONE
  ROOT. `readPiManifest(packageRoot)` (L1841-1853) reads `pkg.pi`. **No subdir
  walk for a manifest.** BUT the manifest's `pi.extensions` *entry paths* resolve
  relative to root (`path.resolve(dir, extPath)`, loader.js), so a root
  `package.json` with `"extensions": ["./extension/pi-editor-bridge.ts"]` IS
  loaded correctly.
- **Q2 — local dir install = the dir IS the root.** `resolveLocalExtensionSource`
  (L1038-1061): `metadata.baseDir = resolved` then `collectPackageResources(resolved, …)`
  reads `<dir>/package.json`. So `pi install ./extension` would read
  `extension/package.json` (if it existed there).
- **Q3 — manifest entry need NOT be `index.ts`.** `resolveExtensionEntries(dir)`:
  reads `manifest.extensions` array → `path.resolve(dir, extPath)` for each → loads
  those EXACT files. `index.ts`/`index.js` is ONLY the fallback when no manifest.
  So `"extensions": ["./pi-editor-bridge.ts"]` works; no rename needed.
- **Q4 — `private` field has NO effect** on loading. pi never reads consumer
  `private`. (The only `private:true` in dist is pi's OWN managed npm wrapper.)
- **Q5 — type-only imports are ERASED by jiti.** jiti uses
  `@babel/preset-typescript` with `onlyRemoveTypeImports:true`; `import type {}`
  is removed at transpile, so `@earendil-works/pi-tui`/`pi-coding-agent` are NEVER
  resolved at runtime. VERIFIED: ALL `@earendil-works/*` imports in the extension
  are `import type` (pi-editor-bridge.ts L130/131/136/152; protocol.ts L26/32) —
  **zero value imports**. So peerDependencies are NOT required for the package to
  LOAD. (The loader ALSO pre-aliases those packages via `getAliases()`/`VIRTUAL_MODULES`.)
  packages.md still RECOMMENDS peerDeps with `"*"` for the documented contract —
  include them as best-practice, knowing they're load-optional.
- **Q6 — `pi-package` keyword NOT enforced by pi.** `grep -rn "pi-package"` over
  dist = zero matches. It's an EXTERNAL npm-gallery discoverability convention
  (packages.md "Gallery Metadata"). Optional but recommended.
- **Q7 — `version` NOT required to load.** `readPiManifest` reads only `pkg.pi`.
  `version` is used only by `getInstalledNpmVersion` (update checks; tolerates
  undefined). Include it anyway (best-practice + aligns with `BRIDGE_VERSION`).
- **Q8 — `npm install` runs ONLY for git/npm installs, NOT local dir.** git uses
  `getGitDependencyInstallArgs()` = `["install","--omit=dev"]` (prod deps only;
  devDeps NOT available at runtime). local dir = `existsSync` only, no install.
  Since this extension has NO runtime deps (type-only), `npm install` is a no-op.

## §4. DECISION: package.json + README.md at REPO ROOT

Repo is a MONOREPO (`pi-nvim-bridge`, remote `git@github.com:dabstractor/pi-nvim-bridge.git`)
that will hold BOTH Component A (this TS extension) AND Component B (the Neovim
plugin, P2). Two install mechanisms coexist: the EXTENSION via `pi install`, the
PLUGIN via a Neovim plugin manager (lazy.nvim) — they are NOT the same.

Placement options analyzed:
- **`extension/package.json`** (subdir): `pi install ./extension` ✓, but
  `pi install git:.../pi-nvim-bridge` ✗ (git reads ROOT only — §3 Q1). Breaks the
  primary git distribution path.
- **ROOT `package.json`** ✅: `pi install git:.../pi-nvim-bridge` ✓ (root manifest,
  entry `./extension/pi-editor-bridge.ts`), `pi install .` ✓. The extension is the
  ONLY `pi install`-able artifact; the nvim plugin is a sibling dir installed via
  lazy.nvim and is irrelevant to pi's loader. ROOT WINS.

**README.md placement**: repo ROOT (companion to the root package.json; npm
convention). S18's README documents the EXTENSION completely (install/config/
troubleshooting) and notes the companion plugin is forthcoming (P2). P3.M11.T28.S44
will later expand to cover BOTH components.

## §5. package.json fields (canonical, from `with-deps` example + packages.md)

Reference example: `examples/extensions/with-deps/package.json`:
```json
{ "name":"pi-extension-with-deps", "private":true, "version":"0.80.10",
  "type":"module", "scripts":{...}, "pi":{"extensions":["./index.ts"]},
  "dependencies":{"ms":"2.1.3"}, "devDependencies":{"@types/ms":"2.1.0"} }
```

Fields for pi-editor-bridge:
- `name`: `"pi-editor-bridge"` (the package identity; matches `BRIDGE_VERSION`'s domain).
- `version`: `"0.1.0"` — align with `BRIDGE_VERSION = "0.1.0"` (pi-editor-bridge.ts:272).
- `description`: one-liner (bridge pi autocomplete to external $EDITOR).
- `type`: `"module"` (ESM; matches tsconfig `module:"ESNext"` + `.ts` ESM syntax).
- `keywords`: `["pi-package","pi","neovim","completion"]` (gallery discoverability; §3 Q6).
- `license`: `"MIT"` (NO LICENSE file exists in repo — NOTE: add a LICENSE file or
  pick another; package.json license field alone is not a substitute, but is the
  manifest convention).
- `private`: OMIT (defaults false; this IS distributable. `with-deps` used `true`
  only because it's a non-distributable example. §3 Q4: no load effect anyway).
- `pi.extensions`: `["./extension/pi-editor-bridge.ts"]` ← THE critical field.
- `peerDependencies`: `{"@earendil-works/pi-coding-agent":"*","@earendil-works/pi-tui":"*"}`
  (packages.md convention; load-optional per §3 Q5 but documents the contract).
- `devDependencies` (OPTIONAL, for reproducible dev): `typescript` + `jiti`.
  jiti in pi's node_modules is `2.7.0`. typescript not in pi's node_modules (npx
  resolves global). Pin to working versions; git install uses `--omit=dev` so
  these never bloat runtime.
- `scripts`: `typecheck` (`tsc --noEmit -p extension/tsconfig.json` — reproducible,
  matches every prior PRP's validated gate) + `test` (document the jiti invocation;
  the absolute JITI_REG path is machine-specific — see §6).

## §6. Validation commands (verified from prior PRPs)

- Type-check (every prior task's gate): `npx tsc --noEmit -p extension/tsconfig.json` ⇒ exit 0.
- Run a test file (node:test + jiti, NOT vitest):
  ```
  JITI_REG=/home/dustin/.local/lib/node_modules/@earendil-works/pi-coding-agent/node_modules/jiti/lib/jiti-register.mjs
  node --import "$JITI_REG" extension/tests/<file>.ts
  ```
  → expect `ℹ fail 0`. (jiti prints a benign DeprecationWarning on Node 26 — judge by exit code.)
- NEW for S18 (package well-formedness):
  - `node -e "const p=require('./package.json'); console.log(p.pi.extensions)"` ⇒
    prints `[ './extension/pi-editor-bridge.ts' ]`.
  - `ls extension/pi-editor-bridge.ts` ⇒ exists (manifest entry resolves).
  - `pi -e .` (try-without-install; packages.md §"Install and Manage") ⇒ pi starts,
    loads the extension with NO load error. Strongest non-interactive proxy for
    "pi accepts the package." (Functional confirmation that PI_NVIM_BRIDGE gets
    set requires an interactive session + launching $EDITOR — document as manual.)

## §7. Scope guard (what S18 does NOT do)

- NO source code changes (pi-editor-bridge.ts / connection.ts / jsonl-reader.ts /
  protocol.ts / tests/ / tsconfig.json all UNTOUCHED). This is manifest + docs only.
- Does NOT rename `pi-editor-bridge.ts` → `index.ts` (manifest handles it; avoid churn).
- Does NOT move `extension/` → `pi-editor-bridge/` (repo-root package.json makes
  the dir name irrelevant to pi; avoid churn).
- Does NOT write the Neovim plugin README (P2/P3.S44 territory).
- Does NOT add a LICENSE file (recommend it, but it's a separate human decision).
- Boundary with S44 ("README for both plugin and extension"): S18 = extension-only
  README, complete for the extension; S44 expands to cover the plugin + polish.

## §8. README content (PRD §10, §11, §12)

Sections: title + tagline; what it does (brief architecture — capture live provider,
serve over Unix socket, advertise via PI_NVIM_BRIDGE); prerequisites (pi w/
extension support, Neovim 0.10+, companion pi-bridge.nvim plugin forthcoming);
installation (`pi install git:github.com/dabstractor/pi-nvim-bridge` or `pi install .`,
note multi-file ⇒ package install ONLY, no single-file drop-in); $EDITOR wiring
(export EDITOR=nvim / VISUAL / settings.json externalEditor; optional NVIM_APPNAME);
the PI_NVIM_BRIDGE env var (process-local, NOT in shell — why `echo $PI_NVIM_BRIDGE`
shows nothing); troubleshooting (PRD §11: forgotten-save↦autosave, stale socket,
fd not installed↦fdAvailable, reload behavior, post-bridge wrapper limitation);
security (PRD §12: 0600 socket, 32-byte token via process.env, never log token);
development (typecheck + test commands); links (PRD, companion plugin).
