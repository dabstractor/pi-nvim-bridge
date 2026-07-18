-- === plugin/tests/bridge_smoke.lua — standalone (plenary-FREE) smoke test ===
-- The Level-1 validation gate: instant, dependency-free feedback (no plenary).
--
-- Spins a REAL luv unix-socket server in-process (mirroring the bridge extension), then
-- exercises bridge.connect / send / close end-to-end:
--   CASE 1: connect success + is_connected + send round-trip + on_event (decoded table)
--   CASE 2: connect failure (ENOENT) -> bare errno string
--   CASE 3: double-close safe + on_exit no-op-when-not-connected
--
-- Run from the REPO ROOT:
--   nvim --headless --clean -u NORC +"luafile plugin/tests/bridge_smoke.lua" +qa
--   echo "exit=$?   # 0 = pass (prints 'SMOKE_PASS'), 1 = a check failed"
--
-- NO `:lua <<HEREDOC` in a -c/+ arg (inherited S19 GOTCHA #10 — source via :luafile).
local me = debug.getinfo(1, "S").source:sub(2)
me = vim.fn.fnamemodify(me, ":p")
local plugin_root = vim.fn.fnamemodify(me, ":h:h") -- .../plugin (the runtimepath entry)
vim.opt.runtimepath:append(plugin_root)

local uv = vim.uv
local bridge = require("pi-editor.bridge")
local jreader = require("pi-editor.jsonlreader")

local fails = 0
local function check(cond, msg)
  if not cond then
    io.stderr:write("FAIL: " .. msg .. "\n")
    fails = fails + 1
  end
end

-- helper: spin a luv unix-socket server that mirrors the bridge extension (decodes the
-- client's JSONL, echoes a JSONL response for each request). Returns (path, stop_fn).
local function start_server(on_request)
  local path = "/tmp/pi-bridge-smoke-" .. tostring(os.time()) .. "-" .. math.random(1e6) .. ".sock"
  os.remove(path)
  local srv = uv.new_pipe(false)
  srv:bind(path)
  local srv_conn
  local srv_rx = jreader.new(function(req)
    if req.id and srv_conn and not srv_conn:is_closing() then
      local resp = vim.json.encode({ jsonrpc = "2.0", id = req.id, result = { ok = true } }) .. "\n"
      srv_conn:write(resp)
    end
    if on_request then on_request(req) end
  end)
  srv:listen(128, function()
    srv_conn = uv.new_pipe(false)
    srv:accept(srv_conn)
    srv_conn:read_start(function(rerr, data)
      if rerr or data == nil then
        if data == nil and srv_conn and not srv_conn:is_closing() then srv_conn:close() end
        return
      end
      srv_rx:feed(data)
    end)
  end)
  return path, function()
    if srv_conn and not srv_conn:is_closing() then pcall(function() srv_conn:close() end) end
    if srv and not srv:is_closing() then pcall(function() srv:close() end) end
    os.remove(path)
  end
end

-- ── CASE 1: connect success + send round-trip + on_event ───────────────────
do
  local path, stop = start_server()
  local got_ready, got_event, got_msg
  bridge.connect(
    path,
    function(err) got_ready = err end,                   -- on_ready
    function(msg) got_event = true; got_msg = msg end,   -- on_event
    function(reason) end                                 -- on_close
  )
  vim.wait(200, function() return got_ready ~= nil end, 10) -- wait for connect
  check(got_ready == nil, "connect success: on_ready(nil) (got " .. tostring(got_ready) .. ")")
  check(bridge.is_connected(), "is_connected() true after on_ready(nil)")
  bridge.send({ jsonrpc = "2.0", id = "r1", method = "ping", params = {} })
  vim.wait(200, function() return got_event end, 10) -- wait for echo response
  check(
    got_event and got_msg and got_msg.id == "r1" and got_msg.result and got_msg.result.ok,
    "send round-trip: on_event got the response {id=r1, result.ok=true}"
  )
  stop()
  vim.wait(100) -- let on_close(EOF) settle
end

-- ── CASE 2: connect failure (ENOENT) — bare errno string ───────────────────
do
  local got
  bridge.connect(
    "/tmp/pi-bridge-nope-" .. os.time() .. ".sock",
    function(err) got = err end,
    function() end,
    function() end
  )
  vim.wait(200, function() return got ~= nil end, 10)
  check(got == "ENOENT", "connect nonexistent -> on_ready('ENOENT') (got " .. tostring(got) .. ")")
  check(not bridge.is_connected(), "is_connected() false after connect failure")
end

-- ── CASE 3: double-close safe + on_exit no-op ──────────────────────────────
do
  bridge.close()
  bridge.close() -- must NOT throw (GOTCHA 2 — guarded)
  bridge.on_exit(0) -- no-op when not connected (GOTCHA 12)
  check(true, "double-close + on_exit(no-connect): no throw")
end

if fails > 0 then
  io.stderr:write(fails .. " check(s) failed\n")
  vim.cmd("cquit 1")
end
io.stdout:write("SMOKE_PASS\n")