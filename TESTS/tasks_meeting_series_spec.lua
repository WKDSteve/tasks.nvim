-- TESTS/tasks_meeting_series_spec.lua -- series of meetings: `repeat`, `repeat_until`, `except` and `series` read and
-- refused, the days of the occurrences (weeks, months at the end of a month, a window far after the first day, the
-- cut), the window of `meetings` (computed occurrences, an occurrence with a file in their place, a moved one),
-- `meeting` of an occurrence without a file, and the first entry that gives an occurrence its file (`meeting_capture`,
-- `meeting_set` to cancel, `meeting_close`, `attach`; a dry run, a stale version, a change that changes nothing).
-- @scans-data: the folders it lists are the fixture vault in the temp folder

---@diagnostic disable: need-check-nil, param-type-mismatch
-- Why: a value is bound with assert()/ok() in the same body, so a nil fails the spec at that line.

return function(H)
  local eq, ok = H.eq, H.ok
  local F = dofile(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)) .. "/fixture.lua")
  local api = require("tasks_nvim.api")
  local meetings = require("tasks_nvim.meetings")
  local ops_mod = require("tasks_nvim.ops")

  ---@param fields string[]
  ---@param slug? string
  ---@return Tasks.Meeting
  local function parse(fields, slug)
    slug = slug or "weekly"
    return meetings.parse(
      "---\n" .. table.concat(fields, "\n") .. "\n---\n\nNote.\n",
      { path = "/v/a/MEETINGS/" .. slug .. ".md", area = "a", slug = slug }
    )
  end
  local function codes(m)
    return table.concat(m.error_codes, ",")
  end
  local BASE = { "title: Weekly", "status: planned", "date: 2026-10-05", 'time: "10:00"' }
  local function with(extra)
    local out = vim.list_slice(BASE, 1)
    vim.list_extend(out, extra)
    return out
  end

  -- ── the fields of a series and of an occurrence ──
  local s = parse(with({ "repeat: weekly", "repeat_until: 2026-12-31", "except: [2026-10-19]" }))
  ok(s.valid, codes(s))
  eq(s.repeat_every, "1w", "weekly is one week")
  eq(s.repeat_until, "2026-12-31")
  eq(s.except, { "2026-10-19" })
  eq(parse(with({ "repeat: 2w" })).repeat_every, "2w")
  eq(codes(parse(with({ "repeat: fortnightly" }))), "meeting-bad-repeat")
  eq(codes(parse(with({ "repeat: 0w" }))), "meeting-bad-repeat")
  eq(
    codes(parse(with({ "repeat_until: 2026-12-31" }))),
    "meeting-bad-repeat-until",
    "without repeat"
  )
  eq(
    codes(parse(with({ "repeat: 1w", "repeat_until: 2026-10-01" }))),
    "meeting-bad-repeat-until",
    "before the first day"
  )
  eq(codes(parse(with({ "repeat: 1w", "repeat_until: 2026-13-01" }))), "meeting-bad-repeat-until")
  eq(codes(parse(with({ "except: [2026-10-12]" }))), "meeting-bad-except", "without repeat")
  eq(codes(parse(with({ "repeat: 1w", "except: [2026-10-32]" }))), "meeting-bad-except")
  local occ = parse(with({ "series: a/weekly" }), "weekly-2026-10-12")
  ok(occ.valid, codes(occ))
  eq(occ.series, "a/weekly")
  eq(occ.occurrence, "2026-10-12", "the day in the slug, not the date of the file")
  eq(codes(parse(with({ "series: a/other" }), "weekly-2026-10-12")), "meeting-bad-series")
  eq(
    codes(parse(with({ "series: b/weekly" }), "weekly-2026-10-12")),
    "meeting-bad-series",
    "other area"
  )
  eq(
    codes(parse(with({ "series: a/weekly" }), "weekly")),
    "meeting-bad-series",
    "no day in the slug"
  )
  eq(
    codes(parse(with({ "series: a/weekly", "repeat: 1w" }), "weekly-2026-10-12")),
    "meeting-bad-series"
  )
  eq(codes(parse(with({ "series: nonsense" }), "weekly-2026-10-12")), "meeting-bad-series")
  eq(
    { meetings.split_occurrence("sync-2026-11-24-2026-12-01") },
    { "sync-2026-11-24", "2026-12-01" }
  )
  eq({ meetings.split_occurrence("sync-2026-02-30") }, {}, "no calendar day")

  -- ── the days of the occurrences ──
  local days, cut = meetings.occurrence_days(s, "2026-10-01", "2026-11-02", 50)
  eq(
    days,
    { "2026-10-05", "2026-10-12", "2026-10-26", "2026-11-02" },
    "weekly, 19 October left out"
  )
  eq(cut, false)
  eq(
    meetings.occurrence_days(s, "2026-12-20", "2027-01-31", 50),
    { "2026-12-21", "2026-12-28" },
    "repeat_until ends it"
  )
  local monthly = parse({ "title: M", "status: planned", "date: 2026-01-31", "repeat: monthly" })
  eq(
    meetings.occurrence_days(monthly, "2026-01-01", "2026-05-31", 50),
    { "2026-01-31", "2026-02-28", "2026-03-31", "2026-04-30", "2026-05-31" },
    "the 31st again after a shorter month"
  )
  local daily = parse({ "title: D", "status: planned", "date: 2000-01-01", "repeat: daily" })
  eq(
    meetings.occurrence_days(daily, "2026-10-05", "2026-10-06", 50),
    { "2026-10-05", "2026-10-06" },
    "a window decades after the first day"
  )
  eq(meetings.occurrence_days(monthly, "2030-03-01", "2030-03-31", 50), { "2030-03-31" })
  local three, more = meetings.occurrence_days(daily, "2026-10-05", "2026-10-30", 3)
  eq(three, { "2026-10-05", "2026-10-06", "2026-10-07" })
  eq(more, true, "the cut is said")
  local workshop = parse({
    "title: W",
    "status: planned",
    "date: 2026-10-05",
    "duration: 2880m",
    "repeat: 1w",
  })
  eq(
    meetings.occurrence_days(workshop, "2026-10-13", "2026-10-13", 50),
    { "2026-10-12" },
    "an occurrence of several days touches the window"
  )
  ok(meetings.is_occurrence_day(s, "2026-10-12"))
  ok(not meetings.is_occurrence_day(s, "2026-10-19"), "an excepted day")
  ok(not meetings.is_occurrence_day(s, "2026-10-13"))
  eq(meetings.occurrence_days(parse(BASE), "2026-10-01", "2026-12-01", 50), {}, "no series")

  -- ── the window of `meetings` ──
  local root = F.vault(H)
  meetings.reset_cache()
  local dir = root .. "/lib.nvim/MEETINGS"
  H.write(
    root .. "/lib.nvim/ROADMAP/tasks/prep.md",
    "---\ntitle: Prep\nstatus: open\ncreated: 2026-10-01\n---\n\nA task.\n"
  )
  local series_text = table.concat({
    "---",
    "title: 1:1 Rick",
    "status: planned",
    "date: 2026-09-28",
    'time: "10:00"',
    "duration: 30m",
    "tasks: [lib.nvim/prep]",
    "repeat: weekly",
    "repeat_until: 2026-10-26",
    "except: [2026-10-12]",
    "created: 2026-09-01",
    "---",
    "",
    "## Agenda",
    "",
    "- [ ] Blockers",
    "",
    "## Protokoll",
    "",
  }, "\n")
  H.write(dir .. "/one-on-one.md", series_text)

  local function call(method, params)
    meetings.reset_cache()
    local doc = vim.json.decode(
      (api.call(method, { params = params or {} }, { root = root, today = F.TODAY }))
    )
    return doc, doc.kind == "tasks.error" and doc.code or nil
  end
  local function ids(doc)
    return vim.tbl_map(function(it)
      return it.id
    end, doc.items)
  end

  local hello = call("hello")
  ok(vim.tbl_contains(hello.capabilities, "meeting_series"), "the capability is announced")

  local list = call("meetings", { since = "2026-09-01", ["until"] = "2026-12-31" })
  eq(ids(list), {
    "lib.nvim/one-on-one-2026-09-28",
    "lib.nvim/one-on-one-2026-10-05",
    "lib.nvim/one-on-one-2026-10-19",
    "lib.nvim/one-on-one-2026-10-26",
  }, "the series as its occurrences, 12 October excepted, none after repeat_until")
  local first = list.items[1]
  eq(first.virtual, true)
  eq(first.series, "lib.nvim/one-on-one")
  eq(first.occurrence, "2026-09-28")
  eq(first.starts_at, "2026-09-28T10:00")
  eq(first.ends_at, "2026-09-28T10:30")
  eq(first.tasks, { "lib.nvim/prep" }, "the tasks of the series")
  eq(first["repeat"], nil, "an occurrence is no series")
  eq(first.file, "lib.nvim/MEETINGS/one-on-one-2026-09-28.md", "the file it gets")
  eq(list.items[2].starts_at, "2026-10-05T10:00")
  eq(list.total, 4)
  eq(#call("meetings", { since = "2026-10-05", ["until"] = "2026-10-05" }).items, 1)
  eq(
    ids(
      call("meetings", { since = "2026-09-01", ["until"] = "2026-12-31", task = "lib.nvim/prep" })
    ),
    ids(list),
    "the task filter sees the occurrences"
  )

  -- `meeting` of an occurrence without a file, and of the series itself
  local one_doc = call("meeting", { id = "lib.nvim/one-on-one-2026-10-05" })
  eq(one_doc.kind, "tasks.meeting", vim.inspect(one_doc))
  eq(one_doc.meeting.virtual, true)
  eq(one_doc.meeting.date, "2026-10-05")
  eq(#one_doc.agenda, 1, "the agenda of the series is the template")
  local _, nf = call("meeting", { id = "lib.nvim/one-on-one-2026-10-12" })
  eq(nf, "not_found", "an excepted day has no occurrence")
  _, nf = call("meeting", { id = "lib.nvim/one-on-one-2026-10-06" })
  eq(nf, "not_found", "no day of the series")
  local series_doc = call("meeting", { id = "lib.nvim/one-on-one" })
  eq(series_doc.meeting["repeat"], "1w")
  eq(series_doc.meeting.repeat_until, "2026-10-26")
  eq(series_doc.meeting.except, { "2026-10-12" })
  eq(series_doc.meeting.virtual, nil)

  -- ── the first entry gives the occurrence its file ──
  local function run(op, dry)
    meetings.reset_cache()
    local doc, err = ops_mod.run(
      { ops = { op }, dry_run = dry or nil },
      { root = root, today = F.TODAY, attach = { upload_dir = root .. "/../uploads" } }
    )
    assert(doc, tostring(err))
    return doc.results[1]
  end
  local occ_file = dir .. "/one-on-one-2026-10-05.md"
  local capture = {
    op = "meeting_capture",
    id = "lib.nvim/one-on-one-2026-10-05",
    entry = { kind = "decision", text = "Ship it", at = "10:12" },
  }
  local d = run(capture, true)
  eq(d.outcome, "would_change", vim.inspect(d))
  eq(d.created, true)
  ok(not vim.uv.fs_stat(occ_file), "a dry run makes no file")

  local stale = vim.deepcopy(capture)
  stale.if_match = "0000000000000000"
  eq(run(stale).error.code, "conflict", "the version is the one of the series")
  ok(not vim.uv.fs_stat(occ_file))

  local c = run(vim.tbl_extend("force", capture, { if_match = first.etag }))
  eq(c.outcome, "changed", vim.inspect(c))
  eq(c.created, true)
  ok(vim.uv.fs_stat(occ_file), "the file is made")
  meetings.reset_cache()
  local made = assert(meetings.find("lib.nvim/one-on-one-2026-10-05", { root = root }))
  ok(made.valid, codes(made))
  eq(made.series, "lib.nvim/one-on-one")
  eq(made.date, "2026-10-05")
  eq(made.repeat_every, nil, "no repeat in the occurrence")
  eq(made.created, F.TODAY)
  eq(#made.agenda, 1, "the template came along")
  ok(made.has_decisions)
  eq(H.read(dir .. "/one-on-one.md"), series_text, "the series stays as it was")

  -- a second capture writes into the file
  local c2 = run(capture)
  eq(c2.outcome, "changed")
  eq(c2.created, nil, "the file was there")

  -- a cancellation is an entry too
  local cancel = run({
    op = "meeting_set",
    id = "lib.nvim/one-on-one-2026-10-19",
    patch = { status = "cancelled" },
  })
  eq(cancel.outcome, "changed", vim.inspect(cancel))
  eq(cancel.created, true)
  -- a change that changes nothing leaves the occurrence computed
  local same = run({
    op = "meeting_set",
    id = "lib.nvim/one-on-one-2026-10-26",
    patch = { status = "planned" },
  })
  eq(same.outcome, "unchanged", vim.inspect(same))
  ok(not vim.uv.fs_stat(dir .. "/one-on-one-2026-10-26.md"))
  -- a series cannot be named in an occurrence
  eq(
    run({ op = "meeting_set", id = "lib.nvim/one-on-one-2026-10-26", patch = { ["repeat"] = "1w" } }).error.code,
    "invalid_argument"
  )
  -- close with a result
  local closed =
    run({ op = "meeting_close", id = "lib.nvim/one-on-one-2026-09-28", result = "Fine." })
  eq(closed.outcome, "changed", vim.inspect(closed))
  meetings.reset_cache()
  local closed_m = assert(meetings.find("lib.nvim/one-on-one-2026-09-28", { root = root }))
  eq(closed_m.status, "done")
  ok(closed_m.has_result)

  -- an attachment: the file is made, then its folder form
  vim.fn.mkdir(root .. "/../uploads", "p")
  H.write(root .. "/../uploads/memo.ogg", "ogg")
  local attach_op = {
    op = "attach",
    id = "lib.nvim/one-on-one-2026-10-26",
    from = "upload",
    upload = "memo.ogg",
    name = "memo.ogg",
    kind = "audio",
  }
  local adry = run(attach_op, true)
  eq(adry.outcome, "would_change", vim.inspect(adry))
  ok(not vim.uv.fs_stat(dir .. "/one-on-one-2026-10-26.md"))
  local att = run(attach_op)
  eq(att.outcome, "changed", vim.inspect(att))
  ok(vim.uv.fs_stat(dir .. "/one-on-one-2026-10-26/one-on-one-2026-10-26.md"), "the folder form")

  -- a task operation on a meeting id takes an occurrence too: ticking the agenda of the template
  local tick = run({ op = "tick_step", id = "lib.nvim/one-on-one-2026-10-19", n = 1 })
  eq(tick.outcome, "changed", vim.inspect(tick))
  meetings.reset_cache()
  local ticked = assert(meetings.find("lib.nvim/one-on-one-2026-10-19", { root = root }))
  eq(ticked.agenda[1].ticked, true)

  -- a series is made with the write door
  local series_new = run({
    op = "meeting_new",
    area = "lib.nvim",
    title = "Jour fixe",
    fields = { date = "2026-11-02", time = "09:00", ["repeat"] = "2w", except = { "2026-11-16" } },
  })
  eq(series_new.outcome, "created", vim.inspect(series_new))
  meetings.reset_cache()
  local jf = assert(meetings.find(series_new.id, { root = root }))
  ok(jf.valid, codes(jf))
  eq(jf.repeat_every, "2w")
  eq(jf.except, { "2026-11-16" })
  eq(
    meetings.occurrence_days(jf, "2026-11-01", "2026-12-01", 50),
    { "2026-11-02", "2026-11-30" },
    "every second week, the 16th left out"
  )

  -- a new meeting never takes the id of an occurrence without a file
  local clash = run({
    op = "meeting_new",
    area = "lib.nvim",
    title = "Jour fixe 2026-11-02",
    fields = { date = "2026-11-30" },
  })
  eq(clash.outcome, "created", vim.inspect(clash))
  eq(clash.id, "lib.nvim/jour-fixe-2026-11-02-2026-11-30-2", "the occurrence holds its id")

  -- a meeting folder that leaves the vault (a junction): its series is no source of occurrences
  local outside = H.tmpdir() .. "/outside-meetings"
  vim.fn.mkdir(outside, "p")
  H.write(
    outside .. "/ext.md",
    "---\ntitle: Ext\nstatus: planned\ndate: 2026-10-05\nrepeat: weekly\n---\n\nX.\n"
  )
  if vim.uv.fs_symlink(outside, root .. "/cascade.nvim/MEETINGS", { junction = true }) then
    meetings.reset_cache()
    eq(meetings.find_any("cascade.nvim/ext-2026-10-12", { root = root }), nil)
    local through = run({
      op = "meeting_capture",
      id = "cascade.nvim/ext-2026-10-12",
      entry = { kind = "text", text = "x", at = "10:00" },
    })
    ok(through.error, vim.inspect(through))
    ok(not vim.uv.fs_stat(outside .. "/ext-2026-10-12.md"), "nothing is written outside the vault")
    vim.uv.fs_unlink(root .. "/cascade.nvim/MEETINGS")
  else
    print("n/a  no junction on this machine")
  end

  -- the window now has the files in place of the computed occurrences; a moved one keeps its own day
  local moved = H.read(occ_file):gsub("date: 2026%-10%-05", "date: 2026-10-07")
  H.write(occ_file, moved)
  list = call("meetings", { since = "2026-09-01", ["until"] = "2026-10-31" })
  eq(ids(list), {
    "lib.nvim/one-on-one-2026-09-28",
    "lib.nvim/one-on-one-2026-10-05",
    "lib.nvim/one-on-one-2026-10-19",
    "lib.nvim/one-on-one-2026-10-26",
  })
  for _, it in ipairs(list.items) do
    eq(it.virtual, nil, it.id .. " has its file")
    eq(it.series, "lib.nvim/one-on-one")
  end
  eq(list.items[2].date, "2026-10-07", "moved, still in place of its day")
  eq(list.items[3].status, "cancelled")
  eq(
    #call("meetings", { since = "2026-10-05", ["until"] = "2026-10-05" }).items,
    0,
    "the moved one is no longer on its old day, and no computed one stands in"
  )

  -- the cut is named in `incomplete`
  H.write(
    dir .. "/standup.md",
    "---\ntitle: Standup\nstatus: planned\ndate: 2026-01-01\nrepeat: daily\n---\n\nDaily.\n"
  )
  local big =
    call("meetings", { since = "2026-01-01", ["until"] = "2027-12-31", area = "lib.nvim" })
  ok(
    big.incomplete[1] and big.incomplete[1]:find("lib.nvim/standup: more than", 1, true),
    vim.inspect(big.incomplete)
  )

  -- ── check ──
  local check = require("tasks_nvim.check")
  -- an occurrence whose series is gone; one whose day was excepted afterwards; a series beside its first occurrence
  H.write(
    dir .. "/ghost-2026-10-05.md",
    "---\ntitle: Ghost\nstatus: planned\ndate: 2026-10-05\nseries: lib.nvim/ghost\n---\n\nX.\n"
  )
  H.write(
    dir .. "/one-on-one.md",
    (series_text:gsub("except: %[2026%-10%-12%]", "except: [2026-10-12, 2026-10-19]"))
  )
  local sync = "---\ntitle: Sync\nstatus: planned\ndate: 2026-11-02\n"
    .. 'time: "09:00"\nduration: 30m\n'
  H.write(dir .. "/sync.md", sync .. "repeat: 1w\n---\n\nX.\n")
  H.write(dir .. "/sync-2026-11-02.md", sync .. "series: lib.nvim/sync\n---\n\nX.\n")
  meetings.reset_cache()
  local res = check.run({ root = root, area = "lib.nvim", today = F.TODAY, ui_words = false })
  local function codes_of(found, id)
    local out = {}
    for _, f in ipairs(found) do
      if f.id == id then
        out[#out + 1] = f.code
      end
    end
    table.sort(out)
    return out
  end
  eq(codes_of(res.findings, "lib.nvim/ghost-2026-10-05"), { "meeting-series-missing" })
  eq(codes_of(res.hints, "lib.nvim/one-on-one-2026-10-19"), { "meeting-series-off-day" })
  eq(codes_of(res.hints, "lib.nvim/one-on-one-2026-10-26"), {}, "still a day of the series")
  eq(codes_of(res.findings, "lib.nvim/one-on-one-2026-10-26"), {})
  eq(codes_of(res.hints, "lib.nvim/sync-2026-11-02"), {}, "the series is no meeting beside it")
  eq(codes_of(res.findings, "lib.nvim/one-on-one"), {}, "a good series says nothing")
end
