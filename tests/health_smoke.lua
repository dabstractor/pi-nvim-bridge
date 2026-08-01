-- === tests/health_smoke.lua — standalone (plenary-FREE) smoke test ===
-- The Level-3 validation gate for the S42 health module: instant, dependency-free
-- feedback (no plenary). Exercises M.check() end-to-end with a stubbed vim.health,
-- asserting it never throws + emits >= 1 start() section.
--
-- Run from the repo root:
--   nvim --headless --clean -u NORC -c 'set rtp+=.' +"luafile tests/health_smoke.lua" +qa
--   echo "exit=$?"   # 0 = pass (prints 'SMOKE_PASS'), 1 = a check failed
--
-- NO `:lua <<HEREDOC` in a -c/+ arg (AGENTS.md HARD RULE — source via :luafile).
local me = debug.getinfo(1, "S").source:sub(2)
me = vim.fn.fnamemodify(me, ":p")
local plugin_root = vim.fn.fnamemodify(me, ":h:h") -- .../<repo-root> (the runtimepath entry)
vim.opt.runtimepath:append(plugin_root)

local health = require("pi-bridge.health")

local fails = 0
local function check(cond, msg)
  if not cond then
    io.stderr:write("FAIL: " .. msg .. "\n")
    fails = fails + 1
  end
end

-- (1) require loads + check is a function + min_nvim is the floor
check(type(health) == "table", "require('pi-bridge.health') returns a table")
check(type(health.check) == "function", "check is a function")
check(health.min_nvim == "0.11", "min_nvim == '0.11'")

-- (2) check() runs without throwing + emits >= 1 start() section, with a captured vim.health
do
  local captured = {}
  local function stub(method)
    return function(msg, advice)
      captured[#captured + 1] = { method = method, msg = msg, advice = advice }
    end
  end
  local real_health = vim.health
  vim.health = {
    start = stub("start"),
    ok = stub("ok"),
    warn = stub("warn"),
    error = stub("error"),
    info = stub("info"),
  }
  -- dormant state (no env var) — the default, but be explicit
  local real_env = vim.env.PI_NVIM_BRIDGE
  vim.env.PI_NVIM_BRIDGE = nil

  local ok, err = pcall(health.check)
  check(ok, "check() does not throw" .. (ok and "" or (" (err=" .. tostring(err) .. ")")))

  local n_start = 0
  for _, c in ipairs(captured) do
    if c.method == "start" then n_start = n_start + 1 end
  end
  check(n_start >= 1, "check() emits >= 1 start() section (got " .. n_start .. ")")

  -- a couple of captured lines for human eyeballing (optional)
  for i = 1, math.min(6, #captured) do
    io.stdout:write(("[smoke] %s: %s\n"):format(captured[i].method:upper(), tostring(captured[i].msg)))
  end

  vim.env.PI_NVIM_BRIDGE = real_env
  vim.health = real_health
end

-- (3) the shell-completion section start()s in BOTH dormant and active sessions.
-- Sets a fake PI_NVIM_BRIDGE (active path) + a fake shell module so status()/resolve_shell()
-- are deterministic; asserts check() never throws + the 'pi-bridge shell completion'
-- section is among the captured start() calls.
do
  local captured = {}
  local function stub(method)
    return function(msg, advice)
      captured[#captured + 1] = { method = method, msg = msg, advice = advice }
    end
  end
  local real_health = vim.health
  vim.health = {
    start = stub("start"), ok = stub("ok"), warn = stub("warn"), error = stub("error"), info = stub("info"),
  }
  local real_env = vim.env.PI_NVIM_BRIDGE
  vim.env.PI_NVIM_BRIDGE =
    '{"transport":"unix","path":"/tmp/x.sock","token":"t","pid":1,"cwd":"/tmp","fdAvailable":false,"serverVersion":"0.1.0"}'
  -- a fake shell module so the section's resolve/status probes are deterministic (no spawn)
  local real_shell = package.loaded["pi-bridge.shell"]
  package.loaded["pi-bridge.shell"] = {
    resolve_shell = function(_p) return "/bin/zsh", "$SHELL" end,
    pick_driver = function(_r) return { start = function() end } end,
    status = function()
      return { shell = nil, driver_basename = "", proc_alive = false, inflight = false, failed = false, parse_failures = 0 }
    end,
  }
  local real_notify = package.loaded["pi-bridge.notify"]
  package.loaded["pi-bridge.notify"] = { did_notify = function(_c) return false end, once = function() end }

  local ok, err = pcall(health.check)
  check(ok, "check() does not throw in the active shell section" .. (ok and "" or (" (err=" .. tostring(err) .. ")")))

  local shell_section = false
  for _, c in ipairs(captured) do
    if c.method == "start" and tostring(c.msg):find("shell completion", 1, true) then
      shell_section = true
      break
    end
  end
  check(shell_section, "check() renders the 'pi-bridge shell completion' section")

  vim.env.PI_NVIM_BRIDGE = real_env
  vim.health = real_health
  package.loaded["pi-bridge.shell"] = real_shell
  package.loaded["pi-bridge.notify"] = real_notify
end

if fails > 0 then
  io.stderr:write(fails .. " check(s) failed\n")
  vim.cmd("cquit 1")
end
io.stdout:write("SMOKE_PASS\n")