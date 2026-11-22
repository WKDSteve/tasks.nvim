-- TESTS/tasks_vault_push_spec.lua -- `tasks push`: a conflict in a generated TASKS.md is rendered anew, the shared checkout is rebased and keeps the files of other sessions, a second push has nothing to do.

---@diagnostic disable: need-check-nil, param-type-mismatch

return function(H)
  local eq, ok = H.eq, H.ok
  local F = dofile(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)) .. "/fixture.lua")
  local index = require("tasks_nvim.index")
  local R =
    dofile(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)) .. "/vault_remote_fixture.lua")(H)
  local git, run, setup_remote, add_task, remote_indexes_fresh =
    R.git, R.run, R.setup_remote, R.add_task, R.remote_indexes_fresh

  -- 1. A conflict in a generated TASKS.md, a foreign uncommitted index in the tree -----------------------------------
  do
    local root, other, bare = setup_remote()
    local mine = add_task(root, "lib.nvim", "mine")
    add_task(other, "lib.nvim", "theirs")
    eq(
      select(2, git(other, { "push", "-q", "origin", "main" })),
      0,
      "the other session pushes first"
    )

    -- positive control: a plain pull of that state does conflict in TASKS.md
    local probe = H.tmpdir() .. "/probe"
    git(root, { "worktree", "add", "-q", "--detach", probe, "origin/main" })
    git(root, { "fetch", "-q" })
    git(probe, { "reset", "-q", "--hard", "origin/main" })
    local _, pick_code = git(probe, { "cherry-pick", mine })
    eq(pick_code, 1, "without the push command the pick conflicts")
    eq(
      git(probe, { "diff", "--name-only", "--diff-filter=U" }),
      "lib.nvim/ROADMAP/TASKS.md",
      "in TASKS.md"
    )
    git(probe, { "cherry-pick", "--abort" })
    git(root, { "worktree", "remove", "--force", probe })

    -- a file of another session in the tree: an uncommitted task and the index that counts it
    F.task(H, root, "lib.nvim", "foreign", F.meta("Foreign", "open"))
    ok(
      index.write_area("lib.nvim", { root = root }),
      "the tree's index lists every session's tasks"
    )
    H.write(
      root .. "/cascade.nvim/ROADMAP/tasks/other.md",
      F.text(F.meta("Other (edited)", "open"))
    )

    local code, said = run(root, { "push" })
    eq(code, 0, "push: " .. said)
    ok(said:find("pushed\t", 1, true), "names the pushed commits: " .. said)
    ok(said:find("synced", 1, true), "and the sync: " .. said)

    local check = remote_indexes_fresh(bare, "one")
    local text = H.read(check .. "/lib.nvim/ROADMAP/TASKS.md")
    ok(
      text:find("mine", 1, true) and text:find("theirs", 1, true),
      "both tasks are in the index on the remote"
    )
    ok(not text:find("<<<<<<<", 1, true), "no conflict marker")
    ok(not text:find("foreign", 1, true), "the foreign task stays out of the push")
    eq(
      git(root, { "rev-list", "origin/main..HEAD" }),
      "",
      "the shared checkout has nothing left to push"
    )
    eq(
      git(root, { "rev-parse", "HEAD" }),
      git(root, { "rev-parse", "origin/main" }),
      "and sits on origin/main"
    )
    eq(git(root, { "stash", "list" }), "", "no autostash is left")
    eq(git(root, { "diff", "--name-only", "--diff-filter=U" }), "", "nothing unmerged")
    ok(
      H.read(root .. "/lib.nvim/ROADMAP/tasks/foreign.md"),
      "the foreign file is still in the tree"
    )
    ok(
      H.read(root .. "/cascade.nvim/ROADMAP/tasks/other.md"):find("edited", 1, true),
      "and the edited one"
    )
    ok(
      H.read(root .. "/lib.nvim/ROADMAP/TASKS.md"):find("foreign", 1, true),
      "the tree's index still counts the foreign task"
    )
    local worktrees = git(root, { "worktree", "list", "--porcelain" })
    eq(select(2, worktrees:gsub("worktree ", "")), 1, "the throwaway worktree is gone")

    -- nothing left: says so
    code, said = run(root, { "push" })
    eq(code, 0, "second push")
    ok(said:find("nothing to push", 1, true), "nothing to push: " .. said)
  end
end
