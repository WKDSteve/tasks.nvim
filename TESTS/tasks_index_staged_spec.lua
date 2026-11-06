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

  -- The last open task leaves the staging area: the index goes with it.
  git({ "rm", "-q", "--cached", "--", "lib.nvim/ROADMAP/tasks/own-task.md" })
  local gone = index.stage_area("lib.nvim", { root = root })
  eq(gone.action, "removed", "an area without open tasks loses its index")
  local _, gone_code = git({ "show", ":lib.nvim/ROADMAP/TASKS.md" })
  ok(gone_code ~= 0, "and it is out of the staging area")

  local none, none_err = index.stage_area("no-such.nvim", { root = root })
  eq(none, nil, "an unknown area is an error")
  ok(tostring(none_err):find("unknown area", 1, true), "and says so: " .. tostring(none_err))
end
