---@module 'tasks_nvim.history'
---@brief The series of the overview figures: one row per day and area below `<vault>/_Telemetry/history/`.
---@description
--- The engine only knows the vault as it is now. How many tasks were ready three weeks ago cannot be worked out later
--- (readiness hangs on the blockers of that day), so the figures are written down when they change and read back as a
--- series (`tasks.history` of the contract).
---
--- Where: `<vault>/_Telemetry/history/YYYY-MM.jsonl`, one JSON object per line, in the vault so that every machine and
--- the web variant read the same series. `_Telemetry` is no area (it has neither `ROADMAP` nor `Backlog`).
---
--- A row holds the figures of ONE area on ONE day, absolute (never a difference), so a row that is missing costs a
--- step in the curve and nothing else:
---   `{ v, day, area, at, open, status{}, state{}, with_effort, with_value, days, value, src? }`
--- `status` counts by `status:`, `state` by readiness (`ready`, `decision`, `waiting`, `stuck`, `freed`, `parked`: the
--- figures of the plan head, so a tile and its curve mean the same number); zero counts are left out. `days` is the
--- sum of the written efforts, `value` the sum of the written values. `src` is `git` for a row that was filled in
--- from the history of the repository (`tasks_nvim.history_backfill`).
---
--- Rules:
---  - a row is written only when the figures of its area changed since the last row, and at most one row per day and
---    area is kept by the writer (a second run on the same day replaces the row of that day);
---  - two machines that both wrote the same day merge without a conflict when the files are merged with
---    `merge=union` (`.gitattributes`): both rows stay, and the reader takes the one with the later `at`;
---  - a line that is no valid row is reported (`<file>:<line>: <why>`) and skipped, by the reader, so no method that
---    asks for the series has to check it again; the writer keeps such a line as it is;
---  - no path of this machine: a row names an area, a problem a file relative to the vault.
---
--- Not its job: building the view the figures are counted from (the caller hands it in), the document
--- (`contract.history`), the filling from git (`history_backfill`).
-- @scans-data

local fsio = require("tasks_nvim.fsio")
local json = require("lib.nvim.json.canonical")
local model = require("tasks_nvim.model")
local vault = require("tasks_nvim.vault")

local uv = vim.uv or vim.loop

local M = {}

---The folder of the series, relative to the vault.
M.DIR = "_Telemetry/history"

---The version of a row.
M.ROW_VERSION = 1

---The readiness states a row counts (those of the plan head).
---@type string[]
M.STATES = { "ready", "decision", "waiting", "stuck", "freed", "parked" }

---Longest line the reader takes for a row (a row of every status and state is below 400 bytes).
M.MAX_LINE = 2048

---The most problems one reading names; the rest is counted in a last entry.
M.MAX_PROBLEMS = 20

---The biggest count or sum a row may hold: beyond it a document could not write the number.
local MAX_NUMBER = 1e9

---@class Tasks.HistoryFigures
---@field open integer
---@field status table<string, integer>   # by `status:`, every open status
---@field state table<string, integer>    # by readiness, every state of `M.STATES`
---@field with_effort integer
---@field with_value integer
---@field days number                     # sum of the written efforts
---@field value integer                   # sum of the written values

---@class Tasks.HistoryRow : Tasks.HistoryFigures
---@field day string     # `YYYY-MM-DD`
---@field area string
---@field at string      # UTC, `YYYY-MM-DDTHH:MM:SSZ`: when the row was written
---@field src? string    # `git` for a row filled in from the repository

local STATUS_SET, STATE_SET = {}, {}
for _, s in ipairs(model.OPEN_STATUSES) do
  STATUS_SET[s] = true
end
for _, s in ipairs(M.STATES) do
  STATE_SET[s] = true
end

---@return Tasks.HistoryFigures
local function empty()
  local f =
    { open = 0, status = {}, state = {}, with_effort = 0, with_value = 0, days = 0, value = 0 }
  for _, s in ipairs(model.OPEN_STATUSES) do
    f.status[s] = 0
  end
  for _, s in ipairs(M.STATES) do
    f.state[s] = 0
  end
  return f
end

M.empty = empty

---@param n number
---@return number
local function round2(n)
  return math.floor(n * 100 + 0.5) / 100
end

---`a + b`, in place.
---@param a Tasks.HistoryFigures
---@param b Tasks.HistoryFigures
local function add(a, b)
  a.open = a.open + b.open
  a.with_effort = a.with_effort + b.with_effort
  a.with_value = a.with_value + b.with_value
  a.days = a.days + b.days
  a.value = a.value + b.value
  for k, n in pairs(b.status) do
    a.status[k] = (a.status[k] or 0) + n
  end
  for k, n in pairs(b.state) do
    a.state[k] = (a.state[k] or 0) + n
  end
end

---Whether every figure is zero.
---@param f Tasks.HistoryFigures
---@return boolean
local function is_zero(f)
  return f.open == 0 and f.with_effort == 0 and f.with_value == 0 and f.days == 0 and f.value == 0
end

---@param f Tasks.HistoryFigures
---@param g Tasks.HistoryFigures
---@return boolean
local function same(f, g)
  if
    f.open ~= g.open
    or f.with_effort ~= g.with_effort
    or f.with_value ~= g.with_value
    or f.days ~= g.days
    or f.value ~= g.value
  then
    return false
  end
  for _, s in ipairs(model.OPEN_STATUSES) do
    if (f.status[s] or 0) ~= (g.status[s] or 0) then
      return false
    end
  end
  for _, s in ipairs(M.STATES) do
    if (f.state[s] or 0) ~= (g.state[s] or 0) then
      return false
    end
  end
  return true
end

M.same = same

---The figures of every area of a view: the areas of the vault (an area without an open task has zeros) and the area
---of every open task.
---@param view Tasks.ContractView
---@return table<string, Tasks.HistoryFigures>
function M.figures(view)
  local by = {}
  for _, a in ipairs(vault.areas(view.root)) do
    by[a.name] = empty()
  end
  for _, t in ipairs(view.open) do
    local f = by[t.area]
    if not f then
      f = empty()
      by[t.area] = f
    end
    f.open = f.open + 1
    if STATUS_SET[t.status] then
      f.status[t.status] = f.status[t.status] + 1
    end
    local node = view.plan.nodes[t.id]
    if node and STATE_SET[node.state] then
      f.state[node.state] = f.state[node.state] + 1
    end
    local days = model.effort_days(t.effort)
    if days then
      f.with_effort = f.with_effort + 1
      f.days = f.days + days
    end
    if t.value then
      f.with_value = f.with_value + 1
      f.value = f.value + t.value
    end
  end
  for _, f in pairs(by) do
    f.days = round2(f.days)
  end
  return by
end

-- ── rows ─────────────────────────────────────────────────────────────────────

---A count of a row: a whole number from 0 up to the limit.
---@param v any
---@return boolean
local function is_count(v)
  return type(v) == "number" and v == v and v >= 0 and v <= MAX_NUMBER and v == math.floor(v)
end

---The counts of `raw` by the words of `set`; nil and why when it holds another word or no count.
---@param raw any
---@param set table<string, true>
---@param name string
---@return table<string, integer>|nil counts
---@return string|nil why
local function counts(raw, set, name)
  local out = {}
  for word in pairs(set) do
    out[word] = 0
  end
  if raw == nil then
    return out
  end
  if type(raw) ~= "table" then
    return nil, name .. " is no object"
  end
  for word, n in pairs(raw) do
    if not set[word] then
      return nil, ("%s names an unknown word"):format(name)
    end
    if not is_count(n) then
      return nil, ("%s.%s is no count"):format(name, word)
    end
    out[word] = n
  end
  return out
end

---One line of a file as a row; nil and why when it is none. The one place that judges a row: what passes here can
---be summed and written into a document.
---@param line string
---@return Tasks.HistoryRow|nil row
---@return string|nil why
function M.parse_row(line)
  if #line > M.MAX_LINE then
    return nil, "line too long"
  end
  local ok, raw = pcall(vim.json.decode, line, { luanil = { object = true, array = true } })
  if not ok or type(raw) ~= "table" or vim.islist(raw) and next(raw) ~= nil then
    return nil, "no JSON object"
  end
  if raw.v ~= M.ROW_VERSION then
    return nil, "unknown row version"
  end
  if not model.is_date(raw.day) then
    return nil, "day is no date"
  end
  if not vault.valid_area(raw.area) or #raw.area > 200 then
    return nil, "area is no area name"
  end
  if type(raw.at) ~= "string" or not raw.at:match("^%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%dZ$") then
    return nil, "at is no UTC time"
  end
  for _, key in ipairs({ "open", "with_effort", "with_value", "value" }) do
    if not is_count(raw[key]) then
      return nil, key .. " is no count"
    end
  end
  if
    type(raw.days) ~= "number"
    or raw.days ~= raw.days
    or raw.days < 0
    or raw.days > MAX_NUMBER
  then
    return nil, "days is no sum of days"
  end
  local status, serr = counts(raw.status, STATUS_SET, "status")
  if not status then
    return nil, serr
  end
  local state, terr = counts(raw.state, STATE_SET, "state")
  if not state then
    return nil, terr
  end
  if raw.src ~= nil and raw.src ~= "git" then
    return nil, "unknown src"
  end
  return {
    day = raw.day,
    area = raw.area,
    at = raw.at,
    src = raw.src,
    open = raw.open,
    status = status,
    state = state,
    with_effort = raw.with_effort,
    with_value = raw.with_value,
    days = round2(raw.days),
    value = raw.value,
  }
end

---The line of a row: canonical JSON (sorted keys), zero counts of `status` and `state` left out.
---@param row Tasks.HistoryRow
---@return string
function M.encode_row(row)
  local function nonzero(t)
    local out = {}
    for k, n in pairs(t) do
      if n ~= 0 then
        out[k] = n
      end
    end
    return json.object(out)
  end
  return json.encode(json.object({
    v = M.ROW_VERSION,
    day = row.day,
    area = row.area,
    at = row.at,
    src = row.src,
    open = row.open,
    status = nonzero(row.status),
    state = nonzero(row.state),
    with_effort = row.with_effort,
    with_value = row.with_value,
    days = round2(row.days),
    value = row.value,
  }))
end

---The folder of the series.
---@param root string
---@return string
function M.dir(root)
  return root .. "/" .. M.DIR
end

---The file of a month.
---@param root string
---@param day string  # a day of that month
---@return string
function M.file_of(root, day)
  return ("%s/%s.jsonl"):format(M.dir(root), day:sub(1, 7))
end

---Whether the vault keeps a series (the folder is there). `tasks index` only adds to a series that exists.
---@param root string
---@return boolean
function M.exists(root)
  return fsio.is_dir(M.dir(root))
end

---The month files of the series, oldest first; nil and why when the folder leads out of the vault.
---@param root string
---@return string[]|nil names
---@return string|nil why
local function month_files(root)
  local dir = M.dir(root)
  -- a link (a symbolic link, a junction) is a way out of the vault: what it points at is not the vault's
  if fsio.is_link(root .. "/_Telemetry") or fsio.is_link(dir) then
    return nil, M.DIR .. " is a link"
  end
  local names = {}
  local handle = uv.fs_scandir(dir)
  if not handle then
    return names
  end
  while true do
    local name, kind = uv.fs_scandir_next(handle)
    if not name then
      break
    end
    if name:match("^%d%d%d%d%-%d%d%.jsonl$") and kind ~= "directory" and kind ~= "link" then
      names[#names + 1] = name
    end
  end
  table.sort(names)
  return names
end

---The lines of a text (`\n` or `\r\n`), without the empty ones at the end.
---@param text string
---@return string[]
local function lines_of(text)
  local out = vim.split(fsio.lf(text), "\n", { plain = true })
  while #out > 0 and out[#out] == "" do
    out[#out] = nil
  end
  return out
end

---@class Tasks.HistoryRead
---@field rows Tasks.HistoryRow[]   # One row per day and area (the latest `at`), by day, then area.
---@field problems string[]        # Lines and files that were skipped, relative to the vault.
---@field days table<string, true> # The days that have a row of any area.

---Read the series. A broken line, a line of another month than its file and a file that cannot be read are named in
---`problems` and skipped; the rest is the series.
---@param root string
---@return Tasks.HistoryRead
function M.read(root)
  local problems, n_problems = {}, 0
  local function problem(text)
    n_problems = n_problems + 1
    if n_problems <= M.MAX_PROBLEMS then
      problems[#problems + 1] = text
    end
  end
  local best, order = {}, {}
  local names, why = month_files(root)
  if not names then
    problem(tostring(why))
    names = {}
  end
  for _, name in ipairs(names) do
    local rel = M.DIR .. "/" .. name
    -- the reason of `fsio.read` names the path of this machine: the file relative to the vault says enough
    local text = fsio.read(M.dir(root) .. "/" .. name)
    if not text then
      problem(rel .. ": cannot be read")
    else
      for n, line in ipairs(lines_of(text)) do
        if line:match("%S") then
          local row, rerr = M.parse_row(line)
          if row and row.day:sub(1, 7) ~= name:sub(1, 7) then
            row, rerr = nil, "day is not of this month"
          end
          if not row then
            problem(("%s:%d: %s"):format(rel, n, rerr))
          else
            local key = row.day .. "\0" .. row.area
            local known = best[key]
            if not known then
              order[#order + 1] = key
              best[key] = { row = row, line = line }
            elseif row.at > known.row.at or (row.at == known.row.at and line > known.line) then
              -- two machines wrote the same day: the later one is the state of that day (the same second: the same
              -- line on every machine, whatever the order in the file)
              best[key] = { row = row, line = line }
            end
          end
        end
      end
    end
  end
  if n_problems > M.MAX_PROBLEMS then
    problems[#problems + 1] = ("... and %d more"):format(n_problems - M.MAX_PROBLEMS)
  end
  local rows, days = {}, {}
  for _, key in ipairs(order) do
    local row = best[key].row
    rows[#rows + 1] = row
    days[row.day] = true
  end
  table.sort(rows, function(a, b)
    if a.day ~= b.day then
      return a.day < b.day
    end
    return a.area < b.area
  end)
  return { rows = rows, problems = problems, days = days }
end

---The last row of every area up to a day (included).
---@param rows Tasks.HistoryRow[]  # as `read` gives them
---@param day string
---@return table<string, Tasks.HistoryRow>
function M.state_at(rows, day)
  local state = {}
  for _, row in ipairs(rows) do
    if row.day > day then
      break
    end
    state[row.area] = row
  end
  return state
end

---The rows a day needs: the areas whose figures differ from their last row, and a row of zeros for an area that had
---figures and is gone. Sorted by area.
---@param state table<string, Tasks.HistoryRow>          # the last row of every area before
---@param figures table<string, Tasks.HistoryFigures>
---@param day string
---@param at string
---@param src? string
---@return Tasks.HistoryRow[]
function M.changes(state, figures, day, at, src)
  local out = {}
  local function push(area, f)
    out[#out + 1] = vim.tbl_extend("force", vim.deepcopy(f), {
      day = day,
      area = area,
      at = at,
      src = src,
    })
  end
  for area, f in pairs(figures) do
    local last = state[area]
    if last and not same(last, f) or not last and not is_zero(f) then
      push(area, f)
    end
  end
  for area, last in pairs(state) do
    if not figures[area] and not is_zero(last) then
      push(area, empty())
    end
  end
  table.sort(out, function(a, b)
    return a.area < b.area
  end)
  return out
end

---Write rows into their month files: a valid row of the same day and area is replaced, every other line stays as it
---is (a broken one too: it may be a row of a newer engine).
---@param root string
---@param rows Tasks.HistoryRow[]
---@return boolean ok
---@return string|nil err
function M.write_rows(root, rows)
  local by_file, files = {}, {}
  for _, row in ipairs(rows) do
    local path = M.file_of(root, row.day)
    if not by_file[path] then
      by_file[path] = {}
      files[#files + 1] = path
    end
    table.insert(by_file[path], row)
  end
  table.sort(files)
  if fsio.is_link(root .. "/_Telemetry") or fsio.is_link(M.dir(root)) then
    return false, M.DIR .. " is a link"
  end
  for _, path in ipairs(files) do
    local ok, err = fsio.with_lock(path, function()
      local replaced = {}
      for _, row in ipairs(by_file[path]) do
        replaced[row.day .. "\0" .. row.area] = true
      end
      local kept = {}
      if fsio.is_file(path) then
        local text, rerr = fsio.read(path)
        if not text then
          return nil, "cannot read " .. vim.fs.basename(path) .. ": " .. tostring(rerr)
        end
        for _, line in ipairs(lines_of(text)) do
          local row = M.parse_row(line)
          if not (row and replaced[row.day .. "\0" .. row.area]) then
            kept[#kept + 1] = line
          end
        end
      end
      for _, row in ipairs(by_file[path]) do
        kept[#kept + 1] = M.encode_row(row)
      end
      local wrote, werr = fsio.write_atomic(path, table.concat(kept, "\n") .. "\n")
      if not wrote then
        return nil, "cannot write " .. vim.fs.basename(path) .. ": " .. tostring(werr)
      end
      return true
    end)
    if not ok then
      return false, tostring(err)
    end
  end
  return true
end

---@class Tasks.HistoryRecorded
---@field rows integer        # Rows written (a dry run: that would be written).
---@field areas string[]      # Their areas, sorted.
---@field file string         # The month file, relative to the vault.
---@field problems string[]   # What the reader skipped.

---Write down the figures of today: a row for every area whose figures changed since its last row.
---@param view Tasks.ContractView
---@param opts? { today?: string, at?: string, dry_run?: boolean }
---@return Tasks.HistoryRecorded|nil result
---@return string|nil err
function M.record(view, opts)
  opts = opts or {}
  local today = opts.today or model.today()
  if not model.is_date(today) then
    return nil, "today is not a date (YYYY-MM-DD)"
  end
  local at = opts.at or os.date("!%Y-%m-%dT%H:%M:%SZ") --[[@as string]]
  local read = M.read(view.root)
  local rows = M.changes(M.state_at(read.rows, today), M.figures(view), today, at)
  local areas = {}
  for _, row in ipairs(rows) do
    areas[#areas + 1] = row.area
  end
  if #rows > 0 and not opts.dry_run then
    local ok, err = M.write_rows(view.root, rows)
    if not ok then
      return nil, err
    end
  end
  return {
    rows = #rows,
    areas = areas,
    file = M.DIR .. "/" .. today:sub(1, 7) .. ".jsonl",
    problems = read.problems,
  }
end

---@class Tasks.HistoryLevels
---@field by_day table<string, Tasks.HistoryFigures>  # The sum over the areas on every day from the first row on.
---@field first? string  # The first day of the series that has a row of these areas.
---@field last? string   # The last such day.

---The level of every day of a window: the sum of the last row of every area up to that day. A day before the first
---row has no level (unknown, never 0).
---@param rows Tasks.HistoryRow[]  # as `read` gives them
---@param since string
---@param until_ string
---@param areas? table<string, true>  # only these areas (default: all)
---@return Tasks.HistoryLevels
function M.levels(rows, since, until_, areas)
  local out = { by_day = {} }
  local cur, seen, i = {}, false, 1
  local scoped = {}
  for _, row in ipairs(rows) do
    if areas == nil or areas[row.area] then
      scoped[#scoped + 1] = row
      out.first = out.first or row.day
      out.last = row.day
    end
  end
  ---@type string|nil
  local day = since
  while day and day <= until_ do
    while scoped[i] and scoped[i].day <= day do
      cur[scoped[i].area] = scoped[i]
      seen = true
      i = i + 1
    end
    if seen then
      local sum = empty()
      for _, row in pairs(cur) do
        add(sum, row)
      end
      sum.days = round2(sum.days)
      out.by_day[day] = sum
    end
    day = model.add_days(day, 1)
  end
  return out
end

return M
