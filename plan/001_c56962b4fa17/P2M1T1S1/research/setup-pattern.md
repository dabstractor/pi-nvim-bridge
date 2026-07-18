# Research: `init.lua` `setup()` pattern for a dependency-free Neovim plugin

> Scope: `pi-editor.nvim`, module `lua/pi-editor/init.lua` → `require("pi-editor")`.
> Plugin root in THIS monorepo is the `plugin/` subdirectory
> (`plugin/lua/pi-editor/init.lua`). Neovim 0.12.4.
>
> **Provenance.** Verified against Neovim's own docs (`neovim.io/doc/user/lua.html`,
> `:help vim.tbl_deep_extend`, `:help lua-require`) and the LuaLS annotations wiki
> (GitHub). Neovim-source URLs verified via web search; see Sources.

---

## 1. Canonical `setup(opts)` structure (dependency-free)

The near-universal shape for a plugin that ships a single `setup()` entry point:

```lua
local M = {}

--- Default configuration (exported so :checkhealth / tests can read it).
M.defaults = {
  -- scalar + nested-dict options
}

--- Resolved configuration. nil until setup() runs.
M.config = nil

---@param opts? pi-editor.Config user overrides
---@return pi-editor.Config resolved config
function M.setup(opts)
  opts = opts or {}                                   -- guard against nil
  M.config = vim.tbl_deep_extend("force", M.defaults, opts)
  return M.config
end

return M
```

Real-world references (URLs verified to resolve):
- **lewis6991/gitsigns.nvim** `lua/gitsigns.lua` — the canonical `setup` + `M.config`
  + `vim.tbl_deep_extend("force", ...)` pattern.
  <https://github.com/lewis6991/gitsigns.nvim/blob/main/lua/gitsigns.lua>
- **folke/which-key.nvim** `lua/which-key/init.lua` — `setup(opts)` that builds
  `M.config` from defaults + opts.
  <https://github.com/folke/which-key.nvim/blob/main/lua/which-key/init.lua>
- Neovim's OWN LSP client merges config with `vim.tbl_deep_extend("force", …)`
  (neovim.io lsp doc, ref_4 in search) — confirming `"force", defaults, user` is the
  sanctioned ordering.

---

## 2. `vim.tbl_deep_extend` semantics & gotchas

**Definition** (neovim.io `lua.txt`, verified):
> "Merges two or more table recursively into a new table. Only **lua-dict tables**
> are merged recursively; **lua-list tables are treated as opaque values**."

**`behavior` argument** (`:help vim.tbl_deep_extend`):
- `"force"` — for keys in multiple tables, **rightmost (later) tables take
  precedence** at the leaf level; nested dict-vs-dict pairs are recursively merged.
- `"keep"` — leftmost (earlier) values win.

**For our config `vim.tbl_deep_extend("force", M.defaults, opts)`** — desired:
| Scenario | Result | Correct? |
|---|---|---|
| `opts.debounce_ms = 50` | `config.debounce_ms == 50` (opts wins) | ✅ |
| `opts.autosave_on_exit = false` | `config.autosave_on_exit == false` (opts `false` beats default `true`) | ✅ |
| `opts.menu = { max_height = 20 }` | `config.menu == { max_height = 20, border = "rounded" }` (dict deep-merged) | ✅ |
| `opts.menu = { border = "none" }` | `config.menu == { max_height = 12, border = "none" }` | ✅ |
| `opts.engine = "blink"` | `config.engine == "blink"` | ✅ |

**KEY: `false` DOES override `true`.** `"force"` selects the rightmost value at a
leaf regardless of truthiness — `false` is a real value, not absence. So
`autosave_on_exit = false` from the user correctly disables the default `true`.
(Contrast: a Lua `{ key = nil }` literal is the same as omitting the key, so a
user who writes `engine = nil` keeps the default `"builtin"` — also correct.)

**GOTCHA #1 — `nil` argument throws.** `vim.tbl_deep_extend` errors if ANY table
argument is `nil`. This is why `opts = opts or {}` is mandatory before the call.

**GOTCHA #2 — list/array tables are OPAQUE.** Lists (array-like, `t[1], t[2], …`)
are replaced wholesale, NOT element-merged. neovim/neovim#23654 + the r/neovim
nightly thread document this. **Not a problem for our config** (`menu` is a dict,
not a list), but it matters for future fields: any user-facing array option would
be fully replaced, not appended. (neovim#23654:
<https://github.com/neovim/neovim/issues/23654>; discussion force-vs-keep #37383:
<https://github.com/neovim/neovim/discussions/37383>.)

**GOTCHA #3 — does NOT mutate inputs.** It returns a NEW table; nested dict merges
go into new sub-tables. So `M.defaults` stays pristine after `setup()` runs with
overrides. (Worth an assertion in the spec to pin this.)

**Sources:**
- `:help vim.tbl_deep_extend` — <https://neovim.io/doc/user/lua.html> (search the
  page for `vim.tbl_deep_extend`)
- neovim#23683 (force/keep discussion) — <https://github.com/neovim/neovim/discussions/37383>
- neovim#23654 (list opacity) — <https://github.com/neovim/neovim/issues/23654>

---

## 3. Idempotent / re-setup guard

Most mature plugins do NOT hard-error on a second `setup()`, but several store a
"configured" flag and either no-op or re-apply. For THIS task the contract is
explicitly "merge + store", with no double-setup semantics required. The simplest
correct behavior is: **each `setup()` call re-merges and overwrites `M.config`** —
no guard. (The plenary `before_each` in the test forces a re-require via
`package.loaded["pi-editor"] = nil`, so repeated setups on a fresh module are the
norm; on the SAME module instance a repeat `setup()` just rewrites `M.config`,
which is harmless and arguably desirable for live config reload.) **Decision: no
guard for S19.** A future task can add a `M._setup_done` flag if reload semantics
need restricting.

---

## 4. LuaCATS / lua-language-server annotations

**Source of truth:** LuaLS wiki "Annotations" —
<https://github.com/LuaLS/lua-language-server/wiki/Annotations> (verified). Key tags:

| Tag | Purpose |
|---|---|
| `---@class Name` | declare a class/table type (used WITH `---@field`) |
| `---@field name Type [desc]` | document a table field (default value via `[default]`) |
| `---@param name Type [desc]` | document a function parameter (`?` = optional) |
| `---@return Type [desc]` | document a return value |
| `---@type Type` | annotate a variable |
| `---@module "name"` | declare the module (optional; lua_ls infers from path) |

**Concrete annotation set for THIS module** (so `:K`/hover shows docs in nvim and
lua_ls reports types):

```lua
---@class pi-editor.MenuConfig
---@field max_height integer Maximum visible rows in the completion popup.
---@field border string|"none"|"single"|"double"|"rounded"|string[] Border style.

---@class pi-editor.Config
---@field menu pi-editor.MenuConfig Floating-menu appearance.
---@field debounce_ms integer Ms to wait before re-querying the bridge after a change.
---@field rpc_timeout_ms integer Ms before a pending RPC is dropped (supersession).
---@field autosave_on_exit boolean Write the pi temp file on VimLeavePre if modified.
---@field engine "builtin"|"blink"|"cmp"|"auto" Completion UI engine.
---@field env_var? string Override the bridge-descriptor env var (default "PI_EDITOR_BRIDGE").
```

Then on `setup`:
```lua
---@param opts? pi-editor.Config User-provided options (empty table OK).
---@return pi-editor.Config The resolved, merged config (also stored as M.config).
function M.setup(opts) ... end
```

**Real reference:** folke plugins (which-key.nvim, lazy.nvim) are the gold standard
for `---@class`+`---@field` config annotations; see
<https://github.com/folke/which-key.nvim/blob/main/lua/which-key/types.lua> and the
init setup annotations.

---

## 5. Exposing a field that starts `nil` (`M.bridge`)

The contract requires exposing `M.bridge` as a `nil` placeholder (populated later by
`bridge.lua`, PRD §7.7). In Lua, an unset field IS `nil`, so the runtime behavior is
identical whether or not we write `M.bridge = nil`. We write it **explicitly with a
docstring** so it is discoverable in hover/typed-completion and self-documents the
forward contract:

```lua
--- Bridge client. Set by `bridge.lua` after a successful connect+handshake; nil
--- until then (and in dormant sessions with no PI_EDITOR_BRIDGE env var). External
--- code (blink/cmp sources, user code) reads `require("pi-editor").bridge` to issue
--- RPCs. See PRD §7.7.
---@type table|nil
M.bridge = nil
```

`table|nil` is used (not a concrete `pi-editor.Bridge` type) because `bridge.lua`
does not exist yet (future task S24) — a forward `---@type pi-editor.Bridge` would
be an unresolved reference. The next task can tighten this to a real type.

---

## Sources (verified)
- LuaLS Annotations wiki — <https://github.com/LuaLS/lua-language-server/wiki/Annotations> — `@class`/`@field`/`@param`/`@return`/`@type` syntax
- Neovim `:help vim.tbl_deep_extend` — <https://neovim.io/doc/user/lua.html> — merge semantics (force/keep, list-opacity, non-mutating)
- neovim#23654 — <https://github.com/neovim/neovim/issues/23654> — list-tables treated as opaque
- neovim#37383 — <https://github.com/neovim/neovim/discussions/37383> — force vs keep usage
- gitsigns.nvim init — <https://github.com/lewis6991/gitsigns.nvim/blob/main/lua/gitsigns.lua> — canonical setup+config pattern
- which-key.nvim — <https://github.com/folke/which-key.nvim/blob/main/lua/which-key/init.lua> — setup + LuaCATS annotations
