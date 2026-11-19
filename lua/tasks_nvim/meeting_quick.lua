---@module 'tasks_nvim.meeting_quick'
---@brief Quick capture of a meeting: one line of text read into a proposal of its fields, never written.
---@description
--- One parser for every front end (the app, the CLI, the editor), so a line reads the same everywhere:
---
---   Mo 14:00-15:00 Sync mit Rick @teams https://teams.microsoft.com/... #Meetings/tosca-vorbereiten !-15m
---   24.11. 9:30 90m Workshop @Raum_3.14
---   morgen ganztägig Schulung
---
--- A day (`Mo`..`So`, `Mon`..`Sun`, `heute`/`today`, `morgen`/`tomorrow`, `übermorgen`, `24.11.`, `24.11.2026`,
--- `2026-11-24`), a time (`9:30`, `14:00-15:00`, `14 Uhr`), a duration (`90m`, `2h`, `1h30m`), `ganztägig` /
--- `all-day`, an http(s) address (`online`), `@<place>` (the location; `_` stands for a blank; a service word such
--- as `@teams` beside an address is the service and no place), `#<area>/<slug>` (a task), `!<offset>` (a notification,
--- `!-15m`, `!-1d@18:00`). Every other word is the title. A weekday is the next such day from today on (today
--- itself counts); a day without a year is this year's, or next year's when it has passed. No day: today, and
--- `assumed` says so. Pure: text in, a table out.
---
--- Not its job: making the meeting (`meeting_write.new`), judging the fields against the vault (a task that does not
--- exist): that is the write door's, when the proposal is sent.

local meetings = require("tasks_nvim.meetings")
local model = require("tasks_nvim.model")

local M = {}

---Weekday words (lower case, without a dot) -> `os.date` weekday (1 = Sunday).
local WEEKDAYS = {
  so = 1,
  sun = 1,
  sonntag = 1,
  sunday = 1,
  mo = 2,
  mon = 2,
  montag = 2,
  monday = 2,
  di = 3,
  tue = 3,
  dienstag = 3,
  tuesday = 3,
  mi = 4,
  wed = 4,
  mittwoch = 4,
  wednesday = 4,
  ["do"] = 5,
  thu = 5,
  donnerstag = 5,
  thursday = 5,
  fr = 6,
  fri = 6,
  freitag = 6,
  friday = 6,
  sa = 7,
  sat = 7,
  samstag = 7,
  saturday = 7,
}

---Relative day words -> days from today.
local RELATIVE = {
  heute = 0,
  today = 0,
  morgen = 1,
  tomorrow = 1,
  ["übermorgen"] = 2,
  uebermorgen = 2,
}

---Words for a meeting of the whole day.
local ALL_DAY =
  { ["ganztägig"] = true, ganztaegig = true, ganztags = true, ["all-day"] = true, allday = true }

---The services a `@word` may name beside an address.
local SERVICE_WORDS =
  { teams = true, zoom = true, meet = true, webex = true, jitsi = true, online = true }

---The weekday (1 = Sunday) of a date `YYYY-MM-DD`.
---@param date string
---@return integer
local function wday(date)
  local y, m, d = date:match("^(%d+)-(%d+)-(%d+)$")
  local t = os.time({ year = tonumber(y), month = tonumber(m), day = tonumber(d), hour = 12 })
  return tonumber(os.date("%w", t)) + 1
end

---`HH:MM` of an hour and minute, or nil when out of range.
---@param h string|integer
---@param m string|integer|nil
---@return string|nil
local function clock(h, m)
  h, m = tonumber(h), tonumber(m or 0)
  if not h or not m or h > 23 or m > 59 then
    return nil
  end
  return ("%02d:%02d"):format(h, m)
end

---A day of a token, or nil: the date and whether it was one.
---@param tok string    # lower case
---@param today string
---@return string|nil
local function day_of(tok, today)
  local word = tok:gsub("%.$", "")
  if RELATIVE[word] then
    return model.add_days(today, RELATIVE[word])
  end
  if WEEKDAYS[word] then
    local ahead = (WEEKDAYS[word] - wday(today)) % 7
    return model.add_days(today, ahead)
  end
  local iso = tok:match("^(%d%d%d%d%-%d%d%-%d%d)$")
  if iso and model.is_date(iso) then
    return iso
  end
  local d, m, y = tok:match("^(%d%d?)%.(%d%d?)%.(%d%d%d%d)$")
  if not d then
    d, m = tok:match("^(%d%d?)%.(%d%d?)%.$")
  end
  if d then
    local year = tonumber(y or today:sub(1, 4))
    local date = ("%04d-%02d-%02d"):format(year, tonumber(m), tonumber(d))
    if not model.is_date(date) then
      return nil
    end
    if not y and date < today then
      date = ("%04d-%02d-%02d"):format(year + 1, tonumber(m), tonumber(d))
      if not model.is_date(date) then
        return nil
      end
    end
    return date
  end
  return nil
end

---@class Tasks.MeetingQuick
---@field title string
---@field fields table<string, any>   # `date`, `time`, `end`, `duration`, `location`, `online`, `tasks`, `notify` as `meeting_new` takes them.
---@field all_day boolean
---@field assumed string[]            # What the line did not say and was assumed (`date`).
---@field problems string[]           # Words that looked like a field but are none (`!soon`, `#nothing`).

---Read one line into a proposal of a meeting.
---@param line string
---@param opts? { today?: string }
---@return Tasks.MeetingQuick
function M.parse(line, opts)
  opts = opts or {}
  local today = opts.today or model.today()
  local fields, title, problems, assumed = {}, {}, {}, {}
  local all_day = false
  local places, tasks, notify = {}, {}, {}
  local words = {}
  for w in tostring(line or ""):gsub("[\r\n]", " "):gmatch("%S+") do
    words[#words + 1] = w
  end
  local i = 1
  while i <= #words do
    local w = words[i]
    local low = w:lower()
    local nxt = words[i + 1] and words[i + 1]:lower() or nil
    local used = true
    if model.is_web_link(w) then
      fields.online = fields.online or w
    elseif w:sub(1, 1) == "@" and #w > 1 then
      places[#places + 1] = w:sub(2):gsub("_", " ")
    elseif w:sub(1, 1) == "#" and #w > 1 then
      local id = w:sub(2)
      if id:match("^[^/%s]+/[^/%s]+$") then
        tasks[#tasks + 1] = id
      else
        problems[#problems + 1] = w
      end
    elseif w:sub(1, 1) == "!" and #w > 1 then
      local n = meetings.parse_notify(w:sub(2))
      if n then
        notify[#notify + 1] = n.spec
      else
        problems[#problems + 1] = w
      end
    elseif ALL_DAY[low] then
      all_day = true
    elseif not fields.date and day_of(low, today) then
      fields.date = day_of(low, today)
    elseif not fields.time and low:match("^%d%d?:%d%d%-%d%d?:%d%d$") then
      local h1, m1, h2, m2 = low:match("^(%d+):(%d+)%-(%d+):(%d+)$")
      local from, to = clock(h1, m1), clock(h2, m2)
      if from and to then
        fields.time = from
        if to > from then
          fields["end"] = to
        else
          -- past midnight: a duration, the only form that crosses it
          local minutes = (tonumber(h2) * 60 + tonumber(m2))
            + 1440
            - (tonumber(h1) * 60 + tonumber(m1))
          fields.duration = minutes .. "m"
        end
      else
        used = false
      end
    elseif not fields.time and low:match("^%d%d?:%d%d$") then
      local t = clock(low:match("^(%d+):(%d+)$"))
      if t then
        fields.time = t
      else
        used = false
      end
    elseif not fields.time and low:match("^%d%d?$") and nxt == "uhr" then
      local t = clock(low)
      if t then
        fields.time = t
        i = i + 1
      else
        used = false
      end
    elseif not fields.duration and not fields["end"] and meetings.parse_duration(low) then
      fields.duration = low
    else
      used = false
    end
    if not used then
      title[#title + 1] = w
    end
    i = i + 1
  end
  -- a service word beside an address is the service; else the first place is the location
  for _, p in ipairs(places) do
    if not (fields.online and SERVICE_WORDS[p:lower()]) and not fields.location then
      fields.location = p
    end
  end
  if all_day then
    fields.time, fields["end"] = nil, nil
  end
  if #tasks > 0 then
    fields.tasks = tasks
  end
  if #notify > 0 then
    fields.notify = vim.list_slice(notify, 1, meetings.MAX_NOTIFY)
  end
  if not fields.date then
    fields.date = today
    assumed[#assumed + 1] = "date"
  end
  return {
    title = table.concat(title, " "),
    fields = fields,
    all_day = fields.time == nil,
    assumed = assumed,
    problems = problems,
  }
end

return M
