-- TESTS/tasks_contract_meeting_parse_spec.lua -- the quick capture in the contract (capability `meeting_parse`): the
-- same proposal as the parser, today from the request, nothing written, and the refusals (the documents themselves are
-- goldens `meeting-parse`, `meeting-parse-assumed`).
-- @scans-data: the folders it lists are the fixture vault in the temp folder

---@diagnostic disable: need-check-nil, param-type-mismatch
-- Why: a value is bound with assert()/ok() in the same body, so a nil fails the spec at that line.

return function(H)
  local eq, ok = H.eq, H.ok
  local F = dofile(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)) .. "/fixture.lua")
  local api = require("tasks_nvim.api")
  local quick = require("tasks_nvim.meeting_quick")

  local root = F.vault(H)
  local function call(params, today)
    local text = api.call(
      "meeting_parse",
      { params = params },
      { root = root, today = today or "2026-11-19" }
    )
    local doc = vim.json.decode(text)
    return doc, doc.kind == "tasks.error" and doc.code or nil
  end

  local hello = vim.json.decode((api.call("hello", { params = {} }, { root = root })))
  ok(vim.tbl_contains(hello.capabilities, "meeting_parse"))

  -- the same proposal as the parser of the CLI and the editor, for the day of the request
  local line = "morgen 9:30 90m Workshop @Raum_3.14 #lib.nvim/alpha !-1d@18:00"
  local doc = call({ text = line })
  eq(doc.kind, "tasks.meetingparse")
  local want = quick.parse(line, { today = "2026-11-19" })
  eq(doc.title, want.title)
  eq(doc.fields.date, "2026-11-20")
  eq(doc.fields.time, "09:30")
  eq(doc.fields.duration, "90m")
  eq(doc.fields.location, "Raum 3.14")
  eq(doc.fields.tasks, { "lib.nvim/alpha" })
  eq(doc.fields.notify, { "-1d@18:00" })
  eq(doc.all_day, false)
  eq(doc.assumed, {})
  eq(doc.problems, {})
  eq(doc.online_service, nil, "no address, no service")
  -- the service of an address, in the words of a meeting entry
  eq(call({ text = "Sync https://meet.google.com/abc" }).online_service, "meet")
  eq(call({ text = "Sync https://example.org/room" }).online_service, "link")

  -- a day without a time: all day; the day comes from `today` of the request
  local allday = call({ text = "ganztägig Schulung" }, "2026-03-04")
  eq(allday.all_day, true)
  eq(allday.fields.date, "2026-03-04")
  eq(allday.assumed, { "date" })
  eq(allday.fields.time, nil)

  -- nothing is written: no MEETINGS folder appears
  eq(vim.fn.isdirectory(root .. "/lib.nvim/MEETINGS"), 0)

  -- the refusals: no text, an empty one, too long, more than one line, a control character
  local _, missing = call({})
  eq(missing, "invalid_argument")
  local _, blank = call({ text = "   " })
  eq(blank, "invalid_argument")
  local _, long = call({ text = ("x"):rep(1001) })
  eq(long, "invalid_argument")
  local fits = call({ text = ("x"):rep(1000) })
  eq(fits.kind, "tasks.meetingparse")
  local _, lines = call({ text = "Mo Sync\nDi Sync" })
  eq(lines, "invalid_argument")
  local _, ctrl = call({ text = "Sync \27[31m" })
  eq(ctrl, "invalid_argument")
  local _, typed = call({ text = 42 })
  eq(typed, "invalid_argument")
end
