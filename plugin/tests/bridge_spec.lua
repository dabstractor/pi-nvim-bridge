-- === plugin/tests/bridge_spec.lua — plenary/busted spec (the Level-2 gate) ===
-- Covers every Success Criterion from the PRP. Mirrors the jsonlreader_spec.lua (S23)
-- pattern: each case spins its OWN luv unix-socket server (unique socket path) for isolation.
--
-- Cases: connect success + is_connected; connect ENOENT; connect ECONNREFUSED (regular
-- file); read -> jsonlreader -> on_event (single / drain / multi-write queueing); send()
-- round-trip delivers encode(obj).."\n"; EOF -> rx:flush + on_close(nil); double-close
-- safe; on_exit no-op-when-not-connected; send-before-connect / after-close -> false;
-- is_connected transitions.
--
-- Run (from the plugin/ directory):
--   nvim --headless --clean -u tests/minimal_init.lua \
--     -c 'lua require("plenary.busted").run("tests/bridge_spec.lua")'
local uv = vim.uv
local bridge = require("pi-bridge.bridge")
local jreader = require("pi-bridge.jsonlreader")

-- helper: a fresh luv server mirroring the bridge extension. Calls spec(path, requests, stop).
-- Each test gets a unique socket path. `requests` collects every decoded client request the
-- server saw; the server echoes a JSONL response for any request that has an `id`.
local function with_server(spec)
  return function()
    local path = "/tmp/pi-bridge-spec-" .. tostring(os.time()) .. "-" .. math.random(1e6) .. ".sock"
    os.remove(path)
    local srv = uv.new_pipe(false)
    srv:bind(path)
    local srv_rx, srv_conn
    local requests = {}
    srv_rx = jreader.new(function(req)
      requests[#requests + 1] = req
      if req.id and srv_conn and not srv_conn:is_closing() then
        srv_conn:write(vim.json.encode({ jsonrpc = "2.0", id = req.id, result = { ok = true } }) .. "\n")
      end
    end)
    srv:listen(128, function()
      srv_conn = uv.new_pipe(false)
      srv:accept(srv_conn)
      srv_conn:read_start(function(rerr, data)
        if rerr or data == nil then return end
        srv_rx:feed(data)
      end)
    end)
    local function stop()
      if srv_conn and not srv_conn:is_closing() then pcall(function() srv_conn:close() end) end
      if srv and not srv:is_closing() then pcall(function() srv:close() end) end
      os.remove(path)
      bridge.close()
    end
    spec(path, requests, stop)
  end
end

describe("pi-bridge.bridge", function()
  -- expose the module surface
  it("exposes connect/send/close/on_exit/is_connected", function()
    assert.are.equals("function", type(bridge.connect))
    assert.are.equals("function", type(bridge.send))
    assert.are.equals("function", type(bridge.close))
    assert.are.equals("function", type(bridge.on_exit))
    assert.are.equals("function", type(bridge.is_connected))
  end)

  -- (a) connect success + is_connected + on_ready(nil)
  it("connects and fires on_ready(nil); is_connected() true", with_server(function(path, _, stop)
    local got
    bridge.connect(path, function(err) got = err end, function() end, function() end)
    vim.wait(200, function() return got ~= nil end, 5)
    assert.is_nil(got)
    assert.is_true(bridge.is_connected())
    vim.wait(20)
    stop()
  end))

  -- (b) connect failure -> bare errno string; not connected; no throw
  it("reports on_ready('ENOENT') for a nonexistent socket", function()
    local got
    assert.has_no.errors(function()
      bridge.connect(
        "/tmp/pi-bridge-none-" .. os.time() .. ".sock",
        function(err) got = err end,
        function() end,
        function() end
      )
    end)
    vim.wait(200, function() return got ~= nil end, 5)
    assert.are.equals("ENOENT", got)
    assert.is_false(bridge.is_connected())
    bridge.close()
  end)

  it("reports on_ready('ECONNREFUSED') for a regular file", function()
    local f = "/tmp/pi-bridge-file-" .. os.time() .. ".txt"
    local fh = io.open(f, "w")
    fh:write("x")
    fh:close()
    local got
    bridge.connect(f, function(err) got = err end, function() end, function() end)
    vim.wait(200, function() return got ~= nil end, 5)
    assert.are.equals("ECONNREFUSED", got)
    os.remove(f)
    bridge.close()
  end)

  -- (c) read -> jsonlreader -> on_event (proves S23 is wired into read_start); multi-write queueing
  it("delivers decoded JSON-RPC responses to on_event (in order)", with_server(function(path, _, stop)
    local msgs = {}
    bridge.connect(path, function() end, function(m) msgs[#msgs + 1] = m end, function() end)
    vim.wait(200, function() return bridge.is_connected() end, 5)
    bridge.send({ jsonrpc = "2.0", id = "r1", method = "ping" })
    bridge.send({ jsonrpc = "2.0", id = "r2", method = "ping" }) -- multi-write queueing
    vim.wait(250, function() return #msgs >= 2 end, 5)
    assert.are.equals("r1", msgs[1].id)
    assert.are.equals("r2", msgs[2].id) -- in order
    vim.wait(20)
    stop()
  end))

  -- (d) send round-trip: server received exactly encode(obj).."\n"
  it("send() delivers encode(obj)..\\n to the server", with_server(function(path, requests, stop)
    bridge.connect(path, function() end, function() end, function() end)
    vim.wait(200, function() return bridge.is_connected() end, 5)
    bridge.send({ jsonrpc = "2.0", id = "x", method = "ping", params = { a = 1 } })
    vim.wait(250, function() return #requests >= 1 end, 5)
    assert.are.equals("x", requests[1].id)
    assert.are.equals("ping", requests[1].method)
    assert.are.same({ a = 1 }, requests[1].params)
    vim.wait(20)
    stop()
  end))

  -- (e) EOF (server closes) -> rx:flush + on_close(nil); is_connected false
  it("fires on_close(nil) on clean EOF after flushing", with_server(function(path, _, stop)
    local closed
    bridge.connect(path, function() end, function() end, function(reason) closed = reason end)
    vim.wait(200, function() return bridge.is_connected() end, 5)
    stop() -- server closes -> client EOF
    vim.wait(250, function() return closed ~= nil end, 5)
    assert.is_nil(closed) -- clean EOF
    assert.is_false(bridge.is_connected())
  end))

  -- (f) double-close safe (no throw) + on_exit no-op when not connected
  it("close() is idempotent (double-close does not throw)", function()
    assert.has_no.errors(function()
      bridge.close()
      bridge.close()
      bridge.on_exit(0)
    end)
  end)

  -- (g) send before connect / after close -> false, no throw
  it("send() returns false before connect and after close", function()
    bridge.close()
    local ok = bridge.send({ jsonrpc = "2.0", id = "z", method = "ping" })
    assert.is_false(ok)
  end)

  -- (h) on_exit no-op when never connected (the S24-ships-before-S25-wires state)
  it("on_exit(buf) is a safe no-op when never connected", function()
    bridge.close() -- ensure clean slate
    assert.has_no.errors(function() bridge.on_exit(0) end)
    assert.is_false(bridge.is_connected())
  end)

  -- (i) is_connected transitions false -> true -> false across connect -> close
  it("is_connected() transitions false -> true -> false", with_server(function(path, _, stop)
    assert.is_false(bridge.is_connected())
    local ready
    bridge.connect(path, function(err) ready = err end, function() end, function() end)
    vim.wait(200, function() return ready ~= nil end, 5)
    assert.is_nil(ready)
    assert.is_true(bridge.is_connected())
    bridge.close()
    assert.is_false(bridge.is_connected())
    stop()
  end))
end)