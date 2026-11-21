-- TESTS/tasks_index_staged_spec.lua -- `index <area> --staged`: the index comes from the staging area.
-- In a shared checkout the tree also holds another session's uncommitted tasks; they must not reach the
-- staged index, and nothing in the tree may change.

---@diagnostic disable: need-check-nil, param-type-mismatch

return function(H)
  local eq, ok = H.eq, H.ok
  local F = dofile(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)) .. "/fixture.lua")
  local index = require("tasks_nvim.index")

  local root = F.vault(H)

  ---@param args string[]
  ---@return string stdout
  ---@return integer code
  local function git(args)
    local res = vim.system(vim.list_extend({ "git", "-C", root }, args), { text = true }):wait()
    return res.stdout or "", res.code
  end

  local _, init_code = git({ "init", "-q" })
  eq(init_code, 0, "git init")
  -- A Windows runner sets autocrlf: the checkout would differ from the render by its line endings and
  -- every run would read as "written". The blob comes out the same either way (`hash-object --path`).
  git({ "config", "core.autocrlf", "false" })

  F.task(H, root, "lib.nvim", "own-task", F.meta("Own task", "open"))
  -- Every file there is so far, the own task among them; the foreign one comes after.
  git({ "add", "." })
  local foreign = F.task(H, root, "lib.nvim", "foreign-task", F.meta("Foreign task", "open"))

  local tree_index = root .. "/lib.nvim/ROADMAP/TASKS.md"
  ok(vim.fn.filereadable(tree_index) == 0, "no index in the tree yet")

  local res, err = index.stage_area("lib.nvim", { root = root })
  ok(res, tostring(err))
  eq(res.action, "written", "the staged index is new")
  eq(res.path, "lib.nvim/ROADMAP/TASKS.md", "the path is relative to the repository")

  local staged, show_code = git({ "show", ":lib.nvim/ROADMAP/TASKS.md" })
  eq(show_code, 0, "the index is staged")
  ok(staged:find("own-task", 1, true), "it lists the staged task")
  ok(not staged:find("foreign-task", 1, true), "and not the one only in the tree")

  ok(vim.fn.filereadable(tree_index) == 0, "the tree has no index afterwards either")
  ok(vim.fn.filereadable(foreign) == 1, "the foreign task stays where it is")
  local status = git({ "status", "--porcelain", "--", "lib.nvim/ROADMAP/tasks/foreign-task.md" })
  ok(status:find("^%?%?"), "and stays untracked: " .. status)

  -- A second run finds nothing to do.
  local again = index.stage_area("lib.nvim", { root = root })
  eq(again.action, "unchanged", "the second run changes nothing")

  -- A tracked task changed in the tree only (another session's claim): the staged index keeps the staged
  -- version. The repro of 2026-11-19 had nothing staged but that file committed.
  local _, commit_code =
    git({ "-c", "user.name=t", "-c", "user.email=t@example.org", "commit", "-q", "-m", "seed" })
  eq(commit_code, 0, "seed commit")
  local own = root .. "/lib.nvim/ROADMAP/tasks/own-task.md"
  local committed_text = table.concat(vim.fn.readfile(own), "\n")
  vim.fn.writefile(vim.split(committed_text:gsub("status: open", "status: doing"), "\n"), own)
  local claimed = index.stage_area("lib.nvim", { root = root })
  ok(claimed, "the run after a tree-only change succeeds")
  local staged_after = git({ "show", ":lib.nvim/ROADMAP/TASKS.md" })
  local row = staged_after:match("[^\n]*own%-task[^\n]*") or ""
  ok(not row:find("doing", 1, true), "the row keeps the staged status, not the tree's: " .. row)
  eq(claimed.action, "unchanged", "nothing to stage: the staged task did not change")
  eq(claimed.staged, {}, "nothing of the area is staged apart from HEAD")

  -- What really happened on 2026-11-19: an autostash that hit a conflict left the claim of the other session
  -- staged. The index is built from the staging area, so the run must name that file.
  git({ "add", "--", "lib.nvim/ROADMAP/tasks/own-task.md" })
  local listed = index.stage_area("lib.nvim", { root = root })
  ok(listed, "a staged change of a task is no error")
  eq(listed.action, "written", "the staged claim reaches the index")
  eq(listed.staged, { "lib.nvim/ROADMAP/tasks/own-task.md" }, "and the run names the staged file")
  vim.fn.writefile(vim.split(committed_text, "\n"), own)
  git({ "add", "--", "lib.nvim/ROADMAP/tasks/own-task.md" })
  index.stage_area("lib.nvim", { root = root })

  ---Put `rel` into the staging area as a conflict of three versions (`ls-files -u`).
  ---@param rel string
  local function conflict(rel)
    local blobs = {}
    for i, text in ipairs({ "base\n", "ours\n", "theirs\n" }) do
      local out = vim
        .system({ "git", "-C", root, "hash-object", "-w", "--stdin" }, { text = true, stdin = text })
        :wait()
      blobs[i] = vim.trim(out.stdout or "")
    end
    git({ "update-index", "--force-remove", "--", rel })
    local info = {}
    for i, blob in ipairs(blobs) do
      info[i] = ("100644 %s %d\t%s"):format(blob, i, rel)
    end
    local out = vim
      .system(
        { "git", "-C", root, "update-index", "--index-info" },
        { text = true, stdin = table.concat(info, "\n") .. "\n" }
      )
      :wait()
    eq(out.code, 0, "update-index --index-info: " .. tostring(out.stderr))
  end

  -- A task file in conflict would drop out of the index without a word (`checkout-index` skips it): refused.
  local stray = "lib.nvim/ROADMAP/tasks/stray.md"
  conflict(stray)
  local refused, refused_err = index.stage_area("lib.nvim", { root = root })
  eq(refused, nil, "a conflict in a task file is refused")
  ok(
    tostring(refused_err):find("conflict", 1, true) and tostring(refused_err):find(stray, 1, true),
    "and the message names it: " .. tostring(refused_err)
  )
  git({ "update-index", "--force-remove", "--", stray })

  -- A conflict in the generated index alone is what this run resolves.
  conflict("lib.nvim/ROADMAP/TASKS.md")
  local resolved, resolved_err = index.stage_area("lib.nvim", { root = root })
  ok(resolved, "a conflicted index is rewritten: " .. tostring(resolved_err))
  local left = git({ "ls-files", "--unmerged" })
  eq(left, "", "and the conflict is gone")

  -- The last open task leaves the staging area: the index goes with it.
  git({ "rm", "-q", "--cached", "--", "lib.nvim/ROADMAP/tasks/own-task.md" })
  local gone = index.stage_area("lib.nvim", { root = root })
  eq(gone.action, "removed", "an area without open tasks loses its index")
  local _, gone_code = git({ "show", ":lib.nvim/ROADMAP/TASKS.md" })
  ok(gone_code ~= 0, "and it is out of the staging area")

  -- A conflicted index of an area without open tasks: nothing to write, the conflict still goes.
  conflict("lib.nvim/ROADMAP/TASKS.md")
  local dropped = index.stage_area("lib.nvim", { root = root })
  eq(dropped and dropped.action, "removed", "the conflicted index of an empty area is removed")
  eq(git({ "ls-files", "--unmerged" }), "", "and leaves no conflict behind")

  local none, none_err = index.stage_area("no-such.nvim", { root = root })
  eq(none, nil, "an unknown area is an error")
  ok(tostring(none_err):find("unknown area", 1, true), "and says so: " .. tostring(none_err))

  -- A linked worktree of the vault (`git worktree add`; `.git` is a file there), as on 2026-11-21: a staged
  -- deletion reaches the staging area of exactly that worktree, the main checkout's stays as it was, and the
  -- run says that the tree's index file is not the staged one (that is what `check` reads).
  local main = F.vault(H)
  local function git_in(dir, args)
    local out = vim.system(vim.list_extend({ "git", "-C", dir }, args), { text = true }):wait()
    return out.stdout or "", out.code
  end
  git_in(main, { "init", "-q" })
  git_in(main, { "config", "core.autocrlf", "false" })
  F.task(H, main, "lib.nvim", "keep-task", F.meta("Keep task", "open"))
  F.task(H, main, "lib.nvim", "done-task", F.meta("Done task", "open"))
  ok(index.write_area("lib.nvim", { root = main }), "seed index")
  git_in(main, { "add", "." })
  local _, seed_code = git_in(
    main,
    { "-c", "user.name=t", "-c", "user.email=t@example.org", "commit", "-q", "-m", "seed" }
  )
  eq(seed_code, 0, "seed commit of the main checkout")
  local linked = vim.fn.tempname() .. "-linked"
  local _, add_code = git_in(main, { "worktree", "add", "-q", linked, "HEAD" })
  eq(add_code, 0, "git worktree add")
  ok(vim.fn.isdirectory(linked .. "/.git") == 0, ".git is a file in a linked worktree")
  local main_index_before = git_in(main, { "ls-files", "-s" })

  git_in(linked, { "rm", "-q", "--", "lib.nvim/ROADMAP/tasks/done-task.md" })
  local wres, werr = index.stage_area("lib.nvim", { root = linked })
  ok(wres, "the run in the linked worktree succeeds: " .. tostring(werr))
  eq(wres.action, "written", "the deletion changes the staged index")
  local linked_staged = git_in(linked, { "show", ":lib.nvim/ROADMAP/TASKS.md" })
  ok(
    linked_staged:find("keep-task", 1, true),
    "the linked worktree's staged index keeps the open task"
  )
  ok(not linked_staged:find("done-task", 1, true), "and drops the deleted one")
  eq(
    git_in(main, { "ls-files", "-s" }),
    main_index_before,
    "the main checkout's staging area is untouched"
  )
  eq(git_in(main, { "status", "--porcelain" }), "", "and its tree too")
  eq(wres.tree_differs, true, "the run says the tree keeps the old index file")

  -- Brought in line after the commit, the next run has nothing to say about the tree.
  git_in(
    linked,
    { "-c", "user.name=t", "-c", "user.email=t@example.org", "commit", "-q", "-m", "done" }
  )
  git_in(linked, { "checkout", "--", "lib.nvim/ROADMAP/TASKS.md" })
  local settled = index.stage_area("lib.nvim", { root = linked })
  eq(settled.action, "unchanged", "nothing left to stage")
  eq(settled.tree_differs, false, "and the tree's index is the staged one")
  git_in(main, { "worktree", "remove", "--force", linked })
end
