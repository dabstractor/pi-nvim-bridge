# Research Notes — P1.M2.T7.S1 (changeset doc sweep)

> NOTE on path: the orchestrator stored this work item at `P1M2T4S1/`, but its
> TITLE/DESCRIPTION are the cross-cutting **documentation sweep**
> (`P1.M2.T7.S1` in the plan tree: "Sweep README.md, extension/README.md, and
> doc/pi-bridge.txt for changeset consistency"). This PRP implements the
> doc-sweep content. **Documentation only — no code changes.**

## What this task IS / IS NOT

- **IS**: the Mode-B final sweep (SOW §5) over the THREE cross-cutting
  OVERVIEW docs: `README.md` (root), `extension/README.md`, `doc/pi-bridge.txt`.
- **IS NOT**: the per-feature Mode-A doc updates, which were/are done inside
  their own subtasks:
  - `doc/pi-bridge-shell.txt §3` (T3.S1) — DONE (commit 9077534)
  - `resolve_shell` doc-comment (T1.S1) — DONE (commit 1a0a071)
  - `ensure()` mismatch+consistency notice comments (T2.S1, T3.S1) — DONE
  - driver `M.cd` doc-comments (T5.S1), driver KNOWN LIMITATION notes
    (T6.S1/S2) — owned by those tasks (Planned at PRP time; the overview docs
    do not surface these driver-internals, so they should not need changes)

## The 6 fixes (status at PRP time) and their doc impact on OVERVIEW docs

| Issue | Fix subtask | Status | Touches an overview doc? |
|---|---|---|---|
| 5 — inaccurate `shellSource` | T1.S1 | DONE | doc table `shellSource` values now `"pi"\|"$SHELL"\|"default"` — verify in ext/README table |
| 1 — notice fires for prefer="bash" | T2.S1 | DONE | README/pi-bridge.txt barely describe the notice; minor verify |
| 2 — default-case consistency gap + `PI_NVIM_SHELL` | T3.S1 | DONE | **MAIN** — README "always agree" claims + missing `PI_NVIM_SHELL` |
| 3 — supersession race | T4.S1 | Researching | not user-facing in overview docs — verify none |
| 4 — cwd re-tracking `M.cd` | T5.S1 | Planned | not user-facing in overview docs — verify none |
| 6 — quoted-command flood | T6.S1/S2 | Planned | driver-internal; overview docs don't claim flood behavior — verify none |

Conclusion: the **substantive** overview-doc edits cluster around Issue 2
(`PI_NVIM_SHELL` + the "always agree" headline claim). Issues 1/5 are verify-
only; Issues 3/4/6 are verify-only (likely no edit).

## Precise findings per file

### README.md (root) — 3 edits needed

1. **L40-44 ("What it does")** — STALE claim:
   `...so completions and execution always agree rather than a zsh-only alias
   being suggested then failing under bash.`
   FALSE in the default case: non-bash `$SHELL` + unset `PI_NVIM_SHELL` ⇒
   completion uses `$SHELL` (zsh/fish) while pi still EXECUTES in bash ⇒ they
   do NOT agree (a zsh-only alias CAN be suggested then fail). Needs qualifier
   + pointer to `PI_NVIM_SHELL`.

2. **L146-148 ("### Shell completion")** — STALE claim (same defect):
   `It defaults to the shell pi *executes* commands in (prefer = "pi" — bash
   unless you set pi's shellPath), so a completion and the command that runs
   always agree.`
   Same fix: qualify "always agree", surface `PI_NVIM_SHELL` as the opt-in
   that restores it, cross-ref `:help pi-bridge-shell` §3.

3. **PI_NVIM_SHELL entirely absent** from README.md (grep: 0 hits). README
   documents env vars `PI_NVIM_BRIDGE` and `PI_NVIM_APPNAME` but NOT
   `PI_NVIM_SHELL`. Add a short env-var note near the shell-completion
   section. AND fix the troubleshooting entry **L303-308** ("`!`/`!!`
   completions are bash-quality / missing") which says "completion uses pi's
   execution shell — bash" — that is BACKWARDS under the default fallback
   (it actually uses `$SHELL`=zsh/fish). Reconcile with shellSource semantics
   and name `PI_NVIM_SHELL`.

### extension/README.md — 1 verify + 1 cross-ref edit

- `PI_NVIM_SHELL` is ALREADY comprehensively documented (L12, L96, L99,
  L122-157, L228). The descriptor table `shellSource` values
  (`"pi"\|"$SHELL"\|"default"`, L96) and the worked example (L99) MATCH the
  post-T1.S1 code. **No change needed to the table.**
- GAP: the "PI_NVIM_SHELL" honesty-note section (L129-165) explains the
  limitation from the EXTENSION side and cross-refs PRD §17.10.2/§17.17, but
  does NOT cross-link the PLUGIN-side doc `doc/pi-bridge-shell.txt §3`
  (`pi-bridge-shell-prefer`), which now (post-T3.S1) documents the
  "default-case consistency gap" + the in-editor one-time notice. Add a
  pointer so the two halves of the explanation are linked. (L120 + L223
  already link shell.txt generically — make the §3 link explicit.)

### doc/pi-bridge.txt (vimdoc) — 2 edits + verify

1. **L227-230 (§8 Completion behavior, "SHELL COMPLETION" tail)** — STALE:
   `By default the daemon completes using pi's execution shell (commonly
   /bin/bash) so completions match what `!` will actually run`
   Qualify "completions match" for the default fallback; cross-ref
   `|pi-bridge-shell-prefer|` (already linked) which now carries the gap doc.

2. **L374-380 (§13 FAQ "Why does !git ch complete with bash...")** — premise
   is conditional on shellSource. Add: if instead you SEE zsh/fish
   completions that fail under bash, export `PI_NVIM_SHELL` (cross-ref
   `|pi-bridge-shell-prefer|`).

3. **L282-285 (§10 env descriptor shell* fields)** — verify cross-ref to
   `|pi-bridge-shell-prefer|` (present). Optionally name `PI_NVIM_SHELL` as
   what makes `shellSource=="pi"`. Minor.

- Cross-refs `|pi-bridge-shell-prefer|` and `|pi-bridge-shell-config|`:
  both tags EXIST in `doc/tags` (L25, L19). Consistent. No new tags needed.
- `Last change:` date stamps (README/pi-bridge.txt headers) should be bumped
  to the sweep date.

## Key code facts the docs must reflect (verified)

- `resolve_shell(prefer)` returns `(path, source)`, `source ∈ {"pi","$SHELL","default"}` (lua/pi-bridge/shell.lua ~L162-191, T1.S1).
- §17.4.3 mismatch notice is GATED on `(cfg.prefer or "pi")=="pi"` (shell.lua ~L405-417, T2.S1).
- §17 consistency-footgun notice fires under `prefer=="pi" AND source=="$SHELL" AND basename($SHELL)∈{zsh,fish}` with a DISTINCT `"shell-consistency"` notify category, dedup'd once/session, message names `PI_NVIM_SHELL` (shell.lua ~L418-437, T3.S1).
- `SHELL_MIRROR_ENV = "PI_NVIM_SHELL"` in extension/pi-nvim-bridge.ts L323; resolver 3-branch chain (L441-452).
- doc/pi-bridge-shell.txt §3 (T3.S1) already has "THE DEFAULT-CASE CONSISTENCY GAP", "THE OPT-IN FIX: PI_NVIM_SHELL", "THE ONE-TIME NOTICE".

## Validation approach (docs-only — adapt the template's ruff/mypy gates)

No code changes ⇒ ruff/mypy/pytest are N/A. Substitute:
- **L1 prose**: grep for residual unqualified "always agree"/"completions match"/"completion uses pi's execution shell — bash" claims ⇒ must be 0 after edits.
- **L2 consistency**: `PI_NVIM_SHELL` referenced in all three overview docs where the consistency topic appears.
- **L3 help-tag integrity**: regenerate `doc/tags` via a FILE-based nvim `:helptags` (AGENTS.md HARD RULE: never pipe heredoc→nvim stdin) and assert `:help pi-bridge-shell-prefer` resolves. Use a file-based `luafile` smoke or a `-c 'lua ...'` one-liner.
- **L4 no-regression**: run the existing Lua spec suite (incl. `shell_notices_spec.lua`, which T3.S1 updated) to confirm docs didn't accidentally get picked up as code — green.