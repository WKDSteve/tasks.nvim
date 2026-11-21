-- TESTS/tasks_contract_prewarm_spec.lua -- the editor asks git for the commit of the engine in the background right
-- before a write through the door, so no document of the door ever waits for git; `setup` starts no process, and the
-- CLI never starts that lookup.

---@diagnostic disable: duplicate-set-field
-- Why: the spec replaces vim.system and contract.prewarm on purpose, so no git is started.

return function(H)
  local eq, ok = H.eq, H.ok

  local real_system = vim.system
  local real_loaded = package.loaded["tasks_nvim.contract"]
  local real_ops = package.loaded["tasks_nvim.ops"]
  local here = vim.fs.normalize(debug.getinfo(1, "S").source:sub(2))
  local plugin = vim.fs.dirname(vim.fs.dirname(here))
  local F = dofile(vim.fs.dirname(here) .. "/fixture.lua")

  ---Run the scheduled work of `setup`: the VimEnter of a fresh editor (when it has not entered yet), then the loop.
  local function after_start()
    if vim.v.vim_did_enter ~= 1 then
      pcall(vim.api.nvim_exec_autocmds, "VimEnter", {})
    end
    vim.wait(20, function()
      return false
    end)
  end

  -- the editor: `setup` starts no process (SEC-22); the first write through the door starts the lookup in the
  -- background (a callback, never a wait), and a head made meanwhile says "unknown" at once
  do
    local starts = {} ---@type { argv: string[], on_exit: fun(res: table) }[]
    vim.system = function(argv, _, on_exit)
      starts[#starts + 1] = { argv = argv, on_exit = on_exit }
      return {
        wait = function()
          error("the editor waited for " .. tostring(argv[1]))
        end,
        kill = function() end,
      }
    end
    package.loaded["tasks_nvim.contract"] = nil
    package.loaded["tasks_nvim.ops"] = nil
    local contract = require("tasks_nvim.contract")
    local root = F.vault(H)
    local run_ok, err = pcall(function()
      require("tasks_nvim").setup({ vault = root })
      after_start()
      eq(#starts, 0, "setup starts no process")
      require("tasks_nvim.ui.meeting_cmd").new({
        args = { area = "lib.nvim" },
        rest = { "2026-10-05", "14:00-15:00", "Sync" },
      })
      ok(
        vim.uv.fs_stat(root .. "/lib.nvim/MEETINGS/sync-2026-10-05.md") ~= nil,
        "the meeting is made without waiting for git"
      )
      eq(#starts, 1, "one git lookup, started by the write")
      eq(starts[1].argv[1], "git", "git by its bare name")
      ok(type(starts[1].on_exit) == "function", "with a callback: nothing waits")
      eq(
        contract.head("probe").engine.git,
        "unknown",
        "a document while git runs: unknown, no wait"
      )
      starts[1].on_exit({ code = 0, signal = 0, stdout = plugin .. "\nabc1234\n" })
      eq(contract.head("probe").engine.git, "abc1234", "the answer of the callback is kept")
      contract.prewarm()
      eq(#starts, 1, "a known answer is not asked again")
    end)
    vim.system = real_system
    package.loaded["tasks_nvim.contract"] = real_loaded
    package.loaded["tasks_nvim.ops"] = real_ops
    pcall(vim.cmd, "silent! %bwipeout!")
    assert(run_ok, err)
  end

  -- the CLI: a command of the write door does not start the lookup in the background
  do
    local contract = require("tasks_nvim.contract")
    local real_prewarm = contract.prewarm
    local calls = 0
    contract.prewarm = function()
      calls = calls + 1
    end
    local vault = H.tmpdir()
    local out = {}
    local run_ok, err = pcall(function()
      vim.fn.mkdir(vault .. "/lib.nvim/ROADMAP/tasks", "p")
      require("tasks_nvim.cli").run({ "call", "hello", "--vault=" .. vault }, {
        out = function(s)
          out[#out + 1] = s
        end,
        err = function(s)
          out[#out + 1] = s
        end,
      })
      vim.wait(20, function()
        return false
      end)
    end)
    contract.prewarm = real_prewarm
    assert(run_ok, err)
    H.has(table.concat(out), "capabilities", "the CLI answered with a document")
    eq(calls, 0, "the CLI never prewarms")
  end
end
