-- TESTS/tasks_meeting_ops_spec.lua -- the write door and meetings: `meeting_new` (dry run, slug, refusals),
-- `meeting_set` (inverse, `done` refused, a stale version), `meeting_close` (with and without a result),
-- `meeting_capture` (each kind, the section it lands in, the asset it needs), `meeting_attend`, `meeting_followups`
-- (tasks with refs, the arrow, a second run), the task ops on a meeting id (`tick_step`, `add_steps`, `append_note`,
-- `set_section`, `set_body`), `attach` of an audio and `board_save` (made, a conflict, replaced on the version read).
-- @scans-data: the folders it lists are the fixture vault in the temp folder

---@diagnostic disable: need-check-nil, param-type-mismatch
-- Why: a value is bound with assert()/ok() in the same body, so a nil fails the spec at that line.

return function(H)
  local eq, ok, has = H.eq, H.ok, H.has
  local F = dofile(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)) .. "/fixture.lua")
  local meetings = require("tasks_nvim.meetings")
  local ops_mod = require("tasks_nvim.ops")
  local scan = require("tasks_nvim.scan")

  local root = F.vault(H)
  local uploads = H.tmpdir() .. "/uploads"
  vim.fn.mkdir(uploads, "p")
  meetings.reset_cache()
  F.task(H, root, "lib.nvim", "prep", F.meta("Prep", "open", { { "tags", "[sync]" } }))
  require("tasks_nvim.index").write_area("lib.nvim", { root = root })

  local function run(list, dry)
    local doc, err = ops_mod.run(
      { ops = list, dry_run = dry or nil },
      { root = root, today = F.TODAY, attach = { upload_dir = uploads } }
    )
    assert(doc, tostring(err))
    eq(doc.kind, "tasks.result", vim.inspect(doc))
    return doc
  end
  local function one(op, dry)
    local doc = run({ op }, dry)
    eq(#doc.results, 1)
    return doc.results[1]
  end
  local function file(id)
    meetings.reset_cache()
    return assert(meetings.find(id, { root = root }))
  end
  local function code(entry)
    return entry.error and entry.error.code
  end

  -- ── meeting_new ──
  local dry = one({
    op = "meeting_new",
    area = "lib.nvim",
    title = "Sync mit Rick",
    fields = {
      date = "2026-10-20",
      time = "14:00",
      ["end"] = "15:00",
      online = "https://teams.microsoft.com/l/meetup-join/x",
      tasks = { "lib.nvim/prep" },
      notify = { "-15m" },
      tags = { "sync" },
    },
  }, true)
  eq(dry.outcome, "would_create", vim.inspect(dry))
  eq(dry.id, "lib.nvim/sync-mit-rick-2026-10-20")
  ok(not vim.uv.fs_stat(root .. "/lib.nvim/MEETINGS"), "a dry run makes no folder")
  local made = one({
    op = "meeting_new",
    area = "lib.nvim",
    title = "Sync mit Rick",
    fields = {
      date = "2026-10-20",
      time = "14:00",
      ["end"] = "15:00",
      online = "https://teams.microsoft.com/l/meetup-join/x",
      tasks = { "lib.nvim/prep" },
      notify = { "-15m" },
      tags = { "sync" },
    },
  })
  eq(made.outcome, "created", vim.inspect(made))
  local id = made.id
  local m = file(id)
  eq(m.valid, true, vim.inspect(m.errors))
  eq(m.status, "planned")
  eq(m.time, "14:00")
  eq(m.duration_min, 60)
  eq(m.online_service, "teams")
  eq(m.tasks, { "lib.nvim/prep" })
  has(m.body, "## Teilnehmer")
  eq(made.etag_after, m.etag)
  -- the same title and day again: the next free slug
  local again = one({
    op = "meeting_new",
    area = "lib.nvim",
    title = "Sync mit Rick",
    fields = { date = "2026-10-20" },
  })
  eq(again.id, id .. "-2")
  eq(again.renamed, true)
  -- a slug of a task is taken (one namespace), a given slug is not renamed
  eq(
    code(one({
      op = "meeting_new",
      area = "lib.nvim",
      title = "x",
      slug = "prep",
      fields = { date = "2026-10-20" },
    })),
    "exists"
  )
  -- refusals: no date, an end before the beginning, a task that exists nowhere, done, an unknown field
  eq(code(one({ op = "meeting_new", area = "lib.nvim", title = "No date" })), "invalid_argument")
  local bad_end = one({
    op = "meeting_new",
    area = "lib.nvim",
    title = "Bad end",
    fields = { date = "2026-10-20", time = "14:00", ["end"] = "13:00" },
  })
  eq(code(bad_end), "invalid_argument")
  has(bad_end.error.message, "not after the beginning")
  eq(
    code(one({
      op = "meeting_new",
      area = "lib.nvim",
      title = "Ghost",
      fields = { date = "2026-10-20", tasks = { "lib.nvim/nowhere" } },
    })),
    "invalid_argument"
  )
  eq(
    code(one({
      op = "meeting_new",
      area = "lib.nvim",
      title = "D",
      fields = { date = "2026-10-20", status = "done" },
    })),
    "invalid_argument"
  )
  eq(
    code(one({
      op = "meeting_new",
      area = "lib.nvim",
      title = "U",
      fields = { date = "2026-10-20", prio = "1" },
    })),
    "invalid_argument"
  )

  -- ── meeting_set: a change, its inverse, done refused, a stale version ──
  local set = one({
    op = "meeting_set",
    id = id,
    patch = { location = "Raum 3.14", time = "15:00", ["end"] = "16:00" },
    if_match = m.etag,
  })
  eq(set.outcome, "changed", vim.inspect(set))
  eq(file(id).location, "Raum 3.14")
  eq(set.inverse.op, "meeting_set")
  eq(set.inverse.patch.time, "14:00")
  ok(
    set.inverse.patch.location == vim.NIL or set.inverse.patch.location == nil,
    vim.inspect(set.inverse)
  )
  local back = one(set.inverse)
  eq(back.outcome, "changed", vim.inspect(back))
  eq(file(id).location, nil)
  eq(file(id).time, "14:00")
  eq(code(one({ op = "meeting_set", id = id, patch = { status = "done" } })), "invalid_argument")
  eq(code(one({ op = "meeting_set", id = id, patch = { title = "" } })), "invalid_argument")
  eq(code(one({ op = "meeting_set", id = id, patch = { time = "25:00" } })), "invalid_argument")
  eq(
    code(
      one({ op = "meeting_set", id = id, patch = { location = "x" }, if_match = set.etag_after })
    ),
    "conflict"
  )
  eq(
    code(one({ op = "meeting_set", id = "lib.nvim/nope", patch = { location = "x" } })),
    "not_found"
  )
  -- cancelled and planned again
  eq(one({ op = "meeting_set", id = id, patch = { status = "cancelled" } }).outcome, "changed")
  eq(one({ op = "meeting_set", id = id, patch = { status = "planned" } }).outcome, "changed")

  -- ── participants and the agenda, through the task ops ──
  eq(
    one({
      op = "set_section",
      id = id,
      heading = "## Teilnehmer",
      text = "- [ ] Rick <rick@example.org> (Organisator)\n- [ ] Stefan",
    }).outcome,
    "changed"
  )
  local att = one({ op = "meeting_attend", id = id, name = "rick" })
  eq(att.outcome, "changed", vim.inspect(att))
  eq(file(id).participants[1].present, true)
  eq(att.inverse.present, false)
  eq(one(att.inverse).outcome, "changed")
  eq(file(id).participants[1].present, false)
  eq(one({ op = "meeting_attend", id = id, n = 2, present = true }).outcome, "changed")
  eq(file(id).participants[2].present, true)
  eq(code(one({ op = "meeting_attend", id = id, name = "Nobody" })), "invalid_argument")
  eq(code(one({ op = "meeting_attend", id = id })), "invalid_argument")

  eq(one({ op = "add_steps", id = id, steps = { "Stand Team 1", "Lizenz" } }).outcome, "changed")
  eq(#file(id).agenda, 2)
  local tick = one({ op = "tick_step", id = id, n = 2 })
  eq(tick.outcome, "changed", vim.inspect(tick))
  eq(file(id).agenda[2].ticked, true)
  eq(tick.inverse.done, false)
  eq(code(one({ op = "tick_step", id = id, n = 9 })), "invalid_argument")
  eq(code(one({ op = "tick_step", id = id, n = 1, section = "minutes" })), "invalid_argument")
  eq(
    code(one({ op = "tick_step", id = "lib.nvim/prep", n = 1, section = "agenda" })),
    "invalid_argument"
  )
  eq(
    one({ op = "add_steps", id = id, steps = { "Testumgebung" }, section = "followups" }).outcome,
    "changed"
  )
  eq(file(id).followups[1].text, "Testumgebung")

  -- ── meeting_capture: each kind and where it lands ──
  local function capture(entry)
    return one({ op = "meeting_capture", id = id, entry = entry })
  end
  local c1 = capture({ kind = "text", text = "Installation läuft", at = "14:05" })
  eq(c1.outcome, "changed", vim.inspect(c1))
  eq(c1.inverse.op, "set_body")
  eq(capture({ kind = "task", text = "Lizenz klären", at = "14:06" }).outcome, "changed")
  eq(capture({ kind = "decision", text = "Start am 1.12.", at = "14:07" }).outcome, "changed")
  eq(capture({ kind = "question", text = "Wer zahlt?", at = "14:08" }).outcome, "changed")
  local body = file(id).body
  has(body, "- 14:05 Installation läuft")
  has(body, "- 14:06 Aufgabe: Lizenz klären")
  has(body, "- [ ] Lizenz klären")
  has(body, "- Start am 1.12.")
  has(body, "### Wer zahlt?")
  ok(body:find("## Protokoll\n\n- 14:05", 1, true), body)
  eq(file(id).has_decisions, true)
  eq(#file(id).followups, 2)
  -- the inverse of a capture puts the body back
  local before_inverse = file(id).body
  local c5 = capture({ kind = "text", text = "Zu viel", at = "14:09" })
  eq(one(c5.inverse).outcome, "changed")
  eq(file(id).body, before_inverse)
  -- refusals: no text, a line break, an asset for text, a photo without one, a photo of an asset that is not there
  eq(code(capture({ kind = "text" })), "invalid_argument")
  eq(code(capture({ kind = "text", text = "a\nb" })), "invalid_argument")
  eq(code(capture({ kind = "text", text = "x", asset = "assets/a.png" })), "invalid_argument")
  eq(code(capture({ kind = "photo" })), "invalid_argument")
  eq(code(capture({ kind = "photo", asset = "assets/images/none.png" })), "invalid_argument")
  eq(code(capture({ kind = "photo", asset = "assets/../x.png" })), "invalid_argument")
  eq(code(capture({ kind = "chat", text = "x" })), "invalid_argument")
  eq(code(capture({ kind = "text", text = "x", at = "9:5" })), "invalid_argument")
  eq(code(capture({ kind = "text", text = "x", extra = "y" })), "invalid_argument")

  -- append_note writes a line of the minutes
  eq(one({ op = "append_note", id = id, text = "Notiz" }).outcome, "changed")
  ok(file(id).body:find("%- %d%d:%d%d Notiz"), file(id).body)

  -- ── attach an audio (the meeting becomes its folder form), then capture it ──
  H.write(uploads .. "/memo.ogg", "ogg")
  local a = one({
    op = "attach",
    id = id,
    from = "upload",
    upload = "memo.ogg",
    name = "memo.ogg",
    kind = "audio",
  })
  eq(a.outcome, "changed", vim.inspect(a))
  eq(a.asset, "assets/audio/memo.ogg")
  ok(vim.uv.fs_stat(root .. "/lib.nvim/MEETINGS/" .. id:match("/(.*)") .. "/assets/audio/memo.ogg"))
  eq(file(id).folder, true)
  eq(capture({ kind = "audio", asset = "assets/audio/memo.ogg", at = "14:10" }).outcome, "changed")
  has(file(id).body, "- 14:10 [Audio: memo.ogg](assets/audio/memo.ogg)")

  -- ── board_save: made, a second writer without the version, replaced on the version read ──
  H.write(uploads .. "/board.json", '{"strokes":[]}')
  H.write(uploads .. "/board.svg", "<svg/>")
  local b1 = one({
    op = "board_save",
    id = id,
    name = "skizze",
    format = "ink",
    upload = "board.json",
    preview = "board.svg",
  })
  eq(b1.outcome, "created", vim.inspect(b1))
  eq(b1.asset, "assets/boards/skizze.ink.json")
  eq(b1.preview, "assets/boards/skizze.svg")
  local b2 =
    one({ op = "board_save", id = id, name = "skizze", format = "ink", upload = "board.json" })
  eq(code(b2), "conflict", vim.inspect(b2))
  eq(b2.error.details.suggestion, "skizze-2")
  eq(b2.error.details.actual, b1.etag)
  H.write(uploads .. "/board.json", '{"strokes":[1]}')
  local b3 = one({
    op = "board_save",
    id = id,
    name = "skizze",
    format = "ink",
    upload = "board.json",
    if_match = b1.etag,
  })
  eq(b3.outcome, "changed", vim.inspect(b3))
  ok(b3.etag ~= b1.etag)
  eq(
    code(one({
      op = "board_save",
      id = id,
      name = "skizze",
      format = "ink",
      upload = "board.json",
      if_match = b1.etag,
    })),
    "conflict"
  )
  eq(
    code(one({
      op = "board_save",
      id = id,
      name = "neu",
      format = "ink",
      upload = "board.json",
      if_match = b1.etag,
    })),
    "not_found"
  )
  eq(
    code(one({ op = "board_save", id = id, name = "x", format = "paint", upload = "board.json" })),
    "invalid_argument"
  )
  eq(
    code(one({ op = "board_save", id = id, name = "x", format = "external", upload = "board.svg" })),
    "invalid_argument",
    "an external board is the file of an app, not a page (svg, html, md)"
  )
  H.write(uploads .. "/notes.xopp", "xopp")
  eq(
    one({ op = "board_save", id = id, name = "xournal", format = "external", upload = "notes.xopp" }).asset,
    "assets/boards/xournal.xopp"
  )
  eq(
    code(one({ op = "board_save", id = id, name = "x", format = "ink", upload = "../board.json" })),
    "invalid_argument"
  )
  -- a board of a task: the task becomes a folder task
  eq(
    one({
      op = "board_save",
      id = "lib.nvim/prep",
      name = "plan",
      format = "ink",
      upload = "board.json",
    }).outcome,
    "created"
  )
  eq(scan.find("lib.nvim/prep", { root = root }).folder, true)
  -- a capture of the board
  eq(
    capture({ kind = "board", asset = "assets/boards/skizze.svg", text = "Skizze", at = "14:11" }).outcome,
    "changed"
  )
  has(file(id).body, "- 14:11 ![Skizze](assets/boards/skizze.svg)")

  -- ── meeting_followups: tasks with refs, the arrow, a second run changes nothing ──
  local fu = one({ op = "meeting_followups", id = id, fields = { prio = 2 } }, true)
  eq(fu.outcome, "would_change", vim.inspect(fu))
  eq(#fu.items, 2)
  ok(not scan.find("lib.nvim/testumgebung", { root = root }), "a dry run makes no task")
  fu = one({ op = "meeting_followups", id = id, fields = { prio = 2 } })
  eq(fu.outcome, "changed", vim.inspect(fu))
  eq(fu.items[1].id, "lib.nvim/testumgebung")
  eq(fu.items[2].id, "lib.nvim/lizenz-klaeren")
  local t = assert(scan.find("lib.nvim/lizenz-klaeren", { root = root }))
  eq(t.refs, { id })
  eq(t.prio, 2)
  eq(t.tags, { "sync" })
  eq(file(id).followups[2].task, "lib.nvim/lizenz-klaeren")
  local fu2 = one({ op = "meeting_followups", id = id })
  eq(fu2.outcome, "unchanged", vim.inspect(fu2))
  eq(#fu2.items, 0)
  eq(code(one({ op = "meeting_followups", id = id, n = 9 })), "invalid_argument")
  eq(code(one({ op = "meeting_followups", id = id, fields = { title = "x" } })), "invalid_argument")

  -- ── meeting_close: with a result, then without on another meeting ──
  local close = one({ op = "meeting_close", id = id, result = "Start am 1.12. vereinbart." })
  eq(close.outcome, "changed", vim.inspect(close))
  eq(close.without_result, false)
  eq(file(id).status, "done")
  eq(file(id).has_result, true)
  eq(one({ op = "meeting_close", id = id }).outcome, "unchanged")
  local other = one({ op = "meeting_close", id = again.id })
  eq(other.without_result, true)
  eq(other.inverse.patch.status, "planned")
  eq(one(other.inverse).outcome, "changed")
  eq(file(again.id).status, "planned")
  -- done back to planned through meeting_set
  eq(one({ op = "meeting_set", id = id, patch = { status = "planned" } }).outcome, "changed")

  -- ── what a front end may not write ──
  -- a control character in the body of a new meeting
  eq(
    code(one({
      op = "meeting_new",
      area = "lib.nvim",
      title = "Ctl",
      fields = { date = "2026-10-21" },
      body = "Agenda" .. string.char(1),
    })),
    "invalid_argument"
  )
  -- a board folder that leaves the vault (a junction, as a shared vault could bring): never written through
  local outside = H.tmpdir() .. "/outside"
  vim.fn.mkdir(outside, "p")
  H.write(outside .. "/skizze.ink.json", "theirs")
  local linked = one({
    op = "meeting_new",
    area = "lib.nvim",
    title = "Linked",
    fields = { date = "2026-10-22" },
  }).id
  eq(
    one({
      op = "attach",
      id = linked,
      from = "upload",
      upload = "memo.ogg",
      name = "m.ogg",
      kind = "audio",
    }).ok,
    true
  )
  local linked_dir = vim.fs.dirname(file(linked).path)
  local junction_ok =
    vim.uv.fs_symlink(outside, linked_dir .. "/assets/boards", { junction = true })
  if junction_ok then
    local theirs = require("tasks_nvim.fsio").etag("theirs")
    local through = one({
      op = "board_save",
      id = linked,
      name = "skizze",
      format = "ink",
      upload = "board.json",
      if_match = theirs,
    })
    eq(code(through), "forbidden", vim.inspect(through))
    eq(H.read(outside .. "/skizze.ink.json"), "theirs", "the file outside the vault is untouched")
    vim.uv.fs_unlink(linked_dir .. "/assets/boards")
  else
    print("n/a  no junction on this machine")
  end
  -- a board file that is a link (where the system lets one be made)
  local boards = linked_dir .. "/assets/boards"
  vim.fn.mkdir(boards, "p")
  if vim.uv.fs_symlink(outside .. "/skizze.ink.json", boards .. "/skizze.ink.json") then
    local through = one({
      op = "board_save",
      id = linked,
      name = "skizze",
      format = "ink",
      upload = "board.json",
      if_match = require("tasks_nvim.fsio").etag("theirs"),
    })
    eq(code(through), "forbidden", vim.inspect(through))
    eq(H.read(outside .. "/skizze.ink.json"), "theirs")
  else
    print("n/a  no file symlink on this machine (needs the right to make one)")
  end

  -- ── the whole file is still a valid meeting ──
  local final = file(id)
  eq(final.valid, true, vim.inspect(final.errors))
  local check = require("tasks_nvim.check")
  local res = check.run({ root = root, area = "lib.nvim", today = F.TODAY, ui_words = false })
  for _, f in ipairs(res.findings or {}) do
    ok(f.id ~= id or f.level ~= "error", vim.inspect(f))
  end
end
