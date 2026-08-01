---
name: "P2.M4.T1.S2 — doc/pi-bridge.txt cross-link to pi-bridge-shell.txt + !/!! completion behavior"
why_this_prp: |
  Mode B changeset-level documentation task. The shell-completion feature (PRD
  §17) landed across P2.M1–P2.M3, and a brand-new shell vimdoc
  (`doc/pi-bridge-shell.txt`) is being produced by the sibling task P2.M3.T6.S4.
  The MAIN plugin vimdoc, `doc/pi-bridge.txt` (380 lines, 19KB), still documents
  ONLY the pi-faithful completion surface (slash commands, prompt templates,
  extension commands, command-arg completion, `@file`, paths) and makes ZERO
  mention of `!`/`!!` shell completion or the new help file. A user reading
  `:help pi-bridge` therefore has no path to discover `:help pi-bridge-shell`.
  This task adds two precise cross-links (a config-section pointer + a
  behavior-list bullet) so navigation works end-to-end. Pure documentation: ONE
  file edited (`doc/pi-bridge.txt`), no code, no tests, no schema change, no
  mocking. It does NOT create `doc/pi-bridge-shell.txt` or its help tag
  (P2.M3.T6.S4 owns both), and it does NOT touch README.md (P2.M4.T1.S1) or
  extension/README.md (P2.M4.T1.S3).
---

## Goal

**Feature Goal**: `doc/pi-bridge.txt` cross-links to the new
`doc/pi-bridge-shell.txt` in two places: (a) a pointer in the **Configuration**
section and (b) a `!/!!` bullet in the **Completion behavior** section. A user
reading `:help pi-bridge` can navigate to `:help pi-bridge-shell` and learn that
`!`/`!!` lines complete against their real shell.

**Deliverable**: Edits to **exactly one file** — `doc/pi-bridge.txt`. No other
file is created or modified. Specifically two content edits (plus an optional
`Last change:` date bump):
1. **§4 Configuration** (after L135, before the L137 divider) — a NOTE paragraph
   whose core sentence is verbatim: *“For shell completion of `!/!!` commands,
   see |pi-bridge-shell|.”*
2. **§8 Completion behavior** (after the `<Tab>` bullet at L211) — a new bullet
   in the what-completes list, core wording verbatim: *“`!/!!` prefix — shell
   command completion (see |pi-bridge-shell|).”*
3. **(optional hygiene)** line 1 `Last change: 2025 Jul 20` → current edit date.

**Success Definition**: `grep` proves `|pi-bridge-shell|` appears exactly twice
in `doc/pi-bridge.txt` (once in §4, once in §8), the tag `pi-bridge-shell` is
resolvable to the new file (once P2.M3.T6.S4 ships — same changeset sweep), no
`*pi-bridge-shell*` tag *definition* was accidentally added to this file (that
belongs in pi-bridge-shell.txt), and `git diff --name-only` shows ONLY
`doc/pi-bridge.txt`.

## User Persona (if applicable)

**Target User**: a pi user who opens `:help pi-bridge` (the main plugin help)
to learn what the plugin does / how to configure it.

**Use Case**: reading the main help → sees the `!/!!` bullet in the completion
behavior list → follows `|pi-bridge-shell|` (Ctrl-] or click) → lands on the
dedicated shell-completion help with the full `shell = {}` option set.

**User Journey**: `:help pi-bridge-completion` (or `-config`) → notices the
`!/!!` line / the shell pointer → `:help pi-bridge-shell` → configures
`shell = { prefer = "pi", … }`.

**Pain Points Addressed**: today the main help is silent on shell completion, so
the feature is invisible from the primary help entry point; a fish/zsh/bash user
has no hint that `!`/`!!` completion exists or where to tune it.

## Why

- **The feature shipped; the main help drifted.** §17 (shell completion) landed
  across P2.M1–P2.M3, and P2.M3.T6.S4 adds the dedicated `pi-bridge-shell.txt`.
  But `pi-bridge.txt` — the file `:help pi-bridge` opens — still describes only
  the pi-faithful surface. This is the residual discoverability debt.
- **This IS the Mode B cross-link update** (contract point 6: “This IS the Mode B
  cross-link update”). No other subtask adds the link from the main help.
- **Low-risk, high-discoverability.** Two additive lines in a vimdoc. Cannot
  regress the extension, the plugin, or any test. The only invariant to protect
  is the sibling-task boundaries (do not create the tag, do not edit the other
  doc files).

## What

Three precisely-scoped edits to `doc/pi-bridge.txt` (the third optional):

### (a) §4 Configuration — add the shell pointer (CORE)
After the closing paragraph *“The seven keys above are the full public
configuration surface … `require(\"pi-bridge\").config`.\"* (ends L135) and
before the `===` section divider (L137), insert a NOTE paragraph. The CORE
sentence is contract-verbatim:

> For shell completion of `!/!!` commands, see |pi-bridge-shell|.

Copy-paste-ready block (the final sentence above is verbatim; the two lead
sentences are window-dressing in the file's existing NOTE voice — see the
`NOTE:` blocks at L258, L246):

```
NOTE ~
This plugin also completes `!/!!` shell ("bash-mode") lines against your real
shell — a separate subsystem with its own `shell = {}` options that does NOT use
the bridge socket. For shell completion of `!/!!` commands, see |pi-bridge-shell|.
```

The sentence *“For shell completion of `!/!!` commands, see |pi-bridge-shell|.”*
is **verbatim per contract**; the surrounding two sentences are window-dressing
in the file’s existing NOTE voice (see `NOTE:` blocks at L258, L246).

### (b) §8 Completion behavior — add the `!/!!` bullet (CORE)
Append a bullet to the what-completes list (the list currently ending at L211
with the `<Tab>` bullet). CORE wording contract-verbatim:

> `!/!!` prefix — shell command completion (see |pi-bridge-shell|)

Suggested bullet (keeps the contract lead phrase; the trailing clauses match how
every other bullet explains its mechanism + caveat — e.g. the `@file` bullet
notes its `fd` dependency, the path bullet notes “identical to pi”):

```
  • `!/!!` prefix — shell command completion (see |pi-bridge-shell|): a
    leading `!` (or `!!`) routes the line to a separate shell-completion
    daemon driving your real shell (fish/zsh/bash). This path does NOT use
    the bridge socket.
```

### (c) doc/tags — DO NOT EDIT (dependency on P2.M3.T6.S4)
The `pi-bridge-shell` tag is **created by P2.M3.T6.S4** (it adds
`doc/pi-bridge-shell.txt`, which contains the `*pi-bridge-shell*` tag
definition, and regenerates/appends `doc/tags` via `:helptags`). This task only
REFERENCES the tag (`|pi-bridge-shell|`). **Do not** manually append
`pi-bridge-shell` to `doc/tags` and **do not** add a `*pi-bridge-shell*` line to
`pi-bridge.txt` — both would collide with P2.M3.T6.S4 and create a duplicate
tag (vim warns on duplicate tags). The reference is a safe forward reference
(see vimdoc mechanics below): it resolves the moment the sibling ships, and both
ship in the same Mode B changeset sweep.

### (optional) Line-1 `Last change:` date bump
Line 1 reads `*pi-bridge.txt*\tFor Nvim 0.11+.\tLast change: 2025 Jul 20`. As
vimdoc hygiene, bump `Last change:` to the edit date (the changeset is dated
**2025 Jul 31** per sibling PRP P2.M4.T1.S1 — use that for consistency). This is
optional; if you are unsure of the canonical date, leave it unchanged rather
than guess. Gate = “date is no longer literally `2025 Jul 20`” OR unchanged
(accepted).

### Success Criteria

- [ ] `|pi-bridge-shell|` appears **exactly twice** in `doc/pi-bridge.txt`
      (once in §4 Configuration, once in §8 Completion behavior).
- [ ] The contract-verbatim core sentence appears in §4:
      *“For shell completion of `!/!!` commands, see |pi-bridge-shell|.”*
- [ ] The contract-verbatim core bullet lead appears in §8:
      *“`!/!!` prefix — shell command completion (see |pi-bridge-shell|)”*.
- [ ] NO `*pi-bridge-shell*` tag **definition** was added to `doc/pi-bridge.txt`
      (only references `|pi-bridge-shell|`).
- [ ] `doc/tags`, `doc/pi-bridge-shell.txt`, `README.md`,
      `extension/README.md`, and every `.lua` file are **untouched**
      (`git diff --name-only` shows ONLY `doc/pi-bridge.txt`).

## All Needed Context

### Context Completeness Check

_Pass_: an implementer who knows nothing about this repo gets (a) the full
`doc/pi-bridge.txt` (380 lines — the two edit sites are quoted verbatim below
with exact line numbers), (b) the exact contract wording for both edits, (c) the
vimdoc cross-link/tag mechanics with authoritative citations, and (d) a precise
sibling-boundary map so they do not collide with P2.M3.T6.S4 / P2.M4.T1.S1 /
P2.M4.T1.S3. No external reading is required to implement; the citations are for
confidence only.

### Documentation & References

```yaml
# MUST READ #1 — the file being edited (the SOLE edit target)
- file: doc/pi-bridge.txt
  why: the only file touched; §4 (L98) and §8 (L195) are the two edit sites.
  section: "§4 Configuration (L98-137) for edit (a); §8 Completion behavior
            (L195-226) for edit (b); line-1 header for the optional date bump."
  critical: |
    The file is a single vimdoc; its LAST line is the modeline
    ` vim:tw=78:ts=8:noet:ft=help:norl:` — do NOT move, delete, or add anything
    after it. The CONTENTS TOC (L9-26) must NOT get a shell entry: shell
    completion has its OWN help file with its OWN TOC (P2.M3.T6.S4); a TOC line
    here would be wrong/duplicative. Cross-link syntax: `|tag|` to reference,
    `*tag*` to DEFINE — this task ONLY references `|pi-bridge-shell|`.

# MUST READ #2 — the contract source (PRD §17, the shell feature)
- docfile: PRD.md
  why: §17.7/§17.9/§17.11 describe the !/!! routing, the visual cue, and the
        `shell = {}` config the cross-link points at. Confirms the tag NAME is
        consistently `pi-bridge-shell` (`:help pi-bridge-shell`).
  section: "h3.36 (§17.7 routing), h3.38 (§17.9 trigger/UX), h3.40 (§17.11 config)"
  critical: |
    The feature does NOT use the bridge socket (§17.11 last line: "`rpc_timeout_ms`
    … is unaffected — shell completion does not use the bridge socket"). Both
    edits should carry that one-liner so a reader isn't misled into thinking
    `rpc_timeout_ms` governs shell completion. Tag name is `pi-bridge-shell`
    (not `pi-bridge-shell-completion`).

# REFERENCE #3 — vimdoc help-tag / cross-link mechanics (cited, confidence only)
- url: https://neovim.io/doc/user/dev/
  why: Neovim dev docs — cross-reference + help-writing conventions.
  critical: |
    `*tag*` defines a tag; `|tag|` creates a cross-reference. Tags from ALL
    `doc/*.txt` on &runtimepath are merged into `doc/tags` by `:helptags <dir>`.
    A `|tag|` whose target is not yet defined yields "E426: tag not found" ONLY
    when FOLLOWED (Ctrl-] / `:help tag`) — there is NO write-time warning
    (neovim/neovim#329). ⇒ `|pi-bridge-shell|` is a safe forward reference; it
    resolves once P2.M3.T6.S4's pi-bridge-shell.txt + tag exist.
  also: ":help help-writing, :help write-help, :help helptags (run inside nvim)."

# RELATED — sibling tasks in the same changeset sweep (boundaries; do NOT cross)
- docfile: plan/002_d23d7473c16c/P2M3T6S4/PRP.md
  why: CREATES doc/pi-bridge-shell.txt + its `*pi-bridge-shell*` tag + the
        doc/tags entry. This task CONSUMES that tag via `|pi-bridge-shell|`.
        (If the PRP is not yet written — it is Planned — treat its contract as
        fixed: it will define `*pi-bridge-shell*` inside doc/pi-bridge-shell.txt.)
- file: doc/tags
  why: generated artifact; OWNED by P2.M3.T6.S4. Do NOT edit (would collide).
- file: README.md
  why: OWNED by P2.M4.T1.S1 (parallel PRP). Do NOT edit.
- file: extension/README.md
  why: OWNED by P2.M4.T1.S3. Do NOT edit.
```

### Current doc/pi-bridge.txt structure map (verified)

```bash
# Section headers + key line numbers (run: grep -nE '^[0-9]+\. ' doc/pi-bridge.txt)
L1   *pi-bridge.txt*   For Nvim 0.11+.   Last change: 2025 Jul 20   ← optional date bump
L9-26 CONTENTS TOC                                      ← DO NOT add a shell entry
L98  4. Configuration            *pi-bridge-config*     ← edit site (a)
L116   DEFAULTS … ~                                     ← config defaults list
L133-135 "The seven keys above are the full public
          configuration surface … require(\"pi-bridge\").config"  ← insert (a) AFTER this
L137   ===… (section divider)                           ← (a) goes between L135 and L137
L195 8. Completion behavior     *pi-bridge-completion*  ← edit site (b)
L204-211 bulleted what-completes list (slash/cmd-arg/@file/path/<Tab>)
L211   • `<Tab>` to force file completion …             ← insert (b) AFTER this bullet
L213   DEBOUNCE ~                                        ← do not disturb
L258  NOTE: `echo $PI_NVIM_BRIDGE` in your shell …       ← unrelated "shell" hit
LAST ` vim:tw=78:ts=8:noet:ft=help:norl:`                ← modeline, must stay LAST
```

### The two edit sites (exact current text)

**Edit site (a) — §4 Configuration closing paragraph + divider (L133-137):**
```
The seven keys above are the full public configuration surface. `setup()`
returns the resolved config and also stores it as
`require("pi-bridge").config`.

==============================================================================
5. Commands                                      *pi-bridge-commands*
```
⇒ INSERT the NOTE paragraph (a) between the `…config.` line and the `===` divider.

**Edit site (b) — §8 Completion behavior last bullet (L211):**
```
  • `<Tab>` to force file completion, matching pi's
    `shouldTriggerFileCompletion`.

DEBOUNCE ~
```
⇒ INSERT the `!/!!` bullet (b) immediately after the `<Tab>` bullet, before the
blank line that precedes `DEBOUNCE ~`.

### Desired doc/pi-bridge.txt delta (no new files; edits to one file)

```bash
doc/pi-bridge.txt             # MODIFIED — §4 NOTE pointer (a) + §8 bullet (b)
                              #   (+ optional line-1 Last change date bump)
# No file is created. No file other than doc/pi-bridge.txt is touched.
```

### Known Gotchas of our codebase & Library Quirks

```vimdoc
" CRITICAL (define-vs-reference): `*pi-bridge-shell*` DEFINES a help tag;
"   `|pi-bridge-shell|` REFERENCES one. This task ONLY references. Adding a
"   `*pi-bridge-shell*` line to pi-bridge.txt would create a DUPLICATE tag
"   (vim warns, and Ctrl-] may jump to the wrong file). The definition lives
"   in pi-bridge-shell.txt (P2.M3.T6.S4). Never add it here.

" CRITICAL (modeline is the last line): the file ends with
"   ` vim:tw=78:ts=8:noet:ft=help:norl:`  — vim treats a trailing modeline
"   specially. Do not append anything after it; if you add content, add it
"   ABOVE the modeline (inside the body), never below.

" GOTCHA (forward reference is safe): until P2.M3.T6.S4 ships, `|pi-bridge-shell|`
"   is an unresolved reference. That is EXPECTED mid-sweep — there is no
"   write-time error (neovim/neovim#329); only a live Ctrl-]/`:help` would say
"   E426, and only before the sibling lands. Both ship in the same changeset.

" GOTCHA (scope): do NOT add a CONTENTS/TOC entry for shell (L9-26). Shell has
"   its own help file with its own TOC. A TOC line here points at nothing
"   inside this file and is wrong.

" GOTCHA (the word "shell" already appears once): L258 "in your shell shows
"   NOTHING" is UNRELATED (it means the login shell, not shell completion).
"   Do not "find and replace" the word shell globally — that would corrupt L258.

" GOTCHA (the two inventories must agree): §4 says "separate subsystem, own
"   shell={} options, does NOT use the bridge socket"; §8 says "separate
"   daemon, real shell, does NOT use the bridge socket". Keep both
"   bridge-socket disclaimers — they prevent the rpc_timeout_ms misconception.

" GOTCHA (don't touch doc/tags): it is a GENERATED artifact owned by
"   P2.M3.T6.S4. Manually appending a line risks a malformed/duplicate entry.
"   The tag is created by `:helptags` scanning pi-bridge-shell.txt.
```

## Implementation Blueprint

### Implementation Tasks (ordered: do (b) then (a), both independent of order)

```yaml
Task 1: ADD the !/!! bullet to §8 Completion behavior  [contract point b — CORE]
  - EDIT doc/pi-bridge.txt.
  - FIND the last bullet of the §8 what-completes list (L211):
        "  • `<Tab>` to force file completion, matching pi's
            `shouldTriggerFileCompletion`."
  - INSERT immediately after it (before the blank line + "DEBOUNCE ~"):
        "  • `!/!!` prefix — shell command completion (see |pi-bridge-shell|): a
            leading `!` (or `!!`) routes the line to a separate shell-completion
            daemon driving your real shell (fish/zsh/bash). This path does NOT
            use the bridge socket."
  - NAMING: lead with the contract-verbatim phrase "`!/!!` prefix — shell
            command completion (see |pi-bridge-shell|)"; the colon+explanation
            mirrors the `@file` bullet's "Needs `fd`" caveat style.
  - ALIGNMENT: keep the 2-space indent + bullet "  • " + 4-space continuation
            indent used by the surrounding bullets (so the gutter stays flush).
  - GOTCHA: do NOT also add this to §6 Keymaps — that section is insert-mode
            MAPPINGS (<Tab>/<CR>/<C-N>…), not "what completes".

Task 2: ADD the shell pointer NOTE to §4 Configuration  [contract point a — CORE]
  - EDIT doc/pi-bridge.txt.
  - FIND the §4 closing paragraph (L133-135):
        "The seven keys above are the full public configuration surface. `setup()`
         returns the resolved config and also stores it as
         `require(\"pi-bridge\").config`."
  - INSERT after it (before the L137 `===` divider):
        "NOTE ~
         This plugin also completes `!/!!` shell (\"bash-mode\") lines against your
         real shell — a separate subsystem with its own `shell = {}` options that
         does NOT use the bridge socket. For shell completion of `!/!!` commands,
         see |pi-bridge-shell|."
  - NAMING: the FINAL sentence is CONTRACT-VERBATIM ("For shell completion of
            `!/!!` commands, see |pi-bridge-shell|."). Keep "NOTE ~" header style
            (matches the file's other "NOTE:" / "DEBOUNCE ~" / "ACCEPTANCE ~"
            sub-headers, e.g. L116, L213, L246).
  - GOTCHA: "separate subsystem with its own shell={} options" is accurate — the
            shell config is NOT part of the seven keys listed just above. The
            "does NOT use the bridge socket" clause prevents the rpc_timeout_ms
            misconception (PRD §17.11).

Task 3: (optional) BUMP line-1 "Last change:" date
  - EDIT the line-1 header `*pi-bridge.txt*\tFor Nvim 0.11+.\tLast change: 2025 Jul 20`.
  - CHANGE "Last change: 2025 Jul 20" → "Last change: 2025 Jul 31" (changeset
            date per sibling PRP P2.M4.T1.S1). Keep the tab separators and the
            `*pi-bridge.txt*` tag intact.
  - GOTCHA: if you are unsure of the canonical date, SKIP this task (leaving the
            date unchanged is acceptable). Do NOT invent a future date.

Task 4: VERIFY the cross-link + scope (NO edit — run the gates)
  - RUN the Level 2 grep gates below. Expect: `|pi-bridge-shell|` count == 2
            (§4 + §8); ZERO `*pi-bridge-shell*` definitions in this file;
            `git diff --name-only` == doc/pi-bridge.txt only.
  - DO NOT edit doc/tags, doc/pi-bridge-shell.txt, README.md, extension/README.md,
            or any .lua. If `git status` shows any of those, STOP — you crossed a
            sibling boundary.
```

### Implementation Patterns & Key Details

```vimdoc
" PATTERN: NOTE/subsection headers in this file use a trailing " ~" (e.g.
"   "DEFAULTS (mirror …) ~", "DEBOUNCE ~", "ACCEPTANCE ~"). Use "NOTE ~" for
"   edit (a) to match. (The file also has bare "NOTE:" inline notes at L246/L258;
"   either is acceptable — "NOTE ~" as a sub-header reads cleaner for a paragraph.)

" PATTERN: the §8 bullets each NAME the trigger, then explain the mechanism +
"   caveat. Mirror that: lead with the trigger token (`!/!!`), then the daemon
"   mechanism + the bridge-socket caveat.

" PATTERN: cross-references are bare `|tag|` inline — never `:help tag` inside
"   prose (the file uses `|pi-bridge-config|`, `|pi-bridge-autosave|`, etc.).
"   The `:help pi-bridge-shell` form appears in the README/help-titles, not in
"   this file's inline prose.

" CRITICAL: keep the bullet continuation indent aligned (2-space "  • " + 4-space
"   wrap indent) so the vimdoc gutter stays flush and the help viewer renders it
"   as one logical list item.
```

### Integration Points

```yaml
DOCUMENTATION GRAPH (no code/config/schema integration):
  - doc/pi-bridge.txt  --|pi-bridge-shell|-->  doc/pi-bridge-shell.txt
      (P2.M3.T6.S4). The link is a forward reference; resolves once the sibling
      defines *pi-bridge-shell* and :helptags runs. Both ship in the Mode B sweep.
  - doc/pi-bridge.txt §4 pointer summarizes PRD §17.11 (shell = {} options);
      §8 bullet summarizes §17.7 (routing) + §17.9 (real-shell daemon). No PRD
      edit (PRD is read-only).

NO CODE CHANGE: shell.lua / completion.lua / init.lua are NOT touched. The
  `shell = {}` options mentioned in §4 are the USER-facing pointer to the
  dedicated shell help (P2.M3.T6.S4 documents them); this file does not list
  them (avoids drift — single source of truth in pi-bridge-shell.txt).

NO doc/tags CHANGE: the pi-bridge-shell tag is created by P2.M3.T6.S4 via
  :helptags over the new pi-bridge-shell.txt. This task must not touch doc/tags.
```

## Validation Loop

> This is a documentation task. There is no compiler/test gate. Validation =
> deterministic grep gates (one per contract point) + a cross-link syntax check +
> a scope guard. Wrap any nvim invocation in `timeout` (AGENTS.md); none are
> required to PASS.

### Level 1: Vimdoc sanity (immediate)

```bash
# Confirm the file still ends with its modeline (nothing appended after it).
tail -1 doc/pi-bridge.txt
# Expected: ` vim:tw=78:ts=8:noet:ft=help:norl:`

# Confirm the CONTENTS TOC was NOT given a stray shell entry.
grep -nE 'shell' doc/pi-bridge.txt | grep -iE 'pi-bridge-contents|^[0-9]+\. .*shell' || echo "TOC untouched (OK)"

# Confirm no line exceeds the vimdoc width convention badly (tw=78; soft check —
# the existing file has some 79-80 char lines, so allow a little slack).
awk 'length > 82 {print NR": "length" chars"}' doc/pi-bridge.txt || true
# Expected: at most the pre-existing long lines; your added lines <= 78-80.
```

### Level 2: Content gates — one grep per contract point (a–c)

```bash
# (a) §4 Configuration pointer — contract-verbatim core sentence + tag
grep -n 'see |pi-bridge-shell|' doc/pi-bridge.txt
grep -n 'For shell completion of `!/!!` commands' doc/pi-bridge.txt
# Expected: both match, inside the §4 region (between the L98 header and L137 divider).

# (b) §8 Completion behavior bullet — contract-verbatim core lead + tag
grep -n '`!/!!` prefix — shell command completion' doc/pi-bridge.txt
# Expected: 1 match, inside §8 (after L195, before DEBOUNCE ~).

# CROSS-LINK COUNT: exactly TWO references, ZERO definitions (define-vs-ref guard)
echo "refs   : $(grep -c '|pi-bridge-shell|' doc/pi-bridge.txt)"   # expect 2
echo "defines: $(grep -c '\*pi-bridge-shell\*' doc/pi-bridge.txt)" # expect 0  ← CRITICAL
# Expected: refs == 2  AND  defines == 0.
#   If defines > 0 you accidentally added a tag DEFINITION — REMOVE it (P2.M3.T6.S4 owns it).
#   If refs != 2 you added/dropped a reference — reconcile to exactly §4 + §8.

# (c) doc/tags precondition — the tag will exist once P2.M3.T6.S4 ships.
#     This task does NOT create it; this gate is a SWEEP-LEVEL precondition, not
#     a this-task action. (Today it is 0 because P2.M3.T6.S4 is still Planned.)
grep -c 'pi-bridge-shell' doc/tags || echo "0 (expected pre-P2.M3.T6.S4; becomes >=1 after the sibling ships)"
```

### Level 3: Cross-doc consistency (forward reference resolves post-sweep)

```bash
# After P2.M3.T6.S4 ships (same changeset), the tag must resolve. Smoke-test in
# a real nvim ONLY if the sibling output is present (wrap in timeout per AGENTS.md):
if [ -f doc/pi-bridge-shell.txt ] && grep -q '\*pi-bridge-shell\*' doc/pi-bridge-shell.txt; then
  timeout 30 nvim --headless --clean -u NORC \
    +"helptags $(pwd)/doc" \
    +"help pi-bridge-shell" \
    +"call assert_match('pi-bridge-shell', bufname('%'))" \
    +"if !empty(v:errors) | cq | endif" +qa && echo "tag resolves OK" || echo "tag smoke FAILED"
else
  echo "pi-bridge-shell.txt not yet present (P2.M3.T6.S4) — forward ref is correct, skip live check"
fi
# Expected: either "tag resolves OK" (post-sweep) or the skip message (pre-sweep).
```

### Level 4: Scope guard (no collateral edits)

```bash
# ONLY doc/pi-bridge.txt changed; no sibling-task files touched.
git status --porcelain
git diff --name-only
# Expected: exactly one line — "M doc/pi-bridge.txt" (or " M doc/pi-bridge.txt").
#   doc/tags, doc/pi-bridge-shell.txt, README.md, extension/README.md, and any
#   *.lua MUST NOT appear. If they do, STOP — you crossed into sibling territory.

# Confirm the modeline is still the literal last line and unchanged.
[ "$(tail -1 doc/pi-bridge.txt)" = " vim:tw=78:ts=8:noet:ft=help:norl:" ] \
  && echo "modeline intact (OK)" || echo "MODELINE CORRUPTED — fix"
```

## Final Validation Checklist

### Technical Validation

- [ ] Level 1 vimdoc sanity passes (modeline is the last line; TOC untouched;
      no wildly long lines introduced).
- [ ] Level 2: `grep -c '|pi-bridge-shell|'` == 2 AND `grep -c '*pi-bridge-shell*'` == 0.
- [ ] Level 2: both contract-verbatim core phrases present (§4 sentence + §8 lead).
- [ ] Level 3: tag resolves post-sweep (or skip message pre-sweep — forward ref OK).
- [ ] Level 4: `git diff --name-only` shows ONLY `doc/pi-bridge.txt`; modeline intact.

### Feature Validation

- [ ] (a) §4 Configuration NOTE contains *“For shell completion of `!/!!`
      commands, see |pi-bridge-shell|.”* (verbatim) + the bridge-socket disclaimer.
- [ ] (b) §8 Completion behavior bullet leads with *“`!/!!` prefix — shell
      command completion (see |pi-bridge-shell|)”* (verbatim) + the daemon/real-
      shell explanation + bridge-socket disclaimer.
- [ ] (c) doc/tags was NOT edited by this task (precondition owned by P2.M3.T6.S4).
- [ ] A reader of `:help pi-bridge-completion` (or `-config`) can navigate to
      `:help pi-bridge-shell` via the new cross-links.

### Documentation Quality

- [ ] Matches the file’s existing NOTE/sub-header voice + bullet indent style.
- [ ] Both edits carry the “does NOT use the bridge socket” caveat (prevents the
      `rpc_timeout_ms` misconception).
- [ ] No PRD/PRP/tasks.json/sibling-doc/extension/.lua edits (read-only outside
      doc/pi-bridge.txt).

---

## Anti-Patterns to Avoid

- ❌ Don’t add a `*pi-bridge-shell*` tag DEFINITION to pi-bridge.txt — that lives
  in pi-bridge-shell.txt (P2.M3.T6.S4); a duplicate tag makes Ctrl-] ambiguous.
- ❌ Don’t manually edit `doc/tags` — it is generated by `:helptags` and owned by
  P2.M3.T6.S4; hand-editing risks malformed/duplicate entries.
- ❌ Don’t add a CONTENTS/TOC line (L9-26) for shell — shell has its own help file
  with its own TOC; a line here points at nothing in this file.
- ❌ Don’t global-find-and-replace the word “shell” — L258’s “in your shell” is
  unrelated (the login shell) and must stay verbatim.
- ❌ Don’t append anything after the modeline (` vim:tw=78:ts=8:…`) — it must be
  the last line; add body content above it.
- ❌ Don’t put the §8 bullet in §6 Keymaps — §6 is insert-mode MAPPINGS, not
  “what completes”; the behavior list is §8.
- ❌ Don’t list the full `shell = {}` 8-option block here — single source of truth
  lives in pi-bridge-shell.txt; this file only POINTS at it (avoids drift).
- ❌ Don’t touch README.md (P2.M4.T1.S1), extension/README.md (P2.M4.T1.S3), or
  doc/pi-bridge-shell.txt (P2.M3.T6.S4) — all are sibling-owned.

---

**Confidence Score: 9/10** — one-pass success is highly likely: it is a
two-line additive vimdoc edit, both edit sites are quoted verbatim with exact
line numbers, the contract wording is given word-for-word, and the validation is
deterministic grep gates. The one subtlety — *define-vs-reference* (`*tag*` vs
`|tag|`) — is called out explicitly so the implementer does not accidentally
create a duplicate tag or touch doc/tags. The forward-reference dependency on
P2.M3.T6.S4 is documented and safe (no write-time error; both ship in the same
Mode B changeset sweep).