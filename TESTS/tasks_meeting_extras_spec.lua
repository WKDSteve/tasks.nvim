-- TESTS/tasks_meeting_extras_spec.lua -- the extras of a meeting (concept 4.4): the agenda proposals of `tasks.meeting`
-- (open tasks and their open questions, a finished task and an answered question propose nothing, a text the agenda
-- has is left out, the revision follows the task files) and `meeting_new` with `prep` (the task due the day before,
-- named in `tasks:`, a dry run, a refusal that leaves no task behind); and `overlap: ok` in the contract and the writer.
-- @scans-data: the folders it lists are the fixture vault in the temp folder

---@diagnostic disable: need-check-nil, param-type-mismatch
-- Why: a value is bound with assert()/ok() in the same body, so a nil fails the spec at that line.

return function(H)
  local eq, ok = H.eq, H.ok
  local F = dofile(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)) .. "/fixture.lua")
  local contract = require("tasks_nvim.contract")
  local meetings = require("tasks_nvim.meetings")
  local ops_mod = require("tasks_nvim.ops")
  local scan = require("tasks_nvim.scan")

  local root = F.vault(H)
  meetings.reset_cache()
  H.write(
    root .. "/lib.nvim/ROADMAP/tasks/install.md",
    table.concat({
      "---",
      "title: Install Tosca",
      "status: open",
      "created: 2026-10-01",
      "---",
      "",
      "## Offene Fragen",
      "",
      "### Which version? [q1]",
      "- [ ] 2025.1 (empfohlen)",
      "- [ ] 2024.2",
      "",
      "### Which machine? [q2]",
      "- [x] The VM",
      "- [ ] The laptop",
      "",
    }, "\n")
  )
  F.task(H, root, "lib.nvim", "licence", F.meta("Get the licence", "open"))
  H.write(
    root .. "/lib.nvim/Backlog/TASKS/2026-10-02_shipped.md",
    "---\ntitle: Shipped\nstatus: done\ncreated: 2026-09-01\n---\n\nDone.\n"
  )
  require("tasks_nvim.index").write_area("lib.nvim", { root = root })
  H.write(
    root .. "/lib.nvim/MEETINGS/sync.md",
    table.concat({
      "---",
      "title: Sync",
      "status: planned",
      "date: 2026-10-20",
      'time: "14:00"',
      "duration: 1h",
      "tasks: [lib.nvim/install, lib.nvim/shipped, lib.nvim/licence]",
      "---",
      "",
      "## Agenda",
      "",
      "- [ ] Get the licence",
      "",
    }, "\n")
  )

  -- ── agenda proposals ──
  local doc = assert(contract.meeting("lib.nvim/sync", { root = root }))
  eq(
    doc.agenda_proposals,
    {
      { text = "Install Tosca", task = "lib.nvim/install", kind = "task" },
      {
        text = "Which version? (Install Tosca)",
        task = "lib.nvim/install",
        kind = "question",
        key = "q1",
      },
    },
    "open tasks and open questions; the finished task, the answered question and the agenda line are left out"
  )
  ok(vim.tbl_contains(contract.CAPABILITIES, "meeting_agenda_proposals"))

  -- the revision follows a task file: answering the question changes the document
  local rev = doc.rev
  H.write(
    root .. "/lib.nvim/ROADMAP/tasks/install.md",
    (H.read(root .. "/lib.nvim/ROADMAP/tasks/install.md"):gsub("%- %[ %] 2025%.1", "- [x] 2025.1"))
  )
  meetings.reset_cache()
  local after = assert(contract.meeting("lib.nvim/sync", { root = root }))
  ok(after.rev ~= rev, "a changed task file is a new revision")
  eq(#after.agenda_proposals, 1, "the answered question proposes nothing")

  -- a meeting without tasks proposes nothing (an empty list)
  H.write(
    root .. "/lib.nvim/MEETINGS/alone.md",
    "---\ntitle: Alone\nstatus: planned\ndate: 2026-10-21\n---\n\nNote.\n"
  )
  meetings.reset_cache()
  eq(assert(contract.meeting("lib.nvim/alone", { root = root })).agenda_proposals, {})

  -- ── meeting_new with prep ──
  local function run(list, dry)
    local res, err = ops_mod.run(
      { ops = list, dry_run = dry or nil },
      { root = root, today = F.TODAY }
    )
    assert(res, tostring(err))
    eq(#res.results, 1)
    meetings.reset_cache()
    return res.results[1]
  end
  local op = {
    op = "meeting_new",
    area = "lib.nvim",
    title = "Workshop",
    fields = { date = "2026-11-03", time = "09:00", tasks = { "lib.nvim/licence" } },
    prep = true,
  }
  local dry = run({ op }, true)
  eq(dry.outcome, "would_create", vim.inspect(dry))
  eq(dry.prep.id, "lib.nvim/vorbereitung-workshop", vim.inspect(dry))
  ok(not scan.find("lib.nvim/vorbereitung-workshop", { root = root }), "a dry run makes no task")

  local made = run({ op })
  eq(made.outcome, "created", vim.inspect(made))
  eq(made.prep.id, "lib.nvim/vorbereitung-workshop")
  eq(made.changed_ids, { made.id, "lib.nvim/vorbereitung-workshop" })
  local prep = assert(scan.find("lib.nvim/vorbereitung-workshop", { root = root }))
  eq(prep.title, "Vorbereitung: Workshop")
  eq(prep.due, "2026-11-02", "due the day before")
  local m = assert(meetings.find(made.id, { root = root }))
  eq(
    m.tasks,
    { "lib.nvim/licence", "lib.nvim/vorbereitung-workshop" },
    "the meeting names its preparation"
  )

  -- English, an own title; the first of a month: the last day of the month before
  local en = run({
    {
      op = "meeting_new",
      area = "lib.nvim",
      title = "Review",
      lang = "en",
      fields = { date = "2026-12-01" },
      prep = true,
    },
  })
  eq(assert(scan.find(en.prep.id, { root = root })).title, "Prepare: Review")
  eq(assert(scan.find(en.prep.id, { root = root })).due, "2026-11-30")
  local own = run({
    {
      op = "meeting_new",
      area = "lib.nvim",
      title = "Retro",
      fields = { date = "2026-12-05" },
      prep = true,
      prep_title = "Collect the points",
    },
  })
  eq(assert(scan.find(own.prep.id, { root = root })).title, "Collect the points")

  -- a meeting that cannot be written leaves no task behind
  local before = #vim.fn.readdir(root .. "/lib.nvim/ROADMAP/tasks")
  local bad = run({
    {
      op = "meeting_new",
      area = "lib.nvim",
      title = "Broken",
      fields = { date = "2026-12-06", time = "25:00" },
      prep = true,
    },
  })
  eq(bad.ok, false, vim.inspect(bad))
  eq(
    #vim.fn.readdir(root .. "/lib.nvim/ROADMAP/tasks"),
    before,
    "no preparation task without its meeting"
  )
  eq(
    run({ { op = "meeting_new", area = "lib.nvim", title = "No day", prep = true } }).error.code,
    "invalid_argument"
  )

  -- a Lua error while the meeting is written (after the task was made) takes the task back as well
  local mw = require("tasks_nvim.meeting_write")
  local real_new = mw.new
  mw.new = function(area, o)
    if o and o.dry_run then
      return real_new(area, o)
    end
    error("disk on fire")
  end
  local called = pcall(ops_mod.run, {
    ops = {
      {
        op = "meeting_new",
        area = "lib.nvim",
        title = "Crash",
        fields = { date = "2026-12-07" },
        prep = true,
      },
    },
  }, { root = root, today = F.TODAY })
  mw.new = real_new
  meetings.reset_cache()
  ok(called ~= nil, "the run came back or threw")
  ok(
    not scan.find("lib.nvim/vorbereitung-crash", { root = root }),
    "no preparation task is left after a Lua error"
  )
  eq(#vim.fn.readdir(root .. "/lib.nvim/ROADMAP/tasks"), before, "the tasks folder is as before")

  -- a meeting title near the limit: the preparation title is cut to the limit, not refused
  local long = string.rep("x", require("tasks_nvim.contract").LIMITS.title - 4)
  local cut = run({
    {
      op = "meeting_new",
      area = "lib.nvim",
      title = long,
      fields = { date = "2026-12-08" },
      prep = true,
    },
  })
  eq(cut.ok, true, vim.inspect(cut))
  local cut_title = assert(scan.find(cut.prep.id, { root = root })).title
  eq(vim.fn.strchars(cut_title), require("tasks_nvim.contract").LIMITS.title, "at the limit")
  ok(vim.startswith(cut_title, "Vorbereitung: xxx"), cut_title)
  ok(vim.endswith(cut_title, "\226\128\166"), "with an ellipsis: " .. cut_title)

  -- without lang: the language of the vault (its marker file), not always German
  local marker = require("tasks_nvim.vault_marker")
  H.write(root .. "/" .. marker.FILE, marker.render({ lang = "en" }))
  local vault_en = run({
    {
      op = "meeting_new",
      area = "lib.nvim",
      title = "Planning",
      fields = { date = "2026-12-09" },
      prep = true,
    },
  })
  H.write(root .. "/" .. marker.FILE, marker.render({}))
  eq(assert(scan.find(vault_en.prep.id, { root = root })).title, "Prepare: Planning")

  -- ── overlap: ok ──
  local quiet = run({
    {
      op = "meeting_new",
      area = "lib.nvim",
      title = "Parallel",
      fields = { date = "2026-11-03", time = "09:30", overlap = "ok" },
    },
  })
  eq(quiet.outcome, "created", vim.inspect(quiet))
  local entry = assert(contract.meeting(quiet.id, { root = root })).meeting
  eq(entry.overlap, "ok")
  eq(assert(contract.meeting(made.id, { root = root })).meeting.overlap, nil)
  local wrong = run({
    {
      op = "meeting_new",
      area = "lib.nvim",
      title = "Wrong",
      fields = { date = "2026-11-03", overlap = "yes" },
    },
  })
  eq(wrong.ok, false, "overlap takes only ok")
end
