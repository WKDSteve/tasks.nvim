-- `tasks index <area> --staged` (the CLI): the index of an area built from git's staging area and staged, the working
-- tree untouched. It asks git (`rev-parse`, `checkout-index`, `hash-object`, `update-index`) while it runs.
-- A user types it in a shell (`nvim -l scripts/tasks.lua`); the trace of `testing perf` does not follow into that child,
-- so the sheet calls the same entry, `tasks_nvim.cli.run(argv, io)`, with the user's words, in the editor it drives.
-- A fixture vault in a temp folder made a git repository by the sheet (never a real vault).
return {
  id = "tasks.cli-index-staged",
  feature = "tasks.cli-index-staged",
  title = "tasks.nvim: tasks index <area> --staged builds the index from the staging area and stages it",
  engine = "rpc",
  sizes = { { rows = 24, cols = 100 } },
  steps = {
    {
      lua = [[local H = {
        tmpdir = function()
          local d = vim.fs.normalize(vim.fn.tempname())
          vim.fn.mkdir(d, "p")
          return d
        end,
        write = function(path, text)
          vim.fn.mkdir(vim.fs.dirname(path), "p")
          local f = assert(io.open(path, "wb"))
          f:write(text)
          f:close()
        end,
      }
      local F = dofile(vim.fn.getcwd() .. "/TESTS/fixture.lua")
      _G.root = vim.fs.normalize(F.vault(H))
      _G.git = function(...)
        local cmd = { "git", "-C", _G.root, "-c", "core.autocrlf=false", ... }
        local res = vim.system(cmd, { text = true, env = { GIT_CONFIG_NOSYSTEM = "1" } }):wait()
        return res.stdout or "", res.code
      end
      assert(select(2, _G.git("init", "-q")) == 0)
      F.task(H, _G.root, "lib.nvim", "own-task", F.meta("Own task", "open"))
      assert(select(2, _G.git("add", ".")) == 0)
      -- another session's task, only in the tree
      F.task(H, _G.root, "lib.nvim", "foreign-task", F.meta("Foreign task", "open"))
      _G.cli = function(argv)
        local out = {}
        local io = { out = function(s) out[#out + 1] = s end, err = function(s) out[#out + 1] = s end }
        return require("tasks_nvim.cli").run(argv, io), table.concat(out)
      end]],
      note = "a fixture vault in git: one staged task, one only in the tree",
    },
    {
      lua = [[_G.code, _G.out = _G.cli({ "--vault=" .. _G.root, "index", "lib.nvim", "--staged" })]],
      note = "tasks --vault=<vault> index lib.nvim --staged",
    },
    {
      expect = [[_G.code == 0 and _G.out:find("(staged)", 1, true) ~= nil]],
      note = "it says the index is staged",
    },
    {
      expect = [[(function()
        local staged, code = _G.git("show", ":lib.nvim/ROADMAP/TASKS.md")
        return code == 0 and staged:find("own-task", 1, true) ~= nil and not staged:find("foreign-task", 1, true)
      end)()]],
      note = "the staged index lists the staged task, not the one only in the tree",
    },
    {
      expect = [[vim.fn.filereadable(_G.root .. "/lib.nvim/ROADMAP/TASKS.md") == 0]],
      note = "the working tree stays as it was",
    },
  },
  judge = {},
  manual = {},
}
