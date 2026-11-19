-- TESTS/tasks_meetings_contract_spec.lua -- the meetings in the contract: `meetings` (window, filters, pages,
-- undated), `meeting` (body and sections), the derived `meetings` of a task entry, the revision and the handshake.
-- @scans-data: the folders it lists are the fixture vault in the temp folder

---@diagnostic disable: need-check-nil, param-type-mismatch
-- Why: a value is bound with assert()/ok() in the same body, so a nil fails the spec at that line.

return function(H)
  local eq, ok = H.eq, H.ok
  local F = dofile(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)) .. "/fixture.lua")
  local api = require("tasks_nvim.api")
  local meetings = require("tasks_nvim.meetings")

  local root = F.vault(H)
  meetings.reset_cache()

  ---@param method string
  ---@param params? table
  ---@return table doc
  ---@return string|nil code
  local function call(method, params)
    local text = api.call(method, { params = params or {} }, { root = root, today = F.TODAY })
    local doc = vim.json.decode(text)
    return doc, doc.kind == "tasks.error" and doc.code or nil
  end

  ---@param path string
  ---@param fields string[]
  ---@param body? string
  local function meeting(path, fields, body)
    H.write(path, "---\n" .. table.concat(fields, "\n") .. "\n---\n" .. (body or "Note.\n"))
  end

  H.write(
    root .. "/lib.nvim/ROADMAP/tasks/install.md",
    "---\ntitle: Install\nstatus: open\ncreated: 2026-10-01\n---\n\nA task.\n"
  )
  H.write(
    root .. "/lib.nvim/ROADMAP/tasks/alone.md",
    "---\ntitle: Alone\nstatus: open\ncreated: 2026-10-01\n---\n\nA task.\n"
  )

  -- a task entry without meetings reads as before, and the vault keeps its revision
  local before = call("snapshot")
  local rev_before = before.rev
  for _, t in ipairs(before.tasks) do
    eq(t.meetings, nil, "no meetings field without meetings")
  end

  local dir = root .. "/lib.nvim/MEETINGS"
  meeting(
    dir .. "/sync/sync.md",
    {
      'title: "Sync"',
      "status: planned",
      "date: 2026-10-05",
      'time: "14:00"',
      "duration: 1h",
      "online: https://teams.microsoft.com/l/x",
      "tasks: [lib.nvim/install]",
      "notify: [-15m, -1d@18:00]",
      "image: assets/cover.png",
    },
    table.concat({
      "Sync on the install.",
      "",
      "## Teilnehmer",
      "- [x] Rick <rick@example.org> (Organisator)",
      "- [ ] Stefan",
      "",
      "## Unterlagen",
      "- [Slides](assets/slides.pdf)",
      "- [Share](C:/Users/x/secret.docx)",
      "",
      "## Folgeaufgaben",
      "- [ ] Clarify -> lib.nvim/clarify",
      "",
    }, "\n")
  )
  H.write(dir .. "/sync/assets/cover.png", "png")
  meeting(
    dir .. "/kickoff.md",
    { "title: Kickoff", "status: done", "date: 2026-09-20", "tasks: [lib.nvim/install]" }
  )
  meeting(dir .. "/far.md", { "title: Far", "status: planned", "date: 2027-06-01" })
  meeting(dir .. "/nodate.md", { "title: No date", "status: planned" })
  meeting(
    root .. "/cascade.nvim/MEETINGS/other.md",
    { "title: Other", "status: cancelled", "date: 2026-10-04" }
  )

  -- ── the derived field of a task entry and the revision ──
  local snap = call("snapshot")
  ok(snap.rev ~= rev_before, "a meeting file changes the revision")
  local by_id = {}
  for _, t in ipairs(snap.tasks) do
    by_id[t.id] = t
  end
  eq(
    by_id["lib.nvim/install"].meetings,
    { "lib.nvim/kickoff", "lib.nvim/sync" },
    "the earliest first"
  )
  eq(by_id["lib.nvim/alone"].meetings, nil)
  local task = call("task", { id = "lib.nvim/install" })
  eq(task.task.meetings, { "lib.nvim/kickoff", "lib.nvim/sync" })
  local listed = call("list", { area = "lib.nvim" })
  for _, t in ipairs(listed.items) do
    if t.id == "lib.nvim/install" then
      eq(t.meetings, { "lib.nvim/kickoff", "lib.nvim/sync" })
    end
  end
  local again = call("snapshot")
  eq(again.rev, snap.rev, "an unchanged vault keeps its revision")
  eq(again.digest, snap.digest)

  -- ── meetings: the default window (30 days back, 90 ahead of today 2026-10-03) ──
  local doc = call("meetings")
  eq(doc.kind, "tasks.meetings")
  eq(doc.since, "2026-09-03")
  eq(doc["until"], "2027-01-01")
  eq(
    vim.tbl_map(function(m)
      return m.id
    end, doc.items),
    { "lib.nvim/kickoff", "cascade.nvim/other", "lib.nvim/sync" },
    "earliest first, across areas; the far one is outside"
  )
  eq(doc.undated, 1)
  eq(doc.total, 3)
  local sync = doc.items[3]
  eq(sync.starts_at, "2026-10-05T14:00")
  eq(sync.ends_at, "2026-10-05T15:00")
  eq(sync.duration_min, 60)
  eq(sync.all_day, false)
  eq(sync.online_service, "teams")
  eq(sync.tasks, { "lib.nvim/install" })
  eq(sync.notify, {
    { spec = "-15m", before_min = 15 },
    { spec = "-1d@18:00", days_before = 1, at = "18:00" },
  })
  eq(sync.participants, { total = 2, present = 1 })
  eq(sync.followups, { total = 1, ticked = 0 })
  eq(sync.folder, true)
  eq(sync.assets, { "assets/cover.png" })
  eq(sync.file, "lib.nvim/MEETINGS/sync/sync.md")
  ok(sync.etag:match("^sha256:"))
  eq(sync.valid, true)

  -- filters, window, pages
  eq(#call("meetings", { area = "cascade.nvim" }).items, 1)
  eq(#call("meetings", { status = { "done" } }).items, 1)
  eq(#call("meetings", { task = "lib.nvim/install" }).items, 2)
  eq(#call("meetings", { since = "2027-01-01", ["until"] = "2027-12-31" }).items, 1)
  local page = call("meetings", { limit = 2 })
  eq(#page.items, 2)
  eq(page.next_offset, 2)
  eq(#call("meetings", { limit = 2, offset = 2 }).items, 1)
  eq(select(2, call("meetings", { since = "2026-13-01" })), "invalid_argument")
  eq(
    select(2, call("meetings", { since = "2026-10-10", ["until"] = "2026-10-01" })),
    "invalid_argument"
  )
  eq(select(2, call("meetings", { status = { "held" } })), "invalid_argument")
  eq(select(2, call("meetings", { task = "nope" })), "invalid_argument")
  eq(select(2, call("meetings", { limit = 0 })), "invalid_argument")
  eq(select(2, call("meetings", { area = "nowhere" })), "not_found")
  eq(select(2, call("meetings", { colour = "red" })), "invalid_argument", "an unknown parameter")

  -- ── meeting: body and sections ──
  local one = call("meeting", { id = "lib.nvim/sync" })
  eq(one.kind, "tasks.meeting")
  eq(one.meeting.id, "lib.nvim/sync")
  ok(one.body:find("## Teilnehmer", 1, true))
  eq(one.body_truncated, false)
  eq(one.participants[1], {
    n = 1,
    name = "Rick",
    email = "rick@example.org",
    role = "Organisator",
    present = true,
  })
  eq(one.documents[1], { n = 1, text = "Slides", kind = "asset", href = "assets/slides.pdf" })
  eq(one.documents[2].kind, "path")
  eq(one.documents[2].href, nil, "a path of a machine is never named")
  eq(one.followups[1], { n = 1, text = "Clarify", ticked = false, task = "lib.nvim/clarify" })
  eq(select(2, call("meeting", { id = "lib.nvim/nope" })), "not_found")
  eq(select(2, call("meeting", { id = "nope" })), "invalid_argument")
  eq(select(2, call("meeting", {})), "invalid_argument", "id is required")

  -- a broken meeting is still there, with its problems
  local nodate = call("meeting", { id = "lib.nvim/nodate" })
  eq(nodate.meeting.valid, false)
  eq(nodate.meeting.problems[1].code, "meeting-bad-date")

  -- ── the handshake ──
  local hello = call("hello")
  ok(vim.tbl_contains(hello.capabilities, "meetings"))
  ok(vim.tbl_contains(hello.capabilities, "meeting"))
  eq(hello.enums.meeting_status, { "planned", "done", "cancelled" })
  eq(hello.enums.online_service, meetings.SERVICES)
  eq(hello.enums.meeting_icon, meetings.ICONS)
end
