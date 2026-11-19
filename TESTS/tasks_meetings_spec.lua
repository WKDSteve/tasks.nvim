-- TESTS/tasks_meetings_spec.lua -- meeting files (`<area>/MEETINGS/`): the fields, the sections of the body, the codes
-- of a broken file, the service of an address, durations, notifications, the listing and the tasks a meeting names.
-- @scans-data: the folders it lists are the fixture vault in the temp folder

---@diagnostic disable: need-check-nil, param-type-mismatch
-- Why: a value is bound with assert()/ok() in the same body, so a nil fails the spec at that line.

return function(H)
  local eq, ok = H.eq, H.ok
  local F = dofile(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)) .. "/fixture.lua")
  local meetings = require("tasks_nvim.meetings")
  local vault = require("tasks_nvim.vault")

  ---@param fields string[]   # frontmatter lines `key: value`
  ---@param body? string
  ---@return string
  local function file(fields, body)
    return "---\n" .. table.concat(fields, "\n") .. "\n---\n" .. (body or "Short note.\n")
  end

  ---@param fields string[]
  ---@param body? string
  ---@return Tasks.Meeting
  local function parse(fields, body)
    return meetings.parse(
      file(fields, body),
      { path = "/v/lib.nvim/MEETINGS/sync.md", area = "lib.nvim", slug = "sync" }
    )
  end

  ---@param m Tasks.Meeting
  ---@param code string
  ---@return boolean
  local function has(m, code)
    return vim.tbl_contains(m.error_codes, code)
  end

  -- ── a full meeting ──
  local body = table.concat({
    "Sync on the install.",
    "",
    "## Agenda",
    "- [x] State of team 1",
    "- [ ] Licence question",
    "",
    "## Teilnehmer",
    "- [x] Rick <rick@example.org> (Organisator)",
    "- [ ] Stefan (Ich)",
    "- Aleks",
    "",
    "## Unterlagen",
    "- [Slides](assets/slides.pdf)",
    "- https://example.org/wiki/x",
    "- [Share](C:/Users/x/doc.docx)",
    "- just a note",
    "",
    "## Protokoll",
    "<!-- notes -->",
    "",
    "## Beschlüsse",
    "- Start on 2026-12-01.",
    "",
    "## Folgeaufgaben",
    "- [ ] Clarify the licence -> lib.nvim/licence",
    "- [x] Prepare the test system",
    "",
    "## Ergebnis",
    "Agreed on the start.",
    "",
  }, "\n")
  local m = parse({
    'title: "Sync with Rick"',
    "status: planned",
    "date: 2026-11-24",
    'time: "14:00"',
    'end: "15:30"',
    "tz: Europe/Vienna",
    'location: "Room 3"',
    "online: https://teams.microsoft.com/l/meetup-join/abc",
    "tasks: [lib.nvim/install, cascade.nvim/demo, lib.nvim/install]",
    "notify: [-15m, -1D@18:00]",
    "notify_to: [me@example.org]",
    "image: assets/images/cover.jpg",
    "icon: handshake",
    "tags: [sync]",
    "created: 2026-11-19",
  }, body)
  ok(m.valid, table.concat(m.errors, "; "))
  eq(m.id, "lib.nvim/sync")
  eq(m.title, "Sync with Rick")
  eq(m.status, "planned")
  eq(m.start, "2026-11-24T14:00")
  eq(m.ends, "2026-11-24T15:30")
  eq(m.duration_min, 90)
  eq(m.end_time, "15:30")
  eq(m.all_day, false)
  eq(m.tz, "Europe/Vienna")
  eq(m.location, "Room 3")
  eq(m.online_service, "teams")
  eq(m.tasks, { "lib.nvim/install", "cascade.nvim/demo" }, "a task named twice is one")
  eq(m.notify, {
    { spec = "-15m", before_min = 15 },
    { spec = "-1d@18:00", days_before = 1, at = "18:00" },
  })
  eq(m.notify_to, { "me@example.org" })
  eq(m.image, "assets/images/cover.jpg")
  eq(m.icon, "handshake")
  eq(m.summary, "Sync on the install.")
  eq(#m.agenda, 2)
  eq(m.agenda[1], { n = 1, text = "State of team 1", ticked = true })
  eq(m.participants, {
    { n = 1, name = "Rick", email = "rick@example.org", role = "Organisator", present = true },
    { n = 2, name = "Stefan", role = "Ich", present = false },
    { n = 3, name = "Aleks", present = false },
  })
  eq(m.documents[1], { n = 1, text = "Slides", kind = "asset", href = "assets/slides.pdf" })
  eq(m.documents[2].kind, "web")
  eq(m.documents[3].kind, "path")
  eq(m.documents[3].href, nil, "a path of a machine is never named")
  eq(m.documents[4].kind, "text")
  eq(m.followups, {
    { n = 1, text = "Clarify the licence", ticked = false, task = "lib.nvim/licence" },
    { n = 2, text = "Prepare the test system", ticked = true },
  })
  eq(m.has_result, true)
  eq(m.has_decisions, true)
  eq(m.has_protocol, false, "a section with only a comment is empty")

  -- the arrow character names the task too
  local arrow = parse(
    { "title: x", "status: done", "date: 2026-11-24" },
    "## Follow-ups\n- [ ] Do it " .. string.char(0xE2, 0x86, 0x92) .. " lib.nvim/do-it\n"
  )
  eq(arrow.followups[1].task, "lib.nvim/do-it")
  eq(arrow.followups[1].text, "Do it")
  eq(arrow.has_result, false)
  -- a bare word after the arrow is no task id
  local word = parse(
    { "title: x", "status: done", "date: 2026-11-24" },
    "## Folgeaufgaben\n- [ ] Ask -> later\n"
  )
  eq(word.followups[1], { n = 1, text = "Ask -> later", ticked = false })
  eq(arrow.all_day, true)
  eq(arrow.start, "2026-11-24")
  eq(arrow.ends, "2026-11-24")

  -- ── times ──
  local over =
    parse({ "title: x", "status: planned", "date: 2026-11-24", 'time: "23:30"', "duration: 1h30m" })
  ok(over.valid, table.concat(over.errors, "; "))
  eq(over.ends, "2026-11-25T01:00", "past midnight with a duration")
  local days = parse({ "title: x", "status: planned", "date: 2026-11-30", "duration: 48h" })
  eq(days.ends, "2026-12-01", "an all-day meeting of two days")

  ok(has(parse({ "title: x", "status: planned", "date: 2026-02-30" }), "meeting-bad-date"))
  ok(has(parse({ "title: x", "status: planned" }), "meeting-bad-date"), "a date is required")
  ok(
    has(
      parse({ "title: x", "status: planned", "date: 2026-11-24", 'time: "25:00"' }),
      "meeting-bad-time"
    )
  )
  ok(has(
    parse({
      "title: x",
      "status: planned",
      "date: 2026-11-24",
      'time: "10:00"',
      'end: "11:00"',
      "duration: 1h",
    }),
    "meeting-end-and-duration"
  ))
  ok(
    has(
      parse({ "title: x", "status: planned", "date: 2026-11-24", 'time: "10:00"', 'end: "09:00"' }),
      "meeting-end-before-start"
    )
  )
  ok(
    has(
      parse({ "title: x", "status: planned", "date: 2026-11-24", 'end: "09:00"' }),
      "meeting-end-without-time"
    )
  )
  ok(
    has(
      parse({ "title: x", "status: planned", "date: 2026-11-24", "duration: 2x" }),
      "meeting-bad-duration"
    )
  )
  ok(
    has(
      parse({ "title: x", "status: planned", "date: 2026-11-24", "duration: 20000m" }),
      "meeting-bad-duration"
    )
  )

  -- ── the other fields ──
  ok(
    has(parse({ "title: x", "status: held", "date: 2026-11-24" }), "meeting-bad-status"),
    "no held (F4)"
  )
  ok(has(parse({ "title: x", "date: 2026-11-24" }), "meeting-bad-status"), "a status is required")
  ok(has(parse({ "status: planned", "date: 2026-11-24" }), "title-missing"))
  ok(
    has(
      parse({ "title: x", "status: planned", "date: 2026-11-24", "tz: vienna" }),
      "meeting-bad-tz"
    )
  )
  ok(
    has(
      parse({ "title: x", "status: planned", "date: 2026-11-24", "online: ftp://x" }),
      "meeting-bad-online"
    )
  )
  ok(
    has(
      parse({ "title: x", "status: planned", "date: 2026-11-24", "recording: x" }),
      "meeting-bad-recording"
    )
  )
  ok(
    has(
      parse({ "title: x", "status: planned", "date: 2026-11-24", "tasks: [nope]" }),
      "meeting-bad-task"
    )
  )
  ok(
    has(
      parse({ "title: x", "status: planned", "date: 2026-11-24", "notify: [15m]" }),
      "meeting-bad-notify"
    )
  )
  ok(
    has(
      parse({
        "title: x",
        "status: planned",
        "date: 2026-11-24",
        "notify: [-1m, -2m, -3m, -4m, -5m, -6m]",
      }),
      "meeting-bad-notify"
    ),
    "at most five"
  )
  ok(
    has(
      parse({ "title: x", "status: planned", "date: 2026-11-24", "notify_to: [nobody]" }),
      "meeting-bad-notify-to"
    )
  )
  ok(
    has(
      parse({ "title: x", "status: planned", "date: 2026-11-24", "image: ../x.png" }),
      "meeting-bad-image"
    )
  )
  ok(
    has(
      parse({ "title: x", "status: planned", "date: 2026-11-24", "image: C:/x.png" }),
      "meeting-bad-image"
    )
  )
  ok(
    has(
      parse({ "title: x", "status: planned", "date: 2026-11-24", "icon: rocket" }),
      "meeting-bad-icon"
    )
  )
  ok(
    has(
      meetings.parse("no frontmatter", { path = "/v/a/MEETINGS/x.md", area = "a" }),
      "frontmatter-missing"
    )
  )
  ok(
    has(
      meetings.parse(file({ "title: x" }), { path = "/v/a/MEETINGS/Bad_Name.md", area = "a" }),
      "slug"
    )
  )

  -- ── the pieces ──
  eq(meetings.online_service("https://us02web.zoom.us/j/1"), "zoom")
  eq(meetings.online_service("https://zoom.us/j/1"), "zoom")
  eq(meetings.online_service("https://notzoom.us/j/1"), "link", "a suffix needs the dot")
  eq(meetings.online_service("https://meet.google.com/abc"), "meet")
  eq(meetings.online_service("https://acme.webex.com/meet/x"), "webex")
  eq(meetings.online_service("https://meet.jit.si/room"), "jitsi")
  eq(
    meetings.online_service("https://user@Teams.Live.com:443/x"),
    "teams",
    "user, port and case do not count"
  )
  eq(meetings.online_service("https://example.org"), "link")
  eq(meetings.online_service("javascript:alert(1)"), nil)
  eq(meetings.parse_duration("45m"), 45)
  eq(meetings.parse_duration("2h"), 120)
  eq(meetings.parse_duration("1h30m"), 90)
  eq(meetings.parse_duration("0m"), nil)
  eq(meetings.parse_duration("1.5h"), nil)
  eq(meetings.parse_notify("-2h"), { spec = "-2h", before_min = 120 })
  eq(meetings.parse_notify("-0d@08:00"), { spec = "-0d@08:00", days_before = 0, at = "08:00" })
  eq(meetings.parse_notify("-31d@08:00"), nil)
  eq(meetings.parse_notify("-1d@24:00"), nil)
  eq(meetings.parse_notify("+15m"), nil)
  ok(meetings.is_tz("America/Argentina/Buenos_Aires"))
  ok(meetings.is_tz("Etc/GMT+2"))
  ok(meetings.is_tz("UTC"))
  ok(not meetings.is_tz("Europe/"))
  ok(not meetings.is_tz("../etc"))

  -- ── on disk: listing, finding, the tasks of a meeting, the namespace ──
  local root = F.vault(H)
  local dir = root .. "/lib.nvim/MEETINGS"
  H.write(
    dir .. "/late.md",
    file({ "title: Late", "status: planned", "date: 2026-12-01", "tasks: [lib.nvim/a]" })
  )
  H.write(
    dir .. "/early/early.md",
    file({
      "title: Early",
      "status: done",
      "date: 2026-11-01",
      'time: "09:00"',
      "tasks: [lib.nvim/a, lib.nvim/b]",
    })
  )
  H.write(dir .. "/early/assets/board.svg", "<svg/>")
  H.write(dir .. "/broken.md", "no frontmatter")
  local list = meetings.area("lib.nvim", { root = root })
  eq(
    vim.tbl_map(function(x)
      return x.slug
    end, list),
    { "broken", "early", "late" }
  )
  eq(list[2].folder, true)
  ok(list[2].etag and list[2].etag:match("^sha256:"), "a meeting has an etag")
  eq(list[1].valid, false, "a broken meeting is still listed")
  eq(meetings.area("cascade.nvim", { root = root }), {}, "an area without MEETINGS has none")
  local all = meetings.all({ root = root })
  eq(#all, 3)
  local by = meetings.by_task(all)
  eq(by["lib.nvim/a"], { "lib.nvim/early", "lib.nvim/late" }, "the earliest first")
  eq(by["lib.nvim/b"], { "lib.nvim/early" })

  local found = meetings.find("lib.nvim/early", { root = root })
  eq(found.title, "Early")
  local none, err = meetings.find("lib.nvim/nope", { root = root })
  eq(none, nil)
  ok(err:find("no such meeting", 1, true))
  ok(select(2, meetings.find("nope", { root = root })))

  ok(vault.has_plan_or_project(root, "lib.nvim", "late"), "a meeting takes its slug")
  ok(vault.has_plan_or_project(root, "lib.nvim", "early"), "in its folder form too")
  ok(not vault.has_plan_or_project(root, "lib.nvim", "other"))
  H.write(dir .. "/late/late.md", file({ "title: Twice", "status: planned", "date: 2026-12-01" }))
  ok(select(2, vault.resolve_meeting(root, "lib.nvim", "late")):find("file and as folder", 1, true))
  ok(vault.has_plan_or_project(root, "lib.nvim", "late"), "a slug that is file and folder is taken")

  -- the cache: an unchanged file is not parsed again, a changed one is
  meetings.reset_cache()
  local p = dir .. "/cached.md"
  H.write(p, file({ "title: One", "status: planned", "date: 2026-11-24" }))
  local uv = vim.uv or vim.loop
  local old = os.time() - 60
  uv.fs_utime(p, old, old)
  eq(meetings.from_file(p, { area = "lib.nvim", slug = "cached" }).title, "One")
  H.write(p, file({ "title: Two!", "status: planned", "date: 2026-11-24" }))
  uv.fs_utime(p, old + 1, old + 1)
  eq(
    meetings.from_file(p, { area = "lib.nvim", slug = "cached" }).title,
    "Two!",
    "a changed file is read again"
  )
end
