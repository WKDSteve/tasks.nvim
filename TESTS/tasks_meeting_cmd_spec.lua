-- TESTS/tasks_meeting_cmd_spec.lua -- `:Tasks meeting ...` in the editor: the routes are in the flat grammar, the picker
-- puts the coming meetings first, a label names day, status, title and place, `open` jumps to a section, `new` makes a
-- meeting from a quick line and opens it, `close` marks it done.
-- @scans-data: the folders it lists are the fixture vault in the temp folder

---@diagnostic disable: need-check-nil
-- Why: a value is bound with assert()/ok() in the same body, so a nil fails the spec at that line.

return function(H)
  local eq, ok, has = H.eq, H.ok, H.has
  local F = dofile(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)) .. "/fixture.lua")
  local meetings = require("tasks_nvim.meetings")
  local mc = require("tasks_nvim.ui.meeting_cmd")

  -- the routes: `:Tasks meeting list|open|new|close`
  local paths = {}
  for _, r in ipairs(require("tasks_nvim.ui.routes").routes({ flat = true })) do
    paths[#paths + 1] = table.concat(r.path, " ")
  end
  for _, want in ipairs({ "meeting list", "meeting open", "meeting new", "meeting close" }) do
    ok(vim.tbl_contains(paths, want), want .. " in " .. vim.inspect(paths))
  end

  -- order and label (pure)
  local function m(id, status, date, extra)
    return vim.tbl_extend(
      "force",
      { id = id, status = status, date = date, start = date, title = id, area = "a" },
      extra or {}
    )
  end
  local ordered = mc.order({
    m("a/old", "done", "2026-09-01"),
    m("a/later", "planned", "2026-10-20"),
    m("a/soon", "planned", "2026-10-04"),
    m("a/past", "planned", "2026-09-10"),
    m("a/older", "done", "2026-08-01"),
  }, "2026-10-03")
  local ids = vim.tbl_map(function(x)
    return x.id
  end, ordered)
  eq(ids, { "a/soon", "a/later", "a/past", "a/old", "a/older" })
  local label =
    mc.label(m("a/x", "planned", "2026-10-04", { time = "14:00", online_service = "teams" }))
  has(label, "2026-10-04 14:00")
  has(label, "@teams")
  has(label, "(a/x)")

  -- new, open at a section, close: in a vault
  local root = F.vault(H)
  meetings.reset_cache()
  -- the editor's commands take the vault of the environment; given back at the end
  local env_was = vim.env.TASKS_VAULT
  vim.env.TASKS_VAULT = root
  mc.new({ args = { area = "lib.nvim" }, rest = { "2026-10-05", "14:00-15:00", "Sync", "@Raum_1" } })
  meetings.reset_cache()
  local made = assert(meetings.find("lib.nvim/sync-2026-10-05", { root = root }))
  eq(made.time, "14:00")
  eq(made.location, "Raum 1")
  eq(vim.fs.normalize(vim.api.nvim_buf_get_name(0)), vim.fs.normalize(made.path))
  eq(vim.api.nvim_win_get_cursor(0)[1], mc.section_line(made.path, "agenda"))
  mc.open(made, "protokoll")
  eq(vim.api.nvim_win_get_cursor(0)[1], mc.section_line(made.path, "protocol"))
  ok(mc.section_line(made.path, "protocol") > mc.section_line(made.path, "agenda"))
  mc.close({ args = { id = made.id }, flags = { result = "Gut." } })
  meetings.reset_cache()
  local closed = assert(meetings.find(made.id, { root = root }))
  eq(closed.status, "done")
  eq(closed.has_result, true)
  vim.cmd("bwipeout!")
  vim.env.TASKS_VAULT = env_was
end
