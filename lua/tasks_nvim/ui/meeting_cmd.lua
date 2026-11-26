---@module 'tasks_nvim.ui.meeting_cmd'
---@brief `:Tasks meeting ...`: the meetings of the vault in the editor: pick one, open it at a section, make one, close one.
---@description
--- A thin layer: the window, the picker (`vim.ui.select`) and the messages are here, every write goes through the
--- write door (`tasks_nvim.ops`), so the editor does what the app and the CLI do.
---
--- Not its job: reading or writing meeting files (`meetings`, `meeting_write`), the line of a quick capture
--- (`meeting_quick`).

local meetings = require("tasks_nvim.meetings")
local notify = require("lib.nvim.notify").create("[tasks]")

local M = {}

---The sections `open` jumps to, by the word given (German and English).
M.SECTIONS = {
  agenda = "agenda",
  teilnehmer = "participants",
  participants = "participants",
  unterlagen = "documents",
  documents = "documents",
  protokoll = "protocol",
  minutes = "protocol",
  beschluesse = "decisions",
  decisions = "decisions",
  folgeaufgaben = "followups",
  followups = "followups",
  ergebnis = "result",
  result = "result",
}

---The meetings to pick from: planned ones from yesterday on, the earliest first, then the rest the latest first.
---@param list Tasks.Meeting[]
---@param today string
---@return Tasks.Meeting[]
function M.order(list, today)
  local coming, rest = {}, {}
  local yesterday = require("tasks_nvim.model").add_days(today, -1)
  for _, m in ipairs(list) do
    if m.status == "planned" and (m.date or "") >= yesterday then
      coming[#coming + 1] = m
    else
      rest[#rest + 1] = m
    end
  end
  table.sort(coming, meetings.less)
  table.sort(rest, function(a, b)
    return meetings.less(b, a)
  end)
  return vim.list_extend(coming, rest)
end

---One line of the picker.
---@param m Tasks.Meeting
---@return string
function M.label(m)
  local when = (m.date or "????-??-??") .. (m.time and (" " .. m.time) or "")
  local where = m.online_service or m.location
  return ("%s  %-9s %s%s  (%s)"):format(
    when,
    m.status or "?",
    m.title,
    where and ("  @" .. where) or "",
    m.id
  )
end

---The line of the heading of section `key` in the file, or nil.
---@param path string
---@param key string
---@return integer|nil
function M.section_line(path, key)
  local names = meetings.HEADINGS[key]
  if not names then
    return nil
  end
  local lines = vim.fn.readfile(path)
  for i, line in ipairs(lines) do
    for _, name in ipairs(names) do
      if vim.trim(line) == name then
        return i
      end
    end
  end
  return nil
end

---Open a meeting file, at the section `section` (a word of `M.SECTIONS`) when given.
---@param m Tasks.Meeting
---@param section? string
function M.open(m, section)
  local ok, err = pcall(vim.cmd, "edit " .. vim.fn.fnameescape(m.path))
  if not ok then
    notify.error(("cannot open %s: %s"):format(m.id, tostring(err)))
    return
  end
  local key = section and M.SECTIONS[section:lower()]
  if section and not key then
    notify.warn("no such section: " .. section)
  end
  local line = key and M.section_line(m.path, key)
  if line then
    vim.api.nvim_win_set_cursor(0, { line, 0 })
  end
end

---Send one operation through the write door; nil and a message on failure.
local run_op = require("tasks_nvim.ui.write_door").run

---`:Tasks meeting list [area]`: pick a meeting and open it.
---@param ctx table
function M.list(ctx)
  local area = ctx.args and ctx.args.area or nil
  local list, err
  if area then
    list, err = meetings.area(area)
  else
    list, err = meetings.all()
  end
  if not list then
    notify.error(tostring(err))
    return
  end
  if #list == 0 then
    notify.info("no meetings" .. (area and (" in " .. area) or ""))
    return
  end
  local ordered = M.order(list, require("tasks_nvim.model").today())
  vim.ui.select(ordered, { prompt = "Meeting", format_item = M.label }, function(choice)
    if choice then
      M.open(choice, ctx.flags and ctx.flags.section or nil)
    end
  end)
end

---`:Tasks meeting open <id> [section=<word>]`.
---@param ctx table
function M.open_cmd(ctx)
  local m, err = meetings.find(ctx.args.id)
  if not m then
    notify.error(tostring(err))
    return
  end
  M.open(m, ctx.flags and ctx.flags.section or nil)
end

---`:Tasks meeting new <area> <line...>`: the rest of the line is read by the quick capture (day, time, @place, ...;
---every other word is the title); the meeting is made and opened.
---@param ctx table
function M.new(ctx)
  local line = table.concat(ctx.rest or {}, " ")
  local proposal = require("tasks_nvim.meeting_quick").parse(line)
  if proposal.title == "" then
    notify.error(
      'usage: :Tasks meeting new <area> <day> <time> <title> (e.g. "Mo 14:00 Sync @teams")'
    )
    return
  end
  for _, p in ipairs(proposal.problems) do
    notify.warn("not read: " .. p)
  end
  local entry = run_op({
    op = "meeting_new",
    area = ctx.args.area,
    title = proposal.title,
    fields = proposal.fields,
  })
  if not entry then
    return
  end
  local m = meetings.find(entry.id)
  if m then
    M.open(m, "agenda")
  end
  notify.info(
    ("%s made%s"):format(entry.id, #proposal.assumed > 0 and " (no day given: today)" or "")
  )
end

---`:Tasks meeting close <id> [result=<text>]`.
---@param ctx table
function M.close(ctx)
  local entry = run_op({
    op = "meeting_close",
    id = ctx.args.id,
    result = ctx.flags and ctx.flags.result or nil,
  })
  if entry then
    notify.info(
      ("%s done%s"):format(entry.id, entry.without_result and " (without a result)" or "")
    )
    vim.cmd("checktime")
  end
end

return M
