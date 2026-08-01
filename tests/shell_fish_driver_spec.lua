-- === tests/shell_fish_driver_spec.lua — plenary/busted spec (P2.M2.T4.S1) ===
-- Covers the contract surface of the REAL fish driver: the start(opts,on_ready)/cd(path)
-- signature, the never-throws discipline, the failure paths (bad shell / spawn err) with
-- NO leaked handles, and (LIVE, gated on `fish`) the real spawn → on_ready(nil,proc,stdin,stdout)
-- + the "git ch" → checkout round-trip.
--
-- MOCKS nothing for the LIVE case (it spawns the real fish); the OFFLINE cases use a
-- bogus shell path + nil cb (no subprocess). Sets package.loaded["pi-bridge.shell.fish"]=nil
-- in after_each so the real module doesn't leak into shell.lua's fake-driver tests
-- (the existing-spec convention — shell_ensure_spec.lua does the same).
--
-- Run (from the repo root):
--   timeout 90 nvim --headless --clean -u tests/minimal_init.lua \
--     -c 'lua require("plenary.busted").run("tests/shell_fish_driver_spec.lua")'
local fish = require("pi-bridge.shell.fish")
local uv = vim.uv

-- count OPEN (not closing) uv handles of a given shape (the no-leak assertion; mirrors
-- shell_complete_current_spec.lua count_open_timers).
local function count_open_handles()
	local n = 0
	uv.walk(function(h)
		if type(h) == "userdata" and not h:is_closing() then n = n + 1 end
	end)
	return n
end

describe("pi-bridge.shell.fish driver (P2.M2.T4.S1)", function()
	after_each(function()
		-- cleanup so the real module doesn't leak into shell.lua's fake-driver tests.
		package.loaded["pi-bridge.shell.fish"] = nil
		-- re-require so the next `it` (same describe) still sees the module if the nil
		-- happened mid-suite; fish is a stateless module so re-require is free.
		fish = require("pi-bridge.shell.fish")
	end)

	describe("offline contract (no subprocess)", function()
		it("exports M.start and M.cd as functions + require loads without error", function()
			assert.is_truthy(fish, "require('pi-bridge.shell.fish') returned nil")
			assert.are.equals("function", type(fish.start))
			assert.are.equals("function", type(fish.cd))
		end)

		it("M.start({}, nil) does NOT throw on a non-function on_ready (never-throws)", function()
			assert.has_no.errors(function()
				fish.start({}, nil)
				fish.start({}, 123)
				fish.start({}, "not a function")
			end)
		end)

		it("M.start with a bogus shell path → on_ready(err, nil,nil,nil); no leaked handles", function()
			local before = count_open_handles()
			local got_err = "UNSET"
			local got_proc, got_stdin, got_stdout = "UNSET", "UNSET", "UNSET"
			fish.start({
				shell = "/nonexistent/path/fish-definitely-missing-xyz",
				cwd = vim.fn.getcwd(),
				startup_timeout_ms = 500,
			}, function(err, proc, stdin, stdout)
				got_err = err
				got_proc, got_stdin, got_stdout = proc, stdin, stdout
			end)
			-- the spawn fails immediately OR the startup timer fires; either way on_ready
			-- MUST fire within a small budget. Drive the loop.
			vim.wait(2000, function() return got_err ~= "UNSET" end, 20)
			-- give luv a tick to finalize any pending closes.
			vim.wait(100, function() return false end, 50)

			assert.is_truthy(got_err and got_err ~= "UNSET", "on_ready never fired for the bogus shell")
			assert.is_nil(got_proc, "on_ready proc must be nil on failure (got " .. tostring(got_proc) .. ")")
			assert.is_nil(got_stdin, "on_ready stdin must be nil on failure")
			assert.is_nil(got_stdout, "on_ready stdout must be nil on failure")
			-- no leaked handles: the count after must not exceed the count before (every
			-- handle the driver created on the failure path must be closed).
			local after = count_open_handles()
			assert.is_true(after <= before,
				"handle leak: before=" .. tostring(before) .. " after=" .. tostring(after)
				.. " (err=" .. tostring(got_err) .. ")")
		end)

		it("M.start never throws on a missing cwd / missing startup_timeout_ms (defaults)", function()
			-- use a bogus shell so no subprocess lingers; we only assert never-throws here.
			assert.has_no.errors(function()
				fish.start({ shell = "/nonexistent/fish-xyz" }, function() end)
			end)
			-- drain any pending timer so it doesn't leak across the suite.
			vim.wait(800, function() return false end, 50)
		end)

		it("M.cd never throws on bad args (nil/empty/number) or when no daemon is running", function()
			assert.has_no.errors(function()
				fish.cd(nil)
				fish.cd("")
				fish.cd(123)
				fish.cd("/tmp")  -- no daemon started in this case → silent noop
			end)
		end)
	end)

	describe("LIVE driver (gated on `fish` on PATH)", function()
		local have_fish = vim.fn.executable("fish") == 1

		-- Build a request frame byte-for-byte like shell.lua M.request (avoids hand-escaping
		-- the embedded quote in a `git "feature` line). SAME encoding M.request step (6) uses.
		local function make_frame(line, cursor, after)
			local l_str = vim.json.encode(line)
			local a_str = vim.json.encode(after or "")
			local payload = string.format('{"line":%s,"cursor":%d,"after":%s}', l_str, cursor, a_str)
			return string.format('__PIREQ__\t%s\n', payload)
		end

		-- shared spawn/wire/decode/teardown helper (each `it` spawns its OWN daemon + tears it
		-- down — no state shared across `it`s). on_ready_cb receives (proc,stdin,stdout) on success.
		local function spawn_daemon(on_ready_cb)
			local ready = false
			local start_err = "UNSET"
			local proc, stdin, stdout
			fish.start({
				shell = "fish",
				cwd = vim.fn.getcwd(),
				startup_timeout_ms = 5000,
			}, function(err, p, si, so)
				start_err = err
				if not err then proc, stdin, stdout = p, si, so end
				ready = true
				if not err and on_ready_cb then on_ready_cb(proc, stdin, stdout) end
			end)
			vim.wait(8000, function() return ready end, 20)
			return start_err, proc, stdin, stdout
		end

		local function teardown_daemon(proc, stdin, stdout)
			pcall(function() if proc and not proc:is_closing() then uv.process_kill(proc, "sigkill") end end)
			pcall(function() if proc and not proc:is_closing() then proc:close() end end)
			pcall(function() if stdin and not stdin:is_closing() then stdin:close() end end)
			pcall(function() if stdout and not stdout:is_closing() then stdout:read_stop(); stdout:close() end end)
		end

		it("start → on_ready(nil, proc, stdin, stdout) + 'git ch' → checkout in items", function()
			if not have_fish then
				pending("fish not on PATH — LIVE case skipped (PRD §17.15)", function() end)
				return
			end
			local ready = false
			local start_err = "UNSET"
			local proc, stdin, stdout
			fish.start({
				shell = "fish",
				cwd = vim.fn.getcwd(),
				startup_timeout_ms = 5000,
			}, function(err, p, si, so)
				start_err = err
				if err then ready = true; return end
				proc, stdin, stdout = p, si, so
				ready = true
			end)
			-- drive the loop until on_ready fires (async — the __PIREADY__ marker arrives
			-- on stderr after config sourcing, 100ms-1s+).
			vim.wait(8000, function() return ready end, 20)
			assert.is_nil(start_err, "LIVE start on_ready err=" .. tostring(start_err))
			assert.is_truthy(proc, "LIVE proc handle missing")
			assert.is_truthy(stdin, "LIVE stdin pipe missing")
			assert.is_truthy(stdout, "LIVE stdout pipe missing")

			-- wire stdout (the smoke stands in for shell.lua's _feed route) + send "git ch".
			local rx_buf = ""
			local decoded = nil
			pcall(function()
				stdout:read_start(function(rerr, data)
					if rerr or not data then return end
					rx_buf = rx_buf .. data
					local s = rx_buf:find("__PIRESP_START__\n", 1, true)
					local e = s and rx_buf:find("__PIRESP_END__\n", s + 1, true)
					if s and e then
						local payload = rx_buf:sub(s + #"__PIRESP_START__\n", e - 1)
						local ok, d = pcall(vim.json.decode, payload)
						if ok and type(d) == "table" then decoded = d end
					end
				end)
			end)
			pcall(function()
				stdin:write('__PIREQ__\t{"line":"git ch","cursor":6,"after":""}\n')
			end)
			vim.wait(8000, function() return decoded ~= nil end, 20)

			assert.is_truthy(decoded, "LIVE 'git ch' response never decoded")
			if decoded then
				local items = (type(decoded.items) == "table") and decoded.items or {}
				local found = {}
				for _, it in ipairs(items) do found[it.value] = true end
				assert.is_true(#items > 0, "LIVE 'git ch' decoded but empty")
				assert.is_true(found["checkout"] == true, "LIVE 'git ch' missing `checkout`")
				assert.is_true(found["cherry"] == true, "LIVE 'git ch' missing `cherry`")
			end

			-- teardown the live daemon (shell.lua owns this in prod).
			pcall(function() if proc and not proc:is_closing() then uv.process_kill(proc, "sigkill") end end)
			pcall(function() if proc and not proc:is_closing() then proc:close() end end)
			pcall(function() if stdin and not stdin:is_closing() then stdin:close() end end)
			pcall(function() if stdout and not stdout:is_closing() then stdout:read_stop(); stdout:close() end end)
		end)

		it("empty line → empty items (no all-commands flood)", function()
			if not have_fish then
				pending("fish not on PATH — LIVE case skipped (PRD §17.15)", function() end)
				return
			end
			local start_err, proc, stdin, stdout = spawn_daemon()
			assert.is_nil(start_err, "LIVE start on_ready err=" .. tostring(start_err))
			assert.is_truthy(proc, "LIVE proc handle missing")

			local rx_buf = ""
			local decoded = nil
			pcall(function()
				stdout:read_start(function(rerr, data)
					if rerr or not data then return end
					rx_buf = rx_buf .. data
					local s = rx_buf:find("__PIRESP_START__\n", 1, true)
					local e = s and rx_buf:find("__PIRESP_END__\n", s + 1, true)
					if s and e then
						local payload = rx_buf:sub(s + #"__PIRESP_START__\n", e - 1)
						local ok, d = pcall(vim.json.decode, payload)
						if ok and type(d) == "table" then decoded = d end
					end
				end)
			end)
			pcall(function() stdin:write(make_frame("", 0, "")) end)
			vim.wait(8000, function() return decoded ~= nil end, 20)

			assert.is_truthy(decoded, "LIVE empty-line response never decoded")
			if decoded then
				local items = (type(decoded.items) == "table") and decoded.items or {}
				assert.are.equals(0, #items,
					"empty line should yield 0 items, got " .. tostring(#items) .. " (FLOOD not suppressed)")
			end

			teardown_daemon(proc, stdin, stdout)
		end)

		it("quote-line → empty items AND daemon survives the NEXT request (no panic)", function()
			if not have_fish then
				pending("fish not on PATH — LIVE case skipped (PRD §17.15)", function() end)
				return
			end
			local start_err, proc, stdin, stdout = spawn_daemon()
			assert.is_nil(start_err, "LIVE start on_ready err=" .. tostring(start_err))
			assert.is_truthy(proc, "LIVE proc handle missing")

			-- rx_buf persists across the two frames (the survival check decodes BOTH on the
			-- SAME stdout read). resolvers fire in send order.
			local rx_buf = ""
			local r_quote, r_followup = nil, nil
			pcall(function()
				stdout:read_start(function(rerr, data)
					if rerr or not data then return end
					rx_buf = rx_buf .. data
					-- drain every complete START..END pair in the buffer (a chunk may carry both).
					while true do
						local s = rx_buf:find("__PIRESP_START__\n", 1, true)
						if not s then break end
						local ps = s + #"__PIRESP_START__\n"
						local e = rx_buf:find("__PIRESP_END__\n", ps, true)
						if not e then break end
						local payload = rx_buf:sub(ps, e - 1)
						rx_buf = rx_buf:sub(e + #"__PIRESP_END__\n")
						local ok, d = pcall(vim.json.decode, payload)
						if ok and type(d) == "table" then
							local items = (type(d.items) == "table") and d.items or {}
							if r_quote == nil then
								r_quote = items
							else
								r_followup = items
							end
						end
					end
				end)
			end)

			-- (1) the quote-frame: `git "feature` extracts to a TRAILING-BACKSLASH cmd → guard
			--     must emit empty BEFORE complete -C (no panic, no flood).
			pcall(function() stdin:write(make_frame('git "feature', 11, "")) end)
			vim.wait(8000, function() return r_quote ~= nil end, 20)

			-- (2) the FOLLOW-UP on the SAME daemon: `git ch` → checkout. If the quote had
			--     panicked the daemon, this follow-up would hang → timeout → r_followup stays nil.
			pcall(function() stdin:write(make_frame("git ch", 6, "")) end)
			vim.wait(8000, function() return r_followup ~= nil end, 20)

			assert.is_truthy(r_quote,
				"quote-frame never resolved — DAEMON PANICKED+DIED (guard did not fire)")
			if r_quote then
				assert.are.equals(0, #r_quote,
					"quote-line should yield 0 items, got " .. tostring(#r_quote) .. " (flood/panic not suppressed)")
			end
			assert.is_truthy(r_followup,
				"follow-up `git ch` never resolved — daemon did NOT survive the quote-frame")
			if r_followup then
				local found = {}
				for _, it in ipairs(r_followup) do found[it.value] = true end
				assert.is_true(found["checkout"] == true,
					"follow-up `git ch` missing `checkout` (daemon degraded after the quote-frame)")
			end

			teardown_daemon(proc, stdin, stdout)
		end)
	end)
end)