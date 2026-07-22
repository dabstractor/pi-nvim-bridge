--- notify.lua — one-time, dedup'd, context-safe failure notification (S39).
-- Centralizes (a) dedup-by-category so connect-fail + handshake-fail + process-death
-- collapse to ONE toast per session (PRD §11 "a single vim.notify the first time" /
-- "notify once"), and (b) the vim.schedule wrapping so the handshake `on_result` cb
-- (which runs INLINE from luv fast context — bridge.lua resolve_handshake is NOT
-- schedule_wrap'd, unlike resolve_request) can call once() WITHOUT throwing E5560.
-- Mirrors the repo's one-responsibility-per-module style (cf. jsonlreader.lua).
local M = {}
local seen = {}  -- category -> true (the dedup set)

--- Emit `vim.notify(msg, level, {title="pi-bridge"})` AT MOST ONCE per `category` per
--- session. Subsequent calls with the same category are silent no-ops (PRD §11 "never
--- spam"). `vim.schedule`s the notify so this is safe to call from luv fast context
--- (the handshake cb) OR the nvim main loop (the disconnect handler). Never throws
--- (pcall the notify; bad args degrade to defaults). Default category "bridge"; default
--- level WARN.
---@param category string? Dedup key (default "bridge" — all bridge failures collapse to one toast).
---@param level integer? vim.log.levels.* (default WARN).
---@param msg string The human-readable message.
function M.once(category, level, msg)
  if type(category) ~= "string" or category == "" then category = "bridge" end
  if seen[category] then return end
  seen[category] = true
  local l = (type(level) == "number") and level or vim.log.levels.WARN
  vim.schedule(function()
    pcall(vim.notify, msg, l, { title = "pi-bridge" })
  end)
end

--- Clear the dedup set (for tests + a future explicit re-arm). Never throws.
function M.reset() seen = {} end

--- Whether once() has already fired for `category` (default "bridge"). For tests.
---@param category string?
---@return boolean
function M.did_notify(category)
  return seen[(type(category) == "string" and category ~= "") and category or "bridge"] == true
end

return M