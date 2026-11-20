---@module 'tasks_nvim.meeting_write'
-- @scans-data: the folders it lists and the paths it names are task vaults, never the files of this plugin
---@brief Writing meeting files: make one, change its frontmatter, close it, capture a line of the minutes, tick who was there, make tasks of its follow-ups, save a whiteboard.
---@description
--- Every change of an existing meeting is read and written under the lock of its file, on the version the caller read
--- (`if_match`, else the version on disk), and it sets `updated`. A change that would make the file wrong (a bad date,
--- an end before the beginning) is refused with the words of `meetings.parse`; a fault the file had already is not the
--- change's. Text in, text out where it can be: the body helpers below are pure.
---
--- A capture (`capture`) is one line: it goes into `## Protokoll` with its time, and a task, a decision or a question
--- also into the section of its kind (`## Folgeaufgaben`, `## Beschlüsse`, `## Offene Fragen`). Two machines writing
--- the minutes at once lose at most a line that is sent again: a capture never rewrites the body as a whole.
---
--- Not its job: the shape of a request (`ops`), reading meetings (`meetings`), the rule check (`check`).

local fm = require("lib.nvim.markdown.frontmatter")
local fsio = require("tasks_nvim.fsio")
local meetings = require("tasks_nvim.meetings")
local model = require("tasks_nvim.model")
local scan = require("tasks_nvim.scan")
local sections = require("tasks_nvim.sections")
local vault = require("tasks_nvim.vault")

local M = {}

---The keys `new` takes in `fields` and `set` may change. `title`, `status` and `date` cannot be removed.
---@type string[]
M.KEYS = {
  "title",
  "status",
  "date",
  "time",
  "end",
  "duration",
  "tz",
  "location",
  "online",
  "tasks",
  "notify",
  "notify_to",
  "cover",
  "image",
  "icon",
  "tags",
  "recording",
  "summary",
  "repeat",
  "repeat_until",
  "except",
}

---The keys whose value is a list.
local LIST_KEYS = { tasks = true, notify = true, notify_to = true, tags = true, except = true }

---The keys that cannot be removed.
local REQUIRED = { title = true, status = true, date = true }

---The kinds of a capture (`capture`).
---@type string[]
M.CAPTURE_KINDS = { "text", "task", "decision", "question", "board", "photo", "audio" }

---The formats of a whiteboard (`board_save`) and the ending of its file.
---@type table<string, string>
M.BOARD_FORMATS = { ink = "ink.json", excalidraw = "excalidraw" }

---The folder of the whiteboards below the folder of their file.
M.BOARDS_DIR = "assets/boards"

---Longest text of one capture, in characters.
M.MAX_CAPTURE = 2000

---Longest slug a meeting gets from its title and date.
M.MAX_SLUG = 60

---Largest whiteboard file and preview, in bytes.
M.MAX_BOARD_BYTES = 50 * 1024 * 1024

---The headings of the sections a capture and `close` write, German and English (the first is the default).
local QUESTIONS = { "## Offene Fragen", "## Open questions" }

---The words a capture line begins with, by kind and language.
local LABELS = {
  de = { task = "Aufgabe", decision = "Beschluss", question = "Frage", audio = "Audio" },
  en = { task = "Task", decision = "Decision", question = "Question", audio = "Audio" },
}

---The sections of a new meeting, in the order they are written.
local TEMPLATE =
  { "agenda", "participants", "documents", "protocol", "decisions", "followups", "result" }

-- ── text helpers (pure) ──────────────────────────────────────────────────────

---@type fun(text: string): string|nil, string|nil
local split_file

---@param text string
---@return string[]
local function split_lines(text)
  return vim.split((text:gsub("\r\n", "\n")), "\n", { plain = true })
end

---Whether a body is written in English: it has one of the English headings of a meeting and none of the German ones.
---@param body string
---@return "de"|"en"
function M.lang_of(body)
  local de, en = false, false
  for _, names in pairs(meetings.HEADINGS) do
    for i, name in ipairs(names) do
      if body:find("\n" .. name .. "\n", 1, true) or body:sub(1, #name + 1) == name .. "\n" then
        if i == 1 then
          de = true
        else
          en = true
        end
      end
    end
  end
  if en and not de then
    return "en"
  end
  return "de"
end

---Where a section of one of `names` is: its heading line and its last line (before the next `## ` heading, outside a
---code fence); nil when the body has none.
---@param lines string[]
---@param names string[]
---@return integer|nil first
---@return integer|nil last
local function find_section(lines, names)
  local want = {}
  for _, n in ipairs(names) do
    want[n] = true
  end
  local first, fence
  for i, line in ipairs(lines) do
    if first then
      if line:match("^%s*```") or line:match("^%s*~~~") then
        fence = not fence
      elseif not fence and line:match("^## ") then
        return first, i - 1
      end
    elseif want[vim.trim(line)] then
      first, fence = i, false
    end
  end
  if first then
    return first, #lines
  end
  return nil, nil
end

---The heading a body uses for a section (`key` of `meetings.HEADINGS`, or the list `names`): the one it has, else the
---one of its language.
---@param body string
---@param names string[]
---@return string
local function heading_for(body, names)
  local lines = split_lines(body)
  local first = find_section(lines, names)
  if first then
    return vim.trim(lines[first])
  end
  return M.lang_of(body) == "en" and (names[2] or names[1]) or names[1]
end

---The body with `new_lines` added at the end of the section of one of `names` (after its last line that is not blank);
---a body without the section gets it at its end.
---@param body string
---@param names string[]
---@param new_lines string[]
---@return string
function M.append_to_section(body, names, new_lines)
  local lines = split_lines(body)
  local first, last = find_section(lines, names)
  if not first then
    local block = heading_for(body, names) .. "\n\n" .. table.concat(new_lines, "\n")
    return sections.set(body, block)
  end
  local at = last
  while at > first and vim.trim(lines[at]) == "" do
    at = at - 1
  end
  local out = vim.list_slice(lines, 1, at)
  if at == first then
    -- an empty section: one blank line under its heading
    out[#out + 1] = ""
  end
  vim.list_extend(out, new_lines)
  local rest = vim.list_slice(lines, at + 1)
  if #rest > 0 and last < #lines and vim.trim(rest[1] or "") ~= "" then
    out[#out + 1] = ""
  end
  vim.list_extend(out, rest)
  local text = table.concat(out, "\n")
  if not text:match("\n$") then
    text = text .. "\n"
  end
  return text
end

---The body with the section of one of `names` set to `text` (replacing it, else added at the end).
---@param body string
---@param names string[]
---@param text string
---@return string
function M.set_section(body, names, text)
  local lines = split_lines(body)
  local first, last = find_section(lines, names)
  local heading = heading_for(body, names)
  local block = heading .. "\n\n" .. vim.trim(text)
  if not first then
    return sections.set(body, block)
  end
  local out = vim.list_slice(lines, 1, first - 1)
  vim.list_extend(out, split_lines(block))
  local rest = vim.list_slice(lines, last + 1)
  while #rest > 0 and rest[#rest] == "" do
    rest[#rest] = nil
  end
  if #rest > 0 then
    out[#out + 1] = ""
    vim.list_extend(out, rest)
  end
  return table.concat(out, "\n") .. "\n"
end

---The lines of the checkbox (or list) items of a section, with their line numbers in the body.
---@param lines string[]
---@param names string[]
---@param checkbox_only boolean
---@return { line: integer, text: string }[]
local function item_lines(lines, names, checkbox_only)
  local first, last = find_section(lines, names)
  local out = {}
  if not first then
    return out
  end
  local fence = false
  for i = first + 1, last do
    local line = lines[i]
    if line:match("^%s*```") or line:match("^%s*~~~") then
      fence = not fence
    elseif not fence then
      if line:match("^%s*[-*+] %[[ xX]%]%s+") then
        out[#out + 1] = { line = i, text = line }
      elseif not checkbox_only and line:match("^%s*[-*+]%s+%S") then
        out[#out + 1] = { line = i, text = line }
      end
    end
  end
  return out
end

---A checkbox line ticked or not (a plain list line becomes a checkbox).
---@param line string
---@param ticked boolean
---@return string
local function tick_line(line, ticked)
  local mark = ticked and "x" or " "
  local indent, bullet, rest = line:match("^(%s*)([-*+]) %[[ xX]%]%s+(.*)$")
  if not indent then
    indent, bullet, rest = line:match("^(%s*)([-*+])%s+(.*)$")
  end
  return ("%s%s [%s] %s"):format(indent, bullet, mark, rest)
end

---Tick or untick participant `n` (1-based, in the order `meetings.parse` counts them) or the one called `name` (case
---does not matter). Returns the new body and whether the participant was present before.
---@param body string
---@param who { n?: integer, name?: string }
---@param present boolean
---@return string|nil body
---@return boolean|string was  # Whether present before; the error when there is no such participant.
function M.attend_body(body, who, present)
  local lines = split_lines(body)
  local items = item_lines(lines, meetings.HEADINGS.participants, false)
  local people = meetings.parse("---\ntitle: x\nstatus: planned\ndate: 2000-01-01\n---\n" .. body, {
    path = "x.md",
    area = "x",
    slug = "x",
  }).participants
  local pick
  if who.n then
    pick = people[who.n]
  else
    local want = vim.trim(tostring(who.name or "")):lower()
    for _, p in ipairs(people) do
      if p.name:lower() == want then
        pick = p
        break
      end
    end
  end
  if not pick or not items[pick.n] then
    return nil, "no such participant: " .. tostring(who.n or who.name)
  end
  local at = items[pick.n].line
  lines[at] = tick_line(lines[at], present)
  return table.concat(lines, "\n"), pick.present
end

---The body with the follow-up `n` naming the task `id` (`-> <id>` at its end).
---@param body string
---@param n integer
---@param text string   # The text the line had when its task was made: a line that moved meanwhile is found by it.
---@param id string
---@return string|nil body
---@return string|nil err
function M.followup_task_body(body, n, text, id)
  local lines = split_lines(body)
  local items = item_lines(lines, meetings.HEADINGS.followups, true)
  local function plain(line)
    return vim.trim((line:gsub("^%s*[-*+] %[[ xX]%]%s+", "")))
  end
  local pick = items[n]
  if not pick or plain(pick.text) ~= text then
    pick = nil
    for _, item in ipairs(items) do
      if plain(item.text) == text then
        pick = item
        break
      end
    end
  end
  if not pick then
    return nil, "the follow-up '" .. text .. "' is no longer in the meeting"
  end
  lines[pick.line] = (lines[pick.line]:gsub("%s+$", "")) .. " -> " .. id
  return table.concat(lines, "\n"), nil
end

---The sections `tick_step` and `add_steps` work on in a meeting.
M.ITEM_SECTIONS = { agenda = true, followups = true }

---Tick or untick item `n` (1-based) of the checkbox section `key` (`agenda`, `followups`). Returns the new body and
---whether the item was ticked before.
---@param body string
---@param key string
---@param n integer
---@param done boolean
---@return string|nil body
---@return boolean|string was  # The error when there is no such item.
function M.tick_item(body, key, n, done)
  local lines = split_lines(body)
  local items = item_lines(lines, meetings.HEADINGS[key], true)
  local item = items[n]
  if not item then
    return nil, ("no item %d in the %s"):format(n, key)
  end
  local was = item.text:match("^%s*[-*+] %[[xX]%]") ~= nil
  lines[item.line] = tick_line(item.text, done)
  return table.concat(lines, "\n"), was
end

---Add open items (one line of text each) at the end of the checkbox section `key` (`agenda`, `followups`).
---@param body string
---@param key string
---@param texts string[]
---@return string|nil body
---@return string|nil err
function M.add_items(body, key, texts)
  local new_lines = {}
  for _, t in ipairs(texts) do
    if type(t) ~= "string" or t:find("[\r\n]") or vim.trim(t) == "" then
      return nil, "an item is one line of text"
    end
    new_lines[#new_lines + 1] = "- [ ] " .. vim.trim(t)
  end
  if #new_lines == 0 then
    return nil, "no items"
  end
  return M.append_to_section(body, meetings.HEADINGS[key], new_lines), nil
end

---A transform of the whole file text (`edit`) made of one of the body.
---@param fn fun(body: string, meeting: Tasks.Meeting): string|nil, string|nil, any
---@return fun(text: string, meeting: Tasks.Meeting): string|nil, string|nil, any
function M.on_body(fn)
  return function(text, meeting)
    local head, body = split_file(text)
    if not head then
      return nil, "the meeting has no frontmatter block"
    end
    local new_body, err, extra = fn(body, meeting)
    if not new_body then
      return nil, err, extra
    end
    return head .. new_body, nil, extra
  end
end

---The body with every follow-up that names `id` ticked (`done` of the task); nil when none names it.
---@param body string
---@param id string
---@return string|nil
function M.tick_followups_of(body, id)
  local lines = split_lines(body)
  local changed = false
  local arrow = string.char(0xE2, 0x86, 0x92)
  for _, item in ipairs(item_lines(lines, meetings.HEADINGS.followups, true)) do
    local named = item.text:match("%->%s*(%S+)%s*$") or item.text:match(arrow .. "%s*(%S+)%s*$")
    if named == id and not item.text:match("^%s*[-*+] %[[xX]%]") then
      lines[item.line] = tick_line(item.text, true)
      changed = true
    end
  end
  return changed and table.concat(lines, "\n") or nil
end

---The body with every follow-up arrow naming `from` naming `to` (`move_area` of the task); nil when none names it.
---@param body string
---@param from string
---@param to string
---@return string|nil
function M.rename_followups(body, from, to)
  local lines = split_lines(body)
  local changed = false
  local arrow = string.char(0xE2, 0x86, 0x92)
  for _, item in ipairs(item_lines(lines, meetings.HEADINGS.followups, true)) do
    for _, sign in ipairs({ "%->", arrow }) do
      local head, named = item.text:match("^(.-" .. sign .. "%s*)(%S+)%s*$")
      if named == from then
        lines[item.line] = head .. to
        changed = true
        break
      end
    end
  end
  return changed and table.concat(lines, "\n") or nil
end

---The lines a capture writes: the line of the minutes and, for a task, a decision or a question, the line of its
---section. Pure; `entry` is checked by the caller.
---@param body string
---@param entry { kind: string, text?: string, asset?: string, at: string }
---@return string body
function M.capture_body(body, entry)
  local lang = M.lang_of(body)
  local label = LABELS[lang]
  local text = entry.text and vim.trim(entry.text) or ""
  local line
  if entry.kind == "text" then
    line = text
  elseif entry.kind == "task" or entry.kind == "decision" or entry.kind == "question" then
    line = label[entry.kind] .. ": " .. text
  elseif entry.kind == "board" or entry.kind == "photo" then
    local alt = text ~= "" and text or vim.fs.basename(entry.asset)
    line = ("![%s](%s)"):format(alt, entry.asset)
  else -- audio
    local alt = text ~= "" and text or vim.fs.basename(entry.asset)
    line = ("[%s: %s](%s)"):format(label.audio, alt, entry.asset)
  end
  body =
    M.append_to_section(body, meetings.HEADINGS.protocol, { ("- %s %s"):format(entry.at, line) })
  if entry.kind == "task" then
    body = M.append_to_section(body, meetings.HEADINGS.followups, { "- [ ] " .. text })
  elseif entry.kind == "decision" then
    body = M.append_to_section(body, meetings.HEADINGS.decisions, { "- " .. text })
  elseif entry.kind == "question" then
    body = M.append_to_section(body, QUESTIONS, { "### " .. text })
  end
  return body
end

-- ── files ────────────────────────────────────────────────────────────────────

---The head (frontmatter block) and body of a file's text.
---@param text string
---@return string|nil head
---@return string|nil body
split_file = function(text)
  local parsed = fm.parse(text)
  if not parsed or not parsed.has_block then
    return nil, nil
  end
  local body = parsed.body or ""
  return text:sub(1, #text - #body), body
end
M.split_file = split_file

---The error codes `after` has and `before` had not: what a change brings.
---@param before Tasks.Meeting
---@param after Tasks.Meeting
---@return string|nil message
local function new_fault(before, after)
  local known = {}
  for _, code in ipairs(before.error_codes) do
    known[code] = true
  end
  for i, code in ipairs(after.error_codes) do
    if not known[code] then
      return after.errors[i]
    end
  end
  return nil
end

---@class Tasks.MeetingEdit
---@field id string
---@field area string
---@field path string
---@field changed boolean
---@field etag_before string
---@field etag_after string
---@field extra any
---@field before? table             # `set`: the old values of the keys it changed.
---@field without_result? boolean   # `close`: the meeting has no result afterwards.
---@field status_before? string     # `close`: the status it had.
---@field body_before? string       # `capture`: the body before the line.
---@field was_present? boolean      # `attend`: the participant was present before.
---@field location? string          # `ops`: "meeting" (the task ops tell a meeting from a task by it).
---@field created? boolean          # The first entry into an occurrence of a series made its file.

---The first entry into an occurrence of a series that has no file yet (`meetings.find_any` named it `virtual`): its
---text is made from the series file (`meetings.occurrence_text`, `created` and `updated` today), `transform` is
---applied, and the file `<slug of the series>-<day>.md` is created in one step; a change that changes nothing writes
---nothing (the occurrence stays computed), unless `opts.materialize` asks for the file. `if_match` is the version of
---the series file (the version of the occurrence as it was read). A file made between the read and the write is a
---`conflict`: the caller reads the occurrence again.
---@param found Tasks.Meeting
---@param transform fun(text: string, meeting: Tasks.Meeting): string|nil, string|nil, any
---@param opts { root?: string, today?: string, if_match?: string, dry_run?: boolean, materialize?: boolean }
---@return Tasks.MeetingEdit|nil result
---@return string|nil err
---@return table|nil info
local function occurrence_edit(found, transform, opts)
  local today = opts.today or model.today()
  local series_text, rd_err = fsio.read(found.series_path)
  if not series_text then
    return nil, "cannot read the series " .. tostring(found.series) .. ": " .. tostring(rd_err)
  end
  local etag = fsio.etag(series_text)
  local result = {
    id = found.id,
    area = found.area,
    path = found.path,
    changed = false,
    etag_before = etag,
    etag_after = etag,
  }
  if opts.if_match ~= nil and opts.if_match ~= etag then
    return nil,
      ("%s is not the version the change was made on (its series is %s, the change was made on %s)"):format(
        found.id,
        etag,
        tostring(opts.if_match)
      ),
      { code = "conflict", id = found.id, expected = opts.if_match, actual = etag }
  end
  local series_area, series_slug = vault.parse_id(found.series)
  local series = meetings.parse(series_text, {
    path = found.series_path,
    area = series_area --[[@as string]],
    slug = series_slug,
  })
  if not series.valid or not series.repeat_every then
    return nil, found.series .. " is no series any more", { code = "conflict", id = found.id }
  end
  local cur = meetings.occurrence_text(series_text, series, found.occurrence)
  cur = cur and fm.update_text(cur, { { "created", today }, { "updated", today } })
  if not cur then
    return nil, "cannot build the occurrence " .. found.id
  end
  local ctx = { path = found.path, area = found.area, slug = found.slug, folder = false }
  local before = meetings.parse(cur, ctx)
  local text, terr, extra = transform(cur, before)
  result.extra = extra
  if not text then
    return nil, terr or "the change cannot be made", { code = "invalid_argument" }
  end
  if text == cur and not opts.materialize then
    return result, nil
  end
  local fault = new_fault(before, meetings.parse(text, ctx))
  if fault then
    return nil, fault, { code = "invalid_argument" }
  end
  result.changed = true
  result.created = true
  result.etag_after = fsio.etag(text)
  if opts.dry_run then
    return result, nil
  end
  local ok, cerr = fsio.create_exclusive(found.path, text)
  if not ok then
    if fsio.is_exists(cerr) then
      return nil,
        found.id .. " was written in the meantime: read it again",
        { code = "conflict", id = found.id, expected = opts.if_match }
    end
    return nil, "cannot create " .. found.id .. ": " .. tostring(cerr)
  end
  return result, nil
end

---The file an occurrence of a series without a file would get, as `mutate.attach_target` names a target (for a dry
---run: nothing is made); nil for any other id.
---@param id string
---@param root string
---@return table|nil
function M.occurrence_target(id, root)
  local found = meetings.find_any(id, { root = root })
  if not found or not found.virtual then
    return nil
  end
  return {
    id = found.id,
    area = found.area,
    slug = found.slug,
    path = found.path,
    folder = false,
    file_kind = "meeting",
    etag = found.etag,
  }
end

---Give the occurrence `id` of a series its file when it has none yet (before something is attached to it). True when
---the file was made, false when there was nothing to do (a meeting file, or no meeting at all: the caller says so).
---@param id string
---@param opts { root?: string, today?: string }
---@return boolean|nil made
---@return string|nil err
---@return table|nil info
function M.materialize(id, opts)
  local root, rerr = vault.root(opts)
  if not root then
    return nil, rerr
  end
  local found = meetings.find_any(id, { root = root })
  if not found or not found.virtual then
    return false, nil
  end
  local r, err, info = occurrence_edit(found, function(text)
    return text
  end, { root = root, today = opts.today, materialize = true })
  if not r then
    return nil, err, info
  end
  return true, nil
end

---Change a meeting file under its lock. `transform(text, meeting)` gives the new text (or nil and an error, and an
---extra value handed back in `extra`); `updated` is set when the text changed. The change is refused when the file is
---not the version `opts.if_match` names (`conflict`) or when it brings a fault (`invalid_argument`).
---@param id string
---@param transform fun(text: string, meeting: Tasks.Meeting): string|nil, string|nil, any
---@param opts { root?: string, today?: string, if_match?: string, dry_run?: boolean }
---@return Tasks.MeetingEdit|nil result
---@return string|nil err
---@return table|nil info  # `{ code = "not_found"|"invalid_argument"|"conflict"|"forbidden" }`
function M.edit(id, transform, opts)
  local root, rerr = vault.root(opts)
  if not root then
    return nil, rerr
  end
  local found, ferr = meetings.find_any(id, { root = root })
  if not found then
    return nil, ferr, { code = "not_found" }
  end
  if found.virtual then
    return occurrence_edit(found, transform, opts)
  end
  if fsio.is_link(found.path) then
    return nil,
      id .. " is a symbolic link or junction: it is not written through",
      { code = "forbidden" }
  end
  local today = opts.today or model.today()
  local result = { id = found.id, area = found.area, path = found.path, changed = false }
  local ok, werr, winfo = fsio.with_lock(found.path, function()
    local cur, rd_err = fsio.read(found.path)
    if not cur then
      return nil, "cannot read " .. found.id .. ": " .. tostring(rd_err)
    end
    local etag = fsio.etag(cur)
    result.etag_before, result.etag_after = etag, etag
    if opts.if_match ~= nil and opts.if_match ~= etag then
      return nil,
        ("%s is not the version the change was made on (it is %s, the change was made on %s)"):format(
          found.id,
          etag,
          tostring(opts.if_match)
        ),
        { code = "conflict", id = found.id, expected = opts.if_match, actual = etag }
    end
    local ctx = { path = found.path, area = found.area, slug = found.slug, folder = found.folder }
    local before = meetings.parse(cur, ctx)
    local text, terr, extra = transform(cur, before)
    result.extra = extra
    if not text then
      return nil, terr or "the change cannot be made", { code = "invalid_argument" }
    end
    if text ~= cur then
      text = fm.update_text(text, { { "updated", today } }) or text
      local fault = new_fault(before, meetings.parse(text, ctx))
      if fault then
        return nil, fault, { code = "invalid_argument" }
      end
    end
    result.changed = text ~= cur
    result.etag_after = fsio.etag(text)
    if opts.dry_run or not result.changed then
      return true
    end
    local wrote, wr_err = fsio.write_atomic(found.path, text)
    if not wrote then
      return nil, "cannot write " .. found.id .. ": " .. tostring(wr_err)
    end
    return true
  end)
  if not ok then
    return nil, werr, winfo
  end
  return result, nil
end

---Change the body of a meeting (`transform(body, meeting)`), the frontmatter as it is.
---@param id string
---@param transform fun(body: string, meeting: Tasks.Meeting): string|nil, string|nil, any
---@param opts table
---@return Tasks.MeetingEdit|nil
---@return string|nil
---@return table|nil
function M.edit_body(id, transform, opts)
  return M.edit(id, function(text, meeting)
    local head, body = split_file(text)
    if not head then
      return nil, "the meeting has no frontmatter block"
    end
    local new_body, err, extra = transform(body, meeting)
    if not new_body then
      return nil, err, extra
    end
    return head .. new_body, nil, extra
  end, opts)
end

-- ── frontmatter values ───────────────────────────────────────────────────────

---Whether `id` is a task that exists, open or finished.
---@param root string
---@param id string
---@return boolean
local function task_exists(root, id)
  return scan.find(id, { root = root }) ~= nil or scan.find_done(id, { root = root }) ~= nil
end

---The frontmatter pairs of `fields` (keys of `M.KEYS`): a list value as a list, `nil`/`vim.NIL`/an empty value as
---removal. New task ids must name a task that exists (`known` holds the ids the file has already).
---@param root string
---@param fields table<string, any>
---@param known? table<string, boolean>
---@return table[]|nil pairs
---@return string|nil err
local function pairs_of(root, fields, known)
  local allowed = {}
  for _, k in ipairs(M.KEYS) do
    allowed[k] = true
  end
  local keys = vim.tbl_keys(fields)
  table.sort(keys)
  local out = {}
  for _, key in ipairs(keys) do
    if not allowed[key] then
      return nil,
        ("unknown field '%s' (meetings take: %s)"):format(tostring(key), table.concat(M.KEYS, ", "))
    end
    local value = fields[key]
    local remove = value == nil
      or value == vim.NIL
      or value == ""
      or (type(value) == "table" and #value == 0)
    if remove then
      if REQUIRED[key] then
        return nil, key .. " cannot be removed"
      end
      out[#out + 1] = { key, fm.REMOVE }
    elseif LIST_KEYS[key] then
      local items = type(value) == "table" and value
        or vim.split(tostring(value), ",", { plain = true })
      local list = {}
      for _, item in ipairs(items) do
        if type(item) ~= "string" then
          return nil, key .. " must be a list of texts"
        end
        local t = vim.trim(item)
        if t:find("[,%[%]\"'#\r\n]") and key ~= "notify" then
          return nil, key .. " item '" .. t .. "' must not contain , [ ] quotes # or a line break"
        end
        if t ~= "" then
          if key == "tasks" and not (known and known[t]) and not task_exists(root, t) then
            return nil, "tasks: no such task: " .. t
          end
          list[#list + 1] = t
        end
      end
      out[#out + 1] = { key, list }
    else
      if type(value) ~= "string" then
        return nil, key .. " must be a text"
      end
      local t = vim.trim(value)
      if t:find("[\r\n]") then
        return nil, key .. " must be one line"
      end
      out[#out + 1] = { key, t }
    end
  end
  return out, nil
end

-- ── operations ───────────────────────────────────────────────────────────────

---The slug a meeting gets: the title folded (`mutate.slugify`) and its date (`sync-mit-rick-2026-11-24`).
---@param title string
---@param date string
---@return string
function M.slug_of(title, date)
  local base = require("tasks_nvim.mutate").slugify(title)
  local room = M.MAX_SLUG - #date - 1
  if #base > room then
    base = base:sub(1, room):gsub("%-+$", "")
  end
  return base .. "-" .. date
end

---The body of a new meeting: the summary (when given) and the empty sections, German or English.
---@param lang "de"|"en"
---@param summary? string
---@return string
function M.template_body(lang, summary)
  local parts = { "" }
  if summary and vim.trim(summary) ~= "" then
    parts[#parts + 1] = vim.trim(summary)
    parts[#parts + 1] = ""
  end
  for _, key in ipairs(TEMPLATE) do
    local names = meetings.HEADINGS[key]
    parts[#parts + 1] = lang == "en" and (names[2] or names[1]) or names[1]
    parts[#parts + 1] = ""
  end
  return table.concat(parts, "\n")
end

---Make a meeting file `<area>/MEETINGS/<slug>.md`. `fields` are the keys of `M.KEYS` (`date` is needed; `status`
---defaults to `planned`, `done` is not made: a meeting is closed with `close`); `body` replaces the template's
---sections; `slug` overrides the one of title and date (then a taken slug is an error, else it gets `-2`, `-3`, ...).
---A dry run names the id it would get.
---@param area string
---@param opts { root?: string, today?: string, title: string, fields?: table, body?: string, slug?: string, lang?: "de"|"en", dry_run?: boolean }
---@return { id: string, path: string, slug: string, renamed: boolean }|nil result
---@return string|nil err
---@return table|nil info
function M.new(area, opts)
  local root, rerr = vault.root(opts)
  if not root then
    return nil, rerr
  end
  if not vault.has_area(root, area) then
    return nil, "unknown area: " .. tostring(area), { code = "invalid_argument" }
  end
  local title = type(opts.title) == "string" and vim.trim(fsio.clean(opts.title)) or ""
  if title == "" or title:find("[\r\n]") then
    return nil, "title must be one non-empty line", { code = "invalid_argument" }
  end
  local fields = vim.deepcopy(opts.fields or {})
  fields.title = title
  fields.status = fields.status or "planned"
  if fields.status == "done" then
    return nil,
      "a meeting is made planned or cancelled; it is closed with meeting_close",
      { code = "invalid_argument" }
  end
  if type(fields.date) ~= "string" or not model.is_date(fields.date) then
    return nil, "date is needed (YYYY-MM-DD)", { code = "invalid_argument" }
  end
  local today = opts.today or model.today()
  if not model.is_date(today) then
    return nil, "today is not a date (YYYY-MM-DD): " .. tostring(today)
  end
  local list, perr = pairs_of(root, fields)
  if not list then
    return nil, perr, { code = "invalid_argument" }
  end
  -- the frontmatter in the order of `M.KEYS`, then `created` and `updated`
  local by_key = {}
  for _, kv in ipairs(list) do
    if kv[2] ~= fm.REMOVE then
      by_key[kv[1]] = kv[2]
    end
  end
  local ordered = {}
  for _, key in ipairs(M.KEYS) do
    if by_key[key] ~= nil then
      ordered[#ordered + 1] = { key, by_key[key] }
    end
  end
  ordered[#ordered + 1] = { "created", today }
  ordered[#ordered + 1] = { "updated", today }
  local body
  if opts.body ~= nil then
    body = "\n" .. vim.trim(fsio.lf(opts.body)) .. "\n"
  else
    body = M.template_body(opts.lang == "en" and "en" or "de", nil)
  end
  local text, ferr = fm.update_text(body, ordered, { create = true })
  if not text then
    return nil, "cannot build the meeting file: " .. tostring(ferr)
  end

  local base = opts.slug or M.slug_of(title, fields.date)
  local slug_err, slug_details = vault.slug_error("slug", base)
  if slug_err then
    return nil, slug_err, { code = "invalid_argument", details = slug_details }
  end
  if vault.is_reserved_name(base) then
    return nil,
      ("slug '%s' is a reserved Windows device name"):format(base),
      { code = "invalid_argument" }
  end
  -- judged as the file would read: a bad time, an end before the beginning, a bad zone
  local probe = meetings.parse(text, { path = base .. ".md", area = area, slug = base })
  if not probe.valid then
    return nil, probe.errors[1], { code = "invalid_argument" }
  end

  local dir = vault.meetings_dir(root, area)
  if not opts.dry_run then
    local made, mkerr = fsio.mkdirp(dir)
    if not made then
      return nil, "cannot create the meeting folder of " .. area .. ": " .. tostring(mkerr)
    end
  end
  local backlog_taken, berr = scan.backlog_slugs(area, { root = root })
  if not backlog_taken then
    return nil, berr
  end
  for n = 1, 999 do
    local slug = n == 1 and base or (base .. "-" .. n)
    local path = dir .. "/" .. slug .. ".md"
    -- tasks, plans, projects and meetings share one id namespace
    local held = backlog_taken[slug] ~= nil
      or fsio.is_file(vault.task_path(root, area, slug))
      or fsio.is_dir(vault.task_dir(root, area, slug))
      or vault.has_plan_or_project(root, area, slug)
      or fsio.is_dir(dir .. "/" .. slug)
      or fsio.is_file(path)
    if held and opts.slug then
      return nil, ("the id %s/%s is taken"):format(area, slug), { code = "exists" }
    end
    if not held then
      local result = { id = area .. "/" .. slug, path = path, slug = slug, renamed = n > 1 }
      if opts.dry_run then
        return result, nil
      end
      local ok, cerr = fsio.create_exclusive(path, text)
      if ok then
        return result, nil
      end
      if not fsio.is_exists(cerr) then
        return nil, "cannot create the meeting " .. area .. "/" .. slug .. ": " .. tostring(cerr)
      end
    end
  end
  return nil, "no free file name for meeting " .. base
end

---Change the frontmatter of a meeting. `patch` maps keys of `M.KEYS` to their new value (`nil`, `vim.NIL` or an empty
---value removes one; not `title`, `status`, `date`). `status` goes between `planned` and `cancelled`, and `done` back
---to `planned` (open again); `done` itself is `close`. The answer has the old values (`before`) for an undo.
---@param id string
---@param patch table<string, any>
---@param opts { root?: string, today?: string, if_match?: string, dry_run?: boolean }
---@return (Tasks.MeetingEdit|{ before: table })|nil
---@return string|nil
---@return table|nil
function M.set(id, patch, opts)
  local root, rerr = vault.root(opts)
  if not root then
    return nil, rerr
  end
  if type(patch) ~= "table" or next(patch) == nil then
    return nil, "the patch is empty", { code = "invalid_argument" }
  end
  if patch.status == "done" then
    return nil,
      "a meeting is finished with meeting_close, not by status done",
      { code = "invalid_argument" }
  end
  local before = {}
  local r, err, info = M.edit(id, function(text, meeting)
    local known = {}
    for _, t in ipairs(meeting.tasks) do
      known[t] = true
    end
    local list, perr = pairs_of(root, patch, known)
    if not list then
      return nil, perr
    end
    local parsed = fm.parse(text)
    for _, kv in ipairs(list) do
      local old = parsed and parsed.has_block and fm.get(parsed, kv[1]) or nil
      before[kv[1]] = old == nil and vim.NIL or old
    end
    local new_text, uerr = fm.update_text(text, list)
    if not new_text then
      return nil, "cannot change " .. id .. ": " .. tostring(uerr)
    end
    return new_text
  end, opts)
  if not r then
    return nil, err, info
  end
  r.before = before
  return r, nil
end

---Finish a meeting (`status: done`), at any time and with or without a result (decision F4). `result` sets the section
---`## Ergebnis` in the same write. `without_result` says the meeting has none afterwards.
---@param id string
---@param opts { root?: string, today?: string, if_match?: string, dry_run?: boolean, result?: string }
---@return (Tasks.MeetingEdit|{ without_result: boolean, status_before?: string })|nil
---@return string|nil
---@return table|nil
function M.close(id, opts)
  local has_result, status_before = false, nil
  local r, err, info = M.edit(id, function(text, meeting)
    status_before = meeting.status
    local new_text = text
    if opts.result ~= nil and vim.trim(opts.result) ~= "" then
      local head, body = split_file(new_text)
      if not head then
        return nil, "the meeting has no frontmatter block"
      end
      new_text = head .. M.set_section(body, meetings.HEADINGS.result, fsio.lf(opts.result))
    end
    if meeting.status ~= "done" then
      new_text = fm.update_text(new_text, { { "status", "done" } }) or new_text
    end
    local after =
      meetings.parse(new_text, { path = meeting.path, area = meeting.area, slug = meeting.slug })
    has_result = after.has_result
    return new_text
  end, opts)
  if not r then
    return nil, err, info
  end
  r.without_result = not has_result
  r.status_before = status_before
  return r, nil
end

---Write one capture of the minutes (`entry`: `kind` of `M.CAPTURE_KINDS`, `text`, `asset` for a board, photo or audio,
---`at` the time `HH:MM`, now when absent). The answer has the body before (`body_before`) for an undo.
---@param id string
---@param entry { kind: string, text?: string, asset?: string, at?: string }
---@param opts { root?: string, today?: string, if_match?: string, dry_run?: boolean, now?: string }
---@return (Tasks.MeetingEdit|{ body_before: string })|nil
---@return string|nil
---@return table|nil
function M.capture(id, entry, opts)
  if type(entry) ~= "table" or not vim.tbl_contains(M.CAPTURE_KINDS, entry.kind) then
    return nil,
      "entry.kind must be one of " .. table.concat(M.CAPTURE_KINDS, ", "),
      { code = "invalid_argument" }
  end
  local at = entry.at or opts.now or tostring(os.date("%H:%M"))
  if not model.is_time(at) then
    return nil,
      "entry.at is no time of day (HH:MM): " .. tostring(at),
      { code = "invalid_argument" }
  end
  local text = entry.text
  if text ~= nil and (type(text) ~= "string" or text:find("[\r\n]")) then
    return nil, "entry.text must be one line", { code = "invalid_argument" }
  end
  if text and vim.fn.strchars(text) > M.MAX_CAPTURE then
    return nil,
      ("entry.text is longer than %d characters"):format(M.MAX_CAPTURE),
      { code = "payload_too_large" }
  end
  local needs_asset = entry.kind == "board" or entry.kind == "photo" or entry.kind == "audio"
  if needs_asset then
    local a = entry.asset
    if
      type(a) ~= "string"
      or not a:match("^assets/[^%s\\]+$")
      or a:find("..", 1, true)
      or a:find("[()%[%]]")
    then
      return nil,
        "entry.asset must be a file below assets/ of the meeting",
        { code = "invalid_argument" }
    end
  elseif entry.asset ~= nil then
    return nil, "entry.asset belongs to a board, a photo or an audio", { code = "invalid_argument" }
  elseif text == nil or vim.trim(text) == "" then
    return nil, "entry.text is needed for a " .. entry.kind, { code = "invalid_argument" }
  end
  local body_before
  local r, err, info = M.edit_body(id, function(body, meeting)
    if needs_asset then
      if
        not meeting.folder or not fsio.is_file(fsio.dirname(meeting.path) .. "/" .. entry.asset)
      then
        return nil, "the meeting has no asset " .. entry.asset
      end
    end
    body_before = body
    return M.capture_body(body, { kind = entry.kind, text = text, asset = entry.asset, at = at })
  end, opts)
  if not r then
    return nil, err, info
  end
  r.body_before = body_before
  return r, nil
end

---Tick (`present`) or untick a participant: number `who.n` or name `who.name`. The answer says whether the participant
---was present before (`was_present`), for an undo.
---@param id string
---@param who { n?: integer, name?: string }
---@param present boolean
---@param opts table
---@return (Tasks.MeetingEdit|{ was_present: boolean })|nil
---@return string|nil
---@return table|nil
function M.attend(id, who, present, opts)
  local was
  local r, err, info = M.edit_body(id, function(body)
    local new_body, w = M.attend_body(body, who, present)
    if not new_body then
      return nil, tostring(w)
    end
    was = w
    return new_body
  end, opts)
  if not r then
    return nil, err, info
  end
  r.was_present = was
  return r, nil
end

---@class Tasks.FollowupResult
---@field n integer
---@field ok boolean
---@field id? string
---@field error? string
---@field code? string

---Make tasks of follow-ups: the lines `items` (numbers; default: every line that names no task yet), in `area` (default:
---the area of the meeting's first task, else the meeting's). Each task gets `refs: [<meeting>]`, the meeting's tags
---and `fields` (`kind`, `prio`, `effort`, `actor`, `value`, `due`, `plan`, `phase`); its id is written behind its line
---(`-> <id>`). One line that fails does not stop the others.
---@param id string
---@param opts { root?: string, today?: string, items?: integer[], area?: string, fields?: table, dry_run?: boolean }
---@return { id: string, path: string, items: Tasks.FollowupResult[], etag_before?: string, etag_after?: string, changed: boolean }|nil
---@return string|nil
---@return table|nil
function M.followups(id, opts)
  local root, rerr = vault.root(opts)
  if not root then
    return nil, rerr
  end
  local meeting, ferr = meetings.find_any(id, { root = root })
  if not meeting then
    return nil, ferr, { code = "not_found" }
  end
  local area = opts.area
  if area == nil then
    area = meeting.tasks[1] and vault.parse_id(meeting.tasks[1]) or meeting.area
  end
  if not vault.has_area(root, area) then
    return nil, "unknown area: " .. tostring(area), { code = "invalid_argument" }
  end
  local wanted = {}
  if opts.items then
    for _, n in ipairs(opts.items) do
      local item = meeting.followups[n]
      if not item then
        return nil, ("no follow-up %s in %s"):format(tostring(n), id), { code = "invalid_argument" }
      end
      wanted[#wanted + 1] = item
    end
  else
    for _, item in ipairs(meeting.followups) do
      if not item.task then
        wanted[#wanted + 1] = item
      end
    end
  end
  local allowed =
    { kind = 1, prio = 1, effort = 1, actor = 1, value = 1, due = 1, plan = 1, phase = 1 }
  for key in pairs(opts.fields or {}) do
    if not allowed[key] then
      return nil,
        ("fields: '%s' is not taken (kind, prio, effort, actor, value, due, plan, phase)"):format(
          tostring(key)
        ),
        { code = "invalid_argument" }
    end
  end
  local mutate = require("tasks_nvim.mutate")
  local results, made, reserved = {}, {}, {}
  for _, item in ipairs(wanted) do
    if item.task then
      results[#results + 1] = { n = item.n, ok = true, id = item.task, code = "unchanged" }
    else
      local new_opts = vim.tbl_extend("force", {}, opts.fields or {}, {
        root = root,
        today = opts.today,
        title = item.text,
        refs = { meeting.id },
        tags = #meeting.tags > 0 and meeting.tags or nil,
        dry_run = opts.dry_run,
        reserved = reserved,
        index = false,
      })
      local r, err = mutate.new(area, new_opts)
      if r then
        reserved[r.id] = true
        results[#results + 1] = { n = item.n, ok = true, id = r.id }
        made[#made + 1] = { n = item.n, text = item.text, id = r.id }
      else
        results[#results + 1] = { n = item.n, ok = false, error = tostring(err) }
      end
    end
  end
  local out =
    { id = meeting.id, path = meeting.path, items = results, changed = false, area = area }
  if #made == 0 then
    return out, nil
  end
  local r, err, info = M.edit_body(id, function(body)
    local cur = body
    for _, m in ipairs(made) do
      local nb, merr = M.followup_task_body(cur, m.n, m.text, m.id)
      if nb then
        cur = nb
      else
        for _, res in ipairs(results) do
          if res.n == m.n then
            res.note = merr
          end
        end
      end
    end
    return cur
  end, { root = root, today = opts.today, dry_run = opts.dry_run })
  if not r then
    -- the tasks are made; only their ids could not be written into the meeting
    out.error, out.info = err, info
    return out, nil
  end
  out.etag_before, out.etag_after, out.changed = r.etag_before, r.etag_after, r.changed
  return out, nil
end

---The meetings that name task `from` (in `tasks:` or behind a follow-up), for `move_area`: the new text of each (its
---`tasks:` and arrows naming `to`), by path.
---@param root string
---@param from string
---@param to string
---@param today string
---@return { id: string, path: string, old: string, new: string }[]
function M.renames_for_move(root, from, to, today)
  local out = {}
  for _, m in ipairs(meetings.all({ root = root }) or {}) do
    local names = vim.tbl_contains(m.tasks, from)
    local by_arrow = false
    for _, f in ipairs(m.followups) do
      if f.task == from then
        by_arrow = true
      end
    end
    if (names or by_arrow) and not fsio.is_link(m.path) then
      local old = fsio.read(m.path)
      if old then
        local text = old
        if names then
          local list = {}
          for _, t in ipairs(m.tasks) do
            list[#list + 1] = t == from and to or t
          end
          text = fm.update_text(text, { { "tasks", list } }) or text
        end
        if by_arrow then
          local head, body = split_file(text)
          local nb = head and M.rename_followups(body, from, to)
          if nb then
            text = head .. nb
          end
        end
        if text ~= old then
          text = fm.update_text(text, { { "updated", today } }) or text
          out[#out + 1] = { id = m.id, path = m.path, old = old, new = text }
        end
      end
    end
  end
  return out
end

---Tick the follow-up lines that name task `task_id` in the meetings its `refs` name (`done` of the task). Best effort:
---a meeting that cannot be written is told in `notes`, never a failure of the `done`.
---@param root string
---@param task_id string
---@param refs string[]
---@param today string
---@return string[] ticked   # The ids of the meetings changed.
---@return string[] notes
function M.tick_done(root, task_id, refs, today)
  local ticked, notes = {}, {}
  for _, ref in ipairs(refs or {}) do
    local area, slug = vault.parse_id(ref)
    if area and slug and vault.has_area(root, area) and vault.resolve_meeting(root, area, slug) then
      local r, err = M.edit_body(ref, function(body)
        return M.tick_followups_of(body, task_id) or body
      end, { root = root, today = today })
      if r and r.changed then
        ticked[#ticked + 1] = ref
      elseif not r then
        notes[#notes + 1] = ("the follow-up of %s in %s was not ticked: %s"):format(
          task_id,
          ref,
          tostring(err)
        )
      end
    end
  end
  return ticked, notes
end

-- ── whiteboards ──────────────────────────────────────────────────────────────

---The bytes of a file (up to `M.MAX_BOARD_BYTES`), or nil and why.
---@param path string
---@return string|nil
---@return string|nil
local function read_bytes(path)
  local st = fsio.stat(path)
  if not st or st.type ~= "file" then
    return nil, "not a file"
  end
  if st.size > M.MAX_BOARD_BYTES then
    return nil, ("larger than %d bytes"):format(M.MAX_BOARD_BYTES)
  end
  local f, err = io.open(path, "rb")
  if not f then
    return nil, tostring(err)
  end
  local data = f:read("*a")
  f:close()
  return data, nil
end

---The version tag of a board file (the SHA-256 of its bytes), or nil when there is none.
---@param path string
---@return string|nil
function M.board_etag(path)
  local data = read_bytes(path)
  return data and fsio.etag(data) or nil
end

---Write `data` to `path`: a new file only when `fresh` (another writer that made it first wins), else replacing the
---file through a temporary one beside it.
---@param path string
---@param data string
---@param fresh boolean
---@return boolean|nil ok
---@return string|nil err
local function put_bytes(path, data, fresh)
  if fresh then
    return fsio.create_exclusive(path, data)
  end
  -- byte-exact: a temporary file beside it, renamed over the old one
  return fsio.write_atomic(path, data)
end

---The ending of the board file of an external app: the ending of the upload (letters and digits, not one of a page).
---@param upload string
---@return string|nil
local function external_ending(upload)
  local ext = upload:match("%.([%w]+)$")
  if not ext then
    return nil
  end
  ext = ext:lower()
  if ext == "md" or ext == "html" or ext == "htm" or ext == "svg" or ext == "js" or #ext > 10 then
    return nil
  end
  return ext
end

---Save a whiteboard of a meeting, a task, a plan or a project into `assets/boards/`: `<name>.<ending>` (`ink.json`,
---`excalidraw`, or the ending of an external app's file) and, when `preview` names an upload, `<name>.svg` or
---`<name>.png`. A board that is there is replaced only on the version read (`if_match`); without it, or on another
---version, the answer is `conflict` and `suggestion` names a free name (`<name>-2`). The only asset ever replaced.
---@param id string
---@param opts { root?: string, today?: string, name: string, format: string, upload: string, preview?: string, if_match?: string, upload_dir: string, dry_run?: boolean }
---@return { id: string, path: string, asset: string, preview?: string, etag: string, created: boolean, etag_before?: string }|nil
---@return string|nil
---@return table|nil
function M.board_save(id, opts)
  local root, rerr = vault.root(opts)
  if not root then
    return nil, rerr
  end
  local mutate = require("tasks_nvim.mutate")
  local attach_source = require("tasks_nvim.attach_source")
  local name, nerr = mutate.asset_name(opts.name)
  if not name or name:find(".", 1, true) then
    return nil,
      nerr or "name must not have a dot (the ending is the format's)",
      { code = "invalid_argument" }
  end
  if not attach_source.plain_upload_name(opts.upload) then
    return nil, "upload must be a plain file name", { code = "invalid_argument" }
  end
  local ending
  if opts.format == "external" then
    ending = external_ending(opts.upload)
    if not ending then
      return nil,
        "the upload of an external board needs the ending of its app (.xopp, .one, ...)",
        { code = "invalid_argument" }
    end
  else
    ending = M.BOARD_FORMATS[opts.format]
    if not ending then
      return nil, "format must be ink, excalidraw or external", { code = "invalid_argument" }
    end
  end
  local preview_ext
  if opts.preview ~= nil then
    if not attach_source.plain_upload_name(opts.preview) then
      return nil, "preview must be a plain file name", { code = "invalid_argument" }
    end
    preview_ext = (opts.preview:match("%.(%w+)$") or ""):lower()
    if preview_ext ~= "svg" and preview_ext ~= "png" then
      return nil, "preview must be an .svg or a .png", { code = "invalid_argument" }
    end
  end
  local data, derr = read_bytes(opts.upload_dir .. "/" .. opts.upload)
  if not data then
    return nil,
      "the upload is not there or too large: " .. tostring(derr),
      { code = "invalid_argument" }
  end
  local preview_data
  if opts.preview then
    preview_data, derr = read_bytes(opts.upload_dir .. "/" .. opts.preview)
    if not preview_data then
      return nil,
        "the preview is not there or too large: " .. tostring(derr),
        { code = "invalid_argument" }
    end
  end
  -- an occurrence of a series gets its file first (in a dry run it is the file it would get)
  local target, terr
  if opts.dry_run then
    target = M.occurrence_target(id, root)
  else
    local made, merr, minfo = M.materialize(id, { root = root, today = opts.today })
    if made == nil then
      return nil, merr, minfo
    end
  end
  if not target then
    target, terr = mutate.attach_target(id, root)
  end
  if not target then
    return nil, terr, { code = "not_found" }
  end
  local asset = M.BOARDS_DIR .. "/" .. name .. "." .. ending
  local preview_rel = preview_ext and (M.BOARDS_DIR .. "/" .. name .. "." .. preview_ext) or nil
  local etag = fsio.etag(data)
  -- where the board lies: the folder of the target (made in a real run)
  local dir = target.folder and fsio.dirname(target.path) or nil
  local existing = dir and fsio.is_file(dir .. "/" .. asset)
  local function conflict(actual)
    local free = name .. "-2"
    for n = 2, 99 do
      free = name .. "-" .. n
      if not (dir and fsio.is_file(dir .. "/" .. M.BOARDS_DIR .. "/" .. free .. "." .. ending)) then
        break
      end
    end
    return nil,
      ("the board %s of %s is not the version the change was made on"):format(name, target.id),
      {
        code = "conflict",
        id = target.id,
        actual = actual,
        expected = opts.if_match,
        suggestion = free,
      }
  end
  if existing and opts.if_match == nil then
    return conflict(M.board_etag(dir .. "/" .. asset))
  end
  if not existing and opts.if_match ~= nil then
    return nil, ("%s has no board %s to replace"):format(target.id, name), { code = "not_found" }
  end
  local result = {
    id = target.id,
    path = target.path,
    asset = asset,
    preview = preview_rel,
    etag = etag,
    created = not existing,
  }
  if opts.dry_run then
    return result, nil
  end
  if not dir then
    local f, fe = mutate.folderize(target.id, { root = root, index = false })
    if not f then
      return nil, fe
    end
    result.path = f.path
    dir = fsio.dirname(f.path)
  end
  local board_path = dir .. "/" .. asset
  local made, mkerr = fsio.mkdirp(fsio.dirname(board_path))
  if not made then
    return nil, "cannot create the board folder of " .. target.id .. ": " .. tostring(mkerr)
  end
  -- A link in the vault is a way out of it (a vault is shared through git): the replace would write where it points.
  local escape = vault.leaves(root, fsio.dirname(board_path))
  if escape then
    return nil, target.id .. ": the board folder " .. escape, { code = "forbidden" }
  end
  for _, p in ipairs({ board_path, preview_rel and (dir .. "/" .. preview_rel) or nil }) do
    if p and fsio.is_link(p) then
      return nil,
        ("%s: %s is a symbolic link or junction: it is not written through"):format(
          target.id,
          p:sub(#dir + 2)
        ),
        { code = "forbidden" }
    end
  end
  local ok, werr, winfo = fsio.with_lock(board_path, function()
    local fresh = not fsio.is_file(board_path)
    if not fresh then
      local actual = M.board_etag(board_path)
      result.etag_before = actual
      if opts.if_match ~= actual then
        local _, cerr, cinfo = conflict(actual)
        return nil, cerr, cinfo
      end
    elseif opts.if_match ~= nil then
      return nil, ("%s has no board %s to replace"):format(target.id, name), { code = "not_found" }
    end
    local wrote, err = put_bytes(board_path, data, fresh)
    if not wrote then
      if fresh and fsio.is_exists(err) then
        local _, cerr, cinfo = conflict(M.board_etag(board_path))
        return nil, cerr, cinfo
      end
      return nil, "cannot write the board of " .. target.id .. ": " .. tostring(err)
    end
    result.created = fresh
    if preview_data then
      local pwrote, perr = put_bytes(dir .. "/" .. preview_rel, preview_data, false)
      if not pwrote then
        return nil, "cannot write the preview of " .. target.id .. ": " .. tostring(perr)
      end
    end
    return true
  end)
  if not ok then
    return nil, werr, winfo
  end
  fm.update(result.path, { { "updated", opts.today or model.today() } })
  return result, nil
end

return M
