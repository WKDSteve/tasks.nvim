-- TESTS/tasks_vault_commit_spec.lua -- `tasks commit <path>... --message=`: commit only your own paths of a shared
-- vault, from a staging area of its own. Another session's staged file stays staged and out of the commit; its tree
-- change in the same area stays out of the committed index; a `done` (a move plus a README row) is committed with the
-- index and README rows of the commit itself.

---@diagnostic disable: need-check-nil, param-type-mismatch

return function(H)
  local eq, ok = H.eq, H.ok
  local F = dofile(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)) .. "/fixture.lua")
  local index = require("tasks_nvim.index")
  local cli = require("tasks_nvim.cli")
  local mutate = require("tasks_nvim.mutate")

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
    local code =
      cli.run(vim.list_extend(vim.deepcopy(args), { "--vault=" .. root }), { out = put, err = put })
    return code, table.concat(said, "\n")
  end

  eq(select(2, git({ "init", "-q" })), 0, "git init")
  git({ "config", "core.autocrlf", "false" })
  git({ "config", "user.name", "t" })
  git({ "config", "user.email", "t@example.org" })
  -- The fixture repository is not signed; a global commit.gpgsign would ask for a key the runner has not.
  git({ "config", "commit.gpgsign", "false" })

  F.task(H, root, "lib.nvim", "keep", F.meta("Keep", "open"))
  F.task(H, root, "lib.nvim", "finish", F.meta("Finish", "open"))
  F.task(H, root, "cascade.nvim", "other", F.meta("Other", "open"))
  ok(index.write_all({ root = root }), "seed indexes")
  git({ "add", "." })
  eq(select(2, git({ "commit", "-q", "-m", "seed" })), 0, "seed commit")
  local seed = vim.trim(git({ "rev-parse", "HEAD" }))

  -- Another session: a staged new task in cascade.nvim, and an unstaged new task in lib.nvim (only in the tree).
  F.task(H, root, "cascade.nvim", "foreign-staged", F.meta("Foreign staged", "open"))
  git({ "add", "--", "cascade.nvim/ROADMAP/tasks/foreign-staged.md" })
  F.task(H, root, "lib.nvim", "foreign-tree", F.meta("Foreign tree", "open"))
  -- ... and the tree's index of lib.nvim as their run of the engine wrote it, with their task in it.
  ok(index.write_area("lib.nvim", { root = root }), "the tree's index lists every session's tasks")

  -- Own work: a new task in lib.nvim.
  F.task(H, root, "lib.nvim", "mine", F.meta("Mine", "open"))

  -- A dry run commits nothing and names what would go in.
  local code, said =
    run({ "commit", "lib.nvim/ROADMAP/tasks/mine.md", "--message=add mine", "--dry-run" })
  eq(code, 0, "dry run: " .. said)
  ok(said:find("would-commit\t2 path(s)", 1, true), "the task and the index: " .. said)
  eq(vim.trim(git({ "rev-parse", "HEAD" })), seed, "a dry run commits nothing")

  code, said = run({ "commit", "lib.nvim/ROADMAP/tasks/mine.md", "--message=add mine" })
  eq(code, 0, "commit: " .. said)
  ok(said:find("^committed\t"), "says committed: " .. said)
  ok(said:find("index\tlib.nvim\twritten\t3 open", 1, true), "the index of the commit: " .. said)
  ok(
    said:find("note: the tree's lib.nvim/ROADMAP/TASKS.md", 1, true),
    "and that the tree's differs: " .. said
  )

  local files = git({ "show", "--name-only", "--no-renames", "--format=", "HEAD" })
  eq(
    vim.split(vim.trim(files), "\n"),
    { "lib.nvim/ROADMAP/TASKS.md", "lib.nvim/ROADMAP/tasks/mine.md" },
    "exactly the own path and its index"
  )
  eq(vim.trim(git({ "rev-parse", "HEAD~1" })), seed, "on top of the seed")
  local committed_index = git({ "show", "HEAD:lib.nvim/ROADMAP/TASKS.md" })
  ok(committed_index:find("mine.md", 1, true), "the committed index lists the own task")
  ok(not committed_index:find("foreign-tree", 1, true), "and not the one only in the tree")

  -- The other session's staged file is still staged, and only it.
  local staged = git({ "diff", "--cached", "--name-only" })
  eq(
    vim.trim(staged),
    "cascade.nvim/ROADMAP/tasks/foreign-staged.md",
    "the foreign staged file stays staged"
  )
  -- The committed paths are not staged changes in the shared staging area either (they match HEAD there).
  local status = git({ "status", "--porcelain", "--", "lib.nvim/ROADMAP/tasks/mine.md" })
  eq(status, "", "the own task is clean afterwards")

  -- A checkout of the commit passes the index check: what the gate would see on the push.
  local snap = vim.fn.tempname() .. "-snap"
  eq(
    select(2, git({ "worktree", "add", "-q", "--detach", snap, "HEAD" })),
    0,
    "checkout of the commit"
  )
  local stale = index.write_all({ root = snap, check = true })
  for _, r in ipairs(stale) do
    eq(r.action, "unchanged", "index of " .. r.area .. " in the commit")
  end
  git({ "worktree", "remove", "--force", snap })

  -- `done` of an own task: the task moves to Backlog/, the README gets a row; another session's done in the same
  -- area left a row of its own in the tree's README, which must stay out.
  local readme = root .. "/lib.nvim/Backlog/README.md"
  local base_readme = git({ "show", "HEAD:lib.nvim/Backlog/README.md" })
  local moved = "2026-10-03_finish.md"
  git({ "mv", "lib.nvim/ROADMAP/tasks/finish.md", "lib.nvim/Backlog/TASKS/" .. moved })
  git({ "reset", "-q", "--", "lib.nvim" }) -- the move is in the tree only; the shared staging area knows nothing
  local text = H.read and H.read(readme) or table.concat(vim.fn.readfile(readme), "\n") .. "\n"
  text = mutate.readme_add_row(
    text,
    "TASKS",
    moved,
    "| [`" .. moved .. "`](./TASKS/" .. moved .. ") | Finish (2026-10-03) |"
  )
  text = mutate.readme_add_row(
    text,
    "TASKS",
    "2026-10-03_theirs.md",
    "| [`2026-10-03_theirs.md`](./TASKS/2026-10-03_theirs.md) | Theirs (2026-10-03) |"
  )
  H.write(readme, text)

  code, said = run({
    "commit",
    "lib.nvim/ROADMAP/tasks/finish.md",
    "lib.nvim/Backlog/TASKS/" .. moved,
    "--message=done finish",
  })
  eq(code, 0, "commit of the done: " .. said)
  files = git({ "show", "--name-only", "--no-renames", "--format=", "HEAD" })
  eq(vim.split(vim.trim(files), "\n"), {
    "lib.nvim/Backlog/README.md",
    "lib.nvim/Backlog/TASKS/" .. moved,
    "lib.nvim/ROADMAP/TASKS.md",
    "lib.nvim/ROADMAP/tasks/finish.md",
  }, "the move, its README and the index")
  local committed_readme = git({ "show", "HEAD:lib.nvim/Backlog/README.md" })
  ok(committed_readme:find("(./TASKS/" .. moved .. ")", 1, true), "the own row is committed")
  ok(not committed_readme:find("theirs", 1, true), "the other session's row is not")
  ok(committed_readme ~= base_readme, "the README changed")
  committed_index = git({ "show", "HEAD:lib.nvim/ROADMAP/TASKS.md" })
  ok(not committed_index:find("finish.md", 1, true), "the finished task left the index")

  -- Another session commits while this one builds (here: during the first index run): `HEAD` moved, so the commit is
  -- built again on top of theirs; theirs is kept, not reverted by a tree built on the old `HEAD`.
  local real_index = vim.trim(git({ "rev-parse", "--path-format=absolute", "--git-path", "index" }))
  local stage_area = index.stage_area
  local fired = false
  index.stage_area = function(...)
    if not fired then
      fired = true
      local out = vim
        .system({
          "git",
          "-C",
          root,
          "commit",
          "-q",
          "-m",
          "theirs",
          "--",
          "cascade.nvim/ROADMAP/tasks/foreign-staged.md",
        }, { text = true, env = { GIT_INDEX_FILE = real_index } })
        :wait()
      eq(out.code, 0, "their commit: " .. tostring(out.stderr))
    end
    return stage_area(...)
  end
  F.task(H, root, "lib.nvim", "late", F.meta("Late", "open"))
  local raced, raced_err = require("tasks_nvim.vault_commit").commit(
    { "lib.nvim/ROADMAP/tasks/late.md" },
    { root = root, message = "late" }
  )
  index.stage_area = stage_area
  ok(raced, "the commit after a race: " .. tostring(raced_err))
  eq(raced.attempts, 2, "built twice")
  eq(vim.trim(git({ "log", "-1", "--format=%s", "HEAD~1" })), "theirs", "on top of their commit")
  local _, kept = git({ "cat-file", "-e", "HEAD:cascade.nvim/ROADMAP/tasks/foreign-staged.md" })
  eq(kept, 0, "their file is still in HEAD")

  -- Usage and refusals.
  eq(run({ "commit", "--message=x" }), 2, "no path")
  eq(run({ "commit", "lib.nvim/ROADMAP/tasks/keep.md" }), 2, "no message")
  code, said = run({ "commit", "../outside.md", "--message=x" })
  eq(code, 1, "a path out of the vault is refused: " .. said)
  code, said = run({ "commit", "lib.nvim/ROADMAP/tasks/keep.md", "--message=x" })
  eq(code, 1, "nothing to commit: " .. said)
  ok(said:find("nothing to commit", 1, true), "and says so: " .. said)
  code, said = run({ "commit", "lib.nvim/ROADMAP/tasks/no-such.md", "--message=x" })
  eq(code, 1, "a path that matches nothing: " .. said)
end
