---@module 'tasks_nvim.learn_history'
---@brief The series of the learning figures: one row per day and learning path below `<vault>/_Telemetry/history/`,
---and what it says (what was learned in a window, the streak of learning days, the day a level was reached, the pace).
---@description
--- A path file carries no date per point (Stefan's decision of 2026-11-22): when a point was learned cannot be worked
--- out later, so the figures of every path are written down when they change, as `tasks_nvim.history` does for the
--- figures of the areas, and read back as a series (`tasks.learn_history`).
---
--- Where: `<vault>/_Telemetry/history/learn-YYYY-MM.jsonl`, one JSON object per line (the reader of `history` takes
--- `YYYY-MM.jsonl` only, so the two series never mix; both are `merge=union`).
---
--- A row holds the figures of ONE path on ONE day, absolute (never a difference):
---   `{ v, day, path, area, at, learned, seen, dropped, open, total, xp, done_h, level?, reached?, given? }`
--- `learned` … `total` the progress of its tree (optional points left out, as everywhere), `xp` the XP earned (optional
--- ones included, as a level in XP counts them), `done_h` the hours done (`learn.hours`), `level` the level reached,
--- `reached` / `given` the refs of the levels reached and of the rewards granted (`"1"`, …, `"done"`).
---
--- Rules as for the other series: a row only when the figures of its path changed since its last row, one row per
--- day and path (a second run the same day replaces it), the later `at` wins when two machines wrote the same day, a
--- broken line is named and skipped. A finished path (closed into a Backlog) keeps being read, so its last figures
--- stay; a path that is gone altogether gets no row.
---
--- Not its job: the document (`contract_learn.history`).
-- @scans-data

local fsio = require("tasks_nvim.fsio")
local json = require("lib.nvim.json.canonical")
local model = require("tasks_nvim.model")

local uv = vim.uv or vim.loop

local M = {}

---The folder of the series, relative to the vault (shared with `tasks_nvim.history`).
M.DIR = "_Telemetry/history"

---The prefix of the month files.
M.PREFIX = "learn-"

---The version of a row.
M.ROW_VERSION = 1

---Longest line the reader takes for a row.
M.MAX_LINE = 4096

---The most problems one reading names.
M.MAX_PROBLEMS = 20

---The most refs a row names (`reached`, `given`).
M.MAX_REFS = 64

---The biggest count or sum a row may hold.
local MAX_NUMBER = 1e9

---The counts of a row, in the order they are written.
M.COUNTS = { "learned", "seen", "dropped", "open", "total", "xp" }

---@class Tasks.LearnFigures
---@field area string
---@field learned integer
---@field seen integer
---@field dropped integer
---@field open integer
---@field total integer
---@field xp integer
---@field done_h number
---@field level? integer
---@field reached? string[]
---@field given? string[]

---@class Tasks.LearnRow : Tasks.LearnFigures
---@field day string
---@field path string
---@field at string

---@param n number
---@return number
local function round2(n)
  local r = math.floor(n * 100 + 0.5) / 100
  return r == math.floor(r) and math.floor(r) or r
end

---The figures of a path file as a row holds them.
---@param f Tasks.PlanFile
---@return Tasks.LearnFigures
function M.figures_of(f)
  local tree = f.tree or require("tasks_nvim.lernbaum").parse("")
  local p = tree.progress
  local hours = require("tasks_nvim.learn").hours(tree)
  local out = {
    area = f.area,
    learned = p.learned,
    seen = p.seen,
    dropped = p.dropped,
    open = p.open,
    total = p.total,
    xp = tree.xp.earned + (tree.optional and tree.optional.xp.earned or 0),
    done_h = hours and hours.done or 0,
  }
  local st = f.level_state
  if st and st.has_levels then
    out.level = st.level
    local reached, given = {}, {}
    local lv = f.levels
    local all = lv and vim.list_slice(lv.levels, 1) or {}
    if lv and lv.final then
      all[#all + 1] = lv.final
    end
    for _, l in ipairs(all) do
      if st.reached[l.ref] then
        reached[#reached + 1] = l.ref
      end
      if l.given then
        given[#given + 1] = l.ref
      end
    end
    out.reached = #reached > 0 and reached or nil
    out.given = #given > 0 and given or nil
  end
  return out
end

---@param a? string[]
---@param b? string[]
---@return boolean
local function same_list(a, b)
  a, b = a or {}, b or {}
  if #a ~= #b then
    return false
  end
  for i = 1, #a do
    if a[i] ~= b[i] then
      return false
    end
  end
  return true
end

---Whether two figures say the same.
---@param a Tasks.LearnFigures
---@param b Tasks.LearnFigures
---@return boolean
function M.same(a, b)
  for _, k in ipairs(M.COUNTS) do
    if a[k] ~= b[k] then
      return false
    end
  end
  return a.done_h == b.done_h
    and a.level == b.level
    and a.area == b.area
    and same_list(a.reached, b.reached)
    and same_list(a.given, b.given)
end

---@param v any
---@return boolean
local function is_count(v)
  return type(v) == "number" and v >= 0 and v <= MAX_NUMBER and v == math.floor(v)
end

---@param v any
---@return string[]|nil list
---@return boolean ok
local function refs_of(v)
  if v == nil then
    return nil, true
  end
  if type(v) ~= "table" or #v == 0 or #v > M.MAX_REFS then
    return nil, false
  end
  for _, r in ipairs(v) do
    if type(r) ~= "string" or not (r:match("^%d+$") or r == "done") then
      return nil, false
    end
  end
  return v, true
end

---Read one line of the series; nil and why for a line that is no valid row.
---@param line string
---@return Tasks.LearnRow|nil row
---@return string|nil err
function M.parse_row(line)
  if #line > M.MAX_LINE then
    return nil, "line too long"
  end
  local okj, raw = pcall(vim.json.decode, line)
  if not okj or type(raw) ~= "table" then
    return nil, "no JSON object"
  end
  if raw.v ~= M.ROW_VERSION then
    return nil, "unknown row version"
  end
  if not model.is_date(raw.day) then
    return nil, "day is not a date"
  end
  if type(raw.path) ~= "string" or not raw.path:match("^[^/%s]+/[^/%s]+$") then
    return nil, "path is no <area>/<slug>"
  end
  if type(raw.area) ~= "string" or raw.area == "" then
    return nil, "area is missing"
  end
  if type(raw.at) ~= "string" or not raw.at:match("^%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%dZ$") then
    return nil, "at is no UTC time"
  end
  local row = { day = raw.day, path = raw.path, area = raw.area, at = raw.at }
  for _, k in ipairs(M.COUNTS) do
    if not is_count(raw[k]) then
      return nil, k .. " is no count"
    end
    row[k] = raw[k]
  end
  if type(raw.done_h) ~= "number" or raw.done_h < 0 or raw.done_h > MAX_NUMBER then
    return nil, "done_h is no number of hours"
  end
  row.done_h = round2(raw.done_h)
  if raw.level ~= nil then
    if not is_count(raw.level) then
      return nil, "level is no count"
    end
    row.level = raw.level
  end
  local reached, rok = refs_of(raw.reached)
  local given, gok = refs_of(raw.given)
  if not rok or not gok then
    return nil, "reached and given are lists of level refs"
  end
  row.reached, row.given = reached, given
  return row
end

---A row as its line (canonical JSON, keys sorted).
---@param row Tasks.LearnRow
---@return string
function M.encode_row(row)
  local obj = {
    v = M.ROW_VERSION,
    day = row.day,
    path = row.path,
    area = row.area,
    at = row.at,
    done_h = round2(row.done_h or 0),
    level = row.level,
    reached = row.reached and json.array(row.reached) or nil,
    given = row.given and json.array(row.given) or nil,
  }
  for _, k in ipairs(M.COUNTS) do
    obj[k] = row[k]
  end
  return (json.encode(json.object(obj)))
end

---The folder of the series.
---@param root string
---@return string
function M.dir(root)
  return root .. "/" .. M.DIR
end

---The file of a month.
---@param root string
---@param day string
---@return string
function M.file_of(root, day)
  return ("%s/%s%s.jsonl"):format(M.dir(root), M.PREFIX, day:sub(1, 7))
end

---The month files of the series, oldest first; nil and why when the folder leads out of the vault.
---@param root string
---@return string[]|nil names
---@return string|nil why
local function month_files(root)
  local dir = M.dir(root)
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
    if name:match("^learn%-%d%d%d%d%-%d%d%.jsonl$") and kind ~= "directory" and kind ~= "link" then
      names[#names + 1] = name
    end
  end
  table.sort(names)
  return names
end

---@param text string
---@return string[]
local function lines_of(text)
  local out = vim.split(fsio.lf(text), "\n", { plain = true })
  while #out > 0 and out[#out] == "" do
    out[#out] = nil
  end
  return out
end

---@class Tasks.LearnRead
---@field rows Tasks.LearnRow[]     # One row per day and path (the later `at`), by day, then path.
---@field problems string[]
---@field files string[]            # The month files read, relative to the vault (for a `rev`).
---@field texts table<string, string>  # Their texts, by relative name.

---Read the series. A broken line and a file that cannot be read are named in `problems` and skipped.
---@param root string
---@return Tasks.LearnRead
function M.read(root)
  local problems, n = {}, 0
  local function problem(text)
    n = n + 1
    if n <= M.MAX_PROBLEMS then
      problems[#problems + 1] = text
    end
  end
  local best, order = {}, {}
  local names, why = month_files(root)
  if not names then
    problem(tostring(why))
    names = {}
  end
  local files, texts = {}, {}
  for _, name in ipairs(names) do
    local rel = M.DIR .. "/" .. name
    local text = fsio.read(M.dir(root) .. "/" .. name)
    if not text then
      problem(rel .. ": cannot be read")
    else
      files[#files + 1] = rel
      texts[rel] = text
      local month = name:match("^learn%-(%d%d%d%d%-%d%d)")
      for i, line in ipairs(lines_of(text)) do
        if line:match("%S") then
          local row, rerr = M.parse_row(line)
          if row and row.day:sub(1, 7) ~= month then
            row, rerr = nil, "day is not of this month"
          end
          if not row then
            problem(("%s:%d: %s"):format(rel, i, rerr))
          else
            local key = row.day .. "\0" .. row.path
            local known = best[key]
            if not known then
              order[#order + 1] = key
              best[key] = { row = row, line = line }
            elseif row.at > known.row.at or (row.at == known.row.at and line > known.line) then
              best[key] = { row = row, line = line }
            end
          end
        end
      end
    end
  end
  if n > M.MAX_PROBLEMS then
    problems[#problems + 1] = ("... and %d more"):format(n - M.MAX_PROBLEMS)
  end
  local rows = {}
  for _, key in ipairs(order) do
    rows[#rows + 1] = best[key].row
  end
  table.sort(rows, function(a, b)
    if a.day ~= b.day then
      return a.day < b.day
    end
    return a.path < b.path
  end)
  return { rows = rows, problems = problems, files = files, texts = texts }
end

---The paths whose figures a record takes: the open ones, and the finished ones read from the Backlogs.
---@param root string
---@return Tasks.PlanFile[]
function M.path_files(root)
  local paths_mod = require("tasks_nvim.paths")
  local out = vim.list_slice(paths_mod.all({ root = root }) or {}, 1)
  local projects_mod = require("tasks_nvim.projects")
  local vault = require("tasks_nvim.vault")
  for _, item in ipairs(projects_mod.finished_items({ root = root })) do
    if projects_mod.finished_kind(item) == "path" then
      local area, slug = vault.parse_id(item.id)
      if area and slug then
        out[#out + 1] = paths_mod.from_file(
          item.path,
          { area = area, slug = slug, location = "backlog", root = root }
        )
      end
    end
  end
  return out
end

---Write rows into their month files: a valid row of the same day and path is replaced, every other line stays.
---@param root string
---@param rows Tasks.LearnRow[]
---@return boolean ok
---@return string|nil err
function M.write_rows(root, rows)
  if fsio.is_link(root .. "/_Telemetry") or fsio.is_link(M.dir(root)) then
    return false, M.DIR .. " is a link"
  end
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
  for _, path in ipairs(files) do
    local ok, err = fsio.with_lock(path, function()
      if fsio.is_link(path) then
        return nil, vim.fs.basename(path) .. " is a link"
      end
      local replaced = {}
      for _, row in ipairs(by_file[path]) do
        replaced[row.day .. "\0" .. row.path] = true
      end
      local kept = {}
      if fsio.is_file(path) then
        local text, rerr = fsio.read(path)
        if not text then
          return nil, "cannot read " .. vim.fs.basename(path) .. ": " .. tostring(rerr)
        end
        for _, line in ipairs(lines_of(text)) do
          local row = M.parse_row(line)
          if not (row and replaced[row.day .. "\0" .. row.path]) then
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

---@class Tasks.LearnRecorded
---@field rows integer
---@field paths string[]
---@field file string
---@field problems string[]

---Write down the learning figures of today: a row for every path whose figures changed since its last row (a path
---without a row yet gets one when it has a tree).
---@param root string
---@param opts? { today?: string, at?: string, dry_run?: boolean }
---@return Tasks.LearnRecorded|nil
---@return string|nil err
function M.record(root, opts)
  opts = opts or {}
  local today = opts.today or model.today()
  if not model.is_date(today) then
    return nil, "today is not a date (YYYY-MM-DD)"
  end
  local at = opts.at or os.date("!%Y-%m-%dT%H:%M:%SZ") --[[@as string]]
  local read = M.read(root)
  local last = {}
  for _, row in ipairs(read.rows) do
    if row.day <= today then
      last[row.path] = row
    end
  end
  local rows, paths = {}, {}
  for _, f in ipairs(M.path_files(root)) do
    local fig = M.figures_of(f)
    local prev = last[f.id]
    if (prev and not M.same(prev, fig)) or (not prev and fig.total > 0) then
      local row = vim.tbl_extend("force", fig, { day = today, path = f.id, at = at })
      rows[#rows + 1] = row
      paths[#paths + 1] = f.id
    end
  end
  table.sort(rows, function(a, b)
    return a.path < b.path
  end)
  table.sort(paths)
  if #rows > 0 and not opts.dry_run then
    local ok, err = M.write_rows(root, rows)
    if not ok then
      return nil, err
    end
  end
  return {
    rows = #rows,
    paths = paths,
    file = M.DIR .. "/" .. M.PREFIX .. today:sub(1, 7) .. ".jsonl",
    problems = read.problems,
  }
end

-- ── what the series says ─────────────────────────────────────────────────────

---The Monday of the week a day falls in.
---@param day string
---@return string
function M.week_start(day)
  local since_monday = (model.days_between("1970-01-05", day) or 0) % 7
  return model.add_days(day, -since_monday) or day
end

---The first day of the month a day falls in.
---@param day string
---@return string
function M.month_start(day)
  return day:sub(1, 8) .. "01"
end

---The first day of the next month.
---@param day string
---@return string
local function next_month(day)
  local y, m = tonumber(day:sub(1, 4)), tonumber(day:sub(6, 7))
  m = m + 1
  if m > 12 then
    y, m = y + 1, 1
  end
  return ("%04d-%02d-01"):format(y, m)
end

---The start of the step a day falls in.
---@param day string
---@param step "day"|"week"|"month"
---@return string
function M.step_start(day, step)
  if step == "week" then
    return M.week_start(day)
  elseif step == "month" then
    return M.month_start(day)
  end
  return day
end

---The start of the next step.
---@param start string
---@param step "day"|"week"|"month"
---@return string
function M.next_step(start, step)
  if step == "week" then
    return model.add_days(start, 7) or start
  elseif step == "month" then
    return next_month(start)
  end
  return model.add_days(start, 1) or start
end

---The rows of every path, in day order.
---@param rows Tasks.LearnRow[]
---@return table<string, Tasks.LearnRow[]>
function M.by_path(rows)
  local out = {}
  for _, row in ipairs(rows) do
    out[row.path] = out[row.path] or {}
    table.insert(out[row.path], row)
  end
  return out
end

---The last row of a path up to a day (included); nil before its first row. A binary search: the rows are in day order
---(`by_path`), and the windows and the streak ask this for every day and path.
---@param list Tasks.LearnRow[]
---@param day string
---@return Tasks.LearnRow|nil
function M.at(list, day)
  local lo, hi = 1, #list
  local found
  while lo <= hi do
    local mid = math.floor((lo + hi) / 2)
    if list[mid].day <= day then
      found = list[mid]
      lo = mid + 1
    else
      hi = mid - 1
    end
  end
  return found
end

---The fields a difference is taken of.
M.DELTAS = { "learned", "seen", "dropped", "xp", "done_h" }

---What changed for a path from the end of `from` (excluded) to the end of `to` (included). Before its first row a
---path counts from nothing, unless its first row is on the first day of the series (`first`): then that row is where
---the series starts, not something learned that day. nil when the path has no row up to `to`.
---@param list Tasks.LearnRow[]
---@param from string   # The day before the window.
---@param to string
---@param first string  # The first day of the series.
---@return table|nil
function M.delta(list, from, to, first)
  local e = M.at(list, to)
  if not e then
    return nil
  end
  local b = M.at(list, from)
  if not b and list[1].day == first then
    b = list[1]
  end
  local out = {}
  for _, k in ipairs(M.DELTAS) do
    local v = e[k] - (b and b[k] or 0)
    out[k] = k == "done_h" and round2(v) or v
  end
  return out
end

---Whether a difference is a learning day's: something learned or seen.
---@param d? table
---@return boolean
function M.learns(d)
  return d ~= nil and ((d.learned or 0) > 0 or (d.seen or 0) > 0)
end

---The streak of learning days (a day on which a point was learned or seen) up to `until_`: `current` the run that ends
---on `until_` or the day before it (today not learned yet keeps the streak), `longest` the longest run, `last_day` the
---last learning day.
---@param lists table<string, Tasks.LearnRow[]>
---@param first string
---@param until_ string
---@return { current: integer, longest: integer, last_day?: string }
function M.streak(lists, first, until_)
  local run, longest, last_day = 0, 0, nil
  local run_on = {}
  local day = first
  while day and day <= until_ do
    local learned = false
    local before = model.add_days(day, -1) or day
    for _, list in pairs(lists) do
      if M.learns(M.delta(list, before, day, first)) then
        learned = true
        break
      end
    end
    run = learned and run + 1 or 0
    run_on[day] = run
    if learned then
      last_day = day
      longest = math.max(longest, run)
    end
    day = model.add_days(day, 1)
  end
  local yesterday = model.add_days(until_, -1)
  local current = run_on[until_] or 0
  if current == 0 and yesterday then
    current = run_on[yesterday] or 0
  end
  return { current = current, longest = longest, last_day = last_day }
end

---The day each level ref was first reached and each reward first granted, from a path's rows.
---@param list Tasks.LearnRow[]
---@return table<string, string> reached_on
---@return table<string, string> given_on
function M.dates(list)
  local reached_on, given_on = {}, {}
  for _, row in ipairs(list or {}) do
    for _, ref in ipairs(row.reached or {}) do
      reached_on[ref] = reached_on[ref] or row.day
    end
    for _, ref in ipairs(row.given or {}) do
      given_on[ref] = given_on[ref] or row.day
    end
  end
  return reached_on, given_on
end

---The last day something changed for a path (learned, seen, dropped, XP or hours), up to `until_`; nil without.
---@param list Tasks.LearnRow[]
---@param first string
---@param until_ string
---@return string|nil
function M.last_active(list, first, until_)
  -- one pass: each row against the one before it (rows are one per day, in day order); the first row against nothing,
  -- unless it is on the first day of the series (where the series starts, nothing learned)
  local found, prev
  for i, row in ipairs(list) do
    if row.day > until_ then
      break
    end
    if i > 1 or row.day ~= first then
      for _, k in ipairs(M.DELTAS) do
        if row[k] ~= (prev and prev[k] or 0) then
          found = row.day
          break
        end
      end
    end
    prev = row
  end
  return found
end

return M
