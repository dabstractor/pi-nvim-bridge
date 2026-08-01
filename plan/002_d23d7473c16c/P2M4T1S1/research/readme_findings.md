# Research — P2.M4.T7.S1 (README shell-completion sweep)

> Mode B changeset-level documentation task. Single edit target: repo-root
> `README.md`. No code, no tests, no mocking. This file captures the facts the
> PRP rests on.

## 1. The edit target: current README.md structure (verified 2025-07-31)

```
## Demo:                                                    (L8)
## What it does                                            (L28)   ← FEATURES prose
## Prerequisites                                           (L44)   ← point (d)
## Installation                                            (L56)
  ### oh-my-pi (`omp`)                                     (L74)   ← ALREADY PRESENT (P1.M1.T1.S2)
  (Companion plugin block)                                 (~L100)
## Configuration (`$EDITOR`)                               (L117)  ← setup({}) lives only in lazy block
  ### Optional startup optimization                        (L137)
## How it works                                            (L182)  ← 3 numbered points (point c)
## The `PI_NVIM_BRIDGE` environment variable               (L197)
## Troubleshooting                                         (L219)
## Security                                                (L246)
## Development                                             (L256)
  **Repository layout:**                                   (L283)  ← file tree (point c)
## Links                                                   (L315)
## Releasing                                               (L322)
```

### 1a. The FEATURES list lives in TWO places (both need the bullet)

**(i) Opening two-component blurb (L18–27)** — renders list:
> renders pi's completion inside Neovim: `/commands`, `skill:` templates,
> argument completions, `@file` references, and filesystem paths.

**(ii) "What it does" prose (L28–42)** — repeats the list:
> …same `/` slash commands, same `skill:` templates, same `@file` references
> and path suggestions, same argument completions.

Contract point (a) = add a `!/!!` shell-completion bullet to the features list.
Keep it in BOTH spots for coherence (the P1.M1.T1.S2 omp PRP edited
Prerequisites + Installation together for the same reason).

### 1b. Exact current text at the edit sites (for precise oldText→newText edits)

**Prerequisites (L51)** — the `fd` bullet (point d inserts AFTER this):
```
- **`fd`** *(optional)* — enables fuzzy `@file` search. Without it `@file`
  silently returns nothing, but path completion (directory listing) still works.
```

**How it works (L182–196)** — 3 numbered points. Point (c) adds a 4th about the
shell-completion subshell (shell.lua routes `!`/`!!` lines to a persistent
fish/zsh/bash daemon; does NOT use the bridge socket).

**Repository layout tree (L291–292)** — the `lua/pi-bridge/` annotation:
```
├── lua/pi-bridge/            # init/bridge/completion/menu/coords/health/  │ nvim plugin
│                             #   blink_source/cmp_source/notify/jsonlreader │ runtime files
```
Does NOT name `shell` (daemon manager) or `shell/` (per-shell drivers).

## 2. RESOLVED: "the architecture diagram / nvim box" (contract point c)

**There is NO box-drawing architecture diagram in README.md today.** The
README's architecture representation is the "Repository layout" file tree
(L283) + the "How it works" prose (L182).

**The canonical box-drawing diagram lives in the PRD** (`prd_snapshot.md`
§3 Architecture Overview, L190–215). Its **nvim box ALREADY mentions
shell.lua** (updated when §17 was authored):

```
 │  nvim (the $EDITOR child)  ◄── loads pi-bridge.nvim                  │
 │     • VimEnter: vim.env.PI_NVIM_BRIDGE present? → activate         │
 │     • bridge.lua: luv pipe client, handshake (token), RPC dispatch   │
 │     • completion.lua: triggers, debounce, accept flow                │
 │     • menu.lua: dependency-free floating completion popup            │
 │     • shell.lua: persistent completion subshell (fish/zsh/bash)      │
 │       spawns pi's resolved shell (default); routes `!`/`!!` lines    │
 │       descriptor gains shell/shellSource (§17.4 consistency)         │
 │     • ExitPre/VimLeavePre: autosave (so pi reads the latest prompt)  │
```

**→ Recommended action for point (c):** copy the PRD §3 box-drawing diagram
into the README's "How it works" section (it already correctly contains the
shell.lua line in the nvim box — no edit to the art needed). This literally
satisfies "update the nvim box to mention shell.lua" and is additive/low-risk.
**Supporting edit:** also update the "Repository layout" tree's
`lua/pi-bridge/` annotation to name `shell` + `shell/`.

## 3. The omp install path is ALREADY present (contract point e = preserve, not add)

Verified present in README.md:
- **Prerequisites (L46–47):** `- **pi** with extension support — or the
  **oh-my-pi** fork (`omp`); the extension runs under either host …`
- **`### oh-my-pi (\`omp\`)` subsection (L74–90):** the three commands
  `omp plugin install npm:pi-nvim-bridge`, `omp plugin list`,
  `omp plugin doctor`, + the "zero code change" note.

Point (e) is a **verification/preservation gate**, not new work. The PRP must
assert (grep) that these survive the shell-completion edits unchanged.

## 4. The `shell = {}` config pointer (contract point b) — source of truth = PRD §17.11

From `selected_prd_content` (§17.11), verbatim:
```lua
require("pi-bridge").setup({
  shell = {
    enabled           = true,                 -- master switch
    prefer            = "pi",                 -- "pi" | "shell" | "bash" | "/abs/path"
    drivers           = { fish = true, zsh = true, bash = true },
    warm_on_enter     = false,
    timeout_ms        = 1500,
    startup_timeout_ms= 5000,
    visual_cue        = "gutter",
    debounce_ms       = 0,
  },
})
```
Key facts for the README section:
- `shell = {}` is the config key; `prefer = "pi"` (default) matches pi's own
  execution shell (descriptor.shell / §17.4).
- The daemon drives the user's REAL shell (fish/zsh/bash) — NOT pi's completion
  engine. Shell completion does **not** use the bridge socket (`rpc_timeout_ms`
  is unaffected — §17.11 last line).
- Canonical detail source = `:help pi-bridge-shell` (produced by sibling task
  **P2.M3.T6.S4**, Planned). README references it as a forward pointer — fine
  for docs in the same changeset sweep.

## 5. Actual module layout (verified) — for accurate diagram/tree copy

```
lua/pi-bridge/
├── bridge.lua completion.lua coords.lua health.lua init.lua jsonlreader.lua
├── menu.lua notify.lua blink_source.lua cmp_source.lua
├── shell.lua            ← daemon manager (resolve_shell, ensure/request/_feed, teardown)
└── shell/               ← per-shell drivers + accept
    ├── accept.lua       ← per-shell quoting (POSIX single-quote)
    └── fish.lua         ← Tier-1 driver (zsh.lua/bash.lua pending: P2.M3.T5.S1/S2)
```

## 6. Sibling-task boundaries (do NOT cross)

- **P2.M4.T7.S2** (doc/pi-bridge.txt cross-link) — NOT this task. Do not edit
  `doc/pi-bridge.txt`.
- **P2.M4.T7.S3** (extension/README.md new descriptor fields + PI_NVIM_SHELL)
  — NOT this task. Do not edit `extension/README.md`.
- **P2.M3.T6.S4** (doc/pi-bridge-shell.txt vimdoc) — produces the `:help` target
  this README points at. Planned; the README forward-reference is correct.
- This task edits ONLY repo-root `README.md`.

## 7. Validation approach for a doc task

No build/test/compile gate. Validation = **deterministic grep gates** for each
contract point + a markdown-render sanity check (no broken anchors/tables) +
a cross-doc consistency check (README `:help` ref + omp commands survive).
`mdcat`/`glow`/`glow` preview is optional if installed.