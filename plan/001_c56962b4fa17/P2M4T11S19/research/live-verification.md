# Live Verification — `init.lua` `setup()` claims

> **Context.** A prior planning pass produced `P2M1T1S1/{PRP.md,research/*.md}`
> for THIS task (`P2.M4.T11.S19`, renumbered). That pass's `research/testing.md`
> explicitly flagged a gap: *"I had no shell tool in this subagent, so the exact
> commands were verified by reading installed source (Neovim docs + plenary)
> rather than by a live `nvim` run."* This note CLOSES that gap: every load-bearing
> claim is now confirmed by a real `nvim --headless` run against the installed
> **Neovim 0.12.4** + **plenary.nvim** at `/home/dustin/.local/share/nvim/lazy/plenary.nvim`.
>
> Environment verified: `NVIM v0.12.4`, repo root `/home/dustin/projects/pi-nvim-bridge`.

## Method

Built a throwaway skeleton at `/tmp/pieb-verify/plugin/lua/pi-editor/init.lua`
(embodying the exact contract: `M.defaults`/`M.config`/`M.bridge`/`M.setup` with
`opts = opts or {}; M.config = vim.tbl_deep_extend("force", M.defaults, opts)`)
and ran the real validation commands. Skeleton was then discarded; it is NOT the
deliverable (the deliverable is `plugin/lua/pi-editor/init.lua` in the repo).

## Confirmed claims

### 1. `vim.tbl_deep_extend("force", defaults, opts)` semantics — LIVE VERIFIED

Ran `setup({ debounce_ms=50, autosave_on_exit=false, menu={ max_height=40 } })`
and read back every field. Result (raw JSON from nvim):

```json
{"d":50,"a":"false","mh":40,"mb":"rounded","defd":25,"defmh":12,"eq":"true","bridge":"nil"}
```

| Claim | Evidence | Status |
|---|---|---|
| Scalar override wins | `d=50` (default 25) | ✅ |
| **`false` overrides default `true`** (value-based, not truthiness) | `a="false"` | ✅ |
| Nested dict deep-merges (override one key, keep sibling) | `mh=40` AND `mb="rounded"` | ✅ |
| `M.defaults` NOT mutated | `defd=25`, `defmh=12` | ✅ |
| `setup()` returns the same table ref as `M.config` | `eq="true"` | ✅ |
| `M.bridge == nil` placeholder | `bridge="nil"` | ✅ |

### 2. Runtimepath gotcha (GOTCHA #1) — LIVE VERIFIED

- `runtimepath += <repo-root>` → `require("pi-editor")` **FAILS** (nvim searches
  `<repo-root>/lua/pi-editor/init.lua`, which does not exist). ✅
- `runtimepath += <repo-root>/plugin` → `require("pi-editor")` **ok=true**. ✅

This is the #1 cause of `module 'pi-editor' not found` and is correctly stated as:
**the runtimepath entry must be the `plugin/` SUBDIRECTORY, not the repo root.**

### 3. Heredoc-in-cmd-args gotcha (GOTCHA #10) — LIVE VERIFIED

```
nvim --headless --clean -u NORC +"lua <<LUA ... LUA" +qa
→ E5107: Lua: [string ":lua"]:1: unexpected symbol near '<'
```

So a `:lua <<HEREDOC` is unusable inside `-c`/`+` command-line args. Multi-statement
validation must use either (a) a file sourced via `:luafile`, or (b) a single `-c`
arg with semicolon-separated statements. This is exactly why `plugin/tests/smoke.lua`
exists and is sourced via `:luafile` rather than inlined.

### 4. Smoke test (dependency-free, `:luafile`) — LIVE VERIFIED

`plugin/tests/smoke.lua` (self-appends runtimepath, `check(cond,msg)` + `cquit 1`
on failure) run via:

```
nvim --headless --clean -u NORC +"luafile plugin/tests/smoke.lua" +qa
→ SMOKE_PASS , exit=0
```

### 5. plenary in-process `.run()` form (the Level-2 gate) — LIVE VERIFIED

`plugin/tests/minimal_init.lua` (prepends plenary, appends `plugin_root`) +
`plugin/tests/init_spec.lua` (3 `it` blocks), run via:

```
cd plugin && nvim --headless --clean -u tests/minimal_init.lua \
  -c 'lua require("plenary.busted").run("tests/init_spec.lua")'
→ Success: 3  Failed: 0  Errors: 0 , exit=0
```

Both `assert.are.equals` (shallow) and `assert.is_false` (from luassert, bundled
in plenary) behave as documented. The `.run()` exit codes (0 pass / 1 fail / 2
load-error, via `cquit`) are reliable for a CI step.

## Tooling inventory (this environment)

- ✅ `nvim` 0.12.4 on PATH.
- ✅ `plenary.nvim` at `/home/dustin/.local/share/nvim/lazy/plenary.nvim` (lazy dir).
- ❌ `stylua` NOT installed → not a hard validation gate (optional lint/format only).
- ❌ `selene` NOT installed → same.

## Implication for the PRP

The validation commands in `P2M4T11S19/PRP.md` are **proven to run green** in this
environment, not merely inferred from docs. An implementer can paste them verbatim
and expect `exit=0`. The prior `P2M1T1S1` PRP remains a valid, detailed reference
contract (its research files are not duplicated here — they are cited where used).
