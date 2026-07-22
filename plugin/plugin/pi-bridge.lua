--- pi-bridge.nvim — VimEnter auto-activation shim.
---
--- This file is auto-sourced by Neovim at startup step 12 (`:help load-plugins`): every
--- `plugin/*.lua` on `runtimepath` is sourced, in alphabetical order, strictly BEFORE
--- the `VimEnter` event fires at step 19 (`:help VimEnter`). So the autocmd registered
--- below is guaranteed live before `VimEnter`.
---
--- It registers exactly ONE `VimEnter` autocmd in the `pi-bridge` augroup:
---   - `clear = true`  — re-sourcing (e.g. `:source %` or a plugin-manager reload) wipes
---                       and re-adds, so autocmds never stack duplicates.
---   - `once = true`   — the callback runs exactly once per session, then is removed.
---
--- The callback calls `require("pi-bridge").activate()` (implemented by a later task,
--- S21). The plugin stays DORMANT in every ordinary nvim session: `activate()` itself
--- returns early unless pi spawned this editor with `PI_NVIM_BRIDGE` set (PRD §7.1,
--- §11). The guard below also keeps this shim crash-free while `activate` is absent
--- (interim build / broken install) — it degrades silently instead of throwing.
---
--- IMPORTANT (install): the user's plugin manager MUST use `lazy = false` (PRD §10.3) so
--- this file is sourced at startup rather than deferred past `VimEnter`. With lazy=true
--- the shim may source after VimEnter and activation is skipped.
---
--- Scope: this shim ONLY triggers activation. It does NOT read `PI_NVIM_BRIDGE`, call
--- `setup()`, or `require` any module other than `pi-bridge` (those belong to S21 / the
--- user's config / S24 respectively).
local group = vim.api.nvim_create_augroup("pi-bridge", { clear = true })

vim.api.nvim_create_autocmd("VimEnter", {
  group = group,
  once = true,
  callback = function()
    -- pcall(require) for load safety: a broken/missing module degrades silently (dormant).
    -- We do NOT pcall activate() itself: genuine activate() bugs should surface for
    -- debugging (activate / S21+S39 own their internal resilience).
    local ok, pi = pcall(require, "pi-bridge")
    if ok and type(pi.activate) == "function" then
      pi.activate()
    end
  end,
})
