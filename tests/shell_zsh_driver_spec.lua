-- === tests/shell_zsh_driver_spec.lua — plenary/busted spec (P2.M3.T5.S1) ===
-- Covers the contract surface of the REAL zsh driver: the start(opts,on_ready)/cd(path)
-- signature, the never-throws discipline, the failure paths (bad shell / spawn err) with
-- NO leaked handles, the pure-Lua M.parse, and (LIVE, gated on `zsh`) the real spawn →
-- on_ready(nil,proc,stdin,stdout) + the "git ch" → checkout round-trip.
--
-- MOCKS nothing for the LIVE case (it spawns the real zsh); the OFFLINE cases use a
-- bogus shell path + nil cb (no subprocess). Sets package.loaded["pi-bridge.shell.zsh"]=nil
-- in after_each so the real module doesn't leak into shell.lua's fake-driver tests
-- (the existing-spec convention — shell_ensure_spec.lua does the same).
--
-- Run (from the repo root):
--   timeout 90 nvim --headless --clean -u tests/minimal_init.lua \
--     -c 'lua require("plenary.busted").run("tests/shell_zsh_driver_spec.lua")'
local zsh = require("pi-bridge.shell.zsh")
local uv = vim.uv

-- count OPEN (not closing) uv handles of a given shape (the no-leak assertion; mirrors
-- shell_complete_current_spec.lua count_open_timers).
local function count_open_handles()
	local n = 0
	uv.walk(function(h)
		if type(h) == "userdata" and not h:is_closing() then
			n = n + 1
		end
	end)
	return n
end

describe("pi-bridge.shell.zsh driver (P2.M3.T5.S1)", function()
	after_each(function()
		-- cleanup so the real module doesn't leak into shell.lua's fake-driver tests.
		package.loaded["pi-bridge.shell.zsh"] = nil
		-- re-require so the next `it` (same describe) still sees the module if the nil
		-- happened mid-suite; zsh is a stateless module so re-require is free.
		zsh = require("pi-bridge.shell.zsh")
	end)

	describe("offline contract (no subprocess)", function()
		it("exports M.start, M.cd, M.parse as functions + require loads without error", function()
			assert.is_truthy(zsh, "require('pi-bridge.shell.zsh') returned nil")
			assert.are.equals("function", type(zsh.start))
			assert.are.equals("function", type(zsh.cd))
			assert.are.equals("function", type(zsh.parse))
		end)

		it("M.start({}, nil) does NOT throw on a non-function on_ready (never-throws)", function()
			assert.has_no.errors(function()
				zsh.start({}, nil)
				zsh.start({}, 123)
				zsh.start({}, "not a function")
			end)
		end)

		it("M.start with a bogus shell path → on_ready(err, nil,nil,nil); no leaked handles", function()
			local before = count_open_handles()
			local got_err = "UNSET"
			local got_proc, got_stdin, got_stdout = "UNSET", "UNSET", "UNSET"
			zsh.start({
				shell = "/nonexistent/path/zsh-definitely-missing-xyz",
				cwd = vim.fn.getcwd(),
				startup_timeout_ms = 500,
			}, function(err, proc, stdin, stdout)
				got_err = err
				got_proc, got_stdin, got_stdout = proc, stdin, stdout
			end)
			-- the spawn fails immediately OR the startup timer fires; either way on_ready
			-- MUST fire within a small budget. Drive the loop.
			vim.wait(2000, function()
				return got_err ~= "UNSET"
			end, 20)
			-- give luv a tick to finalize any pending closes.
			vim.wait(100, function()
				return false
			end, 50)

			assert.is_truthy(got_err and got_err ~= "UNSET", "on_ready never fired for the bogus shell")
			assert.is_nil(got_proc, "on_ready proc must be nil on failure (got " .. tostring(got_proc) .. ")")
			assert.is_nil(got_stdin, "on_ready stdin must be nil on failure")
			assert.is_nil(got_stdout, "on_ready stdout must be nil on failure")
			-- no leaked handles: the count after must not exceed the count before (every
			-- handle the driver created on the failure path must be closed).
			local after = count_open_handles()
			assert.is_true(
				after <= before,
				"handle leak: before="
					.. tostring(before)
					.. " after="
					.. tostring(after)
					.. " (err="
					.. tostring(got_err)
					.. ")"
			)
		end)

		it("M.start never throws on a missing cwd / missing startup_timeout_ms (defaults)", function()
			-- use a bogus shell so no subprocess lingers; we only assert never-throws here.
			assert.has_no.errors(function()
				zsh.start({ shell = "/nonexistent/zsh-xyz" }, function() end)
			end)
			-- drain any pending timer so it doesn't leak across the suite.
			vim.wait(800, function()
				return false
			end, 50)
		end)

		it("M.cd never throws on bad args (nil/empty/number) or when no daemon is running", function()
			assert.has_no.errors(function()
				zsh.cd(nil)
				zsh.cd("")
				zsh.cd(123)
				zsh.cd("/tmp") -- no daemon started in this case → silent noop (advisory for zsh v1)
			end)
		end)

		it("M.parse parses word⇥desc lines into {value, description?} (pure-Lua, offline)", function()
			local items = zsh.parse("checkout\tcheckout branch\ncherry-pick\tapply commits\nadd\n")
			assert.are.equals(3, #items)
			assert.are.equals("checkout", items[1].value)
			assert.are.equals("checkout branch", items[1].description)
			assert.are.equals("cherry-pick", items[2].value)
			assert.are.equals("apply commits", items[2].description)
			assert.are.equals("add", items[3].value)
			assert.is_nil(items[3].description, "add had no description → key omitted")
		end)

		it("M.parse never throws + returns {} on bad input", function()
			assert.has_no.errors(function()
				zsh.parse(nil)
				zsh.parse(123)
				zsh.parse("")
				zsh.parse("\n\n\r\n")
			end)
			assert.are.same({}, zsh.parse(nil))
			assert.are.same({}, zsh.parse(123))
			assert.are.same({}, zsh.parse(""))
		end)
	end)

	describe("LIVE driver (gated on `zsh` on PATH)", function()
		local have_zsh = vim.fn.executable("zsh") == 1

		it("start → on_ready(nil, proc, stdin, stdout) + 'git ch' → checkout in items", function()
			if not have_zsh then
				pending("zsh not on PATH — LIVE case skipped (PRD §17.15)", function() end)
				return
			end
			local ready = false
			local start_err = "UNSET"
			local proc, stdin, stdout
			zsh.start({
				shell = "zsh",
				cwd = vim.fn.getcwd(),
				startup_timeout_ms = 8000,
			}, function(err, p, si, so)
				start_err = err
				if err then
					ready = true
					return
				end
				proc, stdin, stdout = p, si, so
				ready = true
			end)
			-- drive the loop until on_ready fires (async — the __PIREADY__ marker arrives
			-- on stderr after the inner's compinit, 100ms-1s+; first run builds the dump).
			vim.wait(12000, function()
				return ready
			end, 20)
			assert.is_nil(start_err, "LIVE start on_ready err=" .. tostring(start_err))
			assert.is_truthy(proc, "LIVE proc handle missing")
			assert.is_truthy(stdin, "LIVE stdin pipe missing")
			assert.is_truthy(stdout, "LIVE stdout pipe missing")

			-- wire stdout (the spec stands in for shell.lua's _feed route) + send "git ch".
			local rx_buf = ""
			local decoded = nil
			pcall(function()
				stdout:read_start(function(rerr, data)
					if rerr or not data then
						return
					end
					rx_buf = rx_buf .. data
					local s = rx_buf:find("__PIRESP_START__\n", 1, true)
					local e = s and rx_buf:find("__PIRESP_END__\n", s + 1, true)
					if s and e then
						local payload = rx_buf:sub(s + #"__PIRESP_START__\n", e - 1)
						local ok, d = pcall(vim.json.decode, payload)
						if ok and type(d) == "table" then
							decoded = d
						end
					end
				end)
			end)
			pcall(function()
				stdin:write('__PIREQ__\t{"line":"git ch","cursor":6,"after":""}\n')
			end)
			vim.wait(8000, function()
				return decoded ~= nil
			end, 20)

			assert.is_truthy(decoded, "LIVE 'git ch' response never decoded")
			if decoded then
				local items = (type(decoded.items) == "table") and decoded.items or {}
				local found = {}
				for _, it in ipairs(items) do
					found[it.value] = true
				end
				assert.is_true(#items > 0, "LIVE 'git ch' decoded but empty")
				assert.is_true(found["checkout"] == true, "LIVE 'git ch' missing `checkout`")
				assert.is_true(found["cherry"] == true, "LIVE 'git ch' missing `cherry`")
			end

			-- teardown the live daemon (shell.lua owns this in prod).
			pcall(function()
				if proc and not proc:is_closing() then
					uv.process_kill(proc, "sigkill")
				end
			end)
			pcall(function()
				if proc and not proc:is_closing() then
					proc:close()
				end
			end)
			pcall(function()
				if stdin and not stdin:is_closing() then
					stdin:close()
				end
			end)
			pcall(function()
				if stdout and not stdout:is_closing() then
					stdout:read_stop()
					stdout:close()
				end
			end)
		end)
	end)
end)
