---
name: "P3.M11.T28.S43 — Write `doc/pi-editor.txt` vimdoc (commands, options, keymaps, troubleshooting)"
description: |
  Ship the **`plugin/doc/pi-editor.txt`** Neovim help file (PRD §13 Phase 3 step 15: "Docs
  (`doc/pi-editor.txt`, README) + keybinding/help hints"; this task owns the VIMDOC half —
  README is S44). The Neovim help loader discovers `doc/*.txt` on `runtimepath` and builds a
  tag index from `*tag*` definitions via `:helptags` (`:help write-local-help`,
  `:help add-local-help`). So the file MUST live at **`plugin/doc/pi-editor.txt`** (the plugin
  `runtimepath` root is `plugin/` — VERIFIED: `lua/`, `ftplugin/`, `plugin/` are siblings of
  the to-be-created `doc/`), line 1 MUST be the file tag `*pi-editor.txt*`, and the
  top-level topic tag `*pi-editor*` is what `:help pi-editor` jumps to.

  **THE TASK TITLE — "commands, options, keymaps, troubleshooting" — names the four sections
  that MUST exist and MUST be accurate to the SHIPPED code (this is a doc-SYNC, Mode B: the
  code already exists; the doc must match it, not aspire to it).** Every option value, key,
  autocmd, and Lua field below was verified by reading the actual source in this repo:

    (1) **OPTIONS** — `require("pi-editor").setup(opts)` merges over `M.defaults`
        (`plugin/lua/pi-editor/init.lua:30-40`). The shipped defaults (VERIFIED, line-for-line):
          menu.max_height      = 12          (int — max visible rows in the floating popup)
          menu.border          = "rounded"   ("none"|"single"|"double"|"rounded"|"solid"|"shadow"|string[])
          debounce_ms          = 20          (file/attachment-context window; slash/typing = 0 ms — pi-faithful)
          rpc_timeout_ms       = 2000        (MUST exceed the bridge fd-abort 1500; a WARN fires if <=1500)
          autosave_on_exit     = true        (write the pi temp file on VimLeavePre if modified)
          engine               = "builtin"   ("builtin"|"blink"|"cmp" — builtin is the SHIPPED menu;
                                             blink/cmp are the P4 FORTHCOMING sources — document honestly)
          env_var              = "PI_EDITOR_BRIDGE" (override the bridge-descriptor env var name)
        The exported `M.defaults` table is read by `:checkhealth pi-editor` + tests, so the vimdoc
        MUST mirror it (a doc/code drift is a bug).

    (2) **KEYMAPS** — 9 buffer-local INSERT-mode mappings, installed ONLY in `pi-prompt`
        buffers by `plugin/ftplugin/pi-prompt.lua` (VERIFIED, the `map_dispatch` block):
          <Tab>    → trigger / accept the menu (pi-faithful Tab — see completion §)
          <S-Tab>  → previous completion item
          <C-N>    → next completion item
          <Down>   → next completion item (mirrors <C-N>)
          <C-P>    → previous completion item
          <Up>     → previous completion item (mirrors <C-P>)
          <C-Y>    → accept if the menu is open, else fall through to i_CTRL-Y
          <C-E>    → dismiss the completion menu
          <CR>     → accept if the menu is open, ELSE INSERT A NEWLINE (NO Enter-to-submit —
                     the external editor submits on save+quit, not Enter; PRD §2.1/§7.4)
        Each keymap falls through to its normal insert-mode default when the completion module
        signals "not handled" (e.g. bridge not connected) — so `<Tab>` still indents and `<CR>`
        still inserts a newline when completion is inactive. These are `buffer = buf` mappings
        (do NOT leak into other buffers).

    (3) **COMMANDS** — there are NO plugin `:UserCommand`s in the shipped code
        (VERIFIED: `grep -rn create_user_command plugin/` → none). The documented commands are
        therefore the BUILT-IN Neovim commands the user drives the plugin with:
          :help pi-editor            (after :helptags) — opens this help file
          :helptags <plugin>/doc     — generates the tag index (or let the plugin manager do it)
          :checkhealth pi-editor     — the S42 health report (4 sections: version/env/socket/fd)
          :messages                  — read the one-time "completion unavailable" notify (S39)
          :lua print(vim.env.PI_EDITOR_BRIDGE) — inspect the process-local descriptor from inside
                                                 the pi-launched nvim
        (`:PiSubmit` is a PRD §15 FUTURE enhancement, NOT shipped — do NOT document it as a
        real command; it may be mentioned as planned in the FAQ.)

    (4) **TROUBLESHOOTING** — the four real failure modes (mirror the shipped `health.lua` §
        advice + the repo `README.md` Troubleshooting, both VERIFIED): (a) "nothing happens in
        nvim" = DORMANT by design (no `PI_EDITOR_BRIDGE` — expected outside a pi session);
        (b) "completion doesn't appear" = extension not loaded / EDITOR not nvim / handshake
        failed (read `:messages`); (c) "`@file` finds nothing" = install `fd` (optional; path
        completion still works); (d) "I typed then `:q` and lost my prompt" = autosave
        (`autosave_on_exit=true` default handles it; document the manual `:w` fallback).
        Plus: `/reload` re-captures the provider + fires `commandsChanged`; other extensions'
        custom triggers (e.g. `#issues`) are a KNOWN LIMITATION (captured at registration
        time); non-interactive `pi -p` mode is a no-op (TUI-only).

  **ADDITIONAL MUST-HAVE SECTIONS (the help file's completeness bar):** an INTRODUCTION (the
  two-component design: pi-editor-bridge extension + this nvim plugin; the dormant-by-design
  activation gate on `PI_EDITOR_BRIDGE`), REQUIREMENTS (nvim >= 0.11 — NOT 0.10 — coords.lua
  GOTCHA 9; the bridge extension; optional `fd`), QUICKSTART (lazy.nvim `lazy=false` so the
  VimEnter shim sources before VimEnter; `require("pi-editor").setup({})`; the three EDITOR
  wirings: `$EDITOR`/`$VISUAL`/settings.json `externalEditor`), COMPLETION BEHAVIOR (pi-
  faithful: slash commands `/model` `/compact` `/skill:…` + prompt templates + extension
  commands; argument completion `/model <provider/id>`; `@file` fuzzy via `fd`; path
  completion `./` `~/` `/abs`; `<Tab>` force-file; acceptance delegates to pi's
  `applyCompletion` so insertion is identical), FILETYPE `pi-prompt` (the ftplugin sets
  `formatoptions-=t`, `textwidth=0`, `wrap`, `spell=false`), AUTOCMDS (the buffer-local
  `pi-editor` augroup: refresh on InsertEnter/TextChangedI/CursorMovedI; auto-close on
  InsertLeave/BufLeave; autosave+teardown on VimLeavePre/ExitPre), ENVIRONMENT (`PI_EDITOR_BRIDGE`
  JSON descriptor shape + why `echo $PI_EDITOR_BRIDGE` shows nothing; optional `NVIM_APPNAME`
  minimal-config optimization — P4, document as optional), and a LUAL API section for source
  authors / integrators (`require("pi-editor")`: `setup/config/defaults/bridge/descriptor`;
  `require("pi-editor.bridge")`: `version/is_connected/server_info/request/cancel/
  on_notification/on_disconnect`; `require("pi-editor.coords")`: the byte↔UTF-16 primitives).

  **DELIVERABLE (CREATE-ONLY — 1 new doc file; NO source edit, NO TS change, NO README change):**
    (1) **CREATE** `plugin/doc/pi-editor.txt` — a vimdoc help file with the sections above, the
        line-1 file tag `*pi-editor.txt*`, the `*pi-editor*` top topic, and a right-aligned
        CONTENTS table linking every section's tag. Wraps ~78 cols; code blocks delimited by a
        trailing `>` (on its own line, after the intro) and a column-0 `<` to close. Every
        option/key/autocmd/field must match the shipped code exactly.
    (2) **VALIDATE** `:helptags plugin/doc` succeeds (no duplicate/malformed tags) and
        `:help pi-editor` (+ each section tag) resolves to the right line — see Validation Loop.
    (3) **(DECISION, documented in the PRP)** whether to commit `plugin/doc/tags` (generated by
        `:helptags`): the Neovim-plugin convention is split; committing it lets `:help` work
        without a manual `:helptags`. This PRP's recommendation: COMMIT it (lazy.nvim/pack.nvim
        both run `:helptags` anyway, but a committed `tags` is harmless + belt-and-suspenders).
        `.gitignore` does NOT ignore it (VERIFIED). Noting the choice here; the implementer
        commits `tags` if the recommendation is followed.

  **NON-GOALS:** NO README edits (that is S44 — a separate, deliberate PRP; the README currently
  says the nvim plugin is "forthcoming (Phase 2)" and that is STALE now that P2 is Complete —
  but fixing it is S44's job, NOT this PRP's). NO source-code edits (this is a doc-SYNC; if the
  vimdoc reveals a code/doc mismatch the fix is a SEPARATE code task — this PRP only documents
  the shipped behavior). NO blink/cmp source docs beyond "forthcoming" (P4 not shipped). NO
  `:PiSubmit` (PRD §15 future). NO ftdetect/ftplugin/syntax files (the filetype is already set
  by `activate()`; §7.1 names an optional `after/ftplugin` as "if desired" — out of scope here).

  **NON-REGRESSION:** `doc/pi-editor.txt` is a NEW pure-text file on runtimepath. It cannot
  break any test or source. The only runtime effect is `:help pi-editor` resolving (after
  `:helptags`) — which is a net new capability. All existing specs/smokes are untouched.
---

# Goal

**Feature Goal**: Ship a complete, accurate, `:helptags`-clean Neovim vimdoc
(`plugin/doc/pi-editor.txt`) so a user who has never seen this plugin can, from inside
Neovim alone, learn what `pi-editor.nvim` does, how to install/configure it, which keys do
what, how completion behaves (pi-faithful), and how to troubleshoot — with every documented
option/key/autocmd matching the shipped code exactly (doc-SYNC, Mode B). PRD §13 Phase 3 step
15 ("Docs (`doc/pi-editor.txt`, README)") names this vimdoc; this task delivers the vimdoc half.

**Deliverable** (CREATE-ONLY — 1 new file; NO source edit, NO TS change, NO README change):
- **`plugin/doc/pi-editor.txt`** — the vimdoc. Line 1 = file tag `*pi-editor.txt*`. Sections:
  INTRODUCTION, REQUIREMENTS, QUICKSTART, CONFIGURATION, COMMANDS, KEYMAPS, AUTOCMDS,
  COMPLETION, FILETYPE, ENVIRONMENT, LUA API, CHECKHEALTH, TROUBLESHOOTING (FAQ). Every
  option value, key, autocmd, and Lua field mirrors the shipped source (verified in the
  Description block above).
- **`plugin/doc/tags`** — generated by `:helptags plugin/doc` (recommended to commit; see
  the decision in the Description).

**Success Definition**:
- `:helptags plugin/doc` runs with **zero** "Duplicate tag" / "E432"/malformed errors and
  emits a `tags` file whose entries all resolve.
- `:help pi-editor` opens `plugin/doc/pi-editor.txt` and lands on the `*pi-editor*` tag.
- Every CONTENTS-table link + every inline `|tag|` link jumps to the right section
  (`:help pi-editor-config`, `pi-editor-keymaps`, `pi-editor-troubleshooting`, …).
- The CONFIGURATION section's defaults table is byte-faithful to `init.lua:30-40`
  (`menu.max_height=12`, `menu.border="rounded"`, `debounce_ms=20`, `rpc_timeout_ms=2000`,
  `autosave_on_exit=true`, `engine="builtin"`, `env_var="PI_EDITOR_BRIDGE"`).
- The KEYMAPS section lists all 9 buffer-local insert-mode keys with the EXACT behavior
  (incl. `<CR>` = accept-or-newline, NOT submit; `<C-Y>` = accept-or-i_CTRL_Y; the
  fall-through-to-default semantics).
- The REQUIREMENTS section states Neovim **>= 0.11** (NOT 0.10 — coords.lua GOTCHA 9),
  the `pi-editor-bridge` extension, and optional `fd`.
- The TROUBLESHOOTING section covers all four real failure modes + the three known
  limitations (other extensions' triggers, non-interactive mode, autosave).
- The file wraps at ~78 columns; every code block has a matching `>`/`<` pair; no line
  exceeds the help column convention.
- No existing source/test is touched; no README edit (S44's job).

## User Persona

**Target User**: a pi user who just installed `pi-editor.nvim` (or is evaluating it) and wants
to understand it FROM WITHIN NEOVIM — without leaving the editor to read a README or the PRD.
A secondary audience is a **plugin integrator / source author** wiring the optional blink/cmp
sources or scripting against the bridge, who needs the Lua API reference.

**Use Case**: "I installed pi-editor.nvim with lazy.nvim; how do I configure the menu border,
what does `<Tab>` do, why is nothing happening in my normal nvim, and how do I turn on `@file`
completion?" They run `:help pi-editor` and get a single, navigable, accurate answer.

**Pain Points Addressed**: today there is no `doc/pi-editor.txt` (PRD §13 step 15 vimdoc half
is not done), so the only docs are the repo `README.md` (which currently still calls the nvim
plugin "forthcoming (Phase 2)" — stale) and the PRD (too dense for end users). Users have no
`:help`-discoverable, link-navigable reference. This task ships it.

## Why

- **PRD fidelity**: PRD §13 (Implementation Plan, Phase 3 — Polish) step 15 literally lists
  "Docs (`doc/pi-editor.txt`, README)". This task delivers the vimdoc half (README = S44).
- **Closes the discoverability gap**: `:help pi-editor` is the canonical Neovim way to learn a
  plugin; every other plugin ships a `doc/*.txt`. The absence is a visible quality gap,
  especially for a plugin with a non-obvious activation model (dormant unless pi spawned it).
- **Single source of truth for end users**: the README is markdown (GitHub/website); the
  vimdoc is what a user reads mid-edit. The dormant-by-design gate, the pi-faithful `<Tab>`/
  `<CR>` semantics, and the autosave behavior are the three things users get wrong most —
  documenting them in `:help` directly reduces support load.
- **Doc-SYNC correctness (Mode B)**: the code is Complete (P1+P2). The doc must MATCH it, not
  invent it. Verifying every field against source (done in this PRP's research) means the
  implementer copies accurate content, not guesses — so one-pass success is high.

## What

`plugin/doc/pi-editor.txt` is a standard Neovim help file. `:helptags plugin/doc` indexes its
`*tag*` definitions into `plugin/doc/tags`; thereafter `:help pi-editor` (and every `|tag|`
link) resolves. The file has these sections (each with its own tag, linked from a
right-aligned CONTENTS table):

1. **INTRODUCTION** (`pi-editor-intro`) — what the plugin is; the two-component design
   (`pi-editor-bridge` extension on the pi side + this nvim plugin); the dormant-by-design
   gate on `PI_EDITOR_BRIDGE`.
2. **REQUIREMENTS** (`pi-editor-requirements`) — Neovim **>= 0.11** (coords.lua GOTCHA 9 —
   the 3-arg `vim.str_utfindex` UTF-16 overload); the `pi-editor-bridge` pi extension
   (installed + `pi list` shows it); optional `fd` for `@file` fuzzy search.
3. **QUICKSTART** (`pi-editor-quickstart`) — lazy.nvim with `lazy = false` (so the `plugin/`
   shim sources before VimEnter); `require("pi-editor").setup({})`; the three EDITOR wirings
   (`export EDITOR=nvim` / `export VISUAL=nvim` / settings.json `"externalEditor": "nvim"` —
   the latter takes precedence); press `Ctrl+G` in pi to open the editor.
4. **CONFIGURATION** (`pi-editor-config`) — `setup(opts)` + the full defaults table + per-field
   prose (see Description for the exact values).
5. **COMMANDS** (`pi-editor-commands`) — the built-in commands (`:help`, `:helptags`,
   `:checkhealth pi-editor`, `:messages`, `:lua print(vim.env.PI_EDITOR_BRIDGE)`). State
   clearly: the plugin defines NO `:UserCommand`s.
6. **KEYMAPS** (`pi-editor-keymaps`) — all 9 buffer-local insert-mode keys + behavior +
   fall-through semantics (see Description).
7. **AUTOCMDS** (`pi-editor-autocmds`) — the buffer-local `pi-editor` augroup: refresh
   (InsertEnter/TextChangedI/CursorMovedI), auto-close (InsertLeave/BufLeave),
   autosave+teardown (VimLeavePre/ExitPre when `autosave_on_exit ~= false`).
8. **COMPLETION** (`pi-editor-completion`) — pi-faithful: slash commands + skill templates +
   prompt templates + extension commands; argument completion; `@file` fuzzy (fd); path
   completion; `<Tab>` force-file; accept delegates to pi's `applyCompletion` (identical
   insertion). Note the debounce model (0 ms slash/typing; `debounce_ms` for @/# context).
9. **FILETYPE** (`pi-editor-filetype`) — `pi-prompt`: set by `activate()`; the ftplugin sets
   `formatoptions-=t`, `textwidth=0`, `wrap`, `spell=false`.
10. **ENVIRONMENT** (`pi-editor-env`) — the `PI_EDITOR_BRIDGE` JSON descriptor (transport/path/
    token/pid/cwd/fdAvailable/serverVersion); WHY `echo $PI_EDITOR_BRIDGE` shows nothing
    (process-local, only the child `$EDITOR` sees it); inspect via
    `:lua print(vim.env.PI_EDITOR_BRIDGE)`; optional `NVIM_APPNAME` minimal-config optimization
    (P4, optional, document as such).
11. **LUA API** (`pi-editor-api`) — for integrators: `require("pi-editor")` fields
    (`setup/config/defaults/bridge/descriptor`); `require("pi-editor.bridge")` fields
    (`version/is_connected/server_info/request/cancel/on_notification/on_disconnect`);
    `require("pi-editor.coords")` (`byte_to_utf16/utf16_to_byte/nvim_to_pi_coords/pi_to_nvim_coords`).
12. **CHECKHEALTH** (`pi-editor-checkhealth`) — pointer to `:checkhealth pi-editor` (S42) and
    what its 4 sections report.
13. **TROUBLESHOOTING / FAQ** (`pi-editor-troubleshooting`) — the four failure modes + three
    limitations (see Description).

### Success Criteria

- [ ] `plugin/doc/pi-editor.txt` exists; line 1 is `*pi-editor.txt*  For Nvim 0.11+  ...`.
- [ ] `*pi-editor*` top-level tag present (what `:help pi-editor` jumps to).
- [ ] CONTENTS table with right-aligned `|tag|` links for all 13 sections.
- [ ] All 13 section tags exist + resolve (`:help <tag>` lands on the section header).
- [ ] CONFIGURATION defaults are byte-faithful to `init.lua:30-40` (7 fields).
- [ ] KEYMAPS lists all 9 keys with exact behavior (incl. `<CR>` accept-or-newline, `<C-Y>`
      accept-or-i_CTRL_Y, fall-through semantics).
- [ ] REQUIREMENTS states nvim >= 0.11 (not 0.10), the bridge extension, optional fd.
- [ ] TROUBLESHOOTING covers: dormant/nothing-happens, completion-doesn't-appear, @file-empty,
      lost-prompt/autosave, /reload, other-extensions-trigger-limitation, non-interactive-noop.
- [ ] Code blocks balanced (`>` ... `<`); file wraps ~78 cols; no malformed tags.
- [ ] `:helptags plugin/doc` exits 0 with zero warnings; `:help pi-editor` resolves.
- [ ] No source/test/README edits; only `plugin/doc/pi-editor.txt` (+ optionally `doc/tags`).

## All Needed Context

### Context Completeness Check

_Passed._ A reader who knows nothing of this codebase gets: the Neovim help-file loader model
(`doc/*.txt` on rtp + `:helptags` + `*tag*`/`|tag|` syntax + the `>`/`<` code-fence + 78-col
convention — all from `:help help-writing`/`:help write-local-help`), the EXACT shipped
defaults/keys/autocmds/Lua-fields (verified line-for-line against the source in this PRP's
research), the dormant-by-design activation model, the pi-faithful completion semantics, the
four real troubleshooting modes + three limitations, the line-1 file-tag requirement, and a
copy-ready vimdoc skeleton (Implementation Patterns). No guessing required.

### Documentation & References

```yaml
# MUST READ — the Neovim help-writing conventions (the FORMAT this file must follow)
- url: https://neovim.io/doc/user/usr_41.html#41.12   # "Writing documentation"
  why: The canonical rules: first line is `*filename.txt*`; column-0 for tags/section headers;
       `>` on its own line (after the intro text) opens a code block, `<` at column 0 closes it;
       `*tag*` defines a help link target, `|tag|` is a link; `'option'` for options; right-aligned
       `tag` in a CONTENTS line = a TOC entry. Section headers underlined with `=`. Keep <= 78 cols.
  critical: |
    (1) The FIRST non-blank line MUST be the file tag `*pi-editor.txt*` (else `:helptags` skips it).
    (2) A `>` opens a code block; the matching `<` MUST be at column 0 or it isn't recognized.
    (3) Tags are UNIQUE across ALL help files on rtp — prefix everything `pi-editor-…` to avoid
        collisions (e.g. NOT `config`, which would clash — use `pi-editor-config`).
    (4) `:helptags` errors on DUPLICATE tags within the file — define each `*tag*` exactly once.
  tag: ":help help-writing", ":help write-local-help", ":help add-local-help", ":help helptags"

- url: https://github.com/neovim/neovim/blob/master/runtime/doc/faq.txt   # a compact reference help file
  why: A real, small vimdoc to model STRUCTURE on: line-1 tag, a CONTENTS table with right-aligned
       `|tag|` links, `=`-underlined section headers, `>`/`<` code blocks, `*tag*` definitions. Mirror
       this shape (not its content).
  pattern: line 1 `*faq.txt*	For Nvim ...`; then a `CONTENTS` block of `1. Topic .... |faq-x|` lines.

- url: https://github.com/nvim-telescope/telescope.nvim/blob/master/doc/telescope.txt
  why: A widely-used PLUGIN help file (closest analog to what we ship). Note: its setup() example
       block, its options table, its keymap table — the three structures this PRP's CONFIGURATION +
       KEYMAPS sections mirror. Also note lazy.nvim users run `:checkhealth telescope` + `:Telescope`
       — we have NO `:UserCommand`, so document built-in commands instead.

# MUST READ — the SHIPPED code this vimdoc must match EXACTLY (doc-SYNC, Mode B; read-only)
- file: plugin/lua/pi-editor/init.lua
  why: |
    THE source of truth for the CONFIGURATION section. `M.defaults` (:30-40) is the exact defaults
    table (menu.max_height=12, menu.border="rounded", debounce_ms=20, rpc_timeout_ms=2000,
    autosave_on_exit=true, engine="builtin", env_var="PI_EDITOR_BRIDGE"). The `pi-editor.Config`
    class (:16-25) + `pi-editor.MenuConfig` (:12-14) give the field TYPES + prose for each option.
    `M.setup(opts)` (:46) is the documented entry (`setup({ ... })`); `M.config` (:42, nil until
    setup), `M.defaults` (:31), `M.bridge` (:48, nil until handshake), `M.descriptor` (:108, nil if
    dormant), `M.activate()` (:130) = the LUA API section's `require("pi-editor")` fields.
  gotcha: debounce_ms is the FILE/@-context window ONLY — slash commands + plain typing use 0 ms
    (pi-faithful; init.lua:19,36). rpc_timeout_ms MUST exceed 1500 (the bridge fd-abort) — a WARN
    fires at setup if <=1500 (init.lua the S40 guard). engine="builtin" ships; "blink"/"cmp" are
    FORTHCOMING (P4) — document honestly, do NOT claim they work today.

- file: plugin/ftplugin/pi-prompt.lua
  why: |
    THE source of truth for the KEYMAPS + AUTOCMDS + FILETYPE sections. The `map_dispatch` block
    installs exactly 9 buffer-local insert-mode keys: <Tab>→on_tab, <S-Tab>→on_prev, <C-N>→on_next,
    <C-P>→on_prev, <C-E>→on_dismiss, <CR>→on_enter, <Down>→on_next, <Up>→on_prev, <C-Y>→on_enter
    (the exact dispatch table). The Options block sets formatoptions-=t, textwidth=0, wrap, spell=false.
    The Autocmds block (shared "pi-editor" augroup, clear=false): InsertEnter/TextChangedI/
    CursorMovedI→refresh; InsertLeave/BufLeave→auto-close; VimLeavePre/ExitPre→autosave+teardown
    (gated on autosave_on_exit~=false). The `dispatch` helper's fall-through-to-default semantics
    (feedkey when not handled) is the documented "Tab still indents / CR still newlines" behavior.
  gotcha: `<CR>` accepts only when the menu is open; otherwise it inserts a NEWLINE (NO Enter-to-
    submit — the external editor submits on save+quit, PRD §2.1/§7.4; document this prominently).
    `<C-Y>` REUSES on_enter (accept if menu open else i_CTRL_Y fall-through — no separate on_accept).

- file: plugin/lua/pi-editor/health.lua
  why: |
    THE source of truth for the CHECKHEALTH section + the troubleshooting advice. `M.check()` has 4
    `health.start()` sections (pi-editor / bridge-environment / bridge-connection / external-tools-fd).
    `M.min_nvim = "0.11"` (the version floor — coords.lua GOTCHA 9). The advice strings (fd install,
    "save+quit and re-open from pi", "run :messages for a handshake error") are the EXACT copy the
    TROUBLESHOOTING section should paraphrase. The dormant `info "dormant"` line = the "nothing
    happens in nvim" FAQ answer.
  gotcha: the fd section tries BOTH "fd" and "fdfind" (Debian) — document both install paths.

- file: plugin/lua/pi-editor/bridge.lua
  why: |
    THE source of truth for the LUA API section's `require("pi-editor.bridge")` fields + the
    ENVIRONMENT section's handshake/serverVersion. Exported: `M.version="0.1.0"` (:176),
    `M.server_info` (:188, nil until handshake), `M.is_connected()` (:846), `M.request(method,
    params, on_result)->id|nil` (:478), `M.cancel(id)` (:566), `M.on_notification(method,handler)`
    (:586), `M.on_disconnect(handler)` (:619), `M.connect/send/handshake/close/on_exit` (transport).
    The `pi-editor.ServerInfo` (:182) + `pi-editor.BridgeDescriptor` (init.lua:99) classes give the
    field shapes.
  gotcha: the token is the auth boundary — NEVER echo it (PRD §12). The descriptor JSON shape
    (transport/path/token/pid/cwd/fdAvailable/serverVersion) is what the ENVIRONMENT section documents.

- file: plugin/lua/pi-editor/coords.lua
  why: THE source of truth for the LUA API section's `require("pi-editor.coords")` fields:
    `byte_to_utf16(line, byte_idx)` (:138), `utf16_to_byte(line, utf16_idx)` (:163),
    `nvim_to_pi_coords(lines, row, byte_col)` (:212), `pi_to_nvim_coords(lines, cursorLine,
    cursorCol)` (:238). The 0.11 floor (GOTCHA 9: the 3-arg `vim.str_utfindex` overload) is the
    REQUIREMENTS section's ">= 0.11, not 0.10" basis.

- file: plugin/lua/pi-editor/completion.lua
  why: |
    THE source of truth for the COMPLETION section's trigger/accept behavior. The header (:1-90)
    documents the trigger-aware debounce (0 ms slash/typing; debounce_ms for @/# attachment context,
    mirroring pi's `getAutocompleteDebounceMs`). `on_tab` (:672) documents the 3-branch pi-faithful
    Tab (accept if menu open; slash force:false; else shouldTriggerFileCompletion→force:true).
    `accept` (:579) delegates to pi's `applyCompletion` (identical insertion). The two-layer
    supersession (cancel + generation-id guard) + "error/cancelled → touch nothing" semantics are
    why completion degrades silently on a flaky bridge.
  gotcha: acceptance replaces the ENTIRE buffer + sets the cursor (applyCompletion returns full lines
    + cursor) — the plugin NEVER reimplements insertion edge cases (trailing space for files, no space
    for dirs, quotes, `/cmd `). Document "insertion is identical to the TUI" as a user-facing feature.

# MUST READ — the PRD anchors (the spec this doc reflects; read-only)
- file: PRD.md
  section: "§2.1 (editor launch), §7.1 (activation gate), §7.4 (trigger/accept + <CR> nuance), §7.6
            (ftplugin opts/keymaps/autocmds), §10 (install/config), §11 (edge cases), §16 (pi source map)"
  why: The authoritative design. Cross-check the vimdoc's prose against these sections (e.g. the
        "no Enter-to-submit" claim in §2.1/§7.4; the autosave motivation in §11; the lazy=false
        install note in §10.3). Do NOT contradict the PRD; if the shipped code differs from the PRD,
        the SHIPPED CODE wins (doc-SYNC) — but flag it in the PRP's Gotchas (e.g. the 0.11 vs 0.10 floor).

# Reference — the repo README (markdown, end-user-facing; the vimdoc should be CONSISTENT with it
# where they overlap, but the README is S44's to fix — do NOT edit it in this task)
- file: README.md
  why: The markdown analog. Its "Configuration (`$EDITOR`)", "PI_EDITOR_BRIDGE env var",
        "Troubleshooting", and "Security" sections are the prose the vimdoc should MIRROR (not copy
        verbatim — adapt to vimdoc + stay consistent). NOTE: the README currently says the nvim plugin
        is "forthcoming (Phase 2)" — that is STALE (P2 is Complete) — but fixing the README is S44's
        job, NOT this PRP's. The vimdoc should describe the SHIPPED plugin (it is done).
  gotcha: do NOT mark anything "forthcoming" in the vimdoc EXCEPT the blink/cmp sources (genuinely
    P4-planned). The core plugin, the bridge extension, the builtin menu, and :checkhealth are all DONE.

# Reference — the bridge extension (pi side; documents the ENVIRONMENT descriptor + protocol)
- file: extension/pi-editor-bridge.ts
  why: `BRIDGE_VERSION = "0.1.0"` (:272) = the descriptor `serverVersion`. The descriptor write
        (:467: `{transport:"unix", path, token, pid, cwd, fdAvailable, serverVersion}`) is the JSON
        shape the ENVIRONMENT section documents. Read-only; no TS change.
```

### Current Codebase tree (relevant slice)

```bash
plugin/
  lua/pi-editor/
    init.lua          # M.defaults (:30-40) + M.setup/config/defaults/bridge/descriptor/activate — the CONFIG + LUA-API source of truth
    ftplugin/pi-prompt.lua  # the 9 keymaps + autocmds + ft options — the KEYMAPS/AUTOCMDS/FILETYPE source of truth
    bridge.lua        # M.version/server_info/is_connected/request/cancel/on_notification/on_disconnect — LUA-API + ENV source
    completion.lua    # trigger/accept/debounce/Tab semantics — COMPLETION source
    coords.lua        # byte↔UTF-16 primitives + the 0.11 floor (GOTCHA 9) — LUA-API + REQUIREMENTS source
    health.lua        # the 4 check sections + min_nvim="0.11" + advice strings — CHECKHEALTH + TROUBLESHOOTING source
    menu.lua  jsonlreader.lua  notify.lua        # referenced by the LUA-API cross-links (unchanged)
  plugin/pi-editor.lua   # VimEnter shim (lazy=false install note documents THIS; unchanged)
  ftplugin/pi-prompt.lua # (the file above; lives at plugin/ftplugin/)
  # doc/  ← NEW (this task): doc/pi-editor.txt  (and :helptags-generated doc/tags)
  tests/                  # unchanged (the vimdoc is pure text; no test changes)
extension/                # unchanged (no TS change; the vimdoc is client-side docs)
```

### Desired Codebase tree with files to be added and responsibility

```bash
plugin/doc/pi-editor.txt   # NEW — the vimdoc help file. 13 sections (intro/requirements/quickstart/
                           #       config/commands/keymaps/autocmds/completion/filetype/env/lua-api/
                           #       checkhealth/troubleshooting). Line 1 = *pi-editor.txt*. Every option/
                           #       key/autocmd/field mirrors the shipped code (doc-SYNC). ~78-col wrap;
                           #       balanced > / < code fences; *pi-editor-…* tags (unique, prefixed).
plugin/doc/tags            # NEW (generated) — the :helptags index of *tag* definitions. RECOMMENDED to
                           #       commit (lazy.nvim/pack.nvim regenerate it anyway; a committed copy is
                           #       belt-and-suspenders). .gitignore does NOT ignore it (VERIFIED).
```

### Known Gotchas of our codebase & Library Quirks

```vimhelp
" CRITICAL (line-1 file tag): the FIRST non-blank line MUST be `*pi-editor.txt*<TAB>For Nvim ...`.
" :helptags skips a doc file whose first line isn't a `*file.txt*` tag. (help-writing)

" CRITICAL (unique prefixed tags): help tags are GLOBAL across all rtp doc files. Prefix EVERY tag
" `pi-editor-…` (NOT `config`→clash; USE `pi-editor-config`). Define each `*tag*` EXACTLY ONCE —
" :helptags ERRORS on a duplicate tag within the file.

" CRITICAL (code fence balance): a code block opens with `>` on its OWN line (AFTER the intro prose)
" and closes with `<` at COLUMN 0. A missing/indented `<` swallows the rest of the file as "code".
" Every `>` MUST have a matching `<`. (help-writing)

" CRITICAL (doc-SYNC accuracy, Mode B): the code is COMPLETE (P1+P2). The doc must MATCH it. The 7
" config defaults are EXACT (init.lua:30-40): menu.max_height=12, menu.border="rounded", debounce_ms=20,
" rpc_timeout_ms=2000, autosave_on_exit=true, engine="builtin", env_var="PI_EDITOR_BRIDGE". The 9 keys
" are EXACT (ftplugin). Do NOT invent options/keys; do NOT mark core features "forthcoming".

" GOTCHA (0.11 floor, NOT 0.10): REQUIREMENTS must say Neovim >= 0.11. coords.lua GOTCHA 9 — the exact-
" UTF-16 3-arg `vim.str_utfindex` overload was ADDED in 0.11. health.lua `M.min_nvim="0.11"` enforces it.
" PRD §10.1's "0.10+" text is SUPERSEDED — the vimdoc must NOT repeat "0.10+".

" GOTCHA (engine="blink"/"cmp" are FORTHCOMING): the `engine` option ACCEPTS "builtin"|"blink"|"cmp"
" but ONLY "builtin" ships today (the dependency-free floating menu, S34+). blink_source.lua (S45) +
" cmp_source.lua (S46) are P4-Planned, NOT done. Document "builtin" as the shipped default + mark
" blink/cmp as forthcoming — do NOT document their config/source API (it does not exist yet).

" GOTCHA (<CR> is NOT submit): in the external editor there is NO Enter-to-submit — pi reads the temp
" file only AFTER the editor EXITS (PRD §2.1/§7.4). So `<CR>` accepts if the menu is open, ELSE inserts
" a NEWLINE. Document this prominently (it is the #2 user confusion after "nothing happens"). The
" autosave-on-quit (VimLeavePre) is what actually persists the prompt — document that link.

" GOTCHA (<C-Y> reuses on_enter): there is NO separate on_accept. `<C-Y>` accepts if the menu is open,
" else falls through to `:help i_CTRL-Y`. Document both branches.

" GOTCHA (dormant is EXPECTED): the plugin is dormant in every ordinary nvim session (no
" PI_EDITOR_BRIDGE). "I installed it and nothing happens in nvim" is the EXPECTED normal-config state.
" The FAQ must say this first + loudest, and point to `:checkhealth pi-editor` (info "dormant").

" GOTCHA (PI_EDITOR_BRIDGE is process-local): `echo $PI_EDITOR_BRIDGE` in a shell shows NOTHING — the
" var is written to process.env INSIDE pi and only the child $EDITOR sees it. This is the #1 install
" confusion. Document `:lua print(vim.env.PI_EDITOR_BRIDGE)` as the way to inspect it.

" GOTCHA (the token is sensitive): PRD §12 — NEVER echo/paste the `token` field. The ENVIRONMENT section
" documents the descriptor SHAPE but must warn not to paste the live descriptor (esp. the token) into
" bug reports.

" GOTCHA (other extensions' triggers are a known limitation): the bridge captures the provider at its
" OWN registration time, so wrappers registered AFTER it (e.g. a `#issues` trigger) do NOT appear in the
" external editor. The base provider (slash/skill/template/path) is always captured. Document as a
" known limitation in TROUBLESHOOTING (not a bug to fix here).

" GOTCHA (non-interactive mode is a no-op): `openExternalEditor` is TUI-only, so the bridge no-ops when
" ctx.mode ~= "tui". `pi -p` (print mode) never gets completion. Document as expected.

" GOTCHA (README staleness is S44's job): README.md currently says the nvim plugin is "forthcoming
" (Phase 2)" — STALE (P2 is Complete). The VIMDOC must describe the SHIPPED plugin. Do NOT fix the
" README in this task (it is a separate PRP, S44). Keep the two consistent in CONTENT but edit only
" the vimdoc here.

" NEVER pipe a heredoc into `nvim` stdin (AGENTS.md HARD RULE — it hangs). Write any validation snippet
" to a FILE and run with `+"luafile <path>"` (the Validation Loop below is file-based). Wrap EVERY nvim
" invocation in `timeout`.
```

## Implementation Blueprint

### Data models and structure

There is no runtime data model — the deliverable is a plain-text vimdoc. The "structure" is the
**help-tag namespace**: the set of `*tag*` definitions the file owns. Define EXACTLY these tags
(each appears exactly once; all `pi-editor-` prefixed to stay global-unique):

```vimhelp
*pi-editor.txt*          (line 1 — the file tag; :helptags keys on this)
*pi-editor*              (the top-level topic — :help pi-editor lands here, near the top)
*pi-editor-intro*        (INTRODUCTION)
*pi-editor-requirements* (REQUIREMENTS)
*pi-editor-quickstart*   (QUICKSTART)
*pi-editor-config*       (CONFIGURATION — the setup() + defaults table)
*pi-editor-options*      (the per-option reference; may fold INTO config — see skeleton)
*pi-editor-commands*     (COMMANDS — the built-in commands; NO :UserCommands)
*pi-editor-keymaps*      (KEYMAPS — the 9 buffer-local insert-mode keys)
*pi-editor-autocmds*     (AUTOCMDS — the buffer-local pi-editor augroup)
*pi-editor-completion*   (COMPLETION — pi-faithful behavior)
*pi-editor-filetype*     (FILETYPE pi-prompt)
*pi-editor-env*          (ENVIRONMENT — PI_EDITOR_BRIDGE + NVIM_APPNAME)
*pi-editor-api*          (LUA API — require("pi-editor")/.bridge/.coords fields)
*pi-editor-bridge*       (the bridge module fields; may fold INTO api)
*pi-editor-coords*       (the coords module fields; may fold INTO api)
*pi-editor-checkhealth*  (CHECKHEALTH — :checkhealth pi-editor pointer)
*pi-editor-troubleshooting* (TROUBLESHOOTING / FAQ)
*pi-editor-autosave*     (the autosave behavior; linked from COMPLETION/FAQ)
```

The CONTENTS table (right-aligned `|tag|` links) lists the 13 sections. Every `|tag|` link + every
inline reference MUST resolve to one of the tags above.

### Implementation Tasks (ordered by dependencies)

```yaml
Task 1: CREATE plugin/doc/pi-editor.txt — the vimdoc help file
  - FILE: plugin/doc/pi-editor.txt (the rtp-relative doc/pi-editor.txt; rtp root is plugin/ —
          VERIFIED lua//ftplugin//plugin/ are siblings; doc/ is the fourth sibling).
  - LINE 1: `*pi-editor.txt*<TAB>For Nvim 0.11+.<TAB>Last change: 2025 Jul 20` (the file tag —
            :helptags keys on it; the `<TAB>` alignment matches help-writing).
  - STRUCTURE (copy-ready skeleton in "Implementation Patterns" below):
      Title block (pi-editor.nvim — one-line pitch) + the *pi-editor* top tag.
      CONTENTS table (13 right-aligned |tag| links).
      For each of the 13 sections: a `=`-underlined header carrying its *tag*, then prose + tables
      + `>`/`<` code blocks.
  - CONFIGURATION table (EXACT — mirror init.lua:30-40):
      Option              Default        Description (one line each)
      menu.max_height     12             Max visible rows in the floating completion popup.
      menu.border         "rounded"      nvim_open_win border: none|single|double|rounded|solid|shadow|chars[].
      debounce_ms         20             File/attachment-context (@/# ) debounce; slash/typing = 0 ms (pi-faithful).
      rpc_timeout_ms      2000           RPC staleness window; MUST exceed the bridge fd-abort 1500 (WARN if <=).
      autosave_on_exit    true           Write the pi temp file on VimLeavePre if modified (prevents lost prompt).
      engine              "builtin"      builtin = the shipped menu; blink/cmp = FORTHCOMING (P4).
      env_var             "PI_EDITOR_BRIDGE" Override the bridge-descriptor env var name.
  - KEYMAPS table (EXACT — mirror ftplugin): 9 rows (Tab/S-Tab/C-N/Down/C-P/Up/C-Y/C-E/CR) with the
      behavior + the fall-through note (each falls through to its default when not handled).
  - REQUIREMENTS: Nvim >= 0.11 (coords.lua UTF-16 overload); pi-editor-bridge extension (pi list);
      optional fd (Debian: fdfind) for @file fuzzy.
  - COMPLETION prose: pi-faithful (slash/skill/template/extension-commands; arg completion; @file via fd;
      paths ./ ~ /abs; Tab force-file; accept = pi's applyCompletion). Note the debounce model.
  - ENVIRONMENT: the PI_EDITOR_BRIDGE JSON shape (transport/path/token/pid/cwd/fdAvailable/serverVersion)
      + "echo shows nothing (process-local)" + `:lua print(vim.env.PI_EDITOR_BRIDGE)` + token-safety
      warning + optional NVIM_APPNAME optimization (P4, optional).
  - LUA API: require("pi-editor") fields (setup/config/defaults/bridge/descriptor/activate) +
      require("pi-editor.bridge") fields (version/is_connected/server_info/request/cancel/
      on_notification/on_disconnect) + require("pi-editor.coords") primitives.
  - TROUBLESHOOTING: the 4 modes (dormant / completion-doesn't-appear / @file-empty / lost-prompt) +
      the 3 limitations (/reload/commandsChanged OK; other-extensions-triggers NOT captured; pi -p no-op).
  - FORMAT: ~78-col wrap; balanced > / < code fences; *pi-editor-…* tags defined exactly once.
  - FOLLOW pattern: runtime/doc/faq.txt (CONTENTS + section shape); telescope.txt (a plugin help file);
      help-writing rules (`*tag*`/`|tag|`/`>`/`<`/`'opt'`).
  - DO NOT: invent options/keys; repeat "0.10+"; document blink/cmp source API (P4, not shipped);
      document :PiSubmit (PRD §15 future); edit any source/README (README = S44); pipe a heredoc into nvim.

Task 2: VALIDATE — :helptags + :help resolution (the real gate)
  - RUN: `:helptags plugin/doc` (headless, file-based driver per AGENTS.md). Expect exit 0 + zero
         "Duplicate tag"/E432 warnings. Generates plugin/doc/tags.
  - RUN: `:help pi-editor` (+ a sweep of every section tag). Expect each to open the file + land on
         the section header (assert via `tagfiles()`/`getpos()` in the driver, OR eyeball stdout).
  - SWEEP: assert every `|tag|` in the CONTENTS table + every inline link resolves (no "tag not found").
  - COL-WRAP lint: assert no line exceeds 80 cols (warn-level; help convention is ~78).
  - FENCE lint: assert the count of lone `>` lines == count of column-0 `<` lines (balanced code fences).
  - This is the Level-3 gate. NO `:lua <<HEREDOC` in a -c arg (AGENTS.md — source via :luafile/a file).

Task 3: (DECISION) commit plugin/doc/tags
  - RECOMMENDED: commit the :helptags-generated plugin/doc/tags (lazy.nvim/pack.nvim regenerate it; a
    committed copy is belt-and-suspenders + makes `:help` work pre-first-install for packadd users).
    .gitignore does NOT ignore it (VERIFIED). If the maintainer prefers not to commit generated files,
    skip this — the choice is documented; it is not a correctness gate.
  - This is a NOTE, not a code task. The implementer commits `tags` iff following the recommendation.
```

### Implementation Patterns & Key Details

```vimhelp
" === plugin/doc/pi-editor.txt — copy-ready skeleton (Task 1) ===
" (Skeleton is abbreviated with `…` only where the verbatim content is fully specified above in the
"  CONFIGURATION/KEYMAPS tables — the implementer fills those in from the EXACT source values. Every
"  option/key/autocmd/field value is given verbatim in this PRP; do NOT paraphrase the numbers.)

*pi-editor.txt*	For Nvim 0.11+.	Last change: 2025 Jul 20

          NVIM PORT — pi-editor.nvim
          Bring pi's in-prompt completion into the Neovim instance pi launches as $EDITOR.

          This help file documents the SHIPPED plugin. The companion pi extension
          (pi-editor-bridge) and this nvim plugin are both complete; the optional blink.cmp /
          nvim-cmp engine sources are forthcoming (see |pi-editor-config| `engine`).

          Author:   (repo maintainer)
          License:  MIT
          PRD:      ./PRD.md (the full design)

==============================================================================
CONTENTS                                        *pi-editor* *pi-editor-contents*

  1. Introduction ........................... |pi-editor-intro|
  2. Requirements ........................... |pi-editor-requirements|
  3. Quick start ............................ |pi-editor-quickstart|
  4. Configuration ......................... |pi-editor-config|
  5. Commands .............................. |pi-editor-commands|
  6. Keymaps ............................... |pi-editor-keymaps|
  7. Autocmds / events ..................... |pi-editor-autocmds|
  8. Completion behavior ................... |pi-editor-completion|
  9. Filetype .............................. |pi-editor-filetype|
  10. Environment .......................... |pi-editor-env|
  11. Lua API (for integrators) ............ |pi-editor-api|
  12. Health ............................... |pi-editor-checkhealth|
  13. Troubleshooting / FAQ ............... |pi-editor-troubleshooting|

==============================================================================
1. Introduction                                  *pi-editor-intro*

`pi-editor.nvim` renders pi's in-prompt completion inside the Neovim instance pi
launches as `$EDITOR` — slash commands (`/model`, `/compact`, `/skill:…`), prompt
templates, extension commands, command-argument completion, `@file` mentions, and
filesystem paths — through a dependency-free floating menu.

It is one half of a two-component design:

  • `pi-editor-bridge` — a pi EXTENSION (TypeScript) that captures pi's live
    `AutocompleteProvider` and serves it over a local Unix socket. See
    https://pi.dev/docs/extensions .

  • `pi-editor.nvim` (THIS plugin) — a Neovim (Lua) plugin that activates ONLY
    inside a pi-launched editor session, connects to the bridge, and renders
    completion through Neovim's own UI.

DORMANT BY DESIGN ~
This plugin is INERT in every ordinary Neovim session. It activates only when pi
spawned the editor with the `PI_EDITOR_BRIDGE` environment variable set (see
|pi-editor-env|). If nothing happens when you open nvim normally, that is
expected — see |pi-editor-troubleshooting|.

Because acceptance delegates back to pi's own `applyCompletion` (see
|pi-editor-completion|), insertion behavior (trailing space for files, no space
for directories, quote handling, `/cmd ` for commands) is byte-for-byte identical
to pi's TUI.

==============================================================================
2. Requirements                                  *pi-editor-requirements*

  • Neovim >= 0.11. (NOT 0.10 — the exact-UTF-16 cursor conversion in
    `coords.lua` needs the 3-arg `vim.str_utfindex` overload added in 0.11.
    `:checkhealth pi-editor` enforces this; see |pi-editor-checkhealth|.)
  • The `pi-editor-bridge` pi extension installed and enabled (`pi list` shows
    `pi-editor-bridge`). It writes `PI_EDITOR_BRIDGE` when pi starts an editor.
  • `fd` (OPTIONAL) — enables pi's fuzzy `@file` search. Without it `@file`
    silently returns nothing, but path completion (directory listing) still
    works. Debian/Ubuntu ship it as `fdfind` (`apt-get install fd-find`).

==============================================================================
3. Quick start                                   *pi-editor-quickstart*

Install the bridge extension (pi side): >
    pi install git:github.com/<owner>/pi-nvim-bridge
    pi list      # shows "pi-editor-bridge"
<
Install this plugin (lazy.nvim) — NOTE `lazy = false` so the startup shim sources
BEFORE the VimEnter event that triggers activation: >
    {
      "<owner>/pi-editor.nvim",
      lazy = false,
      config = function() require("pi-editor").setup({}) end,
    }
<
Tell pi to use Neovim as its external editor — any ONE of: >
    export EDITOR=nvim        # or:
    export VISUAL=nvim        # or, in pi settings.json (takes precedence):
    { "externalEditor": "nvim" }
<
Then in pi, press `Ctrl+G` (the `app.editor.external` keybinding) to open the
external editor. Completion appears as you type. Submit by SAVE + QUIT (pi
re-reads the temp file after the editor exits) — see |pi-editor-autosave|.

==============================================================================
4. Configuration                                 *pi-editor-config* *pi-editor-setup*

Call `setup()` once from your config. Options are merged over the shipped
defaults (so you only set what you want to change): >
    require("pi-editor").setup({
      menu      = { max_height = 20, border = "rounded" },
      debounce_ms      = 20,   -- file/attachment-context window
      rpc_timeout_ms   = 2000, -- MUST exceed the bridge fd-abort (1500)
      autosave_on_exit = true,
      engine   = "builtin",    -- "builtin" (shipped) | "blink" | "cmp" (forthcoming)
      env_var  = "PI_EDITOR_BRIDGE",
    })
<
DEFAULTS (mirror `lua/pi-editor/init.lua` `M.defaults`) ~

    menu.max_height      12      Max visible rows in the floating completion popup.
    menu.border          "rounded"  |nvim_open_win| border: "none"|"single"|
                                  "double"|"rounded"|"solid"|"shadow"|string[].
    debounce_ms          20      File/attachment-context (@… / #…) debounce window.
                                  Slash commands and plain typing use 0 ms (pi-faithful).
    rpc_timeout_ms       2000    Ms before a pending RPC is considered stale. MUST
                                  exceed the bridge's fd-abort (1500); a WARN fires
                                  at setup if set <= 1500 (it would cut off @file
                                  searches client-side).
    autosave_on_exit     true    Write the pi temp file on |VimLeavePre| if modified
                                  (prevents the lost-prompt bug; see |pi-editor-autosave|).
    engine               "builtin"  Which completion UI to drive. "builtin" = the
                                  dependency-free floating menu (shipped). "blink" /
                                  "cmp" are FORTHCOMING (Phase 4) — do not set yet.
    env_var              "PI_EDITOR_BRIDGE"  Override the bridge-descriptor env var name.

==============================================================================
5. Commands                                      *pi-editor-commands*

This plugin defines NO `:UserCommand`s. You drive it with built-in Neovim
commands: >

    :help pi-editor                 Open this help file (after :helptags).
    :helptags <rtp>/doc             (Re)generate the help tag index.
    :checkhealth pi-editor          Diagnostics: version / env / socket / fd (|pi-editor-checkhealth|).
    :messages                       Read the one-time "completion unavailable" notify.
    :lua print(vim.env.PI_EDITOR_BRIDGE)  Inspect the process-local bridge descriptor.

<

==============================================================================
6. Keymaps                                       *pi-editor-keymaps*

These are BUFFER-LOCAL, INSERT-mode mappings installed only in `pi-prompt`
buffers (see |pi-editor-filetype|) by `ftplugin/pi-prompt.lua`. They do not leak
into other buffers. Each falls through to its normal insert-mode default when
completion is inactive or signals "not handled" (e.g. `<Tab>` still indents,
`<CR>` still inserts a newline, when the bridge is not connected).

    <Tab>     Trigger or accept the menu (pi-faithful Tab). With the menu open +
              an item selected → accept. With the menu closed → trigger file
              completion (respects pi's `shouldTriggerFileCompletion`) or, on a
              bare `/cmd`, slash completion.
    <S-Tab>   Previous completion item.
    <C-N>     Next completion item.
    <Down>    Next completion item (mirrors <C-N>).
    <C-P>     Previous completion item.
    <Up>      Previous completion item (mirrors <C-P>).
    <C-Y>     Accept if the menu is open; otherwise fall through to |i_CTRL-Y|.
    <C-E>     Dismiss the completion menu.
    <CR>      Accept if the menu is open; OTHERWISE INSERT A NEWLINE. There is
              NO Enter-to-submit in the external editor — the prompt submits on
              SAVE + QUIT, not Enter. See |pi-editor-autosave|.

==============================================================================
7. Autocmds / events                             *pi-editor-autocmds*

The buffer-local `pi-editor` augroup (installed by `ftplugin/pi-prompt.lua`):

  Refresh (fire-and-forget): >
    InsertEnter, TextChangedI, CursorMovedI  →  completion refresh
< Auto-close the menu: >
    InsertLeave, BufLeave                     →  hide menu + cancel pending refresh
< Autosave + bridge teardown (when `autosave_on_exit ~= false`, the default): >
    VimLeavePre, ExitPre                      →  autosave-if-modified, send `bye`,
                                                 close the socket
<
The "cursor moved out of prefix" auto-close is owned pi-faithfully by the
existing refresh→re-fetch→empty→close path (no local prefix detector).

==============================================================================
8. Completion behavior                           *pi-editor-completion*

Completion is produced by pi's LIVE `AutocompleteProvider` (captured by the
bridge extension) — not a reimplementation. So what you get is exactly what the
TUI gets:

  • Slash commands: `/model`, `/compact`, `/skill:<name>` (when skill commands
    are on), plus prompt templates (`.pi/prompts`, …) and registered extension
    commands (`pi.registerCommand(…)`), each with a description + argument hint.
  • Command-argument completion where pi supports it (e.g. `/model <provider/id>`,
    `/login <provider>`).
  • `@file` mention completion: pi's exact fuzzy/`fd` logic (gitignore-aware,
    scored, scoped). Needs `fd` (|pi-editor-requirements|).
  • Path completion: bare paths, `./…`, `~/…`, `/abs/…` — identical to pi.
  • `<Tab>` to force file completion, matching pi's `shouldTriggerFileCompletion`.

DEBOUNCE ~
Pi does not apply a flat debounce. The window is computed per request: slash
commands and plain typing use 0 ms (immediate); `@…`/`#…` attachment context uses
`debounce_ms` (default 20). This mirrors pi's TUI `getAutocompleteDebounceMs`.

ACCEPTANCE ~
When you accept an item, the plugin delegates to pi's `applyCompletion`, which
returns the NEW full buffer lines + the final cursor. The plugin replaces the
buffer + positions the cursor. Insertion rules (trailing space for files, no
space for directories, quote handling, `/cmd ` for commands) are therefore
identical to the TUI — the plugin never reimplements them.

==============================================================================
9. Filetype                                      *pi-editor-filetype*

When activation succeeds (|pi-editor-env| present + valid), the buffer's
filetype is set to `pi-prompt`, which auto-sources `ftplugin/pi-prompt.lua`.
That sets: >

    formatoptions  -= t      (stop insert-time auto-wrap)
    textwidth       = 0
    wrap            (window-local)
    spell  = false   (window-local)

< The buffer is otherwise plain markdown (the temp file is `pi-editor-<ts>.pi.md`).

==============================================================================
10. Environment                                  *pi-editor-env*

The bridge extension writes a single-line JSON descriptor to the process
environment INSIDE pi: >

    PI_EDITOR_BRIDGE = {
      "transport": "unix",
      "path": "/tmp/pi-editor-bridge-<uuid>.sock",
      "token": "<32-byte hex>",
      "pid": 12345,
      "cwd": "/your/project",
      "fdAvailable": true,
      "serverVersion": "0.1.0"
    }

< The child `$EDITOR` pi spawns INHERITS this var; THIS PLUGIN keys activation
on it (|pi-editor-intro| dormant-by-design).

NOTE: `echo $PI_EDITOR_BRIDGE` in your shell shows NOTHING — the variable is
written to `process.env` INSIDE pi and is only visible to the child editor. This
is the #1 install confusion; it is not a bug. Inspect it from inside the
launched Neovim: >
    :lua print(vim.env.PI_EDITOR_BRIDGE)

< SECURITY: the `token` is the real auth boundary (|pi-editor-...|). NEVER paste
the live descriptor — especially `token` — into a bug report.

OPTIONAL — minimal-config startup optimization ~
For faster editor launch you may keep a tiny Neovim config at
`~/.config/pi-editor/` and have the bridge set `NVIM_APPNAME=pi-editor` so the
editor instance loads ONLY `pi-editor.nvim`. This is OPTIONAL (Phase 4); the
plugin works with your full config.

==============================================================================
11. Lua API (for integrators)                    *pi-editor-api*
                                                  *pi-editor-bridge* *pi-editor-coords*

The plugin exposes its modules so optional completion-engine sources (blink/cmp,
forthcoming) and user code can issue RPCs.

`require("pi-editor")` ~
    .setup(opts)    Merge opts over defaults; store as .config. (|pi-editor-config|)
    .config         The resolved config (nil until setup()).
    .defaults       The shipped defaults table (read by :checkhealth + tests).
    .bridge         The bridge module table; nil until the hello handshake succeeds
                    (stays nil in dormant sessions + on handshake failure → completion
                    auto-bails → degrade to a plain buffer).
    .descriptor     The parsed PI_EDITOR_BRIDGE descriptor; nil if dormant.
    .activate()     The VimEnter entry point (called automatically by the startup shim;
                    you do not normally call it).

`require("pi-editor.bridge")` ~
    .version            "0.1.0" (mirrors package.json + the extension BRIDGE_VERSION).
    .server_info        {serverVersion, cwd, fdAvailable}; nil until handshake.
    .is_connected()     true between connect-success and teardown.
    .request(method, params, on_result) -> id|nil
                        Generic JSON-RPC. on_result(err, result) resolved once.
    .cancel(id)         Local supersession cleanup (fires cb("cancelled")).
    .on_notification(method, handler)  handler(params) on a server notification
                        (v1: "commandsChanged").
    .on_disconnect(handler)            handler(reason) when the pipe drops
                        (process death / dropped connection post-handshake).
  (Transport: .connect/.send/.handshake/.close/.on_exit — see the source.)

`require("pi-editor.coords")` ~
    .byte_to_utf16(line, byte_idx)        nvim byte col -> pi UTF-16 col.
    .utf16_to_byte(line, utf16_idx)       pi UTF-16 col -> nvim byte col.
    .nvim_to_pi_coords(lines, row, byte_col)   full (lines, cursorLine, cursorCol) map.
    .pi_to_nvim_coords(lines, cursorLine, cursorCol)  inverse.

==============================================================================
12. Health                                       *pi-editor-checkhealth*

Run >
    :checkhealth pi-editor
< for a never-throwing diagnostic with four sections: the plugin version + a
Neovim >= 0.11 gate; the bridge ENVIRONMENT (dormant vs active); the bridge
CONNECTION (`is_connected()` + the handshake result + the socket file); and the
external `fd` tool (optional — WARN, not error). A missing `PI_EDITOR_BRIDGE` is
reported as INFO "dormant" (the expected normal-session state), not an error.

==============================================================================
13. Troubleshooting / FAQ                        *pi-editor-troubleshooting*

Q: "I installed it and nothing happens in nvim." ~
A: EXPECTED. The plugin is dormant unless pi launched the editor. Run
   `:checkhealth pi-editor` (it will say "dormant" if the env var is unset).

Q: "Completion doesn't appear when pi opens nvim." ~
A: Check, in order: (1) the bridge extension loaded — `pi list` shows
   `pi-editor-bridge`; (2) EDITOR/VISUAL/`externalEditor` is `nvim`; (3) this
   plugin is installed with `lazy = false`; (4) read `:messages` for the one-time
   "completion unavailable" notify (connect refused / bad token / timeout).

Q: "`@file` finds nothing." ~
A: Install `fd` (Debian: `fdfind`). Without it `@file` is empty, but path
   completion (directory listing) still works. The bridge may still have `fd`
   in pi's bin dir even if it is not on your `$PATH` — see |pi-editor-checkhealth|.

Q: "I typed, then `:q`, and lost my prompt." ~
A: pi reads the temp file only after the editor exits with status 0. The plugin
   AUTOSAVES on |VimLeavePre| when modified (`autosave_on_exit`, default true —
   see |pi-editor-autosave|). To be safe, `:w` before `:q`, or quit with `:x`/`ZZ`.

Q: "I ran `/reload` while the editor was open." ~
A: The bridge re-captures the provider + re-advertises the descriptor; your open
   connection stays valid, and a `commandsChanged` notification refreshes it.

Q: "Another extension's custom trigger (e.g. `#issues`) doesn't complete." ~
A: KNOWN LIMITATION. The bridge captures the provider at its own registration
   time, so wrappers registered AFTER it do not appear. The BASE provider —
   slash commands, `/skill:`, templates, paths — is always captured.

Q: "Nothing happens in non-interactive mode (`pi -p`)." ~
A: Correct. `openExternalEditor` is TUI-only, so the bridge no-ops outside TUI.

Q: "I set `rpc_timeout_ms` to 1000 and got a warning." ~
A: It must EXCEED the bridge's fd-abort (1500). Setting it lower would cut off
   `@file` searches client-side. Leave it at 2000 (default).

==============================================================================
AUTOSAVE                                         *pi-editor-autosave*

Pi re-reads the temp file ONLY after the editor exits with status 0, trimming
one trailing newline. There is no live sync. So if you type and quit without
saving, you silently lose your prompt. The plugin prevents this by autosaving
the buffer on |VimLeavePre|/|ExitPre| when `autosave_on_exit` is true (the
default) — a plain UTF-8 + `\n` write that matches pi's wire format and does
NOT run user BufWritePre/Post autocmds (no formatter risk on prompt text). It
also sends a best-effort `bye` RPC + closes the socket on the same events.

 vim:tw=78:ts=8:noet:ft=help:norl:

" KEY DETAIL (line 1): the file MUST start with `*pi-editor.txt*` (tab-separated from the "For Nvim"
" line). :helptags skips a doc file whose first line is not a `*file.txt*` tag.

" KEY DETAIL (tag uniqueness): every `*tag*` is defined ONCE and is `pi-editor-` prefixed (no global
" clashes). The CONTENTS right-aligned links + inline `|tag|` all resolve to one of them.

" KEY DETAIL (code fences): each `>` is on its OWN line, AFTER the intro text; each `<` is at column 0.
" Count them — they must balance.

" KEY DETAIL (modeline): the trailing `vim:tw=78:...:ft=help:norl:` line sets the help filetype when the
" file is opened directly (so `>`/`<` highlight correctly). Optional but conventional.

" KEY DETAIL (no :UserCommands): do NOT invent a `:PiEditor…` or `:PiSubmit` command. `:PiSubmit` is a
" PRD §15 FUTURE enhancement; it is NOT shipped. Document built-in commands only.
```

### Integration Points

```yaml
NEOVIM HELP LOADER: discovers plugin/doc/pi-editor.txt automatically (it is doc/*.txt on rtp). The user
  (or their plugin manager) runs `:helptags <rtp>/doc` ONCE to build plugin/doc/tags; thereafter
  `:help pi-editor` (+ every |tag|) resolves. lazy.nvim / vim.pack / packer all run :helptags on install.
AUTOCMDS / EVENTS: NONE new. The vimdoc is pure text; it registers no autocmds.
STATE / SOURCE: READ-ONLY. The vimdoc DESCRIBES the shipped init.lua/ftplugin/bridge/coords/health; it
  changes nothing. If it reveals a code/doc mismatch, the fix is a SEPARATE code task (out of scope here).
CONFIG: NONE new. The CONFIGURATION section documents the EXISTING M.defaults verbatim.
EXTENSION (TS): NONE. The vimdoc is client-side docs; it references the descriptor shape read-only.
README (markdown): NOT edited in this task (S44's job). The vimdoc is kept CONSISTENT in content with
  the README where they overlap, but only the vimdoc is touched here.
GITTIGNORE: doc/tags is NOT ignored (VERIFIED). The recommendation is to COMMIT doc/tags; this is a
  note, not a correctness gate.
```

## Validation Loop

> **AGENTS.md HARD RULE:** NEVER pipe a heredoc into `nvim` stdin (it hangs). Write every validation
> snippet to a FILE and run with `+"luafile <path>"`. Wrap EVERY nvim invocation in `timeout`.

### Level 1: Existence + line-1 tag (immediate)

```bash
cd plugin
# The file exists + line 1 is the *pi-editor.txt* file tag (the :helptags key).
test -f doc/pi-editor.txt && head -1 doc/pi-editor.txt | grep -q '^\*pi-editor\.txt\*' \
  && echo "L1 ok" || { echo "L1 FAIL"; exit 1; }
# Column/fence sanity: no line over 80 cols (help convention ~78); balanced lone-`>` vs col-0 `<`.
awk 'length>80{c++} END{print "lines>80:", c+0}' doc/pi-editor.txt
opens=$(grep -c '^>$' doc/pi-editor.txt); closes=$(grep -c '^<$' doc/pi-editor.txt)
echo "fence opens=$opens closes=$closes"; [ "$opens" = "$closes" ] && echo "fences balanced" || echo "FENCE MISMATCH"
# Expected: L1 ok; lines>80: 0 (or only a few intentional wide table rows — minimize); fences balanced.
```

### Level 2: :helptags (the real gate — no duplicate/malformed tags)

```bash
cd plugin
# Write the driver to a FILE (AGENTS.md). :helptags must exit 0 with zero warnings.
cat > /tmp/helptags_check.lua <<'LUA'
vim.opt.runtimepath:append(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h"))
local out = vim.fn.execute("helptags doc")
io.stdout:write("helptags output:\n" .. tostring(out) .. "\n")
local tagsfile = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h") .. "/doc/tags"
local f = io.open(tagsfile, "r")
if not f then io.stderr:write("doc/tags NOT generated\n"); vim.cmd("cquit 1") end
local n = 0; for _ in f:lines() do n = n + 1 end; f:close()
io.stdout:write(("doc/tags has %d entries\n"):format(n))
LUA
timeout 60 nvim --headless --clean -u NORC +"luafile /tmp/helptags_check.lua" +qa
echo "exit=$?"
grep -i 'duplicate\|E432\|error' /tmp/helptags.out 2>/dev/null || true
rm -f /tmp/helptags_check.lua
# Expected: exit=0; "doc/tags has <N> entries" (N >= 13 sections + the *pi-editor*/*pi-editor.txt* tags);
#           NO "Duplicate tag"/"E432"/"error" in the helptags output.
```

### Level 3: :help resolution (every tag jumps to its section)

```bash
cd plugin
# Verify :help pi-editor opens the file + a sweep of section tags all resolve.
cat > /tmp/help_resolve.lua <<'LUA'
vim.opt.runtimepath:append(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h"))
vim.cmd("helptags doc")
local tags = {
  "pi-editor", "pi-editor-intro", "pi-editor-requirements", "pi-editor-quickstart",
  "pi-editor-config", "pi-editor-commands", "pi-editor-keymaps", "pi-editor-autocmds",
  "pi-editor-completion", "pi-editor-filetype", "pi-editor-env", "pi-editor-api",
  "pi-editor-checkhealth", "pi-editor-troubleshooting", "pi-editor-autosave",
}
local missing = {}
for _, t in ipairs(tags) do
  local found = vim.fn.taglist("^" .. t .. "$")
  if #found == 0 then missing[#missing+1] = t end
end
if #missing > 0 then
  io.stderr:write("UNRESOLVED tags: " .. table.concat(missing, ", ") .. "\n")
  vim.cmd("cquit 1")
end
io.stdout:write(("all %d tags resolve\n"):format(#tags))
-- Spot-open the top topic to confirm it lands on the file (not an E426 "tag not found").
vim.cmd("help pi-editor")
io.stdout:write("buf name: " .. vim.api.nvim_buf_get_name(0) .. "\n")
LUA
timeout 60 nvim --headless --clean -u NORC +"luafile /tmp/help_resolve.lua" +qa
echo "exit=$?"
rm -f /tmp/help_resolve.lua
# Expected: exit=0; "all 15 tags resolve"; buf name ends in doc/pi-editor.txt (no E426).
```

### Level 4: Content accuracy (doc-SYNC spot-checks against source)

```bash
cd plugin
# The CONFIGURATION defaults + the 9 KEYMAPS must match the shipped code (grep the help file).
echo "--- config defaults present ---"
for v in "max_height" '"rounded"' "debounce_ms" "rpc_timeout_ms" "autosave_on_exit" '"builtin"' "PI_EDITOR_BRIDGE"; do
  grep -q "$v" doc/pi-editor.txt && echo "  ok: $v" || echo "  MISSING: $v"
done
echo "--- 9 keymaps present ---"
for k in '<Tab>' '<S-Tab>' '<C-N>' '<Down>' '<C-P>' '<Up>' '<C-Y>' '<C-E>' '<CR>'; do
  grep -qF "$k" doc/pi-editor.txt && echo "  ok: $k" || echo "  MISSING: $k"
done
echo "--- 0.11 floor (NOT 0.10) ---"
grep -q '0\.11' doc/pi-editor.txt && echo "  ok: mentions 0.11" || echo "  MISSING 0.11"
echo "--- no stale '0.10+' requirement ---"
grep -qi 'requires nvim 0\.10\|nvim >= 0\.10' doc/pi-editor.txt && echo "  WARN: still says 0.10" || echo "  ok: no 0.10 requirement"
echo "--- troubleshooting modes present ---"
for kw in dormant '@file' autosave 'known limitation' 'pi -p'; do
  grep -qi "$kw" doc/pi-editor.txt && echo "  ok: $kw" || echo "  MISSING: $kw"
done
# Expected: every grep "ok"; zero MISSING. If any MISSING, the doc drifts from the code — fix it.
```

## Final Validation Checklist

### Technical Validation
- [ ] Level 1: file exists; line 1 = `*pi-editor.txt*`; no line >80 cols; fences balanced (`>`==`<`).
- [ ] Level 2: `:helptags plugin/doc` exits 0; doc/tags generated; NO duplicate/E432/error warnings.
- [ ] Level 3: `:help pi-editor` + all 15 tags resolve (no E426 "tag not found").
- [ ] Level 4: all config defaults + 9 keymaps + "0.11" + troubleshooting keywords present in the file.
- [ ] No edits outside `plugin/doc/` (and optionally the generated `plugin/doc/tags`).

### Feature Validation
- [ ] All 13 sections present with their `*pi-editor-…*` tags + a CONTENTS table linking them.
- [ ] CONFIGURATION defaults byte-faithful to `init.lua:30-40` (7 fields).
- [ ] KEYMAPS lists all 9 buffer-local keys + fall-through semantics; `<CR>` = accept-or-newline (NOT submit).
- [ ] REQUIREMENTS states Nvim >= 0.11 (not 0.10), the bridge extension, optional fd/fdfind.
- [ ] COMPLETION documents pi-faithful behavior + debounce model + accept-via-applyCompletion.
- [ ] ENVIRONMENT documents the descriptor shape + "echo shows nothing" + token-safety + NVIM_APPNAME (optional).
- [ ] LUA API lists `require("pi-editor")` + `.bridge` + `.coords` fields.
- [ ] TROUBLESHOOTING covers the 4 failure modes + 3 limitations (other-extensions-trigger, pi -p, /reload OK).

### Code Quality / Conventions Validation
- [ ] Line 1 is the `*pi-editor.txt*` file tag (tab-separated "For Nvim …").
- [ ] Every `*tag*` defined exactly once; all `pi-editor-` prefixed (no global clashes).
- [ ] Every code block has a matching `>`/`<` pair (`<` at column 0).
- [ ] File wraps ~78 cols; trailing `vim:tw=78:…:ft=help:norl:` modeline.
- [ ] No invented options/keys/commands; no "0.10+"; blink/cmp + :PiSubmit marked forthcoming/future only.

### Documentation
- [ ] The vimdoc is the single `:help`-discoverable end-user reference for this plugin.
- [ ] Consistent (in content) with README.md where they overlap — but README NOT edited here (S44's job).
- [ ] If a code/doc mismatch surfaced during this task, it is FLAGGED in the PRP Gotchas (the fix is a
      separate code task — this PRP only documents shipped behavior).

---

## Anti-Patterns to Avoid

- ❌ Don't omit the line-1 `*pi-editor.txt*` file tag — `:helptags` skips a doc file whose first line isn't a `*file.txt*` tag.
- ❌ Don't use bare tag names (`config`, `keymaps`, `commands`) — help tags are GLOBAL across all rtp doc files; prefix everything `pi-editor-…` to avoid collisions.
- ❌ Don't define a `*tag*` more than once — `:helptags` errors on a duplicate tag within the file.
- ❌ Don't leave a code block's `<` indented or missing — an unbalanced `>`/`<` swallows the rest of the file as "code". Every `>` needs a column-0 `<`.
- ❌ Don't invent options/keys/commands — this is a doc-SYNC (Mode B); the code is Complete. Mirror `init.lua:30-40` + the 9 ftplugin keys EXACTLY.
- ❌ Don't write "requires Neovim 0.10+" — the floor is **0.11** (coords.lua GOTCHA 9; health.lua `min_nvim`). PRD §10.1's "0.10+" text is superseded.
- ❌ Don't claim `engine = "blink"/"cmp"` works today — only `"builtin"` ships (the floating menu). blink/cmp sources are P4-planned; mark them forthcoming.
- ❌ Don't document `:PiSubmit` as a real command — it is a PRD §15 FUTURE enhancement, NOT shipped. Document built-in commands only (this plugin defines NO `:UserCommand`s).
- ❌ Don't document `<CR>` as "submit the prompt" — there is NO Enter-to-submit in the external editor (pi re-reads the temp file only after the editor EXITS). `<CR>` accepts-if-menu-open else inserts a NEWLINE.
- ❌ Don't contradict the dormant-by-design model — "nothing happens in my normal nvim" is EXPECTED. Say it first + loudest in the FAQ.
- ❌ Don't tell users to `echo $PI_EDITOR_BRIDGE` to verify install — it shows nothing (process-local). Tell them `:lua print(vim.env.PI_EDITOR_BRIDGE)` from inside the launched editor, or `:checkhealth pi-editor`.
- ❌ Don't edit README.md, any source file, or any test in this task — the README fix is S44 (a separate PRP); the vimdoc only DESCRIBES shipped code. A code/doc mismatch is a SEPARATE code task.
- ❌ Don't paste or document the live `token` value — it is the auth boundary (PRD §12). Document the descriptor SHAPE, with a "never paste the token" warning.
- ❌ Don't pipe a heredoc into `nvim` stdin (AGENTS.md HARD RULE — it hangs). Write validation snippets to a file; run with `+"luafile <path>"`. Wrap every nvim call in `timeout`.

---

## Confidence Score: 9/10

A clean CREATE-only docs task (1 new text file + a `:helptags`-generated index). The entire content is
DETERMINED by the shipped source, which was verified line-for-line in this PRP's research (the 7 config
defaults, the 9 keymaps, the autocmds, the 0.11 floor, the env-var shape, the Lua API fields, and the 4+3
troubleshooting items are all given verbatim). The only judgment calls are section ordering + wording,
both of which the copy-ready skeleton resolves. Risk is limited to vimdoc syntax mistakes (`>`/`<`
balance, tag uniqueness) — all caught by the Level 2/3 gates. No source/test/README changes.