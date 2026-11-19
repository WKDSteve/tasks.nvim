---@module 'tasks_nvim.meetings'
-- @scans-data: the folders it lists and the paths it names are task vaults, never the files of this plugin
---@brief Meeting files: one Markdown file per meeting under `<area>/MEETINGS/`, tied to the tasks it belongs to.
---@description
--- A meeting is not a task: it has no priority, no effort and no readiness, it is never "next", and it does not move to
--- the Backlog when it is done (a meeting is an event with a date; links to it must hold). Its file is
--- `<area>/MEETINGS/<slug>.md`, or `<area>/MEETINGS/<slug>/<slug>.md` once something was attached to it. The id is
--- `<area>/<slug>` and shares the namespace of the area with the tasks, plans and projects.
---
--- The meeting holds the list of its tasks (`tasks:`); which meetings a task has is derived (`by_task`), as a project
--- does not list its plans: two machines never collide on a list in a task file.
---
--- Frontmatter (flat YAML): `title`, `status` (`planned`, `done`, `cancelled`), `date`, `time` (the beginning, `HH:MM`;
--- none: all day), `end` (`HH:MM`) or `duration` (`45m`, `2h`, `1h30m`), `tz` (an IANA zone, only checked for its
--- form: the clients convert), `location`, `online` (an http(s) address; the service is told from its host),
--- `tasks`, `notify` (`-15m`, `-2h`, `-1d@18:00`), `notify_to`, `image`, `icon`, `tags`, `recording`, `summary`,
--- `created`, `updated`.
---
--- The body is prose with a few sections the engine reads: `## Agenda` (checkboxes), `## Teilnehmer` /
--- `## Participants` (`- [ ] Name <mail> (role)`, ticked = present), `## Unterlagen` / `## Documents` (links, paths),
--- `## Protokoll` / `## Minutes`, `## Beschlüsse` / `## Decisions`, `## Folgeaufgaben` / `## Follow-ups` (checkboxes,
--- `-> <id>` names the task made of the line) and `## Ergebnis` / `## Result`.
---
--- Not its job: writing (`ops`), the rule check across files (`check`), the documents (`contract`).

local fm = require("lib.nvim.markdown.frontmatter")
local fsio = require("tasks_nvim.fsio")
local model = require("tasks_nvim.model")
local vault = require("tasks_nvim.vault")

local M = {}

---The statuses of a meeting. `done` may be set at any time, with or without a result (decision F4).
---@type string[]
M.STATUSES = { "planned", "done", "cancelled" }

---The services the host of `online` is told as; `link` for any other address.
---@type string[]
M.SERVICES = { "teams", "zoom", "meet", "webex", "jitsi", "link" }

---The icons a meeting may name instead of an image (`icon:`); a front end draws its own sign for each.
---@type string[]
M.ICONS = {
  "call",
  "coffee",
  "handshake",
  "idea",
  "meeting",
  "people",
  "phone",
  "planning",
  "presentation",
  "review",
  "video",
  "workshop",
}

---The most entries of `notify`, `notify_to` and `tasks`.
M.MAX_NOTIFY = 5
M.MAX_TASKS = 50

---The longest meeting, in minutes (a workshop of several days is one meeting).
M.MAX_DURATION_MIN = 7 * 24 * 60

---The most days a `-<n>d@HH:MM` notification lies before the meeting.
M.MAX_NOTIFY_DAYS = 30

---The headings of the sections the engine reads, German and English.
local HEADINGS = {
  agenda = { "## Agenda" },
  participants = { "## Teilnehmer", "## Participants" },
  documents = { "## Unterlagen", "## Documents" },
  protocol = { "## Protokoll", "## Minutes" },
  decisions = { "## Beschlüsse", "## Decisions" },
  followups = { "## Folgeaufgaben", "## Follow-ups" },
  result = { "## Ergebnis", "## Result" },
}
M.HEADINGS = HEADINGS

---Hosts of the services (exact host, or a suffix after a dot).
local SERVICE_HOSTS = {
  { service = "teams", exact = { "teams.microsoft.com", "teams.live.com" } },
  { service = "zoom", exact = { "zoom.us" }, suffix = { "zoom.us" } },
  { service = "meet", exact = { "meet.google.com" } },
  { service = "webex", exact = { "webex.com" }, suffix = { "webex.com" } },
  { service = "jitsi", exact = { "meet.jit.si" } },
}

---@param s string
---@return string
local function trim(s)
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

---The service of a meeting address: told from its host (lower case, without user and port); `link` for any other
---host; nil for text that is no http(s) address.
---@param url any
---@return string|nil
function M.online_service(url)
  if not model.is_web_link(url) then
    return nil
  end
  local host = url:match("^[Hh][Tt][Tt][Pp][Ss]?://([^/?#]+)")
  host = (host:gsub("^.*@", ""):gsub(":%d*$", "")):lower()
  for _, entry in ipairs(SERVICE_HOSTS) do
    for _, h in ipairs(entry.exact or {}) do
      if host == h then
        return entry.service
      end
    end
    for _, h in ipairs(entry.suffix or {}) do
      if host:sub(-(#h + 1)) == "." .. h then
        return entry.service
      end
    end
  end
  return "link"
end

---Minutes of a duration: `45m`, `2h`, `1h30m` (1 up to `MAX_DURATION_MIN`); nil for anything else.
---@param s any
---@return integer|nil
function M.parse_duration(s)
  if type(s) ~= "string" then
    return nil
  end
  local h, m = s:match("^(%d+)h(%d+)m$")
  local minutes
  if h then
    minutes = tonumber(h) * 60 + tonumber(m)
  elseif s:match("^%d+h$") then
    minutes = tonumber(s:sub(1, -2)) * 60
  elseif s:match("^%d+m$") then
    minutes = tonumber(s:sub(1, -2))
  end
  if not minutes or minutes < 1 or minutes > M.MAX_DURATION_MIN then
    return nil
  end
  return math.floor(minutes)
end

---@class Tasks.MeetingNotify
---@field spec string           # As written, normalised (`-15m`, `-1d@18:00`).
---@field before_min? integer   # Minutes before the beginning.
---@field days_before? integer  # Days before the day of the meeting ...
---@field at? string            # ... at this time of day.

---One entry of `notify`: `-<n>m`, `-<n>h` (before the beginning, at most 30 days) or `-<n>d@HH:MM` (on the day `n` days
---before, at that time; `-0d@08:00` is the day itself). Nil for anything else.
---@param s any
---@return Tasks.MeetingNotify|nil
function M.parse_notify(s)
  if type(s) ~= "string" then
    return nil
  end
  s = trim(s):lower()
  local n, unit = s:match("^%-(%d+)([mh])$")
  if n then
    local minutes = tonumber(n) * (unit == "h" and 60 or 1)
    if minutes < 1 or minutes > M.MAX_NOTIFY_DAYS * 24 * 60 then
      return nil
    end
    return { spec = "-" .. tonumber(n) .. unit, before_min = math.floor(minutes) }
  end
  local d, at = s:match("^%-(%d+)d@(%d%d:%d%d)$")
  if d and model.is_time(at) and tonumber(d) <= M.MAX_NOTIFY_DAYS then
    return {
      spec = ("-%dd@%s"):format(tonumber(d), at),
      days_before = math.floor(tonumber(d)),
      at = at,
    }
  end
  return nil
end

---Whether `s` has the form of an IANA time zone (`Europe/Vienna`, `America/Argentina/Buenos_Aires`, `UTC`). Only the
---form: which zones exist is for the hub and the clients to say (decision F5).
---@param s any
---@return boolean
function M.is_tz(s)
  if type(s) ~= "string" or #s > 64 then
    return false
  end
  if s == "UTC" then
    return true
  end
  return s:match("^%u[%a_]*/[%a_][%w_%+%-]*$") ~= nil
    or s:match("^%u[%a_]*/[%a_][%w_%+%-]*/[%a_][%w_%+%-]*$") ~= nil
end

---Minutes since midnight of `HH:MM`.
---@param t string
---@return integer
local function minutes_of(t)
  local h, m = t:match("^(%d%d):(%d%d)$")
  return tonumber(h) * 60 + tonumber(m)
end

---`HH:MM` of minutes since midnight (0..1439).
---@param n integer
---@return string
local function clock(n)
  return ("%02d:%02d"):format(math.floor(n / 60), n % 60)
end

---The section of the first heading of `names` the body has: its lines (without the heading), or nil.
---@param lines string[]
---@param names string[]
---@return string[]|nil
local function section_lines(lines, names)
  local want = {}
  for _, n in ipairs(names) do
    want[n] = true
  end
  local out, inside, fence = nil, false, false
  for _, line in ipairs(lines) do
    if inside then
      if not fence and line:match("^## ") then
        break
      end
      if line:match("^%s*```") or line:match("^%s*~~~") then
        fence = not fence
      end
      out[#out + 1] = line
    elseif want[trim(line)] then
      inside, out = true, {}
    end
  end
  return out
end

---The visible text of a section: HTML comments (the placeholders of a template) and the blank lines at both ends taken
---away.
---@param lines string[]|nil
---@return string
local function visible(lines)
  if not lines then
    return ""
  end
  local text = table.concat(lines, "\n"):gsub("<!%-%-.-%-%->", "")
  return trim(text)
end

---A checkbox line: `- [ ] text`, `* [x] text`; nil for any other line.
---@param line string
---@return boolean|nil ticked
---@return string|nil text
local function checkbox(line)
  local mark, text = line:match("^%s*[-*+] %[([ xX])%]%s+(.-)%s*$")
  if not mark then
    return nil, nil
  end
  return mark ~= " ", text
end

---A list line without a checkbox: `- text`.
---@param line string
---@return string|nil
local function bullet(line)
  -- a checkbox is no plain list line; a Markdown link (`- [text](target)`) is
  if line:match("^%s*[-*+] %[[ xX]%]") then
    return nil
  end
  local text = line:match("^%s*[-*+]%s+(.-)%s*$")
  return text ~= "" and text or nil
end

---@class Tasks.MeetingParticipant
---@field n integer
---@field name string
---@field email? string
---@field role? string
---@field present boolean

---The participants: one line each, `Name <mail> (role)`; mail and role are optional. A checkbox ticked is present; a
---plain list line is a participant whose presence was not noted.
---@param lines string[]|nil
---@return Tasks.MeetingParticipant[]
local function participants_of(lines)
  local out = {}
  for _, line in ipairs(lines or {}) do
    local ticked, text = checkbox(line)
    if not text then
      text = bullet(line)
    end
    if text then
      local role = text:match("%(([^()]*)%)%s*$")
      if role then
        text = text:gsub("%s*%([^()]*%)%s*$", "")
      end
      local email = text:match("<([^<>]+)>")
      if email then
        text = text:gsub("%s*<[^<>]+>%s*", " ")
      end
      local name = trim(fsio.clean(text))
      if name ~= "" then
        out[#out + 1] = {
          n = #out + 1,
          name = name,
          email = model.is_email(email) and email or nil,
          role = role and trim(role) ~= "" and trim(fsio.clean(role)) or nil,
          present = ticked == true,
        }
      end
    end
  end
  return out
end

---@class Tasks.MeetingItem
---@field n integer
---@field text string
---@field ticked boolean
---@field task? string   # Follow-ups only: the id of the task made of the line (`-> <id>`).

---The checkbox items of a section (agenda, follow-ups); `with_task` reads a trailing `-> <area>/<slug>` (or the arrow
---character) as the task made of the line.
---@param lines string[]|nil
---@param with_task boolean
---@return Tasks.MeetingItem[]
local function items_of(lines, with_task)
  local out = {}
  for _, line in ipairs(lines or {}) do
    local ticked, text = checkbox(line)
    if text then
      local item = { n = #out + 1, text = fsio.clean(text), ticked = ticked == true }
      if with_task then
        local arrow = string.char(0xE2, 0x86, 0x92)
        local head, id = text:match("^(.-)%s*%->%s*(%S+)$")
        if not head then
          head, id = text:match("^(.-)%s*" .. arrow .. "%s*(%S+)$")
        end
        if id and vault.parse_id(id) then
          item.text, item.task = fsio.clean(head), id
        end
      end
      out[#out + 1] = item
    end
  end
  return out
end

---@class Tasks.MeetingDocument
---@field n integer
---@field text string
---@field kind "web"|"asset"|"path"|"text"
---@field href? string   # The address or the path relative to the meeting folder; an absolute path is never named.

---The documents: one list line each, a Markdown link `[text](target)`, a bare address or a path.
---@param lines string[]|nil
---@return Tasks.MeetingDocument[]
local function documents_of(lines)
  local out = {}
  for _, line in ipairs(lines or {}) do
    local text = bullet(line)
    if text then
      local label, target = text:match("^%[(.-)%]%((.-)%)$")
      target = target or text
      label = label or text
      local doc = { n = #out + 1, text = fsio.clean(label) }
      if model.is_web_link(target) then
        doc.kind, doc.href = "web", target
      elseif target:match("^assets/[^%s]+$") and not target:find("..", 1, true) then
        doc.kind, doc.href = "asset", target
      elseif target:match("^/") or target:match("^%a:[/\\]") or target:match("^[/\\][/\\]") then
        -- a path of some machine: shown as its name only (no document names a path of this machine)
        doc.kind = "path"
        doc.text = label ~= target and doc.text or ("<external>/" .. vim.fs.basename(target))
      else
        doc.kind = "text"
      end
      out[#out + 1] = doc
    end
  end
  return out
end

---@class Tasks.Meeting
---@field id string
---@field area string
---@field slug string
---@field path string
---@field folder boolean
---@field title string
---@field status? string
---@field date? string
---@field time? string
---@field end_time? string        # `end` as written (`HH:MM`).
---@field duration_min? integer   # From `duration`, or from `time` and `end`.
---@field all_day boolean
---@field start? string           # `YYYY-MM-DDTHH:MM`, or the date of an all-day meeting.
---@field ends? string            # The end in the same form (an all-day meeting: its last day).
---@field tz? string
---@field location? string
---@field online? string
---@field online_service? string
---@field tasks string[]
---@field notify Tasks.MeetingNotify[]
---@field notify_to string[]
---@field image? string
---@field icon? string
---@field tags string[]
---@field recording? string
---@field created? string
---@field updated? string
---@field summary string
---@field body string
---@field agenda Tasks.MeetingItem[]
---@field participants Tasks.MeetingParticipant[]
---@field documents Tasks.MeetingDocument[]
---@field followups Tasks.MeetingItem[]
---@field has_result boolean
---@field has_decisions boolean
---@field has_protocol boolean
---@field errors string[]
---@field error_codes string[]
---@field valid boolean
---@field etag? string

---Read one meeting file's text. Always returns a meeting; a broken file carries `errors` (`valid = false`). What
---needs other files (a task that does not exist, an image that is missing, two meetings at the same time) is not
---judged here but by `check`.
---@param text string
---@param ctx { path: string, area: string, slug?: string, folder?: boolean }
---@return Tasks.Meeting
function M.parse(text, ctx)
  local slug = ctx.slug or vim.fs.basename(ctx.path):gsub("%.md$", "")
  local errors, codes = {}, {}
  local function bad(code, msg)
    errors[#errors + 1] = msg
    codes[#codes + 1] = code
  end
  ---@type Tasks.Meeting
  local m = {
    id = ctx.area .. "/" .. slug,
    area = ctx.area,
    slug = slug,
    path = fsio.norm(ctx.path),
    folder = ctx.folder == true,
    title = slug,
    all_day = true,
    tasks = {},
    notify = {},
    notify_to = {},
    tags = {},
    summary = "",
    body = "",
    agenda = {},
    participants = {},
    documents = {},
    followups = {},
    has_result = false,
    has_decisions = false,
    has_protocol = false,
    errors = errors,
    error_codes = codes,
    valid = false,
  }
  if not vault.valid_slug(slug) then
    bad("slug", "filename is not a kebab-case ASCII slug: " .. fsio.clean(slug))
  end
  local parsed, perr = fm.parse(text)
  if not parsed then
    bad("frontmatter-missing", "frontmatter unreadable: " .. tostring(perr))
    return m
  elseif not parsed.has_block then
    bad("frontmatter-missing", "no frontmatter block")
    return m
  end
  local meta = parsed.meta
  m.title = model.field_text(meta.title, "title", bad) or slug
  if meta.title == nil then
    bad("title-missing", "title is missing")
  end

  local status = model.field_text(meta.status, "status", bad)
  if not status then
    bad("meeting-bad-status", "status is missing")
  elseif not vim.tbl_contains(M.STATUSES, status) then
    bad(
      "meeting-bad-status",
      ("unknown meeting status '%s' (expected %s)"):format(status, table.concat(M.STATUSES, ", "))
    )
  else
    m.status = status
  end

  local date = model.field_text(meta.date, "date", bad)
  if not date then
    bad("meeting-bad-date", "date is missing")
  elseif not model.is_date(date) then
    bad("meeting-bad-date", "date is no calendar day (YYYY-MM-DD): " .. date)
  else
    m.date = date
  end

  local time = model.field_text(meta.time, "time", bad)
  if time and not model.is_time(time) then
    bad("meeting-bad-time", "time is no time of day (HH:MM): " .. time)
    time = nil
  end
  m.time = time
  m.all_day = time == nil

  local end_text = model.field_text(meta["end"], "end", bad)
  local duration_text = model.field_text(meta.duration, "duration", bad)
  if end_text and duration_text then
    bad("meeting-end-and-duration", "end and duration are both set: keep one of them")
  end
  if end_text then
    if not model.is_time(end_text) then
      bad("meeting-bad-time", "end is no time of day (HH:MM): " .. end_text)
    elseif not time then
      bad("meeting-end-without-time", "end needs time (the beginning)")
    elseif minutes_of(end_text) <= minutes_of(time) then
      bad(
        "meeting-end-before-start",
        ("end %s is not after the beginning %s (past midnight: use duration)"):format(
          end_text,
          time
        )
      )
    else
      m.end_time = end_text
      if not duration_text then
        m.duration_min = minutes_of(end_text) - minutes_of(time)
      end
    end
  end
  if duration_text then
    local minutes = M.parse_duration(duration_text)
    if not minutes then
      bad(
        "meeting-bad-duration",
        ("duration '%s' is none (45m, 2h, 1h30m; at most 7 days)"):format(duration_text)
      )
    elseif not end_text then
      m.duration_min = minutes
    end
  end

  -- where the meeting begins and ends, in one form a reader compares as text
  if m.date then
    if m.time then
      m.start = m.date .. "T" .. m.time
      local total = minutes_of(m.time) + (m.duration_min or 0)
      m.ends = model.add_days(m.date, math.floor(total / 1440)) .. "T" .. clock(total % 1440)
    else
      m.start = m.date
      -- an all-day meeting of several days: a duration in whole days counts its days
      local days = m.duration_min and math.max(1, math.ceil(m.duration_min / 1440)) or 1
      m.ends = model.add_days(m.date, days - 1)
    end
  end

  local tz = model.field_text(meta.tz, "tz", bad)
  if tz and not M.is_tz(tz) then
    bad("meeting-bad-tz", "tz has not the form of a time zone (Europe/Vienna, UTC): " .. tz)
  elseif tz then
    m.tz = tz
  end

  m.location = model.field_text(meta.location, "location", bad)
  local online = model.field_text(meta.online, "online", bad)
  if online and not model.is_web_link(online) then
    bad("meeting-bad-online", "online is no http(s) address: " .. online)
  elseif online then
    m.online, m.online_service = online, M.online_service(online)
  end
  local recording = model.field_text(meta.recording, "recording", bad)
  if recording and not model.is_web_link(recording) then
    bad("meeting-bad-recording", "recording is no http(s) address: " .. recording)
  else
    m.recording = recording
  end

  for _, id in ipairs(model.field_list(meta.tasks, "tasks", bad)) do
    local area, task_slug = vault.parse_id(id)
    if not area or not task_slug then
      bad("meeting-bad-task", "tasks: not an id <area>/<slug>: " .. id)
    elseif not vim.tbl_contains(m.tasks, id) then
      m.tasks[#m.tasks + 1] = id
    end
  end
  if #m.tasks > M.MAX_TASKS then
    bad("meeting-bad-task", ("tasks: at most %d"):format(M.MAX_TASKS))
    m.tasks = vim.list_slice(m.tasks, 1, M.MAX_TASKS)
  end

  for _, spec in ipairs(model.field_list(meta.notify, "notify", bad)) do
    local n = M.parse_notify(spec)
    if not n then
      bad(
        "meeting-bad-notify",
        ("notify '%s' is none (-15m, -2h, -1d@18:00; at most 30 days)"):format(spec)
      )
    elseif #m.notify < M.MAX_NOTIFY then
      m.notify[#m.notify + 1] = n
    else
      bad("meeting-bad-notify", ("notify: at most %d entries"):format(M.MAX_NOTIFY))
    end
  end
  for _, addr in ipairs(model.field_list(meta.notify_to, "notify_to", bad)) do
    if not model.is_email(addr) then
      bad("meeting-bad-notify-to", "notify_to: not an e-mail address: " .. addr)
    elseif #m.notify_to < model.MAX_REMIND_TO then
      m.notify_to[#m.notify_to + 1] = addr
    end
  end

  local image = model.field_text(meta.image, "image", bad)
  if image then
    if image:find("..", 1, true) or not image:match("^assets/[^%s\\]+$") then
      bad("meeting-bad-image", "image must be a file below assets/ of the meeting: " .. image)
    else
      m.image = image
    end
  end
  local icon = model.field_text(meta.icon, "icon", bad)
  if icon and not vim.tbl_contains(M.ICONS, icon) then
    bad(
      "meeting-bad-icon",
      ("unknown icon '%s' (expected %s)"):format(icon, table.concat(M.ICONS, ", "))
    )
  else
    m.icon = icon
  end

  m.tags = model.field_list(meta.tags, "tags", bad)
  local created = model.field_text(meta.created, "created", bad)
  m.created = model.is_date(created) and created or nil
  local updated = model.field_text(meta.updated, "updated", bad)
  m.updated = model.is_date(updated) and updated or nil

  local body = parsed.body or ""
  m.body = body
  m.summary = model.field_text(meta.summary, "summary", bad) or model.first_paragraph(body)
  local lines = vim.split((body:gsub("\r\n", "\n")), "\n", { plain = true })
  m.agenda = items_of(section_lines(lines, HEADINGS.agenda), false)
  m.participants = participants_of(section_lines(lines, HEADINGS.participants))
  m.documents = documents_of(section_lines(lines, HEADINGS.documents))
  m.followups = items_of(section_lines(lines, HEADINGS.followups), true)
  m.has_result = visible(section_lines(lines, HEADINGS.result)) ~= ""
  m.has_decisions = visible(section_lines(lines, HEADINGS.decisions)) ~= ""
  m.has_protocol = visible(section_lines(lines, HEADINGS.protocol)) ~= ""

  m.valid = #errors == 0
  return m
end

---Parsed files by path (mtime, size, form): an unchanged meeting is a stat, not a read.
---@type table<string, { sec: integer, nsec: integer, size: integer, key: string, meeting: Tasks.Meeting }>
local parsed_files = {}
local parsed_count = 0
local PARSED_MAX = 2000
---A file this young may still change without its mtime moving (FAT: 2 s): never trusted from the cache.
local RACY_SECONDS = 2

---Forget every parsed meeting.
function M.reset_cache()
  parsed_files, parsed_count = {}, 0
end

---Read one meeting file from disk. An unreadable file or a link yields an invalid meeting, never a raise.
---@param path string
---@param ctx { area: string, slug?: string, folder?: boolean }
---@return Tasks.Meeting
function M.from_file(path, ctx)
  local uv = vim.uv or vim.loop
  local full = vim.tbl_extend("force", { path = path }, ctx)
  local key = table.concat({ ctx.area, ctx.slug or "", ctx.folder and "f" or "-" }, "\0")
  local st = uv.fs_lstat(path)
  if st and st.type == "link" then
    local m = M.parse("", full)
    m.errors = {
      "the meeting file is a symbolic link or junction; it is not read (the vault must not point outside itself)",
    }
    m.error_codes = { "symlink-task" }
    m.valid = false
    return m
  end
  local mtime = st and st.mtime
  if st and mtime and st.type == "file" then
    local hit = parsed_files[path]
    if
      hit
      and hit.sec == mtime.sec
      and hit.nsec == mtime.nsec
      and hit.size == st.size
      and hit.key == key
    then
      return vim.deepcopy(hit.meeting)
    end
  end
  local text, err = fsio.read(path)
  if not text then
    local m = M.parse("", full)
    m.errors = { "cannot read file: " .. tostring(err) }
    m.error_codes = { "unreadable" }
    m.valid = false
    return m
  end
  local m = M.parse(text, full)
  m.etag = fsio.etag(text)
  if st and mtime and st.type == "file" and mtime.sec < os.time() - RACY_SECONDS then
    if parsed_files[path] == nil then
      if parsed_count >= PARSED_MAX then
        parsed_files, parsed_count = {}, 0
      end
      parsed_count = parsed_count + 1
    end
    parsed_files[path] =
      { sec = mtime.sec, nsec = mtime.nsec, size = st.size, key = key, meeting = vim.deepcopy(m) }
  end
  return m
end

---The meeting files of an area, by slug.
---@param area string
---@param opts? { root?: string }
---@return Tasks.Meeting[]|nil meetings
---@return string[]|string|nil errors
function M.area(area, opts)
  opts = opts or {}
  local root, err = vault.root(opts)
  if not root then
    return nil, err
  end
  if not vault.valid_area(area) then
    return nil, "invalid area name: " .. tostring(area)
  end
  local dir = vault.meetings_dir(root, area)
  local out = {}
  if not fsio.is_dir(dir) then
    return out, {}
  end
  local escape = vault.leaves(root, dir)
  if escape then
    return out, { escape }
  end
  for _, e in ipairs(vault.plan_files(dir)) do
    out[#out + 1] = M.from_file(e.path, { area = area, slug = e.slug, folder = e.folder })
  end
  return out, {}
end

---Every meeting of the vault, areas in name order, and the folders that could not be read.
---@param opts? { root?: string }
---@return Tasks.Meeting[]|nil meetings
---@return string[]|string|nil errors
function M.all(opts)
  opts = opts or {}
  local root, err = vault.root(opts)
  if not root then
    return nil, err
  end
  local out, errors = {}, {}
  for _, a in ipairs(vault.areas(root)) do
    local list, errs = M.area(a.name, { root = root })
    vim.list_extend(out, list or {})
    for _, e in ipairs(type(errs) == "table" and errs or {}) do
      errors[#errors + 1] = e
    end
  end
  return out, errors
end

---A meeting by id.
---@param id string
---@param opts? { root?: string }
---@return Tasks.Meeting|nil meeting
---@return string|nil err
function M.find(id, opts)
  opts = opts or {}
  local root, err = vault.root(opts)
  if not root then
    return nil, err
  end
  local area, slug, id_err = vault.parse_id(id)
  if not area or not slug then
    return nil, id_err or ("expected <area>/<slug>, got " .. tostring(id))
  end
  if not vault.has_area(root, area) then
    return nil, "no such meeting: " .. id
  end
  local escape = vault.leaves(root, vault.meetings_dir(root, area))
  if escape then
    return nil, "no such meeting: " .. id
  end
  local path, folder = vault.resolve_meeting(root, area, slug)
  if not path then
    return nil, folder --[[@as string]]
  end
  return M.from_file(path, { area = area, slug = slug, folder = folder == true }), nil
end

---Order of meetings: the earlier first (a meeting without a valid date last), then by id.
---@param a Tasks.Meeting
---@param b Tasks.Meeting
---@return boolean
function M.less(a, b)
  local sa, sb = a.start or "~", b.start or "~"
  if sa ~= sb then
    return sa < sb
  end
  return a.id < b.id
end

---Task id -> the ids of the meetings that name it (`tasks:`), the earliest first.
---@param meetings Tasks.Meeting[]
---@return table<string, string[]>
function M.by_task(meetings)
  local sorted = vim.list_slice(meetings, 1)
  table.sort(sorted, M.less)
  local out = {}
  for _, m in ipairs(sorted) do
    for _, id in ipairs(m.tasks) do
      out[id] = out[id] or {}
      table.insert(out[id], m.id)
    end
  end
  return out
end

return M
