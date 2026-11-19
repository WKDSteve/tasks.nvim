-- `--stale=refs`: which open tasks name a file (`refs:`) that changed since the task's `updated`. It asks git for the
-- dates, the real git: `:Tasks list` in the background (`staleness.git_dates_async`, one `vim.system` callback per
-- chunk), `:Tasks plan` while the command runs (`staleness.git_dates`, one blocking `git log` per chunk). A second repo
-- without a commit makes git refuse the `log`: the chunk is not halved for nothing, one `git log -1` asks whether the
-- repository answers at all (`repo_answers`).
-- A fixture vault and two fixture repos in a temp folder (never a real vault); the repos are made by the sheet (its
-- preparation, not the plugin's starts).
return {
  id = "tasks.stale-refs",
  feature = "tasks.stale-refs",
  title = "tasks.nvim: :Tasks list --stale=refs and :Tasks plan --stale=refs date the refs of the tasks with git",
  engine = "rpc",
  sizes = { { rows = 30, cols = 140 } },
  steps = {
    {
      lua = [[vim.opt.shortmess:append("I"); vim.o.ruler = false; vim.o.showcmd = false
      if vim.fn.exists("+messagesopt") == 1 then vim.o.messagesopt = "wait:0,history:500" end
      local H = {
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
      local repos = vim.fs.dirname(_G.root) .. "/repos"

      -- a fixture git call with a fixed date; never the user's config (signing, hooks)
      local env = {
        GIT_AUTHOR_DATE = "2026-06-01T12:00:00Z",
        GIT_COMMITTER_DATE = "2026-06-01T12:00:00Z",
        GIT_CONFIG_NOSYSTEM = "1",
      }
      local function git(dir, ...)
        local cmd = { "git", "-C", dir, "-c", "user.name=Sheet", "-c", "user.email=sheet@example.test",
          "-c", "commit.gpgsign=false", "-c", "core.hooksPath=", ... }
        local res = vim.system(cmd, { text = true, env = env }):wait()
        assert(res.code == 0, table.concat(cmd, " ") .. ": " .. (res.stderr or ""))
      end

      -- lib.nvim: README.md committed on 2026-06-01, after the task's updated day
      H.write(repos .. "/lib.nvim/README.md", "# lib\n")
      H.write(repos .. "/lib.nvim/lua/lib/x.lua", "return {}\n")
      git(repos .. "/lib.nvim", "init", "-q")
      git(repos .. "/lib.nvim", "add", "-A")
      git(repos .. "/lib.nvim", "commit", "-q", "-m", "init")
      F.task(H, _G.root, "lib.nvim", "docs-drifted", F.meta("Docs drifted", "open", {
        { "updated", "2026-01-01" }, { "refs", "[README.md, lua/lib/x.lua]" },
      }))
      F.task(H, _G.root, "lib.nvim", "no-refs-at-all", F.meta("No refs at all", "open", { { "updated", "2026-01-01" } }))

      -- cascade.nvim: files on disk, a repository without a commit yet: git refuses the log
      H.write(repos .. "/cascade.nvim/a.md", "a\n")
      H.write(repos .. "/cascade.nvim/b.md", "b\n")
      git(repos .. "/cascade.nvim", "init", "-q")
      F.task(H, _G.root, "cascade.nvim", "fresh-repo", F.meta("Fresh repo", "open", {
        { "updated", "2026-01-01" }, { "refs", "[a.md, b.md]" },
      }))

      require("tasks_nvim").setup({ vault = _G.root, staleness = { repo_bases = { repos } } })
      _G.buf_has = function(text)
        return table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n"):find(text, 1, true) ~= nil
      end
      _G.said = function(text) return vim.fn.execute("messages"):find(text, 1, true) ~= nil end]],
      note = "a fixture vault; lib.nvim with a commit after the task, cascade.nvim without any commit",
    },

    -- in the background
    { keys = ":Tasks list lib.nvim --stale=refs --to=buffer<CR>" },
    {
      wait = [[require("tasks_nvim.ui.cmd").pending_ref_checks() == 0 and _G.buf_has("Docs drifted")]],
      timeout = 10000,
      note = "the list comes once git answered: the task whose README changed",
    },
    { expect = [[_G.buf_has("README.md")]], note = "the changed file is named" },
    {
      expect = [[not _G.buf_has("No refs at all")]],
      note = "a task without refs is no stale task",
    },

    -- while the command runs
    { keys = ":bwipeout!<CR>" },
    { keys = ":Tasks plan lib.nvim --stale=refs<CR>" },
    {
      wait = [[_G.buf_has("Docs drifted")]],
      timeout = 10000,
      note = "the plan of the stale task",
    },
    { expect = [[not _G.buf_has("No refs at all")]], note = "the plan keeps only the stale task" },

    -- a repository git refuses
    { keys = ":bwipeout!<CR>" },
    {
      keys = ":Tasks plan cascade.nvim --stale=refs<CR>",
      note = "a repository without a commit: no error message",
    },
    {
      wait = [[_G.buf_has("Fresh repo")]],
      timeout = 10000,
      note = "the task whose refs git could not date stays in the plan (an unreadable signal is never 'not stale')",
    },
  },
  judge = {},
  manual = {
    "Once in the real vault: :Tasks list all --stale=refs names the tasks whose refs changed since they were updated",
  },
}
