-- TESTS/tasks_milestones_editor_spec.lua -- the milestones in the editor: `:Tasks done` names a milestone the finish
-- reached, `:Tasks milestones` shows them in a float (status, due, members done of all, overdue).
-- @scans-data: the spec lists its fixture vault in the temp folder only

---@diagnostic disable: need-check-nil
-- Why: a value is bound with assert()/ok() in the same body, so a nil fails the spec at that line.

return function(H)
  local eq, ok, has = H.eq, H.ok, H.has
  local F = dofile(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)) .. "/fixture.lua")
  local cmd = require("tasks_nvim.ui.cmd")
  local ops = require("tasks_nvim.ops")

  -- ── the lines of the float ────────────────────────────────────────────────
  eq(cmd.milestone_lines({ items = {} }), { "no milestones" })
  eq(
    cmd.milestone_lines({
      items = {
        {
          id = "a/r1",
          status = "doing",
          due = "2026-03-01",
          overdue = true,
          title = "Release 1",
          progress = { members = 3, members_done = 1 },
        },
        {
          id = "a/r2",
          status = "planning",
          title = "Release 2",
          progress = { members = 0, members_done = 0 },
        },
      },
    }),
    {
      "a/r1  doing  due 2026-03-01  1/3  overdue  Release 1",
      "a/r2  planning  due -  0/0  Release 2",
    }
  )

  -- ── on a vault ────────────────────────────────────────────────────────────
  local root = F.vault(H)
  F.task(H, root, "lib.nvim", "ship-it", F.meta("Ship it", "open", {}))
  local made = ops.run({
    ops = {
      {
        op = "milestone_new",
        area = "lib.nvim",
        title = "First release",
        includes = { "lib.nvim/ship-it" },
        due = "2026-12-01",
      },
    },
  }, { root = root, today = F.TODAY })
  ok(made.results[1].ok, vim.inspect(made.results[1]))
  local ms_id = made.results[1].id

  require("tasks_nvim.vault").set_root(root)
  local told = {}
  local orig_notify = vim.notify
  vim.notify = function(msg)
    told[#told + 1] = msg
  end
  local wins_before = #vim.api.nvim_list_wins()
  local ran, rerr = pcall(function()
    -- the float: one line per milestone
    cmd.task_milestones({ args = {}, kv = {}, flags = {}, rest = {} })
    eq(#vim.api.nvim_list_wins(), wins_before + 1, "a float opened")
    local float = vim.api.nvim_list_wins()[#vim.api.nvim_list_wins()]
    local text =
      table.concat(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(float), 0, -1, false), "\n")
    has(text, ms_id .. "  ")
    has(text, "due 2026-12-01  0/1")
    vim.api.nvim_win_close(float, true)

    -- the finish names the milestone it reached
    cmd.task_done({ args = { id = "lib.nvim/ship-it" }, kv = {}, flags = { yes = true }, rest = {} })
    -- (the next task's word comes after it: look at every message of the finish)
    local all = table.concat(told, "\n")
    has(all, "done lib.nvim/ship-it")
    has(all, "milestone reached: " .. ms_id)

    -- a word for a stray argument, nothing opened
    local n = #vim.api.nvim_list_wins()
    cmd.task_milestones({ args = {}, kv = {}, flags = {}, rest = { "x" } })
    eq(#vim.api.nvim_list_wins(), n)
  end)
  vim.notify = orig_notify
  require("tasks_nvim.vault").set_root(nil)
  ok(ran, tostring(rerr))
end
