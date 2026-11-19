-- TESTS/tasks_meeting_quick_spec.lua -- the quick capture of a meeting: the three lines of the concept, the day words
-- (weekday from today on, a day without a year, relative words), times (range, past midnight, "14 Uhr"), a place
-- beside an address, tasks and notifications, the words that look like a field but are none, and the day assumed.

---@diagnostic disable: need-check-nil, param-type-mismatch
-- Why: a value is bound with assert()/ok() in the same body, so a nil fails the spec at that line.

return function(H)
  local eq = H.eq
  local quick = require("tasks_nvim.meeting_quick")
  -- 2026-10-03 is a Saturday
  local today = "2026-10-03"
  local function p(line)
    return quick.parse(line, { today = today })
  end

  -- the first line of the concept
  local a = p(
    "Mo 14:00-15:00 Sync mit Rick @teams https://teams.microsoft.com/l/x #Meetings/tosca-vorbereiten !-15m"
  )
  eq(a.title, "Sync mit Rick")
  eq(a.fields.date, "2026-10-05")
  eq(a.fields.time, "14:00")
  eq(a.fields["end"], "15:00")
  eq(a.fields.online, "https://teams.microsoft.com/l/x")
  eq(a.fields.location, nil, "@teams beside an address is the service, not a place")
  eq(a.fields.tasks, { "Meetings/tosca-vorbereiten" })
  eq(a.fields.notify, { "-15m" })
  eq(a.all_day, false)
  eq(a.assumed, {})

  -- the second: a day without a year, a short time, a duration, a place with a blank
  local b = p("24.11. 9:30 90m Workshop @Raum_3.14")
  eq(b.title, "Workshop")
  eq(b.fields.date, "2026-11-24")
  eq(b.fields.time, "09:30")
  eq(b.fields.duration, "90m")
  eq(b.fields.location, "Raum 3.14")

  -- the third: a relative day, all day
  local c = p("morgen ganztägig Schulung")
  eq(c.title, "Schulung")
  eq(c.fields.date, "2026-10-04")
  eq(c.fields.time, nil)
  eq(c.all_day, true)

  -- weekdays: today counts, the English words, a dot
  eq(p("Sa Retro").fields.date, "2026-10-03")
  eq(p("Fri. Retro").fields.date, "2026-10-09")
  eq(p("Sonntag Retro").fields.date, "2026-10-04")
  -- a day without a year that has passed is next year's; a full date stays; an impossible one is a word
  eq(p("2.1. Planung").fields.date, "2027-01-02")
  eq(p("2.1.2026 Planung").fields.date, "2026-01-02")
  eq(p("2026-12-24 Feier").fields.date, "2026-12-24")
  local bad = p("31.02. Nie")
  eq(bad.title, "31.02. Nie")
  eq(bad.assumed, { "date" })
  eq(bad.fields.date, today)
  eq(p("übermorgen x").fields.date, "2026-10-05")
  eq(p("heute x").fields.date, today)

  -- times: "14 Uhr", past midnight (a duration), out of range (a word)
  local u = p("Di 14 Uhr Call")
  eq(u.fields.time, "14:00")
  eq(u.title, "Call")
  local night = p("Fr 23:00-01:00 Deploy")
  eq(night.fields.time, "23:00")
  eq(night.fields["end"], nil)
  eq(night.fields.duration, "120m")
  eq(p("Mo 25:00 x").title, "25:00 x")
  -- an all-day word wins over a time
  eq(p("Mo 10:00 ganztags Messe").fields.time, nil)

  -- words that look like a field but are none
  local w = p("Mo #nothing !soon Treffen")
  eq(w.problems, { "#nothing", "!soon" })
  eq(w.title, "Treffen")
  -- a second date, time or duration is part of the title
  eq(p("Mo 10:00 Di 11:00 x").title, "Di 11:00 x")
  -- a place without an address stays a place even when it is a service word
  eq(p("Mo @teams Sync").fields.location, "teams")
  -- several notifications, at most five
  eq(#p("Mo x !-1m !-2m !-3m !-4m !-5m !-6m").fields.notify, 5)
  -- nothing at all
  local empty = p("")
  eq(empty.title, "")
  eq(empty.fields.date, today)
end
