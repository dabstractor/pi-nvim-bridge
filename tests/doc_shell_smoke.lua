-- tests/doc_shell_smoke.lua — Level 1 doc validation (no plenary; runs under -u NORC).
-- Validates the new doc/pi-bridge-shell.txt + doc/pi-bridge.txt edits.
-- AGENTS.md HARD RULE: this is a FILE run via :luafile — NEVER heredoc into nvim stdin.

-- (1) :help pi-bridge-shell opens a help buffer (tags resolve).
vim.cmd("help pi-bridge-shell")
local ft = vim.bo[vim.api.nvim_get_current_buf()].filetype
assert(ft == "help", ":help pi-bridge-shell did not open a help buffer (ft=" .. tostring(ft) .. ")")

-- (2) First-line tag matches the filename (helptags requires this).
local lines = vim.fn.readfile("doc/pi-bridge-shell.txt")
assert(lines[1]:find("^%*pi%-bridge%-shell%.txt%*"),
  "bad first-line tag: " .. tostring(lines[1]))
-- (3) Trailing modeline is the exact documented bytes.
assert(lines[#lines]:find("vim:tw=78:ts=8:noet:ft=help:norl:"),
  "bad/missing modeline: " .. tostring(lines[#lines]))

-- (4) The cross-links landed in the sibling file.
local sib = vim.fn.readfile("doc/pi-bridge.txt")
local sib_blob = table.concat(sib, "\n")
assert(sib_blob:find("|pi%-bridge%-shell|"),           "missing CONTENTS |pi-bridge-shell| link")
assert(sib_blob:find("|pi%-bridge%-shell%-prefer|"),   "missing §10 |pi-bridge-shell-prefer| link")

-- (5) doc/tags contains the new entries (helptags regen succeeded).
local tags = vim.fn.readfile("doc/tags")
local tag_blob = table.concat(tags, "\n")
for _, t in ipairs({ "pi-bridge-shell\t", "pi-bridge-shell-config\t", "pi-bridge-shell-prefer\t" }) do
  assert(tag_blob:find(t, 1, true), "doc/tags missing entry: " .. t)
end

print("doc_shell_smoke: OK")