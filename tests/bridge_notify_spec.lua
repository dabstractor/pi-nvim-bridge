-- === tests/bridge_notify_spec.lua — plenary/busted spec (the Level-2 gate) ===
-- Covers every Success Criterion from PRP P2.M5.T16.S27. Mirrors bridge_request_spec.lua
-- (S26): each case spins its OWN luv unix-socket server (unique socket path) for isolation,
-- decodes client requests via the S23 jsonlreader, and behaves per opts.mode:
--   "notify" — after the hello reply, push a RAW commandsChanged notification line
--              (the EXACT wire form the S17 server emits: no id, no params).
--   "echo"   — reply {id, result={ok=true, n=seq}} for each request (for interleaving).
--   "slow"   — accept, never reply (per-request timeout; for the interleaving case where
--              the server sends commandsChanged THEN the response).
--
-- Run (from the repo root):
--   nvim --headless --clean -u tests/minimal_init.lua \
--     -c 'lua require("plenary.busted").run("tests/bridge_notify_spec.lua")'
local uv = vim.uv
local bridge = require("pi-bridge.bridge")
local jreader = require("pi-bridge.jsonlreader")
local pi = require("pi-bridge")

if pi.config == nil then pi.setup({}) end -- self-sufficient (mirror smoke.lua GOTCHA D)

local DESC_CWD = "/tmp/proj"
local TOKEN = "deadbeefdeadbeefdeadbeefdeadbeef"

-- The EXACT wire form the DONE S17 server emits (verified by its REAL test:
-- parsed.jsonrpc=="2.0", parsed.method=="commandsChanged", NOT ("id" in parsed),
-- NOT ("params" in parsed)). Written RAW so the spec asserts what production actually
-- sends — do NOT build it with vim.json.encode({params={}}) (that would emit "params":{}).
local NOTIFY_LINE = '{"jsonrpc":"2.0","method":"commandsChanged"}\n'

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
--- pending map / next_id / notification_handlers do not leak across tests. S27's close()
--- clearing notification_handlers makes it sufficient. Idempotent + never throws.
local function reset_module()
  pcall(function() bridge.close() end)
  pi.bridge = nil -- clear a success-case publication (close() already niled server_info)
end

--- A fresh luv server mirroring the bridge extension's IPC. Spins a unique socket path,
--- decodes client messages via the jsonlreader, and behaves per opts.mode. Calls
--- spec(path, opts, stop, seen, server_send).
---
--- NOTE: do NOT name a spec-local table `pending` — it shadows plenary.busted's global
--- `pending` (the test-SKIP function). We use `fired`/`got` locals to observe behavior.
local function with_request_server(opts, spec)
  return function()
    local path = "/tmp/pi-bridge-notify-" .. tostring(os.time()) .. "-" .. math.random(1e6) .. ".sock"
    os.remove(path)
    reset_module()
    local srv = uv.new_pipe(false)
    srv:bind(path)
    local srv_rx, srv_conn
    local seen = {}      -- every decoded client request the server saw (order-preserving)
    local seq = 0
    srv_rx = jreader.new(function(req)
      -- ALWAYS reply to the `hello` handshake with a valid HelloResult so the handshake
      -- succeeds and pi.bridge == bridge (the S27 cases then layer on top).
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
        if opts.mode == "notify" then
          -- push a commandsChanged notification AFTER the hello reply (no id, no params —
          -- the EXACT wire form the S17 server emits). Note: we return here so the
          -- notification mode does not also route to the request behavior below.
          vim.defer_fn(function()
            if srv_conn and not srv_conn:is_closing() then
              srv_conn:write(NOTIFY_LINE)
            end
          end, 30)
        end
        return -- hello handled; do NOT route to the mode-keyed request behavior
      end
      seen[#seen + 1] = req
      seq = seq + 1
      local function reply(payload) -- payload is a Lua table; encode + LF
        if srv_conn and not srv_conn:is_closing() then
          srv_conn:write(vim.json.encode(payload) .. "\n")
        end
      end
      if opts.mode == "echo" then
        reply({ jsonrpc = "2.0", id = req.id, result = { ok = true, n = seq, method = req.method } })
      end
      -- "slow": do not reply (per-request timeout) — used by the interleaving case where
      --         the test drives server_send to emit commandsChanged THEN the response.
    end)
    srv:listen(128, function()
      srv_conn = uv.new_pipe(false)
      srv:accept(srv_conn)
      srv_conn:read_start(function(rerr, data)
        if rerr or data == nil then return end
        srv_rx:feed(data)
      end)
    end)
    --- Send a raw JSON line from the server to the client (for notify / interleaving control).
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
--- control to the inner spec. Mirrors the real activation flow (S25 then S27). Returns a
--- busted case function. server_opts + spec(path, opts, stop, seen, server_send, server_send_raw).
local function with_handshaken_server(server_opts, spec)
  return with_request_server(server_opts, function(path, opts, stop, seen, server_send, server_send_raw)
    -- run the handshake against THIS server (mode is ignored for the hello reply: always
    -- reply a valid HelloResult so the handshake succeeds and pi.bridge == bridge).
    local hs_err
    bridge.handshake(descriptor(path), function(err) hs_err = err end)
    vim.wait(300, function() return hs_err ~= nil or pi.bridge == bridge end, 5)
    assert.is_nil(hs_err, "pre-notification handshake failed: " .. tostring(hs_err))
    assert.is_true(pi.bridge == bridge, "handshake did not publish pi.bridge")
    spec(path, opts, stop, seen, server_send, server_send_raw)
  end)
end

describe("pi-bridge.bridge on_notification", function()
  before_each(function() reset_module() end)
  after_each(function() reset_module() end)

  -- (1) expose on_notification as a function
  it("exposes on_notification as a function", function()
    assert.are.equals("function", type(bridge.on_notification))
  end)

  -- (2) handler invoked on commandsChanged; params == nil (empty params omitted on the wire)
  it("fires the registered handler on commandsChanged with params == nil",
    with_handshaken_server({ mode = "notify" }, function(path, _opts, stop)
      local fired, got_params
      bridge.on_notification("commandsChanged", function(params)
        fired = true
        got_params = params
      end)
      vim.wait(500, function() return fired end, 5)
      assert.is_true(fired, "handler did not fire on commandsChanged")
      assert.is_nil(got_params, "params must be nil (empty params omitted on the wire)")
      stop()
    end))

  -- (3) schedule_wrap'd / safe — handler body calls vim.api.* WITHOUT throwing E5560
  --     (indirect proof the handler ran on the nvim main loop, not libuv fast context)
  it("runs the handler on the nvim main loop (vim.api.* does not throw E5560)",
    with_handshaken_server({ mode = "notify" }, function(path, _opts, stop)
      local buf = vim.api.nvim_create_buf(false, true)
      local fired, threw
      bridge.on_notification("commandsChanged", function(_params)
        fired = true
        -- vim.api.* throws E5560 if invoked from libuv fast context. schedule_wrap defers
        -- this to the nvim main loop, so it must NOT throw here.
        local ok, err = pcall(vim.api.nvim_buf_set_var, buf, "notify_ran", true)
        threw = not ok and tostring(err) or nil
      end)
      vim.wait(500, function() return fired end, 5)
      assert.is_true(fired)
      assert.is_nil(threw, "vim.api.* threw inside the handler: " .. tostring(threw))
      assert.is_true(vim.api.nvim_buf_get_var(buf, "notify_ran"))
      vim.api.nvim_buf_delete(buf, { force = true })
      stop()
    end))

  -- (4) client sends NO response to a notification — the server's decoder saw only `hello`
  --     (JSON-RPC section 4: "The Server MUST NOT reply to a Notification" — and the client
  --      must not reply to a server notification either).
  it("sends NO response to a notification (server saw only hello)",
    with_handshaken_server({ mode = "notify" }, function(path, _opts, stop, seen)
      bridge.on_notification("commandsChanged", function(_params) end)
      vim.wait(500, function() return true end, 5) -- let the notification arrive + be dispatched
      -- the server only ever decoded the hello request (no client reply to the notification)
      assert.are.equals(0, #seen, "client must not send a reply to a notification; saw: " .. #seen)
      stop()
    end))

  -- (5) last-wins re-registration — register A then B; only B fires (A replaced, not leaked)
  it("replaces the prior handler on re-registration (last-wins; A does not fire)",
    with_handshaken_server({ mode = "notify" }, function(path, _opts, stop)
      local a_fired, b_fired = false, false
      bridge.on_notification("commandsChanged", function(_params) a_fired = true end)
      bridge.on_notification("commandsChanged", function(_params) b_fired = true end)
      vim.wait(500, function() return b_fired end, 5)
      assert.is_true(b_fired, "the last-registered handler (B) must fire")
      assert.is_false(a_fired, "the replaced handler (A) must NOT fire (last-wins)")
      stop()
    end))

  -- (6) on_notification(method, nil) removes — subsequent notification dropped, no throw
  it("removes the handler on on_notification(method, nil) and drops silently",
    with_handshaken_server({ mode = "notify" }, function(path, _opts, stop)
      local fired = false
      bridge.on_notification("commandsChanged", function(_params) fired = true end)
      bridge.on_notification("commandsChanged", nil) -- remove
      vim.wait(500, function() return fired end, 5)
      assert.is_false(fired, "a removed handler must not fire")
      stop()
    end))

  -- (7) no handler registered — notification silently dropped, no throw (PRD section 11)
  it("silently drops a notification with NO registered handler (no throw)",
    with_handshaken_server({ mode = "notify" }, function(path, _opts, stop)
      -- do NOT register any handler; the notification must be silently dropped
      local ok = pcall(function()
        vim.wait(500, function() return false end, 5) -- just let the notification arrive
      end)
      assert.is_true(ok, "dropping an unhandled notification must not throw")
      stop()
    end))

  -- (8) interleaving — fire getSuggestions; server sends commandsChanged THEN the
  --     getSuggestions response; BOTH the handler fires AND the request cb resolves with
  --     its own result (independent dispatch paths).
  it("interleaves a notification with an in-flight request (both resolve independently)",
    with_handshaken_server({ mode = "slow" }, function(path, _opts, stop, seen, server_send, server_send_raw)
      local notify_fired, got_params
      bridge.on_notification("commandsChanged", function(params)
        notify_fired = true
        got_params = params
      end)
      -- fire a getSuggestions request (server mode is "slow" — we drive the reply manually)
      local req_err, req_result
      local id = bridge.request("getSuggestions", { lines = { "/m" } }, function(e, r)
        req_err, req_result = e, r
      end)
      assert.is_not_nil(id)
      -- wait until the server has seen the request
      vim.wait(300, function() return #seen >= 1 end, 5)
      -- NOW the server sends commandsChanged THEN the getSuggestions response
      server_send_raw(NOTIFY_LINE)
      vim.wait(100) -- let the notification be dispatched (schedule_wrap -> next loop pass)
      server_send({ jsonrpc = "2.0", id = id, result = { ok = true, which = "interleaved" } })
      vim.wait(500, function() return notify_fired and req_result ~= nil end, 5)
      assert.is_true(notify_fired, "the notification handler must fire")
      assert.is_nil(got_params, "commandsChanged params are nil")
      assert.is_nil(req_err, "the request must resolve without error: " .. tostring(req_err))
      assert.is_not_nil(req_result)
      assert.are.equals("interleaved", req_result.which)
      stop()
    end))

  -- (9) close() clears the registry — register, handshake, close(), reconnect to a
  --     FRESH server WITHOUT re-registering, send a notification; the OLD handler does
  --     NOT fire (no leak across reconnects).
  it("close() clears the registry (a stale handler does not fire across reconnects)",
    with_request_server({ mode = "notify" }, function(path1, _opts, stop1)
      -- (a) register handler A + handshake on server 1 (the notify push happens after hello)
      local fired = false
      bridge.on_notification("commandsChanged", function(_params) fired = true end)
      local hs_err1
      bridge.handshake(descriptor(path1), function(e) hs_err1 = e end)
      vim.wait(500, function() return hs_err1 ~= nil or pi.bridge == bridge end, 5)
      assert.is_nil(hs_err1, "first handshake failed: " .. tostring(hs_err1))
      -- the notify push should have fired handler A (sanity: it was registered)
      vim.wait(500, function() return fired end, 5)
      assert.is_true(fired, "handler A should fire on the first connection")
      -- (b) close the transport — clears notification_handlers
      bridge.close()
      pi.bridge = nil
      vim.wait(100) -- let any pending schedule_wrap'd cb settle
      fired = false -- reset so we can detect a stale fire
      stop1() -- tear down server 1
      -- (c) spin a FRESH server 2 + handshake WITHOUT re-registering
      local path2 = "/tmp/pi-bridge-notify2-" .. tostring(os.time()) .. "-" .. math.random(1e6) .. ".sock"
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
            -- push the notification AFTER the hello reply
            vim.defer_fn(function()
              if srv2_conn and not srv2_conn:is_closing() then
                srv2_conn:write(NOTIFY_LINE)
              end
            end, 30)
          end
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
      -- (d) the notification was pushed — the OLD handler must NOT fire (registry cleared)
      vim.wait(500, function() return fired end, 5)
      assert.is_false(fired, "a stale handler must not fire after close() (no leak)")
      if srv2_conn and not srv2_conn:is_closing() then pcall(function() srv2_conn:close() end) end
      if srv2 and not srv2:is_closing() then pcall(function() srv2:close() end) end
      os.remove(path2)
      reset_module()
    end))

  -- (10) never-throws on bad args (non-string method, empty method, non-function handler, nil method)
  it("never throws on bad args (non-string / empty method, non-function handler)", function()
    reset_module()
    assert.has_no.errors(function()
      bridge.on_notification(nil, function() end)          -- nil method
      bridge.on_notification(123, function() end)          -- non-string method
      bridge.on_notification("", function() end)           -- empty method
      bridge.on_notification("commandsChanged", nil)       -- nil handler (remove) — fine
      bridge.on_notification("commandsChanged", "notafn")  -- non-function handler
      bridge.on_notification("commandsChanged", 42)        -- non-function handler
    end)
    reset_module()
  end)

  -- (11) defensive — a message with method AND a string id (a "request" shape) is NOT
  --      mis-routed to the notification handler (the type(msg.id)~="string" guard).
  it("does not route a method+string-id message to the notification handler",
    with_handshaken_server({ mode = "echo" }, function(path, _opts, stop, _seen, server_send)
      local fired = false
      bridge.on_notification("commandsChanged", function(_params) fired = true end)
      -- a "request" shape: method + a string id + a result (v1-impossible from the server,
      -- but defensive). The type(msg.id)~="string" guard must keep it out of the handler.
      server_send({ jsonrpc = "2.0", id = "9", method = "commandsChanged", result = { ok = true } })
      vim.wait(300, function() return fired end, 5)
      assert.is_false(fired, "a method+string-id message must NOT fire the notification handler")
      stop()
    end))

  -- (12) generic registry — a synthetic method routes to ITS own handler (forward-compat)
  it("routes a synthetic method to its own handler (generic registry)",
    with_handshaken_server({ mode = "echo" }, function(path, _opts, stop, _seen, server_send, server_send_raw)
      local fired = false
      bridge.on_notification("x/synthetic", function(_params) fired = true end)
      server_send_raw('{"jsonrpc":"2.0","method":"x/synthetic"}\n')
      vim.wait(300, function() return fired end, 5)
      assert.is_true(fired, "a synthetic method must route to its own handler")
      stop()
    end))

  -- (13) REGRESSION — handshake + request still route correctly with the notification
  --      branch present (the new branch did not swallow anything).
  it("regression: handshake then request still resolve (notification branch did not swallow)",
    with_handshaken_server({ mode = "echo" }, function(path, _opts, stop)
      assert.is_true(pi.bridge == bridge)
      local err, result
      bridge.request("ping", {}, function(e, r) err, result = e, r end)
      vim.wait(300, function() return err ~= nil or result ~= nil end, 5)
      assert.is_nil(err)
      assert.is_true(result.ok)
      stop()
    end))

  -- (14) S41 WIRING — registering the S41 handler via on_notification runs it on the
  --      REAL commandsChanged notification (the dispatch S27 + the behavior S41 compose).
  --      Observable: a populated menu is closed by on_commands_changed. (Most behavior
  --      stays in completion_spec — this proves the wire-up over a real socket.)
  it("S41 wiring: the on_notification-registered handler closes a stale menu on commandsChanged",
    with_handshaken_server({ mode = "notify" }, function(path, _opts, stop)
      local completion = require("pi-bridge.completion")
      local menu = require("pi-bridge.menu")
      -- populate the menu via the REAL seam (so is_open()==true before the notification)
      local buf = vim.api.nvim_create_buf(true, false)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "/mod" })
      local win = vim.api.nvim_get_current_win()
      vim.api.nvim_win_set_buf(win, buf)
      vim.wo[win].virtualedit = "onemore"
      vim.api.nvim_win_set_cursor(win, { 1, 3 })
      menu.attach()
      -- drive the result→menu seam directly so the menu OPENS (the server's notify mode
      -- doesn't echo getSuggestions; menu.on_results is the S31 consumer of completion's seam).
      -- This sets up the observable "stale menu open" state for the S41 handler to close.
      menu.on_results(buf, { { value = "/model", label = "model" } }, "/mo")
      vim.wait(200, function() return menu.is_open() end, 5)
      assert.is_true(menu.is_open(), "pre: the menu must be open before the notification")
      -- register the S41 handler (exactly as init.lua M.activate() does)
      bridge.on_notification("commandsChanged", function(_params)
        pcall(function() require("pi-bridge.completion").on_commands_changed() end)
      end)
      -- the server pushes the REAL commandsChanged notification (mode=notify → after hello)
      vim.wait(500, function() return not menu.is_open() end, 5)
      assert.is_false(menu.is_open(), "the S41 handler must close the stale menu on the real notification")
      vim.api.nvim_buf_delete(buf, { force = true })
      stop()
    end))
end)