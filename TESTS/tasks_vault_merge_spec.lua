-- TESTS/tasks_vault_merge_spec.lua -- the merge way of the generated files: `tasks merge-driver install` puts git's
-- driver for ROADMAP/TASKS.md into the repository, and a rebase, a cherry-pick or an autostash that touches the index
-- of one area from two sides is no conflict any more (without it: a conflict, the positive control). Backlog/README.md
-- and the history series keep the rows of both sides (`union`).

---@diagnostic disable: need-check-nil, param-type-mismatch

return function(H)
  local eq, ok = H.eq, H.ok
  local F = dofile(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)) .. "/fixture.lua")
  local index = require("tasks_nvim.index")
  local vault_merge = require("tasks_nvim.vault_merge")
  local R =
    dofile(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)) .. "/vault_remote_fixture.lua")(H)
  local git, run, setup_remote, add_task = R.git, R.run, R.setup_remote, R.add_task

  -- the driver itself: a clean three-way merge is written to %A, a conflicting one leaves %A as it was
  do
    local base, ours, theirs = H.tmpdir() .. "/base", H.tmpdir() .. "/ours", H.tmpdir() .. "/theirs"
    H.write(base, "a\nb\nc\nd\ne\n")
    H.write(ours, "a\nB\nc\nd\ne\n")
    H.write(theirs, "a\nb\nc\nd\nE\n")
    eq(vault_merge.driver(base, ours, theirs), "merged", "disjoint changes merge")
    eq(H.read(ours), "a\nB\nc\nd\nE\n", "both changes are in %A")
    H.write(ours, "a\nB\nc\nd\ne\n")
    H.write(theirs, "a\nX\nc\nd\ne\n")
    eq(vault_merge.driver(base, ours, theirs), "kept-ours", "the same line on both sides: no merge")
    eq(H.read(ours), "a\nB\nc\nd\ne\n", "%A stays as it was")
    eq(
      select(2, vault_merge.driver(base, base .. "-gone", theirs)) ~= nil,
      true,
      "an unreadable file is an error"
    )
  end

  -- the driver is not part of the repository: absent, then installed, then outdated
  local root, other = setup_remote()
  local st = vault_merge.status({ root = root })
  eq(st.state, "absent", "no driver yet")
  eq(st.attributes, false, "and no attribute lines")
  local code, said = run(root, { "merge-driver", "status" })
  eq(code, 1, "status exits 1 when it is not installed: " .. said)

  -- positive control: the same history without the driver conflicts in TASKS.md
  local function diverge(dir_a, dir_b)
    local theirs = add_task(dir_b, "lib.nvim", "theirs")
    git(dir_b, { "push", "-q", "origin", "main" })
    add_task(dir_a, "lib.nvim", "mine")
    return theirs
  end
  diverge(root, other)
  git(root, { "fetch", "-q" })
  local _, c = git(root, { "rebase", "origin/main" })
  eq(c, 1, "without the driver the rebase conflicts")
  eq(
    git(root, { "diff", "--name-only", "--diff-filter=U" }),
    "lib.nvim/ROADMAP/TASKS.md",
    "in the index"
  )
  git(root, { "rebase", "--abort" })

  code, said = run(root, { "merge-driver", "install" })
  eq(code, 0, "install: " .. said)
  ok(said:find("installed\ttasks-index", 1, true), "reports the driver: " .. said)
  ok(said:find("attribute\t", 1, true), "and the lines it added: " .. said)
  st = vault_merge.status({ root = root })
  eq(st.state, "installed", "installed")
  eq(st.attributes, true, "attribute lines are there")
  local attrs = H.read(root .. "/.gitattributes")
  ok(attrs:find("*/ROADMAP/TASKS.md merge=tasks-index", 1, true), "the index line: " .. attrs)
  ok(attrs:find("*/Backlog/README.md merge=union", 1, true), "the README line")
  ok(attrs:find("_Telemetry/history/*.jsonl merge=union", 1, true), "the series line")
  _, said = run(root, { "merge-driver", "install" })
  ok(
    said:find("unchanged\ttasks-index", 1, true) and not said:find("attribute\t", 1, true),
    "again: " .. said
  )
  eq(select(1, run(root, { "merge-driver", "status" })), 0, "status exits 0")
  git(root, { "config", "merge.tasks-index.driver", "false" })
  eq(vault_merge.status({ root = root }).state, "outdated", "another command line is outdated")
  run(root, { "merge-driver", "install" })
  eq(vault_merge.status({ root = root }).state, "installed", "and install brings it back")
  -- the attribute lines are part of the vault: they arrive with origin/main (the rebase reads them from the tree it
  -- builds on)
  git(other, { "pull", "-q", "--rebase" })
  H.write(other .. "/.gitattributes", attrs)
  git(other, { "add", ".gitattributes" })
  git(other, { "commit", "-q", "-m", "attributes" })
  git(other, { "push", "-q", "origin", "main" })
  os.remove(root .. "/.gitattributes")

  -- with the driver the same rebase goes through; nothing is left unmerged
  git(root, { "fetch", "-q" })
  local out, rc = git(root, { "rebase", "origin/main" })
  eq(rc, 0, "with the driver the rebase has no conflict: " .. out)
  eq(git(root, { "diff", "--name-only", "--diff-filter=U" }), "", "nothing unmerged")
  local text = H.read(root .. "/lib.nvim/ROADMAP/TASKS.md")
  ok(not text:find("<<<<<<<", 1, true), "no conflict marker in the index")
  -- the merge may leave an old rendering; the next render makes it right (and `index --check` finds it before that)
  ok(index.write_area("lib.nvim", { root = root }), "render the index")
  text = H.read(root .. "/lib.nvim/ROADMAP/TASKS.md")
  ok(
    text:find("mine", 1, true) and text:find("theirs", 1, true),
    "both tasks are in the rendered index"
  )

  -- the autostash of a pull: the tree's own TASKS.md (rendered with another session's task) against the commit
  -- of another session that changed the same table; the stash applies without a conflict and is gone
  git(root, { "reset", "-q", "--hard", "origin/main" })
  local bsha = add_task(other, "lib.nvim", "later")
  git(other, { "push", "-q", "origin", "main" })
  F.task(H, root, "lib.nvim", "uncommitted", F.meta("Uncommitted", "open"))
  ok(index.write_area("lib.nvim", { root = root }), "tree index with the uncommitted task")
  git(root, { "fetch", "-q" })
  out, rc = git(root, { "pull", "--rebase", "--autostash", "-q" })
  eq(rc, 0, "pull --rebase --autostash: " .. out)
  eq(git(root, { "stash", "list" }), "", "no stash is left")
  eq(git(root, { "diff", "--name-only", "--diff-filter=U" }), "", "nothing unmerged")
  eq(git(root, { "rev-parse", "HEAD" }), bsha, "on the other session's commit")
  ok(
    H.read(root .. "/lib.nvim/ROADMAP/tasks/uncommitted.md"),
    "the uncommitted task is still there"
  )
  text = H.read(root .. "/lib.nvim/ROADMAP/TASKS.md")
  ok(not text:find("<<<<<<<", 1, true), "no marker in the index of the tree")

  -- the series and the READMEs keep the rows of both sides
  H.write(
    root .. "/lib.nvim/Backlog/README.md",
    H.read(root .. "/lib.nvim/Backlog/README.md") .. "| mine-row |\n"
  )
  git(root, { "commit", "-q", "-am", "readme row" })
  H.write(
    other .. "/lib.nvim/Backlog/README.md",
    H.read(other .. "/lib.nvim/Backlog/README.md") .. "| their-row |\n"
  )
  git(other, { "commit", "-q", "-am", "readme row elsewhere" })
  git(other, { "push", "-q", "origin", "main" })
  git(root, { "fetch", "-q" })
  out, rc = git(root, { "rebase", "origin/main" })
  eq(rc, 0, "README rows of both sides rebase: " .. out)
  text = H.read(root .. "/lib.nvim/Backlog/README.md")
  ok(
    text:find("| mine-row |", 1, true) and text:find("| their-row |", 1, true),
    "both rows: " .. text
  )
end
