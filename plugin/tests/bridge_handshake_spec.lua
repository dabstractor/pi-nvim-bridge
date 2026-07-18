-- === plugin/tests/bridge_handshake_spec.lua — plenary/busted spec (the Level-2 gate) ===
-- Covers every Success Criterion from PRP P2.M5.T15.S25. Mirrors the bridge_spec.lua (S24)
-- pattern: each case spins its OWN luv unix-socket server (unique socket path) for isolation,
-- decodes client requests via the S23 jsonlreader, and behaves per `opts.mode`:
--   "success"    — on hello with params.token==opts.token: reply HelloResult; keep open.
--   "bad_token"  — on any hello: reply {id,err:{code:-32600,message:"bad token"}} THEN close.
--   "malformed"  — on hello: reply {id:"h1"} (no result/error) THEN keep open.
--   "silent"     — accept then close immediately (no reply).
--   "slow"       — accept, never reply (for the timeout case).
--
-- Run (from the plugin/ directory):
--   nvim --headless --clean -u tests/minimal_init.lua \
--     -c 'lua require("plenary.busted").run("tests/bridge_handshake_spec.lua")'
local uv = vim.uv
local bridge = require("pi-editor.bridge")
local jreader = require("pi-editor.jsonlreader")
local pi = require("pi-editor")

if pi.config == nil then pi.setup({}) end -- self-sufficient (mirror smoke.lua GOTCHA D)

local DESC_CWD = "/tmp/proj"
local TOKEN = "deadbeefdeadbeefdeadbeefdeadbeef"

-- Build a valid descriptor (path is filled per-server; token is fixed).
local function descriptor(path)
  return {
    transport = "unix",
    path = path,
    token = TOKEN,
    pid = 1,
    cwd = DESC_CWD,
    fdAvailable = true,
    serverVersion = "0.1.0",
  }
end

--- Reset module state between cases so handshake_state / server_info / pi.bridge do not
--- leak across tests (the cleanup the PRP GOTCHA calls out). Idempotent + never throws.
local function reset_module()
  pcall(function() bridge.close() end)
  pi.bridge = nil -- clear a success-case publication (close() already niled server_info)
end

--- A fresh luv server mirroring the bridge extension's hello semantics. Spins a unique
--- socket path, decodes client requests, and behaves per `opts.mode`. Calls
--- `spec(path, opts, stop)`.
local function with_hello_server(opts, spec)
  return function()
    local path = "/tmp/pi-bridge-hs-" .. tostring(os.time()) .. "-" .. math.random(1e6) .. ".sock"
    os.remove(path)
    reset_module()
    local srv = uv.new_pipe(false)
    srv:bind(path)
    local srv_rx, srv_conn
    srv_rx = jreader.new(function(req)
      if opts.mode == "success" then
        if req.method == "hello" then
          srv_conn:write(vim.json.encode({
            jsonrpc = "2.0", id = "h1",
            result = {
              ok = true,
              serverVersion = "0.1.0",
              cwd = opts.cwd or DESC_CWD,
              fdAvailable = (opts.fdAvailable == nil) and true or opts.fdAvailable,
            },
          }) .. "\n")
        end
      elseif opts.mode == "bad_token" then
        srv_conn:write(vim.json.encode({
          jsonrpc = "2.0", id = "h1",
          error = { code = -32600, message = "bad token" },
        }) .. "\n")
        if srv_conn and not srv_conn:is_closing() then srv_conn:close() end
      elseif opts.mode == "malformed" then
        srv_conn:write(vim.json.encode({ jsonrpc = "2.0", id = "h1" }) .. "\n") -- no result/error
      end
      -- "silent" / "slow": do not reply
    end)
    srv:listen(128, function()
      srv_conn = uv.new_pipe(false)
      srv:accept(srv_conn)
      if opts.mode == "silent" then
        -- accept then close immediately (no reply)
        srv_conn:close()
        return
      end
      srv_conn:read_start(function(rerr, data)
        if rerr or data == nil then return end
        srv_rx:feed(data)
      end)
    end)
    local function stop()
      if srv_conn and not srv_conn:is_closing() then pcall(function() srv_conn:close() end) end
      if srv and not srv:is_closing() then pcall(function() srv:close() end) end
      os.remove(path)
      reset_module()
    end
    spec(path, opts, stop)
  end
end

describe("pi-editor.bridge handshake", function()
  -- expose the module surface
  it("exposes handshake + version + server_info", function()
    assert.are.equals("function", type(bridge.handshake))
    assert.are.equals("string", type(bridge.version))
    assert.is_nil(bridge.server_info) -- nil until a successful handshake
  end)

  -- (a) SUCCESS — pi.bridge set, server_info populated, on_result(nil, info)
  it("sends hello and publishes pi.bridge + server_info on success",
    with_hello_server({ mode = "success" }, function(path, opts, stop)
      local err, info
      bridge.handshake(descriptor(path), function(e, i) err, info = e, i end)
      vim.wait(300, function() return err ~= nil or info ~= nil end, 5)
      assert.is_nil(err, "expected success, got err=" .. tostring(err))
      assert.is_not_nil(info)
      assert.are.equals("0.1.0", info.serverVersion)
      assert.are.equals(opts.cwd or DESC_CWD, info.cwd)
      assert.is_true(info.fdAvailable)
      assert.is_true(pi.bridge == bridge, "pi.bridge should be the bridge module")        -- the placeholder is now THIS module
      assert.are.equals("0.1.0", bridge.server_info.serverVersion)
      stop()
    end))

  -- (a-cont) the wire envelope is EXACTLY {jsonrpc,id:"h1",method:"hello",params:{token,client,clientVersion}}
  it("sends the exact hello envelope (id h1, client pi-editor.nvim, clientVersion M.version)",
    with_hello_server({ mode = "success" }, function(path, _opts, stop)
      -- intercept the raw client write via a server-side read_cb capture
      local captured
      local srv = uv.new_pipe(false)
      local p2 = path .. "-wire"
      os.remove(p2)
      srv:bind(p2)
      srv:listen(128, function()
        local conn = uv.new_pipe(false)
        srv:accept(conn)
        conn:read_start(function(_rerr, data)
          if data then captured = data end
          if data == nil then return end
        end)
      end)
      bridge.handshake(descriptor(p2), function() end)
      vim.wait(300, function() return captured ~= nil end, 5)
      local line = captured and captured:match("^([^\n]+)\n$")
      assert.is_not_nil(line, "expected a LF-terminated JSON line")
      local ok, env = pcall(vim.json.decode, line)
      assert.is_true(ok, "envelope must be valid JSON")
      assert.are.equals("2.0", env.jsonrpc)
      assert.are.equals("h1", env.id)
      assert.are.equals("hello", env.method)
      assert.are.equals(TOKEN, env.params.token)
      assert.are.equals("pi-editor.nvim", env.params.client)
      assert.are.equals(bridge.version, env.params.clientVersion)
      if srv and not srv:is_closing() then pcall(function() srv:close() end) end
      os.remove(p2)
      stop()
    end))

  -- (b) BAD TOKEN — error -32600 then close; pi.bridge stays nil; on_result(err)
  it("reports an error and leaves pi.bridge nil on a -32600 bad-token response",
    with_hello_server({ mode = "bad_token" }, function(path, _opts, stop)
      local err, info
      bridge.handshake(descriptor(path), function(e, i) err, info = e, i end)
      vim.wait(300, function() return err ~= nil end, 5)
      assert.is_not_nil(err, "expected an error")
      assert.is_nil(info)
      assert.is_nil(pi.bridge)               -- stays nil
      assert.is_nil(bridge.server_info)      -- stays nil
      assert.is_false(bridge.is_connected()) -- transport closed
      -- the token value MUST NEVER appear in the error string (PRD §12)
      assert.is_nil(string.find(err or "", TOKEN, 1, true))
      stop()
    end))

  -- (c) MALFORMED response (no result/error) — failure path
  it("treats a malformed (no result/error) response as failure",
    with_hello_server({ mode = "malformed" }, function(path, _opts, stop)
      local err, info
      bridge.handshake(descriptor(path), function(e, i) err, info = e, i end)
      vim.wait(300, function() return err ~= nil end, 5)
      assert.is_not_nil(err)
      assert.is_nil(info)
      assert.is_nil(pi.bridge)
      stop()
    end))

  -- (d) SILENT SERVER CLOSE — on_result(err); pi.bridge nil; no throw
  it("reports an error on silent server close and leaves pi.bridge nil",
    with_hello_server({ mode = "silent" }, function(path, _opts, stop)
      local err, info
      bridge.handshake(descriptor(path), function(e, i) err, info = e, i end)
      vim.wait(300, function() return err ~= nil end, 5)
      assert.is_not_nil(err)
      assert.is_nil(info)
      assert.is_nil(pi.bridge)
      stop()
    end))

  -- (e) CONNECT FAILURE (ENOENT) — on_result(errno); no socket touched
  it("reports on_result('ENOENT') for a nonexistent socket and never throws", function()
    reset_module()
    local err, info
    assert.has_no.errors(function()
      bridge.handshake(descriptor("/tmp/pi-bridge-none-" .. os.time() .. ".sock"),
        function(e, i) err, info = e, i end)
    end)
    vim.wait(300, function() return err ~= nil end, 5)
    assert.are.equals("ENOENT", err)
    assert.is_nil(info)
    assert.is_nil(pi.bridge)
    reset_module()
  end)

  -- (f) TIMEOUT (slow server, no reply within rpc_timeout_ms)
  it("fires on_result with a timeout message when the server never replies", function()
    reset_module()
    -- shrink the timeout so the test is fast; restore after.
    local saved = pi.config.rpc_timeout_ms
    pi.config.rpc_timeout_ms = 80
    local path = "/tmp/pi-bridge-slow-" .. os.time() .. "-" .. math.random(1e6) .. ".sock"
    os.remove(path)
    local srv = uv.new_pipe(false)
    srv:bind(path)
    srv:listen(128, function()
      local _conn = uv.new_pipe(false)
      srv:accept(_conn) -- accept, NEVER reply (slow)
    end)
    local err, info
    bridge.handshake(descriptor(path), function(e, i) err, info = e, i end)
    vim.wait(500, function() return err ~= nil end, 5)
    assert.is_not_nil(err)
    assert.is_nil(info)
    assert.is_nil(pi.bridge)
    assert.is_not_nil(string.find(err, "timeout", 1, true))
    pi.config.rpc_timeout_ms = saved
    if srv and not srv:is_closing() then pcall(function() srv:close() end) end
    os.remove(path)
    reset_module()
  end)

  -- (g) EXACTLY-ONCE: on_result fires exactly once across the response+timeout race
  it("fires on_result EXACTLY ONCE (response wins the race over the timeout)",
    with_hello_server({ mode = "success" }, function(path, _opts, stop)
      local count = 0
      -- shrink the timeout so the timer is ARMED and racing while the response also arrives.
      local saved = pi.config.rpc_timeout_ms
      pi.config.rpc_timeout_ms = 60
      bridge.handshake(descriptor(path), function() count = count + 1 end)
      vim.wait(300, function() return count >= 1 end, 5)
      vim.wait(120) -- let any overdue timer fire (it must NOT — pending already false)
      assert.are.equals(1, count, "on_result must fire EXACTLY once")
      pi.config.rpc_timeout_ms = saved
      stop()
    end))

  -- (h) INVALID DESCRIPTOR — on_result("invalid descriptor"); no socket touched
  it("calls on_result('invalid descriptor') for nil/missing-token desc and touches no socket",
    function()
      reset_module()
      -- nil desc, missing token, empty token, wrong path type each call cb with the reason.
      for _, case in ipairs({
        { desc = nil },
        { desc = { path = "/tmp/x", token = nil } },
        { desc = { path = "/tmp/x", token = "" } },
        { desc = { path = 123, token = "t" } },
      }) do
        local got
        local function cb(e) got = e end
        bridge.handshake(case.desc, cb)
        assert.are.equals("invalid descriptor", got, "expected invalid-descriptor error")
      end
      -- a non-function on_result must NOT throw and must NOT touch any socket.
      assert.has_no.errors(function() bridge.handshake(nil, "not a function") end)
      assert.is_false(bridge.is_connected()) -- no socket ever touched
      reset_module()
    end)

  -- (i) NEVER THROWS — the whole handshake surface is pcall-safe
  it("never throws on a bad descriptor / connect failure / silent close", function()
    reset_module()
    assert.has_no.errors(function()
      bridge.handshake(nil, function() end)
      bridge.handshake({ path = "/tmp/x", token = "t" }, function() end)
      bridge.handshake(descriptor("/tmp/pi-bridge-none2-" .. os.time() .. ".sock"), function() end)
    end)
    reset_module()
  end)

  -- (j) CLOSE() clears server_info (reconnect hygiene). pi.bridge is the caller's
  -- reference and is intentionally NOT reset by close() (it is nilled in test cleanup).
  it("clears server_info on close() after a success",
    with_hello_server({ mode = "success" }, function(path, _opts, stop)
      local err, info
      bridge.handshake(descriptor(path), function(e, i) err, info = e, i end)
      vim.wait(300, function() return info ~= nil end, 5)
      assert.is_not_nil(bridge.server_info)
      assert.is_true(pi.bridge == bridge, "pi.bridge should be the bridge module")
      bridge.close()
      assert.is_nil(bridge.server_info) -- cleared with the transport
      stop()
    end))
end)