---@module 'tasks_nvim.integrations.tree_counts'
-- @scans-data: the folders it lists and the paths it names are task vaults, never the files of this plugin
---@brief How many open tasks each area has, read from the generated index files and kept for a tree to look up.
---@description
--- A tree view asks for a badge while it draws a line, so the answer has to be a table lookup. This
--- module keeps that table. It never scans task files: per area it reads the head of
--- `<area>/ROADMAP/TASKS.md`, whose second line carries the count (`# <area> — offene Tasks (12)`),
--- which is one small read per area and stays that small in a vault with thousands of tasks.
---
--- The table changes in three ways:
---  - `refresh()`: every area, when a reader starts listening and when the vault changed
---  - `index.on_write`: this Neovim wrote or removed an index file (a task created, finished, moved)
---  - a file watcher per `<area>/ROADMAP` while somebody listens: another Neovim, the headless CLI or
---    a `git pull` wrote it. Non-recursive handles, one per area, at most `MAX_HANDLES`
---
--- Nothing is watched and nothing is read while nobody listens (`on_change`); the last listener that
--- leaves closes every handle.
---
--- Known limits: an area that gets its `ROADMAP/` folder while a reader listens is watched from the
--- next `refresh()` on (the write hook still reports what this Neovim does there). An index that is out
--- of date shows an out-of-date count; `:Tasks check` reports such an index.
---
--- Seam for specs: `M.start_watch` (the handle factory).

local fsio = require("tasks_nvim.fsio")
local index = require("tasks_nvim.index")
local soft = require("tasks_nvim.soft")
local vault = require("tasks_nvim.vault")

local uv = vim.uv or vim.loop

local M = {}

---At most this many folders are watched at once (one `fs_event` handle each); see
---`tasks_nvim.ui.dash_watch` for why there is a limit at all.
M.MAX_HANDLES = 400

---How much of an index file is read: the marker line and the heading are far shorter.
local HEAD_BYTES = 2048

---What a listener is told.
---@class Tasks.TreeCounts.Event
---@field areas? string[]   # The areas whose index changed; nil: all of them (another vault, the first read).
---@field counts boolean    # Whether a count changed (false: the same number of tasks, other rows).
---@field paths? string[]   # The badge keys that changed; nil: all of them.

---@type { root: string|nil, counts: table<string, integer>, badges: table<string, table> }
local state = { root = nil, counts = {}, badges = {} }

---@type table<integer, fun(event: Tasks.TreeCounts.Event)>
local listeners = {}
local next_listener = 0

---@type table[]  the watch handles
local handles = {}
---@type fun()|nil
local unhook = nil

---One spelling for a path, the one a tree view uses for its keys: `/`-separated, the drive letter in
---upper case, no trailing slash.
---@param path string
---@return string
function M.norm(path)
  path = path:gsub("\\", "/")
  path = path:gsub("^(%a):", function(drive)
    return drive:upper() .. ":"
  end)
  if #path > 1 and path:sub(-1) == "/" and not path:match("^%a:/$") then
    path = path:sub(1, -2)
  end
  return path
end

---The open tasks an index text announces in its heading, or nil when it is no generated index.
---@param head string  the first lines of the file
---@return integer|nil
function M.parse_count(head)
  if not index.is_generated(head) then
    return nil
  end
  local heading = fsio.lf(head):match("^[^\n]*\n(#[^\n]*)")
  local count = heading and heading:match("%((%d+)%)%s*$")
  return count and tonumber(count) or nil
end

---The count in the index file at `path`: 0 when there is none (an area without open tasks has no
---index) or when it is somebody's own `TASKS.md`.
---@param path string
---@return integer
function M.read_count(path)
  local fd = uv.fs_open(path, "r", 292)
  if not fd then
    return 0
  end
  local head = uv.fs_read(fd, HEAD_BYTES, 0)
  uv.fs_close(fd)
  return type(head) == "string" and M.parse_count(head) or 0
end

---The paths that carry the badge of an area: the area folder, `ROADMAP` and `ROADMAP/tasks`.
---@param root string
---@param area string
---@return string[]
function M.badge_paths(root, area)
  local dir = M.norm(root) .. "/" .. area
  return { dir, dir .. "/ROADMAP", dir .. "/ROADMAP/tasks" }
end

---@param root string
---@param area string
---@param count integer
local function set_count(root, area, count)
  state.counts[area] = count > 0 and count or nil
  local badge = count > 0 and { text = tostring(count), hl = "Number", count = count } or nil
  for _, path in ipairs(M.badge_paths(root, area)) do
    state.badges[path] = badge
  end
end

---@param event Tasks.TreeCounts.Event
local function tell(event)
  for _, fn in pairs(listeners) do
    pcall(fn, event)
  end
end

---The vault the counts belong to, as it was at the last `refresh()` (no file access).
---@return string|nil
function M.root()
  return state.root
end

---The badge of a path, or nil. A table lookup: this is what a decorator's `get` calls.
---@param path string
---@return table|nil
function M.badge(path)
  return state.badges[path]
end

---Every path that has a badge (the table itself: read it, do not change it).
---@return table<string, table>
function M.badges()
  return state.badges
end

---@param area string
---@return integer
function M.count(area)
  return state.counts[area] or 0
end

---The areas with open tasks, sorted by name.
---@return { name: string, count: integer }[]
function M.areas()
  local out = {}
  for name, count in pairs(state.counts) do
    out[#out + 1] = { name = name, count = count }
  end
  table.sort(out, function(a, b)
    return a.name < b.name
  end)
  return out
end

---Read one area again and tell the listeners. `force` tells them even when the count is the same
---(the rows of the index changed: a status, a title).
---@param area string
---@param force? boolean
---@return boolean changed  whether the count changed
function M.refresh_area(area, force)
  local root = state.root
  if not root then
    return false
  end
  local before = state.counts[area] or 0
  local count = M.read_count(vault.index_path(root, area))
  local changed = count ~= before
  if changed then
    set_count(root, area, count)
  end
  if changed or force then
    tell({
      areas = { area },
      counts = changed,
      paths = changed and M.badge_paths(root, area) or {},
    })
  end
  return changed
end

---Read every area of the vault again. Without a vault the table is emptied. `silent` tells nobody: for
---a caller that is itself answering a tree (a listener that asked the tree to read again from inside
---that answer would re-enter it).
---@param silent? boolean
---@return boolean changed  whether anything differs from before
function M.refresh(silent)
  local root = vault.root()
  local counts = {}
  if root then
    for _, area in ipairs(vault.areas(root)) do
      local count = M.read_count(vault.index_path(root, area.name))
      if count > 0 then
        counts[area.name] = count
      end
    end
  end
  local same = root == state.root and vim.deep_equal(counts, state.counts)
  if same then
    return false
  end
  state = { root = root, counts = {}, badges = {} }
  if root then
    for area, count in pairs(counts) do
      set_count(root, area, count)
    end
  end
  if not silent then
    tell({ counts = true })
  end
  return true
end

---The handle factory: `lib.nvim.fs.watch.start`, or nil without it.
---@type (fun(path: string, on_change: fun(), opts: table): table|nil, string|nil)|nil
M.start_watch = nil

local function stop_watching()
  for _, handle in ipairs(handles) do
    pcall(handle.stop)
  end
  handles = {}
end

---Watch `<area>/ROADMAP` of every area that has one.
local function start_watching()
  stop_watching()
  local root = state.root
  local start = M.start_watch
  if not start then
    local watch = soft.check({ "start" }, pcall(require, "lib.nvim.fs.watch"))
    start = watch and watch.start
  end
  if not (root and start) then
    return
  end
  for _, area in ipairs(vault.areas(root)) do
    if #handles >= M.MAX_HANDLES then
      break
    end
    local dir = root .. "/" .. area.name .. "/ROADMAP"
    if fsio.is_dir(dir) then
      local name = area.name
      -- No filter by file name: an atomic write ends on the name of its temp file as often as on
      -- `TASKS.md`. Reading the head again is cheap, and little else happens in `ROADMAP/` itself.
      local handle = start(dir, function()
        vim.schedule(function()
          if state.root == root then
            M.refresh_area(name, true)
          end
        end)
      end, { debounce_ms = 150 })
      if handle then
        handles[#handles + 1] = handle
      end
    end
  end
end

---Listen for changes. The first listener has the vault read and the watchers started (a moment later,
---see below), the last one that leaves stops them.
---@param fn fun(event: Tasks.TreeCounts.Event)
---@return fun() remove
function M.on_change(fn)
  next_listener = next_listener + 1
  local id = next_listener
  local first = next(listeners) == nil
  listeners[id] = fn
  if first then
    unhook = index.on_write(function(root, result)
      if state.root and fsio.same_path(root, state.root) then
        M.refresh_area(result.area, true)
      end
    end)
    -- Not in this call: a tree subscribes while it opens, and reading the heads of a large vault takes
    -- tens of milliseconds. The tree draws first, the badges arrive with the event.
    vim.schedule(function()
      if next(listeners) ~= nil then
        -- told in any case: a silent read in between (the view was shown first) changed the table
        -- without a word
        if not M.refresh() then
          tell({ counts = true })
        end
        start_watching()
      end
    end)
  end
  return function()
    listeners[id] = nil
    if next(listeners) == nil then
      stop_watching()
      if unhook then
        unhook()
        unhook = nil
      end
    end
  end
end

---Read the vault again and watch what is there now (after `:TasksVault switch`, or by hand).
function M.reload()
  M.refresh()
  if next(listeners) ~= nil then
    start_watching()
  end
end

---How many folders are watched right now (for `:checkhealth` and the specs).
---@return integer
function M.watched()
  return #handles
end

return M
