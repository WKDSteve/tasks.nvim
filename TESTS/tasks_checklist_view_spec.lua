-- TESTS/tasks_checklist_view_spec.lua -- `:Tasks checklist ...` in the editor: the routes, the filter line, the lines
-- of a list buffer, the commands `checklist`, `checklist new`, `checklist add` (by slug, through `:Tasks`) and the
-- buffer-local keys: add, tick and open again, the state and the filter, open as a file, make a task, delete, close.
-- @scans-data: the folders it lists are the fixture vault in the temp folder

---@diagnostic disable: need-check-nil
-- Why: a value is bound with assert()/ok() in the same body, so a nil fails the spec at that line.

return function(H)
  local eq, ok, has = H.eq, H.ok, H.has
  local F = dofile(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)) .. "/fixture.lua")
  local checklist = require("tasks_nvim.checklist")
  local fsio = require("tasks_nvim.fsio")
  local cv = require("tasks_nvim.ui.checklist_view")

  -- ── the routes ──────────────────────────────────────────────────────────────
  local paths = {}
  for _, r in ipairs(require("tasks_nvim.ui.routes").routes({ flat = true })) do
    paths[#paths + 1] = table.concat(r.path, " ")
  end
  for _, want in ipairs({ "checklist", "checklist new", "checklist add" }) do
    ok(vim.tbl_contains(paths, want), want .. " in " .. vim.inspect(paths))
  end
  ok(vim.tbl_contains(paths, "lists"), "`:Tasks lists` stays the named lists of the dashboard")

  -- ── the filter line (pure) ──────────────────────────────────────────────────
  local f, problems = cv.parse_filter(
    "#SAP since:2026-11-01 until:7d state:Open ticket  anlegen since:gestern state:maybe",
    "2026-11-25"
  )
  eq(f.tag, "sap")
  eq(f.since, nil, "a since that cannot be read is dropped, not the one before it kept")
  eq(f["until"], "2026-11-18", "7d is seven days before today")
  eq(f.state, "open")
  eq(f.q, "ticket anlegen")
  eq(problems, { "since:gestern", "state:maybe" })
  f = cv.parse_filter("since:2w until:today", "2026-11-25")
  eq(f.since, "2026-11-11")
  eq(f["until"], "2026-11-25")
  eq(f.state, "all", "no state word: all")
  local back = cv.format_filter({
    tag = "sap",
    since = "2026-11-01",
    ["until"] = "2026-11-18",
    state = "done",
    q = "ticket",
  })
  eq(back, "#sap since:2026-11-01 until:2026-11-18 state:done ticket")
  eq(cv.format_filter({ state = "all" }), "")
  eq(cv.list_id("support"), "_list-support")
  eq(cv.list_id("_list-support"), "_list-support")

  -- ── the lines of a list (pure) ──────────────────────────────────────────────
  local list = { id = "_list-x", title = "Support\nFälle", slug = "x" }
  local open_e = {
    id = "_list-x/b",
    title = "Ticket",
    created = "2026-11-25T10:00:00Z",
    tags = { "sap", "hiva" },
  }
  local done_e = {
    id = "_list-x/a",
    title = "Alt",
    created = "2026-11-20T10:00:00Z",
    tags = {},
    done = "2026-11-24",
  }
  local lines, rows, marks = cv.render(
    list,
    { open_e, done_e },
    { open_e, done_e },
    { state = "all" }
  )
  eq(lines[1], "Support Fälle  ·  1 open of 2", "a line break of a title is a blank")
  has(lines[2], "filter: none")
  eq(lines[4], "[ ] 2026-11-25  Ticket  #sap #hiva")
  eq(lines[5], "[x] 2026-11-20  Alt  (done 2026-11-24)")
  eq(rows[4].id, "_list-x/b")
  eq(rows[5].id, "_list-x/a")
  eq(rows[1], nil, "the heading is no entry")
  local dimmed = false
  for _, m in ipairs(marks) do
    if m.line == 4 and m.group == "TasksChecklistDone" then
      dimmed = true
    end
  end
  ok(dimmed, "a ticked entry is dimmed")
  lines = cv.render(list, { open_e, done_e }, {}, { state = "open", tag = "x" })
  has(lines[2], "filter: #x state:open  ·  0 shown")
  has(lines[4], "nothing matches the filter")
  lines = cv.render(list, {}, {}, { state = "all" })
  has(lines[4], "no entries yet")
  has(cv.label({ id = "_list-x", title = "X", open = 2, total = 5 }), "(2 open of 5)  _list-x")

  -- ── commands and keys in a vault ────────────────────────────────────────────
  local root = F.vault(H)
  local env_was = vim.env.TASKS_VAULT
  vim.env.TASKS_VAULT = root
  local input_was, select_was = vim.ui.input, vim.ui.select
  local confirm = require("tasks_nvim.ui.confirm")
  local yesno_was = confirm.yesno
  local answers = {}
  ---@diagnostic disable-next-line: duplicate-set-field
  vim.ui.input = function(opts, cb)
    answers.input_opts = opts
    cb(table.remove(answers, 1))
  end
  local function press(keys)
    vim.api.nvim_feedkeys(vim.keycode(keys), "mx", false)
  end
  local function line(n)
    return vim.api.nvim_buf_get_lines(0, n - 1, n, false)[1]
  end
  local function cursor_entry()
    return cv.entry_at_cursor(vim.api.nvim_get_current_buf())
  end

  cv.cmd_new({ rest = { "Support", "Fälle" } })
  local buf = vim.api.nvim_get_current_buf()
  eq(
    vim.api.nvim_buf_get_name(buf):match("tasks%-checklist://.*$"),
    "tasks-checklist://_list-support-faelle"
  )
  has(line(1), "Support Fälle  ·  0 open of 0")
  has(line(4), "no entries yet")

  -- `:Tasks checklist add <slug> ...`: the type takes the slug, the rest is the line
  require("tasks_nvim.bindings.usrcmds").register()
  vim.cmd("Tasks checklist add support-faelle SAP Ticket #sap")
  eq(line(4):match("^%[ %] %d+%-%d+%-%d+  SAP Ticket  #sap$") ~= nil, true, line(4))

  -- a adds; the cursor lands on the new entry (the newest: first)
  answers[1] = "Zweiter #hiva"
  press("a")
  has(line(4), "Zweiter  #hiva")
  eq(vim.api.nvim_win_get_cursor(0)[1], 4)
  local second = cursor_entry()
  eq(second.title, "Zweiter")

  -- x ticks, x again opens it again, the cursor stays on the entry
  press("x")
  has(line(4), "[x]")
  has(line(4), "(done ")
  has(fsio.read(second.path), "done: ")
  eq(cursor_entry().id, second.id)
  press("x")
  eq(line(4):sub(1, 3), "[ ]")
  ok(not fsio.read(second.path):find("done:", 1, true), "opened again: no done in the file")
  press("x")

  -- s cycles all -> open -> done -> all
  press("s")
  has(line(2), "state:open")
  has(line(4), "SAP Ticket")
  eq(line(5), nil, "only the open one")
  press("s")
  has(line(4), "Zweiter")
  eq(line(5), nil, "only the done one")
  press("s")
  eq(#vim.api.nvim_buf_get_lines(0, 0, -1, false), 5, "all again")

  -- f reads a filter line (shown again as its default), F clears it
  answers[1] = "#sap"
  press("f")
  eq(answers.input_opts.default, "")
  has(line(4), "SAP Ticket")
  eq(line(5), nil)
  answers[1] = "since:2000-01-01 zweit"
  press("f")
  has(line(4), "Zweiter")
  eq(line(5), nil, "words and a period, through checklist.filter")
  press("F")
  has(line(2), "filter: none")

  -- <CR> opens the entry as a file; back in the list, it is drawn again
  vim.api.nvim_win_set_cursor(0, { 5, 0 })
  local sap = cursor_entry()
  press("<CR>")
  eq(vim.fs.normalize(vim.api.nvim_buf_get_name(0)), vim.fs.normalize(sap.path))

  -- `:Tasks attach <entry> <file>`: the entry takes the folder form, its open buffer follows
  local shot = H.tmpdir() .. "/shot.png"
  H.write(shot, "png")
  vim.cmd("Tasks attach " .. sap.id .. " " .. vim.fn.fnameescape(shot))
  local moved = assert(checklist.find(sap.id, root))
  eq(moved.folder, true, "the entry is a folder now")
  ok(fsio.is_file(fsio.dirname(moved.path) .. "/assets/shot.png"), "the file is in its assets/")
  eq(
    vim.fs.normalize(vim.api.nvim_buf_get_name(0)),
    vim.fs.normalize(moved.path),
    "the open buffer follows"
  )
  vim.cmd("buffer " .. buf)
  has(line(5), "SAP Ticket")

  -- T makes a task of an area: the entry is gone, the task is there
  local offered
  ---@diagnostic disable-next-line: duplicate-set-field
  vim.ui.select = function(items, _, cb)
    offered = items
    cb("lib.nvim")
  end
  vim.api.nvim_win_set_cursor(0, { 5, 0 })
  press("T")
  ok(vim.tbl_contains(offered, "lib.nvim"), vim.inspect(offered))
  eq(#checklist.entries(root, "_list-support-faelle"), 1, "the entry is gone")
  ok(
    fsio.is_file(root .. "/lib.nvim/ROADMAP/tasks/sap-ticket/assets/shot.png"),
    "the task is there, with the attachment"
  )
  eq(line(5), nil)

  -- D deletes after the question; a No keeps it
  local asked
  ---@diagnostic disable-next-line: duplicate-set-field
  confirm.yesno = function(msg, _, cb)
    asked = msg
    cb(false)
  end
  vim.api.nvim_win_set_cursor(0, { 4, 0 })
  press("D")
  has(asked, '"Zweiter"')
  eq(#checklist.entries(root, "_list-support-faelle"), 1, "No keeps it")
  ---@diagnostic disable-next-line: duplicate-set-field
  confirm.yesno = function(_, _, cb)
    cb(true)
  end
  press("D")
  eq(#checklist.entries(root, "_list-support-faelle"), 0, "Yes deletes it")
  has(line(4), "no entries yet")

  -- the picker names title and counts; picked, the list is shown (the same buffer again)
  vim.cmd("enew")
  local picked
  ---@diagnostic disable-next-line: duplicate-set-field
  vim.ui.select = function(items, opts, cb)
    picked = opts.format_item(items[1])
    cb(items[1])
  end
  vim.cmd("Tasks checklist")
  has(picked, "Support Fälle  (0 open of 0)  _list-support-faelle")
  eq(vim.api.nvim_get_current_buf(), buf, "one buffer per list")

  -- q closes it
  press("q")
  ok(not vim.api.nvim_buf_is_valid(buf), "q wipes the list buffer")

  vim.ui.input, vim.ui.select, confirm.yesno = input_was, select_was, yesno_was
  vim.env.TASKS_VAULT = env_was
end
