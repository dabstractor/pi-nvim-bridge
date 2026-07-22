# S44 Research Notes — Write/update README.md for both plugin and extension

Task: **P3.M11.T28.S44** — "Write/update README.md for both plugin and extension" (1 pt).
Mode: **doc-SYNC (Mode B)** — code is the source of truth; READMEs must mirror SHIPPED behavior.

## Deliverables (exactly two files)

1. **UPDATE `README.md`** (repo root) — the EXTENSION README. Currently accurate on the
   bridge but **STALE on the plugin**: it repeatedly calls the companion `pi-bridge.nvim`
   "forthcoming (Phase 2)". P2 (plugin core) and P4 (blink/cmp sources) are both COMPLETE.
2. **CREATE `plugin/README.md`** — does NOT exist yet (VERIFIED: `ls plugin/README.md` →
   no such file). The Neovim-side end-user README for `pi-bridge.nvim`.

## Identity / version facts (verified)
- `git remote`: `git@github.com:dabstractor/pi-nvim-bridge.git` → **owner = `dabstractor`**.
- `package.json` `name` = `"pi-editor-bridge"`, `version` = `"0.1.0"`, `license` = `"MIT"`
  (NO `LICENSE` file committed — the existing README already calls this out; do NOT add one).
- Bridge version constant: `extension/pi-editor-bridge.ts:272  BRIDGE_VERSION = "0.1.0"`.
- Plugin version: `plugin/lua/pi-editor/bridge.lua  M.version = "0.1.0"` (mirrors package.json).

## CRITICAL: the blink/cmp "forthcoming" drift (resolve for the READMEs)
- **Plan status**: P4 (blink.cmp S45 + nvim-cmp S46 + NVIM_APPNAME S47) = **Complete**.
- **Shipped code** (verified): `plugin/lua/pi-editor/blink_source.lua` (391 lines) +
  `plugin/lua/pi-editor/cmp_source.lua` (435 lines) EXIST, are tested
  (`plugin/tests/blink_source_spec.lua`, `_smoke.lua`, `cmp_source_*`), and are
  self-contained OPT-IN adapters. **No shipped code `require`s them** (grep:
  `blink_source|cmp_source` appears ONLY in their own files + tests).
- **`engine` config is NOT wired**: grep shows `engine` consumed only in
  `init.lua` (default `"builtin"`) and read by the two source modules "to degrade"
  (no behavioral change). `completion.lua`/`menu.lua`/`ftplugin` do NOT check `engine`.
  → The builtin menu ALWAYS runs. The sources are ADDITIVE (registering one AND using
  the builtin menu = double UI today). Source headers document this as a
  "KNOWN FORWARD-CONTRACT" (a future engine-wiring task would suppress the builtin menu
  when `engine` != builtin).
- **CONSEQUENCE for the READMEs**: document blink/cmp sources as **SHIPPED, opt-in
  adapters** the user registers in THEIR engine config — NOT "forthcoming". This is the
  honest, code-faithful state. (The S43 vimdoc `pi-editor.txt` says "forthcoming" — that
  wording is now stale; flag it as a cross-doc-consistency NOTE, do not let the README
  repeat the staleness.)

## Source-of-truth file map (read these; READMEs mirror them verbatim)
- `plugin/lua/pi-editor/init.lua` — `M.defaults` (lines 30-40): the 7 config fields.
  Exact: `menu.max_height=12`, `menu.border="rounded"`, `debounce_ms=20`,
  `rpc_timeout_ms=2000`, `autosave_on_exit=true`, `engine="builtin"` (+ optional
  `env_var="PI_NVIM_BRIDGE"`). `M.setup()` merges over defaults, stores `M.config`,
  emits a WARN if `rpc_timeout_ms <= 1500`.
- `plugin/lua/pi-editor/health.lua` — `M.min_nvim = "0.11"` (NOT 0.10); 4 `check()`
  sections; fd tries both `fd` and `fdfind` (Debian).
- `plugin/lua/pi-editor/coords.lua` — the **0.11 floor** (3-arg `vim.str_utfindex`
  overload added in 0.11). `byte_to_utf16`/`utf16_to_byte`/`nvim_to_pi_coords`/`pi_to_nvim_coords`.
- `plugin/ftplugin/pi-prompt.lua` — the 9 buffer-local INSERT keymaps: `<Tab>`→on_tab,
  `<S-Tab>`/`<C-P>`/`<Up>`→on_prev, `<C-N>`/`<Down>`→on_next, `<C-E>`→on_dismiss,
  `<CR>`/`<C-Y>`→on_enter. Fall-through-to-default when not handled. Options:
  `formatoptions-=t`, `textwidth=0`, `wrap`, `spell=false`. Autocmds (pi-editor augroup):
  InsertEnter/TextChangedI/CursorMovedI→refresh; InsertLeave/BufLeave→auto-close;
  VimLeavePre/ExitPre→autosave-if-modified + bye + close.
- `plugin/lua/pi-editor/bridge.lua` — Lua API surface: `M.version`, `M.server_info`,
  `M.is_connected()`, `M.request(method,params,on_result)`, `M.cancel(id)`,
  `M.on_notification`, `M.on_disconnect`.
- `plugin/lua/pi-editor/blink_source.lua` + `cmp_source.lua` headers — the VERBATIM
  user-registration snippets (copied into the README below; authoritative).

## Registration snippets (verbatim from source headers — paste into plugin README)
**blink.cmp** (user's lazy.nvim spec for blink):
```lua
{
  "Saghen/blink.cmp",
  opts = {
    sources = {
      default = { "pi" },
      providers = { pi = { name = "pi", module = "pi-editor.blink_source" } },
    },
  },
}
```
**nvim-cmp** (user's cmp config):
```lua
require("cmp").setup({
  sources = cmp.config.sources({ { name = "pi" } }),
})
-- register ONCE (e.g. in the cmp config or a lazy.nvim `config` fn):
require("cmp").register_source("pi", require("pi-editor.cmp_source").new())
```
**Trigger characters**: both sources expose `{"/", "@"}` (from the source headers).

## The `PI_NVIM_BRIDGE` env var (process-local — the #1 install confusion)
- Descriptor JSON shape: `{transport:"unix", path, token, pid, cwd, fdAvailable, serverVersion}`.
- `echo $PI_NVIM_BRIDGE` in a shell shows NOTHING (written to `process.env` INSIDE pi;
  only the child `$EDITOR` sees it). Inspect from inside launched nvim:
  `:lua print(vim.env.PI_NVIM_BRIDGE)`. Or `:checkhealth pi-editor`.
- NEVER paste the live `token` (PRD §12). Document the SHAPE, not live values.

## Root README.md — STALENESS to fix (grep the file for these)
- Line ~2 (intro): "A companion Neovim plugin — `pi-bridge.nvim` (forthcoming, see Phase 2)"
- "What it does" note block: "the Neovim-side rendering plugin (`pi-bridge.nvim`) ships
  separately under Phase 2. Until it lands, the bridge advertises correctly but there is
  nothing on the editor side to consume it."
- "Companion plugin: install `pi-bridge.nvim` with your plugin manager … See that plugin's
  README (Phase 2)."
- Troubleshooting: "Until Phase 2 ships, remember to `:w` before `:q`." (the plugin now
  AUTOSAVES on VimLeavePre — `autosave_on_exit=true`)
- Links section: "Companion plugin: **`pi-bridge.nvim`** (Phase 2, forthcoming)."
- Repo-layout block lists only `extension/` — should add `plugin/`.

## Conventions / constraints (from AGENTS.md + validate.sh + S43 sibling PRP)
- AGENTS.md HARD RULE: NEVER pipe a heredoc into `nvim` stdin (hangs). Write validation
  snippets to a FILE, run `+"luafile <file>" +qa`; wrap every nvim call in `timeout`.
- No format gate: `validate.sh` Phase 1/3 SKIP (no stylua.toml / selene.yml / prettier).
  So no markdown-lint hard gate; still wrap prose ~Markdown convention.
- `validate.sh` is the project validator (`./validate.sh`): Phase 2 tsc, Phase 4 extension
  node:test + plugin plenary specs/smokes, Phase 5 E2E. Docs have no dedicated phase.
- Two READMEs must be **CONSISTENT with each other + the vimdoc (S43)** in content where
  they overlap (per the S43 PRP's own anti-pattern note: "the README should be CONSISTENT
  with the vimdoc"). The ONE known inconsistency to RESOLVE in the READMEs (not repeat):
  blink/cmp are SHIPPED (README) vs "forthcoming" (vimdoc line ~7 + `engine` row). The
  README side is correct per the code; note the vimdoc drift, don't propagate it.
- Allowed edits: `plugin/README.md` (new) + root `README.md` (edit). NOT allowed: source,
  tests, PRD.md, plan/, PRP, the vimdoc (S43's file — optional cross-doc note only).

## External doc URLs (for the README "Links"/source sections)
- blink.cmp: https://github.com/Saghen/blink.cmp (sources via `providers.<name>.module`).
- nvim-cmp: https://github.com/hrsh7th/nvim-cmp ; source-dev help:
  https://github.com/hrsh7th/nvim-cmp/blob/main/doc/cmp.txt (`register_source`).
- pi docs: packages https://pi.dev/docs/packages · extensions https://pi.dev/docs/extensions .