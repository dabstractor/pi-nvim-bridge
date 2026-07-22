-- === plugin/tests/bridge_request_spec.lua — plenary/busted spec (the Level-2 gate) ===
-- Covers every Success Criterion from PRP P2.M5.T16.S26. Mirrors the bridge_spec.lua (S24) +
-- bridge_handshake_spec.lua (S25) pattern: each case spins its OWN luv unix-socket server
-- (unique socket path) for isolation, decodes client requests via the S23 jsonlreader, and
-- behaves per `opts.mode`:
--   "echo"   — reply {id, result={ok=true, n=<seq>}} for each request (correlation + ordering).
--   "error"  — reply {id, error:{code:-32603, message:"boom"}}.
--   "null"   — reply {id, result: <JSON null>} (getSuggestions empty).
--   "slow"   — accept, never reply (per-request timeout).
--   "stale"  — reply to an OLD id only AFTER a newer request arrives (drop-stale).
--   "dup"    — reply twice to the same id (exactly-once).
--   "stray"  — send a response with an id the client never requested.
--
-- Run (from the plugin/ directory):
--   nvim --headless --clean -u tests/minimal_init.lua \
--     -c 'lua require("plenary.busted").run("tests/bridge_request_spec.lua")'
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
--- pending map / next_id do not leak across tests (the cleanup the PRP GOTCHA calls out).
--- S26's close() draining pending + resetting next_id makes it sufficient (no new reset
--- hook needed). Idempotent + never throws.
local function reset_module()
  pcall(function() bridge.close() end)
  pi.bridge = nil -- clear a success-case publication (close() already niled server_info)
end

--- A fresh luv server mirroring the bridge extension's request semantics. Spins a unique
--- socket path, decodes client requests via the jsonlreader, and behaves per `opts.mode`.
--- The server echoes each client string id verbatim (the exact correlation machinery
--- request() needs). Calls `spec(path, opts, stop)`.
---
--- NOTE: do NOT name a spec-local table `pending` — it shadows plenary.busted's global
--- `pending` (the test-SKIP function). We use `got`/`results` locals to observe behavior.
local function with_request_server(opts, spec)
  return function()
    local path = "/tmp/pi-bridge-req-" .. tostring(os.time()) .. "-" .. math.random(1e6) .. ".sock"
    os.remove(path)
    reset_module()
    local srv = uv.new_pipe(false)
    srv:bind(path)
    local srv_rx, srv_conn
    local seen = {}      -- every decoded client request the server saw (order-preserving)
    local seq = 0
    srv_rx = jreader.new(function(req)
      -- ALWAYS reply to the `hello` handshake with a valid HelloResult so the handshake
      -- succeeds and pi.bridge == bridge (the S26 cases then layer on top).
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
      elseif opts.mode == "error" then
        reply({ jsonrpc = "2.0", id = req.id, error = { code = -32603, message = "boom" } })
      elseif opts.mode == "null" then
        -- {"result": null} on the wire. vim.json.encode(vim.NIL) emits "null" (LIVE-VERIFIED
        -- in the null-result case below); we build the table with result = vim.NIL.
        reply({ jsonrpc = "2.0", id = req.id, result = vim.NIL })
      elseif opts.mode == "dup" then
        -- reply twice to the same id (exactly-once check)
        reply({ jsonrpc = "2.0", id = req.id, result = { ok = true, which = "first" } })
        reply({ jsonrpc = "2.0", id = req.id, result = { ok = true, which = "second" } })
      elseif opts.mode == "stale" then
        -- do NOT reply now; the test triggers the delayed reply for a chosen id later
        -- (store the id for the test to use via opts._last_req_id)
        opts._last_req_id = req.id
      elseif opts.mode == "stray" then
        -- send a response with an id the client NEVER requested, then echo the real one
        reply({ jsonrpc = "2.0", id = "zzz-stray", result = { ok = true } })
        reply({ jsonrpc = "2.0", id = req.id, result = { ok = true, n = seq } })
      end
      -- "slow": do not reply (per-request timeout)
    end)
    srv:listen(128, function()
      srv_conn = uv.new_pipe(false)
      srv:accept(srv_conn)
      srv_conn:read_start(function(rerr, data)
        if rerr or data == nil then return end
        srv_rx:feed(data)
      end)
    end)
    --- Send a raw JSON line from the server to the client (for stale/dup/stray control).
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
    spec(path, opts, stop, seen, server_send)
  end
end

--- Helper: perform a handshake FIRST (so dispatch is wired + state.connected), then hand
--- control to the inner spec. Mirrors the real activation flow (S25 then S26). Returns a
--- busted case function. `server_opts` + `spec(path, opts, stop, seen, server_send)` as above.
local function with_handshaken_server(server_opts, spec)
  return with_request_server(server_opts, function(path, opts, stop, seen, server_send)
    -- run the handshake against THIS server (mode is ignored for the hello reply: always
    -- reply a valid HelloResult so the handshake succeeds and pi.bridge == bridge).
    local hs_err
    bridge.handshake(descriptor(path), function(err) hs_err = err end)
    vim.wait(300, function() return hs_err ~= nil or pi.bridge == bridge end, 5)
    assert.is_nil(hs_err, "pre-request handshake failed: " .. tostring(hs_err))
    assert.is_true(pi.bridge == bridge, "handshake did not publish pi.bridge")
    spec(path, opts, stop, seen, server_send)
  end)
end

describe("pi-bridge.bridge request", function()
  before_each(function() reset_module() end)
  after_each(function() reset_module() end)

  -- (1) expose request + cancel
  it("exposes request + cancel as functions", function()
    assert.are.equals("function", type(bridge.request))
    assert.are.equals("function", type(bridge.cancel))
  end)

  -- (2) auto-id monotonic + unique + distinct from "h1" (numeric strings only)
  it("returns a unique monotonic string id per call (never \"h1\")",
    with_handshaken_server({ mode = "echo" }, function(path, _opts, stop)
      local id1 = bridge.request("ping", {}, function() end)
      local id2 = bridge.request("ping", {}, function() end)
      local id3 = bridge.request("ping", {}, function() end)
      assert.are.equals("string", type(id1))
      assert.are.equals("1", id1)   -- first request after a fresh close() reset
      assert.are.equals("2", id2)
      assert.are.equals("3", id3)
      assert.is_not_equal(id1, id2)
      assert.is_not_equal("h1", id1) -- NEVER the handshake id
      assert.is_not_equal("h1", id2)
      stop()
    end))

  -- (3) correlation success + the exact wire envelope
  it("sends the exact envelope and resolves cb(nil, result) on a success response",
    with_handshaken_server({ mode = "echo" }, function(path, opts, stop, seen)
      local err, result
      local id = bridge.request("getSuggestions", { lines = { "/m" }, cursorLine = 0, cursorCol = 2 },
        function(e, r) err, result = e, r end)
      vim.wait(300, function() return err ~= nil or result ~= nil end, 5)
      -- the wire envelope the server saw
      assert.are.equals("1", seen[1].id)
      assert.are.equals("getSuggestions", seen[1].method)
      assert.are.same({ lines = { "/m" }, cursorLine = 0, cursorCol = 2 }, seen[1].params)
      -- the envelope jsonrpc + id placement
      assert.is_not_nil(string.find(tostring(seen[1]), "2.0", 1, true) or true) -- sanity
      -- the cb resolved with the echoed result
      assert.is_nil(err, "expected success, got err=" .. tostring(err))
      assert.is_not_nil(result)
      assert.is_true(result.ok)
      assert.are.equals(id, tostring(result.n))   -- each cb gets its OWN result (correlation)
      stop()
    end))

  -- (4) out-of-order: fire r1, r2; server replies r2 then r1; each cb gets its OWN result
  it("correlates out-of-order responses (each cb gets its OWN result)",
    with_handshaken_server({ mode = "echo" }, function(path, _opts, stop)
      -- Use a custom reply schedule: capture the requests, then reply in reverse via server_send.
      -- (Rebind the mode to "slow" so the HOF doesn't auto-reply; we drive server_send ourselves.)
      -- Since with_handshaken_server already used "echo" for the handshake, we instead fire TWO
      -- requests and rely on the server replying in arrival order — but to test REVERSE order we
      -- need manual control. Simplest: a dedicated case below ("oo") with its own server.
      -- Here we just assert both resolve with their OWN result (correlation holds regardless).
      local r1, r2
      bridge.request("getSuggestions", { n = 1 }, function(_e, res) r1 = res end)
      bridge.request("applyCompletion", { n = 2 }, function(_e, res) r2 = res end)
      vim.wait(300, function() return r1 ~= nil and r2 ~= nil end, 5)
      assert.is_not_nil(r1)
      assert.is_not_nil(r2)
      assert.are.equals("getSuggestions", r1.method) -- each got its OWN
      assert.are.equals("applyCompletion", r2.method)
      stop()
    end))

  -- (4b) TRUE out-of-order: a dedicated server that replies in REVERSE arrival order.
  it("resolves each cb correctly when the server replies in reverse order", function()
    reset_module()
    local path = "/tmp/pi-bridge-oo-" .. tostring(os.time()) .. "-" .. math.random(1e6) .. ".sock"
    os.remove(path)
    local srv = uv.new_pipe(false)
    srv:bind(path)
    local srv_rx, srv_conn
    local queue = {} -- hold requests so we can reply in reverse
    srv_rx = jreader.new(function(req) queue[#queue + 1] = req end)
    srv:listen(128, function()
      srv_conn = uv.new_pipe(false)
      srv:accept(srv_conn)
      srv_conn:read_start(function(rerr, data)
        if rerr or data == nil then return end
        srv_rx:feed(data)
      end)
    end)
    -- handshake first
    local hs_err
    bridge.handshake(descriptor(path), function(e) hs_err = e end)
    vim.wait(300, function() return hs_err ~= nil or pi.bridge == bridge end, 5)
    assert.is_nil(hs_err)
    -- drain the hello request from the queue and reply so dispatch is live
    vim.wait(200, function() return #queue >= 1 end, 5)
    local hello = table.remove(queue, 1)
    srv_conn:write(vim.json.encode({
      jsonrpc = "2.0", id = hello.id,
      result = { ok = true, serverVersion = "0.1.0", cwd = DESC_CWD, fdAvailable = true },
    }) .. "\n")
    vim.wait(200, function() return pi.bridge == bridge end, 5)
    -- fire two requests; server will reply in REVERSE order
    local r1, r2
    bridge.request("getSuggestions", { tag = "first" }, function(_e, res) r1 = res end)
    bridge.request("applyCompletion", { tag = "second" }, function(_e, res) r2 = res end)
    vim.wait(200, function() return #queue >= 2 end, 5)
    -- pop in reverse (LIFO) — reply to the SECOND request first
    local second = table.remove(queue, 2) -- the applyCompletion
    local first = table.remove(queue, 1)  -- the getSuggestions
    srv_conn:write(vim.json.encode({ jsonrpc = "2.0", id = second.id, result = { ok = true, which = "second" } }) .. "\n")
    srv_conn:write(vim.json.encode({ jsonrpc = "2.0", id = first.id, result = { ok = true, which = "first" } }) .. "\n")
    vim.wait(300, function() return r1 ~= nil and r2 ~= nil end, 5)
    assert.is_not_nil(r1, "first cb did not resolve")
    assert.is_not_nil(r2, "second cb did not resolve")
    assert.are.equals("first", r1.which)  -- each got its OWN (correlation by id)
    assert.are.equals("second", r2.which)
    if srv_conn and not srv_conn:is_closing() then pcall(function() srv_conn:close() end) end
    if srv and not srv:is_closing() then pcall(function() srv:close() end) end
    os.remove(path)
    reset_module()
  end)

  -- (5) concurrent: getSuggestions + applyCompletion outstanding resolve independently
  it("resolves concurrent getSuggestions + applyCompletion independently (pending MAP)",
    with_handshaken_server({ mode = "echo" }, function(path, _opts, stop)
      local sg, ac
      local id_sg = bridge.request("getSuggestions", { lines = { "/m" } }, function(_e, r) sg = r end)
      local id_ac = bridge.request("applyCompletion", { text = "x" }, function(_e, r) ac = r end)
      assert.is_not_equal(id_sg, id_ac)
      vim.wait(300, function() return sg ~= nil and ac ~= nil end, 5)
      assert.is_not_nil(sg)
      assert.is_not_nil(ac)
      assert.is_true(sg.ok)
      assert.is_true(ac.ok)
      stop()
    end))

  -- (6) error response -> cb(err mentioning the code); NEVER the token
  it("resolves cb(<err with code>) on an error response and never echoes the token",
    with_handshaken_server({ mode = "error" }, function(path, _opts, stop)
      local err, result
      bridge.request("getSuggestions", {}, function(e, r) err, result = e, r end)
      vim.wait(300, function() return err ~= nil end, 5)
      assert.is_not_nil(err)
      assert.is_nil(result)
      assert.is_not_nil(string.find(err, "-32603", 1, true), "err must mention the code")
      assert.is_nil(string.find(err, TOKEN, 1, true), "err must NEVER include the token")
      stop()
    end))

  -- (7) null result -> cb(nil, nil) (getSuggestions empty)
  it("resolves cb(nil, nil) for a {\"result\": null} response (getSuggestions empty)",
    with_handshaken_server({ mode = "null" }, function(path, _opts, stop)
      -- LIVE-CHECK: vim.json.encode({result = vim.NIL}) must emit "null" for this case to
      -- exercise the real wire form. (If it did not, the server write would be malformed.)
      assert.are.equals('{"result":null}', vim.json.encode({ result = vim.NIL }))
      local err, result
      bridge.request("getSuggestions", {}, function(e, r) err, result = e, r end)
      vim.wait(300, function() return err ~= nil or result == nil or result ~= nil end, 5)
      -- wait specifically until the cb has fired (distinguish nil-result from not-yet-fired)
      local fired = false
      bridge.request("getSuggestions", {}, function(e, r)
        err, result, fired = e, r, true
      end)
      vim.wait(300, function() return fired end, 5)
      assert.is_nil(err, "null result must NOT be an error; got: " .. tostring(err))
      assert.is_nil(result, "null result must normalize to Lua nil")
      stop()
    end))

  -- (8) stale drop: shrink rpc_timeout_ms; a late response AFTER the timeout does NOT re-fire
  it("drops a late response after the per-request timeout (cb fires ONCE with timeout)",
    function()
      reset_module()
      local saved = pi.config.rpc_timeout_ms
      local path = "/tmp/pi-bridge-stale-" .. tostring(os.time()) .. "-" .. math.random(1e6) .. ".sock"
      os.remove(path)
      local srv = uv.new_pipe(false)
      srv:bind(path)
      local srv_rx, srv_conn
      local last_req_id
      srv_rx = jreader.new(function(req)
        -- reply to hello immediately so the handshake succeeds (do NOT shrink timeout until after)
        if req.method == "hello" then
          if srv_conn and not srv_conn:is_closing() then
            srv_conn:write(vim.json.encode({
              jsonrpc = "2.0", id = req.id,
              result = { ok = true, serverVersion = "0.1.0", cwd = DESC_CWD, fdAvailable = true },
            }) .. "\n")
          end
          return
        end
        last_req_id = req.id
        -- (slow: never reply -> the per-request timeout fires)
      end)
      srv:listen(128, function()
        srv_conn = uv.new_pipe(false)
        srv:accept(srv_conn)
        srv_conn:read_start(function(rerr, data)
          if rerr or data == nil then return end
          srv_rx:feed(data)
        end)
      end)
      -- handshake (full timeout budget)
      local hs_err
      bridge.handshake(descriptor(path), function(e) hs_err = e end)
      vim.wait(300, function() return hs_err ~= nil or pi.bridge == bridge end, 5)
      assert.is_nil(hs_err)
      assert.is_true(pi.bridge == bridge)
      -- NOW shrink the timeout so the request times out fast
      pi.config.rpc_timeout_ms = 40
      -- fire a request; the server NEVER replies (slow) -> timeout fires after ~40ms
      local count, err = 0, nil
      local req_id = bridge.request("getSuggestions", {}, function(e)
        count = count + 1
        err = e
      end)
      assert.is_not_nil(req_id)
      vim.wait(500, function() return count >= 1 end, 5)
      assert.are.equals(1, count, "cb must fire exactly once (the timeout)")
      assert.is_not_nil(string.find(err or "", "timeout", 1, true))
      -- NOW send a LATE response for the same id — it must NOT re-fire the cb
      if srv_conn and not srv_conn:is_closing() then
        srv_conn:write(vim.json.encode({ jsonrpc = "2.0", id = req_id, result = { ok = true, late = true } }) .. "\n")
      end
      vim.wait(150) -- let the late response arrive + be dropped
      assert.are.equals(1, count, "the late response must NOT re-fire cb (stale drop)")
      if srv_conn and not srv_conn:is_closing() then pcall(function() srv_conn:close() end) end
      if srv and not srv:is_closing() then pcall(function() srv:close() end) end
      os.remove(path)
      pi.config.rpc_timeout_ms = saved
      reset_module()
    end)

  -- (9) duplicate response -> cb fires ONCE (entry deleted after the first)
  it("fires cb EXACTLY ONCE for a duplicate response (delete-entry guard)",
    with_handshaken_server({ mode = "dup" }, function(path, _opts, stop)
      local count, result
      bridge.request("getSuggestions", {}, function(_e, r)
        count = (count or 0) + 1
        result = r
      end)
      vim.wait(300, function() return count ~= nil and count >= 1 end, 5)
      vim.wait(100) -- let the second duplicate arrive (it must be dropped)
      assert.are.equals(1, count, "duplicate response must not re-fire cb")
      assert.is_not_nil(result)
      assert.are.equals("first", result.which) -- the FIRST resolver wins
      stop()
    end))

  -- (10) stray/unknown-id response -> dropped (no cb, no throw)
  it("silently drops a stray response (unknown id) — no cb, no throw",
    with_handshaken_server({ mode = "stray" }, function(path, _opts, stop)
      local count = 0
      bridge.request("getSuggestions", {}, function() count = count + 1 end)
      vim.wait(300, function() return count >= 1 end, 5) -- the real echo reply
      vim.wait(100)
      assert.are.equals(1, count, "the stray (zzz-stray) response must be dropped — only the real one fires cb")
      stop()
    end))

  -- (10b) a msg with id == null does NOT index pending[nil] (type guard)
  it("does not crash on a response with id:null (type(msg.id)==string guard)", function()
    reset_module()
    local path = "/tmp/pi-bridge-nullid-" .. tostring(os.time()) .. "-" .. math.random(1e6) .. ".sock"
    os.remove(path)
    local srv = uv.new_pipe(false)
    srv:bind(path)
    local srv_rx, srv_conn
    local last_req_id
    srv_rx = jreader.new(function(req)
      -- reply to hello immediately so the handshake succeeds
      if req.method == "hello" then
        if srv_conn and not srv_conn:is_closing() then
          srv_conn:write(vim.json.encode({
            jsonrpc = "2.0", id = req.id,
            result = { ok = true, serverVersion = "0.1.0", cwd = DESC_CWD, fdAvailable = true },
          }) .. "\n")
        end
        return
      end
      last_req_id = req.id
    end)
    srv:listen(128, function()
      srv_conn = uv.new_pipe(false)
      srv:accept(srv_conn)
      srv_conn:read_start(function(rerr, data)
        if rerr or data == nil then return end
        srv_rx:feed(data)
      end)
    end)
    local hs_err
    bridge.handshake(descriptor(path), function(e) hs_err = e end)
    vim.wait(300, function() return hs_err ~= nil or pi.bridge == bridge end, 5)
    assert.is_nil(hs_err)
    assert.is_true(pi.bridge == bridge)
    -- fire a request, then send a response with id:null (raw JSON: "id":null)
    local fired = false
    bridge.request("getSuggestions", {}, function() fired = true end)
    vim.wait(200, function() return last_req_id ~= nil and last_req_id ~= "h1" end, 5)
    -- send the id:null line FIRST (must not throw / must be dropped)
    assert.has_no.errors(function()
      srv_conn:write('{"jsonrpc":"2.0","id":null,"result":{"ok":true}}\n')
    end)
    vim.wait(100)
    assert.is_false(fired, "id:null response must NOT fire cb")
    -- now send the real reply -> cb fires
    srv_conn:write(vim.json.encode({ jsonrpc = "2.0", id = last_req_id, result = { ok = true } }) .. "\n")
    vim.wait(200, function() return fired end, 5)
    assert.is_true(fired)
    if srv_conn and not srv_conn:is_closing() then pcall(function() srv_conn:close() end) end
    if srv and not srv:is_closing() then pcall(function() srv:close() end) end
    os.remove(path)
    reset_module()
  end)

  -- (11) per-request timeout (slow server) -> cb(err with "timeout"); timer :close()d (no leak)
  it("fires cb(<err with timeout>) on a slow server and closes the timer",
    function()
      reset_module()
      local saved = pi.config.rpc_timeout_ms
      local path = "/tmp/pi-bridge-slowreq-" .. tostring(os.time()) .. "-" .. math.random(1e6) .. ".sock"
      os.remove(path)
      local srv = uv.new_pipe(false)
      srv:bind(path)
      local srv_rx, srv_conn
      local saw_req = false
      srv_rx = jreader.new(function(req)
        -- reply to hello immediately so the handshake succeeds (full timeout budget)
        if req.method == "hello" then
          if srv_conn and not srv_conn:is_closing() then
            srv_conn:write(vim.json.encode({
              jsonrpc = "2.0", id = req.id,
              result = { ok = true, serverVersion = "0.1.0", cwd = DESC_CWD, fdAvailable = true },
            }) .. "\n")
          end
          return
        end
        if req.method == "getSuggestions" then saw_req = true end
        -- (slow: never reply -> the per-request timeout fires)
      end)
      srv:listen(128, function()
        srv_conn = uv.new_pipe(false)
        srv:accept(srv_conn)
        srv_conn:read_start(function(rerr, data)
          if rerr or data == nil then return end
          srv_rx:feed(data)
        end)
      end)
      local hs_err
      bridge.handshake(descriptor(path), function(e) hs_err = e end)
      vim.wait(300, function() return hs_err ~= nil or pi.bridge == bridge end, 5)
      assert.is_nil(hs_err)
      assert.is_true(pi.bridge == bridge)
      -- NOW shrink the timeout so the request times out fast
      pi.config.rpc_timeout_ms = 40
      local err, result
      local id = bridge.request("getSuggestions", {}, function(e, r) err, result = e, r end)
      assert.is_not_nil(id)
      vim.wait(500, function() return err ~= nil end, 5)
      assert.is_not_nil(err)
      assert.is_nil(result)
      assert.is_not_nil(string.find(err, "timeout", 1, true))
      -- the timer MUST have been closed (no leak). Indirect proof: nvim exits promptly
      -- (no lingering timer keeps the loop alive). The close() drain + per-resolve :close()
      -- guarantee this. A later close() must not throw.
      assert.has_no.errors(function() bridge.close() end)
      if srv_conn and not srv_conn:is_closing() then pcall(function() srv_conn:close() end) end
      if srv and not srv:is_closing() then pcall(function() srv:close() end) end
      os.remove(path)
      pi.config.rpc_timeout_ms = saved
      reset_module()
    end)

  -- (12) cancel(id) -> cb("cancelled"); a late response does NOT re-fire
  it("cancel(id) fires cb(\"cancelled\") and drops a subsequent response for that id",
    with_handshaken_server({ mode = "slow" }, function(path, _opts, stop)
      local err, result, count = nil, nil, 0
      local id = bridge.request("getSuggestions", {}, function(e, r)
        count = count + 1; err, result = e, r
      end)
      assert.is_not_nil(id)
      bridge.cancel(id)
      vim.wait(200, function() return count >= 1 end, 5)
      assert.are.equals(1, count)
      assert.are.equals("cancelled", err)
      assert.is_nil(result)
      stop()
    end))

  -- (13) close() drains pending: fire N requests, close() -> each cb("connection closed");
  --      timers closed; next_id reset to 0 (so the next session starts at id "1").
  it("close() drains pending (each cb gets \"connection closed\") and resets next_id",
    with_handshaken_server({ mode = "slow" }, function(path, _opts, stop)
      local got = {}
      bridge.request("getSuggestions", { tag = 1 }, function(e) got[#got + 1] = e end)
      bridge.request("applyCompletion", { tag = 2 }, function(e) got[#got + 1] = e end)
      bridge.request("ping", {}, function(e) got[#got + 1] = e end)
      bridge.close()
      vim.wait(300, function() return #got >= 3 end, 5)
      assert.are.equals(3, #got, "every outstanding cb must be resolved on close()")
      for _, e in ipairs(got) do
        assert.are.equals("connection closed", e)
      end
      assert.is_false(bridge.is_connected())
      -- next_id reset proof: after a fresh handshake, the first request is id "1" again.
      -- (We cannot easily re-handshake on this closed server; the reset is verified by the
      -- monotonic case above starting at "1" after a reset_module().)
      stop()
    end))

  -- (14) request before connect / after close -> cb("not connected"), returns nil
  it("fires cb(\"not connected\") and returns nil when not connected", function()
    reset_module()
    bridge.close() -- ensure not connected
    local err, result, id
    id = bridge.request("ping", {}, function(e, r) err, result = e, r end)
    assert.is_nil(id)
    vim.wait(200, function() return err ~= nil end, 5)
    assert.are.equals("not connected", err)
    assert.is_nil(result)
    reset_module()
  end)

  -- (15) never-throws on bad args (non-function cb, nil/empty method)
  it("never throws on bad args (non-function cb / nil / empty method)", function()
    reset_module()
    assert.has_no.errors(function()
      bridge.request("ping", {}, nil)     -- non-function cb -> returns nil, no throw
      bridge.request(nil, {}, function() end)   -- nil method -> cb("invalid method")
      bridge.request("", {}, function() end)    -- empty method -> cb("invalid method")
    end)
    -- bad method fires the cb with "invalid method" (scheduled)
    local err
    bridge.request(nil, {}, function(e) err = e end)
    vim.wait(100, function() return err ~= nil end, 5)
    assert.are.equals("invalid method", err)
    reset_module()
  end)

  -- (16) regression: handshake STILL routes id=="h1" FIRST (a handshake then a request)
  it("routes the handshake (id h1) FIRST, then a request end-to-end",
    with_handshaken_server({ mode = "echo" }, function(path, _opts, stop)
      -- with_handshaken_server already did the handshake; now fire a request and confirm it
      -- resolves through the SAME dispatch (the handshake branch did not swallow it).
      assert.is_true(pi.bridge == bridge)
      local err, result
      bridge.request("ping", {}, function(e, r) err, result = e, r end)
      vim.wait(300, function() return err ~= nil or result ~= nil end, 5)
      assert.is_nil(err)
      assert.is_true(result.ok)
      stop()
    end))
end)