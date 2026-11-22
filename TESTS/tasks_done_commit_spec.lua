-- TESTS/tasks_done_commit_spec.lua -- `tasks done <id> --commit`: the files the finish wrote in the vault are committed
-- at once from a staging area of their own (as `tasks commit`); without `--commit` one line `commit-paths` lists them.
-- A file another session left in the tree, changed or staged, stays out either way.

---@diagnostic disable: need-check-nil, param-type-mismatch

return function(H)
  local eq, ok = H.eq, H.ok
  local F = dofile(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)) .. "/fixture.lua")
  local index = require("tasks_nvim.index")
  local cli = require("tasks_nvim.cli")

  local root = F.vault(H)

  ---@param args string[]
  ---@return string stdout
  ---@return integer code
  local function git(args)
    local res = vim.system(vim.list_extend({ "git", "-C", root }, args), { text = true }):wait()
    return res.stdout or "", res.code
  end
  ---@param args string[]
  ---@return integer code
  ---@return string said
  local function run(args)
    local said = {}
    local function put(s)
      said[#said + 1] = s
    end
    local code = cli.run(
      vim.list_extend(vim.deepcopy(args), { "--vault=" .. root, "--today=" .. F.TODAY }),
      { out = put, err = put }
    )
    return code, table.concat(said, "\n")
  end

  eq(select(2, git({ "init", "-q" })), 0, "git init")
  git({ "config", "core.autocrlf", "false" })
  git({ "config", "user.name", "t" })
  git({ "config", "user.email", "t@example.org" })
  git({ "config", "commit.gpgsign", "false" })

  F.task(H, root, "lib.nvim", "keep", F.meta("Keep", "open"))
  F.task(H, root, "lib.nvim", "first", F.meta("First", "open"))
  F.task(H, root, "lib.nvim", "second", F.meta("Second", "open"))
  F.task(H, root, "cascade.nvim", "other", F.meta("Other", "open"))
  ok(index.write_all({ root = root }), "seed indexes")
  git({ "add", "." })
  eq(select(2, git({ "commit", "-q", "-m", "seed" })), 0, "seed commit")
  local seed = vim.trim(git({ "rev-parse", "HEAD" }))

  -- Another session: a staged new task, a changed task (tree only) and an untracked one, in the same area.
  F.task(H, root, "cascade.nvim", "foreign-staged", F.meta("Foreign staged", "open"))
  git({ "add", "--", "cascade.nvim/ROADMAP/tasks/foreign-staged.md" })
  F.task(H, root, "lib.nvim", "foreign-new", F.meta("Foreign new", "open"))
  local keep_file = root .. "/lib.nvim/ROADMAP/tasks/keep.md"
  H.write(keep_file, H.read(keep_file) .. "\nTheir edit.\n")

  -- Without --commit: the paths are listed, nothing is committed.
  local code, said = run({ "done", "lib.nvim/first", "--no-next" })
  eq(code, 0, said)
  local line = said:match("commit%-paths\t([^\n]*)")
  ok(line, "a commit-paths line: " .. said)
  local listed = vim.split(line, " ", { plain = true })
  table.sort(listed)
  eq(
    listed[1]:match("^lib.nvim/Backlog/TASKS/.*_first%.md$") ~= nil,
    true,
    "the backlog file: " .. line
  )
  eq(listed[2], "lib.nvim/ROADMAP/tasks/first.md", "the removed source")
  eq(
    #listed,
    2,
    "only the files of the task, not the generated ones nor the foreign ones: " .. line
  )
  eq(vim.trim(git({ "rev-parse", "HEAD" })), seed, "nothing was committed")

  -- With --commit: the second finish is committed; the first finish (uncommitted, not this run's) stays in the tree.
  code, said = run({ "done", "lib.nvim/second", "--no-next", "--commit" })
  eq(code, 0, said)
  ok(said:find("committed\t", 1, true), "says committed: " .. said)
  ok(not said:find("commit-paths", 1, true), "no list when it committed: " .. said)
  local files =
    vim.split(vim.trim(git({ "show", "--name-only", "--no-renames", "--format=", "HEAD" })), "\n")
  table.sort(files)
  eq(#files, 4, "the move, its README row and the index: " .. table.concat(files, ","))
  ok(files[1] == "lib.nvim/Backlog/README.md", "README: " .. files[1])
  ok(files[2]:match("^lib.nvim/Backlog/TASKS/.*_second%.md$"), "backlog file: " .. files[2])
  eq(files[3], "lib.nvim/ROADMAP/TASKS.md")
  eq(files[4], "lib.nvim/ROADMAP/tasks/second.md")
  eq(vim.trim(git({ "log", "-1", "--format=%s" })), "done: lib.nvim/second", "default message")
  eq(vim.trim(git({ "rev-parse", "HEAD~1" })), seed, "on top of the seed")
  local committed_index = git({ "show", "HEAD:lib.nvim/ROADMAP/TASKS.md" })
  ok(
    not committed_index:find("foreign-new", 1, true),
    "the foreign task is not in the committed index"
  )
  ok(not committed_index:find("second.md", 1, true), "the finished one left it")

  -- The foreign work is untouched: staged stays staged, tree changes stay in the tree.
  eq(
    vim.trim(git({ "diff", "--cached", "--name-only" })),
    "cascade.nvim/ROADMAP/tasks/foreign-staged.md",
    "their staged file stays staged"
  )
  local status = git({ "status", "--porcelain", "-uall" })
  ok(status:find("lib.nvim/ROADMAP/tasks/keep.md", 1, true), "their edit is still uncommitted")
  ok(status:find("lib.nvim/ROADMAP/tasks/foreign-new.md", 1, true), "their new file too")
  ok(
    status:find("ROADMAP/tasks/first.md", 1, true),
    "the earlier finish was not this run's: still in the tree"
  )

  -- A custom message, and the refusal of a message without --commit.
  F.task(H, root, "lib.nvim", "third", F.meta("Third", "open"))
  code, said =
    run({ "done", "lib.nvim/third", "--no-next", "--commit", "--commit-message=finish third" })
  eq(code, 0, said)
  eq(vim.trim(git({ "log", "-1", "--format=%s" })), "finish third", "the message")
  code = run({ "done", "lib.nvim/keep", "--commit-message=x" })
  eq(code, 2, "--commit-message needs --commit")
end
