-- === tests/bridge_disconnect_spec.lua — plenary/busted spec (the Level-2 gate for S39) ===
-- Covers every Success Criterion of bridge.on_disconnect (the post-handshake pipe-drop
-- event consumer). MIRRORS bridge_notify_spec.lua (S27) VERBATIM for the harness:
-- `with_request_server(opts, spec)`, `with_handshaken_server(server_opts, spec)`,
-- `descriptor(path)`, `reset_module()`, the TOKEN/DESC_CWD constants, and the server's
-- hello-reply. The server additionally exposes a way to trigger a client-side disconnect:
--   "echo"   — after hello, accept/echo requests (for the regression case).
--   "close"  — after hello, the server half-closes its conn (srv_conn:close()) so the
--              client's read_cb sees EOF -> fires the disconnect handler.
--
-- Run (from the repo root):
--   nvim --headless --clean -u tests/minimal_init.lua \
--     -c 'lua require("plenary.busted").run("tests/bridge_disconnect_spec.lua")'
local uv = vim.uv
local bridge = require("pi-bridge.bridge")
local jreader = require("pi-bridge.jsonlreader")
local pi = require("pi-bridge")

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

--- Reset module state between cases so handshake_state / server_info / pi.bridge / the
--- pending map / next_id / notification_handlers / disconnect_handler do not leak across
--- tests. close() clearing disconnect_handler makes it sufficient. Idempotent + never throws.
local function reset_module()
  pcall(function() bridge.close() end)
  pi.bridge = nil -- clear a success-case publication (close() already niled server_info)
end

--- A fresh luv server mirroring the bridge extension's IPC. Spins a unique socket path,
--- decodes client messages via the jsonlreader, and behaves per opts.mode. Calls
--- spec(path, opts, stop, seen, server_send, server_send_raw, srv_conn_ref).
---
--- NOTE: do NOT name a spec-local table `pending` — it shadows plenary.busted's global
--- `pending` (the test-SKIP function). We use `fired`/`got` locals to observe behavior.
local function with_request_server(opts, spec)
  return function()
    local path = "/tmp/pi-bridge-disc-" .. tostring(os.time()) .. "-" .. math.random(1e6) .. ".sock"
    os.remove(path)
    reset_module()
    local srv = uv.new_pipe(false)
    srv:bind(path)
    local srv_rx, srv_conn
    local seen = {}      -- every decoded client request the server saw (order-preserving)
    local seq = 0
    srv_rx = jreader.new(function(req)
      -- ALWAYS reply to the `hello` handshake with a valid HelloResult so the handshake
      -- succeeds and pi.bridge == bridge (the disconnect cases then layer on top).
      if req.method == "hello" then
        if srv_conn and not srv_conn:is_closing() then
          srv_conn:write(vim.json.encode({
            jsonrpc = "2.0", id = req.id,
            result = {
              ok = true,
              serverVersion = "0.1.0",
              cwd = opts.cwd or DESC_CWD,
              fdAvailable = (opts.fdAvailable == nil) and true or opts.fdAvailable,
            },
          }) .. "\n")
        end
        if opts.mode == "close" then
          -- after the hello reply, half-close the server conn so the client's read_cb
          -- sees EOF -> fires the registered disconnect handler (reason == nil).
          vim.defer_fn(function()
            if srv_conn and not srv_conn:is_closing() then srv_conn:close() end
          end, 30)
        end
        return -- hello handled; do NOT route to the mode-keyed request behavior
      end
      seen[#seen + 1] = req
      seq = seq + 1
      if opts.mode == "echo" then
        if srv_conn and not srv_conn:is_closing() then
          srv_conn:write(vim.json.encode({
            jsonrpc = "2.0", id = req.id, result = { ok = true, n = seq, method = req.method },
          }) .. "\n")
        end
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
    --- Send a raw JSON line from the server to the client.
    local function server_send_raw(raw_line)
      if srv_conn and not srv_conn:is_closing() then
        srv_conn:write(raw_line)
      end
    end
    --- Send a JSON table as a line from the server to the client.
    local function server_send(payload)
      if srv_conn and not srv_conn:is_closing() then
        srv_conn:write(vim.json.encode(payload) .. "\n")
      end
    end
    local function stop()
      if srv_conn and not srv_conn:is_closing() then pcall(function() srv_conn:close() end) end
      if srv and not srv:is_closing() then pcall(function() srv:close() end) end
      os.remove(path)
      reset_module()
    end
    spec(path, opts, stop, seen, server_send, server_send_raw)
  end
end

--- Helper: perform a handshake FIRST (so dispatch is wired + state.connected), then hand
--- control to the inner spec. Mirrors the real activation flow (S25 then S39 disconnect).
local function with_handshaken_server(server_opts, spec)
  return with_request_server(server_opts, function(path, opts, stop, seen, server_send, server_send_raw)
    local hs_err
    bridge.handshake(descriptor(path), function(err) hs_err = err end)
    vim.wait(300, function() return hs_err ~= nil or pi.bridge == bridge end, 5)
    assert.is_nil(hs_err, "pre-disconnect handshake failed: " .. tostring(hs_err))
    assert.is_true(pi.bridge == bridge, "handshake did not publish pi.bridge")
    spec(path, opts, stop, seen, server_send, server_send_raw)
  end)
end

describe("pi-bridge.bridge on_disconnect (S39)", function()
  before_each(function() reset_module() end)
  after_each(function() reset_module() end)

  -- (a) exposes on_disconnect as a function
  it("exposes on_disconnect as a function", function()
    assert.are.equals("function", type(bridge.on_disconnect))
  end)

  -- (b) fires the handler on server-side close (EOF) after a successful handshake, reason==nil
  it("fires the handler on server-side close (EOF) after handshake, reason==nil",
    with_handshaken_server({ mode = "close" }, function(path, _opts, stop)
      local fired, got_reason
      bridge.on_disconnect(function(reason)
        fired = true
        got_reason = reason
      end)
      vim.wait(500, function() return fired end, 5)
      assert.is_true(fired, "disconnect handler did not fire on EOF")
      assert.is_nil(got_reason, "reason must be nil for a clean EOF")
      assert.is_false(bridge.is_connected(), "is_connected() false after disconnect")
      stop()
    end))

  -- (d) runs the handler on the nvim main loop (vim.api.* does not throw E5560)
  it("runs the handler on the nvim main loop (vim.api.* does not throw E5560)",
    with_handshaken_server({ mode = "close" }, function(path, _opts, stop)
      local buf = vim.api.nvim_create_buf(false, true)
      local fired, threw
      bridge.on_disconnect(function(_reason)
        fired = true
        -- vim.api.* throws E5560 if invoked from libuv fast context. schedule_wrap defers
        -- this to the nvim main loop, so it must NOT throw here.
        local ok, err = pcall(vim.api.nvim_buf_set_var, buf, "disc_ran", true)
        threw = not ok and tostring(err) or nil
      end)
      vim.wait(500, function() return fired end, 5)
      assert.is_true(fired)
      assert.is_nil(threw, "vim.api.* threw inside the handler: " .. tostring(threw))
      assert.is_true(vim.api.nvim_buf_get_var(buf, "disc_ran"))
      vim.api.nvim_buf_delete(buf, { force = true })
      stop()
    end))

  -- (e) does NOT fire while a handshake is unresolved (handshake cb owns it)
  it("does NOT fire while a handshake is unresolved (handshake cb owns it)", function()
    -- a server that accepts the connect but NEVER replies to hello AND closes its conn
    -- so the client's read_cb sees EOF while handshake_state.pending == true.
    local path = "/tmp/pi-bridge-disc-hs-" .. tostring(os.time()) .. "-" .. math.random(1e6) .. ".sock"
    os.remove(path)
    reset_module()
    local srv = uv.new_pipe(false)
    srv:bind(path)
    local srv_conn
    srv:listen(128, function()
      srv_conn = uv.new_pipe(false)
      srv:accept(srv_conn)
      srv_conn:read_start(function(_rerr, _data) end) -- ignore; close below to trigger EOF
      -- close the server conn shortly AFTER accept so the client sees EOF mid-handshake
      vim.defer_fn(function()
        if srv_conn and not srv_conn:is_closing() then srv_conn:close() end
      end, 30)
    end)
    local disc_fired, hs_err = false, nil
    bridge.on_disconnect(function(_reason) disc_fired = true end)
    bridge.handshake(descriptor(path), function(err) hs_err = err end)
    vim.wait(500, function() return hs_err ~= nil end, 5)
    assert.is_not_nil(hs_err, "the handshake cb MUST fire (not the disconnect handler)")
    assert.is_false(disc_fired, "disconnect must NOT fire during an unresolved handshake")
    if srv and not srv:is_closing() then pcall(function() srv:close() end) end
    if srv_conn and not srv_conn:is_closing() then pcall(function() srv_conn:close() end) end
    os.remove(path)
    reset_module()
  end)

  -- (f) last-wins re-registration — register A then B; only B fires (A replaced, not leaked)
  it("replaces the prior handler on re-registration (last-wins; A does not fire)",
    with_handshaken_server({ mode = "close" }, function(path, _opts, stop)
      local a_fired, b_fired = false, false
      bridge.on_disconnect(function(_reason) a_fired = true end)
      bridge.on_disconnect(function(_reason) b_fired = true end)
      vim.wait(500, function() return b_fired end, 5)
      assert.is_true(b_fired, "the last-registered handler (B) must fire")
      assert.is_false(a_fired, "the replaced handler (A) must NOT fire (last-wins)")
      stop()
    end))

  -- (g) on_disconnect(nil) removes — subsequent drop does not fire
  it("removes the handler on on_disconnect(nil) and drops silently",
    with_handshaken_server({ mode = "close" }, function(path, _opts, stop)
      local fired = false
      bridge.on_disconnect(function(_reason) fired = true end)
      bridge.on_disconnect(nil) -- remove
      vim.wait(500, function() return fired end, 5)
      assert.is_false(fired, "a removed handler must not fire")
      stop()
    end))

  -- (h) no handler registered — a drop is silently swallowed (no throw)
  it("silently swallows a drop with NO registered handler (no throw)",
    with_handshaken_server({ mode = "close" }, function(path, _opts, stop)
      -- do NOT register any handler; the EOF must be silently swallowed
      local ok = pcall(function()
        vim.wait(500, function() return false end, 5) -- just let the EOF arrive
      end)
      assert.is_true(ok, "an unregistered disconnect must not throw")
      stop()
    end))

  -- (i) close() clears the slot — register, handshake, close, reconnect WITHOUT
  --     re-registering, drop; the OLD handler does NOT fire across the reconnect.
  it("close() clears the slot (a stale handler does not fire across reconnects)",
    with_request_server({ mode = "echo" }, function(path1, _opts, stop1)
      -- (a) register handler A + handshake on server 1 (mode echo so no auto-close)
      local fired = false
      bridge.on_disconnect(function(_reason) fired = true end)
      local hs_err1
      bridge.handshake(descriptor(path1), function(e) hs_err1 = e end)
      vim.wait(500, function() return hs_err1 ~= nil or pi.bridge == bridge end, 5)
      assert.is_nil(hs_err1, "first handshake failed: " .. tostring(hs_err1))
      -- (b) close the transport — clears disconnect_handler
      bridge.close()
      pi.bridge = nil
      vim.wait(100) -- let any pending schedule_wrap'd cb settle
      fired = false -- reset so we can detect a stale fire
      stop1() -- tear down server 1
      -- (c) spin a FRESH server 2 (mode close -> EOF after hello) + handshake WITHOUT re-registering
      local path2 = "/tmp/pi-bridge-disc2-" .. tostring(os.time()) .. "-" .. math.random(1e6) .. ".sock"
      os.remove(path2)
      local srv2 = uv.new_pipe(false)
      srv2:bind(path2)
      local srv2_rx, srv2_conn
      srv2_rx = jreader.new(function(req)
        if req.method == "hello" then
          if srv2_conn and not srv2_conn:is_closing() then
            srv2_conn:write(vim.json.encode({
              jsonrpc = "2.0", id = req.id,
              result = { ok = true, serverVersion = "0.1.0", cwd = DESC_CWD, fdAvailable = true },
            }) .. "\n")
          end
          -- after hello, half-close so the client's read_cb sees EOF
          vim.defer_fn(function()
            if srv2_conn and not srv2_conn:is_closing() then srv2_conn:close() end
          end, 30)
        end
      end)
      srv2:listen(128, function()
        srv2_conn = uv.new_pipe(false)
        srv2:accept(srv2_conn)
        srv2_conn:read_start(function(rerr, data)
          if rerr or data == nil then return end
          srv2_rx:feed(data)
        end)
      end)
      local hs_err2
      bridge.handshake(descriptor(path2), function(e) hs_err2 = e end)
      vim.wait(500, function() return hs_err2 ~= nil or pi.bridge == bridge end, 5)
      assert.is_nil(hs_err2, "second handshake failed: " .. tostring(hs_err2))
      assert.is_true(pi.bridge == bridge)
      -- (d) the EOF was pushed — the OLD handler must NOT fire (slot cleared by close())
      vim.wait(500, function() return fired end, 5)
      assert.is_false(fired, "a stale handler must not fire after close() (no leak)")
      if srv2_conn and not srv2_conn:is_closing() then pcall(function() srv2_conn:close() end) end
      if srv2 and not srv2:is_closing() then pcall(function() srv2:close() end) end
      os.remove(path2)
      reset_module()
    end))

  -- (j) never-throws on bad args (nil handler removes; non-function handler no-op)
  it("never throws on bad args (non-function handler, nil remove)", function()
    reset_module()
    assert.has_no.errors(function()
      bridge.on_disconnect(nil)           -- nil remove — fine
      bridge.on_disconnect("notafn")      -- non-function handler
      bridge.on_disconnect(42)            -- non-function handler
    end)
    reset_module()
  end)

  -- (k) REGRESSION — handshake + request still resolve with the disconnect branch present
  it("regression: handshake then request still resolve (disconnect branch did not swallow)",
    with_handshaken_server({ mode = "echo" }, function(path, _opts, stop)
      assert.is_true(pi.bridge == bridge)
      local err, result
      bridge.request("ping", {}, function(e, r) err, result = e, r end)
      vim.wait(300, function() return err ~= nil or result ~= nil end, 5)
      assert.is_nil(err)
      assert.is_true(result.ok)
      stop()
    end))
end)