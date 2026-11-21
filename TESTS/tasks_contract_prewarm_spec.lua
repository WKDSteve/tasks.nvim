-- TESTS/tasks_contract_prewarm_spec.lua -- the editor asks git for the commit of the engine in the background after
-- `setup`, so the first document of the write door never waits for git; the CLI never starts that lookup.

---@diagnostic disable: duplicate-set-field
-- Why: the spec replaces vim.system and contract.prewarm on purpose, so no git is started.

return function(H)
  local eq, ok = H.eq, H.ok

  local real_system = vim.system
  local real_loaded = package.loaded["tasks_nvim.contract"]
  local root = vim.fs.dirname(vim.fs.dirname(vim.fs.normalize(debug.getinfo(1, "S").source:sub(2))))

  ---Run the scheduled work of `setup`: the VimEnter of a fresh editor (when it has not entered yet), then the loop.
  local function after_start()
    if vim.v.vim_did_enter ~= 1 then
      pcall(vim.api.nvim_exec_autocmds, "VimEnter", { group = "TasksPrewarm" })
    end
    vim.wait(20, function()
      return false
    end)
  end

  -- the editor: a background lookup (a callback), never a wait; a head made meanwhile says "unknown" at once
  do
    local starts = {} ---@type { argv: string[], on_exit: fun(res: table) }[]
    vim.system = function(argv, _, on_exit)
      starts[#starts + 1] = { argv = argv, on_exit = on_exit }
      return {
        wait = function()
          error("the editor waited for git")
        end,
        kill = function() end,
      }
    end
    package.loaded["tasks_nvim.contract"] = nil
    local contract = require("tasks_nvim.contract")
    local vault = H.tmpdir()
    local run_ok, err = pcall(function()
      require("tasks_nvim").setup({ vault = vault })
      after_start()
      eq(#starts, 1, "one git lookup after the start")
      eq(starts[1].argv[1], "git", "git by its bare name")
      ok(type(starts[1].on_exit) == "function", "with a callback: nothing waits")
      eq(
        contract.head("probe").engine.git,
        "unknown",
        "a document while git runs: unknown, no wait"
      )
      starts[1].on_exit({ code = 0, signal = 0, stdout = root .. "\nabc1234\n" })
      eq(contract.head("probe").engine.git, "abc1234", "the answer of the callback is kept")
      require("tasks_nvim").setup({ vault = vault })
      after_start()
      eq(#starts, 1, "a second setup does not ask again")
    end)
    vim.system = real_system
    package.loaded["tasks_nvim.contract"] = real_loaded
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
