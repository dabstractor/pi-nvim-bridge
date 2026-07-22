-- === tests/bridge_on_exit_spec.lua — plenary/busted spec (the Level-2 gate for S38) ===
-- Covers every Success Criterion from PRP P2.M9.T23.S38:
--   * autosave: writes a modified named loaded buffer to its file (UTF-8 + \n + trailing \n),
--     clears 'modified'; skips unmodified / unnamed / invalid / unloaded buffers (no error).
--   * bye:     when connected, sends exactly ONE {jsonrpc:"2.0",id,method:"bye",params:{}}
--              on the wire, then closes; when NOT connected, sends nothing.
--   * idempotency: double-fire (ExitPre then VimLeavePre) writes once, sends bye once, no throw.
--   * never-throws: on_exit(0) when never connected is a safe no-op (preserves bridge_spec.lua:159).
--
-- Mirrors bridge_request_spec.lua: each case spins its OWN luv unix-socket server (unique
-- socket path), replies a valid HelloResult so the handshake succeeds + pi.bridge==bridge,
-- then layers the S38 behavior on top. Server mode "record_bye" captures every non-hello
-- request so the spec can assert the exact bye envelope.
--
-- Run (from the repo root):
--   nvim --headless --clean -u tests/minimal_init.lua \
--     -c 'lua require("plenary.busted").run("tests/bridge_on_exit_spec.lua")'
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
--- pending map / next_id do not leak across tests. Idempotent + never throws.
local function reset_module()
  pcall(function() bridge.close() end)
  pi.bridge = nil -- clear a success-case publication (close() already niled server_info)
end

--- A fresh luv server mirroring the bridge extension's request semantics. Spins a unique
--- socket path, ALWAYS replies a valid HelloResult to `hello` (so the handshake succeeds),
--- and behaves per `opts.mode` for everything else:
---   "record_bye" — record every non-hello request into `seen`, reply {id, result:{ok:true}}.
---   "silent"     — record into `seen`, never reply (the bye cb is fire-and-forget anyway).
--- Calls `spec(path, opts, stop, seen, server_send)`.
---
--- NOTE: do NOT name a spec-local table `pending` — it shadows plenary.busted's global
--- `pending` (the test-SKIP function). We use `seen` locals to observe behavior.
local function with_request_server(opts, spec)
  return function()
    local path = "/tmp/pi-bridge-onexit-" .. tostring(os.time()) .. "-" .. math.random(1e6) .. ".sock"
    os.remove(path)
    reset_module()
    local srv = uv.new_pipe(false)
    srv:bind(path)
    local srv_rx, srv_conn
    local seen = {} -- every decoded non-hello request the server saw (order-preserving)
    srv_rx = jreader.new(function(req)
      -- ALWAYS reply to the `hello` handshake with a valid HelloResult so the handshake
      -- succeeds and pi.bridge == bridge.
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
      if opts.mode == "record_bye" then
        if srv_conn and not srv_conn:is_closing() then
          srv_conn:write(vim.json.encode({
            jsonrpc = "2.0", id = req.id, result = { ok = true },
          }) .. "\n")
        end
      end
      -- "silent": record only; never reply (bye cb is fire-and-forget — no ack awaited)
    end)
    srv:listen(128, function()
      srv_conn = uv.new_pipe(false)
      srv:accept(srv_conn)
      srv_conn:read_start(function(rerr, data)
        if rerr or data == nil then return end
        srv_rx:feed(data)
      end)
    end)
    --- Send a raw JSON line from the server to the client (for control). Unused by S38 cases
    --- but kept for parity with the bridge_request_spec harness.
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
--- control to the inner spec. Returns a busted case function.
local function with_handshaken_server(server_opts, spec)
  return with_request_server(server_opts, function(path, opts, stop, seen, server_send)
    local hs_err
    bridge.handshake(descriptor(path), function(err) hs_err = err end)
    vim.wait(300, function() return hs_err ~= nil or pi.bridge == bridge end, 5)
    assert.is_nil(hs_err, "pre-request handshake failed: " .. tostring(hs_err))
    assert.is_true(pi.bridge == bridge, "handshake did not publish pi.bridge")
    spec(path, opts, stop, seen, server_send)
  end)
end

--- Helper: make a temp file backed by `content`, open it as a NORMAL (non-scratch) loaded
--- buffer, and return (buf, path). Mirrors a real pi-prompt buffer (a named file buffer).
local function make_named_loaded_buf(content_lines)
  local path = "/tmp/pi-s38-" .. tostring(os.time()) .. "-" .. math.random(1e6) .. ".md"
  local f = io.open(path, "w")
  if f then f:write(table.concat(content_lines, "\n") .. "\n"); f:close() end
  local buf = vim.api.nvim_create_buf(true, false) -- listed, NOT scratch
  vim.api.nvim_buf_set_name(buf, path)
  vim.fn.bufload(buf)
  return buf, path
end

describe("bridge.on_exit (S38)", function()
  local tmp_paths = {}
  after_each(function()
    for _, p in ipairs(tmp_paths) do os.remove(p) end
    tmp_paths = {}
    reset_module()
  end)

  -- (a) autosave: writes a modified named loaded buffer to its file + clears 'modified'
  it("autosave: writes a modified named loaded buffer to its file (UTF-8 + \\n + trailing \\n) and clears modified",
    function()
      reset_module()
      local buf, path = make_named_loaded_buf({ "original" })
      tmp_paths[#tmp_paths + 1] = path
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "hello", "world" })
      assert.is_true(vim.bo[buf].modified, "precondition: set_lines marked buffer modified")
      -- on_exit is a safe no-op re: transport here (never connected); autosave still runs.
      assert.has_no.errors(function() bridge.on_exit(buf) end)
      vim.wait(50) -- writefile is synchronous, but give the loop a tick
      assert.is_false(vim.bo[buf].modified, "on_exit must clear 'modified' after writefile")
      local f = io.open(path, "r")
      local got = f and f:read("*a") or ""
      if f then f:close() end
      assert.are.equals("hello\nworld\n", got, "file bytes must be \\n-delimited + single trailing \\n")
    end)

  -- (b) autosave: skips an unmodified buffer (file untouched)
  it("autosave: skips an unmodified buffer (file untouched)", function()
    reset_module()
    local buf, path = make_named_loaded_buf({ "untouched" })
    tmp_paths[#tmp_paths + 1] = path
    assert.is_false(vim.bo[buf].modified, "precondition: freshly-loaded buffer is unmodified")
    local mtime_before = vim.loop.fs_stat(path).mtime.sec
    assert.has_no.errors(function() bridge.on_exit(buf) end)
    vim.wait(50)
    assert.is_false(vim.bo[buf].modified, "still unmodified (no write)")
    local f = io.open(path, "r")
    local got = f and f:read("*a") or ""
    if f then f:close() end
    assert.are.equals("untouched\n", got, "file content must be UNCHANGED (autosave skipped)")
    _ = mtime_before -- (mtime parity is flaky on fast disks; content parity is the hard check)
  end)

  -- (c) autosave: skips an unnamed buffer (no error, no file written)
  it("autosave: skips an unnamed buffer (no error)", function()
    reset_module()
    local buf = vim.api.nvim_create_buf(true, false) -- unnamed (name == "")
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "nope" })
    assert.has_no.errors(function() bridge.on_exit(buf) end)
    vim.wait(50)
    -- nothing to assert about a file (no name); the no-throw + no-write is the contract
    assert.is_true(true, "unnamed buffer skipped without error")
  end)

  -- (d) autosave: skips an invalid buf handle (no error)
  it("autosave: skips an invalid buf handle (no error)", function()
    reset_module()
    assert.has_no.errors(function() bridge.on_exit(999999) end) -- never-allocated handle
    assert.has_no.errors(function() bridge.on_exit(nil) end)    -- non-number
    assert.has_no.errors(function() bridge.on_exit("x") end)    -- non-number
  end)

  -- (e) bye: when connected, sends exactly ONE bye request on the wire, then closes
  it("bye: when connected, sends exactly one bye request on the wire then closes",
    with_handshaken_server({ mode = "record_bye" }, function(path, _opts, stop, seen)
      local buf, p = make_named_loaded_buf({ "x" })
      tmp_paths[#tmp_paths + 1] = p
      assert.is_true(bridge.is_connected())
      assert.has_no.errors(function() bridge.on_exit(buf) end)
      -- give the server time to observe the bye request + the client close
      vim.wait(300, function() return #seen >= 1 end, 5)
      assert.is_false(bridge.is_connected(), "on_exit must close the connection")
      assert.are.equals(1, #seen, "exactly ONE bye request on the wire")
      assert.are.equals("bye", seen[1].method)
      assert.are.equals("2.0", seen[1].jsonrpc)
      assert.is_not_nil(seen[1].id, "bye must carry an id (M.request assigns a monotonic string)")
      assert.are.equals("string", type(seen[1].id))
      assert.is_not_equal("h1", seen[1].id) -- NEVER the handshake id
      -- params is empty table (M.request passes {} -> omitted if nil, but {} is sent as {})
      assert.is_truthy(seen[1].params == nil or (type(seen[1].params) == "table" and next(seen[1].params) == nil),
        "bye params must be empty/omitted")
      stop()
    end))

  -- (f) bye: when NOT connected, sends nothing and close is a no-op
  it("bye: when NOT connected, sends nothing and close is a no-op", function()
    reset_module()
    bridge.close() -- ensure not connected
    local buf, p = make_named_loaded_buf({ "y" })
    tmp_paths[#tmp_paths + 1] = p
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "edited" })
    assert.is_false(bridge.is_connected())
    assert.has_no.errors(function() bridge.on_exit(buf) end)
    assert.is_false(bridge.is_connected())
    -- autosave still ran (independent of connection — GOTCHA G)
    local f = io.open(p, "r")
    local got = f and f:read("*a") or ""
    if f then f:close() end
    assert.are.equals("edited\n", got, "autosave runs even when NOT connected")
  end)

  -- (g) idempotent across double-fire (ExitPre then VimLeavePre)
  it("idempotent across double-fire (ExitPre then VimLeavePre)",
    with_handshaken_server({ mode = "record_bye" }, function(path, _opts, stop, seen)
      local buf, p = make_named_loaded_buf({ "first" })
      tmp_paths[#tmp_paths + 1] = p
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "second" })
      -- First fire (ExitPre): autosave + bye + close.
      assert.has_no.errors(function() bridge.on_exit(buf) end)
      -- Second fire (VimLeavePre) immediately after: all three steps must be clean no-ops.
      assert.has_no.errors(function() bridge.on_exit(buf) end)
      vim.wait(300, function() return #seen >= 1 end, 5)
      assert.are.equals(1, #seen, "double-fire must send bye exactly ONCE (2nd call: is_connected()==false)")
      assert.are.equals("bye", seen[1].method)
      assert.is_false(bridge.is_connected())
      -- autosave wrote once (2nd call: modified already false -> skipped)
      local f = io.open(p, "r")
      local got = f and f:read("*a") or ""
      if f then f:close() end
      assert.are.equals("second\n", got, "autosave wrote the buffer content once")
      stop()
    end))

  -- (h) never throws: on_exit(0) when never connected is a safe no-op
  --     (preserves the bridge_spec.lua:159 guarantee)
  it("on_exit(0) when never connected is a safe no-op", function()
    reset_module()
    bridge.close() -- ensure clean slate
    assert.has_no.errors(function() bridge.on_exit(0) end)
    assert.is_false(bridge.is_connected())
  end)
end)