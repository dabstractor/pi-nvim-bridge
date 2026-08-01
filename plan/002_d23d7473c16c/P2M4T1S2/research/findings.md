# Research notes — P2.M4.T1.S2 (doc/pi-bridge.txt cross-link to pi-bridge-shell.txt)

## Task
Update the MAIN plugin vimdoc `doc/pi-bridge.txt` so it cross-links to the new
shell-completion vimdoc `doc/pi-bridge-shell.txt` (produced by P2.M3.T6.S4). Pure
documentation: one file edited, no code, no tests.

## Contract (verbatim from item_description)
- (a) Configuration section → add pointer: "For shell completion of !/!! commands,
      see |pi-bridge-shell|."
- (b) Features/behavior section → add to the keymaps/behavior table:
      "!/!! prefix — shell command completion (see |pi-bridge-shell|)".
- (c) Ensure the `pi-bridge-shell` tag is in doc/tags → OWNED by P2.M3.T6.S4
      (this task only REFERENCES it; it does not create it).

## Codebase findings (verified)
- `doc/pi-bridge.txt` is 380 lines, single vimdoc. `wc -l` = 380.
- It is SILENT on shell completion. Only hit for "shell" is L258
  `NOTE: \`echo $PI_NVIM_BRIDGE\` in your shell shows NOTHING` (unrelated).
- `grep -c pi-bridge-shell doc/tags` = 0  → tag does not exist yet (dependency).
- Cross-link convention in the file: `|tagname|` for inline refs (used ~25×:
  |pi-bridge-autosave| x5, |pi-bridge-checkhealth| x4, |pi-bridge-env| x3, …).
- Tag DEFINITION syntax: `*tagname*` (see every section header, e.g. L195
  `8. Completion behavior  *pi-bridge-completion*`). This task must NOT define
  `*pi-bridge-shell*` — that definition lives in pi-bridge-shell.txt (P2.M3.T6.S4).
- Modeline (LAST line, must stay last): ` vim:tw=78:ts=8:noet:ft=help:norl:`.
- Header line 1: `*pi-bridge.txt*  For Nvim 0.11+.  Last change: 2025 Jul 20`
  → bump "Last change" on edit (vimdoc hygiene; loosely gated).

## Section anchors (exact line numbers, for placement)
- L98   `4. Configuration  *pi-bridge-config*`           ← edit site (a)
- L116  `DEFAULTS (mirror … M.defaults) ~`               ← config defaults list
- L133-135 closing paragraph: "The seven keys above are the full public
         configuration surface … `require(\"pi-bridge\").config`."
- L137  `===…` section divider                            ← insert (a) between L135 and L137
- L195  `8. Completion behavior  *pi-bridge-completion*`  ← edit site (b)
- L204-211 bulleted "what completes" list (slash/cmd-arg/@file/path/<Tab>)
- L211  last bullet `• \`<Tab>\` to force file completion …`  ← insert (b) after L211
- L213  `DEBOUNCE ~`                                       ← do not disturb
- L9-26 CONTENTS TOC                                       ← DO NOT add a shell entry
         (shell has its OWN help file + own TOC; a TOC line here would be wrong)

## vimdoc / help-tag mechanics (cited)
- Authoritative: `:help help-writing`, `:help write-help`, `:help helptags`.
  Neovim dev docs: https://neovim.io/doc/user/dev/  (cross-reference guidance).
- `*tag*` defines; `|tag|` references. Tags from ALL `doc/*.txt` on &runtimepath
  are merged into `doc/tags` by `:helptags <dir>` (auto on many plugin managers).
- A `|tag|` whose target is not yet defined yields "E426: tag not found" ONLY when
  FOLLOWED (Ctrl-] / `:help tag`). There is NO write-time warning (neovim/neovim#329).
  ⇒ `|pi-bridge-shell|` is a safe forward reference; it resolves once P2.M3.T6.S4's
  pi-bridge-shell.txt + tag are present. Both ship in the same Mode B changeset sweep.

## Sibling boundaries (do NOT cross — they own these)
- README.md               → P2.M4.T1.S1 (parallel PRP, README shell blurb + diagram).
- extension/README.md     → P2.M4.T1.S3 (descriptor fields + PI_NVIM_SHELL).
- doc/pi-bridge-shell.txt → P2.M3.T6.S4 (the NEW shell vimdoc + its `*pi-bridge-shell*`
                            tag definition + the doc/tags entry).
- doc/tags                → generated; owned by P2.M3.T6.S4 (append on helptags).

## Decision: placement of (b)
Contract says "keymaps/behavior table". The "behavior table" is the bulleted
what-completes list in §8 Completion behavior (L204-211), NOT §6 Keymaps (which is
insert-mode MAPPINGS like <Tab>/<CR>, not "what completes"). ⇒ bullet goes in §8.

## Validation approach (no compiler/tests — deterministic grep gates)
- (a) grep `pi-bridge-shell` in §4 Configuration region (L98-137).
- (b) grep `!/!!` + `pi-bridge-shell` in §8 region (L195-226).
- (c) precondition: `grep -c pi-bridge-shell doc/tags` will be ≥1 once P2.M3.T6.S4
      ships (NOT this task's edit; gated as a sweep-level precondition).
- scope: `git diff --name-only` == doc/pi-bridge.txt only.
- syntax: exactly 2 `|pi-bridge-shell|` occurrences (§4 + §8); ZERO `*pi-bridge-shell*`
  definitions (must not duplicate the tag here).