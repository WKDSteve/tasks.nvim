-- `tasks history backfill` (the CLI): the figures of the past days, read from the vault's git history (one `git` call
-- per question: `rev-parse`, `log`, the tree of a day's last commit). It blocks while it runs.
-- A user types it in a shell (`nvim -l scripts/tasks.lua`); the trace of `testing perf` does not follow into that child,
-- so the sheet calls the same entry, `tasks_nvim.cli.run(argv, io)`, with the user's words, in the editor it drives.
-- A fixture vault in a temp folder made a git repository with three days of commits by the sheet (never a real vault).
return {
  id = "tasks.cli-history-backfill",
  feature = "tasks.cli-history-backfill",
  title = "tasks.nvim: tasks history backfill fills the history rows of past days from git",
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
      local function git(date, ...)
        local cmd = { "git", "-C", _G.root, "-c", "user.name=Sheet", "-c", "user.email=sheet@example.test",
          "-c", "commit.gpgsign=false", "-c", "core.hooksPath=", "-c", "core.autocrlf=false", ... }
        local env = { GIT_CONFIG_NOSYSTEM = "1", GIT_AUTHOR_DATE = date, GIT_COMMITTER_DATE = date }
        local res = vim.system(cmd, { text = true, env = env }):wait()
        assert(res.code == 0, table.concat(cmd, " ") .. ": " .. (res.stderr or ""))
      end
      local function commit(date)
        git(date, "add", "-A")
        git(date, "commit", "-q", "-m", "state of " .. date)
      end
      git(nil, "init", "-q")
      F.task(H, _G.root, "lib.nvim", "alpha", F.meta("Alpha", "open", { { "created", "2026-03-02" } }))
      commit("2026-03-02T09:00:00")
      F.task(H, _G.root, "lib.nvim", "beta", F.meta("Beta", "open", { { "created", "2026-03-03" } }))
      commit("2026-03-03T12:00:00")
      F.task(H, _G.root, "cascade.nvim", "gamma", F.meta("Gamma", "doing", { { "created", "2026-03-04" } }))
      commit("2026-03-04T12:00:00")
      _G.cli = function(argv)
        local out = {}
        local io = { out = function(s) out[#out + 1] = s end, err = function(s) out[#out + 1] = s end }
        return require("tasks_nvim.cli").run(argv, io), table.concat(out)
      end]],
      note = "a fixture vault in git, commits on 2026-03-02, 03 and 04",
    },
    {
      lua = [[_G.code, _G.out = _G.cli({ "--vault=" .. _G.root, "--today=2026-03-05", "history", "backfill" })]],
      timeout = 20000,
      note = "tasks --vault=<vault> --today=2026-03-05 history backfill",
    },
    {
      expect = [[_G.code == 0 and _G.out:find("3 day(s)\t3 row(s)\t2026-03-02..2026-03-04", 1, true) ~= nil]],
      note = "it reports a row for each of the three days",
    },
    {
      expect = [[#vim.fn.glob(_G.root .. "/_Telemetry/history/*.jsonl", false, true) > 0]],
      note = "the history file of the vault holds them",
    },
  },
  judge = {},
  manual = {},
}
