name: "S44 — Write/update README.md for both plugin and extension"
description: |
  A doc-SYNC (Mode B) documentation task. Two markdown deliverables:
    (1) UPDATE the repo-root `README.md` (the pi-editor-bridge EXTENSION README) to remove
        stale "the nvim plugin is forthcoming (Phase 2)" language — both P2 (plugin core)
        and P4 (blink.cmp + nvim-cmp sources + NVIM_APPNAME) are now COMPLETE — and to point
        at the now-existing companion docs.
    (2) CREATE `plugin/README.md` — the end-user README for the `pi-bridge.nvim` Neovim
        plugin (does not exist yet). Mirrors the SHIPPED plugin behavior verbatim, is
        consistent with the S43 vimdoc (`plugin/doc/pi-editor.txt`) and the root README
        where they overlap, and documents the opt-in blink.cmp / nvim-cmp sources.

---

## Goal

**Feature Goal**: Both end-user READMEs in the `dabstractor/pi-nvim-bridge` repo accurately
reflect the SHIPPED state of the two components (the `pi-editor-bridge` pi extension AND the
`pi-bridge.nvim` Neovim plugin, including its opt-in blink.cmp/nvim-cmp sources), with zero
"forthcoming/Phase 2" staleness and full, copy-pasteable install + config + troubleshooting
guidance. The root README remains the extension's `pi install` face; `plugin/README.md`
becomes the plugin's face.

**Deliverable**:
1. `README.md` (repo root) — UPDATED in place. Surgical edits only: replace every stale
   "companion plugin is forthcoming (Phase 2)" framing with the shipped reality; add a
   pointer to `plugin/README.md` + `plugin/doc/pi-editor.txt`; fix the troubleshooting line
   that says "Until Phase 2 ships, remember to `:w` before `:q`" (the plugin now autosaves);
   add `plugin/` to the repo-layout block. Preserve all still-accurate content (install,
   `$EDITOR` config, the `PI_NVIM_BRIDGE` env-var section, security, dev, NVIM_APPNAME).
2. `plugin/README.md` — NEW. The complete Neovim-plugin README.

**Success Definition**: A user who knows nothing about this repo can, reading only these two
READMEs (+ the linked vimdoc), (a) install both components, (b) wire `$EDITOR=nvim`, (c)
open pi's external editor with `Ctrl+G` and see pi-faithful completion, (d) optionally wire
the blink.cmp or nvim-cmp source, and (e) self-diagnose via `:checkhealth pi-editor` /
`:messages` / the FAQ — with no false claims about unshipped features and no stale
"forthcoming" language about shipped ones.

## User Persona (if applicable)

**Target User**: A developer who uses **pi** and **Neovim** and wants pi's in-prompt
completion (slash commands, `/skill:`, prompt templates, `@file`, paths) inside the Neovim
instance pi launches as `$EDITOR`.

**Use Case**: Pressing `Ctrl+G` in pi to edit the prompt in Neovim and getting the same
completion menu pi's TUI shows.

**User Journey**: install the bridge extension (`pi install`) → install the nvim plugin
(lazy.nvim, `lazy=false`) → set `EDITOR=nvim` → `Ctrl+G` in pi → type `/mo` → accept
`/model` → save+quit to submit.

**Pain Points Addressed**: (1) "the README says the plugin is forthcoming but it's shipped";
(2) no plugin README exists at all; (3) `echo $PI_NVIM_BRIDGE` confusion (process-local);
(4) the lost-prompt-on-`:q` trap (autosave handles it — must be documented).

## Why

- **Truth in advertising.** The root README was written when only the extension (P1) and
  its own packaging (P3.M3.T10.S18) existed; it correctly hedged the plugin as "Phase 2,
  forthcoming". P2 and P4 are now Complete, so the hedging is misinformation. This is the
  single most-visible doc surface (`github.com/dabstractor/pi-nvim-bridge` lands here).
- **Discoverability of the shipped plugin.** `plugin/README.md` is the conventional entry
  point GitHub and plugin managers show for the Neovim half; its absence is a gap.
- **Consistency with the S43 vimdoc.** The two READMEs + `plugin/doc/pi-editor.txt` form the
  end-user doc set; they must agree where they overlap (config defaults, keymaps, env var,
  troubleshooting). One genuine drift exists (the vimdoc still calls blink/cmp "forthcoming"
  while the code ships them) — the READMEs must reflect the **shipped code** (doc-SYNC Mode
  B), and the drift is recorded here as a cross-doc note.

## What

Two markdown files, doc-SYNC'd to the shipped source. No code, test, build, or pipeline
changes. The READMEs are **prose analogs** of the S43 vimdoc plus install/getting-started
framing appropriate to a project landing page.

### Success Criteria

- [ ] `plugin/README.md` exists and renders cleanly as GitHub Markdown.
- [ ] Root `README.md` contains **zero** occurrences of "forthcoming" / "Phase 2" applied to
  the nvim plugin or the blink/cmp sources (they are shipped). (`grep -ni 'forthcoming\|phase 2' README.md` → no plugin/sourcing hits; "Phase 4" may appear only if rewording an accurate historical note — prefer to omit.)
- [ ] Root `README.md` links to `plugin/README.md` and `plugin/doc/pi-editor.txt`.
- [ ] `plugin/README.md` documents all 7 `setup()` defaults byte-faithful to
  `plugin/lua/pi-editor/init.lua` (`M.defaults`).
- [ ] `plugin/README.md` lists all 9 buffer-local keymaps (Tab/S-Tab/C-N/Down/C-P/Up/C-Y/C-E/CR).
- [ ] `plugin/README.md` states the **Neovim >= 0.11** requirement (not 0.10).
- [ ] `plugin/README.md` documents the opt-in blink.cmp and nvim-cmp sources as SHIPPED, with
  the verbatim registration snippets.
- [ ] Both READMEs explain `PI_NVIM_BRIDGE` is process-local (`echo` shows nothing) and
  warn never to paste the live `token`.
- [ ] Both READMEs mention the autosave-on-quit behavior (the lost-prompt fix).
- [ ] No edits outside `README.md` and `plugin/README.md`.

## All Needed Context

### Context Completeness Check

_Passed._ Every fact in both READMEs is determined by shipped source (listed in the
file-map below with line anchors) or by repo identity facts already verified (`git remote`,
`package.json`). The implementer needs no prior knowledge of this codebase.

### Documentation & References

```yaml
# MUST READ — the SHIPPED source of truth (READMEs mirror these VERBATIM; doc-SYNC Mode B)
- file: plugin/lua/pi-editor/init.lua
  why: |
    THE source of truth for the CONFIGURATION section (the 7 setup() defaults + the
    rpc_timeout_ms<=1500 WARN). `M.defaults` (lines 30-40): menu.max_height=12,
    menu.border="rounded", debounce_ms=20, rpc_timeout_ms=2000, autosave_on_exit=true,
    engine="builtin" (+ optional env_var="PI_NVIM_BRIDGE"). `M.setup()` deep-merges opts
    over defaults into `M.config`. Also exports M.defaults / M.config / M.bridge /
    M.descriptor / M.activate() — the Lua-API surface.
  pattern: the exact default values + the WARN invariant the README must reproduce.
  gotcha: |
    `engine` ACCEPTS "builtin"|"blink"|"cmp" but is NOT consumed by any wiring today (the
    builtin menu ALWAYS runs). Document "builtin" as the shipped default and the sources as
    OPT-IN adapters the user registers — do NOT claim `engine="blink"` auto-routes (it does not).

- file: plugin/ftplugin/pi-prompt.lua
  why: |
    THE source of truth for the KEYMAPS + the FILETYPE options + the AUTOCMDS. The dispatch
    table installs exactly 9 buffer-local INSERT keys: <Tab>→on_tab, <S-Tab>→on_prev,
    <C-N>→on_next, <C-P>→on_prev, <C-E>→on_dismiss, <CR>→on_enter, <Down>→on_next,
    <Up>→on_prev, <C-Y>→on_enter. Options: formatoptions-=t, textwidth=0, wrap, spell=false.
    Autocmds (pi-editor augroup): InsertEnter/TextChangedI/CursorMovedI→refresh;
    InsertLeave/BufLeave→auto-close; VimLeavePre/ExitPre→autosave-if-modified + bye + close.
  gotcha: |
    <CR> accepts ONLY when the menu is open; otherwise it inserts a NEWLINE. There is NO
    Enter-to-submit in the external editor — the prompt submits on SAVE+QUIT (pi re-reads
    the temp file after the editor exits). <C-Y> reuses on_enter (accept-if-menu-open else
    fall through to i_CTRL-Y). Each key falls through to its default when not handled.

- file: plugin/lua/pi-editor/health.lua
  why: |
    THE source of truth for the :checkhealth + troubleshooting content. `M.min_nvim="0.11"`
    (the version floor — coords.lua needs the 3-arg vim.str_utfindex overload). 4 check()
    sections: pi-editor / bridge-environment / bridge-connection / external-tools-fd.
  gotcha: the fd section tries BOTH "fd" and "fdfind" (Debian) — document both install paths.

- file: plugin/lua/pi-editor/coords.lua
  why: the basis for the "Neovim >= 0.11 (not 0.10)" requirement (the exact-UTF-16 3-arg
       vim.str_utfindex overload). Exports byte_to_utf16/utf16_to_byte/nvim_to_pi_coords/pi_to_nvim_coords.
  gotcha: 0.11 is a HARD floor (not 0.10); PRD §10.1's "0.10+" text is SUPERSEDED.

- file: plugin/lua/pi-editor/bridge.lua
  why: |
    THE source of truth for the Lua API + the env-var descriptor shape. Exports: M.version
    ("0.1.0"), M.server_info ({serverVersion,cwd,fdAvailable}; nil until handshake),
    M.is_connected(), M.request(method,params,on_result)->id|nil, M.cancel(id),
    M.on_notification(method,handler), M.on_disconnect(handler).
  gotcha: the token is the auth boundary — NEVER echo it. Descriptor JSON shape:
    {transport:"unix", path, token, pid, cwd, fdAvailable, serverVersion}.

- file: plugin/lua/pi-editor/blink_source.lua
  why: |
    THE source of truth for the blink.cmp OPT-IN source registration snippet (header lines
    ~9-22). The user registers it in THEIR blink config: providers.pi.module =
    "pi-editor.blink_source". Exposes get_trigger_characters = {"/","@"}. NEVER requires
    blink.cmp at runtime (the user's plugin). SHIPPED (P4 Complete) — do NOT mark forthcoming.
  pattern: copy the registration snippet VERBATIM from the header into the README.
  gotcha: |
    ADDITIVE — registering it AND using the builtin menu = double UI today. State plainly
    that the source is an alternative UI for users who already drive blink.cmp; to use it
    as the sole UI they should disable the builtin menu (a forward-contract; see note).

- file: plugin/lua/pi-editor/cmp_source.lua
  why: |
    THE source of truth for the nvim-cmp OPT-IN source registration snippet (header lines
    ~13-22): require("cmp").register_source("pi", require("pi-editor.cmp_source").new()).
    The DIRECT ANALOG of blink_source.lua (S46). SHIPPED — do NOT mark forthcoming.
  pattern: copy the registration snippet VERBATIM from the header into the README.
  gotcha: same additive/double-UI caveat as the blink source.

- file: extension/pi-editor-bridge.ts
  why: |
    Confirms BRIDGE_VERSION = "0.1.0" (line 272) = the descriptor serverVersion; the
    descriptor write (transport/path/token/pid/cwd/fdAvailable/serverVersion); the
    NVIM_APPNAME opt-in (PI_EDITOR_NVIM_APPNAME env var) documented in the root README.
    Read-only; no TS change.

- file: plugin/doc/pi-editor.txt
  why: |
    The S43 vimdoc (Complete). The plugin README must be CONSISTENT with it where they
    overlap (config table, 9 keymaps, env-var shape, troubleshooting). It is the more
    detailed reference; the README is the landing-page analog + getting-started framing.
  gotcha: |
    The vimdoc's intro + the `engine` row still say blink/cmp are "forthcoming" — that is
    STALE (P4 ships them). The README must reflect the SHIPPED code (doc-SYNC: code wins).
    Do NOT edit the vimdoc in this task (it is S43's file); record the drift in the
    README's note + this PRP's Anti-Patterns. (Optional one-line vimdoc consistency fix is
    a separate, future touch — out of scope here.)

- file: README.md   # the EXISTING root README (the file Task 1 edits)
  why: |
    Read in full before editing. Its accurate sections (Prerequisites, Installation,
    `Configuration ($EDITOR)`, optional NVIM_APPNAME optimization, "How it works",
    `PI_NVIM_BRIDGE` env var, Troubleshooting, Security, Development, repo layout, Links)
    are PRESERVED. Only the STALE plugin framing (see "Root README — STALENESS to fix") is
    rewritten.

# MUST READ — the PRD anchors (the design; read-only; do not contradict)
- file: PRD.md
  section: "§2.1 (editor launch / save+quit semantics), §7.1 (activation gate), §7.4
            (trigger/accept + <CR> nuance), §7.6 (ftplugin), §10 (install/config), §11
            (edge cases), §12 (security/token)"
  why: Cross-check README prose against these. Do NOT contradict the PRD; where shipped
        code differs from the PRD (e.g. 0.11 vs PRD's 0.10; debounce 20 vs PRD's 25; engine
        not auto-routing), the SHIPPED CODE wins (doc-SYNC) and the README states the code's
        value.

# Reference — repo identity facts (verified; paste concrete values, not <owner> placeholders)
- git remote: git@github.com:dabstractor/pi-nvim-bridge.git   -> owner = "dabstractor"
- package.json: name="pi-editor-bridge", version="0.1.0", license="MIT" (no LICENSE file)

# External docs (for the README "Links" / source-registration sections)
- url: https://github.com/Saghen/blink.cmp
  why: the completion engine the opt-in blink source adapts to (providers.<name>.module convention).
- url: https://github.com/hrsh7th/nvim-cmp
  why: the completion engine the opt-in cmp source adapts to.
- url: https://github.com/hrsh7th/nvim-cmp/blob/main/doc/cmp.txt
  why: the authoritative nvim-cmp source-development reference (register_source / execute).
- url: https://pi.dev/docs/packages
  why: the `pi install` package docs the root README already cites.
- url: https://pi.dev/docs/extensions
  why: the pi extension docs (the bridge is a pi extension).
```

### Current Codebase tree (relevant slice)

```bash
pi-nvim-bridge/
├── README.md                         # EXISTS — the EXTENSION README (Task 1 UPDATES)
├── package.json                      # name=pi-editor-bridge, version=0.1.0, license=MIT
├── PRD.md                            # READ-ONLY design doc
├── AGENTS.md                         # the nvim-stdin HARD RULE + repo rules
├── validate.sh                       # the project validator (5 phases; no docs gate)
├── extension/                        # the pi extension (P1 — Complete)
│   ├── pi-editor-bridge.ts           # entry: BRIDGE_VERSION=0.1.0, NVIM_APPNAME opt-in
│   ├── connection.ts  jsonl-reader.ts  protocol.ts
│   └── tests/                        # node:test + jiti
└── plugin/                           # the nvim plugin (P2 + P4 — Complete)
    ├── lua/pi-editor/
    │   ├── init.lua                  # M.defaults (7 fields) + setup/activate  — CONFIG truth
    │   ├── bridge.lua                # Lua API + version=0.1.0 + server_info   — API truth
    │   ├── completion.lua            # trigger/accept/debounce/Tab             — COMPLETION truth
    │   ├── menu.lua                  # the dependency-free floating popup
    │   ├── coords.lua                # byte<->UTF-16; the 0.11 floor            — REQUIREMENTS truth
    │   ├── health.lua                # checkhealth (4 sections) + min_nvim=0.11 — CHECKHEALTH truth
    │   ├── jsonlreader.lua  notify.lua
    │   ├── blink_source.lua          # OPT-IN blink.cmp source (SHIPPED, P4)    — registration snippet
    │   └── cmp_source.lua            # OPT-IN nvim-cmp source (SHIPPED, P4)     — registration snippet
    ├── plugin/pi-editor.lua          # VimEnter auto-activation shim (lazy=false note)
    ├── ftplugin/pi-prompt.lua        # 9 keymaps + ft opts + autocmds            — KEYMAPS truth
    ├── doc/pi-editor.txt             # the S43 vimdoc (Complete) — keep consistent
    ├── doc/tags                      # :helptags index (committed)
    └── tests/                        # plenary specs + plenary-free smokes
```

### Desired Codebase tree with files to be added/updated

```bash
README.md            # UPDATE — de-stale the plugin framing; add plugin/ pointer + layout line.
plugin/README.md     # NEW    — the pi-bridge.nvim end-user README (full).
```

### Known Gotchas of our codebase & Library Quirks

```text
CRITICAL (doc-SYNC Mode B, code is truth): P2 + P4 are COMPLETE. The bridge extension, the
  builtin floating menu, :checkhealth, AND the blink.cmp/nvim-cmp opt-in sources are ALL
  shipped. The READMEs must NOT mark any of these "forthcoming". The ONLY genuinely-unbuilt
  item is the `engine` auto-routing (the builtin menu always runs today; the sources are
  additive opt-ins) — document THAT honestly, not as "the sources don't exist".

CRITICAL (0.11 floor, NOT 0.10): plugin/README.md Requirements MUST say Neovim >= 0.11.
  coords.lua needs the 3-arg vim.str_utfindex overload (added in 0.11); health.lua enforces
  M.min_nvim="0.11". PRD §10.1's "0.10+" text is SUPERSEDED — do not repeat it.

CRITICAL (<CR> is NOT submit): in the external editor there is NO Enter-to-submit — pi
  re-reads the temp file only AFTER the editor EXITS (PRD §2.1). So <CR> accepts if the menu
  is open, ELSE inserts a NEWLINE. The autosave-on-VimLeavePre (autosave_on_exit=true) is
  what actually persists the prompt. Document both, prominently.

CRITICAL (PI_NVIM_BRIDGE is process-local): `echo $PI_NVIM_BRIDGE` in a shell shows
  NOTHING — the var is written to process.env INSIDE pi and only the child $EDITOR sees it.
  This is the #1 install confusion. Tell users `:lua print(vim.env.PI_NVIM_BRIDGE)` from
  inside the launched nvim, or `:checkhealth pi-editor`.

CRITICAL (token is sensitive — PRD §12): NEVER document/paste the live token. Document the
  descriptor SHAPE (transport/path/token/pid/cwd/fdAvailable/serverVersion) with a "never
  paste the live descriptor, especially token, into a bug report" warning.

GOTCHA (engine config is a hint, not wiring): `engine` is in M.defaults but is NOT read by
  completion.lua/menu.lua/ftplugin. The builtin menu ALWAYS runs. The blink/cmp sources are
  ADDITIVE opt-ins the user registers in THEIR engine config; registering one AND using the
  builtin menu yields DOUBLE UI today. State this plainly; do not claim `engine="blink"`
  switches the UI (a forward-contract, not shipped).

GOTCHA (debounce is 20, not 25): M.defaults.debounce_ms = 20 (pi's
  ATTACHMENT_AUTOCOMPLETE_DEBOUNCE_MS). Slash/typing use 0 ms (pi-faithful). PRD §10.5 / §5.5
  say 25 — SUPERSEDED by the shipped 20.

GOTCHA (vimdoc drift to NOT propagate): the S43 vimdoc (plugin/doc/pi-editor.txt) intro +
  the `engine` row say blink/cmp are "forthcoming" — STALE. The READMEs reflect the shipped
  code (sources exist). Do NOT edit the vimdoc here (S43's file); just don't repeat its
  staleness in the READMEs.

GOTCHA (no LICENSE file): package.json declares "license":"MIT" but no LICENSE file is
  committed. The existing root README already notes this is a separate human decision. Do
  NOT add a LICENSE file in this docs task; you MAY keep the one-line note in the README.

GOTCHA (no format gate): validate.sh Phases 1+3 SKIP (no stylua.toml / selene.yml /
  prettier). Markdown has no hard lint gate; still keep fenced blocks consistent and links
  valid. The real gates for this task are the grep/link checks in the Validation Loop.

NEVER pipe a heredoc into `nvim` stdin (AGENTS.md HARD RULE — it hangs the session). The
  Validation Loop below uses ONLY file-based nvim checks (write a .lua, `+"luafile <path>"
  +qa`, wrapped in `timeout`) — and in fact this docs task needs NO nvim invocation at all
  (it is pure markdown); the nvim-based gates are optional belt-and-suspenders.
```

## Implementation Blueprint

### Data models and structure

No runtime data model — the deliverables are two Markdown files. The "structure" each owns:

**Root `README.md`** (UPDATE — keep its existing section order; only de-stale + cross-link):
title pitch → What it does → Prerequisites → Installation → `Configuration ($EDITOR)` +
optional NVIM_APPNAME → How it works → `PI_NVIM_BRIDGE` env var → Troubleshooting →
Security → Development → repo layout (ADD `plugin/`) → Links (point to plugin README + vimdoc).

**`plugin/README.md`** (NEW — recommended section order, mirroring the vimdoc's 13 sections
as Markdown headings + landing-page framing):
1. Title + one-line pitch (+ badges optional).
2. **What it does** (pi-faithful completion; dormant-by-design; the two-component design).
3. **Requirements** (Nvim >= 0.11; the bridge extension; optional `fd`/`fdfind`).
4. **Quick start** (install bridge → install plugin `lazy=false` → `$EDITOR=nvim` → `Ctrl+G`
   → save+quit to submit).
5. **Configuration** (`setup()` + the 7-field defaults table).
6. **Completion behavior** (slash/skill/template/ext-commands/arg-completion/`@file`/paths/
   Tab; accept delegates to pi's `applyCompletion` → identical insertion).
7. **Keymaps** (the 9 buffer-local keys + fall-through + `<CR>`=accept-or-newline).
8. **Optional: blink.cmp source** (SHIPPED opt-in; verbatim registration snippet; additive
   caveat) + **nvim-cmp source** (likewise).
9. **The `PI_NVIM_BRIDGE` environment variable** (shape; process-local; inspect via
   `:lua print(...)` / `:checkhealth`; token-safety).
10. **Health & diagnostics** (`:checkhealth pi-editor`; `:messages`; `:help pi-editor`).
11. **Troubleshooting / FAQ** (dormant-is-expected; completion-doesn't-appear; `@file` empty;
    lost-prompt/autosave; `/reload`; other-extensions-trigger limitation; `pi -p` no-op;
    rpc_timeout_ms warning).
12. **Security** (socket 0600; 32-byte token; never paste it).
13. **Development** (smoke + plenary test commands; `./validate.sh`; pointer to vimdoc + PRD).
14. **Links** (vimdoc, PRD, bridge README, blink.cmp, nvim-cmp, pi docs).

### Implementation Tasks (ordered by dependencies)

```yaml
Task 1: READ the shipped source + the existing root README (no writes yet)
  - READ: plugin/lua/pi-editor/init.lua (M.defaults :30-40; M.setup; M.activate)
  - READ: plugin/ftplugin/pi-prompt.lua (9 keymaps + ft opts + autocmds)
  - READ: plugin/lua/pi-editor/health.lua (min_nvim="0.11"; 4 sections; fd/fdfind)
  - READ: plugin/lua/pi-editor/bridge.lua (Lua API + version + descriptor shape)
  - READ: plugin/lua/pi-editor/blink_source.lua + cmp_source.lua HEADERS (registration snippets)
  - READ: plugin/doc/pi-editor.txt (S43 vimdoc — keep consistent; note the blink/cmp drift)
  - READ: README.md (the file Task 3 edits — identify the STALENESS below)
  - WHY: every README fact is determined by these. Doc-SYNC = mirror VERBATIM.

Task 2: CREATE plugin/README.md — the pi-bridge.nvim end-user README
  - FILE: plugin/README.md (NEW; the rtp-root README GitHub + plugin managers show).
  - SECTIONS: the 14 headings in "Data models and structure" above.
  - CONFIGURATION table — EXACT (mirror init.lua M.defaults :30-40):
      Option              Default             Notes
      menu.max_height     12                  Max visible rows in the floating popup.
      menu.border         "rounded"           nvim_open_win border style.
      debounce_ms         20                  @/# attachment-context window; slash/typing=0ms.
      rpc_timeout_ms      2000                MUST exceed bridge fd-abort 1500 (WARN if <=).
      autosave_on_exit    true                Write the pi temp file on VimLeavePre if modified.
      engine              "builtin"           builtin=shipped menu. blink/cmp=OPT-IN sources you
                                              register (see §Optional). engine does NOT auto-switch
                                              the UI today (forward-contract); the builtin menu
                                              always runs unless you suppress it yourself.
      env_var             "PI_NVIM_BRIDGE"  Override the bridge-descriptor env var name.
  - KEYMAPS table — EXACT (mirror ftplugin): 9 rows. <Tab> trigger/accept (pi-faithful Tab);
      <S-Tab>/<C-P>/<Up> prev; <C-N>/<Down> next; <C-E> dismiss; <C-Y> accept-if-menu-open else
      i_CTRL-Y; <CR> accept-if-menu-open ELSE NEWLINE (NO Enter-to-submit). Note fall-through.
  - REQUIREMENTS: Neovim >= 0.11 (NOT 0.10); pi-editor-bridge extension (`pi list`); optional
      fd (Debian: fdfind) for @file fuzzy.
  - QUICK START: install bridge (`pi install git:github.com/dabstractor/pi-nvim-bridge`;
      `pi list` shows pi-editor-bridge); install plugin (lazy.nvim spec WITH `lazy = false` so
      the VimEnter shim sources before activation); set EDITOR/VISUAL/externalEditor=nvim;
      Ctrl+G in pi; completion appears; SUBMIT = save+quit (pi re-reads the temp file after exit).
  - OPTIONAL blink.cmp source — paste the VERBATIM registration snippet from blink_source.lua
      header (providers.pi.module = "pi-editor.blink_source"; sources.default={"pi"}). Mark
      SHIPPED. Caveat: additive — registering it AND keeping the builtin menu = double UI; to
      use blink as the sole UI, suppress the builtin menu yourself (forward-contract).
  - OPTIONAL nvim-cmp source — paste the VERBATIM snippet from cmp_source.lua header
      (require("cmp").register_source("pi", require("pi-editor.cmp_source").new())). Same caveat.
  - ENV VAR: the PI_NVIM_BRIDGE JSON shape; "echo shows nothing (process-local)";
      `:lua print(vim.env.PI_NVIM_BRIDGE)`; `:checkhealth pi-editor`; never paste the token.
  - HEALTH: `:checkhealth pi-editor` (4 sections; dormant=INFO not error); `:messages` for the
      one-time "completion unavailable" notify; `:help pi-editor` (after `:helptags`).
  - TROUBLESHOOTING: dormant-is-expected; completion-doesn't-appear (4-step checklist);
      @file-empty (install fd/fdfind); lost-prompt (autosave_on_exit handles it; `:w`/`:x`/`ZZ`
      to be safe); /reload (commandsChanged refresh); other-extensions-trigger (KNOWN
      LIMITATION — base provider always captured); pi -p (no-op, TUI-only); rpc_timeout_ms
      warning (must exceed 1500).
  - SECURITY: socket 0600; 32-byte random token via process.env; never paste the live token.
  - DEVELOPMENT: plenary spec runner + plenary-free smoke runner (from AGENTS.md):
        Spec:   timeout 90 nvim --headless --clean -u plugin/tests/minimal_init.lua \
                  -c 'lua require("plenary.busted").run("plugin/tests/<spec>.lua")'
        Smoke:  timeout 60 nvim --headless --clean -u NORC +"luafile plugin/tests/<m>_smoke.lua" +qa
      plus `./validate.sh` (5-phase project validator). Pointer to plugin/doc/pi-editor.txt +
      the root PRD.md + the bridge README (../README.md).
  - LINKS: vimdoc (:help pi-editor), PRD (../PRD.md), bridge README (../README.md),
      blink.cmp (https://github.com/Saghen/blink.cmp), nvim-cmp
      (https://github.com/hrsh7th/nvim-cmp), pi docs (packages + extensions).
  - DO NOT: invent options/keys/commands; repeat "0.10+"; mark blink/cmp/core "forthcoming";
      document :PiSubmit (PRD §15 FUTURE, not shipped); claim engine auto-routes; edit any
      source/test/vimdoc; use <owner> placeholders (owner = dabstractor — concrete).

Task 3: UPDATE README.md (repo root) — de-stale the plugin framing; cross-link
  - FILE: README.md (EDIT IN PLACE — surgical; PRESERVE all still-accurate content).
  - REPLACE the intro "companion plugin (forthcoming, see Phase 2)" framing with the shipped
      reality: the repo ships BOTH the pi extension (pi-editor-bridge) AND the Neovim plugin
      (pi-bridge.nvim, under plugin/). Keep the bridge as THIS README's focus (it is the
      `pi install` target); add a one-line pointer to plugin/README.md + plugin/doc/pi-editor.txt.
  - REPLACE the "What it does" note block ("the Neovim-side rendering plugin ships separately
      under Phase 2. Until it lands…") with: the companion plugin is COMPLETE (under plugin/);
      together they deliver pi-faithful completion in the external editor.
  - REPLACE "Companion plugin: install pi-bridge.nvim … See that plugin's README (Phase 2)."
      → point to plugin/README.md (now exists) with the lazy.nvim `lazy=false` note.
  - FIX the Troubleshooting line "Until Phase 2 ships, remember to `:w` before `:q`." → the
      plugin now AUTOSAVES on VimLeavePre (autosave_on_exit=true); remove the stale caveat
      (or rephrase to ":x/ZZ or rely on autosave").
  - FIX the Links "Companion plugin: pi-bridge.nvim (Phase 2, forthcoming)." → link to
      plugin/README.md and `:help pi-editor` (plugin/doc/pi-editor.txt).
  - ADD `plugin/` to the repo-layout block (currently lists only package.json + extension/).
  - PRESERVE: Prerequisites, Installation (pi install git:github.com/dabstractor/pi-nvim-bridge),
      the multi-file-package warning, Configuration ($EDITOR) + optional NVIM_APPNAME
      optimization (PI_EDITOR_NVIM_APPNAME), How it works, the PI_NVIM_BRIDGE env-var
      section (process-local + token-safety), Security, Development (typecheck + node:test via
      jiti), the LICENSE note.
  - DO NOT: restructure the whole README (surgical edits only); change the package name
      (pi-editor-bridge) or install commands; add a LICENSE file; mark anything forthcoming;
      touch any other file.

Task 4: VALIDATE — grep/link/render checks (the real gate; pure shell, no nvim needed)
  - RUN the Validation Loop Level 1-4 below. Fix any MISSING/STALE hit; re-run until green.
```

### Implementation Patterns & Key Details

```markdown
<!-- plugin/README.md — copy-ready fragments (the implementer fills surrounding prose) -->

## Configuration  (mirror plugin/lua/pi-editor/init.lua M.defaults VERBATIM)

```lua
require("pi-editor").setup({
  menu            = { max_height = 12, border = "rounded" },
  debounce_ms     = 20,   -- @/# attachment-context; slash/typing use 0 ms (pi-faithful)
  rpc_timeout_ms  = 2000, -- MUST exceed the bridge fd-abort (1500); warns at setup if <= 1500
  autosave_on_exit = true,
  engine          = "builtin", -- "builtin" (shipped) | "blink" | "cmp" (opt-in sources)
  -- env_var = "PI_NVIM_BRIDGE", -- override the bridge-descriptor env var
})
```

## Optional — blink.cmp source  (SHIPPED, opt-in; snippet verbatim from blink_source.lua)

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
> Additive: the builtin menu still runs unless you suppress it. The source exposes trigger
> characters `{"/", "@"}` and delegates acceptance to pi's `applyCompletion`.

## Optional — nvim-cmp source  (SHIPPED, opt-in; snippet verbatim from cmp_source.lua)

```lua
require("cmp").setup({
  sources = cmp.config.sources({ { name = "pi" } }),
})
require("cmp").register_source("pi", require("pi-editor.cmp_source").new())
```

## Requirements
- **Neovim >= 0.11** (not 0.10 — exact UTF-16 cursor conversion needs the 3-arg
  `vim.str_utfindex` added in 0.11; `:checkhealth pi-editor` enforces it).
- The **pi-editor-bridge** pi extension (`pi list` shows `pi-editor-bridge`).
- **`fd`** *(optional)* — enables `@file` fuzzy search. Debian/Ubuntu: `fdfind`
  (`apt-get install fd-find`). Without it `@file` is empty but path completion still works.

## Submit your prompt
There is **no Enter-to-submit** in the external editor — pi re-reads the temp file only after
the editor **exits**. The plugin autosaves on `VimLeavePre` when modified (`autosave_on_exit`,
default `true`), so `:x`/`ZZ`/a plain save+quit all persist your prompt. `<CR>` accepts a
completion if the menu is open, otherwise inserts a newline.
```

```markdown
<!-- README.md (root) — the surgical de-stale edits (Task 3). Show the BEFORE→AFTER intent,
     not a full rewrite; the implementer applies targeted edits to the existing prose. -->

INTRO (before): "A companion Neovim plugin — pi-bridge.nvim (forthcoming, see Phase 2) …"
INTRO (after):  "This repo ships TWO components: the pi-editor-bridge EXTENSION (this README)
                 and the pi-bridge.nvim Neovim PLUGIN (see plugin/README.md)."

"WHAT IT DOES" NOTE (before): "… the Neovim-side rendering plugin ships separately under
    Phase 2. Until it lands, the bridge advertises correctly but there is nothing on the
    editor side to consume it."
(after): "… the companion pi-bridge.nvim plugin is COMPLETE (under plugin/). Together they
    deliver pi-faithful completion in the external editor."

COMPANION PLUGIN LINE (before): "install pi-bridge.nvim with your plugin manager … See that
    plugin's README (Phase 2)."
(after): "install pi-bridge.nvim with your plugin manager (lazy.nvim, `lazy = false` so the
    VimEnter shim sources before activation). See plugin/README.md and `:help pi-editor`."

TROUBLESHOOTING (before): "Until Phase 2 ships, remember to `:w` before `:q`."
(after): "The plugin autosaves the buffer on VimLeavePre (autosave_on_exit=true). To be
    explicit, quit with `:x`/`ZZ`."

LINKS (before): "Companion plugin: pi-bridge.nvim (Phase 2, forthcoming)."
(after): "Companion plugin: plugin/README.md · :help pi-editor (plugin/doc/pi-editor.txt)."

REPO LAYOUT: ADD a `plugin/` entry (lua/pi-editor/…, plugin/pi-editor.lua, ftplugin/,
    doc/pi-editor.txt, tests/) alongside the existing extension/ block.
```

### Integration Points

```yaml
NEOVIM HELP LOADER: unchanged. plugin/doc/pi-editor.txt (S43) is already the :help surface;
  the READMEs LINK to it (`:help pi-editor`) rather than duplicate it wholesale.
PLUGIN MANAGERS: lazy.nvim / vim.pack / packer discover plugin/README.md as the plugin's
  landing page; the `lazy = false` install note is load-bearing (the VimEnter shim must
  source before the activation event). State it in BOTH READMEs' install sections.
AUTOCMDS / EVENTS: NONE new. The READMEs are pure docs.
STATE / SOURCE: READ-ONLY. The READMEs DESCRIBE shipped code; they change nothing. Any code/
  doc mismatch surfaced is a SEPARATE task (out of scope). The one known mismatch (vimdoc
  blink/cmp "forthcoming" vs shipped) is recorded here, NOT fixed by editing the vimdoc.
CONFIG: NONE new. The CONFIGURATION section documents the EXISTING M.defaults verbatim.
EXTENSION (TS): NONE. The root README references the extension read-only; no TS change.
VIMDOC (S43): NOT edited in this task. The READMEs are kept CONSISTENT in content with it
  where they overlap; the README side wins on the blink/cmp drift (doc-SYNC: code is truth).
GITIGNORE: unchanged (no docs artifacts to ignore; doc/tags already committed, unrelated).
```

## Validation Loop

> This is a MARKDOWN docs task. The real gates are grep/link/render checks (shell-only).
> AGENTS.md HARD RULE still applies: if you invoke `nvim` at all, write the snippet to a FILE
> and run `+"luafile <path>" +qa` inside `timeout` — NEVER a heredoc into nvim stdin. In
> practice Level 4 (nvim) is OPTIONAL here; Levels 1-3 are sufficient.

### Level 1: Existence + render sanity (immediate)

```bash
cd /home/dustin/projects/pi-nvim-bridge
# plugin/README.md exists; root README.md still exists.
test -f plugin/README.md && echo "plugin/README.md ok" || { echo "FAIL: no plugin/README.md"; exit 1; }
test -f README.md       && echo "README.md ok"        || { echo "FAIL: no README.md"; exit 1; }
# Markdown fence balance (a missing ``` swallows the rest on render) — per file.
for f in README.md plugin/README.md; do
  o=$(grep -c '^```' "$f"); [ $((o % 2)) -eq 0 ] && echo "$f: fences balanced ($o)" || echo "FAIL: $f unbalanced fences ($o)"
done
# Expected: both "ok"; both fences balanced (even count of ``` lines).
```

### Level 2: De-stale gate (root README has NO plugin/sourcing "forthcoming"/"Phase 2")

```bash
cd /home/dustin/projects/pi-nvim-bridge
echo "--- root README must NOT hedge the plugin/sources as forthcoming ---"
# Allow the word only in genuinely-accurate contexts; the shipped plugin + blink/cmp must not be hedged.
grep -niE 'forthcoming|phase 2|phase2' README.md && echo "WARN: re-check each hit is NOT about the shipped plugin/sources" || echo "ok: no forthcoming/Phase 2 in README.md"
echo "--- root README points at the plugin README + vimdoc ---"
grep -q 'plugin/README.md' README.md && echo "ok: links plugin/README.md" || echo "MISSING: plugin/README.md link"
grep -qiE 'pi-editor\.txt|:help pi-editor' README.md && echo "ok: references vimdoc" || echo "MISSING: vimdoc reference"
echo "--- root README no longer says 'Until Phase 2 ships' ---"
grep -qi 'Until Phase 2 ships' README.md && echo "FAIL: stale 'Until Phase 2 ships' line" || echo "ok: stale line removed"
echo "--- repo layout now mentions plugin/ ---"
grep -q 'plugin/' README.md && echo "ok: layout has plugin/" || echo "MISSING: plugin/ in layout"
# Expected: every grep "ok"/"MISSING resolved"; zero FAIL.
```

### Level 3: plugin/README.md content-accuracy gate (doc-SYNC against shipped source)

```bash
cd /home/dustin/projects/pi-nvim-bridge/plugin
echo "--- config defaults present (mirror init.lua M.defaults) ---"
for v in 'max_height' '"rounded"' 'debounce_ms' 'rpc_timeout_ms' 'autosave_on_exit' '"builtin"' 'PI_NVIM_BRIDGE'; do
  grep -qF "$v" README.md && echo "  ok: $v" || echo "  MISSING: $v"
done
echo "--- 9 keymaps present (mirror ftplugin) ---"
for k in '<Tab>' '<S-Tab>' '<C-N>' '<Down>' '<C-P>' '<Up>' '<C-Y>' '<C-E>' '<CR>'; do
  grep -qF "$k" README.md && echo "  ok: $k" || echo "  MISSING: $k"
done
echo "--- 0.11 floor (NOT 0.10) ---"
grep -q '0\.11' README.md && echo "  ok: mentions 0.11" || echo "  MISSING 0.11"
grep -qiE 'requires?.*0\.10|nvim ?>= ?0\.10' README.md && echo "  WARN: still claims 0.10" || echo "  ok: no 0.10 requirement"
echo "--- blink/cmp sources documented as SHIPPED opt-in (with registration snippets) ---"
grep -q 'pi-editor.blink_source' README.md && echo "  ok: blink source module named" || echo "  MISSING blink_source"
grep -q 'pi-editor.cmp_source'   README.md && echo "  ok: cmp source module named"   || echo "  MISSING cmp_source"
grep -qiE 'register_source|providers' README.md && echo "  ok: registration snippet present" || echo "  MISSING registration snippet"
echo "--- env var + token-safety + autosave + dormant ---"
for kw in 'PI_NVIM_BRIDGE' 'process-local\|inside pi' 'token' 'autosave' 'dormant'; do
  grep -qiE "$kw" README.md && echo "  ok: $kw" || echo "  MISSING: $kw"
done
echo "--- troubleshooting coverage ---"
for kw in '@file' 'checkhealth' 'lazy ?= ?false\|lazy = false' 'pi -p\|print mode'; do
  grep -qiE "$kw" README.md && echo "  ok: $kw" || echo "  MISSING: $kw"
done
echo "--- no <owner> placeholder left (owner is concrete: dabstractor) ---"
grep -q '<owner>' README.md && echo "  FAIL: <owner> placeholder remains" || echo "  ok: no <owner> placeholder"
# Expected: every grep "ok"; zero MISSING; zero FAIL.
```

### Level 4 (OPTIONAL): confirm the documented defaults truly match the source (no nvim needed)

```bash
cd /home/dustin/projects/pi-nvim-bridge
# Cross-check the README's stated defaults against init.lua M.defaults (grep the source).
echo "--- source M.defaults (authoritative) ---"
grep -nE 'max_height|border|debounce_ms|rpc_timeout_ms|autosave_on_exit|engine' plugin/lua/pi-editor/init.lua | head
# Manually confirm the plugin/README.md table matches these EXACT values. If any value in the
# README differs from the source, fix the README (doc-SYNC: source wins).
# (No nvim invocation required for a markdown docs task; this grep is the real check.)
```

```bash
# OPTIONAL nvim gate (only if you want to confirm :help still resolves after no vimdoc change).
# Write the driver to a FILE (AGENTS.md); wrap in timeout. Skip entirely if unnecessary.
cat > /tmp/s44_help.lua <<'LUA'
vim.opt.runtimepath:append(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h") .. "/plugin")
vim.cmd("helptags plugin/doc")
local found = vim.fn.taglist("^pi-editor$")
io.stdout:write(#found > 0 and "pi-editor tag resolves\n" or "MISSING pi-editor tag\n")
LUA
timeout 60 nvim --headless --clean -u NORC +"luafile /tmp/s44_help.lua" +qa; echo "exit=$?"; rm -f /tmp/s44_help.lua
# Expected (if run): "pi-editor tag resolves"; exit=0. (The READMEs did NOT touch the vimdoc,
# so this is a no-regression sanity check only.)
```

## Final Validation Checklist

### Technical Validation
- [ ] Level 1: both files exist; fences balanced in each.
- [ ] Level 2: root README has no shipped-plugin "forthcoming/Phase 2" hedging; links
      `plugin/README.md` + the vimdoc; the "Until Phase 2 ships" line is gone; layout has `plugin/`.
- [ ] Level 3: plugin/README.md has all 7 config defaults, all 9 keymaps, "0.11" (no "0.10"),
      blink/cmp sources named as SHIPPED with registration snippets, env-var + token-safety +
      autosave + dormant, troubleshooting coverage, no `<owner>` placeholder.
- [ ] Level 4: README-stated defaults match `plugin/lua/pi-editor/init.lua` M.defaults (source wins).
- [ ] No edits outside `README.md` and `plugin/README.md`.

### Feature Validation
- [ ] A new user can install both components + wire `$EDITOR=nvim` from the READMEs alone.
- [ ] Quick start covers: `pi install`, lazy.nvim `lazy=false`, `Ctrl+G`, save+quit to submit.
- [ ] The opt-in blink.cmp / nvim-cmp registration snippets are copy-pasteable and accurate.
- [ ] `PI_NVIM_BRIDGE` process-local confusion is addressed (echo shows nothing; `:lua print`).
- [ ] The lost-prompt trap is addressed (autosave_on_exit; `:x`/`ZZ`).
- [ ] No false claims: nothing shipped is marked forthcoming; `:PiSubmit` is NOT documented as real.

### Code Quality / Conventions Validation
- [ ] Markdown renders (fences balanced; tables well-formed; links valid).
- [ ] Concrete values throughout (owner `dabstractor`; version `0.1.0`; no `<owner>`/`<repo>` placeholders).
- [ ] Consistent with the S43 vimdoc where they overlap (config, keymaps, env var, troubleshooting).
- [ ] The blink/cmp "shipped vs vimdoc-forthcoming" drift is reflected as SHIPPED in the READMEs
      (doc-SYNC: code is truth) and NOT propagated as "forthcoming".
- [ ] Repository layout blocks are accurate (root README lists both `extension/` and `plugin/`).

### Documentation
- [ ] Root README remains the extension's `pi install` face, de-staled + cross-linked.
- [ ] plugin/README.md is the plugin's landing page + getting-started + reference pointers.
- [ ] Both READMEs link the PRD, the vimdoc, and each other where useful.

---

## Anti-Patterns to Avoid

- ❌ Don't mark the plugin, the builtin menu, `:checkhealth`, or the blink/cmp sources "forthcoming" — they are SHIPPED (P2 + P4 Complete). The ONLY not-yet-built item is `engine` auto-routing (the builtin menu always runs; the sources are additive opt-ins). State that honestly instead.
- ❌ Don't write "requires Neovim 0.10+" — the floor is **0.11** (coords.lua 3-arg `vim.str_utfindex`; health.lua `min_nvim`). PRD §10.1's "0.10+" is superseded.
- ❌ Don't claim `engine = "blink"`/`"cmp"` switches the UI — `engine` is NOT consumed by any wiring today; the builtin menu always runs. The sources are opt-in adapters the user registers (additive; double-UI if both). Document the forward-contract, don't fake the feature.
- ❌ Don't document `:PiSubmit` as a real command — it is a PRD §15 FUTURE enhancement, NOT shipped. Document built-in commands / keymaps only.
- ❌ Don't document `<CR>` as "submit the prompt" — there is NO Enter-to-submit in the external editor (pi re-reads the temp file only after the editor EXITS). `<CR>` accepts-if-menu-open else inserts a NEWLINE. The autosave-on-VimLeavePre is what persists the prompt.
- ❌ Don't contradict the dormant-by-design model — "nothing happens in my normal nvim" is EXPECTED. Say it first + loudest in the FAQ; point to `:checkhealth pi-editor` (INFO "dormant").
- ❌ Don't tell users to `echo $PI_NVIM_BRIDGE` to verify install — it shows nothing (process-local). Tell them `:lua print(vim.env.PI_NVIM_BRIDGE)` from inside the launched editor, or `:checkhealth pi-editor`.
- ❌ Don't propagate the S43 vimdoc's "blink/cmp forthcoming" wording into the READMEs — the code ships them; doc-SYNC means the README reflects the code. (Editing the vimdoc to fix its drift is out of scope here — S43's file; record, don't repeat.)
- ❌ Don't use `<owner>`/`<repo>` placeholders — the repo is `dabstractor/pi-nvim-bridge` (concrete). `pi install git:github.com/dabstractor/pi-nvim-bridge`.
- ❌ Don't add a `LICENSE` file — package.json declares MIT but no LICENSE is committed; the existing README notes this is a separate human decision. Keep the note, don't add the file.
- ❌ Don't rewrite the root README wholesale — Task 3 is SURGICAL (de-stale + cross-link + layout). Preserve the still-accurate install/config/env-var/security/dev sections.
- ❌ Don't edit source, tests, PRD.md, plan/, any PRP/tasks.json, the vimdoc (S43's file), or `.gitignore`. Only `README.md` + `plugin/README.md`.
- ❌ Don't pipe a heredoc into `nvim` stdin (AGENTS.md HARD RULE — it hangs). This docs task needs NO nvim run at all; if you do the optional Level-4 check, write the snippet to a file and run `+"luafile <path>" +qa` inside `timeout`.
- ❌ Don't paste or document the live `token` value — it is the auth boundary (PRD §12). Document the descriptor SHAPE with a "never paste the token" warning.

---

## Confidence Score: 9/10

A clean docs task: one NEW markdown file (`plugin/README.md`) + SURGICAL edits to one existing
markdown file (root `README.md`). Every fact is DETERMINED by shipped source, verified line-for-line
in this PRP (the 7 config defaults, the 9 keymaps, the 0.11 floor, the env-var shape, the verbatim
blink/cmp registration snippets, the Lua-API surface, and the 4+3 troubleshooting items are all
given verbatim or anchored to exact source lines). The one judgment call — how to frame the
`engine` config / additive sources honestly — is resolved explicitly (document as shipped opt-in,
state the forward-contract). Risk is limited to (a) Markdown rendering nits (caught by Level 1's
fence-balance check) and (b) leaving a stale "forthcoming" somewhere (caught by Level 2's grep gate).
No source/test/vimdoc/PRD changes; no nvim run required.